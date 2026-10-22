import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Natural-language edit/forget: conservative recognition, candidates from
/// the visible ledger, nothing changed without the user's pick and confirmation.
struct MemoryIntentTests {
    @Test func explicitChineseRequestsAreRecognised() {
        let cases: [(String, MemoryIntent.Action, String, String?)] = [
            ("忘掉关于杭州的记忆", .forget, "杭州", nil),
            ("请帮我删除我住在杭州那条记忆。", .forget, "我住在杭州", nil),
            ("删除记忆：PKATEST_GAPS_周五开组会", .forget, "PKATEST_GAPS_周五开组会", nil),
            ("把开会时间的记忆删掉", .forget, "开会时间", nil),
            ("遗忘有关咖啡的记忆", .forget, "咖啡", nil),
            ("/forget 咖啡偏好", .forget, "咖啡偏好", nil),
            ("更正关于开会时间的记忆", .edit, "开会时间", nil),
            ("修改记忆：每周五下午开组会", .edit, "每周五下午开组会", nil),
            ("把开会时间的记忆改成周四下午三点", .edit, "开会时间", "周四下午三点"),
            ("麻烦把关于咖啡的记忆改为不加糖！", .edit, "咖啡", "不加糖"),
        ]
        for (text, action, subject, replacement) in cases {
            let intent = MemoryIntent.parse(text)
            #expect(intent == MemoryIntent(action: action, subject: subject, replacement: replacement), "\(text)")
        }
    }

    @Test func ordinarySentencesAreNotMemoryRequests() {
        for text in ["我忘记带钥匙", "忘记带钥匙了", "我忘记带钥匙了，帮我查一下附近的锁匠", "忘记密码怎么办",
                     "我的记忆力不好", "你忘记了关于我生日的记忆", "你还记得我的记忆吗", "记忆里我住在哪？",
                     "删除这个文件", "帮我更新一下 App", "把这段记忆写成日记", "删除记忆", "忘掉记忆", "更正这条记忆",
                     "忘掉记忆中的杭州", "修改记忆：", "/forget ", "记住：我住在杭州"] {
            #expect(MemoryIntent.parse(text) == nil, "\(text)")
        }
    }

    private func ledger(_ contents: [(String, MemoryScope)]) throws -> HistoryFile {
        var file = HistoryFile.initial(selection: nil)
        for (content, scope) in contents {
            _ = try file.applyMemoryEdit(.add(target: .memory, scope: scope, content: content, origin: .panel,
                                              sourceRootPromptIDs: [], sourceMessageIDs: []))
        }
        return file
    }

    @Test func candidatesComeFromTheVisibleScopeAndMayBeOneManyOrNone() throws {
        let project = UUID(), other = UUID()
        let file = try ledger([("PKATEST_GAPS_我住在杭州西湖区", .global), ("PKATEST_GAPS_杭州出差住在滨江", .workspace(project)),
                               ("PKATEST_GAPS_杭州的朋友叫小王", .workspace(other)), ("PKATEST_GAPS_喜欢喝美式咖啡", .global)])
        let memory = file.assistant.memory
        let hangzhou = try #require(MemoryIntent.parse("忘掉关于杭州的记忆"))
        #expect(hangzhou.candidates(in: memory, scope: .general).map(\.content) == ["PKATEST_GAPS_我住在杭州西湖区"])
        let inProject = hangzhou.candidates(in: memory, scope: .workspace(project)).map(\.content)
        #expect(Set(inProject) == ["PKATEST_GAPS_我住在杭州西湖区", "PKATEST_GAPS_杭州出差住在滨江"])
        #expect(!inProject.contains("PKATEST_GAPS_杭州的朋友叫小王"))
        let none = try #require(MemoryIntent.parse("忘掉关于上海的记忆"))
        #expect(none.candidates(in: memory, scope: .workspace(project)).isEmpty)
        // A single shared character is not a match; the whole phrase is.
        #expect(try #require(MemoryIntent.parse("删除关于州的记忆")).candidates(in: memory, scope: .general).count == 1)
        #expect(try #require(MemoryIntent.parse("删除关于喝茶的记忆")).candidates(in: memory, scope: .general).isEmpty)
    }

    @Test func candidatesFollowCorrectionsAndForgets() throws {
        var file = try ledger([("PKATEST_GAPS_每周五下午开组会", .global)])
        let entry = try #require(file.assistant.memory.active.first)
        let intent = try #require(MemoryIntent.parse("更正关于组会的记忆"))
        #expect(intent.candidates(in: file.assistant.memory, scope: .general).map(\.revision) == [1])
        // Corrected elsewhere after the cards appeared: the card shows the new revision,
        // and an editor opened with revision 1 is refused (CAS).
        _ = try file.applyMemoryEdit(.replace(entryID: entry.id, expectedRevision: 1, content: "PKATEST_GAPS_每周四下午开组会"))
        #expect(intent.candidates(in: file.assistant.memory, scope: .general).map(\.revision) == [2])
        #expect(throws: MemoryError.stale) {
            var stale = file
            _ = try stale.applyMemoryEdit(.replace(entryID: entry.id, expectedRevision: 1, content: "旧版本的更正"))
        }
        // Forgotten meanwhile: the card is gone.
        _ = try file.commitForget(try file.forgetPreview([entry.id], activeRoot: nil), activeRoot: nil)
        #expect(intent.candidates(in: file.assistant.memory, scope: .general).isEmpty)
    }

    @Test func aSettledRequestEmptiesOnlyItsUnchangedDraft() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        try file.editSession(primary) { $0.draft = "忘掉关于杭州的记忆" }
        let draft = ComposerDraft(sessionID: primary, text: "忘掉关于杭州的记忆", draftRevision: 2)
        var later = file
        try later.settleComposerDraft(draft, draftRevision: 3)
        #expect(later.primary?.draft == "忘掉关于杭州的记忆")
        try file.settleComposerDraft(draft, draftRevision: 2)
        #expect(file.primary?.draft == "")
    }
}
