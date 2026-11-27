import CoreTransferable
import Foundation
import ShuffleKit
import UniformTypeIdentifiers

enum Format {
    /// "3:06:36" or "4:05".
    static func duration(milliseconds: Int) -> String {
        guard milliseconds > 0 else { return "–" }
        let seconds = (milliseconds + 500) / 1000
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "9.5 hours", "42 minutes".
    static func totalDuration(milliseconds: Int) -> String {
        let minutes = Double(milliseconds) / 60_000
        if minutes >= 90 { return String(format: "%.1f hours", minutes / 60) }
        if minutes >= 1 { return "\(Int(minutes.rounded())) min" }
        return "\(milliseconds / 1000) s"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func songs(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }

    /// "English (United States)" for "en-US".
    static func language(_ tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag.replacingOccurrences(of: "-", with: "_")) ?? tag
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "–" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// What is carried when tracks are dragged inside the app.
struct TrackDrag: Codable, Transferable, Sendable {
    var trackIDs: [UInt64]
    /// Rows being dragged, so a drop in the same list can be treated as a reorder.
    var rowIDs: [String]
    /// The list they came from.
    var source: SidebarItem

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .shufflerTracks)
    }
}

extension UTType {
    /// Declared in the app's Info.plist by `scripts/build-app.sh`.
    static let shufflerTracks = UTType(exportedAs: "io.github.billiamdan.shuffler.tracks")
}

enum SidebarItem: Hashable, Codable, Sendable {
    case allSongs
    case playlist(UInt64)

    var playlistID: UInt64? {
        if case let .playlist(id) = self { return id }
        return nil
    }
}

/// One line of the track list. A playlist may hold the same track several times, so a row is
/// identified by the track plus which occurrence it is.
struct TrackRow: Identifiable, Equatable {
    let id: String
    let position: Int
    let track: Track

    static func rows(for tracks: [Track]) -> [TrackRow] {
        var seen: [UInt64: Int] = [:]
        return tracks.enumerated().map { position, track in
            let occurrence = seen[track.id, default: 0]
            seen[track.id] = occurrence + 1
            return TrackRow(id: "\(track.id)#\(occurrence)", position: position, track: track)
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case dateAdded = "Date Added"
    case duration = "Length"

    var id: String { rawValue }

    func sorted(_ tracks: [Track]) -> [Track] {
        func text(_ first: String, _ second: String) -> Bool {
            first.localizedStandardCompare(second) == .orderedAscending
        }
        switch self {
        case .title: return tracks.sorted { text($0.title, $1.title) }
        case .artist: return tracks.sorted { ($0.artist, $0.album) == ($1.artist, $1.album) ? text($0.title, $1.title) : text($0.artist + "\u{1}" + $0.album, $1.artist + "\u{1}" + $1.album) }
        case .album: return tracks.sorted {
            $0.album == $1.album
                ? ($0.record.discNumber, $0.record.trackNumber) < ($1.record.discNumber, $1.record.trackNumber)
                : text($0.album, $1.album)
        }
        case .dateAdded: return tracks.sorted { ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast) }
        case .duration: return tracks.sorted { $0.durationMs < $1.durationMs }
        }
    }
}
