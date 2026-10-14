import AgentKit
import Foundation
import Synchronization
import Testing
@testable import PocketAgentCore

/// Serves one scripted response per request and counts requests.
private final class LimitProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var contentType = "application/json"; var body = "" }
    static let reply = Mutex(Reply())
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "limit.pocketagent.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.reply.withLock { $0 }
        Self.requests.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A secret-looking value and an endpoint that must never reach the message.
private let echoed = #""note":"sk-PKATEST-0000 https://internal.example/v1""#

private func client(_ format: ModelAPIFormat, _ reply: LimitProtocol.Reply) -> AgentProviderClient {
    LimitProtocol.reply.withLock { $0 = reply }
    LimitProtocol.requests.withLock { $0 = 0 }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LimitProtocol.self]
    return AgentProviderClient(
        provider: ModelProvider(name: "t", apiFormat: format, inferenceURL: "https://limit.pocketagent.test/v1/x"),
        model: AIModel(id: "m"), secret: "", session: URLSession(configuration: configuration))
}

private func http(_ status: Int, _ body: String) -> AgentProviderError { .http(status, body) }

@Suite(.serialized)
struct ProviderContextLimitTests {
    // MARK: Classification

    @Test func providerContextRejectionsAreRecognisedWithTheirReportedLimit() {
        let cases: [(AgentProviderError, String?, Int?)] = [
            (http(400, #"{"error":{"message":"This model's maximum context length is 128000 tokens. However, your messages resulted in 130500 tokens.","type":"invalid_request_error","param":"messages","code":"context_length_exceeded"},\#(echoed)}"#),
             "context_length_exceeded", 128_000),
            (http(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 215000 tokens > 200000 maximum"}}"#),
             nil, 200_000),
            (http(400, #"{"error":{"code":400,"message":"The input token count (1234567) exceeds the maximum number of tokens allowed (1048576).","status":"INVALID_ARGUMENT"}}"#),
             nil, 1_048_576),
            (http(400, #"{"code":"InvalidParameter","message":"Range of input length should be [1, 30720]"}"#), nil, 30_720),
            (http(413, "<html>Request Entity Too Large</html>"), nil, nil),
            (http(422, #"{"error":{"message":"输入长度超过模型上下文长度"}}"#), nil, nil),
        ]
        for (error, code, limit) in cases {
            let mapped = ProviderContextLimit.classify(error, path: .main)
            #expect(mapped?.code == code && mapped?.reportedLimit == limit, "\(error)")
            let text = mapped?.errorDescription ?? ""
            #expect(text.contains("本机输入上限") && !text.contains("sk-PKATEST") && !text.contains("internal.example"))
            #expect(!text.contains("However") && !text.contains("prompt is too long"))
        }
    }

    @Test func authenticationRateLimitsServerAndNetworkErrorsAreNotContextLimits() {
        let others: [any Error] = [
            http(401, #"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#),
            http(403, #"{"error":{"message":"context length exceeded"}}"#),
            http(429, #"{"error":{"message":"Rate limit reached on tokens per min (TPM): Limit 30000, Requested 130000.","code":"rate_limit_exceeded"}}"#),
            http(400, #"{"error":{"message":"Request too large for gpt-4 on tokens per min (TPM): Limit 10000, Requested 12000.","code":"rate_limit_exceeded"}}"#),
            http(400, #"{"message":"Rate limit exceeded for context window tokens per minute; retry later"}"#),
            http(400, #"{"error":{"message":"上下文长度请求频率超限，请稍后再试"}}"#),
            http(400, #"{"error":{"message":"max_tokens is too large: 100000. This model supports at most 4096 completion tokens."}}"#),
            http(400, #"{"error":{"message":"Invalid image URL"}}"#),
            http(500, #"{"error":{"message":"maximum context length is 8192"}}"#),
            http(503, "context window service unavailable"),
            AgentProviderError.responseTooLarge, AgentProviderError.invalidResponse,
            URLError(.timedOut), URLError(.notConnectedToInternet), CancellationError(),
            StorageCommitError.timedOut, ContextBudgetError.overHardCeiling(estimated: 9_000, ceiling: 8_000, source: "x"),
        ]
        for error in others { #expect(ProviderContextLimit.classify(error, path: .main) == nil, "\(error)") }
    }

    @Test func theMappedErrorIsTerminalForBothPaths() {
        let limit = ProviderContextLimit(path: .summary, status: 400, code: nil, reportedLimit: nil)
        #expect(TurnGateErrors.isTerminal(limit) && SummaryMaintenance.stopsTurn(limit))
        let gated = CommitGatedModel(base: client(.chatCompletions, .init()), barrier: TranscriptCommitBarrier(), epoch: 1,
                                     promptID: UUID(), synthetic: { [] }, prepare: { $0 })
        #expect(!gated.shouldRetry(after: limit))
        // A rate limit keeps the provider's own retry decision.
        #expect(gated.shouldRetry(after: http(429, "{}")))
        #expect(limit.errorDescription?.contains("整理较早对话的请求") == true)
    }

    // MARK: Through the pinned provider client

    /// The real AgentProviderClient answers HTTP 400 context_length_exceeded;
    /// the main-model gate maps it, AgentRuntime sends nothing more and the
    /// run's failure is the mapped advice.
    @Test func aMainRequestRejectionStopsTheRunWithTheAdvice() async throws {
        let base = client(.chatCompletions, .init(status: 400, body:
            #"{"error":{"message":"This model's maximum context length is 8192 tokens. However, you requested 9000 tokens.","code":"context_length_exceeded"},\#(echoed)}"#))
        let barrier = TranscriptCommitBarrier()
        let prompt = AgentTranscriptMessage(role: .user, text: "看一下屏幕")
        barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        let model = CommitGatedModel(base: base, barrier: barrier, epoch: 1, promptID: prompt.id, synthetic: { [] },
                                     prepare: { $0 })
        let runtime = AgentRuntime(model: model, tools: [], approval: AllowEverything(), configuration: AgentLoopConfiguration())
        var failure: String?
        var terminal: AgentRunState?
        for await event in await runtime.start(AgentRunRequest(conversationID: UUID(), promptID: prompt.id, prompt: prompt.text,
                                                                permissionMode: .fullAccess, systemPrompt: "s", priorMessages: [])) {
            if case .failed(let reason) = event { failure = reason }
            if case .runFinished(let summary) = event { terminal = summary.state }
        }
        #expect(LimitProtocol.requests.withLock { $0 } == 1 && terminal == .failed)
        let text = try #require(failure)
        #expect(text == ProviderContextLimit(path: .main, status: 400, code: "context_length_exceeded", reportedLimit: 8192).errorDescription)
        #expect(!text.contains("sk-PKATEST") && !text.contains("internal.example") && !text.contains("However"))
    }

    /// The same rejection sent inside a Responses stream (an in-stream
    /// failure event rather than an HTTP status).
    @Test func anInStreamFailureEventIsRecognised() async throws {
        let base = client(.responses, .init(contentType: "text/event-stream", body:
            #"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model."}}}"# + "\n\n"))
        var thrown: (any Error)?
        do {
            for try await _ in base.stream(AgentModelRequest(systemPrompt: "s", messages: [AgentTranscriptMessage(role: .user, text: "x")],
                                                             tools: [])) {}
        } catch { thrown = error }
        let mapped = try #require(thrown.flatMap { ProviderContextLimit.classify($0, path: .main) })
        #expect(mapped.code == "context_length_exceeded" && mapped.status == nil)
        // An in-stream rate limit stays a rate limit.
        let limited = client(.responses, .init(contentType: "text/event-stream", body:
            #"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"Rate limit reached"}}}"# + "\n\n"))
        var other: (any Error)?
        do { for try await _ in limited.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { other = error }
        #expect(other != nil && other.flatMap { ProviderContextLimit.classify($0, path: .main) } == nil)
    }

    /// A summary request the service rejects stops maintenance (and so the
    /// turn) with the summary wording; no main request follows.
    @Test func aSummaryRequestRejectionStopsMaintenance() async throws {
        let base = client(.chatCompletions, .init(status: 400, body:
            #"{"error":{"message":"prompt is too long: 30000 tokens > 16000 maximum"}}"#))
        let producer: StreamingSummary.Producer = { request, onEvent in
            do { try await base.consume(request, limits: .maintenance, onEvent: onEvent) }
            catch { throw ProviderContextLimit.classify(error, path: .summary) ?? error }
        }
        let request = SummaryRequest.make(messages: [AgentTranscriptMessage(role: .user, text: "第一轮")], previous: nil)
        do {
            _ = try await StreamingSummary.run(request, producer: producer, deadline: MaintenanceDeadline(turnRemaining: 600))
            Issue.record("expected a rejection")
        } catch {
            let limit = try #require(error as? ProviderContextLimit)
            #expect(limit.path == .summary && limit.reportedLimit == 16_000 && SummaryMaintenance.stopsTurn(error))
        }
        #expect(LimitProtocol.requests.withLock { $0 } == 1)
    }
}
