# PlayNite Watcher Script Guide

Welcome to the PlayNite Watcher script for Sunshine and Moonlight! This powerful script enables the automated addition of multiple games to Sunshine and ensures that Moonlight shuts down when you exit those games. It emulates the behavior of GeForce Experience, providing you with game names, box art, and additional details right within Moonlight once installed.

This script is also perfect for users who prefer the "Big Picture Mode" or FullScreen mode in PlayNite. It conveniently closes games launched in FullScreen mode upon exit, maintaining the same streamlined experience.

## Why the script is necessary

Many games launch through unique launchers that initiate separate processes. As a result, these games are often added as "detached" commands, which Sunshine and Moonlight can't monitor to close the stream automatically. This script is designed to overcome that hurdle, enabling virtually any game to launch without sacrificing auto-close functionality.

Furthermore, the script is a great asset for those seeking to streamline their big picture mode experience.

In short, this script enhances PlayNite by running games as "commands," thus allowing Sunshine to recognize when a game is closed.

## Caveats:

 - If using Windows 11, you'll need to set the default terminal to Windows Console Host as there is currently a bug in Windows Terminal that prevents hidden consoles from working properly.
    * That can be changed at Settings > System > For Developers > Terminal [Let Windows decide] >> (change to) >> Terminal [Windows Console Host]
    * On older versions of Windows 11 it can be found at: Settings > Privacy & security > Security > For developers > Terminal [Let Windows decide] >> (change to) >> Terminal [Windows Console Host]
 - The script will stop working if you move the folder, simply reinstall it to resolve that issue.
 - Due to Windows API restrictions, this script does not work on cold reboots (hard crashes or shutdowns of your computer).
    * If you're cold booting, simply sign into the computer using the "Desktop" app on Moonlight, then end the stream, then start it again. 
    * Normal reboots issued from start menu will function as intended, no workarounds needed.

## Prerequisites

Before you begin, ensure:

- Your host computer is Windows-based.
- Sunshine is installed, version [v2025.122.141614](https://github.com/LizardByte/Sunshine/releases/tag/v2025.122.141614) or higher.
---

# Vibeshine (Custom Fork)

If you want a smoother experience, Vibeshine lets you automatically sync Playnite games directly to Sunshine.  
You can also add or remove games manually from the WebUI, so there’s no need for extra scripts.  

👉 Check it out here: [Vibeshine on GitHub](https://github.com/Nonary/vibeshine/releases/latest)

If you’d rather stick with the original Sunshine and Apollo, you can skip this and continue with the section below.
---

## Automated Playnite + Steam setup

Use this if Playnite is not installed yet. Setup installs the **official Playnite portable** archive from GitHub (current releases use **`.7z`**, e.g. [10.55.7z](https://github.com/JosefNemec/Playnite/releases/download/10.55/10.55.7z) — not a `.zip`; **7-Zip** must be installed on the PC).

For full step-by-step host setup, see [`docs/Playnite-EndToEnd.md`](docs/Playnite-EndToEnd.md).

1. **Run** `Setup-PlayniteSteam.bat` — folder picker asks for a parent folder; setup always installs into **`<your-choice>\Playnite`**. Path is saved in **`PlayniteInstall.path`**. Downloads go to **`<install-folder>\Download`**.
2. **All Windows users — one library**: Program and data live under the folder you chose. Every account should launch **`<install-folder>\Playnite.DesktopApp.exe`** (not a per-user copy under `%LocalAppData%`). Only one user should run Playnite at a time.
3. **Default behavior** (Playnite only, no Playnite UI):
   - Download and extract Playnite portable
   - Configure Steam/Epic for **installed games only** (no login)
   - Install official Steam/Epic `.pext` extensions into `Extensions\`, then run `--updatelibraries` to import games from disk
4. **Sunshine/Moonlight is separate** — not part of default setup. If you use PlayNiteWatcher with Sunshine, run later:
   ```powershell
   .\Setup-PlayniteSteam.ps1 -WithSunshine -SkipInstall
   ```
   **`Setup-PlayniteSteam.bat`** (with `-WithSunshine`) also imports desktop apps via **`es.exe`** (Everything must be running in tray/service; use `-SkipEverythingInstall` for directory walk). Pick drive/folder or all non-system drives; allowlist in `config\playnite\desktop-apps.allowlist.json`.
   Manual steps if needed:
   ```powershell
   .\Import-PlayniteDesktopApps.ps1
   .\Export-SunshineFromPlaynite.ps1
   .\Install-PlayniteWatcher.ps1
   ```
5. Re-scan after new installs: `.\Update-PlayniteLibraries.ps1` — reads **`PlayniteInstall.path`** from your folder picker; no path argument needed.
6. Optional flags:
   - `-WithSunshine` — also export to Sunshine and install PlayNiteWatcher during setup
   - `-SkipInstall` — portable already extracted; re-run config + import
   - `-SkipLibraryUpdate` — skip `--updatelibraries`
   - `-LaunchPlaynite` — open Playnite desktop at the end
   - `-PortablePackagePath C:\path\10.55.7z` — local `.7z` or `.zip` instead of GitHub
   - `-PickInstallFolder` — show install folder picker again (updates `PlayniteInstall.path`)
   - `-SkipSunshineExtension` — skip copying `SunshineAppExport` into Playnite Extensions
   - `-PlayniteInstallDir` — advanced: fixed path without picker (automation only)
   - `-SkipLegacyCleanup` — do not remove old AppData junctions / `unins000.*`
   - `-FullSetup` — Steam detect, library stats, optional Sunshine extension (with `-WithSunshine`)
7. Log: `Setup-PlayniteSteam.log`. Saved install path: `PlayniteInstall.path`.

**Playnite setup prerequisites:** **7-Zip** or WinRAR/UnRAR for `.7z` portable archives. Steam/Epic clients with games installed on disk for import. Sunshine/`eventLogs.ps1` are only needed if you use the optional `-WithSunshine` path or the scripts above.

### Migrating from the old installer or `%AppData%\Playnite`

Setup does **not** copy old libraries automatically. To move an existing library manually ([Playnite FAQ](https://api.playnite.link/docs/manual/gettingStarted/helpAndTroubleshooting/faq.html)):

1. Shut down Playnite.
2. Copy everything from `%AppData%\Playnite` (or your old shared profile folder) into your portable install folder.
3. Delete `unins000.exe` and `unins000.dat` from the install folder if present.
4. Edit `<install-folder>\config.json` and set `"DatabasePath": "library"` (if needed).
5. Run setup once; it removes obsolete AppData **junctions** and `PlayniteProfile.path` unless you use `-SkipLegacyCleanup`.

---

## Setup Instructions

**Note:** This script automatically adds Playnite's fullscreen mode to Sunshine, so you don't need to manually add every game—just focus on your favorites.

1. **Open PlayNite**: Launch the PlayNite application on your computer (or use **Automated Playnite + Steam setup** above).
2. **Download the Extension**: Visit the [Playnite Add-ons page](https://playnite.link/addons.html) and download the "Sunshine App Export" extension. When prompted, open the extension in PlayNite.
3. **Restart PlayNite**: Follow the on-screen instructions to restart PlayNite and proceed to the next steps.
4. **Export Games**:
   - Click on "Controller" in the top-left corner.
   - Navigate to "Extensions" -> "Sunshine App Export" -> **Export all games** (exports your full Playnite library).
5. **Specify Sunshine Path**: If the installation path for Sunshine has changed, click "Browse" to locate it. If the path is correct, click "Export Games." Confirm the User Account Control (UAC) prompt that appears. This writes `apps.json` plus `resolved-appids.json` / `resolved-appids.txt` into your Sunshine config folder.
6. **Run the Installer**: Double-click "Installer.bat" and accept the UAC prompt to continue. 
7. **Handle Configuration Errors**: If a configuration error occurs, follow any additional instructions provided.
8. **Finalize Setup**: Click "Install" to complete the setup process. This adds **`prep-cmd` undo** (`eventLogs.ps1`) to exported apps and does **not** replace them with a `cmd` line to `PlayniteWatcher.ps1` (launch stays as exported / `resolved-appids.txt`). Session cleanup still uses `global_prep_cmd` undo via `PlayNiteWatcher-EndScript.ps1`. This will terminate any existing Moonlight sessions and restart Playnite.

### Export formats (Sunshine App Export)

- **Steam / Epic games**: Sunshine app `name` is the **NameID** (Steam AppID such as `730` for CS2, or Epic install folder name). No box art. `prep-cmd` undo runs `eventLogs.ps1` (same as Add-SteamGames). Moonlight pairing AppIDs are in `resolved-appids.txt` (CRC hash of NameID, same algorithm as Add-SteamGames). **Steam** launch lines are `&"steam.exe" -applaunch <AppId>`; **Epic** uses `&"Playnite.DesktopApp.exe" --start <playniteGameId>`.
- **Other platforms (GOG, etc.)**: Legacy export with Playnite box art under `%LocalAppData%\Sunshine Playnite App Export\Apps\`.

Ensure `C:\Program Files\Sunshine\scripts\eventLogs.ps1` exists (for example by running Add-SteamGames.ps1 once) before streaming.

### Important Notes:
- **Automatic Duplicate Removal**: The script automatically removes duplicate exports when installing, so you don't have to worry about accidentally adding the same game more than once.
- **Re-exporting Games**: Re-export in Playnite, then run **Installer.bat** and click **Install** again when you add or refresh games.
- **Removing Applications**: To remove exported applications, either:
  - Visit the Sunshine Web UI application tab and remove them manually, or
  - Uninstall the script, which will remove remove **all** exported games.


## Troubleshooting

If you encounter any issues with the PlayNite Watcher script, follow these steps:

1. **Review Setup Instructions**: Double-check the setup instructions to ensure all steps were completed correctly.
2. **Verify Prerequisites**: Confirm that all required prerequisites are installed and properly configured.
3. **Update Sunshine**: Ensure that Sunshine is updated to at least version 0.20.

### Export Issues: Not All Games Are Exported
Steam and Epic entries are exported whenever Playnite has a valid GameId / install path. **Legacy** (cover art) exports still require downloaded metadata. If you have added games manually (e.g., via scanning or manual entry), ensure that you download all necessary metadata for those games. To download metadata in Playnite:

1. Right-click the game in Playnite.
2. Select "Edit."
3. Click the "Download Metadata" button.
4. Choose "IGDB," select the correct game name, and follow the on-screen instructions to import all available data.

**Tip:** You can automate metadata downloads for all games by clicking the Playnite menu button and selecting "Download Metadata" (or press Control + D).

### Session Not Terminating When Closing a Game
If the script doesn’t terminate the session when you close a game, it may be due to the script being saved in a location that requires administrator rights. This script does not run in administrator mode. To resolve this:

- Adjust the folder's file permissions to allow write access for users.
- Alternatively, move the folder to your user profile (e.g., Documents, Desktop) and reinstall the script.

If these steps don’t resolve your issues, seek further support on the Sunshine or Moonlight Discord channels. You can also contact the script creator, demon.cat, for additional help.