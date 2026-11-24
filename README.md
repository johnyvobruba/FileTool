# FileTool

Dvoupanelový správce souborů pro macOS ve stylu Total / Double Commanderu. Vzhled a barevné profily jsou stejné jako v [SSHTool](https://github.com/johnyvobruba/SSHTool).

## Hlavní funkce

| Oblast | Co umí |
|---|---|
| **Panely** | dva panely se záložkami, klikací cesta, boční panel (disky, oblíbené, servery), náhledy obrázků, velikost složek mezerníkem, rychlé hledání psaním |
| **Soubory** | F3–F8 jako v TC (⌘3–⌘8), hromadné přejmenování, synchronizace složek, porovnání souborů (diff), kontrolní součty MD5 / SHA |
| **Archivy** | ZIP, tar.gz, 7z, RAR… procházení jako složky, balení i s heslem (AES-256 přes 7-Zip) |
| **Servery** | SFTP, SCP, FTP/FTPS, SMB (Windows / NAS) – skupiny, import ze SSHTool, automatické připojení SMB |
| **Hledání** | název s maskou, text v souborech, uvnitř archivů; výsledky jako seznam v panelu |
| **Úklid** (⇧⌘U) | systémový odpad, velké a staré soubory, odinstalace aplikací, služby při startu (Výkon), mapa disku, duplicity – vše do Koše po potvrzení |

## Instalace

> ⚠️ **Neinstaluj přes `git` ani `gh`.** Příkazy v [PUBLISHING.md](PUBLISHING.md) jsou jen pro autora (vydávání nových verzí). Spuštěné ve vlastní domovské složce by mohly nahrát tvoje soubory na GitHub.

1. Stáhni nejnovější `FileTool-x.y.z.zip` z [Releases](../../releases/latest).
2. Rozbal ho a přesuň `FileTool.app` do složky **Aplikace**.
3. Při prvním spuštění macOS hlásí *„FileTool“ nelze otevřít* (aplikace není notarizovaná Apple). Klikni **Hotovo** a pak:
   - **Nastavení systému → Soukromí a zabezpečení** → dole u „FileTool bylo zablokováno…“ **Přesto otevřít** → potvrď heslem, **nebo**
   - v Terminálu: `xattr -dr com.apple.quarantine /Applications/FileTool.app`

   (Od macOS 15 Sequoia už nejde obejít kontrolu přes pravé tlačítko → Otevřít.)
4. Doporučeno: **Plný přístup k disku** – FileTool tě při prvním spuštění navede (Nastavení → Oprávnění). Bez něj se macOS ptá u každé chráněné složky zvlášť a Úklid nevidí Koš, Mail apod.

Další verze už nabídne aplikace sama (Nastavení → O aplikaci → Zkontrolovat).

Požadavky: macOS 13 Ventura nebo novější. Volitelně 7-Zip (`brew install sevenzip`) pro šifrované ZIP AES-256 a 7z.

### Ověření staženého souboru (volitelné)

```bash
shasum -a 256 -c FileTool-x.y.z.zip.sha256
gh attestation verify FileTool-x.y.z.zip -R johnyvobruba/FileTool     # sestaveno z tohoto repozitáře přes GitHub Actions
```

## Aktualizace

- Při každé nové verzi GitHub Actions sestaví aplikaci a publikuje **Release** (`.zip`, `.sha256`, `.sig`, `.sbom.json`) s podepsanou provenance buildu.
- Aplikace se při spuštění (max. 4× denně, lze vypnout) zeptá `api.github.com` na nejnovější verzi. Instalace proběhne **až po potvrzení**: stažení → **ověření podpisu Ed25519** veřejným klíčem zabudovaným v aplikaci → kontrola bundle id a verze → stará verze do Koše → restart.
- Po aktualizaci může macOS „zapomenout“ Plný přístup k disku (aplikace není podepsaná certifikátem Apple) – v Nastavení systému u FileTool přepínač vypni a zapni.

## Bezpečnost

- Hesla k serverům jen v Klíčence macOS (volitelně); SMB hesla spravuje přímo macOS. Export serverů je bez hesel.
- Neznámý klíč SSH serveru se vždy ukáže k potvrzení (výchozí volba Odmítnout).
- Mazání v Úklidu a synchronizaci jde do Koše; systémové složky se nenabízejí.
- Soubory stažené ze serveru dostávají karanténu macOS (Gatekeeper).

## Klávesy

| TC | Mac | Akce |
|---|---|---|
| F3 | ⌘3 | Zobrazit (Quick Look) |
| F4 | ⌘4 | Upravit |
| F5 | ⌘5 | Kopírovat do druhého panelu |
| F6 | ⌘6 | Přesunout |
| ⇧F6 / F2 | ⌘R | Přejmenovat |
| F7 | ⌘7 | Nová složka |
| F8 | ⌘8 | Do Koše (⇧F8 / ⇧⌘8 trvale) |
| Alt+F1 / F2 | ⌥⌘1 / ⌥⌘2 | Disk / místo pro levý / pravý panel |
| Tab | Tab | Přepnout panel |
| Insert / mezerník | mezerník | Označit |
| num + / − / * | ⌥⌘= / ⌥⌘- / ⌥⌘8 | Označit / odznačit maskou, obrátit |
| Ctrl+T / Ctrl+W | ⌘T / ⌘W | Nová / zavřít záložku |
| Enter, ⌫ | Enter, ⌫ (⌘↓, ⌘↑) | Otevřít, nadřazená složka |
| psaní | psaní | Rychlé hledání |
| | ⌘U, ⌘= | Prohodit panely, druhý panel = stejná složka |

Úplný přehled: Nastavení → Klávesové zkratky.

## Sestavení ze zdrojů

```bash
xcode-select --install          # Command Line Tools (Xcode není nutný)
bash build-app.sh               # → build/FileTool.app
bash build-app.sh --install     # → /Applications/FileTool.app
```

Vydávání nových verzí (jen autor): [PUBLISHING.md](PUBLISHING.md).
