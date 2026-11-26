import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

/// The NP desk login: a 6-digit PIN of its own (kept as a salted hash in the Keychain), with Face ID / Touch ID
/// as a shortcut. It is a lock on this device, not an account. It locks itself after the app has been away.
@MainActor
final class NPSession: ObservableObject {
    static let shared = NPSession()

    @Published private(set) var unlocked = false
    @Published private(set) var hasPin = Keychain.npPin != nil
    @Published var message = ""
    @Published var faceID: Bool = UserDefaults.standard.object(forKey: "np.faceid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(faceID, forKey: "np.faceid") }
    }
    /// Seconds the app can be in the background before the desk locks. 0 = every time.
    @Published var autoLockSeconds: Int = UserDefaults.standard.object(forKey: "np.autolock") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(autoLockSeconds, forKey: "np.autolock") }
    }

    private var backgroundedAt: Date?
    private let defaults = UserDefaults.standard

    var biometricsAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    // MARK: PIN

    /// Creates the login. Returns false (and sets `message`) if the two entries don't match or aren't 6 digits.
    @discardableResult
    func createPin(_ pin: String, again: String) -> Bool {
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else { message = "Use exactly 6 digits."; return false }
        guard pin == again else { message = "The two PINs don't match."; return false }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        Keychain.npPin = Self.hex(salt) + ":" + Self.digest(pin, salt: salt)
        hasPin = Keychain.npPin != nil
        defaults.set(0, forKey: "np.fails")
        defaults.removeObject(forKey: "np.until")
        message = ""
        unlocked = hasPin
        return hasPin
    }

    func unlock(pin: String) -> Bool {
        if let until = defaults.object(forKey: "np.until") as? Date, until > Date() {
            let s = Int(until.timeIntervalSinceNow.rounded(.up))
            message = "Too many tries. Wait \(s) seconds."
            return false
        }
        guard let stored = Keychain.npPin, let colon = stored.firstIndex(of: ":"),
              let salt = Self.data(fromHex: String(stored[..<colon])) else { message = "Set up the login again in Settings."; return false }
        if Self.digest(pin, salt: salt) == String(stored[stored.index(after: colon)...]) {
            defaults.set(0, forKey: "np.fails")
            defaults.removeObject(forKey: "np.until")
            message = ""
            unlocked = true
            return true
        }
        let fails = defaults.integer(forKey: "np.fails") + 1
        defaults.set(fails, forKey: "np.fails")
        if fails >= 5 {
            let wait = min(900.0, 30.0 * pow(2.0, Double(fails - 5)))
            defaults.set(Date().addingTimeInterval(wait), forKey: "np.until")
            message = "Too many tries. Wait \(Int(wait)) seconds."
        } else {
            message = "That PIN isn't right. \(5 - fails) tries left."
        }
        return false
    }

    func unlockWithBiometrics(auto: Bool = false) async {
        if auto && skipAutoFaceID { skipAutoFaceID = false; return }
        guard hasPin, faceID, biometricsAvailable else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use PIN"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Open the NP desk")
            if ok { message = ""; unlocked = true }
        } catch {
            // cancelled or failed: the PIN field is still there
        }
    }

    private var skipAutoFaceID = false

    /// `manual`: Paul tapped Lock, so don't pop Face ID straight back up.
    func lock(manual: Bool = false) { unlocked = false; message = ""; skipAutoFaceID = manual }

    /// Removes the login. Only reachable from Settings once the desk is open.
    func removeLogin() {
        guard unlocked else { return }
        Keychain.npPin = nil
        hasPin = false
        unlocked = false
    }

    // MARK: auto-lock

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            if let t = backgroundedAt, Date().timeIntervalSince(t) >= Double(autoLockSeconds) { lock() }
            backgroundedAt = nil
        default:
            break
        }
    }

    // MARK: hashing

    private static func digest(_ pin: String, salt: Data) -> String {
        var d = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        for _ in 0..<20_000 { d = Data(SHA256.hash(data: d + salt)) }
        return hex(d)
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private static func data(fromHex s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }
}
