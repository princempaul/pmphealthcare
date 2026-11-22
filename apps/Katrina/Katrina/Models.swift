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
