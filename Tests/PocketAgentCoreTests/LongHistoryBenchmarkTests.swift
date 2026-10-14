import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Opt-in host run of `LongHistoryBenchmark`. Set POCKETAGENT_BENCH_OUT to a
/// JSON path outside the repository; without it the test does nothing.
/// Numbers are host measurements, not device acceptance.
@MainActor
struct LongHistoryBenchmarkTests {
    @Test func measureWritePath() throws {
        guard let output = ProcessInfo.processInfo.environment["POCKETAGENT_BENCH_OUT"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa-bench-\(UUID().uuidString)")
        let data = try LongHistoryBenchmark.report(sizes: [10_000, 50_000], directory: directory,
                                                   label: ProcessInfo.processInfo.environment["POCKETAGENT_BENCH_CONFIG"] ?? "swift test")
        try data.write(to: URL(fileURLWithPath: output))
    }

    /// The generator itself stays valid at a small size.
    @Test func theSyntheticFileIsAValidHistory() throws {
        let file = try LongHistoryBenchmark.synthetic(messages: 120)
        #expect(file.sessions[0].messages.count == 120)
        _ = try HistoryCodec.decode(try HistoryCodec.encode(file))
    }
}
