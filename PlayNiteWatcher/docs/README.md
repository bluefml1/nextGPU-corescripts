# PlayNiteWatcher Documentation

For the full architecture overview, see [PlayNiteWatcher-Overview.md](PlayNiteWatcher-Overview.md).

## Folder Overview

| Folder | Contents |
|---|---|
| `src/` | PowerShell module files (`.psm1`) — all shared function implementations |
| `watcher/` | Core watcher script + end script + UI |
| `install/` | Playnite + PlayNiteWatcher installation scripts |
| `export/` | Sunshine export scripts (Playnite → Sunshine app list) |
| `import/` | Desktop app import: scan roots, allowlist merge, host status |
| `docs/` | Architecture documentation (this folder) |
| `library/` | Playnite LiteDB database files + cover assets |
| `tools/` | SQLite, 7-Zip, Everything.exe binaries |
| `config/` | JSON config files and templates |
| `templates/` | Shortcut templates, script templates |
| `SteamExtensions/` | NextGPU Steam extension builds |
| `SunshineAppExport/` | Sunshine export plugin for Playnite |
