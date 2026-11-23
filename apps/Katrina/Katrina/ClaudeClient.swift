import Foundation

/// Minimal Claude Messages API client over HTTPS (Swift has no official Anthropic SDK).
/// Keeps every assistant turn's content blocks exactly as returned and sends them back unchanged.
struct ClaudeClient {
    enum Model: String, CaseIterable, Identifiable {
        case opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .opus: return "Opus 5.5 (best answers)"
            case .sonnet: return "Sonnet 5.5 (balanced)"
            case .haiku: return "Haiku 5.5 (fastest, cheapest)"
            }
        }
    }

    enum ClientError: LocalizedError {
        case noKey, http(Int, String), refused(String?), decoding
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add your Anthropic API key in Settings to ask Katrina."
            case .http(let code, let msg):
                switch code {
                case 401: return "The API key was rejected. Check it in Settings."
                case 429: return "Too many requests right now. Wait a minute and ask again."
                case 529, 500...599: return "Claude is busy or unavailable. Try again shortly."
                default: return "Request failed (\(code)): \(msg)"
                }
            case .refused(let cat): return "Claude declined to answer that\(cat.map { " (\($0))" } ?? "")."
            case .decoding: return "Couldn't read Claude's reply."
            }
        }
    }

    let apiKey: String
    let model: Model

    /// One request. `messages` are raw JSON-ready dictionaries (user turns, assistant content arrays, tool results).
    /// `system` is the stable part (rules) and is cached with the tools; `context` (the live digest) changes
    /// every refresh, so it goes after the cache breakpoint and doesn't spoil the cache.
    func send(system: String, context: String = "", messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            // the stable system prompt is cached, so repeat questions cost a fraction
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]] as [String: Any]]
                + (context.isEmpty ? [] as [[String: Any]] : [["type": "text", "text": context] as [String: Any]]),
            "messages": messages,
            "tools": tools,
            "output_config": ["effort": "low"],
        ]
        if model != .haiku {
            // if a safety classifier declines, the API retries on a suitable fallback model in the same call
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.decoding }
        guard code == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            throw ClientError.http(code, msg)
        }
        if json["stop_reason"] as? String == "refusal" {
            throw ClientError.refused((json["stop_details"] as? [String: Any])?["category"] as? String)
        }
        return json
    }
}
