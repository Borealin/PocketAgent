import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

private func msg(_ text: String, role: AgentTranscriptRole = .user, id: UUID = UUID(), ms: Int64 = 1_000) -> PortableMessage {
    PortableMessage(AgentTranscriptMessage(id: id, role: role, text: text, createdAt: PortableTime.date(ms)), attribution: nil)
}
private func session(_ id: UUID, _ messages: [PortableMessage], title: String = "t", meta: Int64 = 0) -> PortableSession {
    PortableSession(id: id, title: title, selection: nil, metadataUpdatedMs: meta, messages: messages)
}
private func snap(_ sessions: [PortableSession], providers: [PortableProvider] = [],
                  deleted: [PortableTombstone] = [], deletedProviders: [PortableTombstone] = []) -> PortableSnapshot {
    PortableSnapshot(sessions: sessions, providers: providers, deletedSessions: deleted, deletedProviders: deletedProviders)
}

struct PortableMergeTests {
    let id = UUID()
    let m1 = msg("a"), m2 = msg("b", role: .assistant)

    @Test func prefixCompatibleKeepsLongerWithoutConflict() {
        let short = snap([session(id, [m1])]), long = snap([session(id, [m1, m2])])
        let merged = PortableMerge.merge(short, long)
        #expect(merged.sessions.count == 1 && merged.sessions[0].messages == [m1, m2])
        #expect(PortableMerge.merge(long, short) == merged)
    }

    @Test func divergentHistoriesProduceOneStableConflictCopy() {
        let a = snap([session(id, [m1, msg("from A")])]), b = snap([session(id, [m1, msg("from B")])])
        let ab = PortableMerge.merge(a, b), ba = PortableMerge.merge(b, a)
        #expect(ab == ba)
        #expect(ab.sessions.count == 2)
        let copy = ab.sessions.first { $0.id != id }!
        #expect(copy.title.hasSuffix(PortableMerge.conflictSuffix))
        // Idempotent: merging again, in either direction, adds nothing.
        #expect(PortableMerge.merge(ab, a) == ab)
        #expect(PortableMerge.merge(ab, b) == ab)
        #expect(PortableMerge.merge(ab, ab) == ab)
        // Each device keeping its own winner converges on the same copy ID.
        #expect(PortableMerge.merge(PortableMerge.merge(a, ab), PortableMerge.merge(b, ab)) == ab)
        let all = Set(ab.sessions.flatMap { $0.messages.map(\.text) })
        #expect(all == ["a", "from A", "from B"])
    }

    @Test func sameMessageIDEditedDifferentlyIsDetectedAsDivergence() {
        let shared = UUID()
        let a = snap([session(id, [m1, msg("version A", id: shared)])])
        let b = snap([session(id, [m1, msg("version B", id: shared)])])
        let merged = PortableMerge.merge(a, b)
        #expect(merged.sessions.count == 2)
        #expect(Set(merged.sessions.flatMap { $0.messages.filter { $0.id == shared }.map(\.text) }) == ["version A", "version B"])
        #expect(PortableMerge.merge(merged, b) == merged)
    }

    @Test func tombstonesPreventResurrectionOfSessionsAndProviders() {
        let provider = PortableProvider(ProviderRecord(name: "P", inferenceURL: "https://a.example.com/v1"))
        let remote = snap([session(id, [m1, m2])], providers: [provider])
        let local = snap([], deleted: [PortableTombstone(id: id, deletedAtMs: 5)],
                         deletedProviders: [PortableTombstone(id: provider.id, deletedAtMs: 5)])
        let merged = PortableMerge.merge(local, remote)
        #expect(merged.sessions.isEmpty && merged.providers.isEmpty)
        #expect(merged.deletedSessions.map(\.id) == [id])
        #expect(PortableMerge.merge(remote, merged) == merged)
    }

    @Test func providerUpdatesUseNewestAndMetadataIsDeterministic() {
        var record = ProviderRecord(name: "Old", inferenceURL: "https://a.example.com/v1", updatedAt: PortableTime.date(1_000))
        let old = PortableProvider(record)
        record.name = "New"; record.updatedAt = PortableTime.date(2_000)
        let new = PortableProvider(record)
        #expect(PortableMerge.merge(snap([], providers: [old]), snap([], providers: [new])).providers == [new])
        #expect(PortableMerge.merge(snap([], providers: [new]), snap([], providers: [old])).providers == [new])

        let renamedA = snap([session(id, [m1], title: "A", meta: 10)]), renamedB = snap([session(id, [m1], title: "B", meta: 20)])
        #expect(PortableMerge.merge(renamedA, renamedB).sessions[0].title == "B")
        let tieA = snap([session(id, [m1], title: "A", meta: 10)]), tieB = snap([session(id, [m1], title: "B", meta: 10)])
        #expect(PortableMerge.merge(tieA, tieB) == PortableMerge.merge(tieB, tieA))
    }

    @Test func portableProjectionRedactsLocalOnlyData() throws {
        let image = AgentImageAttachment(label: "screen", mimeType: "image/png", data: Data([1, 2, 3]), pixelWidth: 1, pixelHeight: 1)
        let attachment = AgentContextAttachment(kind: .file, label: "f", contentTypeIdentifier: "public.data",
                                                suggestedFilename: "f", data: Data([9]))
        let call = AgentToolCall(id: "c1", name: "tap", arguments: .object(["node": .number(1)]), providerItemID: "opaque")
        var chat = ChatSession(selection: ModelSelection(providerID: UUID(), modelID: "m"))
        chat.draft = "unsent draft"; chat.state = .running; chat.detail = "running detail"
        chat.messages = [
            AgentTranscriptMessage(role: .user, text: "hi", images: [image], contextAttachments: [attachment]),
            AgentTranscriptMessage(role: .assistant, reasoning: [AgentReasoningBlock(text: "hidden")], toolCalls: [call],
                                   providerItems: [.string("encrypted")]),
            AgentTranscriptMessage(role: .tool, text: "{\"ok\":true}", toolCallID: "c1", toolName: "tap"),
        ]
        let provider = ProviderRecord(name: "P", inferenceURL: "https://a.example.com/v1")
        let snapshot = PortableSnapshot(sessions: [chat, ChatSession()], sessionTombstones: [],
                                        providers: [provider], providerTombstones: [])
        let text = String(decoding: try PortableCodec.encode(snapshot), as: UTF8.self)
        for forbidden in ["unsent draft", "running detail", "hidden", "encrypted", "opaque", "AQID", "selectedID",
                          "images", "contextAttachments", "providerItems", "reasoning", "state", "secret", "apiKey"] {
            #expect(!text.contains(forbidden), "leaked \(forbidden)")
        }
        #expect(snapshot.sessions.count == 1, "empty sessions stay local")
        let decoded = try PortableCodec.decode(try PortableCodec.encode(snapshot))
        #expect(decoded == snapshot)
        let messages = decoded.sessions[0].messages
        #expect(messages[1].toolCalls.map(\.id) == ["c1"] && messages[2].toolCallID == "c1")
    }

    @Test func unknownOrNewerSchemaFailsAndInvalidContentIsRejected() throws {
        #expect(throws: SyncError.newerVersion(2)) { try PortableCodec.decode(Data(#"{"schemaVersion":2}"#.utf8)) }
        #expect(throws: SyncError.unreadable("缺少 schemaVersion")) { try PortableCodec.decode(Data("{}".utf8)) }
        #expect(throws: SyncError.unreadable("不是 JSON 对象")) { try PortableCodec.decode(Data("garbage".utf8)) }
        var bad = PortableProvider(ProviderRecord(name: "P", inferenceURL: "https://a.example.com/v1"))
        bad.inferenceURL = "http://plain.example.com"
        let data = try PortableCodec.encode(snap([], providers: [bad]))
        #expect(throws: SyncError.self) { try PortableCodec.decode(data) }
    }

    @Test func stableIDsAreDeterministic() {
        #expect(StableHash.uuid(["a", "b"]) == StableHash.uuid(["a", "b"]))
        #expect(StableHash.uuid(["a", "b"]) != StableHash.uuid(["ab"]))
        #expect(StableHash.digest(Data("x".utf8)) == StableHash.digest(Data("x".utf8)))
    }
}

struct SyncApplicationTests {
    private func chat(_ texts: [String], id: UUID = UUID()) -> ChatSession {
        var s = ChatSession(); s.id = id
        s.messages = texts.map { AgentTranscriptMessage(role: .user, text: $0, createdAt: PortableTime.date(1_000)) }
        return s
    }
    private func local(_ sessions: [ChatSession], tombstones: [Tombstone] = []) -> PortableSnapshot {
        PortableSnapshot(sessions: sessions, sessionTombstones: tombstones, providers: [], providerTombstones: [])
    }

    @Test func remoteUpdateAppliesButKeepsDraftAndState() {
        var mine = chat(["a"]); mine.draft = "draft"; mine.state = .completed
        let base = local([mine])
        var remoteSession = PortableSession(mine)!
        remoteSession.messages.append(PortableMessage(AgentTranscriptMessage(role: .assistant, text: "b"), attribution: "P · m"))
        let plan = SyncPlan.make(local: base, remote: PortableSnapshot(sessions: [remoteSession]), deferred: [])
        #expect(plan.output == nil, "remote already holds the merge")
        let result = SyncApplication.sessions([mine], tombstones: [], merged: plan.merged, base: base, deferred: [])
        #expect(result.sessions[0].messages.map(\.text) == ["a", "b"])
        #expect(result.sessions[0].draft == "draft" && result.sessions[0].state == .completed)
        #expect(result.sessions[0].attributions.values.contains("P · m"))
    }

    @Test func activeSessionIsDeferredAndRemoteVersionIsPreservedInOutput() {
        let mine = chat(["a", "local running"])
        var remote = PortableSession(chat(["a"], id: mine.id))!
        remote.messages.append(PortableMessage(AgentTranscriptMessage(role: .user, text: "remote only"), attribution: nil))
        let base = local([mine])
        let plan = SyncPlan.make(local: base, remote: PortableSnapshot(sessions: [remote]), deferred: [mine.id])
        #expect(plan.merged.sessions == [remote], "remote data is not lost while local work is deferred")
        let result = SyncApplication.sessions([mine], tombstones: [], merged: plan.merged, base: base, deferred: [mine.id])
        #expect(result.sessions[0].messages.map(\.text) == ["a", "local running"])
        #expect(result.deferred == 1)
    }

    @Test func localEditDuringSyncIsNotOverwrittenAndDeletionIsNotUndone() {
        let edited = chat(["a"]), deleted = chat(["x"])
        let base = local([edited, deleted])
        var remoteEdited = PortableSession(edited)!
        remoteEdited.messages.append(PortableMessage(AgentTranscriptMessage(role: .user, text: "remote"), attribution: nil))
        let plan = SyncPlan.make(local: base, remote: PortableSnapshot(sessions: [remoteEdited]), deferred: [])
        var current = edited
        current.messages.append(AgentTranscriptMessage(role: .user, text: "typed during sync"))
        let tomb = Tombstone(id: deleted.id, deletedAt: Date())
        let result = SyncApplication.sessions([current], tombstones: [tomb], merged: plan.merged, base: base, deferred: [])
        #expect(result.sessions.map(\.id) == [edited.id])
        #expect(result.sessions[0].messages.last?.text == "typed during sync")
        #expect(result.tombstones.map(\.id).contains(deleted.id))
    }

    @Test func remoteDeletionRemovesLocalAndNewRemoteSessionsArriveIdle() {
        let doomed = chat(["bye"]), fresh = chat(["new"])
        let base = local([doomed])
        let remote = PortableSnapshot(sessions: [PortableSession(fresh)!],
                                      deletedSessions: [PortableTombstone(id: doomed.id, deletedAtMs: 10)])
        let plan = SyncPlan.make(local: base, remote: remote, deferred: [])
        let result = SyncApplication.sessions([doomed], tombstones: [], merged: plan.merged, base: base, deferred: [])
        #expect(result.sessions.map(\.id) == [fresh.id])
        #expect(result.sessions[0].state == .idle && result.sessions[0].draft.isEmpty)
    }

    @Test func realTimestampsConvergeWithoutChurnOrLocalRewrite() throws {
        var mine = ChatSession()
        let call = AgentToolCall(id: "c1", name: "observe_screen", arguments: .object([:]))
        mine.messages = [
            AgentTranscriptMessage(role: .user, text: "看屏幕", createdAt: Date(timeIntervalSinceReferenceDate: 811_111_111.123_456_7)),
            AgentTranscriptMessage(role: .assistant, toolCalls: [call], providerItems: [.string("opaque")],
                                   createdAt: Date(timeIntervalSinceReferenceDate: 811_111_112.987_654_3)),
            AgentTranscriptMessage(role: .tool, text: "{}", toolCallID: "c1", toolName: "observe_screen", modelText: "{}",
                                   createdAt: Date(timeIntervalSinceReferenceDate: 811_111_113.000_444_4)),
        ]
        mine.attributions[mine.messages[1].id.uuidString] = "P · m"
        let base = local([mine])
        var remote = try #require(base.sessions.first)
        remote.messages.append(PortableMessage(AgentTranscriptMessage(role: .user, text: "另一台设备", createdAt: Date()), attribution: nil))
        let plan = SyncPlan.make(local: base, remote: PortableSnapshot(sessions: [remote]), deferred: [])
        let result = SyncApplication.sessions([mine], tombstones: [], merged: plan.merged, base: base, deferred: [])
        #expect(result.sessions.count == 1)
        #expect(Array(result.sessions[0].messages.prefix(3)) == mine.messages, "local values keep exact dates and provider state")
        #expect(result.sessions[0].messages.count == 4)
        let second = SyncPlan.make(local: local(result.sessions), remote: plan.merged, deferred: [])
        #expect(second.output == nil, "second round writes nothing")
        #expect(second.merged.sessions.count == 1, "no conflict copy")
    }

    @Test func emptyLocalSessionAdoptsRemoteContentWithSameID() {
        let empty = ChatSession()
        let base = local([empty])
        #expect(base.sessions.isEmpty)
        let remote = PortableSnapshot(sessions: [PortableSession(chat(["remote"], id: empty.id))!])
        let plan = SyncPlan.make(local: base, remote: remote, deferred: [])
        let result = SyncApplication.sessions([empty], tombstones: [], merged: plan.merged, base: base, deferred: [])
        #expect(result.sessions.map(\.id) == [empty.id])
        #expect(result.sessions[0].messages.map(\.text) == ["remote"])
    }

    @Test func providersApplyUpdatesDeletionsAndKeepLocalEdits() {
        let a = ProviderRecord(name: "A", inferenceURL: "https://a.example.com/v1", updatedAt: PortableTime.date(1_000))
        let b = ProviderRecord(name: "B", inferenceURL: "https://b.example.com/v1", updatedAt: PortableTime.date(1_000))
        let base = PortableSnapshot(sessions: [], sessionTombstones: [], providers: [a, b], providerTombstones: [])
        var remoteA = PortableProvider(a); remoteA.name = "A2"; remoteA.updatedAtMs = 2_000
        let remote = PortableSnapshot(providers: [remoteA, PortableProvider(b)],
                                      deletedProviders: [PortableTombstone(id: b.id, deletedAtMs: 3_000)])
        let plan = SyncPlan.make(local: base, remote: remote, deferred: [])
        let applied = SyncApplication.providers([a, b], tombstones: [], merged: plan.merged, base: base)
        #expect(applied.providers.map(\.name) == ["A2"] && applied.removed == [b.id])
        var editedA = a; editedA.name = "Local edit"
        let kept = SyncApplication.providers([editedA], tombstones: [], merged: plan.merged, base: base)
        #expect(kept.providers.map(\.name) == ["Local edit"])
    }
}
