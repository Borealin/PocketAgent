import AgentKit
import Foundation

/// The model service rejected a request as larger than its context window
/// or its request size limit. Ends the turn without a retry, a model change
/// or a replayed action. The text names only the HTTP status, a known error
/// code and a limit the service reported, never the response body, key or
/// endpoint.
nonisolated struct ProviderContextLimit: LocalizedError, Equatable {
    enum Path: Equatable, Sendable {
        /// The turn's own model request.
        case main
        /// A context-maintenance summary request before it.
        case summary
    }

    enum Kind: Equatable, Sendable {
        /// More tokens than the model's context window.
        case contextWindow
        /// More bytes than the service or a gateway accepts (HTTP 413 or a
        /// request-size code); often images or attachments.
        case requestSize
    }

    var path: Path
    var kind: Kind
    /// HTTP status, when the rejection was an HTTP error response.
    var status: Int?
    /// One of the known codes, when the service sent it.
    var code: String?
    /// The context limit the service reported, in tokens, when it said so.
    var reportedLimit: Int?

    var errorDescription: String? {
        let request = path == .summary ? "整理较早对话的请求" : "本次请求"
        let source = [status.map { "HTTP \($0)" }, code].compactMap { $0 }.joined(separator: " ")
        let what = switch kind {
        case .contextWindow: "超过它的上下文上限" + (reportedLimit.map { "（服务报告上限约 \($0) token）" } ?? "")
        case .requestSize: "请求体积超过服务或网关的上限"
        }
        let advice = switch kind {
        case .contextWindow:
            "可在「模型服务」中为这个模型设置更小的本机输入上限" + (reportedLimit == nil ? "" : "（低于服务报告的上限）")
                + "，然后发送新消息：新一轮会尝试先按上限整理较早的对话；没有可安全切分的位置或单段对话过大时仍可能超限，可缩短输入或开始新对话。"
        case .requestSize:
            "可减少图片或附件、缩短输入后发送新消息；本机输入上限只按 token 估计，不一定能避开体积限制。"
        }
        return "模型服务拒绝了\(request)：\(what)\(source.isEmpty ? "" : "，\(source)")。已停止本轮且不重试；拒绝后不再执行新的手机动作，此前已执行的动作和结果保留。"
            + advice
    }

    /// Provider codes of a context-window overflow.
    static let contextCodes: Set<String> = [
        "context_length_exceeded", "context_window_exceeded", "model_context_window_exceeded", "prompt_too_long",
    ]
    /// Provider codes of a request-size rejection.
    static let sizeCodes: Set<String> = ["request_too_large", "payload_too_large"]
    /// Phrases that by themselves state an overflow (lowercased).
    static let overflowPhrases = [
        "maximum context length is", "prompt is too long", "input is too long", "too many input tokens",
        "exceeds the maximum number of tokens", "reduce the length of the messages", "range of input length should be",
    ]
    /// A context noun counts only together with an overflow verb, so field or
    /// parameter errors ("Unknown field: context_length") are not overflows.
    static let contextNouns = [
        "context length", "context_length", "context window", "context_window", "input token count", "input length",
        "上下文长度", "上下文窗口", "上下文", "输入长度",
    ]
    static let overflowVerbs = ["exceed", "too long", "too large", "超过", "超出", "过长", "超限"]
    /// Phrases of rate limits and quotas, which are never a size limit.
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
        } else if let failure = StreamFailureBridge.read(error) {
            status = nil
            (code, message) = failure
        } else {
            return nil
        }
        let text = message.lowercased()
        let normalized = code?.lowercased()
        if excluded.contains(where: text.contains) || normalized.map({ $0.contains("rate") || $0.contains("quota") }) == true {
            return nil
        }
        if let normalized, contextCodes.contains(normalized) {
            return ProviderContextLimit(path: path, kind: .contextWindow, status: status, code: normalized,
                                        reportedLimit: reportedLimit(in: message))
        }
        if overflowPhrases.contains(where: text.contains)
            || contextNouns.contains(where: text.contains) && overflowVerbs.contains(where: text.contains) {
            return ProviderContextLimit(path: path, kind: .contextWindow, status: status, code: nil,
                                        reportedLimit: reportedLimit(in: message))
        }
        if status == 413 || normalized.map(sizeCodes.contains) == true {
            return ProviderContextLimit(path: path, kind: .requestSize, status: status,
                                        code: normalized.flatMap { sizeCodes.contains($0) ? $0 : nil }, reportedLimit: nil)
        }
        return nil
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

/// Reads AgentKit's in-stream provider failure (`response.failed`, an SSE
/// `error` event, a bare root `error` frame or a body `error` field), whose
/// type is internal to the SDK.
/// Depends on its private shape at the revision pinned in Package.swift:
/// `AgentKit.AgentProviderStreamFailure { code: String?; message: String }`,
/// with the message as `localizedDescription`. Any other type or shape is nil,
/// so a changed SDK falls back to the generic failure text.
nonisolated enum StreamFailureBridge {
    static let typeName = "AgentKit.AgentProviderStreamFailure"

    static func read(_ error: any Error) -> (code: String?, message: String)? {
        guard String(reflecting: type(of: error)) == typeName else { return nil }
        let mirror = Mirror(reflecting: error)
        guard let codeField = mirror.children.first(where: { $0.label == "code" }),
              mirror.children.contains(where: { $0.label == "message" }) else { return nil }
        let code: String?
        let field = Mirror(reflecting: codeField.value)
        if field.displayStyle == .optional {
            code = field.children.first.flatMap { $0.value as? String }
        } else {
            code = codeField.value as? String
        }
        return (code, error.localizedDescription)
    }
}
