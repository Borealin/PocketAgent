import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Summaries that end at a safe cut inside a root: repair-equivalent cuts,
/// exact raw continuation, bounded progress through one huge root, typed
/// refusals, validation of stored records, and the request-time exclusion
/// of fragments whose summary a forget invalidated.
struct PartialCoverageTests {
    typealias Fixture = ContextBuilderTests.Fixture

    // MARK: Safe cuts

    /// Every cut `internalCuts` accepts gives the same repair as the whole
    /// segment (messages and synthetic IDs), over random segments with reused
    /// call IDs, own, foreign, duplicate, detached and orphan results,
    /// unanswered calls and results without an ID.
    @Test func everyAcceptedCutRepairsLikeTheWholeSegment() {
        var rng = SplitMix(state: 0x5EED_CAFE)
        var cuts = 0, uncuttable = 0
        for _ in 0..<2_000 {
            let messages = randomSegment(&rng)
            let whole = AssistantContext.repaired(messages)
            let accepted = AssistantContext.internalCuts(messages)
            if accepted.isEmpty, messages.count > 1 { uncuttable += 1 }
            for cut in accepted {
                let left = AssistantContext.repaired(Array(messages[..<cut]))
                let right = AssistantContext.repaired(Array(messages[cut...]))
                #expect(left.messages + right.messages == whole.messages)
                #expect(left.synthetic.union(right.synthetic) == whole.synthetic)
                cuts += 1
            }
        }
        #expect(cuts > 2_000 && uncuttable > 0)
    }

    /// A detached result (outside the run right after its call) is kept by the
    /// whole segment's repair only because its call is in the same array: the
    /// segment has no internal cut, since one would drop it.
    @Test func aDetachedResultMakesItsSegmentUncuttable() {
        let call = AgentToolCall(id: "b", name: "wait", arguments: .object([:]))
        let messages = [AgentTranscriptMessage(role: .user, text: "p"),
                        AgentTranscriptMessage(role: .assistant, toolCalls: [call]),
                        AgentTranscriptMessage(role: .user, text: "steer"),
                        AgentTranscriptMessage(role: .tool, text: "late", toolCallID: "b", toolName: "wait")]
        #expect(AssistantContext.internalCuts(messages).isEmpty)
        let split = AssistantContext.repaired(Array(messages[..<2])).messages + AssistantContext.repaired(Array(messages[2...])).messages
        #expect(split != AssistantContext.repaired(messages).messages)
        // Reused IDs in separate complete groups do not block.
        let again = [messages[0], messages[1], AgentTranscriptMessage(role: .tool, text: "r", toolCallID: "b", toolName: "wait"),
                     AgentTranscriptMessage(role: .assistant, toolCalls: [call]),
                     AgentTranscriptMessage(role: .tool, text: "r2", toolCallID: "b", toolName: "wait")]
        #expect(AssistantContext.internalCuts(again) == [1, 3])
    }

    // MARK: Progress through one huge root

    /// One huge root is the only old root: each turn folds a bounded prefix of
    /// whole groups (at most three folds) through the real maintenance, the
    /// coverage only grows and always ends at a safe cut, and at the end the
    /// chain's sources plus the raw history are exactly the eligible messages.
    @MainActor
    @Test func oneHugeRootIsFoldedInBoundedSteps() async throws {
        var fixture = Fixture()
        _ = try fixture.longTurn("PKATEST_E 大任务", groups: 60, result: String(repeating: "屏", count: 200))
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 4_000))
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let turn = SummaryMaintenance.Turn(sessionID: fixture.primary, promptID: prompt.id, scope: .general, budget: budget,
                                           estimator: ContextEstimator(), summaryModel: "m")
        var covered = 0, turns = 0
        while let plan = AssistantContext.build(Self.input(owner.file, fixture.primary, prompt, budget)).plan {
            #expect(plan.folds.count <= AssistantContext.maxFolds && plan.blocked == nil)
            try await SummaryMaintenance.run(plan, turn: turn, owner: owner, producer: Self.summarizer(),
                                             deadline: MaintenanceDeadline(turnRemaining: 600))
            let segments = AssistantContext.eligibleSegments(owner.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
            let tip = try #require(AssistantContext.validTip(owner.file, sessionID: fixture.primary, scope: .general, segments: segments))
            #expect(tip.covered > covered && AssistantContext.safeCuts(segments).contains(tip.covered))
            #expect(segments.flatMap(\.messages)[tip.covered].role != .tool)
            covered = tip.covered; turns += 1
            if turns > 40 { Issue.record("no convergence"); break }
        }
        #expect(turns >= 3)
        let final = AssistantContext.build(Self.input(owner.file, fixture.primary, prompt, budget))
        let eligible = AssistantContext.eligibleSegments(owner.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
            .flatMap(\.messages).map(\.id)
        #expect(Self.chainSources(owner.file) + final.messages.map(\.id).filter { !final.syntheticIDs.contains($0) } == eligible)
        // The partly covered root is raw and summarized at once; its raw part
        // depends on the summary.
        #expect(final.rawRoots == final.summaryRoots && !final.partialSuffix.isEmpty)
    }

    /// An indivisible group larger than the fold window: the folds before it
    /// commit, then the next turn reports the block and keeps the group and
    /// everything after it raw.
    @MainActor
    @Test func anOversizedGroupIsReportedAndStaysRaw() async throws {
        var fixture = Fixture()
        let normal = String(repeating: "长", count: 150), huge = String(repeating: "巨", count: 400)
        let roots = try [normal, huge, normal, normal, normal].enumerated().map {
            try fixture.turn("PKATEST_E 第\($0.offset)轮", reply: $0.element)
        }
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 1_000))
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let plan = try #require(AssistantContext.build(Self.input(owner.file, fixture.primary, prompt, budget)).plan)
        #expect(plan.blocked != nil)
        try await SummaryMaintenance.run(plan, turn: .init(sessionID: fixture.primary, promptID: prompt.id, scope: .general,
                                                          budget: budget, estimator: ContextEstimator(), summaryModel: "m"),
                                         owner: owner, producer: Self.summarizer(), deadline: MaintenanceDeadline(turnRemaining: 600))
        let next = AssistantContext.build(Self.input(owner.file, fixture.primary, prompt, budget))
        let reply = try #require(owner.file.segment(root: roots[1], in: fixture.primary).last)
        #expect(next.plan == nil && next.messages.contains(reply))
        guard case .oversizedGroup(let first, _, _)? = next.refusal else { Issue.record("expected the block"); return }
        #expect(first == reply.id && next.refusal?.note.contains("未截断、未跳过") == true)
    }

    /// The only thing left after the summary is one indivisible group larger
    /// than any fold window (the start of its root already folded): it is
    /// the recent tail, stays raw and unsplit, and the block is reported.
    @Test func aLoneOversizedRecentGroupIsReported() throws {
        var fixture = Fixture()
        let root = try fixture.turn("PKATEST_E 大回复", reply: String(repeating: "巨", count: 400))
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        try fixture.file.commitSummary(try fixture.candidate(covering: [ContextSegment(root: root, messages: [segments[0].messages[0]])],
                                                             predecessor: nil))
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 1_000))
        let built = AssistantContext.build(Self.input(fixture.file, fixture.primary, prompt, budget))
        #expect(built.estimatedTokens > budget.summaryTrigger && built.plan == nil)
        #expect(built.messages.contains(segments[0].messages[1]))
        guard case .oversizedGroup(let first, let estimate, let limit)? = built.refusal else { Issue.record("expected the block"); return }
        #expect(first == segments[0].messages[1].id && estimate > limit)
    }

    // MARK: Budgets

    /// The recent tail and the first fold use the turn's calibrated estimate:
    /// at factors 0.5, 1 and 2 the kept tail is within the recent target (or
    /// one unit), a higher factor keeps less, and the first fold's actual
    /// request passes the dispatch check.
    @Test(arguments: [4_000, 12_000])
    func calibrationAppliesToTailAndFirstFold(ceiling: Int) throws {
        var fixture = Fixture()
        for n in 0..<14 { _ = try fixture.turn("PKATEST_E 第\(n)轮", reply: String(repeating: "长", count: ceiling / 24)) }
        _ = try fixture.longTurn("PKATEST_E 尾", groups: 12, result: String(repeating: "屏", count: ceiling / 40))
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: ceiling))
        let eligible = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
            .flatMap(\.messages)
        var kept: [Double: Int] = [:]
        for factor in [0.5, 1, 2] {
            let estimator = ContextEstimator(calibration: factor)
            var input = Self.input(fixture.file, fixture.primary, prompt, budget)
            input.estimator = estimator
            let plan = try #require(AssistantContext.build(input).plan, "factor \(factor)")
            let tail = eligible.suffix(plan.recentMessages)
            let tailTokens = tail.reduce(0) { $0 + ContextEstimator.messageTokens($1) }
            #expect(estimator.calibrated(tailTokens) <= budget.recentTarget || plan.recentMessages <= 2, "factor \(factor)")
            kept[factor] = plan.recentMessages
            let first = try #require(plan.folds.first)
            let request = SummaryRequest.make(messages: first.flatMap(\.messages), previous: nil)
            #expect(estimator.estimate(request) <= budget.target, "factor \(factor)")
        }
        #expect(kept[2]! < kept[0.5]!)
    }

    /// A previous summary above the 60% window is not an impossible request
    /// by itself: a small group that fits the whole target is still folded.
    /// Only a summary that fills the target, or a group the remaining room
    /// cannot take, is refused, each as what it is.
    @Test func aLargePreviousSummaryNarrowsTheFoldInsteadOfForbiddingIt() throws {
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 4_000))
        let overhead = ContextEstimator().estimate(SummaryRequest.make(messages: [], previous: ""))
        func plan(previousShare: Double) throws -> PreparedContext {
            var fixture = Fixture()
            // Long prompts: the first unit of each older root is large.
            for n in 0..<4 { _ = try fixture.turn("PKATEST_E 第\(n)轮" + String(repeating: "问", count: 300), reply: "好") }
            let prompt = AgentTranscriptMessage(role: .user, text: "当前")
            try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
            let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
            let tokens = max(0, Int(Double(budget.target) * previousShare) - overhead)
            let previous = try fixture.candidate(covering: [segments[0]], predecessor: nil,
                                                 summary: "## Goal\n" + String(repeating: "摘", count: tokens / 2))
            try fixture.file.commitSummary(previous)
            return AssistantContext.build(Self.input(fixture.file, fixture.primary, prompt, budget))
        }
        let narrowed = try plan(previousShare: 0.65)
        let fold = try #require(narrowed.plan?.folds.first)
        #expect(fold.count == 1 && narrowed.refusal == nil)
        let request = SummaryRequest.make(messages: fold.flatMap(\.messages), previous: narrowed.plan?.predecessor?.record.summary)
        #expect(ContextEstimator().estimate(request) <= budget.target)
        guard case .previousSummaryLeavesNoRoom(let estimate, let room)? = try plan(previousShare: 0.9).refusal else {
            Issue.record("expected no room beside the previous summary"); return
        }
        #expect(estimate > room && estimate <= budget.target * 60 / 100)
        guard case .previousSummaryTooLarge? = try plan(previousShare: 1.05).refusal else {
            Issue.record("expected the previous summary alone to be too large"); return
        }
    }

    // MARK: Stored records

    /// Records ending at an unsafe cut with valid digests (a root record, a
    /// child and a checkpoint) are never valid: validTip ignores them, build
    /// sends raw history instead, commit refuses them.
    @Test func recordsEndingAtAnUnsafeCutAreRejected() throws {
        var fixture = Fixture()
        let root = try fixture.longTurn("PKATEST_E 任务", groups: 3, result: "r")
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        let messages = segments[0].messages
        #expect(messages[2].role == .tool)  // [prompt, call, result, ...]: 2 is unsafe, 3 is safe
        let unsafe = try fixture.candidate(covering: [ContextSegment(root: root, messages: Array(messages[..<2]))], predecessor: nil)
        let safe = try fixture.candidate(covering: [ContextSegment(root: root, messages: Array(messages[..<3]))], predecessor: nil)
        let child = try fixture.candidate(covering: [ContextSegment(root: root, messages: [messages[3]])], predecessor: safe)
        let checkpoint = try Self.forgedCheckpoint(basis: unsafe, prefix: Array(messages[..<2]), fixture)
        func tip(_ records: [StoredCompaction]) -> SummaryTip? {
            var file = fixture.file
            file.assistant.compactions = records
            return AssistantContext.validTip(file, sessionID: fixture.primary, scope: .general, segments: segments)
        }
        #expect(tip([unsafe]) == nil && tip([unsafe, checkpoint]) == nil)
        #expect(tip([safe])?.covered == 3 && tip([safe, child])?.tip.id == safe.id)
        var file = fixture.file
        file.assistant.compactions = [unsafe]
        #expect(AssistantContext.build(Self.input(file, fixture.primary, prompt, .unknown)).summaryID == nil)
        var committing = fixture.file
        #expect(throws: SummaryPreparationError.self) { try committing.commitSummary(unsafe) }
        try committing.commitSummary(safe)
        #expect(throws: SummaryPreparationError.self) { try committing.commitSummary(child) }
    }

    /// A checkpoint re-roots a chain whose tip ends inside a root and keeps that partial coverage.
    @Test func aCheckpointKeepsPartialCoverage() throws {
        var fixture = Fixture()
        let root = try fixture.longTurn("PKATEST_E 任务", groups: 3, result: "r")
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        // A two-record chain ending inside the root (positions 3 and 5 are safe cuts).
        let first = try fixture.candidate(covering: [ContextSegment(root: root, messages: Array(segments[0].messages[..<3]))],
                                          predecessor: nil)
        try fixture.file.commitSummary(first)
        let tip = try fixture.candidate(covering: [ContextSegment(root: root, messages: Array(segments[0].messages[3..<5]))],
                                        predecessor: first)
        try fixture.file.commitSummary(tip)
        let checkpoint = try AssistantContext.checkpoint(of: tip, in: fixture.file, forgetEpoch: 0)
        try fixture.file.commitSummary(checkpoint)
        let valid = try #require(AssistantContext.validTip(fixture.file, sessionID: fixture.primary, scope: .general, segments: segments))
        #expect(valid.tip.id == checkpoint.id && valid.covered == 5 && valid.depth == 1)
        #expect(checkpoint.sourceRootPromptIDs == [root])
    }

    /// Summaries of another builder version stay in the file but are unused:
    /// history is all raw, nothing is lost, and a forget preview does not count
    /// them as newly invalidated.
    @Test func otherVersionSummariesAreIgnoredAndNotCounted() throws {
        var fixture = Fixture()
        let first = try fixture.turn("PKATEST_E 第一轮")
        _ = try fixture.turn("PKATEST_E 第二轮")
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        _ = try fixture.file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_E 记忆", origin: .command,
                                                  sourceRootPromptIDs: [], sourceMessageIDs: []))
        let entry = try #require(fixture.file.assistant.memory.active.last)
        try fixture.file.registerReads(root: first, memory: [MemoryReadRevision(entryID: entry.id, revision: entry.revision)],
                                       roots: [], messages: [])
        var current = try fixture.candidate(covering: [segments[0]], predecessor: nil)
        var file = fixture.file
        file.assistant.compactions = [current]
        #expect(try file.forgetPreview([entry.id], activeRoot: nil).affectedSummaries == 1)
        current.builderVersion = 1
        file.assistant.compactions = [current]
        #expect(try file.forgetPreview([entry.id], activeRoot: nil).affectedSummaries == 0)
        let built = AssistantContext.build(Self.input(file, fixture.primary, prompt, .unknown))
        #expect(built.summaryID == nil && built.messages.map(\.id) == segments.flatMap(\.messages).map(\.id))
        #expect(file.assistant.compactions.count == 1)
    }

    // MARK: Maintenance checks

    /// Two runs of one interleaved root in one fold: the record and the reads
    /// list each root once, in order, and the commit succeeds.
    @MainActor
    @Test func aFoldOverInterleavedRootsListsEachRootOnce() async throws {
        var fixture = Fixture()
        let (a, b) = try fixture.interleaved()
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        #expect(segments.map(\.root) == [a, b, a])
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        try await SummaryMaintenance.run(SummaryPlan(sessionID: fixture.primary, scope: .general, predecessor: nil, folds: [segments]),
                                         turn: .init(sessionID: fixture.primary, promptID: prompt.id, scope: .general,
                                                     budget: .unknown, estimator: ContextEstimator(), summaryModel: "m"),
                                         owner: owner, producer: Self.summarizer(), deadline: MaintenanceDeadline(turnRemaining: 600))
        #expect(owner.file.assistant.compactions.map(\.sourceRootPromptIDs) == [[a, b]])
        #expect(owner.file.assistant.scopeIndex.scopedRoot(prompt.id)?.dependencies.rootReads == [a, b])
    }

    /// A fold must be exactly the eligible messages right after the current
    /// coverage: skipping ahead, an edited source or a message inserted inside
    /// it is refused before any dispatch. (A message appended after its end
    /// leaves it an exact slice ending at a safe cut: still valid.)
    @MainActor
    @Test func aFoldThatIsNotTheExactNextSliceIsRefused() async throws {
        for change in ["skip", "edit", "insert"] {
            var fixture = Fixture()
            _ = try fixture.turn("PKATEST_E 第一轮")
            let second = try fixture.turn("PKATEST_E 第二轮")
            let prompt = AgentTranscriptMessage(role: .user, text: "当前")
            try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
            let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
            let folds = change == "skip" ? [[segments[1]]] : [[segments[0], segments[1]]]
            switch change {
            case "edit":
                var edited = segments[1].messages[1]
                edited.text = "改写"
                try fixture.file.appendEvent(edited, to: fixture.primary, root: second)
            case "insert":
                try fixture.file.appendEvent(AgentTranscriptMessage(role: .user, text: "插入"), to: fixture.primary, root: second,
                                             before: [segments[1].messages[1].id])
            default: break
            }
            let owner = HistoryOwner(file: fixture.file, writer: { _ in })
            let calls = SummaryCalls()
            await #expect(throws: SummaryPreparationError.self, "\(change)") {
                try await SummaryMaintenance.run(SummaryPlan(sessionID: fixture.primary, scope: .general, predecessor: nil, folds: folds),
                                                 turn: .init(sessionID: fixture.primary, promptID: prompt.id, scope: .general,
                                                             budget: .unknown, estimator: ContextEstimator(), summaryModel: "m"),
                                                 owner: owner, producer: Self.summarizer(calls),
                                                 deadline: MaintenanceDeadline(turnRemaining: 600))
            }
            #expect(calls.count == 0 && owner.file.assistant.compactions.isEmpty, "\(change)")
        }
    }

    /// Positive control: a message appended to a root after the fold's end
    /// leaves the fold an exact slice ending at a safe cut; it commits and the
    /// new message stays raw after the summary.
    @MainActor
    @Test func aMessageAppendedAfterTheFoldKeepsItValid() async throws {
        var fixture = Fixture()
        _ = try fixture.turn("PKATEST_E 第一轮")
        let second = try fixture.turn("PKATEST_E 第二轮")
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        let late = AgentTranscriptMessage(role: .assistant, text: "迟到")
        // After the fold's end, still before the current prompt.
        try fixture.file.appendEvent(late, to: fixture.primary, root: second, before: [prompt.id])
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        try await SummaryMaintenance.run(SummaryPlan(sessionID: fixture.primary, scope: .general, predecessor: nil,
                                                     folds: [[segments[0], segments[1]]]),
                                         turn: .init(sessionID: fixture.primary, promptID: prompt.id, scope: .general,
                                                     budget: .unknown, estimator: ContextEstimator(), summaryModel: "m"),
                                         owner: owner, producer: Self.summarizer(), deadline: MaintenanceDeadline(turnRemaining: 600))
        let built = AssistantContext.build(Self.input(owner.file, fixture.primary, prompt, .unknown))
        #expect(owner.file.assistant.compactions.count == 1 && built.summaryID != nil)
        #expect(built.messages.map(\.id).contains(late.id) && built.partialSuffix.contains(late.id))
    }

    // MARK: Forget at request time

    /// A forget of a covered root after the context was built invalidates the
    /// summary: the request also drops every raw fragment of roots that
    /// summary covered (inside a root, and the later run of an interleaved
    /// root), keeps the prompt, registers none of them as read, and reports
    /// the exclusion once.
    @MainActor
    @Test(arguments: ["internalCut", "interleaved"])
    func aForgetDropsTheSummaryWithItsDependentFragments(shape: String) throws {
        var fixture = Fixture()
        let forgotten: UUID, dependent: UUID, covering: [ContextSegment]
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        if shape == "internalCut" {
            forgotten = try fixture.turn("PKATEST_E 第一轮")
            dependent = try fixture.longTurn("PKATEST_E 任务", groups: 3, result: "r")
            try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
            let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
            covering = [segments[0], ContextSegment(root: dependent, messages: Array(segments[1].messages[..<3]))]
        } else {
            let pair = try fixture.interleaved()
            dependent = pair.a; forgotten = pair.b
            try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
            let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
            covering = [segments[0], segments[1]]
        }
        try fixture.file.commitSummary(try fixture.candidate(covering: covering, predecessor: nil))
        let prepared = AssistantContext.build(Self.input(fixture.file, fixture.primary, prompt, .unknown))
        let fragment = fixture.file.segment(root: dependent, in: fixture.primary).filter { prepared.messages.map(\.id).contains($0.id) }
        #expect(prepared.summaryID != nil && !fragment.isEmpty && prepared.partialSuffix == Set(fragment.map(\.id)))
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let preparer = AssistantRequestPreparer(owner: owner, sessionID: fixture.primary, promptID: prompt.id, scope: .general,
                                                budget: .unknown, estimator: { ContextEstimator() })
        preparer.rawRoots = prepared.rawRoots
        preparer.summaryRoots = prepared.summaryRoots
        preparer.summaryMessageID = owner.file.assistant.compactions.first?.record.summaryMessageID
        preparer.partialSuffix = prepared.partialSuffix
        var reported: [Int] = []
        preparer.onExclusion = { reported.append($0) }
        try owner.transact { try $0.assistant.scopeIndex.mask(root: forgotten, by: UUID()) }
        let request = AgentModelRequest(systemPrompt: "s", messages: prepared.messages + [prompt], tools: [])
        let sent = try preparer.prepare(request).messages.map(\.id)
        _ = try preparer.prepare(request)
        #expect(sent == [prompt.id])
        #expect(reported == [fragment.count])
        let reads = owner.file.assistant.scopeIndex.scopedRoot(prompt.id)?.dependencies.rootReads ?? []
        #expect(!reads.contains(dependent) && !reads.contains(forgotten))
    }

    // MARK: Helpers

    static func input(_ file: HistoryFile, _ session: UUID, _ prompt: AgentTranscriptMessage,
                      _ budget: ContextBudgetPolicy) -> AssistantContext.Input {
        .init(file: file, sessionID: session, promptID: prompt.id, scope: .general, references: [], budget: budget,
              estimator: ContextEstimator(), systemPrompt: "s", tools: [], prompt: [prompt])
    }

    static func summarizer(_ calls: SummaryCalls = SummaryCalls()) -> StreamingSummary.Producer {
        { _, onEvent in
            let n = calls.next()
            try onEvent(.textDelta("## Goal\n第\(n)段摘要"))
            try onEvent(.finished(.completed))
        }
    }

    /// Source IDs of the valid chain, oldest first.
    static func chainSources(_ file: HistoryFile) -> [UUID] {
        let byID = Dictionary(file.assistant.compactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let primary = file.primary,
              let tip = AssistantContext.validTip(file, sessionID: primary.id, scope: .general,
                                                  segments: AssistantContext.eligibleSegments(file, sessionID: primary.id,
                                                                                              before: UUID(), scope: .general))
        else { return [] }
        var ids: [UUID] = []
        var record: StoredCompaction? = tip.tip
        while let current = record {
            ids = current.sourceMessageIDs + ids
            record = current.builderVersion == AssistantContext.checkpointBuilderVersion ? nil
                : current.predecessorID.flatMap { byID[$0] }
        }
        return ids
    }

    /// A checkpoint over `basis` built like `AssistantContext.checkpoint`,
    /// without its validity precondition (digests valid, coverage as given).
    static func forgedCheckpoint(basis: StoredCompaction, prefix: [AgentTranscriptMessage], _ fixture: Fixture) throws -> StoredCompaction {
        let roots = AssistantContext.roots(of: prefix, index: fixture.file.assistant.scopeIndex)
        let receipt = try AssistantContext.checkpointReceipt(prefix: prefix, roots: roots, attachments: fixture.file.primary?.attachments ?? [:],
                                                             scope: .general, basis: basis)
        let record = AgentCompactionRecord(summaryMessageID: UUID(), compactedThroughMessageID: basis.record.compactedThroughMessageID,
                                           sequence: basis.record.sequence + 1, summary: basis.record.summary,
                                           summarizedTokens: 1, keptTokens: 0, displayAnchor: basis.record.displayAnchor)
        let ids = prefix.map(\.id)
        return StoredCompaction(id: record.id, record: record, sessionID: fixture.primary, scope: .general,
                                sourceRootPromptIDs: roots, sourceMessageIDs: ids, predecessorID: basis.id,
                                predecessorDigest: basis.recordDigest, inputDigest: receipt,
                                recordDigest: try AssistantContext.recordDigest(inputDigest: receipt, record: record, sourceIDs: ids,
                                                                                parentRecordDigest: basis.recordDigest),
                                builderVersion: AssistantContext.checkpointBuilderVersion,
                                summaryPromptVersion: AssistantContext.summaryPromptVersion, forgetEpoch: 0, summaryModel: "m")
    }
}

final class SummaryCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

extension ContextBuilderTests.Fixture {
    /// A started root with `groups` call/result groups and a final reply.
    @discardableResult
    mutating func longTurn(_ text: String, groups: Int, result: String) throws -> UUID {
        let prompt = AgentTranscriptMessage(role: .user, text: text)
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .general)
        try file.commitDispatchPermit(root: prompt.id, sessionID: primary, scope: .general)
        for n in 0..<groups {
            let call = AgentToolCall(id: "w\(n)", name: "wait", arguments: .object([:]))
            try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "第\(n)步", toolCalls: [call]), to: primary, root: prompt.id)
            try file.appendEvent(AgentTranscriptMessage(role: .tool, text: result, toolCallID: call.id, toolName: call.name),
                                 to: primary, root: prompt.id)
        }
        try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "完成"), to: primary, root: prompt.id)
        return prompt.id
    }

    /// Root A, then root B, then a late message of A: segments A, B, A.
    mutating func interleaved() throws -> (a: UUID, b: UUID) {
        let a = try turn("PKATEST_E 甲")
        let b = try turn("PKATEST_E 乙")
        try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "甲的迟到回复"), to: primary, root: a)
        return (a, b)
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A prompt, then steering, text, calls (IDs from a small reused pool) and
/// results (own, foreign, duplicate, detached, orphan, or without an ID).
private func randomSegment(_ rng: inout SplitMix) -> [AgentTranscriptMessage] {
    let pool = ["a", "b", "c"]
    var messages = [AgentTranscriptMessage(role: .user, text: "p")]
    for _ in 0..<Int.random(in: 1...11, using: &rng) {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: messages.append(AgentTranscriptMessage(role: .user, text: "s"))
        case 1: messages.append(AgentTranscriptMessage(role: .assistant, text: "t"))
        case 2, 3:
            let calls = (0..<Int.random(in: 1...2, using: &rng)).map { _ in
                AgentToolCall(id: pool[Int.random(in: 0..<3, using: &rng)], name: "wait", arguments: .object([:]))
            }
            messages.append(AgentTranscriptMessage(role: .assistant, toolCalls: calls))
        default:
            let pick = Int.random(in: 0..<5, using: &rng)
            messages.append(AgentTranscriptMessage(role: .tool, text: "r", toolCallID: pick < 3 ? pool[pick] : pick == 3 ? "z" : nil,
                                                   toolName: "wait"))
        }
    }
    return messages
}
