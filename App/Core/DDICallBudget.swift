import Foundation

/// The time one native DDI call may take. It is fixed as a wall-clock expiry
/// (the turn deadline's clock) before the call is handed to its worker thread;
/// native code deducts the handoff delay from it, caps it at 35 s and checks it
/// before every stage and physical effect. The call's input cleanup runs after
/// it and is not covered by it, so the turn must leave room for that cleanup.
nonisolated enum DDICallBudget {
    /// The longest one call may take (native code caps it again).
    static let cap: TimeInterval = 35
    /// Native cleanup after a call, all time-only: releasing touch and home and
    /// releasing, resetting and removing the keyboard (5 × 4 s), then closing
    /// AX (2 s) (`Native/ddi/mod.rs` `cleanup_input`, `close_ax`).
    static let cleanupReserve: TimeInterval = 22
    static let minimum: TimeInterval = 1

    /// Seconds for the next call, or nil when the turn cannot afford a call
    /// and its cleanup; nothing is then dispatched. `cap` is lowered only by
    /// the local acceptance launch argument.
    static func seconds(remaining: TimeInterval, cap: TimeInterval = cap) -> TimeInterval? {
        let budget = min(cap, Self.cap, remaining - cleanupReserve)
        return budget >= minimum ? budget : nil
    }

    /// The expiry handed to native code, in wall-clock Unix milliseconds.
    static func expiry(now: Date, seconds: TimeInterval) -> UInt64 {
        UInt64(((now.timeIntervalSince1970 + seconds) * 1000).rounded(.down))
    }
}
