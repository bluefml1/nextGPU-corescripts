# SunshineAppExport

This is a [Playnite](https://github.com/JosefNemec/Playnite) addon that creates custom [Sunshine](https://github.com/LizardByte/Sunshine) apps from your Playnite library for use with [Moonlight](https://github.com/moonlight-stream).

By default it looks for Sunshine's `apps.json` at `C:\Program Files\Sunshine\config\apps.json`. You can choose another path in the export dialog.

## Export behavior

### Steam and Epic

- Sunshine **`name`** = **NameID** (Steam AppID, e.g. `730` for CS2; Epic = install folder name).
- **No** `image-path` (matches Add-SteamGames-style Steam entries).
- **`prep-cmd`** undo: `powershell.exe ... eventLogs.ps1` (requires that script under `C:\Program Files\Sunshine\scripts\`).
- Hidden **`playnite-id`** field stores the Playnite game GUID for [PlayNite Watcher](user-guide.md) Installer.
- Writes **`resolved-appids.json`** and **`resolved-appids.txt`** next to `apps.json`, using the **same CRC AppID algorithm** as [`PlayNiteWatcher/Add-SteamGames.ps1`](../../PlayNiteWatcher/Add-SteamGames.ps1). Launch lines use `&"Playnite.DesktopApp.exe" --start <playniteGameId>` (PowerShell call operator) instead of `steam://rungameid/...`.

Example `resolved-appids.txt` line for CS2:

```text
215449499: &"C:\Program Files\Playnite\Playnite.DesktopApp.exe" --start <your-playnite-guid>
```

(`215449499` is the AppID for NameID `730`.)

### Other platforms (GOG, etc.)

Legacy export: display name, box art PNG, and `detached` Playnite launch (same as older versions of this extension).

## Workflow with PlayNite Watcher

1. Playnite → **Extensions → Sunshine App Export → Export all games** (UAC copies config files).
2. Run **`Installer.bat`** from the PlayNite Watcher repo → **Install** (sets `cmd` to `PlayniteWatcher.ps1` and installs the Playnite extension).

<img src="dialog_screenshot.png" width="352">
