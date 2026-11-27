import Foundation

/// What the iPod records while it plays, in `iPod_Control/iTunes/iTunesStats`.
///
/// One 32-byte entry per track, in the same order as the track table of the database
/// the iPod was playing from. A sync is expected to read the file and then reset it.
public struct PlayStatistics: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var bookmarkMs: UInt32
        public var playCount: UInt32
        /// Seconds since 1904-01-01 on the iPod's own clock; 0 when never played.
        public var lastPlayed: UInt32
        public var skipCount: UInt32
        public var lastSkipped: UInt32

        public init(bookmarkMs: UInt32 = 0, playCount: UInt32 = 0, lastPlayed: UInt32 = 0, skipCount: UInt32 = 0, lastSkipped: UInt32 = 0) {
            self.bookmarkMs = bookmarkMs
            self.playCount = playCount
            self.lastPlayed = lastPlayed
            self.skipCount = skipCount
            self.lastSkipped = lastSkipped
        }

        public var isEmpty: Bool { bookmarkMs == 0 && playCount == 0 && skipCount == 0 }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public init(data: Data) throws {
        let reader = ByteReader(data)
        do {
            let count = Int(try reader.u32(0))
            var entries: [Entry] = []
            var offset = 8
            for _ in 0..<count {
                let length = Int(try reader.u32(offset))
                guard length >= 24 else { throw DatabaseError.malformed("statistics entry too short") }
                entries.append(Entry(
                    bookmarkMs: try reader.u32(offset + 4),
                    playCount: try reader.u32(offset + 8),
                    lastPlayed: try reader.u32(offset + 12),
                    skipCount: try reader.u32(offset + 16),
                    lastSkipped: try reader.u32(offset + 20)
                ))
                offset += length
            }
            self.entries = entries
        } catch let error as BinaryError {
            throw DatabaseError.malformed(error.description)
        }
    }

    /// True when the iPod recorded anything since the file was last reset.
    public var hasActivity: Bool { entries.contains { !$0.isEmpty } }

    /// The empty file Apple's sync leaves behind: a count, then one zeroed 32-byte entry per track.
    public static func empty(trackCount: Int) -> Data {
        var out = ByteWriter()
        out.u32(UInt32(trackCount))
        out.u32(0)
        for _ in 0..<trackCount {
            out.u32(32)
            out.zeros(28)
        }
        return Data(out.bytes)
    }

    /// Converts the iPod's clock value (seconds since 1904, local time) to a date.
    public static func date(fromDeviceTime value: UInt32, timeZone: TimeZone = .current) -> Date? {
        guard value != 0 else { return nil }
        let unixLocal = TimeInterval(value) - 2_082_844_800
        return Date(timeIntervalSince1970: unixLocal - TimeInterval(timeZone.secondsFromGMT()))
    }
}
