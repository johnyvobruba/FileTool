import Foundation
import AppKit
import Darwin

// Operace s panelem připojeným k serveru (SFTP / SCP / FTP): F3/F4/Enter, F5/F6, F7, F8, ⇧F6.
extension Commander {

    // MARK: Připojení

    /// ⌘K – dialog s uloženými servery; připojí aktivní záložku.
    func connectDialog() {
        let side = activeSide
        ConnectWindow.show { [weak self] cfg in
            guard let self else { return }
            self.panel(side).tab.connect(cfg)
            self.focus(side)
        }
    }

    func disconnect() {
        guard tab.remote != nil else { NSSound.beep(); return }
        tab.disconnectRemote()
        tab.go(tab.dir, record: false)
    }

    // MARK: Spuštění dávky s možností zrušení

    /// Jeden příkaz na položku – mezi nimi se kontroluje Zrušit; běžící přenos se ukončí (SIGTERM).
    private func runEach(_ s: RemoteSession, _ op: FileOperation, _ steps: [(String, [String])]) async -> [String] {
        var errs: [String] = []
        let pid = Box<Int32>(0)
        let cancel = op.cancel
        let watchdog = Task.detached {
            while !Task.isCancelled {
                if cancel.value, pid.value > 0 { kill(pid.value, SIGTERM) }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        for (i, st) in steps.enumerated() {
            let (label, cmds) = st
            if cancel.value { errs.append("Zrušeno."); break }
            op.current = label
            op.progress.value = (Int64(i), label)
            let r = await s.run(cmds, pid: pid)
            pid.value = 0
            if !r.ok { errs.append("\(label): \(RemoteSession.cleanErr(r.err))") }
        }
        watchdog.cancel()
        return errs
    }

    // MARK: Stažení do dočasné složky (F3, F4, Enter)

    func downloadToTemp(_ t: PanelTab, _ items: [FileItem], then: @escaping ([URL]) -> Void) {
        guard let r = t.remote else { return }
        let dir = ArchiveIO.viewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = items.filter { !$0.isDir && $0.remotePath != nil }
        let op = FileOperation(kind: .copy, title: "Stahování z \(r.session.config.title)")
        op.total = Int64(files.count)
        start(op)
        Task {
            let steps: [(String, [String])] = files.map { f in (f.name, ["get -p " + RemotePath.q(f.remotePath!) + " " + RemotePath.q(dir.appendingPathComponent(f.name).path)]) }
            let errs = await runEach(r.session, op, steps)
            let urls = files.map { dir.appendingPathComponent($0.name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            RemoteDownload.quarantine(urls, from: r.session.label)
            finish(op, errs, refresh: false)
            then(urls)
        }
    }

    func openFromRemote(_ t: PanelTab, _ items: [FileItem]) {
        downloadToTemp(t, items) { urls in for u in urls { NSWorkspace.shared.open(u) } }
    }

    /// F4 na serveru: stáhnout, otevřít v editoru a po uložení nabídnout nahrání zpět.
    func editRemote(_ t: PanelTab, _ item: FileItem) {
        guard let r = t.remote, let rp = item.remotePath else { return }
        downloadToTemp(t, [item]) { [weak self] urls in
            guard let self, let u = urls.first else { return }
            let before = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date
            self.openInEditor(u)
            let a = NSAlert()
            a.messageText = "Upravuješ kopii „\(item.name)“ ze serveru"
            a.informativeText = "Až soubor v editoru uložíš, klikni na Nahrát zpět – přepíše \(rp) na \(r.session.config.title)."
            a.addButton(withTitle: "Nahrát zpět"); a.addButton(withTitle: "Zahodit změny")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            let after = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date
            if before == after, !self.confirm("Soubor se od stažení nezměnil (neuložil jsi ho?). Přesto nahrát?") { return }
            let op = FileOperation(kind: .copy, title: "Nahrávání \(item.name)")
            self.start(op)
            Task {
                let errs = await self.runEach(r.session, op, [(item.name, ["put -p " + RemotePath.q(u.path) + " " + RemotePath.q(rp)])])
                self.finish(op, errs)
            }
        }
    }

    // MARK: F5 / F6

    /// Kopírování / přesun se serverem na jedné straně. true = obslouženo.
    func remoteTransfer(move: Bool) -> Bool {
        let src = tab, dst = other.tab
        guard src.remote != nil || dst.remote != nil else { return false }
        if src.remote != nil && dst.remote != nil { alert("Přenos mezi dvěma servery", "Zkopíruj soubory nejdřív do místní složky."); return true }
        if src.archive != nil || dst.archive != nil { alert("Přenos archiv ↔ server", "Rozbal soubory nejdřív do místní složky."); return true }
        let items = src.selection
        guard !items.isEmpty else { NSSound.beep(); return true }
        if src.remote != nil { download(items, from: src, to: dst.dir, move: move) }
        else { upload(items.map(\.url), to: dst, move: move) }
        return true
    }

    private func conflictPolicy(_ names: [String]) -> Bool? {
        guard !names.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = "\(names.count == 1 ? "Položka už" : "\(names.count) položek už") v cíli existuje"
        a.informativeText = names.prefix(12).joined(separator: "\n") + (names.count > 12 ? "\n…" : "")
        a.addButton(withTitle: "Přepsat"); a.addButton(withTitle: "Přeskočit existující"); a.addButton(withTitle: "Zrušit")
        switch a.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    func download(_ items: [FileItem], from t: PanelTab, to dir: URL, move: Bool) {
        guard let r = t.remote else { return }
        let what = items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek"
        guard confirm("\(move ? "Přesunout" : "Stáhnout") \(what) ze \(r.session.config.title) do \(dir.path)?"
                      + (move ? "\n\nPo stažení se položky na serveru smažou." : "")) else { return }
        let clashes = items.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.name).path) }.map(\.name)
        guard let overwrite = conflictPolicy(clashes) else { return }
        let todo = overwrite ? items : items.filter { !clashes.contains($0.name) }
        let op = FileOperation(kind: move ? .move : .copy, title: (move ? "Přesun ze " : "Stahování ze ") + r.session.config.title)
        op.total = Int64(todo.count)
        start(op)
        Task {
            let steps: [(String, [String])] = todo.map { i in (i.name, [(i.isDir ? "get -r -p " : "get -p ") + RemotePath.q(i.remotePath!) + " "
                                                   + RemotePath.q(dir.appendingPathComponent(i.name).path)]) }
            var errs = await runEach(r.session, op, steps)
            let got = todo.map { dir.appendingPathComponent($0.name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            RemoteDownload.quarantine(got, from: r.session.label)
            if move, errs.isEmpty { errs += await removeRemote(r.session, todo, op) }
            finish(op, errs)
        }
    }

    func upload(_ srcs: [URL], to t: PanelTab, move: Bool) {
        guard let r = t.remote else { return }
        let what = srcs.count == 1 ? "„\(srcs[0].lastPathComponent)“" : "\(srcs.count) položek"
        guard confirm("\(move ? "Přesunout" : "Nahrát") \(what) na \(r.session.config.title):\(r.path)?"
                      + (move ? "\n\nPo nahrání se místní položky přesunou do Koše." : "")) else { return }
        let existing = Set(t.items.map(\.name))
        let clashes = srcs.map(\.lastPathComponent).filter { existing.contains($0) }
        guard let overwrite = conflictPolicy(clashes) else { return }
        let todo = overwrite ? srcs : srcs.filter { !clashes.contains($0.lastPathComponent) }
        let op = FileOperation(kind: move ? .move : .copy, title: (move ? "Přesun na " : "Nahrávání na ") + r.session.config.title)
        op.total = Int64(todo.count)
        start(op)
        Task {
            let steps: [(String, [String])] = todo.map { u -> (String, [String]) in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                return (u.lastPathComponent, [(isDir.boolValue ? "put -r -p " : "put -p ") + RemotePath.q(u.path) + " "
                                              + RemotePath.q(RemotePath.join(r.path, u.lastPathComponent))])
            }
            var errs = await runEach(r.session, op, steps)
            if move, errs.isEmpty {
                let cancel = op.cancel, progress = op.progress
                errs += await Task.detached { FileOps.delete(todo, trash: true, cancel: cancel, progress: progress) }.value
            }
            finish(op, errs)
        }
    }

    // MARK: F7 / F8 / ⇧F6

    func remoteMkdir() {
        guard let r = tab.remote else { return }
        guard let n = askText("Nová složka", info: "na \(r.session.config.title):\(r.path)", initial: "", button: "Vytvořit"),
              !n.isEmpty, !n.contains("/") else { return }
        let t = tab
        Task {
            let res = await r.session.run(["mkdir " + RemotePath.q(RemotePath.join(r.path, n))])
            if res.ok { t.load(select: n) } else { alert("Složku nelze vytvořit", RemoteSession.cleanErr(res.err)) }
        }
    }

    func remoteRename(_ i: FileItem) {
        guard let r = tab.remote, let rp = i.remotePath else { return }
        guard let n = askText("Přejmenovat", info: i.name, initial: i.name, button: "Přejmenovat", selectBase: !i.isDir),
              !n.isEmpty, n != i.name, !n.contains("/") else { return }
        if tab.items.contains(where: { $0.name == n }) { alert("„\(n)“ už existuje", ""); return }
        let t = tab
        Task {
            let res = await r.session.run(["rename " + RemotePath.q(rp) + " " + RemotePath.q(RemotePath.join(r.path, n))])
            if res.ok { t.load(select: n) } else { alert("Nelze přejmenovat", RemoteSession.cleanErr(res.err)) }
        }
    }

    func remoteDelete(_ items: [FileItem]) {
        guard let r = tab.remote else { return }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "TRVALE smazat na \(r.session.config.title) " + (items.count == 1 ? "„\(items[0].name)“?" : "\(items.count) položek?")
        a.informativeText = items.prefix(12).map { ($0.isDir ? "📁 " : "") + $0.name }.joined(separator: "\n")
            + (items.count > 12 ? "\n…" : "") + "\n\nNa serveru není Koš – smazání nelze vrátit. Složky se mažou i s obsahem."
        a.addButton(withTitle: "Smazat trvale"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let op = FileOperation(kind: .delete, title: "Mazání na \(r.session.config.title)")
        op.total = Int64(items.count)
        start(op)
        Task {
            let errs = await removeRemote(r.session, items, op)
            finish(op, errs)
        }
    }

    /// Smaže položky na serveru; složky rekurzivně (sftp ani FTP neumí rm -r) – odkazy se nenásledují.
    private func removeRemote(_ s: RemoteSession, _ items: [FileItem], _ op: FileOperation) async -> [String] {
        var errs: [String] = []
        let base = URL(fileURLWithPath: "/.filetool-remote/del")
        func remove(_ path: String, isDir: Bool, depth: Int) async {
            if op.cancel.value { return }
            op.current = (path as NSString).lastPathComponent
            if isDir && depth < 64 {
                do {
                    for c in try await s.list(path, base: base) {
                        await remove(c.remotePath ?? RemotePath.join(path, c.name), isDir: c.isDir && !c.isLink, depth: depth + 1)
                    }
                } catch let err { errs.append("\(path): \(err.localizedDescription)"); return }
            }
            let r = await s.run([(isDir ? "rmdir " : "rm ") + RemotePath.q(path)])
            if !r.ok { errs.append("\(path): \(RemoteSession.cleanErr(r.err))") }
        }
        for (n, i) in items.enumerated() {
            guard let p = i.remotePath, !i.isParent, p != "/" else { continue }
            await remove(p, isDir: i.isDir && !i.isLink, depth: 0)
            op.progress.value = (Int64(n + 1), i.name)
        }
        return errs
    }
}

enum RemoteDownload {
    /// Soubory ze serveru dostanou karanténu (Gatekeeper je před spuštěním zkontroluje).
    static func quarantine(_ urls: [URL], from source: String) {
        let value = String(format: "0083;%08x;FileTool;", Int(Date().timeIntervalSince1970))
        for root in urls {
            var paths = [root.path]
            if let e = FileManager.default.enumerator(atPath: root.path) { for case let r as String in e { paths.append(root.path + "/" + r) } }
            for p in paths { _ = setxattr(p, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW) }
        }
    }
}
