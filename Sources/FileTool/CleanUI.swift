import SwiftUI
import AppKit

// Okno Úklid (⇧⌘U) ve stylu CleanMyMac: vlevo lišta modulů, vpravo modul na vlastním barevném přechodu.

enum CleanModule: String, CaseIterable, Identifiable {
    case smart, junk, large, old, uninstall, performance, lens, dupes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: return "Chytrá kontrola"
        case .junk: return "Systémový odpad"
        case .large: return "Velké soubory"
        case .old: return "Staré soubory"
        case .uninstall: return "Odinstalace aplikací"
        case .performance: return "Výkon"
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
        case .performance: return "Služby při startu, položky při přihlášení, údržba"
        case .lens: return "Kde je místo – klikni na bublinu a jdi hlouběji"
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
        case .performance: return "bolt.fill"
        case .lens: return "circle.hexagongrid"
        case .dupes: return "doc.on.doc"
        }
    }
}

@MainActor
final class CleanHub: ObservableObject {
    @Published var module: CleanModule = .smart { didSet { C.module = module } }
    let junk = JunkModel()
    let large = LargeOldModel()
    let old = LargeOldModel(oldMode: true)
    let uninstall = UninstallModel()
    let perf = PerformanceModel()
    let lens = SpaceLensModel()
    let dupes = DuplicatesModel()

    init() { C.module = .smart }

    func smartScan() {
        junk.scan()
        large.minSizeMB = 500
        large.scan()
        uninstall.scanOrphans()
        perf.scan()
    }
}

// MARK: - Okno

@MainActor
enum CleanupWindow {
    private static var window: NSWindow?
    private static var hub: CleanHub?

    nonisolated(unsafe) private static var themeObserver: NSObjectProtocol?

    private static func build(_ w: NSWindow, _ h: CleanHub) {
        let dark = ThemeStore.ui.isDark && !ThemeStore.ui.mixedContent      // Neon Orchid: světlá plocha
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = NSHostingView(rootView: CleanRootView(hub: h).preferredColorScheme(dark ? .dark : .light))
    }

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let h = CleanHub()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Úklid"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        build(w, h)
        // změna profilu nebo stylu rozhraní: okno se přebarví (rozpracované hledání zůstává v hubu)
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeStore.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let w = window, let h = hub { build(w, h) } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                hub?.junk.stop(); hub?.large.stop(); hub?.old.stop(); hub?.dupes.stop()
                window = nil; hub = nil
                if let o = themeObserver { NotificationCenter.default.removeObserver(o); themeObserver = nil }
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

    private var boot: SidebarVolume? { volumes.volumes.first { $0.url.path == "/" } }

    var body: some View {
        ZStack {
            hub.module.gradient.ignoresSafeArea()
                .animation(.easeInOut(duration: 0.35), value: hub.module)
            // jemná záře v rohu jako v CMM
            RadialGradient(colors: [Modern.glow, .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
                .ignoresSafeArea()
            HStack(spacing: 0) {
                rail
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        VStack(spacing: 2) {
                            Text(hub.module.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.text2)
                        }
                        Spacer()
                    }
                    .frame(height: 38)
                    Group {
                        switch hub.module {
                        case .smart: SmartScanView(hub: hub, junk: hub.junk, large: hub.large, un: hub.uninstall, perf: hub.perf)
                        case .junk: JunkView(m: hub.junk)
                        case .large: LargeOldView(m: hub.large)
                        case .old: LargeOldView(m: hub.old)
                        case .uninstall: UninstallView(m: hub.uninstall)
                        case .performance: PerformanceView(m: hub.perf)
                        case .lens: SpaceLensView(m: hub.lens)
                        case .dupes: DuplicatesView(m: hub.dupes)
                        }
                    }
                    .id(hub.module)
                    .scrollContentBackground(.hidden)          // seznamy a tabulky průhledné na přechodu
                    .padding(.horizontal, 26).padding(.bottom, 22).padding(.top, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .foregroundStyle(C.text)
        .tint(C.accent)
        .frame(minWidth: 1040, minHeight: 660)
    }

    /// Lišta modulů vlevo: barevné dlaždice s ikonou, název, dole disk a oprávnění.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 34)
            ForEach(CleanModule.allCases) { m in
                let on = hub.module == m
                Button { withAnimation(.easeInOut(duration: 0.25)) { hub.module = m } } label: {
                    HStack(spacing: 10) {
                        TileIcon(symbol: m.icon, hue: m.hue, size: 28, glow: on)
                        Text(m.title).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? C.railText : C.railText2)
                        Spacer()
                    }
                    .padding(.horizontal, 8).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? C.railSelected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !Permissions.hasFullDiskAccess {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Omezený přístup", systemImage: "lock.trianglebadge.exclamationmark").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.yellow)
                    Text("Bez Plného přístupu k disku nevidí FileTool Koš, Mail a další složky.")
                        .font(.system(size: 10.5)).foregroundStyle(C.railText2).fixedSize(horizontal: false, vertical: true)
                    Button("Nastavit přístup…") { Permissions.guide() }.buttonStyle(GlassButton())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(C.railCard))
            }
            if let b = boot {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Macintosh HD", systemImage: "internaldrive").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(C.railText)
                    Text("\(Fmt.bytes(b.free)) volných").font(.system(size: 10.5)).foregroundStyle(C.railText2)
                }
                .padding(10)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .frame(width: 220)
        .background(C.rail)
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
                Circle().fill(Modern.brand.primary == nil
                              ? LinearGradient(colors: [Modern.gradA, Modern.gradB], startPoint: .topLeading, endPoint: .bottomTrailing)
                              : Modern.primaryGradient(onDark: C.heroOn))
                    .shadow(color: (Modern.brand.primary.map { C.hex($0.0) } ?? Modern.gradB).opacity(Brand.vivid ? 0.5 : 0.2), radius: Brand.vivid ? 16 : 8)
                Circle().fill(LinearGradient(colors: [.white.opacity(Brand.vivid ? 0.28 : 0.08), .clear], startPoint: .top, endPoint: .center))
                    .padding(3)
                if running { ProgressView().controlSize(.large).tint(Modern.primaryText(onDark: C.heroOn)) }
                else { Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Modern.primaryText(onDark: C.heroOn)) }
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
                .font(.system(size: 14)).foregroundStyle(state == false ? C.text3 : C.accent)
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
                if let stop { Button("Zastavit", action: stop).buttonStyle(GlassButton()) }
                ProgressView().controlSize(.small)
            } else {
                Button(scanTitle, action: scan).buttonStyle(GlassButton(prominent: true)).keyboardShortcut(.defaultAction)
            }
            Text(status).font(SK.helpFont).foregroundStyle(C.text2).lineLimit(1)
            Spacer()
        }
    }
}

private func folderPicker(_ path: Binding<String>) -> some View {
    HStack(spacing: 6) {
        Text("Ve složce").font(SK.helpFont).foregroundStyle(C.text2)
        TextField("", text: path).textFieldStyle(.roundedBorder).font(SK.monoFont).frame(minWidth: 220)
        Button("Vybrat…") {
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
            p.directoryURL = URL(fileURLWithPath: path.wrappedValue)
            if p.runModal() == .OK, let u = p.url { path.wrappedValue = u.path }
        }.buttonStyle(GlassButton())
    }
}

private func dateText(_ d: Date?) -> String { d.map { Fmt.date.string(from: $0) } ?? "neznámé" }

// MARK: - Chytrá kontrola

struct SmartScanView: View {
    @ObservedObject var hub: CleanHub
    @ObservedObject var junk: JunkModel
    @ObservedObject var large: LargeOldModel
    @ObservedObject var un: UninstallModel
    @ObservedObject var perf: PerformanceModel

    private var running: Bool { junk.running || large.running || un.running || perf.running }
    private var scanned: Bool { junk.scanned }
    private var trash: Int64 { junk.categories.first { $0.id == "trash" }?.size ?? 0 }

    var body: some View {
        VStack(spacing: 22) {
            if !scanned && !running {
                Spacer()
                VStack(spacing: 22) {
                    ZStack {
                        Circle().fill(RadialGradient(colors: [(C.heroOn ? SwiftUI.Color.white.opacity(0.35) : Modern.gradB.opacity(Brand.vivid ? 0.5 : 0.25)), .clear],
                                                     center: .center, startRadius: 4, endRadius: 140))
                            .frame(width: 280, height: 280)
                        Image(systemName: "sparkles").font(.system(size: 80, weight: .light))
                            .foregroundStyle(C.dark ? AnyShapeStyle(SwiftUI.Color.white) : AnyShapeStyle(Modern.accentGradient))
                    }
                    Text("Vítej v Úklidu").font(.system(size: 30, weight: .bold)).foregroundStyle(C.heroText)
                    Text("Najde odpad, velké soubory, zbytky aplikací a zbytečné služby při startu. Nic se nesmaže bez tvého potvrzení.")
                        .font(.system(size: 14)).foregroundStyle(C.heroText2).multilineTextAlignment(.center).frame(maxWidth: 520)
                    BigActionButton(title: "Prohledat", running: false) { hub.smartScan() }
                }
                .padding(.vertical, C.heroOn ? 26 : 0).padding(.horizontal, C.heroOn ? 60 : 0)
                .frame(maxWidth: .infinity)
                .background(HeroPanel())
                Spacer()
            } else {
                VStack(spacing: 10) {
                    Text(running ? "Prohledávám tvůj Mac…" : "Na tvém Macu je \(Fmt.bytes(junk.total)) odpadu.")
                        .font(.system(size: 26, weight: .semibold)).foregroundStyle(C.text)
                    HStack(spacing: 10) {
                        Button("Zkontrolovat odpad") { hub.module = .junk }.buttonStyle(GlassButton())
                        Button(running ? "…" : "Prohledat znovu") { hub.smartScan() }.buttonStyle(GlassButton()).disabled(running)
                    }
                }
                .padding(.top, 8)
                HStack(alignment: .top, spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(junk.running ? "Hledám systémový odpad…" : "\(Fmt.bytes(junk.totalChecked)) systémového odpadu")
                                .font(.system(size: 19, weight: .semibold)).foregroundStyle(C.text)
                            Text("Mezipaměti, logy, vývojářské soubory a staré instalátory, které si aplikace znovu vytvoří.")
                                .font(.system(size: 12.5)).foregroundStyle(C.text2)
                            Spacer()
                            HStack(spacing: 22) {
                                Image(systemName: "shippingbox").font(.system(size: 34))
                                Image(systemName: "trash.circle.fill").font(.system(size: 64))
                                Image(systemName: "doc.text").font(.system(size: 34))
                            }
                            .foregroundStyle(C.accent).frame(maxWidth: .infinity)
                            Spacer()
                            HStack {
                                Spacer()
                                Button("Zkontrolovat") { hub.module = .junk }.buttonStyle(GlassButton())
                                Button("Vyčistit") { junk.clean() }.buttonStyle(GlassButton(prominent: true))
                                    .disabled(junk.running || junk.totalChecked == 0)
                            }
                        }
                    }
                    VStack(spacing: 16) {
                        smallCard(title: large.running ? "Hledám velké soubory…" : "\(large.files.count) souborů nad \(large.minSizeMB) MB",
                                  text: large.running ? large.status : "Celkem \(Fmt.bytes(large.files.reduce(0) { $0 + $1.size })) – zkontroluj, co už nepotřebuješ.",
                                  icon: "arrow.up.doc.fill", target: .large)
                        smallCard(title: un.running ? "Hledám zbytky aplikací…" : "\(Fmt.bytes(un.orphans.reduce(0) { $0 + $1.size })) zbytků aplikací",
                                  text: "\(un.orphans.count) položek v Knihovně po aplikacích, které už na Macu nejsou.",
                                  icon: "xmark.app.fill", target: .uninstall)
                        smallCard(title: perf.running ? "Načítám služby…" : "\(perf.items.filter { !$0.disabled }.count) služeb při startu",
                                  text: "\(perf.items.filter { $0.orphan && !$0.disabled }.count) po odinstalovaných aplikacích, \(perf.items.filter { !$0.signedOK && !$0.disabled }.count) bez platného podpisu.",
                                  icon: "bolt.fill", target: .performance)
                        if trash > 0 {
                            smallCard(title: "\(Fmt.bytes(trash)) v Koši", text: "Vysypáním Koše se místo opravdu uvolní.", icon: "trash.fill", target: .junk)
                        }
                    }
                    .frame(width: 400)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func smallCard(title: String, text: String, icon: String, target: CleanModule) -> some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(C.text)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(C.text2).lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Image(systemName: icon).font(.system(size: 26)).foregroundStyle(target.palette.accent)
                    Spacer()
                    Button("Zkontrolovat") { hub.module = target }.buttonStyle(GlassButton())
                }
            }
        }
        .frame(height: 104)
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
                        Text("Nic k vyčištění 🎉").foregroundStyle(C.text2).padding(30)
                    }
                }
            }
            HStack {
                Text("Vybráno \(Fmt.bytes(m.totalChecked))").font(.system(size: 13, weight: .semibold)).foregroundStyle(C.text)
                Spacer()
                Button("Vyčistit") { m.clean() }.buttonStyle(GlassButton(prominent: true)).disabled(m.totalChecked == 0 || m.running)
            }
        }
    }

    private func category(_ cat: JunkCategory) -> some View {
        let open = m.expanded.contains(cat.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                CheckBox(state: m.state(cat)) { m.toggleCategory(cat) }
                Image(systemName: cat.icon).font(.system(size: 15)).foregroundStyle(cat.permanent ? Color(red: 1, green: 0.45, blue: 0.45) : C.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.text)
                    Text(cat.help).font(SK.helpFont).foregroundStyle(C.text2).lineLimit(1)
                }
                Spacer()
                let sel = cat.items.filter { m.checked.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.bytes(sel)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(sel > 0 ? C.accent : C.text3)
                    Text("z \(Fmt.bytes(cat.size))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(C.text2)
                }
                Button {
                    if open { m.expanded.remove(cat.id) } else { m.expanded.insert(cat.id) }
                } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(C.text2)
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
                            Text(i.name).font(.system(size: 12)).foregroundStyle(i.note.isEmpty ? C.text : Color.yellow).lineLimit(1)
                            Spacer()
                            Text(Fmt.bytes(i.size)).font(.system(size: 12).monospacedDigit()).foregroundStyle(C.text2)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).foregroundStyle(C.text3).tip("Zobrazit ve Finderu")
                        }
                        .padding(.horizontal, 12).padding(.leading, 34).frame(height: 26)
                    }
                    if cat.items.count > 300 { Text("… a dalších \(cat.items.count - 300)").font(SK.helpFont).foregroundStyle(C.text3).padding(6) }
                }
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(C.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: SK.cardRadius).stroke(C.border, lineWidth: 1))
    }
}

// MARK: - Velké a staré soubory

struct LargeOldView: View {
    @ObservedObject var m: LargeOldModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                folderPicker($m.root)
                Text("Větší než").font(SK.helpFont).foregroundStyle(C.text2)
                SKMenuPicker(selection: $m.minSizeMB, options: m.oldMode
                             ? [(1, "1 MB"), (10, "10 MB"), (50, "50 MB"), (100, "100 MB")]
                             : [(10, "10 MB"), (50, "50 MB"), (100, "100 MB"), (500, "500 MB"), (1024, "1 GB")], width: 100)
                Toggle("Včetně ~/Library", isOn: $m.includeLibrary).toggleStyle(.checkbox).fixedSize()
            }
            ScanBar(running: m.running, status: m.status, scan: { m.scan() }, stop: { m.stop() })
            HStack(spacing: 12) {
                Text("Typ").font(SK.helpFont).foregroundStyle(C.text2)
                SKMenuPicker(selection: $m.kind, options: FileKind.allCases.map { ($0, $0.title) }, width: 150)
                Text("Stáří").font(SK.helpFont).foregroundStyle(C.text2)
                SKMenuPicker(selection: $m.age, options: AgeFilter.allCases.filter { !m.oldMode || $0 != .anyAge }.map { ($0, $0.title) }, width: 210)
                Text("Řadit").font(SK.helpFont).foregroundStyle(C.text2)
                Menu {
                    ForEach(BigSort.allCases) { s in Button(s.title) { m.sortOrder = s.comparators } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
                .tip("Předvolby řazení. „Velké a zároveň staré“ = velikost × doba bez otevření. Řadit jde i klikem na hlavičku sloupce.")
                Spacer()
                Text("\(m.shown.count) · \(Fmt.bytes(m.shownSize))").font(SK.helpFont).foregroundStyle(C.text2)
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
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(C.text2)
                }
                TableColumn("Velikost", value: \.size) { f in Text(Fmt.bytes(f.size)).monospacedDigit() }.width(85)
                TableColumn("Naposledy otevřeno", value: \.lastUsedKey) { f in Text(dateText(f.lastUsed)).monospacedDigit() }.width(125)
                TableColumn("Změněno", value: \.modifiedKey) { f in Text(dateText(f.modified)).monospacedDigit() }.width(115)
            }
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 14).fill(C.card))
            .contextMenu(forSelectionType: URL.self) { _ in
                Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting(Array(m.selection)) }
                Button("Přesunout do Koše…") { m.trashSelected() }
            } primaryAction: { urls in NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            HStack {
                Text(m.selection.isEmpty ? "Vyber soubory (⌘ / ⇧ + klik)" : "Vybráno \(m.selection.count) · \(Fmt.bytes(m.selectedSize))")
                    .font(SK.helpFont).foregroundStyle(C.text2)
                Spacer()
                Button("Zobrazit v panelu") {
                    let urls = (m.selection.isEmpty ? m.shown.map(\.url) : Array(m.selection))
                    Commander.shared.tab.showResults(urls, title: m.oldMode ? "Staré soubory" : "Velké soubory")
                    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
                }
                .buttonStyle(GlassButton()).disabled(m.shown.isEmpty)
                .tip("Výsledky jako seznam v aktivním panelu – např. zkopírovat na externí disk (F5) a pak smazat")
                Button("Přesunout do Koše…") { m.trashSelected() }.buttonStyle(GlassButton(prominent: true)).disabled(m.selection.isEmpty)
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
                Text(m.status).font(SK.helpFont).foregroundStyle(C.text2).lineLimit(1)
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
                            Text(a.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(C.text)
                            Text("\(a.bundleID) · verze \(a.version)").font(SK.helpFont).foregroundStyle(C.text2)
                            Text("Aplikace \(a.size < 0 ? "…" : Fmt.bytes(a.size)) + data \(Fmt.bytes(m.relatedChecked))")
                                .font(SK.helpFont).foregroundStyle(C.text2)
                        }
                    }
                    Text("Související soubory").font(SK.titleFont).foregroundStyle(C.text)
                    ScrollView {
                        VStack(spacing: 0) {
                            if m.related.isEmpty { Text("Žádná nalezená data v ~/Library.").font(SK.helpFont).foregroundStyle(C.text2).padding(10) }
                            ForEach(m.related) { i in
                                HStack(spacing: 10) {
                                    CheckBox(state: m.checkedRelated.contains(i.id)) {
                                        if m.checkedRelated.contains(i.id) { m.checkedRelated.remove(i.id) } else { m.checkedRelated.insert(i.id) }
                                    }
                                    Text(i.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        .foregroundStyle(i.note.hasSuffix("podle názvu, ověř") ? Color.yellow : C.text)
                                    Spacer()
                                    Text(Fmt.bytes(i.size)).font(.system(size: 12).monospacedDigit()).foregroundStyle(C.text2)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.plain).foregroundStyle(C.text3)
                                }
                                .padding(.horizontal, 10).frame(height: 26)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(C.card.opacity(0.55)))
                    HStack {
                        Text("Odstraní se aplikace a zaškrtnutá data – vše do Koše.").font(SK.helpFont).foregroundStyle(C.text2)
                        Spacer()
                        Button("Odinstalovat") { m.uninstall() }.buttonStyle(GlassButton(danger: true))
                    }
                } else {
                    Spacer()
                    Text("Vyber aplikaci vlevo").font(SK.bodyFont).foregroundStyle(C.text2).frame(maxWidth: .infinity)
                    Spacer()
                }
            }
        }
    }

    private var orphans: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(m.orphans.isEmpty ? "Najít zbytky" : "Hledat znovu") { m.scanOrphans() }.buttonStyle(GlassButton(prominent: true)).disabled(m.running)
                Text("Položky v ~/Library pojmenované podle aplikace, která už na Macu není. Je to odhad – nic není zaškrtnuté předem.")
                    .font(SK.helpFont).foregroundStyle(C.text2)
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
                Button("Vybrat vše") { m.checkedOrphans = Set(m.orphans.map(\.id)) }.buttonStyle(GlassButton()).disabled(m.orphans.isEmpty)
                Spacer()
                Text("Vybráno \(Fmt.bytes(m.orphans.filter { m.checkedOrphans.contains($0.id) }.reduce(0) { $0 + $1.size }))")
                    .font(SK.helpFont).foregroundStyle(C.text2)
                Button("Přesunout do Koše…") { m.trashOrphans() }.buttonStyle(GlassButton(prominent: true)).disabled(m.checkedOrphans.isEmpty)
            }
        }
    }
}

// MARK: - Mapa disku (bubliny)

/// Rozmístění kruhů: největší uprostřed, další co nejblíž středu bez překryvu; nakonec se vše vejde do plochy.
enum BubblePack {
    static func layout(_ sizes: [Double], in rect: CGRect) -> [(center: CGPoint, r: CGFloat)] {
        guard !sizes.isEmpty, rect.width > 10, rect.height > 10 else { return [] }
        let maxS = sizes.max() ?? 1
        let radii = sizes.map { CGFloat(max(0.06, sqrt($0 / max(maxS, 1)))) * 100 }   // relativní poloměry
        var placed: [(CGPoint, CGFloat)] = []
        let gap: CGFloat = 4
        for r in radii {
            if placed.isEmpty { placed.append((.zero, r)); continue }
            var best: CGPoint?
            var bestD = CGFloat.infinity
            for (c, pr) in placed {
                for k in 0..<36 {
                    let a = CGFloat(k) / 36 * .pi * 2
                    let p = CGPoint(x: c.x + cos(a) * (pr + r + gap), y: c.y + sin(a) * (pr + r + gap) * 0.82)
                    let ok = placed.allSatisfy { hypot($0.0.x - p.x, $0.0.y - p.y) >= $0.1 + r + gap - 0.5 }
                    let d = hypot(p.x, p.y * 1.25)
                    if ok, d < bestD { bestD = d; best = p }
                }
            }
            placed.append((best ?? CGPoint(x: CGFloat(placed.count) * 2 * r, y: 0), r))
        }
        let minX = placed.map { $0.0.x - $0.1 }.min()!, maxX = placed.map { $0.0.x + $0.1 }.max()!
        let minY = placed.map { $0.0.y - $0.1 }.min()!, maxY = placed.map { $0.0.y + $0.1 }.max()!
        let scale = min(rect.width / (maxX - minX), rect.height / (maxY - minY)) * 0.96
        let ox = rect.midX - (minX + maxX) / 2 * scale, oy = rect.midY - (minY + maxY) / 2 * scale
        return placed.map { (CGPoint(x: $0.0.x * scale + ox, y: $0.0.y * scale + oy), $0.1 * scale) }
    }
}

struct SpaceLensView: View {
    @ObservedObject var m: SpaceLensModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            // vlevo: disk + seznam se zaškrtávátky
            VStack(spacing: 12) {
                GlassCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(m.current.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: m.current.path))
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text(m.running ? "…" : Fmt.bytes(m.total)).font(.system(size: 12).monospacedDigit()).foregroundStyle(C.text2)
                        }
                        Text("\(m.nodes.count) položek").font(.system(size: 11)).foregroundStyle(C.text3)
                    }
                }
                .frame(height: 74)
                List(m.nodes) { n in
                    HStack(spacing: 8) {
                        CheckBox(state: m.checked.contains(n.url)) {
                            if m.checked.contains(n.url) { m.checked.remove(n.url) } else { m.checked.insert(n.url) }
                        }
                        .disabled(CleanFS.isProtected(n.url.path))
                        Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path)).resizable().frame(width: 22, height: 22)
                        Text(n.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(n.size == 0 && m.running ? "…" : Fmt.bytes(n.size)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(C.text2)
                    }
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(m.hover == n.url ? C.hover : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if n.isDir { m.open(n.url) } }
                    .contextMenu { nodeMenu(n) }
                }
                .background(RoundedRectangle(cornerRadius: 16).fill(C.card))
            }
            .frame(width: 360)
            // vpravo: drobečky + bubliny
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button { m.up() } label: { Image(systemName: "chevron.left") }.buttonStyle(GlassButton()).disabled(m.path.count < 2)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(m.path, id: \.self) { u in
                                Button(u.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: u.path)) { m.open(u) }
                                    .buttonStyle(.plain).font(.system(size: 12, weight: u == m.current ? .semibold : .regular))
                                    .foregroundStyle(u == m.current ? C.text : C.text2)
                                if u != m.current { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(C.text3) }
                            }
                        }
                    }
                    if m.running { ProgressView().controlSize(.small) }
                    Menu("Začít od") {
                        Button("Domovská složka") { m.setRoot(FileManager.default.homeDirectoryForCurrentUser) }
                        Button("Celý disk (/)") { m.setRoot(URL(fileURLWithPath: "/")) }
                        Button("Jiná složka…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { m.setRoot(u) }
                        }
                    }
                    .fixedSize()
                    Button { m.load(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GlassButton()).tip("Přepočítat")
                }
                GeometryReader { g in
                    let shown = Array(m.nodes.filter { $0.size > 0 }.prefix(24))
                    let other = m.nodes.filter { $0.size > 0 }.dropFirst(24).reduce(Int64(0)) { $0 + $1.size }
                    let sizes = shown.map { Double($0.size) } + (other > 0 ? [Double(other)] : [])
                    let pack = BubblePack.layout(sizes, in: CGRect(origin: .zero, size: g.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(pack.enumerated()), id: \.offset) { i, b in
                            if i < shown.count { bubble(shown[i], b.center, b.r) }
                            else { otherBubble(other, b.center, b.r) }
                        }
                    }
                }
                HStack {
                    let sel = m.nodes.filter { m.checked.contains($0.url) }
                    Text(sel.isEmpty ? "Zaškrtni, co chceš odebrat" : "Vybráno \(sel.count) · \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Zkontrolovat a odebrat") { m.trashChecked() }.buttonStyle(GlassButton(prominent: true)).disabled(sel.isEmpty)
                }
            }
        }
        .onAppear { if m.nodes.isEmpty && !m.running { m.load() } }
    }

    private func bubble(_ n: LensNode, _ c: CGPoint, _ r: CGFloat) -> some View {
        let checked = m.checked.contains(n.url), hover = m.hover == n.url
        return ZStack {
            Circle().fill(RadialGradient(colors: [C.accent.opacity(hover ? 0.55 : 0.38), C.accent.opacity(0.10)],
                                         center: .center, startRadius: 2, endRadius: r))
            Circle().stroke(checked ? C.accent : C.border, lineWidth: checked ? 4 : 1)
            VStack(spacing: 3) {
                if r > 34 {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path)).resizable().frame(width: min(r * 0.55, 64), height: min(r * 0.55, 64))
                }
                if r > 26 {
                    Text(n.name).font(.system(size: max(9, min(13, r / 6)), weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: r * 1.5)
                    Text(Fmt.bytes(n.size)).font(.system(size: max(8.5, min(12, r / 7)))).foregroundStyle(C.text2)
                }
            }
        }
        .frame(width: r * 2, height: r * 2)
        .contentShape(Circle())
        .position(c)
        .onHover { inside in m.hover = inside ? n.url : (m.hover == n.url ? nil : m.hover) }
        .onTapGesture(count: 2) { if n.isDir { m.open(n.url) } }
        .onTapGesture { if n.isDir { m.open(n.url) } else if !CleanFS.isProtected(n.url.path) { m.toggle(n.url) } }
        .contextMenu { nodeMenu(n) }
        .tip("\(n.name) · \(Fmt.bytes(n.size))" + (n.isDir ? " · klikni pro vstup" : " · klikni pro výběr"))
    }

    private func otherBubble(_ size: Int64, _ c: CGPoint, _ r: CGFloat) -> some View {
        ZStack {
            Circle().fill(C.card)
            Circle().stroke(C.border, lineWidth: 1)
            VStack(spacing: 2) {
                Text("Ostatní").font(.system(size: max(9, min(12, r / 6)), weight: .semibold))
                Text(Fmt.bytes(size)).font(.system(size: max(8.5, min(11, r / 7)))).foregroundStyle(C.text2)
            }
        }
        .frame(width: r * 2, height: r * 2)
        .position(c)
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
                Text("Od velikosti").font(SK.helpFont).foregroundStyle(C.text2)
                SKMenuPicker(selection: $m.minSizeMB, options: [(0, "100 kB"), (1, "1 MB"), (10, "10 MB"), (100, "100 MB")], width: 100)
            }
            ScanBar(running: m.running, status: m.status, scan: { m.scan() }, stop: { m.stop() })
            HStack {
                Button("Ponechat nejnovější") { m.autoSelect(keepNewest: true) }.buttonStyle(GlassButton()).disabled(m.groups.isEmpty)
                Button("Ponechat nejstarší") { m.autoSelect(keepNewest: false) }.buttonStyle(GlassButton()).disabled(m.groups.isEmpty)
                Button("Nic") { m.checked = [] }.buttonStyle(GlassButton()).disabled(m.groups.isEmpty)
                Spacer()
                Text("Zbytečně zabráno \(Fmt.bytes(m.wasted))").font(SK.helpFont).foregroundStyle(C.text2)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(m.groups) { g in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(g.files[0].url.lastPathComponent).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(C.text).lineLimit(1)
                                Spacer()
                                Text("\(g.files.count)× \(Fmt.bytes(g.files[0].size))").font(SK.helpFont).foregroundStyle(C.text2)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            ForEach(g.files) { f in
                                HStack(spacing: 10) {
                                    CheckBox(state: m.checked.contains(f.id)) { m.toggle(f, in: g) }
                                    Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: CleanFS.home, with: "~"))
                                        .font(.system(size: 11.5)).foregroundStyle(m.checked.contains(f.id) ? C.text2 : C.text)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.date.string(from: f.modified)).font(.system(size: 11).monospacedDigit()).foregroundStyle(C.text3)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.plain).foregroundStyle(C.text3)
                                }
                                .padding(.horizontal, 12).padding(.leading, 6).frame(height: 24)
                            }
                        }
                        .padding(.bottom, 6)
                        .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(C.card.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: SK.cardRadius).stroke(C.border, lineWidth: 1))
                    }
                }
            }
            HStack {
                Text("Vybráno \(m.checked.count) · \(Fmt.bytes(m.checkedSize))").font(.system(size: 13, weight: .semibold)).foregroundStyle(C.text)
                Spacer()
                Button("Přesunout do Koše…") { m.trashChecked() }.buttonStyle(GlassButton(prominent: true)).disabled(m.checked.isEmpty || m.running)
            }
        }
    }
}
