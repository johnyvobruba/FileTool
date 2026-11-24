# FileTool – historie změn

Dvoupanelový správce souborů pro macOS ve stylu Total Commanderu, vzhledem i barevnými profily jako SSHTool.
Sekce `## x.y.z` se automaticky použije jako poznámky k vydání na GitHubu.

## 0.10.0

Inspirace z Double / Total Commanderu (zkratky po macOS – ⌘ ⌥ ⌃ ⇧):
- **Hromadné přejmenování** (⇧⌘M): maska názvu a přípony se zástupnými znaky – `[N]` název, `[N1-5]` část názvu, `[E]` přípona, `[C]` čítač (začátek, krok, počet číslic), `[P]` složka, `[YMD]` `[hms]` `[Y]` `[M]` `[D]` datum změny –, hledat a nahradit (i regulární výraz se skupinami `$1`), velikost písmen. Živý náhled se zvýrazněním konfliktů (duplicity, existující soubor, neplatné znaky), bezpečné provedení i při prohození názvů a tlačítko **Zpět**. Bez označení se přejmenuje celá složka.
- **Synchronizace složek** (⇧⌘S): porovná levý a pravý panel (i SMB / NAS) podle data a velikosti, volitelně podle obsahu (SHA-256), s podsložkami a maskou. Směr oba / vlevo → vpravo / vpravo → vlevo, akci u každé položky změníš klikem (→ ← —). Volitelné **zrcadlení** (položky navíc v cíli do Koše). Průběh v liště operací.
- **Porovnání souborů – diff** (⇧⌘D): dva označené soubory, nebo soubor pod kurzorem vlevo × vpravo. Vedle sebe s čísly řádků, barevně přidané / odebrané / změněné, skok na další rozdíl ⌥↓ / ⌥↑, „jen rozdíly“, ignorovat mezery / velikost písmen. Na přání otevře FileMerge, VS Code nebo BBEdit.
- **Velikost složek:** mezerník na složce ji označí a spočítá její velikost (zobrazí se místo `<DIR>` a započítá do součtu výběru); hromadně z menu Operace nebo pravým tlačítkem.

## 0.9.2

- **Klikací cesta** nad panelem (jako ve Finderu): klik na libovolnou část cesty = přejít do ní, **dvojklik = zkopírovat celou cestu** (potvrdí „Zkopírováno“), tlačítka ↑ (nadřazená), ✎ ruční úprava cesty (⌘L, Esc zruší) a kopírování. Funguje i v archivu (včetně vnitřních složek), na serveru a ve výsledcích hledání.
- **Šířka bočního panelu** jde měnit táhnutím za jeho pravý okraj (150–420 bodů, pamatuje se), dvojklik vrátí výchozí šířku.
- **Kontrolní součty** (⌥⌘H, menu Operace, pravé tlačítko): MD5, SHA-1, SHA-256 a SHA-512 pro označené soubory i celé složky, s průběhem i u velkých souborů. Porovnání s vloženým otiskem (např. ze stránky výrobce), kopírování a uložení ve formátu md5sum / shasum. Vybraný soubor `.md5` / `.sha1` / `.sha256` / `.sha512` = **ověření** souborů podle něj (✓ / ✗ / chybí).

## 0.9.1

- **Oprava SMB s cestou ke složce** (např. `smb://bont1/Users/jvobruba`): připojí se stejně jako ve Finderu (⌘K) – i přímo podsložka sdílení – a panel otevře správnou složku (dřív hledal neexistující `/Volumes/jvobruba/jvobruba`). Už připojené sdílení se pozná i tehdy, když je připojený celý share a ty chceš jeho podsložku.

## 0.9.0

- **Náhledy (velké ikony):** panel umí místo seznamu zobrazit mřížku náhledů obrázků (Quick Look – i HEIC, RAW, PDF, videa). Složka **jen s obrázky** se tak zobrazí automaticky (vypnutelné v Nastavení → Obecné). Přepnutí ⌥⌘T nebo ikonou v liště, velikost náhledů posuvníkem nad mřížkou (64–320 bodů).
  - ovládání jako v seznamu: šipky po mřížce, mezerník / ⌘-klik označí, Enter / dvojklik otevře, F3 Quick Look, F5–F8 a další operace beze změny, přetahování myší;
  - v archivu a na serveru ikony podle typu souboru.

## 0.8.5

- **Úklid – řazení výsledků:** u Velkých a Starých souborů jde řadit klikem na hlavičku sloupce (název, umístění, velikost, naposledy otevřeno, změněno) a přes předvolbu „Řadit“ – včetně **„Velké a zároveň staré“** (velikost × doba bez otevření), které je výchozí u Starých souborů.

## 0.8.4

- **Úklid → Staré soubory** (nový modul): soubory, které jsi dlouho neotevřel, už od 1 MB (výchozí 10 MB, neotevřené 1+ rok; 6 měsíců – 2 roky). Modul „Velké soubory“ zůstává pro to, co zabírá nejvíc místa.
- **Plný přístup k disku:** spolehlivější rozpoznání – kontroluje víc chráněných míst, takže po zapnutí oprávnění už aplikace neukazuje „Omezený přístup“.

## 0.8.3

Bezpečnostní úpravy podle revize Project CodeGuard:
- **Odinstalace:** soubory nalezené jen podle názvu aplikace (ne podle bundle ID) nejsou předem zaškrtnuté a jsou označené „podle názvu, ověř“ – mohou patřit jiné aplikaci.
- **Mazání ze ZIP** bere názvy položek doslova (`zip -nw`) – položka pojmenovaná `*` už nesmaže celý archiv; názvy začínající „-“ se odmítnou.
- **FTPS** vyžaduje minimálně TLS 1.2.
- **Release:** GitHub Actions připnuté na commit SHA (+ Dependabot), oprávnění jen na úrovni jobu, ke každému vydání **SBOM** a podepsaná **provenance buildu** (Sigstore – ověření `gh attestation verify FileTool-<verze>.zip -R johnyvobruba/FileTool`).

## 0.8.2

- **SMB sdílení při spuštění:** u SMB serveru zaškrtni „Připojit při spuštění FileTool“ – po startu se sdílení tiše připojí (heslo z Klíčenky macOS, žádné dialogy) a jsou hned v Zařízeních v bočním panelu. Nedostupná (bez VPN) se přeskočí; ručně je připojíš z nabídky Server → „Připojit automatická SMB sdílení“.
- **Výběr skupiny:** v dialogu ⌘K je u pole Skupina nabídka existujících skupin (i podskupin); novou stačí napsat. Seznam uložených serverů vlevo je rozdělený podle skupin.

## 0.8.1

- **Adresa serveru jakkoliv:** do pole Server jde vložit i celou adresu – `smb://nas/Data/Projekty`, `\\nas\Data`, `sftp://user@host:2222/var/log`, `ftp://…` – rozloží se sama do protokolu, serveru, portu, uživatele a cesty.
- **SMB bez názvu sdílení:** prázdné pole Sdílení = macOS po přihlášení nabídne seznam sdílení na serveru.
- Pole „Skupina“ (dříve „Složka“) je jen pro zařazení v seznamu serverů a je nepovinné.

## 0.8.0

- **SMB sdílení** (Windows, NAS) v připojení k serverům: připojí se jako disk a panel ho prochází jako běžnou složku (všechny operace F3–F8, hledání, Úklid). Heslo spravuje macOS (dialog s uložením do Klíčenky), odpojení ⏏ v bočním panelu. Import / export JSON umí `"proto": "smb"`.
- **Plný přístup k disku na jednom místě:** nová stránka Nastavení → Oprávnění (stav, odkaz do Nastavení systému, ukázání FileTool ve Finderu, restart). Při spuštění se FileTool jednou zeptá, jestli přístup nastavit – pak už se macOS neptá u každé složky zvlášť.
- **Systémový odpad:** u každé kategorie je vidět, kolik je zaškrtnuto (z celkové velikosti).
- Opravy Úklidu: filtry Typ a Stáří jako rozbalovací nabídky (přetékaly do bočního menu), opakované nebo zastavené hledání už nepřimíchá výsledky z předchozího běhu (týká se i Hledání).

## 0.7.0

- **Úklid jako samostatný nástroj** (⇧⌘U, ✨ v liště) ve stylu CleanMyMac – vlevo moduly:
  - **Chytrá kontrola** – jedno tlačítko prohledá systémový odpad, soubory nad 500 MB a zbytky po smazaných aplikacích; výsledky na kartách, odpad lze rovnou vyčistit;
  - **Systémový odpad** – kategorie se zaškrtávátky a velikostí (mezipaměti, logy, uložený stav oken, Xcode, vývojářské mezipaměti, stažené instalátory, aktualizace iOS, přílohy Mailu, zálohy iPhonu, Koš), rozbalitelné po položkách; mezipaměti běžících aplikací se předem nezaškrtávají;
  - **Velké a staré soubory** – filtry podle typu (video, archivy, obrazy disků, dokumenty, hudba) a stáří;
  - **Odinstalace aplikací** – aplikace s velikostí a datem posledního spuštění; odinstaluje i související data (Application Support, Caches, Preferences, Containers, LaunchAgents…); hledání zbytků po už smazaných aplikacích;
  - **Mapa disku** – barevná mapa (treemap), kliknutím do složky, drobečková navigace, seznam s podíly;
  - **Duplicity** – stejný obsah (velikost → SHA-256), automatický výběr „ponechat nejnovější / nejstarší“, v každé skupině vždy zůstane jedna kopie.
  - Vše do Koše po potvrzení (jen vysypání Koše je trvalé). Systémové složky se nenabízejí. Upozornění, když chybí Plný přístup k disku.

## 0.6.0

- **Úklid disku** (⇧⌘U, ikona v liště) – najde, co zabírá místo:
  - **Velké soubory** nad zvolenou velikost (50 MB – 5 GB) ve vybrané složce;
  - **Nepoužívané soubory** – neotevřené 6 měsíců až 3 roky (datum posledního otevření ze Spotlightu, jinak datum změny);
  - **Nepoužívané aplikace** – dlouho nespuštěné aplikace (bez aplikací Apple) i s velikostí;
  - **Mezipaměti a logy** – ~/Library/Caches, Logs, Xcode DerivedData / Archives / DeviceSupport, npm, ~/.cache, přílohy Mailu.
  - Mazání jen **do Koše** po potvrzení (lze vrátit); u mezipamětí se maže jen obsah složky. Systémové složky se neprohledávají ani nenabízejí, soubory jen v iCloudu se přeskočí.
  - Výsledky lze zobrazit ve Finderu nebo v aktivním panelu (např. zkopírovat na externí disk a pak smazat).

## 0.5.1

- **Servery ve složkách** jako v SSHTool: skupina „Zákazník A/Praha“ = podsložka. Boční panel ukazuje rozbalovací strom (stav se pamatuje), nabídka Server má vnořené podnabídky, v dialogu ⌘K je pole Složka. Struktura se přebírá i při importu ze SSHTool.
- **Oprava:** označení mezerníkem už nevrací kurzor na první řádek – zůstane u označeného souboru a posune se na další.

## 0.5.0

- **Boční panel** (jako Finder / JABKOmmander): Zařízení s volným místem a tlačítkem pro vysunutí, Oblíbené složky (+ přidá složku aktivního panelu, lze sem přetáhnout složku; pravým tlačítkem odebrat / přesunout) a uložené Servery. Kliknutí otevře místo v aktivním panelu. Skrytí tlačítkem v liště nebo ⌃⌘S.
- **Hledání** (⌘F, Alt+F7, lupa v liště):
  - název s maskou (`*.log;report` – bez hvězdičky hledá část názvu), volitelně text v souborech (jen textové do 50 MB), skryté soubory;
  - i uvnitř archivů ZIP, tar.gz, 7z… (názvy);
  - výsledky průběžně, Enter / dvojklik = přejít na soubor v panelu;
  - „Zobrazit v aktivním panelu“ – výsledky jako seznam v panelu, funguje na ně F3–F8, označování i přetahování.

## 0.4.0

- **Import serverů:** v Nastavení → Servery jedním tlačítkem načteš servery ze SSHTool (SSH jako SFTP/SCP, FTP/FTPS; RDP a telnet se vynechají), nebo importuješ JSON (formát FileTool i SSHTool). Export bez hesel a vzor JSON pro kolegy. Hesla se nikdy neimportují.
- **Skupiny serverů:** v nabídce Server jsou servery rozdělené do složek podle skupin ze SSHTool / JSON.
- **Nastavitelná šířka panelů:** táhni za dělicí čáru mezi panely, dvojklik vrátí rozdělení na polovinu. Šířka se pamatuje.

## 0.3.3

- **Nové okno Nastavení** ve stylu SSHTool: postranní navigace (Obecné, Vzhled, Servery, Klávesové zkratky, O aplikaci), karty profilů s náhledem seznamu souborů, správa uložených serverů, přehled zkratek.

## 0.3.2

- **Popisky ikon:** po najetí myší na ikonu se po chvilce ukáže bublina s popisem.

## 0.3.1

- **Ozubené kolečko v horní liště** otevře Nastavení (⌘,), stejně jako v SSHTool.
- Úklid varování kompilátoru (příprava na Swift 6).

## 0.3.0

- **Servery v panelu – SFTP, SCP a FTP/FTPS** (⌘K připojit, ⇧⌘K odpojit, nabídka „Server“ nad panelem):
  - uložená připojení (bez hesla); heslo volitelně v Klíčence macOS, jinak se zadá při připojení;
  - SFTP a SCP přes systémové ssh – funguje přihlášení klíčem, agentem i `~/.ssh/config`; jedno přihlášení na panel (ControlMaster);
  - neznámý klíč serveru se ukáže k potvrzení (výchozí volba Odmítnout), OTP / ověřovací kódy přes dialog;
  - FTP přes curl, výchozí FTPS s explicitním TLS; heslo jde curl přes stdin, ne v argumentech;
  - F5/F6 stahování a nahrávání (i složky přes SFTP/SCP), F7 nová složka, F8 mazání (i složek s obsahem), ⇧F6 přejmenování;
  - F3/Enter stáhne soubor do dočasné složky a otevře ho; F4 upraví kopii a po uložení ji nahraje zpět;
  - stažené soubory dostanou karanténu macOS (Gatekeeper).
- **ZIP s heslem:** Zabalit (⌥⌘5) má pole pro heslo – ZIP AES-256 přes 7-Zip (je-li nainstalovaný, jinak klasický ZipCrypto), nebo 7z se šifrovanými názvy.
- **Tlačítko „stejná složka jako vedlejší panel“** v liště nad panelem (u serveru otevře stejné spojení).
- **Volba editoru pro F4:** výchozí textový editor (TextEdit) nebo jakýkoliv nalezený (VS Code, Sublime, BBEdit, CotEditor, Nova, Zed…), případně vlastní aplikace.

## 0.1.0

- **Dva panely se záložkami** (⌘T nová, ⌘W zavřít, ⌃Tab další). Tab přepíná panel. Složky panelů a záložek se pamatují.
- **Výběr disku a míst:** připojené svazky, Domů, Plocha, Dokumenty, Stažené, Aplikace, iCloud Drive (⌥⌘1 / ⌥⌘2). Volné místo a kapacita svazku.
- **Seznam souborů jako v TC:**
  - sloupce Název, Přípona, Velikost, Datum, Atributy; řazení kliknutím na hlavičku; složky nahoře, `[..]` pro nadřazenou;
  - označování mezerníkem (označené červeně), ⌘A vše, ⌘D nic, `+` / `-` podle masky;
  - rychlé hledání psaním; Enter otevřít, ⌫ nebo ⌘↑ nadřazená složka;
  - automatická obnova při změně ve složce.
- **Funkční klávesy F3–F8 a ekvivalenty pro Mac** (⌘3–⌘8):
  - zobrazit (Quick Look), upravit, kopírovat, přesunout, nová složka, smazat do Koše (⇧ = trvale);
  - přejmenovat (⇧F6 / ⌘R).
- **Kopírování a přesun s průběhem:** bajty, rychlost, zrušení; dotaz při kolizi (přepsat / přeskočit); přesun v rámci svazku bez kopírování.
- **Příkazový řádek** dole: příkaz se spustí ve složce aktivního panelu (`cd` změní složku panelu), výstup v okně.
- **Barevné profily ze SSHTool** (Midnight, Tokyo, Nord, Catppuccin, Emerald, Walnut, Sandstone, Arctic). Ikona v Docku podle profilu.
- **Automatické aktualizace** z GitHub Releases s podpisem Ed25519 (jako SSHTool).

## 0.2.0

- **Archivy jako složky** (inspirace JABKOmmander). Enter na archivu ho otevře v panelu, ⌫ nebo `[..]` z něj vede ven.
  - Čtení přes libarchive obsaženou v macOS: ZIP, JAR, TAR, GZ, TGZ, BZ2, XZ, ZST, 7z, RAR, ISO, CPIO, XAR, CAB.
  - Šifrovaný ZIP (AES i ZipCrypto): heslo se zadává do dialogu a pamatuje se jen do ukončení aplikace. Šifrované položky mají v atributech 🔒.
- **Práce s obsahem archivu:**
  - F3 (náhled), Enter (otevření) a F4 (úprava kopie) fungují i na souborech v archivu. Soubor se rozbalí do dočasné složky a karanténa se zdědí z archivu.
  - F5 rozbalí označené do druhého panelu. F6 ze ZIP rozbalí a položky odebere až po úspěšném rozbalení.
  - F5 nebo F6 do panelu s otevřeným ZIP přidá soubory na aktuální vnitřní cestu (také přetažením). ZIP se po změně ověří (`zip -T`). Originály jdou při přesunu do Koše až po ověření.
  - F8 v ZIP odebere položky (se zpětným ověřením). Ostatní formáty jsou jen pro čtení.
- **Zabalit (⌥⌘5, v TC Alt+F5):** označené položky do druhého panelu jako ZIP, tar.gz nebo tar.xz.
- **Rozbalit (⌥⌘9, v TC Alt+F9):** označené archivy do druhého panelu, volitelně každý do vlastní složky. Uvnitř archivu rozbalí celý obsah aktuální složky nebo označené položky.
- **Bezpečné rozbalování:**
  - položky s absolutní cestou nebo `..` se přeskočí (zip-slip);
  - symbolické a pevné odkazy ani speciální soubory se nerozbalí;
  - práva bez setuid a setgid.
- **Zatím nejde:** vytvořit šifrovaný ZIP a zapisovat do jiných formátů než ZIP. Šifrované 7z a RAR přidá 7-Zip v další verzi spolu s DMG a GPG/age.
