import AgentKit
import Foundation

/// Every model request of a primary turn, after the commit gate and phone
/// preparation: forget filtering against the latest history, stale phone
/// screens projected, the memory block rebuilt from the latest ledger, the
/// complete request estimated against the frozen budget (a known or explicit
/// ceiling is a hard guard), and what the request reads durably registered as
/// the turn's reads before it is sent. Runs synchronously on the main actor,
/// so it always sees the owner's latest file.
@MainActor
final class AssistantRequestPreparer {
    let owner: HistoryOwner
    let sessionID: UUID
    let promptID: UUID
    let scope: WorkScope
    let budget: ContextBudgetPolicy
    /// The calibrated estimator current at each request.
    let estimator: () -> ContextEstimator
    /// Set from the prepared context before the first request.
    var rawRoots: [UUID] = []
    var summaryRoots: [UUID] = []
    var summaryMessageID: UUID?
    var historicalMessages: [UUID] = []
    /// Raw messages of roots the summary also covers (`PreparedContext.partialSuffix`).
    var partialSuffix: Set<UUID> = []
    /// Receives the estimate of every complete request, before the ceiling check.
    var onEstimate: (@MainActor (Int) -> Void)?
    /// Called once, with the number of raw messages dropped with it, when a
    /// forget first invalidates the included summary.
    var onExclusion: (@MainActor (Int) -> Void)?
    private var exclusionReported = false
    private(set) var lastRawEstimate: Int?

    init(owner: HistoryOwner, sessionID: UUID, promptID: UUID, scope: WorkScope, budget: ContextBudgetPolicy,
         estimator: @escaping () -> ContextEstimator) {
        self.owner = owner; self.sessionID = sessionID; self.promptID = promptID; self.scope = scope
        self.budget = budget; self.estimator = estimator
    }

    func prepare(_ request: AgentModelRequest) throws -> AgentModelRequest {
        let file = owner.file
        let index = file.assistant.scopeIndex
        // A forget of a covered root invalidates the summary, and with it every
        // raw fragment that continues a root it covered: the model never gets
        // a root's later part without its start. History itself is unchanged.
        var dropped: Set<UUID> = []
        let summaryDropped = summaryMessageID != nil && summaryRoots.contains(where: index.isMasked(root:))
        if summaryDropped, let summaryMessageID {
            dropped.insert(summaryMessageID)
            dropped.formUnion(partialSuffix)
            if !exclusionReported {
                exclusionReported = true
                onExclusion?(partialSuffix.count)
            }
        }
        var prepared = request
        prepared.messages = try AssistantRequestProjection.filterForgotten(request.messages, index: index, currentRoot: promptID,
                                                                           dropped: dropped)
        prepared.messages = AssistantRequestProjection.projectOldScreens(prepared.messages)
        let real = Set(file.session(sessionID)?.messages.map(\.id) ?? [])
        let query = AssistantRequestProjection.memoryQuery(prepared.messages, real: real)
        let block = MemoryBlock.build(file.assistant.memory, scope: scope, query: query)
        prepared.systemPrompt = MemoryBlock.apply(block, to: request.systemPrompt,
                                                  hasMemoryTools: request.tools.contains { $0.name == "memory_search" })
        let estimator = estimator()
        let estimate = estimator.estimate(prepared)
        onEstimate?(estimate)
        if let ceiling = budget.hardCeiling, estimate > ceiling {
            throw ContextBudgetError.overHardCeiling(estimated: estimate, ceiling: ceiling, source: budget.label)
        }
        // What this dispatch reads is durable before it is sent.
        let present = Set(prepared.messages.map(\.id))
        let roots = rawRoots.filter { root in present.contains(root) || prepared.messages.contains { index.root(of: $0.id) == root } }
            + (!summaryDropped && summaryMessageID.map(present.contains) == true ? summaryRoots : [])
        do {
            try owner.transact { try $0.registerReads(root: promptID, memory: block.reads, roots: roots, messages: historicalMessages) }
        } catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
        lastRawEstimate = estimator.rawEstimate(prepared)
        return prepared
    }
}
