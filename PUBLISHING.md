# Vydávání FileTool – jen pro autora

> ⚠️ **Toto není návod k instalaci.** Pro instalaci viz [README – Instalace](README.md#instalace).
> Příkazy níže zakládají repozitář a nahrávají soubory **z aktuální složky** na GitHub – spouštěj je jen
> ve složce se zdrojovými kódy FileTool, nikdy v domovské složce.

## První publikace (jednou, už proběhla)

```bash
cd ~/cesta/k/FileTool-app            # složka se zdrojovými kódy (Package.swift, build-app.sh…)
git init -b main && git add -A && git commit -m "FileTool 0.1.0"
gh repo create FileTool --public --source=. --push
swift scripts/generate-update-key.swift                       # soukromý klíč → ~/.filetool-update-signing-key, veřejný → update-public-key.txt
gh secret set UPDATE_SIGNING_KEY < ~/.filetool-update-signing-key
```

## Nová verze

1. Zvyš `VERSION` v `build-app.sh` a doplň sekci `## x.y.z` do `CHANGELOG.md`.
2. `./publish.sh` (nebo průvodce `../release.sh`) – kontrola, commit, push.
3. GitHub Actions sestaví, podepíše, přiloží SBOM a provenance a vytvoří Release.
