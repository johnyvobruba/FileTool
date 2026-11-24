import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// Kontrolní součty (jako „Vytvořit / ověřit kontrolní součty“ v TC): MD5, SHA-1, SHA-256, SHA-512.
// Výpočet po 1 MB (i obří soubory bez načtení do paměti), porovnání s vloženým otiskem,
// ověření podle souboru .md5 / .sha1 / .sha256 / .sha512 (formát md5sum / shasum), uložení na vyžádání.

enum HashAlgo: String, CaseIterable, Identifiable {
    case md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256", sha512 = "SHA-512"
    var id: String { rawValue }
    var ext: String { ["MD5": "md5", "SHA-1": "sha1", "SHA-256": "sha256", "SHA-512": "sha512"][rawValue]! }
    var hexLength: Int { ["MD5": 32, "SHA-1": 40, "SHA-256": 64, "SHA-512": 128][rawValue]! }
    static func from(ext: String) -> HashAlgo? { allCases.first { $0.ext == ext.lowercased() } }
    static func from(length: Int) -> HashAlgo? { allCases.first { $0.hexLength == length } }

    /// Otisk souboru po blocích; nil = soubor nejde číst nebo zrušeno.
    func hash(_ url: URL, cancel: Box<Bool>, progress: (Int64) -> Void) -> String? {
        switch self {
        case .md5: return run(Insecure.MD5(), url, cancel, progress)
        case .sha1: return run(Insecure.SHA1(), url, cancel, progress)
        case .sha256: return run(SHA256(), url, cancel, progress)
        case .sha512: return run(SHA512(), url, cancel, progress)
        }
    }

    private func run<H: HashFunction>(_ initial: H, _ url: URL, _ cancel: Box<Bool>, _ progress: (Int64) -> Void) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = initial
        var done: Int64 = 0
        while true {
            if cancel.value { return nil }
            guard let d = try? fh.read(upToCount: 1 << 20), !d.isEmpty else { break }
            h.update(data: d)
            done += Int64(d.count)
            progress(done)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct HashRow: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    var hash: String?
    var expected: String?          // z ověřovacího souboru
    var error: String?
    var name: String { url.lastPathComponent }
    var status: Bool? {             // nil = není s čím porovnat
        guard let e = expected else { return nil }
        guard let h = hash else { return false }
        return h.lowercased() == e.lowercased()
    }
}

@MainActor
final class ChecksumModel: ObservableObject {
    @Published var algo: HashAlgo { didSet { if oldValue != algo, !verifyMode { compute() } } }
    @Published var rows: [HashRow] = []
    @Published var compare = ""
    @Published var running = false
    @Published var progress: Double = 0
    @Published var status = ""
    let baseDir: URL
    let verifyMode: Bool
    let sourceFile: URL?
    private var cancel = Box(false)

    init(files: [URL], baseDir: URL, algo: HashAlgo) {
        self.baseDir = baseDir
        // jediný vybraný soubor .md5/.sha… = ověřit soubory podle něj
        if files.count == 1, let a = HashAlgo.from(ext: files[0].pathExtension) {
            verifyMode = true; sourceFile = files[0]; self.algo = a
            rows = Self.parseChecksumFile(files[0], algo: a)
        } else {
            verifyMode = false; sourceFile = nil; self.algo = algo
            rows = files.map { HashRow(url: $0, size: Self.size($0)) }
        }
        compute()
    }

    nonisolated static func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    /// Řádky „<hash>  <soubor>“ (md5sum/shasum, i s * pro binární režim) nebo „MD5 (soubor) = hash“ (macOS md5).
    nonisolated static func parseChecksumFile(_ f: URL, algo: HashAlgo) -> [HashRow] {
        guard let text = try? String(contentsOf: f, encoding: .utf8), text.utf8.count < 5_000_000 else { return [] }
        let dir = f.deletingLastPathComponent()
        var out: [HashRow] = []
        let bsd = try! NSRegularExpression(pattern: #"^[A-Z0-9-]+ \((.+)\) = ([0-9a-fA-F]+)$"#)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            var name = "", hash = ""
            if let m = bsd.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r1 = Range(m.range(at: 1), in: line), let r2 = Range(m.range(at: 2), in: line) {
                name = String(line[r1]); hash = String(line[r2])
            } else if let sp = line.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                hash = String(line[..<sp])
                name = String(line[sp...]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("*") { name.removeFirst() }
            }
            guard hash.count == algo.hexLength, !name.isEmpty else { continue }
            // jen soubory v této složce a pod ní (bez „..“ a absolutních cest)
            let clean = name.replacingOccurrences(of: "\\", with: "/")
            guard !clean.hasPrefix("/"), !clean.split(separator: "/").contains("..") else { continue }
            let u = dir.appendingPathComponent(clean)
            let exists = FileManager.default.fileExists(atPath: u.path)
            out.append(HashRow(url: u, size: exists ? size(u) : 0, hash: nil, expected: hash, error: exists ? nil : "soubor chybí"))
        }
        return out
    }

    var total: Int64 { rows.reduce(0) { $0 + $1.size } }

    func compute() {
        cancel.value = true
        let c = Box(false); cancel = c
        for i in rows.indices { rows[i].hash = nil }
        running = true; progress = 0; status = "Počítám \(algo.rawValue)…"
        let list = rows.map { ($0.id, $0.url, $0.error) }, a = algo, total = max(1, total)
        Task.detached(priority: .userInitiated) {
            var doneBefore: Int64 = 0
            var lastUI = Date()
            for (id, url, err) in list {
                if c.value { break }
                if err != nil { continue }
                let before = doneBefore
                let h = a.hash(url, cancel: c) { done in
                    if Date().timeIntervalSince(lastUI) > 0.15 {
                        lastUI = Date()
                        let p = Double(before + done) / Double(total)
                        Task { @MainActor in if self.cancel === c { self.progress = p } }
                    }
                }
                doneBefore += ChecksumModel.size(url)
                await MainActor.run {
                    guard self.cancel === c, let i = self.rows.firstIndex(where: { $0.id == id }) else { return }
                    self.rows[i].hash = h
                    if h == nil, !c.value { self.rows[i].error = "nelze číst" }
                }
            }
            await MainActor.run {
                guard self.cancel === c else { return }
                self.running = false; self.progress = 1
                if self.verifyMode {
                    let ok = self.rows.filter { $0.status == true }.count
                    let bad = self.rows.count - ok
                    self.status = bad == 0 ? "✓ Všech \(ok) souborů odpovídá" : "✗ Nesouhlasí nebo chybí: \(bad) z \(self.rows.count)"
                } else {
                    self.status = c.value ? "Zrušeno" : "Hotovo – \(self.rows.count) souborů, \(Fmt.bytes(self.total))"
                }
            }
        }
    }

    func stop() { cancel.value = true; running = false; status = "Zrušeno" }

    /// Text ve formátu md5sum / shasum („hash  název“), cesty relativně ke složce panelu.
    var listing: String {
        rows.compactMap { r in
            guard let h = r.hash else { return nil }
            let rel = r.url.path.hasPrefix(baseDir.path + "/") ? String(r.url.path.dropFirst(baseDir.path.count + 1)) : r.name
            return "\(h)  \(rel)"
        }.joined(separator: "\n") + "\n"
    }

    /// Shoda s vloženým otiskem (bez ohledu na velikost písmen a mezery).
    func matches(_ r: HashRow) -> Bool? {
        let c = compare.lowercased().filter { $0.isHexDigit }
        guard !c.isEmpty, let h = r.hash else { return nil }
        return h.lowercased() == c
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func save() {
        let p = NSSavePanel()
        p.title = "Uložit kontrolní součty"
        p.directoryURL = baseDir
        p.nameFieldStringValue = (rows.count == 1 ? rows[0].name : baseDir.lastPathComponent) + "." + algo.ext
        p.allowedContentTypes = [UTType(filenameExtension: algo.ext) ?? .plainText]
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try listing.write(to: u, atomically: true, encoding: .utf8); Commander.shared.refreshAll() }
        catch let err { let a = NSAlert(); a.messageText = "Uložení selhalo"; a.informativeText = err.localizedDescription; a.runModal() }
    }
}

struct ChecksumView: View {
    @ObservedObject var m: ChecksumModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if m.verifyMode {
                    Label("Ověření podle \(m.sourceFile?.lastPathComponent ?? "") (\(m.algo.rawValue))", systemImage: "checkmark.seal")
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Picker("", selection: $m.algo) { ForEach(HashAlgo.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                    if m.algo == .md5 || m.algo == .sha1 {
                        Text("MD5 / SHA-1 jen pro kontrolu shody, ne jako ochrana proti podvržení")
                            .font(.system(size: 10.5)).foregroundStyle(UI.textTertiary)
                            .tip("MD5 a SHA-1 jdou úmyslně „vyrobit“ se stejným otiskem (kolize). Na ověření, že se soubor nepoškodil, stačí; proti záměrně podvrženému souboru použij SHA-256.")
                    }
                }
                Spacer()
                if m.running {
                    ProgressView(value: m.progress).frame(width: 120)
                    Button("Zastavit") { m.stop() }
                }
            }
            Table(m.rows) {
                TableColumn("Soubor") { r in
                    HStack(spacing: 5) {
                        statusIcon(r)
                        Text(r.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                TableColumn(m.algo.rawValue) { r in
                    Text(r.hash ?? r.error ?? "…")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(r.error != nil ? UI.error : UI.text)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Velikost") { r in Text(Fmt.bytes(r.size)).monospacedDigit() }.width(80)
            }
            .contextMenu(forSelectionType: HashRow.ID.self) { ids in
                if let id = ids.first, let r = m.rows.first(where: { $0.id == id }), let h = r.hash {
                    Button("Kopírovat \(m.algo.rawValue)") { m.copy(h) }
                    Button("Kopírovat řádek (hash  soubor)") { m.copy("\(h)  \(r.name)") }
                }
            }
            if !m.verifyMode {
                HStack {
                    Text("Porovnat s").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                    TextField("vlož očekávaný otisk (např. ze stránky výrobce)", text: $m.compare)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
                    if let hit = m.rows.first(where: { m.matches($0) == true }) {
                        Label("Shoda: \(hit.name)", systemImage: "checkmark.circle.fill").foregroundStyle(UI.ok).lineLimit(1)
                    } else if !m.compare.isEmpty, !m.running {
                        Label("Žádný soubor neodpovídá", systemImage: "xmark.octagon.fill").foregroundStyle(UI.error)
                    }
                }
            }
            HStack {
                Text(m.status).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Spacer()
                if !m.verifyMode {
                    Button("Kopírovat vše") { m.copy(m.listing) }.disabled(m.running)
                    Button("Uložit jako .\(m.algo.ext)…") { m.save() }.disabled(m.running)
                        .tip("Soubor ve formátu md5sum / shasum – ověříš ho později vybráním a stejnou funkcí, nebo v Terminálu (shasum -c).")
                } else {
                    Button("Ověřit znovu") { m.compute() }.disabled(m.running)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 380)
        .background(UI.app)
    }

    @ViewBuilder private func statusIcon(_ r: HashRow) -> some View {
        let cmp = m.verifyMode ? r.status : m.matches(r)
        if r.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.warn) }
        else if cmp == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(UI.ok) }
        else if cmp == false { Image(systemName: "xmark.octagon.fill").foregroundStyle(UI.error) }
        else if r.hash == nil { ProgressView().controlSize(.mini) }
        else { Image(systemName: "number").foregroundStyle(UI.textTertiary) }
    }
}

@MainActor
enum ChecksumWindow {
    private static var windows: [NSWindow] = []

    static func show(files: [URL], baseDir: URL) {
        let m = ChecksumModel(files: files, baseDir: baseDir, algo: HashAlgo(rawValue: UserDefaults.standard.string(forKey: "hashAlgo") ?? "") ?? .md5)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = m.verifyMode ? "Ověření kontrolních součtů" : "Kontrolní součty"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ChecksumView(m: m).preferredColorScheme(FTSettings.shared.isDark ? .dark : .light))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !m.verifyMode { UserDefaults.standard.set(m.algo.rawValue, forKey: "hashAlgo") }
                m.stop()
                windows.removeAll { $0 === w }
            }
        }
        windows.append(w)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

extension Commander {
    /// Kontrolní součty označených souborů (složky se projdou rekurzivně); vybraný .md5/.sha… = ověření.
    func checksums() {
        guard tab.remote == nil, tab.archive == nil else {
            alert("Kontrolní součty", "Počítají se z místních souborů – soubor ze serveru nebo z archivu nejdřív zkopíruj (F5)."); return
        }
        var files: [URL] = []
        for i in tab.selection {
            if i.isDir && !i.isPackage {
                let e = FileManager.default.enumerator(at: i.url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let u = e?.nextObject() as? URL {
                    if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(u) }
                    if files.count > 20_000 { break }
                }
            } else if !i.isDir {
                files.append(i.url)
            }
        }
        guard !files.isEmpty else { alert("Kontrolní součty", "Vyber soubory (nebo složky)."); return }
        ChecksumWindow.show(files: files, baseDir: tab.dir)
    }
}
