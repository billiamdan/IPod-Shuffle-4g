import AppKit
import SwiftUI

/// Developer aid for checking the interface without a person at the screen (and for README pictures).
///
///     SHUFFLER_DEVICE=/path/to/ipod-folder SHUFFLER_SNAPSHOT=/tmp/shot.png Shuffler
///
/// The app opens, draws each of its windows into a PNG and quits. Because it draws its own views,
/// no screen-recording permission is involved. `SHUFFLER_SNAPSHOT_SCENE` picks what to show:
/// `list` (default), `inspector`, `playlist`, `settings`, or one of two scripted sessions that go
/// through the same code paths the window uses, so the result on the device can be checked afterwards:
/// `exercise` (add the files in `SHUFFLER_SNAPSHOT_FILES` to a new playlist, reorder, edit, remove)
/// and `rename` (create a playlist, name it, switch to another list; prints the name at each step).
@MainActor
enum Snapshot {
    static func runIfRequested(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SHUFFLER_SNAPSHOT"], !path.isEmpty else { return }
        let scene = environment["SHUFFLER_SNAPSHOT_SCENE"] ?? "list"

        Task { @MainActor in
            // Give the device time to open and the window time to lay out.
            for _ in 0..<40 where model.device == nil || model.activity != nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(600))

            switch scene {
            case "inspector":
                if let first = model.rows.first { model.selection = [first.id] }
                model.showInspector = true
            case "playlist":
                if let playlist = model.library.playlists.last { model.sidebarSelection = .playlist(playlist.id) }
            case "settings":
                model.settingsRequested = true
            case "exercise":
                await exercise(model)
            case "rename":
                await renameScenario(model)
            default:
                break
            }
            try? await Task.sleep(for: .milliseconds(1500))

            let base = URL(fileURLWithPath: path)
            var index = 0
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let url = index == 0 ? base : base.deletingPathExtension().appendingPathExtension("\(index).png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                index += 1
            }
            NSApp.terminate(nil)
        }
    }

    private static func exercise(_ model: AppModel) async {
        let files = (ProcessInfo.processInfo.environment["SHUFFLER_SNAPSHOT_FILES"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)) }

        let playlistID = model.createPlaylist()
        model.renamingPlaylist = nil
        model.renamePlaylist(playlistID, to: "Exercise")
        model.addFiles(files, to: playlistID)
        await model.waitUntilIdle()
        model.importReport = nil

        // Drag the last song of All Songs to the top, then rename it and make it resume where it stopped.
        model.sidebarSelection = .allSongs
        if let last = model.rows.last {
            model.handleDrop([model.dragPayload(for: last)], at: 0)
        }
        if let first = model.rows.first {
            model.update(trackID: first.track.id) {
                $0.title = "Exercised"
                $0.remembersPosition = true
            }
        }
        await model.waitUntilIdle()

        // Remove the second song from the iPod, and the first one from the new playlist only.
        if model.rows.count > 1 { model.removeFromDevice([model.rows[1].track.id]) }
        await model.waitUntilIdle()
        model.sidebarSelection = .playlist(playlistID)
        if let first = model.rows.first { model.removeFromPlaylist(rowIDs: [first.id]) }
        await model.waitUntilIdle()
    }

    /// What a person does when naming a new playlist: create it, let the window show it, type a name
    /// in the sidebar, then click another list. Prints the name before and after leaving the playlist.
    private static func renameScenario(_ model: AppModel) async {
        let id = model.createPlaylist()
        try? await Task.sleep(for: .milliseconds(1200))
        model.renamePlaylist(id, to: "Evening Mix")
        model.renamingPlaylist = nil
        try? await Task.sleep(for: .milliseconds(400))
        print("after typing the name: \(model.library.playlist(id)?.name ?? "?")")
        model.sidebarSelection = .allSongs
        try? await Task.sleep(for: .milliseconds(1200))
        await model.waitUntilIdle()
        print("after switching to All Songs: \(model.library.playlist(id)?.name ?? "?")")
    }
}
