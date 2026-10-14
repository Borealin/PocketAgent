import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

private func uuid(_ n: UInt64) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", n & 0xffffffffffff))! }
private func message(_ text: String, _ id: UUID) -> PortableMessage {
    PortableMessage(AgentTranscriptMessage(id: id, role: .user, text: text, createdAt: Date(timeIntervalSince1970: 1)), attribution: nil)
}
private func one(_ id: UUID, _ title: String, _ messages: [PortableMessage], meta: Int64 = 0,
                 selection: ModelSelection? = nil) -> PortableSnapshot {
    PortableSnapshot(sessions: [PortableSession(id: id, title: title, selection: selection, metadataUpdatedMs: meta, messages: messages)])
}
private func m(_ a: PortableSnapshot, _ b: PortableSnapshot) -> PortableSnapshot { PortableMerge.merge(a, b) }

/// Source: peer review (equal-depth three-branch merge produced grouping-dependent copy titles).
struct MergeAssociativityTests {
    @Test func equalDepthThreeBranchesProduceIdenticalCopiesInAnyGrouping() {
        let s = uuid(1), common = message("common", uuid(2))
        let a = one(s, "A", [common, message("a", uuid(3))], selection: ModelSelection(providerID: uuid(90), modelID: "ma"))
        let b = one(s, "B", [common, message("b", uuid(4))], selection: ModelSelection(providerID: uuid(91), modelID: "mb"))
        let c = one(s, "C", [common, message("c", uuid(5))])
        let groupings = [m(m(a, b), c), m(a, m(b, c)), m(m(a, c), b), m(c, m(b, a))]
        #expect(Set(groupings).count == 1)
        let result = groupings[0]
        #expect(result.sessions.count == 3)
        let original = result.sessions.first { $0.id == s }!
        for copy in result.sessions where copy.id != s {
            #expect(copy.conflictOf == s)
            #expect(copy.title == original.title + PortableMerge.conflictSuffix)
            #expect(copy.selection == original.selection, "copies keep a real selection, never nil")
        }
        #expect(Set(result.sessions.flatMap { $0.messages.map(\.text) }) == ["common", "a", "b", "c"])
        #expect(m(result, a) == result && m(result, m(b, c)) == result)
    }

    @Test func randomizedBranchesWithPrefixesEditsAndRenamesAreAssociative() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
        for trial in 0..<1500 {
            let s = uuid(UInt64(trial) + 1)
            var pool: [[PortableMessage]] = [[message("c", uuid(UInt64(trial) * 100 + 50_000))]]
            var inputs: [PortableSnapshot] = []
            for i in 0..<3 {
                var branch = pool[Int(next() % UInt64(pool.count))]
                let extra = Int(next() % 3)
                for k in 0..<max(extra, branch.count == 1 ? 1 : 0) {
                    branch.append(message("t\(trial)-\(i)-\(k)", uuid(next())))
                }
                if next() % 5 == 0, branch.count > 1 { // same message ID, different content
                    branch[branch.count - 1].text += "-edited\(i)"
                }
                pool.append(branch)
                inputs.append(one(s, "T\(next() % 3)", branch, meta: Int64(next() % 3) * 10))
            }
            let (a, b, c) = (inputs[0], inputs[1], inputs[2])
            let results = [m(m(a, b), c), m(a, m(b, c)), m(m(a, c), b), m(m(c, b), a)]
            guard Set(results).count == 1 else {
                Issue.record("trial \(trial) not associative: \(results.map { $0.sessions.map { "\($0.title):\($0.messages.map(\.text))" } })")
                return
            }
            #expect(m(results[0], results[0]) == results[0])
            #expect(m(results[0], b) == results[0])
            // No message is lost by merging or pruning.
            let all = Set(inputs.flatMap { $0.sessions.flatMap { $0.messages } })
            #expect(Set(results[0].sessions.flatMap(\.messages)) == all)
        }
    }

    @Test func deviceThatKeptChattingDoesNotLeaveStaleTruncatedCopy() {
        // Device X wrote A; Y merged B over it (A lost, became a copy); X then
        // continued A to A' and syncs again. A's copy is contained in A' and
        // must not remain as a duplicate; B is preserved as the copy.
        // Either branch may lose the first tie-break, so exercise both roles.
        let s = uuid(10), common = message("hi", uuid(11))
        let x = message("x1", uuid(12)), y = message("y1", uuid(14))
        var sawStaleCandidate = false
        for (mine, theirs) in [(x, y), (y, x)] {
            let fileAfterOther = m(one(s, "t", [common, mine]), one(s, "t", [common, theirs]))
            sawStaleCandidate = sawStaleCandidate || fileAfterOther.sessions.contains { $0.messages.last == mine && $0.conflictOf == s }
            let continued = one(s, "t", [common, mine, message("more", uuid(15)), message("more2", uuid(16))])
            let result = m(continued, fileAfterOther)
            #expect(result.sessions.count == 2)
            #expect(result.sessions.first { $0.id == s }?.messages.count == 4)
            #expect(result.sessions.contains { $0.conflictOf == s && $0.messages == [common, theirs] })
        }
        #expect(sawStaleCandidate, "one role must exercise a copy later contained in the continued branch")
    }

    /// Source: peer review (pruning dropped a user-edited copy's title/selection).
    @Test func editedCopyContainedInMainIsNotPruned() {
        let root = uuid(40), m1 = message("one", uuid(41)), m2 = message("two", uuid(42))
        let selection = ModelSelection(providerID: uuid(43), modelID: "edited-model")
        let main = one(root, "Main", [m1, m2, message("three", uuid(44))], meta: 100)
        let edited = PortableSnapshot(sessions: [PortableSession(id: uuid(45), title: "Mine", selection: selection,
                                                                 metadataUpdatedMs: 200, messages: [m1, m2], conflictOf: root)])
        let unedited = PortableSnapshot(sessions: [PortableSession(id: uuid(46), title: "x", selection: nil,
                                                                   metadataUpdatedMs: 0, messages: [m1, m2], conflictOf: root)])
        let result = m(m(main, edited), unedited)
        #expect(result == m(main, m(edited, unedited)))
        #expect(result.sessions.first { $0.id == uuid(45) }.map { ($0.title, $0.selection) }! == ("Mine", selection))
        #expect(!result.sessions.contains { $0.id == uuid(46) }, "unedited redundant copy is still pruned")
    }

    @Test func userRenamedCopyKeepsItsOwnTitle() {
        let s = uuid(20), common = message("c", uuid(21))
        let merged = m(one(s, "T", [common, message("a", uuid(22))]), one(s, "T", [common, message("b", uuid(23))]))
        var renamed = merged
        let index = renamed.sessions.firstIndex { $0.conflictOf == s }!
        renamed.sessions[index].title = "My branch"; renamed.sessions[index].metadataUpdatedMs = 500
        let parentRenamed = one(s, "Renamed parent", merged.sessions.first { $0.id == s }!.messages, meta: 600)
        let result = m(m(renamed, merged), parentRenamed)
        #expect(result.sessions.first { $0.conflictOf == s }?.title == "My branch")
        #expect(result.sessions.first { $0.id == s }?.title == "Renamed parent")
        #expect(m(merged, parentRenamed).sessions.first { $0.conflictOf == s }?.title == "Renamed parent" + PortableMerge.conflictSuffix)
    }
}

/// Source: peer review (deletion during sync dropped concurrently appended local text).
struct DeletionDuringSyncTests {
    @Test func sameSessionDeletedRemotelyWhileEditedLocallyKeepsTheEdit() throws {
        let id = UUID()
        var original = ChatSession(); original.id = id
        original.messages = [AgentTranscriptMessage(role: .user, text: "base")]
        let base = PortableSnapshot(sessions: [original], sessionTombstones: [], providers: [], providerTombstones: [])
        let remote = PortableSnapshot(deletedSessions: [PortableTombstone(id: id, deletedAtMs: 10)])
        let plan = SyncPlan.make(local: base, remote: remote, deferred: [])
        var edited = original
        edited.messages.append(AgentTranscriptMessage(role: .user, text: "valuable local edit"))
        edited.draft = "still typing"
        let applied = SyncApplication.sessions([edited], tombstones: [], merged: plan.merged, base: base, deferred: [])
        let kept = try #require(applied.sessions.first)
        #expect(applied.sessions.count == 1)
        #expect(kept.id != id, "the deletion of the original ID is honored")
        #expect(kept.messages.map(\.text) == ["base", "valuable local edit"])
        #expect(kept.draft == "still typing")
        #expect(applied.replaced[id] == kept.id)
        #expect(applied.tombstones.map(\.id).contains(id))
        // Deterministic: replaying the same round yields the same ID.
        let again = SyncApplication.sessions([edited], tombstones: [], merged: plan.merged, base: base, deferred: [])
        #expect(again.sessions.map(\.id) == [kept.id])
        // Next round exports the preserved text; the original stays deleted.
        let next = SyncPlan.make(local: PortableSnapshot(sessions: applied.sessions, sessionTombstones: applied.tombstones,
                                                         providers: [], providerTombstones: []),
                                 remote: plan.merged, deferred: [])
        #expect(next.merged.sessions.map(\.id) == [kept.id])
        #expect(next.merged.deletedSessions.map(\.id) == [id])
    }

    @Test func unchangedSessionIsStillDeleted() {
        var original = ChatSession(); original.messages = [AgentTranscriptMessage(role: .user, text: "x")]
        let base = PortableSnapshot(sessions: [original], sessionTombstones: [], providers: [], providerTombstones: [])
        let plan = SyncPlan.make(local: base, remote: PortableSnapshot(deletedSessions: [PortableTombstone(id: original.id, deletedAtMs: 1)]),
                                 deferred: [])
        #expect(SyncApplication.sessions([original], tombstones: [], merged: plan.merged, base: base, deferred: []).sessions.isEmpty)
    }

    @Test func locallyHeldRedundantCopyIsRemovedWhenUnchanged() {
        let s = uuid(30), common = message("hi", uuid(31))
        let file = m(one(s, "t", [common, message("x", uuid(32))]), one(s, "t", [common, message("y", uuid(33))]))
        let copy = file.sessions.first { $0.conflictOf == s }!
        // This device adopted the copy earlier; another device extended that branch.
        var local = ChatSession(); local.id = copy.id; local.conflictOf = s
        local.messages = copy.messages.map(\.transcript); local.title = copy.title
        let base = PortableSnapshot(sessions: [local], sessionTombstones: [], providers: [], providerTombstones: [])
        let extended = one(s, "t", copy.messages + [message("more", uuid(34)), message("more2", uuid(35))])
        let plan = SyncPlan.make(local: base, remote: m(file, extended), deferred: [])
        #expect(!plan.merged.sessions.contains { $0.id == copy.id })
        let applied = SyncApplication.sessions([local], tombstones: [], merged: plan.merged, base: base, deferred: [])
        #expect(!applied.sessions.contains { $0.id == copy.id })
        #expect(applied.sessions.contains { $0.messages.map(\.text).contains("more2") })
    }
}

/// Source: main static review (iCloud conflict versions were never read).
struct ConflictVersionTests {
    @Test func everyConflictVersionIsMergedAndWritten() {
        let s1 = UUID(), s2 = UUID()
        let current = one(s1, "current", [message("from current", UUID())])
        let versionA = one(s2, "other device", [message("only in conflict version", UUID())])
        let versionB = PortableSnapshot(deletedSessions: [PortableTombstone(id: UUID(), deletedAtMs: 3)])
        let plan = SyncPlan.make(local: PortableSnapshot(), remote: current, conflictVersions: [versionA, versionB], deferred: [])
        #expect(plan.output != nil, "merged result must be written before versions are resolved")
        #expect(Set(plan.merged.sessions.map(\.id)) == [s1, s2])
        #expect(plan.merged.deletedSessions.count == 1)
        let reordered = SyncPlan.make(local: PortableSnapshot(), remote: versionA, conflictVersions: [versionB, current], deferred: [])
        #expect(reordered.merged == plan.merged)
    }
}

/// Source: main review (synced endpoint origin change must not reuse the local key).
struct KeyOriginTests {
    let provider = ProviderRecord(name: "P", inferenceURL: "https://api.example.com/v1/chat/completions",
                                  modelsBaseURL: "https://api.example.com/v1",
                                  models: [ProviderModelEntry(id: "m", supportsImages: false)])

    @Test func originNormalization() {
        #expect(EndpointValidation.origin(of: "https://API.Example.com:443/v1") == "https://api.example.com")
        #expect(EndpointValidation.origin(of: "https://api.example.com:8443/v1/models/{model}:generateContent") == "https://api.example.com:8443")
        #expect(provider.credentialOrigins == ["https://api.example.com"])
    }

    @Test func syncedHostChangeRefusesStoredKey() throws {
        let selection = ModelSelection(providerID: provider.id, modelID: "m")
        let bound = provider.credentialOrigins
        _ = try RunConfiguration.resolve(selection, providers: [provider], secret: { _ in "sk" }, boundOrigins: { _ in bound })
        var moved = provider
        moved.inferenceURL = "https://attacker.example.net/v1/chat/completions"
        #expect(throws: ProviderError.keyOriginChanged("P")) {
            try RunConfiguration.resolve(selection, providers: [moved], secret: { _ in "sk" }, boundOrigins: { _ in bound })
        }
        #expect(throws: ProviderError.keyOriginChanged("P")) {
            try RunConfiguration.resolve(selection, providers: [provider], secret: { _ in "sk" }, boundOrigins: { _ in nil })
        }
        // Path changes on the same origin keep working; keyless providers are unaffected.
        var samehost = provider; samehost.inferenceURL = "https://api.example.com/v2/chat/completions"
        #expect(try RunConfiguration.resolve(selection, providers: [samehost], secret: { _ in "sk" }, boundOrigins: { _ in bound }).secret == "sk")
        #expect(try RunConfiguration.resolve(selection, providers: [moved], secret: { _ in nil }, boundOrigins: { _ in nil }).secret == "")
    }

    @Test func savingRebindsOnlyWithExplicitIntent() throws {
        var moved = provider
        moved.inferenceURL = "https://other.example.org/v1/chat/completions"
        moved.modelsBaseURL = ""
        let bound = provider.credentialOrigins
        // Address changed by sync, user saves without re-entering the key: refused.
        #expect(throws: ProviderError.keyOriginChanged("P")) {
            try KeyBinding.afterSave(stored: moved, saved: moved, bound: bound, hasStoredKey: true, enteredNewKey: false, removeKey: false)
        }
        // User edited the address on this device: explicit intent rebinds.
        #expect(try KeyBinding.afterSave(stored: provider, saved: moved, bound: bound, hasStoredKey: true,
                                         enteredNewKey: false, removeKey: false) == ["https://other.example.org"])
        #expect(try KeyBinding.afterSave(stored: moved, saved: moved, bound: bound, hasStoredKey: true,
                                         enteredNewKey: true, removeKey: false) == ["https://other.example.org"])
        #expect(try KeyBinding.afterSave(stored: moved, saved: moved, bound: bound, hasStoredKey: true,
                                         enteredNewKey: false, removeKey: true) == nil)
        #expect(try KeyBinding.afterSave(stored: provider, saved: provider, bound: bound, hasStoredKey: true,
                                         enteredNewKey: false, removeKey: false) == bound)
    }

    /// assistant-v1 provider files are strict: earlier shapes and other
    /// generations/schemas are refused, never converted.
    @Test func providerFileRefusesEarlierShapesAndUnknownVersions() throws {
        let earlier = #"{"version":1,"providers":[],"deletedProviders":[],"legacySecretPending":false}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ProviderFile.self, from: Data(earlier.utf8)) }
        let current = #"{"generation":"assistant-v1","schemaVersion":2,"providers":[],"defaultSelection":null,"deletedProviders":[],"keyOrigins":{},"budgetOverrides":[]}"#
        #expect(throws: ProviderError.unsupportedVersion(2)) { try JSONDecoder().decode(ProviderFile.self, from: Data(current.utf8)) }
        let valid = current.replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":1"#)
        #expect(try JSONDecoder().decode(ProviderFile.self, from: Data(valid.utf8)).keyOrigins.isEmpty)
    }
}
