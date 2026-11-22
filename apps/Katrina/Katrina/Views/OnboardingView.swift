import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var brain: BrainStore
    @State private var picking = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 120, height: 120)
                Text("K").font(Theme.display(64)).foregroundStyle(Theme.accent)
            }
            VStack(spacing: 10) {
                Text("Katrina").font(Theme.display(40))
                Text("Your projects, both Macs and what needs you, in one place.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                step("1", "Install Katrina on your Macs", "It writes a small summary to iCloud Drive every hour.")
                step("2", "Choose the PMPBrain folder", "iCloud Drive > PMPBrain. Katrina reads it on this device.")
                step("3", "Optional: add an API key", "To ask questions. Everything else works without it.")
            }
            .frame(maxWidth: 440).card()
            Button { picking = true } label: {
                Text("Choose PMPBrain folder").font(.headline).frame(maxWidth: 360).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if let e = brain.error { Text(e).font(.footnote).foregroundStyle(Theme.action) }
            Spacer()
            Text("Patient details never go into Katrina.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { brain.setFolder(url) }
        }
    }

    private func step(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(n).font(.system(.callout, design: .rounded).weight(.bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
