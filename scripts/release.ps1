<#
.SYNOPSIS
    Automate the cr2xt release pipeline: version bump, build, verify, release, upload.

.DESCRIPTION
    Five-stage linear pipeline with resumability via -StartFrom:
      1. VersionBump - Update CMakeLists.txt, commit, tag, push
      2. Build       - Run build-dist-all.ps1 with smart artifact skipping
      3. Verify      - Check dist/ artifacts for completeness
      4. Release     - Create draft GitHub release with notes
      5. Upload      - Upload artifacts to the GitHub release

    Each stage prints a resume command on failure.

.PARAMETER Version
    Target version (e.g. "0.9.3" or "v0.9.3"). Required for VersionBump unless -Bump is used.
    Optional for later stages (reads from CMakeLists.txt).

.PARAMETER Bump
    Auto-increment: "major", "minor", or "patch". Alternative to -Version.

.PARAMETER StartFrom
    Stage to start from. Default: VersionBump.

.PARAMETER StopAfter
    Stage to stop after. Default: Upload (run all remaining stages).

.PARAMETER Only
    Run a single stage. Shorthand for -StartFrom X -StopAfter X.

.PARAMETER SkipLinux
    Skip Linux AppImage build and verification.

.PARAMETER SkipMacOS
    Skip macOS DMG build and verification.

.PARAMETER SkipWindows
    Skip Windows portable build and verification.

.PARAMETER DryRun
    Preview all actions without executing them.

.PARAMETER Yes
    Skip all confirmation prompts (assume "yes"). Required for non-interactive runs.

.PARAMETER Force
    Force rebuild all platforms even if artifacts already exist.

.PARAMETER Retag
    Move an existing version tag to the current HEAD. Deletes the old tag (local + remote)
    and re-creates it. Fails if a published (non-draft) GitHub release exists for that version.
    Can be used without -Version/-Bump to retag the current version.

.PARAMETER ReleaseNotesFile
    Path to a .md file for release notes. Default: .claude/docs/release-v{version}.md.

.EXAMPLE
    .\release.ps1 -Version 0.9.3
    Full release pipeline for version 0.9.3.

.EXAMPLE
    .\release.ps1 -Bump patch
    Auto-increment patch version and run full pipeline.

.EXAMPLE
    .\release.ps1 -StartFrom Build
    Resume from build stage (reads version from CMakeLists.txt).

.EXAMPLE
    .\release.ps1 -DryRun -Version 0.9.3
    Preview all stages without executing.

.EXAMPLE
    .\release.ps1 -Only VersionBump -Bump patch
    Only bump the version, don't build or release.

.EXAMPLE
    .\release.ps1 -StartFrom Build -StopAfter Verify
    Build and verify, but don't create a release.

.EXAMPLE
    .\release.ps1 -Retag -Version 0.9.3
    Move the v0.9.3 tag to the current HEAD (no version bump).

.EXAMPLE
    .\release.ps1 -Retag
    Re-tag current version on HEAD (reads version from CMakeLists.txt).
#>

[CmdletBinding()]
param(
    [string]$Version,

    [ValidateSet("major", "minor", "patch")]
    [string]$Bump,

    [ValidateSet("VersionBump", "Build", "Verify", "Release", "Upload")]
    [string]$StartFrom = "VersionBump",

    [ValidateSet("VersionBump", "Build", "Verify", "Release", "Upload")]
    [string]$StopAfter = "Upload",

    [ValidateSet("VersionBump", "Build", "Verify", "Release", "Upload")]
    [string]$Only,

    [switch]$SkipLinux,
    [switch]$SkipMacOS,
    [switch]$SkipWindows,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Force,
    [switch]$Retag,
    [string]$ReleaseNotesFile
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# --- Ordered stage list for range execution ---
$StageOrder = @("VersionBump", "Build", "Verify", "Release", "Upload")

# -Only is shorthand for -StartFrom X -StopAfter X
if ($Only) {
    $StartFrom = $Only
    $StopAfter = $Only
}

function Should-RunStage([string]$StageName) {
    $startIdx = $StageOrder.IndexOf($StartFrom)
    $stopIdx  = $StageOrder.IndexOf($StopAfter)
    $stageIdx = $StageOrder.IndexOf($StageName)
    return ($stageIdx -ge $startIdx) -and ($stageIdx -le $stopIdx)
}

# --- Utility functions ---

function Get-CurrentVersion {
    $cmakePath = Join-Path $ProjectRoot "CMakeLists.txt"
    $content = Get-Content $cmakePath -Raw
    $major = if ($content -match 'set\(CR2XT_VERSION_MAJOR\s+(\d+)\)') { [int]$Matches[1] } else { 0 }
    $minor = if ($content -match 'set\(CR2XT_VERSION_MINOR\s+(\d+)\)') { [int]$Matches[1] } else { 0 }
    $patch = if ($content -match 'set\(CR2XT_VERSION_PATCH\s+(\d+)\)') { [int]$Matches[1] } else { 0 }
    return @{ Major = $major; Minor = $minor; Patch = $patch; String = "$major.$minor.$patch" }
}

function Get-GitHash {
    Push-Location $ProjectRoot
    try {
        $hash = git rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        return $hash.Trim()
    }
    finally { Pop-Location }
}

function Normalize-Version([string]$ver) {
    $ver = $ver.TrimStart("v")
    if ($ver -notmatch '^\d+\.\d+\.\d+$') {
        Write-Error "Invalid version format: '$ver'. Expected X.Y.Z"
        exit 1
    }
    return $ver
}

function Parse-Version([string]$ver) {
    $parts = $ver.Split(".")
    return @{ Major = [int]$parts[0]; Minor = [int]$parts[1]; Patch = [int]$parts[2]; String = $ver }
}

function Format-Duration($duration) {
    if ($null -eq $duration) { return "-" }
    if ($duration.TotalMinutes -ge 1) {
        return "{0:N1} min" -f $duration.TotalMinutes
    }
    return "{0:N1} sec" -f $duration.TotalSeconds
}

function Format-FileSize([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N1} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

function Write-StageHeader([string]$title) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-ResumeHint([string]$stage, [string]$message) {
    Write-Host ""
    Write-Host "ERROR: $message" -ForegroundColor Red
    Write-Host "To resume: .\release.ps1 -StartFrom $stage" -ForegroundColor Yellow
    Write-Host ""
}

# --- Resolve target version ---

$currentVer = Get-CurrentVersion

if ($StartFrom -eq "VersionBump") {
    # Need either -Version or -Bump
    if ($Version -and $Bump) {
        Write-Error "Specify either -Version or -Bump, not both."
        exit 1
    }
    if (-not $Version -and -not $Bump) {
        if ($Retag) {
            $targetVersion = $currentVer.String
        }
        else {
            Write-Error "Specify -Version or -Bump for the VersionBump stage."
            exit 1
        }
    }

    if ($Version) {
        $targetVersion = Normalize-Version $Version
    }
    elseif ($Bump) {
        # Auto-increment
        $newMajor = $currentVer.Major
        $newMinor = $currentVer.Minor
        $newPatch = $currentVer.Patch
        switch ($Bump) {
            "major" { $newMajor++; $newMinor = 0; $newPatch = 0 }
            "minor" { $newMinor++; $newPatch = 0 }
            "patch" { $newPatch++ }
        }
        $targetVersion = "$newMajor.$newMinor.$newPatch"
    }
}
else {
    # Later stages: -Version is optional, default to CMakeLists.txt
    if ($Version) {
        $targetVersion = Normalize-Version $Version
    }
    else {
        $targetVersion = $currentVer.String
    }
}

$targetParsed = Parse-Version $targetVersion

# --- Header ---

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  cr2xt Release Pipeline" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Version:    $targetVersion" -ForegroundColor White
$stageRange = if ($StartFrom -eq $StopAfter) { $StartFrom } elseif ($StopAfter -ne "Upload") { "$StartFrom .. $StopAfter" } else { $StartFrom }
Write-Host "  Stages:     $stageRange" -ForegroundColor White
if ($DryRun) { Write-Host "  Mode:       DRY RUN" -ForegroundColor Yellow }
if ($Retag)  { Write-Host "  Retag:      move tag to current HEAD" -ForegroundColor Yellow }
if ($Force)  { Write-Host "  Force:      rebuild all platforms" -ForegroundColor Yellow }

$skipPlatforms = @()
if ($SkipLinux)   { $skipPlatforms += "Linux" }
if ($SkipMacOS)   { $skipPlatforms += "macOS" }
if ($SkipWindows) { $skipPlatforms += "Windows" }
if ($skipPlatforms.Count -gt 0) {
    Write-Host "  Skipping:   $($skipPlatforms -join ', ')" -ForegroundColor DarkGray
}
Write-Host ""

$overallStart = Get-Date

# ============================================================
# Stage 1: VersionBump
# ============================================================

if (Should-RunStage "VersionBump") {
    Write-StageHeader "Stage 1/5: Version Bump"

    Write-Host "  Current version: $($currentVer.String)" -ForegroundColor Gray
    Write-Host "  Target version:  $targetVersion" -ForegroundColor White

    if ($currentVer.String -eq $targetVersion -and -not $Retag) {
        Write-Error "Target version $targetVersion is the same as current version. Use -Retag to move the tag to HEAD."
        exit 1
    }

    # Safety checks
    Push-Location $ProjectRoot
    try {
        $safetyIssues = @()

        # Clean working tree
        $status = git status --porcelain 2>$null
        if ($status) { $safetyIssues += "Working tree is not clean. Commit or stash changes first." }

        # On main branch
        $branch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
        if ($branch -ne "main") { $safetyIssues += "Not on main branch (current: $branch). Switch to main first." }

        # Tag doesn't exist (or -Retag handles it)
        $existingTag = git tag -l "v$targetVersion" 2>$null
        if ($existingTag) {
            if ($Retag) {
                # Block retag if a published (non-draft) release exists
                $ghAvailable = Get-Command "gh" -ErrorAction SilentlyContinue
                if ($ghAvailable) {
                    $isDraft = gh release view "v$targetVersion" --json isDraft -q ".isDraft" 2>$null
                    if ($LASTEXITCODE -eq 0 -and $isDraft -eq "false") {
                        $safetyIssues += "Tag v$targetVersion has a published release. Delete or unpublish it first."
                    }
                }
            }
            else {
                $safetyIssues += "Tag v$targetVersion already exists. Use -Retag to move it to HEAD."
            }
        }

        if ($safetyIssues.Count -gt 0) {
            if ($DryRun) {
                foreach ($issue in $safetyIssues) {
                    Write-Host "  [DRY RUN WARNING] $issue" -ForegroundColor Yellow
                }
            }
            else {
                foreach ($issue in $safetyIssues) { Write-Error $issue }
                exit 1
            }
        }
    }
    finally { Pop-Location }

    $versionChanged = $currentVer.String -ne $targetVersion

    # Confirm
    if (-not $DryRun) {
        Write-Host ""
        if ($Retag -and -not $versionChanged) {
            Write-Host "  Will re-tag v$targetVersion on current HEAD and push." -ForegroundColor Yellow
        }
        elseif ($Retag) {
            Write-Host "  Will bump $($currentVer.String) -> $targetVersion, re-tag on HEAD, and push." -ForegroundColor Yellow
        }
        else {
            Write-Host "  Will bump $($currentVer.String) -> $targetVersion, commit, tag, and push." -ForegroundColor Yellow
        }
        if (-not $Yes) {
            $confirm = Read-Host "  Proceed? [y/N]"
            if ($confirm -notmatch '^[Yy]') {
                Write-Host "  Aborted." -ForegroundColor DarkGray
                exit 0
            }
        }
    }

    # Update CMakeLists.txt (only if version actually changes)
    $cmakePath = Join-Path $ProjectRoot "CMakeLists.txt"
    if ($versionChanged) {
        $cmakeContent = Get-Content $cmakePath -Raw
        $cmakeContent = $cmakeContent -replace '(set\(CR2XT_VERSION_MAJOR\s+)\d+\)', "`${1}$($targetParsed.Major))"
        $cmakeContent = $cmakeContent -replace '(set\(CR2XT_VERSION_MINOR\s+)\d+\)', "`${1}$($targetParsed.Minor))"
        $cmakeContent = $cmakeContent -replace '(set\(CR2XT_VERSION_PATCH\s+)\d+\)', "`${1}$($targetParsed.Patch))"
    }

    if ($DryRun) {
        if ($versionChanged) {
            Write-Host "  [DRY RUN] Would update CMakeLists.txt:" -ForegroundColor Yellow
            Write-Host "    CR2XT_VERSION_MAJOR = $($targetParsed.Major)"
            Write-Host "    CR2XT_VERSION_MINOR = $($targetParsed.Minor)"
            Write-Host "    CR2XT_VERSION_PATCH = $($targetParsed.Patch)"
        }
        if ($Retag) {
            Write-Host "  [DRY RUN] Would delete existing tag v$targetVersion and re-create on HEAD." -ForegroundColor Yellow
        }
        Write-Host "  [DRY RUN] Would commit, tag v$targetVersion, and push." -ForegroundColor Yellow
    }
    else {
        Push-Location $ProjectRoot
        try {
            # Commit version bump if needed
            if ($versionChanged) {
                Set-Content -Path $cmakePath -Value $cmakeContent -NoNewline

                git add CMakeLists.txt
                if ($LASTEXITCODE -ne 0) { Write-Error "git add failed"; exit 1 }

                git commit -m "chore(cmake): bump version to $targetVersion"
                if ($LASTEXITCODE -ne 0) { Write-Error "git commit failed"; exit 1 }
            }

            # Delete existing tag if retagging
            if ($Retag) {
                $oldTag = git tag -l "v$targetVersion" 2>$null
                if ($oldTag) {
                    Write-Host "  Deleting existing tag v$targetVersion..." -ForegroundColor Yellow
                    git tag -d "v$targetVersion" 2>$null
                    git push origin ":refs/tags/v$targetVersion" 2>$null
                }
            }

            # --no-sign: tag.gpgsign=true would force an annotated tag (and fail
            # non-interactively); releases use lightweight tags
            git tag --no-sign "v$targetVersion"
            if ($LASTEXITCODE -ne 0) { Write-Error "git tag failed"; exit 1 }

            git push origin main --tags
            if ($LASTEXITCODE -ne 0) {
                Write-ResumeHint "VersionBump" "git push failed. Fix the issue, then re-run."
                exit 1
            }
        }
        finally { Pop-Location }

        if ($Retag -and -not $versionChanged) {
            Write-Host "  Re-tagged v$targetVersion on current HEAD and pushed." -ForegroundColor Green
        }
        else {
            Write-Host "  Version bumped, committed, tagged v$targetVersion, and pushed." -ForegroundColor Green
        }
    }
}

# ============================================================
# Stage 2: Build
# ============================================================

if (Should-RunStage "Build") {
    Write-StageHeader "Stage 2/5: Build"

    $gitHash = Get-GitHash
    $distDir = Join-Path $ProjectRoot "dist"
    Write-Host "  Git hash: $gitHash" -ForegroundColor Gray

    # Define expected artifacts per platform
    $platformArtifacts = @{
        Linux   = @("cr2xt-$targetVersion-*-linux-x86_64.AppImage")
        MacOS   = @("cr2xt-$targetVersion-*-macos-universal.dmg")
        Windows = @("cr2xt-$targetVersion-*-win64-portable.zip", "cr2xt-$targetVersion-*-win64-portable.7z")
    }

    # Check which platforms already have artifacts with matching version AND hash
    $autoSkip = @{ Linux = $false; MacOS = $false; Windows = $false }

    if (-not $Force -and (Test-Path $distDir)) {
        foreach ($platform in @("Linux", "MacOS", "Windows")) {
            $patterns = $platformArtifacts[$platform]
            $allFound = $true
            $foundFiles = @()

            foreach ($pattern in $patterns) {
                # Check for exact hash match
                $exactPattern = $pattern -replace '\*', $gitHash
                $matches = Get-ChildItem -Path $distDir -Filter $exactPattern -ErrorAction SilentlyContinue
                if ($matches) {
                    $foundFiles += $matches.Name
                }
                else {
                    $allFound = $false
                    break
                }
            }

            if ($allFound -and $foundFiles.Count -gt 0) {
                $autoSkip[$platform] = $true
                $displayName = switch ($platform) { "MacOS" { "macOS" }; default { $platform } }
                foreach ($f in $foundFiles) {
                    Write-Host "  $displayName`: already built ($f), skipping" -ForegroundColor DarkGray
                }
            }
        }
    }

    # Merge auto-skip with user-provided skip flags
    $buildSkipLinux   = $SkipLinux.IsPresent   -or $autoSkip.Linux
    $buildSkipMacOS   = $SkipMacOS.IsPresent   -or $autoSkip.MacOS
    $buildSkipWindows = $SkipWindows.IsPresent  -or $autoSkip.Windows

    if ($buildSkipLinux -and $buildSkipMacOS -and $buildSkipWindows) {
        Write-Host "  All platform artifacts already exist. Nothing to build." -ForegroundColor Green
        if (-not $SkipLinux -and -not $SkipMacOS -and -not $SkipWindows) {
            Write-Host "  Use -Force to rebuild all platforms." -ForegroundColor DarkGray
        }
    }
    else {
        $buildScript = Join-Path $ScriptDir "build-dist-all.ps1"
        if (-not (Test-Path $buildScript)) {
            Write-Error "Build script not found: $buildScript"
            exit 1
        }

        $buildArgs = @{ Clean = $true }
        if ($buildSkipLinux)   { $buildArgs.SkipLinux   = $true }
        if ($buildSkipMacOS)   { $buildArgs.SkipMacOS   = $true }
        if ($buildSkipWindows) { $buildArgs.SkipWindows = $true }

        $buildPlatforms = @()
        if (-not $buildSkipLinux)   { $buildPlatforms += "Linux" }
        if (-not $buildSkipMacOS)   { $buildPlatforms += "macOS" }
        if (-not $buildSkipWindows) { $buildPlatforms += "Windows" }
        Write-Host "  Building: $($buildPlatforms -join ', ')" -ForegroundColor White

        if ($DryRun) {
            $argsStr = ($buildArgs.GetEnumerator() | ForEach-Object {
                if ($_.Value -eq $true) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value)" }
            }) -join ' '
            Write-Host "  [DRY RUN] Would execute:" -ForegroundColor Yellow
            Write-Host "    & `"$buildScript`" $argsStr" -ForegroundColor Cyan
        }
        else {
            $buildStart = Get-Date
            try {
                & $buildScript @buildArgs
                if ($LASTEXITCODE -ne 0) {
                    Write-ResumeHint "Build" "Build failed (exit code: $LASTEXITCODE). Existing artifacts in dist/ are preserved."
                    exit 1
                }
            }
            catch {
                Write-ResumeHint "Build" "Build failed: $_. Existing artifacts in dist/ are preserved."
                exit 1
            }
            $buildDuration = (Get-Date) - $buildStart
            Write-Host ""
            Write-Host "  Build completed in $(Format-Duration $buildDuration)." -ForegroundColor Green
        }
    }
}

# ============================================================
# Stage 3: Verify
# ============================================================

if (Should-RunStage "Verify") {
    Write-StageHeader "Stage 3/5: Verify Artifacts"

    $gitHash = Get-GitHash
    $distDir = Join-Path $ProjectRoot "dist"

    if (-not (Test-Path $distDir)) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] dist/ directory not found (expected - build hasn't run)." -ForegroundColor Yellow
            Write-Host ""
        }
        else {
            Write-ResumeHint "Build" "dist/ directory not found. Run the Build stage first."
            exit 1
        }
    }

    # Define required artifacts per platform
    $required = @()
    if (-not $SkipLinux) {
        $required += @{ Platform = "Linux"; Pattern = "cr2xt-$targetVersion-*-linux-x86_64.AppImage" }
    }
    if (-not $SkipMacOS) {
        $required += @{ Platform = "macOS"; Pattern = "cr2xt-$targetVersion-*-macos-universal.dmg" }
    }
    if (-not $SkipWindows) {
        $required += @{ Platform = "Windows (zip)"; Pattern = "cr2xt-$targetVersion-*-win64-portable.zip" }
        $required += @{ Platform = "Windows (7z)";  Pattern = "cr2xt-$targetVersion-*-win64-portable.7z" }
    }

    $verified = @()
    $missing = @()

    foreach ($req in $required) {
        $found = Get-ChildItem -Path $distDir -Filter $req.Pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) {
            $size = Format-FileSize $found.Length

            # Check if hash matches HEAD
            $hashWarning = ""
            if ($found.Name -match "cr2xt-$([regex]::Escape($targetVersion))-([a-f0-9]+)-") {
                $fileHash = $Matches[1]
                if ($fileHash -ne $gitHash) {
                    $hashWarning = " (WARNING: hash $fileHash != HEAD $gitHash)"
                }
            }

            $verified += $found
            Write-Host "  OK  $($req.Platform.PadRight(16)) $($found.Name)  [$size]$hashWarning" -ForegroundColor Green
        }
        else {
            $missing += $req
            Write-Host "  MISSING  $($req.Platform.PadRight(16)) $($req.Pattern)" -ForegroundColor Red
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host ""
        if ($DryRun) {
            Write-Host "  [DRY RUN] $($missing.Count) artifact(s) missing (expected - build hasn't run)." -ForegroundColor Yellow
        }
        else {
            Write-ResumeHint "Build" "$($missing.Count) artifact(s) missing. Run the Build stage to create them."
            exit 1
        }
    }
    else {
        Write-Host ""
        Write-Host "  All $($verified.Count) artifact(s) verified." -ForegroundColor Green
    }

    # Store verified files for later stages
    $script:VerifiedArtifacts = $verified
}

# ============================================================
# Stage 4: Release
# ============================================================

if (Should-RunStage "Release") {
    Write-StageHeader "Stage 4/5: Create GitHub Release"

    # Check gh CLI
    $ghCmd = Get-Command "gh" -ErrorAction SilentlyContinue
    if (-not $ghCmd) {
        Write-Error "GitHub CLI (gh) not found. Install it from https://cli.github.com/"
        exit 1
    }

    # Resolve release notes
    $notesFile = $null
    $notesContent = $null

    if ($ReleaseNotesFile) {
        if (-not (Test-Path $ReleaseNotesFile)) {
            Write-Error "Release notes file not found: $ReleaseNotesFile"
            exit 1
        }
        $notesFile = $ReleaseNotesFile
        Write-Host "  Using release notes: $notesFile" -ForegroundColor Gray
    }
    else {
        $defaultNotes = Join-Path (Join-Path (Join-Path $ProjectRoot ".claude") "docs") "release-v$targetVersion.md"
        if (Test-Path $defaultNotes) {
            $notesFile = $defaultNotes
            Write-Host "  Using release notes: $defaultNotes" -ForegroundColor Gray
        }
        else {
            Write-Host "  No release notes file found. Auto-generating from git log..." -ForegroundColor Yellow

            # Find previous tag
            Push-Location $ProjectRoot
            try {
                $allTags = git tag -l 'v*' --sort=-v:refname 2>$null
                if ($allTags) {
                    if ($allTags -is [string]) { $allTags = @($allTags) }
                    $prevTag = ($allTags | Where-Object { $_ -ne "v$targetVersion" } | Select-Object -First 1)
                }
                else {
                    $prevTag = $null
                }
            }
            finally { Pop-Location }

            # Use HEAD if target tag doesn't exist yet (e.g. dry run)
            Push-Location $ProjectRoot
            try {
                $tagExists = git tag -l "v$targetVersion" 2>$null
            }
            finally { Pop-Location }
            $rangeEnd = if ($tagExists) { "v$targetVersion" } else { "HEAD" }

            $range = if ($prevTag) { "$prevTag..$rangeEnd" } else { $rangeEnd }
            Write-Host "  Commit range: $range" -ForegroundColor Gray

            Push-Location $ProjectRoot
            try {
                $commits = git log --format="%s" $range 2>$null
            }
            finally { Pop-Location }

            if (-not $commits) { $commits = @() }
            if ($commits -is [string]) { $commits = @($commits) }

            # Group by conventional commit type
            $groups = [ordered]@{
                "New Features"   = @()
                "Bug Fixes"      = @()
                "Improvements"   = @()
                "Other"          = @()
            }

            $submoduleOnly = $true

            foreach ($msg in $commits) {
                # Skip version bump commits
                if ($msg -match 'chore\(cmake\):\s*bump') { continue }

                $isSubmodule = $msg -match 'update submodule'

                if ($msg -match '^feat[\(:]') {
                    $clean = $msg -replace '^feat(\([^)]*\))?:\s*', ''
                    $groups["New Features"] += "- $clean"
                    if (-not $isSubmodule) { $submoduleOnly = $false }
                }
                elseif ($msg -match '^fix[\(:]') {
                    $clean = $msg -replace '^fix(\([^)]*\))?:\s*', ''
                    $groups["Bug Fixes"] += "- $clean"
                    if (-not $isSubmodule) { $submoduleOnly = $false }
                }
                elseif ($msg -match '^(refactor|perf|style)[\(:]') {
                    $clean = $msg -replace '^(refactor|perf|style)(\([^)]*\))?:\s*', ''
                    $groups["Improvements"] += "- $clean"
                    if (-not $isSubmodule) { $submoduleOnly = $false }
                }
                elseif ($msg -notmatch '^(docs|chore|ci|build|test)[\(:]') {
                    $groups["Other"] += "- $msg"
                    if (-not $isSubmodule) { $submoduleOnly = $false }
                }
            }

            # Build notes
            $lines = @("# cr2xt $targetVersion", "")

            if ($submoduleOnly -and ($groups.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum -gt 0) {
                $lines += "Various engine and UI improvements."
                $lines += ""
            }

            foreach ($section in $groups.Keys) {
                if ($groups[$section].Count -gt 0) {
                    $lines += "## $section"
                    $lines += ""
                    $lines += $groups[$section]
                    $lines += ""
                }
            }

            $notesContent = $lines -join "`n"
        }
    }

    # Read notes from file if we have one
    if ($notesFile -and -not $notesContent) {
        $notesContent = Get-Content $notesFile -Raw
    }

    # Preview
    Write-Host ""
    Write-Host "  --- Release Notes Preview ---" -ForegroundColor DarkGray
    $notesContent.Split("`n") | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    Write-Host "  --- End Preview ---" -ForegroundColor DarkGray

    if (-not $DryRun -and -not $Yes) {
        Write-Host ""
        $confirm = Read-Host "  Create draft release v$targetVersion? [y/N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "  Aborted." -ForegroundColor DarkGray
            exit 0
        }
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "  [DRY RUN] Would create draft release v$targetVersion on GitHub." -ForegroundColor Yellow
    }
    else {
        # Write notes to temp file for gh
        $tempNotes = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tempNotes -Value $notesContent -NoNewline

            Push-Location $ProjectRoot
            try {
                gh release create "v$targetVersion" --draft --title "cr2xt $targetVersion" --notes-file $tempNotes
                if ($LASTEXITCODE -ne 0) {
                    Write-ResumeHint "Release" "gh release create failed. Check 'gh auth status' and retry."
                    exit 1
                }
            }
            finally { Pop-Location }
        }
        finally {
            Remove-Item $tempNotes -ErrorAction SilentlyContinue
        }

        Write-Host "  Draft release v$targetVersion created." -ForegroundColor Green
    }
}

# ============================================================
# Stage 5: Upload
# ============================================================

if (Should-RunStage "Upload") {
    Write-StageHeader "Stage 5/5: Upload Artifacts"

    $distDir = Join-Path $ProjectRoot "dist"

    # Re-discover artifacts (in case we resumed directly to Upload)
    $artifacts = @()

    if (-not $SkipLinux) {
        $found = Get-ChildItem -Path $distDir -Filter "cr2xt-$targetVersion-*-linux-x86_64.AppImage" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { $artifacts += $found }
    }
    if (-not $SkipMacOS) {
        $found = Get-ChildItem -Path $distDir -Filter "cr2xt-$targetVersion-*-macos-universal.dmg" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { $artifacts += $found }
    }
    if (-not $SkipWindows) {
        foreach ($ext in @("zip", "7z")) {
            $found = Get-ChildItem -Path $distDir -Filter "cr2xt-$targetVersion-*-win64-portable.$ext" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { $artifacts += $found }
        }
    }

    if ($artifacts.Count -eq 0) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] No artifacts found (expected - build hasn't run)." -ForegroundColor Yellow
        }
        else {
            Write-ResumeHint "Verify" "No artifacts found for v$targetVersion in dist/. Run Verify stage first."
            exit 1
        }
    }

    Write-Host "  Uploading $($artifacts.Count) artifact(s) to release v${targetVersion}:" -ForegroundColor White

    foreach ($artifact in $artifacts) {
        $size = Format-FileSize $artifact.Length
        Write-Host "    $($artifact.Name)  [$size]" -ForegroundColor Gray

        if (-not $DryRun) {
            Push-Location $ProjectRoot
            try {
                gh release upload "v$targetVersion" $artifact.FullName --clobber
                if ($LASTEXITCODE -ne 0) {
                    Write-ResumeHint "Upload" "Failed to upload $($artifact.Name). Retry with -StartFrom Upload."
                    exit 1
                }
            }
            finally { Pop-Location }

            Write-Host "      uploaded" -ForegroundColor Green
        }
        else {
            Write-Host "      [DRY RUN] would upload" -ForegroundColor Yellow
        }
    }

    # Print final URL
    if (-not $DryRun) {
        Write-Host ""
        Push-Location $ProjectRoot
        try {
            $releaseUrl = gh release view "v$targetVersion" --json url -q ".url" 2>$null
        }
        finally { Pop-Location }

        if ($releaseUrl) {
            Write-Host "  Draft release: $releaseUrl" -ForegroundColor Cyan
        }
    }

    Write-Host ""
    Write-Host "  All artifacts uploaded." -ForegroundColor Green
}

# --- Summary ---

$overallDuration = (Get-Date) - $overallStart

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Release Pipeline Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Version: $targetVersion" -ForegroundColor White
Write-Host "  Time:    $(Format-Duration $overallDuration)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Mode:    DRY RUN (no changes made)" -ForegroundColor Yellow
}
Write-Host ""
