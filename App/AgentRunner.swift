import AgentKit
import BackgroundTasks
import Foundation

// Host integration only: the pinned AgentKit package owns the agent loop.
@MainActor
extension Model {
    /// `config` was captured when the turn was enqueued and is used verbatim.
    func beginAgent(goal: String, config: RunConfiguration, conversationID: UUID, promptID: UUID,
                    priorMessages: [AgentTranscriptMessage],
                    onEvent: (@MainActor (AgentEvent) -> Void)?,
                    onFinished: (@MainActor (Bool, String) -> Void)?) {
        guard !busy else { return }
        do {
            guard !goal.isEmpty else { throw failure("消息不能为空。") }
            runID = UUID().uuidString
            logURL = documents.appendingPathComponent("run-\(runID).jsonl")
            busy = true
            pendingAgentCancellation = false
            let identifier = "\(Bundle.main.bundleIdentifier ?? "PocketAgent").run.\(runID)"
            guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                Task { @MainActor in
                    self?.executePhoneAgent(config: config, goal: goal, task: task, conversationID: conversationID,
                        promptID: promptID, priorMessages: priorMessages, onEvent: onEvent, onFinished: onFinished)
                }
            }) else { throw failure("Background task registration failed") }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                title: "手机助手", subtitle: "\(config.modelID) · 处理中")
            request.strategy = .fail
            // Diagnostics carry no prompt, endpoint or key.
            log("agent_submitted", ["format": config.format.rawValue, "imageInput": config.supportsImages,
                "os": ProcessInfo.processInfo.operatingSystemVersionString])
            try BGTaskScheduler.shared.submit(request)
        } catch { busy = false; log("failed", Model.errorFields(error)); onFinished?(false, "") }
    }

    /// Error identity without message text, which may echo personal content.
    static func errorFields(_ error: any Error) -> [String: Any] {
        let error = error as NSError
        return ["errorDomain": error.domain, "errorCode": error.code]
    }
}
