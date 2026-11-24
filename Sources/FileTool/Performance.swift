import SwiftUI
import AppKit
import Security

// Úklid → Výkon: položky při přihlášení, služby na pozadí (LaunchAgents / LaunchDaemons) s popisem,
// podpisem a stavem, zapnutí / vypnutí (launchctl – vratné, nic se nemaže) a údržbové úlohy.
// Systémové položky (/Library/LaunchDaemons) a údržba se správcovským heslem přes dialog macOS.

enum StartupScope: String {
    case userAgent = "Uživatel", globalAgent = "Všichni uživatelé", daemon = "Systém (démon)"
    var dir: String {
        switch self {
        case .userAgent: return CleanFS.home + "/Library/LaunchAgents"
        case .globalAgent: return "/Library/LaunchAgents"
        case .daemon: return "/Library/LaunchDaemons"
        }
    }
    var needsAdmin: Bool { self == .daemon }
}

struct StartupItem: Identifiable, Hashable {
    let id: String              // cesta k plistu
    let plist: URL
    let label: String
    let scope: StartupScope
    let program: String
    let runAtLoad: Bool
    let keepAlive: Bool
    let interval: Int?
    var disabled: Bool
    var running: Bool
    let appName: String?
    let appURL: URL?
    let signer: String          // „Apple“, tým / vydavatel, „bez podpisu“
    let signedOK: Bool
    let programExists: Bool
    let description: String

    static func == (a: StartupItem, b: StartupItem) -> Bool { a.id == b.id && a.disabled == b.disabled && a.running == b.running }
    func hash(into h: inout Hasher) { h.combine(id) }

    var orphan: Bool { !programExists || (appURL == nil && appName == nil && program.contains(".app/")) }
    var when: String {
        if keepAlive { return "běží stále" }
        if let i = interval { return i >= 3600 ? "každé \(i / 3600) h" : "každých \(max(1, i / 60)) min" }
        if runAtLoad { return scope == .daemon ? "při startu Macu" : "při přihlášení" }
        return "na vyžádání"
    }
}

struct LoginItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let path: String
}

enum MaintenanceTask: String, CaseIterable, Identifiable {
    case dns, launchServices, quickLook, spotlight, verifyDisk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dns: return "Vyprázdnit mezipaměť DNS"
        case .launchServices: return "Obnovit databázi Launch Services"
        case .quickLook: return "Vyčistit mezipaměť Quick Look"
        case .spotlight: return "Přeindexovat Spotlight"
        case .verifyDisk: return "Ověřit spouštěcí disk"
        }
    }
    var help: String {
        switch self {
        case .dns: return "Pomůže, když se weby nebo servery po změně DNS (VPN, nový záznam) pořád nepřekládají správně."
        case .launchServices: return "Opraví zdvojené položky v „Otevřít v…“ a špatné výchozí aplikace pro typy souborů."
        case .quickLook: return "Pomůže při chybných nebo zastaralých náhledech souborů (mezerník ve Finderu, náhledy ve FileTool)."
        case .spotlight: return "Když hledání nenachází soubory nebo ukazuje smazané. Indexace pak běží desítky minut a krátce zatíží Mac."
        case .verifyDisk: return "Kontrola souborového systému za běhu (jen čtení) – ukáže, jestli je potřeba První pomoc v Diskové utilitě."
        }
    }
    var icon: String {
        switch self {
        case .dns: return "network"
        case .launchServices: return "square.stack.3d.up"
        case .quickLook: return "eye"
        case .spotlight: return "magnifyingglass"
        case .verifyDisk: return "internaldrive"
        }
    }
    var admin: Bool { self == .dns || self == .spotlight }
    /// Pevné příkazy – žádný vstup od uživatele ani z plistů.
    var command: [String] {
        switch self {
        case .dns: return ["/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"]
        case .launchServices: return ["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                      "-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]
        case .quickLook: return ["/usr/bin/qlmanage", "-r", "cache"]
        case .spotlight: return ["/usr/bin/mdutil -E /"]
        case .verifyDisk: return ["/usr/sbin/diskutil", "verifyVolume", "/"]
        }
    }
}

@MainActor
final class PerformanceModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loginItems: [LoginItem] = []
    @Published var loginError: String?
    @Published var running = false
    @Published var scanned = false
    @Published var status = ""
    @Published var filter: Filter = .all
    @Published var selected: String?
    @Published var maintenanceLog = ""
    @Published var busyTask: MaintenanceTask?
    @Published var view: Page = .overview

    enum Page { case overview, items, maintenance }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Vše", active = "Zapnuté", orphans = "Bez aplikace", unsigned = "Bez platného podpisu", always = "Běží stále"
        var id: String { rawValue }
    }

    var shown: [StartupItem] {
        switch filter {
        case .all: return items
        case .active: return items.filter { !$0.disabled }
        case .orphans: return items.filter(\.orphan)
        case .unsigned: return items.filter { !$0.signedOK }
        case .always: return items.filter { $0.keepAlive && !$0.disabled }
        }
    }

    // MARK: Načtení

    nonisolated static let labelRe = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._-]{1,200}$"#)
    nonisolated static func validLabel(_ s: String) -> Bool {
        labelRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        do { try p.run() } catch { return (-1, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Vypnuté položky domény (launchctl print-disabled): "label" => disabled / true.
    nonisolated static func disabledSet(_ domain: String) -> Set<String> {
        var s = Set<String>()
        for line in run("/bin/launchctl", ["print-disabled", domain]).1.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("\""), let end = l.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(l[l.index(after: l.startIndex)..<end])
            if l.hasSuffix("disabled") || l.hasSuffix("true") { s.insert(label) }
        }
        return s
    }

    /// Běžící úlohy uživatelské domény (launchctl list: PID  status  label).
    nonisolated static func runningUser() -> Set<String> {
        var s = Set<String>()
        for line in run("/bin/launchctl", ["list"]).1.split(whereSeparator: \.isNewline).dropFirst() {
            let c = line.split(separator: "\t")
            if c.count >= 3, c[0] != "-" { s.insert(String(c[2])) }
        }
        return s
    }

    nonisolated static func signature(_ path: String) -> (String, Bool) {
        var code: SecStaticCode?
        guard FileManager.default.fileExists(atPath: path),
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return ("bez podpisu", false) }
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)), nil) == errSecSuccess
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info)
        let d = info as? [String: Any] ?? [:]
        if let ident = d[kSecCodeInfoIdentifier as String] as? String, ident.hasPrefix("com.apple."),
           (d[kSecCodeInfoTeamIdentifier as String] as? String) == nil, valid { return ("Apple", true) }
        let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let name = certs.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let team = d[kSecCodeInfoTeamIdentifier as String] as? String
        if let name { return (name.replacingOccurrences(of: "Developer ID Application: ", with: ""), valid) }
        if let team { return ("tým \(team)", valid) }
        return ("ad-hoc / bez vydavatele", false)
    }

    /// Srozumitelný popis podle známých názvů, jinak podle programu.
    nonisolated static func describe(label: String, program: String, app: String?) -> String {
        let l = label.lowercased()
        let known: [(String, String)] = [
            ("com.google.keystone", "Automatické aktualizace aplikací Google (Chrome, Drive…)."),
            ("com.google.googleupdater", "Automatické aktualizace aplikací Google."),
            ("com.microsoft.update", "Microsoft AutoUpdate – aktualizace Office, Teams, Edge."),
            ("com.microsoft.autoupdate", "Microsoft AutoUpdate – aktualizace Office, Teams, Edge."),
            ("com.microsoft.onedrive", "OneDrive – synchronizace souborů."),
            ("com.microsoft.teams", "Microsoft Teams – pomocná služba."),
            ("com.microsoft.wdav", "Microsoft Defender – ochrana před malwarem (firemní politika)."),
            ("com.microsoft.dlp", "Microsoft Purview DLP – ochrana firemních dat (firemní politika)."),
            ("com.microsoft.intune", "Microsoft Intune – správa firemního zařízení."),
            ("com.adobe.acc", "Adobe Creative Cloud – přihlášení a aktualizace."),
            ("com.adobe.agsservice", "Adobe Genuine Software – kontrola licencí Adobe."),
            ("com.adobe.arm", "Adobe Acrobat – aktualizace."),
            ("com.adobe", "Služba aplikací Adobe."),
            ("us.zoom", "Zoom – aktualizace a pomocná služba."),
            ("com.cisco.secureclient", "Cisco Secure Client (AnyConnect VPN) – firemní VPN."),
            ("com.cisco.anyconnect", "Cisco AnyConnect VPN – firemní VPN."),
            ("com.citrix", "Citrix Workspace – vzdálené aplikace a plochy."),
            ("com.docker", "Docker Desktop – virtualizace kontejnerů."),
            ("homebrew.mxcl.", "Služba nainstalovaná přes Homebrew (brew services)."),
            ("com.dropbox", "Dropbox – synchronizace souborů."),
            ("com.teamviewer", "TeamViewer – vzdálený přístup k tomuto Macu."),
            ("com.anydesk", "AnyDesk – vzdálený přístup k tomuto Macu."),
            ("com.spotify", "Spotify – pomocná služba."),
            ("com.duo", "Duo – dvoufázové ověření."),
            ("com.paloaltonetworks", "Palo Alto GlobalProtect – firemní VPN."),
            ("com.fortinet", "FortiClient – firemní VPN / ochrana."),
            ("com.checkpoint", "Check Point – VPN / ochrana koncového zařízení."),
            ("com.crowdstrike", "CrowdStrike Falcon – ochrana koncového zařízení (firemní politika)."),
            ("com.qualys", "Qualys Cloud Agent – skenování zranitelností (firemní politika)."),
            ("com.thousandeyes", "ThousandEyes – monitorování síťového výkonu."),
            ("com.oracle.java", "Java – aktualizace."),
            ("com.parallels", "Parallels Desktop – virtualizace."),
            ("com.vmware", "VMware Fusion – virtualizace."),
            ("org.virtualbox", "VirtualBox – virtualizace."),
            ("com.logi", "Logitech – ovladače a nastavení myši / klávesnice."),
            ("com.tuxera", "Tuxera NTFS – zápis na disky NTFS."),
            ("com.jamf", "Jamf – správa firemního zařízení."),
            ("com.grammarly", "Grammarly – kontrola textu."),
            ("com.openai", "ChatGPT – pomocná služba."),
            ("com.whatsapp", "WhatsApp – pomocná služba."),
        ]
        if let k = known.first(where: { l.hasPrefix($0.0) }) { return k.1 }
        if l.contains("update") || l.contains("updater") || program.lowercased().contains("update") {
            return "Automatické aktualizace" + (app.map { " aplikace \($0)" } ?? "") + "."
        }
        if l.contains("helper") { return "Pomocná služba" + (app.map { " aplikace \($0)" } ?? "") + "." }
        if let app { return "Služba aplikace \(app)." }
        return "Spouští \((program as NSString).lastPathComponent)."
    }

    func scan() {
        running = true; status = "Načítám služby…"
        Task.detached(priority: .userInitiated) {
            let uid = getuid()
            let disUser = PerformanceModel.disabledSet("gui/\(uid)")
            let disSys = PerformanceModel.disabledSet("system")
            let run = PerformanceModel.runningUser()
            var out: [StartupItem] = []
            for scope in [StartupScope.userAgent, .globalAgent, .daemon] {
                for u in CleanFS.children(URL(fileURLWithPath: scope.dir)) where u.pathExtension == "plist" {
                    guard let d = NSDictionary(contentsOf: u) as? [String: Any], let label = d["Label"] as? String,
                          PerformanceModel.validLabel(label) else { continue }
                    let args = d["ProgramArguments"] as? [String] ?? []
                    let program = (d["Program"] as? String) ?? args.first ?? ""
                    let keep: Bool = (d["KeepAlive"] as? Bool) ?? (d["KeepAlive"] is [String: Any])
                    let interval = d["StartInterval"] as? Int
                    var appURL: URL?
                    if let r = program.range(of: ".app/") { appURL = URL(fileURLWithPath: String(program[..<r.lowerBound]) + ".app") }
                    else if let bid = d["AssociatedBundleIdentifiers"] as? [String], let b = bid.first {
                        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b)
                    } else if let b = d["AssociatedBundleIdentifiers"] as? String {
                        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b)
                    }
                    if let a = appURL, !FileManager.default.fileExists(atPath: a.path) { appURL = nil }
                    let appName = appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                    let exists = !program.isEmpty && FileManager.default.fileExists(atPath: program)
                    let sig = exists ? PerformanceModel.signature(program) : ("program chybí", false)
                    let disabled = scope == .daemon ? disSys.contains(label) : disUser.contains(label)
                    let isRunning = scope == .daemon
                        ? PerformanceModel.run("/bin/launchctl", ["print", "system/\(label)"]).1.contains("state = running")
                        : run.contains(label)
                    out.append(StartupItem(id: u.path, plist: u, label: label, scope: scope, program: program,
                                           runAtLoad: d["RunAtLoad"] as? Bool ?? false, keepAlive: keep, interval: interval,
                                           disabled: disabled, running: isRunning, appName: appName, appURL: appURL,
                                           signer: sig.0, signedOK: sig.1, programExists: exists,
                                           description: PerformanceModel.describe(label: label, program: program, app: appName)))
                }
            }
            let result = out.sorted { ($0.scope.rawValue, $0.label.lowercased()) < ($1.scope.rawValue, $1.label.lowercased()) }
            await MainActor.run {
                self.items = result
                self.running = false; self.scanned = true
                self.status = "\(result.count) služeb · zapnuto \(result.filter { !$0.disabled }.count)"
            }
        }
    }

    /// Položky při přihlášení přes System Events (macOS se jednou zeptá na povolení automatizace).
    func loadLoginItems() {
        loginError = nil
        Task.detached {
            let r = PerformanceModel.run("/usr/bin/osascript", ["-e",
                "tell application \"System Events\" to get {name, path} of every login item"])
            await MainActor.run {
                guard r.0 == 0 else {
                    self.loginError = "macOS nedovolil přečíst položky při přihlášení (povol FileTool v Soukromí a zabezpečení → Automatizace), nebo je otevři v Nastavení systému."
                    return
                }
                // výstup: "A, B, /cesta/A, /cesta/B"
                let parts = r.1.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ")
                let n = parts.count / 2
                self.loginItems = (0..<n).map { LoginItem(name: parts[$0], path: parts[n + $0]) }
            }
        }
    }

    static func openLoginSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    // MARK: Zapnutí / vypnutí (launchctl – vratné)

    func setEnabled(_ item: StartupItem, _ on: Bool) {
        guard Self.validLabel(item.label) else { return }
        let uid = getuid()
        let label = item.label, plist = item.plist.path
        if item.scope.needsAdmin {
            // pevný příkaz; label prošel kontrolou znaků, cesta k plistu je z /Library/LaunchDaemons
            let cmd = on
                ? "/bin/launchctl enable system/\(label); /bin/launchctl bootstrap system '\(plist)' 2>/dev/null; true"
                : "/bin/launchctl disable system/\(label); /bin/launchctl bootout system/\(label) 2>/dev/null; true"
            guard plist.hasPrefix("/Library/LaunchDaemons/"), !plist.contains("'") else { return }
            admin(cmd, reason: on ? "zapnout \(label)" : "vypnout \(label)")
        } else {
            let domain = "gui/\(uid)"
            Task.detached {
                if on {
                    _ = PerformanceModel.run("/bin/launchctl", ["enable", "\(domain)/\(label)"])
                    _ = PerformanceModel.run("/bin/launchctl", ["bootstrap", domain, plist])
                } else {
                    _ = PerformanceModel.run("/bin/launchctl", ["disable", "\(domain)/\(label)"])
                    _ = PerformanceModel.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
                }
                await MainActor.run { self.scan() }
            }
        }
    }

    /// Správcovský příkaz přes dialog macOS (heslo / Touch ID) – FileTool heslo nevidí.
    private func admin(_ cmd: String, reason: String) {
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        Task.detached {
            let r = PerformanceModel.run("/usr/bin/osascript", ["-e", script])
            await MainActor.run {
                if r.0 != 0, !r.1.contains("-128") { Commander.shared.alert("Nepodařilo se \(reason)", r.1) }
                self.scan()
            }
        }
    }

    /// Odstranit plist uživatelské služby (do Koše) – jen pro položky bez aplikace.
    func trashOrphan(_ item: StartupItem) {
        guard item.scope == .userAgent else { return }
        let a = NSAlert()
        a.messageText = "Odstranit službu „\(item.label)“?"
        a.informativeText = "Služba se vypne a její plist se přesune do Koše (lze vrátit). Program: \(item.program)"
        a.addButton(withTitle: "Odstranit"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        _ = Self.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
        try? FileManager.default.trashItem(at: item.plist, resultingItemURL: nil)
        scan()
    }

    // MARK: Údržba

    func runTask(_ t: MaintenanceTask) {
        busyTask = t
        maintenanceLog += "▶ \(t.title)…\n"
        if t.admin {
            let script = "do shell script \"\(t.command[0])\" with administrator privileges"
            Task.detached {
                let r = PerformanceModel.run("/usr/bin/osascript", ["-e", script])
                await MainActor.run { self.finishTask(t, r) }
            }
        } else {
            let cmd = t.command
            Task.detached {
                let r = PerformanceModel.run(cmd[0], Array(cmd.dropFirst()))
                await MainActor.run { self.finishTask(t, r) }
            }
        }
    }

    private func finishTask(_ t: MaintenanceTask, _ r: (Int32, String)) {
        busyTask = nil
        let out = r.1.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.0 == 0 { maintenanceLog += "✓ \(t.title) – hotovo\n" + (out.isEmpty ? "" : String(out.suffix(1500)) + "\n") }
        else if out.contains("-128") { maintenanceLog += "– \(t.title) – zrušeno\n" }
        else { maintenanceLog += "✗ \(t.title) – chyba (\(r.0))\n" + String(out.suffix(800)) + "\n" }
    }
}

// MARK: - Zobrazení

struct PerformanceView: View {
    @ObservedObject var m: PerformanceModel

    var body: some View {
        Group {
            switch m.view {
            case .overview: overview
            case .items: itemsPage
            case .maintenance: maintenance
            }
        }
        .onAppear { if !m.scanned && !m.running { m.scan() } }
    }

    // Přehled s kartami doporučení
    private var overview: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(m.running ? "Načítám služby…" : "Uplatni doporučení, nebo projdi služby ručně.")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(C.text).multilineTextAlignment(.center)
                Button("Zobrazit všechny služby") { m.filter = .all; m.view = .items }.buttonStyle(GlassButton())
            }
            .padding(.top, 10)
            HStack(alignment: .top, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(MaintenanceTask.allCases.count) úlohy údržby").font(.system(size: 17, weight: .semibold)).foregroundStyle(C.text)
                        Text("DNS, Launch Services, Quick Look, Spotlight a kontrola disku – každá s vysvětlením, co dělá.")
                            .font(.system(size: 12.5)).foregroundStyle(C.text2)
                        Spacer()
                        HStack(spacing: 18) {
                            ForEach([MaintenanceTask.dns, .launchServices, .spotlight], id: \.self) { t in
                                Image(systemName: t.icon).font(.system(size: 30)).foregroundStyle(C.accent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                        HStack { Spacer(); Button("Zkontrolovat") { m.view = .maintenance }.buttonStyle(GlassButton(prominent: true)) }
                    }
                }
                VStack(spacing: 16) {
                    card(count: m.items.filter { $0.orphan && !$0.disabled }.count, icon: "questionmark.app.dashed",
                         title: "služeb po odinstalovaných aplikacích",
                         text: "Spouštějí se, ale jejich aplikace nebo program už na Macu není. Můžeš je vypnout nebo odstranit.", filter: .orphans)
                    card(count: m.items.filter { !$0.signedOK && !$0.disabled }.count, icon: "exclamationmark.shield",
                         title: "služeb bez platného podpisu",
                         text: "Program nemá ověřitelný podpis vývojáře. Nemusí jít o nic zlého (vlastní skripty, Homebrew), ale stojí za kontrolu.", filter: .unsigned)
                    card(count: m.items.filter { $0.keepAlive && !$0.disabled }.count, icon: "infinity",
                         title: "služeb běží pořád na pozadí",
                         text: "Spouštějí se znovu, i když skončí. Vypni ty, které nepotřebuješ.", filter: .always)
                    GlassCard(padding: 14) {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 22)).foregroundStyle(C.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.loginItems.isEmpty ? "Položky při přihlášení" : "\(m.loginItems.count) položek při přihlášení")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(C.text)
                                Text(m.loginError ?? (m.loginItems.isEmpty ? "Aplikace, které se otevřou po přihlášení." : m.loginItems.map(\.name).joined(separator: ", ")))
                                    .font(.system(size: 11.5)).foregroundStyle(C.text2).lineLimit(2)
                            }
                            Spacer()
                            if m.loginItems.isEmpty && m.loginError == nil {
                                Button("Načíst") { m.loadLoginItems() }.buttonStyle(GlassButton())
                            }
                            Button("Nastavení") { PerformanceModel.openLoginSettings() }.buttonStyle(GlassButton())
                        }
                    }
                    .frame(height: 86)
                }
            }
        }
    }

    private func card(count: Int, icon: String, title: String, text: String, filter: PerformanceModel.Filter) -> some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.running ? "…" : "\(count) \(title)").font(.system(size: 14, weight: .semibold)).foregroundStyle(C.text)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Image(systemName: icon).font(.system(size: 24)).foregroundStyle(C.accent)
                    Spacer()
                    Button("Zkontrolovat") { m.filter = filter; m.view = .items }.buttonStyle(GlassButton()).disabled(count == 0)
                }
            }
        }
        .frame(height: 112)
    }

    // Seznam služeb
    private var itemsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { m.view = .overview } label: { Label("Zpět", systemImage: "chevron.left") }.buttonStyle(GlassButton())
                Picker("", selection: $m.filter) { ForEach(PerformanceModel.Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560)
                Spacer()
                if m.running { ProgressView().controlSize(.small) }
                Button { m.scan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GlassButton())
            }
            HStack(alignment: .top, spacing: 14) {
                List(m.shown, selection: $m.selected) { i in
                    HStack(spacing: 10) {
                        Group {
                            if let a = i.appURL { Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable() }
                            else { Image(systemName: i.scope == .daemon ? "gearshape.2" : "gearshape").resizable().scaledToFit().padding(3) }
                        }
                        .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.appName ?? i.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(i.disabled ? C.text3 : C.text).lineLimit(1)
                            Text(i.label).font(.system(size: 10.5)).foregroundStyle(C.text3).lineLimit(1)
                        }
                        Spacer()
                        if i.orphan { Image(systemName: "questionmark.app.dashed").foregroundStyle(.orange).tip("Aplikace nebo program chybí") }
                        if !i.signedOK { Image(systemName: "exclamationmark.shield").foregroundStyle(.yellow).tip("Bez platného podpisu") }
                        if i.running { Circle().fill(.green).frame(width: 7, height: 7).tip("Právě běží") }
                        Toggle("", isOn: Binding(get: { !i.disabled }, set: { m.setEnabled(i, $0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            .tip(i.scope.needsAdmin ? "Systémová služba – změna vyžaduje heslo správce" : "Zapnout / vypnout (vratné, nic se nemaže)")
                    }
                    .padding(.vertical, 2)
                    .tag(i.id)
                }
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 14).fill(C.card))
                .frame(minWidth: 380)
                detail.frame(width: 360)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = m.selected, let i = m.items.first(where: { $0.id == id }) {
            GlassCard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(i.appName ?? i.label).font(.system(size: 17, weight: .semibold)).foregroundStyle(C.text)
                        Text(i.description).font(.system(size: 12.5)).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
                        Divider().overlay(C.border)
                        row("Stav", (i.disabled ? "vypnuto" : "zapnuto") + (i.running ? " · běží" : ""))
                        row("Kdy", i.when)
                        row("Rozsah", i.scope.rawValue)
                        row("Podpis", i.signer + (i.signedOK ? " ✓" : " ⚠︎"))
                        row("Program", i.program.isEmpty ? "—" : i.program)
                        row("Label", i.label)
                        row("Soubor", i.plist.path)
                        HStack {
                            Button("Ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([i.plist]) }.buttonStyle(GlassButton())
                            if i.orphan && i.scope == .userAgent {
                                Button("Odstranit") { m.trashOrphan(i) }.buttonStyle(GlassButton(danger: true))
                            }
                        }
                        Text("Vypnutí je vratné – služba zůstane na disku, jen se nespustí (launchctl disable). Firemní bezpečnostní nástroje (Defender, VPN, Intune…) nevypínej, porušil bys firemní politiku.")
                            .font(.system(size: 10.5)).foregroundStyle(C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            GlassCard { Text("Vyber službu – uvidíš, co dělá, kdo ji vydal a kdy se spouští.").foregroundStyle(C.text2) }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11.5)).foregroundStyle(C.text3).frame(width: 70, alignment: .leading)
            Text(v).font(.system(size: 11.5)).foregroundStyle(C.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    // Údržba
    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { m.view = .overview } label: { Label("Zpět", systemImage: "chevron.left") }.buttonStyle(GlassButton())
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    ForEach(MaintenanceTask.allCases) { t in
                        GlassCard(padding: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: t.icon).font(.system(size: 22)).foregroundStyle(C.accent).frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(t.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(C.text)
                                        if t.admin { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(C.text3).tip("Vyžaduje heslo správce") }
                                    }
                                    Text(t.help).font(.system(size: 11.5)).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if m.busyTask == t { ProgressView().controlSize(.small) }
                                Button("Spustit") { m.runTask(t) }.buttonStyle(GlassButton()).disabled(m.busyTask != nil)
                            }
                        }
                        .frame(height: 84)
                    }
                }
                GlassCard {
                    ScrollView {
                        Text(m.maintenanceLog.isEmpty ? "Výstup úloh se zobrazí tady." : m.maintenanceLog)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(C.text2)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: 320)
            }
            Text("„Uvolnění RAM“ (purge) ani mazání systémových mezipamětí FileTool nenabízí – macOS si paměť spravuje sám a tyto zásahy výkon spíš zhorší.")
                .font(.system(size: 10.5)).foregroundStyle(C.text3)
        }
    }
}
