# voidtools Everything (optional)

Desktop allowlist import uses **`es.exe` only** — no Everything UI is started by setup.

## Before desktop import (step 7)

1. Install [voidtools Everything](https://www.voidtools.com/) (setup can install silently on first run).
2. **`es.exe` is separate** from the main installer — setup auto-downloads it from [voidtools/ES](https://github.com/voidtools/ES/releases) into `tools\everything\es.exe` when missing.
3. **IPC needs the Everything app**, not only the Windows service. Setup starts `Everything.exe -startup` (minimized) automatically when `es.exe` gets Error 8; you can also start it manually from the tray.
4. When downloaded, `es.exe` is placed in `tools\everything\` and copied next to `C:\Program Files\Everything\es.exe` when permissions allow.
4. Confirm IPC works (setup logs the same probe under `Everything debug:` in `Setup-PlayniteSteam.log`):
   ```powershell
   $es = ".\tools\everything\es.exe"
   if (-not (Test-Path $es)) { $es = "${env:ProgramFiles}\Everything\es.exe" }
   & $es -max-results 1 -timeout 5000 playnitewatcher_probe
   echo $LASTEXITCODE   # 0 = OK, 8 = Everything not running
   ```

Setup places `es.exe` here automatically when Everything is installed but the CLI was never downloaded. You can also copy it manually from [voidtools/ES](https://github.com/voidtools/ES/releases).

## Skip Everything (directory walk)

```powershell
.\Setup-PlayniteSteam.ps1 -SkipEverythingInstall ...
```

## Indexing

In Everything → **Indexes**, include data drives (e.g. `Z:\`) so allowlisted apps under `Z:\Adobe` are found.
