import Foundation

/// Idle RP maintenance only; never authorizes a phone action or its replay.
struct CellularConnectionPolicy: Sendable {
    var enabled = true
    var paused = false
    private(set) var consecutiveFailures = 0
    private(set) var reminderDismissed = false

    var needsRecovery: Bool { consecutiveFailures >= 3 }
    var showsReminder: Bool { enabled && !paused && needsRecovery && !reminderDismissed }
    var retryDelay: TimeInterval {
        switch consecutiveFailures {
        case 0: 20
        case 1: 2
        case 2: 5
        case 3: 10
        default: 30
        }
    }

    func shouldMaintain(foreground: Bool, paired: Bool, busy: Bool,
                        cellular: Bool, retained: Bool, expired: Bool = false) -> Bool {
        // After the reminder, continue while data is temporarily off: the
        // local VPN can work even with an unsatisfied default network path.
        enabled && !paused && foreground && paired && !busy && (cellular || retained || expired || needsRecovery)
    }

    mutating func failed() { consecutiveFailures = min(consecutiveFailures + 1, 4) }
    mutating func succeeded() { consecutiveFailures = 0; reminderDismissed = false }
    mutating func dismissReminder() { reminderDismissed = true }
}
