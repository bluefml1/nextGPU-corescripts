# NextGPU SteamExtensions

Permanent in-repo Playnite extensions for NextGPU hosts. Replaces the official JosefNemec `SteamLibrary_Builtin_2_40.pext` download with a forked Steam library plus a bypass preservation plugin.

## Components

| Folder | Type | Role |
|--------|------|------|
| **SteamLibrary_NextGPU** | Game library plugin | Drop-in fork of SteamLibrary **2.40**; same `PluginId` `CB91DFC9-B977-43BF-8E70-55F46E410FAB` |
| **NextGPUBypassGuard** | Generic plugin | Reads `ExtensionsData/NextGPU/bypass-bindings.json` and restores `.lnk` play paths after library import |

Setup and `Update-PlayniteLibraries.ps1` install both via `Install-NextGpuSteamExtensions` in `Playnite-Common.ps1`. Epic remains on the official `.pext` download.

## Upstream version

- **SteamLibrary**: JosefNemec PlayniteExtensions **2.40** (`SteamLibrary_Builtin_2_40.pext`)
- **Playnite SDK**: NuGet `PlayniteSDK` **6.11.0** (matches Playnite 10.55.x portable)
- Documented in `extension.yaml` as version **2.40.1** (NextGPU branding only)

To cherry-pick upstream fixes: extract a newer official `.pext`, diff against `build/SteamLibrary_NextGPU`, keep `extension.yaml` Id/Name, rebuild.

## Build (developers)

Requires Windows + .NET SDK.

```powershell
cd PlayNiteWatcher\SteamExtensions
.\Build-SteamExtensions.ps1
# Or when a local Playnite install already has SteamLibrary_Builtin:
.\Build-SteamExtensions.ps1 -PlayniteInstallDir Z:\Playnite
```

Output:

```text
SteamExtensions\build\
  SteamLibrary_NextGPU\    SteamLibrary.dll + Resources + extension.yaml
  NextGPUBypassGuard\      NextGPUBypassGuard.dll + extension.yaml
```

**Commit `build/`** after C# or fork changes so `Setup-PlayniteSteam.bat` works without SDK.

If no local Steam extension exists, the build script downloads `SteamLibrary_Builtin_2_40.pext` into `.cache/` (dev/build only — end-user setup never downloads Steam).

## Install / repair

Automatic during setup and library update. Manual:

```powershell
.\Install-SteamExtensions.ps1
.\Install-SteamExtensions.ps1 -PlayniteInstallDir Z:\Playnite
```

`Install-NextGpuSteamExtensions`:

1. Copies `build/SteamLibrary_NextGPU` and `build/NextGPUBypassGuard` to `<install>\Extensions\`
2. **Removes** `Extensions/SteamLibrary_Builtin` if present (duplicate PluginId)
3. Preserves `ExtensionsData/CB91DFC9-.../config.json` (same PluginId)

## Bypass bindings

On each bypass sync, PowerShell publishes:

`<PlayniteInstall>/ExtensionsData/NextGPU/bypass-bindings.json`

```json
{
  "bypassesPath": "Z:\\Game Shortcuts",
  "bindings": [
    {
      "playniteId": "guid",
      "title": "Wuthering Waves",
      "launchPath": "Z:\\Game Shortcuts\\Wuthering Waves.lnk",
      "syncType": "OutsideAllowlist"
    }
  ],
  "updatedAt": "2026-06-26T..."
}
```

`NextGPUBypassGuard` reconciles on startup and after debounced `Games.ItemUpdated` events (library import).

PowerShell fallback: `Update-PlayniteLibraries.ps1` calls `Invoke-ReapplyPlayniteBypassShortcuts` in `finally`.

## Migration from SteamLibrary_Builtin

On first setup or update after upgrading this repo:

1. `SteamLibrary_Builtin` folder is removed
2. `SteamLibrary_NextGPU` is installed
3. Steam `ExtensionsData` and existing Steam rows in `games.db` are unchanged (same PluginId)
4. Run `Sync-PlayniteBypassShortcuts.ps1 -SyncOnly` once to publish `bypass-bindings.json` if you already have bypass shortcuts

## Troubleshooting

| Issue | Check |
|-------|--------|
| Setup fails: build not found | Run `Build-SteamExtensions.ps1` and commit `build/`, or pull latest repo |
| Two Steam extensions | Remove `SteamLibrary_Builtin`; keep only `SteamLibrary_NextGPU` |
| Bypass reverts after Update All | Confirm `NextGPUBypassGuard` loaded in `playnite.log`; run `-SyncOnly`; check `bypass-bindings.json` |
| Wrong row updated on `-SyncOnly` | Re-run interactive sync so binding has `syncType: OutsideAllowlist` for Steam games |
| Sunshine missing Genshin/Naraka | Re-export after bypass sync; export matches by binding before exe leaf (C7) |

## Conflict matrix (summary)

| ID | Conflict | Owner |
|----|----------|-------|
| C1 | Steam import overwrites bypass path | NextGPUBypassGuard + PS re-apply |
| C2 | Official Steam download on setup | `Install-NextGpuSteamExtensions` only |
| C3 | No re-apply after UpdateLib | `Update-PlayniteLibraries.ps1` finally |
| C4 | SyncOnly wrong row | `syncType` + `-OutsideAllowlist` |
| C7 | Sunshine export skip for `.lnk` paths | `Get-ExportableDesktopPlayniteGames` binding match |

Full matrix: [end-to-end.md](end-to-end.md#bypass-vs-steam-conflict-matrix).

## Testing

```powershell
cd PlayNiteWatcher
.\Test-BypassShortcutReview.ps1
```

Integration (manual):

1. `Sync-PlayniteBypassShortcuts.ps1 -Interactive` — sync Wuthering as Outside allowlist
2. `Update-PlayniteLibraries.ps1`
3. Verify Playnite **Configure → Play** still shows `Z:\Game Shortcuts\*.lnk`
4. `Export-SunshineFromPlaynite.ps1` — Genshin/Naraka still exported (no `Desktop export skipped` for bound games)
