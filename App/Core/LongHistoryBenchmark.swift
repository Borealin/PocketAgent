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

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Yields between samples and phases (never inside a write), so a long
    /// run does not hold the main actor for its whole duration.
    static func report(sizes: [Int], directory: URL, label: String) async throws -> Data {
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
            // Complete bytes: the file is exactly the published layout's whole
            // image, and decodes to the owner's state.
            let onDisk = try Data(contentsOf: storage.url)
            let bytesMatch = onDisk == store.published?.layout.image()
            let decodesToState = try HistoryCodec.decode(onDisk) == owner.file
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
                            "encodeSeconds": encode, "writeSeconds": write,
                            "decodeSeconds": decode, "roots": allRoots.count, "registerReadsSeconds": register,
                            "forgetPreviewSeconds": preview, "forgetClosureRoots": closure, "validateGraphSeconds": validate,
                            "firstRecordSeconds": firstRecord, "firstRecordMode": firstMode,
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
        return try JSONSerialization.data(withJSONObject: ["configuration": label, "results": results],
                                          options: [.prettyPrinted, .sortedKeys])
    }
}
