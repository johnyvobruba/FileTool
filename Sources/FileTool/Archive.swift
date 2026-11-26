import Foundation
import AppKit
import CArchive
import Darwin

// Archivy jako složky: čtení přes libarchive z macOS (ZIP, TAR, GZ, BZ2, XZ, 7z, RAR, ISO, CPIO, XAR),
// zápis do ZIP přes /usr/bin/zip, balení do tar.* přes /usr/bin/tar.
// Bezpečnost rozbalování: žádné absolutní cesty ani „..“ (zip-slip), symbolické a pevné odkazy se přeskakují,
// práva bez setuid/setgid.

struct ArchiveEntry: Hashable {
    let path: String          // vnitřní cesta bez lomítka na konci
    let name: String
    let isDir: Bool
    let size: Int64
    let mtime: Date
    let perm: mode_t
    let encrypted: Bool
    let isLink: Bool
}

/// Obsah archivu (jen hlavičky – data se nečtou).
final class ArchiveIndex: @unchecked Sendable {
    let file: URL
    let format: String
    let encrypted: Bool
    private let children: [String: [ArchiveEntry]]     // vnitřní složka ("" = kořen) → položky
    let entries: [String: ArchiveEntry]

    init(file: URL, format: String, entries list: [ArchiveEntry]) {
        self.file = file
        self.format = format
        encrypted = list.contains { $0.encrypted }
        var all: [String: ArchiveEntry] = [:]
        for e in list { all[e.path] = e }
        // doplnit složky, které archiv nemá jako samostatný záznam (běžné u ZIP)
        for e in list {
            var parts = e.path.split(separator: "/").map(String.init)
            parts.removeLast()
            var p = ""
            for comp in parts {
                p = p.isEmpty ? comp : p + "/" + comp
                if all[p] == nil {
                    all[p] = ArchiveEntry(path: p, name: comp, isDir: true, size: -1, mtime: e.mtime, perm: 0o755, encrypted: false, isLink: false)
                }
            }
        }
        var ch: [String: [ArchiveEntry]] = [:]
        for e in all.values {
            let parent = (e.path as NSString).deletingLastPathComponent
            ch[parent, default: []].append(e)
        }
        children = ch
        entries = all
    }

    func list(_ inner: String) -> [ArchiveEntry] { children[inner] ?? [] }

    /// Všechny soubory pod danými položkami (pro součet velikosti).
    func totalSize(of paths: [String]) -> Int64 {
        entries.values.filter { e in !e.isDir && paths.contains { e.path == $0 || e.path.hasPrefix($0 + "/") } }
            .reduce(Int64(0)) { $0 + max(0, $1.size) }
    }
}

enum ArchiveError: LocalizedError {
    case open(String), read(String), password, cancelled, tool(String)
    var errorDescription: String? {
        switch self {
        case .open(let s): return "Archiv nelze otevřít: \(s)"
        case .read(let s): return "Chyba čtení archivu: \(s)"
        case .password: return "Nesprávné nebo chybějící heslo."
        case .cancelled: return "Zrušeno uživatelem."
        case .tool(let s): return s
        }
    }
}

/// Hesla k archivům – jen v paměti po dobu běhu aplikace.
@MainActor
enum ArchivePasswords {
    private static var cache: [String: String] = [:]
    static func get(_ file: URL) -> String? { cache[file.path] }
    static func forget(_ file: URL) { cache[file.path] = nil }

    /// Zeptá se na heslo (zabezpečené pole). nil = zrušeno.
    static func ask(_ file: URL, wrong: Bool = false) -> String? {
        let a = NSAlert()
        a.messageText = wrong ? "Nesprávné heslo k „\(file.lastPathComponent)“" : "Archiv „\(file.lastPathComponent)“ je zašifrovaný"
        a.informativeText = "Zadej heslo. Pamatuje se jen do ukončení FileTool, nikam se neukládá."
        let f = RevealPasswordField(width: 300)
        a.accessoryView = f
        a.addButton(withTitle: "Otevřít"); a.addButton(withTitle: "Zrušit")
        a.window.initialFirstResponder = f.secure
        guard a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return nil }
        cache[file.path] = f.stringValue
        return f.stringValue
    }
}

enum ArchiveIO {
    static let readableExts: Set<String> = ["zip", "jar", "war", "apk", "epub", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
                                            "xz", "txz", "lz4", "zst", "tzst", "7z", "rar", "cab", "iso", "cpio", "xar", "lzh", "lha"]

    static func isArchive(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return readableExts.contains(url.pathExtension.lowercased()) || n.hasSuffix(".tar.gz") || n.hasSuffix(".tar.bz2") || n.hasSuffix(".tar.xz")
    }

    static func isZip(_ url: URL) -> Bool { ["zip", "jar"].contains(url.pathExtension.lowercased()) }

    private static func open(_ file: URL, passphrase: String?) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw ArchiveError.open("libarchive") }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        archive_read_support_format_raw(a)              // samostatný .gz / .bz2 / .xz
        if let p = passphrase { archive_read_add_passphrase(a, p) }
        if archive_read_open_filename(a, file.path, 65536) != CA_OK {
            let msg = archive_error_string(a).map { String(cString: $0) } ?? "neznámá chyba"
            archive_read_free(a)
            throw ArchiveError.open(msg)
        }
        return a
    }

    /// Bezpečná vnitřní cesta: bez „./“, bez úvodního „/“, bez „..“ a prázdných částí. nil = podezřelá cesta.
    static func clean(_ raw: String) -> String? {
        var parts: [String] = []
        for p in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { return nil }
            parts.append(String(p))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static func entryPath(_ e: OpaquePointer) -> String? {
        if let p = archive_entry_pathname_utf8(e) { return String(cString: p) }
        if let p = archive_entry_pathname(e) { return String(cString: p) }
        return nil
    }

    /// Načte seznam položek (bez dat).
    static func index(_ file: URL) throws -> ArchiveIndex {
        let a = try open(file, passphrase: nil)
        defer { archive_read_free(a) }
        var list: [ArchiveEntry] = []
        var entry: OpaquePointer?
        let rawSingle = file.deletingPathExtension().lastPathComponent
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == CA_EOF { break }
            if r < CA_WARN { throw ArchiveError.read(archive_error_string(a).map { String(cString: $0) } ?? "\(r)") }
            guard let e = entry else { break }
            var path = entryPath(e) ?? ""
            if path == "data" && archive_format_name(a).map({ String(cString: $0) }) == "raw" { path = rawSingle }
            if let p = clean(path) {
                let type = archive_entry_filetype(e) & S_IFMT
                let isDir = type == S_IFDIR || path.hasSuffix("/")
                list.append(ArchiveEntry(path: p, name: (p as NSString).lastPathComponent, isDir: isDir,
                                         size: isDir ? -1 : (archive_entry_size_is_set(e) != 0 ? archive_entry_size(e) : 0),
                                         mtime: Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(e))),
                                         perm: archive_entry_perm(e), encrypted: archive_entry_is_encrypted(e) != 0,
                                         isLink: type == S_IFLNK || archive_entry_hardlink(e) != nil))
            }
            archive_read_data_skip(a)
        }
        let fmt = archive_format_name(a).map { String(cString: $0) } ?? ""
        return ArchiveIndex(file: file, format: fmt, entries: list)
    }

    /// Rozbalí položky `paths` (a vše pod nimi; nil = celý archiv) do `dest`.
    /// Cesta v cíli = vnitřní cesta bez prefixu `stripPrefix` (aktuální složka v archivu).
    static func extract(_ file: URL, paths: [String]?, stripPrefix: String, to dest: URL, passphrase: String?,
                        cancel: Box<Bool>, progress: Box<(done: Int64, current: String)>) throws -> [String] {
        let a = try open(file, passphrase: passphrase)
        defer { archive_read_free(a) }
        let fm = FileManager.default
        let destRoot = dest.standardizedFileURL.path
        var skipped: [String] = []
        var done: Int64 = 0
        var entry: OpaquePointer?
        let rawSingle = file.deletingPathExtension().lastPathComponent
        var buf = [UInt8](repeating: 0, count: 1 << 18)
        let prefix = stripPrefix.isEmpty ? "" : stripPrefix + "/"
        while true {
            if cancel.value { throw ArchiveError.cancelled }
            let r = archive_read_next_header(a, &entry)
            if r == CA_EOF { break }
            if r < CA_WARN { throw ArchiveError.read(archive_error_string(a).map { String(cString: $0) } ?? "\(r)") }
            guard let e = entry else { break }
            var raw = entryPath(e) ?? ""
            if raw == "data" && archive_format_name(a).map({ String(cString: $0) }) == "raw" { raw = rawSingle }
            guard let p = clean(raw) else { skipped.append("\(raw) (nebezpečná cesta)"); archive_read_data_skip(a); continue }
            if let paths, !paths.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { archive_read_data_skip(a); continue }
            guard p.hasPrefix(prefix) || prefix.isEmpty else { archive_read_data_skip(a); continue }
            let rel = String(p.dropFirst(prefix.count))
            let target = dest.appendingPathComponent(rel)
            // zip-slip: výsledná cesta musí zůstat v cílové složce
            guard target.standardizedFileURL.path.hasPrefix(destRoot + "/") else {
                skipped.append("\(p) (mimo cílovou složku)"); archive_read_data_skip(a); continue
            }
            let type = archive_entry_filetype(e) & S_IFMT
            if type == S_IFLNK || archive_entry_hardlink(e) != nil {
                skipped.append("\(p) (odkaz – přeskočen)"); archive_read_data_skip(a); continue
            }
            let isDir = type == S_IFDIR || raw.hasSuffix("/")
            if isDir {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                archive_read_data_skip(a); continue
            }
            if type != S_IFREG && type != 0 { skipped.append("\(p) (speciální soubor)"); archive_read_data_skip(a); continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let h = try? FileHandle(forWritingTo: target) else { skipped.append("\(p) (nelze zapsat)"); archive_read_data_skip(a); continue }
            progress.value = (done, (p as NSString).lastPathComponent)
            var failed: String?
            while true {
                if cancel.value { try? h.close(); try? fm.removeItem(at: target); throw ArchiveError.cancelled }
                let n = buf.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                if n == 0 { break }
                if n < 0 { failed = archive_error_string(a).map { String(cString: $0) } ?? "chyba dat"; break }
                h.write(Data(buf[0..<n]))
                done += Int64(n)
                progress.value = (done, (p as NSString).lastPathComponent)
            }
            try? h.close()
            if let failed {
                try? fm.removeItem(at: target)
                let low = failed.lowercased()
                if low.contains("passphrase") || low.contains("password") || low.contains("decrypt") { throw ArchiveError.password }
                skipped.append("\(p) (\(failed))")
                continue
            }
            // práva z archivu bez setuid/setgid/sticky, čas změny
            let perm = Int(archive_entry_perm(e)) & 0o777
            try? fm.setAttributes([.posixPermissions: perm == 0 ? 0o644 : perm,
                                   .modificationDate: Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(e)))],
                                  ofItemAtPath: target.path)
        }
        return skipped
    }

    // MARK: Zápis (nástroje macOS)

    /// Spustí nástroj (bez shellu), vrátí (kód, výstup). Proces jde zrušit přes `cancel`.
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, cancel: Box<Bool>? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "Nelze spustit \(exe)") }
        if let cancel {
            DispatchQueue.global().async {
                while p.isRunning { if cancel.value { p.terminate(); break }; usleep(100_000) }
            }
        }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    /// Nová archivní složka/soubor: ZIP (/usr/bin/zip) nebo tar.gz / tar.xz (/usr/bin/tar). Názvy jako „./název“.
    static func create(_ out: URL, from dir: URL, names: [String], format: String, cancel: Box<Bool>) throws {
        let items = names.map { "./" + $0 }
        let r: (Int32, String)
        switch format {
        case "zip": r = run("/usr/bin/zip", ["-r", "-y", "-q", out.path] + items, cwd: dir, cancel: cancel)
        case "tar.xz": r = run("/usr/bin/tar", ["-cJf", out.path] + items, cwd: dir, cancel: cancel)
        default: r = run("/usr/bin/tar", ["-czf", out.path] + items, cwd: dir, cancel: cancel)
        }
        if cancel.value { try? FileManager.default.removeItem(at: out); throw ArchiveError.cancelled }
        guard r.0 == 0 else { try? FileManager.default.removeItem(at: out); throw ArchiveError.tool("Balení selhalo (kód \(r.0)): \(r.1.suffix(300))") }
    }

    /// Šifrovaný archiv. 7-Zip (je-li nainstalovaný): ZIP i 7z s AES-256 (7z i se šifrovanými názvy).
    /// Bez 7-Zip jen ZIP přes /usr/bin/zip -e (ZipCrypto – slabé šifrování). Heslo jde přes pseudoterminál.
    static func createEncrypted(_ out: URL, from dir: URL, names: [String], format: String, password: String, cancel: Box<Bool>) throws {
        let items = names.map { "./" + $0 }
        let r: (Int32, String)
        if let sz = SevenZip.path {
            let type = format == "7z" ? ["-t7z", "-mhe=on"] : ["-tzip", "-mem=AES256"]
            r = PtyRunner.run(sz, ["a"] + type + ["-p", "-y", "-bso0", "-bsp0", out.path] + items, cwd: dir, password: password, cancel: cancel)
        } else {
            guard format == "zip" else { throw ArchiveError.tool("Formát 7z potřebuje 7-Zip (brew install sevenzip).") }
            r = PtyRunner.run("/usr/bin/zip", ["-r", "-y", "-e", out.path] + items, cwd: dir, password: password, cancel: cancel)
        }
        if cancel.value { try? FileManager.default.removeItem(at: out); throw ArchiveError.cancelled }
        guard r.0 == 0, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            throw ArchiveError.tool("Šifrované balení selhalo (kód \(r.0)): \(r.1.suffix(300))")
        }
    }

    /// Balení s volbami (dialog ⌥⌘5): úroveň komprese, heslo (AES-256 / ZipCrypto), šifrované názvy (7z),
    /// rozdělení na části. ZIP a 7z přes 7-Zip, je-li nainstalovaný; jinak ZIP přes macOS zip. tar přes /usr/bin/tar,
    /// části u taru přes /usr/bin/split. Heslo jde přes pseudoterminál (není v argumentech ani v prostředí).
    static func pack(_ out: URL, from dir: URL, names: [String], o: PackOptions, cancel: Box<Bool>) throws {
        let items = names.map { "./" + $0 }
        let lv = max(0, min(9, o.level))
        let pw = !o.password.isEmpty
        var r: (Int32, String) = (0, "")
        switch o.format {
        case "zip", "7z":
            if let sz = SevenZip.path {
                var args = ["a", o.format == "7z" ? "-t7z" : "-tzip", "-mx=\(lv)", "-y", "-bso0", "-bsp0"]
                if pw {
                    args.append("-p")
                    if o.format == "7z" { if o.encryptNames { args.append("-mhe=on") } }
                    else { args.append(o.zipCrypto ? "-mem=ZipCrypto" : "-mem=AES256") }
                }
                if let v = o.volume { args.append("-v" + v) }
                args += [out.path] + items
                r = pw ? PtyRunner.run(sz, args, cwd: dir, password: o.password, cancel: cancel)
                       : run(sz, args, cwd: dir, cancel: cancel)
            } else {
                guard o.format == "zip" else { throw ArchiveError.tool("Formát 7z potřebuje 7-Zip (brew install sevenzip).") }
                var args = ["-r", "-y", "-\(lv)"]
                if let v = o.volume { args += ["-s", v] }
                if pw { args.append("-e") } else { args.append("-q") }
                args += [out.path] + items
                r = pw ? PtyRunner.run("/usr/bin/zip", args, cwd: dir, password: o.password, cancel: cancel)
                       : run("/usr/bin/zip", args, cwd: dir, cancel: cancel)
            }
        default:
            let (flag, opt): (String, String) = o.format == "tar.xz" ? ("-J", "xz") : o.format == "tar.bz2" ? ("-j", "bzip2") : ("-z", "gzip")
            let tl = opt == "bzip2" ? max(1, lv) : lv
            r = run("/usr/bin/tar", ["-c", flag, "--options", "\(opt):compression-level=\(tl)", "-f", out.path] + items, cwd: dir, cancel: cancel)
            if r.0 == 0, !cancel.value, let v = o.volume {
                let s = run("/usr/bin/split", ["-b", v, out.lastPathComponent, out.lastPathComponent + "."], cwd: out.deletingLastPathComponent(), cancel: cancel)
                if s.0 == 0 { try? FileManager.default.removeItem(at: out) } else { r = s }
            }
        }
        let made = FileManager.default.fileExists(atPath: out.path) || FileManager.default.fileExists(atPath: out.path + ".001")
            || FileManager.default.fileExists(atPath: out.path + ".aa")
        if cancel.value { for u in parts(of: out) { try? FileManager.default.removeItem(at: u) }; throw ArchiveError.cancelled }
        guard r.0 == 0, made else {
            for u in parts(of: out) { try? FileManager.default.removeItem(at: u) }
            throw ArchiveError.tool("Balení selhalo (kód \(r.0)): \(r.1.suffix(300))")
        }
    }

    /// Archiv a všechny jeho části: název.zip, název.zip.001…, název.z01…, název.tar.gz.aa…
    static func parts(of out: URL) -> [URL] {
        let dir = out.deletingLastPathComponent(), n = out.lastPathComponent
        let base = (n as NSString).deletingPathExtension
        let list = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return list.filter { f in
            if f == n { return true }
            if f.hasPrefix(n + "."), let s = f.split(separator: ".").last {
                return (s.count == 3 && s.allSatisfy(\.isNumber)) || (s.count == 2 && s.allSatisfy(\.isLowercase))
            }
            if f.hasPrefix(base + ".z"), f.count == base.count + 4, f.suffix(2).allSatisfy(\.isNumber) { return true }
            return false
        }.map { dir.appendingPathComponent($0) }
    }

    /// Přidá soubory do ZIP na vnitřní cestu `inner` (přes dočasnou složku se stejnou strukturou), pak ověří ZIP.
    static func addToZip(_ zip: URL, inner: String, sources: [URL], cancel: Box<Bool>) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("filetool-zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let base = inner.isEmpty ? stage : stage.appendingPathComponent(inner, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var names: [String] = []
        for s in sources {
            try fm.copyItem(at: s, to: base.appendingPathComponent(s.lastPathComponent))   // APFS klon
            names.append((inner.isEmpty ? "" : inner + "/") + s.lastPathComponent)
        }
        let r = run("/usr/bin/zip", ["-r", "-y", "-q", zip.path] + names.map { "./" + $0 }, cwd: stage, cancel: cancel)
        if cancel.value { throw ArchiveError.cancelled }
        guard r.0 == 0 else { throw ArchiveError.tool("Přidání do ZIP selhalo (kód \(r.0)): \(r.1.suffix(300))") }
        try verifyZip(zip)
    }

    /// Smaže položky (i složky) ze ZIP, pak ověří.
    static func deleteFromZip(_ zip: URL, paths: [String], dirs: Set<String>) throws {
        // -nw: názvy z archivu se berou doslova (položka „*“ nesmaže vše); obsah složky se vyjmenuje
        if let bad = paths.first(where: { $0.hasPrefix("-") }) {
            throw ArchiveError.tool("Položku „\(bad)“ nelze bezpečně smazat (název začíná „-“).")
        }
        var args = ["-d", "-q", "-nw", zip.path]
        let all = (try? index(zip))?.entries.keys.map { $0 } ?? []
        for p in paths {
            args.append(p)
            if dirs.contains(p) {
                args.append(p + "/")
                args += all.filter { $0.hasPrefix(p + "/") && !$0.hasPrefix("-") }
            }
        }
        let r = run("/usr/bin/zip", args)
        // kód 12 = „nothing to do“ (např. složka neexistovala jako záznam) – v pořádku
        guard r.0 == 0 || r.0 == 12 else { throw ArchiveError.tool("Mazání ze ZIP selhalo (kód \(r.0)): \(r.1.suffix(300))") }
        try verifyZip(zip)
    }

    static func verifyZip(_ zip: URL) throws {
        let t = run("/usr/bin/zip", ["-T", "-q", zip.path])
        guard t.0 == 0 else { throw ArchiveError.tool("Kontrola ZIP po změně selhala: \(t.1.suffix(300))") }
    }

    /// Dočasná složka pro náhled / otevření souboru z archivu (smaže se při dalším spuštění).
    static var viewRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileTool/archive-view", isDirectory: true)
    }

    static func cleanupViewCopies() { try? FileManager.default.removeItem(at: viewRoot) }

    /// Atribut karantény archivu se přenese na rozbalené soubory (Gatekeeper je pak zkontroluje).
    static func inheritQuarantine(from archive: URL, to root: URL) {
        let attr = "com.apple.quarantine"
        let len = getxattr(archive.path, attr, nil, 0, 0, 0)
        guard len > 0 else { return }
        var value = [UInt8](repeating: 0, count: len)
        guard getxattr(archive.path, attr, &value, len, 0, 0) == len else { return }
        var paths = [root.path]
        if let e = FileManager.default.enumerator(atPath: root.path) { for case let r as String in e { paths.append(root.path + "/" + r) } }
        for p in paths { _ = setxattr(p, attr, value, len, 0, XATTR_NOFOLLOW) }
    }
}
