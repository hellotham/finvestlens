// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — CLI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

// `finlens` — the ledger-modelled, strictly read-only command line over
// FinvestLens books, Ledger journals, and GnuCash files (docs/ledger-design.md).
// macOS-only: it links Persistence (GRDB) and the interchange codecs, and has
// no UI dependency. The library target holds everything so the tests can
// exercise the pipeline; the executable is a thin main.
let package = Package(
    name: "FinvestLensCLI",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "finlens", targets: ["finlens"]),
        .library(name: "FinvestLensCLICore", targets: ["FinvestLensCLICore"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(path: "../Persistence"),
        .package(path: "../Interchange"),
        .package(path: "../Reports"),
    ],
    targets: [
        .target(
            name: "FinvestLensCLICore",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
                .product(name: "FinvestLensPersistence", package: "Persistence"),
                .product(name: "FinvestLensInterchange", package: "Interchange"),
                .product(name: "FinvestLensReports", package: "Reports"),
            ]
        ),
        .executableTarget(
            name: "finlens",
            dependencies: ["FinvestLensCLICore"]
        ),
        .testTarget(
            name: "FinvestLensCLITests",
            dependencies: ["FinvestLensCLICore"]
        ),
    ]
)
