import Foundation
import Testing
@testable import ShuffleKit

@Suite("Importing what is already on the iPod")
struct LibraryImportTests {
    @Test("Titles and playlist names come from Apple's library file")
    func importsNamesFromAppleLibrary() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let library = try await DeviceImporter.importLibrary(from: fake.device)

        #expect(library.tracks.count == 7)
        #expect(library.tracks[0].title == "Title 0")
        #expect(library.tracks[3].artist == "Artist 1")
        #expect(library.tracks[0].kind == "MP3")
        #expect(library.tracks[6].kind == "WAV")
        #expect(library.tracks[0].sizeBytes == 1000)
        #expect(library.tracks[0].durationMs == 4_335_568)
        #expect(library.tracks.allSatisfy { $0.announcement.state == .inherited })

        #expect(library.playlists.map(\.name) == ["List 1", "List 2"])
        #expect(library.playlists.allSatisfy { $0.announcement.state == .inherited })
        #expect(library.masterPlaylistID == 0)
        #expect(library.voiceOverEnabled)
        #expect(library.layout == .current)

        // "All Songs" keeps Apple's play order, which differs from the order of the track table.
        let positions = library.allSongsOrder.map { id in library.tracks.firstIndex { $0.id == id }! }
        #expect(positions == [3, 4, 5, 1, 0, 2, 6])
        // Apple's playlists list tracks twice; that must survive.
        #expect(library.playlists[0].trackIDs == [library.tracks[0].id, library.tracks[0].id])
    }

    @Test("Importing and rebuilding without changes reproduces Apple's database exactly")
    func untouchedLibraryRebuildsIdentically() async throws {
        for fixture in [Fixture.appleSync, Fixture.deviceTested, Fixture.legacyScript] {
            let fake = try FakeDevice(database: fixture)
            let library = try await DeviceImporter.importLibrary(from: fake.device)
            #expect(try library.makeDatabase().encoded() == fake.databaseOnDisk, "\(fixture)")
            #expect(library.databaseDigest == FileOps.sha256(fake.databaseOnDisk))
        }
    }

    @Test("Without Apple's library file, tags are asked for and file names are the last resort")
    func fallsBackToTagsThenFileNames() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync, titles: false)

        let fromNames = try await DeviceImporter.importLibrary(from: fake.device)
        #expect(fromNames.tracks[0].title == "GGFT")
        #expect(fromNames.playlists.map(\.name) == ["Playlist 1", "Playlist 2"])

        let fromTags = try await DeviceImporter.importLibrary(from: fake.device) { url in
            ProbedTags(title: "Tagged " + url.lastPathComponent, artist: "Someone", kind: "MP3", bitrateKbps: 128)
        }
        #expect(fromTags.tracks[0].title == "Tagged GGFT.mp3")
        #expect(fromTags.tracks[0].artist == "Someone")
        #expect(fromTags.tracks[0].bitrateKbps == 128)
    }

    @Test("What the app knew before is kept for tracks that are still in place")
    func carriesOverPreviousKnowledge() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        var previous = try await DeviceImporter.importLibrary(from: fake.device)
        previous.tracks[2].title = "My own title"
        previous.tracks[2].spokenName = "Say this"
        previous.tracks[2].playCount = 9
        previous.playlists[0].name = "Renamed"
        previous.addPlaylist(named: "Still empty")

        let library = try await DeviceImporter.importLibrary(from: fake.device, previous: previous)
        #expect(library.tracks[2].title == "My own title")
        #expect(library.tracks[2].spokenName == "Say this")
        #expect(library.tracks[2].playCount == 9)
        #expect(library.playlists.map(\.name) == ["Renamed", "List 2", "Still empty"])
    }

    @Test("Tracks that share an ID get distinct ones, and the database can still be built")
    func separatesDuplicateIDs() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        var database = try ShuffleDatabase(data: fake.databaseOnDisk)
        database.tracks[1].id = database.tracks[0].id
        try database.encoded().write(to: fake.device.databaseURL)

        let library = try await DeviceImporter.importLibrary(from: fake.device)
        #expect(Set(library.tracks.map(\.id)).count == 7)
        #expect(library.tracks[0].announcement.state == .inherited)
        #expect(library.tracks[1].announcement.state == .missing)
        #expect(try library.makeDatabase().tracks.count == 7)
    }

    @Test("An iPod with no database starts as an empty library")
    func emptyDevice() async throws {
        let fake = try FakeDevice()
        let library = try await DeviceImporter.importLibrary(from: fake.device)
        #expect(library.tracks.isEmpty)
        #expect(library.layout == .current)
        #expect(try library.makeDatabase().playlists.count == 1)
    }

    @Test("The manifest survives a save and load unchanged")
    func manifestRoundTrips() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        var library = try await DeviceImporter.importLibrary(from: fake.device)
        library.tracks[0].dateAdded = Date(timeIntervalSince1970: 1_700_000_000)
        library.tracks[0].spokenLanguage = "ru-RU"
        library.tracks[1].remembersPosition = true

        try ManifestStore.save(library, to: fake.device)
        let loaded = try #require(try ManifestStore.load(from: fake.device))
        #expect(loaded == library)
        #expect(try loaded.makeDatabase().tracks[1].rememberPosition == 1)
    }

    @Test("A manifest from a newer app version is refused rather than overwritten")
    func refusesNewerManifest() throws {
        let fake = try FakeDevice()
        try FileManager.default.createDirectory(at: fake.device.manifestDirectory, withIntermediateDirectories: true)
        try Data(#"{"schema": 99, "tracks": []}"#.utf8).write(to: fake.device.manifestURL)
        #expect(throws: ManifestError.self) { try ManifestStore.load(from: fake.device) }
    }

    @Test("A damaged manifest is ignored so the library can be rebuilt from the database")
    func ignoresDamagedManifest() throws {
        let fake = try FakeDevice()
        try FileManager.default.createDirectory(at: fake.device.manifestDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fake.device.manifestURL)
        #expect(try ManifestStore.load(from: fake.device) == nil)
    }
}

@Suite("Library edits")
struct LibraryEditTests {
    private func sample() -> Library {
        var library = Library()
        for index in 1...4 {
            let record = TrackRecord(id: UInt64(index), path: "/iPod_Control/Music/F00/T\(index).mp3", fileType: FileTypeCode.mp3)
            library.add(Track(record: record, title: "Track \(index)", kind: "MP3", durationMs: 1000, sizeBytes: 10))
        }
        return library
    }

    @Test("Removing tracks also removes them from every playlist and from All Songs")
    func removal() {
        var library = sample()
        let playlist = library.addPlaylist(named: "Mix")
        library.update(playlistID: playlist.id) { $0.trackIDs = [1, 2, 2, 3] }

        library.removeTracks([2])
        #expect(library.tracks.map(\.id) == [1, 3, 4])
        #expect(library.allSongsOrder == [1, 3, 4])
        #expect(library.playlist(playlist.id)?.trackIDs == [1, 3])
    }

    @Test("Normalizing repairs the play order and drops stale references")
    func normalize() {
        var library = sample()
        library.allSongsOrder = [3, 99, 3, 1]
        let playlist = library.addPlaylist(named: "Mix")
        library.update(playlistID: playlist.id) { $0.trackIDs = [4, 77] }

        library.normalize()
        #expect(library.allSongsOrder == [3, 1, 2, 4])
        #expect(library.playlist(playlist.id)?.trackIDs == [4])
    }

    @Test("Empty playlists stay in the library but are left out of the database")
    func emptyPlaylistsNotWritten() throws {
        var library = sample()
        library.addPlaylist(named: "Empty")
        let full = library.addPlaylist(named: "Full")
        library.update(playlistID: full.id) { $0.trackIDs = [4, 1] }

        let database = try library.makeDatabase()
        #expect(database.playlists.count == 2)
        #expect(database.playlists[1].id == full.id)
        #expect(database.playlists[1].trackIndexes == [3, 0])
        #expect(database.playlists[0].trackIndexes == [0, 1, 2, 3])
    }

    @Test("Playback options map onto the database flags")
    func playbackOptions() {
        var library = sample()
        library.update(trackID: 1) {
            $0.remembersPosition = true
            $0.skipsWhenShuffling = true
        }
        #expect(library.tracks[0].record.rememberPosition == 1)
        #expect(library.tracks[0].record.dontSkipOnShuffle == 0)
        #expect(library.tracks[1].record.dontSkipOnShuffle == 1)
    }

    @Test("New IDs never collide with existing ones or with zero")
    func freshIDs() {
        let library = sample()
        for _ in 0..<100 {
            let id = library.makeID()
            #expect(id != 0)
            #expect(library.track(id) == nil)
        }
    }
}

@Suite("Apple library reader")
struct AppleLibraryTests {
    @Test("Titles, artists and playlist names are read by ID")
    func readsNames() {
        let data = AppleLibraryBuilder.make(
            tracks: [(id: 10, title: "Группа крови", artist: "Кино", album: "A", durationMs: 5000)],
            playlists: [(id: 77, name: "Road Trip", isMaster: false, tracks: [0])]
        )
        let library = AppleLibrary(data: data)
        #expect(library.tracks[10]?.title == "Группа крови")
        #expect(library.tracks[10]?.artist == "Кино")
        #expect(library.tracks[10]?.durationMs == 5000)
        #expect(library.playlistNames[77] == "Road Trip")
    }

    @Test("Garbage and truncated files yield an empty result instead of a crash")
    func toleratesGarbage() {
        #expect(AppleLibrary(data: Data()).tracks.isEmpty)
        #expect(AppleLibrary(data: Data(repeating: 0xFF, count: 4096)).tracks.isEmpty)
        let valid = AppleLibraryBuilder.make(tracks: [(id: 1, title: "T", artist: "A", album: "B", durationMs: 1)], playlists: [])
        for length in stride(from: 0, to: valid.count, by: 7) {
            _ = AppleLibrary(data: valid.prefix(length))
        }
    }
}
