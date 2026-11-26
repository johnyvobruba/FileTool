import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

/// Tabulka souborů (AppKit) – klávesnice jako v Total Commanderu.
final class FileTableNSView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var side: Side = .left
    var keyHandler: ((NSEvent) -> Bool)?
    var onFocus: (() -> Void)?
    var previewURLs: [URL] = []

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        needsDisplay = true
        return ok
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    // Quick Look (F3 / ⌘3)
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }
}

/// Řádek: kurzor v barvě profilu (aktivní panel výrazně, neaktivní tlumeně).
final class FileRowView: NSTableRowView {
    var activePanel: () -> Bool = { true }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        (activePanel() ? UI.NS.cursor : UI.NS.cursorInactive).setFill()
        bounds.fill()
        if activePanel() {
            UI.NS.accent.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
    }
    override var isEmphasized: Bool { get { false } set {} }
}

struct FileTable: NSViewRepresentable {
    @ObservedObject var tab: PanelTab
    let side: Side
    let commander: Commander
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let t = FileTableNSView()
        t.side = side
        t.headerView = ThemedHeaderView()
        t.usesAlternatingRowBackgroundColors = false
        t.allowsMultipleSelection = false
        t.allowsEmptySelection = false
        t.intercellSpacing = NSSize(width: 6, height: 0)
        t.rowHeight = CGFloat(fontSize) + 7
        t.style = .plain
        t.gridStyleMask = []
        t.focusRingType = .none
        t.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, title, w) in [("name", "Název", 260.0), ("ext", "Přípona", 60.0), ("size", "Velikost", 90.0),
                               ("date", "Datum", 118.0), ("attr", "Atributy", 86.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.headerCell = ThemedHeaderCell(textCell: title)
            c.title = title
            c.width = w
            c.minWidth = id == "name" ? 120 : 40
            if id == "size" { c.headerCell.alignment = .right }
            t.addTableColumn(c)
        }
        t.dataSource = context.coordinator
        t.delegate = context.coordinator
        t.target = context.coordinator
        t.doubleAction = #selector(Coordinator.doubleClick)
        t.registerForDraggedTypes([.fileURL])
        t.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        t.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        t.menu = context.coordinator.contextMenu()
        t.keyHandler = { [weak coord = context.coordinator] e in coord?.key(e) ?? false }
        t.onFocus = { [weak coord = context.coordinator] in coord.map { c in c.commander.activate(c.side) } }
        context.coordinator.table = t
        commander.tables[side] = t

        let s = NSScrollView()
        s.documentView = t
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = false
        s.autohidesScrollers = true
        s.drawsBackground = true
        s.backgroundColor = UI.NS.list
        t.backgroundColor = UI.NS.list
        return s
    }

    func updateNSView(_ s: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let t = c.table else { return }
        commander.tables[side] = t
        t.backgroundColor = UI.NS.list
        s.backgroundColor = UI.NS.list
        t.rowHeight = CGFloat(fontSize) + 7
        updateHeaders(t)
        if c.shownTab != tab.id || c.shownVersion != tab.version || c.shownTheme != ThemeStore.ui.id {
            let sameList = c.shownTab == tab.id && c.shownTheme == ThemeStore.ui.id && t.numberOfRows == tab.items.count
            c.shownTab = tab.id
            c.shownVersion = tab.version
            c.shownTheme = ThemeStore.ui.id
            // reloadData při allowsEmptySelection = false umí na okamžik vybrat 1. řádek → kurzor by skočil nahoru.
            // Při označení (stejný počet řádků) stačí překreslit obsah řádků – výběr i posun zůstanou.
            c.reloading = true
            if sameList, t.numberOfRows > 0 {
                t.reloadData(forRowIndexes: IndexSet(integersIn: 0..<t.numberOfRows), columnIndexes: IndexSet(integersIn: 0..<t.numberOfColumns))
            } else {
                t.reloadData()
            }
            c.reloading = false
        }
        if tab.items.indices.contains(tab.cursor), t.selectedRow != tab.cursor {
            t.selectRowIndexes(IndexSet(integer: tab.cursor), byExtendingSelection: false)
            t.scrollRowToVisible(tab.cursor)
        }
        t.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }     // aktivní/neaktivní kurzor
    }

    private func updateHeaders(_ t: NSTableView) {
        let arrow = tab.ascending ? " ▲" : " ▼"
        for c in t.tableColumns {
            let base = ["name": "Název", "ext": "Přípona", "size": "Velikost", "date": "Datum", "attr": "Atributy"][c.identifier.rawValue] ?? ""
            let key: SortKey? = ["name": .name, "ext": .ext, "size": .size, "date": .date][c.identifier.rawValue]
            c.title = base + (key == tab.sortKey ? arrow : "")
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileTable
        weak var table: FileTableNSView?
        var shownTab: UUID?
        var shownVersion = -1
        var shownTheme = ""
        var reloading = false
        private var typed = ""
        private var typedAt = Date.distantPast

        init(_ p: FileTable) { parent = p }
        var tab: PanelTab { parent.tab }
        var commander: Commander { parent.commander }
        var side: Side { parent.side }

        func numberOfRows(in tableView: NSTableView) -> Int { tab.items.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rv = FileRowView()
            rv.activePanel = { [weak self] in
                guard let self else { return false }
                return self.commander.activeSide == self.side && self.table?.window?.firstResponder === self.table
            }
            return rv
        }

        func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let col, tab.items.indices.contains(row) else { return nil }
            let item = tab.items[row]
            let id = col.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FileCell) ?? FileCell(id: id)
            let marked = tab.marked.contains(item.url)
            let color: NSColor = marked ? UI.NS.marked
                : item.isParent || item.isDir ? UI.NS.dir
                : item.isHidden ? UI.NS.hidden
                : item.isArchive ? UI.NS.archive
                : item.isExecutable ? UI.NS.exec : UI.NS.text
            let font = NSFont.systemFont(ofSize: CGFloat(parent.fontSize), weight: marked ? .semibold : .regular)
            let mono = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(parent.fontSize) - 0.5, weight: .regular)
            switch id.rawValue {
            case "name":
                let n = item.isParent ? "[..]" : item.isDir ? "[\(item.name)]" : item.baseName
                cell.set(n, color: color, font: font, icon: item.isParent ? nil : icon(item))
            case "ext": cell.set(item.ext, color: color, font: font)
            case "size":
                let s = item.isDir ? tab.dirSizes[item.url].map { Fmt.bytes($0) } : nil
                cell.set(s ?? Fmt.column(item), color: color, font: mono, align: .right)
            case "date": cell.set(item.isParent ? "" : Fmt.date.string(from: item.modified), color: marked ? color : UI.NS.textDim, font: mono)
            default: cell.set(item.perms, color: marked ? color : UI.NS.textDim, font: mono)
            }
            return cell
        }

        private func icon(_ i: FileItem) -> NSImage {
            let img: NSImage
            if i.archiveInner != nil || i.remotePath != nil {               // v archivu / na serveru soubor na disku není
                img = i.isDir ? NSWorkspace.shared.icon(for: .folder)
                    : NSWorkspace.shared.icon(for: UTType(filenameExtension: i.ext) ?? .data)
            } else {
                img = NSWorkspace.shared.icon(forFile: i.url.path)
            }
            img.size = NSSize(width: 16, height: 16)
            return img
        }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard !reloading, let t = table, t.selectedRow >= 0, t.selectedRow != tab.cursor else { return }
            tab.cursor = t.selectedRow
        }

        func tableView(_ tableView: NSTableView, didClick col: NSTableColumn) {
            let key: SortKey? = ["name": .name, "ext": .ext, "size": .size, "date": .date][col.identifier.rawValue]
            if let key { tab.setSort(key) }
        }

        @objc func doubleClick() {
            guard let t = table, t.clickedRow >= 0, tab.items.indices.contains(t.clickedRow) else { return }
            tab.cursor = t.clickedRow
            tab.open(tab.items[t.clickedRow])
        }

        // MARK: Klávesnice (TC)

        func key(_ e: NSEvent) -> Bool {
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let code = e.keyCode
            if tab.showThumbs, mods.isEmpty {                                                    // mřížka náhledů
                let cols = max(1, tab.gridColumns)
                switch code {
                case 123: move(-1); return true                                                  // ←
                case 124: move(1); return true                                                   // →
                case 125: move(cols); return true                                                // ↓
                case 126: move(-cols); return true                                               // ↑
                default: break
                }
            }
            switch (code, mods) {
            case (48, []): commander.switchPanel(); return true                                  // Tab
            case (36, []), (76, []), (125, [.command]):                                          // Enter, ⌘↓
                if let i = tab.current { tab.open(i) }; return true
            case (51, []), (126, [.command]): tab.up(); return true                              // ⌫, ⌘↑
            case (49, []):                                                                       // mezerník = označit
                if let i = tab.current, i.isDir { tab.computeSize(i) }                          // jako v TC: složka + velikost
                tab.toggleMark(tab.cursor); move(1); return true
            case (99, []): commander.view(); return true                                         // F3
            case (118, []): commander.edit(); return true                                        // F4
            case (96, []): commander.transfer(move: false); return true                          // F5
            case (97, []): commander.transfer(move: true); return true                           // F6
            case (97, [.shift]), (120, []): commander.rename(); return true                      // ⇧F6, F2
            case (98, []): commander.mkdir(); return true                                        // F7
            case (98, [.option]): commander.search(); return true                                // Alt+F7 hledání
            case (100, []): commander.delete(); return true                                      // F8
            case (100, [.shift]): commander.delete(permanent: true); return true                 // ⇧F8
            case (53, []):                                                                       // Esc
                if !typed.isEmpty { typed = "" } else { tab.unmarkAll() }; return true
            case (116, []): move(-pageRows); return true                                         // PgUp
            case (121, []): move(pageRows); return true                                          // PgDn
            case (115, []): setCursor(0); return true                                            // Home
            case (119, []): setCursor(tab.items.count - 1); return true                          // End
            case (123, [.command]): commander.panel(.left).tab.go(tab.dir); return true          // ⌘← druhý panel sem
            case (124, [.command]): commander.panel(.right).tab.go(tab.dir); return true
            case (123, [.option]), (33, [.command]): tab.goBack(); return true                   // ⌥← / ⌘[ zpět
            case (124, [.option]), (30, [.command]): tab.goForward(); return true
            default: break
            }
            // numerická klávesnice jako v TC: + označit maskou, - odznačit, * obrátit
            // (bez numerické klávesnice: ⌥⌘= / ⌥⌘- / ⌥⌘8 v menu Výběr)
            if mods.isEmpty {
                switch code {
                case 69: commander.markByMask(add: true); return true
                case 78: commander.markByMask(add: false); return true
                case 67: tab.invertMarks(); return true
                default: break
                }
            }
            // rychlé hledání psaním (jako ⌃⌥ v TC – na Macu stačí psát)
            if mods.isEmpty || mods == [.shift], let ch = e.characters, ch.count == 1,
               let s = ch.unicodeScalars.first, CharacterSet.alphanumerics.union(.punctuationCharacters).contains(s) {
                if Date().timeIntervalSince(typedAt) > 1.0 { typed = "" }
                typed += ch.lowercased(); typedAt = Date()
                if let i = tab.items.firstIndex(where: { !$0.isParent && $0.name.lowercased().hasPrefix(typed) }) { setCursor(i) }
                else { NSSound.beep() }
                return true
            }
            return false
        }

        private var pageRows: Int {
            guard let t = table, let sv = t.enclosingScrollView else { return 20 }
            return max(1, Int(sv.contentView.bounds.height / max(1, t.rowHeight)) - 1)
        }

        private func move(_ d: Int) { setCursor(tab.cursor + d) }

        private func setCursor(_ i: Int) {
            guard !tab.items.isEmpty, let t = table else { return }
            let r = min(max(0, i), tab.items.count - 1)
            tab.cursor = r
            t.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            t.scrollRowToVisible(r)
            t.reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet(integersIn: 0..<t.numberOfColumns))
        }

        // MARK: Kontextové menu

        func contextMenu() -> NSMenu {
            let m = NSMenu()
            func add(_ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
                let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
                it.keyEquivalentModifierMask = mods
                it.target = self
                m.addItem(it)
            }
            add("Otevřít", #selector(mOpen))
            add("Zobrazit (Quick Look)", #selector(mView))
            add("Upravit", #selector(mEdit))
            add("Otevřít výchozí aplikací", #selector(mOpenExt))
            m.addItem(.separator())
            add("Kopírovat do druhého panelu…", #selector(mCopy))
            add("Přesunout do druhého panelu…", #selector(mMove))
            add("Přejmenovat…", #selector(mRename))
            add("Přesunout do Koše", #selector(mDelete))
            m.addItem(.separator())
            add("Zabalit do druhého panelu…", #selector(mPack))
            add("Rozbalit do druhého panelu…", #selector(mUnpack))
            add("Kontrolní součty (MD5, SHA)…", #selector(mHash))
            m.addItem(.separator())
            add("Hromadné přejmenování…", #selector(mMulti))
            add("Porovnat soubory (diff)…", #selector(mDiff))
            add("Synchronizovat složky…", #selector(mSync))
            add("Spočítat velikost složky", #selector(mSize))
            m.addItem(.separator())
            add("Zobrazit ve Finderu", #selector(mReveal))
            add("Kopírovat cestu", #selector(mCopyPath))
            add("Otevřít Terminál zde", #selector(mTerminal))
            return m
        }

        /// Pravé tlačítko: kurzor na řádek pod myší.
        private func focusClicked() {
            commander.focus(side)
            if let t = table, t.clickedRow >= 0 { setCursor(t.clickedRow) }
        }
        @objc func mOpen() { focusClicked(); if let i = tab.current { tab.open(i) } }
        @objc func mView() { focusClicked(); commander.view() }
        @objc func mOpenExt() { focusClicked(); commander.openExternally() }
        @objc func mPack() { focusClicked(); commander.pack() }
        @objc func mHash() { focusClicked(); commander.checksums() }
        @objc func mMulti() { focusClicked(); commander.multiRename() }
        @objc func mDiff() { focusClicked(); commander.diffFiles() }
        @objc func mSync() { focusClicked(); commander.syncDirs() }
        @objc func mSize() {
            focusClicked()
            let sel = tab.items.filter { tab.marked.contains($0.url) && $0.isDir }
            if sel.isEmpty, let c = tab.current { tab.computeSize(c) } else { tab.computeSizes(sel) }
        }
        @objc func mUnpack() { focusClicked(); commander.unpack() }
        @objc func mEdit() { focusClicked(); commander.edit() }
        @objc func mCopy() { focusClicked(); commander.transfer(move: false) }
        @objc func mMove() { focusClicked(); commander.transfer(move: true) }
        @objc func mRename() { focusClicked(); commander.rename() }
        @objc func mDelete() { focusClicked(); commander.delete() }
        @objc func mReveal() { focusClicked(); commander.revealInFinder() }
        @objc func mCopyPath() { focusClicked(); commander.copyPaths() }
        @objc func mTerminal() { focusClicked(); commander.openTerminalHere() }

        // MARK: Drag & drop (Finder i druhý panel)

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard tab.items.indices.contains(row), !tab.items[row].isParent, tab.items[row].archiveInner == nil, tab.items[row].remotePath == nil else { return nil }
            return tab.items[row].url as NSURL
        }

        /// Tažení označeného souboru vezme všechny označené (mezerník / Insert), ne jen řádek pod myší.
        /// Tabulka má jednořádkový výběr, proto se při začátku tažení přepíše obsah schránky tažení.
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let row = rowIndexes.first, tab.items.indices.contains(row),
                  tab.marked.contains(tab.items[row].url) else { return }
            let urls = tab.items.filter { tab.marked.contains($0.url) && !$0.isParent && $0.archiveInner == nil && $0.remotePath == nil }
                .map { $0.url as NSURL }
            guard urls.count > 1 else { return }
            let pb = session.draggingPasteboard
            pb.clearContents()
            pb.writeObjects(urls)
            session.draggingFormation = .pile
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            tableView.setDropRow(-1, dropOperation: .on)                 // vždy do aktuální složky panelu
            return NSEvent.modifierFlags.contains(.command) ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            if tab.archive != nil { commander.dropIntoArchive(tab, urls); return true }
            let move = NSEvent.modifierFlags.contains(.command)
            if tab.remote != nil { commander.upload(urls, to: tab, move: move); return true }
            let dir = tab.dir
            let srcs = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL }
            guard !srcs.isEmpty else { return false }
            commander.dropTransfer(srcs, to: dir, move: move)
            return true
        }
    }
}

/// Buňka tabulky (ikona + text).
final class FileCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let img = NSImageView()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.lineBreakMode = .byTruncatingMiddle
        // zkrácený text (název, cesta…) se po najetí myší ukáže celý v bublině – jen když se nevejde
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false
        img.translatesAutoresizingMaskIntoConstraints = false
        addSubview(img); addSubview(label)
        textField = label; imageView = img
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            img.centerYAnchor.constraint(equalTo: centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16), img.heightAnchor.constraint(equalToConstant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        leadingWithIcon = label.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 5)
        leadingPlain = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
    }
    required init?(coder: NSCoder) { nil }

    private var leadingWithIcon: NSLayoutConstraint!
    private var leadingPlain: NSLayoutConstraint!

    func set(_ text: String, color: NSColor, font: NSFont, icon: NSImage? = nil, align: NSTextAlignment = .left) {
        label.stringValue = text
        label.textColor = color
        label.font = font
        label.alignment = align
        img.image = icon
        img.isHidden = icon == nil
        leadingWithIcon.isActive = icon != nil
        leadingPlain.isActive = icon == nil
    }
}

// MARK: - Záhlaví tabulky v barvách profilu (místo systémové šedé)

/// Plocha záhlaví za sloupci.
final class ThemedHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        UI.NS.headerBG.setFill(); dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

/// Buňka záhlaví: podklad, oddělovače a text podle profilu (u světlé plochy světlé záhlaví s tmavým textem).
final class ThemedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame f: NSRect, in v: NSView) {
        UI.NS.headerBG.setFill(); f.fill()
        UI.NS.headerLine.setFill()
        NSRect(x: f.maxX - 1, y: f.minY + 5, width: 1, height: max(0, f.height - 10)).fill()
        NSRect(x: f.minX, y: v.isFlipped ? f.maxY - 1 : f.minY, width: f.width, height: 1).fill()
        let p = NSMutableParagraphStyle(); p.alignment = alignment; p.lineBreakMode = .byTruncatingTail
        let s = NSAttributedString(string: stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: UI.NS.headerText, .paragraphStyle: p])
        let h = s.size().height
        s.draw(in: NSRect(x: f.minX + 5, y: f.midY - h / 2, width: f.width - 12, height: h))
    }
    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {}
}
