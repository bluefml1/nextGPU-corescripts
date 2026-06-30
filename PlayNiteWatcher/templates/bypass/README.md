# Bypass seed templates

Bundled assets for **Setup-PlayniteBypassAutomated.ps1** (NextGPU Playnite → Bypass → step 1).

## Contents

| Path | Purpose |
|------|---------|
| `RunAsTool.rnt` | RunAsTool program list (File → Export List on a reference machine) |
| `Game Shortcuts/*.lnk` | Pre-built RunAsTool shortcuts copied to `{parent}\Game Shortcuts` on setup |
| `Game Shortcuts/*.ps1` / `*.cmd` | Optional composite launcher examples (Helper + app); Review and Sync can regenerate |

## Composite launchers (Helper column)

For games that need an extra process alongside the RunAsTool shortcut (e.g. Garena):

1. Keep the `.lnk` in **File** (e.g. `Garena FC Online.lnk`).
2. In **Review and Sync**, enter the helper path in **Helper** (e.g. `Z:\Garena\Garena\Garena.exe`). Double-click the cell to browse.
3. Sync auto-generates `{DisplayName}.ps1` + `{DisplayName}.cmd` in Game Shortcuts. The script starts the helper, then the `.lnk`.
4. Playnite play path = `.cmd` (thin wrapper that `start`s the `.lnk`). Leave **Helper** empty for normal shortcut-only launches (Genshin, Wuthering Waves, etc.).

## Refreshing the seed

1. On a reference host, configure RunAsTool (Edit mode, Run as administrator for each app).
2. **File → Export List** → save as `RunAsTool.rnt` in this folder (replace existing).
3. Create shortcuts in a Game Shortcuts folder, then copy all `.lnk` files into `Game Shortcuts/` here.
4. Optionally add example `.ps1` / `.cmd` composite launchers (see `Garena FC Online.example.*`).
5. Ensure game executables use paths that exist on target machines (RunAsTool stores absolute paths).

## Notes

- Setup **copies** from this folder; it does not move or modify these files.
- After automated setup, run **Review and Sync** in the NextGPU Playnite page to bind shortcuts to Playnite.
