// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — Rules
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensRules",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
        .macCatalyst("27.0"),
        .visionOS("27.0"),
    ],
    products: [
        .library(name: "FinvestLensRules", targets: ["FinvestLensRules"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .target(
            name: "FinvestLensRules",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "FinvestLensRulesTests",
            dependencies: ["FinvestLensRules"]
        ),
    ]
)
