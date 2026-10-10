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
    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var process: OpaquePointer?
    private var runnerPID: UInt64?
    var ownsRunner: Bool { runnerPID != nil }
    deinit {
        closeDVT()
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
    }
    private func closeDVT() {
        if let process { process_control_free(process) }
        if let server { remote_server_free(server) }
        process = nil; server = nil
    }
    func connect() throws {
        var pairing: OpaquePointer?
        let path = DeviceSettings.pairingURL.path
        guard FileManager.default.fileExists(atPath: path) else { throw failure("尚未导入配对文件，请在设置中导入。") }
        try path.withCString { try check(rp_pairing_file_read($0, &pairing)) }
        guard let pairing else { throw failure("Pairing file did not open") }
        defer { rp_pairing_file_free(pairing) }
        let endpoint = try DeviceSettings.tunnelEndpoint()
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else { throw failure("Invalid IP") }
        try "PocketAgent".withCString { hostname in
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    try check(tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                        hostname, pairing, nil, nil, &adapter, &handshake))
                }
            }
        }
        guard adapter != nil, handshake != nil else { throw failure("Incomplete tunnel handles") }
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
    func launchRunner() throws -> UInt64 {
        guard !ownsRunner else { throw failure("This turn already owns a runner") }
        closeDVT()
        try check(remote_server_connect_rsd(adapter, handshake, &server))
        guard let server else { throw failure("Missing DVT server") }
        try check(process_control_new(server, &process))
        guard let process else { throw failure("Missing process control") }
        let runnerID = DeviceSettings.runnerBundleID
        let environment = ["USE_PORT=8100", "USE_IP=127.0.0.1", "WDA_PRODUCT_BUNDLE_IDENTIFIER=\(runnerID)"]
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
    var wdaSessionBase: String?
    init() {
        DeviceSettings.migrateLegacyPairing()
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

    private func ffi<T>(_ action: @escaping () throws -> T) async throws -> T {
        try await runOnFFIThread(action)
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
        pendingAgentCancellation = true
        if let runtime = activeAgentRuntime {
            // Drain AgentKit's terminal events before releasing phone resources.
            // Cancelling the consumer task would stop waiting for an in-flight tool.
            Task { await runtime.cancel() }
        } else { job?.cancel() }
    }
    func prepareWDA() async throws -> String {
        let device: DeviceConnection
        if let existing = connection {
            // A failed HTTP/session setup may already own a running process.
            // Resume setup without replacing the object that owns its PID.
            device = existing
        } else {
            log("network_authorization_requested")
            guard await LocalNetworkPermission().request() else {
                throw failure("Allow Local Network access for PocketAgent in Settings")
            }
            try Task.checkCancellation()
            log("network_authorized")
            device = DeviceConnection()
            try await ffi { try device.connect() }
            connection = device
            log("rp_tunnel_connected")
        }
        if !device.ownsRunner {
            wdaSessionBase = nil
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
            let pid = try await ffi { try device.launchRunner() }
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
        _ = try await request("POST", "\(base)/appium/settings",
            ["settings": ["waitForIdleTimeout": 0, "animationCoolOffTimeout": 0]])
        return base
    }
    /// Called in an uncancelled task after the agent has stopped using tools.
    /// Keep the serial queue occupied until activation and runner teardown finish.
    func finishPhoneAutomation() async -> String {
        defer { wdaSessionBase = nil; connection = nil }
        guard let device = connection, device.ownsRunner else { return "" }
        var warnings: [String] = []
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
        let (data, response) = try await http.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (json["value"] as? [String: Any])?["error"] == nil else {
            throw failure("WDA \(path): \(String(data: data, encoding: .utf8) ?? "invalid response")")
        }
        return json
    }
}

@main
struct ControllerApp: App {
    @StateObject private var model: Model
    @StateObject private var providers: ProviderStore
    @StateObject private var chat: ChatController
    @StateObject private var sync: SyncCoordinator
    @StateObject private var device = DeviceSettingsModel()
    @StateObject private var workspaces: WorkspaceStore
    init() {
        let model = Model(), providers = ProviderStore(), workspaces = WorkspaceStore()
        let chat = ChatController(engine: model, providers: providers, workspaces: workspaces)
        _model = StateObject(wrappedValue: model)
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
