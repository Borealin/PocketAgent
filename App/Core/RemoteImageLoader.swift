import Foundation

/// One user-initiated image download: ephemeral session without cookies,
/// cache or credentials; every redirect and the final URL must satisfy
/// `RemoteImagePolicy`; the body is bounded while it streams and the task is
/// cancelled as soon as it would exceed the limit.
nonisolated final class RemoteImageLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = BoundedBuffer(limit: RemoteImagePolicy.maxBytes)
    private var continuation: CheckedContinuation<Data, any Error>?
    private var problem: String?
    /// Completion that arrived before the continuation was installed.
    private var early: Result<Data, any Error>?
    private let lock = NSLock()

    /// `configure` exists for tests (stub protocols); the app passes nothing.
    static func load(_ url: URL, configure: (URLSessionConfiguration) -> Void = { _ in }) async throws -> Data {
        guard RemoteImagePolicy.allows(url) else { throw RemoteImageError("图片地址不受支持") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configure(configuration)
        let loader = RemoteImageLoader()
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early = loader.lock.withLock { () -> Result<Data, any Error>? in
                    if loader.early == nil { loader.continuation = continuation }
                    return loader.early
                }
                if let early { continuation.resume(with: early) } else { task.resume() }
            }
        } onCancel: { task.cancel() }
    }

    private func reject(_ task: URLSessionTask, _ reason: String) {
        lock.withLock { if problem == nil { problem = reason } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard RemoteImagePolicy.allows(request.url) else {
            reject(task, "图片重定向到不受支持的地址，已停止")
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, RemoteImagePolicy.allows(http.url) else {
            reject(dataTask, "图片服务器返回无效响应"); completionHandler(.cancel); return
        }
        if let type = http.mimeType?.lowercased(), !type.hasPrefix("image/"), type != "application/octet-stream" {
            reject(dataTask, "返回的内容不是图片"); completionHandler(.cancel); return
        }
        guard RemoteImagePolicy.acceptsDeclaredLength(http.expectedContentLength) else {
            reject(dataTask, "图片超过 20 MB"); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let fits = lock.withLock { buffer.append(data) }
        if !fits { reject(dataTask, "图片超过 20 MB") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            let result: Result<Data, any Error> = problem.map { .failure(RemoteImageError($0)) }
                ?? error.map { .failure($0) } ?? .success(buffer.data)
            guard let continuation = self.continuation else { early = result; return nil }
            self.continuation = nil
            continuation.resume(with: result)
            return continuation
        }
        _ = continuation
    }
}

nonisolated struct RemoteImageError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
