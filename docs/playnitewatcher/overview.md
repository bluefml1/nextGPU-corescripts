# PlayNiteWatcher Architecture Overview

## What Is PlayNiteWatcher?

PlayNiteWatcher bridges Playnite (a universal game library manager) and Sunshine (a self-hosted game streaming server) by:

1. **Watching** for game launch events from Playnite's fullscreen mode
2. **Exporting** the Playnite library to Sunshine's `apps.json`
3. **Binding** bypass shortcuts so Sunshine can monitor game-exit events even through launcher processes
4. **Importing** desktop apps into Playnite's library via `es.exe` (Everything) scanning

---

## Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Sunshine                                                      │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  global_prep_cmd / global_shutdown_cmd               │    │
│  │  → PlayNiteWatcher.ps1 (watcher/)                    │    │
│  │  → PlayniteWatcher-EndScript.ps1                      │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  apps.json (per-game commands)                       │    │
│  │  → SunshineExport-Core.ps1 (export/)                 │    │
│  │  → Export-SunshineFromPlaynite.ps1                   │    │
│  └──────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Playnite (LiteDB: library/games.db)                        │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Playnite-Common.ps1 (LOADER → src/*.psm1)           │    │
│  │  Playnite-BypassCommon.ps1 (LOADER → src/bypass/*)   │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  src/ modules:                                        │    │
│  │  Playnite-Database.psm1   — LiteDB init, game reads   │    │
│  │  Playnite-Everything.psm1 — es.exe scanning, allowlist │    │
│  │  Playnite-Allowlist.psm1  — NameId mapping, types      │    │
│  │  Playnite-Export.psm1    — Steam detection, export     │    │
│  │  Playnite-Import.psm1    — desktop import, repo root   │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  src/bypass/ modules:                                 │    │
│  │  Bypass-Config.psm1      — config init, read/write    │    │
│  │  Bypass-RunAsTool.psm1   — RunAsTool install, launch  │    │
│  │  Bypass-Shortcuts.psm1   — shortcut sync, library bind│    │
│  │  Bypass-Sync.psm1        — review UI, publish, seed   │    │
│  │  Bypass-Uninstall.psm1   — uninstall hooks, cleanup   │    │
│  └──────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## How PlayNiteWatcher.ps1 Plugs Into Sunshine

In `sunshine.conf`, add to `global_prep_cmd`:

```ini
global_prep_cmd = C:\path\to\PlayNiteWatcher\watcher\PlayNiteWatcher.ps1
```

And in Sunshine's per-app `prep-cmd undo` / `global_shutdown_cmd`:

```ini
global_shutdown_cmd = C:\path\to\PlayNiteWatcher\watcher\PlayniteWatcher-EndScript.ps1
```

`PlayNiteWatcher.ps1` registers a PowerShell engine event (`GamePathReceived`) to receive the launched game path, then calls `Watch-AndApplyFocusToGame` to monitor the process tree and restore focus when the game exits.

---

## How LiteDB Is Loaded

`Playnite-Database.psm1` handles all LiteDB access:

```
Initialize-LiteDbFromPlayniteInstall
  → Loads LiteDB.Bson.dll from Playnite install directory
  → Connects to library/games.db

Get-PlayniteGameRecordsFromLiteDb
  → Opens db, queries 'Games' collection
  → Maps BSON documents to PSCustomObjects

Ensure-PlayniteLibraryDatabaseUnlocked
  → Tries to open db, returns error if locked by Playnite
  → Callers must close Playnite before reading
```

**Critical**: `games.db` is locked by Playnite while it runs. Read operations must either:
- Close Playnite first, or
- Use `Move-PlayniteLibraryDatabaseAside` to work on a copy

---

## Named-Pipe IPC Flow

The watcher communicates with Playnite via:

1. **Engine events** (`Register-EngineEvent`) — receives `GamePathReceived` messages from Playnite
2. **Process tree watching** — monitors the game process and its children for exit events
3. **Named pipe** (via `eventLogs.ps1`) — Sunshine watches Playnite's log for import-complete events

```
Playnite (game launches)
  → EngineEvent: GamePathReceived
      → PlayNiteWatcher.ps1
          → Watch-AndApplyFocusToGame
              → Loop: Get-ProcessByExecutablePath
              → On exit: Focus Restore
```

---

## Bypass Shortcuts

Bypass shortcuts solve the problem of games that launch through intermediate launchers (Steam, Epic, Battle.net). Sunshine can't monitor the actual game process — only the launcher. Bypass shortcuts create `.cmd` wrappers that:

1. Launch the game directly (bypassing the launcher), then
2. Create a named pipe / event log entry that Sunshine's `eventLogs.ps1` can watch

```
Playnite library entry
  → Sync-PlayniteBypassShortcuts.ps1
      → Bypass-Shortcuts.psm1 (sanitize, resolve exe, create .cmd)
      → Bypass-Sync.psm1 (bind to Playnite library via LiteDB)
          → Bypass-Uninstall.psm1 (on removal: unbind from library)
```

---

## Key Module Dependencies

```
Playnite-Common.ps1 (loader)
  ├── Playnite-Path.psm1          (InstallDir, 7Zip, Process, Start-PlayniteProcess)
  ├── Playnite-Database.psm1     (LiteDB, BSON, GameRecords)
  ├── Playnite-Steam.psm1        (SQLite tools, Extension install)
  ├── Playnite-Everything.psm1   (es.exe, Allowlist scanning)
  ├── Playnite-Allowlist.psm1     (NameId, AllowlistTypes)
  ├── Playnite-Export.psm1       (Steam detection, Get-ExportablePlayniteGames)
  ├── Playnite-Import.psm1       (RepoRoot, GamesAppsManifest)
  └── src/bypass/*.psm1

Playnite-BypassCommon.ps1 (loader)
  └── src/bypass/*.psm1
```

---

## Playnite → Sunshine Export Pipeline

```
Playnite library (games.db)
  → Playnite-Database.psm1
      → Get-PlayniteGameRecordsFromLiteDb
      → Get-PlayniteLibraryGameStats

export/SunshineExport-Core.ps1
  → Resolves app name (NameID for Steam, folder name for Epic)
  → Builds apps.json entry with:
      • name — Sunshine app identifier
      • cmd — Playnite launch command
      • prep-cmd undo — eventLogs.ps1 for exit detection

Playnite Browser Extension (SunshineAppExport/)
  → Triggers export from within Playnite UI
  → Writes to Sunshine config directory
```
