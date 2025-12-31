<#
.SYNOPSIS
    Build Linux AppImage using WSL and copy the artifact to the dist directory.

.DESCRIPTION
    This script copies the build scripts to the WSL build directory, runs the
    create-appimage.sh script in WSL, and downloads the resulting AppImage artifact.

.PARAMETER Clean
    Run clean build (passes --clean to build script). Does NOT delete src directory.

.PARAMETER CleanSrc
    Also delete the src directory (full clean, triggers fresh git clone)

.PARAMETER CleanAppDir
    Only delete the AppDir (keeps build, useful for re-packaging without rebuilding)

.PARAMETER SkipBuild
    Skip CMake build, only create AppImage from existing build (passes --skip-build)

.PARAMETER Jobs
    Number of parallel build jobs (passes -j to build script)

.PARAMETER QtVersion
    Qt version to use (passes --qt to build script)

.PARAMETER ExtraArgs
    Additional arguments to pass to create-appimage.sh

.PARAMETER DryRun
    Show what would be executed without actually running

.EXAMPLE
    .\build-appimage-wsl.ps1 -Clean
    Build with clean (removes build and AppDir, keeps src)

.EXAMPLE
    .\build-appimage-wsl.ps1 -CleanSrc
    Full clean build (removes everything including src)

.EXAMPLE
    .\build-appimage-wsl.ps1 -SkipBuild
    Skip build, only package existing build into AppImage

.EXAMPLE
    .\build-appimage-wsl.ps1 -CleanAppDir
    Clean only AppDir and re-package (keeps compiled binaries)
#>

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$CleanSrc,
    [switch]$CleanAppDir,
    [switch]$SkipBuild,

    [int]$Jobs = 0,
    [string]$QtVersion = "",

    [string]$ExtraArgs = "",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Script location
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

#region WSL Configuration

# Helper function to clean UTF-16LE output from wsl.exe (removes null bytes)
function Clean-WslOutput {
    param([string]$Text)
    # Use backtick-zero for null character in PowerShell
    return ($Text -replace "`0", '').Trim()
}

# Test if WSL is available
$testWsl = Clean-WslOutput (wsl.exe -- echo "ok" 2>$null)
if ($testWsl -ne "ok") {
    Write-Host "ERROR: No default WSL distribution found or WSL not running" -ForegroundColor Red
    Write-Host "Please install and configure a WSL distribution" -ForegroundColor Yellow
    exit 1
}

# Get the default WSL distribution name
# wsl.exe --list outputs UTF-16LE with null bytes between characters
$wslListRaw = wsl.exe --list --verbose 2>$null | Out-String
$wslListText = Clean-WslOutput $wslListRaw

# Find line with asterisk (default distro)
$WslDistro = $null
foreach ($line in ($wslListText -split "`r?`n")) {
    if ($line -match '^\s*\*') {
        # Extract distro name: "* Ubuntu-22.04  Running  2" -> "Ubuntu-22.04"
        $parts = ($line -replace '^\s*\*\s*', '') -split '\s+' | Where-Object { $_ }
        if ($parts.Count -gt 0) {
            $WslDistro = $parts[0]
            break
        }
    }
}

if (-not $WslDistro) {
    Write-Host "ERROR: Could not determine default WSL distribution" -ForegroundColor Red
    exit 1
}

Write-Host "Using WSL distribution: $WslDistro" -ForegroundColor Gray

# Get default user for the WSL distribution
$WslUser = Clean-WslOutput (wsl.exe -d $WslDistro -- whoami 2>$null)

if (-not $WslUser) {
    Write-Host "ERROR: Could not determine WSL user" -ForegroundColor Red
    exit 1
}
Write-Host "Using WSL user: $WslUser" -ForegroundColor Gray

# Build directory in WSL
$WslBuildDir = "/home/$WslUser/cr2xt-build"
$WslBuildDirWindows = "\\wsl$\$WslDistro\home\$WslUser\cr2xt-build"

# Local dist directory
$LocalDistPath = Join-Path $ProjectRoot "dist"

#endregion

#region Build Arguments

$buildArgs = @()

if ($Clean)       { $buildArgs += "--clean" }
if ($CleanSrc)    { $buildArgs += "--clean-src" }
if ($CleanAppDir) { $buildArgs += "--clean-appdir" }
if ($SkipBuild)   { $buildArgs += "--skip-build" }
if ($Jobs -gt 0) { $buildArgs += "-j"; $buildArgs += $Jobs.ToString() }
if ($QtVersion) { $buildArgs += "--qt"; $buildArgs += $QtVersion }

if ($ExtraArgs) {
    $buildArgs += $ExtraArgs.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
}

$buildArgsStr = $buildArgs -join " "

#endregion

#region Display Info

Write-Host ""
Write-Host "=== WSL AppImage Build ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "WSL distro:     $WslDistro" -ForegroundColor Gray
Write-Host "WSL user:       $WslUser" -ForegroundColor Gray
Write-Host "Build dir:      $WslBuildDir" -ForegroundColor Gray
Write-Host "Build args:     $buildArgsStr" -ForegroundColor Gray
Write-Host "Local dist:     $LocalDistPath" -ForegroundColor Gray
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] Would copy scripts to: $WslBuildDirWindows" -ForegroundColor Yellow
    Write-Host "[DRY RUN] Would run: cd $WslBuildDir && ./create-appimage.sh $buildArgsStr" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

#endregion

#region Copy Scripts to WSL

Write-Host "=== Copying Build Scripts ===" -ForegroundColor Cyan
Write-Host ""

# Ensure WSL build directory exists
if (-not (Test-Path $WslBuildDirWindows)) {
    Write-Host "Creating build directory: $WslBuildDirWindows" -ForegroundColor Gray
    New-Item -ItemType Directory -Path $WslBuildDirWindows -Force | Out-Null
}

# Copy scripts
$scriptsToSync = @(
    "create-appimage.sh",
    "excludelist"
)

foreach ($script in $scriptsToSync) {
    $srcPath = Join-Path $ScriptDir $script
    $dstPath = Join-Path $WslBuildDirWindows $script

    if (Test-Path $srcPath) {
        Copy-Item -Path $srcPath -Destination $dstPath -Force
        Write-Host "  Copied: $script" -ForegroundColor Gray
    } else {
        Write-Host "  WARNING: Script not found: $srcPath" -ForegroundColor Yellow
    }
}

# Fix line endings (convert CRLF to LF for bash scripts)
Write-Host "  Fixing line endings..." -ForegroundColor Gray
wsl.exe -d $WslDistro -- sed -i 's/\r$//' "$WslBuildDir/create-appimage.sh"
wsl.exe -d $WslDistro -- sed -i 's/\r$//' "$WslBuildDir/excludelist"
wsl.exe -d $WslDistro -- chmod +x "$WslBuildDir/create-appimage.sh"

Write-Host ""

#endregion

#region Build

Write-Host "=== Starting WSL Build ===" -ForegroundColor Cyan
Write-Host ""

# Run the build script with bash explicitly (user's default shell might be different)
# Use & operator for direct invocation which handles arguments better
$buildCommand = "cd '$WslBuildDir' && ./create-appimage.sh $buildArgsStr"
& wsl.exe -d $WslDistro -e bash -c $buildCommand
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "ERROR: WSL build failed with exit code $exitCode" -ForegroundColor Red
    exit $exitCode
}

Write-Host ""
Write-Host "=== WSL Build Completed ===" -ForegroundColor Green
Write-Host ""

#endregion

#region Download Artifacts

Write-Host "=== Checking for AppImage Artifacts ===" -ForegroundColor Cyan
Write-Host ""

# Find AppImage files in WSL build directory
$appimageFiles = Get-ChildItem -Path $WslBuildDirWindows -Filter "*.AppImage" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

if (-not $appimageFiles -or $appimageFiles.Count -eq 0) {
    Write-Host "No AppImage files found in build directory." -ForegroundColor Yellow
    Write-Host "The build may have failed silently." -ForegroundColor Yellow
    exit 0
}

# Ensure local dist directory exists
if (-not (Test-Path $LocalDistPath)) {
    New-Item -ItemType Directory -Path $LocalDistPath -Force | Out-Null
}

Write-Host "=== Copying AppImage Artifacts ===" -ForegroundColor Cyan
Write-Host ""

# Copy the most recent AppImage (or all if multiple)
$latestAppImage = $appimageFiles | Select-Object -First 1

$appImageName = $latestAppImage.Name
$localAppImage = Join-Path $LocalDistPath $appImageName

Write-Host "Copying: $appImageName" -ForegroundColor Gray

Copy-Item -Path $latestAppImage.FullName -Destination $localAppImage -Force

$fileSize = (Get-Item $localAppImage).Length / 1MB
Write-Host "  Copied: $appImageName ($([math]::Round($fileSize, 1)) MB)" -ForegroundColor Green

#endregion

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Artifact saved to: $LocalDistPath\$appImageName" -ForegroundColor Gray
