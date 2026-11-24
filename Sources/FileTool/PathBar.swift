import SwiftUI
import AppKit

// Cesta jako klikací „drobečky“: klik na část = přejít tam, dvojklik kamkoli = zkopírovat celou cestu,
// tužka (⌘L) = ruční úprava cesty v textovém poli.

struct PathSegment: Identifiable {
    let id: Int
    let title: String
    let symbol: String
    let go: @MainActor () -> Void
}

@MainActor
final class PathBarModel: ObservableObject {
    @Published var editing = false
    @Published var copied = false

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self.copied = false }
    }
}

struct PathBar: View {
    @ObservedObject var tab: PanelTab
    let side: Side
    let commander: Commander
    let active: Bool
    @StateObject private var m = PathBarModel()

    private var fg: SwiftUI.Color { active ? .white : UI.textSecondary }

    /// Části cesty podle toho, co panel ukazuje (složka / archiv / server / výsledky hledání).
    private var segments: [PathSegment] {
        var out: [PathSegment] = []
        func add(_ t: String, _ s: String, _ g: @escaping @MainActor () -> Void) { out.append(PathSegment(id: out.count, title: t, symbol: s, go: g)) }
        if let r = tab.results {
            add("Výsledky: \(r.title)", "magnifyingglass") { }
            return out
        }
        if let r = tab.remote {
            add(r.session.config.title, r.session.config.proto == "ftp" ? "tray" : "server.rack") { tab.goRemote("/") }
            var acc = ""
            for p in r.path.split(separator: "/").map(String.init) {
                acc += "/" + p
                let target = acc
                add(p, "folder") { tab.goRemote(target) }
            }
            return out
        }
        // místní složka (u archivu složka, ve které archiv leží)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = tab.dir.path
        var base = ""
        var rest: [String]
        if path == home || path.hasPrefix(home + "/") {
            base = home
            add(FileManager.default.displayName(atPath: home), "house") { tab.go(URL(fileURLWithPath: home, isDirectory: true)) }
            rest = String(path.dropFirst(home.count)).split(separator: "/").map(String.init)
        } else {
            let parts = path.split(separator: "/").map(String.init)
            if parts.first == "Volumes", parts.count >= 2 {
                base = "/Volumes/" + parts[1]
                let b = base
                add(parts[1], "externaldrive") { tab.go(URL(fileURLWithPath: b, isDirectory: true)) }
                rest = Array(parts.dropFirst(2))
            } else {
                add("/", "internaldrive") { tab.go(URL(fileURLWithPath: "/", isDirectory: true)) }
                rest = parts
            }
        }
        var acc = base
        for p in rest {
            acc += "/" + p
            let target = acc
            add(p, "folder") { tab.go(URL(fileURLWithPath: target, isDirectory: true)) }
        }
        if let a = tab.archive {
            let file = a.file
            add(file.lastPathComponent, "archivebox") { tab.goArchive("") }
            var inner = ""
            for p in a.inner.split(separator: "/").map(String.init) {
                inner += (inner.isEmpty ? "" : "/") + p
                let target = inner
                add(p, "folder") { tab.goArchive(target) }
            }
            _ = file
        }
        return out
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { tab.up(); commander.focus(side) } label: { Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(fg).tip("Nadřazená složka (⌫ / ⌘↑)")
            if m.editing {
                TextField("", text: $tab.pathField, onCommit: {
                    tab.submitPath(); m.editing = false; commander.focus(side)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(fg)
                .onExitCommand { tab.pathField = tab.displayPath; m.editing = false; commander.focus(side) }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(segments) { s in
                                if s.id > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(fg.opacity(0.6)) }
                                SegmentButton(segment: s, last: s.id == segments.count - 1, fg: fg) {
                                    s.go(); commander.focus(side)
                                } copy: { m.copy(tab.displayPath) }
                                .id(s.id)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .onAppear { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
                    .onChange(of: tab.displayPath) { _ in proxy.scrollTo(segments.count - 1, anchor: .trailing) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { m.copy(tab.displayPath) }
            }
            if m.copied {
                Label("Zkopírováno", systemImage: "checkmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(fg)
                    .transition(.opacity)
            }
            Button {
                tab.pathField = tab.displayPath
                m.editing.toggle()
            } label: { Image(systemName: m.editing ? "xmark" : "pencil").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(fg)
                .tip(m.editing ? "Zrušit úpravu (Esc)" : "Upravit cestu ručně (⌘L)")
            Button { m.copy(tab.displayPath) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10.5)) }
                .buttonStyle(.plain).foregroundStyle(fg).tip("Zkopírovat celou cestu (nebo dvojklik na cestu)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileToolEditPath)) { n in
            guard (n.object as? String) == side.rawValue else { return }
            tab.pathField = tab.displayPath; m.editing = true
        }
    }
}

private struct SegmentButton: View {
    let segment: PathSegment
    let last: Bool
    let fg: SwiftUI.Color
    let go: () -> Void
    let copy: () -> Void
    @StateObject private var hover = HoverModel()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: segment.symbol).font(.system(size: 10.5))
            Text(segment.title).font(.system(size: 11.5, weight: last ? .semibold : .medium)).lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(fg.opacity(hover.on ? 0.18 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(count: 2) { copy() }
        .onTapGesture { go() }
        .tip(last ? "Dvojklik = zkopírovat celou cestu" : "Přejít sem · dvojklik = zkopírovat celou cestu")
    }
}

extension Notification.Name {
    static let fileToolEditPath = Notification.Name("FileToolEditPath")
}
