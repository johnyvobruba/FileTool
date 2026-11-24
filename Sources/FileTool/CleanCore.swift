import Foundation
import AppKit
import CoreServices
import CryptoKit

// Jádro nástroje Úklid (styl CleanMyMac): společné funkce, systémový odpad, velké a staré soubory.
// Zásady: systémové složky se nikdy nenabízejí; mazání = Koš po potvrzení (výjimka: vysypání Koše).

enum CleanFS {
    static let protectedRoots = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/dev", "/cores", "/opt", "/Volumes/Recovery"]

    static func isProtected(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "/" || path == home || path == home + "/Library" { return true }
        return protectedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

    /// Velikost na disku (u složky součet obsahu).
    static func size(_ u: URL, cancel: Box<Bool>? = nil) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            if cancel?.value == true { break }
            if let fv = try? f.resourceValues(forKeys: Set(keys)), fv.isRegularFile == true {
                total += Int64(fv.totalFileAllocatedSize ?? fv.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Kdy byl soubor / aplikace naposledy otevřen(a) – Spotlight; nil = neznámé.
    static func lastUsed(_ u: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, u as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func children(_ u: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    /// Přesun do Koše (permanent = trvale, jen pro vysypání Koše). Vrací uvolněné bajty, hotové a chyby.
    static func remove(_ items: [(URL, Int64)], permanent: Bool = false) -> (freed: Int64, done: [URL], errors: [String]) {
        var freed: Int64 = 0, done: [URL] = [], errs: [String] = []
        for (u, size) in items {
            guard !isProtected(u.path) else { errs.append("\(u.path): chráněná složka"); continue }
            do {
                if permanent { try FileManager.default.removeItem(at: u) }
                else { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
                freed += size; done.append(u)
            } catch let err { errs.append("\(u.lastPathComponent): \(err.localizedDescription)") }
        }
        return (freed, done, errs)
    }

    /// Plný přístup k disku: bez něj macOS nedovolí číst Koš, Mail a další složky.
    static var hasFullDiskAccess: Bool { Permissions.hasFullDiskAccess }

    @MainActor static func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }

    @MainActor static func report(_ title: String, freed: Int64, errors: [String], trash: Bool = true) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "Uvolněno: \(Fmt.bytes(freed))" + (trash ? " (místo se uvolní po vysypání Koše)" : "")
            + (errors.isEmpty ? "" : "\n\nNešlo zpracovat (\(errors.count)):\n" + errors.prefix(10).joined(separator: "\n")
               + "\n\nČasto jde o běžící aplikaci, soubory jiného uživatele nebo chybějící Plný přístup k disku.")
        a.runModal()
    }

    /// SHA-256 souboru (limit = jen prvních N bajtů).
    static func hash(_ u: URL, limit: Int? = nil) -> String? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let want = limit.map { min(1 << 20, $0 - read) } ?? (1 << 20)
            if want <= 0 { break }
            guard let d = try? h.read(upToCount: want), !d.isEmpty else { break }
            hasher.update(data: d); read += d.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Systémový odpad

struct JunkItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var note = ""
    var id: URL { url }
    var name: String { note.isEmpty ? FileManager.default.displayName(atPath: url.path) : note }
}

struct JunkCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let help: String
    let defaultOn: Bool
    let permanent: Bool
    var items: [JunkItem] = []
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Definice kategorie: kořenové složky (obsah = položky) nebo filtr souborů.
struct JunkDef: Sendable {
    let id, title, icon, help: String
    let roots: [String]
    let exts: [String]          // prázdné = všechny položky ve složce
    let defaultOn: Bool
    let permanent: Bool
}

@MainActor
final class JunkModel: ObservableObject {
    @Published var categories: [JunkCategory] = []
    @Published var checked = Set<URL>()
    @Published var expanded = Set<String>()
    @Published var running = false
    @Published var scanned = false
    @Published var status = ""
    private var cancel = Box(false)

    static let defs: [JunkDef] = [
        JunkDef(id: "caches", title: "Mezipaměti aplikací", icon: "shippingbox", help: "~/Library/Caches – aplikace si je znovu vytvoří. Mezipaměti běžících aplikací se nezaškrtávají.",
                roots: ["~/Library/Caches"], exts: [], defaultOn: true, permanent: false),
        JunkDef(id: "logs", title: "Logy aplikací", icon: "doc.text", help: "~/Library/Logs včetně hlášení o pádech.",
                roots: ["~/Library/Logs"], exts: [], defaultOn: true, permanent: false),
        JunkDef(id: "state", title: "Uložený stav oken", icon: "macwindow.on.rectangle", help: "Obnova oken po restartu aplikace (~/Library/Saved Application State).",
                roots: ["~/Library/Saved Application State"], exts: [], defaultOn: true, permanent: false),
        JunkDef(id: "xcode", title: "Xcode a simulátory", icon: "hammer", help: "DerivedData, iOS DeviceSupport a mezipaměť simulátorů – vytvoří se znovu.",
                roots: ["~/Library/Developer/Xcode/DerivedData", "~/Library/Developer/Xcode/iOS DeviceSupport",
                        "~/Library/Developer/Xcode/watchOS DeviceSupport", "~/Library/Developer/CoreSimulator/Caches"], exts: [], defaultOn: true, permanent: false),
        JunkDef(id: "xarchives", title: "Xcode Archives", icon: "archivebox", help: "Staré buildy pro distribuci – smaž jen ty, které už nepotřebuješ (symboly pro pády).",
                roots: ["~/Library/Developer/Xcode/Archives"], exts: [], defaultOn: false, permanent: false),
        JunkDef(id: "dev", title: "Vývojářské mezipaměti", icon: "terminal", help: "npm, pip, Gradle, Cargo, CocoaPods, ~/.cache – stáhnou se znovu při dalším buildu.",
                roots: ["~/.npm/_cacache", "~/.cache", "~/.gradle/caches", "~/.cargo/registry/cache"], exts: [], defaultOn: true, permanent: false),
        JunkDef(id: "installers", title: "Stažené instalátory", icon: "shippingbox.and.arrow.backward", help: "Soubory .dmg, .pkg, .iso a .xip ve Stažených – po instalaci se obvykle nepotřebují.",
                roots: ["~/Downloads"], exts: ["dmg", "pkg", "mpkg", "iso", "xip"], defaultOn: true, permanent: false),
        JunkDef(id: "ios", title: "Aktualizace iOS / iPadOS", icon: "iphone", help: "Stažené firmwary (.ipsw) – Finder je při další aktualizaci stáhne znovu.",
                roots: ["~/Library/iTunes/iPhone Software Updates", "~/Library/iTunes/iPad Software Updates"], exts: [], defaultOn: true, permanent: false),
        JunkDef(id: "mail", title: "Přílohy Mailu", icon: "paperclip", help: "Kopie otevřených příloh – originál zůstává v e-mailu.",
                roots: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"], exts: [], defaultOn: false, permanent: false),
        JunkDef(id: "backups", title: "Zálohy iPhonu / iPadu", icon: "externaldrive.badge.timemachine", help: "Lokální zálohy zařízení – smaž jen staré zálohy zařízení, která už nemáš!",
                roots: ["~/Library/Application Support/MobileSync/Backup"], exts: [], defaultOn: false, permanent: false),
        JunkDef(id: "trash", title: "Koš", icon: "trash", help: "Vysypání Koše maže TRVALE – nelze vrátit.",
                roots: ["~/.Trash"], exts: [], defaultOn: false, permanent: true),
    ]

    var totalChecked: Int64 { categories.flatMap(\.items).filter { checked.contains($0.id) }.reduce(0) { $0 + $1.size } }
    var total: Int64 { categories.reduce(0) { $0 + $1.size } }

    func scan() {
        cancel.value = true
        let c = Box(false); cancel = c
        running = true; status = "Prohledávám…"; categories = []; checked = []
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let defs = Self.defs
        Task.detached(priority: .userInitiated) {
            var cats: [JunkCategory] = []
            for d in defs {
                if c.value { break }
                await MainActor.run { guard self.cancel === c else { return }; self.status = "Prohledávám: \(d.title)…" }
                var items: [JunkItem] = []
                for r in d.roots {
                    let root = CleanFS.expand(r)
                    for u in CleanFS.children(root) {
                        if c.value { break }
                        if u.lastPathComponent == ".DS_Store" || u.lastPathComponent == ".localized" { continue }
                        if !d.exts.isEmpty, !d.exts.contains(u.pathExtension.lowercased()) { continue }
                        if d.id == "caches", u.lastPathComponent.hasPrefix("cz.local.filetool") || u.lastPathComponent == "FileTool" { continue }
                        let s = CleanFS.size(u, cancel: c)
                        guard s > 0 else { continue }
                        var note = ""
                        if d.id == "caches" || d.id == "state" || d.id == "logs" {
                            let base = u.lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
                            if running.contains(base) { note = FileManager.default.displayName(atPath: u.path) + " – aplikace běží" }
                        }
                        items.append(JunkItem(url: u, size: s, note: note))
                    }
                }
                guard !items.isEmpty else { continue }
                items.sort { $0.size > $1.size }
                cats.append(JunkCategory(id: d.id, title: d.title, icon: d.icon, help: d.help, defaultOn: d.defaultOn, permanent: d.permanent, items: items))
            }
            let result = cats
            await MainActor.run { guard self.cancel === c else { return };
                self.categories = result
                self.checked = Set(result.filter(\.defaultOn).flatMap(\.items).filter { !$0.note.hasSuffix("aplikace běží") }.map(\.id))
                self.running = false
                self.scanned = true
                self.status = c.value ? "Zastaveno" : "Nalezeno \(Fmt.bytes(self.total)) v \(result.count) kategoriích"
            }
        }
    }

    func stop() { cancel.value = true; running = false }

    func toggleCategory(_ cat: JunkCategory) {
        let ids = Set(cat.items.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }
    func state(_ cat: JunkCategory) -> Bool? {
        let ids = Set(cat.items.map(\.id))
        if ids.isSubset(of: checked) { return true }
        return ids.isDisjoint(with: checked) ? false : nil
    }

    func clean() {
        let chosen = categories.flatMap { cat in cat.items.filter { checked.contains($0.id) }.map { (cat, $0) } }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        let perm = chosen.filter { $0.0.permanent }
        let a = NSAlert()
        a.alertStyle = perm.isEmpty ? .warning : .critical
        a.messageText = "Vyčistit \(Fmt.bytes(totalChecked))?"
        a.informativeText = "Položky se přesunou do Koše (lze vrátit)." + (perm.isEmpty ? "" : "\n\nObsah Koše (\(perm.count) položek) se smaže TRVALE.")
            + "\nPřed čištěním mezipamětí je dobré zavřít ostatní aplikace."
        a.addButton(withTitle: "Vyčistit"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        running = true; status = "Čistím…"
        let normal = chosen.filter { !$0.0.permanent }.map { ($0.1.url, $0.1.size) }
        let permanent = perm.map { ($0.1.url, $0.1.size) }
        Task.detached(priority: .userInitiated) {
            let r1 = CleanFS.remove(normal)
            let r2 = CleanFS.remove(permanent, permanent: true)
            await MainActor.run {
                let done = Set(r1.done + r2.done)
                for i in self.categories.indices { self.categories[i].items.removeAll { done.contains($0.id) } }
                self.categories.removeAll { $0.items.isEmpty }
                self.checked.subtract(done)
                self.running = false
                self.status = "Uvolněno \(Fmt.bytes(r1.freed + r2.freed))"
                SidebarModel.shared.reloadVolumes()
                CleanFS.report("Čištění dokončeno", freed: r1.freed + r2.freed, errors: r1.errors + r2.errors, trash: !r1.done.isEmpty)
            }
        }
    }
}

// MARK: - Velké a staré soubory

struct BigFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let lastUsed: Date?
    let modified: Date?
    var id: URL { url }
    var kind: FileKind { FileKind.of(url) }
    var reference: Date { max(lastUsed ?? .distantPast, modified ?? .distantPast) }

    // klíče pro řazení tabulky
    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }
    var lastUsedKey: Date { lastUsed ?? .distantPast }
    var modifiedKey: Date { modified ?? .distantPast }
    /// „Kolik místa a jak dlouho ladem“: velikost (MB) × stáří (dny) – nahoře velké a zároveň staré soubory.
    var score: Double { Double(size) / 1_048_576 * max(1, Date().timeIntervalSince(reference) / 86_400) }
}

enum BigSort: String, CaseIterable, Identifiable {
    case sizeAge, size, oldest, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sizeAge: return "Velké a zároveň staré"
        case .size: return "Největší"
        case .oldest: return "Nejstarší"
        case .name: return "Název"
        }
    }
    var comparators: [KeyPathComparator<BigFile>] {
        switch self {
        case .sizeAge: return [KeyPathComparator(\.score, order: .reverse)]
        case .size: return [KeyPathComparator(\.size, order: .reverse)]
        case .oldest: return [KeyPathComparator(\.modifiedKey), KeyPathComparator(\.size, order: .reverse)]
        case .name: return [KeyPathComparator(\.name)]
        }
    }
}

enum FileKind: String, CaseIterable, Identifiable {
    case all, video, archive, image, document, audio, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Vše"; case .video: return "Video"; case .archive: return "Archivy"
        case .image: return "Obrazy disků"; case .document: return "Dokumenty"; case .audio: return "Hudba"; case .other: return "Ostatní"
        }
    }
    static func of(_ u: URL) -> FileKind {
        let e = u.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "mts"].contains(e) { return .video }
        if ["zip", "7z", "rar", "gz", "tgz", "xz", "bz2", "tar", "zst"].contains(e) { return .archive }
        if ["dmg", "iso", "img", "pkg", "ipsw", "vmdk", "qcow2", "ova", "vdi", "xip", "sparsebundle", "sparseimage"].contains(e) { return .image }
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "psd", "ai", "sketch"].contains(e) { return .document }
        if ["mp3", "m4a", "wav", "flac", "aiff", "aac"].contains(e) { return .audio }
        return .other
    }
}

enum AgeFilter: Int, CaseIterable, Identifiable {
    case anyAge = 0, m6 = 6, y1 = 12, y2 = 24
    var id: Int { rawValue }
    var title: String {
        switch self { case .anyAge: return "Jakékoliv stáří"; case .m6: return "Neotevřené 6+ měsíců"; case .y1: return "Neotevřené 1+ rok"; case .y2: return "Neotevřené 2+ roky" }
    }
}

@MainActor
final class LargeOldModel: ObservableObject {
    /// Režim „Staré soubory“: menší soubory (od 1 MB), výsledky jen neotevřené déle než zvolené stáří.
    let oldMode: Bool
    init(oldMode: Bool = false) {
        self.oldMode = oldMode
        if oldMode { minSizeMB = 10; age = .y1; sortOrder = BigSort.sizeAge.comparators }
    }
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var minSizeMB = 100
    @Published var includeLibrary = false
    @Published var files: [BigFile] = []
    @Published var kind: FileKind = .all
    @Published var age: AgeFilter = .anyAge
    @Published var selection = Set<URL>()
    @Published var running = false
    @Published var scanned = false
    @Published var status = ""
    /// Řazení tabulky (klik na hlavičku sloupce nebo předvolba).
    @Published var sortOrder: [KeyPathComparator<BigFile>] = [KeyPathComparator(\.size, order: .reverse)]
    private var cancel = Box(false)

    var shown: [BigFile] { filtered.sorted(using: sortOrder) }
    private var filtered: [BigFile] {
        let cutoff = age == .anyAge ? nil : Calendar.current.date(byAdding: .month, value: -age.rawValue, to: Date())
        return files.filter { (kind == .all || $0.kind == kind) && (cutoff == nil || $0.reference < cutoff!) }
    }
    var shownSize: Int64 { shown.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { files.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        cancel.value = true
        let c = Box(false); cancel = c
        files = []; selection = []; running = true; status = "Prohledávám…"
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        let minBytes = Int64(minSizeMB) * 1_048_576, lib = includeLibrary
        // staré soubory: do seznamu jen to, co je starší než zvolené stáří (jinak by šlo o desetitisíce položek)
        let cutoff: Date? = oldMode && age != .anyAge ? Calendar.current.date(byAdding: .month, value: -age.rawValue, to: Date()) : nil
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
            let libPath = CleanFS.home + "/Library"
            let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                   options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true })
            var batch: [BigFile] = [], n = 0, last = Date()
            while let u = e?.nextObject() as? URL {
                if c.value { break }
                n += 1
                let p = u.path
                if CleanFS.isProtected(p) || (!lib && (p == libPath || p.hasPrefix(libPath + "/"))) || p.hasPrefix(CleanFS.home + "/.Trash") {
                    e?.skipDescendants(); continue
                }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                if let st = v.ubiquitousItemDownloadingStatus, st != .current { continue }
                let s = Int64(v.totalFileAllocatedSize ?? 0)
                guard s >= minBytes else { continue }
                if let cutoff, (v.contentModificationDate ?? .distantPast) >= cutoff { continue }     // rychlé vyřazení bez Spotlightu
                let f = BigFile(url: u, size: s, lastUsed: CleanFS.lastUsed(u), modified: v.contentModificationDate)
                if let cutoff, f.reference >= cutoff { continue }
                batch.append(f)
                if Date().timeIntervalSince(last) > 0.3 {
                    last = Date()
                    let b = batch, count = n; batch = []
                    await MainActor.run { guard self.cancel === c else { return }; self.files += b; self.files.sort { $0.size > $1.size }; self.status = "Prohledáno \(count) položek…" }
                }
            }
            let b = batch, count = n
            await MainActor.run { guard self.cancel === c else { return };
                self.files += b; self.files.sort { $0.size > $1.size }
                self.running = false; self.scanned = true
                self.status = (c.value ? "Zastaveno · " : "") + "\(self.files.count) souborů, \(Fmt.bytes(self.files.reduce(0) { $0 + $1.size })) · prohledáno \(count) položek"
            }
        }
    }

    func stop() { cancel.value = true; running = false }

    func trashSelected() {
        let chosen = files.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "Přesunout do Koše \(chosen.count) souborů (\(Fmt.bytes(chosen.reduce(0) { $0 + $1.size })))?"
        a.informativeText = chosen.prefix(10).map { "• " + $0.url.lastPathComponent }.joined(separator: "\n") + (chosen.count > 10 ? "\n…" : "")
        a.addButton(withTitle: "Do Koše"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let list = chosen.map { ($0.url, $0.size) }
        Task.detached {
            let r = CleanFS.remove(list)
            await MainActor.run {
                self.files.removeAll { r.done.contains($0.url) }
                self.selection.subtract(r.done)
                Commander.shared.refreshAll(); SidebarModel.shared.reloadVolumes()
                CleanFS.report("Hotovo", freed: r.freed, errors: r.errors)
            }
        }
    }
}
