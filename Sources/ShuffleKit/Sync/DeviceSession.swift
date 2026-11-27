import Foundation

public struct ImportProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case reading, converting, copying
    }

    /// Position of the current file in the batch, starting at 0.
    public var index: Int
    public var count: Int
    public var name: String
    public var phase: Phase
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public init(index: Int, count: Int, name: String, phase: Phase, bytesDone: Int64, bytesTotal: Int64) {
        self.index = index
        self.count = count
        self.name = name
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}

public struct ImportReport: Sendable {
    public struct Added: Sendable, Identifiable {
        public var id: UInt64
        public var title: String
        /// What was done to the file on the way, if it was not copied as it is.
        public var note: String?
    }

    public struct Skipped: Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var reason: String
    }

    public var added: [Added] = []
    public var skipped: [Skipped] = []
    public var cancelled = false

    public init() {}
}

public enum CommitProgress: Sendable, Equatable {
    case announcements(done: Int, total: Int)
    case writingDatabase
    case finishing
}

public struct CommitSummary: Sendable, Equatable {
    public var databaseWritten = false
    /// The app's own notes on the iPod (titles, playlist names) were saved.
    public var librarySaved = false
    public var announcementsRecorded = 0
    public var announcementsFailed = 0
    public var filesRemoved = 0
    /// Apple's library file, which Finder lists the iPod's songs from, was brought in step.
    public var appleLibraryWritten = false
    /// Why Apple's library file could not be brought in step, when it could not. The iPod plays regardless.
    public var appleLibraryProblem: String?
    /// Where the previous database was copied before the first change of this session.
    public var backup: URL?
}

/// How Apple's library file (`iTunesDB`) stands next to what is on the iPod.
public enum AppleLibraryStatus: Sendable, Equatable {
    /// The iPod has no such file, so there is nothing to keep in step.
    case absent
    case inStep
    /// The file lists other songs or playlists than the iPod holds. The next commit corrects that.
    case behind(AppleLibraryChanges)
    /// The file cannot be read, or is built in a way this app does not edit. It is left alone.
    case unreadable(String)
}

public struct UnusedFile: Sendable, Identifiable, Equatable {
    public var url: URL
    public var sizeBytes: Int64
    public var id: String { url.path }
}

public enum SessionError: ShuffleError, Equatable {
    case notAnIPod
    case changedElsewhere
    case verificationFailed

    public var description: String {
        switch self {
        case .notAnIPod:
            return "this folder is not an iPod (no iPod_Control folder)"
        case .changedElsewhere:
            return "the iPod's database was changed by another program while it was open here; reload before making changes"
        case .verificationFailed:
            return "the database read back from the iPod differs from what was written"
        }
    }
}

/// One open iPod. All reading and writing of the device goes through here, one operation at a time.
///
/// Opening never writes. Edits change the in-memory library; music files are copied in as they are
/// added; `commit` then records announcements, replaces the database in one step and only afterwards
/// deletes the files of removed tracks, so the database never points at something that is not there.
public actor DeviceSession {
    public nonisolated let device: ShuffleDevice

    private var library = Library()
    /// The library as it stood when nothing was pending: after opening, and after each commit.
    /// A commit that finds the library equal to this has nothing to save.
    private var baseline = Library()
    /// Digest of the database on the iPod as last seen; `nil` when there is none.
    private var expectedDigest: String?
    /// Track IDs in the order of the database on the iPod. Play statistics are indexed the same way.
    private var deviceTrackIDs: [UInt64] = []
    private var statisticsNeedReset = false
    private var pendingRemovals: [URL] = []
    /// Plays and skips taken over from the iPod that Apple's library file has not been told about yet.
    private var unreportedActivity: [UInt64: PlayActivity] = [:]
    /// Playlists deleted here that may still have a record in Apple's library file.
    private var deletedPlaylists = Set<UInt64>()
    /// True when the library came from this app's own notes, which means this app wrote the iPod last.
    private var openedFromManifest = false
    private var backupURL: URL?
    private let speech: any SpeechProvider
    private let backupRoot: URL

    /// Free space kept aside for the database and announcements.
    private static let reservedBytes: Int64 = 4 << 20
    private static let musicFolders = ["F00", "F01", "F02"]

    public init(device: ShuffleDevice, speech: any SpeechProvider = SystemSpeech(), backupRoot: URL? = nil) {
        self.device = device
        self.speech = speech
        self.backupRoot = backupRoot ?? DeviceSession.defaultBackupRoot
    }

    /// `~/Library/Application Support/Shuffler/Backups`, unless `SHUFFLER_BACKUP_DIR` points elsewhere.
    public static var defaultBackupRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SHUFFLER_BACKUP_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Shuffler/Backups", isDirectory: true)
    }

    // MARK: Opening

    /// Loads the library: from this app's manifest when it still matches the database, otherwise by
    /// importing whatever is on the iPod.
    @discardableResult
    public func open() async throws -> Library {
        guard ShuffleDevice.isDevice(at: device.root) else { throw SessionError.notAnIPod }
        let manifest = try ManifestStore.load(from: device)
        let databaseData = try? Data(contentsOf: device.databaseURL)
        let digest = databaseData.map(FileOps.sha256)

        if var manifest, databaseData == nil || manifest.databaseDigest == digest {
            if databaseData == nil {
                // The database is gone but the manifest survived: rebuild from it, minus anything whose file is gone too.
                let lost = manifest.tracks.filter { !FileOps.exists(device.fileURL(devicePath: $0.record.path)) }
                manifest.removeTracks(Set(lost.map(\.id)))
            }
            library = manifest
            openedFromManifest = true
        } else {
            library = try await DeviceImporter.importLibrary(from: device, previous: manifest) { url in
                try? await MediaProbe.probe(url).tags
            }
            openedFromManifest = false
        }
        expectedDigest = digest
        deviceTrackIDs = databaseData == nil ? [] : library.tracks.map(\.id)
        pendingRemovals = []
        unreportedActivity = [:]
        deletedPlaylists = []
        statisticsNeedReset = mergeStatistics()
        baseline = library
        return library
    }

    public func snapshot() -> Library { library }

    // MARK: Editing

    /// Applies a change to the library (rename, reorder, playlist membership, playback options).
    @discardableResult
    public func edit(_ change: @Sendable (inout Library) -> Void) -> Library {
        change(&library)
        library.normalize()
        return library
    }

    /// Takes tracks out of the library. Their files are deleted by the next `commit`.
    @discardableResult
    public func removeTracks(_ ids: Set<UInt64>) -> Library {
        for track in library.tracks where ids.contains(track.id) {
            pendingRemovals.append(device.fileURL(devicePath: track.record.path))
            pendingRemovals.append(device.trackAnnouncementURL(id: track.id))
        }
        library.removeTracks(ids)
        return library
    }

    @discardableResult
    public func removePlaylist(_ id: UInt64) -> Library {
        guard library.playlists.contains(where: { $0.id == id }) else { return library }
        pendingRemovals.append(device.playlistAnnouncementURL(id: id))
        deletedPlaylists.insert(id)
        library.playlists.removeAll { $0.id == id }
        return library
    }

    // MARK: Adding music

    /// Copies files (and the audio files inside folders) onto the iPod, converting what it cannot play.
    /// The tracks join the library at once; call `commit` afterwards so the iPod knows about them.
    public func addFiles(
        _ urls: [URL], toPlaylist playlistID: UInt64? = nil, settings: ImportSettings = ImportSettings(),
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async -> ImportReport {
        var report = ImportReport()
        let files = Self.expand(urls)
        do {
            try device.ensureDirectories()
        } catch {
            report.skipped = files.map { .init(name: $0.lastPathComponent, reason: "\(error)") }
            return report
        }

        for (index, url) in files.enumerated() {
            if Task.isCancelled {
                report.cancelled = true
                break
            }
            do {
                let (track, note) = try await importFile(url, settings: settings) { phase, done, total in
                    progress?(ImportProgress(
                        index: index, count: files.count, name: url.lastPathComponent, phase: phase, bytesDone: done, bytesTotal: total
                    ))
                }
                library.add(track, toPlaylist: playlistID)
                report.added.append(.init(id: track.id, title: track.title, note: note))
            } catch is CancellationError {
                report.cancelled = true
                break
            } catch {
                report.skipped.append(.init(name: url.lastPathComponent, reason: Self.describe(error)))
            }
        }
        return report
    }

    private func importFile(
        _ url: URL, settings: ImportSettings, progress: @escaping @Sendable (ImportProgress.Phase, Int64, Int64) -> Void
    ) async throws -> (Track, String?) {
        progress(.reading, 0, 0)
        let info = try await MediaProbe.probe(url)
        let wavLayout = info.container == .wav ? try? WAVFile.inspect(url) : nil
        let fastStart = info.container == .mpeg4 ? MP4File.isFastStart(url) : true
        let plan = try ImportPlanner.plan(for: info, isFastStart: fastStart, wavFormat: wavLayout?.format, settings: settings)

        // Work out what will actually be copied; conversions happen in a scratch folder on the Mac first.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Shuffler-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var payload = url
        var frames: Int64?
        var sampleRate = info.sampleRate
        switch plan.action {
        case .copy:
            break
        case .rewrapWAV:
            frames = wavLayout?.frameCount
        case .remux:
            progress(.converting, 0, 0)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            payload = scratch.appendingPathComponent("audio.m4a")
            try await Transcoder.remux(source: url, destination: payload)
        case let .convert(target):
            progress(.converting, 0, 0)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            payload = scratch.appendingPathComponent("audio." + target.fileExtension)
            let result = try await Transcoder.convert(source: url, to: target, destination: payload)
            sampleRate = result.sampleRate
            if target == .wav16 { frames = result.frames }
        }

        let payloadSize: Int64
        if case .rewrapWAV = plan.action, let wavLayout {
            payloadSize = Int64(WAVFile.headerLength) + wavLayout.dataLength
        } else {
            payloadSize = FileOps.fileSize(payload) ?? 0
        }
        if let capacity = device.capacity(), capacity.available < payloadSize + Self.reservedBytes {
            throw ImportError.notEnoughSpace(needed: payloadSize, available: max(0, capacity.available - Self.reservedBytes))
        }

        let destination = try freeMusicURL(fileExtension: plan.fileExtension)
        progress(.copying, 0, payloadSize)
        if case .rewrapWAV = plan.action, let wavLayout {
            try WAVFile.rewrap(source: url, layout: wavLayout, to: destination) { progress(.copying, $0, payloadSize) }
        } else {
            try FileOps.copy(from: payload, to: destination) { progress(.copying, $0, payloadSize) }
        }

        let size = FileOps.fileSize(destination) ?? payloadSize
        let title = info.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? VoiceOverSettings.tidy(url.deletingPathExtension().lastPathComponent)
        let artist = info.artist ?? ""
        let album = info.album ?? ""

        var record = TrackRecord(
            id: library.makeID(), path: device.devicePath(for: destination) ?? "", fileType: plan.fileType,
            stopMs: UInt32(clamping: info.durationMs)
        )
        // Apple's sync stores the exact length of uncompressed audio in samples.
        if plan.fileType == FileTypeCode.wav, let frames { record.sampleCount = UInt32(clamping: frames) }
        record.trackNumber = UInt16(clamping: info.trackNumber ?? 0)
        record.discNumber = UInt16(clamping: info.discNumber ?? 0)
        record.albumID = groupID(for: album, existing: { ($0.album, $0.record.albumID) })
        record.artistID = groupID(for: artist, existing: { ($0.artist, $0.record.artistID) })

        let converted = plan.action != .copy && plan.action != .rewrapWAV
        let track = Track(
            record: record, title: title, artist: artist, album: album, genre: info.genre ?? "", kind: plan.kind,
            durationMs: info.durationMs, sizeBytes: size,
            bitrateKbps: converted && info.durationMs > 0 ? Int(Double(size) * 8 / Double(info.durationMs)) : info.bitrateKbps,
            // Whole seconds, which is what the manifest's date format keeps.
            sampleRate: sampleRate, dateAdded: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        return (track, plan.note)
    }

    /// Tracks with the same album (or artist) name share a number in the database; a new name gets a new number.
    private func groupID(for name: String, existing: (Track) -> (String, UInt32)) -> UInt32 {
        guard !name.isEmpty else { return 0 }
        var highest: UInt32 = 0
        for track in library.tracks {
            let (otherName, id) = existing(track)
            if otherName.caseInsensitiveCompare(name) == .orderedSame, id != 0 { return id }
            highest = max(highest, id)
        }
        return highest + 1
    }

    /// A short random name in the least full of Apple's music folders, like `F01/QXBT.m4a`.
    private func freeMusicURL(fileExtension: String) throws -> URL {
        let manager = FileManager.default
        let folders = Self.musicFolders.map { device.musicDirectory.appendingPathComponent($0, isDirectory: true) }
        for folder in folders { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        let folder = folders.min { first, second in
            ((try? manager.contentsOfDirectory(atPath: first.path))?.count ?? 0)
                < ((try? manager.contentsOfDirectory(atPath: second.path))?.count ?? 0)
        } ?? folders[0]

        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for _ in 0..<200 {
            let name = String((0..<4).map { _ in letters.randomElement()! })
            // The name must be free in every folder regardless of extension, so a track is findable by name alone.
            let taken = folders.contains { other in
                ((try? manager.contentsOfDirectory(atPath: other.path)) ?? []).contains { $0.uppercased().hasPrefix(name + ".") }
            }
            if !taken { return folder.appendingPathComponent("\(name).\(fileExtension)") }
        }
        throw ImportError.nameCollision
    }

    /// Folders become the audio files inside them, in a stable, human order.
    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.append(url)
                continue
            }
            guard isDirectory.boolValue else {
                result.append(url)
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            var inside: [URL] = []
            while let item = enumerator?.nextObject() as? URL {
                if MediaProbe.audioExtensions.contains(item.pathExtension.lowercased()) { inside.append(item) }
            }
            result.append(contentsOf: inside.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        error.localizedDescription
    }

    // MARK: Committing

    /// Makes the iPod match the library: records missing or outdated announcements, replaces the
    /// database, resets the play statistics, brings Apple's library file in step, deletes files of
    /// removed tracks and saves the manifest. Does nothing at all when nothing changed.
    @discardableResult
    public func commit(
        voiceOver settings: VoiceOverSettings, progress: (@Sendable (CommitProgress) -> Void)? = nil
    ) async throws -> CommitSummary {
        var summary = CommitSummary()
        let onDevice = try? Data(contentsOf: device.databaseURL)
        guard onDevice.map(FileOps.sha256) == expectedDigest else { throw SessionError.changedElsewhere }

        try device.ensureDirectories()
        library.normalize()

        if library.voiceOverEnabled {
            let (recorded, failed) = await recordAnnouncements(settings: settings, progress: progress)
            summary.announcementsRecorded = recorded
            summary.announcementsFailed = failed
        }

        progress?(.writingDatabase)
        let bytes = try library.makeDatabase().encoded()
        if onDevice != bytes {
            try backupIfNeeded()
            try FileOps.atomicWrite(bytes, to: device.databaseURL)
            guard (try? Data(contentsOf: device.databaseURL)) == bytes else { throw SessionError.verificationFailed }
            summary.databaseWritten = true
        }
        let digest = FileOps.sha256(bytes)
        expectedDigest = digest

        // The statistics are indexed by position in the track table, so they are only valid for the database
        // they were recorded against. Apple's sync leaves an empty file of the right size; so do we.
        var mustSave = summary.databaseWritten
        if summary.databaseWritten || statisticsNeedReset {
            try FileOps.atomicWrite(PlayStatistics.empty(trackCount: library.tracks.count), to: device.statisticsURL)
            statisticsNeedReset = false
            mustSave = true
        }
        deviceTrackIDs = library.tracks.map(\.id)

        // A playlist can also disappear through `edit`; whichever way it went, its record should go too.
        deletedPlaylists.formUnion(baseline.playlists.map(\.id))
        deletedPlaylists.subtract(library.playlists.map(\.id))
        updateAppleLibrary(&summary)

        progress?(.finishing)
        // The database no longer mentions these, so they can go. Anything still referenced stays.
        let stillUsed = Set(library.tracks.map { device.fileURL(devicePath: $0.record.path).path.lowercased() })
            .union(library.tracks.map { device.trackAnnouncementURL(id: $0.id).path.lowercased() })
            .union(library.playlists.map { device.playlistAnnouncementURL(id: $0.id).path.lowercased() })
        for url in pendingRemovals where !stillUsed.contains(url.path.lowercased()) {
            if FileOps.exists(url) { summary.filesRemoved += 1 }
            FileOps.remove(url)
        }
        pendingRemovals = []

        library.databaseDigest = digest
        if mustSave || library != baseline {
            try ManifestStore.save(library, to: device)
            summary.librarySaved = true
        }
        baseline = library
        summary.backup = backupURL
        return summary
    }

    // MARK: Apple's library file

    /// Rewrites Apple's library file when it lists something else than the library does. A failure here
    /// is reported, not thrown: the iPod plays from the database, which is already in place.
    private func updateAppleLibrary(_ summary: inout CommitSummary) {
        guard let current = try? Data(contentsOf: device.appleLibraryURL) else {
            deletedPlaylists = []
            unreportedActivity = [:]
            return
        }
        do {
            let updated = try AppleLibraryMirror.mirror(
                current, to: library, removedPlaylists: deletedPlaylists, activity: unreportedActivity
            ).data
            if updated != current {
                try backupIfNeeded()
                try FileOps.atomicWrite(updated, to: device.appleLibraryURL)
                guard (try? Data(contentsOf: device.appleLibraryURL)) == updated else { throw SessionError.verificationFailed }
                summary.appleLibraryWritten = true
            }
            deletedPlaylists = []
            unreportedActivity = [:]
        } catch {
            summary.appleLibraryProblem = Self.describe(error)
        }
    }

    /// Compares Apple's library file with the library as it stands, pending edits included. Reads only.
    public func appleLibraryStatus() -> AppleLibraryStatus {
        guard let current = try? Data(contentsOf: device.appleLibraryURL) else { return .absent }
        do {
            let result = try AppleLibraryMirror.mirror(current, to: library, removedPlaylists: deletedPlaylists)
            return result.data == current ? .inStep : .behind(result.changes)
        } catch {
            return .unreadable(Self.describe(error))
        }
    }

    /// True when this app wrote the iPod last and left Apple's library file behind, as its first builds
    /// always did. Catching up is then unfinished business of this app rather than a new change, so the
    /// app does it on opening. On an iPod this app has not written, nothing happens unasked.
    public func appleLibraryNeedsCatchUp() -> Bool {
        guard openedFromManifest, case .behind = appleLibraryStatus() else { return false }
        return true
    }

    /// Adds what the iPod recorded since the last sync to the library. Returns whether there was anything.
    private func mergeStatistics() -> Bool {
        guard let data = try? Data(contentsOf: device.statisticsURL), let statistics = try? PlayStatistics(data: data),
              statistics.hasActivity, statistics.entries.count == deviceTrackIDs.count else { return false }
        for (index, entry) in statistics.entries.enumerated() where !entry.isEmpty {
            if entry.playCount > 0 || entry.skipCount > 0 {
                unreportedActivity[deviceTrackIDs[index]] = PlayActivity(
                    plays: entry.playCount, skips: entry.skipCount, lastPlayed: entry.lastPlayed, lastSkipped: entry.lastSkipped
                )
            }
            library.update(trackID: deviceTrackIDs[index]) { track in
                track.playCount += Int(entry.playCount)
                track.skipCount += Int(entry.skipCount)
                if let played = PlayStatistics.date(fromDeviceTime: entry.lastPlayed) {
                    track.lastPlayed = max(track.lastPlayed ?? played, played)
                }
                if track.remembersPosition {
                    if entry.bookmarkMs != 0 {
                        track.record.bookmarkMs = entry.bookmarkMs
                    } else if entry.playCount > 0 {
                        track.record.bookmarkMs = 0   // played to the end
                    }
                }
            }
        }
        return true
    }

    // MARK: Announcements

    private struct AnnouncementJob {
        enum Target { case track(UInt64), playlist(UInt64) }
        var target: Target
        var url: URL
        var text: String
        var language: String
        var key: String
    }

    private func recordAnnouncements(
        settings: VoiceOverSettings, progress: (@Sendable (CommitProgress) -> Void)?
    ) async -> (recorded: Int, failed: Int) {
        var jobs: [AnnouncementJob] = []
        for track in library.tracks {
            let text = settings.spokenText(for: track)
            let language = settings.language(for: text, override: track.spokenLanguage)
            let url = device.trackAnnouncementURL(id: track.id)
            if needsRecording(track.announcement, text: text, key: settings.renderKey(language: language), url: url) {
                jobs.append(.init(target: .track(track.id), url: url, text: text, language: language, key: settings.renderKey(language: language)))
            }
        }
        for playlist in library.playlists where !playlist.trackIDs.isEmpty {
            let text = settings.spokenText(for: playlist)
            let language = settings.language(for: text, override: playlist.spokenLanguage)
            let url = device.playlistAnnouncementURL(id: playlist.id)
            if needsRecording(playlist.announcement, text: text, key: settings.renderKey(language: language), url: url) {
                jobs.append(.init(target: .playlist(playlist.id), url: url, text: text, language: language, key: settings.renderKey(language: language)))
            }
        }

        var recorded = 0
        var failed = 0
        for (index, job) in jobs.enumerated() {
            if Task.isCancelled { break }
            progress?(.announcements(done: index, total: jobs.count))
            var result = Announcement(state: .missing, text: job.text, voice: job.key)
            do {
                let speech = try await speech.render(text: job.text, voiceID: settings.voiceID(for: job.language), language: job.language)
                try FileOps.atomicWrite(speech.wavFile, to: job.url)
                result.state = .generated
                recorded += 1
            } catch {
                // Remembering the attempt (text and voice) keeps an unspeakable title from being retried on every sync.
                failed += 1
            }
            switch job.target {
            case let .track(id): library.update(trackID: id) { $0.announcement = result }
            case let .playlist(id): library.update(playlistID: id) { $0.announcement = result }
            }
        }
        return (recorded, failed)
    }

    private func needsRecording(_ announcement: Announcement, text: String, key: String, url: URL) -> Bool {
        if announcement.rerecord { return true }
        let upToDate = announcement.text == text && announcement.voice == key
        switch announcement.state {
        case .missing:
            return !upToDate            // already tried with this text and voice: nothing more to do
        case .inherited:
            return !FileOps.exists(url)
        case .generated:
            return !upToDate || !FileOps.exists(url)
        }
    }

    // MARK: Backups

    /// Copies the files about to be replaced to the Mac, once per session, before the first change.
    private func backupIfNeeded() throws {
        guard backupURL == nil else { return }
        let playState = device.databaseDirectory.appendingPathComponent("iTunesPState")
        let sources = [device.databaseURL, device.statisticsURL, playState, device.appleLibraryURL, device.manifestURL]
            .filter(FileOps.exists)
        guard !sources.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let deviceFolder = backupRoot.appendingPathComponent(device.backupKey, isDirectory: true)
        var folder = deviceFolder.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        var suffix = 1
        while FileOps.exists(folder) {
            suffix += 1
            folder = deviceFolder.appendingPathComponent("\(formatter.string(from: Date())) (\(suffix))", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for source in sources {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        }
        backupURL = folder

        // Keep the 20 most recent backups per iPod.
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: deviceFolder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in all.dropLast(20) {
            try? FileManager.default.removeItem(at: deviceFolder.appendingPathComponent(old))
        }
    }

    // MARK: Maintenance

    /// Problems found by comparing the database on the iPod with the files that are there. Empty means healthy.
    public func verify() -> [String] {
        guard let data = try? Data(contentsOf: device.databaseURL) else { return ["there is no database on the iPod"] }
        let database: ShuffleDatabase
        do {
            database = try ShuffleDatabase(data: data)
        } catch {
            return ["the database cannot be read: \(Self.describe(error))"]
        }
        var problems: [String] = []
        for (index, track) in database.tracks.enumerated() {
            if !FileOps.exists(device.fileURL(devicePath: track.path)) {
                problems.append("track \(index + 1) points at a missing file: \(track.path)")
            }
            if database.voiceOverEnabled, !FileOps.exists(device.trackAnnouncementURL(id: track.id)) {
                problems.append("track \(index + 1) has no announcement: \(track.path)")
            }
        }
        if !database.playlists.contains(where: { $0.kind == PlaylistRecord.Kind.master }) {
            problems.append("there is no \"All Songs\" list")
        }
        for (index, playlist) in database.playlists.enumerated() where playlist.kind != PlaylistRecord.Kind.master {
            if playlist.id != 0, !FileOps.exists(device.playlistAnnouncementURL(id: playlist.id)) {
                problems.append("playlist \(index) has no announcement")
            }
        }
        if data.count != (try? database.encoded().count) {
            problems.append("the database has an unusual structure (it would be rewritten differently)")
        }
        switch appleLibraryStatus() {
        case .absent, .inStep:
            break
        case let .behind(changes):
            problems.append("Apple's library file, which Finder shows, is out of step: \(changes.pendingSummary)")
        case let .unreadable(reason):
            problems.append("Apple's library file, which Finder shows, cannot be kept in step: \(reason)")
        }
        return problems
    }

    /// Music files and announcements on the iPod that nothing refers to: left behind by other software,
    /// an interrupted copy, or a sync that replaced the database.
    public func unusedFiles() -> [UnusedFile] {
        let manager = FileManager.default
        var unused: [UnusedFile] = []
        let used = Set(library.tracks.map { device.fileURL(devicePath: $0.record.path).path.lowercased() })
            .union(pendingRemovals.map { $0.path.lowercased() })

        if let enumerator = manager.enumerator(at: device.musicDirectory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            while let url = enumerator.nextObject() as? URL {
                guard !url.lastPathComponent.hasPrefix("."), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if !used.contains(url.standardizedFileURL.path.lowercased()) {
                    unused.append(UnusedFile(url: url, sizeBytes: FileOps.fileSize(url) ?? 0))
                }
            }
        }
        let trackIDs = Set(library.tracks.map { $0.id.hexID })
        let playlistIDs = Set(library.playlists.map { $0.id.hexID } + [library.masterPlaylistID.hexID])
        for (folder, known) in [(device.trackAnnouncementsDirectory, trackIDs), (device.playlistAnnouncementsDirectory, playlistIDs)] {
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.lowercased().hasSuffix(".wav") && !name.hasPrefix(".") {
                let id = String(name.dropLast(4)).uppercased()
                if !known.contains(id) {
                    let url = folder.appendingPathComponent(name)
                    unused.append(UnusedFile(url: url, sizeBytes: FileOps.fileSize(url) ?? 0))
                }
            }
        }
        return unused.sorted { $0.url.path < $1.url.path }
    }

    /// Deletes what `unusedFiles()` lists. Returns the number of bytes freed.
    @discardableResult
    public func removeUnusedFiles() -> Int64 {
        var freed: Int64 = 0
        for file in unusedFiles() {
            FileOps.remove(file.url)
            freed += file.sizeBytes
        }
        return freed
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
