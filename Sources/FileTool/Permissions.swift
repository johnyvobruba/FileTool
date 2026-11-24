import Foundation
import AppKit

// Plný přístup k disku (Full Disk Access): jedno oprávnění místo jednotlivých dotazů
// na Plochu, Dokumenty, Stažené, síťové a vyměnitelné svazky, Koš, Mail…
// macOS ho neumí udělit z aplikace – jen uživatel v Nastavení systému. Tady ho jen navedeme.

@MainActor
enum Permissions {
    /// TCC.db jde otevřít jen s Plným přístupem k disku – spolehlivý test.
    /// Chráněná místa, která jde číst jen s Plným přístupem k disku. Stačí, aby šlo jedno z existujících.
    nonisolated static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let files = [home + "/Library/Application Support/com.apple.TCC/TCC.db", "/Library/Application Support/com.apple.TCC/TCC.db"]
        for p in files { if let h = FileHandle(forReadingAtPath: p) { try? h.close(); return true } }
        let dirs = ["/Library/Safari", "/Library/Mail", "/Library/Messages", "/Library/Containers/com.apple.Safari",
                    "/Library/Cookies", "/.Trash"].map { home + $0 }
        for d in dirs where FileManager.default.fileExists(atPath: d) {
            if (try? FileManager.default.contentsOfDirectory(atPath: d)) != nil { return true }
        }
        return false
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }

    /// Nastavení + FileTool ve Finderu (přetáhne se do seznamu, nebo + a vybrat).
    static func guide() {
        let a = NSAlert()
        a.messageText = "Plný přístup k disku pro FileTool"
        a.informativeText = """
        Jedno oprávnění pro všechny složky – macOS se pak už nebude ptát zvlášť na Plochu, Dokumenty, Stažené, síťové disky, Koš nebo Mail.

        1. Otevře se Nastavení systému → Soukromí a zabezpečení → Plný přístup k disku.
        2. Klikni na „+“ (nebo přetáhni FileTool z okna Finderu, které se otevře) a zapni přepínač.
        3. Restartuj FileTool.

        macOS toto oprávnění z aplikace udělit nedovolí – musíš ho zapnout ty.
        """
        a.addButton(withTitle: "Otevřít Nastavení")
        a.addButton(withTitle: "Později")
        a.addButton(withTitle: "Neptat se znovu")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "fdaDontAsk")
        default: break
        }
    }

    /// Při spuštění: zeptat se jednou (dokud uživatel neřekne „Neptat se znovu“ nebo přístup nezapne).
    static func askOnLaunchIfNeeded() {
        guard !hasFullDiskAccess, !UserDefaults.standard.bool(forKey: "fdaDontAsk") else { return }
        let last = UserDefaults.standard.double(forKey: "fdaAskedAt")
        guard Date().timeIntervalSince1970 - last > 7 * 86400 else { return }        // nejvýš jednou týdně
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "fdaAskedAt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { guide() }
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
