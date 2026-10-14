import Foundation

/// Native request failure metadata survives FFI so a refused preflight is not
/// confused with an uncertain input effect. It never authorizes a replay.
nonisolated struct DDIOperationFailure: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let actionIssued: Bool
    let requiresNewTurn: Bool

    var errorDescription: String? { message }

    enum DecodeIssue: Error, LocalizedError, Equatable {
        case malformed
        var errorDescription: String? { "DDI 请求结果缺少有效的动作状态；请重新观察，不要重放动作。" }
    }

    static func decode(_ object: [String: Any]) throws -> Self? {
        guard let ok = object["ok"] as? Bool else { throw DecodeIssue.malformed }
        guard !ok else { return nil }
        guard let code = object["code"] as? String, !code.isEmpty,
              let message = object["message"] as? String, !message.isEmpty,
              let actionIssued = object["action_issued"] as? Bool,
              let requiresNewTurn = object["requires_new_turn"] as? Bool,
              object["replay_allowed"] as? Bool == false else { throw DecodeIssue.malformed }
        return Self(code: code, message: message, actionIssued: actionIssued, requiresNewTurn: requiresNewTurn)
    }

    /// Earlier primitives in a composite tool may already have changed the
    /// clipboard, focus or text even when its final native request was refused.
    func actionWasIssued(after earlierEffect: Bool) -> Bool { earlierEffect || actionIssued }
}
