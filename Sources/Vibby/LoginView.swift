import SwiftUI

struct LoginView: View {
    @EnvironmentObject var s: Session

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .padding(.top, 48)
                Text("Vibby").font(.largeTitle.bold())
                content
                if !s.err.isEmpty {
                    Text(s.err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder var content: some View {
        switch s.step {
        case .boot:
            ProgressView().padding(.top, 24)
        case .form:
            form
        case .verify:
            info("Подтвердите почту", "Мы отправили письмо со ссылкой на \(s.email). Откройте её — приложение продолжит само.")
            Button(s.cooldown > 0 ? "Отправить ещё раз (\(s.cooldown))" : "Отправить ещё раз") {
                Task { await s.resend() }
            }.disabled(s.cooldown > 0)
            Button("Назад") { Task { await s.back() } }
        case .approve:
            info("Подтвердите вход", "Откройте Vibby на другом устройстве и нажмите «Разрешить» в служебных уведомлениях.")
            ProgressView()
            Button("Нет доступа к устройству — подтвердить по почте") { Task { await s.viaMail() } }
                .font(.footnote)
            Button("Отмена") { Task { await s.back() } }
        case .handle:
            info("Профиль", "Выберите логин и имя.")
            field("Логин (a-z, 0-9, _)", text: $s.handle, auto: false)
            field("Имя", text: $s.name, auto: true)
            primary("Продолжить") { await s.finish() }
        case .legacy:
            info("Нужна почта", "Этот аккаунт создан по логину. Привяжите настоящую почту в версии Vibby для Android или Windows, затем войдите здесь.")
            Button("Назад") { Task { await s.back() } }
        case .reset:
            info("Проверьте почту", "Мы отправили ссылку для сброса пароля. Задайте новый пароль по ссылке и введите его ниже.")
            SecureField("Новый пароль", text: $s.newPass).textFieldStyle(.roundedBorder)
            primary("Войти") { await s.relogin() }
        case .done:
            EmptyView()
        }
    }

    var form: some View {
        VStack(spacing: 12) {
            Picker("", selection: $s.register) {
                Text("Вход").tag(false)
                Text("Регистрация").tag(true)
            }.pickerStyle(.segmented)
            field("Почта", text: $s.email, auto: false, kb: .emailAddress)
            if s.register {
                field("Логин (a-z, 0-9, _)", text: $s.handle, auto: false)
                field("Имя", text: $s.name, auto: true)
            }
            SecureField("Пароль", text: $s.pass).textFieldStyle(.roundedBorder)
            primary(s.register ? "Создать аккаунт" : "Войти") { await s.submit() }
        }
    }

    func field(_ ph: String, text: Binding<String>, auto: Bool, kb: UIKeyboardType = .default) -> some View {
        TextField(ph, text: text)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(auto ? .words : .never)
            .autocorrectionDisabled(!auto)
            .keyboardType(kb)
    }

    func info(_ t: String, _ b: String) -> some View {
        VStack(spacing: 8) {
            Text(t).font(.title3.bold())
            Text(b).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    func primary(_ t: String, _ a: @escaping () async -> Void) -> some View {
        Button {
            Task { await a() }
        } label: {
            HStack {
                if s.busy { ProgressView().tint(.white) }
                Text(t).bold()
            }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(s.busy)
    }
}
