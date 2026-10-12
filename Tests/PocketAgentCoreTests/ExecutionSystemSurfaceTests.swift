import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

@Suite struct ExecutionSystemSurfaceTests {
    private func invocation(_ name: String, _ id: String, _ arguments: [String: AgentJSONValue] = [:]) -> AgentToolInvocation {
        AgentToolInvocation(runID: UUID(), call: AgentToolCall(id: id, name: name, arguments: .object(arguments)))
    }

    @Test func actionUpdatesWithoutRepeatingAppPhaseOrCounts() {
        var status = ExecutionStatus(modelLabel: "Provider · model")
        let observed = #"{"ok":true,"screen":{"app":"com.apple.Preferences","elements":[{"node":3,"label":"通用"},{"node":4,"label":"返回"}]}}"#
        status.apply(.toolFinished(invocation("observe_screen", "o"), AgentToolResult(callID: "o", content: observed)))
        status.apply(.toolStarted(invocation("tap", "a", ["node": .number(3)])))
        #expect(status.systemTaskTitle == "点击「通用」")
        #expect(status.systemTaskSubtitle.isEmpty)
        #expect(status.subtitle == "正在操作手机 · 点击「通用」 · 设置 · 已执行 1 步", "chat detail remains intact")
        let units = status.progressUnits
        status.apply(.toolStarted(invocation("tap", "b", ["node": .number(4)])))
        #expect(status.systemTaskTitle == "点击「返回」", "the title changes even when the subtitle stays empty")
        #expect(status.systemTaskSubtitle.isEmpty && status.progressUnits == units, "display changes do not fabricate work")
    }

    @Test func finishedActionDoesNotLingerDuringModelOrCleanup() {
        var status = ExecutionStatus()
        let open = invocation("open_app", "o", ["bundle_id": .string("com.apple.Preferences")])
        status.apply(.toolStarted(open))
        #expect(status.systemTaskTitle == "打开 设置")
        status.apply(.toolFinished(open, AgentToolResult(callID: "o", content: "ok")))
        #expect(status.currentAction == "打开 设置" && status.systemTaskTitle == "等待模型")
        status.apply(.messageDelta(messageID: UUID(), text: "done"))
        #expect(status.systemTaskTitle == "模型回复")
        status.apply(.runFinished(AgentRunSummary(id: UUID(), state: .completed, startedAt: Date())))
        #expect(status.systemTaskTitle == "结束自动化")
        let completed = status.progressUnits.completed
        status.finish(successful: true, cancelled: false)
        #expect(status.systemTaskTitle == "已完成")
        #expect(status.progressUnits == (completed, completed))
    }

    @Test func nativeAndScriptActionsUseTheSameActionText() {
        var status = ExecutionStatus(modelLabel: "Provider · model")
        status.apply(.toolStarted(invocation("read_file", "f", ["path": .string("AGENTS.md")])))
        #expect(status.systemTaskTitle == "读取文件 AGENTS.md")
        status.apply(.toolStarted(invocation("run_script", "s")))
        let phone = AgentToolCall(id: "p", name: "observe_screen", arguments: .object([:]))
        status.applyScript(.started(phone))
        #expect(status.systemTaskTitle == "脚本：读取屏幕")
        status.applyScript(.finished(phone, content: "ok", isError: false))
        #expect(status.systemTaskTitle == "运行脚本", "a finished nested phone action must not linger during script work")
        #expect(status.systemTaskSubtitle.isEmpty && !status.systemTaskTitle.contains(status.modelLabel))
        #expect(status.phoneActions == 1 && status.scriptPhoneActions == 1 && status.progressUnits == (2, 3))
    }

    @Test func fallbackCoversLifecycleWithoutCarryingStaleActionOrModelIdentity() {
        let phases: [ExecutionPhase] = [.queued(rank: 2, waitingForForeground: false),
            .queued(rank: 1, waitingForForeground: true), .connecting, .modelResponse,
            .phoneAction, .workspaceTool, .network, .script, .retrying(attempt: 1, maximum: 2),
            .needsUser, .finishing, .completed, .failed, .cancelled]
        for phase in phases {
            var status = ExecutionStatus(modelLabel: "Provider · model", phase: phase)
            status.currentAction = "  \n "
            status.currentApp = "com.apple.Preferences"
            status.phoneActions = 8
            #expect(!status.systemTaskTitle.isEmpty && status.systemTaskSubtitle.isEmpty)
            #expect(!status.systemTaskTitle.contains("手机助手") && !status.systemTaskTitle.contains("正在操作手机"))
            #expect(!status.systemTaskTitle.contains("Provider") && !status.systemTaskTitle.contains("已执行")
                && !status.systemTaskTitle.contains("设置"))
            if phase.isTerminal {
                #expect(status.progressUnits == (8, 8))
            } else {
                #expect(status.progressUnits == (8, 9))
            }
        }
        var failed = ExecutionStatus()
        failed.currentAction = "点击「返回」"
        failed.finish(successful: false, cancelled: false)
        #expect(failed.systemTaskTitle == "未完成")
        var cancelled = ExecutionStatus()
        cancelled.currentAction = "点击「返回」"
        cancelled.finish(successful: false, cancelled: true)
        #expect(cancelled.systemTaskTitle == "已取消")
    }
}
