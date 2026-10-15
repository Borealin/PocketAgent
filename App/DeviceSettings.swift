import Darwin
import Foundation
import PocketAgentNative
import SwiftUI

/// Per-device automation settings. Nothing here syncs: pairing records,
/// runner identity and tunnel address belong to this phone only.
enum DeviceSettings {
    static let defaultRunnerBundleID = RunnerBundleID.canonicalRunnerBundleID
    static let defaultTunnelEndpoint = "10.7.0.1:49152"
    private static let runnerKey = "runnerBundleID", tunnelKey = "tunnelEndpoint"
    private static let screenshotsKey = "saveDiagnosticScreenshots", logsKey = "saveDiagnosticLogs"

    static var pairingDirectory: URL { applicationSupport.appendingPathComponent("Pairing", isDirectory: true) }
    static var pairingURL: URL { pairingDirectory.appendingPathComponent("rp_pairing_file.plist") }
    static var hasPairing: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    /// Local override, then build `Info.plist`, then the public default.
    static var runnerBundleID: String {
        runnerBundleIDOverride ?? embeddedRunnerBundleID
    }
    static var runnerBundleIDOverride: String? { nonEmpty(UserDefaults.standard.string(forKey: runnerKey)) }
    static var embeddedRunnerBundleID: String {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "PocketAgentRunnerBundleID") as? String) ?? defaultRunnerBundleID
    }
    /// The endpoint used when the local override is empty; independent of saved settings.
    static var embeddedTunnelEndpoint: String {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "PocketAgentTunnelEndpoint") as? String)
            ?? defaultTunnelEndpoint
    }
    static var tunnelEndpointText: String {
        nonEmpty(UserDefaults.standard.string(forKey: tunnelKey)) ?? embeddedTunnelEndpoint
    }
    static var assistantBundleID: String { Bundle.main.bundleIdentifier ?? "" }
    static var phoneBackend: PhoneBackendKind {
        UserDefaults.standard.string(forKey: "phoneControlBackend").flatMap(PhoneBackendKind.init(rawValue:)) ?? .defaultBackend
    }
    /// Preserve existing text behavior on upgrade; this policy is device-local.
    static var clipboardAllowed: Bool { UserDefaults.standard.object(forKey: "phoneClipboardAllowed") as? Bool ?? true }
    /// Off by default; screenshots may contain personal screen content.
    static var saveScreenshots: Bool { UserDefaults.standard.bool(forKey: screenshotsKey) }
    /// Off by default: no run log or native idevice log file is written.
    static var saveDiagnosticLogs: Bool { UserDefaults.standard.bool(forKey: logsKey) }
    /// Acceptance-only fault injection: when the app is launched with this
    /// argument, system task submission fails before any dispatch permit.
    /// Absent by default; it cannot be enabled from the app UI.
    static var injectStartFailure: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentInjectStartFailure") }
    /// Local launch argument only (not reachable from the UI): measure the long-
    /// history write path on a synthetic file in a temporary directory and write
    /// `Documents/long-history-benchmark.json`. The real history is not touched.
    static var longHistoryBenchmark: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentLongHistoryBenchmark") }
    /// Local launch argument only: the real transcript view over synthetic long
    /// histories in a read-only controller (`ViewportBenchmarkRoot`).
    static var viewportBenchmark: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentViewportBenchmark") }
    /// Local acceptance launch argument only (fault injection, not reachable
    /// from the UI): each context-maintenance fold waits 20 s after its checks
    /// and read registration, before its provider request, so a forget can be
    /// confirmed while the turn prepares. The wait is cancellable; nothing is
    /// sent or shown during it.
    static var maintenanceDispatchHold: Duration? {
        ProcessInfo.processInfo.arguments.contains("-PocketAgentHoldMaintenanceDispatch") ? .seconds(20) : nil
    }
    /// Local acceptance launch arguments only (not reachable from the UI):
    /// record the kinds, sizes and timing of each maintenance fold's stream
    /// events, no content, in `Documents/maintenance-stream-*.json`.
    static var recordMaintenanceStream: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentRecordMaintenanceStream") }
    /// Fault injection: a fold sends no provider request and receives a new
    /// summary text increment every 3 s instead, so the real 150 s
    /// maintenance deadline (not the 45 s idle limit) ends it.
    static var injectSlowSummaryStream: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentInjectSlowSummaryStream") }
    /// At the first summary text received from the provider, request the same
    /// stop as the Stop button for the primary line.
    static var stopAtFirstSummaryText: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentStopAtFirstSummaryText") }
    static let diagnosticStop = Notification.Name("PocketAgent.diagnosticStop")
    /// After a run's first script phone call, the next history write fails
    /// once (fault injection) on a run event, so storage becomes dirty while
    /// the script still runs.
    static var dirtyAfterFirstScriptCall: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentDirtyAfterFirstScriptCall") }
    static let diagnosticDirty = Notification.Name("PocketAgent.diagnosticDirty")
    /// Provider error shapes through the pinned client on the device (`ProviderLimitProbe`).
    static var providerLimitProbe: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentProviderLimitProbe") }
    /// The script helper gate on the device (`ScriptGateProbe`).
    static var scriptGateProbe: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentScriptGateProbe") }
    /// Context maintenance end to end on isolated data (`SummaryMaintenanceProbe`).
    static var summaryMaintenanceProbe: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAgentSummaryMaintenanceProbe") }
    /// Metadata diagnostics (run log and native log) for this launch only,
    /// without changing the saved setting.
    static var diagnosticsEnabled: Bool {
        saveDiagnosticLogs || ProcessInfo.processInfo.arguments.contains("-PocketAgentDiagnosticLogs")
    }
    private static func argument(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    /// Lowers the cap of one native DDI call (seconds); the expiry is computed
    /// and enforced exactly as in production.
    static var ddiCallBudgetCap: TimeInterval {
        argument(after: "-PocketAgentDDICallBudgetCap").flatMap(TimeInterval.init).map { max(1, $0) } ?? DDICallBudget.cap
    }
    /// Fault injection: one DDI stage (`ax_read`, `geometry` or `screenshot`)
    /// stalls once per native session until Stop or the call's expiry ends it.
    static var injectDDIStall: String? {
        argument(after: "-PocketAgentInjectDDIStall").flatMap { ["ax_read", "geometry", "screenshot"].contains($0) ? $0 : nil }
    }
    /// Fault injection: the next native call of this operation (for example
    /// `tap`) is refused before dispatch, as when too little of the turn is
    /// left; once per phone control.
    static var refuseNextDDIDispatch: String? { argument(after: "-PocketAgentRefuseNextDDIDispatch") }
    /// Fault injection: the first touch release of a native session is sent,
    /// then its confirmation is treated as lost, so the real unconfirmed-release
    /// path runs. No input is left held.
    static var dropInputReleaseConfirmation: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketAgentDropInputReleaseConfirmation")
    }
    /// Local acceptance launch argument only (not reachable from the UI): the
    /// `PKATEST_` marker of one own memory entry that a running primary turn,
    /// after reading it, forgets once through the panel's own preview and
    /// commit (`ChatController.diagnosticForgetDuringRun`).
    static var forgetDuringRunMarker: String? {
        argument(after: "-PocketAgentForgetDuringRun").flatMap { $0.hasPrefix("PKATEST_") ? $0 : nil }
    }

    /// Writes `Documents/summary-maintenance-probe.json`: the probe's cases
    /// with a fresh run nonce, start and end time, process and build.
    @MainActor
    private static func runSummaryMaintenanceProbe() async {
        try? await Task.sleep(for: .seconds(2))
        let started = Date()
        var report = await SummaryMaintenanceProbe.report()
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        report["configuration"] = "device \(configuration) \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        report["runNonce"] = UUID().uuidString
        report["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        let format = ISO8601DateFormatter()
        report["startedAt"] = format.string(from: started)
        report["endedAt"] = format.string(from: Date())
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("summary-maintenance-probe.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    @MainActor
    static func runLongHistoryBenchmarkIfRequested() async {
        if scriptGateProbe { await ScriptGateProbe.runAndReport(); return }
        if providerLimitProbe { await ProviderLimitProbe.runAndReport(); return }
        if summaryMaintenanceProbe { await runSummaryMaintenanceProbe(); return }
        guard longHistoryBenchmark else { return }
        // Let launch finish first; the run yields between samples.
        try? await Task.sleep(for: .seconds(3))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa-bench-\(UUID().uuidString)")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let output = documents.appendingPathComponent("long-history-benchmark.json")
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        let label = "device \(configuration) \(info["CFBundleShortVersionString"] as? String ?? "?")"
            + " (\(info["CFBundleVersion"] as? String ?? "?"))"
        do {
            try await LongHistoryBenchmark.report(sizes: [10_000, 50_000], directory: directory, label: label)
                .write(to: output, options: .atomic)
        } catch {
            let failure = ["configuration": label, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]).write(to: output, options: .atomic)
        }
    }

    static func tunnelEndpoint() throws -> (host: String, port: UInt16) {
        try parseEndpoint(tunnelEndpointText)
    }

    static func parseEndpoint(_ text: String) throws -> (host: String, port: UInt16) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        var address = in_addr()
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0,
              inet_pton(AF_INET, String(parts[0]), &address) == 1 else {
            throw failure("VPN 隧道地址应为 IPv4:端口，例如 \(defaultTunnelEndpoint)")
        }
        return (String(parts[0]), port)
    }

    static func save(runner: String, tunnel: String, screenshots: Bool, logs: Bool) throws {
        let runner = runner.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnel = tunnel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tunnel.isEmpty { _ = try parseEndpoint(tunnel) }
        guard runner.isEmpty || runner.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw failure("Runner Bundle ID 只能包含字母、数字、点和连字符。")
        }
        let defaults = UserDefaults.standard
        runner.isEmpty ? defaults.removeObject(forKey: runnerKey) : defaults.set(runner, forKey: runnerKey)
        tunnel.isEmpty ? defaults.removeObject(forKey: tunnelKey) : defaults.set(tunnel, forKey: tunnelKey)
        defaults.set(screenshots, forKey: screenshotsKey)
        defaults.set(logs, forKey: logsKey)
    }

    /// Earlier builds read the pairing record from Documents. Move it once
    /// into protected, backup-excluded Application Support.
    static func migrateLegacyPairing() {
        let legacy = documents.appendingPathComponent("rp_pairing_file.plist")
        guard !hasPairing, FileManager.default.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy), (try? validatedPlist(data)) != nil else { return }
        do {
            try install(data)
            try FileManager.default.removeItem(at: legacy)
        } catch {
            try? FileManager.default.removeItem(at: pairingURL)
        }
    }

    /// Imports a user-picked RP pairing property list after checking both its
    /// shape and that the native pairing reader accepts it.
    static func importPairing(from url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: PairingImport.maximumBytes + 1) ?? Data()
            try PairingImport.validate(data)
            return data
        }.value
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
        try data.write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: probe) }
        try await runOnFFIThread {
            var pairing: OpaquePointer?
            try probe.path.withCString { try check(rp_pairing_file_read($0, &pairing)) }
            guard let pairing else { throw failure("配对文件无法解析。") }
            rp_pairing_file_free(pairing)
        }
        try install(data)
    }

    @discardableResult
    private static func validatedPlist(_ data: Data) throws -> [String: Any] {
        try PairingImport.validate(data)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              !plist.isEmpty else { throw failure("所选文件不是 RP 配对属性列表。") }
        return plist
    }

    private static func install(_ data: Data) throws {
        var directory = pairingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        var file = pairingURL
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try file.setResourceValues(values)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.hasPrefix("$(") else { return nil }
        return value
    }
}

@MainActor
final class DeviceSettingsModel: ObservableObject {
    @Published var backend = DeviceSettings.phoneBackend
    @Published var clipboardAllowed = DeviceSettings.clipboardAllowed
    @Published var runner = UserDefaults.standard.string(forKey: "runnerBundleID") ?? ""
    @Published var tunnel = UserDefaults.standard.string(forKey: "tunnelEndpoint") ?? ""
    @Published var saveScreenshots = DeviceSettings.saveScreenshots
    @Published var saveLogs = DeviceSettings.saveDiagnosticLogs
    @Published private(set) var hasPairing = DeviceSettings.hasPairing
    @Published private(set) var importing = false
    @Published private(set) var checking = false
    @Published private(set) var connectionStatus = "尚未检查连接"
    @Published private(set) var connectionVerified = false
    @Published var status = ""
    private var generation = 0
    private let engine: Model

    init(engine: Model) { self.engine = engine }

    func saveBackend() {
        guard engine.beginDeviceConfigurationChange() else {
            backend = DeviceSettings.phoneBackend
            status = "请等待当前连接检查、准备或手机任务结束后再切换。"
            return
        }
        defer { engine.endDeviceConfigurationChange() }
        UserDefaults.standard.set(backend.rawValue, forKey: "phoneControlBackend")
        generation += 1
        connectionVerified = false
        status = backend == .ddi ? "已选择 DDI，无需安装 Automation。" : "已选择 WDA，请安装匹配的 Automation。"
    }

    func saveClipboardPolicy() {
        guard engine.beginDeviceConfigurationChange() else {
            clipboardAllowed = DeviceSettings.clipboardAllowed
            status = "请等待当前手机任务结束后再修改剪贴板许可。"
            return
        }
        defer { engine.endDeviceConfigurationChange() }
        UserDefaults.standard.set(clipboardAllowed, forKey: "phoneClipboardAllowed")
        status = clipboardAllowed ? "后续回合允许模型使用剪贴板输入。" : "后续回合禁止剪贴板；DDI 可直接替换普通单行文本框或逐键输入。"
    }

    func save() {
        guard !importing, !checking, engine.beginDeviceConfigurationChange() else {
            status = "请等待当前连接检查、准备或手机任务结束后再保存。"
            return
        }
        defer { engine.endDeviceConfigurationChange() }
        do {
            try DeviceSettings.save(runner: runner, tunnel: tunnel, screenshots: saveScreenshots, logs: saveLogs)
            generation += 1
            connectionVerified = false; connectionStatus = "设置已更改，请检查连接"
            status = "已保存。"
        }
        catch { status = error.localizedDescription }
    }

    func importPairing(_ result: Result<URL, any Error>) {
        guard !importing, !checking, engine.beginDeviceConfigurationChange() else {
            status = "请等待当前连接检查、准备或手机任务结束后再导入。"
            return
        }
        importing = true
        Task {
            defer { importing = false; engine.endDeviceConfigurationChange() }
            do {
                try await DeviceSettings.importPairing(from: result.get())
                generation += 1
                connectionVerified = false; connectionStatus = "配对文件已导入，请检查连接"
                status = "导入成功。连接 LocalDevVPN 后，点“检查连接”。"
            } catch { status = "导入失败：\(error.localizedDescription)" }
            hasPairing = DeviceSettings.hasPairing
        }
    }

    /// Verifies the pairing and VPN tunnel without starting WDA or phone actions.
    func checkConnection() {
        guard !checking, !importing, hasPairing, !engine.busy, !engine.deviceConnectionBusy,
              !engine.hasPreparedPhoneConnection else { return }
        checking = true; connectionVerified = false; connectionStatus = "正在验证配对与 VPN…"
        let connection = generation
        Task {
            defer { checking = false }
            do {
                try await engine.checkPhoneConnection()
                guard generation == connection else { return }
                connectionVerified = true
                connectionStatus = "配对与 VPN 连接正常"
                status = backend == .ddi ? "连接检查通过；首次手机操作将检查开发者模式和 DDI 服务。" : "连接检查通过；Automation 安装、开发者模式及首次 XCTest 授权仍需完成。"
            } catch {
                guard generation == connection else { return }
                connectionStatus = "连接未通过"
                status = error.localizedDescription
            }
        }
    }
}
