import Foundation

/// A mounted iPod shuffle, or any folder laid out like one (handy for tests and dry runs).
public struct ShuffleDevice: Sendable, Hashable, Identifiable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var id: String { root.path }

    // MARK: Layout

    public var controlDirectory: URL { root.appendingPathComponent("iPod_Control", isDirectory: true) }
    public var databaseDirectory: URL { controlDirectory.appendingPathComponent("iTunes", isDirectory: true) }
    /// The database the firmware plays from.
    public var databaseURL: URL { databaseDirectory.appendingPathComponent("iTunesSD") }
    /// Play counts and bookmarks, written by the iPod.
    public var statisticsURL: URL { databaseDirectory.appendingPathComponent("iTunesStats") }
    /// Apple's own library file, which Finder lists the iPod's songs from. Read for titles; kept in step on commit.
    public var appleLibraryURL: URL { databaseDirectory.appendingPathComponent("iTunesDB") }
    public var musicDirectory: URL { controlDirectory.appendingPathComponent("Music", isDirectory: true) }
    public var speakableDirectory: URL { controlDirectory.appendingPathComponent("Speakable", isDirectory: true) }
    public var trackAnnouncementsDirectory: URL { speakableDirectory.appendingPathComponent("Tracks", isDirectory: true) }
    public var playlistAnnouncementsDirectory: URL { speakableDirectory.appendingPathComponent("Playlists", isDirectory: true) }
    /// This app's own notes about the iPod: titles, playlist names and what it last wrote.
    public var manifestDirectory: URL { controlDirectory.appendingPathComponent("Shuffler", isDirectory: true) }
    public var manifestURL: URL { manifestDirectory.appendingPathComponent("library.json") }

    public func trackAnnouncementURL(id: UInt64) -> URL {
        trackAnnouncementsDirectory.appendingPathComponent(id.hexID + ".wav")
    }

    public func playlistAnnouncementURL(id: UInt64) -> URL {
        playlistAnnouncementsDirectory.appendingPathComponent(id.hexID + ".wav")
    }

    /// Turns a database path such as `/iPod_Control/Music/F00/ABCD.mp3` into a file URL on this device.
    public func fileURL(devicePath: String) -> URL {
        var url = root
        for component in devicePath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// The database path for a file on this device, or `nil` if the file lives elsewhere.
    public func devicePath(for url: URL) -> String? {
        let rootComponents = root.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return "/" + components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    // MARK: State

    public static func isDevice(at root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = root.appendingPathComponent("iPod_Control").path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public var hasDatabase: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    /// The volume name, or the folder name when this is not a volume root.
    public var name: String {
        if isVolume, let name = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName { return name }
        return root.lastPathComponent
    }

    public struct Capacity: Sendable, Equatable {
        public var total: Int64
        public var available: Int64
        public var used: Int64 { max(0, total - available) }
    }

    public func capacity() -> Capacity? {
        guard let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        return Capacity(total: Int64(total), available: Int64(available))
    }

    /// True when `root` is the top of a mounted volume (a real iPod) rather than a folder somewhere.
    public var isVolume: Bool {
        guard let volume = (try? root.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return false }
        return volume.standardizedFileURL == root
    }

    /// A stable folder name for this device's backups: the volume's UUID for a real iPod,
    /// otherwise the folder name plus a short hash of its path.
    public var backupKey: String {
        if isVolume, let uuid = (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString { return uuid }
        let safe = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        return "\(safe)-\(FileOps.sha256(Data(root.path.utf8)).prefix(8))"
    }

    /// Creates the folders the firmware expects. Existing folders and their contents are left alone,
    /// so on an iPod that has been used before this changes nothing.
    public func ensureDirectories() throws {
        let manager = FileManager.default
        for directory in [databaseDirectory, musicDirectory, trackAnnouncementsDirectory, playlistAnnouncementsDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

public enum DeviceLocator {
    /// Mounted volumes that look like an iPod (they have an `iPod_Control` folder).
    public static func mountedDevices() -> [ShuffleDevice] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return volumes
            .filter { $0.path != "/" && ShuffleDevice.isDevice(at: $0) }
            .map(ShuffleDevice.init(root:))
    }
}
