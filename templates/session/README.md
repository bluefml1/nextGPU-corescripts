# Session templates (Clean Session)

Golden **replace** sources for session folder rules live under:

```text
C:\ProgramData\nextGPU\session-templates\{rule-id}\
```

Runtime config: `C:\ProgramData\nextGPU\session-folder-rules.json`

## Host setup vs Clean Session

Both are on the NextGPU HOST page **Setup Games & Apps** (separate tabs):

| Section | When | Scripts |
|---------|------|---------|
| **Host Setup** | Operator runs manually during golden-image / maintenance | `arrange-games-apps.bat` → `Arrange-GamesApps.ps1` (display name **Setup Games & Apps**) |
| **Clean Session** | Automatic every logoff (+ logon fallback) | `Invoke-SessionFolderRules.ps1` |

There is **no coupling** between them: arrange does not invoke session rules, and session rules do not invoke arrange.

## Seeding templates

Use **Seed Garena Template** (or Arrange Garena) after the Garena bundle is on disk. It discovers the folder under bundle `Config\` that contains `gxx`, copies it to `session-templates\<that-name>`, and **upserts** a replace rule targeting `ProgramData\<that-name>`. No Garena rule is shipped in the config template.

For custom rules:

```powershell
.\Seed-SessionFolderTemplates.ps1 -RuleId my-rule -FromPath 'D:\golden\my-folder'
```

## Tasks

Register once (or via Register Machine):

```powershell
.\Register-SessionFolderRulesTasks.ps1
```

- `nextGPU-SessionFolderRulesLogoff` — runs as **SYSTEM** when `nextGPU` signs out. Prefer native LogoffTrigger where available; on Windows builds without “At log off” (common), uses **Security event 4647** for account `nextGPU`.
- `nextGPU-SessionFolderRulesLogon` — verifies `.ok` markers; re-runs incomplete rules when `logonFallback` is true

`endSession.ps1` also runs the logoff phase (STEP 0) before user logoff.

## Example rule (Garena)

See `config/session-folder-rules.json.template` in the repo (starts with empty `rules`). Garena Arrange/Seed registers the replace rule dynamically from the discovered Config folder name.
