import Foundation
import AppKit
import NetFS

// SMB sdílení (Windows, NAS): připojí se systémově (NetFS) do /Volumes a panel ho prochází
// jako běžnou složku – fungují všechny operace. Heslo zadáš v systémovém dialogu macOS
// (nabídne uložení do Klíčenky); FileTool heslo nevidí ani neukládá. Odpojení: ⏏ v bočním panelu.

enum SMBMount {
    /// smb://user@host[:port]/share – podsložky za sdílením se otevřou až po připojení.
    static func url(_ c: RemoteConfig) -> URL? {
        let parts = c.path.split(separator: "/").map(String.init)
        guard let share = parts.first else { return nil }
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = c.host
        if c.port != 445 { comps.port = c.port }
        if !c.user.isEmpty { comps.user = c.user }
        comps.path = "/" + share
        return comps.url
    }

    static func subpath(_ c: RemoteConfig) -> String {
        c.path.split(separator: "/").dropFirst().joined(separator: "/")
    }

    /// Už připojené sdílení (stejný server a share).
    static func mounted(_ c: RemoteConfig) -> URL? {
        let share = (c.path.split(separator: "/").first.map(String.init) ?? "").lowercased()
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        for v in vols {
            guard let r = (try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting,
                  r.scheme?.lowercased() == "smb", r.host?.lowercased() == c.host.lowercased() else { continue }
            let rs = r.path.split(separator: "/").first.map { String($0).removingPercentEncoding ?? String($0) }?.lowercased() ?? ""
            if rs == share { return v }
        }
        return nil
    }

    /// Připojí (nebo najde připojené) a vrátí složku k otevření v panelu.
    static func mount(_ c: RemoteConfig, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        func finish(_ base: URL) -> URL {
            let sub = subpath(c)
            return sub.isEmpty ? base : base.appendingPathComponent(sub, isDirectory: true)
        }
        if let m = mounted(c) { Task { @MainActor in completion(.success(finish(m))) }; return }
        guard let u = url(c) else {
            Task { @MainActor in completion(.failure(RemoteError.failed("Zadej název sdílení (např. Data)."))) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let open = NSMutableDictionary()
            open["UIOption"] = "AllowUI"                       // kNAUIOptionKey / kNAUIOptionAllowUI – dialog pro heslo
            let user: CFString? = c.user.isEmpty ? nil : c.user as CFString
            let rc = NetFSMountURLSync(u as CFURL, nil, user, nil, open as CFMutableDictionary, nil, nil)
            let result: Result<URL, Error>
            if rc == 0, let m = mounted(c) {
                result = .success(finish(m))
            } else if rc == 0 {
                result = .success(finish(URL(fileURLWithPath: "/Volumes/" + (c.path.split(separator: "/").first.map(String.init) ?? ""), isDirectory: true)))
            } else if rc == -128 || rc == Int32(ECANCELED) {
                result = .failure(RemoteError.cancelled)
            } else {
                let msg: String
                switch rc {
                case Int32(EAUTH), Int32(EACCES), Int32(EPERM): msg = "Přihlášení odmítnuto (špatné jméno nebo heslo, nebo chybí oprávnění ke sdílení)."
                case Int32(ENOENT): msg = "Sdílení „\(c.path)“ na serveru neexistuje."
                case Int32(EHOSTUNREACH), Int32(ETIMEDOUT), Int32(ECONNREFUSED), Int32(ENETUNREACH): msg = "Server \(c.host) není dostupný (síť, VPN, firewall – port \(c.port))."
                default: msg = "Připojení selhalo (kód \(rc))."
                }
                result = .failure(RemoteError.failed(msg))
            }
            Task { @MainActor in completion(result) }
        }
    }
}
