import Testing
@testable import PocketAgentCore

struct WDARequestDiagnosticsTests {
    @Test func diagnosticsKeepEndpointShapeWithoutRequestIdentityOrQuery() {
        #expect(WDARequestDiagnostics.route("/session/private-session/element/private-element/value?query=private-text")
                == "/session/:id/element/:id/value")
        #expect(WDARequestDiagnostics.route("/session/private-session/wda/dragfromtoforduration")
                == "/session/:id/wda/dragfromtoforduration")
        #expect(WDARequestDiagnostics.route("/wda/homescreen") == "/wda/homescreen")
    }
}
