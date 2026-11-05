import SwiftUI
import PhotosUI
import AVFoundation

struct ChatView: View {
    let id: String
    @EnvironmentObject var store: Store
    @StateObject private var model: ChatModel
    @StateObject private var stickers = Stickers.shared
    @State private var text = ""
    @State private var reply: J?
    @State private var editing: String?
    @State private var showStickers = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewer: Msg?
    @State private var toast = ""
    @State private var lastTyping = 0
    @FocusState private var focus: Bool

    init(id: String) {
        self.id = id
        _model = StateObject(wrappedValue: ChatModel(id: id))
    }

    private var chat: J { store.chats[id] ?? [:] }
    private var me: String { Api.shared.uid }
    private var isChannel: Bool { chat.s("type") == "channel" }
    private var canPost: Bool { !isChannel || chat.s("owner") == me }
    private var isGroup: Bool { chat.s("type") != "dm" }

    var body: some View {
        VStack(spacing: 0) {
            messages
            if !toast.isEmpty {
                Text(toast).font(.footnote).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 4)
            }
            if canPost { composer } else {
                Text("Только владелец может писать в канал").font(.footnote)
                    .foregroundStyle(.secondary).padding(14)
            }
            if showStickers && canPost {
                StickerPanel(onEmoji: { e in
                    showStickers = false
                    run { try await model.send(["t": "sticker", "d": e]) }
                }, onSticker: { pk, it in
                    showStickers = false
                    run {
                        try await model.send(["t": "sticker", "sfid": it.s("id"), "pk": pk,
                                              "m": it["m"] == nil ? "image/png" : it.s("m")])
                    }
                })
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(store.title(chat)).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .onAppear {
            store.openId = id
            model.start()
            stickers.start()
        }
        .onDisappear {
            store.openId = nil
            model.stop()
        }
        .fullScreenCover(item: $viewer) { m in PhotoViewer(msg: m, chatId: id) }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            let list = items
            picked = []
            for it in list { sendPhoto(it) }
        }
    }

    // MARK: - Список сообщений

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.items) { m in
                        Bubble(msg: m, chat: chat, mine: m.uid == me, group: isGroup,
                               readUpTo: model.otherSeen(chat),
                               canDelete: m.uid == me || chat.s("owner") == me,
                               onReply: { reply = ["n": senderName(m), "t": prevText(m.body)] ; focus = true },
                               onEdit: { editing = m.id; text = m.body.s("d"); focus = true },
                               onDelete: { Task { await model.delete(m.id) } },
                               onReact: { e in
                                   model.react(m.id, e, current: m.raw.d("r").s(me).isEmpty ? nil : m.raw.d("r").s(me))
                               },
                               onVote: { i in model.vote(m.id, i) },
                               onOpenImage: { viewer = m })
                        .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.items.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var subtitle: String {
        let t = chat.d("typing").filter { $0.key != me && (($0.value as? NSNumber)?.intValue ?? 0) > nowMs() - 6000 }
        if !t.isEmpty { return "печатает…" }
        if chat.s("type") == "dm" {
            let p = store.peer(chat)
            if p.isEmpty { return "" }
            return store.online(p) ? "в сети" : ""
        }
        let n = chat.d("members").count
        return isChannel ? "канал · \(n)" : "участников: \(n)"
    }

    private func senderName(_ m: Msg) -> String {
        let n = store.users[m.uid]?.s("name") ?? ""
        if !n.isEmpty { return n }
        return m.encrypted ? m.raw.s("n") : (m.type == "text" ? m.raw.s("n") : "")
    }

    // MARK: - Ввод

    private var composer: some View {
        VStack(spacing: 0) {
            if let r = reply {
                banner(icon: "arrowshape.turn.up.left", title: r.s("n"), sub: r.s("t")) { reply = nil }
            }
            if editing != nil {
                banner(icon: "pencil", title: "Редактирование", sub: "") { editing = nil; text = "" }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $picked, maxSelectionCount: 5, matching: .images) {
                    Image(systemName: "photo").font(.title3)
                }
                Button {
                    showStickers.toggle()
                    focus = false
                } label: { Image(systemName: showStickers ? "keyboard" : "face.smiling").font(.title3) }
                TextField("Сообщение", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focus)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .onChange(of: text) { _, _ in
                        if nowMs() - lastTyping > 2500 { lastTyping = nowMs(); model.typing() }
                    }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func banner(icon: String, title: String, sub: String, close: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.bold())
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }.padding(.horizontal, 12).padding(.top, 6)
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        text = ""
        if let k = editing {
            editing = nil
            run { try await model.edit(k, t) }
            return
        }
        let r = reply
        reply = nil
        run { try await model.sendText(t, reply: r) }
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task {
            do { try await f() } catch { flash(error.localizedDescription) }
        }
    }

    private func flash(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == s { toast = "" }
        }
    }

    private func sendPhoto(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else { return }
                // Сжатие вне главного потока: длинная сторона до 1600 px, JPEG 0.82.
                let jpeg = await Task.detached(priority: .userInitiated) { shrinkJPEG(raw, maxSide: 1600, q: 0.82) }.value
                guard let jpeg else { throw VErr(msg: "Не удалось обработать фото") }
                try await model.sendImage(jpeg)
            } catch { flash(error.localizedDescription) }
        }
    }
}

func shrinkJPEG(_ data: Data, maxSide: CGFloat, q: CGFloat) -> Data? {
    guard let img = ImageLoader.downsample(data, Int(maxSide)) else { return nil }
    return img.jpegData(compressionQuality: q)
}

// MARK: - Пузырь сообщения

struct Bubble: View {
    @EnvironmentObject var store: Store
    let msg: Msg
    let chat: J
    let mine: Bool
    let group: Bool
    let readUpTo: Int
    let canDelete: Bool
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReact: (String) -> Void
    let onVote: (Int) -> Void
    let onOpenImage: () -> Void

    private var isChannel: Bool { chat.s("type") == "channel" }
    private var out: Bool { mine && !isChannel }
    private var b: J { msg.body }
    private var isSticker: Bool { msg.type == "sticker" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if out { Spacer(minLength: 48) }
            VStack(alignment: out ? .trailing : .leading, spacing: 2) {
                bubble
                reactions
            }
            if !out { Spacer(minLength: 48) }
        }
        .contextMenu { menu }
    }

    @ViewBuilder private var bubble: some View {
        if isSticker {
            VStack(alignment: .trailing, spacing: 0) {
                if b["sfid"] != nil {
                    FileImage(sfid: b.s("sfid"), px: 360, fit: true).frame(width: 150, height: 150)
                } else {
                    Text(b.s("d")).font(.system(size: 76))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if group && !mine && !isChannel {
                    Text(name).font(.caption.bold()).foregroundStyle(.tint)
                }
                if let rp = b["rp"] as? J {
                    HStack(spacing: 6) {
                        Rectangle().fill(out ? Color.white.opacity(0.7) : Color.accentColor).frame(width: 2.5)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rp.s("n")).font(.caption.bold())
                            Text(rp.s("t")).font(.caption).lineLimit(1).opacity(0.8)
                        }
                    }.frame(height: 34)
                }
                content
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if b.b("ed") || msg.raw.b("ed") { Text("изм.") }
                    Text(hm(msg.ts > 0 ? msg.ts : nowMs()))
                    if out { Image(systemName: msg.ts > 0 && msg.ts <= readUpTo ? "checkmark.circle.fill" : "checkmark") }
                }
                .font(.system(size: 10))
                .opacity(0.7)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(out ? Color.white : Color.primary)
            .background(out ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var name: String {
        let n = store.users[msg.uid]?.s("name") ?? ""
        if !n.isEmpty { return n }
        return msg.raw.s("n")
    }

    @ViewBuilder private var content: some View {
        switch msg.state {
        case .pending:
            ProgressView().controlSize(.small).frame(width: 40, height: 20)
        case .failed:
            Text("🔒 Сообщение недоступно на этом устройстве").font(.footnote).opacity(0.8)
        case .ok:
            switch msg.type {
            case "img": image
            case "voice": VoiceView(msg: msg, fg: out ? .white : .primary)
            case "video", "file": attachment
            case "poll": poll
            default:
                Text(b.s("d")).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var image: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if b["sfid"] != nil {
                    FileImage(sfid: b.s("sfid"), px: 720)
                } else if let s = b["d"] as? String {
                    let key = "msg_\(msg.id)_\(s.count)"
                    CachedImage(key: key, px: 720) {
                        await Task.detached { Data(base64Encoded: s, options: .ignoreUnknownCharacters) }.value
                    }
                } else {
                    Color(.secondarySystemFill)
                }
            }
            .frame(width: 240, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(perform: onOpenImage)
            if !b.s("cap").isEmpty { Text(b.s("cap")) }
        }
    }

    @ViewBuilder private var attachment: some View {
        let video = msg.type == "video"
        let name = b["n"] == nil ? (video ? "Видео" : "Файл") : b.s("n")
        HStack(spacing: 10) {
            Image(systemName: video ? (b.b("round") ? "circle.dashed" : "play.rectangle.fill") : "doc.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(2)
                if b.i("s") > 0 { Text(humanSize(b.i("s"))).font(.caption).opacity(0.7) }
            }
        }
        .frame(minWidth: 180, alignment: .leading)
        .onTapGesture {
            if let u = Api.shared.fileUrl(b.s("sfid")) { UIApplication.shared.open(u) }
        }
    }

    @ViewBuilder private var poll: some View {
        let opts = (b["o"] as? [Any]) ?? []
        let votes = msg.raw.d("v")
        let base = b.d("pvc")
        let total = max(1, b.i("pt") + votes.count)
        VStack(alignment: .leading, spacing: 6) {
            Text(b.s("p")).font(.subheadline.bold())
            ForEach(Array(opts.enumerated()), id: \.offset) { i, o in
                let cnt = base.i("\(i)") + votes.values.filter { ($0 as? NSNumber)?.intValue == i }.count
                Button { onVote(i) } label: {
                    HStack {
                        Text("\(o)")
                        Spacer()
                        Text("\(cnt * 100 / total)%").font(.caption)
                    }
                    .padding(8)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }.frame(minWidth: 200)
    }

    @ViewBuilder private var reactions: some View {
        let rs = msg.raw.d("r")
        if !rs.isEmpty {
            let counts = Dictionary(grouping: rs.values.compactMap { $0 as? String }, by: { $0 }).mapValues { $0.count }
            HStack(spacing: 4) {
                ForEach(counts.keys.sorted(), id: \.self) { e in
                    Text("\(e) \(counts[e] ?? 0)").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        let cur = msg.raw.d("r").s(Api.shared.uid)
        ForEach(["❤️", "👍", "😂", "🔥"], id: \.self) { e in
            Button("\(e)\(cur == e ? " ✓" : "")") { onReact(e) }
        }
        Button { onReply() } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
        if msg.type == "text" {
            Button { UIPasteboard.general.string = b.s("d") } label: { Label("Копировать", systemImage: "doc.on.doc") }
        }
        if mine && msg.type == "text" {
            Button { onEdit() } label: { Label("Изменить", systemImage: "pencil") }
        }
        if canDelete {
            Button(role: .destructive) { onDelete() } label: { Label("Удалить", systemImage: "trash") }
        }
    }
}

// MARK: - Голосовое

@MainActor
final class VoicePlayer: ObservableObject {
    @Published var playing = false
    private var player: AVPlayer?
    private var obs: NSObjectProtocol?

    func toggle(_ msg: Msg) {
        if playing { player?.pause(); playing = false; return }
        if player == nil {
            let b = msg.body
            var url: URL?
            if b["sfid"] != nil { url = Api.shared.fileUrl(b.s("sfid")) }
            else if let s = b["d"] as? String, let d = Data(base64Encoded: s) {
                let ext = b.s("x").isEmpty ? "m4a" : b.s("x")
                let f = FileManager.default.temporaryDirectory.appendingPathComponent("v_\(msg.id).\(ext)")
                try? d.write(to: f)
                url = f
            }
            guard let url else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(url: url)
            obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.playing = false
                    self?.player?.seek(to: .zero)
                }
            }
            player = p
        }
        player?.play()
        playing = true
    }
}

struct VoiceView: View {
    let msg: Msg
    let fg: Color
    @StateObject private var vp = VoicePlayer()
    var body: some View {
        Button { vp.toggle(msg) } label: {
            HStack(spacing: 8) {
                Image(systemName: vp.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                Image(systemName: "waveform").font(.title3)
                Text("\(msg.body.i("s")) с").font(.caption)
            }.foregroundStyle(fg)
        }.buttonStyle(.plain)
    }
}

// MARK: - Просмотр фото

struct PhotoViewer: View, Identifiable {
    let msg: Msg
    let chatId: String
    var id: String { msg.id }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Group {
                if msg.body["sfid"] != nil {
                    FileImage(sfid: msg.body.s("sfid"), px: 2400, fit: true)
                } else if let s = msg.body["d"] as? String {
                    CachedImage(key: "msg_\(msg.id)_\(s.count)", px: 2400, fit: true) {
                        Data(base64Encoded: s, options: .ignoreUnknownCharacters)
                    }
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.85))
            }.padding(16)
        }
    }
}
