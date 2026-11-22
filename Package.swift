// swift-tools-version:5.9
import PackageDescription

// FileTool – dvoupanelový správce souborů pro macOS (ve stylu Total Commanderu), vzhled jako SSHTool.
// Bez externích závislostí: AppKit, SwiftUI, Quick Look, libarchive a nástroje obsažené v macOS.
let package = Package(
    name: "FileTool",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CArchive", path: "Sources/CArchive", linkerSettings: [.linkedLibrary("archive")]),
        .executableTarget(name: "FileTool", dependencies: ["CArchive"], path: "Sources/FileTool"),
    ]
)
