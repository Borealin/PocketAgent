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

    private struct Run {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pa-gate-" + UUID().uuidString)
        let paths: WorkspacePaths
        let helper: URL
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
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning, Date() < deadline {
                // As the script runner does: after revocation pending requests are refused at once.
                if lease.isActive { await bridge.service() } else { await bridge.refusePending() }
                try await Task.sleep(for: .milliseconds(30))
            }
            return process.terminationStatus
        }
    }

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

    @Test func aRevokedJobOrLeaseRefusesTheNextActionWithoutExecutingIt() async throws {
        let run = try Run()
        let owner = HistoryOwner(file: HistoryFile.initial(selection: nil), writer: { _ in })
        let lease = ScriptLease(), job = Job(), executed = Executed()
        let bridge = bridge(run, lease: lease, owner: owner, job: job, executed: executed)
        let started = Date()
        #expect(try await run.call(bridge, lease: lease, ["press_home"]) == 0)
        // A forget hit the running turn (revoked) between the script's calls.
        job.revoked = true
        #expect(try await run.call(bridge, lease: lease, ["press_home"]) != 0)
        job.revoked = false
        lease.revoke()
        #expect(try await run.call(bridge, lease: lease, ["press_home"]) != 0)
        #expect(executed.all == ["press_home"])
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(ScriptPhoneAdmission.refusal(decision: .allow, leaseActive: false, effectsBlocked: nil) == ScriptPhoneAdmission.revoked)
    }
}
