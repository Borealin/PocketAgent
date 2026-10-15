import AgentKit
import Darwin
import Foundation
import PocketAgentNative

enum ScriptReadiness: Equatable {
    case missing, idle, preparing, started, checking, ready, failed(String)
    var title: String {
        switch self {
        case .missing: "此版本未包含脚本环境"
        case .idle: "等待自动准备"
        case .preparing: "正在初始化 Linux…"
        case .started: "Linux 已启动，待检查工具"
        case .checking: "正在检查 Bash、Python、Node.js…"
        case .ready: "脚本环境可用"
        case .failed: "需要重启 App"
        }
    }
    var busy: Bool { self == .preparing || self == .checking }
}

extension Notification.Name {
    static let scriptReadinessChanged = Notification.Name("PocketAgent.scriptReadinessChanged")
}

/// Embedded iSH Linux runtime. One script runs at a time. The guest sees the
/// Alpine rootfs (app-private fakefs, excluded from backup) and, during a run,
/// exactly the turn's project root at /workspace. Scripts run as uid 501
/// without capabilities; the patched kernel refuses guest host-filesystem
/// mounts, confines hostfs below the mounted project and refuses egress to
/// loopback, private networks and the phone's own addresses, so
/// WebDriverAgent's listener is unreachable and phone actions go only
/// through the file bridge (ScriptBridge).
final class ScriptRuntime: @unchecked Sendable {
    static let shared = ScriptRuntime()
    static let uid: Int32 = 501
    static let mountPoint = "/workspace"
    static let outputLimit: off_t = 8 * 1024 * 1024
    static let keptRuns = 20

    let archive = Bundle.main.url(forResource: "ish-root", withExtension: "tar.gz")
    var isBundled: Bool { archive != nil }
    let directory = applicationSupport.appendingPathComponent("PocketAgent/LinuxRuntime", isDirectory: true)
    private let gate = RunGate()
    private let state = NSLock()
    private var ready = false
    private var preparing = 0
    private var checkingTools = false
    private var toolsChecked = false
    private var toolCheck: Task<Void, any Error>?
    private var unusable: String?
    private var tunnelAddress: UInt32?

    var readiness: ScriptReadiness {
        state.withLock {
            if let unusable { return .failed(unusable) }
            if archive == nil { return .missing }
            if checkingTools { return .checking }
            if preparing > 0 { return .preparing }
            if toolsChecked { return .ready }
            return ready ? .started : .idle
        }
    }

    private func readinessChanged() {
        NotificationCenter.default.post(name: .scriptReadinessChanged, object: nil)
    }

    /// Imports the rootfs on first use and boots the kernel off the main thread.
    func prepare() async throws {
        if let unusable = state.withLock({ unusable }) { throw failure(unusable) }
        if state.withLock({ ready }) { return }
        guard let archive else { throw failure("此版本未包含脚本运行环境。") }
        state.withLock { preparing += 1 }
        readinessChanged()
        defer { state.withLock { preparing -= 1 }; readinessChanged() }
        let tunnel = await MainActor.run { try? DeviceSettings.tunnelEndpoint().host }
        let directory = directory
        do {
            try await runOnFFIThread {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var url = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
                var error: NSString?
                guard PocketISHBoot(archive.path, directory.path, &error) else {
                    throw failure("脚本运行环境启动失败：\(error ?? "unknown")")
                }
            }
        } catch {
            markUnusable(error.localizedDescription)
            throw error
        }
        var address = in_addr()
        let tunnelAddress = tunnel.flatMap { inet_pton(AF_INET, $0, &address) == 1 ? address.s_addr : nil }
        state.withLock { self.tunnelAddress = tunnelAddress; ready = true }
        refreshBlockedHosts()
    }

    /// A read-only startup check. It shares the script gate, owns every uid-501
    /// process it starts and mounts no workspace or phone bridge.
    func checkTools() async throws {
        if readiness == .ready { return }
        // Shared work outlives a dismissed SwiftUI .task. In particular, its
        // sleeps stay live after caller cancellation and checks never overlap.
        let work = state.withLock {
            if let toolCheck { return toolCheck }
            let task = Task.detached(priority: .utility) { [self] in try await verifyTools() }
            toolCheck = task
            return task
        }
        try await work.value
    }

    private func verifyTools() async throws {
        await gate.acquire()
        do {
            try await prepare()
            if !state.withLock({ toolsChecked }) {
                state.withLock { checkingTools = true }; readinessChanged()
                let exit = ExitBox()
                let command = "/bin/bash --version >/dev/null && /usr/bin/python3 --version >/dev/null && /usr/bin/node --version >/dev/null"
                PocketISHRun(["/bin/sh", "-c", command], ["PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/home/pocketagent"], Self.uid) {
                    status, _ in exit.finish(status)
                }
                let started = Date()
                while !exit.done, Date().timeIntervalSince(started) < 20 {
                    if let reason = PocketISHFailure() { throw failure("脚本环境已停止：\(reason)") }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if !exit.done { _ = await stop(until: exit, diagnostic: { _, _ in }) }
                let remaining = await blocking { PocketISHUserTasks(Self.uid, 0) }
                guard remaining == 0 else { throw failure("无法确认脚本环境检查已结束，请重启 App。") }
                let result = ScriptExit.resolve(kernel: exit.status, wrapper: nil)
                guard result.exitCode == 0 else { throw failure("Bash、Python 或 Node.js 检查未通过，请重启 App 后重试。") }
                state.withLock { toolsChecked = true; checkingTools = false }; readinessChanged()
            }
            await gate.release()
        } catch {
            state.withLock { checkingTools = false }
            markUnusable(error.localizedDescription)
            await gate.release()
            throw error
        }
    }

    /// The phone's own IPv4 addresses (WebDriverAgent listens on every
    /// interface) plus the tunnel address; refreshed while a script runs.
    private func refreshBlockedHosts() {
        var addresses = Self.localAddresses()
        if let tunnel = state.withLock({ tunnelAddress }) { addresses.append(tunnel) }
        PocketISHSetBlockedHosts(addresses.map { NSNumber(value: $0) })
    }

    static func localAddresses() -> [UInt32] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: [UInt32] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { result.append($0.pointee.sin_addr.s_addr) }
        }
        return Array(Set(result)).sorted()
    }

    /// `stage` reports lifecycle stages actually reached and output growth
    /// (at most once per second); it never fires without a real change.
    /// `diagnostic` receives metadata-only stop-path events (names, counts,
    /// milliseconds) for the opt-in run log.
    func run(_ request: ScriptRequest, workspace: WorkspaceSnapshot, lease: ScriptLease,
             phone: @escaping ScriptPhoneHandler,
             stage: @escaping @Sendable (ScriptStage) -> Void = { _ in },
             diagnostic: @escaping ScriptDiagnostic = { _, _ in }) async -> ScriptOutcome {
        let control = RunControl()
        // The run, including its stop sequence, is not itself cancellable:
        // cancellation only sets the flag the run observes.
        let work = Task.detached(priority: .userInitiated) { [self] in
            await gate.acquire()
            let outcome = await execute(request, workspace: workspace, lease: lease, control: control,
                                        stage: stage, phone: phone, diagnostic: diagnostic)
            await gate.release()
            return outcome
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { control.cancel() }
    }

    /// Stop or the deadline before a process exists: nothing to signal.
    private func stoppedBeforeStart(_ outcome: inout ScriptOutcome, control: RunControl, started: Date,
                                    timeout: TimeInterval) -> Bool {
        if control.cancelled { outcome.cancelled = true }
        else if Date().timeIntervalSince(started) > timeout { outcome.timedOut = true }
        else { return false }
        outcome.failure = "脚本在启动前被停止，未运行。"
        return true
    }

    private func execute(_ request: ScriptRequest, workspace: WorkspaceSnapshot, lease: ScriptLease,
                         control: RunControl, stage: @escaping @Sendable (ScriptStage) -> Void,
                         phone: @escaping ScriptPhoneHandler, diagnostic: @escaping ScriptDiagnostic) async -> ScriptOutcome {
        var outcome = ScriptOutcome()
        let started = Date()
        defer { lease.revoke() }
        // First use imports the rootfs and boots the kernel. Stop and the
        // timeout stay live meanwhile; an abandoned boot finishes in the
        // background and the next run reuses it.
        let preparing = Completion()
        Task.detached(priority: .userInitiated) { [self] in
            do { try await prepare(); preparing.finish(nil) } catch { preparing.finish(error.localizedDescription) }
        }
        while !preparing.done {
            if stoppedBeforeStart(&outcome, control: control, started: started, timeout: request.timeout) { return outcome }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let error = preparing.error { outcome.failure = error; return outcome }
        stage(.runtimeReady)
        let paths: WorkspacePaths, run: String, scriptPath: String, cwd: String, root: String
        do {
            root = try Self.canonicalRoot(workspace.root)
            paths = try WorkspacePaths(root: URL(fileURLWithPath: root, isDirectory: true))
            run = ".pocketagent/runs/" + Self.runID()
            try paths.createDirectories(run + "/bridge")
            try paths.writeFile(".pocketagent/bin/pocketagent-phone", data: Data(ScriptBridge.phoneHelper.utf8), mode: 0o755)
            if let code = request.code {
                scriptPath = run + "/script." + request.language.fileExtension
                try paths.writeFile(scriptPath, data: Data(code.utf8))
            } else {
                scriptPath = try WorkspacePaths.components(request.path ?? "").joined(separator: "/")
                guard (try? paths.readFile(scriptPath, limit: 16 * 1024 * 1024)) != nil else { throw WorkspaceError.notAFile(scriptPath) }
            }
            cwd = try WorkspacePaths.components(request.cwd).joined(separator: "/")
            _ = try WorkspaceFiles(paths: paths).list(cwd.isEmpty ? "." : cwd, limit: 1)
        } catch { outcome.failure = error.localizedDescription; return outcome }
        outcome.run = run
        if stoppedBeforeStart(&outcome, control: control, started: started, timeout: request.timeout) { return outcome }
        let guest = { (relative: String) in Self.mountPoint + (relative.isEmpty ? "" : "/" + relative) }
        refreshBlockedHosts()
        // Mount exactly this project; any earlier mount at /workspace is
        // detached first and leftover processes must be gone.
        let mounted: String? = await blocking {
            _ = PocketISHUnmount(Self.mountPoint)
            // Every run ends with a verified zero count (or disables scripts),
            // so anything else here means the runtime cannot be trusted.
            guard PocketISHUserTasks(Self.uid, 0) == 0 else { return "无法确认上一个脚本的进程状态。" }
            let result = PocketISHMount(root, Self.mountPoint)
            return result == 0 ? nil : "挂载项目目录失败（\(result)）。"
        }
        if let mounted {
            outcome.failure = mounted
            if mounted.hasPrefix("无法确认") { markUnusable("脚本运行环境没有响应；请重启 App 后再运行脚本。") }
            return outcome
        }
        if stoppedBeforeStart(&outcome, control: control, started: started, timeout: request.timeout) {
            _ = await blocking { PocketISHUnmount(Self.mountPoint) }
            return outcome
        }
        let wrapper = """
        exec </dev/null >"$PA_RUN/stdout" 2>"$PA_RUN/stderr"
        cd -- "$PA_CWD" || exit 126
        "$@"
        status=$?
        printf '%s' "$status" >"$PA_RUN/status.tmp" && mv -f "$PA_RUN/status.tmp" "$PA_RUN/status"
        exit $status
        """
        let argv = ["/bin/sh", "-c", wrapper, "pocketagent-run", request.language.interpreter, guest(scriptPath)] + request.arguments
        // pocketagent-phone is the rootfs launcher (/usr/local/bin), which runs
        // this run's helper with python3; nothing on the project mount is exec'd.
        let environment = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                           "POCKETAGENT_HELPER=\(guest(".pocketagent/bin/pocketagent-phone"))",
                           "HOME=/home/pocket", "USER=pocket", "LOGNAME=pocket", "LANG=C.UTF-8", "TERM=dumb",
                           "PYTHONUNBUFFERED=1", "PA_RUN=\(guest(run))", "PA_CWD=\(guest(cwd))",
                           "POCKETAGENT_BRIDGE=\(guest(run + "/bridge"))", "POCKETAGENT_TOKEN=\(lease.token)"]
        let exit = ExitBox()
        PocketISHRun(argv, environment, Self.uid) { status, _ in exit.finish(status) }
        stage(.processStarted)
        let bridge = ScriptBridge(paths: paths, directory: run + "/bridge", lease: lease, phone: phone)
        // Requests are served on their own task so the deadline, cancellation
        // and output checks below stay live while a phone action is in flight.
        let serving = Task { while !exit.done && lease.isActive { await bridge.service(); try? await Task.sleep(for: .milliseconds(80)) } }
        var ticks = 0
        var reportedOutput: off_t = 0, outputReportedAt = Date.distantPast
        while !exit.done {
            if let failure = PocketISHFailure() {
                // The kernel panicked or stopped answering: nothing can be
                // signalled or counted any more, so end the run now.
                lease.revoke()
                diagnostic("script_lease_revoked", ["reason": "kernel"])
                outcome.failure = "脚本运行环境已停止（\(failure)）；请重启 App 后再运行脚本。"
                markUnusable(outcome.failure!)
                break
            }
            if control.cancelled { outcome.cancelled = true; diagnostic("script_cancel_observed", [:]) }
            else if Date().timeIntervalSince(started) > request.timeout { outcome.timedOut = true }
            else {
                let stdout = Self.size(paths, run + "/stdout"), stderr = Self.size(paths, run + "/stderr")
                if stdout > Self.outputLimit || stderr > Self.outputLimit { outcome.outputLimited = true }
                else if stdout + stderr != reportedOutput, Date().timeIntervalSince(outputReportedAt) >= 1 {
                    reportedOutput = stdout + stderr; outputReportedAt = Date()
                    stage(.outputGrew)
                }
            }
            if outcome.cancelled || outcome.timedOut || outcome.outputLimited {
                // Revoke first so no further phone action starts, then stop.
                lease.revoke()
                diagnostic("script_lease_revoked", ["reason": outcome.cancelled ? "cancelled" : outcome.timedOut ? "timedOut" : "output"])
                outcome.terminatedProcesses = await stop(until: exit, diagnostic: diagnostic)
                break
            }
            ticks += 1
            if ticks % 10 == 0 { refreshBlockedHosts() }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Background processes left by a finished script are reaped as well.
        if exit.done, !outcome.cancelled, !outcome.timedOut, !outcome.outputLimited {
            outcome.terminatedProcesses = await stop(until: exit, diagnostic: diagnostic)
        }
        lease.revoke()
        // An action already started finishes and is recorded, never repeated;
        // requests that arrive afterwards are answered as refused.
        let serveWait = ContinuousClock.now
        diagnostic("script_serving_wait_begin", [:])
        await serving.value
        diagnostic("script_serving_wait_end", ["ms": Self.milliseconds(since: serveWait)])
        await bridge.refusePending()
        diagnostic("ish_remaining_enter", [:])
        let remainingStarted = ContinuousClock.now
        let remaining = Int(await blocking { PocketISHUserTasks(Self.uid, 0) })
        diagnostic("ish_remaining_exit", ["remaining": remaining, "ms": Self.milliseconds(since: remainingStarted)])
        outcome.remainingProcesses = remaining < 0 ? nil : remaining
        if remaining != 0 {
            markUnusable(remaining < 0 ? "无法确认脚本进程是否已结束；请重启 App 后再运行脚本。"
                                       : "上一个脚本有 \(remaining) 个 guest 进程无法终止；请重启 App 后再运行脚本。")
        }
        diagnostic("ish_unmount_enter", [:])
        let unmountStarted = ContinuousClock.now
        _ = await blocking { PocketISHUnmount(Self.mountPoint) }
        diagnostic("ish_unmount_exit", ["ms": Self.milliseconds(since: unmountStarted)])
        outcome.phoneActions = await bridge.records
        outcome.phoneActionsOmitted = await bridge.omittedRecords
        outcome.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        let written = (try? paths.readFile(run + "/status", limit: 32)).flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        outcome.exit = ScriptExit.resolve(kernel: exit.status, wrapper: written)
        (outcome.stdout, outcome.stdoutBytes) = Self.bounded(paths, run + "/stdout")
        (outcome.stderr, outcome.stderrBytes) = Self.bounded(paths, run + "/stderr")
        Self.prune(paths)
        return outcome
    }

    /// The first reason is kept; later ones are usually its consequence.
    private func markUnusable(_ message: String) {
        state.withLock { if unusable == nil { unusable = message } }
        readinessChanged()
    }

    /// SIGINT, a two-second grace period, then SIGKILL; returns how many
    /// threads were found. Completion is the kernel's own count of live
    /// threads owned by the script uid reaching zero, not a sent signal; a
    /// negative count (kernel not answering) never counts as zero.
    private func stop(until exit: ExitBox, diagnostic: @escaping ScriptDiagnostic) async -> Int {
        let begun = ContinuousClock.now
        diagnostic("script_stop_begin", [:])
        let found = Int(await blocking { PocketISHUserTasks(Self.uid, 0) })
        diagnostic("script_stop_found", ["found": found, "ms": Self.milliseconds(since: begun)])
        guard found != 0 else { return 0 }
        var polls = 0
        _ = await blocking("signal", diagnostic) { PocketISHUserTasks(Self.uid, SIGINT) }
        for _ in 0..<20 {
            polls += 1
            if await blocking("tasks", diagnostic, { PocketISHUserTasks(Self.uid, 0) }) == 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<50 {
            polls += 1
            if await blocking("signal", diagnostic, { PocketISHUserTasks(Self.uid, SIGKILL) }) == 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<50 where !exit.done { try? await Task.sleep(for: .milliseconds(100)) }
        diagnostic("script_stop_end", ["ms": Self.milliseconds(since: begun), "terminated": max(found, 0),
                                       "polls": polls, "exited": exit.done])
        return max(found, 0)
    }

    /// A polled stop-path iSH call. Each is bounded underneath
    /// (`PocketISHWork`: 15 s for tasks and signals, 30 s for unmount); the
    /// polls are counted, and only calls slower than 500 ms are reported.
    private func blocking<T: Sendable>(_ label: String, _ diagnostic: @escaping ScriptDiagnostic,
                                       _ work: @escaping @Sendable () -> T) async -> T {
        let started = ContinuousClock.now
        let result = await blocking(work)
        let ms = Self.milliseconds(since: started)
        if ms > 500 { diagnostic("ish_call", ["op": label, "ms": ms]) }
        return result
    }
    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    private func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        (try? await runOnFFIThread(work))!
    }

    /// The project root without symbolic links (iOS /var is one), which the
    /// hostfs confinement requires, checked to be the same directory and
    /// still inside the app's Projects directory.
    static func canonicalRoot(_ root: URL) throws -> String {
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var original = stat(), canonical = stat()
        guard let path = real(root.path), let projects = real(WorkspaceStore.projectsDirectory.path),
              path.hasPrefix(projects + "/"), !path.dropFirst(projects.count + 1).contains("/"),
              stat(root.path, &original) == 0, stat(path, &canonical) == 0,
              original.st_dev == canonical.st_dev, original.st_ino == canonical.st_ino else {
            throw failure("项目目录位置无效，无法挂载。")
        }
        return path
    }

    private static func runID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(6).lowercased()
    }

    private static func size(_ paths: WorkspacePaths, _ relative: String) -> off_t {
        paths.status(relative)?.st_size ?? 0
    }

    /// Head and tail of a guest-written file, opened without following links.
    static func bounded(_ paths: WorkspacePaths, _ relative: String, head: Int = 12 * 1024, tail: Int = 4 * 1024) -> (String, Int) {
        guard let fd = try? paths.openFile(relative) else { return ("", 0) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return ("", 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let total = Int(info.st_size)
        if total <= head + tail { return (String(decoding: (try? handle.read(upToCount: head + tail)) ?? Data(), as: UTF8.self), total) }
        let first = (try? handle.read(upToCount: head)) ?? Data()
        try? handle.seek(toOffset: UInt64(total - tail))
        let last = (try? handle.read(upToCount: tail)) ?? Data()
        return (String(decoding: first, as: UTF8.self) + "\n…（省略 \(total - head - tail) 字节，完整内容见 full_output）…\n"
                + String(decoding: last, as: UTF8.self), total)
    }

    private static func prune(_ paths: WorkspacePaths) {
        guard let names = try? paths.entries(".pocketagent/runs").map(\.name) else { return }
        for name in names.sorted().dropLast(keptRuns) where !name.hasPrefix(".") {
            try? paths.remove(".pocketagent/runs/" + name)
        }
    }
}

/// FIFO: one script at a time across all conversations. This is what makes
/// uid-wide process control (count, signal, verify zero) exact: every live
/// uid-501 thread, including setsid descendants, belongs to the current run.
private actor RunGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }
}

private final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var cancelled: Bool { lock.withLock { flag } }
    func cancel() { lock.withLock { flag = true } }
}

private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var message: String?
    var done: Bool { lock.withLock { finished } }
    var error: String? { lock.withLock { message } }
    func finish(_ error: String?) { lock.withLock { message = error; finished = true } }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var done: Bool { lock.withLock { value != nil } }
    var status: Int32? { lock.withLock { value } }
    func finish(_ status: Int32) { lock.withLock { value = status } }
}
