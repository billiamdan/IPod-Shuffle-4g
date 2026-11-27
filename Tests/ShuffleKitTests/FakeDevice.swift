import Foundation
import Testing
@testable import ShuffleKit

/// A temporary folder laid out like an iPod shuffle.
struct FakeDevice {
    let directory: TemporaryDirectory
    let device: ShuffleDevice

    /// An empty iPod: just the `iPod_Control` folder.
    init() throws {
        directory = try TemporaryDirectory()
        device = ShuffleDevice(root: directory.url)
        try FileManager.default.createDirectory(at: device.controlDirectory, withIntermediateDirectories: true)
    }

    /// An iPod holding the given database, with a small file for every track and a recording for
    /// every track and playlist. With `titles`, an Apple library file names them "Title N" / "List N";
    /// with `appleLibrary`, that fixture is the library file instead.
    init(database fixture: String, titles: Bool = true, appleLibrary: String? = nil) throws {
        try self.init()
        let data = try Fixture.data(fixture)
        let database = try ShuffleDatabase(data: data)
        try device.ensureDirectories()
        try data.write(to: device.databaseURL)

        for track in database.tracks {
            let url = device.fileURL(devicePath: track.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x55, count: 1000).write(to: url)
            try Data("RIFF".utf8).write(to: device.trackAnnouncementURL(id: track.id))
        }
        for playlist in database.playlists where playlist.id != 0 {
            try Data("RIFF".utf8).write(to: device.playlistAnnouncementURL(id: playlist.id))
        }
        if let appleLibrary {
            try Fixture.data(appleLibrary).write(to: device.appleLibraryURL)
        } else if titles {
            let library = AppleLibraryBuilder.make(
                tracks: database.tracks.enumerated().map { index, track in
                    (id: track.id, title: "Title \(index)", artist: "Artist \(index % 2)", album: "Album", durationMs: 1234)
                },
                playlists: database.playlists.enumerated().map { index, playlist in
                    (
                        id: playlist.id == 0 ? 0x4D41_5354_4552 : playlist.id, name: "List \(index)",
                        isMaster: playlist.id == 0, tracks: playlist.trackIndexes.map { Int($0) }
                    )
                }
            )
            try library.write(to: device.appleLibraryURL)
        }
    }

    /// The iPod as Apple's sync left it: the play database and the library file written by the same sync.
    static func appleSynced() throws -> FakeDevice {
        try FakeDevice(database: Fixture.appleSync, appleLibrary: Fixture.appleLibrary)
    }

    var databaseOnDisk: Data { (try? Data(contentsOf: device.databaseURL)) ?? Data() }
    var appleLibraryOnDisk: Data { (try? Data(contentsOf: device.appleLibraryURL)) ?? Data() }
}

/// Builds a small `iTunesDB` the way software older than today's wrote it: short headers, one playlist
/// section, no album list. The fixture `apple-sync-current.itunesdb` covers what Apple writes now;
/// this covers a file that differs from it in every size, and lets tests name their own tracks.
enum AppleLibraryBuilder {
    typealias TrackSpec = (id: UInt64, title: String, artist: String, album: String, durationMs: Int)
    /// `tracks` are positions in the track list, in play order.
    typealias PlaylistSpec = (id: UInt64, name: String, isMaster: Bool, tracks: [Int])

    /// The number playlist items use to point at the track at `index`.
    static func trackNumber(_ index: Int) -> UInt32 { UInt32(100 + index) }

    static func make(tracks: [TrackSpec], playlists: [PlaylistSpec]) -> Data {
        let trackItems = tracks.enumerated().map { index, spec -> [UInt8] in
            let strings = string(type: 1, spec.title) + string(type: 4, spec.artist) + string(type: 3, spec.album)
            var header = [UInt8](repeating: 0, count: 156)
            put(&header, 0, tag: "mhit")
            put(&header, 4, u32: 156)
            put(&header, 8, u32: UInt32(156 + strings.count))
            put(&header, 12, u32: 3)
            put(&header, 16, u32: trackNumber(index))
            put(&header, 40, u32: UInt32(spec.durationMs))
            put(&header, 112, u64: spec.id)
            return header + strings
        }
        var trackList = [UInt8](repeating: 0, count: 92)
        put(&trackList, 0, tag: "mhlt")
        put(&trackList, 4, u32: 92)
        put(&trackList, 8, u32: UInt32(tracks.count))
        let trackSection = section(type: 1, body: trackList + trackItems.flatMap { $0 })

        var itemNumber: UInt32 = 1000
        let playlistItems = playlists.map { spec -> [UInt8] in
            let strings = string(type: 1, spec.name)
            let items = spec.tracks.enumerated().flatMap { position, track -> [UInt8] in
                itemNumber += 1
                var place = [UInt8](repeating: 0, count: 44)
                put(&place, 0, tag: "mhod")
                put(&place, 4, u32: 24)
                put(&place, 8, u32: 44)
                put(&place, 12, u32: 100)
                put(&place, 24, u32: UInt32(position))
                var item = [UInt8](repeating: 0, count: 76)
                put(&item, 0, tag: "mhip")
                put(&item, 4, u32: 76)
                put(&item, 8, u32: 120)
                put(&item, 12, u32: 1)
                put(&item, 20, u32: itemNumber)
                put(&item, 24, u32: trackNumber(track))
                put(&item, 44, u64: tracks[track].id)
                return item + place
            }
            var header = [UInt8](repeating: 0, count: 108)
            put(&header, 0, tag: "mhyp")
            put(&header, 4, u32: 108)
            put(&header, 8, u32: UInt32(108 + strings.count + items.count))
            put(&header, 12, u32: 1)
            put(&header, 16, u32: UInt32(spec.tracks.count))
            header[20] = spec.isMaster ? 1 : 0
            put(&header, 28, u64: spec.id)
            return header + strings + items
        }
        var playlistList = [UInt8](repeating: 0, count: 92)
        put(&playlistList, 0, tag: "mhlp")
        put(&playlistList, 4, u32: 92)
        put(&playlistList, 8, u32: UInt32(playlists.count))
        let playlistSection = section(type: 2, body: playlistList + playlistItems.flatMap { $0 })

        var file = [UInt8](repeating: 0, count: 104)
        put(&file, 0, tag: "mhbd")
        put(&file, 4, u32: 104)
        put(&file, 8, u32: UInt32(104 + trackSection.count + playlistSection.count))
        put(&file, 20, u32: 2)
        return Data(file + trackSection + playlistSection)
    }

    private static func section(type: UInt32, body: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 96)
        put(&header, 0, tag: "mhsd")
        put(&header, 4, u32: 96)
        put(&header, 8, u32: UInt32(96 + body.count))
        put(&header, 12, u32: type)
        return header + body
    }

    private static func string(type: UInt32, _ text: String) -> [UInt8] {
        let payload = text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        var item = [UInt8](repeating: 0, count: 40)
        put(&item, 0, tag: "mhod")
        put(&item, 4, u32: 24)
        put(&item, 8, u32: UInt32(40 + payload.count))
        put(&item, 12, u32: type)
        put(&item, 24, u32: 1)
        put(&item, 28, u32: UInt32(payload.count))
        return item + payload
    }

    private static func put(_ bytes: inout [UInt8], _ offset: Int, tag: String) {
        bytes.replaceSubrange(offset..<offset + 4, with: Array(tag.utf8))
    }

    private static func put(_ bytes: inout [UInt8], _ offset: Int, u32 value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(8 * index)) }
    }

    private static func put(_ bytes: inout [UInt8], _ offset: Int, u64 value: UInt64) {
        for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(8 * index)) }
    }
}
