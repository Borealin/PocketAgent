import AgentKit
import Darwin
import Foundation

/// Destination rules for the native http_request tool, for the initial URL
/// and every redirect: https only, no embedded credentials, never ports 8100
/// (WebDriverAgent) or 62078 (lockdown), no local-only names, and no
/// loopback, private, link-local, CGNAT or multicast address, either as a
/// literal or among the addresses the name resolves to just before the
/// request. URLSession then resolves the name again itself; the connection is
/// not pinned to the checked addresses. TLS authenticates the requested
/// hostname, not the address: it keeps the phone's WebDriverAgent, lockdown
/// and plain LAN services (no trusted certificate for that name) from
/// receiving the request, but a server on a local address that holds a
/// publicly trusted certificate for its own public name can still receive it
/// if that name's DNS answer changes after the check.
nonisolated struct NetworkPolicy: Sendable {
    /// Tests use a plain-HTTP loopback server; production never sets this.
    var allowLoopback = false
    /// Name resolution (getaddrinfo); tests substitute a slow resolver.
    var resolver: @Sendable (String) throws -> [String] = { try NetworkPolicy.resolve($0) }

    static func isPublic(ipv4 a: UInt32) -> Bool {
        !((a >> 24) == 0 || (a >> 24) == 10 || (a >> 24) == 127 || (a & 0xfff0_0000) == 0xac10_0000 ||
          (a & 0xffff_0000) == 0xc0a8_0000 || (a & 0xffc0_0000) == 0x6440_0000 ||
          (a & 0xffff_0000) == 0xa9fe_0000 || a >= 0xe000_0000)
    }

    static func isPublic(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isPublic(ipv4: bytes[12..<16].reduce(0) { $0 << 8 | UInt32($1) })
        }
        if bytes.allSatisfy({ $0 == 0 }) || bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }   // link-local
        if (bytes[0] & 0xfe) == 0xfc { return false }                       // unique local
        if bytes[0] == 0xff { return false }                                // multicast
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }           // IPv4-compatible
        return true
    }

    func allows(address: String) -> Bool? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            if allowLoopback, a >> 24 == 127 { return true }
            return Self.isPublic(ipv4: a)
        }
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if allowLoopback, bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            return Self.isPublic(ipv6: bytes)
        }
        return nil
    }

    func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || allowLoopback && scheme == "http" else {
            throw HTTPToolError.policy("只允许 https URL：明文 http 无法证明连接到的是公共主机。")
        }
        guard url.user == nil, url.password == nil else { throw HTTPToolError.policy("URL 不能包含用户名或密码。") }
        guard var host = url.host?.lowercased(), !host.isEmpty else { throw HTTPToolError.policy("URL 缺少主机名。") }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // WebDriverAgent (8100) and lockdown (62078) are never targets, even
        // if a public name later resolves to this phone.
        if let port = url.port, [8100, 62078].contains(port), !allowLoopback {
            throw HTTPToolError.policy("不允许访问端口 \(port)。")
        }
        if let literal = allows(address: host) {
            guard literal else { throw HTTPToolError.policy("不允许访问本机、局域网或保留地址：\(host)") }
            return
        }
        let localNames = ["localhost", "localhost.localdomain", "ip6-localhost"]
        if !allowLoopback, localNames.contains(host) || host.hasSuffix(".localhost") || host.hasSuffix(".local") ||
            host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") {
            throw HTTPToolError.policy("不允许访问本机或局域网主机名：\(host)")
        }
    }

    /// Resolves `host` and requires every address to be allowed. Cancellation
    /// ends the wait at once (see `resolveCancellably`).
    func checkResolved(_ url: URL) async throws {
        try check(url)
        guard let host = url.host, allows(address: host) == nil else { return }
        let addresses = try await Self.resolveCancellably(host, resolver)
        guard !addresses.isEmpty else { throw HTTPToolError.policy("无法解析主机名：\(host)") }
        for address in addresses where allows(address: address) != true {
            throw HTTPToolError.policy("\(host) 解析到不允许的地址 \(address)。")
        }
    }

    /// getaddrinfo cannot be interrupted, so it runs on a dispatch thread
    /// that owns its arguments; a cancelled caller stops waiting immediately
    /// and the late answer is dropped. The continuation resumes exactly once.
    static func resolveCancellably(_ host: String, _ resolver: @escaping @Sendable (String) throws -> [String]) async throws -> [String] {
        let resolution = Resolution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard resolution.wait(continuation) else { return }
                DispatchQueue.global(qos: .utility).async { resolution.finish(Result { try resolver(host) }) }
            }
        } onCancel: { resolution.finish(.failure(CancellationError())) }
    }

    private final class Resolution: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String], any Error>?
        private var result: Result<[String], any Error>?

        /// False if the outcome (cancellation) arrived first; then it resumes at once.
        func wait(_ continuation: CheckedContinuation<[String], any Error>) -> Bool {
            let early = lock.withLock { () -> Result<[String], any Error>? in
                if result == nil { self.continuation = continuation }
                return result
            }
            if let early { continuation.resume(with: early); return false }
            return true
        }

        /// The first outcome wins; later ones are ignored.
        func finish(_ outcome: Result<[String], any Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<[String], any Error>? in
                guard result == nil else { return nil }
                result = outcome
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: outcome)
        }
    }

    static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw HTTPToolError.policy("无法解析主机名：\(host)")
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }
}

nonisolated enum HTTPToolError: LocalizedError, Equatable {
    case policy(String)
    case invalid(String)
    case tooLarge(Int)
    var errorDescription: String? {
        switch self {
        case .policy(let message), .invalid(let message): message
        case .tooLarge(let limit): "请求体超过 \(limit) 字节上限。"
        }
    }
}

nonisolated struct HTTPToolResult: Sendable {
    var status: Int
    var url: String
    var headers: [String: String]
    var body: Data
    var truncated: Bool
    var contentType: String
}

/// The native http_request tool: arbitrary method, headers and body (text or
/// JSON), bounded response and cancellation through Swift task cancellation.
/// Uses an ephemeral session without cookies, cache or credential storage;
/// provider API keys are never available to it.
nonisolated final class HTTPTool: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let requestLimit = 1024 * 1024
    static let responseLimit = 2 * 1024 * 1024
    static let modelBodyLimit = 32 * 1024
    let policy: NetworkPolicy
    private let session: URLSession

    init(policy: NetworkPolicy = NetworkPolicy()) {
        self.policy = policy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 130
        session = URLSession(configuration: configuration)
        super.init()
    }

    static let blockedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding",
                                              "proxy-authorization", "proxy-connection", "upgrade", "te"]

    /// Builds the request from tool arguments: method, url, headers, body or json, timeout_seconds.
    func request(_ args: [String: AgentJSONValue]) throws -> URLRequest {
        guard let text = args["url"]?.stringValue, let url = URL(string: text) else { throw HTTPToolError.invalid("缺少有效 url。") }
        try policy.check(url)
        let method = (args["method"]?.stringValue ?? "GET").uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else {
            throw HTTPToolError.invalid("不支持的 method：\(method)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(max(args["timeout_seconds"]?.numberValue ?? 30, 1), 120)
        request.httpShouldHandleCookies = false
        for (name, value) in args["headers"]?.objectValue ?? [:] {
            guard let value = value.stringValue else { throw HTTPToolError.invalid("请求头 \(name) 的值必须是字符串。") }
            // Scalars, not Characters: "\r\n" is a single grapheme in Swift.
            let control = { (text: String) in text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7f } }
            guard !name.isEmpty, !Self.blockedHeaders.contains(name.lowercased()), !name.unicodeScalars.contains(":"),
                  !control(name), !control(value) else { throw HTTPToolError.invalid("不允许的请求头：\(name)") }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if method == "GET" || method == "HEAD" {
            // Structured calls often fill unused optional fields with null.
            // GET/HEAD have no entity; never discard an actual payload silently.
            let hasJSONBody = args["json"].map { $0 != .null } ?? false
            let hasTextBody = !(args["body"]?.stringValue ?? "").isEmpty
            guard !hasJSONBody, !hasTextBody else {
                throw HTTPToolError.invalid("\(method) 不支持请求体；请把参数放在 URL 查询字符串（query）中，或改用 POST、PUT 等支持请求体的方法。")
            }
        } else if let json = args["json"] {
            // Body methods retain explicit JSON null as the entity `null`.
            let data = try JSONEncoder().encode(json)
            guard data.count <= Self.requestLimit else { throw HTTPToolError.tooLarge(Self.requestLimit) }
            request.httpBody = data
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } else if let body = args["body"]?.stringValue, !body.isEmpty {
            let data = Data(body.utf8)
            guard data.count <= Self.requestLimit else { throw HTTPToolError.tooLarge(Self.requestLimit) }
            request.httpBody = data
        }
        return request
    }

    /// `timeout_seconds` bounds the whole call, name resolution included
    /// (URLSession's own interval only bounds inactivity, so a slowly
    /// dripping server could hold it).
    func perform(_ request: URLRequest) async throws -> HTTPToolResult {
        let limit = request.timeoutInterval
        return try await withThrowingTaskGroup(of: HTTPToolResult.self) { group in
            group.addTask { try await self.transfer(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw HTTPToolError.invalid("请求超过 \(Int(limit)) 秒总时限，已取消。")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func transfer(_ request: URLRequest) async throws -> HTTPToolResult {
        guard let url = request.url else { throw HTTPToolError.invalid("缺少 URL。") }
        try await policy.checkResolved(url)
        // The deadline or Stop may have ended the resolution wait: send nothing.
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw HTTPToolError.invalid("不是 HTTP 响应。") }

        var body = Data()
        var truncated = false
        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            if body.count + buffer.count >= Self.responseLimit { truncated = true; break }
            buffer.append(byte)
            if buffer.count == 64 * 1024 { body.append(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        body.append(contentsOf: buffer)
        try Task.checkCancellation()
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields.prefix(40) {
            let name = "\(key)"
            if name.lowercased() == "set-cookie" { continue }
            headers[HostToolResult.clip(name, bytes: 100)] = HostToolResult.clip("\(value)", bytes: 500)
        }
        return HTTPToolResult(status: http.statusCode, url: http.url?.absoluteString ?? url.absoluteString,
                              headers: headers, body: body, truncated: truncated,
                              contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, (try? await policy.checkResolved(url)) != nil else { return nil }
        return request
    }

    /// The model-facing JSON text. `saved` names the workspace file holding the full body.
    static func render(_ result: HTTPToolResult, saved: String?) -> String {
        var object: [String: Any] = ["status": result.status, "url": result.url, "headers": result.headers,
                                     "content_type": result.contentType, "bytes": result.body.count,
                                     "truncated_at_limit": result.truncated]
        if let saved {
            object["saved_to"] = saved
            if result.truncated { object["saved_note"] = "响应超过 \(responseLimit) 字节上限，保存的文件只有前 \(responseLimit) 字节。" }
        }
        // The byte limit may split one UTF-8 character: drop at most its 3 leading bytes, never repair other invalid data.
        let cuts = result.body.count > modelBodyLimit ? 0...3 : 0...0
        if let text = cuts.lazy.compactMap({ String(data: result.body.prefix(modelBodyLimit - $0), encoding: .utf8) }).first {
            object["body"] = text
            if result.body.count > modelBodyLimit {
                object["body_note"] = "正文只显示前 \(modelBodyLimit) 字节；设置 save_to 可把收到的响应（最多 \(responseLimit) 字节）保存到项目文件。"
            }
        } else {
            object["body"] = ""
            object["body_note"] = "响应不是 UTF-8 文本；设置 save_to 保存到项目文件。"
        }
        // Escapes can make 32 KB of text several times longer in JSON.
        return HostToolResult.json(object, shortening: ["body", "headers"])
    }
}
