import SwiftUI

let kEmoji = ["😀","😂","🥹","😍","🤩","😎","🥳","😭","😡","🤯","🥶","😴","🤝","👍","👎","🔥","💀","👻","🎉","❤️","💎","🚀","🌈","🍕","🐱","🐶","🦄","🍀","⚡","🌙","👑","🎮","🙈","🥰","😅","🤔","🙏","👏","💪","✨"]

/// Наборы стикеров: userStickers/<uid> (id → время) и stickerPacks/<id>.
/// Наборы кэшируются на диске, картинки — через ImageLoader.
@MainActor
final class Stickers: ObservableObject {
    static let shared = Stickers()
    @Published var mine: [String] = []
    @Published var packs: [String: J] = [:]
    private var watch: Watch?
    private var started = ""

    func start() {
        let uid = Api.shared.uid
        if started == uid { return }
        started = uid
        watch?.stop()
        if let c = Disk.read("packs_\(uid).json") as? J { packs = c.compactMapValues { $0 as? J } }
        if let m = Disk.read("mystickers_\(uid).json") as? [String] { mine = m }
        watch = Watch("userStickers/\(uid)") { [weak self] snap in self?.sync(snap) }
    }

    func stop() {
        watch?.stop()
        watch = nil
        started = ""
        mine = []
        packs = [:]
    }

    private func sync(_ snap: Any?) {
        let m = (snap as? J) ?? [:]
        let ids = m.keys.sorted { m.i($0) < m.i($1) }
        mine = ids
        let uid = Api.shared.uid
        Disk.write("mystickers_\(uid).json", ids)
        let need = ids.filter { packs[$0] == nil }
        // Недостающие наборы грузим параллельно, а не по одному.
        Task { [self] in
            await withTaskGroup(of: (String, J?).self) { g in
                for id in need {
                    g.addTask {
                        let r = try? await Api.shared.get("stickerPacks/\(id)")
                        return (id, r as? J)
                    }
                }
                for await (id, p) in g { if let p { packs[id] = p } }
            }
            Disk.write("packs_\(uid).json", packs)
            prefetchAll()
        }
        prefetchAll()
    }

    func name(_ id: String) -> String {
        let n = packs[id]?.s("name") ?? ""
        return n.isEmpty ? "Набор" : n
    }

    func items(_ id: String) -> [J] {
        guard let it = packs[id]?["items"] as? J else { return [] }
        return it.keys.sorted().compactMap { it[$0] as? J }
    }

    /// Заранее кладём в кэш первые стикеры каждого набора — панель открывается без «мигания».
    func prefetchAll() {
        for id in mine.prefix(6) {
            for it in items(id).prefix(24) {
                if let url = Api.shared.fileUrl(it.s("id")) {
                    ImageLoader.shared.prefetch(key: url.absoluteString, px: 256) { await fetchURL(url) }
                }
            }
        }
    }
}

struct StickerPanel: View {
    @ObservedObject var stickers = Stickers.shared
    @State private var tab = "emoji"
    let onEmoji: (String) -> Void
    let onSticker: (String, J) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    tabButton("emoji", label: "😀")
                    ForEach(stickers.mine, id: \.self) { id in
                        tabButton(id, label: String(stickers.name(id).prefix(2)))
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider()
            ScrollView {
                if tab == "emoji" {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                        ForEach(kEmoji, id: \.self) { e in
                            Button { onEmoji(e) } label: { Text(e).font(.system(size: 28)) }
                        }
                    }.padding(12)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(Array(stickers.items(tab).enumerated()), id: \.offset) { _, it in
                            Button { onSticker(tab, it) } label: {
                                FileImage(sfid: it.s("id"), px: 256, fit: true).frame(height: 76)
                            }
                        }
                    }.padding(12)
                }
            }
        }
        .frame(height: 280)
        .background(.bar)
    }

    func tabButton(_ id: String, label: String) -> some View {
        Button { tab = id } label: {
            Text(label).font(.system(size: 18))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(tab == id ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
        }
    }
}
