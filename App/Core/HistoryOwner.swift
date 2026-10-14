import AgentKit
import Foundation

nonisolated enum StorageHealth: Equatable, Sendable {
    case ready
    /// The current file could not be read; nothing may overwrite it until the
    /// user explicitly resets the namespace.
    case loadBlocked(String)
    /// Recorded events are newer than the file. New acceptance, transactions,
    /// sync and phone/model side effects stay blocked until a full write
    /// succeeds; a successful flush restores storage, never the stopped run.
    case saveDirty(String)

    var isReady: Bool { self == .ready }
    var message: String? {
        switch self {
        case .ready: nil
        case .loadBlocked(let detail): "历史读取失败，原文件已保留：\(detail)"
        case .saveDirty(let detail): "历史保存失败，后续执行已暂停：\(detail)"
        }
    }
}

nonisolated struct StorageBlocked: LocalizedError {
    let health: StorageHealth
    var errorDescription: String? { health.message ?? "历史存储不可用。" }
}

/// The single writer of the assistant-v1 history file. User operations are
/// transactions (copy the confirmed state, validate, write, publish; nothing
/// is published on failure). Run events are records: they already happened,
/// so they stay visible even when their write fails, which marks storage
/// dirty, fails every commit-barrier waiter and stops further effects.
@MainActor
final class HistoryOwner {
    private(set) var file: HistoryFile
    private(set) var health: StorageHealth
    let barrier = TranscriptCommitBarrier()
    private let writer: (Data) throws -> Void
    private let encoder = HistoryFileEncoder()
    /// Published after every state change (successful transaction or record).
    var onChange: (() -> Void)?
    /// Called once each time storage becomes dirty.
    var onStorageFailure: ((StorageCommitError) -> Void)?
    /// Encode + write duration of the last successful write, for diagnostics.
    private(set) var lastWriteSeconds: Double = 0

    init(file: HistoryFile, health: StorageHealth = .ready, writer: @escaping (Data) throws -> Void) {
        self.file = file; self.health = health; self.writer = writer
    }

    /// Commits made durable by one write, released only after it succeeds.
    struct BarrierCommit {
        var epoch: UInt64
        var messages: [UUID: CommittedMessage]
        var results: Set<TranscriptCommitBarrier.ResultKey> = []
    }

    @discardableResult
    func transact<Result>(commit: BarrierCommit? = nil, _ edit: (inout HistoryFile) throws -> Result) throws -> Result {
        guard health.isReady else { throw StorageBlocked(health: health) }
        var candidate = file
        let result = try edit(&candidate)
        try write(candidate)
        file = candidate
        if let commit { barrier.commit(epoch: commit.epoch, commit.messages, results: commit.results) }
        onChange?()
        return result
    }

    /// Applies an event that already happened, then writes the full state.
    /// Returns whether it is durable with storage ready.
    @discardableResult
    func record(commit: BarrierCommit? = nil, _ edit: (inout HistoryFile) throws -> Void) -> Bool {
        if case .loadBlocked = health { return false }
        var candidate = file
        do { try edit(&candidate) } catch {
            // An event that cannot be represented is a storage failure, not a silent drop.
            markDirty("事件无法记录：\(error.localizedDescription)")
            onChange?()
            return false
        }
        file = candidate
        let wasReady = health.isReady
        do {
            try write(candidate)
            // While dirty, a later event's successful write keeps the file
            // current but does not reopen storage: only an explicit flush does,
            // and epochs failed by the earlier error stay failed.
            if wasReady, let commit { barrier.commit(epoch: commit.epoch, commit.messages, results: commit.results) }
            onChange?()
            return wasReady
        } catch {
            markDirty(error.localizedDescription)
            onChange?()
            return false
        }
    }

    /// Explicit retry: writes the latest complete state. Does not resume anything.
    func flush() throws {
        if case .loadBlocked = health { throw StorageBlocked(health: health) }
        try write(file)
        health = .ready
        onChange?()
    }

    /// Writes a replacement computed while storage was unavailable (launch
    /// recovery) and publishes it only after the write succeeds.
    func flushReplacing(_ replacement: HistoryFile) throws {
        if case .loadBlocked = health { throw StorageBlocked(health: health) }
        try write(replacement)
        file = replacement
        health = .ready
        onChange?()
    }

    /// In-memory edit written by the next record/transaction/flush. Only for
    /// local draft text, which a later write includes.
    func replaceInMemory(_ edit: (inout HistoryFile) -> Void) {
        edit(&file)
        onChange?()
    }

    /// Explicit user reset after a load failure replaces the in-memory state;
    /// the caller has already moved the unreadable file aside.
    func reset(to initial: HistoryFile) throws {
        try write(initial)
        file = initial
        health = .ready
        onChange?()
    }

    private func write(_ candidate: HistoryFile) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let data = try encoder.encode(candidate)
        try writer(data)
        lastWriteSeconds = ProcessInfo.processInfo.systemUptime - started
    }

    private func markDirty(_ detail: String) {
        let wasReady = health.isReady
        health = .saveDirty(detail)
        barrier.failAll(.saveFailed(detail))
        if wasReady { onStorageFailure?(.saveFailed(detail)) }
    }
}
