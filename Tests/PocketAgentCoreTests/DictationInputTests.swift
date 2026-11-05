import Foundation
import Testing
@testable import PocketAgentCore

struct DictationInputTests {
    @Test func revisionsReplaceGuessesButRepeatedSpokenWordsRemain() {
        var input = DictationInput()
        let token = input.begin(in: UUID())
        input.transition(to: .recording, generation: token)
        input.receive("猜测", start: 0, end: 1, final: false, generation: token)
        input.receive("你好", start: 0, end: 1, final: false, generation: token)
        #expect(input.finalText.isEmpty && input.volatileText == "你好")
        input.receive("你好", start: 0, end: 1, final: true, generation: token)
        input.receive("你好", start: 0, end: 1, final: true, generation: token)
        input.receive("旧猜测", start: 0, end: 1, final: false, generation: token)
        input.receive("你好", start: 1, end: 2, final: true, generation: token)
        input.receive("未确认", start: 2, end: 3, final: false, generation: token)
        input.transition(to: .preview, generation: token)
        #expect(input.finalText == "你好你好" && input.volatileText.isEmpty)
    }

    @Test func cancellationAndNewSessionRejectLateResults() {
        var input = DictationInput()
        let old = input.begin(in: UUID())
        input.transition(to: .recording, generation: old)
        input.cancel()
        input.receive("迟到", start: 0, end: 1, final: true, generation: old)
        #expect(input.phase == .idle && !input.canAppend)
        let session = UUID(), current = input.begin(in: session)
        let accepted = input.transition(to: .recording, generation: old)
        #expect(!accepted)
        input.transition(to: .recording, generation: current)
        input.receive("迟到", start: 0, end: 1, final: true, generation: old)
        #expect(input.finalText.isEmpty && input.sessionID == session)
    }

    @Test @MainActor func confirmationUsesLatestDraftAndFailedWriteKeepsPreview() throws {
        var file = HistoryFile.initial(selection: nil)
        let id = try #require(file.primary?.id)
        var input = DictationInput()
        let token = input.begin(in: id)
        input.transition(to: .recording, generation: token)
        input.receive("语音", start: 0, end: 1, final: true, generation: token)
        #expect(throws: (any Error).self) { try file.appendDictation(input) }
        input.transition(to: .preview, generation: token)
        try file.editSession(id) { $0.draft = "并发键盘输入" }
        var fail = true
        let owner = HistoryOwner(file: file) { _ in if fail { throw CocoaError(.fileWriteOutOfSpace) } }
        #expect(throws: (any Error).self) { try owner.transact { try $0.appendDictation(input) } }
        #expect(owner.file == file && input.canAppend)
        fail = false
        try owner.transact { try $0.appendDictation(input) }
        input.cancel() // Only consume after the history write succeeds.
        #expect(owner.file.session(id)?.draft == "并发键盘输入\n语音")
        #expect(owner.file.session(id)?.messages == file.session(id)?.messages)
        #expect(owner.file.assistant == file.assistant)
        #expect(throws: (any Error).self) { try owner.transact { try $0.appendDictation(input) } }
    }
}
