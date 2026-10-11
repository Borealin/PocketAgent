import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Coordinated read-merge-write of one snapshot file inside a folder the user
/// picked (typically in iCloud Drive). No ubiquity container entitlement.
enum FolderSync {
    static let fileName = "PocketAgent-Sync.json"

    struct Outcome: Sendable {
        var plan: SyncPlan
        var refreshedBookmark: Data?
    }

    static func run(bookmark: Data, local: PortableSnapshot, deferred: Set<UUID>) throws -> Outcome {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else { throw failure("无法访问同步文件夹，请重新选择。") }
        defer { folder.stopAccessingSecurityScopedResource() }
        let refreshed = stale ? try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        let file = folder.appendingPathComponent(fileName)
        let placeholder = folder.appendingPathComponent(".\(fileName).icloud")
        if !FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            throw SyncError.notDownloaded
        }
        var coordinationError: NSError?
        var result: Result<SyncPlan, any Error> = .failure(failure("同步文件协调未执行。"))
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forMerging,
                                                         error: &coordinationError) { url in
            result = Result {
                var remote: PortableSnapshot?
                var conflicts: [NSFileVersion] = []
                var conflictSnapshots: [PortableSnapshot] = []
                if FileManager.default.fileExists(atPath: url.path) {
                    let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                    if status == .notDownloaded {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                        throw SyncError.notDownloaded
                    }
                    remote = try PortableCodec.decode(read(url))
                    // iCloud keeps competing writes from other devices as
                    // conflict versions; every one is merged. Any unreadable or
                    // newer version fails the round before anything is written.
                    conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
                    conflictSnapshots = try conflicts.map { try PortableCodec.decode(read($0.url)) }
                }
                let plan = SyncPlan.make(local: local, remote: remote, conflictVersions: conflictSnapshots, deferred: deferred)
                if let output = plan.output { try PortableCodec.encode(output).write(to: url, options: .atomic) }
                // Only after the merged result is durable: drop the other
                // versions, then mark the conflicts resolved (Apple: last).
                if !conflicts.isEmpty {
                    try NSFileVersion.removeOtherVersionsOfItem(at: url)
                    for version in conflicts { version.isResolved = true }
                }
                return plan
            }
        }
        if let coordinationError { throw coordinationError }
        return Outcome(plan: try result.get(), refreshedBookmark: refreshed)
    }

    private static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw SyncError.unreadable(error.localizedDescription) }
    }
}

@MainActor
final class SyncCoordinator: ObservableObject {
    nonisolated static let defaultFolderName = "PocketAgent"
    @Published private(set) var folderName: String?
    @Published private(set) var status = "首次启用时，在 iCloud Drive 选择位置；自动创建 PocketAgent 文件夹。"
    @Published private(set) var syncing = false
    @Published private(set) var connecting = false
    private let chat: ChatController
    private let providers: ProviderStore
    private let bookmarkURL = applicationSupport.appendingPathComponent("sync-folder.bookmark")
    private var rerun = false
    private var lastAttempt = Date.distantPast
    /// Bumped whenever the folder is chosen or disconnected; a round started
    /// for an older connection never applies, stores a bookmark or reports.
    private var generation = 0

    init(chat: ChatController, providers: ProviderStore) {
        self.chat = chat; self.providers = providers
        if let bookmark = try? Data(contentsOf: bookmarkURL) {
            var stale = false
            folderName = (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))?
                .lastPathComponent
            status = folderName == nil ? "同步文件夹不可用，请重新选择。" : "已恢复同步位置，自动同步已开启。"
        }
    }

    var isConfigured: Bool { FileManager.default.fileExists(atPath: bookmarkURL.path) }

    /// Default setup creates only our named child after the picker grants access.
    /// Existing bookmarks and explicit replacement folders keep their exact path.
    func chooseFolder(_ url: URL, initializeDefault: Bool = false) {
        guard !connecting else { return }
        generation += 1
        let connection = generation
        connecting = true
        status = initializeDefault ? "正在创建默认同步文件夹…" : "正在连接同步文件夹…"
        Task {
            defer { connecting = false }
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let folder = initializeDefault && url.lastPathComponent != Self.defaultFolderName
                        ? url.appendingPathComponent(Self.defaultFolderName, isDirectory: true) : url
                    if initializeDefault {
                        var coordinationError: NSError?
                        var result: Result<Void, any Error> = .failure(failure("文件夹初始化未执行。"))
                        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging,
                                                       error: &coordinationError) { target in
                            result = Result {
                                if FileManager.default.fileExists(atPath: target.path) {
                                    let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                                        throw failure("PocketAgent 已被同名文件占用，请选择其他位置。")
                                    }
                                } else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                            }
                        }
                        if let coordinationError { throw coordinationError }
                        try result.get()
                    }
                    let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    return (bookmark, folder.lastPathComponent)
                }.value
                guard connection == generation else { return }
                try storeBookmark(prepared.0)
                folderName = prepared.1
                status = "位置已保存，自动同步已开启。"
                await syncNow()
            } catch {
                guard connection == generation else { return }
                status = "无法初始化同步位置：\(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        generation += 1
        try? FileManager.default.removeItem(at: bookmarkURL)
        folderName = nil
        status = "已停止同步；本机数据保持不变。"
    }

    /// Opportunistic sync when the app returns to the foreground.
    func foreground() {
        guard isConfigured, !syncing, !connecting, Date().timeIntervalSince(lastAttempt) > 60 else { return }
        Task { await syncNow() }
    }

    /// Overlapping requests are serialized: a request during a running sync
    /// schedules exactly one more round after it.
    func syncNow() async {
        guard !syncing else { rerun = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            rerun = false
            lastAttempt = Date()
            await round()
        } while rerun
    }

    private func round() async {
        guard let bookmark = try? Data(contentsOf: bookmarkURL) else { status = "未选择同步文件夹。"; return }
        guard chat.storageError.isEmpty, providers.storageError.isEmpty else {
            status = "本地数据读取失败，已暂停同步以免覆盖。"; return
        }
        let connection = generation
        let deferred = chat.activeSessionIDs
        let base = PortableSnapshot(sessions: chat.sessions, sessionTombstones: chat.deletedSessions,
                                    providers: providers.providers, providerTombstones: providers.deletedProviders)
        status = "正在同步…"
        do {
            let outcome = try await Task.detached(priority: .utility) {
                try FolderSync.run(bookmark: bookmark, local: base, deferred: deferred)
            }.value
            guard connection == generation else { return }
            if let refreshed = outcome.refreshedBookmark { try? storeBookmark(refreshed) }
            // Never executes synced work: merged sessions arrive idle or keep local state.
            let skipped = chat.applySync(merged: outcome.plan.merged, base: base,
                                       deferred: deferred.union(chat.activeSessionIDs))
            providers.applySync(merged: outcome.plan.merged, base: base)
            let time = Date().formatted(date: .omitted, time: .shortened)
            status = skipped > 0 ? "已同步 \(time)；\(skipped) 个会话在本机任务结束后再合并。" : "已同步 \(time)。"
            if skipped > 0 { rerunWhenIdle() }
        } catch {
            guard connection == generation else { return }
            status = "同步失败：\(error.localizedDescription)"
        }
    }

    private func rerunWhenIdle() {
        chat.onIdle = { [weak self] in
            guard let self, isConfigured else { return }
            Task { await self.syncNow() }
        }
    }

    private func storeBookmark(_ data: Data) throws {
        var url = bookmarkURL
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    var title = "选择文件夹"
    let onPick: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.title = title
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
