import SwiftUI
import AppKit

// Vstupní bod je main.swift (kvůli režimu vykreslení ikony při sestavení).
struct FileToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var commander = Commander.shared
    @ObservedObject private var settings = FTSettings.shared

    var body: some Scene {
        Window("FileTool", id: "main") {
            MainView(commander: commander, settings: settings)
                .tint(UI.accent)
                .preferredColorScheme(settings.isDark ? .dark : .light)
                .id(settings.themeKey)                    // nový profil = překreslit okno
                .frame(minWidth: 900, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("O aplikaci FileTool") { NSApp.orderFrontStandardAboutPanel(nil) }
                Button("Zkontrolovat aktualizace…") { Updater.shared.check(interactive: true) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Nová záložka") { commander.active.newTab(); commander.focus(commander.activeSide) }
                    .keyboardShortcut("t")
                Button("Zavřít záložku") { commander.active.close(commander.active.activeID) }
                    .keyboardShortcut("w")
                Button("Další záložka") { commander.active.cycle(1); commander.focus(commander.activeSide) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Předchozí záložka") { commander.active.cycle(-1); commander.focus(commander.activeSide) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            CommandGroup(replacing: .saveItem) {}
            CommandMenu("Operace") {
                Button("Zobrazit (F3)") { commander.view() }.keyboardShortcut("3")
                Button("Upravit (F4)") { commander.edit() }.keyboardShortcut("4")
                Button("Kopírovat (F5)") { commander.transfer(move: false) }.keyboardShortcut("5")
                Button("Přesunout (F6)") { commander.transfer(move: true) }.keyboardShortcut("6")
                Button("Nová složka (F7)") { commander.mkdir() }.keyboardShortcut("7")
                Button("Do Koše (F8)") { commander.delete() }.keyboardShortcut("8")
                Button("Smazat trvale (⇧F8)") { commander.delete(permanent: true) }.keyboardShortcut("8", modifiers: [.command, .shift])
                Button("Přejmenovat (⇧F6)") { commander.rename() }.keyboardShortcut("r")
                Divider()
                Button("Zabalit do druhého panelu… (Alt+F5)") { commander.pack() }.keyboardShortcut("5", modifiers: [.command, .option])
                Button("Rozbalit do druhého panelu… (Alt+F9)") { commander.unpack() }.keyboardShortcut("9", modifiers: [.command, .option])
                Button("Otevřít výchozí aplikací") { commander.openExternally() }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Zobrazit ve Finderu") { commander.revealInFinder() }.keyboardShortcut("r", modifiers: [.command, .option])
                Button("Kopírovat cestu") { commander.copyPaths() }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("Hledat… (Alt+F7)") { commander.search() }.keyboardShortcut("f")
                Button("Úklid…") { CleanupWindow.show() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Otevřít Terminál zde") { commander.openTerminalHere() }
                Divider()
                Button("Připojit k serveru…") { commander.connectDialog() }.keyboardShortcut("k")
                Button("Odpojit od serveru") { commander.disconnect() }.keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandMenu("Výběr") {
                Button("Označit vše") { commander.tab.markAll() }.keyboardShortcut("a")
                Button("Zrušit označení") { commander.tab.unmarkAll() }.keyboardShortcut("d")
                Button("Obrátit označení (num *)") { commander.tab.invertMarks() }.keyboardShortcut("8", modifiers: [.command, .option])
                Button("Označit maskou… (num +)") { commander.markByMask(add: true) }.keyboardShortcut("=", modifiers: [.command, .option])
                Button("Odznačit maskou… (num -)") { commander.markByMask(add: false) }.keyboardShortcut("-", modifiers: [.command, .option])
            }
            CommandGroup(after: .sidebar) {
                Button(settings.showSidebar ? "Skrýt boční panel" : "Zobrazit boční panel") { settings.showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Seznam / náhledy") { let t = commander.tab; t.thumbOverride = !t.showThumbs; commander.focus(commander.activeSide) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Skryté soubory") { settings.showHidden.toggle(); commander.refreshAll() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Obnovit") { commander.refreshAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Přepnout panel (Tab)") { commander.switchPanel() }.keyboardShortcut("0")
                Button("Disk / místo – levý panel") { commander.showPlaces(.left) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Disk / místo – pravý panel") { commander.showPlaces(.right) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Prohodit panely") { commander.swapPanels() }.keyboardShortcut("u")
                Button("Druhý panel = stejná složka") { commander.mirrorToOther() }.keyboardShortcut("=")
                Button("Nadřazená složka") { commander.tab.up() }.keyboardShortcut(.upArrow)
                Button("Zpět") { commander.tab.goBack() }.keyboardShortcut("[")
                Button("Vpřed") { commander.tab.goForward() }.keyboardShortcut("]")
                Divider()
                Button("Větší písmo") { settings.fontSize = min(18, settings.fontSize + 0.5) }.keyboardShortcut("+")
                Button("Menší písmo") { settings.fontSize = max(10, settings.fontSize - 0.5) }.keyboardShortcut("-")
            }
        }

        Settings {
            SettingsView(settings: settings)
                .id(settings.themeKey)                    // nový profil = překreslit i nastavení
                .preferredColorScheme(settings.isDark ? .dark : .light)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        ArchiveIO.cleanupViewCopies()                    // pracovní kopie z archivů z minula
        MainActor.assumeIsolated {
            AppIcon.apply()
            Updater.shared.checkOnLaunch()
            Permissions.askOnLaunchIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SMBMount.autoMountAll() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated { Commander.shared.save() } }
}
