import Foundation

/// Descriptive facts about an audio file, read from its tags.
public struct ProbedTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var kind: String?
    public var durationMs: Int?
    public var bitrateKbps: Int?
    public var sampleRate: Int?

    public init(
        title: String? = nil, artist: String? = nil, album: String? = nil, genre: String? = nil,
        kind: String? = nil, durationMs: Int? = nil, bitrateKbps: Int? = nil, sampleRate: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.kind = kind
        self.durationMs = durationMs
        self.bitrateKbps = bitrateKbps
        self.sampleRate = sampleRate
    }
}

public typealias TagReader = @Sendable (URL) async -> ProbedTags?

/// Builds a `Library` from what is on the iPod. Used the first time this app sees a device,
/// and again whenever other software (Apple's sync, the `ipod-shuffle-4g.py` script) has changed it since.
public enum DeviceImporter {
    /// - Parameters:
    ///   - previous: what this app knew before, if anything. Titles and settings of tracks that are
    ///     still at the same path are carried over.
    ///   - tagReader: asked for titles of tracks nothing else can name.
    public static func importLibrary(
        from device: ShuffleDevice, previous: Library? = nil, tagReader: TagReader? = nil
    ) async throws -> Library {
        guard device.hasDatabase else { return Library() }

        let data = try Data(contentsOf: device.databaseURL)
        let database = try ShuffleDatabase(data: data)
        let apple = (try? Data(contentsOf: device.appleLibraryURL)).map(AppleLibrary.init(data:))
        let known = Dictionary((previous?.tracks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var library = Library(
            voiceOverEnabled: database.voiceOverEnabled, maxVolume: database.maxVolume, layout: database.layout,
            reserved: database.reserved, databaseDigest: FileOps.sha256(data)
        )

        // Tracks. IDs must be unique because they name VoiceOver files and identify rows;
        // `ipod-shuffle-4g.py` derived them from the title, so two tracks could share one.
        var taken: Set<UInt64> = [0]
        for record in database.tracks {
            var record = record
            let originalID = record.id
            let isDuplicate = !taken.insert(originalID).inserted
            if isDuplicate {
                record.id = unusedID(&taken)
            }
            let url = device.fileURL(devicePath: record.path)
            let size = FileOps.fileSize(url) ?? 0

            if !isDuplicate, var old = known[originalID], old.record.path == record.path {
                old.record = record
                old.sizeBytes = size
                library.tracks.append(old)
                continue
            }

            var track = Track(
                record: record, title: "", kind: defaultKind(for: record),
                durationMs: Int(record.stopMs), sizeBytes: size
            )
            if let info = apple?.tracks[originalID] {
                track.title = info.title
                track.artist = info.artist
                track.album = info.album
                track.genre = info.genre
                track.playCount = info.playCount
                track.skipCount = info.skipCount
                track.lastPlayed = info.lastPlayed
                track.dateAdded = info.dateAdded
                if track.durationMs == 0 { track.durationMs = info.durationMs }
            }
            if track.title.isEmpty || track.durationMs == 0, let tags = await tagReader?(url) {
                if track.title.isEmpty {
                    track.title = tags.title ?? ""
                    track.artist = tags.artist ?? track.artist
                    track.album = tags.album ?? track.album
                    track.genre = tags.genre ?? track.genre
                }
                if track.durationMs == 0 { track.durationMs = tags.durationMs ?? 0 }
                track.kind = tags.kind ?? track.kind
                track.bitrateKbps = tags.bitrateKbps
                track.sampleRate = tags.sampleRate
            }
            if track.title.isEmpty {
                track.title = url.deletingPathExtension().lastPathComponent
            }
            let hasRecording = !isDuplicate && FileOps.exists(device.trackAnnouncementURL(id: originalID))
            track.announcement = Announcement(state: hasRecording ? .inherited : .missing)
            library.tracks.append(track)
        }

        // Playlists. Positions in the database become track IDs.
        let ids = library.tracks.map(\.id)
        let oldPlaylists = Dictionary((previous?.playlists ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordinal = 0
        var sawSpecialKind = false
        for record in database.playlists {
            let members = record.trackIndexes.map { ids[Int($0)] }
            if record.kind == PlaylistRecord.Kind.master {
                library.masterPlaylistID = record.id
                library.allSongsOrder = members
                continue
            }
            ordinal += 1
            sawSpecialKind = sawSpecialKind || record.kind != PlaylistRecord.Kind.normal
            var id = record.id
            if !taken.insert(id).inserted { id = unusedID(&taken) }

            var playlist = oldPlaylists[record.id] ?? Playlist(id: id, name: "")
            playlist.id = id
            playlist.trackIDs = members
            if playlist.name.isEmpty {
                playlist.name = apple?.playlistNames[record.id] ?? defaultName(kind: record.kind, ordinal: ordinal)
            }
            if oldPlaylists[record.id] == nil {
                let hasRecording = id == record.id && FileOps.exists(device.playlistAnnouncementURL(id: id))
                playlist.announcement = Announcement(state: hasRecording ? .inherited : .missing)
            }
            library.playlists.append(playlist)
        }
        // Empty playlists are not stored in the database, so they survive only in the manifest.
        for old in previous?.playlists ?? [] where old.trackIDs.isEmpty && !library.playlists.contains(where: { $0.id == old.id }) {
            library.playlists.append(old)
        }
        if sawSpecialKind {
            // Podcast and audiobook lists become ordinary playlists; the header bytes that described them no longer apply.
            library.reserved.playlistHeaderTail = nil
        }
        library.normalize()
        return library
    }

    private static func unusedID(_ taken: inout Set<UInt64>) -> UInt64 {
        while true {
            let candidate = UInt64.random(in: 1...UInt64.max)
            if taken.insert(candidate).inserted { return candidate }
        }
    }

    private static func defaultKind(for record: TrackRecord) -> String {
        switch record.fileType {
        case FileTypeCode.mp3: return "MP3"
        case FileTypeCode.mpeg4: return "MPEG-4 audio"
        case FileTypeCode.wav: return "WAV"
        default: return "Audio"
        }
    }

    private static func defaultName(kind: UInt32, ordinal: Int) -> String {
        switch kind {
        case PlaylistRecord.Kind.podcast: return "Podcasts"
        case PlaylistRecord.Kind.audiobook: return "Audiobooks"
        default: return "Playlist \(ordinal)"
        }
    }
}
