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
        if !github.hasToken {
            items.append(TowerItem(id: "setup-github", level: .info, icon: "chevron.left.forwardslash.chevron.right", title: "Add a GitHub token",
                                   detail: "Shows pull requests and builds across every repo, and lets you merge from here.", source: "Setup", tap: .settings))
        }

        // The Macs themselves.
        for f in brain.fleet where !(f.laptop ?? false) && !f.isOnline {
            let mins = f.generatedDate.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
            items.append(TowerItem(id: "offline-\(f.machine)-\(mins / 30)", level: .action, icon: "desktopcomputer.trianglebadge.exclamationmark",
                                   title: "\(f.machine) is off the radar", detail: "Its crew last checked in \(mins) min ago. Missions sent now wait until it's back.",
                                   source: "Fleet"))
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
                if let slug = m.repo, !slug.isEmpty, !pulls.contains(where: { $0.repo.slug == slug && $0.pull.head == branch }) {
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
        case .open, .mission, .settings:
            return nil
        }
    }

    static func refresh(brain: BrainStore, github: GitHubStore) async {
        await brain.reload()
        let slugs = brain.projects.compactMap { GitHubStore.slug(fromRemote: $0.project.remote) }
        await github.refresh(slugs: slugs)
    }
}
