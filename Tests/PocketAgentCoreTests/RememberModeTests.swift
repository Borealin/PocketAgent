import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Remember mode: the primary composer's plain text is saved only through
/// the prefilled editor's confirmation, as one host write.
@MainActor
struct RememberModeTests {
    private let text = "  PKATEST_GAPS_周五下午固定开组会  "

    private func file(draft: String) throws -> HistoryFile {
        var file = HistoryFile.initial(selection: nil)
        try file.editSession(file.assistant.primarySessionID) { $0.draft = draft }
        return file
    }

    private func add(_ content: String, target: AgentMemoryTarget = .memory, scope: MemoryScope = .global) -> UserMemoryEdit {
        .add(target: target, scope: scope, content: content, origin: .panel, sourceRootPromptIDs: [], sourceMessageIDs: [])
    }

    @Test func aConfirmedSaveStoresTheChosenEntryAndEmptiesTheUnchangedDraft() throws {
        var file = try file(draft: text)
        let primary = file.assistant.primarySessionID
        let project = UUID()
        let request = ComposerDraft(sessionID: primary, text: text, draftRevision: 3)
        let receipt = try file.commitComposerMemory(add("PKATEST_GAPS_周五下午固定开组会", scope: .workspace(project)), from: request,
                                                    draftRevision: 3)
        let entry = try #require(file.assistant.memory.active.first)
        #expect(receipt.entryIDs == [entry.id] && entry.revision == 1 && entry.scope == .workspace(project))
        #expect(entry.content == "PKATEST_GAPS_周五下午固定开组会" && entry.origin == .panel)
        #expect(file.session(primary)?.draft == "")
        // The personal-profile target is saved as global.
        var profile = try self.file(draft: "我是左撇子")
        let own = ComposerDraft(sessionID: profile.assistant.primarySessionID, text: "我是左撇子", draftRevision: 0)
        _ = try profile.commitComposerMemory(add("我是左撇子", target: .user), from: own, draftRevision: 0)
        #expect(profile.assistant.memory.active.first?.target == .user && profile.primary?.draft == "")
    }

    @Test func laterDraftEditsAndOtherConversationsAreLeftAlone() throws {
        let base = try file(draft: text)
        let primary = base.assistant.primarySessionID
        let request = ComposerDraft(sessionID: primary, text: text, draftRevision: 3)
        // Typed on after the editor opened: same text again would still be a later edit.
        var edited = base
        _ = try edited.commitComposerMemory(add("PKATEST_GAPS_周五下午固定开组会"), from: request, draftRevision: 4)
        #expect(edited.assistant.memory.active.count == 1 && edited.session(primary)?.draft == text)
        // The draft text itself changed (another writer).
        var changed = base
        try changed.editSession(primary) { $0.draft = "别的内容" }
        _ = try changed.commitComposerMemory(add("PKATEST_GAPS_周五下午固定开组会"), from: request, draftRevision: 3)
        #expect(changed.session(primary)?.draft == "别的内容")
        // The conversation was cleared meanwhile: the entry is still saved, nothing else is touched.
        var cleared = base
        try cleared.clearPrimaryConversation()
        let fresh = cleared.assistant.primarySessionID
        try cleared.editSession(fresh) { $0.draft = "新对话的草稿" }
        _ = try cleared.commitComposerMemory(add("PKATEST_GAPS_周五下午固定开组会"), from: request, draftRevision: 3)
        #expect(fresh != primary && cleared.session(fresh)?.draft == "新对话的草稿" && cleared.assistant.memory.active.count == 1)
    }

    @Test func aRefusedOrUnwrittenSaveKeepsTheDraftAndSavesNothing() throws {
        let base = try file(draft: text)
        let primary = base.assistant.primarySessionID
        let request = ComposerDraft(sessionID: primary, text: text, draftRevision: 0)
        for edit in [add("   "), add(String(repeating: "长", count: MemoryLimits.entryScalars + 1)),
                     add("我是左撇子", target: .user, scope: .workspace(UUID()))] {
            let owner = HistoryOwner(file: base, writer: { _ in })
            #expect(throws: (any Error).self) {
                try owner.transact { _ = try $0.commitComposerMemory(edit, from: request, draftRevision: 0) }
            }
            #expect(owner.file == base)
        }
        let unwritable = HistoryOwner(file: base, writer: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(throws: (any Error).self) {
            try unwritable.transact { _ = try $0.commitComposerMemory(add("PKATEST_GAPS_周五下午固定开组会"), from: request, draftRevision: 0) }
        }
        #expect(unwritable.file == base && unwritable.file.session(primary)?.draft == text)
        // The strict command keeps its direct path; plain text is not a command.
        #expect(MemoryCommand.parse("记住：PKATEST_GAPS_x")?.content == "PKATEST_GAPS_x" && MemoryCommand.parse(text) == nil)
    }
}
