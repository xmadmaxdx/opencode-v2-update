# Contributing

Thanks for considering it. Issues and pull requests are both welcome.

## Ground rules

**The default contract is non-destructive.** The installer must never overwrite or delete a file in the user's OpenCode config unless `-ReplaceConfig` was passed explicitly. If you change the config step, extend the preservation test rather than trusting a read-through — that property is the whole point of this project.

**No credentials, ever.** Config values come from `{env:...}` or `{file:...}` substitution. CI fails on credential-shaped strings.

**No personal files in the payload.** `payload/config/` ships a template, not somebody's setup. Agents, commands, skills and `AGENTS.md` are personal and must not be committed here. CI enforces this.

## Before you push

```powershell
# 1. both scripts must parse
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\install.ps1), [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" } }

# 2. the config must still be valid JSONC
$raw = Get-Content payload\config\opencode.jsonc -Raw
$stripped = ($raw -split "`r?`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
$null = $stripped | ConvertFrom-Json
```

## Testing the installer safely

Do not test against your own `USERPROFILE`. Point it at a throwaway directory and neutralise the calls that touch the real machine:

```powershell
$env:USERPROFILE = "$PWD\.sandbox"
```

The calls that affect the live system are:

| Call | Guarded by |
|---|---|
| `[Environment]::SetEnvironmentVariable('Path', ..., 'User')` | only writes `User` PATH — patch out during tests |
| `npm uninstall -g ...` | runs only when a competing install is found |
| `[Environment]::GetFolderPath('Desktop')` | resolves to the real Desktop — redirect it |

A useful preservation test seeds sentinel files (a skill, an agent, a command, `AGENTS.md`, a fake data file), runs the installer, then compares SHA-256 hashes before and after. Hash comparison, not eyeballing — that is what makes the guarantee checkable.

## Commit messages

Short imperative subject, explain the *why* in the body when it is not obvious.