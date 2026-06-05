# NextGPU Controller

Windows desktop app to monitor and operate a **nextGPU-corescripts** GPU rental host: service health, log tailing, Sunshine/Moonlight restarts, and one-click maintenance scripts.

## Ready to use (operators)

1. On the GPU Windows PC, open the **nextGPU-corescripts** folder.
2. **Double-click `NextGPU.bat`** (at repo root, one folder above `apps\`).
3. First launch may take 1–2 minutes while it builds (only if .NET 8 SDK is installed).
4. Sign in:

| Field | Value |
|-------|--------|
| Username | `bluefml1` |
| Password | `letmeinpls` |

After the first successful build, **`NextGPU.exe`** at the repo root runs with **no .NET install** required.

## One-time build (admin / dev)

From repo root:

```bat
apps\NextGPU\build-publish.bat
```

Creates:

- `NextGPU.exe` at repo root (launcher target)
- `apps\NextGPU\publish\NextGPU.exe` (self-contained, ~80–100 MB)

Optional desktop shortcut:

```bat
apps\NextGPU\setup-controller.bat
```

## Fleet deploy (no SDK on GPU machines)

On a build PC with .NET 8 SDK:

```bat
git clone <repo>
cd nextGPU-corescripts
apps\NextGPU\build-publish.bat
```

Copy to each GPU host:

- Entire repo **or** at minimum `NextGPU.exe`, `NextGPU.bat`, `scripts\`, `logs\`, and runtime folders (`domain.txt` created by setup).

## Requirements

- Windows 10/11 x64
- **To run:** nothing extra after `build-publish.bat` (self-contained exe)
- **To build:** [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- nextGPU-corescripts on the same machine (or `NEXTGPU_REPO_ROOT`)

## Repo detection

1. `NEXTGPU_REPO_ROOT` environment variable
2. Walk parent folders from the app until both exist:
   - `RegisterMachine_Beta.bat`
   - `scripts/provisioning/RegisterMachine_Beta.bat`

Override in app **Settings** if needed.

## Features

- **Dashboard** — `domain.txt`, HTTP probes (Moonlight :8080, Sunshine :47990), VDD/VAD status, service start/stop/restart
- **Sunshine** — service restart + **interactive** restart (fixes broken web UI with raw `{{ $t(...) }}` text)
- **Logs** — tail `logs\`, filter, **open logs folder** in Explorer, **jump to** latest `setup_log_*.txt` / `sunshine-bind.log`, open in editor
- **User Storage (U:)** — dedicated page: setup, diagnose (ACL/WinFsp/API), mount for Admin RDP + Moonlight
- **Get Started** — step **05** links to User Storage page
- **Actions** — broad script catalog: install monitoring shortcuts, provisioning (Sunshine logon, desktop cleanup, per-user S3 storage, API restart, display IDs), maintenance (`copy`/`extract`/garena, layout test, auto-repair loop), inventory (WMI, machine inventory), drivers/wallpaper/shutdown lock, full setup with **console stays open** (`/k` / `-NoExit`) for readable install output
- **Settings** — repo path, refresh interval 15/30/60 s

Audit log: `logs/nextgpu-controller.log`

## Developer run (without publish)

```bat
cd apps\NextGPU
dotnet run --project NextGPU.App -c Release
```

## Security

Hardcoded login is operator convenience only — not secure against other local users. Destructive actions use UAC + confirmations.
