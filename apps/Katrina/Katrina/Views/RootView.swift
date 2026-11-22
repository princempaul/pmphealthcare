import SwiftUI

struct RootView: View {
    @EnvironmentObject var brain: BrainStore
    @State private var tab = 0

    var body: some View {
        if !brain.hasFolder {
            OnboardingView()
        } else {
            TabView(selection: $tab) {
                TodayView().tabItem { Label("Today", systemImage: "sun.horizon") }.tag(0)
                AskView().tabItem { Label("Ask", systemImage: "sparkles") }.tag(1)
                ProjectsView().tabItem { Label("Projects", systemImage: "square.grid.2x2") }.tag(2)
                NotesView().tabItem { Label("Notes", systemImage: "note.text") }.tag(3)
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
            }
        }
    }
}
