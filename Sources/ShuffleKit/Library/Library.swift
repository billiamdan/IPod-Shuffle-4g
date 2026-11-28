// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// State of the spoken name (VoiceOver recording) of a track or playlist.
public struct Announcement: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// No recording on the iPod.
        case missing
        /// A recording made by other software (Apple's sync, the `ipod-shuffle-4g.py` script).
        /// Kept until the user asks otherwise.
        case inherited
        /// Recorded by this app from `text` with `voice`.
        case generated
    }

    public var state: State
    public var text: String?
    public var voice: String?
    /// Set when the user asks for a fresh recording regardless of what is there.
    public var rerecord: Bool

    public init(state: State = .missing, text: String? = nil, voice: String? = nil, rerecord: Bool = false) {
        self.state = state
        self.text = text
        self.voice = voice
        self.rerecord = rerecord
    }
}

public struct Track: Identifiable, Codable, Sendable, Equatable {
    /// The exact database record: file path, type code, playback options, gapless values.
    public var record: TrackRecord
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    /// "MP3", "AAC", "Apple Lossless", "WAV" or "MPEG-4 audio".
    public var kind: String
    public var durationMs: Int
    public var sizeBytes: Int64
    public var bitrateKbps: Int?
    public var sampleRate: Int?
    public var dateAdded: Date?
    public var playCount: Int
    public var skipCount: Int
    public var lastPlayed: Date?
    /// What VoiceOver should say instead of "title, artist".
    public var spokenName: String?
    /// Language to speak this track in (for example "ru-RU"), overriding detection.
    public var spokenLanguage: String?
    public var announcement: Announcement

    public var id: UInt64 { record.id }

    public init(
        record: TrackRecord, title: String, artist: String = "", album: String = "", genre: String = "", kind: String,
        durationMs: Int = 0, sizeBytes: Int64 = 0, bitrateKbps: Int? = nil, sampleRate: Int? = nil, dateAdded: Date? = nil,
        playCount: Int = 0, skipCount: Int = 0, lastPlayed: Date? = nil, spokenName: String? = nil,
        spokenLanguage: String? = nil, announcement: Announcement = Announcement()
    ) {
        self.record = record
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.kind = kind
        self.durationMs = durationMs
        self.sizeBytes = sizeBytes
        self.bitrateKbps = bitrateKbps
        self.sampleRate = sampleRate
        self.dateAdded = dateAdded
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayed = lastPlayed
        self.spokenName = spokenName
        self.spokenLanguage = spokenLanguage
        self.announcement = announcement
    }

    /// The iPod resumes this track where it was left (useful for long mixes and audiobooks).
    public var remembersPosition: Bool {
        get { record.rememberPosition != 0 }
        set { record.rememberPosition = newValue ? 1 : 0 }
    }

    /// The iPod leaves this track out when it shuffles.
    public var skipsWhenShuffling: Bool {
        get { record.dontSkipOnShuffle == 0 }
        set { record.dontSkipOnShuffle = newValue ? 0 : 1 }
    }
}

public struct Playlist: Identifiable, Codable, Sendable, Equatable {
    public var id: UInt64
    public var name: String
    /// In play order. A track may appear more than once.
    public var trackIDs: [UInt64]
    public var spokenName: String?
    public var spokenLanguage: String?
    public var announcement: Announcement

    public init(
        id: UInt64, name: String, trackIDs: [UInt64] = [], spokenName: String? = nil,
        spokenLanguage: String? = nil, announcement: Announcement = Announcement()
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.spokenName = spokenName
        self.spokenLanguage = spokenLanguage
        self.announcement = announcement
    }
}

/// Everything this app knows about one iPod. Saved on the iPod as `iPod_Control/Shuffler/library.json`,
/// because the play database itself has no room for titles or playlist names.
public struct Library: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    /// In database order. New tracks go at the end so existing positions never move.
    public var tracks: [Track]
    /// Play order of "All Songs".
    public var allSongsOrder: [UInt64]
    public var playlists: [Playlist]
    public var voiceOverEnabled: Bool
    public var maxVolume: UInt8
    public var layout: ShuffleDatabase.Layout
    public var reserved: ShuffleDatabase.Reserved
    /// 0 makes the iPod say its built-in "All Songs".
    public var masterPlaylistID: UInt64
    /// SHA-256 of the database this library describes. A mismatch means other software changed the iPod.
    public var databaseDigest: String?

    public init(
        tracks: [Track] = [], allSongsOrder: [UInt64] = [], playlists: [Playlist] = [], voiceOverEnabled: Bool = true,
        maxVolume: UInt8 = 0, layout: ShuffleDatabase.Layout = .current, reserved: ShuffleDatabase.Reserved = .none,
        masterPlaylistID: UInt64 = 0, databaseDigest: String? = nil
    ) {
        self.schema = Library.currentSchema
        self.tracks = tracks
        self.allSongsOrder = allSongsOrder
        self.playlists = playlists
        self.voiceOverEnabled = voiceOverEnabled
        self.maxVolume = maxVolume
        self.layout = layout
        self.reserved = reserved
        self.masterPlaylistID = masterPlaylistID
        self.databaseDigest = databaseDigest
    }
}

// MARK: - Queries and edits

extension Library {
    public func track(_ id: UInt64) -> Track? { tracks.first { $0.id == id } }

    public func playlist(_ id: UInt64) -> Playlist? { playlists.first { $0.id == id } }

    /// Tracks of a playlist in play order, or of "All Songs" when `playlistID` is `nil`.
    public func tracks(in playlistID: UInt64?) -> [Track] {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = playlistID.flatMap { playlist($0)?.trackIDs } ?? allSongsOrder
        return order.compactMap { byID[$0] }
    }

    public var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.sizeBytes } }
    public var totalDurationMs: Int { tracks.reduce(0) { $0 + $1.durationMs } }

    /// A random ID that no track or playlist uses. IDs double as VoiceOver file names.
    public func makeID() -> UInt64 {
        var taken = Set(tracks.map(\.id))
        taken.formUnion(playlists.map(\.id))
        taken.insert(masterPlaylistID)
        taken.insert(0)
        while true {
            let candidate = UInt64.random(in: 1...UInt64.max)
            if !taken.contains(candidate) { return candidate }
        }
    }

    public mutating func add(_ track: Track, toPlaylist playlistID: UInt64? = nil) {
        tracks.append(track)
        allSongsOrder.append(track.id)
        if let playlistID, let index = playlists.firstIndex(where: { $0.id == playlistID }) {
            playlists[index].trackIDs.append(track.id)
        }
    }

    public mutating func removeTracks(_ ids: Set<UInt64>) {
        tracks.removeAll { ids.contains($0.id) }
        allSongsOrder.removeAll { ids.contains($0) }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { ids.contains($0) } }
    }

    @discardableResult
    public mutating func addPlaylist(named name: String) -> Playlist {
        let playlist = Playlist(id: makeID(), name: name)
        playlists.append(playlist)
        return playlist
    }

    public mutating func update(trackID: UInt64, _ change: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        change(&tracks[index])
    }

    public mutating func update(playlistID: UInt64, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        change(&playlists[index])
    }

    /// Repairs references after edits: drops IDs of tracks that no longer exist and makes
    /// "All Songs" list every track exactly once.
    public mutating func normalize() {
        let known = Set(tracks.map(\.id))
        var seen = Set<UInt64>()
        allSongsOrder = allSongsOrder.filter { known.contains($0) && seen.insert($0).inserted }
        for track in tracks where !seen.contains(track.id) {
            allSongsOrder.append(track.id)
            seen.insert(track.id)
        }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { !known.contains($0) } }
    }
}

// MARK: - Database

extension Library {
    /// The database for this library. Playlists with no tracks are left out, as Apple's sync does.
    public func makeDatabase() throws -> ShuffleDatabase {
        var indexByID: [UInt64: UInt32] = [:]
        for (index, track) in tracks.enumerated() {
            guard indexByID.updateValue(UInt32(index), forKey: track.id) == nil else {
                throw DatabaseError.malformed("two tracks share the ID \(track.id.hexID)")
            }
        }
        var records = [PlaylistRecord(
            id: masterPlaylistID, kind: PlaylistRecord.Kind.master,
            trackIndexes: allSongsOrder.compactMap { indexByID[$0] }
        )]
        for playlist in playlists {
            let indexes = playlist.trackIDs.compactMap { indexByID[$0] }
            if !indexes.isEmpty {
                records.append(PlaylistRecord(id: playlist.id, kind: PlaylistRecord.Kind.normal, trackIndexes: indexes))
            }
        }
        return ShuffleDatabase(
            layout: layout, maxVolume: maxVolume, voiceOverEnabled: voiceOverEnabled,
            reserved: reserved, tracks: tracks.map(\.record), playlists: records
        )
    }
}
