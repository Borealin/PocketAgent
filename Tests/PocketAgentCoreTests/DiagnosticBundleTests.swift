import Foundation
import Testing
@testable import PocketAgentCore

struct DiagnosticBundleTests {
    private let context = DiagnosticExportContext(appVersion: "0.3.7", appBuild: "9", systemVersion: "27.2",
        deviceFamily: "phone", currentBackend: "ddi", loggingEnabled: true, backgroundTaskNamespaceMatches: true)

    @Test func privacyRebuildsRecognizedFieldsAndIgnoresUnrelatedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "TEST-SECRET-token.example.invalid/private"
        let runID = UUID(), conversationID = UUID()
        // Values emitted by Controller's scene notifications and PhoneAgent's
        // script/preparation progress callbacks must survive the privacy projection.
        let phases = ["willResignActive", "didEnterBackground", "willEnterForeground", "didBecomeActive"]
        let progressReasons = [ScriptStage.runtimeReady, .processStarted, .outputGrew].map { "script_" + $0.rawValue }
            + ["phone_preparation"]
        let directoryEvents = ["ddi_service_directory_refresh_started", "ddi_service_directory_refresh_failed",
                               "ddi_service_directory_refreshed"]
        let preparedEvents = ["rp_tunnel_prepared", "rp_tunnel_prepared_expired", "rp_tunnel_prepared_released",
                              "rp_tunnel_prepared_rejected", "rp_tunnel_prepared_consumed"]
        try write([
            ["event": "run_context", "conversationID": conversationID.uuidString, "backend": "ddi", "runID": runID.uuidString],
            ["event": "model_stream", "path": "main", "events": ["textDelta": 3, secret: 10], "outcome": secret,
             "failureType": secret, "providerCode": secret, "error": secret, "seq": 7, "ms": 24, "time": "2026-11-04T01:02:03Z"],
            ["event": "wda_request_failed", "method": secret, "route": secret, "errorDomain": secret, "errorCode": secret],
            ["event": "tool_started", "name": secret, "callID": secret],
            ["event": "tool_finished", "name": "observe_screen", "isError": false],
            ["event": "runner_launch_failed", "errorDomain": "PocketAgent", "errorCode": -1],
            ["event": secret, "ms": 5],
            ["event": "task_progress", "reason": secret]
        ] + phases.map { ["event": "scene_phase", "phase": $0] }
          + progressReasons.map { ["event": "task_progress", "reason": $0] }
          + directoryEvents.map { ["event": $0, "errorDomain": "PocketAgent", "errorCode": -1,
                                    "error": secret, "reason": secret] },
          to: root.appendingPathComponent("run-\(runID).jsonl"))
        for name in ["history.json", "providers.json", "pairing.plist", "native.log", "screenshot.png"] {
            try Data(secret.utf8).write(to: root.appendingPathComponent(name))
        }
        let diagnostics = root.appendingPathComponent("Diagnostics")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try write([["event": "rp_tunnel_connect_failed", "context": "device_setup", "connectionStage": "initial_tcp_connect",
                    "connectionError": "connection_refused", "networkPath": "satisfied", "usesCellular": true,
                    "nativeErrorCode": secret]]
                  + preparedEvents.map { ["event": $0, "context": "device_setup"] },
                  to: diagnostics.appendingPathComponent("phone-connection.jsonl"))
        var hostile = context
        hostile.appVersion = secret; hostile.systemVersion = secret; hostile.deviceFamily = secret
        hostile.currentBackend = secret; hostile.orientation = secret; hostile.conversationState = secret
        hostile.windowWidth = .infinity
        let result = try DiagnosticBundle.create(documents: root, applicationSupport: root, outputDirectory: root,
                                                scope: .recent, context: hostile)
        let contents = try unzip(result.url, ["-p"])
        #expect(!contents.contains(secret))
        #expect(!contents.contains(runID.uuidString))
        #expect(!contents.contains(conversationID.uuidString))
        #expect(contents.contains("\"seq\":7"))
        #expect(contents.contains("\"textDelta\":3"))
        #expect(contents.contains("\"name\":\"observe_screen\""))
        #expect(contents.contains("\"event\":\"runner_launch_failed\""))
        #expect(contents.contains("\"errorCode\":-1"))
        #expect(contents.contains("\"connectionError\":\"connection_refused\""))
        for phase in phases { #expect(contents.contains("\"phase\":\"\(phase)\"")) }
        for reason in progressReasons { #expect(contents.contains("\"reason\":\"\(reason)\"")) }
        for event in preparedEvents { #expect(contents.contains("\"event\":\"\(event)\"")) }
        for event in directoryEvents { #expect(contents.contains("\"event\":\"\(event)\"")) }
        #expect(result.runCount == 1 && result.eventCount == 24 && result.skippedCount == 1)
        let names = try unzip(result.url, ["-Z1"])
        #expect(names == "manifest.json\nrun-01.jsonl\nphone-connection.jsonl\n")
    }

    @Test func conversationUsesFirstRecordBeyondTailAndExcludesLegacyGlobalAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        var log = try encoded(["event": "run_context", "conversationID": id.uuidString, "backend": "wda"])
        let row = try encoded(["event": "ddi_call_exit", "seq": 12, "outcome": "ok", "ms": 8])
        while log.count < 600 * 1024 { log.append(row) }
        log.append(try encoded(["event": "ddi_call_exit", "seq": 13, "outcome": "ok"]))
        log.append(Data("{\"event\":\"tool_started\"".utf8)) // concurrent incomplete final write
        let selectedLog = root.appendingPathComponent("run-\(UUID()).jsonl")
        try log.write(to: selectedLog)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: selectedLog.path)
        for _ in 0..<13 {
            try write([["event": "run_context", "conversationID": UUID().uuidString], ["event": "failed"]],
                      to: root.appendingPathComponent("run-\(UUID()).jsonl"))
        }
        let diagnostics = root.appendingPathComponent("Diagnostics")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try write([["event": "rp_tunnel_connect_failed", "context": "device_setup"]],
                  to: diagnostics.appendingPathComponent("phone-connection.jsonl"))
        try write([["event": "run_context", "conversationID": UUID().uuidString], ["event": "failed"]],
                  to: root.appendingPathComponent("run-\(UUID()).jsonl"))
        try write([["event": "failed"], ["event": "run_context", "conversationID": id.uuidString]],
                  to: root.appendingPathComponent("run-\(UUID()).jsonl"))
        try write([["event": "failed"]], to: root.appendingPathComponent("history.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("run-\(UUID()).jsonl"),
                                                  withDestinationURL: root.appendingPathComponent("history.json"))
        let result = try DiagnosticBundle.create(documents: root, applicationSupport: root, outputDirectory: root,
                                                scope: .conversation(id), context: context)
        #expect(result.runCount == 1 && result.truncated && result.skippedCount == 1)
        let contents = try unzip(result.url, ["-p", "run-01.jsonl"])
        #expect(contents.utf8.count <= 512 * 1024)
        #expect(contents.hasSuffix("{\"event\":\"ddi_call_exit\",\"outcome\":\"ok\",\"seq\":13}\n"))
        #expect(!contents.contains("run_context") && !contents.contains("failed"))
        let manifest = try unzip(result.url, ["-p", "manifest.json"])
        #expect(manifest.contains("\"connectionLogIncluded\" : false"))
        let recent = try DiagnosticBundle.create(documents: root, applicationSupport: root, outputDirectory: root,
                                                scope: .recent, context: context)
        #expect(recent.runCount == 12 && recent.truncated)
        let legacyRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        try write([["event": "failed"]], to: legacyRoot.appendingPathComponent("run-\(UUID()).jsonl"))
        let legacy = try DiagnosticBundle.create(documents: legacyRoot, applicationSupport: legacyRoot, outputDirectory: legacyRoot,
                                                scope: .recent, context: context)
        #expect(legacy.runCount == 1) // legacy logs remain usable without claiming an owner
    }

    @Test func storedZipInteroperatesAndReportsEmptyOrBoundedDiscovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try DiagnosticBundle.create(documents: root, applicationSupport: root, outputDirectory: root,
                                               scope: .recent, context: context)
        #expect(empty.runCount == 0 && empty.eventCount == 0 && !empty.truncated)
        #expect(try unzip(empty.url, ["-t"]).contains("No errors detected"))
        #expect(try unzip(empty.url, ["-p", "manifest.json"]).contains("\"logsMissing\" : true"))
        for index in 0..<15 {
            try write([["event": "ddi_call_exit", "seq": index, "outcome": "ok"]],
                      to: root.appendingPathComponent("run-\(UUID()).jsonl"))
        }
        let limited = try DiagnosticBundle.create(documents: root, applicationSupport: root, outputDirectory: root,
                                                 scope: .recent, context: context)
        #expect(limited.runCount == 12 && limited.eventCount == 12 && limited.truncated)
        #expect(try unzip(limited.url, ["-t"]).contains("No errors detected"))
        // Large run tails must not starve the separate connection diagnostic.
        var large = Data()
        let row = try encoded(["event": "ddi_call_exit", "outcome": "ok", "padding": String(repeating: "x", count: 8000)])
        while large.count < 512 * 1024 { large.append(row) }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("run-") {
            try large.write(to: file)
        }
        let diagnostics = root.appendingPathComponent("Diagnostics")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try write([["event": "rp_tunnel_connect_succeeded", "context": "device_setup"]],
                  to: diagnostics.appendingPathComponent("phone-connection.jsonl"))
        let full = try DiagnosticBundle.create(documents: root, applicationSupport: root, outputDirectory: root,
                                              scope: .recent, context: context)
        #expect(full.truncated && full.runCount == 7)
        #expect(try unzip(full.url, ["-p", "phone-connection.jsonl"]).contains("rp_tunnel_connect_succeeded"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticBundleTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func encoded(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
    }
    private func write(_ records: [[String: Any]], to url: URL) throws {
        var data = Data()
        for record in records { data.append(try encoded(record)) }
        try data.write(to: url)
    }
    private func unzip(_ url: URL, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = Array(arguments.prefix(1)) + [url.path] + Array(arguments.dropFirst())
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: output, as: UTF8.self)
    }
}
