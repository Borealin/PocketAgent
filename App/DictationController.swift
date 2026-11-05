import AVFoundation
import Combine
import Speech

/// One microphone lease. A future Live input must acquire this same lease;
/// there is no second capture engine or automatic transfer between owners.
@MainActor enum MicrophoneOwnership {
    private static var owner: UUID?
    static func acquire(_ id: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = id
        return true
    }
    static func release(_ id: UUID) { if owner == id { owner = nil } }
}

@MainActor final class DictationController: ObservableObject {
    @Published private(set) var input = DictationInput()
    @Published private(set) var notice = ""
    @Published private(set) var language = ""
    @Published private(set) var download: Progress?
    @Published var localeID = "zh-CN"
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var preparation: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lease: UUID?

    func start(in sessionID: UUID) {
        guard input.phase == .idle else { return }
        let token = input.begin(in: sessionID)
        guard MicrophoneOwnership.acquire(token) else {
            input.cancel(); notice = "麦克风正被其他语音功能使用。"; return
        }
        lease = token
        notice = ""; language = ""
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVAudioApplication.requestRecordPermission() else {
                    throw DictationFailure.permission
                }
                try check(token)
                let requested = Locale(identifier: localeID)
                if SpeechTranscriber.isAvailable,
                   let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                    try check(token)
                    language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                    let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                    try await prepare(module, token: token) { String($0.text.characters) }
                } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
                    try check(token)
                    language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                    let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
                    try await prepare(module, token: token) { String($0.text.characters) }
                } else { throw DictationFailure.unavailable }
            } catch is CancellationError { /* An invalidated start never opens the mic. */ }
            catch {
                guard input.generation == token else { return }
                fail((error as? DictationFailure)?.message ?? DictationFailure.unavailable.message)
            }
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard input.generation == token else { throw CancellationError() }
    }

    private func prepare<Module: SpeechModule>(_ module: Module, token: UUID,
                                               text: @escaping @Sendable (Module.Result) -> String) async throws {
        let modules: [any SpeechModule] = [module]
        guard await AssetInventory.status(forModules: modules) != .unsupported else { throw DictationFailure.unavailable }
        try check(token)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try check(token)
            download = request.progress
            try await request.downloadAndInstall()
            try check(token)
            download = nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw DictationFailure.unavailable
        }
        try check(token)
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try check(token)
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        self.continuation = continuation
        results = Task { [weak self] in
            do {
                for try await result in module.results {
                    guard let self, self.input.generation == token else { return }
                    self.input.receive(text(result), start: result.range.start.seconds,
                                       end: CMTimeRangeGetEnd(result.range).seconds, final: result.isFinal, generation: token)
                }
            } catch {
                guard let self, !Task.isCancelled, self.input.generation == token, self.input.busy else { return }
                self.fail("听写未完成；请使用键盘或系统键盘听写。")
            }
        }
        try await analyzer.start(inputSequence: stream)
        try check(token)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let engine = AVAudioEngine()
        let natural = engine.inputNode.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
              let source = DictationAudioSource(from: natural, to: format, continuation: continuation, failure: { [weak self] in
                  Task { @MainActor in
                      guard let self, self.input.generation == token, self.input.busy else { return }
                      self.fail(DictationFailure.audio.message)
                  }
              }) else {
            throw DictationFailure.audio
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in source.accept(buffer) }
        self.engine = engine // Cleanup also covers engine.start failures.
        observeAudio(token)
        try engine.start()
        input.transition(to: .recording, generation: token)
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.input.generation == token else { return }
            self.stop()
        }
    }

    func stop() {
        guard input.phase == .recording, let token = input.generation, let analyzer else { return }
        input.transition(to: .finishing, generation: token)
        stopAudio()
        deadline?.cancel()
        let results = self.results
        finishing = Task { [weak self] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                guard let self, self.input.generation == token else { return }
                self.preview(token)
            } catch {
                guard let self, !Task.isCancelled, self.input.generation == token, self.input.phase == .finishing else { return }
                self.fail("听写结束失败；请使用键盘或系统键盘听写。")
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.input.generation == token else { return }
            self.notice = "听写结束超时，仅保留已确认的文字。"
            self.preview(token)
        }
    }

    private func preview(_ token: UUID) {
        input.transition(to: .preview, generation: token)
        cleanUp()
        if !input.canAppend, notice.isEmpty { notice = "没有识别到文字，请重新开始或使用键盘输入。" }
    }

    func cancel() {
        input.cancel() // Invalidate before any asynchronous cleanup/callback.
        cleanUp()
        notice = ""; language = ""
    }

    func interrupt(_ message: String) {
        if let token = input.generation, !input.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notice = message
            preview(token) // Stops capture and rejects later results; preserves confirmed text.
        } else {
            cancel()
            notice = message
        }
    }

    private func fail(_ message: String) { interrupt(message) }

    private func stopAudio() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        continuation?.finish(); continuation = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let lease {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            MicrophoneOwnership.release(lease)
            self.lease = nil
        }
    }

    private func cleanUp() {
        stopAudio()
        preparation?.cancel(); preparation = nil
        results?.cancel(); results = nil
        finishing?.cancel(); finishing = nil
        deadline?.cancel(); deadline = nil
        download = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    private func observeAudio(_ token: UUID) {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.input.generation == token else { return }
                    self.fail("音频输入已中断，录音已停止；请重新开始或使用键盘输入。")
                }
            })
        }
    }
}

private enum DictationFailure: Error {
    case permission, unavailable, audio
    var message: String {
        switch self {
        case .permission: "请在系统设置中允许麦克风访问，或使用键盘输入。"
        case .unavailable: "本机或所选语言的离线听写暂不可用；请使用键盘或系统键盘听写。"
        case .audio: "音频输入未能完成，请重新开始或使用键盘输入。"
        }
    }
}

/// The converter is confined to the engine's serial tap callback. Each yield
/// owns a new PCM buffer; the engine's reused input buffer never escapes.
/// Eight queued buffers bound memory; overflow ends this input rather than
/// dropping words or retaining an unbounded recording. No audio file/log exists.
private final class DictationAudioSource: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let failure: @Sendable () -> Void
    private var failed = false // Like the converter, accessed only by the tap.

    init?(from: AVAudioFormat, to: AVAudioFormat, continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
          failure: @escaping @Sendable () -> Void) {
        guard let converter = AVAudioConverter(from: from, to: to) else { return nil }
        converter.primeMethod = .none
        self.converter = converter; format = to; self.continuation = continuation; self.failure = failure
    }

    func accept(_ input: AVAudioPCMBuffer) {
        guard !failed else { return }
        guard input.frameLength > 0, input.frameLength <= 16_384 else {
            fail(); return
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail(); return
        }
        var supplied = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil else { fail(); return }
        guard output.frameLength > 0 else { return }
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
            fail()
        }
    }

    private func fail() {
        failed = true
        continuation.finish(throwing: DictationFailure.audio)
        failure()
    }
}
