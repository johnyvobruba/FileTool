import SwiftUI
import AppKit

// Hromadné přejmenování (jako Multi-Rename v Total / Double Commanderu).
// Maska názvu a přípony se zástupnými znaky, čítač, hledat/nahradit (i regex), velikost písmen,
// náhled se zvýrazněním konfliktů, provedení ve dvou krocích (bezpečné i pro prohození názvů) a Zpět.

struct RenameRow: Identifiable {
    let id = UUID()
    let url: URL
    let modified: Date
    var newName = ""
    var problem: String?
    var old: String { url.lastPathComponent }
}

enum RenameCase: String, CaseIterable, Identifiable {
    case keep = "Beze změny", lower = "malá písmena", upper = "VELKÁ PÍSMENA", title = "První Velké", sentence = "První písmeno velké"
    var id: String { rawValue }
}

@MainActor
final class RenameModel: ObservableObject {
    @Published var nameMask = "[N]" { didSet { preview() } }
    @Published var extMask = "[E]" { didSet { preview() } }
    @Published var search = "" { didSet { preview() } }
    @Published var replace = "" { didSet { preview() } }
    @Published var regex = false { didSet { preview() } }
    @Published var caseMode: RenameCase = .keep { didSet { preview() } }
    @Published var counterStart = 1 { didSet { preview() } }
    @Published var counterStep = 1 { didSet { preview() } }
    @Published var counterDigits = 2 { didSet { preview() } }
    @Published var rows: [RenameRow] = []
    @Published var regexError: String?
    @Published var lastUndo: [(from: URL, to: URL)] = []
    let dir: URL

    init(items: [FileItem], dir: URL) {
        self.dir = dir
        rows = items.map { RenameRow(url: $0.url, modified: $0.modified) }
        preview()
    }

    var changes: Int { rows.filter { $0.newName != $0.old && $0.problem == nil }.count }
    var problems: Int { rows.filter { $0.problem != nil }.count }

    // MARK: Výpočet nových názvů

    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    private func expand(_ mask: String, name: String, ext: String, index: Int, row: RenameRow) -> String {
        var out = ""
        var i = mask.startIndex
        while i < mask.endIndex {
            guard mask[i] == "[", let close = mask[i...].firstIndex(of: "]") else { out.append(mask[i]); i = mask.index(after: i); continue }
            let tok = String(mask[mask.index(after: i)..<close])
            out += token(tok, name: name, ext: ext, index: index, row: row) ?? "[\(tok)]"
            i = mask.index(after: close)
        }
        return out
    }

    /// [N] název, [N2-5] / [N3] znaky názvu, [E] přípona, [C] čítač, [P] nadřazená složka,
    /// [Y] [M] [D] [h] [m] [s] datum změny, [YMD] = 20261124, [hms] = 143005.
    private func token(_ t: String, name: String, ext: String, index: Int, row: RenameRow) -> String? {
        func sub(_ s: String, _ spec: String) -> String? {
            let arr = Array(s)
            if spec.isEmpty { return s }
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            if parts.count == 1, let a = parts[0], a >= 1 { return a <= arr.count ? String(arr[a - 1]) : "" }
            if parts.count == 2, let a = parts[0], a >= 1 {
                let b = parts[1] ?? arr.count
                guard a <= arr.count else { return "" }
                return String(arr[(a - 1)..<min(max(a, b), arr.count)])
            }
            return nil
        }
        let d = row.modified
        func fmt(_ f: String) -> String { Self.df.dateFormat = f; return Self.df.string(from: d) }
        switch t {
        case "E": return ext
        case "C":
            let n = counterStart + index * counterStep
            return String(format: "%0\(max(1, min(counterDigits, 9)))ld", n)
        case "P": return row.url.deletingLastPathComponent().lastPathComponent
        case "Y": return fmt("yyyy")
        case "M": return fmt("MM")
        case "D": return fmt("dd")
        case "h": return fmt("HH")
        case "m": return fmt("mm")
        case "s": return fmt("ss")
        case "YMD": return fmt("yyyyMMdd")
        case "hms": return fmt("HHmmss")
        default:
            if t.hasPrefix("N") { return sub(name, String(t.dropFirst())) }
            if t.hasPrefix("E") { return sub(ext, String(t.dropFirst())) }
            return nil
        }
    }

    private func applyCase(_ s: String) -> String {
        switch caseMode {
        case .keep: return s
        case .lower: return s.lowercased()
        case .upper: return s.uppercased()
        case .title: return s.capitalized
        case .sentence: return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }
    }

    func preview() {
        regexError = nil
        var re: NSRegularExpression?
        if regex, !search.isEmpty {
            do { re = try NSRegularExpression(pattern: search) } catch { regexError = "Neplatný regulární výraz" }
        }
        for i in rows.indices {
            let r = rows[i]
            let isDir = (try? r.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let name = isDir ? r.old : (r.old as NSString).deletingPathExtension
            let ext = isDir ? "" : (r.old as NSString).pathExtension
            var base = expand(nameMask, name: name, ext: ext, index: i, row: r)
            var e = expand(extMask, name: name, ext: ext, index: i, row: r)
            var full = e.isEmpty ? base : base + "." + e
            if !search.isEmpty {
                if let re {
                    full = re.stringByReplacingMatches(in: full, range: NSRange(full.startIndex..., in: full), withTemplate: replace)
                } else if !regex {
                    full = full.replacingOccurrences(of: search, with: replace)
                }
            }
            // velikost písmen jen pro název (přípona zvlášť, aby .JPG → .jpg šlo maskou [E] / malými písmeny)
            if caseMode != .keep {
                let n = (full as NSString).deletingPathExtension, x = (full as NSString).pathExtension
                base = applyCase(n); e = caseMode == .keep ? x : (caseMode == .upper ? x.uppercased() : x.lowercased())
                full = e.isEmpty || isDir ? applyCase(full) : base + "." + e
            }
            rows[i].newName = full.trimmingCharacters(in: .whitespaces)
        }
        validate()
    }

    private func validate() {
        let fm = FileManager.default
        var seen: [String: Int] = [:]
        for r in rows { seen[r.newName.lowercased(), default: 0] += 1 }
        let olds = Set(rows.map { $0.old.lowercased() })
        for i in rows.indices {
            let n = rows[i].newName
            var p: String?
            if n.isEmpty { p = "prázdný název" }
            else if n.contains("/") || n.contains(":") { p = "obsahuje / nebo :" }
            else if n == "." || n == ".." { p = "neplatný název" }
            else if n.utf8.count > 255 { p = "příliš dlouhý" }
            else if (seen[n.lowercased()] ?? 0) > 1 { p = "stejný název víckrát" }
            else if n.lowercased() != rows[i].old.lowercased(), !olds.contains(n.lowercased()),
                    fm.fileExists(atPath: dir.appendingPathComponent(n).path) { p = "už existuje" }
            rows[i].problem = p
        }
    }

    // MARK: Provedení

    /// Dva kroky (dočasné názvy → cílové), takže projde i prohození a změna jen velikosti písmen.
    func run() -> String? {
        let todo = rows.filter { $0.newName != $0.old && $0.problem == nil }
        guard !todo.isEmpty else { return "Není co přejmenovat." }
        let fm = FileManager.default
        var temp: [(tmp: URL, row: RenameRow)] = []
        var done: [(from: URL, to: URL)] = []
        var errors: [String] = []
        for r in todo {
            let t = r.url.deletingLastPathComponent().appendingPathComponent(".ft-rename-\(UUID().uuidString.prefix(8))")
            do { try fm.moveItem(at: r.url, to: t); temp.append((t, r)) }
            catch let err { errors.append("\(r.old): \(err.localizedDescription)") }
        }
        for (t, r) in temp {
            let target = r.url.deletingLastPathComponent().appendingPathComponent(r.newName)
            do {
                if fm.fileExists(atPath: target.path) { throw NSError(domain: "FileTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "cíl už existuje"]) }
                try fm.moveItem(at: t, to: target); done.append((r.url, target))
            } catch let err {
                try? fm.moveItem(at: t, to: r.url)                     // vrátit původní název
                errors.append("\(r.old) → \(r.newName): \(err.localizedDescription)")
            }
        }
        lastUndo = done
        rows = rows.map { r in
            if let d = done.first(where: { $0.from == r.url }) { return RenameRow(url: d.to, modified: r.modified) }
            return r
        }
        preview()
        Commander.shared.refreshAll()
        return errors.isEmpty ? nil : errors.prefix(12).joined(separator: "\n")
    }

    func undo() {
        let fm = FileManager.default
        var errors: [String] = []
        for (from, to) in lastUndo.reversed() {
            do { try fm.moveItem(at: to, to: from) } catch let err { errors.append("\(to.lastPathComponent): \(err.localizedDescription)") }
        }
        rows = rows.map { r in
            if let d = lastUndo.first(where: { $0.to == r.url }) { return RenameRow(url: d.from, modified: r.modified) }
            return r
        }
        lastUndo = []
        preview()
        Commander.shared.refreshAll()
        if !errors.isEmpty { Commander.shared.alert("Zpět se nepovedlo u všech", errors.joined(separator: "\n")) }
    }
}

struct RenameView: View {
    @ObservedObject var m: RenameModel
    let close: () -> Void

    private let tokens: [(String, String)] = [
        ("[N]", "název"), ("[N1-3]", "znaky 1–3"), ("[E]", "přípona"), ("[C]", "čítač"), ("[P]", "složka"),
        ("[YMD]", "datum"), ("[hms]", "čas"), ("[Y]", "rok"), ("[M]", "měsíc"), ("[D]", "den"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Maska názvu").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                    HStack {
                        TextField("[N]", text: $m.nameMask).textFieldStyle(.roundedBorder).font(SK.monoFont)
                        Text(".").foregroundStyle(UI.textSecondary)
                        TextField("[E]", text: $m.extMask).textFieldStyle(.roundedBorder).font(SK.monoFont).frame(width: 90)
                    }
                    HStack(spacing: 4) {
                        ForEach(tokens, id: \.0) { t in
                            Button(t.0) { m.nameMask += t.0 }.font(.system(size: 10.5, design: .monospaced))
                                .tip("Vložit \(t.0) – \(t.1)")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Čítač [C]").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                    HStack {
                        Stepper("od \(m.counterStart)", value: $m.counterStart, in: 0...99999)
                        Stepper("krok \(m.counterStep)", value: $m.counterStep, in: 1...1000)
                        Stepper("číslic \(m.counterDigits)", value: $m.counterDigits, in: 1...9)
                    }
                    .font(.system(size: 11.5))
                }
            }
            HStack(spacing: 10) {
                Text("Hledat").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                TextField("", text: $m.search).textFieldStyle(.roundedBorder).font(SK.monoFont)
                Text("nahradit").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                TextField("", text: $m.replace).textFieldStyle(.roundedBorder).font(SK.monoFont)
                Toggle("Regex", isOn: $m.regex).toggleStyle(.checkbox)
                    .tip("Regulární výraz – v náhradě $1, $2… pro skupiny")
                Picker("", selection: $m.caseMode) { ForEach(RenameCase.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 170)
            }
            if let e = m.regexError { Text(e).font(SK.helpFont).foregroundStyle(UI.error) }
            Table(m.rows) {
                TableColumn("Původní název") { r in Text(r.old).lineLimit(1).truncationMode(.middle).foregroundStyle(UI.textSecondary) }
                TableColumn("Nový název") { r in
                    HStack(spacing: 5) {
                        if let p = r.problem {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.error).tip(p)
                        } else if r.newName != r.old {
                            Image(systemName: "arrow.right").foregroundStyle(UI.accent)
                        }
                        Text(r.newName).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(r.problem != nil ? UI.error : r.newName != r.old ? UI.text : UI.textTertiary)
                        if let p = r.problem { Text("– \(p)").font(.system(size: 10.5)).foregroundStyle(UI.error) }
                    }
                }
            }
            HStack {
                Text("Změní se \(m.changes) z \(m.rows.count)" + (m.problems > 0 ? " · \(m.problems) s problémem (přeskočí se)" : ""))
                    .font(SK.helpFont).foregroundStyle(m.problems > 0 ? UI.warn : UI.textSecondary)
                Spacer()
                if !m.lastUndo.isEmpty { Button("Zpět (\(m.lastUndo.count))") { m.undo() } }
                Button("Zavřít") { close() }.keyboardShortcut(.cancelAction)
                Button("Přejmenovat") {
                    if let err = m.run() { Commander.shared.alert("Přejmenování", err) }
                }
                .keyboardShortcut(.defaultAction).disabled(m.changes == 0)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 480)
        .background(UI.app)
    }
}

@MainActor
enum RenameWindow {
    private static var window: NSWindow?

    static func show(items: [FileItem], dir: URL) {
        window?.close()
        let m = RenameModel(items: items, dir: dir)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Hromadné přejmenování – \(items.count) položek"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RenameView(m: m) { w.close() }
            .preferredColorScheme(FTSettings.shared.isDark ? .dark : .light))
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

extension Commander {
    /// ⇧⌘M – hromadné přejmenování označených (nebo všech) položek aktivního panelu.
    func multiRename() {
        guard tab.remote == nil, tab.archive == nil, tab.results == nil else {
            alert("Hromadné přejmenování", "Funguje v místních složkách (ne na serveru, v archivu ani ve výsledcích hledání)."); return
        }
        var items = tab.items.filter { tab.marked.contains($0.url) }
        if items.isEmpty { items = tab.items.filter { !$0.isParent } }
        guard !items.isEmpty else { NSSound.beep(); return }
        RenameWindow.show(items: items, dir: tab.dir)
    }
}
