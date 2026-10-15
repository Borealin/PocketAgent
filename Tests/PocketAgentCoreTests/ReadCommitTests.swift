import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// A finished general round that mentions a pass phrase, a memory entry taken
/// from it, and the current run's started root in the same session.
private struct ReadFixture {
    static let secret = "PKATEST_GAPS_口令是红色十九"
    static let transcript = "PKATEST_GAPS_口令已记下"
    var file: HistoryFile
    var entry: UUID
    var source: UUID
    var current: UUID

    init() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        source = try file.acceptCurrent("PKATEST_GAPS_上次说的口令", in: primary, scope: .general)
        try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: Self.transcript), to: primary, root: source)
        try file.editSession(primary) { $0.state = .completed }
        let saved = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: Self.secret, origin: .chatChip,
                                                  sourceRootPromptIDs: [source], sourceMessageIDs: [source]))
        entry = try #require(saved.entryIDs.first)
        current = try file.acceptCurrent("口令是什么", in: primary, scope: .general)
        self.file = file
    }

    static func forget(_ entry: UUID, in file: inout HistoryFile, activeRoot: UUID?) throws -> ForgetPreview {
        let preview = try file.forgetPreview([entry], activeRoot: activeRoot)
        _ = try file.commitForget(preview, activeRoot: activeRoot)
        return preview
    }

    static func search(_ adapter: PocketMemoryAdapter, session: Bool) async throws -> AgentJSONValue {
        session ? try await adapter.searchSessions(AgentSessionSearchRequest(query: "口令"))
                : try await adapter.searchMemories(AgentMemorySearchRequest(query: "口令"))
    }

    static func leaks(_ value: Any) -> Bool { "\(value)".contains("红色十九") || "\(value)".contains("口令已记下") }
}

/// The three ways a planned page can change before its commit.
private enum Change: CaseIterable, Sendable {
    case correctMemory, rewriteSource, deleteSource

    var searchesSessions: Bool { self != .correctMemory }

    func apply(_ file: inout HistoryFile, entry: UUID) throws {
        let primary = file.assistant.primarySessionID
        switch self {
        case .correctMemory:
            _ = try file.applyMemoryEdit(.replace(entryID: entry, expectedRevision: 1, content: "PKATEST_GAPS_口令是蓝色二十"))
        case .rewriteSource:
            try file.editSession(primary) { session in
                if let index = session.messages.firstIndex(where: { $0.role == .assistant }) {
                    session.messages[index].text = "PKATEST_GAPS_同步改写的口令"
                }
            }
        case .deleteSource:
            try file.editSession(primary) { session in session.messages.removeAll { $0.role == .assistant } }
        }
    }
}

/// memory_search / session_search return only what one owner transaction
/// verified against the latest history and registered as the run's reads.
struct ReadCommitTests {
    @Test func aForgetBeforeTheCommitMakesBothSearchesStaleAndRegistersNothing() async throws {
        let h = try ReadFixture()
        for session in [false, true] {
            let box = FileBox(h.file)
            // The planning snapshot is taken, then the user's forget commits.
            let adapter = PocketMemoryAdapter.testing(box, scope: .general, currentRoot: h.current, snapshot: {
                let planned = box.file
                box.edit { _ = try? ReadFixture.forget(h.entry, in: &$0, activeRoot: h.current) }
                return planned
            })
            let result = try await ReadFixture.search(adapter, session: session)
            #expect(result.objectValue?["status"]?.stringValue == "stale_search")
            #expect(!ReadFixture.leaks(result))
            let deps = try #require(box.file.assistant.scopeIndex.scopedRoot(h.current)).dependencies
            #expect(deps.memoryReads.isEmpty && deps.rootReads.isEmpty)
            // The run was not a reader, so the forget neither stopped nor masked it.
            #expect(!box.file.assistant.scopeIndex.isMasked(root: h.current))
        }
    }

    @Test(arguments: Change.allCases)
    fileprivate func correctionsRewritesAndDeletionsBetweenPlanAndCommitAreStale(_ change: Change) async throws {
        let h = try ReadFixture()
        let box = FileBox(h.file)
        let adapter = PocketMemoryAdapter.testing(box, scope: .general, currentRoot: h.current, snapshot: {
            let planned = box.file
            box.edit { try? change.apply(&$0, entry: h.entry) }
            return planned
        })
        let result = try await ReadFixture.search(adapter, session: change.searchesSessions)
        #expect(result.objectValue?["status"]?.stringValue == "stale_search")
        #expect(!ReadFixture.leaks(result))
    }

    /// Once the page is registered, a later forget finds the run among the
    /// readers: the preview stops it and the next request cannot carry the
    /// returned content (its root is masked).
    @Test func aForgetAfterRegistrationStopsTheReaderAndMasksItsNextRequest() async throws {
        let h = try ReadFixture()
        for session in [false, true] {
            let box = FileBox(h.file)
            let adapter = PocketMemoryAdapter.testing(box, scope: .general, currentRoot: h.current)
            let result = try await ReadFixture.search(adapter, session: session)
            #expect("\(result)".contains(session ? ReadFixture.transcript : ReadFixture.secret))
            var file = box.file
            let preview = try ReadFixture.forget(h.entry, in: &file, activeRoot: h.current)
            #expect(preview.stopsActiveRoot && preview.affectedRoots.contains(h.current))
            #expect(file.assistant.scopeIndex.isMasked(root: h.current))
            let tool = AgentTranscriptMessage(role: .tool, text: "\(result)", toolCallID: "c1", toolName: "memory_search")
            #expect(throws: ContextSourceRevoked.self) {
                try AssistantRequestProjection.filterForgotten([tool], index: file.assistant.scopeIndex, currentRoot: h.current,
                                                               dropped: [])
            }
        }
    }

    @Test func aFailedRegistrationWriteReturnsNoContentAndChangesNothing() async throws {
        let h = try ReadFixture()
        for session in [false, true] {
            let box = FileBox(h.file)
            let adapter = PocketMemoryAdapter.testing(box, scope: .general, currentRoot: h.current, writeFails: { true })
            await #expect(throws: StorageCommitError.self) { _ = try await ReadFixture.search(adapter, session: session) }
            #expect(box.file == h.file)
        }
    }

    @Test func pagesStayFrozenAndAChangedLaterPageIsStale() async throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        var ids: [UUID] = []
        for n in 0..<3 {
            let saved = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GAPS_口令\(n)号",
                                                      origin: .command, sourceRootPromptIDs: [], sourceMessageIDs: []))
            ids += saved.entryIDs
        }
        let current = try file.acceptCurrent("列出口令", in: primary, scope: .general)
        let box = FileBox(file)
        let adapter = PocketMemoryAdapter.testing(box, scope: .general, currentRoot: current)
        let first = try await adapter.searchMemories(AgentMemorySearchRequest(query: "口令", limit: 1))
        #expect(first.objectValue?["entries"]?.arrayValue?.count == 1 && first.objectValue?["next_offset"]?.numberValue == 1)
        let returned = try #require(first.objectValue?["entries"]?.arrayValue?.first?.objectValue?["id"]?.stringValue)
        // A new matching entry does not shift the frozen list.
        box.edit { _ = try? $0.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GAPS_口令新增",
                                                    origin: .command, sourceRootPromptIDs: [], sourceMessageIDs: [])) }
        let second = try await adapter.searchMemories(AgentMemorySearchRequest(query: "口令", limit: 1, offset: 1))
        let secondID = try #require(second.objectValue?["entries"]?.arrayValue?.first?.objectValue?["id"]?.stringValue)
        #expect(secondID != returned && ids.map(\.uuidString).contains(secondID))
        // Correct the entry the frozen list puts on the last page.
        let last = try #require(ids.first { ![returned, secondID].contains($0.uuidString) })
        box.edit { _ = try? $0.applyMemoryEdit(.replace(entryID: last, expectedRevision: 1, content: "PKATEST_GAPS_口令已更正")) }
        let third = try await adapter.searchMemories(AgentMemorySearchRequest(query: "口令", limit: 1, offset: 2))
        #expect(third.objectValue?["status"]?.stringValue == "stale_search" && !"\(third)".contains("号"))
        // After a stale page the list is rebuilt from the latest ledger.
        let fresh = try await adapter.searchMemories(AgentMemorySearchRequest(query: "口令", limit: 10))
        #expect("\(fresh)".contains("口令已更正") && "\(fresh)".contains("口令新增"))
    }

    @MainActor
    @Test func theGateStopsTheRunOnAReplacedRunAWrongRootOrAFailedWrite() async throws {
        let h = try ReadFixture()
        let plan = ReadPlan.memory([SearchPageCache.Memory(id: h.entry, revision: 1)], target: nil)
        func gate(_ owner: HistoryOwner, root: UUID? = nil, scope: WorkScope = .general,
                  active: Bool = true) throws -> ReadCommitResult {
            owner.barrier.open(epoch: 7)
            return try ReadCommitGate.commit(plan, owner: owner, root: root ?? h.current, scope: scope, references: [],
                                             epoch: 7, isActive: { active })
        }
        func stopped(_ owner: HistoryOwner) async -> Bool {
            do { try await owner.barrier.wait(epoch: 7, .messages([:]), timeout: .milliseconds(200)); return false }
            catch { return true }
        }
        // Replaced/cancelled/finished run.
        let replaced = HistoryOwner(file: h.file, writer: { _ in })
        #expect(throws: StorageCommitError.jobReplaced) { try gate(replaced, active: false) }
        #expect(replaced.file == h.file && replaced.health == .ready)
        #expect(await stopped(replaced))
        // The current root is no longer the started run it was frozen as.
        var unpermitted = h.file
        let waiting = AgentTranscriptMessage(role: .user, text: "未开始")
        try unpermitted.acceptRoot(waiting, attachments: [], in: unpermitted.assistant.primarySessionID, scope: .general)
        let wrong: [(HistoryFile, UUID, WorkScope)] = [(h.file, h.current, .workspace(UUID())),
                                                       (unpermitted, waiting.id, .general), (h.file, UUID(), .general)]
        for (file, root, scope) in wrong {
            let owner = HistoryOwner(file: file, writer: { _ in })
            #expect(throws: StorageCommitError.jobReplaced) { try gate(owner, root: root, scope: scope) }
            #expect(owner.file == file)
            #expect(await stopped(owner))
        }
        // A masked current root (its source forgotten) is revoked.
        var masked = h.file
        _ = try ReadFixture.forget(h.entry, in: &masked, activeRoot: nil)
        try masked.assistant.scopeIndex.mask(root: h.current, by: UUID())
        #expect(throws: ContextSourceRevoked.self) { try gate(HistoryOwner(file: masked, writer: { _ in })) }
        // A failed write: nothing published, storage health unchanged, the run's epoch failed.
        let failing = HistoryOwner(file: h.file, writer: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(throws: StorageCommitError.self) { try gate(failing) }
        #expect(failing.file == h.file && failing.health == .ready)
        #expect(await stopped(failing))
        // Success registers exactly the returned entry.
        let owner = HistoryOwner(file: h.file, writer: { _ in })
        guard case .memory(let records) = try gate(owner) else { Issue.record("expected memory"); return }
        #expect(records.map(\.content) == [ReadFixture.secret])
        #expect(owner.file.assistant.scopeIndex.scopedRoot(h.current)?.dependencies.memoryReads.map(\.entryID) == [h.entry])
        #expect(!(await stopped(owner)))
    }
}

/// Fails exactly the next write after `arm()`.
private final class WriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func take() -> Bool { lock.withLock { defer { armed = false }; return armed } }
}

/// The same contract through the pinned AgentRuntime, the main-model gate and
/// the tool dispatch gate, with events recorded through the owner as the
/// product does: the forgotten plaintext is never sent in a model request,
/// and a read that could not be registered stops the run.
@MainActor
struct ReadCommitRuntimeTests {
    fileprivate enum Case: Sendable { case forgetBeforeCommit, forgetAfterRegistration, registrationWriteFails }

    private struct Outcome {
        var requests: [AgentModelRequest]
        var terminal: AgentRunState?
        var sideEffects: Int
        var owner: HistoryOwner
        var current: UUID
    }

    private func run(_ race: Case, session: Bool) async throws -> Outcome {
        let h = try ReadFixture()
        let primary = h.file.assistant.primarySessionID
        let fault = WriteFault()
        let owner = HistoryOwner(file: h.file, writer: { _ in
            if fault.take() { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let epoch: UInt64 = 1
        let prompt = try #require(h.file.session(primary)?.messages.first { $0.id == h.current })
        owner.barrier.open(epoch: epoch, seed: [prompt.id: try CommittedMessage(prompt)])
        let entry = h.entry, current = h.current
        let forgetNow: @MainActor @Sendable () throws -> Void = {
            try owner.transact { _ = try ReadFixture.forget(entry, in: &$0, activeRoot: current) }
        }
        let adapter = PocketMemoryAdapter(scope: .general, currentRoot: current, references: [],
            snapshot: {
                await MainActor.run {
                    let planned = owner.file
                    if race == .forgetBeforeCommit { try? forgetNow() }
                    return planned
                }
            },
            commit: { plan in
                try await MainActor.run {
                    if race == .registrationWriteFails { fault.arm() }
                    return try ReadCommitGate.commit(plan, owner: owner, root: current, scope: .general, references: [],
                                                     epoch: epoch, isActive: { true })
                }
            })
        let name = session ? "session_search" : "memory_search"
        let search = session ? AnyAgentTool(SessionSearchTool(store: adapter)) : AnyAgentTool(MemorySearchTool(store: adapter))
        // The user's forget lands right after the result was registered and
        // returned; the product then also cancels the run (not simulated).
        let searchTool = AnyAgentTool(descriptor: search.descriptor) { invocation, context in
            let result = try await search.execute(invocation, context: context)
            if race == .forgetAfterRegistration { try await MainActor.run { try forgetNow() } }
            return result
        }
        let sideEffects = CallCounter()
        let phoneTool = AnyAgentTool(descriptor: ToolCatalog.phoneTools[0].descriptor) { invocation, _ in
            sideEffects.increment()
            return AgentToolResult(callID: invocation.call.id, content: "{\"ok\":true}")
        }
        var first: [AgentModelStreamEvent] = [.toolCallSnapshot(id: "c1", providerItemID: nil, name: name, arguments: #"{"query":"口令"}"#)]
        if race != .forgetAfterRegistration {
            first.append(.toolCallSnapshot(id: "c2", providerItemID: nil, name: phoneTool.descriptor.name, arguments: "{}"))
        }
        first.append(.finished(.toolCalls))
        let base = ScriptedModel(turns: [first, [.textDelta("完成"), .finished(.completed)]])
        let model = CommitGatedModel(base: base, barrier: owner.barrier, epoch: epoch, promptID: prompt.id, synthetic: { [] },
            prepare: { request in
                try await MainActor.run {
                    var prepared = request
                    prepared.messages = try AssistantRequestProjection.filterForgotten(
                        request.messages, index: owner.file.assistant.scopeIndex, currentRoot: current, dropped: [])
                    return prepared
                }
            }, commitTimeout: .seconds(5))
        let approval = CommitGatedApproval(barrier: owner.barrier, epoch: epoch, decide: { _ in .allow },
                                           commitTimeout: .seconds(5))
        var loop = AgentLoopConfiguration()
        loop.toolExecution = .sequential; loop.maximumToolConcurrency = 1; loop.modelRetryPolicy = .disabled
        let runtime = AgentRuntime(model: model, tools: [searchTool, phoneTool], approval: approval, configuration: loop)
        func record(_ message: AgentTranscriptMessage, result: TranscriptCommitBarrier.ResultKey? = nil) {
            let stored = ChatSession.forHistory(message)
            let commit = try? CommittedMessage(stored)
            owner.record(commit: commit.map { .init(epoch: epoch, messages: [stored.id: $0], results: result.map { [$0] } ?? []) }) {
                try $0.appendEvent(stored, to: primary, root: current)
            }
        }
        var terminal: AgentRunState?
        for await event in await runtime.start(AgentRunRequest(conversationID: primary, promptID: prompt.id, prompt: prompt.text,
                                                                permissionMode: .fullAccess, systemPrompt: "s", priorMessages: [])) {
            switch event {
            case .messageFinished(let message): record(message)
            case .toolFinished(let invocation, let result):
                record(AgentTranscriptMessage(id: AgentTranscriptMessage.toolResultID(runID: invocation.runID, callID: result.callID),
                                              role: .tool, text: result.content, toolCallID: result.callID,
                                              toolName: invocation.call.name, isError: result.isError, modelText: result.modelContent),
                       result: .init(runID: invocation.runID, callID: result.callID))
            case .runFinished(let summary): terminal = summary.state
            default: break
            }
        }
        return Outcome(requests: base.requests, terminal: terminal, sideEffects: sideEffects.count, owner: owner, current: current)
    }

    private func carries(_ requests: [AgentModelRequest], _ text: String) -> Bool {
        requests.contains { request in request.messages.contains { ($0.modelText ?? $0.text).contains(text) } }
    }

    @Test func aForgetBeforeTheCommitIsAStaleResultAndTheRunContinuesWithoutTheText() async throws {
        for session in [false, true] {
            let outcome = try await run(.forgetBeforeCommit, session: session)
            #expect(outcome.requests.count == 2 && outcome.terminal == .completed && outcome.sideEffects == 1)
            #expect(!carries(outcome.requests, "红色十九") && !carries(outcome.requests, "口令已记下"))
            #expect(carries(outcome.requests, "stale_search"))
        }
    }

    @Test func aForgetAfterRegistrationStopsTheRunBeforeTheNextRequest() async throws {
        for session in [false, true] {
            let outcome = try await run(.forgetAfterRegistration, session: session)
            #expect(outcome.requests.count == 1 && outcome.terminal == .failed)
            #expect(!carries(outcome.requests, "红色十九") && !carries(outcome.requests, "口令已记下"))
        }
    }

    /// One failed registration write, then successful event writes: the
    /// search returns no content, the later phone call in the same message is
    /// denied, no further model request is sent and storage stays ready.
    @Test func aFailedRegistrationWriteStopsTheRunThoughLaterEventWritesSucceed() async throws {
        for session in [false, true] {
            let outcome = try await run(.registrationWriteFails, session: session)
            #expect(outcome.requests.count == 1 && outcome.terminal == .failed && outcome.sideEffects == 0)
            #expect(outcome.owner.health == .ready)
            let file = outcome.owner.file
            let deps = try #require(file.assistant.scopeIndex.scopedRoot(outcome.current)).dependencies
            #expect(deps.memoryReads.isEmpty && deps.rootReads.isEmpty)
            // Both tool results were recorded by later successful writes, as errors without the content.
            let tools = file.session(file.assistant.primarySessionID)?.messages.filter { $0.role == .tool } ?? []
            #expect(tools.count == 2 && tools.allSatisfy { $0.isError == true } && !tools.contains { ReadFixture.leaks($0.text) })
        }
    }
}
