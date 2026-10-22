import Foundation

nonisolated enum PhoneBackendKind: String, CaseIterable, Codable, Sendable {
    case ddi, wda
    static let defaultBackend = PhoneBackendKind.ddi
    var label: String { self == .ddi ? "DDI" : "WDA" }
}

/// Effects of one phone tool call: the requested action and any executor
/// preparation gesture sent while observing for it (the task-surface swipe on
/// Dynamic Island layouts). A refusal before the requested touch restores only
/// the action flag; a preparation gesture stays reported in every outcome,
/// including cancellation and failed observation, unless its own operation
/// provably sent nothing.
nonisolated struct PhoneCallEffects: Equatable, Sendable {
    private(set) var action = false
    private(set) var preparation = false
    var issued: Bool { action || preparation }

    /// Marks the requested action as sent; returns the previous action flag.
    mutating func beginAction() -> Bool {
        defer { action = true }
        return action
    }
    mutating func refusedBeforeTouch(restoring previous: Bool) { action = previous }
    /// Called before the gesture is sent: a failed send may still have touched.
    mutating func preparationSent() { preparation = true }

    /// An effect operation failed. Only a refusal proven to precede anything
    /// it could have sent restores the action flag: a native refusal before
    /// any touch, or a failure `sentNothing` accepts. Preparation stays
    /// reported either way.
    mutating func settle(after error: any Error, restoring previous: Bool, dispatchedDuringOperation: Int,
                         native: NativeEffectReports = NativeEffectReports()) {
        if case PhoneObservationIssue.targetCovered = error { action = previous; return }
        if Self.sentNothing(error, dispatchedDuringOperation: dispatchedDuringOperation, native: native) { action = previous }
    }

    /// The preparation gesture's own operation failed: it is unreported only
    /// when `sentNothing` accepts the failure, as for an action. An earlier
    /// sent preparation (`previous`) and the action flag stay reported.
    mutating func settlePreparation(after error: any Error, restoring previous: Bool, dispatchedDuringOperation: Int,
                                    native: NativeEffectReports) {
        if Self.sentNothing(error, dispatchedDuringOperation: dispatchedDuringOperation, native: native) { preparation = previous }
    }

    /// A failed operation provably sent nothing: a typed refusal before
    /// dispatch when no native call of the operation was dispatched at all, or
    /// a DDI refusal whose native calls in the operation all reported that no
    /// effect had started (`native`, the reports of this operation only). A
    /// composite operation whose earlier call acted, a timeout, a cancellation
    /// or any failure without such proof may follow a sent effect.
    private static func sentNothing(_ error: any Error, dispatchedDuringOperation: Int, native: NativeEffectReports) -> Bool {
        (error is PhoneCallNotDispatched && dispatchedDuringOperation == 0) || native.provenUnsent
    }
}

/// What DDI native calls reported about effects, counted per call (WDA reports
/// nothing). `possible`: calls in which an effect started, or could not be
/// ruled out (an error without metadata, a malformed result). `refused`:
/// failed calls whose native metadata says no effect had started.
nonisolated struct NativeEffectReports: Equatable, Sendable {
    var possible = 0
    var refused = 0

    /// A refusal, and no call that could have acted.
    var provenUnsent: Bool { refused > 0 && possible == 0 }

    /// A native call that returned a result: a failure is decoded and
    /// counted by its metadata (and returned to be thrown), a success that
    /// reports an effect, or omits the flag, counts as possible. A result
    /// whose metadata is malformed counts as possible and throws.
    mutating func record(result object: [String: Any]) throws -> DDIOperationFailure? {
        let failure: DDIOperationFailure?
        do { failure = try DDIOperationFailure.decode(object) } catch { possible += 1; throw error }
        if let failure { record(failure) }
        else if DDIOperationFailure.flag(object["action_issued"]) != false { possible += 1 }
        return failure
    }
    mutating func record(_ failure: DDIOperationFailure) {
        if failure.actionIssued { possible += 1 } else { refused += 1 }
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(possible: lhs.possible - rhs.possible, refused: lhs.refused - rhs.refused)
    }
}

/// A phone call refused before it was handed to the device: not enough of the
/// turn is left for the call and its cleanup, or native code refused the
/// expiry at entry. Nothing of this call was sent.
nonisolated struct PhoneCallNotDispatched: LocalizedError, Equatable {
    var reason: String
    var errorDescription: String? { reason }
    static let insufficientTime = PhoneCallNotDispatched(reason: "本轮剩余时间不足以安全执行手机操作；未执行。")
}

nonisolated enum DDIResultError: LocalizedError, Equatable {
    case outsideCount
    var errorDescription: String? { "DDI 观察结果格式无效：缺少有效的应用外元素计数。" }
}

/// Normalize only device-reported AX semantics. AX role codes differ from
/// XCTest enums; unknown roles retain Other, and absent states stay absent.
nonisolated enum DDINodeMapping {
    static func attributes(_ raw: [String: Any]) throws -> [String: String]? {
        guard let r = raw["21"] as? [String: Any], let x = r["x"] as? Double, let y = r["y"] as? Double,
              let w = r["width"] as? Double, let h = r["height"] as? Double,
              [x,y,w,h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        let role = (raw["45"] as? NSNumber)?.intValue
        if role == 1 { return nil }
        let subrole = (raw["51"] as? NSNumber)?.intValue
        let traits = (raw["77"] as? NSNumber)?.uint64Value ?? 0
        let type: String
        switch role {
        case 2: type = "Button"
        case 3: type = subrole == 3 ? "Switch" : "Other"
        case 6,14: type = "StaticText"
        case 15: type = subrole == 5 ? "SecureTextField" : subrole == 1 ? "SearchField" : "TextField"
        case 17 where traits & ((1 << 18) | (1 << 47)) == ((1 << 18) | (1 << 47)): type = "TextView"
        default: type = "Other"
        }
        var a = ["type": "XCUIElementType" + type, "x": String(x), "y": String(y), "width": String(w), "height": String(h)]
        for (key,name) in [("3","label"),("25","name"),("42","placeholder"),("53","value"),("identity","ddi_identity")] {
            if let s = raw[key] as? String { a[name] = s }
        }
        // Description is the device's semantic text; retain its provenance.
        if a["label"] == nil, let description = raw["33"] as? String { a["label"] = description; a["ddi_text_source"] = "description" }
        for (key,name) in [("27","enabled"),("28","focused"),("32","visible")] {
            if let n = raw[key] as? NSNumber, n == 0 || n == 1 { a[name] = n.boolValue ? "true" : "false" }
        }
        // The tested focused editable UITextView may omit all text attributes.
        // Preserve that shape without asserting it is empty. A pending paste
        // can defer confirmation to the exact final value; clear-only cannot.
        if type == "TextView", raw["53"] == nil, a["focused"] == "true", a["enabled"] == "true",
           (a["label"] ?? "").isEmpty, raw["33"] == nil || (raw["33"] as? String)?.isEmpty == true {
            a["ddi_textview_value_omitted"] = "true"
        }
        if type == "SecureTextField" { a["ddi_value"] = a.removeValue(forKey: "value") }
        if a["visible"] == "false" { return nil }
        return a
    }

    /// Elements on screen hosted by another process that the observation did
    /// not read (native limit 32). Every DDI snapshot reports it; a missing,
    /// boolean, fractional, non-finite or out-of-range count is a malformed
    /// observation, never guessed.
    static let outsideLimit = 32
    static func outsideAppElements(_ result: [String: Any]) throws -> Int {
        guard let number = result["outside_app_elements"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw DDIResultError.outsideCount
        }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(), (0...Double(outsideLimit)).contains(value) else {
            throw DDIResultError.outsideCount
        }
        return Int(value)
    }

    static func confirmsInput(_ node: [String: String], text: String) -> Bool {
        guard let value = node["value"] else { return false }
        let placeholder = node["placeholder"]
        // An empty field can report its placeholder as its value (for example
        // after a paste that did not land): that cannot confirm nonempty text,
        // even text equal to the placeholder.
        guard text.isEmpty else { return value == text && value != placeholder }
        // Clear-only keeps its empty-or-placeholder confirmation.
        return value.isEmpty || value == placeholder
    }
}
