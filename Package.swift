// swift-tools-version: 5.9
// Optional: `open Package.swift` on a Mac to browse/test parsing sources.
// For the full LSUIElement app bundle, prefer: `xcodegen generate && open UsageOverview.xcodeproj`

import PackageDescription

let package = Package(
    name: "UsageOverview",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UsageOverview", targets: ["UsageOverview"])
    ],
    targets: [
        .target(
            name: "UsageOverview",
            path: "Sources",
            exclude: [
                "Info.plist",
                "App/UsageOverviewApp.swift"
            ]
        ),
        .testTarget(
            name: "UsageOverviewTests",
            dependencies: ["UsageOverview"],
            path: "Tests"
        )
    ]
)
