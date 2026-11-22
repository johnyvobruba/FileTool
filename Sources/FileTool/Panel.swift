import Foundation
import AppKit
import Darwin

/// Otevřený archiv v panelu: obsah (index) a aktuální vnitřní složka.
struct ArchiveLocation {
    let index: ArchiveIndex
    var inner: String
    var file: URL { index.file }
}

/// Panel připojený k serveru: spojení a aktuální vzdálená složka.
struct RemoteLocation {
    let session: RemoteSession
    var path: String
    /// Kořen falešných URL položek (identita v tabulce, na disku neexistuje).
    let base: URL
}

/// Výsledky hledání zobrazené v panelu (skutečné soubory z různých složek).
struct SearchResults {
    let title: String
    var urls: [URL]
}

/// Jedna záložka panelu: složka, seznam, kurzor, označené položky, historie.
@MainActor
final class PanelTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var dir: URL
    @Published private(set) var items: [FileItem] = []
    @Published var marked: Set<URL> = [] { didSet { version &+= 1 } }
    @Published var cursor: Int = 0
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published private(set) var error: String?
    @Published var pathField = ""
    /// Zvyšuje se při každé změně obsahu – tabulka podle něj ví, kdy překreslit.
    @Published private(set) var version = 0
    /// Panel ukazuje obsah archivu (dir = složka, ve které archiv leží).
    @Published private(set) var archive: ArchiveLocation?
    @Published private(set) var opening = false
    /// Panel ukazuje složku na serveru (SFTP/SCP/FTP).
    @Published private(set) var remote: RemoteLocation?
    /// Panel ukazuje výsledky hledání (⌘F → Zobrazit v aktivním panelu).
    @Published private(set) var results: SearchResults?

    private var back: [URL] = []
    private var forward: [URL] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    var onNavigate: (() -> Void)?

    init(dir: URL) {
        self.dir = dir
        pathField = dir.path
        load()
    }

    var title: String {
        if let r = results { return "🔍 " + r.title }
        if let r = remote { return "🌐 " + r.session.config.title }
        if let a = archive { return "📦 " + a.file.lastPathComponent }
        return dir.path == "/" ? "/" : (dir.lastPathComponent.isEmpty ? dir.path : dir.lastPathComponent)
    }

    /// Cesta pro zobrazení (u archivu i vnitřní složka).
    var displayPath: String {
        if let r = results { return "Výsledky hledání „\(r.title)“ – \(r.urls.count) položek" }
        if let r = remote { return r.session.label + r.path }
        guard let a = archive else { return dir.path }
        return a.file.path + (a.inner.isEmpty ? "" : "/" + a.inner)
    }
    var current: FileItem? { items.indices.contains(cursor) ? items[cursor] : nil }

    /// Označené položky, jinak položka pod kurzorem (bez [..]) – cíl operací F5/F6/F8.
    var selection: [FileItem] {
        let m = items.filter { marked.contains($0.url) }
        if !m.isEmpty { return m }
        if let c = current, !c.isParent { return [c] }
        return []
    }

    // MARK: Navigace

    func go(_ url: URL, select name: String? = nil, record: Bool = true) {
        let target = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            error = "Složka neexistuje: \(target.path)"; NSSound.beep(); pathField = dir.path; return
        }
        if record, target != dir || archive != nil { back.append(dir); forward.removeAll() }
        disconnectRemote()
        archive = nil
        results = nil
        dir = target
        pathField = target.path
        marked = []
        load(select: name, resetCursor: name == nil)
        onNavigate?()
    }

    func up() {
        if results != nil { results = nil; pathField = dir.path; marked = []; load(); onNavigate?(); return }
        if var r = remote {
            if r.path == "/" { disconnectRemote(); pathField = dir.path; marked = []; load(); onNavigate?(); return }
            let last = (r.path as NSString).lastPathComponent
            r.path = RemotePath.parent(r.path)
            remote = r
            pathField = displayPath
            marked = []
            load(select: last)
            return
        }
        if var a = archive {
            if a.inner.isEmpty {                                   // z kořene archivu ven, kurzor na archiv
                let name = a.file.lastPathComponent
                archive = nil
                pathField = dir.path
                marked = []
                load(select: name)
            } else {
                let last = (a.inner as NSString).lastPathComponent
                a.inner = (a.inner as NSString).deletingLastPathComponent
                archive = a
                pathField = displayPath
                marked = []
                load(select: last)
            }
            return
        }
        guard dir.path != "/" else { return }
        go(dir.deletingLastPathComponent(), select: dir.lastPathComponent)
    }

    func goBack() { guard let u = back.popLast() else { return }; forward.append(dir); go(u, record: false) }
    func goForward() { guard let u = forward.popLast() else { return }; back.append(dir); go(u, record: false) }

    func open(_ item: FileItem) {
        if item.isParent { up(); return }
        if let r = remote, let p = item.remotePath {
            if item.isDir { goRemote(p) }
            else if item.isLink {                     // odkaz: na složku → dovnitř, jinak jako soubor
                Task {
                    let l = try? await r.session.list(p, base: r.base)
                    let isFile = l == nil || (l!.count == 1 && l![0].name == item.name && !l![0].isDir)
                    if isFile { Commander.shared.openFromRemote(self, [item]) } else { self.goRemote(p) }
                }
            } else { Commander.shared.openFromRemote(self, [item]) }
            return
        }
        if var a = archive, let inner = item.archiveInner {
            if item.isDir {
                a.inner = inner; archive = a; pathField = displayPath; marked = []
                load(resetCursor: true)
            } else {
                Commander.shared.openFromArchive(self, [item])
            }
            return
        }
        if item.isDir { go(item.url); return }
        if item.isArchive { enterArchive(item.url); return }
        NSWorkspace.shared.open(item.url)
    }

    /// Otevře archiv jako složku (obsah se čte mimo hlavní vlákno).
    func enterArchive(_ file: URL) {
        opening = true
        Task.detached(priority: .userInitiated) {
            let r = Result { try ArchiveIO.index(file) }
            await MainActor.run {
                self.opening = false
                switch r {
                case .success(let idx):
                    self.back.append(self.dir); self.forward.removeAll()
                    self.archive = ArchiveLocation(index: idx, inner: "")
                    self.pathField = self.displayPath
                    self.marked = []
                    self.load(resetCursor: true)
                    self.onNavigate?()
                case .failure(let e):
                    // není to čitelný archiv → otevřít výchozí aplikací (např. .pkg, .gz neznámého typu)
                    let a = NSAlert()
                    a.messageText = "„\(file.lastPathComponent)“ nejde otevřít jako archiv"
                    a.informativeText = e.localizedDescription
                    a.addButton(withTitle: "Otevřít výchozí aplikací"); a.addButton(withTitle: "Zavřít")
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(file) }
                }
            }
        }
    }

    /// Po změně archivu (přidání, smazání) znovu načíst obsah, vnitřní složku ponechat.
    func reloadArchive() {
        guard let a = archive else { return }
        let file = a.file, inner = a.inner
        Task.detached(priority: .userInitiated) {
            let r = Result { try ArchiveIO.index(file) }
            await MainActor.run {
                guard self.archive?.file == file else { return }
                switch r {
                case .success(let idx):
                    let keep = idx.entries[inner]?.isDir == true || inner.isEmpty ? inner : ""
                    self.archive = ArchiveLocation(index: idx, inner: keep)
                    self.pathField = self.displayPath
                    self.load()
                case .failure(let e):
                    self.archive = nil
                    self.error = "Archiv už nejde přečíst: \(e.localizedDescription)"
                    self.load()
                }
            }
        }
    }

    // MARK: Vzdálený server

    /// Připojí záložku k serveru (dosavadní složka zůstává jako návrat po odpojení).
    func connect(_ config: RemoteConfig) {
        opening = true
        let s = RemoteSession(config: config)
        Task {
            do {
                try await s.connect()
                self.opening = false
                disconnectRemote()
                archive = nil
                let start = config.path.isEmpty ? s.home : config.path
                remote = RemoteLocation(session: s, path: start,
                                        base: URL(fileURLWithPath: "/.filetool-remote/" + UUID().uuidString))
                stopWatching()
                pathField = displayPath
                marked = []
                load(resetCursor: true)
                onNavigate?()
            } catch let err {
                self.opening = false
                s.disconnect()
                if let re = err as? RemoteError, case .cancelled = re { return }
                let a = NSAlert()
                a.messageText = "Připojení k \(config.title) selhalo"
                a.informativeText = err.localizedDescription
                a.runModal()
            }
        }
    }

    func goRemote(_ path: String) {
        guard var r = remote else { return }
        let p = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : RemotePath.join(r.path, path))
        r.path = (p as NSString).standardizingPath
        if r.path.isEmpty { r.path = "/" }
        remote = r
        pathField = displayPath
        marked = []
        load(resetCursor: true)
        onNavigate?()
    }

    func disconnectRemote() {
        guard let r = remote else { return }
        remote = nil
        r.session.disconnect()
    }

    /// Cesta zadaná do řádku cesty: u serveru vzdálená, jinak místní.
    func submitPath() {
        let s = pathField.trimmingCharacters(in: .whitespaces)
        if let r = remote {
            var p = s
            if p.hasPrefix(r.session.label) { p = String(p.dropFirst(r.session.label.count)) }
            if p.contains("://") { pathField = displayPath; NSSound.beep(); return }
            goRemote(p.isEmpty ? "/" : p)
            return
        }
        go(URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true))
    }

    private func loadRemote(_ r: RemoteLocation, select name: String?, resetCursor: Bool) {
        let keepName = name ?? current?.name
        let hidden = FTSettings.shared.showHidden
        let key = sortKey, asc = ascending, ff = FTSettings.shared.foldersFirst
        opening = true
        Task {
            let res: Result<[FileItem], Error>
            do { res = .success(try await r.session.list(r.path, base: r.base)) } catch let err { res = .failure(err) }
            self.opening = false
            guard self.remote?.base == r.base, self.remote?.path == r.path else { return }
            let parentItem = FileItem.parent(of: URL(fileURLWithPath: r.base.path + r.path))
            switch res {
            case .success(var list):
                if !hidden { list = list.filter { !$0.isHidden } }
                let all = [parentItem] + LocalFS.sort(list, by: key, ascending: asc, foldersFirst: ff)
                self.items = all
                self.error = nil
                self.marked = self.marked.intersection(Set(all.map(\.url)))
                if !resetCursor, let n = keepName, let i = all.firstIndex(where: { $0.name == n }) { self.cursor = i }
                else if resetCursor { self.cursor = 0 }
                self.cursor = min(self.cursor, max(0, all.count - 1))
            case .failure(let e):
                self.items = [parentItem]
                self.cursor = 0
                self.error = e.localizedDescription
            }
            self.version &+= 1
        }
    }

    // MARK: Výsledky hledání

    func showResults(_ urls: [URL], title: String) {
        disconnectRemote()
        archive = nil
        stopWatching()
        results = SearchResults(title: title.isEmpty ? "hledání" : title, urls: urls)
        pathField = displayPath
        marked = []
        load(resetCursor: true)
        onNavigate?()
    }

    private func loadResults(_ r: SearchResults, select name: String?, resetCursor: Bool) {
        let keepName = name ?? current?.name
        let hidden = FTSettings.shared.showHidden
        let key = sortKey, asc = ascending, ff = FTSettings.shared.foldersFirst
        let urls = r.urls, d = dir
        Task.detached(priority: .userInitiated) {
            let list = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { LocalFS.item($0) }
            await MainActor.run {
                guard self.results != nil else { return }
                self.results?.urls = list.map(\.url)               // smazané / přesunuté vypadnou
                let shown = hidden ? list : list.filter { !$0.isHidden }
                let all = [FileItem.parent(of: d.appendingPathComponent("_"))] + LocalFS.sort(shown, by: key, ascending: asc, foldersFirst: ff)
                self.items = all
                self.error = nil
                self.pathField = self.displayPath
                self.marked = self.marked.intersection(Set(all.map(\.url)))
                if !resetCursor, let n = keepName, let i = all.firstIndex(where: { $0.name == n }) { self.cursor = i }
                else if resetCursor { self.cursor = 0 }
                self.cursor = min(self.cursor, max(0, all.count - 1))
                self.version &+= 1
            }
        }
    }

    // MARK: Načtení (mimo hlavní vlákno) a sledování změn

    func load(select name: String? = nil, resetCursor: Bool = false) {
        if let r = results { loadResults(r, select: name, resetCursor: resetCursor); return }
        if let r = remote { loadRemote(r, select: name, resetCursor: resetCursor); return }
        if let a = archive { loadArchive(a, select: name, resetCursor: resetCursor); return }
        let d = dir, hidden = FTSettings.shared.showHidden
        let key = sortKey, asc = ascending, ff = FTSettings.shared.foldersFirst
        let keepName = name ?? current?.name
        Task.detached(priority: .userInitiated) {
            let r: Result<[FileItem], Error> = Result { try LocalFS.list(d, showHidden: hidden) }
            await MainActor.run {
                guard self.dir == d else { return }                     // mezitím jinam
                switch r {
                case .success(let list):
                    var all = LocalFS.sort(list, by: key, ascending: asc, foldersFirst: ff)
                    if d.path != "/" { all.insert(FileItem.parent(of: d), at: 0) }
                    self.items = all
                    self.error = nil
                    let existing = Set(all.map(\.url))
                    self.marked = self.marked.intersection(existing)
                    if !resetCursor, let n = keepName, let i = all.firstIndex(where: { $0.name == n }) { self.cursor = i }
                    else if resetCursor { self.cursor = 0 }
                    self.cursor = min(self.cursor, max(0, all.count - 1))
                case .failure(let e):
                    self.items = d.path == "/" ? [] : [FileItem.parent(of: d)]
                    self.cursor = 0
                    self.error = (e as NSError).code == NSFileReadNoPermissionError
                        ? "Bez oprávnění ke čtení – povol FileTool přístup v Nastavení systému → Soukromí a zabezpečení."
                        : e.localizedDescription
                }
                self.version &+= 1
                self.watch()
            }
        }
    }

    private func loadArchive(_ a: ArchiveLocation, select name: String?, resetCursor: Bool) {
        let keepName = name ?? current?.name
        let hidden = FTSettings.shared.showHidden
        var list = a.index.list(a.inner).map { FileItem.fromArchive($0, archive: a.file) }
        if !hidden { list = list.filter { !$0.isHidden } }
        var all = LocalFS.sort(list, by: sortKey, ascending: ascending, foldersFirst: FTSettings.shared.foldersFirst)
        all.insert(FileItem.parent(of: URL(fileURLWithPath: a.file.path + "/" + a.inner)), at: 0)
        items = all
        error = nil
        marked = marked.intersection(Set(all.map(\.url)))
        if !resetCursor, let n = keepName, let i = all.firstIndex(where: { $0.name == n }) { cursor = i }
        else if resetCursor { cursor = 0 }
        cursor = min(cursor, max(0, all.count - 1))
        version &+= 1
    }

    func refresh() { if remote != nil || results != nil { load() } else if archive != nil { reloadArchive() } else { load() } }

    func setSort(_ k: SortKey) {
        if sortKey == k { ascending.toggle() } else { sortKey = k; ascending = true }
        load()
    }

    /// Změna ve složce (jiný program, kopírování) → po krátké pauze znovu načíst.
    private func watch() {
        watcher?.cancel(); watcher = nil
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func stopWatching() { watcher?.cancel(); watcher = nil }

    // MARK: Označování

    func toggleMark(_ i: Int) {
        guard items.indices.contains(i), !items[i].isParent else { return }
        let u = items[i].url
        if marked.contains(u) { marked.remove(u) } else { marked.insert(u) }
    }

    func markAll() { marked = Set(items.filter { !$0.isParent }.map(\.url)) }
    func unmarkAll() { marked = [] }
    func invertMarks() { marked = Set(items.filter { !$0.isParent && !marked.contains($0.url) }.map(\.url)) }

    /// Maska jako v TC: „*.log“, „*.txt;*.md“ – add = označit, jinak odznačit.
    func mark(mask: String, add: Bool) {
        let pats = mask.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let hits = items.filter { i in !i.isParent && pats.contains { fnmatch($0, i.name, FNM_CASEFOLD) == 0 } }.map(\.url)
        if add { marked.formUnion(hits) } else { marked.subtract(hits) }
    }

    /// Souhrn pro stavový řádek.
    var summary: String {
        let files = items.filter { !$0.isDir && !$0.isParent }, dirs = items.filter { $0.isDir && !$0.isParent }
        let mFiles = files.filter { marked.contains($0.url) }, mDirs = dirs.filter { marked.contains($0.url) }
        let mBytes = mFiles.reduce(Int64(0)) { $0 + $1.size }, tBytes = files.reduce(Int64(0)) { $0 + $1.size }
        return "Výběr: \(Fmt.bytes(mBytes)) / \(Fmt.bytes(tBytes))   Soubory: \(mFiles.count) / \(files.count)   Složky: \(mDirs.count) / \(dirs.count)"
    }
}

/// Levý nebo pravý panel – záložky.
@MainActor
final class Panel: ObservableObject {
    @Published var tabs: [PanelTab]
    @Published var activeID: UUID
    var onChange: (() -> Void)?

    init(dirs: [URL], active: Int) {
        let t = (dirs.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : dirs).map { PanelTab(dir: $0) }
        tabs = t
        activeID = t[min(max(0, active), t.count - 1)].id
        for x in t { x.onNavigate = { [weak self] in self?.changed() } }
    }

    var tab: PanelTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    func newTab(_ dir: URL? = nil) {
        let t = PanelTab(dir: dir ?? tab.dir)
        t.onNavigate = { [weak self] in self?.changed() }
        if let i = tabs.firstIndex(where: { $0.id == activeID }) { tabs.insert(t, at: i + 1) } else { tabs.append(t) }
        activeID = t.id
        changed()
    }

    func close(_ id: UUID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        tabs[i].stopWatching()
        tabs[i].disconnectRemote()
        tabs.remove(at: i)
        if activeID == id { activeID = tabs[min(i, tabs.count - 1)].id }
        changed()
    }

    func cycle(_ d: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        activeID = tabs[(i + d + tabs.count) % tabs.count].id
        changed()
    }

    func select(_ id: UUID) { activeID = id; changed() }

    private func changed() { objectWillChange.send(); onChange?() }
}
