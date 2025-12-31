<#
.SYNOPSIS
    Build distribution packages for all platforms (Linux, macOS, Windows).

.DESCRIPTION
    This script orchestrates builds for all supported platforms by calling
    the platform-specific build scripts:
    - build-appimage-wsl.ps1 (Linux AppImage via WSL)
    - remote-build-macos.ps1 (macOS DMG via SSH)
    - build-dist-windows.ps1 (Windows portable archive)

.PARAMETER SkipLinux
    Skip the Linux AppImage build

.PARAMETER SkipMacOS
    Skip the macOS DMG build

.PARAMETER SkipWindows
    Skip the Windows portable build

.PARAMETER Clean
    Pass -Clean to all platform build scripts for clean builds

.PARAMETER DryRun
    Show what would be executed without actually running

.EXAMPLE
    .\build-dist-all.ps1
    Build all platforms (incremental builds)

.EXAMPLE
    .\build-dist-all.ps1 -Clean
    Build all platforms with clean builds

.EXAMPLE
    .\build-dist-all.ps1 -SkipMacOS
    Build only Linux and Windows

.EXAMPLE
    .\build-dist-all.ps1 -DryRun
    Show what would be executed
#>

[CmdletBinding()]
param(
    [switch]$SkipLinux,
    [switch]$SkipMacOS,
    [switch]$SkipWindows,
    [switch]$Clean,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Script location
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Track results
$results = @{
    Linux = @{ Status = "skipped"; Duration = $null }
    MacOS = @{ Status = "skipped"; Duration = $null }
    Windows = @{ Status = "skipped"; Duration = $null }
}

$overallStart = Get-Date

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  cr2xt Distribution Build (All Platforms)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN MODE]" -ForegroundColor Yellow
    Write-Host ""
}

#region Linux AppImage Build

if (-not $SkipLinux) {
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "  Building Linux AppImage" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host ""

    $linuxScript = Join-Path $ScriptDir "build-appimage-wsl.ps1"

    if (-not (Test-Path $linuxScript)) {
        Write-Host "WARNING: Linux build script not found: $linuxScript" -ForegroundColor Yellow
        $results.Linux.Status = "not found"
    }
    else {
        $linuxStart = Get-Date

        $linuxArgs = @{ CleanAppDir = $true }
        if ($Clean) { $linuxArgs.Clean = $true }

        if ($DryRun) {
            $linuxArgsStr = ($linuxArgs.Keys | ForEach-Object { "-$_" }) -join ' '
            Write-Host "[DRY RUN] Would execute:" -ForegroundColor Yellow
            Write-Host "  & `"$linuxScript`" $linuxArgsStr" -ForegroundColor Cyan
            $results.Linux.Status = "dry run"
        }
        else {
            try {
                & $linuxScript @linuxArgs
                if ($LASTEXITCODE -eq 0) {
                    $results.Linux.Status = "success"
                }
                else {
                    $results.Linux.Status = "failed (exit code: $LASTEXITCODE)"
                }
            }
            catch {
                $results.Linux.Status = "failed: $_"
            }
        }

        $results.Linux.Duration = (Get-Date) - $linuxStart
    }

    Write-Host ""
}
else {
    Write-Host "Skipping Linux build" -ForegroundColor DarkGray
}

#endregion

#region macOS Build

if (-not $SkipMacOS) {
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "  Building macOS Universal DMG" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host ""

    $macosScript = Join-Path $ScriptDir "remote-build-macos.ps1"

    if (-not (Test-Path $macosScript)) {
        Write-Host "WARNING: macOS build script not found: $macosScript" -ForegroundColor Yellow
        $results.MacOS.Status = "not found"
    }
    else {
        $macosStart = Get-Date

        $macosArgs = @{ Arch = "universal" }
        if ($Clean) { $macosArgs.Clean = $true }

        if ($DryRun) {
            $macosArgsStr = ($macosArgs.GetEnumerator() | ForEach-Object { if ($_.Value -eq $true) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value)" } }) -join ' '
            Write-Host "[DRY RUN] Would execute:" -ForegroundColor Yellow
            Write-Host "  & `"$macosScript`" $macosArgsStr" -ForegroundColor Cyan
            $results.MacOS.Status = "dry run"
        }
        else {
            try {
                & $macosScript @macosArgs
                if ($LASTEXITCODE -eq 0) {
                    $results.MacOS.Status = "success"
                }
                else {
                    $results.MacOS.Status = "failed (exit code: $LASTEXITCODE)"
                }
            }
            catch {
                $results.MacOS.Status = "failed: $_"
            }
        }

        $results.MacOS.Duration = (Get-Date) - $macosStart
    }

    Write-Host ""
}
else {
    Write-Host "Skipping macOS build" -ForegroundColor DarkGray
}

#endregion

#region Windows Build

if (-not $SkipWindows) {
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "  Building Windows Portable" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host ""

    $windowsScript = Join-Path $ScriptDir "build-dist-windows.ps1"

    if (-not (Test-Path $windowsScript)) {
        Write-Host "WARNING: Windows build script not found: $windowsScript" -ForegroundColor Yellow
        $results.Windows.Status = "not found"
    }
    else {
        $windowsStart = Get-Date

        $windowsArgs = @{ Build = $true; CleanDlls = $true }
        if ($Clean) { $windowsArgs.Clean = $true }

        if ($DryRun) {
            $windowsArgsStr = ($windowsArgs.Keys | ForEach-Object { "-$_" }) -join ' '
            Write-Host "[DRY RUN] Would execute:" -ForegroundColor Yellow
            Write-Host "  & `"$windowsScript`" $windowsArgsStr" -ForegroundColor Cyan
            $results.Windows.Status = "dry run"
        }
        else {
            try {
                & $windowsScript @windowsArgs
                if ($LASTEXITCODE -eq 0) {
                    $results.Windows.Status = "success"
                }
                else {
                    $results.Windows.Status = "failed (exit code: $LASTEXITCODE)"
                }
            }
            catch {
                $results.Windows.Status = "failed: $_"
            }
        }

        $results.Windows.Duration = (Get-Date) - $windowsStart
    }

    Write-Host ""
}
else {
    Write-Host "Skipping Windows build" -ForegroundColor DarkGray
}

#endregion

#region Summary

$overallDuration = (Get-Date) - $overallStart

Write-Host "========================================" -ForegroundColor Green
Write-Host "  Build Summary" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

function Format-Duration($duration) {
    if ($null -eq $duration) { return "-" }
    if ($duration.TotalMinutes -ge 1) {
        return "{0:N1} min" -f $duration.TotalMinutes
    }
    return "{0:N1} sec" -f $duration.TotalSeconds
}

function Get-StatusColor($status) {
    switch -Wildcard ($status) {
        "success" { return "Green" }
        "skipped" { return "DarkGray" }
        "dry run" { return "Yellow" }
        "not found" { return "Yellow" }
        default { return "Red" }
    }
}

$platforms = @(
    @{ Name = "Linux AppImage"; Key = "Linux" }
    @{ Name = "macOS Universal"; Key = "MacOS" }
    @{ Name = "Windows Portable"; Key = "Windows" }
)

foreach ($platform in $platforms) {
    $status = $results[$platform.Key].Status
    $duration = Format-Duration $results[$platform.Key].Duration
    $color = Get-StatusColor $status

    $statusText = $status.PadRight(30)
    Write-Host "  $($platform.Name.PadRight(20))" -NoNewline
    Write-Host $statusText -ForegroundColor $color -NoNewline
    Write-Host " [$duration]" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Total time: $(Format-Duration $overallDuration)" -ForegroundColor White
Write-Host ""

# Determine overall exit code
$hasFailures = $results.Values | Where-Object { $_.Status -like "failed*" }
if ($hasFailures) {
    Write-Host "Some builds failed!" -ForegroundColor Red
    exit 1
}

Write-Host "All builds completed!" -ForegroundColor Green

#endregion
