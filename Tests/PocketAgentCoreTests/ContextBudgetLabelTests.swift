import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// The chat strip's frozen budget and latest request estimate.
struct ContextBudgetLabelTests {
    @Test func eachBudgetSourceIsLabelledAndAnUnknownWindowIsNotALimit() throws {
        let known = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: 32_768))
        let explicit = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 20_000))
        var status = ExecutionStatus(modelLabel: "m · p", budget: known)
        #expect(status.contextLabel == "本轮 m · p：输入上限 \(known.hardCeiling!) token（已确认窗口 32768）")
        status.requestEstimate = 12_345
        #expect(status.contextLabel == "本轮 m · p：请求估计约 12345 token · 输入上限 \(known.hardCeiling!) token（已确认窗口 32768）")
        #expect(ExecutionStatus(budget: explicit).contextLabel == "本轮：本机输入上限 20000 token")
        let unknown = ExecutionStatus(budget: .unknown).contextLabel ?? ""
        #expect(unknown.contains("窗口未知") && unknown.contains("软目标") && unknown.contains("不是模型上限"))
        #expect(!unknown.contains("输入上限"))
        // Other turns show no budget.
        #expect(ExecutionStatus(modelLabel: "m").contextLabel == nil)
    }

    @Test func theFrozenBudgetAndLastEstimateOutliveEventsAndTheEnd() {
        var status = ExecutionStatus(modelLabel: "m", budget: .unknown)
        status.requestEstimate = 9_000
        status.apply(.messageDelta(messageID: UUID(), text: "x"))
        status.apply(.failed("模型服务拒绝了本次请求"))
        status.finish(successful: false, cancelled: false)
        #expect(status.phase == .failed && status.budget == .unknown && status.requestEstimate == 9_000)
        #expect(status.contextLabel?.hasPrefix("本轮 m：请求估计约 9000 token") == true)
        var stopped = ExecutionStatus(modelLabel: "m", budget: .unknown)
        stopped.requestEstimate = 4_000
        stopped.finish(successful: false, cancelled: true)
        #expect(stopped.phase == .cancelled && stopped.requestEstimate == 4_000)
    }

    /// Device finding: the refusal read "超过本机输入上限 1000输入上限 1000".
    @Test func theOverCeilingRefusalNamesTheCeilingOnce() throws {
        let explicit = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 1_000))
        let known = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: 32_768))
        for budget in [explicit, known] {
            let ceiling = try #require(budget.hardCeiling)
            let text = ContextBudgetError.overHardCeiling(estimated: 23_582, ceiling: ceiling, source: budget.label).errorDescription ?? ""
            #expect(text.hasPrefix("本次请求估计约 23582 token，超过输入上限 \(ceiling)（\(budget.label)）"))
            #expect(!text.contains("输入上限 \(ceiling)输入上限"))
        }
    }
}
