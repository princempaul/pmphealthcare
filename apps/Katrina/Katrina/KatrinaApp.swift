import SwiftUI

@main
struct KatrinaApp: App {
    @StateObject private var brain = BrainStore()
    @StateObject private var chat = ChatStore()
    @AppStorage("appearance") private var appearance = 0   // 0 system, 1 light, 2 dark

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(brain)
                .environmentObject(chat)
                .tint(Theme.accent)
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
                .task { await brain.reload() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await brain.reload() } }.keyboardShortcut("r")
            }
        }
        #endif
    }
}
