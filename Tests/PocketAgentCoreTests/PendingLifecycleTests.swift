import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Every persisted intermediate state of the single pending request, as a
/// restart would find it, plus the pure routing policies.
struct PendingLifecycleTests {
    private func pending(_ session: UUID, _ text: String = "然后查一下航班",
                         attachments: [ChatAttachment] = []) -> PendingNext {
        PendingNext(sessionID: session, prompt: .detached(message: AgentTranscriptMessage(role: .user, text: text),
                                                          attachments: attachments),
                    selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil, backend: .ddi,
                    clipboardAllowed: true, acceptedOrdinal: 3, state: .queued, references: [], acceptedAt: Date())
    }

    private func restart(_ file: HistoryFile) throws -> HistoryFile {
        var decoded = try HistoryCodec.decode(HistoryCodec.encode(file))
        decoded.recoverAfterLaunch()
        return decoded
    }

    @Test func detachedCrashPointNeedsExplicitResumeAndOwnsItsAttachments() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let image = ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1, byteCount: 1)
        try file.acceptPending(pending(primary, attachments: [image]))
        #expect(throws: PendingError.alreadyPending) { try file.acceptPending(pending(primary, "第二件")) }
        #expect(file.referencedAttachmentIDs.contains(image.id))
        let restarted = try restart(file)
        #expect(restarted.assistant.pendingNext?.state == .needsResume && restarted.pendingResumeOption == .detached)
        #expect(restarted.primary?.messages.isEmpty == true)
        var moved = restarted
        let removed = try moved.removeDetachedPending()
        #expect(removed.attachments == [image] && moved.assistant.pendingNext == nil)
    }

    @Test func promotedWithoutPermitResumesWithTheSameIDOnce() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        try file.acceptPending(pending(primary))
        let activated = try file.activatePending(scope: .general)
        #expect(file.primary?.messages.map(\.id) == [activated.prompt.id] && file.primary?.state == .queued)
        let restarted = try restart(file)
        #expect(restarted.pendingResumeOption == .promotedUnstarted(promptID: activated.prompt.id))
        #expect(restarted.primary?.state == .interrupted)
        var resumed = restarted
        try resumed.requeuePending(selection: ModelSelection(providerID: UUID(), modelID: "n"), workspaceID: nil, backend: .wda,
                                   clipboardAllowed: false, ordinal: 9)
        try resumed.commitDispatchPermit(root: activated.prompt.id, sessionID: primary)
        #expect(resumed.primary?.messages.filter { $0.id == activated.prompt.id }.count == 1)
        #expect(resumed.assistant.pendingNext == nil)
    }

    @Test func afterPermitRestartNeverOffersSameIDContinuation() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        try file.acceptPending(pending(primary))
        let activated = try file.activatePending(scope: .general)
        try file.commitDispatchPermit(root: activated.prompt.id, sessionID: primary)
        let restarted = try restart(file)
        #expect(restarted.pendingResumeOption == .none && restarted.primary?.state == .interrupted)
        var again = restarted
        #expect(throws: PendingError.notPromoted) { try again.abandonUnstarted(promptID: activated.prompt.id, detail: "") }
    }

    @Test func abandonUnstartedKeepsOriginalOutOfContextAndReleasesTheSlot() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        try file.acceptPending(pending(primary))
        let activated = try file.activatePending(scope: .general)
        try file.abandonUnstarted(promptID: activated.prompt.id, detail: "已取消，未开始执行。")
        #expect(file.assistant.pendingNext == nil && file.primary?.messages.map(\.id) == [activated.prompt.id])
        #expect(file.assistant.scopeIndex.scopedRoot(activated.prompt.id)?.abandonedUnstarted == true)
        #expect(AssistantContext.eligibleSegments(file, sessionID: primary, before: UUID(), scope: .general).isEmpty)
        #expect(throws: (any Error).self) { try file.commitDispatchPermit(root: activated.prompt.id, sessionID: primary) }
        // A new request may be accepted again.
        try file.acceptPending(pending(primary, "新的请求"))
    }

    @Test func policiesRouteStopFailureForegroundAndStaleJobs() {
        #expect(PendingAdvancePolicy.afterPrimaryTurn(successful: true, foreground: true, stopEpochAtAccept: 2, stopEpochNow: 2) == .advance)
        // Stop raced with a completed turn: held, never auto-advanced.
        #expect(PendingAdvancePolicy.afterPrimaryTurn(successful: true, foreground: true, stopEpochAtAccept: 2, stopEpochNow: 3) != .advance)
        #expect(PendingAdvancePolicy.afterPrimaryTurn(successful: false, foreground: true, stopEpochAtAccept: 2, stopEpochNow: 2) != .advance)
        #expect(PendingAdvancePolicy.afterPrimaryTurn(successful: true, foreground: false, stopEpochAtAccept: 2, stopEpochNow: 2) != .advance)
        #expect(TurnEffectPolicy.blocked(storage: .ready, isCurrent: true, isRunning: true, cancelled: false, terminal: false) == nil)
        #expect(TurnEffectPolicy.blocked(storage: .saveDirty("x"), isCurrent: true, isRunning: true, cancelled: false, terminal: false) != nil)
        // A late callback of a replaced job can never act.
        #expect(TurnEffectPolicy.blocked(storage: .ready, isCurrent: false, isRunning: true, cancelled: false, terminal: false) != nil)
        #expect(TurnEffectPolicy.blocked(storage: .ready, isCurrent: true, isRunning: false, cancelled: false, terminal: false) != nil)
        #expect(TurnEffectPolicy.blocked(storage: .ready, isCurrent: true, isRunning: true, cancelled: true, terminal: false) != nil)
        #expect(TurnEffectPolicy.blocked(storage: .ready, isCurrent: true, isRunning: true, cancelled: false, terminal: true) != nil)
        #expect(NotStartedRoute.route(pendingOrigin: false, cancelled: true) == .restoreDraft)
        #expect(NotStartedRoute.route(pendingOrigin: true, cancelled: true) == .abandon)
        #expect(NotStartedRoute.route(pendingOrigin: true, cancelled: false) == .hold)
    }

    /// iOS expiring the task while context maintenance runs (before any
    /// permit): the turn ends unstarted with the system cause, a pending
    /// request is held with that cause, and nothing is dispatched or replayed.
    @Test func systemExpiryDuringMaintenanceEndsTheTurnUnstartedWithItsCause() {
        var status = ExecutionStatus(modelLabel: "m")
        status.phase = .preparingContext
        status.markSystemExpired()
        status.finish(successful: false, cancelled: true)
        #expect(status.phase == .failed && status.failure == ExecutionStatus.systemExpiredMessage)
        // Not a user Stop: an ordinary send gets its draft back, a pending request is held (not abandoned).
        #expect(NotStartedRoute.route(pendingOrigin: false, cancelled: false) == .restoreDraft)
        #expect(NotStartedRoute.route(pendingOrigin: true, cancelled: false) == .hold)
    }

    @Test func barrierClosedForReplacedJobFailsItsWaitersImmediately() async throws {
        let barrier = TranscriptCommitBarrier()
        barrier.open(epoch: 1)
        let waiting = Task { try await barrier.wait(epoch: 1, .messages([UUID(): "x"]), timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        barrier.close(epoch: 1)
        barrier.open(epoch: 2)
        await #expect(throws: StorageCommitError.jobReplaced) { try await waiting.value }
        // A late commit for the closed epoch cannot satisfy anything.
        barrier.commit(epoch: 1, [UUID(): CommittedMessage(digest: "x")])
        await #expect(throws: StorageCommitError.jobReplaced) {
            try await barrier.wait(epoch: 1, .messages([:]), timeout: .milliseconds(10))
        }
    }
}

/// Sync applies only portable session data from the complete local file and
/// turns primary deletion/divergence into explicit recovery notices.
struct AssistantSyncTests {
    private func portable(_ session: ChatSession) -> PortableSnapshot {
        PortableSnapshot(sessions: [session], sessionTombstones: [], providers: [], providerTombstones: [])
    }

    @Test func pendingSessionIsDeferredAndLocalStateSurvives() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "本地")
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .general)
        _ = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "本机记忆", origin: .panel,
                                          sourceRootPromptIDs: [], sourceMessageIDs: []))
        let base = portable(file.primary!)
        var remote = try #require(PortableSession(file.primary!))
        remote.messages.append(PortableMessage(AgentTranscriptMessage(role: .assistant, text: "远端"), attribution: nil))
        let merged = PortableSnapshot(sessions: [remote])
        try file.acceptPending(PendingNext(sessionID: primary, prompt: .detached(message: AgentTranscriptMessage(role: .user, text: "下一件"), attachments: []),
            selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil, backend: .ddi, clipboardAllowed: true,
            acceptedOrdinal: 1, state: .queued, references: [], acceptedAt: Date()))
        var applied = file
        let skipped = try applied.applyPortable(merged: merged, base: base, deferred: [primary])
        #expect(skipped == 1 && applied.primary?.messages == file.primary?.messages)
        #expect(applied.assistant.pendingNext == file.assistant.pendingNext && applied.assistant.memory == file.assistant.memory)
        // Without deferral the remote extension is adopted, still keeping local assistant state.
        var adopted = file
        adopted.assistant.pendingNext = nil
        _ = try adopted.applyPortable(merged: merged, base: base, deferred: [])
        #expect(adopted.primary?.messages.count == 2 && adopted.assistant.primaryNotice == nil)
        #expect(adopted.assistant.memory == file.assistant.memory)
        // The remote message has no known root: unknown, not automatic context.
        #expect(AssistantContext.eligibleSegments(adopted, sessionID: primary, before: UUID(), scope: .general).first?.messages.count == 1)
    }

    @Test func remoteDeletionAndDivergenceBecomeNoticesNotSilentWinners() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        try file.acceptRoot(AgentTranscriptMessage(role: .user, text: "a"), attachments: [], in: primary, scope: .general)
        let base = portable(file.primary!)
        var deleted = file
        let tombstone = PortableTombstone(id: primary, deletedAtMs: PortableTime.ms(Date()))
        _ = try deleted.applyPortable(merged: PortableSnapshot(deletedSessions: [tombstone]), base: base, deferred: [])
        #expect(deleted.primary == nil)
        if case .remoteDeleted = deleted.assistant.primaryNotice {} else { Issue.record("expected remoteDeleted") }
        try deleted.startNewPrimary(selection: nil)
        #expect(deleted.primary?.messages.isEmpty == true && deleted.assistant.primaryNotice == nil)

        var diverged = file
        var remote = try #require(PortableSession(file.primary!))
        remote.messages[0].text = "远端改写"
        _ = try diverged.applyPortable(merged: PortableSnapshot(sessions: [remote]), base: base, deferred: [])
        if case .diverged = diverged.assistant.primaryNotice {} else { Issue.record("expected diverged") }
        // Same IDs, changed content: the root becomes unknown.
        let root = try #require(file.primary?.messages.first?.id)
        #expect(diverged.assistant.scopeIndex.scopedRoot(root)?.verified == false)
        try diverged.choosePrimary(primary)
        #expect(diverged.assistant.primaryNotice == nil)
    }
}
