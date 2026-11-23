import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct KatrinaApp: App {
    @StateObject private var brain = BrainStore()
    @StateObject private var chat = ChatStore()
    @StateObject private var github = GitHubStore()
    @StateObject private var sites = SiteMonitor()
    @AppStorage("appearance") private var appearance = 2   // 0 system, 1 light, 2 dark (the tower default)
    @Environment(\.scenePhase) private var phase

    static let refreshTask = "ca.pmphealthcare.katrina.refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(brain)
                .environmentObject(chat)
                .environmentObject(github)
                .environmentObject(sites)
                .tint(Theme.accent)
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
                .task(id: phase) { await liveLoop() }
        }
        #if os(iOS)
        .onChange(of: phase) { _, p in if p == .background { Self.scheduleBackground() } }
        .backgroundTask(.appRefresh(Self.refreshTask)) { await backgroundRefresh() }
        #endif
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await refreshAll() } }.keyboardShortcut("r")
            }
        }
        #endif
    }

    /// While the app is open: Mac files every 15 s, GitHub every minute, websites every 2 minutes.
    @MainActor
    private func liveLoop() async {
        guard phase == .active else { return }
        var tick = 0
        while !Task.isCancelled {
            await brain.reload()
            if github.hasToken { if tick % 4 == 0 { await github.refresh(slugs: slugs) } }
            else { Dispatcher.adoptGitHub(brain: brain, github: github) }
            if tick % 8 == 0 { await sites.refresh() }
            Notifier.update(with: TowerBoard.needsYou(brain: brain, github: github, sites: sites))
            tick += 1
            try? await Task.sleep(for: .seconds(15))
        }
    }

    @MainActor
    private var slugs: [String] { brain.projects.compactMap { GitHubStore.slug(fromRemote: $0.project.remote) } }

    @MainActor
    private func refreshAll() async {
        await Dispatcher.refresh(brain: brain, github: github)
        await sites.refresh()
    }

    #if os(iOS)
    static func scheduleBackground() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTask)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// iOS wakes the app now and then: check everything and notify if something new needs Paul.
    private func backgroundRefresh() async {
        Self.scheduleBackground()
        await refreshAll()
        await MainActor.run { Notifier.update(with: TowerBoard.needsYou(brain: brain, github: github, sites: sites)) }
    }
    #endif
}
