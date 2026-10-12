import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Local display preference (UserDefaults); never synchronized.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let storageKey = "appearance"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    /// `.unspecified` hands appearance back to the system.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @ObservedObject var engine: Model
    @ObservedObject var providers: ProviderStore
    @ObservedObject var sync: SyncCoordinator
    @ObservedObject var device: DeviceSettingsModel
    @ObservedObject var workspaces: WorkspaceStore
    let close: () -> Void
    @State private var pickingFolder = false
    @State private var initializeSyncFolder = false
    @State private var pickingDefault = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("外观", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearance")
                } header: { Text("外观") } footer: { Text("只保存在本机，不会同步。") }
                Section("模型") {
                    NavigationLink { ProviderListView(store: providers) } label: {
                        LabeledContent("模型服务", value: "\(providers.providers.count) 个")
                    }.accessibilityIdentifier("manageProviders")
                    Button { pickingDefault = true } label: {
                        LabeledContent("新会话默认模型", value: providers.describe(providers.defaultSelection).label)
                    }.accessibilityIdentifier("defaultModel")
                }
                RulesSettingsSection(store: workspaces)
                ScriptEnvironmentSection()
                Section {
                    LabeledContent(sync.isConfigured ? "同步位置" : "默认文件夹", value: sync.folderName ?? "iCloud Drive / PocketAgent")
                    if !sync.isConfigured {
                        Button {
                            initializeSyncFolder = true; pickingFolder = true
                        } label: { Label("启用 iCloud 同步", systemImage: "icloud") }
                            .accessibilityIdentifier("initializeSyncFolder")
                            .disabled(sync.connecting)
                        Text("在 iCloud Drive 选择一次位置，自动创建 PocketAgent 文件夹。以后打开 App 自动同步。选择“我的 iPhone”等本地目录不会跨设备同步。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(sync.isConfigured ? "更改同步位置…" : "使用已有同步文件夹…") {
                        initializeSyncFolder = false; pickingFolder = true
                    }.accessibilityIdentifier("chooseSyncFolder").disabled(sync.connecting)
                    Button(sync.syncing ? "正在同步…" : "立即同步") { Task { await sync.syncNow() } }
                        .disabled(sync.syncing || sync.connecting || !sync.isConfigured).accessibilityIdentifier("syncNow")
                    Text(sync.status).font(.caption).accessibilityIdentifier("syncStatus")
                    if sync.folderName != nil { Button("停止同步", role: .destructive) { sync.disconnect() } }
                } header: { Text("iCloud Drive 同步") } footer: {
                    Text("跨设备同步请选择 iCloud Drive，并在其他设备选同一个 PocketAgent 文件夹。本地目录不会跨设备同步。只同步会话文字、工具调用结果、服务商的非机密配置和图片的存在信息。API Key、配对文件、草稿、运行状态、日志、截图和图片内容不会同步，其他设备上的图片显示为不可用；同步来的会话不会自动执行。")
                }
                Section {
                    NavigationLink {
                        PhoneSetupView(engine: engine, device: device)
                    } label: {
                        LabeledContent("手机操作配置", value: engine.hasPreparedPhoneConnection ? "连接已保留" : device.connectionVerified ? "连接已验证" : device.hasPairing ? "待检查连接" : "待导入配对文件")
                    }.accessibilityIdentifier("phoneSetup")
                } header: { Text("手机操作") }
            }.navigationTitle("设置")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: close).accessibilityIdentifier("closeSettings") } }
                .sheet(isPresented: $pickingFolder) {
                    FolderPicker(title: initializeSyncFolder ? "在 iCloud Drive 选择位置" : "选择已有同步文件夹") { url in
                        pickingFolder = false
                        sync.chooseFolder(url, initializeDefault: initializeSyncFolder)
                    }
                }
                .sheet(isPresented: $pickingDefault) {
                    ModelPickerSheet(providers: providers, current: providers.defaultSelection, title: "新会话默认模型",
                                     offersDefault: false) { selection, _ in
                        providers.setDefault(selection); pickingDefault = false
                    }
                }
        }
    }
}

struct ScriptEnvironmentSection: View {
    @State private var readiness = ScriptRuntime.shared.readiness
    var body: some View {
        Section {
            HStack {
                if readiness.busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: readiness == .ready ? "checkmark.circle.fill" : "terminal")
                        .foregroundStyle(readiness == .ready ? .green : .secondary)
                }
                Text(readiness.title).accessibilityIdentifier("runtimeStatus")
            }
            Text("Bash · Python 3 · Node.js").font(.caption).foregroundStyle(.secondary)
            if readiness == .idle || readiness == .started {
                Button("准备并检查环境") { Task { try? await ScriptRuntime.shared.checkTools() } }
                    .accessibilityIdentifier("prepareRuntime")
            }
            if case .failed(let reason) = readiness {
                Text(reason).font(.caption).foregroundStyle(.orange)
                Text("关闭 App 后重新打开会自动检查；聊天记录不会删除。").font(.caption)
            }
        } header: { Text("脚本环境") } footer: {
            Text("随 App 提供，在本机自动初始化，无需下载或开启 JIT。选定会话项目后，脚本可读写项目文件并通过手机工具执行操作。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .scriptReadinessChanged).receive(on: DispatchQueue.main)) { _ in
            readiness = ScriptRuntime.shared.readiness
        }
        .task {
            readiness = ScriptRuntime.shared.readiness
            try? await ScriptRuntime.shared.checkTools()
            readiness = ScriptRuntime.shared.readiness
        }
    }
}

struct PhoneSetupView: View {
    @ObservedObject var engine: Model
    @ObservedObject var device: DeviceSettingsModel
    @State private var importingPairing = false
    @State private var showAdvanced = false
    var body: some View {
        Form {
            Section {
                Picker("控制方式", selection: $device.backend) {
                    Text("DDI（默认）").tag(PhoneBackendKind.ddi)
                    Text("WDA").tag(PhoneBackendKind.wda)
                }.disabled(settingsBusy).accessibilityIdentifier("phoneControlBackend")
                    .onChange(of: device.backend) { device.saveBackend() }
                Text(device.backend == .ddi
                    ? "DDI 直接使用开发服务，无需 Automation。开启 iOS 设置 → 隐私与安全性 → 开发者模式。"
                    : "在 SideStore / AltStore 中同时安装主 App 和 Automation，保持版本一致。开启 iOS 设置 → 隐私与安全性 → 开发者模式。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("打开安装说明", destination: URL(string: "https://github.com/Borealin/PocketAgent#installation")!)
            } header: { Text("首次配置") }
            Section {
                Label("连接 LocalDevVPN", systemImage: "2.circle")
                Text("打开 LocalDevVPN，点 Connect 并允许添加 VPN。运行手机操作期间保持连接，手机保持解锁。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Label(device.hasPairing ? "RP 配对文件已导入" : "导入这台 iPhone 的 RP 配对文件",
                      systemImage: device.hasPairing ? "checkmark.circle.fill" : "3.circle")
                Button(device.importing ? "正在校验…" : device.hasPairing ? "更换配对文件…" : "从“文件”导入配对文件…") {
                    importingPairing = true
                }.disabled(settingsBusy).accessibilityIdentifier("importPairing")
                NavigationLink("配对文件从哪里获取？") { PairingGuideView() }
            } footer: {
                Text("请选择 rp_pairing_file.plist。SideStore 的 USB 配对文件不是同一种文件。只保存在本机，不进入 iCloud 或备份。")
            }
            Section {
                Button { device.checkConnection() } label: {
                    HStack {
                        if device.checking { ProgressView().controlSize(.small) }
                        Label(device.checking ? "正在检查…" : "检查连接", systemImage: "network")
                    }
                }.disabled(settingsBusy || engine.hasPreparedPhoneConnection || !device.hasPairing)
                    .accessibilityIdentifier("checkDeviceConnection")
                Label(device.connectionStatus, systemImage: device.connectionVerified ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption).accessibilityIdentifier("deviceConnectionStatus")
                if !device.status.isEmpty { Text(device.status).font(.caption).accessibilityIdentifier("deviceSetupStatus") }
            } footer: {
                Text(device.backend == .ddi
                    ? "检查已保存设置下的配对与 VPN，结束即释放连接，不会打开其他 App。DDI 无需 XCTest 授权；输入文字会替换系统剪贴板并模拟粘贴，不会切回本 App。目标 App 可能提示粘贴许可。"
                    : "检查已保存设置下的配对与 VPN，结束即释放连接，不会打开其他 App。首次运行手机操作时，iOS 可能要求输入解锁密码以启用 XCTest。")
            }
            Section {
                Text("1. 临时关闭蜂窝数据，并断开 Wi-Fi；保持 LocalDevVPN 连接和手机解锁。\n2. 点下面的准备按钮，等待连接已保留。\n3. 开回蜂窝数据，回到聊天发送新消息。")
                    .font(.caption).foregroundStyle(.secondary)
                Button { engine.prepareCellularConnection() } label: {
                    HStack {
                        if engine.preparingPhoneConnection { ProgressView().controlSize(.small) }
                        Label(engine.preparingPhoneConnection ? "正在准备…" : "准备蜂窝模式连接", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }.disabled(settingsBusy || !device.hasPairing)
                    .accessibilityIdentifier("prepareCellularConnection")
                Text(engine.phonePreparationStatus).font(.caption)
                    .accessibilityIdentifier("phonePreparationStatus")
                if let expiry = engine.preparedConnectionExpiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("剩余 \(max(0, Int(expiry.timeIntervalSince(context.date)))) 秒；系统可能提前结束保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("释放已准备连接") { engine.releasePreparedPhoneConnection() }
                        .accessibilityIdentifier("releasePreparedConnection")
                }
                Text(engine.networkPath.description).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("phoneNetworkPath")
            } header: { Text("蜂窝连接恢复") } footer: {
                Text("用于蜂窝开启时无法建立初始连接的情况。只建立并短暂保留 RP 隧道，下一次手机操作才会启动所选控制后端；不会自动执行或重试手机操作。默认网络路径状态不代表 VPN 是否可用。")
            }
            Section {
                DisclosureGroup("高级设备设置", isExpanded: $showAdvanced) {
                    TextField("Automation Bundle ID", text: $device.runner)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("runnerBundleID")
                    Text("留空自动匹配已安装的 Automation").font(.caption).foregroundStyle(.secondary)
                    TextField("VPN 地址:端口", text: $device.tunnel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("tunnelEndpoint")
                    Text("留空使用 \(DeviceSettings.embeddedTunnelEndpoint)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("tunnelEndpointDefaultHint")
                    Toggle("保存诊断日志", isOn: $device.saveLogs).accessibilityIdentifier("diagnosticLogs")
                    Toggle("保存诊断截图", isOn: $device.saveScreenshots).accessibilityIdentifier("diagnosticScreenshots")
                    Button("保存设备设置") { device.save() }.disabled(settingsBusy)
                        .accessibilityIdentifier("saveDeviceSettings")
                }
            } footer: {
                Text("自动匹配侧载签名后的 Automation；仅在自动匹配失败时手动填写 Bundle ID。诊断默认关闭，只保存在本机；原生日志开关在下次启动后生效。")
            }
        }.navigationTitle("手机操作配置").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.data]) { device.importPairing($0) }
    }
    private var settingsBusy: Bool {
        device.checking || device.importing || engine.busy || engine.deviceConnectionBusy
    }
}

struct PairingGuideView: View {
    private let command = "idevice-tools remotepairing_lockdown pair PocketAgent rp_pairing_file.plist"
    var body: some View {
        List {
            Section {
                Text("已有 RP 文件") .font(.headline)
                Text("把这台 iPhone 对应的 rp_pairing_file.plist 用 AirDrop 或其他方式存到“文件”App，再回到上一页点“从文件导入”。文件名可以不同，导入时会校验内容。")
            }
            Section {
                Text("首次生成") .font(.headline)
                Text("首次需要电脑通过 USB 与这台 iPhone 建立 RP 配对。解锁手机、信任电脑，并使用包含 remotepairing_lockdown 的 idevice-tools 版本运行：")
                Text(command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button("复制电脑命令") { UIPasteboard.general.string = command }
                Link("idevice-tools 项目与安装说明", destination: URL(string: "https://github.com/jkcoxson/idevice")!)
                Text("生成后传到手机并导入。之后的聊天、脚本和手机操作可在手机上运行；配对文件不要分享给他人。")
            }
            Section {
                Text("SideStore / Jitterbug 导出的 .mobiledevicepairing 或包含 HostCertificate 的 USB 配对文件不能直接代替 RP 文件。导入成功只表示格式有效，是否属于这台手机由“检查连接”验证。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("导入配对文件").navigationBarTitleDisplayMode(.inline)
    }
}
