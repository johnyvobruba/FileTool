import SwiftUI
import AppKit

/// Nastavení aplikace (UserDefaults). Jedna instance pro celou aplikaci.
@MainActor
final class FTSettings: ObservableObject {
    static let shared = FTSettings()
    private let d = UserDefaults.standard

    @Published var themeID: String        { didSet { d.set(themeID, forKey: "themeID"); applyTheme() } }
    @Published var appearance: String     { didSet { d.set(appearance, forKey: "appearance"); applyTheme() } }
    @Published var showHidden: Bool       { didSet { d.set(showHidden, forKey: "showHidden") } }
    @Published var foldersFirst: Bool     { didSet { d.set(foldersFirst, forKey: "foldersFirst") } }
    @Published var useTrash: Bool         { didSet { d.set(useTrash, forKey: "useTrash") } }
    @Published var confirmDelete: Bool    { didSet { d.set(confirmDelete, forKey: "confirmDelete") } }
    @Published var editorPath: String     { didSet { d.set(editorPath, forKey: "editorPath") } }
    @Published var fontSize: Double       { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var themedIcon: Bool       { didSet { d.set(themedIcon, forKey: "themedIcon"); AppIcon.apply() } }
    @Published var autoUpdateCheck: Bool  { didSet { d.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }

    /// Klíč aktuálního motivu – při změně se okno přebuduje.
    @Published private(set) var themeKey = ""

    private init() {
        // lokální konstanta – před inicializací všech vlastností se nesmí sahat na self (ani self.d)
        let ud = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { ud.object(forKey: k) as? Bool ?? def }
        themeID = ud.string(forKey: "themeID") ?? Theme.midnight.id
        appearance = ud.string(forKey: "appearance") ?? "dark"
        showHidden = b("showHidden", false)
        foldersFirst = b("foldersFirst", true)
        useTrash = b("useTrash", true)
        confirmDelete = b("confirmDelete", true)
        editorPath = ud.string(forKey: "editorPath") ?? ""
        fontSize = ud.object(forKey: "fontSize") as? Double ?? 12.5
        themedIcon = b("themedIcon", true)
        autoUpdateCheck = b("autoUpdateCheck", true)
        applyTheme()
        // „Podle macOS“: reagovat na přepnutí světlý/tmavý režim
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    var theme: Theme { ThemeStore.ui }
    var isDark: Bool { ThemeStore.ui.isDark }

    func applyTheme() {
        let t = ThemeStore.resolve(themeID: themeID, appearance: appearance)
        guard t.id != themeKey else { return }
        ThemeStore.ui = t
        themeKey = t.id
        NotificationCenter.default.post(name: ThemeStore.changed, object: nil)
        DispatchQueue.main.async { AppIcon.apply() }
    }

    func selectTheme(_ id: String) {
        themeID = id
        let t = Theme.byID(id)
        if !t.isDark { appearance = "light" } else if appearance == "light" { appearance = "dark" }
    }
}
