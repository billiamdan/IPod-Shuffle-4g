// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import ShuffleKit
import SwiftUI

@main
struct ShufflerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Shuffler", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 480)
                .onAppear {
                    delegate.model = model
                    model.start()
                    Snapshot.runIfRequested(model: model)
                }
        }
        .defaultSize(width: 1100, height: 680)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is started outside an app bundle (for example with `swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting waits until everything pending has reached the iPod.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.needsToFinishBeforeQuit else { return .terminateNow }
        Task { @MainActor in
            await model.finishPendingWork()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let connected = model.device != nil

        CommandGroup(replacing: .appInfo) {
            Button("About Shuffler") { AboutPanel.show() }
        }

        CommandGroup(replacing: .newItem) {
            Button("Add Music…") { model.chooseFilesToAdd() }
                .keyboardShortcut("o")
                .disabled(!connected)
            Button("New Playlist") { model.createPlaylist() }
                .keyboardShortcut("n")
                .disabled(!connected)
            Divider()
            Button("Open iPod Folder…") { model.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("iPod") {
            Toggle("VoiceOver", isOn: Binding(
                get: { model.library.voiceOverEnabled },
                set: { model.setVoiceOverEnabled($0) }
            ))
            Button("Record All Announcements Again") { model.rerecordAnnouncements() }
            Divider()
            Menu("Sort All Songs By") {
                ForEach(SortKey.allCases) { key in
                    Button(key.rawValue) { model.sortAllSongs(by: key) }
                }
            }
            Divider()
            Button("Reload") { model.reload() }
                .keyboardShortcut("r")
            Button("Remove Unused Files…") { model.confirmingCleanup = true }
                .disabled(model.unusedFiles.isEmpty)
            Button("Show Backups in Finder") { model.showBackups() }
            Divider()
            Button("Eject") { model.eject() }
                .keyboardShortcut("e")
        }
    }
}
