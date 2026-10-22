import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct PrecompactionTests {
    private func fixture() throws -> (ContextBuilderTests.Fixture, AssistantContext.Input) {
        var fixture = ContextBuilderTests.Fixture()
        for _ in 0..<100 {
            try fixture.turn(String(repeating: "较早的问题和决定。", count: 80))
            let estimate = AssistantContext.build(fixture.input(prompt: UUID())).estimatedTokens
            if estimate > ContextBudgetPolicy.unknown.target / 2 { break }
        }
        let prompt = AgentTranscriptMessage(role: .user, text: "当前任务")
        try fixture.file.acceptRoot(prompt, attachments: [], in: fixture.primary, scope: .general)
        try fixture.file.commitDispatchPermit(root: prompt.id, sessionID: fixture.primary, scope: .general)
        return (fixture, fixture.input(prompt: prompt.id))
    }

    @Test func plansEarlyButNeverReadsTheActiveRootOrChangesTheBlockingPolicy() throws {
        let (_, input) = try fixture()
        let required = AssistantContext.build(input)
        #expect(required.estimatedTokens > input.budget.target / 2)
        #expect(required.estimatedTokens < input.budget.summaryTrigger)
        #expect(required.plan == nil)
        let plan = try #require(AssistantContext.precompactionPlan(input))
        #expect(plan.folds.count == 1)
        #expect(!plan.folds.flatMap { $0 }.contains { $0.root == input.promptID })
        #expect(!plan.folds.flatMap { $0 }.flatMap(\.messages).contains { $0.id == input.promptID })
        var missing = input
        missing.promptID = UUID()
        #expect(AssistantContext.precompactionPlan(missing) == nil)
    }

    @Test @MainActor func commitsOneFoldForTheNextTurnAndStartsOnlyOnce() async throws {
        let (fixture, input) = try fixture()
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let worker = PrecompactionTask()
        let requests = CallCounter()
        let producer: StreamingSummary.Producer = { _, emit in
            requests.increment()
            try emit(.textDelta("已核对的较早决定"))
            try emit(.finished(.completed))
        }
        let plan = try #require(AssistantContext.precompactionPlan(input))
        let turn = SummaryMaintenance.Turn(sessionID: fixture.primary, promptID: input.promptID, scope: .general,
            budget: input.budget, estimator: input.estimator, summaryModel: "test")
        worker.start(plan: plan, turn: turn, owner: owner, producer: producer,
                     deadline: MaintenanceDeadline(turnRemaining: 60, total: 30), isActive: { true })
        await worker.wait()
        #expect(worker.outcome == .completed)
        #expect(requests.count == 1)
        #expect(owner.file.assistant.compactions.count == 1)
        #expect(owner.file.primary?.messages == fixture.file.primary?.messages)
        worker.start(plan: plan, turn: turn, owner: owner, producer: producer,
                     deadline: MaintenanceDeadline(turnRemaining: 60), isActive: { true })
        await worker.wait()
        #expect(requests.count == 1)
        await worker.finish()
    }

    @Test @MainActor func cancellationDuringTheResponseCannotCommitLateText() async throws {
        let (fixture, input) = try fixture()
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let worker = PrecompactionTask()
        worker.start(plan: AssistantContext.precompactionPlan(input),
            turn: .init(sessionID: fixture.primary, promptID: input.promptID, scope: .general,
                        budget: input.budget, estimator: input.estimator, summaryModel: "test"),
            owner: owner, producer: { _, emit in
                await worker.cancel()
                try emit(.textDelta("late"))
                try emit(.finished(.completed))
            }, deadline: MaintenanceDeadline(turnRemaining: 60), isActive: { true })
        await worker.wait()
        #expect(worker.outcome == .cancelled)
        #expect(owner.file.assistant.compactions.isEmpty)
        await worker.finish()
    }

    @Test @MainActor func endingTheTurnBeforeTheReplyPreventsPublication() async throws {
        let (fixture, input) = try fixture()
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let worker = PrecompactionTask()
        let active = ActivePrecompactionTurn()
        worker.start(plan: AssistantContext.precompactionPlan(input),
            turn: .init(sessionID: fixture.primary, promptID: input.promptID, scope: .general,
                        budget: input.budget, estimator: input.estimator, summaryModel: "test"),
            owner: owner, producer: { _, emit in
                await MainActor.run { active.value = false }
                try emit(.textDelta("late"))
                try emit(.finished(.completed))
            }, deadline: MaintenanceDeadline(turnRemaining: 60), isActive: { active.value })
        await worker.wait()
        #expect(worker.outcome == .cancelled)
        #expect(owner.file.assistant.compactions.isEmpty)
    }

    @Test(arguments: ["edit", "forget"])
    @MainActor func staleOrForgottenSourcesCannotPublish(failure: String) async throws {
        let (fixture, input) = try fixture()
        let owner = HistoryOwner(file: fixture.file, writer: { _ in })
        let plan = try #require(AssistantContext.precompactionPlan(input))
        let source = try #require(plan.folds.first?.first)
        let messageID = try #require(source.messages.last?.id)
        let worker = PrecompactionTask()
        worker.start(plan: plan,
            turn: .init(sessionID: fixture.primary, promptID: input.promptID, scope: .general,
                        budget: input.budget, estimator: input.estimator, summaryModel: "test"),
            owner: owner, producer: { _, emit in
                try await MainActor.run {
                    try owner.transact { file in
                        if failure == "forget" {
                            try file.assistant.scopeIndex.mask(root: source.root, by: UUID())
                            file.assistant.memory.forgetEpoch += 1
                        } else {
                            try file.editSession(fixture.primary) { session in
                                let index = session.messages.firstIndex { $0.id == messageID }!
                                session.messages[index].text = "已更改的来源"
                            }
                        }
                    }
                }
                try emit(.textDelta("stale"))
                try emit(.finished(.completed))
            }, deadline: MaintenanceDeadline(turnRemaining: 60), isActive: { true })
        await worker.wait()
        #expect(worker.outcome == .failed)
        #expect(worker.requiresTurnStop == (failure == "forget"))
        #expect(owner.file.assistant.compactions.isEmpty)
    }

    @Test @MainActor func summarySaveFailureRequiresTheMainTurnToStop() async throws {
        let (fixture, input) = try fixture()
        let sink = PrecompactionSink()
        let owner = HistoryOwner(file: fixture.file, writer: { _ in
            if sink.fail { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let worker = PrecompactionTask()
        var storageFailure = false
        worker.start(plan: AssistantContext.precompactionPlan(input),
            turn: .init(sessionID: fixture.primary, promptID: input.promptID, scope: .general,
                        budget: input.budget, estimator: input.estimator, summaryModel: "test"),
            owner: owner, producer: { _, emit in
                await MainActor.run { sink.fail = true }
                try emit(.textDelta("not saved"))
                try emit(.finished(.completed))
            }, deadline: MaintenanceDeadline(turnRemaining: 60), isActive: { true },
            onFailure: { storageFailure = $0 is StorageCommitError })
        await worker.wait()
        #expect(worker.requiresTurnStop && storageFailure)
        #expect(worker.outcome == .failed)
        #expect(owner.file.assistant.compactions.isEmpty)
    }
}

@MainActor private final class ActivePrecompactionTurn { var value = true }
@MainActor private final class PrecompactionSink { var fail = false }
