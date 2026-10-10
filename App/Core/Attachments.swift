import AgentKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Nonsecret description of one user image. It is the only attachment data in
/// history and portable snapshots: no bytes, file names or paths. The bytes
/// live in a protected local file derived from `id`.
nonisolated struct ChatAttachment: Identifiable, Hashable, Codable, Sendable {
    static let maxPerMessage = 6
    var id: UUID
    var mimeType: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int

    var fileExtension: String { mimeType == "image/png" ? "png" : "jpg" }
}

nonisolated enum AttachmentError: LocalizedError, Equatable {
    case unreadableImage, tooLarge, tooMany, missingFile, writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .unreadableImage: "无法读取该图片，未添加。"
        case .tooLarge: "图片过大（超过 40 MB），未添加。"
        case .tooMany: "每条消息最多 \(ChatAttachment.maxPerMessage) 张图片。"
        case .missingFile: "图片文件已不在本机，无法发送；请移除后重新添加。"
        case .writeFailed(let detail): "图片保存失败，未添加：\(detail)"
        }
    }
}

/// A re-encoded image: orientation applied, at most `maxPixelSize` on the long
/// edge, and no source metadata (EXIF, GPS) carried over.
nonisolated struct NormalizedImage: Sendable {
    var data: Data
    var mimeType: String
    var pixelWidth: Int
    var pixelHeight: Int
}

nonisolated enum ImageNormalizer {
    static let maxPixelSize = 2048
    static let maxInputBytes = 40 * 1024 * 1024

    static func normalize(_ input: Data) throws -> NormalizedImage {
        guard input.count <= maxInputBytes else { throw AttachmentError.tooLarge }
        guard let source = CGImageSourceCreateWithData(input as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw AttachmentError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError.unreadableImage
        }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = opaque ? UTType.jpeg : UTType.png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw AttachmentError.unreadableImage
        }
        CGImageDestinationAddImage(destination, image,
                                   (opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.unreadableImage }
        return NormalizedImage(data: output as Data, mimeType: opaque ? "image/jpeg" : "image/png",
                               pixelWidth: image.width, pixelHeight: image.height)
    }
}

/// Local image files in one directory excluded from backup. Files are named by
/// attachment ID only; a file is written and verified before its metadata is
/// returned, so history never records an attachment that does not exist.
nonisolated struct AttachmentFiles: Sendable {
    let directory: URL

    func url(for attachment: ChatAttachment) -> URL {
        directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).\(attachment.fileExtension)")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func store(_ image: NormalizedImage, id: UUID = UUID()) throws -> ChatAttachment {
        let attachment = ChatAttachment(id: id, mimeType: image.mimeType, pixelWidth: image.pixelWidth,
                                        pixelHeight: image.pixelHeight, byteCount: image.data.count)
        let url = url(for: attachment)
        do {
            try prepare()
            // Names are fresh UUIDs; an existing file is never replaced.
            // (`.withoutOverwriting` cannot be combined with `.atomic`.)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw AttachmentError.writeFailed("同名附件已存在")
            }
            try image.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == image.data.count else {
                try? FileManager.default.removeItem(at: url)
                throw AttachmentError.writeFailed("写入大小不一致")
            }
        } catch let error as AttachmentError { throw error }
        catch { throw AttachmentError.writeFailed(error.localizedDescription) }
        return attachment
    }

    func data(for attachment: ChatAttachment) -> Data? {
        guard let data = try? Data(contentsOf: url(for: attachment)), data.count == attachment.byteCount else { return nil }
        return data
    }

    func exists(_ attachment: ChatAttachment) -> Bool {
        FileManager.default.fileExists(atPath: url(for: attachment).path)
    }

    /// Removes attachment files no conversation, draft or accepted turn still
    /// references. Names that are not attachment files are left alone.
    @discardableResult
    func removeUnreferenced(keeping referenced: Set<UUID>) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names {
            let stem = (name as NSString).deletingPathExtension
            guard let id = UUID(uuidString: stem), !referenced.contains(id) else { continue }
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}

/// Builds model-facing image parts from file-backed attachments only when a
/// request is assembled. History keeps metadata; no base64 is ever repeated.
nonisolated enum AttachmentHydration {
    /// Earlier user images re-sent as context per run, newest first.
    static let priorImageLimit = 4

    /// Images for the turn being sent. A missing file fails the send instead of
    /// silently dropping the picture the user chose.
    static func images(_ attachments: [ChatAttachment],
                       load: (ChatAttachment) -> Data?) throws -> [AgentImageAttachment] {
        try attachments.enumerated().map { index, attachment in
            guard let data = load(attachment) else { throw AttachmentError.missingFile }
            return image(attachment, data: data, index: index)
        }
    }

    /// Frozen prior context with images attached to the user messages that sent
    /// them. Only `messages` (captured at enqueue) are considered. Images that
    /// are not included get an explicit note rather than disappearing.
    static func context(_ messages: [AgentTranscriptMessage], attachments: [String: [ChatAttachment]],
                        supportsImages: Bool, load: (ChatAttachment) -> Data?) -> [AgentTranscriptMessage] {
        var result = messages
        var budget = supportsImages ? priorImageLimit : 0
        for index in result.indices.reversed() where result[index].role == .user {
            let stored = attachments[result[index].id.uuidString] ?? []
            guard !stored.isEmpty else { continue }
            var omitted = 0, missing = 0
            for (offset, attachment) in stored.enumerated() {
                guard budget > 0 else { omitted += 1; continue }
                guard let data = load(attachment) else { missing += 1; continue }
                result[index].images.append(image(attachment, data: data, index: offset))
                budget -= 1
            }
            let reason = !supportsImages ? "当前模型不接收图片"
                : missing > 0 && omitted == 0 ? "图片已不在本机" : "较早的图片未随本轮重发"
            if omitted + missing > 0 {
                result[index].text += "\n[用户在此消息附带了 \(omitted + missing) 张图片，本轮请求未包含：\(reason)]"
            }
        }
        return result
    }

    private static func image(_ attachment: ChatAttachment, data: Data, index: Int) -> AgentImageAttachment {
        AgentImageAttachment(id: attachment.id, label: "用户图片 \(index + 1)", mimeType: attachment.mimeType, data: data,
                             pixelWidth: attachment.pixelWidth, pixelHeight: attachment.pixelHeight)
    }
}
