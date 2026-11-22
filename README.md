# FileTool

Dvoupanelový správce souborů pro macOS ve stylu Total Commanderu. Vzhled a barevné profily jsou stejné jako v SSHTool.

## Sestavení

    swift build -c release          # kontrola překladu
    ./build-app.sh                  # → build/FileTool.app
    ./build-app.sh --install        # → /Applications/FileTool.app

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

## První publikace (jednou)

    git init -b main && git add -A && git commit -m "FileTool 0.1.0"
    gh repo create FileTool --public --source=. --push
    swift scripts/generate-update-key.swift                     # veřejný klíč → update-public-key.txt
    gh secret set UPDATE_SIGNING_KEY < ~/.filetool-update-signing-key
    ./publish.sh
