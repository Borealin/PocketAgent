import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

private final class FoldCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var previous: [String] = []
    var count: Int { lock.withLock { value } }
    /// The previous summary each fold request carried.
    var carried: [String] { lock.withLock { previous } }
    func next(_ request: AgentModelRequest) -> Int {
        let text = request.messages.map(\.text).joined(separator: "\n")
        return lock.withLock { value += 1; previous.append(text); return value }
    }
}

private struct FoldFailed: Error {}

/// Summary chains at the 128-record depth limit: the valid tip is re-rooted
/// by a host-only checkpoint (no model request, same summary, full prefix
/// coverage and all roots, parent kept as evidence), then folds continue.
/// Replaces the local probe that showed every later turn re-planning on the
/// 128-deep tip and every 129th commit being rejected. Fixtures are built
/// off the main actor; only the owner and maintenance run on it.
struct SummaryChainDepthTests {
    typealias Fixture = ContextBuilderTests.Fixture

    private struct Chain: Sendable {
        var fixture: Fixture
        var prompt: UUID
        var segments: [ContextSegment]
        var records: [StoredCompaction]
    }

    /// `turns` finished rounds, a chain of single-round records over the first
    /// `depth` of them, and the current (not yet started) prompt.
    private static func makeChain(turns: Int, depth: Int, reply: String? = nil) throws -> Chain {
        var fixture = Fixture()
        for n in 0..<turns { _ = try fixture.turn("PKATEST_GAPS_第\(n)轮", reply: reply) }
        let prompt = AgentTranscriptMessage(role: .user, text: "当前")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        let segments = AssistantContext.eligibleSegments(fixture.file, sessionID: fixture.primary, before: prompt.id, scope: .general)
        var records: [StoredCompaction] = []
        for n in 0..<depth {
            records.append(try fixture.candidate(covering: [segments[n]], predecessor: records.last, summary: "## Goal\n第\(n + 1)段摘要"))
        }
        fixture.file.assistant.compactions = records
        return Chain(fixture: fixture, prompt: prompt.id, segments: segments, records: records)
    }

    static let longReply = String(repeating: "长", count: 150)

    /// Built once and shared (parallel tests rebuilding it would starve the
    /// executor): 133 rounds with ~300-token replies, records r1…r129 over
    /// the first 129 and the current prompt.
    private static let shared = Result { try makeChain(turns: 133, depth: 129, reply: longReply) }

    /// The shared history with only r1…r`depth`; off the main actor.
    private func chain(depth: Int) async throws -> Chain {
        var built = try Self.shared.get()
        built.records = Array(built.records.prefix(depth))
        built.fixture.file.assistant.compactions = built.records
        return built
    }

    private func tip(_ file: HistoryFile, _ chain: Chain) -> SummaryTip? {
        AssistantContext.validTip(file, sessionID: chain.fixture.primary, scope: .general,
            eligible: AssistantContext.eligibleSegments(file, sessionID: chain.fixture.primary, before: UUID(), scope: .general)
                .flatMap(\.messages))
    }

    private func covered(_ chain: Chain, _ segments: Int) -> Int {
        chain.segments.prefix(segments).reduce(0) { $0 + $1.messages.count }
    }

    /// The plan the builder would make: the current valid tip and its depth.
    private func plan(_ chain: Chain, file: HistoryFile, folds: [[ContextSegment]]) throws -> SummaryPlan {
        let valid = try #require(tip(file, chain))
        return SummaryPlan(sessionID: chain.fixture.primary, scope: .general, predecessor: valid.tip, folds: folds,
                           predecessorDepth: valid.depth)
    }

    @MainActor
    private func run(_ plan: SummaryPlan, _ chain: Chain, owner: HistoryOwner, calls: FoldCalls,
                     onCall: @escaping @Sendable (Int) async throws -> Void = { _ in }) async throws {
        try await SummaryMaintenance.run(
            plan, turn: .init(sessionID: chain.fixture.primary, promptID: chain.prompt, scope: .general, budget: .unknown,
                              estimator: ContextEstimator(), summaryModel: "m"),
            owner: owner,
            producer: { request, onEvent in
                let call = calls.next(request)
                try await onCall(call)
                try onEvent(.textDelta("## Goal\n续写第\(call)段摘要"))
                try onEvent(.finished(.completed))
            },
            deadline: MaintenanceDeadline(turnRemaining: 600))
    }

    // MARK: Boundaries

    @Test func chainsUpTo128RecordsAreValidAndTheNextRecordIsNot() async throws {
        let built = try await chain(depth: 129)
        for depth in [127, 128, 129] {
            var file = built.fixture.file
            file.assistant.compactions = Array(built.records.prefix(depth))
            let valid = try #require(tip(file, built))
            let expected = min(depth, AssistantContext.maxChainDepth)
            #expect(valid.tip.id == built.records[expected - 1].id && valid.depth == expected)
            #expect(valid.covered == covered(built, expected))
        }
    }

    @MainActor
    @Test(arguments: [(127, 1, false), (128, 1, true), (129, 1, true), (125, 3, false), (126, 3, true)])
    func foldsPastTheLimitCheckpointTheTipFirst(records: Int, folds: Int, checkpoints: Bool) async throws {
        let built = try await chain(depth: records)
        let start = min(records, AssistantContext.maxChainDepth)
        let plan = try plan(built, file: built.fixture.file, folds: (0..<folds).map { [built.segments[start + $0]] })
        let basis = try #require(plan.predecessor)
        #expect(plan.predecessorDepth == start && basis.id == built.records[start - 1].id)
        let owner = HistoryOwner(file: built.fixture.file, writer: { _ in })
        let calls = FoldCalls()
        try await run(plan, built, owner: owner, calls: calls)
        #expect(calls.count == folds)
        let added = owner.file.assistant.compactions.dropFirst(records)
        #expect(added.count == folds + (checkpoints ? 1 : 0))
        let valid = try #require(tip(owner.file, built))
        #expect(valid.covered == covered(built, start + folds))
        #expect(valid.depth == (checkpoints ? 1 + folds : start + folds))
        // Every fold request carried the tip's summary, never the raw prefix.
        #expect(calls.carried.allSatisfy { !$0.contains("PKATEST_GAPS_第0轮") })
        #expect(calls.carried.first?.contains(basis.record.summary) == true)
        guard checkpoints, let checkpoint = added.first else { return }
        // Same summary, whole prefix, every covered root, the tip kept as parent evidence.
        #expect(checkpoint.record.summary == basis.record.summary && checkpoint.predecessorID == basis.id)
        #expect(checkpoint.predecessorDigest == basis.recordDigest)
        #expect(checkpoint.sourceMessageIDs == built.segments.prefix(start).flatMap { $0.messages.map(\.id) })
        #expect(Set(checkpoint.sourceRootPromptIDs) == Set(built.segments.prefix(start).map(\.root)))
        #expect(owner.file.assistant.compactions.prefix(records).map(\.id) == built.records.map(\.id))
        // The next context reads every covered root through the new tip.
        let next = AssistantContext.build(built.fixture.input(prompt: built.prompt).with(file: owner.file))
        #expect(next.summaryID == valid.tip.id && Set(next.summaryRoots) == Set(built.segments.prefix(start + folds).map(\.root)))
    }

    /// The probe's scenario as a regression: after the checkpoint, the next
    /// turn extends the new short chain instead of re-planning on the 128 tip.
    @MainActor
    @Test func laterTurnsContinueFromTheCheckpointedChain() async throws {
        let built = try await chain(depth: 128)
        let owner = HistoryOwner(file: built.fixture.file, writer: { _ in })
        let calls = FoldCalls()
        try await run(try plan(built, file: owner.file, folds: [[built.segments[128]]]), built, owner: owner, calls: calls)
        let second = try plan(built, file: owner.file, folds: [[built.segments[129]], [built.segments[130]]])
        #expect(second.predecessorDepth == 2)
        try await run(second, built, owner: owner, calls: calls)
        let valid = try #require(tip(owner.file, built))
        #expect(calls.count == 3 && valid.depth == 4 && valid.covered == covered(built, 131))
        #expect(owner.file.assistant.compactions.count == 128 + 1 + 3)
    }

    /// The builder plans with the tip's depth, and a remainder needing more
    /// than three folds starts with its oldest three instead of never.
    @Test func theBuilderPlansTheOldestThreeFoldsWithTheTipDepth() async throws {
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 1_000))
        for depth in [0, 128] {
            let built = depth == 0 ? try Self.makeChain(turns: 8, depth: 0, reply: Self.longReply) : try await chain(depth: depth)
            let plan = try #require(AssistantContext.build(built.fixture.input(prompt: built.prompt, budget: budget)).plan)
            #expect(plan.predecessorDepth == depth && plan.predecessor?.id == built.records.last?.id)
            #expect(plan.folds.count == AssistantContext.maxFolds)
            #expect(plan.folds.flatMap { $0.map(\.root) } == Array(built.segments[depth..<depth + plan.folds.joined().count].map(\.root)))
        }
    }

    /// A segment larger than one summarizer input is never split: the plan
    /// folds what comes before it; with nothing before it there is no plan
    /// (a recorded boundary: raw context and the request ceiling still apply).
    @Test func anOversizedSegmentStopsThePlanBeforeIt() throws {
        let normal = String(repeating: "长", count: 150), huge = String(repeating: "巨", count: 400)
        let budget = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 1_000))
        for (replies, folded) in [([normal, huge, normal, normal, normal], 1), ([huge, normal, normal], 0)] {
            var fixture = Fixture()
            let roots = try replies.enumerated().map { try fixture.turn("PKATEST_GAPS_第\($0.offset)轮", reply: $0.element) }
            let prompt = AgentTranscriptMessage(role: .user, text: "当前")
            try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
            let built = AssistantContext.build(fixture.input(prompt: prompt.id, budget: budget))
            #expect(built.estimatedTokens > budget.summaryTrigger)
            #expect(built.plan?.folds.flatMap { $0.map(\.root) } == (folded == 0 ? nil : Array(roots.prefix(folded))))
        }
    }

    // MARK: Rebuild failures commit nothing

    @MainActor
    @Test func aChangedSourceOrAFailedWriteCommitsNoCheckpoint() async throws {
        let built = try await chain(depth: 128)
        let plan = try plan(built, file: built.fixture.file, folds: [[built.segments[128]]])
        // A synchronized rewrite of a covered message after planning.
        var rewritten = built.fixture.file
        try rewritten.editSession(built.fixture.primary) { session in
            let index = session.messages.firstIndex { $0.id == built.segments[5].messages[1].id }!
            session.messages[index].text = "PKATEST_GAPS_同步改写"
        }
        let changed = HistoryOwner(file: rewritten, writer: { _ in })
        let none = FoldCalls()
        await #expect(throws: SummaryPreparationError.self) { try await run(plan, built, owner: changed, calls: none) }
        #expect(none.count == 0 && changed.file.assistant.compactions == built.records)
        // The checkpoint's write fails: nothing published, the turn stops.
        let failing = HistoryOwner(file: built.fixture.file, writer: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        await #expect(throws: StorageCommitError.self) { try await run(plan, built, owner: failing, calls: none) }
        #expect(none.count == 0 && failing.file == built.fixture.file)
    }

    @MainActor
    @Test func aForgetBeforeOrDuringTheRebuildCommitsNothingMore() async throws {
        var built = try await chain(depth: 128)
        let receipt = try built.fixture.file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GAPS_第5轮的偏好",
            origin: .chatChip, sourceRootPromptIDs: [built.segments[5].root], sourceMessageIDs: []))
        let entry = try #require(receipt.entryIDs.first)
        let plan = try plan(built, file: built.fixture.file, folds: [[built.segments[128]]])
        let prompt = built.prompt
        let forget: @Sendable (inout HistoryFile) throws -> Void = { file in
            _ = try file.commitForget(try file.forgetPreview([entry], activeRoot: prompt), activeRoot: prompt)
        }
        // Before: the planned tip is no longer valid; no checkpoint, no fold.
        var forgotten = built.fixture.file
        try forget(&forgotten)
        let before = HistoryOwner(file: forgotten, writer: { _ in })
        let none = FoldCalls()
        await #expect(throws: SummaryPreparationError.self) { try await run(plan, built, owner: before, calls: none) }
        #expect(none.count == 0 && before.file.assistant.compactions == forgotten.assistant.compactions)
        // During the first fold after the checkpoint: the forget removes the
        // checkpoint (it lists every covered root) and the fold is discarded.
        let during = HistoryOwner(file: built.fixture.file, writer: { _ in })
        let one = FoldCalls()
        await #expect(throws: ContextSourceRevoked.self) {
            try await run(plan, built, owner: during, calls: one) { _ in
                try await MainActor.run { try during.transact { try forget(&$0) } }
            }
        }
        #expect(one.count == 1)
        let left = during.file.assistant.compactions
        #expect(left.count == 127 && !left.contains { $0.sourceRootPromptIDs.contains(built.segments[5].root) })
        #expect(tip(during.file, built)?.tip.id == built.records[4].id)
    }

    @MainActor
    @Test func aFailedFoldKeepsTheValidCheckpointForTheNextTurn() async throws {
        let built = try await chain(depth: 128)
        let owner = HistoryOwner(file: built.fixture.file, writer: { _ in })
        let calls = FoldCalls()
        await #expect(throws: (any Error).self) {
            try await run(try plan(built, file: owner.file, folds: [[built.segments[128]]]), built, owner: owner, calls: calls) { _ in
                throw FoldFailed()
            }
        }
        let valid = try #require(tip(owner.file, built))
        #expect(calls.count == 1 && owner.file.assistant.compactions.count == 129)
        #expect(valid.depth == 1 && valid.covered == covered(built, 128) && valid.tip.predecessorID == built.records[127].id)
    }

    // MARK: Checkpoint validity

    /// Re-seals a forged checkpoint so only the boundary under test can reject it.
    private func resealed(_ checkpoint: StoredCompaction, basis: StoredCompaction, prefix: [AgentTranscriptMessage],
                          roots: [UUID], in file: HistoryFile) throws -> StoredCompaction {
        var copy = checkpoint
        copy.sourceMessageIDs = prefix.map(\.id)
        copy.sourceRootPromptIDs = roots
        copy.record.compactedThroughMessageID = prefix.last?.id
        copy.predecessorID = basis.id
        copy.predecessorDigest = basis.recordDigest
        copy.inputDigest = try AssistantContext.checkpointReceipt(prefix: prefix, roots: AssistantContext.roots(of: prefix,
            index: file.assistant.scopeIndex), attachments: [:], scope: .general, basis: basis)
        copy.recordDigest = try AssistantContext.recordDigest(inputDigest: copy.inputDigest, record: copy.record,
                                                              sourceIDs: copy.sourceMessageIDs, parentRecordDigest: basis.recordDigest)
        return copy
    }

    @Test func aCheckpointIsValidOnlyWithItsEvidenceAndUnchangedSources() async throws {
        let built = try await chain(depth: 128)
        let basis = built.records[127]
        let checkpoint = try AssistantContext.checkpoint(of: basis, in: built.fixture.file, forgetEpoch: 0)
        #expect(checkpoint.builderVersion == AssistantContext.checkpointBuilderVersion)
        #expect(checkpoint.record.compactedThroughMessageID == basis.record.compactedThroughMessageID)
        var file = built.fixture.file
        try file.commitSummary(checkpoint)
        let at = file.assistant.compactions.count - 1
        let valid = try #require(tip(file, built))
        #expect(valid.tip.id == checkpoint.id && valid.depth == 1 && valid.covered == covered(built, 128))
        #expect(Set(AssistantContext.coverageRoots(checkpoint, in: file)) == Set(built.segments.prefix(128).map(\.root)))
        // Bounded: valid without walking the chain it re-rooted (its parent must stay).
        var bounded = file
        bounded.assistant.compactions.removeAll { built.records.prefix(127).map(\.id).contains($0.id) }
        #expect(tip(bounded, built)?.tip.id == checkpoint.id)
        let prefix128 = built.segments.prefix(128).flatMap(\.messages)
        let roots128 = built.segments.prefix(128).map(\.root)
        var cases: [(String, HistoryFile, Int?)] = []
        func variant(_ name: String, fallback: Int?, _ change: (inout HistoryFile) throws -> Void) rethrows {
            var copy = file
            try change(&copy)
            cases.append((name, copy, fallback))
        }
        // The copy itself.
        try variant("summary differs from the basis", fallback: 128) { $0.assistant.compactions[at].record.summary = "篡改" }
        try variant("basis missing", fallback: 127) { $0.assistant.compactions.removeAll { $0.id == basis.id } }
        try variant("parent digest of another record", fallback: 128) {
            $0.assistant.compactions[at].predecessorDigest = built.records[126].recordDigest
        }
        try variant("prefix without its first message", fallback: 128) { $0.assistant.compactions[at].sourceMessageIDs.removeFirst() }
        // A forged copy that also wraps a segment its basis never covered.
        try variant("extra unseen segment", fallback: 128) { copy in
            let extended = prefix128 + built.segments[128].messages
            copy.assistant.compactions[at] = try resealed(checkpoint, basis: basis, prefix: extended,
                                                         roots: roots128 + [built.segments[128].root], in: copy)
        }
        // Forget edges: phantom, missing and duplicated roots (receipt re-sealed).
        try variant("phantom root", fallback: 128) { copy in
            copy.assistant.compactions[at] = try resealed(checkpoint, basis: basis, prefix: prefix128, roots: roots128 + [UUID()], in: copy)
        }
        try variant("missing root", fallback: 128) { copy in
            copy.assistant.compactions[at] = try resealed(checkpoint, basis: basis, prefix: prefix128,
                                                         roots: Array(roots128.dropFirst()), in: copy)
        }
        try variant("duplicated root", fallback: 128) { copy in
            copy.assistant.compactions[at] = try resealed(checkpoint, basis: basis, prefix: prefix128,
                                                         roots: roots128 + [roots128[0]], in: copy)
        }
        // The basis body no longer yields its record digest.
        try variant("basis input digest", fallback: 127) { $0.assistant.compactions[127].inputDigest = "forged" }
        try variant("basis source IDs", fallback: 127) { copy in
            copy.assistant.compactions[127].sourceMessageIDs = built.segments[126].messages.map(\.id)
        }
        try variant("basis summary with the copy's", fallback: 127) { copy in
            copy.assistant.compactions[127].record.summary = "篡改"
            copy.assistant.compactions[at].record.summary = "篡改"
        }
        // Sources and cycles.
        try variant("covered message rewritten", fallback: 100) { copy in
            try copy.editSession(built.fixture.primary) { session in
                let index = session.messages.firstIndex { $0.id == built.segments[100].messages[1].id }!
                session.messages[index].text = "PKATEST_GAPS_同步改写"
            }
        }
        try variant("checkpoint is its own parent", fallback: 128) { $0.assistant.compactions[at].predecessorID = checkpoint.id }
        try variant("basis chain runs into a cycle", fallback: nil) { $0.assistant.compactions[0].predecessorID = basis.id }
        for (name, broken, fallback) in cases {
            let after = tip(broken, built)
            #expect(after?.tip.id != checkpoint.id, "\(name)")
            #expect(after?.tip.id == fallback.map { built.records[$0 - 1].id }, "\(name)")
        }
        // Ordinary records list exactly their roots, too.
        var phantom = built.fixture.file
        phantom.assistant.compactions[49].sourceRootPromptIDs.append(UUID())
        var duplicated = built.fixture.file
        duplicated.assistant.compactions[49].sourceRootPromptIDs.append(built.segments[49].root)
        for broken in [phantom, duplicated] { #expect(tip(broken, built)?.tip.id == built.records[48].id) }
        // Committed only over the current valid ordinary tip.
        #expect(throws: SummaryPreparationError.self) {
            _ = try AssistantContext.checkpoint(of: built.records[126], in: built.fixture.file, forgetEpoch: 0)
        }
        #expect(throws: SummaryPreparationError.self) { _ = try AssistantContext.checkpoint(of: checkpoint, in: file, forgetEpoch: 0) }
    }

    /// A chain grown from a checkpoint to the limit is re-rooted again; the
    /// new checkpoint still lists every root since the first message.
    /// A checkpoint over the first 128 rounds and an ordinary chain of 127
    /// more records grown from it (depth 128 again).
    private static func makeRegrown() throws -> (chain: Chain, tip: StoredCompaction) {
        var built = try makeChain(turns: 128 + 128 + 2, depth: 128)
        var file = built.fixture.file
        let first = try AssistantContext.checkpoint(of: built.records[127], in: file, forgetEpoch: 0)
        try file.commitSummary(first)
        var parent = first
        for n in 128..<255 {
            let record = try built.fixture.with(file: file).candidate(covering: [built.segments[n]], predecessor: parent)
            file.assistant.compactions.append(record)
            parent = record
        }
        built.fixture.file = file
        return (built, parent)
    }

    private static let regrownShared = Result { try makeRegrown() }
    private func regrown() async throws -> (chain: Chain, tip: StoredCompaction) { try Self.regrownShared.get() }

    @MainActor
    @Test func aSecondCheckpointCoversEveryRootSinceTheStart() async throws {
        let (built, parent) = try await regrown()
        let file = built.fixture.file
        let plan = try plan(built, file: file, folds: [[built.segments[255]]])
        #expect(plan.predecessorDepth == 128 && plan.predecessor?.id == parent.id)
        let owner = HistoryOwner(file: file, writer: { _ in })
        try await run(plan, built, owner: owner, calls: FoldCalls())
        let valid = try #require(tip(owner.file, built))
        #expect(valid.depth == 2 && valid.covered == covered(built, 256))
        let second = try #require(owner.file.assistant.compactions.first { $0.predecessorID == parent.id })
        #expect(Set(second.sourceRootPromptIDs) == Set(built.segments.prefix(255).map(\.root)))
    }
}

extension ContextBuilderTests.Fixture {
    func with(file: HistoryFile) -> Self { var copy = self; copy.file = file; return copy }
}

extension AssistantContext.Input {
    func with(file: HistoryFile) -> Self { var copy = self; copy.file = file; return copy }
}
