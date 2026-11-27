import ShuffleKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model

        Group {
            if model.device != nil {
                BrowserView()
            } else {
                WelcomeView()
            }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.alert?.message ?? "")
        }
        .sheet(isPresented: Binding(get: { model.importReport != nil }, set: { if !$0 { model.importReport = nil } })) {
            if let report = model.importReport {
                ImportReportView(report: report)
            }
        }
        .onChange(of: model.settingsRequested) { _, requested in
            guard requested else { return }
            model.settingsRequested = false
            openSettings()
        }
        .confirmationDialog(
            "Remove \(model.unusedFiles.count) unused file(s) from the iPod?",
            isPresented: $model.confirmingCleanup
        ) {
            Button("Remove", role: .destructive) { model.removeUnusedFiles() }
        } message: {
            Text("These are files on the iPod that nothing in its library refers to, taking up \(Format.bytes(model.unusedFiles.reduce(0) { $0 + $1.sizeBytes })). This cannot be undone.")
        }
    }
}

/// Shown while no iPod is connected.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Connect your iPod shuffle", systemImage: "ipodshuffle.gen4")
        } description: {
            Text("It appears here as soon as it is mounted on this Mac.")
        } actions: {
            Button("Open Folder…") { model.chooseFolder() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The main window: lists on the left, songs in the middle, details on the right.
struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            TrackListView()
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
                }
                .navigationTitle(model.currentPlaylist?.name ?? "All Songs")
                .navigationSubtitle(model.device?.name ?? "")
        }
        .searchable(text: $model.searchText, prompt: "Search")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.chooseFilesToAdd()
                } label: {
                    Label("Add Music", systemImage: "plus")
                }
                .help("Copy songs or folders to the iPod")

                Button {
                    model.createPlaylist()
                } label: {
                    Label("New Playlist", systemImage: "text.badge.plus")
                }
                .help("Create a playlist")

                Button {
                    model.eject()
                } label: {
                    Label("Eject", systemImage: "eject")
                }
                .help("Save everything and eject the iPod")

                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Info", systemImage: "sidebar.trailing")
                }
                .help("Show or hide details of the selected song")
            }
        }
    }
}

/// Lists what happened to files that were not simply copied.
struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let report: ImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.skipped.isEmpty ? "Music added" : "Some files were not added")
                .font(.headline)
            Text(summary)
                .foregroundStyle(.secondary)

            List {
                if !report.skipped.isEmpty {
                    Section("Not added") {
                        ForEach(report.skipped) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(item.name, systemImage: "exclamationmark.triangle")
                                Text(item.reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                let converted = report.added.filter { $0.note != nil }
                if !converted.isEmpty {
                    Section("Converted on the way") {
                        ForEach(converted) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.note ?? "")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }

    private var summary: String {
        var parts = ["\(Format.songs(report.added.count)) added"]
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
        if report.cancelled { parts.append("stopped early") }
        return parts.joined(separator: ", ")
    }
}
