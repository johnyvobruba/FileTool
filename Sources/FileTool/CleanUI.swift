import SwiftUI
import AppKit

// Okno Úklid (⇧⌘U) ve stylu CleanMyMac: vlevo moduly, vpravo obsah modulu.

enum CleanModule: String, CaseIterable, Identifiable {
    case smart, junk, large, old, uninstall, lens, dupes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: return "Chytrá kontrola"
        case .junk: return "Systémový odpad"
        case .large: return "Velké soubory"
        case .old: return "Staré soubory"
        case .uninstall: return "Odinstalace aplikací"
        case .lens: return "Mapa disku"
        case .dupes: return "Duplicity"
        }
    }
    var subtitle: String {
        switch self {
        case .smart: return "Jedno prohledání – odpad, velké soubory a zbytky aplikací"
        case .junk: return "Mezipaměti, logy, vývojářské soubory, instalátory, Koš"
        case .large: return "Co zabírá nejvíc místa"
        case .old: return "Soubory, které jsi dlouho neotevřel (i menší než 100 MB)"
        case .uninstall: return "Aplikace i se všemi soubory, zbytky po smazaných aplikacích"
        case .lens: return "Kde je místo – klikni na blok a jdi hlouběji"
        case .dupes: return "Stejné soubory podle obsahu (SHA-256)"
        }
    }
    var icon: String {
        switch self {
        case .smart: return "sparkles"
        case .junk: return "trash.circle"
        case .large: return "arrow.up.doc"
        case .old: return "clock.arrow.circlepath"
        case .uninstall: return "xmark.app"
        case .lens: return "square.grid.3x3.square"
        case .dupes: return "doc.on.doc"
        }
    }
}

@MainActor
final class CleanHub: ObservableObject {
    @Published var module: CleanModule = .smart
    let junk = JunkModel()
    let large = LargeOldModel()
    let old = LargeOldModel(oldMode: true)
    let uninstall = UninstallModel()
    let lens = SpaceLensModel()
    let dupes = DuplicatesModel()

    func smartScan() {
        junk.scan()
        large.minSizeMB = 500
        large.scan()
        uninstall.scanOrphans()
    }
}

// MARK: - Okno

@MainActor
enum CleanupWindow {
    private static var window: NSWindow?
    private static var hub: CleanHub?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let h = CleanHub()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Úklid"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: CleanRootView(hub: h).preferredColorScheme(FTSettings.shared.isDark ? .dark : .light))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                hub?.junk.stop(); hub?.large.stop(); hub?.old.stop(); hub?.dupes.stop()
                window = nil; hub = nil
            }
        }
        window = w; hub = h
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

struct CleanRootView: View {
    @ObservedObject var hub: CleanHub
    @ObservedObject var volumes = SidebarModel.shared

    private var bootFree: String {
        volumes.volumes.first { $0.url.path == "/" }.map { Fmt.bytes($0.free) + " volných" } ?? ""
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ÚKLID").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(UI.textTertiary)
                    .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
                ForEach(CleanModule.allCases) { m in
                    let on = hub.module == m
                    Button { hub.module = m } label: {
                        HStack(spacing: 10) {
                            Image(systemName: m.icon).font(.system(size: 13)).frame(width: 20)
                                .foregroundStyle(on ? UI.accent : UI.textSecondary)
                            Text(m.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? UI.text : UI.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(on ? UI.rowSelected : SwiftUI.Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if !CleanFS.hasFullDiskAccess {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Omezený přístup", systemImage: "lock.trianglebadge.exclamationmark").font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(UI.warn)
                        Text("Bez Plného přístupu k disku nevidí FileTool Koš, Mail a další složky.")
                            .font(.system(size: 10.5)).foregroundStyle(UI.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Button("Nastavit přístup…") { Permissions.guide() }.buttonStyle(SKButton())
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(UI.card.opacity(0.6)))
                }
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").foregroundStyle(UI.textTertiary)
                    Text("Macintosh HD · \(bootFree)").font(.system(size: 10.5)).foregroundStyle(UI.textTertiary)
                }
                .padding(10)
            }
            .padding(.horizontal, 10)
            .frame(width: 230)
            .background(UI.sidebar)
            Rectangle().fill(UI.border).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hub.module.title).font(SK.pageTitleFont).foregroundStyle(UI.text)
                        Text(hub.module.subtitle).font(SK.subtitleFont).foregroundStyle(UI.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24).frame(height: 72).background(UI.chrome)
                Rectangle().fill(UI.border).frame(height: 1)
                Group {
                    switch hub.module {
                    case .smart: SmartScanView(hub: hub, junk: hub.junk, large: hub.large, un: hub.uninstall)
                    case .junk: JunkView(m: hub.junk)
                    case .large: LargeOldView(m: hub.large)
                    case .old: LargeOldView(m: hub.old)
                    case .uninstall: UninstallView(m: hub.uninstall)
                    case .lens: SpaceLensView(m: hub.lens)
                    case .dupes: DuplicatesView(m: hub.dupes)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(UI.app)
        }
        .frame(minWidth: 980, minHeight: 620)
        .tint(UI.accent)
    }
}

// MARK: - Společné prvky

struct BigActionButton: View {
    let title: String
    let running: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [UI.accent, UI.accent.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: UI.accent.opacity(0.45), radius: 14)
                if running { ProgressView().controlSize(.large).tint(.white) }
                else { Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white) }
            }
            .frame(width: 120, height: 120)
        }
        .buttonStyle(.plain)
    }
}

struct CheckBox: View {
    let state: Bool?                 // nil = částečně
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : state == nil ? "minus.square.fill" : "square")
                .font(.system(size: 14)).foregroundStyle(state == false ? UI.textTertiary : UI.accent)
        }
        .buttonStyle(.plain)
    }
}

struct ScanBar: View {
    let running: Bool
    let status: String
    let scan: () -> Void
    var stop: (() -> Void)? = nil
    var scanTitle = "Prohledat"
    var body: some View {
        HStack(spacing: 10) {
            if running {
                if let stop { Button("Zastavit", action: stop).buttonStyle(SKButton()) }
                ProgressView().controlSize(.small)
            } else {
                Button(scanTitle, action: scan).buttonStyle(SKButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
            Text(status).font(SK.helpFont).foregroundStyle(UI.textSecondary).lineLimit(1)
            Spacer()
        }
    }
}

private func folderPicker(_ path: Binding<String>) -> some View {
    HStack(spacing: 6) {
        Text("Ve složce").font(SK.helpFont).foregroundStyle(UI.textSecondary)
        TextField("", text: path).textFieldStyle(.roundedBorder).font(SK.monoFont).frame(minWidth: 220)
        Button("Vybrat…") {
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
            p.directoryURL = URL(fileURLWithPath: path.wrappedValue)
            if p.runModal() == .OK, let u = p.url { path.wrappedValue = u.path }
        }.buttonStyle(SKButton())
    }
}

private func dateText(_ d: Date?) -> String { d.map { Fmt.date.string(from: $0) } ?? "neznámé" }

// MARK: - Chytrá kontrola

struct SmartScanView: View {
    @ObservedObject var hub: CleanHub
    @ObservedObject var junk: JunkModel
    @ObservedObject var large: LargeOldModel
    @ObservedObject var un: UninstallModel

    private var running: Bool { junk.running || large.running || un.running }
    private var scanned: Bool { junk.scanned }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 10)
            if !scanned && !running {
                Image(systemName: "sparkles").font(.system(size: 54)).foregroundStyle(UI.accent)
                Text("Najdi, co na Macu zbytečně zabírá místo").font(.system(size: 18, weight: .semibold)).foregroundStyle(UI.text)
                Text("Prohledá mezipaměti a logy, vývojářské soubory, staré instalátory, soubory nad 500 MB a zbytky po smazaných aplikacích. Nic se nesmaže bez tvého potvrzení.")
                    .font(SK.bodyFont).foregroundStyle(UI.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            if scanned || running {
                HStack(spacing: 14) {
                    card("Systémový odpad", "trash.circle", junk.running ? "…" : Fmt.bytes(junk.totalChecked),
                         junk.running ? junk.status : "k vyčištění (z \(Fmt.bytes(junk.total)))", .junk)
                    card("Velké soubory", "doc.badge.clock", large.running ? "…" : Fmt.bytes(large.files.reduce(0) { $0 + $1.size }),
                         large.running ? large.status : "\(large.files.count) souborů nad \(large.minSizeMB) MB", .large)
                    card("Zbytky aplikací", "xmark.app", un.running ? "…" : Fmt.bytes(un.orphans.reduce(0) { $0 + $1.size }),
                         un.running ? un.status : "\(un.orphans.count) položek po smazaných aplikacích", .uninstall)
                }
            }
            HStack(spacing: 30) {
                BigActionButton(title: scanned ? "Znovu" : "Prohledat", running: running) { hub.smartScan() }
                if scanned && !running && junk.totalChecked > 0 {
                    BigActionButton(title: "Vyčistit", running: false) { junk.clean() }
                        .tip("Vyčistí zaškrtnutý systémový odpad (\(Fmt.bytes(junk.totalChecked))). Velké soubory a zbytky zkontroluj v jejich modulech.")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ title: String, _ icon: String, _ value: String, _ detail: String, _ target: CleanModule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
            Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(UI.accent)
            Text(detail).font(SK.helpFont).foregroundStyle(UI.textSecondary).lineLimit(2)
            Spacer(minLength: 0)
            Button("Zkontrolovat") { hub.module = target }.buttonStyle(SKButton())
        }
        .padding(16)
        .frame(width: 230, height: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(UI.card.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UI.border, lineWidth: 1))
    }
}

// MARK: - Systémový odpad

struct JunkView: View {
    @ObservedObject var m: JunkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScanBar(running: m.running, status: m.status, scan: { m.scan() }, stop: { m.stop() })
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(m.categories) { cat in category(cat) }
                    if m.scanned && m.categories.isEmpty {
                        Text("Nic k vyčištění 🎉").foregroundStyle(UI.textSecondary).padding(30)
                    }
                }
            }
            HStack {
                Text("Vybráno \(Fmt.bytes(m.totalChecked))").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                Spacer()
                Button("Vyčistit") { m.clean() }.buttonStyle(SKButton(kind: .primary)).disabled(m.totalChecked == 0 || m.running)
            }
        }
    }

    private func category(_ cat: JunkCategory) -> some View {
        let open = m.expanded.contains(cat.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                CheckBox(state: m.state(cat)) { m.toggleCategory(cat) }
                Image(systemName: cat.icon).font(.system(size: 15)).foregroundStyle(cat.permanent ? UI.error : UI.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                    Text(cat.help).font(SK.helpFont).foregroundStyle(UI.textSecondary).lineLimit(1)
                }
                Spacer()
                let sel = cat.items.filter { m.checked.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.bytes(sel)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(sel > 0 ? UI.accent : UI.textTertiary)
                    Text("z \(Fmt.bytes(cat.size))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(UI.textSecondary)
                }
                Button {
                    if open { m.expanded.remove(cat.id) } else { m.expanded.insert(cat.id) }
                } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(UI.textSecondary)
                }
                .buttonStyle(.plain).tip("\(cat.items.count) položek")
            }
            .padding(12)
            if open {
                VStack(spacing: 0) {
                    ForEach(cat.items.prefix(300)) { i in
                        HStack(spacing: 10) {
                            CheckBox(state: m.checked.contains(i.id)) {
                                if m.checked.contains(i.id) { m.checked.remove(i.id) } else { m.checked.insert(i.id) }
                            }
                            Text(i.name).font(.system(size: 12)).foregroundStyle(i.note.isEmpty ? UI.text : UI.warn).lineLimit(1)
                            Spacer()
                            Text(Fmt.bytes(i.size)).font(.system(size: 12).monospacedDigit()).foregroundStyle(UI.textSecondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).foregroundStyle(UI.textTertiary).tip("Zobrazit ve Finderu")
                        }
                        .padding(.horizontal, 12).padding(.leading, 34).frame(height: 26)
                    }
                    if cat.items.count > 300 { Text("… a dalších \(cat.items.count - 300)").font(SK.helpFont).foregroundStyle(UI.textTertiary).padding(6) }
                }
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(UI.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: SK.cardRadius).stroke(UI.border, lineWidth: 1))
    }
}

// MARK: - Velké a staré soubory

struct LargeOldView: View {
    @ObservedObject var m: LargeOldModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                folderPicker($m.root)
                Text("Větší než").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                SKMenuPicker(selection: $m.minSizeMB, options: m.oldMode
                             ? [(1, "1 MB"), (10, "10 MB"), (50, "50 MB"), (100, "100 MB")]
                             : [(10, "10 MB"), (50, "50 MB"), (100, "100 MB"), (500, "500 MB"), (1024, "1 GB")], width: 100)
                Toggle("Včetně ~/Library", isOn: $m.includeLibrary).toggleStyle(.checkbox).fixedSize()
            }
            ScanBar(running: m.running, status: m.status, scan: { m.scan() }, stop: { m.stop() })
            HStack(spacing: 12) {
                Text("Typ").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                SKMenuPicker(selection: $m.kind, options: FileKind.allCases.map { ($0, $0.title) }, width: 150)
                Text("Stáří").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                SKMenuPicker(selection: $m.age, options: AgeFilter.allCases.filter { !m.oldMode || $0 != .anyAge }.map { ($0, $0.title) }, width: 210)
                Text("Řadit").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Menu {
                    ForEach(BigSort.allCases) { s in Button(s.title) { m.sortOrder = s.comparators } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
                .tip("Předvolby řazení. „Velké a zároveň staré“ = velikost × doba bez otevření. Řadit jde i klikem na hlavičku sloupce.")
                Spacer()
                Text("\(m.shown.count) · \(Fmt.bytes(m.shownSize))").font(SK.helpFont).foregroundStyle(UI.textSecondary)
            }
            Table(m.shown, selection: $m.selection, sortOrder: $m.sortOrder) {
                TableColumn("Název", value: \.name) { f in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 16, height: 16)
                        Text(f.url.lastPathComponent).lineLimit(1)
                    }
                }
                TableColumn("Umístění", value: \.folder) { f in
                    Text(f.folder.replacingOccurrences(of: CleanFS.home, with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(UI.textSecondary)
                }
                TableColumn("Velikost", value: \.size) { f in Text(Fmt.bytes(f.size)).monospacedDigit() }.width(85)
                TableColumn("Naposledy otevřeno", value: \.lastUsedKey) { f in Text(dateText(f.lastUsed)).monospacedDigit() }.width(125)
                TableColumn("Změněno", value: \.modifiedKey) { f in Text(dateText(f.modified)).monospacedDigit() }.width(115)
            }
            .contextMenu(forSelectionType: URL.self) { _ in
                Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting(Array(m.selection)) }
                Button("Přesunout do Koše…") { m.trashSelected() }
            } primaryAction: { urls in NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            HStack {
                Text(m.selection.isEmpty ? "Vyber soubory (⌘ / ⇧ + klik)" : "Vybráno \(m.selection.count) · \(Fmt.bytes(m.selectedSize))")
                    .font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Spacer()
                Button("Zobrazit v panelu") {
                    let urls = (m.selection.isEmpty ? m.shown.map(\.url) : Array(m.selection))
                    Commander.shared.tab.showResults(urls, title: m.oldMode ? "Staré soubory" : "Velké soubory")
                    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
                }
                .buttonStyle(SKButton()).disabled(m.shown.isEmpty)
                .tip("Výsledky jako seznam v aktivním panelu – např. zkopírovat na externí disk (F5) a pak smazat")
                Button("Přesunout do Koše…") { m.trashSelected() }.buttonStyle(SKButton(kind: .primary)).disabled(m.selection.isEmpty)
            }
        }
    }
}

// MARK: - Odinstalace

struct UninstallView: View {
    @ObservedObject var m: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $m.showOrphans) {
                    Text("Aplikace").tag(false); Text("Zbytky po smazaných aplikacích").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                Spacer()
                if m.running { ProgressView().controlSize(.small) }
                Text(m.status).font(SK.helpFont).foregroundStyle(UI.textSecondary).lineLimit(1)
            }
            if m.showOrphans { orphans } else { appsPane }
        }
        .onAppear { if !m.scanned && !m.running { m.scan() } }
    }

    private var appsPane: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                HStack {
                    TextField("Hledat aplikaci", text: $m.filter).textFieldStyle(.roundedBorder)
                    Toggle("Nejdéle nepoužité", isOn: $m.sortByUse).toggleStyle(.checkbox).font(.system(size: 11.5))
                }
                List(m.shownApps, selection: $m.selected) { a in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text("Naposledy: \(dateText(a.lastUsed))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(a.size < 0 ? "…" : Fmt.bytes(a.size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(a.url)
                }
            }
            .frame(width: 360)
            VStack(alignment: .leading, spacing: 10) {
                if let a = m.app {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(UI.text)
                            Text("\(a.bundleID) · verze \(a.version)").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                            Text("Aplikace \(a.size < 0 ? "…" : Fmt.bytes(a.size)) + data \(Fmt.bytes(m.relatedChecked))")
                                .font(SK.helpFont).foregroundStyle(UI.textSecondary)
                        }
                    }
                    Text("Související soubory").font(SK.titleFont).foregroundStyle(UI.text)
                    ScrollView {
                        VStack(spacing: 0) {
                            if m.related.isEmpty { Text("Žádná nalezená data v ~/Library.").font(SK.helpFont).foregroundStyle(UI.textSecondary).padding(10) }
                            ForEach(m.related) { i in
                                HStack(spacing: 10) {
                                    CheckBox(state: m.checkedRelated.contains(i.id)) {
                                        if m.checkedRelated.contains(i.id) { m.checkedRelated.remove(i.id) } else { m.checkedRelated.insert(i.id) }
                                    }
                                    Text(i.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        .foregroundStyle(i.note.hasSuffix("podle názvu, ověř") ? UI.warn : UI.text)
                                    Spacer()
                                    Text(Fmt.bytes(i.size)).font(.system(size: 12).monospacedDigit()).foregroundStyle(UI.textSecondary)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.plain).foregroundStyle(UI.textTertiary)
                                }
                                .padding(.horizontal, 10).frame(height: 26)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(UI.card.opacity(0.55)))
                    HStack {
                        Text("Odstraní se aplikace a zaškrtnutá data – vše do Koše.").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                        Spacer()
                        Button("Odinstalovat") { m.uninstall() }.buttonStyle(SKButton(kind: .danger))
                    }
                } else {
                    Spacer()
                    Text("Vyber aplikaci vlevo").font(SK.bodyFont).foregroundStyle(UI.textSecondary).frame(maxWidth: .infinity)
                    Spacer()
                }
            }
        }
    }

    private var orphans: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(m.orphans.isEmpty ? "Najít zbytky" : "Hledat znovu") { m.scanOrphans() }.buttonStyle(SKButton(kind: .primary)).disabled(m.running)
                Text("Položky v ~/Library pojmenované podle aplikace, která už na Macu není. Je to odhad – nic není zaškrtnuté předem.")
                    .font(SK.helpFont).foregroundStyle(UI.textSecondary)
            }
            List(m.orphans) { i in
                HStack(spacing: 10) {
                    CheckBox(state: m.checkedOrphans.contains(i.id)) {
                        if m.checkedOrphans.contains(i.id) { m.checkedOrphans.remove(i.id) } else { m.checkedOrphans.insert(i.id) }
                    }
                    Text(i.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.bytes(i.size)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                }
            }
            HStack {
                Button("Vybrat vše") { m.checkedOrphans = Set(m.orphans.map(\.id)) }.buttonStyle(SKButton()).disabled(m.orphans.isEmpty)
                Spacer()
                Text("Vybráno \(Fmt.bytes(m.orphans.filter { m.checkedOrphans.contains($0.id) }.reduce(0) { $0 + $1.size }))")
                    .font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Button("Přesunout do Koše…") { m.trashOrphans() }.buttonStyle(SKButton(kind: .primary)).disabled(m.checkedOrphans.isEmpty)
            }
        }
    }
}

// MARK: - Mapa disku

struct SpaceLensView: View {
    @ObservedObject var m: SpaceLensModel

    private let palette: [SwiftUI.Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .brown]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button { m.up() } label: { Image(systemName: "chevron.left") }.buttonStyle(SKButton()).disabled(m.path.count < 2)
                ForEach(m.path, id: \.self) { u in
                    Button(u.path == "/" ? "Disk" : FileManager.default.displayName(atPath: u.path)) { m.open(u) }
                        .buttonStyle(.plain).foregroundStyle(u == m.current ? UI.text : UI.accent)
                    if u != m.current { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(UI.textTertiary) }
                }
                Spacer()
                if m.running { ProgressView().controlSize(.small) }
                Text(Fmt.bytes(m.total)).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(UI.text)
                Menu("Začít od") {
                    Button("Domovská složka") { m.setRoot(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Celý disk (/)") { m.setRoot(URL(fileURLWithPath: "/")) }
                    Button("Jiná složka…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { m.setRoot(u) }
                    }
                }
                .frame(width: 110)
                Button { m.load(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(SKButton()).tip("Přepočítat")
            }
            HStack(alignment: .top, spacing: 14) {
                GeometryReader { g in
                    let shown = Array(m.nodes.filter { $0.size > 0 }.prefix(60))
                    let rects = Treemap.layout(shown.map { Double($0.size) }, in: CGRect(origin: .zero, size: g.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                            let r = i < rects.count ? rects[i] : .zero
                            let color = palette[i % palette.count]
                            RoundedRectangle(cornerRadius: 6)
                                .fill(color.opacity(m.hover == n.url ? 0.95 : 0.7))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.app, lineWidth: 2))
                                .overlay(alignment: .topLeading) {
                                    if r.width > 70 && r.height > 34 {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(n.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                            Text(Fmt.bytes(n.size)).font(.system(size: 10.5))
                                        }
                                        .foregroundStyle(.white).padding(6)
                                    }
                                }
                                .frame(width: max(0, r.width), height: max(0, r.height))
                                .offset(x: r.minX, y: r.minY)
                                .onHover { inside in m.hover = inside ? n.url : (m.hover == n.url ? nil : m.hover) }
                                .onTapGesture { if n.isDir { m.open(n.url) } else { m.selection = n.url } }
                                .tip("\(n.name) · \(Fmt.bytes(n.size))" + (n.isDir ? " · klikni pro vstup" : ""))
                                .contextMenu { nodeMenu(n) }
                        }
                    }
                }
                .frame(minWidth: 400)
                List(m.nodes, selection: $m.selection) { n in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path)).resizable().frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.name).font(.system(size: 12)).lineLimit(1)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 2).fill(UI.accent.opacity(0.6))
                                    .frame(width: g.size.width * CGFloat(m.total > 0 ? Double(n.size) / Double(m.total) : 0))
                            }
                            .frame(height: 3)
                        }
                        Spacer()
                        Text(n.size == 0 && m.running ? "…" : Fmt.bytes(n.size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(n.url)
                    .contextMenu { nodeMenu(n) }
                    .onTapGesture(count: 2) { if n.isDir { m.open(n.url) } }
                }
                .frame(width: 300)
            }
        }
        .onAppear { if m.nodes.isEmpty && !m.running { m.load() } }
    }

    @ViewBuilder private func nodeMenu(_ n: LensNode) -> some View {
        if n.isDir { Button("Otevřít") { m.open(n.url) } }
        Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
        Button("Otevřít v aktivním panelu") {
            Commander.shared.tab.go(n.isDir ? n.url : n.url.deletingLastPathComponent(), select: n.isDir ? nil : n.url.lastPathComponent)
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
        Divider()
        Button("Přesunout do Koše…") { m.trash(n) }.disabled(CleanFS.isProtected(n.url.path))
    }
}

// MARK: - Duplicity

struct DuplicatesView: View {
    @ObservedObject var m: DuplicatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                folderPicker($m.root)
                Text("Od velikosti").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                SKMenuPicker(selection: $m.minSizeMB, options: [(0, "100 kB"), (1, "1 MB"), (10, "10 MB"), (100, "100 MB")], width: 100)
            }
            ScanBar(running: m.running, status: m.status, scan: { m.scan() }, stop: { m.stop() })
            HStack {
                Button("Ponechat nejnovější") { m.autoSelect(keepNewest: true) }.buttonStyle(SKButton()).disabled(m.groups.isEmpty)
                Button("Ponechat nejstarší") { m.autoSelect(keepNewest: false) }.buttonStyle(SKButton()).disabled(m.groups.isEmpty)
                Button("Nic") { m.checked = [] }.buttonStyle(SKButton()).disabled(m.groups.isEmpty)
                Spacer()
                Text("Zbytečně zabráno \(Fmt.bytes(m.wasted))").font(SK.helpFont).foregroundStyle(UI.textSecondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(m.groups) { g in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(g.files[0].url.lastPathComponent).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.text).lineLimit(1)
                                Spacer()
                                Text("\(g.files.count)× \(Fmt.bytes(g.files[0].size))").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            ForEach(g.files) { f in
                                HStack(spacing: 10) {
                                    CheckBox(state: m.checked.contains(f.id)) { m.toggle(f, in: g) }
                                    Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: CleanFS.home, with: "~"))
                                        .font(.system(size: 11.5)).foregroundStyle(m.checked.contains(f.id) ? UI.textSecondary : UI.text)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.date.string(from: f.modified)).font(.system(size: 11).monospacedDigit()).foregroundStyle(UI.textTertiary)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.plain).foregroundStyle(UI.textTertiary)
                                }
                                .padding(.horizontal, 12).padding(.leading, 6).frame(height: 24)
                            }
                        }
                        .padding(.bottom, 6)
                        .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(UI.card.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: SK.cardRadius).stroke(UI.border, lineWidth: 1))
                    }
                }
            }
            HStack {
                Text("Vybráno \(m.checked.count) · \(Fmt.bytes(m.checkedSize))").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                Spacer()
                Button("Přesunout do Koše…") { m.trashChecked() }.buttonStyle(SKButton(kind: .primary)).disabled(m.checked.isEmpty || m.running)
            }
        }
    }
}
