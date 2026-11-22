import SwiftUI

struct TodayView: View {
    @EnvironmentObject var brain: BrainStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    macs
                    alertSection("Needs you", brain.needsYou, empty: "Nothing needs you right now.")
                    alertSection("Keep an eye on", brain.watch, empty: nil)
                    if !brain.notes.isEmpty { latestNotes }
                    if !brain.nightlyReport.isEmpty { nightly }
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await brain.reload() }
            .navigationTitle("Today")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem { Button { Task { await brain.reload() } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(Theme.label).tracking(1.2).foregroundStyle(.secondary)
            Text(greeting).font(Theme.display(34))
            Text(summary).font(.title3).foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning, Paul" : h < 18 ? "Good afternoon, Paul" : "Good evening, Paul"
    }

    private var summary: String {
        let n = brain.needsYou.count
        return n == 0 ? "All clear on both Macs." : "\(n) thing\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") you."
    }

    private var macs: some View {
        HStack(spacing: 12) {
            ForEach(brain.machines) { m in
                let hours = brain.staleHours(m)
                let stale = (hours ?? 99) >= (m.isLaptop ? 96 : 3)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: m.isLaptop ? "laptopcomputer" : "desktopcomputer").foregroundStyle(Theme.accent)
                        Spacer()
                        Circle().fill(stale ? Theme.watch : Theme.ok).frame(width: 8, height: 8)
                    }
                    Text(m.machine).font(.headline).lineLimit(1)
                    Text(hours.map { $0 == 0 ? "Checked in this hour" : "Checked in \($0)h ago" } ?? "Not checked in")
                        .font(.caption).foregroundStyle(stale ? Theme.watch : .secondary)
                    Text("\(m.projects.count) projects").font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }
        }
    }

    @ViewBuilder
    private func alertSection(_ title: String, _ items: [MergedAlert], empty: String?) -> some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: title)
                if items.isEmpty, let empty {
                    Label(empty, systemImage: "checkmark.seal").foregroundStyle(Theme.ok).card()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                LevelDot(level: a.level)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(a.message).font(.body)
                                    Text("\(a.area) · \(a.machine)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 10)
                            if i < items.count - 1 { Divider() }
                        }
                    }
                    .card()
                }
            }
        }
    }

    private var latestNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Latest decisions")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(brain.notes.prefix(3)) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.text)
                        Text("\(n.topic) · \(String(n.created.prefix(10)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .card()
        }
    }

    private var nightly: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Last night's check")
            DisclosureGroup("Full report") {
                Text(brain.nightlyReport).font(Theme.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            .card()
        }
    }
}
