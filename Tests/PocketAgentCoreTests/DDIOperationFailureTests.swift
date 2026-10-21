import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Review findings R2 and R8. Native DDI requests report whether they started
/// an effect; `DDIControl` records each result with `NativeEffectReports`
/// and the executor settles each effect bracket with them. Results below are
/// the native wire shapes, decoded through JSONSerialization as the app does.
struct DDIOperationFailureTests {
    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func failure(_ code: String, _ message: String, issued: Bool, newTurn: Bool) throws -> [String: Any] {
        try json(#"{"ok":false,"code":"\#(code)","message":"\#(message)","action_issued":\#(issued),"requires_new_turn":\#(newTurn),"replay_allowed":false}"#)
    }
    private func success(issued: Bool) throws -> [String: Any] {
        try json(#"{"ok":true,"action_issued":\#(issued),"replay_allowed":false}"#)
    }
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

    @Test func decodingKeepsRefusalAndUncertaintyApartAndFailsClosed() throws {
        let refused = try #require(try DDIOperationFailure.decode(failure("ddi_preflight_refused", "target changed", issued: false, newTurn: false)))
        #expect(!refused.actionIssued && !refused.requiresNewTurn)
        let uncertain = try #require(try DDIOperationFailure.decode(failure("ddi_effect_unconfirmed", "timed out", issued: true, newTurn: true)))
        #expect(uncertain.actionIssued && uncertain.requiresNewTurn)
        let disabled = try #require(try DDIOperationFailure.decode(failure("ddi_session_poisoned", "input disabled", issued: false, newTurn: true)))
        #expect(!disabled.actionIssued && disabled.requiresNewTurn)
        #expect(try DDIOperationFailure.decode(success(issued: true)) == nil)
        let complete = try failure("ddi_preflight_refused", "target changed", issued: false, newTurn: false)
        for key in ["ok", "code", "message", "action_issued", "requires_new_turn", "replay_allowed"] {
            var missing = complete; missing.removeValue(forKey: key)
            #expect(throws: DDIOperationFailure.DecodeIssue.malformed) { try DDIOperationFailure.decode(missing) }
        }
        // Flags are JSON booleans: a number is not a flag, and replay is never allowed.
        for (key, value) in [("ok", "0"), ("action_issued", "0"), ("requires_new_turn", "1"), ("replay_allowed", "true"),
                             ("replay_allowed", "0")] {
            var fields = ["ok": "false", "action_issued": "false", "requires_new_turn": "false", "replay_allowed": "false"]
            fields[key] = value
            let flags = fields.map { #""\#($0.key)":\#($0.value)"# }.joined(separator: ",")
            #expect(throws: DDIOperationFailure.DecodeIssue.malformed, "\(key)=\(value)") {
                try DDIOperationFailure.decode(try json(#"{"code":"c","message":"m",\#(flags)}"#))
            }
        }
    }

    /// The executor's effect bracket (`PhoneExecutor.perform`'s `effect`):
    /// begin, run the operation's native calls as `DDIControl` records them,
    /// settle on failure with this operation's reports only.
    private func operation(_ effects: inout PhoneCallEffects, _ reports: inout NativeEffectReports,
                           _ results: [[String: Any]]) {
        let before = effects.beginAction()
        let start = reports
        do { for result in results { if let failure = try reports.record(result: result) { throw failure } } }
        catch { effects.settle(after: error, restoring: before, dispatchedDuringOperation: results.count, native: reports - start) }
    }

    @Test func aRefusalBeforeAnyEffectIsNotAnAction() throws {
        // type: the clipboard readback succeeded, the paste's target check refused it.
        var effects = PhoneCallEffects(), reports = NativeEffectReports()
        operation(&effects, &reports, [try success(issued: false),
                                       try failure("ddi_preflight_refused", "AX foreground or root changed", issued: false, newTurn: false)])
        #expect(!effects.issued)
        // prepareText: the clipboard service was unavailable before any write.
        var clipboard = PhoneCallEffects(), clipboardReports = NativeEffectReports()
        operation(&clipboard, &clipboardReports,
                  [try failure("ddi_preflight_refused", "DDI clipboard readback service unavailable", issued: false, newTurn: false)])
        #expect(!clipboard.issued)
    }

    @Test func earlierEffectsAndUncertainEffectsStayReported() throws {
        // clear: the key chord was sent, then the follow-up read failed.
        var cleared = PhoneCallEffects(), reports = NativeEffectReports()
        operation(&cleared, &reports, [try success(issued: true),
                                       try failure("ddi_observation_failed", "AX request type 6 refused: 8", issued: false, newTurn: false)])
        #expect(cleared.issued)
        // A clipboard write earlier in the same tool call, then a refused tap.
        var chain = PhoneCallEffects(), chainReports = NativeEffectReports()
        operation(&chain, &chainReports, [try success(issued: true)])
        operation(&chain, &chainReports,
                  [try failure("ddi_preflight_refused", "DDI target is covered by another process's UI; not tapped", issued: false, newTurn: false)])
        #expect(chain.issued && chain.action)
        // An effect that started and then failed is uncertain.
        var uncertain = PhoneCallEffects(), uncertainReports = NativeEffectReports()
        operation(&uncertain, &uncertainReports, [try failure("ddi_effect_unconfirmed", "DDI service request timed out", issued: true, newTurn: true)])
        #expect(uncertain.issued && uncertainReports.possible == 1)
        // A result whose metadata is malformed is never read as a refusal.
        var malformed = PhoneCallEffects(), malformedReports = NativeEffectReports()
        operation(&malformed, &malformedReports, [try json(#"{"ok":false,"message":"x"}"#)])
        #expect(malformed.issued && malformedReports.possible == 1)
        // A success without the flag counts as a possible effect.
        var unflagged = NativeEffectReports()
        _ = try unflagged.record(result: try json(#"{"ok":true}"#))
        #expect(unflagged.possible == 1)
    }

    /// Later input in a session an uncertain effect disabled is refused
    /// before anything is sent: not an action, but it still requires a new turn.
    @Test func aDisabledSessionRefusesWithoutInventingAnAction() throws {
        var effects = PhoneCallEffects(), reports = NativeEffectReports()
        let refusal = try failure("ddi_session_poisoned", "DDI input is disabled after an uncertain effect; observe and send a new turn",
                                  issued: false, newTurn: true)
        operation(&effects, &reports, [refusal])
        #expect(!effects.issued)
        #expect(try DDIOperationFailure.decode(refusal)?.requiresNewTurn == true)
    }

    /// Stands in for `DDIControl`'s per-call accounting: `dispatchedCalls`
    /// (counted when handed to the worker, uncounted when native entry refuses
    /// the passed expiry) and `nativeEffects` (a result by its metadata; an
    /// error without metadata after dispatch counts as possible).
    private final class Native {
        enum Call {
            /// No budget for the call and its cleanup: refused before dispatch.
            case budgetMissing
            /// Native entry refused the passed expiry: counted, then uncounted.
            case expiredAtEntry
            /// Stop or the turn's deadline seen before dispatch (`cancellationCheck`).
            case cancelledBeforeDispatch
            /// A native result object.
            case result([String: Any])
            /// A failure after dispatch without native metadata (a transport timeout).
            case errorWithoutMetadata
        }
        var dispatched = 0
        var reports = NativeEffectReports()
        func run(_ call: Call) throws {
            switch call {
            case .budgetMissing: throw PhoneCallNotDispatched.insufficientTime
            case .expiredAtEntry:
                dispatched += 1; dispatched -= 1
                throw PhoneCallNotDispatched(reason: "手机操作的期限在交给设备前已过；未执行。")
            case .cancelledBeforeDispatch: throw CancellationError()
            case .result(let object):
                dispatched += 1
                if let failure = try reports.record(result: object) { throw failure }
            case .errorWithoutMetadata:
                dispatched += 1; reports.possible += 1
                throw URLError(.timedOut)
            }
        }
    }

    /// `PhoneExecutor.compactTaskSurface`'s bracket around the status-band
    /// gesture: marked sent, then settled with this operation's dispatch
    /// count and reports if it fails.
    private func gesture(_ effects: inout PhoneCallEffects, _ native: Native, _ calls: [Native.Call]) {
        let previous = effects.preparation, reports = native.reports, dispatched = native.dispatched
        effects.preparationSent()
        do { for call in calls { try native.run(call) } }
        catch {
            effects.settlePreparation(after: error, restoring: previous,
                                      dispatchedDuringOperation: native.dispatched - dispatched, native: native.reports - reports)
        }
    }

    /// The executor's own status-band gesture is unreported only when its
    /// operation provably sent nothing: a typed refusal before dispatch with
    /// no native call dispatched (no native report exists then), or native
    /// metadata that no effect had started. A dispatched call that acted or
    /// may have, an error without metadata, a cancellation or a timeout keep
    /// it reported.
    @Test func aPreparationGestureIsUnreportedOnlyWhenItProvablySentNothing() throws {
        let refused = try failure("ddi_preflight_refused", "DDI foreground is not the observed app; not tapped", issued: false, newTurn: false)
        let cases: [(String, [Native.Call], Bool)] = [
            ("no budget", [.budgetMissing], false),
            ("expired at native entry", [.expiredAtEntry], false),
            ("native refusal", [.result(refused)], false),
            ("sent, then no budget", [.result(try success(issued: true)), .budgetMissing], true),
            ("unflagged success, then expired", [.result(try json(#"{"ok":true}"#)), .expiredAtEntry], true),
            ("effect unconfirmed", [.result(try failure("ddi_effect_unconfirmed", "DDI service request timed out", issued: true, newTurn: true))], true),
            ("malformed result", [.result(try json(#"{"ok":false,"message":"x"}"#))], true),
            ("error without metadata", [.errorWithoutMetadata], true),
            ("cancelled before dispatch", [.cancelledBeforeDispatch], true),
        ]
        for (label, calls, issued) in cases {
            var effects = PhoneCallEffects()
            gesture(&effects, Native(), calls)
            #expect(effects.issued == issued && effects.preparation == issued && !effects.action, "\(label)")
            // The same proof an action's settlement accepts.
            var action = PhoneCallEffects()
            let before = action.beginAction(), native = Native()
            do { for call in calls { try native.run(call) } }
            catch { action.settle(after: error, restoring: before, dispatchedDuringOperation: native.dispatched, native: native.reports) }
            #expect(action.issued == issued, "\(label) as an action")
        }
    }

    /// Effects sent earlier in the same tool call stay reported when a later
    /// gesture provably sent nothing: an earlier gesture, or an action (a
    /// clipboard write before node recovery).
    @Test func earlierEffectsStayReportedWhenALaterGestureSentNothing() throws {
        let nativeRefusal = try failure("ddi_preflight_refused", "DDI foreground is not the observed app; not tapped",
                                        issued: false, newTurn: false)
        for refusal in [Native.Call.budgetMissing, .expiredAtEntry, .result(nativeRefusal)] {
            var gestures = PhoneCallEffects()
            let native = Native()
            gesture(&gestures, native, [.result(try success(issued: true))])
            gesture(&gestures, native, [refusal])
            #expect(gestures.issued && gestures.preparation && !gestures.action, "\(refusal)")
            var action = PhoneCallEffects(), reports = NativeEffectReports()
            operation(&action, &reports, [try success(issued: true)])
            gesture(&action, Native(), [refusal])
            #expect(action.issued && action.action && !action.preparation, "\(refusal)")
            // An earlier native refusal of a gesture is followed the same way.
            var refusedTwice = PhoneCallEffects()
            let again = Native()
            gesture(&refusedTwice, again, [.result(try failure("ddi_preflight_refused", "DDI display changed", issued: false, newTurn: false))])
            gesture(&refusedTwice, again, [refusal])
            #expect(!refusedTwice.issued, "\(refusal)")
        }
    }

    /// R8: preparing empty text writes nothing, so it is not wrapped as an
    /// effect; a node preflight failure afterwards is "not started", while a
    /// status-band gesture actually sent during node recovery stays reported.
    @Test func emptyTextPreparationIsNotAnEffect() throws {
        let empty = try TextInputRequest(arguments: ["text": .string(""), "clear": .bool(true)], backend: .ddi, clipboardAllowed: true)
        let text = try TextInputRequest(arguments: ["text": .string("你好"), "clear": .bool(true)], backend: .ddi, clipboardAllowed: true)
        let ax = try TextInputRequest(arguments: ["text": .string("你好"), "clear": .bool(true), "method": .string("ax")],
                                      backend: .ddi, clipboardAllowed: false)
        #expect(!empty.preparationWritesClipboard && text.preparationWritesClipboard && !ax.preparationWritesClipboard)
        // Empty text: no effect bracket; node recovery then fails before any touch.
        var plain = PhoneCallEffects()
        if empty.preparationWritesClipboard { _ = plain.beginAction() }
        #expect(!plain.issued)
        // The same with a status-band gesture actually sent during node recovery.
        var prepared = PhoneCallEffects(), reports = NativeEffectReports()
        if empty.preparationWritesClipboard { _ = prepared.beginAction() }
        prepared.preparationSent()
        _ = try reports.record(result: try success(issued: true))
        #expect(prepared.issued && !prepared.action)
        // Nonempty text: the clipboard write is an effect and stays reported.
        var written = PhoneCallEffects(), writeReports = NativeEffectReports()
        if text.preparationWritesClipboard { operation(&written, &writeReports, [try success(issued: true)]) }
        #expect(written.issued && written.action)
    }
}
