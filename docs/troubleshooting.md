# Troubleshooting

## `Error: Background service failed to start`

The most common issue, and it is almost never a bug in OpenCode itself.

OpenCode runs as two processes: a client (the TUI you type into) and a background server that owns sessions, plugins and permissions. The server listens on a fixed port — **4096** by default. If two different OpenCode installations exist, both try to bind that port. The loser fails, and the error names the symptom rather than the cause.

### Check for duplicates

```powershell
opencode --version
npm ls -g --depth=0
Get-NetTCPConnection -LocalPort 4096 -State Listen |
    ForEach-Object { Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)" |
        Select-Object ProcessId, ExecutablePath }
```

If `npm ls` lists `@opencode/cli` **and** a manual copy exists somewhere such as `%LOCALAPPDATA%\Programs\opencode\opencode.exe`, you have the conflict.

### Fix

Run the installer. It detects a competing npm install and removes it so exactly one OpenCode remains.

If you want to keep the npm copy instead, remove the manual one by hand — but make sure **no window is still running it**, or the file stays locked and the deletion silently fails:

```powershell
Get-Process opencode -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item "$env:LOCALAPPDATA\Programs\opencode" -Recurse -Force
```

Then repoint any shortcut that referenced the deleted path.

---

## `opencode` is not recognised

The `PATH` entry only reaches **new** processes.

1. Close every terminal window.
2. Reopen one.
3. Verify: `where.exe opencode`

Windows Explorer sometimes keeps a stale copy of the environment; restart it or sign out and back in if the new terminal still cannot find the command.

---

## The free models return "OpenCode's free tier can only be used from within OpenCode"

That is an **authentication** problem, not an install problem. The free models on `opencode.ai` require a signed-in OpenCode account.

```powershell
opencode auth login
```

If you would rather not authenticate, remove the `opencode` provider block from `opencode.jsonc` and use another provider. With the default non-destructive config step, editing your own `opencode.jsonc` by hand is completely safe — the installer will not overwrite it.

---

## Antivirus quarantined the download

The OpenCode binary is fetched from `opencode.ai` over plain HTTPS and is **not code-signed**, so heuristic scanners sometimes flag it. Verify the download is genuine by checking the size and that the installed binary runs:

```powershell
& "$env:USERPROFILE\.opencode\bin\opencode.exe" --version
```

Then add an exclusion for the install directory if your AV insists.

---

## The installer stops with "version X is not downloadable"

The npm registry advertised a version that the CDN has not published yet. This is a transient upstream state, not a corrupt archive.

- Wait and re-run — the publish usually completes within minutes.
- Or pin a version you know exists:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version 2.0.29
  ```

The check exists precisely so this fails *before* anything is installed, leaving your machine untouched.

---

## `npm not found - skipping @opencode-ai/plugin`

Not fatal. It only skips the optional TUI plugin dependency; OpenCode itself works, plugins just do not load.

Install Node.js from <https://nodejs.org> and re-run with `-SkipConfig` to retry that step alone without re-downloading the binary.

---

## My config did not change

That is the intended behaviour.

The installer is additive: it adds files that are missing and leaves everything that already exists alone. If you expected your `opencode.jsonc` to be updated with the bundled one, either:

- the file already existed, so it was deliberately left alone, or
- you passed `-SkipConfig`.

To take the bundled copy deliberately:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ReplaceConfig
```

A timestamped backup is taken first.

---

## Restoring from a backup

Every run that modifies your config writes a full copy first:

```
%USERPROFILE%\.config\opencode.backup-<yyyyMMdd-HHmmss>\
```

To restore:

```powershell
$backup = Get-ChildItem "$env:USERPROFILE\.config" -Directory -Filter 'opencode.backup-*' |
          Sort-Object Name -Descending | Select-Object -First 1
Copy-Item "$($backup.FullName)\*" "$env:USERPROFILE\.config\opencode\" -Recurse -Force
```

Close OpenCode before restoring so it does not rewrite state underneath you.

---

## Getting diagnostics

```powershell
# what the installer would do right now
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Force

# what is currently owning the service port
Get-NetTCPConnection -LocalPort 4096 -State Listen

# OpenCode's own logs
Get-Content "$env:USERPROFILE\.local\share\opencode\log\opencode.log" -Tail 50

# the fully resolved configuration, after {env:...} substitution
opencode debug config
```