import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// A writer that can be told to fail, standing in for the atomic file write.
@MainActor
private final class FakeWriter {
    var fail = false
    var writes: [Data] = []
    func write(_ data: Data) throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        writes.append(data)
    }
}

@MainActor
struct HistoryOwnerTests {
    private func owner() -> (HistoryOwner, FakeWriter) {
        let writer = FakeWriter()
        return (HistoryOwner(file: .initial(selection: nil), writer: { try writer.write($0) }), writer)
    }

    @Test func failedTransactionPublishesNothing() throws {
        let (owner, writer) = owner()
        let before = owner.file
        writer.fail = true
        #expect(throws: (any Error).self) {
            try owner.transact { try $0.editSession($0.assistant.primarySessionID) { $0.title = "改名" } }
        }
        #expect(owner.file == before && owner.health == .ready)
        writer.fail = false
        try owner.transact { try $0.editSession($0.assistant.primarySessionID) { $0.title = "改名" } }
        #expect(owner.file.primary?.title == "改名" && writer.writes.count == 1)
        #expect(try HistoryCodec.decode(writer.writes[0]).primary?.title == "改名")
    }

    @Test func failedRecordKeepsEventVisibleBlocksTransactionsAndFlushRestoresStorageOnly() async throws {
        let (owner, writer) = owner()
        let primary = owner.file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "查天气")
        try owner.transact { try $0.acceptRoot(prompt, attachments: [], in: primary, scope: .general) }
        owner.barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        var failures: [StorageCommitError] = []
        owner.onStorageFailure = { failures.append($0) }
        writer.fail = true
        let reply = AgentTranscriptMessage(role: .assistant, text: "晴")
        let durable = owner.record(commit: .init(epoch: 1, messages: [reply.id: try CommittedMessage(reply)])) {
            try $0.appendEvent(reply, to: primary, root: prompt.id)
        }
        #expect(!durable)
        // The event happened: it stays visible even though it is not saved.
        #expect(owner.file.primary?.messages.map(\.id) == [prompt.id, reply.id])
        guard case .saveDirty = owner.health else { Issue.record("expected dirty"); return }
        #expect(failures.count == 1)
        #expect(throws: StorageBlocked.self) { try owner.transact { _ in } }
        // Every gate of the job fails instead of waiting.
        await #expect(throws: StorageCommitError.self) {
            try await owner.barrier.wait(epoch: 1, .messages([reply.id: try MessageDigestDTO.requestDigest(reply)]))
        }
        writer.fail = false
        try owner.flush()
        #expect(owner.health == .ready)
        #expect(try HistoryCodec.decode(writer.writes.last!).primary?.messages.count == 2)
        // Flushing restores storage, not the stopped job.
        await #expect(throws: StorageCommitError.self) {
            try await owner.barrier.wait(epoch: 1, .messages([reply.id: try MessageDigestDTO.requestDigest(reply)]))
        }
    }

    /// Review finding: a late event written after storage recovered must not
    /// clear the dirty state by itself or revive the failed run.
    @Test func lateRecordAfterWriterRecoveryKeepsStorageDirtyUntilExplicitFlush() async throws {
        let (owner, writer) = owner()
        let primary = owner.file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "开始")
        try owner.transact { try $0.acceptRoot(prompt, attachments: [], in: primary, scope: .general) }
        owner.barrier.open(epoch: 5, seed: [prompt.id: try CommittedMessage(prompt)])
        writer.fail = true
        let first = AgentTranscriptMessage(role: .assistant, text: "一")
        owner.record(commit: .init(epoch: 5, messages: [first.id: try CommittedMessage(first)])) {
            try $0.appendEvent(first, to: primary, root: prompt.id)
        }
        guard case .saveDirty = owner.health else { Issue.record("expected dirty"); return }
        writer.fail = false
        let late = AgentTranscriptMessage(role: .assistant, text: "迟到的事件")
        let durable = owner.record(commit: .init(epoch: 5, messages: [late.id: try CommittedMessage(late)])) {
            try $0.appendEvent(late, to: primary, root: prompt.id)
        }
        #expect(!durable)
        guard case .saveDirty = owner.health else { Issue.record("late record cleared dirty"); return }
        // The event is kept and written, yet nothing new may be accepted.
        #expect(owner.file.primary?.messages.map(\.id) == [prompt.id, first.id, late.id])
        #expect(try HistoryCodec.decode(writer.writes.last!).primary?.messages.count == 3)
        #expect(throws: StorageBlocked.self) { try owner.transact { _ in } }
        await #expect(throws: StorageCommitError.self) {
            try await owner.barrier.wait(epoch: 5, .messages([late.id: try MessageDigestDTO.requestDigest(late)]),
                                         timeout: .milliseconds(100))
        }
        try owner.flush()
        #expect(owner.health == .ready)
        await #expect(throws: StorageCommitError.self) {
            try await owner.barrier.wait(epoch: 5, .messages([late.id: try MessageDigestDTO.requestDigest(late)]),
                                         timeout: .milliseconds(100))
        }
    }

    @Test func barrierWaitsForDurableContentAndRejectsWrongDigest() async throws {
        let barrier = TranscriptCommitBarrier()
        barrier.open(epoch: 3)
        let message = AgentTranscriptMessage(role: .assistant, text: "a")
        let expected = try MessageDigestDTO.requestDigest(message)
        let waiter = Task { try await barrier.wait(epoch: 3, .messages([message.id: expected]), timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        var edited = message; edited.text = "b"
        barrier.commit(epoch: 3, [message.id: try CommittedMessage(edited)])
        try await Task.sleep(for: .milliseconds(50))
        // Same ID with different content is not an acknowledgement.
        barrier.commit(epoch: 3, [message.id: try CommittedMessage(message)])
        try await waiter.value
        let stale = Task { try await barrier.wait(epoch: 3, .messages([UUID(): "x"]), timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        barrier.close(epoch: 3)
        await #expect(throws: StorageCommitError.jobReplaced) { try await stale.value }
        await #expect(throws: StorageCommitError.timedOut) {
            barrier.open(epoch: 4)
            try await barrier.wait(epoch: 4, .messages([UUID(): "x"]), timeout: .milliseconds(50))
        }
    }

    @Test func toolDispatchNeedsSourceCallAndEveryEarlierResult() async throws {
        let barrier = TranscriptCommitBarrier()
        barrier.open(epoch: 1)
        let runID = UUID()
        let first = AgentToolCall(id: "c1", name: "observe_screen", arguments: .object([:]))
        let second = AgentToolCall(id: "c2", name: "tap", arguments: .object(["node": .number(1)]))
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [first, second])
        let requirement = TranscriptCommitBarrier.Requirement.toolDispatch(
            runID: runID, sourceMessageID: assistant.id, callID: "c2", callDigest: try MessageDigestDTO.callDigest(second))
        #expect(!TranscriptCommitBarrier.satisfied(requirement, in: [:]))
        let committed = [assistant.id: try CommittedMessage(assistant)]
        #expect(!TranscriptCommitBarrier.satisfied(requirement, in: committed))
        let result = AgentTranscriptMessage(id: AgentTranscriptMessage.toolResultID(runID: runID, callID: "c1"),
                                            role: .tool, text: "{}", toolCallID: "c1", toolName: "observe_screen")
        var all = committed
        all[result.id] = try CommittedMessage(result)
        // A saved message with the result's UUID is not the per-call watermark.
        #expect(!TranscriptCommitBarrier.satisfied(requirement, in: all))
        let saved: Set<TranscriptCommitBarrier.ResultKey> = [.init(runID: runID, callID: "c1")]
        #expect(TranscriptCommitBarrier.satisfied(requirement, in: all, results: saved))
        // A provider-answered earlier call is acknowledged without any local message.
        #expect(TranscriptCommitBarrier.satisfied(requirement, in: committed, results: saved))
        // A different argument set for the same call ID is not the saved call.
        let forged = TranscriptCommitBarrier.Requirement.toolDispatch(
            runID: runID, sourceMessageID: assistant.id, callID: "c2",
            callDigest: try MessageDigestDTO.callDigest(AgentToolCall(id: "c2", name: "tap", arguments: .object(["node": .number(9)]))))
        #expect(!TranscriptCommitBarrier.satisfied(forged, in: all, results: saved))
        // The first call needs no earlier result.
        let firstOnly = TranscriptCommitBarrier.Requirement.toolDispatch(
            runID: runID, sourceMessageID: assistant.id, callID: "c1", callDigest: try MessageDigestDTO.callDigest(first))
        #expect(TranscriptCommitBarrier.satisfied(firstOnly, in: committed))
    }

    @Test func cancellationReleasesAWaiter() async throws {
        let barrier = TranscriptCommitBarrier()
        barrier.open(epoch: 9)
        let task = Task { try await barrier.wait(epoch: 9, .messages([UUID(): "x"]), timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: StorageCommitError.cancelled) { try await task.value }
    }

    @Test func digestsAreStableAndIgnoreRequestOnlyState() throws {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let message = AgentTranscriptMessage(id: id, role: .user, text: "你好", createdAt: Date(timeIntervalSince1970: 1))
        var request = message
        request.images = [AgentImageAttachment(label: "a", mimeType: "image/png", data: Data([1]), pixelWidth: 1, pixelHeight: 1)]
        request.contextSnapshot = AgentTurnContextSnapshot()
        request.createdAt = Date(timeIntervalSince1970: 99)
        #expect(try MessageDigestDTO.digest(message) == MessageDigestDTO.digest(request))
        // Provider replay items and image identity are part of the request view.
        var items = message; items.providerItems = [.object(["id": .string("rs_1")])]
        #expect(try MessageDigestDTO.requestDigest(items) != MessageDigestDTO.requestDigest(message))
        #expect(try MessageDigestDTO.requestDigest(message, imageIDs: [UUID()]) != MessageDigestDTO.requestDigest(message))
        #expect(try MessageDigestDTO.requestDigest(request) == MessageDigestDTO.requestDigest(message, imageIDs: request.images.map(\.id)))
        #expect(CanonicalDigest.contentFingerprint(" 北京\r\n出差 ") == CanonicalDigest.contentFingerprint("北京\n出差"))
        #expect(CanonicalDigest.contentFingerprint("北京") != CanonicalDigest.contentFingerprint("北京出差"))
        #expect(CanonicalDigest.contentFingerprint("Tea") != CanonicalDigest.contentFingerprint("tea"))
    }

    /// Sorted-key canonical JSON of an ordered DTO: the same bytes in every
    /// process. Fixed expected values pin the encoding version.
    @Test func canonicalDigestsHaveFixedValues() throws {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let message = AgentTranscriptMessage(id: id, role: .assistant, text: "你好",
            toolCalls: [AgentToolCall(id: "c1", name: "tap", arguments: .object(["snapshot_id": .number(3), "node": .number(1)]))],
            createdAt: Date(timeIntervalSince1970: 1))
        let messageDigest = try MessageDigestDTO.digest(message)
        let segmentDigest = try HistoryFile.segmentDigest([message])
        #expect(messageDigest == FixedDigests.message)
        #expect(segmentDigest == FixedDigests.segment)
        #expect(CanonicalDigest.contentFingerprint("北京\r\n出差 ") == FixedDigests.fingerprint)
    }

    @Test func segmentDigestTracksMembershipAndContent() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "a")
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .workspace(UUID()))
        let initial = try #require(file.assistant.scopeIndex.scopedRoot(prompt.id)?.segmentDigest)
        let revision = file.assistant.scopeIndex.dependencyRevision
        let call = AgentToolCall(id: "c", name: "observe_screen", arguments: .object([:]))
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        try file.appendEvent(assistant, to: primary, root: prompt.id)
        let steer = AgentTranscriptMessage(role: .user, text: "改成查天气")
        try file.appendEvent(steer, to: primary, root: prompt.id)
        let result = AgentTranscriptMessage(role: .tool, text: "{}", toolCallID: "c", toolName: "observe_screen")
        // Tool result goes before undelivered steering, preserving call/result adjacency.
        try file.appendEvent(result, to: primary, root: prompt.id, before: [steer.id])
        #expect(file.primary?.messages.map(\.id) == [prompt.id, assistant.id, result.id, steer.id])
        #expect(file.assistant.scopeIndex.root(of: steer.id) == prompt.id)
        let after = try #require(file.assistant.scopeIndex.scopedRoot(prompt.id)?.segmentDigest)
        #expect(after != initial && file.assistant.scopeIndex.dependencyRevision > revision)
        #expect(try HistoryFile.segmentDigest(file.segment(root: prompt.id, in: primary)) == after)
    }

    @Test func dispatchPermitClearsPromotedReceiptAndMarksRunning() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "下一件")
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .general)
        file.assistant.pendingNext = PendingNext(sessionID: primary, prompt: .promoted(promptID: prompt.id),
            selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil, backend: .ddi,
            clipboardAllowed: true, acceptedOrdinal: 2, state: .queued, references: [], acceptedAt: Date())
        _ = try HistoryCodec.encode(file)
        try file.commitDispatchPermit(root: prompt.id, sessionID: primary, scope: .general)
        #expect(file.assistant.pendingNext == nil && file.primary?.state == .running)
        #expect(file.assistant.scopeIndex.scopedRoot(prompt.id)?.dispatchAuthorized == true)
        _ = try HistoryCodec.encode(file)
    }
}

struct HistoryFileEncoderTests {
    @Test func incrementalEncodingDecodesToTheSameFileAndTracksEdits() throws {
        var file = HistoryFile.initial(selection: ModelSelection(providerID: UUID(), modelID: "m"))
        file.sessions[0].draft = #"包含 "messages":[] 与 "sessions":[] 的草稿"#
        file.sessions[0].title = #""messages":[]"#
        let first = AgentTranscriptMessage(role: .user, text: #"{"sessions":[]} "messages":[]"#)
        file.sessions[0].messages = [first, AgentTranscriptMessage(role: .assistant, text: "回复")]
        var copy = ChatSession(title: "副本")
        var changed = first; changed.text = "副本中的不同内容"
        copy.messages = [changed]
        copy.conflictOf = file.sessions[0].id
        file.sessions.append(copy)
        let encoder = HistoryFileEncoder()
        #expect(try HistoryCodec.decode(encoder.encode(file)) == file)
        // Second pass reuses cached fragments; edits in place are re-encoded.
        #expect(try HistoryCodec.decode(encoder.encode(file)) == file)
        file.sessions[0].messages[1].text = "改过的回复"
        file.sessions[1].messages = []
        #expect(try HistoryCodec.decode(encoder.encode(file)) == file)
        var empty = HistoryFile.initial(selection: nil)
        empty.sessions = []
        #expect(try HistoryCodec.decode(encoder.encode(empty)) == empty)
    }

    /// Confirmed bug: the first `"messages":[]` in bytes could be a nested
    /// attachments key, so messages were spliced into the wrong object and the
    /// next launch could not read the file.
    @Test func nestedSameNamedFieldsNeverReceiveTheSplicedArrays() throws {
        let encoder = HistoryFileEncoder()
        for round in 0..<200 {
            var file = HistoryFile.initial(selection: nil)
            let user = AgentTranscriptMessage(role: .user, text: "第 \(round) 条")
            file.sessions[0].messages = [user, AgentTranscriptMessage(role: .assistant, text: "好")]
            // Nested keys named like the spliced top-level fields, in varying sets.
            var keys = ["messages", "sessions", user.id.uuidString]
            for extra in 0..<(round % 7) { keys.append("k\(extra)-\(round)") }
            for key in keys { file.sessions[0].attachments[key] = round % 3 == 0 ? [] : [ChatAttachment(
                id: UUID(), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1, byteCount: round)] }
            file.sessions[0].draft = #"{"messages":[],"sessions":[]}"#
            if round % 2 == 0 {
                var copy = ChatSession(title: "messages")
                var changed = user; changed.text = "同 ID 不同内容 \(round)"
                copy.messages = [changed]
                copy.attachments["sessions"] = []
                file.sessions.append(copy)
            }
            let data = try encoder.encode(file)
            #expect(try HistoryCodec.decode(data) == file)
        }
    }

    /// Scope-index rows (membership, roots) are reused from earlier writes
    /// only while unchanged: after every kind of index change the incremental
    /// file decodes to the same history as a full encode, as the same JSON value.
    @MainActor
    @Test func cachedScopeRowsFollowEveryIndexChange() throws {
        var file = try LongHistoryBenchmark.synthetic(messages: 300)
        let encoder = HistoryFileEncoder()
        func same() throws {
            let incremental = try encoder.encode(file)
            #expect(try HistoryCodec.decode(incremental) == file)
            let a = try JSONSerialization.jsonObject(with: incremental) as? NSDictionary
            let b = try JSONSerialization.jsonObject(with: HistoryCodec.encode(file)) as? NSDictionary
            let rows = { (d: NSDictionary?) -> Set<String> in
                let index = (d?["assistant"] as? NSDictionary)?["scopeIndex"] as? NSDictionary
                return Set(((index?["messageRoots"] as? [NSDictionary]) ?? []).map { "\($0)" })
            }
            // Same value except the order of membership rows, which carries no meaning.
            let sameRows = rows(a) == rows(b)
            #expect(sameRows)
            let strip = { (d: NSDictionary?) -> NSDictionary? in
                guard let copy = d?.mutableCopy() as? NSMutableDictionary,
                      let assistant = (copy["assistant"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary,
                      let index = (assistant["scopeIndex"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary else { return nil }
                index["messageRoots"] = nil; assistant["scopeIndex"] = index; copy["assistant"] = assistant
                return copy
            }
            let sameValue = strip(a) == strip(b)
            #expect(sameValue)
        }
        try same()
        try same()
        let primary = file.assistant.primarySessionID
        let roots = file.assistant.scopeIndex.sortedRootRows.map(\.rootPromptID)
        // A new root and member, a dependency change, a mask, a moved member, a removed message.
        let prompt = AgentTranscriptMessage(role: .user, text: "新的一轮")
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .general)
        try same()
        try file.registerReads(root: prompt.id, memory: [], roots: [roots[0]], messages: [])
        try same()
        try file.assistant.scopeIndex.mask(root: roots[1], by: UUID())
        try same()
        try file.appendEvent(AgentTranscriptMessage(role: .assistant, text: "事件"), to: primary, root: prompt.id)
        try same()
        file.sessions[0].messages.removeLast(7)
        try file.assistant.scopeIndex.prune(existing: Set(file.sessions.flatMap { $0.messages.map(\.id) }))
        try same()
        // The same message ID removed and recorded again under another root between two writes.
        let target = AgentTranscriptMessage(role: .user, text: "另一轮")
        try file.acceptRoot(target, attachments: [], in: primary, scope: .general)
        try same()
        let moved = file.sessions[0].messages[10]
        #expect(file.assistant.scopeIndex.root(of: moved.id).map { $0 != target.id } == true)
        file.sessions[0].messages.removeAll { $0.id == moved.id }
        try file.assistant.scopeIndex.prune(existing: Set(file.sessions.flatMap { $0.messages.map(\.id) }))
        try file.appendEvent(moved, to: primary, root: target.id)
        #expect(file.assistant.scopeIndex.root(of: moved.id) == target.id)
        try same()
    }

    @Test func spliceRefusesAMissingOrRepeatedPair() {
        let once = Data(#"{"a":1,"messages":"S","b":[]}"#.utf8)
        let twice = Data(#"{"messages":"S","x":{"messages":"S"}}"#.utf8)
        let spliced = HistoryFileEncoder.splice(once, key: "messages", sentinel: "S", elements: [Data("1".utf8), Data("2".utf8)])
        #expect(spliced.map { String(decoding: $0, as: UTF8.self) } == #"{"a":1,"messages":[1,2],"b":[]}"#)
        #expect(HistoryFileEncoder.splice(twice, key: "messages", sentinel: "S", elements: []) == nil)
        #expect(HistoryFileEncoder.splice(Data("{}".utf8), key: "messages", sentinel: "S", elements: []) == nil)
        // The nested same-named key precedes the real one in bytes (the key
        // order JSONEncoder chose in failing processes): only the sentinel
        // pair is replaced.
        let nestedFirst = Data(#"{"attachments":{"messages":[]},"messages":"S","id":"x"}"#.utf8)
        let fixed = HistoryFileEncoder.splice(nestedFirst, key: "messages", sentinel: "S", elements: [Data(#"{"m":1}"#.utf8)])
        #expect(fixed.map { String(decoding: $0, as: UTF8.self) } == #"{"attachments":{"messages":[]},"messages":[{"m":1}],"id":"x"}"#)
    }
}

/// v1 canonical values, also reproduced independently (sorted-key compact
/// JSON + SHA-256 outside Swift). A change means stored segment, summary and
/// reference digests would stop matching.
enum FixedDigests {
    static let message = "v1:db26d14d4a6aac5303ee1a0b567cba017f5fa1a23a0d862a10da4d719fc9d251"
    static let segment = "v1:4fba9b8cfabd44640ea899235157a9575539fb38ceb5f20d1d5b40ac0a9285d8"
    static let fingerprint = "v1:4cb911b9dead4ad081ab47fbe5302ee4df843b24793710727c847eaaf635321c"
}
