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
    /// Explicit reference quotes (`PreparedContext.quotes`). A quote's sources
    /// are not raw messages of the request: each request rechecks its
    /// reference against the latest history and registers what it carries.
    var quotes: [QuotedReference] = []
    /// Raw messages of roots the summary also covers (`PreparedContext.partialSuffix`).
    var partialSuffix: Set<UUID> = []
    /// Receives the estimate of every complete request, before the ceiling check.
    var onEstimate: (@MainActor (Int) -> Void)?
    /// Called once, with the number of raw messages dropped with it, when a
    /// forget first invalidates the included summary.
    var onExclusion: (@MainActor (Int) -> Void)?
    /// Called once per quote, with the number of quotes dropped so far, when
    /// its window was masked, deleted or changed since the context was built.
    var onQuoteExclusion: (@MainActor (Int) -> Void)?
    private var exclusionReported = false
    private var quotesReported: Set<UUID> = []
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
        // Each quote is rechecked against the latest history: a window that
        // was deleted, changed (its digest no longer matches) or masked since
        // the context was built is never sent again. Once this run registered
        // a source, the forget's closure masks this root as well and the
        // filter below stops the run; a deleted read root stays known to the
        // forget, since prune keeps a root another root read. Before that (a
        // change between building the context and the request) the quote
        // alone goes and nothing of it is registered.
        var sources: [UUID: (roots: [UUID], unknownMessages: [UUID])] = [:]
        for quote in quotes {
            if let current = quote.sources(in: file) { sources[quote.messageID] = current; continue }
            dropped.insert(quote.messageID)
            if quotesReported.insert(quote.messageID).inserted { onQuoteExclusion?(quotesReported.count) }
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
        // What this dispatch reads is durable before it is sent: raw roots with
        // a message in the request, the summary's roots while it is included,
        // and the current sources of every quote it carries (known roots, or
        // exact messages without one). Nothing dropped above is registered.
        let present = Set(prepared.messages.map(\.id))
        let quoted = quotes.compactMap { present.contains($0.messageID) ? sources[$0.messageID] : nil }
        let roots = rawRoots.filter { root in present.contains(root) || prepared.messages.contains { index.root(of: $0.id) == root } }
            + (!summaryDropped && summaryMessageID.map(present.contains) == true ? summaryRoots : [])
            + quoted.flatMap { $0.roots }
        do {
            try owner.transact {
                try $0.registerReads(root: promptID, memory: block.reads, roots: roots, messages: quoted.flatMap { $0.unknownMessages })
            }
        } catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
        lastRawEstimate = estimator.rawEstimate(prepared)
        return prepared
    }
}
