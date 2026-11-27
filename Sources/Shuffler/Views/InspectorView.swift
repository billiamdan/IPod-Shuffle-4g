import ShuffleKit
import SwiftUI

/// Details of the selection: one song, several songs, or the playlist being shown.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.selectedTracks
        if let track = model.inspectedTrack {
            TrackInspector(track: track)
                .id(track.id)
        } else if selected.count > 1 {
            MultipleTracksInspector(tracks: selected)
        } else if let playlist = model.currentPlaylist {
            PlaylistInspector(playlist: playlist)
                .id(playlist.id)
        } else {
            ContentUnavailableView(
                "No Selection", systemImage: "music.note",
                description: Text("Select a song to see and change its details.")
            )
        }
    }
}

private struct TrackInspector: View {
    @Environment(AppModel.self) private var model
    let track: Track

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var spokenName: String
    @FocusState private var focus: Field?

    private enum Field { case title, artist, album, spokenName }

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _spokenName = State(initialValue: track.spokenName ?? "")
    }

    var body: some View {
        Form {
            Section("Song") {
                TextField("Title", text: $title).focused($focus, equals: .title)
                TextField("Artist", text: $artist).focused($focus, equals: .artist)
                TextField("Album", text: $album).focused($focus, equals: .album)
            }

            Section {
                LabeledContent("Says") {
                    Text(model.spokenText(for: edited))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                TextField("Custom wording", text: $spokenName, prompt: Text("Same as above"))
                    .focused($focus, equals: .spokenName)
                Picker("Language", selection: Binding(
                    get: { track.spokenLanguage ?? "" },
                    set: { value in model.update(trackID: track.id) { $0.spokenLanguage = value.isEmpty ? nil : value } }
                )) {
                    Text("Automatic (\(Format.language(model.spokenLanguage(for: automatic))))").tag("")
                    Divider()
                    ForEach(model.voiceSettings.installedLanguages, id: \.self) { language in
                        Text(Format.language(language)).tag(language)
                    }
                }
                HStack {
                    Button("Play") {
                        commit()
                        model.playAnnouncement(for: edited)
                    }
                    Button("Record Again") { model.rerecordAnnouncements(trackIDs: [track.id]) }
                    Spacer()
                }
            } header: {
                Text("VoiceOver")
            } footer: {
                Text(announcementStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                Toggle("Remember playback position", isOn: Binding(
                    get: { track.remembersPosition },
                    set: { value in model.update(trackID: track.id) { $0.remembersPosition = value } }
                ))
                Toggle("Skip when shuffling", isOn: Binding(
                    get: { track.skipsWhenShuffling },
                    set: { value in model.update(trackID: track.id) { $0.skipsWhenShuffling = value } }
                ))
            }

            Section("File") {
                LabeledContent("Kind", value: track.kind)
                LabeledContent("Length", value: Format.duration(milliseconds: track.durationMs))
                LabeledContent("Size", value: Format.bytes(track.sizeBytes))
                if let bitrate = track.bitrateKbps { LabeledContent("Bit rate", value: "\(bitrate) kbps") }
                if let rate = track.sampleRate { LabeledContent("Sample rate", value: String(format: "%.1f kHz", Double(rate) / 1000)) }
                LabeledContent("Plays", value: "\(track.playCount)")
                if track.lastPlayed != nil { LabeledContent("Last played", value: Format.date(track.lastPlayed)) }
                if track.dateAdded != nil { LabeledContent("Added", value: Format.date(track.dateAdded)) }
                LabeledContent("On iPod") {
                    Text(track.record.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onSubmit(commit)
        .onChange(of: focus) { commit() }
        .onDisappear(perform: commit)
    }

    /// The track with whatever is typed in the fields right now.
    private var edited: Track {
        var copy = track
        copy.title = title
        copy.artist = artist
        copy.album = album
        copy.spokenName = spokenName.isEmpty ? nil : spokenName
        return copy
    }

    private var automatic: Track {
        var copy = edited
        copy.spokenLanguage = nil
        return copy
    }

    private var announcementStatus: String {
        if !model.library.voiceOverEnabled { return "VoiceOver is turned off for this iPod (iPod menu)." }
        if track.announcement.rerecord { return "Will be recorded again." }
        switch track.announcement.state {
        case .inherited: return "Recorded by other software. It is kept until you choose Record Again."
        case .generated: return "Recorded by this app."
        case .missing: return "Not recorded yet."
        }
    }

    private func commit() {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSpoken = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else {
            title = track.title
            return
        }
        guard newTitle != track.title || newArtist != track.artist || newAlbum != track.album || newSpoken != (track.spokenName ?? "") else {
            return
        }
        model.update(trackID: track.id) { track in
            track.title = newTitle
            track.artist = newArtist
            track.album = newAlbum
            track.spokenName = newSpoken.isEmpty ? nil : newSpoken
        }
    }
}

private struct MultipleTracksInspector: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let ids = tracks.map(\.id)
        Form {
            Section("\(Format.songs(tracks.count)) selected") {
                LabeledContent("Length", value: Format.totalDuration(milliseconds: tracks.reduce(0) { $0 + $1.durationMs }))
                LabeledContent("Size", value: Format.bytes(tracks.reduce(0) { $0 + $1.sizeBytes }))
            }
            Section("Playback") {
                Toggle("Remember playback position", isOn: Binding(
                    get: { tracks.allSatisfy(\.remembersPosition) },
                    set: { value in model.update(trackIDs: ids) { $0.remembersPosition = value } }
                ))
                Toggle("Skip when shuffling", isOn: Binding(
                    get: { tracks.allSatisfy(\.skipsWhenShuffling) },
                    set: { value in model.update(trackIDs: ids) { $0.skipsWhenShuffling = value } }
                ))
            }
            Section("VoiceOver") {
                Button("Record Announcements Again") { model.rerecordAnnouncements(trackIDs: ids) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaylistInspector: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    @State private var name: String
    @State private var spokenName: String

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
        _spokenName = State(initialValue: playlist.spokenName ?? "")
    }

    var body: some View {
        Form {
            Section("Playlist") {
                TextField("Name", text: $name)
                LabeledContent("Songs", value: "\(playlist.trackIDs.count)")
            }
            Section {
                TextField("Custom wording", text: $spokenName, prompt: Text(playlist.name))
                Picker("Language", selection: Binding(
                    get: { playlist.spokenLanguage ?? "" },
                    set: { value in
                        let id = playlist.id
                        model.edit { $0.update(playlistID: id) { $0.spokenLanguage = value.isEmpty ? nil : value } }
                    }
                )) {
                    Text("Automatic").tag("")
                    Divider()
                    ForEach(model.voiceSettings.installedLanguages, id: \.self) { language in
                        Text(Format.language(language)).tag(language)
                    }
                }
            } header: {
                Text("VoiceOver")
            } footer: {
                Text(playlist.trackIDs.isEmpty
                    ? "An empty playlist is not sent to the iPod. Add songs to make it appear."
                    : "The iPod says this name when you hold the VoiceOver button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onSubmit(commit)
        .onDisappear(perform: commit)
    }

    private func commit() {
        model.renamePlaylist(playlist.id, to: name)
        let wording = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wording != (playlist.spokenName ?? "") else { return }
        let id = playlist.id
        model.edit { $0.update(playlistID: id) { $0.spokenName = wording.isEmpty ? nil : wording } }
    }
}
