import Foundation

/// What each Mac writes to iCloud Drive/PMPBrain/machines/<Mac>.json (see brain.py export_snapshot).
struct MachineSnapshot: Decodable, Identifiable, Hashable {
    let machine: String
    let laptop: Int?
    let generated: String
    let lastRun: String?
    let projects: [Project]
    let alerts: [Alert]
    let notes: [Note]
    let map: [String]?
    let facts: [String: String]?

    var id: String { machine }
    var isLaptop: Bool { (laptop ?? 0) == 1 }
    var generatedDate: Date? { Date.fromBrain(generated) }

    enum CodingKeys: String, CodingKey {
        case machine, laptop, generated, projects, alerts, notes, map, facts
        case lastRun = "last_run"
    }

    struct Project: Decodable, Hashable, Identifiable {
        let name: String
        let path: String
        let category: String?
        let kind: String?
        let branch: String?
        let remote: String?
        let dirtyFiles: Int?
        let unpushed: Int?
        let lastModified: String?
        let uses: [String]?

        var id: String { path }
        var isLoose: Bool { (dirtyFiles ?? 0) > 0 || (unpushed ?? 0) > 0 }

        enum CodingKeys: String, CodingKey {
            case name, path, category, kind, branch, remote, uses
            case dirtyFiles = "dirty_files", unpushed, lastModified = "last_modified"
        }
    }

    struct Alert: Decodable, Hashable {
        let level: String
        let area: String
        let message: String
    }

    struct Note: Decodable, Hashable {
        let created: String
        let topic: String
        let text: String
    }
}

struct MergedAlert: Identifiable, Hashable {
    let id = UUID()
    let machine: String
    let level: String
    let area: String
    let message: String
}

struct MergedNote: Identifiable, Hashable {
    let id = UUID()
    let machine: String
    let created: String
    let topic: String
    let text: String
    var date: Date? { Date.fromBrain(created) }
}

extension Date {
    static func fromBrain(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: String(s.prefix(19))) { return d }
        }
        return nil
    }
}

// MARK: - Fleet: what each Mac's ground crew writes to PMPBrain/fleet/<Mac>.json every 20 seconds (crew.py)

struct FleetSnapshot: Decodable, Identifiable, Hashable {
    let machine: String
    let laptop: Bool?
    let generated: String
    let paired: Bool?
    let keyId: String?
    let host: MacHealth?
    let sessions: [Session]
    let missions: [Mission]
    let github: GitHubView?
    let disk: Disk?

    enum CodingKeys: String, CodingKey {
        case machine, laptop, generated, paired, host, sessions, missions, github, disk
        case keyId = "key_id"
    }

    /// Where the space went (measured when the disk is over 85% full) and what "Clear caches" can free.
    struct Disk: Decodable, Hashable {
        let checked: String?
        let running: Bool?
        let places: [Place]?
        let caches: [Place]?
        let safeGb: Double?
        let cleaned: String?
        let freedGb: Double?

        struct Place: Decodable, Hashable {
            let label: String
            let path: String?
            let gb: Double
        }
        enum CodingKeys: String, CodingKey {
            case checked, running, places, caches, cleaned
            case safeGb = "safe_gb", freedGb = "freed_gb"
        }
    }

    /// GitHub as this Mac sees it with its own git login (crew.py github_status).
    struct GitHubView: Decodable, Hashable {
        let ok: Bool?
        let error: String?
        let checked: String?
        let repos: [Repo]?
        let results: [ActionResult]?

        struct Repo: Decodable, Hashable {
            let slug: String
            let defaultBranch: String?
            let error: String?
            let pulls: [Pull]?
            let runs: [Run]?
            enum CodingKeys: String, CodingKey { case slug, error, pulls, runs; case defaultBranch = "default_branch" }
        }
        struct Pull: Decodable, Hashable {
            let number: Int
            let title: String?
            let author: String?
            let draft: Bool?
            let head: String?
            let headSha: String?
            let url: String?
            let updated: String?
            let checks: String?
            enum CodingKeys: String, CodingKey { case number, title, author, draft, head, url, updated, checks; case headSha = "head_sha" }
        }
        struct Run: Decodable, Hashable {
            let id: Int
            let name: String?
            let status: String?
            let conclusion: String?
            let branch: String?
            let url: String?
            let created: String?
        }
        struct ActionResult: Decodable, Hashable {
            let kind: String?
            let ok: Bool?
            let message: String?
            let url: String?
            let at: String?
        }
    }

    var id: String { machine }
    var generatedDate: Date? { Date.fromBrain(generated) }
    /// The crew writes every 20 seconds; iCloud adds some delay. Past 3 minutes, call it offline.
    var isOnline: Bool { generatedDate.map { Date().timeIntervalSince($0) < 180 } ?? false }

    struct MacHealth: Decodable, Hashable {
        let diskFreeGb: Double?
        let diskUsedPct: Int?
        let load: Double?
        let uptimeH: Double?
        let macos: String?
        let batteryPct: Int?
        let claude: Bool?
        let brainQuick: String?
        let brainNightly: String?
        let brainNightlyOk: Bool?
        let version: String?

        enum CodingKeys: String, CodingKey {
            case load, macos, claude, version
            case diskFreeGb = "disk_free_gb", diskUsedPct = "disk_used_pct", uptimeH = "uptime_h"
            case batteryPct = "battery_pct", brainQuick = "brain_quick", brainNightly = "brain_nightly"
            case brainNightlyOk = "brain_nightly_ok"
        }
    }

    /// A Claude Code conversation on that Mac in the last 24 hours. Titles only; clinical ones are blanked.
    struct Session: Decodable, Hashable, Identifiable {
        let id: String
        let project: String
        let title: String
        let category: String?
        let started: String?
        let last: String?
        let messages: Int?
        let state: String          // active | waiting | idle
        let mission: String?

        var lastDate: Date? { last.flatMap(Date.fromBrain) }
        var projectName: String { (project as NSString).lastPathComponent }
    }

    /// Work Paul delegated from the phone. States: queued, running, done, needs_approval, pushed, failed, stopped, discarded, closed.
    struct Mission: Decodable, Hashable, Identifiable {
        let id: String
        let mode: String?
        let project: String?
        let projectName: String?
        let prompt: String?
        let created: String?
        let started: String?
        let finished: String?
        let updated: String?
        let state: String
        let result: String?
        let turns: [Turn]?
        let branch: String?
        let commits: Int?
        let diffstat: String?
        let compare: String?
        let repo: String?
        let costUsd: Double?
        let numTurns: Int?
        let error: String?
        let pr: String?

        struct Turn: Decodable, Hashable {
            let who: String
            let text: String
        }

        var isWork: Bool { mode == "work" }
        var isLive: Bool { state == "running" || state == "queued" }
        var createdDate: Date? { created.flatMap(Date.fromBrain) }
        var title: String { (prompt ?? "").isEmpty ? "Mission" : prompt! }

        enum CodingKeys: String, CodingKey {
            case id, mode, project, prompt, created, started, finished, updated, state, result, turns
            case branch, commits, diffstat, compare, repo, error, pr
            case projectName = "project_name", costUsd = "cost_usd", numTurns = "num_turns"
        }
    }
}
