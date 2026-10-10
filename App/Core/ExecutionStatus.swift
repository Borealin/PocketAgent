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
    /// Native project file or skill work.
    case workspaceTool
    case network
    /// A script is running; its own phone requests show as phoneAction.
    case script
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
    /// Phone actions, whether the model or a running script requested them.
    var phoneActions = 0
    var failedActions = 0
    /// Completed file, skill, network and script steps; never counted as phone actions.
    var otherSteps = 0
    var failedOtherSteps = 0
    /// Phone actions requested by the script that is currently running.
    var scriptPhoneActions = 0
    /// Observed real work inside an unfinished step: streamed model output,
    /// script runtime stages and output, script phone requests. Feeds only
    /// `progressUnits`, never the visible step counts.
    var workObserved = 0
    /// The system (or the person, from the system task UI) ended the background task; the turn fails with that cause
    /// even though AgentKit reports the resulting stop as a cancellation.
    private(set) var systemExpired = false
    private var lastStreamWorkAt: Date?
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
        case .messageDelta, .reasoningDelta:
            phase = .modelResponse
            // Streamed output is real work; count at most one unit per window.
            if lastStreamWorkAt.map({ now.timeIntervalSince($0) >= Self.streamWorkInterval }) ?? true {
                workObserved += 1; lastStreamWorkAt = now
            }
        case .messageStarted, .modelRetryRecovered: phase = .modelResponse
        case .messageFinished(let message):
            if message.role == .assistant { modelResponses += 1 }
        case .modelRetryScheduled(let progress):
            phase = .retrying(attempt: progress.attempt, maximum: progress.maximumAttempts)
        case .toolProposed(let invocation, _), .toolStarted(let invocation):
            phase = Self.phase(for: invocation.call.name)
            if phase == .script { scriptPhoneActions = 0 }
            currentAction = ToolLabels.action(invocation.call, elements: elements)
        case .toolFinished(let invocation, let result):
            if Self.phase(for: invocation.call.name) == .phoneAction {
                phoneActions += 1
                if result.isError { failedActions += 1 }
            } else {
                otherSteps += 1
                if result.isError { failedOtherSteps += 1 }
            }
            if let screen = ToolLabels.observation(result.content) {
                currentApp = screen.app; elements = screen.elements
            }
            phase = .connecting
        case .approvalRequested, .userInputRequested: phase = .needsUser
        case .runState(let state):
            if state == .waitingForUser || state == .waitingForApproval { phase = .needsUser }
            else if state == .running, phase == .needsUser { phase = .connecting }
        case .failed(let reason): if !systemExpired { failure = reason }
        case .runFinished(let run):
            terminalState = run.state
            if failure == nil { failure = run.failure }
            phase = .finishing
        default: break
        }
    }

    static func phase(for tool: String) -> ExecutionPhase {
        switch ToolCatalog.kind(of: tool) {
        case .file, .context: .workspaceTool
        case .network: .network
        case .script: .script
        case .phone, nil: .phoneAction
        }
    }

    /// A phone action requested by a running script. It is counted and shown
    /// as a phone step, nested under the script; no transcript message exists.
    mutating func applyScript(_ event: ScriptPhoneEvent) {
        guard !phase.isTerminal else { return }
        switch event {
        case .started(let call):
            workObserved += 1
            phase = .phoneAction
            currentAction = "脚本：" + ToolLabels.action(call, elements: elements)
        case .finished(let call, let content, let isError):
            phoneActions += 1; scriptPhoneActions += 1
            if isError { failedActions += 1 }
            // The script keeps running; its last phone step stays visible.
            currentAction = "运行脚本 · " + ToolLabels.action(call, elements: elements)
            if let screen = ToolLabels.observation(content) { currentApp = screen.app; elements = screen.elements }
            phase = .script
        }
    }

    static let streamWorkInterval: TimeInterval = 5

    /// A stage of a running script's lifecycle actually reached; counted as
    /// observed work only.
    mutating func applyScript(_ stage: ScriptStage) {
        guard !phase.isTerminal else { return }
        workObserved += 1
    }

    static let systemExpiredMessage = "后台任务已被系统或从系统任务界面结束，本轮已停止；已执行的步骤不会重放。请回到 PocketAgent 发送新消息继续。"

    /// The system's expiration handler fired. Not a user Stop: the turn ends
    /// as failed with this cause.
    mutating func markSystemExpired() {
        guard !phase.isTerminal else { return }
        systemExpired = true
        failure = Self.systemExpiredMessage
    }

    /// Whether an expiration callback for the turn accepted as `acceptedRunID`
    /// may stop the live turn. A late callback from an earlier turn, or one
    /// for a turn already final, must not cancel anything.
    func expirationApplies(acceptedRunID: String, currentRunID: String, busy: Bool) -> Bool {
        busy && acceptedRunID == currentRunID && !phase.isTerminal
    }

    /// Host cleanup has finished; the run is final.
    /// A successful AgentKit terminal means the goal was already completed, so
    /// a system expiry during host cleanup is not this turn's failure.
    mutating func finish(successful: Bool, cancelled: Bool, now: Date = Date()) {
        if successful { if failure == Self.systemExpiredMessage { failure = nil } }
        else if systemExpired { failure = Self.systemExpiredMessage }
        phase = successful ? .completed : systemExpired ? .failed
            : (cancelled || terminalState == .cancelled ? .cancelled : .failed)
        finishedAt = now
    }

    var phaseLabel: String {
        switch phase {
        case .queued(let rank, let waitingForForeground):
            waitingForForeground ? "排队中：回到 App 后开始" : "排队中：第 \(rank) 位，等待手机空闲"
        case .connecting: modelResponses == 0 && phoneActions == 0 ? "正在连接模型" : "等待模型决定下一步"
        case .modelResponse: "模型正在回复"
        case .phoneAction: "正在操作手机"
        case .workspaceTool: "正在读写项目文件"
        case .network: "正在请求网络"
        case .script: scriptPhoneActions > 0 ? "脚本运行中（已操作手机 \(scriptPhoneActions) 步）" : "脚本运行中"
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
        if [.phoneAction, .workspaceTool, .network, .script].contains(phase), let currentAction { parts.append(currentAction) }
        if let currentApp, !currentApp.isEmpty { parts.append(ToolLabels.appName(currentApp)) }
        return parts.joined(separator: " · ")
    }

    var stepsLabel: String {
        var parts: [String] = []
        if phoneActions > 0 {
            parts.append(failedActions > 0 ? "\(phoneActions) 步（\(failedActions) 步失败）" : "\(phoneActions) 步")
        }
        if otherSteps > 0 {
            parts.append("文件/网络/脚本 \(otherSteps) 次" + (failedOtherSteps > 0 ? "（\(failedOtherSteps) 次失败）" : ""))
        }
        return parts.joined(separator: "，")
    }

    /// One line for the system task surface while another app is in front.
    var subtitle: String {
        ([phaseLabel, activity, stepsLabel.isEmpty ? "" : "已执行 \(stepsLabel)"]).filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Completed real work units (model responses, steps and observed work
    /// inside a running step) with the one unit currently in flight.
    /// BGContinuedProcessingTask requires progress reporting and stalls a
    /// task whose completed count stops changing; this never encodes a
    /// request budget, a timer or a guess about how much work remains.
    var progressUnits: (completed: Int64, total: Int64) {
        let done = Int64(modelResponses + phoneActions + otherSteps + workObserved)
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
        case "list_files": "列出文件"
        case "read_file": "读取文件"
        case "search_files": "搜索文件"
        case "write_file": "写入文件"
        case "patch_file": "修改文件"
        case "read_skill": "读取技能"
        case "http_request": "网络请求"
        case "run_script": "运行脚本"
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
        case "list_files", "read_file", "write_file", "patch_file":
            return name(call.name) + " " + (args["path"]?.stringValue ?? ".")
        case "search_files": return "搜索「\((args["pattern"]?.stringValue ?? "").prefix(20))」"
        case "read_skill": return "读取技能 " + (args["name"]?.stringValue ?? "")
        case "http_request":
            let url = URL(string: args["url"]?.stringValue ?? "")
            return (args["method"]?.stringValue ?? "GET").uppercased() + " " + (url?.host ?? "")
        case "run_script":
            let language = args["language"]?.stringValue ?? ""
            return "运行 \(language) 脚本" + (args["path"]?.stringValue.map { " \($0)" } ?? "")
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
    /// Phone actions a run_script call performed, from its own result.
    var children: [ScriptPhoneRecord] { result.map { ScriptPhoneRecord.parse($0.text) } ?? [] }

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

/// Script lifecycle stages actually reached, reported to the status reducer.
nonisolated enum ScriptStage: String, Sendable {
    case runtimeReady, processStarted, outputGrew
}

/// Live phone request from a running script, reported to the status reducer.
nonisolated enum ScriptPhoneEvent: Sendable {
    case started(AgentToolCall)
    case finished(AgentToolCall, content: String, isError: Bool)
}

/// One phone action recorded inside a run_script result (`phone_actions`).
nonisolated struct ScriptPhoneRecord: Hashable, Sendable, Codable {
    var tool: String
    var label: String
    var ok: Bool
    var detail: String

    static func parse(_ content: String) -> [ScriptPhoneRecord] {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = object["phone_actions"] as? [[String: Any]] else { return [] }
        return actions.map {
            ScriptPhoneRecord(tool: $0["tool"] as? String ?? "", label: $0["label"] as? String ?? "",
                              ok: $0["ok"] as? Bool ?? false, detail: $0["detail"] as? String ?? "")
        }
    }
}
