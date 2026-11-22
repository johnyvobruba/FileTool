import Foundation
import AppKit
import Darwin

/// Spuštění nástroje, který se ptá na heslo přes terminál (zip -e, 7zz -p): proces dostane pseudoterminál,
/// heslo se mu napíše na výzvu. Heslo tak není v argumentech (ps) ani v proměnných prostředí.
enum PtyRunner {
    static func run(_ exe: String, _ args: [String], cwd: URL, password: String, cancel: Box<Bool>) -> (Int32, String) {
        // vše pro potomka připravit před fork (po fork jen chdir/execv/_exit)
        var argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv { free(p) } }
        guard let cexe = strdup(exe), let cdir = strdup(cwd.path) else { return (-1, "strdup") }
        defer { free(cexe); free(cdir) }
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, nil)
        if pid < 0 { return (-1, "Nelze vytvořit pseudoterminál.") }
        if pid == 0 {
            _ = chdir(cdir)
            _ = argv.withUnsafeBufferPointer { execv(cexe, $0.baseAddress) }
            _exit(127)
        }
        let answer = Array((password + "\n").utf8)
        var out = "", tail = ""
        var answered = 0
        var buf = [UInt8](repeating: 0, count: 8192)
        var status: Int32 = 0
        var reaped = false
        while true {
            if cancel.value { kill(pid, SIGTERM) }
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 200)
            if pr > 0 {
                let n = read(master, &buf, buf.count)
                if n <= 0 { break }
                let s = String(decoding: buf[0..<n], as: UTF8.self)
                out += s
                tail = String((tail + s).suffix(200)).lowercased()
                if tail.contains("password"), tail.hasSuffix(":") || tail.hasSuffix(": "), answered < 4 {
                    answer.withUnsafeBytes { _ = write(master, $0.baseAddress, $0.count) }
                    answered += 1
                    tail = ""
                }
            } else if pr == 0 {
                if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
            } else { break }
        }
        close(master)
        if !reaped { waitpid(pid, &status, 0) }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        if out.count > 4000 { out = String(out.suffix(4000)) }
        return (code, out)
    }
}

/// 7-Zip z Homebrew (brew install sevenzip) – AES-256 pro ZIP i 7z, šifrované 7z a RAR.
enum SevenZip {
    static var path: String? {
        ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7z"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Textové editory pro F4 – nabídne nainstalované (aby nebyl nikdo odkázaný na jeden konkrétní editor).
enum Editors {
    static let known: [(String, String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"), ("com.sublimetext.4", "Sublime Text"), ("com.sublimetext.3", "Sublime Text 3"),
        ("com.barebones.bbedit", "BBEdit"), ("com.coteditor.CotEditor", "CotEditor"), ("com.panic.Nova", "Nova"),
        ("dev.zed.Zed", "Zed"), ("com.macromates.TextMate", "TextMate"), ("com.vscodium", "VSCodium"),
        ("com.jetbrains.fleet", "Fleet"), ("com.apple.TextEdit", "TextEdit"),
    ]

    /// Nainstalované editory (cesta, název).
    static func installed() -> [(path: String, name: String)] {
        known.compactMap { id, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { ($0.path, name) }
        }
    }
}
