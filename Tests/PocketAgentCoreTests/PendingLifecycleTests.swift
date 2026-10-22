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
        try resumed.commitDispatchPermit(root: activated.prompt.id, sessionID: primary, scope: .general)
        #expect(resumed.primary?.messages.filter { $0.id == activated.prompt.id }.count == 1)
        #expect(resumed.assistant.pendingNext == nil)
    }

    /// A promoted request that never started in project A is continued after
    /// the user switched to project B or to no project: its root moves to the
    /// confirmed scope in the same write and keeps its ID once and its
    /// registered reads; the run's results never become A's automatic context
    /// or search results; the permit refuses a run whose scope differs.
    @Test func continuingAnUnstartedRequestInAnotherScopeMovesItsRoot() async throws {
        let a = UUID(), b = UUID()
        for target in [WorkScope.workspace(b), .general] {
            var file = HistoryFile.initial(selection: nil)
            let primary = file.assistant.primarySessionID
            let earlier = AgentTranscriptMessage(role: .user, text: "A项目里的旧任务")
            try file.acceptRoot(earlier, attachments: [], in: primary, scope: .workspace(a))
            try file.commitDispatchPermit(root: earlier.id, sessionID: primary, scope: .workspace(a))
            try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "A的结果"), to: primary, root: earlier.id)
            try file.acceptPending(pending(primary, "整理一下报销单"))
            let promptID = try file.activatePending(scope: .workspace(a)).prompt.id
            // Context maintenance read the earlier A turn before startup failed.
            try file.registerReads(root: promptID, memory: [], roots: [earlier.id], messages: [])
            try file.holdPending("启动失败")
            let workspaceID: UUID? = { if case .workspace(let id) = target { return id }; return nil }()
            try file.requeuePending(selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: workspaceID,
                                    backend: .ddi, clipboardAllowed: true, ordinal: 5)
            let root = try #require(file.assistant.scopeIndex.scopedRoot(promptID))
            #expect(root.scope == target && root.dependencies.rootReads == [earlier.id] && !root.dispatchAuthorized)
            var mismatch = file
            #expect(throws: (any Error).self) {
                try mismatch.commitDispatchPermit(root: promptID, sessionID: primary, scope: .workspace(a))
            }
            try file.commitDispatchPermit(root: promptID, sessionID: primary, scope: target)
            try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "报销单已整理"), to: primary, root: promptID)
            try file.editSession(primary) { $0.state = .completed }
            #expect(file.primary?.messages.filter { $0.id == promptID }.count == 1)
            let next = AgentTranscriptMessage(role: .user, text: "A项目继续")
            try file.acceptRoot(next, attachments: [], in: primary, scope: .workspace(a))
            #expect(AssistantContext.eligibleSegments(file, sessionID: primary, before: next.id, scope: .workspace(a)).map(\.root)
                    == [earlier.id])
            #expect(AssistantContext.eligibleSegments(file, sessionID: primary, before: next.id, scope: target).map(\.root)
                    == [promptID])
            let snapshot = file
            // Each search runs from a started root of the scope it searches.
            func search(_ scope: WorkScope) async throws -> Int {
                var copy = snapshot
                let current = try copy.acceptCurrent("查找", in: primary, scope: scope)
                let adapter = PocketMemoryAdapter.testing(FileBox(copy), scope: scope, currentRoot: current)
                let result = try await adapter.searchSessions(AgentSessionSearchRequest(query: "报销"))
                return result.objectValue?["segments"]?.arrayValue?.count ?? 0
            }
            #expect(try await search(.workspace(a)) == 0)
            #expect(try await search(target) == 1)
        }
    }

    @Test func afterPermitRestartNeverOffersSameIDContinuation() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        try file.acceptPending(pending(primary))
        let activated = try file.activatePending(scope: .general)
        try file.commitDispatchPermit(root: activated.prompt.id, sessionID: primary, scope: .general)
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
        #expect(throws: (any Error).self) { try file.commitDispatchPermit(root: activated.prompt.id, sessionID: primary, scope: .general) }
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

/// Review finding R9: an ordinary primary send T1 ends before its startup
/// permit (preparation failure, system expiry, startup failure) while a
/// detached pending request P waits. The controller settles P in `notStarted`
/// / `finished` with `PrimaryTurnSettlement.settle` before `finish`, and
/// `advancePendingIfReady` (scheduled by `finish`, and on returning to the
/// foreground) appends and enqueues P only on `PendingActivation.activate`.
/// These are the functions the controller calls, on a real `HistoryOwner`
/// whose writes can fail; the steps below are the controller's order.
/// Without the settlement the gate alone would activate P.
@MainActor
struct PrimaryTurnSettlementTests {
    /// The history file write; fails the next `failures` writes.
    @MainActor final class Writer {
        var failures = 0
        private(set) var writes = 0
        func write(_ data: Data) throws {
            if failures > 0 { failures -= 1; throw CocoaError(.fileWriteOutOfSpace) }
            writes += 1
        }
    }

    @MainActor private struct Line {
        let owner: HistoryOwner
        let writer = Writer()
        let t1 = AgentTranscriptMessage(role: .user, text: "先整理今天的日程")
        let p = AgentTranscriptMessage(role: .user, text: "然后按日程订会议室")
        /// The controller's in-memory frozen configuration of P (`pendingFrozen`).
        var frozen: String? = "P 的冻结配置"
        var file: HistoryFile { owner.file }
        var pending: PendingNext? { owner.file.assistant.pendingNext }

        init(permitted: Bool) throws {
            var initial = HistoryFile.initial(selection: nil)
            let primary = initial.assistant.primarySessionID
            try initial.acceptRoot(t1, attachments: [], in: primary, scope: .general)
            if permitted { try initial.commitDispatchPermit(root: t1.id, sessionID: primary, scope: .general) }
            try initial.acceptPending(PendingNext(sessionID: primary, prompt: .detached(message: p, attachments: []),
                                                  selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil,
                                                  backend: .ddi, clipboardAllowed: true, acceptedOrdinal: 2, state: .queued,
                                                  references: [], acceptedAt: Date()))
            let writer = writer
            owner = HistoryOwner(file: initial, writer: { try writer.write($0) })
        }

        /// `advancePendingIfReady`'s decision with the line free and no Stop
        /// since P was accepted.
        func activation(foreground: Bool = true, stopEpochNow: UInt64 = 0) -> PendingActivation {
            PendingActivation.decide(pending: pending, storageReady: owner.health.isReady, lineBusy: false, settlingSteers: 0,
                                     primaryNotice: file.assistant.primaryNotice, foreground: foreground,
                                     frozenAvailable: frozen != nil, stopEpochAtAccept: 0, stopEpochNow: stopEpochNow)
        }

        /// `notStarted` / `finished` for T1: the settlement, T1's own route (an
        /// ordinary send writes its draft back), then `finish`'s record of the
        /// session state. Returns the hold write's error.
        mutating func end(_ end: PrimaryTurnEnd, cancelled: Bool = false) -> (any Error)? {
            let error = PrimaryTurnSettlement.settle(owner, after: end, frozen: &frozen)
            let primary = file.assistant.primarySessionID, draft = t1.text
            if !end.permitted {
                #expect(NotStartedRoute.route(pendingOrigin: false, cancelled: cancelled) == .restoreDraft)
                #expect((try? owner.transact { try $0.editSession(primary) { $0.draft = draft } }) != nil)
            }
            let state: ChatState = end.permitted && end.successful ? .completed : (cancelled ? .interrupted : .failed)
            #expect(owner.record { try $0.editSession(primary) { $0.state = state } })
            return error
        }

        /// `advancePendingIfReady` as `finish` schedules it: a hold decision is
        /// written; only `.activate` appends P (and enqueues its job).
        mutating func advance(foreground: Bool = true) -> Bool {
            switch activation(foreground: foreground) {
            case .wait: return false
            case .hold(let reason): _ = try? owner.transact { try $0.holdPending(reason) }; return false
            case .activate:
                guard (try? owner.transact { _ = try $0.activatePending(scope: .general) }) != nil else { return false }
                frozen = nil
                return true
            }
        }

        /// `resumePending`: an explicit continue requeues P with a newly frozen configuration.
        mutating func resume() throws {
            try owner.transact { try $0.requeuePending(selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil,
                                                       backend: .ddi, clipboardAllowed: true, ordinal: 3) }
            frozen = "P 重新冻结的配置"
        }
    }

    /// Failure, system expiry (in the background, then back in the
    /// foreground) and startup failure before the permit: P is held, never
    /// appended to history, and no job (so no model or phone work) follows.
    @Test func aTurnEndingBeforeItsPermitHoldsTheDetachedRequest() throws {
        for foreground in [true, false] {
            var line = try Line(permitted: false)
            #expect(line.activation() == .activate) // the gate alone does not know T1 failed
            #expect(line.end(PrimaryTurnEnd(permitted: false, successful: false, foreground: foreground,
                                            stopEpochAtAccept: 0, stopEpochNow: 0)) == nil)
            #expect(line.pending?.state == .held(reason: "上一轮未正常完成；确认后再继续。") && line.frozen == nil)
            #expect(line.activation() == .wait && line.activation(foreground: false) == .wait && !line.advance())
            #expect(line.file.primary?.messages.map(\.id) == [line.t1.id])
            #expect(line.file.assistant.scopeIndex.scopedRoot(line.t1.id)?.dispatchAuthorized == false)
            if case .detached = line.pending?.prompt {} else { Issue.record("P left the detached state") }
            // Only an explicit continue queues it again.
            try line.resume()
            #expect(line.activation() == .activate)
        }
    }

    /// Host review follow-up: the hold is a transaction, so a failed hold
    /// write leaves storage ready and P queued, and the draft restore and the
    /// `finish` record after it are written successfully. P still never
    /// follows on its own: its frozen configuration went before the hold was
    /// tried, so the advancement `finish` schedules holds it again (a second
    /// failed hold leaves it queued, still not activated); only an explicit
    /// continue lets it start.
    @Test func aFailedHoldWriteNeverLetsTheRequestFollowOnItsOwn() throws {
        for permitted in [false, true] {
            var line = try Line(permitted: permitted)
            line.writer.failures = 1
            let error = line.end(PrimaryTurnEnd(permitted: permitted, successful: false, foreground: true,
                                                stopEpochAtAccept: 0, stopEpochNow: 0))
            #expect(error != nil, "\(permitted)")
            // The hold was not written; every later write was.
            #expect(line.owner.health == .ready && line.pending?.state == .queued, "\(permitted)")
            #expect(line.writer.writes == (permitted ? 1 : 2) && line.file.primary?.state == .failed, "\(permitted)")
            #expect(line.activation() == .hold("需要重新确认模型与项目后继续"), "\(permitted)")
            line.writer.failures = 1
            #expect(!line.advance() && line.pending?.state == .queued, "\(permitted)")
            #expect(!line.advance() && line.pending?.state == .held(reason: "需要重新确认模型与项目后继续"), "\(permitted)")
            #expect(line.file.primary?.messages.map(\.id) == [line.t1.id], "\(permitted)")
            try line.resume()
            #expect(line.advance() && line.file.primary?.messages.map(\.id) == [line.t1.id, line.p.id], "\(permitted)")
        }
    }

    /// A user Stop keeps its own hold; a turn that failed after its permit
    /// holds as before; a completed foreground turn still advances P.
    @Test func stopFailureAfterPermitAndCompletionKeepTheirRoutes() throws {
        var stopped = try Line(permitted: false)
        #expect(stopped.end(PrimaryTurnEnd(permitted: false, successful: false, foreground: true, stopEpochAtAccept: 0,
                                           stopEpochNow: 1), cancelled: true) == nil)
        #expect(stopped.pending?.state == .held(reason: "已停止；确认后再继续。"))
        #expect(stopped.activation(stopEpochNow: 1) == .wait)

        var failed = try Line(permitted: true)
        #expect(failed.end(PrimaryTurnEnd(permitted: true, successful: false, foreground: true, stopEpochAtAccept: 0,
                                          stopEpochNow: 0)) == nil)
        #expect(failed.pending?.state == .held(reason: "上一轮未正常完成；确认后再继续。") && failed.activation() == .wait)

        var completed = try Line(permitted: true)
        #expect(completed.end(PrimaryTurnEnd(permitted: true, successful: true, foreground: true, stopEpochAtAccept: 0,
                                             stopEpochNow: 0)) == nil)
        #expect(completed.pending?.state == .queued && completed.frozen != nil && completed.activation() == .activate)
        #expect(completed.advance() && completed.file.primary?.messages.map(\.id) == [completed.t1.id, completed.p.id])

        // A promoted request is the ended turn's own receipt: not settled here.
        let promoted = try Line(permitted: true)
        try promoted.owner.transact { _ = try $0.activatePending(scope: .general) }
        #expect(promoted.file.pendingSettlement(after: PrimaryTurnEnd(permitted: false, successful: false, foreground: true,
                                                                      stopEpochAtAccept: 0, stopEpochNow: 0)) == nil)
    }
}

/// Cross-review follow-up to R9: a job's role is frozen when it is accepted
/// (`ChatJob.primary`), with what follows from it: the assistant's context
/// and memory reads, the forget stop (only the running primary root) and the
/// pending settlement when the turn ends (only a primary turn settles).
/// Before the fix a recovery choice changed roles under a job: a conflict
/// copy S ran an independent turn J (its sends are allowed while the notice
/// shows), was chosen as the primary line, accepted a detached next request
/// P, and when J failed nothing settled P, so `finish`'s advancement started
/// it on its own. `HistoryFile.primaryRecoveryBlocker` (the controller's
/// `choosePrimary` / `startNewPrimary` pass it their jobs, the recovery card
/// shows it) refuses a recovery that changes the role of a session with a
/// job: the current primary line's or the chosen session's. These run the
/// controller's transactions on a real `HistoryOwner`.
@MainActor
struct PrimaryRecoveryTests {
    /// A primary line O with a finished turn, a synchronized conflict copy S
    /// (notice `.diverged([S])`) and an unrelated task T; `busy` is the
    /// controller's sessions with a job.
    @MainActor private struct Lines {
        let owner: HistoryOwner
        let writer = PrimaryTurnSettlementTests.Writer()
        let o: UUID, s: UUID, t: UUID
        var busy: Set<UUID> = []
        var file: HistoryFile { owner.file }

        /// `primaryTurn`: O's own turn was accepted before the copy arrived
        /// (the sync deferred O, which has a job).
        init(primaryTurn: Bool = false) throws {
            var file = HistoryFile.initial(selection: nil)
            let primary = file.assistant.primarySessionID
            let earlier = try file.acceptCurrent("整理今天的日程", in: primary, scope: .general)
            try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "日程已整理"), to: primary, root: earlier)
            try file.editSession(primary) { $0.state = .completed }
            let task = ChatSession(title: "查快递")
            file.sessions.append(task)
            let synced = try #require(file.session(primary))
            let base = PortableSnapshot(sessions: [synced], sessionTombstones: [], providers: [], providerTombstones: [])
            var copy = ChatSession(title: ChatSession.primaryTitle)
            copy.conflictOf = primary
            copy.messages = synced.messages + [AgentTranscriptMessage(role: .assistant, text: "另一台设备上的回复")]
            var deferred: Set<UUID> = []
            if primaryTurn {
                try Self.accept(AgentTranscriptMessage(role: .user, text: "然后订会议室"), in: primary, file: &file)
                deferred = [primary]
            }
            let merged = PortableSnapshot(sessions: [try #require(PortableSession(synced)), try #require(PortableSession(copy))])
            _ = try file.applyPortable(merged: merged, base: base, deferred: deferred)
            let copyID = copy.id
            #expect(file.assistant.primaryNotice == .diverged(copyIDs: [copyID]) && file.session(copyID)?.state == .idle)
            o = primary; s = copyID; t = task.id; busy = deferred
            let writer = writer
            owner = HistoryOwner(file: file, writer: { try writer.write($0) })
        }

        /// `ChatController.acceptSend`'s write: the root and the queued state.
        static func accept(_ prompt: AgentTranscriptMessage, in session: UUID, file: inout HistoryFile) throws {
            try file.acceptRoot(prompt, attachments: [], in: session, scope: .general)
            try file.editSession(session) { $0.state = .queued }
        }

        /// The write, then the job exists.
        mutating func accept(_ text: String, in session: UUID) throws -> UUID {
            let prompt = AgentTranscriptMessage(role: .user, text: text)
            try owner.transact { try Self.accept(prompt, in: session, file: &$0) }
            busy.insert(session)
            return prompt.id
        }

        /// The job's stage as the controller writes it.
        func advance(_ root: UUID, in session: UUID, to state: ChatState) throws {
            switch state {
            case .running: try owner.transact { try $0.commitDispatchPermit(root: root, sessionID: session, scope: .general) }
            default: #expect(owner.record { try $0.editSession(session) { $0.state = state } })
            }
        }

        /// `finish`: the final state is recorded and the job is gone.
        mutating func end(_ session: UUID, _ state: ChatState) {
            #expect(owner.record { try $0.editSession(session) { $0.state = state } })
            busy.remove(session)
        }

        /// `ChatController.choosePrimary` / `startNewPrimary`.
        func choose(_ id: UUID) -> (any Error)? {
            do { try owner.transact { try $0.choosePrimary(id, busy: busy) }; return nil } catch { return error }
        }
        func startNew() -> (any Error)? {
            do { try owner.transact { try $0.startNewPrimary(selection: nil, busy: busy) }; return nil } catch { return error }
        }

        /// A refusal changed nothing and wrote nothing; the card shows the same reason.
        func expectRefused(_ attempt: () -> (any Error)?, _ reason: PrimaryRecoveryError, target: UUID?, _ label: String) {
            let before = file, writes = writer.writes
            let refusal = attempt() as? PrimaryRecoveryError
            #expect(refusal == reason, "\(label)")
            #expect(file == before && writer.writes == writes && file.assistant.primarySessionID == o, "\(label)")
            #expect(file.assistant.primaryNotice == .diverged(copyIDs: [s]) && file.session(s)?.conflictOf == o, "\(label)")
            #expect(file.primaryRecoveryBlocker(choosing: target, busy: busy) == reason, "\(label)")
        }
    }

    /// S runs an independent turn while the notice shows: S is not promoted
    /// while the job is queued or preparing, running or cancelling; either
    /// the controller's job or the persisted run state alone refuses. Once
    /// the job has ended, S may become the primary line.
    @Test func aSessionWithAJobIsNotPromotedUntilItEnds() throws {
        var lines = try Lines()
        let j = try lines.accept("查一下明天的航班", in: lines.s)
        for state in [ChatState.queued, .running, .cancelling] {
            if state != .queued { try lines.advance(j, in: lines.s, to: state) }
            #expect(lines.file.session(lines.s)?.state == state)
            lines.expectRefused({ lines.choose(lines.s) }, .targetBusy, target: lines.s, "\(state)")
        }
        // A job whose session does not say so (a continued unstarted request
        // keeps its earlier final state), and a persisted state without a job.
        lines.end(lines.s, .failed)
        lines.busy = [lines.s]
        lines.expectRefused({ lines.choose(lines.s) }, .targetBusy, target: lines.s, "job only")
        lines.busy = []
        try lines.advance(j, in: lines.s, to: .cancelling)
        lines.expectRefused({ lines.choose(lines.s) }, .targetBusy, target: lines.s, "state only")
        lines.end(lines.s, .interrupted)
        #expect(lines.choose(lines.s) == nil)
        #expect(lines.file.assistant.primarySessionID == lines.s && lines.file.assistant.primaryNotice == nil)
    }

    /// O's turn keeps its primary role: switching to S, keeping O itself and
    /// a new empty line all wait while it is queued, running or cancelling.
    @Test func theCurrentPrimaryWithAJobKeepsItsRoleUntilItEnds() throws {
        var lines = try Lines(primaryTurn: true)
        let root = try #require(lines.file.session(lines.o)?.messages.last?.id)
        let sessions = lines.file.sessions.count
        for state in [ChatState.queued, .running, .cancelling] {
            if state != .queued { try lines.advance(root, in: lines.o, to: state) }
            lines.expectRefused({ lines.choose(lines.s) }, .primaryBusy, target: lines.s, "copy \(state)")
            lines.expectRefused({ lines.choose(lines.o) }, .primaryBusy, target: lines.o, "keep \(state)")
            lines.expectRefused({ lines.startNew() }, .primaryBusy, target: nil, "new \(state)")
            #expect(lines.file.sessions.count == sessions)
        }
        lines.end(lines.o, .interrupted)
        #expect(lines.startNew() == nil)
        #expect(lines.file.assistant.primarySessionID != lines.o && lines.file.session(lines.o) != nil)
        #expect(lines.file.assistant.primaryNotice == nil && lines.file.sessions.count == sessions + 1)
    }

    /// A job of a task whose role no choice changes (T, or S when O is kept
    /// or a new line starts) does not block recovering the two idle lines.
    @Test func aJobOfAnotherTaskDoesNotBlockRecovery() throws {
        for (task, choice) in [(0, 1), (0, 2), (0, nil), (1, 2), (1, nil)] as [(Int, Int?)] {
            var lines = try Lines()
            let ids = [lines.t, lines.s, lines.o]
            let job = try lines.accept("查快递", in: ids[task])
            try lines.advance(job, in: ids[task], to: .running)
            let label = "\(task) \(String(describing: choice))"
            let refusal = if let choice { lines.choose(ids[choice]) } else { lines.startNew() }
            #expect(refusal == nil, "\(label)")
            #expect(lines.file.assistant.primaryNotice == nil, "\(label)")
            if let choice { #expect(lines.file.assistant.primarySessionID == ids[choice], "\(label)") }
            // The task keeps its role and its run.
            #expect(lines.file.assistant.primarySessionID != ids[task] && lines.file.session(ids[task])?.state == .running, "\(label)")
        }
    }

    /// The reported trigger. The pick of S while J waits is refused, so S
    /// stays a task (its input steers J; a pending request is accepted only
    /// on the primary line). J fails before its permit; an independent job
    /// settles nothing and nothing is queued behind it, so `finish`'s
    /// advancement has nothing to start. Only then may S be chosen.
    @Test func aFailedTaskTurnNeverStartsAPendingRequestOnItsOwn() throws {
        func advancement(_ file: HistoryFile, frozen: Bool) -> PendingActivation {
            PendingActivation.decide(pending: file.assistant.pendingNext, storageReady: true, lineBusy: false, settlingSteers: 0,
                                     primaryNotice: file.assistant.primaryNotice, foreground: true, frozenAvailable: frozen,
                                     stopEpochAtAccept: 0, stopEpochNow: 0)
        }
        var lines = try Lines()
        let j = try lines.accept("查一下明天的航班", in: lines.s)
        lines.expectRefused({ lines.choose(lines.s) }, .targetBusy, target: lines.s, "pick")
        #expect(lines.file.assistant.pendingNext == nil)
        lines.end(lines.s, .failed)
        #expect(advancement(lines.file, frozen: false) == .wait)
        #expect(lines.choose(lines.s) == nil && lines.file.assistant.pendingNext == nil)
        #expect(lines.file.session(lines.s)?.messages.last?.id == j)

        // What the unguarded choice wrote: S became the primary line during J
        // and accepted P. J's end settles nothing (a frozen independent job),
        // so the advancement alone would start P.
        var unguarded = try Lines()
        _ = try unguarded.accept("查一下明天的航班", in: unguarded.s)
        let s = unguarded.s
        try unguarded.owner.transact { file in
            file.assistant.primarySessionID = s; file.assistant.primaryNotice = nil
            try file.acceptPending(PendingNext(sessionID: s, prompt: .detached(message: AgentTranscriptMessage(role: .user, text: "然后订酒店"),
                                                                                attachments: []),
                                               selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil,
                                               backend: .ddi, clipboardAllowed: true, acceptedOrdinal: 2, state: .queued,
                                               references: [], acceptedAt: Date()))
        }
        unguarded.end(s, .failed)
        #expect(advancement(unguarded.file, frozen: true) == .activate)
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
        try file.commitDispatchPermit(root: prompt.id, sessionID: primary, scope: .general)
        try file.editSession(primary) { $0.state = .completed }
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
        try deleted.startNewPrimary(selection: nil, busy: [])
        #expect(deleted.primary?.messages.isEmpty == true && deleted.assistant.primaryNotice == nil)

        var diverged = file
        var remote = try #require(PortableSession(file.primary!))
        remote.messages[0].text = "远端改写"
        _ = try diverged.applyPortable(merged: PortableSnapshot(sessions: [remote]), base: base, deferred: [])
        if case .diverged = diverged.assistant.primaryNotice {} else { Issue.record("expected diverged") }
        // Same IDs, changed content: the root becomes unknown.
        let root = try #require(file.primary?.messages.first?.id)
        #expect(diverged.assistant.scopeIndex.scopedRoot(root)?.verified == false)
        try diverged.choosePrimary(primary, busy: [])
        #expect(diverged.assistant.primaryNotice == nil)
    }

    /// Device finding: a running primary turn stopped by a forget showed the
    /// phone run's generic failure. The forget's own reason wins; the other
    /// outcomes keep their wording.
    @Test func aRevokedStartedTurnGivesTheForgetReason() {
        let revoked = StartedTurnOutcome.detail(successful: false, cancelled: false, revoked: true,
                                                failure: "手机助手未完成本轮", cleanupWarning: "")
        #expect(revoked.contains(ContextSourceRevoked().errorDescription!) && !revoked.contains("手机助手未完成本轮"))
        #expect(StartedTurnOutcome.detail(successful: false, cancelled: false, revoked: false, failure: "超时", cleanupWarning: "")
            == "本轮未完成，请发送新消息继续；已执行的动作不会重放。 原因：超时")
        #expect(StartedTurnOutcome.detail(successful: false, cancelled: true, revoked: false, failure: "x", cleanupWarning: "清理") == "已取消。 清理")
        #expect(StartedTurnOutcome.detail(successful: true, cancelled: false, revoked: false, failure: nil, cleanupWarning: "") == "")
    }
}
