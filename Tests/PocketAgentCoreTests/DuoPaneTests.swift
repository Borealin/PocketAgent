import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PocketAgentCore

struct DuoPaneTests {
    @Test func scopedPolicyRefusesUnboundOperationsForModelsAndScripts() {
        for pane in DuoPane.allCases {
            let scoped = ToolCapabilities(duoPane: pane)
            for name in DuoPane.unavailableTools {
                #expect(ToolCatalog.decision(for: name, capabilities: scoped) == .deny(DuoPane.unavailableReason))
                #expect(ToolCatalog.scriptDecision(for: name, capabilities: scoped) == .deny(DuoPane.unavailableReason))
                #expect(ToolCatalog.decision(for: name, capabilities: ToolCapabilities()) == .allow)
            }
            for name in ["observe_screen", "tap_point", "swipe", "swipe_from_to", "press_home"] {
                #expect(ToolCatalog.decision(for: name, capabilities: scoped) == .allow)
            }
            #expect(ToolCatalog.available(ToolCapabilities(phoneBackend: .wda, duoPane: pane)).allSatisfy { $0.kind != .phone })
        }
    }

    @Test func croppedImageContainsOnlySelectedSideAndMatchesLogicalBounds() throws {
        let full = try fixture(gutter: true)
        for pane in DuoPane.allCases {
            let source = try #require(CGImageSourceCreateWithData(try DuoScreenCapture.cropPNG(full, pane: pane) as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == Int(pane.frame.width * 3))
            #expect(image.height == Int(pane.frame.height * 3))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let ctx = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            #expect(pixel[pane == .left ? 0 : 2] > 240)
            #expect(pixel[pane == .left ? 2 : 0] < 32)
        }
    }

    @Test func unreadableOrMissingSplitImageFailsClosed() throws {
        #expect(throws: DuoScreenCapture.Issue.self) { try DuoScreenCapture.cropPNG(Data(), pane: .left) }
        let noGutter = try fixture(gutter: false)
        #expect(throws: DuoScreenCapture.Issue.self) { try DuoScreenCapture.cropPNG(noGutter, pane: .right) }
    }

    private func fixture(gutter: Bool) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 2853, height: 2007, bitsPerComponent: 8,
            bytesPerRow: 2853 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2853, height: 2007))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(DuoPane.right.pixelCrop)
        if gutter {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 1407, y: 0, width: 39, height: 2007))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
