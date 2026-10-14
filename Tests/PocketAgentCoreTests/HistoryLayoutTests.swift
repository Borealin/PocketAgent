import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Deterministic generator for the edit sequences.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 29)
    }
}

/// The stable layout is the same JSON value as the codec's encoding, and a
/// patch applied to the published bytes gives exactly the whole image. These
/// run off the main actor (only the synthetic file is built on it), so a long
/// sequence does not starve main-actor suites with deadlines.
struct HistoryLayoutTests {
    private func jsonValue(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @MainActor private static func sample() throws -> HistoryFile {
        var file = try LongHistoryBenchmark.synthetic(messages: 60)
        file.sessions[0].draft = "草稿 \"引号\" \\ 反斜杠\n换行 \u{1F600}"
        var task = ChatSession(selection: nil, title: "任务 \"一\"")
        task.messages = [AgentTranscriptMessage(role: .user, text: "messages"),
                         AgentTranscriptMessage(role: .assistant, text: "{\"messages\":[]}")]
        // An attachments key named like the array the layout moves.
        task.attachments = ["messages": [ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 1, pixelHeight: 1,
                                                        byteCount: 1)]]
        // A conflict copy shares message IDs with different values.
        var copy = task
        copy.id = UUID(); copy.conflictOf = task.id
        copy.messages[1].text = "冲突副本的不同内容"
        file.sessions += [task, copy, ChatSession(selection: nil, title: "空任务")]
        file.deletedSessions = [Tombstone(id: UUID(), deletedAt: Date(timeIntervalSince1970: 1_800_000_000.25))]
        return file
    }

    @Test func layoutImageIsTheSameJSONValueAndDecodesToTheFile() async throws {
        let sample = try await MainActor.run { try Self.sample() }
        for file in [HistoryFile.initial(selection: nil), sample] {
            let image = try HistoryLayoutEncoder().plan(file, baseline: nil).layout.image()
            #expect(try jsonValue(image) == jsonValue(HistoryCodec.encode(file)))
            #expect(try HistoryCodec.decode(image) == file)
        }
    }

    @Test func fieldsWithoutThePairKeepEveryOtherField() throws {
        let cases = ["{\"k\":\"S\",\"a\":1}", "{\"a\":1,\"k\":\"S\"}", "{\"a\":1,\"k\":\"S\",\"b\":[2]}"]
        for shell in cases {
            let fields = try #require(HistoryLayoutEncoder.fields(Data(shell.utf8), key: "k", sentinel: "S"))
            let rebuilt = "{" + String(decoding: fields.dropLast(), as: UTF8.self) + "}"
            #expect(try jsonValue(Data(rebuilt.utf8)).allKeys.count == (shell.contains("\"b\"") ? 2 : 1))
        }
        // Not unique, or no other field: the caller fails instead of guessing.
        #expect(HistoryLayoutEncoder.fields(Data("{\"k\":\"S\",\"j\":\"\\\"k\\\":\\\"S\\\"\",\"x\":{\"k\":\"S\"}}".utf8),
                                            key: "k", sentinel: "S") == nil)
        #expect(HistoryLayoutEncoder.fields(Data("{\"k\":\"S\"}".utf8), key: "k", sentinel: "S") == nil)
    }

    /// Random edits of every region; a patched copy of the previous bytes
    /// must equal the new whole image byte for byte, and decode to the file.
    @Test func patchesGiveExactlyTheWholeImageAcrossRandomEdits() async throws {
        var generator = SeededGenerator(state: 7)
        var file = try await MainActor.run { try Self.sample() }
        let encoder = HistoryLayoutEncoder()
        var plan = try encoder.plan(file, baseline: nil)
        var bytes = [UInt8](plan.layout.image())
        var patched = 0, rebuilt = 0
        for step in 0..<300 {
            if step % 10 == 0 { await Task.yield() }
            let session = Int.random(in: 0..<file.sessions.count, using: &generator)
            switch Int.random(in: 0..<12, using: &generator) {
            case 0, 1, 2:
                file.sessions[session].messages.append(AgentTranscriptMessage(role: .assistant, text: "追加 \(step)"))
            case 3 where !file.sessions[session].messages.isEmpty:
                let index = Int.random(in: 0..<file.sessions[session].messages.count, using: &generator)
                file.sessions[session].messages[index].text += " 改 \(step)"
            case 4 where !file.sessions[session].messages.isEmpty:
                file.sessions[session].messages.removeLast()
            case 5 where !file.sessions[session].messages.isEmpty:
                let index = Int.random(in: 0..<file.sessions[session].messages.count, using: &generator)
                file.sessions[session].messages.remove(at: index)
            case 6:
                file.sessions[session].title = "标题 \(step)"
                file.sessions[session].updatedAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(step))
            case 7:
                file.sessions[session].draft = String(repeating: "长草稿", count: Int.random(in: 0..<900, using: &generator))
            case 8:
                file.deletedSessions.append(Tombstone(id: UUID(), deletedAt: Date(timeIntervalSince1970: Double(step))))
            case 9:
                file.sessions.append(ChatSession(selection: nil, title: "新任务 \(step)"))
            case 10 where file.sessions.count > 2 && file.sessions[session].id != file.assistant.primarySessionID:
                file.sessions.remove(at: session)
            case 11 where file.sessions.count > 2:
                file.sessions.swapAt(1, file.sessions.count - 1)
            default:
                file.sessions[session].messages.append(AgentTranscriptMessage(role: .user, text: String(repeating: "大", count: 30_000)))
            }
            let next = try encoder.plan(file, baseline: plan.layout)
            let image = [UInt8](next.layout.image())
            if let chunks = next.chunks {
                #expect(next.layout.size == plan.layout.size)
                for chunk in chunks { bytes.replaceSubrange(chunk.offset..<(chunk.offset + chunk.bytes.count), with: chunk.bytes) }
                #expect(bytes == image, "step \(step)")
                patched += 1
            } else {
                bytes = image
                rebuilt += 1
            }
            #expect(try HistoryCodec.decode(Data(bytes)) == file, "step \(step)")
            plan = next
        }
        #expect(patched > 150 && rebuilt > 5)
    }

    /// Review finding: capacity came from a floor of the whole history
    /// applied to every session (a 110 MB primary would give each of 1,000
    /// small tasks 1 MiB, about 1 GB of spaces). Capacity now comes from each
    /// region's own size: a small task's spare does not change when the rest
    /// of the history grows, and the primary keeps an eighth.
    @Test func capacityFollowsEachSessionsOwnSize() async throws {
        let small = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 60) }
        var large = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 3_000) }
        var tasks: [ChatSession] = []
        for index in 0..<400 {
            var task = ChatSession(selection: nil, title: "小任务 \(index)")
            task.messages = (0..<20).map { AgentTranscriptMessage(role: $0 % 2 == 0 ? .user : .assistant,
                                                                   text: String(repeating: "任务内容\(index)", count: 30)) }
            tasks.append(task)
        }
        tasks += (0..<50).map { ChatSession(selection: nil, title: "空任务 \($0)") }
        large.sessions += tasks
        var lone = small
        lone.sessions.append(tasks[0])
        let layout = try HistoryLayoutEncoder().plan(large, baseline: nil).layout
        let alone = try HistoryLayoutEncoder().plan(lone, baseline: nil).layout
        for session in layout.sessions {
            #expect(session.contentCapacity - session.contentLength == HistoryLayout.contentSpare(session.contentLength))
            #expect(session.headerCapacity - session.header.count == HistoryLayout.headerSpare(session.header.count))
        }
        let primary = layout.sessions[0]
        #expect(primary.contentLength / 8 > 16 << 10)
        #expect(primary.contentCapacity - primary.contentLength == primary.contentLength / 8)
        // The same task gets the same capacity next to a 60- or a 3,000-message primary.
        let task = try #require(layout.sessions.first { $0.id == tasks[0].id })
        let taskAlone = try #require(alone.sessions.first { $0.id == tasks[0].id })
        #expect(task.contentCapacity == taskAlone.contentCapacity && task.contentCapacity - task.contentLength == 16 << 10)
        // Bounded: spaces stay within an eighth of the content, half the
        // headers and the per-region constants.
        let data = layout.prefix.count + layout.sessions.reduce(0) { $0 + $1.header.count + $1.contentLength }
        let bound = layout.prefix.count / 8 + (64 << 10)
            + layout.sessions.reduce(0) { $0 + $1.contentLength / 8 + (16 << 10) + $1.header.count / 2 + (1 << 10) }
        let structure = 1 + HistoryLayout.sessionsKey.count + 2 + layout.sessions.count * (2 + HistoryLayout.messagesKey.count + 1)
        #expect(layout.size - data - structure <= bound)
        // The same JSON value as the codec, and it decodes to the file.
        let image = layout.image()
        #expect(image.count == layout.size)
        #expect(try jsonValue(image) == jsonValue(HistoryCodec.encode(large)))
        #expect(try HistoryCodec.decode(image) == large)
    }

    @Test func unchangedFileProducesNoChunks() async throws {
        let file = try await MainActor.run { try Self.sample() }
        let encoder = HistoryLayoutEncoder()
        let first = try encoder.plan(file, baseline: nil)
        let again = try encoder.plan(file, baseline: first.layout)
        #expect(again.chunks?.isEmpty == true)
    }
}

/// The production writer on a real temporary file: patches only while the
/// file is the one it published, every failure before the rename leaves the
/// file untouched, and the baseline moves only after publication. Off the
/// main actor except the owner test.
struct PatchingHistoryWriterTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa-layout-\(UUID().uuidString)")
        lazy var storage = HistoryStorage(url: directory.appendingPathComponent("history.json"))
        deinit { try? FileManager.default.removeItem(at: directory) }
        var leftovers: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0 != "history.json" }
        }
        func onDisk() throws -> Data { try Data(contentsOf: storage.url) }
    }

    private func grow(_ file: inout HistoryFile, _ text: String) throws {
        try file.editSession(file.assistant.primarySessionID) {
            $0.messages.append(AgentTranscriptMessage(role: .assistant, text: text))
        }
    }

    private func written(_ writer: PatchingHistoryWriter, _ fixture: Fixture, equal file: HistoryFile) throws -> Bool {
        let data = try fixture.onDisk()
        return try data == writer.published?.layout.image() && HistoryCodec.decode(data) == file && fixture.leftovers.isEmpty
    }

    @Test func firstWriteIsWholeThenChangesArePatchedAndARestartStartsWhole() async throws {
        let fixture = Fixture()
        var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 300) }
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        try writer.write(file)
        #expect(writer.lastMode == .whole)
        for index in 0..<5 {
            try grow(&file, "事件 \(index)")
            try writer.write(file)
            #expect(writer.lastMode == .patch)
            #expect(writer.lastChangedBytes < 64 << 10)
            #expect(try written(writer, fixture, equal: file))
        }
        // A new process knows nothing it published: whole first, then patches.
        let restarted = PatchingHistoryWriter(storage: fixture.storage)
        try grow(&file, "重启后")
        try restarted.write(file)
        #expect(restarted.lastMode == .whole)
        try grow(&file, "重启后再一次")
        try restarted.write(file)
        #expect(try restarted.lastMode == .patch && written(restarted, fixture, equal: file))
    }

    /// A clone left behind by a process that ended before its rename is
    /// removed when the next writer starts; other files are left alone.
    @Test func aNewWriterRemovesClonesLeftByAnEndedProcess() async throws {
        let fixture = Fixture()
        let file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
        try PatchingHistoryWriter(storage: fixture.storage).write(file)
        let directory = fixture.directory
        let stale = directory.appendingPathComponent(".history.json.patch-\(UUID().uuidString)")
        let other = directory.appendingPathComponent("history.unreadable-1.json")
        #expect(FileManager.default.createFile(atPath: stale.path, contents: Data("x".utf8)))
        #expect(FileManager.default.createFile(atPath: other.path, contents: Data("y".utf8)))
        _ = PatchingHistoryWriter(storage: fixture.storage)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(try HistoryCodec.decode(fixture.onDisk()) == file)
    }

    @Test func aFileChangedOutsideTheWriterIsWrittenWhole() async throws {
        let fixture = Fixture()
        var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        try writer.write(file)
        // Same size, different bytes (as corruption or another writer would leave).
        var bytes = try fixture.onDisk()
        bytes[bytes.count - 3] = 0x20
        try bytes.write(to: fixture.storage.url)
        try grow(&file, "外部修改之后")
        try writer.write(file)
        #expect(try writer.lastMode == .wholeAfterIdentityChange && written(writer, fixture, equal: file))
        // Replaced by another file.
        try Data("{}".utf8).write(to: fixture.storage.url, options: .atomic)
        try grow(&file, "被替换之后")
        try writer.write(file)
        #expect(try writer.lastMode == .wholeAfterIdentityChange && written(writer, fixture, equal: file))
        // Removed.
        try FileManager.default.removeItem(at: fixture.storage.url)
        try grow(&file, "被删除之后")
        try writer.write(file)
        #expect(try writer.lastMode == .wholeAfterIdentityChange && written(writer, fixture, equal: file))
    }

    @Test func aChangeDuringTheCloneIsDetectedAfterIt() async throws {
        let fixture = Fixture()
        var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        try writer.write(file)
        var calls = HistoryPatchCalls.system
        let url = fixture.storage.url
        calls.afterClone = {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            try? handle.seek(toOffset: 0); try? handle.write(contentsOf: Data("{".utf8)); try? handle.close()
        }
        writer.calls = calls
        try grow(&file, "克隆期间被改")
        try writer.write(file)
        #expect(try writer.lastMode == .wholeAfterIdentityChange && written(writer, fixture, equal: file))
    }

    private enum Fault { case noSpace, partialThenNoSpace, shortWrites, interrupted, fsync, fsyncInterrupted, rename, cloneNoSpace }

    private func calls(_ fault: Fault) -> HistoryPatchCalls {
        var calls = HistoryPatchCalls.system
        switch fault {
        case .noSpace:
            calls.pwrite = { _, _, _, _ in errno = ENOSPC; return -1 }
        case .partialThenNoSpace:
            // Some bytes reach the clone, then the disk is full.
            var calls_ = 0
            calls.pwrite = { fd, bytes, count, offset in
                calls_ += 1
                if calls_ == 1 { return Darwin.pwrite(fd, bytes, max(1, count / 2), offset) }
                errno = ENOSPC; return -1
            }
        case .shortWrites:
            calls.pwrite = { fd, bytes, count, offset in Darwin.pwrite(fd, bytes, max(1, count / 3), offset) }
        case .interrupted:
            var interrupted = false
            calls.pwrite = { fd, bytes, count, offset in
                if !interrupted { interrupted = true; errno = EINTR; return -1 }
                return Darwin.pwrite(fd, bytes, count, offset)
            }
        case .fsync:
            calls.fsync = { _ in errno = EIO; return -1 }
        case .fsyncInterrupted:
            var interrupted = false
            calls.fsync = { fd in
                if !interrupted { interrupted = true; errno = EINTR; return -1 }
                return Darwin.fsync(fd)
            }
        case .rename:
            calls.rename = { _, _, _ in errno = EIO; return -1 }
        case .cloneNoSpace:
            calls.clone = { _, _, _ in errno = ENOSPC; return -1 }
        }
        return calls
    }

    @Test func failuresBeforeTheRenameLeaveTheFileAndBaselineUntouched() async throws {
        for fault in [Fault.noSpace, .partialThenNoSpace, .fsync, .rename, .cloneNoSpace] {
            let fixture = Fixture()
            var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
            let writer = PatchingHistoryWriter(storage: fixture.storage)
            try writer.write(file)
            try grow(&file, "成功的补丁")
            try writer.write(file)
            let before = try fixture.onDisk()
            let baseline = try #require(writer.published?.identity)
            writer.calls = calls(fault)
            var failed = file
            try grow(&failed, "失败的补丁")
            #expect(throws: HistoryPatchError.self) { try writer.write(failed) }
            #expect(try fixture.onDisk() == before, "\(fault)")
            #expect(writer.published?.identity == baseline, "\(fault)")
            #expect(fixture.leftovers.isEmpty, "\(fault)")
            // The untouched file is still the baseline: the retry patches it.
            writer.calls = .system
            try writer.write(failed)
            #expect(try writer.lastMode == .patch && written(writer, fixture, equal: failed), "\(fault)")
        }
    }

    @Test func shortAndInterruptedWritesComplete() async throws {
        for fault in [Fault.shortWrites, .interrupted, .fsyncInterrupted] {
            let fixture = Fixture()
            var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
            let writer = PatchingHistoryWriter(storage: fixture.storage)
            try writer.write(file)
            writer.calls = calls(fault)
            try grow(&file, "分段写入")
            try writer.write(file)
            #expect(try writer.lastMode == .patch && written(writer, fixture, equal: file), "\(fault)")
        }
    }

    @Test func aVolumeWithoutCloningIsWrittenWhole() async throws {
        let fixture = Fixture()
        var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        try writer.write(file)
        var calls = HistoryPatchCalls.system
        calls.clone = { _, _, _ in errno = ENOTSUP; return -1 }
        writer.calls = calls
        try grow(&file, "不支持克隆")
        try writer.write(file)
        #expect(try writer.lastMode == .wholeWithoutCloning && written(writer, fixture, equal: file))
        try grow(&file, "之后都整体写")
        try writer.write(file)
        #expect(try writer.lastMode == .whole && written(writer, fixture, equal: file))
    }

    /// A patch publishes a clone of the published file, so it keeps that
    /// file's protection class, extended attributes and backup flag exactly
    /// as the whole write left them. An attribute change made outside the
    /// writer changes the file's change time, so the next write is whole.
    @Test func aPatchKeepsThePublishedFilesAttributes() async throws {
        let fixture = Fixture()
        var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        try writer.write(file)
        var url = fixture.storage.url
        func protection() -> Int32 { let fd = open(url.path, O_RDONLY); defer { close(fd) }; return fcntl(fd, F_GETPROTECTIONCLASS) }
        func attributes() -> [String] {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = listxattr(url.path, &buffer, buffer.count, 0)
            return length <= 0 ? [] : buffer.prefix(length).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
        }
        func excluded() throws -> Bool? {
            url.removeAllCachedResourceValues()
            return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }
        let before = (protection(), attributes(), try excluded())
        for index in 0..<3 {
            try grow(&file, "保留属性 \(index)")
            try writer.write(file)
            #expect(writer.lastMode == .patch)
            #expect(protection() == before.0 && attributes() == before.1)
            #expect(try excluded() == before.2)
        }
        let marker = Data("kept".utf8)
        let set = marker.withUnsafeBytes { setxattr(url.path, "com.pocketagent.test", $0.baseAddress, marker.count, 0, 0) }
        #expect(set == 0)
        try grow(&file, "外部改属性之后")
        try writer.write(file)
        #expect(try writer.lastMode == .wholeAfterIdentityChange && written(writer, fixture, equal: file))
    }

    /// A clone whose class C cannot be confirmed (unreadable where required,
    /// or not class C after setting it) is not published by a patch; the
    /// whole write publishes instead and the file stays exact.
    @Test func anUnconfirmedProtectionClassFallsBackToAWholeWrite() async throws {
        let cases: [(String, (Int32) -> Int32, (Int32, Int32) -> Int32)] = [
            ("unreadable", { _ in errno = EINVAL; return -1 }, { _, _ in 0 }),
            ("set fails", { _ in 2 }, { _, _ in errno = EPERM; return -1 }),
            ("set does not stick", { _ in 2 }, { _, _ in 0 }),
        ]
        for (name, get, set) in cases {
            let fixture = Fixture()
            var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
            let writer = PatchingHistoryWriter(storage: fixture.storage)
            try writer.write(file)
            var calls = HistoryPatchCalls.system
            calls.requireProtection = true
            calls.protection = get
            calls.setProtection = set
            writer.calls = calls
            try grow(&file, "保护级别 \(name)")
            try writer.write(file)
            #expect(try writer.lastMode == .wholeAfterProtectionCheck && written(writer, fixture, equal: file), "\(name)")
        }
        // A different class that is set and confirmed lets the patch publish.
        let fixture = Fixture()
        var file = try await MainActor.run { try LongHistoryBenchmark.synthetic(messages: 120) }
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        try writer.write(file)
        var current: Int32 = 2
        var calls = HistoryPatchCalls.system
        calls.requireProtection = true
        calls.protection = { _ in current }
        calls.setProtection = { _, value in current = value; return 0 }
        writer.calls = calls
        try grow(&file, "设置后确认")
        try writer.write(file)
        #expect(try writer.lastMode == .patch && written(writer, fixture, equal: file))
    }

    /// The owner's gates are the same with the patching writer: a failed
    /// record keeps the event, marks storage dirty and fails the barrier; a
    /// failed transaction publishes nothing; an explicit flush restores
    /// storage and writes the latest state.
    @MainActor @Test func ownerGatesHoldWithThePatchingWriter() async throws {
        let fixture = Fixture()
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        let owner = HistoryOwner(file: .initial(selection: nil), store: writer)
        try owner.reset(to: owner.file)
        let primary = owner.file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "查天气")
        try owner.transact { try $0.acceptRoot(prompt, attachments: [], in: primary, scope: .general) }
        #expect(writer.lastMode == .patch)
        owner.barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        writer.calls = calls(.partialThenNoSpace)
        let before = try fixture.onDisk()
        let baseline = try #require(writer.published?.identity)
        #expect(throws: (any Error).self) {
            try owner.transact { try $0.editSession(primary) { $0.title = "不会发布" } }
        }
        #expect(owner.file.primary?.title != "不会发布" && owner.health == .ready)
        let reply = AgentTranscriptMessage(role: .assistant, text: "晴")
        let durable = owner.record(commit: .init(epoch: 1, messages: [reply.id: try CommittedMessage(reply)])) {
            try $0.appendEvent(reply, to: primary, root: prompt.id)
        }
        #expect(!durable && owner.file.primary?.messages.map(\.id) == [prompt.id, reply.id])
        guard case .saveDirty = owner.health else { Issue.record("expected dirty"); return }
        #expect(try fixture.onDisk() == before && fixture.leftovers.isEmpty)
        #expect(writer.published?.identity == baseline)
        await #expect(throws: StorageCommitError.self) {
            try await owner.barrier.wait(epoch: 1, .messages([reply.id: try MessageDigestDTO.requestDigest(reply)]))
        }
        writer.calls = .system
        try owner.flush()
        #expect(owner.health == .ready && writer.lastMode == .patch)
        #expect(try written(writer, fixture, equal: owner.file))
    }
}
