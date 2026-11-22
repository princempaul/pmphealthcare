import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var chat: ChatStore
    @AppStorage("appearance") private var appearance = 0
    @State private var key = ""
    @State private var hasKey = Keychain.apiKey != nil
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Brain folder") {
                    LabeledContent("Folder", value: brain.folderName ?? "Not chosen")
                    if let d = brain.lastLoaded { LabeledContent("Last read", value: d.formatted(date: .omitted, time: .shortened)) }
                    Button("Choose another folder") { picking = true }
                    if let e = brain.error { Text(e).font(.footnote).foregroundStyle(Theme.watch) }
                }
                Section {
                    if hasKey {
                        LabeledContent("API key", value: "Saved in Keychain")
                        Button("Remove key", role: .destructive) { Keychain.apiKey = nil; hasKey = false }
                    } else {
                        SecureField("sk-ant-…", text: $key)
                        Button("Save key") { Keychain.apiKey = key; key = ""; hasKey = Keychain.apiKey != nil }.disabled(key.isEmpty)
                    }
                    Picker("Model", selection: $chat.modelRaw) {
                        ForEach(ClaudeClient.Model.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } header: { Text("Ask Katrina") } footer: {
                    Text("Asking uses an Anthropic API key, billed per use at console.anthropic.com and separate from your Claude subscription. Today, Projects and Notes never use it.")
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) { Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }
                        .pickerStyle(.segmented)
                }
                Section {
                    Text("Katrina reads only the summaries your Macs write to iCloud Drive. They hold no patient data, and notes that look like patient detail are refused here and on the Macs.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Privacy") }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { brain.setFolder(url) }
            }
        }
    }
}
