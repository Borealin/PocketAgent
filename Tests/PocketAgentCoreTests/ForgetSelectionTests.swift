import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// The forget panel shows exactly what its preview computed: a selection made
/// on an older revision is refused, and a change after opening refreshes the
/// shown content and revision before anything can be forgotten.
@MainActor
struct ForgetSelectionTests {
    private func file() throws -> (HistoryFile, MemoryRecord) {
        var file = HistoryFile.initial(selection: nil)
        _ = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GAPS_A：每周五开组会", origin: .panel,
                                          sourceRootPromptIDs: [], sourceMessageIDs: []))
        return (file, try #require(file.assistant.memory.active.first))
    }

    private func correct(_ file: inout HistoryFile, _ entry: MemoryRecord) throws {
        _ = try file.applyMemoryEdit(.replace(entryID: entry.id, expectedRevision: entry.revision, content: "PKATEST_GAPS_B：每周四开组会"))
    }

    /// A card or panel row rendered at revision 1, corrected before the tap.
    @Test func aSelectionOfAnOlderRevisionIsRefused() throws {
        var (file, shown) = try file()
        try correct(&file, shown)
        #expect(throws: MemoryError.stale) {
            _ = try file.forgetPreview(selected: [MemoryReadRevision(entryID: shown.id, revision: shown.revision)], activeRoot: nil)
        }
        let current = try #require(file.assistant.memory.entry(shown.id))
        let preview = try file.forgetPreview(selected: [MemoryReadRevision(entryID: current.id, revision: 2)], activeRoot: nil)
        #expect(preview.shown.map(\.content) == ["PKATEST_GAPS_B：每周四开组会"] && preview.entries.map(\.revision) == [2])
    }

    /// The panel was opened showing A; B was saved before the confirmation.
    @Test func aChangeAfterOpeningIsRefusedAndTheRefreshShowsTheLatest() throws {
        let (base, shown) = try file()
        let opened = try base.forgetPreview(selected: [MemoryReadRevision(entryID: shown.id, revision: 1)], activeRoot: nil)
        #expect(opened.shown.map(\.content) == ["PKATEST_GAPS_A：每周五开组会"])
        var changed = base
        try correct(&changed, shown)
        let owner = HistoryOwner(file: changed, writer: { _ in })
        #expect(throws: ForgetError.changed) { try owner.transact { _ = try $0.commitForget(opened, activeRoot: nil) } }
        #expect(owner.file == changed)
        // The refreshed panel shows B at revision 2; only its confirmation forgets B.
        let refreshed = try owner.file.forgetPreview([shown.id], activeRoot: nil)
        #expect(refreshed.shown.map(\.content) == ["PKATEST_GAPS_B：每周四开组会"] && refreshed.shown.map(\.revision) == [2])
        try owner.transact { _ = try $0.commitForget(refreshed, activeRoot: nil) }
        #expect(owner.file.assistant.memory.active.isEmpty)
        #expect(owner.file.assistant.memory.tombstones.map(\.throughRevision) == [2])
    }

    @Test func aMissingEntryCannotBePreviewedOrConfirmed() throws {
        var (file, shown) = try file()
        let opened = try file.forgetPreview([shown.id], activeRoot: nil)
        _ = try file.commitForget(opened, activeRoot: nil)
        #expect(throws: MemoryError.missing) {
            _ = try file.forgetPreview(selected: [MemoryReadRevision(entryID: shown.id, revision: 1)], activeRoot: nil)
        }
        #expect(throws: MemoryError.missing) { _ = try file.forgetPreview([shown.id], activeRoot: nil) }
        #expect(throws: (any Error).self) { _ = try file.commitForget(opened, activeRoot: nil) }
    }
}
