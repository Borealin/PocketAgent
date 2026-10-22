import AgentKit
import Foundation

/// Thread-safe set read by the nonisolated request gate.
final class SyntheticIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []
    var value: Set<UUID> { lock.withLock { ids } }
    func set(_ new: Set<UUID>) { lock.withLock { ids = new } }
}

/// Primary-line support for one accepted turn: bounded context before the
/// first request, fresh memory and forget filtering at every request, a hard
/// guard for known/explicit limits, read registration before dispatch, and
/// AgentKit's read-only memory/history tools. The AgentKit loop is unchanged.
@MainActor
final class AssistantTurnSupport {
    let owner: HistoryOwner
    let sessionID: UUID
    let promptID: UUID
    let scope: WorkScope
    let references: [HistoryReference]
    let config: RunConfiguration
    /// The run's commit epoch; a failed read registration fails it.
    let epoch: UInt64
    /// Whether this run still owns its session (not replaced, cancelled, revoked or finished).
    let isActive: @MainActor () -> Bool
    private let synthetic = SyntheticIDs()
    /// Every request's preparation (Core, shared with the gate tests).
    private let requests: AssistantRequestPreparer
    /// Outcome of context maintenance this turn (shown in the status detail).
    private(set) var maintenanceNote: String?
    let precompaction = PrecompactionTask()
    /// Metadata of each summary fold's provider request (opt-in run log).
    var observeStream: (@Sendable (ModelStreamTrace) -> Void)?
    /// Receives the estimate of every complete request, before the ceiling check.
    var onEstimate: (@MainActor (Int) -> Void)? {
        get { requests.onEstimate }
        set { requests.onEstimate = newValue }
    }
    /// A forget invalidated the included summary (with this many dependent raw messages).
    var onExclusion: (@MainActor (Int) -> Void)? {
        get { requests.onExclusion }
        set { requests.onExclusion = newValue }
    }
    /// A reference quote's window was masked, deleted or changed since the context was built.
    var onQuoteExclusion: (@MainActor (Int) -> Void)? {
        get { requests.onQuoteExclusion }
        set { requests.onQuoteExclusion = newValue }
    }
    private var calibrationKey: EstimatorCalibration.Key {
        .init(providerID: config.providerID, modelID: config.modelID, images: config.supportsImages)
    }

    init(owner: HistoryOwner, sessionID: UUID, promptID: UUID, scope: WorkScope, references: [HistoryReference],
         config: RunConfiguration, epoch: UInt64, isActive: @escaping @MainActor () -> Bool) {
        self.owner = owner; self.sessionID = sessionID; self.promptID = promptID; self.scope = scope
        self.references = references; self.config = config; self.epoch = epoch; self.isActive = isActive
        let key = EstimatorCalibration.Key(providerID: config.providerID, modelID: config.modelID, images: config.supportsImages)
        requests = AssistantRequestPreparer(owner: owner, sessionID: sessionID, promptID: promptID, scope: scope,
                                            budget: config.budget, estimator: { EstimatorCalibration.shared.estimator(key) })
    }

    nonisolated var syntheticIDs: Set<UUID> { synthetic.value }

    // MARK: Before the first request

    /// `onWork` receives coalesced counts of real summary text/reasoning
    /// increments (at most one pending MainActor delivery).
    func prepareContext(prompt: AgentTranscriptMessage, systemPrompt: String, tools: [AgentToolDescriptor],
                        provider: AgentProviderClient, deadline: TurnDeadline,
                        onWork: @escaping @MainActor @Sendable (Int) -> Void) async throws -> [AgentTranscriptMessage] {
        var prepared = build(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
        // An indivisible group or previous summary that cannot be folded is
        // reported, never silently skipped (the messages stay raw).
        maintenanceNote = prepared.refusal?.note
        if let plan = prepared.plan {
            do {
                try await summarize(plan, provider: provider, deadline: deadline, onWork: onWork)
                prepared = build(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
                maintenanceNote = plan.blocked?.note
            } catch where SummaryMaintenance.stopsTurn(error) {
                // Stop, system expiry, the turn deadline, storage or an explicit
                // forget of a source: stop the turn, no main request.
                throw error
            } catch {
                // No summary this turn and no automatic retry; a known or
                // explicit ceiling is still enforced before every request.
                maintenanceNote = (error as? LocalizedError)?.errorDescription ?? "上下文整理未完成。"
            }
        }
        synthetic.set(prepared.syntheticIDs)
        requests.rawRoots = prepared.rawRoots
        requests.summaryRoots = prepared.summaryRoots
        requests.summaryMessageID = prepared.summaryID.flatMap { id in
            owner.file.assistant.compactions.first { $0.id == id }?.record.summaryMessageID
        }
        requests.quotes = prepared.quotes
        requests.partialSuffix = prepared.partialSuffix
        let session = owner.file.session(sessionID)
        return AttachmentHydration.context(prepared.messages, attachments: session?.attachments ?? [:],
                                           supportsImages: config.supportsImages, load: attachmentFiles.data)
    }

    private func build(prompt: AgentTranscriptMessage, systemPrompt: String, tools: [AgentToolDescriptor]) -> PreparedContext {
        AssistantContext.build(.init(file: owner.file, sessionID: sessionID, promptID: promptID, scope: scope,
                                     references: references, budget: config.budget,
                                     estimator: EstimatorCalibration.shared.estimator(calibrationKey),
                                     systemPrompt: systemPrompt, tools: tools, prompt: [prompt]))
    }

    /// Tool-free summary folds over AgentKit's bounded `consume` (transport
    /// bytes, SSE line and event count capped; terminal required). Each fold is
    /// checked before dispatch (storage, forgets, eligibility, complete request
    /// estimate against the frozen budget) and committed by CAS. All folds
    /// share one 150 s maintenance deadline that never passes the turn
    /// deadline; idle is 45 s per attempt.
    private func summaryProducer(_ provider: AgentProviderClient) -> StreamingSummary.Producer {
        // Local acceptance launch arguments only (DeviceSettings); all absent by default.
        let hold = DeviceSettings.maintenanceDispatchHold
        let injected = DeviceSettings.injectSlowSummaryStream
        let recorder = DeviceSettings.recordMaintenanceStream ? MaintenanceStreamRecorder(injected: injected) : nil
        let stopAtText = DeviceSettings.stopAtFirstSummaryText
        let observe = observeStream
        return { request, onEvent in
            if let hold { try await Task.sleep(for: hold) }
            recorder?.started()
            var trace = ModelStreamTrace(path: .summary)
            observe?(trace)
            do {
                if injected {
                    for index in 0..<80 {
                        try await Task.sleep(for: .seconds(3))
                        let event = AgentModelStreamEvent.textDelta("整理测试\(index)。")
                        recorder?.saw(event)
                        trace.saw(event)
                        try onEvent(event)
                    }
                } else {
                    try await provider.consume(request, limits: .maintenance) { event in
                        recorder?.saw(event)
                        trace.saw(event)
                        if stopAtText, recorder?.takeFirstText(event) == true {
                            Task { @MainActor in NotificationCenter.default.post(name: DeviceSettings.diagnosticStop, object: nil) }
                        }
                        try onEvent(event)
                    }
                }
                recorder?.finished("completed")
                trace.finished(); observe?(trace)
            } catch {
                recorder?.finished(String(describing: type(of: error)) + (Task.isCancelled ? " after cancellation" : ""))
                trace.failed(error, cancelled: Task.isCancelled); observe?(trace)
                throw ProviderContextLimit.classify(error, path: .summary) ?? error
            }
        }
    }

    private func summarize(_ plan: SummaryPlan, provider: AgentProviderClient, deadline: TurnDeadline,
                           onWork: @escaping @MainActor @Sendable (Int) -> Void) async throws {
        try await SummaryMaintenance.run(
            plan, turn: .init(sessionID: sessionID, promptID: promptID, scope: scope, budget: config.budget,
                              estimator: EstimatorCalibration.shared.estimator(calibrationKey), summaryModel: config.label),
            owner: owner, producer: summaryProducer(provider), deadline: MaintenanceDeadline(turnRemaining: deadline.remaining),
            progress: ProgressCoalescer(deliver: onWork))
    }

    /// Called once tool work has begun, so maintenance never competes with
    /// the first model request. Only finished history before this prompt is
    /// eligible; at most one fold and thirty seconds, within the same turn.
    func startPrecompaction(prompt: AgentTranscriptMessage, systemPrompt: String, tools: [AgentToolDescriptor],
                           provider: AgentProviderClient, deadline: TurnDeadline,
                           stopTurn: @escaping @MainActor (any Error) -> Void) {
        guard !precompaction.attempted, isActive(), deadline.remaining > 30 else { return }
        let estimator = EstimatorCalibration.shared.estimator(calibrationKey)
        let input = AssistantContext.Input(file: owner.file, sessionID: sessionID, promptID: promptID, scope: scope,
            references: references, budget: config.budget, estimator: estimator, systemPrompt: systemPrompt, tools: tools, prompt: [prompt])
        precompaction.start(plan: AssistantContext.precompactionPlan(input),
            turn: .init(sessionID: sessionID, promptID: promptID, scope: scope, budget: config.budget,
                        estimator: estimator, summaryModel: config.label),
            owner: owner, producer: summaryProducer(provider),
            deadline: MaintenanceDeadline(turnRemaining: deadline.remaining, total: 30), isActive: isActive,
            onFailure: { [weak self] error in
                guard let self else { return }
                self.maintenanceNote = "提前整理未完成：" + error.localizedDescription
                if let storage = error as? StorageCommitError { self.owner.barrier.fail(epoch: self.epoch, storage) }
                if SummaryMaintenance.stopsTurn(error) { stopTurn(error) }
            })
    }

    // MARK: Every request

    func prepareRequest(_ request: AgentModelRequest) async throws -> AgentModelRequest {
        try requests.prepare(request)
    }

    func observeUsage(_ usage: AgentTokenUsage) {
        guard let raw = requests.lastRawEstimate, usage.inputTokens > 0 else { return }
        EstimatorCalibration.shared.record(calibrationKey, estimatedRaw: raw, actualInputTokens: usage.inputTokens)
    }

    // MARK: Read-only tools

    func readTools() -> [AnyAgentTool] {
        let owner = owner, root = promptID, scope = scope, references = references, epoch = epoch, isActive = isActive
        let adapter = PocketMemoryAdapter(scope: scope, currentRoot: root, references: references,
            snapshot: { await MainActor.run { owner.file } },
            commit: { plan in
                try await MainActor.run { try ReadCommitGate.commit(plan, owner: owner, root: root, scope: scope,
                                                                    references: references, epoch: epoch, isActive: isActive) }
            })
        return [AnyAgentTool(MemorySearchTool(store: adapter)), AnyAgentTool(SessionSearchTool(store: adapter))]
    }
}

/// Local acceptance only (`-PocketAgentRecordMaintenanceStream`): what one
/// maintenance fold's producer actually received — event kinds and sizes, the
/// first text time, a diagnostic stop request and how it ended — without any
/// content. One file per fold in Documents.
final class MaintenanceStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let injected: Bool
    private var start = 0.0, firstText: Double?, stopRequested: Double?
    private var counts: [String: Int] = [:], textCharacters = 0, reasoningCharacters = 0

    init(injected: Bool) { self.injected = injected }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func started() { lock.withLock { start = Self.now() } }

    func saw(_ event: AgentModelStreamEvent) {
        lock.withLock {
            let kind: String
            switch event {
            case .textDelta(let text): kind = "textDelta"; textCharacters += text.count
                if firstText == nil, !text.isEmpty { firstText = Self.now() }
            case .textSnapshot(let text): kind = "textSnapshot"; textCharacters = max(textCharacters, text.count)
                if firstText == nil, !text.isEmpty { firstText = Self.now() }
            case .reasoningDelta(let text): kind = "reasoningDelta"; reasoningCharacters += text.count
            case .reasoningSnapshot(let text): kind = "reasoningSnapshot"; reasoningCharacters = max(reasoningCharacters, text.count)
            case .usage: kind = "usage"
            case .finished: kind = "finished"
            default: kind = "other"
            }
            counts[kind, default: 0] += 1
        }
    }

    /// True once, at the first non-empty text; records the stop request time.
    func takeFirstText(_ event: AgentModelStreamEvent) -> Bool {
        lock.withLock {
            guard stopRequested == nil, firstText != nil else { return false }
            switch event {
            case .textDelta(let text) where !text.isEmpty: stopRequested = Self.now(); return true
            case .textSnapshot(let text) where !text.isEmpty: stopRequested = Self.now(); return true
            default: return false
            }
        }
    }

    func finished(_ reason: String) {
        let report: [String: Any] = lock.withLock {
            let end = Self.now()
            var report: [String: Any] = ["source": injected ? "injected slow stream (no provider request)" : "configured provider stream",
                                         "eventCounts": counts, "textCharacters": textCharacters,
                                         "reasoningCharacters": reasoningCharacters, "secondsToEnd": end - start, "end": reason,
                                         "wallClock": ISO8601DateFormatter().string(from: Date())]
            if let firstText { report["secondsToFirstText"] = firstText - start }
            if let stopRequested { report["secondsToStopRequest"] = stopRequested - start }
            return report
        }
        let name = "maintenance-stream-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
