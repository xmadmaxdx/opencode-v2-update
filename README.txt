================================================================================
  opencode-v2-update  -  portable installer for OpenCode 2.x
  Windows  |  macOS  |  Linux
================================================================================

WHAT THIS IS
  A self-contained installer that puts the newest OpenCode 2.x on a machine.

  * It always installs the latest release - the version is resolved when you
    run it, not baked into this script.
  * It tries four install methods and keeps the first that actually works.
  * It NEVER overwrites or deletes anything in your existing OpenCode config.
  * It removes OpenCode 1.x by default, because 1.x and 2.x overwrite each
    other's `opencode` command and both claim the background service port.
  * It ships no credentials of any kind.


--------------------------------------------------------------------------------
HOW TO USE IT
--------------------------------------------------------------------------------

  WINDOWS
    1. Extract this folder to C:\      (you get C:\opencode-v2-update\)
    2. Double-click  C:\opencode-v2-update\INSTALL.cmd

    Or from a terminal:

        powershell -ExecutionPolicy Bypass -File C:\opencode-v2-update\install.ps1

  macOS
    1. Extract this folder.
    2. From Terminal, in that folder:

        chmod +x install.sh && ./install.sh

    Or double-click  INSTALL.command.  macOS Gatekeeper blocks double-clicked
    .command files the first time - right-click it and choose Open, or just
    run the command above.

  LINUX
    In that folder:

        chmod +x install.sh && ./install.sh

  Afterwards: reopen your terminal. Already-open windows keep the old PATH.

      cd <project>      # open a directory
      opencode          # start


--------------------------------------------------------------------------------
WHAT NEEDS TO BE TRUE
--------------------------------------------------------------------------------
  Windows : Windows 10 or 11, x64 or ARM64, PowerShell 5.1+ (already present)
  macOS   : macOS with x64 or Apple Silicon
  Linux   : x64, ARM64, or musl libc (Alpine)
  All     : internet access, and `curl` + `tar` (present by default everywhere)

  Node.js is NOT required. npm, bun and brew are optional - they are only used
  as fallbacks if the direct download cannot work.


--------------------------------------------------------------------------------
THE FOUR INSTALL METHODS
--------------------------------------------------------------------------------
  They are tried in this order, and the first one that produces a binary
  reporting the expected version wins:

    1. direct   per-target npm tarball -> ~/.opencode/bin
                needs only curl + tar; same code path on all three systems

    2. npm      npm install -g @opencode/cli

    3. bun      bun install -g --trust @opencode/cli

    4. brew     brew install anomalyco/tap/opencode-v2      (macOS / Linux)

  Direct is first because it needs no package manager, needs no admin rights,
  and installs to one predictable place. The package managers are the safety
  net for a blocked CDN, a proxy, or a missing `tar`.

  Each method is VERIFIED before it is accepted. A method only counts as
  successful if the binary it produced actually reports the expected version:

        [warn] npm did not produce 2.0.29 (got '2.0.23'); trying the next method

  You can force one method instead of the chain:

      Windows : -Method npm
      mac/Linux: --method npm

  Valid methods: auto (default), direct, npm, bun, brew.


--------------------------------------------------------------------------------
WHAT THE INSTALLER DOES
--------------------------------------------------------------------------------
  1. Detects OS and CPU, including Rosetta on Apple Silicon, musl on Alpine,
     and selects a baseline build when the CPU has no AVX2.
  2. Resolves the newest 2.x and confirms it is published for your platform
     BEFORE installing anything. A bad pin fails early and cleanly.
  3. Audits the machine for existing OpenCode installs.
  4. Removes OpenCode 1.x (unless you pass -SkipUninstallV1 / --keep-legacy).
  5. Backs up an existing config to opencode.backup-<timestamp>/
  6. Installs the bundled config ADDITIVELY. Existing files are never
     overwritten and nothing is ever deleted, so your own opencode.jsonc,
     MCP servers, providers, agents\, commands\, skills\, permission rules and
     any stored data all survive untouched. Only missing files are added.
  7. Installs the binary by the first method that verifies.
  8. Removes a duplicate OpenCode, which would otherwise cause "Background
     service failed to start".
  9. Adds ~/.opencode/bin to PATH (direct method only - npm, bun and brew
     manage PATH themselves).
 10. Creates a desktop shortcut on Windows.
 11. Verifies the installed binary reports the expected version.

  If every method fails, the installer says so and stops:

        [FAIL] every install method failed
        [FAIL] tried: direct, npm, bun, brew
        [FAIL] if you are behind a proxy, set HTTPS_PROXY and re-run

  Nothing is left half-installed.


--------------------------------------------------------------------------------
YOUR EXISTING SETUP IS SAFE BY DEFAULT
--------------------------------------------------------------------------------
  By default the installer never overwrites and never deletes a file in your
  OpenCode config. Re-running it on a machine you already use adds only what
  is missing and prints:

      [ok]   added N file(s) that were missing
      [ok]   left your existing M file(s) untouched
      [info] your skills, agents, commands and stored data were not modified

  Preserved: MCP servers, providers, permission rules, agents, commands,
  skills, AGENTS.md, opencode.jsonc, session data.

  This is verified by SHA-256 comparison of seeded files before and after a
  test run, not by inspection.

  If you DO want the bundled copy to win - for example to reset a config you
  have broken - ask for it explicitly:

      Windows  : -ReplaceConfig
      mac/Linux: --replace-config

  That is the older, destructive behaviour (mirror the payload over the
  target, deleting anything the payload does not contain). A timestamped
  backup is taken first either way.

  To install the binary and nothing else, leaving the config completely alone:

      Windows  : -SkipConfig
      mac/Linux: --skip-config


--------------------------------------------------------------------------------
THE PAYLOAD IS EMPTY ON PURPOSE
--------------------------------------------------------------------------------
  It is three files. opencode.jsonc inside it contains only:

      "$schema": "https://opencode.ai/config.json",
      "lsp": true

  No providers. No MCP servers. No agents, commands, skills or permissions.
  No AGENTS.md. Nothing personal.

  That is deliberate. An installer that bundles MCP servers and providers has
  to either overwrite yours - breaking your setup - or skip them, leaving you
  half-configured. Shipping nothing avoids both.

  A fresh machine gets a clean baseline it fills in itself. An existing
  machine keeps every MCP server and every provider it already had.

  To add your own, edit your opencode.jsonc by hand. The installer will not
  overwrite it on any later run.

      Windows  : %USERPROFILE%\.config\opencode\opencode.jsonc
      mac/Linux: ~/.config/opencode/opencode.jsonc


--------------------------------------------------------------------------------
CREDENTIALS
--------------------------------------------------------------------------------
  None are shipped, and CI fails the build if a credential-shaped value
  appears anywhere in this repository.

  The bundled config has no providers and no MCP servers, so nothing in it
  needs a secret. When you add your own, keep the value out of the file by
  reading it through OpenCode's substitution:

      "headers": { "Authorization": "Bearer {env:GITHUB_TOKEN}" }

  or from a file:

      "apiKey": "{file:~/.secrets/provider-key}"

  The secret then lives outside the config, so the config itself stays safe
  to commit and safe to share.


--------------------------------------------------------------------------------
HOW "LATEST" IS RESOLVED
--------------------------------------------------------------------------------
  OpenCode 2.x publishes no GitHub Release assets - the GitHub "latest
  release" is still 1.18.x. So the version comes from OpenCode's own endpoint,
  the same one the upstream installer uses:

      https://opencode.ai/update/api/latest/cli/npm   ->  {"version":"2.0.29", ...}

  If that is unreachable, it falls back to the npm registry:

      https://registry.npmjs.org/@opencode%2Fcli/latest

  Three guards apply:
    1. the result must be 2.x, so a 1.x download is impossible
    2. it must exist for your specific target, checked before installing
    3. the installed binary must report exactly that version

  The binary itself comes from the per-target npm tarball, e.g.

      @opencode/cli-windows-x64    @opencode/cli-darwin-arm64
      @opencode/cli-linux-x64      @opencode/cli-linux-x64-musl

  That is deliberate. The CDN path opencode.ai/files/bin/ serves macOS and
  Windows builds but returns HTTP 404 for every linux-* asset, so it cannot
  be used on Linux. The npm tarballs cover all three systems.

  To pin an exact version instead:

      Windows  : -Version 2.0.29
      mac/Linux: --version 2.0.29


--------------------------------------------------------------------------------
UPGRADING LATER
--------------------------------------------------------------------------------
      Windows  : powershell -ExecutionPolicy Bypass -File "C:\opencode-v2-update\Upgrade-OpenCode.ps1"
      mac/Linux: ./Upgrade-OpenCode.sh

  To only report whether an update exists:

      ./Upgrade-OpenCode.sh --check

  It resolves the newest 2.x the same way, replaces the binary in place and
  re-verifies. It refuses to run against a 1.x install and tells you to run
  the installer instead, because 1.x and 2.x cannot upgrade into each other.

  Use the bundled script rather than the built-in `opencode upgrade`, because
  the built-in updater needs bash, which most Windows machines do not have.


--------------------------------------------------------------------------------
ALL OPTIONS
--------------------------------------------------------------------------------
  Windows - install.ps1
      (none)               install newest 2.x; additive config; removes 1.x
      -Latest              explicit "newest" (same as the default)
      -Version <x.y.z>     pin an exact version
      -Method <name>       auto | direct | npm | bun | brew   (default auto)
      -SkipConfig          binary only; do not touch the config
      -ReplaceConfig       opt in to the destructive mirror
      -SkipUninstallV1     leave OpenCode 1.x alone
      -Force               non-interactive; assume yes to every prompt

  macOS / Linux - install.sh
      (none)               install newest 2.x; additive config; removes 1.x
      -v, --version <x.y.z>  pin an exact version (leading v accepted)
      --method <name>      auto | direct | npm | bun | brew   (default auto)
      --skip-config        binary only
      --replace-config     opt in to the destructive mirror
      --keep-legacy        leave OpenCode 1.x alone
      --no-modify-path     do not edit .zshrc / .bashrc / .profile
      -h, --help           show help

  Environment: OPENCODE_INSTALL_DIR overrides the install directory.


--------------------------------------------------------------------------------
1.x VERSUS 2.x - HOW TO TELL THEM APART
--------------------------------------------------------------------------------
  Two different products that both register a command called `opencode`, so
  they overwrite each other. The identifiers differ in EVERY package manager,
  which is how a 1.x survives an attempted upgrade:

                        1.x                            2.x
    npm        npm install -g opencode-ai     npm install -g @opencode/cli
    bun        bun install -g opencode-ai     bun install -g --trust @opencode/cli
    brew       anomalyco/tap/opencode         anomalyco/tap/opencode-v2
    curl       https://opencode.ai/install   https://opencode.ai/v2/install
    latest     1.19.0                         2.0.29

  Note the brew formulae are genuinely different - `opencode` versus
  `opencode-v2` - so "remove the brew one" is ambiguous unless you know which
  major you are looking at.

  To check what is installed:

      opencode --version
      npm ls -g --depth=0
      brew list --formula | grep opencode
      bun pm ls -g

  This installer removes 1.x by default, and checks ALL FOUR vectors - npm,
  bun, brew and a manual binary in ~/.opencode/bin. Removal is always keyed to
  the 1.x identifier, so a 2.x install can never be removed by mistake. A
  manual 1.x binary is quarantined (moved aside with a timestamp), never
  deleted.

  Opt out with -SkipUninstallV1 / --keep-legacy if you need 1.x to stay - but
  be aware the two will conflict.


--------------------------------------------------------------------------------
WHERE THINGS GO
--------------------------------------------------------------------------------
                        Windows                      macOS / Linux
  binary                %USERPROFILE%\.opencode\     ~/.opencode/bin/
                        bin\opencode.exe             opencode
  config                %USERPROFILE%\.config\      ~/.config/opencode/
                        opencode\
  config backup         …\.config\                   ~/.config/
                        opencode.backup-<stamp>\     opencode.backup-<stamp>/
  PATH                  User PATH                    .zshrc / .bashrc /
                                                    .profile
  shortcut              OpenCode.lnk (Windows        -
                        Terminal)

  service.json is NOT shipped - it holds a machine-specific port and password,
  and OpenCode generates its own.


--------------------------------------------------------------------------------
TROUBLESHOOTING
--------------------------------------------------------------------------------
  "Background service failed to start"
      Two OpenCode installs competing for the background service port (4096).
      Run the installer - it removes the duplicate. To check by hand:

          Windows  : Get-NetTCPConnection -LocalPort 4096 -State Listen
          mac/Linux: lsof -i :4096

  `opencode` is not recognised
      The PATH entry only reaches NEW processes. Close every terminal and
      reopen one, then check:

          Windows  : where.exe opencode
          mac/Linux: command -v opencode

      Windows Explorer may also need a restart to refresh icons.

  "npm not found - skipping @opencode-ai/plugin"
      Not fatal. Only means TUI plugins will not load; OpenCode itself works.
      Node.js from https://nodejs.org fixes it.

  "every install method failed"
      Usually a proxy or a blocked CDN. Set HTTPS_PROXY and re-run, or
      install through a package manager yourself:

          npm  install -g @opencode/cli
          bun  install -g --trust @opencode/cli
          brew install anomalyco/tap/opencode-v2

  Free models return "OpenCode's free tier can only be used from within
  OpenCode"
      An authentication problem, not an install problem:

          opencode auth login

      Or use a different provider in your opencode.jsonc.

  "version X is not published for <target>"
      The registry advertised a version the CDN has not published yet.
      Transient. Re-run later, or pin a known-good version.

  Antivirus flagged the download
      The binary is fetched over plain HTTPS and is NOT code-signed, so
      heuristic scanners sometimes flag it. Check it runs, then add an
      exclusion if your AV insists:

          ~/.opencode/bin/opencode --version

  A file will not delete
      An opencode process is still holding it. Close every open OpenCode
      window first, then re-run.

================================================================================
  More detail: docs/troubleshooting.md   Full project: github.com/<you>/opencode-v2-update
  MIT licensed. OpenCode itself is licensed separately by its authors.
================================================================================