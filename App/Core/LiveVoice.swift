import Foundation

/// Local settings only. Provider sync never exports this selection or endpoint.
nonisolated struct LiveVoiceSettings: Codable, Equatable, Sendable {
    var providerID: UUID?
    var endpoint = "https://api.openai.com/v1/live/sessions"
    var continuesInBackground = false

    func socketURL(boundOrigins: Set<String>) throws -> URL {
        let value = try EndpointValidation.validate(endpoint, field: "Live URL")
        guard var parts = URLComponents(string: value), parts.query == nil,
              !value.contains("{"), let origin = EndpointValidation.origin(of: value),
              boundOrigins.contains(origin) else { throw LiveVoiceFailure.origin }
        parts.scheme = "wss"
        guard let url = parts.url else { throw LiveVoiceFailure.origin }
        return url
    }
}

nonisolated enum LiveVoiceFailure: Error, LocalizedError {
    case origin, key, protocolError, capacity, connection, permission, microphone
    var errorDescription: String? {
        switch self {
        case .origin: "Live 地址须为无参数的 HTTPS URL，且必须属于此服务商本机 Key 已确认的主机。"
        case .key: "请先在模型服务中为此服务商配置个人 API Key，并确认其支持 GPT-Live。"
        case .protocolError: "Live 返回了无法处理的音频或事件，会话已结束。"
        case .capacity: "Live 音频或字幕缓冲已满，会话已结束；请重新开始。"
        case .connection: "Live 连接未完成或已断开，请核对服务地址、网络和 GPT-Live 权限；未自动重连。"
        case .permission: "请在系统设置中允许麦克风访问。"
        case .microphone: "麦克风正被使用，或音频无法启动；请结束其他语音功能后重试。"
        }
    }
}

/// Only the primary Live protocol. No Realtime VAD, commits or response lifecycle.
nonisolated enum LiveWire {
    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    static func start() throws -> String {
        try json(["type": "session.start", "event_id": UUID().uuidString, "session": [
            "model": "gpt-live-1", "store": false, "input": [],
            "instructions": "用简洁中文交谈。你不能操作手机。手机任务必须由用户检查应用确认卡并点击确认后执行。不要声称已执行、已停止或已完成，除非应用返回了对应事实。",
            "audio": ["format": ["type": "audio/pcm", "rate": 24000], "output": ["voice": "marin"]],
            "delegation": ["type": "client", "acknowledgement_delay_ms": 800]
        ]])
    }
    static func command(_ type: String, id: String = UUID().uuidString) throws -> String {
        try json(["type": type, "event_id": id])
    }
    static func context(_ text: String, delegation: String?, spoken: Bool) throws -> String {
        // A UTF-8 byte ceiling is conservative even for byte-fallback tokens.
        // Never project a full phone observation or split a Unicode scalar.
        var content = ""
        for scalar in text.unicodeScalars {
            guard content.utf8.count + scalar.utf8.count <= 400 else { break }
            content.unicodeScalars.append(scalar)
        }
        return try json(["type": spoken ? "session.commentary.append" : "session.thinking.append",
                         "event_id": UUID().uuidString, "delegation_id": delegation.map { $0 as Any } ?? NSNull(),
                         "content": content])
    }

    enum Event: Equatable, Sendable {
        case started(String), audio(Data), transcript(user: Bool, text: String, start: Int, end: Int)
        case delegation(String), muted(Bool, command: String?), usage(Double), closed(Double, String)
        case rejected(code: String, command: String?), ignored
    }
    struct Received: Sendable { let id: String?; let event: Event }

    static func decode(_ data: Data) throws -> Received {
        guard data.count <= 512 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw LiveVoiceFailure.protocolError }
        let id = object["event_id"] as? String
        if let id, id.utf8.count > 512 { throw LiveVoiceFailure.protocolError }
        let event: Event
        switch type {
        case "session.started":
            guard let session = object["session"] as? [String: Any], let value = session["id"] as? String,
                  !value.isEmpty, session["model"] as? String == "gpt-live-1" else { throw LiveVoiceFailure.protocolError }
            if let audio = session["audio"] as? [String: Any], let format = audio["format"] as? [String: Any] {
                guard format["type"] as? String == "audio/pcm", format["rate"] as? Int == 24000 else {
                    throw LiveVoiceFailure.protocolError
                }
            }
            event = .started(value)
        case "session.output_audio.delta":
            guard let value = object["delta"] as? String, let bytes = Data(base64Encoded: value),
                  !bytes.isEmpty, bytes.count % 2 == 0, bytes.count <= 192_000 else { throw LiveVoiceFailure.protocolError }
            event = .audio(bytes)
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let text = object["delta"] as? String, let start = object["start_ms"] as? Int,
                  let end = object["end_ms"] as? Int, start >= 0, end >= start else { throw LiveVoiceFailure.protocolError }
            event = .transcript(user: type == "session.input_transcript.delta", text: text, start: start, end: end)
        case "session.delegation.created":
            guard let value = object["delegation"] as? [String: Any], let key = value["id"] as? String,
                  !key.isEmpty, key.utf8.count <= 512, id != nil, value["target"] as? String == "client" else { throw LiveVoiceFailure.protocolError }
            event = .delegation(key)
        case "session.input_audio.muted", "session.input_audio.unmuted":
            event = .muted(type == "session.input_audio.muted", command: object["client_event_id"] as? String)
        case "session.usage.updated", "session.closed":
            guard let usage = object["usage"] as? [String: Any], let seconds = usage["seconds"] as? Double,
                  seconds.isFinite, seconds >= 0 else { throw LiveVoiceFailure.protocolError }
            if type == "session.closed" { event = .closed(seconds, object["reason"] as? String ?? "unknown") }
            else { event = .usage(seconds) }
        case "error":
            let error = object["error"] as? [String: Any] ?? [:]
            // Never surface or log provider prose, which can echo credentials/input.
            let raw = error["code"] as? String ?? "unknown"
            let code = raw.count <= 64 && raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? raw : "unknown"
            event = .rejected(code: code, command: error["client_event_id"] as? String ?? object["client_event_id"] as? String)
        default: event = .ignored
        }
        return Received(id: id, event: event)
    }
}

/// Ephemeral state, exercised by Core tests without audio frameworks or credentials.
nonisolated struct LiveVoiceState: Sendable {
    enum Phase: Sendable { case idle, preparing, connecting, active, closing, ended }
    struct Card: Identifiable, Sendable {
        let id = UUID()
        let delegation: String
        var text: String
        var confirming = false
    }
    private(set) var generation = UUID()
    private(set) var phase = Phase.idle
    private(set) var sessionID: UUID?
    private(set) var userCaption = ""
    private(set) var assistantCaption = ""
    private(set) var pendingText = ""
    var card: Card?
    private(set) var muted = false
    private(set) var muteCommand: String?
    private(set) var seconds = 0.0
    private(set) var finalUsage = false
    private var seen: Set<String> = []
    private var delegations: Set<String> = []
    var running: Bool { phase == .preparing || phase == .connecting || phase == .active || phase == .closing }
    var mayUpload: Bool { phase == .active && !muted && muteCommand == nil }

    mutating func begin(in session: UUID) -> UUID {
        self = Self(); sessionID = session; phase = .preparing
        return generation
    }
    mutating func connecting() { if phase == .preparing { phase = .connecting } }
    mutating func receive(_ received: LiveWire.Received, generation: UUID) throws -> Bool {
        guard self.generation == generation, running else { return false }
        if let id = received.id {
            guard !seen.contains(id) else { return false }
            guard seen.count < 16_384 else { throw LiveVoiceFailure.capacity }
            seen.insert(id)
        }
        if case .closed(let seconds, _) = received.event {
            self.seconds = seconds; finalUsage = true; finish(); return true
        }
        if case .usage(let seconds) = received.event { self.seconds = seconds; return true }
        guard phase != .closing else { return false }
        switch received.event {
        case .started: guard phase == .connecting else { return false }; phase = .active
        case .transcript(let user, let text, _, _):
            guard phase == .active else { return false }
            guard userCaption.utf8.count + assistantCaption.utf8.count + text.utf8.count <= 64 * 1024 else { throw LiveVoiceFailure.capacity }
            if user { userCaption += text; pendingText += text } else { assistantCaption += text }
        case .delegation(let id):
            guard phase == .active, delegations.insert(id).inserted else { return false }
            if card == nil { card = Card(delegation: id, text: pendingText) }
        case .muted(let muted, let command):
            guard muteCommand == command, command != nil else { return false }
            self.muted = muted; muteCommand = nil
        case .audio: return phase == .active
        default: break
        }
        return true
    }
    mutating func requestMute() -> (id: String, mute: Bool)? {
        guard phase == .active, muteCommand == nil else { return nil }
        let id = UUID().uuidString; muteCommand = id
        return (id, !muted)
    }
    mutating func beginConfirmation(_ id: UUID) -> String? {
        guard phase == .active, card?.id == id, card?.confirming == false,
              let text = card?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        card?.confirming = true; return text
    }
    mutating func settleConfirmation(_ id: UUID, accepted: Bool) {
        guard card?.id == id else { return }
        if accepted { card = nil; pendingText = "" } else { card?.confirming = false }
    }
    mutating func close() { if running { phase = .closing; muteCommand = nil } }
    mutating func finish() { phase = .ended; card?.confirming = false; muteCommand = nil }
}

nonisolated extension HistoryFile {
    /// Shared by ordinary sends and separately confirmed voice input. Voice
    /// never borrows or consumes the keyboard draft or its photo references.
    mutating func settleAcceptedDraft(in id: UUID, consume: Bool, keepImages: Bool) throws {
        guard consume else { return }
        try editSession(id) { $0.draft = ""; if !keepImages { $0.draftAttachments = [] } }
    }
}
