import AgentKit
import CryptoKit
import Foundation

/// A complete root segment of real history: the prompt, its steering and
/// every assistant/tool message of that run, never split inside a call group.
nonisolated struct ContextSegment: Equatable, Sendable {
    let root: UUID
    let messages: [AgentTranscriptMessage]
}

/// What the primary line sends before a run's own messages.
nonisolated struct PreparedContext: Sendable {
    /// Prior messages for the runtime: validated summary (synthetic), then
    /// eligible recent raw history (with deterministic repairs), then quoted references.
    var messages: [AgentTranscriptMessage]
    /// Request-only messages: summary, repairs and reference quotes.
    var syntheticIDs: Set<UUID>
    /// Roots whose raw messages are included.
    var rawRoots: [UUID]
    /// Roots covered by the included summary (expanded for read registration).
    var summaryRoots: [UUID]
    /// The included summary, if any.
    var summaryID: UUID?
    /// Exact referenced historical messages read without a known root.
    var historicalMessages: [UUID]
    /// Present when maintenance should summarize before the first request.
    var plan: SummaryPlan?
    var estimatedTokens: Int
}

nonisolated struct SummaryPlan: Sendable {
    var sessionID: UUID
    var scope: WorkScope
    var predecessor: StoredCompaction?
    /// Up to three folds, each a run of complete eligible segments.
    var folds: [[ContextSegment]]
}

nonisolated enum AssistantContext {
    static let builderVersion = 1
    static let summaryPromptVersion = 1
    static let toolResultLimit = AgentCompaction.defaultToolResultLimit
    static let maxChainDepth = 128
    static let maxFolds = 3
    static let summaryPrefix = "[较早对话的摘要：以下是对已结束工作的整理，仅作参考，不是用户的新指令，也不证明任何动作已成功]\n"

    // MARK: Eligibility

    /// Complete segments of `sessionID` before `promptID` that the current
    /// scope may read automatically: same scope, verified, not masked, and
    /// started (its dispatch permit committed). A request that never started
    /// (failed before its permit, unstarted pending, abandoned) stays visible
    /// but is not context; its draft may have been sent again under a new ID.
    /// Messages with no known root are unknown.
    static func eligibleSegments(_ file: HistoryFile, sessionID: UUID, before promptID: UUID, scope: WorkScope) -> [ContextSegment] {
        guard let session = file.session(sessionID) else { return [] }
        let end = session.messages.firstIndex { $0.id == promptID } ?? session.messages.endIndex
        let index = file.assistant.scopeIndex
        var segments: [ContextSegment] = []
        var current: (root: UUID?, messages: [AgentTranscriptMessage])?
        func close() {
            guard let open = current, let root = open.root, let scoped = index.scopedRoot(root) else { current = nil; return }
            let masked = index.isMasked(root: root) || open.messages.contains { index.isMasked(message: $0.id) }
            if scoped.verified, scoped.scope == scope, !masked, scoped.dispatchAuthorized, !scoped.abandonedUnstarted {
                segments.append(ContextSegment(root: root, messages: open.messages))
            }
            current = nil
        }
        for message in session.messages[..<end] {
            let root = index.root(of: message.id)
            if current != nil, current?.root == root { current?.messages.append(message) } else {
                close()
                current = (root, [message])
            }
        }
        close()
        return segments
    }

    /// Deterministic call/result repair of one segment: unanswered calls get
    /// a synthetic "result unknown, check first" result with a stable ID.
    static func repaired(_ messages: [AgentTranscriptMessage]) -> (messages: [AgentTranscriptMessage], synthetic: Set<UUID>) {
        var output: [AgentTranscriptMessage] = []
        var synthetic: Set<UUID> = []
        let calls = Set(messages.flatMap { $0.toolCalls.map(\.id) })
        var index = 0
        while index < messages.count {
            let message = messages[index]
            index += 1
            if message.role == .tool, let id = message.toolCallID, !calls.contains(id) { continue } // orphan
            output.append(message)
            guard message.role == .assistant, !message.toolCalls.isEmpty else { continue }
            var answered: Set<String> = []
            let own = Set(message.toolCalls.map(\.id))
            while index < messages.count, messages[index].role == .tool {
                // Results of this group stay adjacent; anything else here is an orphan.
                if let id = messages[index].toolCallID, own.contains(id), answered.insert(id).inserted {
                    output.append(messages[index])
                }
                index += 1
            }
            for call in message.toolCalls where !answered.contains(call.id) {
                let id = stableID("repair:\(message.id.uuidString):\(call.id)")
                synthetic.insert(id)
                output.append(AgentTranscriptMessage(id: id, role: .tool,
                    text: "这次工具调用在 App 退出或中断前没有记录结果。动作是否发生未知；继续前请先检查实际状态。",
                    toolCallID: call.id, toolName: call.name, isError: true, createdAt: message.createdAt))
            }
        }
        return (output, synthetic)
    }

    static func stableID(_ seed: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    // MARK: Summary digests

    private struct AttachmentDTO: Encodable { let messageID: String; let id: String; let mimeType: String; let bytes: Int }
    private struct InputDTO: Encodable {
        let builderVersion: Int
        let summaryPromptVersion: Int
        let toolResultLimit: Int
        let scope: String
        let sourceIDs: [String]
        let serialized: String
        let attachments: [AttachmentDTO]
        let parentRecordDigest: String?
        let parentSummary: String?
    }
    private struct RecordDTO: Encodable {
        let inputDigest: String
        let summary: String
        let anchor: String?
        let sourceIDs: [String]
        let parentRecordDigest: String?
    }

    static func scopeKey(_ scope: WorkScope) -> String {
        switch scope {
        case .general: "general"
        case .workspace(let id): "workspace:" + id.uuidString
        }
    }

    /// The exact text a summarizer is shown for these messages: repaired,
    /// modelText-projected and serialized with the fixed tool-result limit.
    static func serialized(_ messages: [AgentTranscriptMessage]) -> String {
        let projected = repaired(messages).messages.map { message -> AgentTranscriptMessage in
            var copy = message
            copy.text = message.modelText ?? message.text
            copy.modelText = nil
            copy.images = []
            copy.contextSnapshot = nil
            return copy
        }
        return AgentCompaction.serialized(projected, toolResultLimit: toolResultLimit)
    }

    static func inputDigest(messages: [AgentTranscriptMessage], attachments: [String: [ChatAttachment]], scope: WorkScope,
                            parent: StoredCompaction?) throws -> String {
        let dto = InputDTO(
            builderVersion: builderVersion, summaryPromptVersion: summaryPromptVersion, toolResultLimit: toolResultLimit,
            scope: scopeKey(scope), sourceIDs: messages.map(\.id.uuidString), serialized: serialized(messages),
            attachments: messages.flatMap { message in
                (attachments[message.id.uuidString] ?? []).map {
                    AttachmentDTO(messageID: message.id.uuidString, id: $0.id.uuidString, mimeType: $0.mimeType, bytes: $0.byteCount)
                }
            },
            parentRecordDigest: parent?.recordDigest, parentSummary: parent?.record.summary)
        return try CanonicalDigest.digest(dto, domain: "summary-input")
    }

    static func recordDigest(inputDigest: String, record: AgentCompactionRecord, sourceIDs: [UUID],
                             parentRecordDigest: String?) throws -> String {
        try CanonicalDigest.digest(RecordDTO(inputDigest: inputDigest, summary: record.summary,
                                             anchor: record.compactedThroughMessageID?.uuidString,
                                             sourceIDs: sourceIDs.map(\.uuidString), parentRecordDigest: parentRecordDigest),
                                   domain: "summary-record")
    }

    /// The longest stored summary chain that exactly covers a prefix of the
    /// eligible real messages: every record's source IDs continue the parent
    /// without gap or overlap, the anchor is the last covered message, and
    /// both digests recompute from the current projection. Returns the tip
    /// and the number of covered messages.
    static func validSummary(_ file: HistoryFile, sessionID: UUID, scope: WorkScope,
                             eligible: [AgentTranscriptMessage]) -> (StoredCompaction, Int)? {
        let candidates = file.assistant.compactions.filter { $0.sessionID == sessionID && $0.scope == scope }
        guard !candidates.isEmpty, let session = file.session(sessionID) else { return nil }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var best: (StoredCompaction, Int)?
        for tip in candidates {
            var chain: [StoredCompaction] = [tip]
            var seen: Set<UUID> = [tip.id]
            var valid = true
            while let parentID = chain.last?.predecessorID {
                guard chain.count < maxChainDepth, let parent = byID[parentID], seen.insert(parentID).inserted else { valid = false; break }
                chain.append(parent)
            }
            guard valid else { continue }
            chain.reverse()
            var position = 0
            var parent: StoredCompaction?
            for record in chain {
                let ids = record.sourceMessageIDs
                guard !ids.isEmpty, position + ids.count <= eligible.count,
                      Array(eligible[position..<position + ids.count].map(\.id)) == ids,
                      record.record.compactedThroughMessageID == ids.last,
                      record.predecessorID == parent?.id, record.predecessorDigest == parent?.recordDigest,
                      record.builderVersion == builderVersion, record.summaryPromptVersion == summaryPromptVersion,
                      let input = try? inputDigest(messages: Array(eligible[position..<position + ids.count]),
                                                   attachments: session.attachments, scope: scope, parent: parent),
                      input == record.inputDigest,
                      let output = try? recordDigest(inputDigest: input, record: record.record, sourceIDs: ids,
                                                     parentRecordDigest: parent?.recordDigest),
                      output == record.recordDigest else { valid = false; break }
                position += ids.count
                parent = record
            }
            if valid, position > (best?.1 ?? 0) { best = (tip, position) }
        }
        return best
    }

    static func coverageRoots(_ tip: StoredCompaction, in file: HistoryFile) -> [UUID] {
        var roots: [UUID] = []
        var seen: Set<UUID> = []
        var record: StoredCompaction? = tip
        let byID = Dictionary(file.assistant.compactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var depth = 0
        while let current = record, depth < maxChainDepth {
            for root in current.sourceRootPromptIDs where seen.insert(root).inserted { roots.append(root) }
            record = current.predecessorID.flatMap { byID[$0] }
            depth += 1
        }
        return roots
    }

    static func summaryMessage(_ stored: StoredCompaction) -> AgentTranscriptMessage {
        AgentTranscriptMessage(id: stored.record.summaryMessageID, role: .user, text: summaryPrefix + stored.record.summary,
                               isCompaction: true, createdAt: stored.record.displayAnchor)
    }

    // MARK: Build

    struct Input: Sendable {
        var file: HistoryFile
        var sessionID: UUID
        var promptID: UUID
        var scope: WorkScope
        var references: [HistoryReference]
        var budget: ContextBudgetPolicy
        var estimator: ContextEstimator
        /// Fixed request parts that count toward the same estimate.
        var systemPrompt: String
        var tools: [AgentToolDescriptor]
        /// Prompt text/images of this run.
        var prompt: [AgentTranscriptMessage]
    }

    /// Pure: no await, no history mutation.
    static func build(_ input: Input) -> PreparedContext {
        let segments = eligibleSegments(input.file, sessionID: input.sessionID, before: input.promptID, scope: input.scope)
        let eligible = segments.flatMap(\.messages)
        var synthetic: Set<UUID> = []
        var messages: [AgentTranscriptMessage] = []
        var covered = 0
        var summary: StoredCompaction?
        var summaryRoots: [UUID] = []
        if let (tip, count) = validSummary(input.file, sessionID: input.sessionID, scope: input.scope, eligible: eligible) {
            summary = tip; covered = count
            summaryRoots = coverageRoots(tip, in: input.file)
            let message = summaryMessage(tip)
            messages.append(message); synthetic.insert(message.id)
        }
        // Raw segments after the summary anchor (segments are never split:
        // a summary always ends on a segment boundary).
        var position = 0
        var remaining: [ContextSegment] = []
        for segment in segments {
            if position >= covered { remaining.append(segment) }
            position += segment.messages.count
        }
        var rawRoots: [UUID] = []
        for segment in remaining {
            let fixed = repaired(segment.messages)
            messages += fixed.messages; synthetic.formUnion(fixed.synthetic)
            rawRoots.append(segment.root)
        }
        // Explicit user-selected references, quoted as data, never as new instructions.
        var historical: [UUID] = []
        for reference in input.references {
            guard let quoted = quote(reference, file: input.file) else { continue }
            messages.append(quoted.message); synthetic.insert(quoted.message.id)
            rawRoots += quoted.roots.filter { !rawRoots.contains($0) }
            historical += quoted.unknownMessages
        }
        let estimate = input.estimator.estimate(systemPrompt: input.systemPrompt, tools: input.tools,
                                                messages: messages + input.prompt)
        var plan: SummaryPlan?
        if estimate > input.budget.summaryTrigger {
            plan = summaryPlan(remaining, predecessor: summary, input: input)
        }
        return PreparedContext(messages: messages, syntheticIDs: synthetic, rawRoots: rawRoots, summaryRoots: summaryRoots,
                               summaryID: summary?.id, historicalMessages: historical, plan: plan, estimatedTokens: estimate)
    }

    /// Keep the most recent complete segments within 35% of the target and
    /// summarize the older remainder (folded with the previous summary), in at
    /// most three folds that each fit the summarizer's own input budget.
    static func summaryPlan(_ remaining: [ContextSegment], predecessor: StoredCompaction?, input: Input) -> SummaryPlan? {
        var kept = 0
        var cut = remaining.count
        for index in remaining.indices.reversed() {
            let tokens = remaining[index].messages.reduce(0) { $0 + ContextEstimator.messageTokens($1) }
            if cut < remaining.count, kept + tokens > input.budget.recentTarget { break }
            kept += tokens; cut = index
        }
        let older = Array(remaining[..<cut])
        guard !older.isEmpty else { return nil }
        // Each fold's serialized input stays within 60% of the target.
        let foldBudget = input.budget.target * 60 / 100
        var folds: [[ContextSegment]] = []
        var current: [ContextSegment] = []
        var size = predecessor.map { ContextEstimator.textTokens($0.record.summary) } ?? 0
        for segment in older {
            let tokens = ContextEstimator.textTokens(serialized(segment.messages))
            if tokens > foldBudget { return nil } // one safe group is larger than a summarizer input
            if !current.isEmpty, size + tokens > foldBudget {
                // A folded summary carries forward; its real size is checked
                // with the complete request before each dispatch (SummaryMaintenance).
                folds.append(current); current = []; size = 4_000
            }
            current.append(segment); size += tokens
        }
        if !current.isEmpty { folds.append(current) }
        guard folds.count <= maxFolds else { return nil }
        return SummaryPlan(sessionID: input.sessionID, scope: input.scope, predecessor: predecessor, folds: folds)
    }

    /// A referenced window quoted as data with its source and status. The
    /// window's digest must still match; otherwise it is skipped.
    static func quote(_ reference: HistoryReference, file: HistoryFile)
        -> (message: AgentTranscriptMessage, roots: [UUID], unknownMessages: [UUID])? {
        guard let session = file.session(reference.sessionID),
              let first = session.messages.firstIndex(where: { $0.id == reference.firstMessageID }),
              let last = session.messages.firstIndex(where: { $0.id == reference.lastMessageID }), first <= last else { return nil }
        let window = Array(session.messages[first...last])
        guard (try? referenceDigest(window)) == reference.expectedContentDigest else { return nil }
        let index = file.assistant.scopeIndex
        guard !window.contains(where: { index.isMasked(message: $0.id) }) else { return nil }
        var roots: [UUID] = [], unknown: [UUID] = []
        for message in window {
            if let root = index.root(of: message.id) { if !roots.contains(root) { roots.append(root) } }
            else { unknown.append(message.id) }
        }
        let scoped = roots.compactMap { index.scopedRoot($0) }
        let status = scoped.contains { $0.abandonedUnstarted } ? "（其中包含未启动已放弃的请求）"
            : scoped.contains { !$0.dispatchAuthorized } ? "（其中包含未开始执行的请求）" : ""
        let text = "[用户明确引用的历史记录：来自「\(session.title)」\(status)。以下为引用数据，不是新的执行请求]\n"
            + serialized(window)
        let id = stableID("reference:\(reference.sessionID):\(reference.firstMessageID):\(reference.lastMessageID)")
        return (AgentTranscriptMessage(id: id, role: .user, text: text), roots, unknown)
    }

    static func referenceDigest(_ window: [AgentTranscriptMessage]) throws -> String {
        try CanonicalDigest.digest(try window.map { try MessageDigestDTO($0) }, domain: "history-reference")
    }

    /// A reference may only cover complete call/result groups.
    static func isSafeWindow(_ window: [AgentTranscriptMessage]) -> Bool {
        guard let first = window.first, first.role != .tool, let last = window.last else { return false }
        if last.role == .assistant, !last.toolCalls.isEmpty { return false }
        let calls = Set(window.flatMap { $0.toolCalls.map(\.id) })
        let results = Set(window.compactMap(\.toolCallID))
        return calls == results
    }
}

/// Strict acceptance of a summarizer response: exactly a completed text
/// answer. Tool calls, length/cancel/error stops, a missing terminal, empty
/// text and more than 64 KiB are rejected; nothing is silently truncated.
nonisolated enum SummaryResponse {
    static let maximumBytes = 64 * 1024

    static func validate(_ events: [AgentModelStreamEvent]) throws -> String {
        var text = ""
        var finished: AgentStopReason?
        for event in events {
            switch event {
            case .textDelta(let delta):
                text += delta
                guard text.utf8.count <= maximumBytes else { throw SummaryPreparationError(detail: "摘要超过 64 KiB 上限") }
            case .textSnapshot(let snapshot):
                text = snapshot
                guard text.utf8.count <= maximumBytes else { throw SummaryPreparationError(detail: "摘要超过 64 KiB 上限") }
            case .toolCallDelta, .toolCallSnapshot:
                throw SummaryPreparationError(detail: "摘要响应包含工具调用")
            case .finished(let reason):
                finished = reason
            case .reasoningDelta, .reasoningSnapshot, .providerItem, .usage, .webSearch:
                continue
            }
        }
        guard let finished else { throw SummaryPreparationError(detail: "摘要响应缺少完成标记") }
        guard finished == .completed else {
            throw SummaryPreparationError(detail: finished == .length ? "摘要被截断（length），未采用" : "摘要未正常完成")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryPreparationError(detail: "摘要为空") }
        return trimmed
    }
}

nonisolated extension HistoryFile {
    /// CAS commit of a summary candidate: it must extend the currently valid
    /// chain exactly over the latest eligible history (same sources, digests
    /// and coverage). Anything that changed meanwhile discards it.
    mutating func commitSummary(_ candidate: StoredCompaction) throws {
        let segments = AssistantContext.eligibleSegments(self, sessionID: candidate.sessionID, before: UUID(),
                                                         scope: candidate.scope)
        let eligible = segments.flatMap(\.messages)
        let before = AssistantContext.validSummary(self, sessionID: candidate.sessionID, scope: candidate.scope,
                                                   eligible: eligible)
        guard before?.0.id == candidate.predecessorID else {
            throw SummaryPreparationError(detail: "历史已变化，整理结果已丢弃")
        }
        var trial = self
        trial.assistant.compactions.append(candidate)
        guard let after = AssistantContext.validSummary(trial, sessionID: candidate.sessionID, scope: candidate.scope,
                                                        eligible: eligible),
              after.0.id == candidate.id else {
            throw SummaryPreparationError(detail: "整理结果与当前历史不一致，已丢弃")
        }
        // A summary ends on a segment boundary.
        var position = 0
        var boundaries: Set<Int> = [0]
        for segment in segments { position += segment.messages.count; boundaries.insert(position) }
        guard boundaries.contains(after.1) else { throw SummaryPreparationError(detail: "整理结果切在任务段中间，已丢弃") }
        assistant.compactions.append(candidate)
    }
}
