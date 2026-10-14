import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Opt-in measurement of the single-file write path with realistic message
/// shapes. Set POCKETAGENT_BENCH_OUT to a JSON path outside the repository;
/// without it the test does nothing. Numbers are host measurements, not
/// device acceptance.
@MainActor
struct LongHistoryBenchmarkTests {
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

    @Test func measureWritePath() throws {
        guard let output = ProcessInfo.processInfo.environment["POCKETAGENT_BENCH_OUT"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HistoryStorage(url: directory.appendingPathComponent("history.json"))
        var results: [[String: Any]] = []
        for size in [10_000, 50_000] {
            let file = try Self.synthetic(messages: size)
            var data = Data()
            let encode = try Self.seconds { data = try HistoryCodec.encode(file) }
            let write = try Self.seconds { try storage.write(data) }
            var decoded: HistoryFile?
            let decode = try Self.seconds { decoded = try HistoryCodec.decode(data) }
            #expect(decoded?.sessions[0].messages.count == size)
            let owner = HistoryOwner(file: file, writer: { try storage.write($0) })
            let primary = file.assistant.primarySessionID
            let root = try #require(file.sessions[0].messages.last.flatMap { file.assistant.scopeIndex.root(of: $0.id) })
            // The first write after launch encodes every message once.
            let firstRecord = Self.seconds {
                owner.record { try $0.appendEvent(AgentTranscriptMessage(role: .assistant, text: "预热"), to: primary, root: root) }
            }
            var events: [Double] = []
            for index in 0..<20 {
                let event = AgentTranscriptMessage(role: .assistant, text: "事件 \(index)")
                events.append(Self.seconds {
                    owner.record { try $0.appendEvent(event, to: primary, root: root) }
                })
            }
            #expect(owner.health == .ready)
            // Read registration of a request whose context holds 20 raw roots
            // and a summary covering every earlier root; then a forget preview
            // whose closure spans the whole chain.
            let allRoots = file.sessions[0].messages.compactMap { message in
                file.assistant.scopeIndex.root(of: message.id).flatMap { $0 == message.id ? $0 : nil } }
            var graph = file
            let current = AgentTranscriptMessage(role: .user, text: "当前")
            try graph.acceptRoot(current, attachments: [], in: primary, scope: .general)
            let register = try Self.seconds {
                try graph.registerReads(root: current.id, memory: [], roots: Array(allRoots.reversed()), messages: [])
            }
            #expect(graph.assistant.scopeIndex.scopedRoot(current.id)?.dependencies.rootReads.count == 1)
            let memoryID = try #require(graph.assistant.memory.active.first?.id)
            var closure = 0
            let preview = try Self.seconds { closure = try graph.forgetPreview([memoryID], activeRoot: current.id).affectedRootCount }
            let validate = try Self.seconds { try ScopeIndex.validateGraph(graph.assistant.scopeIndex.roots) }
            var items: [TranscriptItem] = []
            let display = Self.seconds { items = TranscriptItem.build(file.sessions[0].messages) }
            let tail = Self.seconds { _ = TranscriptItem.build(Array(file.sessions[0].messages.suffix(400))) }
            results.append(["messages": size, "fileBytes": data.count, "encodeSeconds": encode, "writeSeconds": write,
                            "decodeSeconds": decode, "roots": allRoots.count, "registerReadsSeconds": register,
                            "forgetPreviewSeconds": preview, "forgetClosureRoots": closure, "validateGraphSeconds": validate,
                            "recordP50Seconds": Self.percentile(events, 0.5),
                            "recordP95Seconds": Self.percentile(events, 0.95), "firstRecordSeconds": firstRecord,
                            "fullDisplayBuildSeconds": display,
                            "displayItems": items.count, "tail400DisplayBuildSeconds": tail])
        }
        let report: [String: Any] = ["host": ProcessInfo.processInfo.hostName.isEmpty ? "mac" : "mac",
                                     "configuration": ProcessInfo.processInfo.environment["POCKETAGENT_BENCH_CONFIG"] ?? "swift test", "results": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
