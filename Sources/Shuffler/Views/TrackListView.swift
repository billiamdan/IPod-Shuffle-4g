import ShuffleKit
import SwiftUI

/// The songs of "All Songs" or of one playlist, in the order the iPod plays them.
struct TrackListView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: Set<UInt64> = []
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var model = model
        let rows = model.rows

        Table(of: TrackRow.self, selection: $model.selection) {
            TableColumn("#") { row in
                Text("\(row.position + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 26, ideal: 30, max: 44)

            TableColumn("Title") { row in
                HStack(spacing: 6) {
                    Text(row.track.title)
                    if row.track.remembersPosition {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Resumes where you left off")
                    }
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("Artist") { row in Text(row.track.artist) }
                .width(min: 70, ideal: 120)

            TableColumn("Album") { row in Text(row.track.album) }
                .width(min: 70, ideal: 110)

            TableColumn("Time") { row in
                Text(Format.duration(milliseconds: row.track.durationMs))
                    .monospacedDigit()
            }
            .width(min: 48, ideal: 58, max: 80)

            TableColumn("Kind") { row in Text(row.track.kind) }
                .width(min: 60, ideal: 96, max: 130)

            TableColumn("Size") { row in
                Text(Format.bytes(row.track.sizeBytes))
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 66, max: 96)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .draggable(model.dragPayload(for: row))
            }
            .dropDestination(for: TrackDrag.self) { offset, drags in
                model.handleDrop(drags, at: offset)
            }
        }
        .contextMenu(forSelectionType: TrackRow.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { _ in
            model.showInspector = true
        }
        .onDeleteCommand { remove(model.selection) }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls, to: model.sidebarSelection.playlistID)
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if rows.isEmpty { emptyState }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Remove \(Format.songs(pendingRemoval.count)) from the iPod?",
            isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
        ) {
            Button("Remove", role: .destructive) {
                model.removeFromDevice(pendingRemoval)
                pendingRemoval = []
            }
        } message: {
            Text("The files are deleted from the iPod. Copies on your Mac are not touched.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.canReorder {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.sidebarSelection == .allSongs {
            ContentUnavailableView {
                Label("No Music Yet", systemImage: "music.note")
            } description: {
                Text("Drag songs or folders here, or click the + button.")
            } actions: {
                Button("Add Music…") { model.chooseFilesToAdd() }
            }
        } else {
            ContentUnavailableView(
                "Empty Playlist", systemImage: "music.note.list",
                description: Text("Drag songs here from All Songs or from Finder.")
            )
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<TrackRow.ID>) -> some View {
        let tracks = model.tracks(for: ids)
        let trackIDs = tracks.map(\.id)
        if !tracks.isEmpty {
            if tracks.count == 1 {
                Button("Play Announcement") { model.playAnnouncement(for: tracks[0]) }
            }
            Button("Record Announcement Again") { model.rerecordAnnouncements(trackIDs: trackIDs) }
            Divider()
            Menu("Add to Playlist") {
                ForEach(model.library.playlists) { playlist in
                    Button(playlist.name) { model.addTracks(trackIDs, toPlaylist: playlist.id) }
                }
                if !model.library.playlists.isEmpty { Divider() }
                Button("New Playlist") { model.createPlaylist(with: trackIDs) }
            }
            Toggle("Remember Playback Position", isOn: Binding(
                get: { tracks.allSatisfy(\.remembersPosition) },
                set: { value in model.update(trackIDs: trackIDs) { $0.remembersPosition = value } }
            ))
            Toggle("Skip When Shuffling", isOn: Binding(
                get: { tracks.allSatisfy(\.skipsWhenShuffling) },
                set: { value in model.update(trackIDs: trackIDs) { $0.skipsWhenShuffling = value } }
            ))
            Divider()
            if model.sidebarSelection.playlistID != nil {
                Button("Remove from Playlist") { model.removeFromPlaylist(rowIDs: ids) }
            }
            Button("Remove from iPod…", role: .destructive) { pendingRemoval = Set(trackIDs) }
        }
    }

    /// Delete key: in a playlist it only takes the songs out of the playlist; in All Songs it asks first.
    private func remove(_ ids: Set<TrackRow.ID>) {
        guard !ids.isEmpty else { return }
        if model.sidebarSelection.playlistID != nil {
            model.removeFromPlaylist(rowIDs: ids)
        } else {
            pendingRemoval = Set(model.tracks(for: ids).map(\.id))
        }
    }
}

/// The strip under the list: what is shown, and what the app is doing.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Text(summary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            activity
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        let tracks = model.rows.map(\.track)
        guard !tracks.isEmpty else { return "No songs" }
        let size = tracks.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let length = tracks.reduce(0) { $0 + $1.durationMs }
        return "\(Format.songs(tracks.count)), \(Format.totalDuration(milliseconds: length)), \(Format.bytes(size))"
    }

    @ViewBuilder
    private var activity: some View {
        switch model.activity {
        case .opening:
            ProgressView().controlSize(.small)
            Text("Reading iPod…")
        case let .importing(progress):
            let fraction = progress.bytesTotal > 0 ? Double(progress.bytesDone) / Double(progress.bytesTotal) : 0
            ProgressView(value: (Double(progress.index) + fraction) / Double(max(progress.count, 1)))
                .frame(width: 120)
            Text(importText(progress))
                .frame(maxWidth: 320, alignment: .leading)
            Button("Stop") { model.cancelImport() }
                .controlSize(.small)
        case let .saving(text):
            ProgressView().controlSize(.small)
            Text(text)
        case nil:
            if model.hasUnsavedChanges {
                ProgressView().controlSize(.small)
                Text("Saving…")
            } else {
                if let message = model.statusMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                Label("Saved to iPod", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func importText(_ progress: ImportProgress) -> String {
        let verb: String
        switch progress.phase {
        case .reading: verb = "Reading"
        case .converting: verb = "Converting"
        case .copying: verb = "Copying"
        }
        let name = progress.name.isEmpty ? "" : " “\(progress.name)”"
        return "\(verb)\(name) (\(progress.index + 1) of \(progress.count))"
    }
}
