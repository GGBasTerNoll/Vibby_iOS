import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var seedInput = ""
    @State private var msg = ""
    @State private var showSeed = false
    @State private var filesInfo = ""
    @State private var manual = UserDefaults.standard.string(forKey: "files_manual") ?? ""
    @State private var confirmOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Аккаунт") {
                    HStack(spacing: 12) {
                        AvatarView(id: Api.shared.uid, name: store.me.s("name"), size: 48)
                        VStack(alignment: .leading) {
                            Text(store.me.s("name")).font(.headline)
                            if !store.me.s("login").isEmpty {
                                Text("@\(store.me.s("login"))").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(Api.shared.mail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !store.role.isEmpty { LabeledContent("Роль", value: store.role.uppercased()) }
                }

                Section("Шифрование (E2EE)") {
                    LabeledContent("Отпечаток", value: E2ee.shared.fingerprint())
                    LabeledContent("Состояние", value: E2ee.shared.ready ? "активно" : "не готово")
                    Button("Показать ключ для резервной копии") { showSeed = true }
                    TextField("Вставить ключ с другого устройства", text: $seedInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Импортировать ключ") {
                        Task {
                            let ok = await E2ee.shared.importSeed(seedInput)
                            msg = ok ? "Ключ импортирован" : "Неверный ключ"
                            if ok { seedInput = "" }
                        }
                    }.disabled(seedInput.isEmpty)
                    Text("Импорт нужен, чтобы читать историю, зашифрованную для другого вашего устройства.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Файловый сервер") {
                    TextField("Адрес вручную (необязательно)", text: $manual)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Применить и проверить") { Task { await checkFiles() } }
                    if !filesInfo.isEmpty { Text(filesInfo).font(.footnote).foregroundStyle(.secondary) }
                    LabeledContent("Сейчас", value: Api.shared.fileBase.isEmpty ? "не задан" : Api.shared.fileBase)
                }

                Section("Кэш") {
                    Button("Очистить кэш картинок") {
                        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("vibby-img")
                        try? FileManager.default.removeItem(at: d)
                        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                        ImageLoader.shared.mem.removeAllObjects()
                        msg = "Кэш очищен"
                    }
                }

                if !msg.isEmpty { Section { Text(msg).font(.footnote) } }

                Section {
                    Button("Выйти из аккаунта", role: .destructive) { confirmOut = true }
                }
            }
            .navigationTitle("Настройки")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .alert("Ключ шифрования", isPresented: $showSeed) {
                Button("Копировать") { UIPasteboard.general.string = E2ee.shared.seedB64 }
                Button("Закрыть", role: .cancel) {}
            } message: {
                Text("Храните в тайне. Любой, у кого есть этот ключ, сможет читать ваши сообщения.\n\n\(E2ee.shared.seedB64)")
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) {
                    dismiss()
                    Task { await session.signOut() }
                }
            }
        }
    }

    func checkFiles() async {
        let d = UserDefaults.standard
        let n = Api.normBase(manual)
        if n.isEmpty { d.removeObject(forKey: "files_manual") } else { d.set(n, forKey: "files_manual") }
        let base = await Api.shared.loadFiles(force: true)
        guard !base.isEmpty, let url = URL(string: base + "/health") else {
            filesInfo = "Адрес не найден (config/files в Firebase пуст)"
            return
        }
        var rq = URLRequest(url: url)
        rq.timeoutInterval = 12
        if let (_, r) = try? await URLSession.shared.data(for: rq), (r as? HTTPURLResponse)?.statusCode == 200 {
            filesInfo = "Сервер доступен ✓"
        } else {
            filesInfo = "Сервер не отвечает"
        }
        store.filesTick += 1
    }
}
