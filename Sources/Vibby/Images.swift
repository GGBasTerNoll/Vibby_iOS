import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// Двухуровневый кэш картинок: память (уже уменьшенные) + диск (оригиналы).
/// Уменьшение через ImageIO, вне главного потока; одинаковые запросы объединяются.
actor ImageLoader {
    static let shared = ImageLoader()

    nonisolated let mem: NSCache<NSString, UIImage>
    nonisolated let dir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vibby-img", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 150_000_000
        mem = cache
        dir = u
    }

    nonisolated func cached(_ key: String, _ px: Int) -> UIImage? {
        mem.object(forKey: "\(key)#\(px)" as NSString)
    }

    nonisolated static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func downsample(_ data: Data, _ px: Int) -> UIImage? {
        let o1: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, o1 as CFDictionary) else { return nil }
        let o2: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, o2 as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    func load(key: String, px: Int, fetch: @escaping @Sendable () async -> Data?) async -> UIImage? {
        let mk = "\(key)#\(px)"
        if let i = mem.object(forKey: mk as NSString) { return i }
        if let t = inflight[mk] { return await t.value }
        let dir = self.dir
        let mem = self.mem
        let t = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let f = dir.appendingPathComponent(ImageLoader.hash(key))
            var data = try? Data(contentsOf: f)
            let fromDisk = data != nil
            if data == nil {
                data = await fetch()
                if let d = data { try? d.write(to: f, options: .atomic) }
            }
            guard let d = data, let img = ImageLoader.downsample(d, px) else {
                if fromDisk { try? FileManager.default.removeItem(at: f) }
                return nil
            }
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            mem.setObject(img, forKey: mk as NSString, cost: cost)
            return img
        }
        inflight[mk] = t
        let r = await t.value
        inflight[mk] = nil
        return r
    }

    /// Прогрев кэша (например, для стикеров набора) без ожидания результата.
    nonisolated func prefetch(key: String, px: Int, fetch: @escaping @Sendable () async -> Data?) {
        if cached(key, px) != nil { return }
        Task.detached(priority: .utility) { _ = await ImageLoader.shared.load(key: key, px: px, fetch: fetch) }
    }
}

func fetchURL(_ u: URL) async -> Data? {
    var rq = URLRequest(url: u)
    rq.timeoutInterval = 30
    guard let (d, r) = try? await URLSession.shared.data(for: rq),
          (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return d
}

struct CachedImage: View {
    let key: String
    let px: Int
    var fit = false
    let fetch: @Sendable () async -> Data?
    @State private var img: UIImage?

    init(key: String, px: Int, fit: Bool = false, fetch: @escaping @Sendable () async -> Data?) {
        self.key = key
        self.px = px
        self.fit = fit
        self.fetch = fetch
        _img = State(initialValue: ImageLoader.shared.cached(key, px))
    }

    var body: some View {
        ZStack {
            if let img {
                if fit {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            } else {
                Rectangle().fill(Color(.secondarySystemFill))
            }
        }
        .task(id: key) {
            if let c = ImageLoader.shared.cached(key, px) { img = c; return }
            img = await ImageLoader.shared.load(key: key, px: px, fetch: fetch)
        }
    }
}

/// Файл с файлового сервера по id (фото, стикеры).
struct FileImage: View {
    let sfid: String
    let px: Int
    var fit = false
    var body: some View {
        if let url = Api.shared.fileUrl(sfid) {
            CachedImage(key: url.absoluteString, px: px, fit: fit) { await fetchURL(url) }
        } else {
            Rectangle().fill(Color(.secondarySystemFill))
        }
    }
}

struct AvatarView: View {
    @EnvironmentObject var store: Store
    let id: String
    let name: String
    let size: CGFloat

    private var version: Int {
        if let u = store.users[id] { return u.i("avv") }
        if let c = store.chats[id] { return c.i("avv") }
        return 0
    }

    private var hue: Double {
        Double(name.unicodeScalars.reduce(7) { ($0 * 31 + Int($1.value)) % 360 }) / 360
    }

    var body: some View {
        let v = version
        ZStack {
            Circle().fill(Color(hue: hue, saturation: 0.4, brightness: 0.62))
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
            if v > 0 && store.canSee(id, "avatar") {
                CachedImage(key: "av_\(id)_\(v)", px: Int(size * 3)) {
                    await Store.shared.fetchAvatar(id)
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}
