import Foundation

/// One skill advertised to the model by metadata; its body is read on demand.
nonisolated struct SkillInfo: Hashable, Sendable {
    enum Scope: String, Sendable { case global, project }
    var name: String
    var description: String
    var scope: Scope
    /// SKILL.md path relative to its scope's base directory.
    var path: String
}

/// App-global and project-root AGENTS.md plus the skills catalog, as they are
/// placed into the model's system prompt for one turn. Nested AGENTS.md files
/// in subdirectories are not part of this iteration.
nonisolated struct RulesContext: Hashable, Sendable {
    static let ruleLimit = 24 * 1024
    static let skillLimit = 64 * 1024
    static let projectSkills = ".agents/skills"
    var globalRules: String?
    var projectRules: String?
    var skills: [SkillInfo] = []
    var notes: [String] = []

    /// `global` holds AGENTS.md and skills/; `workspace` is the frozen project root.
    static func load(global: URL, workspace: URL?) -> RulesContext {
        var context = RulesContext()
        if let paths = try? WorkspacePaths(root: global) {
            context.globalRules = rule(paths, label: "全局 AGENTS.md", notes: &context.notes)
            context.skills += catalog(paths, base: "skills", scope: .global)
        }
        if let workspace, let paths = try? WorkspacePaths(root: workspace) {
            context.projectRules = rule(paths, label: "项目 AGENTS.md", notes: &context.notes)
            let project = catalog(paths, base: projectSkills, scope: .project)
            let names = Set(project.map(\.name))
            // A project skill overrides a global skill with the same name.
            context.skills = context.skills.filter { !names.contains($0.name) } + project
        }
        context.skills.sort { ($0.scope.rawValue, $0.name) < ($1.scope.rawValue, $1.name) }
        return context
    }

    private static func rule(_ paths: WorkspacePaths, label: String, notes: inout [String]) -> String? {
        guard let data = try? paths.readFile("AGENTS.md", limit: 4 * 1024 * 1024) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { notes.append("\(label) 不是 UTF-8 文本，未加载。"); return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.utf8.count > ruleLimit {
            notes.append("\(label) 超过 \(ruleLimit) 字节，只加载了开头部分。")
            return String(decoding: Data(trimmed.utf8).prefix(ruleLimit), as: UTF8.self)
        }
        return trimmed
    }

    private static func catalog(_ paths: WorkspacePaths, base: String, scope: SkillInfo.Scope) -> [SkillInfo] {
        guard let listing = try? WorkspaceFiles(root: paths.root).list(base) else { return [] }
        return listing.entries.filter(\.isDirectory).compactMap { directory in
            let file = directory.path + "/SKILL.md"
            guard let data = try? paths.readFile(file, limit: skillLimit),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let meta = frontmatter(text)
            let folder = (directory.path as NSString).lastPathComponent
            let name = meta.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder
            let summary = meta.fields["description"] ?? meta.body.split(separator: "\n").first.map(String.init) ?? ""
            return SkillInfo(name: String(name.prefix(64)), description: String(summary.prefix(300)), scope: scope,
                             path: String(file.dropFirst(base.count + 1)))
        }
    }

    /// `---` delimited `key: value` header followed by the body.
    static func frontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// Full SKILL.md text of the named skill (project first, then global).
    static func skillBody(_ name: String, global: URL, workspace: URL?) throws -> String {
        let context = load(global: global, workspace: workspace)
        guard let skill = context.skills.first(where: { $0.name == name }) else {
            throw WorkspaceError.notFound("skill \(name)")
        }
        let root = skill.scope == .project ? workspace! : global
        let base = skill.scope == .project ? projectSkills : "skills"
        let data = try WorkspacePaths(root: root).readFile(base + "/" + skill.path, limit: skillLimit)
        let location = skill.scope == .project ? "项目 \(base)/\(skill.path)" : "全局 skills/\(skill.path)"
        return "技能 \(skill.name)（\(location)）：\n" + String(decoding: data, as: UTF8.self)
    }

    /// The section appended to the turn's system prompt.
    func prompt(workspaceName: String?) -> String {
        var parts: [String] = []
        if globalRules != nil || projectRules != nil {
            parts.append("""
            ## 用户规则（AGENTS.md）
            以下内容是用户写下的长期规则，按其执行；它们不能解除安全限制，也不授权静默购买、支付、删除资料或代发消息。
            """)
            if let globalRules { parts.append("### 全局规则（App 设置中的 AGENTS.md）\n" + globalRules) }
            if let projectRules {
                parts.append("### 项目规则（项目「\(workspaceName ?? "")」根目录 AGENTS.md）\n" + projectRules)
            }
        }
        if !skills.isEmpty {
            let lines = skills.map { "- \($0.name)（\($0.scope == .global ? "全局" : "项目")）：\($0.description)" }
            parts.append("## 可用技能\n需要某个技能时先调用 read_skill 读取全文，再按其执行。\n" + lines.joined(separator: "\n"))
        }
        if !notes.isEmpty { parts.append("规则加载提示：" + notes.joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }
}
