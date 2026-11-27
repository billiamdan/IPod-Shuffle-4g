import AppKit
import AVFoundation
import Observation
import ShuffleKit
import SwiftUI

/// Everything the window shows, and every action it can take. All work on the iPod is handed to
/// a `DeviceSession`; this type keeps the on-screen copy of the library and decides when to save.
@MainActor
@Observable
final class AppModel {
    enum Activity: Equatable {
        case opening
        case importing(ImportProgress)
        case saving(String)
    }

    struct AlertInfo: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    // MARK: State

    private(set) var devices: [ShuffleDevice] = []
    private(set) var device: ShuffleDevice?
    private(set) var capacity: ShuffleDevice.Capacity?
    private(set) var library = Library()
    private(set) var unusedFiles: [UnusedFile] = []

    var sidebarSelection: SidebarItem = .allSongs {
        didSet { if oldValue != sidebarSelection { selection = [] } }
    }
    var selection: Set<TrackRow.ID> = []
    var searchText = ""
    var showInspector = false
    var renamingPlaylist: UInt64?

    private(set) var activity: Activity?
    private(set) var hasUnsavedChanges = false
    private(set) var statusMessage: String?
    var importReport: ImportReport?
    var alert: AlertInfo?
    var confirmingCleanup = false
    /// Set to open the Settings window from code (used by the snapshot aid).
    var settingsRequested = false

    var voiceSettings: VoiceOverSettings {
        didSet {
            guard voiceSettings != oldValue else { return }
            Self.store(voiceSettings, key: "voiceOverSettings")
            if session != nil { markChanged() }
        }
    }
    var importSettings: ImportSettings {
        didSet { Self.store(importSettings, key: "importSettings") }
    }

    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var manualDevice: ShuffleDevice?
    @ObservationIgnored private var pendingEdits = 0
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var commitRequestedAgain = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var sound: NSSound?
    @ObservationIgnored private let previewSynthesizer = AVSpeechSynthesizer()

    init() {
        var voice = Self.load(VoiceOverSettings.self, key: "voiceOverSettings") ?? VoiceOverSettings.systemDefault()
        voice.installedLanguages = SystemSpeech.languages()
        voiceSettings = voice
        importSettings = Self.load(ImportSettings.self, key: "importSettings") ?? ImportSettings()
    }

    // MARK: Devices

    /// Starts watching for iPods being connected and removed.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rescanDevices() }
            })
        }
        // A folder can stand in for an iPod: handy for trying things out without the device.
        if let path = ProcessInfo.processInfo.environment["SHUFFLER_DEVICE"], ShuffleDevice.isDevice(at: URL(fileURLWithPath: path)) {
            manualDevice = ShuffleDevice(root: URL(fileURLWithPath: path))
        }
        rescanDevices()
    }

    func rescanDevices() {
        var found = DeviceLocator.mountedDevices()
        if let manualDevice, ShuffleDevice.isDevice(at: manualDevice.root), !found.contains(manualDevice) {
            found.insert(manualDevice, at: 0)
        }
        devices = found
        if let device, !found.contains(device) { closeDevice() }
        if device == nil, let first = found.first {
            Task { await open(first) }
        } else {
            refreshCapacity()
        }
    }

    func open(_ target: ShuffleDevice) async {
        closeDevice()
        device = target
        activity = .opening
        let session = DeviceSession(device: target)
        do {
            let library = try await session.open()
            guard device == target else { return }
            self.session = session
            self.library = library
            sidebarSelection = .allSongs
            refreshCapacity()
            unusedFiles = await session.unusedFiles()
        } catch {
            device = nil
            alert = AlertInfo(title: "“\(target.name)” could not be opened", message: error.localizedDescription)
        }
        activity = nil
    }

    func reload() {
        guard let device else { return }
        Task { await open(device) }
    }

    /// Lets the user pick a folder laid out like an iPod (a copy, or a volume that was not detected).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose an iPod, or a folder that contains “iPod_Control”."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ShuffleDevice.isDevice(at: url) else {
            alert = AlertInfo(title: "That is not an iPod", message: "The folder has no “iPod_Control” folder inside it.")
            return
        }
        let chosen = ShuffleDevice(root: url)
        manualDevice = chosen
        if !devices.contains(chosen) { devices.insert(chosen, at: 0) }
        Task { await open(chosen) }
    }

    private func closeDevice() {
        debounce?.cancel()
        debounce = nil
        importTask?.cancel()
        session = nil
        device = nil
        library = Library()
        selection = []
        unusedFiles = []
        capacity = nil
        activity = nil
        hasUnsavedChanges = false
        statusMessage = nil
        pendingEdits = 0
    }

    private func refreshCapacity() {
        capacity = device?.capacity()
    }

    func eject() {
        guard let device else { return }
        Task {
            await finishPendingWork()
            if device.isVolume {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: device.root)
                } catch {
                    alert = AlertInfo(title: "“\(device.name)” could not be ejected", message: error.localizedDescription)
                    return
                }
            } else {
                manualDevice = nil
            }
            closeDevice()
            rescanDevices()
        }
    }

    /// Stops an import in progress and writes everything that is still pending. Used before ejecting and quitting.
    func finishPendingWork() async {
        debounce?.cancel()
        debounce = nil
        if let importTask {
            importTask.cancel()
            await importTask.value
        }
        if hasUnsavedChanges { startCommit() }
        while let commitTask { await commitTask.value }
    }

    var needsToFinishBeforeQuit: Bool { hasUnsavedChanges || commitTask != nil || importTask != nil }

    /// Returns once nothing is being copied, edited or saved. Used by the scripted run in `Snapshot`.
    func waitUntilIdle() async {
        while importTask != nil || commitTask != nil || hasUnsavedChanges || pendingEdits > 0 || activity != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: What is on screen

    var currentPlaylist: Playlist? { sidebarSelection.playlistID.flatMap { library.playlist($0) } }

    var rows: [TrackRow] {
        let all = TrackRow.rows(for: library.tracks(in: sidebarSelection.playlistID))
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.track.title.localizedCaseInsensitiveContains(query) || $0.track.artist.localizedCaseInsensitiveContains(query)
                || $0.track.album.localizedCaseInsensitiveContains(query)
        }
    }

    var canReorder: Bool { searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func tracks(for rowIDs: Set<TrackRow.ID>) -> [Track] {
        rows.filter { rowIDs.contains($0.id) }.map(\.track)
    }

    var selectedTracks: [Track] { tracks(for: selection) }

    /// The single track the inspector edits, read fresh from the library so edits show at once.
    var inspectedTrack: Track? {
        let selected = selectedTracks
        guard selected.count == 1 else { return nil }
        return library.track(selected[0].id)
    }

    // MARK: Editing

    /// Applies a change on screen at once and to the session in the background, then saves shortly after.
    func edit(_ change: @escaping @Sendable (inout Library) -> Void) {
        guard let session else { return }
        var copy = library
        change(&copy)
        copy.normalize()
        library = copy
        pendingEdits += 1
        Task {
            let result = await session.edit(change)
            self.finishEdit(session, result)
        }
    }

    private func finishEdit(_ session: DeviceSession, _ result: Library) {
        guard self.session === session else { return }
        pendingEdits -= 1
        // Only adopt the session's copy once it has caught up with everything typed so far.
        if pendingEdits == 0 { library = result }
        markChanged()
    }

    private func markChanged() {
        hasUnsavedChanges = true
        statusMessage = nil
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.startCommit()
        }
    }

    func update(trackID: UInt64, _ change: @escaping @Sendable (inout Track) -> Void) {
        edit { $0.update(trackID: trackID, change) }
    }

    func update(trackIDs: [UInt64], _ change: @escaping @Sendable (inout Track) -> Void) {
        edit { library in
            for id in trackIDs { library.update(trackID: id, change) }
        }
    }

    func setVoiceOverEnabled(_ enabled: Bool) {
        edit { $0.voiceOverEnabled = enabled }
    }

    /// Records announcements again: for the given tracks, or for everything when `trackIDs` is nil.
    func rerecordAnnouncements(trackIDs: [UInt64]? = nil) {
        edit { library in
            for index in library.tracks.indices where trackIDs?.contains(library.tracks[index].id) ?? true {
                library.tracks[index].announcement.rerecord = true
            }
            if trackIDs == nil {
                for index in library.playlists.indices { library.playlists[index].announcement.rerecord = true }
            }
        }
    }

    // MARK: Music

    func addFiles(_ urls: [URL], to playlistID: UInt64? = nil) {
        guard let session, importTask == nil, !urls.isEmpty else { return }
        let settings = importSettings
        hasUnsavedChanges = true
        statusMessage = nil
        activity = .importing(ImportProgress(index: 0, count: urls.count, name: "", phase: .reading, bytesDone: 0, bytesTotal: 0))
        importTask = Task { [weak self] in
            let report = await session.addFiles(urls, toPlaylist: playlistID, settings: settings) { progress in
                Task { @MainActor in
                    guard let self, self.importTask != nil else { return }
                    self.activity = .importing(progress)
                }
            }
            guard let self else { return }
            self.importTask = nil
            guard self.session === session else { return }
            self.library = await session.snapshot()
            self.activity = nil
            self.refreshCapacity()
            if !report.skipped.isEmpty || report.added.contains(where: { $0.note != nil }) {
                self.importReport = report
            }
            self.startCommit()
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.message = "Choose songs or folders to copy to the iPod."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls, to: sidebarSelection.playlistID)
    }

    func removeFromDevice(_ ids: Set<UInt64>) {
        guard let session, !ids.isEmpty else { return }
        library.removeTracks(ids)
        selection = []
        pendingEdits += 1
        Task {
            let result = await session.removeTracks(ids)
            self.finishEdit(session, result)
        }
    }

    /// Takes the selected rows out of the playlist being shown; the songs stay on the iPod.
    func removeFromPlaylist(rowIDs: Set<TrackRow.ID>) {
        guard let playlistID = sidebarSelection.playlistID else { return }
        let positions = Set(rows.filter { rowIDs.contains($0.id) }.map(\.position))
        selection = []
        edit { library in
            library.update(playlistID: playlistID) { playlist in
                playlist.trackIDs = playlist.trackIDs.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
            }
        }
    }

    func sortAllSongs(by key: SortKey) {
        let order = key.sorted(library.tracks(in: nil)).map(\.id)
        edit { $0.allSongsOrder = order }
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(with trackIDs: [UInt64] = []) -> UInt64 {
        var name = "New Playlist"
        var suffix = 2
        while library.playlists.contains(where: { $0.name == name }) {
            name = "New Playlist \(suffix)"
            suffix += 1
        }
        let id = library.makeID()
        let playlist = Playlist(id: id, name: name, trackIDs: trackIDs)
        edit { $0.playlists.append(playlist) }
        sidebarSelection = .playlist(id)
        renamingPlaylist = id
        return id
    }

    func renamePlaylist(_ id: UInt64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, library.playlist(id)?.name != trimmed else { return }
        edit { $0.update(playlistID: id) { $0.name = trimmed } }
    }

    func deletePlaylist(_ id: UInt64) {
        guard let session else { return }
        if sidebarSelection == .playlist(id) { sidebarSelection = .allSongs }
        library.playlists.removeAll { $0.id == id }
        pendingEdits += 1
        Task {
            let result = await session.removePlaylist(id)
            self.finishEdit(session, result)
        }
    }

    func addTracks(_ ids: [UInt64], toPlaylist playlistID: UInt64) {
        guard !ids.isEmpty else { return }
        edit { $0.update(playlistID: playlistID) { $0.trackIDs.append(contentsOf: ids) } }
    }

    // MARK: Drag and drop

    func dragPayload(for row: TrackRow) -> TrackDrag {
        let dragged = selection.contains(row.id) ? rows.filter { selection.contains($0.id) } : [row]
        return TrackDrag(trackIDs: dragged.map(\.track.id), rowIDs: dragged.map(\.id), source: sidebarSelection)
    }

    /// Handles tracks dropped between rows of the list being shown: a reorder, or an insert from another list.
    func handleDrop(_ drags: [TrackDrag], at offset: Int) {
        guard canReorder, let drag = drags.first else { return }
        let target = sidebarSelection
        let all = TrackRow.rows(for: library.tracks(in: target.playlistID))
        var order = all.map(\.track.id)

        if drag.source == target {
            let moving = IndexSet(all.filter { drag.rowIDs.contains($0.id) }.map(\.position))
            guard !moving.isEmpty else { return }
            order.move(fromOffsets: moving, toOffset: min(offset, order.count))
        } else if target.playlistID != nil {
            order.insert(contentsOf: drag.trackIDs, at: min(offset, order.count))
        } else {
            return
        }
        let newOrder = order
        edit { library in
            if let playlistID = target.playlistID {
                library.update(playlistID: playlistID) { $0.trackIDs = newOrder }
            } else {
                library.allSongsOrder = newOrder
            }
        }
    }

    // MARK: Announcements

    /// Plays what the iPod will say for a track: the recording if there is one, otherwise a live preview.
    func playAnnouncement(for track: Track) {
        guard let device else { return }
        sound?.stop()
        previewSynthesizer.stopSpeaking(at: .immediate)
        let url = device.trackAnnouncementURL(id: track.id)
        if !track.announcement.rerecord, track.announcement.state != .missing,
           FileManager.default.fileExists(atPath: url.path), let recording = NSSound(contentsOf: url, byReference: false) {
            sound = recording
            recording.play()
            return
        }
        let text = voiceSettings.spokenText(for: track)
        let language = voiceSettings.language(for: text, override: track.spokenLanguage)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceSettings.voiceID(for: language).flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: language)
        previewSynthesizer.speak(utterance)
    }

    func spokenText(for track: Track) -> String { voiceSettings.spokenText(for: track) }

    func spokenLanguage(for track: Track) -> String {
        voiceSettings.language(for: voiceSettings.spokenText(for: track), override: track.spokenLanguage)
    }

    // MARK: Maintenance

    func removeUnusedFiles() {
        guard let session else { return }
        Task {
            let freed = await session.removeUnusedFiles()
            unusedFiles = await session.unusedFiles()
            refreshCapacity()
            statusMessage = "Freed \(Format.bytes(freed))"
        }
    }

    func showBackups() {
        let folder = DeviceSession.defaultBackupRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Saving

    private func startCommit() {
        guard let session else { return }
        if commitTask != nil || importTask != nil {
            commitRequestedAgain = true
            return
        }
        debounce?.cancel()
        debounce = nil
        commitTask = Task { [weak self] in
            await self?.performCommit(session)
            guard let self else { return }
            self.commitTask = nil
            if self.commitRequestedAgain {
                self.commitRequestedAgain = false
                self.startCommit()
            }
        }
    }

    private func performCommit(_ session: DeviceSession) async {
        let settings = voiceSettings
        do {
            let summary = try await session.commit(voiceOver: settings) { [weak self] progress in
                Task { @MainActor in self?.show(progress) }
            }
            guard self.session === session else { return }
            if pendingEdits == 0 { library = await session.snapshot() }
            hasUnsavedChanges = pendingEdits > 0 || commitRequestedAgain
            refreshCapacity()
            unusedFiles = await session.unusedFiles()
            if summary.announcementsFailed > 0 {
                statusMessage = "\(summary.announcementsFailed) title(s) could not be spoken"
            }
        } catch SessionError.changedElsewhere {
            alert = AlertInfo(
                title: "The iPod was changed by another program",
                message: "Its contents were reloaded. Changes made here since the last save were not written."
            )
            await open(session.device)
        } catch {
            guard self.session === session else { return }
            alert = AlertInfo(title: "The iPod could not be updated", message: error.localizedDescription)
        }
        if case .saving = activity { activity = nil }
    }

    private func show(_ progress: CommitProgress) {
        guard commitTask != nil else { return }
        switch progress {
        case let .announcements(done, total):
            activity = .saving("Recording announcements (\(done + 1) of \(total))")
        case .writingDatabase, .finishing:
            activity = .saving("Updating iPod…")
        }
    }

    // MARK: Preferences

    private static func store<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
