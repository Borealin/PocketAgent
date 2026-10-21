import AgentKit
import Foundation
import Synchronization
import Testing
@testable import PocketAgentCore

/// Streams scripted SSE chunks with delays; records cancellation.
private final class TimedSSEProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var chunks: [String] = []
        var delay: Double = 0
        var finish = true
        /// Key of this load's progress in `loads`.
        var label = ""
    }
    enum Load: Sendable { case started, delivered, interrupted }
    static let script = Mutex(Script())
    static let stopped = Mutex(0)
    /// Started → delivered (every chunk handed over) or interrupted (stopped before that).
    static let loads = Mutex<[String: Load]>([:])
    private let cancelled = Mutex(false)
    private let label = Mutex("")

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "consume.pocketagent.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.script.withLock { $0 }
        label.withLock { $0 = script.label }
        Self.loads.withLock { $0[script.label] = .started }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let client = client
        Thread.detachNewThread { [self] in
            for chunk in script.chunks {
                if cancelled.withLock({ $0 }) { return }
                if script.delay > 0 { Thread.sleep(forTimeInterval: script.delay) }
                if cancelled.withLock({ $0 }) { return }
                client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            }
            Self.loads.withLock { if $0[script.label] == .started { $0[script.label] = .delivered } }
            if script.finish, !cancelled.withLock({ $0 }) { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        cancelled.withLock { $0 = true }
        Self.stopped.withLock { $0 += 1 }
        let key = label.withLock { $0 }
        Self.loads.withLock { if $0[key] == .started { $0[key] = .interrupted } }
    }
}

/// Bounded wait (fixture bound 5 s) for what the protocol's threads report.
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    let end = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

private func provider(_ script: TimedSSEProtocol.Script) -> AgentProviderClient {
    TimedSSEProtocol.script.withLock { $0 = script }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TimedSSEProtocol.self]
    configuration.timeoutIntervalForRequest = 30
    return AgentProviderClient(
        provider: ModelProvider(name: "t", apiFormat: .chatCompletions, inferenceURL: "https://consume.pocketagent.test/v1/chat"),
        model: AIModel(id: "m"), secret: "", session: URLSession(configuration: configuration))
}

private func delta(_ text: String) -> String {
    #"data: {"choices":[{"index":0,"delta":{"content":"\#(text)"}}]}"# + "\n\n"
}
private let stop = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"

/// The production producer: AgentKit's bounded consume under maintenance limits.
private func producer(_ client: AgentProviderClient) -> StreamingSummary.Producer {
    { request, onEvent in try await client.consume(request, limits: .maintenance, onEvent: onEvent) }
}

@Suite(.serialized)
struct ConsumeIntegrationTests {
    private let request = SummaryRequest.make(messages: [AgentTranscriptMessage(role: .user, text: "第一轮")], previous: nil)

    @Test func realConsumeFeedsTheCollectorAndRequiresATerminal() async throws {
        let text = try await StreamingSummary.run(request, producer: producer(provider(.init(chunks: [delta("## Goal"), delta("\\n完成"), stop]))),
                                                  deadline: MaintenanceDeadline(turnRemaining: 600))
        #expect(text == "## Goal\n完成")
        await #expect(throws: (any Error).self) {
            try await StreamingSummary.run(request, producer: producer(provider(.init(chunks: [delta("x")]))),
                                           deadline: MaintenanceDeadline(turnRemaining: 600))
        }
    }

    @Test func oneDeadlineIsSharedAcrossFolds() async throws {
        // A later fold gets only what is left of the turn's one budget, never a
        // fresh one: `now:` started the production 150 s budget 149 s ago, as
        // earlier folds would have. The fold streams 30 s of real chunks (a
        // fixture bound a reset would let finish) until that end stops it.
        let overrun = SummaryPreparationError(detail: "上下文整理超过 150 秒，本轮不使用新的摘要")
        let shared = MaintenanceDeadline(turnRemaining: 600, now: ProcessInfo.processInfo.systemUptime - 149)
        let slow = { (label: String) in
            TimedSSEProtocol.Script(chunks: (0..<300).map { delta("片段\($0)") } + [stop], delay: 0.1, label: label)
        }
        let streaming = UUID().uuidString, next = UUID().uuidString
        await #expect(throws: overrun) {
            try await StreamingSummary.run(request, producer: producer(provider(slow(streaming))), deadline: shared, idleSeconds: 60)
        }
        #expect(shared.remaining <= 0)
        // The stop reached the real transfer: a load that started never delivered its whole stream.
        #expect(try await eventually { [nil, .interrupted].contains(TimedSSEProtocol.loads.withLock { $0[streaming] }) })
        // Spent: the next fold of the same budget is refused before sending a request.
        await #expect(throws: overrun) {
            try await StreamingSummary.run(request, producer: producer(provider(slow(next))), deadline: shared, idleSeconds: 60)
        }
        #expect(TimedSSEProtocol.loads.withLock { $0[next] } == nil)
    }

    @Test func cancellationStopsTheTransferAndSurfacesAsCancellation() async throws {
        let before = TimedSSEProtocol.stopped.withLock { $0 }
        let client = provider(.init(chunks: (0..<100).map { delta("\($0)") } + [stop], delay: 0.1))
        let task = Task {
            try await StreamingSummary.run(request, producer: producer(client), deadline: MaintenanceDeadline(turnRemaining: 600))
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(TimedSSEProtocol.stopped.withLock { $0 } > before)
    }

    @Test func anOversizedLineIsRefusedNotTruncated() async throws {
        let long = delta(String(repeating: "长", count: 100_000)) // ~300 KB line > 256 KiB
        await #expect(throws: (any Error).self) {
            try await StreamingSummary.run(request, producer: producer(provider(.init(chunks: [long, stop]))),
                                           deadline: MaintenanceDeadline(turnRemaining: 600))
        }
    }
}
