import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var github: GitHubStore
    @EnvironmentObject var sites: SiteMonitor
    @EnvironmentObject var np: NPSession
    @AppStorage("np.sources") private var npSources = ClinicAssistant.defaultSources
    @AppStorage("appearance") private var appearance = 2
    @AppStorage("sites") private var siteList = SiteMonitor.defaultList
    @AppStorage("notify") private var notify = true
    @AppStorage("speak.replies") private var speakReplies = false
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
                    if paired || Keychain.pairingCode != nil {
                        LabeledContent("Pairing", value: brain.pairedAutomatically ? "Paired automatically" : "Paired")
                        ForEach(brain.fleet) { f in
                            LabeledContent(f.machine, value: brain.pairedWith(f) ? (f.isOnline ? "Online" : "Offline") : "Waiting for its code")
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
                    Text("Happens by itself: the iMac hands this phone its code once through your iCloud folder, then deletes it. Orders are signed with it, so nothing else can command the Macs. To type it instead: python3 ~/PMPBrain/crew.py pair on the iMac.")
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
                        if let mac = github.viaMac {
                            LabeledContent("Using", value: "\(mac)'s GitHub login")
                            LabeledContent("Repos watched", value: "\(github.repos.count)")
                        } else if let e = github.error {
                            Text(e).font(.footnote).foregroundStyle(Theme.watch)
                        }
                        SecureField("Optional: github_pat_…", text: $token)
                        Button("Save token") { Keychain.githubToken = token; token = ""; hasToken = Keychain.githubToken != nil }.disabled(token.isEmpty)
                    }
                } header: { Text("GitHub") } footer: {
                    Text("Nothing to set up: the iMac watches GitHub with the login it already uses for git, and merges, re-runs and opens PRs when you tap. A token here is optional; it makes GitHub refresh straight from the phone.")
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
                    Picker("Thinking", selection: $chat.effortRaw) {
                        ForEach(ClaudeClient.Effort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } header: { Text("Katrina (Dispatch)") } footer: {
                    Text("Dispatch uses an Anthropic API key from console.anthropic.com, billed per use. Higher thinking and Fable cost more; spoken questions always use Sonnet at low. Missions on your Macs use your Claude subscription there instead. The Tower never uses either.")
                }

                Section {
                    if np.hasPin {
                        Toggle("Face ID / Touch ID", isOn: $np.faceID).disabled(!np.biometricsAvailable)
                        Picker("Lock after", selection: $np.autoLockSeconds) {
                            Text("Every time").tag(0)
                            Text("1 minute").tag(60)
                            Text("5 minutes").tag(300)
                            Text("15 minutes").tag(900)
                        }
                        if np.unlocked {
                            Button("Remove NP login", role: .destructive) { np.removeLogin() }
                        } else {
                            Text("Open the NP desk to change or remove the login.").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not set up yet. Open the NP desk tab to create your PIN.").foregroundStyle(.secondary)
                    }
                } header: { Text("NP desk login") } footer: {
                    Text("A 6-digit PIN of its own, kept on this device only. Five wrong tries in a row lock it for a while. It locks again when the app has been away.")
                }

                Section {
                    TextField("cno.org, cps.ca, …", text: $npSources, axis: .vertical).lineLimit(3...10)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .font(.footnote)
                    Button("Reset to the default list") { npSources = ClinicAssistant.defaultSources }
                } header: { Text("NP desk trusted sources") } footer: {
                    Text("When \"Look up trusted sources\" is on, the NP desk searches only these sites and lists what it cited. Separate with commas. Each search costs about one cent plus the reading. Leave it empty to search the whole web.")
                }

                Section {
                    TextField("https://…", text: $siteList, axis: .vertical).lineLimit(1...4)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Check now") { Task { await sites.refresh() } }
                } header: { Text("Websites to watch") } footer: { Text("Separate with commas.") }

                Section {
                    Toggle("Read Dispatch replies aloud", isOn: $speakReplies)
                    LabeledContent("Voice", value: VoiceOutput.bestVoice?.name ?? "System")
                } header: { Text("Voice") } footer: {
                    Text("Say \"Hey Siri, ask Katrina PA\" or \"Hey Siri, what needs me in Katrina PA\". For a better voice: iPhone Settings > Accessibility > Spoken Content > Voices > English, download an Enhanced or Premium voice; Katrina uses the best one installed.")
                }

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
