import SwiftUI
import AppKit

// Synchronizace složek (jako v Total / Double Commanderu): porovná levý a pravý panel
// (podle data + velikosti, nebo i obsahu), ukáže rozdíly a zkopíruje je zvoleným směrem.
// Mazání jen na výslovnou volbu „Zrcadlit“ a vždy do Koše.

enum SyncAction: String { case toRight = "→", toLeft = "←", skip = "—", equal = "=", deleteRight = "🗑→", deleteLeft = "←🗑" }

struct SyncRow: Identifiable {
    let id = UUID()
    let rel: String
    let isDir: Bool
    var left: (size: Int64, date: Date)?
    var right: (size: Int64, date: Date)?
    var action: SyncAction
    var differs: Bool              // obsahově / podle data se liší
}

enum SyncDirection: String, CaseIterable, Identifiable {
    case both = "Oba směry", toRight = "Vlevo → vpravo", toLeft = "Vpravo → vlevo"
    var id: String { rawValue }
}

@MainActor
final class SyncModel: ObservableObject {
    let leftDir: URL
    let rightDir: URL
    @Published var rows: [SyncRow] = []
    @Published var direction: SyncDirection = .both { didSet { assignActions() } }
    @Published var byContent = false
    @Published var subdirs = true
    @Published var ignoreDate = false
    @Published var mirror = false { didSet { assignActions() } }
    @Published var showEqual = false
    @Published var mask = "*"
    @Published var running = false
    @Published var status = ""
    private var cancel = Box(false)

    init(left: URL, right: URL) { leftDir = left; rightDir = right }

    var shown: [SyncRow] { rows.filter { showEqual || $0.action != .equal } }
    var counts: (r: Int, l: Int, del: Int) {
        (rows.filter { $0.action == .toRight }.count, rows.filter { $0.action == .toLeft }.count,
         rows.filter { $0.action == .deleteLeft || $0.action == .deleteRight }.count)
    }

    // MARK: Porovnání

    nonisolated static func scan(_ root: URL, sub: Bool, masks: [String], cancel: Box<Bool>) -> [String: (Int64, Date, Bool)] {
        var out: [String: (Int64, Date, Bool)] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let opts: FileManager.DirectoryEnumerationOptions = sub ? [.skipsPackageDescendants] : [.skipsSubdirectoryDescendants]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: opts, errorHandler: { _, _ in true })
        let base = root.standardizedFileURL.path
        while let u = e?.nextObject() as? URL {
            if cancel.value { break }
            let name = u.lastPathComponent
            if name == ".DS_Store" { continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            let isDir = v.isDirectory == true
            if !isDir, !masks.isEmpty, !masks.contains(where: { fnmatch($0, name, FNM_CASEFOLD) == 0 }) { continue }
            out[rel] = (isDir ? 0 : Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast, isDir)
        }
        return out
    }

    func compare() {
        cancel.value = true
        let c = Box(false); cancel = c
        running = true; status = "Porovnávám…"; rows = []
        let l = leftDir, r = rightDir, sub = subdirs, content = byContent, noDate = ignoreDate
        let masks = mask.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "*" && $0 != "*.*" }
        Task.detached(priority: .userInitiated) {
            let a = SyncModel.scan(l, sub: sub, masks: masks, cancel: c)
            let b = SyncModel.scan(r, sub: sub, masks: masks, cancel: c)
            var out: [SyncRow] = []
            var checked = 0
            for rel in Set(a.keys).union(b.keys).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                if c.value { break }
                let x = a[rel], y = b[rel]
                let isDir = (x?.2 ?? y?.2) ?? false
                if isDir, x != nil, y != nil { continue }                         // složka na obou stranách – řeší se obsah
                var differs = true
                if let x, let y, !isDir {
                    let sameSize = x.0 == y.0
                    let sameDate = noDate || abs(x.1.timeIntervalSince(y.1)) < 2          // FAT/SMB mají přesnost 2 s
                    if content, sameSize {
                        checked += 1
                        if checked % 20 == 0 { let k = checked; await MainActor.run { if self.cancel === c { self.status = "Porovnávám obsah… \(k)" } } }
                        differs = CleanFS.hash(l.appendingPathComponent(rel)) != CleanFS.hash(r.appendingPathComponent(rel))
                    } else {
                        differs = !(sameSize && sameDate)
                    }
                }
                out.append(SyncRow(rel: rel, isDir: isDir,
                                   left: x.map { ($0.0, $0.1) }, right: y.map { ($0.0, $0.1) },
                                   action: .skip, differs: differs))
            }
            // složka jen na jedné straně: obsah se přenese s ní → vnořené řádky skrýt
            let onlyDirs = out.filter { $0.isDir && ($0.left == nil || $0.right == nil) }.map { $0.rel + "/" }
            out.removeAll { r in onlyDirs.contains { r.rel.hasPrefix($0) } }
            let result = out
            await MainActor.run {
                guard self.cancel === c else { return }
                self.rows = result
                self.assignActions()
                self.running = false
                let k = self.counts
                self.status = c.value ? "Zrušeno" : "Rozdílů: \(k.r + k.l + k.del) (→ \(k.r), ← \(k.l)" + (k.del > 0 ? ", smazat \(k.del)" : "") + ")"
            }
        }
    }

    /// Výchozí akce podle směru: novější přepíše starší, chybějící se doplní, „Zrcadlit“ maže navíc v cíli.
    func assignActions() {
        for i in rows.indices {
            let r = rows[i]
            var a: SyncAction = .skip
            switch (r.left, r.right) {
            case (_?, nil):
                a = direction == .toLeft ? (mirror ? .deleteLeft : .skip) : .toRight
            case (nil, _?):
                a = direction == .toRight ? (mirror ? .deleteRight : .skip) : .toLeft
            case (let x?, let y?):
                if !r.differs { a = .equal }
                else {
                    switch direction {
                    case .toRight: a = .toRight
                    case .toLeft: a = .toLeft
                    case .both: a = x.date >= y.date ? .toRight : .toLeft
                    }
                }
            default: a = .skip
            }
            rows[i].action = a
        }
    }

    /// Klik na akci: → / ← / přeskočit (u položky jen na jedné straně i smazat).
    func cycle(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].action != .equal else { return }
        let r = rows[i]
        var options: [SyncAction] = [.skip]
        if r.left != nil { options.append(.toRight) }
        if r.right != nil { options.append(.toLeft) }
        if r.left != nil, r.right == nil { options.append(.deleteLeft) }
        if r.right != nil, r.left == nil { options.append(.deleteRight) }
        let cur = options.firstIndex(of: r.action) ?? 0
        rows[i].action = options[(cur + 1) % options.count]
    }

    // MARK: Provedení

    func run() {
        let todo = rows.filter { [.toRight, .toLeft, .deleteLeft, .deleteRight].contains($0.action) }
        guard !todo.isEmpty else { NSSound.beep(); return }
        let k = counts
        let a = NSAlert()
        a.alertStyle = k.del > 0 ? .warning : .informational
        a.messageText = "Synchronizovat \(todo.count) položek?"
        a.informativeText = "→ do \(rightDir.path): \(k.r)\n← do \(leftDir.path): \(k.l)"
            + (k.del > 0 ? "\n\nDo Koše: \(k.del) (zrcadlení)" : "") + "\n\nExistující soubory v cíli se přepíšou."
        a.addButton(withTitle: "Synchronizovat"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let l = leftDir, r = rightDir
        let op = FileOperation(kind: .copy, title: "Synchronizace \(l.lastPathComponent) ↔ \(r.lastPathComponent)")
        op.total = todo.reduce(Int64(0)) { $0 + (($1.action == .toRight ? $1.left?.size : $1.action == .toLeft ? $1.right?.size : 0) ?? 0) }
        Commander.shared.start(op)
        running = true; status = "Synchronizuji…"
        let cancel = op.cancel, progress = op.progress
        let jobs = todo.map { ($0.rel, $0.action) }
        Task.detached(priority: .userInitiated) {
            var errs: [String] = []
            let fm = FileManager.default
            for (rel, act) in jobs {
                if cancel.value { break }
                switch act {
                case .toRight, .toLeft:
                    let src = (act == .toRight ? l : r).appendingPathComponent(rel)
                    let dstDir = (act == .toRight ? r : l).appendingPathComponent(rel).deletingLastPathComponent()
                    try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                    errs += FileOps.transfer([src], to: dstDir, move: false, conflict: .overwrite, cancel: cancel, progress: progress)
                case .deleteLeft, .deleteRight:
                    let u = (act == .deleteLeft ? l : r).appendingPathComponent(rel)
                    do { try fm.trashItem(at: u, resultingItemURL: nil) } catch let err { errs.append("\(rel): \(err.localizedDescription)") }
                default: break
                }
            }
            await MainActor.run { [errs] in
                Commander.shared.finish(op, errs)
                self.running = false
                self.compare()
            }
        }
    }

    func stop() { cancel.value = true; running = false }
}

struct SyncView: View {
    @ObservedObject var m: SyncModel

    private func info(_ x: (size: Int64, date: Date)?, dir: Bool) -> String {
        guard let x else { return "" }
        return (dir ? "<DIR>" : Fmt.bytes(x.size)) + "  " + Fmt.date.string(from: x.date)
    }
    private func color(_ a: SyncAction) -> SwiftUI.Color {
        switch a {
        case .toRight, .toLeft: return UI.accent
        case .deleteLeft, .deleteRight: return UI.error
        case .equal: return UI.ok
        case .skip: return UI.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(m.leftDir.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(UI.textSecondary)
                Label(m.rightDir.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 14) {
                Picker("", selection: $m.direction) { ForEach(SyncDirection.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 340)
                Toggle("Podsložky", isOn: $m.subdirs)
                Toggle("Podle obsahu", isOn: $m.byContent).tip("Soubory stejné velikosti porovná podle obsahu (SHA-256) – pomalejší, ale přesné.")
                Toggle("Ignorovat datum", isOn: $m.ignoreDate)
                Toggle("Zrcadlit (smazat navíc)", isOn: $m.mirror)
                    .tip("Položky, které jsou jen v cíli, přesune do Koše – cíl bude přesnou kopií zdroje. Jen pro jednosměrnou synchronizaci.")
                    .disabled(m.direction == .both)
            }
            .toggleStyle(.checkbox).font(.system(size: 12))
            HStack {
                Text("Maska").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                TextField("*", text: $m.mask).textFieldStyle(.roundedBorder).frame(width: 200).font(SK.monoFont)
                    .tip("Např. *.log;*.cfg – víc masek odděl středníkem")
                Button(m.rows.isEmpty ? "Porovnat" : "Porovnat znovu") { m.compare() }.disabled(m.running)
                Toggle("Zobrazit i shodné", isOn: $m.showEqual).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                if m.running { ProgressView().controlSize(.small); Button("Zastavit") { m.stop() } }
            }
            Table(m.shown) {
                TableColumn("Soubor") { r in
                    HStack(spacing: 5) {
                        Image(systemName: r.isDir ? "folder" : "doc").foregroundStyle(UI.textSecondary)
                        Text(r.rel).lineLimit(1).truncationMode(.middle)
                    }
                }
                TableColumn("Vlevo") { r in Text(info(r.left, dir: r.isDir)).font(.system(size: 11).monospacedDigit()).foregroundStyle(UI.textSecondary) }
                    .width(200)
                TableColumn("Akce") { r in
                    Button { m.cycle(r.id) } label: {
                        Text(r.action.rawValue).font(.system(size: 14, weight: .bold)).foregroundStyle(color(r.action)).frame(width: 44)
                    }
                    .buttonStyle(.plain)
                    .tip("Klikem změníš: → kopírovat doprava · ← doleva · — přeskočit" + (r.left == nil || r.right == nil ? " · 🗑 smazat (do Koše)" : ""))
                }
                .width(60)
                TableColumn("Vpravo") { r in Text(info(r.right, dir: r.isDir)).font(.system(size: 11).monospacedDigit()).foregroundStyle(UI.textSecondary) }
                    .width(200)
            }
            HStack {
                Text(m.status).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Spacer()
                let k = m.counts
                Button("Synchronizovat (→ \(k.r), ← \(k.l)\(k.del > 0 ? ", 🗑 \(k.del)" : ""))") { m.run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.running || k.r + k.l + k.del == 0)
            }
        }
        .padding(16)
        .frame(minWidth: 960, minHeight: 520)
        .background(UI.app)
        .onAppear { if m.rows.isEmpty { m.compare() } }
    }
}

@MainActor
enum SyncWindow {
    private static var windows: [NSWindow] = []

    static func show(left: URL, right: URL) {
        let m = SyncModel(left: left, right: right)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Synchronizace složek"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SyncView(m: m).preferredColorScheme(FTSettings.shared.isDark ? .dark : .light))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { m.stop(); windows.removeAll { $0 === w } }
        }
        windows.append(w)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

extension Commander {
    /// ⇧⌘S – synchronizace levého a pravého panelu (místní složky, SMB / NAS svazky).
    func syncDirs() {
        let l = left.tab, r = right.tab
        guard l.remote == nil, r.remote == nil, l.archive == nil, r.archive == nil, l.results == nil, r.results == nil else {
            alert("Synchronizace složek", "Oba panely musí ukazovat místní složku (i připojený SMB / NAS disk) – ne server přes SFTP/FTP ani archiv."); return
        }
        guard l.dir.standardizedFileURL != r.dir.standardizedFileURL else { alert("Synchronizace složek", "Oba panely ukazují stejnou složku."); return }
        SyncWindow.show(left: l.dir, right: r.dir)
    }
}
