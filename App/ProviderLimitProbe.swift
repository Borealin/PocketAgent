import AgentKit
import Foundation
import Synchronization

/// Local launch argument `-PocketAgentProviderLimitProbe` only (not
/// reachable from the UI): Chat Completions SSE fixtures served by a
/// `URLProtocol` registered only on this probe's own ephemeral session, read by
/// the app's pinned `AgentProviderClient` and mapped by the app's gates — the
/// main run (`CommitGatedModel` under `AgentRuntime`) and the summary
/// producer (`consume` with `StreamingSummary`). It proves the provider error
/// shapes and their mapping in the optimized iOS build; it is an injected
/// fixture, not a service actually rejecting a request. No network, keys or
/// stored settings are used. Report: `Documents/provider-limit-probe.json`
/// (booleans and counts only).
@MainActor
enum ProviderLimitProbe {
    private final class Fixture: URLProtocol, @unchecked Sendable {
        static let body = Mutex("")
        static let requests = Mutex(0)
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "limit-probe.pocketagent.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.withLock { $0 += 1 }
            let body = Self.body.withLock { $0 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                                  headerFields: ["Content-Type": "text/event-stream"])!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private struct Allow: AgentApprovalHandling {
        func authorize(_ request: AgentApprovalRequest, mode: AgentPermissionMode) async -> AgentApprovalDecision { .allow }
    }

    private static func client(_ body: String) -> AgentProviderClient {
        Fixture.body.withLock { $0 = body }
        Fixture.requests.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Fixture.self]
        return AgentProviderClient(provider: ModelProvider(name: "probe", apiFormat: .chatCompletions,
                                                           inferenceURL: "https://limit-probe.pocketagent.invalid/v1/x"),
                                   model: AIModel(id: "probe"), secret: "", session: URLSession(configuration: configuration))
    }

    private static let partial = #"data: {"choices":[{"index":0,"delta":{"content":"部分"}}]}"# + "\n\n"
    private static let echoed = "PKATEST_PROBE_SECRET_SENTINEL"
    private static let bareObject = partial
        + #"data: {"error":{"message":"This model's maximum context length is 8192 tokens. However, your messages resulted in 9100 tokens.","code":"context_length_exceeded","note":"\#(echoed)"}}"# + "\n\n"

    static func runAndReport() async {
        try? await Task.sleep(for: .seconds(2))
        var report: [String: Any] = ["fixture": "isolated URLProtocol on the probe's ephemeral session; pinned AgentKit client; injected SSE shapes",
                                     "wallClock": ISO8601DateFormatter().string(from: Date())]
        report["mainBareObject"] = await mainBareObject()
        report["summaryBareObject"] = await summaryBareObject()
        report["bareString"] = await bareString()
        report["negatives"] = await negatives()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("provider-limit-probe.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func mainBareObject() async -> [String: Any] {
        let base = client(bareObject)
        let barrier = TranscriptCommitBarrier()
        let prompt = AgentTranscriptMessage(role: .user, text: "PKATEST_PROBE")
        guard let committed = try? CommittedMessage(prompt) else { return ["error": "commit"] }
        barrier.open(epoch: 1, seed: [prompt.id: committed])
        let model = CommitGatedModel(base: base, barrier: barrier, epoch: 1, promptID: prompt.id, synthetic: { [] }, prepare: { $0 })
        let runtime = AgentRuntime(model: model, tools: [], approval: Allow(), configuration: AgentLoopConfiguration())
        var failure: String?
        var terminal: String?
        for await event in await runtime.start(AgentRunRequest(conversationID: UUID(), promptID: prompt.id, prompt: prompt.text,
                                                                permissionMode: .fullAccess, systemPrompt: "s", priorMessages: [])) {
            if case .failed(let reason) = event { failure = reason }
            if case .runFinished(let summary) = event { terminal = String(describing: summary.state) }
        }
        let requests = Fixture.requests.withLock { $0 }
        let expected = ProviderContextLimit(path: .main, kind: .contextWindow, status: nil, code: "context_length_exceeded",
                                            reportedLimit: 8192).errorDescription
        var raw: (any Error)?
        do { for try await _ in client(bareObject).stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { raw = error }
        let mapped = raw.flatMap { ProviderContextLimit.classify($0, path: .main) }
        return ["requests": requests, "terminal": terminal ?? NSNull(), "failureIsAdvice": failure != nil && failure == expected,
                "sentinelHidden": !(failure ?? "").contains(echoed) && !(failure ?? "").contains("However"),
                "rawTypeIsBridge": raw.map { String(reflecting: type(of: $0)) == StreamFailureBridge.typeName } ?? false,
                "mappedLimit": mapped?.reportedLimit ?? NSNull(), "mappedCode": mapped?.code ?? NSNull(),
                "gateRetries": mapped.map { model.shouldRetry(after: $0) } ?? NSNull(),
                "clientRetries": raw.map { base.shouldRetry(after: $0) } ?? NSNull()]
    }

    private static func summaryBareObject() async -> [String: Any] {
        let base = client(bareObject)
        let producer: StreamingSummary.Producer = { request, onEvent in
            do { try await base.consume(request, limits: .maintenance, onEvent: onEvent) }
            catch { throw ProviderContextLimit.classify(error, path: .summary) ?? error }
        }
        let request = SummaryRequest.make(messages: [AgentTranscriptMessage(role: .user, text: "第一轮")], previous: nil)
        do {
            _ = try await StreamingSummary.run(request, producer: producer, deadline: MaintenanceDeadline(turnRemaining: 600))
            return ["mapped": false, "completed": true]
        } catch {
            let limit = error as? ProviderContextLimit
            return ["mapped": limit?.path == .summary, "limit": limit?.reportedLimit ?? NSNull(),
                    "stopsTurn": SummaryMaintenance.stopsTurn(error), "requests": Fixture.requests.withLock { $0 }]
        }
    }

    private static func bareString() async -> [String: Any] {
        var failure: (any Error)?
        let source = client(#"data: {"error":"prompt is too long: 30000 tokens > 16000 maximum"}"# + "\n\n")
        do { for try await _ in source.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { failure = error }
        let mapped = failure.flatMap { ProviderContextLimit.classify($0, path: .main) }
        let text = mapped?.errorDescription ?? ""
        return ["mapped": mapped != nil, "limit": mapped?.reportedLimit ?? NSNull(),
                "adviceNamesLimit": text.contains("16000"), "providerTextHidden": !text.contains("prompt is too long")]
    }

    private static func negatives() async -> [String: Any] {
        var cutError: (any Error)?
        let cut = client(partial)
        do { try await cut.consume(AgentModelRequest(systemPrompt: "s", messages: [], tools: []), limits: .maintenance) { _ in } }
        catch { cutError = error }
        let gate = CommitGatedModel(base: cut, barrier: TranscriptCommitBarrier(), epoch: 1, promptID: UUID(), synthetic: { [] },
                                    prepare: { $0 })
        var serverError: (any Error)?
        let server = client(partial + #"data: {"error":{"message":"The server had an error while processing your request.","code":"server_error"}}"# + "\n\n")
        do { for try await _ in server.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} } catch { serverError = error }
        var text = "", normalError = false
        let normal = client(#"data: {"choices":[{"index":0,"delta":{"content":"好"}}],"error":null}"# + "\n\n"
            + #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n")
        do {
            for try await event in normal.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {
                if case .textDelta(let delta) = event { text += delta }
            }
        } catch { normalError = true }
        return ["cutStreamFails": cutError != nil,
                "cutStreamNotLimit": cutError.map { ProviderContextLimit.classify($0, path: .summary) == nil
                    && ProviderContextLimit.classify($0, path: .main) == nil } ?? false,
                "gateDefersCutRetry": cutError.map { gate.shouldRetry(after: $0) == cut.shouldRetry(after: $0) } ?? false,
                "serverErrorFails": serverError != nil,
                "serverErrorNotLimit": serverError.map { ProviderContextLimit.classify($0, path: .main) == nil } ?? false,
                "nullErrorCompletes": !normalError && text == "好"]
    }
}
