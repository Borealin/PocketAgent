import AgentKit
import Foundation

/// The byte layout of the one history file. The file is the same JSON value
/// `HistoryCodec.encode` produces; only key order and insignificant
/// whitespace differ:
///
///     { <file fields except sessions>, <spaces> "sessions":[ S, S, … ]}
///     S = { <session fields except messages>, <spaces> "messages":[ m,m,… ] <spaces> }
///
/// Whitespace capacity after the file fields (including the assistant
/// section), after each session's fields and after each message array keeps
/// every other byte at its offset when one of them changes, so a write can
/// replace only the changed ranges. Capacities are chosen when the layout is
/// (re)built; a region that outgrows its capacity, or a change in the
/// session order, rebuilds it.
nonisolated struct HistoryLayout: Sendable {
    struct Session: Sendable {
        var id: UUID
        /// Offset of the session's `{`.
        var start: Int
        var headerCapacity: Int
        var contentCapacity: Int
        /// Session fields except messages, each followed by a comma.
        var header: Data
        var messages: [AgentTranscriptMessage]
        /// Encoded messages, parallel to `messages`.
        var fragments: [Data]
        /// End of each fragment inside the content region (exclusive).
        var ends: [Int]

        /// Messages, commas and the closing bracket.
        var contentLength: Int { (ends.last ?? 0) + 1 }
        var contentStart: Int { start + 1 + headerCapacity + HistoryLayout.messagesKey.count }
        var length: Int { 1 + headerCapacity + HistoryLayout.messagesKey.count + contentCapacity + 1 }
    }

    static let sessionsKey = Data("\"sessions\":[".utf8)
    static let messagesKey = Data("\"messages\":[".utf8)

    var prefixCapacity: Int
    /// File fields except sessions, each followed by a comma.
    var prefix: Data
    var sessions: [Session]

    var sessionsStart: Int { 1 + prefixCapacity + Self.sessionsKey.count }
    var size: Int {
        sessionsStart + sessions.reduce(0) { $0 + $1.length } + max(0, sessions.count - 1) + 2
    }

    static func ends(_ fragments: [Data]) -> [Int] {
        var ends: [Int] = []
        ends.reserveCapacity(fragments.count)
        var offset = 0
        for (index, fragment) in fragments.enumerated() {
            if index > 0 { offset += 1 }
            offset += fragment.count
            ends.append(offset)
        }
        return ends
    }

    /// Assigns fresh capacities and offsets.
    static func fresh(prefix: Data, sessions: [Session]) -> HistoryLayout {
        let total = prefix.count + sessions.reduce(0) { $0 + $1.header.count + $1.contentLength }
        let floor = min(1 << 20, max(16 << 10, total / 64))
        var layout = HistoryLayout(prefixCapacity: prefix.count + max(64 << 10, prefix.count / 8), prefix: prefix, sessions: [])
        var start = layout.sessionsStart
        for var session in sessions {
            session.start = start
            session.headerCapacity = session.header.count + max(1 << 10, session.header.count / 2)
            session.contentCapacity = session.contentLength + max(floor, session.contentLength / 8)
            start += session.length + 1
            layout.sessions.append(session)
        }
        return layout
    }

    /// The whole file, built in one pass.
    func image() -> Data {
        var data = Data()
        data.reserveCapacity(size)
        data.append(0x7B)
        data.append(prefix)
        data.append(contentsOf: repeatElement(0x20, count: prefixCapacity - prefix.count))
        data.append(Self.sessionsKey)
        for (index, session) in sessions.enumerated() {
            if index > 0 { data.append(0x2C) }
            data.append(0x7B)
            data.append(session.header)
            data.append(contentsOf: repeatElement(0x20, count: session.headerCapacity - session.header.count))
            data.append(Self.messagesKey)
            for (position, fragment) in session.fragments.enumerated() {
                if position > 0 { data.append(0x2C) }
                data.append(fragment)
            }
            data.append(0x5D)
            data.append(contentsOf: repeatElement(0x20, count: session.contentCapacity - session.contentLength))
            data.append(0x7D)
        }
        data.append(0x5D)
        data.append(0x7D)
        return data
    }
}

/// Builds layouts and patch plans. It holds only encoding caches: the last
/// published layout is passed in by the writer, which adopts a plan's layout
/// only after that plan is published.
nonisolated final class HistoryLayoutEncoder {
    struct Chunk: Sendable {
        var offset: Int
        var bytes: Data
    }

    struct Plan: Sendable {
        /// The file's layout once this plan is published.
        var layout: HistoryLayout
        /// Ranges that turn a file holding the baseline exactly into
        /// `layout.image()`; nil when the layout was rebuilt and the whole
        /// file must be written.
        var chunks: [Chunk]?
    }

    struct ShellError: Error {}

    private let shells = HistoryFileEncoder()

    init() {}

    /// The fields of an encoded object without its unique `"key":"sentinel"`
    /// pair, each followed by a comma. Nil when the pair is not unique or the
    /// object has no other field.
    static func fields(_ shell: Data, key: String, sentinel: String) -> Data? {
        let pair = Data("\"\(key)\":\"\(sentinel)\"".utf8)
        guard shell.first == 0x7B, shell.last == 0x7D, let range = shell.range(of: pair),
              shell.range(of: pair, in: range.upperBound..<shell.endIndex) == nil else { return nil }
        var removed = range
        if range.upperBound < shell.endIndex, shell[range.upperBound] == 0x2C {
            removed = range.lowerBound..<(range.upperBound + 1)
        } else if range.lowerBound > shell.startIndex, shell[range.lowerBound - 1] == 0x2C {
            removed = (range.lowerBound - 1)..<range.upperBound
        }
        var inner = Data()
        inner.reserveCapacity(shell.count)
        inner.append(shell[(shell.startIndex + 1)..<removed.lowerBound])
        inner.append(shell[removed.upperBound..<(shell.endIndex - 1)])
        guard !inner.isEmpty else { return nil }
        inner.append(0x2C)
        return inner
    }

    /// The first index whose message differs (ordinary `==`), or the
    /// shorter count.
    static func firstChange(_ old: [AgentTranscriptMessage], _ new: [AgentTranscriptMessage]) -> Int {
        let count = min(old.count, new.count)
        var index = 0
        while index < count, old[index] == new[index] { index += 1 }
        return index
    }

    func plan(_ file: HistoryFile, baseline: HistoryLayout?) throws -> Plan {
        try HistoryCodec.validate(file)
        let sentinel = "pocketagent-splice-" + UUID().uuidString
        guard let prefix = Self.fields(try shells.fileShell(file, sentinel: sentinel), key: "sessions", sentinel: sentinel) else {
            throw ShellError()
        }
        let previous = Dictionary((baseline?.sessions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sessions: [HistoryLayout.Session] = []
        sessions.reserveCapacity(file.sessions.count)
        var firstChanges: [Int] = []
        for session in file.sessions {
            guard let header = Self.fields(try shells.sessionShell(session, sentinel: sentinel), key: "messages",
                                           sentinel: sentinel) else { throw ShellError() }
            let old = previous[session.id]
            let first = old.map { Self.firstChange($0.messages, session.messages) } ?? 0
            var fragments = Array((old?.fragments ?? []).prefix(first))
            fragments.reserveCapacity(session.messages.count)
            for index in first..<session.messages.count {
                let message = session.messages[index]
                if let old, index < old.messages.count, old.messages[index] == message {
                    fragments.append(old.fragments[index])
                } else {
                    fragments.append(try shells.encodeMessage(message))
                }
            }
            var ends = Array((old?.ends ?? []).prefix(first))
            ends.reserveCapacity(fragments.count)
            var offset = ends.last ?? 0
            for index in first..<fragments.count {
                if index > 0 { offset += 1 }
                offset += fragments[index].count
                ends.append(offset)
            }
            sessions.append(HistoryLayout.Session(id: session.id, start: old?.start ?? 0, headerCapacity: old?.headerCapacity ?? 0,
                                                  contentCapacity: old?.contentCapacity ?? 0, header: header,
                                                  messages: session.messages, fragments: fragments, ends: ends))
            firstChanges.append(first)
        }
        guard let baseline, baseline.sessions.map(\.id) == file.sessions.map(\.id), prefix.count <= baseline.prefixCapacity,
              zip(baseline.sessions, sessions).allSatisfy({ old, new in
                  new.header.count <= old.headerCapacity && new.contentLength <= old.contentCapacity
              }) else {
            return Plan(layout: .fresh(prefix: prefix, sessions: sessions), chunks: nil)
        }
        var chunks: [Chunk] = []
        if prefix != baseline.prefix {
            chunks.append(Chunk(offset: 1, bytes: Self.padded(prefix, over: baseline.prefix.count)))
        }
        for (index, (old, new)) in zip(baseline.sessions, sessions).enumerated() {
            if new.header != old.header {
                chunks.append(Chunk(offset: old.start + 1, bytes: Self.padded(new.header, over: old.header.count)))
            }
            let first = firstChanges[index]
            guard first < new.messages.count || new.messages.count != old.messages.count else { continue }
            let relative = first == 0 ? 0 : new.ends[first - 1]
            var tail = Data()
            tail.reserveCapacity(new.contentLength - relative)
            for position in first..<new.fragments.count {
                if position > 0 { tail.append(0x2C) }
                tail.append(new.fragments[position])
            }
            tail.append(0x5D)
            chunks.append(Chunk(offset: old.contentStart + relative,
                                bytes: Self.padded(tail, over: old.contentLength - relative)))
        }
        var layout = baseline
        layout.prefix = prefix
        layout.sessions = sessions
        return Plan(layout: layout, chunks: chunks)
    }

    /// `bytes` followed by spaces over whatever longer content it replaces.
    private static func padded(_ bytes: Data, over previous: Int) -> Data {
        guard previous > bytes.count else { return bytes }
        var data = bytes
        data.append(contentsOf: repeatElement(0x20, count: previous - bytes.count))
        return data
    }
}
