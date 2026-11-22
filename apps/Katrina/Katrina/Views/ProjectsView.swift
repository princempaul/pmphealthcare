import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var brain: BrainStore
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
    let machine: String
    let project: MachineSnapshot.Project

    var body: some View {
        List {
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
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).textSelection(.enabled).multilineTextAlignment(.trailing) }
    }
}
