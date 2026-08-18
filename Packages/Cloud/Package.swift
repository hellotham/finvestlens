// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — Cloud
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensCloud",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
        .macCatalyst("26.0"),
    ],
    products: [
        .library(name: "FinvestLensCloud", targets: ["FinvestLensCloud"]),
    ],
    // Deliberately depends on nothing. A cloud transport needs no accounting
    // model, and keeping it that way means the Engine cannot acquire a
    // dependency on the network by accident (Architecture: dependencies point
    // strictly downward).
    targets: [
        .target(name: "FinvestLensCloud"),
        .testTarget(
            name: "FinvestLensCloudTests",
            dependencies: ["FinvestLensCloud"]
        ),
    ]
)
