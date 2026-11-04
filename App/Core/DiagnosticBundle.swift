import Foundation
import CoreFoundation
import Darwin
import zlib

nonisolated enum DiagnosticExportScope: Hashable, Identifiable, Sendable {
    case recent
    case conversation(UUID)
    var id: String {
        switch self { case .recent: "recent"; case .conversation(let id): "conversation-\(id)" }
    }
}

nonisolated struct DiagnosticExportContext: Codable, Sendable {
    var appVersion: String
    var appBuild: String
    var systemVersion: String
    var deviceFamily: String
    var currentBackend: String
    var loggingEnabled: Bool
    var backgroundTaskNamespaceMatches: Bool
    var conversationState: String? = nil
    var windowWidth: Double? = nil
    var windowHeight: Double? = nil
    var displayScale: Double? = nil
    var orientation: String? = nil
}

nonisolated struct DiagnosticExportResult: Sendable {
    let url: URL
    let runCount: Int
    let eventCount: Int
    /// Rejected records and unreadable candidate files, not records outside the bounded tails.
    let skippedCount: Int
    let truncated: Bool
}

/// Reads only the two existing opt-in diagnostic locations. Everything copied
/// into the archive is rebuilt from typed, closed allowlists; raw strings and
/// source names/identities are never copied. Export has no device side effects.
nonisolated enum DiagnosticBundle {
    private static let maxRuns = 12, maxEntries = 2048
    private static let prefixBytes = 16 * 1024, tailBytes = 512 * 1024, totalBytes = 4 * 1024 * 1024

    static func create(documents: URL, applicationSupport: URL, outputDirectory: URL,
                       scope: DiagnosticExportScope, context: DiagnosticExportContext) throws -> DiagnosticExportResult {
        var skipped = 0, truncated = false, budget = totalBytes - (scope == .recent ? tailBytes : 0), events = 0
        var files: [(String, Data)] = []
        let docs = open(documents.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if docs >= 0 {
            defer { close(docs) }
            for name in discover(docs, scope: scope, truncated: &truncated) {
                let fd = openat(docs, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { skipped += 1; continue }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { skipped += 1; continue }
                if case .conversation(let id) = scope {
                    let prefix = read(fd, offset: 0, count: min(prefixBytes, Int(info.st_size)))
                    guard let end = prefix.firstIndex(of: 10),
                          let first = try? JSONSerialization.jsonObject(with: prefix[..<end]) as? [String: Any],
                          first["event"] as? String == "run_context",
                          let raw = first["conversationID"] as? String, UUID(uuidString: raw) == id else { continue }
                }
                guard budget > 0 else { truncated = true; break }
                let data = tail(fd, size: info.st_size, budget: &budget, truncated: &truncated)
                let clean = sanitize(data, skipped: &skipped, events: &events)
                if !clean.isEmpty { files.append((String(format: "run-%02d.jsonl", files.count + 1), clean)) }
            }
        }
        let runs = files.count
        var connectionIncluded = false
        if scope == .recent {
            budget += tailBytes // Reserve one bounded tail for standalone connection diagnostics.
            let support = open(applicationSupport.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if support >= 0 {
                defer { close(support) }
                let diagnostics = openat(support, "Diagnostics", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if diagnostics >= 0 {
                    defer { close(diagnostics) }
                    let fd = openat(diagnostics, "phone-connection.jsonl", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    if fd >= 0 {
                        defer { close(fd) }
                        var info = stat()
                        if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                            let data = tail(fd, size: info.st_size, budget: &budget, truncated: &truncated)
                            let clean = sanitize(data, skipped: &skipped, events: &events)
                            if !clean.isEmpty { files.append(("phone-connection.jsonl", clean)); connectionIncluded = true }
                        } else { skipped += 1 }
                    }
                }
            }
        }
        let manifest: [String: Any] = [
            "formatVersion": 1, "scope": scope == .recent ? "recent" : "conversation",
            "metadata": metadata(context), "runCount": runs, "eventCount": events,
            "skippedCount": skipped, "truncated": truncated, "connectionLogIncluded": connectionIncluded,
            "logsMissing": files.isEmpty,
            "limits": ["runFiles": maxRuns, "directoryEntries": maxEntries, "associationPrefixBytes": prefixBytes,
                       "perFileTailBytes": tailBytes, "totalTailInputBytes": totalBytes],
            "coverage": "Only existing opt-in metadata logs; no history, provider settings, pairing, screenshots or native text logs. Closed allowlists omit unknown fields and values. Recent files may lack conversation attribution. Conversation export requires a first-record run_context and excludes the global connection log. Directory enumeration is not chronological; hitting its entry limit can omit even the newest runs. Bounded tails are not a complete transcript. Skipped counts exclude data outside these bounds. Concurrent partial records are omitted."
        ]
        files.insert(("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])), at: 0)
        let manager = FileManager.default
        let directory = outputDirectory.appendingPathComponent("diagnostics-\(UUID())", isDirectory: true)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        do {
            var protectedDirectory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            let url = directory.appendingPathComponent("PocketAgent-diagnostics.zip")
            #if os(iOS)
            try zip(files).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try zip(files).write(to: url, options: .atomic)
            #endif
            var fileAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            fileAttributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try manager.setAttributes(fileAttributes, ofItemAtPath: url.path)
            return .init(url: url, runCount: runs, eventCount: events, skippedCount: skipped, truncated: truncated)
        } catch { try? manager.removeItem(at: directory); throw error }
    }

    /// Bounded nonrecursive discovery anchored at the opened app-owned directory.
    private static func discover(_ fd: Int32, scope: DiagnosticExportScope, truncated: inout Bool) -> [String] {
        guard let directory = fdopendir(dup(fd)) else { return [] }
        defer { closedir(directory) }
        var found: [(String, timespec)] = [], entries = 0, candidates = 0
        while let entry = readdir(directory) {
            entries += 1
            guard entries <= maxEntries else { truncated = true; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix("run-"), name.hasSuffix(".jsonl"), UUID(uuidString: String(name.dropFirst(4).dropLast(6))) != nil else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if case .conversation(let id) = scope {
                let candidate = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard candidate >= 0 else { continue }
                defer { close(candidate) }
                // Filter before the output-file cap, so newer unrelated runs
                // cannot hide the selected conversation. Rechecked on export.
                var opened = stat()
                guard fstat(candidate, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { continue }
                let prefix = read(candidate, offset: 0, count: min(prefixBytes, Int(max(0, opened.st_size))))
                guard let end = prefix.firstIndex(of: 10),
                      let first = try? JSONSerialization.jsonObject(with: prefix[..<end]) as? [String: Any],
                      first["event"] as? String == "run_context",
                      let raw = first["conversationID"] as? String, UUID(uuidString: raw) == id else { continue }
            }
            candidates += 1
            found.append((name, info.st_mtimespec))
            found.sort {
                if $0.1.tv_sec != $1.1.tv_sec { return $0.1.tv_sec > $1.1.tv_sec }
                if $0.1.tv_nsec != $1.1.tv_nsec { return $0.1.tv_nsec > $1.1.tv_nsec }
                return $0.0 < $1.0
            }
            if found.count > maxRuns { found.removeLast() }
        }
        if candidates > maxRuns { truncated = true }
        return found.map(\.0)
    }

    private static func read(_ fd: Int32, offset: off_t, count: Int) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let received = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
        guard received > 0 else { return Data() }
        data.count = received
        return data
    }

    private static func tail(_ fd: Int32, size: off_t, budget: inout Int, truncated: inout Bool) -> Data {
        let count = min(tailBytes, budget, Int(max(0, size)))
        let offset = max(0, size - off_t(count))
        if offset > 0 { truncated = true }
        budget -= count
        var data = read(fd, offset: offset, count: count)
        if data.count < count { truncated = true }
        // The first bytes of a tail can belong to a cut record. Never parse it.
        if offset > 0 {
            if let end = data.firstIndex(of: 10) { data.removeSubrange(...end) }
            else { data.removeAll() }
        }
        return data
    }

    private static func sanitize(_ data: Data, skipped: inout Int, events: inout Int) -> Data {
        var result = Data(), start = data.startIndex
        for end in data.indices where data[end] == 10 {
            defer { start = end + 1 }
            guard end > start else { continue }
            guard end - start <= prefixBytes,
                  let record = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
                  let event = record["event"] as? String, eventNames.contains(event) else { skipped += 1; continue }
            var output: [String: Any] = ["event": event]
            for (key, value) in record where key != "event" {
                if let allowed = strings[key], let text = value as? String, allowed.contains(text) { output[key] = text }
                else if booleans.contains(key), let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { output[key] = number }
                else if numbers.contains(key), let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                        number.doubleValue.isFinite, abs(number.doubleValue) <= 1e15,
                        key != "stage" || (number.doubleValue.rounded() == number.doubleValue && (0...19).contains(number.intValue)) { output[key] = number }
                else if key == "time", let text = value as? String, text.utf8.count <= 32,
                        let date = ISO8601DateFormatter().date(from: text) { output[key] = ISO8601DateFormatter().string(from: date) }
                else if key == "events", let counts = value as? [String: Any] {
                    var clean: [String: Int] = [:]
                    for name in streamKinds {
                        if let n = counts[name] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                           n.doubleValue >= 0, n.doubleValue <= 1e9, n.doubleValue.rounded() == n.doubleValue { clean[name] = n.intValue }
                    }
                    output[key] = clean
                }
            }
            if let encoded = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
                result.append(encoded); result.append(10); events += 1
            } else { skipped += 1 }
        }
        if start < data.endIndex { skipped += 1 }
        return result
    }

    private static func metadata(_ context: DiagnosticExportContext) -> [String: Any] {
        func version(_ text: String) -> String {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            return !parts.isEmpty && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) } } ? text : "unknown"
        }
        func choice(_ value: String, _ choices: Set<String>) -> String { choices.contains(value) ? value : "unknown" }
        var result: [String: Any] = ["appVersion": version(context.appVersion), "appBuild": version(context.appBuild),
            "systemVersion": version(context.systemVersion), "deviceFamily": choice(context.deviceFamily, ["phone", "tablet", "other"]),
            "currentBackend": choice(context.currentBackend, ["ddi", "wda"]), "loggingEnabled": context.loggingEnabled,
            "backgroundTaskNamespaceMatches": context.backgroundTaskNamespaceMatches]
        if let state = context.conversationState { result["conversationState"] = choice(state, ["idle", "queued", "running", "cancelling", "completed", "failed", "interrupted"]) }
        if let orientation = context.orientation { result["orientation"] = choice(orientation, ["portrait", "landscapeLeft", "landscapeRight", "portraitUpsideDown", "unknown"]) }
        for (key, value, limit) in [("windowWidth", context.windowWidth, 10000.0), ("windowHeight", context.windowHeight, 10000.0), ("displayScale", context.displayScale, 10.0)] {
            if let value, value.isFinite, value > 0, value <= limit { result[key] = value }
        }
        return result
    }

    private static let eventNames: Set<String> = [
        "rp_tunnel_prepared", "rp_tunnel_prepared_expired", "rp_tunnel_prepared_released", "rp_tunnel_prepared_rejected", "rp_tunnel_prepared_consumed",
        "interrupted", "ddi_services_connect_started", "ddi_services_connect_failed", "runner_dvt_connect_started", "runner_dvt_connect_failed", "runner_apps_listing_started", "runner_apps_listing_failed", "runner_bundle_resolve_started", "runner_bundle_resolve_failed", "runner_launch_started", "runner_launch_failed",
        "run_context", "agent_submitted", "agent_started", "agent_event", "agent_cancel_requested", "failed", "completed",
        "scene_phase", "input_release_unconfirmed_latched", "network_authorization_requested", "network_authorized", "rp_tunnel_connected",
        "ddi_check_started", "ddi_check_finished", "ddi_download", "ddi_download_file", "ddi_mount_started", "ddi_mount_finished", "ddi_ready",
        "ddi_service_directory_refresh_started", "ddi_service_directory_refresh_failed", "ddi_service_directory_refreshed",
        "ddi_services_ready", "runner_bundle_resolved", "runner_launched", "wda_ready", "finish_gate_wait", "finish_gate_acquired",
        "finish_step_enter", "ddi_observation_closed", "ddi_observation_stop_failed", "assistant_returned", "assistant_return_failed",
        "ddi_services_closed", "ddi_close_failed", "finish_step", "runner_stopped", "runner_stop_failed",
        "wda_request_started", "wda_request_finished", "wda_request_failed", "ddi_call_enter", "ddi_cancel_signalled", "ddi_call_outstanding", "ddi_call_exit",
        "phone_agent_started", "deadline_exceeded", "tool_started", "tool_finished", "agent_terminal", "agent_events_drained", "phone_agent_completed", "action_lock_wait", "action_lock_wait_cancelled", "action_lock_acquired", "action_lock_released", "phone_model_request", "phone_task_surface_gesture", "phone_observe", "context_exclusion", "script_finished", "script_lease_revoked", "script_cancel_observed", "script_serving_wait_begin", "script_serving_wait_end", "ish_remaining_enter", "ish_remaining_exit", "ish_unmount_enter", "ish_unmount_exit", "script_stop_begin", "script_stop_found", "script_stop_end", "ish_call",
        "model_stream", "task_progress", "background_task_expired", "rp_tunnel_connect_started", "rp_tunnel_connect_failed", "rp_tunnel_connect_succeeded", "rp_pairing_configuration_failed"
    ]
    private static let booleans: Set<String> = ["imageInput", "hadRuntime", "workspace", "globalRules", "projectRules", "assistant", "summary", "sameProgressObject", "isError", "gestureCompleted", "cancelled", "timedOut", "exited", "usedOverride", "inCall", "inputUnconfirmed", "terminalSeen", "providerCodePresent", "usesWiFi", "usesCellular", "usesOtherInterface", "isExpensive", "isConstrained"]
    private static let numbers: Set<String> = ["seq", "upMs", "rawMs", "appState", "appStateAtWrite", "ms", "limitMs", "budgetMs", "waitedMs", "files", "index", "nativeSeq", "stage", "stageAgeMs", "beats", "beatAgeMs", "reconnects", "firstEventMs", "endedMs", "urlErrorCode", "httpStatus", "errorCode", "nativeErrorCode", "completed", "total", "elapsed", "completedUnits", "totalUnits", "workObserved", "secondsSinceLastChange", "secondsSinceChange", "modelResponses", "phoneActions", "otherSteps", "skills", "partialMessages", "quotes", "promptImages", "requests", "toolCalls", "request", "snapshotID", "elements", "screenshotBytes", "waiters", "heldMs", "waiting", "exitCode", "signal", "remaining", "found", "terminated", "polls"]
    private static let streamKinds: Set<String> = ["textDelta", "textSnapshot", "reasoningDelta", "reasoningSnapshot", "toolCallDelta", "toolCallSnapshot", "providerItem", "webSearch", "usage", "finished"]
    private static let strings: [String: Set<String>] = [
        "backend": ["ddi", "wda"], "path": ["main", "summary"],
        "outcome": ["running", "ended", "cancelled", "failed", "ok", "error", "timeout", "budget", "installed", "missing"],
        "phase": ["active", "inactive", "background", "willResignActive", "didEnterBackground", "willEnterForeground", "didBecomeActive", "connecting", "responding", "phoneAction", "retrying", "waitingForUser", "cleaningUp", "completed", "failed", "cancelled", "expired"],
        "step": ["stop_observing", "return", "close", "ddi_finished"],
        "op": ["tap", "hold", "drag", "surface_drag", "clear", "paste", "key", "keys", "ax_replace", "screenshot", "observe", "request", "home", "open_app", "press_home", "swipe", "type_text", "snapshot", "launch", "button", "signal", "tasks", "ax_tree", "ax_stop", "foreground", "activate", "clipboard_set", "clipboard_verify", "stop_observing", "return"],
        "format": ["chatCompletions", "responses", "messages", "generateContent"],
        "name": Set(ToolCatalog.all.map(\.name)),
        "state": ["idle", "running", "completed", "failed", "cancelled", "interrupted"],
        "layout": ["portrait"],
        "reason": ["kernel", "cancelled", "timedOut", "output", "started", "finishing", "terminal", "context_preparation", "context_work", "context_ready", "phone_preparation", "script_runtimeReady", "script_processStarted", "script_outputGrew", "script_phone_started", "script_phone_finished", "model_stream", "model_response", "tool_finished", "agent_event"],
        "connectionStage": ["initial_tcp_connect", "rp_tunnel_handshake"],
        "connectionError": ["connection_refused", "no_route", "tunnel_failed"],
        "method": ["GET", "POST", "DELETE"],
        "route": ["/status", "/session", "/session/:id", "/session/:id/source", "/session/:id/screenshot", "/session/:id/element/:id/click", "/session/:id/element/:id/value", "/session/:id/wda/dragfromtoforduration", "/wda/homescreen"],
        "failureKind": ["cancelled", "urlError", "http", "providerResponse", "providerStreamError", "contextLimit", "other"],
        "providerCode": StreamFailureCategory.knownProviderCodes,
        "terminalReason": ["completed", "toolCalls", "length", "cancelled", "error"],
        "errorDomain": ["PocketAgent", "NSURLErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain"],
        "networkPath": ["satisfied", "unsatisfied", "requires_connection", "unknown"],
        "context": ["device_setup", "active_turn"],
        "subscription_stop": ["ok", "stopped", "closed", "unknown"]
    ]

    /// PKWARE APPNOTE 6.3.10 sections 4.3.7, 4.3.12, 4.3.16.
    /// Method 0 (stored), fixed DOS epoch, no source paths or extra fields.
    private static func zip(_ files: [(String, Data)]) -> Data {
        var archive = Data(), central = Data()
        func append(_ value: UInt32, bytes: Int, to data: inout Data) {
            for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        for (name, content) in files {
            let filename = Data(name.utf8), size = UInt32(content.count), offset = UInt32(archive.count)
            let checksum = content.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(content.count))) }
            append(0x04034b50, bytes: 4, to: &archive)
            for value: UInt32 in [10, 0, 0, 0, 33] { append(value, bytes: 2, to: &archive) }
            for value in [checksum, size, size] { append(value, bytes: 4, to: &archive) }
            append(UInt32(filename.count), bytes: 2, to: &archive); append(0, bytes: 2, to: &archive)
            archive.append(filename); archive.append(content)
            append(0x02014b50, bytes: 4, to: &central)
            for value: UInt32 in [10, 10, 0, 0, 0, 33] { append(value, bytes: 2, to: &central) }
            for value in [checksum, size, size] { append(value, bytes: 4, to: &central) }
            for value: UInt32 in [UInt32(filename.count), 0, 0, 0, 0] { append(value, bytes: 2, to: &central) }
            append(0, bytes: 4, to: &central); append(offset, bytes: 4, to: &central); central.append(filename)
        }
        let offset = UInt32(archive.count)
        archive.append(central); append(0x06054b50, bytes: 4, to: &archive)
        for value: UInt32 in [0, 0, UInt32(files.count), UInt32(files.count)] { append(value, bytes: 2, to: &archive) }
        append(UInt32(central.count), bytes: 4, to: &archive); append(offset, bytes: 4, to: &archive); append(0, bytes: 2, to: &archive)
        return archive
    }
}
