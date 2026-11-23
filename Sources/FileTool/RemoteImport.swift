import Foundation
import AppKit
import UniformTypeIdentifiers

// Import a export uložených serverů (SFTP / SCP / FTP) – JSON jako v SSHTool, včetně
// přímého načtení serverů ze SSHTool. Hesla se nikdy neimportují ani neexportují.

@MainActor
enum RemoteImport {

    /// ~/Library/Application Support/SSHTool/sessions.json (jen čtení).
    static var sshToolFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHTool/sessions.json")
    }

    static var sshToolAvailable: Bool { FileManager.default.isReadableFile(atPath: sshToolFile.path) }

    // MARK: Převod záznamu

    /// Jeden objekt JSON → připojení. Rozumí formátu FileTool i SSHTool (proto ssh/ftp + fileTransfer).
    /// nil = záznam se přeskočí (RDP, telnet, sériová linka, chybí host…).
    static func config(from o: [String: Any]) -> RemoteConfig? {
        func str(_ k: String) -> String { (o[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var c = RemoteConfig()
        let proto = str("proto").lowercased()
        switch proto {
        case "", "ssh", "sftp": c.proto = str("fileTransfer").lowercased() == "scp" ? "scp" : "sftp"
        case "scp": c.proto = "scp"
        case "ftp", "ftps": c.proto = "ftp"
        case "smb", "cifs": c.proto = "smb"
        default: return nil                                      // rdp, telnet, serial…
        }
        c.name = str("name")
        c.host = str("host")
        c.user = str("user")
        c.path = str("path")
        let g = str("group")
        c.group = g.isEmpty || g == "Default" ? nil : g
        if let p = o["port"] as? Int { c.port = p }
        else if let p = Int(str("port")) { c.port = p }
        else { c.port = c.proto == "ftp" ? (str("ftpTLS") == "implicit" ? 990 : 21) : c.proto == "smb" ? 445 : 22 }
        if c.proto == "ftp" {
            let tls = o["ftpTLS"] == nil ? (proto == "ftps" ? "implicit" : "explicit") : str("ftpTLS")
            c.ftpTLS = ["", "explicit", "implicit"].contains(tls) ? tls : "explicit"
        }
        c.savePassword = false                                   // hesla se neimportují
        guard c.problem == nil else { return nil }
        return c
    }

    private static func key(_ c: RemoteConfig) -> String {
        "\(c.proto)|\(c.host.lowercased())|\(c.port)|\(c.user.lowercased())"
    }

    /// Přidá nové servery, duplicity (protokol + host + port + uživatel) přeskočí.
    static func merge(_ objects: [[String: Any]], source: String) {
        let store = RemoteStore.shared
        var seen = Set(store.configs.map(key))
        var added: [RemoteConfig] = [], skipped = 0, ignored = 0
        for o in objects {
            guard let c = config(from: o) else { ignored += 1; continue }
            guard !seen.contains(key(c)) else { skipped += 1; continue }
            seen.insert(key(c)); added.append(c)
        }
        store.configs.append(contentsOf: added)
        info("Import serverů – \(source)",
             "Přidáno: \(added.count), přeskočeno (už existují): \(skipped)"
             + (ignored > 0 ? ", vynecháno (RDP / telnet / neplatný host nebo port): \(ignored)" : "") + "."
             + (added.isEmpty ? "" : "\nHesla se neimportují – zadáš je při prvním připojení (volitelně se uloží do Klíčenky)."))
    }

    private static func objects(_ data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let a = json as? [[String: Any]] { return a }
        if let d = json as? [String: Any] {
            for k in ["servers", "sessions", "connections"] { if let a = d[k] as? [[String: Any]] { return a } }
            return [d]
        }
        throw NSError(domain: "FileTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Soubor neobsahuje seznam serverů (pole JSON)."])
    }

    // MARK: Akce

    static func importFromSSHTool() {
        do {
            let data = try Data(contentsOf: sshToolFile)
            guard data.count < 20_000_000 else { info("Import ze SSHTool", "Soubor je příliš velký."); return }
            merge(try objects(data), source: "SSHTool")
        } catch let err {
            info("Import ze SSHTool selhal", err.localizedDescription)
        }
    }

    static func importPanel() {
        let p = NSOpenPanel()
        p.title = "Importovat servery"
        p.message = "JSON z FileTool nebo SSHTool (export i sessions.json) – lze vybrat více souborů"
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        var all: [[String: Any]] = []
        for u in p.urls {
            do {
                let data = try Data(contentsOf: u)
                guard data.count < 20_000_000 else { info("Import serverů", "\(u.lastPathComponent) je příliš velký."); return }
                all += try objects(data)
            } catch let err {
                info("Import serverů selhal", "\(u.lastPathComponent): \(err.localizedDescription)"); return
            }
        }
        merge(all, source: p.urls.count == 1 ? p.urls[0].lastPathComponent : "\(p.urls.count) souborů")
    }

    static func exportPanel() {
        let p = NSSavePanel()
        p.title = "Exportovat servery"
        p.nameFieldStringValue = "filetool-servers.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        let rows: [[String: Any]] = RemoteStore.shared.configs.map { c in
            var o: [String: Any] = ["name": c.name, "proto": c.proto, "host": c.host, "port": c.port, "user": c.user]
            if c.proto == "ftp" { o["ftpTLS"] = c.ftpTLS }
            if !c.path.isEmpty { o["path"] = c.path }
            if let g = c.group { o["group"] = g }
            return o
        }
        do {
            let d = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try d.write(to: url, options: .atomic)
        } catch let err { info("Export selhal", err.localizedDescription) }
    }

    /// Vzor pro kolegy (adresy z dokumentačních rozsahů RFC 5737).
    static let templateJSON = """
    [
      {
        "name": "Web server",
        "proto": "sftp",
        "host": "192.0.2.10",
        "port": 22,
        "user": "admin",
        "group": "Zákazník A",
        "path": "/var/www"
      },
      {
        "name": "Switch (bez SFTP)",
        "proto": "scp",
        "host": "192.0.2.20",
        "user": "admin",
        "group": "Zákazník A"
      },
      {
        "name": "FTP archiv",
        "proto": "ftp",
        "host": "198.51.100.5",
        "port": 21,
        "user": "backup",
        "ftpTLS": "explicit"
      },
      {
        "name": "NAS – projekty",
        "proto": "smb",
        "host": "198.51.100.20",
        "user": "jnovak",
        "path": "Data/Projekty",
        "group": "Firma"
      }
    ]
    """

    static func copyTemplate() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(templateJSON, forType: .string)
    }

    private static func info(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}
