import SwiftUI

struct RootView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var np: NPSession
    @Environment(\.scenePhase) private var phase
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("talk.open") private var talkOpen = false
    @State private var tab = 0

    var body: some View {
        if !brain.hasFolder && !onboarded {
            OnboardingView(onboarded: $onboarded)
        } else {
            TabView(selection: $tab) {
                TowerView(tab: $tab).tabItem { Label("Tower", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
                DispatchView().tabItem { Label("Dispatch", systemImage: "sparkles") }.tag(1)
                MissionsView().tabItem { Label("Missions", systemImage: "scope") }.tag(2)
                ProjectsView().tabItem { Label("Projects", systemImage: "square.grid.2x2") }.tag(3)
                NPDeskView().tabItem { Label("NP desk", systemImage: "stethoscope") }.tag(5)
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
            }
            .onChange(of: phase) { _, p in np.scenePhaseChanged(p) }
            .onAppear { if UserDefaults.standard.object(forKey: "notify") as? Bool ?? true { Notifier.requestPermission() } }
            #if os(iOS)
            .fullScreenCover(isPresented: $talkOpen) { TalkView().environmentObject(ChatStore.shared) }
            #else
            .sheet(isPresented: $talkOpen) { TalkView().environmentObject(ChatStore.shared).frame(minWidth: 520, minHeight: 640) }
            #endif
        }
    }
}
