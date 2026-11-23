import SwiftUI

struct RootView: View {
    @EnvironmentObject var brain: BrainStore
    @AppStorage("onboarded") private var onboarded = false
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
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
            }
            .onAppear { if UserDefaults.standard.object(forKey: "notify") as? Bool ?? true { Notifier.requestPermission() } }
        }
    }
}
