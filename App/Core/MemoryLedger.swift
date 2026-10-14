import AgentKit
import Foundation

nonisolated enum MemoryLimits {
    static let activeEntries = 200
    static let totalContentBytes = 64 * 1024
    static let entryScalars = 2_000
    /// Core user-profile entries injected every request (complete entries only).
    static let userInjectionScalars = 2_000
    /// Relevant memory entries injected per request.
    static let memoryInjectionScalars = 6_000
    static let memoryInjectionEntries = 8
}

nonisolated enum MemoryError: LocalizedError, Equatable {
    case empty
    case tooLong
    case unsafe(String)
    case capacity(String)
    case stale
    case missing
    case modelWriteRefused
    case userTargetRequiresGlobal
    var errorDescription: String? {
        switch self {
        case .empty: "记忆内容不能为空。"
        case .tooLong: "单条记忆最多 \(MemoryLimits.entryScalars) 个字符。"
        case .unsafe(let detail): "记忆内容不能保存：\(detail)"
        case .capacity(let detail): "记忆容量已满：\(detail)。请先整理或遗忘不需要的条目。"
        case .stale: "这条记忆已在别处更新；已刷新，请重新确认后再编辑。"
        case .missing: "这条记忆已不存在。"
        case .modelWriteRefused: "记忆只能由你在记忆面板或明确命令中保存；模型不能直接写入。"
        case .userTargetRequiresGlobal: "个人资料类记忆只能保存为全局范围。"
        }
    }
}

/// Strict host memory command: `记住：<完整原文>` or `/remember <完整原文>`.
/// The whole remainder is the exact payload; no run starts.
nonisolated struct MemoryCommand: Equatable, Sendable {
    let content: String

    static func parse(_ draft: String) -> MemoryCommand? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["记住：", "记住:", "/remember "] where text.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : MemoryCommand(content: rest)
        }
        return nil
    }
}

/// One explicit user edit from the panel, command or chat chip.
nonisolated enum UserMemoryEdit: Equatable, Sendable {
    case add(target: AgentMemoryTarget, scope: MemoryScope, content: String, origin: MemoryOrigin,
             sourceRootPromptIDs: [UUID], sourceMessageIDs: [UUID])
    /// Correction: same ID, new revision. Existing readers keep their reads;
    /// nothing is forgotten or stopped.
    case replace(entryID: UUID, expectedRevision: UInt64, content: String)
}

/// The final forget panel's facts, captured with the versions they were
/// computed from. Commit recomputes and refuses any difference.
nonisolated struct ForgetPreview: Equatable, Sendable {
    var entries: [MemoryReadRevision]
    var ledgerRevision: UInt64
    var dependencyRevision: UInt64
    var affectedRoots: Set<UUID>
    var maskedMessages: Set<UUID>
    var stopsActiveRoot: Bool
    var affectedSummaries: Int
    var affectedRootCount: Int { affectedRoots.count }
}

nonisolated enum ForgetError: LocalizedError, Equatable {
    case changed
    var errorDescription: String? { "遗忘的影响范围已变化（有新的读取或编辑），已刷新预览；请重新确认。" }
}

nonisolated extension MemoryLedger {
    func entry(_ id: UUID) -> MemoryRecord? { active.first { $0.id == id } }

    /// Active entries readable from `work`: global ones and the same project's.
    func visible(in work: WorkScope) -> [MemoryRecord] { active.filter { $0.scope.visible(in: work) } }

    var totalContentBytes: Int { active.reduce(0) { $0 + $1.content.utf8.count } }
}

nonisolated extension HistoryFile {
    /// Host-exact memory write. The content passes AgentKit's native
    /// validation (`AgentMemoryState.applying` / content scanner); identity is
    /// by entry ID and revision, never substring matching.
    mutating func applyMemoryEdit(_ edit: UserMemoryEdit, now: Date = Date()) throws -> MemoryReceipt {
        var ledger = assistant.memory
        let receipt: MemoryReceipt
        switch edit {
        case .add(let target, let scope, let raw, let origin, let roots, let messages):
            let content = try Self.validatedMemory(raw, target: target)
            if target == .user, scope != .global { throw MemoryError.userTargetRequiresGlobal }
            let fingerprint = CanonicalDigest.contentFingerprint(content)
            if let existing = ledger.active.first(where: {
                $0.target == target && $0.scope == scope && CanonicalDigest.contentFingerprint($0.content) == fingerprint
            }) {
                receipt = MemoryReceipt(id: UUID(), entryIDs: [existing.id], action: "add", scope: scope, createdAt: now,
                                        result: "已有相同记忆，未重复保存")
            } else {
                guard ledger.active.count < MemoryLimits.activeEntries else { throw MemoryError.capacity("最多 \(MemoryLimits.activeEntries) 条") }
                guard ledger.totalContentBytes + content.utf8.count <= MemoryLimits.totalContentBytes else {
                    throw MemoryError.capacity("总内容超过 64 KiB")
                }
                ledger.revision += 1
                let record = MemoryRecord(id: UUID(), target: target, scope: scope, content: content, revision: ledger.revision,
                                          origin: origin, sourceRootPromptIDs: roots, sourceMessageIDs: messages,
                                          createdAt: now, updatedAt: now)
                ledger.active.append(record)
                receipt = MemoryReceipt(id: UUID(), entryIDs: [record.id], action: "add", scope: scope, createdAt: now,
                                        result: "已保存")
            }
        case .replace(let id, let expected, let raw):
            guard let index = ledger.active.firstIndex(where: { $0.id == id }) else { throw MemoryError.missing }
            guard ledger.active[index].revision == expected else { throw MemoryError.stale }
            let content = try Self.validatedMemory(raw, target: ledger.active[index].target)
            let others = ledger.totalContentBytes - ledger.active[index].content.utf8.count
            guard others + content.utf8.count <= MemoryLimits.totalContentBytes else { throw MemoryError.capacity("总内容超过 64 KiB") }
            ledger.revision += 1
            ledger.active[index].content = content
            ledger.active[index].revision = ledger.revision
            ledger.active[index].updatedAt = now
            receipt = MemoryReceipt(id: UUID(), entryIDs: [id], action: "replace", scope: ledger.active[index].scope,
                                    createdAt: now, result: "已更正；下一次模型请求使用新内容")
        }
        assistant.memory = ledger
        appendReceipt(receipt)
        return receipt
    }

    mutating func appendReceipt(_ receipt: MemoryReceipt) {
        assistant.memoryReceipts.append(receipt)
        if assistant.memoryReceipts.count > MemoryReceipt.retained {
            assistant.memoryReceipts.removeFirst(assistant.memoryReceipts.count - MemoryReceipt.retained)
        }
    }

    /// Native AgentKit content checks applied to one exact entry projection.
    static func validatedMemory(_ raw: String, target: AgentMemoryTarget) throws -> String {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw MemoryError.empty }
        guard content.unicodeScalars.count <= MemoryLimits.entryScalars else { throw MemoryError.tooLong }
        do {
            _ = try AgentMemoryState().applying([AgentMemoryOperation(action: .add, target: target, content: content)])
        } catch { throw MemoryError.unsafe((error as? LocalizedError)?.errorDescription ?? "内容未通过检查") }
        return content
    }

    // MARK: Forgetting

    /// Known dependency closure of forgetting `entries` through their current
    /// revision: roots that read them (any revision ≤ current), their source
    /// roots/messages, and every root that read an affected root or message.
    func forgetPreview(_ entryIDs: [UUID], activeRoot: UUID?) throws -> ForgetPreview {
        var reads: [MemoryReadRevision] = []
        var seedsRoots: Set<UUID> = []
        var seedMessages: Set<UUID> = []
        for id in entryIDs {
            guard let entry = assistant.memory.entry(id) else { throw MemoryError.missing }
            reads.append(MemoryReadRevision(entryID: id, revision: entry.revision))
            seedsRoots.formUnion(entry.sourceRootPromptIDs)
            seedMessages.formUnion(entry.sourceMessageIDs)
        }
        let index = assistant.scopeIndex
        let throughRevision = Dictionary(uniqueKeysWithValues: reads.map { ($0.entryID, $0.revision) })
        for rootID in index.allRootIDs {
            guard let root = index.scopedRoot(rootID) else { continue }
            if root.dependencies.memoryReads.contains(where: { read in
                throughRevision[read.entryID].map { read.revision <= $0 } ?? false
            }) { seedsRoots.insert(rootID) }
        }
        // A source message with a known root masks that whole root; unknown
        // history stays masked by exact message ID.
        var maskedMessages: Set<UUID> = []
        for message in seedMessages {
            if let root = index.root(of: message) { seedsRoots.insert(root) } else { maskedMessages.insert(message) }
        }
        let closure = Self.dependencyClosure(seeds: seedsRoots, messages: maskedMessages, index: index)
        let summaries = assistant.compactions.filter { !closure.isDisjoint(with: $0.sourceRootPromptIDs)
            || !maskedMessages.isDisjoint(with: $0.sourceMessageIDs) }.count
        return ForgetPreview(entries: reads, ledgerRevision: assistant.memory.revision,
                             dependencyRevision: index.dependencyRevision, affectedRoots: closure,
                             maskedMessages: maskedMessages, stopsActiveRoot: activeRoot.map(closure.contains) ?? false,
                             affectedSummaries: summaries)
    }

    /// Reverse reachability over the known read graph: one reverse index and
    /// one breadth-first pass, linear in roots + edges.
    static func dependencyClosure(seeds: Set<UUID>, messages: Set<UUID>, index: ScopeIndex) -> Set<UUID> {
        var readers: [UUID: [UUID]] = [:]
        var messageReaders: [UUID: [UUID]] = [:]
        for rootID in index.allRootIDs {
            guard let deps = index.scopedRoot(rootID)?.dependencies else { continue }
            for target in deps.rootReads { readers[target, default: []].append(rootID) }
            for message in deps.historicalMessageReads { messageReaders[message, default: []].append(rootID) }
        }
        var masked = seeds
        var queue = Array(seeds)
        for message in messages { for reader in messageReaders[message] ?? [] where masked.insert(reader).inserted { queue.append(reader) } }
        // Exact historical reads are registered only for messages without a
        // known root; a source message with a root is a root seed instead.
        for (message, list) in messageReaders where index.root(of: message).map(seeds.contains) == true {
            for reader in list where masked.insert(reader).inserted { queue.append(reader) }
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            for reader in readers[current] ?? [] where masked.insert(reader).inserted { queue.append(reader) }
        }
        return masked
    }

    /// Commits a confirmed preview: recomputed now, any difference refuses.
    /// Masks first, then tombstones (no content), then affected summaries
    /// removed. A remembered-again fact later gets a new ID; masks stay.
    mutating func commitForget(_ preview: ForgetPreview, activeRoot: UUID?, now: Date = Date()) throws -> MemoryReceipt {
        let current = try forgetPreview(preview.entries.map(\.entryID), activeRoot: activeRoot)
        guard current == preview else { throw ForgetError.changed }
        var ledger = assistant.memory
        ledger.revision += 1
        ledger.forgetEpoch += 1
        var scopes: [MemoryScope] = []
        for read in preview.entries {
            guard let index = ledger.active.firstIndex(where: { $0.id == read.entryID }) else { throw MemoryError.missing }
            let entry = ledger.active.remove(at: index)
            scopes.append(entry.scope)
            let tombstone = MemoryTombstone(id: UUID(), entryID: entry.id, throughRevision: entry.revision, target: entry.target,
                                            scope: entry.scope, contentDigest: CanonicalDigest.contentFingerprint(entry.content),
                                            sourceRootPromptIDs: entry.sourceRootPromptIDs, sourceMessageIDs: entry.sourceMessageIDs,
                                            revision: ledger.revision, forgottenAt: now)
            ledger.tombstones.append(tombstone)
            for root in preview.affectedRoots { try assistant.scopeIndex.mask(root: root, by: tombstone.id) }
            for message in preview.maskedMessages { try assistant.scopeIndex.mask(message: message, by: tombstone.id) }
        }
        assistant.memory = ledger
        assistant.compactions.removeAll { !preview.affectedRoots.isDisjoint(with: $0.sourceRootPromptIDs)
            || !preview.maskedMessages.isDisjoint(with: $0.sourceMessageIDs) }
        let receipt = MemoryReceipt(id: UUID(), entryIDs: preview.entries.map(\.entryID), action: "forget",
                                    scope: scopes.first ?? .global, createdAt: now,
                                    result: "已遗忘；\(preview.affectedRootCount) 段相关历史已排除出助理上下文，原文仍保留")
        appendReceipt(receipt)
        return receipt
    }

    // MARK: Read registration

    /// Merges what a model dispatch or read tool actually used into `root`'s
    /// direct dependencies. Self-references and roots already reachable
    /// through another direct read are not stored again.
    mutating func registerReads(root: UUID, memory: [MemoryReadRevision], roots: [UUID], messages: [UUID]) throws {
        guard let scoped = assistant.scopeIndex.scopedRoot(root) else { throw HistoryEditError.missingRoot }
        var deps = scoped.dependencies
        for read in memory where !deps.memoryReads.contains(read) { deps.memoryReads.append(read) }
        let index = assistant.scopeIndex
        for candidate in roots where candidate != root && index.scopedRoot(candidate) != nil && !deps.rootReads.contains(candidate) {
            deps.rootReads.append(candidate)
        }
        deps.rootReads = Self.reduced(deps.rootReads, root: root, index: index)
        for message in messages where !deps.historicalMessageReads.contains(message) { deps.historicalMessageReads.append(message) }
        guard deps != scoped.dependencies else { return }
        try assistant.scopeIndex.updateRoot(root) { $0.dependencies = deps }
    }

    /// Drops direct reads already reachable from another direct read, and any
    /// read that could reach `root` (a cycle). One multi-source traversal from
    /// the candidates' own reads marks every redundant candidate; linear in
    /// the reachable graph, independent of the number of candidates.
    static func reduced(_ reads: [UUID], root: UUID, index: ScopeIndex) -> [UUID] {
        var candidates: [UUID] = []
        var seen: Set<UUID> = []
        for read in reads where read != root && seen.insert(read).inserted { candidates.append(read) }
        let candidateSet = Set(candidates)
        var redundant: Set<UUID> = []
        var visited: Set<UUID> = []
        var stack: [UUID] = []
        for candidate in candidates { stack += index.scopedRoot(candidate)?.dependencies.rootReads ?? [] }
        var reachesRoot = false
        while let next = stack.popLast() {
            guard visited.insert(next).inserted else { continue }
            if next == root { reachesRoot = true }
            if candidateSet.contains(next) { redundant.insert(next) }
            stack += index.scopedRoot(next)?.dependencies.rootReads ?? []
        }
        var kept = candidates.filter { !redundant.contains($0) }
        if reachesRoot {
            // Rare: exclude exactly the candidates that would close a cycle.
            kept = kept.filter { !reaches(from: $0, target: root, index: index) }
        }
        return kept
    }

    static func reaches(from start: UUID, target: UUID, index: ScopeIndex) -> Bool {
        if start == target { return true }
        var visited: Set<UUID> = []
        var stack = [start]
        while let next = stack.popLast() {
            if next == target { return true }
            guard visited.insert(next).inserted else { continue }
            stack += index.scopedRoot(next)?.dependencies.rootReads ?? []
        }
        return false
    }
}
