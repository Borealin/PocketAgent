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
