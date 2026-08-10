# NextGPU SteamExtensions

Permanent in-repo Playnite Steam library extension for NextGPU hosts. Replaces the official JosefNemec `SteamLibrary_Builtin_2_40.pext` download with a forked Steam library package.

## Components

| Folder | Type | Role |
|--------|------|------|
| **SteamLibrary_NextGPU** | Game library plugin | Drop-in fork of SteamLibrary **2.40**; same `PluginId` `CB91DFC9-B977-43BF-8E70-55F46E410FAB` |

Setup and `Update-PlayniteLibraries.ps1` install it via `Install-NextGpuSteamExtensions` in `Playnite-Common.ps1`. Epic remains on the official `.pext` download.

## Upstream version

- **SteamLibrary**: JosefNemec PlayniteExtensions **2.40** (`SteamLibrary_Builtin_2_40.pext`)
- Documented in `extension.yaml` as version **2.40.1** (NextGPU branding only)

To cherry-pick upstream fixes: extract a newer official `.pext`, diff against `build/SteamLibrary_NextGPU`, keep `extension.yaml` Id/Name, rebuild.

## Build (developers)

Requires Windows.

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
```

**Commit `build/`** after fork changes so `Setup-PlayniteSteam.bat` works without re-downloading.

If no local Steam extension exists, the build script downloads `SteamLibrary_Builtin_2_40.pext` into `.cache/` (dev/build only — end-user setup never downloads Steam).

## Install / repair

Automatic during setup and library update. Manual:

```powershell
.\Install-SteamExtensions.ps1
.\Install-SteamExtensions.ps1 -PlayniteInstallDir Z:\Playnite
```

`Install-NextGpuSteamExtensions`:

1. Copies `build/SteamLibrary_NextGPU` to `<install>\Extensions\`
2. **Removes** `Extensions/SteamLibrary_Builtin` if present (duplicate PluginId)
3. Preserves `ExtensionsData/CB91DFC9-.../config.json` (same PluginId)

## Migration from SteamLibrary_Builtin

On first setup or update after upgrading this repo:

1. `SteamLibrary_Builtin` folder is removed
2. `SteamLibrary_NextGPU` is installed
3. Steam `ExtensionsData` and existing Steam rows in `games.db` are unchanged (same PluginId)

## Troubleshooting

| Issue | Check |
|-------|--------|
| Setup fails: build not found | Run `Build-SteamExtensions.ps1` and commit `build/`, or pull latest repo |
| Two Steam extensions | Remove `SteamLibrary_Builtin`; keep only `SteamLibrary_NextGPU` |
