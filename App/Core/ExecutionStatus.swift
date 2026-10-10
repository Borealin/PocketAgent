import AgentKit
import Foundation

/// The one semantic state of an accepted turn, derived only from real AgentKit
/// events and host lifecycle calls. Shown in the chat strip and as the
/// BGContinuedProcessingTask subtitle. There is no percentage: the task
/// progress reports counted, completed units of work.
nonisolated enum ExecutionPhase: Hashable, Sendable {
    /// Waiting for the serial phone queue; `rank` is 1 for the next turn.
    case queued(rank: Int, waitingForForeground: Bool)
    /// Request sent; no model output yet.
    case connecting
    case modelResponse
    case phoneAction
    case retrying(attempt: Int, maximum: Int)
    /// Only for a requirement AgentKit actually surfaced.
    case needsUser
    /// AgentKit finished; the host is returning to the app and stopping automation.
    case finishing
    case completed, failed, cancelled

    var isTerminal: Bool { [.completed, .failed, .cancelled].contains(self) }
}

nonisolated struct ExecutionStatus: Hashable, Sendable {
    var phase = ExecutionPhase.connecting
    var modelLabel = ""
    var startedAt: Date?
    var finishedAt: Date?
    var modelResponses = 0
    var phoneActions = 0
    var failedActions = 0
    /// Bundle ID of the foreground app from the latest phone observation.
    var currentApp: String?
    /// Human description of the running or last phone action.
    var currentAction: String?
    var failure: String?
    private var terminalState: AgentRunState?
    /// Visible labels of nodes in the latest observation, for action text.
    private var elements: [Int: String] = [:]

    init(modelLabel: String = "", phase: ExecutionPhase = .connecting) {
        self.modelLabel = modelLabel; self.phase = phase
    }

    mutating func apply(_ event: AgentEvent, now: Date = Date()) {
        guard !phase.isTerminal else { return }
        switch event {
        case .runStarted(let run): startedAt = run.startedAt; phase = .connecting
        case .turnStarted: if phase != .finishing { phase = .connecting }
        case .messageStarted, .messageDelta, .reasoningDelta, .modelRetryRecovered: phase = .modelResponse
        case .messageFinished(let message):
            if message.role == .assistant { modelResponses += 1 }
        case .modelRetryScheduled(let progress):
            phase = .retrying(attempt: progress.attempt, maximum: progress.maximumAttempts)
        case .toolProposed(let invocation, _), .toolStarted(let invocation):
            phase = .phoneAction
            currentAction = ToolLabels.action(invocation.call, elements: elements)
        case .toolFinished(_, let result):
            phoneActions += 1
            if result.isError { failedActions += 1 }
            if let screen = ToolLabels.observation(result.content) {
                currentApp = screen.app; elements = screen.elements
            }
            phase = .connecting
        case .approvalRequested, .userInputRequested: phase = .needsUser
        case .runState(let state):
            if state == .waitingForUser || state == .waitingForApproval { phase = .needsUser }
            else if state == .running, phase == .needsUser { phase = .connecting }
        case .failed(let reason): failure = reason
        case .runFinished(let run):
            terminalState = run.state
            if failure == nil { failure = run.failure }
            phase = .finishing
        default: break
        }
    }

    /// Host cleanup has finished; the run is final.
    mutating func finish(successful: Bool, cancelled: Bool, now: Date = Date()) {
        phase = successful ? .completed : (cancelled || terminalState == .cancelled ? .cancelled : .failed)
        finishedAt = now
    }

    var phaseLabel: String {
        switch phase {
        case .queued(let rank, let waitingForForeground):
            waitingForForeground ? "排队中：回到 App 后开始" : "排队中：第 \(rank) 位，等待手机空闲"
        case .connecting: modelResponses == 0 && phoneActions == 0 ? "正在连接模型" : "等待模型决定下一步"
        case .modelResponse: "模型正在回复"
        case .phoneAction: "正在操作手机"
        case .retrying(let attempt, let maximum): "连接中断，正在重试（\(attempt)/\(maximum)）"
        case .needsUser: "需要你的处理"
        case .finishing: "正在返回 App 并结束自动化"
        case .completed: "已完成"
        case .failed: "未完成"
        case .cancelled: "已取消"
        }
    }

    /// Current app / action line, empty when nothing real is known.
    var activity: String {
        var parts: [String] = []
        if phase == .phoneAction, let currentAction { parts.append(currentAction) }
        if let currentApp, !currentApp.isEmpty { parts.append(ToolLabels.appName(currentApp)) }
        return parts.joined(separator: " · ")
    }

    var stepsLabel: String {
        guard phoneActions > 0 else { return "" }
        return failedActions > 0 ? "\(phoneActions) 步（\(failedActions) 步失败）" : "\(phoneActions) 步"
    }

    /// One line for the system task surface while another app is in front.
    var subtitle: String {
        ([phaseLabel, activity, stepsLabel.isEmpty ? "" : "已执行 \(stepsLabel)"]).filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Completed real work units (model responses and phone actions) with the
    /// one unit currently in flight. BGContinuedProcessingTask requires
    /// progress reporting; this never encodes a request budget or a guess
    /// about how much work remains.
    var progressUnits: (completed: Int64, total: Int64) {
        let done = Int64(modelResponses + phoneActions)
        return phase.isTerminal ? (max(done, 1), max(done, 1)) : (done, done + 1)
    }
}

nonisolated enum ToolLabels {
    static func name(_ tool: String) -> String {
        switch tool {
        case "observe_screen": "读取屏幕"
        case "open_app": "打开 App"
        case "tap": "点击"
        case "tap_point": "点击坐标"
        case "long_press": "长按"
        case "swipe": "滑动"
        case "type_text": "输入文字"
        case "press_key": "按键"
        case "dismiss_keyboard": "收起键盘"
        case "press_home": "回到主屏幕"
        case "wait": "等待"
        default: tool
        }
    }

    /// What the action visibly does. Element actions name the element's
    /// visible label from the observation they referenced; internal node
    /// numbers stay in the expanded details only.
    static func action(_ call: AgentToolCall, elements: [Int: String] = [:]) -> String {
        let args = call.arguments.objectValue ?? [:]
        let target = args["node"]?.integerValue.flatMap { elements[$0] }.map(quoted)
        switch call.name {
        case "open_app": return "打开 " + appName(args["bundle_id"]?.stringValue ?? "")
        case "tap": return target.map { "点击\($0)" } ?? "点击屏幕元素"
        case "long_press": return target.map { "长按\($0)" } ?? "长按屏幕元素"
        case "tap_point": return "点击屏幕位置"
        case "type_text":
            let text = args["text"]?.stringValue ?? ""
            let shown = text.count > 16 ? String(text.prefix(16)) + "…" : text
            return (target.map { "在\($0)" } ?? "") + (shown.isEmpty ? "清空输入" : "输入「\(shown)」")
        case "swipe":
            let direction = ["up": "向上", "down": "向下", "left": "向左", "right": "向右"][args["direction"]?.stringValue ?? ""]
            return (direction ?? "") + "滑动"
        case "press_key": return args["key"]?.stringValue == "delete" ? "按删除键" : "按回车键"
        case "wait": return args["seconds"]?.numberValue.map { "等待 \($0.formatted()) 秒" } ?? "等待"
        default: return name(call.name)
        }
    }

    static func appName(_ bundleID: String) -> String {
        switch bundleID {
        case "com.apple.Preferences": "设置"
        case "com.apple.AppStore": "App Store"
        case "com.apple.mobilesafari": "Safari"
        case "com.apple.springboard": "主屏幕"
        default: bundleID
        }
    }

    private static func quoted(_ label: String) -> String {
        "「\(label.count > 18 ? String(label.prefix(18)) + "…" : label)」"
    }

    /// Foreground app and visible node labels reported by a phone tool result.
    static func observation(_ content: String) -> (app: String, elements: [Int: String])? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let screen = object["screen"] as? [String: Any], let app = screen["app"] as? String, !app.isEmpty else { return nil }
        var elements: [Int: String] = [:]
        for element in screen["elements"] as? [[String: Any]] ?? [] {
            guard let node = element["node"] as? Int else { continue }
            let label = ((element["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = ((element["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { elements[node] = label } else if !name.isEmpty { elements[node] = name }
        }
        return (app, elements)
    }
}

/// One step in a folded tool timeline. IDs are the provider's call IDs.
nonisolated struct ToolStep: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable { case pending, succeeded, failed, noResult }
    var call: AgentToolCall
    var result: AgentTranscriptMessage?
    /// Visible meaning, resolved against the observation preceding the call.
    var label: String
    var id: String { call.id }

    func status(running: Bool) -> Status {
        guard let result else { return running ? .pending : .noResult }
        return result.isError ? .failed : .succeeded
    }
}

nonisolated enum TranscriptItem: Identifiable, Hashable, Sendable {
    case message(AgentTranscriptMessage)
    case tools(id: UUID, steps: [ToolStep])
    /// A tool result whose call is not in this history.
    case orphanResult(AgentTranscriptMessage)

    var id: String {
        switch self {
        case .message(let message): message.id.uuidString
        case .tools(let id, _): "tools-\(id.uuidString)"
        case .orphanResult(let message): "result-\(message.id.uuidString)"
        }
    }

    /// Display grouping in event order. Each result is paired with the nearest
    /// preceding unanswered call carrying its ID; consecutive tool-only
    /// assistant turns fold into one timeline. Messages are never reordered.
    static func build(_ messages: [AgentTranscriptMessage]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var open: [String: (item: Int, step: Int)] = [:]
        var elements: [Int: String] = [:]
        func step(_ call: AgentToolCall) -> ToolStep {
            ToolStep(call: call, label: ToolLabels.action(call, elements: elements))
        }
        for message in messages {
            switch message.role {
            case .tool:
                if let screen = ToolLabels.observation(message.text) { elements = screen.elements }
                if let callID = message.toolCallID, let slot = open.removeValue(forKey: callID),
                   case .tools(let id, var steps) = items[slot.item] {
                    steps[slot.step].result = message
                    items[slot.item] = .tools(id: id, steps: steps)
                } else { items.append(.orphanResult(message)) }
            case .assistant where !message.toolCalls.isEmpty:
                let hasText = !message.text.isEmpty || !message.reasoning.isEmpty
                if hasText { items.append(.message(message)) }
                if !hasText, case .tools(let id, var steps)? = items.last {
                    for call in message.toolCalls {
                        open[call.id] = (items.count - 1, steps.count)
                        steps.append(step(call))
                    }
                    items[items.count - 1] = .tools(id: id, steps: steps)
                } else {
                    for (index, call) in message.toolCalls.enumerated() { open[call.id] = (items.count, index) }
                    items.append(.tools(id: message.id, steps: message.toolCalls.map(step)))
                }
            default: items.append(.message(message))
            }
        }
        return items
    }
}

/// Whether a frozen run configuration can carry the user's images.
nonisolated enum ImageCapability {
    enum Verdict: Equatable { case ok, warnDropImages, blockImageOnly }
    static func check(supportsImages: Bool, hasText: Bool, imageCount: Int) -> Verdict {
        guard imageCount > 0, !supportsImages else { return .ok }
        return hasText ? .warnDropImages : .blockImageOnly
    }
}
