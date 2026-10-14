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
    /// The run's commit epoch; a failed read registration fails it.
    let epoch: UInt64
    /// Whether this run still owns its session (not replaced, cancelled, revoked or finished).
    let isActive: @MainActor () -> Bool
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
         config: RunConfiguration, epoch: UInt64, isActive: @escaping @MainActor () -> Bool) {
        self.owner = owner; self.sessionID = sessionID; self.promptID = promptID; self.scope = scope
        self.references = references; self.config = config; self.epoch = epoch; self.isActive = isActive
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
            } catch where SummaryMaintenance.stopsTurn(error) {
                // Stop, system expiry, the turn deadline, storage or an explicit
                // forget of a source: stop the turn, no main request.
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
    /// bytes, SSE line and event count capped; terminal required). Each fold is
    /// checked before dispatch (storage, forgets, eligibility, complete request
    /// estimate against the frozen budget) and committed by CAS. All folds
    /// share one 150 s maintenance deadline that never passes the turn
    /// deadline; idle is 45 s per attempt.
    private func summarize(_ plan: SummaryPlan, provider: AgentProviderClient, deadline: TurnDeadline,
                           onWork: @escaping @MainActor @Sendable (Int) -> Void) async throws {
        let producer: StreamingSummary.Producer = { request, onEvent in
            do { try await provider.consume(request, limits: .maintenance, onEvent: onEvent) }
            catch { throw ProviderContextLimit.classify(error, path: .summary) ?? error }
        }
        try await SummaryMaintenance.run(
            plan, turn: .init(sessionID: sessionID, promptID: promptID, scope: scope, budget: config.budget,
                              estimator: EstimatorCalibration.shared.estimator(calibrationKey), summaryModel: config.label),
            owner: owner, producer: producer, deadline: MaintenanceDeadline(turnRemaining: deadline.remaining),
            progress: ProgressCoalescer(deliver: onWork))
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
        let owner = owner, root = promptID, scope = scope, references = references, epoch = epoch, isActive = isActive
        let adapter = PocketMemoryAdapter(scope: scope, currentRoot: root, references: references,
            snapshot: { await MainActor.run { owner.file } },
            commit: { plan in
                try await MainActor.run { try ReadCommitGate.commit(plan, owner: owner, root: root, scope: scope,
                                                                    references: references, epoch: epoch, isActive: isActive) }
            })
        return [AnyAgentTool(MemorySearchTool(store: adapter)), AnyAgentTool(SessionSearchTool(store: adapter))]
    }
}
