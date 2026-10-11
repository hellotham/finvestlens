// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensReports",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
        .macCatalyst("27.0"),
        .visionOS("27.0"),
    ],
    products: [
        .library(name: "FinvestLensReports", targets: ["FinvestLensReports"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .target(
            name: "FinvestLensReports",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "FinvestLensReportsTests",
            dependencies: ["FinvestLensReports"]
        ),
    ]
)
