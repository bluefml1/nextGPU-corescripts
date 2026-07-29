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

## Operator flow (Controller)

On **Setup Games & Apps → Clean Session**:

1. **Import JSON** — load the session-folder rules file NextGPU assigned to this machine.
2. Confirm the rules table matches what you expect (id, target, source, stop, logon).
3. **Register Session Folder Tasks** — activates logoff/logon scheduled tasks.

**Do not use Seed Garena Template** in the normal operator path — **Host Setup → Setup Games & Apps** already lays out Garena so the replace source is ready. Optional helpers if you need them: **Open session-templates Folder**, **Run Logoff Rules (test)**.

## Seeding templates (advanced / recovery only)

Normal hosts skip this. Host Setup already prepares Garena. Use seeding only for custom rules or if a template folder is missing:

```powershell
.\Seed-SessionFolderTemplates.ps1 -RuleId my-rule -FromPath 'D:\golden\my-folder'
```

Legacy Garena-only seed (usually unnecessary after Host Setup):

```powershell
.\Seed-SessionFolderTemplates.ps1 -SeedGarena
```

## Tasks

Register once (or via Register Machine):

```powershell
.\Register-SessionFolderRulesTasks.ps1
```

- `nextGPU-SessionFolderRulesLogoff` — primary trigger at nextGPU logoff
- `nextGPU-SessionFolderRulesLogon` — verifies `.ok` markers; re-runs incomplete rules when `logonFallback` is true

`endSession.ps1` also runs the logoff phase (STEP 0) before user logoff.

## NextGPU-Admin at session end

**Notice:** Session end (`endSession.ps1` STEP 7b) **deletes the `NextGPU-Admin` local account and its profile**, then **recreates** it as an administrator using the password stored at Register Machine (DPAPI). That keeps RunAsTool bindings working for the next rental while wiping leftover admin-profile state (Clean Session hygiene).

Operators should:

- Keep the **NextGPU-Admin password** they set during Register Machine.
- Not store important files only under the `NextGPU-Admin` profile — it will be removed each session end.

## Example rule (Garena)

See `config/session-folder-rules.json.template` in the repo. Replace action copies `session-templates\garena-gxx` over `C:\ProgramData\Garena\gxx`, optionally stopping `gxxapphelper.exe` and `Garena.exe` first.
