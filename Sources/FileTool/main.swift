import AppKit

// SSH_ASKPASS: ssh spuštěné z FileTool se ptá na heslo / OTP / klíč serveru.
if ProcessInfo.processInfo.environment["FILETOOL_ASKPASS"] == "1" {
    AskPass.run(prompt: CommandLine.arguments.dropFirst().joined(separator: " "))
}

// Sestavení (build-app.sh): vykreslit ikonu do PNG a skončit.
if let out = ProcessInfo.processInfo.environment["FILETOOL_RENDER_ICON"] {
    let ok = MainActor.assumeIsolated { AppIcon.writePNG(Theme.midnight, to: out) }
    exit(ok ? 0 : 1)
}

FileToolApp.main()
