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
    static var tunnelEndpointText: String {
        nonEmpty(UserDefaults.standard.string(forKey: tunnelKey))
            ?? nonEmpty(Bundle.main.object(forInfoDictionaryKey: "PocketAgentTunnelEndpoint") as? String)
            ?? defaultTunnelEndpoint
    }
    static var assistantBundleID: String { Bundle.main.bundleIdentifier ?? "" }
    /// Off by default; screenshots may contain personal screen content.
    static var saveScreenshots: Bool { UserDefaults.standard.bool(forKey: screenshotsKey) }
    /// Off by default: no run log or native idevice log file is written.
    static var saveDiagnosticLogs: Bool { UserDefaults.standard.bool(forKey: logsKey) }

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

    func save() {
        do {
            try DeviceSettings.save(runner: runner, tunnel: tunnel, screenshots: saveScreenshots, logs: saveLogs)
            generation += 1
            connectionVerified = false; connectionStatus = "设置已更改，请检查连接"
            status = "已保存。"
        }
        catch { status = error.localizedDescription }
    }

    func importPairing(_ result: Result<URL, any Error>) {
        guard !importing, !checking else { return }
        importing = true
        Task {
            defer { importing = false }
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
        guard !checking, !importing, hasPairing else { return }
        checking = true; connectionVerified = false; connectionStatus = "正在验证配对与 VPN…"
        let connection = generation
        Task {
            defer { checking = false }
            do {
                try await runOnFFIThread {
                    let device = DeviceConnection()
                    try device.connect()
                    // The local connection is released when this scope ends.
                }
                guard generation == connection else { return }
                connectionVerified = true
                connectionStatus = "配对与 VPN 连接正常"
                status = "连接检查通过；Automation 安装、开发者模式及首次 XCTest 授权仍需完成。"
            } catch {
                guard generation == connection else { return }
                connectionStatus = "连接未通过"
                status = "请确认手机已解锁、LocalDevVPN 已连接、配对文件属于这台手机。\n\(error.localizedDescription)"
            }
        }
    }
}
