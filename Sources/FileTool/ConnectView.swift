import SwiftUI
import AppKit

/// Model dialogu „Připojit k serveru“ (⌘K).
@MainActor
final class ConnectModel: ObservableObject {
    @Published var selected: UUID?
    @Published var draft = RemoteConfig()
    @Published var portText = "22"
    @Published var problem: String?
    var onConnect: ((RemoteConfig) -> Void)?
    var close: (() -> Void)?

    init() {
        if let first = RemoteStore.shared.configs.first { pick(first) }
    }

    func pick(_ c: RemoteConfig) { selected = c.id; draft = c; portText = String(c.port); problem = nil }

    func new() { selected = nil; draft = RemoteConfig(); portText = "22"; problem = nil }

    func protoChanged(_ p: String) {
        let defaults = ["sftp": 22, "scp": 22, "ftp": 21, "smb": 445]
        if defaults.values.contains(Int(portText) ?? -1) { portText = String(defaults[p] ?? 22) }
        draft.proto = p
        if p == "ftp", draft.ftpTLS == "implicit", portText == "21" { portText = "990" }
    }

    /// Adresa vložená do pole Server (smb://user@nas/Data/Projekty, sftp://host:2222/var, \\\\nas\\Data)
    /// se rozloží do polí protokol / server / port / uživatel / cesta.
    private func normalize(_ c: inout RemoteConfig) {
        var h = c.host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("\\\\") {                                         // Windows UNC \\server\share
            h = "smb://" + h.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        guard h.contains("://") || h.contains("/") || h.contains("@") else { c.host = h; return }
        if !h.contains("://") { h = c.proto + "://" + h }
        guard let u = URLComponents(string: h), let host = u.host, !host.isEmpty else { c.host = h; return }
        let scheme = (u.scheme ?? c.proto).lowercased()
        let proto = ["smb": "smb", "cifs": "smb", "sftp": "sftp", "ssh": "sftp", "scp": "scp", "ftp": "ftp", "ftps": "ftp"][scheme] ?? c.proto
        if proto != c.proto { c.proto = proto; if scheme == "ftps" { c.ftpTLS = "implicit" } }
        c.host = host
        if let usr = u.user, !usr.isEmpty, c.user.isEmpty { c.user = usr.removingPercentEncoding ?? usr }
        let defaults = ["sftp": 22, "scp": 22, "ftp": scheme == "ftps" ? 990 : 21, "smb": 445]
        c.port = u.port ?? defaults[proto] ?? c.port
        let p = (u.path.removingPercentEncoding ?? u.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !p.isEmpty, c.path.isEmpty { c.path = proto == "smb" ? p : "/" + p }
    }

    private func validated() -> RemoteConfig? {
        var c = draft
        c.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        normalize(&c)
        draft = c; portText = String(c.port)                                // ukázat rozložené hodnoty
        c.host = c.host.trimmingCharacters(in: .whitespaces)
        c.user = c.user.trimmingCharacters(in: .whitespaces)
        if let p = c.problem { problem = p; return nil }
        problem = nil
        return c
    }

    func save() {
        guard let c = validated() else { return }
        if !c.savePassword { RemoteKeychain.delete(c.id.uuidString) }
        RemoteStore.shared.upsert(c)
        pick(c)
    }

    func delete() {
        guard let id = selected, let c = RemoteStore.shared.configs.first(where: { $0.id == id }) else { return }
        RemoteStore.shared.remove(c)
        new()
    }

    func forgetPassword() { RemoteKeychain.delete(draft.id.uuidString) }

    func connect() {
        guard let c = validated() else { return }
        if selected != nil {
            if !c.savePassword { RemoteKeychain.delete(c.id.uuidString) }
            RemoteStore.shared.upsert(c)
        }
        close?()
        onConnect?(c)
    }
}

struct ConnectView: View {
    @ObservedObject var model: ConnectModel
    @ObservedObject var store = RemoteStore.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Uložené servery").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                List {
                    ForEach(store.configs) { c in
                        Button { model.pick(c) } label: {
                            HStack {
                                Image(systemName: c.proto == "smb" ? "externaldrive.connected.to.line.below" : c.proto == "ftp" ? "tray.and.arrow.down" : "lock.shield")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title).lineLimit(1)
                                    Text("\(c.scheme)://\(c.dest)").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .listRowBackground(model.selected == c.id ? Color.accentColor.opacity(0.25) : Color.clear)
                    }
                }
                .frame(width: 210)
                HStack {
                    Button { model.new() } label: { Image(systemName: "plus") }.tip("Nový server")
                    Button { model.delete() } label: { Image(systemName: "minus") }.tip("Smazat uložený server").disabled(model.selected == nil)
                }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Form {
                    TextField("Název", text: $model.draft.name)
                    TextField("Skupina", text: Binding(get: { model.draft.group ?? "" },
                                                      set: { model.draft.group = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                              prompt: Text("nepovinné – např. Zákazník A/Praha"))
                    Picker("Protokol", selection: Binding(get: { model.draft.proto }, set: { model.protoChanged($0) })) {
                        Text("SFTP").tag("sftp")
                        Text("SCP (zařízení bez SFTP)").tag("scp")
                        Text("FTP / FTPS").tag("ftp")
                        Text("SMB (sdílení Windows / NAS)").tag("smb")
                    }
                    TextField("Server", text: $model.draft.host, prompt: Text("název, IP nebo adresa (smb://…, sftp://…)"))
                    TextField("Port", text: $model.portText)
                    TextField("Uživatel", text: $model.draft.user)
                    if model.draft.proto == "ftp" {
                        Picker("Šifrování", selection: $model.draft.ftpTLS) {
                            Text("FTPS – explicitní TLS (doporučeno)").tag("explicit")
                            Text("FTPS – implicitní TLS (port 990)").tag("implicit")
                            Text("Bez šifrování (heslo jde po síti čitelně)").tag("")
                        }
                    }
                    if model.draft.proto == "smb" {
                        TextField("Sdílení", text: $model.draft.path, prompt: Text("nepovinné – prázdné = výběr ze seznamu"))
                    } else {
                        TextField("Počáteční složka", text: $model.draft.path, prompt: Text("domovská"))
                        Toggle("Uložit heslo do Klíčenky", isOn: $model.draft.savePassword)
                    }
                }
                if model.draft.proto == "smb" {
                    Text("Připojí se jako disk (/Volumes) a panel ho prochází jako běžnou složku. Heslo zadáš v dialogu macOS, který nabídne uložení do Klíčenky. Odpojení: ⏏ u disku v bočním panelu.")
                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if model.draft.proto != "ftp" {
                    Text("Přihlášení klíčem nebo agentem funguje bez hesla (podle ~/.ssh/config). Neznámý klíč serveru se před uložením ukáže k potvrzení.")
                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if model.draft.ftpTLS.isEmpty {
                    Text("⚠︎ Nešifrované FTP posílá heslo i data čitelně. Používej jen v izolované síti.")
                        .font(.system(size: 11)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let p = model.problem {
                    Text(p).font(.system(size: 11)).foregroundColor(.red)
                }
                Spacer()
                HStack {
                    if model.draft.savePassword {
                        Button("Zapomenout heslo") { model.forgetPassword() }
                    }
                    Spacer()
                    Button("Zrušit") { model.close?() }.keyboardShortcut(.cancelAction)
                    Button(model.selected == nil ? "Uložit" : "Uložit změny") { model.save() }
                    Button("Připojit") { model.connect() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 400)
        }
        .frame(height: 400)
    }
}

/// Okno dialogu (modální k hlavnímu oknu).
@MainActor
enum ConnectWindow {
    private static var window: NSWindow?

    static func show(onConnect: @escaping (RemoteConfig) -> Void) {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let model = ConnectModel()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Připojit k serveru"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ConnectView(model: model))
        model.onConnect = onConnect
        model.close = { w.close(); window = nil }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
