import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Boční panel: Zařízení (svazky s volným místem, vysunutí), Oblíbené (vlastní složky) a Servery.
// Kliknutí otevře místo v aktivním panelu. Skrytí: tlačítko v liště nebo ⌃⌘S.

struct SidebarVolume: Identifiable {
    let url: URL
    let name: String
    let symbol: String
    let free: Int64
    let ejectable: Bool
    var id: URL { url }
}

@MainActor
final class SidebarModel: ObservableObject {
    static let shared = SidebarModel()
    @Published private(set) var volumes: [SidebarVolume] = []
    @Published private(set) var favorites: [URL] = []
    @Published var ejecting: URL?
    /// Sbalené složky serverů (cesta skupiny, např. „Zákazník A/Praha“).
    @Published private(set) var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebarCollapsed") ?? [])

    func toggleFolder(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
        UserDefaults.standard.set(Array(collapsed), forKey: "sidebarCollapsed")
    }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "sidebarFavorites")
        if let saved {
            favorites = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            let fm = FileManager.default
            favorites = [fm.homeDirectoryForCurrentUser]
                + [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
                    .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
                + [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        }
        reloadVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SidebarModel.shared.reloadVolumes() }
            }
        }
    }

    func reloadVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
                                      .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let network = v?.volumeIsLocal == false
            let external = v?.volumeIsRemovable == true || v?.volumeIsInternal == false
            let root = v?.volumeIsRootFileSystem == true
            return SidebarVolume(url: u, name: v?.volumeName ?? u.lastPathComponent,
                                 symbol: network ? "network" : external ? "externaldrive" : "internaldrive",
                                 free: Int64(v?.volumeAvailableCapacityForImportantUsage ?? 0),
                                 ejectable: !root && (v?.volumeIsEjectable == true || v?.volumeIsRemovable == true || network || external))
        }
    }

    private func saveFavorites() { UserDefaults.standard.set(favorites.map(\.path), forKey: "sidebarFavorites") }

    func addFavorite(_ u: URL) {
        let d = u.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { NSSound.beep(); return }
        guard !favorites.contains(where: { $0.standardizedFileURL == d }) else { return }
        favorites.append(d); saveFavorites()
    }
    func removeFavorite(_ u: URL) { favorites.removeAll { $0 == u }; saveFavorites() }
    func moveFavorite(_ u: URL, by delta: Int) {
        guard let i = favorites.firstIndex(of: u) else { return }
        let j = i + delta
        guard favorites.indices.contains(j) else { return }
        favorites.swapAt(i, j); saveFavorites()
    }

    /// Vysune svazek; panely, které na něm stojí, se nejdřív přesunou domů (jinak by byl „používaný“).
    func eject(_ v: SidebarVolume) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for p in [Commander.shared.left, Commander.shared.right] {
            for t in p.tabs where t.dir.path == v.url.path || t.dir.path.hasPrefix(v.url.path + "/") {
                if t.archive != nil || t.remote != nil { t.disconnectRemote() }
                t.go(home)
            }
        }
        ejecting = v.url
        let url = v.url
        Task.detached {
            var msg: String?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch let err { msg = err.localizedDescription }
            await MainActor.run {
                SidebarModel.shared.ejecting = nil
                SidebarModel.shared.reloadVolumes()
                if let msg {
                    let a = NSAlert()
                    a.messageText = "„\(v.name)“ nejde vysunout"
                    a.informativeText = msg + "\n\nSvazek nejspíš používá jiná aplikace."
                    a.runModal()
                }
            }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var commander: Commander
    @ObservedObject var model = SidebarModel.shared
    @ObservedObject var remotes = RemoteStore.shared
    @ObservedObject var tab: PanelTab

    private func open(_ u: URL) { commander.tab.go(u); commander.focus(commander.activeSide) }
    private func isCurrent(_ u: URL) -> Bool { tab.remote == nil && tab.archive == nil && tab.results == nil && tab.dir.standardizedFileURL == u.standardizedFileURL }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header("Zařízení")
                ForEach(model.volumes) { v in
                    row(symbol: v.symbol, title: v.name, detail: Fmt.bytes(v.free), current: isCurrent(v.url)) { open(v.url) }
                        .overlay(alignment: .trailing) {
                            if v.ejectable {
                                Button { model.eject(v) } label: {
                                    if model.ejecting == v.url { ProgressView().controlSize(.mini) }
                                    else { Image(systemName: "eject").font(.system(size: 11)) }
                                }
                                .buttonStyle(.plain).foregroundStyle(UI.textSecondary)
                                .padding(.trailing, 8)
                                .tip("Vysunout „\(v.name)“")
                            }
                        }
                        .tip("\(v.url.path) · volné \(Fmt.bytes(v.free))")
                }
                HStack {
                    header("Oblíbené")
                    Spacer()
                    Button { addCurrent() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(UI.textSecondary).padding(.trailing, 8).padding(.top, 10)
                        .tip("Přidat složku aktivního panelu (nebo sem přetáhni složku)")
                }
                ForEach(model.favorites, id: \.self) { u in
                    row(symbol: symbol(for: u), title: name(for: u), detail: nil, current: isCurrent(u)) { open(u) }
                        .tip(u.path)
                        .contextMenu {
                            Button("Otevřít v druhém panelu") { commander.other.tab.go(u) }
                            Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            Divider()
                            Button("Posunout nahoru") { model.moveFavorite(u, by: -1) }
                            Button("Posunout dolů") { model.moveFavorite(u, by: 1) }
                            Divider()
                            Button("Odebrat z Oblíbených") { model.removeFavorite(u) }
                        }
                }
                if !remotes.configs.isEmpty {
                    header("Servery")
                    ForEach(ServerTree.rows(remotes.configs, collapsed: model.collapsed)) { r in
                        switch r.kind {
                        case .folder(let path, let name, let count):
                            let open = !model.collapsed.contains(path)
                            Button { model.toggleFolder(path) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                                        .foregroundStyle(UI.textTertiary)
                                    Image(systemName: open ? "folder" : "folder.fill").font(.system(size: 11.5))
                                        .foregroundStyle(UI.accent)
                                    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.textSecondary).lineLimit(1)
                                    Text("\(count)").font(.system(size: 10)).foregroundStyle(UI.textTertiary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 8 + CGFloat(r.depth) * 14).padding(.trailing, 8).frame(height: 24)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tip(path)
                        case .server(let c):
                            let on = tab.remote?.session.config.id == c.id
                            row(symbol: c.proto == "smb" ? "externaldrive.connected.to.line.below" : "server.rack", title: c.title, detail: c.proto.uppercased(), current: on) {
                                commander.tab.connect(c); commander.focus(commander.activeSide)
                            }
                            .padding(.leading, CGFloat(r.depth) * 14 + (r.depth > 0 ? 10 : 0))
                            .tip("\(c.scheme)://\(c.dest):\(c.port)")
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .background(UI.sidebar)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { SidebarModel.shared.addFavorite(url) } }
                }
            }
            return true
        }
        .onAppear { model.reloadVolumes() }
    }

    private func addCurrent() {
        guard commander.tab.remote == nil, commander.tab.archive == nil else { NSSound.beep(); return }
        model.addFavorite(commander.tab.dir)
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(UI.textTertiary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
    }

    private func row(symbol: String, title: String, detail: String?, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(current ? UI.accent : UI.textSecondary)
                Text(title).font(.system(size: 12.5, weight: current ? .semibold : .regular))
                    .foregroundStyle(UI.text).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(UI.textTertiary).lineLimit(1).layoutPriority(1)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? UI.rowSelected : SwiftUI.Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func name(for u: URL) -> String {
        let fm = FileManager.default
        if u.path == fm.homeDirectoryForCurrentUser.path { return "Domů" }
        let known: [(FileManager.SearchPathDirectory, String)] = [(.desktopDirectory, "Plocha"), (.documentDirectory, "Dokumenty"), (.downloadsDirectory, "Stažené")]
        for (d, n) in known where fm.urls(for: d, in: .userDomainMask).first?.path == u.path { return n }
        if u.path == "/Applications" { return "Aplikace" }
        return fm.displayName(atPath: u.path)
    }

    private func symbol(for u: URL) -> String {
        let fm = FileManager.default
        if u.path == fm.homeDirectoryForCurrentUser.path { return "house" }
        if fm.urls(for: .desktopDirectory, in: .userDomainMask).first?.path == u.path { return "menubar.dock.rectangle" }
        if fm.urls(for: .documentDirectory, in: .userDomainMask).first?.path == u.path { return "doc" }
        if fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path == u.path { return "arrow.down.circle" }
        if u.path == "/Applications" { return "square.grid.2x2" }
        return "folder"
    }
}

/// Servery ve stromu složek podle skupiny („Zákazník A/Praha“ = podsložka), jako v SSHTool.
enum ServerTree {
    enum Kind { case folder(path: String, name: String, count: Int), server(RemoteConfig) }
    struct Row: Identifiable {
        let id: String
        let depth: Int
        let kind: Kind
    }

    static func parts(_ c: RemoteConfig) -> [String] {
        (c.group ?? "").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Viditelné řádky: složky (abecedně) před servery, obsah sbalených složek se vynechá.
    static func rows(_ configs: [RemoteConfig], collapsed: Set<String>) -> [Row] {
        var out: [Row] = []
        func walk(_ prefix: [String]) {
            let inHere = configs.filter { Array(parts($0).prefix(prefix.count)) == prefix }
            let sub = Set(inHere.compactMap { c -> String? in let p = parts(c); return p.count > prefix.count ? p[prefix.count] : nil })
            for name in sub.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let path = (prefix + [name]).joined(separator: "/")
                let count = inHere.filter { Array(parts($0).prefix(prefix.count + 1)) == prefix + [name] }.count
                out.append(Row(id: "f:" + path, depth: prefix.count, kind: .folder(path: path, name: name, count: count)))
                if !collapsed.contains(path) { walk(prefix + [name]) }
            }
            for c in inHere where parts(c) == prefix {
                out.append(Row(id: "s:" + c.id.uuidString, depth: prefix.count, kind: .server(c)))
            }
        }
        walk([])
        return out
    }
}
