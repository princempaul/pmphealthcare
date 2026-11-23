import SwiftUI

/// Dispatch: talk to Katrina. She checks the whole fleet and puts proposed orders in front of Paul as cards.
struct DispatchView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var github: GitHubStore
    @EnvironmentObject var sites: SiteMonitor
    @EnvironmentObject var chat: ChatStore
    @State private var draft = ""
    @State private var showJane = false
    @AppStorage("talk.open") private var talkOpen = false
    @AppStorage("speak.replies") private var speakReplies = false
    @StateObject private var dictation = VoiceInput()
    @FocusState private var focused: Bool

    private let suggestions = [
        "What needs me right now?",
        "Status of every project, one line each",
        "Which Claude sessions are waiting on me?",
        "Review the portal repo and list the riskiest open issues",
        "Fix the failing build and open a PR",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if chat.lines.isEmpty { empty }
                            ForEach(chat.lines) { line in row(line).id(line.id) }
                            if chat.busy {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(chat.status).foregroundStyle(.secondary) }.id("busy")
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.lines.count) { _, _ in withAnimation { proxy.scrollTo(chat.lines.last?.id, anchor: .bottom) } }
                }
                composer
            }
            .navigationTitle("Dispatch")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showJane = true } label: { Label("Jane", systemImage: "stethoscope") }
                }
                ToolbarItem { Button { talkOpen = true } label: { Label("Talk", systemImage: "waveform") } }
                ToolbarItem { Button("New") { chat.reset() }.disabled(chat.lines.isEmpty || chat.busy) }
            }
            .sheet(isPresented: $showJane) { JaneView() }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What do you need done?").font(Theme.display(28))
            Text("Katrina sees both Macs, every Claude session, your missions, repos, builds and sites. Ask anything, or give an order: she'll line it up for your approval.")
                .foregroundStyle(.secondary)
            Button { showJane = true } label: {
                HStack {
                    Image(systemName: "stethoscope").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jane desk").font(.subheadline.weight(.semibold))
                        Text("Notes, forms and bookings in Jane, from the iMac's Chrome").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        HStack { Text(s).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private func row(_ line: ChatLine) -> some View {
        switch line.role {
        case .paul:
            HStack { Spacer(minLength: 60)
                Text(line.text).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .katrina:
            Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .note:
            Label(line.text, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.watch)
        case .proposal(let id):
            if let p = chat.proposals[id] { ProposalCard(proposal: p) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(dictation.state == .listening ? (dictation.transcript.isEmpty ? "Listening…" : dictation.transcript) : "Ask or give an order",
                      text: $draft, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit { send(draft) }
            if dictation.state == .listening || (draft.trimmingCharacters(in: .whitespaces).isEmpty && !chat.busy) {
                Button { dictate() } label: {
                    Image(systemName: dictation.state == .listening ? "waveform" : "mic.fill").font(.headline)
                        .frame(width: 36, height: 36)
                        .background(dictation.state == .listening ? Theme.live : Theme.accent, in: Circle()).foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.state == .listening)
                }
                .buttonStyle(.plain)
            } else {
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up").font(.headline).frame(width: 36, height: 36)
                        .background(Theme.accent, in: Circle()).foregroundStyle(.white)
                }
                .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || chat.busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(.bar)
        // voice to type: words appear in the box as you speak
        .onChange(of: dictation.transcript) { _, t in if dictation.state == .listening { draft = t } }
        .onChange(of: dictation.state) { _, st in
            if case .denied(let why) = st {
                chat.lines.append(ChatLine(role: .note, text: why))
                dictation.reset()
            }
        }
    }

    private func send(_ text: String, spoken: Bool = false) {
        let q = text
        draft = ""
        Task {
            let before = chat.lines.count
            await chat.ask(q, brain: brain, github: github, sites: sites, voice: spoken)
            if spoken || speakReplies {
                let said = chat.lines.suffix(from: min(before, chat.lines.count)).filter { $0.role == .katrina }.map(\.text).joined(separator: " ")
                if !said.isEmpty { VoiceOutput.shared.speak(said) }
            }
        }
    }

    /// Tap the mic, speak, pause: it sends by itself and Katrina answers out loud.
    private func dictate() {
        if dictation.state == .listening { dictation.finish(); return }
        VoiceOutput.shared.stop()
        dictation.onFinished = { text in send(text, spoken: true) }
        dictation.reset()
        Task { await dictation.start() }
    }
}

/// An order Katrina lined up. Approve sends it; Cancel drops it.
struct ProposalCard: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var github: GitHubStore
    @EnvironmentObject var chat: ChatStore
    let proposal: Proposal
    @State private var expanded = false

    private var icon: String {
        switch proposal.kind {
        case .mission: return proposal.mode == "work" ? "hammer.fill" : "binoculars.fill"
        case .merge: return "arrow.triangle.merge"
        case .rerun: return "arrow.clockwise.circle.fill"
        case .refresh: return "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32).background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROPOSED ORDER").font(Theme.monoSmall).foregroundStyle(.secondary)
                    Text(proposal.title).font(.subheadline.weight(.semibold))
                }
                Spacer()
                stateBadge
            }
            if !proposal.reason.isEmpty { Text(proposal.reason).font(.callout).foregroundStyle(.secondary) }
            if proposal.kind == .mission {
                Text(proposal.prompt).font(.callout).lineLimit(expanded ? nil : 5)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { expanded.toggle() }
                Text("Runs on \(proposal.machine)\(proposal.mode == "work" ? " · on its own branch; push waits for you" : " · read only")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if proposal.state == .pending {
                HStack {
                    Button { Task { await chat.approve(proposal.id, brain: brain, github: github) } } label: {
                        Label("Approve", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                    Button("Cancel") { chat.cancel(proposal.id) }.buttonStyle(.bordered)
                }
            } else if !proposal.message.isEmpty {
                Text(proposal.message).font(.footnote).foregroundStyle(proposal.state == .failed ? Theme.action : .secondary)
            }
        }
        .card(tint: proposal.state == .pending ? Theme.accent : nil)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch proposal.state {
        case .pending: Pill(text: "Awaiting you", color: Theme.accent)
        case .running: ProgressView().controlSize(.small)
        case .done: Pill(text: "Sent", color: Theme.ok)
        case .cancelled: Pill(text: "Cancelled")
        case .failed: Pill(text: "Failed", color: Theme.action)
        }
    }
}

/// Wrapping row of chips.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(items, id: \.self, content: content) }
            VStack(alignment: .leading, spacing: 8) { ForEach(items, id: \.self, content: content) }
        }
    }
}
