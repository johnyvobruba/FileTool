# FileTool – historie změn

Dvoupanelový správce souborů pro macOS ve stylu Total Commanderu, vzhledem i barevnými profily jako SSHTool.
Sekce `## x.y.z` se automaticky použije jako poznámky k vydání na GitHubu.

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
