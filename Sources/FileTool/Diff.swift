import SwiftUI
import AppKit

// Porovnání dvou textových souborů (diff) vedle sebe: přidané / odebrané / změněné řádky,
// skok na další rozdíl, volitelně ignorovat mezery a velikost písmen. Externí nástroj na přání
// (FileMerge – opendiff z Xcode, VS Code, BBEdit).

struct DiffLine: Identifiable {
    enum Kind { case same, added, removed, changed }
    let id: Int
    let kind: Kind
    let left: String?
    let right: String?
    let leftNo: Int?
    let rightNo: Int?
}

@MainActor
final class DiffModel: ObservableObject {
    let leftURL: URL
    let rightURL: URL
    @Published var lines: [DiffLine] = []
    @Published var ignoreSpace = false { didSet { compute() } }
    @Published var ignoreCase = false { didSet { compute() } }
    @Published var onlyChanges = false
    @Published var current = 0
    @Published var error: String?
    private var a: [String] = []
    private var b: [String] = []

    init(left: URL, right: URL) {
        leftURL = left; rightURL = right
        load()
    }

    var stats: (added: Int, removed: Int, changed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count, lines.filter { $0.kind == .changed }.count)
    }
    /// Začátky bloků rozdílů (pro skok na další / předchozí).
    var hunks: [Int] {
        var out: [Int] = []
        for (i, l) in lines.enumerated() where l.kind != .same && (i == 0 || lines[i - 1].kind == .same) { out.append(l.id) }
        return out
    }
    var shown: [DiffLine] { onlyChanges ? lines.filter { $0.kind != .same } : lines }

    static func readText(_ u: URL) throws -> [String] {
        let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
        if let s = attrs[.size] as? NSNumber, s.intValue > 20_000_000 { throw DiffError("„\(u.lastPathComponent)“ je větší než 20 MB.") }
        let d = try Data(contentsOf: u)
        if d.prefix(8192).contains(0) { throw DiffError("„\(u.lastPathComponent)“ není textový soubor.") }
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1250) ?? String(decoding: d, as: UTF8.self)
        var l = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        return l
    }

    struct DiffError: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }

    func load() {
        do { a = try Self.readText(leftURL); b = try Self.readText(rightURL); compute() }
        catch let err { error = err.localizedDescription }
    }

    private func norm(_ s: String) -> String {
        var x = s
        if ignoreSpace { x = x.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if ignoreCase { x = x.lowercased() }
        return x
    }

    /// Myersův diff (CollectionDifference) → zarovnané řádky; odebrané + přidané vedle sebe = změněné.
    func compute() {
        let na = a.map(norm), nb = b.map(norm)
        let diff = nb.difference(from: na)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0, id = 0
        func push(_ k: DiffLine.Kind, _ l: Int?, _ r: Int?) {
            out.append(DiffLine(id: id, kind: k, left: l.map { a[$0] }, right: r.map { b[$0] },
                                leftNo: l.map { $0 + 1 }, rightNo: r.map { $0 + 1 }))
            id += 1
        }
        while i < a.count || j < b.count {
            var rem: [Int] = [], ins: [Int] = []
            while i < a.count, removed.contains(i) { rem.append(i); i += 1 }
            while j < b.count, inserted.contains(j) { ins.append(j); j += 1 }
            if !rem.isEmpty || !ins.isEmpty {
                let n = max(rem.count, ins.count)
                for k in 0..<n {
                    let l = k < rem.count ? rem[k] : nil, r = k < ins.count ? ins[k] : nil
                    push(l != nil && r != nil ? .changed : l != nil ? .removed : .added, l, r)
                }
                continue
            }
            if i < a.count, j < b.count { push(.same, i, j); i += 1; j += 1 }
            else if i < a.count { push(.removed, i, nil); i += 1 }
            else if j < b.count { push(.added, nil, j); j += 1 }
        }
        lines = out
        current = hunks.first ?? 0
        error = nil
    }

    func next(_ d: Int) {
        let h = hunks
        guard !h.isEmpty else { NSSound.beep(); return }
        if d > 0 { current = h.first(where: { $0 > current }) ?? h[0] }
        else { current = h.last(where: { $0 < current }) ?? h[h.count - 1] }
    }

    /// Externí nástroj: FileMerge (opendiff, s Xcode), VS Code nebo BBEdit, pokud jsou nainstalované.
    static var externalTools: [(name: String, exe: String, args: [String])] {
        var t: [(String, String, [String])] = []
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/opendiff"),
           FileManager.default.fileExists(atPath: "/Applications/Xcode.app") { t.append(("FileMerge", "/usr/bin/opendiff", [])) }
        for (name, path) in [("Visual Studio Code", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
                             ("BBEdit", "/usr/local/bin/bbdiff"), ("BBEdit", "/opt/homebrew/bin/bbdiff")]
            where FileManager.default.isExecutableFile(atPath: path) {
            t.append((name, path, name == "Visual Studio Code" ? ["--diff"] : []))
        }
        return t.map { (name: $0.0, exe: $0.1, args: $0.2) }
    }

    func openExternal(_ tool: (name: String, exe: String, args: [String])) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool.exe)
        p.arguments = tool.args + [leftURL.path, rightURL.path]
        p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        try? p.run()
    }
}

struct DiffView: View {
    @ObservedObject var m: DiffModel

    private func bg(_ k: DiffLine.Kind, left: Bool) -> SwiftUI.Color {
        switch k {
        case .same: return .clear
        case .added: return left ? UI.card.opacity(0.4) : UI.ok.opacity(0.22)
        case .removed: return left ? UI.error.opacity(0.22) : UI.card.opacity(0.4)
        case .changed: return UI.warn.opacity(0.22)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(m.leftURL.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .tip(m.leftURL.path)
                Text(m.rightURL.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .tip(m.rightURL.path)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(UI.chrome)
            if let e = m.error {
                Text(e).foregroundStyle(UI.error).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(m.shown) { l in
                                HStack(spacing: 0) {
                                    cell(l.leftNo, l.left, bg(l.kind, left: true))
                                    Rectangle().fill(UI.border).frame(width: 1)
                                    cell(l.rightNo, l.right, bg(l.kind, left: false))
                                }
                                .overlay(alignment: .leading) {
                                    if l.id == m.current { Rectangle().fill(UI.accent).frame(width: 3) }
                                }
                                .id(l.id)
                            }
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                    .onChange(of: m.current) { c in withAnimation { proxy.scrollTo(c, anchor: .center) } }
                    .onAppear { proxy.scrollTo(m.current, anchor: .center) }
                }
                .background(UI.surface)
            }
            HStack(spacing: 12) {
                let s = m.stats
                Label("\(s.added)", systemImage: "plus").foregroundStyle(UI.ok).tip("Přidané řádky")
                Label("\(s.removed)", systemImage: "minus").foregroundStyle(UI.error).tip("Odebrané řádky")
                Label("\(s.changed)", systemImage: "pencil").foregroundStyle(UI.warn).tip("Změněné řádky")
                if s.added + s.removed + s.changed == 0, m.error == nil {
                    Label("Soubory jsou shodné", systemImage: "checkmark.circle.fill").foregroundStyle(UI.ok)
                }
                Spacer()
                Toggle("Jen rozdíly", isOn: $m.onlyChanges).toggleStyle(.checkbox)
                Toggle("Ignorovat mezery", isOn: $m.ignoreSpace).toggleStyle(.checkbox)
                Toggle("Ignorovat velikost písmen", isOn: $m.ignoreCase).toggleStyle(.checkbox)
                Button { m.next(-1) } label: { Image(systemName: "chevron.up") }.keyboardShortcut(.upArrow, modifiers: [.option]).tip("Předchozí rozdíl (⌥↑)")
                Button { m.next(1) } label: { Image(systemName: "chevron.down") }.keyboardShortcut(.downArrow, modifiers: [.option]).tip("Další rozdíl (⌥↓)")
                Button { m.load() } label: { Image(systemName: "arrow.clockwise") }.tip("Načíst soubory znovu")
                let tools = DiffModel.externalTools
                if !tools.isEmpty {
                    Menu("Otevřít v…") { ForEach(tools, id: \.exe) { t in Button(t.name) { m.openExternal(t) } } }
                        .fixedSize()
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12).padding(.vertical, 8).background(UI.chrome)
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    private func cell(_ no: Int?, _ text: String?, _ bg: SwiftUI.Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(no.map(String.init) ?? "").foregroundStyle(UI.textTertiary).frame(width: 44, alignment: .trailing)
            Text(text ?? "").foregroundStyle(UI.text).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1).padding(.trailing, 8)
        .frame(minWidth: 440, maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }
}

@MainActor
enum DiffWindow {
    private static var windows: [NSWindow] = []

    static func show(_ a: URL, _ b: URL) {
        let m = DiffModel(left: a, right: b)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Porovnání: \(a.lastPathComponent) ↔ \(b.lastPathComponent)"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DiffView(m: m).preferredColorScheme(FTSettings.shared.isDark ? .dark : .light))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { $0 === w } }
        }
        windows.append(w)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

extension Commander {
    /// ⇧⌘D – dva označené soubory v aktivním panelu, jinak soubor pod kurzorem vlevo × vpravo.
    func diffFiles() {
        func local(_ t: PanelTab) -> Bool { t.remote == nil && t.archive == nil }
        let marked = tab.items.filter { tab.marked.contains($0.url) && !$0.isDir }
        var pair: (URL, URL)?
        if marked.count == 2, local(tab) { pair = (marked[0].url, marked[1].url) }
        else if let l = left.tab.current, let r = right.tab.current, !l.isDir, !r.isDir, !l.isParent, !r.isParent,
                local(left.tab), local(right.tab) { pair = (l.url, r.url) }
        guard let (a, b) = pair else {
            alert("Porovnání souborů", "Označ dva soubory v jednom panelu, nebo dej kurzor na soubor v levém i pravém panelu.\n(Soubory ze serveru nebo z archivu nejdřív zkopíruj.)")
            return
        }
        DiffWindow.show(a, b)
    }
}
