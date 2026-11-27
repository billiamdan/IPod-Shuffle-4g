import Foundation
import ShuffleKit

// shufflectl: manage an iPod shuffle (3rd/4th generation) from the terminal.
// Everything here is a thin layer over ShuffleKit; the app uses the same engine.

let usage = """
usage: shufflectl [--device PATH] <command> [arguments]

  devices                              list connected iPods
  info                                 name, free space, what is on it
  list [--playlist NAME]               tracks of All Songs or of one playlist
  playlists                            playlists and their sizes
  add FILE|FOLDER... [--playlist NAME] [--lossless keep|alac|aac]
  remove TRACK...                      delete tracks from the iPod
  set TRACK [--title T] [--artist A] [--say TEXT] [--language TAG]
            [--remember on|off] [--skip-shuffle on|off]
  playlist create NAME
  playlist delete NAME
  playlist rename NAME NEW-NAME
  playlist add NAME TRACK...
  playlist remove NAME TRACK...
  voiceover on|off|rebuild             turn announcements on or off, or record them all again
  check                                compare the database with the files on the iPod
  cleanup [--yes]                      list unused files; delete them with --yes
  dump                                 decode the database (changes nothing)

  TRACK is a number from `list`, a 16-digit ID, or part of a title.

options:
  --device PATH      the iPod's volume or folder (default: the only connected iPod)
  --language TAG     language of announcements, e.g. en-US (default: the Mac's language)
  --also TAG,TAG     further languages a title may be spoken in when clearly written in one
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = [
        "device", "language", "also", "lossless", "playlist", "title", "artist", "say", "remember", "skip-shuffle",
    ]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if Arguments.valued.contains(name) {
                    guard index + 1 < raw.count else { throw Failure("--\(name) needs a value") }
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func locateDevice(_ arguments: Arguments) throws -> ShuffleDevice {
    if let path = arguments.options["device"] {
        let device = ShuffleDevice(root: URL(fileURLWithPath: path))
        guard ShuffleDevice.isDevice(at: device.root) else { throw Failure("\(path) is not an iPod (no iPod_Control folder)") }
        return device
    }
    let devices = DeviceLocator.mountedDevices()
    switch devices.count {
    case 0: throw Failure("no iPod found; connect it or pass --device PATH")
    case 1: return devices[0]
    default: throw Failure("several iPods found (\(devices.map(\.root.path).joined(separator: ", "))); pass --device PATH")
    }
}

func voiceSettings(_ arguments: Arguments) -> VoiceOverSettings {
    var settings = VoiceOverSettings.systemDefault()
    if let language = arguments.options["language"] { settings.defaultLanguage = language }
    if let also = arguments.options["also"] {
        settings.additionalLanguages = also.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    return settings
}

func duration(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    return seconds >= 3600
        ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}

func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

func pad(_ text: String, _ width: Int) -> String {
    let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
    return clipped + String(repeating: " ", count: max(0, width - clipped.count))
}

/// Finds the track a user means by a number from `list`, an ID, or part of a title.
func resolveTrack(_ reference: String, in library: Library) throws -> Track {
    let listed = library.tracks(in: nil)
    if let number = Int(reference), (1...max(listed.count, 1)).contains(number), number <= listed.count {
        return listed[number - 1]
    }
    if reference.count == 16, let id = UInt64(reference, radix: 16), let track = library.track(id) { return track }
    let matches = listed.filter { $0.title.localizedCaseInsensitiveContains(reference) }
    switch matches.count {
    case 1: return matches[0]
    case 0: throw Failure("no track matches \"\(reference)\"")
    default: throw Failure("\"\(reference)\" matches \(matches.count) tracks: \(matches.map(\.title).joined(separator: "; "))")
    }
}

func resolvePlaylist(_ name: String, in library: Library) throws -> Playlist {
    let matches = library.playlists.filter { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    guard let playlist = matches.first else { throw Failure("there is no playlist named \"\(name)\"") }
    return playlist
}

func onOff(_ value: String?, option: String) throws -> Bool? {
    switch value?.lowercased() {
    case nil: return nil
    case "on", "yes", "true": return true
    case "off", "no", "false": return false
    default: throw Failure("--\(option) takes on or off")
    }
}

func printTracks(_ tracks: [Track]) {
    print(pad("#", 4) + pad("Title", 40) + pad("Artist", 22) + pad("Time", 9) + pad("Kind", 15) + "Size")
    for (index, track) in tracks.enumerated() {
        print(pad(String(index + 1), 4) + pad(track.title, 40) + pad(track.artist, 22)
            + pad(duration(track.durationMs), 9) + pad(track.kind, 15) + bytes(track.sizeBytes))
    }
}

func commit(_ session: DeviceSession, _ arguments: Arguments) async throws {
    let summary = try await session.commit(voiceOver: voiceSettings(arguments)) { progress in
        if case let .announcements(done, total) = progress {
            FileHandle.standardError.write(Data("\rrecording announcements \(done + 1)/\(total)   ".utf8))
        }
    }
    if summary.announcementsRecorded + summary.announcementsFailed > 0 { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    var parts: [String] = []
    if summary.databaseWritten { parts.append("database updated") }
    if summary.announcementsRecorded > 0 { parts.append("\(summary.announcementsRecorded) announcement(s) recorded") }
    if summary.announcementsFailed > 0 { parts.append("\(summary.announcementsFailed) title(s) could not be spoken") }
    if summary.filesRemoved > 0 { parts.append("\(summary.filesRemoved) file(s) removed") }
    if parts.isEmpty, summary.librarySaved { parts.append("saved") }
    print(parts.isEmpty ? "nothing to change" : parts.joined(separator: ", "))
    if let backup = summary.backup, summary.databaseWritten { print("previous database saved in \(backup.path)") }
}

func run(_ raw: [String]) async throws {
    let arguments = try Arguments(raw)
    guard let command = arguments.positional.first, !arguments.flags.contains("help") else {
        print(usage)
        return
    }
    let rest = Array(arguments.positional.dropFirst())

    if command == "devices" {
        let devices = DeviceLocator.mountedDevices()
        if devices.isEmpty { print("no iPod connected") }
        for device in devices {
            let space = device.capacity().map { "\(bytes($0.available)) free of \(bytes($0.total))" } ?? ""
            print("\(device.name)  \(device.root.path)  \(space)")
        }
        return
    }

    let device = try locateDevice(arguments)

    if command == "dump" {
        let database = try ShuffleDatabase(data: try Data(contentsOf: device.databaseURL))
        print(String(format: "version 0x%08X, VoiceOver %@, volume limit %d", database.layout.rawValue, database.voiceOverEnabled ? "on" : "off", database.maxVolume))
        for (index, track) in database.tracks.enumerated() {
            print(String(format: "track %3d  type %d  %8.1fs  id %@  %@", index, track.fileType, Double(track.stopMs) / 1000, track.id.hexID, track.path))
        }
        for (index, playlist) in database.playlists.enumerated() {
            print("playlist \(index)  kind \(playlist.kind)  id \(playlist.id.hexID)  tracks \(playlist.trackIndexes)")
        }
        return
    }

    let session = DeviceSession(device: device)
    var library = try await session.open()

    switch command {
    case "info":
        print("\(device.name) at \(device.root.path)")
        if let capacity = device.capacity() { print("\(bytes(capacity.available)) free of \(bytes(capacity.total))") }
        print("\(library.tracks.count) tracks, \(duration(library.totalDurationMs)), \(bytes(library.totalBytes))")
        print("\(library.playlists.count) playlists; VoiceOver \(library.voiceOverEnabled ? "on" : "off")")
        let unused = await session.unusedFiles()
        if !unused.isEmpty { print("\(unused.count) unused file(s), \(bytes(unused.reduce(0) { $0 + $1.sizeBytes })) (see `cleanup`)") }

    case "list":
        if let name = arguments.options["playlist"] {
            printTracks(library.tracks(in: try resolvePlaylist(name, in: library).id))
        } else {
            printTracks(library.tracks(in: nil))
        }

    case "playlists":
        for playlist in library.playlists {
            print("\(pad(playlist.name, 32)) \(playlist.trackIDs.count) track(s)")
        }
        if library.playlists.isEmpty { print("no playlists") }

    case "add":
        guard !rest.isEmpty else { throw Failure("add needs at least one file or folder") }
        var settings = ImportSettings()
        switch arguments.options["lossless"] {
        case nil, "keep": break
        case "alac": settings.lossless = .appleLossless
        case "aac": settings.lossless = .aac
        default: throw Failure("--lossless takes keep, alac or aac")
        }
        let playlistID = try arguments.options["playlist"].map { try resolvePlaylist($0, in: library).id }
        let report = await session.addFiles(rest.map { URL(fileURLWithPath: $0) }, toPlaylist: playlistID, settings: settings) { progress in
            let percent = progress.bytesTotal > 0 ? Int(100 * progress.bytesDone / progress.bytesTotal) : 0
            FileHandle.standardError.write(Data("\r\u{1B}[K[\(progress.index + 1)/\(progress.count)] \(progress.phase.rawValue) \(progress.name) \(percent)%".utf8))
        }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
        for item in report.added { print("added    \(item.title)" + (item.note.map { "  (\($0))" } ?? "")) }
        for item in report.skipped { print("skipped  \(item.name): \(item.reason)") }
        try await commit(session, arguments)
        if !report.skipped.isEmpty { throw Failure("\(report.skipped.count) file(s) were not added") }

    case "remove":
        guard !rest.isEmpty else { throw Failure("remove needs at least one track") }
        let tracks = try rest.map { try resolveTrack($0, in: library) }
        for track in tracks { print("removing \(track.title)") }
        await session.removeTracks(Set(tracks.map(\.id)))
        try await commit(session, arguments)

    case "set":
        guard let reference = rest.first else { throw Failure("set needs a track") }
        let track = try resolveTrack(reference, in: library)
        let remember = try onOff(arguments.options["remember"], option: "remember")
        let skip = try onOff(arguments.options["skip-shuffle"], option: "skip-shuffle")
        let options = arguments.options
        await session.edit { library in
            library.update(trackID: track.id) { track in
                if let title = options["title"] { track.title = title }
                if let artist = options["artist"] { track.artist = artist }
                if let say = options["say"] { track.spokenName = say.isEmpty ? nil : say }
                if let language = options["language"] { track.spokenLanguage = language.isEmpty ? nil : language }
                if let remember { track.remembersPosition = remember }
                if let skip { track.skipsWhenShuffling = skip }
            }
        }
        try await commit(session, arguments)

    case "playlist":
        guard let action = rest.first, rest.count >= 2 else { throw Failure("playlist needs an action and a name") }
        let name = rest[1]
        switch action {
        case "create":
            guard !library.playlists.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
                throw Failure("a playlist named \"\(name)\" already exists")
            }
            await session.edit { $0.addPlaylist(named: name) }
        case "delete":
            await session.removePlaylist(try resolvePlaylist(name, in: library).id)
        case "rename":
            guard rest.count == 3 else { throw Failure("playlist rename needs the old and the new name") }
            let id = try resolvePlaylist(name, in: library).id
            let newName = rest[2]
            await session.edit { $0.update(playlistID: id) { $0.name = newName } }
        case "add", "remove":
            let id = try resolvePlaylist(name, in: library).id
            let ids = try rest.dropFirst(2).map { try resolveTrack($0, in: library).id }
            guard !ids.isEmpty else { throw Failure("playlist \(action) needs at least one track") }
            await session.edit { library in
                library.update(playlistID: id) { playlist in
                    if action == "add" {
                        playlist.trackIDs.append(contentsOf: ids)
                    } else {
                        playlist.trackIDs.removeAll { ids.contains($0) }
                    }
                }
            }
        default:
            throw Failure("unknown playlist action \"\(action)\"")
        }
        try await commit(session, arguments)

    case "voiceover":
        switch rest.first {
        case "on": await session.edit { $0.voiceOverEnabled = true }
        case "off": await session.edit { $0.voiceOverEnabled = false }
        case "rebuild":
            await session.edit { library in
                library.voiceOverEnabled = true
                for index in library.tracks.indices { library.tracks[index].announcement.rerecord = true }
                for index in library.playlists.indices { library.playlists[index].announcement.rerecord = true }
            }
        default: throw Failure("voiceover takes on, off or rebuild")
        }
        try await commit(session, arguments)

    case "check":
        let problems = await session.verify()
        if problems.isEmpty {
            library = await session.snapshot()
            print("ok: \(library.tracks.count) tracks, every file and announcement is in place")
        } else {
            problems.forEach { print($0) }
            throw Failure("\(problems.count) problem(s) found")
        }

    case "cleanup":
        let unused = await session.unusedFiles()
        guard !unused.isEmpty else {
            print("nothing unused")
            return
        }
        for file in unused { print("\(pad(bytes(file.sizeBytes), 10)) \(device.devicePath(for: file.url) ?? file.url.path)") }
        if arguments.flags.contains("yes") {
            print("freed \(bytes(await session.removeUnusedFiles()))")
        } else {
            print("\(unused.count) unused file(s); run again with --yes to delete them")
        }

    default:
        throw Failure("unknown command \"\(command)\"\n\n\(usage)")
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = (error as? Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("shufflectl: \(message)\n".utf8))
    exit(1)
}
