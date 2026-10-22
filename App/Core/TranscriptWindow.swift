import AgentKit
import Foundation

/// A display-only page. It never edits the transcript or its call/result order.
nonisolated struct TranscriptWindow {
    var messages: [AgentTranscriptMessage]
    private(set) var items: [TranscriptItem]
    let hiddenCount: Int
    let totalCount: Int
    private let liveIndex: Int?
    private let liveItemIndex: Int?

    init(history: [AgentTranscriptMessage], partial: AgentTranscriptMessage?, pendingSteering: Set<UUID>, limit: Int) {
        let inserted = partial.map { live in !history.contains { $0.id == live.id } } ?? false
        let insertion = inserted ? (history.firstIndex { pendingSteering.contains($0.id) } ?? history.endIndex) : history.endIndex
        let count = history.count + (inserted ? 1 : 0)
        func message(at index: Int) -> AgentTranscriptMessage {
            if inserted, index == insertion { return partial! }
            return history[index - (inserted && index > insertion ? 1 : 0)]
        }
        var start = max(0, count - max(1, limit))
        // Keep the assistant call when the visible page would start at its result.
        while start > 0, start < count, message(at: start).role == .tool { start -= 1 }
        messages = (start..<count).map { message(at: $0) }
        items = TranscriptItem.build(messages)
        hiddenCount = start
        totalCount = count
        liveIndex = inserted && insertion >= start ? insertion - start : nil
        liveItemIndex = inserted ? items.firstIndex {
            if case .message(let message) = $0 { message.id == partial?.id } else { false }
        } : nil
    }

    /// Replace only the visible live row; the saved page is shared until this write.
    func displaying(_ partial: AgentTranscriptMessage?) -> Self {
        guard let liveIndex, let partial, messages[liveIndex].id == partial.id else { return self }
        var result = self
        result.messages[liveIndex] = partial
        if let liveItemIndex, partial.toolCalls.isEmpty {
            result.items[liveItemIndex] = .message(partial)
        } else {
            result.items = TranscriptItem.build(result.messages)
        }
        return result
    }
}

/// History is projected once per committed/staged revision, not once per token.
nonisolated struct TranscriptWindowCache {
    private struct Key: Equatable {
        var session: UUID
        var revision: Int
        var limit: Int
        var live: UUID?
        var pending: Set<UUID>
    }
    private var key: Key?
    private var window: TranscriptWindow?
    private(set) var rebuilds = 0

    mutating func page(session: UUID, revision: Int, history: [AgentTranscriptMessage], partial: AgentTranscriptMessage?,
                       pendingSteering: Set<UUID>, limit: Int) -> TranscriptWindow {
        let current = Key(session: session, revision: revision, limit: limit, live: partial?.id, pending: pendingSteering)
        if key != current || window == nil {
            window = TranscriptWindow(history: history, partial: partial, pendingSteering: pendingSteering, limit: limit)
            key = current
            rebuilds += 1
        }
        return window!.displaying(partial)
    }
}
