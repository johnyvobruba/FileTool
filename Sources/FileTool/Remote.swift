import Foundation
import AppKit
import Security
import Darwin

// Vzdálené panely: SFTP (přes ssh ControlMaster), SCP (zařízení bez SFTP) a FTP/FTPS (curl).
// Hesla jen v Klíčence macOS (volitelně) nebo zadaná při připojení; do ssh je předává pomocný
// proces askpass (FileTool v režimu askpass, ověřuje rodiče), do curl jdou přes stdin.

enum RemotePath {
    static let ssh = "/usr/bin/ssh"

    /// Cesta v uvozovkách pro dávku sftp. Řídicí znaky (konec řádku) se odmítnou – jinak by vznikl další příkaz dávky.
    static func q(_ s: String) -> String {
        let clean = String(s.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(Character.init))
        return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
    }

    static func parent(_ p: String) -> String {
        let r = (p as NSString).deletingLastPathComponent
        return r.isEmpty ? "/" : r
    }

    /// Výpis „ls -la“ (sftp, ssh i FTP LIST) → položky.
    static func parse(_ out: String, dir: String, base: URL) -> [FileItem] {
        let re = try! NSRegularExpression(pattern:
            #"^([\-dlcbps][rwxsStT\-]{9}[+@.]?)\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+([A-Z][a-z]{2}\s+\d{1,2}\s+[\d:]{4,5})\s(.+)$"#)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        let year = Calendar.current.component(.year, from: Date())
        var res: [FileItem] = []
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard !line.hasPrefix("sftp>"), let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
            let perms = g(1)
            var name = g(6)
            let isLink = perms.hasPrefix("l")
            if isLink, let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
            if name.count > 1, name.hasSuffix("/") { name.removeLast() }
            if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
            guard name != ".", name != "..", !name.contains("/") else { continue }
            let ds = g(5).replacingOccurrences(of: "  ", with: " ")
            var date: Date?
            if ds.contains(":") { df.dateFormat = "MMM d HH:mm yyyy"; date = df.date(from: ds + " \(year)") }
            else { df.dateFormat = "MMM d yyyy"; date = df.date(from: ds) }
            let path = join(dir, name)
            res.append(FileItem(url: URL(fileURLWithPath: base.path + path), name: name, isDir: perms.hasPrefix("d"),
                                isPackage: false, isLink: isLink, isHidden: name.hasPrefix("."), isExecutable: false,
                                size: perms.hasPrefix("d") ? -1 : Int64(g(4)) ?? 0, modified: date ?? Date.distantPast,
                                perms: perms, remotePath: path))
        }
        return res
    }
}

/// Uložené připojení (bez hesla).
struct RemoteConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var proto = "sftp"          // sftp | scp | ftp | smb
    var host = ""
    var port = 22
    var user = ""
    var ftpTLS = "explicit"     // "" | explicit | implicit
    var savePassword = false
    var path = ""               // počáteční složka (prázdné = domovská)
    var group: String? = nil    // složka v nabídce Server (import ze SSHTool / JSON)

    var title: String { name.isEmpty ? (user.isEmpty ? host : "\(user)@\(host)") : name }
    var dest: String { user.isEmpty ? host : "\(user)@\(host)" }
    var scheme: String { proto == "ftp" ? (ftpTLS.isEmpty ? "ftp" : "ftps") : proto }

    /// Kontrola polí – nic, co by šlo podstrčit jako přepínač ssh nebo rozbít URL.
    var problem: String? {
        let ctrl: (String) -> Bool = { $0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
        if host.isEmpty { return "Zadej server." }
        for (n, v) in [("Server", host), ("Uživatel", user)] {
            if ctrl(v) || v.contains(where: \.isWhitespace) { return "\(n) nesmí obsahovat mezery ani řídicí znaky." }
            if v.hasPrefix("-") { return "\(n) nesmí začínat znakem „-“." }
        }
        if host.contains("/") || host.contains("@") { return "Server zadej bez uživatele a cesty (např. fw1.example.com)." }
        if !(1...65535).contains(port) { return "Port musí být 1–65535." }
        return nil
    }
}

@MainActor
final class RemoteStore: ObservableObject {
    static let shared = RemoteStore()
    @Published var configs: [RemoteConfig] = [] { didSet { save() } }
    private init() {
        if let d = UserDefaults.standard.data(forKey: "remotes"), let c = try? JSONDecoder().decode([RemoteConfig].self, from: d) { configs = c }
    }
    private func save() { if let d = try? JSONEncoder().encode(configs) { UserDefaults.standard.set(d, forKey: "remotes") } }

    func upsert(_ c: RemoteConfig) {
        if let i = configs.firstIndex(where: { $0.id == c.id }) { configs[i] = c } else { configs.append(c) }
    }
    func remove(_ c: RemoteConfig) { configs.removeAll { $0.id == c.id }; RemoteKeychain.delete(c.id.uuidString) }
}

/// Hesla k serverům v Klíčence (služba cz.local.filetool.remote).
enum RemoteKeychain {
    static let service = "cz.local.filetool.remote"
    private static func q(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func set(_ pw: String, for account: String) {
        SecItemDelete(q(account) as CFDictionary)
        var a = q(account)
        a[kSecValueData as String] = Data(pw.utf8)
        a[kSecAttrLabel as String] = "FileTool – server"
        SecItemAdd(a as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        var a = q(account)
        a[kSecReturnData as String] = true
        a[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(a as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) { SecItemDelete(q(account) as CFDictionary) }
}

/// Spojení jednoho vzdáleného panelu.
@MainActor
final class RemoteSession {
    let config: RemoteConfig
    private(set) var controlPath = ""
    private var master: Process?
    private var masterErr = Box("")
    private var ftpPassword: String?
    private(set) var home = "/"

    init(config: RemoteConfig) { self.config = config }

    var label: String { "\(config.scheme)://\(config.dest)" }

    // MARK: Připojení

    func connect() async throws {
        if config.proto == "ftp" {
            if config.savePassword, let p = RemoteKeychain.get(config.id.uuidString) { ftpPassword = p }
            else if !config.user.isEmpty && config.user != "anonymous" {
                guard let p = askPassword("Heslo pro \(config.dest) (\(config.scheme.uppercased()))") else { throw RemoteError.cancelled }
                ftpPassword = p
                if config.savePassword { RemoteKeychain.set(p, for: config.id.uuidString) }
            }
        } else {
            try await startMaster()
        }
        let r = await run(["pwd"])
        guard r.ok, let line = r.out.split(whereSeparator: \.isNewline).first(where: { $0.contains("Remote working directory:") }) else {
            disconnect()
            throw RemoteError.failed(r.err.isEmpty ? "Server neodpověděl." : String(r.err.suffix(400)))
        }
        home = line.components(separatedBy: "Remote working directory:").last?.trimmingCharacters(in: .whitespaces) ?? "/"
        if home.isEmpty { home = "/" }
    }

    /// ssh -M -N: jedno přihlášené spojení, přes které běží sftp/scp bez dalšího přihlášení.
    private func startMaster() async throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("FileTool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        controlPath = dir.appendingPathComponent("cm-" + String(UUID().uuidString.prefix(8)).lowercased()).path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: RemotePath.ssh)
        p.arguments = ["-M", "-N", "-S", controlPath, "-o", "ControlPersist=no", "-o", "StrictHostKeyChecking=ask",
                       "-o", "ServerAliveInterval=30", "-o", "NumberOfPasswordPrompts=3", "-p", String(config.port), "--", config.dest]
        var env = ProcessInfo.sanitizedEnvironment
        if let exe = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = exe
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["FILETOOL_ASKPASS"] = "1"
            env["FILETOOL_TARGET"] = config.host
            if config.savePassword { env["FILETOOL_ASKPASS_ID"] = config.id.uuidString }
        }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let box = masterErr
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { box.value += String(decoding: d, as: UTF8.self) }
        }
        try p.run()
        master = p
        let cp = controlPath, dest = config.dest
        for _ in 0..<240 {                                       // až 2 minuty (heslo, OTP, potvrzení klíče)
            if !p.isRunning {
                throw RemoteError.failed(box.value.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Přihlášení selhalo.")
            }
            let ready = await Task.detached { RemoteSession.masterReady(cp, dest) }.value
            if ready { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        disconnect()
        throw RemoteError.failed("Přihlášení nedokončeno do 2 minut.")
    }

    nonisolated static func masterReady(_ cp: String, _ dest: String) -> Bool {
        guard FileManager.default.fileExists(atPath: cp) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: RemotePath.ssh)
        p.arguments = ["-S", cp, "-O", "check", "--", dest]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func disconnect() {
        if let m = master, m.isRunning {
            let cp = controlPath, dest = config.dest
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: RemotePath.ssh)
                p.arguments = ["-S", cp, "-O", "exit", "--", dest]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
            }
            m.terminate()
        }
        master = nil
    }

    // MARK: Příkazy (formát dávky sftp; SCP a FTP je převádějí)

    func run(_ commands: [String], pid: Box<Int32>? = nil) async -> (ok: Bool, out: String, err: String) {
        let cfg = config, cp = controlPath, pw = ftpPassword
        return await Task.detached { () -> (ok: Bool, out: String, err: String) in
            switch cfg.proto {
            case "scp": return RemoteBackend.scp(commands, cp: cp, dest: cfg.dest, pid: pid)
            case "ftp":
                let f = FTPConfig(host: cfg.host, port: cfg.port, user: cfg.user, tls: cfg.ftpTLS, insecure: false)
                return RemoteBackend.ftp(commands, f, password: pw, pid: pid)
            default: break
            }
            let r = RemoteBackend.proc("/usr/bin/sftp", ["-b", "-", "-S", RemotePath.ssh, "-o", "ControlPath=\(cp)", "-o", "ControlMaster=no",
                                                          "-o", "BatchMode=yes", "--", cfg.dest],
                                       stdin: commands.joined(separator: "\n") + "\n", pid: pid)
            return (r.0 == 0, r.1, r.2)
        }.value
    }

    func list(_ dir: String, base: URL) async throws -> [FileItem] {
        let r = await run(["ls -la " + RemotePath.q(dir)])
        guard r.ok else { throw RemoteError.failed(Self.cleanErr(r.err)) }
        return RemotePath.parse(r.out, dir: dir, base: base)
    }

    nonisolated static func cleanErr(_ e: String) -> String {
        e.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("sftp>") }.last ?? "Operace selhala"
    }

    private func askPassword(_ title: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = config.savePassword ? "Heslo se uloží do Klíčenky macOS." : "Heslo se nikam neukládá."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Připojit"); a.addButton(withTitle: "Zrušit")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return nil }
        return f.stringValue
    }
}

enum RemoteError: LocalizedError {
    case cancelled, failed(String)
    var errorDescription: String? {
        switch self { case .cancelled: return "Zrušeno."; case .failed(let s): return s }
    }
}
