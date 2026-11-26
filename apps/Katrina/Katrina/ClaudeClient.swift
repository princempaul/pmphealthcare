import Foundation

/// Minimal Claude Messages API client over HTTPS (Swift has no official Anthropic SDK).
/// Keeps every assistant turn's content blocks exactly as returned and sends them back unchanged.
struct ClaudeClient {
    enum Model: String, CaseIterable, Identifiable {
        case fable = "claude-fable-5-2", opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fable: return "Fable 5.2 (strongest, costs most)"
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

    enum Effort: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String {
            switch self {
            case .low: return "Low (fastest)"
            case .medium: return "Medium"
            case .high: return "High (thinks longest)"
            }
        }
    }

    let apiKey: String
    let model: Model
    var effort: Effort = .low

    /// One request. `messages` are raw JSON-ready dictionaries (user turns, assistant content arrays, tool results).
    /// `system` is the stable part (rules) and is cached with the tools; `context` (the live digest) changes
    /// every refresh, so it goes after the cache breakpoint and doesn't spoil the cache.
    /// With `onText`, the reply streams: text arrives through the closure as it is written, and the returned
    /// message is rebuilt block for block so it can be sent back unchanged in a tool loop.
    func send(system: String, context: String = "", messages: [[String: Any]], tools: [[String: Any]],
              onText: (@MainActor (String) -> Void)? = nil) async throws -> [String: Any] {
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
            "output_config": ["effort": effort.rawValue],
        ]
        if !tools.isEmpty { body["tools"] = tools }
        if onText != nil { body["stream"] = true }
        if model != .haiku {
            // if a safety classifier declines, the API retries on a suitable fallback model in the same call
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json: [String: Any]
        if let onText {
            json = try await stream(req, onText: onText)
        } else {
            let (data, resp) = try await URLSession.shared.data(for: req)
            json = try Self.decode(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        Usage.record(json["usage"] as? [String: Any])
        if json["stop_reason"] as? String == "refusal" {
            throw ClientError.refused((json["stop_details"] as? [String: Any])?["category"] as? String)
        }
        return json
    }

    private static func decode(_ data: Data, status: Int) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status != 200 { throw ClientError.http(status, "no details") }
            throw ClientError.decoding
        }
        guard status == 200 else {
            throw ClientError.http(status, ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown error")
        }
        return json
    }

    /// Server-sent events: every `data:` line is one JSON object whose `type` names the event.
    private func stream(_ req: URLRequest, onText: @MainActor (String) -> Void) async throws -> [String: Any] {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 200_000 { break } }
            return try Self.decode(data, status: status)
        }
        var message: [String: Any] = [:]
        var blocks: [Int: [String: Any]] = [:]
        var partial: [Int: String] = [:]
        var finished = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let ev = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            let i = ev["index"] as? Int ?? -1
            switch type {
            case "message_start":
                message = ev["message"] as? [String: Any] ?? [:]
            case "content_block_start":
                blocks[i] = ev["content_block"] as? [String: Any] ?? [:]
            case "content_block_delta":
                guard var block = blocks[i], let delta = ev["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let t = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + t
                    if !t.isEmpty { await onText(t) }
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    block["signature"] = delta["signature"] as? String ?? ""
                case "input_json_delta":
                    partial[i, default: ""] += delta["partial_json"] as? String ?? ""
                case "citations_delta":
                    if let c = delta["citation"] as? [String: Any] {
                        block["citations"] = (block["citations"] as? [[String: Any]] ?? []) + [c]
                    }
                default:
                    break
                }
                blocks[i] = block
            case "content_block_stop":
                if let raw = partial[i], !raw.isEmpty, var block = blocks[i] {
                    block["input"] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                    blocks[i] = block
                }
            case "message_delta":
                for (k, v) in ev["delta"] as? [String: Any] ?? [:] { message[k] = v }
                if let u = ev["usage"] as? [String: Any] {
                    message["usage"] = (message["usage"] as? [String: Any] ?? [:]).merging(u) { _, new in new }
                }
            case "message_stop":
                finished = true
            case "error":
                let e = ev["error"] as? [String: Any]
                let busy = (e?["type"] as? String) == "overloaded_error"
                throw ClientError.http(busy ? 529 : 500, e?["message"] as? String ?? "stream error")
            default:
                break
            }
        }
        guard finished || message["stop_reason"] is String else { throw ClientError.http(500, "the connection dropped mid-reply") }
        message["content"] = blocks.keys.sorted().compactMap { blocks[$0] }
        return message
    }
}
