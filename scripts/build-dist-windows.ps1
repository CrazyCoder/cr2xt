#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a portable distribution of cr2xt (Cool Reader) for Windows.

.DESCRIPTION
    This script packages the installed cr2xt application into a portable
    distribution with selected fonts, translations, and dependencies.
    It runs windeployqt6 to ensure Qt dependencies are up to date.

.PARAMETER SourceDir
    Path to the installed application (default: ..\cr-conv)

.PARAMETER DistDir
    Output directory for the distribution (default: .\dist)

.PARAMETER NoZip
    Skip creating the ZIP archive

.PARAMETER Clean
    Remove dist directory before building

.PARAMETER SkipWinDeployQt
    Skip running windeployqt6 (use existing Qt files)

.PARAMETER CleanDlls
    Remove all *.dll files from SourceDir (except libcrengine-ng.dll) before
    running windeployqt6. Use this to ensure clean Qt deployment after Qt updates.

.PARAMETER SkipMingwDlls
    Skip running mingw-bundledlls to copy MinGW dependencies

.PARAMETER No7z
    Skip creating the 7z archive (only creates ZIP)

.PARAMETER Build
    Run CMake build and install before packaging. Uses release configuration
    with -DCON_DEBUG:BOOL=OFF to produce Windows binary without console.

.PARAMETER CleanBuild
    Remove build directory before building (forces full rebuild)

.PARAMETER BuildDir
    CMake build directory (default: ..\build\release)

.PARAMETER Jobs
    Number of parallel build jobs (default: number of processors)

.PARAMETER Msys2Root
    Path to MSYS2 installation (default: C:\tools\msys64)

.EXAMPLE
    .\build-dist-windows.ps1
    .\build-dist-windows.ps1 -SourceDir "C:\MyApp" -DistDir ".\output"
    .\build-dist-windows.ps1 -Clean -NoZip
    .\build-dist-windows.ps1 -SkipWinDeployQt
    .\build-dist-windows.ps1 -Build -CleanDlls -Clean
#>

param(
    [string]$SourceDir = "..\cr-conv",
    [string]$DistDir = "",
    [switch]$NoZip,
    [switch]$Clean,
    [switch]$SkipWinDeployQt,
    [switch]$CleanDlls,
    [switch]$SkipMingwDlls,
    [switch]$No7z,
    [switch]$Build,
    [switch]$CleanBuild,
    [string]$BuildDir = "",
    [int]$Jobs = 0,
    [string]$Msys2Root = "C:\tools\msys64"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Get script directory and project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Default dist directory is in project root
if ([string]::IsNullOrEmpty($DistDir)) {
    $DistDir = Join-Path $ProjectRoot "dist"
}

# Load configuration
$ConfigPath = Join-Path $ScriptDir "dist-config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
Write-Host "Loaded configuration from: $ConfigPath" -ForegroundColor Cyan

# Validate source directory
if (-not (Test-Path $SourceDir)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}

$AppExe = Join-Path $SourceDir $Config.app_executable
if (-not (Test-Path $AppExe)) {
    Write-Error "Application executable not found: $AppExe"
    exit 1
}

Write-Host "Source: $SourceDir" -ForegroundColor Cyan
Write-Host "Destination: $DistDir" -ForegroundColor Cyan

# Find Python in PATH or MinGW (skip Windows Store stubs)
function Find-Python {
    # Try PATH first, but skip WindowsApps stubs
    $candidates = @(Get-Command "python3.exe", "python.exe" -ErrorAction SilentlyContinue)
    foreach ($cmd in $candidates) {
        if ($cmd -and $cmd.Source -notlike "*\WindowsApps\*") {
            return $cmd.Source
        }
    }

    # Try common MinGW/MSYS2 locations
    $pythonPaths = @(
        "$Msys2Root\mingw64\bin\python3.exe",
        "$Msys2Root\mingw64\bin\python.exe",
        "$env:MSYSTEM_PREFIX\bin\python3.exe",
        "$env:MSYSTEM_PREFIX\bin\python.exe",
        "C:\Python312\python.exe",
        "C:\Python313\python.exe",
        "C:\Python314\python.exe"
    )

    foreach ($path in $pythonPaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

# Find windeployqt6 in PATH or MinGW
function Find-WinDeployQt {
    # Try PATH first
    $inPath = Get-Command "windeployqt6.exe" -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }

    # Try common MinGW locations
    $mingwPaths = @(
        "$Msys2Root\mingw64\bin\windeployqt6.exe",
        "$env:MSYSTEM_PREFIX\bin\windeployqt6.exe"
    )

    foreach ($path in $mingwPaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

# Find 7za.exe in PATH or common locations
function Find-7za {
    # Try PATH first
    $inPath = Get-Command "7za.exe" -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }

    # Also try 7z.exe (full 7-Zip)
    $inPath = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }

    # Try common locations
    $paths = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$Msys2Root\mingw64\bin\7za.exe",
        "$env:MSYSTEM_PREFIX\bin\7za.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

# Get version from git
function Get-GitVersion {
    try {
        Push-Location $ProjectRoot
        $version = git describe --tags --always 2>$null
        if ([string]::IsNullOrEmpty($version)) {
            $version = git rev-parse --short HEAD 2>$null
        }
        if ([string]::IsNullOrEmpty($version)) {
            $version = Get-Date -Format "yyyy.MM.dd"
        }
        return $version
    }
    catch {
        return Get-Date -Format "yyyy.MM.dd"
    }
    finally {
        Pop-Location
    }
}

$Version = Get-GitVersion
Write-Host "Version: $Version" -ForegroundColor Green

# Run CMake build and install if requested
if ($Build) {
    # Disable progress bar to prevent overlap with build output
    $oldProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    Write-Host "`n=== Building project ===" -ForegroundColor Cyan

    # Default build directory
    if ([string]::IsNullOrEmpty($BuildDir)) {
        $BuildDir = Join-Path $ProjectRoot "build\release"
    }

    # Resolve SourceDir to absolute path for install prefix
    $SourceDirAbs = (Resolve-Path $SourceDir -ErrorAction SilentlyContinue)
    if (-not $SourceDirAbs) {
        # SourceDir doesn't exist yet, construct absolute path
        $SourceDirAbs = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $SourceDir))
    }
    else {
        $SourceDirAbs = $SourceDirAbs.Path
    }

    # Default to number of processors
    if ($Jobs -le 0) {
        $Jobs = $env:NUMBER_OF_PROCESSORS
        if (-not $Jobs) { $Jobs = 4 }
    }

    # Validate MSYS2 installation
    if (-not (Test-Path (Join-Path $Msys2Root "msys2_shell.cmd"))) {
        Write-Error "MSYS2 installation not found at: $Msys2Root"
        exit 1
    }

    Write-Host "MSYS2: $Msys2Root" -ForegroundColor Gray
    Write-Host "Build directory: $BuildDir" -ForegroundColor Gray
    Write-Host "Install prefix: $SourceDirAbs" -ForegroundColor Gray
    Write-Host "Jobs: $Jobs" -ForegroundColor Gray

    # Clean build directory if requested
    if ($CleanBuild -and (Test-Path $BuildDir)) {
        Write-Host "`nCleaning build directory..." -ForegroundColor Yellow
        Remove-Item -Path $BuildDir -Recurse -Force
    }

    # Create build directory if it doesn't exist
    if (-not (Test-Path $BuildDir)) {
        New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
    }

    # Convert Windows paths to Unix-style for MSYS2
    function ConvertTo-UnixPath($winPath) {
        $p = $winPath -replace '\\', '/'
        if ($p -match '^([A-Za-z]):(.*)$') {
            return "/$($Matches[1].ToLower())$($Matches[2])"
        }
        return $p
    }

    $ProjectRootUnix = ConvertTo-UnixPath $ProjectRoot
    $BuildDirUnix = ConvertTo-UnixPath $BuildDir
    $InstallPrefixUnix = ConvertTo-UnixPath $SourceDirAbs

    # MSYS2 environment runner - executes commands in MinGW64 environment
    $msysEnv = Join-Path $Msys2Root "usr\bin\env.exe"
    $msysBash = Join-Path $Msys2Root "usr\bin\bash.exe"

    function Invoke-Msys2Command {
        param([string]$Command, [string]$Description)
        Write-Host "`n=== $Description ===" -ForegroundColor Yellow
        # Use & operator with explicit argument array to preserve quoting
        # CLICOLOR_FORCE and CMAKE_COLOR_DIAGNOSTICS enable colored output (CMake/Ninja/GCC don't detect TTY)
        & $msysEnv "MSYSTEM=MINGW64" "CLICOLOR_FORCE=1" "CMAKE_COLOR_DIAGNOSTICS=ON" $msysBash "-lc" $Command
        if ($LASTEXITCODE -ne 0) {
            Write-Error "$Description failed with exit code $LASTEXITCODE"
            exit 1
        }
    }

    # Check if configure is needed
    $needsConfigure = -not (Test-Path (Join-Path $BuildDir "CMakeCache.txt"))

    if ($needsConfigure) {
        # Configure step - use double quotes for paths with spaces, escape inner quotes
        # -w flag suppresses all compiler warnings for cleaner distribution builds
        $configureCmd = "cmake -S `"$ProjectRootUnix`" -B `"$BuildDirUnix`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCON_DEBUG:BOOL=OFF -DCMAKE_INSTALL_PREFIX:PATH=`"$InstallPrefixUnix`" -DCMAKE_C_FLAGS=-w -DCMAKE_CXX_FLAGS=-w"
        Invoke-Msys2Command -Command $configureCmd -Description "Configuring"
    }
    else {
        Write-Host "Build directory already configured, skipping configure step" -ForegroundColor Gray
    }

    # Build step
    $buildCmd = "cmake --build `"$BuildDirUnix`" --target all -j $Jobs"
    Invoke-Msys2Command -Command $buildCmd -Description "Building"

    # Install step
    $installCmd = "cmake --build `"$BuildDirUnix`" --target install -j $Jobs"
    Invoke-Msys2Command -Command $installCmd -Description "Installing"

    # Restore progress preference
    $ProgressPreference = $oldProgressPreference

    Write-Host "`nBuild and install completed successfully" -ForegroundColor Green
}

# Clean DLLs from source directory if requested (before windeployqt6)
if ($CleanDlls) {
    Write-Host "`n=== Cleaning DLLs from source directory ===" -ForegroundColor Yellow

    # Files to preserve (case-insensitive)
    $preserveDlls = @("libcrengine-ng.dll")

    # Get all DLLs recursively
    $dllsToRemove = Get-ChildItem -Path $SourceDir -Filter "*.dll" -Recurse -File | Where-Object {
        $preserveDlls -notcontains $_.Name
    }

    $removedCount = 0
    foreach ($dll in $dllsToRemove) {
        $relativePath = $dll.FullName.Substring($SourceDir.Length + 1)
        Remove-Item -Path $dll.FullName -Force
        Write-Host "  - $relativePath" -ForegroundColor DarkYellow
        $removedCount++
    }

    Write-Host "Removed $removedCount DLL files (preserved: $($preserveDlls -join ', '))" -ForegroundColor Yellow
}

# Run windeployqt6 if not skipped
if (-not $SkipWinDeployQt) {
    Write-Host "`n=== Running windeployqt6 ===" -ForegroundColor Cyan

    $windeployqt = Find-WinDeployQt
    if (-not $windeployqt) {
        Write-Error "windeployqt6.exe not found in PATH or MinGW installation"
        exit 1
    }

    Write-Host "Using: $windeployqt" -ForegroundColor Gray

    # Run windeployqt6 to update Qt dependencies
    $deployArgs = @($AppExe)
    $process = Start-Process -FilePath $windeployqt -ArgumentList $deployArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Warning "windeployqt6 returned exit code $($process.ExitCode)"
    }
    else {
        Write-Host "windeployqt6 completed successfully" -ForegroundColor Green
    }
}

# Run mingw-bundledlls to copy MinGW dependencies
if (-not $SkipMingwDlls) {
    Write-Host "`n=== Copying MinGW dependencies ===" -ForegroundColor Cyan

    $bundledllsScript = Join-Path $ScriptDir "mingw-bundledlls"
    if (-not (Test-Path $bundledllsScript)) {
        Write-Warning "mingw-bundledlls script not found: $bundledllsScript"
    }
    else {
        $python = Find-Python
        if (-not $python) {
            Write-Warning "Python not found in PATH or MinGW installation, skipping mingw-bundledlls"
        }
        else {
            Write-Host "Using Python: $python" -ForegroundColor Gray
            Write-Host "Script: $bundledllsScript" -ForegroundColor Gray

            # Set search path for mingw-bundledlls (mingw64/bin and mingw64/lib)
            $mingwBin = Join-Path $Msys2Root "mingw64\bin"
            $mingwLib = Join-Path $Msys2Root "mingw64\lib"
            $env:MINGW_BUNDLEDLLS_SEARCH_PATH = "$mingwBin;$mingwLib"
            Write-Host "Search path: $env:MINGW_BUNDLEDLLS_SEARCH_PATH" -ForegroundColor Gray

            # Run mingw-bundledlls to get list of dependencies
            try {
                $dllList = & $python $bundledllsScript $AppExe 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "mingw-bundledlls failed with exit code $LASTEXITCODE"
                    Write-Warning $dllList
                }
                else {
                    $dllPaths = $dllList -split "`n" | Where-Object { $_ -and $_.Trim() }
                    $copiedCount = 0
                    $skippedCount = 0

                    foreach ($dllPath in $dllPaths) {
                        $dllPath = $dllPath.Trim()
                        if (-not $dllPath) { continue }

                        $dllName = Split-Path -Leaf $dllPath
                        $targetPath = Join-Path $SourceDir $dllName

                        # Check if DLL should be excluded
                        $exclude = $false
                        foreach ($excludePattern in $Config.exclude_files) {
                            if ($dllName -like $excludePattern) {
                                $exclude = $true
                                break
                            }
                        }

                        if ($exclude) {
                            Write-Host "  - $dllName (excluded)" -ForegroundColor DarkGray
                            $skippedCount++
                            continue
                        }

                        # Copy if not already present
                        if (-not (Test-Path $targetPath)) {
                            Copy-Item -Path $dllPath -Destination $targetPath -Force
                            Write-Host "  + $dllName" -ForegroundColor Gray
                            $copiedCount++
                        }
                    }

                    Write-Host "Copied $copiedCount DLLs, skipped $skippedCount (excluded or already present)" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "Error running mingw-bundledlls: $_"
            }
        }
    }
}

# Clean if requested
if ($Clean -and (Test-Path $DistDir)) {
    Write-Host "`nCleaning existing dist directory..." -ForegroundColor Yellow
    Remove-Item -Path $DistDir -Recurse -Force
}

# Create dist directory
if (-not (Test-Path $DistDir)) {
    New-Item -Path $DistDir -ItemType Directory -Force | Out-Null
}

Write-Host "`n=== Copying root files ===" -ForegroundColor Cyan

# Copy root files matching patterns
foreach ($pattern in $Config.root_files.include) {
    $files = Get-ChildItem -Path $SourceDir -Filter $pattern -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        # Skip files matching exclude patterns
        $exclude = $false
        foreach ($excludePattern in $Config.exclude_files) {
            if ($file.Name -like $excludePattern) {
                $exclude = $true
                break
            }
        }
        if (-not $exclude) {
            Copy-Item -Path $file.FullName -Destination $DistDir -Force
            Write-Host "  + $($file.Name)" -ForegroundColor Gray
        }
    }
}

Write-Host "`n=== Copying directories ===" -ForegroundColor Cyan

# Copy included directories (full copy)
foreach ($dir in $Config.include_dirs) {
    $srcPath = Join-Path $SourceDir $dir
    if (Test-Path $srcPath) {
        $destPath = Join-Path $DistDir $dir
        Copy-Item -Path $srcPath -Destination $destPath -Recurse -Force
        $files = @(Get-ChildItem -Path $destPath -Recurse -File -ErrorAction SilentlyContinue)
        $count = $files.Count
        Write-Host "  + $dir/ ($count files)" -ForegroundColor Gray
    }
    else {
        Write-Host "  - $dir/ (not found, skipping)" -ForegroundColor DarkGray
    }
}

Write-Host "`n=== Copying fonts (filtered) ===" -ForegroundColor Cyan

# Copy fonts with include filter
$fontsSrc = Join-Path $SourceDir "fonts"
$fontsDest = Join-Path $DistDir "fonts"
if (Test-Path $fontsSrc) {
    New-Item -Path $fontsDest -ItemType Directory -Force | Out-Null
    $fontCount = 0
    foreach ($pattern in $Config.fonts.include) {
        $fonts = Get-ChildItem -Path $fontsSrc -Filter $pattern -File -ErrorAction SilentlyContinue
        foreach ($font in $fonts) {
            Copy-Item -Path $font.FullName -Destination $fontsDest -Force
            $fontCount++
        }
    }
    Write-Host "  + fonts/ ($fontCount files matching patterns)" -ForegroundColor Gray
}

Write-Host "`n=== Copying Qt translations (filtered) ===" -ForegroundColor Cyan

# Copy Qt translations with include filter
$transSrc = Join-Path $SourceDir "translations"
$transDest = Join-Path $DistDir "translations"
if (Test-Path $transSrc) {
    New-Item -Path $transDest -ItemType Directory -Force | Out-Null
    $transCount = 0
    foreach ($file in $Config.qt_translations.include) {
        $srcFile = Join-Path $transSrc $file
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination $transDest -Force
            $transCount++
        }
    }
    Write-Host "  + translations/ ($transCount files)" -ForegroundColor Gray
}

Write-Host "`n=== Copying config files ===" -ForegroundColor Cyan

# Copy config files (crui.ini etc.)
if ($Config.config_files -and $Config.config_files.include) {
    $configDestDir = Join-Path $DistDir $Config.config_files.dest_dir
    New-Item -Path $configDestDir -ItemType Directory -Force | Out-Null
    $configCount = 0
    foreach ($file in $Config.config_files.include) {
        $srcFile = Join-Path $SourceDir $file
        if (Test-Path $srcFile) {
            $destFile = Join-Path $configDestDir (Split-Path -Leaf $file)
            Copy-Item -Path $srcFile -Destination $destFile -Force
            Write-Host "  + $file" -ForegroundColor Gray
            $configCount++
        }
        else {
            Write-Host "  - $file (not found, skipping)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n=== Distribution Summary ===" -ForegroundColor Cyan

# Calculate sizes
$totalSize = 0
$fileCount = 0
Get-ChildItem -Path $DistDir -Recurse -File | ForEach-Object {
    $totalSize += $_.Length
    $fileCount++
}
$sizeMB = [math]::Round($totalSize / 1MB, 2)

Write-Host "Total files: $fileCount" -ForegroundColor White
Write-Host "Total size: $sizeMB MB" -ForegroundColor White

# List excluded directories that exist in source but weren't copied
Write-Host "`nExcluded directories:" -ForegroundColor DarkGray
foreach ($dir in $Config.exclude_dirs) {
    $srcPath = Join-Path $SourceDir $dir
    if (Test-Path $srcPath) {
        Write-Host "  - $dir/" -ForegroundColor DarkGray
    }
}

# Create ZIP archive
if (-not $NoZip) {
    Write-Host "`n=== Creating ZIP archive ===" -ForegroundColor Cyan

    $zipName = "$($Config.app_name)-$Version-win64-portable.zip"
    $zipPath = Join-Path $ProjectRoot $zipName

    # Remove existing ZIP
    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force
    }

    # Create ZIP
    Compress-Archive -Path "$DistDir\*" -DestinationPath $zipPath -CompressionLevel Optimal

    $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Host "Created: $zipName ($zipSize MB)" -ForegroundColor Green
    Write-Host "Location: $zipPath" -ForegroundColor Gray
}

# Create 7z archive (if 7za/7z is available)
if (-not $No7z) {
    $sevenZip = Find-7za
    if (-not $sevenZip) {
        Write-Host "`n7za.exe/7z.exe not found, skipping 7z archive" -ForegroundColor DarkGray
    }
    else {
        Write-Host "`n=== Creating 7z archive ===" -ForegroundColor Cyan
        Write-Host "Using: $sevenZip" -ForegroundColor Gray

        $szName = "$($Config.app_name)-$Version-win64-portable.7z"
        $szPath = Join-Path $ProjectRoot $szName

        # Remove existing 7z
        if (Test-Path $szPath) {
            Remove-Item -Path $szPath -Force
        }

        # Create 7z with maximum compression
        # -t7z: 7z format, -mx=9: max compression, -mfb=273: max word size, -ms=on: solid archive
        $szArgs = @("a", "-t7z", "-mx=9", "-mfb=273", "-ms=on", $szPath, "$DistDir\*")
        $process = Start-Process -FilePath $sevenZip -ArgumentList $szArgs -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            Write-Warning "7z returned exit code $($process.ExitCode)"
        }
        else {
            $szSize = [math]::Round((Get-Item $szPath).Length / 1MB, 2)
            Write-Host "Created: $szName ($szSize MB)" -ForegroundColor Green
            Write-Host "Location: $szPath" -ForegroundColor Gray
        }
    }
}

Write-Host "`n=== Done ===" -ForegroundColor Green
