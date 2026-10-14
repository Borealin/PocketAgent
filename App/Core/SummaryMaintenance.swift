import AgentKit
import Foundation

/// Context maintenance of one primary turn: the planned tool-free summary
/// folds over a bounded producer (AgentKit `consume` in production). Right
/// before every fold's provider dispatch the host re-checks storage, explicit
/// forgets, the fold's current eligibility and the complete request estimate
/// against the frozen budget, then durably registers the roots it reads (the
/// fold and the summary it extends) for the turn's root; each result is
/// committed by CAS. All folds share one `MaintenanceDeadline`.
@MainActor
enum SummaryMaintenance {
    /// What the turn froze at acceptance.
    struct Turn: Sendable {
        var sessionID: UUID
        var promptID: UUID
        var scope: WorkScope
        var budget: ContextBudgetPolicy
        /// The same calibrated estimator the turn's main requests use.
        var estimator: ContextEstimator
        var summaryModel: String
    }

    /// Errors that stop the whole turn; any other maintenance error only
    /// means no new summary this turn (no retry).
    nonisolated static func stopsTurn(_ error: any Error) -> Bool {
        error is CancellationError || error is TurnDeadlineReached || error is StorageCommitError
            || error is ContextSourceRevoked
    }

    static func run(_ plan: SummaryPlan, turn: Turn, owner: HistoryOwner, producer: @escaping StreamingSummary.Producer,
                    deadline: MaintenanceDeadline, progress: ProgressCoalescer? = nil) async throws {
        var predecessor = plan.predecessor
        let forgetEpoch = owner.file.assistant.memory.forgetEpoch
        if let tip = predecessor, plan.predecessorDepth + plan.folds.count > AssistantContext.maxChainDepth {
            predecessor = try checkpoint(tip, turn: turn, owner: owner, forgetEpoch: forgetEpoch)
        }
        for fold in plan.folds {
            let messages = fold.flatMap(\.messages)
            guard let last = messages.last else { continue }
            try ensureStorage(owner)
            let file = owner.file
            try checkSources(file, fold: fold, predecessor: predecessor, turn: turn, forgetEpoch: forgetEpoch)
            try checkEligible(file, fold: fold, predecessor: predecessor, turn: turn)
            let request = SummaryRequest.make(messages: messages, previous: predecessor?.record.summary)
            try checkBudget(request, turn: turn)
            // What this dispatch reads is durable before it is sent, so a forget
            // preview sees the turn as a reader of these roots.
            let reads = fold.map(\.root) + (predecessor.map { AssistantContext.coverageRoots($0, in: file) } ?? [])
            do { try owner.transact { try $0.registerReads(root: turn.promptID, memory: [], roots: reads, messages: []) } }
            catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
            let input = try AssistantContext.inputDigest(messages: messages, attachments: file.session(turn.sessionID)?.attachments ?? [:],
                                                         scope: turn.scope, parent: predecessor)
            let text = try await StreamingSummary.run(request, producer: producer, deadline: deadline, progress: progress)
            // A forget during the fold discards its result and stops the turn.
            try ensureStorage(owner)
            try checkSources(owner.file, fold: fold, predecessor: predecessor, turn: turn, forgetEpoch: forgetEpoch)
            let ids = messages.map(\.id)
            let record = AgentCompactionRecord(summaryMessageID: UUID(), compactedThroughMessageID: last.id,
                                               sequence: (predecessor?.record.sequence ?? 0) + 1, summary: text,
                                               summarizedTokens: messages.reduce(0) { $0 + ContextEstimator.messageTokens($1) },
                                               keptTokens: 0, displayAnchor: last.createdAt)
            let candidate = StoredCompaction(
                id: record.id, record: record, sessionID: turn.sessionID, scope: turn.scope, sourceRootPromptIDs: fold.map(\.root),
                sourceMessageIDs: ids, predecessorID: predecessor?.id, predecessorDigest: predecessor?.recordDigest,
                inputDigest: input,
                recordDigest: try AssistantContext.recordDigest(inputDigest: input, record: record, sourceIDs: ids,
                                                                parentRecordDigest: predecessor?.recordDigest),
                builderVersion: AssistantContext.builderVersion, summaryPromptVersion: AssistantContext.summaryPromptVersion,
                forgetEpoch: owner.file.assistant.memory.forgetEpoch, summaryModel: turn.summaryModel)
            do { try owner.transact { try $0.commitSummary(candidate) } }
            catch let error as SummaryPreparationError { throw error }
            catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
            predecessor = candidate
        }
    }

    /// The chain would pass the depth limit: re-root the valid tip first, as
    /// a host-only CAS commit with no model request (`AssistantContext.checkpoint`).
    private static func checkpoint(_ tip: StoredCompaction, turn: Turn, owner: HistoryOwner,
                                   forgetEpoch: UInt64) throws -> StoredCompaction {
        try ensureStorage(owner)
        try checkSources(owner.file, fold: [], predecessor: tip, turn: turn, forgetEpoch: forgetEpoch)
        let checkpoint = try AssistantContext.checkpoint(of: tip, in: owner.file, forgetEpoch: forgetEpoch)
        do { try owner.transact { try $0.commitSummary(checkpoint) } }
        catch let error as SummaryPreparationError { throw error }
        catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
        return checkpoint
    }

    private static func ensureStorage(_ owner: HistoryOwner) throws {
        guard owner.health.isReady else { throw StorageCommitError.storageUnavailable }
    }

    /// An explicit forget masked the turn's own request, a fold source or the
    /// summary this fold extends (whose record a forget removes).
    /// `forgetEpoch` is the value when maintenance started.
    nonisolated static func checkSources(_ file: HistoryFile, fold: [ContextSegment], predecessor: StoredCompaction?,
                                         turn: Turn, forgetEpoch: UInt64) throws {
        let index = file.assistant.scopeIndex
        if index.isMasked(root: turn.promptID) { throw ContextSourceRevoked() }
        for segment in fold where index.isMasked(root: segment.root) || segment.messages.contains(where: { index.isMasked(message: $0.id) }) {
            throw ContextSourceRevoked()
        }
        guard let predecessor else { return }
        guard file.assistant.compactions.contains(where: { $0.id == predecessor.id }) else {
            if file.assistant.memory.forgetEpoch != forgetEpoch { throw ContextSourceRevoked() }
            throw SummaryPreparationError(detail: "上一段摘要已不在历史中，本轮不再整理")
        }
        if AssistantContext.coverageRoots(predecessor, in: file).contains(where: index.isMasked(root:))
            || predecessor.sourceMessageIDs.contains(where: index.isMasked(message:)) {
            throw ContextSourceRevoked()
        }
    }

    /// The fold's segments are still exactly current eligible history of the
    /// turn's scope, and the summary it extends is still the valid tip.
    nonisolated static func checkEligible(_ file: HistoryFile, fold: [ContextSegment], predecessor: StoredCompaction?,
                                          turn: Turn) throws {
        let segments = AssistantContext.eligibleSegments(file, sessionID: turn.sessionID, before: turn.promptID, scope: turn.scope)
        let current = Dictionary(segments.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        guard fold.allSatisfy({ current[$0.root] == $0 }) else {
            throw SummaryPreparationError(detail: "待整理的历史已变化，本轮不再整理")
        }
        let tip = AssistantContext.validSummary(file, sessionID: turn.sessionID, scope: turn.scope,
                                                eligible: segments.flatMap(\.messages))?.0.id
        guard tip == predecessor?.id else { throw SummaryPreparationError(detail: "摘要链已变化，本轮不再整理") }
    }

    /// The complete request (system prompt, previous summary, serialized
    /// history) must fit the turn's frozen target: the hard input ceiling of
    /// a known window or explicit limit, otherwise the unknown-window soft
    /// target (host policy, not a token bound). Over it, nothing is sent.
    nonisolated static func checkBudget(_ request: AgentModelRequest, turn: Turn) throws {
        let estimate = turn.estimator.estimate(request)
        let limit = turn.budget.target
        guard estimate > limit else { return }
        let kind = turn.budget.hardCeiling == nil ? "窗口未知时的整理软目标" : "输入上限"
        throw SummaryPreparationError(detail: "整理请求估计约 \(estimate) token，超过\(kind) \(limit)；未发送、不重试")
    }
}
