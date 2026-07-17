# RunAsTool (bypass shortcuts)

Playnite bypass setup uses **Sordum RunAsTool v1.5** (CLI `.rnt` import via `/U=`, `/P=`, `/I=`, `/R`). Live sordum.org now ships v1.6, which removed Import Cmd parameters — do not use v1.6 here.

## Operator flow (NextGPU Playnite page)

1. **Setup Bypass Folder** — pick parent folder; creates `{parent}\Bypasses`; installs RunAsTool to ProgramData.
2. **Add / Sync Bypass App** — pick exe and shortcut name; **RunAsTool automation** registers the app and creates the `.lnk` in Bypasses; allowlist + Playnite are updated.
3. **Re-sync Bypass Shortcuts** — repair Playnite bindings from existing `.lnk` files (no RunAsTool).

RunAsTool does not need to be opened manually in the normal flow.

## Install / maintenance

`Install-RunAsTool.ps1` always installs **v1.5**. Preferred source is the vendored zip:

`PlayNiteWatcher/tools/runastool/RunAsTool-1.5.zip`

(SHA256-checked, offline). Remote Internet Archive URLs are only a fallback and may hit 429 rate limits.

```powershell
.\PlayNiteWatcher\Install-RunAsTool.ps1
```

Open RunAsTool manually for troubleshooting:

```powershell
.\PlayNiteWatcher\Launch-RunAsTool.ps1
```

Installed copy: `C:\ProgramData\NextGPU\RunAsTool\`.
If ProgramData already has a newer build, it replaces it with v1.5.

## Automation details

`Invoke-RunAsToolGuiAutomation.ps1` drives RunAsTool via UI automation: Add File, enable **Run as administrator**, Create Shortcut into the Bypasses folder. The wizard supplies the **NextGPU-Authority** password for first-time RunAsTool login.

If automation fails, retry or run with manual fallback:

```powershell
.\Sync-PlayniteBypassShortcuts.ps1 -Interactive -ManualFallback
```

Bulk app lists can still be imported via `.rnt` and `Invoke-RunAsToolImportRnt.ps1`.

## Admin account

Provisioning sets the local admin username to **NextGPU-Authority**. The bypass wizard prompts for that password once per session (not stored in repo config).
