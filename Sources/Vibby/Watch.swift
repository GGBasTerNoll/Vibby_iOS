import Foundation

/// Живая подписка на узел Realtime DB (SSE). Разбор и применение событий идут
/// вне главного потока; в интерфейс уходит уже готовый снимок.
@MainActor
final class Watch {
    private var task: Task<Void, Never>?

    init(_ path: String, query: [String: String] = [:],
         onChange: @escaping @MainActor (Any?) -> Void) {
        task = Task.detached(priority: .userInitiated) {
            await Watch.run(path: path, query: query, emit: onChange)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    nonisolated static let sse: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    nonisolated static func run(path: String, query: [String: String],
                                emit: @escaping @MainActor (Any?) -> Void) async {
        var root: Any? = nil
        while !Task.isCancelled {
            do {
                let t = try await Api.shared.tok()
                var c = URLComponents()
                c.scheme = "https"
                c.host = Cfg.dbHost
                c.path = "/\(path).json"
                var items = [URLQueryItem(name: "auth", value: t)]
                for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
                c.queryItems = items
                guard let url = c.url else { return }
                var rq = URLRequest(url: url)
                rq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, resp) = try await sse.bytes(for: rq)
                if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw VErr(msg: "denied") }
                var ev = ""
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    if line.hasPrefix("event:") {
                        ev = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        if ev == "auth_revoked" || ev == "cancel" { break }
                        if ev != "put" && ev != "patch" { continue }
                        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let d = raw.data(using: .utf8),
                              let j = (try? JSONSerialization.jsonObject(with: d)) as? J else { continue }
                        let p = (j["path"] as? String) ?? "/"
                        let keys = p.split(separator: "/").map(String.init)
                        var val = j["data"]
                        if val is NSNull { val = nil }
                        root = apply(root, keys[...], val, merge: ev == "patch")
                        let snap = root
                        await emit(snap)
                    }
                }
            } catch {}
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    nonisolated static func apply(_ root: Any?, _ keys: ArraySlice<String>, _ value: Any?, merge: Bool) -> Any? {
        if keys.isEmpty {
            if !merge { return value }
            var m = (root as? J) ?? [:]
            if let patch = value as? J {
                for (k, v) in patch {
                    if v is NSNull { m[k] = nil } else { m[k] = v }
                }
            }
            return m.isEmpty ? nil : m
        }
        var m = (root as? J) ?? [:]
        let k = keys.first!
        m[k] = apply(m[k], keys.dropFirst(), value, merge: merge)
        return m.isEmpty ? nil : m
    }
}
