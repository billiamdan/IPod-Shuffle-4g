import Foundation
import Testing
@testable import ShuffleKit

/// Stands in for the system voices: instant, deterministic, and records what it was asked to say.
final class FakeSpeech: SpeechProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var spoken: [(text: String, language: String, voice: String?)] = []
    private let unspeakable: Set<String>

    init(unspeakable: Set<String> = []) {
        self.unspeakable = unspeakable
    }

    var texts: [String] { lock.withLock { spoken.map(\.text) } }
    var languages: [String] { lock.withLock { spoken.map(\.language) } }

    func render(text: String, voiceID: String?, language: String) async throws -> RenderedSpeech {
        lock.withLock { spoken.append((text, language, voiceID)) }
        if unspeakable.contains(text) { throw SpeechError.nothingToSay }
        return RenderedSpeech(samples: Data(repeating: 7, count: 2_000), voiceID: voiceID ?? "fake." + language)
    }
}

@Suite("Working on an iPod end to end")
struct DeviceSessionTests {
    private let voice = VoiceOverSettings(defaultLanguage: "en-US", additionalLanguages: ["ru-RU"])

    private func makeSession(_ fake: FakeDevice, speech: FakeSpeech = FakeSpeech()) throws -> (DeviceSession, TemporaryDirectory) {
        let backups = try TemporaryDirectory()
        return (DeviceSession(device: fake.device, speech: speech, backupRoot: backups.url), backups)
    }

    private func audioFiles(in directory: TemporaryDirectory) throws -> (wav: URL, mp3: URL) {
        let wav = directory.url.appendingPathComponent("My Tone.wav")
        let mp3 = directory.url.appendingPathComponent("Группа крови.mp3")
        try AudioFixtures.wav(at: wav, seconds: 0.5)
        try AudioFixtures.mp3(at: mp3, frames: 40)
        return (wav, mp3)
    }

    @Test("Opening and committing without changes writes nothing at all")
    func noChangesNoWrites() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let speech = FakeSpeech()
        let (session, backups) = try makeSession(fake, speech: speech)
        let before = fake.databaseOnDisk

        let library = try await session.open()
        #expect(library.tracks.count == 7)
        let summary = try await session.commit(voiceOver: voice)

        #expect(summary == CommitSummary())
        #expect(fake.databaseOnDisk == before)
        #expect(!FileManager.default.fileExists(atPath: fake.device.manifestDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: fake.device.statisticsURL.path))
        #expect(speech.texts.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.url.path).isEmpty)
    }

    @Test("Added files are copied in, announced and registered with the right type codes")
    func addsMusic() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let speech = FakeSpeech()
        let (session, backups) = try makeSession(fake, speech: speech)
        let sources = try TemporaryDirectory()
        let files = try audioFiles(in: sources)
        let original = fake.databaseOnDisk
        try await session.open()

        let report = await session.addFiles([files.wav, files.mp3])
        #expect(report.added.count == 2)
        #expect(report.skipped.isEmpty)
        #expect(report.added.map(\.title) == ["My Tone", "Группа крови"])

        let summary = try await session.commit(voiceOver: voice)
        #expect(summary.databaseWritten)
        #expect(summary.announcementsRecorded == 2)
        #expect(speech.texts == ["My Tone", "Группа крови"])
        #expect(speech.languages == ["en-US", "ru-RU"])

        // The iPod's database now has nine tracks, the first seven exactly as Apple wrote them.
        let database = try ShuffleDatabase(data: fake.databaseOnDisk)
        let apple = try ShuffleDatabase(data: original)
        #expect(database.tracks.count == 9)
        #expect(Array(database.tracks.prefix(7)) == apple.tracks)
        #expect(Array(database.playlists.dropFirst()) == Array(apple.playlists.dropFirst()))
        #expect(database.playlists[0].trackIndexes == apple.playlists[0].trackIndexes + [7, 8])

        let wav = database.tracks[7]
        #expect(wav.fileType == FileTypeCode.wav)
        #expect(wav.path.hasPrefix("/iPod_Control/Music/F0") && wav.path.hasSuffix(".wav"))
        #expect(wav.sampleCount == 22_050)
        #expect(wav.stopMs == 500)
        let mp3 = database.tracks[8]
        #expect(mp3.fileType == FileTypeCode.mp3)
        #expect(mp3.path.hasSuffix(".mp3"))
        #expect(mp3.dontSkipOnShuffle == 1)

        // Files: the WAV was rewritten in Apple's layout, the MP3 is an exact copy, both have announcements.
        let wavOnDevice = fake.device.fileURL(devicePath: wav.path)
        #expect(try WAVFile.inspect(wavOnDevice).dataOffset == 4096)
        #expect(try Data(contentsOf: fake.device.fileURL(devicePath: mp3.path)) == Data(contentsOf: files.mp3))
        let announcement = try Data(contentsOf: fake.device.trackAnnouncementURL(id: wav.id))
        #expect(announcement.count == 4096 + 2_000)
        #expect(String(decoding: announcement[36..<40], as: UTF8.self) == "FLLR")

        // Housekeeping: fresh statistics for nine tracks, a manifest, a backup of what was there, no sidecar files.
        #expect(try Data(contentsOf: fake.device.statisticsURL) == PlayStatistics.empty(trackCount: 9))
        #expect(try #require(try ManifestStore.load(from: fake.device)).tracks.count == 9)
        let backup = try #require(summary.backup)
        #expect(try Data(contentsOf: backup.appendingPathComponent("iTunesSD")) == original)
        #expect(backup.path.hasPrefix(backups.url.path))
        #expect(await session.verify().isEmpty)
    }

    @Test("Reopening trusts the manifest and a second commit is a no-op")
    func reopening() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let sources = try TemporaryDirectory()
        let files = try audioFiles(in: sources)
        let (first, _) = try makeSession(fake)
        try await first.open()
        _ = await first.addFiles([files.wav])
        try await first.commit(voiceOver: voice)
        let saved = await first.snapshot()
        let bytes = fake.databaseOnDisk

        let speech = FakeSpeech()
        let (second, _) = try makeSession(fake, speech: speech)
        let reopened = try await second.open()
        #expect(reopened == saved)
        #expect(reopened.tracks.last?.title == "My Tone")
        #expect(reopened.tracks.last?.announcement.state == .generated)

        let summary = try await second.commit(voiceOver: voice)
        #expect(!summary.databaseWritten)
        #expect(summary.announcementsRecorded == 0)
        #expect(fake.databaseOnDisk == bytes)
        #expect(speech.texts.isEmpty)
    }

    @Test("Removed tracks leave the database first and only then lose their files")
    func removesMusic() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let (session, _) = try makeSession(fake)
        let library = try await session.open()
        let victim = library.tracks[0]
        let file = fake.device.fileURL(devicePath: victim.record.path)
        let recording = fake.device.trackAnnouncementURL(id: victim.id)

        let after = await session.removeTracks([victim.id])
        #expect(after.tracks.count == 6)
        #expect(FileManager.default.fileExists(atPath: file.path), "nothing is deleted before the commit")

        let summary = try await session.commit(voiceOver: voice)
        #expect(summary.filesRemoved == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: recording.path))

        let database = try ShuffleDatabase(data: fake.databaseOnDisk)
        #expect(database.tracks.count == 6)
        #expect(!database.tracks.contains { $0.id == victim.id })
        // The playlist that held only that track (twice) is now empty and therefore gone from the database.
        #expect(database.playlists.count == 2)
        #expect(await session.verify().isEmpty)
    }

    @Test("Playlists can be created, filled, renamed and deleted")
    func managesPlaylists() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let speech = FakeSpeech()
        let (session, _) = try makeSession(fake, speech: speech)
        let library = try await session.open()
        let ids = library.tracks.map(\.id)

        let withPlaylist = await session.edit { library in
            let playlist = library.addPlaylist(named: "Road Trip")
            library.update(playlistID: playlist.id) { $0.trackIDs = [ids[2], ids[5], ids[2]] }
        }
        let created = try #require(withPlaylist.playlists.last?.id)
        try await session.commit(voiceOver: voice)

        var database = try ShuffleDatabase(data: fake.databaseOnDisk)
        #expect(database.playlists.count == 4)
        #expect(database.playlists[3].id == created)
        #expect(database.playlists[3].trackIndexes == [2, 5, 2])
        #expect(speech.texts == ["Road Trip"])
        let recording = fake.device.playlistAnnouncementURL(id: created)
        #expect(FileManager.default.fileExists(atPath: recording.path))

        await session.edit { $0.update(playlistID: created) { $0.name = "Summer" } }
        try await session.commit(voiceOver: voice)
        #expect(speech.texts == ["Road Trip", "Summer"])

        await session.removePlaylist(created)
        try await session.commit(voiceOver: voice)
        database = try ShuffleDatabase(data: fake.databaseOnDisk)
        #expect(database.playlists.count == 3)
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        #expect(try #require(try ManifestStore.load(from: fake.device)).playlists.count == 2)
    }

    @Test("A change made by another program is detected instead of overwritten")
    func detectsOutsideChanges() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let (session, _) = try makeSession(fake)
        try await session.open()
        await session.edit { $0.tracks[0].title = "Renamed here" }
        try await session.commit(voiceOver: voice)

        // Another program replaces the database while this session is still open.
        try Fixture.data(Fixture.deviceTested).write(to: fake.device.databaseURL)
        await session.edit { $0.addPlaylist(named: "Too late") }
        await #expect(throws: SessionError.changedElsewhere) { try await session.commit(voiceOver: voice) }
        #expect(fake.databaseOnDisk == (try Fixture.data(Fixture.deviceTested)))

        // Reloading picks up the other program's tracks and keeps what was known about the old ones.
        let (fresh, _) = try makeSession(fake)
        let library = try await fresh.open()
        #expect(library.tracks.count == 11)
        #expect(library.tracks[0].title == "Renamed here")
    }

    @Test("Play counts and resume positions recorded by the iPod are taken over, then the statistics are reset")
    func mergesStatistics() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let (setup, _) = try makeSession(fake)
        let initial = try await setup.open()
        await setup.edit { $0.tracks[2].remembersPosition = true }
        try await setup.commit(voiceOver: voice)

        // The iPod plays track 2 halfway and track 4 three times.
        var statistics = [UInt8](PlayStatistics.empty(trackCount: 7))
        func put(_ value: UInt32, entry: Int, field: Int) {
            let offset = 8 + 32 * entry + 4 * field
            for index in 0..<4 { statistics[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(8 * index)) }
        }
        put(90_000, entry: 2, field: 1)
        put(1, entry: 2, field: 2)
        put(3, entry: 4, field: 2)
        put(2, entry: 4, field: 4)
        try Data(statistics).write(to: fake.device.statisticsURL)

        let (session, _) = try makeSession(fake)
        let library = try await session.open()
        #expect(library.tracks[2].playCount == 1)
        #expect(library.tracks[2].record.bookmarkMs == 90_000)
        #expect(library.tracks[4].playCount == 3)
        #expect(library.tracks[4].skipCount == 2)
        #expect(library.tracks[4].record.bookmarkMs == 0, "only tracks that remember their position get a bookmark")
        #expect(library.tracks[0].playCount == initial.tracks[0].playCount)

        try await session.commit(voiceOver: voice)
        #expect(try Data(contentsOf: fake.device.statisticsURL) == PlayStatistics.empty(trackCount: 7))
        #expect(try ShuffleDatabase(data: fake.databaseOnDisk).tracks[2].bookmarkMs == 90_000)
        #expect(try #require(try ManifestStore.load(from: fake.device)).tracks[4].playCount == 3)

        // Opening again must not count the same plays twice.
        let (again, _) = try makeSession(fake)
        #expect(try await again.open().tracks[4].playCount == 3)
    }

    @Test("With VoiceOver off nothing is recorded and the database says so")
    func voiceOverDisabled() async throws {
        let fake = try FakeDevice()
        let speech = FakeSpeech()
        let (session, _) = try makeSession(fake, speech: speech)
        let sources = try TemporaryDirectory()
        let files = try audioFiles(in: sources)
        try await session.open()
        await session.edit { $0.voiceOverEnabled = false }
        _ = await session.addFiles([files.mp3])
        try await session.commit(voiceOver: voice)

        #expect(speech.texts.isEmpty)
        let database = try ShuffleDatabase(data: fake.databaseOnDisk)
        #expect(!database.voiceOverEnabled)
        #expect(database.tracks.count == 1)
        #expect(database.layout == .current)
    }

    @Test("Changing a title re-records its announcement; unspeakable titles are tried once")
    func announcementUpkeep() async throws {
        let fake = try FakeDevice()
        let speech = FakeSpeech(unspeakable: ["???"])
        let (session, _) = try makeSession(fake, speech: speech)
        let sources = try TemporaryDirectory()
        let files = try audioFiles(in: sources)
        try await session.open()
        _ = await session.addFiles([files.wav, files.mp3])
        try await session.commit(voiceOver: voice)
        #expect(speech.texts.count == 2)

        let library = await session.snapshot()
        await session.edit {
            $0.update(trackID: library.tracks[0].id) { $0.title = "New Name"; $0.artist = "Someone" }
            $0.update(trackID: library.tracks[1].id) { $0.title = "???" }
        }
        var summary = try await session.commit(voiceOver: voice)
        #expect(speech.texts.suffix(2) == ["New Name, Someone", "???"])
        #expect(summary.announcementsRecorded == 1)
        #expect(summary.announcementsFailed == 1)

        summary = try await session.commit(voiceOver: voice)
        #expect(speech.texts.count == 4, "nothing is retried when neither the text nor the voice changed")

        // An inherited recording is kept until the user asks for a new one.
        await session.edit { $0.update(trackID: library.tracks[0].id) { $0.announcement.rerecord = true } }
        try await session.commit(voiceOver: voice)
        #expect(speech.texts.last == "New Name, Someone")
        #expect(await session.snapshot().tracks[0].announcement.rerecord == false)
    }

    @Test("Files that cannot be imported are reported and do not stop the rest")
    func reportsUnusableFiles() async throws {
        let fake = try FakeDevice()
        let (session, _) = try makeSession(fake)
        let sources = try TemporaryDirectory()
        let files = try audioFiles(in: sources)
        let text = sources.url.appendingPathComponent("notes.mp3")
        try Data("not audio at all".utf8).write(to: text)
        try await session.open()

        let report = await session.addFiles([text, files.mp3, sources.url.appendingPathComponent("missing.wav")])
        #expect(report.added.count == 1)
        #expect(report.skipped.map(\.name) == ["notes.mp3", "missing.wav"])
        #expect(report.skipped.allSatisfy { !$0.reason.isEmpty })
    }

    @Test("Dropping a folder imports the audio inside it, in order, into the chosen playlist")
    func importsFolders() async throws {
        let fake = try FakeDevice()
        let (session, _) = try makeSession(fake)
        let sources = try TemporaryDirectory()
        let album = sources.url.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        for name in ["10 Ten.mp3", "2 Two.mp3", "1 One.mp3"] {
            try AudioFixtures.mp3(at: album.appendingPathComponent(name), frames: 10)
        }
        try Data("x".utf8).write(to: album.appendingPathComponent("cover.jpg"))
        try AudioFixtures.mp3(at: album.appendingPathComponent(".hidden.mp3"), frames: 10)
        try await session.open()

        let playlist = try #require(await session.edit { $0.addPlaylist(named: "Album") }.playlists.first)
        let report = await session.addFiles([album], toPlaylist: playlist.id)
        #expect(report.added.map(\.title) == ["1 One", "2 Two", "10 Ten"])

        let library = await session.snapshot()
        #expect(library.playlists[0].trackIDs == library.tracks.map(\.id))
        try await session.commit(voiceOver: voice)
        #expect(try ShuffleDatabase(data: fake.databaseOnDisk).playlists[1].trackIndexes == [0, 1, 2])
    }

    @Test("If the database is lost but the manifest survives, the next commit rebuilds it")
    func rebuildsLostDatabase() async throws {
        let fake = try FakeDevice()
        let (first, _) = try makeSession(fake)
        let sources = try TemporaryDirectory()
        let files = try audioFiles(in: sources)
        try await first.open()
        _ = await first.addFiles([files.wav, files.mp3])
        try await first.commit(voiceOver: voice)
        let bytes = fake.databaseOnDisk
        try FileManager.default.removeItem(at: fake.device.databaseURL)

        let (second, _) = try makeSession(fake)
        let library = try await second.open()
        #expect(library.tracks.count == 2)
        let summary = try await second.commit(voiceOver: voice)
        #expect(summary.databaseWritten)
        #expect(fake.databaseOnDisk == bytes)
    }

    @Test("Stray files are found and can be cleared without touching music in use")
    func cleansUpUnusedFiles() async throws {
        let fake = try FakeDevice(database: Fixture.appleSync)
        let (session, _) = try makeSession(fake)
        try await session.open()
        let stray = fake.device.musicDirectory.appendingPathComponent("F00/STRAY.mp3")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5_000).write(to: stray)
        let orphan = fake.device.trackAnnouncementURL(id: 0xDEAD)
        try Data(repeating: 1, count: 300).write(to: orphan)

        let unused = await session.unusedFiles()
        #expect(Set(unused.map(\.url.lastPathComponent)) == ["STRAY.mp3", orphan.lastPathComponent])
        #expect(await session.removeUnusedFiles() == 5_300)
        #expect(await session.unusedFiles().isEmpty)
        #expect(await session.verify().isEmpty)
    }

    @Test("A folder that is not an iPod is refused")
    func refusesOtherFolders() async throws {
        let directory = try TemporaryDirectory()
        let session = DeviceSession(device: ShuffleDevice(root: directory.url), speech: FakeSpeech(), backupRoot: directory.url)
        await #expect(throws: SessionError.notAnIPod) { try await session.open() }
    }
}
