import Foundation
import SwiftUI

/// One line on the tower board: something that needs Paul, or something in flight.
struct TowerItem: Identifiable, Hashable {
    enum Level: Int, Comparable { case action = 0, watch = 1, info = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    enum Action: Hashable {
        case approvePush(machine: String, mission: String)
        case openPull(machine: String, mission: String, slug: String, branch: String, title: String)
        case merge(slug: String, number: Int)
        case rerun(slug: String, run: Int)
        case cleanup(machine: String)
        case open(URL)
        case mission(machine: String, id: String)
        case settings
    }

    let id: String               // stable while the underlying state is the same, so "dismiss" sticks
    let level: Level
    let icon: String
    let title: String
    let detail: String
    let source: String
    var primary: (label: String, action: Action)? = nil
    var tap: Action? = nil

    static func == (a: TowerItem, b: TowerItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Builds the board from what the stores already hold. Pure: no network, no tokens.
@MainActor
enum TowerBoard {
    static func needsYou(brain: BrainStore, github: GitHubStore, sites: SiteMonitor) -> [TowerItem] {
        var items: [TowerItem] = []
        let pulls = github.openPulls

        // Setup gaps come first: without them the tower is half blind.
        if !brain.hasFolder {
            items.append(TowerItem(id: "setup-folder", level: .action, icon: "folder.badge.plus", title: "Connect the PMPBrain folder",
                                   detail: "So Katrina can see both Macs, every Claude session and your missions.", source: "Setup", tap: .settings))
        } else if Keychain.pairingCode == nil {
            items.append(TowerItem(id: "setup-pair", level: .action, icon: "link.badge.plus", title: "Pair with your Macs",
                                   detail: "Lets you send missions to the iMac. On the Mac run: python3 ~/PMPBrain/crew.py pair", source: "Setup", tap: .settings))
        }
        if !github.connected && !brain.fleet.isEmpty {
            items.append(TowerItem(id: "setup-github", level: .info, icon: "chevron.left.forwardslash.chevron.right", title: "GitHub isn't visible yet",
                                   detail: github.error ?? "The iMac uses its own GitHub login once it has pushed code once. Or add a token in Settings.",
                                   source: "Setup", tap: .settings))
        }

        // The Macs themselves.
        for f in brain.fleet where !(f.laptop ?? false) && !f.isOnline {
            let mins = f.generatedDate.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
            items.append(TowerItem(id: "offline-\(f.machine)-\(mins / 30)", level: .action, icon: "desktopcomputer.trianglebadge.exclamationmark",
                                   title: "\(f.machine) is off the radar", detail: "Its crew last checked in \(mins) min ago. Missions sent now wait until it's back.",
                                   source: "Fleet"))
        }

        // Jane desk on the always-on Mac.
        if let mac = brain.commandMac, mac.isOnline, mac.host?.janeDesk == false {
            items.append(TowerItem(id: "jane-desk-\(mac.machine)", level: .watch, icon: "stethoscope",
                                   title: "Jane desk isn't running on \(mac.machine)",
                                   detail: "On the iMac, in Terminal: cd ~/pmp-brain-src && ./jane-desk.sh", source: "Jane"))
        }

        // Disk space: one tap clears caches that rebuild themselves.
        for f in brain.fleet {
            guard let used = f.host?.diskUsedPct, used >= 85, let d = f.disk else { continue }
            let safe = d.safeGb ?? 0
            let top = (d.places ?? []).filter { $0.gb >= 1 }.prefix(3).map { "\($0.label) \(Int($0.gb.rounded())) GB" }.joined(separator: " · ")
            if safe >= 0.5 {
                items.append(TowerItem(id: "disk-\(f.machine)-\(d.checked ?? "")", level: .action, icon: "externaldrive.badge.minus",
                                       title: "\(f.machine): \(String(format: "%.1f", safe)) GB of throwaway caches can go",
                                       detail: top.isEmpty ? "Xcode, simulator and download caches. They rebuild themselves." : "Biggest: \(top)",
                                       source: "Disk \(used)% full",
                                       primary: (label: "Clear caches", action: .cleanup(machine: f.machine))))
            } else if !top.isEmpty {
                items.append(TowerItem(id: "disk-\(f.machine)-\(d.checked ?? "")", level: .watch, icon: "externaldrive",
                                       title: "\(f.machine) is \(used)% full", detail: "Biggest: \(top). Only you can decide what to delete there.",
                                       source: "Disk"))
            }
        }

        // Missions.
        for (machine, m) in brain.missions {
            switch m.state {
            case "needs_approval":
                items.append(TowerItem(id: "m-\(m.id)-approve", level: .action, icon: "checkmark.seal",
                                       title: "Approve: \(m.title)",
                                       detail: "\(m.projectName ?? "") · \(m.commits ?? 0) commit\((m.commits ?? 0) == 1 ? "" : "s")\(m.diffstat.map { " · " + $0 } ?? "")",
                                       source: "Mission on \(machine)",
                                       primary: (label: "Approve & push", action: .approvePush(machine: machine, mission: m.id)),
                                       tap: .mission(machine: machine, id: m.id)))
            case "pushed":
                let branch = m.branch ?? ""
                if let slug = m.repo, !slug.isEmpty, (m.pr ?? "").isEmpty,
                   !pulls.contains(where: { $0.repo.slug == slug && $0.pull.head == branch }) {
                    items.append(TowerItem(id: "m-\(m.id)-pr", level: .action, icon: "arrow.triangle.pull",
                                           title: "Open a pull request: \(m.title)", detail: "\(slug) · \(branch)", source: "Mission on \(machine)",
                                           primary: (label: "Open PR", action: .openPull(machine: machine, mission: m.id, slug: slug, branch: branch, title: m.title)),
                                           tap: .mission(machine: machine, id: m.id)))
                }
            case "failed":
                if let d = m.createdDate, Date().timeIntervalSince(d) < 86400 {
                    items.append(TowerItem(id: "m-\(m.id)-failed", level: .watch, icon: "xmark.octagon",
                                           title: "Mission failed: \(m.title)", detail: m.error ?? "", source: "Mission on \(machine)",
                                           tap: .mission(machine: machine, id: m.id)))
                }
            case "done":
                if let d = m.createdDate, Date().timeIntervalSince(d) < 86400 {
                    items.append(TowerItem(id: "m-\(m.id)-done", level: .info, icon: "text.badge.checkmark",
                                           title: "Report ready: \(m.title)", detail: String((m.result ?? "").prefix(140)),
                                           source: "Mission on \(machine)", tap: .mission(machine: machine, id: m.id)))
                }
            default: break
            }
        }

        // Claude Code sessions waiting on Paul.
        for (machine, s) in brain.sessions where s.state == "waiting" && (s.mission ?? "").isEmpty {
            items.append(TowerItem(id: "s-\(s.id)-\(s.last ?? "")", level: .watch, icon: "bubble.left.and.exclamationmark.bubble.right",
                                   title: "Claude is waiting for you", detail: "\(s.projectName) · \(s.title)", source: "Session on \(machine)",
                                   primary: (label: "Open Claude", action: .open(URL(string: "https://claude.ai/code")!))))
        }

        // Pull requests and builds.
        for (repo, p) in pulls where !p.draft {
            if p.checks == "passing" || p.checks == "none" {
                items.append(TowerItem(id: "pr-\(repo.slug)-\(p.number)-\(p.headSha)", level: .action, icon: "arrow.triangle.merge",
                                       title: "Ready to merge: \(p.title)", detail: "\(repo.name) #\(p.number) · checks \(p.checks)", source: "GitHub",
                                       primary: (label: "Merge", action: .merge(slug: repo.slug, number: p.number)), tap: URL(string: p.url).map { .open($0) }))
            } else if p.checks == "failing" {
                items.append(TowerItem(id: "prf-\(repo.slug)-\(p.number)-\(p.headSha)", level: .watch, icon: "exclamationmark.triangle",
                                       title: "Checks failing: \(p.title)", detail: "\(repo.name) #\(p.number)", source: "GitHub",
                                       tap: URL(string: p.url).map { .open($0) }))
            }
        }
        for (repo, r) in github.failingRuns {
            items.append(TowerItem(id: "run-\(repo.slug)-\(r.id)", level: .watch, icon: "hammer",
                                   title: "\(r.name) failed", detail: "\(repo.name) · \(r.branch)", source: "GitHub",
                                   primary: (label: "Re-run", action: .rerun(slug: repo.slug, run: r.id)), tap: URL(string: r.url).map { .open($0) }))
        }

        // Websites.
        for s in sites.sites where s.isDown {
            items.append(TowerItem(id: "site-\(s.url)", level: .action, icon: "globe.badge.chevron.backward",
                                   title: "\(s.host) is down", detail: s.error ?? "HTTP \(s.status)", source: "Websites",
                                   tap: URL(string: s.url).map { .open($0) }))
        }

        // Heartbeat: a check that silently stopped running looks the same as "all clear" unless it's called out.
        for f in brain.fleet where f.isOnline && !(f.laptop ?? false) {
            if let last = f.host?.brainNightly.flatMap(Date.fromBrain), Date().timeIntervalSince(last) > 36 * 3600 {
                items.append(TowerItem(id: "beat-nightly-\(f.machine)-\(Int(Date().timeIntervalSince(last) / 86400))", level: .watch, icon: "moon.zzz",
                                       title: "\(f.machine): the nightly check hasn't run for \(ago(last))",
                                       detail: "Alerts from it are out of date. On the Mac: launchctl list | grep pmphealthcare", source: "Heartbeat"))
            }
            if let last = f.host?.brainQuick.flatMap(Date.fromBrain), Date().timeIntervalSince(last) > 3 * 3600 {
                items.append(TowerItem(id: "beat-quick-\(f.machine)-\(Int(Date().timeIntervalSince(last) / 21600))", level: .watch, icon: "clock.badge.exclamationmark",
                                       title: "\(f.machine): the hourly refresh hasn't run for \(ago(last))",
                                       detail: "Project and session lists may be stale.", source: "Heartbeat"))
            }
        }

        // What the nightly check flagged.
        for a in brain.needsYou {
            items.append(TowerItem(id: "a-\(a.machine)-\(a.area)-\(a.message)", level: .action, icon: "exclamationmark.circle",
                                   title: a.message, detail: a.area, source: "Nightly check · \(a.machine)"))
        }
        for a in brain.watch {
            items.append(TowerItem(id: "a-\(a.machine)-\(a.area)-\(a.message)", level: .watch, icon: "eye",
                                   title: a.message, detail: a.area, source: "Nightly check · \(a.machine)"))
        }
        return items.sorted { $0.level < $1.level }
    }

    struct Flight: Identifiable, Hashable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let tint: Color
        var tap: TowerItem.Action? = nil
        static func == (a: Flight, b: Flight) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    static func inFlight(brain: BrainStore, github: GitHubStore) -> [Flight] {
        var out: [Flight] = []
        for (machine, m) in brain.missions where m.isLive {
            out.append(Flight(id: "m-\(m.id)", icon: m.isWork ? "hammer.fill" : "binoculars.fill", title: m.title,
                              detail: "\(m.state == "queued" ? "Queued" : "Working") · \(m.projectName ?? "") · \(machine)",
                              tint: Theme.live, tap: .mission(machine: machine, id: m.id)))
        }
        for (machine, s) in brain.sessions where s.state == "active" {
            out.append(Flight(id: "s-\(s.id)", icon: "sparkles", title: s.title, detail: "Claude Code · \(s.projectName) · \(machine)", tint: Theme.accent))
        }
        for (repo, r) in github.runningRuns {
            out.append(Flight(id: "r-\(r.id)", icon: "gearshape.2.fill", title: r.name, detail: "GitHub Actions · \(repo.name) · \(r.branch)",
                              tint: Theme.watch, tap: URL(string: r.url).map { .open($0) }))
        }
        for (repo, p) in github.openPulls where p.draft {
            out.append(Flight(id: "pr-\(p.id)-\(repo.slug)", icon: "arrow.triangle.pull", title: p.title, detail: "Draft PR · \(repo.name) #\(p.number)",
                              tint: .secondary, tap: URL(string: p.url).map { .open($0) }))
        }
        return out
    }
}

/// Carries out a tower action. Every one of these starts from Paul's tap.
@MainActor
enum Dispatcher {
    static func perform(_ action: TowerItem.Action, brain: BrainStore, github: GitHubStore) async throws -> String? {
        switch action {
        case .approvePush(let machine, let id):
            try brain.send(CrewOrder(kind: .push, machine: machine, mission: id))
            return "Sent. \(machine) pushes the branch within a minute."
        case .openPull(_, _, let slug, let branch, let title) where !github.hasToken:
            guard let mac = github.viaMac else { throw GitHubStore.GitHubError.noToken }
            try brain.send(CrewOrder(kind: .ghOpenPR, machine: mac, project: slug, prompt: title, mission: branch))
            return "Sent. \(mac) opens the pull request within a minute."
        case .merge(let slug, let number) where !github.hasToken:
            guard let mac = github.viaMac,
                  let pull = github.repos.first(where: { $0.slug == slug })?.pulls.first(where: { $0.number == number })
            else { throw GitHubStore.GitHubError.noToken }
            try brain.send(CrewOrder(kind: .ghMerge, machine: mac, project: slug, prompt: pull.headSha, mission: "\(number)"))
            return "Sent. \(mac) merges #\(number) within a minute."
        case .rerun(let slug, let run) where !github.hasToken:
            guard let mac = github.viaMac else { throw GitHubStore.GitHubError.noToken }
            try brain.send(CrewOrder(kind: .ghRerun, machine: mac, project: slug, mission: "\(run)"))
            return "Sent. \(mac) re-runs it within a minute."
        case .openPull(_, _, let slug, let branch, let title):
            let url = try await github.openPull(slug: slug, branch: branch, title: title,
                                                body: "Opened from Katrina PA. Made by a Katrina mission on branch `\(branch)`.")
            await refresh(brain: brain, github: github)
            return url.isEmpty ? "Pull request opened." : "Pull request opened: \(url)"
        case .merge(let slug, let number):
            guard let repo = github.repos.first(where: { $0.slug == slug }),
                  let pull = repo.pulls.first(where: { $0.number == number }) else { return "That pull request has changed. Refresh." }
            try await github.merge(pull, in: repo)
            await refresh(brain: brain, github: github)
            return "Merged \(repo.name) #\(number)."
        case .rerun(let slug, let run):
            guard let repo = github.repos.first(where: { $0.slug == slug }),
                  let r = repo.runs.first(where: { $0.id == run }) else { return nil }
            try await github.rerun(r, in: repo)
            return "Re-running \(r.name)."
        case .cleanup(let machine):
            try brain.send(CrewOrder(kind: .cleanup, machine: machine))
            return "Sent. \(machine) clears its caches; the freed space shows in a minute or two."
        case .open, .mission, .settings:
            return nil
        }
    }

    static func refresh(brain: BrainStore, github: GitHubStore) async {
        await brain.reload()
        if github.hasToken {
            let slugs = brain.projects.compactMap { GitHubStore.slug(fromRemote: $0.project.remote) }
            await github.refresh(slugs: slugs)
        } else {
            adoptGitHub(brain: brain, github: github)
        }
    }

    /// No token on the phone: show GitHub as the always-on Mac sees it.
    static func adoptGitHub(brain: BrainStore, github: GitHubStore) {
        let mac = brain.fleet.filter { $0.github?.ok == true }
            .sorted { (($0.laptop ?? false) ? 1 : 0) < (($1.laptop ?? false) ? 1 : 0) }.first
            ?? brain.commandMac
        github.adopt(mac?.github, from: mac?.machine)
    }
}
