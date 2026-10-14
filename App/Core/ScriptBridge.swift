import AgentKit
import Darwin
import Foundation

/// A running script's revocable permission to request phone actions. It is
/// separate from PhoneExecutor's action lock: the script holds the lease for
/// its whole run, the lock only for one action at a time.
nonisolated final class ScriptLease: @unchecked Sendable {
    let token = UUID().uuidString + UUID().uuidString
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
}

nonisolated enum ScriptError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

nonisolated enum ScriptLanguage: String, Sendable {
    case bash, sh, python, node
    var interpreter: String {
        switch self {
        case .bash: "/bin/bash"
        case .sh: "/bin/sh"
        case .python: "/usr/bin/python3"
        case .node: "/usr/bin/node"
        }
    }
    var fileExtension: String {
        switch self {
        case .bash, .sh: "sh"
        case .python: "py"
        case .node: "js"
        }
    }
}

nonisolated struct ScriptRequest: Sendable {
    var language: ScriptLanguage
    var code: String?
    var path: String?
    var arguments: [String]
    var cwd: String
    var timeout: TimeInterval

    /// `remaining` is the turn's remaining time; a script must finish, and be
    /// stopped if necessary, before the turn's own deadline.
    init(_ args: [String: AgentJSONValue], remaining: TimeInterval) throws {
        guard let language = args["language"]?.stringValue.flatMap(ScriptLanguage.init(rawValue:)) else {
            throw ScriptError.invalid("language 必须是 bash、sh、python 或 node。")
        }
        self.language = language
        code = args["code"]?.stringValue
        path = args["path"]?.stringValue
        guard (code == nil) != (path == nil) else { throw ScriptError.invalid("code 和 path 必须且只能提供一个。") }
        if let code, code.utf8.count > 512 * 1024 { throw ScriptError.invalid("脚本超过 512 KB。") }
        if case .array(let items)? = args["args"] {
            arguments = try items.map { guard let s = $0.stringValue else { throw ScriptError.invalid("args 只能包含字符串。") }; return s }
        } else { arguments = [] }
        cwd = args["cwd"]?.stringValue ?? "."
        let budget = remaining - 25
        guard budget >= 10 else { throw ScriptError.invalid("本轮剩余时间不足以运行脚本；请发送新消息继续。") }
        timeout = min(max(args["timeout_seconds"]?.numberValue ?? 120, 5), 540, budget)
    }
}

/// How a run ended. The kernel's wait status for the wrapper process is the
/// authority; the status file the wrapper writes lives in the guest-writable
/// run directory, so a script can forge it and then kill its own wrapper. It
/// is only compared, never preferred.
nonisolated struct ScriptExit: Equatable, Sendable {
    var exitCode: Int?
    var signal: Int?
    var failure: String?
    var note: String?

    /// `kernel`: the usermode-helper result (a wait status, a negative errno
    /// when the process could not start, nil when no result arrived).
    /// `wrapper`: the guest-written status file, if it parsed.
    static func resolve(kernel: Int32?, wrapper: Int?) -> ScriptExit {
        guard let status = kernel else {
            return ScriptExit(failure: "脚本进程没有报告退出状态，结果未知。")
        }
        guard status >= 0 else {
            return ScriptExit(failure: "无法启动脚本进程（错误 \(-status)）。")
        }
        var exit = ScriptExit()
        if status & 0x7f == 0 {
            exit.exitCode = Int((status >> 8) & 0xff)
        } else {
            exit.signal = Int(status & 0x7f)
        }
        if let wrapper, wrapper != exit.exitCode {
            exit.note = "脚本写入的状态文件为 \(wrapper)，与内核报告的结果不符；以内核结果为准。"
        }
        return exit
    }
}

nonisolated struct ScriptOutcome: Sendable {
    var run = ""
    var exit = ScriptExit()
    var timedOut = false
    var cancelled = false
    var outputLimited = false
    var stdout = ""
    var stderr = ""
    var stdoutBytes = 0
    var stderrBytes = 0
    var milliseconds = 0
    var terminatedProcesses = 0
    /// Live guest threads after the stop sequence; nil when the count failed.
    var remainingProcesses: Int? = 0
    var failure: String?
    var phoneActions: [ScriptPhoneRecord] = []
    /// Phone requests beyond `ScriptBridge.recordLimit`, counted only.
    var phoneActionsOmitted = 0

    var exitCode: Int? { exit.exitCode }
    var isError: Bool {
        failure != nil || exit.failure != nil || exit.exitCode != 0 || timedOut || cancelled || outputLimited
            || remainingProcesses != 0
    }

    func render() -> String {
        var object: [String: Any] = ["exit_code": exit.exitCode.map { $0 as Any } ?? NSNull(), "stdout": stdout, "stderr": stderr,
            "stdout_bytes": stdoutBytes, "stderr_bytes": stderrBytes, "duration_ms": milliseconds,
            "timed_out": timedOut, "cancelled": cancelled, "output_limited": outputLimited,
            "guest_processes_remaining": remainingProcesses.map { $0 as Any } ?? "unknown"]
        if !run.isEmpty {
            object["full_output"] = ["stdout": run + "/stdout", "stderr": run + "/stderr"]
        }
        if let signal = exit.signal { object["signal"] = signal }
        if let note = exit.note { object["exit_note"] = note }
        if terminatedProcesses > 0 { object["terminated_processes"] = terminatedProcesses }
        if let error = failure ?? exit.failure { object["error"] = error }
        if timedOut || cancelled || outputLimited {
            object["note"] = "脚本被停止：先撤销其手机授权，再 SIGINT、宽限后 SIGKILL，并确认剩余 guest 进程数为 \(remainingProcesses.map(String.init) ?? "未知")。已发生的手机动作不会重放。"
        }
        // Streams are shortened first (full_output keeps them); if the action
        // list is still too large, details are cut, then the later half of the
        // actions is dropped repeatedly and counted as omitted.
        var actions = phoneActions, omitted = phoneActionsOmitted, detail = 240
        while true {
            object["phone_actions"] = actions.map { ["tool": HostToolResult.clip($0.tool, bytes: 64),
                                                     "label": HostToolResult.clip($0.label, bytes: 160), "ok": $0.ok,
                                                     "detail": HostToolResult.clip($0.detail, bytes: detail)] }
            if omitted > 0 { object["phone_actions_omitted"] = omitted }
            if let text = HostToolResult.fitting(object, shortening: ["stdout", "stderr"]) { return text }
            if detail > 40 { detail = 40 }
            else if actions.isEmpty { return HostToolResult.json(object, shortening: ["stdout", "stderr"]) }
            else { omitted += actions.count - actions.count / 2; actions = Array(actions.prefix(actions.count / 2)) }
        }
    }
}

/// Whether a running script's phone request may start: the tool must be
/// allowed for scripts, the script's lease active and the turn's shared
/// effect gate open (`TurnEffectPolicy`: storage, ownership, cancellation,
/// revocation). Checked for every helper request before anything is sent;
/// an action that starts re-checks the same gate before each effect.
nonisolated enum ScriptPhoneAdmission {
    static let revoked = "脚本的手机授权已撤销，动作未执行。"

    static func refusal(decision: ToolDecision, leaseActive: Bool, effectsBlocked: String?) -> String? {
        if case .deny(let reason) = decision { return reason }
        guard leaseActive else { return revoked }
        if let effectsBlocked { return effectsBlocked + "动作未执行。" }
        return nil
    }
}

/// Phone request handler supplied by the turn (PhoneExecutor.executeScript).
typealias ScriptPhoneHandler = @Sendable (AgentToolCall) async -> (content: String, isError: Bool, denied: Bool)

/// Serves one run's phone requests from files the guest writes in the run's
/// bridge directory. Requests are read without following links, each ID is
/// executed at most once, and responses are written atomically by rename.
actor ScriptBridge {
    let paths: WorkspacePaths
    let directory: String
    let lease: ScriptLease
    let phone: ScriptPhoneHandler
    /// Recorded for the result; later requests (for example a polling loop
    /// past the 100-action limit) are only counted.
    static let recordLimit = 100
    private(set) var records: [ScriptPhoneRecord] = []
    private(set) var omittedRecords = 0
    private var handled: Set<String> = []

    init(paths: WorkspacePaths, directory: String, lease: ScriptLease, phone: @escaping ScriptPhoneHandler) {
        self.paths = paths; self.directory = directory; self.lease = lease; self.phone = phone
    }

    /// Executes every new request while the lease is active.
    func service() async {
        for (id, name) in pending() {
            guard lease.isActive else { return }
            handled.insert(id)
            var response: [String: Any]
            if let data = try? paths.readFile(directory + "/" + name, limit: 256 * 1024),
               let request = try? JSONDecoder().decode(BridgeRequest.self, from: data) {
                if request.token != lease.token {
                    response = ["ok": false, "denied": true, "error": "invalid bridge token"]
                } else {
                    let call = AgentToolCall(id: "script-" + id, name: request.tool, arguments: .object(request.arguments))
                    let result = await phone(call)
                    // Byte-bounded: the tool name comes from the guest and need not be a real tool.
                    if records.count < Self.recordLimit {
                        records.append(ScriptPhoneRecord(tool: HostToolResult.clip(request.tool, bytes: 64),
                                                         label: HostToolResult.clip(ToolLabels.action(call), bytes: 160),
                                                         ok: !result.isError, detail: HostToolResult.clip(result.content, bytes: 240)))
                    } else {
                        omittedRecords += 1
                    }
                    let parsed = try? JSONSerialization.jsonObject(with: Data(result.content.utf8))
                    response = ["ok": !result.isError, "denied": result.denied, "result": parsed ?? result.content]
                    if result.isError { response["error"] = result.content }
                }
            } else {
                response = ["ok": false, "denied": true, "error": "unreadable request"]
            }
            respond(id, response)
        }
    }

    /// After the lease is revoked: every request not yet handled is answered
    /// as refused without executing it, so the guest helper does not wait.
    func refusePending() {
        for (id, _) in pending() {
            handled.insert(id)
            respond(id, ["ok": false, "denied": true, "error": "脚本的手机授权已撤销，动作未执行。"])
        }
    }

    private func pending() -> [(id: String, name: String)] {
        guard let names = try? paths.entries(directory).map(\.name) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".req") else { return nil }
            let id = String(name.dropLast(4))
            guard !handled.contains(id), id.count <= 64,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
            return (id, name)
        }
    }

    private func respond(_ id: String, _ response: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
            try? paths.writeFile(directory + "/" + id + ".resp", data: data)
        }
    }

    private struct BridgeRequest: Decodable {
        var token: String
        var tool: String
        var arguments: [String: AgentJSONValue]
    }

    /// Guest command: `pocketagent-phone <tool> '<json arguments>'`.
    static let phoneHelper = #"""
    #!/usr/bin/env python3
    """pocketagent-phone <tool> ['<json arguments>'] -- run one PocketAgent phone tool.

    Prints the JSON result. Exit status: 0 success, 3 the action failed or its
    outcome is unknown (observe_screen before deciding; never retry blindly),
    4 refused (lease revoked, not a phone tool), 2 usage error."""
    import json, os, sys, time, uuid

    def main():
        if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
            print(__doc__)
            return 0 if len(sys.argv) > 1 else 2
        try:
            arguments = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
        except ValueError as error:
            print(json.dumps({"ok": False, "error": "invalid JSON arguments: %s" % error}))
            return 2
        if not isinstance(arguments, dict):
            print(json.dumps({"ok": False, "error": "arguments must be a JSON object"}))
            return 2
        bridge = os.environ["POCKETAGENT_BRIDGE"]
        request_id = uuid.uuid4().hex
        base = os.path.join(bridge, request_id)
        with open(base + ".tmp", "w") as stream:
            json.dump({"id": request_id, "token": os.environ["POCKETAGENT_TOKEN"], "tool": sys.argv[1],
                       "arguments": arguments}, stream)
        os.rename(base + ".tmp", base + ".req")
        deadline = time.time() + float(os.environ.get("POCKETAGENT_PHONE_TIMEOUT", "180"))
        while time.time() < deadline:
            if os.path.exists(base + ".resp"):
                with open(base + ".resp") as stream:
                    result = json.load(stream)
                print(json.dumps(result, ensure_ascii=False))
                return 0 if result.get("ok") else (4 if result.get("denied") else 3)
            time.sleep(0.05)
        print(json.dumps({"ok": False, "outcome": "unknown",
                          "error": "no result; the action may have happened. observe_screen before deciding."}))
        return 3

    sys.exit(main())
    """#
}
