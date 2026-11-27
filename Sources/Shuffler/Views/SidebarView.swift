import CoreTransferable
import ShuffleKit
import SwiftUI

/// Something dropped on a sidebar row: songs dragged from the list, or files from Finder.
enum DropItem: Transferable {
    case tracks(TrackDrag)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (drag: TrackDrag) in DropItem.tracks(drag) })
        ProxyRepresentation(importing: { (url: URL) in DropItem.file(url) })
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let selection = Binding<SidebarItem?>(
            get: { model.sidebarSelection },
            set: { if let item = $0 { model.sidebarSelection = item } }
        )

        List(selection: selection) {
            Section(model.device?.name ?? "iPod") {
                Label("All Songs", systemImage: "music.note")
                    .badge(model.library.tracks.count)
                    .tag(SidebarItem.allSongs)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.addFiles(urls)
                        return !urls.isEmpty
                    }
            }
            Section("Playlists") {
                ForEach(model.library.playlists) { playlist in
                    PlaylistRow(playlist: playlist)
                        .tag(SidebarItem.playlist(playlist.id))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                CapacityView()
                    .padding(.horizontal, 12)
                Button {
                    model.createPlaylist()
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .background(.bar)
        }
    }
}

private struct PlaylistRow: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        Group {
            if model.renamingPlaylist == playlist.id {
                TextField("Playlist name", text: $draft)
                    .focused($isEditing)
                    .onSubmit(finishRenaming)
                    .onExitCommand { model.renamingPlaylist = nil }
                    .onAppear {
                        draft = playlist.name
                        isEditing = true
                    }
                    .onChange(of: isEditing) { _, editing in
                        if !editing { finishRenaming() }
                    }
            } else {
                Label(playlist.name, systemImage: "music.note.list")
                    .badge(playlist.trackIDs.count)
            }
        }
        .contextMenu {
            Button("Rename") { model.renamingPlaylist = playlist.id }
            Button("Record Announcement Again") {
                let id = playlist.id
                model.edit { $0.update(playlistID: id) { $0.announcement.rerecord = true } }
            }
            Divider()
            Button("Delete Playlist", role: .destructive) { model.deletePlaylist(playlist.id) }
        }
        .dropDestination(for: DropItem.self) { items, _ in
            var trackIDs: [UInt64] = []
            var files: [URL] = []
            for item in items {
                switch item {
                case let .tracks(drag): trackIDs.append(contentsOf: drag.trackIDs)
                case let .file(url): files.append(url)
                }
            }
            model.addTracks(trackIDs, toPlaylist: playlist.id)
            model.addFiles(files, to: playlist.id)
            return !trackIDs.isEmpty || !files.isEmpty
        }
    }

    private func finishRenaming() {
        guard model.renamingPlaylist == playlist.id else { return }
        model.renamePlaylist(playlist.id, to: draft)
        model.renamingPlaylist = nil
    }
}

/// How full the iPod is.
private struct CapacityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let capacity = model.capacity, capacity.total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(capacity.used), total: Double(capacity.total))
                    .tint(Double(capacity.available) / Double(capacity.total) < 0.05 ? .red : .accentColor)
                Text("\(Format.bytes(capacity.available)) free of \(Format.bytes(capacity.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
