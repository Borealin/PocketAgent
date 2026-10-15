import AgentKit
import Foundation
import Synchronization

/// Metadata of one model stream attempt for the opt-in run log: event kinds
/// and counts, time to the first event and to the end, how it ended and, for a
/// failure, its category. Never request or response content, provider
/// messages, endpoints or credentials.
nonisolated struct ModelStreamTrace: Sendable {
    enum Path: String, Sendable { case main, summary }
    let path: Path
    private let started = ContinuousClock.now
    private(set) var counts: [String: Int] = [:]
    private(set) var firstEventMs: Int?
    private(set) var endedMs: Int?
    /// "ended" (the event sequence ended without an error), "cancelled" or
    /// "failed"; nil while running. Whether the provider's terminal arrived is
    /// `terminalReason`, which "ended" alone does not imply.
    private(set) var outcome: String?
    /// The stop reason of the `.finished` terminal, when it arrived.
    private(set) var terminalReason: String?
    private(set) var failure: StreamFailureCategory?

    init(path: Path) { self.path = path }

    private var elapsedMs: Int { Int((ContinuousClock.now - started) / .milliseconds(1)) }

    mutating func saw(_ event: AgentModelStreamEvent) {
        if firstEventMs == nil { firstEventMs = elapsedMs }
        counts[Self.kind(event), default: 0] += 1
        if case .finished(let reason) = event { terminalReason = reason.rawValue }
    }
    mutating func finished() { endedMs = elapsedMs; outcome = "ended" }
    mutating func failed(_ error: any Error, cancelled: Bool) {
        endedMs = elapsedMs
        let category = StreamFailureCategory.of(error)
        outcome = cancelled || category.kind == "cancelled" ? "cancelled" : "failed"
        failure = category
    }

    /// The case name only; associated values (text, arguments) are never read.
    static func kind(_ event: AgentModelStreamEvent) -> String {
        switch event {
        case .textDelta: "textDelta"
        case .textSnapshot: "textSnapshot"
        case .reasoningDelta: "reasoningDelta"
        case .reasoningSnapshot: "reasoningSnapshot"
        case .toolCallDelta: "toolCallDelta"
        case .toolCallSnapshot: "toolCallSnapshot"
        case .providerItem: "providerItem"
        case .webSearch: "webSearch"
        case .usage: "usage"
        case .finished: "finished"
        }
    }

    var fields: [String: any Sendable] {
        var fields: [String: any Sendable] = ["path": path.rawValue, "events": counts, "outcome": outcome ?? "running",
                                              "terminalSeen": terminalReason != nil]
        if let terminalReason { fields["terminalReason"] = terminalReason }
        if let firstEventMs { fields["firstEventMs"] = firstEventMs }
        if let endedMs { fields["endedMs"] = endedMs }
        if let failure { fields.merge(failure.fields) { a, _ in a } }
        return fields
    }
}

/// Where a stream failure came from, by type and allowlisted code only.
nonisolated struct StreamFailureCategory: Sendable, Equatable {
    /// "cancelled", "urlError", "http", "providerResponse" (an AgentKit
    /// response error other than HTTP status), "providerStreamError" (an error
    /// frame inside the stream), "contextLimit" or "other".
    let kind: String
    /// The error's type name (a code identifier, not a message).
    let typeName: String
    let urlErrorCode: Int?
    /// The HTTP status of an `AgentProviderError.http` (never its body).
    let httpStatus: Int?
    /// A provider error code from a known set; others are only marked present.
    let providerCode: String?
    let providerCodePresent: Bool

    static let knownProviderCodes: Set<String> = [
        "server_error", "internal_error", "overloaded_error", "overloaded", "rate_limit_exceeded", "rate_limit_error",
        "insufficient_quota", "invalid_request_error", "timeout", "service_unavailable", "bad_gateway",
        "context_length_exceeded", "context_window_exceeded", "model_context_window_exceeded", "prompt_too_long",
    ]

    static func of(_ error: any Error) -> StreamFailureCategory {
        let typeName = String(reflecting: type(of: error))
        if error is CancellationError { return .init(kind: "cancelled", typeName: typeName) }
        if let limit = error as? ProviderContextLimit {
            return .init(kind: "contextLimit", typeName: typeName, code: limit.code)
        }
        if let url = error as? URLError {
            return .init(kind: url.code == .cancelled ? "cancelled" : "urlError", typeName: typeName, urlErrorCode: url.code.rawValue)
        }
        if let provider = error as? AgentProviderError {
            if case .http(let status, _) = provider { return .init(kind: "http", typeName: typeName, httpStatus: status) }
            return .init(kind: "providerResponse", typeName: typeName)
        }
        if let stream = StreamFailureBridge.read(error) {
            return .init(kind: "providerStreamError", typeName: typeName, code: stream.code)
        }
        return .init(kind: "other", typeName: typeName)
    }

    private init(kind: String, typeName: String, urlErrorCode: Int? = nil, httpStatus: Int? = nil, code: String? = nil) {
        self.kind = kind; self.typeName = typeName; self.urlErrorCode = urlErrorCode; self.httpStatus = httpStatus
        providerCodePresent = code != nil
        providerCode = code.flatMap { Self.knownProviderCodes.contains($0) ? $0 : nil }
    }

    var fields: [String: any Sendable] {
        var fields: [String: any Sendable] = ["failureKind": kind, "failureType": typeName, "providerCodePresent": providerCodePresent]
        if let urlErrorCode { fields["urlErrorCode"] = urlErrorCode }
        if let httpStatus { fields["httpStatus"] = httpStatus }
        if let providerCode { fields["providerCode"] = providerCode }
        return fields
    }
}

/// A run's log identity and its one diagnostic sequence, created when the run
/// starts and shared by every source that logs late (script stop path, model
/// streams): an event delivered later (after its run ended, while another
/// runs) still goes to its own run's log with its original time and order.
nonisolated final class RunLogStamp: Sendable {
    struct Origin: Sendable {
        let runID: String
        let url: URL?
        let sequence: Int
        let time: Date
        /// Uptime (stops in system sleep) and the raw monotonic clock, in ms.
        let upMs: UInt64
        let rawMs: UInt64
    }

    let runID: String
    let url: URL?
    private let next = Mutex(0)

    init(runID: String, url: URL?) { self.runID = runID; self.url = url }

    func origin() -> Origin {
        let sequence = next.withLock { value in value += 1; return value }
        return Origin(runID: runID, url: url, sequence: sequence, time: Date(),
                      upMs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000,
                      rawMs: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
    }
}
