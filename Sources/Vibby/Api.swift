import Foundation
import UIKit

/// Firebase Auth + Realtime Database по REST — тот же протокол, что и в Flutter-клиенте.
@MainActor
final class Api {
    static let shared = Api()

    private(set) var uid = ""
    private(set) var did = ""
    let dname: String
    var fileBase = ""

    private var tokStr = ""
    private var refTok = ""
    private var exp = Date.distantPast
    private var keep = false
    private var refreshing: Task<String, Error>?
    nonisolated let session: URLSession

    private let idt = "https://identitytoolkit.googleapis.com/v1/accounts"

    private init() {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
        let d = UserDefaults.standard
        fileBase = d.string(forKey: "files") ?? ""
        if let s = d.string(forKey: "did"), !s.isEmpty {
            did = s
        } else {
            did = "d" + Api.nid()
            d.set(did, forKey: "did")
        }
        dname = "iOS · \(UIDevice.current.model)"
    }

    nonisolated static func nid() -> String {
        String(Int(Date().timeIntervalSince1970 * 1_000_000)) + String(format: "%03d", Int.random(in: 0..<999))
    }

    // MARK: - Токен

    private func claims() -> J {
        let parts = tokStr.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? J else { return [:] }
        return j
    }

    var verified: Bool { claims().b("email_verified") }
    var mail: String { claims().s("email") }
    var legacyMail: Bool { mail.hasSuffix("@vibby.app") }
    var signedIn: Bool { !uid.isEmpty && !refTok.isEmpty }

    func restore() async -> Bool {
        let d = UserDefaults.standard
        refTok = Secrets.get("ref") ?? ""
        uid = d.string(forKey: "uid") ?? ""
        if refTok.isEmpty { return false }
        keep = true
        do {
            _ = try await tok()
            return verified
        } catch {
            return !(error is VErr)
        }
    }

    func commit() {
        keep = true
        store()
    }

    private func store() {
        Secrets.set(refTok, "ref")
        UserDefaults.standard.set(uid, forKey: "uid")
    }

    private func save(_ j: J, _ a: String, _ b: String, _ c: String) {
        tokStr = j.s(a)
        refTok = j.s(b)
        exp = Date().addingTimeInterval(TimeInterval((Int(j.s(c)) ?? 3600) - 60))
        if keep && verified { store() }
    }

    private func post(_ u: String, json: Any? = nil, form: String? = nil,
                      headers: [String: String] = [:]) async throws -> J {
        guard let url = URL(string: u) else { throw VErr(msg: "bad url") }
        var rq = URLRequest(url: url)
        rq.httpMethod = "POST"
        for (k, v) in headers { rq.setValue(v, forHTTPHeaderField: k) }
        if let form {
            rq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            rq.httpBody = Data(form.utf8)
        } else if let json {
            rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            rq.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await session.data(for: rq)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = ((try? JSONSerialization.jsonObject(with: data)) as? J) ?? [:]
        if code != 200 {
            let e = j["error"]
            if let em = e as? J { throw VErr(msg: em.s("message")) }
            throw VErr(msg: (e as? String) ?? "HTTP \(code)")
        }
        return j
    }

    func auth(_ id: String, _ pass: String, signUp: Bool) async throws {
        keep = false
        let t = id.trimmingCharacters(in: .whitespaces).lowercased()
        let em = t.contains("@") ? t : "\(t)@vibby.app"
        let j = try await post("\(idt):\(signUp ? "signUp" : "signInWithPassword")?key=\(Cfg.apiKey)",
                               json: ["email": em, "password": pass, "returnSecureToken": true])
        uid = j.s("localId")
        save(j, "idToken", "refreshToken", "expiresIn")
    }

    func tok() async throws -> String {
        if Date() < exp, !tokStr.isEmpty { return tokStr }
        if let t = refreshing { return try await t.value }
        let t = Task { () -> String in
            let enc = self.refTok.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self.refTok
            let j = try await self.post("https://securetoken.googleapis.com/v1/token?key=\(Cfg.apiKey)",
                                        form: "grant_type=refresh_token&refresh_token=\(enc)")
            self.uid = j.s("user_id")
            self.save(j, "id_token", "refresh_token", "expires_in")
            return self.tokStr
        }
        refreshing = t
        defer { refreshing = nil }
        return try await t.value
    }

    func refreshNow() async throws {
        exp = .distantPast
        _ = try await tok()
    }

    func emailVerifiedNow(_ want: String? = nil) async throws -> Bool {
        let j = try await post("\(idt):lookup?key=\(Cfg.apiKey)", json: ["idToken": try await tok()])
        guard let u = (j["users"] as? [Any])?.first as? J else { return false }
        return u.b("emailVerified") && (want == nil || u.s("email").lowercased() == want)
    }

    func sendVerify() async throws {
        _ = try await post("\(idt):sendOobCode?key=\(Cfg.apiKey)",
                           json: ["requestType": "VERIFY_EMAIL", "idToken": try await tok()],
                           headers: ["X-Firebase-Locale": "ru"])
    }

    func sendReset(_ email: String) async throws {
        _ = try await post("\(idt):sendOobCode?key=\(Cfg.apiKey)",
                           json: ["requestType": "PASSWORD_RESET", "email": email],
                           headers: ["X-Firebase-Locale": "ru"])
    }

    func changePass(_ p: String) async throws {
        let j = try await post("\(idt):update?key=\(Cfg.apiKey)",
                               json: ["idToken": try await tok(), "password": p, "returnSecureToken": true])
        save(j, "idToken", "refreshToken", "expiresIn")
    }

    func logout() {
        keep = false
        Secrets.remove("ref")
        UserDefaults.standard.removeObject(forKey: "uid")
        refTok = ""
        tokStr = ""
        uid = ""
        exp = .distantPast
    }

    func signOutDevice() async {
        if !uid.isEmpty { _ = try? await del("devices/\(uid)/\(did)") }
        logout()
    }

    // MARK: - Realtime Database

    func req(_ m: String, _ p: String, body: Any? = nil, hasBody: Bool = false,
             q: [String: String] = [:]) async throws -> Any? {
        let t = try await tok()
        var c = URLComponents()
        c.scheme = "https"
        c.host = Cfg.dbHost
        c.path = "/\(p).json"
        var items = [URLQueryItem(name: "auth", value: t)]
        for (k, v) in q { items.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = items
        guard let url = c.url else { throw VErr(msg: "bad path") }
        var rq = URLRequest(url: url)
        rq.httpMethod = m
        if hasBody {
            rq.httpBody = try JSONSerialization.data(withJSONObject: body ?? NSNull(), options: [.fragmentsAllowed])
            rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: rq)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 300 { throw VErr(msg: "db \(code): \(String(data: data, encoding: .utf8) ?? "")") }
        return await Api.parse(data)
    }

    /// Разбор JSON вне главного потока — большие ответы не подвешивают интерфейс.
    nonisolated static func parse(_ d: Data) async -> Any? {
        if d.isEmpty { return nil }
        guard let r = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return nil }
        return r is NSNull ? nil : r
    }

    func get(_ p: String, q: [String: String] = [:]) async throws -> Any? { try await req("GET", p, q: q) }
    func put(_ p: String, _ v: Any?) async throws { _ = try await req("PUT", p, body: v, hasBody: true) }
    func patch(_ p: String, _ v: J) async throws { _ = try await req("PATCH", p, body: v, hasBody: true) }
    func del(_ p: String) async throws -> Any? { try await req("DELETE", p) }
    func update(_ v: [String: Any?]) async throws {
        var o: J = [:]
        for (k, x) in v { o[k] = x ?? NSNull() }
        _ = try await req("PATCH", "", body: o, hasBody: true)
    }

    func presence(_ online: Bool) async {
        guard !uid.isEmpty else { return }
        let seen: Any = online ? (SV as Any) : (nowMs() as Any)
        _ = try? await patch("users/\(uid)", ["online": online, "seen": seen])
    }

    // MARK: - Файловый сервер

    nonisolated static func normBase(_ raw: Any?) -> String {
        var v = ""
        if let s = raw as? String {
            v = s
        } else if let m = raw as? J {
            for k in ["url", "value", "base", "files", "address"] {
                if let s = m[k] as? String { v = s; break }
            }
        }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "'\"` \n\t"))
        if v.isEmpty { return "" }
        if !v.lowercased().hasPrefix("http://") && !v.lowercased().hasPrefix("https://") { v = "https://" + v }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    @discardableResult
    func loadFiles(force: Bool = false) async -> String {
        let d = UserDefaults.standard
        if let m = d.string(forKey: "files_manual"), !m.isEmpty { fileBase = m; return m }
        if !force && !fileBase.isEmpty { return fileBase }
        if let r = try? await get("config/files") {
            let v = Api.normBase(r)
            if !v.isEmpty {
                fileBase = v
                d.set(v, forKey: "files")
            }
        }
        return fileBase
    }

    func fileUrl(_ id: String) -> URL? {
        if id.isEmpty || fileBase.isEmpty { return nil }
        return URL(string: "\(fileBase)/f/\(id)")
    }

    func upload(_ data: Data, name: String, mime: String) async throws -> J {
        let base = await loadFiles()
        guard !base.isEmpty, let url = URL(string: base + "/upload") else {
            throw VErr(msg: "Отправка файлов сейчас недоступна")
        }
        var rq = URLRequest(url: url)
        rq.httpMethod = "POST"
        rq.timeoutInterval = 300
        rq.setValue("Bearer \(try await tok())", forHTTPHeaderField: "Authorization")
        let n = Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        rq.setValue(n, forHTTPHeaderField: "X-File-Name")
        rq.setValue(mime, forHTTPHeaderField: "X-File-Type")
        rq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await session.upload(for: rq, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = ((try? JSONSerialization.jsonObject(with: d)) as? J) ?? [:]
        if code != 200 { throw VErr(msg: j["error"] as? String ?? "HTTP \(code)") }
        return j
    }

    /// Просит сервер отправить FCM-уведомление получателям (ошибки глотаем).
    func pushMessage(chat: String, uids: [String], title: String, body: String) async {
        if uids.isEmpty { return }
        let base = await loadFiles()
        guard !base.isEmpty, let url = URL(string: base + "/push"), let t = try? await tok() else { return }
        var rq = URLRequest(url: url)
        rq.httpMethod = "POST"
        rq.timeoutInterval = 12
        rq.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rq.httpBody = try? JSONSerialization.data(withJSONObject:
            ["chat": chat, "uids": uids, "title": title, "body": body])
        _ = try? await session.data(for: rq)
    }
}
