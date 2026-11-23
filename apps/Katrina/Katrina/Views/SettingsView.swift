import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var github: GitHubStore
    @EnvironmentObject var sites: SiteMonitor
    @AppStorage("appearance") private var appearance = 2
    @AppStorage("sites") private var siteList = SiteMonitor.defaultList
    @AppStorage("notify") private var notify = true
    @State private var key = ""
    @State private var token = ""
    @State private var code = ""
    @State private var codeError: String?
    @State private var hasKey = Keychain.apiKey != nil
    @State private var hasToken = Keychain.githubToken != nil
    @State private var paired = Keychain.pairingCode != nil
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if paired {
                        LabeledContent("Pairing", value: "Paired")
                        ForEach(brain.fleet) { f in
                            LabeledContent(f.machine, value: f.paired == true ? (f.isOnline ? "Online" : "Offline") : "Not paired on that Mac")
                        }
                        Button("Forget pairing", role: .destructive) { Keychain.pairingCode = nil; paired = false }
                    } else {
                        TextField("ABCD-EFGH-JKLM-NPQR", text: $code)
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Pair") {
                            if let c = CrewOrder.normalise(code) { Keychain.pairingCode = c; paired = true; code = ""; codeError = nil }
                            else { codeError = "That isn't a pairing code. It's 16 letters and digits, like ABCD-EFGH-JKLM-NPQR." }
                        }
                        .disabled(code.isEmpty)
                        if let codeError { Text(codeError).font(.footnote).foregroundStyle(Theme.action) }
                    }
                } header: { Text("Pair with your Macs") } footer: {
                    Text("Lets this phone send missions to your Macs. Get the code on the iMac: python3 ~/PMPBrain/crew.py pair. Orders are signed with it, so nothing else can command the Macs.")
                }

                Section {
                    LabeledContent("Folder", value: brain.folderName ?? "Not chosen")
                    if let d = brain.lastLoaded { LabeledContent("Last read", value: d.formatted(date: .omitted, time: .standard)) }
                    Button("Choose PMPBrain folder") { picking = true }
                    if let e = brain.error { Text(e).font(.footnote).foregroundStyle(Theme.watch) }
                } header: { Text("Brain folder") } footer: {
                    Text("iCloud Drive > PMPBrain. Your Macs write their status here every 20 seconds and pick up your orders from it.")
                }

                Section {
                    if hasToken {
                        LabeledContent("Token", value: "Saved in Keychain")
                        LabeledContent("Repos watched", value: "\(github.repos.count)")
                        if let e = github.error { Text(e).font(.footnote).foregroundStyle(Theme.watch) }
                        Button("Remove token", role: .destructive) { Keychain.githubToken = nil; hasToken = false }
                    } else {
                        SecureField("github_pat_…", text: $token)
                        Button("Save token") { Keychain.githubToken = token; token = ""; hasToken = Keychain.githubToken != nil }.disabled(token.isEmpty)
                    }
                } header: { Text("GitHub") } footer: {
                    Text("A fine-grained token from github.com > Settings > Developer settings, for your repos, with read and write on Pull requests and Actions, and read on Contents. Repos come from your projects automatically.")
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
                } header: { Text("Katrina (Dispatch)") } footer: {
                    Text("Dispatch uses an Anthropic API key from console.anthropic.com, billed per use. Missions on your Macs use your Claude subscription there instead. The Tower never uses either.")
                }

                Section {
                    TextField("https://…", text: $siteList, axis: .vertical).lineLimit(1...4)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Check now") { Task { await sites.refresh() } }
                } header: { Text("Websites to watch") } footer: { Text("Separate with commas.") }

                Section("Alerts") {
                    Toggle("Notify me when something needs me", isOn: $notify)
                        .onChange(of: notify) { _, on in if on { Notifier.requestPermission() } }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) { Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }
                        .pickerStyle(.segmented)
                }

                Section {
                    NavigationLink("Decisions and notes") { NotesView() }
                }

                Section {
                    Text("The Macs share titles and status only: no conversation text, no file contents, no patient data. Orders and notes that look like patient detail are refused here and on the Macs. Nothing is pushed, merged, sent or paid without your tap.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Privacy and control") }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { brain.setFolder(url) }
            }
        }
    }
}
