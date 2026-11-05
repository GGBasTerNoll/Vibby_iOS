import Foundation
import SwiftUI

/// Состояние приложения. Быстрый старт устроен так:
/// 1) мгновенно рисуем чаты и пользователей из дискового кэша;
/// 2) параллельно догружаем только СВОИ чаты (а не весь узел chats);
/// 3) затем подключаем живые подписки и держим кэш свежим.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var chats: [String: J] = [:]
    @Published var users: [String: J] = [:]
    @Published var contacts: [String: J] = [:]
    @Published var me: J = [:]
    @Published var role = ""
    @Published var readMap: [String: Int] = [:]
    @Published var pinned: Set<String> = []
    @Published var muted: Set<String> = []
    @Published var previews: [String: String] = [:]
    @Published var filesTick = 0
    @Published var loaded = false

    var openId: String?
    var onKick: (() -> Void)?

    private var ids: Set<String> = []
    private var watches: [Watch] = []
    private var hb: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var prevSig: [String: String] = [:]
    private var running = false
    private var peerFetched: [String: Date] = [:]
    private var lastTs: [String: Int] = [:]
    private var avatarBusy: Set<String> = []

    // MARK: - Запуск / остановка

    func start() async {
        if running { return }
        running = true
        let api = Api.shared
        let uid = api.uid
        let d = UserDefaults.standard

        if let c = Disk.read("chats_\(uid).json") as? J { chats = c.compactMapValues { $0 as? J } }
        if let u = Disk.read("users_\(uid).json") as? J { users = u.compactMapValues { $0 as? J } }
        if let m = Disk.read("me_\(uid).json") as? J { me = m }
        readMap = (d.dictionary(forKey: "read") as? [String: Int]) ?? [:]
        pinned = Set(d.stringArray(forKey: "pinned") ?? [])
        muted = Set(d.stringArray(forKey: "muted") ?? [])
        for (id, c) in chats { lastTs[id] = c.i("ts") }
        ids = Set(chats.keys)
        if !chats.isEmpty { loaded = true }
        refreshPreviews()

        Task { [self] in await E2ee.shared.boot(); refreshPreviews() }
        Task { [self] in await api.loadFiles(force: true); filesTick += 1 }
        Task { [self] in
            if let r = (try? await api.get("users/\(uid)")) as? J {
                me = r
                Disk.write("me_\(uid).json", r)
            }
        }
        Task { [self] in
            let r = try? await api.get("roles/\(uid)")
            let a = try? await api.get("admins/\(uid)")
            let rs = (r as? String) ?? ""
            role = rs == "owner" ? "own" : (rs == "admin" || (a as? Bool) == true) ? "adm" : rs == "mod" ? "mod" : ""
        }

        // Быстрая загрузка: только мои чаты, все параллельно.
        Task { [self] in
            if let uc = (try? await api.get("userChats/\(uid)")) as? J {
                ids = Set(uc.keys)
                await fetchChats(Array(ids))
            }
            loaded = true
            startWatches()
        }
        beat()
        hb = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.beat()
                self?.refreshPeers(force: true)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        hb?.cancel()
        hb = nil
        watches.forEach { $0.stop() }
        watches = []
        chats = [:]
        users = [:]
        contacts = [:]
        me = [:]
        previews = [:]
        ids = []
        loaded = false
        peerFetched = [:]
        lastTs = [:]
        prevSig = [:]
    }

    private func startWatches() {
        let uid = Api.shared.uid
        watches.forEach { $0.stop() }
        watches = [
            Watch("userChats/\(uid)") { [weak self] snap in
                guard let self else { return }
                let new = Set(((snap as? J) ?? [:]).keys)
                let added = new.subtracting(self.ids)
                self.ids = new
                if !added.isEmpty { Task { await self.fetchChats(Array(added)) } }
                self.chats = self.chats.filter { new.contains($0.key) }
                self.schedulePersist()
            },
            Watch("chats") { [weak self] snap in self?.onChats(snap) },
            Watch("contacts/\(uid)") { [weak self] snap in
                self?.contacts = ((snap as? J) ?? [:]).compactMapValues { $0 as? J }
            },
        ]
    }

    private func fetchChats(_ list: [String]) async {
        let api = Api.shared
        var got: [String: J] = [:]
        await withTaskGroup(of: (String, J?).self) { g in
            for id in list {
                g.addTask {
                    let r = try? await api.get("chats/\(id)")
                    return (id, r as? J)
                }
            }
            for await (id, c) in g { if let c { got[id] = c } }
        }
        if got.isEmpty { return }
        for (id, c) in got {
            var x = c
            x["id"] = id
            chats[id] = x
            lastTs[id] = c.i("ts")
        }
        afterChatsChanged()
    }

    private func onChats(_ snap: Any?) {
        guard let all = snap as? J else { return }
        var changed = false
        for id in ids {
            guard var c = all[id] as? J else { continue }
            c["id"] = id
            if chats[id].map({ NSDictionary(dictionary: $0).isEqual(to: c) }) != true {
                chats[id] = c
                changed = true
            }
            lastTs[id] = c.i("ts")
        }
        if changed { afterChatsChanged() }
    }

    private func afterChatsChanged() {
        refreshPreviews()
        refreshPeers(force: false)
        schedulePersist()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            let uid = Api.shared.uid
            if uid.isEmpty { return }
            Disk.write("chats_\(uid).json", self.chats)
            Disk.write("users_\(uid).json", self.users)
        }
    }

    // MARK: - Пользователи (только собеседники, а не весь узел users)

    private func refreshPeers(force: Bool) {
        let api = Api.shared
        var want: [String] = []
        for (_, c) in chats where c.s("type") == "dm" {
            let p = peer(c)
            if p.isEmpty { continue }
            if let at = peerFetched[p], !force || Date().timeIntervalSince(at) < 25 { continue }
            peerFetched[p] = Date()
            want.append(p)
        }
        if want.isEmpty { return }
        Task { [self] in
            var got: [String: J] = [:]
            await withTaskGroup(of: (String, J?).self) { g in
                for id in want {
                    g.addTask {
                        let r = try? await api.get("users/\(id)")
                        return (id, r as? J)
                    }
                }
                for await (id, u) in g { if let u { got[id] = u } }
            }
            if got.isEmpty { return }
            for (k, v) in got { users[k] = v }
            schedulePersist()
        }
    }

    func ensureUser(_ id: String) {
        if users[id] != nil || id.isEmpty { return }
        Task { [self] in
            if let u = (try? await Api.shared.get("users/\(id)")) as? J { users[id] = u }
        }
    }

    func fetchAvatar(_ id: String) async -> Data? {
        guard let s = (try? await Api.shared.get("avatars/\(id)")) as? String, s.count > 20 else { return nil }
        return await Task.detached { Data(base64Encoded: s, options: .ignoreUnknownCharacters) }.value
    }

    // MARK: - Производные данные

    func peer(_ c: J) -> String {
        let uid = Api.shared.uid
        return c.d("members").keys.first { $0 != uid } ?? ""
    }

    func title(_ c: J) -> String {
        if c.s("type") != "dm" { return c.s("title") }
        let m = c.d("members")
        if m.count < 2 && m[Api.shared.uid] != nil { return "Избранное" }
        let o = peer(c)
        let n = users[o]?.s("name") ?? ""
        if !n.isEmpty { return n }
        let nm = c.d("names").s(o)
        return nm.isEmpty ? "Чат" : nm
    }

    func avatarId(_ c: J) -> String {
        if c.s("type") == "dm" {
            let m = c.d("members")
            return m.count < 2 ? Api.shared.uid : peer(c)
        }
        return c.s("id")
    }

    func isContact(_ id: String) -> Bool { contacts[id] != nil }

    private func priv(_ id: String, _ field: String) -> Int {
        let p = users[id]?.d("privacy") ?? [:]
        if let n = p[field] as? NSNumber, !(p[field] is Bool) { return n.intValue }
        if let s = p[field] as? String { return s == "contacts" ? 1 : s == "nobody" ? 2 : 0 }
        return 0
    }

    func canSee(_ id: String, _ field: String) -> Bool {
        if id.isEmpty || id == Api.shared.uid { return true }
        let m = priv(id, field)
        if m == 2 { return false }
        if m == 1 { return isContact(id) }
        return true
    }

    func canSeePresence(_ id: String) -> Bool {
        if id == Api.shared.uid { return true }
        let v = users[id]?.d("privacy")["lastSeen"]
        if let b = v as? Bool, !b { return false }
        if let n = v as? NSNumber {
            if n.intValue == 2 { return false }
            if n.intValue == 1 { return isContact(id) }
        }
        if let s = v as? String {
            if s == "nobody" { return false }
            if s == "contacts" { return isContact(id) }
        }
        return true
    }

    func online(_ uid: String) -> Bool {
        guard let u = users[uid], canSeePresence(uid) else { return false }
        let s = u.i("seen")
        if u["online"] as? Bool == false { return false }
        if u["online"] as? Bool != true { return nowMs() - s < 75000 }
        return nowMs() - s < 95000
    }

    func verifiedName(_ c: J) -> Bool {
        if c.b("verified") { return true }
        return users[peer(c)]?.b("verified") == true
    }

    func isUnread(_ id: String) -> Bool {
        guard let c = chats[id] else { return false }
        if c.s("lu") == Api.shared.uid || openId == id { return false }
        return c.i("ts") > (readMap[id] ?? 0)
    }

    var sortedChatIds: [String] {
        chats.keys.sorted { a, b in
            let pa = pinned.contains(a), pb = pinned.contains(b)
            if pa != pb { return pa }
            return (chats[a]?.i("ts") ?? 0) > (chats[b]?.i("ts") ?? 0)
        }
    }

    func markRead(_ id: String) {
        guard let c = chats[id] else { return }
        let t = c.i("ts")
        if readMap[id] == t { return }
        readMap[id] = t
        UserDefaults.standard.set(readMap, forKey: "read")
    }

    func toggle(_ kind: String, _ id: String) {
        if kind == "m" {
            if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
            UserDefaults.standard.set(Array(muted), forKey: "muted")
        } else {
            if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
            UserDefaults.standard.set(Array(pinned), forKey: "pinned")
        }
    }

    // MARK: - Превью последнего сообщения

    func previewText(_ id: String) -> String {
        previews[id] ?? ""
    }

    private func refreshPreviews() {
        for (id, c) in chats {
            let last = c.s("last")
            if prevSig[id] == last, previews[id] != nil { continue }
            if !E2ee.isEnvelope(last) {
                prevSig[id] = last
                previews[id] = last
                continue
            }
            if !E2ee.shared.ready && prevSig[id] == last { continue }
            prevSig[id] = last
            Task { [self] in
                if let p = await E2ee.shared.decryptPreview(chat: id, value: last) {
                    previews[id] = prevText(p)
                } else {
                    previews[id] = "🔒 Сообщение"
                    if !E2ee.shared.ready { prevSig[id] = nil }
                }
            }
        }
    }


    // MARK: - Создание чатов (формат как в Flutter: pages.dart openDm)

    func chatId(_ a: String, _ b: String) -> String { [a, b].sorted().joined(separator: "_") }

    func openDm(_ other: String) async throws -> String {
        let api = Api.shared
        let id = chatId(api.uid, other)
        let ex = try await api.get("chats/\(id)/type")
        if ex == nil {
            let u = users[other] ?? [:]
            let data: J = [
                "type": "dm", "owner": api.uid,
                "members": [api.uid: true, other: true],
                "names": [api.uid: me.s("name"), other: u.s("name")],
                "ts": nowMs(), "last": "",
            ]
            try await api.update([
                "chats/\(id)": data,
                "userChats/\(api.uid)/\(id)": true,
                "userChats/\(other)/\(id)": true,
            ])
            var c = data
            c["id"] = id
            chats[id] = c
        } else {
            try? await api.put("userChats/\(api.uid)/\(id)", true)
        }
        ids.insert(id)
        return id
    }

    func openSaved() async throws -> String {
        let api = Api.shared
        let uid = api.uid
        let id = "\(uid)_\(uid)"
        let ex = try await api.get("chats/\(id)/type")
        if ex == nil {
            let data: J = ["type": "dm", "owner": uid, "members": [uid: true],
                           "names": [uid: me.s("name")], "ts": nowMs(), "last": ""]
            try await api.update(["chats/\(id)": data, "userChats/\(uid)/\(id)": true])
            var c = data
            c["id"] = id
            chats[id] = c
        } else {
            try await api.put("userChats/\(uid)/\(id)", true)
        }
        ids.insert(id)
        return id
    }

    /// Pull-to-refresh: перечитать свои чаты и собеседников.
    func reloadAll() async {
        let api = Api.shared
        if let uc = (try? await api.get("userChats/\(api.uid)")) as? J {
            ids = Set(uc.keys)
            await fetchChats(Array(ids))
        }
        refreshPeers(force: true)
    }

    // MARK: - Присутствие

    private func beat() {
        let api = Api.shared
        let uid = api.uid, did = api.did
        if uid.isEmpty { return }
        Task { [self] in
            do {
                let d = try await api.get("devices/\(uid)/\(did)")
                if d == nil { kick(); return }
                try await api.patch("devices/\(uid)/\(did)", ["last": SV])
                if fg { await api.presence(true) }
            } catch {
                let s = "\(error)"
                if s.contains("db 401") || s.contains("db 403") { kick() }
            }
        }
    }

    var fg = true

    func setForeground(_ v: Bool) {
        fg = v
        if running { Task { await Api.shared.presence(v) } }
    }

    func kick() {
        if Api.shared.uid.isEmpty { return }
        stop()
        Api.shared.logout()
        onKick?()
    }
}
