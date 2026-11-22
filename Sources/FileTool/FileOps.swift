import Foundation
import AppKit
import Darwin

/// Vláknově bezpečná hodnota (sdílená mezi kopírovacím vláknem a UI).
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Běžící operace (kopírování, přesun, mazání) – průběh pro lištu dole.
@MainActor
final class FileOperation: ObservableObject, Identifiable {
    enum Kind { case copy, move, delete }
    let id = UUID()
    let kind: Kind
    let title: String
    @Published var done: Int64 = 0
    @Published var total: Int64 = 0
    @Published var current = ""
    @Published var finished = false
    @Published var errors: [String] = []
    @Published var speed: Double = 0
    let cancel = Box(false)
    let progress = Box<(done: Int64, current: String)>((0, ""))
    let started = Date()

    init(kind: Kind, title: String) { self.kind = kind; self.title = title }

    var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }

    var detail: String {
        var p = [String]()
        if total > 0 { p.append("\(Fmt.bytes(done)) z \(Fmt.bytes(total))") }
        if speed > 0 { p.append("\(Fmt.bytes(Int64(speed)))/s") }
        if total > done, speed > 0 {
            let s = Int(Double(total - done) / speed)
            p.append("zbývá " + String(format: "%d:%02d", s / 60, s % 60))
        }
        if !current.isEmpty { p.append(current) }
        return p.joined(separator: " · ")
    }

    /// Převzít průběh z pracovního vlákna (volá časovač každých 0,25 s).
    func pull() {
        let p = progress.value
        let dt = Date().timeIntervalSince(started)
        if dt > 0.5 { speed = Double(p.done) / dt }
        done = p.done
        current = p.current
    }
}

// MARK: - copyfile(3) s průběhem

/// Konstanty z <copyfile.h> (makra složená z více hodnot se do Swiftu neimportují spolehlivě).
enum CF {
    static let all: UInt32 = 0xF                 // ACL | STAT | XATTR | DATA
    static let recursive: UInt32 = 1 << 15
    static let clone: UInt32 = 1 << 24           // APFS klon, když to jde (okamžité kopírování)
    static let nofollowSrc: UInt32 = 1 << 18
    static let recurseFile: Int32 = 1
    static let copyData: Int32 = 4
    static let stageFinish: Int32 = 2
    static let stageProgress: Int32 = 4
    static let cont: Int32 = 0
    static let quit: Int32 = 2
    static let stateStatusCB: UInt32 = 6
    static let stateStatusCtx: UInt32 = 7
    static let stateCopied: UInt32 = 8
}

/// Kontext pro callback copyfile: hotové bajty položky + aktuální soubor.
final class CopyCtx: @unchecked Sendable {
    let cancel: Box<Bool>
    let report: (Int64, String) -> Void
    var finished: Int64 = 0              // dokončené soubory uvnitř složky
    var currentFile: Int64 = 0           // rozkopírovaný soubor
    init(cancel: Box<Bool>, report: @escaping (Int64, String) -> Void) { self.cancel = cancel; self.report = report }
}

private let copyCallback: @convention(c) (Int32, Int32, OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = {
    what, stage, state, src, _, ctx in
    guard let ctx else { return CF.cont }
    let c = Unmanaged<CopyCtx>.fromOpaque(ctx).takeUnretainedValue()
    if c.cancel.value { return CF.quit }
    let name = src.map { (String(cString: $0) as NSString).lastPathComponent } ?? ""
    if what == CF.copyData, stage == CF.stageProgress, let state {
        var copied: off_t = 0
        copyfile_state_get(state, CF.stateCopied, &copied)
        c.currentFile = Int64(copied)
        c.report(c.finished + c.currentFile, name)
    } else if what == CF.recurseFile, stage == CF.stageFinish, let src {
        var st = stat()
        if lstat(src, &st) == 0 { c.finished += Int64(st.st_size) }
        c.currentFile = 0
        c.report(c.finished, name)
    }
    return CF.cont
}

enum FileOps {
    enum Conflict { case overwrite, skip }

    /// Celková velikost položek (rekurzivně) – pro průběh.
    static func totalSize(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let f as URL in e {
                    if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                        total += Int64(v.fileSize ?? 0)
                    }
                }
            } else {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let kb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        return ka != nil && ka == kb
    }

    /// Zkopíruje / přesune položky do složky. Běží mimo hlavní vlákno, vrací chyby.
    static func transfer(_ sources: [URL], to dir: URL, move: Bool, conflict: Conflict,
                         cancel: Box<Bool>, progress: Box<(done: Int64, current: String)>) -> [String] {
        let fm = FileManager.default
        var errors: [String] = []
        var base: Int64 = 0
        let destIsSameVolume = sameVolume(sources.first ?? dir, dir)
        for src in sources {
            if cancel.value { errors.append("Zrušeno uživatelem."); break }
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            let size = totalSize([src])
            defer { base += size; progress.value = (base, "") }
            if dst.standardizedFileURL == src.standardizedFileURL { errors.append("\(src.lastPathComponent): cíl je stejný jako zdroj"); continue }
            if dst.path.hasPrefix(src.path + "/") { errors.append("\(src.lastPathComponent): nelze kopírovat složku do sebe sama"); continue }
            let exists = fm.fileExists(atPath: dst.path)
            if exists && conflict == .skip { continue }

            // přesun v rámci svazku = přejmenování (okamžité); u kolize se složkou radši kopírovat a sloučit
            if move, destIsSameVolume {
                var dstIsDir: ObjCBool = false
                let dstDir = fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir) && dstIsDir.boolValue
                if !dstDir {
                    do {
                        if exists { try fm.removeItem(at: dst) }
                        try fm.moveItem(at: src, to: dst)
                        continue
                    } catch { errors.append("\(src.lastPathComponent): \(error.localizedDescription)"); continue }
                }
            }

            let ctx = CopyCtx(cancel: cancel) { n, name in progress.value = (base + n, name) }
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }
            copyfile_state_set(state, CF.stateStatusCB, unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
            let unmanaged = Unmanaged.passRetained(ctx)
            copyfile_state_set(state, CF.stateStatusCtx, unmanaged.toOpaque())
            let rc = copyfile(src.path, dst.path, state, CF.all | CF.recursive | CF.clone | CF.nofollowSrc)
            unmanaged.release()
            if rc != 0 {
                if cancel.value { errors.append("Zrušeno uživatelem."); break }
                errors.append("\(src.lastPathComponent): \(String(cString: strerror(errno)))")
                continue
            }
            if move {
                do { try fm.removeItem(at: src) }
                catch { errors.append("\(src.lastPathComponent): zkopírováno, ale zdroj nejde smazat – \(error.localizedDescription)") }
            }
        }
        return errors
    }

    /// Smazání: do Koše, nebo trvale.
    static func delete(_ urls: [URL], trash: Bool, cancel: Box<Bool>, progress: Box<(done: Int64, current: String)>) -> [String] {
        var errors: [String] = []
        for (i, u) in urls.enumerated() {
            if cancel.value { errors.append("Zrušeno uživatelem."); break }
            progress.value = (Int64(i), u.lastPathComponent)
            do {
                if trash { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
                else { try FileManager.default.removeItem(at: u) }
            } catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        progress.value = (Int64(urls.count), "")
        return errors
    }
}
