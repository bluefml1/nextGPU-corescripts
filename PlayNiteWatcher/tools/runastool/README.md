# RunAsTool (bypass shortcuts)

Playnite bypass setup uses [Sordum RunAsTool v1.5](https://www.sordum.org/8727/runastool-v1-5/) to create elevated launch shortcuts in a `Bypasses` folder.

## Operator flow (NextGPU Playnite page)

1. **Setup Bypass Folder** — pick parent folder; creates `{parent}\Bypasses`; installs RunAsTool to ProgramData.
2. **Add / Sync Bypass App** — pick exe and shortcut name; **RunAsTool automation** registers the app and creates the `.lnk` in Bypasses; allowlist + Playnite are updated.
3. **Re-sync Bypass Shortcuts** — repair Playnite bindings from existing `.lnk` files (no RunAsTool).

RunAsTool does not need to be opened manually in the normal flow.

## Install / maintenance

RunAsTool is auto-downloaded when missing:

```powershell
.\PlayNiteWatcher\Install-RunAsTool.ps1
```

Open RunAsTool manually for troubleshooting:

```powershell
.\PlayNiteWatcher\Launch-RunAsTool.ps1
```

Installed copy: `C:\ProgramData\NextGPU\RunAsTool\`.

## Automation details

`Invoke-RunAsToolGuiAutomation.ps1` drives RunAsTool via UI automation: Add File, enable **Run as administrator**, Create Shortcut into the Bypasses folder. The wizard supplies the **NextGPU-Authority** password for first-time RunAsTool login.

If automation fails, retry or run with manual fallback:

```powershell
.\Sync-PlayniteBypassShortcuts.ps1 -Interactive -ManualFallback
```

Bulk app lists can still be imported via `.rnt` and `Invoke-RunAsToolImportRnt.ps1`.

## Admin account

Provisioning sets the local admin username to **NextGPU-Authority**. The bypass wizard prompts for that password once per session (not stored in repo config).
