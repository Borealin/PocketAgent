import AVFoundation
import Combine
import Foundation

/// One capture/playback owner and one bounded WebSocket writer. Raw audio and
/// captions never reach files, diagnostics, history or portable sync.
@MainActor final class LiveVoiceController: ObservableObject {
    @Published var state = LiveVoiceState()
    @Published private(set) var notice = ""
    @Published private(set) var playing = false
    private var socket: URLSessionWebSocketTask?
    private var transport: URLSession?
    private var preparation: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var source: LiveCaptureSource?
    private var audioContinuation: AsyncThrowingStream<LiveCaptureSource.Chunk, Error>.Continuation?
    private var lease: UUID?
    private var observers: [NSObjectProtocol] = []
    private var outgoing: [Packet] = []
    private var inputEpoch: UInt64 = 0
    private var scheduledFrames = 0
    private var backgroundAllowed = false
    private var taskDelegations: [UUID: String] = [:]
    private enum Packet { case command(String), audio(Data, UInt64) }

    func start(in sessionID: UUID, request: URLRequest, background: Bool) {
        guard !state.running else { return }
        let token = state.begin(in: sessionID)
        guard MicrophoneOwnership.acquire(token) else {
            state.finish(); notice = LiveVoiceFailure.microphone.localizedDescription; return
        }
        lease = token; backgroundAllowed = background; notice = ""; taskDelegations = [:]
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVAudioApplication.requestRecordPermission() else { throw LiveVoiceFailure.permission }
                guard state.generation == token, state.phase == .preparing, !Task.isCancelled else { return }
                try prepareAudio(token)
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                let session = URLSession(configuration: config, delegate: LiveNoRedirect(), delegateQueue: nil)
                let socket = session.webSocketTask(with: request)
                socket.maximumMessageSize = 512 * 1024
                transport = session; self.socket = socket
                state.connecting(); socket.resume()
                receiver = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            guard let self, self.state.generation == token, self.state.running else { return }
                            let data: Data
                            switch message {
                            case .string(let text): data = Data(text.utf8)
                            case .data(let value): data = value
                            @unknown default: throw LiveVoiceFailure.protocolError
                            }
                            try self.receive(LiveWire.decode(data), token: token)
                        }
                    } catch {
                        guard let self, self.state.generation == token, self.state.running else { return }
                        self.fail((error as? LiveVoiceFailure)?.localizedDescription ?? self.connectionFailure(socket), token: token)
                    }
                }
                try enqueue(.command(LiveWire.start()), token: token)
                setTimeout(token, seconds: 20, message: "Live 启动超时，未自动重连。")
            } catch {
                guard state.generation == token, state.running else { return }
                fail((error as? LiveVoiceFailure)?.localizedDescription ?? LiveVoiceFailure.microphone.localizedDescription, token: token)
            }
        }
    }

    private func receive(_ event: LiveWire.Received, token: UUID) throws {
        // Primary audio has no event ID or logical state change. Do not publish
        // the entire UI at audio-frame rate merely to check its admission gate.
        if case .audio(let bytes) = event.event {
            guard state.generation == token, state.phase == .active else { return }
            try play(bytes, token: token)
            return
        }
        guard try state.receive(event, generation: token) else { return }
        switch event.event {
        case .started:
            timeout?.cancel(); timeout = nil
            enableInput(true)
        case .delegation(let id):
            sendContext("用户尚未检查并确认任务卡，没有执行手机操作。", delegation: id, spoken: false)
        case .muted:
            timeout?.cancel(); timeout = nil
            if !state.muted { enableInput(true) }
        case .closed:
            notice = "语音已结束；最终用量已确认。已接受的手机任务按原状态继续。"
            releaseTransport()
        case .rejected(let code, _):
            // A rejected command is not proof that its intended effect happened.
            fail("Live 拒绝了命令（\(code)）；会话已结束，手机任务未自动重试。", token: token)
        default: break
        }
    }

    private func enqueue(_ packet: Packet, token: UUID) throws {
        guard state.generation == token, state.running else { return }
        guard outgoing.count < 96 else { throw LiveVoiceFailure.capacity }
        outgoing.append(packet)
        guard writer == nil, let socket else { return }
        writer = Task { [weak self] in
            guard let self else { return }
            do {
                while state.generation == token, state.running, !outgoing.isEmpty {
                    let packet = outgoing.removeFirst()
                    let text: String
                    switch packet {
                    case .command(let value): text = value
                    case .audio(let bytes, let epoch):
                        guard state.mayUpload, epoch == inputEpoch else { continue }
                        text = try LiveWire.json(["type": "session.input_audio.append", "audio": bytes.base64EncodedString()])
                    }
                    // Only this writer calls send. A frame already handed to
                    // the network cannot be retracted by a later microphone mute.
                    try await socket.send(.string(text))
                }
                if state.generation == token { writer = nil }
            } catch {
                guard state.generation == token, state.running else { return }
                fail(connectionFailure(socket), token: token)
            }
        }
    }

    func toggleMicrophone() {
        guard let command = state.requestMute() else { return }
        enableInput(false) // Purge queued, unsent mic packets before the control.
        do {
            try enqueue(.command(LiveWire.command(command.mute ? "session.input_audio.mute" : "session.input_audio.unmute", id: command.id)), token: state.generation)
            setTimeout(state.generation, seconds: 10, message: "Live 关麦/开麦确认超时，语音已结束。")
        } catch { fail(LiveVoiceFailure.capacity.localizedDescription, token: state.generation) }
    }

    func end(_ message: String = "语音已结束；已接受的手机任务继续，结束语音不会停止手机执行。") {
        guard state.running, state.phase != .closing else { return }
        let active = state.phase == .active
        let token = state.generation
        state.close(); stopAudio(); preparation?.cancel(); preparation = nil
        outgoing.removeAll()
        notice = message
        if active {
            do { try enqueue(.command(LiveWire.command("session.close")), token: token) }
            catch { fail(message, token: token); return }
            setTimeout(token, seconds: 15, message: message)
        } else { state.finish(); releaseTransport() }
    }

    func enteredBackground() {
        guard state.running else { return }
        if state.phase != .active || !backgroundAllowed {
            end("已进入后台，语音结束；未自动恢复。已接受的手机任务继续。")
        }
    }

    func sendContext(_ text: String, delegation: String?, spoken: Bool) {
        guard state.phase == .active else { return }
        do { try enqueue(.command(LiveWire.context(text, delegation: delegation, spoken: spoken)), token: state.generation) }
        catch { fail(LiveVoiceFailure.capacity.localizedDescription, token: state.generation) }
    }

    func taskAccepted(_ prompt: UUID, delegation: String) {
        guard state.phase == .active else { return }
        taskDelegations[prompt] = delegation
        sendContext("用户已确认任务，已交给应用。可能排队中；请依据后续结果说明进展。", delegation: delegation, spoken: false)
    }

    func taskFinished(_ prompt: UUID, completed: Bool, cancelled: Bool, answer: String? = nil) {
        guard let delegation = taskDelegations.removeValue(forKey: prompt) else { return }
        let result = completed ? (answer.map { "应用确认任务已完成，原聊天结果：" + $0 } ?? "应用确认任务已完成，详细结果在原聊天中。") :
            (cancelled ? "应用确认本轮已停止。已发生的操作不会撤销；结果未知的操作没有自动重放。" : "应用确认本轮未完成，请查看原聊天中的状态；没有自动重放手机操作。")
        sendContext(result, delegation: delegation, spoken: true)
    }

    private func setTimeout(_ token: UUID, seconds: Double, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.state.generation == token, self.state.running else { return }
            self.fail(message, token: token)
        }
    }

    private func connectionFailure(_ socket: URLSessionWebSocketTask) -> String {
        if let status = (socket.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            return ProviderAccessRejection(status: status).localizedDescription
        }
        return LiveVoiceFailure.connection.localizedDescription
    }

    private func fail(_ message: String, token: UUID) {
        guard state.generation == token else { return }
        let hadSession = state.phase == .active || state.phase == .closing
        state.finish(); notice = message + (hadSession && !state.finalUsage ? " 最终用量未确认。" : "")
        releaseTransport()
    }

    private func releaseTransport() {
        stopAudio(); preparation?.cancel(); preparation = nil
        timeout?.cancel(); timeout = nil; receiver?.cancel(); receiver = nil; writer?.cancel(); writer = nil
        outgoing = []; taskDelegations = [:]
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        transport?.invalidateAndCancel(); transport = nil
    }

    private func prepareAudio(_ token: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let engine = AVAudioEngine()
        self.engine = engine
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let player = AVAudioPlayerNode()
        self.player = player; engine.attach(player)
        guard let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
            throw LiveVoiceFailure.microphone
        }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        let natural = engine.inputNode.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw LiveVoiceFailure.microphone }
        let (stream, continuation) = AsyncThrowingStream<LiveCaptureSource.Chunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(96))
        audioContinuation = continuation
        guard let source = LiveCaptureSource(from: natural, to: pcm, continuation: continuation) else { throw LiveVoiceFailure.microphone }
        self.source = source
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in source.accept(buffer) }
        capture = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.state.generation == token, self.state.running else { return }
                    guard self.state.mayUpload, self.inputEpoch == chunk.epoch else { continue }
                    try self.enqueue(.audio(chunk.data, chunk.epoch), token: token)
                }
            } catch {
                guard let self, self.state.generation == token, self.state.running else { return }
                self.fail(LiveVoiceFailure.capacity.localizedDescription, token: token)
            }
        }
        observeAudio(token)
        try engine.start(); player.play()
    }

    private func enableInput(_ enabled: Bool) {
        inputEpoch &+= 1
        source?.setEnabled(enabled, epoch: inputEpoch)
        outgoing.removeAll { if case .audio = $0 { true } else { false } }
    }

    private func play(_ bytes: Data, token: UUID) throws {
        let frames = bytes.count / 2
        // Memory ceiling, not a target latency or an assumed server pacing rate.
        guard scheduledFrames + frames <= 1_440_000, let player,
              let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { throw LiveVoiceFailure.capacity }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            for index in 0..<frames {
                let value = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                samples[index] = Float(Int16(littleEndian: value)) / 32768
            }
        }
        scheduledFrames += frames
        if !playing { playing = true }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.generation == token, self.state.phase == .active else { return }
                self.scheduledFrames = max(0, self.scheduledFrames - frames)
                let hasAudio = self.scheduledFrames > 0
                if self.playing != hasAudio { self.playing = hasAudio }
            }
        }
    }

    private func stopAudio() {
        enableInput(false)
        source = nil; audioContinuation?.finish(); audioContinuation = nil
        capture?.cancel(); capture = nil
        player?.stop(); player = nil; scheduledFrames = 0
        if playing { playing = false }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let lease {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            MicrophoneOwnership.release(lease); self.lease = nil
        }
    }

    private func observeAudio(_ token: UUID) {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == AVAudioSession.routeChangeNotification {
                    guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                          raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
                }
                MainActor.assumeIsolated {
                    guard let self, self.state.generation == token else { return }
                    self.end("系统音频或耳机已中断，语音结束；不会自动恢复。")
                }
            })
        }
    }
}

private final class LiveNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Converter stays on the engine's serial tap. The small lock changes only
/// capture admission; muting invalidates both queued buffers and unsent frames.
private final class LiveCaptureSource: @unchecked Sendable {
    struct Chunk: Sendable { let data: Data; let epoch: UInt64 }
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuation: AsyncThrowingStream<Chunk, Error>.Continuation
    private let lock = NSLock()
    private var enabled = false
    private var epoch: UInt64 = 0
    init?(from: AVAudioFormat, to: AVAudioFormat, continuation: AsyncThrowingStream<Chunk, Error>.Continuation) {
        guard let converter = AVAudioConverter(from: from, to: to) else { return nil }
        converter.primeMethod = .none
        self.converter = converter; format = to; self.continuation = continuation
    }
    func setEnabled(_ enabled: Bool, epoch: UInt64) {
        lock.lock(); self.enabled = enabled; self.epoch = epoch; lock.unlock()
    }
    func accept(_ input: AVAudioPCMBuffer) {
        lock.lock(); let enabled = enabled, epoch = epoch; lock.unlock()
        guard enabled else { return }
        guard input.frameLength > 0, input.frameLength <= 16_384 else {
            continuation.finish(throwing: LiveVoiceFailure.capacity); return
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            continuation.finish(throwing: LiveVoiceFailure.capacity); return
        }
        var supplied = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil, let pointer = output.int16ChannelData?[0] else {
            continuation.finish(throwing: LiveVoiceFailure.microphone); return
        }
        guard output.frameLength > 0 else { return }
        let data = Data(bytes: pointer, count: Int(output.frameLength) * 2)
        if case .dropped = continuation.yield(Chunk(data: data, epoch: epoch)) {
            continuation.finish(throwing: LiveVoiceFailure.capacity)
        }
    }
}
