import Foundation
import PocketAgentNative
import UIKit

/// The executor owns tool policy and snapshots; these backends only perform
/// primitive observations/effects under that same serial action lock.
@MainActor
protocol PhoneControl: AnyObject {
    var cancellationCheck: (() throws -> Void)? { get set }
    /// Seconds the next native call may take, or nil when the turn cannot
    /// afford one (DDI only; set beside `cancellationCheck`).
    var budget: (() -> TimeInterval?)? { get set }
    func prepare() async throws
    func activeApp() async throws -> String
    func readTree() async throws -> PhoneTree
    func screenshot() async throws -> Data
    func activate(_ bundle: String) async throws
    func tap(_ x: Double, _ y: Double, seconds: Double?) async throws
    func drag(_ x: Double, _ y: Double, _ toX: Double, _ toY: Double, seconds: Double) async throws
    /// Executor-internal swipe in the status band that compacts the system
    /// task surface; never reachable from a model tool.
    func compactSurface(fromX: Double, toX: Double, y: Double, seconds: Double) async throws
    func input(_ node: [String: String]) async throws -> PhoneInput
    func click(_ input: PhoneInput) async throws
    func clear(_ input: PhoneInput) async throws
    func prepareText(_ text: String) async throws
    func type(_ text: String, into input: PhoneInput) async throws
    func replaceTextAX(_ text: String, into input: PhoneInput) async throws
    func key(_ name: String) async throws
    func pressKeys(_ sequence: KeyboardSequence) async throws
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
    var budget: (() -> TimeInterval?)?
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
        try cancellationCheck?()
        if model.inputReleaseUnconfirmed { throw InputReleaseUnconfirmed() }
        _ = try await model.request("POST", path, body)
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
    func compactSurface(fromX: Double, toX: Double, y: Double, seconds: Double) async throws {
        try await drag(fromX, y, toX, y, seconds: seconds)
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
    func replaceTextAX(_ text: String, into input: PhoneInput) async throws { throw failure("AX 输入当前只支持 DDI。") }
    func key(_ name: String) async throws { try await effect("\(session)/wda/keys", ["value": [name == "return" ? "\n" : "\u{8}"]]) }
    func pressKeys(_ sequence: KeyboardSequence) async throws { throw failure("press_keys 当前只支持 DDI。") }
    func dismissKeyboard() async throws { try await effect("\(session)/wda/keyboard/dismiss", [:]) }
    func home() async throws { try await effect("/wda/homescreen", [:]) }
}

/// Releasing input held on the phone (touch, home, keyboard) could not be
/// confirmed earlier in this app run; no input is sent until PocketAgent is
/// relaunched. Raised before anything is sent.
struct InputReleaseUnconfirmed: LocalizedError {
    var errorDescription: String? {
        "此前一次手机输入的释放未能确认；为安全起见，本次运行中不再向手机发送输入（观察仍可用）。请先检查手机上没有被按住的触摸或按键，然后重新打开 PocketAgent。"
    }
}

@MainActor
final class DDIControl: PhoneControl {
    let model: Model
    var cancellationCheck: (() throws -> Void)?
    var budget: (() -> TimeInterval?)?
    private var observedFrame: CGRect?
    private var observedApp: String?
    private var preparedText: String?
    /// Local acceptance launch arguments (fault injection).
    private let stall = DeviceSettings.injectDDIStall
    private let dropReleaseConfirmation = DeviceSettings.dropInputReleaseConfirmation
    /// Operations that send input to the phone.
    static let inputOperations: Set<String> = ["tap", "hold", "drag", "surface_drag", "clear", "paste", "key", "keys",
                                               "ax_replace", "home"]
    init(_ model: Model) { self.model = model }
    func prepare() async throws { try await model.prepareDDI() }
    /// One native call on the turn's session. The expiry is fixed on the wall
    /// clock before the worker thread starts, so the handoff delay counts. The
    /// worker is always awaited to its end, cleanup included: there is no
    /// Swift-side timeout, and the connection outlives the call.
    private func native<T>(_ op: String, encode: (UInt64) throws -> String,
                           run: @escaping (OpaquePointer, String, UInt64) throws -> T) async throws -> T {
        guard let device = model.connection, let handle = device.ddi, let cancel = device.ddiCancellation else { throw failure("DDI 连接尚未准备。") }
        try cancellationCheck?()
        if Self.inputOperations.contains(op), model.inputReleaseUnconfirmed { throw InputReleaseUnconfirmed() }
        guard let seconds = budget?() else { throw failure("本轮剩余时间不足以安全执行手机操作；未执行。") }
        let expiresAt = DDICallBudget.expiry(now: Date(), seconds: seconds)
        let request = try encode(expiresAt)
        let seq = model.nextDDICallSequence()
        let started = ContinuousClock.now
        func elapsed() -> Int { Int((ContinuousClock.now - started) / .milliseconds(1)) }
        pocket_ddi_reset_cancel(cancel)
        model.log("ddi_call_enter", ["seq": seq, "op": op, "budgetMs": Int(seconds * 1000)])
        // Lease revocation/Stop is observed during a native await as well as
        // between primitives; progress is logged while the call is outstanding.
        let watcher = Task { @MainActor in
            var signalled = false, ticks = 0
            while !Task.isCancelled {
                if !signalled {
                    do { try cancellationCheck?() } catch {
                        pocket_ddi_cancel(cancel); signalled = true
                        model.log("ddi_cancel_signalled", ["seq": seq, "ms": elapsed()])
                    }
                }
                ticks += 1
                if ticks % 250 == 0 { model.log("ddi_call_outstanding", Self.progressFields(cancel, seq: seq, op: op, ms: elapsed())) }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { watcher.cancel() }
        let outcome: Result<T, any Error>
        do { outcome = .success(try await model.ffi { try run(handle, request, expiresAt) }) }
        catch { outcome = .failure(error) }
        var progress = PocketDDIProgress()
        _ = pocket_ddi_progress(cancel, &progress)
        if progress.input_unconfirmed { model.latchInputReleaseUnconfirmed(op: op) }
        var fields = Self.progressFields(cancel, seq: seq, op: op, ms: elapsed())
        switch outcome {
        case .success: fields["outcome"] = "ok"
        case .failure(let error):
            let text = error.localizedDescription
            fields["outcome"] = text.contains("DDI action cancelled") ? "cancelled"
                : text.contains("DDI call budget") ? "budget" : "error"
        }
        model.log("ddi_call_exit", fields)
        // The connection, and with it the native session and cancellation,
        // stays alive until the worker has returned.
        withExtendedLifetime(device) {}
        return try outcome.get()
    }
    private static func progressFields(_ cancel: OpaquePointer, seq: Int, op: String, ms: Int) -> [String: Any] {
        var p = PocketDDIProgress()
        guard pocket_ddi_progress(cancel, &p) else { return ["seq": seq, "op": op, "ms": ms] }
        return ["seq": seq, "op": op, "ms": ms, "nativeSeq": p.seq, "inCall": p.in_call, "stage": p.stage, "detail": p.detail,
                "stageAgeMs": p.stage_age_ms, "beats": p.beats, "beatAgeMs": p.beat_age_ms, "reconnects": p.reconnects,
                "inputUnconfirmed": p.input_unconfirmed]
    }
    private func call(_ object: [String: Any]) async throws -> [String: Any] {
        let op = object["op"] as? String ?? "request"
        var requestObject = object
        if ["tap", "hold", "drag", "surface_drag", "clear", "paste", "key", "keys", "ax_replace"].contains(op) {
            if let observedApp { requestObject["expected_app"] = observedApp }
            if let frame = observedFrame { requestObject["expected_frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height] }
        }
        if let stall, stall != "screenshot" { requestObject["diagnostic_stall"] = stall }
        if dropReleaseConfirmation { requestObject["diagnostic_release_unconfirmed"] = true }
        let result: Data
        do { result = try await native(op, encode: { expiresAt in
            requestObject["expires_at_ms"] = expiresAt
            return String(decoding: try JSONSerialization.data(withJSONObject: requestObject), as: UTF8.self)
        }) { handle, request, _ in
            var result: UnsafeMutablePointer<CChar>?
            try request.withCString { try check(pocket_ddi_call(handle, $0, &result)) }
            guard let result else { throw failure("DDI 返回为空。") }
            defer { idevice_string_free(result) }
            let data = Data(String(cString: result).utf8)
            // A failure after native admission is a result carrying whether
            // this request started an effect (thrown here, so the call log
            // records its outcome).
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let failure = try DDIOperationFailure.decode(object) { throw failure }
            return data
        } } catch let refused as InputReleaseUnconfirmed { throw refused }
        catch let failure as DDIOperationFailure {
            if ["snapshot", "foreground"].contains(op),
               failure.message.contains("AX foreground or root changed") ||
               (failure.message.contains("AX request type") && failure.message.contains("refused: 8")) {
                throw PhoneObservationIssue.foregroundChanged
            }
            if ["snapshot", "foreground"].contains(op),
               failure.message.contains("DDI display changed") { throw PhoneObservationIssue.geometryChanged }
            // Native coordinate-effect refusals happen before any touch.
            if !failure.actionIssued, failure.message.contains("; not tapped") { throw PhoneObservationIssue.targetCovered }
            throw failure
        } catch {
            if error.localizedDescription.contains("AX foreground or root changed") { throw PhoneObservationIssue.foregroundChanged }
            // The device can refuse attributes with error 8 during a UI transition.
            // The executor retries only observation, after the old AX socket closes.
            if ["snapshot", "foreground"].contains(object["op"] as? String ?? ""),
               error.localizedDescription.contains("AX request type"),
               error.localizedDescription.contains("refused: 8") { throw PhoneObservationIssue.foregroundChanged }
            if error.localizedDescription.contains("DDI display changed") { throw PhoneObservationIssue.geometryChanged }
            // Native coordinate-effect refusals happen before any touch.
            if error.localizedDescription.contains("; not tapped") { throw PhoneObservationIssue.targetCovered }
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
        tree.outsideAppElements = try DDINodeMapping.outsideAppElements(result)
        observedFrame = tree.frame; observedApp = tree.bundleID
        guard tree.frame.width > 0, tree.frame.height > 0 else { throw failure("DDI 屏幕尺寸无效。") }
        return tree
    }
    func screenshot() async throws -> Data {
        let stall: UInt32 = self.stall == "screenshot" ? 1 : 0
        let result: Data = try await native("screenshot", encode: { _ in "" }) { handle, _, expiresAt in
            var bytes: UnsafeMutablePointer<UInt8>?, count: UInt = 0
            try check(pocket_ddi_screenshot(handle, expiresAt, stall, &bytes, &count))
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
    func compactSurface(fromX: Double, toX: Double, y: Double, seconds: Double) async throws {
        _ = try await call(["op": "surface_drag", "x": fromX, "to_x": toX, "y": y, "seconds": seconds])
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
        // Omitted text is not proof of an empty field. For a nonempty
        // replacement, defer confirmation to the executor's exact post-paste
        // value check; a clear-only request still reports unavailable values.
        if field["ddi_textview_value_omitted"] == "true", preparedText != nil { return }
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
    func replaceTextAX(_ text: String, into input: PhoneInput) async throws {
        guard case .ddi(let rect, let identity) = input else { throw PhoneObservationIssue.nodeChanged }
        _ = try await call(["op": "ax_replace", "identity": identity, "text": text, "clear": true,
                            "target_frame": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]])
    }
    func pressKeys(_ sequence: KeyboardSequence) async throws {
        _ = try await call(["op": "keys", "keys": sequence.keys, "modifiers": sequence.modifiers,
                           "clipboard_allowed": sequence.clipboardAllowed])
    }
    func dismissKeyboard() async throws { _ = try await call(["op": "key", "key": "escape"]) }
    func home() async throws { _ = try await call(["op": "home"]) }
}
