import AgentKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PocketAgentCore

private let fixedMessage = AgentTranscriptMessage(
    id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, role: .user, text: "打开设置",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000))

private func attachment(_ n: Int = 1) -> ChatAttachment {
    ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 10 * n, pixelHeight: 20, byteCount: 100 + n)
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pa-attach-\(UUID().uuidString)", isDirectory: true)
}

/// A real encoded image of the given size, with an EXIF block to verify stripping.
private func sampleImage(width: Int, height: Int, type: UTType = .jpeg, alpha: Bool = false) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: info)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private-note"],
                                       kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2]]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// Canonical bytes of attachment-free messages must not change: existing
/// conflict-copy and deleted-edit IDs derive from them.
struct PortableCanonicalPinTests {
    @Test func attachmentFreeMessageHashesAreUnchanged() throws {
        let portable = PortableMessage(fixedMessage, attribution: nil)
        #expect(StableHash.digest(StableHash.canonical(portable)) == "ab457097187a5ec95cf87767e2caecfc")
        #expect(PortableMerge.conflictID(of: fixedMessage.id, branch: [portable]).uuidString
                == "672775DF-29E7-8C3E-9498-BBCB93D2A27A")
        let json = String(decoding: StableHash.canonical(portable), as: UTF8.self)
        #expect(!json.contains("attachments"))
    }

    @Test func attachmentMetadataRoundTripsWithoutBytesOrPaths() throws {
        let stub = attachment()
        let portable = PortableMessage(fixedMessage, attribution: "P · m", attachments: [stub])
        let data = try PortableCodec.encode(PortableSnapshot(sessions: [
            PortableSession(id: UUID(), title: "t", selection: nil, metadataUpdatedMs: 0, messages: [portable])]))
        let decoded = try PortableCodec.decode(data)
        #expect(decoded.sessions[0].messages[0].attachments == [stub])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("Attachments") && !text.contains(".jpg") && !text.contains("file:"))
        #expect(!text.contains("\"data\""), "no image bytes")
    }

    @Test func invalidAttachmentMetadataIsRejectedWithoutWriting() throws {
        var bad = attachment(); bad.mimeType = "text/html"
        let assistant = AgentTranscriptMessage(role: .assistant, text: "x")
        for message in [PortableMessage(fixedMessage, attribution: nil, attachments: [bad]),
                        PortableMessage(assistant, attribution: nil, attachments: [attachment()])] {
            let data = try PortableCodec.encode(PortableSnapshot(sessions: [
                PortableSession(id: UUID(), title: "t", selection: nil, metadataUpdatedMs: 0, messages: [message])]))
            #expect(throws: SyncError.invalidContent("附件元数据无效")) { try PortableCodec.decode(data) }
        }
    }
}

/// Source: approved scope (sync must not erase local-only image references).
struct AttachmentSyncPreservationTests {
    private func session(_ messages: [AgentTranscriptMessage], attachments: [String: [ChatAttachment]] = [:]) -> ChatSession {
        var session = ChatSession(); session.messages = messages; session.attachments = attachments
        session.draft = "typing"; session.draftAttachments = [attachment(9)]
        return session
    }

    @Test func unchangedLocalMessagesKeepAttachmentsWhenRemoteAppends() {
        let photo = attachment()
        let local = session([fixedMessage], attachments: [fixedMessage.id.uuidString: [photo]])
        let base = PortableSnapshot(sessions: [local], sessionTombstones: [], providers: [], providerTombstones: [])
        var remote = PortableSession(local)!
        remote.messages.append(PortableMessage(AgentTranscriptMessage(role: .assistant, text: "好的"), attribution: nil))
        let plan = SyncPlan.make(local: base, remote: PortableSnapshot(sessions: [remote]), deferred: [])
        let applied = SyncApplication.sessions([local], tombstones: [], merged: plan.merged, base: base, deferred: [])
        let result = applied.sessions[0]
        #expect(result.messages.count == 2)
        #expect(result.attachments[fixedMessage.id.uuidString] == [photo])
        #expect(result.draft == "typing" && result.draftAttachments == local.draftAttachments)
        #expect(result.referencedAttachmentIDs.contains(photo.id))
    }

    @Test func restampedMessageKeepsAttachmentsThroughAdoption() {
        let photo = attachment()
        let local = session([fixedMessage], attachments: [fixedMessage.id.uuidString: [photo]])
        let base = PortableSnapshot(sessions: [local], sessionTombstones: [], providers: [], providerTombstones: [])
        var restamped = fixedMessage
        restamped.createdAt = fixedMessage.createdAt.addingTimeInterval(3)
        var remote = PortableSession(local)!
        remote.messages = [PortableMessage(restamped, attribution: nil, attachments: [photo])]
        let applied = SyncApplication.sessions([local], tombstones: [], merged: PortableSnapshot(sessions: [remote]),
                                               base: base, deferred: [])
        #expect(applied.sessions[0].messages[0].createdAt == restamped.createdAt)
        #expect(applied.sessions[0].attachments[fixedMessage.id.uuidString] == [photo])
    }

    @Test func otherDeviceReceivesPresenceMetadataOnly() {
        let photo = attachment()
        let sender = session([fixedMessage], attachments: [fixedMessage.id.uuidString: [photo]])
        let snapshot = PortableSnapshot(sessions: [sender], sessionTombstones: [], providers: [], providerTombstones: [])
        let applied = SyncApplication.sessions([], tombstones: [], merged: snapshot, base: PortableSnapshot(), deferred: [])
        let received = applied.sessions[0]
        #expect(received.attachments[fixedMessage.id.uuidString] == [photo])
        #expect(received.messages[0].images.isEmpty)
        #expect(received.draft.isEmpty && received.draftAttachments.isEmpty, "drafts and draft images never sync")
        // Re-export is identical, so the next round does not create a conflict copy.
        #expect(PortableSession(received) == snapshot.sessions[0])
    }

    @Test func conflictCopiesShareAttachmentReferences() {
        let photo = attachment()
        let common = PortableMessage(fixedMessage, attribution: nil, attachments: [photo])
        let id = UUID()
        let a = PortableSnapshot(sessions: [PortableSession(id: id, title: "t", selection: nil, metadataUpdatedMs: 0,
            messages: [common, PortableMessage(AgentTranscriptMessage(role: .assistant, text: "a"), attribution: nil)])])
        let b = PortableSnapshot(sessions: [PortableSession(id: id, title: "t", selection: nil, metadataUpdatedMs: 0,
            messages: [common, PortableMessage(AgentTranscriptMessage(role: .assistant, text: "b"), attribution: nil)])])
        let merged = PortableMerge.merge(a, b)
        #expect(merged.sessions.count == 2)
        #expect(merged.sessions.allSatisfy { $0.messages[0].attachments == [photo] })
    }
}

struct AttachmentFileTests {
    @Test func storesNormalizedImageAndReadsItBack() throws {
        let files = AttachmentFiles(directory: temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let normalized = try ImageNormalizer.normalize(sampleImage(width: 4000, height: 1000))
        #expect(normalized.mimeType == "image/jpeg")
        #expect(max(normalized.pixelWidth, normalized.pixelHeight) == ImageNormalizer.maxPixelSize)
        let stored = try files.store(normalized)
        #expect(files.exists(stored))
        #expect(files.data(for: stored) == normalized.data)
        #expect(stored.byteCount == normalized.data.count)
        let excluded = try files.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        // Re-encoding drops source metadata such as EXIF comments and GPS.
        let source = CGImageSourceCreateWithData(normalized.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test func transparentImagesStayPNGAndSmallImagesAreNotUpscaled() throws {
        let normalized = try ImageNormalizer.normalize(sampleImage(width: 64, height: 48, type: .png, alpha: true))
        #expect(normalized.mimeType == "image/png")
        #expect(normalized.pixelWidth == 64 && normalized.pixelHeight == 48)
    }

    @Test func collisionNeverOverwritesAndRecordsNothing() throws {
        let files = AttachmentFiles(directory: temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let image = try ImageNormalizer.normalize(sampleImage(width: 20, height: 20))
        let first = try files.store(image)
        let original = try #require(files.data(for: first))
        let other = NormalizedImage(data: Data("other".utf8), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1)
        #expect(throws: AttachmentError.self) { try files.store(other, id: first.id) }
        #expect(files.data(for: first) == original)
    }

    @Test func unwritableDirectoryFailsWithoutMetadata() throws {
        let parent = temporaryDirectory()
        try Data("file".utf8).write(to: parent) // a file where the directory should be
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = AttachmentFiles(directory: parent.appendingPathComponent("Attachments"))
        let image = NormalizedImage(data: Data([1, 2, 3]), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1)
        #expect(throws: AttachmentError.self) { try files.store(image) }
    }

    @Test func unreadableInputIsRejected() {
        #expect(throws: AttachmentError.unreadableImage) { try ImageNormalizer.normalize(Data("not an image".utf8)) }
    }

    @Test func cleanupKeepsReferencedFilesAndForeignNames() throws {
        let files = AttachmentFiles(directory: temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let image = NormalizedImage(data: Data([1, 2, 3]), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1)
        let kept = try files.store(image), dropped = try files.store(image)
        try Data().write(to: files.directory.appendingPathComponent("notes.txt"))
        #expect(files.removeUnreferenced(keeping: [kept.id]) == 1)
        #expect(files.exists(kept) && !files.exists(dropped))
        #expect(FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("notes.txt").path))
    }
}

struct AttachmentHydrationTests {
    @Test func promptImagesComeFromFilesAndMissingFileFailsTheSend() throws {
        let photo = attachment()
        let images = try AttachmentHydration.images([photo]) { _ in Data([9]) }
        #expect(images.map(\.id) == [photo.id] && images[0].data == Data([9]) && images[0].mimeType == "image/jpeg")
        #expect(throws: AttachmentError.missingFile) { try AttachmentHydration.images([photo]) { _ in nil } }
    }

    @Test func contextHydratesOnlyFrozenMessagesWithinLimit() {
        let messages = (0..<6).map { AgentTranscriptMessage(role: .user, text: "m\($0)") }
        var stored: [String: [ChatAttachment]] = [:]
        for message in messages { stored[message.id.uuidString] = [attachment()] }
        let future = AgentTranscriptMessage(role: .user, text: "later")
        stored[future.id.uuidString] = [attachment()]
        let result = AttachmentHydration.context(messages, attachments: stored, supportsImages: true) { _ in Data([1]) }
        #expect(result.map(\.id) == messages.map(\.id), "no message outside the frozen prior context appears")
        #expect(result.suffix(AttachmentHydration.priorImageLimit).allSatisfy { $0.images.count == 1 })
        #expect(result.prefix(2).allSatisfy { $0.images.isEmpty && $0.text.contains("未随本轮重发") })
        #expect(messages.allSatisfy { $0.images.isEmpty }, "history values are not mutated")
    }

    @Test func textOnlyModelGetsExplicitNoteInsteadOfImages() {
        let message = AgentTranscriptMessage(role: .user, text: "看图")
        let result = AttachmentHydration.context([message], attachments: [message.id.uuidString: [attachment(), attachment(2)]],
                                                 supportsImages: false) { _ in Data([1]) }
        #expect(result[0].images.isEmpty)
        #expect(result[0].text.contains("2 张图片") && result[0].text.contains("当前模型不接收图片"))
    }

    @Test func historyValuesNeverCarryEventImages() {
        let screenshot = AgentImageAttachment(label: "iPhone screen 1", mimeType: "image/png", data: Data([1]),
                                              pixelWidth: 1, pixelHeight: 1)
        let delivered = AgentTranscriptMessage(role: .user, text: "steer", images: [screenshot])
        let stored = ChatSession.forHistory(delivered)
        #expect(stored.images.isEmpty && stored.id == delivered.id && stored.text == "steer")
    }

    @Test func capabilityVerdicts() {
        #expect(ImageCapability.check(supportsImages: true, hasText: false, imageCount: 2) == .ok)
        #expect(ImageCapability.check(supportsImages: false, hasText: true, imageCount: 0) == .ok)
        #expect(ImageCapability.check(supportsImages: false, hasText: true, imageCount: 1) == .warnDropImages)
        #expect(ImageCapability.check(supportsImages: false, hasText: false, imageCount: 1) == .blockImageOnly)
    }
}

/// assistant-v1 sessions carry attachment fields explicitly; files without them are rejected, not upgraded.
struct CurrentStoreAttachmentTests {
    @Test func attachmentFieldsRoundTripAndAreRequired() throws {
        var file = HistoryFile.initial(selection: ModelSelection(providerID: UUID(), modelID: "m"))
        let reply = AgentTranscriptMessage(role: .assistant, text: "回复")
        file.sessions[0].messages = [fixedMessage, reply]
        file.sessions[0].draft = "未发送"
        file.sessions[0].attributions = [reply.id.uuidString: "P · m"]
        file.sessions[0].attachments[fixedMessage.id.uuidString] = [attachment()]
        file.sessions[0].draftAttachments = [attachment(3)]
        file.deletedSessions = [Tombstone(id: UUID(), deletedAt: Date(timeIntervalSince1970: 5))]
        let data = try HistoryCodec.encode(file)
        let again = try HistoryCodec.decode(data)
        #expect(again.sessions[0].attachments == file.sessions[0].attachments)
        #expect(again.sessions[0].draftAttachments == file.sessions[0].draftAttachments)
        #expect(again.sessions[0].messages == file.sessions[0].messages && again.deletedSessions == file.deletedSessions)
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var rows = root["sessions"] as! [[String: Any]]
        rows[0]["attachments"] = nil; rows[0]["draftAttachments"] = nil
        root["sessions"] = rows
        #expect(throws: (any Error).self) { try HistoryCodec.decode(JSONSerialization.data(withJSONObject: root)) }
    }
}
