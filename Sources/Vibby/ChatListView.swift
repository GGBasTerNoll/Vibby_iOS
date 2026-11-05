import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showSettings = false

    private var ids: [String] {
        let all = store.sortedChatIds
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return all }
        return all.filter { store.title(store.chats[$0] ?? [:]).lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.chats.isEmpty && !store.loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                }
                ForEach(ids, id: \.self) { id in
                    if let c = store.chats[id] {
                        NavigationLink(value: id) { Row(id: id, chat: c) }
                            .swipeActions(edge: .leading) {
                                Button { store.toggle("p", id) } label: {
                                    Label(store.pinned.contains(id) ? "Открепить" : "Закрепить", systemImage: "pin")
                                }.tint(.orange)
                            }
                            .swipeActions(edge: .trailing) {
                                Button { store.toggle("m", id) } label: {
                                    Label(store.muted.contains(id) ? "Со звуком" : "Без звука", systemImage: "bell.slash")
                                }.tint(.gray)
                            }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Поиск")
            .navigationTitle("Чаты")
            .navigationDestination(for: String.self) { id in ChatView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showNew) {
                NewChatView { id in
                    showNew = false
                    path.append(id)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await store.reloadAll() }
        }
        .task { Stickers.shared.start() }
    }
}

private struct Row: View {
    @EnvironmentObject var store: Store
    let id: String
    let chat: J

    var body: some View {
        let title = store.title(chat)
        let unread = store.isUnread(id)
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(id: store.avatarId(chat), name: title, size: 52)
                if chat.s("type") == "dm", store.online(store.peer(chat)) {
                    Circle().fill(.green).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title).font(.headline).lineLimit(1)
                    if store.verifiedName(chat) {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.tint)
                    }
                    if store.muted.contains(id) {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(listTime(chat.i("ts"))).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(store.previewText(id)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if store.pinned.contains(id) {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if unread {
                        Circle().fill(store.muted.contains(id) ? Color.gray : Color.accentColor).frame(width: 10, height: 10)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Новый личный чат по логину (или «Избранное»).
struct NewChatView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let open: (String) -> Void
    @State private var login = ""
    @State private var err = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Личный чат по логину") {
                    TextField("логин", text: $login)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { Task { await go() } } label: {
                        HStack { if busy { ProgressView() }; Text("Открыть чат") }
                    }.disabled(login.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    if !err.isEmpty { Text(err).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button("Избранное") { Task { await saved() } }
                }
            }
            .navigationTitle("Новый чат")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    func go() async {
        busy = true
        err = ""
        defer { busy = false }
        let h = login.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        guard let uid = (try? await Api.shared.get("logins/\(h)")) as? String, !uid.isEmpty else {
            err = "Пользователь не найден"
            return
        }
        if uid == Api.shared.uid { await saved(); return }
        store.ensureUser(uid)
        do { open(try await store.openDm(uid)) } catch { err = error.localizedDescription }
    }

    func saved() async {
        do { open(try await store.openSaved()) } catch { err = error.localizedDescription }
    }
}
