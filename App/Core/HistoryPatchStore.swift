import Foundation

/// What identifies the exact file this writer last published. Any write to
/// the file changes its modification and change times; a replacement changes
/// its inode.
nonisolated struct HistoryFileIdentity: Equatable, Sendable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modified: timespec
    var changed: timespec

    init(_ info: stat) {
        device = Int64(info.st_dev); inode = info.st_ino; size = info.st_size
        modified = info.st_mtimespec; changed = info.st_ctimespec
    }

    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size
            && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
            && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
}

/// The system calls of a patch write, replaceable in tests to inject
/// failures (ENOSPC, short writes, EINTR, rename failure, no cloning).
nonisolated struct HistoryPatchCalls: @unchecked Sendable {
    var clone: (_ source: Int32, _ directory: Int32, _ name: String) -> Int32 = { fclonefileat($0, $1, $2, 0) }
    var pwrite: (_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ offset: off_t) -> Int = { Darwin.pwrite($0, $1, $2, $3) }
    var fsync: (_ fd: Int32) -> Int32 = { Darwin.fsync($0) }
    var rename: (_ directory: Int32, _ from: String, _ to: String) -> Int32 = { renameat($0, $1, $0, $2) }
    var protection: (_ fd: Int32) -> Int32 = { fcntl($0, F_GETPROTECTIONCLASS) }
    var setProtection: (_ fd: Int32, _ value: Int32) -> Int32 = { fcntl($0, F_SETPROTECTIONCLASS, $1) }
    /// On iOS a clone whose protection class cannot be confirmed as class C
    /// is never published by a patch (the whole write sets it instead). The
    /// macOS host may not report classes; tests can require it there too.
    var requireProtection = HistoryPatchCalls.protectionRequiredByPlatform
    /// Runs after the clone and before any byte is written (tests only).
    var afterClone: () -> Void = {}
    static let system = HistoryPatchCalls()
    #if os(iOS)
    static let protectionRequiredByPlatform = true
    #else
    static let protectionRequiredByPlatform = false
    #endif
}

nonisolated enum HistoryPatchError: Error, Equatable {
    /// The file is not the one this writer last published, before or after
    /// cloning: write the whole file instead.
    case identityChanged
    /// The volume cannot clone: write the whole file and stop patching.
    case cloningUnsupported
    /// The clone's protection class could not be confirmed as class C:
    /// write the whole file (which sets it).
    case protectionUnconfirmed
    case failed(String, Int32)
}

extension HistoryStorage {
    /// Data protection class C (`completeUntilFirstUserAuthentication`).
    static let protectionClass: Int32 = 3

    /// The whole file through the atomic write, then its identity (nil when
    /// it cannot be read after publication; never throws after the rename).
    func writeWhole(_ data: Data) throws -> HistoryFileIdentity? {
        try write(data)
        var info = stat()
        return stat(url.path, &info) == 0 ? HistoryFileIdentity(info) : nil
    }

    /// Clones the published file, overwrites `chunks` in the clone, fsyncs
    /// it and renames it over the file. Before the rename every failure
    /// removes the clone and leaves the file untouched; the rename is the
    /// commit. Returns the new identity, nil when it cannot be read after the
    /// rename.
    func writePatch(_ chunks: [HistoryLayoutEncoder.Chunk], size: Int, expected: HistoryFileIdentity,
                    calls: HistoryPatchCalls = .system) throws -> HistoryFileIdentity? {
        func failure(_ step: String) -> HistoryPatchError { .failed(step, errno) }
        let directoryPath = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let directory = open(directoryPath, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw failure("open directory") }
        defer { close(directory) }
        let source = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { throw HistoryPatchError.identityChanged }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0 else { throw failure("fstat") }
        guard HistoryFileIdentity(info) == expected, Int(info.st_size) == size else { throw HistoryPatchError.identityChanged }
        let temporary = ".\(name).patch-\(UUID().uuidString)"
        guard calls.clone(source, directory, temporary) == 0 else {
            if errno == ENOTSUP || errno == EXDEV { throw HistoryPatchError.cloningUnsupported }
            throw failure("clone")
        }
        var committed = false
        defer { if !committed { unlinkat(directory, temporary, 0) } }
        calls.afterClone()
        guard fstat(source, &info) == 0 else { throw failure("fstat") }
        guard HistoryFileIdentity(info) == expected else { throw HistoryPatchError.identityChanged }
        let target = openat(directory, temporary, O_RDWR | O_NOFOLLOW)
        guard target >= 0 else { throw failure("open clone") }
        var open = true
        defer { if open { close(target) } }
        var cloned = stat()
        guard fstat(target, &cloned) == 0, cloned.st_size == info.st_size else { throw failure("clone size") }
        let current = calls.protection(target)
        if current < 0 {
            if calls.requireProtection { throw HistoryPatchError.protectionUnconfirmed }
        } else if current != Self.protectionClass {
            guard calls.setProtection(target, Self.protectionClass) == 0, calls.protection(target) == Self.protectionClass else {
                throw HistoryPatchError.protectionUnconfirmed
            }
        }
        for chunk in chunks {
            guard chunk.offset >= 0, chunk.offset + chunk.bytes.count <= size else { throw failure("chunk range") }
            try chunk.bytes.withUnsafeBytes { bytes in
                var done = 0
                while done < bytes.count {
                    let written = calls.pwrite(target, bytes.baseAddress! + done, bytes.count - done, off_t(chunk.offset + done))
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw failure("pwrite") }
                    done += written
                }
            }
        }
        while calls.fsync(target) != 0 {
            guard errno == EINTR else { throw failure("fsync") }
        }
        open = false
        guard close(target) == 0 else { throw failure("close") }
        guard calls.rename(directory, temporary, name) == 0 else { throw failure("rename") }
        committed = true
        var published = stat()
        return fstatat(directory, name, &published, AT_SYMLINK_NOFOLLOW) == 0 ? HistoryFileIdentity(published) : nil
    }
}

/// Writes the history file in the stable layout: only the changed ranges
/// when the file is still exactly the one this writer last published,
/// otherwise the whole file. The published layout and identity change only
/// after a write is published.
nonisolated final class PatchingHistoryWriter {
    /// Whole rewrites at least this often, so nothing the identity check
    /// cannot see persists indefinitely.
    static let patchesPerWholeWrite = 512

    enum Mode: String, Sendable { case patch, whole, wholeAfterIdentityChange, wholeWithoutCloning, wholeAfterProtectionCheck }

    let storage: HistoryStorage
    var calls: HistoryPatchCalls
    private let encoder = HistoryLayoutEncoder()
    private(set) var published: (layout: HistoryLayout, identity: HistoryFileIdentity?)?
    private var patches = 0
    private var cloning = true
    /// Diagnostics of the last successful write.
    private(set) var lastMode: Mode?
    private(set) var lastPlanSeconds = 0.0
    private(set) var lastWriteSeconds = 0.0
    private(set) var lastChangedBytes = 0

    /// The one writer of `storage`. A clone left by a process that ended
    /// between cloning and renaming would keep the old file's blocks alive;
    /// with no write in flight yet, it is removed here.
    init(storage: HistoryStorage, calls: HistoryPatchCalls = .system) {
        self.storage = storage; self.calls = calls
        let directory = storage.url.deletingLastPathComponent()
        let prefix = ".\(storage.url.lastPathComponent).patch-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func write(_ file: HistoryFile) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let plan = try encoder.plan(file, baseline: published?.layout)
        let planned = ProcessInfo.processInfo.systemUptime
        var mode = Mode.whole
        if let chunks = plan.chunks, let identity = published?.identity, cloning, patches < Self.patchesPerWholeWrite {
            do {
                let next = try storage.writePatch(chunks, size: plan.layout.size, expected: identity, calls: calls)
                record(plan.layout, next, mode: .patch, changed: chunks.reduce(0) { $0 + $1.bytes.count },
                       started: started, planned: planned)
                patches += 1
                return
            } catch HistoryPatchError.identityChanged {
                mode = .wholeAfterIdentityChange
            } catch HistoryPatchError.cloningUnsupported {
                cloning = false
                mode = .wholeWithoutCloning
            } catch HistoryPatchError.protectionUnconfirmed {
                mode = .wholeAfterProtectionCheck
            }
        }
        let image = plan.layout.image()
        let next = try storage.writeWhole(image)
        record(plan.layout, next, mode: mode, changed: image.count, started: started, planned: planned)
        patches = 0
    }

    /// The file has been replaced; only now does the baseline move.
    private func record(_ layout: HistoryLayout, _ identity: HistoryFileIdentity?, mode: Mode, changed: Int,
                        started: Double, planned: Double) {
        published = (layout, identity)
        lastMode = mode
        lastChangedBytes = changed
        lastPlanSeconds = planned - started
        lastWriteSeconds = ProcessInfo.processInfo.systemUptime - planned
    }
}
