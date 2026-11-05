import Foundation
import CoreGraphics
import ImageIO

/// A user-selected geometric control area, not an app/window or keyboard binding.
/// Only the measured fixed inner-display landscapeRight profile is supported.
nonisolated enum DuoPane: String, CaseIterable, Hashable, Sendable {
    case left, right

    var label: String { self == .left ? "左侧" : "右侧" }
    var observationID: String { "duo-pane-" + rawValue }
    var frame: CGRect { CGRect(x: 0, y: 0, width: 469, height: 669) }
    var pixelCrop: CGRect { CGRect(x: self == .left ? 0 : 1446, y: 0, width: 1407, height: 2007) }

    /// These operations cannot be scoped safely with the verified physical
    /// protocol. Keep the policy shared by model and script dispatch.
    static let unavailableTools: Set<String> = [
        "open_app", "open_app_by_name", "tap", "long_press", "type_text",
        "press_key", "press_keys", "dismiss_keyboard",
    ]
    static let unavailableReason = "Duo 单侧模式仅支持半屏截图、坐标触摸、滑动和单侧主屏幕。文字、键盘及 AX 节点操作尚未验证隔离；启动 App 请先返回该侧主屏幕，再按截图点击图标。"
}

nonisolated enum DuoScreenCapture {
    enum Issue: LocalizedError {
        case image, size, gutter
        var errorDescription: String? {
            switch self {
            case .image: "Duo 截图解码或裁剪失败。"
            case .size: "Duo 内屏截图尺寸与已验证姿态不符；未发送输入。"
            case .gutter: "未看到固定分屏中缝；请恢复横向等分分屏并关闭覆盖界面。未发送输入。"
            }
        }
    }

    /// A visual gutter check, not a window/app or modal-ownership proof.
    static func cropPNG(_ data: Data, pane: DuoPane) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Issue.image }
        guard image.width == 2853, image.height == 2007 else { throw Issue.size }
        guard let column = image.cropping(to: CGRect(x: 1426, y: 0, width: 1, height: 2007)) else { throw Issue.image }
        var rgba = [UInt8](repeating: 0, count: 2007 * 4)
        let black: Int = try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 2007,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Issue.image }
            context.draw(column, in: CGRect(x: 0, y: 0, width: 1, height: 2007))
            return (0..<2007).filter { row in
                let p = row * 4
                return bytes[p] < 8 && bytes[p + 1] < 8 && bytes[p + 2] < 8 && bytes[p + 3] == 255
            }.count
        }
        guard Double(black) / 2007 >= 0.9 else { throw Issue.gutter }
        guard let crop = image.cropping(to: pane.pixelCrop) else { throw Issue.image }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw Issue.image }
        CGImageDestinationAddImage(destination, crop, nil)
        guard CGImageDestinationFinalize(destination) else { throw Issue.image }
        return output as Data
    }
}
