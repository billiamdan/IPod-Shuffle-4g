// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import PackageDescription

let package = Package(
    name: "Shuffler",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShuffleKit", targets: ["ShuffleKit"]),
        .executable(name: "shufflectl", targets: ["shufflectl"]),
        .executable(name: "Shuffler", targets: ["Shuffler"]),
    ],
    targets: [
        // Everything that touches the iPod: database codec, import, VoiceOver, sync. No UI.
        .target(name: "ShuffleKit"),
        // The same engine from the terminal.
        .executableTarget(name: "shufflectl", dependencies: ["ShuffleKit"]),
        // The Mac app. `scripts/build-app.sh` wraps the binary into Shuffler.app and a DMG.
        .executableTarget(name: "Shuffler", dependencies: ["ShuffleKit"]),
        .testTarget(
            name: "ShuffleKitTests",
            dependencies: ["ShuffleKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
