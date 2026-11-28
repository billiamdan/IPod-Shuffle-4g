// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ShuffleKit

private typealias Record = AppleLibraryFile.Record

/// A library file read back for inspection. Offsets used below are the documented ones (see `AppleLibraryMirror`).
private struct Decoded {
    let file: AppleLibraryFile

    init(_ data: Data) throws { file = try AppleLibraryFile(data: data) }

    func section(_ kind: UInt32) -> Record? { file.root.children.first { $0.kind == kind } }
    func records(_ kind: UInt32) -> [Record] { section(kind)?.children[0].children ?? [] }

    var tracks: [Record] { records(1) }
    var albums: [Record] { records(4) }
    func track(_ id: UInt64) -> Record? { tracks.first { $0.u64(112) == id } }
    func playlist(_ id: UInt64, section: UInt32 = 2) -> Record? { records(section).first { $0.u64(28) == id } }
    func album(_ number: UInt32) -> Record? { albums.first { $0.u32(16) == number } }

    static func items(_ playlist: Record?) -> [Record] { (playlist?.children ?? []).filter { $0.tag == "mhip" } }
    /// The track numbers a playlist's items point at, in order.
    static func tracks(_ playlist: Record?) -> [UInt32] { items(playlist).map { $0.u32(24) } }
    static func positions(_ playlist: Record?) -> [UInt32] {
        items(playlist).compactMap { item in
            guard let body = item.children.first(where: { $0.kind == 100 })?.body, body.count >= 4 else { return nil }
            return UInt32(body[0]) | UInt32(body[1]) << 8 | UInt32(body[2]) << 16 | UInt32(body[3]) << 24
        }
    }
    static func kinds(_ record: Record?) -> [UInt32] { (record?.children ?? []).filter { $0.tag == "mhod" }.map(\.kind) }
}

/// What the fixture holds: seven tracks, three albums, the "everything" list and three playlists.
private enum Synced {
    static func id(_ index: Int) -> UInt64 { 0xA11C_E000_0000_0001 + UInt64(index) }
    /// The numbers playlist items use for the seven tracks.
    static let numbers: [UInt32] = [35, 38, 40, 42, 44, 46, 48]
    static let morning: UInt64 = 0xA11C_E000_0000_0008
    static let evening: UInt64 = 0xA11C_E000_0000_0009
    static let everything: UInt64 = 0xA11C_E000_0000_000A
    /// An empty playlist. It never reached the play database, so the library does not know it.
    static let unplayedBook: UInt64 = 0xA11C_E000_0000_000B
    /// The file's dates are on a clock one hour east of Greenwich.
    static func fileTime(_ date: Date) -> UInt32 { UInt32(date.timeIntervalSince1970) + 2_082_844_800 + 3600 }
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func load() async throws -> (data: Data, library: Library) {
        let fake = try FakeDevice.appleSynced()
        return (fake.appleLibraryOnDisk, try await DeviceImporter.importLibrary(from: fake.device))
    }

    static func newTrack(
        id: UInt64 = 0xBEEF, type: UInt32 = FileTypeCode.mp3, file: String = "NEWS.mp3", title: String = "New Song",
        artist: String = "", album: String = "", kind: String = "MP3"
    ) -> Track {
        Track(
            record: TrackRecord(id: id, path: "/iPod_Control/Music/F00/" + file, fileType: type, stopMs: 61_000),
            title: title, artist: artist, album: album, kind: kind, durationMs: 61_000, sizeBytes: 976_000,
            bitrateKbps: 128, sampleRate: 48_000, dateAdded: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}

@Suite("Apple library file, read and written whole")
struct AppleLibraryFileTests {
    @Test("A file written by Apple's sync comes back byte for byte")
    func roundTrips() throws {
        let data = try Fixture.data(Fixture.appleLibrary)
        let decoded = try Decoded(data)
        #expect(decoded.file.encoded() == data)

        #expect(decoded.file.root.children.map(\.kind) == [4, 1, 3, 2, 5])
        #expect(decoded.tracks.map { $0.u64(112) } == (0..<7).map(Synced.id))
        #expect(decoded.tracks.map { $0.u32(16) } == Synced.numbers)
        #expect(decoded.tracks.allSatisfy { $0.header.count == 624 })
        #expect(decoded.tracks[5].string(1) == "Привет")
        #expect(decoded.tracks[3].string(4) == "The Robots")
        #expect(decoded.albums.map { $0.u32(16) } == [32, 33, 34])
        #expect(decoded.albums.map { $0.string(201) } == [nil, "The Robots", "Vega Nine"])

        // Both playlist sections are the same; the first list is the one holding everything.
        #expect(decoded.records(3) == decoded.records(2))
        #expect(decoded.records(2).map { $0.string(1) } == ["Test iPod", "Morning", "Evening", "Unplayed Book"])
        #expect(Decoded.tracks(decoded.playlist(Synced.everything)) == Synced.numbers)
        #expect(Decoded.tracks(decoded.playlist(Synced.morning)) == [35, 35])
        #expect(Decoded.tracks(decoded.playlist(Synced.evening)) == [38, 40, 42, 38, 40, 42])
        #expect(decoded.records(5).map { $0.string(1) } == ["Audiobooks", "Music"])
    }

    @Test("A file from older software, with shorter records, comes back byte for byte too")
    func roundTripsOldLayout() throws {
        let data = AppleLibraryBuilder.make(
            tracks: [(id: 1, title: "One", artist: "A", album: "B", durationMs: 1), (id: 2, title: "Two", artist: "", album: "", durationMs: 2)],
            playlists: [(id: 9, name: "All", isMaster: true, tracks: [0, 1]), (id: 7, name: "Mix", isMaster: false, tracks: [1, 1])]
        )
        let decoded = try Decoded(data)
        #expect(decoded.file.encoded() == data)
        #expect(Decoded.tracks(decoded.playlist(7)) == [101, 101])
    }

    @Test("Damaged or foreign files are refused rather than guessed at")
    func refusesWhatItCannotReproduce() throws {
        let data = try Fixture.data(Fixture.appleLibrary)
        #expect(throws: AppleLibraryError.notALibrary) { try AppleLibraryFile(data: Data()) }
        #expect(throws: AppleLibraryError.notALibrary) { try AppleLibraryFile(data: Data(repeating: 0x41, count: 5000)) }
        for length in stride(from: 12, to: data.count, by: 211) {
            #expect(throws: AppleLibraryError.self) { try AppleLibraryFile(data: data.prefix(length)) }
        }
        #expect(throws: AppleLibraryError.self) { try AppleLibraryFile(data: data + Data([0, 0, 0, 0])) }

        // A record this app has never seen: where it ends is anyone's guess, so the file is not edited.
        var unknown = [UInt8](data)
        let firstTrack = try #require(data.firstRange(of: Data("mhit".utf8))).lowerBound
        unknown.replaceSubrange(firstTrack..<firstTrack + 4, with: Array("mhzz".utf8))
        #expect(throws: AppleLibraryError.self) { try AppleLibraryFile(data: Data(unknown)) }

        // A count that disagrees with the contents.
        var miscounted = [UInt8](data)
        let trackList = try #require(data.firstRange(of: Data("mhlt".utf8))).lowerBound
        miscounted[trackList + 8] = 6
        #expect(throws: AppleLibraryError.self) { try AppleLibraryFile(data: Data(miscounted)) }

        // A track that claims fewer strings than it has would be changed just by rewriting it.
        var understated = [UInt8](data)
        understated[firstTrack + 12] = 2
        #expect(throws: AppleLibraryError.unsupported("its counts and lengths do not add up")) {
            try AppleLibraryFile(data: Data(understated))
        }
    }
}

@Suite("Keeping Apple's library file in step")
struct AppleLibraryMirrorTests {
    @Test("What Apple's sync wrote needs no change for the library imported from the same iPod")
    func alreadyInStep() async throws {
        let (data, library) = try await Synced.load()
        let result = try AppleLibraryMirror.mirror(data, to: library, now: Synced.now)
        #expect(result.data == data)
        #expect(result.changes.isEmpty)
    }

    @Test("Removed songs lose their records, their playlist items and their unused albums; nothing else moves")
    func removesTracks() async throws {
        var (data, library) = try await Synced.load()
        let original = try Decoded(data)
        library.removeTracks([Synced.id(3), Synced.id(5), Synced.id(6)])

        let result = try AppleLibraryMirror.mirror(data, to: library, now: Synced.now)
        let decoded = try Decoded(result.data)
        #expect(result.changes.tracksRemoved == 3)
        #expect(result.changes.playlistsUpdated == 2)
        #expect(result.changes.tracksAdded == 0 && result.changes.tracksUpdated == 0)
        #expect(result.changes.playlistsAdded == 0 && result.changes.playlistsRemoved == 0)
        #expect(result.changes.summary == "3 songs removed, 2 playlists updated")
        #expect(result.changes.pendingSummary == "3 songs to remove, 2 playlists to update")

        // The four survivors are exactly as Apple wrote them.
        #expect(decoded.tracks.map { $0.u64(112) } == [0, 1, 2, 4].map(Synced.id))
        for index in [0, 1, 2, 4] {
            #expect(decoded.track(Synced.id(index)) == original.track(Synced.id(index)))
        }
        // "The Robots" had one song, which is gone; the nameless album and "Vega Nine" are still in use.
        #expect(decoded.albums == [original.albums[0], original.albums[2]])

        #expect(Decoded.tracks(decoded.playlist(Synced.everything)) == [35, 38, 40, 44])
        #expect(Decoded.tracks(decoded.playlist(Synced.evening)) == [38, 40, 38, 40])
        #expect(decoded.playlist(Synced.morning) == original.playlist(Synced.morning))
        #expect(decoded.playlist(Synced.unplayedBook) == original.playlist(Synced.unplayedBook))
        #expect(decoded.records(3) == decoded.records(2))
        #expect(decoded.section(5) == original.section(5))
        #expect(decoded.file.root.header.dropFirst(12) == original.file.root.header.dropFirst(12))

        // The forgiving reader, which the importer uses, agrees.
        let reader = AppleLibrary(data: result.data)
        #expect(Set(reader.tracks.keys) == Set([0, 1, 2, 4].map(Synced.id)))
        #expect(reader.tracks[Synced.id(4)]?.artist == "Vega Nine")

        // Doing it again changes nothing.
        #expect(try AppleLibraryMirror.mirror(result.data, to: library, now: Synced.now).data == result.data)
    }

    @Test("A song added here gets a record filled in the way Apple fills one")
    func addsTrack() async throws {
        var (data, library) = try await Synced.load()
        var track = Synced.newTrack(artist: "Кино", album: "Группа крови")
        track.playCount = 3
        track.lastPlayed = Date(timeIntervalSince1970: 1_795_000_000)
        track.remembersPosition = true
        library.add(track)

        let result = try AppleLibraryMirror.mirror(data, to: library, now: Synced.now)
        let decoded = try Decoded(result.data)
        #expect(result.changes.tracksAdded == 1)
        #expect(result.changes.playlistsUpdated == 1)
        #expect(Array(decoded.tracks.prefix(7)) == (try Decoded(data)).tracks)

        let record = try #require(decoded.track(0xBEEF))
        let added = Synced.fileTime(Date(timeIntervalSince1970: 1_790_000_000))
        #expect(record.header.count == 624)
        #expect(record.u32(16) == 78, "numbers continue after the highest one in the file")
        #expect(record.u32(20) == 1)
        #expect(Array(record.header[24..<28]) == Array(" 3PM".utf8))
        #expect(record.u8(29) == 1)
        #expect(record.u32(36) == 976_000 && record.u32(300) == 976_000)
        #expect(record.u32(40) == 61_000)
        #expect(record.u32(56) == 128)
        #expect(record.u32(60) == 48_000 << 16)
        #expect(record.u32(80) == 3 && record.u32(84) == 3)
        #expect(record.u32(88) == Synced.fileTime(Date(timeIntervalSince1970: 1_795_000_000)))
        #expect(record.u32(32) == added && record.u32(104) == added)
        #expect(record.u16(126) == 0xFFFF)
        #expect(record.u32(136) == Float(48_000).bitPattern)
        #expect(record.u16(144) == 0x0C)
        #expect(record.u8(164) == 2)
        #expect(record.u8(165) == 0 && record.u8(166) == 1)
        #expect(record.u8(178) == 1)
        #expect(record.u32(208) == 1)
        #expect(record.u16(256) == 1)
        #expect(record.u64(308) == 0x8080_8080_8080)
        #expect(record.u32(360) == 1)
        #expect(record.u32(480) == 79 && record.u32(500) == 80)
        #expect(Decoded.kinds(record) == [1, 4, 3, 6, 2])
        #expect(record.string(1) == "New Song")
        #expect(record.string(4) == "Кино")
        #expect(record.string(3) == "Группа крови")
        #expect(record.string(6) == "MPEG audio file")
        #expect(record.string(2) == ":iPod_Control:Music:F00:NEWS.mp3")

        // Its album is new, so it gets an album record; the others are untouched.
        let album = try #require(decoded.album(record.u32(288)))
        #expect(decoded.albums.count == 4)
        #expect(album.u32(16) == 81)
        #expect(album.string(200) == "Группа крови" && album.string(201) == "Кино")
        #expect(album.header.count == 88)

        // It joins the list of everything, after what was there, in both playlist sections.
        let everything = decoded.playlist(Synced.everything)
        #expect(Decoded.tracks(everything) == Synced.numbers + [78])
        #expect(Decoded.positions(everything) == [0, 1, 2, 3, 4, 0x52, 0x59, 0x5A])
        let item = try #require(Decoded.items(everything).last)
        #expect(item.header.count == 76)
        #expect(item.u32(20) == 82)
        #expect(item.u32(28) == added)
        #expect(item.u64(44) == 0xBEEF)
        #expect(item.u64(60) != 0)
        #expect(decoded.records(3) == decoded.records(2))

        let reader = AppleLibrary(data: result.data)
        #expect(reader.tracks[0xBEEF]?.title == "New Song")
        #expect(reader.tracks[0xBEEF]?.playCount == 3)
        #expect(reader.tracks[0xBEEF]?.dateAdded == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try AppleLibraryMirror.mirror(result.data, to: library, now: Synced.now).data == result.data)
    }

    @Test("WAV, AAC and Apple Lossless get the markers of their kind; untitled extras share the nameless album")
    func addsOtherFormats() async throws {
        var (data, library) = try await Synced.load()
        var wav = Synced.newTrack(id: 0xA1, type: FileTypeCode.wav, file: "WAVE.wav", title: "Tone", kind: "WAV")
        wav.record.sampleCount = 123_456
        library.add(wav)
        library.add(Synced.newTrack(id: 0xA2, type: FileTypeCode.mpeg4, file: "AACS.m4a", title: "Compressed", kind: "AAC"))
        library.add(Synced.newTrack(id: 0xA3, type: FileTypeCode.mpeg4, file: "ALAC.m4a", title: "Lossless", kind: "Apple Lossless"))

        let decoded = try Decoded(try AppleLibraryMirror.mirror(data, to: library, now: Synced.now).data)
        let wave = try #require(decoded.track(0xA1))
        #expect(Array(wave.header[24..<28]) == Array(" VAW".utf8))
        #expect(wave.u8(29) == 0)
        #expect(wave.u16(126) == 0)
        #expect(wave.u16(144) == 0x46)
        #expect(wave.u64(188) == 123_456 && wave.u32(204) == 1)
        #expect(wave.u8(178) == 2, "not played yet")
        #expect(wave.string(6) == "WAV audio file")

        let aac = try #require(decoded.track(0xA2))
        #expect(Array(aac.header[24..<28]) == Array(" A4M".utf8))
        #expect(aac.u16(126) == 0xFFFF && aac.u16(144) == 0x33)
        #expect(aac.u64(188) == 0 && aac.u32(204) == 0)
        #expect(aac.string(6) == "AAC audio file")
        #expect(decoded.track(0xA3)?.string(6) == "Apple Lossless audio file")

        // No artist and no album: the album Apple made for such tracks is reused.
        #expect(decoded.albums.count == 3)
        #expect([0xA1, 0xA2, 0xA3].allSatisfy { decoded.track($0)?.u32(288) == 32 })
        #expect(Decoded.kinds(wave) == [1, 6, 2])
    }

    @Test("Renaming a song changes its strings; a new artist moves it to that artist's album")
    func renamesTracks() async throws {
        var (data, library) = try await Synced.load()
        let original = try Decoded(data)
        library.update(trackID: Synced.id(0)) {
            $0.title = "Sunrise (edit)"
            $0.artist = "Vega Nine"
        }
        library.update(trackID: Synced.id(3)) { $0.artist = "" }
        library.update(trackID: Synced.id(1)) { $0.skipsWhenShuffling = true }

        let result = try AppleLibraryMirror.mirror(data, to: library, now: Synced.now)
        let decoded = try Decoded(result.data)
        #expect(result.changes.tracksUpdated == 3)
        #expect(result.changes.playlistsUpdated == 0)

        let first = try #require(decoded.track(Synced.id(0)))
        #expect(first.string(1) == "Sunrise (edit)")
        #expect(first.string(4) == "Vega Nine")
        #expect(Decoded.kinds(first) == [1, 4, 6, 2], "the artist goes where Apple puts it, after the title")
        #expect(first.u32(288) == 34, "the album record Vega Nine already has")
        #expect(first.header.count == 624 && first.u32(16) == 35)

        // "The Robots" lost its only song: the string goes, the song joins the nameless album, the record goes.
        let fourth = try #require(decoded.track(Synced.id(3)))
        #expect(fourth.string(4) == nil)
        #expect(fourth.u32(288) == 32)
        #expect(decoded.albums.map { $0.u32(16) } == [32, 34])

        #expect(decoded.track(Synced.id(1))?.u8(165) == 1)
        #expect(decoded.track(Synced.id(2)) == original.track(Synced.id(2)))
        #expect(decoded.records(2) == original.records(2))
        #expect(try AppleLibraryMirror.mirror(result.data, to: library, now: Synced.now).data == result.data)
    }

    @Test("Playlists made, renamed, refilled and deleted here follow; unknown ones are left alone")
    func mirrorsPlaylists() async throws {
        var (data, library) = try await Synced.load()
        let original = try Decoded(data)
        let roadTrip = Playlist(id: 0xCAFE, name: "Road Trip", trackIDs: [Synced.id(2), Synced.id(5), Synced.id(2)])
        library.playlists.append(roadTrip)
        library.playlists.append(Playlist(id: 0xD00D, name: "Still Empty"))
        library.update(playlistID: Synced.morning) {
            $0.name = "Dawn"
            $0.trackIDs = [Synced.id(0)]                     // was the same song twice
        }
        library.update(playlistID: Synced.evening) { $0.trackIDs.append(Synced.id(4)) }

        let result = try AppleLibraryMirror.mirror(data, to: library, now: Synced.now)
        let decoded = try Decoded(result.data)
        #expect(result.changes.playlistsAdded == 2)
        #expect(result.changes.playlistsUpdated == 2)
        #expect(result.changes.playlistsRemoved == 0)
        #expect(decoded.tracks == original.tracks)

        #expect(decoded.records(2).map { $0.string(1) } == ["Test iPod", "Dawn", "Evening", "Unplayed Book", "Road Trip", "Still Empty"])
        #expect(decoded.records(3) == decoded.records(2))
        #expect(decoded.playlist(Synced.everything) == original.playlist(Synced.everything))
        #expect(decoded.playlist(Synced.unplayedBook) == original.playlist(Synced.unplayedBook))

        // The first of the two identical items stays; nothing is renumbered.
        let dawn = decoded.playlist(Synced.morning)
        #expect(Decoded.items(dawn) == [Decoded.items(original.playlist(Synced.morning))[0]])
        // Apple's order is kept and the addition goes last.
        let evening = decoded.playlist(Synced.evening)
        #expect(Decoded.tracks(evening) == [38, 40, 42, 38, 40, 42, 44])
        #expect(Decoded.positions(evening) == [0, 1, 2, 3, 4, 5, 6])

        let made = try #require(decoded.playlist(0xCAFE))
        #expect(made.header.count == 184)
        #expect(made.u8(20) == 0)
        #expect(made.u32(24) == Synced.fileTime(Synced.now))
        #expect(made.u16(40) == 1 && made.u16(42) == 0)
        #expect(made.u32(44) == 1, "its items are in play order")
        #expect(Decoded.kinds(made) == [1, 100, 102])
        #expect(made.children[1] == original.playlist(Synced.morning)?.children[1], "view settings as in Apple's playlists")
        #expect(made.children[2] == original.playlist(Synced.morning)?.children[2])
        #expect(Decoded.tracks(made) == [40, 46, 40])
        #expect(Decoded.positions(made) == [0, 1, 2])
        #expect(Decoded.tracks(decoded.playlist(0xD00D)) == [])
        #expect(AppleLibrary(data: result.data).playlistNames[0xCAFE] == "Road Trip")
        #expect(try AppleLibraryMirror.mirror(result.data, to: library, now: Synced.now).data == result.data)

        // Deleting a playlist here removes its record; a playlist that is merely unknown here is not deleted.
        library.playlists.removeAll { $0.id == 0xCAFE || $0.id == Synced.evening }
        let afterDelete = try AppleLibraryMirror.mirror(result.data, to: library, removedPlaylists: [0xCAFE, Synced.evening], now: Synced.now)
        let remaining = try Decoded(afterDelete.data)
        #expect(afterDelete.changes.playlistsRemoved == 2)
        #expect(remaining.records(2).map { $0.string(1) } == ["Test iPod", "Dawn", "Unplayed Book", "Still Empty"])
        #expect(remaining.records(3) == remaining.records(2))
        #expect(try AppleLibraryMirror.mirror(afterDelete.data, to: library, now: Synced.now).data == afterDelete.data)
    }

    @Test("A different play order, or details this app does not edit, are no reason to rewrite anything")
    func leavesTheRestAlone() async throws {
        var (data, library) = try await Synced.load()
        library.allSongsOrder.reverse()
        library.update(playlistID: Synced.evening) { $0.trackIDs.reverse() }
        // The genre cannot be changed in this app, so a library without one says nothing about Apple's.
        #expect(library.tracks[3].genre == "Blues")
        library.update(trackID: Synced.id(3)) { $0.genre = "" }
        library.update(trackID: Synced.id(0)) { $0.spokenName = "Say this instead" }
        #expect(try AppleLibraryMirror.mirror(data, to: library, now: Synced.now).data == data)
    }

    @Test("Randomly damaged files are refused or handled; none crashes the editor or yields a file it cannot read")
    func survivesDamage() async throws {
        var (data, library) = try await Synced.load()
        library.removeTracks([Synced.id(2)])
        library.add(Synced.newTrack(artist: "Someone", album: "Something"))
        library.playlists.append(Playlist(id: 0xCAFE, name: "New", trackIDs: [Synced.id(0), 0xBEEF]))

        // A fixed sequence, so a failure can be repeated.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var accepted = 0
        for _ in 0..<1500 {
            var bytes = [UInt8](data)
            for _ in 0..<(1 + Int(next() % 3)) {
                let offset = Int(next() % UInt64(bytes.count))
                bytes[offset] = UInt8(truncatingIfNeeded: next())
            }
            guard let result = try? AppleLibraryMirror.mirror(Data(bytes), to: library, now: Synced.now) else { continue }
            accepted += 1
            _ = try AppleLibraryFile(data: result.data)
            _ = AppleLibrary(data: result.data)
        }
        // Most single-byte changes hit fields this app carries along without interpreting them.
        #expect(accepted > 500)
    }

    @Test("Plays and skips the iPod recorded are added to Apple's totals")
    func addsActivity() async throws {
        let (data, library) = try await Synced.load()
        let original = try Decoded(data)
        let before = try #require(original.track(Synced.id(0)))
        let activity: [UInt64: PlayActivity] = [
            Synced.id(0): PlayActivity(plays: 3, skips: 1, lastPlayed: before.u32(88) - 10, lastSkipped: before.u32(160) + 10),
            Synced.id(6): PlayActivity(plays: 2, lastPlayed: 3_900_000_000),
        ]

        let result = try AppleLibraryMirror.mirror(data, to: library, activity: activity, now: Synced.now)
        let decoded = try Decoded(result.data)
        #expect(result.changes.tracksUpdated == 2)

        let first = try #require(decoded.track(Synced.id(0)))
        #expect(first.u32(80) == before.u32(80) + 3)
        #expect(first.u32(84) == before.u32(84), "Apple's second count is Apple's to move")
        #expect(first.u32(88) == before.u32(88), "an older date does not replace a newer one")
        #expect(first.u32(156) == before.u32(156) + 1)
        #expect(first.u32(160) == before.u32(160) + 10)

        // The WAV had never been played and was marked so.
        let wave = try #require(decoded.track(Synced.id(6)))
        #expect(original.track(Synced.id(6))?.u8(178) == 2)
        #expect(wave.u32(80) == 2 && wave.u32(88) == 3_900_000_000)
        #expect(wave.u8(178) == 1)
        #expect(decoded.track(Synced.id(1)) == original.track(Synced.id(1)))
    }

    @Test("A file with shorter records is edited in its own shape")
    func editsOldLayout() throws {
        let data = AppleLibraryBuilder.make(
            tracks: [
                (id: 10, title: "One", artist: "A", album: "B", durationMs: 1000),
                (id: 11, title: "Two", artist: "A", album: "B", durationMs: 2000),
                (id: 12, title: "Three", artist: "A", album: "B", durationMs: 3000),
            ],
            playlists: [(id: 9, name: "All", isMaster: true, tracks: [0, 1, 2]), (id: 7, name: "Mix", isMaster: false, tracks: [1, 1, 2])]
        )
        var library = Library()
        for (id, title) in [(UInt64(10), "One"), (11, "Two"), (12, "Three")] {
            let record = TrackRecord(id: id, path: "/iPod_Control/Music/F00/T\(id).mp3", fileType: FileTypeCode.mp3)
            library.add(Track(record: record, title: title, artist: "A", album: "B", kind: "MP3"))
        }
        library.playlists = [Playlist(id: 7, name: "Mix", trackIDs: [11, 11, 12])]
        #expect(try AppleLibraryMirror.mirror(data, to: library, now: Synced.now).data == data)

        library.removeTracks([11])
        library.add(Synced.newTrack(id: 13, title: "Four"), toPlaylist: 7)
        library.playlists.append(Playlist(id: 8, name: "New", trackIDs: [10]))
        let decoded = try Decoded(try AppleLibraryMirror.mirror(data, to: library, now: Synced.now).data)

        #expect(decoded.tracks.map { $0.u64(112) } == [10, 12, 13])
        let added = try #require(decoded.track(13))
        #expect(added.header.count == 156, "as long as the records already there; fields beyond that do not exist")
        #expect(added.u32(16) == 1007, "after the highest number in the file, which a playlist item holds")
        #expect(added.u32(40) == 61_000)
        #expect(added.string(1) == "Four")
        #expect(Decoded.tracks(decoded.playlist(9)) == [100, 102, 1007])
        #expect(Decoded.tracks(decoded.playlist(7)) == [102, 1007])
        let made = try #require(decoded.playlist(8))
        #expect(made.header.count == 108)
        #expect(Decoded.kinds(made) == [1], "nothing to copy view settings from, so none are invented")
        #expect(Decoded.tracks(made) == [100])
        #expect(decoded.file.root.children.count == 2)
    }

    @Test("A file this app cannot reproduce is reported, never rewritten")
    func refusesUnknownStructure() async throws {
        let (data, library) = try await Synced.load()
        var bytes = [UInt8](data)
        let firstTrack = try #require(data.firstRange(of: Data("mhit".utf8))).lowerBound
        bytes[firstTrack + 12] = 2
        #expect(throws: AppleLibraryError.self) { try AppleLibraryMirror.mirror(Data(bytes), to: library) }
        #expect(throws: AppleLibraryError.notALibrary) { try AppleLibraryMirror.mirror(Data("not a library".utf8), to: library) }
    }
}
