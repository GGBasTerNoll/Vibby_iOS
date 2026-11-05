import Foundation
import SwiftUI

/// Вход в аккаунт: те же шаги, что и в Flutter-клиенте
/// (пароль → подтверждение почты → разрешение с другого устройства → профиль).
@MainActor
final class Session: ObservableObject {
    enum Step { case boot, form, verify, approve, handle, legacy, reset, done }

    @Published var step: Step = .boot
    @Published var busy = false
    @Published var err = ""
    @Published var register = false
    @Published var email = ""
    @Published var pass = ""
    @Published var handle = ""
    @Published var name = ""
    @Published var newPass = ""
    @Published var cooldown = 0

    private var poll: Task<Void, Never>?
    private var trusted = false
    private var resetMail = ""
    private let api = Api.shared

    private static let mailRe = try! NSRegularExpression(pattern: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")
    private static let handleRe = try! NSRegularExpression(pattern: "^[a-z0-9_]{3,20}$")

    private func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func boot() async {
        if await api.restore() {
            Store.shared.onKick = { [weak self] in self?.signedOut("Сеанс завершён") }
            step = .done
            await Store.shared.start()
        } else {
            step = .form
        }
    }

    private func signedOut(_ msg: String) {
        poll?.cancel()
        step = .form
        err = msg
        busy = false
        pass = ""
    }

    func submit() async {
        let id = email.trimmingCharacters(in: .whitespaces).lowercased()
        if register {
            if !matches(Session.mailRe, id) { err = "Введите настоящую почту"; return }
            if !matches(Session.handleRe, handle.trimmingCharacters(in: .whitespaces).lowercased()) {
                err = "Логин: 3–20 символов, a-z, 0-9, _"
                return
            }
        } else if id.isEmpty {
            err = "Введите почту"
            return
        }
        busy = true
        err = ""
        do {
            try await api.auth(id, pass, signUp: register)
            await after()
        } catch {
            fail(error)
        }
    }

    private func fail(_ e: Error) {
        busy = false
        let s = "\(e.localizedDescription)"
        if s.contains("INVALID_LOGIN_CREDENTIALS") || s.contains("INVALID_PASSWORD") || s.contains("EMAIL_NOT_FOUND") {
            err = "Неверная почта или пароль"
        } else if s.contains("EMAIL_EXISTS") {
            err = "Эта почта уже зарегистрирована"
        } else if s.contains("WEAK_PASSWORD") {
            err = "Пароль слишком короткий (минимум 6 символов)"
        } else if s.contains("TOO_MANY_ATTEMPTS") {
            err = "Слишком много попыток, попробуйте позже"
        } else {
            err = s
        }
    }

    private func after() async {
        if api.legacyMail { step = .legacy; busy = false; return }
        if !api.verified { await startVerify(); return }
        await device()
    }

    func startVerify() async {
        step = .verify
        busy = false
        err = ""
        do { try await api.sendVerify() } catch { err = error.localizedDescription }
        startCooldown()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let ok = try? await self.api.emailVerifiedNow(), ok {
                    try? await self.api.refreshNow()
                    await self.device()
                    return
                }
            }
        }
    }

    func resend() async {
        do { try await api.sendVerify(); startCooldown() } catch { err = error.localizedDescription }
    }

    private func startCooldown() {
        cooldown = 45
        Task { [weak self] in
            while let self, self.cooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.cooldown -= 1
            }
        }
    }

    /// Если аккаунт уже открыт на другом устройстве — ждём «Разрешить» там.
    private func device() async {
        poll?.cancel()
        let uid = api.uid, did = api.did
        do {
            let dv = (try await api.get("devices/\(uid)") as? J) ?? [:]
            let others = dv.filter { $0.key != did && (($0.value as? J)?.i("last") ?? 0) > nowMs() - 30 * 86_400_000 }
            if dv[did] != nil || others.isEmpty || trusted {
                await finish()
                return
            }
            try await api.put("approvals/\(uid)/\(did)", ["name": api.dname, "ts": SV, "status": "wait"] as J)
            step = .approve
            busy = false
            err = ""
            let t0 = nowMs()
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    let s = (try? await self.api.get("approvals/\(uid)/\(did)/status")) as? String
                    if s == "ok" { await self.finish(); return }
                    if s == "no" { await self.back("Вход отклонён с другого устройства"); return }
                    if nowMs() - t0 > 600_000 { await self.back("Время ожидания истекло"); return }
                }
            }
        } catch {
            fail(error)
        }
    }

    func viaMail() async {
        busy = true
        do {
            resetMail = api.mail
            try await api.sendReset(resetMail)
            poll?.cancel()
            step = .reset
            busy = false
            newPass = ""
            startCooldown()
        } catch { fail(error) }
    }

    func relogin() async {
        busy = true
        err = ""
        do {
            try await api.auth(resetMail, newPass, signUp: false)
            trusted = true
            await device()
        } catch { fail(error) }
    }

    func finish() async {
        let uid = api.uid, did = api.did
        do {
            let u = try await api.get("users/\(uid)") as? J
            if u == nil {
                let hd = handle.trimmingCharacters(in: .whitespaces).lowercased()
                if !matches(Session.handleRe, hd) { step = .handle; busy = false; return }
                do { try await api.put("logins/\(hd)", uid) } catch {
                    step = .handle
                    busy = false
                    err = "Этот логин занят — выберите другой"
                    return
                }
                let nm = name.trimmingCharacters(in: .whitespaces)
                try await api.put("users/\(uid)", ["login": hd, "name": nm.isEmpty ? hd : nm, "seen": SV] as J)
            } else if let l = u?["login"] as? String {
                Task { try? await Api.shared.put("logins/\(l)", uid) }
            }
            try await api.put("devices/\(uid)/\(did)", ["name": api.dname, "ts": SV, "last": SV] as J)
            Task { _ = try? await Api.shared.del("approvals/\(uid)/\(did)") }
            poll?.cancel()
            api.commit()
            Store.shared.onKick = { [weak self] in self?.signedOut("Сеанс завершён") }
            step = .done
            busy = false
            await Store.shared.start()
        } catch { fail(error) }
    }

    func back(_ msg: String = "") async {
        poll?.cancel()
        _ = try? await api.del("approvals/\(api.uid)/\(api.did)")
        await api.signOutDevice()
        step = .form
        err = msg
        busy = false
        trusted = false
    }

    func signOut() async {
        Store.shared.stop()
        await api.signOutDevice()
        step = .form
        pass = ""
        err = ""
    }
}
