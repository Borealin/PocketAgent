import Foundation
import Testing
@testable import PocketAgentCore

/// The phone action gate and the budget of one native call.
@MainActor
struct DDICallGateTests {
    @Test func aCallLeavesRoomForItsCleanupWithinTheTurn() {
        #expect(DDICallBudget.seconds(remaining: 600) == 35)
        #expect(DDICallBudget.seconds(remaining: 40) == 18)
        #expect(DDICallBudget.seconds(remaining: 23) == 1)
        // Not enough for a call and its cleanup: nothing is dispatched.
        #expect(DDICallBudget.seconds(remaining: 22.5) == nil)
        #expect(DDICallBudget.seconds(remaining: 0) == nil)
        #expect(DDICallBudget.seconds(remaining: -5) == nil)
        // The local acceptance cap only lowers it.
        #expect(DDICallBudget.seconds(remaining: 600, cap: 5) == 5)
        #expect(DDICallBudget.seconds(remaining: 600, cap: 90) == 35)
    }

    @Test func imagePreparationNeverOutlivesItsBudgetOrTheTurn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let far = now.addingTimeInterval(600), near = now.addingTimeInterval(40)
        // The check: 15 s, cut by the turn's end; none once the turn has ended.
        #expect(DDIImagePreparation.checkExpiry(now: now, turnEnd: far) == now.addingTimeInterval(15))
        #expect(DDIImagePreparation.checkExpiry(now: now, turnEnd: now.addingTimeInterval(3)) == now.addingTimeInterval(3))
        #expect(DDIImagePreparation.checkExpiry(now: now, turnEnd: now) == nil)
        // Downloads and the mount share 180 s, cut by the turn's end.
        #expect(DDIImagePreparation.preparationEnd(now: now, turnEnd: far) == now.addingTimeInterval(180))
        let end = DDIImagePreparation.preparationEnd(now: now, turnEnd: near)
        #expect(end == near)
        // The mount: at most 120 s and what is left; not started with < 5 s left.
        #expect(DDIImagePreparation.mountExpiry(now: now, preparationEnd: now.addingTimeInterval(180)) == now.addingTimeInterval(120))
        #expect(DDIImagePreparation.mountExpiry(now: now, preparationEnd: end) == near)
        #expect(DDIImagePreparation.mountExpiry(now: now, preparationEnd: now.addingTimeInterval(4.9)) == nil)
        #expect(DDIImagePreparation.milliseconds(now.addingTimeInterval(0.25)) == 1_800_000_000_250)
    }

    @Test func theExpiryIsFixedOnTheWallClockBeforeTheHandoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000.25)
        #expect(DDICallBudget.expiry(now: now, seconds: 35) == 1_800_000_035_250)
        #expect(DDICallBudget.expiry(now: now, seconds: 0.0004) == 1_800_000_000_250)
    }

    struct Stalled: Error {}
    /// Yields until `condition` holds; fails instead of spinning forever.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        throw Stalled()
    }
    /// Starts a task that waits for the gate and returns once it is queued, so
    /// queue order is the order of these calls, not of task scheduling. The
    /// body runs while the task owns the gate.
    private func enqueue(_ gate: SerialGate,
                         _ body: @escaping @MainActor () async -> Void) async throws -> Task<Void, any Error> {
        let queued = gate.waiting
        let task = Task { @MainActor in
            try await gate.acquire()
            await body()
            gate.release()
        }
        try await until { gate.waiting > queued }
        return task
    }

    @Test func ownersFollowArrivalOrder() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        var order: [Int] = []
        var waiters: [Task<Void, any Error>] = []
        for n in 1...3 { waiters.append(try await enqueue(gate) { order.append(n) }) }
        gate.release()
        for waiter in waiters { try await waiter.value }
        #expect(order == [1, 2, 3])
        #expect(!gate.isHeld)
    }

    @Test func aCancelledWaiterLeavesWithoutOwningOrReorderingTheRest() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        var order: [Int] = []
        let first = try await enqueue(gate) { order.append(1) }
        let cancelled = try await enqueue(gate) { order.append(2) }
        let third = try await enqueue(gate) { order.append(3) }
        cancelled.cancel()
        try await until { gate.waiting == 2 }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        // The owner still holds the gate: the cancelled waiter never took it.
        #expect(gate.isHeld && order.isEmpty)
        gate.release()
        try await first.value
        try await third.value
        #expect(order == [1, 3])
        #expect(!gate.isHeld)
    }

    @Test func anAlreadyCancelledTaskNeverQueues() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        let late = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire()
        }
        await #expect(throws: CancellationError.self) { try await late.value }
        #expect(gate.waiting == 0 && gate.isHeld)
        gate.release()
        #expect(!gate.isHeld)
    }

    @Test func aWaiterCancelledAsTheGateReachesItPassesItOn() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        var order: [Int] = []
        let handed = try await enqueue(gate) { order.append(1) }
        let next = try await enqueue(gate) { order.append(2) }
        // `handed` is the first waiter: the release hands it the gate, and it
        // is cancelled before it resumes.
        gate.release()
        #expect(gate.waiting == 1 && gate.isHeld)
        handed.cancel()
        await #expect(throws: CancellationError.self) { try await handed.value }
        try await next.value
        #expect(order == [2])
        #expect(!gate.isHeld && gate.waiting == 0)
    }

    /// A fixed-seed generator, so a failing interleaving can be replayed.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test(arguments: 0..<20 as Range<UInt64>)
    func randomCancellationsKeepOneOwnerAndFIFOAmongTheRest(seed: UInt64) async throws {
        var random = SplitMix(state: seed)
        let gate = SerialGate()
        try await gate.acquire()
        var owners = 0, maximum = 0, order: [Int] = []
        var tasks: [Task<Void, any Error>] = []
        for n in 0..<12 {
            tasks.append(try await enqueue(gate) {
                owners += 1; maximum = max(maximum, owners)
                order.append(n)
                // Suspend while owning the gate, so other tasks run meanwhile.
                for _ in 0..<3 { await Task.yield() }
                owners -= 1
            })
        }
        // Waiter 0 is never cancelled; the others are, at random, some before
        // the gate is released and some while it is being handed along.
        let cancelled = Set((1..<12).filter { _ in Bool.random(using: &random) })
        let early = cancelled.filter { _ in Bool.random(using: &random) }
        for n in early { tasks[n].cancel() }
        gate.release()
        for n in cancelled.subtracting(early) { tasks[n].cancel() }
        for task in tasks { _ = try? await task.value }
        #expect(maximum <= 1)
        #expect(!gate.isHeld && gate.waiting == 0)
        #expect(order.first == 0)
        // Whoever owned the gate did so in arrival order, and every waiter
        // never cancelled owned it.
        #expect(order == order.sorted())
        #expect(Set(0..<12).subtracting(cancelled).isSubset(of: Set(order)))
        #expect(Set(order).intersection(early).isEmpty)
    }
}
