# Getting Started With `nextGPU-corescripts`

This repo is a Windows automation toolkit for turning a GPU machine into a remote gaming or rental host. The main setup script installs streaming software, virtual display/audio drivers, Cloudflare Tunnel exposure, backend registration, health reporting, repair loops, wallpaper policy, scheduled tasks, and local user/account changes.

Use this file as the fast orientation guide. Use `README.md` when you need the full phase-by-phase detail.

## Big Picture

The main product flow is:

1. Run `RegisterMachine_Beta.bat` once on a fresh Windows GPU machine as Administrator.
2. The script installs/repairs prerequisites:
   - Virtual Display Driver and Virtual Audio Driver.
   - Sunshine streaming host.
   - Moonlight Web browser client.
   - NSSM for Windows services.
   - ViGEmBus for controller input.
   - Cloudflare Tunnel for public HTTPS access.
3. It pairs Moonlight Web to Sunshine, creates a Cloudflare DNS hostname under `next-gpu.com`, collects hardware inventory, registers the machine with the AWS backend, and writes `domain.txt`.
4. It installs background services:
   - `moonlight-web`
   - `cloudflared`
   - `gpu-heartbeat`
   - `auto-repair`
5. It applies the nextGPU wallpaper policy, renames the chosen admin account to `NextGPU-Authority`, creates a standard `nextGPU` user, and asks for a reboot.

Most other scripts are helpers for that flow or maintenance tools after setup.

## Primary Entry Point

Run this on the target Windows machine:

```bat
RegisterMachine_Beta.bat
```

Right-click and choose **Run as administrator**. The script also tries to auto-elevate if started without admin rights.

Before running it, have these values ready:

- Cloudflare API token with permission to manage tunnels and DNS for `next-gpu.com`.
- Cloudflare account ID.
- API key for the AWS `registerMachine` endpoint.
- Machine display name, for example `GPU-RENTAL-01`.
- Original rental/listing price.
- Optional vendor ID.
- Existing local admin username that should become `NextGPU-Authority`.

After it finishes, reboot manually. Driver enumeration, display paths, scheduled tasks, and user/account changes are more reliable after a restart.

## Repo Layout

The root folder now keeps compatibility launchers and shared runtime artifacts. The real implementation files live under named folders:

```text
nextGPU-corescripts/
├── RegisterMachine_Beta.bat      # main setup launcher
├── uninstall-all.bat              # uninstall launcher
├── logs/                         # generated repo logs
├── assets/                       # static files such as nextgputobu.jpeg
├── docs/                         # README, this guide, manual checklist
├── scripts/
│   ├── provisioning/             # one-time setup and inventory helpers
│   ├── runtime/                  # heartbeat, repair, update loops
│   ├── drivers/                  # VDD/VAD and ViGEmBus installers
│   ├── desktop/                  # wallpaper policy setup
│   ├── tasks/                    # scheduled task registration
│   └── maintenance/              # games, copy/extract, uninstall helpers
└── tools/                        # reserved for future local tools
```

## Script Map

### Root Launchers

Only the primary setup and uninstall launchers are kept at the repo root:

- `RegisterMachine_Beta.bat`: delegates to `scripts/provisioning/RegisterMachine_Beta.bat`.
- `uninstall-all.bat`: delegates to `scripts/maintenance/uninstall-all.bat`.

All other workflows are run from their `scripts/` subfolders.

### Provisioning

- `scripts/provisioning/RegisterMachine_Beta.bat`: Main one-time provisioning script. This is the script to understand first.
- `scripts/provisioning/Ensure-WmiSupport.ps1`: Confirms WMI/CIM inventory works. It may install WMIC only when the OS image supports it, otherwise CIM is used.
- `scripts/provisioning/Get-DisplayDeviceId.ps1`: Computes the Sunshine `output_name` device ID for the virtual display.
- `scripts/provisioning/Get-MachineInventory.ps1`: Emits OS, CPU, RAM, GPU, and check-in fields for registration.
- `scripts/provisioning/Get-BenchmarkScores-Silent.ps1`: Attempts to scrape CPU/GPU benchmark scores and outputs `CPU_SCORE|GPU_SCORE`.

### Drivers

- `scripts/drivers/silent-install-vdd-vad.ps1`: Downloads the official Virtual Driver Control app, removes existing VDD/VAD devices/packages, installs fresh Virtual Display Driver plus Virtual Audio Driver with NefCon, then verifies VDD readiness. Main setup asks before running it; if skipped or unsuccessful, setup warns but still installs Sunshine. VAD is non-blocking by default because some Windows images reject the upstream audio driver with Code 52.
- `scripts/drivers/InstallVDD-VAD.bat`: One-click wrapper for the virtual display/audio installer.
- `scripts/drivers/ViGEmBus.bat`: Downloads and silently installs ViGEmBus if it is not already installed.

### Runtime Services

- `scripts/runtime/heartbeat-only.bat`: Loops every 300 seconds and posts the current machine status to the AWS `updateStatus` endpoint.
- `scripts/runtime/auto-repair.bat`: Loops every 60 seconds, checks `cloudflared`, Sunshine, `moonlight-web`, and local HTTP `127.0.0.1:8080`. It can reinstall Sunshine/Moonlight and re-pair them.
- `scripts/runtime/auto-update.bat`: Long-running update loop for Sunshine/Moonlight versions. It is not installed by the main setup script in the current repo.
- `scripts/runtime/checking-update.bat`: Run-once/logging update checker. It currently skips the backend availability gate and writes to `logs/checking-update.log`.
- **Per-user S3 storage (opt-in):** `scripts/runtime/Setup-UserStorage.bat` installs rclone `[nextgpu-user]` under `%ProgramData%\nextGPU\rclone\`, registers `nextGPU-UserStorageMount` / `nextGPU-UserStorageUnmount` for the **nextGPU** user, and mounts `user_<id>/` from bucket `next-gpu-storage` as **`U:`** at logon (Explorer label `{name}'s Storage` from checkDomain `displayName` / `name` / `firstName` / `lastName`). Not wired into `RegisterMachine_Beta.bat` by default.
- **Clean Session folder rules:** `scripts/runtime/Invoke-SessionFolderRules.ps1` runs **delete** or **replace** rules on nextGPU logoff (primary) with logon fallback. Config: `%ProgramData%\nextGPU\session-folder-rules.json`; golden replace sources: `%ProgramData%\nextGPU\session-templates\{id}\`. Tasks: `nextGPU-SessionFolderRulesLogoff` / `nextGPU-SessionFolderRulesLogon` via `Register-SessionFolderRulesTasks.ps1` (also called from `RegisterMachine_Beta.bat` after the nextGPU user is created). `sunshine/endSession.ps1` runs logoff rules at STEP 0. NextGPU HOST page **Setup Games & Apps** → **Clean Session** tab for CRUD, import/export, seed templates. Host layout (`arrange-games-apps.bat`) is separate on the **Host Setup** tab.

### Per-user S3 storage (optional)

Run **once** as Administrator after provisioning (and after `domain.txt` exists). Repo can stay in place (e.g. under Administrator profile): setup copies mount scripts to `%ProgramData%\nextGPU\scripts\runtime\` for scheduled tasks and grants **nextGPU** read on `domain.txt` + `scripts\runtime` under the repo root. If you **delete and recreate** the local `nextGPU` user (same name), you do **not** re-run setup: **`nextGPU-UserStorageEnsureBindings`** runs as SYSTEM at logon (+0s) and re-registers tasks/ACLs for the new SID; **`nextGPU-UserStorageMount`** runs at logon (+22s). If mount starts before ensure finishes, `Mount-UserStorage.ps1` waits on the ensure task (up to ~60s, progress in `user-storage-mount.log`). Manual fix: `Sync-NextGpuUserStorageForLocalUser.bat` as Administrator. `RegisterMachine_Beta.bat` runs **Sync** when it creates `nextGPU`.

```bat
scripts\runtime\User-Storage.bat Setup
```

Setup installs rclone/WinFsp, AWS config, publishes scripts, registers **ensure (logon +0s)** + **mount (logon +22s)** tasks, and grants **nextGPU** access. After **recreate nextGPU**, run **`User-Storage.bat Sync`** only (not Setup). One script for everything: `User-Storage.bat` (Test, Mount, Sync, Troubleshoot, Logs).

**Credentials (never commit to git):** set machine env vars `NEXTGPU_USER_S3_ACCESS_KEY` and `NEXTGPU_USER_S3_SECRET_KEY`, or copy `scripts/runtime/user-s3.env.example` to `%ProgramData%\nextGPU\secrets\user-s3.env` and fill in values. Rotate keys if they were exposed.

**Verify:** log in as **nextGPU** → `U:` appears with label like `Viet's Storage` (from checkDomain name fields) → disconnect Moonlight unmounts `U:` → next connect remounts. Logs: `%ProgramData%\nextGPU\logs\user-storage-mount.log` (includes label before/after mount).

**Admin RDP + Moonlight (single session, no second RDP as nextGPU):** mount always runs via Task Scheduler task `nextGPU-UserStorageMount` as **nextGPU** (`Mount-UserStorage.ps1 -FromScheduledTask`). Logon (~20s delay), session unlock, Sunshine (`Start-UserStorage-InSession.ps1` → `schtasks /Run`), and Admin (`Invoke-UserStorageMountFromAdmin.ps1` or `Mount-UserStorage-Now.bat`) all trigger the same task. From Admin after Moonlight connect: `scripts\runtime\Mount-UserStorage-Now.bat`. Logs: `%ProgramData%\nextGPU\logs\` and mirrored under repo `logs\`.

**Cost note:** mount uses 30s poll/dir-cache refresh; avoid antivirus or search indexing on `U:\`.

### Games, Desktop, And Maintenance

- `scripts/maintenance/Update-Games.ps1`: Reads apps from Moonlight Web and sends stream URLs to the AWS `updateNewGame` endpoint.
- `scripts/maintenance/updateGames.bat`: Admin wrapper for `Update-Games.ps1`; can read `COMPUTER_NAME` and `PUBLIC_IP` from `domain.txt`.
- `scripts/maintenance/copy.bat`: Connects to an SMB share, copies files into the repo root, then runs `scripts/maintenance/extract.bat`.
- `scripts/maintenance/extract.bat`: Recursively extracts `.zip` and `.rar` files from the repo root using `C:\Program Files\7-Zip\7z.exe`, then deletes the archives.
- `scripts/maintenance/garena.bat`: Starts Garena from `Z:\Garena\...`.
- `scripts/maintenance/Uninstall-NextGPU.ps1`: Full local uninstaller for services, Sunshine/Moonlight/cloudflared, drivers, scheduled tasks (`nextGPU-*`), wallpaper/shutdown policy, environment variables, optional `nextGPU` user removal, and generated logs.
- `scripts/maintenance/uninstall-all.bat`: Admin wrapper for `Uninstall-NextGPU.ps1`.
- `scripts/desktop/Setup-Wallpaper.bat`: Wrapper for wallpaper setup.
- `scripts/desktop/Set-DesktopWallpaper-Gpo.ps1`: Copies the wallpaper from `assets/` to `C:\Users\Public\Wallpaper`, writes User Configuration `registry.pol` with **Fit** (full image), applies desktop and lock/sign-in wallpaper keys, registers **`nextGPU-WallpaperFitLogon`**, refreshes Explorer, and runs `gpupdate`.
- `scripts/desktop/WallpaperFitCommon.ps1`: Ensures `nextgputobu-4k.bmp` (3840×2160) or uses exact 4K JPEG; Fit registry + PersonalizationCSP + hide icons.
- `scripts/desktop/Apply-WallpaperFit-Logon.ps1` / `Register-WallpaperFitLogonTask.ps1`: Per-logon Fit wallpaper, hide icons, clear nextGPU Desktop files.
- `scripts/desktop/Clear-NextGpuUserDesktop.ps1`: Deletes everything under the **nextGPU** user’s Desktop folder (used by the `nextGPU-DesktopCleanupLogon` task at each nextGPU logon).
- `scripts/desktop/Register-NextGpuDesktopCleanupTask.ps1`: Registers that logon task (run elevated; `RegisterMachine_Beta.bat` calls it after `net user nextGPU /add`).
- `scripts/tasks/TaskScheduler.ps1`: Registers the `EndSession` task.
- `scripts/tasks/launchGameTaskScheduler.ps1`: Registers `auto game launch` at user logon and runs `Z:\launchGame.ps1`.

### Notes

- `docs/Main script to do.txt`: Small manual checklist for image preparation steps, including game/app deletion, disk shrinking, copy operations, user creation, and reboot.
- `docs/README.md`: Existing detailed reference for setup phases, services, logs, dependencies, and troubleshooting.

## Files Created At Runtime

These are important because maintenance scripts depend on them:

- `domain.txt`: Created by `RegisterMachine_Beta.bat`. It stores `DOMAIN`, `PUBLIC_IP`, and `COMPUTER_NAME`; update/heartbeat/repair scripts read it. Some scripts also add `STATUS`.
- `logs/register_api_log.txt`: Registration payload and backend response.
- `logs/setup_log_YYYYMMDD.txt`: Setup start timestamp.
- `logs/wmi-probe.log`: WMI/WMIC probe output.
- `logs/VDD-VAD.log`: Virtual display/audio installer log.
- `logs/ViGEmBus.log`: ViGEmBus installer log.
- `logs/heartbeat.log` and `logs/heartbeat-error.log`: NSSM service logs.
- `logs/auto-repair.log` and `logs/auto-repair-error.log`: NSSM service logs.
- `logs/checking-update.log`: Run-once update checker log.
- `logs/uninstall-nextgpu.log`: Uninstaller log.
- Downloaded folders/binaries still stay at the repo root, such as `sunshine\`, `moonlight-web\`, `nssm\`, `VDD-VAD-Install\`, and `cloudflared.exe`.

## Common Workflows

### Set Up A Fresh Machine

1. Copy or clone this repo onto the Windows target machine.
2. Open an elevated command prompt or right-click `RegisterMachine_Beta.bat` and run as Administrator.
3. Enter Cloudflare, API, pricing, machine, vendor, and admin-account inputs.
4. Wait for the install, pairing, Cloudflare tunnel creation, backend registration, and service installation.
5. Reboot.
6. Confirm these services are running:
   - `cloudflared`
   - `moonlight-web`
   - `gpu-heartbeat`
   - `auto-repair`
7. Open the generated domain from `domain.txt` and confirm Moonlight Web loads.

### Refresh The Game List

Use this after Sunshine/Moonlight apps change:

```bat
scripts\maintenance\updateGames.bat
```

It reads `domain.txt` when available, asks you to confirm the detected values, then calls `Update-Games.ps1`.

### Repair Streaming Stack Manually

If the service is not already installed, run:

```bat
scripts\runtime\auto-repair.bat
```

It waits for network access, checks Cloudflare/Sunshine/Moonlight/local HTTP, and performs a full Sunshine/Moonlight reinstall plus pairing if needed.

If `domain.txt` contains `STATUS=updating`, `scripts/runtime/auto-repair.bat` skips repairs to avoid fighting an update.

### Run A One-Time Update Check

Use:

```bat
scripts\runtime\checking-update.bat
```

This logs to `logs/checking-update.log`, sets status to `updating`, checks remote Sunshine/Moonlight versions, applies updates when local version files exist and differ, re-pairs if needed, then sets status back to `online` or `update_fail`.

### Apply Wallpaper Only

Use:

```bat
scripts\desktop\Setup-Wallpaper.bat
```

Expected wallpaper source file: `assets/nextgputobu.jpeg`. If that file is missing, wallpaper setup fails.

### Uninstall Local nextGPU Components

Preview the cleanup first:

```bat
uninstall-all.bat whatif
```

Run the full local uninstall:

```bat
uninstall-all.bat
```

To skip the confirmation prompt:

```bat
uninstall-all.bat force
```

Optional flags: `skipdrivers`, `skipfiles`, `keepusers` (retain local user `nextGPU`). Combine with `force`, for example `uninstall-all.bat force skipdrivers`.

The uninstaller removes local Windows services, Sunshine (Program Files + AppData), Moonlight Web, NSSM, `cloudflared.exe`, VDD/VAD (`DISPLAY\MTT1337*`), ViGEmBus, scheduled tasks including `nextGPU-*`, wallpaper and shutdown policy (Default user hive included), `CLOUDFLARE_TUNNEL_TOKEN`, the `nextGPU` user (unless `keepusers`), and generated files/logs such as `domain.txt` and `logs/*`.

It does not delete Cloudflare DNS/tunnel resources from the Cloudflare account and does not remove `NextGPU-Authority`. Reboot after uninstall, especially after driver removal.

## Important Assumptions

- Target OS is Windows with PowerShell 5.1+.
- Most scripts require Administrator rights.
- Outbound HTTPS must work for GitHub, Cloudflare, AWS API Gateway, benchmark sites, and public IP lookup.
- `curl.exe` is expected; many scripts have PowerShell download fallbacks.
- 7-Zip is expected at `C:\Program Files\7-Zip\7z.exe` for `scripts/maintenance/extract.bat`.
- Some game/session scripts assume a `Z:` drive exists:
  - `Z:\launchGame.ps1`
  - `Z:\Garena\Garena\Garena.exe`
- Private IP detection is hardcoded around `192.168.1.*`; machines on other LAN ranges may report `127.0.0.1`.
- Cloudflare DNS is hardcoded to `next-gpu.com`.
- Sunshine credentials are set by script to `bluefml1` / `letmeinpls`.
- Moonlight pairing uses the test login in the downloaded Moonlight data/config templates.

## Security And Safety Notes

- Do not commit real Cloudflare tokens, API keys, tunnel tokens, or production credentials.
- `scripts/maintenance/copy.bat` currently contains plaintext SMB credentials (`name123` / `password123`). Treat them as placeholders or rotate/remove them before sharing the repo.
- `RegisterMachine_Beta.bat` writes the Cloudflare tunnel token into the machine environment variable `CLOUDFLARE_TUNNEL_TOKEN`.
- `logs/register_api_log.txt` can contain registration payload details. Review before sharing logs.
- `scripts/maintenance/extract.bat` deletes archives after successful extraction.
- `RegisterMachine_Beta.bat` removes/reinstalls Sunshine, removes/recreates the Moonlight service, creates Cloudflare tunnel/DNS resources, renames a local admin account, and creates a local `nextGPU` user. Run it only on a machine intended for provisioning.

## What To Read First When Editing

Start with the script that owns the workflow you want to change:

- Full setup or service install changes: `scripts/provisioning/RegisterMachine_Beta.bat`.
- Health check or self-healing behavior: `scripts/runtime/auto-repair.bat`.
- Periodic status payload: `scripts/runtime/heartbeat-only.bat`.
- Sunshine/Moonlight update behavior: `scripts/runtime/checking-update.bat` and `scripts/runtime/auto-update.bat`.
- Machine registration payload fields: `scripts/provisioning/RegisterMachine_Beta.bat`, `scripts/provisioning/Get-MachineInventory.ps1`, and `scripts/provisioning/Get-BenchmarkScores-Silent.ps1`.
- Game list payloads: `scripts/maintenance/Update-Games.ps1` and `scripts/maintenance/updateGames.bat`.
- Wallpaper policy behavior: `scripts/desktop/Setup-Wallpaper.bat` and `scripts/desktop/Set-DesktopWallpaper-Gpo.ps1`.
- Virtual display ID issues: `scripts/provisioning/Get-DisplayDeviceId.ps1`.

## Known Gaps From This Scan

- `scripts/runtime/auto-update.bat` exists as a long-running updater, but `RegisterMachine_Beta.bat` currently installs `auto-repair` and not an `auto-update` service.
- `scripts/tasks/launchGameTaskScheduler.ps1` and `scripts/maintenance/garena.bat` depend on `Z:` paths that are not created by this repo.
- Several scripts duplicate Sunshine/Moonlight pairing logic. When changing pairing behavior, check `scripts/provisioning/RegisterMachine_Beta.bat`, `scripts/runtime/auto-repair.bat`, `scripts/runtime/auto-update.bat`, and `scripts/runtime/checking-update.bat`.

## Quick Troubleshooting

- Setup fails early: check `logs/wmi-probe.log`; run `scripts/provisioning/Ensure-WmiSupport.ps1` manually.
- Sunshine has no virtual display: inspect `logs\VDD-VAD.log`, reboot, then run `scripts\provisioning\Get-DisplayDeviceId.ps1 -ListAll -IncludeInactive`.
- Public URL does not load: check `sc query cloudflared`, Cloudflare tunnel/DNS, and local `http://127.0.0.1:8080`.
- Heartbeat does not update backend: check `domain.txt`, `gpu-heartbeat`, `logs/heartbeat.log`, and network access to AWS.
- Auto-repair keeps reinstalling: check `logs/auto-repair.log`, Moonlight local HTTP status, and whether `STATUS=updating` is being set/cleared correctly.
- Game list is stale: run `scripts/maintenance/updateGames.bat` after confirming Moonlight Web returns apps at `http://localhost:8080/api/apps?host_id=0&force_refresh=false`.

