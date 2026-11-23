import SwiftUI
import AppKit

// Hledání souborů (Alt+F7 v TC → ⌘F / ⌥F7): název s maskou, volitelně text v souborech,
// volitelně i uvnitř archivů (ZIP, tar.gz, 7z… – jen názvy). Výsledky lze poslat do aktivního panelu.

struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let url: URL                // soubor na disku (u archivu = archiv)
    let inner: String?          // cesta uvnitř archivu
    let isDir: Bool
    let size: Int64
    let modified: Date
    var name: String { inner.map { ($0 as NSString).lastPathComponent } ?? url.lastPathComponent }
    var location: String { inner.map { url.path + " ▸ " + (($0 as NSString).deletingLastPathComponent) } ?? url.deletingLastPathComponent().path }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var root: String
    @Published var pattern = ""
    @Published var text = ""
    @Published var findText = false
    @Published var caseSensitive = false
    @Published var inArchives = true
    @Published var hidden = false
    @Published var hits: [SearchHit] = []
    @Published var running = false
    @Published var status = ""
    @Published var selection: SearchHit.ID?
    private var cancel = Box(false)

    init(root: String) { self.root = root }

    func start() {
        stop()
        hits = []; selection = nil
        let dir = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            status = "Složka neexistuje."; return
        }
        let masks = Self.masks(pattern)
        let needle = findText ? text : ""
        guard !(masks.isEmpty && needle.isEmpty) else { status = "Zadej název nebo text."; return }
        let c = Box(false); cancel = c
        running = true; status = "Hledám…"
        let opts = (inArchives, hidden, caseSensitive)
        Task.detached(priority: .userInitiated) {
            let found = Box<[SearchHit]>([])
            var scanned = 0, last = Date()
            func flush(_ final: Bool) async {
                let batch = found.value; found.value = []
                let n = scanned
                await MainActor.run { [batch] in
                    guard self.cancel === c else { return }
                    self.hits.append(contentsOf: batch)
                    self.status = final ? "" : "Prohledáno \(n) položek…"
                }
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                   options: opts.1 ? [.skipsPackageDescendants] : [.skipsPackageDescendants, .skipsHiddenFiles],
                                                   errorHandler: { _, _ in true })
            while let u = e?.nextObject() as? URL {
                if c.value { break }
                scanned += 1
                let v = try? u.resourceValues(forKeys: Set(keys))
                let isDir = v?.isDirectory ?? false
                let size = Int64(v?.fileSize ?? 0), date = v?.contentModificationDate ?? .distantPast
                let nameOK = masks.isEmpty || Self.match(u.lastPathComponent, masks)
                if nameOK {
                    if needle.isEmpty {
                        found.value.append(SearchHit(url: u, inner: nil, isDir: isDir, size: isDir ? -1 : size, modified: date))
                    } else if !isDir, v?.isRegularFile == true, Self.contains(u, needle, caseSensitive: opts.2) {
                        found.value.append(SearchHit(url: u, inner: nil, isDir: false, size: size, modified: date))
                    }
                }
                // názvy uvnitř archivů (text v archivech se neprohledává)
                if opts.0, needle.isEmpty, !isDir, ArchiveIO.isArchive(u), let idx = try? ArchiveIO.index(u) {
                    for (path, entry) in idx.entries where Self.match((path as NSString).lastPathComponent, masks) {
                        found.value.append(SearchHit(url: u, inner: path, isDir: entry.isDir,
                                                     size: entry.isDir ? -1 : entry.size, modified: entry.mtime))
                    }
                }
                if Date().timeIntervalSince(last) > 0.25 { last = Date(); await flush(false) }
            }
            await flush(true)
            let stopped = c.value
            await MainActor.run { guard self.cancel === c else { return };
                self.running = false
                self.status = (stopped ? "Zastaveno · " : "") + "Nalezeno \(self.hits.count) · prohledáno \(scanned) položek"
            }
        }
    }

    func stop() { cancel.value = true; running = false }

    // MARK: Pomocné

    /// „*.log;report*“ → masky; bez * a ? se hledá jako část názvu.
    nonisolated static func masks(_ p: String) -> [String] {
        p.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.contains("*") || $0.contains("?") ? $0 : "*\($0)*" }
    }

    nonisolated static func match(_ name: String, _ masks: [String]) -> Bool {
        masks.isEmpty || masks.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    /// Text v souboru: jen textové soubory do 50 MB (binární = NUL v prvních 8 kB).
    nonisolated static func contains(_ u: URL, _ needle: String, caseSensitive: Bool) -> Bool {
        guard let d = try? Data(contentsOf: u, options: .alwaysMapped), d.count <= 50_000_000 else { return false }
        if d.prefix(8192).contains(0) { return false }
        let s = String(decoding: d, as: UTF8.self)
        return s.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

struct SearchView: View {
    @ObservedObject var m: SearchModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Hledat v").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                TextField("", text: $m.root).textFieldStyle(.roundedBorder).font(SK.monoFont)
                Button("Vybrat…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = URL(fileURLWithPath: m.root)
                    if p.runModal() == .OK, let u = p.url { m.root = u.path }
                }
            }
            HStack(spacing: 8) {
                TextField("Název souboru nebo složky (např. *.log;report)", text: $m.pattern, onCommit: { m.start() })
                    .textFieldStyle(.roundedBorder).font(.system(size: 13))
                if m.running {
                    Button("Zastavit") { m.stop() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Hledat") { m.start() }.keyboardShortcut(.defaultAction)
                }
            }
            HStack(spacing: 16) {
                Toggle("Hledat text v souborech", isOn: $m.findText)
                Toggle("Uvnitř archivů (ZIP, tar.gz, 7z…)", isOn: $m.inArchives).disabled(m.findText)
                Toggle("Skryté soubory", isOn: $m.hidden)
            }
            .toggleStyle(.checkbox).font(.system(size: 12))
            if m.findText {
                HStack(spacing: 8) {
                    TextField("Hledaný text", text: $m.text, onCommit: { m.start() }).textFieldStyle(.roundedBorder)
                    Toggle("Rozlišovat velikost písmen", isOn: $m.caseSensitive).toggleStyle(.checkbox).font(.system(size: 12))
                }
            }
            Table(m.hits, selection: $m.selection) {
                TableColumn("Název") { h in
                    HStack(spacing: 5) {
                        Image(systemName: h.isDir ? "folder" : h.inner != nil ? "archivebox" : "doc").foregroundStyle(UI.textSecondary)
                        Text(h.name).lineLimit(1)
                    }
                }
                TableColumn("Umístění") { h in Text(h.location).lineLimit(1).truncationMode(.middle).foregroundStyle(UI.textSecondary) }
                TableColumn("Velikost") { h in Text(h.size < 0 ? "<DIR>" : Fmt.bytes(h.size)).monospacedDigit() }.width(80)
                TableColumn("Datum") { h in Text(Fmt.date.string(from: h.modified)).monospacedDigit() }.width(120)
            }
            .contextMenu(forSelectionType: SearchHit.ID.self) { ids in
                if let id = ids.first, let h = m.hits.first(where: { $0.id == id }) {
                    Button("Přejít na soubor") { go(h) }
                    Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([h.url]) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let h = m.hits.first(where: { $0.id == id }) { go(h) }
            }
            HStack {
                if m.running { ProgressView().controlSize(.small) }
                Text(m.status).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Spacer()
                Button("Přejít na soubor") { if let h = m.hits.first(where: { $0.id == m.selection }) { go(h) } }
                    .disabled(m.selection == nil)
                Button("Zobrazit v aktivním panelu") { feed() }
                    .disabled(m.hits.filter { $0.inner == nil }.isEmpty)
                    .tip("Výsledky se zobrazí jako seznam v aktivním panelu – funguje na ně F3–F8, označování i přetahování")
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 480)
        .background(UI.app)
    }

    /// Aktivní panel přejde do složky souboru s kurzorem na něm (u archivu otevře archiv).
    private func go(_ h: SearchHit) {
        let t = Commander.shared.tab
        t.go(h.url.deletingLastPathComponent(), select: h.url.lastPathComponent)
        Commander.shared.focus(Commander.shared.activeSide)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func feed() {
        let urls = m.hits.filter { $0.inner == nil }.map(\.url)
        Commander.shared.tab.showResults(urls, title: m.pattern.isEmpty ? m.text : m.pattern)
        Commander.shared.focus(Commander.shared.activeSide)
        close()
    }
}

@MainActor
enum SearchWindow {
    private static var window: NSWindow?
    private static var model: SearchModel?

    static func show(root: URL) {
        if let w = window, let m = model {
            if !m.running { m.root = root.path }
            w.makeKeyAndOrderFront(nil); return
        }
        let m = SearchModel(root: root.path)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Hledat"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SearchView(m: m) { w.close() }
            .preferredColorScheme(FTSettings.shared.isDark ? .dark : .light))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { model?.stop(); window = nil; model = nil }
        }
        window = w; model = m
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
