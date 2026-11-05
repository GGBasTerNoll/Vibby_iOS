import SwiftUI

@main
struct VibbyApp: App {
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Root()
                .environmentObject(session)
                .environmentObject(Store.shared)
                .task { await session.boot() }
                .onChange(of: phase) { _, p in Store.shared.setForeground(p == .active) }
        }
    }
}

private struct Root: View {
    @EnvironmentObject var session: Session

    var body: some View {
        switch session.step {
        case .done:
            ChatListView()
        default:
            LoginView()
        }
    }
}
