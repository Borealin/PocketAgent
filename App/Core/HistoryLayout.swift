import AgentKit
import Foundation
import Synchronization

/// The byte layout of the one history file. The file is the same JSON value
/// `HistoryCodec.encode` produces; only key order and insignificant
/// whitespace differ:
///
///     {"sessions":[ S, S, … ],<file fields except sessions>}
///     S = {"messages":[ m,m,… ]<spaces>,<session fields except messages><spaces>}
///
/// Sessions come first and the other file fields (including the assistant
/// section, rewritten by almost every event) last, without capacity, so their
/// growth moves nothing. Inside a session the message array comes first,
/// followed by whitespace capacity, then the session's other fields and their
/// capacity. A change inside a region rewrites only that region; a region
/// that outgrows its capacity, or a change in the session list, rewrites from
/// the first moved session to the end of the file.
nonisolated struct HistoryLayout: Sendable {
    struct Session: Sendable {
        var id: UUID
        /// Offset of the session's `{`.
        var start: Int
        var contentCapacity: Int
        var headerCapacity: Int
        /// Session fields except messages, without a trailing comma.
        var header: Data
        var messages: [AgentTranscriptMessage]
        /// Encoded messages, parallel to `messages`.
        var fragments: [Data]
        /// End of each fragment inside the content region (exclusive).
        var ends: [Int]

        /// Messages, commas and the closing bracket.
        var contentLength: Int { (ends.last ?? 0) + 1 }
        var contentStart: Int { start + HistoryLayout.sessionHead.count }
        /// Offset of the first session field (after the comma closing the content region).
        var headerStart: Int { contentStart + contentCapacity + 1 }
        var length: Int { HistoryLayout.sessionHead.count + contentCapacity + 1 + headerCapacity + 1 }
        var end: Int { start + length }
    }

    static let fileHead = Data(#"{"sessions":["#.utf8)
    static let sessionHead = Data(#"{"messages":["#.utf8)

    var sessions: [Session]
    /// File fields except sessions, without a trailing comma.
    var tail: Data

    var sessionsEnd: Int { sessions.last?.end ?? Self.fileHead.count }
    var tailStart: Int { sessionsEnd + 2 }
    var size: Int { tailStart + tail.count + 1 }

    static func ends(_ fragments: [Data], keeping prefix: ArraySlice<Int> = []) -> [Int] {
        var ends = Array(prefix)
        ends.reserveCapacity(fragments.count)
        var offset = ends.last ?? 0
        for index in prefix.count..<fragments.count {
            if index > 0 { offset += 1 }
            offset += fragments[index].count
            ends.append(offset)
        }
        return ends
    }

    /// Spare bytes for a region from its own length only, so the whole
    /// capacity stays within 1/8 (messages) and 1/2 (session fields) of the
    /// data plus a small constant per session, however many sessions there are.
    static func contentSpare(_ length: Int) -> Int { max(16 << 10, length / 8) }
    static func headerSpare(_ length: Int) -> Int { max(1 << 10, length / 2) }

    /// Places sessions from `first` on after the previous one, keeping a
    /// session's capacities while its content and fields still fit them.
    mutating func place(from first: Int) {
        for index in first..<sessions.count {
            var session = sessions[index]
            session.start = index == 0 ? Self.fileHead.count : sessions[index - 1].end + 1
            if session.contentCapacity < session.contentLength {
                session.contentCapacity = session.contentLength + Self.contentSpare(session.contentLength)
            }
            if session.headerCapacity < session.header.count {
                session.headerCapacity = session.header.count + Self.headerSpare(session.header.count)
            }
            sessions[index] = session
        }
    }

    /// Fresh capacities and offsets for every session.
    static func fresh(sessions: [Session], tail: Data) -> HistoryLayout {
        var layout = HistoryLayout(sessions: sessions.map { session in
            var session = session
            session.contentCapacity = 0; session.headerCapacity = 0
            return session
        }, tail: tail)
        layout.place(from: 0)
        return layout
    }

    /// Where the bytes from session `first` (or, past the last session, the
    /// closing of the session list) begin.
    func suffixStart(_ first: Int) -> Int {
        first == 0 ? Self.fileHead.count : sessions[first - 1].end
    }

    /// The file's bytes from `suffixStart(first)` to the end.
    func suffix(_ first: Int) -> Data {
        var data = Data()
        data.reserveCapacity(size - suffixStart(first))
        appendSuffix(first, to: &data)
        return data
    }

    /// The whole file, built in one pass into one buffer.
    func image() -> Data {
        var data = Data()
        data.reserveCapacity(size)
        data.append(Self.fileHead)
        appendSuffix(0, to: &data)
        return data
    }

    /// One piece of the whole file, in file order.
    enum Piece {
        case data(Data)
        case byte(UInt8)
        /// A run of ASCII spaces (capacity).
        case spaces(Int)
    }

    /// The whole file's pieces in order, for writing it without assembling
    /// the image: the same bytes as `image()`, every byte from offset 0 to
    /// `size`, capacity as spaces.
    func visit(_ body: (Piece) throws -> Void) rethrows {
        try body(.data(Self.fileHead))
        for index in sessions.indices {
            if index > 0 { try body(.byte(0x2C)) }
            let session = sessions[index]
            try body(.data(Self.sessionHead))
            for (position, fragment) in session.fragments.enumerated() {
                if position > 0 { try body(.byte(0x2C)) }
                try body(.data(fragment))
            }
            try body(.byte(0x5D))
            try body(.spaces(session.contentCapacity - session.contentLength))
            try body(.byte(0x2C))
            try body(.data(session.header))
            try body(.spaces(session.headerCapacity - session.header.count))
            try body(.byte(0x7D))
        }
        try body(.byte(0x5D))
        try body(.byte(0x2C))
        try body(.data(tail))
        try body(.byte(0x7D))
    }

    private func appendSuffix(_ first: Int, to data: inout Data) {
        for index in first..<sessions.count {
            if index > 0 { data.append(0x2C) }
            append(sessions[index], to: &data)
        }
        data.append(0x5D)
        data.append(0x2C)
        data.append(tail)
        data.append(0x7D)
    }

    private func append(_ session: Session, to data: inout Data) {
        data.append(Self.sessionHead)
        for (position, fragment) in session.fragments.enumerated() {
            if position > 0 { data.append(0x2C) }
            data.append(fragment)
        }
        data.append(0x5D)
        data.append(Data(repeating: 0x20, count: session.contentCapacity - session.contentLength))
        data.append(0x2C)
        data.append(session.header)
        data.append(Data(repeating: 0x20, count: session.headerCapacity - session.header.count))
        data.append(0x7D)
    }

    /// The layout of `data` when it is exactly this layout's image of `file`:
    /// every message encoded again, capacities read from the whitespace runs,
    /// and the rebuilt image compared with `data` byte for byte. `file` must
    /// be the strict decoding of these same bytes. Nil for any other file
    /// (another layout, other bytes), so the next write is whole.
    static func adopting(_ data: Data, file: HistoryFile, encoder: HistoryLayoutEncoder) throws -> HistoryLayout? {
        let bytes = [UInt8](data)
        func matches(_ expected: Data, at offset: Int) -> Bool {
            offset >= 0 && offset + expected.count <= bytes.count && bytes[offset..<(offset + expected.count)].elementsEqual(expected)
        }
        func spaces(from offset: Int) -> Int {
            var end = offset
            while end < bytes.count, bytes[end] == 0x20 { end += 1 }
            return end
        }
        guard matches(fileHead, at: 0) else { return nil }
        let sentinel = "pocketagent-splice-" + UUID().uuidString
        let fragments = try ParallelEncoding.encode(file.sessions.flatMap(\.messages))
        var used = 0
        var sessions: [Session] = []
        var offset = fileHead.count
        for (index, session) in file.sessions.enumerated() {
            guard let header = HistoryLayoutEncoder.fields(try encoder.sessionShell(session, sentinel: sentinel), key: "messages",
                                                           sentinel: sentinel) else { return nil }
            let own = Array(fragments[used..<(used + session.messages.count)])
            used += session.messages.count
            var placed = Session(id: session.id, start: offset, contentCapacity: 0, headerCapacity: 0, header: header,
                                 messages: session.messages, fragments: own, ends: ends(own))
            guard matches(sessionHead, at: offset) else { return nil }
            let contentEnd = placed.contentStart + placed.contentLength
            let comma = spaces(from: contentEnd)
            guard comma < bytes.count, bytes[comma] == 0x2C else { return nil }
            placed.contentCapacity = comma - placed.contentStart
            let close = spaces(from: comma + 1 + header.count)
            guard close < bytes.count, bytes[close] == 0x7D else { return nil }
            placed.headerCapacity = close - (comma + 1)
            sessions.append(placed)
            offset = placed.end
            if index < file.sessions.count - 1 {
                guard offset < bytes.count, bytes[offset] == 0x2C else { return nil }
                offset += 1
            }
        }
        guard matches(Data("],".utf8), at: offset), bytes.last == 0x7D, offset + 2 <= bytes.count - 1 else { return nil }
        let layout = HistoryLayout(sessions: sessions, tail: data.subdata(in: (offset + 2)..<(data.count - 1)))
        return layout.size == data.count && layout.image() == data ? layout : nil
    }
}

/// Encodes values in order on several threads, one encoder per worker (the
/// encoders are not shared); results are placed by index.
nonisolated enum ParallelEncoding {
    private final class Slots: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Data>
        init(_ count: Int) {
            buffer = .allocate(capacity: count)
            buffer.initialize(repeating: Data())
        }
        deinit { buffer.deinitialize(); buffer.deallocate() }
    }

    /// Sorted keys, so an unchanged value always encodes to the same bytes.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func encode<Value: Encodable & Sendable>(_ values: [Value]) throws -> [Data] {
        guard values.count >= 512 else {
            let encoder = encoder()
            return try values.map { try encoder.encode($0) }
        }
        let slots = Slots(values.count)
        let failure = Mutex<(any Error)?>(nil)
        let chunk = 256
        DispatchQueue.concurrentPerform(iterations: (values.count + chunk - 1) / chunk) { part in
            let encoder = encoder()
            for index in (part * chunk)..<min(values.count, (part + 1) * chunk) {
                do { slots.buffer[index] = try encoder.encode(values[index]) } catch {
                    failure.withLock { if $0 == nil { $0 = error } }
                    return
                }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
        return Array(slots.buffer)
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
        /// `layout.image()` (the last may extend or shorten the file); nil
        /// when every session moved and the whole file must be written.
        var chunks: [Chunk]?
    }

    struct ShellError: Error {}

    private let shells = HistoryFileEncoder()

    init() {}

    func sessionShell(_ session: ChatSession, sentinel: String) throws -> Data {
        try shells.sessionShell(session, sentinel: sentinel)
    }

    /// Scope-index rows encoded ahead (`HistoryFileEncoder.RowSeed`).
    func install(_ rows: HistoryFileEncoder.RowSeed) { shells.install(rows) }

    /// The fields of an encoded object without its unique `"key":"sentinel"`
    /// pair, comma-separated, without a trailing comma. Nil when the pair is
    /// not unique or the object has no other field.
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
        return inner.isEmpty ? nil : inner
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
        guard let tail = Self.fields(try shells.fileShell(file, sentinel: sentinel), key: "sessions", sentinel: sentinel) else {
            throw ShellError()
        }
        let previous = Dictionary((baseline?.sessions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sessions: [HistoryLayout.Session] = []
        sessions.reserveCapacity(file.sessions.count)
        var firstChanges: [Int] = []
        var misses: [(session: Int, index: Int)] = []
        for (position, session) in file.sessions.enumerated() {
            guard let header = Self.fields(try shells.sessionShell(session, sentinel: sentinel), key: "messages",
                                           sentinel: sentinel) else { throw ShellError() }
            let old = previous[session.id]
            let first = old.map { Self.firstChange($0.messages, session.messages) } ?? 0
            var fragments = Array((old?.fragments ?? []).prefix(first))
            fragments.reserveCapacity(session.messages.count)
            for index in first..<session.messages.count {
                if let old, index < old.messages.count, old.messages[index] == session.messages[index] {
                    fragments.append(old.fragments[index])
                } else {
                    misses.append((position, index))
                    fragments.append(Data())
                }
            }
            sessions.append(HistoryLayout.Session(id: session.id, start: old?.start ?? 0,
                                                  contentCapacity: old?.contentCapacity ?? 0,
                                                  headerCapacity: old?.headerCapacity ?? 0, header: header,
                                                  messages: session.messages, fragments: fragments, ends: []))
            firstChanges.append(first)
        }
        let encoded = try ParallelEncoding.encode(misses.map { file.sessions[$0.session].messages[$0.index] })
        for (miss, data) in zip(misses, encoded) { sessions[miss.session].fragments[miss.index] = data }
        for (position, session) in file.sessions.enumerated() {
            let kept = (previous[session.id]?.ends ?? []).prefix(firstChanges[position])
            sessions[position].ends = HistoryLayout.ends(sessions[position].fragments, keeping: kept)
        }
        guard let baseline else { return Plan(layout: .fresh(sessions: sessions, tail: tail), chunks: nil) }
        // Sessions that keep their place: same session at the same index,
        // content and fields within capacity.
        var stable = 0
        while stable < min(baseline.sessions.count, sessions.count), baseline.sessions[stable].id == sessions[stable].id,
              sessions[stable].contentLength <= baseline.sessions[stable].contentCapacity,
              sessions[stable].header.count <= baseline.sessions[stable].headerCapacity {
            stable += 1
        }
        let moved = stable < max(baseline.sessions.count, sessions.count)
        if moved, stable == 0 { return Plan(layout: .fresh(sessions: sessions, tail: tail), chunks: nil) }
        var layout = HistoryLayout(sessions: sessions, tail: tail)
        layout.place(from: stable)
        var chunks: [Chunk] = []
        for index in 0..<stable {
            let (old, new) = (baseline.sessions[index], layout.sessions[index])
            let first = firstChanges[index]
            if first < new.messages.count || new.messages.count != old.messages.count {
                let relative = first == 0 ? 0 : new.ends[first - 1]
                var bytes = Data()
                bytes.reserveCapacity(new.contentLength - relative)
                for position in first..<new.fragments.count {
                    if position > 0 { bytes.append(0x2C) }
                    bytes.append(new.fragments[position])
                }
                bytes.append(0x5D)
                chunks.append(Chunk(offset: old.contentStart + relative, bytes: Self.padded(bytes, over: old.contentLength - relative)))
            }
            if new.header != old.header {
                chunks.append(Chunk(offset: old.headerStart, bytes: Self.padded(new.header, over: old.header.count)))
            }
        }
        if moved {
            chunks.append(Chunk(offset: layout.suffixStart(stable), bytes: layout.suffix(stable)))
        } else if tail != baseline.tail {
            chunks.append(Chunk(offset: layout.suffixStart(stable), bytes: layout.suffix(stable)))
        }
        return Plan(layout: layout, chunks: chunks)
    }

    /// `bytes` followed by spaces over whatever longer content it replaces.
    private static func padded(_ bytes: Data, over previous: Int) -> Data {
        guard previous > bytes.count else { return bytes }
        var data = bytes
        data.append(Data(repeating: 0x20, count: previous - bytes.count))
        return data
    }
}
