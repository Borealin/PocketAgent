import Darwin
import Foundation

/// A project directory owned by the app. Only the ID and name are stored;
/// the absolute root is resolved under the current container at use time.
nonisolated struct WorkspaceRecord: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}

/// The workspace an accepted turn uses, frozen when it was queued.
nonisolated struct WorkspaceSnapshot: Hashable, Sendable {
    let id: UUID
    let name: String
    let root: URL
}

nonisolated enum WorkspaceError: LocalizedError, Equatable {
    case invalidPath(String)
    case outsideWorkspace(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case binary(String)
    case tooLarge(String, Int)
    case noMatch(String)
    case ambiguousMatch(String, Int)
    case exists(String)
    case searchBudget(Int)
    var errorDescription: String? {
        switch self {
        case .invalidPath(let p): "无效路径：\(p)。使用相对于项目根目录的路径，不能包含 .. 或以 / 开头。"
        case .outsideWorkspace(let p): "路径 \(p) 指向项目目录之外（例如符号链接），已拒绝。"
        case .notFound(let p): "不存在：\(p)"
        case .notAFile(let p): "不是普通文件：\(p)"
        case .notADirectory(let p): "不是目录：\(p)"
        case .binary(let p): "\(p) 不是 UTF-8 文本文件。"
        case .tooLarge(let p, let limit): "\(p) 超过 \(limit) 字节上限。"
        case .noMatch(let p): "\(p) 中找不到要替换的原文。请先 read_file 获取准确内容。"
        case .ambiguousMatch(let p, let n): "\(p) 中原文出现 \(n) 次；请提供更长且唯一的上下文，或设置 replace_all。"
        case .exists(let p): "\(p) 已存在。"
        case .searchBudget(let seconds): "搜索超过 \(seconds) 秒时间预算，已停止。请缩小目录范围或简化正则表达式。"
        }
    }
}

/// Path confinement shared by the native file tools and every host-side
/// access to guest-written files. Inputs are relative paths without `..`.
/// Each operation opens the root and walks every component with
/// openat(O_NOFOLLOW) on live directory descriptors, so neither a symbolic
/// link nor a directory swapped for one while the guest runs can lead outside
/// the project. Symbolic links inside a project are listed but never followed.
nonisolated struct WorkspacePaths: Sendable {
    let root: URL

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        var info = stat()
        guard stat(self.root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw WorkspaceError.notFound(".") }
    }

    /// Normalized components; "" or "." is the root.
    static func components(_ relative: String) throws -> [String] {
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.contains("\0") else {
            throw WorkspaceError.invalidPath(relative)
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else { throw WorkspaceError.invalidPath(relative) }
        return parts
    }

    /// Display/location URL for a confined path (validated by an anchored walk).
    func resolve(_ relative: String, mustExist: Bool = true) throws -> URL {
        let parts = try Self.components(relative)
        if mustExist || !parts.isEmpty {
            let dir = try openDirectory(parts.dropLast())
            defer { close(dir) }
            if let last = parts.last, mustExist {
                var info = stat()
                guard fstatat(dir, last, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkspaceError.notFound(relative) }
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw WorkspaceError.outsideWorkspace(relative) }
            }
        }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        let rest = path.dropFirst(base.count).drop { $0 == "/" }
        return rest.isEmpty ? "." : String(rest)
    }

    /// Descriptor of the directory at `parts`, each component opened without
    /// following links; `create` makes missing directories. Caller closes it.
    func openDirectory<C: Collection>(_ parts: C, create: Bool = false) throws -> Int32 where C.Element == String {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceError.notFound(".") }
        var walked: [String] = []
        for part in parts {
            walked.append(part)
            var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                if mkdirat(fd, part, 0o755) != 0, errno != EEXIST { close(fd); throw WorkspaceError.invalidPath(walked.joined(separator: "/")) }
                next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0 {
                let failure = errno
                var info = stat()
                let isLink = fstatat(fd, part, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
                close(fd)
                let path = walked.joined(separator: "/")
                if isLink || failure == ELOOP { throw WorkspaceError.outsideWorkspace(path) }
                throw failure == ENOTDIR ? WorkspaceError.notADirectory(path) : WorkspaceError.notFound(path)
            }
            close(fd)
            fd = next
        }
        return fd
    }

    /// Opens a regular file without following any link. Caller closes it.
    func openFile(_ relative: String, flags: Int32 = O_RDONLY) throws -> Int32 {
        let parts = try Self.components(relative)
        guard let name = parts.last else { throw WorkspaceError.notAFile(relative) }
        let dir = try openDirectory(parts.dropLast())
        defer { close(dir) }
        let fd = openat(dir, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ELOOP { throw WorkspaceError.outsideWorkspace(relative) }
            throw WorkspaceError.notFound(relative)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw WorkspaceError.notAFile(relative) }
        return fd
    }

    func status(_ relative: String) -> stat? {
        guard let parts = try? Self.components(relative), let name = parts.last,
              let dir = try? openDirectory(parts.dropLast()) else { return nil }
        defer { close(dir) }
        var info = stat()
        return fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? info : nil
    }

    func readFile(_ relative: String, limit: Int) throws -> Data {
        let fd = try openFile(relative)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= limit else { throw WorkspaceError.tooLarge(relative, limit) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw WorkspaceError.tooLarge(relative, limit) }
        return data
    }

    /// Atomic replace: an exclusive temporary file in the anchored parent,
    /// then renameat (which replaces the entry and never follows a link).
    func writeFile(_ relative: String, data: Data, createOnly: Bool = false, mode: mode_t = 0o644) throws {
        let parts = try Self.components(relative)
        guard let name = parts.last else { throw WorkspaceError.invalidPath(relative) }
        let dir = try openDirectory(parts.dropLast(), create: true)
        defer { close(dir) }
        var existing = stat()
        if fstatat(dir, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            if createOnly { throw WorkspaceError.exists(relative) }
            guard (existing.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.notAFile(relative) }
        }
        let temporary = ".\(name.prefix(80)).\(UUID().uuidString).tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw WorkspaceError.invalidPath(relative) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            fchmod(fd, mode)
            close(fd)
        } catch { close(fd); unlinkat(dir, temporary, 0); throw error }
        let renamed = createOnly ? renameatx_np(dir, temporary, dir, name, UInt32(RENAME_EXCL)) : renameat(dir, temporary, dir, name)
        guard renamed == 0 else {
            let failure = errno
            unlinkat(dir, temporary, 0)
            throw failure == EEXIST ? WorkspaceError.exists(relative) : WorkspaceError.invalidPath(relative)
        }
    }

    func createDirectories(_ relative: String) throws {
        close(try openDirectory(try Self.components(relative), create: true))
    }

    /// Names in a directory with their lstat information.
    func entries(_ relative: String) throws -> [(name: String, info: stat)] {
        let fd = try openDirectory(try Self.components(relative))
        guard let stream = fdopendir(fd) else { close(fd); throw WorkspaceError.notADirectory(relative) }
        defer { closedir(stream) }
        var result: [(String, stat)] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            if fstatat(dirfd(stream), name, &info, AT_SYMLINK_NOFOLLOW) == 0 { result.append((name, info)) }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Removes a file or directory tree without following any link.
    func remove(_ relative: String) throws {
        let parts = try Self.components(relative)
        guard let name = parts.last else { throw WorkspaceError.invalidPath(relative) }
        let dir = try openDirectory(parts.dropLast())
        defer { close(dir) }
        try Self.removeTree(dir, name)
    }

    private static func removeTree(_ dir: Int32, _ name: String) throws {
        var info = stat()
        guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            let child = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0, let stream = fdopendir(child) else { if child >= 0 { close(child) }; throw WorkspaceError.invalidPath(name) }
            var names: [String] = []
            while let entry = readdir(stream) {
                let entryName = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
                if entryName != ".", entryName != ".." { names.append(entryName) }
            }
            for entryName in names { try removeTree(dirfd(stream), entryName) }
            closedir(stream)
            guard unlinkat(dir, name, AT_REMOVEDIR) == 0 else { throw WorkspaceError.invalidPath(name) }
        } else if unlinkat(dir, name, 0) != 0 { throw WorkspaceError.invalidPath(name) }
    }
}

/// Native list/read/search/write/patch operations confined to one workspace.
/// Results are bounded text intended for model context.
nonisolated struct WorkspaceFiles: Sendable {
    static let readLimit = 4 * 1024 * 1024
    static let writeLimit = 4 * 1024 * 1024
    static let resultLimit = 48 * 1024
    let paths: WorkspacePaths

    init(root: URL) throws { paths = try WorkspacePaths(root: root) }
    init(paths: WorkspacePaths) { self.paths = paths }

    struct Entry: Hashable, Sendable {
        var path: String
        var isDirectory: Bool
        var isLink: Bool
        var size: Int64
    }

    func list(_ relative: String = ".", recursive: Bool = false, limit: Int = 400) throws -> (entries: [Entry], truncated: Bool) {
        let start = try WorkspacePaths.components(relative).joined(separator: "/")
        var result: [Entry] = []
        var queue = [start]
        while !queue.isEmpty {
            try Task.checkCancellation()
            let directory = queue.removeFirst()
            guard let items = try? paths.entries(directory.isEmpty ? "." : directory) else {
                if directory == start { _ = try paths.entries(directory.isEmpty ? "." : directory) }
                continue
            }
            for (name, info) in items {
                let kind = info.st_mode & S_IFMT
                let path = directory.isEmpty ? name : directory + "/" + name
                if result.count >= limit { return (result, true) }
                result.append(Entry(path: path, isDirectory: kind == S_IFDIR, isLink: kind == S_IFLNK, size: Int64(info.st_size)))
                // Recursion never descends through links or VCS/dependency internals.
                if recursive, kind == S_IFDIR, ![".git", "node_modules"].contains(name) { queue.append(path) }
            }
        }
        return (result, false)
    }

    func read(_ relative: String, offset: Int = 1, limit: Int = 400) throws -> String {
        let data = try paths.readFile(relative, limit: Self.readLimit)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.binary(relative) }
        let lines = text.components(separatedBy: "\n")
        let start = max(1, offset), count = max(1, min(limit, 2000))
        guard start <= max(lines.count, 1) else { return "（\(relative) 共 \(lines.count) 行，起始行超出范围）" }
        let end = min(lines.count, start + count - 1)
        var out = ""
        for index in (start - 1)..<end {
            let line = "\(index + 1)\t\(lines[index])\n"
            if out.utf8.count + line.utf8.count > Self.resultLimit {
                out += "…（输出截断；用 offset=\(index + 1) 继续读取）\n"; return out
            }
            out += line
        }
        if end < lines.count { out += "…（共 \(lines.count) 行；用 offset=\(end + 1) 继续读取）\n" }
        return out
    }

    struct Match: Hashable, Sendable { var path: String; var line: Int; var text: String }

    static let searchBudget: TimeInterval = 15
    /// Matched lines are cut to this many characters and the whole result to
    /// `resultLimit`, so the model receives every match line it is shown.
    static let matchTextLimit = 200

    /// Literal or regular-expression search. Regex matching reports progress
    /// so a pathological pattern stops at Task cancellation or after `budget`
    /// seconds instead of running inside NSRegularExpression indefinitely.
    func search(_ pattern: String, in relative: String = ".", regex: Bool = false, limit: Int = 200,
                budget: TimeInterval = searchBudget) throws -> (matches: [Match], truncated: Bool) {
        guard !pattern.isEmpty else { throw WorkspaceError.invalidPath(pattern) }
        let expression = try regex ? NSRegularExpression(pattern: pattern) : nil
        let deadline = Date().addingTimeInterval(budget)
        func check() throws {
            try Task.checkCancellation()
            if Date() >= deadline { throw WorkspaceError.searchBudget(Int(budget.rounded(.up))) }
        }
        var matches: [Match] = []
        var size = 0
        let parts = try WorkspacePaths.components(relative)
        let single = !parts.isEmpty && paths.status(relative).map { ($0.st_mode & S_IFMT) == S_IFREG } == true
        let listing = single ? (entries: [Entry(path: relative, isDirectory: false, isLink: false, size: 0)], truncated: false)
            : try list(relative, recursive: true, limit: 5000)
        let candidates = listing.entries.filter { !$0.isDirectory && !$0.isLink && $0.size <= 2 * 1024 * 1024 }
        for entry in candidates {
            try check()
            guard let data = try? paths.readFile(entry.path, limit: 2 * 1024 * 1024), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let hit: Bool
                if let expression {
                    var found = false, stopped = false
                    expression.enumerateMatches(in: line, options: [.reportProgress],
                                                range: NSRange(line.startIndex..., in: line)) { result, _, stop in
                        if result != nil { found = true; stop.pointee = true }
                        else if Task.isCancelled || Date() >= deadline { stopped = true; stop.pointee = true }
                    }
                    if stopped { try check() }
                    hit = found
                } else {
                    if index % 4096 == 0 { try check() }
                    hit = line.contains(pattern)
                }
                guard hit else { continue }
                let match = Match(path: entry.path, line: index + 1, text: String(line.prefix(Self.matchTextLimit)))
                size += match.path.utf8.count + match.text.utf8.count + 16
                if matches.count >= limit || size > Self.resultLimit { return (matches, true) }
                matches.append(match)
            }
        }
        return (matches, listing.truncated)
    }

    func write(_ relative: String, content: String, createOnly: Bool = false) throws -> Int {
        let data = Data(content.utf8)
        guard data.count <= Self.writeLimit else { throw WorkspaceError.tooLarge(relative, Self.writeLimit) }
        try paths.writeFile(relative, data: data, createOnly: createOnly)
        return data.count
    }

    struct Edit: Hashable, Sendable { var old: String; var new: String; var replaceAll = false }

    /// Applies exact-text replacements in order; each `old` must match once
    /// unless `replaceAll`. Nothing is written if any edit fails.
    func patch(_ relative: String, edits: [Edit]) throws -> Int {
        guard !edits.isEmpty else { throw WorkspaceError.noMatch(relative) }
        let data = try paths.readFile(relative, limit: Self.writeLimit)
        guard !data.contains(0), var text = String(data: data, encoding: .utf8) else { throw WorkspaceError.binary(relative) }
        var replaced = 0
        for edit in edits {
            guard !edit.old.isEmpty else { throw WorkspaceError.noMatch(relative) }
            let count = text.components(separatedBy: edit.old).count - 1
            guard count > 0 else { throw WorkspaceError.noMatch(relative) }
            guard count == 1 || edit.replaceAll else { throw WorkspaceError.ambiguousMatch(relative, count) }
            text = text.replacingOccurrences(of: edit.old, with: edit.new)
            replaced += count
        }
        try paths.writeFile(relative, data: Data(text.utf8))
        return replaced
    }
}
