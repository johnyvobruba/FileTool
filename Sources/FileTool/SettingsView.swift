import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: FTSettings
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section("Barevný profil (stejné jako SSHTool)") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(Theme.all) { t in
                        Button { settings.selectTheme(t.id) } label: { ThemeChip(theme: t, selected: settings.themeID == t.id) }
                            .buttonStyle(.plain)
                    }
                }
                Picker("Režim", selection: $settings.appearance) {
                    Text("Tmavý").tag("dark"); Text("Světlý").tag("light"); Text("Podle macOS").tag("system")
                }
                .pickerStyle(.segmented)
                Toggle("Ikona v Docku podle profilu", isOn: $settings.themedIcon)
            }
            Section("Panely") {
                Toggle("Zobrazovat skryté soubory (⇧⌘.)", isOn: $settings.showHidden)
                Toggle("Složky vždy nahoře", isOn: $settings.foldersFirst)
                LabeledContent("Velikost písma") {
                    Stepper(String(format: "%.1f pt", settings.fontSize), value: $settings.fontSize, in: 10...18, step: 0.5)
                }
            }
            Section("Operace") {
                Toggle("F8 přesouvá do Koše (⇧F8 = trvale)", isOn: $settings.useTrash)
                Toggle("Potvrzovat mazání", isOn: $settings.confirmDelete)
                LabeledContent("Editor pro F4") {
                    HStack {
                        // nainstalované editory (VS Code, Sublime, BBEdit, CotEditor, Nova, Zed…) + vlastní volba
                        Picker("", selection: $settings.editorPath) {
                            Text("Výchozí textový editor (TextEdit)").tag("")
                            ForEach(Editors.installed(), id: \.path) { e in Text(e.name).tag(e.path) }
                            if !settings.editorPath.isEmpty, !Editors.installed().contains(where: { $0.path == settings.editorPath }) {
                                Text((settings.editorPath as NSString).lastPathComponent).tag(settings.editorPath)
                            }
                        }
                        .labelsHidden().frame(width: 230)
                        Button("Jiná…") {
                            let p = NSOpenPanel()
                            p.directoryURL = URL(fileURLWithPath: "/Applications")
                            p.allowedContentTypes = [.application]
                            if p.runModal() == .OK, let u = p.url { settings.editorPath = u.path }
                        }
                    }
                }
            }
            Section("Aktualizace") {
                Toggle("Kontrolovat při spuštění", isOn: $settings.autoUpdateCheck)
                HStack {
                    Text("Verze \(updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Text(updater.status).foregroundStyle(.secondary)
                    Button("Zkontrolovat") { updater.check(interactive: true) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }
}

struct ThemeChip: View {
    let theme: Theme
    let selected: Bool
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach([theme.background, theme.accentColor, theme.ansiBright[4], theme.ansiBright[1]], id: \.self) { h in
                    Rectangle().fill(SwiftUI.Color(hex: h) ?? .gray).frame(width: 10, height: 18)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(theme.name).font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? UI.cardSelected : UI.card))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? UI.accent : SwiftUI.Color.clear, lineWidth: 1.5))
    }
}
