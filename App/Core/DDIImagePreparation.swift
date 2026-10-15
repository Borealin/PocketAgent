import Foundation

/// Phone preparation before the first phone action: checking for, downloading
/// and mounting the developer disk image, and reading the app inventory. Each
/// native step gets a wall-clock expiry, fixed before it is handed to its
/// worker thread and cut by the turn's end; native code deducts the handoff
/// delay and refuses a passed expiry. The expiry bounds the step's cooperative
/// waits (network and device replies); synchronous work such as loading the
/// image assets is not preempted.
nonisolated enum DDIImagePreparation {
    /// Whether the image is mounted (`pocket_ddi_installed` caps it at 15 s);
    /// the app inventory (`pocket_installed_apps`) has the same limit.
    static let checkLimit: TimeInterval = 15
    /// Downloading the files of a missing image and mounting it, together.
    static let budget: TimeInterval = 180
    /// One mount (`pocket_ddi_mount` caps it at 120 s).
    static let mountLimit: TimeInterval = 120
    /// A mount is not started with less left than this.
    static let minimumMount: TimeInterval = 5

    /// The expiry of the image check or of the app inventory read, or nil when
    /// the turn has ended.
    static func checkExpiry(now: Date, turnEnd: Date) -> Date? {
        let expiry = min(now.addingTimeInterval(checkLimit), turnEnd)
        return expiry > now ? expiry : nil
    }
    /// The end of a missing image's downloads and mount.
    static func preparationEnd(now: Date, turnEnd: Date) -> Date {
        min(now.addingTimeInterval(budget), turnEnd)
    }
    /// The mount's expiry, or nil when too little of the preparation is left.
    static func mountExpiry(now: Date, preparationEnd: Date) -> Date? {
        guard preparationEnd.timeIntervalSince(now) >= minimumMount else { return nil }
        return min(now.addingTimeInterval(mountLimit), preparationEnd)
    }
    /// The form native code takes: wall-clock Unix milliseconds.
    static func milliseconds(_ date: Date) -> UInt64 {
        UInt64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
