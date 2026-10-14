import AgentKit
import Foundation

/// The model service rejected a request as larger than its context (or
/// request size) limit. Ends the turn without a retry, a model change or a
/// replayed action. The text names only the HTTP status, a known error code
/// and a limit the service reported, never the response body, key or endpoint.
nonisolated struct ProviderContextLimit: LocalizedError, Equatable {
    enum Path: Equatable, Sendable {
        /// The turn's own model request.
        case main
        /// A context-maintenance summary request before it.
        case summary
    }

    var path: Path
    /// HTTP status, when the rejection was an HTTP error response.
    var status: Int?
    /// One of `codes`, when the service sent it.
    var code: String?
    /// The limit the service reported, in tokens, when it said so.
    var reportedLimit: Int?

    var errorDescription: String? {
        let request = path == .summary ? "整理较早对话的请求" : "本次请求"
        let limit = reportedLimit.map { "（服务报告上限约 \($0) token）" } ?? ""
        let source = [status.map { "HTTP \($0)" }, code].compactMap { $0 }.joined(separator: " ")
        return "模型服务拒绝了\(request)：超过它的上下文上限\(limit)\(source.isEmpty ? "" : "，\(source)")。"
            + "已停止本轮、不重试，也没有执行新的手机动作。可在「模型服务」中为这个模型设置更小的本机输入上限"
            + (reportedLimit == nil ? "" : "（低于服务报告的上限）") + "，然后发送新消息：新一轮会先按上限整理较早的对话。"
    }

    /// Provider codes that mean the request is too large for the model.
    static let codes: Set<String> = [
        "context_length_exceeded", "context_window_exceeded", "model_context_window_exceeded",
        "prompt_too_long", "request_too_large",
    ]
    /// Message phrases (lowercased) that mean the same; checked only on a
    /// 400/413/422 response or an in-stream failure, never on 401/403/429/5xx.
    static let phrases = [
        "maximum context length", "context length", "context_length", "context window", "context_window",
        "prompt is too long", "input is too long", "too many input tokens", "input token count",
        "maximum number of tokens allowed", "reduce the length of the messages", "range of input length",
        "request entity too large", "payload too large",
        "上下文长度", "上下文窗口", "超出上下文", "超过上下文", "输入长度超",
    ]
    /// Phrases of rate limits and quotas, which are never a context limit.
    static let excluded = ["rate limit", "rate_limit", "per min", "tokens per", "tpm", "rpm", "quota", "限流", "频率"]

    /// Maps a provider rejection to this error; anything else (network,
    /// authentication, rate limits, server errors, host gate errors) is nil.
    static func classify(_ error: any Error, path: Path) -> ProviderContextLimit? {
        if var limit = error as? ProviderContextLimit { limit.path = path; return limit }
        let status: Int?
        let code: String?
        let message: String
        if let provider = error as? AgentProviderError {
            guard case .http(let httpStatus, let body) = provider, [400, 413, 422].contains(httpStatus) else { return nil }
            status = httpStatus
            (code, message) = parse(body)
        } else if String(describing: type(of: error)) == "AgentProviderStreamFailure" {
            // AgentKit's in-stream provider failure (an internal type): its code and message.
            status = nil
            code = Mirror(reflecting: error).children.first { $0.label == "code" }.flatMap { $0.value as? String }
            message = error.localizedDescription
        } else {
            return nil
        }
        let text = message.lowercased()
        let normalized = code?.lowercased()
        if excluded.contains(where: text.contains) || normalized.map({ $0.contains("rate") || $0.contains("quota") }) == true {
            return nil
        }
        let known = normalized.flatMap { codes.contains($0) ? $0 : nil }
        guard known != nil || status == 413 || phrases.contains(where: text.contains) else { return nil }
        return ProviderContextLimit(path: path, status: status, code: known, reportedLimit: reportedLimit(in: message))
    }

    /// `error.code`/`error.type` and `error.message` (or a top-level message)
    /// of a JSON error body; otherwise its text.
    private static func parse(_ body: String) -> (code: String?, message: String) {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, body) }
        let error = root["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? (root["code"] as? String)
        let message = (error?["message"] as? String) ?? (root["message"] as? String) ?? (root["error"] as? String) ?? body
        return (code, message)
    }

    private static let limitPatterns = [
        #"maximum context length is (\d+)"#,
        #"\d+ tokens? > (\d+) maximum"#,
        #"maximum number of tokens allowed \((\d+)\)"#,
        #"range of input length should be \[\d+, *(\d+)\]"#,
    ]

    static func reportedLimit(in message: String) -> Int? {
        for pattern in limitPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message),
                  let value = Int(message[range]), (1...100_000_000).contains(value) else { continue }
            return value
        }
        return nil
    }
}
