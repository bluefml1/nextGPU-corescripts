# nextGPU Core Scripts

Windows automation for provisioning a remote GPU gaming/rental workstation with Sunshine, Moonlight Web, Cloudflare Tunnel, AWS registration, health reporting, auto-repair, virtual display/audio, controller support, wallpaper policy, and scheduled tasks.

The root folder exposes the main launchers:

- `RegisterMachine_Beta.bat` — full machine setup
- `NextGPU.bat` — operator dashboard (health, logs, maintenance)
- `uninstall-all.bat`

Detailed docs live in `docs/README.md` and `docs/started.md`.

## Repo Layout

```text
nextGPU-corescripts/
├── RegisterMachine_Beta.bat      # main install launcher
├── NextGPU.bat                   # operator dashboard (double-click)
├── NextGPU.exe                   # built by apps\NextGPU\build-publish.bat
├── uninstall-all.bat             # uninstall launcher
├── logs/                         # generated logs
├── assets/                       # static assets, including wallpaper
├── docs/                         # detailed docs and checklist
└── scripts/
    ├── provisioning/             # setup, inventory, display helpers
    ├── runtime/                  # heartbeat, repair, update scripts
    ├── drivers/                  # VDD/VAD and ViGEmBus installers
    ├── desktop/                  # wallpaper policy scripts
    ├── tasks/                    # scheduled task registration
    └── maintenance/              # game update, copy/extract, uninstall internals
├── apps/
│   └── NextGPU/                  # controller source + build-publish.bat
```

Runtime state such as `domain.txt`, `sunshine/`, `moonlight-web/`, `nssm/`, `VDD-VAD-Install/`, and `cloudflared.exe` stays at the repo root for compatibility.

## Before You Start

Run on Windows as Administrator. Have these ready:

- Cloudflare API token for tunnel/DNS management under `next-gpu.com`.
- Cloudflare account ID.
- AWS API key for machine registration.
- Machine display name, for example `GPU-RENTAL-01`.
- Original listing price.
- Optional vendor ID.
- Existing local admin username to rename to `NextGPU-Authority`.

The target machine needs outbound HTTPS access to GitHub, Cloudflare, AWS API Gateway, benchmark sites, and public IP lookup services.

## Install

From the repo root, run:

```bat
RegisterMachine_Beta.bat
```

Recommended flow:

1. Right-click `RegisterMachine_Beta.bat` and choose **Run as administrator**.
2. Enter the requested Cloudflare, AWS API, machine, price, vendor, and admin-account values.
3. Choose whether to install/refresh VDD/VAD when prompted. If VDD is missing or fails, setup warns but still continues so Sunshine can install.
4. Wait for setup to install Sunshine, Moonlight Web, NSSM, ViGEmBus, Cloudflare Tunnel, scheduled tasks, heartbeat, auto-repair, wallpaper policy, and backend registration.
5. Reboot manually when setup finishes.
6. Confirm these services are running:
   - `cloudflared`
   - `moonlight-web`
   - `gpu-heartbeat`
   - `auto-repair`

After setup, `domain.txt` is created at the repo root and logs are written under `logs/`.

## NextGPU Controller (ready to use)

**Double-click `NextGPU.bat`** at the repo root on the GPU machine.

| Step | What happens |
|------|----------------|
| First run (SDK installed) | Builds a self-contained `NextGPU.exe` automatically, then opens the app |
| After build | Opens `NextGPU.exe` instantly (no .NET required on the machine) |
| Sign in | `bluefml1` / `letmeinpls` |

One-time build (or if auto-build failed):

```bat
apps\NextGPU\build-publish.bat
```

Desktop shortcut + build:

```bat
apps\NextGPU\setup-controller.bat
```

Full details: [apps/NextGPU/README.md](apps/NextGPU/README.md). Setup also tries to build the controller at the end of `RegisterMachine_Beta.bat` when the .NET 8 SDK is present.

## Common Operations

Refresh games after Moonlight/Sunshine apps change:

```bat
scripts\maintenance\updateGames.bat
```

Run a one-time update check:

```bat
scripts\runtime\checking-update.bat
```

Apply wallpaper only:

```bat
scripts\desktop\Setup-Wallpaper.bat
```

This applies both the desktop wallpaper (GPO **Fit** — full image on any resolution) and the Windows lock/sign-in screen background, and registers **`nextGPU-WallpaperFitLogon`** to keep Fit after each logon.

Lock shutdown/restart to **NextGPU-Authority** only (`nextGPU` and other users cannot shut down or restart):

```bat
scripts\desktop\Setup-Shutdown-Policy.bat
```

Run auto-repair manually:

```bat
scripts\runtime\auto-repair.bat
```

## Logs

Generated logs are centralized in `logs/`, including:

- `logs/wmi-probe.log`
- `logs/VDD-VAD.log`
- `logs/ViGEmBus.log`
- `logs/register_api_log.txt`
- `logs/setup_log_*.txt`
- `logs/heartbeat.log`
- `logs/heartbeat-error.log`
- `logs/auto-repair.log`
- `logs/auto-repair-error.log`
- `logs/checking-update.log`
- `logs/moonlight-web.log`
- `logs/moonlight-web-error.log`
- `logs/network_copy.log`
- `logs/uninstall-nextgpu.log`

## Troubleshooting

- Setup exits during WMI check: inspect `logs/wmi-probe.log`, then run `scripts\provisioning\Ensure-WmiSupport.ps1` manually if needed.
- Virtual display is missing: setup can still continue, but Sunshine will use default display behavior until VDD is fixed. Inspect `logs\VDD-VAD.log`, reboot, then run `scripts\provisioning\Get-DisplayDeviceId.ps1 -ListAll -IncludeInactive`.
- Virtual audio shows Code 52: VDD can still be used headless. VAD is non-blocking by default because some Windows 11 24H2 / Server 2025 images reject the upstream audio driver signature.
- Before unplugging every physical monitor: confirm VDD is OK, Sunshine is capturing the intended display (set `output_name` in `sunshine.conf` manually if you need a fixed VDD head), and RDP works.
- Public URL does not load: check `sc query cloudflared`, Cloudflare tunnel/DNS, and local `http://127.0.0.1:8080`.
- Heartbeat does not update backend: confirm `domain.txt` exists, `gpu-heartbeat` is running, and inspect `logs/heartbeat.log`.
- Auto-repair keeps reinstalling: inspect `logs/auto-repair.log`, check Moonlight local HTTP, and confirm `domain.txt` is not stuck at `STATUS=updating`.
- Registration failed: inspect `logs/register_api_log.txt`, API key, and payload size.
- Game list is stale: confirm Moonlight Web returns apps at `http://localhost:8080/api/apps?host_id=0&force_refresh=false`, then run `scripts\maintenance\updateGames.bat`.

## Uninstall

Preview the uninstall without making changes:

```bat
uninstall-all.bat whatif
```

Run the full local uninstall:

```bat
uninstall-all.bat
```

Skip confirmation:

```bat
uninstall-all.bat force
```

Optional flags can be combined:

```bat
uninstall-all.bat force skipdrivers
uninstall-all.bat force skipfiles
uninstall-all.bat force keepusers
```

The uninstaller removes local nextGPU services, Sunshine (including AppData config), Moonlight Web, NSSM, `cloudflared.exe`, VDD/VAD (`DISPLAY\MTT1337*` + driver packages), ViGEmBus, all `nextGPU-*` scheduled tasks, wallpaper and shutdown policy (including Default user hive keys), `CLOUDFLARE_TUNNEL_TOKEN`, the `nextGPU` local user (unless `keepusers`), and generated files/logs. It does not delete Cloudflare DNS/tunnel resources from your Cloudflare account, and it does not remove the `NextGPU-Authority` admin account.

Reboot after uninstall, especially if drivers were removed.

