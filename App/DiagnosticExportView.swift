import SwiftUI
import UIKit

/// Produces a local snapshot before handing its file URL to system sharing.
struct DiagnosticExportView: View {
    let scope: DiagnosticExportScope
    var conversationState: ChatState? = nil
    @State private var result: DiagnosticExportResult?
    @State private var preparing = false
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                Text(scope == .recent ? "近期诊断" : "当前会话诊断")
                Text("包含版本、系统、执行阶段和错误代码等诊断信息。不会导出对话正文、模型回复、截图、API Key 或配对文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if preparing {
                    ProgressView("正在准备诊断包…")
                } else if let result {
                    LabeledContent("运行日志", value: "\(result.runCount) 份")
                    LabeledContent("诊断事件", value: "\(result.eventCount) 条")
                    if result.eventCount == 0 {
                        Text("没有可用日志。请在设置 → 手机操作配置 → 高级设备设置中开启“保存诊断日志”，保存后重启 App，重现问题再导出。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if scope != .recent {
                        Text("只包含此版本以后、开启日志时产生且能关联到本会话的运行记录。旧版本的问题可从设置导出近期诊断。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if result.truncated || result.skippedCount > 0 {
                        Text("部分记录因数量、大小限制、不完整或无法识别而未包含。达到目录扫描上限时可能遗漏最新运行，详情见诊断包。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ShareLink(item: result.url) {
                        Label("分享诊断包", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("shareDiagnostics")
                } else if failed {
                    Text("无法生成诊断包，请检查本机可用空间后重试。")
                        .foregroundStyle(.orange).accessibilityIdentifier("diagnosticsExportError")
                }
                Button(result == nil ? "重试" : "重新生成", action: prepare)
                    .disabled(preparing).accessibilityIdentifier("regenerateDiagnostics")
            } footer: {
                Text("诊断包只在本机生成。点分享后可存储到“文件”或自行发送；生成后的新事件需要重新生成。日志默认关闭，导出不会开启日志或执行手机操作。")
            }
        }
        .navigationTitle("导出诊断包")
        .task { if result == nil && !failed { prepare() } }
    }

    private func prepare() {
        guard !preparing else { return }
        preparing = true; failed = false
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let output = manager.temporaryDirectory
        let scope = scope, context = context()
        Task {
            do {
                let exported = try await Task.detached(priority: .utility) {
                    try DiagnosticBundle.create(documents: documents, applicationSupport: support,
                                                outputDirectory: output, scope: scope, context: context)
                }.value
                result = exported
            } catch { result = nil; failed = true }
            preparing = false
        }
    }

    /// Generic environment values only; no device, scene, signing or provider identity.
    private func context() -> DiagnosticExportContext {
        let bundle = Bundle.main
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let permitted = bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        var context = DiagnosticExportContext(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            systemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceFamily: UIDevice.current.userInterfaceIdiom == .phone ? "phone" : UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "other",
            currentBackend: DeviceSettings.phoneBackend.rawValue,
            loggingEnabled: DeviceSettings.diagnosticsEnabled,
            backgroundTaskNamespaceMatches: bundle.bundleIdentifier.map { permitted.contains("\($0).run.*") } ?? false,
            conversationState: conversationState?.rawValue)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let window = scene.windows.first(where: \.isKeyWindow) {
            context.windowWidth = Double(window.bounds.width)
            context.windowHeight = Double(window.bounds.height)
            context.displayScale = Double(window.traitCollection.displayScale)
            switch scene.effectiveGeometry.interfaceOrientation {
            case .portrait: context.orientation = "portrait"
            case .portraitUpsideDown: context.orientation = "portraitUpsideDown"
            case .landscapeLeft: context.orientation = "landscapeLeft"
            case .landscapeRight: context.orientation = "landscapeRight"
            default: context.orientation = "unknown"
            }
        }
        return context
    }
}
