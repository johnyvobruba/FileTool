import SwiftUI
import AppKit
import CoreServices

// Úklid disku: velké soubory, dlouho nepoužívané soubory, nepoužívané aplikace, mezipaměti a logy.
// Jen vyhledává a ukazuje. Mazání = přesun do Koše po potvrzení (nikdy trvale), jde tedy vrátit.
// Systémové složky (/System, /usr, /bin, /sbin, /private, /Library) se neprohledávají ani nenabízejí.

struct CleanupItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let lastUsed: Date?
    let modified: Date?
    let isDir: Bool
    var note = ""
    /// Mezipaměť / logy: maže se jen obsah složky, ne složka samotná.
    var contentsOnly = false
    var id: URL { url }
    var name: String { note.isEmpty ? FileManager.default.displayName(atPath: url.path) : note }
}

enum CleanupMode: String, CaseIterable, Identifiable {
    case large, old, apps, caches
    var id: String { rawValue }
    var title: String {
        switch self {
        case .large: return "Velké soubory"
        case .old: return "Nepoužívané soubory"
        case .apps: return "Nepoužívané aplikace"
        case .caches: return "Mezipaměti a logy"
        }
    }
}

@MainActor
final class CleanupModel: ObservableObject {
    @Published var mode: CleanupMode = .large { didSet { if oldValue != mode { stop(); items = []; selection = []; status = "" } } }
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var minSizeMB = 100
    @Published var oldMinSizeMB = 10
    @Published var months = 12
    @Published var includeLibrary = false
    @Published var hidden = false
    @Published var items: [CleanupItem] = []
    @Published var selection = Set<URL>()
    @Published var running = false
    @Published var status = ""
    private var cancel = Box(false)

    var selectedSize: Int64 { items.filter { selection.contains($0.id) }.reduce(0) { $0 + max(0, $1.size) } }
    var totalSize: Int64 { items.reduce(0) { $0 + max(0, $1.size) } }

    nonisolated static let protected = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/dev", "/cores", "/opt"]

    nonisolated static func isProtected(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "/" || path == home { return true }
        return protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func start() {
        stop()
        items = []; selection = []
        let c = Box(false); cancel = c
        running = true; status = "Prohledávám…"
        let mode = self.mode, rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        let minBytes = Int64(mode == .large ? minSizeMB : oldMinSizeMB) * 1_048_576
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        let lib = includeLibrary, hid = hidden
        Task.detached(priority: .userInitiated) {
            let found = Box<[CleanupItem]>([])
            var scanned = 0
            var last = Date()
            func flush(_ final: Bool) async {
                let batch = found.value; found.value = []
                let n = scanned
                await MainActor.run {
                    self.items.append(contentsOf: batch)
                    self.items.sort { $0.size > $1.size }
                    if !final { self.status = "Prohledáno \(n) položek…" }
                }
            }
            switch mode {
            case .large, .old:
                let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
                                              .contentModificationDateKey, .isDirectoryKey, .ubiquitousItemDownloadingStatusKey]
                let libPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Library"
                let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                       options: hid ? [.skipsPackageDescendants] : [.skipsPackageDescendants, .skipsHiddenFiles],
                                                       errorHandler: { _, _ in true })
                while let u = e?.nextObject() as? URL {
                    if c.value { break }
                    scanned += 1
                    let p = u.path
                    if Self.isProtected(p) || (!lib && (p == libPath || p.hasPrefix(libPath + "/"))) {
                        if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e?.skipDescendants() }
                        continue
                    }
                    guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    if let st = v.ubiquitousItemDownloadingStatus, st != .current { continue }   // jen v iCloudu – místo nezabírá
                    let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                    guard size >= minBytes else { continue }
                    let mod = v.contentModificationDate
                    let used = Self.lastUsed(u)
                    if mode == .old {
                        let ref = max(used ?? .distantPast, mod ?? .distantPast)
                        guard ref < cutoff else { continue }
                    }
                    found.value.append(CleanupItem(url: u, size: size, lastUsed: used, modified: mod, isDir: false))
                    if Date().timeIntervalSince(last) > 0.3 { last = Date(); await flush(false) }
                }
            case .apps:
                let fm = FileManager.default
                let dirs = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
                for d in dirs {
                    for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "app" {
                        if c.value { break }
                        scanned += 1
                        let bid = Bundle(url: u)?.bundleIdentifier ?? ""
                        if bid.hasPrefix("com.apple.") || bid == Bundle.main.bundleIdentifier { continue }
                        let used = Self.lastUsed(u)
                        guard (used ?? .distantPast) < cutoff else { continue }
                        let size = Self.dirSize(u, cancel: c)
                        found.value.append(CleanupItem(url: u, size: size, lastUsed: used, modified: nil, isDir: true))
                        if Date().timeIntervalSince(last) > 0.3 { last = Date(); await flush(false) }
                    }
                }
            case .caches:
                for (path, note) in Self.cacheLocations {
                    if c.value { break }
                    let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    scanned += 1
                    await MainActor.run { self.status = "Počítám \(note)…" }
                    let size = Self.dirSize(u, cancel: c)
                    guard size > 0 else { continue }
                    found.value.append(CleanupItem(url: u, size: size, lastUsed: nil, modified: nil, isDir: true, note: note, contentsOnly: true))
                    await flush(false)
                }
            }
            await flush(true)
            let stopped = c.value
            await MainActor.run {
                self.running = false
                self.status = (stopped ? "Zastaveno · " : "") + "Nalezeno \(self.items.count) položek, celkem \(Fmt.bytes(self.totalSize))"
            }
        }
    }

    func stop() { cancel.value = true; running = false }

    /// Známá místa, která se dají bezpečně vyprázdnit (aplikace si obsah znovu vytvoří).
    nonisolated static let cacheLocations: [(String, String)] = [
        ("~/Library/Caches", "Mezipaměti aplikací (~/Library/Caches)"),
        ("~/Library/Logs", "Logy aplikací (~/Library/Logs)"),
        ("~/Library/Developer/Xcode/DerivedData", "Xcode – DerivedData"),
        ("~/Library/Developer/Xcode/Archives", "Xcode – Archives (staré buildy)"),
        ("~/Library/Developer/Xcode/iOS DeviceSupport", "Xcode – iOS DeviceSupport"),
        ("~/Library/Developer/CoreSimulator/Caches", "Simulátory – mezipaměť"),
        ("~/.npm/_cacache", "npm – mezipaměť balíčků"),
        ("~/.cache", "~/.cache (pip, různé nástroje)"),
        ("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Mail – stažené přílohy"),
    ]

    /// Kdy byl soubor naposledy otevřen (Spotlight kMDItemLastUsedDate); nil = neznámé.
    nonisolated static func lastUsed(_ u: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, u as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    nonisolated static func dirSize(_ u: URL, cancel: Box<Bool>) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            if cancel.value { break }
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    // MARK: Akce

    func trashSelected() {
        let chosen = items.filter { selection.contains($0.id) && !Self.isProtected($0.url.path) }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        let caches = chosen.filter(\.contentsOnly)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Přesunout do Koše \(chosen.count == 1 ? "„\(chosen[0].name)“" : "\(chosen.count) položek") (\(Fmt.bytes(chosen.reduce(0) { $0 + $1.size })))?"
        a.informativeText = chosen.prefix(10).map { "• " + $0.name }.joined(separator: "\n") + (chosen.count > 10 ? "\n…" : "")
            + (caches.isEmpty ? "" : "\n\nU mezipamětí a logů se do Koše přesune jen obsah složky. Před tím zavři dotčené aplikace.")
            + "\n\nMísto se uvolní až po vysypání Koše. Do té doby lze vše vrátit."
        a.addButton(withTitle: "Do Koše"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        running = true; status = "Přesouvám do Koše…"
        Task.detached(priority: .userInitiated) {
            var errs: [String] = [], done: [URL] = [], freed: Int64 = 0
            for i in chosen {
                let targets = i.contentsOnly
                    ? ((try? FileManager.default.contentsOfDirectory(at: i.url, includingPropertiesForKeys: nil)) ?? [])
                    : [i.url]
                var ok = true
                for t in targets {
                    do { try FileManager.default.trashItem(at: t, resultingItemURL: nil) }
                    catch let err { ok = false; errs.append("\(t.lastPathComponent): \(err.localizedDescription)") }
                }
                if ok { done.append(i.url); freed += i.size }
            }
            let finished = done, f = freed, e = errs
            await MainActor.run {
                self.running = false
                self.items.removeAll { finished.contains($0.url) }
                self.selection.subtract(finished)
                self.status = "Přesunuto do Koše: \(finished.count) · \(Fmt.bytes(f)) (uvolní se po vysypání Koše)"
                Commander.shared.refreshAll()
                SidebarModel.shared.reloadVolumes()
                if !e.isEmpty {
                    let a = NSAlert()
                    a.messageText = "Některé položky nešlo přesunout (\(e.count))"
                    a.informativeText = e.prefix(12).joined(separator: "\n") + "\n\nČasto jde o soubory jiného uživatele, běžící aplikaci nebo chybějící Plný přístup k disku."
                    a.runModal()
                }
            }
        }
    }

    func reveal() {
        let urls = items.filter { selection.contains($0.id) }.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func showInPanel() {
        let urls = (selection.isEmpty ? items : items.filter { selection.contains($0.id) }).map(\.url)
        guard !urls.isEmpty else { return }
        Commander.shared.tab.showResults(urls, title: mode.title)
        Commander.shared.focus(Commander.shared.activeSide)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

struct CleanupView: View {
    @ObservedObject var m: CleanupModel

    private func date(_ d: Date?) -> String { d.map { Fmt.date.string(from: $0) } ?? "neznámé" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $m.mode) {
                ForEach(CleanupMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                switch m.mode {
                case .large:
                    HStack(spacing: 10) {
                        folderField
                        Picker("Větší než", selection: $m.minSizeMB) {
                            Text("50 MB").tag(50); Text("100 MB").tag(100); Text("500 MB").tag(500)
                            Text("1 GB").tag(1024); Text("5 GB").tag(5120)
                        }.frame(width: 170)
                    }
                    options
                case .old:
                    HStack(spacing: 10) {
                        folderField
                        Picker("Neotevřené", selection: $m.months) {
                            Text("6 měsíců").tag(6); Text("1 rok").tag(12); Text("2 roky").tag(24); Text("3 roky").tag(36)
                        }.frame(width: 180)
                        Picker("od velikosti", selection: $m.oldMinSizeMB) {
                            Text("1 MB").tag(1); Text("10 MB").tag(10); Text("100 MB").tag(100)
                        }.frame(width: 160)
                    }
                    options
                case .apps:
                    HStack {
                        Picker("Nespuštěné déle než", selection: $m.months) {
                            Text("3 měsíce").tag(3); Text("6 měsíců").tag(6); Text("1 rok").tag(12); Text("2 roky").tag(24)
                        }.frame(width: 260)
                        Spacer()
                    }
                    Text("Aplikace z /Applications a ~/Applications (bez aplikací Apple). Datum posledního spuštění eviduje Spotlight – „neznámé“ znamená, že ji Spotlight nikdy neviděl spustit.")
                        .font(SK.helpFont).foregroundStyle(UI.textSecondary)
                case .caches:
                    Text("Známá místa, která si aplikace po vyprázdnění znovu vytvoří. Do Koše se přesune jen obsah složky. Před vyprázdněním zavři dotčené aplikace.")
                        .font(SK.helpFont).foregroundStyle(UI.textSecondary)
                }
            }
            HStack {
                if m.running {
                    Button("Zastavit") { m.stop() }.keyboardShortcut(.cancelAction)
                    ProgressView().controlSize(.small)
                } else {
                    Button("Prohledat") { m.start() }.keyboardShortcut(.defaultAction)
                }
                Text(m.status).font(SK.helpFont).foregroundStyle(UI.textSecondary).lineLimit(1)
                Spacer()
            }
            Table(m.items, selection: $m.selection) {
                TableColumn("Název") { i in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: i.url.path)).resizable().frame(width: 16, height: 16)
                        Text(i.name).lineLimit(1)
                    }
                }
                TableColumn("Umístění") { i in
                    Text(i.contentsOnly ? i.url.path : i.url.deletingLastPathComponent().path)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(UI.textSecondary)
                }
                TableColumn("Velikost") { i in Text(Fmt.bytes(i.size)).monospacedDigit() }.width(90)
                TableColumn("Naposledy otevřeno") { i in Text(i.contentsOnly ? "" : date(i.lastUsed)).monospacedDigit() }.width(130)
                TableColumn("Změněno") { i in Text(i.contentsOnly ? "" : date(i.modified)).monospacedDigit() }.width(120)
            }
            .contextMenu(forSelectionType: URL.self) { _ in
                Button("Zobrazit ve Finderu") { m.reveal() }
                Button("Zobrazit v aktivním panelu") { m.showInPanel() }
                Divider()
                Button("Přesunout do Koše…") { m.trashSelected() }
            } primaryAction: { urls in
                if let u = urls.first { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
            HStack {
                Text(m.selection.isEmpty ? "Vyber položky (⌘ / ⇧ + klik pro víc)" : "Vybráno \(m.selection.count) · \(Fmt.bytes(m.selectedSize))")
                    .font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Spacer()
                Button("Vybrat vše") { m.selection = Set(m.items.map(\.id)) }.disabled(m.items.isEmpty)
                Button("Zobrazit ve Finderu") { m.reveal() }.disabled(m.selection.isEmpty)
                Button("Zobrazit v panelu") { m.showInPanel() }.disabled(m.items.isEmpty || m.mode == .caches)
                    .tip("Výsledky jako seznam v aktivním panelu – můžeš je třeba zkopírovat na externí disk (F5) a pak smazat")
                Button("Přesunout do Koše…") { m.trashSelected() }.disabled(m.selection.isEmpty || m.running)
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 520)
        .background(UI.app)
    }

    private var folderField: some View {
        HStack(spacing: 6) {
            Text("Ve složce").font(SK.helpFont).foregroundStyle(UI.textSecondary)
            TextField("", text: $m.root).textFieldStyle(.roundedBorder).font(SK.monoFont)
            Button("Vybrat…") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                p.directoryURL = URL(fileURLWithPath: m.root)
                if p.runModal() == .OK, let u = p.url { m.root = u.path }
            }
        }
    }

    private var options: some View {
        HStack(spacing: 16) {
            Toggle("Včetně ~/Library (data aplikací)", isOn: $m.includeLibrary)
            Toggle("Skryté soubory", isOn: $m.hidden)
        }
        .toggleStyle(.checkbox).font(.system(size: 12))
    }
}

@MainActor
enum CleanupWindow {
    private static var window: NSWindow?
    private static var model: CleanupModel?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let m = CleanupModel()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Úklid disku"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: CleanupView(m: m).preferredColorScheme(FTSettings.shared.isDark ? .dark : .light))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { model?.stop(); window = nil; model = nil }
        }
        window = w; model = m
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
