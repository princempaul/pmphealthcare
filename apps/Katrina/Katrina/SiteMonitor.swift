import Foundation

/// Are the public websites up? A plain GET from the phone, timed. No tokens, no AI.
@MainActor
final class SiteMonitor: ObservableObject {
    /// One instance for the app, Siri and Shortcuts.
    static let shared = SiteMonitor()

    struct Site: Identifiable, Hashable {
        let url: String
        var status: Int = 0          // HTTP status; 0 = not checked or no answer
        var ms: Int = 0
        var checked: Date?
        var error: String?
        var id: String { url }
        var host: String { URL(string: url)?.host ?? url }
        var isUp: Bool { (200..<400).contains(status) }
        var isDown: Bool { checked != nil && !isUp }
    }

    static let defaultList = "https://pmphealthcare.ca, https://bluewatermetabolic.ca"
    @Published private(set) var sites: [Site] = []

    var urls: [String] {
        (UserDefaults.standard.string(forKey: "sites") ?? Self.defaultList)
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { String($0) }
            .filter { $0.hasPrefix("http") }
    }

    func refresh() async {
        let list = urls
        var out: [Site] = []
        await withTaskGroup(of: Site.self) { group in
            for u in list { group.addTask { await Self.check(u) } }
            for await s in group { out.append(s) }
        }
        sites = out.sorted { $0.url < $1.url }
    }

    private nonisolated static func check(_ url: String) async -> Site {
        var site = Site(url: url)
        guard let u = URL(string: url) else { site.error = "Not a web address"; return site }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        let start = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            site.status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            // the phone being offline says nothing about the site: leave it unchecked instead of "down"
            let mine: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]
            if let code = (error as? URLError)?.code, mine.contains(code) { return site }
            site.error = error.localizedDescription
        }
        site.ms = Int(Date().timeIntervalSince(start) * 1000)
        site.checked = Date()
        return site
    }
}
