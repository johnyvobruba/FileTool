import Foundation
import AppKit

// Úklid: odinstalace aplikací (+ zbytky), mapa disku, duplicity.

// MARK: - Odinstalace

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    var size: Int64
    let lastUsed: Date?
    var id: URL { url }
}

@MainActor
final class UninstallModel: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var selected: URL? { didSet { if selected != oldValue { loadRelated() } } }
    @Published var related: [JunkItem] = []
    @Published var checkedRelated = Set<URL>()
    @Published var orphans: [JunkItem] = []
    @Published var checkedOrphans = Set<URL>()
    @Published var showOrphans = false
    @Published var filter = ""
    @Published var sortByUse = false
    @Published var running = false
    @Published var scanned = false
    @Published var status = ""

    /// Kde aplikace nechávají data. (název složky, zda jde i o shodu podle názvu aplikace)
    nonisolated static let libraryDirs: [(String, Bool)] = [
        ("~/Library/Application Support", true), ("~/Library/Caches", true), ("~/Library/Preferences", false),
        ("~/Library/Containers", false), ("~/Library/Group Containers", false), ("~/Library/Saved Application State", false),
        ("~/Library/LaunchAgents", false), ("~/Library/HTTPStorages", false), ("~/Library/WebKit", false),
        ("~/Library/Logs", true), ("~/Library/Cookies", false), ("~/Library/Application Scripts", false),
        ("~/Library/Preferences/ByHost", false),
    ]

    var shownApps: [AppEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let l = apps.filter { f.isEmpty || $0.name.lowercased().contains(f) }
        return sortByUse ? l.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) } : l
    }
    var app: AppEntry? { apps.first { $0.url == selected } }
    var relatedChecked: Int64 { related.filter { checkedRelated.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        running = true; status = "Načítám aplikace…"; apps = []
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var list: [AppEntry] = []
            for d in ["/Applications", "/Applications/Utilities", CleanFS.home + "/Applications"] {
                for u in CleanFS.children(URL(fileURLWithPath: d)) where u.pathExtension == "app" {
                    guard let b = Bundle(url: u), let bid = b.bundleIdentifier, !bid.hasPrefix("com.apple.") else { continue }
                    if bid == Bundle.main.bundleIdentifier { continue }
                    let name = fm.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
                    let ver = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                    list.append(AppEntry(url: u, name: name, bundleID: bid, version: ver, size: -1, lastUsed: CleanFS.lastUsed(u)))
                }
            }
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let first = list
            await MainActor.run { self.apps = first; self.status = "Počítám velikosti…" }
            for a in first {
                let s = CleanFS.size(a.url)
                await MainActor.run { if let i = self.apps.firstIndex(where: { $0.url == a.url }) { self.apps[i].size = s } }
            }
            await MainActor.run { self.running = false; self.scanned = true; self.status = "\(first.count) aplikací" }
        }
    }

    /// Soubory patřící aplikaci: složky / soubory pojmenované podle bundle ID nebo (u části složek) podle názvu.
    nonisolated static func relatedFiles(bundleID: String, name: String) -> [JunkItem] {
        let bid = bundleID.lowercased(), nm = name.lowercased()
        var out: [JunkItem] = []
        for (dir, byName) in libraryDirs {
            for u in CleanFS.children(CleanFS.expand(dir)) {
                let n = u.lastPathComponent.lowercased()
                let stem = n.replacingOccurrences(of: ".plist", with: "").replacingOccurrences(of: ".savedstate", with: "")
                    .replacingOccurrences(of: ".binarycookies", with: "")
                let byID = stem == bid || stem.hasPrefix(bid + ".") || stem.hasSuffix("." + bid)
                let byNm = !byID && byName && nm.count >= 3 && (n == nm || n == nm.replacingOccurrences(of: " ", with: ""))
                if byID || byNm, !CleanFS.isProtected(u.path) {
                    out.append(JunkItem(url: u, size: CleanFS.size(u),
                                        note: dir.replacingOccurrences(of: "~/Library/", with: "") + " / " + u.lastPathComponent
                                            + (byNm ? " – podle názvu, ověř" : "")))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    private func loadRelated() {
        related = []; checkedRelated = []
        guard let a = app else { return }
        let bid = a.bundleID, name = a.name, url = a.url
        Task.detached {
            let r = UninstallModel.relatedFiles(bundleID: bid, name: name)
            await MainActor.run {
                guard self.selected == url else { return }
                self.related = r
                // předem jen jisté shody (bundle ID); shody podle názvu může mít i jiná aplikace
                self.checkedRelated = Set(r.filter { !$0.note.hasSuffix("podle názvu, ověř") }.map(\.id))
            }
        }
    }

    func uninstall() {
        guard let a = app else { return }
        let extra = related.filter { checkedRelated.contains($0.id) }
        let total = max(0, a.size) + extra.reduce(0) { $0 + $1.size }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID).first {
            let q = NSAlert()
            q.messageText = "\(a.name) právě běží"
            q.informativeText = "Před odinstalací se aplikace ukončí."
            q.addButton(withTitle: "Ukončit a pokračovat"); q.addButton(withTitle: "Zrušit")
            guard q.runModal() == .alertFirstButtonReturn else { return }
            running.terminate()
        }
        let c = NSAlert()
        c.alertStyle = .warning
        c.messageText = "Odinstalovat \(a.name) (\(Fmt.bytes(total)))?"
        c.informativeText = "Do Koše se přesune aplikace a \(extra.count) souvisejících položek (nastavení, mezipaměti, data). Dokud nevysypeš Koš, lze vše vrátit."
            + "\n\nAplikace s vlastním odinstalátorem (např. ovladače, VPN, antiviry) raději odinstaluj jejich nástrojem – mohou mít i systémové součásti."
        c.addButton(withTitle: "Odinstalovat"); c.addButton(withTitle: "Zrušit")
        guard c.runModal() == .alertFirstButtonReturn else { return }
        let list = [(a.url, max(0, a.size))] + extra.map { ($0.url, $0.size) }
        Task.detached {
            try? await Task.sleep(nanoseconds: 800_000_000)                 // čas na ukončení aplikace
            let r = CleanFS.remove(list)
            await MainActor.run {
                if r.done.contains(a.url) { self.apps.removeAll { $0.url == a.url }; self.selected = nil }
                else { self.related.removeAll { r.done.contains($0.url) } }
                SidebarModel.shared.reloadVolumes()
                CleanFS.report("Odinstalace \(a.name)", freed: r.freed, errors: r.errors)
            }
        }
    }

    /// Zbytky po už smazaných aplikacích: položky pojmenované bundle ID, ke kterému není nainstalovaná aplikace.
    func scanOrphans() {
        running = true; status = "Hledám zbytky po smazaných aplikacích…"; orphans = []; checkedOrphans = []
        Task.detached(priority: .userInitiated) {
            let re = try! NSRegularExpression(pattern: #"^([A-Z0-9]{10}\.)?([a-z0-9-]+\.[a-z0-9-]+\.[A-Za-z0-9._-]+?)(\.plist|\.savedState|\.binarycookies)?$"#, options: [.caseInsensitive])
            var installed: [String: Bool] = [:]
            var found: [JunkItem] = []
            for (dir, _) in UninstallModel.libraryDirs {
                for u in CleanFS.children(CleanFS.expand(dir)) {
                    let n = u.lastPathComponent
                    guard let m = re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                          let r = Range(m.range(at: 2), in: n) else { continue }
                    let bid = String(n[r])
                    let low = bid.lowercased()
                    if low.hasPrefix("com.apple.") || low.hasPrefix("group.com.apple") || low.contains("apple") || low.hasPrefix("cz.local.") { continue }
                    if low.hasPrefix("group.") { continue }                          // sdílené skupiny – nejisté přiřazení
                    let ok: Bool
                    if let cached = installed[low] { ok = cached }
                    else {
                        // nainstalovaná = známá Launch Services (i přes prefix: com.firma.app.helper → com.firma.app)
                        var parts = bid.split(separator: ".").map(String.init), hit = false
                        while parts.count >= 2 && !hit {
                            hit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) != nil
                            parts.removeLast()
                        }
                        ok = hit; installed[low] = hit
                    }
                    if ok { continue }
                    let s = CleanFS.size(u)
                    guard s > 0 else { continue }
                    found.append(JunkItem(url: u, size: s, note: dir.replacingOccurrences(of: "~/Library/", with: "") + " / " + n))
                }
            }
            let res = found.sorted { $0.size > $1.size }
            await MainActor.run {
                self.orphans = res
                self.running = false
                self.status = "\(res.count) pravděpodobných zbytků, \(Fmt.bytes(res.reduce(0) { $0 + $1.size }))"
            }
        }
    }

    func trashOrphans() {
        let chosen = orphans.filter { checkedOrphans.contains($0.id) }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "Přesunout do Koše \(chosen.count) zbytků (\(Fmt.bytes(chosen.reduce(0) { $0 + $1.size })))?"
        a.informativeText = "Rozpoznání zbytků je odhad podle bundle ID – zkontroluj seznam. Vše jde vrátit z Koše."
        a.addButton(withTitle: "Do Koše"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let list = chosen.map { ($0.url, $0.size) }
        Task.detached {
            let r = CleanFS.remove(list)
            await MainActor.run {
                self.orphans.removeAll { r.done.contains($0.url) }
                self.checkedOrphans.subtract(r.done)
                CleanFS.report("Zbytky aplikací", freed: r.freed, errors: r.errors)
            }
        }
    }
}

// MARK: - Mapa disku

struct LensNode: Identifiable, Hashable {
    let url: URL
    let name: String
    var size: Int64
    let isDir: Bool
    var id: URL { url }
}

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published var path: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    @Published var nodes: [LensNode] = []
    @Published var running = false
    @Published var hover: URL?
    @Published var selection: URL?
    private var cache: [URL: [LensNode]] = [:]
    private var cancel = Box(false)

    var current: URL { path.last! }
    var total: Int64 { nodes.reduce(0) { $0 + $1.size } }

    func open(_ u: URL) {
        if let i = path.firstIndex(of: u) { path = Array(path.prefix(i + 1)) } else { path.append(u) }
        load()
    }
    func setRoot(_ u: URL) { path = [u]; cache = [:]; load() }
    func up() { if path.count > 1 { path.removeLast(); load() } }

    func load(force: Bool = false) {
        cancel.value = true
        let c = Box(false); cancel = c
        let dir = current
        selection = nil
        if !force, let cached = cache[dir] { nodes = cached; running = false; return }
        nodes = []; running = true
        Task.detached(priority: .userInitiated) {
            let kids = CleanFS.children(dir).filter { $0.lastPathComponent != ".DS_Store" }
            var list: [LensNode] = kids.map { u in
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
                return LensNode(url: u, name: FileManager.default.displayName(atPath: u.path), size: 0, isDir: isDir)
            }
            await MainActor.run { if self.current == dir { self.nodes = list } }
            for i in list.indices {
                if c.value { return }
                list[i].size = CleanFS.size(list[i].url, cancel: c)
                let snap = list.sorted { $0.size > $1.size }
                if i % 3 == 0 || i == list.count - 1 {
                    await MainActor.run { if self.current == dir { self.nodes = snap } }
                }
            }
            let final = list.filter { $0.size > 0 }.sorted { $0.size > $1.size }
            await MainActor.run {
                self.cache[dir] = final
                if self.current == dir { self.nodes = final; self.running = false }
            }
        }
    }

    func trash(_ n: LensNode) {
        guard !CleanFS.isProtected(n.url.path) else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "Přesunout „\(n.name)“ (\(Fmt.bytes(n.size))) do Koše?"
        a.addButton(withTitle: "Do Koše"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let r = CleanFS.remove([(n.url, n.size)])
        if !r.done.isEmpty {
            nodes.removeAll { $0.url == n.url }
            for u in path { cache[u] = nil }
            cache[current] = nodes
        } else { CleanFS.report("Nepodařilo se", freed: 0, errors: r.errors) }
    }
}

/// Squarified treemap: obdélníky s poměrem stran blízko 1.
enum Treemap {
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        guard !sizes.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        var result = [CGRect](repeating: .zero, count: sizes.count)
        var r = rect
        var i = 0
        while i < sizes.count {
            let short = Double(min(r.width, r.height))
            var row: [Int] = [i]
            var rowSum = sizes[i] * scale
            func worst(_ idx: [Int], _ sum: Double) -> Double {
                let mx = idx.map { sizes[$0] * scale }.max() ?? 0, mn = idx.map { sizes[$0] * scale }.min() ?? 0
                guard sum > 0, mn > 0 else { return .infinity }
                return max(short * short * mx / (sum * sum), (sum * sum) / (short * short * mn))
            }
            var j = i + 1
            while j < sizes.count {
                let ns = rowSum + sizes[j] * scale
                if worst(row + [j], ns) <= worst(row, rowSum) { row.append(j); rowSum = ns; j += 1 } else { break }
            }
            let thick = CGFloat(rowSum / short)
            var off: CGFloat = 0
            for k in row {
                let len = CGFloat(sizes[k] * scale) / max(thick, 0.0001)
                if r.width >= r.height {
                    result[k] = CGRect(x: r.minX, y: r.minY + off, width: thick, height: len)
                } else {
                    result[k] = CGRect(x: r.minX + off, y: r.minY, width: len, height: thick)
                }
                off += len
            }
            if r.width >= r.height { r = CGRect(x: r.minX + thick, y: r.minY, width: r.width - thick, height: r.height) }
            else { r = CGRect(x: r.minX, y: r.minY + thick, width: r.width, height: r.height - thick) }
            i = j
        }
        return result
    }
}

// MARK: - Duplicity

struct DupFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: URL { url }
}

struct DupGroup: Identifiable {
    let id = UUID()
    let files: [DupFile]
    var wasted: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var minSizeMB = 1
    @Published var groups: [DupGroup] = []
    @Published var checked = Set<URL>()
    @Published var running = false
    @Published var scanned = false
    @Published var status = ""
    private var cancel = Box(false)

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var checkedSize: Int64 { groups.flatMap(\.files).filter { checked.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        cancel.value = true
        let c = Box(false); cancel = c
        groups = []; checked = []; running = true; status = "Procházím soubory…"
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        let minBytes = max(102_400, Int64(minSizeMB) * 1_048_576)
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .ubiquitousItemDownloadingStatusKey]
            let libPath = CleanFS.home + "/Library"
            var bySize: [Int64: [DupFile]] = [:]
            let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                   options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true })
            var n = 0
            while let u = e?.nextObject() as? URL {
                if c.value { break }
                n += 1
                let p = u.path
                if CleanFS.isProtected(p) || p == libPath || p.hasPrefix(libPath + "/") { e?.skipDescendants(); continue }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                if let st = v.ubiquitousItemDownloadingStatus, st != .current { continue }
                let s = Int64(v.fileSize ?? 0)
                guard s >= minBytes else { continue }
                bySize[s, default: []].append(DupFile(url: u, size: s, modified: v.contentModificationDate ?? .distantPast))
                if n % 2000 == 0 { let k = n; await MainActor.run { guard self.cancel === c else { return }; self.status = "Prošlo \(k) položek…" } }
            }
            // stejná velikost → hash prvních 64 kB → hash celého souboru
            let candidates = bySize.values.filter { $0.count > 1 }
            var result: [DupGroup] = []
            var done = 0
            for same in candidates {
                if c.value { break }
                var byHead: [String: [DupFile]] = [:]
                for f in same { if let h = CleanFS.hash(f.url, limit: 65_536) { byHead[h, default: []].append(f) } }
                for g in byHead.values where g.count > 1 {
                    var byFull: [String: [DupFile]] = [:]
                    for f in g { if c.value { break }; if let h = CleanFS.hash(f.url) { byFull[h, default: []].append(f) } }
                    for d in byFull.values where d.count > 1 {
                        result.append(DupGroup(files: d.sorted { $0.modified > $1.modified }))       // nejnovější první
                    }
                }
                done += 1
                if done % 20 == 0 {
                    let k = done, total = candidates.count
                    await MainActor.run { guard self.cancel === c else { return }; self.status = "Porovnávám obsah \(k) / \(total)…" }
                }
            }
            let res = result.sorted { $0.wasted > $1.wasted }
            await MainActor.run { guard self.cancel === c else { return };
                self.groups = res
                self.autoSelect(keepNewest: true)
                self.running = false; self.scanned = true
                self.status = (c.value ? "Zastaveno · " : "") + "\(res.count) skupin duplicit, zbytečně \(Fmt.bytes(self.wasted))"
            }
        }
    }

    func stop() { cancel.value = true; running = false }

    /// V každé skupině ponechá jeden soubor (nejnovější / nejstarší), ostatní označí.
    func autoSelect(keepNewest: Bool) {
        var s = Set<URL>()
        for g in groups {
            let keep = keepNewest ? g.files.first : g.files.last
            for f in g.files where f.url != keep?.url { s.insert(f.url) }
        }
        checked = s
    }

    func toggle(_ f: DupFile, in g: DupGroup) {
        if checked.contains(f.id) { checked.remove(f.id); return }
        // aspoň jedna kopie musí zůstat
        let others = g.files.filter { $0.id != f.id && !checked.contains($0.id) }
        if others.isEmpty { NSSound.beep(); return }
        checked.insert(f.id)
    }

    func trashChecked() {
        let chosen = groups.flatMap(\.files).filter { checked.contains($0.id) }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        for g in groups where g.files.allSatisfy({ checked.contains($0.id) }) {
            CleanFS.report("Ve skupině musí zůstat aspoň jedna kopie", freed: 0, errors: [g.files[0].url.lastPathComponent], trash: false); return
        }
        let a = NSAlert()
        a.messageText = "Přesunout do Koše \(chosen.count) duplicit (\(Fmt.bytes(checkedSize)))?"
        a.informativeText = "V každé skupině zůstane aspoň jedna kopie. Vše jde vrátit z Koše."
        a.addButton(withTitle: "Do Koše"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let list = chosen.map { ($0.url, $0.size) }
        Task.detached {
            let r = CleanFS.remove(list)
            await MainActor.run {
                let done = Set(r.done)
                self.groups = self.groups.map { DupGroup(files: $0.files.filter { !done.contains($0.url) }) }.filter { $0.files.count > 1 }
                self.checked.subtract(done)
                Commander.shared.refreshAll(); SidebarModel.shared.reloadVolumes()
                CleanFS.report("Duplicity", freed: r.freed, errors: r.errors)
            }
        }
    }
}
