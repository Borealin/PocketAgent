import AgentKit
import Foundation
import Synchronization

/// Local acceptance fixture (launch argument `-PocketAgentSummaryMaintenanceProbe`,
/// and a host test): the real `SummaryMaintenance.run` over an isolated owner
/// whose writes go through the production writer to a temporary file, the
/// pinned AgentKit client's `consume` reading injected responses from a
/// `URLProtocol` registered only on its own session. Nothing touches the app's
/// history, settings, credentials or network. Each case starts from fresh data.
@MainActor
enum SummaryMaintenanceProbe {
    /// The injected provider. `stall` sends part of a summary, then waits until
    /// released (sends the rest) or until the transfer is cancelled.
    final class Provider: URLProtocol, @unchecked Sendable {
        enum Mode: Sendable { case summary, limit, stall }
        struct State: Sendable {
            var mode = Mode.summary
            var requests = 0
            var partialSent = false
            var released = false
            /// `stopLoading` was called (the transfer's cancellation arrived).
            var stopped = false
            /// The stalled response's loop has returned (released or stopped).
            var loopExited = false
        }
        static let state = Mutex(State())
        static let host = "summary-probe.pocketagent.invalid"
        private let cancelled = Mutex(false)

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        private func send(_ text: String) { client?.urlProtocol(self, didLoad: Data(text.utf8)) }
        static func delta(_ text: String) -> String {
            let chunk = ["choices": [["index": 0, "delta": ["content": text]]]]
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data(), as: UTF8.self)
            return "data: \(json)\n\n"
        }
        static let finish = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        static let limitFrame = #"data: {"error":{"message":"This model's maximum context length is 8192 tokens.","code":"context_length_exceeded"}}"# + "\n\n"

        override func startLoading() {
            let (mode, call) = Self.state.withLock { state -> (Mode, Int) in state.requests += 1; return (state.mode, state.requests) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            switch mode {
            case .summary:
                send(Self.delta("## Goal\n第\(call)段整理")); send(Self.finish)
                client?.urlProtocolDidFinishLoading(self)
            case .limit:
                send(Self.delta("部分")); send(Self.limitFrame)
                client?.urlProtocolDidFinishLoading(self)
            case .stall:
                send(Self.delta("## Goal\n暂停中的整理"))
                Self.state.withLock { $0.partialSent = true }
                DispatchQueue.global().async { [self] in
                    defer { Self.state.withLock { $0.loopExited = true } }
                    while !cancelled.withLock({ $0 }) {
                        if Self.state.withLock({ $0.released }) {
                            send(Self.finish)
                            client?.urlProtocolDidFinishLoading(self)
                            return
                        }
                        usleep(20_000)
                    }
                }
            }
        }
        override func stopLoading() {
            cancelled.withLock { $0 = true }
            Self.state.withLock { $0.stopped = true }
        }
    }

    private final class Calls: Sendable {
        let registered = Mutex<[Bool]>([])
    }

    private struct Fixture {
        let directory: URL
        let storage: HistoryStorage
        let owner: HistoryOwner
        let prompt: UUID
        let segments: [ContextSegment]
        let plan: SummaryPlan
        let turn: SummaryMaintenance.Turn
    }

    /// Two earlier rounds, the current prompt, a plan of two single-round folds;
    /// the file written whole by the production writer before the run.
    private static func fixture() throws -> Fixture {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        for text in ["PKATEST_SUMMARY 第一轮", "PKATEST_SUMMARY 第二轮"] {
            let prompt = AgentTranscriptMessage(role: .user, text: text)
            try file.acceptRoot(prompt, attachments: [], in: primary, scope: .general)
            try file.commitDispatchPermit(root: prompt.id, sessionID: primary, scope: .general)
            try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "回复：" + text), to: primary, root: prompt.id)
        }
        let prompt = AgentTranscriptMessage(role: .user, text: "PKATEST_SUMMARY 当前")
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(file, sessionID: primary, before: prompt.id, scope: .general)
        guard segments.count == 2 else { throw CocoaError(.featureUnsupported) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa-summary-probe-\(UUID().uuidString)")
        let storage = HistoryStorage(url: directory.appendingPathComponent("history.json"))
        let writer = PatchingHistoryWriter(storage: storage)
        try writer.write(file)
        return Fixture(directory: directory, storage: storage, owner: HistoryOwner(file: file, store: writer), prompt: prompt.id,
                       segments: segments,
                       plan: SummaryPlan(sessionID: primary, scope: .general, predecessor: nil, folds: [[segments[0]], [segments[1]]]),
                       turn: .init(sessionID: primary, promptID: prompt.id, scope: .general, budget: .unknown,
                                   estimator: ContextEstimator(), summaryModel: "probe"))
    }

    private static func client() -> AgentProviderClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Provider.self]
        return AgentProviderClient(provider: ModelProvider(name: "probe", apiFormat: .chatCompletions,
                                                           inferenceURL: "https://\(Provider.host)/v1/x"),
                                   model: AIModel(id: "probe"), secret: "", session: URLSession(configuration: configuration))
    }

    /// Before each dispatch, the fold's read registration is read back from
    /// the file on disk (strict decode) and recorded.
    private static func producer(_ fixture: Fixture, _ calls: Calls) -> StreamingSummary.Producer {
        let client = client(), storage = fixture.storage, prompt = fixture.prompt
        let roots = fixture.segments.map(\.root)
        return { request, onEvent in
            let index = calls.registered.withLock { $0.count }
            var registered = false
            if case .loaded(let onDisk)? = try? storage.load(), index < roots.count {
                registered = onDisk.assistant.scopeIndex.scopedRoot(prompt)?.dependencies.rootReads.contains(roots[index]) == true
            }
            calls.registered.withLock { $0.append(registered) }
            do { try await client.consume(request, limits: .maintenance, onEvent: onEvent) }
            catch { throw ProviderContextLimit.classify(error, path: .summary) ?? error }
        }
    }

    private static func run(_ fixture: Fixture, _ calls: Calls) async -> Result<Void, any Error> {
        do {
            try await SummaryMaintenance.run(fixture.plan, turn: fixture.turn, owner: fixture.owner,
                                             producer: producer(fixture, calls), deadline: MaintenanceDeadline(turnRemaining: 600))
            return .success(())
        } catch { return .failure(error) }
    }

    private static func protectionClass(_ url: URL) -> Int32 {
        let fd = open(url.path, O_RDONLY)
        defer { if fd >= 0 { close(fd) } }
        return fd >= 0 ? fcntl(fd, F_GETPROTECTIONCLASS) : -1
    }

    private static func waitForLoopExit() async -> Bool {
        for _ in 0..<100 {
            if Provider.state.withLock({ $0.loopExited }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func waitForPartial() async -> Bool {
        for _ in 0..<500 {
            if Provider.state.withLock({ $0.partialSent }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Runs every case; booleans and counts only.
    static func report() async -> [String: Any] {
        var cases: [String: Any] = [:]
        var all = true
        func check(_ name: String, _ values: [String: Any], _ passed: Bool) { cases[name] = values.merging(["passed": passed]) { a, _ in a }; all = all && passed }
        do {
            // Two folds sent and committed by CAS; the file reloads to a valid tip.
            let success = try fixture(), calls = Calls()
            defer { try? FileManager.default.removeItem(at: success.directory) }
            Provider.state.withLock { $0 = .init(mode: .summary) }
            let result = await run(success, calls)
            let compactions = success.owner.file.assistant.compactions
            var reloadValid = false, reloadEqual = false
            if case .loaded(let reloaded)? = try? success.storage.load() {
                reloadEqual = reloaded.assistant.compactions == compactions
                let eligible = AssistantContext.eligibleSegments(reloaded, sessionID: success.turn.sessionID, before: success.prompt,
                                                                 scope: .general).flatMap(\.messages)
                if let (tip, covered) = AssistantContext.validSummary(reloaded, sessionID: success.turn.sessionID, scope: .general,
                                                                      eligible: eligible) {
                    reloadValid = tip.id == compactions.last?.id && covered == eligible.count
                }
            }
            let registered = calls.registered.withLock { $0 }
            let chained = compactions.count == 2 && compactions[1].predecessorID == compactions[0].id
            let protection = protectionClass(success.storage.url)
            let classC = protection == HistoryStorage.protectionClass || !HistoryPatchCalls.protectionRequiredByPlatform
            check("success", ["ok": (try? result.get()) != nil, "providerRequests": Provider.state.withLock { $0.requests },
                              "registrationOnDiskBeforeEachDispatch": registered == [true, true], "compactions": compactions.count,
                              "chained": chained, "reloadEqual": reloadEqual, "reloadValidTip": reloadValid,
                              "fileProtectionClass": Int(protection)],
                  (try? result.get()) != nil && registered == [true, true] && chained && reloadEqual && reloadValid && classC
                      && Provider.state.withLock { $0.requests } == 2)

            // The provider rejects the summary request as too large: typed,
            // turn-stopping, nothing committed, no later fold.
            let limit = try fixture(), limitCalls = Calls()
            defer { try? FileManager.default.removeItem(at: limit.directory) }
            Provider.state.withLock { $0 = .init(mode: .limit) }
            let limited = await run(limit, limitCalls)
            var typed = false, stops = false
            if case .failure(let error) = limited {
                typed = (error as? ProviderContextLimit)?.path == .summary
                stops = SummaryMaintenance.stopsTurn(error)
            }
            let limitRegistered = limitCalls.registered.withLock { $0 } == [true]
            check("providerLimit", ["typedSummaryLimit": typed, "stopsTurnDecision": stops, "providerRequests": Provider.state.withLock { $0.requests },
                                    "registrationOnDiskBeforeDispatch": limitRegistered,
                                    "compactions": limit.owner.file.assistant.compactions.count],
                  typed && stops && limitRegistered && limit.owner.file.assistant.compactions.isEmpty
                      && Provider.state.withLock { $0.requests } == 1)

            // Stop while the fold streams: the run ends only after the
            // transfer has stopped; the partial summary is discarded.
            let cancel = try fixture(), cancelCalls = Calls()
            defer { try? FileManager.default.removeItem(at: cancel.directory) }
            Provider.state.withLock { $0 = .init(mode: .stall) }
            let running = Task { @MainActor in await run(cancel, cancelCalls) }
            let streaming = await waitForPartial()
            running.cancel()
            let cancelled = await running.value
            var cancelStops = false
            if case .failure(let error) = cancelled { cancelStops = SummaryMaintenance.stopsTurn(error) }
            let transferStopped = Provider.state.withLock { $0.stopped }
            let loopExited = await waitForLoopExit()
            check("cancelWhileStreaming", ["streamingWhenStopped": streaming, "stopsTurnDecision": cancelStops,
                                           "cancelCallbackBeforeRunEnded": transferStopped, "providerLoopExited": loopExited,
                                           "providerRequests": Provider.state.withLock { $0.requests },
                                           "compactions": cancel.owner.file.assistant.compactions.count],
                  streaming && cancelStops && transferStopped && loopExited && cancel.owner.file.assistant.compactions.isEmpty
                      && Provider.state.withLock { $0.requests } == 1)

            // The fold's own source is forgotten while it streams: the
            // completed summary is discarded and the turn stops.
            let forget = try fixture(), forgetCalls = Calls()
            defer { try? FileManager.default.removeItem(at: forget.directory) }
            Provider.state.withLock { $0 = .init(mode: .stall) }
            let forgetting = Task { @MainActor in await run(forget, forgetCalls) }
            let forgetStreaming = await waitForPartial()
            var masked = false
            do {
                try forget.owner.transact {
                    try $0.assistant.scopeIndex.mask(root: forget.segments[0].root, by: UUID())
                    $0.assistant.memory.forgetEpoch += 1
                }
                masked = true
            } catch {}
            Provider.state.withLock { $0.released = true }
            let forgotten = await forgetting.value
            var revoked = false
            if case .failure(let error) = forgotten { revoked = error is ContextSourceRevoked }
            let forgetLoopExited = await waitForLoopExit()
            check("forgetWhileStreaming", ["streamingWhenForgotten": forgetStreaming, "maskCommitted": masked,
                                           "contextSourceRevoked": revoked, "providerLoopExited": forgetLoopExited,
                                           "providerRequests": Provider.state.withLock { $0.requests },
                                           "compactions": forget.owner.file.assistant.compactions.count],
                  forgetStreaming && masked && revoked && forgetLoopExited && forget.owner.file.assistant.compactions.isEmpty
                      && Provider.state.withLock { $0.requests } == 1)

            // A fold's source message is edited (same ID and membership) while
            // it streams: the commit's compare-and-swap rejects the stale input;
            // the edit stays, nothing is committed and the next fold is not sent.
            let changed = try fixture(), changedCalls = Calls()
            defer { try? FileManager.default.removeItem(at: changed.directory) }
            Provider.state.withLock { $0 = .init(mode: .stall) }
            let changing = Task { @MainActor in await run(changed, changedCalls) }
            let changeStreaming = await waitForPartial()
            guard let edited = changed.segments[0].messages.last?.id else { throw CocoaError(.featureUnsupported) }
            let replacement = "PKATEST_SUMMARY 已改动的回复"
            var editCommitted = false
            do {
                try changed.owner.transact { file in
                    try file.editSession(changed.turn.sessionID) { session in
                        if let index = session.messages.firstIndex(where: { $0.id == edited }) { session.messages[index].text = replacement }
                    }
                }
                editCommitted = true
            } catch {}
            Provider.state.withLock { $0.released = true }
            let stale = await changing.value
            var rejected = false, staleStops = true
            if case .failure(let error) = stale {
                rejected = (error as? SummaryPreparationError)?.detail == "整理结果与当前历史不一致，已丢弃"
                staleStops = SummaryMaintenance.stopsTurn(error)
            }
            var editOnDisk = false
            if case .loaded(let reloaded)? = try? changed.storage.load() {
                editOnDisk = reloaded.session(changed.turn.sessionID)?.messages.first(where: { $0.id == edited })?.text == replacement
                    && reloaded.assistant.compactions.isEmpty
            }
            let changedLoopExited = await waitForLoopExit()
            check("sourceChangedWhileStreaming", ["streamingWhenChanged": changeStreaming, "editCommitted": editCommitted,
                                                  "commitRejectedStaleInput": rejected, "stopsTurnDecision": staleStops,
                                                  "editAndNoSummaryOnDisk": editOnDisk, "providerLoopExited": changedLoopExited,
                                                  "providerRequests": Provider.state.withLock { $0.requests },
                                                  "compactions": changed.owner.file.assistant.compactions.count],
                  changeStreaming && editCommitted && rejected && !staleStops && editOnDisk && changedLoopExited
                      && changed.owner.file.assistant.compactions.isEmpty && Provider.state.withLock { $0.requests } == 1)
        } catch {
            cases["setupError"] = String(describing: type(of: error))
            all = false
        }
        return ["fixture": "isolated owner + production writer to a temporary file; real SummaryMaintenance.run; pinned AgentKit consume over an isolated URLProtocol; injected provider responses",
                "scope": [
                    "stopsTurnDecision": "SummaryMaintenance.stopsTurn on the thrown error only; no main request or phone dispatch is run by this fixture",
                    "cancelWhileStreaming": "the run task is cancelled; the URLProtocol's stopLoading arrival and its loop exit are recorded",
                    "forgetWhileStreaming": "low-level revocation (scope mask + forget epoch through the owner), not the memory panel's forget flow",
                    "sourceChangedWhileStreaming": "a fold source's text edited through the owner while it streams; the rejection is the real commitSummary compare-and-swap (a preparation error: the turn continues without a new summary)",
                ],
                "cases": cases, "allPassed": all]
    }
}
