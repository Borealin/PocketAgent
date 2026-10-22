/// One owner at a time, handed over in arrival order. A waiter cancelled while
/// queued leaves without ever owning the gate; one cancelled as the gate is
/// handed to it takes it and passes it straight on, so there is never a second
/// owner and never an owner that nobody releases.
@MainActor
final class SerialGate {
    private var held = false
    private var nextID: UInt64 = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []

    init() {}

    var isHeld: Bool { held }
    var waiting: Int { waiters.count }

    /// Throws `CancellationError` without owning the gate when the task is
    /// cancelled before or while waiting.
    func acquire() async throws {
        try Task.checkCancellation()
        guard held else { held = true; return }
        let id = nextID
        nextID += 1
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { @MainActor in self.withdraw(id) }
        }
        guard granted else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().continuation.resume(returning: true) }
    }

    private func withdraw(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
