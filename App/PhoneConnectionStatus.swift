import Foundation
import Network

enum PhoneConnectionDiagnosticContext: String {
    case deviceSetup = "device_setup"
    case activeTurn = "active_turn"
}

/// The default network path is useful context, not a test of the local VPN.
/// In particular, an unsatisfied default path can still carry our RP tunnel.
struct PhoneNetworkPath {
    var status = "unknown"
    var wifi = false
    var cellular = false
    var other = false
    var expensive = false
    var constrained = false

    init() {}
    init(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires_connection"
        @unknown default: status = "unknown"
        }
        wifi = path.usesInterfaceType(.wifi)
        cellular = path.usesInterfaceType(.cellular)
        other = path.usesInterfaceType(.other)
        expensive = path.isExpensive
        constrained = path.isConstrained
    }

    var description: String {
        let interfaces = [(wifi, "Wi-Fi"), (cellular, "蜂窝"), (other, "其他接口")]
            .filter { $0.0 }.map { $0.1 }.joined(separator: "、")
        let state: String
        switch status {
        case "satisfied": state = "可用"
        case "unsatisfied": state = "不可用"
        case "requires_connection": state = "等待连接"
        default: state = "正在获取"
        }
        return interfaces.isEmpty ? "默认网络路径：\(state)" : "默认网络路径：\(interfaces)（\(state)）"
    }

    /// No interface names, addresses, device identifiers or pairing content.
    var diagnosticFields: [String: Any] {
        ["networkPath": status, "usesWiFi": wifi, "usesCellular": cellular,
         "usesOtherInterface": other, "isExpensive": expensive, "isConstrained": constrained]
    }
}

/// Translate a tunnel error without persisting the native message, which may
/// contain local addresses. Only the known initial TCP error identifies that stage.
struct PhoneConnectionFailure: LocalizedError {
    let stage: String
    let kind: String
    let nativeCode: String?
    let path: PhoneNetworkPath

    init(_ error: any Error, path: PhoneNetworkPath) {
        let message = error.localizedDescription
        self.path = path
        let initialConnect = message.contains("connect:")
        stage = initialConnect ? "initial_tcp_connect" : "rp_tunnel_handshake"
        if initialConnect && message.contains("ConnectionRefused") { kind = "connection_refused" }
        else if initialConnect && message.contains("NoRouteToHost") { kind = "no_route" }
        else { kind = "tunnel_failed" }
        if let range = message.range(of: #"idevice [0-9]+/[0-9]+"#, options: .regularExpression) {
            nativeCode = String(message[range])
        } else { nativeCode = nil }
    }

    var errorDescription: String? {
        let stageText = stage == "initial_tcp_connect" ? "初始 TCP 连接" : "RP 配对与隧道连接"
        let reason = kind == "connection_refused" ? "本机 VPN 的初始连接被拒绝" : "本机 VPN 隧道未能建立"
        let code = nativeCode.map { "；\($0)" } ?? ""
        return "\(reason)（阶段：\(stageText)；\(path.description)\(code)）。请保持手机解锁、LocalDevVPN 已连接。如果只在蜂窝网络下失败，请在设置 → 手机操作配置中临时关闭蜂窝数据、断开 Wi-Fi，再点“准备蜂窝模式连接”；成功后开回蜂窝数据，再发送新消息。"
    }

    var diagnosticFields: [String: Any] {
        var fields = path.diagnosticFields
        fields["connectionStage"] = stage
        fields["connectionError"] = kind
        if let nativeCode { fields["nativeErrorCode"] = nativeCode }
        return fields
    }
}
