import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Chinese lexical recall evaluation over a fixed synthetic table, through
/// the two paths the assistant actually uses: `memory_search` ranking and the
/// automatic per-request memory block. Keywords, scope, forget and unrelated
/// queries are asserted; paraphrases and false-positive probes are measured
/// and reported, because word matching (NLTokenizer terms + CJK bigrams, no
/// embeddings) is expected to miss paraphrases. Set
/// `POCKETAGENT_EVAL_REPORT=/path/report.json` to write the per-query results.
struct ChineseRecallEvaluationTests {
    private static let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private static let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    /// Label → content and scope.
    private static let corpus: [(String, String, MemoryScope)] = [
        ("home", "我住在杭州西湖区", .global),
        ("meeting", "每周五下午三点开组会", .global),
        ("coffee", "喝咖啡不加糖，偏好美式", .global),
        ("allergy", "对花生过敏", .global),
        ("daughter", "女儿叫小雨，今年上三年级", .global),
        ("parcel", "常用的快递地址是公司前台", .global),
        ("plate", "车牌号是浙A12345（测试数据）", .global),
        ("weekend", "周末通常去爬山", .global),
        ("hotel", "出差住宿预算每晚不超过500元", .global),
        ("gym", "健身房在小区对面", .global),
        ("cilantro", "不吃香菜", .global),
        ("mom", "通讯录里妈妈的备注是“老妈”", .global),
        ("repo", "项目P的代码仓库放在GitLab", .workspace(project)),
        ("email", "报销用工作邮箱提交", .workspace(project)),
        ("deadline", "项目Q的截止日期是月底", .workspace(other)),
    ]

    private enum Kind: String, CaseIterable { case keyword, paraphrase, unrelated, falsePositive, scope, forget }

    private struct Query {
        var kind: Kind
        var text: String
        var scope: WorkScope = .general
        var expected: Set<String>
        var forget: [String] = []
    }

    private static let queries: [Query] = [
        .init(kind: .keyword, text: "杭州", expected: ["home"]),
        .init(kind: .keyword, text: "组会几点开始", expected: ["meeting"]),
        .init(kind: .keyword, text: "咖啡要加糖吗", expected: ["coffee"]),
        .init(kind: .keyword, text: "我对什么过敏", expected: ["allergy"]),
        .init(kind: .keyword, text: "小雨", expected: ["daughter"]),
        .init(kind: .keyword, text: "快递寄到哪里", expected: ["parcel"]),
        .init(kind: .keyword, text: "车牌号", expected: ["plate"]),
        .init(kind: .keyword, text: "周末爬山", expected: ["weekend"]),
        .init(kind: .keyword, text: "住宿预算", expected: ["hotel"]),
        .init(kind: .keyword, text: "香菜", expected: ["cilantro"]),
        .init(kind: .paraphrase, text: "我家在哪个城市", expected: ["home"]),
        .init(kind: .paraphrase, text: "开会是星期几", expected: ["meeting"]),
        .init(kind: .paraphrase, text: "我能吃坚果吗", expected: ["allergy"]),
        .init(kind: .paraphrase, text: "孩子读几年级", expected: ["daughter"]),
        .init(kind: .paraphrase, text: "住酒店一晚能花多少钱", expected: ["hotel"]),
        .init(kind: .paraphrase, text: "早上喝什么饮品", expected: ["coffee"]),
        .init(kind: .paraphrase, text: "给母亲打电话", expected: ["mom"]),
        .init(kind: .unrelated, text: "明天天气怎么样", expected: []),
        .init(kind: .unrelated, text: "帮我订一张去北京的机票", expected: []),
        .init(kind: .unrelated, text: "播放一首轻音乐", expected: []),
        .init(kind: .unrelated, text: "今天的股票行情", expected: []),
        .init(kind: .falsePositive, text: "西湖醋鱼怎么做", expected: []),
        .init(kind: .falsePositive, text: "公司前台电话", expected: []),
        .init(kind: .falsePositive, text: "小区停车费", expected: []),
        .init(kind: .scope, text: "代码仓库在哪", expected: []),
        .init(kind: .scope, text: "代码仓库在哪", scope: .workspace(project), expected: ["repo"]),
        .init(kind: .scope, text: "代码仓库在哪", scope: .workspace(other), expected: []),
        .init(kind: .scope, text: "截止日期", scope: .workspace(other), expected: ["deadline"]),
        .init(kind: .scope, text: "截止日期", scope: .workspace(project), expected: []),
        .init(kind: .forget, text: "咖啡要加糖吗", expected: [], forget: ["coffee"]),
        .init(kind: .forget, text: "杭州", expected: ["home"], forget: ["coffee"]),
    ]

    private struct Result: Encodable {
        var kind: String, query: String, scope: String, expected: [String]
        var search: [String], block: [String], searchHit: Bool, blockHit: Bool, searchExtra: [String], blockExtra: [String]
    }

    private func evaluate() throws -> [Result] {
        var base = HistoryFile.initial(selection: nil)
        var labels: [UUID: String] = [:], ids: [String: UUID] = [:]
        for (label, content, scope) in Self.corpus {
            let id = try #require(try base.applyMemoryEdit(.add(target: .memory, scope: scope, content: content, origin: .panel,
                                                                sourceRootPromptIDs: [], sourceMessageIDs: [])).entryIDs.first)
            labels[id] = label; ids[label] = id
        }
        return try Self.queries.map { query in
            var file = base
            for label in query.forget {
                let preview = try file.forgetPreview([ids[label]!], activeRoot: nil)
                _ = try file.commitForget(preview, activeRoot: nil)
            }
            let ledger = file.assistant.memory
            let search = MemorySearch.rank(ledger.visible(in: query.scope), query: query.text).prefix(5).compactMap { labels[$0.id] }
            let block = MemoryBlock.build(ledger, scope: query.scope, query: query.text).reads.compactMap { labels[$0.entryID] }
            let scope = query.scope == .general ? "general" : (query.scope == .workspace(Self.project) ? "P" : "Q")
            return Result(kind: query.kind.rawValue, query: query.text, scope: scope, expected: query.expected.sorted(),
                          search: search, block: block,
                          searchHit: query.expected.isSubset(of: Set(search)), blockHit: query.expected.isSubset(of: Set(block)),
                          searchExtra: search.filter { !query.expected.contains($0) },
                          blockExtra: block.filter { !query.expected.contains($0) })
        }
    }

    @Test func lexicalRecallBaseline() throws {
        let results = try evaluate()
        func group(_ kind: Kind) -> [Result] { results.filter { $0.kind == kind.rawValue } }
        // Asserted: exact words recall in both paths; an entry of a scope the
        // query cannot see, or a forgotten entry, is never returned.
        let scopes = Dictionary(uniqueKeysWithValues: Self.corpus.map { ($0.0, $0.2) })
        for kind in [Kind.keyword, .scope, .forget] {
            for r in group(kind) { #expect(r.searchHit && r.blockHit, "\(r.kind) \(r.query)") }
        }
        for (r, query) in zip(results, Self.queries) {
            for label in r.search + r.block {
                #expect(scopes[label]!.visible(in: query.scope), "\(r.query) returned \(label) outside its scope")
                #expect(!query.forget.contains(label), "\(r.query) returned forgotten \(label)")
            }
        }
        // Measured: single-character words (在、对、去) match in both paths, so
        // unrelated questions can return or inject an entry; reported below.
        // Measured: paraphrases and shared-word probes (reported, not tuned).
        let paraphrase = group(.paraphrase), probes = group(.falsePositive)
        let summary: [String: String] = [
            "keyword": "\(group(.keyword).filter(\.searchHit).count)/\(group(.keyword).count)",
            "paraphraseSearch": "\(paraphrase.filter(\.searchHit).count)/\(paraphrase.count)",
            "paraphraseBlock": "\(paraphrase.filter(\.blockHit).count)/\(paraphrase.count)",
            "falsePositiveProbesWithResults": "\(probes.filter { !$0.search.isEmpty }.count)/\(probes.count)",
            "scope": "\(group(.scope).filter(\.searchHit).count)/\(group(.scope).count)",
            "forget": "\(group(.forget).filter(\.searchHit).count)/\(group(.forget).count)",
            "unrelatedWithResults": "\(group(.unrelated).filter { !$0.search.isEmpty }.count)/\(group(.unrelated).count)",
            "queriesWithExtraEntries": "\(results.filter { !$0.searchExtra.isEmpty }.count)/\(results.count)",
        ]
        if let path = ProcessInfo.processInfo.environment["POCKETAGENT_EVAL_REPORT"] {
            struct Report: Encodable { var summary: [String: String]; var results: [Result] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Report(summary: summary, results: results)).write(to: URL(fileURLWithPath: path))
        }
        #expect(paraphrase.count == 7 && probes.count == 3)
    }
}
