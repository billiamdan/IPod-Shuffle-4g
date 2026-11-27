import Foundation
import Testing
@testable import ShuffleKit

enum Fixture {
    /// Written by Apple's sync on macOS 27.2.1 (library IDs replaced by made-up ones).
    static let appleSync = "apple-sync-current.itunessd"
    /// Apple's library file from the same sync as `appleSync`: its exact structure, with every name,
    /// ID, date, play count and size replaced by made-up values (IDs match `appleSync`).
    static let appleLibrary = "apple-sync-current.itunesdb"
    /// The Apple database plus four tracks and a playlist appended; played on a real iPod shuffle 4G.
    static let deviceTested = "device-tested-current.itunessd"
    /// Written by `ipod-shuffle-4g.py`, the Python script this project replaced (it is still in the
    /// project this one was forked from), for a made-up folder tree.
    static let legacyScript = "legacy-script.itunessd"

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

/// A scratch directory that is removed when the value goes away.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ShuffleKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
