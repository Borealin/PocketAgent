import Foundation

/// Ephemeral, local-only recognition. Completed input is appended to the draft.
/// Audio ranges identify revisions; text equality cannot deduplicate speech
/// because a person may deliberately repeat the same words.
nonisolated struct DictationInput: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, preparing, recording, finishing, preview }
    private(set) var phase = Phase.idle
    private(set) var sessionID: UUID?
    private(set) var generation: UUID?
    private(set) var finalText = ""
    private(set) var volatileText = ""
    private var finalizedThrough = -Double.infinity

    var busy: Bool { phase == .preparing || phase == .recording || phase == .finishing }
    var canAppend: Bool { phase == .preview && !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    mutating func begin(in sessionID: UUID) -> UUID {
        self = Self()
        self.sessionID = sessionID
        let generation = UUID()
        self.generation = generation
        phase = .preparing
        return generation
    }

    @discardableResult
    mutating func transition(to phase: Phase, generation: UUID) -> Bool {
        guard self.generation == generation, self.phase != phase else { return false }
        self.phase = phase
        if phase == .preview { volatileText = "" }
        return true
    }

    mutating func receive(_ text: String, start: Double, end: Double, final: Bool, generation: UUID) {
        guard self.generation == generation, phase == .recording || phase == .finishing,
              start.isFinite, end.isFinite, end > start, start >= finalizedThrough else { return }
        if final {
            finalText += text
            finalizedThrough = end
            volatileText = ""
        } else { volatileText = text }
    }

    mutating func cancel() { self = Self() }
}
