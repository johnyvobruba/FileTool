import AppKit

/// Volby balení (⌥⌘5).
struct PackOptions {
    var format = "zip"            // zip | 7z | tar.gz | tar.bz2 | tar.xz
    var level = 5                 // 0 = jen uložit … 9 = ultra
    var password = ""
    var zipCrypto = false         // ZIP: ZipCrypto místo AES-256 (kompatibilita se starými rozbalovači)
    var encryptNames = true       // 7z: šifrovat i názvy souborů
    var volume: String? = nil     // velikost části, např. "100m" (nil = nerozdělovat)
    var trashSources = false      // po úspěšném zabalení zdroje do Koše
}

/// Dialog balení: název, formát, cílová složka (lze upravit), úroveň komprese, rozdělení na části,
/// heslo s okem pro zobrazení, metoda šifrování. Poslední volby si pamatuje (kromě hesla).
@MainActor
final class PackDialog: NSObject {
    private let name = NSTextField()
    private let fmt = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dest = NSTextField()
    private let level = NSPopUpButton(frame: .zero, pullsDown: false)
    private let split = NSPopUpButton(frame: .zero, pullsDown: false)
    private let splitCustom = NSTextField()
    private let pw1 = RevealPasswordField(width: 300, placeholder: "Heslo (nepovinné)")
    private let pw2 = RevealPasswordField(width: 300, placeholder: "Heslo znovu")
    private let match = NSTextField(labelWithString: "")
    private let method = NSPopUpButton(frame: .zero, pullsDown: false)
    private let encNames = NSButton(checkboxWithTitle: "Šifrovat i názvy souborů", target: nil, action: nil)
    private let trash = NSButton(checkboxWithTitle: "Po zabalení přesunout zdrojové soubory do Koše", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let d = UserDefaults.standard

    static let levels: [(String, Int)] = [("Bez komprese (jen uložit)", 0), ("Nejrychlejší", 1), ("Rychlá", 3),
                                          ("Normální", 5), ("Maximální", 7), ("Ultra (nejmenší, nejpomalejší)", 9)]
    static let splits: [(String, String?)] = [("Nerozdělovat", nil), ("10 MB", "10m"), ("100 MB", "100m"), ("700 MB (CD)", "700m"),
                                              ("1 GB", "1g"), ("2 GB", "2g"), ("4 GB (FAT32)", "4095m"), ("4,7 GB (DVD)", "4480m"),
                                              ("Vlastní…", "custom")]
    private var has7z: Bool { SevenZip.path != nil }

    /// Vrátí (cílový soubor, volby) nebo nil (zrušeno).
    func run(title: String, defName: String, defDest: URL) -> (URL, PackOptions)? {
        build(defName: defName, defDest: defDest)
        let a = NSAlert()
        a.messageText = title
        a.accessoryView = grid()
        a.addButton(withTitle: "Zabalit"); a.addButton(withTitle: "Zrušit")
        a.window.initialFirstResponder = name
        while true {
            guard a.runModal() == .alertFirstButtonReturn else { return nil }
            switch validate() {
            case .success(let r): save(r.1); return r
            case .failure(let e):
                let w = NSAlert(); w.alertStyle = .warning; w.messageText = e.title; w.informativeText = e.text; w.runModal()
            }
        }
    }

    // MARK: Sestavení

    private func build(defName: String, defDest: URL) {
        name.stringValue = defName
        fmt.addItems(withTitles: has7z ? ["zip", "7z", "tar.gz", "tar.bz2", "tar.xz"] : ["zip", "tar.gz", "tar.bz2", "tar.xz"])
        fmt.selectItem(withTitle: d.string(forKey: "pack.format") ?? "zip")
        if fmt.indexOfSelectedItem < 0 { fmt.selectItem(at: 0) }
        dest.stringValue = (defDest.path as NSString).abbreviatingWithTildeInPath
        dest.lineBreakMode = .byTruncatingHead
        dest.cell?.isScrollable = true
        dest.toolTip = "Cílová složka – lze přepsat nebo vybrat"
        level.addItems(withTitles: Self.levels.map(\.0))
        let lv = d.object(forKey: "pack.level") as? Int ?? 5
        level.selectItem(at: Self.levels.firstIndex { $0.1 == lv } ?? 3)
        split.addItems(withTitles: Self.splits.map(\.0))
        splitCustom.placeholderString = "např. 250M, 1,5G"
        splitCustom.toolTip = "Velikost jedné části: číslo a jednotka K, M nebo G"
        encNames.state = (d.object(forKey: "pack.encNames") as? Bool ?? true) ? .on : .off
        trash.state = .off
        pw1.partner = pw2; pw2.partner = pw1
        pw1.onChange = { [weak self] in self?.updateMatch() }
        pw2.onChange = { [weak self] in self?.updateMatch() }
        match.font = .systemFont(ofSize: 11)
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        for p in [fmt, split, method] { p.target = self; p.action = #selector(update) }
        update()
    }

    private func grid() -> NSView {
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        func row(_ v: [NSView]) -> NSStackView { let s = NSStackView(views: v); s.orientation = .horizontal; s.spacing = 8; return s }
        let choose = NSButton(title: "Vybrat…", target: self, action: #selector(chooseDest))
        for (v, w) in [(name, 250.0), (dest, 300.0), (splitCustom, 120.0)] as [(NSView, CGFloat)] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: w).isActive = true
        }
        note.preferredMaxLayoutWidth = 400
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 400).isActive = true
        note.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let empty = NSGridCell.emptyContentView
        let g = NSGridView(views: [
            [label("Název:"), row([name, fmt])],
            [label("Uložit do:"), row([dest, choose])],
            [label("Komprese:"), level],
            [label("Rozdělit:"), row([split, splitCustom])],
            [label("Heslo:"), pw1],
            [label("Znovu:"), row([pw2, match])],
            [label("Šifrování:"), method],
            [empty, encNames],
            [empty, trash],
            [empty, note],
        ])
        g.rowSpacing = 8; g.columnSpacing = 8
        g.column(at: 0).xPlacement = .trailing
        g.yPlacement = .center
        g.layoutSubtreeIfNeeded()
        g.frame = NSRect(origin: .zero, size: g.fittingSize)
        return g
    }

    // MARK: Chování

    @objc private func update() {
        let f = fmt.titleOfSelectedItem ?? "zip"
        let tar = f.hasPrefix("tar")
        splitCustom.isHidden = Self.splits[max(0, split.indexOfSelectedItem)].1 != "custom"
        pw1.isEnabled = !tar; pw2.isEnabled = !tar
        // metoda šifrování podle formátu a dostupnosti 7-Zip
        let prev = method.titleOfSelectedItem
        method.removeAllItems()
        switch f {
        case "zip" where has7z: method.addItems(withTitles: ["AES-256 (doporučeno)", "ZipCrypto (kompatibilní, slabé)"])
        case "zip": method.addItems(withTitles: ["ZipCrypto (macOS zip, slabé)"])
        case "7z": method.addItems(withTitles: ["AES-256"])
        default: method.addItems(withTitles: ["– (tar heslo neumí)"])
        }
        if let prev, method.itemTitles.contains(prev) { method.selectItem(withTitle: prev) }
        else if f == "zip", has7z, d.bool(forKey: "pack.zipCrypto") { method.selectItem(at: 1) }
        method.isEnabled = method.numberOfItems > 1
        encNames.isEnabled = f == "7z"
        updateMatch()

        var t: [String] = []
        if tar {
            t.append("tar neumí heslo.")
            if split.indexOfSelectedItem > 0 { t.append("Části vzniknou příkazem split (název.\(f).aa, .ab…); spojení: cat název.\(f).* > název.\(f).") }
        } else if f == "zip" && !has7z {
            t.append("Bez 7-Zip: macOS zip, šifrování jen ZipCrypto (slabé). Pro AES-256: brew install sevenzip.")
            if split.indexOfSelectedItem > 0 { t.append("Části: název.z01, .z02… + název.zip (všechny musí být pohromadě).") }
        } else {
            if f == "zip", method.indexOfSelectedItem == 0 {
                t.append("AES-256 ZIP rozbalí 7-Zip, Keka, The Unarchiver i WinRAR; starší vestavěné rozbalování (Windows, Archivační nástroj) ho nemusí otevřít.")
            }
            if f == "7z" { t.append("7z s heslem: AES-256, s volbou výše jsou skryté i názvy souborů.") }
            if split.indexOfSelectedItem > 0 { t.append("Části: název.\(f).001, .002… (7-Zip).") }
        }
        note.stringValue = t.joined(separator: " ")
    }

    private func updateMatch() {
        let a = pw1.stringValue, b = pw2.stringValue
        if a.isEmpty && b.isEmpty { match.stringValue = "" }
        else if a == b { match.stringValue = "✓ shodují se"; match.textColor = .systemGreen }
        else { match.stringValue = b.isEmpty ? "" : "✗ neshodují se"; match.textColor = .systemRed }
    }

    @objc private func chooseDest() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Vybrat"
        p.directoryURL = URL(fileURLWithPath: (dest.stringValue as NSString).expandingTildeInPath)
        if p.runModal() == .OK, let u = p.url { dest.stringValue = (u.path as NSString).abbreviatingWithTildeInPath }
    }

    // MARK: Kontrola

    struct Problem: Error { let title: String; let text: String }

    private func validate() -> Result<(URL, PackOptions), Problem> {
        var o = PackOptions()
        o.format = fmt.titleOfSelectedItem ?? "zip"
        var n = name.stringValue.trimmingCharacters(in: .whitespaces)
        if n.lowercased().hasSuffix("." + o.format) { n = String(n.dropLast(o.format.count + 1)) }   // přípona napsaná ručně
        guard !n.isEmpty, !n.contains("/"), !n.hasPrefix(".") else {
            return .failure(Problem(title: "Neplatný název", text: "Zadej název archivu bez lomítka a bez tečky na začátku."))
        }
        let dirPath = (dest.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard dirPath.hasPrefix("/"), FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
            return .failure(Problem(title: "Cílová složka neexistuje", text: dest.stringValue))
        }
        guard FileManager.default.isWritableFile(atPath: dirPath) else {
            return .failure(Problem(title: "Do cílové složky nelze zapisovat", text: dirPath))
        }
        o.level = Self.levels[max(0, level.indexOfSelectedItem)].1
        let sv = Self.splits[max(0, split.indexOfSelectedItem)].1
        if sv == "custom" {
            guard let v = Self.parseSize(splitCustom.stringValue) else {
                return .failure(Problem(title: "Neplatná velikost části", text: "Zadej např. 250M, 700M nebo 1,5G (nejméně 64K)."))
            }
            o.volume = v
        } else { o.volume = sv }
        o.password = pw1.stringValue
        if !o.password.isEmpty {
            guard o.password == pw2.stringValue else { return .failure(Problem(title: "Hesla se neshodují", text: "Zadej heslo dvakrát stejně (okem si ho můžeš zobrazit).")) }
            guard !o.format.hasPrefix("tar") else { return .failure(Problem(title: "\(o.format) heslo neumí", text: "Pro šifrování zvol ZIP nebo 7z.")) }
        }
        o.zipCrypto = o.format == "zip" && (!has7z || method.indexOfSelectedItem == 1)
        o.encryptNames = encNames.state == .on
        o.trashSources = trash.state == .on
        return .success((URL(fileURLWithPath: dirPath, isDirectory: true).appendingPathComponent(n + "." + o.format), o))
    }

    /// „250M“, „1,5G“, „800k“ → velikost pro 7z / zip / split v KiB („…k“). nil = neplatné.
    static func parseSize(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "b", with: "")
        guard let u = t.last, let mult: Double = ["k": 1, "m": 1024, "g": 1024 * 1024][u],
              let v = Double(t.dropLast()), v > 0 else { return nil }
        let kib = Int((v * mult).rounded())
        return kib >= 64 ? "\(kib)k" : nil
    }

    private func save(_ o: PackOptions) {
        d.set(o.format, forKey: "pack.format")
        d.set(o.level, forKey: "pack.level")
        d.set(o.encryptNames, forKey: "pack.encNames")
        if o.format == "zip" && has7z { d.set(o.zipCrypto, forKey: "pack.zipCrypto") }
    }
}
