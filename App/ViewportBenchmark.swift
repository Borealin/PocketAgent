import QuartzCore
import SwiftUI

/// Next-frame and frame-interval timing from the display link.
@MainActor
final class FrameProbe: NSObject {
    private var link: CADisplayLink?
    private var waiters: [CheckedContinuation<Double, Never>] = []
    private var recording = false
    private var stamps: [Double] = []

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        if recording { stamps.append(now) }
        let ready = waiters
        waiters = []
        ready.forEach { $0.resume(returning: now) }
    }

    /// The uptime of the next frame the main thread can deliver.
    func nextFrame() async -> Double {
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Frame-to-frame intervals over `seconds` (while someone scrolls).
    func record(seconds: Double) async -> [Double] {
        stamps = []; recording = true
        try? await Task.sleep(for: .seconds(seconds))
        recording = false
        return zip(stamps.dropFirst(), stamps).map { $0 - $1 }
    }
}

/// Local launch argument `-PocketAgentViewportBenchmark` only: the real
/// `ChatTranscriptView` over synthetic 10k/50k histories held by a read-only
/// controller (`ChatController(viewing:)`). Measures the time until the main
/// thread can deliver the next display-link frame after the transcript is
/// shown and after each programmatic "load earlier" step (the same state the
/// button changes; not proof that layout or presentation finished), and the
/// display-link frame intervals during an 8 s window in which the device is
/// scrolled from outside. Report:
/// `Documents/viewport-benchmark.json`. The app's history is not touched.
struct ViewportBenchmarkRoot: View {
    let engine: Model
    let providers: ProviderStore
    let workspaces: WorkspaceStore
    @State private var viewer: ChatController?
    @State private var status = "准备合成历史…"

    var body: some View {
        NavigationStack {
            Group {
                if let viewer {
                    ChatTranscriptView(chat: viewer, dismissKeyboard: {})
                } else {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(status).navigationBarTitleDisplayMode(.inline)
        }
        .task { await run() }
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(2))
        let probe = FrameProbe()
        probe.start()
        defer { probe.stop() }
        var results: [[String: Any]] = []
        for size in [10_000, 50_000] {
            status = "生成 \(size) 条…"
            _ = await probe.nextFrame()
            guard var file = try? LongHistoryBenchmark.synthetic(messages: size) else { continue }
            file.selectedID = file.sessions[0].id
            _ = await probe.nextFrame()
            let start = ProcessInfo.processInfo.systemUptime
            var writerCalls = 0
            let controller = ChatController(viewing: file, engine: engine, providers: providers, workspaces: workspaces,
                                            writerCalls: { writerCalls += 1 })
            viewer = controller
            let firstFrame = await probe.nextFrame() - start
            var earlier: [Double] = []
            for _ in 0..<5 {
                let step = ProcessInfo.processInfo.systemUptime
                controller.visibleLimit[file.sessions[0].id, default: ChatTranscriptView.pageSize] += ChatTranscriptView.pageSize
                earlier.append(await probe.nextFrame() - step)
            }
            status = "\(size) 条：请滚动（8 秒）"
            let intervals = await probe.record(seconds: 8)
            let sorted = intervals.sorted()
            results.append(["messages": size, "nextFrameAfterShowSeconds": firstFrame,
                            "nextFrameAfterProgrammaticLoadEarlierSeconds": earlier,
                            "visibleAfterLoads": ChatTranscriptView.pageSize * 6,
                            "scrollFrames": intervals.count, "frameIntervalP50": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                            "frameIntervalP95": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)],
                            "frameIntervalMax": sorted.last ?? 0, "framesOver50ms": intervals.filter { $0 > 0.05 }.count,
                            "writerCalls": writerCalls,
                            "storageLoadBlocked": { if case .loadBlocked = controller.owner.health { true } else { false } }()])
            viewer = nil
            _ = await probe.nextFrame()
        }
        status = "完成"
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let report: [String: Any] = ["configuration": "device viewport \(configuration)", "results": results]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("viewport-benchmark.json"), options: .atomic)
        }
    }
}
