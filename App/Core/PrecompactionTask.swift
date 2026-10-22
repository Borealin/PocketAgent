import Foundation

/// Optional work within an already-authorized turn. It neither starts another
/// run nor changes that run's assembled model context. Stop cancels transport;
/// finish drains it before the host releases its system task and phone slot.
@MainActor
final class PrecompactionTask {
    enum Outcome: Equatable { case skipped, running, completed, cancelled, failed }
    private(set) var attempted = false
    private(set) var outcome: Outcome?
    private(set) var requiresTurnStop = false
    private var closed = false
    private var task: Task<Void, Never>?

    func start(plan: SummaryPlan?, turn: SummaryMaintenance.Turn, owner: HistoryOwner,
               producer: @escaping StreamingSummary.Producer, deadline: MaintenanceDeadline,
               isActive: @escaping @MainActor () -> Bool,
               onFailure: @escaping @MainActor (any Error) -> Void = { _ in }) {
        guard !attempted, !closed else { return }
        attempted = true
        guard let plan, isActive(), deadline.remaining > 0 else { outcome = .skipped; return }
        outcome = .running
        task = Task { @MainActor in
            defer { task = nil }
            do {
                try await SummaryMaintenance.run(plan, turn: turn, owner: owner, producer: producer,
                                                 deadline: deadline, isActive: isActive)
                outcome = .completed
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed
                requiresTurnStop = SummaryMaintenance.stopsTurn(error)
                onFailure(error)
            }
        }
    }

    func cancel() {
        closed = true
        task?.cancel()
    }

    func finish() async {
        let pending = task
        cancel()
        await pending?.value
    }

    func wait() async { await task?.value }
}
