// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The standard About window with the licence, where the source is, and where the project came from.
/// The copyright line above the credits comes from `NSHumanReadableCopyright` in the bundle's Info.plist
/// (written by `scripts/build-app.sh`); outside a bundle it is added to the credits instead.
@MainActor
enum AboutPanel {
    static let copyright = "© 2026 billiamdan"
    static let sourceURL = URL(string: "https://github.com/billiamdan/shuffler")!

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        func add(_ string: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            text.append(NSAttributedString(string: string, attributes: base.merging(extra) { $1 }))
        }

        if Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") == nil {
            add("\(copyright)\n")
        }
        add("Free software under the GNU General Public License, version 2 or (at your option) any later "
            + "version. It comes with no warranty.\n")
        add("Source code: ")
        add("github.com/billiamdan/shuffler", [.link: sourceURL])
        add("\n")
        add("Grew out of ipod-shuffle-4g by Nimesh Ghelani, NicoHood and contributors, "
            + "which was based on shuffle-db-ng by ikelos.\n")
        add("iPod is a trademark of Apple Inc. Shuffler is not affiliated with or endorsed by Apple.")
        return text
    }
}
