import AgentKit
import Foundation

/// Errors that end a turn without a provider/tool retry.
nonisolated enum TurnGateErrors {
    static func isTerminal(_ error: any Error) -> Bool {
        error is StorageCommitError || error is ContextBudgetError || error is ContextSourceRevoked
            || error is SummaryPreparationError || error is RequestCommitRequirement.MissingPrompt
    }
}

/// An explicit forget masked a source this run is using. The run stops before
/// its next model request; original messages and completed results stay.
nonisolated struct ContextSourceRevoked: LocalizedError, Equatable {
    var errorDescription: String? {
        "本轮使用的上下文来源已被你明确遗忘，已停止本轮；原文和已发生的结果保留。请发送新消息继续。"
    }
}

nonisolated struct SummaryPreparationError: LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { "上下文整理失败：\(detail)" }
}

/// Every actual model request of a gated run passes here: first the awaited
/// save acknowledgement of every real message since this run's prompt, then
/// the host's per-request preparation (memory refresh, projections, budget,
/// phone observation), then the provider. Gate errors are never retried.
nonisolated struct CommitGatedModel: AgentModelStreaming {
    let base: any AgentModelStreaming
    let barrier: TranscriptCommitBarrier
    let epoch: UInt64
    let promptID: UUID
    /// IDs of request-only messages the host itself built (summary, memory, repair).
    let synthetic: @Sendable () -> Set<UUID>
    let prepare: @Sendable (AgentModelRequest) async throws -> AgentModelRequest
    var commitTimeout: Duration = .seconds(30)

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let required = try RequestCommitRequirement.messages(in: request.messages, promptID: promptID,
                                                                         synthetic: synthetic())
                    try await barrier.wait(epoch: epoch, .messages(required), timeout: commitTimeout)
                    let prepared = try await prepare(request)
                    for try await event in base.stream(prepared) { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func shouldRetry(after error: any Error) -> Bool {
        TurnGateErrors.isTerminal(error) ? false : base.shouldRetry(after: error)
    }
}

/// Each tool dispatch waits until its assistant message (with these exact
/// arguments) and every earlier call's result in that message are saved,
/// then applies the host's decision. A gate failure denies the call: it is
/// never executed.
nonisolated struct CommitGatedApproval: AgentApprovalHandling {
    let barrier: TranscriptCommitBarrier
    let epoch: UInt64
    let decide: @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision
    var commitTimeout: Duration = .seconds(30)

    func authorize(_ request: AgentApprovalRequest, mode: AgentPermissionMode) async -> AgentApprovalDecision {
        guard let source = request.invocation.sourceMessageID else {
            return .deny("缺少工具调用来源，未执行。")
        }
        do {
            let digest = try MessageDigestDTO.callDigest(request.invocation.call)
            try await barrier.wait(epoch: epoch, .toolDispatch(runID: request.invocation.runID, sourceMessageID: source,
                                                               callID: request.invocation.call.id, callDigest: digest),
                                   timeout: commitTimeout)
        } catch {
            return .deny((error as? LocalizedError)?.errorDescription ?? "历史保存未确认，工具未执行。")
        }
        return await decide(request)
    }
}
