import SwiftUI

/// Every job Paul has delegated to a Mac, live.
struct MissionsView: View {
    @EnvironmentObject var brain: BrainStore
    @State private var composing = false
    @State private var filter = 0      // 0 active, 1 all

    private var rows: [(machine: String, mission: FleetSnapshot.Mission)] {
        let quiet: Set<String> = ["discarded", "closed", "stopped"]
        return brain.missions.filter { filter == 1 || !quiet.contains($0.mission.state) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $filter) { Text("Open").tag(0); Text("All").tag(1) }.pickerStyle(.segmented)
                }
                if rows.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No missions yet").font(.headline)
                            Text("Send Claude to work on any project from here. It runs on the iMac, on its own branch, and reports back. Pushing waits for your approval.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("New mission") { composing = true }.buttonStyle(.borderedProminent).padding(.top, 4)
                        }
                        .padding(.vertical, 6)
                    }
                }
                ForEach(rows, id: \.mission.id) { row in
                    NavigationLink(value: MissionRef(machine: row.machine, id: row.mission.id)) { MissionRow(machine: row.machine, mission: row.mission) }
                }
            }
            .navigationTitle("Missions")
            .navigationDestination(for: MissionRef.self) { MissionDetailView(ref: $0) }
            .refreshable { await brain.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: { Label("New mission", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $composing) { NewMissionView() }
        }
    }
}

struct MissionRow: View {
    let machine: String
    let mission: FleetSnapshot.Mission

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusLight(color: Theme.color(forMission: mission.state), pulsing: mission.isLive, size: 8).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(mission.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Pill(text: Theme.label(forMission: mission.state), color: Theme.color(forMission: mission.state))
                    Text("\(mission.isWork ? "Work" : "Look") · \(mission.projectName ?? "") · \(machine)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(ago(mission.createdDate)).font(Theme.mono).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// One mission: the brief, Katrina's reports, follow-ups and the approve / discard decision.
struct MissionDetailView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var github: GitHubStore
    @Environment(\.openURL) private var openURL
    let ref: MissionRef
    @State private var followUp = ""
    @State private var message: String?
    @State private var sending = false
    @State private var confirmDiscard = false
    @State private var sent: Set<String> = []     // orders sent this session, so buttons don't double-fire

    private var mission: FleetSnapshot.Mission? {
        brain.fleet.first { $0.machine == ref.machine }?.missions.first { $0.id == ref.id }
    }

    var body: some View {
        Group {
            if let m = mission { content(m) } else {
                ContentUnavailableView("Mission not found", systemImage: "scope", description: Text("It may have been cleared on the Mac."))
            }
        }
        .navigationTitle("Mission")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await brain.reload() }
    }

    private func content(_ m: FleetSnapshot.Mission) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusLight(color: Theme.color(forMission: m.state), pulsing: m.isLive)
                        Text(Theme.label(forMission: m.state).uppercased()).font(Theme.label).tracking(1.2)
                            .foregroundStyle(Theme.color(forMission: m.state))
                    }
                    Text(m.projectName ?? "Project").font(Theme.display(26))
                    Text("\(m.isWork ? "Work mission: edits on its own branch" : "Look-only mission") · \(ref.machine)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                if let e = m.error, !e.isEmpty { Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.watch).card() }

                ForEach(Array((m.turns ?? []).enumerated()), id: \.offset) { _, t in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.who == "paul" ? "YOU" : "KATRINA").font(Theme.monoSmall).foregroundStyle(t.who == "paul" ? Theme.accent : Theme.live)
                        Text(t.text).font(.callout).textSelection(.enabled)
                    }
                    .card(tint: t.who == "paul" ? nil : Theme.live)
                }
                if m.isLive {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(m.state == "queued" ? "Waiting for the Mac to pick it up…" : "Katrina is working…").foregroundStyle(.secondary) }
                }

                if m.isWork, let branch = m.branch, !branch.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Changes")
                        Text(branch).font(Theme.mono)
                        if let d = m.diffstat, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                        if let c = m.commits { Text("\(c) commit\(c == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
                    }
                    .card()
                }

                actions(m)

                if let msg = message { Text(msg).font(.footnote).foregroundStyle(.secondary) }

                HStack(spacing: 14) {
                    if let c = m.costUsd, c > 0 { Text(String(format: "$%.2f", c)).font(Theme.mono) }
                    if let n = m.numTurns, n > 0 { Text("\(n) turns").font(Theme.mono) }
                    Text(m.id.prefix(8)).font(Theme.mono)
                }
                .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Discard this mission's branch?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { order(.discard, m) }
        } message: { Text("The worktree and branch on the Mac are deleted. Pushed branches stay on GitHub.") }
    }

    @ViewBuilder
    private func actions(_ m: FleetSnapshot.Mission) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.state == "needs_approval" && !sent.contains("push") {
                Button { order(.push, m) } label: { Label("Approve & push branch", systemImage: "checkmark.seal.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if m.state == "pushed", let slug = m.repo, !slug.isEmpty, let branch = m.branch {
                let existing = github.openPulls.first { $0.repo.slug == slug && $0.pull.head == branch }
                if let pr = existing {
                    Button { if let u = URL(string: pr.pull.url) { openURL(u) } } label: {
                        Label("View pull request #\(pr.pull.number)", systemImage: "arrow.triangle.pull").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button { openPR(m, slug: slug, branch: branch) } label: {
                        Label("Open pull request", systemImage: "arrow.triangle.pull").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(sending || !github.hasToken)
                    if !github.hasToken { Text("Add a GitHub token in Settings to open it from here.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if m.isLive {
                Button(role: .destructive) { order(.stop, m) } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(sent.contains("stop"))
            } else if ["done", "needs_approval", "failed", "stopped", "pushed"].contains(m.state) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Follow up")
                    TextField("Tell Katrina what to do next", text: $followUp, axis: .vertical).lineLimit(2...6)
                        .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button { order(.followup, m, text: followUp) } label: { Label("Send", systemImage: "arrow.up.circle.fill") }
                        .buttonStyle(.borderedProminent).disabled(followUp.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                }
                if m.isWork && m.state != "pushed" {
                    Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard branch", systemImage: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func order(_ kind: CrewOrder.Kind, _ m: FleetSnapshot.Mission, text: String = "") {
        do {
            try brain.send(CrewOrder(kind: kind, machine: ref.machine, mission: m.id).withPrompt(text))
            sent.insert(kind.rawValue)
            if kind == .followup { followUp = "" }
            message = "Sent to \(ref.machine). It picks this up within a minute."
        } catch {
            message = error.localizedDescription
        }
    }

    private func openPR(_ m: FleetSnapshot.Mission, slug: String, branch: String) {
        sending = true
        Task {
            do {
                let url = try await github.openPull(slug: slug, branch: branch, title: m.title,
                                                    body: "Opened from Katrina PA. Made by a Katrina mission on `\(branch)`.\n\n\(m.result ?? "")")
                message = "Pull request opened."
                await Dispatcher.refresh(brain: brain, github: github)
                if let u = URL(string: url) { openURL(u) }
            } catch {
                message = error.localizedDescription
            }
            sending = false
        }
    }
}

extension CrewOrder {
    /// The same order with a prompt (follow-ups carry text). Rebuilt so the id and time stay fresh.
    func withPrompt(_ text: String) -> CrewOrder {
        text.isEmpty ? self : CrewOrder(kind: Kind(rawValue: kind) ?? .followup, machine: machine, project: project,
                                        mode: Mode(rawValue: mode), prompt: text, mission: mission)
    }
}

/// Brief a new mission: pick a project, look or work, say what done looks like.
struct NewMissionView: View {
    @EnvironmentObject var brain: BrainStore
    @Environment(\.dismiss) private var dismiss
    @State private var machine: String
    @State private var projectPath: String
    @State private var work = false
    @State private var brief = ""
    @State private var error: String?

    init(machine: String = "", projectPath: String = "") {
        _machine = State(initialValue: machine)
        _projectPath = State(initialValue: projectPath)
    }

    private var macs: [String] {
        var list = brain.fleet.map(\.machine)
        if !machine.isEmpty && !list.contains(machine) { list.append(machine) }
        return list
    }
    private var projects: [MachineSnapshot.Project] {
        brain.projects.filter { $0.machine == machine }.map(\.project).filter { !work || $0.kind == "git" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mac", selection: $machine) { ForEach(macs, id: \.self) { Text($0).tag($0) } }
                    Picker("Project", selection: $projectPath) {
                        Text("Choose…").tag("")
                        ForEach(projects) { Text($0.name).tag($0.path) }
                    }
                    Picker("Mode", selection: $work) {
                        Text("Look & report").tag(false)
                        Text("Make changes").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(work ? "Edits and commits on a new katrina/ branch in a separate copy. Your own working folder isn't touched. Nothing is pushed until you approve."
                              : "Reads the project and reports back. Changes nothing.")
                }
                Section("Brief") {
                    TextField("What should Katrina do? What does done look like?", text: $brief, axis: .vertical).lineLimit(4...12)
                }
                if let error { Section { Text(error).foregroundStyle(Theme.action) } }
                if brain.fleet.isEmpty {
                    Section { Text("No Mac's crew has checked in yet. Run ./install.sh on the iMac, then pair in Settings.").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New mission")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }.disabled(projectPath.isEmpty || brief.trimmingCharacters(in: .whitespaces).isEmpty || machine.isEmpty)
                }
            }
            .onAppear { if machine.isEmpty { machine = brain.commandMac?.machine ?? macs.first ?? "" } }
            .onChange(of: machine) { _, _ in projectPath = "" }
            .onChange(of: work) { _, _ in if !projects.contains(where: { $0.path == projectPath }) { projectPath = "" } }
        }
    }

    private func send() {
        do {
            try brain.send(CrewOrder(kind: .mission, machine: machine, project: projectPath, mode: work ? .work : .look, prompt: brief))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
