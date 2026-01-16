<#
.SYNOPSIS
    Run macOS build on a remote machine via SSH and download the DMG artifact.

.DESCRIPTION
    This script connects to a remote macOS machine via SSH, runs the build-dist-macos.sh
    script, and downloads the resulting DMG artifact if one was created.

.PARAMETER Arch
    Target architecture: "arm64", "x86_64", "universal", or "all".
    Maps to build script options: -a/--arch, -u/--universal, -A/--all

.PARAMETER Clean
    Run clean build (passes --clean to build script)

.PARAMETER NoBuild
    Skip CMake build, only run deployment/packaging (passes --no-build to build script)

.PARAMETER SkipDmg
    Skip DMG creation (passes --skip-dmg to build script)

.PARAMETER SkipDeploy
    Skip macdeployqt (passes --skip-deploy to build script)

.PARAMETER Headless
    Force headless DMG creation (passes --headless to build script)

.PARAMETER Jobs
    Number of parallel build jobs (passes -j to build script)

.PARAMETER ExtraArgs
    Additional arguments to pass to build-dist-macos.sh

.PARAMETER Sync
    Pull latest changes and update submodules before building (default: enabled)

.PARAMETER NoSync
    Skip git pull and submodule update

.PARAMETER DryRun
    Show what would be executed without actually running

.EXAMPLE
    .\remote-build-macos.ps1 -Arch arm64 -Clean
    Build for arm64 with clean build

.EXAMPLE
    .\remote-build-macos.ps1 -Arch universal
    Build universal binary

.EXAMPLE
    .\remote-build-macos.ps1 -Arch all -Headless
    Build all architectures (arm64, x86_64, universal) in headless mode
#>

[CmdletBinding()]
param(
    [ValidateSet("arm64", "x86_64", "universal", "all")]
    [string]$Arch = "",

    [switch]$Clean,
    [switch]$NoBuild,
    [switch]$SkipDmg,
    [switch]$SkipDeploy,
    [switch]$Headless,

    [int]$Jobs = 0,

    [string]$ExtraArgs = "",

    [switch]$NoSync,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Script location
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

#region Configuration

$ConfigFile = Join-Path $ScriptDir "remote-build-config.local.ps1"
$TemplateFile = Join-Path $ScriptDir "remote-build-config.template.ps1"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Configuration file not found: $ConfigFile" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please create the configuration file by copying the template:" -ForegroundColor Yellow
    Write-Host "  Copy-Item `"$TemplateFile`" `"$ConfigFile`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Then edit $ConfigFile with your remote machine settings."
    exit 1
}

. $ConfigFile

# Validate required configuration
foreach ($var in @("SSH_HOST", "SSH_USER", "REMOTE_PROJECT_PATH", "REMOTE_DIST_PATH")) {
    if (-not (Get-Variable -Name $var -ValueOnly -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Required configuration variable '$var' is not set in $ConfigFile" -ForegroundColor Red
        exit 1
    }
}

# Set defaults
if (-not $SSH_PORT) { $SSH_PORT = 22 }
if (-not $SSH_TOOL) { $SSH_TOOL = "msys2" }
if (-not $LOCAL_DIST_PATH) { $LOCAL_DIST_PATH = Join-Path $ProjectRoot "dist" }

#endregion

#region SSH/SCP Tool Setup

$script:sshCmd = ""
$script:scpCmd = ""
$script:puttyKeyFile = ""

switch ($SSH_TOOL.ToLower()) {
    "msys2" {
        $script:sshCmd = if ($MSYS2_SSH -and (Test-Path $MSYS2_SSH)) { $MSYS2_SSH } else { "C:\tools\msys64\usr\bin\ssh.exe" }
        $script:scpCmd = if ($MSYS2_SCP -and (Test-Path $MSYS2_SCP)) { $MSYS2_SCP } else { "C:\tools\msys64\usr\bin\scp.exe" }
    }
    "putty" {
        $script:sshCmd = if ($PUTTY_PLINK -and (Test-Path $PUTTY_PLINK)) { $PUTTY_PLINK } else { "plink.exe" }
        $script:scpCmd = if ($PUTTY_PSCP -and (Test-Path $PUTTY_PSCP)) { $PUTTY_PSCP } else { "pscp.exe" }
        if ($PUTTY_KEY -and (Test-Path $PUTTY_KEY)) { $script:puttyKeyFile = $PUTTY_KEY }
    }
    default {
        Write-Host "ERROR: Unknown SSH_TOOL: $SSH_TOOL (use 'msys2' or 'putty')" -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $script:sshCmd)) {
    Write-Host "ERROR: SSH tool not found: $script:sshCmd" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $script:scpCmd)) {
    Write-Host "ERROR: SCP tool not found: $script:scpCmd" -ForegroundColor Red
    exit 1
}

#endregion

#region Helper Functions

function Get-SshArgs {
    param([string]$Command)

    $args = @()
    if ($SSH_TOOL -eq "msys2") {
        $args += "-p"
    } else {
        $args += "-batch"
        if ($script:puttyKeyFile) { $args += "-i"; $args += $script:puttyKeyFile }
        $args += "-P"
    }
    $args += $SSH_PORT.ToString()
    $args += "$SSH_USER@$SSH_HOST"
    $args += $Command
    return $args
}

function Get-ScpArgs {
    param([string]$RemotePath, [string]$LocalPath)

    $args = @()
    if ($SSH_TOOL -ne "msys2" -and $script:puttyKeyFile) {
        $args += "-i"
        $args += $script:puttyKeyFile
    }
    $args += "-P"
    $args += $SSH_PORT.ToString()
    $args += "$SSH_USER@$SSH_HOST`:$RemotePath"
    $args += $LocalPath
    return $args
}

function Invoke-RemoteCommand {
    param(
        [string]$Command,
        [string]$Description,
        [switch]$CaptureOutput
    )

    $sshArgs = Get-SshArgs -Command $Command

    if ($CaptureOutput) {
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            $process = Start-Process -FilePath $script:sshCmd -ArgumentList $sshArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput $tempFile
            $output = Get-Content $tempFile
            return @{ ExitCode = $process.ExitCode; Output = $output }
        } finally {
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
    } else {
        $process = Start-Process -FilePath $script:sshCmd -ArgumentList $sshArgs -NoNewWindow -PassThru -Wait
        return @{ ExitCode = $process.ExitCode; Output = $null }
    }
}

function Invoke-RemoteCopy {
    param([string]$RemotePath, [string]$LocalPath)

    $scpArgs = Get-ScpArgs -RemotePath $RemotePath -LocalPath $LocalPath
    $process = Start-Process -FilePath $script:scpCmd -ArgumentList $scpArgs -NoNewWindow -PassThru -Wait
    return $process.ExitCode
}

#endregion

#region Build Arguments

$buildArgs = @()

switch ($Arch) {
    "universal" { $buildArgs += "--universal" }
    "all"       { $buildArgs += "--all" }
    "arm64"     { $buildArgs += "--arch"; $buildArgs += "arm64" }
    "x86_64"    { $buildArgs += "--arch"; $buildArgs += "x86_64" }
}

if ($Clean)      { $buildArgs += "--clean" }
if ($NoBuild)    { $buildArgs += "--no-build" }
if ($SkipDmg)    { $buildArgs += "--skip-dmg" }
if ($SkipDeploy) { $buildArgs += "--skip-deploy" }
if ($Headless)   { $buildArgs += "--headless" }
if ($Jobs -gt 0) { $buildArgs += "-j"; $buildArgs += $Jobs.ToString() }

if ($ExtraArgs) {
    $buildArgs += $ExtraArgs.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
}

$buildArgsStr = $buildArgs -join " "

# Ensure Homebrew paths are in PATH for non-interactive SSH sessions
$pathSetup = "export PATH=/opt/homebrew/bin:/usr/local/bin:`$PATH"
$cdProject = "cd `"$REMOTE_PROJECT_PATH`""

#endregion

#region Display Info

Write-Host ""
Write-Host "=== Remote macOS Build ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Remote host:    $SSH_USER@$SSH_HOST`:$SSH_PORT" -ForegroundColor Gray
Write-Host "Remote path:    $REMOTE_PROJECT_PATH" -ForegroundColor Gray
Write-Host "Git sync:       $(if ($NoSync) { 'disabled' } else { 'enabled' })" -ForegroundColor Gray
Write-Host "Build args:     $buildArgsStr" -ForegroundColor Gray
Write-Host "Local dist:     $LOCAL_DIST_PATH" -ForegroundColor Gray
Write-Host ""

if ($DryRun) {
    if (-not $NoSync) {
        Write-Host "[DRY RUN] Would sync git:" -ForegroundColor Yellow
        Write-Host "  git pull --ff-only && git submodule update --init --recursive" -ForegroundColor Cyan
    }
    Write-Host "[DRY RUN] Would build:" -ForegroundColor Yellow
    Write-Host "  $REMOTE_PROJECT_PATH/scripts/build-dist-macos.sh $buildArgsStr" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

#endregion

#region Git Sync

if (-not $NoSync) {
    Write-Host "=== Syncing Git Repository ===" -ForegroundColor Cyan
    Write-Host ""

    # Reset any local changes to get clean copies
    $syncCommand = "$pathSetup && $cdProject && git fetch origin && git reset --hard origin/main && git submodule foreach --recursive git reset --hard && git submodule update --init --recursive --force"
    $result = Invoke-RemoteCommand -Command $syncCommand

    if ($result.ExitCode -ne 0) {
        Write-Host ""
        Write-Host "ERROR: Git sync failed with exit code $($result.ExitCode)" -ForegroundColor Red
        exit $result.ExitCode
    }

    Write-Host ""
    Write-Host "Git sync completed" -ForegroundColor Green
    Write-Host ""
}

#endregion

#region Build

Write-Host "=== Starting Remote Build ===" -ForegroundColor Cyan
Write-Host ""

$buildCommand = "$pathSetup && $cdProject && `"./scripts/build-dist-macos.sh`" $buildArgsStr"
$result = Invoke-RemoteCommand -Command $buildCommand

if ($result.ExitCode -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Remote build failed with exit code $($result.ExitCode)" -ForegroundColor Red
    exit $result.ExitCode
}

Write-Host ""
Write-Host "=== Remote Build Completed ===" -ForegroundColor Green
Write-Host ""

#endregion

#region Download Artifacts

if ($SkipDmg) {
    Write-Host "DMG creation was skipped, no artifact to download." -ForegroundColor Yellow
    exit 0
}

Write-Host "=== Checking for DMG Artifacts ===" -ForegroundColor Cyan
Write-Host ""

$listCommand = "ls -1t `"$REMOTE_DIST_PATH`"/*.dmg 2>/dev/null | head -5"
$result = Invoke-RemoteCommand -Command $listCommand -CaptureOutput
$dmgFiles = $result.Output | Where-Object { $_ -match "\.dmg$" }

if (-not $dmgFiles -or $dmgFiles.Count -eq 0) {
    Write-Host "No DMG files found in remote dist folder." -ForegroundColor Yellow
    Write-Host "The build may have skipped DMG creation or failed silently." -ForegroundColor Yellow
    exit 0
}

# Determine which DMG files to download based on architecture
$dmgsToDownload = switch ($Arch) {
    "all"       { $dmgFiles | Select-Object -First 3 }
    "universal" { ($dmgFiles | Where-Object { $_ -match "-universal\.dmg$" } | Select-Object -First 1) ?? ($dmgFiles | Select-Object -First 1) }
    "arm64"     { ($dmgFiles | Where-Object { $_ -match "-arm64\.dmg$" } | Select-Object -First 1) ?? ($dmgFiles | Select-Object -First 1) }
    "x86_64"    { ($dmgFiles | Where-Object { $_ -match "-x86_64\.dmg$" } | Select-Object -First 1) ?? ($dmgFiles | Select-Object -First 1) }
    default     { $dmgFiles | Select-Object -First 1 }
}

if (-not $dmgsToDownload -or $dmgsToDownload.Count -eq 0) {
    Write-Host "No matching DMG files found for architecture: $Arch" -ForegroundColor Yellow
    exit 0
}

# Ensure local dist directory exists
if (-not (Test-Path $LOCAL_DIST_PATH)) {
    New-Item -ItemType Directory -Path $LOCAL_DIST_PATH -Force | Out-Null
}

Write-Host "=== Downloading DMG Artifacts ===" -ForegroundColor Cyan
Write-Host ""

foreach ($remoteDmg in $dmgsToDownload) {
    $dmgName = Split-Path -Leaf $remoteDmg
    $localDmg = Join-Path $LOCAL_DIST_PATH $dmgName

    Write-Host "Downloading: $dmgName" -ForegroundColor Gray

    $exitCode = Invoke-RemoteCopy -RemotePath $remoteDmg -LocalPath $localDmg

    if ($exitCode -eq 0) {
        $fileSize = (Get-Item $localDmg).Length / 1MB
        Write-Host "  Downloaded: $dmgName ($([math]::Round($fileSize, 1)) MB)" -ForegroundColor Green
    } else {
        Write-Host "  Failed to download: $dmgName" -ForegroundColor Red
    }
}

#endregion

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Artifacts saved to: $LOCAL_DIST_PATH" -ForegroundColor Gray
exit 0
