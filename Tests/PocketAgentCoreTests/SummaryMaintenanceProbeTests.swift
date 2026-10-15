import Foundation
import Testing
@testable import PocketAgentCore

/// The device fixture's logic on the host: every case passes with the same
/// code the launch argument runs on the phone.
@MainActor
struct SummaryMaintenanceProbeTests {
    @Test func everyMaintenanceCasePasses() async throws {
        let report = await SummaryMaintenanceProbe.report()
        let cases = try #require(report["cases"] as? [String: [String: Any]])
        #expect(Set(cases.keys) == ["success", "providerLimit", "cancelWhileStreaming", "forgetWhileStreaming",
                                    "sourceChangedWhileStreaming", "partialRootProgress"])
        for (name, values) in cases { #expect(values["passed"] as? Bool == true, "\(name): \(values)") }
        #expect(report["allPassed"] as? Bool == true)
        #expect(cases["success"]?["providerRequests"] as? Int == 2)
        #expect(cases["providerLimit"]?["providerRequests"] as? Int == 1)
    }
}
