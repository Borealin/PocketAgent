import AgentKit
import Darwin
import Foundation
import Network
import Testing
@testable import PocketAgentCore

/// Temporary project plus an "outside" directory standing in for the rest of
/// the app container (pairing record, history).
private struct Sandbox {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("pa-cap-" + UUID().uuidString)
    var root: URL { base.appendingPathComponent("project") }
    var outside: URL { base.appendingPathComponent("outside") }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("SECRET".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    }
    func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

struct WorkspaceConfinementTests {
    @Test func traversalAndAbsolutePathsAreRejected() throws {
        let box = try Sandbox()
        let files = try WorkspaceFiles(root: box.root)
        for path in ["../outside/secret.txt", "a/../../outside/secret.txt", "/etc/hosts", "~/x", box.outside.path + "/secret.txt"] {
            #expect(throws: WorkspaceError.self) { try files.read(path) }
            #expect(throws: WorkspaceError.self) { try files.write(path, content: "x") }
        }
        #expect(try String(contentsOf: box.outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "SECRET")
    }

    @Test func symbolicLinksOutOfTheProjectAreNeverFollowed() throws {
        let box = try Sandbox()
        try box.write("ok.txt", "inside")
        try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent("link.txt"),
                                                   withDestinationURL: box.outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent("dir"), withDestinationURL: box.outside)
        let files = try WorkspaceFiles(root: box.root)
        #expect(throws: WorkspaceError.outsideWorkspace("link.txt")) { try files.read("link.txt") }
        #expect(throws: WorkspaceError.outsideWorkspace("dir")) { try files.read("dir/secret.txt") }
        #expect(throws: WorkspaceError.outsideWorkspace("dir")) { try files.write("dir/new.txt", content: "x") }
        #expect(throws: WorkspaceError.notAFile("link.txt")) { try files.write("link.txt", content: "overwrite") }
        #expect(throws: WorkspaceError.self) { try files.patch("link.txt", edits: [.init(old: "SECRET", new: "x")]) }
        // Listing shows the links but recursion and search never enter them.
        let listing = try files.list(".", recursive: true)
        #expect(listing.entries.contains { $0.path == "dir" && $0.isLink })
        #expect(!listing.entries.contains { $0.path.hasPrefix("dir/") })
        #expect(try files.search("SECRET").matches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("new.txt").path))
        #expect(try String(contentsOf: box.outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "SECRET")
        try WorkspacePaths(root: box.root).remove("dir")
        #expect(FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("secret.txt").path))
    }

    /// A concurrently running guest swaps an intermediate directory for a
    /// link to the outside while the host reads; no read may escape.
    @Test func concurrentParentSwapCannotEscape() throws {
        let box = try Sandbox()
        try box.write("parent/file", "inside")
        try Data("OUTSIDE".utf8).write(to: box.outside.appendingPathComponent("file"))
        let paths = try WorkspacePaths(root: box.root)
        let parent = box.root.appendingPathComponent("parent").path, parked = box.root.appendingPathComponent("parked").path
        let outside = box.outside.path
        // Keep both entries present. A rename/unlink gap lets a legitimate
        // write create a new parent, stranding the original file at parked
        // and turning all later reads into not-found errors.
        try FileManager.default.createSymbolicLink(atPath: parked, withDestinationPath: outside)
        #expect(try paths.readFile("parent/file", limit: 64) == Data("inside".utf8))
        let stop = Atomic()
        let swaps = Counter(), swapErrors = Counter()
        let swapper = Thread {
            while !stop.value {
                if renameatx_np(AT_FDCWD, parent, AT_FDCWD, parked, UInt32(RENAME_SWAP)) != 0 {
                    swapErrors.increment(); break
                }
                swaps.increment()
                usleep(5)
                if renameatx_np(AT_FDCWD, parent, AT_FDCWD, parked, UInt32(RENAME_SWAP)) != 0 {
                    swapErrors.increment(); break
                }
                usleep(5)
            }
        }
        swapper.start()
        var escaped = 0, reads = 0
        for _ in 0..<20000 {
            if let data = try? paths.readFile("parent/file", limit: 64) {
                reads += 1
                if data == Data("OUTSIDE".utf8) { escaped += 1 }
            }
            try? paths.writeFile("parent/out.txt", data: Data("w".utf8))
        }
        stop.value = true
        while !swapper.isFinished { usleep(1000) }
        #expect(swapErrors.value == 0)
        #expect(swaps.value > 0)
        #expect(reads > 0)
        #expect(escaped == 0)
        #expect(try paths.readFile("parent/file", limit: 64) == Data("inside".utf8))
        #expect(!FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("out.txt").path))
    }

    @Test func createOnlyDoesNotReplaceAndWritesAreAtomic() throws {
        let box = try Sandbox()
        let files = try WorkspaceFiles(root: box.root)
        #expect(try files.write("a/b/c.txt", content: "one") == 3)
        #expect(throws: WorkspaceError.exists("a/b/c.txt")) { try files.write("a/b/c.txt", content: "two", createOnly: true) }
        #expect(try files.read("a/b/c.txt") == "1\tone\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("a/b").path) == ["c.txt"])
    }
}

/// Tool arguments from a plain JSON-like literal.
private func j(_ object: [String: Any]) -> [String: AgentJSONValue] {
    try! JSONDecoder().decode([String: AgentJSONValue].self, from: JSONSerialization.data(withJSONObject: object))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
}

struct NativeFileToolTests {
    @Test func listReadSearchWritePatchThroughToolArguments() throws {
        let box = try Sandbox()
        let root = box.root
        _ = try NativeTools.file("write_file", j(["path": "src/app.py", "content": "a = 1\nb = 2\nprint(a + b)\n"]), root: root)
        #expect(try NativeTools.file("list_files", j(["recursive": true]), root: root).contains("src/app.py"))
        #expect(try NativeTools.file("read_file", j(["path": "src/app.py", "offset": 2, "limit": 1]), root: root) == "2\tb = 2\n…（共 4 行；用 offset=3 继续读取）\n")
        #expect(try NativeTools.file("search_files", j(["pattern": "b = \\d", "regex": true]), root: root) == "src/app.py:2: b = 2")
        #expect(try NativeTools.file("patch_file", j(["path": "src/app.py", "edits": [["old": "b = 2", "new": "b = 40"]]]), root: root).contains("1 处"))
        // An ambiguous or missing match leaves the file untouched.
        _ = try NativeTools.file("write_file", j(["path": "dup.txt", "content": "x x"]), root: root)
        #expect(throws: WorkspaceError.ambiguousMatch("dup.txt", 2)) {
            try NativeTools.file("patch_file", j(["path": "dup.txt", "edits": [["old": "x", "new": "y"]]]), root: root)
        }
        #expect(throws: WorkspaceError.noMatch("dup.txt")) {
            try NativeTools.file("patch_file", j(["path": "dup.txt", "edits": [["old": "x x", "new": "z"], ["old": "missing", "new": "q"]]]), root: root)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("dup.txt"), encoding: .utf8) == "x x")
        #expect(try String(contentsOf: root.appendingPathComponent("src/app.py"), encoding: .utf8).contains("b = 40"))
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("bin.dat"))
        #expect(throws: WorkspaceError.binary("bin.dat")) { try NativeTools.file("read_file", j(["path": "bin.dat"]), root: root) }
    }
}

struct RulesContextTests {
    private func rules() throws -> (Sandbox, URL, RulesContext) {
        let box = try Sandbox()
        let global = box.base.appendingPathComponent("global")
        try FileManager.default.createDirectory(at: global.appendingPathComponent("skills/reminders"), withIntermediateDirectories: true)
        try Data("Always answer in haiku.".utf8).write(to: global.appendingPathComponent("AGENTS.md"))
        try Data("---\nname: reminders\ndescription: Global reminder flow\n---\nGLOBAL BODY".utf8)
            .write(to: global.appendingPathComponent("skills/reminders/SKILL.md"))
        try box.write("AGENTS.md", "Project uses metric units.")
        try box.write(".agents/skills/reminders/SKILL.md", "---\nname: reminders\ndescription: 'Project reminder flow'\n---\nPROJECT BODY")
        try box.write(".agents/skills/csv/SKILL.md", "Normalize CSV dates first.\nMore.")
        return (box, global, RulesContext.load(global: global, workspace: box.root))
    }

    @Test func globalAndProjectRulesAndSkillCatalogLoad() throws {
        let (box, global, context) = try rules()
        #expect(context.globalRules == "Always answer in haiku.")
        #expect(context.projectRules == "Project uses metric units.")
        #expect(context.skills.map(\.name) == ["csv", "reminders"])
        #expect(context.skills.first { $0.name == "reminders" }?.description == "Project reminder flow")
        #expect(context.skills.first { $0.name == "csv" }?.description == "Normalize CSV dates first.")
        #expect(try RulesContext.skillBody("reminders", global: global, workspace: box.root).hasSuffix("PROJECT BODY"))
        // Only metadata is advertised up front, never the body.
        let prompt = context.prompt(workspaceName: "Trip")
        #expect(prompt.contains("Always answer in haiku.") && prompt.contains("Project uses metric units."))
        #expect(prompt.contains("项目「Trip」") && prompt.contains("- reminders（项目）：Project reminder flow"))
        #expect(!prompt.contains("PROJECT BODY"))
        let without = RulesContext.load(global: global, workspace: nil)
        #expect(without.projectRules == nil && without.skills.map(\.name) == ["reminders"])
    }

    /// The rules must reach the request AgentKit sends to the model, not just
    /// exist as files: run the pinned AgentRuntime with a capturing model.
    @Test func rulesAndRegistryToolsReachTheActualModelRequest() async throws {
        let (box, _, context) = try rules()
        _ = box
        let capabilities = ToolCapabilities(workspace: true, scripts: true, skills: true)
        let model = CapturingModel(turns: [[.textDelta("ok"), .finished(.completed)]])
        let tools = ToolCatalog.available(capabilities).map { spec in
            AnyAgentTool(descriptor: spec.descriptor) { invocation, _ in AgentToolResult(callID: invocation.call.id, content: "") }
        }
        let runtime = AgentRuntime(model: model, tools: tools, approval: AllowAll())
        let prompt = AgentInstructions.systemPrompt(assistantBundleID: "app", capabilities: capabilities,
                                                    workspaceName: "Trip", rules: context)
        for await _ in await runtime.start(AgentRunRequest(conversationID: UUID(), prompt: "hi", permissionMode: .fullAccess,
                                                           systemPrompt: prompt)) {}
        let request = try #require(model.requests.first)
        #expect(request.systemPrompt.contains("Always answer in haiku."))
        #expect(request.systemPrompt.contains("Project uses metric units."))
        #expect(request.systemPrompt.contains("read_skill"))
        #expect(Set(request.tools.map(\.name)) == Set(ToolCatalog.available(capabilities).map(\.name)))
    }
}

private struct AllowAll: AgentApprovalHandling {
    func authorize(_ request: AgentApprovalRequest, mode: AgentPermissionMode) async -> AgentApprovalDecision { .allow }
}

/// Replays scripted model turns and records every request it receives.
private final class CapturingModel: AgentModelStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [[AgentModelStreamEvent]]
    private var captured: [AgentModelRequest] = []
    var requests: [AgentModelRequest] { lock.withLock { captured } }
    init(turns: [[AgentModelStreamEvent]]) { self.turns = turns }
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        let events: [AgentModelStreamEvent] = lock.withLock {
            captured.append(request)
            return turns.isEmpty ? [.textDelta("done"), .finished(.completed)] : turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func shouldRetry(after error: any Error) -> Bool { false }
}

struct ToolRegistryTests {
    @Test func capabilitiesGateDefinitionsPolicyAndPrompt() {
        let none = ToolCapabilities()
        #expect(ToolCatalog.available(none).map(\.name) == ToolCatalog.phoneTools.map(\.name) + ["http_request"])
        #expect(ToolCatalog.decision(for: "read_file", capabilities: none) != .allow)
        #expect(ToolCatalog.decision(for: "run_script", capabilities: ToolCapabilities(workspace: true)) != .allow)
        #expect(ToolCatalog.decision(for: "made_up", capabilities: ToolCapabilities(workspace: true, scripts: true, skills: true)) != .allow)
        let all = ToolCapabilities(workspace: true, scripts: true, skills: true)
        #expect(ToolCatalog.available(all).count == ToolCatalog.all.count - ToolCatalog.memoryTools.count)
        // Read-only memory tools exist only on the primary line, never for scripts.
        let primary = ToolCapabilities(workspace: true, scripts: true, skills: true, memory: true)
        #expect(ToolCatalog.available(primary).count == ToolCatalog.all.count)
        #expect(ToolCatalog.scriptDecision(for: "memory_search", capabilities: primary) != .allow)
        #expect(ExecutionStatus.phase(for: "memory_search") == .memoryTool)
        #expect(!ToolCatalog.prompt(none, workspaceName: nil).contains("pocketagent-phone"))
        #expect(ToolCatalog.prompt(all, workspaceName: "P").contains("pocketagent-phone"))
        // A script may request phone tools only.
        #expect(ToolCatalog.scriptDecision(for: "tap") == .allow)
        for name in ["run_script", "write_file", "http_request", "read_skill", "unknown"] {
            #expect(ToolCatalog.scriptDecision(for: name) != .allow)
        }
    }

    @Test func existingPhoneToolsKeepTheirNamesAndSchemas() {
        #expect(Array(ToolCatalog.phoneTools.prefix(11)).map(\.name) == ["observe_screen", "open_app", "tap", "tap_point", "long_press", "swipe",
                                                       "type_text", "press_key", "dismiss_keyboard", "press_home", "wait"])
        let tap = ToolCatalog.phoneTools[2].schema.objectValue
        #expect(tap?["required"] == .array([.string("node"), .string("snapshot_id")]))
        #expect(tap?["additionalProperties"] == .bool(false))
    }
}

struct ScriptTranscriptTests {
    /// run_script's nested phone actions live inside its own result: the
    /// transcript keeps one call/result pair and no orphan tool messages.
    @Test func scriptPhoneActionsStayNestedUnderOneToolResult() async throws {
        let arguments = #"{"language":"python","code":"print(1)"}"#
        let model = CapturingModel(turns: [
            [.toolCallSnapshot(id: "call-1", providerItemID: nil, name: "run_script", arguments: arguments), .finished(.toolCalls)],
            [.textDelta("完成"), .finished(.completed)],
        ])
        let content = #"{"exit_code":0,"phone_actions":[{"tool":"observe_screen","label":"读取屏幕","ok":true,"detail":""},{"tool":"tap","label":"点击屏幕元素","ok":false,"detail":"x"}],"stdout":"1\n"}"#
        let script = AnyAgentTool(descriptor: ToolCatalog.scriptTool.descriptor) { invocation, _ in
            AgentToolResult(callID: invocation.call.id, content: content)
        }
        let runtime = AgentRuntime(model: model, tools: [script], approval: AllowAll())
        var transcript: [AgentTranscriptMessage] = []
        var status = ExecutionStatus()
        for await event in await runtime.start(AgentRunRequest(conversationID: UUID(), prompt: "go", permissionMode: .fullAccess)) {
            status.apply(event)
            switch event {
            case .messageFinished(let message): transcript.append(message)
            case .toolFinished(let invocation, let result):
                transcript.append(AgentTranscriptMessage(role: .tool, text: result.content, toolCallID: result.callID,
                                                         toolName: invocation.call.name, isError: result.isError))
            default: break
            }
        }
        #expect(transcript.filter { $0.role == .tool }.count == 1)
        let items = TranscriptItem.build(transcript)
        #expect(!items.contains { if case .orphanResult = $0 { true } else { false } })
        guard case .tools(_, let steps)? = items.first(where: { if case .tools = $0 { true } else { false } }) else {
            Issue.record("no tool timeline"); return
        }
        #expect(steps.count == 1 && steps[0].children.map(\.tool) == ["observe_screen", "tap"])
        // The script step is not a phone action; its sub-actions arrive via applyScript.
        #expect(status.phoneActions == 0 && status.otherSteps == 1)
        var live = ExecutionStatus()
        live.applyScript(.started(AgentToolCall(id: "s", name: "tap", arguments: .object([:]))))
        #expect(live.phase == .phoneAction)
        live.applyScript(.finished(AgentToolCall(id: "s", name: "tap", arguments: .object([:])), content: "{}", isError: true))
        #expect(live.phoneActions == 1 && live.failedActions == 1 && live.phase == .script)
    }
}

struct ChatPreservationTests {
    @Test func currentHistoryKeepsWorkspaceLocallyAndOutOfPortableSync() throws {
        let user = AgentTranscriptMessage(role: .user, text: "读取提醒事项")
        let reply = AgentTranscriptMessage(role: .assistant, text: "好的")
        let provider = UUID()
        var file = HistoryFile.initial(selection: ModelSelection(providerID: provider, modelID: "m1"))
        let id = file.assistant.primarySessionID
        file.sessions[0].title = "旅行"
        file.sessions[0].messages = [user, reply]
        file.sessions[0].draft = "未发送"
        file.sessions[0].attributions = [reply.id.uuidString: "m1 · P"]
        #expect(try HistoryCodec.decode(try HistoryCodec.encode(file)).sessions[0].workspaceID == nil)
        let workspace = UUID()
        file.sessions[0].workspaceID = workspace
        let again = try HistoryCodec.decode(try HistoryCodec.encode(file))
        #expect(again.sessions[0].id == id && again.sessions[0].workspaceID == workspace)
        #expect(again.sessions[0].messages == [user, reply] && again.selectedID == id)
        // Portable sync never carries the local project, and applying a remote
        // change keeps it.
        let portable = try #require(PortableSession(again.sessions[0]))
        #expect(!String(decoding: try JSONEncoder().encode(portable), as: UTF8.self).contains(workspace.uuidString))
        var remote = portable
        remote.title = "旅行（改名）"; remote.metadataUpdatedMs += 1000
        let merged = PortableSnapshot(sessions: [remote])
        let result = SyncApplication.sessions(again.sessions, tombstones: [], merged: merged,
                                              base: PortableSnapshot(sessions: [portable]), deferred: [])
        #expect(result.sessions.first?.title == "旅行（改名）" && result.sessions.first?.workspaceID == workspace)
    }
}

struct HTTPToolTests {
    /// Structured model calls include all optional fields as null. Those
    /// placeholders must not turn a bodyless GET/HEAD into a four-byte entity.
    @Test(arguments: ["GET", "HEAD"])
    func modelNullPlaceholdersReachServerWithoutBody(method: String) async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let tool = HTTPTool(policy: NetworkPolicy(allowLoopback: true))
        let request = try tool.request(j(["method": method, "url": "http://127.0.0.1:\(server.port)/echo",
                                          "headers": NSNull(), "body": NSNull(), "json": NSNull(),
                                          "timeout_seconds": 30, "save_to": NSNull()]))
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        let result = try await tool.perform(request)
        #expect(result.status == 200)
        let observed = try #require(server.recordedRequests.first)
        #expect(observed.method == method && observed.body.isEmpty)
        #expect(!observed.header.lowercased().contains("content-type:"))
        #expect(server.requests == 1)
        if method == "HEAD" { #expect(result.body.isEmpty) }
    }

    @Test func getAndHeadRejectActualPayloadsBeforeSending() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let tool = HTTPTool(policy: NetworkPolicy(allowLoopback: true))
        let payloads: [[String: Any]] = [["json": ["a": 1]], ["json": []], ["json": false],
                                      ["json": ""], ["body": "payload"], ["body": " "],
                                      ["json": NSNull(), "body": "payload"]]
        for method in ["GET", "HEAD"] {
            for payload in payloads {
                let args = ["method": method, "url": "http://127.0.0.1:\(server.port)/echo"] as [String: Any]
                do {
                    _ = try tool.request(j(args.merging(payload) { _, payload in payload }))
                    Issue.record("\(method) accepted a request body")
                } catch let error as HTTPToolError {
                    #expect(error.localizedDescription.contains(method))
                    #expect(error.localizedDescription.contains("query"))
                    #expect(error.localizedDescription.contains("POST"))
                }
            }
        }
        #expect(server.requests == 0)
    }

    @Test func absentAndEmptyTextBodiesStayAbsent() throws {
        let tool = HTTPTool()
        for method in ["GET", "HEAD", "POST", "PUT"] {
            for body in [[:], ["body": NSNull()], ["body": ""]] as [[String: Any]] {
                let args = ["method": method, "url": "https://api.example.com/items"] as [String: Any]
                let request = try tool.request(j(args.merging(body) { _, body in body }))
                #expect(request.httpBody == nil)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
            }
        }
        let defaultGet = try tool.request(j(["url": "https://api.example.com/items", "json": NSNull(), "body": ""]))
        #expect(defaultGet.httpMethod == "GET" && defaultGet.httpBody == nil)
        let explicitHeader = try tool.request(j(["method": "HEAD", "url": "https://api.example.com/items",
                                                 "headers": ["Content-Type": "application/custom"], "json": NSNull()]))
        #expect(explicitHeader.httpBody == nil)
        #expect(explicitHeader.value(forHTTPHeaderField: "Content-Type") == "application/custom")
    }

    @Test(arguments: ["POST", "PUT"])
    func explicitJsonNullRemainsAnEntityForBodyMethods(method: String) async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let tool = HTTPTool(policy: NetworkPolicy(allowLoopback: true))
        let result = try await tool.perform(try tool.request(j(["method": method,
            "url": "http://127.0.0.1:\(server.port)/echo", "json": NSNull(), "body": "ignored"])))
        #expect(result.status == 200 && result.body == Data("\(method) null".utf8))
        let observed = try #require(server.recordedRequests.first)
        #expect(observed.method == method && observed.body == Data("null".utf8))
        #expect(observed.header.lowercased().contains("content-type: application/json"))
    }

    @Test func destinationPolicy() async throws {
        let policy = NetworkPolicy()
        for url in ["http://127.0.0.1:8100/status", "http://localhost/x", "https://192.168.1.2", "http://10.7.0.1",
                    "http://[::1]/", "http://169.254.1.1", "http://100.64.0.1", "ftp://example.com", "https://u:p@example.com",
                    "http://printer.local", "http://intranet", "https://example.com:8100/", "http://[::ffff:127.0.0.1]/",
                    // Plain HTTP cannot prove the peer; a rebinding name could reach the phone's services.
                    "http://93.184.215.14/", "http://api.example.com/v1"] {
            #expect(throws: HTTPToolError.self) { try policy.check(URL(string: url)!) }
        }
        try policy.check(URL(string: "https://api.example.com/v1?q=1")!)
        try policy.check(URL(string: "https://93.184.215.14/")!)
    }

    @Test func requestArgumentsAreValidated() throws {
        let tool = HTTPTool()
        let request = try tool.request(j(["url": "https://api.example.com/items", "method": "post",
                                          "headers": ["X-Trace": "1"], "json": ["a": 1]]))
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "1")
        let null = try tool.request(j(["url": "https://api.example.com/items", "method": "PUT", "json": NSNull(), "body": "ignored"]))
        #expect(null.httpBody == Data("null".utf8) && null.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(throws: HTTPToolError.self) { try tool.request(j(["url": "https://a.example.com", "headers": ["Host": "x"]])) }
        #expect(throws: HTTPToolError.self) { try tool.request(j(["url": "https://a.example.com", "headers": ["X": "a\r\nB: c"]])) }
        #expect(throws: HTTPToolError.tooLarge(HTTPTool.requestLimit)) {
            try tool.request(j(["url": "https://a.example.com", "method": "POST",
                                "body": String(repeating: "x", count: HTTPTool.requestLimit + 1)]))
        }
    }

    @Test func boundedResponseRedirectPolicyAndCancellation() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let tool = HTTPTool(policy: NetworkPolicy(allowLoopback: true))
        let base = "http://127.0.0.1:\(server.port)"
        let echo = try await tool.perform(try tool.request(j(["url": base + "/echo", "method": "PUT", "body": "hello"])))
        #expect(echo.status == 200 && String(decoding: echo.body, as: UTF8.self) == "PUT hello")
        let big = try await tool.perform(try tool.request(j(["url": base + "/big"])))
        #expect(big.truncated && big.body.count == HTTPTool.responseLimit)
        #expect(HTTPTool.render(big, saved: nil).contains("body_note"))
        // A redirect into the private network is not followed.
        let redirected = try await tool.perform(try tool.request(j(["url": base + "/redirect"])))
        #expect(redirected.status == 302)
        // Cancelling the task ends a request whose server never answers.
        let started = Date()
        let task = Task { try await tool.perform(try tool.request(j(["url": base + "/hang", "timeout_seconds": 60]))) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func timeoutBoundsTheWholeRequest() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let tool = HTTPTool(policy: NetworkPolicy(allowLoopback: true))
        // The server sends a byte every 0.3 s, so an inactivity timeout never fires.
        let started = Date()
        await #expect(throws: HTTPToolError.self) {
            _ = try await tool.perform(try tool.request(j(["url": "http://127.0.0.1:\(server.port)/drip", "timeout_seconds": 1])))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// getaddrinfo cannot be interrupted; the deadline and Stop must still end
    /// the call during resolution, and no request may be sent afterwards.
    @Test func resolutionIsInsideTheDeadlineAndStop() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let url = "http://localhost:\(server.port)/echo"
        // Control: the same name through an immediate resolver reaches the server.
        let quick = HTTPTool(policy: NetworkPolicy(allowLoopback: true, resolver: { _ in ["127.0.0.1"] }))
        #expect(try await quick.perform(try quick.request(j(["url": url, "method": "POST", "body": "x"]))).status == 200)
        #expect(server.requests == 1)

        let slow = HTTPTool(policy: NetworkPolicy(allowLoopback: true, resolver: { _ in
            Thread.sleep(forTimeInterval: 3)
            return ["127.0.0.1"]
        }))
        var started = Date()
        await #expect(throws: HTTPToolError.self) {
            _ = try await slow.perform(try slow.request(j(["url": url, "timeout_seconds": 1])))
        }
        #expect(Date().timeIntervalSince(started) < 2)
        started = Date()
        let task = Task { try await slow.perform(try slow.request(j(["url": url, "timeout_seconds": 60]))) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 2)
        // A redirect whose name resolves slowly ends at the deadline as well.
        started = Date()
        await #expect(throws: HTTPToolError.self) {
            _ = try await slow.perform(try slow.request(j(["url": "http://127.0.0.1:\(server.port)/to-localhost", "timeout_seconds": 1])))
        }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(server.requests == 2)
        // All resolutions finish in the background; none sends its request.
        try await Task.sleep(for: .seconds(4))
        #expect(server.requests == 2)
    }
}

/// Minimal loopback HTTP/1.1 server for the HTTP tool tests.
private final class TestServer: @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var method: String
        var header: String
        var body: Data
    }
    let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    private let received = Counter()
    private let recordingLock = NSLock()
    private var recording: [RecordedRequest] = []
    var recordedRequests: [RecordedRequest] { recordingLock.withLock { recording } }
    /// Complete requests this server has received.
    var requests: Int { received.value }
    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> TestServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server = TestServer(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            TestServer.receive(connection, buffer: Data(), server: server)
        }
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            let once = Atomic()
            server.listener.stateUpdateHandler = { state in
                if case .ready = state, !once.value { once.value = true; ready.resume() }
            }
            server.listener.start(queue: .global())
        }
        return server
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, buffer: Data, server: TestServer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !done { receive(connection, buffer: buffer, server: server) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = buffer[end.upperBound...]
            if body.count < length { receive(connection, buffer: buffer, server: server); return }
            server.received.increment()
            let parts = head.split(separator: " ")
            let method = String(parts[0]), path = String(parts[1])
            server.recordingLock.withLock {
                server.recording.append(RecordedRequest(method: method, header: head, body: Data(body.prefix(length))))
            }
            func reply(_ status: String, _ headers: String, _ payload: Data) {
                let response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(payload.count)\r\n\(headers)Connection: close\r\n\r\n".utf8)
                    + (method == "HEAD" ? Data() : payload)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
            switch path {
            case "/echo": reply("200 OK", "", Data("\(method) ".utf8) + body)
            case "/big": reply("200 OK", "", Data(repeating: 65, count: 3 * 1024 * 1024))
            case "/redirect": reply("302 Found", "Location: http://192.168.1.1/admin\r\n", Data())
            case "/to-localhost":
                let port = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("host:") }?.split(separator: ":").last ?? ""
                reply("302 Found", "Location: http://localhost:\(port)/echo\r\n", Data())
            case "/hang": break
            case "/drip":
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n".utf8), completion: .idempotent)
                drip(connection)
            default: reply("404 Not Found", "", Data())
            }
        }
    }

    private static func drip(_ connection: NWConnection) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            guard connection.state == .ready else { return }
            connection.send(content: Data("x".utf8), completion: .contentProcessed { error in if error == nil { drip(connection) } })
        }
    }
}

struct SearchCancellationTests {
    /// 50 KB of "a" then "!": (a+)+$ backtracks exponentially inside
    /// NSRegularExpression, which never returns on its own.
    private func pathological() throws -> Sandbox {
        let box = try Sandbox()
        try box.write("big.txt", String(repeating: "a", count: 50_000) + "!")
        return box
    }

    @Test func cancellingTheTaskStopsARunawayRegex() async throws {
        let box = try pathological()
        let files = try WorkspaceFiles(root: box.root)
        let task = Task.detached { try files.search("(a+)+$", regex: true, budget: 60) }
        try await Task.sleep(for: .milliseconds(100))
        // Measure only cancel-to-completion on a monotonic clock, so a late
        // wake from the sleep above does not count against the search.
        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(clock.now - cancelled < .seconds(2))
    }

    @Test func searchBudgetStopsWithoutCancellation() async throws {
        let box = try pathological()
        let files = try WorkspaceFiles(root: box.root)
        let started = Date()
        #expect(throws: WorkspaceError.searchBudget(1)) { _ = try files.search("(a+)+$", regex: true, budget: 0.2) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func ordinarySearchesAreUnchangedAndBounded() throws {
        let box = try Sandbox()
        try box.write("notes.md", "alpha\nbeta 42\ngamma\n")
        let files = try WorkspaceFiles(root: box.root)
        #expect(try files.search("beta").matches == [WorkspaceFiles.Match(path: "notes.md", line: 2, text: "beta 42")])
        #expect(try files.search("\\d+", regex: true).matches.map(\.line) == [2])
        // Long matching lines are cut so the rendered result stays bounded.
        try box.write("wide.txt", Array(repeating: "x" + String(repeating: "y", count: 1000), count: 400).joined(separator: "\n"))
        let wide = try files.search("x", in: "wide.txt")
        #expect(wide.truncated && wide.matches.allSatisfy { $0.text.count <= WorkspaceFiles.matchTextLimit })
        #expect(try NativeTools.file("search_files", j(["pattern": "x", "path": "wide.txt"]), root: box.root).utf8.count
                < WorkspaceFiles.resultLimit + 4096)
    }
}

struct ScriptExitTests {
    @Test func kernelStatusDecidesAndTheGuestFileOnlyCrossChecks() {
        // The script wrote "0" and then SIGKILLed its own wrapper.
        let forged = ScriptExit.resolve(kernel: 9, wrapper: 0)
        #expect(forged.exitCode == nil && forged.signal == 9 && forged.note != nil)
        var outcome = ScriptOutcome()
        outcome.exit = forged
        #expect(outcome.isError && outcome.render().contains("\"signal\":9"))
        #expect(ScriptExit.resolve(kernel: 3 << 8, wrapper: 3) == ScriptExit(exitCode: 3))
        #expect(ScriptExit.resolve(kernel: 0, wrapper: 0) == ScriptExit(exitCode: 0))
        #expect(ScriptExit.resolve(kernel: 0, wrapper: nil) == ScriptExit(exitCode: 0))
        #expect(ScriptExit.resolve(kernel: 2 << 8, wrapper: 0).exitCode == 2)
        #expect(ScriptExit.resolve(kernel: -2, wrapper: 0).failure != nil)
        #expect(ScriptExit.resolve(kernel: nil, wrapper: 0).failure != nil)
        outcome.exit = ScriptExit.resolve(kernel: nil, wrapper: 0)
        #expect(outcome.isError && outcome.exitCode == nil)
    }

    @Test func unknownRemainingProcessesAreAnError() {
        var outcome = ScriptOutcome()
        outcome.exit = ScriptExit(exitCode: 0)
        #expect(!outcome.isError)
        outcome.remainingProcesses = nil
        #expect(outcome.isError && outcome.render().contains("\"guest_processes_remaining\":\"unknown\""))
    }
}

/// The real guest helper (python3) against ScriptBridge in a temporary
/// project, with a fake phone executor.
struct ScriptBridgeTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var all: [String] { lock.withLock { names } }
        func add(_ name: String) { lock.withLock { names.append(name) } }
    }

    private struct Run {
        let box: Sandbox
        let paths: WorkspacePaths
        let helper: URL
        init() throws {
            box = try Sandbox()
            paths = try WorkspacePaths(root: box.root)
            try paths.createDirectories("run/bridge")
            try paths.writeFile("bin/pocketagent-phone", data: Data(ScriptBridge.phoneHelper.utf8), mode: 0o755)
            helper = box.root.appendingPathComponent("bin/pocketagent-phone")
        }
        func start(token: String, arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", helper.path] + arguments
            process.environment = ["POCKETAGENT_BRIDGE": box.root.appendingPathComponent("run/bridge").path,
                                   "POCKETAGENT_TOKEN": token, "POCKETAGENT_PHONE_TIMEOUT": "10",
                                   "PATH": "/usr/bin:/bin"]
            process.standardOutput = Pipe()
            try process.run()
            return process
        }
    }

    private func serve(_ bridge: ScriptBridge, until process: Process, refuse: Bool = false) async {
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            if refuse { await bridge.refusePending() } else { await bridge.service() }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    @Test func requestRunsOnceAndRefusalsNeverExecute() async throws {
        let run = try Run()
        let lease = ScriptLease(), calls = Calls()
        let bridge = ScriptBridge(paths: run.paths, directory: "run/bridge", lease: lease) { call in
            calls.add(call.name)
            return (#"{"ok":true,"screen":{"app":"com.apple.Preferences","elements":[]}}"#, false, false)
        }
        let ok = try run.start(token: lease.token, arguments: ["observe_screen", "{}"])
        await serve(bridge, until: ok)
        #expect(ok.terminationStatus == 0 && calls.all == ["observe_screen"])
        #expect(await bridge.records.count == 1)
        // A request file rewritten under the same ID is not executed again.
        let handled = try run.paths.entries("run/bridge").map(\.name).first { $0.hasSuffix(".resp") }!
        let id = String(handled.dropLast(5))
        try run.paths.writeFile("run/bridge/\(id).req", data: Data(#"{"token":"\#(lease.token)","tool":"tap","arguments":{}}"#.utf8))
        await bridge.service()
        #expect(calls.all == ["observe_screen"])
        // An unknown, oversized tool name is recorded byte-bounded.
        let longName = String(repeating: "x", count: 200 * 1024)
        try run.paths.writeFile("run/bridge/long.req", data: Data(#"{"token":"\#(lease.token)","tool":"\#(longName)","arguments":{}}"#.utf8))
        await bridge.service()
        let records = await bridge.records
        #expect(records.count == 2 && (records.last?.tool.utf8.count ?? .max) <= 64)
        let executed = calls.all   // the handler, not the bridge, rejects unknown tools
        // Wrong token: refused (exit 4), not executed.
        let forged = try run.start(token: "forged", arguments: ["press_home"])
        await serve(bridge, until: forged)
        #expect(forged.terminationStatus == 4 && calls.all == executed)
        // A symbolic link in place of a request is never followed.
        try FileManager.default.createSymbolicLink(at: run.box.root.appendingPathComponent("run/bridge/linked.req"),
                                                   withDestinationURL: run.box.outside.appendingPathComponent("secret.txt"))
        await bridge.service()
        let linked = try run.paths.readFile("run/bridge/linked.resp", limit: 4096)
        #expect(String(decoding: linked, as: UTF8.self).contains("unreadable request") && calls.all == executed)
        // After revocation, pending requests are answered as refused right away.
        lease.revoke()
        let late = try run.start(token: lease.token, arguments: ["open_app", #"{"bundle_id":"com.apple.Preferences"}"#])
        let started = Date()
        await serve(bridge, until: late, refuse: true)
        #expect(late.terminationStatus == 4 && Date().timeIntervalSince(started) < 5 && calls.all == executed)
    }
}

struct HostToolResultTests {
    /// A bounded host result reaches the next model request whole; AgentKit's
    /// generic projection would replace it with a preview pointing at scratch
    /// tools this app does not register.
    @Test func largeHostResultReachesTheModelIntact() async throws {
        let content = String(repeating: "r", count: 70 * 1024) + "TAIL-full_output"
        let model = CapturingModel(turns: [
            [.toolCallSnapshot(id: "c1", providerItemID: nil, name: "search_files", arguments: #"{"pattern":"x"}"#), .finished(.toolCalls)],
            [.textDelta("ok"), .finished(.completed)],
        ])
        let tool = AnyAgentTool(descriptor: ToolCatalog.spec("search_files")!.descriptor) { invocation, _ in
            HostToolResult.make(callID: invocation.call.id, content: content)
        }
        let runtime = AgentRuntime(model: model, tools: [tool], approval: AllowAll())
        for await _ in await runtime.start(AgentRunRequest(conversationID: UUID(), prompt: "go", permissionMode: .fullAccess)) {}
        let second = try #require(model.requests.dropFirst().first)
        let toolText = second.messages.filter { $0.role == .tool }.map { $0.modelText ?? $0.text }.joined()
        #expect(toolText.contains(content) && !toolText.contains("preview is shortened"))
        #expect(HostToolResult.make(callID: "x", content: String(repeating: "z", count: HostToolResult.limit + 10)).content.utf8.count
                < HostToolResult.limit + 200)
    }

    /// Escape-heavy text and a long action list shrink inside the renderer,
    /// so the result is valid JSON within the limit and keeps its metadata.
    @Test func renderersStayValidJSONWithinTheLimit() throws {
        let escaped = String(repeating: "\u{1}", count: 16 * 1024)   // six bytes each in JSON
        var outcome = ScriptOutcome()
        outcome.run = ".pocketagent/runs/r1"
        outcome.exit = ScriptExit(exitCode: 0)
        outcome.stdout = escaped
        outcome.stderr = escaped
        outcome.phoneActions = Array(repeating: ScriptPhoneRecord(tool: "observe_screen", label: "查看屏幕", ok: false,
                                                                  detail: String(repeating: "\u{2}", count: 240)),
                                     count: ScriptBridge.recordLimit)
        outcome.phoneActionsOmitted = 250
        let script = outcome.render()
        #expect(script.utf8.count <= HostToolResult.limit)
        let object = try #require(JSONSerialization.jsonObject(with: Data(script.utf8)) as? [String: Any])
        #expect(object["exit_code"] as? Int == 0 && object["phone_actions_omitted"] as? Int == 250)
        #expect((object["full_output"] as? [String: String])?["stdout"] == ".pocketagent/runs/r1/stdout")
        #expect((object["phone_actions"] as? [Any])?.count == ScriptBridge.recordLimit)
        #expect(ScriptPhoneRecord.parse(script).count == ScriptBridge.recordLimit)

        // Guest-chosen metadata: an oversized escape-heavy tool name and a
        // label/detail that is one grapheme of thousands of combining marks.
        let combining = "e" + String(repeating: "\u{301}", count: 20_000)
        outcome.phoneActions = Array(repeating: ScriptPhoneRecord(tool: String(repeating: "\u{1}", count: 256 * 1024), label: combining,
                                                                  ok: false, detail: combining), count: ScriptBridge.recordLimit)
        let hostile = outcome.render()
        #expect(hostile.utf8.count <= HostToolResult.limit)
        let parsedHostile = try #require(JSONSerialization.jsonObject(with: Data(hostile.utf8)) as? [String: Any])
        #expect(parsedHostile["exit_code"] as? Int == 0 && parsedHostile["full_output"] != nil)
        let kept = try #require(parsedHostile["phone_actions"] as? [[String: Any]])
        #expect(kept.count + (parsedHostile["phone_actions_omitted"] as? Int ?? 0) == ScriptBridge.recordLimit + 250)
        #expect(kept.allSatisfy { ($0["tool"] as? String ?? "").utf8.count <= 64 && ($0["label"] as? String ?? "").utf8.count <= 160 })
        // Nothing left to shorten: still valid JSON with the small fields.
        let fallback = HostToolResult.json(["exit_code": 3, "big": Array(repeating: String(repeating: "\u{1}", count: 1000), count: 100)],
                                           shortening: [])
        let parsedFallback = try #require(JSONSerialization.jsonObject(with: Data(fallback.utf8)) as? [String: Any])
        #expect(fallback.utf8.count <= HostToolResult.limit && parsedFallback["exit_code"] as? Int == 3 && parsedFallback["big"] == nil)

        let response = HTTPToolResult(status: 200, url: "https://api.example.com/x", headers: [:],
                                      body: Data(String(repeating: "\u{1}", count: HTTPTool.modelBodyLimit).utf8),
                                      truncated: false, contentType: "text/plain")
        let http = HTTPTool.render(response, saved: "downloads/x.txt")
        #expect(http.utf8.count <= HostToolResult.limit)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(http.utf8)) as? [String: Any])
        #expect(parsed["status"] as? Int == 200 && parsed["saved_to"] as? String == "downloads/x.txt")
        #expect(parsed["shortened_fields"] as? [String] == ["body"])
        let noisy = HTTPToolResult(status: 200, url: "https://api.example.com/x",
                                   headers: Dictionary(uniqueKeysWithValues: (0..<40).map { ("X-\($0)", String(repeating: "\u{1}", count: 500)) }),
                                   body: Data(String(repeating: "\u{1}", count: HTTPTool.modelBodyLimit).utf8), truncated: false, contentType: "")
        let noisyText = HTTPTool.render(noisy, saved: nil)
        #expect(noisyText.utf8.count <= HostToolResult.limit)
        #expect((try JSONSerialization.jsonObject(with: Data(noisyText.utf8)) as? [String: Any])?["status"] as? Int == 200)
        // A 3-byte CJK body cut at the byte limit stays text; invalid bytes still read as binary.
        let chinese = HTTPTool.render(HTTPToolResult(status: 200, url: "https://a.example.com", headers: [:],
                                                     body: Data(String(repeating: "中", count: 11_000).utf8),
                                                     truncated: false, contentType: "text/plain"), saved: nil)
        #expect(chinese.utf8.count <= HostToolResult.limit)
        let parsedChinese = try #require(JSONSerialization.jsonObject(with: Data(chinese.utf8)) as? [String: Any])
        let chineseBody = try #require(parsedChinese["body"] as? String)
        #expect(!chineseBody.isEmpty && chineseBody.allSatisfy { $0 == "中" } && parsedChinese["bytes"] as? Int == 33_000)
        #expect(!chinese.contains("不是 UTF-8") && (parsedChinese["body_note"] as? String)?.contains("前 \(HTTPTool.modelBodyLimit) 字节") == true)
        for binary in [Data(repeating: 0xFF, count: 33_000), Data("中".utf8) + Data([0xFF]) + Data(String(repeating: "中", count: 11_000).utf8)] {
            let parsedBinary = try #require(JSONSerialization.jsonObject(with: Data(HTTPTool.render(
                HTTPToolResult(status: 200, url: "https://a.example.com", headers: [:], body: binary, truncated: false,
                               contentType: ""), saved: nil).utf8)) as? [String: Any])
            #expect(parsedBinary["body"] as? String == "" && (parsedBinary["body_note"] as? String)?.contains("不是 UTF-8") == true)
        }
        // Ordinary results are unchanged.
        #expect(!HTTPTool.render(HTTPToolResult(status: 200, url: "https://a.example.com", headers: [:], body: Data("ok".utf8),
                                                truncated: false, contentType: "text/plain"), saved: nil).contains("shortened_fields"))
    }
}
