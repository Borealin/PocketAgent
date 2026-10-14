import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// "清空对话，保留记忆" on the assistant line.
@MainActor
struct ClearPrimaryTests {
    private let selection = ModelSelection(providerID: UUID(), modelID: "m")
    private let project = UUID()
    private let image = ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1, byteCount: 1)
    private let draftImage = ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1, byteCount: 1)
    private let taskImage = ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1, byteCount: 1)

    private struct Built {
        var file: HistoryFile
        var primary: UUID, task: UUID
        var first: UUID, second: UUID, taskRoot: UUID
        var codeword: UUID, fromChat: UUID
    }

    /// Two primary turns (an image, a read edge), an independent task, a draft,
    /// three memory entries (one forgotten, one saved from the primary chat)
    /// and a summary of the primary line.
    private func built() throws -> Built {
        var file = HistoryFile.initial(selection: selection)
        let primary = file.assistant.primarySessionID
        try file.editSession(primary) { $0.workspaceID = project }
        func turn(_ text: String, attachments: [ChatAttachment] = [], in session: UUID, scope: WorkScope) throws -> UUID {
            let prompt = AgentTranscriptMessage(role: .user, text: text)
            try file.acceptRoot(prompt, attachments: attachments, in: session, scope: scope)
            try file.commitDispatchPermit(root: prompt.id, sessionID: session, scope: scope)
            try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "已记下：" + text), to: session, root: prompt.id)
            try file.editSession(session) { $0.state = .completed }
            return prompt.id
        }
        let first = try turn("PKATEST_CLEAR_对话标记一", attachments: [image], in: primary, scope: .workspace(project))
        let second = try turn("PKATEST_CLEAR_对话标记二", in: primary, scope: .workspace(project))
        try file.registerReads(root: second, memory: [], roots: [first], messages: [])
        let task = ChatSession(selection: selection, title: "独立任务")
        file.sessions.append(task)
        let taskRoot = try turn("PKATEST_CLEAR_独立任务内容", attachments: [taskImage], in: task.id, scope: .general)
        try file.editSession(primary) { $0.draft = "未发送的草稿"; $0.draftAttachments = [draftImage] }
        let codeword = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_CLEAR_暗号是蓝色四十二",
                                                     origin: .command, sourceRootPromptIDs: [], sourceMessageIDs: []))
        let fromChat = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_CLEAR_来自对话的记忆",
                                                     origin: .chatChip, sourceRootPromptIDs: [first], sourceMessageIDs: [first]))
        let gone = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_CLEAR_要遗忘的记忆",
                                                 origin: .chatChip, sourceRootPromptIDs: [second], sourceMessageIDs: []))
        _ = try file.commitForget(try file.forgetPreview(gone.entryIDs, activeRoot: nil), activeRoot: nil)
        let record = AgentCompactionRecord(summaryMessageID: UUID(), compactedThroughMessageID: first, sequence: 1,
                                           summary: "## Goal\nPKATEST_CLEAR_摘要", summarizedTokens: 1, keptTokens: 0,
                                           displayAnchor: Date(timeIntervalSince1970: 1))
        file.assistant.compactions.append(StoredCompaction(
            id: record.id, record: record, sessionID: primary, scope: .workspace(project), sourceRootPromptIDs: [first],
            sourceMessageIDs: [first], predecessorID: nil, predecessorDigest: nil, inputDigest: "input", recordDigest: "record",
            builderVersion: AssistantContext.builderVersion, summaryPromptVersion: AssistantContext.summaryPromptVersion,
            forgetEpoch: 0, summaryModel: "m"))
        return Built(file: file, primary: primary, task: task.id, first: first, second: second, taskRoot: taskRoot,
                     codeword: try #require(codeword.entryIDs.first), fromChat: try #require(fromChat.entryIDs.first))
    }

    @Test func clearingRemovesTheConversationAndKeepsMemoryAndEverythingElse() throws {
        var b = try built()
        let before = b.file
        #expect(before.assistant.scopeIndex.isMasked(root: b.second))
        let fresh = try b.file.clearPrimaryConversation(now: Date(timeIntervalSince1970: 1000))
        let primary = try #require(b.file.primary)
        #expect(fresh != b.primary && primary.id == fresh && b.file.selectedID == fresh)
        #expect(primary.messages.isEmpty && primary.draft.isEmpty && primary.draftAttachments.isEmpty && primary.attachments.isEmpty)
        #expect(primary.title == ChatSession.primaryTitle && primary.selection == selection && primary.workspaceID == project)
        // The old line is gone with a deletion record; nothing else is.
        #expect(b.file.session(b.primary) == nil && b.file.deletedSessions.contains { $0.id == b.primary })
        #expect(b.file.session(b.task) == before.session(b.task) && b.file.sessions.count == before.sessions.count)
        #expect(b.file.assistant.compactions.isEmpty)
        // Memory entries, revisions, sources, tombstones and receipts are unchanged; masks stay.
        #expect(b.file.assistant.memory == before.assistant.memory)
        #expect(b.file.assistant.memoryReceipts == before.assistant.memoryReceipts)
        #expect(b.file.assistant.scopeIndex.isMasked(root: b.second))
        // Membership of the removed history goes; the task's root stays.
        let index = b.file.assistant.scopeIndex
        #expect(index.scopedRoot(b.first) == nil && index.scopedRoot(b.second) == nil && index.scopedRoot(b.taskRoot) != nil)
        // Only the task's image is still referenced (the cleared line's files are collected).
        #expect(b.file.referencedAttachmentIDs == [taskImage.id])
        // The current format round-trips and a restart changes nothing.
        var restarted = try HistoryCodec.decode(HistoryCodec.encode(b.file))
        restarted.recoverAfterLaunch()
        #expect(restarted == b.file && restarted.assistant.primaryNotice == nil)
    }

    @Test func clearedHistoryNeverComesBackThroughContextSearchOrSync() async throws {
        var b = try built()
        let before = b.file
        let fresh = try b.file.clearPrimaryConversation()
        let next = AgentTranscriptMessage(role: .user, text: "继续")
        var withNext = b.file
        try withNext.acceptRoot(next, attachments: [], in: fresh, scope: .workspace(project))
        #expect(AssistantContext.eligibleSegments(withNext, sessionID: fresh, before: next.id, scope: .workspace(project)).isEmpty)
        let snapshot = withNext
        let adapter = PocketMemoryAdapter(scope: .workspace(project), currentRoot: next.id, references: [],
                                          snapshot: { snapshot }, register: { _, _, _ in })
        let history = try await adapter.searchSessions(AgentSessionSearchRequest(query: "PKATEST_CLEAR_对话标记"))
        #expect(history.objectValue?["segments"]?.arrayValue?.isEmpty ?? true)
        let memory = try await adapter.searchMemories(AgentMemorySearchRequest(query: "暗号"))
        #expect(memory.objectValue?["entries"]?.arrayValue?.count == 1)
        // A sync round planned before the clear and applied after it does not
        // bring the old line back or raise a primary notice.
        let base = PortableSnapshot(sessions: before.sessions, sessionTombstones: before.deletedSessions, providers: [],
                                    providerTombstones: [])
        var applied = b.file
        _ = try applied.applyPortable(merged: base, base: base, deferred: [])
        #expect(applied.session(b.primary) == nil && applied.primary?.id == fresh && applied.assistant.primaryNotice == nil)
        #expect(applied.session(b.task) != nil)
        // The next round merges the tombstone over a remote copy of the old line.
        let local = PortableSnapshot(sessions: b.file.sessions, sessionTombstones: b.file.deletedSessions, providers: [],
                                     providerTombstones: [])
        let merged = PortableMerge.merge(local, base)
        // (An empty line is not exported until it has messages.)
        #expect(!merged.sessions.contains { $0.id == b.primary } && merged.deletedSessions.contains { $0.id == b.primary })
    }

    /// A conflict copy of the old line (kept as a visible conversation) holds
    /// the same message IDs: its roots become unknown, so automatic context
    /// and history search cannot read the cleared chat back through it.
    @Test func aConflictCopyOfTheOldLineIsNotReadBackAutomatically() async throws {
        var b = try built()
        var copy = try #require(b.file.primary)
        copy.id = UUID(); copy.title = ChatSession.primaryTitle + PortableMerge.conflictSuffix; copy.conflictOf = b.primary
        copy.draft = ""; copy.draftAttachments = []
        b.file.sessions.append(copy)
        func found(_ file: HistoryFile, current: UUID) async throws -> Int {
            let adapter = PocketMemoryAdapter(scope: .workspace(project), currentRoot: current, references: [],
                                              snapshot: { file }, register: { _, _, _ in })
            let result = try await adapter.searchSessions(AgentSessionSearchRequest(query: "PKATEST_CLEAR_对话标记一"))
            return result.objectValue?["segments"]?.arrayValue?.count ?? 0
        }
        #expect(try await found(b.file, current: UUID()) >= 1)
        try b.file.clearPrimaryConversation()
        #expect(b.file.session(copy.id) != nil && b.file.session(b.task) != nil)
        let index = b.file.assistant.scopeIndex
        #expect(index.scopedRoot(b.first)?.verified == false && index.scopedRoot(b.taskRoot)?.verified == true)
        #expect(AssistantContext.eligibleSegments(b.file, sessionID: copy.id, before: UUID(), scope: .workspace(project)).isEmpty)
        #expect(try await found(b.file, current: UUID()) == 0)
        // The cleared roots keep their identity for forgetting the memory saved from them.
        let preview = try b.file.forgetPreview([b.fromChat], activeRoot: nil)
        #expect(preview.affectedRoots.contains(b.first))
        _ = try HistoryCodec.decode(HistoryCodec.encode(b.file))
    }

    @Test func keptMemoryIsStillRecalledAndCanStillBeForgotten() throws {
        var b = try built()
        try b.file.clearPrimaryConversation()
        let block = MemoryBlock.build(b.file.assistant.memory, scope: .workspace(project), query: "暗号")
        #expect(block.text.contains("蓝色四十二") && block.reads.contains { $0.entryID == b.codeword })
        // Forgetting an entry whose source conversation was cleared still works.
        let preview = try b.file.forgetPreview([b.fromChat], activeRoot: nil)
        #expect(preview.affectedRoots.contains(b.first))
        _ = try b.file.commitForget(preview, activeRoot: nil)
        #expect(!b.file.assistant.memory.active.contains { $0.id == b.fromChat })
        #expect(b.file.assistant.memory.tombstones.contains { $0.entryID == b.fromChat && $0.sourceRootPromptIDs == [b.first] })
        _ = try HistoryCodec.decode(HistoryCodec.encode(b.file))
    }

    @Test func refusedWhileTheLineIsBusyPendingOrNeedsRecovery() throws {
        let b = try built()
        var busy = b.file
        try busy.editSession(b.primary) { $0.state = .running }
        let busyBefore = busy
        #expect(throws: ClearPrimaryError.busy) { try busy.clearPrimaryConversation() }
        #expect(busy == busyBefore)
        var pending = b.file
        try pending.acceptPending(PendingNext(sessionID: b.primary,
            prompt: .detached(message: AgentTranscriptMessage(role: .user, text: "下一件"), attachments: []),
            selection: selection, workspaceID: project, backend: .ddi, clipboardAllowed: true, acceptedOrdinal: 1,
            state: .queued, references: [], acceptedAt: Date()))
        let pendingBefore = pending
        #expect(throws: ClearPrimaryError.pending) { try pending.clearPrimaryConversation() }
        #expect(pending == pendingBefore)
        var notice = b.file
        notice.assistant.primaryNotice = .diverged(copyIDs: [])
        #expect(throws: ClearPrimaryError.notice) { try notice.clearPrimaryConversation() }
    }

    @Test func aFailedWriteChangesNothing() throws {
        let b = try built()
        let owner = HistoryOwner(file: b.file, writer: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(throws: (any Error).self) { try owner.transact { try $0.clearPrimaryConversation() } }
        #expect(owner.file == b.file && owner.file.assistant.primarySessionID == b.primary && owner.health.isReady)
    }

    /// An empty local line is not exported, so a remote copy with the same ID
    /// and history would be adopted into it; clearing replaces it too, and
    /// repeating the clear changes no content.
    @Test func anEmptyLineIsReplacedSoASameIDRemoteHistoryCannotRefillIt() throws {
        var file = HistoryFile.initial(selection: selection)
        let primary = file.assistant.primarySessionID
        try file.editSession(primary) { $0.draft = "草稿"; $0.draftAttachments = [draftImage]; $0.workspaceID = project }
        var remote = ChatSession(id: primary, selection: selection, title: ChatSession.primaryTitle)
        remote.messages = [AgentTranscriptMessage(role: .user, text: "PKATEST_CLEAR_远端旧历史")]
        let merged = PortableSnapshot(sessions: [try #require(PortableSession(remote))])
        let base = PortableSnapshot(sessions: file.sessions, sessionTombstones: file.deletedSessions, providers: [],
                                    providerTombstones: [])
        // Control: without the clear the same-ID remote history fills the empty line.
        var untouched = file
        _ = try untouched.applyPortable(merged: merged, base: base, deferred: [])
        #expect(untouched.primary?.messages.count == 1)
        let fresh = try file.clearPrimaryConversation()
        #expect(fresh != primary && file.deletedSessions.map(\.id) == [primary])
        #expect(file.primary?.draft.isEmpty == true && file.primary?.draftAttachments.isEmpty == true)
        #expect(file.primary?.workspaceID == project && file.primary?.selection == selection)
        var applied = file
        _ = try applied.applyPortable(merged: merged, base: base, deferred: [])
        #expect(applied.primary?.id == fresh && applied.primary?.messages.isEmpty == true && applied.session(primary) == nil)
        #expect(applied.assistant.primaryNotice == nil)
        // Repeating the clear keeps the same content (an empty line, memory and other sessions).
        let once = file
        try file.clearPrimaryConversation()
        #expect(file.primary?.messages.isEmpty == true && file.sessions.count == once.sessions.count)
        #expect(file.assistant.memory == once.assistant.memory && file.referencedAttachmentIDs.isEmpty)
    }
}
