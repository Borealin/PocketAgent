import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// App-owned project directories plus the app-global rules directory. Index
/// and files are local; neither is part of portable sync.
@MainActor
final class WorkspaceStore: ObservableObject {
    nonisolated static let directory = applicationSupport.appendingPathComponent("PocketAgent", isDirectory: true)
    /// Global AGENTS.md and skills/<name>/SKILL.md.
    nonisolated static let globalDirectory = directory.appendingPathComponent("Global", isDirectory: true)
    nonisolated static let projectsDirectory = directory.appendingPathComponent("Projects", isDirectory: true)
    private let index = directory.appendingPathComponent("workspaces.json")
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published var error = ""
    /// Set by ChatController: a queued or running turn froze this project.
    var inUse: (UUID) -> Bool = { _ in false }

    init() {
        let files = FileManager.default
        try? files.createDirectory(at: Self.projectsDirectory, withIntermediateDirectories: true)
        try? files.createDirectory(at: Self.globalDirectory.appendingPathComponent("skills"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index) {
            do { workspaces = try JSONDecoder().decode([WorkspaceRecord].self, from: data) }
            catch { self.error = "项目列表读取失败：\(error.localizedDescription)" }
        }
    }

    func root(_ id: UUID) -> URL { Self.projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func record(_ id: UUID?) -> WorkspaceRecord? { id.flatMap { id in workspaces.first { $0.id == id } } }

    /// Resolved under the current container; nil when the project is gone.
    func snapshot(_ id: UUID) -> WorkspaceSnapshot? {
        guard let record = record(id) else { return nil }
        var directory: ObjCBool = false
        let root = root(id)
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { return nil }
        return WorkspaceSnapshot(id: id, name: record.name, root: root)
    }

    private func save() {
        do {
            try JSONEncoder().encode(workspaces).write(to: index, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "项目列表保存失败：\(error.localizedDescription)" }
    }

    @discardableResult
    func create(name: String) -> WorkspaceRecord? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let record = WorkspaceRecord(name: String(name.prefix(60)))
        do {
            try FileManager.default.createDirectory(at: root(record.id), withIntermediateDirectories: true)
        } catch { self.error = error.localizedDescription; return nil }
        workspaces.append(record); save()
        return record
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = String(name.prefix(60)); save()
    }

    /// Refused while a queued or running turn uses the project: its accepted
    /// root is never removed or replaced underneath it.
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard !inUse(id) else {
            error = "项目正在被排队或运行中的任务使用；任务结束后再删除。"
            return false
        }
        try? FileManager.default.removeItem(at: root(id))
        workspaces.removeAll { $0.id == id }; save()
        return true
    }

    /// Copies a user-picked folder into a new project (security-scoped read).
    func importFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let record = create(name: url.lastPathComponent) else { return }
        let destination = root(record.id)
        do {
            for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
            }
        } catch { self.error = "导入失败：\(error.localizedDescription)" }
    }

    /// Copies picked files into a project directory (never overwrites).
    func importFiles(_ urls: [URL], into directory: URL) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(url.lastPathComponent)) }
            catch { self.error = "导入 \(url.lastPathComponent) 失败：\(error.localizedDescription)" }
        }
    }
}

/// Chooses the conversation's project; shown from the chip beside the model chip.
struct WorkspacePickerSheet: View {
    @ObservedObject var store: WorkspaceStore
    let current: UUID?
    let choose: (UUID?) -> Void
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(nil, title: "不使用项目", subtitle: "只有手机和网络工具")
                    ForEach(store.workspaces) { workspace in row(workspace.id, title: workspace.name, subtitle: nil) }
                } footer: {
                    Text("项目目录供文件工具和脚本使用，根目录的 AGENTS.md 会加入模型上下文。已开始的任务使用接受时的项目，之后的更改只影响新消息。")
                }
                Section {
                    Button("新建项目…") { creating = true }.accessibilityIdentifier("newWorkspace")
                    NavigationLink("管理项目") { WorkspaceListView(store: store) }
                }
            }
            .navigationTitle("本会话项目").navigationBarTitleDisplayMode(.inline)
            .alert("新建项目", isPresented: $creating) {
                TextField("项目名称", text: $name)
                Button("创建") { if let record = store.create(name: name) { choose(record.id) }; name = "" }
                Button("取消", role: .cancel) { name = "" }
            }
        }
    }

    private func row(_ id: UUID?, title: String, subtitle: String?) -> some View {
        Button { choose(id) } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if current == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }.accessibilityIdentifier("workspace-\(id?.uuidString ?? "none")")
    }
}

struct WorkspaceListView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var creating = false
    @State private var importing = false
    @State private var renaming: WorkspaceRecord?
    @State private var deleting: WorkspaceRecord?
    @State private var name = ""

    var body: some View {
        List {
            if !store.error.isEmpty { Text(store.error).font(.caption).foregroundStyle(.red) }
            ForEach(store.workspaces) { workspace in
                NavigationLink {
                    FileBrowserView(store: store, project: workspace.id, root: store.root(workspace.id), relative: ".", title: workspace.name)
                } label: { Label(workspace.name, systemImage: "folder") }
                .contextMenu {
                    Button("重命名") { name = workspace.name; renaming = workspace }
                    Button("删除", role: .destructive) { deleting = workspace }
                }
                .swipeActions { Button("删除", role: .destructive) { deleting = workspace } }
            }
        }
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建项目") { name = ""; creating = true }
                    Button("从“文件”导入文件夹") { importing = true }
                } label: { Image(systemName: "plus") }.accessibilityIdentifier("addWorkspace")
            }
        }
        .alert("新建项目", isPresented: $creating) {
            TextField("项目名称", text: $name)
            Button("创建") { store.create(name: name) }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名项目", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("项目名称", text: $name)
            Button("保存") { if let renaming { store.rename(renaming.id, to: name) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除项目及其中所有文件？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            if let deleting, store.inUse(deleting.id) {
                Button("知道了", role: .cancel) {}
            } else {
                Button("删除", role: .destructive) { if let deleting { store.delete(deleting.id) } }
            }
        } message: {
            if let deleting, store.inUse(deleting.id) {
                Text("「\(deleting.name)」正在被排队或运行中的任务使用，任务结束后才能删除。")
            } else {
                Text("使用该项目的会话将不再有项目目录；会话记录不受影响。")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.importFolder(url) }
        }
    }
}

/// Minimal project file manager: browse, create, import, export, edit, delete.
/// Deleting is refused while a queued or running turn uses the project (a
/// running script's .pocketagent/runs folder would vanish under it).
struct FileBrowserView: View {
    @ObservedObject var store: WorkspaceStore
    let project: UUID?
    let root: URL
    let relative: String
    let title: String
    @State private var entries: [WorkspaceFiles.Entry] = []
    @State private var message = ""
    @State private var creating: Bool?
    @State private var name = ""
    @State private var importing = false
    @State private var exporting = false

    private var directory: URL? { try? WorkspacePaths(root: root).resolve(relative) }

    var body: some View {
        List {
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            ForEach(entries, id: \.path) { entry in
                let display = (entry.path as NSString).lastPathComponent
                if entry.isDirectory {
                    NavigationLink { FileBrowserView(store: store, project: project, root: root, relative: entry.path, title: display) } label: {
                        Label(display, systemImage: "folder")
                    }
                } else if entry.isLink {
                    Label(display, systemImage: "link").foregroundStyle(.secondary)
                } else {
                    NavigationLink { TextFileEditor(root: root, relative: entry.path) } label: {
                        LabeledContent { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) } label: {
                            Label(display, systemImage: "doc.text")
                        }
                    }
                }
            }
            .onDelete { offsets in
                if let project, store.inUse(project) {
                    message = "这个项目正被排队或运行中的对话使用，结束后才能删除文件。"
                    return
                }
                for index in offsets {
                    do { try WorkspacePaths(root: root).remove(entries[index].path) } catch { message = error.localizedDescription }
                }
                reload()
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建文本文件") { name = relative == "." ? "AGENTS.md" : ""; creating = true }
                    Button("新建文件夹") { name = ""; creating = false }
                    Button("从“文件”导入") { importing = true }
                    Button("导出此文件夹到“文件”") { exporting = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("fileActions")
            }
        }
        .alert(creating == true ? "新建文件" : "新建文件夹", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("名称", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("创建") { create(file: creating == true) }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, let directory { store.importFiles(urls, into: directory); reload() }
        }
        .sheet(isPresented: $exporting) { if let directory { FolderExporter(url: directory) } }
        .onAppear(perform: reload)
    }

    private func reload() {
        do { entries = try WorkspaceFiles(root: root).list(relative, limit: 2000).entries; message = "" }
        catch { message = error.localizedDescription }
    }

    private func create(file: Bool) {
        let path = relative == "." ? name : relative + "/" + name
        do {
            if file { _ = try WorkspaceFiles(root: root).write(path, content: "", createOnly: true) }
            else { try WorkspacePaths(root: root).createDirectories(path) }
        } catch { message = error.localizedDescription }
        reload()
    }
}

/// Plain UTF-8 editor; saving is an atomic replace inside the project.
struct TextFileEditor: View {
    let root: URL
    let relative: String
    @State private var text = ""
    @State private var original = ""
    @State private var message = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!loaded)
                .accessibilityIdentifier("fileEditor")
        }
        .navigationTitle((relative as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }.disabled(!loaded || text == original).accessibilityIdentifier("saveFile")
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let data = try WorkspacePaths(root: root).readFile(relative, limit: 2 * 1024 * 1024)
            guard let value = String(data: data, encoding: .utf8) else { message = "不是 UTF-8 文本，不能编辑。"; return }
            text = value; original = value; loaded = true
        } catch WorkspaceError.notFound { text = ""; original = ""; loaded = true
        } catch { message = error.localizedDescription }
    }

    private func save() {
        do { try WorkspacePaths(root: root).writeFile(relative, data: Data(text.utf8)); original = text; message = "已保存。" }
        catch { message = error.localizedDescription }
    }
}

/// Exports a copy of a folder through the system document picker.
struct FolderExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// Settings section: projects, global rules and skills, script runtime state.
struct RulesSettingsSection: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Section {
            NavigationLink { WorkspaceListView(store: store) } label: {
                LabeledContent("项目", value: "\(store.workspaces.count) 个")
            }.accessibilityIdentifier("manageWorkspaces")
            NavigationLink { TextFileEditor(root: WorkspaceStore.globalDirectory, relative: "AGENTS.md") } label: {
                Text("全局 AGENTS.md")
            }.accessibilityIdentifier("globalRules")
            NavigationLink {
                FileBrowserView(store: store, project: nil, root: WorkspaceStore.globalDirectory, relative: "skills", title: "全局技能")
            } label: { Text("全局技能") }.accessibilityIdentifier("globalSkills")
        } header: { Text("项目与规则") } footer: {
            Text("全局 AGENTS.md 和所选项目根目录的 AGENTS.md 会加入每轮的模型上下文；技能放在 skills/<名称>/SKILL.md（项目内为 .agents/skills），模型按需读取。项目和规则只保存在本机，不会同步。脚本在本机的 Linux 环境中运行，只能看到所选项目。")
        }
    }
}
