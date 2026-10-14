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
    }
    static let script = Mutex(Script())
    static let stopped = Mutex(0)
    private let cancelled = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "consume.pocketagent.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.script.withLock { $0 }
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
            if script.finish, !cancelled.withLock({ $0 }) { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        cancelled.withLock { $0 = true }
        Self.stopped.withLock { $0 += 1 }
    }
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
        let shared = MaintenanceDeadline(turnRemaining: 600, total: 1.2)
        let slow = TimedSSEProtocol.Script(chunks: (0..<8).map { delta("片段\($0)") } + [stop], delay: 0.1)
        _ = try await StreamingSummary.run(request, producer: producer(provider(slow)), deadline: shared, idleSeconds: 5)
        // The second fold has only the remainder (~0.3 s) and stops at the shared end.
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: producer(provider(slow)), deadline: shared, idleSeconds: 5)
        }
        #expect(shared.remaining <= 0)
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
