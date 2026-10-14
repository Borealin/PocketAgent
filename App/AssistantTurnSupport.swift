import AgentKit
import Foundation

/// Thread-safe set read by the nonisolated request gate.
final class SyntheticIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []
    var value: Set<UUID> { lock.withLock { ids } }
    func set(_ new: Set<UUID>) { lock.withLock { ids = new } }
}

/// Primary-line support for one accepted turn: bounded context before the
/// first request, fresh memory and forget filtering at every request, a hard
/// guard for known/explicit limits, read registration before dispatch, and
/// AgentKit's read-only memory/history tools. The AgentKit loop is unchanged.
@MainActor
final class AssistantTurnSupport {
    let owner: HistoryOwner
    let sessionID: UUID
    let promptID: UUID
    let scope: WorkScope
    let references: [HistoryReference]
    let config: RunConfiguration
    private let synthetic = SyntheticIDs()
    private var rawRoots: [UUID] = []
    private var summaryRoots: [UUID] = []
    private var summaryMessageID: UUID?
    private var historicalMessages: [UUID] = []
    private var lastRawEstimate: Int?
    /// Outcome of context maintenance this turn (shown in the status detail).
    private(set) var maintenanceNote: String?
    private var calibrationKey: EstimatorCalibration.Key {
        .init(providerID: config.providerID, modelID: config.modelID, images: config.supportsImages)
    }

    init(owner: HistoryOwner, sessionID: UUID, promptID: UUID, scope: WorkScope, references: [HistoryReference],
         config: RunConfiguration) {
        self.owner = owner; self.sessionID = sessionID; self.promptID = promptID; self.scope = scope
        self.references = references; self.config = config
    }

    nonisolated var syntheticIDs: Set<UUID> { synthetic.value }

    // MARK: Before the first request

    /// `onWork` receives coalesced counts of real summary text/reasoning
    /// increments (at most one pending MainActor delivery).
    func prepareContext(prompt: AgentTranscriptMessage, systemPrompt: String, tools: [AgentToolDescriptor],
                        provider: AgentProviderClient, deadline: TurnDeadline,
                        onWork: @escaping @MainActor @Sendable (Int) -> Void) async throws -> [AgentTranscriptMessage] {
        var prepared = build(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
        if let plan = prepared.plan {
            do {
                try await summarize(plan, provider: provider, deadline: deadline, onWork: onWork)
                prepared = build(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TurnDeadlineReached {
                // The turn's own deadline: stop the turn, no main request.
                throw error
            } catch {
                // No summary this turn and no automatic retry; a known or
                // explicit ceiling is still enforced before every request.
                maintenanceNote = (error as? LocalizedError)?.errorDescription ?? "上下文整理未完成。"
            }
        }
        synthetic.set(prepared.syntheticIDs)
        rawRoots = prepared.rawRoots
        summaryRoots = prepared.summaryRoots
        summaryMessageID = prepared.summaryID.flatMap { id in owner.file.assistant.compactions.first { $0.id == id }?.record.summaryMessageID }
        historicalMessages = prepared.historicalMessages
        let session = owner.file.session(sessionID)
        return AttachmentHydration.context(prepared.messages, attachments: session?.attachments ?? [:],
                                           supportsImages: config.supportsImages, load: attachmentFiles.data)
    }

    private func build(prompt: AgentTranscriptMessage, systemPrompt: String, tools: [AgentToolDescriptor]) -> PreparedContext {
        AssistantContext.build(.init(file: owner.file, sessionID: sessionID, promptID: promptID, scope: scope,
                                     references: references, budget: config.budget,
                                     estimator: EstimatorCalibration.shared.estimator(calibrationKey),
                                     systemPrompt: systemPrompt, tools: tools, prompt: [prompt]))
    }

    /// Tool-free summary folds over AgentKit's bounded `consume` (transport
    /// bytes, SSE line and event count capped; terminal required), each
    /// committed by CAS against the latest eligible history; a changed source
    /// discards the candidate. All folds share one 150 s maintenance deadline
    /// that never passes the turn deadline; idle is 45 s per attempt.
    private func summarize(_ plan: SummaryPlan, provider: AgentProviderClient, deadline: TurnDeadline,
                           onWork: @escaping @MainActor @Sendable (Int) -> Void) async throws {
        let maintenance = MaintenanceDeadline(turnRemaining: deadline.remaining)
        let progress = ProgressCoalescer(deliver: onWork)
        let producer: StreamingSummary.Producer = { request, onEvent in
            try await provider.consume(request, limits: .maintenance, onEvent: onEvent)
        }
        var predecessor = plan.predecessor
        for fold in plan.folds {
            let messages = fold.flatMap(\.messages)
            guard let last = messages.last else { continue }
            let attachments = owner.file.session(sessionID)?.attachments ?? [:]
            let input = try AssistantContext.inputDigest(messages: messages, attachments: attachments, scope: scope,
                                                         parent: predecessor)
            let text = try await StreamingSummary.run(
                SummaryRequest.make(messages: messages, previous: predecessor?.record.summary),
                producer: producer, deadline: maintenance, progress: progress)
            let ids = messages.map(\.id)
            let record = AgentCompactionRecord(summaryMessageID: UUID(), compactedThroughMessageID: last.id,
                                               sequence: (predecessor?.record.sequence ?? 0) + 1, summary: text,
                                               summarizedTokens: messages.reduce(0) { $0 + ContextEstimator.messageTokens($1) },
                                               keptTokens: 0, displayAnchor: last.createdAt)
            let candidate = StoredCompaction(
                id: record.id, record: record, sessionID: sessionID, scope: scope, sourceRootPromptIDs: fold.map(\.root),
                sourceMessageIDs: ids, predecessorID: predecessor?.id, predecessorDigest: predecessor?.recordDigest,
                inputDigest: input,
                recordDigest: try AssistantContext.recordDigest(inputDigest: input, record: record, sourceIDs: ids,
                                                                parentRecordDigest: predecessor?.recordDigest),
                builderVersion: AssistantContext.builderVersion, summaryPromptVersion: AssistantContext.summaryPromptVersion,
                forgetEpoch: owner.file.assistant.memory.forgetEpoch, summaryModel: config.label)
            try owner.transact { try $0.commitSummary(candidate) }
            predecessor = candidate
        }
    }

    // MARK: Every request

    func prepareRequest(_ request: AgentModelRequest) async throws -> AgentModelRequest {
        let file = owner.file
        let index = file.assistant.scopeIndex
        var invalid: Set<UUID> = []
        if let summaryMessageID, summaryRoots.contains(where: index.isMasked(root:)) { invalid.insert(summaryMessageID) }
        var prepared = request
        prepared.messages = try AssistantRequestProjection.filterForgotten(request.messages, index: index, currentRoot: promptID,
                                                                           invalidSummaries: invalid)
        prepared.messages = AssistantRequestProjection.projectOldScreens(prepared.messages)
        let real = Set(file.session(sessionID)?.messages.map(\.id) ?? [])
        let query = AssistantRequestProjection.memoryQuery(prepared.messages, real: real)
        let block = MemoryBlock.build(file.assistant.memory, scope: scope, query: query)
        prepared.systemPrompt = MemoryBlock.apply(block, to: request.systemPrompt,
                                                  hasMemoryTools: request.tools.contains { $0.name == "memory_search" })
        let estimator = EstimatorCalibration.shared.estimator(calibrationKey)
        let estimate = estimator.estimate(prepared)
        if let ceiling = config.budget.hardCeiling, estimate > ceiling {
            throw ContextBudgetError.overHardCeiling(estimated: estimate, ceiling: ceiling, source: config.budget.label)
        }
        // What this dispatch reads is durable before it is sent.
        let present = Set(prepared.messages.map(\.id))
        let roots = rawRoots.filter { root in present.contains(root) || prepared.messages.contains { index.root(of: $0.id) == root } }
            + (invalid.isEmpty && summaryMessageID.map(present.contains) == true ? summaryRoots : [])
        do {
            try owner.transact { try $0.registerReads(root: promptID, memory: block.reads, roots: roots, messages: historicalMessages) }
        } catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
        lastRawEstimate = estimator.rawEstimate(prepared)
        return prepared
    }

    func observeUsage(_ usage: AgentTokenUsage) {
        guard let raw = lastRawEstimate, usage.inputTokens > 0 else { return }
        EstimatorCalibration.shared.record(calibrationKey, estimatedRaw: raw, actualInputTokens: usage.inputTokens)
    }

    // MARK: Read-only tools

    func readTools() -> [AnyAgentTool] {
        let owner = owner, root = promptID
        let adapter = PocketMemoryAdapter(scope: scope, currentRoot: root, references: references,
            snapshot: { await MainActor.run { owner.file } },
            register: { memory, roots, messages in
                try await MainActor.run {
                    do { try owner.transact { try $0.registerReads(root: root, memory: memory, roots: roots, messages: messages) } }
                    catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
                }
            })
        return [AnyAgentTool(MemorySearchTool(store: adapter)), AnyAgentTool(SessionSearchTool(store: adapter))]
    }
}
