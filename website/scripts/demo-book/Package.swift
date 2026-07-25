// swift-tools-version: 6.2
import PackageDescription

let root = "../../../Packages"

let package = Package(
    name: "demo",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "\(root)/Engine"),
        .package(path: "\(root)/Persistence"),
    ],
    targets: [
        .executableTarget(name: "demo", dependencies: [
            .product(name: "FinvestLensEngine", package: "Engine"),
            .product(name: "FinvestLensPersistence", package: "Persistence"),
        ]),
    ]
)
