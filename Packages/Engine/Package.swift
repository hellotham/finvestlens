// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensEngine",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
        .macCatalyst("27.0"),
        .visionOS("27.0"),
    ],
    products: [
        .library(name: "FinvestLensEngine", targets: ["FinvestLensEngine"]),
    ],
    targets: [
        .target(
            name: "FinvestLensEngine"
        ),
        .testTarget(
            name: "FinvestLensEngineTests",
            dependencies: ["FinvestLensEngine"]
        ),
    ]
)
