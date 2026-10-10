import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// BGContinuedProcessingTask is stalled and then expired when its completed
/// unit count stops changing, so real work inside a long step must advance it
/// without touching the visible step counts.
@Suite struct ProgressLivenessTests {
    private let call = AgentToolCall(id: "s1", name: "observe_screen", arguments: .object([:]))

    @Test func streamedOutputAdvancesProgressAtMostOncePerWindow() {
        var status = ExecutionStatus()
        let message = UUID(), start = Date(timeIntervalSince1970: 1_000)
        status.apply(.reasoningDelta(messageID: message, text: "a"), now: start)
        #expect(status.progressUnits == (1, 2))
        status.apply(.messageDelta(messageID: message, text: "b"), now: start.addingTimeInterval(1))
        status.apply(.messageDelta(messageID: message, text: "c"), now: start.addingTimeInterval(4.9))
        #expect(status.progressUnits == (1, 2), "chunks inside one window count once")
        status.apply(.messageDelta(messageID: message, text: "d"), now: start.addingTimeInterval(5))
        #expect(status.progressUnits == (2, 3))
        #expect(status.modelResponses == 0 && status.stepsLabel.isEmpty)
    }

    @Test func scriptStagesAndRequestsAdvanceProgressNotSteps() {
        var status = ExecutionStatus()
        status.apply(.toolStarted(AgentToolInvocation(runID: UUID(),
            call: AgentToolCall(id: "r", name: "run_script", arguments: .object([:])))))
        status.applyScript(ScriptStage.runtimeReady)
        status.applyScript(ScriptStage.processStarted)
        status.applyScript(ScriptStage.outputGrew)
        #expect(status.progressUnits == (3, 4))
        #expect(status.phoneActions == 0 && status.otherSteps == 0 && status.stepsLabel.isEmpty)
        status.applyScript(ScriptPhoneEvent.started(call))
        #expect(status.progressUnits == (4, 5) && status.phoneActions == 0)
        status.applyScript(ScriptPhoneEvent.finished(call, content: "失败", isError: true))
        #expect(status.progressUnits == (5, 6))
        #expect(status.phoneActions == 1 && status.scriptPhoneActions == 1 && status.stepsLabel == "1 步（1 步失败）")
    }

    @Test func systemExpirationFailsWithItsCauseNotAsUserStop() {
        var status = ExecutionStatus()
        status.markSystemExpired()
        status.apply(.failed("cancelled"))
        status.apply(.runFinished(AgentRunSummary(id: UUID(), state: .cancelled, startedAt: Date())))
        status.finish(successful: false, cancelled: true)
        #expect(status.phase == .failed)
        #expect(status.failure == ExecutionStatus.systemExpiredMessage)

        var stopped = ExecutionStatus()
        stopped.apply(.runFinished(AgentRunSummary(id: UUID(), state: .cancelled, startedAt: Date())))
        stopped.finish(successful: false, cancelled: true)
        #expect(stopped.phase == .cancelled && stopped.failure == nil)
    }

    @Test func successfulFinishAfterSystemExpirationCompletesWithoutFailure() {
        var status = ExecutionStatus()
        status.markSystemExpired()
        status.finish(successful: true, cancelled: true)
        #expect(status.phase == .completed && status.failure == nil)

        var stopped = ExecutionStatus()
        stopped.finish(successful: false, cancelled: true)
        #expect(stopped.phase == .cancelled && stopped.failure == nil)
    }

    @Test func terminalStatusIgnoresLateWork() {
        var status = ExecutionStatus()
        status.finish(successful: true, cancelled: false)
        status.applyScript(ScriptStage.outputGrew)
        status.markSystemExpired()
        #expect(status.progressUnits == (1, 1) && status.phase == .completed && status.failure == nil)
    }

    @Test func expirationBeforeTheTurnBodyFailsThatTurnWithItsCause() {
        var status = ExecutionStatus()
        #expect(status.expirationApplies(acceptedRunID: "a", currentRunID: "a", busy: true))
        status.markSystemExpired()
        // The body then sees the pending cancellation and stops before any work.
        status.finish(successful: false, cancelled: true)
        #expect(status.phase == .failed && status.failure == ExecutionStatus.systemExpiredMessage)
        #expect(!status.expirationApplies(acceptedRunID: "a", currentRunID: "a", busy: true))
    }

    @Test func lateExpirationNeverStopsAnotherTurn() {
        // A queued callback from a finished turn while the next turn runs.
        var finished = ExecutionStatus()
        finished.finish(successful: true, cancelled: false)
        #expect(!finished.expirationApplies(acceptedRunID: "a", currentRunID: "b", busy: true))
        // Even a non-final status never applies to another run or an idle model.
        let live = ExecutionStatus()
        #expect(!live.expirationApplies(acceptedRunID: "a", currentRunID: "b", busy: true))
        #expect(!live.expirationApplies(acceptedRunID: "a", currentRunID: "a", busy: false))
    }
}
