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
private let echoed = #""note":"PKATEST_SECRET_SENTINEL https://pkatest.invalid/v1""#

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

/// Same name and shape as AgentKit's internal in-stream failure, in another module.
private struct AgentProviderStreamFailure: LocalizedError {
    let code: String?
    let message: String
    var errorDescription: String? { message }
}

@Suite(.serialized)
struct ProviderContextLimitTests {
    // MARK: Classification

    @Test func providerContextRejectionsAreRecognisedWithTheirReportedLimit() {
        let cases: [(AgentProviderError, ProviderContextLimit.Kind, String?, Int?)] = [
            (http(400, #"{"error":{"message":"This model's maximum context length is 128000 tokens. However, your messages resulted in 130500 tokens.","type":"invalid_request_error","param":"messages","code":"context_length_exceeded"},\#(echoed)}"#),
             .contextWindow, "context_length_exceeded", 128_000),
            (http(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 215000 tokens > 200000 maximum"}}"#),
             .contextWindow, nil, 200_000),
            (http(400, #"{"error":{"code":400,"message":"The input token count (1234567) exceeds the maximum number of tokens allowed (1048576).","status":"INVALID_ARGUMENT"}}"#),
             .contextWindow, nil, 1_048_576),
            (http(400, #"{"code":"InvalidParameter","message":"Range of input length should be [1, 30720]"}"#), .contextWindow, nil, 30_720),
            (http(422, #"{"error":{"message":"输入长度超过模型上下文长度"}}"#), .contextWindow, nil, nil),
            (http(413, #"{"error":{"code":"context_length_exceeded","message":"Input exceeds the context window"}}"#),
             .contextWindow, "context_length_exceeded", nil),
            // Request size, not the model's context: a gateway 413 or a size code.
            (http(413, "<html>Request Entity Too Large</html>"), .requestSize, nil, nil),
            (http(413, #"{"type":"error","error":{"type":"request_too_large","message":"Request exceeds the maximum allowed number of bytes."}}"#),
             .requestSize, "request_too_large", nil),
        ]
        for (error, kind, code, limit) in cases {
            let mapped = ProviderContextLimit.classify(error, path: .main)
            #expect(mapped?.kind == kind && mapped?.code == code && mapped?.reportedLimit == limit, "\(error)")
            let text = mapped?.errorDescription ?? ""
            #expect(text.contains(kind == .contextWindow ? "本机输入上限" : "减少图片"), "\(error)")
            #expect(text.contains("此前已执行的动作和结果保留") && text.contains("拒绝后不再执行新的手机动作"))
            #expect(!text.contains("PKATEST_SECRET_SENTINEL") && !text.contains("pkatest.invalid"))
            #expect(!text.contains("However") && !text.contains("prompt is too long") && !text.contains("Entity"))
        }
        // The advice is an attempt, with its boundary.
        let window = ProviderContextLimit.classify(cases[0].0, path: .main)?.errorDescription ?? ""
        #expect(window.contains("尝试") && window.contains("没有可安全切分的位置"))
    }

    @Test func fieldErrorsAuthenticationRateLimitsServerAndNetworkErrorsAreNotSizeLimits() {
        let others: [any Error] = [
            // A context noun without an overflow is a field or parameter error.
            http(400, #"{"error":{"message":"Unknown field: context_length"}}"#),
            http(400, #"{"error":{"message":"context window parameter must be positive"}}"#),
            http(400, #"{"error":{"message":"input token count must be integer"}}"#),
            http(422, #"{"detail":"context_window: field required"}"#),
            http(400, #"{"error":{"message":"Invalid value for 'context_length': expected an integer"}}"#),
            http(401, #"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#),
            http(403, #"{"error":{"message":"context length exceeded"}}"#),
            http(429, #"{"error":{"message":"Rate limit reached on tokens per min (TPM): Limit 30000, Requested 130000.","code":"rate_limit_exceeded"}}"#),
            http(400, #"{"error":{"message":"Request too large for gpt-4 on tokens per min (TPM): Limit 10000, Requested 12000.","code":"rate_limit_exceeded"}}"#),
            http(400, #"{"message":"Rate limit exceeded for context window tokens per minute; retry later"}"#),
            http(400, #"{"error":{"message":"上下文长度请求频率超限，请稍后再试"}}"#),
            http(400, #"{"error":{"message":"max_tokens is too large: 100000. This model supports at most 4096 completion tokens."}}"#),
            http(400, #"{"error":{"message":"Invalid image URL"}}"#),
            http(500, #"{"error":{"message":"maximum context length is 8192"}}"#),
            http(503, "context window exceeded upstream"),
            AgentProviderError.responseTooLarge, AgentProviderError.invalidResponse,
            URLError(.timedOut), URLError(.notConnectedToInternet), CancellationError(),
            StorageCommitError.timedOut, ContextBudgetError.overHardCeiling(estimated: 9_000, ceiling: 8_000, source: "x"),
            // Same type name and shape, but not AgentKit's type.
            AgentProviderStreamFailure(code: "context_length_exceeded", message: "maximum context length is 8192"),
        ]
        for error in others { #expect(ProviderContextLimit.classify(error, path: .main) == nil, "\(error)") }
    }

    @Test func theMappedErrorIsTerminalForBothPaths() {
        let limit = ProviderContextLimit(path: .summary, kind: .contextWindow, status: 400, code: nil, reportedLimit: nil)
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
        #expect(text == ProviderContextLimit(path: .main, kind: .contextWindow, status: 400, code: "context_length_exceeded",
                                             reportedLimit: 8192).errorDescription)
        #expect(!text.contains("PKATEST_SECRET_SENTINEL") && !text.contains("pkatest.invalid") && !text.contains("However"))
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
        #expect(thrown.map { String(reflecting: type(of: $0)) } == StreamFailureBridge.typeName)
        let mapped = try #require(thrown.flatMap { ProviderContextLimit.classify($0, path: .main) })
        #expect(mapped.code == "context_length_exceeded" && mapped.status == nil && mapped.kind == .contextWindow)
        // The other shapes AgentKit raises as an in-stream failure: a typed SSE
        // error event (Messages, Chat Completions gateway) and a 200 JSON error
        // body; a provider code that is not a context code, and a null code.
        let fixtures: [(ModelAPIFormat, LimitProtocol.Reply, String?, Int)] = [
            (.messages, .init(contentType: "text/event-stream", body: "event: error\n"
                + #"data: {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 30000 tokens > 16000 maximum"}}"# + "\n\n"),
             nil, 16_000),
            (.chatCompletions, .init(contentType: "text/event-stream", body:
                #"data: {"type":"error","error":{"code":"context_length_exceeded","message":"This model's maximum context length is 8192 tokens."}}"# + "\n\n"),
             "context_length_exceeded", 8192),
            (.chatCompletions, .init(body: #"{"error":{"message":"This model's maximum context length is 4096 tokens.","code":null}}"#),
             nil, 4096),
        ]
        for (format, reply, code, limit) in fixtures {
            let source = client(format, reply)
            var failure: (any Error)?
            do { for try await _ in source.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { failure = error }
            #expect(failure.map { String(reflecting: type(of: $0)) } == StreamFailureBridge.typeName, "\(format)")
            let found = failure.flatMap { ProviderContextLimit.classify($0, path: .main) }
            #expect(found?.code == code && found?.reportedLimit == limit && found?.kind == .contextWindow, "\(format)")
        }
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

    // MARK: Bare error objects (AgentKit e1c81c9)

    private static let partial = #"data: {"choices":[{"index":0,"delta":{"content":"部分"}}]}"# + "\n\n"
    private static let bareObject = partial
        + #"data: {"error":{"message":"This model's maximum context length is 8192 tokens. However, your messages resulted in 9100 tokens.","code":"context_length_exceeded"},\#(echoed)}"# + "\n\n"

    /// A Chat Completions gateway reports the overflow after the stream has
    /// started as a frame whose root `error` is an object, with no event name
    /// or type. Through the pinned client and the main-model gate it stops the
    /// run with the advice, after one request, without the provider's text.
    @Test func aBareErrorObjectAfterTheStreamStartedStopsTheMainRunWithTheAdvice() async throws {
        let base = client(.chatCompletions, .init(contentType: "text/event-stream", body: Self.bareObject))
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
        let expected = ProviderContextLimit(path: .main, kind: .contextWindow, status: nil, code: "context_length_exceeded",
                                            reportedLimit: 8192)
        let text = try #require(failure)
        #expect(text == expected.errorDescription)
        #expect(!text.contains("PKATEST_SECRET_SENTINEL") && !text.contains("pkatest.invalid") && !text.contains("However"))
        // Neither the gate nor the client retries it.
        var raw: (any Error)?
        do { for try await _ in base.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { raw = error }
        let thrown = try #require(raw)
        let mapped = try #require(ProviderContextLimit.classify(thrown, path: .main))
        #expect(!model.shouldRetry(after: mapped) && !base.shouldRetry(after: thrown))
    }

    /// The same frame on the bounded maintenance path stops the summary.
    @Test func aBareErrorObjectStopsASummaryRequest() async throws {
        let base = client(.chatCompletions, .init(contentType: "text/event-stream", body: Self.bareObject))
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
            #expect(limit.path == .summary && limit.reportedLimit == 8192 && limit.code == "context_length_exceeded")
            #expect(SummaryMaintenance.stopsTurn(error))
        }
        #expect(LimitProtocol.requests.withLock { $0 } == 1)
    }

    /// A bare string error keeps its reported limit; the text stays out of
    /// the advice.
    @Test func aBareStringErrorKeepsItsLimitButNotItsText() async throws {
        let base = client(.chatCompletions, .init(contentType: "text/event-stream", body:
            #"data: {"error":"prompt is too long: 30000 tokens > 16000 maximum"}"# + "\n\n"))
        var failure: (any Error)?
        do { for try await _ in base.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { failure = error }
        #expect(failure.map { String(reflecting: type(of: $0)) } == StreamFailureBridge.typeName)
        let mapped = try #require(failure.flatMap { ProviderContextLimit.classify($0, path: .main) })
        #expect(mapped.kind == .contextWindow && mapped.reportedLimit == 16_000 && mapped.code == nil)
        let text = try #require(mapped.errorDescription)
        #expect(text.contains("16000") && !text.contains("prompt is too long"))
    }

    /// Nothing is inferred from an ending: a stream cut off without an error
    /// frame fails the bounded path (a terminal is required) without becoming
    /// a limit, and the main gate leaves its retry to the client; a bare error
    /// that is not an overflow, and a null error beside normal content (which
    /// completes), are not context limits either.
    @Test func noLimitIsInferredWithoutAnOverflowError() async throws {
        let cut = client(.chatCompletions, .init(contentType: "text/event-stream", body: Self.partial))
        var ended: (any Error)?
        do { try await cut.consume(AgentModelRequest(systemPrompt: "s", messages: [], tools: []), limits: .maintenance) { _ in } }
        catch { ended = error }
        let error = try #require(ended)
        #expect(ProviderContextLimit.classify(error, path: .summary) == nil && ProviderContextLimit.classify(error, path: .main) == nil)
        let gate = CommitGatedModel(base: cut, barrier: TranscriptCommitBarrier(), epoch: 1, promptID: UUID(), synthetic: { [] },
                                    prepare: { $0 })
        #expect(gate.shouldRetry(after: error) == cut.shouldRetry(after: error))
        let other = client(.chatCompletions, .init(contentType: "text/event-stream", body: Self.partial
            + #"data: {"error":{"message":"The server had an error while processing your request.","code":"server_error"}}"# + "\n\n"))
        var failure: (any Error)?
        do { for try await _ in other.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { failure = error }
        #expect(failure != nil && failure.flatMap { ProviderContextLimit.classify($0, path: .main) } == nil)
        let normal = client(.chatCompletions, .init(contentType: "text/event-stream", body:
            #"data: {"choices":[{"index":0,"delta":{"content":"好"}}],"error":null}"# + "\n\n"
            + #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"))
        var text = ""
        for try await event in normal.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {
            if case .textDelta(let delta) = event { text += delta }
        }
        #expect(text == "好")
    }
}
