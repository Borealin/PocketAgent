import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

private func photo(_ n: Int = 0) -> ChatAttachment {
    ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1, byteCount: n)
}

/// Source: root/peer review (a turn rejected before it started left the
/// composer empty; then a restore merged the old image into a newer draft).
struct DraftRestoreTests {
    let saved = DraftSnapshot(text: "  analyse A\n", attachments: [photo(1)], revision: 4)

    /// After enqueue the composer is cleared programmatically (no edit).
    private func cleared() -> ChatSession { ChatSession() }

    @Test func pristineComposerGetsTheExactWholeDraftBack() {
        var session = cleared()
        #expect(DraftRestore.apply(saved, to: &session, started: false, currentRevision: 4))
        #expect(session.draft == "  analyse A\n" && session.draftAttachments == saved.attachments)
    }

    @Test func editedDraftIsLeftEntirelyUntouched() {
        var session = cleared()
        let imageB = photo(2)
        session.draft = "analyse B"; session.draftAttachments = [imageB]
        #expect(!DraftRestore.apply(saved, to: &session, started: false, currentRevision: 6))
        #expect(session.draft == "analyse B" && session.draftAttachments == [imageB], "never merges image A")
    }

    @Test func draftEditedBackToEmptyStaysEmpty() {
        var session = cleared()
        session.draft = "   "
        #expect(!DraftRestore.apply(saved, to: &session, started: false, currentRevision: 5))
        #expect(session.draft == "   " && session.draftAttachments.isEmpty)
    }

    @Test func imageChosenButStillLoadingCountsAsEdit() {
        var session = cleared() // reservation bumped the revision before any read finished
        #expect(!DraftRestore.apply(saved, to: &session, started: false, currentRevision: 5))
        #expect(session.draft.isEmpty && session.draftAttachments.isEmpty)
    }

    @Test func startedRunIsNeverRestored() {
        var session = cleared()
        #expect(!DraftRestore.apply(saved, to: &session, started: true, currentRevision: 4))
        #expect(session.draft.isEmpty && session.draftAttachments.isEmpty)
    }

    @Test func skippedRestorationMakesNoClaim() {
        var session = cleared()
        session.draft = "analyse B"
        let restored = DraftRestore.apply(saved, to: &session, started: false, currentRevision: 5)
        #expect(DraftRestore.note(restored: restored).isEmpty)
        #expect(DraftRestore.note(restored: true).contains("草稿已恢复"))
    }

    @Test func textOnlySendRestoresTextAndKeepsRetainedPhotos() {
        // "仅发送文字": the photos stayed in the draft; the snapshot is the
        // whole pre-send draft, so restoring cannot drop them.
        let photos = [photo(1), photo(2)]
        let textOnly = DraftSnapshot(text: "只发文字", attachments: photos, revision: 2)
        var session = cleared()
        session.draftAttachments = photos
        #expect(DraftRestore.apply(textOnly, to: &session, started: false, currentRevision: 2))
        #expect(session.draft == "只发文字" && session.draftAttachments == photos)
    }
}

/// Source: root/peer review (overlapping imports could exceed six images).
struct AttachmentCapacityTests {
    @Test func reservationsAndCommitsNeverExceedTheLimit() {
        #expect(AttachmentCapacity.room(committed: 2, reserved: 3) == 1)
        #expect(AttachmentCapacity.room(committed: 4, reserved: 4) == 0)
        #expect(AttachmentCapacity.accepted(incoming: 3, committed: 5) == 1)
        #expect(AttachmentCapacity.accepted(incoming: 3, committed: 7) == 0)
        // Two concurrent imports reserved from the same committed count.
        var committed = 1, reserved = 0
        let first = min(4, AttachmentCapacity.room(committed: committed, reserved: reserved)); reserved += first
        let second = min(4, AttachmentCapacity.room(committed: committed, reserved: reserved)); reserved += second
        committed += AttachmentCapacity.accepted(incoming: first, committed: committed)
        committed += AttachmentCapacity.accepted(incoming: second, committed: committed)
        #expect(first == 4 && second == 1 && committed == ChatAttachment.maxPerMessage)
    }
}

/// Source: root/peer review (deltas above a pending steering message stopped following).
struct TranscriptProgressTests {
    @Test func liveReplyAbovePendingSteeringStillSignalsChanges() {
        let prompt = AgentTranscriptMessage(role: .user, text: "开始")
        var live = AgentTranscriptMessage(role: .assistant, text: "")
        let steering = AgentTranscriptMessage(role: .user, text: "再快一点")
        func rendered() -> TranscriptProgress { TranscriptProgress([prompt, live, steering]) }
        var last = rendered()
        live.text += "第一段"
        #expect(rendered() != last, "text delta in a non-last message"); last = rendered()
        live.reasoning = [AgentReasoningBlock(text: "思")]
        #expect(rendered() != last, "reasoning delta"); last = rendered()
        live.reasoning[0].text += "考"
        #expect(rendered() != last); last = rendered()
        let appended = TranscriptProgress([prompt, live, steering, AgentTranscriptMessage(role: .tool, text: "", toolCallID: "c")])
        #expect(appended != last, "normal append")
        #expect(TranscriptProgress([prompt, live, steering]) == last, "no change, no signal")
    }
}

struct RemoteImagePolicyTests {
    @Test func onlyPublicCredentialFreeHTTPS() {
        for allowed in ["https://example.com/a.png", "https://cdn.example.com:8443/x", "https://8.8.8.8/i.png",
                        "https://[2001:4860::8888]/i.png"] {
            #expect(RemoteImagePolicy.allows(URL(string: allowed)), "\(allowed)")
        }
        for refused in ["http://example.com/a.png", "https://u:p@example.com/a.png", "https://localhost/a.png",
                        "https://" + "printer.local" + "/a.png", "https://intranet/a.png", "https://192.168.1.10/a.png",
                        "https://10.0.0.1/a", "https://127.0.0.1/a", "https://169.254.1.1/a", "https://172.20.0.1/a",
                        "https://100.64.0.1/a", "https://[::1]/a", "https://[fe80::1]/a", "https://[fd00::1]/a",
                        "file:///etc/hosts", "data:image/png;base64,AA=="] {
            #expect(!RemoteImagePolicy.allows(URL(string: refused)), "\(refused)")
        }
        #expect(!RemoteImagePolicy.allows(nil))
        #expect(RemoteImagePolicy.acceptsDeclaredLength(-1) && RemoteImagePolicy.acceptsDeclaredLength(RemoteImagePolicy.maxBytes))
        #expect(!RemoteImagePolicy.acceptsDeclaredLength(RemoteImagePolicy.maxBytes + 1))
        #expect(MarkdownImageReference(alt: "", url: URL(string: "https://192.168.0.2/x.png"), raw: "").isLoadable == false)
    }

    @Test func boundedBufferStopsAtLimit() {
        var buffer = BoundedBuffer(limit: 10)
        let first = buffer.append(Data(count: 6)), second = buffer.append(Data(count: 4))
        let overflow = buffer.append(Data(count: 1))
        #expect(first && second && !overflow)
        #expect(buffer.data.count == 10)
    }
}

// MARK: Loader against a local stub protocol (no network)

private final class StubImageProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior {
        case image(Data, mime: String = "image/png", length: Int? = nil)
        case redirect(to: String)
        case endless(chunk: Int)
    }
    nonisolated(unsafe) static var behaviors: [String: Behavior] = [:]
    nonisolated(unsafe) static var sentBytes: [String: Int] = [:]
    static let lock = NSLock()
    private var stopped = false
    private let stopLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("stub.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = url.host! + url.path
        guard let behavior = Self.lock.withLock({ Self.behaviors[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        switch behavior {
        case .image(let data, let mime, let length):
            var headers = ["Content-Type": mime]
            headers["Content-Length"] = String(length ?? data.count)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if length == nil || length == data.count { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
        case .endless(let chunk):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/jpeg"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().async {
                for _ in 0..<200 {
                    if self.stopLock.withLock({ self.stopped }) { return }
                    Self.lock.withLock { Self.sentBytes[key, default: 0] += chunk }
                    self.client?.urlProtocol(self, didLoad: Data(count: chunk))
                    Thread.sleep(forTimeInterval: 0.002)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { stopLock.withLock { stopped = true } }

    static func register(_ path: String, _ behavior: Behavior) { lock.withLock { behaviors["img.stub.test" + path] = behavior } }
    static func sent(_ path: String) -> Int { lock.withLock { sentBytes["img.stub.test" + path] ?? 0 } }
}

private func load(_ path: String) async throws -> Data {
    try await RemoteImageLoader.load(URL(string: "https://img.stub.test" + path)!) {
        $0.protocolClasses = [StubImageProtocol.self]
    }
}

/// Source: root/peer review (unbounded buffering and unchecked redirects).
struct RemoteImageLoaderTests {
    @Test func smallImageLoads() async throws {
        StubImageProtocol.register("/ok.png", .image(Data([1, 2, 3])))
        #expect(try await load("/ok.png") == Data([1, 2, 3]))
    }

    @Test func declaredOversizeIsRefusedBeforeBody() async {
        StubImageProtocol.register("/big.png", .image(Data(), length: Int(RemoteImagePolicy.maxBytes) + 1))
        await #expect(throws: RemoteImageError("图片超过 20 MB")) { try await load("/big.png") }
    }

    @Test func endlessBodyIsCancelledAtTheLimit() async {
        let chunk = 1024 * 1024
        StubImageProtocol.register("/endless.jpg", .endless(chunk: chunk))
        await #expect(throws: RemoteImageError("图片超过 20 MB")) { try await load("/endless.jpg") }
        try? await Task.sleep(for: .milliseconds(100))
        let sent = StubImageProtocol.sent("/endless.jpg")
        #expect(sent > Int(RemoteImagePolicy.maxBytes) && sent < Int(RemoteImagePolicy.maxBytes) + 20 * chunk,
                "stopped near the limit instead of reading all 200 MB (sent \(sent))")
    }

    @Test func unsafeRedirectIsNotFollowed() async {
        StubImageProtocol.register("/to-lan", .redirect(to: "http://192.168.1.1/admin.png"))
        await #expect(throws: RemoteImageError("图片重定向到不受支持的地址，已停止")) { try await load("/to-lan") }
    }

    @Test func safeRedirectIsFollowed() async throws {
        StubImageProtocol.register("/hop", .redirect(to: "https://img.stub.test/final.png"))
        StubImageProtocol.register("/final.png", .image(Data([7])))
        #expect(try await load("/hop") == Data([7]))
    }

    @Test func nonImageResponseIsRefused() async {
        StubImageProtocol.register("/page", .image(Data("<html>".utf8), mime: "text/html"))
        await #expect(throws: RemoteImageError("返回的内容不是图片")) { try await load("/page") }
    }
}
