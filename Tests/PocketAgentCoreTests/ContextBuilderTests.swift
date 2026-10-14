import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct ContextBuilderTests {
    fileprivate struct Fixture {
        var file = HistoryFile.initial(selection: nil)
        var primary: UUID { file.assistant.primarySessionID }

        @discardableResult
        mutating func turn(_ text: String, scope: WorkScope = .general, reply: String? = nil,
                           tool: Bool = false) throws -> UUID {
            let prompt = AgentTranscriptMessage(role: .user, text: text)
            try file.acceptRoot(prompt, attachments: [], in: primary, scope: scope)
            try file.commitDispatchPermit(root: prompt.id, sessionID: primary, scope: scope)
            if tool {
                let call = AgentToolCall(id: "call-\(prompt.id.uuidString.prefix(6))", name: "observe_screen", arguments: .object([:]))
                try file.appendEvent(AgentTranscriptMessage(role: .assistant, toolCalls: [call]), to: primary, root: prompt.id)
                try file.appendEvent(AgentTranscriptMessage(role: .tool, text: #"{"ok":true,"screen":{"app":"x"}}"#,
                                                            toolCallID: call.id, toolName: call.name), to: primary, root: prompt.id)
            }
            try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: reply ?? "回复：" + text), to: primary, root: prompt.id)
            return prompt.id
        }

        func input(prompt: UUID, budget: ContextBudgetPolicy = .unknown) -> AssistantContext.Input {
            .init(file: file, sessionID: primary, promptID: prompt, scope: .general, references: [], budget: budget,
                  estimator: ContextEstimator(), systemPrompt: "s", tools: [],
                  prompt: [AgentTranscriptMessage(id: prompt, role: .user, text: "p")])
        }

        func candidate(covering segments: [ContextSegment], predecessor: StoredCompaction?, summary: String = "## Goal\n摘要") throws -> StoredCompaction {
            let messages = segments.flatMap(\.messages)
            let input = try AssistantContext.inputDigest(messages: messages, attachments: file.primary?.attachments ?? [:],
                                                         scope: .general, parent: predecessor)
            let record = AgentCompactionRecord(summaryMessageID: UUID(), compactedThroughMessageID: messages.last!.id,
                                               sequence: (predecessor?.record.sequence ?? 0) + 1, summary: summary,
                                               summarizedTokens: 1, keptTokens: 0, displayAnchor: Date(timeIntervalSince1970: 1))
            return StoredCompaction(id: record.id, record: record, sessionID: primary, scope: .general,
                sourceRootPromptIDs: segments.map(\.root), sourceMessageIDs: messages.map(\.id), predecessorID: predecessor?.id,
                predecessorDigest: predecessor?.recordDigest, inputDigest: input,
                recordDigest: try AssistantContext.recordDigest(inputDigest: input, record: record, sourceIDs: messages.map(\.id),
                                                                parentRecordDigest: predecessor?.recordDigest),
                builderVersion: AssistantContext.builderVersion, summaryPromptVersion: AssistantContext.summaryPromptVersion,
                forgetEpoch: 0, summaryModel: "m")
        }
    }

    @Test func eligibilityFollowsScopeMasksUnknownAndAbandonedRoots() throws {
        var fixture = Fixture()
        let project = UUID()
        let general = try fixture.turn("一般问题")
        _ = try fixture.turn("项目问题", scope: .workspace(project))
        // Unknown: synchronized message without membership.
        try fixture.file.editSession(fixture.primary) { $0.messages.append(AgentTranscriptMessage(role: .assistant, text: "远端")) }
        let masked = try fixture.turn("要遗忘的")
        try fixture.file.assistant.scopeIndex.mask(root: masked, by: UUID())
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        #expect(segments.map(\.root) == [general])
        let projectOnly = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id,
                                                            scope: .workspace(project))
        #expect(projectOnly.count == 1 && projectOnly[0].root != general)
    }

    /// A send that failed before its permit gives its draft back and the same
    /// text is sent again under a new ID. Later context, summaries and
    /// automatic history search use that text once, from the request that ran;
    /// a summary that still counted the unstarted copy is no longer trusted; a
    /// run that failed after its permit keeps its real and unknown results.
    @Test func requestsThatNeverStartedAreNotAutomaticContext() async throws {
        var fixture = Fixture()
        let earlier = try fixture.turn("第一轮")
        let failed = AgentTranscriptMessage(role: .user, text: "列出这些章节的标题")
        try fixture.file.acceptRoot(failed, attachments: [], in: fixture.primary, scope: .general)
        try fixture.file.editSession(fixture.primary) { $0.state = .failed }
        let resent = try fixture.turn("列出这些章节的标题")
        let interrupted = AgentTranscriptMessage(role: .user, text: "打开设置")
        try fixture.file.acceptRoot(interrupted, attachments: [], in: fixture.primary, scope: .general)
        try fixture.file.commitDispatchPermit(root: interrupted.id, sessionID: fixture.primary, scope: .general)
        let call = AgentToolCall(id: "call-open", name: "tap", arguments: .object([:]))
        try fixture.file.appendEvent(AgentTranscriptMessage(role: .assistant, toolCalls: [call]), to: fixture.primary,
                                     root: interrupted.id)
        try fixture.file.editSession(fixture.primary) { $0.state = .failed }
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        #expect(segments.map(\.root) == [earlier, resent, interrupted.id])
        let built = AssistantContext.build(fixture.input(prompt: prompt.id))
        #expect(built.messages.filter { $0.text == failed.text }.count == 1 && !built.messages.contains { $0.id == failed.id })
        #expect(built.messages.contains { $0.role == .tool && $0.toolCallID == call.id && $0.isError })
        // A summary written while the unstarted copy still counted is not trusted.
        let stored = try #require(fixture.file.primary?.messages.first { $0.id == failed.id })
        let stale = try fixture.candidate(covering: [segments[0], ContextSegment(root: failed.id, messages: [stored])], predecessor: nil)
        let good = try fixture.candidate(covering: [segments[0]], predecessor: nil)
        var withStale = fixture.file
        withStale.assistant.compactions.append(stale)
        #expect(AssistantContext.build(.init(file: withStale, sessionID: fixture.primary, promptID: prompt.id, scope: .general,
            references: [], budget: .unknown, estimator: ContextEstimator(), systemPrompt: "s", tools: [], prompt: [])).summaryID == nil)
        var withGood = fixture.file
        withGood.assistant.compactions.append(good)
        #expect(AssistantContext.build(.init(file: withGood, sessionID: fixture.primary, promptID: prompt.id, scope: .general,
            references: [], budget: .unknown, estimator: ContextEstimator(), systemPrompt: "s", tools: [], prompt: [])).summaryID == good.id)
        // Automatic history search finds only the request that ran.
        let snapshot = fixture.file
        let adapter = PocketMemoryAdapter(scope: .general, currentRoot: prompt.id, references: [], snapshot: { snapshot },
                                          register: { _, _, _ in })
        let found = try await adapter.searchSessions(AgentSessionSearchRequest(query: "章节的标题"))
        #expect(found.objectValue?["segments"]?.arrayValue?.compactMap { $0.objectValue?["root_prompt_id"]?.stringValue }
                == [resent.uuidString])
        // An explicit reference still shows the unstarted request, labelled as such (not as abandoned).
        let reference = HistoryReference(sessionID: fixture.primary, firstMessageID: failed.id, lastMessageID: failed.id,
                                         expectedContentDigest: try AssistantContext.referenceDigest([stored]))
        let quoted = try #require(AssistantContext.quote(reference, file: fixture.file))
        #expect(quoted.message.text.contains("未开始执行") && !quoted.message.text.contains("已放弃"))
    }

    @Test func interruptedGroupsGetDeterministicSyntheticRepairs() {
        let call = AgentToolCall(id: "c", name: "tap", arguments: .object([:]))
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        let orphan = AgentTranscriptMessage(role: .tool, text: "x", toolCallID: "zzz", toolName: "tap")
        let first = AssistantContext.repaired([assistant, orphan])
        let second = AssistantContext.repaired([assistant, orphan])
        #expect(first.messages.count == 2 && first.messages[1].toolCallID == "c" && first.messages[1].isError)
        #expect(first.synthetic == second.synthetic && first.synthetic.count == 1)
        #expect(!first.messages.contains { $0.id == orphan.id })
    }

    @Test func summaryChainCoverageDigestsAndInvalidation() throws {
        var fixture = Fixture()
        let a = try fixture.turn("第一轮", tool: true)
        let b = try fixture.turn("第二轮")
        let c = try fixture.turn("第三轮")
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        #expect(segments.map(\.root) == [a, b, c])
        let first = try fixture.candidate(covering: [segments[0]], predecessor: nil)
        try fixture.file.commitSummary(first)
        let second = try fixture.candidate(covering: [segments[1]], predecessor: first, summary: "## Goal\n合并后的摘要")
        try fixture.file.commitSummary(second)
        let built = AssistantContext.build(fixture.input(prompt: prompt.id))
        #expect(built.summaryID == second.id)
        #expect(built.messages.first?.isCompaction == true && built.syntheticIDs.contains(second.record.summaryMessageID))
        #expect(built.rawRoots == [c] && Set(built.summaryRoots) == [a, b])
        // A candidate that skips the uncovered middle is refused (coverage gap).
        let gap = try fixture.candidate(covering: [segments[2]], predecessor: first)
        #expect(throws: SummaryPreparationError.self) { try fixture.file.commitSummary(gap) }
        // A synchronized rewrite of a covered message invalidates the chain.
        var rewritten = fixture.file
        try rewritten.editSession(fixture.primary) { session in
            let index = session.messages.firstIndex { $0.id == segments[1].messages[1].id }!
            session.messages[index].text = "被改写"
        }
        let fallback = AssistantContext.build(.init(file: rewritten, sessionID: fixture.primary, promptID: prompt.id, scope: .general,
            references: [], budget: .unknown, estimator: ContextEstimator(), systemPrompt: "s", tools: [], prompt: []))
        #expect(fallback.summaryID == first.id && fallback.rawRoots == [b, c])
        // A forged record digest is not trusted.
        var forged = fixture.file
        forged.assistant.compactions[1].record.summary = "篡改"
        #expect(AssistantContext.build(.init(file: forged, sessionID: fixture.primary, promptID: prompt.id, scope: .general,
            references: [], budget: .unknown, estimator: ContextEstimator(), systemPrompt: "s", tools: [], prompt: [])).summaryID == first.id)
        // A parent cycle is rejected rather than followed.
        var cyclic = fixture.file
        cyclic.assistant.compactions[0].predecessorID = second.id
        #expect(AssistantContext.build(.init(file: cyclic, sessionID: fixture.primary, promptID: prompt.id, scope: .general,
            references: [], budget: .unknown, estimator: ContextEstimator(), systemPrompt: "s", tools: [], prompt: [])).summaryID == nil)
        // An unrelated new turn keeps the summary valid (no global epoch reset).
        _ = try fixture.turn("无关")
        #expect(AssistantContext.validSummary(fixture.file, sessionID: fixture.primary, scope: .general,
            eligible: AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: UUID(), scope: .general)
                .flatMap(\.messages))?.0.id == second.id)
    }

    @Test func summaryResponsesMustBeCompleteBoundedText() throws {
        #expect(try SummaryResponse.validate([.textDelta("## Goal"), .textSnapshot("## Goal\n完整"), .finished(.completed)]) == "## Goal\n完整")
        #expect(throws: SummaryPreparationError.self) { try SummaryResponse.validate([.textDelta("x"), .finished(.length)]) }
        #expect(throws: SummaryPreparationError.self) { try SummaryResponse.validate([.textDelta("x")]) }
        #expect(throws: SummaryPreparationError.self) {
            try SummaryResponse.validate([.toolCallSnapshot(id: "t", providerItemID: nil, name: "tap", arguments: "{}"), .finished(.completed)])
        }
        #expect(throws: SummaryPreparationError.self) { try SummaryResponse.validate([.textDelta("  "), .finished(.completed)]) }
        #expect(throws: SummaryPreparationError.self) {
            try SummaryResponse.validate([.textSnapshot(String(repeating: "长", count: 30_000)), .finished(.completed)])
        }
    }

    @Test func planKeepsRecentCompleteSegmentsAndSummarizesOlderOnes() throws {
        var fixture = Fixture()
        let long = String(repeating: "很长的内容。", count: 100)
        var roots: [UUID] = []
        for index in 0..<8 { roots.append(try fixture.turn("第 \(index) 轮", reply: long, tool: index % 2 == 0)) }
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 9_000))
        let built = AssistantContext.build(fixture.input(prompt: prompt.id, budget: budget))
        #expect(built.estimatedTokens > budget.summaryTrigger)
        guard let plan = built.plan else { Issue.record("expected a summary plan"); return }
        let folded = plan.folds.flatMap { $0.map(\.root) }
        #expect(!folded.isEmpty && folded.count < roots.count)
        #expect(folded == Array(roots.prefix(folded.count)))
        #expect(plan.folds.count <= AssistantContext.maxFolds)
        // Each fold is a run of whole segments; no call group is split.
        for fold in plan.folds { for segment in fold { #expect(segment.messages.first?.role == .user) } }
    }

    @Test func requestProjectionDropsForgottenSegmentsAndStopsOnActiveRoot() throws {
        var fixture = Fixture()
        let kept = try fixture.turn("保留", tool: true)
        let forgotten = try fixture.turn("遗忘", tool: true)
        let messages = fixture.file.primary!.messages
        var index = fixture.file.assistant.scopeIndex
        try index.mask(root: forgotten, by: UUID())
        let filtered = try AssistantRequestProjection.filterForgotten(messages, index: index, currentRoot: UUID(), invalidSummaries: [])
        #expect(Set(filtered.compactMap { index.root(of: $0.id) }) == [kept])
        #expect(throws: ContextSourceRevoked.self) {
            try AssistantRequestProjection.filterForgotten(messages, index: index, currentRoot: forgotten, invalidSummaries: [])
        }
    }

    @Test func oldPhoneScreensBecomeStaleRecordsButOtherToolsStay() {
        func screen(_ n: Int) -> AgentTranscriptMessage {
            AgentTranscriptMessage(role: .tool, text: #"{"ok":true,"action_issued":true,"screen":{"app":"a","snapshot_id":\#(n),"elements":[{"node":1,"label":"按钮"}]}}"#,
                                   toolCallID: "c\(n)", toolName: "tap")
        }
        let file = AgentTranscriptMessage(role: .tool, text: "\"screen\" 文件内容", toolCallID: "f", toolName: "read_file")
        let screens = [screen(1), screen(2), screen(3)]
        let projected = AssistantRequestProjection.projectOldScreens([screens[0], file, screens[1], screens[2]])
        #expect(projected[0].text.contains("过期观察") && !projected[0].text.contains("按钮") && projected[0].text.contains("action_issued"))
        #expect(projected[1] == file && projected[2] == screens[1] && projected[3] == screens[2])
    }

    /// Review finding: phone.prepare appends a synthetic screenshot caption as
    /// the last user message; memory relevance must follow the real request.
    @Test func memoryQueryIgnoresTheAppendedScreenshotCaption() {
        let prompt = AgentTranscriptMessage(role: .user, text: "帮我订北京的酒店")
        let reply = AgentTranscriptMessage(role: .assistant, text: "好")
        let caption = AgentTranscriptMessage(role: .user, text: "最新工具屏幕截图；对应 snapshot_id=3",
            images: [AgentImageAttachment(label: "s", mimeType: "image/png", data: Data([1]), pixelWidth: 1, pixelHeight: 1)])
        let query = AssistantRequestProjection.memoryQuery([prompt, reply, caption], real: [prompt.id, reply.id])
        #expect(query == "帮我订北京的酒店")
        var ledger = MemoryLedger()
        ledger.revision = 1
        ledger.active = [MemoryRecord(id: UUID(), target: .memory, scope: .global, content: "出差常住北京国贸", revision: 1,
                                      origin: .panel, sourceRootPromptIDs: [], sourceMessageIDs: [], createdAt: Date(), updatedAt: Date())]
        #expect(MemoryBlock.build(ledger, scope: .general, query: query).reads.count == 1)
        #expect(MemoryBlock.build(ledger, scope: .general, query: caption.text).reads.isEmpty)
    }

    /// The primary pipeline strips replay snapshots and sends modelText, through the real runtime.
    @Test func primaryPipelineSendsModelTextWithoutSnapshotBlocks() async throws {
        let model = ScriptedModel(turns: [[.textDelta("ok"), .finished(.completed)]])
        var loop = AgentLoopConfiguration()
        loop.contextPipeline = { _, _, _ in AssistantContextPipeline.pipeline }
        loop.contextSnapshot = { _, _ in AgentTurnContextSnapshot() }
        let runtime = AgentRuntime(model: model, tools: [], approval: AllowEverything(), configuration: loop)
        let tool = AgentTranscriptMessage(role: .tool, text: "完整原文", toolCallID: "c", toolName: "tap", modelText: "投影")
        let prior = [AgentTranscriptMessage(role: .assistant, toolCalls: [AgentToolCall(id: "c", name: "tap", arguments: .object([:]))]), tool]
        for await _ in await runtime.start(AgentRunRequest(conversationID: UUID(), prompt: "hi", permissionMode: .fullAccess,
                                                           systemPrompt: "s", priorMessages: prior)) {}
        let request = try #require(model.requests.first)
        #expect(request.messages.contains { $0.toolCallID == "c" && $0.text == "投影" })
        #expect(request.messages.allSatisfy { $0.contextSnapshot == nil })
        #expect(request.messages.count == 3) // no replayed context blocks
    }
}

struct AllowEverything: AgentApprovalHandling {
    func authorize(_ request: AgentApprovalRequest, mode: AgentPermissionMode) async -> AgentApprovalDecision { .allow }
}

private final class PreviewSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false
    var value: Bool { lock.withLock { seen } }
    func set(_ new: Bool) { lock.withLock { seen = new } }
}

private final class ProducerCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Checks right before every maintenance dispatch: the complete request
/// against the frozen budget, storage health and explicit forgets.
@MainActor
struct SummaryDispatchGuardTests {
    private typealias Fixture = ContextBuilderTests.Fixture

    private func turn(_ fixture: Fixture, prompt: UUID, budget: ContextBudgetPolicy = .unknown) -> SummaryMaintenance.Turn {
        .init(sessionID: fixture.primary, promptID: prompt, scope: .general, budget: budget, estimator: ContextEstimator(),
              summaryModel: "m")
    }

    private func producer(_ calls: ProducerCalls,
                          onCall: @escaping @Sendable (Int) async throws -> Void = { _ in }) -> StreamingSummary.Producer {
        { _, onEvent in
            let call = calls.next()
            try await onCall(call)
            try onEvent(.textDelta("## Goal\n第\(call)段摘要"))
            try onEvent(.finished(.completed))
        }
    }

    /// Two older rounds, the current prompt and the plan's two single-round folds.
    private func twoFolds() throws -> (Fixture, UUID, [ContextSegment], SummaryPlan) {
        var fixture = Fixture()
        _ = try fixture.turn("第一轮")
        _ = try fixture.turn("第二轮")
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        return (fixture, prompt.id, segments,
                SummaryPlan(sessionID: fixture.primary, scope: .general, predecessor: nil, folds: [[segments[0]], [segments[1]]]))
    }

    @Test func foldsWithinBudgetAreSentAndChained() async throws {
        let (fixture, prompt, segments, plan) = try twoFolds()
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let calls = ProducerCalls()
        try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt), owner: owner, producer: producer(calls),
                                         deadline: MaintenanceDeadline(turnRemaining: 600))
        #expect(calls.count == 2)
        #expect(owner.file.assistant.compactions.map(\.sourceRootPromptIDs) == [[segments[0].root], [segments[1].root]])
        #expect(owner.file.assistant.compactions[1].predecessorID == owner.file.assistant.compactions[0].id)
    }

    /// Counterexample: the planner reserves a fixed amount for a carried
    /// summary, but a stored 60 KB Chinese summary makes the real fold request
    /// larger than the soft target or a known window's ceiling. Nothing is sent.
    @Test func aLargeChinesePreviousSummaryIsRefusedBeforeAnyProducerCall() async throws {
        var fixture = Fixture()
        _ = try fixture.turn("第一轮")
        _ = try fixture.turn("第二轮")
        _ = try fixture.turn("第三轮", reply: String(repeating: "近", count: 5_000))
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        let large = try fixture.candidate(covering: [segments[0]], predecessor: nil,
                                          summary: "## Goal\n" + String(repeating: "摘", count: 20_000))
        #expect(large.record.summary.utf8.count <= SummaryResponse.maximumBytes)
        try fixture.file.commitSummary(large)
        let plan = try #require(AssistantContext.build(fixture.input(prompt: prompt.id)).plan)
        #expect(plan.predecessor?.id == large.id && plan.folds.map { $0.map(\.root) } == [[segments[1].root]])
        let known = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: 32_768))
        for budget in [ContextBudgetPolicy.unknown, known] {
            let owner = HistoryOwner(file: fixture.file, writer: { _ in })
            let calls = ProducerCalls()
            await #expect(throws: SummaryPreparationError.self) {
                try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt.id, budget: budget), owner: owner,
                                                 producer: producer(calls), deadline: MaintenanceDeadline(turnRemaining: 600))
            }
            #expect(calls.count == 0 && owner.file.assistant.compactions.map(\.id) == [large.id])
            // An ordinary preparation failure: the turn continues without a new summary.
            #expect(!SummaryMaintenance.stopsTurn(SummaryPreparationError(detail: "")))
        }
    }

    @Test func aForgetDuringMaintenanceStopsTheTurnBeforeDisclosingMore() async throws {
        let (fixture, prompt, segments, plan) = try twoFolds()
        // After the first fold, the user forgets the second fold's round.
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let calls = ProducerCalls()
        await #expect(throws: ContextSourceRevoked.self) {
            try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt), owner: owner,
                producer: producer(calls) { call in
                    guard call == 1 else { return }
                    try await MainActor.run {
                        try owner.transact {
                            try $0.assistant.scopeIndex.mask(root: segments[1].root, by: UUID())
                            $0.assistant.memory.forgetEpoch += 1
                        }
                    }
                }, deadline: MaintenanceDeadline(turnRemaining: 600))
        }
        #expect(calls.count == 1)
        #expect(owner.file.assistant.compactions.map(\.sourceRootPromptIDs) == [[segments[0].root]])
        // A forget of the fold's own source while it streams: its result is discarded.
        let during = HistoryOwner(file: fixture.file, writer: { _ in })
        let again = ProducerCalls()
        await #expect(throws: ContextSourceRevoked.self) {
            try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt), owner: during,
                producer: producer(again) { _ in
                    try await MainActor.run {
                        try during.transact { try $0.assistant.scopeIndex.mask(root: segments[0].root, by: UUID()) }
                    }
                }, deadline: MaintenanceDeadline(turnRemaining: 600))
        }
        #expect(again.count == 1 && during.file.assistant.compactions.isEmpty)
        #expect(SummaryMaintenance.stopsTurn(ContextSourceRevoked()))
    }

    @Test func storageFailureStopsTheTurnBeforeTheNextDispatch() async throws {
        let (fixture, prompt, _, plan) = try twoFolds()
        let dirty = HistoryOwner(file: fixture.file, health: .saveDirty("磁盘已满"), writer: { _ in })
        let none = ProducerCalls()
        await #expect(throws: StorageCommitError.self) {
            try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt), owner: dirty, producer: producer(none),
                                             deadline: MaintenanceDeadline(turnRemaining: 600))
        }
        #expect(none.count == 0)
        // The read registration before the first dispatch cannot be written: nothing is sent.
        let unwritable = HistoryOwner(file: fixture.file, writer: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let zero = ProducerCalls()
        await #expect(throws: StorageCommitError.self) {
            try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt), owner: unwritable, producer: producer(zero),
                                             deadline: MaintenanceDeadline(turnRemaining: 600))
        }
        #expect(zero.count == 0 && unwritable.file.assistant.scopeIndex.scopedRoot(prompt)?.dependencies.rootReads.isEmpty == true)
        // Registration written, then the first fold's commit fails: the second fold is never sent.
        var writes = 0
        let failing = HistoryOwner(file: fixture.file, writer: { _ in
            writes += 1
            if writes > 1 { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let one = ProducerCalls()
        await #expect(throws: StorageCommitError.self) {
            try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt), owner: failing, producer: producer(one),
                                             deadline: MaintenanceDeadline(turnRemaining: 600))
        }
        #expect(one.count == 1 && failing.file.assistant.compactions.isEmpty)
        #expect(SummaryMaintenance.stopsTurn(StorageCommitError.storageUnavailable) && SummaryMaintenance.stopsTurn(TurnDeadlineReached()))
    }

    /// The fold's reads are registered for the turn's root before dispatch, so
    /// a forget confirmed while the fold streams previews the preparing turn as
    /// affected, and committing it stops the turn before anything more is sent.
    @Test func aForgetPreviewDuringMaintenanceShowsThePreparingTurnAsAffected() async throws {
        var (fixture, prompt, segments, plan) = try twoFolds()
        let receipt = try fixture.file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "第一轮里说的偏好",
            origin: .chatChip, sourceRootPromptIDs: [segments[0].root], sourceMessageIDs: []))
        let entry = try #require(receipt.entryIDs.first)
        // Before maintenance read anything, the queued turn is not a reader.
        #expect(try fixture.file.forgetPreview([entry], activeRoot: prompt).stopsActiveRoot == false)
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let calls = ProducerCalls()
        let seen = PreviewSeen()
        await #expect(throws: ContextSourceRevoked.self) {
            try await SummaryMaintenance.run(plan, turn: turn(fixture, prompt: prompt), owner: owner,
                producer: producer(calls) { _ in
                    try await MainActor.run {
                        let preview = try owner.file.forgetPreview([entry], activeRoot: prompt)
                        seen.set(preview.stopsActiveRoot && preview.affectedRoots.contains(prompt))
                        try owner.transact { _ = try $0.commitForget(preview, activeRoot: prompt) }
                    }
                }, deadline: MaintenanceDeadline(turnRemaining: 600))
        }
        #expect(seen.value && calls.count == 1 && owner.file.assistant.compactions.isEmpty)
        #expect(owner.file.assistant.scopeIndex.isMasked(root: prompt))
    }

    /// Only the primary turn the engine executes can be stopped by a forget.
    @Test func forgetStopsOnlyTheExecutingPrimaryTurn() {
        let primary = UUID(), root = UUID(), task = UUID()
        #expect(ForgetStopPolicy.activeRoot(primaryID: primary, runningSessionID: primary, runningRoot: root, terminal: false) == root)
        // An independent task is running while a primary request waits in the queue.
        #expect(ForgetStopPolicy.activeRoot(primaryID: primary, runningSessionID: task, runningRoot: UUID(), terminal: false) == nil)
        #expect(ForgetStopPolicy.activeRoot(primaryID: primary, runningSessionID: nil, runningRoot: nil, terminal: true) == nil)
        #expect(ForgetStopPolicy.activeRoot(primaryID: primary, runningSessionID: primary, runningRoot: root, terminal: true) == nil)
    }
}
