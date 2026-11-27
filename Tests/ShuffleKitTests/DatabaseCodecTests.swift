import Foundation
import Testing
@testable import ShuffleKit

@Suite("iTunesSD codec")
struct DatabaseCodecTests {
    @Test("Apple's own database decodes and re-encodes byte for byte")
    func appleDatabaseRoundTrips() throws {
        let original = try Fixture.data(Fixture.appleSync)
        let database = try ShuffleDatabase(data: original)

        #expect(database.layout == .current)
        #expect(database.voiceOverEnabled)
        #expect(database.maxVolume == 0)
        #expect(database.tracks.count == 7)
        #expect(database.playlists.count == 3)
        #expect(try database.encoded() == original)
    }

    @Test("Apple's records carry the values we rely on")
    func appleRecordContents() throws {
        let database = try ShuffleDatabase(data: try Fixture.data(Fixture.appleSync))

        let first = database.tracks[0]
        #expect(first.path == "/iPod_Control/Music/F01/GGFT.mp3")
        #expect(first.fileType == FileTypeCode.mp3)
        #expect(first.stopMs == 4_335_568)
        #expect(first.pregap == 576)
        #expect(first.sampleCount == 191_195_550)
        #expect(first.dontSkipOnShuffle == 1)
        #expect(first.rememberPosition == 0)

        let wav = database.tracks[6]
        #expect(wav.path.hasSuffix(".wav"))
        #expect(wav.fileType == FileTypeCode.wav)
        #expect(wav.sampleCount == 604_799)

        let master = database.playlists[0]
        #expect(master.kind == PlaylistRecord.Kind.master)
        #expect(master.id == 0)
        #expect(master.trackIndexes == [3, 4, 5, 1, 0, 2, 6])
        #expect(database.playlists[1].kind == PlaylistRecord.Kind.normal)
        #expect(database.playlists[1].trackIndexes == [0, 0])
    }

    @Test("The database that played on a real iPod round-trips")
    func deviceTestedDatabaseRoundTrips() throws {
        let original = try Fixture.data(Fixture.deviceTested)
        let database = try ShuffleDatabase(data: original)

        #expect(database.tracks.count == 11)
        #expect(database.playlists.count == 4)
        #expect(database.tracks.suffix(4).map(\.fileType) == [FileTypeCode.mpeg4, FileTypeCode.mpeg4, FileTypeCode.wav, FileTypeCode.mp3])
        #expect(database.playlists[3].trackIndexes == [7, 8, 9, 10])
        #expect(try database.encoded() == original)
    }

    @Test("The legacy script's database round-trips, including a path that fills the whole field")
    func legacyDatabaseRoundTrips() throws {
        let original = try Fixture.data(Fixture.legacyScript)
        let database = try ShuffleDatabase(data: original)

        #expect(database.layout == .legacy)
        #expect(database.reserved.legacySentinelCounts)
        #expect(database.tracks.count == 6)
        #expect(database.tracks.contains { $0.path.utf8.count == 256 })
        #expect(database.tracks.contains { $0.path.contains("Кино") })
        #expect(try database.encoded() == original)
    }

    @Test("Appending a playlist to Apple's database yields exactly the bytes that played on the iPod")
    func appendingReproducesDeviceTestedDatabase() throws {
        var database = try ShuffleDatabase(data: try Fixture.data(Fixture.appleSync))
        let expected = try ShuffleDatabase(data: try Fixture.data(Fixture.deviceTested))

        database.tracks.append(contentsOf: expected.tracks.suffix(4))
        database.playlists[0] = expected.playlists[0]
        database.playlists.append(expected.playlists[3])

        #expect(try database.encoded() == (try Fixture.data(Fixture.deviceTested)))
    }

    @Test("An empty library encodes to a master playlist with no songs")
    func emptyDatabase() throws {
        let database = ShuffleDatabase(playlists: [PlaylistRecord(id: 0, kind: PlaylistRecord.Kind.master, trackIndexes: [])])
        let data = try database.encoded()
        let decoded = try ShuffleDatabase(data: data)

        #expect(decoded == database)
        #expect(data.count == 64 + 20 + 68 + 4 + 44)
    }

    @Test("The legacy layout can be written from scratch")
    func legacyLayoutEncodes() throws {
        let track = TrackRecord(id: 0x1122_3344_5566_7788, path: "/iPod_Control/Music/F00/ABCD.mp3", fileType: FileTypeCode.mp3, stopMs: 1000)
        let database = ShuffleDatabase(
            layout: .legacy,
            tracks: [track],
            playlists: [
                PlaylistRecord(id: 0, kind: PlaylistRecord.Kind.master, trackIndexes: [0]),
                PlaylistRecord(id: 42, kind: PlaylistRecord.Kind.normal, trackIndexes: [0, 0]),
            ]
        )
        let decoded = try ShuffleDatabase(data: try database.encoded())
        #expect(decoded == database)
    }

    @Test("Damaged or foreign files are rejected with a clear error")
    func rejectsBadInput() throws {
        #expect(throws: DatabaseError.notShuffleDatabase) { try ShuffleDatabase(data: Data()) }
        #expect(throws: DatabaseError.notShuffleDatabase) { try ShuffleDatabase(data: Data(repeating: 0x41, count: 200)) }

        var wrongVersion = try Fixture.data(Fixture.appleSync)
        wrongVersion[4] = 0x99
        #expect(throws: DatabaseError.self) { try ShuffleDatabase(data: wrongVersion) }

        let truncated = try Fixture.data(Fixture.appleSync).prefix(1500)
        #expect(throws: DatabaseError.self) { try ShuffleDatabase(data: Data(truncated)) }
    }

    @Test("A playlist that points past the last track cannot be written")
    func rejectsDanglingPlaylistEntry() {
        let database = ShuffleDatabase(playlists: [PlaylistRecord(id: 0, kind: PlaylistRecord.Kind.master, trackIndexes: [0])])
        #expect(throws: DatabaseError.self) { try database.encoded() }
    }

    @Test("Paths longer than the 256-byte field are refused instead of truncated")
    func rejectsOverlongPath() {
        let track = TrackRecord(id: 1, path: "/" + String(repeating: "x", count: 300), fileType: FileTypeCode.mp3)
        let database = ShuffleDatabase(tracks: [track], playlists: [])
        #expect(throws: DatabaseError.self) { try database.encoded() }
    }
}

@Suite("iTunesStats")
struct PlayStatisticsTests {
    @Test("An empty statistics file matches what Apple's sync leaves behind")
    func emptyFileLayout() throws {
        let data = PlayStatistics.empty(trackCount: 7)
        #expect(data.count == 232)
        #expect([UInt8](data.prefix(12)) == [7, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0])

        let parsed = try PlayStatistics(data: data)
        #expect(parsed.entries.count == 7)
        #expect(!parsed.hasActivity)
    }

    @Test("Play counts and bookmarks are read from their documented positions")
    func decodesEntries() throws {
        var bytes = [UInt8](PlayStatistics.empty(trackCount: 2))
        // Second entry starts at 8 + 32: bookmark 5000 ms, 3 plays, 1 skip.
        bytes.replaceSubrange(44..<48, with: [0x88, 0x13, 0, 0])
        bytes[48] = 3
        bytes[56] = 1
        let parsed = try PlayStatistics(data: Data(bytes))

        #expect(parsed.entries[0].isEmpty)
        #expect(parsed.entries[1].bookmarkMs == 5000)
        #expect(parsed.entries[1].playCount == 3)
        #expect(parsed.entries[1].skipCount == 1)
        #expect(parsed.hasActivity)
    }
}
