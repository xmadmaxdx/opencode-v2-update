# OpenCode v2 Update

**One command to put [OpenCode](https://opencode.ai) 2.x on a machine - always the newest build, never touching the setup you already have.**

Works on **Windows, macOS and Linux**. Resolves the latest version at run time, falls back across four install methods until one produces a working binary, and leaves your existing config completely alone.

```
Windows:   double-click INSTALL.cmd
mac/Linux: ./install.sh
```

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Quick start](#quick-start)
- [What a run looks like](#what-a-run-looks-like)
- [The four install methods](#the-four-install-methods)
- [The fallback chain](#the-fallback-chain)
- [Platform support](#platform-support)
- [The guarantee](#the-guarantee)
- [Credentials](#credentials)
- [What gets installed, and where](#what-gets-installed-and-where)
- [All options](#all-options)
- [Upgrading](#upgrading)
- [How "latest" is resolved](#how-latest-is-resolved)
- [What is verified, and how](#what-is-verified-and-how)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Why this exists

Installing OpenCode 2.x is awkward in five specific, reproducible ways. Each one below is a bug this project was written to remove.

### 1. Version pins go stale immediately

Most installers hardcode a version in the script. OpenCode 2.x ships frequently - this was written against **2.0.26** and the registry already had **2.0.29**. A pinned installer quietly installs an old build and there is nothing to signal it.

**Fix:** the version is resolved at run time from OpenCode's own update endpoint, and confirmed to exist before anything is installed.

### 2. Two installs fight over a port

OpenCode runs as a client plus a background server. The server binds a fixed port (**4096**). Install OpenCode twice - an npm copy and a manual one, say - and the second fails with the famously unhelpful:

```
Error: Background service failed to start
    at service.ensure (B:/~BUN/root/chunk-byt0d468.js:3:4841)
    at cli.server-connection.resolve (B:/~BUN/root/chunk-q5e81s9g.js:96:6565)
```

**Fix:** the installer audits every existing OpenCode, keeps exactly one, and removes the duplicates that cause the conflict.

### 3. Config installers destroy what you have

The common approach mirrors a bundled config over `~/.config/opencode` with `robocopy /MIR` or `rsync --delete`. **That deletes anything the payload does not contain** - your skills, your MCP servers, your agents, your session data.

**Fix:** additive by default. Files that already exist are left byte-for-byte alone. The destructive behaviour is opt-in only.

### 4. The installer path you reach for first may not exist

`opencode.ai/files/bin/` serves macOS and Windows builds but returns **HTTP 404 for every `linux-*` asset**:

| Asset | `opencode.ai/files/bin/` |
|---|---|
| `opencode-darwin-x64.zip` | OK, 86.2 MB |
| `opencode-darwin-arm64.zip` | OK, 81.4 MB |
| `opencode-windows-x64.zip` | OK, 95.7 MB |
| `opencode-windows-arm64.zip` | OK, 91.4 MB |
| `opencode-linux-x64.zip` | **404** |
| `opencode-linux-arm64.zip` | **404** |
| `opencode-linux-x64-musl.zip` | **404** |

**Fix:** this installer uses the **per-target npm tarballs** that upstream actually publishes, which cover all three operating systems through one code path:

| Target | Published |
|---|---|
| `cli-darwin-x64`, `cli-darwin-arm64`, `cli-darwin-x64-baseline` | yes |
| `cli-linux-x64`, `cli-linux-arm64`, `cli-linux-x64-musl` | yes |
| `cli-windows-x64`, `cli-windows-arm64`, `cli-windows-x64-baseline` | yes |

### 5. 1.x and 2.x silently overwrite each other

Both products register a command called `opencode`. Install both and only one runs, unpredictably.

Worse, the identifiers are **different in every package manager**, which is how people end up with a 1.x that survives an attempted upgrade:

| | OpenCode **1.x** | OpenCode **2.x** |
|---|---|---|
| **npm** | `npm install -g opencode-ai` | `npm install -g @opencode/cli` |
| **bun** | `bun install -g opencode-ai` | `bun install -g --trust @opencode/cli` |
| **brew** | `brew install anomalyco/tap/opencode` | `brew install anomalyco/tap/opencode-v2` |
| **curl** | `curl -fsSL https://opencode.ai/install \| bash` | `curl -fsSL https://opencode.ai/v2/install \| bash` |
| npm latest | `1.19.0` | `2.0.29` |

Note the brew formulae are genuinely different - `opencode` versus `opencode-v2` - so "remove the brew one" is ambiguous unless you know which major you are looking at.

**Fix:** OpenCode 1.x is removed on every install, across **all four vectors**, not just npm. It is not something you have to remember to ask for - it is what the installer does.

Removal is always keyed to the **1.x identifier**, so a 2.x install can never be removed by mistake. A manual 1.x binary is **quarantined** - moved to a timestamped name, never deleted.

```
==> OpenCode 1.x
    [info] 1.x npm package : opencode-ai@1.19.0
    ==> Removing legacy 1.x install
    [info] found opencode-ai@1.19.0
    [ok]   uninstalled opencode-ai
    [ok]   removed brew formula opencode (1.x)
    [ok]   quarantined legacy binary -> ~/.opencode/bin/opencode-1x-20261015-105458
```

### This was tested, not assumed

The claim above is backed by a real run. A genuine OpenCode **1.19.0** was installed into an isolated npm prefix, the installer was run against it, and the machine's own package list was compared before and after:

```
REAL BEFORE:
    `-- @opencode/cli@2.0.23

=== installing a REAL OpenCode 1.x into the sandbox ===
SANDBOX globals now:
    `-- opencode-ai@1.19.0
  ok  1.x is really installed: opencode-ai@1.19.0
  ok  1.x shim present at: ...\npm-global\opencode.cmd (True)

=== running the installer's 1.x removal ===
    [info] 1.x npm package : opencode-ai@1.19.0
    ==> Removing legacy 1.x install
    [info] found opencode-ai@1.19.0
    [ok]   uninstalled opencode-ai

=== did 1.x actually go away? ===
  ok    1.x package removed from the sandbox
  ok    1.x shim removed

=== did the REAL machine survive untouched? ===
REAL AFTER:
    `-- @opencode/cli@2.0.23
  ok    real global package list is IDENTICAL
  ok    'opencode' still resolves: ...\npm\opencode.ps1

RESULT: PASS - 1.x removal is real, real machine untouched
```

A real 1.x went in, was detected, was removed, and the 2.x install sitting next to it was left byte-identical.

You can opt out with `-SkipUninstallV1` (Windows) or `--keep-legacy` (macOS/Linux) if you genuinely need 1.x to stay - but be aware the two will conflict.

---

## Quick start

### Windows

1. Extract so you end up with `C:\opencode-v2-update\`
2. Double-click **`INSTALL.cmd`**, or run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\opencode-v2-update\install.ps1
   ```

### macOS

1. Extract so you end up with `opencode-v2-update/`
2. From Terminal, in that folder:

   ```bash
   chmod +x install.sh && ./install.sh
   ```

   macOS Gatekeeper blocks double-clicked `.command` files the first time. Either right-click and choose Open, or just run it from Terminal as above.

### Linux

```bash
chmod +x install.sh && ./install.sh
```

### Afterwards

**Reopen your terminal.** Already-open windows keep the old `PATH`.

```bash
cd <project>   # open a directory
opencode       # start
```

---

## What a run looks like

This is real output from the test suite, not an illustration.

### Windows - the direct path

```
    [info] looking up the newest 2.x release
    [ok]   resolved latest: 2.0.29
    [ok]   2.0.29 is published for windows-x64 (scope @opencode)

==> Preflight
    [ok]   PowerShell 5.1.26100.9444
    [ok]   CPU architecture: x64
    [ok]   Internet reachable (opencode.ai)
    [ok]   Payload found: C:\opencode-v2-update\payload\config
    [ok]   Scratch folder: %TEMP%\opencode-install-20261015-105458

==> Auditing existing OpenCode installs
    [info] 2.x npm package : @opencode/cli@2.0.23
    [info] on PATH: C:\Users\user\AppData\Roaming\npm\opencode

==> Installing your config
    [ok]   added 2 file(s) that were missing
    [ok]   left your existing 1 file(s) untouched
    [info] your skills, agents, commands and stored data were not modified

==> Installing OpenCode 2.0.29
    [info] --- method: direct ---
    [info] downloading @opencode/cli-windows-x64
    [ok]   downloaded 95.3 MB
    [ok]   installed to C:\Users\user\.opencode\bin\opencode.exe
    [ok]   direct install verified at 2.0.29

==> Checking for a competing npm install
    [ok]   npm OpenCode 2.x is the active install; nothing to remove

==> Updating PATH
    [ok]   added C:\Users\user\.opencode\bin to the User PATH

==> Creating the desktop shortcut
    [ok]   launches Windows Terminal with OpenCode
    [ok]   created C:\Users\user\Desktop\OpenCode.lnk

==> Verifying
    [ok]   reported version: 2.0.29
    [ok]   binary: C:\Users\user\.opencode\bin\opencode.exe

==> Done

    opencode is ready. Reopen your terminal, then run:

        cd <project>   # open a directory
        opencode       # start

    Docs: https://opencode.ai/v2/docs
```

### Windows - the fallback chain, direct forced to fail

```
==> Installing OpenCode 2.0.29
    [info] --- method: direct ---
    [warn] direct install failed: SANDBOX: direct forced to fail
    [info] --- method: npm ---
    [info] installing with npm
    [ok]   installed via npm (reports 2.0.29)
    [ok]   npm install verified at 2.0.29

==> Updating PATH
    [info] npm puts opencode on PATH itself - nothing to do
```

### macOS / Linux

```
==> Finding the newest OpenCode 2.x
    [ok]   latest is 2.0.29

==> Preflight
    [ok]   curl and tar are available
    [ok]   internet reachable
    [ok]   target: darwin-arm64 (darwin, arm64)

==> Installing OpenCode 2.0.29
    [info] --- method: direct ---
    [ok]   2.0.29 is published for darwin-arm64
    [info] downloading cli-darwin-arm64
    [ok]   installed to /Users/you/.opencode/bin/opencode

==> OpenCode 1.x
    [ok]   removed npm package opencode-ai (1.x)

==> Config
    [ok]   added 2 file(s) that were missing
    [ok]   left your existing 1 file(s) untouched
    [info] your skills, agents, MCP servers, providers and stored data were not modified

==> Verifying
    [ok]   binary: /Users/you/.opencode/bin/opencode
    [ok]   reports version 2.0.29
```

### When everything fails

The chain never fails silently. If all four methods are exhausted:

```
    [FAIL] every install method failed
    [FAIL] tried: direct, npm, bun, brew
    [FAIL] if you are behind a proxy, set HTTPS_PROXY and re-run
```

---

## The four install methods

| # | Method | Command used | Requires | Produces |
|---|---|---|---|---|
| 1 | **direct** | per-target npm tarball to `~/.opencode/bin` | `curl` + `tar` (npm on Windows) | `~/.opencode/bin/opencode` |
| 2 | **npm** | `npm install -g @opencode/cli` | Node.js | npm global prefix |
| 3 | **bun** | `bun install -g --trust @opencode/cli` | Bun | bun global prefix |
| 4 | **brew** | `brew install anomalyco/tap/opencode-v2` | Homebrew (macOS/Linux) | Homebrew prefix |

**Direct is tried first** because it needs no package manager, needs no `sudo`, installs to one predictable location, and works identically on all three operating systems. The package managers are there so that a blocked CDN, a proxy, or a missing `tar` does not dead-end the install.

### Force a specific method

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Method npm
```

```bash
./install.sh --method brew
```

Valid: `auto` (default), `direct`, `npm`, `bun`, `brew`.

---

## The fallback chain

Every method is **verified before it is accepted**. A method only counts as successful if the binary it produced actually reports the expected version:

```
direct  ->  npm  ->  bun  ->  brew
```

Two independent gates:

1. **Install gate** - did the command exit 0 and produce a binary?
2. **Verify gate** - does that binary print exactly the resolved version?

If a method passes the install gate but fails the verify gate (for example npm installs 2.0.23 when 2.0.29 was requested), the installer says so and moves on rather than leaving a wrong version in place:

```
    [warn] npm did not produce 2.0.29 (got '2.0.23'); trying the next method
```

With `-Method <name>` there is no chain: a failure is fatal, because you asked for that method specifically.

---

## Platform support

| | Windows | macOS | Linux |
|---|---|---|---|
| **PowerShell 5.1+** | native | - | - |
| **bash 3.2+** | via Git Bash | yes | yes |
| Architectures | x64, arm64 | x64, arm64 | x64, arm64, musl |
| Baseline builds | auto (no AVX2) | auto (no AVX2) | auto (no AVX2) |
| Rosetta | - | detected, prefers arm64 | - |
| Double-click entry | `INSTALL.cmd` | `INSTALL.command` | - |

Target detection mirrors upstream's installer, including the awkward cases: Rosetta translation on Apple Silicon, musl libc on Alpine, and AVX2-baseline selection on older x64 CPUs.

Requirements are deliberately minimal - **only `curl` and `tar`**, both present by default everywhere. No `jq`, no `awk`, no `sed`, no Python. The version JSON is parsed with native bash regex and PowerShell's own JSON handling.

---

## The guarantee

> **By default this installer never overwrites and never deletes a file in your OpenCode config.**

That includes the things people actually care about:

| Preserved | How it is proven |
|---|---|
| MCP servers | SHA-256 identical after run |
| Model providers | SHA-256 identical after run |
| `permission` rules | SHA-256 identical after run |
| Agents, commands, skills | SHA-256 identical after run |
| `AGENTS.md` | SHA-256 identical after run |
| `opencode.jsonc` | SHA-256 identical after run |
| Session / stored data | SHA-256 identical after run |

The bundled payload is three small files, and the installer only adds the ones you are missing:

```
==> Installing your config
    [ok]   added 2 file(s) that were missing
    [ok]   left your existing 1 file(s) untouched
    [info] your skills, agents, commands and stored data were not modified
```

A timestamped backup is taken first, on every run that touches the config:

```
%USERPROFILE%\.config\opencode.backup-20261015-103056\
~/.config/opencode.backup-20261015-103056/
```

### Why the payload is empty on purpose

```
payload/config/opencode.jsonc    517 bytes - "$schema" and "lsp", nothing else
payload/config/package.json      declares @opencode-ai/plugin
payload/config/.gitignore
```

It ships **no providers, no MCP servers, no agents, no commands, no skills, no permissions, no `AGENTS.md`**.

This is not laziness, it is the fix. An installer that bundles MCP servers and providers must choose between overwriting yours - breaking your setup - or skipping them, leaving you half-configured. Shipping nothing removes the choice. A fresh machine gets a clean baseline; an existing machine keeps everything it had.

### If you do want the bundled copy to win

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -ReplaceConfig
```

```bash
./install.sh --replace-config
```

Backup is taken first either way.

---

## Credentials

**This repository contains no API keys, tokens or passwords**, and CI fails the build if a credential-shaped value ever appears.

The shipped config has no providers and no MCP servers, so nothing in it needs a secret. When you add your own, keep the value out of the file:

```jsonc
{
  "mcp": {
    "github": {
      "type": "remote",
      "url": "https://api.githubcopilot.com/mcp/",
      "headers": { "Authorization": "Bearer {env:GITHUB_TOKEN}" }
    }
  }
}
```

`{file:~/.secrets/provider-key}` works too. Either way the secret lives outside the config, so the config itself is safe to commit.

CI scans for `github_pat_`, `gh[pousr]_`, `sbp_`, `nfp_`, `sk-` and JWT shapes, and refuses the build on any hit.

---

## What gets installed, and where

| Thing | Windows | macOS / Linux |
|---|---|---|
| Binary | `%USERPROFILE%\.opencode\bin\opencode.exe` | `~/.opencode/bin/opencode` |
| Config (missing files only) | `%USERPROFILE%\.config\opencode\` | `~/.config/opencode/` |
| Config backup | `...\.config\opencode.backup-<stamp>\` | `~/.config/opencode.backup-<stamp>/` |
| PATH | User PATH, added idempotently | `.zshrc` / `.bashrc` / `.profile` |
| Shortcut | `OpenCode.lnk` (Windows Terminal) | - |
| Alias | - | `opencode2` shim, as upstream provides |

`service.json` is **not** shipped - it holds a machine-specific port and password, and OpenCode generates its own.

---

## All options

### Windows - `install.ps1`

| Flag | Effect |
|---|---|
| *(none)* | Install newest 2.x. Additive config. 1.x removed. |
| `-Latest` | Explicitly resolve newest 2.x (same as default) |
| `-Version 2.0.29` | Pin an exact version |
| `-Method auto\|direct\|npm\|bun\|brew` | Choose the install method (default `auto`) |
| `-SkipConfig` | Binary only. Do not touch your config at all |
| `-ReplaceConfig` | Opt in to the destructive mirror |
| `-SkipUninstallV1` | Keep OpenCode 1.x instead of removing it. Off by default. |
| `-Force` | Non-interactive; assume yes to every prompt |

### macOS / Linux - `install.sh`

| Flag | Effect |
|---|---|
| *(none)* | Install newest 2.x. Additive config. 1.x removed. |
| `-v, --version 2.0.29` | Pin an exact version (leading `v` accepted) |
| `--method auto\|direct\|npm\|bun\|brew` | Choose the install method (default `auto`) |
| `--skip-config` | Binary only |
| `--replace-config` | Opt in to the destructive mirror |
| `--keep-legacy` | Keep OpenCode 1.x instead of removing it. Off by default. |
| `--no-modify-path` | Do not edit your shell rc file |
| `-h, --help` | Show help |

Environment: `OPENCODE_INSTALL_DIR` overrides the install directory.

---

## Upgrading

```powershell
powershell -ExecutionPolicy Bypass -File "C:\opencode-v2-update\Upgrade-OpenCode.ps1"
```

```bash
./Upgrade-OpenCode.sh
./Upgrade-OpenCode.sh --check     # report only, change nothing
```

Upgrading replaces the binary in place and re-verifies the reported version. It refuses to run against a 1.x install and tells you to run `install.sh` instead, because 1.x and 2.x cannot be upgraded into each other.

This exists because the built-in `opencode upgrade` needs `bash`, which most Windows machines do not have.

---

## How "latest" is resolved

OpenCode 2.x publishes **no GitHub Release assets** - the GitHub "latest release" is still 1.18.x. So the version comes from OpenCode's own update endpoint, the same one the upstream installer uses:

```bash
GET https://opencode.ai/update/api/latest/cli/npm
-> {"version":"2.0.29","metadata":{"package":"@opencode/cli", ...}}
```

If that endpoint is unreachable, the installer falls back to the npm registry:

```bash
GET https://registry.npmjs.org/@opencode%2Fcli/latest
```

Three guards on the result:

1. **Must be 2.x** - anything else aborts, so a 1.x download is impossible
2. **Must exist for your target** - checked before anything is installed
3. **Must extract and run** - the binary must report the exact expected version

Scope fallback: if `@opencode/cli-<target>` is absent for an older release, `@opencode-ai/cli-<target>` is tried, matching upstream's own compatibility path.

---

## What is verified, and how

Claims in a README are worth nothing without evidence, so here is exactly what has been executed:

| Check | Result |
|---|---|
| `install.sh` unit tests | **21/21 pass** - version parsing, 2.x guard, arg parsing, binary-version parsing, additive config, payload purity |
| bash syntax, all 4 shell scripts | clean (`bash -n`) |
| Windows install, direct path | exit 0, installed 2.0.29, reports `opencode v2.0.29` |
| Windows fallback chain | direct forced to fail, npm engaged, verified 2.0.29 |
| **1.x removal, real 1.19.0** | installed a genuine 1.x, detected it, removed it; machine's package list byte-identical afterwards |
| Tarball layout, darwin-arm64 | `package/bin/opencode` |
| Tarball layout, windows-x64 | `package/bin/opencode.exe`, runs, reports `v2.0.29` |
| CDN vs npm target coverage | files/bin has no Linux; npm tarballs cover all three OSes |
| **Non-destructive default** | 12 sentinels seeded - MCPs, providers, permissions, agents, commands, skills, `AGENTS.md`, storage - **all survived byte-for-byte by SHA-256** |
| Shipped config validity | parses as JSONC |
| Secret scan | zero credentials |
| Payload purity | no agents, commands, skills, `AGENTS.md`, or personal config |

The preservation test is the important one. It is not a claim about the code reading correctly - it is a hash comparison of your files before and after.

Three genuine bugs were found and fixed by these tests, which is the point of running them:

- `Get-ActiveBinary` assumed `%APPDATA%\npm` instead of asking `npm prefix -g`
- the duplicate-cleanup could remove the very install it had just created, when npm was the chosen method
- legacy removal force-killed *every* running `opencode` process, including the user's live session

---

## Project layout

```
opencode-v2-update/
  README.md                  this file
  INSTALL.cmd                double-click entry (Windows)
  INSTALL.command            double-click entry (macOS)
  install.ps1                installer - Windows
  install.sh                 installer - macOS / Linux
  Upgrade-OpenCode.ps1       upgrade - Windows
  Upgrade-OpenCode.sh        upgrade - macOS / Linux
  test-install.sh            unit tests for the shell installer
  README.txt                 offline manual (ships in the zip)
  CONTRIBUTING.md            how to contribute, how to test safely
  SECURITY.md                no-credentials policy, private reporting
  LICENSE                    MIT
  docs/
    troubleshooting.md
  payload/config/
    opencode.jsonc           baseline only - $schema and lsp
    package.json             declares @opencode-ai/plugin
    .gitignore
  .github/workflows/ci.yml
```

---

## Troubleshooting

Full guide: [`docs/troubleshooting.md`](docs/troubleshooting.md).

**`Background service failed to start`** - two OpenCode installs competing for port 4096.

```bash
opencode --version
npm ls -g --depth=0
Get-NetTCPConnection -LocalPort 4096 -State Listen   # Windows
lsof -i :4096                                      # macOS / Linux
```

**`opencode` is not recognised** - the PATH entry only reaches new processes. Close every terminal, reopen, verify with `where.exe opencode` / `command -v opencode`.

**Free models return "OpenCode's free tier can only be used from within OpenCode"** - an authentication problem, not an install problem. `opencode auth login`, or use another provider.

**Antivirus flagged the download** - the binary is fetched over plain HTTPS and is not code-signed. Verify it runs, then add an exclusion if your AV insists.

**"version X is not published for \<target\>"** - the registry advertised a version the CDN has not published yet. Transient. Re-run, or pin a known-good version.

---

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

Three ground rules:

1. **The default contract is non-destructive.** The installer must never overwrite or delete a file in the user's config unless `-ReplaceConfig` / `--replace-config` was passed explicitly. Extend the preservation test rather than trusting a read-through.
2. **No credentials, ever.** Use `{env:...}` / `{file:...}` substitution. CI enforces it.
3. **No personal files in the payload.** CI enforces this too.

Run the shell tests before pushing:

```bash
bash test-install.sh
```

---

## License

MIT - see [LICENSE](LICENSE). (c) 2026 Simanta Das.

OpenCode itself is licensed separately by its authors. No OpenCode source code is included in this repository; it only installs and configures it.