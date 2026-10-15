import AgentKit
import Foundation
import Synchronization
import Testing
@testable import PocketAgentCore

private final class StreamProtocol: URLProtocol, @unchecked Sendable {
    static let body = Mutex("")
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stream.pocketagent.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.withLock { $0 }.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func client(_ body: String) -> AgentProviderClient {
    StreamProtocol.body.withLock { $0 = body }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamProtocol.self]
    return AgentProviderClient(
        provider: ModelProvider(name: "t", apiFormat: .chatCompletions, inferenceURL: "https://stream.pocketagent.test/v1/x"),
        model: AIModel(id: "m"), secret: "", session: URLSession(configuration: configuration))
}

private let sentinel = "PKATEST_STREAM_SENTINEL"

/// A model that replays fixed events, then optionally fails.
private struct Scripted: AgentModelStreaming {
    let events: [AgentModelStreamEvent]
    let failure: (any Error & Sendable)?
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }
    func shouldRetry(after error: any Error) -> Bool { false }
}

/// Stream diagnostics are metadata: kinds, counts, timing, terminal and a
/// failure category by type, HTTP status or allowlisted code. Content, provider
/// messages and bodies never appear.
struct StreamDiagnosticsTests {
    private func json(_ fields: [String: any Sendable]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func aTraceCountsKindsAndTheTerminalButNeverContent() throws {
        var trace = ModelStreamTrace(path: .main)
        for event: AgentModelStreamEvent in [.textDelta(sentinel), .reasoningDelta(sentinel), .textDelta("x"),
                                             .toolCallDelta(id: "c", name: "tap", arguments: sentinel),
                                             .usage(AgentTokenUsage()), .finished(.toolCalls)] {
            trace.saw(event)
        }
        trace.finished()
        #expect(trace.counts == ["textDelta": 2, "reasoningDelta": 1, "toolCallDelta": 1, "usage": 1, "finished": 1])
        #expect(trace.outcome == "ended" && trace.terminalReason == "toolCalls" && trace.firstEventMs != nil)
        let text = try json(trace.fields)
        #expect(!text.contains(sentinel) && !text.contains("tap") && text.contains("\"terminalSeen\":true"))
        // The event sequence ended without a terminal: "ended" alone does not claim one.
        var cut = ModelStreamTrace(path: .summary)
        cut.saw(.textDelta("partial")); cut.finished()
        #expect(cut.outcome == "ended" && cut.terminalReason == nil)
        #expect(try json(cut.fields).contains("\"terminalSeen\":false"))
    }

    @Test func failuresAreCategorisedByTypeStatusAndKnownCodeOnly() throws {
        let cases: [(any Error, String)] = [
            (CancellationError(), "cancelled"),
            (URLError(.cancelled), "cancelled"),
            (URLError(.networkConnectionLost), "urlError"),
            (AgentProviderError.http(502, "\(sentinel) https://pkatest.invalid/v1"), "http"),
            (AgentProviderError.invalidResponse, "providerResponse"),
            (ProviderContextLimit(path: .main, kind: .contextWindow, status: nil, code: "context_length_exceeded", reportedLimit: 8192),
             "contextLimit"),
            (CocoaError(.fileReadUnknown), "other"),
        ]
        for (error, kind) in cases {
            let category = StreamFailureCategory.of(error)
            #expect(category.kind == kind, "\(error)")
            let text = try json(category.fields)
            #expect(!text.contains(sentinel) && !text.contains("pkatest.invalid"), "\(error)")
        }
        #expect(StreamFailureCategory.of(URLError(.networkConnectionLost)).urlErrorCode == URLError.Code.networkConnectionLost.rawValue)
        #expect(StreamFailureCategory.of(AgentProviderError.http(502, sentinel)).httpStatus == 502)
        #expect(StreamFailureCategory.of(ProviderContextLimit(path: .main, kind: .contextWindow, status: nil,
                                                              code: "context_length_exceeded", reportedLimit: 8192)).providerCode
                == "context_length_exceeded")
    }

    /// An error frame inside the stream, through the pinned client: the frame
    /// is told apart from transport and HTTP failures, a known code is kept,
    /// an unknown one is only marked present, and the message never appears.
    @Test func anInStreamProviderErrorFrameKeepsOnlyItsKnownCode() async throws {
        let partial = #"data: {"choices":[{"index":0,"delta":{"content":"部分"}}]}"# + "\n\n"
        for (code, kept) in [("server_error", "server_error"), ("pkatest_unlisted_code", nil)] as [(String, String?)] {
            let source = client(partial + #"data: {"error":{"message":"Upstream response stream was interrupted \#(sentinel)","code":"\#(code)"}}"# + "\n\n")
            var failure: (any Error)?
            do { for try await _ in source.stream(AgentModelRequest(systemPrompt: "s", messages: [], tools: [])) {} }
            catch { failure = error }
            let category = StreamFailureCategory.of(try #require(failure))
            #expect(category.kind == "providerStreamError" && category.providerCode == kept && category.providerCodePresent)
            let text = try json(category.fields)
            #expect(!text.contains(sentinel) && !text.contains("Upstream") && !text.contains("pkatest_unlisted_code"))
        }
    }

    /// Every request through the gate is observed when it is handed to the
    /// provider and when it ends, failures included, without changing what the
    /// run sees.
    @Test func theGateObservesEachProviderRequest() async throws {
        let barrier = TranscriptCommitBarrier()
        let prompt = AgentTranscriptMessage(role: .user, text: "看一下屏幕")
        barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        let seen = Mutex<[ModelStreamTrace]>([])
        for (events, failure) in [([AgentModelStreamEvent.textDelta(sentinel), .finished(.completed)], nil),
                                  ([.textDelta("半")], URLError(.networkConnectionLost) as (any Error & Sendable)?)] {
            seen.withLock { $0 = [] }
            var model = CommitGatedModel(base: Scripted(events: events, failure: failure), barrier: barrier, epoch: 1,
                                         promptID: prompt.id, synthetic: { [] }, prepare: { $0 })
            model.observe = { trace in seen.withLock { $0.append(trace) } }
            var delivered = 0, thrown: (any Error)?
            do {
                for try await _ in model.stream(AgentModelRequest(systemPrompt: "s", messages: [prompt], tools: [])) { delivered += 1 }
            } catch { thrown = error }
            let traces = seen.withLock { $0 }
            #expect(delivered == events.count && (thrown != nil) == (failure != nil))
            #expect(traces.count == 2 && traces[0].outcome == nil)
            if failure == nil {
                #expect(traces[1].outcome == "ended" && traces[1].terminalReason == "completed")
            } else {
                #expect(traces[1].outcome == "failed" && traces[1].failure?.kind == "urlError" && traces[1].terminalReason == nil)
            }
        }
    }

    /// One stamp per run: every source shares its sequence, and an event keeps
    /// the run it was stamped for and its own time, however late it is written.
    @Test func aRunStampOrdersEverySourceOfTheRun() async throws {
        let url = URL(fileURLWithPath: "/tmp/run-a.jsonl")
        let stamp = RunLogStamp(runID: "run-a", url: url)
        let sequences = await withTaskGroup(of: [Int].self) { group in
            for _ in 0..<4 { group.addTask { (0..<100).map { _ in stamp.origin().sequence } } }
            var all: [Int] = []
            for await part in group { all += part }
            return all
        }
        #expect(Set(sequences).count == 400 && sequences.min() == 1 && sequences.max() == 400)
        let early = stamp.origin()
        try await Task.sleep(for: .milliseconds(20))
        let late = stamp.origin()
        #expect(early.runID == "run-a" && early.url == url && early.sequence < late.sequence)
        #expect(early.time < late.time && early.rawMs <= late.rawMs)
    }
}

/// Only a refusal proven to precede everything an effect could send makes it
/// "not executed"; a composite operation whose first call acted stays reported.
struct PhoneEffectRefusalTests {
    /// Stands in for the DDI control's dispatch accounting.
    private final class Control {
        enum Step { case dispatch, refuseBeforeDispatch, refusedAtNativeEntry, dispatchThenTimeout, cancelledBeforeDispatch }
        var dispatched = 0
        func run(_ step: Step) throws {
            switch step {
            case .dispatch: dispatched += 1
            case .refuseBeforeDispatch: throw PhoneCallNotDispatched.insufficientTime
            case .refusedAtNativeEntry:
                // Counted when handed to the worker, uncounted when native
                // entry refuses the expiry (nothing ran).
                dispatched += 1; dispatched -= 1
                throw PhoneCallNotDispatched(reason: "期限在交给设备前已过")
            case .dispatchThenTimeout: dispatched += 1; throw URLError(.timedOut)
            case .cancelledBeforeDispatch: throw CancellationError()
            }
        }
    }

    /// The executor's effect bracket: begin, run, settle on failure.
    private func effect(_ effects: inout PhoneCallEffects, _ control: Control, _ steps: [Control.Step]) {
        let before = effects.beginAction()
        let dispatched = control.dispatched
        do { for step in steps { try control.run(step) } }
        catch { effects.settle(after: error, restoring: before, dispatchedDuringOperation: control.dispatched - dispatched) }
    }

    @Test func onlyARefusalBeforeAnyDispatchOfTheOperationIsUnsent() {
        for (steps, issued) in [([Control.Step.refuseBeforeDispatch], false),
                                ([.refusedAtNativeEntry], false),
                                // `clear` was sent, then its follow-up observation was refused.
                                ([.dispatch, .refuseBeforeDispatch], true),
                                ([.dispatch, .refusedAtNativeEntry], true),
                                // A timeout may follow a sent effect.
                                ([.dispatchThenTimeout], true),
                                // An untyped failure is never assumed unsent.
                                ([.cancelledBeforeDispatch], true)] as [([Control.Step], Bool)] {
            var effects = PhoneCallEffects()
            effect(&effects, Control(), steps)
            #expect(effects.issued == issued, "\(steps)")
        }
    }

    @Test func earlierEffectsAndPreparationStayReported() {
        // A preparation gesture was sent while observing; the tap is refused.
        var prepared = PhoneCallEffects()
        prepared.preparationSent()
        effect(&prepared, Control(), [.refuseBeforeDispatch])
        #expect(prepared.issued && prepared.preparation && !prepared.action)
        // An earlier effect of the same tool call was sent; the next is refused.
        var chain = PhoneCallEffects()
        let control = Control()
        effect(&chain, control, [.dispatch])
        effect(&chain, control, [.refuseBeforeDispatch])
        #expect(chain.issued && chain.action)
        // A native refusal before any touch keeps its earlier meaning.
        var covered = PhoneCallEffects()
        let before = covered.beginAction()
        covered.settle(after: PhoneObservationIssue.targetCovered, restoring: before, dispatchedDuringOperation: 1)
        #expect(!covered.issued)
    }
}

struct NotStartedCancellationTests {
    @Test func aStopWhilePreparingSaysOnlyWhatIsKnown() {
        let preparing = NotStartedCancellation.preparing
        // Summary requests may already have been sent: never claim none were.
        for claim in ["没有模型请求", "未发送", "没有请求", "排队"] {
            #expect(!preparing.detail.contains(claim) && !preparing.abandonDetail.contains(claim), "\(claim)")
        }
        #expect(preparing.detail.contains("主请求未开始") && preparing.detail.contains("手机操作"))
        #expect(preparing.abandonDetail.contains("主请求未开始"))
        // A request still waiting in the phone queue keeps its wording.
        #expect(NotStartedCancellation.queued.detail == "已取消排队任务。")
        #expect(NotStartedCancellation.queued.abandonDetail == "已取消，未开始执行。")
    }
}
