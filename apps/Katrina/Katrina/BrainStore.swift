import CryptoKit
import Foundation
import SwiftUI

/// Reads what the two Macs share in iCloud Drive > PMPBrain. All local: no AI call, no tokens.
@MainActor
final class BrainStore: ObservableObject {
    @Published private(set) var machines: [MachineSnapshot] = []
    @Published private(set) var fleet: [FleetSnapshot] = []
    @Published private(set) var nightlyReport: String = ""
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var error: String?
    @Published private(set) var folderName: String?

    private let bookmarkKey = "pmpbrain.folder.bookmark"

    var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    // MARK: derived views of the data

    var alerts: [MergedAlert] {
        machines.flatMap { m in m.alerts.map { MergedAlert(machine: m.machine, level: $0.level, area: $0.area, message: $0.message) } }
            .sorted { rank($0.level) < rank($1.level) }
    }
    var needsYou: [MergedAlert] { alerts.filter { $0.level.uppercased() == "ACTION" } }
    var watch: [MergedAlert] { alerts.filter { $0.level.uppercased() == "WATCH" } }

    var projects: [(machine: String, project: MachineSnapshot.Project)] {
        machines.flatMap { m in m.projects.map { (m.machine, $0) } }
            .sorted { ($0.project.category ?? "", $0.project.name) < ($1.project.category ?? "", $1.project.name) }
    }

    var notes: [MergedNote] {
        var seen = Set<String>()
        return machines.flatMap { m in m.notes.map { MergedNote(machine: m.machine, created: $0.created, topic: $0.topic, text: $0.text) } }
            .filter { seen.insert($0.created + $0.text).inserted }
            .sorted { $0.created > $1.created }
    }

    var map: [String] { Array(Set(machines.flatMap { $0.map ?? [] })).sorted() }
    var facts: [String: String] { machines.reduce(into: [:]) { $0.merge($1.facts ?? [:]) { a, _ in a } } }

    func staleHours(_ m: MachineSnapshot) -> Int? {
        guard let d = m.generatedDate else { return nil }
        return Int(Date().timeIntervalSince(d) / 3600)
    }

    private func rank(_ level: String) -> Int { ["ACTION": 0, "WATCH": 1][level.uppercased()] ?? 2 }

    // MARK: folder access

    func setFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            #if os(macOS)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            Task { await reload() }
        } catch {
            self.error = "Couldn't remember that folder: \(error.localizedDescription)"
        }
    }

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        if stale, let url { setFolder(url) }
        return url
    }

    // MARK: loading

    func reload() async {
        guard let folder = resolveFolder() else { return }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        folderName = folder.lastPathComponent
        let fm = FileManager.default
        let machinesDir = folder.appendingPathComponent("machines")
        var loaded: [MachineSnapshot] = []
        let files = (try? fm.contentsOfDirectory(at: machinesDir, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            // iCloud keeps not-yet-downloaded files as ".Name.json.icloud": ask for them and pick them up next refresh
            if f.lastPathComponent.hasSuffix(".icloud") {
                try? fm.startDownloadingUbiquitousItem(at: f)
                continue
            }
            guard f.pathExtension == "json", let data = readCoordinated(f),
                  let snap = try? JSONDecoder().decode(MachineSnapshot.self, from: data) else { continue }
            loaded.append(snap)
        }
        machines = loaded.sorted { $0.machine < $1.machine }
        var crews: [FleetSnapshot] = []
        let fleetDir = folder.appendingPathComponent("fleet")
        for f in (try? fm.contentsOfDirectory(at: fleetDir, includingPropertiesForKeys: nil)) ?? [] {
            if f.lastPathComponent.hasSuffix(".icloud") { try? fm.startDownloadingUbiquitousItem(at: f); continue }
            guard f.pathExtension == "json" else { continue }
            try? fm.startDownloadingUbiquitousItem(at: f)          // nudge iCloud for the newest copy
            if let data = readCoordinated(f), let snap = try? JSONDecoder().decode(FleetSnapshot.self, from: data) { crews.append(snap) }
        }
        fleet = crews.sorted { ($0.laptop ?? false ? 1 : 0, $0.machine) < ($1.laptop ?? false ? 1 : 0, $1.machine) }
        autoPair(folder)
        let report = folder.appendingPathComponent("latest-nightly.md")
        if let data = readCoordinated(report) { nightlyReport = String(decoding: data, as: UTF8.self) }
        error = loaded.isEmpty ? "No Mac snapshots found yet in \(folder.lastPathComponent)/machines. Run the installer on a Mac and wait for its hourly update." : nil
        lastLoaded = Date()
    }

    private func readCoordinated(_ url: URL) -> Data? {
        var out: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in out = try? Data(contentsOf: u) }
        return out
    }

    // MARK: notes (written for the Macs to import; they apply the same privacy rules)

    enum NoteError: LocalizedError {
        case patientDetail, noFolder, write(String)
        var errorDescription: String? {
            switch self {
            case .patientDetail: return "That reads like patient detail, so it wasn't kept. Say \"a patient inquiry\" instead."
            case .noFolder: return "Choose the PMPBrain folder in Settings first."
            case .write(let m): return "Couldn't save the note: \(m)"
            }
        }
    }

    func addNote(topic: String, text: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if Privacy.looksLikePatientDetail(topic + " " + clean) { throw NoteError.patientDetail }
        guard let folder = resolveFolder() else { throw NoteError.noFolder }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        let inbox = folder.appendingPathComponent("inbox")
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
            #if os(macOS)
            let device = Host.current().localizedName ?? "Mac"
            #else
            let device = "iPhone"
            #endif
            let note: [String: String] = ["created": f.string(from: Date()), "topic": topic.isEmpty ? "note" : topic,
                                          "text": String(clean.prefix(600)), "device": "Katrina app (\(device))"]
            let data = try JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted])
            try data.write(to: inbox.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
        } catch {
            throw NoteError.write(error.localizedDescription)
        }
    }

    // MARK: pairing without typing a code

    @Published private(set) var pairedAutomatically = UserDefaults.standard.bool(forKey: "paired.auto")

    static func keyId(_ code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// The Macs leave their pairing code in PMPBrain/pairing once. Take it (the always-on Mac's wins), say thanks
    /// with an ack file so they delete it. Re-take it if the always-on Mac has been re-keyed since.
    private func autoPair(_ folder: URL) {
        let dir = folder.appendingPathComponent("pairing")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        struct Offer { let machine: String; let laptop: Bool; let code: String }
        var offers: [Offer] = []
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasPrefix("ack-") {
            try? fm.startDownloadingUbiquitousItem(at: f)
            guard let data = readCoordinated(f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let machine = obj["machine"] as? String,
                  let code = CrewOrder.normalise(obj["code"] as? String ?? "") else { continue }
            offers.append(Offer(machine: machine, laptop: obj["laptop"] as? Bool ?? false, code: code))
        }
        guard !offers.isEmpty else { return }
        let best = offers.first { !$0.laptop } ?? offers[0]
        let current = Keychain.pairingCode
        let commandKey = fleet.first { $0.machine == best.machine }?.keyId
        if current == nil || (current != best.code && !best.laptop && commandKey == Self.keyId(best.code)) {
            Keychain.pairingCode = best.code
            pairedAutomatically = true
            UserDefaults.standard.set(true, forKey: "paired.auto")
        }
        guard let mine = Keychain.pairingCode else { return }
        for o in offers where o.code == mine {
            let ack: [String: String] = ["machine": o.machine, "device": "Katrina PA"]
            if let data = try? JSONSerialization.data(withJSONObject: ack) {
                try? data.write(to: dir.appendingPathComponent("ack-\(o.machine).json"), options: .atomic)
            }
        }
    }

    /// Does this phone hold the same pairing code as that Mac?
    func pairedWith(_ f: FleetSnapshot) -> Bool {
        guard let code = Keychain.pairingCode, let k = f.keyId, !k.isEmpty else { return false }
        return Self.keyId(code) == k
    }

    // MARK: orders for the Macs' ground crew

    enum OrderError: LocalizedError {
        case notPaired, noFolder, patientDetail, noMac, write(String)
        var errorDescription: String? {
            switch self {
            case .notPaired: return "Pair with your Macs first: Settings > Pair with your Macs."
            case .noFolder: return "Choose the PMPBrain folder in Settings first."
            case .patientDetail: return "That reads like patient detail, so it wasn't sent. Say \"a patient inquiry\" instead."
            case .noMac: return "No Mac's crew has checked in yet. Run ./install.sh on the iMac."
            case .write(let m): return "Couldn't send the order: \(m)"
            }
        }
    }

    /// The Mac that takes orders by default: the always-on one that checked in most recently.
    var commandMac: FleetSnapshot? {
        fleet.filter { !($0.laptop ?? false) }.max { ($0.generatedDate ?? .distantPast) < ($1.generatedDate ?? .distantPast) }
            ?? fleet.max { ($0.generatedDate ?? .distantPast) < ($1.generatedDate ?? .distantPast) }
    }

    var missions: [(machine: String, mission: FleetSnapshot.Mission)] {
        fleet.flatMap { f in f.missions.map { (f.machine, $0) } }
            .sorted { ($0.mission.created ?? "") > ($1.mission.created ?? "") }
    }

    var sessions: [(machine: String, session: FleetSnapshot.Session)] {
        fleet.flatMap { f in f.sessions.map { (f.machine, $0) } }
            .sorted { ($0.session.last ?? "") > ($1.session.last ?? "") }
    }

    func send(_ order: CrewOrder) throws {
        guard let code = Keychain.pairingCode else { throw OrderError.notPaired }
        if Privacy.looksLikePatientDetail(order.prompt) { throw OrderError.patientDetail }
        guard let folder = resolveFolder() else { throw OrderError.noFolder }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        let dir = folder.appendingPathComponent("orders")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(order.signed(with: code))
            try data.write(to: dir.appendingPathComponent("\(order.id).json"), options: .atomic)
        } catch {
            throw OrderError.write(error.localizedDescription)
        }
    }

    /// Plain-text digest Katrina reads before answering, so most questions need no further lookups.
    func digest(maxChars: Int = 9000) -> String {
        var lines: [String] = []
        for m in machines {
            let age = staleHours(m).map { "\($0)h ago" } ?? "unknown"
            lines.append("MAC \(m.machine) (\(m.isLaptop ? "laptop" : "always-on")), checked in \(age)")
        }
        if !alerts.isEmpty { lines.append("OPEN"); lines += alerts.map { "- \($0.level) [\($0.machine)] \($0.area): \($0.message)" } }
        lines.append("PROJECTS")
        lines += projects.map { p in "- \(p.project.name) [\(p.project.category ?? "")] on \(p.machine)\(p.project.isLoose ? " (loose work)" : "")" }
        if !map.isEmpty { lines.append("HOW THINGS CONNECT"); lines += map.map { $0 } }
        for f in fleet {
            lines.append("CREW \(f.machine): \(f.isOnline ? "online" : "offline"), \(f.sessions.filter { $0.state != "idle" }.count) live Claude session(s)")
            lines += f.sessions.filter { $0.state != "idle" }.prefix(8).map { "- session [\($0.state)] \($0.projectName): \($0.title)" }
            lines += f.missions.prefix(10).map { "- mission \($0.id.prefix(8)) [\($0.state)] \($0.projectName ?? ""): \(($0.prompt ?? "").prefix(80))" }
        }
        if !notes.isEmpty { lines.append("DECISIONS"); lines += notes.prefix(15).map { "- \($0.created.prefix(10)) [\($0.topic)] \($0.text)" } }
        return String(lines.joined(separator: "\n").prefix(maxChars))
    }
}
