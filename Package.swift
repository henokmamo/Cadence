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
//      swift test                    # engine, recurrence, working hours + widget contract
//      swift build -c release
//
//  The Xcode app target compiles the same files directly (see tools/GenerateXcodeProject.py),
//  so there is exactly one copy of the algorithm.
//
//  Two targets beyond the core exist for the same reason: WidgetSnapshot.swift is the
//  data contract between the app process and the widget extension, and it is Foundation-only,
//  so its behaviour can be tested here rather than only on a device.
//

import PackageDescription

let package = Package(
    name: "CadenceCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CadenceCore", targets: ["CadenceCore"]),
        .library(name: "CadenceSharedContract", targets: ["CadenceSharedContract"])
    ],
    targets: [
        .target(
            name: "CadenceCore",
            path: "CadenceCore"
        ),
        // The app<->widget App Group contract. Foundation-only on purpose: this is the
        // only part of the widget pipeline that can be verified without a device.
        .target(
            name: "CadenceSharedContract",
            dependencies: ["CadenceCore"],
            path: "CadenceShared",
            sources: ["WidgetSnapshot.swift"]
        ),
        .testTarget(
            name: "CadenceCoreTests",
            dependencies: ["CadenceCore"],
            path: "CadenceCoreTests"
        ),
        // Lives in CadenceTests/ because the Xcode test target picks it up from there;
        // `sources:` keeps SwiftPM to just this one Foundation-only file.
        .testTarget(
            name: "CadenceSharedContractTests",
            dependencies: ["CadenceSharedContract"],
            path: "CadenceTests",
            sources: ["WidgetSnapshotContractTests.swift"]
        )
    ]
)
