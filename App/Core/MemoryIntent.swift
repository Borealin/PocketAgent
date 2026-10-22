import Foundation

/// An explicit request in the primary composer to correct or forget saved
/// memory, recognised conservatively: an edit/forget verb at the start (after
/// an optional polite prefix) and the word 记忆, or `/forget`. Plain sentences
/// such as "我忘记带钥匙" are ordinary messages. It only finds candidates; the
/// user picks one, and the existing editor (CAS by revision) or the final
/// forget preview does the rest. No model, no automatic change.
nonisolated struct MemoryIntent: Equatable, Sendable {
    enum Action: Equatable, Sendable { case edit, forget }

    let action: Action
    /// The words that identify the entry.
    let subject: String
    /// For an edit, the new text the user already gave ("改成…").
    let replacement: String?

    private static let polite = #"^(?:请|麻烦|帮我|请帮我|麻烦你|麻烦帮我)*"#
    private static let forgetVerbs = "忘掉|忘记|遗忘|删除|删掉|移除|去掉"
    private static let editVerbs = "更正|修改|改正|编辑|更新"
    private static let which = "(?:的|这条|那条|这些|那些|这个|那个)?"
    private static let about = "(?:关于|有关)?"

    private static let patterns: [(Action, String, hasReplacement: Bool)] = [
        (.forget, "(?:\(forgetVerbs))(?:这条|那条)?记忆[：:\\s]+(.+)", false),
        (.forget, "(?:\(forgetVerbs))\(about)(.+?)\(which)记忆", false),
        (.forget, "把\(about)(.+?)\(which)记忆(?:忘掉|忘了|删掉|删了|删除|遗忘|去掉)", false),
        (.edit, "把\(about)(.+?)\(which)记忆(?:改成|改为|更正为|更新为|修改为)(.+)", true),
        (.edit, "(?:\(editVerbs))(?:一下)?(?:这条|那条)?记忆[：:\\s]+(.+)", false),
        (.edit, "(?:\(editVerbs))(?:一下)?\(about)(.+?)\(which)记忆", false),
    ]

    static func parse(_ draft: String) -> MemoryIntent? {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, "。.!！?？".contains(last) { text.removeLast() }
        guard !text.isEmpty, text.count <= 200 else { return nil }
        if text.hasPrefix("/forget ") {
            let subject = String(text.dropFirst("/forget ".count)).trimmingCharacters(in: .whitespaces)
            return subject.isEmpty ? nil : MemoryIntent(action: .forget, subject: subject, replacement: nil)
        }
        guard text.contains("记忆") else { return nil }
        for (action, body, hasReplacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: polite + body + "$"),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let subjectRange = Range(match.range(at: 1), in: text) else { continue }
            let subject = String(text[subjectRange]).trimmingCharacters(in: .whitespaces)
            guard !subject.isEmpty, subject != "这条", subject != "那条" else { continue }
            var replacement: String?
            if hasReplacement, let range = Range(match.range(at: 2), in: text) {
                replacement = String(text[range]).trimmingCharacters(in: .whitespaces)
                if replacement?.isEmpty == true { continue }
            }
            return MemoryIntent(action: action, subject: subject, replacement: replacement)
        }
        return nil
    }

    static let candidateLimit = 5

    /// Entries visible in `scope` that the subject actually matches (a term of
    /// two or more characters, or the whole phrase), best first, at most five.
    func candidates(in ledger: MemoryLedger, scope: WorkScope) -> [MemoryRecord] {
        let terms = MemorySearch.terms(subject)
        guard !terms.isEmpty else { return [] }
        let phrase = subject.count <= 64 ? subject : ""
        let scored = ledger.visible(in: scope).compactMap { entry -> (MemoryRecord, Int)? in
            let score = MemorySearch.score(entry.content, terms: terms, phrase: phrase)
            return score >= 2 ? (entry, score) : nil
        }
        return scored.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            if left.0.updatedAt != right.0.updatedAt { return left.0.updatedAt > right.0.updatedAt }
            return left.0.id.uuidString < right.0.id.uuidString
        }.prefix(Self.candidateLimit).map(\.0)
    }
}

/// The composer draft a host memory operation came from: its session, its
/// exact text and its local edit count when the operation began.
nonisolated struct ComposerDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    let sessionID: UUID
    let text: String
    let draftRevision: Int
}

/// A recognised edit/forget request waiting for the user's pick.
nonisolated struct MemoryIntentRequest: Identifiable, Equatable, Sendable {
    var id: UUID { draft.id }
    let intent: MemoryIntent
    let draft: ComposerDraft
}

nonisolated extension HistoryFile {
    /// Empties the composer draft an operation came from, only if it is
    /// unchanged (text and edit count) and its session still exists.
    mutating func settleComposerDraft(_ draft: ComposerDraft, draftRevision: Int) throws {
        guard draftRevision == draft.draftRevision, session(draft.sessionID)?.draft == draft.text else { return }
        try editSession(draft.sessionID) { $0.draft = "" }
    }
}
