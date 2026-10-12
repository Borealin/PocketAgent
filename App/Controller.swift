import SwiftUI
import Foundation
import Darwin
import PocketAgentNative
import Network
import AgentKit

let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let applicationSupport: URL = {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

func failure(_ message: String) -> NSError {
    NSError(domain: "PocketAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// idevice FFI work needs a larger stack than Swift concurrency threads offer.
func runOnFFIThread<T>(_ action: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let worker = Thread { continuation.resume(with: Result(catching: action)) }
        worker.name = "PocketAgent.ffi"
        worker.stackSize = 8 * 1024 * 1024
        worker.start()
    }
}

func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
    if let error {
        let message = error.pointee.message.map { String(cString: $0) } ?? "Unknown idevice error"
        let code = error.pointee.code
        let subcode = error.pointee.sub_code
        idevice_error_free(error)
        throw failure("idevice \(code)/\(subcode): \(message)")
    }
}

@MainActor
private final class LocalNetworkPermission {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var completion: CheckedContinuation<Bool, Never>?
    func request() async -> Bool {
        await withCheckedContinuation { completion in
            self.completion = completion
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            do {
                let listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(name: UUID().uuidString, type: "_pocketagent._tcp")
                listener.newConnectionHandler = { $0.cancel() }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { MainActor.assumeIsolated { self?.finish(false) } }
                }
                let browser = NWBrowser(for: .bonjour(type: "_pocketagent._tcp", domain: nil), using: parameters)
                browser.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { MainActor.assumeIsolated { self?.finish(false) } }
                }
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    if !results.isEmpty { MainActor.assumeIsolated { self?.finish(true) } }
                }
                self.listener = listener
                self.browser = browser
                listener.start(queue: .main)
                browser.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.finish(false) }
            } catch { finish(false) }
        }
    }
    private func finish(_ allowed: Bool) {
        guard let completion else { return }
        self.completion = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        completion.resume(returning: allowed)
    }
}

final class DeviceConnection {
    struct TunnelFailure: Error { let cause: any Error }
    struct Configuration {
        let pairingPath: String
        let host: String
        let port: UInt16
        static func current() throws -> Configuration {
            let endpoint = try DeviceSettings.tunnelEndpoint()
            return Configuration(pairingPath: DeviceSettings.pairingURL.path,
                                 host: endpoint.host, port: endpoint.port)
        }
    }
    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    var ddi: OpaquePointer?
    var ddiCancellation: OpaquePointer?
    private var server: OpaquePointer?
    private var process: OpaquePointer?
    private var runnerPID: UInt64?
    var ownsRunner: Bool { runnerPID != nil }
    deinit {
        if let ddi { if let error = pocket_ddi_close(ddi, ddiCancellation) { idevice_error_free(error) } }
        closeDVT()
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
    }
    private func closeDVT() {
        if let process { process_control_free(process) }
        if let server { remote_server_free(server) }
        process = nil; server = nil
    }
    func connect(configuration: Configuration) throws {
        var pairing: OpaquePointer?
        let path = configuration.pairingPath
        guard FileManager.default.fileExists(atPath: path) else { throw failure("尚未导入配对文件，请在设置中导入。") }
        try path.withCString { try check(rp_pairing_file_read($0, &pairing)) }
        guard let pairing else { throw failure("Pairing file did not open") }
        defer { rp_pairing_file_free(pairing) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.port.bigEndian
        guard inet_pton(AF_INET, configuration.host, &address.sin_addr) == 1 else { throw failure("Invalid IP") }
        do {
            try "PocketAgent".withCString { hostname in
                try withUnsafePointer(to: &address) { pointer in
                    try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        try check(tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            hostname, pairing, nil, nil, &adapter, &handshake))
                    }
                }
            }
        } catch { throw TunnelFailure(cause: error) }
        guard adapter != nil, handshake != nil else { throw failure("Incomplete tunnel handles") }
    }
    func openDDI() throws {
        guard ddi == nil else { return }
        try check(pocket_ddi_open(adapter, handshake, &ddi, &ddiCancellation))
    }
    func ddiRequest(_ object: [String: Any]) throws -> [String: Any] {
        guard let ddi else { throw failure("DDI 服务尚未连接。") }
        let data = try JSONSerialization.data(withJSONObject: object)
        let request = String(decoding: data, as: UTF8.self)
        var output: UnsafeMutablePointer<CChar>?
        try request.withCString { try check(pocket_ddi_call(ddi, $0, &output)) }
        guard let output else { throw failure("DDI 返回为空。") }
        defer { idevice_string_free(output) }
        guard let result = try JSONSerialization.jsonObject(with: Data(String(cString: output).utf8)) as? [String: Any] else { throw failure("DDI 返回格式无效。") }
        return result
    }
    func closeDDI() throws {
        let session = ddi, cancel = ddiCancellation
        ddi = nil; ddiCancellation = nil
        try check(pocket_ddi_close(session, cancel))
    }
    func hasDDI() -> Bool {
        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        if let error = cryptexd_installed_ddi(adapter, handshake, &installed) {
            idevice_error_free(error)
            return false
        }
        guard let installed else { return false }
        cryptexd_free_installed_cryptex(installed)
        return true
    }
    func mountDDI(_ directory: URL) throws {
        var assets: OpaquePointer?
        try directory.path.withCString { try check(cryptex1_assets_load($0, &assets)) }
        guard let assets else { throw failure("Missing Cryptex assets") }
        defer { cryptex1_assets_free(assets) }
        try check(cryptexd_install_ddi(adapter, handshake, assets, nil))
    }
    func connectRunnerDVT() throws {
        guard !ownsRunner else { throw failure("This turn already owns a runner") }
        closeDVT()
        try check(remote_server_connect_rsd(adapter, handshake, &server))
        guard server != nil else { throw failure("Missing DVT server") }
    }
    func installedApplications() throws -> [InstalledApp] {
        guard let adapter, let handshake, process == nil else { throw failure("Missing available device tunnel") }
        var client: OpaquePointer?
        defer { if let client { installation_proxy_client_free(client) } }
        try check(installation_proxy_connect_rsd(adapter, handshake, &client))
        guard let client else { throw failure("Missing installation service") }
        var raw: UnsafeMutableRawPointer?
        var count = 0
        try check(installation_proxy_get_apps(client, nil, nil, 0, &raw, &count))
        let apps = raw?.assumingMemoryBound(to: plist_t?.self)
        defer { if let apps { installation_proxy_free_apps(apps, UInt(count)) } }
        guard count == 0 || apps != nil else { throw failure("Missing installed application records") }
        var entries: [[String: Any]] = []
        for index in 0..<count {
            guard let app = apps?[index], plist_get_node_type(app) == PLIST_DICT else { continue }
            var entry: [String: Any] = [:]
            for key in ["CFBundleIdentifier", "CFBundlePackageType", "Path", "BundlePath",
                        "CFBundleDisplayName", "CFBundleName", "DisplayName", "displayName", "name"] {
                guard let node = plist_dict_get_item(app, key), plist_get_node_type(node) == PLIST_STRING,
                      let value = plist_get_string_ptr(node, nil) else { continue }
                entry[key] = String(cString: value)
            }
            if plist_dict_get_item(app, "NSExtension") != nil { entry["NSExtension"] = true }
            if let node = plist_dict_get_item(app, "SBAppTags"), plist_get_node_type(node) == PLIST_ARRAY {
                entry["SBAppTags"] = (0..<plist_array_get_size(node)).compactMap { index -> String? in
                    guard let child = plist_array_get_item(node, index), plist_get_node_type(child) == PLIST_STRING,
                          let value = plist_get_string_ptr(child, nil) else { return nil }
                    return String(cString: value)
                }
            }
            if let node = plist_dict_get_item(app, "IsDemotedApp"), plist_get_node_type(node) == PLIST_BOOLEAN {
                var value: UInt8 = 0; plist_get_bool_val(node, &value)
                entry["IsDemotedApp"] = value != 0
            }
            entries.append(entry)
        }
        return InstalledApps.fromMetadata(entries)
    }

    func launchRunner(bundleID runnerID: String) throws -> UInt64 {
        guard !ownsRunner else { throw failure("This turn already owns a runner") }
        guard let server else { throw failure("Missing DVT server") }
        try check(process_control_new(server, &process))
        guard let process else { throw failure("Missing process control") }
        // XCTest resolves relative bundle paths against the runner's main app
        // bundle. This stays valid when sideload signing changes its install path.
        let environment = ["USE_PORT=8100", "USE_IP=127.0.0.1", "WDA_PRODUCT_BUNDLE_IDENTIFIER=\(runnerID)",
                           "XCTestBundlePath=Frameworks/WebDriverAgentRunner.framework"]
        let allocated = environment.map { strdup($0)! }
        defer { allocated.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = allocated.map { UnsafePointer($0) }
        var pid: UInt64 = 0
        try runnerID.withCString { id in
            try pointers.withUnsafeBufferPointer {
                try check(process_control_launch_test_runner(process, id, $0.baseAddress, UInt($0.count), &pid))
            }
        }
        guard pid > 0, pid <= UInt64(UInt32.max) else { throw failure("Runner launch returned an invalid PID") }
        runnerPID = pid
        return pid
    }
    func stopRunner() throws {
        guard let runnerPID else { return }
        // Instruments may close the launch channel while XCTest is running.
        // Reopen it over the existing phone tunnel before stopping the owned PID.
        closeDVT()
        try check(remote_server_connect_rsd(adapter, handshake, &server))
        guard let server else { throw failure("Missing DVT server") }
        var info: OpaquePointer?
        try check(device_info_new(server, &info))
        guard let initialInfo = info else { throw failure("Missing device info") }
        var running = true
        do {
            defer { device_info_free(initialInfo); info = nil }
            try check(device_info_is_running_pid(initialInfo, UInt32(runnerPID), &running))
            if running {
                var name: UnsafeMutablePointer<CChar>?
                try check(device_info_execname_for_pid(initialInfo, UInt32(runnerPID), &name))
                guard let name else { throw failure("Missing runner executable") }
                defer { idevice_string_free(name) }
                guard URL(fileURLWithPath: String(cString: name)).lastPathComponent == "WebDriverAgentRunner-Runner" else {
                    throw failure("Owned PID no longer belongs to the automation runner")
                }
            }
        }
        if !running { self.runnerPID = nil; return }
        try check(process_control_new(server, &process))
        guard let process else { throw failure("Missing process control") }
        try check(process_control_kill_app(process, runnerPID))
        process_control_free(process)
        self.process = nil
        // The patched signal API waits for acknowledgement. Also verify process
        // disappearance before releasing the queue or starting another runner.
        try check(device_info_new(server, &info))
        guard let info else { throw failure("Missing device info") }
        defer { device_info_free(info) }
        for _ in 0..<30 {
            running = true
            try check(device_info_is_running_pid(info, UInt32(runnerPID), &running))
            if !running { self.runnerPID = nil; return }
            Thread.sleep(forTimeInterval: 0.1) // Runs on the dedicated FFI thread.
        }
        throw failure("Runner shutdown was not confirmed")
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    var activeAgentRuntime: AgentRuntime?
    var pendingAgentCancellation = false
    var job: Task<Void, Never>?
    var runID = ""
    var logURL: URL?
    var connection: DeviceConnection?
    var installedApps: [InstalledApp] = []
    var wdaSessionBase: String?
    @Published private(set) var networkPath = PhoneNetworkPath()
    @Published private(set) var deviceConnectionBusy = false
    @Published private(set) var preparingPhoneConnection = false
    @Published private(set) var preparedConnectionExpiresAt: Date?
    @Published private(set) var phonePreparationStatus = "尚未准备保留连接"
    private let pathMonitor = NWPathMonitor()
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparedConnection: DeviceConnection?
    private var preparedConnectionDeadline: TimeInterval?
    private var preparedConnectionExpired = false
    private var preparedExpiryRejectedRunID: String?
    private var preparedConnectionInUse = false
    private var preparationGeneration = 0
    private var preparationJob: Task<Void, Never>?
    private var preparedExpiryJob: Task<Void, Never>?
    private var preparationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    var hasPreparedPhoneConnection: Bool { preparedConnection != nil }
    init() {
        DeviceSettings.migrateLegacyPairing()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.networkPath = PhoneNetworkPath(path) }
        }
        pathMonitor.start(queue: .main)
        // Native file logging only when the user opted in (read at launch).
        if DeviceSettings.saveDiagnosticLogs {
            let path = documents.appendingPathComponent("idevice-stages.log").path
            _ = path.withCString {
                idevice_init_logger(IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 3), UnsafeMutablePointer(mutating: $0))
            }
        }
    }
    private let http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    func ffi<T>(_ action: @escaping () throws -> T) async throws -> T {
        try await runOnFFIThread(action)
    }
    /// Settings handshakes and turn startup share this gate. A turn may begin
    /// model work while preparation finishes, but cannot touch the phone yet.
    private func acquireDeviceConnection() async {
        guard deviceConnectionBusy else { deviceConnectionBusy = true; return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }
    private func releaseDeviceConnection() {
        if connectionWaiters.isEmpty { deviceConnectionBusy = false }
        else { connectionWaiters.removeFirst().resume() }
    }
    func beginDeviceConfigurationChange() -> Bool {
        guard !busy, !deviceConnectionBusy else { return false }
        deviceConnectionBusy = true
        releasePreparedPhoneConnection(message: "设备设置已更改，请重新准备连接")
        return true
    }
    func endDeviceConfigurationChange() { releaseDeviceConnection() }

    /// Setup has its own protected diagnostic file; it never borrows a previous
    /// turn's runID/logURL. Callers supply only the non-sensitive fields below.
    private func logPhoneConnection(_ event: String, context: PhoneConnectionDiagnosticContext,
                                    fields: [String: Any] = [:]) {
        guard DeviceSettings.saveDiagnosticLogs else { return }
        let allowed = Set(["networkPath", "usesWiFi", "usesCellular", "usesOtherInterface",
                           "isExpensive", "isConstrained", "connectionStage", "connectionError",
                           "nativeErrorCode", "errorDomain", "errorCode"])
        var record = fields.filter { allowed.contains($0.key) }
        record["event"] = event
        record["context"] = context.rawValue
        record["time"] = ISO8601DateFormatter().string(from: Date())
        record["appState"] = UIApplication.shared.applicationState.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        var directory = applicationSupport.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let file = directory.appendingPathComponent("phone-connection.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
            try handle.synchronize()
        } catch { /* Optional diagnostics never change connection behavior. */ }
    }

    private func connectPhone(_ device: DeviceConnection, configuration: DeviceConnection.Configuration,
                              context: PhoneConnectionDiagnosticContext) async throws {
        let path = networkPath
        logPhoneConnection("rp_tunnel_connect_started", context: context, fields: path.diagnosticFields)
        do { try await ffi { try device.connect(configuration: configuration) } }
        catch {
            guard let tunnelError = error as? DeviceConnection.TunnelFailure else {
                logPhoneConnection("rp_pairing_configuration_failed", context: context, fields: Model.errorFields(error))
                throw error
            }
            let diagnostic = PhoneConnectionFailure(tunnelError.cause, path: path)
            logPhoneConnection("rp_tunnel_connect_failed", context: context, fields: diagnostic.diagnosticFields)
            throw diagnostic
        }
        logPhoneConnection("rp_tunnel_connect_succeeded", context: context, fields: networkPath.diagnosticFields)
    }

    /// An ordinary check owns only a temporary tunnel and never preserves it.
    func checkPhoneConnection() async throws {
        guard !busy, !deviceConnectionBusy, !hasPreparedPhoneConnection else {
            throw failure("请等待当前手机任务结束；如已准备连接，请先释放它再检查。")
        }
        let configuration = try DeviceConnection.Configuration.current()
        deviceConnectionBusy = true
        defer { releaseDeviceConnection() }
        let device = DeviceConnection()
        try await connectPhone(device, configuration: configuration, context: .deviceSetup)
        // A fresh explicit check supersedes an earlier expired preparation,
        // without reviving or retaining that preparation's old handles.
        preparedConnectionExpired = false
        preparedExpiryRejectedRunID = nil
    }

    /// The manual recovery establishes RP only. WDA still starts under the
    /// next turn's existing phone executor, after the user restores data.
    func prepareCellularConnection() {
        guard !busy, !deviceConnectionBusy else { return }
        releasePreparedPhoneConnection(message: "正在准备连接…")
        let configuration: DeviceConnection.Configuration
        do { configuration = try .current() }
        catch { phonePreparationStatus = error.localizedDescription; return }
        deviceConnectionBusy = true
        preparingPhoneConnection = true
        let generation = preparationGeneration
        phonePreparationStatus = "正在建立 RP 隧道；请暂时保持蜂窝数据关闭"
        preparationBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PreparePhoneConnection") { [weak self] in
            guard let self, self.preparationGeneration == generation else { return }
            self.releasePreparedPhoneConnection(message: "系统后台保留时间已结束，请重新准备连接", expired: true)
        }
        guard preparationBackgroundTask != .invalid else {
            phonePreparationStatus = "系统未提供后台保留时间，请回到 App 后重新准备连接"
            preparingPhoneConnection = false
            releaseDeviceConnection()
            return
        }
        preparationJob = Task {
            defer {
                preparingPhoneConnection = false
                preparationJob = nil
                releaseDeviceConnection()
            }
            let device = DeviceConnection()
            do {
                try await connectPhone(device, configuration: configuration, context: .deviceSetup)
                guard generation == preparationGeneration, !Task.isCancelled else { return }
                preparedConnection = device
                preparedConnectionDeadline = ProcessInfo.processInfo.systemUptime + 120
                preparedConnectionExpiresAt = Date().addingTimeInterval(120)
                phonePreparationStatus = "连接已保留。现在开回蜂窝数据，再发送新消息；下一次手机操作会使用它。"
                logPhoneConnection("rp_tunnel_prepared", context: .deviceSetup, fields: networkPath.diagnosticFields)
                preparedExpiryJob = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    guard let self, self.preparationGeneration == generation else { return }
                    self.releasePreparedPhoneConnection(message: "准备连接已过期，请重新准备", expired: true)
                }
            } catch {
                guard generation == preparationGeneration else { return }
                phonePreparationStatus = error.localizedDescription
                endPreparationBackgroundTask()
            }
        }
    }

    func releasePreparedPhoneConnection(message: String = "已释放准备连接", expired: Bool = false) {
        if preparedConnection != nil || preparingPhoneConnection {
            logPhoneConnection(expired ? "rp_tunnel_prepared_expired" : "rp_tunnel_prepared_released",
                               context: .deviceSetup, fields: networkPath.diagnosticFields)
        }
        preparationGeneration += 1
        preparationJob?.cancel()
        preparedExpiryJob?.cancel(); preparedExpiryJob = nil
        preparedConnection = nil
        preparedConnectionDeadline = nil
        preparedConnectionExpired = expired
        preparedConnectionExpiresAt = nil
        phonePreparationStatus = message
        endPreparationBackgroundTask()
    }
    private func endPreparationBackgroundTask() {
        guard preparationBackgroundTask != .invalid else { return }
        let identifier = preparationBackgroundTask
        preparationBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }
    private func consumePreparedPhoneConnection() throws -> DeviceConnection? {
        func rejectExpiredConnection() throws -> Never {
            // This turn cannot reconnect behind an expired preparation or retry
            // phone effects, but a later explicit user turn may connect normally.
            preparedConnectionExpired = false
            preparedExpiryRejectedRunID = runID
            logPhoneConnection("rp_tunnel_prepared_rejected", context: .activeTurn,
                               fields: networkPath.diagnosticFields)
            throw failure("准备连接已过期。请重新准备连接，或在可连接的网络下发送新消息；本轮手机操作未执行，不会自动重试。")
        }
        if preparedConnectionExpired || preparedExpiryRejectedRunID == runID { try rejectExpiredConnection() }
        guard let device = preparedConnection else { return nil }
        guard let deadline = preparedConnectionDeadline,
              ProcessInfo.processInfo.systemUptime < deadline,
              preparationBackgroundTask != .invalid else {
            releasePreparedPhoneConnection(message: "准备连接已过期，请重新准备", expired: true)
            try rejectExpiredConnection()
        }
        preparedConnection = nil
        preparationGeneration += 1
        preparedConnectionDeadline = nil
        preparedConnectionExpiresAt = nil
        preparedExpiryJob?.cancel(); preparedExpiryJob = nil
        endPreparationBackgroundTask()
        preparedConnectionInUse = true
        phonePreparationStatus = "本轮正在使用准备连接，结束后会释放"
        logPhoneConnection("rp_tunnel_prepared_consumed", context: .activeTurn, fields: networkPath.diagnosticFields)
        return device
    }
    private func runnerStage<T>(_ event: String, description: String,
                                operation: () async throws -> T) async throws -> T {
        log(event + "_started")
        do { return try await operation() }
        catch {
            log(event + "_failed", Model.errorFields(error))
            if error is CancellationError { throw error }
            throw failure("\(description)：\(error.localizedDescription)")
        }
    }
    /// Writes run metadata (event names, counts, IDs; never prompts, keys,
    /// arguments, results or response bodies) only when diagnostics are on.
    func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard DeviceSettings.saveDiagnosticLogs else { return }
        var record = fields
        record["event"] = event
        record["runID"] = runID
        record["time"] = ISO8601DateFormatter().string(from: Date())
        record["appState"] = UIApplication.shared.applicationState.rawValue
        guard let logURL, let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([10]))
            try? handle.synchronize()
        }
    }
    func cancel() {
        releasePreparedPhoneConnection(message: "已停止并释放准备连接")
        pendingAgentCancellation = true
        if let runtime = activeAgentRuntime {
            // Drain AgentKit's terminal events before releasing phone resources.
            // Cancelling the consumer task would stop waiting for an in-flight tool.
            Task { await runtime.cancel() }
        } else { job?.cancel() }
    }
    private func preparePhoneTransport() async throws -> DeviceConnection {
        let device: DeviceConnection
        if let existing = connection {
            // A failed HTTP/session setup may already own a running process.
            // Resume setup without replacing the object that owns its PID.
            device = existing
        } else if let prepared = try consumePreparedPhoneConnection() {
            device = prepared
            connection = prepared
        } else {
            let configuration = try DeviceConnection.Configuration.current()
            log("network_authorization_requested")
            guard await LocalNetworkPermission().request() else {
                throw failure("Allow Local Network access for PocketAgent in Settings")
            }
            try Task.checkCancellation()
            log("network_authorized")
            device = DeviceConnection()
            try await connectPhone(device, configuration: configuration, context: .activeTurn)
            connection = device
            log("rp_tunnel_connected")
        }
        if !(try await ffi { device.hasDDI() }) {
            log("ddi_download")
            let directory = documents.appendingPathComponent("DDI", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"] {
                let destination = directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                let url = URL(string: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/\(name)")!
                let (temporary, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("DDI download failed: \(name)") }
                try FileManager.default.moveItem(at: temporary, to: destination)
                }
            }
            try await ffi { try device.mountDDI(directory) }
        }
        log("ddi_ready")
        try Task.checkCancellation()
        return device
    }
    func prepareDDI() async throws {
        await acquireDeviceConnection()
        defer { releaseDeviceConnection() }
        try Task.checkCancellation()
        guard !pendingAgentCancellation else { throw CancellationError() }
        let device = try await preparePhoneTransport()
        guard device.ddi == nil else { return }
        try await runnerStage("ddi_services_connect", description: "DDI 控制服务连接失败") {
            try await self.ffi { try device.openDDI() }
        }
        try Task.checkCancellation()
        guard !pendingAgentCancellation else { throw CancellationError() }
        installedApps = try await ffi { try device.installedApplications() }
        log("ddi_services_ready")
    }
    func prepareWDA() async throws -> String {
        await acquireDeviceConnection()
        defer { releaseDeviceConnection() }
        try Task.checkCancellation()
        guard !pendingAgentCancellation else { throw CancellationError() }
        let device = try await preparePhoneTransport()
        if !device.ownsRunner {
            wdaSessionBase = nil
            let override = DeviceSettings.runnerBundleIDOverride
            let defaultID = DeviceSettings.embeddedRunnerBundleID
            let assistantID = DeviceSettings.assistantBundleID
            try await runnerStage("runner_dvt_connect", description: "Automation 开发服务连接失败") {
                try await self.ffi { try device.connectRunnerDVT() }
            }
            try Task.checkCancellation()
            let apps = try await runnerStage("runner_apps_listing", description: "App 安装列表读取失败") {
                try await self.ffi { try device.installedApplications() }
            }
            installedApps = apps
            let installedIDs = Set(apps.map(\.bundleID))
            try Task.checkCancellation()
            let runnerID = try await runnerStage("runner_bundle_resolve", description: "Automation 配置检查失败") {
                try RunnerBundleID.resolve(override: override, embeddedDefaultID: defaultID,
                                           assistantBundleID: assistantID, installedIDs: installedIDs)
            }
            log("runner_bundle_resolved", ["usedOverride": override != nil,
                                          "matchedAssistantSuffix": override == nil && runnerID != defaultID])
            try Task.checkCancellation()
            let pid = try await runnerStage("runner_launch", description: "Automation 进程启动失败") {
                try await self.ffi { try device.launchRunner(bundleID: runnerID) }
            }
            log("runner_launched", ["pid": pid])
        }
        if wdaSessionBase == nil {
            var ready = false
            for _ in 0..<45 {
                try Task.checkCancellation()
                if (try? await request("GET", "/status")) != nil { ready = true; break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard ready else { throw failure("WDA HTTP did not become ready") }
            log("wda_ready", ["endpoint": "127.0.0.1:8100"])
            let capabilities: [String: Any] = ["shouldWaitForQuiescence": false,
                "waitForIdleTimeout": 0, "forceAppLaunch": false]
            let result = try await request("POST", "/session", ["capabilities": ["alwaysMatch": capabilities]])
            let session = (result["sessionId"] as? String) ?? ((result["value"] as? [String: Any])?["sessionId"] as? String)
            guard let session else { throw failure("Missing WDA session ID") }
            wdaSessionBase = "/session/\(session)"
        }
        let base = wdaSessionBase!
        let bounds = UIScreen.main.bounds
        _ = try await request("POST", "\(base)/appium/settings",
            ["settings": ["waitForIdleTimeout": 0, "animationCoolOffTimeout": 0,
                          "activeAppDetectionPoint": "\(bounds.midX),\(bounds.midY)"]])
        return base
    }
    /// Called in an uncancelled task after the agent has stopped using tools.
    /// Keep the serial queue occupied until activation and runner teardown finish.
    func finishPhoneAutomation() async -> String {
        await acquireDeviceConnection()
        defer { releaseDeviceConnection() }
        defer {
            wdaSessionBase = nil; connection = nil; installedApps = []
            if preparedConnectionInUse {
                preparedConnectionInUse = false
                phonePreparationStatus = "本轮已结束，使用的准备连接已释放"
            }
        }
        guard let device = connection else { return "" }
        var warnings: [String] = []
        if device.ddi != nil {
            do {
                // Finalization runs uncancelled. Returning to our app is a
                // cleanup effect, even after Stop or a failed AX observation.
                _ = try await ffi { try device.ddiRequest(["op": "return", "bundle_id": DeviceSettings.assistantBundleID]) }
                log("assistant_returned")
            } catch { warnings.append("未能自动返回 App，请手动切回。"); log("assistant_return_failed", Model.errorFields(error)) }
            do { try await ffi { try device.closeDDI() }; log("ddi_services_closed") }
            catch { warnings.append("DDI 服务清理未完全确认，连接已释放。"); log("ddi_close_failed", Model.errorFields(error)) }
            return warnings.joined(separator: " ")
        }
        guard device.ownsRunner else { return "" }
        if let base = wdaSessionBase {
            do {
                _ = try await request("POST", "\(base)/wda/apps/activate",
                    ["bundleId": DeviceSettings.assistantBundleID])
                log("assistant_returned")
            } catch {
                log("assistant_return_failed", Model.errorFields(error))
                warnings.append("未能自动返回 App，请手动切回。")
            }
        }
        // DELETE /session only removes the HTTP session; XCTest remains alive.
        // Stop only the PID returned by this turn's own runner launch.
        do {
            try await ffi { try device.stopRunner() }
            log("runner_stopped")
        } catch {
            log("runner_stop_failed", Model.errorFields(error))
            warnings.append("自动化进程未能停止，请检查 VPN 连接。")
        }
        return warnings.joined(separator: " ")
    }
    func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8100\(path)")!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let route = WDARequestDiagnostics.route(path)
        let requestID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        log("wda_request_started", ["requestID": requestID, "method": method, "route": route])
        do {
            let (data, response) = try await http.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard code == 200, (json["value"] as? [String: Any])?["error"] == nil else {
                throw failure("WDA \(path): \(String(data: data, encoding: .utf8) ?? "invalid response")")
            }
            log("wda_request_finished", ["requestID": requestID, "method": method, "route": route,
                "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - started) * 1000), "statusCode": code])
            return json
        } catch {
            var fields = Model.errorFields(error)
            fields.merge(["requestID": requestID, "method": method, "route": route,
                "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)]) { _, new in new }
            log("wda_request_failed", fields)
            throw error
        }
    }
}

@main
struct ControllerApp: App {
    @StateObject private var model: Model
    @StateObject private var providers: ProviderStore
    @StateObject private var chat: ChatController
    @StateObject private var sync: SyncCoordinator
    @StateObject private var device: DeviceSettingsModel
    @StateObject private var workspaces: WorkspaceStore
    init() {
        let model = Model(), providers = ProviderStore(), workspaces = WorkspaceStore()
        let chat = ChatController(engine: model, providers: providers, workspaces: workspaces)
        _model = StateObject(wrappedValue: model)
        _device = StateObject(wrappedValue: DeviceSettingsModel(engine: model))
        _workspaces = StateObject(wrappedValue: workspaces)
        _providers = StateObject(wrappedValue: providers)
        _chat = StateObject(wrappedValue: chat)
        _sync = StateObject(wrappedValue: SyncCoordinator(chat: chat, providers: providers))
    }
    var body: some Scene {
        WindowGroup {
            ChatRootView(engine: model, chat: chat, providers: providers, sync: sync, device: device, workspaces: workspaces)
        }
    }
}
