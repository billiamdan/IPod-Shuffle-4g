import Foundation
import Testing
@testable import ShuffleKit

/// The session's side of keeping Apple's library file in step: when it is written, backed up and left alone.
@Suite("Finder's list follows the iPod")
struct AppleLibrarySyncTests {
    private let voice = VoiceOverSettings(defaultLanguage: "en-US")

    private func makeSession(_ fake: FakeDevice) throws -> (DeviceSession, TemporaryDirectory) {
        let backups = try TemporaryDirectory()
        return (DeviceSession(device: fake.device, speech: FakeSpeech(), backupRoot: backups.url), backups)
    }

    private func listed(_ fake: FakeDevice) -> AppleLibrary { AppleLibrary(data: fake.appleLibraryOnDisk) }

    @Test("An iPod as Apple's sync left it is in step, and nothing is written")
    func syncedDeviceIsInStep() async throws {
        let fake = try FakeDevice.appleSynced()
        let original = fake.appleLibraryOnDisk
        let (session, backups) = try makeSession(fake)

        let library = try await session.open()
        #expect(library.tracks.map(\.title).prefix(2) == ["Desert Sunrise Set", "Garden Session"])
        #expect(library.playlists.map(\.name) == ["Morning", "Evening"])
        // Apple's play counts and dates come along, so the app starts from the numbers Finder shows.
        #expect(library.tracks[0].playCount == 9)
        #expect(library.tracks[0].skipCount == 6)
        #expect(library.tracks[0].lastPlayed != nil && library.tracks[0].dateAdded != nil)
        #expect(library.tracks[6].playCount == 0 && library.tracks[6].lastPlayed == nil)

        #expect(await session.appleLibraryStatus() == .inStep)
        #expect(await session.appleLibraryNeedsCatchUp() == false)
        #expect(try await session.commit(voiceOver: voice) == CommitSummary())
        #expect(fake.appleLibraryOnDisk == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.url.path).isEmpty)
        #expect(await session.verify().isEmpty)
    }

    @Test("Removing songs removes them from Finder's list, after a backup of the file")
    func removalReachesAppleLibrary() async throws {
        let fake = try FakeDevice.appleSynced()
        let original = fake.appleLibraryOnDisk
        let (session, _) = try makeSession(fake)
        let library = try await session.open()
        let gone = Set([library.tracks[3].id, library.tracks[5].id, library.tracks[6].id])

        await session.removeTracks(gone)
        guard case let .behind(changes) = await session.appleLibraryStatus() else {
            Issue.record("the file should be behind before the commit")
            return
        }
        #expect(changes.tracksRemoved == 3)

        let summary = try await session.commit(voiceOver: voice)
        #expect(summary.databaseWritten && summary.appleLibraryWritten)
        #expect(summary.appleLibraryProblem == nil)
        #expect(Set(listed(fake).tracks.keys) == Set(library.tracks.map(\.id)).subtracting(gone))
        #expect(try Data(contentsOf: try #require(summary.backup).appendingPathComponent("iTunesDB")) == original)
        #expect(await session.appleLibraryStatus() == .inStep)
        #expect(await session.verify().isEmpty)
        // No sidecar or temporary file is left next to it.
        let names = try FileManager.default.contentsOfDirectory(atPath: fake.device.databaseDirectory.path)
        #expect(!names.contains { $0.hasPrefix("._") || $0.hasSuffix(".new") })

        // A second commit has nothing to do.
        let again = try await session.commit(voiceOver: voice)
        #expect(!again.appleLibraryWritten && !again.databaseWritten)
    }

    @Test("Songs and playlists added here appear in Apple's file with their names")
    func additionsReachAppleLibrary() async throws {
        let fake = try FakeDevice.appleSynced()
        let (session, _) = try makeSession(fake)
        let sources = try TemporaryDirectory()
        let wav = sources.url.appendingPathComponent("My Tone.wav")
        let mp3 = sources.url.appendingPathComponent("Группа крови.mp3")
        try AudioFixtures.wav(at: wav, seconds: 0.5)
        try AudioFixtures.mp3(at: mp3, frames: 40)
        try await session.open()

        let playlist = try #require(await session.edit { $0.addPlaylist(named: "Fresh") }.playlists.last)
        let report = await session.addFiles([wav, mp3], toPlaylist: playlist.id)
        #expect(report.added.count == 2)
        let summary = try await session.commit(voiceOver: voice)
        #expect(summary.appleLibraryWritten)

        let apple = listed(fake)
        #expect(apple.tracks.count == 9)
        #expect(report.added.map { apple.tracks[$0.id]?.title } == ["My Tone", "Группа крови"])
        #expect(apple.tracks[report.added[0].id]?.durationMs == 500)
        #expect(apple.playlistNames[playlist.id] == "Fresh")

        // The file agrees with the play database about where each new song lives.
        let file = try AppleLibraryFile(data: fake.appleLibraryOnDisk)
        let records = try #require(file.root.children.first { $0.kind == 1 }).children[0].children
        let database = try ShuffleDatabase(data: fake.databaseOnDisk)
        #expect(records.map { $0.string(2)?.replacingOccurrences(of: ":", with: "/") } == database.tracks.map(\.path))
        #expect(records.map { $0.u64(112) } == database.tracks.map(\.id))
        #expect(records[7].string(6) == "WAV audio file")
        #expect(records[7].u64(188) == 22_050, "the sample count of uncompressed audio, as in the play database")
        #expect(records[7].u32(36) == UInt32(try #require(FileOps.fileSize(fake.device.fileURL(devicePath: database.tracks[7].path)))))

        // Opening again: in step, nothing to catch up on, nothing written.
        let (second, _) = try makeSession(fake)
        try await second.open()
        #expect(await second.appleLibraryStatus() == .inStep)
        #expect(try await second.commit(voiceOver: voice) == CommitSummary())

        // Renaming and deleting follow too.
        let id = report.added[0].id
        await second.edit { $0.update(trackID: id) { $0.title = "Renamed Tone" } }
        await second.removePlaylist(playlist.id)
        #expect(try await second.commit(voiceOver: voice).appleLibraryWritten)
        #expect(listed(fake).tracks[id]?.title == "Renamed Tone")
        #expect(listed(fake).playlistNames[playlist.id] == nil)
        #expect(await second.verify().isEmpty)
    }

    @Test("An iPod this app left behind is caught up; one it never wrote waits for a change")
    func catchesUp() async throws {
        // An earlier version of this app removed songs and did not touch Apple's file.
        let fake = try FakeDevice.appleSynced()
        let stale = fake.appleLibraryOnDisk
        let (first, _) = try makeSession(fake)
        let library = try await first.open()
        await first.removeTracks([library.tracks[0].id])
        try await first.commit(voiceOver: voice)
        try stale.write(to: fake.device.appleLibraryURL)

        let (second, backups) = try makeSession(fake)
        try await second.open()
        #expect(await second.appleLibraryNeedsCatchUp())
        #expect(await second.verify().count == 1)
        let summary = try await second.commit(voiceOver: voice)
        #expect(summary.appleLibraryWritten && !summary.databaseWritten)
        #expect(listed(fake).tracks.count == 6)
        #expect(await second.appleLibraryNeedsCatchUp() == false)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: backups.url.path).contains { $0.hasSuffix("iTunesDB") })

        // Another program (the legacy script, say) rebuilt the database with fewer songs. This app has never
        // written this iPod, so it only reports the difference; the user's first change settles it.
        let foreign = try FakeDevice.appleSynced()
        var database = try ShuffleDatabase(data: foreign.databaseOnDisk)
        database.tracks.removeLast()
        database.playlists[0].trackIndexes.removeAll { $0 == 6 }
        try database.encoded().write(to: foreign.device.databaseURL)
        let (third, _) = try makeSession(foreign)
        try await third.open()
        #expect(await third.appleLibraryNeedsCatchUp() == false)
        guard case .behind = await third.appleLibraryStatus() else {
            Issue.record("the file lists a song the database no longer has")
            return
        }
        await third.edit { $0.tracks[0].title = "Mine now" }
        #expect(try await third.commit(voiceOver: voice).appleLibraryWritten)
        #expect(listed(foreign).tracks.count == 6)
        #expect(listed(foreign).tracks[try #require(await third.snapshot().tracks.first).id]?.title == "Mine now")
    }

    @Test("A library file this app cannot edit is left as it is, and the iPod is still updated")
    func unreadableFileIsLeftAlone() async throws {
        let fake = try FakeDevice.appleSynced()
        let garbage = Data("mhbd, but not really".utf8)
        try garbage.write(to: fake.device.appleLibraryURL)
        let (session, _) = try makeSession(fake)
        let library = try await session.open()
        #expect(library.tracks.count == 7)
        guard case .unreadable = await session.appleLibraryStatus() else {
            Issue.record("garbage should be reported as unreadable")
            return
        }
        #expect(await session.appleLibraryNeedsCatchUp() == false)

        await session.removeTracks([library.tracks[0].id])
        let summary = try await session.commit(voiceOver: voice)
        #expect(summary.databaseWritten)
        #expect(!summary.appleLibraryWritten)
        #expect(summary.appleLibraryProblem?.contains("Apple's library file") == true)
        #expect(fake.appleLibraryOnDisk == garbage)
        #expect(try ShuffleDatabase(data: fake.databaseOnDisk).tracks.count == 6)
    }

    @Test("Without a library file none is made")
    func absentFileStaysAbsent() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync, titles: false)
        let (session, _) = try makeSession(fake)
        let library = try await session.open()
        #expect(await session.appleLibraryStatus() == .absent)
        await session.removeTracks([library.tracks[0].id])
        let summary = try await session.commit(voiceOver: voice)
        #expect(summary.databaseWritten && !summary.appleLibraryWritten && summary.appleLibraryProblem == nil)
        #expect(!FileManager.default.fileExists(atPath: fake.device.appleLibraryURL.path))
    }

    @Test("Plays the iPod recorded are added to Apple's totals once")
    func playsReachAppleLibrary() async throws {
        let fake = try FakeDevice.appleSynced()
        var statistics = [UInt8](PlayStatistics.empty(trackCount: 7))
        func put(_ value: UInt32, entry: Int, field: Int) {
            let offset = 8 + 32 * entry + 4 * field
            for index in 0..<4 { statistics[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(8 * index)) }
        }
        put(4, entry: 1, field: 2)                  // four plays of the second track
        put(3_950_000_000, entry: 1, field: 3)      // the last of them, on the iPod's clock
        put(2, entry: 6, field: 4)                  // two skips of the seventh
        try Data(statistics).write(to: fake.device.statisticsURL)

        let (session, _) = try makeSession(fake)
        let library = try await session.open()
        #expect(library.tracks[1].playCount == 7 + 4)
        // Plays alone are not a reason to write on opening; they go out with the next commit.
        #expect(await session.appleLibraryStatus() == .inStep)

        let summary = try await session.commit(voiceOver: voice)
        #expect(summary.appleLibraryWritten && !summary.databaseWritten)
        let file = try AppleLibraryFile(data: fake.appleLibraryOnDisk)
        let records = try #require(file.root.children.first { $0.kind == 1 }).children[0].children
        #expect(records[1].u32(80) == 7 + 4)
        #expect(records[1].u32(88) == 3_950_000_000)
        #expect(records[6].u32(156) == 0 + 2)
        #expect(listed(fake).tracks[library.tracks[1].id]?.playCount == 11)

        let written = fake.appleLibraryOnDisk
        #expect(try await session.commit(voiceOver: voice).appleLibraryWritten == false)
        let (again, _) = try makeSession(fake)
        #expect(try await again.open().tracks[1].playCount == 11)
        #expect(try await again.commit(voiceOver: voice) == CommitSummary())
        #expect(fake.appleLibraryOnDisk == written)
    }
}
