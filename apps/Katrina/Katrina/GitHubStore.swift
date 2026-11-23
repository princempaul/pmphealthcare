import Foundation

/// Live state of Paul's GitHub repos: open pull requests and the latest Actions runs.
/// Repos come from the brain (every project's GitHub remote), so there's nothing to configure.
/// Uses a fine-grained token from the Keychain. Writes happen only from a button Paul taps.
@MainActor
final class GitHubStore: ObservableObject {
    struct Repo: Identifiable, Hashable {
        let slug: String                  // owner/name
        var defaultBranch: String = "main"
        var pulls: [Pull] = []
        var runs: [Run] = []
        var error: String?
        var id: String { slug }
        var name: String { String(slug.split(separator: "/").last ?? "") }
        /// Latest run of each workflow.
        var latestRuns: [Run] {
            var seen = Set<String>()
            return runs.filter { seen.insert($0.name).inserted }
        }
        var failing: [Run] { latestRuns.filter { $0.conclusion == "failure" || $0.conclusion == "timed_out" } }
        var running: [Run] { runs.filter { $0.status == "in_progress" || $0.status == "queued" } }
    }

    struct Pull: Identifiable, Hashable {
        let number: Int
        let title: String
        let author: String
        let draft: Bool
        let head: String
        let headSha: String
        let url: String
        let updated: String
        var checks: String = "unknown"    // passing | failing | pending | none | unknown
        var id: Int { number }
    }

    struct Run: Identifiable, Hashable {
        let id: Int
        let name: String
        let status: String
        let conclusion: String?
        let branch: String
        let url: String
        let created: String
    }

    @Published private(set) var repos: [Repo] = []
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var error: String?
    @Published private(set) var busy = false

    /// When the phone has no token, the always-on Mac watches GitHub with its own git login and acts on orders.
    @Published private(set) var viaMac: String?
    @Published private(set) var lastResult: FleetSnapshot.GitHubView.ActionResult?

    var hasToken: Bool { Keychain.githubToken != nil }
    var connected: Bool { hasToken || viaMac != nil }

    /// Use what a Mac's crew reports. Called on every refresh when the phone has no token of its own.
    func adopt(_ view: FleetSnapshot.GitHubView?, from machine: String?) {
        guard !hasToken else { viaMac = nil; return }
        guard let view, view.ok == true, let machine else {
            viaMac = nil; repos = []; error = view?.error; return
        }
        viaMac = machine
        error = nil
        lastResult = view.results?.first
        repos = (view.repos ?? []).map { r in
            var repo = Repo(slug: r.slug)
            repo.defaultBranch = r.defaultBranch ?? "main"
            repo.error = (r.error ?? "").isEmpty ? nil : r.error
            repo.pulls = (r.pulls ?? []).map {
                Pull(number: $0.number, title: $0.title ?? "", author: $0.author ?? "", draft: $0.draft ?? false,
                     head: $0.head ?? "", headSha: $0.headSha ?? "", url: $0.url ?? "", updated: $0.updated ?? "",
                     checks: $0.checks ?? "unknown")
            }
            repo.runs = (r.runs ?? []).map {
                Run(id: $0.id, name: $0.name ?? "", status: $0.status ?? "", conclusion: $0.conclusion,
                    branch: $0.branch ?? "", url: $0.url ?? "", created: $0.created ?? "")
            }
            return repo
        }
        lastLoaded = Date()
    }
    var openPulls: [(repo: Repo, pull: Pull)] { repos.flatMap { r in r.pulls.map { (r, $0) } } }
    var failingRuns: [(repo: Repo, run: Run)] { repos.flatMap { r in r.failing.map { (r, $0) } } }
    var runningRuns: [(repo: Repo, run: Run)] { repos.flatMap { r in r.running.map { (r, $0) } } }

    static func slug(fromRemote remote: String?) -> String? {
        guard let remote, let range = remote.range(of: #"github\.com[:/]([^/\s]+/[^/\s]+?)(\.git)?$"#, options: .regularExpression) else { return nil }
        var s = String(remote[range]).replacingOccurrences(of: "github.com:", with: "").replacingOccurrences(of: "github.com/", with: "")
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    func refresh(slugs: [String]) async {
        guard let token = Keychain.githubToken else { return }     // the Mac's view is adopted instead
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var out: [Repo] = []
        await withTaskGroup(of: Repo.self) { group in
            for slug in Set(slugs).sorted() {
                group.addTask { await Self.load(slug: slug, token: token) }
            }
            for await r in group { out.append(r) }
        }
        repos = out.sorted { $0.slug < $1.slug }
        let failures = out.compactMap(\.error)
        error = failures.count == out.count && !out.isEmpty ? failures.first : nil
        lastLoaded = Date()
    }

    private nonisolated static func load(slug: String, token: String) async -> Repo {
        var repo = Repo(slug: slug)
        do {
            if let info = try await get("/repos/\(slug)", token) as? [String: Any] {
                repo.defaultBranch = info["default_branch"] as? String ?? "main"
            }
            let pulls = try await get("/repos/\(slug)/pulls?state=open&per_page=20", token) as? [[String: Any]] ?? []
            for p in pulls.prefix(10) {
                let head = p["head"] as? [String: Any] ?? [:]
                var pull = Pull(number: p["number"] as? Int ?? 0, title: p["title"] as? String ?? "",
                                author: (p["user"] as? [String: Any])?["login"] as? String ?? "",
                                draft: p["draft"] as? Bool ?? false, head: head["ref"] as? String ?? "",
                                headSha: head["sha"] as? String ?? "", url: p["html_url"] as? String ?? "",
                                updated: p["updated_at"] as? String ?? "")
                if let checks = try? await get("/repos/\(slug)/commits/\(pull.headSha)/check-runs?per_page=50", token) as? [String: Any],
                   let list = checks["check_runs"] as? [[String: Any]] {
                    let conclusions = list.compactMap { $0["conclusion"] as? String }
                    if list.isEmpty { pull.checks = "none" }
                    else if conclusions.contains(where: { ["failure", "timed_out", "cancelled", "action_required"].contains($0) }) { pull.checks = "failing" }
                    else if list.contains(where: { ($0["status"] as? String) != "completed" }) { pull.checks = "pending" }
                    else { pull.checks = "passing" }
                }
                repo.pulls.append(pull)
            }
            if let runs = try await get("/repos/\(slug)/actions/runs?per_page=15", token) as? [String: Any] {
                repo.runs = (runs["workflow_runs"] as? [[String: Any]] ?? []).map {
                    Run(id: $0["id"] as? Int ?? 0, name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "",
                        conclusion: $0["conclusion"] as? String, branch: $0["head_branch"] as? String ?? "",
                        url: $0["html_url"] as? String ?? "", created: $0["created_at"] as? String ?? "")
                }
            }
        } catch {
            repo.error = error.localizedDescription
        }
        return repo
    }

    // MARK: actions (each one is a button Paul taps; nothing here runs on its own)

    func merge(_ pull: Pull, in repo: Repo) async throws {
        _ = try await Self.call("PUT", "/repos/\(repo.slug)/pulls/\(pull.number)/merge",
                                ["merge_method": "merge", "sha": pull.headSha])
    }

    func rerun(_ run: Run, in repo: Repo) async throws {
        _ = try await Self.call("POST", "/repos/\(repo.slug)/actions/runs/\(run.id)/rerun-failed-jobs", nil)
    }

    /// Opens a pull request for a branch a mission pushed. Returns its web URL.
    func openPull(slug: String, branch: String, title: String, body: String) async throws -> String {
        let base = repos.first { $0.slug == slug }?.defaultBranch ?? "main"
        let r = try await Self.call("POST", "/repos/\(slug)/pulls",
                                    ["title": title, "head": branch, "base": base, "body": body, "draft": true])
        return (r as? [String: Any])?["html_url"] as? String ?? ""
    }

    // MARK: HTTP

    enum GitHubError: LocalizedError {
        case noToken, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noToken: return "Add a GitHub token in Settings."
            case .http(401, _): return "GitHub rejected the token. Check it in Settings."
            case .http(let c, let m): return "GitHub said \(c): \(m)"
            }
        }
    }

    private nonisolated static func get(_ path: String, _ token: String) async throws -> Any {
        try await request("GET", path, nil, token)
    }

    private static func call(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> Any {
        guard let token = Keychain.githubToken else { throw GitHubError.noToken }
        return try await request(method, path, body, token)
    }

    private nonisolated static func request(_ method: String, _ path: String, _ body: [String: Any]?, _ token: String) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var json: Any = [String: Any]()
        if !data.isEmpty, let parsed = try? JSONSerialization.jsonObject(with: data) { json = parsed }
        guard (200..<300).contains(code) else {
            throw GitHubError.http(code, (json as? [String: Any])?["message"] as? String ?? "error")
        }
        return json
    }
}
