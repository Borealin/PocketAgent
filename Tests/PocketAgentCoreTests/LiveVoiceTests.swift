import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct LiveVoiceTests {
    private func event(_ json: String) throws -> LiveWire.Received { try LiveWire.decode(Data(json.utf8)) }
    private func active() throws -> (LiveVoiceState, UUID) {
        var state = LiveVoiceState()
        let token = state.begin(in: UUID()); state.connecting()
        _ = try state.receive(event(#"{"type":"session.started","event_id":"start","session":{"id":"live_fixture","model":"gpt-live-1"}}"#), generation: token)
        return (state, token)
    }

    @Test func boundOriginAndStartedGateAudioWithoutGuessingCompatibility() throws {
        var settings = LiveVoiceSettings(endpoint: "https://voice.example.invalid:443/prefix/live/sessions")
        #expect(throws: (any Error).self) { try settings.socketURL(boundOrigins: ["https://other.example.invalid"]) }
        let socket = try settings.socketURL(boundOrigins: ["https://voice.example.invalid"])
        #expect(socket.scheme == "wss" && socket.path == "/prefix/live/sessions")
        settings.endpoint += "?token=fixture"
        #expect(throws: (any Error).self) { try settings.socketURL(boundOrigins: ["https://voice.example.invalid"]) }
        var state = LiveVoiceState()
        let token = state.begin(in: UUID())
        let audio = try event(#"{"type":"session.output_audio.delta","delta":"AAAAAA=="}"#)
        #expect(!state.mayUpload)
        #expect(try !state.receive(audio, generation: token))
        state.connecting()
        _ = try state.receive(event(#"{"type":"session.started","session":{"id":"live_fixture","model":"gpt-live-1"}}"#), generation: token)
        #expect(state.mayUpload)
        // Primary audio has no event ID. Repeated identical chunks are real samples.
        #expect(try state.receive(audio, generation: token))
        #expect(try state.receive(audio, generation: token))
        let start = try #require(try JSONSerialization.jsonObject(with: Data(LiveWire.start().utf8)) as? [String: Any])
        let config = try #require(start["session"] as? [String: Any])
        #expect(config["store"] as? Bool == false && config["model"] as? String == "gpt-live-1")
        let context = try LiveWire.context(String(repeating: "😀", count: 500), delegation: nil, spoken: true)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        #expect((object["content"] as? String)?.utf8.count == 400 && object["delegation_id"] is NSNull)
    }

    @Test @MainActor func confirmedCardAcceptsOnceAndKeepsKeyboardPhotosAndSelection() throws {
        var (state, token) = try active()
        let text = try event(#"{"type":"session.input_transcript.delta","event_id":"t1","delta":"周四，周四","start_ms":0,"end_ms":1000}"#)
        _ = try state.receive(text, generation: token)
        _ = try state.receive(text, generation: token)
        _ = try state.receive(event(#"{"type":"session.delegation.created","event_id":"d1","offset_ms":1000,"delegation":{"id":"delegation","target":"client"}}"#), generation: token)
        let card = try #require(state.card)
        #expect(card.text == "周四，周四")
        _ = try state.receive(event(#"{"type":"session.input_transcript.delta","event_id":"t2","delta":"不是周五","start_ms":1000,"end_ms":2000}"#), generation: token)
        #expect(state.card?.text == card.text) // A late fragment never edits the visible confirmation.
        state.card?.text = "改成周四，不是周五"
        let candidate = state.beginConfirmation(card.id)
        let confirmed = try #require(candidate)
        #expect(state.beginConfirmation(card.id) == nil)
        var file = HistoryFile.initial(selection: ModelSelection(providerID: UUID(), modelID: "frozen-model"))
        let id = try #require(file.primary?.id)
        let photo = ChatAttachment(id: UUID(), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1, byteCount: 4)
        try file.editSession(id) { $0.draft = "键盘草稿"; $0.draftAttachments = [photo] }
        var fail = true
        let owner = HistoryOwner(file: file) { _ in if fail { throw CocoaError(.fileWriteOutOfSpace) } }
        let message = AgentTranscriptMessage(role: .user, text: confirmed)
        let accept: (inout HistoryFile) throws -> Void = { value in
            try value.acceptRoot(message, attachments: [], in: id, scope: .general)
            try value.settleAcceptedDraft(in: id, consume: false, keepImages: false)
        }
        #expect(throws: (any Error).self) { try owner.transact(accept) }
        state.settleConfirmation(card.id, accepted: false)
        #expect(owner.file == file && state.card?.confirming == false)
        _ = state.beginConfirmation(card.id); fail = false
        try owner.transact(accept)
        state.settleConfirmation(card.id, accepted: true)
        #expect(state.beginConfirmation(card.id) == nil)
        #expect(owner.file.session(id)?.messages.map(\.id) == [message.id])
        #expect(owner.file.session(id)?.draft == "键盘草稿" && owner.file.session(id)?.draftAttachments == [photo])
        #expect(owner.file.session(id)?.selection == file.session(id)?.selection)
        _ = try state.receive(event(#"{"type":"session.delegation.created","event_id":"d2","offset_ms":2000,"delegation":{"id":"delegation","target":"client"}}"#), generation: token)
        #expect(state.card == nil)
    }

    @Test func muteCloseAndLateEventsNeverReopenOrInventFinalUsage() throws {
        var (state, token) = try active()
        let requested = state.requestMute()
        let command = try #require(requested)
        #expect(!state.mayUpload)
        _ = try state.receive(.init(id: "mute", event: .muted(true, command: command.id)), generation: token)
        #expect(state.muted && !state.mayUpload)
        _ = try state.receive(.init(id: "usage1", event: .usage(12)), generation: token)
        _ = try state.receive(.init(id: "usage2", event: .usage(15)), generation: token)
        #expect(state.seconds == 15 && !state.finalUsage)
        state.close()
        #expect(try !state.receive(.init(id: "late", event: .delegation("late")), generation: token))
        _ = try state.receive(event(#"{"type":"session.closed","event_id":"closed","reason":"close_requested","session":{"status":"active"},"usage":{"seconds":16}}"#), generation: token)
        #expect(state.phase == .ended && state.finalUsage && state.seconds == 16)
        let new = state.begin(in: UUID())
        #expect(try !state.receive(.init(id: "old", event: .started("old")), generation: token))
        #expect(state.generation == new && state.phase == .preparing && !state.mayUpload)
        state.finish() // Transport loss without session.closed does not claim finalization.
        #expect(!state.finalUsage && !state.running)
        let error = try event(#"{"type":"error","error":{"code":null,"message":"secret must never escape"}}"#)
        #expect(error.event == .rejected(code: "unknown", command: nil))
    }
}
