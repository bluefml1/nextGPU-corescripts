# PlayNiteWatcher Architecture Overview

## What Is PlayNiteWatcher?

PlayNiteWatcher bridges Playnite (a universal game library manager) and Sunshine (a self-hosted game streaming server) by:

1. **Watching** for game launch events from Playnite's fullscreen mode
2. **Exporting** the Playnite library to Sunshine's `apps.json`
3. **Importing** desktop apps into Playnite's library via `es.exe` (Everything) scanning

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
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  src/ modules:                                        │    │
│  │  Playnite-Database.psm1   — LiteDB init, game reads   │    │
│  │  Playnite-Everything.psm1 — es.exe scanning, allowlist │    │
│  │  Playnite-Allowlist.psm1  — NameId mapping, types      │    │
│  │  Playnite-Export.psm1    — Steam detection, export     │    │
│  │  Playnite-Import.psm1    — desktop import, repo root   │    │
│  │  Playnite-Steam.psm1     — Steam extension install     │    │
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

## Key Module Dependencies

```
Playnite-Common.ps1 (loader)
  ├── Playnite-Path.psm1          (InstallDir, 7Zip, Process, Start-PlayniteProcess)
  ├── Playnite-Database.psm1     (LiteDB, BSON, GameRecords)
  ├── Playnite-Steam.psm1        (SQLite tools, Extension install)
  ├── Playnite-Everything.psm1   (es.exe, Allowlist scanning)
  ├── Playnite-Allowlist.psm1     (NameId, AllowlistTypes)
  ├── Playnite-Export.psm1       (Steam detection, Get-ExportablePlayniteGames)
  └── Playnite-Import.psm1       (RepoRoot, GamesAppsManifest)
```

---

## Playnite → Sunshine Export Pipeline

```
Update-PlayniteLibraries / Import-PlayniteDesktopApps
  → games.db updated
Export-SunshineFromPlaynite.ps1
  → SunshineExport-Core.ps1
  → sunshine/apps.json
```
