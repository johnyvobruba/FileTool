import Foundation
import AppKit
import Darwin

/// Položka v panelu. `isParent` = řádek [..] (nadřazená složka).
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDir: Bool            // složka (ne balíček .app)
    let isPackage: Bool        // .app, .bundle … (otevírá se jako soubor, ⌘↓ dovnitř)
    let isLink: Bool
    let isHidden: Bool
    let isExecutable: Bool
    let size: Int64            // −1 = složka (velikost neznámá)
    let modified: Date
    let perms: String          // drwxr-xr-x
    var isParent = false
    /// Položka uvnitř archivu: vnitřní cesta (url je pak jen identifikátor, na disku neexistuje).
    var archiveInner: String? = nil
    /// Položka na vzdáleném serveru: absolutní cesta tam.
    var remotePath: String? = nil

    var id: URL { url }
    var ext: String { isDir || isParent ? "" : (name as NSString).pathExtension }
    /// Název bez přípony (sloupec Název jako v TC).
    var baseName: String {
        if isParent { return ".." }
        if isDir || ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") { return name }
        return (name as NSString).deletingPathExtension
    }
    var isArchive: Bool { !isDir && archiveInner == nil && remotePath == nil && ArchiveIO.isArchive(url) }

    static func fromArchive(_ e: ArchiveEntry, archive: URL) -> FileItem {
        FileItem(url: URL(fileURLWithPath: archive.path + "/" + e.path), name: e.name, isDir: e.isDir, isPackage: false,
                 isLink: e.isLink, isHidden: e.name.hasPrefix("."), isExecutable: false, size: e.isDir ? -1 : e.size,
                 modified: e.mtime, perms: LocalFS.permString((e.isDir ? S_IFDIR : S_IFREG) | e.perm) + (e.encrypted ? " 🔒" : ""),
                 archiveInner: e.path)
    }

    static func parent(of dir: URL) -> FileItem {
        FileItem(url: dir.deletingLastPathComponent(), name: "..", isDir: true, isPackage: false, isLink: false,
                 isHidden: false, isExecutable: false, size: -1, modified: Date.distantPast, perms: "", isParent: true)
    }
}

enum SortKey: String, Codable { case name, ext, size, date }

/// Čtení místní složky (FileManager + lstat). Běží mimo hlavní vlákno.
enum LocalFS {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
                                         .fileSizeKey, .contentModificationDateKey, .isExecutableKey]

    static func list(_ dir: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map { item($0) }
    }

    static func item(_ u: URL) -> FileItem {
        let v = try? u.resourceValues(forKeys: Set(keys))
        let link = v?.isSymbolicLink ?? false
        var dir = v?.isDirectory ?? false
        var pkg = v?.isPackage ?? false
        if link {                                          // odkaz na složku se chová jako složka
            let t = u.resolvingSymlinksInPath()
            let tv = try? t.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            dir = tv?.isDirectory ?? false
            pkg = tv?.isPackage ?? false
        }
        var st = stat()
        let perms = lstat(u.path, &st) == 0 ? permString(st.st_mode) : ""
        let isDirReal = dir && !pkg
        return FileItem(url: u, name: u.lastPathComponent, isDir: isDirReal, isPackage: pkg, isLink: link,
                        isHidden: v?.isHidden ?? u.lastPathComponent.hasPrefix("."),
                        isExecutable: !dir && (v?.isExecutable ?? false) && (st.st_mode & S_IXUSR) != 0,
                        size: isDirReal ? -1 : Int64(v?.fileSize ?? 0),
                        modified: v?.contentModificationDate ?? Date.distantPast, perms: perms)
    }

    static func permString(_ m: mode_t) -> String {
        let type: Character
        switch m & S_IFMT {
        case S_IFDIR: type = "d"
        case S_IFLNK: type = "l"
        default: type = "-"
        }
        let bits: [(mode_t, Character)] = [(S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
                                           (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
                                           (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")]
        return String(type) + String(bits.map { m & $0.0 != 0 ? $0.1 : "-" })
    }

    static func sort(_ items: [FileItem], by key: SortKey, ascending: Bool, foldersFirst: Bool) -> [FileItem] {
        items.sorted { a, b in
            if foldersFirst, a.isDir != b.isDir { return a.isDir }
            let r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .ext:
                let e = a.ext.localizedStandardCompare(b.ext)
                r = e == .orderedSame ? a.name.localizedStandardCompare(b.name) : e
            case .size: r = a.size == b.size ? a.name.localizedStandardCompare(b.name) : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .date: r = a.modified == b.modified ? a.name.localizedStandardCompare(b.name) : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}

// MARK: - Formátování

enum Fmt {
    static let size: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
    static func bytes(_ n: Int64) -> String { size.string(fromByteCount: n) }

    /// Velikost do sloupce: přesně s mezerami po tisících (jako TC), složka = <DIR>.
    static func column(_ i: FileItem) -> String {
        if i.isParent || i.isDir { return "<DIR>" }
        return grouped.string(from: NSNumber(value: i.size)) ?? "\(i.size)"
    }
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = " "; f.usesGroupingSeparator = true; return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; return f
    }()
}

/// Svazky a oblíbená místa pro výběr „disku“.
struct Place: Identifiable, Hashable {
    let url: URL
    let name: String
    let symbol: String
    let isVolume: Bool
    var id: URL { url }

    static func volumes() -> [Place] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let symbol = (v?.volumeIsLocal == false) ? "network" : (v?.volumeIsRemovable == true || v?.volumeIsInternal == false) ? "externaldrive" : "internaldrive"
            return Place(url: u, name: v?.volumeName ?? u.lastPathComponent, symbol: symbol, isVolume: true)
        }
    }

    static func favorites() -> [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var p: [Place] = [Place(url: home, name: "Domů", symbol: "house", isVolume: false)]
        for (dir, name, sym) in [(FileManager.SearchPathDirectory.desktopDirectory, "Plocha", "menubar.dock.rectangle"),
                                 (.documentDirectory, "Dokumenty", "doc"),
                                 (.downloadsDirectory, "Stažené", "arrow.down.circle"),
                                 (.applicationDirectory, "Aplikace", "square.grid.2x2")] {
            if let u = fm.urls(for: dir, in: dir == .applicationDirectory ? .localDomainMask : .userDomainMask).first {
                p.append(Place(url: u, name: name, symbol: sym, isVolume: false))
            }
        }
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: icloud.path) { p.append(Place(url: icloud, name: "iCloud Drive", symbol: "icloud", isVolume: false)) }
        return p
    }

    /// Volné místo a kapacita svazku, na kterém je složka.
    static func space(for url: URL) -> (free: Int64, total: Int64, name: String)? {
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeNameKey]),
              let total = v.volumeTotalCapacity else { return nil }
        return (Int64(v.volumeAvailableCapacityForImportantUsage ?? 0), Int64(total), v.volumeName ?? "")
    }
}
