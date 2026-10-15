import AgentKit
import Foundation

/// Long-history measurement of the single-file write path with realistic
/// message shapes: encode/write/decode of the whole file, per-event record
/// p50/p95 through the production `PatchingHistoryWriter` (plan and file
/// write split, write mode, and a final check that the file is exactly the
/// published layout image), read registration and forget preview over the full root chain,
/// and transcript item building (full and the 400-message page). It runs on
/// a synthetic file in `directory` only; the app's history, owner and sync are
/// never touched. Used by the opt-in host test and, on a device, by the local
/// launch argument `-PocketAgentLongHistoryBenchmark` (report in Documents).
@MainActor
enum LongHistoryBenchmark {
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "长历史量测失败：\(detail)" }
    }

    static func synthetic(messages target: Int, attachmentsEvery: Int = 25) throws -> HistoryFile {
        var file = HistoryFile.initial(selection: ModelSelection(providerID: UUID(), modelID: "bench-model"))
        let primary = file.assistant.primarySessionID
        let elements = (1...30).map { index in
            ["node": index, "type": "Button", "label": "商品标题示例 \(index) 价格 ¥\(index * 13)",
             "enabled": true, "rect": ["x": 12, "y": index * 40, "width": 300, "height": 36]] as [String: Any]
        }
        let screen = String(decoding: try JSONSerialization.data(withJSONObject: [
            "ok": true, "screen": ["snapshot_id": 3, "app": "com.example.shop", "screen": ["width": 390, "height": 844],
                                   "elements": elements, "truncated": false]], options: [.sortedKeys]), as: UTF8.self)
        let reply = String(repeating: "根据当前页面，这是整理后的结论与下一步建议。", count: 12)
        var turn = 0
        var built: [AgentTranscriptMessage] = []
        var memberships: [(UUID, UUID)] = []
        var attachments: [String: [ChatAttachment]] = [:]
        while built.count < target {
            turn += 1
            let prompt = AgentTranscriptMessage(role: .user, text: "第 \(turn) 次：帮我在购物 App 里搜索蓝牙耳机并比较价格")
            let observe = AgentToolCall(id: "o\(turn)", name: "observe_screen", arguments: .object([:]))
            let tap = AgentToolCall(id: "t\(turn)", name: "tap", arguments: .object(["node": .number(3), "snapshot_id": .number(3)]))
            let a1 = AgentTranscriptMessage(role: .assistant, toolCalls: [observe])
            let r1 = AgentTranscriptMessage(role: .tool, text: screen, toolCallID: observe.id, toolName: observe.name)
            let a2 = AgentTranscriptMessage(role: .assistant, text: "点击第三个结果。", toolCalls: [tap])
            let r2 = AgentTranscriptMessage(role: .tool, text: screen, toolCallID: tap.id, toolName: tap.name)
            let final = AgentTranscriptMessage(role: .assistant, text: reply)
            for message in [prompt, a1, r1, a2, r2, final] { built.append(message); memberships.append((message.id, prompt.id)) }
            if turn % attachmentsEvery == 0 {
                attachments[prompt.id.uuidString] = [ChatAttachment(id: UUID(), mimeType: "image/jpeg", pixelWidth: 2048,
                                                                   pixelHeight: 1536, byteCount: 400_000)]
            }
        }
        file.sessions[0].messages = Array(built.prefix(target))
        file.sessions[0].attachments = attachments
        // Assistant-shaped read graph: each root read the previous root and a
        // saved memory, as a continuing primary line registers at dispatch.
        let memory = try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: "偏好：靠窗座位", origin: .panel,
                                                   sourceRootPromptIDs: [], sourceMessageIDs: []))
        var rootsSeen: Set<UUID> = []
        var previous: UUID?
        for (message, root) in memberships.prefix(target) {
            if rootsSeen.insert(root).inserted {
                var deps = RootDependencies(memoryReads: [MemoryReadRevision(entryID: memory.entryIDs[0], revision: 1)])
                if let previous { deps.rootReads = [previous] }
                try file.assistant.scopeIndex.addRoot(root, ScopedRoot(scope: .general, sourceSessionID: primary,
                    segmentDigest: "v1:placeholder", dependencies: deps, abandonedUnstarted: false,
                    dispatchAuthorized: true, verified: true))
                previous = root
            } else {
                try file.assistant.scopeIndex.addMember(message, root: root)
            }
        }
        return file
    }

    private static func seconds(_ block: () throws -> Void) rethrows -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        try block()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private static func stages(_ timing: HistoryWholeTiming?) -> Any {
        guard let t = timing else { return NSNull() }
        return ["createSeconds": t.create, "emitSeconds": t.emit, "writeSeconds": t.write, "writeCalls": t.writeCalls,
                "fsyncSeconds": t.fsync, "closeSeconds": t.close, "renameSeconds": t.rename, "statSeconds": t.stat,
                "totalSeconds": t.total]
    }

    /// The old whole path on the same layout, to a separate sandbox file:
    /// assembling the image, `Data.write(.atomic, class C)`, then `stat`.
    private static func foundationReference(_ layout: HistoryLayout, directory: URL) throws -> [String: Any] {
        let storage = HistoryStorage(url: directory.appendingPathComponent("reference.json"))
        var image = Data()
        let assemble = seconds { image = layout.image() }
        let write = try seconds { try storage.write(image) }
        var info = stat(), statOK = false
        let status = seconds { statOK = fstatat(AT_FDCWD, storage.url.path, &info, 0) == 0 }
        return ["imageSeconds": assemble, "atomicWriteSeconds": write, "statSeconds": status, "statOK": statOK,
                "totalSeconds": assemble + write + status, "bytes": image.count]
    }

    /// The region writer on the same final layout, to a separate sandbox file
    /// (no planning; paired with `foundationReference`).
    private static func regionPaired(_ layout: HistoryLayout, directory: URL) throws -> [String: Any] {
        let storage = HistoryStorage(url: directory.appendingPathComponent("paired.json"))
        let written = try storage.writeWhole(layout)
        guard var timing = stages(written.timing) as? [String: Any] else { throw Failure(detail: "paired: timing") }
        timing["statOK"] = written.identity != nil
        timing["bytes"] = layout.size
        return timing
    }

    /// The same image already in memory, through explicit calls to a separate
    /// sandbox file: exclusive create with class C, one pwrite loop, fsync,
    /// close, rename, fstatat. The I/O cost of this one strategy on this run.
    private static func syscallFloor(_ image: Data, directory: URL) throws -> [String: Any] {
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard dir >= 0 else { throw Failure(detail: "floor: directory") }
        defer { close(dir) }
        let temporary = ".floor-\(UUID().uuidString)"
        var mark = ProcessInfo.processInfo.systemUptime
        func lap() -> Double { let now = ProcessInfo.processInfo.systemUptime; defer { mark = now }; return now - mark }
        let fd = openat(dir, temporary, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(detail: "floor: create") }
        _ = fcntl(fd, F_SETPROTECTIONCLASS, HistoryStorage.protectionClass)
        let protected = fcntl(fd, F_GETPROTECTIONCLASS) == HistoryStorage.protectionClass
        // Where class C is required it must be confirmed, or the sample is not
        // a comparable durable write and nothing is published.
        if !protected && HistoryPatchCalls.protectionRequiredByPlatform {
            close(fd); unlinkat(dir, temporary, 0)
            return ["valid": false, "invalidReason": "class C not confirmed"]
        }
        let create = lap()
        var done = 0
        try image.withUnsafeBytes { bytes in
            while done < bytes.count {
                let written = pwrite(fd, bytes.baseAddress! + done, bytes.count - done, off_t(done))
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { close(fd); unlinkat(dir, temporary, 0); throw Failure(detail: "floor: pwrite") }
                done += written
            }
        }
        let write = lap()
        guard fsync(fd) == 0 else { close(fd); unlinkat(dir, temporary, 0); throw Failure(detail: "floor: fsync") }
        let sync = lap()
        guard close(fd) == 0 else { unlinkat(dir, temporary, 0); throw Failure(detail: "floor: close") }
        let closing = lap()
        guard renameat(dir, temporary, dir, "floor.json") == 0 else { unlinkat(dir, temporary, 0); throw Failure(detail: "floor: rename") }
        let rename = lap()
        var info = stat()
        let statOK = fstatat(dir, "floor.json", &info, AT_SYMLINK_NOFOLLOW) == 0
        let status = lap()
        return ["valid": true, "createSeconds": create, "writeSeconds": write, "fsyncSeconds": sync, "closeSeconds": closing,
                "renameSeconds": rename, "statSeconds": status, "statOK": statOK,
                "totalSeconds": create + write + sync + closing + rename + status,
                "classCConfirmed": protected, "bytes": done]
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Yields between samples and phases (never inside a write), so a long
    /// run does not hold the main actor for its whole duration.
    static func report(sizes: [Int], directory: URL, label: String) async throws -> Data {
        let started = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HistoryStorage(url: directory.appendingPathComponent("history.json"))
        var results: [[String: Any]] = []
        for size in sizes {
            await Task.yield()
            let file = try synthetic(messages: size)
            var data = Data()
            let encode = try seconds { data = try HistoryCodec.encode(file) }
            let write = try seconds { try storage.write(data) }
            var decoded: HistoryFile?
            let decode = try seconds { decoded = try HistoryCodec.decode(data) }
            guard decoded?.sessions[0].messages.count == size else { throw Failure(detail: "解码后消息数不符") }
            // The production writer: stable layout, changed ranges patched
            // into a clone of the published file.
            let store = PatchingHistoryWriter(storage: storage)
            let owner = HistoryOwner(file: file, store: store)
            let primary = file.assistant.primarySessionID
            guard let root = file.sessions[0].messages.last.flatMap({ file.assistant.scopeIndex.root(of: $0.id) }) else {
                throw Failure(detail: "缺少根")
            }
            // The first write after launch writes the whole file in the layout.
            let firstRecord = seconds {
                owner.record { try $0.appendEvent(AgentTranscriptMessage(role: .assistant, text: "预热"), to: primary, root: root) }
            }
            let firstMode = store.lastMode?.rawValue ?? "none"
            let firstSplit = (plan: store.lastPlanSeconds, write: store.lastWriteSeconds)
            let firstStages = stages(store.lastWholeTiming)
            var events: [Double] = [], plans: [Double] = [], writes: [Double] = [], changed: [Int] = []
            var modes: [String: Int] = [:]
            var durable = true
            for index in 0..<40 {
                await Task.yield()
                let event = AgentTranscriptMessage(role: .assistant, text: "事件 \(index)")
                var ok = false
                events.append(seconds { ok = owner.record { try $0.appendEvent(event, to: primary, root: root) } })
                durable = durable && ok && owner.health == .ready
                plans.append(store.lastPlanSeconds); writes.append(store.lastWriteSeconds); changed.append(store.lastChangedBytes)
                modes[store.lastMode?.rawValue ?? "none", default: 0] += 1
            }
            guard durable else { throw Failure(detail: "写入失败") }
            // Relaunch: the file read through one descriptor and strictly
            // decoded, proven to be this layout's image of that decoding
            // (launch cost, off the main actor in the app), then the first
            // record patches. Whole writes every 4 patches here, to time one.
            var source: HistoryLoadSource?
            let load = try seconds { source = try storage.loadForAdoption().source }
            guard let source else { throw Failure(detail: "启动读取未得到同一身份的字节") }
            var hydration: HistoryHydration?
            let hydrate = seconds { hydration = HistoryHydration.make(source) }
            let relaunched = PatchingHistoryWriter(storage: storage, wholeWriteEvery: 4)
            let launchedOwner = HistoryOwner(file: source.file, store: relaunched)
            guard let hydration, launchedOwner.adopt(hydration) else { throw Failure(detail: "启动文件未被采用") }
            var after: [(name: String, seconds: Double, mode: String, plan: Double, write: Double, bytes: Int, stages: Any)] = []
            func timed(_ name: String, _ edit: @escaping @Sendable (inout HistoryFile) throws -> Void) throws {
                var ok = false
                let elapsed = seconds { ok = launchedOwner.record(edit) }
                guard ok, launchedOwner.health == .ready else { throw Failure(detail: "\(name) 写入失败") }
                // Read right away: the next write replaces these.
                after.append((name, elapsed, relaunched.lastMode?.rawValue ?? "none", relaunched.lastPlanSeconds,
                              relaunched.lastWriteSeconds, relaunched.lastChangedBytes, stages(relaunched.lastWholeTiming)))
            }
            for index in 0..<5 {
                await Task.yield()
                try timed(index == 0 ? "firstAfterAdoption" : index == 4 ? "periodicWhole" : "patch") {
                    try $0.appendEvent(AgentTranscriptMessage(role: .assistant, text: "启动后 \(index)"), to: primary, root: root)
                }
            }
            // A warm whole write after an outside change: touching the file changes its identity.
            guard utimes(storage.url.path, nil) == 0 else { throw Failure(detail: "无法更新文件时间") }
            try timed("identityChangeWhole") {
                try $0.appendEvent(AgentTranscriptMessage(role: .assistant, text: "整体写"), to: primary, root: root)
            }
            for index in 0..<3 {
                await Task.yield()
                guard utimes(storage.url.path, nil) == 0 else { throw Failure(detail: "无法更新文件时间") }
                try timed("identityChangeWholeRepeat") {
                    try $0.appendEvent(AgentTranscriptMessage(role: .assistant, text: "整体写 \(index)"), to: primary, root: root)
                }
            }
            // A session added after the others, then outgrowing its capacity.
            let task = ChatSession(selection: nil, title: "量测任务")
            try timed("appendSession") { $0.sessions.append(task) }
            try timed("laterSessionOverflow") { file in
                try file.editSession(task.id) {
                    $0.messages.append(AgentTranscriptMessage(role: .user, text: String(repeating: "溢", count: 20_000)))
                }
            }
            let expected: [String: String] = ["firstAfterAdoption": "patch", "periodicWhole": "whole",
                                              "identityChangeWhole": "wholeAfterIdentityChange",
                                              "identityChangeWholeRepeat": "wholeAfterIdentityChange", "appendSession": "patch",
                                              "laterSessionOverflow": "patch"]
            guard after.allSatisfy({ path in expected[path.name].map { $0 == path.mode } ?? true }) else {
                throw Failure(detail: "写入方式与预期不符")
            }
            let paths = after.map { ["name": $0.name, "seconds": $0.seconds, "mode": $0.mode, "planSeconds": $0.plan,
                                     "writeSeconds": $0.write, "changedBytes": $0.bytes, "wholeStages": $0.stages] as [String: Any] }
            // The old whole path and the explicit-call floor on the same final
            // layout, separate sandbox files, after the production writes.
            guard let finalLayout = relaunched.published?.layout else { throw Failure(detail: "缺少发布的布局") }
            var references: [[String: Any]] = [], paired: [[String: Any]] = [], floors: [[String: Any]] = []
            for _ in 0..<3 {
                await Task.yield()
                references.append(try foundationReference(finalLayout, directory: directory))
                await Task.yield()
                paired.append(try regionPaired(finalLayout, directory: directory))
                await Task.yield()
                floors.append(try syscallFloor(finalLayout.image(), directory: directory))
            }
            // Complete bytes: the file is exactly the published layout's whole
            // image, and decodes to the owner's state.
            let onDisk = try Data(contentsOf: storage.url)
            let bytesMatch = onDisk == relaunched.published?.layout.image()
            let decodesToState = try HistoryCodec.decode(onDisk) == launchedOwner.file
            guard bytesMatch, decodesToState else { throw Failure(detail: "补丁后的文件与期望不一致") }
            // Read registration of a request whose context holds the chain of
            // every earlier root; then a forget preview whose closure spans it.
            let allRoots = file.sessions[0].messages.compactMap { message in
                file.assistant.scopeIndex.root(of: message.id).flatMap { $0 == message.id ? $0 : nil } }
            var graph = file
            let current = AgentTranscriptMessage(role: .user, text: "当前")
            try graph.acceptRoot(current, attachments: [], in: primary, scope: .general)
            let register = try seconds {
                try graph.registerReads(root: current.id, memory: [], roots: Array(allRoots.reversed()), messages: [])
            }
            guard let memoryID = graph.assistant.memory.active.first?.id else { throw Failure(detail: "缺少记忆") }
            var closure = 0
            let preview = try seconds { closure = try graph.forgetPreview([memoryID], activeRoot: current.id).affectedRootCount }
            let validate = try seconds { try ScopeIndex.validateGraph(graph.assistant.scopeIndex.roots) }
            var items: [TranscriptItem] = []
            let display = seconds { items = TranscriptItem.build(file.sessions[0].messages) }
            let tail = seconds { _ = TranscriptItem.build(Array(file.sessions[0].messages.suffix(400))) }
            results.append(["messages": size, "fileBytes": data.count, "layoutFileBytes": onDisk.count,
                            "firstRecordWholeStages": firstStages, "foundationReference": references,
                            "regionPaired": paired, "syscallFloor": floors, "finalLayoutBytes": finalLayout.size,
                            "encodeSeconds": encode, "writeSeconds": write,
                            "decodeSeconds": decode, "roots": allRoots.count, "registerReadsSeconds": register,
                            "forgetPreviewSeconds": preview, "forgetClosureRoots": closure, "validateGraphSeconds": validate,
                            "firstRecordSeconds": firstRecord, "firstRecordMode": firstMode,
                            "firstRecordPlanSeconds": firstSplit.plan, "firstRecordWriteSeconds": firstSplit.write,
                            "launchLoadSeconds": load, "hydrationSeconds": hydrate, "afterLaunchPaths": paths,
                            "recordP50Seconds": percentile(events, 0.5), "recordP95Seconds": percentile(events, 0.95),
                            "recordMaxSeconds": events.max() ?? 0,
                            "planP50Seconds": percentile(plans, 0.5), "planP95Seconds": percentile(plans, 0.95),
                            "fileWriteP50Seconds": percentile(writes, 0.5), "fileWriteP95Seconds": percentile(writes, 0.95),
                            "recordSamples": events, "planSamples": plans, "fileWriteSamples": writes,
                            "changedBytesSamples": changed, "modes": modes,
                            "everyEventDurableAndReady": durable, "fileBytesEqualPublishedImage": bytesMatch,
                            "fileDecodesToOwnerState": decodesToState,
                            "fullDisplayBuildSeconds": display,
                            "displayItems": items.count, "tail400DisplayBuildSeconds": tail])
        }
        let labels = [
            "encodeSeconds/writeSeconds": "generic codec encoding + HistoryStorage.write (Foundation .atomic), not the layout writer",
            "firstRecord/afterLaunchPaths": "production PatchingHistoryWriter; whole writes are the region writer (exclusive temp, class C, bounded buffer, fsync, close, rename)",
            "periodicWhole": "benchmark interval 4 (production 512)",
            "foundationReference": "old whole path on the same final layout: image() + Data.write(.atomic, class C) + stat, separate sandbox file",
            "regionPaired": "region writer on that same final layout, no planning, separate sandbox file; paired with foundationReference (production cold/periodic/identity writes are earlier, smaller layouts and include planning)",
            "syscallFloor": "the same image prebuilt in memory: one pwrite loop + fsync + close + rename + fstatat, separate sandbox file; this strategy on this run only",
            "memory": "not measured; the region writer's explicit buffer is 4 MiB (a bound, not a process measurement)",
        ]
        return try JSONSerialization.data(withJSONObject: ["configuration": label, "results": results, "labels": labels,
                                                           "runNonce": UUID().uuidString,
                                                           "startedAt": ISO8601DateFormatter().string(from: started),
                                                           "pid": Int(ProcessInfo.processInfo.processIdentifier)],
                                          options: [.prettyPrinted, .sortedKeys])
    }
}
