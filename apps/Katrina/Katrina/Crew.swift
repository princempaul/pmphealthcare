import CryptoKit
import Foundation

/// An instruction for a Mac's ground crew (crew.py). The phone writes it to PMPBrain/orders/<id>.json;
/// the Mac it names runs it only if the HMAC matches the pairing code both sides hold.
struct CrewOrder: Encodable {
    enum Kind: String {
        case mission, followup, push, discard, stop, refresh
        case ghMerge = "gh_merge", ghRerun = "gh_rerun", ghOpenPR = "gh_openpr"
    }
    enum Mode: String { case look, work }

    let v = 1
    let id: String
    let created: String
    let machine: String
    let kind: String
    let project: String
    let mode: String
    let prompt: String
    let mission: String
    var sig = ""

    init(kind: Kind, machine: String, project: String = "", mode: Mode? = nil, prompt: String = "", mission: String = "") {
        id = UUID().uuidString.lowercased()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        created = f.string(from: Date())
        self.machine = machine
        self.kind = kind.rawValue
        self.project = project
        self.mode = mode?.rawValue ?? ""
        self.prompt = prompt
        self.mission = mission
    }

    /// Same field order as crew.py FIELDS: v|id|created|machine|kind|project|mode|prompt|mission
    func signed(with code: String) -> CrewOrder {
        let message = ["\(v)", id, created, machine, kind, project, mode, prompt, mission].joined(separator: "|")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(code.utf8)))
        var copy = self
        copy.sig = mac.map { String(format: "%02x", $0) }.joined()
        return copy
    }

    /// "abcd-efgh ijkl mnpq" -> "ABCDEFGHIJKLMNPQ", or nil if it isn't a pairing code.
    static func normalise(_ raw: String) -> String? {
        let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let c = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return c.count == 16 && c.allSatisfy { allowed.contains($0) } ? c : nil
    }
}
