import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

private let runID = UUID()
private func invocation(_ name: String, _ id: String, _ args: [String: AgentJSONValue] = [:]) -> AgentToolInvocation {
    AgentToolInvocation(runID: runID, call: AgentToolCall(id: id, name: name, arguments: .object(args)))
}
private func result(_ id: String, app: String? = nil, error: Bool = false) -> AgentToolResult {
    let content = app.map { #"{"ok":true,"screen":{"app":"\#($0)","elements":[]}}"# } ?? "失败"
    return AgentToolResult(callID: id, content: content, isError: error)
}

struct ExecutionStatusTests {
    @Test func realEventsDriveOnePhaseSequence() {
        var status = ExecutionStatus(modelLabel: "P · m")
        let started = Date(timeIntervalSince1970: 100)
        status.apply(.runStarted(AgentRunSummary(id: runID, state: .running, startedAt: started)))
        #expect(status.phase == .connecting && status.startedAt == started && status.phaseLabel == "正在连接模型")
        let reply = AgentTranscriptMessage(role: .assistant, text: "")
        status.apply(.messageStarted(reply))
        #expect(status.phase == .modelResponse)
        status.apply(.messageFinished(reply))
        status.apply(.toolStarted(invocation("open_app", "c1", ["bundle_id": .string("com.apple.Preferences")])))
        #expect(status.phase == .phoneAction && status.activity == "打开 设置")
        status.apply(.toolFinished(invocation("open_app", "c1"), result("c1", app: "com.apple.Preferences")))
        #expect(status.phoneActions == 1 && status.currentApp == "com.apple.Preferences")
        #expect(status.phase == .connecting && status.phaseLabel == "等待模型决定下一步")
        status.apply(.toolStarted(invocation("tap", "c2", ["node": .number(3)])))
        status.apply(.toolFinished(invocation("tap", "c2"), result("c2", error: true)))
        #expect(status.stepsLabel == "2 步（1 步失败）")
        #expect(status.currentApp == "com.apple.Preferences", "an error result keeps the last observed app")
        status.apply(.modelRetryScheduled(AgentModelRetryProgress(runID: runID, messageID: UUID(), attempt: 1, maximumAttempts: 2)))
        #expect(status.phaseLabel == "连接中断，正在重试（1/2）")
        status.apply(.modelRetryRecovered(AgentModelRetryProgress(runID: runID, messageID: UUID(), attempt: 1, maximumAttempts: 2)))
        #expect(status.phase == .modelResponse)
        status.apply(.runFinished(AgentRunSummary(id: runID, state: .completed, startedAt: started)))
        #expect(status.phase == .finishing)
        #expect(status.subtitle.contains("正在返回 App") && status.subtitle.contains("已执行 2 步"))
        status.finish(successful: true, cancelled: false)
        #expect(status.phase == .completed)
        status.apply(.toolStarted(invocation("tap", "late")))
        #expect(status.phase == .completed, "terminal state is final")
    }

    @Test func failureKeepsFirstReasonAndTerminalStateFromRun() {
        var status = ExecutionStatus()
        status.apply(.failed("provider said no"))
        status.apply(.runFinished(AgentRunSummary(id: runID, state: .failed, startedAt: Date(), failure: "later")))
        status.finish(successful: false, cancelled: false)
        #expect(status.phase == .failed && status.failure == "provider said no")
        var cancelled = ExecutionStatus()
        cancelled.apply(.runFinished(AgentRunSummary(id: runID, state: .cancelled, startedAt: Date())))
        cancelled.finish(successful: false, cancelled: false)
        #expect(cancelled.phase == .cancelled)
    }

    @Test func needsUserOnlyFromSurfacedRequirement() {
        var status = ExecutionStatus()
        status.apply(.messageDelta(messageID: UUID(), text: "请问你要打开哪个？"))
        #expect(status.phase != .needsUser, "a question in text is not inferred as a requirement")
        status.apply(.runState(.waitingForUser))
        #expect(status.phase == .needsUser)
        status.apply(.runState(.running))
        #expect(status.phase == .connecting)
    }

    @Test func progressCountsCompletedWorkWithoutBudget() {
        var status = ExecutionStatus()
        #expect(status.progressUnits == (0, 1))
        status.apply(.messageFinished(AgentTranscriptMessage(role: .assistant, text: "x")))
        status.apply(.toolFinished(invocation("wait", "w"), result("w", app: "a")))
        #expect(status.progressUnits == (2, 3))
        status.finish(successful: true, cancelled: false)
        #expect(status.progressUnits == (2, 2))
    }

    @Test func elementActionsUseVisibleLabelsNotNodeNumbers() {
        var status = ExecutionStatus()
        let observed = #"{"ok":true,"screen":{"app":"com.apple.Preferences","elements":[{"node":3,"label":"通用"},{"node":4,"label":"","name":"search"}]}}"#
        status.apply(.toolFinished(invocation("observe_screen", "o"), AgentToolResult(callID: "o", content: observed)))
        status.apply(.toolStarted(invocation("tap", "t", ["node": .number(3), "snapshot_id": .number(1)])))
        #expect(status.activity == "点击「通用」 · 设置")
        status.apply(.toolStarted(invocation("long_press", "l", ["node": .number(4)])))
        #expect(status.currentAction == "长按「search」")
        status.apply(.toolStarted(invocation("tap", "u", ["node": .number(99)])))
        #expect(status.currentAction == "点击屏幕元素")
        #expect(!(status.currentAction ?? "").contains("#"))
        let typing = AgentToolCall(id: "x", name: "type_text", arguments: .object(["node": .number(4), "text": .string("天气"), "clear": .bool(true)]))
        #expect(ToolLabels.action(typing, elements: [4: "搜索"]) == "在「搜索」输入「天气」")
    }

    @Test func everyToolLabelIsReadableWithoutInternalIDs() {
        let args: [String: AgentJSONValue] = ["node": .number(7), "snapshot_id": .number(3), "x": .number(1), "y": .number(2),
                                              "direction": .string("up"), "key": .string("return"), "seconds": .number(1),
                                              "bundle_id": .string("com.example.app"), "text": .string("hi"), "clear": .bool(false)]
        for name in ["observe_screen", "open_app", "tap", "tap_point", "long_press", "swipe", "type_text", "press_key",
                     "dismiss_keyboard", "press_home", "wait"] {
            let label = ToolLabels.action(AgentToolCall(id: "c", name: name, arguments: .object(args)))
            #expect(!label.isEmpty && !label.contains("#") && !label.contains("node") && !label.contains("snapshot"), "\(name): \(label)")
            #expect(label != name, "\(name) has a human label")
        }
    }

    @Test func queuedRankLabels() {
        #expect(ExecutionStatus(phase: .queued(rank: 2, waitingForForeground: false)).phaseLabel == "排队中：第 2 位，等待手机空闲")
        #expect(ExecutionStatus(phase: .queued(rank: 1, waitingForForeground: true)).phaseLabel == "排队中：回到 App 后开始")
        #expect(ExecutionStatus(phase: .queued(rank: 1, waitingForForeground: false)).phaseLabel == "排队中：第 1 位，等待手机空闲")
    }
}

struct TranscriptItemTests {
    @Test func toolCallsPairWithResultsAndFoldInOrder() {
        let user = AgentTranscriptMessage(role: .user, text: "打开设置")
        let call1 = AgentToolCall(id: "c1", name: "open_app", arguments: .object([:]))
        let call2 = AgentToolCall(id: "c2", name: "observe_screen", arguments: .object([:]))
        let a1 = AgentTranscriptMessage(role: .assistant, toolCalls: [call1])
        let r1 = AgentTranscriptMessage(role: .tool, text: "ok", toolCallID: "c1", toolName: "open_app")
        let a2 = AgentTranscriptMessage(role: .assistant, toolCalls: [call2])
        let r2 = AgentTranscriptMessage(role: .tool, text: "bad", toolCallID: "c2", toolName: "observe_screen", isError: true)
        let final = AgentTranscriptMessage(role: .assistant, text: "完成")
        let items = TranscriptItem.build([user, a1, r1, a2, r2, final])
        #expect(items.count == 3)
        guard case .tools(let id, let steps) = items[1] else { Issue.record("expected tools"); return }
        #expect(id == a1.id && steps.map(\.id) == ["c1", "c2"])
        #expect(steps[0].status(running: false) == .succeeded && steps[1].status(running: false) == .failed)
        #expect(items[2] == .message(final))
    }

    @Test func timelineStepLabelsResolveAgainstPrecedingObservation() {
        let observe = AgentToolCall(id: "o", name: "observe_screen", arguments: .object([:]))
        let tap = AgentToolCall(id: "t", name: "tap", arguments: .object(["node": .number(2), "snapshot_id": .number(1)]))
        let screen = #"{"ok":true,"screen":{"app":"com.apple.AppStore","elements":[{"node":2,"label":"搜索"}]}}"#
        let items = TranscriptItem.build([
            AgentTranscriptMessage(role: .assistant, toolCalls: [observe]),
            AgentTranscriptMessage(role: .tool, text: screen, toolCallID: "o"),
            AgentTranscriptMessage(role: .assistant, toolCalls: [tap])])
        guard case .tools(_, let steps) = items[0] else { Issue.record("expected tools"); return }
        #expect(steps.map(\.label) == ["读取屏幕", "点击「搜索」"])
    }

    @Test func unansweredCallsArePendingOnlyWhileRunning() {
        let call = AgentToolCall(id: "c9", name: "tap", arguments: .object([:]))
        let items = TranscriptItem.build([AgentTranscriptMessage(role: .assistant, text: "我来点", toolCalls: [call])])
        #expect(items.count == 2)
        guard case .tools(_, let steps) = items[1] else { Issue.record("expected tools"); return }
        #expect(steps[0].status(running: true) == .pending && steps[0].status(running: false) == .noResult)
    }

    @Test func reusedCallIDsPairWithNearestOpenCallAndOrphansStay() {
        let call = AgentToolCall(id: "call_0", name: "wait", arguments: .object([:]))
        let run1 = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        let res1 = AgentTranscriptMessage(role: .tool, text: "1", toolCallID: "call_0")
        let between = AgentTranscriptMessage(role: .user, text: "继续")
        let run2 = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        let res2 = AgentTranscriptMessage(role: .tool, text: "2", toolCallID: "call_0")
        let orphan = AgentTranscriptMessage(role: .tool, text: "?", toolCallID: "gone")
        let items = TranscriptItem.build([run1, res1, between, run2, res2, orphan])
        guard case .tools(_, let first) = items[0], case .tools(_, let second) = items[2] else {
            Issue.record("expected two timelines"); return
        }
        #expect(first[0].result?.text == "1" && second[0].result?.text == "2")
        #expect(items.last == .orphanResult(orphan))
    }
}

struct MarkdownParserTests {
    @Test func blocks() {
        let source = """
        # 标题 #
        段落 **粗体**
        第二行

        - 一
        - 二
          - 嵌套
        1. 甲
        2) 乙

        > 引用
        > - 列表

        ```swift
        let x = 1 | 2
        ```

        | 名称 | 数量 |
        |:---|---:|
        | a \\| b | `x|y` |
        | 只有一列 |

        ---
        - [x] 完成
        - [ ] 待办
        """
        let blocks = MarkdownParser.parse(source)
        #expect(blocks[0] == .heading(level: 1, text: "标题"))
        #expect(blocks[1] == .paragraph("段落 **粗体**\n第二行"))
        guard case .list(false, _, let bullets) = blocks[2] else { Issue.record("bullets \(blocks[2])"); return }
        #expect(bullets.count == 2)
        #expect(bullets[1].blocks == [.paragraph("二"), .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("嵌套")])])])
        guard case .list(true, 1, let ordered) = blocks[3] else { Issue.record("ordered \(blocks[3])"); return }
        #expect(ordered.count == 2)
        #expect(blocks[4] == .quote([.paragraph("引用"), .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("列表")])])]))
        #expect(blocks[5] == .code(language: "swift", text: "let x = 1 | 2", closed: true))
        #expect(blocks[6] == .table(MarkdownTable(header: ["名称", "数量"], alignments: [.leading, .trailing],
                                                  rows: [["a | b", "`x|y`"], ["只有一列", ""]])))
        #expect(blocks[7] == .rule)
        guard case .list(false, _, let tasks) = blocks[8] else { Issue.record("tasks"); return }
        #expect(tasks.map(\.checked) == [true, false])
        #expect(tasks[0].blocks == [.paragraph("完成")])
    }

    @Test func setextAndStreamingFence() {
        #expect(MarkdownParser.parse("标题\n===\n正文") == [.heading(level: 1, text: "标题"), .paragraph("正文")])
        #expect(MarkdownParser.parse("说明\n```py\nprint(1)") == [.paragraph("说明"), .code(language: "py", text: "print(1)", closed: false)])
    }

    @Test func everyPrefixOfStreamingTextParses() {
        let source = "## 步骤\n1. 打开 **设置\n   - 子项 `代码\n> 引用 [链接](https://exa\n| a | b |\n|--\n```\ncode\n~~~\n***\n- [x"
        var count = 0
        for end in source.indices {
            _ = MarkdownParser.parse(String(source[..<end]))
            count += 1
        }
        #expect(count == source.count)
    }

    @Test func randomInputNeverTraps() {
        var state: UInt64 = 42
        let alphabet = Array("#->*`~|:-1. []()!\\\n abc中")
        for _ in 0..<2000 {
            var text = ""
            for _ in 0..<Int(state % 80) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                text.append(alphabet[Int(state >> 33) % alphabet.count])
            }
            _ = MarkdownParser.parse(text)
            _ = MarkdownInline.attributed(text)
        }
        let deep = String(repeating: "> ", count: 200) + "x"
        #expect(!MarkdownParser.parse(deep).isEmpty)
        let nested = (0..<100).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        #expect(!MarkdownParser.parse(nested).isEmpty)
    }

    @Test func imageReferencesLoadOnlyHTTPSAndNeverDuringParsing() {
        let refs = MarkdownInline.images(in: #"看图 ![截图](https://example.com/a.png "t") ![本地](file:///x.png) ![明文](http://example.com/b.png) ![凭据](https://u:p@example.com/c.png) ![破损](https://exa"#)
        #expect(refs.map(\.alt) == ["截图", "本地", "明文", "凭据"])
        #expect(refs.map(\.isLoadable) == [true, false, false, false])
        #expect(refs[0].url == URL(string: "https://example.com/a.png"))
    }

    @Test func inlineLinkPolicy() {
        let text = MarkdownInline.attributed("[ok](https://example.com) [bad](javascript:alert(1)) [file](file:///etc/passwd) ![img](https://example.com/x.png)")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://example.com")!])
        #expect(text.runs.allSatisfy { $0.imageURL == nil })
        #expect(String(text.characters).contains("img"))
        #expect(MarkdownInline.isAllowed(URL(string: "mailto:a@example.com")!))
        #expect(!MarkdownInline.isAllowed(URL(string: "https:///nohost")!))
    }
}
