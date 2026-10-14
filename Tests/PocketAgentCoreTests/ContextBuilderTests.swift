import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct ContextBuilderTests {
    private struct Fixture {
        var file = HistoryFile.initial(selection: nil)
        var primary: UUID { file.assistant.primarySessionID }

        @discardableResult
        mutating func turn(_ text: String, scope: WorkScope = .general, reply: String? = nil,
                           tool: Bool = false) throws -> UUID {
            let prompt = AgentTranscriptMessage(role: .user, text: text)
            try file.acceptRoot(prompt, attachments: [], in: primary, scope: scope)
            try file.commitDispatchPermit(root: prompt.id, sessionID: primary)
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
