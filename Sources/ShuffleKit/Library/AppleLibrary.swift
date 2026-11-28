// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A forgiving reader for Apple's `iTunesDB`, the library file Apple's sync keeps next to the play database.
///
/// The play database has no text in it, so this is where titles and playlist names of music that
/// was synced by Apple's software come from. Anything unexpected in the file simply ends the scan:
/// the result holds whatever was understood up to that point. Changing the file is the business of
/// `AppleLibraryMirror`, which reads it strictly instead (see `AppleLibraryFile` for the layout).
public struct AppleLibrary: Sendable, Equatable {
    public struct TrackInfo: Sendable, Equatable {
        public var title = ""
        public var artist = ""
        public var album = ""
        public var genre = ""
        public var trackNumber = 0
        public var durationMs = 0
        public var playCount = 0
        public var skipCount = 0
        public var lastPlayed: Date?
        public var dateAdded: Date?
    }

    /// Keyed by the same 64-bit ID the play database uses.
    public private(set) var tracks: [UInt64: TrackInfo] = [:]
    public private(set) var playlistNames: [UInt64: String] = [:]
    /// The file's dates are on the clock of the Mac that wrote it; this is that clock's distance from Greenwich.
    private var zone = TimeZone.current

    public init(data: Data) {
        let reader = ByteReader(data)
        do {
            guard try reader.tag(0) == "mhbd" else { return }
            if Int(try reader.u32(4)) >= 112, let stored = TimeZone(secondsFromGMT: Int(Int32(bitPattern: try reader.u32(108)))) {
                zone = stored
            }
            let childCount = Int(try reader.u32(20))
            var offset = Int(try reader.u32(4))
            for _ in 0..<childCount {
                guard try reader.tag(offset) == "mhsd" else { break }
                let headerLength = Int(try reader.u32(offset + 4))
                let totalLength = Int(try reader.u32(offset + 8))
                let type = try reader.u32(offset + 12)
                // Each section is independent: a damaged one should not hide the others.
                switch type {
                case 1: try? readTracks(reader, at: offset + headerLength)
                case 2, 3: try? readPlaylists(reader, at: offset + headerLength)
                default: break
                }
                guard totalLength > 0 else { break }
                offset += totalLength
            }
        } catch {
            return
        }
    }

    private mutating func readTracks(_ reader: ByteReader, at list: Int) throws {
        guard try reader.tag(list) == "mhlt" else { return }
        let count = Int(try reader.u32(list + 8))
        var offset = list + Int(try reader.u32(list + 4))
        for _ in 0..<count {
            guard try reader.tag(offset) == "mhit" else { return }
            let headerLength = Int(try reader.u32(offset + 4))
            let totalLength = Int(try reader.u32(offset + 8))
            let stringCount = Int(try reader.u32(offset + 12))
            guard headerLength >= 120, totalLength > 0 else { return }

            let strings = try Self.readStrings(reader, at: offset + headerLength, count: stringCount)
            var info = TrackInfo()
            info.title = strings[1] ?? ""
            info.album = strings[3] ?? ""
            info.artist = strings[4] ?? ""
            info.genre = strings[5] ?? ""
            info.durationMs = Int(try reader.u32(offset + 40))
            info.trackNumber = Int(try reader.u32(offset + 44))
            info.playCount = Int(try reader.u32(offset + 80))
            info.lastPlayed = PlayStatistics.date(fromDeviceTime: try reader.u32(offset + 88), timeZone: zone)
            info.dateAdded = PlayStatistics.date(fromDeviceTime: try reader.u32(offset + 104), timeZone: zone)
            if headerLength >= 160 { info.skipCount = Int(try reader.u32(offset + 156)) }
            tracks[try reader.u64(offset + 112)] = info
            offset += totalLength
        }
    }

    private mutating func readPlaylists(_ reader: ByteReader, at list: Int) throws {
        guard try reader.tag(list) == "mhlp" else { return }
        let count = Int(try reader.u32(list + 8))
        var offset = list + Int(try reader.u32(list + 4))
        for _ in 0..<count {
            guard try reader.tag(offset) == "mhyp" else { return }
            let headerLength = Int(try reader.u32(offset + 4))
            let totalLength = Int(try reader.u32(offset + 8))
            let stringCount = Int(try reader.u32(offset + 12))
            guard headerLength >= 36, totalLength > 0 else { return }

            let id = try reader.u64(offset + 28)
            if playlistNames[id] == nil,
               let name = try Self.readStrings(reader, at: offset + headerLength, count: stringCount)[1] {
                playlistNames[id] = name
            }
            offset += totalLength
        }
    }

    /// Reads the string items (`mhod`) that follow a track or playlist header, keyed by their type:
    /// 1 title, 3 album, 4 artist, 5 genre.
    private static func readStrings(_ reader: ByteReader, at start: Int, count: Int) throws -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        var offset = start
        for _ in 0..<count {
            guard try reader.tag(offset) == "mhod" else { break }
            let headerLength = Int(try reader.u32(offset + 4))
            let totalLength = Int(try reader.u32(offset + 8))
            let type = try reader.u32(offset + 12)
            guard totalLength > 0 else { break }
            if type < 50 {
                let body = offset + headerLength
                let encoding = try reader.u32(body)
                let length = Int(try reader.u32(body + 4))
                let raw = try reader.slice(body + 16, length)
                if encoding == 2 {
                    result[type] = String(decoding: raw, as: UTF8.self)
                } else {
                    var units: [UInt16] = []
                    units.reserveCapacity(raw.count / 2)
                    for index in stride(from: 0, to: raw.count - 1, by: 2) {
                        units.append(UInt16(raw[index]) | UInt16(raw[index + 1]) << 8)
                    }
                    result[type] = String(decoding: units, as: UTF16.self)
                }
            }
            offset += totalLength
        }
        return result
    }
}
