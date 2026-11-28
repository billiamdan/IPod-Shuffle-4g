// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public enum ManifestError: ShuffleError {
    case newerSchema(Int)

    public var description: String {
        switch self {
        case let .newerSchema(schema):
            return "this iPod was last managed by a newer version of the app (library format \(schema)); update the app before changing it"
        }
    }
}

/// Reads and writes `iPod_Control/Shuffler/library.json`.
public enum ManifestStore {
    /// Returns `nil` when the iPod has no manifest, or one that cannot be read (the caller then
    /// rebuilds it from the database). A manifest from a newer app version is an error instead,
    /// so that an old build never overwrites information it does not understand.
    public static func load(from device: ShuffleDevice) throws -> Library? {
        guard let data = try? Data(contentsOf: device.manifestURL) else { return nil }
        struct Probe: Decodable { var schema: Int }
        if let probe = try? JSONDecoder().decode(Probe.self, from: data), probe.schema > Library.currentSchema {
            throw ManifestError.newerSchema(probe.schema)
        }
        return try? decoder.decode(Library.self, from: data)
    }

    public static func save(_ library: Library, to device: ShuffleDevice) throws {
        try FileManager.default.createDirectory(at: device.manifestDirectory, withIntermediateDirectories: true)
        FileOps.removeSidecar(for: device.manifestDirectory)
        try FileOps.atomicWrite(try encode(library), to: device.manifestURL)
    }

    public static func encode(_ library: Library) throws -> Data {
        try encoder.encode(library)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
