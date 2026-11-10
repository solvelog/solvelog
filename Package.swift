// swift-tools-version:5.9
// SolveLog — track your competitive programming submissions across online judges.
// Copyright (C) 2026 SolveLog contributors. Licensed under the GNU GPL v3 or later.

import PackageDescription

let package = Package(
    name: "SolveLog",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SolveLog",
            path: "Sources/SolveLog",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
