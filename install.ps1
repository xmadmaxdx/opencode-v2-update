<#
.SYNOPSIS
    Installs OpenCode 2.x plus your personal config onto a Windows PC.

.DESCRIPTION
    Self-contained installer. Requires internet. Does NOT require Node.js or npm.

    What it does, in order:
      1. Preflight        - PowerShell version, admin warning, internet, CPU arch
      2. Audit            - find every existing OpenCode install (1.x and/or 2.x)
      3. Remove 1.x       - uninstall the legacy `opencode-ai` package, quarantine
                            any legacy binary, never hard-delete
      4. Backup config    - copy the target's existing ~/.config/opencode to a
                            timestamped sibling folder
      5. Install config   - overwrite ~/.config/opencode with the bundled payload
      6. Install binary   - download opencode.ai/files/bin/<ver>/opencode-windows-<arch>.zip
                            and place the exe in %USERPROFILE%\.opencode\bin
      7. PATH             - add %USERPROFILE%\.opencode\bin to the User PATH (idempotent)
      8. Desktop shortcut - "OpenCode.lnk" launching Windows Terminal
      9. Verify           - assert the installed binary reports major version 2

.PARAMETER Version
    OpenCode version to install. Omit to resolve the newest 2.x automatically.

.PARAMETER Latest
    Resolve the newest 2.x from the npm registry at run time. This is the
    default when -Version is omitted, so a plain run is always up to date.

.PARAMETER Force
    Non-interactive. Assume yes to every prompt and stop running OpenCode
    processes automatically. Use for automated / unattended runs.

.PARAMETER SkipUninstallV1
    Leave any detected 1.x install completely alone.

.PARAMETER SkipConfig
    Install only the binary. Do not touch the target's config folder.

.PARAMETER ReplaceConfig
    Overwrite the target's config with the bundled copy. WITHOUT this flag the
    installer is additive only: existing files are never modified or deleted,
    so your own opencode.jsonc, agents\, commands\, skills\ and any stored data
    are left exactly as they are. Only files that do not already exist are
    added. This is the default because clobbering a working setup is far more
    damaging than shipping a stale default file.

.PARAMETER Method
    Which install method to use: auto, direct, npm, bun or brew. 'auto' (the
    default) tries the per-target npm tarball first and falls back to npm, bun
    and brew until one produces a binary that reports the expected version.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\opencode-v2-update\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\opencode-v2-update\install.ps1 -Version 2.0.29 -Force

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\opencode-v2-update\install.ps1 -Method npm
#>
[CmdletBinding()]
param(
    [string] $Version = '',
    [switch] $Latest,
    [switch] $Force,
    [switch] $SkipUninstallV1,
    [switch] $SkipConfig,
    [switch] $ReplaceConfig,
    [ValidateSet('auto','direct','npm','bun','brew')]
    [string] $Method = 'auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is far faster without it

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:LegacyNpmPkg    = 'opencode-ai'      # OpenCode 1.x  (npm + bun)
$script:ModernNpmPkg    = '@opencode/cli'    # OpenCode 2.x  (npm + bun)
$script:LegacyBrewFormula = 'opencode'        # OpenCode 1.x  (anomalyco/tap/opencode)
$script:ModernBrewFormula = 'opencode-v2'     # OpenCode 2.x  (anomalyco/tap/opencode-v2)
$script:InstallDirName  = '.opencode\bin'
$script:BackupStamp     = (Get-Date -Format 'yyyyMMdd-HHmmss')
$script:InstalledVia    = $null              # set to direct|npm|bun|brew once installed
$script:ActiveBinary    = $null              # resolved by Invoke-Verify

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ok]   $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    [info] $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "    [warn] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }

function Confirm-Step {
    param([string]$Question)
    if ($Force) { return $true }
    $answer = Read-Host "    $Question [y/N]"
    return ($answer -match '^(y|yes)$')
}

function Invoke-Native {
    <#
      Runs a native command and returns its exit code and merged output.

      This wrapper exists because $ErrorActionPreference is 'Stop' for the whole
      script, and under that setting PowerShell promotes ANY line a native tool
      writes to stderr into a terminating error. Without this, a routine npm
      warning such as "npm warn EBADENGINE" would abort the installation, and
      `where.exe opencode` would throw whenever opencode is not installed.
    #>
    param(
        [Parameter(Mandatory)] [string]   $FilePath,
        [string[]] $Arguments = @(),
        [string]   $WorkingDirectory
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pushed = $false
    try {
        if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            Push-Location -LiteralPath $WorkingDirectory -ErrorAction Stop
            $pushed = $true
        }
        $output = & $FilePath @Arguments 2>&1
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output | Out-String)
        }
    } finally {
        if ($pushed) { Pop-Location }
        $ErrorActionPreference = $previous
    }
}

function Install-BinaryFile {
    <#
      Copies the new binary into place, retrying once after stopping OpenCode if
      the destination turns out to be locked.

      Checking for a running process BEFORE copying is wrong: any OpenCode
      process on the machine would block the install, including one launched from
      a completely different install that does not hold this file. Attempting the
      copy first is precise - it only intervenes when the file is genuinely busy.
    #>
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )
    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        return
    } catch {
        $running = @(Get-Process -Name 'opencode' -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) { throw }
        Write-Info "the file is in use; stopping $($running.Count) OpenCode process(es) and retrying"
        foreach ($p in $running) {
            try { $p | Stop-Process -Force -ErrorAction Stop } catch { Write-Warn "could not stop PID $($p.Id)" }
        }
        Start-Sleep -Milliseconds 900
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Resolve-ScratchDir {
    <#
      Picks a temporary folder that is actually present and writable.

      $env:TEMP is not trustworthy on its own: on some machines it points at an
      8.3 short path such as C:\Users\CW SYL~1, and Remove-Item -Recurse over a
      short path fails with "An object at the specified path ... does not exist".
    #>
    $candidates = @()
    try { $candidates += [System.IO.Path]::GetTempPath() } catch { }
    if ($env:TEMP)          { $candidates += $env:TEMP }
    if ($env:TMP)           { $candidates += $env:TMP }
    $candidates += (Join-Path $env:USERPROFILE 'AppData\Local\Temp')

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
            $probe = Join-Path $candidate "oc-write-probe-$script:BackupStamp"
            New-Item -ItemType Directory -Path $probe -Force -ErrorAction Stop | Out-Null
            Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction Stop
            return $candidate
        } catch { }
    }
    throw 'No writable temporary folder could be found on this PC.'
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
function Test-Elevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'x86'   { return 'x64' }   # 32-bit PowerShell on 64-bit OS
        default {
            if ([Environment]::Is64BitOperatingSystem) { return 'x64' }
            throw "Unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE"
        }
    }
}

function Test-Internet {
    param([string]$Host_ = 'opencode.ai')
    try {
        $null = Invoke-WebRequest -Uri "https://$Host_" -Method Head -TimeoutSec 15 -UseBasicParsing
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$script:UserProfile    = $env:USERPROFILE
$script:InstallDir     = Join-Path $script:UserProfile $script:InstallDirName
$script:ExePath        = Join-Path $script:InstallDir 'opencode.exe'
$script:ConfigDir      = Join-Path $script:UserProfile '.config\opencode'
$script:PayloadDir     = Join-Path $PSScriptRoot 'payload\config'
$script:DesktopLnk     = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OpenCode.lnk'
$script:ScratchRoot    = $null   # resolved during preflight
$script:DownloadDir    = $null   # resolved during preflight

# ---------------------------------------------------------------------------
# Audit helpers
# ---------------------------------------------------------------------------
function Get-NpmGlobalPackages {
    # Returns a hashtable of globally-installed npm package name -> version, or $null.
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) { return $null }
    $result = Invoke-Native -FilePath $npm.Source -Arguments @('ls','-g','--depth=0','--json')
    if ($result.ExitCode -ne 0 -and -not $result.Output.Trim()) { return @{} }
    try {
        $parsed = $result.Output | ConvertFrom-Json
        $map = @{}
        if ($parsed.dependencies) {
            foreach ($prop in $parsed.dependencies.PSObject.Properties) {
                $map[$prop.Name] = $prop.Value.version
            }
        }
        return $map
    } catch {
        Write-Warn "Could not parse the npm global list: $($_.Exception.Message)"
        return $null
    }
}

function Get-BinaryVersion {
    # Runs <exe> --version and returns e.g. '2.0.26', or $null if not runnable.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $result = Invoke-Native -FilePath $Path -Arguments @('--version')
    if ($result.Output -match 'v(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-PATHShimHits {
    # which opencode resolvable right now, via the current process PATH.
    $hits = @()
    $where = Get-Command where.exe -ErrorAction SilentlyContinue
    if (-not $where) { return $hits }
    $result = Invoke-Native -FilePath $where.Source -Arguments @('opencode')
    foreach ($line in ($result.Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed) { $hits += $trimmed }
    }
    return $hits
}

function Get-StrayBinaries {
    <#
      opencode*.exe files that are neither the canonical install nor an npm
      shim - i.e. copies someone dropped into a folder by hand. Those are the
      ones that silently shadow a real install.

      Two sources are combined: whatever resolves on PATH, plus the handful of
      folders people actually unzip into. A hand-placed copy that has been
      dropped from PATH still cannot shadow anything, but it is worth naming so
      the user can delete it deliberately rather than wonder where it went.
    #>
    $candidates = @()

    foreach ($hit in @(Get-PATHShimHits)) {
        if ($hit.ToLower().EndsWith('.exe')) { $candidates += $hit }
    }

    $known = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\opencode\opencode.exe'),
        (Join-Path $env:LOCALAPPDATA 'opencode\opencode.exe'),
        (Join-Path $env:ProgramFiles 'opencode\opencode.exe')
    )
    foreach ($k in $known) { if (Test-Path -LiteralPath $k) { $candidates += $k } }

    $stray  = @()
    $seen   = @{}
    foreach ($path in $candidates) {
        if ($seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        if ($path -ieq $script:ExePath) { continue }
        if ($path -like "$env:APPDATA\npm\*") { continue }
        $stray += [PSCustomObject]@{
            Path     = $path
            Version  = (Get-BinaryVersion -Path $path)
            OnPath   = (@(Get-PATHShimHits) -contains $path)
        }
    }
    return $stray
}

function Get-Audit {
    <#
      Returns a PSCustomObject describing what is currently installed.
    #>
    $npmPkgs = Get-NpmGlobalPackages
    $manualV  = Get-BinaryVersion -Path $script:ExePath

    $legacyNpm = $null
    $modernNpm = $null
    if ($null -ne $npmPkgs) {
        if ($npmPkgs.ContainsKey($script:LegacyNpmPkg)) { $legacyNpm = $npmPkgs[$script:LegacyNpmPkg] }
        if ($npmPkgs.ContainsKey($script:ModernNpmPkg)) { $modernNpm = $npmPkgs[$script:ModernNpmPkg] }
    }

    return [PSCustomObject]@{
        LegacyNpmVersion   = $legacyNpm
        ModernNpmVersion   = $modernNpm
        ManualBinaryVersion = $manualV
        PathShims          = @(Get-PATHShimHits)
        StrayBinaries      = @(Get-StrayBinaries)
        HasDesktopShortcut = (Test-Path -LiteralPath $script:DesktopLnk)
    }
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
function Invoke-Preflight {
    Write-Step 'Preflight'

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5.1 or newer is required (found $($PSVersionTable.PSVersion))."
    }
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

    if (Test-Elevated) {
        Write-Warn 'Running elevated. User-scope PATH and config writes will target the'
        Write-Warn 'administrator account, not the logged-in user. Prefer a normal shell.'
    }

    $arch = Get-TargetArch
    Write-Ok "CPU architecture: $arch"

    if (-not (Test-Internet)) {
        throw 'No internet connection to opencode.ai. This installer downloads the binary.'
    }
    Write-Ok 'Internet reachable (opencode.ai)'

    if (-not (Test-Path -LiteralPath $script:PayloadDir)) {
        throw "Payload folder missing: $($script:PayloadDir). Re-extract the whole zip."
    }
    Write-Ok "Payload found: $($script:PayloadDir)"

    $script:ScratchRoot = Resolve-ScratchDir
    $script:DownloadDir = Join-Path $script:ScratchRoot "opencode-install-$script:BackupStamp"
    Write-Ok "Scratch folder: $($script:DownloadDir)"
}

function Invoke-Audit {
    Write-Step 'Auditing existing OpenCode installs'
    $audit = Get-Audit

    if ($audit.LegacyNpmVersion) {
        Write-Info "1.x npm package : $($script:LegacyNpmPkg)@$($audit.LegacyNpmVersion)"
    }
    if ($audit.ModernNpmVersion) {
        Write-Info "2.x npm package : $($script:ModernNpmPkg)@$($audit.ModernNpmVersion)"
    }
    if ($audit.ManualBinaryVersion) {
        $major = ($audit.ManualBinaryVersion -split '\.')[0]
        $tag   = if ($major -eq '1') { '  <-- LEGACY 1.x' } else { '' }
        Write-Info "binary at \$USERPROFILE\$InstallDirName : v$($audit.ManualBinaryVersion)$tag"
    }
    if ($audit.PathShims.Count -gt 0) {
        foreach ($s in $audit.PathShims) { Write-Info "on PATH: $s" }
    }
    foreach ($s in $audit.StrayBinaries) {
        $shown = if ($s.Version) { "v$($s.Version)" } else { 'version unreadable' }
        $where = if ($s.OnPath) { 'ON PATH - can shadow other installs' } else { 'not on PATH - harmless but stale' }
        Write-Warn "hand-placed binary: $shown  ($where)"
        Write-Host "           $($s.Path)" -ForegroundColor DarkGray
    }
    if ($audit.HasDesktopShortcut) {
        Write-Info 'desktop shortcut: OpenCode.lnk (will be refreshed)'
    }

    $anything = $audit.LegacyNpmVersion -or $audit.ModernNpmVersion -or $audit.ManualBinaryVersion `
                -or ($audit.PathShims.Count -gt 0) -or ($audit.StrayBinaries.Count -gt 0)
    if (-not $anything) { Write-Ok 'No existing OpenCode install found. Clean machine.' }

    return $audit
}

function Invoke-RemoveLegacy {
    param($Audit)

    if ($SkipUninstallV1) {
        Write-Step 'Skipping 1.x removal (-SkipUninstallV1)'
        return
    }

    $needsNpm    = [bool]$Audit.LegacyNpmVersion
    $manualIsV1  = $false
    if ($Audit.ManualBinaryVersion) {
        $manualIsV1 = (($Audit.ManualBinaryVersion -split '\.')[0] -eq '1')
    }

    # Hand-placed 1.x exes: on PATH, but neither the canonical install nor an npm shim.
    $strayLegacy = @($Audit.StrayBinaries | Where-Object {
        $_.Version -and (($_.Version -split '\.')[0] -eq '1')
    })
    if (-not $needsNpm -and -not $manualIsV1 -and $strayLegacy.Count -eq 0) {
        Write-Step 'No 1.x install to remove'
        return
    }

    Write-Step 'Removing legacy 1.x install'
    if ($needsNpm)    { Write-Info "found $($script:LegacyNpmPkg)@$($Audit.LegacyNpmVersion)" }
    if ($manualIsV1)  { Write-Info "found legacy binary v$($Audit.ManualBinaryVersion) in $script:InstallDir" }
    foreach ($s in $strayLegacy) { Write-Info "found hand-placed 1.x v$($s.Version) at $($s.Path)" }

    if (-not (Confirm-Step 'Remove the 1.x install? (1.x and 2.x share the same `opencode` command)')) {
        Write-Warn 'Left 1.x in place. It will shadow the 2.x binary because both register as `opencode`.'
        return
    }

    # A file can only be moved if nothing holds it open. Stop ONLY the process
    # running the exact binary we are about to quarantine.
    #
    # This deliberately does not kill every `opencode` process on the machine.
    # That would kill the user's live session - including the very client that
    # launched this installer - and it is unnecessary on the npm path, where
    # npm manages its own files and no lock needs clearing.
    if ($manualIsV1) {
        $holder = $null
        foreach ($proc in @(Get-Process -Name 'opencode' -ErrorAction SilentlyContinue)) {
            try {
                if ($proc.Path -and ($proc.Path -ieq $script:ExePath)) { $holder = $proc; break }
            } catch {
                # Reading .Path can be denied for processes we do not own.
            }
        }
        if ($holder) {
            Write-Info "stopping PID $($holder.Id), which is running the 1.x binary"
            try {
                $holder | Stop-Process -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 800
            } catch {
                Write-Warn "could not stop PID $($holder.Id): $($_.Exception.Message)"
                Write-Warn "close it by hand, then re-run"
            }
        } else {
            Write-Info 'no running process holds the 1.x binary'
        }
    }

    if ($needsNpm) {
        $npm = Get-Command npm -ErrorAction SilentlyContinue
        if (-not $npm) {
            Write-Warn "npm not found; remove 1.x by hand with:  npm uninstall -g $($script:LegacyNpmPkg)"
        } else {
            $result = Invoke-Native -FilePath $npm.Source -Arguments @('uninstall','-g',$script:LegacyNpmPkg)
            if ($result.ExitCode -eq 0) {
                Write-Ok "uninstalled $($script:LegacyNpmPkg)"
            } else {
                Write-Warn "npm uninstall exited $($result.ExitCode)"
                Write-Warn "remove it manually with:  npm uninstall -g $($script:LegacyNpmPkg)"
            }
        }
    }

    # bun. 1.x and 2.x differ only by package name here: opencode-ai vs
    # @opencode/cli, so removing the 1.x name can never touch a 2.x install.
    $bun = Get-Command bun -ErrorAction SilentlyContinue
    if ($bun) {
        $bunLs = Invoke-Native -FilePath $bun.Source -Arguments @('pm','ls','-g')
        if ($bunLs.Output -match [regex]::Escape('"' + $script:LegacyNpmPkg + '"')) {
            Write-Info "found $($script:LegacyNpmPkg) installed via bun"
            $r = Invoke-Native -FilePath $bun.Source -Arguments @('remove','-g',$script:LegacyNpmPkg)
            if ($r.ExitCode -ne 0) {
                $r = Invoke-Native -FilePath $bun.Source -Arguments @('uninstall','-g',$script:LegacyNpmPkg)
            }
            if ($r.ExitCode -eq 0) { Write-Ok "removed bun package $($script:LegacyNpmPkg)" }
            else { Write-Warn "remove it manually with:  bun remove -g $($script:LegacyNpmPkg)" }
        }
    }

    # brew. The 1.x formula is `opencode`; the 2.x one is `opencode-v2`, so
    # removing by formula name can never touch a 2.x brew install.
    $brew = Get-Command brew -ErrorAction SilentlyContinue
    if ($brew) {
        $brewList = Invoke-Native -FilePath $brew.Source -Arguments @('list','--formula')
        if (($brewList.Output -split "`r?`n") -contains $script:LegacyBrewFormula) {
            Write-Info "found brew formula $($script:LegacyBrewFormula) (1.x)"
            $r = Invoke-Native -FilePath $brew.Source -Arguments @('uninstall',$script:LegacyBrewFormula)
            if ($r.ExitCode -eq 0) { Write-Ok "removed brew formula $($script:LegacyBrewFormula)" }
            else { Write-Warn "remove it manually with:  brew uninstall $($script:LegacyBrewFormula)" }
        }
    }

    if ($manualIsV1) {
        # Quarantine, never hard-delete.
        $grave = Join-Path $script:InstallDir "opencode-1x-$script:BackupStamp.exe"
        try {
            Move-Item -LiteralPath $script:ExePath -Destination $grave -Force
            Write-Ok "quarantined legacy binary -> $grave"
        } catch {
            Write-Warn "could not quarantine legacy binary: $($_.Exception.Message)"
        }
    }

    foreach ($s in $strayLegacy) {
        # Renamed in place: the folder may still be on PATH, but `opencode`
        # will no longer resolve there.
        $dir      = Split-Path $s.Path -Parent
        $ext      = [IO.Path]::GetExtension($s.Path)
        $stem     = [IO.Path]::GetFileNameWithoutExtension($s.Path)
        $newName  = "$stem-1x-$script:BackupStamp$ext"
        $grave    = Join-Path $dir $newName
        try {
            Rename-Item -LiteralPath $s.Path -NewName $newName -Force
            Write-Ok "quarantined legacy binary -> $grave"
        } catch {
            Write-Warn "could not quarantine $($s.Path): $($_.Exception.Message)"
        }
    }
}

function Invoke-BackupConfig {
    Write-Step 'Backing up existing config'
    if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
        Write-Ok 'No existing config on this PC. Nothing to back up.'
        return
    }
    $backup = Join-Path (Split-Path $script:ConfigDir -Parent) "opencode.backup-$script:BackupStamp"
    try {
        Copy-Item -LiteralPath $script:ConfigDir -Destination $backup -Recurse -Force
        Write-Ok "backed up to $backup"
    } catch {
        throw "Could not back up the existing config: $($_.Exception.Message). Aborting so nothing is lost."
    }
}

function Invoke-InstallConfig {
    Write-Step 'Installing your config'

    $preExisting = Test-Path -LiteralPath $script:ConfigDir
    $excluded = 'node_modules', '__pycache__'
    $payloadFiles = @(Get-ChildItem $script:PayloadDir -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' -and $_.FullName -notmatch '\\__pycache__\\' })

    if ($ReplaceConfig) {
        Write-Warn '-ReplaceConfig given: the bundled config will overwrite existing files.'
        try {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
            # /MIR makes the target an exact copy of the payload, which DELETES
            # anything the payload does not contain. Only reachable via the
            # explicit -ReplaceConfig opt-in.
            & robocopy $script:PayloadDir $script:ConfigDir /MIR /XD $excluded /NFL /NDL /NJH /NJS /NP | Out-Null
            $rc = $LASTEXITCODE
            if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
            Write-Ok "config replaced at $script:ConfigDir"
        } catch {
            throw "Failed to install config: $($_.Exception.Message)"
        }
    } else {
        # Default: additive only. An existing file is never overwritten and
        # nothing is ever deleted, so a working setup survives untouched.
        try {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        } catch {
            throw "Failed to create $script:ConfigDir : $($_.Exception.Message)"
        }
        $added = 0
        $kept  = 0
        foreach ($pf in $payloadFiles) {
            $rel  = $pf.FullName.Substring($script:PayloadDir.Length).TrimStart('\')
            $dest = Join-Path $script:ConfigDir $rel
            if (Test-Path -LiteralPath $dest) { $kept++; continue }
            $parent = Split-Path $dest -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $pf.FullName -Destination $dest -Force
            $added++
        }
        Write-Ok "added $added file(s) that were missing"
        if ($kept -gt 0) {
            Write-Ok "left your existing $kept file(s) untouched"
        }
        if ($preExisting) {
            Write-Info 'your skills, agents, commands and stored data were not modified'
            Write-Info 'pass -ReplaceConfig only if you really want the bundled copy to win'
        }
    }

    # The bundled package.json declares @opencode-ai/plugin. Install it only when
    # npm exists; the CLI runs fine without it, it only disables plugin support.
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Info 'installing @opencode-ai/plugin (optional, enables TUI plugins)'
        $npm = (Get-Command npm).Source
        $result = Invoke-Native -FilePath $npm -Arguments @('install','--no-audit','--no-fund') -WorkingDirectory $script:ConfigDir
        if ($result.ExitCode -eq 0) {
            Write-Ok 'plugin dependency installed'
        } else {
            Write-Warn "npm install exited $($result.ExitCode); TUI plugins may be unavailable."
            foreach ($line in ($result.Output -split "`r?`n" | Where-Object { $_ -match 'npm (warn|err)' } | Select-Object -First 4)) {
                Write-Host "           $line" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Warn 'npm not found - skipping @opencode-ai/plugin. TUI plugins will not load.'
    }
}

function Get-LatestV2 {
    # Prefer OpenCode's own update endpoint (the same one the upstream
    # installer uses), then fall back to the npm registry. Guarded so a wrong
    # or absent major version can never resolve to a 1.x download.
    try {
        $body = Invoke-RestMethod -Uri 'https://opencode.ai/update/api/latest/cli/npm' -TimeoutSec 30 -UseBasicParsing
        if ($body.version -and $body.version -match '^2\.(\d+\.\d+)$') { return $body.version }
        if ($body.version) { Write-Warn "update endpoint returned '$($body.version)', which is not 2.x." }
    } catch {
        Write-Warn "update endpoint unreachable, trying the npm registry."
    }
    try {
        $j = Invoke-RestMethod -Uri 'https://registry.npmjs.org/@opencode%2Fcli/latest' -TimeoutSec 30 -UseBasicParsing
        if ($j.version -and $j.version -match '^2\.(\d+\.\d+)$') { return $j.version }
        Write-Warn "registry returned '$($j.version)', which is not a 2.x version."
    } catch {
        Write-Warn "could not read the latest version: $($_.Exception.Message)"
    }
    return $null
}

function Get-PackageScope {
    # Older clients published the per-target builds under @opencode-ai.
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Version)

    $code = (Invoke-WebRequest -Uri "https://registry.npmjs.org/@opencode%2Fcli-$Target/$Version" `
                                -Method Head -TimeoutSec 30 -UseBasicParsing).StatusCode
    if ($code -eq 200) { return '@opencode' }

    $code = (Invoke-WebRequest -Uri "https://registry.npmjs.org/@opencode-ai%2Fcli-$Target/$Version" `
                                -Method Head -TimeoutSec 30 -UseBasicParsing).StatusCode
    if ($code -eq 200) { return '@opencode-ai' }

    throw "version $Version is not published for windows-$Target"
}

function Assert-VersionAvailable {
    # Confirms the per-target npm tarball exists before anything is installed
    # or any PATH entry is touched, so a bad pin fails early instead of leaving
    # a half-installed machine behind.
    param([Parameter(Mandatory)][string]$Arch, [Parameter(Mandatory)][string]$Version)

    try {
        $scope = Get-PackageScope -Target "windows-$Arch" -Version $Version
    } catch {
        throw "version $Version is not available for windows-$Arch. Pass -Version with a version that exists."
    }
    Write-Ok "$Version is published for windows-$Arch (scope $scope)"
    return $scope
}

function Resolve-InstallVersion {
    # -Version wins if given. Otherwise resolve newest 2.x, falling back to
    # whatever is already installed so a re-run without network still works.
    if ($Version -and -not $Latest) {
        Write-Ok "using requested version $Version"
        return $Version
    }

    if ($Latest -or -not $Version) {
        Write-Info 'looking up the newest 2.x release'
        $resolved = Get-LatestV2
        if ($resolved) {
            Write-Ok "resolved latest: $resolved"
            return $resolved
        }
        $fallback = Get-BinaryVersion -Path $script:ExePath
        if ($fallback) {
            Write-Warn "falling back to the already-installed $fallback"
            return $fallback
        }
        throw 'Could not determine the latest version and none is installed. Re-run with -Version <x.y.z>.'
    }
    return $Version
}

function Invoke-InstallBinary {
    Write-Step "Installing OpenCode $Version"

    # Idempotent: a re-run after a partial failure must not re-download ~95 MB.
    $existing = Get-BinaryVersion -Path $script:ExePath
    if ($existing -eq $Version) {
        Write-Ok "already installed at $Version - skipping the download"
        return
    }
    if ($existing) { Write-Info "replacing $existing with $Version" }

    $arch = Get-TargetArch
    $target = "windows-$arch"
    $pkg = "cli-$target"

    try {
        $scope = Get-PackageScope -Target $target -Version $Version
    } catch {
        throw "version $Version is not published for $target. Pass -Version with a version that exists."
    }

    $url = "https://registry.npmjs.org/$scope/$pkg/-/$pkg-$Version.tgz"
    Write-Info "downloading $scope/$pkg"

    New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
    $tgz = Join-Path $script:DownloadDir "$pkg-$Version.tgz"

    try {
        try {
            Invoke-WebRequest -Uri $url -OutFile $tgz -UseBasicParsing -TimeoutSec 900
        } catch {
            throw "Could not download $url : $($_.Exception.Message)"
        }

        $info = Get-Item -LiteralPath $tgz
        if ($info.Length -lt 1MB) {
            throw "Downloaded archive is only $($info.Length) bytes - not a real OpenCode build."
        }
        Write-Ok ("downloaded {0:N1} MB" -f ($info.Length / 1MB))

        # .tar.gz. Windows 10+ ships bsdtar as tar.exe, so no extra tooling is
        # needed; the npm CLI on PATH would also work as a fallback.
        $extract = Join-Path $script:DownloadDir 'extracted'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        if ($tar) {
            $r = Invoke-Native -FilePath $tar.Source -Arguments @('-xzf', $tgz, '-C', $extract)
            if ($r.ExitCode -ne 0) { throw "tar failed to unpack the archive: $($r.Output)" }
        } else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            throw "tar.exe is unavailable - install it, or run with -Method npm"
        }

        $exe = Join-Path $extract 'package\bin\opencode.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            throw "The archive did not contain package\bin\opencode.exe"
        }

        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
        Install-BinaryFile -Source $exe -Destination $script:ExePath
        Write-Ok "installed to $script:ExePath"
    } finally {
        try {
            if (Test-Path -LiteralPath $script:DownloadDir) {
                Remove-Item -LiteralPath $script:DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warn "could not remove the scratch folder: $($_.Exception.Message)"
            Write-Warn "harmless - delete it by hand: $script:DownloadDir"
        }
    }
}

function Invoke-InstallViaPackageManager {
    param([Parameter(Mandatory)][ValidateSet('npm','bun','brew')][string]$Method)

    if ($Method -eq 'npm') {
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Write-Info 'npm not installed'; return $false }
        Write-Info 'installing with npm'
        $r = Invoke-Native -FilePath (Get-Command npm).Source -Arguments @('install','-g','@opencode/cli')
        if ($r.ExitCode -ne 0) { Write-Warn "npm install exited $($r.ExitCode)"; return $false }
    }
    elseif ($Method -eq 'bun') {
        if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Write-Info 'bun not installed'; return $false }
        Write-Info 'installing with bun'
        $r = Invoke-Native -FilePath (Get-Command bun).Source -Arguments @('install','-g','--trust','@opencode/cli')
        if ($r.ExitCode -ne 0) { Write-Warn "bun install exited $($r.ExitCode)"; return $false }
    }
    else {
        if (-not (Get-Command brew -ErrorAction SilentlyContinue)) { Write-Info 'brew not installed (Windows)'; return $false }
        Write-Info 'installing with brew'
        $r = Invoke-Native -FilePath (Get-Command brew).Source -Arguments @('install','anomalyco/tap/opencode-v2')
        if ($r.ExitCode -ne 0) { Write-Warn "brew install exited $($r.ExitCode)"; return $false }
    }

    # Confirm the package manager really produced a usable binary before
    # declaring success.
    $shim = Join-Path $env:APPDATA 'npm\opencode.cmd'
    if (Test-Path -LiteralPath $shim) {
        $reported = Get-BinaryVersion -Path $shim
        if ($reported) {
            Write-Ok "installed via $Method (reports $reported)"
            $script:InstalledVia = $Method
            return $true
        }
        Write-Warn "$Method installed but the binary did not report a version"
        return $false
    }
    Write-Warn "$Method finished but no opencode command was found"
    return $false
}

function Invoke-InstallBinaryWithFallback {
    # Tries the direct tarball first, then npm, bun and brew. Each method is
    # only accepted once the produced binary reports the expected version.
    $order = if ($script:Method -eq 'auto') { @('direct','npm','bun','brew') } else { @($script:Method) }

    foreach ($m in $order) {
        Write-Info "--- method: $m ---"
        $succeeded = $false
        switch ($m) {
            'direct' {
                try {
                    Invoke-InstallBinary
                    $script:InstalledVia = 'direct'
                    $succeeded = $true
                } catch {
                    $script:InstalledVia = $null
                    Write-Warn "direct install failed: $($_.Exception.Message)"
                }
            }
            default { $succeeded = Invoke-InstallViaPackageManager -Method $m }
        }

        if ($succeeded) {
            $exe = if ($script:InstalledVia -and $script:InstalledVia -ne 'direct') {
                Join-Path $env:APPDATA "npm\opencode.cmd"
            } else { $script:ExePath }

            $reported = Get-BinaryVersion -Path $exe
            if ($reported -eq $Version) {
                Write-Ok "$($script:InstalledVia) install verified at $reported"
                return $true
            }
            Write-Warn "$m did not produce $Version (got '$reported'); trying the next method"
        }

        if ($script:Method -ne 'auto') {
            throw "method '$m' failed"
        }
    }

    throw 'every install method failed (tried: direct, npm, bun, brew). If you are behind a proxy, set HTTPS_PROXY and re-run.'
}

function Invoke-RemoveNpmShim {
    # Two installs that both register an `opencode` command will fight over the
    # background service port, producing "Background service failed to start".
    # Never remove the copy this run just installed.
    Write-Step 'Checking for a competing npm install'

    $keep = if ($script:InstalledVia -eq 'direct') { $script:ModernNpmPkg } else { $null }

    $pkgs = Get-NpmGlobalPackages
    if ($null -eq $pkgs) {
        Write-Info 'npm not found - nothing to clean up'
        return
    }

    # Never remove the package that produced the running install. Only the
    # other 2.x copy (a duplicate) and 1.x are candidates for removal.
    $present = @()
    if ($keep) {
        $present += @($script:LegacyNpmPkg | Where-Object { $pkgs.ContainsKey($_) })
    } else {
        $present += @($script:ModernNpmPkg | Where-Object { $pkgs.ContainsKey($_) })
        $present += @($script:LegacyNpmPkg  | Where-Object { $pkgs.ContainsKey($_) })
    }
    if (-not $present) {
        if ($keep) {
            Write-Ok 'no OpenCode 1.x installed - nothing to remove'
        } else {
            Write-Ok 'no competing npm OpenCode package - single install confirmed'
        }
        return
    }

    foreach ($p in $present) {
        Write-Warn "removing $p@$($pkgs[$p]) - it would shadow this install and cause a port conflict"
    }

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    $r = Invoke-Native -FilePath $npm.Source -Arguments (@('uninstall','-g') + $present)
    if ($r.ExitCode -ne 0) {
        Write-Warn "npm uninstall exited $($r.ExitCode)"
        Write-Warn "remove it manually with:  npm uninstall -g $($present -join ' ')"
        return
    }
    Write-Ok 'removed the npm OpenCode package(s)'

    $shim = Join-Path $env:APPDATA 'npm\opencode.cmd'
    if (Test-Path -LiteralPath $shim) {
        Write-Warn "a stale shim is still at $shim - delete it by hand, then reopen terminals."
    }
}

function Invoke-AddToPath {
    Write-Step 'Updating PATH'
    if ($script:InstalledVia -and $script:InstalledVia -ne 'direct') {
        Write-Info "$($script:InstalledVia) puts opencode on PATH itself - nothing to do"
        return
    }
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $current) { $current = '' }

    $entries = @($current -split ';' | Where-Object { $_ -and $_.Trim() })
    $already = $false
    foreach ($e in $entries) {
        if ($e.Trim().TrimEnd('\') -ieq $script:InstallDir.TrimEnd('\')) { $already = $true; break }
    }
    if ($already) {
        Write-Ok "$script:InstallDir already on PATH"
        return
    }
    try {
        $new = (($entries + $script:InstallDir) -join ';')
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        Write-Ok "added $script:InstallDir to the User PATH"
    } catch {
        Write-Warn "could not update PATH: $($_.Exception.Message)"
        Write-Warn "add it by hand:  $script:InstallDir"
    }
}

function Invoke-DesktopShortcut {
    Write-Step 'Creating the desktop shortcut'
    $wt = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'

    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk   = $shell.CreateShortcut($script:DesktopLnk)
        $binary = if ($script:ActiveBinary) { $script:ActiveBinary } else { Get-ActiveBinary }
        if (-not $binary) { Write-Warn 'no binary to point the shortcut at'; return }

        if (Test-Path -LiteralPath $wt) {
            $lnk.TargetPath       = $wt
            $lnk.Arguments        = "-w new -M `"$binary`""
            Write-Ok 'launches Windows Terminal with OpenCode'
        } else {
            $lnk.TargetPath = $binary
            Write-Warn 'Windows Terminal not found; shortcut opens a plain console window'
        }
        $lnk.WorkingDirectory = $script:UserProfile
        $lnk.IconLocation     = "$binary,0"
        $lnk.Description      = "OpenCode $Version"
        $lnk.Save()
        Write-Ok "created $script:DesktopLnk"
    } catch {
        Write-Warn "could not create the shortcut: $($_.Exception.Message)"
    }
}

function Get-ActiveBinary {
    # Where the binary that `opencode` actually resolves to. It is not always
    # ~/.opencode/bin: npm, bun and brew all install to their own prefix, and
    # on those paths ~/.opencode/bin is empty.
    if ($script:InstalledVia -eq 'direct') { return $script:ExePath }

    # Ask npm where its global prefix actually is, rather than assuming
    # %APPDATA%\npm - that assumption breaks whenever APPDATA and USERPROFILE
    # disagree. Wrapped because $ErrorActionPreference is Stop and npm writes
    # to stderr, which would otherwise throw out of this function.
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        try {
            $r = Invoke-Native -FilePath (Get-Command npm).Source -Arguments @('prefix', '-g')
            if ($r.ExitCode -eq 0 -and $r.Output) {
                $candidate = Join-Path $r.Output.Trim() 'opencode.cmd'
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        } catch {
            Write-Info "could not ask npm for its global prefix: $($_.Exception.Message)"
        }
    }

    $fallback = Join-Path $env:APPDATA 'npm\opencode.cmd'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    if (Test-Path -LiteralPath $script:ExePath) { return $script:ExePath }

    $onPath = Get-Command opencode -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function Invoke-Verify {
    Write-Step 'Verifying'
    $binary = Get-ActiveBinary
    if (-not $binary) { throw "No OpenCode binary could be located after installing via $($script:InstalledVia)." }
    $reported = Get-BinaryVersion -Path $binary
    if (-not $reported) {
        throw "The installed binary at $binary will not run. Re-run the installer."
    }
    if ($reported -ne $Version) {
        throw "Expected $Version but the installed binary reports $reported."
    }
    Write-Ok "reported version: $reported"
    Write-Ok "binary: $binary"
    $script:ActiveBinary = $binary

    $major = ($reported -split '\.')[0]
    if ($major -ne '2') {
        throw "Expected major version 2 but the binary reports $reported. Something is wrong with the download."
    }

    if (Test-Path -LiteralPath $script:ConfigDir) {
        $cfg = Join-Path $script:ConfigDir 'opencode.jsonc'
        if (Test-Path -LiteralPath $cfg) { Write-Ok "config present: $cfg" }
        else { Write-Warn "opencode.jsonc not found in $script:ConfigDir" }
    } else {
        Write-Warn "config folder missing: $script:ConfigDir"
    }

    $shim = Join-Path $env:APPDATA 'npm\opencode.cmd'
    if ($script:InstalledVia -eq 'npm') {
        # npm is the install we chose; its shim is meant to be there.
        if (Test-Path -LiteralPath $shim) { Write-Ok "active install: $shim" }
        else { Write-Warn "npm was used but no shim was found at $shim" }
        return
    }
    if (Test-Path -LiteralPath $shim) {
        Write-Warn "an npm `opencode` shim still exists at $shim and will shadow 2.x."
        Write-Warn "remove it with:  npm uninstall -g $($script:ModernNpmPkg) $($script:LegacyNpmPkg)"
    }
}

function Write-Summary {
    Write-Step 'Done'
    Write-Host ''
    Write-Host '    Open the desktop "OpenCode" icon to start it.' -ForegroundColor White
    Write-Host ''
    Write-Host '    To upgrade later, run:' -ForegroundColor White
    Write-Host '        powershell -ExecutionPolicy Bypass -File "C:\opencode-v2-update\Upgrade-OpenCode.ps1"' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    Close and reopen any already-open terminals before using the' -ForegroundColor Gray
    Write-Host '    `opencode` command - they still hold the old PATH.' -ForegroundColor Gray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$exitCode = 0
try {
    $script:Version = Resolve-InstallVersion
    Assert-VersionAvailable -Arch (Get-TargetArch) -Version $script:Version | Out-Null
    Invoke-Preflight
    $audit    = Invoke-Audit
    Invoke-RemoveLegacy -Audit $audit
    if (-not $SkipConfig) {
        Invoke-BackupConfig
        Invoke-InstallConfig
    } else {
        Write-Step 'Skipping config install (-SkipConfig)'
    }
    Invoke-InstallBinaryWithFallback
    Invoke-RemoveNpmShim
    Invoke-AddToPath
    Invoke-DesktopShortcut
    Invoke-Verify
    Write-Summary
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-Host "    at: $($_.ScriptStackTrace -split "`n" | Select-Object -First 1)" -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '    Nothing was left half-installed. Re-run after fixing the problem above.' -ForegroundColor Yellow
    $exitCode = 1
}
exit $exitCode