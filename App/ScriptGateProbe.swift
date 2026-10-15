import AgentKit
import Foundation

/// Local launch argument `-PocketAgentScriptGateProbe` only (not reachable
/// from the UI): a script in the embedded Linux runtime calls its phone helper
/// through the real `ScriptRuntime` and `ScriptBridge`, admitted the way
/// `PhoneExecutor.executeScript` admits it (`ScriptPhoneAdmission` with
/// `TurnEffectPolicy` over a `HistoryOwner`). The owner and project are
/// isolated temporary state, never the app's history; admitted calls are
/// answered without a device action. Between helper calls the probe makes the
/// owner's storage dirty, or forgets memory the run read (as
/// `ChatController.commitForget` revokes the job), then revokes the lease.
/// Report: `Documents/script-gate-probe.json`.
@MainActor
enum ScriptGateProbe {
    struct HandshakeMissing: LocalizedError {
        let call: Int
        var errorDescription: String? { "脚本第 \(call + 1) 次调用后的握手在 300 秒内未出现；不注入、不判定" }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var revokedValue = false
        private var log: [[String: Any]] = []
        var revoked: Bool { get { lock.withLock { revokedValue } } set { lock.withLock { revokedValue = newValue } } }
        func add(_ name: String, admitted: Bool, reason: String?) {
            lock.withLock { log.append(["tool": name, "admitted": admitted, "refusal": reason ?? NSNull()]) }
        }
        var calls: [[String: Any]] { lock.withLock { log } }
    }

    /// Calls the helper `count` times; after each call but the last it
    /// writes `done-<n>` and waits for `go-<n>` from the probe.
    private static func script(calls count: Int) -> String {
        """
        import json, os, subprocess, time
        results = []
        for n in range(\(count)):
            r = subprocess.run(["pocketagent-phone", "wait", json.dumps({"seconds": 0.5})], capture_output=True, text=True, timeout=120)
            try:
                response = json.loads(r.stdout)
                results.append({"rc": r.returncode, "json": True, "denied": response.get("denied") is True})
            except Exception as error:
                results.append({"rc": r.returncode, "json": False, "error": type(error).__name__})
            with open("/workspace/result.json", "w") as f:
                json.dump(results, f)
            if n == \(count) - 1:
                break
            open("/workspace/done-%d" % n, "w").close()
            for _ in range(1800):
                if os.path.exists("/workspace/go-%d" % n):
                    break
                time.sleep(0.1)
        """
    }

    static func runAndReport() async {
        try? await Task.sleep(for: .seconds(3))
        var report: [String: Any] = [
            "fixture": "isolated synthetic HistoryOwner and temporary project; real embedded ScriptRuntime and ScriptBridge; "
                + "admission ScriptPhoneAdmission + TurnEffectPolicy as PhoneExecutor.executeScript; admitted calls answered without a device action",
            "wallClock": ISO8601DateFormatter().string(from: Date())]
        do {
            try await ScriptRuntime.shared.prepare()
            report["dirty"] = try await dirtyCase()
            report["forget"] = try await forgetCase()
        } catch { report["error"] = error.localizedDescription }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("script-gate-probe.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    /// Runs the script; `between(n)` runs after call n while the script waits.
    private static func run(calls count: Int, owner: HistoryOwner, state: State, lease: ScriptLease,
                            between: @escaping @MainActor (Int) throws -> [String: Any]) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa-script-gate-\(UUID().uuidString)/project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let workspace = WorkspaceSnapshot(id: UUID(), name: "probe", root: root)
        let request = try ScriptRequest(["language": .string("python"), "code": .string(script(calls: count)), "timeout": .number(400)],
                                        remaining: 600)
        let handler: ScriptPhoneHandler = { call in
            let blocked = await MainActor.run {
                TurnEffectPolicy.blocked(storage: owner.health, isCurrent: true, isRunning: true, cancelled: state.revoked, terminal: false)
            }
            if let refusal = ScriptPhoneAdmission.refusal(decision: ToolCatalog.scriptDecision(for: call.name),
                                                          leaseActive: lease.isActive, effectsBlocked: blocked) {
                state.add(call.name, admitted: false, reason: refusal)
                return (refusal, true, true)
            }
            state.add(call.name, admitted: true, reason: nil)
            return (#"{"ok":true,"probe":"admitted; answered without a device action"}"#, false, false)
        }
        let running = Task.detached { await ScriptRuntime.shared.run(request, workspace: workspace, lease: lease, phone: handler) }
        var steps: [[String: Any]] = []
        for n in 0..<(count - 1) {
            let done = root.appendingPathComponent("done-\(n)")
            var waited = 0
            while !FileManager.default.fileExists(atPath: done.path), waited < 3000 {
                try await Task.sleep(for: .milliseconds(100)); waited += 1
            }
            guard FileManager.default.fileExists(atPath: done.path), state.calls.count == n + 1 else {
                lease.revoke()
                _ = await running.value
                throw HandshakeMissing(call: n)
            }
            var step = try between(n)
            step["afterCall"] = n
            steps.append(step)
            FileManager.default.createFile(atPath: root.appendingPathComponent("go-\(n)").path, contents: nil)
        }
        let outcome = await running.value
        let results = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("result.json")))) as? [Any] ?? []
        guard results.count == count, state.calls.count == count else {
            return ["incomplete": true, "steps": steps, "helperResultCount": results.count, "bridgeCalls": state.calls,
                    "exitCode": outcome.exitCode ?? -1, "cancelled": outcome.cancelled, "failure": outcome.failure ?? NSNull()]
        }
        return ["steps": steps, "helperResults": results, "bridgeCalls": state.calls, "exitCode": outcome.exitCode ?? -1,
                "cancelled": outcome.cancelled, "timedOut": outcome.timedOut, "failure": outcome.failure ?? NSNull(),
                "milliseconds": outcome.milliseconds]
    }

    /// Storage becomes dirty between two helper calls: the second is refused.
    private static func dirtyCase() async throws -> [String: Any] {
        final class Disk: @unchecked Sendable {
            private let lock = NSLock(); private var broken = false
            func fail() { lock.withLock { broken = true } }
            func write(_ data: Data) throws { if lock.withLock({ broken }) { throw CocoaError(.fileWriteOutOfSpace) } }
        }
        let disk = Disk()
        let owner = HistoryOwner(file: .initial(selection: nil), writer: { try disk.write($0) })
        let state = State(), lease = ScriptLease()
        return try await run(calls: 2, owner: owner, state: state, lease: lease) { _ in
            disk.fail()
            let durable = owner.record { try $0.editSession($0.assistant.primarySessionID) { $0.detail = "probe event" } }
            return ["injected": "isolated writer failure", "recordDurable": durable, "storageReady": owner.health.isReady]
        }
    }

    /// The run read memory A: forgetting B leaves it running, forgetting A
    /// revokes it, and a revoked lease refuses as well.
    private static func forgetCase() async throws -> [String: Any] {
        var file = HistoryFile.initial(selection: nil)
        let a = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GATE_A", origin: .panel,
                                              sourceRootPromptIDs: [], sourceMessageIDs: [])).entryIDs[0]
        let b = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "PKATEST_GATE_B", origin: .panel,
                                              sourceRootPromptIDs: [], sourceMessageIDs: [])).entryIDs[0]
        let prompt = AgentTranscriptMessage(role: .user, text: "PKATEST_GATE 脚本")
        let session = file.assistant.primarySessionID
        try file.acceptRoot(prompt, attachments: [], in: session, scope: .general)
        try file.commitDispatchPermit(root: prompt.id, sessionID: session, scope: .general)
        let root = prompt.id
        guard let revision = file.assistant.memory.entry(a)?.revision else { throw CocoaError(.featureUnsupported) }
        try file.registerReads(root: root, memory: [MemoryReadRevision(entryID: a, revision: revision)], roots: [], messages: [])
        let owner = HistoryOwner(file: file, writer: { _ in })
        let state = State(), lease = ScriptLease()
        return try await run(calls: 4, owner: owner, state: state, lease: lease) { n in
            switch n {
            case 0, 1:
                let entry = n == 0 ? b : a
                let preview = try owner.file.forgetPreview([entry], activeRoot: root)
                try owner.transact { _ = try $0.commitForget(preview, activeRoot: root) }
                // ChatController.commitForget revokes the running job only when the preview stops its root.
                if preview.stopsActiveRoot { state.revoked = true }
                return ["forgot": n == 0 ? "unrelated B" : "read A", "stopsActiveRoot": preview.stopsActiveRoot,
                        "rootMasked": owner.file.assistant.scopeIndex.isMasked(root: root)]
            default:
                state.revoked = false
                lease.revoke()
                return ["leaseRevoked": true, "jobRevokedFlagClearedToIsolateLease": true]
            }
        }
    }
}
