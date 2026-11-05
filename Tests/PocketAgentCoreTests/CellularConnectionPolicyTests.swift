import Testing
@testable import PocketAgentCore

struct CellularConnectionPolicyTests {
    @Test func repeatedFailuresBackOffAndPromptOnceUntilRecovery() {
        var policy = CellularConnectionPolicy()
        #expect(!policy.showsReminder)
        for delay in [2.0, 5.0, 10.0, 30.0, 30.0] {
            policy.failed()
            #expect(policy.retryDelay == delay)
            #expect(policy.showsReminder == (delay >= 10))
        }
        policy.dismissReminder()
        policy.failed()
        #expect(!policy.showsReminder && policy.needsRecovery)
        policy.succeeded()
        #expect(!policy.needsRecovery && policy.retryDelay == 20)
        for _ in 0..<3 { policy.failed() }
        #expect(policy.showsReminder)
    }

    @Test func recoveryContinuesWithDataOffButOrdinaryWiFiDoesNotStartATunnel() {
        var policy = CellularConnectionPolicy()
        func allowed(cellular: Bool, retained: Bool = false) -> Bool {
            policy.shouldMaintain(foreground: true, paired: true, busy: false, cellular: cellular, retained: retained)
        }
        #expect(allowed(cellular: true))
        #expect(!allowed(cellular: false))
        #expect(allowed(cellular: false, retained: true))
        // A background-expired preparation must resume even before the user
        // restores cellular data, without needing three new failures first.
        #expect(policy.shouldMaintain(foreground: true, paired: true, busy: false,
                                      cellular: false, retained: false, expired: true))
        for _ in 0..<3 { policy.failed() }
        policy.dismissReminder()
        #expect(allowed(cellular: false))
        policy.succeeded()
        #expect(!allowed(cellular: false))
    }

    @Test func maintenanceNeverRunsDuringATurnOrWithoutForegroundPairingAndConsent() {
        var policy = CellularConnectionPolicy()
        for (foreground, paired, busy) in [(false, true, false), (true, false, false), (true, true, true)] {
            #expect(!policy.shouldMaintain(foreground: foreground, paired: paired, busy: busy, cellular: true, retained: true, expired: true))
        }
        policy.paused = true
        #expect(!policy.shouldMaintain(foreground: true, paired: true, busy: false, cellular: true, retained: false))
        policy.paused = false; policy.enabled = false
        #expect(!policy.shouldMaintain(foreground: true, paired: true, busy: false, cellular: true, retained: true))
    }
}
