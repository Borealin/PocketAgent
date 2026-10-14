import AgentKit
import Foundation
import UIKit

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
    /// The bounded-streaming maintenance API is not available in the pinned
    /// AgentKit; summaries use the buffered fallback for at most this long,
    /// in the foreground only.
    static let fallbackSummarySeconds: TimeInterval = 30

    init(owner: HistoryOwner, sessionID: UUID, promptID: UUID, scope: WorkScope, references: [HistoryReference],
         config: RunConfiguration) {
        self.owner = owner; self.sessionID = sessionID; self.promptID = promptID; self.scope = scope
        self.references = references; self.config = config
    }

    nonisolated var syntheticIDs: Set<UUID> { synthetic.value }

    // MARK: Before the first request

    func prepareContext(prompt: AgentTranscriptMessage, systemPrompt: String, tools: [AgentToolDescriptor],
                        provider: AgentProviderClient, deadline: TurnDeadline) async throws -> [AgentTranscriptMessage] {
        var prepared = build(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
        if let plan = prepared.plan {
            do {
                try await summarize(plan, provider: provider, deadline: deadline)
                prepared = build(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
            } catch is CancellationError {
                throw CancellationError()
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

    /// Tool-free summary folds, each committed by CAS against the latest
    /// eligible history; a changed source discards the candidate.
    private func summarize(_ plan: SummaryPlan, provider: AgentProviderClient, deadline: TurnDeadline) async throws {
        var predecessor = plan.predecessor
        for fold in plan.folds {
            let messages = fold.flatMap(\.messages)
            guard let last = messages.last else { continue }
            let attachments = owner.file.session(sessionID)?.attachments ?? [:]
            let input = try AssistantContext.inputDigest(messages: messages, attachments: attachments, scope: scope,
                                                         parent: predecessor)
            let text = try await Self.summaryText(messages: messages, previous: predecessor?.record.summary,
                                                  provider: provider, deadline: deadline)
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

    /// Buffered fallback: AgentKit's complete() (16 MiB cap, terminal event
    /// required), at most 30 s, cancelled if the app leaves the foreground.
    /// Accepts only `.completed` without tool calls and at most 64 KiB of
    /// text; `.length` and empty answers are rejected.
    static func summaryText(messages: [AgentTranscriptMessage], previous: String?, provider: AgentProviderClient,
                            deadline: TurnDeadline) async throws -> String {
        let limit = min(fallbackSummarySeconds, deadline.remaining)
        guard limit > 1 else { throw SummaryPreparationError(detail: "本轮剩余时间不足") }
        var body = ""
        if let previous { body += "<previous-summary>\n\(previous)\n</previous-summary>\n" }
        body += "<untrusted-data>\n\(AssistantContext.serialized(messages))\n</untrusted-data>"
        let request = AgentModelRequest(
            systemPrompt: AgentCompactionService.systemPrompt(
                instructions: "使用对话所用的语言。合并 previous-summary 与新内容，保留用户明确的偏好、决定、未完成事项和未确认的动作结果。"),
            messages: [AgentTranscriptMessage(role: .user, text: body)], tools: [])
        let background = NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification)
        let events: [AgentModelStreamEvent] = try await withThrowingTaskGroup(of: [AgentModelStreamEvent]?.self) { group in
            group.addTask { try await provider.complete(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw SummaryPreparationError(detail: "整理超过 \(Int(limit)) 秒，本轮不使用摘要")
            }
            group.addTask {
                for await _ in background { throw SummaryPreparationError(detail: "App 离开前台，整理已取消") }
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() { if let result { return result } }
            throw SummaryPreparationError(detail: "整理没有结果")
        }
        return try SummaryResponse.validate(events)
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
