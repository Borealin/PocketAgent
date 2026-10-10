import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var providers: ProviderStore
    @ObservedObject var sync: SyncCoordinator
    @ObservedObject var device: DeviceSettingsModel
    let close: () -> Void
    @State private var pickingFolder = false
    @State private var importingPairing = false
    @State private var pickingDefault = false

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    NavigationLink { ProviderListView(store: providers) } label: {
                        LabeledContent("模型服务", value: "\(providers.providers.count) 个")
                    }.accessibilityIdentifier("manageProviders")
                    Button { pickingDefault = true } label: {
                        LabeledContent("新会话默认模型", value: providers.describe(providers.defaultSelection).label)
                    }.accessibilityIdentifier("defaultModel")
                }
                Section {
                    LabeledContent("文件夹", value: sync.folderName ?? "未选择")
                    Button(sync.folderName == nil ? "选择 iCloud Drive 文件夹…" : "更换文件夹…") { pickingFolder = true }
                        .accessibilityIdentifier("chooseSyncFolder")
                    Button(sync.syncing ? "正在同步…" : "立即同步") { Task { await sync.syncNow() } }
                        .disabled(sync.syncing || sync.folderName == nil).accessibilityIdentifier("syncNow")
                    Text(sync.status).font(.caption).accessibilityIdentifier("syncStatus")
                    if sync.folderName != nil { Button("停止同步", role: .destructive) { sync.disconnect() } }
                } header: { Text("iCloud Drive 同步") } footer: {
                    Text("只同步会话文字、工具调用结果和服务商的非机密配置。API Key、配对文件、草稿、运行状态、日志、截图和附件不会同步；同步来的会话不会自动执行。")
                }
                Section {
                    LabeledContent("配对文件", value: device.hasPairing ? "已导入" : "未导入")
                    Button("导入配对文件…") { importingPairing = true }.accessibilityIdentifier("importPairing")
                } header: { Text("设备配对") } footer: { Text("RP 配对文件只保存在本机，受文件保护且不进入备份。") }
                Section {
                    TextField("WDA Runner（默认 \(DeviceSettings.runnerBundleID)）", text: $device.runner)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("VPN 隧道（默认 \(DeviceSettings.tunnelEndpointText)）", text: $device.tunnel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                    Toggle("保存诊断日志", isOn: $device.saveLogs).accessibilityIdentifier("diagnosticLogs")
                    Toggle("保存诊断截图", isOn: $device.saveScreenshots).accessibilityIdentifier("diagnosticScreenshots")
                    Button("保存设备设置") { device.save() }.accessibilityIdentifier("saveDeviceSettings")
                    if !device.status.isEmpty { Text(device.status).font(.caption) }
                } header: { Text("手机自动化") } footer: {
                    Text("留空使用默认值。诊断日志和截图默认关闭，开启后仅保存在本机；日志只含事件、计数和 ID，不含消息、工具参数、结果或 Key。原生连接日志在下次启动后生效。")
                }
            }.navigationTitle("设置")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: close).accessibilityIdentifier("closeSettings") } }
                .sheet(isPresented: $pickingFolder) {
                    FolderPicker { url in pickingFolder = false; sync.chooseFolder(url) }
                }
                .sheet(isPresented: $pickingDefault) {
                    ModelPickerSheet(providers: providers, current: providers.defaultSelection, title: "新会话默认模型",
                                     offersDefault: false) { selection, _ in
                        providers.setDefault(selection); pickingDefault = false
                    }
                }
                .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.propertyList, .xml]) { result in
                    device.importPairing(result)
                }
        }
    }
}
