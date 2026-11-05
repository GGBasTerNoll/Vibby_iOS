import Foundation
import CryptoKit

struct Sealed {
    let env: J
    let preview: String?
}

/// Сквозное шифрование — бинарно совместимо с lib/e2ee.dart:
/// X25519 (ключ устройства) → HKDF-SHA256 (info "vibby-key-v1") → AES-256-GCM.
/// Ключ сообщения заворачивается отдельно для каждого устройства участников.
@MainActor
final class E2ee {
    static let shared = E2ee()
    static let prefix = "vibby1:"

    private var priv: Curve25519.KeyAgreement.PrivateKey?
    private(set) var pubB64 = ""
    private(set) var ready = false
    private(set) var lastError: String?
    private(set) var lastSkip: String?
    private var booting: Task<Void, Never>?
    private var bootUid = ""

    private var peerAt: [String: Date] = [:]
    private var peerCache: [String: [String: String]] = [:]

    static func isEnvelope(_ s: String) -> Bool { s.hasPrefix(prefix) }

    func boot() async {
        let api = Api.shared
        if bootUid != api.uid || booting == nil {
            bootUid = api.uid
            booting = Task { await self.doBoot() }
        }
        await booting?.value
    }

    private func doBoot() async {
        ready = false
        lastError = nil
        let api = Api.shared
        let uid = api.uid, did = api.did
        if uid.isEmpty || did.isEmpty { return }
        let skey = "e2ee_seed_\(uid)"
        var key: Curve25519.KeyAgreement.PrivateKey
        if let s = Secrets.get(skey), let d = Data(base64Encoded: s), d.count == 32,
           let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) {
            key = k
        } else {
            key = Curve25519.KeyAgreement.PrivateKey()
            Secrets.set(key.rawRepresentation.base64EncodedString(), skey)
        }
        priv = key
        pubB64 = key.publicKey.rawRepresentation.base64EncodedString()
        do {
            try await api.put("users/\(uid)/keys/\(did)", pubB64)
            peerCache[uid] = nil
            peerAt[uid] = nil
            ready = true
        } catch {
            lastError = "\(error)"
            ready = false
        }
    }

    var seedB64: String { priv?.rawRepresentation.base64EncodedString() ?? "" }

    func fingerprint() -> String {
        guard let d = Data(base64Encoded: pubB64) else { return "" }
        return SHA256.hash(data: d).prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    /// Импорт seed с другого устройства — чтобы читать старую историю.
    func importSeed(_ value: String) async -> Bool {
        guard let raw = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == 32,
              let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return false }
        let api = Api.shared
        Secrets.set(raw.base64EncodedString(), "e2ee_seed_\(api.uid)")
        priv = k
        pubB64 = k.publicKey.rawRepresentation.base64EncodedString()
        do {
            try await api.put("users/\(api.uid)/keys/\(api.did)", pubB64)
        } catch { return false }
        peerCache[api.uid] = nil
        peerAt[api.uid] = nil
        ready = true
        lastError = nil
        return true
    }

    private func rand(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { p in
            _ = SecRandomCopyBytes(kSecRandomDefault, n, p.baseAddress!)
        }
        return d
    }

    private func keysOf(_ uid: String) async -> [String: String] {
        let api = Api.shared
        if let at = peerAt[uid], Date().timeIntervalSince(at) < 120 {
            return peerCache[uid] ?? [:]
        }
        var m: [String: String] = [:]
        do {
            if let r = try await api.get("users/\(uid)/keys") as? J {
                for (k, v) in r { if let s = v as? String, !s.isEmpty { m[k] = s } }
            }
            peerCache[uid] = m
            peerAt[uid] = Date()
        } catch {
            return [:]
        }
        if uid == api.uid, !pubB64.isEmpty { m[api.did] = pubB64 }
        return m
    }

    private func recipients(members: [String], missing: inout Set<String>) async -> [String: [String: String]] {
        let api = Api.shared
        var all = Set(members.filter { !$0.isEmpty })
        all.insert(api.uid)
        var out: [String: [String: String]] = [:]
        for u in all {
            let k = await keysOf(u)
            if !k.isEmpty { out[u] = k } else if u != api.uid { missing.insert(u) }
        }
        return out
    }

    private func derive(_ remote: Data, salt: Data) throws -> SymmetricKey {
        guard let priv else { throw VErr(msg: "no key") }
        let rp = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
        let shared = try priv.sharedSecretFromKeyAgreement(with: rp)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                              sharedInfo: Data("vibby-key-v1".utf8), outputByteCount: 32)
    }

    private func wrap(chat: String, uid: String, did: String, pub: Data, key: Data) throws -> String {
        let salt = rand(16)
        let k = try derive(pub, salt: salt)
        let box = try AES.GCM.seal(key, using: k, nonce: AES.GCM.Nonce(data: rand(12)),
                                   authenticating: Data("\(chat)|\(uid)|\(did)".utf8))
        return "1.\(salt.base64EncodedString()).\(Data(box.nonce).base64EncodedString())."
            + "\(box.tag.base64EncodedString()).\(box.ciphertext.base64EncodedString())"
    }

    private func unwrap(chat: String, uid: String, did: String, pub: Data, box: String) throws -> Data {
        let p = box.components(separatedBy: ".")
        guard p.count == 5, p[0] == "1",
              let salt = Data(base64Encoded: p[1]), let nonce = Data(base64Encoded: p[2]),
              let tag = Data(base64Encoded: p[3]), let ct = Data(base64Encoded: p[4]) else {
            throw VErr(msg: "bad key box")
        }
        let k = try derive(pub, salt: salt)
        let sb = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
        return try AES.GCM.open(sb, using: k, authenticating: Data("\(chat)|\(uid)|\(did)".utf8))
    }

    private func open(chat: String, env: J) async -> J? {
        await boot()
        guard ready, priv != nil else { return nil }
        let api = Api.shared
        let sender = env.s("u"), from = env.s("f")
        if sender.isEmpty || from.isEmpty { return nil }
        guard let km = env.d("k")[api.uid] as? J, let box = km[api.did] as? String else { return nil }
        let keys = await keysOf(sender)
        guard let pub64 = keys[from], let pub = Data(base64Encoded: pub64) else { return nil }
        do {
            let key = try unwrap(chat: chat, uid: api.uid, did: api.did, pub: pub, box: box)
            guard let n = Data(base64Encoded: env.s("n")), let c = Data(base64Encoded: env.s("c")),
                  let m = Data(base64Encoded: env.s("m")) else { return nil }
            let sb = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: n), ciphertext: c, tag: m)
            let clear = try AES.GCM.open(sb, using: SymmetricKey(data: key),
                                         authenticating: Data("\(chat)|\(sender)".utf8))
            return (try? JSONSerialization.jsonObject(with: clear)) as? J
        } catch {
            return nil
        }
    }

    func decryptMessage(chat: String, msg: J) async -> J? {
        guard let env = msg["e"] as? J else { return nil }
        return await open(chat: chat, env: env)
    }

    func decryptPreview(chat: String, value: String) async -> J? {
        guard E2ee.isEnvelope(value),
              let d = Data(base64Encoded: String(value.dropFirst(E2ee.prefix.count))),
              let env = (try? JSONSerialization.jsonObject(with: d)) as? J else { return nil }
        return await open(chat: chat, env: env)
    }

    /// Шифрует содержимое (и превью для списка чатов тем же ключом).
    /// nil — ключи ещё не готовы или не у всех участников есть ключ: тогда
    /// сообщение уходит открытым, как и в остальных клиентах.
    func seal(chat: String, content: J, preview: J?, members: [String]) async -> Sealed? {
        lastSkip = nil
        lastError = nil
        await boot()
        guard ready, priv != nil else { return nil }
        let api = Api.shared
        var missing = Set<String>()
        let rec = await recipients(members: members, missing: &missing)
        if rec.isEmpty { lastSkip = "не удалось получить ключи участников"; return nil }
        if !missing.isEmpty { lastSkip = "не все участники обновили Vibby"; return nil }
        let key = rand(32)
        do {
            let aad = Data("\(chat)|\(api.uid)".utf8)
            let body = try JSONSerialization.data(withJSONObject: content)
            let box = try AES.GCM.seal(body, using: SymmetricKey(data: key),
                                       nonce: AES.GCM.Nonce(data: rand(12)), authenticating: aad)
            var wrapped: J = [:]
            for (u, devs) in rec {
                var dm: J = [:]
                for (d, p) in devs {
                    if let pd = Data(base64Encoded: p), let w = try? wrap(chat: chat, uid: u, did: d, pub: pd, key: key) {
                        dm[d] = w
                    }
                }
                if !dm.isEmpty { wrapped[u] = dm }
            }
            if wrapped.isEmpty { return nil }
            let env: J = [
                "v": 1, "u": api.uid, "f": api.did,
                "n": Data(box.nonce).base64EncodedString(),
                "c": box.ciphertext.base64EncodedString(),
                "m": box.tag.base64EncodedString(),
                "k": wrapped,
            ]
            var pv: String?
            if let preview {
                let pd = try JSONSerialization.data(withJSONObject: preview)
                let pb = try AES.GCM.seal(pd, using: SymmetricKey(data: key),
                                          nonce: AES.GCM.Nonce(data: rand(12)), authenticating: aad)
                var pe = env
                pe["n"] = Data(pb.nonce).base64EncodedString()
                pe["c"] = pb.ciphertext.base64EncodedString()
                pe["m"] = pb.tag.base64EncodedString()
                let js = try JSONSerialization.data(withJSONObject: pe)
                pv = E2ee.prefix + js.base64EncodedString()
            }
            return Sealed(env: env, preview: pv)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }
}
