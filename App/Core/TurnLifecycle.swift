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
