# PlayNiteWatcher Module Reference

Thin loader modules (`Playnite-Common.ps1`) dot-source these files -- all actual function implementations live here.

---

## Core Modules (`src/`)

### `Playnite-Path.psm1`
Path normalization, install directory resolution, folder picker dialogs, Playnite launch helpers.

| Function | Purpose |
|---|---|
| `Get-NormalizedDirectoryPath` | Normalize a path string, trim trailing backslash |
| `Expand-PlayniteInstallDirectory` | Append "Playnite" to a parent directory |
| `Get-PlayniteInstallPathFile` | Path to the `.PlayniteInstall.path` marker file |
| `Read-SavedPlayniteInstallPath` | Read the saved install path from the marker file |
| `Resolve-PlayniteInstallPathFromConfig` | Resolve from override or saved config |
| `Test-PlayniteInstalledAt` | Check if Playnite.DesktopApp.exe exists |
| `Test-PlaynitePortableLayout` | Detect portable (no unins000.exe) vs installed |
| `Get-7ZipExecutable` | Locate 7z.exe in Program Files |
| `Get-PlayniteDownloadDir` | Temp download directory |
| `Normalize-FolderPickerPath` | Normalize paths returned by folder picker dialog |
| `Test-FolderPickerPathIsDriveRoot` | Detect if user picked a bare drive root |
| `Get-PlayniteFolderPickerInitialDirectory` | Suggested initial folder for dialog |
| `Get-CommittedFolderBrowserPath` | Get a stable starting path for dialogs |
| `Show-PlayniteFolderBrowserDialog` | WinForms folder browser dialog |
| `Test-PlayniteInstallParentInsideWatcherScripts` | Guard against nested Playnite install |
| `Show-PlayniteInstallFolderDialog` | Interactive folder picker for Playnite install |
| `Resolve-PlayniteInstallDir` | Full resolution pipeline with validation |
| `Save-PlayniteInstallPath` | Write install path to marker file |
| `Get-PlayniteDesktopExe` | Resolve Playnite.DesktopApp.exe from install dir |
| `Get-PlayniteInstallRootFromExe` | Get the parent of the exe |
| `Get-ProcessByExecutablePath` | Find a running process by its exe path |
| `Start-LimitedUserProcess` | Launch a process under a limited user token |
| `Start-PlayniteProcess` | Start Playnite with optional wait |
| `Get-PlayniteDesktopExeFromConfig` | Read exe path from config |
| `Get-PlayniteDataDirectory` | Get the %LOCALAPPDATA%\Playnite data directory |

---

### `Playnite-Admin.psm1`
Administrator checks, directory junction detection, rental access ACL management.

| Function | Purpose |
|---|---|
| `Test-PathIsDirectoryJunction` | Detect reparse-point junctions |
| `Test-IsAdministrator` | Check if current session is elevated |
| `Write-PlayniteRentalAccessLog` | Audit log for rental access grants |
| `Grant-PlayniteRentalAccess` | Grant time-limited ACL on Playnite directory |
| `Test-PlayniteRentalAccess` | Check if current user can write under Playnite folder |
| `Get-PlayniteRentalAclStatus` | Inspect icacls for BUILTIN\Users Modify on Playnite folder |
| `Test-PlayniteRentalAclGranted` | True when rental ACL (Users Modify) is configured |

---

### `Playnite-Database.psm1`
LiteDB initialization, BSON document helpers, game record extraction, Playnite log watching.

| Function | Purpose |
|---|---|
| `Get-PlayniteLibraryGamesDbPath` | Find the `library.db` file |
| `Test-PlayniteLiteDbDatabase` | Validate a LiteDB file is readable |
| `Get-PlayniteLiteDbInvalidReason` | Explain why a db is unreadable |
| `Initialize-LiteDbFromPlayniteInstall` | Load LiteDB assembly from install dir |
| `Get-PlayniteLiteDbConnectionString` | Build connection string for library.db |
| `Set-LiteDbBsonField` | Safely set a BSON field, handling unwrapping |
| `Add-LiteDbBsonArrayItem` | Append to a BSON array in a document |
| `Get-BsonValueAsGuid` | Extract a GUID from a BSON value |
| `Get-BsonValueAsString` | Extract a string from a BSON value |
| `Get-BsonValueAsBool` | Extract a bool from a BSON value |
| `Get-BsonValueAsInt` | Extract an int from a BSON value |
| `Copy-LiteDbBsonValue` | Deep-copy a BSON value |
| `Copy-LiteDbBsonDocument` | Deep-copy a BSON document |
| `New-LiteDbGuidBsonDocument` | Create a `{_id: Guid}` template |
| `ConvertFrom-PlayniteLogTimestamp` | Parse Playnite's `dd-MM HH:mm:ss.fff` log format |
| `Test-PlayniteLogLineIsRecent` | Filter to recent log lines |
| `Wait-PlayniteLibraryImportInLog` | Block until Playnite finishes library scan |
| `Get-PlayActionsFromGameDocument` | Extract play actions from a game BSON doc |
| `Get-PrimaryPlayAction` | Get the primary (first) play action |
| `New-PlayniteGameRecordFromBsonDocument` | Build a PSCustomObject from a game doc |
| `Get-PlayniteGamesWithPlayActions` | Get games with populated play actions |
| `Normalize-PlayniteGamesArray` | Ensure result is always an array |
| `Get-SinglePlayniteGameRecord` | Look up one game by ID |
| `Get-PlayniteNativeGameBsonTemplateDocument` | Template for native-library games |
| `Get-RawPlayActionDocumentsFromGameDocument` | Raw play action BSON array |
| `Get-PlayniteTemplatePlayActionDocument` | Default play action template |
| `New-PlayniteFilePlayActionBson` | Create a file-type play action BSON |
| `New-PlayniteManualGameBsonDocument` | Create a manual-library game BSON doc |
| `Update-PlayniteGamePlayActionInDocument` | Update play actions in a game doc |
| `Remove-PlayniteManualGamesFromLiteDb` | Delete all manual-library entries |
| `Find-PlayniteGameForAllowlistExe` | Find a Playnite game matching an allowlist exe |
| `Get-PlayniteGameRecordsFromLiteDb` | Full game record extraction |
| `Ensure-PlayniteLibraryDatabaseUnlocked` | Verify db is not locked by Playnite |
| `Stop-PlayniteApplication` | Stop running Playnite process |
| `Move-PlayniteLibraryDatabaseAside` | Rename db to avoid conflicts |
| `Invoke-PlayniteLibraryDatabaseBootstrap` | First-run db initialization |
| `Repair-PlayniteLibraryDatabaseIfNeeded` | Detect and repair broken db |
| `Get-PlayniteLibraryGameStats` | Count games, sources, and library kinds |

---

### `Playnite-Steam.psm1`
Sunshine config path, SQLite tools download/install, Playnite extension installation.

| Function | Purpose |
|---|---|
| `Get-DefaultSunshineConfigPath` | `%ProgramW6432%\Sunshine\config` |
| `Get-SqliteToolsDirectory` | `tools\sqlite` path relative to src |
| `Get-SqliteToolsWinX64DownloadUrl` | Latest SQLite tools download URL |
| `Install-Sqlite3ToolsPortable` | Download and extract SQLite tools |
| `Get-Sqlite3Executable` | Locate sqlite3.exe |
| `Ensure-Sqlite3Available` | Auto-install if missing |
| `Expand-PlaynitePackageArchive` | Extract a Playnite package .zip |
| `Get-PlayniteExtensionPackageUrlFromManifest` | Resolve .pext download URL |
| `Get-PlayniteExtensionManifestField` | Read field from extension manifest |
| `Test-PlayniteLibraryExtensionInstalled` | Check if extension is installed |
| `Install-PlayniteExtensionFromPextFile` | Install a .pext extension package |
| `Get-NextGpuSteamExtensionsBuildRoot` | Path to NextGPU Steam extensions build |
| `Install-NextGpuSteamExtensions` | Install NextGPU Steam extension build |
| `Install-PlayniteBuiltinLibraryExtensions` | Install Steam + Epic library plugins |

---

### `Playnite-Everything.psm1`
Everything.exe integration, allowlist exe search, scan path filtering, path-walking.

| Function | Purpose |
|---|---|
| `Get-EverythingToolsDirectory` | Relative path to tools\everything |
| `Get-EverythingEsCandidatePaths` | Candidate es.exe locations |
| `Get-EverythingEsExePath` | Resolve es.exe path |
| `Get-ExcludedSystemDriveRoots` | System drive roots to skip |
| `Normalize-EverythingSearchPath` | Normalize a path for Everything query |
| `ConvertFrom-EverythingSearchOutputLine` | Parse es.exe output line |
| `Test-AllowlistedExeLeafMatch` | Case-insensitive filename match |
| `Test-PathUnderScanRoot` | Verify path is inside a scan root |
| `Test-DesktopScanDirectoryName` | Skip common excluded directories |
| `Test-DesktopScanRootIsOnSystemDrive` | Skip non-system-drive roots |
| `Test-DesktopScanInstallerExeExcluded` | Skip common installer names |
| `Test-DesktopScanPathOnSystemDrive` | Skip non-system paths in scan |
| `Select-BestAllowlistedExeHit` | Pick the best exe when multiple match |
| `Get-EverythingSearchQueriesForAllowlistExe` | Build es.exe queries for an exe |
| `Invoke-EverythingEsSearchLines` | Run es.exe and stream output lines |
| `Test-EverythingSearchHitCandidate` | Filter Everything hits |
| `Find-AllowlistedExesViaEverything` | Find matching exes using es.exe |
| `Find-AllowlistedExesUnderPathWalk` | Walk directory tree when Everything unavailable |
| `Find-AllowlistedExeHitForEntry` | Match one allowlist entry |
| `Find-AllowlistedExesUnderPath` | Scan one root for matching allowlist entries |

---

### `Playnite-Allowlist.psm1`
Desktop app allowlist types, NameId mapping, allowlist loading.

| Function | Purpose |
|---|---|
| `Get-DesktopAppAllowlistPath` | Resolve allowlist path from repo root |
| `Resolve-DesktopAppAllowlistPath` | Path with override support |
| `Get-AllowlistTypeDefinitions` | Get all defined allowlist type ranges |
| `Get-AllowlistTypeDefinition` | Get definition for one type by NameId range |
| `Get-AllowlistTypeFromNameId` | Map a NameId to its type definition |
| `Test-NameIdInAllowlistTypeRange` | Test if NameId falls in a type's range |
| `Resolve-AllowlistNameId` | Resolve full NameId from an exe path |
| `Get-DesktopAppAllowlist` | Load and return the allowlist JSON |

---

### `Playnite-Export.psm1`
Steam client detection, Steam path resolution, R2 manifest integration, exportable game records.

| Function | Purpose |
|---|---|
| `Test-PlayniteSteamClientPath` | Validate a Steam install directory |
| `Get-PlayniteSteamPathFromRegistry` | Read Steam path from registry |
| `Resolve-PlayniteSteamFromR2Manifest` | Resolve Steam from R2 deployment manifest |
| `Resolve-PlayniteSteamInstallPath` | Full resolution pipeline for Steam |
| `Register-PlayniteSteamInstallPath` | Persist Steam path to config |
| `Ensure-PlayniteSteamForLibraryScan` | Ensure Steam is available before scan |
| `Get-ExportablePlayniteGames` | Get Steam + Epic game records for Sunshine export |

---

### `Playnite-Import.psm1`
Folder picker (UI), repository root resolution, GamesApps manifest import.

| Function | Purpose |
|---|---|
| `Show-PlayniteFolderPicker` | UI folder picker for import roots |
| `Resolve-PlayNiteWatcherRepoRoot` | Find the PlayNiteWatcher repo root |
| `Get-NextGpuCoreRepoRootFromWatcher` | Locate the parent NextGPU repo root |
| `Import-NextGpuGamesAppsManifest` | Import GamesApps-Manifest.ps1 from parent repo |

---

