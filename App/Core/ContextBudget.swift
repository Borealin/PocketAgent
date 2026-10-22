import AgentKit
import Foundation

/// Local, per provider/model budget settings. Never synchronized: portable
/// provider data only projects the explicit provider/model fields.
nonisolated struct ContextBudgetOverride: Hashable, Sendable, Codable {
    var providerID: UUID
    var modelID: String
    /// User-confirmed provider context window in tokens.
    var contextWindow: Int?
    /// User-set input hard ceiling in tokens.
    var inputCeiling: Int?

    init(providerID: UUID, modelID: String, contextWindow: Int? = nil, inputCeiling: Int? = nil) {
        self.providerID = providerID; self.modelID = modelID; self.contextWindow = contextWindow; self.inputCeiling = inputCeiling
    }
    private enum Keys: String, CodingKey { case providerID, modelID, contextWindow, inputCeiling }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        providerID = try c.decode(UUID.self, forKey: .providerID)
        modelID = try c.decode(String.self, forKey: .modelID)
        contextWindow = try c.nullable(Int.self, .contextWindow)
        inputCeiling = try c.nullable(Int.self, .inputCeiling)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(providerID, forKey: .providerID); try c.encode(modelID, forKey: .modelID)
        try c.encode(contextWindow, forKey: .contextWindow); try c.encode(inputCeiling, forKey: .inputCeiling)
    }
    var isEmpty: Bool { contextWindow == nil && inputCeiling == nil }
}

nonisolated enum ContextBudgetError: LocalizedError, Equatable {
    case invalidOverride(String)
    case overHardCeiling(estimated: Int, ceiling: Int, source: String)
    var errorDescription: String? {
        switch self {
        case .invalidOverride(let detail): "上下文预算设置无效：\(detail)"
        case .overHardCeiling(let estimated, let ceiling, let source):
            // `source` is the budget label, which already names its own ceiling.
            "本次请求估计约 \(estimated) token，超过输入上限 \(ceiling)（\(source)）；已停止且不重试。可在模型服务中调整本机上下文设置，或发送新消息让助理先整理。"
        }
    }
}

/// The frozen budget of one accepted turn. A known window or an explicit
/// ceiling is a hard guard; an unknown window only sets a soft maintenance
/// target (host policy, not a claim about the provider's real limit).
nonisolated struct ContextBudgetPolicy: Hashable, Sendable {
    static let outputReserve = 4096
    static let unknownSoftTarget = 24_000
    /// Accepted local settings; anything outside is refused, never trapped on.
    static let windowRange = 8_192...10_000_000
    static let ceilingRange = 1_000...10_000_000

    enum Source: Hashable, Sendable {
        case knownWindow(Int)
        case explicitCeiling(Int)
        case unknown
    }

    let source: Source
    /// Hard input ceiling; nil when the window is unknown and none was set.
    let hardCeiling: Int?
    /// The amount maintenance aims to stay below.
    let target: Int

    /// Summarize before a request once the estimate passes 70% of the target.
    var summaryTrigger: Int { target * 70 / 100 }
    /// Recent raw history kept verbatim after summarizing: 35% of the target.
    var recentTarget: Int { target * 35 / 100 }

    var label: String {
        switch source {
        case .knownWindow(let window): "已确认窗口 \(window)，输入上限 \(hardCeiling ?? 0)"
        case .explicitCeiling(let ceiling): "本机输入上限 \(ceiling)"
        case .unknown: "窗口未知；按约 \(target) token 软目标整理"
        }
    }

    static func ceiling(window: Int) -> Int {
        window - outputReserve - max(2048, Int((Double(window) * 0.08).rounded(.up)))
    }

    static func resolve(_ override: ContextBudgetOverride?) throws -> ContextBudgetPolicy {
        var hard: Int?
        var source = Source.unknown
        if let window = override?.contextWindow {
            guard windowRange.contains(window) else {
                throw ContextBudgetError.invalidOverride("上下文窗口应在 \(windowRange.lowerBound)–\(windowRange.upperBound) token 之间")
            }
            let ceiling = ceiling(window: window)
            guard ceiling > 0 else { throw ContextBudgetError.invalidOverride("窗口 \(window) 扣除输出与余量后没有可用输入预算") }
            hard = ceiling; source = .knownWindow(window)
        }
        if let explicit = override?.inputCeiling {
            guard ceilingRange.contains(explicit) else {
                throw ContextBudgetError.invalidOverride("输入上限应在 \(ceilingRange.lowerBound)–\(ceilingRange.upperBound) token 之间")
            }
            if hard.map({ explicit < $0 }) ?? true { hard = explicit; source = .explicitCeiling(explicit) }
        }
        return ContextBudgetPolicy(source: source, hardCeiling: hard, target: hard ?? unknownSoftTarget)
    }

    static let unknown = ContextBudgetPolicy(source: .unknown, hardCeiling: nil, target: unknownSoftTarget)
}

/// Estimate v1, one unit for the whole request (system prompt, tool schemas,
/// messages, images). CJK scalars count 2, other text one per 3 UTF-8 bytes,
/// plus structural headroom. An engineering estimate, not a token upper bound;
/// provider-specific tests and real usage calibrate it.
nonisolated struct ContextEstimator: Sendable {
    static let version = 1
    static let messageOverhead = 8
    static let unknownImageTokens = 4096
    /// Usage calibration, bounded to 0.5–2.
    var calibration: Double = 1

    static func textTokens(_ text: String) -> Int {
        var cjk = 0, otherBytes = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 }
            else { otherBytes += scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4 }
        }
        return cjk * 2 + (otherBytes + 2) / 3
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    static func imageTokens(_ image: AgentImageAttachment) -> Int {
        // Implausible or missing dimensions use the unknown default.
        guard (1...100_000).contains(image.pixelWidth), (1...100_000).contains(image.pixelHeight) else { return unknownImageTokens }
        // Tiled vision estimate, capped by the unknown default (no overflow: ≤ 196² tiles).
        let tiles = ((image.pixelWidth + 511) / 512) * ((image.pixelHeight + 511) / 512)
        return min(unknownImageTokens, 85 + 170 * max(1, tiles))
    }

    static func messageTokens(_ message: AgentTranscriptMessage) -> Int {
        var total = messageOverhead + textTokens(message.modelText ?? message.text)
        for call in message.toolCalls { total += textTokens(call.name) + textTokens(call.arguments.encodedString) + messageOverhead }
        for block in message.reasoning { total += textTokens(block.text) }
        for image in message.images { total += imageTokens(image) }
        // Provider replay items and replayed context are sent too.
        for item in message.providerItems { total += textTokens(item.encodedString) }
        if let snapshot = message.contextSnapshot { total += textTokens(snapshot.modelDescription) }
        return total
    }

    func estimate(systemPrompt: String, tools: [AgentToolDescriptor], messages: [AgentTranscriptMessage]) -> Int {
        var raw = Self.textTokens(systemPrompt) + Self.messageOverhead
        for tool in tools {
            raw += Self.textTokens(tool.name) + Self.textTokens(tool.summary) + Self.textTokens(tool.inputSchema.encodedString)
        }
        for message in messages { raw += Self.messageTokens(message) }
        return calibrated(raw)
    }

    func rawEstimate(_ request: AgentModelRequest) -> Int {
        var copy = self
        copy.calibration = 1
        return copy.estimate(request)
    }

    /// Applies the bounded factor; never traps on huge or non-finite values.
    func calibrated(_ raw: Int) -> Int {
        let factor = calibration.isFinite ? min(2, max(0.5, calibration)) : 1
        let value = (Double(raw) * factor).rounded(.up)
        guard value.isFinite, value < Double(Int.max / 4) else { return Int.max / 4 }
        return max(0, Int(value))
    }

    func estimate(_ request: AgentModelRequest) -> Int {
        estimate(systemPrompt: request.systemPrompt, tools: request.tools, messages: request.messages)
    }

    /// Bounded calibration from a real usage sample of the same provider/model/input mode.
    /// Outliers (ratio outside 0.25–4) are ignored instead of skewing the factor.
    mutating func calibrate(estimatedRaw: Int, actualInputTokens: Int) {
        guard estimatedRaw > 0, actualInputTokens > 0 else { return }
        let ratio = Double(actualInputTokens) / Double(estimatedRaw)
        guard ratio.isFinite, (0.25...4).contains(ratio), calibration.isFinite else { return }
        calibration = min(2, max(0.5, calibration * 0.7 + ratio * 0.3))
    }
}

/// Process-local usage calibration per provider/model/input mode. Samples
/// come from real provider usage of the same request shape; nothing is
/// persisted or synchronized, and no window is inferred from usage.
@MainActor
final class EstimatorCalibration {
    static let shared = EstimatorCalibration()
    struct Key: Hashable { var providerID: UUID; var modelID: String; var images: Bool }
    private var factors: [Key: ContextEstimator] = [:]
    func estimator(_ key: Key) -> ContextEstimator { factors[key] ?? ContextEstimator() }
    func record(_ key: Key, estimatedRaw: Int, actualInputTokens: Int) {
        var estimator = factors[key] ?? ContextEstimator()
        estimator.calibrate(estimatedRaw: estimatedRaw, actualInputTokens: actualInputTokens)
        factors[key] = estimator
    }
}
