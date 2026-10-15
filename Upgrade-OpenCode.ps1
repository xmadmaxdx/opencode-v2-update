<#
.SYNOPSIS
    Updates an OpenCode 2.x install installed by install.ps1.

.DESCRIPTION
    Downloads the newest OpenCode 2.x build and replaces the binary in
    %USERPROFILE%\.opencode\bin.

    Why this exists instead of `opencode upgrade`:
    OpenCode's built-in updater shells out to bash/sh to re-run its install
    script. On Windows without Git for Windows there is no bash, so
    `opencode upgrade` fails. This script needs nothing but PowerShell.

    The latest 2.x version is read from the npm registry, because OpenCode 2.x
    publishes no GitHub Release assets (the GitHub "latest release" is 1.18.x).

    The current binary is backed up before being replaced, and is restored
    automatically if the new one fails to launch.

.PARAMETER Version
    Target version. Omit to auto-detect the newest 2.x release.

.PARAMETER Force
    Non-interactive.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\opencode-v2-update\Upgrade-OpenCode.ps1
#>
[CmdletBinding()]
param(
    [string] $Version,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DownloadBase = 'https://opencode.ai/files/bin'
$InstallDir   = Join-Path $env:USERPROFILE '.opencode\bin'
$ExePath      = Join-Path $InstallDir 'opencode.exe'
$script:Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')

function Write-Step { param([string]$M) Write-Host "`n==> $M" -ForegroundColor Cyan }
function Write-Ok   { param([string]$M) Write-Host "    [ok]   $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "    [info] $M" -ForegroundColor Gray }
function Write-Warn { param([string]$M) Write-Host "    [warn] $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "    [FAIL] $M" -ForegroundColor Red }

function Get-TargetArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { if ([Environment]::Is64BitOperatingSystem) { return 'x64' }
                  throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
    }
}

function Invoke-Native {
    # $ErrorActionPreference is 'Stop' here, which promotes any stderr line from a
    # native tool into a terminating error. Route native calls through this.
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output | Out-String)
        }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Install-BinaryFile {
    # Copy first, intervene only if the file is genuinely locked. Checking for a
    # running process up front would refuse whenever any OpenCode was open, even
    # one from a different install that does not hold this file.
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
    # $env:TEMP can be an 8.3 short path (e.g. C:\Users\CW SYL~1) on some
    # machines, and Remove-Item -Recurse over one fails. Prove it is writable.
    $candidates = @()
    try { $candidates += [System.IO.Path]::GetTempPath() } catch { }
    if ($env:TEMP)          { $candidates += $env:TEMP }
    if ($env:TMP)           { $candidates += $env:TMP }
    $candidates += (Join-Path $env:USERPROFILE 'AppData\Local\Temp')

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
            $probe = Join-Path $candidate "oc-write-probe-$script:Stamp"
            New-Item -ItemType Directory -Path $probe -Force -ErrorAction Stop | Out-Null
            Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction Stop
            return $candidate
        } catch { }
    }
    throw 'No writable temporary folder could be found on this PC.'
}

function Get-BinaryVersion {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $result = Invoke-Native -FilePath $Path -Arguments @('--version')
    if ($result.Output -match 'v(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-LatestV2 {
    # The npm registry is the only reliable "latest 2.x" source: OpenCode 2.x
    # ships no GitHub Release assets.
    $uri = 'https://registry.npmjs.org/@opencode%2Fcli/latest'
    try {
        $j = Invoke-RestMethod -Uri $uri -TimeoutSec 30 -UseBasicParsing
        if ($j.version -and $j.version -match '^2\.') { return $j.version }
    } catch {
        Write-Warn "could not read the latest version: $($_.Exception.Message)"
    }
    return $null
}

$exitCode = 0
try {
    Write-Step 'Checking the current install'

    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "No OpenCode binary at $ExePath. Run install.ps1 first."
    }
    $current = Get-BinaryVersion -Path $ExePath
    if (-not $current) { throw "The existing binary at $ExePath does not run." }

    $major = ($current -split '\.')[0]
    if ($major -eq '1') {
        throw "That binary is OpenCode 1.x ($current). 1.x and 2.x cannot be upgraded into each other. Run install.ps1 instead."
    }
    Write-Ok "installed version: $current"

    if (-not $Version) {
        Write-Info 'looking up the newest 2.x release'
        $Version = Get-LatestV2
        if (-not $Version) {
            throw 'Could not determine the latest version. Re-run with -Version, e.g. -Version 2.0.26'
        }
    }
    Write-Ok "target version:   $Version"

    if ($Version -eq $current) {
        Write-Step 'Already up to date.'
        exit 0
    }

    $running = @(Get-Process -Name 'opencode' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Info "$($running.Count) OpenCode process(es) are running; they keep the old code until restarted."
    }

    $stamp  = $script:Stamp
    $backup = Join-Path $InstallDir "opencode-$current-$stamp.exe.bak"
    $tmp    = Join-Path (Resolve-ScratchDir) "opencode-upgrade-$stamp"
    $arch   = Get-TargetArch
    $url    = "$DownloadBase/$Version/opencode-windows-$arch.zip"

    Write-Step "Downloading $Version"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'opencode.zip'
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 900
        $len = (Get-Item -LiteralPath $zip).Length
        if ($len -lt 1MB) { throw "Downloaded archive is only $len bytes - not a real OpenCode build." }
        Write-Ok ("downloaded {0:N1} MB" -f ($len / 1MB))

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $extract = Join-Path $tmp 'extracted'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)

        $newExe = Get-ChildItem -LiteralPath $extract -Filter 'opencode.exe' -Recurse -File |
                  Select-Object -First 1
        if (-not $newExe) { throw 'The archive did not contain opencode.exe.' }

        Write-Step 'Replacing the binary'
        Copy-Item -LiteralPath $ExePath -Destination $backup -Force
        Write-Ok "previous binary backed up to $backup"
        Install-BinaryFile -Source $newExe.FullName -Destination $ExePath

        Write-Step 'Verifying'
        $reported = Get-BinaryVersion -Path $ExePath
        if (-not $reported) {
            Copy-Item -LiteralPath $backup -Destination $ExePath -Force
            throw "The new binary would not run. Rolled back to $current."
        }
        if ($reported -ne $Version) {
            Write-Warn "expected $Version but the binary reports $reported"
        }
        Write-Ok "OpenCode is now $reported"
        Write-Host ''
        Write-Host '    Close and reopen any open terminals before using the `opencode` command.' -ForegroundColor Gray
        Write-Host ''
    } finally {
        # Best-effort cleanup. It must never fail the upgrade, which by this
        # point has already replaced and verified the binary.
        try {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warn "could not remove the scratch folder: $($_.Exception.Message)"
            Write-Warn "harmless - delete it by hand: $tmp"
        }
    }
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    $exitCode = 1
}
exit $exitCode