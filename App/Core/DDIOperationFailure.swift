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
    var controlSurface: DDIControlSurface? = nil

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
        return Self(code: code, message: message, actionIssued: actionIssued, requiresNewTurn: requiresNewTurn,
                    controlSurface: try DDIControlSurface.decode(object["control_surface"]))
    }

    /// A JSON boolean only; a number is not a flag.
    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Earlier primitives in a composite tool may already have changed the
    /// clipboard, focus or text even when its final native request was refused.
    func actionWasIssued(after earlierEffect: Bool) -> Bool { earlierEffect || actionIssued }

    /// Unsupported layouts need an explicit stop, never another recovery read.
    /// Preserve the caller's issued-effect and new-turn fields unchanged.
    func applyUnavailableSurfaceGuidance(to result: inout [String: Any]) -> Bool {
        guard let controlSurface, controlSurface.state == "unavailable" else { return false }
        result["control_surface"] = controlSurface.dictionary
        result["message"] = requiresNewTurn
            ? "当前布局无法确认目标 App 的操作区域；此前动作效果未知，本轮输入已停用。请检查实际界面，在受支持的单屏竖屏中开始新回合；不要重放此前动作。"
            : "当前布局无法确认目标 App 的操作区域，已停止本次手机操作。切回受支持的单屏竖屏后可重新观察；不会重放此前动作。"
        result["requires_replan"] = false
        result["recovery"] = "supported_layout_required"
        return true
    }
}
