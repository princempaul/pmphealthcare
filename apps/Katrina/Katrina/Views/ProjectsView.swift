import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var github: GitHubStore
    @State private var query = ""

    private var grouped: [(String, [(machine: String, project: MachineSnapshot.Project)])] {
        let q = query.lowercased()
        let rows = brain.projects.filter { q.isEmpty || $0.project.name.lowercased().contains(q) || ($0.project.category ?? "").lowercased().contains(q) }
        return Dictionary(grouping: rows) { $0.project.category ?? "Other" }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.0) { category, rows in
                    Section(category) {
                        ForEach(rows, id: \.project.id) { row in
                            NavigationLink { ProjectDetail(machine: row.machine, project: row.project) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.project.name).font(.headline)
                                        Text(row.machine).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let slug = GitHubStore.slug(fromRemote: row.project.remote),
                                       let r = github.repos.first(where: { $0.slug == slug }) {
                                        if !r.failing.isEmpty { Pill(text: "Build failing", color: Theme.action) }
                                        else if !r.pulls.isEmpty { Pill(text: "\(r.pulls.count) PR", color: Theme.accent) }
                                    }
                                    if row.project.isLoose {
                                        Text("Loose work").font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(Theme.watch.opacity(0.18), in: Capsule()).foregroundStyle(Theme.watch)
                                    }
                                }
                            }
                        }
                    }
                }
                if !brain.map.isEmpty {
                    Section("How things connect") {
                        ForEach(brain.map, id: \.self) { Text($0).font(.callout) }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a project")
            .refreshable { await brain.reload() }
            .navigationTitle("Projects")
        }
    }
}

struct ProjectDetail: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var github: GitHubStore
    @Environment(\.openURL) private var openURL
    let machine: String
    let project: MachineSnapshot.Project
    @State private var composing = false

    private var repo: GitHubStore.Repo? {
        guard let slug = GitHubStore.slug(fromRemote: project.remote) else { return nil }
        return github.repos.first { $0.slug == slug }
    }

    var body: some View {
        List {
            Section {
                Button { composing = true } label: { Label("Send a mission here", systemImage: "scope") }
            }
            if let repo {
                Section("GitHub · \(repo.slug)") {
                    if repo.pulls.isEmpty { Text("No open pull requests").foregroundStyle(.secondary) }
                    ForEach(repo.pulls) { p in
                        Button { if let u = URL(string: p.url) { openURL(u) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).foregroundStyle(.primary)
                                    Text("#\(p.number) · \(p.author)\(p.draft ? " · draft" : "")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Pill(text: p.checks, color: p.checks == "passing" ? Theme.ok : p.checks == "failing" ? Theme.action : .secondary)
                            }
                        }
                    }
                    ForEach(repo.latestRuns.prefix(4)) { r in
                        Button { if let u = URL(string: r.url) { openURL(u) } } label: {
                            HStack {
                                StatusLight(color: r.status != "completed" ? Theme.live : r.conclusion == "success" ? Theme.ok : r.conclusion == "failure" ? Theme.action : .secondary,
                                            pulsing: r.status != "completed", size: 6)
                                Text(r.name).foregroundStyle(.primary)
                                Spacer()
                                Text(r.status == "completed" ? (r.conclusion ?? "") : r.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let live = brain.sessions.filter { $0.session.project == project.path }
            if !live.isEmpty {
                Section("Claude sessions (24h)") {
                    ForEach(live, id: \.session.id) { s in
                        HStack {
                            StatusLight(color: s.session.state == "active" ? Theme.live : s.session.state == "waiting" ? Theme.watch : .secondary,
                                        pulsing: s.session.state == "active", size: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.session.title).lineLimit(2)
                                Text("\(s.session.state) · \(s.machine) · \(ago(s.session.lastDate)) ago").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                row("Mac", machine)
                row("Location", project.path)
                if let b = project.branch, !b.isEmpty { row("Branch", b) }
                if let r = project.remote, !r.isEmpty { row("GitHub", r) }
                row("Uncommitted files", "\(project.dirtyFiles ?? 0)")
                row("Unpushed commits", "\(max(project.unpushed ?? 0, 0))")
                if let m = project.lastModified { row("Last touched", String(m.prefix(10))) }
            }
            let links = brain.map.filter { $0.localizedCaseInsensitiveContains(project.name) }
            if !links.isEmpty { Section("Tied to") { ForEach(links, id: \.self) { Text($0).font(.callout) } } }
            let notes = brain.notes.filter { $0.topic.caseInsensitiveCompare(project.name) == .orderedSame }
            if !notes.isEmpty { Section("Decisions") { ForEach(notes) { Text($0.text) } } }
        }
        .navigationTitle(project.name)
        .sheet(isPresented: $composing) { NewMissionView(machine: machine, projectPath: project.path) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).textSelection(.enabled).multilineTextAlignment(.trailing) }
    }
}
