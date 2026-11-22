import SwiftUI
import AppKit

// Pozn.: bez @State (SDK z Command Line Tools nemá SwiftUI makra) – stav drží ObservableObject.

struct MainView: View {
    @ObservedObject var commander: Commander
    @ObservedObject var settings: FTSettings

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(commander: commander, settings: settings)
            Rectangle().fill(UI.border).frame(height: 1)
            HStack(spacing: 0) {
                PanelView(panel: commander.left, side: .left, commander: commander, settings: settings)
                Rectangle().fill(UI.border).frame(width: 1)
                PanelView(panel: commander.right, side: .right, commander: commander, settings: settings)
            }
            if !commander.ops.isEmpty {
                Rectangle().fill(UI.border).frame(height: 1)
                OpsBar(commander: commander)
            }
            Rectangle().fill(UI.border).frame(height: 1)
            CommandLineBar(commander: commander)
            FunctionKeyBar(commander: commander)
        }
        .background(UI.app)
        .sheet(item: $commander.output) { out in OutputSheet(out: out) { commander.output = nil } }
        .onAppear { DispatchQueue.main.async { commander.focus(commander.activeSide) } }
    }
}

// MARK: - Horní lišta

struct Toolbar: View {
    @ObservedObject var commander: Commander
    @ObservedObject var settings: FTSettings

    private func button(_ symbol: String, _ help: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { ChromeIcon(symbol: symbol, active: active) }.buttonStyle(.plain).help(help)
    }

    var body: some View {
        HStack(spacing: 4) {
            button("arrow.clockwise", "Obnovit oba panely (⇧⌘R)") { commander.refreshAll() }
            button("eye.slash", "Skryté soubory (⇧⌘.)", active: settings.showHidden) {
                settings.showHidden.toggle(); commander.refreshAll()
            }
            Rectangle().fill(UI.border).frame(width: 1, height: 16).padding(.horizontal, 4)
            button("chevron.left", "Zpět (⌘[)") { commander.tab.goBack() }
            button("chevron.right", "Vpřed (⌘])") { commander.tab.goForward() }
            button("arrow.up", "Nadřazená složka (⌘↑)") { commander.tab.up() }
            Rectangle().fill(UI.border).frame(width: 1, height: 16).padding(.horizontal, 4)
            button("arrow.left.arrow.right", "Prohodit panely (⌘U)") { commander.swapPanels() }
            button("equal.square", "Druhý panel = stejná složka (⌘=)") { commander.mirrorToOther() }
            button("folder.badge.plus", "Nová složka (F7 / ⌘7)") { commander.mkdir() }
            Spacer()
            button("terminal", "Otevřít Terminál ve složce aktivního panelu") { commander.openTerminalHere() }
            button("magnifyingglass", "Zobrazit ve Finderu") { commander.revealInFinder() }
            Rectangle().fill(UI.border).frame(width: 1, height: 16).padding(.horizontal, 4)
            SettingsButton()
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(UI.chrome)
    }
}

/// Ozubené kolečko v horní liště – otevře Nastavení (⌘,), stejně jako v SSHTool.
struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { ChromeIcon(symbol: "gearshape") }
                .buttonStyle(.plain)
                .help("Nastavení (⌘,)")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { ChromeIcon(symbol: "gearshape") }
            .buttonStyle(.plain)
            .help("Nastavení (⌘,)")
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var panel: Panel
    let side: Side
    @ObservedObject var commander: Commander
    @ObservedObject var settings: FTSettings

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(panel: panel, side: side, commander: commander)
            PanelContent(tab: panel.tab, side: side, commander: commander, settings: settings)
                .id(panel.tab.id)
        }
    }
}

struct PanelTabBar: View {
    @ObservedObject var panel: Panel
    let side: Side
    let commander: Commander

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(panel.tabs) { t in
                    PanelTabChip(tab: t, active: t.id == panel.activeID, closable: panel.tabs.count > 1,
                                 select: { panel.select(t.id); commander.focus(side) },
                                 close: { panel.close(t.id) })
                }
                Button { panel.newTab(); commander.focus(side) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                        .frame(width: 20, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(UI.card))
                }
                .buttonStyle(.plain).foregroundStyle(UI.textSecondary).help("Nová záložka (⌘T)")
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .frame(height: 26)
        .background(UI.chrome)
    }
}

struct PanelTabChip: View {
    @ObservedObject var tab: PanelTab
    let active: Bool
    let closable: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(UI.textTertiary)
            Text(tab.title).font(.system(size: 11, weight: active ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            if closable {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .semibold))
                        .frame(width: 14, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(UI.textTertiary)
            }
        }
        .padding(.leading, 7).padding(.trailing, closable ? 2 : 7)
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? UI.cardSelected : UI.card))
        .overlay(alignment: .bottom) {
            Rectangle().fill(UI.accent).frame(height: 2).padding(.horizontal, 5).opacity(active ? 1 : 0)
        }
        .foregroundStyle(active ? UI.text : UI.textSecondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(tab.dir.path)
    }
}

struct PanelContent: View {
    @ObservedObject var tab: PanelTab
    let side: Side
    @ObservedObject var commander: Commander
    @ObservedObject var settings: FTSettings

    private var isActive: Bool { commander.activeSide == side }

    var body: some View {
        VStack(spacing: 0) {
            DriveBar(tab: tab, side: side, commander: commander)
            // cesta – aktivní panel zvýrazněný barvou profilu (jako modrý pruh v TC)
            HStack(spacing: 6) {
                TextField("", text: $tab.pathField, onCommit: {
                    tab.submitPath()
                    commander.focus(side)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? SwiftUI.Color.white : UI.textSecondary)
                if tab.opening { ProgressView().controlSize(.small) }
                if let a = tab.archive {
                    Text(a.index.format + (a.index.encrypted ? " · 🔒 šifrovaný" : "") + (ArchiveIO.isZip(a.file) ? "" : " · jen pro čtení"))
                        .font(.system(size: 10.5)).foregroundStyle(isActive ? SwiftUI.Color.white.opacity(0.85) : UI.textTertiary)
                }
                if !tab.marked.isEmpty {
                    Text("\(tab.marked.count) označeno").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isActive ? SwiftUI.Color.white : UI.accent)
                }
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(isActive ? UI.accent : UI.card)
            if let e = tab.error {
                Text(e).font(.system(size: 11)).foregroundStyle(UI.error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(UI.list)
            }
            FileTable(tab: tab, side: side, commander: commander, fontSize: settings.fontSize)
            Rectangle().fill(UI.border).frame(height: 1)
            Text(tab.summary)
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(UI.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 20)
                .background(UI.chrome)
        }
    }
}

/// Výběr „disku“: svazky a oblíbená místa + volné místo (jako řádek s disky v TC).
struct DriveBar: View {
    @ObservedObject var tab: PanelTab
    let side: Side
    let commander: Commander

    private var space: (free: Int64, total: Int64, name: String)? { Place.space(for: tab.dir) }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Section("Svazky") {
                    ForEach(Place.volumes()) { p in
                        Button { tab.go(p.url); commander.focus(side) } label: { Label(p.name, systemImage: p.symbol) }
                    }
                }
                Section("Místa") {
                    ForEach(Place.favorites()) { p in
                        Button { tab.go(p.url); commander.focus(side) } label: { Label(p.name, systemImage: p.symbol) }
                    }
                }
            } label: {
                Label(space?.name.isEmpty == false ? space!.name : "Disk", systemImage: "internaldrive")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Výběr disku / místa (⌥⌘\(side == .left ? "1" : "2"))")
            ServerMenu(tab: tab, side: side, commander: commander)
            if let r = tab.remote {
                Text(r.session.config.scheme.uppercased() + " · " + r.session.config.dest)
                    .font(.system(size: 10.5)).foregroundStyle(UI.textSecondary).lineLimit(1)
            } else if let s = space {
                Text("\(Fmt.bytes(s.free)) volných z \(Fmt.bytes(s.total))")
                    .font(.system(size: 10.5)).foregroundStyle(UI.textSecondary).lineLimit(1)
            }
            Spacer()
            Button { commander.sameAsOther(side) } label: {
                Image(systemName: side == .left ? "arrow.left.square" : "arrow.right.square").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(UI.textSecondary)
            .help("Otevřít stejnou složku jako vedlejší panel")
            Button { if tab.remote != nil { tab.goRemote("/") } else { tab.go(URL(fileURLWithPath: "/")) } } label: { Text("/").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                .buttonStyle(.plain).foregroundStyle(UI.textSecondary).help("Kořen svazku")
            Button { if let r = tab.remote { tab.goRemote(r.session.home) } else { tab.go(FileManager.default.homeDirectoryForCurrentUser) } } label: { Text("~").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                .buttonStyle(.plain).foregroundStyle(UI.textSecondary).help("Domovská složka")
            Button { tab.up() } label: { Text("..").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                .buttonStyle(.plain).foregroundStyle(UI.textSecondary).help("Nadřazená složka")
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(UI.chrome)
    }
}

// MARK: - Spodní část

struct OpsBar: View {
    @ObservedObject var commander: Commander
    var body: some View {
        VStack(spacing: 4) {
            ForEach(commander.ops) { OpRow(op: $0) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(UI.sidebar)
    }
}

struct OpRow: View {
    @ObservedObject var op: FileOperation
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: op.finished ? (op.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                  : op.kind == .delete ? "trash" : "doc.on.doc")
                .foregroundStyle(op.finished ? (op.errors.isEmpty ? UI.ok : UI.warn) : UI.accent)
            Text(op.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            if let f = op.fraction {
                ProgressView(value: f).frame(width: 160)
            } else if !op.finished {
                ProgressView().controlSize(.small)
            }
            Text(op.detail).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1)
            Spacer()
            if !op.finished {
                Button("Zrušit") { op.cancel.value = true }.controlSize(.small)
            }
        }
    }
}

struct CommandLineBar: View {
    @ObservedObject var commander: Commander
    var body: some View {
        HStack(spacing: 6) {
            Text(commander.tab.dir.path + ">")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(UI.textSecondary)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: 360, alignment: .trailing)
            TextField("příkaz (zsh) – spustí se ve složce aktivního panelu; cd změní složku panelu", text: $commander.commandLine,
                      onCommit: { commander.runCommandLine() })
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(UI.list)
    }
}

struct FunctionKeyBar: View {
    @ObservedObject var commander: Commander

    private func key(_ f: String, _ mac: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(f).font(.system(size: 10, weight: .bold)).foregroundStyle(UI.accent)
                Text(title).font(.system(size: 11)).foregroundStyle(UI.text)
                Text(mac).font(.system(size: 9.5)).foregroundStyle(UI.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 0) {
            key("F3", "⌘3", "Zobrazit") { commander.view() }
            sep
            key("F4", "⌘4", "Upravit") { commander.edit() }
            sep
            key("F5", "⌘5", "Kopírovat") { commander.transfer(move: false) }
            sep
            key("F6", "⌘6", "Přesunout") { commander.transfer(move: true) }
            sep
            key("F7", "⌘7", "Nová složka") { commander.mkdir() }
            sep
            key("F8", "⌘8", "Smazat") { commander.delete() }
            sep
            key("⇧F6", "⌘R", "Přejmenovat") { commander.rename() }
            sep
            key("Alt+F5", "⌥⌘5", "Zabalit") { commander.pack() }
            sep
            key("Alt+F9", "⌥⌘9", "Rozbalit") { commander.unpack() }
        }
        .frame(height: 24)
        .background(UI.chrome)
    }

    private var sep: some View { Rectangle().fill(UI.border).frame(width: 1, height: 14) }
}

struct OutputSheet: View {
    @ObservedObject var out: CommandOutput
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("$ " + out.command).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer()
                if out.running { ProgressView().controlSize(.small) }
            }
            Text(out.dir).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(UI.textSecondary)
            ScrollView {
                Text(out.text.isEmpty ? " " : out.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.list))
            HStack {
                Spacer()
                if out.running { Button("Zastavit") { out.stop() } }
                Button("Zavřít") { out.stop(); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 720, height: 460)
        .background(UI.sidebar)
    }
}

/// Nabídka serverů u panelu: uložená připojení, nové připojení (⌘K), odpojení.
struct ServerMenu: View {
    @ObservedObject var tab: PanelTab
    let side: Side
    let commander: Commander
    @ObservedObject var store = RemoteStore.shared

    var body: some View {
        Menu {
            ForEach(store.configs) { c in
                Button { tab.connect(c); commander.focus(side) } label: { Label(c.title, systemImage: "server.rack") }
            }
            if !store.configs.isEmpty { Divider() }
            Button("Připojit k serveru… (⌘K)") { commander.focus(side); commander.connectDialog() }
            if tab.remote != nil {
                Button("Odpojit (⇧⌘K)") { commander.focus(side); commander.disconnect() }
            }
        } label: {
            Label(tab.remote == nil ? "Server" : "Připojeno", systemImage: tab.remote == nil ? "network" : "network.badge.shield.half.filled")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("SFTP / SCP / FTP")
    }
}
