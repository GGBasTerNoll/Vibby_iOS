import Foundation
import SwiftUI

struct Msg: Identifiable {
    enum State { case ok, pending, failed }
    let id: String
    let raw: J
    let body: J
    let state: State
    var ts: Int { raw.i("ts") }
    var uid: String { raw.s("u") }
    var type: String { let t = body.s("t"); return t.isEmpty ? "text" : t }
    var encrypted: Bool { raw["e"] != nil }
}

@MainActor
final class ChatModel: ObservableObject {
    let id: String
    @Published var items: [Msg] = []

    private var raw: [String: J] = [:]
    private var dec: [String: (sig: String, body: J?, at: Date)] = [:]
    private var busy: Set<String> = []
    private var watch: Watch?
    private var seenSent = 0
    private var rebuildTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var gotLive = false

    init(id: String) {
        self.id = id
        if let c = Disk.read("msgs_\(Api.shared.uid)_\(id).json") as? J {
            raw = c.compactMapValues { $0 as? J }
        }
        rebuild()
    }

    // MARK: - Подписка

    func start() {
        watch?.stop()
        let q = ["orderBy": "\"$key\"", "limitToLast": "60"]
        watch = Watch("messages/\(id)", query: q) { [weak self] snap in
            self?.gotLive = true
            self?.apply(snap)
        }
        // Быстрый запрос параллельно с установкой SSE-соединения.
        Task { [weak self] in
            guard let self else { return }
            if let r = try? await Api.shared.get("messages/\(id)", q: q), !self.gotLive {
                self.apply(r)
            }
        }
    }

    func stop() {
        watch?.stop()
        watch = nil
    }

    private func apply(_ snap: Any?) {
        raw = ((snap as? J) ?? [:]).compactMapValues { $0 as? J }
        schedulePersist()
        scheduleRebuild()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            Disk.write("msgs_\(Api.shared.uid)_\(self.id).json", self.raw)
        }
    }

    private func scheduleRebuild() {
        if rebuildTask != nil { return }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self else { return }
            self.rebuildTask = nil
            self.rebuild()
            Store.shared.markRead(self.id)
            self.markSeen()
        }
    }

    private func rebuild() {
        var out: [Msg] = []
        out.reserveCapacity(raw.count)
        for (k, m) in raw {
            if let env = m["e"] as? J {
                let sig = env.s("n")
                if let c = dec[k], c.sig == sig, c.body != nil || Date().timeIntervalSince(c.at) < 15 {
                    if let b = c.body {
                        out.append(Msg(id: k, raw: m, body: m.merging(b) { _, n in n }, state: .ok))
                    } else {
                        out.append(Msg(id: k, raw: m, body: [:], state: .failed))
                    }
                } else {
                    out.append(Msg(id: k, raw: m, body: [:], state: dec[k] == nil ? .pending : .failed))
                    decrypt(k, m, sig)
                }
            } else {
                out.append(Msg(id: k, raw: m, body: m, state: .ok))
            }
        }
        out.sort {
            let a = ($0.ts == 0 ? Int.max : $0.ts), b = ($1.ts == 0 ? Int.max : $1.ts)
            return a != b ? a < b : $0.id < $1.id
        }
        items = out
    }

    private func decrypt(_ k: String, _ m: J, _ sig: String) {
        if !busy.insert(k).inserted { return }
        Task { [weak self] in
            guard let self else { return }
            let b = await E2ee.shared.decryptMessage(chat: self.id, msg: m)
            self.busy.remove(k)
            self.dec[k] = (sig, b, Date())
            self.scheduleRebuild()
        }
    }

    // MARK: - Прочитано

    func otherSeen(_ chat: J) -> Int {
        let me = Api.shared.uid
        var mx = 0
        for (k, v) in chat.d("seen") where k != me {
            if let n = v as? NSNumber, n.intValue > mx { mx = n.intValue }
        }
        return mx
    }

    func markSeen() {
        guard Store.shared.fg else { return }
        let me = Api.shared.uid
        let last = items.filter { $0.uid != me }.map { $0.ts }.max() ?? 0
        let mine = Store.shared.chats[id]?.d("seen").i(me) ?? 0
        if last > mine && last > seenSent {
            seenSent = last
            let id = self.id
            Task { try? await Api.shared.put("chats/\(id)/seen/\(me)", last) }
        }
    }

    func typing() {
        let id = self.id, me = Api.shared.uid
        Task { try? await Api.shared.put("chats/\(id)/typing/\(me)", nowMs()) }
    }

    // MARK: - Отправка

    private func members() -> [String] {
        Array((Store.shared.chats[id]?.d("members") ?? [:]).keys)
    }

    private func previewOf(_ m: J) -> J {
        let t = m.s("t").isEmpty ? "text" : m.s("t")
        var p: J = ["t": t]
        if t == "text" || t == "sticker" { p["d"] = String(m.s("d").prefix(200)) }
        if t == "sticker", m["sfid"] != nil { p["sfid"] = m.s("sfid") }
        if t == "poll" { p["p"] = m.s("p") }
        if t == "video" || t == "file" { p["n"] = m.s("n") }
        if t == "video", m.b("round") { p["round"] = true }
        return p
    }

    /// Отправка сообщения: шифруется, если у всех участников есть ключи (как в Flutter).
    func send(_ content: J, reply: J? = nil) async throws {
        let api = Api.shared
        var payload = content
        if let reply { payload["rp"] = reply }
        let sealed = await E2ee.shared.seal(chat: id, content: payload, preview: previewOf(content), members: members())
        let t = content.s("t").isEmpty ? "text" : content.s("t")
        var wire: J = ["u": api.uid, "n": Store.shared.me.s("name"), "ts": SV, "t": t]
        if let s = sealed { wire["e"] = s.env } else { for (k, v) in payload { wire[k] = v } }
        let key = Api.nid()
        try await api.update([
            "messages/\(id)/\(key)": wire,
            "chats/\(id)/last": sealed?.preview ?? prevText(content),
            "chats/\(id)/ts": SV,
            "chats/\(id)/lu": api.uid,
        ])
        // Оптимистичное отображение до эха от сервера.
        var local = wire
        local["ts"] = nowMs()
        if let s = sealed, let env = s.env["n"] as? String {
            dec[key] = (env, payload, Date())
        }
        raw[key] = local
        scheduleRebuild()
        pushPeers(content)
    }

    private func pushPeers(_ m: J) {
        guard let ch = Store.shared.chats[id] else { return }
        let me = Api.shared.uid
        let uids = ch.d("members").keys.filter { $0 != me && !$0.isEmpty }
        if uids.isEmpty { return }
        let who = Store.shared.me.s("name").trimmingCharacters(in: .whitespaces)
        let name = ch.s("title").trimmingCharacters(in: .whitespaces)
        let dm = ch.s("type") == "dm"
        let title = dm ? (who.isEmpty ? "Vibby" : who) : (name.isEmpty ? "Vibby" : name)
        let body = (!dm && !who.isEmpty) ? "\(who): новое сообщение" : "Новое сообщение"
        let id = self.id
        Task { await Api.shared.pushMessage(chat: id, uids: Array(uids), title: title, body: body) }
    }

    func sendText(_ t: String, reply: J?) async throws {
        try await send(["t": "text", "d": String(t.prefix(3000))], reply: reply)
    }

    func sendImage(_ jpeg: Data, caption: String = "") async throws {
        let api = Api.shared
        let base = await api.loadFiles()
        if !base.isEmpty {
            do {
                let meta = try await api.upload(jpeg, name: "photo_\(nowMs()).jpg", mime: "image/jpeg")
                var c: J = ["t": "img", "sfid": meta.s("id"),
                            "n": meta["name"] == nil ? "photo.jpg" : meta.s("name"),
                            "s": meta["size"] == nil ? jpeg.count : meta.i("size"),
                            "m": meta["mime"] == nil ? "image/jpeg" : meta.s("mime")]
                if !caption.isEmpty { c["cap"] = caption }
                try await send(c)
                return
            } catch {
                if jpeg.count > 600_000 { throw error }
            }
        }
        if jpeg.count > 600_000 { throw VErr(msg: "Фото слишком большое") }
        var c: J = ["t": "img", "d": jpeg.base64EncodedString()]
        if !caption.isEmpty { c["cap"] = caption }
        try await send(c)
    }

    func edit(_ k: String, _ t: String) async throws {
        let api = Api.shared
        if let s = await E2ee.shared.seal(chat: id, content: ["t": "text", "d": t], preview: nil, members: members()) {
            try await api.patch("messages/\(id)/\(k)", ["e": s.env, "d": NSNull(), "ed": true])
        } else {
            try await api.patch("messages/\(id)/\(k)", ["d": t, "ed": true])
        }
    }

    func delete(_ k: String) async {
        raw[k] = nil
        scheduleRebuild()
        _ = try? await Api.shared.del("messages/\(id)/\(k)")
    }

    func react(_ k: String, _ e: String, current: String?) {
        let me = Api.shared.uid, id = self.id
        let nv: Any? = current == e ? nil : e
        if var m = raw[k] {
            var r = m.d("r")
            r[me] = nv
            if nv == nil { r[me] = nil }
            m["r"] = r
            raw[k] = m
            scheduleRebuild()
        }
        Task { try? await Api.shared.put("messages/\(id)/\(k)/r/\(me)", nv) }
    }

    func vote(_ k: String, _ i: Int) {
        let me = Api.shared.uid, id = self.id
        Task { try? await Api.shared.put("messages/\(id)/\(k)/v/\(me)", i) }
    }
}
