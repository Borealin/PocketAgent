import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// A running script's phone helper through the shared gate: the real Python
/// helper and `ScriptBridge`, the admission the app's PhoneExecutor uses
/// (`ScriptPhoneAdmission`), the production effect policy over a real
/// `HistoryOwner`. Storage failing or the job being revoked between two
/// helper calls refuses the second without executing it.
@MainActor
struct ScriptPhoneGateTests {
    private final class Executed: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var all: [String] { lock.withLock { names } }
        func add(_ name: String) { lock.withLock { names.append(name) } }
    }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var revoked: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    /// Fails every write after `fail()`.
    private final class Disk: @unchecked Sendable {
        private let lock = NSLock()
        private var broken = false
        func fail() { lock.withLock { broken = true } }
        func write(_ data: Data) throws { if lock.withLock({ broken }) { throw CocoaError(.fileWriteOutOfSpace) } }
    }

    /// Every helper process a run launched.
    private final class Launched: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []
        var count: Int { lock.withLock { processes.count } }
        var anyRunning: Bool { lock.withLock { processes.contains { $0.isRunning } } }
        func add(_ process: Process) { lock.withLock { processes.append(process) } }
    }

    private struct Run {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pa-gate-" + UUID().uuidString)
        let paths: WorkspacePaths
        let helper: URL
        let launched = Launched()
        init() throws {
            let root = base.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            paths = try WorkspacePaths(root: root)
            try paths.createDirectories("run/bridge")
            try paths.writeFile("bin/pocketagent-phone", data: Data(ScriptBridge.phoneHelper.utf8), mode: 0o755)
            helper = root.appendingPathComponent("bin/pocketagent-phone")
        }
        /// One helper call, served until the guest process exits; returns its exit status.
        func call(_ bridge: ScriptBridge, lease: ScriptLease, _ arguments: [String]) async throws -> Int32 {
            let token = lease.token
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", helper.path] + arguments
            process.environment = ["POCKETAGENT_BRIDGE": base.appendingPathComponent("project/run/bridge").path,
                                   "POCKETAGENT_TOKEN": token, "POCKETAGENT_PHONE_TIMEOUT": "10", "PATH": "/usr/bin:/bin"]
            process.standardOutput = Pipe()
            try process.run()
            launched.add(process)
            // Whatever ends the call (status, fixture bound, cancellation, a
            // throw) leaves no helper running.
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning, Date() < deadline {
                // As the script runner does: after revocation pending requests are refused at once.
                if lease.isActive { await bridge.service() } else { await bridge.refusePending() }
                try await Task.sleep(for: .milliseconds(30))
            }
            // Past the fixture bound (the helper itself waits 10 s): fail, never
            // read the status of a running process (an exception).
            guard !process.isRunning else { throw HelperStillRunning() }
            return process.terminationStatus
        }
    }

    private struct HelperStillRunning: Error {}

    /// The helper's exit status for a refused request (3 would be no answer within its own wait).
    private let refused: Int32 = 4

    private func bridge(_ run: Run, lease: ScriptLease, owner: HistoryOwner, job: Job, executed: Executed) -> ScriptBridge {
        ScriptBridge(paths: run.paths, directory: "run/bridge", lease: lease) { call in
            let blocked = await MainActor.run {
                TurnEffectPolicy.blocked(storage: owner.health, isCurrent: true, isRunning: true, cancelled: job.revoked, terminal: false)
            }
            if let refusal = ScriptPhoneAdmission.refusal(decision: ToolCatalog.scriptDecision(for: call.name),
                                                          leaseActive: lease.isActive, effectsBlocked: blocked) {
                return (refusal, true, true)
            }
            executed.add(call.name)
            return (#"{"ok":true,"action_issued":true}"#, false, false)
        }
    }

    @Test func storageFailingBetweenHelperCallsRefusesTheNextAction() async throws {
        let run = try Run()
        let disk = Disk()
        let owner = HistoryOwner(file: HistoryFile.initial(selection: nil), writer: { try disk.write($0) })
        let lease = ScriptLease(), job = Job(), executed = Executed()
        let bridge = bridge(run, lease: lease, owner: owner, job: job, executed: executed)
        let first = try await run.call(bridge, lease: lease, ["press_home"])
        #expect(first == 0 && executed.all == ["press_home"])
        // A run event's write fails: storage is dirty for every effect.
        disk.fail()
        owner.record { try $0.editSession($0.assistant.primarySessionID) { $0.detail = "event" } }
        #expect(!owner.health.isReady)
        let second = try await run.call(bridge, lease: lease, ["press_home"])
        #expect(second != 0 && executed.all == ["press_home"])
        let refusals = try run.paths.entries("run/bridge").map(\.name).filter { $0.hasSuffix(".resp") }
            .map { String(decoding: try run.paths.readFile("run/bridge/" + $0, limit: 8192), as: UTF8.self) }
        #expect(refusals.contains { $0.contains("\"denied\":true") && $0.contains("动作未执行") })
    }

    /// The causal chain: the run registered a read of A; forgetting an
    /// unrelated entry B does not stop it, forgetting A does (its preview
    /// stops the active root, which is how the app revokes the running job),
    /// and a revoked lease refuses as well. Nothing refused is executed.
    @Test func onlyAForgetOfWhatTheRunReadRevokesItsScript() async throws {
        let run = try Run()
        var file = HistoryFile.initial(selection: nil)
        let a = try #require(try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GAPS_A", origin: .panel,
                                                            sourceRootPromptIDs: [], sourceMessageIDs: [])).entryIDs.first)
        let b = try #require(try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GAPS_B", origin: .panel,
                                                            sourceRootPromptIDs: [], sourceMessageIDs: [])).entryIDs.first)
        let root = try file.acceptCurrent("PKATEST_GAPS 脚本", in: file.assistant.primarySessionID, scope: .general)
        try file.registerReads(root: root, memory: [MemoryReadRevision(entryID: a, revision: file.assistant.memory.entry(a)!.revision)],
                               roots: [], messages: [])
        let owner = HistoryOwner(file: file, writer: { _ in })
        let lease = ScriptLease(), job = Job(), executed = Executed()
        let bridge = bridge(run, lease: lease, owner: owner, job: job, executed: executed)
        func forget(_ entry: UUID) throws {
            let preview = try owner.file.forgetPreview([entry], activeRoot: root)
            try owner.transact { _ = try $0.commitForget(preview, activeRoot: root) }
            // ChatController.commitForget: only a preview that stops the running root revokes the job.
            if preview.stopsActiveRoot { job.revoked = true }
        }
        #expect(try await run.call(bridge, lease: lease, ["press_home"]) == 0)
        try forget(b)
        #expect(!job.revoked && !owner.file.assistant.scopeIndex.isMasked(root: root))
        #expect(try await run.call(bridge, lease: lease, ["press_home"]) == 0)
        try forget(a)
        #expect(job.revoked && owner.file.assistant.scopeIndex.isMasked(root: root))
        // Refusals are answered (exit 4), not left to the helper's own timeout.
        #expect(try await run.call(bridge, lease: lease, ["press_home"]) == refused)
        job.revoked = false
        lease.revoke()
        #expect(try await run.call(bridge, lease: lease, ["press_home"]) == refused)
        #expect(executed.all == ["press_home", "press_home"])
        #expect(ScriptPhoneAdmission.refusal(decision: .allow, leaseActive: false, effectsBlocked: nil) == ScriptPhoneAdmission.revoked)
    }

    /// A call cancelled while its helper waits for an answer stops that
    /// helper, instead of leaving it to the helper's own 10 s wait.
    @Test func aCancelledCallLeavesNoHelperRunning() async throws {
        let run = try Run()
        let owner = HistoryOwner(file: HistoryFile.initial(selection: nil), writer: { _ in })
        let lease = ScriptLease(), job = Job(), executed = Executed()
        let bridge = bridge(run, lease: lease, owner: owner, job: job, executed: executed)
        // Cancelled before it runs: the helper is launched, then the call's first wait throws.
        let call = Task { try await run.call(bridge, lease: lease, ["press_home"]) }
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(run.launched.count == 1 && !run.launched.anyRunning)
    }
}
