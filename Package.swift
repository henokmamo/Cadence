// swift-tools-version: 5.9
//
//  Package.swift
//  Cadence
//
//  The scheduling core as a standalone SwiftPM package.
//
//  Why it exists: CadenceCore is pure Swift + Foundation — no SwiftUI, no SwiftData,
//  no EventKit — which means the part of the app that actually decides your day can be
//  built and unit-tested anywhere Swift runs, including Linux (and therefore in CI),
//  not just on a Mac with Xcode.
//
//      swift test                    # engine + recurrence tests, ~1 second
//      swift build -c release
//
//  The Xcode app target compiles the same files directly (see tools/GenerateXcodeProject.py),
//  so there is exactly one copy of the algorithm.
//

import PackageDescription

let package = Package(
    name: "CadenceCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CadenceCore", targets: ["CadenceCore"])
    ],
    targets: [
        .target(
            name: "CadenceCore",
            path: "CadenceCore"
        ),
        .testTarget(
            name: "CadenceCoreTests",
            dependencies: ["CadenceCore"],
            path: "CadenceCoreTests"
        )
    ]
)
