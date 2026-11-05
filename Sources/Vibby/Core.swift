import Foundation
import Security
import UIKit

enum Cfg {
    static let apiKey = "AIzaSyBOqQGSCsCD_cVUrpDsQwBl1nnqYqV5tWQ"
    static let dbHost = "vibby-b1913-default-rtdb.europe-west1.firebasedatabase.app"
}

typealias J = [String: Any]
let SV: J = [".sv": "timestamp"]

func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

struct VErr: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String {
        if let v = self[k] as? String { return v }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return ""
    }
    func i(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func b(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
    func d(_ k: String) -> J { (self[k] as? J) ?? [:] }
}

/// Keychain с запасным вариантом в UserDefaults (для переподписанных IPA).
enum Secrets {
    private static let svc = "app.vibby.secrets"

    private static func base(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: svc,
         kSecAttrAccount as String: k]
    }

    static func set(_ v: String, _ k: String) {
        let b = base(k)
        SecItemDelete(b as CFDictionary)
        var add = b
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: "sec_" + k)
        } else {
            UserDefaults.standard.set(v, forKey: "sec_" + k)
        }
    }

    static func get(_ k: String) -> String? {
        var q = base(k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: "sec_" + k)
    }

    static func remove(_ k: String) {
        SecItemDelete(base(k) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "sec_" + k)
    }
}

/// JSON-кэш на диске: списки чатов, пользователи, последние сообщения.
/// Благодаря ему интерфейс рисуется мгновенно, пока сеть догружает свежие данные.
enum Disk {
    static let dir: URL = {
        let u = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vibby", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func write(_ name: String, _ obj: Any) {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let url = dir.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async {
            try? d.write(to: url, options: .atomic)
        }
    }

    static func read(_ name: String) -> Any? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

// MARK: - Форматирование

func hm(_ ms: Int) -> String {
    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

func listTime(_ ms: Int) -> String {
    if ms <= 0 { return "" }
    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
    let cal = Calendar.current
    if cal.isDateInToday(d) { return hm(ms) }
    if cal.isDateInYesterday(d) { return "вчера" }
    let f = DateFormatter()
    f.dateFormat = "dd.MM.yy"
    return f.string(from: d)
}

func humanSize(_ bytes: Int) -> String {
    if bytes <= 0 { return "0 Б" }
    let units = ["Б", "КБ", "МБ", "ГБ"]
    var v = Double(bytes)
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return (v >= 10 || i == 0) ? "\(Int(v.rounded())) \(units[i])" : String(format: "%.1f %@", v, units[i])
}

func mimeOf(_ name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    let m: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "mp4": "video/mp4", "mov": "video/quicktime",
        "m4a": "audio/mp4", "mp3": "audio/mpeg", "aac": "audio/aac", "wav": "audio/wav",
        "pdf": "application/pdf", "zip": "application/zip", "txt": "text/plain",
    ]
    return m[ext] ?? "application/octet-stream"
}

/// Краткий текст сообщения для списка чатов (повторяет prev() из Flutter-версии).
func prevText(_ m: J) -> String {
    let t = m.s("t")
    let s: String
    switch t {
    case "img": s = "📷 Фото"
    case "voice": s = "🎤 Голосовое"
    case "video": s = m.b("round") ? "⭕ Кружок" : "🎬 \(m["n"] == nil ? "Видео" : m.s("n"))"
    case "file": s = "📎 \(m["n"] == nil ? "Файл" : m.s("n"))"
    case "sticker": s = m["sfid"] != nil ? "🖼 Стикер" : "\(m.s("d")) Стикер"
    case "poll": s = "📊 \(m.s("p"))"
    default: s = m.s("d")
    }
    return s.count > 60 ? String(s.prefix(60)) : s
}
