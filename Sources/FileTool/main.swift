import AppKit

// Sestavení (build-app.sh): vykreslit ikonu do PNG a skončit.
if let out = ProcessInfo.processInfo.environment["FILETOOL_RENDER_ICON"] {
    let ok = MainActor.assumeIsolated { AppIcon.writePNG(Theme.midnight, to: out) }
    exit(ok ? 0 : 1)
}

FileToolApp.main()
