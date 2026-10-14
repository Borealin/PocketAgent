import Foundation
import Testing
@testable import PocketAgentCore

struct DDIOperationFailureTests {
    private func response(issued: Bool = false, newTurn: Bool = false) -> [String: Any] {
        ["ok": false, "code": "ddi_preflight_refused", "message": "target changed",
         "action_issued": issued, "requires_new_turn": newTurn, "replay_allowed": false]
    }

    @Test func refusedPreflightDoesNotInventAnInputEffect() throws {
        let failure = try #require(try DDIOperationFailure.decode(response()))
        #expect(!failure.actionIssued)
        #expect(!failure.requiresNewTurn)
        #expect(!failure.actionWasIssued(after: false))
        #expect(failure.actionWasIssued(after: true)) // Preserve an earlier clear or focus tap.
    }

    @Test func uncertainInputAndPreviouslyPoisonedSessionRemainDistinct() throws {
        let uncertain = try #require(try DDIOperationFailure.decode(response(issued: true, newTurn: true)))
        #expect(uncertain.actionWasIssued(after: false))
        let poisoned = try #require(try DDIOperationFailure.decode(response(issued: false, newTurn: true)))
        #expect(!poisoned.actionIssued)
        #expect(poisoned.requiresNewTurn)
    }

    @Test func malformedMetadataCannotClaimARefusalOrPermitReplay() throws {
        #expect(try DDIOperationFailure.decode(["ok": true]) == nil)
        for key in ["ok", "code", "message", "action_issued", "requires_new_turn", "replay_allowed"] {
            var value = response(); value.removeValue(forKey: key)
            #expect(throws: DDIOperationFailure.DecodeIssue.malformed) { try DDIOperationFailure.decode(value) }
        }
        var replay = response(); replay["replay_allowed"] = true
        #expect(throws: DDIOperationFailure.DecodeIssue.malformed) { try DDIOperationFailure.decode(replay) }
    }
}
