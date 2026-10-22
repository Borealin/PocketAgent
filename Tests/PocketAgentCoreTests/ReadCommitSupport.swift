import AgentKit
import Foundation
@testable import PocketAgentCore

/// Thread-safe stand-in for the owner's latest file in adapter tests.
final class FileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HistoryFile
    init(_ value: HistoryFile) { self.value = value }
    var file: HistoryFile { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    func edit<T>(_ change: (inout HistoryFile) throws -> T) rethrows -> T {
        try lock.withLock { var copy = value; let result = try change(&copy); value = copy; return result }
    }
}

extension PocketMemoryAdapter {
    /// An adapter whose commit applies `commitRead` to the box's latest file in
    /// one step, as the owner transaction does; a failed write publishes nothing.
    static func testing(_ box: FileBox, scope: WorkScope, currentRoot: UUID, references: [HistoryReference] = [],
                        snapshot: (@Sendable () async -> HistoryFile)? = nil,
                        writeFails: @escaping @Sendable () -> Bool = { false }) -> PocketMemoryAdapter {
        PocketMemoryAdapter(scope: scope, currentRoot: currentRoot, references: references,
            snapshot: snapshot ?? { box.file },
            commit: { plan in
                try box.edit { file in
                    var candidate = file
                    let result = try candidate.commitRead(plan, root: currentRoot, scope: scope, references: references)
                    if writeFails() { throw StorageCommitError.saveFailed("磁盘已满") }
                    file = candidate
                    return result
                }
            })
    }
}

extension HistoryFile {
    /// The prompt of the run that searches: accepted and started in `session`.
    mutating func acceptCurrent(_ text: String, in session: UUID, scope: WorkScope) throws -> UUID {
        let prompt = AgentTranscriptMessage(role: .user, text: text)
        try acceptRoot(prompt, attachments: [], in: session, scope: scope)
        try commitDispatchPermit(root: prompt.id, sessionID: session, scope: scope)
        return prompt.id
    }
}
