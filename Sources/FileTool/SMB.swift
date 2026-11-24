import Foundation
import AppKit
import NetFS

// SMB sdílení (Windows, NAS): připojí se systémově (NetFS) do /Volumes a panel ho prochází
// jako běžnou složku – fungují všechny operace. Heslo zadáš v systémovém dialogu macOS
// (nabídne uložení do Klíčenky); FileTool heslo nevidí ani neukládá. Odpojení: ⏏ v bočním panelu.

enum SMBMount {
    /// Části cesty (sdílení + podsložky), bez prázdných.
    static func parts(_ p: String) -> [String] {
        p.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// smb://user@host[:port]/share/podsložka – celá cesta jako ve Finderu (⌘K): macOS umí připojit
    /// i podsložku sdílení (např. smb://bont1/Users/jvobruba → /Volumes/jvobruba).
    static func url(_ c: RemoteConfig) -> URL? {
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = c.host
        if c.port != 445 { comps.port = c.port }
        if !c.user.isEmpty { comps.user = c.user }
        comps.path = "/" + parts(c.path).joined(separator: "/")   // prázdné = macOS nabídne seznam sdílení
        return comps.url
    }

    /// Už připojený svazek pro tento server a cestu → složka k otevření.
    /// Připojený může být celý share (/Volumes/Users → doplní se podsložka) i přímo podsložka (/Volumes/jvobruba).
    static func mounted(_ c: RemoteConfig) -> URL? {
        let want = parts(c.path).map { $0.lowercased() }
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        var best: (rank: Int, url: URL)?
        for v in vols {
            guard let r = (try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting,
                  r.scheme?.lowercased() == "smb", r.host?.lowercased() == c.host.lowercased() else { continue }
            let have = parts(r.path.removingPercentEncoding ?? r.path).map { $0.lowercased() }
            if want.isEmpty {                                       // bez cesty – kterýkoli svazek serveru
                if best == nil { best = (0, v) }
                continue
            }
            guard !have.isEmpty, have.count <= want.count, Array(want.prefix(have.count)) == have else { continue }
            let rest = parts(c.path).dropFirst(have.count)
            let target = rest.reduce(v) { $0.appendingPathComponent($1, isDirectory: true) }
            if best == nil || have.count > best!.rank { best = (have.count, target) }
        }
        return best?.url
    }

    /// Připojí (nebo najde připojené) a vrátí složku k otevření v panelu.
    static func mount(_ c: RemoteConfig, interactive: Bool = true, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let noShare = parts(c.path).isEmpty
        if !noShare, let m = mounted(c) { Task { @MainActor in completion(.success(m)) }; return }
        let before = Set(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
        guard let u = url(c) else {
            Task { @MainActor in completion(.failure(RemoteError.failed("Neplatná adresa serveru."))) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let open = NSMutableDictionary()
            open["UIOption"] = interactive ? "AllowUI" : "NoUI"   // NoUI = jen s heslem uloženým v Klíčence, bez dialogu
            let user: CFString? = c.user.isEmpty ? nil : c.user as CFString
            let rc = NetFSMountURLSync(u as CFURL, nil, user, nil, open as CFMutableDictionary, nil, nil)
            let result: Result<URL, Error>
            let fresh = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).filter { !before.contains($0) }
            if rc == 0, noShare, let m = fresh.first ?? mounted(c) {
                result = .success(m)                    // sdílení vybrané v dialogu macOS
            } else if rc == 0, let m = mounted(c) {
                result = .success(m)
            } else if rc == 0, let m = fresh.first {
                result = .success(m)                    // nový svazek, i když se adresa nepodařila spárovat
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

extension SMBMount {
    /// Při spuštění: tiše připojí SMB sdílení označená „Připojit při spuštění“ (heslo z Klíčenky macOS,
    /// bez dialogů). Nedostupná (bez VPN, mimo síť) se přeskočí; ručně je připojíš z nabídky Server.
    @MainActor static func autoMountAll(interactive: Bool = false) {
        let list = RemoteStore.shared.configs.filter { $0.proto == "smb" && $0.autoMount == true }
        guard !list.isEmpty else { return }
        func next(_ i: Int, failed: [String]) {
            guard i < list.count else {
                SidebarModel.shared.reloadVolumes()
                if interactive, !failed.isEmpty {
                    let a = NSAlert()
                    a.messageText = "Některá sdílení se nepřipojila"
                    a.informativeText = failed.joined(separator: "\n")
                    a.runModal()
                }
                return
            }
            let c = list[i]
            if !c.path.isEmpty, mounted(c) != nil { next(i + 1, failed: failed); return }
            mount(c, interactive: interactive) { r in
                var f = failed
                if case .failure(let e) = r { f.append("\(c.title): \(e.localizedDescription)") }
                SidebarModel.shared.reloadVolumes()
                next(i + 1, failed: f)
            }
        }
        next(0, failed: [])
    }
}
