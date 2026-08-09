// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

// `finlab` — the headless *write* side of FinvestLens: import a GnuCash file
// into a book, refresh prices, ingest documents, attach and categorise them,
// and time every one of those on whatever volume the book lives on.
//
// It is deliberately a separate package from `Packages/CLI`. `finlens` is
// strictly read-only by design (docs/cli.md ▸ Sources, ADR-L2) and that
// promise is worth more than the convenience of one binary: a tool you can
// point at a book with no possibility of it writing is a different kind of
// tool. Everything here writes, so it lives somewhere else and says so.
//
// It is not shipped in the app bundle — it exists for maintenance runs and
// for the large-book validation NFR-02 asks for.
//
// It depends on **FeatureUI**, which looks surprising for a command-line tool
// and is deliberate. `AppModel` is where import matching, attachment
// matching, smart categorisation and quote fetching actually live, and it
// imports no SwiftUI: it is an `@Observable` model class the UI happens to sit
// on top of, already driven headlessly by the FeatureUI test suites. Reaching
// for it means this tool exercises *the code the app runs* rather than a
// parallel implementation that can silently drift from it — which for a tool
// whose whole purpose is validating matching quality is the entire point.
// The app target and `finlab` are then two thin shells over one model.
let package = Package(
    name: "FinvestLensLab",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "finlab", targets: ["finlab"]),
        .library(name: "FinvestLensLabCore", targets: ["FinvestLensLabCore"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(path: "../Persistence"),
        .package(path: "../Interchange"),
        .package(path: "../Quotes"),
        .package(path: "../Intelligence"),
        .package(path: "../FeatureUI"),
    ],
    targets: [
        .target(
            name: "FinvestLensLabCore",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
                .product(name: "FinvestLensPersistence", package: "Persistence"),
                .product(name: "FinvestLensInterchange", package: "Interchange"),
                .product(name: "FinvestLensQuotes", package: "Quotes"),
                .product(name: "FinvestLensIntelligence", package: "Intelligence"),
                .product(name: "FinvestLensUI", package: "FeatureUI"),
            ]
        ),
        .executableTarget(
            name: "finlab",
            dependencies: ["FinvestLensLabCore"]
        ),
        .testTarget(
            name: "FinvestLensLabTests",
            dependencies: ["FinvestLensLabCore"]
        ),
    ]
)
