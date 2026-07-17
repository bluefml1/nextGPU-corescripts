# PlayNiteWatcher Documentation

PlayNiteWatcher bridges **Playnite**, **Sunshine**, and **Moonlight**: library export, desktop app import, bypass shortcuts (RunAsTool), and session cleanup when games exit.

**Run scripts from** [`PlayNiteWatcher/`](../../PlayNiteWatcher/) unless a guide says otherwise.

---

## Guides

| Document | Description |
|----------|-------------|
| [overview.md](overview.md) | Layer architecture, data flow, module map |
| [end-to-end.md](end-to-end.md) | Portable Playnite setup, Steam/Epic scan, desktop allowlist, Sunshine export |
| [user-guide.md](user-guide.md) | PlayNite Watcher installer, session termination, legacy manual export flow |

---

## Reference

| Document | Description |
|----------|-------------|
| [modules.md](modules.md) | PowerShell `.psm1` function reference |
| [everything.md](everything.md) | voidtools Everything / `es.exe` for desktop import |
| [runastool.md](runastool.md) | RunAsTool v1.5 install and bypass automation |
| [bypass-templates.md](bypass-templates.md) | Seed `Game Shortcuts/`, `RunAsTool.rnt`, sync-list scope |
| [steam-extensions.md](steam-extensions.md) | `SteamLibrary_NextGPU` + `NextGPUBypassGuard` |
| [sunshine-export.md](sunshine-export.md) | Sunshine App Export Playnite extension |

---

## Repo layout (`PlayNiteWatcher/`)

| Folder | Contents |
|--------|----------|
| `src/` | PowerShell modules (`.psm1`) — shared implementations |
| `src/bypass/` | Bypass modules: config, RunAsTool, shortcuts, sync, uninstall |
| `watcher/` | Core watcher script, end script, UI |
| `install/` | Playnite + PlayNiteWatcher installation scripts |
| `export/` | Sunshine export (Playnite → `apps.json`) |
| `bypass/` | Bypass shortcut sync, review UI, uninstall |
| `import/` | Desktop app import, allowlist merge, host status |
| `library/` | Playnite LiteDB database files + cover assets |
| `tools/` | SQLite, 7-Zip, Everything, RunAsTool binaries |
| `config/` | JSON config and templates |
| `templates/` | Shortcut and script templates |
| `SteamExtensions/` | NextGPU Steam extension builds |
| `SunshineAppExport/` | Sunshine export plugin for Playnite |

Central doc index: [../README.md](../README.md).
