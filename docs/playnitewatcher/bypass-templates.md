# Bypass seed templates

Bundled assets for **Setup-PlayniteBypassAutomated.ps1** (NextGPU Bypass → Setup).

## Contents

| Path | Purpose |
|------|---------|
| `RunAsTool.rnt` | RunAsTool program list (File → Export List on a reference machine) |
| `Game Shortcuts/*.lnk` | Pre-built RunAsTool shortcuts; **setup copies only entries named in `bypass-sync-list.json`** |
| `Game Shortcuts/*.ps1` / `*.cmd` | Generated at sync when `launches[]` has pre-launch paths |

## Sync list scope

The seed folder may contain many `.lnk` files for reference. **Setup does not bulk-copy the folder.** It copies `{shortcutName}.lnk` only for each row in [`PlayNiteWatcher/config/playnite/bypass-sync-list.json`](../../PlayNiteWatcher/config/playnite/bypass-sync-list.json). RunAsTool import uses a **filtered** subset of `RunAsTool.rnt` matched by sync-list `title`, `shortcutName`, or `launches[].path` exe leaf.

Add or edit sync-list entries on the **Bypass → Sync** tab (or **PlayNite → Library → Add to Bypass Sync**) before running Setup Bypass.

## Pre-launches (`launches[]`)

Launch order: each `launches[]` path (with optional `delaySec`), then **`{shortcutName}.lnk`** (always the final step).

1. Add `launches` for any exe that must start before the shortcut, e.g. `{ "path": "Z:\\...\\gxxapphelper.exe", "delaySec": 2 }`.
2. Keep the `.lnk` named `{shortcutName}.lnk` in Game Shortcuts.
3. Sync auto-generates `{shortcutName}.ps1` + `{shortcutName}.cmd`. Playnite play path = `.cmd`.

Legacy `helperPath`, `exe`, and `appExe` in JSON are migrated on read but are not required.

## Refreshing the seed

1. On a reference host, configure RunAsTool (Edit mode, Run as administrator for each app).
2. **File → Export List** → save as `RunAsTool.rnt` in this folder (replace existing).
3. Create shortcuts in a Game Shortcuts folder, then copy `.lnk` files into `Game Shortcuts/` here (more than you deploy is fine).
4. Update `bypass-sync-list.json` with the `shortcutName` values you want setup to deploy.
5. Ensure game executables use paths that exist on target machines (RunAsTool stores absolute paths).

## Notes

- Setup **copies** listed shortcuts only; it does not move or modify seed files.
- After automated setup, run **Review and Sync** on the Bypass tab to update Playnite launch paths for sync-list entries.
