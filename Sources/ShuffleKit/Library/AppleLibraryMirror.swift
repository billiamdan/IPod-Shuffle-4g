import Foundation

/// What the iPod recorded for one track since the last sync. Apple's library file keeps running
/// totals, so these are added to what it already holds.
struct PlayActivity: Sendable, Equatable {
    var plays: UInt32 = 0
    var skips: UInt32 = 0
    /// On the iPod's clock (seconds since 1904, local time), which is also how Apple's file stores dates.
    var lastPlayed: UInt32 = 0
    var lastSkipped: UInt32 = 0
}

/// What bringing Apple's library file in step involved, counted in songs and playlists.
public struct AppleLibraryChanges: Sendable, Equatable {
    public var tracksAdded = 0
    public var tracksRemoved = 0
    public var tracksUpdated = 0
    public var playlistsAdded = 0
    public var playlistsRemoved = 0
    public var playlistsUpdated = 0

    public init() {}

    public var isEmpty: Bool { self == AppleLibraryChanges() }

    /// What was done, for example "3 songs removed, 1 playlist added".
    public var summary: String { describe(["removed", "added", "updated"]) ?? "details updated" }

    /// The same as work still to do, for example "3 songs to remove, 1 playlist to add".
    public var pendingSummary: String { describe(["to remove", "to add", "to update"]) ?? "details to update" }

    private func describe(_ verbs: [String]) -> String? {
        func count(_ number: Int, _ noun: String, _ verb: String) -> String? {
            number == 0 ? nil : "\(number) \(noun)\(number == 1 ? "" : "s") \(verb)"
        }
        let parts = [
            count(tracksRemoved, "song", verbs[0]), count(tracksAdded, "song", verbs[1]), count(tracksUpdated, "song", verbs[2]),
            count(playlistsRemoved, "playlist", verbs[0]), count(playlistsAdded, "playlist", verbs[1]),
            count(playlistsUpdated, "playlist", verbs[2]),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Brings Apple's library file in step with a `Library`.
///
/// Finder lists the iPod's songs from that file, not from the play database, so a song removed here
/// stays listed there (and one added here never appears) unless the file follows along.
///
/// The edit is as small as it can be: records of songs that are gone are taken out together with
/// every playlist item that points at them, songs and playlists made here get records shaped like
/// the ones Apple wrote next to them, and names follow renames. Everything else is left byte for
/// byte as it was, which includes whatever this app does not know about: an empty playlist that
/// never reached the play database, the built-in smart lists, the podcast list.
enum AppleLibraryMirror {
    /// - Parameters:
    ///   - removedPlaylists: playlists the user deleted. A playlist that is merely unknown here is kept.
    ///   - activity: plays and skips to add to the totals of tracks that already have a record.
    /// - Returns: the file's new contents. They equal `data` when it was already in step.
    static func mirror(
        _ data: Data, to library: Library, removedPlaylists: Set<UInt64> = [],
        activity: [UInt64: PlayActivity] = [:], now: Date = Date()
    ) throws -> (data: Data, changes: AppleLibraryChanges) {
        var editor = try Editor(data: data, now: now)
        try editor.mirror(library, removedPlaylists: removedPlaylists, activity: activity)
        let result = editor.file.encoded()
        // What is about to be written must itself be a file this app can read back.
        _ = try AppleLibraryFile(data: result)
        return (result, editor.changes)
    }
}

private typealias Record = AppleLibraryFile.Record

/// Offsets of the header fields this app reads or writes. Names follow libgpod where it has one.
private enum Field {
    enum File {
        /// Seconds east of Greenwich of the Mac that wrote the file; its dates are on that clock.
        static let timeZoneOffset = 108
    }

    enum Track {
        static let number = 16              // what playlist items point at
        static let visible = 20
        static let fileTypeMarker = 24      // "MP3 ", "M4A ", "WAV " as a big-endian four-character code
        static let variableBitrate = 28
        static let isMP3 = 29
        static let modified = 32
        static let size = 36
        static let duration = 40
        static let trackNumber = 44
        static let bitrate = 56
        static let sampleRate = 60          // in the upper 16 bits
        static let playCount = 80
        static let playCount2 = 84          // a second count Apple keeps at or just below the first; set once, never raised here
        static let lastPlayed = 88
        static let discNumber = 92
        static let added = 104
        static let id = 112                 // the 64-bit ID the play database uses too
        static let compressionFlag = 126    // 0xFFFF for MP3 and AAC, 0 for uncompressed audio
        static let sampleRateFloat = 136
        static let formatFlag = 144         // 0x0C MP3, 0x33 AAC, 0x46 WAV in files Apple writes today
        static let skipCount = 156
        static let lastSkipped = 160
        static let artworkFlag = 164        // 2 = none
        static let skipWhenShuffling = 165
        static let rememberPosition = 166
        static let playedMark = 178         // 1 = played, 2 = not played yet
        static let pregap = 184
        static let sampleCount = 188
        static let postgap = 200
        static let hasSampleCount = 204
        static let mediaType = 208          // 1 = music
        static let gaplessTrack = 256
        static let album = 288              // number of the album record
        static let sizeAgain = 300
        static let filler = 308             // always 0x808080808080
        static let alwaysOne = 360
        static let artistNumber = 480       // a number of its own per track; the play database repeats it as the artist number
        static let secondNumber = 500       // another number of its own per track (libgpod: composer)
    }

    enum Album {
        static let number = 16
        static let persistentID = 20
        static let kind = 28
    }

    enum Playlist {
        static let isMaster = 20
        static let created = 24
        static let id = 28
        static let stringCount = 40
        static let isPodcastList = 42
        static let sortOrder = 44           // 1 = the order of the items, 5 = by artist (Apple's default)
    }

    enum Item {
        static let groupFlag = 16           // non-zero for a heading in the podcast list, which points at no track
        static let number = 20
        static let track = 24
        static let added = 28
        static let trackID = 44
        static let persistentID = 60
    }
}

/// String types (`mhod`), in the order Apple writes them after a track.
private enum Text {
    static let title: UInt32 = 1
    static let location: UInt32 = 2
    static let album: UInt32 = 3
    static let artist: UInt32 = 4
    static let genre: UInt32 = 5
    static let kind: UInt32 = 6
    static let comment: UInt32 = 8
    static let composer: UInt32 = 12
    static let trackOrder: [UInt32] = [title, artist, album, composer, genre, kind, comment, location]

    static let albumName: UInt32 = 200
    static let albumArtist: UInt32 = 201
    static let albumOrder: [UInt32] = [albumName, albumArtist]

    /// Not text: where an item sits in its playlist, and the playlist's view settings.
    static let position: UInt32 = 100
    static let settings: UInt32 = 102
    static let smartRules: Set<UInt32> = [50, 51]
}

private struct Editor {
    var file: AppleLibraryFile
    var changes = AppleLibraryChanges()

    private let now: UInt32
    private let zoneOffset: Int
    private var nextNumber: UInt32
    /// Header length of the playlist items already in the file; new ones are made the same size.
    private let itemHeaderLength: Int
    /// For each track number: what a playlist item repeats from the track.
    private var trackFacts: [UInt32: (id: UInt64, added: UInt32)] = [:]

    private var addedPlaylists = Set<UInt64>()
    private var removedPlaylists = Set<UInt64>()
    private var updatedPlaylists = Set<UInt64>()

    init(data: Data, now: Date) throws {
        file = try AppleLibraryFile(data: data)

        let stored = Int(Int32(bitPattern: file.root.u32(Field.File.timeZoneOffset)))
        let plausible = file.root.header.count >= Field.File.timeZoneOffset + 4 && abs(stored) <= 14 * 3600
        zoneOffset = plausible ? stored : TimeZone.current.secondsFromGMT(for: now)
        self.now = Editor.deviceTime(now, zoneOffset: zoneOffset)

        // Albums, tracks and playlist items are numbered from one counter. New records continue after the highest.
        var highest: UInt32 = 0
        var itemLength: Int?
        func scan(_ record: Record) {
            switch record.tag {
            case "mhia":
                highest = max(highest, record.u32(Field.Album.number))
            case "mhit":
                highest = max(highest, record.u32(Field.Track.number), record.u32(Field.Track.artistNumber), record.u32(Field.Track.secondNumber))
            case "mhip":
                highest = max(highest, record.u32(Field.Item.number))
                if itemLength == nil { itemLength = record.header.count }
            default:
                break
            }
            record.children.forEach(scan)
        }
        scan(file.root)
        guard highest < 0xFFF0_0000 else { throw AppleLibraryError.unsupported("its record numbers are used up") }
        nextNumber = highest + 1
        itemHeaderLength = itemLength ?? 76
    }

    private static func deviceTime(_ date: Date, zoneOffset: Int) -> UInt32 {
        UInt32(clamping: Int(date.timeIntervalSince1970.rounded(.down)) + 2_082_844_800 + zoneOffset)
    }

    private func deviceTime(_ date: Date?) -> UInt32 {
        date.map { Editor.deviceTime($0, zoneOffset: zoneOffset) } ?? 0
    }

    private mutating func newNumber() -> UInt32 {
        defer { nextNumber += 1 }
        return nextNumber
    }

    // MARK: Sections

    private func sectionIndexes(holding listTag: String, kinds: Set<UInt32>? = nil) -> [Int] {
        file.root.children.indices.filter { index in
            let section = file.root.children[index]
            return section.children[0].tag == listTag && (kinds?.contains(section.kind) ?? true)
        }
    }

    private func records(inSection index: Int) -> [Record] { file.root.children[index].children[0].children }

    private mutating func setRecords(_ records: [Record], inSection index: Int) {
        file.root.children[index].children[0].children = records
    }

    // MARK: Everything

    mutating func mirror(_ library: Library, removedPlaylists removed: Set<UInt64>, activity: [UInt64: PlayActivity]) throws {
        guard let trackSection = sectionIndexes(holding: "mhlt", kinds: [1]).first else {
            throw AppleLibraryError.unsupported("it has no track list")
        }
        let trackNumbers = mirrorTracks(library, inSection: trackSection, activity: activity)

        // Sections 2 and 3 hold the same playlists; Apple writes them as identical copies unless there
        // are podcasts. Where they start out identical they are kept identical.
        let managed = sectionIndexes(holding: "mhlp", kinds: [2, 3])
        var finished: [(before: [Record], after: [Record])] = []
        for section in managed {
            let before = records(inSection: section)
            if let same = finished.first(where: { $0.before == before }) {
                setRecords(same.after, inSection: section)
                continue
            }
            let after = mirrorPlaylists(before, library: library, removed: removed, trackNumbers: trackNumbers)
            finished.append((before, after))
            setRecords(after, inSection: section)
        }
        // Anywhere else (the built-in smart lists) only references to tracks that are gone are dropped.
        for section in sectionIndexes(holding: "mhlp") where !managed.contains(section) {
            setRecords(records(inSection: section).map { list in
                var list = list
                if dropDeadItems(&list) { updatedPlaylists.insert(list.u64(Field.Playlist.id)) }
                return list
            }, inSection: section)
        }

        changes.playlistsAdded = addedPlaylists.count
        changes.playlistsRemoved = removedPlaylists.count
        changes.playlistsUpdated = updatedPlaylists.subtracting(addedPlaylists).count
    }

    // MARK: Tracks

    /// Makes the track list hold exactly the library's tracks. Returns each track's number in the file.
    private mutating func mirrorTracks(_ library: Library, inSection section: Int, activity: [UInt64: PlayActivity]) -> [UInt64: UInt32] {
        let existing = records(inSection: section)
        let headerLength = existing.first?.header.count ?? 624
        let wanted = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var numbers: [UInt64: UInt32] = [:]
        var kept: [Record] = []
        /// Positions in `kept` of tracks whose album record has to be looked up (new, or renamed).
        var needAlbum: [Int] = []
        /// Albums that lost a track and may now be unused.
        var releasedAlbums = Set<UInt32>()

        for var record in existing {
            let id = record.u64(Field.Track.id)
            guard let track = wanted[id], numbers[id] == nil else {
                releasedAlbums.insert(record.u32(Field.Track.album))
                changes.tracksRemoved += 1
                continue
            }
            let (changed, regrouped) = update(&record, to: track, activity: activity[id])
            if changed { changes.tracksUpdated += 1 }
            if regrouped {
                releasedAlbums.insert(record.u32(Field.Track.album))
                needAlbum.append(kept.count)
            }
            numbers[id] = record.u32(Field.Track.number)
            kept.append(record)
        }
        for track in library.tracks where numbers[track.id] == nil {
            let number = newNumber()
            needAlbum.append(kept.count)
            kept.append(makeTrack(track, number: number, headerLength: headerLength))
            numbers[track.id] = number
            changes.tracksAdded += 1
        }

        if let albumSection = sectionIndexes(holding: "mhla").first {
            var albums = records(inSection: albumSection)
            for index in needAlbum {
                guard let track = wanted[kept[index].u64(Field.Track.id)] else { continue }
                kept[index].set32(albumNumber(album: track.album, artist: track.artist, in: &albums), at: Field.Track.album)
            }
            let used = Set(kept.map { $0.u32(Field.Track.album) })
            albums.removeAll { album in
                let number = album.u32(Field.Album.number)
                return releasedAlbums.contains(number) && !used.contains(number)
            }
            setRecords(albums, inSection: albumSection)
        }

        for record in kept {
            trackFacts[record.u32(Field.Track.number)] = (record.u64(Field.Track.id), record.u32(Field.Track.added))
        }
        setRecords(kept, inSection: section)
        return numbers
    }

    /// Carries renames, playback options and new plays over to a record that already exists.
    /// Only what can be changed in this app is carried over; the genre, the comment and the like
    /// stay as Apple wrote them.
    private func update(_ record: inout Record, to track: Track, activity: PlayActivity?) -> (changed: Bool, regrouped: Bool) {
        var changed = false
        var regrouped = false
        if !track.title.isEmpty, record.setString(Text.title, track.title, order: Text.trackOrder) { changed = true }
        if record.setString(Text.artist, track.artist, order: Text.trackOrder) { (changed, regrouped) = (true, true) }
        if record.setString(Text.album, track.album, order: Text.trackOrder) { (changed, regrouped) = (true, true) }

        if record.set8(track.skipsWhenShuffling ? 1 : 0, at: Field.Track.skipWhenShuffling) { changed = true }
        if record.set8(track.remembersPosition ? 1 : 0, at: Field.Track.rememberPosition) { changed = true }

        if let activity {
            if activity.plays > 0 {
                let total = record.u32(Field.Track.playCount).addingReportingOverflow(activity.plays)
                record.set32(total.overflow ? .max : total.partialValue, at: Field.Track.playCount)
                record.set8(1, at: Field.Track.playedMark)
                changed = true
            }
            if activity.lastPlayed > record.u32(Field.Track.lastPlayed) {
                record.set32(activity.lastPlayed, at: Field.Track.lastPlayed)
                changed = true
            }
            if activity.skips > 0 {
                let total = record.u32(Field.Track.skipCount).addingReportingOverflow(activity.skips)
                record.set32(total.overflow ? .max : total.partialValue, at: Field.Track.skipCount)
                changed = true
            }
            if activity.lastSkipped > record.u32(Field.Track.lastSkipped) {
                record.set32(activity.lastSkipped, at: Field.Track.lastSkipped)
                changed = true
            }
        }
        return (changed, regrouped)
    }

    /// A record for a track this app put on the iPod, filled in the way Apple's sync fills one today.
    private mutating func makeTrack(_ track: Track, number: UInt32, headerLength: Int) -> Record {
        let isMP3 = track.record.fileType == FileTypeCode.mp3
        let isWAV = track.record.fileType == FileTypeCode.wav
        let marker: UInt32 = isMP3 ? 0x4D50_3320 : isWAV ? 0x5741_5620 : 0x4D34_4120   // "MP3 ", "WAV ", "M4A "
        let size = UInt32(clamping: track.sizeBytes)
        let duration = UInt32(clamping: track.durationMs)
        let added = track.dateAdded.map { deviceTime($0) } ?? now
        let sampleRate = UInt32(clamping: track.sampleRate ?? 44_100)
        let bitrate = track.bitrateKbps ?? (track.durationMs > 0 ? Int(track.sizeBytes * 8 / Int64(track.durationMs)) : 0)
        let plays = UInt32(clamping: track.playCount)

        var record = Record(tag: "mhit", headerLength: headerLength)
        record.set32(number, at: Field.Track.number)
        record.set32(1, at: Field.Track.visible)
        record.set32(marker, at: Field.Track.fileTypeMarker)
        record.set8(isMP3 ? 1 : 0, at: Field.Track.isMP3)
        record.set32(added, at: Field.Track.modified)
        record.set32(size, at: Field.Track.size)
        record.set32(duration, at: Field.Track.duration)
        record.set32(UInt32(track.record.trackNumber), at: Field.Track.trackNumber)
        record.set32(UInt32(clamping: bitrate), at: Field.Track.bitrate)
        record.set32(sampleRate << 16, at: Field.Track.sampleRate)
        record.set32(plays, at: Field.Track.playCount)
        record.set32(plays, at: Field.Track.playCount2)
        record.set32(deviceTime(track.lastPlayed), at: Field.Track.lastPlayed)
        record.set32(UInt32(track.record.discNumber), at: Field.Track.discNumber)
        record.set32(added, at: Field.Track.added)
        record.set64(track.id, at: Field.Track.id)
        record.set16(isWAV ? 0 : 0xFFFF, at: Field.Track.compressionFlag)
        record.set32(Float(sampleRate).bitPattern, at: Field.Track.sampleRateFloat)
        record.set16(isMP3 ? 0x0C : isWAV ? 0x46 : 0x33, at: Field.Track.formatFlag)
        record.set32(UInt32(clamping: track.skipCount), at: Field.Track.skipCount)
        record.set8(2, at: Field.Track.artworkFlag)
        record.set8(track.skipsWhenShuffling ? 1 : 0, at: Field.Track.skipWhenShuffling)
        record.set8(track.remembersPosition ? 1 : 0, at: Field.Track.rememberPosition)
        record.set8(plays > 0 ? 1 : 2, at: Field.Track.playedMark)
        record.set32(track.record.pregap, at: Field.Track.pregap)
        record.set64(UInt64(track.record.sampleCount), at: Field.Track.sampleCount)
        record.set32(track.record.postgap, at: Field.Track.postgap)
        record.set32(track.record.sampleCount == 0 ? 0 : 1, at: Field.Track.hasSampleCount)
        record.set32(1, at: Field.Track.mediaType)
        record.set16(1, at: Field.Track.gaplessTrack)
        record.set32(size, at: Field.Track.sizeAgain)
        record.set64(0x8080_8080_8080, at: Field.Track.filler)
        record.set32(1, at: Field.Track.alwaysOne)
        record.set32(newNumber(), at: Field.Track.artistNumber)
        record.set32(newNumber(), at: Field.Track.secondNumber)

        let kind: String
        if isMP3 {
            kind = "MPEG audio file"
        } else if isWAV {
            kind = "WAV audio file"
        } else {
            kind = track.kind == "Apple Lossless" ? "Apple Lossless audio file" : "AAC audio file"
        }
        let strings: [(UInt32, String)] = [
            (Text.title, track.title), (Text.artist, track.artist), (Text.album, track.album), (Text.genre, track.genre),
            (Text.kind, kind), (Text.location, track.record.path.replacingOccurrences(of: "/", with: ":")),
        ]
        record.children = strings.filter { !$0.1.isEmpty }.map { Record.string($0.0, $0.1) }
        return record
    }

    /// The number of the album record for this album and artist, adding the record if there is none.
    /// Tracks with neither share one nameless album, as in files Apple writes.
    private mutating func albumNumber(album: String, artist: String, in albums: inout [Record]) -> UInt32 {
        if let match = albums.first(where: { ($0.string(Text.albumName) ?? "") == album && ($0.string(Text.albumArtist) ?? "") == artist }) {
            return match.u32(Field.Album.number)
        }
        var record = Record(tag: "mhia", headerLength: albums.first?.header.count ?? 88)
        let number = newNumber()
        record.set32(number, at: Field.Album.number)
        record.set64(UInt64.random(in: 1...UInt64.max), at: Field.Album.persistentID)
        record.set32(albums.first?.u32(Field.Album.kind) ?? 2, at: Field.Album.kind)
        record.setString(Text.albumName, album, order: Text.albumOrder)
        record.setString(Text.albumArtist, artist, order: Text.albumOrder)
        albums.append(record)
        return number
    }

    // MARK: Playlists

    private func isSmart(_ list: Record) -> Bool {
        list.children.contains { $0.tag == "mhod" && Text.smartRules.contains($0.kind) }
    }

    /// An item that points at a track, as opposed to a heading in the podcast list.
    private func pointsAtTrack(_ item: Record) -> Bool {
        item.tag == "mhip" && item.u32(Field.Item.groupFlag) == 0
    }

    /// Takes out items whose track has no record any more. Returns whether there were any.
    private func dropDeadItems(_ list: inout Record) -> Bool {
        let before = list.children.count
        list.children.removeAll { pointsAtTrack($0) && trackFacts[$0.u32(Field.Item.track)] == nil }
        return list.children.count != before
    }

    private mutating func mirrorPlaylists(
        _ lists: [Record], library: Library, removed: Set<UInt64>, trackNumbers: [UInt64: UInt32]
    ) -> [Record] {
        let playlists = Dictionary(library.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Record] = []
        var present = Set<UInt64>()
        var sawMaster = false

        for var list in lists {
            let id = list.u64(Field.Playlist.id)
            let isMaster = list.u8(Field.Playlist.isMaster) != 0 && !sawMaster
            // Smart lists fill themselves, and the podcast list has headings this app does not arrange.
            let editable = !isSmart(list) && list.u16(Field.Playlist.isPodcastList) == 0
            var changed = dropDeadItems(&list)

            if isMaster {
                sawMaster = true
                if editable, setItems(of: &list, to: library.allSongsOrder.compactMap { trackNumbers[$0] }) { changed = true }
            } else if editable, let playlist = playlists[id] {
                if !playlist.name.isEmpty, list.setString(Text.title, playlist.name, order: [Text.title]) { changed = true }
                if setItems(of: &list, to: playlist.trackIDs.compactMap { trackNumbers[$0] }) { changed = true }
            } else if editable, removed.contains(id) {
                removedPlaylists.insert(id)
                continue
            }
            if changed { updatedPlaylists.insert(id) }
            present.insert(id)
            result.append(list)
        }

        for playlist in library.playlists where !present.contains(playlist.id) {
            result.append(makePlaylist(playlist, like: lists, trackNumbers: trackNumbers))
            present.insert(playlist.id)
            addedPlaylists.insert(playlist.id)
        }
        return result
    }

    /// Makes a playlist hold the wanted tracks, each as often as wanted, changing as little as possible:
    /// items that are still wanted stay where they are, surplus ones go, missing ones are added at the end.
    /// The order Apple gave the existing items is not touched.
    private mutating func setItems(of list: inout Record, to wanted: [UInt32]) -> Bool {
        var missing: [UInt32: Int] = [:]
        for number in wanted { missing[number, default: 0] += 1 }

        var items: [Record] = []
        var changed = false
        var nextPosition: UInt32 = 0
        for item in list.children where item.tag == "mhip" {
            if pointsAtTrack(item) {
                let number = item.u32(Field.Item.track)
                guard let left = missing[number], left > 0 else {
                    changed = true
                    continue
                }
                missing[number] = left - 1
                if let position = position(of: item) { nextPosition = max(nextPosition, position &+ 1) }
            }
            items.append(item)
        }
        for number in wanted {
            guard let left = missing[number], left > 0 else { continue }
            missing[number] = left - 1
            items.append(makeItem(track: number, position: nextPosition))
            nextPosition &+= 1
            changed = true
        }
        if changed { list.children = list.children.filter { $0.tag == "mhod" } + items }
        return changed
    }

    private func position(of item: Record) -> UInt32? {
        guard let data = item.children.first(where: { $0.kind == Text.position })?.body, data.count >= 4 else { return nil }
        return UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    }

    private mutating func makeItem(track number: UInt32, position: UInt32) -> Record {
        var out = ByteWriter()
        out.u32(position)
        out.zeros(16)
        var place = Record(tag: "mhod", headerLength: 24, body: out.bytes)
        place.set32(Text.position, at: 12)

        let facts = trackFacts[number]
        var item = Record(tag: "mhip", headerLength: itemHeaderLength, children: [place])
        item.set32(newNumber(), at: Field.Item.number)
        item.set32(number, at: Field.Item.track)
        item.set32(facts?.added ?? now, at: Field.Item.added)
        item.set64(facts?.id ?? 0, at: Field.Item.trackID)
        item.set64(UInt64.random(in: 1...UInt64.max), at: Field.Item.persistentID)
        return item
    }

    /// A playlist made in this app. Its view settings are copied from a playlist Apple wrote, when there is one.
    private mutating func makePlaylist(_ playlist: Playlist, like siblings: [Record], trackNumbers: [UInt64: UInt32]) -> Record {
        var record = Record(tag: "mhyp", headerLength: siblings.first?.header.count ?? 184)
        record.set32(now, at: Field.Playlist.created)
        record.set64(playlist.id, at: Field.Playlist.id)
        record.set16(1, at: Field.Playlist.stringCount)
        // The items are in play order, and say so; Apple's own playlists are marked "by artist".
        record.set32(1, at: Field.Playlist.sortOrder)

        record.setString(Text.title, playlist.name, order: [Text.title])
        if siblings.isEmpty {
            record.children += [Editor.defaultView, Editor.defaultSettings]
        } else {
            let model = siblings.first { $0.u8(Field.Playlist.isMaster) == 0 && !isSmart($0) } ?? siblings[0]
            record.children += model.children.filter { $0.tag == "mhod" && [Text.position, Text.settings].contains($0.kind) }
        }
        _ = setItems(of: &record, to: playlist.trackIDs.compactMap { trackNumbers[$0] })
        return record
    }

    /// The two settings items Apple's sync puts in every playlist (macOS 27: identical in all of them).
    /// They describe how a list is displayed; only used when the file has no playlist to copy them from.
    private static let defaultView: Record = {
        var body = [UInt8](repeating: 0, count: 624)
        body[18] = 1
        body[20] = 5
        var record = Record(tag: "mhod", headerLength: 24, body: body)
        record.set32(Text.position, at: 12)
        return record
    }()

    private static let defaultSettings: Record = {
        var body = [UInt8](repeating: 0, count: 332)
        body[0] = 1
        body[8] = 1
        body[76] = 4
        body[140] = 0x78
        var record = Record(tag: "mhod", headerLength: 24, body: body)
        record.set32(Text.settings, at: 12)
        return record
    }()
}
