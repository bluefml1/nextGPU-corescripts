# Session templates (Clean Session)

Golden **replace** sources for session folder rules live under:

```text
C:\ProgramData\nextGPU\session-templates\{rule-id}\
```

Runtime config: `C:\ProgramData\nextGPU\session-folder-rules.json`

## Host setup vs Clean Session

Host layout and Clean Session are separate steps in Step 6:

| Section | Where in Controller | When | Scripts |
|---------|----------------------|------|---------|
| **Host Setup** | **Setup Games & Apps** → Host Setup tab | Operator runs manually during golden-image / maintenance | `arrange-games-apps.bat` → `Arrange-GamesApps.ps1` (display name **Setup Games & Apps**) |
| **Clean Session** | **Bypass** → Clean Session tab | Automatic every logoff (+ logon fallback) | `Invoke-SessionFolderRules.ps1` |

There is **no coupling** between them: arrange does not invoke session rules, and session rules do not invoke arrange.

## Seeding templates

Use **Seed Garena Template** on **Bypass → Clean Session** (`Seed-SessionFolderTemplates.ps1 -SeedGarena`) after host setup has placed the Garena bundle on disk. This copies `gxx` into `session-templates\garena-gxx`.

For custom rules:

```powershell
.\Seed-SessionFolderTemplates.ps1 -RuleId my-rule -FromPath 'D:\golden\my-folder'
```

## Tasks

Register once (or via Register Machine):

```powershell
.\Register-SessionFolderRulesTasks.ps1
```

- `nextGPU-SessionFolderRulesLogoff` — primary trigger at nextGPU logoff
- `nextGPU-SessionFolderRulesLogon` — verifies `.ok` markers; re-runs incomplete rules when `logonFallback` is true

`endSession.ps1` also runs the logoff phase (STEP 0) before user logoff.

## Example rule (Garena)

See `config/session-folder-rules.json.template` in the repo. Replace action copies `session-templates\garena-gxx` over `C:\ProgramData\Garena\gxx`, optionally stopping `gxxapphelper.exe` and `Garena.exe` first.
