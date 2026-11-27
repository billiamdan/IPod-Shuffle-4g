import Foundation

/// The play database the iPod shuffle (3rd and 4th generation) firmware reads from
/// `iPod_Control/iTunes/iTunesSD`.
///
/// Layout (all integers little-endian; the four-character tags read backwards on disk):
///
///     bdhs  header, 64 bytes
///     hths  track table: 20-byte header, then one 4-byte file offset per track
///     rths  one 372-byte record per track
///     hphs  playlist table: fixed part, then one 4-byte file offset per playlist
///     lphs  one record per playlist: 44-byte header, then 4-byte track indexes
///
/// Two variants exist. They differ only in the fixed part of `hphs`:
/// 20 bytes in the documented layout, 68 bytes in what Apple's sync writes today.
/// The type keeps every byte it does not interpret, so decoding and re-encoding an
/// untouched database reproduces the original file exactly.
public struct ShuffleDatabase: Equatable, Sendable {
    public enum Layout: UInt32, Codable, Sendable, CaseIterable {
        /// Version `0x02000003`: the layout described in `docs/iTunesSD3gen.md`.
        case legacy = 0x0200_0003
        /// Version `0x02010001`: written by Apple's sync on macOS 27.
        case current = 0x0201_0001

        var playlistHeaderLength: Int { self == .current ? 68 : 20 }
    }

    /// Bytes whose meaning is unknown. They are zero in every database seen so far.
    public struct Reserved: Equatable, Sendable, Codable {
        public var header8: HexBytes?
        public var header2: UInt16
        public var header20: HexBytes?
        public var trackTable8: HexBytes?
        /// Bytes after the counted fields of the playlist table header (48 in the current layout, 2 in the legacy one).
        public var playlistHeaderTail: HexBytes?
        /// The legacy layout stores three 16-bit counts. Some writers put `0xFFFF` there instead of the real count.
        public var legacySentinelCounts: Bool

        public init(
            header8: HexBytes? = nil, header2: UInt16 = 0, header20: HexBytes? = nil,
            trackTable8: HexBytes? = nil, playlistHeaderTail: HexBytes? = nil, legacySentinelCounts: Bool = false
        ) {
            self.header8 = header8
            self.header2 = header2
            self.header20 = header20
            self.trackTable8 = trackTable8
            self.playlistHeaderTail = playlistHeaderTail
            self.legacySentinelCounts = legacySentinelCounts
        }

        public static let none = Reserved()
    }

    public var layout: Layout
    /// 0 means no limit; otherwise 0x03 (quietest) to 0x20 (loudest).
    public var maxVolume: UInt8
    /// Raw flag byte. Only track announcements depend on it; playlist names are spoken regardless.
    public var voiceOverFlag: UInt8
    public var reserved: Reserved
    public var tracks: [TrackRecord]
    public var playlists: [PlaylistRecord]

    public init(
        layout: Layout = .current, maxVolume: UInt8 = 0, voiceOverEnabled: Bool = true,
        reserved: Reserved = .none, tracks: [TrackRecord] = [], playlists: [PlaylistRecord] = []
    ) {
        self.layout = layout
        self.maxVolume = maxVolume
        self.voiceOverFlag = voiceOverEnabled ? 1 : 0
        self.reserved = reserved
        self.tracks = tracks
        self.playlists = playlists
    }

    public var voiceOverEnabled: Bool {
        get { voiceOverFlag != 0 }
        set { voiceOverFlag = newValue ? 1 : 0 }
    }
}

/// File type codes. The firmware picks its decoder from this value, not from the file contents.
public enum FileTypeCode {
    public static let mp3: UInt32 = 1
    /// MPEG-4 audio: AAC and Apple Lossless both use this code.
    public static let mpeg4: UInt32 = 2
    public static let wav: UInt32 = 4
}

/// One `rths` record: everything the iPod knows about a track.
public struct TrackRecord: Equatable, Sendable, Codable {
    public static let encodedLength = 372
    public static let pathFieldLength = 256

    /// Also the name of the track's VoiceOver recording (`Speakable/Tracks/<16 hex digits>.wav`).
    public var id: UInt64
    /// Path on the iPod with forward slashes and a leading slash, at most 256 UTF-8 bytes.
    public var path: String
    public var fileType: UInt32
    public var startMs: UInt32
    /// Where playback stops. Apple writes the track length; 0 also means "play to the end".
    public var stopMs: UInt32
    public var volumeGain: UInt32
    public var bookmarkMs: UInt32
    /// 1 for ordinary tracks. 0 makes the iPod leave the track out when choosing playlists in shuffle mode.
    public var dontSkipOnShuffle: UInt8
    public var rememberPosition: UInt8
    public var uninterruptibleAlbum: UInt8
    public var unknown1: UInt8
    public var pregap: UInt32
    public var postgap: UInt32
    public var sampleCount: UInt32
    public var unknown2: UInt32
    public var gaplessData: UInt32
    public var unknown3: UInt32
    public var albumID: UInt32
    public var trackNumber: UInt16
    public var discNumber: UInt16
    public var unknown4: HexBytes?
    public var artistID: UInt32
    public var unknown5: HexBytes?

    public init(
        id: UInt64, path: String, fileType: UInt32, startMs: UInt32 = 0, stopMs: UInt32 = 0, volumeGain: UInt32 = 0,
        bookmarkMs: UInt32 = 0, dontSkipOnShuffle: UInt8 = 1, rememberPosition: UInt8 = 0, uninterruptibleAlbum: UInt8 = 0,
        unknown1: UInt8 = 0, pregap: UInt32 = 0, postgap: UInt32 = 0, sampleCount: UInt32 = 0, unknown2: UInt32 = 0,
        gaplessData: UInt32 = 0, unknown3: UInt32 = 0, albumID: UInt32 = 0, trackNumber: UInt16 = 0, discNumber: UInt16 = 0,
        unknown4: HexBytes? = nil, artistID: UInt32 = 0, unknown5: HexBytes? = nil
    ) {
        self.id = id
        self.path = path
        self.fileType = fileType
        self.startMs = startMs
        self.stopMs = stopMs
        self.volumeGain = volumeGain
        self.bookmarkMs = bookmarkMs
        self.dontSkipOnShuffle = dontSkipOnShuffle
        self.rememberPosition = rememberPosition
        self.uninterruptibleAlbum = uninterruptibleAlbum
        self.unknown1 = unknown1
        self.pregap = pregap
        self.postgap = postgap
        self.sampleCount = sampleCount
        self.unknown2 = unknown2
        self.gaplessData = gaplessData
        self.unknown3 = unknown3
        self.albumID = albumID
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.unknown4 = unknown4
        self.artistID = artistID
        self.unknown5 = unknown5
    }
}

/// One `lphs` record.
public struct PlaylistRecord: Equatable, Sendable {
    public enum Kind {
        public static let master: UInt32 = 1
        public static let normal: UInt32 = 2
        public static let podcast: UInt32 = 3
        public static let audiobook: UInt32 = 4
    }

    /// Also the name of the playlist's VoiceOver recording. 0 makes the iPod say its built-in "All Songs".
    public var id: UInt64
    public var kind: UInt32
    /// Positions in the track table, in play order. A track may appear more than once.
    public var trackIndexes: [UInt32]
    /// Count of entries that are neither podcast nor audiobook. `nil` means "all of them".
    public var plainCount: UInt32?
    public var unknown: HexBytes?

    public init(id: UInt64, kind: UInt32, trackIndexes: [UInt32], plainCount: UInt32? = nil, unknown: HexBytes? = nil) {
        self.id = id
        self.kind = kind
        self.trackIndexes = trackIndexes
        self.plainCount = plainCount
        self.unknown = unknown
    }
}

public enum DatabaseError: ShuffleError, Equatable {
    case notShuffleDatabase
    case unsupportedVersion(UInt32)
    case malformed(String)
    case pathTooLong(String)

    public var description: String {
        switch self {
        case .notShuffleDatabase:
            return "this is not an iPod shuffle (3rd/4th generation) database"
        case let .unsupportedVersion(version):
            return String(format: "unknown database version 0x%08X", version)
        case let .malformed(reason):
            return "the database is damaged: \(reason)"
        case let .pathTooLong(path):
            return "the path is longer than 256 bytes: \(path)"
        }
    }
}

// MARK: - Decoding

extension ShuffleDatabase {
    public init(data: Data) throws {
        let reader = ByteReader(data)
        do {
            try self.init(reader: reader)
        } catch let error as BinaryError {
            throw DatabaseError.malformed(error.description)
        }
    }

    private init(reader: ByteReader) throws {
        guard reader.count >= 64, try reader.tag(0) == "bdhs" else { throw DatabaseError.notShuffleDatabase }
        let version = try reader.u32(4)
        guard let layout = Layout(rawValue: version) else { throw DatabaseError.unsupportedVersion(version) }
        guard try reader.u32(8) == 64 else { throw DatabaseError.malformed("unexpected header length") }

        let trackCount = Int(try reader.u32(12))
        let playlistCount = Int(try reader.u32(16))
        let trackTable = Int(try reader.u32(36))
        let playlistTable = Int(try reader.u32(40))

        var reserved = Reserved(
            header8: HexBytes(nonZero: try reader.slice(20, 8)),
            header2: try reader.u16(30),
            header20: HexBytes(nonZero: try reader.slice(44, 20))
        )

        // Track table.
        guard try reader.tag(trackTable) == "hths" else { throw DatabaseError.malformed("track table not found") }
        guard Int(try reader.u32(trackTable + 8)) == trackCount else {
            throw DatabaseError.malformed("track counts disagree")
        }
        reserved.trackTable8 = HexBytes(nonZero: try reader.slice(trackTable + 12, 8))
        var tracks: [TrackRecord] = []
        tracks.reserveCapacity(trackCount)
        for index in 0..<trackCount {
            let offset = Int(try reader.u32(trackTable + 20 + 4 * index))
            tracks.append(try TrackRecord(reader: reader, offset: offset))
        }

        // Playlist table.
        guard try reader.tag(playlistTable) == "hphs" else { throw DatabaseError.malformed("playlist table not found") }
        let tableLength = Int(try reader.u32(playlistTable + 4))
        guard Int(try reader.u32(playlistTable + 8)) == playlistCount else {
            throw DatabaseError.malformed("playlist counts disagree")
        }
        let fixedLength = layout.playlistHeaderLength
        guard tableLength == fixedLength + 4 * playlistCount else {
            throw DatabaseError.malformed("unexpected playlist table length \(tableLength)")
        }
        switch layout {
        case .current:
            let tail = try reader.slice(playlistTable + 20, 48)
            reserved.playlistHeaderTail = tail == ShuffleDatabase.defaultPlaylistHeaderTail ? nil : HexBytes(tail)
        case .legacy:
            reserved.legacySentinelCounts = try reader.u16(playlistTable + 12) == 0xFFFF
            reserved.playlistHeaderTail = HexBytes(nonZero: try reader.slice(playlistTable + 18, 2))
        }
        var playlists: [PlaylistRecord] = []
        playlists.reserveCapacity(playlistCount)
        for index in 0..<playlistCount {
            let offset = Int(try reader.u32(playlistTable + fixedLength + 4 * index))
            let playlist = try PlaylistRecord(reader: reader, offset: offset)
            if let bad = playlist.trackIndexes.first(where: { Int($0) >= trackCount }) {
                throw DatabaseError.malformed("playlist \(index) refers to track \(bad), but there are only \(trackCount)")
            }
            playlists.append(playlist)
        }

        self.layout = layout
        self.maxVolume = try reader.u8(28)
        self.voiceOverFlag = try reader.u8(29)
        self.reserved = reserved
        self.tracks = tracks
        self.playlists = playlists
    }
}

extension TrackRecord {
    fileprivate init(reader: ByteReader, offset: Int) throws {
        guard try reader.tag(offset) == "rths" else { throw DatabaseError.malformed("track record not found at \(offset)") }
        guard Int(try reader.u32(offset + 4)) == TrackRecord.encodedLength else {
            throw DatabaseError.malformed("unexpected track record length")
        }
        let field = try reader.slice(offset + 24, TrackRecord.pathFieldLength)
        let pathBytes = field.prefix { $0 != 0 }

        id = try reader.u64(offset + 328)
        path = String(decoding: pathBytes, as: UTF8.self)
        startMs = try reader.u32(offset + 8)
        stopMs = try reader.u32(offset + 12)
        volumeGain = try reader.u32(offset + 16)
        fileType = try reader.u32(offset + 20)
        bookmarkMs = try reader.u32(offset + 280)
        dontSkipOnShuffle = try reader.u8(offset + 284)
        rememberPosition = try reader.u8(offset + 285)
        uninterruptibleAlbum = try reader.u8(offset + 286)
        unknown1 = try reader.u8(offset + 287)
        pregap = try reader.u32(offset + 288)
        postgap = try reader.u32(offset + 292)
        sampleCount = try reader.u32(offset + 296)
        unknown2 = try reader.u32(offset + 300)
        gaplessData = try reader.u32(offset + 304)
        unknown3 = try reader.u32(offset + 308)
        albumID = try reader.u32(offset + 312)
        trackNumber = try reader.u16(offset + 316)
        discNumber = try reader.u16(offset + 318)
        unknown4 = HexBytes(nonZero: try reader.slice(offset + 320, 8))
        artistID = try reader.u32(offset + 336)
        unknown5 = HexBytes(nonZero: try reader.slice(offset + 340, 32))
    }
}

extension PlaylistRecord {
    fileprivate init(reader: ByteReader, offset: Int) throws {
        guard try reader.tag(offset) == "lphs" else { throw DatabaseError.malformed("playlist record not found at \(offset)") }
        // The entry count is authoritative: some writers store a record length that includes entries they dropped.
        let count = Int(try reader.u32(offset + 8))
        let plain = try reader.u32(offset + 12)
        id = try reader.u64(offset + 16)
        kind = try reader.u32(offset + 24)
        unknown = HexBytes(nonZero: try reader.slice(offset + 28, 16))
        var indexes: [UInt32] = []
        indexes.reserveCapacity(count)
        for position in 0..<count { indexes.append(try reader.u32(offset + 44 + 4 * position)) }
        trackIndexes = indexes
        plainCount = Int(plain) == count ? nil : plain
    }
}

// MARK: - Encoding

extension ShuffleDatabase {
    /// What Apple's sync writes after the ordinary-playlist pair when there are no podcasts,
    /// audiobooks, Genius mixes or iTunes U lists: four "none" pairs, then 16 zero bytes.
    static let defaultPlaylistHeaderTail: [UInt8] = {
        var out = ByteWriter()
        for _ in 0..<4 {
            out.u32(0xFFFF_FFFF)
            out.u32(0)
        }
        out.zeros(16)
        return out.bytes
    }()

    public func encoded() throws -> Data {
        let trackCount = tracks.count
        let playlistCount = playlists.count
        if let bad = playlists.flatMap(\.trackIndexes).first(where: { Int($0) >= trackCount }) {
            throw DatabaseError.malformed("a playlist refers to track \(bad), but there are only \(trackCount)")
        }

        let trackTable = 64
        let firstTrack = trackTable + 20 + 4 * trackCount
        let playlistTable = firstTrack + TrackRecord.encodedLength * trackCount
        let fixedLength = layout.playlistHeaderLength
        let playlistRecords = playlists.map { $0.encoded() }

        var out = ByteWriter()

        // bdhs
        out.tag("bdhs")
        out.u32(layout.rawValue)
        out.u32(64)
        out.u32(UInt32(trackCount))
        out.u32(UInt32(playlistCount))
        out.fixed(reserved.header8?.bytes ?? [], length: 8)
        out.u8(maxVolume)
        out.u8(voiceOverFlag)
        out.u16(reserved.header2)
        out.u32(UInt32(trackCount))  // tracks that are neither podcast nor audiobook
        out.u32(UInt32(trackTable))
        out.u32(UInt32(playlistTable))
        out.fixed(reserved.header20?.bytes ?? [], length: 20)

        // hths
        out.tag("hths")
        out.u32(UInt32(20 + 4 * trackCount))
        out.u32(UInt32(trackCount))
        out.fixed(reserved.trackTable8?.bytes ?? [], length: 8)
        for index in 0..<trackCount { out.u32(UInt32(firstTrack + TrackRecord.encodedLength * index)) }

        // rths
        for track in tracks { out.append(try track.encoded()) }

        // hphs
        out.tag("hphs")
        out.u32(UInt32(fixedLength + 4 * playlistCount))
        out.u32(UInt32(playlistCount))
        switch layout {
        case .current:
            // (index of the first ordinary playlist, how many there are), then the same pair for each special kind.
            let ordinary = playlists.indices.filter { playlists[$0].kind == PlaylistRecord.Kind.normal }
            out.u32(ordinary.first.map(UInt32.init) ?? 0xFFFF_FFFF)
            out.u32(UInt32(ordinary.count))
            if let tail = reserved.playlistHeaderTail?.bytes, tail.count == 48 {
                out.append(tail)
            } else {
                out.append(ShuffleDatabase.defaultPlaylistHeaderTail)
            }
        case .legacy:
            let count: UInt16 = reserved.legacySentinelCounts ? 0xFFFF : UInt16(truncatingIfNeeded: playlistCount)
            out.u16(count)  // playlists that are not podcasts
            out.u16(1)      // master playlists
            out.u16(count)  // playlists that are not audiobooks
            out.fixed(reserved.playlistHeaderTail?.bytes ?? [], length: 2)
        }
        var offset = playlistTable + fixedLength + 4 * playlistCount
        for record in playlistRecords {
            out.u32(UInt32(offset))
            offset += record.count
        }

        // lphs
        for record in playlistRecords { out.append(record) }

        return Data(out.bytes)
    }
}

extension TrackRecord {
    func encoded() throws -> [UInt8] {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= TrackRecord.pathFieldLength else { throw DatabaseError.pathTooLong(path) }

        var out = ByteWriter()
        out.tag("rths")
        out.u32(UInt32(TrackRecord.encodedLength))
        out.u32(startMs)
        out.u32(stopMs)
        out.u32(volumeGain)
        out.u32(fileType)
        out.fixed(pathBytes, length: TrackRecord.pathFieldLength)
        out.u32(bookmarkMs)
        out.u8(dontSkipOnShuffle)
        out.u8(rememberPosition)
        out.u8(uninterruptibleAlbum)
        out.u8(unknown1)
        out.u32(pregap)
        out.u32(postgap)
        out.u32(sampleCount)
        out.u32(unknown2)
        out.u32(gaplessData)
        out.u32(unknown3)
        out.u32(albumID)
        out.u16(trackNumber)
        out.u16(discNumber)
        out.fixed(unknown4?.bytes ?? [], length: 8)
        out.u64(id)
        out.u32(artistID)
        out.fixed(unknown5?.bytes ?? [], length: 32)
        precondition(out.count == TrackRecord.encodedLength)
        return out.bytes
    }
}

extension PlaylistRecord {
    func encoded() -> [UInt8] {
        var out = ByteWriter()
        out.tag("lphs")
        out.u32(UInt32(44 + 4 * trackIndexes.count))
        out.u32(UInt32(trackIndexes.count))
        out.u32(plainCount ?? UInt32(trackIndexes.count))
        out.u64(id)
        out.u32(kind)
        out.fixed(unknown?.bytes ?? [], length: 16)
        for index in trackIndexes { out.u32(index) }
        return out.bytes
    }
}
