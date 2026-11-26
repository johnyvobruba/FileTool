import Foundation
import AppKit
import Darwin

extension ProcessInfo {
    /// Prostředí pro spouštěné procesy bez DYLD_* (vložení knihoven do ssh/curl, které dostávají heslo).
    static var sanitizedEnvironment: [String: String] {
        processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
    }
}

/// FileTool spuštěný jako SSH_ASKPASS: odpoví ssh na dotaz (heslo, OTP, neznámý klíč serveru) a skončí.
/// Odpovídá jen ssh (/usr/bin/ssh), které spustila běžící aplikace FileTool.
enum AskPass {
    static func run(prompt: String) -> Never {
        guard calledFromFileTool() else {
            FileHandle.standardError.write(Data("filetool: askpass odmítnut – nevolá ho ssh spuštěné z FileTool\n".utf8))
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let p = prompt.lowercased()
        let env = ProcessInfo.processInfo.environment

        if p.contains("continue connecting") || p.contains("authenticity of host") {
            let ok = confirmHostKey(prompt)
            answer(ok ? "yes" : "no", code: ok ? 0 : 1)
        }
        if p.contains("password") || p.contains("passphrase") {
            let target = (env["FILETOOL_TARGET"] ?? "").lowercased()
            let asked = promptHost(prompt)?.lowercased()
            let ownHost = asked == nil || asked == target
            let id = env["FILETOOL_ASKPASS_ID"] ?? ""
            // uložené heslo jen pro cílový server a jen na první výzvu (špatné heslo → ruční zadání)
            if !id.isEmpty, ownHost, p.contains("password"), !retried(id), let pw = RemoteKeychain.get(id) {
                answer(pw)
            }
            guard let typed = ask(title: "FileTool – přihlášení", text: prompt, secure: true,
                                  save: !id.isEmpty && ownHost && p.contains("password")) else { exit(1) }
            if typed.save { RemoteKeychain.set(typed.value, for: id) }
            answer(typed.value)
        }
        // jiné výzvy (OTP, „Verification code:“) – ruční zadání
        guard let typed = ask(title: "FileTool – ověření", text: prompt, secure: false, save: false) else { exit(1) }
        answer(typed.value)
    }

    private static func answer(_ s: String, code: Int32 = 0) -> Never {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
        exit(code)
    }

    /// Druhá výzva v rámci stejného ssh = uložené heslo nesedí. Značka v proměnné rodiče nejde, proto soubor podle PID ssh.
    private static func retried(_ id: String) -> Bool {
        let mark = FileManager.default.temporaryDirectory.appendingPathComponent("filetool-askpass-\(getppid())")
        if FileManager.default.fileExists(atPath: mark.path) { return true }
        FileManager.default.createFile(atPath: mark.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return false
    }

    private static func ask(title: String, text: String, secure: Bool, save: Bool) -> (value: String, save: Bool)? {
        // askpass běží celý na hlavním vlákně (synchronně z main) → dialog smí sahat na @MainActor prvky
        MainActor.assumeIsolated { askOnMain(title: title, text: text, secure: secure, save: save) }
    }

    @MainActor
    private static func askOnMain(title: String, text: String, secure: Bool, save: Bool) -> (value: String, save: Bool)? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pf = secure ? RevealPasswordField(width: 280) : nil        // heslo s okem pro zobrazení
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let box = NSStackView()
        box.orientation = .vertical; box.alignment = .leading; box.spacing = 8
        box.addArrangedSubview(pf ?? tf)
        let chk = NSButton(checkboxWithTitle: "Uložit do Klíčenky", target: nil, action: nil)
        if save { box.addArrangedSubview(chk) }
        box.frame = NSRect(x: 0, y: 0, width: 280, height: save ? 54 : 24)
        a.accessoryView = box
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Zrušit")
        a.window.initialFirstResponder = pf?.secure ?? tf
        a.window.level = .floating
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return (pf?.stringValue ?? tf.stringValue, save && chk.state == .on)
    }

    static func promptHost(_ prompt: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"[^\s@()']+@([^\s'()]+?)(?:'s password|\))"#, options: [.caseInsensitive]),
              let m = re.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let r = Range(m.range(at: 1), in: prompt) else { return nil }
        return String(prompt[r])
    }

    private static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// askpass ← /usr/bin/ssh ← FileTool (stejná binárka, jiný proces).
    static func calledFromFileTool() -> Bool {
        guard let me = path(of: getpid()) else { return false }
        let ssh = URL(fileURLWithPath: RemotePath.ssh).resolvingSymlinksInPath().path
        let pid = getppid()
        guard path(of: pid) == ssh, let pp = parent(of: pid), pp > 1, pp != getpid(), let p = path(of: pp) else { return false }
        return p == me
    }

    private static func confirmHostKey(_ prompt: String) -> Bool {
        let text = prompt
            .replacingOccurrences(of: "Are you sure you want to continue connecting (yes/no/[fingerprint])?", with: "")
            .replacingOccurrences(of: "Are you sure you want to continue connecting (yes/no)?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "FileTool: neznámý klíč serveru"
        a.informativeText = text + "\n\nOvěř otisk SHA256 se správcem serveru. Přijmi jen při shodě – jinak může jít o útok typu man-in-the-middle."
        a.addButton(withTitle: "Odmítnout")
        a.addButton(withTitle: "Přijmout a uložit")
        a.window.level = .floating
        return a.runModal() == .alertSecondButtonReturn
    }
}
