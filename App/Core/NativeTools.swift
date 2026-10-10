import AgentKit
import Foundation

/// Model-facing implementations of the native file, skill and HTTP tools.
/// Each returns the tool result text or throws a user-readable error.
nonisolated enum NativeTools {
    static func file(_ name: String, _ args: [String: AgentJSONValue], root: URL) throws -> String {
        let files = try WorkspaceFiles(root: root)
        let path = args["path"]?.stringValue ?? "."
        switch name {
        case "list_files":
            let result = try files.list(path, recursive: args["recursive"]?.boolValue ?? false)
            guard !result.entries.isEmpty else { return "（\(path) 为空）" }
            var lines = result.entries.map { entry in
                entry.isDirectory ? entry.path + "/" : entry.isLink ? entry.path + " -> （符号链接）" : "\(entry.path)  \(entry.size) B"
            }
            if result.truncated { lines.append("…（列表已截断，请指定子目录）") }
            return lines.joined(separator: "\n")
        case "read_file":
            return try files.read(path, offset: args["offset"]?.integerValue ?? 1, limit: args["limit"]?.integerValue ?? 400)
        case "search_files":
            guard let pattern = args["pattern"]?.stringValue else { throw WorkspaceError.invalidPath("pattern") }
            let result = try files.search(pattern, in: path, regex: args["regex"]?.boolValue ?? false)
            guard !result.matches.isEmpty else { return "没有匹配。" }
            var lines = result.matches.map { "\($0.path):\($0.line): \($0.text)" }
            if result.truncated { lines.append("…（结果已截断）") }
            return lines.joined(separator: "\n")
        case "write_file":
            guard args["path"] != nil, let content = args["content"]?.stringValue else { throw WorkspaceError.invalidPath("path/content") }
            return "已写入 \(path)（\(try files.write(path, content: content)) 字节）。"
        case "patch_file":
            guard args["path"] != nil, case .array(let items)? = args["edits"] else { throw WorkspaceError.invalidPath("path/edits") }
            let edits = try items.map { item -> WorkspaceFiles.Edit in
                guard let object = item.objectValue, let old = object["old"]?.stringValue, let new = object["new"]?.stringValue else {
                    throw WorkspaceError.invalidPath("edits")
                }
                return WorkspaceFiles.Edit(old: old, new: new, replaceAll: object["replace_all"]?.boolValue ?? false)
            }
            return "已修改 \(path)：替换 \(try files.patch(path, edits: edits)) 处。"
        default:
            throw WorkspaceError.invalidPath(name)
        }
    }

    static func skill(_ args: [String: AgentJSONValue], global: URL, workspace: URL?) throws -> String {
        guard let name = args["name"]?.stringValue else { throw WorkspaceError.notFound("skill") }
        return try RulesContext.skillBody(name, global: global, workspace: workspace)
    }

    static func http(_ args: [String: AgentJSONValue], tool: HTTPTool, workspace: URL?) async throws -> String {
        let request = try tool.request(args)
        var saveTarget: (WorkspacePaths, String)?
        if let save = args["save_to"]?.stringValue, !save.isEmpty {
            guard let workspace else { throw HTTPToolError.invalid("save_to 需要本会话选择项目目录。") }
            let paths = try WorkspacePaths(root: workspace)
            _ = try WorkspacePaths.components(save)
            saveTarget = (paths, save)
        }
        let result = try await tool.perform(request)
        if let (paths, save) = saveTarget { try paths.writeFile(save, data: result.body) }
        return HTTPTool.render(result, saved: saveTarget?.1)
    }
}
