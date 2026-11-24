import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Okno nastavení (⌘,) – stejné uspořádání jako v SSHTool: postranní navigace, záhlaví stránky,
// karty sekcí. Komponenty SK* odpovídají SSHTool (vstupy 32 pt, řádek 44 pt, karty 10 pt).

// MARK: - Design tokeny a komponenty

enum SK {
    static let inputHeight: CGFloat = 32
    static let rowHeight: CGFloat = 44
    static let compactRow: CGFloat = 36
    static let inputRadius: CGFloat = 7
    static let cardRadius: CGFloat = 10
    static let hPad: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let pageTitleFont = Font.system(size: 22, weight: .semibold)
    static let subtitleFont = Font.system(size: 13)
    static let contentMaxWidth: CGFloat = 760
    static let bodyFont = Font.system(size: 13)
    static let helpFont = Font.system(size: 11.5)
    static let monoFont = Font.system(size: 12, design: .monospaced)
}

struct SKSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var plain = false
    let content: Content

    init(_ title: String, subtitle: String? = nil, plain: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.plain = plain; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SK.titleFont).foregroundStyle(UI.text)
                if let subtitle {
                    Text(subtitle).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if plain {
                content
            } else {
                VStack(spacing: 0) { content }
                    .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(UI.card.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: SK.cardRadius).stroke(UI.border, lineWidth: 1))
            }
        }
    }
}

struct SKRow<Control: View>: View {
    let title: String
    var help: String? = nil
    var first = false
    let control: Control

    init(_ title: String, help: String? = nil, first: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title; self.help = help; self.first = first; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SK.bodyFont).foregroundStyle(UI.text)
                if let help {
                    Text(help).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, SK.hPad).padding(.vertical, 8)
        .frame(minHeight: SK.rowHeight)
        .overlay(alignment: .top) { if !first { SKDivider() } }
    }
}

struct SKDivider: View {
    var body: some View { Rectangle().fill(UI.border.opacity(0.6)).frame(height: 1).padding(.leading, SK.hPad) }
}

struct SKToggle: View {
    let isOn: Binding<Bool>
    var body: some View { Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden() }
}

struct SKButton: ButtonStyle {
    enum Kind { case normal, primary, danger, subtle }
    var kind: Kind = .normal
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let bg: SwiftUI.Color = {
            switch kind {
            case .primary: return UI.accent
            case .danger: return UI.error.opacity(0.15)
            case .normal: return UI.card
            case .subtle: return SwiftUI.Color.clear
            }
        }()
        let fg: SwiftUI.Color = kind == .primary ? .white : (kind == .danger ? UI.error : UI.text)
        return configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: SK.inputHeight)
            .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: SK.inputRadius)
                .stroke(kind == .normal ? UI.border : SwiftUI.Color.clear, lineWidth: 1))
            .foregroundStyle(fg)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct SKMenuPicker<T: Hashable>: View {
    let selection: Binding<T>
    let options: [(T, String)]
    var width: CGFloat = 220

    var body: some View {
        let current = options.first { $0.0 == selection.wrappedValue }?.1 ?? "Vlastní"
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    selection.wrappedValue = options[i].0
                } label: {
                    if options[i].0 == selection.wrappedValue { Label(options[i].1, systemImage: "checkmark") }
                    else { Text(options[i].1) }
                }
            }
        } label: {
            HStack {
                Text(current).font(SK.bodyFont).foregroundStyle(UI.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UI.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: SK.inputHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: width, height: SK.inputHeight)
        .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(UI.app))
        .overlay(RoundedRectangle(cornerRadius: SK.inputRadius).stroke(UI.border, lineWidth: 1))
    }
}

struct KeyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(UI.textSecondary)
            .padding(.horizontal, 7).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(UI.app))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.border, lineWidth: 1))
    }
}

// MARK: - Navigace

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, servers, permissions, shortcuts, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Obecné"
        case .appearance: return "Vzhled"
        case .servers: return "Servery"
        case .permissions: return "Oprávnění"
        case .shortcuts: return "Klávesové zkratky"
        case .about: return "O aplikaci"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Panely, mazání a editor"
        case .appearance: return "Barevný profil aplikace a ikona"
        case .servers: return "Uložená připojení SFTP, SCP, FTP a SMB"
        case .permissions: return "Přístup ke složkám a diskům"
        case .shortcuts: return "Přehled klávesových zkratek"
        case .about: return AppCredits.line
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .servers: return "network"
        case .permissions: return "lock.shield"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNav: ObservableObject {
    /// Sdílené – okno se při změně profilu překreslí (.id), vybraná stránka ale zůstane.
    static let shared = SettingsNav()
    @Published var pane: SettingsPane = .general
}

enum AppCredits {
    static let author = "Jan Vobruba"
    static let line = "Vytvořil Jan Vobruba · Claude · Vibecoding"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

// MARK: - Kořen okna

struct SettingsView: View {
    @ObservedObject var settings: FTSettings
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(UI.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(UI.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: SK.sectionGap) { content }
                        .frame(maxWidth: SK.contentMaxWidth, alignment: .leading)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(nav.pane)
            }
            .background(UI.app)
        }
        .frame(minWidth: 820, idealWidth: 980, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .tint(UI.accent)
        .background(WindowTitleSetter(title: "Nastavení"))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nastavení")
                .font(.system(size: 11, weight: .semibold)).tracking(0.4)
                .foregroundStyle(UI.textTertiary)
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
            ForEach(SettingsPane.allCases) { p in
                let on = nav.pane == p
                Button { nav.pane = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.icon).font(.system(size: 12)).frame(width: 18)
                            .foregroundStyle(on ? UI.accent : UI.textSecondary)
                        Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? UI.text : UI.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(on ? UI.rowSelected : SwiftUI.Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("FileTool \(AppCredits.version)").font(.system(size: 10.5, weight: .medium))
                Text(AppCredits.line).font(.system(size: 10))
            }
            .foregroundStyle(UI.textTertiary)
            .padding(10)
        }
        .padding(.horizontal, 10)
        .frame(width: 230)
        .background(UI.sidebar)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(nav.pane.title).font(SK.pageTitleFont).foregroundStyle(UI.text)
                Text(nav.pane.subtitle).font(SK.subtitleFont).foregroundStyle(UI.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(height: 76)
        .background(UI.chrome)
    }

    @ViewBuilder private var content: some View {
        switch nav.pane {
        case .general: SettingsGeneralPane(settings: settings)
        case .appearance: SettingsAppearancePane(settings: settings)
        case .servers: SettingsServersPane()
        case .permissions: SettingsPermissionsPane()
        case .shortcuts: SettingsShortcutsPane()
        case .about: SettingsAboutPane(settings: settings)
        }
    }
}

// MARK: - Obecné

struct SettingsGeneralPane: View {
    @ObservedObject var settings: FTSettings

    private var editorOptions: [(String, String)] {
        var o: [(String, String)] = [("", "Výchozí textový editor (TextEdit)")]
        o += Editors.installed().map { ($0.path, $0.name) }
        if !settings.editorPath.isEmpty, !o.contains(where: { $0.0 == settings.editorPath }) {
            o.append((settings.editorPath, (settings.editorPath as NSString).lastPathComponent))
        }
        return o
    }

    var body: some View {
        SKSection("Panely") {
            SKRow("Zobrazovat skryté soubory", help: "Soubory začínající tečkou. Přepnutí také ⇧⌘.", first: true) {
                SKToggle(isOn: $settings.showHidden)
            }
            SKRow("Složky vždy nahoře", help: "Při jakémkoliv řazení jsou složky před soubory (jako v Total Commanderu).") {
                SKToggle(isOn: $settings.foldersFirst)
            }
            SKRow("Náhledy ve složkách s obrázky", help: "Složka jen s obrázky se automaticky zobrazí jako mřížka náhledů. Ručně přepneš ⌥⌘T nebo ikonou v liště.") {
                SKToggle(isOn: $settings.autoThumbs)
            }
            SKRow("Velikost náhledů", help: "Také posuvníkem nad mřížkou.") {
                Slider(value: $settings.thumbSize, in: 64...320).frame(width: 180)
            }
            SKRow("Velikost písma seznamu", help: "Také ⌘+ / ⌘−.") {
                HStack(spacing: 8) {
                    Text(String(format: "%.1f pt", settings.fontSize)).font(SK.monoFont).foregroundStyle(UI.textSecondary)
                    Stepper("", value: $settings.fontSize, in: 10...18, step: 0.5).labelsHidden()
                }
            }
        }
        SKSection("Mazání") {
            SKRow("F8 přesouvá do Koše", help: "⇧F8 (⇧⌘8) maže vždy trvale. Na serveru a v archivu Koš není.", first: true) {
                SKToggle(isOn: $settings.useTrash)
            }
            SKRow("Potvrzovat mazání", help: "Trvalé smazání se potvrzuje vždy.") {
                SKToggle(isOn: $settings.confirmDelete)
            }
        }
        SKSection("Editor") {
            SKRow("Editor pro F4", help: "Nabízí nainstalované editory (VS Code, Sublime, BBEdit, CotEditor, Nova, Zed…). Bez volby se použije výchozí textový editor macOS.", first: true) {
                HStack(spacing: 6) {
                    SKMenuPicker(selection: $settings.editorPath, options: editorOptions, width: 240)
                    Button("Jiná…") {
                        let p = NSOpenPanel()
                        p.title = "Aplikace pro úpravy souborů (F4)"
                        p.directoryURL = URL(fileURLWithPath: "/Applications")
                        p.allowedContentTypes = [.application]
                        if p.runModal() == .OK, let u = p.url { settings.editorPath = u.path }
                    }
                    .buttonStyle(SKButton())
                }
            }
        }
    }
}

// MARK: - Vzhled

struct SettingsAppearancePane: View {
    @ObservedObject var settings: FTSettings

    var body: some View {
        SKSection("Barevný profil aplikace",
                  subtitle: "Stejné profily jako v SSHTool. Profil aktivuješ kliknutím na kartu.", plain: true) {
            VStack(spacing: 8) {
                ForEach(Theme.all) { t in
                    ThemeCard(theme: t, selected: settings.themeID == t.id) { settings.selectTheme(t.id) }
                }
            }
        }
        SKSection("Ikona aplikace") {
            SKRow("Ikona v Docku podle profilu",
                  help: "Barvy ikony v Docku a v přepínači ⌘Tab odpovídají vybranému profilu. Finder a Launchpad ukazují původní ikonu.",
                  first: true) {
                SKToggle(isOn: $settings.themedIcon)
            }
        }
        SKSection("Automatický vzhled") {
            SKRow("Režim", help: "Podle macOS: ve tmavém režimu zvolený tmavý profil, ve světlém Arctic Light.", first: true) {
                Picker("", selection: $settings.appearance) {
                    Text("Světlý").tag("light")
                    Text("Tmavý").tag("dark")
                    Text("Podle macOS").tag("system")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
        }
    }
}

@MainActor
final class ThemeCardModel: ObservableObject {
    @Published var hover = false
}

/// Karta profilu – celá klikací; vpravo náhled seznamu souborů v barvách profilu.
struct ThemeCard: View {
    let theme: Theme
    let selected: Bool
    let pick: () -> Void
    @StateObject private var m = ThemeCardModel()

    private func c(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(theme.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                        if selected {
                            HStack(spacing: 3) { Image(systemName: "checkmark.circle.fill"); Text("Aktivní") }
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(UI.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(UI.accent.opacity(0.15)))
                        }
                    }
                    Text(theme.note).font(SK.helpFont).foregroundStyle(UI.textSecondary).lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach([theme.sidebarBackground, theme.tabActiveBackground, theme.accentColor,
                                 theme.statusConnected, theme.statusConnecting, theme.statusError], id: \.self) { h in
                            RoundedRectangle(cornerRadius: 3).fill(c(h)).frame(width: 12, height: 12)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.border, lineWidth: 0.5))
                        }
                    }
                }
                .frame(width: (g.size.width - 46) * 0.55, alignment: .leading)
                FileListPreview(theme: theme, width: (g.size.width - 46) * 0.45)
            }
            .padding(.horizontal, 16)
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: 100)
        .background(RoundedRectangle(cornerRadius: SK.cardRadius)
            .fill(selected ? UI.rowSelected.opacity(0.6) : m.hover ? UI.hover : UI.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: SK.cardRadius)
            .stroke(selected ? UI.accent : UI.border, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { m.hover = $0 }
        .onTapGesture(perform: pick)
        .tip(selected ? "Aktivní profil" : "Kliknutím aktivovat")
    }
}

/// Zmenšený seznam souborů: složka, označený soubor, kurzor, archiv, spustitelný soubor.
struct FileListPreview: View {
    let theme: Theme
    let width: CGFloat
    private func c(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row("[..]", "", "<DIR>", color: theme.ansiBright[4])
            row("Projekty", "", "<DIR>", color: theme.ansiBright[4])
            row("report", "pdf", "1 204 k", color: theme.ansiBright[1])
            row("zaloha", "zip", "88 M", color: theme.ansiBright[5], cursor: true)
            row("deploy", "sh", "4 k", color: theme.ansiBright[2])
        }
        .font(.system(size: 9.5, design: .monospaced))
        .lineLimit(1)
        .padding(6)
        .frame(width: width, height: 80, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(c(theme.background)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(c(theme.borderColor), lineWidth: 1))
    }

    private func row(_ name: String, _ ext: String, _ size: String, color: String, cursor: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(ext).frame(width: 26, alignment: .leading)
            Text(size).frame(width: 46, alignment: .trailing)
        }
        .foregroundColor(c(color))
        .padding(.horizontal, 4)
        .frame(height: 13)
        .background(RoundedRectangle(cornerRadius: 3).fill(cursor ? c(theme.itemSelectedBackground) : SwiftUI.Color.clear))
    }
}

// MARK: - Servery

struct SettingsServersPane: View {
    @ObservedObject private var store = RemoteStore.shared

    var body: some View {
        SKSection("Uložená připojení", subtitle: "Hesla se ukládají jen do Klíčenky macOS (pokud to u připojení zapneš), nikdy do nastavení.") {
            if store.configs.isEmpty {
                SKRow("Zatím žádné uložené připojení", help: "Přidáš ho v dialogu Připojit k serveru (⌘K).", first: true) { EmptyView() }
            }
            ForEach(Array(store.configs.enumerated()), id: \.element.id) { i, c in
                SKRow(c.title, help: (c.group.map { $0 + " · " } ?? "") + "\(c.scheme)://\(c.dest):\(c.port)" + (c.savePassword ? " · heslo v Klíčence" : "") + (c.autoMount == true ? " · připojit při spuštění" : ""), first: i == 0) {
                    Button("Smazat") { store.remove(c) }.buttonStyle(SKButton(kind: .danger))
                        .tip("Smaže uložené připojení i jeho heslo z Klíčenky")
                }
            }
        }
        HStack {
            Button { Commander.shared.connectDialog() } label: { Label("Přidat nebo upravit…", systemImage: "plus") }
                .buttonStyle(SKButton(kind: .primary))
            Spacer()
        }
        SKSection("Import a export", subtitle: "Hesla se nikdy neimportují ani neexportují. Duplicity (protokol + host + port + uživatel) se přeskočí.") {
            SKRow("Servery ze SSHTool", help: RemoteImport.sshToolAvailable
                  ? "Načte SSH a FTP servery uložené v SSHTool (RDP, telnet a sériové linky vynechá). SSH servery se přidají jako SFTP, nebo SCP podle nastavení prohlížeče souborů."
                  : "SSHTool na tomto Macu nemá uložené servery.", first: true) {
                Button("Importovat ze SSHTool") { RemoteImport.importFromSSHTool() }
                    .buttonStyle(SKButton(kind: .primary)).disabled(!RemoteImport.sshToolAvailable)
            }
            SKRow("Importovat ze souboru (JSON)", help: "Formát FileTool i SSHTool (export i sessions.json), lze vybrat víc souborů.") {
                Button("Importovat…") { RemoteImport.importPanel() }.buttonStyle(SKButton())
            }
            SKRow("Exportovat servery", help: "Bez hesel – bezpečné ke sdílení s kolegy.") {
                Button("Exportovat…") { RemoteImport.exportPanel() }.buttonStyle(SKButton()).disabled(store.configs.isEmpty)
            }
        }
        SKSection("Vzor JSON pro kolegy", subtitle: "Pole: name, proto (sftp / scp / ftp / smb), host, port, user, group, path, ftpTLS (explicit / implicit / \"\"). Adresy ve vzoru jsou z dokumentačních rozsahů (RFC 5737).") {
            HStack {
                Button { RemoteImport.copyTemplate() } label: { Label("Kopírovat vzor", systemImage: "doc.on.doc") }.buttonStyle(SKButton())
                Spacer()
            }
            .padding(.horizontal, SK.hPad).padding(.vertical, 10)
            Text(RemoteImport.templateJSON)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(UI.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(UI.list))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.border, lineWidth: 1))
                .padding(.horizontal, SK.hPad).padding(.bottom, 14)
        }
        SKSection("Protokoly") {
            SKRow("SFTP", help: "Systémové ssh: klíče, agent i ~/.ssh/config. Neznámý klíč serveru se před uložením ukáže k potvrzení.", first: true) { EmptyView() }
            SKRow("SCP", help: "Pro zařízení bez SFTP (některé síťové prvky). Výpis přes ssh, přenosy přes scp.") { EmptyView() }
            SKRow("SMB", help: "Sdílené složky Windows / NAS – připojí se jako disk a panel je prochází jako běžné složky. Heslo spravuje macOS (Klíčenka).") { EmptyView() }
            SKRow("FTP / FTPS", help: "Přes curl, výchozí explicitní TLS. Nešifrované FTP posílá heslo čitelně – jen v izolované síti.") { EmptyView() }
        }
    }
}

// MARK: - Oprávnění

struct SettingsPermissionsPane: View {
    var body: some View {
        let ok = Permissions.hasFullDiskAccess
        SKSection("Plný přístup k disku", subtitle: "Jedno oprávnění pro všechny složky – macOS se pak neptá zvlášť na Plochu, Dokumenty, Stažené, síťové a externí disky, Koš nebo Mail.") {
            SKRow(ok ? "Zapnuto" : "Vypnuto", help: ok ? "FileTool vidí do všech složek." : "Bez něj se macOS ptá u každé chráněné složky zvlášť a Úklid nevidí Koš, Mail a další místa.", first: true) {
                Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 20)).foregroundStyle(ok ? UI.ok : UI.warn)
            }
            if !ok {
                SKRow("1. Otevřít nastavení", help: "Soukromí a zabezpečení → Plný přístup k disku.") {
                    Button("Otevřít") { Permissions.openSettings() }.buttonStyle(SKButton(kind: .primary))
                }
                SKRow("2. Přidat FileTool", help: "V seznamu klikni na „+“ a vyber FileTool, nebo ho přetáhni z Finderu. Pak zapni přepínač.") {
                    Button("Ukázat FileTool ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.buttonStyle(SKButton())
                }
                SKRow("3. Restartovat FileTool", help: "Oprávnění platí až po novém spuštění.") {
                    Button("Restartovat") { Permissions.relaunch() }.buttonStyle(SKButton())
                }
            }
        }
        SKSection("Poznámka k aktualizacím") {
            SKRow("Oprávnění po aktualizaci", help: "FileTool je podepsaný bez certifikátu Apple Developer. macOS proto může po aktualizaci oprávnění „zapomenout“ – v seznamu FileTool vypni a znovu zapni (případně odeber „−“ a přidej znovu).", first: true) { EmptyView() }
        }
    }
}

// MARK: - Klávesové zkratky

struct SettingsShortcutsPane: View {
    private let groups: [(String, [(String, String)])] = [
        ("Soubory (F-klávesy z TC)", [("F3 / ⌘3", "Zobrazit (Quick Look)"), ("F4 / ⌘4", "Upravit"), ("F5 / ⌘5", "Kopírovat do druhého panelu"),
                                       ("F6 / ⌘6", "Přesunout"), ("⇧F6 / ⌘R", "Přejmenovat"), ("F7 / ⌘7", "Nová složka"),
                                       ("F8 / ⌘8", "Do Koše"), ("⇧F8 / ⇧⌘8", "Smazat trvale")]),
        ("Archivy", [("⌥⌘5", "Zabalit do druhého panelu (i s heslem)"), ("⌥⌘9", "Rozbalit do druhého panelu"), ("Enter", "Otevřít archiv jako složku")]),
        ("Panely", [("Tab", "Přepnout panel"), ("⌘T / ⌘W", "Nová / zavřít záložku"), ("⌃Tab", "Další záložka"), ("⌘U", "Prohodit panely"),
                    ("⌘=", "Druhý panel = stejná složka"), ("⌥⌘1 / ⌥⌘2", "Výběr disku vlevo / vpravo"), ("⌘[ / ⌘]", "Zpět / vpřed"),
                    ("⌘↑ / ⌫", "Nadřazená složka"), ("⇧⌘.", "Skryté soubory"), ("⇧⌘R", "Obnovit")]),
        ("Výběr", [("Mezerník", "Označit položku"), ("⌘A / ⌘D", "Označit vše / nic"), ("+ / −", "Označit / odznačit maskou"), ("*", "Obrátit výběr")]),
        ("Servery", [("⌘K", "Připojit k serveru"), ("⇧⌘K", "Odpojit")]),
        ("Nástroje", [("⌘F / Alt+F7", "Hledat soubory"), ("⇧⌘U", "Úklid (odpad, velké soubory, odinstalace, mapa disku, duplicity)"), ("⌃⌘S", "Boční panel")]),
        ("Okno", [("⌥⌘↓", "Otevřít výchozí aplikací"), ("⌥⌘R", "Zobrazit ve Finderu"), ("⌥⌘C", "Kopírovat cestu"), ("⌘,", "Nastavení")]),
    ]

    var body: some View {
        ForEach(groups.indices, id: \.self) { gi in
            let g = groups[gi]
            SKSection(g.0) {
                ForEach(Array(g.1.enumerated()), id: \.offset) { i, item in
                    HStack {
                        Text(item.1).font(SK.bodyFont).foregroundStyle(UI.text)
                        Spacer()
                        KeyHint(text: item.0)
                    }
                    .padding(.horizontal, SK.hPad)
                    .frame(height: SK.compactRow)
                    .overlay(alignment: .top) { if i > 0 { SKDivider() } }
                }
            }
        }
    }
}

// MARK: - O aplikaci

struct SettingsAboutPane: View {
    @ObservedObject var settings: FTSettings
    @ObservedObject private var up = Updater.shared

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("FileTool").font(.system(size: 20, weight: .semibold)).foregroundStyle(UI.text)
                Text("Verze \(AppCredits.version)").font(SK.bodyFont).foregroundStyle(UI.textSecondary)
                Text(AppCredits.line).font(SK.bodyFont).foregroundStyle(UI.text)
            }
        }
        SKSection("Aktualizace") {
            SKRow("Verze \(up.currentVersion)", help: up.repo.map { "Zdroj: github.com/\($0)" } ?? "Repozitář není nastavený.", first: true) {
                HStack(spacing: 8) {
                    if up.checking { ProgressView().controlSize(.small) }
                    if !up.status.isEmpty { Text(up.status).font(SK.helpFont).foregroundStyle(UI.textSecondary) }
                    Button("Zkontrolovat") { up.check(interactive: true) }
                        .buttonStyle(SKButton()).disabled(up.checking || up.repo == nil)
                }
            }
            SKRow("Kontrolovat automaticky", help: "Při spuštění (max. 4× denně) se zeptá GitHubu na novou verzi.") {
                SKToggle(isOn: $settings.autoUpdateCheck)
                    .tip("Jen dotaz na api.github.com (veřejné repo, bez přihlášení). Instalace vždy až po potvrzení; balíček musí mít platný podpis Ed25519.")
            }
            if let r = up.repo, let u = URL(string: "https://github.com/\(r)") {
                SKRow("Projekt na GitHubu", help: "Popis, změny a stažení") {
                    Button("Otevřít") { NSWorkspace.shared.open(u) }.buttonStyle(SKButton())
                }
            }
        }
        SKSection("Autorství") {
            SKRow("Autor", first: true) { Text(AppCredits.author).font(SK.bodyFont) }
            SKRow("Vytvořeno s") { Text("Claude (Anthropic) · Vibecoding").font(SK.bodyFont) }
            SKRow("Archivy", help: "libarchive (BSD) ze systému macOS; volitelně 7-Zip (7zz) z Homebrew.") { EmptyView() }
        }
    }
}

/// Titulek okna „Nastavení“ místo systémového „FileTool Settings“.
struct WindowTitleSetter: NSViewRepresentable {
    let title: String
    final class V: NSView {
        var title = ""
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.title = title }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.title = title; return v }
    func updateNSView(_ v: V, context: Context) { v.title = title; if v.window?.title != title { v.window?.title = title } }
}
