// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "renpho-scale",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "renpho-recon",
            path: "Sources/renpho-recon",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "renpho-explore",
            path: "Sources/renpho-explore",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
