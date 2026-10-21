import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Review finding R1: an explicit reference becomes a request-only quote, so
/// its sources are never raw messages of the request. The quote keeps its
/// reference by its own ID; each request rechecks the window against the
/// latest history (still present, same digest, nothing masked) and registers
/// the current sources of what it actually carries.
///
/// The production-reachable path: in the old primary line root A read (or
/// contributed) memory E and repeated its fact; a diverging sync is resolved
/// with "新建空主线（保留记忆）", which keeps the old line as a task; turn B of
/// the new line quotes A, and B's own question does not match E. The run goes
/// through the pinned AgentRuntime, the main-model gate and the production
/// `AssistantRequestPreparer`; the forget is the panel's preview and commit,
/// and a preview that stops the active root revokes the job as
/// `ChatController.commitForget` does (tools then refuse through
/// `TurnEffectPolicy`).
@MainActor
struct QuoteRevocationTests {
    private static let fact = "PKATEST_QUOTE 车位在B2层117号"
    private static let ask = "照着引用说一下"

    enum Source { case read, contributed, unknownWindow }
    /// What changes in history while B runs, each through its production
    /// edit: the forget panel, `ChatSessions.delete` of the old line, or a
    /// sync that rewrote the quoted reply on another device.
    enum Step { case forgetEntry, forgetUnrelated, deleteSource, rewriteSource }

    struct Scenario {
        var file: HistoryFile
        var oldPrimary: UUID
        /// A's root, or nil for a window of synchronized messages without one.
        var a: UUID?
        var quoted: [UUID]
        var entry: UUID
        var unrelated: UUID
        var b: UUID
        var reference: HistoryReference
    }

    private func add(_ content: String, to file: inout HistoryFile, roots: [UUID] = [], messages: [UUID] = []) throws -> UUID {
        try #require(try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: content, origin: .chatChip,
                                                   sourceRootPromptIDs: roots, sourceMessageIDs: messages)).entryIDs.first)
    }

    func scenario(_ source: Source) throws -> Scenario {
        var file = HistoryFile.initial(selection: nil)
        let old = file.assistant.primarySessionID
        let unrelated = try add("PKATEST_QUOTE_OTHER 周三健身", to: &file)
        let a = try file.acceptCurrent("我的车位在哪", in: old, scope: .general)
        var entry: UUID?
        switch source {
        case .read:
            let id = try add(Self.fact, to: &file)
            try file.registerReads(root: a, memory: [MemoryReadRevision(entryID: id, revision: file.assistant.memory.entry(id)!.revision)],
                                   roots: [], messages: [])
            entry = id
        case .contributed:
            entry = try add(Self.fact, to: &file, roots: [a], messages: [a])
        case .unknownWindow: break
        }
        let reply = AgentTranscriptMessage(role: .assistant, text: "记下了：" + Self.fact)
        try file.appendEvent(reply, to: old, root: a)
        let x = try file.acceptCurrent("别的事", in: old, scope: .general)
        try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "好的"), to: old, root: x)
        try file.editSession(old) { $0.state = .completed }
        // Another device rewrote the later reply (and, for the unknown case,
        // added a question and answer): the primary line diverged.
        let base = PortableSnapshot(sessions: [file.session(old)!], sessionTombstones: [], providers: [], providerTombstones: [])
        var remote = try #require(PortableSession(file.session(old)!))
        remote.messages[remote.messages.count - 1].text = "远端改写"
        let synced = [AgentTranscriptMessage(role: .user, text: "车位号再说一遍"),
                      AgentTranscriptMessage(role: .assistant, text: "另一台设备：" + Self.fact)]
        if source == .unknownWindow { remote.messages += synced.map { PortableMessage($0, attribution: nil) } }
        _ = try file.applyPortable(merged: PortableSnapshot(sessions: [remote]), base: base, deferred: [])
        guard case .diverged = file.assistant.primaryNotice else { throw HistoryEditError.invalid("expected a diverged primary") }
        #expect(file.assistant.scopeIndex.scopedRoot(a)?.verified == true)
        if source == .unknownWindow {
            #expect(synced.allSatisfy { file.assistant.scopeIndex.root(of: $0.id) == nil })
            // The user later saved the synchronized answer as memory.
            entry = try add(Self.fact, to: &file, messages: [synced[1].id])
        }
        try file.startNewPrimary(selection: nil, busy: [])
        #expect(file.assistant.primarySessionID != old && file.session(old) != nil)
        let b = try file.acceptCurrent(Self.ask, in: file.assistant.primarySessionID, scope: .general)
        let ids = source == .unknownWindow ? synced.map(\.id) : [a, reply.id]
        let window = try ids.map { id in try #require(file.session(old)?.messages.first { $0.id == id }) }
        let reference = HistoryReference(sessionID: old, firstMessageID: window[0].id, lastMessageID: window[window.count - 1].id,
                                         expectedContentDigest: try AssistantContext.referenceDigest(window))
        return Scenario(file: file, oldPrimary: old, a: source == .unknownWindow ? nil : a, quoted: window.map(\.id),
                        entry: try #require(entry), unrelated: unrelated, b: b, reference: reference)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        private var shown: ForgetPreview?
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
        var preview: ForgetPreview? {
            get { lock.withLock { shown } }
            set { lock.withLock { shown = newValue } }
        }
    }

    struct Outcome {
        var requests: [AgentModelRequest]
        var terminal: AgentRunState?
        var effects: Int
        var preview: ForgetPreview?
        var quoteExclusions: Int
        var file: HistoryFile
    }

    /// `before` runs after the context was built and before the first
    /// request; `atFirstTool` inside the first tool call, after the first
    /// request was sent.
    func run(_ s: Scenario, before: [Step] = [], atFirstTool: [Step] = []) async throws -> Outcome {
        let owner = HistoryOwner(file: s.file, writer: { _ in })
        let primary = s.file.assistant.primarySessionID
        let prompt = try #require(s.file.session(primary)?.messages.first { $0.id == s.b })
        owner.barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        let prepared = AssistantContext.build(.init(file: owner.file, sessionID: primary, promptID: s.b, scope: .general,
                                                    references: [s.reference], budget: .unknown, estimator: ContextEstimator(),
                                                    systemPrompt: "s", tools: [], prompt: [prompt]))
        let preparer = AssistantRequestPreparer(owner: owner, sessionID: primary, promptID: s.b, scope: .general,
                                                budget: .unknown, estimator: { ContextEstimator() })
        preparer.rawRoots = prepared.rawRoots
        preparer.quotes = prepared.quotes
        let exclusions = CallCounter()
        preparer.onQuoteExclusion = { _ in exclusions.increment() }
        let revoked = Flag()
        let current = s.b
        let commitForget: @MainActor @Sendable (UUID) throws -> Void = { entry in
            let shown = try owner.file.forgetPreview([entry], activeRoot: current)
            try owner.transact { _ = try $0.commitForget(shown, activeRoot: current) }
            // ChatController.commitForget: only a preview that stops the active root revokes its job.
            if shown.stopsActiveRoot { revoked.set() }
            revoked.preview = shown
        }
        let old = s.oldPrimary, entry = s.entry, unrelated = s.unrelated, rewritten = s.quoted[s.quoted.count - 1]
        let apply: @MainActor @Sendable ([Step]) throws -> Void = { steps in
            for step in steps {
                switch step {
                case .forgetEntry: try commitForget(entry)
                case .forgetUnrelated: try commitForget(unrelated)
                case .deleteSource:
                    // ChatSessions.delete: the old line is a task, without a job or the pending request.
                    #expect(old != owner.file.assistant.primarySessionID && owner.file.assistant.pendingNext == nil)
                    try owner.transact { try $0.deleteSession(old) }
                case .rewriteSource:
                    let local = try #require(owner.file.session(old))
                    let base = PortableSnapshot(sessions: [local], sessionTombstones: [], providers: [], providerTombstones: [])
                    var remote = try #require(PortableSession(local))
                    let position = try #require(remote.messages.firstIndex { $0.id == rewritten })
                    remote.messages[position].text = "另一台设备改写了这条回复"
                    _ = try owner.transact { try $0.applyPortable(merged: PortableSnapshot(sessions: [remote]), base: base, deferred: []) }
                }
            }
        }
        try apply(before)
        let effects = CallCounter()
        let descriptor = ToolCatalog.phoneTools[0].descriptor
        let tool = AnyAgentTool(descriptor: descriptor) { invocation, _ in
            try await MainActor.run {
                if let reason = TurnEffectPolicy.blocked(storage: owner.health, isCurrent: true, isRunning: true,
                                                         cancelled: revoked.isSet, terminal: false) {
                    return AgentToolResult(callID: invocation.call.id, content: reason, isError: true)
                }
                effects.increment()
                if invocation.call.id == "c1" { try apply(atFirstTool) }
                return AgentToolResult(callID: invocation.call.id, content: #"{"ok":true}"#)
            }
        }
        let base = ScriptedModel(turns: [
            [.toolCallSnapshot(id: "c1", providerItemID: nil, name: descriptor.name, arguments: "{}"),
             .toolCallSnapshot(id: "c2", providerItemID: nil, name: descriptor.name, arguments: "{}"),
             .finished(.toolCalls)],
            [.textDelta("完成"), .finished(.completed)],
        ])
        let synthetic = prepared.syntheticIDs
        let model = CommitGatedModel(base: base, barrier: owner.barrier, epoch: 1, promptID: s.b, synthetic: { synthetic },
                                     prepare: { request in try await MainActor.run { try preparer.prepare(request) } },
                                     commitTimeout: .seconds(5))
        let approval = CommitGatedApproval(barrier: owner.barrier, epoch: 1, decide: { _ in .allow }, commitTimeout: .seconds(5))
        var loop = AgentLoopConfiguration()
        loop.toolExecution = .sequential; loop.maximumToolConcurrency = 1; loop.modelRetryPolicy = .disabled
        loop.contextPipeline = { _, _, _ in AssistantContextPipeline.pipeline }
        loop.contextSnapshot = { _, _ in AgentTurnContextSnapshot() }
        let runtime = AgentRuntime(model: model, tools: [tool], approval: approval, configuration: loop)
        func record(_ message: AgentTranscriptMessage, result: TranscriptCommitBarrier.ResultKey? = nil) {
            let stored = ChatSession.forHistory(message)
            let commit = try? CommittedMessage(stored)
            owner.record(commit: commit.map { .init(epoch: 1, messages: [stored.id: $0], results: result.map { [$0] } ?? []) }) {
                try $0.appendEvent(stored, to: primary, root: s.b)
            }
        }
        var terminal: AgentRunState?
        for await event in await runtime.start(AgentRunRequest(conversationID: primary, promptID: s.b, prompt: prompt.text,
                                                                permissionMode: .fullAccess,
                                                                systemPrompt: "s\n" + AssistantContextPipeline.memorySlot,
                                                                priorMessages: prepared.messages)) {
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
        return Outcome(requests: base.requests, terminal: terminal, effects: effects.count, preview: revoked.preview,
                       quoteExclusions: exclusions.count, file: owner.file)
    }

    private func carriesFact(_ request: AgentModelRequest) -> Bool {
        request.systemPrompt.contains(Self.fact) || request.messages.contains { ($0.modelText ?? $0.text).contains(Self.fact) }
    }

    private func carriesQuote(_ request: AgentModelRequest) -> Bool {
        request.messages.contains { $0.text.hasPrefix("[用户明确引用的历史记录") }
    }

    private func dependencies(_ outcome: Outcome, _ s: Scenario) throws -> RootDependencies {
        try #require(outcome.file.assistant.scopeIndex.scopedRoot(s.b)).dependencies
    }

    /// B carries the quote, registers its source, and a forget of E then
    /// stops B: the preview names B, no second tool effect and no further
    /// model request follow.
    @Test func aForgetOfTheQuotedSourceStopsTheQuotingTurn() async throws {
        for source in [Source.read, .contributed, .unknownWindow] {
            let s = try scenario(source)
            let outcome = try await run(s, atFirstTool: [.forgetEntry])
            #expect(outcome.requests.count == 1 && outcome.terminal == .failed, "\(source)")
            // B's own question never matched E; only the quote carried it.
            #expect(!outcome.requests[0].systemPrompt.contains(Self.fact), "\(source)")
            #expect(outcome.requests[0].messages.contains { $0.text.contains(Self.fact) }, "\(source)")
            let preview = try #require(outcome.preview)
            #expect(preview.stopsActiveRoot && preview.affectedRoots.contains(s.b), "\(source)")
            #expect(outcome.file.assistant.scopeIndex.isMasked(root: s.b), "\(source)")
            #expect(outcome.effects == 1, "\(source)")
            let deps = try dependencies(outcome, s)
            #expect(!deps.memoryReads.contains { $0.entryID == s.entry }, "\(source)")
            if let a = s.a { #expect(deps.rootReads == [a], "\(source)") } else { #expect(deps.historicalMessageReads == s.quoted) }
        }
    }

    /// A forget between building the context and the first request: B never
    /// read the source, so the preview does not stop it, and the quote is not
    /// sent nor registered; the run continues without it.
    @Test func aForgetBeforeTheFirstRequestDropsTheQuote() async throws {
        for source in [Source.read, .contributed, .unknownWindow] {
            let s = try scenario(source)
            let outcome = try await run(s, before: [.forgetEntry])
            #expect(outcome.preview?.stopsActiveRoot == false, "\(source)")
            #expect(outcome.requests.count == 2 && outcome.terminal == .completed && outcome.effects == 2, "\(source)")
            #expect(!outcome.requests.contains(where: carriesFact), "\(source)")
            #expect(outcome.quoteExclusions == 1, "\(source)")
            let deps = try dependencies(outcome, s)
            #expect(deps.rootReads.isEmpty && deps.historicalMessageReads.isEmpty, "\(source)")
            #expect(!outcome.file.assistant.scopeIndex.isMasked(root: s.b), "\(source)")
        }
    }

    /// A valid quote is sent on every request and registered; an unrelated
    /// forget does not stop the turn or drop it.
    @Test func aValidQuoteIsSentAndRegisteredAndAnUnrelatedForgetKeepsIt() async throws {
        for forget in [[], [Step.forgetUnrelated]] {
            let s = try scenario(.read)
            let outcome = try await run(s, atFirstTool: forget)
            #expect(outcome.requests.count == 2 && outcome.terminal == .completed && outcome.effects == 2, "\(forget)")
            #expect(outcome.requests.allSatisfy { $0.messages.contains { $0.text.contains(Self.fact) } }, "\(forget)")
            #expect(outcome.quoteExclusions == 0 && outcome.preview?.stopsActiveRoot != true, "\(forget)")
            #expect(try dependencies(outcome, s).rootReads == [s.a!], "\(forget)")
        }
    }

    /// A window whose source was already masked when the turn was built is
    /// neither quoted nor registered.
    @Test func anAlreadyMaskedSourceIsNeitherQuotedNorRegistered() async throws {
        for source in [Source.read, .unknownWindow] {
            var s = try scenario(source)
            let preview = try s.file.forgetPreview([s.entry], activeRoot: nil)
            _ = try s.file.commitForget(preview, activeRoot: nil)
            let outcome = try await run(s)
            #expect(outcome.requests.count == 2 && outcome.terminal == .completed, "\(source)")
            #expect(!outcome.requests.contains(where: carriesFact) && outcome.quoteExclusions == 0, "\(source)")
            let deps = try dependencies(outcome, s)
            #expect(deps.rootReads.isEmpty && deps.historicalMessageReads.isEmpty, "\(source)")
        }
    }

    /// Each request rechecks that the quoted window still exists with the
    /// referenced digest, not only that nothing in it is masked. Deleting the
    /// old line (which prunes A, read by nobody yet, with its memory reads)
    /// or a sync rewriting the quoted reply between building the context and
    /// the first request drops the quote: neither the deleted nor the stale
    /// text is sent, nothing is registered, and a later forget of E rightly
    /// finds no reader in B.
    @Test func aQuoteWhoseWindowIsGoneOrChangedBeforeTheFirstRequestIsNotSent() async throws {
        for source in [Source.read, .contributed, .unknownWindow] {
            for change in [Step.deleteSource, .rewriteSource] {
                let s = try scenario(source)
                let outcome = try await run(s, before: [change], atFirstTool: [.forgetEntry])
                let label = "\(source) \(change)"
                #expect(!outcome.requests.contains(where: carriesQuote) && !outcome.requests.contains(where: carriesFact), "\(label)")
                #expect(outcome.quoteExclusions == 1, "\(label)")
                #expect(outcome.requests.count == 2 && outcome.terminal == .completed && outcome.effects == 2, "\(label)")
                #expect(outcome.preview?.stopsActiveRoot == false, "\(label)")
                let deps = try dependencies(outcome, s)
                #expect(deps.rootReads.isEmpty && deps.historicalMessageReads.isEmpty, "\(label)")
            }
        }
    }

    /// Deleting the old line after a request carried the quote: later
    /// requests no longer carry it, and the read B registered keeps A's
    /// identity and reads (prune keeps a root another root read), so a later
    /// forget of E still stops B.
    @Test func aQuoteDeletedAfterItWasSentIsNotResentAndStaysTraceable() async throws {
        for source in [Source.read, .contributed, .unknownWindow] {
            let s = try scenario(source)
            let outcome = try await run(s, atFirstTool: [.deleteSource])
            #expect(outcome.requests.count == 2 && outcome.terminal == .completed, "\(source)")
            #expect(carriesQuote(outcome.requests[0]) && !carriesQuote(outcome.requests[1]), "\(source)")
            #expect(outcome.quoteExclusions == 1 && outcome.file.session(s.oldPrimary) == nil, "\(source)")
            let deps = try dependencies(outcome, s)
            if let a = s.a {
                #expect(deps.rootReads == [a] && outcome.file.assistant.scopeIndex.scopedRoot(a)?.verified == false, "\(source)")
            } else {
                #expect(deps.historicalMessageReads == s.quoted, "\(source)")
            }
            #expect(try outcome.file.forgetPreview([s.entry], activeRoot: s.b).stopsActiveRoot, "\(source)")
        }
    }
}
