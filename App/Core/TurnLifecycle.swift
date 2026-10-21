import Foundation

/// Decisions of the turn/pending lifecycle, kept pure so every route can be
/// tested without the app's MainActor controller.
nonisolated enum PendingAdvanceDecision: Equatable, Sendable {
    case advance
    case hold(String)
}

nonisolated enum PendingAdvancePolicy {
    /// A pending request may follow a primary turn automatically only after a
    /// completed turn, in the foreground, with no Stop since it was accepted.
    static func afterPrimaryTurn(successful: Bool, foreground: Bool, stopEpochAtAccept: UInt64,
                                 stopEpochNow: UInt64) -> PendingAdvanceDecision {
        if stopEpochNow != stopEpochAtAccept { return .hold("已停止；确认后再继续。") }
        if !successful { return .hold("上一轮未正常完成；确认后再继续。") }
        if !foreground { return .hold("App 不在前台；回来后确认继续。") }
        return .advance
    }
}

/// The end of a primary-line turn as the controller settles it, before
/// `finish` gives the line back (which lets a queued request advance).
nonisolated struct PrimaryTurnEnd: Equatable, Sendable {
    /// The startup permit was committed.
    var permitted: Bool
    /// The run completed (counts only after the permit).
    var successful: Bool
    var foreground: Bool
    /// The Stop epoch when the pending request was accepted, and now.
    var stopEpochAtAccept: UInt64
    var stopEpochNow: UInt64
}

nonisolated extension HistoryFile {
    /// What the end of a primary turn means for a detached queued pending
    /// request; nil when there is none (a promoted request is the ended
    /// turn's own receipt and follows `NotStartedRoute`). It stays queued
    /// only after a turn that started and completed, in the foreground, with
    /// no Stop since it was accepted. Every other end holds it, including a
    /// failure, system expiry or preparation failure before the startup
    /// permit; the caller writes the hold before `finish`.
    func pendingSettlement(after end: PrimaryTurnEnd) -> PendingAdvanceDecision? {
        guard let pending = assistant.pendingNext, pending.state == .queued, case .detached = pending.prompt else { return nil }
        return PendingAdvancePolicy.afterPrimaryTurn(successful: end.permitted && end.successful, foreground: end.foreground,
                                                      stopEpochAtAccept: end.stopEpochAtAccept, stopEpochNow: end.stopEpochNow)
    }
}

/// The controller's settlement of the pending request when a primary turn
/// ends (`ChatController.notStarted` / `finished`, before `finish`).
@MainActor
enum PrimaryTurnSettlement {
    /// When the end holds the request, the in-memory frozen configuration,
    /// the only authority for automatic activation, is dropped before the
    /// hold is written. The hold is a transaction: a failed write leaves
    /// storage ready and the request queued, and later writes (the draft
    /// restore, `finish`'s record) may succeed. None of that lets it follow
    /// on its own: without a frozen configuration `PendingActivation` holds
    /// it again; only an explicit continue freezes a new one. Returns the
    /// hold write's error for the caller's notice.
    static func settle<Frozen>(_ owner: HistoryOwner, after end: PrimaryTurnEnd, frozen: inout Frozen?) -> (any Error)? {
        guard case .hold(let reason)? = owner.file.pendingSettlement(after: end) else { return nil }
        frozen = nil
        do { try owner.transact { try $0.holdPending(reason) } } catch { return error }
        return nil
    }
}

/// Whether the single pending request is activated now
/// (`ChatController.advancePendingIfReady`); only `.activate` appends it to
/// history and enqueues a job.
nonisolated enum PendingActivation: Equatable, Sendable {
    /// Not now: nothing detached and queued, the line busy, steering still
    /// settling, a recovery notice, unusable storage or the background.
    case wait
    /// It cannot follow automatically: held with this reason.
    case hold(String)
    case activate

    static func decide(pending: PendingNext?, storageReady: Bool, lineBusy: Bool, settlingSteers: Int,
                       primaryNotice: PrimaryNotice?, foreground: Bool, frozenAvailable: Bool,
                       stopEpochAtAccept: UInt64, stopEpochNow: UInt64) -> PendingActivation {
        guard storageReady, let pending, pending.state == .queued, case .detached = pending.prompt, !lineBusy,
              settlingSteers == 0, primaryNotice == nil, foreground else { return .wait }
        guard frozenAvailable, stopEpochNow == stopEpochAtAccept else {
            return .hold(frozenAvailable ? "已停止；确认后再继续" : "需要重新确认模型与项目后继续")
        }
        return .activate
    }
}

nonisolated enum TurnEffectPolicy {
    /// Why a job may not issue a new phone/model effect now, or nil. A job
    /// that is no longer the current owner of its session, not the engine's
    /// running job, cancelled or terminal can never act again.
    static func blocked(storage: StorageHealth, isCurrent: Bool, isRunning: Bool, cancelled: Bool, terminal: Bool) -> String? {
        if !storage.isReady { return storage.message ?? "历史存储不可用。" }
        if !isCurrent || !isRunning { return "本轮已被替换或结束，不再执行新动作。" }
        if cancelled { return "本轮已取消。" }
        if terminal { return "本轮已结束。" }
        return nil
    }
}

/// Where a request that never received its startup permit goes.
nonisolated enum NotStartedRoute: Equatable, Sendable {
    /// Ordinary send: the untouched composer gets its draft back; the prompt stays.
    case restoreDraft
    /// Pending origin cancelled: abandon unstarted (original kept, slot released).
    case abandon
    /// Pending origin failed: the receipt stays, held for an explicit decision.
    case hold

    static func route(pendingOrigin: Bool, cancelled: Bool) -> NotStartedRoute {
        guard pendingOrigin else { return .restoreDraft }
        return cancelled ? .abandon : .hold
    }
}

/// What a cancelled request that never received its startup permit says.
/// A Stop during context preparation may follow summary requests that were
/// already sent, so it reports only what is known: the preparation stopped, the
/// main request did not start and no new phone action follows.
nonisolated enum NotStartedCancellation: Equatable, Sendable {
    /// Still waiting in the phone queue.
    case queued
    /// Stopped while preparing (context maintenance, before the main request).
    case preparing

    var detail: String {
        switch self {
        case .queued: "已取消排队任务。"
        case .preparing: "已在准备阶段停止：本轮主请求未开始，不会再有新的手机操作。"
        }
    }
    /// The pending-origin abandon's receipt detail.
    var abandonDetail: String {
        switch self {
        case .queued: "已取消，未开始执行。"
        case .preparing: "已在准备阶段停止，主请求未开始。"
        }
    }
}

/// The detail of a turn that ended after its startup permit. A turn an
/// explicit forget revoked gives that reason, not whatever its interrupted
/// run reported (the phone run only knows it did not finish).
nonisolated enum StartedTurnOutcome {
    static func detail(successful: Bool, cancelled: Bool, revoked: Bool, failure: String?, cleanupWarning: String) -> String {
        var parts: [String] = []
        if !successful {
            if cancelled { parts.append("已取消。") } else {
                parts.append("本轮未完成，请发送新消息继续；已执行的动作不会重放。")
                if let reason = revoked ? ContextSourceRevoked().errorDescription : failure { parts.append("原因：\(reason)") }
            }
        }
        if !cleanupWarning.isEmpty { parts.append(cleanupWarning) }
        return parts.joined(separator: " ")
    }
}

/// The primary root an explicit forget may stop: only the primary turn the
/// engine is executing, while it prepares context (before its permit, when
/// maintenance already reads history) or runs. A queued primary request has
/// read nothing yet, and a running independent task is never stopped by it.
nonisolated enum ForgetStopPolicy {
    static func activeRoot(primaryID: UUID, runningSessionID: UUID?, runningRoot: UUID?, terminal: Bool) -> UUID? {
        guard runningSessionID == primaryID, !terminal else { return nil }
        return runningRoot
    }
}
