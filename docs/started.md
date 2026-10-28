# Getting Started With `nextGPU-corescripts`

This repo is a Windows automation toolkit for turning a GPU machine into a remote gaming or rental host. The main setup script installs streaming software, virtual display/audio drivers, Cloudflare Tunnel exposure, backend registration, health reporting, repair loops, wallpaper policy, scheduled tasks, and local user/account changes.

Use this file as the fast orientation guide. Use [`README.md`](README.md) when you need the full phase-by-phase detail.

## Big Picture

The main product flow is:

1. Run `RegisterMachine_Beta.bat` once on a fresh Windows GPU machine as Administrator (or use **Register Machine** in the NextGPU app, which runs it with `/UiConfig`).
2. The script installs/repairs prerequisites:
   - Virtual Display Driver and Virtual Audio Driver (optional per machine; the choice is saved in `machine-profile.json`).
   - Sunshine streaming host (credentials verified before setup continues).
   - VC++ Runtime (x64) for Moonlight Web.
   - Moonlight Web browser client.
   - NSSM for Windows services.
   - ViGEmBus for controller input.
   - Cloudflare Tunnel for public HTTPS access.
3. It pairs Moonlight Web to Sunshine, creates a Cloudflare DNS hostname under `next-gpu.com`, collects hardware inventory, registers the machine with the AWS backend, and writes `domain.txt` plus `%ProgramData%\nextGPU\machine-identity.env` / `machine-status.flag`.
4. It installs Windows services:
   - `moonlight-web`
   - `cloudflared`
   - `gpu-sunshine` (manual-start fallback only; Sunshine normally starts in the user session via `nextGPU-SunshineLogon`)
5. It registers scheduled tasks, including:
   - `nextGPU-Heartbeat` (every 5 minutes)
   - `nextGPU-AutoRepair` (every 1 minute)
   - `EndSession`, `nextGPU-EndSessionRecoveryStartup`, `auto game launch`, `nextGPU-NvidiaLogon`
6. It applies the nextGPU wallpaper policy, optionally renames the chosen admin account to `NextGPU-Authority`, creates a standard `nextGPU` user (group `NextGPURestricted`), registers desktop-cleanup and Clean Session tasks, locks shutdown, reports `online`, builds the NextGPU app if the .NET 8 SDK is present, and asks for a reboot.

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
- Whether to rename the local admin to `NextGPU-Authority` and, if yes, its current username.
- Whether this machine needs VDD/VAD (or pass `/UseVdd` / `/NoVdd`).

After it finishes, reboot manually. Driver enumeration, display paths, scheduled tasks, and user/account changes are more reliable after a restart.

## Repo Layout

The root folder keeps launchers and shared runtime artifacts. The real implementation files live under named folders:

```text
nextGPU-corescripts/
├── RegisterMachine_Beta.bat      # main setup launcher
├── NextGPU.bat                   # NextGPU operator dashboard
├── Start-Sunshine.bat            # start Sunshine in the current session
├── uninstall-all.bat             # uninstall launcher
├── apps/NextGPU/                 # NextGPU app + NextGPUService (.NET 8)
├── config/                       # launch-companion defaults, session rules template
├── templates/session/            # Clean Session template notes
├── PlayNiteWatcher/              # PlayNite setup and Sunshine app export
├── logs/                         # generated repo logs
├── assets/                       # static files such as nextgputobu.jpeg
├── docs/                         # README, this guide, setup guides
└── scripts/
    ├── provisioning/             # one-time setup, Sunshine/VDD helpers, inventory
    ├── runtime/                  # heartbeat, repair, update, user storage, session rules
    ├── drivers/                  # VDD/VAD and ViGEmBus installers
    ├── desktop/                  # wallpaper, shutdown policy, desktop cleanup
    ├── tasks/                    # scheduled task registration
    └── maintenance/              # games/apps sync + layout, clients, disk, uninstall
```

## Script Map

### Root Launchers

- `RegisterMachine_Beta.bat`: delegates to `scripts/provisioning/RegisterMachine_Beta.bat`. Flags: `/UseVdd`, `/NoVdd`, `/UiConfig`.
- `NextGPU.bat`: opens the NextGPU dashboard (installs the .NET 8 SDK and builds `NextGPU.exe` if needed). See [`nextgpu-app/README.md`](nextgpu-app/README.md).
- `Start-Sunshine.bat`: runs `scripts/provisioning/Start-Sunshine-InSession.ps1`.
- `uninstall-all.bat`: delegates to `scripts/maintenance/uninstall-all.bat`.

All other workflows are run from their `scripts/` subfolders.

### Provisioning

- `scripts/provisioning/RegisterMachine_Beta.bat`: Main one-time provisioning script. This is the script to understand first.
- `scripts/provisioning/Ensure-WmiSupport.ps1`: Confirms WMI/CIM inventory works. It may install WMIC only when the OS image supports it, otherwise CIM is used.
- `scripts/provisioning/Get-DisplayDeviceId.ps1`: Computes the Sunshine `output_name` device ID for the virtual display.
- `scripts/provisioning/Get-MachineInventory.ps1`: Emits OS, CPU, RAM, GPU, and check-in fields for registration.
- `scripts/provisioning/Get-BenchmarkScores-Silent.ps1`: Attempts to scrape CPU/GPU benchmark scores and outputs `CPU_SCORE|GPU_SCORE`.
- `scripts/provisioning/Invoke-PostSunshineSetup.ps1`: After any Sunshine install: deploys repo `sunshine.conf` and support scripts, resolves VDD `output_name` (VDD hosts only), and exports PlayNite games to Sunshine.
- `scripts/provisioning/Update-NextGpuStreamingStack.ps1`: Shared Sunshine/Moonlight install, update, and pairing logic used by auto-repair and checking-update (via `scripts/runtime/Run-StreamingStackUpdate.bat`).
- `scripts/provisioning/MachineProfile.ps1`: Reads/writes `machine-profile.json` (VDD enabled/disabled).
- `scripts/provisioning/Start-Sunshine-InSession.ps1` / `Register-SunshineLogonTask.ps1`: Start Sunshine in the logged-on user session and register `nextGPU-SunshineLogon`.

### Drivers

- `scripts/drivers/silent-install-vdd-vad.ps1`: Downloads the official Virtual Driver Control app, removes existing VDD/VAD devices/packages, installs fresh Virtual Display Driver plus Virtual Audio Driver with NefCon, then verifies VDD readiness. Main setup asks before running it; if skipped or unsuccessful, setup warns but still installs Sunshine. VAD is non-blocking by default because some Windows images reject the upstream audio driver with Code 52.
- `scripts/drivers/InstallVDD-VAD.bat`: One-click wrapper for the virtual display/audio installer.
- `scripts/drivers/ViGEmBus.bat`: Downloads and silently installs ViGEmBus if it is not already installed.

### Runtime Tasks

- `scripts/runtime/heartbeat-only.bat`: Runs one heartbeat per call (task `nextGPU-Heartbeat`, at boot and every 5 minutes) and posts the status from `machine-status.flag` to the AWS `updateStatus` endpoint. Skips while `heartbeat-suspended.flag` or `startup-publish-pending.flag` exists in `%ProgramData%\nextGPU`.
- `scripts/runtime/auto-repair.bat`: Runs one health check per call (task `nextGPU-AutoRepair`, at boot and every 1 minute). Checks `cloudflared`, Sunshine, `moonlight-web`, local HTTP `127.0.0.1:8080`, and Sunshine credentials / Moonlight pairing. It can restore credentials, re-pair, or fully reinstall Sunshine/Moonlight.
- `scripts/runtime/checking-update.bat`: Run-once update checker (EndSession / vendor path). Writes to `logs/checking-update.log`.
- `scripts/runtime/Invoke-NextGpuMachineIdentity.ps1`: Reads/writes `%ProgramData%\nextGPU\machine-identity.env` and `machine-status.flag` (`online`, `updating`, `update_fail`, `error`).
- `scripts/runtime/Recover-NextGpuEndSessionAtStartup.ps1`: Task `nextGPU-EndSessionRecoveryStartup`; finishes an interrupted EndSession reset at boot and publishes `online`.
- `scripts/runtime/Invoke-VendorOfflineShutdown.ps1`: Calls the `onDemandGPUHost` shutdown API for vendor hosts (secrets in `ondemand-gpu-host.env`, see `ondemand-gpu-host.env.example`).
- `scripts/runtime/NextGPU-PlayElevated.*` / `Update-LaunchCompanions.ps1`: Ask `NextGPUService` to launch games elevated, and manage its launch companions.
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

- `scripts/maintenance/Update-Games.ps1`: Restarts Sunshine via API, reads apps from Moonlight Web, and sends stream URLs to the AWS `updateNewGame` endpoint.
- `scripts/maintenance/updateGames.bat`: Admin wrapper for `Update-Games.ps1`; can read `COMPUTER_NAME` and `PUBLIC_IP` from `domain.txt` (`/UseDomainTxt` skips prompts).
- `scripts/maintenance/sync-games-apps-official.bat` / `push-games-apps-to-r2.bat`: Download / upload official game and app archives on Cloudflare R2 via rclone (`Sync-GamesApps-Official.ps1`).
- `scripts/maintenance/arrange-games-apps.bat`: Arranges synced games/apps into Steam, Garena, LevelUp, and HoYoPlay layouts (`Arrange-GamesApps.ps1`, `Invoke-Arrange*Layout.ps1`).
- `scripts/maintenance/Install-SteamClient.ps1`, `Install-GarenaClient.ps1`, `Install-LevelUpClient.ps1`, `Install-HoYoPlayClient.ps1`: Launcher client installers.
- `scripts/maintenance/Install-GarenaPlatformService.ps1` / `Register-GarenaLaunchCompanion.ps1`: Garena platform service and the `gxxapphelper.exe` launch companion for `NextGPUService`.
- `scripts/maintenance/Create-Z-Partition.ps1`: Shrinks a volume and creates/extends the `Z:` partition.
- `scripts/maintenance/Run-ChkDsk-Repair.ps1`: Runs `chkdsk /f` on one or all fixed drives, then prompts for reboot.
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
- `scripts/desktop/Setup-Shutdown-Policy.bat` / `Set-ShutdownPolicy.ps1`: Only `NextGPU-Authority` may shut down or restart.
- `scripts/tasks/TaskScheduler.ps1`: Registers the core tasks by calling `Register-HeartbeatTask.ps1`, `Register-AutoRepairTask.ps1`, `Register-NvidiaLogonTask.ps1`, `Register-EndSessionTask.ps1`, `Register-NextGpuEndSessionRecoveryTask.ps1`, `launchGameTaskScheduler.ps1`, and (if present) `PlayNiteWatcher\Register-PlayniteLogonTask.ps1`. Removes the deprecated `nextGPU-AutoUpdate` task.
- `scripts/tasks/launchGameTaskScheduler.ps1`: Registers `auto game launch` at user logon and runs `C:\Program Files\Sunshine\scripts\launchGame.ps1` (falls back to repo `sunshine\launchGame.ps1` or `Z:\launchGame.ps1`).
- `scripts/tasks/Test-TaskSchedulerSetup.ps1`: Verifies the task registration wiring.

### Notes

- [`README.md`](README.md): Detailed reference for setup phases, services, scheduled tasks, status flags, logs, dependencies, and troubleshooting. (`register-machine.md` is a copy of it.)
- [`setup-beginer.md`](setup-beginer.md), [`machine-setup-beginer.md`](machine-setup-beginer.md), [`machine-setup-guide.md`](machine-setup-guide.md): Step-by-step host setup guides.

## Files Created At Runtime

These are important because maintenance scripts depend on them:

- `domain.txt`: Created by `RegisterMachine_Beta.bat`. It stores identity only (`DOMAIN`, `PUBLIC_IP`, `COMPUTER_NAME`, `VENDOR_ID`, `VENDOR_ID_ENABLED`). Machine STATUS lives in `%ProgramData%\nextGPU\machine-status.flag`; durable identity also in `%ProgramData%\nextGPU\machine-identity.env`.
- `machine-profile.json`: Per-machine settings, currently whether VDD/VAD is enabled.
- `%ProgramData%\nextGPU\vendor-id.txt`: Present only on vendor hosts.
- `logs/register_api_log.txt`: Registration payload and backend response.
- `logs/setup_log_YYYYMMDD.txt`: Setup start timestamp.
- `logs/wmi-probe.log`: WMI/WMIC probe output.
- `logs/VDD-VAD.log`: Virtual display/audio installer log.
- `logs/ViGEmBus.log`: ViGEmBus installer log.
- `logs/sunshine-bind.log` and `logs/sunshine-vdd-setup.log`: Sunshine VDD display binding.
- `logs/moonlight-web.log` and `logs/moonlight-web-error.log`: Moonlight Web service output.
- `logs/heartbeat.log` and `logs/heartbeat-error.log`: `nextGPU-Heartbeat` task output.
- `logs/auto-repair.log` and `logs/auto-repair-error.log`: `nextGPU-AutoRepair` task output.
- `logs/checking-update.log`: Run-once update checker log.
- `logs/uninstall-nextgpu.log`: Uninstaller log.
- Downloaded folders/binaries still stay at the repo root, such as `sunshine\`, `moonlight-web\`, `nssm\`, `VDD-VAD-Install\`, and `cloudflared.exe`.

## Common Workflows

### Set Up A Fresh Machine

1. Copy or clone this repo onto the Windows target machine.
2. Open an elevated command prompt or right-click `RegisterMachine_Beta.bat` and run as Administrator.
3. Choose VDD/VAD, then enter Cloudflare, API, machine name, price, vendor, and admin-rename inputs.
4. Wait for the install, pairing, Cloudflare tunnel creation, backend registration, and service/task registration.
5. Reboot, then log on once (RDP or console) so Sunshine starts in the user session.
6. Confirm the services are running: `sc query cloudflared`, `sc query moonlight-web`.
7. Confirm the scheduled tasks exist and have run: `schtasks /Query /TN nextGPU-Heartbeat` and `schtasks /Query /TN nextGPU-AutoRepair`.
8. Open the generated domain from `domain.txt` and confirm Moonlight Web loads.

### Refresh The Game List

Use this after Sunshine/Moonlight apps change:

```bat
scripts\maintenance\updateGames.bat
```

It reads `domain.txt` when available, asks you to confirm the detected values, then calls `Update-Games.ps1`.

### Repair Streaming Stack Manually

Run one repair cycle manually (as Administrator), or trigger the task with `schtasks /Run /TN nextGPU-AutoRepair`:

```bat
scripts\runtime\auto-repair.bat
```

It waits for network access, checks Cloudflare/Sunshine/Moonlight/local HTTP and credentials/pairing, and restores credentials, re-pairs, or performs a full Sunshine/Moonlight reinstall plus pairing as needed. Cloudflared failures only restart the tunnel service; they never trigger a streaming-stack reinstall.

If `%ProgramData%\nextGPU\machine-status.flag` is `updating`, `scripts/runtime/auto-repair.bat` skips repairs to avoid fighting an update. Otherwise, when a check fails:

- Flag `online`: the flag is set to `error` and `error` is sent to `updateStatus` immediately, then the repair runs. After a successful repair, `online` is sent and the flag is set to `online`.
- Flag `error`: `error` is not re-sent. Once the machine is healthy again (repaired or recovered), `online` is sent.
- Flag `update_fail`: repair only (no status change). After a successful repair, vendor hosts (`VENDOR_ID_ENABLED=yes`) call only the `onDemandGPUHost` shutdown API and keep `update_fail`; other hosts send `online`.

If `checking-update` sets `updating` while a repair is running, auto-repair stops without overwriting the status. If cloudflared cannot be restarted, the status stays `error`.

### Run A One-Time Update Check

Use:

```bat
scripts\runtime\checking-update.bat
```

This logs to `logs/checking-update.log`, sets `machine-status.flag` to `updating`, checks remote Sunshine/Moonlight versions, applies updates when local version files exist and differ, re-pairs if needed, then sets status back to `online` or `update_fail` (Vendor hosts leave status as `updating` and request shutdown).

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

Optional flags: `skipdrivers`, `skipfiles`, `keepusers` (retain local users `nextGPU` and `NextGPU-Admin`). Combine with `force`, for example `uninstall-all.bat force skipdrivers`.

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
- Sunshine/Moonlight update behavior: `scripts/runtime/checking-update.bat`.
- Machine registration payload fields: `scripts/provisioning/RegisterMachine_Beta.bat`, `scripts/provisioning/Get-MachineInventory.ps1`, and `scripts/provisioning/Get-BenchmarkScores-Silent.ps1`.
- Game list payloads: `scripts/maintenance/Update-Games.ps1` and `scripts/maintenance/updateGames.bat`.
- Wallpaper policy behavior: `scripts/desktop/Setup-Wallpaper.bat` and `scripts/desktop/Set-DesktopWallpaper-Gpo.ps1`.
- Virtual display ID issues: `scripts/provisioning/Get-DisplayDeviceId.ps1`.

## Known Gaps From This Scan

- `scripts/tasks/launchGameTaskScheduler.ps1` and `scripts/maintenance/garena.bat` depend on `Z:` paths that are not created by this repo.
- Several scripts share Sunshine/Moonlight update logic via `Update-NextGpuStreamingStack.ps1` (`auto-repair.bat`, `checking-update.bat`).

## Quick Troubleshooting

- Setup fails early: check `logs/wmi-probe.log`; run `scripts/provisioning/Ensure-WmiSupport.ps1` manually.
- Sunshine has no virtual display: inspect `logs\VDD-VAD.log`, reboot, then run `scripts\provisioning\Get-DisplayDeviceId.ps1 -ListAll -IncludeInactive`.
- Public URL does not load: check `sc query cloudflared`, Cloudflare tunnel/DNS, and local `http://127.0.0.1:8080`.
- Heartbeat does not update backend: check `domain.txt`, the `nextGPU-Heartbeat` task, `logs/heartbeat.log`, that no `heartbeat-suspended.flag` is left in `%ProgramData%\nextGPU`, and network access to AWS.
- Auto-repair keeps reinstalling: check `logs/auto-repair.log`, Moonlight local HTTP status, and whether `machine-status.flag` is stuck at `updating`.
- Game list is stale: run `scripts/maintenance/updateGames.bat` after confirming Moonlight Web returns apps at `http://localhost:8080/api/apps?host_id=0&force_refresh=false`.

