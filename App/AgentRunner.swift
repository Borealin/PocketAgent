import AgentKit
import BackgroundTasks
import Foundation

// Host integration only: the pinned AgentKit package owns the agent loop.
@MainActor
extension Model {
    /// `config` was captured when the turn was enqueued and is used verbatim.
    /// `images` were hydrated from the turn's frozen attachment references.
    func beginAgent(goal: String, images: [AgentImageAttachment], config: RunConfiguration, workspace: WorkspaceSnapshot?, backend: PhoneBackendKind,
                    clipboardAllowed: Bool,
                    conversationID: UUID, promptID: UUID, priorMessages: [AgentTranscriptMessage],
                    onEvent: (@MainActor (AgentEvent, ExecutionStatus) -> Void)?,
                    onStatus: (@MainActor (ExecutionStatus) -> Void)?,
                    onFinished: (@MainActor (Bool, String, ExecutionStatus) -> Void)?) {
        guard !busy else { return }
        do {
            guard !goal.isEmpty || !images.isEmpty else { throw failure("消息不能为空。") }
            runID = UUID().uuidString
            logURL = documents.appendingPathComponent("run-\(runID).jsonl")
            busy = true
            pendingAgentCancellation = false
            // The turn's single status and identity exist before the system can
            // call back, so an expiration before or after the turn body runs is
            // attributed to this turn only.
            let acceptedRunID = runID
            let status = TurnStatus(ExecutionStatus(modelLabel: config.label))
            let identifier = "\(Bundle.main.bundleIdentifier ?? "PocketAgent").run.\(runID)"
            guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                // Determinate progress is published before the handler returns;
                // the turn updates this same object from then on.
                let progress = task.progress
                progress.totalUnitCount = 1
                progress.completedUnitCount = 0
                // Installed before any hop so no expiration goes unhandled.
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        self?.expireTurn(acceptedRunID, status: status, task: task, progress: progress)
                    }
                }
                Task { @MainActor in
                    self?.executePhoneAgent(config: config, workspace: workspace, backend: backend, clipboardAllowed: clipboardAllowed, goal: goal, images: images,
                        task: task, progress: progress, status: status,
                        conversationID: conversationID, promptID: promptID, priorMessages: priorMessages,
                        onEvent: onEvent, onStatus: onStatus, onFinished: onFinished)
                }
            }) else { throw failure("Background task registration failed") }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                title: status.value.systemTaskTitle, subtitle: status.value.systemTaskSubtitle)
            request.strategy = .fail
            // Diagnostics carry no prompt, endpoint or key.
            log("agent_submitted", ["format": config.format.rawValue, "imageInput": config.supportsImages,
                "promptImages": images.count,
                "os": ProcessInfo.processInfo.operatingSystemVersionString])
            try BGTaskScheduler.shared.submit(request)
        } catch {
            busy = false; log("failed", Model.errorFields(error))
            var status = ExecutionStatus(modelLabel: config.label)
            status.failure = error.localizedDescription
            status.finish(successful: false, cancelled: false)
            onFinished?(false, "", status)
        }
    }

    /// Error identity without message text, which may echo personal content.
    static func errorFields(_ error: any Error) -> [String: Any] {
        let error = error as NSError
        return ["errorDomain": error.domain, "errorCode": error.code]
    }
}
