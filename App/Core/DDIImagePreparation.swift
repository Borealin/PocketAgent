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

/// What a DDI connection still needs after its transport and image before a
/// turn's tools may use it: the installed-app catalog, then the DDI session.
/// The executor publishes its backend as ready only when preparation returns,
/// so it returns only when both are done. The catalog comes first: a failed
/// catalog read opens no session, and a later preparation in the same turn
/// reads the catalog again instead of taking a leftover session as ready (a
/// failed read is an error, never an empty catalog).
nonisolated struct DDIServiceReadiness: Equatable, Sendable {
    var catalogLoaded: Bool
    var sessionOpen: Bool

    enum Step: Equatable, Sendable { case readCatalog, openSession }

    var remaining: [Step] { (catalogLoaded ? [] : [.readCatalog]) + (sessionOpen ? [] : [.openSession]) }
    var ready: Bool { remaining.isEmpty }

    /// Runs the remaining steps in order; `checkpoint` (Stop, deadline, lease,
    /// storage) runs before each and after the last. A step that throws ends
    /// the preparation with nothing after it.
    @MainActor
    static func prepare(_ current: Self, checkpoint: () throws -> Void, readCatalog: () async throws -> Void,
                        openSession: () async throws -> Void) async throws {
        for step in current.remaining {
            try checkpoint()
            switch step {
            case .readCatalog: try await readCatalog()
            case .openSession: try await openSession()
            }
        }
        try checkpoint()
    }
}
