import Foundation

/// A DDI request that failed after native admission, with the native
/// metadata: whether this request started an effect (`actionIssued`) and
/// whether input stays disabled for the session (`requiresNewTurn`: an
/// uncertain effect, an unconfirmed release, or an earlier one). It never
/// authorizes a replay.
nonisolated struct DDIOperationFailure: Error, LocalizedError, Equatable, Sendable {
    let code: String
    let message: String
    let actionIssued: Bool
    let requiresNewTurn: Bool

    var errorDescription: String? { message }

    enum DecodeIssue: Error, LocalizedError, Equatable {
        case malformed
        var errorDescription: String? { "DDI 请求结果缺少有效的动作状态；请重新观察，不要重放动作。" }
    }

    /// nil for a successful result; a failure must carry every field.
    static func decode(_ object: [String: Any]) throws -> Self? {
        guard let ok = flag(object["ok"]) else { throw DecodeIssue.malformed }
        guard !ok else { return nil }
        guard let code = object["code"] as? String, !code.isEmpty,
              let message = object["message"] as? String, !message.isEmpty,
              let actionIssued = flag(object["action_issued"]),
              let requiresNewTurn = flag(object["requires_new_turn"]),
              flag(object["replay_allowed"]) == false else { throw DecodeIssue.malformed }
        return Self(code: code, message: message, actionIssued: actionIssued, requiresNewTurn: requiresNewTurn)
    }

    /// A JSON boolean only; a number is not a flag.
    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Earlier primitives in a composite tool may already have changed the
    /// clipboard, focus or text even when its final native request was refused.
    func actionWasIssued(after earlierEffect: Bool) -> Bool { earlierEffect || actionIssued }
}
