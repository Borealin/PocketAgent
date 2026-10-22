import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// The whole write streams the layout's pieces instead of assembling its image:
/// the published file must be exactly the image (and decode to the owner's
/// file for valid states), and any failure before the rename must leave the
/// published file, the writer's baseline and the directory as they were.
struct HistoryWholeWriteTests {
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa-whole-\(UUID().uuidString)")
        lazy var storage = HistoryStorage(url: directory.appendingPathComponent("history.json"))
        deinit { try? FileManager.default.removeItem(at: directory) }
        var leftovers: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0 != "history.json" }
        }
        func onDisk() throws -> Data { try Data(contentsOf: storage.url) }
    }

    @MainActor private static func sample() throws -> HistoryFile {
        var file = try LongHistoryBenchmark.synthetic(messages: 60)
        var task = ChatSession(selection: nil, title: "任务")
        task.messages = [AgentTranscriptMessage(role: .user, text: String(repeating: "大", count: 30_000)),
                         AgentTranscriptMessage(role: .assistant, text: "短")]
        file.sessions += [task, ChatSession(selection: nil, title: "空任务")]
        return file
    }

    private func calls(buffer: Int) -> HistoryPatchCalls {
        var calls = HistoryPatchCalls.system
        calls.wholeBufferSize = buffer
        return calls
    }

    /// Valid owner states across random edits, with buffers that put every
    /// piece kind on a buffer edge (one byte, a few bytes, small, default):
    /// the file is the image byte for byte and strictly decodes to the file.
    @Test func aWholeWriteIsExactlyTheImageAcrossEditsAndBufferSizes() async throws {
        var generator = Seeded(state: 11)
        var file = try await MainActor.run { try Self.sample() }
        let encoder = HistoryLayoutEncoder()
        var plan = try encoder.plan(file, baseline: nil)
        for step in 0..<24 {
            if step % 4 == 0 { await Task.yield() }
            let session = Int.random(in: 0..<file.sessions.count, using: &generator)
            switch Int.random(in: 0..<5, using: &generator) {
            case 0: file.sessions[session].messages.append(AgentTranscriptMessage(role: .assistant, text: "追加 \(step)"))
            case 1: file.sessions[session].draft = String(repeating: "草稿", count: Int.random(in: 0..<500, using: &generator))
            case 2: file.sessions.append(ChatSession(selection: nil, title: "新任务 \(step)"))
            case 3: file.sessions[session].messages.append(AgentTranscriptMessage(role: .user, text: String(repeating: "溢", count: 9_000)))
            default: file.deletedSessions.append(Tombstone(id: UUID(), deletedAt: Date(timeIntervalSince1970: Double(step))))
            }
            plan = try encoder.plan(file, baseline: plan.layout)
            let image = plan.layout.image()
            for buffer in [1, 7, 4096, 4 << 20] {
                let fixture = Fixture()
                let written = try fixture.storage.writeWhole(plan.layout, calls: calls(buffer: buffer))
                let bytes = try fixture.onDisk()
                #expect(bytes == image, "step \(step) buffer \(buffer)")
                #expect(try HistoryCodec.decode(bytes) == file, "step \(step) buffer \(buffer)")
                #expect(written.identity?.size == Int64(plan.layout.size))
                #expect(fixture.leftovers.isEmpty)
            }
        }
    }

    /// Internal layouts at the edges, compared with the image only (they are
    /// not all valid history files): no sessions, an empty session, a piece of
    /// exactly the buffer's size, pieces and capacity runs longer than it.
    @Test func edgeLayoutsAreWrittenByteForByte() async throws {
        let file = try await MainActor.run { try Self.sample() }
        let layout = try HistoryLayoutEncoder().plan(file, baseline: nil).layout
        let empty = HistoryLayout(sessions: [], tail: layout.tail)
        // An empty header (not produced by the codec today) is skipped, not
        // dereferenced; its capacity is all spaces.
        var hollow = layout
        hollow.sessions[0].header = Data()
        let fragment = try #require(layout.sessions[0].fragments.first)
        for (name, value, buffer) in [("no sessions", empty, 3), ("no sessions default", empty, 4 << 20),
                                      ("piece of exactly the buffer", layout, fragment.count),
                                      ("piece one over the buffer", layout, fragment.count - 1),
                                      ("long pieces and spaces", layout, 64), ("empty pieces", hollow, 5)] {
            let fixture = Fixture()
            let written = try fixture.storage.writeWhole(value, calls: calls(buffer: buffer))
            #expect(try fixture.onDisk() == value.image(), "\(name)")
            #expect(written.timing.writeCalls > 0 && written.timing.total > 0, "\(name)")
        }
        // Every capacity byte is a space, not a hole or a zero.
        let fixture = Fixture()
        _ = try fixture.storage.writeWhole(layout)
        #expect(try !fixture.onDisk().contains(0))
    }

    /// Empty data pieces between others write nothing and break nothing; a
    /// layout whose pieces do not add up to its size is refused unpublished.
    @Test func emptyPiecesAreSkippedAndAWrongSizeIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa-emit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pieces").path
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        #expect(fd >= 0)
        var calls = HistoryPatchCalls.system
        calls.wholeBufferSize = 3
        let emitter = HistoryLayoutEmitter(fd: fd, calls: calls)
        for piece: HistoryLayout.Piece in [.data(Data()), .byte(0x5B), .data(Data()), .data(Data("abcd".utf8)), .spaces(0),
                                           .data(Data()), .spaces(4), .byte(0x5D), .data(Data())] {
            try emitter.add(piece)
        }
        try emitter.flush()
        close(fd)
        #expect(emitter.offset == 10)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("[abcd    ]".utf8))
        // A layout whose pieces are one byte longer than its size.
        let file = try await MainActor.run { try Self.sample() }
        var wrong = try HistoryLayoutEncoder().plan(file, baseline: nil).layout
        wrong.sessions[0].fragments.insert(Data(), at: 0)
        let fixture = Fixture()
        #expect(throws: HistoryPatchError.failed("size", EIO)) { _ = try fixture.storage.writeWhole(wrong) }
        #expect(fixture.leftovers.isEmpty && !FileManager.default.fileExists(atPath: fixture.storage.url.path))
    }

    private enum Fault: CaseIterable {
        case create, protectionUnreadable, protectionNotSet, partialThenNoSpace, wroteNothing, fsync, close, rename
    }

    private func inject(_ fault: Fault, into calls: inout HistoryPatchCalls) {
        switch fault {
        case .create:
            calls.create = { _, _ in errno = EACCES; return -1 }
        case .protectionUnreadable:
            calls.requireProtection = true
            calls.protection = { _ in errno = EINVAL; return -1 }
        case .protectionNotSet:
            calls.protection = { _ in 2 }
            calls.setProtection = { _, _ in 0 }
        case .partialThenNoSpace:
            var count = 0
            calls.pwrite = { fd, bytes, length, offset in
                count += 1
                if count == 1 { return Darwin.pwrite(fd, bytes, max(1, length / 2), offset) }
                errno = ENOSPC; return -1
            }
        case .wroteNothing:
            calls.pwrite = { _, _, _, _ in errno = 0; return 0 }
        case .fsync:
            calls.fsync = { _ in errno = EIO; return -1 }
        case .close:
            // The descriptor is really closed; only the result is an error.
            calls.close = { fd in _ = Darwin.close(fd); errno = EIO; return -1 }
        case .rename:
            calls.rename = { _, _, _ in errno = EIO; return -1 }
        }
    }

    /// The writer's next write is whole (the file's identity changed), and it
    /// fails: the file keeps its bytes, the baseline its identity, nothing is
    /// left in the directory, and the retry without the fault succeeds.
    @Test func failuresBeforeTheRenameLeaveTheFileAndBaselineUntouched() async throws {
        for fault in Fault.allCases {
            let fixture = Fixture()
            var file = try await MainActor.run { try Self.sample() }
            let writer = PatchingHistoryWriter(storage: fixture.storage)
            try writer.write(file)
            guard utimes(fixture.storage.url.path, nil) == 0 else { Issue.record("utimes"); return }
            let before = try fixture.onDisk()
            let baseline = writer.published?.identity
            var calls = HistoryPatchCalls.system
            inject(fault, into: &calls)
            writer.calls = calls
            try file.editSession(file.assistant.primarySessionID) {
                $0.messages.append(AgentTranscriptMessage(role: .assistant, text: "失败的整体写"))
            }
            #expect(throws: HistoryPatchError.self, "\(fault)") { try writer.write(file) }
            #expect(try fixture.onDisk() == before, "\(fault)")
            #expect(writer.published?.identity == baseline, "\(fault)")
            #expect(fixture.leftovers.isEmpty, "\(fault)")
            writer.calls = .system
            try writer.write(file)
            #expect(writer.lastMode == .wholeAfterIdentityChange, "\(fault)")
            #expect(try fixture.onDisk() == writer.published?.layout.image(), "\(fault)")
            #expect(try HistoryCodec.decode(fixture.onDisk()) == file, "\(fault)")
        }
    }

    @Test func aZeroByteWriteReportsItsOwnCause() async throws {
        let fixture = Fixture()
        let layout = try HistoryLayoutEncoder().plan(HistoryFile.initial(selection: nil), baseline: nil).layout
        var calls = HistoryPatchCalls.system
        inject(.wroteNothing, into: &calls)
        #expect(throws: HistoryPatchError.failed("pwrite wrote nothing", EIO)) {
            _ = try fixture.storage.writeWhole(layout, calls: calls)
        }
        #expect(fixture.leftovers.isEmpty)
    }

    @Test func shortAndInterruptedWritesComplete() async throws {
        let file = try await MainActor.run { try Self.sample() }
        let layout = try HistoryLayoutEncoder().plan(file, baseline: nil).layout
        var interruptedWrite = false, interruptedSync = false
        var calls = HistoryPatchCalls.system
        calls.wholeBufferSize = 4096
        calls.pwrite = { fd, bytes, count, offset in
            if !interruptedWrite { interruptedWrite = true; errno = EINTR; return -1 }
            return Darwin.pwrite(fd, bytes, max(1, count / 3), offset)
        }
        calls.fsync = { fd in
            if !interruptedSync { interruptedSync = true; errno = EINTR; return -1 }
            return Darwin.fsync(fd)
        }
        let fixture = Fixture()
        _ = try fixture.storage.writeWhole(layout, calls: calls)
        #expect(try fixture.onDisk() == layout.image())
        #expect(interruptedWrite && interruptedSync)
    }

    /// After the rename nothing throws: an unreadable published status gives
    /// no identity, and the next write is whole again.
    @Test func anUnreadablePublishedStatusDoesNotThrow() async throws {
        let fixture = Fixture()
        var file = try await MainActor.run { try Self.sample() }
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        var calls = HistoryPatchCalls.system
        calls.publishedStat = { _, _, _ in errno = EIO; return -1 }
        writer.calls = calls
        try writer.write(file)
        #expect(writer.published?.identity == nil)
        #expect(try fixture.onDisk() == writer.published?.layout.image())
        writer.calls = .system
        try file.editSession(file.assistant.primarySessionID) {
            $0.messages.append(AgentTranscriptMessage(role: .assistant, text: "之后"))
        }
        try writer.write(file)
        #expect(writer.lastMode == .whole)
        #expect(try HistoryCodec.decode(fixture.onDisk()) == file)
    }

    @Test func aNewWriterRemovesWholeWriteTemporariesLeftByAnEndedProcess() async throws {
        let fixture = Fixture()
        let file = try await MainActor.run { try Self.sample() }
        try PatchingHistoryWriter(storage: fixture.storage).write(file)
        let stale = fixture.directory.appendingPathComponent(".history.json.whole-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: stale.path, contents: Data("x".utf8)))
        _ = PatchingHistoryWriter(storage: fixture.storage)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try HistoryCodec.decode(fixture.onDisk()) == file)
    }

    /// A failed whole write makes the owner's storage dirty, as any failed
    /// write does; nothing it holds is published.
    @MainActor @Test func aFailedWholeWriteMakesTheOwnerDirty() throws {
        let fixture = Fixture()
        let file = try Self.sample()
        let writer = PatchingHistoryWriter(storage: fixture.storage)
        var calls = HistoryPatchCalls.system
        inject(.partialThenNoSpace, into: &calls)
        writer.calls = calls
        let owner = HistoryOwner(file: file, store: writer)
        let durable = owner.record { try $0.editSession($0.assistant.primarySessionID) { $0.detail = "失败" } }
        #expect(!durable)
        #expect(!owner.health.isReady)
        #expect(writer.published == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.url.path))
        #expect(fixture.leftovers.isEmpty)
    }
}
