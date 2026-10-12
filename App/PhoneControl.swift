import Foundation
import PocketAgentNative
import UIKit

/// The executor owns tool policy and snapshots; these backends only perform
/// primitive observations/effects under that same serial action lock.
@MainActor
protocol PhoneControl: AnyObject {
    var cancellationCheck: (() throws -> Void)? { get set }
    func prepare() async throws
    func activeApp() async throws -> String
    func readTree() async throws -> PhoneTree
    func screenshot() async throws -> Data
    func activate(_ bundle: String) async throws
    func tap(_ x: Double, _ y: Double, seconds: Double?) async throws
    func drag(_ x: Double, _ y: Double, _ toX: Double, _ toY: Double, seconds: Double) async throws
    func input(_ node: [String: String]) async throws -> PhoneInput
    func click(_ input: PhoneInput) async throws
    func clear(_ input: PhoneInput) async throws
    func prepareText(_ text: String) async throws
    func type(_ text: String, into input: PhoneInput) async throws
    func key(_ name: String) async throws
    func dismissKeyboard() async throws
    func home() async throws
}
enum PhoneInput {
    case wda(String)
    case ddi(rect: CGRect, identity: String)
}

@MainActor
final class WDAControl: PhoneControl {
    let model: Model
    var base: String?
    var cancellationCheck: (() throws -> Void)?
    init(_ model: Model) { self.model = model }
    func prepare() async throws { if base == nil { base = try await model.prepareWDA() } }
    private var session: String { base ?? "" }
    func activeApp() async throws -> String {
        (try await model.request("GET", "\(session)/wda/activeAppInfo")["value"] as? [String: Any])?["bundleId"] as? String ?? ""
    }
    func readTree() async throws -> PhoneTree {
        let raw = try await model.request("GET", "\(session)/source")["value"] as? String ?? ""
        let tree = PhoneTree(), parser = XMLParser(data: Data(raw.utf8)); parser.delegate = tree
        guard parser.parse(), tree.frame.width > 0 else { throw failure("无法读取当前界面树。") }
        return tree
    }
    func screenshot() async throws -> Data {
        let text = try await model.request("GET", "/screenshot")["value"] as? String ?? ""
        guard let data = Data(base64Encoded: text) else { throw failure("截屏失败。") }; return data
    }
    private func effect(_ path: String, _ body: [String: Any]) async throws {
        try cancellationCheck?(); _ = try await model.request("POST", path, body)
    }
    func activate(_ bundle: String) async throws { try await effect("\(session)/wda/apps/activate", ["bundleId": bundle]) }
    func tap(_ x: Double, _ y: Double, seconds: Double?) async throws {
        var body: [String: Any] = ["x": x, "y": y]
        if let seconds { body["duration"] = seconds }
        try await effect("\(session)/wda/\(seconds == nil ? "tap" : "touchAndHold")", body)
    }
    func drag(_ x: Double, _ y: Double, _ toX: Double, _ toY: Double, seconds: Double) async throws {
        try await effect("\(session)/wda/dragfromtoforduration", ["fromX": x, "fromY": y, "toX": toX, "toY": toY, "duration": seconds])
    }
    func input(_ a: [String: String]) async throws -> PhoneInput {
        let name = a["name"].map { "@name=\(PhoneExecutor.xpathLiteral($0)) and " } ?? ""
        let xpath = "//\(a["type"]!)[\(name)@x=\(PhoneExecutor.xpathLiteral(a["x"] ?? "")) and @y=\(PhoneExecutor.xpathLiteral(a["y"] ?? ""))]"
        let found = try await model.request("POST", "\(session)/element", ["using": "xpath", "value": xpath])["value"] as? [String: Any]
        guard let id = found?["element-6066-11e4-a52e-4f735466cecf"] as? String else { throw PhoneObservationIssue.nodeChanged }
        return .wda(id)
    }
    private func element(_ input: PhoneInput) throws -> String {
        guard case .wda(let id) = input else { throw failure("输入目标与后端不匹配。") }; return "\(session)/element/\(id)"
    }
    func click(_ input: PhoneInput) async throws { try await effect(try element(input) + "/click", [:]) }
    func clear(_ input: PhoneInput) async throws { try await effect(try element(input) + "/clear", [:]) }
    func prepareText(_ text: String) async throws {}
    func type(_ text: String, into input: PhoneInput) async throws { try await effect(try element(input) + "/value", ["text": text]) }
    func key(_ name: String) async throws { try await effect("\(session)/wda/keys", ["value": [name == "return" ? "\n" : "\u{8}"]]) }
    func dismissKeyboard() async throws { try await effect("\(session)/wda/keyboard/dismiss", [:]) }
    func home() async throws { try await effect("/wda/homescreen", [:]) }
}

@MainActor
final class DDIControl: PhoneControl {
    let model: Model
    var cancellationCheck: (() throws -> Void)?
    private var observedFrame: CGRect?
    private var observedApp: String?
    private var preparedText: String?
    init(_ model: Model) { self.model = model }
    func prepare() async throws { try await model.prepareDDI() }
    private func call(_ object: [String: Any]) async throws -> [String: Any] {
        guard let device = model.connection, let handle = device.ddi, let cancel = device.ddiCancellation else { throw failure("DDI 连接尚未准备。") }
        try cancellationCheck?()
        pocket_ddi_reset_cancel(cancel)
        // Lease revocation/Stop is observed during a native await as well as
        // between primitives. Await the worker and its input cleanup fully.
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                do { try cancellationCheck?() }
                catch { pocket_ddi_cancel(cancel); return }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { watcher.cancel() }
        var requestObject = object
        if ["tap", "hold", "drag", "clear", "paste", "key"].contains(object["op"] as? String ?? "") {
            if let observedApp { requestObject["expected_app"] = observedApp }
            if let frame = observedFrame { requestObject["expected_frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height] }
        }
        let data = try JSONSerialization.data(withJSONObject: requestObject)
        let request = String(decoding: data, as: UTF8.self)
        let result: Data
        do { result = try await model.ffi {
            var result: UnsafeMutablePointer<CChar>?
            try request.withCString { try check(pocket_ddi_call(handle, $0, &result)) }
            guard let result else { throw failure("DDI 返回为空。") }
            defer { idevice_string_free(result) }
            return Data(String(cString: result).utf8)
        } } catch {
            if error.localizedDescription.contains("AX foreground or root changed") { throw PhoneObservationIssue.foregroundChanged }
            // The device can refuse attributes with error 8 during a UI transition.
            // The executor retries only observation, after the old AX socket closes.
            if ["snapshot", "foreground"].contains(object["op"] as? String ?? ""),
               error.localizedDescription.contains("AX request type"),
               error.localizedDescription.contains("refused: 8") { throw PhoneObservationIssue.foregroundChanged }
            if error.localizedDescription.contains("DDI display changed") { throw PhoneObservationIssue.geometryChanged }
            let operation = object["op"] as? String ?? "request"
            throw failure("DDI \(operation)：\(error.localizedDescription)")
        }
        try cancellationCheck?()
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw failure("DDI 返回格式无效。") }
        return object
    }
    func activeApp() async throws -> String { try await call(["op": "foreground"])["app"] as? String ?? "" }
    func readTree() async throws -> PhoneTree {
        let result = try await call(["op": "snapshot"])
        let tree = PhoneTree()
        guard let frame = result["frame"] as? [String: Double], let raw = result["nodes"] as? [[String: Any]] else { throw failure("DDI 界面树缺少坐标。") }
        tree.bundleID = result["app"] as? String
        tree.frame = CGRect(x: frame["x"] ?? 0, y: frame["y"] ?? 0, width: frame["width"] ?? 0, height: frame["height"] ?? 0)
        tree.nodes = try raw.compactMap { try DDINodeMapping.attributes($0) }
        observedFrame = tree.frame; observedApp = tree.bundleID
        guard tree.frame.width > 0, tree.frame.height > 0 else { throw failure("DDI 屏幕尺寸无效。") }
        return tree
    }
    func screenshot() async throws -> Data {
        guard let device = model.connection, let handle = device.ddi else { throw failure("DDI 连接尚未准备。") }
        try cancellationCheck?()
        let result: Data = try await model.ffi {
            var bytes: UnsafeMutablePointer<UInt8>?, count: UInt = 0
            try check(pocket_ddi_screenshot(handle, &bytes, &count))
            guard let bytes, count > 0 else { throw failure("DDI 截图为空。") }
            defer { pocket_ddi_bytes_free(bytes, count) }
            return Data(bytes: bytes, count: Int(count))
        }
        try cancellationCheck?(); return result
    }
    func activate(_ bundle: String) async throws { _ = try await call(["op": "activate", "bundle_id": bundle]) }
    func tap(_ x: Double, _ y: Double, seconds: Double?) async throws { _ = try await call(["op": seconds == nil ? "tap" : "hold", "x": x, "y": y, "seconds": seconds ?? 0.05]) }
    func drag(_ x: Double, _ y: Double, _ toX: Double, _ toY: Double, seconds: Double) async throws {
        _ = try await call(["op": "drag", "x": x, "y": y, "to_x": toX, "to_y": toY, "seconds": seconds])
    }
    func input(_ node: [String: String]) async throws -> PhoneInput {
        guard let identity = node["ddi_identity"] else { throw PhoneObservationIssue.nodeChanged }
        return .ddi(rect: PhoneTree.rect(node), identity: identity)
    }
    func click(_ input: PhoneInput) async throws {
        guard case .ddi(let rect, _) = input, !rect.isEmpty else { throw PhoneObservationIssue.nodeChanged }
        try await tap(rect.midX, rect.midY, seconds: nil)
    }
    func clear(_ input: PhoneInput) async throws {
        guard case .ddi(_, let identity) = input else { throw PhoneObservationIssue.nodeChanged }
        _ = try await call(["op": "clear"])
        try await Task.sleep(for: .milliseconds(100))
        try cancellationCheck?()
        let tree = try await readTree()
        guard let field = tree.nodes.first(where: { $0["ddi_identity"] == identity }) else { throw PhoneObservationIssue.nodeChanged }
        guard let value = field["ddi_value"] ?? field["value"] else {
            throw failure("清空请求已发出，但输入框未提供可核实的值；未继续粘贴。请读取实际页面，不要重放输入。")
        }
        guard value.isEmpty || value == field["placeholder"] else {
            throw failure("清空请求已发出，但输入框仍有文字；未继续粘贴。请读取实际页面，不要重放输入。")
        }
    }
    func prepareText(_ text: String) async throws {
        try cancellationCheck?()
        guard text.count <= 4000 else { throw failure("输入文字超过限制。") }
        preparedText = nil
        if !text.isEmpty {
            // Device-side clipboard service writes UTF-8 without foregrounding
            // the assistant. Exact readback completes before any field is cleared.
            _ = try await call(["op": "clipboard_set", "text": text])
            try cancellationCheck?()
            preparedText = text
        }
    }
    func type(_ text: String, into input: PhoneInput) async throws {
        try cancellationCheck?()
        if !text.isEmpty {
            guard preparedText == text else {
                throw failure("准备后的剪贴板已变化或不可核实；未发送粘贴。请重新观察，不要重放输入。")
            }
            _ = try await call(["op": "clipboard_verify", "text": text])
            _ = try await call(["op": "paste"])
        }
        preparedText = nil
    }
    func key(_ name: String) async throws { _ = try await call(["op": "key", "key": name]) }
    func dismissKeyboard() async throws { _ = try await call(["op": "key", "key": "escape"]) }
    func home() async throws { _ = try await call(["op": "home"]) }
}
