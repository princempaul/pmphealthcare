import SwiftUI

struct MissionRef: Hashable {
    let machine: String
    let id: String
}

/// Home: the control tower. What needs Paul, what's in flight, and the health of everything he runs.
struct TowerView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var github: GitHubStore
    @EnvironmentObject var sites: SiteMonitor
    @Binding var tab: Int
    @AppStorage("dismissed") private var dismissedRaw = ""
    @State private var path = NavigationPath()
    @State private var toast: String?
    @State private var confirm: TowerItem?
    @State private var working: String?

    private var dismissed: Set<String> { Set(dismissedRaw.split(separator: "\n").map(String.init)) }
    private var needs: [TowerItem] { TowerBoard.needsYou(brain: brain, github: github, sites: sites).filter { !dismissed.contains($0.id) } }
    private var flights: [TowerBoard.Flight] { TowerBoard.inFlight(brain: brain, github: github) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    gauges
                    needsSection
                    if !flights.isEmpty { flightSection }
                    fleetSection
                    if !sites.sites.isEmpty { sitesSection }
                    briefSection
                }
                .padding(20)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await refreshAll() }
            .navigationTitle("Tower")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem {
                    Button { Task { await refreshAll() } } label: {
                        if github.busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .navigationDestination(for: MissionRef.self) { ref in MissionDetailView(ref: ref) }
            .overlay(alignment: .bottom) { toastView }
            .confirmationDialog(confirm?.primary?.label ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible, presenting: confirm) { item in
                Button(item.primary?.label ?? "Go") { run(item) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(item.title)
            }
        }
    }

    // MARK: header and gauges

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(Theme.label).tracking(1.4).foregroundStyle(.secondary)
            Text(greeting).font(Theme.display(32))
            HStack(spacing: 8) {
                StatusLight(color: headline.1, pulsing: !flights.isEmpty)
                Text(headline.0).font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning, Paul" : h < 18 ? "Good afternoon, Paul" : "Good evening, Paul"
    }

    private var headline: (String, Color) {
        let action = needs.filter { $0.level == .action }.count
        let live = flights.count
        if action > 0 { return ("\(action) need\(action == 1 ? "s" : "") you\(live > 0 ? " · \(live) in flight" : "")", Theme.action) }
        if live > 0 { return ("All clear · \(live) in flight", Theme.live) }
        return ("All clear. Nothing needs you.", Theme.ok)
    }

    private var gauges: some View {
        let online = brain.fleet.filter(\.isOnline).count
        let activeSessions = brain.sessions.filter { $0.session.state == "active" }.count
        let waiting = brain.sessions.filter { $0.session.state == "waiting" }.count
        let liveMissions = brain.missions.filter { $0.mission.isLive }.count
        let failing = github.failingRuns.count
        let up = sites.sites.filter(\.isUp).count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
            TowerGauge(icon: "desktopcomputer", label: "Macs", value: brain.fleet.isEmpty ? "–" : "\(online)/\(brain.fleet.count)",
                  color: brain.fleet.isEmpty ? .secondary : online == brain.fleet.count ? Theme.ok : Theme.watch)
            TowerGauge(icon: "sparkles", label: "Claude", value: "\(activeSessions)", sub: waiting > 0 ? "\(waiting) waiting" : "live",
                  color: waiting > 0 ? Theme.watch : activeSessions > 0 ? Theme.live : .secondary, pulsing: activeSessions > 0)
            TowerGauge(icon: "scope", label: "Missions", value: "\(liveMissions)", sub: "running",
                  color: liveMissions > 0 ? Theme.live : .secondary, pulsing: liveMissions > 0)
                .onTapGesture { tab = 2 }
            TowerGauge(icon: "hammer", label: "Builds", value: github.hasToken ? "\(failing)" : "–", sub: "failing",
                  color: !github.hasToken ? .secondary : failing > 0 ? Theme.action : Theme.ok)
            TowerGauge(icon: "globe", label: "Sites", value: sites.sites.isEmpty ? "–" : "\(up)/\(sites.sites.count)", sub: "up",
                  color: sites.sites.isEmpty ? .secondary : up == sites.sites.count ? Theme.ok : Theme.action)
        }
    }

    // MARK: needs you

    private var needsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Needs you", trailing: needs.isEmpty ? nil : "\(needs.count)")
            if needs.isEmpty {
                Label("Nothing needs you right now.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok).card()
            } else {
                ForEach(needs) { item in itemCard(item) }
            }
        }
    }

    private func itemCard(_ item: TowerItem) -> some View {
        let color = Theme.color(for: item.level)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                .frame(width: 34, height: 34).background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(3)
                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Text(item.source.uppercased()).font(Theme.monoSmall).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let p = item.primary {
                Button {
                    if case .open(let url) = p.action { openURL(url) } else { confirm = item }
                } label: {
                    if working == item.id { ProgressView().controlSize(.small) } else { Text(p.label).font(.caption.weight(.semibold)) }
                }
                .buttonStyle(.borderedProminent).tint(color).controlSize(.small).disabled(working != nil)
            }
        }
        .card(tint: item.level == .action ? color : nil)
        .contentShape(Rectangle())
        .onTapGesture { if let t = item.tap { follow(t) } }
        .contextMenu {
            Button("Dismiss until it changes", systemImage: "eye.slash") { dismissedRaw = (Array(dismissed) + [item.id]).suffix(300).joined(separator: "\n") }
        }
    }

    // MARK: in flight

    private var flightSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "In flight", trailing: "\(flights.count)")
            VStack(spacing: 0) {
                ForEach(Array(flights.enumerated()), id: \.element.id) { i, f in
                    HStack(spacing: 12) {
                        StatusLight(color: f.tint, pulsing: true, size: 7)
                        Image(systemName: f.icon).foregroundStyle(f.tint).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.subheadline).lineLimit(1)
                            Text(f.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if f.tap != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .onTapGesture { if let t = f.tap { follow(t) } }
                    if i < flights.count - 1 { Divider() }
                }
            }
            .card()
        }
    }

    // MARK: fleet

    private var fleetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Fleet")
            if brain.fleet.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Mac's crew has checked in yet.").font(.subheadline.weight(.semibold))
                    Text("On the iMac, in the pmphealthcare folder: git pull && ./install.sh. It starts the crew and shows the pairing code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }
            ForEach(brain.fleet) { f in macCard(f) }
        }
    }

    private func macCard(_ f: FleetSnapshot) -> some View {
        let h = f.host
        let snap = brain.machines.first { $0.machine == f.machine }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: f.laptop == true ? "laptopcomputer" : "desktopcomputer").font(.title3).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.machine).font(.headline)
                    Text(f.isOnline ? "Online · checked in \(ago(f.generatedDate)) ago" : "Offline · last seen \(ago(f.generatedDate)) ago")
                        .font(.caption).foregroundStyle(f.isOnline ? .secondary : Theme.watch)
                }
                Spacer()
                StatusLight(color: f.isOnline ? Theme.ok : (f.laptop == true ? .secondary : Theme.action), pulsing: f.isOnline)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                stat("Disk free", h?.diskFreeGb.map { "\(Int($0)) GB" } ?? "–", warn: (h?.diskFreeGb ?? 100) < 20)
                stat("Uptime", h?.uptimeH.map { $0 < 48 ? "\(Int($0))h" : "\(Int($0 / 24))d" } ?? "–")
                stat(f.laptop == true ? "Battery" : "Load", f.laptop == true ? (h?.batteryPct.map { "\($0)%" } ?? "–") : (h?.load.map { String(format: "%.1f", $0) } ?? "–"))
                stat("Claude Code", h?.claude == true ? "Ready" : "Missing", warn: h?.claude != true)
                stat("Paired", f.paired == true ? "Yes" : "No", warn: f.paired != true)
                stat("Projects", snap.map { "\($0.projects.count)" } ?? "–")
            }
        }
        .card()
    }

    private func stat(_ k: String, _ v: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(Theme.monoSmall).foregroundStyle(.tertiary)
            Text(v).font(.subheadline.weight(.semibold)).foregroundStyle(warn ? Theme.watch : .primary)
        }
    }

    // MARK: sites and brief

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Websites")
            VStack(spacing: 0) {
                ForEach(Array(sites.sites.enumerated()), id: \.element.id) { i, s in
                    HStack {
                        StatusLight(color: s.isUp ? Theme.ok : Theme.action, size: 7)
                        Text(s.host).font(.subheadline)
                        Spacer()
                        Text(s.isUp ? "\(s.ms) ms" : (s.status > 0 ? "HTTP \(s.status)" : "No answer"))
                            .font(Theme.mono).foregroundStyle(s.isUp ? Color.secondary : Theme.action)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { if let u = URL(string: s.url) { openURL(u) } }
                    if i < sites.sites.count - 1 { Divider() }
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private var briefSection: some View {
        if !brain.notes.isEmpty || !brain.nightlyReport.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Brief")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(brain.notes.prefix(3)) { n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.text).font(.subheadline)
                            Text("\(n.topic) · \(String(n.created.prefix(10)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !brain.nightlyReport.isEmpty {
                        DisclosureGroup("Last night's full check") {
                            Text(brain.nightlyReport).font(Theme.mono).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                        .font(.subheadline)
                    }
                }
                .card()
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast).font(.callout).padding(.horizontal, 16).padding(.vertical, 12)
                .background(.thickMaterial, in: Capsule()).padding(.bottom, 16).padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { self.toast = nil }
        }
    }

    // MARK: actions

    @Environment(\.openURL) private var openURL

    private func follow(_ action: TowerItem.Action) {
        switch action {
        case .open(let url): openURL(url)
        case .mission(let machine, let id): path.append(MissionRef(machine: machine, id: id))
        case .settings: tab = 4
        default: break
        }
    }

    private func run(_ item: TowerItem) {
        guard let p = item.primary else { return }
        working = item.id
        Task {
            do {
                let msg = try await Dispatcher.perform(p.action, brain: brain, github: github)
                show(msg ?? "Done.")
            } catch {
                show(error.localizedDescription)
            }
            working = nil
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if toast == message { toast = nil } }
        }
    }

    private func refreshAll() async {
        async let a: Void = Dispatcher.refresh(brain: brain, github: github)
        async let b: Void = sites.refresh()
        _ = await (a, b)
    }
}

struct TowerGauge: View {
    let icon: String
    let label: String
    let value: String
    var sub: String? = nil
    var color: Color = .secondary
    var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Spacer()
                StatusLight(color: color, pulsing: pulsing, size: 6)
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text((sub ?? label).uppercased()).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
            if sub != nil { Text(label.uppercased()).font(Theme.monoSmall).foregroundStyle(.tertiary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}
