// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public enum AppleLibraryError: ShuffleError, Equatable {
    case notALibrary
    case malformed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .notALibrary:
            return "this is not an Apple library file"
        case let .malformed(detail):
            return "Apple's library file is damaged: \(detail)"
        case let .unsupported(detail):
            return "Apple's library file has a structure this app does not edit: \(detail)"
        }
    }
}

/// Apple's library file (`iPod_Control/iTunes/iTunesDB`) as the tree of records it is made of.
///
/// `AppleLibrary` picks titles out of whatever it can read. This model is the opposite: strict and
/// complete. Every byte of the file belongs to a record, and writing an unmodified tree gives the
/// original file back, which is checked when the file is read. That is what makes editing safe: the
/// many bytes this app has no use for are carried along untouched.
///
/// Each record starts with a four-letter tag, the length of its header, and either its total length
/// or, for lists, the number of records that follow:
///
///     mhbd                            the file
///       mhsd (4) > mhla > mhia          albums; a track names its album by number
///       mhsd (1) > mhlt > mhit          tracks, each with its strings (mhod)
///       mhsd (3) > mhlp > mhyp          playlists, each with strings and items (mhip); the first is "everything"
///       mhsd (2) > mhlp > mhyp          the same playlists again
///       mhsd (5) > mhlp > mhyp          built-in smart lists ("Music", "Audiobooks")
///
/// Integers are little-endian. Dates are seconds since 1904 on the clock of the Mac that wrote them.
struct AppleLibraryFile: Equatable, Sendable {
    var root: Record

    init(data: Data) throws {
        let reader = ByteReader(data)
        do {
            guard reader.count >= 12, try reader.tag(0) == "mhbd" else { throw AppleLibraryError.notALibrary }
            let (record, size) = try Self.read(reader, at: 0, end: reader.count, depth: 0)
            guard size == reader.count else {
                throw AppleLibraryError.malformed("\(reader.count - size) bytes follow the last record")
            }
            root = record
        } catch let error as BinaryError {
            throw AppleLibraryError.malformed(error.description)
        }
        // Counts and lengths are recomputed on writing. A file whose own numbers disagree with that
        // would be altered just by passing through here, so it is not accepted for editing.
        guard encoded() == data else {
            throw AppleLibraryError.unsupported("its counts and lengths do not add up")
        }
    }

    func encoded() -> Data { Data(root.encoded()) }

    private static func read(_ reader: ByteReader, at offset: Int, end: Int, depth: Int) throws -> (Record, Int) {
        guard depth < 8 else { throw AppleLibraryError.malformed("records are nested too deeply") }
        guard end - offset >= 12 else { throw AppleLibraryError.malformed("a record is cut short at byte \(offset)") }
        let tag = try reader.tag(offset)
        guard let shape = Record.shape(of: tag) else {
            throw AppleLibraryError.unsupported("unknown record at byte \(offset)")
        }
        let headerLength = Int(try reader.u32(offset + 4))
        guard headerLength >= Record.minimumHeaderLength(of: tag), headerLength <= end - offset else {
            throw AppleLibraryError.malformed("the \(tag) record at byte \(offset) has a header of \(headerLength) bytes")
        }
        var record = Record(tag: tag, header: try reader.slice(offset, headerLength))
        let declared = Int(try reader.u32(offset + 8))

        if shape == .list {
            // `declared` is a count taken from the file; a wrong one simply runs into the end of the data.
            var position = offset + headerLength
            for _ in 0..<declared {
                let (child, size) = try read(reader, at: position, end: end, depth: depth + 1)
                record.children.append(child)
                position += size
            }
            try record.checkChildren()
            return (record, position - offset)
        }

        guard declared >= headerLength, declared <= end - offset else {
            throw AppleLibraryError.malformed("the \(tag) record at byte \(offset) claims \(declared) bytes")
        }
        if shape == .data {
            record.body = try reader.slice(offset + headerLength, declared - headerLength)
            return (record, declared)
        }
        var position = offset + headerLength
        while position < offset + declared {
            let (child, size) = try read(reader, at: position, end: offset + declared, depth: depth + 1)
            record.children.append(child)
            position += size
        }
        try record.checkChildren()
        return (record, declared)
    }
}

extension AppleLibraryFile {
    struct Record: Equatable, Sendable {
        enum Shape {
            /// Offset 8 holds the number of records that follow (`mhlt`, `mhlp`, `mhla`).
            case list
            /// Offset 8 holds the total length; the records inside follow the header.
            case container
            /// Offset 8 holds the total length; raw data follows the header (`mhod`).
            case data
        }

        var tag: String
        /// The whole header, tag and length fields included.
        var header: [UInt8]
        var children: [Record] = []
        /// What follows the header of a record that holds data rather than other records.
        var body: [UInt8] = []

        init(tag: String, header: [UInt8], children: [Record] = [], body: [UInt8] = []) {
            self.tag = tag
            self.header = header
            self.children = children
            self.body = body
        }

        /// A new record with a zeroed header of the given length.
        init(tag: String, headerLength: Int, children: [Record] = [], body: [UInt8] = []) {
            precondition(tag.utf8.count == 4 && headerLength >= 12, "records have a four-letter tag and at least three fields")
            var header = [UInt8](repeating: 0, count: headerLength)
            header.replaceSubrange(0..<4, with: Array(tag.utf8))
            self.init(tag: tag, header: header, children: children, body: body)
            set32(UInt32(headerLength), at: 4)
        }

        static func shape(of tag: String) -> Shape? {
            switch tag {
            case "mhlt", "mhlp", "mhla", "mhli": return .list
            case "mhbd", "mhsd", "mhit", "mhyp", "mhip", "mhia", "mhii": return .container
            case "mhod": return .data
            default: return nil
            }
        }

        /// Enough header to hold the fields this app relies on to tell records apart.
        static func minimumHeaderLength(of tag: String) -> Int {
            switch tag {
            case "mhbd": return 24      // number of sections
            case "mhit": return 120     // the track's 64-bit ID
            case "mhyp": return 36      // the playlist's 64-bit ID
            case "mhip": return 28      // the track an item points at
            case "mhia": return 20      // the album's number
            case "mhsd", "mhod": return 16
            default: return 12
            }
        }

        /// Type of a data item (`mhod`) or of a section (`mhsd`).
        var kind: UInt32 { u32(12) }

        // MARK: Structure

        /// Only arrangements this app has seen and knows how to count are accepted.
        fileprivate func checkChildren() throws {
            func require(_ condition: Bool, _ what: String) throws {
                if !condition { throw AppleLibraryError.unsupported("a \(tag) record \(what)") }
            }
            let tags = children.map(\.tag)
            switch tag {
            case "mhbd":
                try require(tags.allSatisfy { $0 == "mhsd" }, "holds something other than sections")
            case "mhsd":
                try require(children.count == 1 && Record.shape(of: tags[0]) == .list, "does not hold exactly one list")
            case "mhlt":
                try require(tags.allSatisfy { $0 == "mhit" }, "holds something other than tracks")
            case "mhlp":
                try require(tags.allSatisfy { $0 == "mhyp" }, "holds something other than playlists")
            case "mhla":
                try require(tags.allSatisfy { $0 == "mhia" }, "holds something other than albums")
            case "mhli":
                try require(tags.allSatisfy { $0 == "mhii" }, "holds something other than artists")
            case "mhit", "mhia", "mhii", "mhip":
                try require(tags.allSatisfy { $0 == "mhod" }, "holds something other than data items")
            case "mhyp":
                // Strings first, then items. Very old files put each item's data after the item instead of
                // inside it; those are not edited.
                let firstItem = tags.firstIndex(of: "mhip") ?? tags.count
                try require(tags[..<firstItem].allSatisfy { $0 == "mhod" }, "does not start with its data items")
                try require(tags[firstItem...].allSatisfy { $0 == "mhip" }, "mixes data items with playlist items")
            default:
                break
            }
        }

        // MARK: Writing

        /// The record and everything in it, with lengths and counts brought up to date.
        func encoded() -> [UInt8] {
            var content = body
            for child in children { content.append(contentsOf: child.encoded()) }

            var copy = self
            if Record.shape(of: tag) == .list {
                copy.set32(UInt32(children.count), at: 8)
            } else {
                copy.set32(UInt32(header.count + content.count), at: 8)
            }
            switch tag {
            case "mhbd":
                copy.set32(UInt32(children.count), at: 20)
            case "mhit", "mhia", "mhii", "mhip":
                copy.set32(UInt32(children.count), at: 12)
            case "mhyp":
                let items = children.filter { $0.tag == "mhip" }.count
                copy.set32(UInt32(children.count - items), at: 12)
                copy.set32(UInt32(items), at: 16)
            default:
                break
            }
            return copy.header + content
        }

        // MARK: Header fields

        // A field that lies beyond the end of the header does not exist in this file: it reads as zero
        // and writing it does nothing. Headers have grown over the years, always at the end.

        func u8(_ offset: Int) -> UInt8 { offset < header.count ? header[offset] : 0 }
        func u16(_ offset: Int) -> UInt16 { UInt16(truncatingIfNeeded: integer(at: offset, bytes: 2)) }
        func u32(_ offset: Int) -> UInt32 { UInt32(truncatingIfNeeded: integer(at: offset, bytes: 4)) }
        func u64(_ offset: Int) -> UInt64 { integer(at: offset, bytes: 8) }

        private func integer(at offset: Int, bytes: Int) -> UInt64 {
            guard offset >= 0, offset + bytes <= header.count else { return 0 }
            var value: UInt64 = 0
            for index in (0..<bytes).reversed() { value = value << 8 | UInt64(header[offset + index]) }
            return value
        }

        /// Each setter reports whether the header changed.
        @discardableResult mutating func set8(_ value: UInt8, at offset: Int) -> Bool { store(UInt64(value), at: offset, bytes: 1) }
        @discardableResult mutating func set16(_ value: UInt16, at offset: Int) -> Bool { store(UInt64(value), at: offset, bytes: 2) }
        @discardableResult mutating func set32(_ value: UInt32, at offset: Int) -> Bool { store(UInt64(value), at: offset, bytes: 4) }
        @discardableResult mutating func set64(_ value: UInt64, at offset: Int) -> Bool { store(value, at: offset, bytes: 8) }

        private mutating func store(_ value: UInt64, at offset: Int, bytes: Int) -> Bool {
            guard offset >= 0, offset + bytes <= header.count, integer(at: offset, bytes: bytes) != value else { return false }
            for index in 0..<bytes { header[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(8 * index)) }
            return true
        }

        // MARK: Strings

        /// Layout of a string item: after the 24-byte header come the encoding (1 = UTF-16, 2 = UTF-8),
        /// the length in bytes, two more fields Apple fills with 1 and 0, then the text.
        static func string(_ type: UInt32, _ text: String) -> Record {
            var record = Record(tag: "mhod", headerLength: 24, body: stringBody(text))
            record.set32(type, at: 12)
            return record
        }

        private static func stringBody(_ text: String) -> [UInt8] {
            var out = ByteWriter()
            out.u32(1)
            out.u32(UInt32(text.utf16.count * 2))
            out.u32(1)
            out.u32(0)
            for unit in text.utf16 { out.u16(unit) }
            return out.bytes
        }

        /// The text of a string item, or `nil` if this is not one.
        var text: String? {
            guard tag == "mhod", body.count >= 16 else { return nil }
            func field(_ offset: Int) -> Int {
                Int(body[offset]) | Int(body[offset + 1]) << 8 | Int(body[offset + 2]) << 16 | Int(body[offset + 3]) << 24
            }
            let length = field(4)
            guard length <= body.count - 16 else { return nil }
            let raw = body[16..<16 + length]
            if field(0) == 2 { return String(decoding: raw, as: UTF8.self) }
            var units: [UInt16] = []
            units.reserveCapacity(length / 2)
            var index = raw.startIndex
            while index + 1 < raw.endIndex {
                units.append(UInt16(raw[index]) | UInt16(raw[index + 1]) << 8)
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }

        /// The string of the given type among this record's data items.
        func string(_ type: UInt32) -> String? {
            children.first { $0.tag == "mhod" && $0.kind == type }?.text
        }

        /// Sets, adds or (for an empty text) removes a string. Returns whether anything changed.
        /// `order` lists string types in the order Apple writes them, so a new one lands in its usual place.
        @discardableResult
        mutating func setString(_ type: UInt32, _ text: String, order: [UInt32]) -> Bool {
            let existing = children.firstIndex { $0.tag == "mhod" && $0.kind == type }
            if let existing {
                if text.isEmpty {
                    children.remove(at: existing)
                    return true
                }
                guard children[existing].text != text else { return false }
                children[existing].body = Record.stringBody(text)
                return true
            }
            guard !text.isEmpty else { return false }
            func rank(_ other: UInt32) -> Int { order.firstIndex(of: other) ?? order.count }
            let position = children.firstIndex { $0.tag != "mhod" || rank($0.kind) > rank(type) } ?? children.count
            children.insert(Record.string(type, text), at: position)
            return true
        }
    }
}
