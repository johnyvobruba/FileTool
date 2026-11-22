import SwiftUI
import AppKit
import Quartz

enum Side: String { case left, right
    var other: Side { self == .left ? .right : .left }
}

/// Hlavní model: dva panely, aktivní strana, operace F3–F8, příkazový řádek.
@MainActor
final class Commander: ObservableObject {
    static let shared = Commander()

    let left: Panel
    let right: Panel
    @Published var activeSide: Side = .left
    @Published var commandLine = ""
    @Published private(set) var ops: [FileOperation] = []
    @Published var output: CommandOutput?

    /// Tabulky souborů (kvůli fokusu a Quick Look).
    var tables: [Side: FileTableNSView] = [:]
    private var opTimer: Timer?

    private init() {
        let d = UserDefaults.standard
        func restore(_ key: String, _ fallback: URL) -> (dirs: [URL], active: Int) {
            let paths = d.stringArray(forKey: key + ".tabs") ?? []
            let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                .filter { var b: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &b) && b.boolValue }
            return (urls.isEmpty ? [fallback] : urls, d.integer(forKey: key + ".active"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
        let l = restore("left", home), r = restore("right", downloads)
        left = Panel(dirs: l.dirs, active: l.active)
        right = Panel(dirs: r.dirs, active: r.active)
        left.onChange = { [weak self] in self?.save() }
        right.onChange = { [weak self] in self?.save() }
    }

    func panel(_ s: Side) -> Panel { s == .left ? left : right }
    var active: Panel { panel(activeSide) }
    var other: Panel { panel(activeSide.other) }
    var tab: PanelTab { active.tab }

    func save() {
        let d = UserDefaults.standard
        for (k, p) in [("left", left), ("right", right)] {
            d.set(p.tabs.map(\.dir.path), forKey: k + ".tabs")
            d.set(p.tabs.firstIndex { $0.id == p.activeID } ?? 0, forKey: k + ".active")
        }
    }

    // MARK: Fokus

    func activate(_ s: Side) {
        if activeSide != s { activeSide = s }
    }

    func focus(_ s: Side) {
        activeSide = s
        if let t = tables[s] { t.window?.makeFirstResponder(t) }
    }

    func switchPanel() { focus(activeSide.other) }

    /// ⌥⌘1 / ⌥⌘2: nabídka svazků a míst u tabulky panelu (jako Alt+F1/F2 v TC).
    func showPlaces(_ s: Side) {
        focus(s)
        guard let t = tables[s] else { return }
        let m = NSMenu()
        let target = PlaceTarget(tab: panel(s).tab)
        placeTarget = target
        for (title, places) in [("Svazky", Place.volumes()), ("Místa", Place.favorites())] {
            if m.numberOfItems > 0 { m.addItem(.separator()) }
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            h.isEnabled = false
            m.addItem(h)
            for p in places {
                let it = NSMenuItem(title: p.name, action: #selector(PlaceTarget.pick(_:)), keyEquivalent: "")
                it.target = target
                it.representedObject = p.url
                it.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)
                m.addItem(it)
            }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 8, y: t.visibleRect.minY + 8), in: t)
    }
    private var placeTarget: PlaceTarget?

    func refreshAll() { left.tab.refresh(); right.tab.refresh() }

    func swapPanels() {
        let a = left.tab.dir, b = right.tab.dir
        left.tab.go(b); right.tab.go(a)
    }

    /// Druhý panel otevře stejnou složku jako aktivní (⌘→ / ⌘←).
    func mirrorToOther() { other.tab.go(tab.dir) }

    // MARK: F3 – Zobrazit (Quick Look)

    func view() {
        guard let t = tables[activeSide] else { return }
        if tab.archive != nil {                                    // z archivu: rozbalit do dočasné složky
            let items = tab.selection.filter { !$0.isDir }
            guard !items.isEmpty else { NSSound.beep(); return }
            extractToTemp(tab, items) { urls in
                guard !urls.isEmpty else { return }
                t.previewURLs = urls
                t.window?.makeFirstResponder(t)
                QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
            }
            return
        }
        let urls = tab.selection.filter { !$0.isDir }.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        t.previewURLs = urls
        t.window?.makeFirstResponder(t)
        if let p = QLPreviewPanel.shared() {
            if p.isVisible { p.orderOut(nil) } else { p.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: F4 – Upravit

    func edit() {
        guard let i = tab.current, !i.isDir, !i.isParent else { NSSound.beep(); return }
        if tab.archive != nil {                                    // jen kopie – změny se do archivu nevrací
            extractToTemp(tab, [i]) { [weak self] urls in
                guard let u = urls.first else { return }
                self?.openInEditor(u)
                self?.alert("Upravuješ kopii z archivu", "Změny se do archivu automaticky neuloží. Upravený soubor zkopíruj zpět (F5) – do ZIP to jde.")
            }
            return
        }
        openInEditor(i.url)
    }

    private func openInEditor(_ url: URL) {
        let editor = FTSettings.shared.editorPath
        if !editor.isEmpty, FileManager.default.fileExists(atPath: editor) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: editor), configuration: NSWorkspace.OpenConfiguration())
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-t", url.path]              // výchozí textový editor (TextEdit)
            try? p.run()
        }
    }

    // MARK: Archivy

    /// Enter na souboru v archivu: rozbalit do dočasné složky a otevřít výchozí aplikací.
    func openFromArchive(_ t: PanelTab, _ items: [FileItem]) {
        extractToTemp(t, items) { urls in for u in urls { NSWorkspace.shared.open(u) } }
    }

    /// Rozbalí položky archivu do dočasné složky (pro náhled a otevření), karanténa se dědí z archivu.
    func extractToTemp(_ t: PanelTab, _ items: [FileItem], then: @escaping ([URL]) -> Void) {
        guard let a = t.archive else { return }
        let dir = ArchiveIO.viewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = items.compactMap(\.archiveInner)
        let op = FileOperation(kind: .copy, title: "Rozbalování z \(a.file.lastPathComponent)")
        op.total = a.index.totalSize(of: paths)
        start(op)
        Task {
            let errs = await extractEntries(a.file, encrypted: a.index.encrypted, paths: paths, strip: a.inner, to: dir, op: op)
            ArchiveIO.inheritQuarantine(from: a.file, to: dir)
            finish(op, errs, refresh: false)
            then(items.map { dir.appendingPathComponent($0.name) }.filter { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    /// Rozbalení s heslem: při šifrování (nebo chybě hesla) se zeptá, max. 3 pokusy.
    func extractEntries(_ file: URL, encrypted: Bool, paths: [String]?, strip: String, to dest: URL, op: FileOperation) async -> [String] {
        var pass = ArchivePasswords.get(file)
        if encrypted, pass == nil {
            pass = ArchivePasswords.ask(file)
            if pass == nil { return ["Zrušeno – bez hesla nelze rozbalit."] }
        }
        let cancel = op.cancel, progress = op.progress
        for attempt in 0..<3 {
            let p = pass
            let r: Result<[String], Error> = await Task.detached(priority: .userInitiated) {
                Result { try ArchiveIO.extract(file, paths: paths, stripPrefix: strip, to: dest, passphrase: p, cancel: cancel, progress: progress) }
            }.value
            switch r {
            case .success(let skipped): return skipped.map { "Přeskočeno: " + $0 }
            case .failure(let e):
                guard case .password? = e as? ArchiveError else { return [e.localizedDescription] }
                ArchivePasswords.forget(file)
                guard attempt < 2, let np = ArchivePasswords.ask(file, wrong: pass != nil) else { return ["Nesprávné heslo."] }
                pass = np
            }
        }
        return ["Nesprávné heslo."]
    }

    /// ⌥⌘5 (Alt+F5 v TC): zabalit označené do druhého panelu – ZIP, tar.gz nebo tar.xz.
    func pack() {
        guard tab.archive == nil, other.tab.archive == nil else { alert("Balení", "Zabalit jde z běžné složky do běžné složky."); return }
        let items = tab.selection
        guard !items.isEmpty else { NSSound.beep(); return }
        let defName = items.count == 1 ? items[0].baseName : tab.dir.lastPathComponent
        let a = NSAlert()
        a.messageText = "Zabalit \(items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek") do \(other.tab.dir.path)"
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); name.stringValue = defName
        let fmt = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 24), pullsDown: false)
        fmt.addItems(withTitles: ["zip", "tar.gz", "tar.xz"])
        let row = NSStackView(views: [name, fmt]); row.orientation = .horizontal; row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 420, height: 26)
        a.accessoryView = row
        a.addButton(withTitle: "Zabalit"); a.addButton(withTitle: "Zrušit")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let format = fmt.titleOfSelectedItem ?? "zip"
        guard !n.isEmpty, !n.contains("/") else { return }
        let out = other.tab.dir.appendingPathComponent(n + "." + format)
        if FileManager.default.fileExists(atPath: out.path) {
            let c = NSAlert(); c.messageText = "„\(out.lastPathComponent)“ už existuje"; c.addButton(withTitle: "Přepsat"); c.addButton(withTitle: "Zrušit")
            guard c.runModal() == .alertFirstButtonReturn else { return }
            try? FileManager.default.removeItem(at: out)
        }
        let op = FileOperation(kind: .copy, title: "Balení do \(out.lastPathComponent)")
        start(op)
        let dir = tab.dir, names = items.map(\.name), cancel = op.cancel
        Task.detached(priority: .userInitiated) {
            var errs: [String] = []
            do { try ArchiveIO.create(out, from: dir, names: names, format: format, cancel: cancel) } catch { errs.append(error.localizedDescription) }
            await MainActor.run { self.finish(op, errs) }
        }
    }

    /// ⌥⌘9 (Alt+F9 v TC): rozbalit označené archivy (nebo obsah otevřeného archivu) do druhého panelu.
    func unpack() {
        guard other.tab.archive == nil else { alert("Rozbalení", "Cílový panel musí být běžná složka."); return }
        let dest = other.tab.dir
        if let a = tab.archive {
            let items = tab.marked.isEmpty ? nil : tab.selection.compactMap(\.archiveInner)
            guard confirm("Rozbalit \(items == nil ? "celý obsah" : "\(items!.count) položek") z „\(a.file.lastPathComponent)“ do \(dest.path)?") else { return }
            let op = FileOperation(kind: .copy, title: "Rozbalování \(a.file.lastPathComponent)")
            op.total = a.index.totalSize(of: items ?? [a.inner].filter { !$0.isEmpty })
            start(op)
            Task {
                let errs = await extractEntries(a.file, encrypted: a.index.encrypted,
                                                paths: items ?? (a.inner.isEmpty ? nil : [a.inner]), strip: a.inner, to: dest, op: op)
                finish(op, errs)
            }
            return
        }
        let archives = tab.selection.filter(\.isArchive)
        guard !archives.isEmpty else { alert("Rozbalení", "Označ archivy (ZIP, tar.gz, 7z, RAR…)."); return }
        let a = NSAlert()
        a.messageText = "Rozbalit \(archives.count == 1 ? "„\(archives[0].name)“" : "\(archives.count) archivů") do \(dest.path)?"
        let sub = NSButton(checkboxWithTitle: "Každý archiv do vlastní složky", target: nil, action: nil)
        sub.state = .on
        a.accessoryView = sub
        a.addButton(withTitle: "Rozbalit"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let ownFolder = sub.state == .on
        let op = FileOperation(kind: .copy, title: "Rozbalování \(archives.count) archivů")
        op.total = archives.reduce(Int64(0)) { $0 + max(0, $1.size) }
        start(op)
        Task {
            var errs: [String] = []
            for ar in archives {
                if op.cancel.value { break }
                var target = dest
                if ownFolder {
                    var base = ar.name
                    for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where base.lowercased().hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }
                    if base == ar.name { base = (ar.name as NSString).deletingPathExtension }
                    target = dest.appendingPathComponent(base, isDirectory: true)
                    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                }
                errs += await extractEntries(ar.url, encrypted: false, paths: nil, strip: "", to: target, op: op).map { "\(ar.name): \($0)" }
                ArchiveIO.inheritQuarantine(from: ar.url, to: target)
            }
            finish(op, errs)
        }
    }

    private func confirm(_ text: String) -> Bool {
        let a = NSAlert(); a.messageText = text
        a.addButton(withTitle: "Pokračovat"); a.addButton(withTitle: "Zrušit")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Kopírování / přesun s archivem na jedné straně. true = obslouženo.
    private func archiveTransfer(move: Bool) -> Bool {
        let src = tab, dst = other.tab
        if src.archive != nil && dst.archive != nil {
            alert("Mezi dvěma archivy zatím nelze kopírovat", "Rozbal nejdřív do složky (⌥⌘9) a pak přidej do druhého archivu."); return true
        }
        if let a = src.archive {                                   // z archivu → složka
            let items = src.selection
            guard !items.isEmpty else { NSSound.beep(); return true }
            if move && !ArchiveIO.isZip(a.file) {
                alert("Archiv \(a.index.format) je jen pro čtení", "Přesun ven jde jen ze ZIP. Použij kopírování (F5)."); return true
            }
            let what = items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek"
            guard let target = askText(move ? "Přesunout \(what) z archivu do:" : "Rozbalit \(what) do:", info: a.file.lastPathComponent,
                                       initial: dst.dir.path, button: move ? "Přesunout" : "Rozbalit") else { return true }
            let dest = URL(fileURLWithPath: (target as NSString).expandingTildeInPath, isDirectory: true)
            let clashes = items.filter { FileManager.default.fileExists(atPath: dest.appendingPathComponent($0.name).path) }
            if !clashes.isEmpty, !confirm("\(clashes.count) položek už v cíli existuje – přepsat?\n" + clashes.prefix(10).map(\.name).joined(separator: "\n")) { return true }
            let paths = items.compactMap(\.archiveInner)
            let op = FileOperation(kind: move ? .move : .copy, title: (move ? "Přesun z " : "Rozbalování z ") + a.file.lastPathComponent)
            op.total = a.index.totalSize(of: paths)
            start(op)
            Task {
                var errs = await extractEntries(a.file, encrypted: a.index.encrypted, paths: paths, strip: a.inner, to: dest, op: op)
                ArchiveIO.inheritQuarantine(from: a.file, to: dest)
                if move && errs.isEmpty {                          // ze ZIP odebrat až po úspěšném rozbalení
                    let dirs = Set(items.filter(\.isDir).compactMap(\.archiveInner))
                    let file = a.file
                    let r = await Task.detached { Result { try ArchiveIO.deleteFromZip(file, paths: paths, dirs: dirs) } }.value
                    if case .failure(let e) = r { errs.append("Rozbaleno, ale ze ZIP nešlo odebrat: \(e.localizedDescription)") }
                }
                finish(op, errs)
            }
            return true
        }
        if let b = dst.archive {                                   // složka → do ZIP
            guard ArchiveIO.isZip(b.file) else {
                alert("Do archivu \(b.index.format) nelze zapisovat", "Přidávat jde jen do ZIP. Pro jiný formát použij Zabalit (⌥⌘5)."); return true
            }
            guard !b.index.encrypted else { alert("Šifrovaný ZIP", "Přidávání do šifrovaného ZIP zatím není podporované."); return true }
            let items = src.selection
            guard !items.isEmpty else { NSSound.beep(); return true }
            let inner = b.inner
            let existing = Set(b.index.list(inner).map(\.name))
            let clashes = items.filter { existing.contains($0.name) }
            let place = b.file.lastPathComponent + (inner.isEmpty ? "" : "/" + inner)
            var text = (move ? "Přesunout " : "Přidat ") + "\(items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek") do \(place)?"
            if !clashes.isEmpty { text += "\n\n\(clashes.count) položek v ZIP už existuje a bude nahrazeno." }
            if move { text += "\n\nOriginály se přesunou do Koše až po ověření ZIP." }
            guard confirm(text) else { return true }
            let op = FileOperation(kind: move ? .move : .copy, title: (move ? "Přesun do " : "Přidávání do ") + b.file.lastPathComponent)
            start(op)
            let srcs = items.map(\.url), zip = b.file, cancel = op.cancel
            Task.detached(priority: .userInitiated) {
                var errs: [String] = []
                do {
                    try ArchiveIO.addToZip(zip, inner: inner, sources: srcs, cancel: cancel)
                    if move {
                        for u in srcs {
                            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
                            catch { errs.append("\(u.lastPathComponent): přidáno, ale original nejde přesunout do Koše – \(error.localizedDescription)") }
                        }
                    }
                } catch { errs.append(error.localizedDescription) }
                await MainActor.run { self.finish(op, errs) }
            }
            return true
        }
        return false
    }

    // MARK: F5 / F6 – Kopírovat / Přesunout

    func transfer(move: Bool) {
        if archiveTransfer(move: move) { return }
        let items = tab.selection
        guard !items.isEmpty else { NSSound.beep(); return }
        let what = items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek"
        guard let target = askText(move ? "Přesunout \(what) do:" : "Kopírovat \(what) do:",
                                   info: "Cíl je složka druhého panelu – cestu můžeš upravit.",
                                   initial: other.tab.dir.path, button: move ? "Přesunout" : "Kopírovat") else { return }
        let dir = URL(fileURLWithPath: (target as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            alert("Cílová složka neexistuje", dir.path); return
        }
        let clashes = items.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.name).path) }
        var policy = FileOps.Conflict.overwrite
        if !clashes.isEmpty {
            let a = NSAlert()
            a.messageText = "\(clashes.count == 1 ? "Položka už" : "\(clashes.count) položek už") v cíli existuje"
            a.informativeText = clashes.prefix(12).map(\.name).joined(separator: "\n")
                + (clashes.count > 12 ? "\n…" : "") + "\n\nSložky se při přepsání sloučí."
            a.addButton(withTitle: "Přepsat"); a.addButton(withTitle: "Přeskočit existující"); a.addButton(withTitle: "Zrušit")
            switch a.runModal() {
            case .alertFirstButtonReturn: policy = .overwrite
            case .alertSecondButtonReturn: policy = .skip
            default: return
            }
        }
        let op = FileOperation(kind: move ? .move : .copy, title: (move ? "Přesun " : "Kopírování ") + what)
        start(op)
        let srcs = items.map(\.url)
        let cancel = op.cancel, progress = op.progress
        Task.detached(priority: .userInitiated) {
            let total = FileOps.totalSize(srcs)
            await MainActor.run { op.total = total }
            let errs = FileOps.transfer(srcs, to: dir, move: move, conflict: policy, cancel: cancel, progress: progress)
            await MainActor.run { self.finish(op, errs) }
        }
    }

    /// Přetažení myší (z Finderu nebo druhého panelu): bez dotazu na cíl, kolize se ale řeší.
    /// Přetažení do panelu s otevřeným ZIP = přidat do ZIP (stejně jako F5).
    func dropIntoArchive(_ t: PanelTab, _ srcs: [URL]) {
        guard let b = t.archive, ArchiveIO.isZip(b.file), !b.index.encrypted else { alert("Do tohoto archivu nelze přidávat", "Přidávat jde jen do nešifrovaného ZIP."); return }
        guard confirm("Přidat \(srcs.count) položek do \(b.file.lastPathComponent)\(b.inner.isEmpty ? "" : "/" + b.inner)?") else { return }
        let op = FileOperation(kind: .copy, title: "Přidávání do \(b.file.lastPathComponent)")
        start(op)
        let zip = b.file, inner = b.inner, cancel = op.cancel
        Task.detached(priority: .userInitiated) {
            var errs: [String] = []
            do { try ArchiveIO.addToZip(zip, inner: inner, sources: srcs, cancel: cancel) } catch { errs.append(error.localizedDescription) }
            await MainActor.run { self.finish(op, errs) }
        }
    }

    func dropTransfer(_ srcs: [URL], to dir: URL, move: Bool) {
        let clashes = srcs.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.lastPathComponent).path) }
        var policy = FileOps.Conflict.overwrite
        if !clashes.isEmpty {
            let a = NSAlert()
            a.messageText = "\(clashes.count) položek už v cíli existuje"
            a.informativeText = clashes.prefix(12).map(\.lastPathComponent).joined(separator: "\n")
            a.addButton(withTitle: "Přepsat"); a.addButton(withTitle: "Přeskočit existující"); a.addButton(withTitle: "Zrušit")
            switch a.runModal() {
            case .alertFirstButtonReturn: policy = .overwrite
            case .alertSecondButtonReturn: policy = .skip
            default: return
            }
        }
        let op = FileOperation(kind: move ? .move : .copy, title: (move ? "Přesun " : "Kopírování ") + "\(srcs.count) položek")
        start(op)
        let cancel = op.cancel, progress = op.progress
        Task.detached(priority: .userInitiated) {
            let total = FileOps.totalSize(srcs)
            await MainActor.run { op.total = total }
            let errs = FileOps.transfer(srcs, to: dir, move: move, conflict: policy, cancel: cancel, progress: progress)
            await MainActor.run { self.finish(op, errs) }
        }
    }

    // MARK: F7 – Nová složka

    func mkdir() {
        if tab.archive != nil { alert("V archivu nelze vytvořit složku", "Vytvoř ji ve složce a přidej do ZIP (F5)."); return }
        guard let n = askText("Nová složka", info: "v \(tab.dir.path)", initial: "", button: "Vytvořit"),
              !n.isEmpty, !n.contains("/") else { return }
        do {
            try FileManager.default.createDirectory(at: tab.dir.appendingPathComponent(n), withIntermediateDirectories: false)
            tab.load(select: n)
        } catch { alert("Složku nelze vytvořit", error.localizedDescription) }
    }

    // MARK: F8 – Smazat

    func delete(permanent: Bool = false) {
        let items = tab.selection
        guard !items.isEmpty else { NSSound.beep(); return }
        if let a = tab.archive {                                   // mazání v ZIP
            guard ArchiveIO.isZip(a.file) else { alert("Archiv \(a.index.format) je jen pro čtení", "Mazat jde jen ze ZIP."); return }
            guard confirm("Odebrat ze ZIP „\(a.file.lastPathComponent)“ \(items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek")?\n\nNelze vrátit (Koš se u položek v archivu nepoužije).") else { return }
            let op = FileOperation(kind: .delete, title: "Odebírání ze \(a.file.lastPathComponent)")
            start(op)
            let paths = items.compactMap(\.archiveInner), dirs = Set(items.filter(\.isDir).compactMap(\.archiveInner)), file = a.file
            Task.detached(priority: .userInitiated) {
                var errs: [String] = []
                do { try ArchiveIO.deleteFromZip(file, paths: paths, dirs: dirs) } catch { errs.append(error.localizedDescription) }
                await MainActor.run { self.finish(op, errs) }
            }
            return
        }
        let trash = FTSettings.shared.useTrash && !permanent
        if FTSettings.shared.confirmDelete || !trash {
            let a = NSAlert()
            a.alertStyle = trash ? .warning : .critical
            a.messageText = (trash ? "Přesunout do Koše " : "TRVALE smazat ")
                + (items.count == 1 ? "„\(items[0].name)“?" : "\(items.count) položek?")
            a.informativeText = items.prefix(12).map { ($0.isDir ? "📁 " : "") + $0.name }.joined(separator: "\n")
                + (items.count > 12 ? "\n…" : "") + (trash ? "" : "\n\nTrvalé smazání nelze vrátit.")
            a.addButton(withTitle: trash ? "Do Koše" : "Smazat trvale"); a.addButton(withTitle: "Zrušit")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let op = FileOperation(kind: .delete, title: (trash ? "Do Koše: " : "Mazání: ") + "\(items.count) položek")
        op.total = Int64(items.count)
        start(op)
        let urls = items.map(\.url)
        let cancel = op.cancel, progress = op.progress
        Task.detached(priority: .userInitiated) {
            let errs = FileOps.delete(urls, trash: trash, cancel: cancel, progress: progress)
            await MainActor.run { self.finish(op, errs) }
        }
    }

    // MARK: ⇧F6 – Přejmenovat

    func rename() {
        guard let i = tab.current, !i.isParent else { NSSound.beep(); return }
        if tab.archive != nil { alert("V archivu nelze přejmenovat", "Rozbal položku, přejmenuj ji a přidej zpět."); return }
        guard let n = askText("Přejmenovat", info: i.name, initial: i.name, button: "Přejmenovat", selectBase: !i.isDir),
              !n.isEmpty, n != i.name, !n.contains("/") else { return }
        let dst = i.url.deletingLastPathComponent().appendingPathComponent(n)
        if FileManager.default.fileExists(atPath: dst.path) { alert("„\(n)“ už existuje", ""); return }
        do { try FileManager.default.moveItem(at: i.url, to: dst); tab.load(select: n) }
        catch { alert("Nelze přejmenovat", error.localizedDescription) }
    }

    /// Otevřít výchozí aplikací (i archiv, místo procházení).
    func openExternally() {
        guard let i = tab.current, !i.isParent, i.archiveInner == nil else { if let i = tab.current, i.archiveInner != nil { openFromArchive(tab, [i]) }; return }
        NSWorkspace.shared.open(i.url)
    }

    func revealInFinder() {
        if let a = tab.archive { NSWorkspace.shared.activateFileViewerSelecting([a.file]); return }
        let urls = tab.selection.map(\.url)
        if urls.isEmpty { NSWorkspace.shared.open(tab.dir) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copyPaths() {
        let p = tab.selection.map(\.url.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((p.isEmpty ? [tab.dir.path] : p).joined(separator: "\n"), forType: .string)
    }

    func openTerminalHere() {
        NSWorkspace.shared.open([tab.dir], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Označování maskou (+ / -)

    func markByMask(add: Bool) {
        guard let m = askText(add ? "Označit soubory" : "Odznačit soubory", info: "Maska, víc masek odděl středníkem (např. *.log;*.txt)",
                              initial: "*.*", button: add ? "Označit" : "Odznačit") else { return }
        tab.mark(mask: m == "*.*" ? "*" : m, add: add)
    }

    // MARK: Průběh operací

    private func start(_ op: FileOperation) {
        ops.append(op)
        if opTimer == nil {
            opTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for o in self.ops where !o.finished { o.pull() }
                }
            }
        }
    }

    private func finish(_ op: FileOperation, _ errs: [String], refresh: Bool = true) {
        op.pull()
        op.errors = errs
        op.finished = true
        if op.total > 0, errs.isEmpty { op.done = op.total }
        if refresh { left.tab.refresh(); right.tab.refresh() }
        if !errs.isEmpty {
            alert("\(op.title) – \(errs.count) \(errs.count == 1 ? "chyba" : "chyb")", errs.prefix(15).joined(separator: "\n"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (errs.isEmpty ? 1.5 : 0.1)) { [weak self] in
            guard let self else { return }
            self.ops.removeAll { $0.id == op.id }
            if self.ops.isEmpty { self.opTimer?.invalidate(); self.opTimer = nil }
        }
    }

    // MARK: Příkazový řádek

    func runCommandLine() {
        let cmd = commandLine.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        commandLine = ""
        if cmd == "cd" { tab.go(FileManager.default.homeDirectoryForCurrentUser); return }
        if cmd.hasPrefix("cd ") {
            let arg = (String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            tab.go(arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : tab.dir.appendingPathComponent(arg))
            return
        }
        let dir = tab.dir
        let out = CommandOutput(command: cmd, dir: dir.path)
        output = out
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.currentDirectoryURL = dir
            p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                await MainActor.run { out.append("Nelze spustit: \(error.localizedDescription)\n"); out.running = false }
                return
            }
            await MainActor.run { out.process = p }
            let h = pipe.fileHandleForReading
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                let s = String(decoding: d, as: UTF8.self)
                await MainActor.run { out.append(s) }
            }
            p.waitUntilExit()
            let code = p.terminationStatus
            await MainActor.run {
                out.running = false
                out.append("\n[konec · kód \(code)]\n")
                self.tab.refresh()
            }
        }
    }

    // MARK: Dialogy

    func askText(_ title: String, info: String, initial: String, button: String, selectBase: Bool = false) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: button); a.addButton(withTitle: "Zrušit")
        a.window.initialFirstResponder = f
        DispatchQueue.main.async {                       // u přejmenování označit jen název bez přípony
            if selectBase, let ed = f.currentEditor() {
                let base = (initial as NSString).deletingPathExtension
                ed.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return f.stringValue.trimmingCharacters(in: .whitespaces)
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

/// Cíl položek nabídky svazků (NSMenu potřebuje Objective-C target).
@MainActor
final class PlaceTarget: NSObject {
    let tab: PanelTab
    init(tab: PanelTab) { self.tab = tab }
    @objc func pick(_ it: NSMenuItem) { if let u = it.representedObject as? URL { tab.go(u) } }
}

/// Výstup příkazu z příkazového řádku (okno nad panely).
@MainActor
final class CommandOutput: ObservableObject, Identifiable {
    let id = UUID()
    let command: String
    let dir: String
    @Published var text = ""
    @Published var running = true
    var process: Process?
    init(command: String, dir: String) { self.command = command; self.dir = dir }

    func append(_ s: String) {
        text += s
        if text.count > 400_000 { text = String(text.suffix(300_000)) }
    }

    func stop() { process?.terminate() }
}
