import AgentKit
import Foundation

/// What a read-only search intends to return, by identity only (planned from
/// an earlier snapshot; never content).
nonisolated enum ReadPlan: Sendable {
    case memory([SearchPageCache.Memory], target: AgentMemoryTarget?)
    case segments([SearchPageCache.Segment])
}

/// Content taken from the latest file in the same edit that verified and
/// registered it.
nonisolated enum ReadCommitResult: Sendable {
    struct Segment: Sendable {
        var plan: SearchPageCache.Segment
        var title: String
        var messages: [AgentTranscriptMessage]
    }
    case memory([MemoryRecord])
    case segments([Segment])
}

/// A planned result no longer matches the latest history (corrected, forgotten,
/// rewritten, deleted, masked or no longer eligible): nothing was registered.
nonisolated struct ReadStale: Error, Equatable {}

nonisolated extension HistoryFile {
    /// Verifies a planned search page against this (latest) file, registers
    /// exactly what it returns as reads of `root` and returns the content, in
    /// one edit. Applied inside the owner's transaction, so no await separates
    /// the check, the registration and the content: a forget committed before
    /// this edit makes the page stale; one committed after it finds `root` among
    /// the readers. A masked `root` stops its run, and so does a root that is
    /// no longer the started run it was frozen as (scope, permit, verification).
    mutating func commitRead(_ plan: ReadPlan, root: UUID, scope: WorkScope,
                             references: [HistoryReference]) throws -> ReadCommitResult {
        let index = assistant.scopeIndex
        guard let current = index.scopedRoot(root), current.scope == scope, current.dispatchAuthorized,
              !current.abandonedUnstarted, current.verified else { throw StorageCommitError.jobReplaced }
        if index.isMasked(root: root) { throw ContextSourceRevoked() }
        switch plan {
        case .memory(let items, let target):
            var records: [MemoryRecord] = []
            for item in items {
                guard let entry = assistant.memory.entry(item.id), entry.revision == item.revision,
                      entry.scope.visible(in: scope), target == nil || entry.target == target else { throw ReadStale() }
                records.append(entry)
            }
            if !records.isEmpty {
                try registerReads(root: root, memory: records.map { MemoryReadRevision(entryID: $0.id, revision: $0.revision) },
                                  roots: [], messages: [])
            }
            return .memory(records)
        case .segments(let items):
            var result: [ReadCommitResult.Segment] = []
            var roots: [UUID] = [], unknown: [UUID] = []
            var byID: [UUID: [UUID: AgentTranscriptMessage]] = [:]
            for item in items {
                guard let session = session(item.sessionID) else { throw ReadStale() }
                if byID[session.id] == nil {
                    byID[session.id] = Dictionary(session.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                }
                let messages = item.messageIDs.compactMap { byID[session.id]?[$0] }
                guard messages.count == item.messageIDs.count, !messages.isEmpty,
                      (try? AssistantContext.referenceDigest(messages)) == item.digest,
                      !messages.contains(where: { message in
                          index.isMasked(message: message.id) || index.root(of: message.id).map(index.isMasked(root:)) == true
                      }) else { throw ReadStale() }
                if let segmentRoot = item.root {
                    guard segmentRoot != root, let scoped = index.scopedRoot(segmentRoot), scoped.verified,
                          scoped.scope == scope, scoped.dispatchAuthorized, !scoped.abandonedUnstarted,
                          !index.isMasked(root: segmentRoot),
                          messages.allSatisfy({ index.root(of: $0.id) == segmentRoot }) else { throw ReadStale() }
                    // The unfinished last segment of a session still being written is not history.
                    if [.queued, .running, .cancelling].contains(session.state),
                       session.messages.last.flatMap({ index.root(of: $0.id) }) == segmentRoot { throw ReadStale() }
                    roots.append(segmentRoot)
                } else {
                    // A window the user referenced explicitly, still with the digest they chose.
                    guard references.contains(where: { $0.sessionID == item.sessionID && $0.expectedContentDigest == item.digest
                        && $0.firstMessageID == item.messageIDs.first && $0.lastMessageID == item.messageIDs.last }) else {
                        throw ReadStale()
                    }
                    unknown += messages.filter { index.root(of: $0.id) == nil }.map(\.id)
                    for message in messages { if let r = index.root(of: message.id), !roots.contains(r) { roots.append(r) } }
                }
                result.append(.init(plan: item, title: session.title, messages: messages))
            }
            if !roots.isEmpty || !unknown.isEmpty {
                try registerReads(root: root, memory: [], roots: roots, messages: unknown)
            }
            return .segments(result)
        }
    }
}

/// The owner side of a read-only search: one MainActor transaction after the
/// run's ownership and storage are checked. Stale and revoked outcomes pass
/// through. Any other failure registered and returned nothing, and it stops
/// the run: AgentKit turns a thrown tool error into an ordinary error result,
/// so the run's commit epoch is failed here, which denies every later tool
/// dispatch and fails the next model request. Like any user transaction, the
/// failed write published nothing and leaves storage health as it was.
@MainActor
enum ReadCommitGate {
    static func commit(_ plan: ReadPlan, owner: HistoryOwner, root: UUID, scope: WorkScope,
                       references: [HistoryReference], epoch: UInt64, isActive: () -> Bool) throws -> ReadCommitResult {
        do {
            try Task.checkCancellation()
            guard isActive() else { throw StorageCommitError.jobReplaced }
            guard owner.health.isReady else { throw StorageCommitError.storageUnavailable }
            var result: ReadCommitResult?
            do { try owner.transact { result = try $0.commitRead(plan, root: root, scope: scope, references: references) } }
            catch let error as ReadStale { throw error }
            catch let error as ContextSourceRevoked { throw error }
            catch let error as StorageCommitError { throw error }
            catch { throw StorageCommitError.saveFailed(error.localizedDescription) }
            guard let result else { throw ReadStale() }
            return result
        } catch let error as StorageCommitError {
            owner.barrier.fail(epoch: epoch, error)
            throw error
        }
    }
}
