#Requires -Version 5.1
param(
    [switch]$Check,
    [switch]$NoBuild,
    [switch]$Release,
    [switch]$UpstreamOnly,
    [switch]$Setup,
    [switch]$FixLpi,
    [switch]$ForceRebuild,
    [switch]$ResetConfig,
    [switch]$Doctor,
    [string]$VPDir,
    [switch]$SelfUpdated,
    [switch]$NoLaunch,
    [switch]$AllowPush,
    [switch]$KeepLocal,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LazarusDir = $ScriptDir

if ($Help) {
    Write-Host "Lazarus + VibePascal Auto-Updater (Windows)"
    Write-Host ""
    Write-Host "Usage: .\auto-update.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Check          Check for updates only (no pull, no build)"
    Write-Host "  -NoBuild        Pull updates but skip rebuild"
    Write-Host "  -Release        Also rebuild release tarballs after updating"
    Write-Host "  -UpstreamOnly   Only sync upstream Lazarus (skip VibePascal)"
    Write-Host "  -Setup          Configure Lazarus IDE to use VibePascal compiler"
    Write-Host "  -FixLpi         Scan and fix .lpi files (set UnitOutputDirectory to 'lib')"
    Write-Host "  -ForceRebuild   Force rebuild even if no updates are available"
    Write-Host "  -ResetConfig    Wipe %LOCALAPPDATA%\lazarus and re-run -Setup with a clean slate"
    Write-Host "  -Doctor         Diagnose toolchain + IDE config; report problems without changing state"
    Write-Host "  -VPDir <path>   Path to VibePascal source (auto-detected if omitted)"
    Write-Host "  -NoLaunch       Do not launch the IDE after a successful update/rebuild"
    Write-Host "  -AllowPush      Opt-in: push the post-upstream-merge result to origin/main."
    Write-Host "                  Default is no-push (per GOD directive 2026-05-16) -- merge stays local"
    Write-Host "                  to avoid background-process credential-prompt hangs and accidental"
    Write-Host "                  pushes from end-user boxes. BuildMaster ships releases, not clients."
    Write-Host "  -KeepLocal      Preserve uncommitted changes and untracked files in both repos."
    Write-Host "                  Use this when developing or testing updater changes so they are"
    Write-Host "                  not wiped by the pristine-test-env reset."
    Write-Host "  -Help           Show this help"
    Write-Host ""
    Write-Host "Default: pull updates, rebuild lazbuild + IDE if anything changed."
    exit 0
}

function Log-Info  { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Log-Ok    { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Log-Warn  { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Log-Err   { param($msg) $script:ErrorCount++; Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-ErrDetail { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }  # continuation line of an already-counted failure -- prints identically, does NOT increment ErrorCount
function Log-Header { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

$script:LazarusUpdated = $false
$script:VPUpdated = $false
$script:CheckFailed = $false   # a Check-* helper could not read or refresh a repository; "up to date" is then not a verdict (c675)
$script:UpstreamUpdated = $false
# c722 -- is an 'upstream' remote configured at all, and could it be read? Reported by Miles
# (MonitoringSystemsDeveloper) from MVMJ26, which has no such remote: the run correctly warns
# and skips the check, and then the summary prints "[-] Lazarus upstream : no changes (HEAD
# <sha>)" anyway -- where that sha is the ORIGIN head, because nothing ever looked upstream.
# Nothing in the line is false; it is reliably misread. NOT CHECKED is not "no changes" (c675).
$script:UpstreamConfigured = $false
$script:UpstreamUnknown = $false
$script:BuildProductsWereMissing = $false
$script:LocalBuildProductsRestored = $false
# c719 -- HEAD as it stood BEFORE this run pulled anything, so Print-Summary can report
# what HAPPENED instead of what was AVAILABLE. $null means git could not be read, which is
# UNKNOWN and never "no changes" (c675).
$script:LazarusHeadBefore = $null
$script:VPHeadBefore = $null
# c720 -- the VibePascal version as the dist named it BEFORE this run pulled anything, so
# Print-Summary can say "v53 -> v59" instead of leaving a pre-pull reading as the last word.
$script:VPVersionBefore = $null
$script:LazarusHeadAfterUpstream = $null   # set between the upstream merge and the origin pull, so the two lines are attributable to the right one
# c635: first compiler Error:/Fatal: line from the build attempt that INCLUDED commonx.
# Replayed in the final failure block so the causal line survives a top-truncated paste.
$script:CommonXFirstError = ""
$script:CommonXPpuHint = ""
$script:CommonXArtifactsCleaned = 0
$script:ErrorCount = 0
$script:MakeRejected = @()

# c671 -- REFUSE unbound arguments instead of silently running without them. A plain param()
# block drops anything it cannot bind into $args and carries on, so ".\auto-update.ps1
# -Check,-NoBuild" (ONE comma-joined token, the PowerShell array habit) bound NEITHER switch
# and ran the FULL pipeline -- Wipe-LocalChanges (reset --hard + clean -fdx), pull, IDE
# rebuild -- while auto-update.bat had classified that line read-only and left lazarus.exe
# running, because cmd's `for` splits the token on the comma. Measured on lazdev under
# pwsh 7.6.6 against this file; Steve's real-Windows matrix of 2026-09-16 surfaced the token.
if ($args.Count -gt 0) {
    Log-Err "Unrecognised argument(s): $($args -join ' ')"
    Log-ErrDetail "  Flags are separate, space-separated switches:  auto-update.bat -Check -NoBuild   (not -Check,-NoBuild)."
    Log-ErrDetail "  Refusing to run: an unbound flag would otherwise fall through to a FULL update (wipe + pull + rebuild)."
    Log-ErrDetail "  Run  auto-update.bat -Help  for the option list."
    exit 2
}

if (-not $VPDir -and $env:VPDIR -and (Test-Path (Join-Path $env:VPDIR ".git"))) {
    $VPDir = $env:VPDIR
    Log-Info "VibePascal: using `$env:VPDIR = $VPDir"
}

if (-not $VPDir) {
    $parent = Split-Path -Parent $LazarusDir
    $grandparent = if ($parent) { Split-Path -Parent $parent } else { $null }

    # Per Policy #22: canonical Pascal/FPC code location is {rootdir}\Pascal\FPC\.
    # Search sibling-of-Lazarus, Policy #22 layout, and common Windows roots.
    $candidates = @(
        # Sibling of Lazarus (simple/legacy layout)
        (Join-Path $parent "vibepascal"),
        (Join-Path $parent "VibePascal"),
        (Join-Path $parent "fpc"),
        (Join-Path $parent "fpcsrc")
    )
    # Policy #22 canonical: <parent>\Pascal\FPC\vibepascal
    $candidates += (Join-Path $parent "Pascal\FPC\vibepascal")
    $candidates += (Join-Path $parent "Pascal\FPC\VibePascal")
    $candidates += (Join-Path $parent "Pascal\FPC")
    if ($grandparent) {
        $candidates += (Join-Path $grandparent "Pascal\FPC\vibepascal")
        $candidates += (Join-Path $grandparent "Pascal\FPC\VibePascal")
        $candidates += (Join-Path $grandparent "Pascal\FPC")
    }
    # Common Windows roots
    $candidates += @(
        "C:\vibepascal",
        "C:\VibePascal",
        "C:\Pascal\FPC\vibepascal",
        "C:\Pascal\FPC\VibePascal",
        "C:\Pascal\FPC",
        "C:\source\vibepascal",
        "C:\source\VibePascal",
        "C:\source\Pascal\FPC\vibepascal",
        "C:\source\Pascal\FPC\VibePascal",
        "C:\source\Pascal\FPC",
        "C:\dev\vibepascal",
        "C:\dev\Pascal\FPC\vibepascal"
    )
    if ($env:USERPROFILE) {
        $candidates += @(
            (Join-Path $env:USERPROFILE "source\vibepascal"),
            (Join-Path $env:USERPROFILE "source\VibePascal"),
            (Join-Path $env:USERPROFILE "source\Pascal\FPC\vibepascal"),
            (Join-Path $env:USERPROFILE "source\Pascal\FPC")
        )
    }

    foreach ($c in $candidates) {
        if (-not (Test-Path (Join-Path $c ".git"))) { continue }
        # Sanity-check it actually looks like a vibepascal/FPC source tree
        # (must have at least one of: Makefile.fpc, compiler\, rtl\, vibepascal-*.cfg).
        $isVP = (Test-Path (Join-Path $c "Makefile.fpc")) -or `
                (Test-Path (Join-Path $c "compiler")) -or `
                (Test-Path (Join-Path $c "rtl")) -or `
                ((Get-ChildItem -Path $c -Filter "vibepascal-*.cfg" -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null)
        if ($isVP) {
            $VPDir = $c
            Log-Info "VibePascal auto-detected at: $VPDir"
            break
        }
    }
    if (-not $VPDir) {
        # GOD directive mp8vlvmq (2026-05-16): if VibePascal isn't anywhere on this machine,
        # materialize it from GitHub rather than bailing out. Canonical default: C:\vibepascal.
        $cloneTarget = "C:\vibepascal"
        $cloneRepo = "https://github.com/adaloveless/vibepascal.git"
        Log-Warn "VibePascal directory not found in any candidate path."

        if (Test-Path $cloneTarget) {
            Log-Err "$cloneTarget exists but lacks .git or VibePascal source markers -- refusing to clone over it."
            Log-Err "Move it aside (rename to ${cloneTarget}.bak) and re-run, or pass -VPDir."
            exit 1
        }

        Log-Info "Materializing VibePascal: git clone $cloneRepo -> $cloneTarget"
        $cloneParent = Split-Path -Parent $cloneTarget
        if ($cloneParent -and -not (Test-Path $cloneParent)) {
            New-Item -ItemType Directory -Path $cloneParent -Force | Out-Null
        }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & git clone $cloneRepo $cloneTarget 2>&1 | ForEach-Object { Write-Host $_ }
            $cloneExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEAP
        }

        if ($cloneExit -ne 0 -or -not (Test-Path (Join-Path $cloneTarget ".git"))) {
            Log-Err "git clone failed (exit $cloneExit) -- VibePascal could not be materialized."
            Log-ErrDetail "Searched: $($candidates -join ', ')"
            Log-ErrDetail ""
            Log-ErrDetail "How to fix manually:"
            Log-ErrDetail "  1. Clone next to Lazarus: git clone $cloneRepo ""$parent\vibepascal"""
            Log-ErrDetail "  2. Or pass the path:      .\auto-update.bat -VPDir C:\path\to\vibepascal"
            Log-ErrDetail "  3. Or set the env var:    setx VPDIR ""C:\path\to\vibepascal"" (then open a new shell)"
            exit 1
        }

        $VPDir = $cloneTarget
        Log-Ok "VibePascal materialized at: $VPDir"
    }
}

# Prefer bin\ppcx64.exe (tarball layout) over compiler\ppcx64.exe (legacy). When fpc reads its
# default config, $FPCBINDIR is derived from the running binary's directory -- the tarball's
# fpc.cfg expects $FPCBINDIR=bin/, so running from bin is the supported path.
$VPCompiler = Join-Path $VPDir "bin\ppcx64.exe"
if (-not (Test-Path $VPCompiler)) {
    $VPCompiler = Join-Path $VPDir "compiler\ppcx64.exe"
}
if (-not (Test-Path $VPCompiler)) {
    $VPCompiler = Join-Path $VPDir "compiler\ppcx64"
}

function Sort-VPArchives {
    param([object[]]$Items)
    # Parse -v## from filename and sort numerically descending; unversioned archives
    # fall behind and sort by LastWriteTime. Fresh git clones give all archives nearly
    # identical mtimes, so LastWriteTime alone is non-deterministic -- version number
    # is the authoritative ordering.
    #
    # Two naming conventions are supported:
    #   legacy (v23-v31):  vibepascal-win64-<sha>-v28.tar.gz       -- "-v28." at end
    #   v32+ split-archives: vibepascal-v32-rc-<sha>-win64-bin.tar.gz -- "-v32-" mid-name
    # The single regex '-v(\d+)[-.]' captures both: the version-number segment is
    # always preceded by '-v' and followed by '-' (new) or '.' (legacy).
    return $Items | Sort-Object `
        @{Expression = {
            if ($_.Name -match '-v(\d+)[-.]') { [int]$Matches[1] } else { -1 }
          }; Descending = $true}, `
        @{Expression = {$_.LastWriteTime}; Descending = $true}
}

function Read-LATESTTxt {
    # Parse LATEST.txt sidecar in dist/win64/. Returns a hashtable with parsed fields or $null on failure.
    # Expected format: key: value pairs (version, source_commit, dist_commit, versioned_tarball, tarball_md5, tarball_sha256, exe_md5, exe_sha256, date, notes).
    # LATEST.txt is the authoritative version SELECTOR while split-archive pairing stays intact.
    # If absent (older dist), caller falls back to Sort-VPArchives[0].
    param([string]$DistDir)
    $latestFile = Join-Path $DistDir "LATEST.txt"
    if (-not (Test-Path $latestFile)) { return $null }

    try {
        $content = Get-Content -Path $latestFile -Raw -ErrorAction Stop
        $result = @{}
        foreach ($line in $content -split "`n") {
            if ($line -match '^\s*(\w[\w\s]*):\s*(.+?)\s*$') {
                $key = $Matches[1].Trim().ToLower()
                $value = $Matches[2].Trim()
                $result[$key] = $value
            }
        }
        if ($result.ContainsKey('versioned_tarball')) { return $result }
        Log-Warn "LATEST.txt present but missing versioned_tarball field"
        return $null
    } catch {
        Log-Warn "Failed to read LATEST.txt at ${latestFile}: $_"
        return $null
    }
}

function Get-VPDistVersion {
    # c720 -- answer "which VibePascal is in place?" by READING THE SIDECAR OFF DISK at the
    # moment of the call, never from a variable set earlier in the run.
    #
    # Why this exists: Extract-VPBinaries logs `LATEST.txt version: ...` from the dist as it
    # stands when IT runs, and on the main path it runs BEFORE Pull-VP. Miles read that line
    # as the version his run had installed and reported v53; the run then pulled and extracted
    # a newer one. A pre-pull reading printed with no end-of-run counterpart reads like a
    # verdict -- the same defect class as c719's `[+] Lazarus updated`, and the same cure:
    # report the thing itself, at the end, rather than something remembered from earlier.
    #
    # Deliberately does NOT reuse Read-LATESTTxt: that function is the extraction SELECTOR and
    # returns $null (plus a WARN) when `versioned_tarball` is absent, which would throw away a
    # perfectly readable `version` and duplicate its warning inside the summary.
    param([string]$VPRoot = $VPDir)

    foreach ($sub in @("dist\win64", "dist")) {
        $latestFile = Join-Path (Join-Path $VPRoot $sub) "LATEST.txt"
        if (-not (Test-Path $latestFile)) { continue }
        try {
            $version = $null
            $commit = $null
            foreach ($line in ((Get-Content -Path $latestFile -Raw -ErrorAction Stop) -split "`n")) {
                if ($line -match '^\s*version:\s*(.+?)\s*$') { $version = $Matches[1] }
                elseif ($line -match '^\s*source_commit:\s*(.+?)\s*$') { $commit = $Matches[1] }
            }
            if (-not $version) { return $null }
            if ($commit) { return "$version (source_commit $commit)" }
            return $version
        } catch {
            return $null
        }
    }
    return $null
}

function Get-VPArchiveSet {
    # Resolve the ordered list of FileInfo archives that Extract-VPBinaries must unpack.
    # v32+ tarballs are split: bin-only (compiler + bin/) needs pairing with a units tarball
    # (RTL+packages PPU baseline) and optionally an RTL overlay (cycle-fix RTL PPUs over the
    # baseline). Legacy v23-v31 tarballs are monolithic and extract alone. Extract order
    # matters: units (baseline) -> bin (compiler + bin/) -> RTL overlay (patches over baseline).
    #
    # If $VersionedTarball is provided (from LATEST.txt), use that as primary instead of Sort-VPArchives[0].
    # This ensures split-archive pairing regex ^vibepascal-v(\d+)(?:-rc)?-([0-9a-f]+)-win64-bin\.tar\.gz$ matches.
    # The vibepascal-latest-win64-bin.tar.gz filename does NOT match this regex -> falls through to legacy monolithic -> bin-without-units CRC error class.
    param([string]$DistDir, [string]$Filter, [string]$VersionedTarball = $null)
    $all = @(Get-ChildItem -Path $DistDir -Filter $Filter -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return @() }

    # Use LATEST.txt versioned_tarball as primary if provided, otherwise Sort-VPArchives[0].
    if ($VersionedTarball) {
        $primaryFile = Get-ChildItem -Path $DistDir -Filter $VersionedTarball -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($primaryFile) {
            Log-Info "LATEST.txt versioned_tarball $($primaryFile.Name) selected as primary"
            $primary = $primaryFile
        } else {
            Log-Warn "LATEST.txt references $VersionedTarball but file not found in $DistDir -- falling back to Sort-VPArchives[0]"
            $sorted = @(Sort-VPArchives $all)
            $primary = $sorted[0]
        }
    } else {
        $sorted = @(Sort-VPArchives $all)
        $primary = $sorted[0]
    }

    if (-not $primary) { return @() }

    # v32+ split-bin pattern: vibepascal-v<N>(-rc)?-<sha>-win64-bin.tar.gz
    if ($primary.Name -match '^vibepascal-v(\d+)(?:-rc)?-([0-9a-f]+)-win64-bin\.tar\.gz$') {
        $binVersion = [int]$Matches[1]
        $binSha = $Matches[2]

        # Units baseline: latest vibepascal-v<N>-win64-units.tar.gz (no -rc, no -bin).
        # Otto ships v33-units as the stable baseline; v42-bin diffs only RTL from v33.
        $unitsCandidates = @($all | Where-Object { $_.Name -match '^vibepascal-v\d+-win64-units\.tar\.gz$' })
        if ($unitsCandidates.Count -eq 0) {
            Log-Err "v$binVersion bin-only tarball requires a paired units tarball (vibepascal-v<N>-win64-units.tar.gz); none found in $DistDir"
            # DO NOT RE-PIN A VERSION NUMBER IN THIS TEXT. It said v33 for long enough that
            # Otto shipped nineteen releases past it, and the resolver below has never cared:
            # it globs vibepascal-v<N>-win64-units.tar.gz and takes the HIGHEST N, deliberately
            # not the bin tarball's N. A number here only tells the operator to fetch the wrong
            # file. (c700, prompted by Otto: four UNITS.txt files had the same staleness.)
            Log-Warn "Fetch the HIGHEST vibepascal-v<N>-win64-units.tar.gz Otto publishes into $DistDir -- this resolver picks the newest one present and does NOT require N to match the compiler bin tarball, which is how a bin-only refresh stays a ~3.4 MB pull"
            return @()
        }
        # HIGHEST-VERSION units, deliberately NOT "units matching the bin's version number".
        # A bin-only refresh over an older units baseline is Otto's intended steady state for
        # compiler-internal fixes -- it keeps consumers on a ~3.4 MB pull instead of ~104 MB.
        # v53 (2026-09-02) is the first ship to use it: bin v53 paired with units v52. A strict
        # version-match here would break that pairing and every one after it. (Otto, 2026-09-02.)
        $units = (Sort-VPArchives $unitsCandidates)[0]

        # RTL overlay: prefer commit-hash prefix match against the bin's sha (e.g. v42-bin c7617b0
        # pairs with vibepascal-c7617b0252-rtl-findclose-win64.tar.gz). Falls back to latest mtime
        # if no prefix match. Overlay is optional -- units alone may be sufficient for many builds.
        $overlayCandidates = @($all | Where-Object { $_.Name -match '^vibepascal-([0-9a-f]+)-rtl-.*-win64\.tar\.gz$' })
        $matchingOverlay = $null
        if ($overlayCandidates.Count -gt 0) {
            $shaPrefix = $binSha.Substring(0, [Math]::Min(7, $binSha.Length))
            $prefixMatch = @($overlayCandidates | Where-Object { $_.Name.StartsWith("vibepascal-$shaPrefix") })
            if ($prefixMatch.Count -gt 0) {
                $matchingOverlay = ($prefixMatch | Sort-Object LastWriteTime -Descending)[0]
            } else {
                $matchingOverlay = ($overlayCandidates | Sort-Object LastWriteTime -Descending)[0]
                Log-Warn "RTL overlay $($matchingOverlay.Name) does not match bin commit-hash prefix $shaPrefix -- using latest available"
            }
        }

        $set = @($units, $primary)
        if ($matchingOverlay) { $set += $matchingOverlay }
        return $set
    }

    # Legacy monolithic v23-v31 (or any unrecognized naming): extract primary alone.
    return @($primary)
}

function Extract-VPBinaries {
    $compilerExe = Join-Path $VPDir "compiler\ppcx64.exe"
    $markerFile = Join-Path $VPDir ".auto-update-extracted.txt"

    $distDir = Join-Path $VPDir "dist\win64"
    if (-not (Test-Path $distDir)) {
        $distDir = Join-Path $VPDir "dist"
    }
    if (-not (Test-Path $distDir)) {
        if (Test-Path $compilerExe) { return }
        Log-Warn "No VibePascal dist directory found at $distDir"
        return
    }

    # LATEST.txt sidecar (GOD mrghu0l5): read versioned_tarball for authoritative version SELECTOR.
    # Falls back to Sort-VPArchives[0] if absent (older dist). The versioned_tarball filename matches
    # the split-archive pairing regex; vibepascal-latest-win64-bin.tar.gz does NOT match -> legacy monolithic extract -> bin-without-units CRC error class.
    $latestData = Read-LATESTTxt -DistDir $distDir
    $versionedTarball = if ($latestData) { $latestData['versioned_tarball'] } else { $null }
    # c720 -- wording is load-bearing: this fires BEFORE Pull-VP on the main path, so it is a
    # reading of the dist as it stands right now and NOT what this run ends up with.
    if ($versionedTarball) { Log-Info "dist LATEST.txt currently names version $($latestData['version']) commit: $($latestData['source_commit']) -- the version in place at the END of this run is reported in the Update Summary" }

    $archiveSet = @(Get-VPArchiveSet -DistDir $distDir -Filter "*.tar.gz" -VersionedTarball $versionedTarball)
    if ($archiveSet.Count -eq 0) {
        $archiveSet = @(Get-VPArchiveSet -DistDir $distDir -Filter "*.zip" -VersionedTarball $versionedTarball)
    }
    if ($archiveSet.Count -eq 0) {
        if (Test-Path $compilerExe) { return }
        Log-Warn "No usable VibePascal archives in $distDir"
        return
    }

    # Marker fingerprints every archive in the set so any change invalidates the cache.
    $archiveKey = ($archiveSet | ForEach-Object { "$($_.Name)|$($_.LastWriteTime.Ticks)" }) -join ';'

    # LATEST.txt sidecar (GOD mrghu0l5). The .sh half of this landed long ago; the .ps1 half did
    # not, and Windows is GOD's own workstation. Without it the key above is names + mtimes only,
    # so a ship where Otto bumps version/source_commit but the tarball comes out byte-identical
    # leaves the name AND the mtime untouched (git does not restat an unchanged file) -- the key
    # matches, the early return fires, and the box never re-extracts.
    # Hash the FILE rather than reuse $latestData: Read-LATESTTxt returns $null when the sidecar
    # is present but has no versioned_tarball field, and that case still has to invalidate.
    # One-time effect on upgrade: every existing install re-extracts once, because the key format
    # changed. That is the cheap direction to be wrong in.
    # c641 -- EXECUTED on lazdev (native pwsh 7.6.6), this block verbatim, four cases, fixed
    # archive names AND fixed mtimes throughout so only LATEST.txt varies:
    #   v42 vs v43 sidecar -> the OLD names+mtimes key is IDENTICAL in both (the defect: the
    #     early return fires and the box never re-extracts); the new key DIFFERS. Fix works.
    #   sidecar present but NO versioned_tarball -> Read-LATESTTxt returns $null, the WARN
    #     fires, and the key STILL busts off the file hash. This is exactly why the FILE is
    #     hashed rather than $latestData being reused, and it is now measured, not argued.
    #   no sidecar at all -> key degrades to byte-identical to the old names+mtimes form.
    $latestFile = Join-Path $distDir "LATEST.txt"
    if (Test-Path $latestFile) {
        $latestHash = (Get-FileHash -Path $latestFile -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        $archiveKey = "$latestHash;$archiveKey"
        if ($latestData) {
            Log-Info "LATEST.txt present: version $($latestData['version']) source_commit $($latestData['source_commit']) -- included in extraction key"
        } else {
            Log-Info "LATEST.txt present (unparsed, sha256 $latestHash) -- included in extraction key"
        }
    }

    if ((Test-Path $compilerExe) -and (Test-Path $markerFile)) {
        $lastExtracted = (Get-Content $markerFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($lastExtracted -eq $archiveKey) { return }
        Log-Info "VibePascal archive set changed, re-extracting..."
    } elseif ($archiveSet.Count -gt 1) {
        $names = ($archiveSet | ForEach-Object { $_.Name }) -join ', '
        Log-Info "Extracting VibePascal split-archive set ($($archiveSet.Count) archives): $names"
    } else {
        Log-Info "Extracting VibePascal binaries from $($archiveSet[0].FullName)"
    }

    # Blow away stale units once at the start to avoid v24-compiler+v22-PPU CRC mismatches.
    # Both dirs matter: units\x86_64-win64 holds tarball PPUs, rtl\units\x86_64-win64 may hold
    # source-build PPUs that collide with tarball PPUs (different system.ppu CRC).
    foreach ($stale in @("units\x86_64-win64", "rtl\units\x86_64-win64")) {
        $stalePath = Join-Path $VPDir $stale
        if (Test-Path $stalePath) {
            Log-Info "Removing stale PPU units at $stalePath"
            Remove-Item -Recurse -Force $stalePath -ErrorAction SilentlyContinue
        }
    }

    $srcCompiler = $null

    foreach ($archive in $archiveSet) {
        $archivePath = $archive.FullName
        $tempDir = Join-Path $env:TEMP "vp-extract-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            if ($archivePath.EndsWith(".zip")) {
                Expand-Archive -Path $archivePath -DestinationPath $tempDir -Force
            } else {
                & "$env:SystemRoot\System32\tar.exe" -xzf $archivePath -C $tempDir 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Log-Err "tar extraction failed for $($archive.Name) (exit $LASTEXITCODE)"
                    return
                }
            }

            # Descend into a single root dir if the tarball wrapped everything in one
            $extractRoot = $tempDir
            $topDirs = @(Get-ChildItem -Path $tempDir -Directory -ErrorAction SilentlyContinue)
            $topFiles = @(Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue)
            if ($topDirs.Count -eq 1 -and $topFiles.Count -eq 0) {
                $extractRoot = $topDirs[0].FullName
            }

            # Capture compiler from the first archive that has one (bin tarball does;
            # units/RTL-overlay archives don't include ppcx64.exe). Track the DESTINATION
            # path in $VPDir (which persists), not the source in $tempDir (deleted by
            # the finally below). GOD mp8x4twg: previous code pointed at a temp path
            # that was gone by the time the legacy-compiler\ copy at line ~370 ran.
            if (-not $srcCompiler) {
                foreach ($rel in @("bin\ppcx64.exe", "compiler\ppcx64.exe")) {
                    if (Test-Path (Join-Path $extractRoot $rel)) {
                        $srcCompiler = Join-Path $VPDir $rel
                        break
                    }
                }
            }

            # Copy ALL top-level entries into $VPDir. Later archives in the set overlay earlier ones.
            Log-Info "Copying $($archive.Name) contents to $VPDir"
            Get-ChildItem -Path $extractRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $destPath = Join-Path $VPDir $_.Name
                if ($_.PSIsContainer) {
                    if (-not (Test-Path $destPath)) {
                        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                    }
                    # Retry copy for locked binaries (e.g. ppcx64.exe still held by a crashed process).
                    $copyOk = $false
                    for ($retry = 0; $retry -lt 3; $retry++) {
                        try {
                            Copy-Item -Path (Join-Path $_.FullName "*") -Destination $destPath -Recurse -Force -ErrorAction Stop
                            $copyOk = $true
                            break
                        } catch {
                            if ($retry -lt 2) {
                                Log-Warn "Copy locked, retrying in 1s... ($($_.Exception.Message))"
                                Start-Sleep -Seconds 1
                            }
                        }
                    }
                    if (-not $copyOk) {
                        Log-Err "Failed to copy $($_.Name) to $destPath after 3 attempts -- file may be locked by a running compiler process"
                    }
                } else {
                    $copyOk = $false
                    for ($retry = 0; $retry -lt 3; $retry++) {
                        try {
                            Copy-Item -Path $_.FullName -Destination $destPath -Force -ErrorAction Stop
                            $copyOk = $true
                            break
                        } catch {
                            if ($retry -lt 2) {
                                Log-Warn "Copy locked, retrying in 1s... ($($_.Exception.Message))"
                                Start-Sleep -Seconds 1
                            }
                        }
                    }
                    if (-not $copyOk) {
                        Log-Err "Failed to copy $($_.Name) to $destPath after 3 attempts -- file may be locked by a running compiler process"
                    }
                }
            }
        } finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    # Recover compiler if no archive contained it (e.g. user supplied units-only + overlay).
    if (-not $srcCompiler) {
        $found = @(Get-ChildItem -Path $VPDir -Filter "ppcx64.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($found.Count -gt 0) { $srcCompiler = $found[0].FullName }
    }
    if (-not $srcCompiler) {
        Log-Err "ppcx64.exe not found in any extracted archive"
        return
    }

    # Ensure compiler\ppcx64.exe exists for legacy callers that look there
    if (-not (Test-Path $compilerExe)) {
        $compilerDir = Join-Path $VPDir "compiler"
        if (-not (Test-Path $compilerDir)) { New-Item -ItemType Directory -Path $compilerDir -Force | Out-Null }
        Copy-Item $srcCompiler $compilerExe -Force
    }

    $unitCount = 0
    $unitsDir = Join-Path $VPDir "units\x86_64-win64"
    if (Test-Path $unitsDir) {
        $unitCount = (Get-ChildItem -Path $unitsDir -Filter "*.ppu" -ErrorAction SilentlyContinue).Count
    }
    $fpcCfgExtracted = Test-Path (Join-Path $VPDir "bin\fpc.cfg")
    $setDesc = if ($archiveSet.Count -gt 1) { " ($($archiveSet.Count)-archive set)" } else { "" }
    Log-Ok "Extracted VibePascal${setDesc}: ppcx64.exe + $unitCount PPUs$(if ($fpcCfgExtracted) { ' + bin\fpc.cfg' })"

    [IO.File]::WriteAllText($markerFile, $archiveKey, (New-Object System.Text.UTF8Encoding $false))

    # Prefer bin\ppcx64.exe -- fpcres.exe and the tarball's fpc.cfg live in bin\ alongside it.
    # compiler\ppcx64.exe is the legacy fallback but has no resource compiler next to it.
    $binCompiler = Join-Path $VPDir "bin\ppcx64.exe"
    if (Test-Path $binCompiler) {
        $script:VPCompiler = $binCompiler
    } else {
        $script:VPCompiler = $compilerExe
    }
}

$VPCfgPath = Join-Path $VPDir "vibepascal-win64-native.cfg"

function Get-VPUnitPaths {
    # Return only -Fu candidate paths that (a) exist as directories and (b) contain at least one .ppu
    # file. Wildcards like packages\*\units\x86_64-win64 do not reliably expand on Windows fpc.cfg,
    # and a path with no .ppu contributes nothing but noise. Parent "units" (no target subfolder)
    # never contains ppus and must not be included.
    $tarballUnits = Join-Path $VPDir "units\x86_64-win64"
    $rtlUnits = Join-Path $VPDir "rtl\units\x86_64-win64"
    $pkgRoot = Join-Path $VPDir "packages"

    $paths = @()

    # Tarball (flat) layout: units\x86_64-win64 holds the complete consistent PPU set.
    if ((Test-Path $tarballUnits) -and (Get-ChildItem -Path $tarballUnits -Filter *.ppu -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $paths += $tarballUnits
    }

    # Source-tree layout: expand packages/*/units/x86_64-win64 to explicit dirs that actually have ppus.
    if (Test-Path $pkgRoot) {
        foreach ($pkg in (Get-ChildItem -Path $pkgRoot -Directory -ErrorAction SilentlyContinue)) {
            $pkgUnitDir = Join-Path $pkg.FullName "units\x86_64-win64"
            if ((Test-Path $pkgUnitDir) -and (Get-ChildItem -Path $pkgUnitDir -Filter *.ppu -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                $paths += $pkgUnitDir
            }
        }
    }

    # Source-tree layout: rtl/units/x86_64-win64 (skipped when tarball already covers it -- tarball
    # PPUs are internally consistent and mixing them with source-built rtl PPUs causes CRC mismatch).
    if ((Test-Path $rtlUnits) -and ($paths.Count -eq 0) -and (Get-ChildItem -Path $rtlUnits -Filter *.ppu -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $paths += $rtlUnits
    }

    return $paths
}

function Ensure-VPConfig {
    $unitPaths = Get-VPUnitPaths
    if ($unitPaths.Count -eq 0) {
        Log-Err "No VibePascal PPU directories found under $VPDir -- cannot generate config"
        return
    }

    $lines = @("# VibePascal configuration for native x86_64-win64 builds (auto-generated)")
    foreach ($p in $unitPaths) { $lines += "-Fu$p" }

    [IO.File]::WriteAllText($VPCfgPath, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
    Log-Info "Generated VibePascal config: $VPCfgPath ($($unitPaths.Count) unit path$(if ($unitPaths.Count -ne 1) { 's' }))"
}

# GOD mp8g1me3 (2026-05-16): auto-update is for pristine test envs, not local dev.
# Wipe ALL local changes (tracked + untracked) so test machines pull cleanly.
# If you are a developer with local work, do NOT run auto-update.bat -- use git directly.
function Wipe-LocalChanges {
    param([string]$RepoDir, [string]$Label)
    Log-Header "Wiping local changes in $Label (pristine test-env mode)"
    Log-Warn "auto-update.bat discards ALL uncommitted changes and untracked files."
    Log-Warn "If you are a developer with local work, abort NOW (Ctrl-C)."

    # Kill any compiler/build processes that might lock binaries in the repo
    # before git clean tries to remove them (prevents "Invalid argument" / access-denied).
    if ($Label -eq "VibePascal") {
        Get-Process | Where-Object { $_.ProcessName -in @("ppcx64","fpc","make") } | ForEach-Object {
            Log-Warn "Terminating locked process: $($_.ProcessName) (PID $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }

    if ($Label -eq "VibePascal") {
        $br = Test-RepoOnMain -WorkDir $RepoDir
        if ($br -and $br -ne "main") {
            Log-Warn "SKIPPING the $Label wipe: $RepoDir is on branch '$br', not main. 'reset --hard HEAD' there would discard somebody else's uncommitted work with NO rescue tag and no way back. Put that checkout back on main yourself, or run with -UpstreamOnly."
            return
        }
    }

    $reset = Invoke-Git -WorkDir $RepoDir -GitArgs @("reset", "--hard", "HEAD")
    if ($reset.ExitCode -ne 0) {
        Log-Err "git reset --hard HEAD failed in $RepoDir`: $($reset.Error)"
    }
    $clean = Invoke-Git -WorkDir $RepoDir -GitArgs @("clean", "-fdx")
    if ($clean.ExitCode -ne 0) {
        Log-Err "git clean -fdx failed in $RepoDir`: $($clean.Error)"
    }
    Log-Ok "$Label working tree reset + cleaned ($RepoDir)"
}

function Relaunch-IfUpdated {
    param([string]$PreHash)
    if ($SelfUpdated) { return }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.PSCommandPath }
    if (-not $scriptPath) { return }
    $postHash = (Get-FileHash -Path $scriptPath -Algorithm SHA256).Hash
    if ($PreHash -eq $postHash) { return }

    Log-Info "auto-update.ps1 was updated by pull -- relaunching with new version"
    $relaunchParams = @{ SelfUpdated = $true }
    if ($Check)        { $relaunchParams['Check']        = $true }
    if ($NoBuild)      { $relaunchParams['NoBuild']      = $true }
    if ($Release)      { $relaunchParams['Release']      = $true }
    if ($UpstreamOnly) { $relaunchParams['UpstreamOnly'] = $true }
    if ($Setup)        { $relaunchParams['Setup']        = $true }
    if ($FixLpi)       { $relaunchParams['FixLpi']       = $true }
    if ($ForceRebuild) { $relaunchParams['ForceRebuild'] = $true }
    if ($NoLaunch)     { $relaunchParams['NoLaunch']     = $true }
    if ($KeepLocal)    { $relaunchParams['KeepLocal']    = $true }
    if ($VPDir)        { $relaunchParams['VPDir']        = $VPDir }

    $paramSummary = ($relaunchParams.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
    Log-Info "Relaunch: & `"$scriptPath`" $paramSummary"

    & $scriptPath @relaunchParams
    exit $LASTEXITCODE
}

function Invoke-Git {
    param([string]$WorkDir, [string[]]$GitArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = $GitArgs -join " "
    $psi.WorkingDirectory = $WorkDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $proc.WaitForExit()
    return @{ Output = $stdout.Trim(); Error = $stderr.Trim(); ExitCode = $proc.ExitCode }
}

function Get-GitOutput {
    param([string]$WorkDir, [string[]]$GitArgs)
    $result = Invoke-Git -WorkDir $WorkDir -GitArgs $GitArgs
    return $result.Output
}

# Returns @{ Sha; Short; When } for <WorkDir>'s HEAD, or $null when git cannot be read there.
# Used to answer "did HEAD actually move?" -- the only honest basis for the summary's
# "[+] <repo> updated" line (c719). Same doctrine as Get-GitCount: an unreadable repository
# yields $null, and the caller must report UNKNOWN rather than treat it as "nothing changed".
function Get-HeadStamp {
    param([string]$WorkDir)
    if (-not $WorkDir) { return $null }
    $sha = Get-GitOutput -WorkDir $WorkDir -GitArgs @("rev-parse", "HEAD")
    if (-not $sha) { return $null }
    $sha = $sha.Trim()
    if ($sha -notmatch '^[0-9a-f]{40}$') { return $null }
    $when = Get-GitOutput -WorkDir $WorkDir -GitArgs @("log", "-1", "--format=%ci", "HEAD")
    if ($when) { $when = $when.Trim() } else { $when = "unknown date" }
    return @{ Sha = $sha; Short = $sha.Substring(0, 10); When = $when }
}

# A count from an instrument that cannot see is not zero. Steve (SiteManager_DESKTOP-IO9QJQ4,
# 2026-09-16) ran `-Check` in a directory holding no repository and read "[OK] VibePascal: up to
# date", "[OK] Lazarus origin: up to date", "[OK] Everything is up to date" over two blank HEAD
# lines: every rev-list had failed, Get-GitOutput had yielded "", and the
# `if (-not $x) { $x = "0" }` idiom scored each failure as "0 commits behind". Reproduced here
# under pwsh 7.6 with the same scratch layout (exit 0). Returns the [int] count or "UNKNOWN";
# callers must treat UNKNOWN as a failed check and never as 0 (same rule as
# Get-UnpushedCommitCount, which guards the destructive reset for the same reason).
function Get-GitCount {
    param([string]$WorkDir, [string]$Range)
    $r = Invoke-Git -WorkDir $WorkDir -GitArgs @("rev-list", "--count", $Range)
    if ($r.ExitCode -ne 0) { return "UNKNOWN" }
    if ("$($r.Output)" -notmatch '^\d+$') { return "UNKNOWN" }
    return [int]$r.Output
}

# --- Unpushed-work guard for `reset --hard origin/main` (Lars, c668 2026-09-11) -------------
# Both Pull-*Origin functions fall back to `reset --hard origin/main` when an --ff-only pull
# fails. The fallback exists for a real reason (GOD mrghu0l5: a stale local commit pinned VP
# on an old version forever), but it could silently DESTROY commits the remote does not have.
# Measured on the bash twin with the real shipped function: a clean-tree checkout carrying 2
# unpushed commits came out with both commits unreachable from every ref while the log read
# "[OK] Lazarus origin pulled". Steve reported the live instance on 2026-09-11 -- E:\lazarus,
# clean working tree, HEAD 205d77ed3f plus 098e5739c6 and 1b9f60f35c on no remote at all.
function Get-UnpushedCommitCount {
    # Returns an [int] count of commits on HEAD that origin/main does not contain, or the
    # string "UNKNOWN" when git could not answer. It must NEVER return 0 for a failed
    # measurement: Get-GitOutput discards git's exit code and yields "" on failure, and the
    # `if (-not $x) { $x = "0" }` idiom turned that empty string into "no local work" --
    # which then authorised the destructive reset. A zero from an instrument that cannot see
    # is not a clean answer, it is no answer.
    param([string]$WorkDir)
    $r = Invoke-Git -WorkDir $WorkDir -GitArgs @("rev-list", "--count", "origin/main..HEAD")
    if ($r.ExitCode -ne 0) { return "UNKNOWN" }
    if ("$($r.Output)" -notmatch '^\d+$') { return "UNKNOWN" }
    return [int]$r.Output
}

function Invoke-AnchorBeforeReset {
    # Call immediately before `reset --hard origin/main`. $true = the reset may proceed,
    # $false = the caller must NOT reset.
    param([string]$WorkDir, [string]$Label)
    $n = Get-UnpushedCommitCount -WorkDir $WorkDir
    if ($n -is [string]) {
        Log-Err       "${Label}: cannot determine whether $WorkDir carries unpushed commits (git rev-list failed)."
        Log-ErrDetail "${Label}: REFUSING to reset --hard -- that would silently discard local work if any exists."
        Log-ErrDetail "${Label}: check the repo (git -C `"$WorkDir`" fsck), then reset by hand if you are sure:"
        Log-ErrDetail "    git -C `"$WorkDir`" reset --hard origin/main"
        return $false
    }
    if ($n -eq 0) { return $true }

    $sha    = (Invoke-Git -WorkDir $WorkDir -GitArgs @("rev-parse", "HEAD")).Output
    $branch = (Invoke-Git -WorkDir $WorkDir -GitArgs @("rev-parse", "--abbrev-ref", "HEAD")).Output -replace '/', '-'
    if (-not $branch) { $branch = "detached" }
    $stamp  = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $tag    = "autoupdate-rescue/$branch-$stamp"
    Log-Warn "${Label}: $WorkDir has $n commit(s) that origin/main does not contain."
    Log-Warn "${Label}: HEAD $sha"
    $t = Invoke-Git -WorkDir $WorkDir -GitArgs @("tag", $tag, "HEAD")
    if ($t.ExitCode -eq 0) {
        Log-Warn "${Label}: anchored in local tag '$tag' before resetting. Recover with:"
        Log-Warn "    git -C `"$WorkDir`" log $tag"
        Log-Warn "    git -C `"$WorkDir`" push origin $tag     # the tag is LOCAL ONLY until you do this"
        return $true
    }
    Log-Err       "${Label}: could not create rescue tag '$tag'. REFUSING to reset --hard and lose $n commit(s)."
    Log-ErrDetail "    git -C `"$WorkDir`" branch rescue-$stamp HEAD     # save them, then re-run"
    return $false
}

function Check-VPUpdates {
    Log-Header "Checking VibePascal (adaloveless/vibepascal)"

    if (-not (Test-Path (Join-Path $VPDir ".git"))) {
        Log-Err "VibePascal repo not found at $VPDir"
        return
    }

    $fetch = Invoke-Git -WorkDir $VPDir -GitArgs @("fetch", "origin")
    if ($fetch.ExitCode -ne 0) {
        Log-Warn "VibePascal: git fetch origin failed (exit $($fetch.ExitCode)): $($fetch.Error)"
        Log-Warn "VibePascal: comparing against the LAST fetched origin/main -- an 'up to date' below is not a fresh reading"
        $script:CheckFailed = $true
    }

    $behind = Get-GitCount -WorkDir $VPDir -Range "HEAD..origin/main"
    if ("$behind" -eq "UNKNOWN") {
        Log-Err "VibePascal: cannot count HEAD..origin/main in $VPDir (not a git repository, or origin/main missing) -- verdict UNKNOWN, not 'up to date'"
        $script:CheckFailed = $true
        return
    }

    if ([int]$behind -gt 0) {
        Log-Warn "VibePascal: $behind new commit(s) available"
        $log = Get-GitOutput -WorkDir $VPDir -GitArgs @("log", "--oneline", "HEAD..origin/main")
        Write-Host $log
        $script:VPUpdated = $true
    } else {
        Log-Ok "VibePascal: up to date"
    }
}

# --- Never write git state into a checkout sitting on somebody else's branch -------------
# (Lars, c698 2026-09-17 -- reported by Otto/FPCDeveloper; mirror of auto-update.sh)
#
# On lazdev at 2026-09-17 22:06:56/22:06:59Z the bash half ran reset --hard HEAD and then
# pull --ff-only origin main against the SHARED vibepascal checkout while that tree was
# sitting on GOD's own branch `interface-temp-end-of-statement`. The ff-only pull SUCCEEDED
# -- the branch was merely BEHIND main -- so it silently fast-forwarded a branch that is not
# main, and nothing in the log said so. Reproduced here on a synthetic tree: the pre-fix code
# moved the branch AND destroyed an uncommitted edit; the guarded code leaves both alone.
#
# Invoke-AnchorBeforeReset already covers the DIVERGED case, but only on the pull FAILURE
# path -- which is exactly the path a merely-behind branch never takes. The guard belongs in
# FRONT of both operations. Same class as the c686 environmentoptions.xml defect.
function Test-RepoOnMain {
    param([string]$WorkDir)
    if (-not (Test-Path (Join-Path $WorkDir ".git"))) { return $null }
    $br = Get-GitOutput -WorkDir $WorkDir -GitArgs @("rev-parse", "--abbrev-ref", "HEAD")
    if (-not $br) { return $null }
    return $br.Trim()
}

function Pull-VP {
    if (-not $script:VPUpdated) { return }

    Log-Header "Pulling VibePascal updates"
    # If ff-only pull fails (local branch diverged from origin/main), reset to origin/main.
    # Recovers from the pinning bug where a stale local commit leaves VP stuck on an old version
    # (GOD mrghu0l5; Finn/ZENBOOK r23 win64 smoke: --ff-only failure + no fallback = pinned forever).
    $vpBranch = Test-RepoOnMain -WorkDir $VPDir
    if ($vpBranch -and $vpBranch -ne "main") {
        Log-Warn "SKIPPING the VibePascal pull: $VPDir is on branch '$vpBranch', not main. A --ff-only pull there moves SOMEBODY ELSE'S branch onto origin/main, silently, whenever it is merely behind -- measured 2026-09-17, when GOD's 'interface-temp-end-of-statement' was fast-forwarded exactly that way. Put that checkout back on main to resume VibePascal updates."
        return
    }

    $result = Invoke-Git -WorkDir $VPDir -GitArgs @("pull", "--ff-only", "origin", "main")
    if ($result.ExitCode -ne 0) {
        Log-Warn "VP --ff-only pull failed; reset --hard origin/main (pristine mode)"
        # The failed pull above already fetched, so origin/main is fresh for this check (c668).
        if (-not (Invoke-AnchorBeforeReset -WorkDir $VPDir -Label "VP")) {
            Log-ErrDetail "VibePascal origin pull ABORTED to protect local commits; tree left as-is."
            return
        }
        $reset = Invoke-Git -WorkDir $VPDir -GitArgs @("reset", "--hard", "origin/main")
        if ($reset.ExitCode -ne 0) {
            Log-Err "VP reset --hard origin/main failed: $($reset.Error)"
            return
        }
    }
    Log-Ok "VibePascal pulled successfully"
}

function Check-LazarusUpstream {
    Log-Header "Checking Lazarus upstream (fpc/Lazarus)"

    $behind = Get-GitCount -WorkDir $LazarusDir -Range "HEAD..upstream/main"
    if ("$behind" -eq "UNKNOWN") {
        Log-Err "Lazarus: cannot count HEAD..upstream/main in $LazarusDir (not a git repository, or upstream/main missing) -- verdict UNKNOWN, not 'in sync'"
        $script:CheckFailed = $true
        $script:UpstreamUnknown = $true   # c722 -- so the summary says UNKNOWN too, instead of "no changes"
        return
    }

    $localCommits = Get-GitCount -WorkDir $LazarusDir -Range "upstream/main..HEAD"
    if ("$localCommits" -eq "UNKNOWN") { $localCommits = 0 }   # informational line only; the update path re-measures

    if ([int]$behind -gt 0) {
        Log-Warn "Lazarus: $behind new upstream commit(s)"
        $log = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("log", "--oneline", "HEAD..upstream/main")
        Write-Host $log
        $script:UpstreamUpdated = $true
    } else {
        Log-Ok "Lazarus: upstream in sync"
    }

    if ([int]$localCommits -gt 0) {
        Log-Info "Lazarus: $localCommits local commit(s) ahead of upstream"
    }
}

function Check-LazarusOrigin {
    Log-Header "Checking Lazarus origin (adaloveless/Lazarus)"

    $fetch = Invoke-Git -WorkDir $LazarusDir -GitArgs @("fetch", "origin")
    if ($fetch.ExitCode -ne 0) {
        Log-Warn "Lazarus origin: git fetch origin failed (exit $($fetch.ExitCode)): $($fetch.Error)"
        Log-Warn "Lazarus origin: comparing against the LAST fetched origin/main -- an 'up to date' below is not a fresh reading"
        $script:CheckFailed = $true
    }

    $behind = Get-GitCount -WorkDir $LazarusDir -Range "HEAD..origin/main"
    if ("$behind" -eq "UNKNOWN") {
        Log-Err "Lazarus origin: cannot count HEAD..origin/main in $LazarusDir (not a git repository, or origin/main missing) -- verdict UNKNOWN, not 'up to date'"
        $script:CheckFailed = $true
        return
    }

    if ([int]$behind -gt 0) {
        Log-Warn "Lazarus origin: $behind new commit(s) from other developers"
        $log = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("log", "--oneline", "HEAD..origin/main")
        Write-Host $log
        $script:LazarusUpdated = $true
    } else {
        Log-Ok "Lazarus origin: up to date"
    }
}

function Pull-LazarusUpstream {
    if (-not $script:UpstreamUpdated) { return }

    Log-Header "Merging Lazarus upstream"

    $localCommits = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-list", "--count", "upstream/main..HEAD")
    if (-not $localCommits) { $localCommits = "0" }

    if ([int]$localCommits -eq 0) {
        $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("merge", "--ff-only", "upstream/main")
        if ($result.ExitCode -ne 0) {
            Log-Err "Fast-forward merge failed: $($result.Error)"
            return
        }
        Log-Ok "Fast-forward merge from upstream"
    } else {
        if (-not $AllowPush) {
            # Update/user mode: this box tracks adaloveless/origin -- the curated fork that
            # Lars periodically merges fpc/upstream into and resolves. Re-merging fpc/upstream
            # here re-does those resolved merges and CONFLICTS ($localCommits fork commit(s)
            # diverge from upstream), leaving conflict markers that the missing-binary
            # force-rebuild then compiles (Finn/ZENBOOK r23 win64 smoke 2026-07-03:
            # components/codetools/stdcodetools.pas <<<<<<< HEAD -> exit 1). The origin pull
            # below brings in whatever upstream commits adaloveless has already curated.
            Log-Ok "Skipping fpc/upstream merge in update mode ($localCommits fork commit(s) diverge from upstream); tracking adaloveless/origin only. Re-run with -AllowPush to merge upstream as a maintainer."
            return
        }
        Log-Info "Merging upstream/main ($localCommits local commit(s) ahead)..."
        $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("merge", "-m", "Merge upstream/main", "upstream/main")
        if ($result.ExitCode -ne 0) {
            Log-Err "Merge failed: $($result.Error)"
            Log-Warn "Aborting the conflicted merge so the working tree stays clean (never rebuild a tree with conflict markers)."
            Invoke-Git -WorkDir $LazarusDir -GitArgs @("merge", "--abort") | Out-Null
            Log-Err "Resolve conflicts manually (or pull adaloveless/origin), then re-run."
            return
        }
        Log-Ok "Merge from upstream complete"
    }

    if ($AllowPush) {
        Log-Info "Pushing to origin..."
        $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("push", "origin", "main")
        if ($result.ExitCode -ne 0) {
            Log-Warn "Push failed (non-critical): $($result.Error)"
        } else {
            Log-Ok "Pushed to adaloveless/Lazarus"
        }
    } else {
        Log-Info "Skipping push to origin/main (use -AllowPush to enable; merge stays local per GOD directive)"
    }
    $script:LazarusUpdated = $true
}

function Pull-LazarusOrigin {
    if (-not $script:LazarusUpdated) { return }

    Log-Header "Pulling Lazarus origin changes"

    $localCommits = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-list", "--count", "origin/main..HEAD")
    if (-not $localCommits) { $localCommits = "0" }

    if ([int]$localCommits -eq 0) {
        # If ff-only pull fails (local branch diverged from origin/main), reset to origin/main.
        $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("pull", "--ff-only", "origin", "main")
        if ($result.ExitCode -ne 0) {
            Log-Warn "Lazarus --ff-only pull failed; reset --hard origin/main (pristine mode)"
            # The failed pull above already fetched, so origin/main is fresh for this check --
            # the $localCommits reading further up was taken against the PRE-fetch ref and is
            # stale here, which is how a force-pushed origin could still drop local work (c668).
            if (-not (Invoke-AnchorBeforeReset -WorkDir $LazarusDir -Label "Lazarus")) {
                Log-ErrDetail "Lazarus origin pull ABORTED to protect local commits; tree left as-is."
                return
            }
            $reset = Invoke-Git -WorkDir $LazarusDir -GitArgs @("reset", "--hard", "origin/main")
            if ($reset.ExitCode -ne 0) {
                Log-Err "Lazarus reset --hard origin/main failed: $($reset.Error)"
            } else {
                Log-Ok "Lazarus origin pulled"
            }
        } else {
            Log-Ok "Lazarus origin pulled"
        }
    } else {
        Log-Info "Merging origin/main ($localCommits local commit(s) ahead)..."
        $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("merge", "-m", "Merge origin/main", "origin/main")
        if ($result.ExitCode -ne 0) {
            Log-Err "Merge from origin failed: $($result.Error)"
            Log-Warn "Aborting the conflicted merge so the working tree stays clean (never rebuild a tree with conflict markers)."
            Invoke-Git -WorkDir $LazarusDir -GitArgs @("merge", "--abort") | Out-Null
            Log-Err "Resolve conflicts manually, then re-run."
        } else {
            Log-Ok "Merge from origin complete"
        }
    }
}

# c718 -- ASK WHAT THE make WE FOUND ACTUALLY IS. Miles (MonitoringSystemsDeveloper, MVMJ26,
# 2026-09-18) measured the failure this exists to stop. On an ex-Delphi box the only make on
# PATH is C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\make.exe -- "MAKE Version 5.43
# Copyright (c) 1987, 2019 Embarcadero Technologies", i.e. BORLAND make, which rejects GNU
# arguments outright (it refuses even -v). Find-Make returned it because Test-Path said the
# file was there and nothing asked what it was; Rebuild-Lazbuild then handed GNU arguments to
# a program that cannot read them, Borland printed its own USAGE TEXT into the log, no
# lazbuild.exe appeared, and auto-update blamed something else entirely:
#   [ERROR] lazbuild.exe build failed -- binary not found!
# The build never had a chance and the tool never noticed it was talking to the wrong make;
# lazarus.exe had in fact NEVER been built on that box. Policy #22 makes this general rather
# than exotic: Delphi is dead org-wide but the installs are still on our machines and still
# own "make" on PATH, so every ex-Delphi site hits this the moment auto-update rebuilds.
#
# Two call sites beyond the build were being poisoned by the same return value: Rebuild-IDE
# PREPENDS the discovered make's directory to PATH, and Configure-Environment WRITES it into
# environmentoptions.xml as MakeFilename -- so an unverified answer here does not just fail a
# build, it persists into the user's IDE config.
#
# Returns @{ IsGnu; Name; Detail }. A probe that cannot run, or will not answer, is NOT GNU:
# an error must never read as a pass (c661 -- in any rc-shaped test an error is
# indistinguishable from a clean NO, so the default has to be the refusing one).
function Get-MakeFlavour {
    param([string]$Path)

    $flavour = @{ IsGnu = $false; Name = "unknown"; Detail = "" }
    $out = ""
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Path
        $psi.Arguments = "--version"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        # Bounded wait: a make that prompts instead of printing must not hang the whole
        # update. Borland MAKE answers an unknown switch and exits, but "it exits on my box"
        # is not a property of every make we might meet.
        if (-not $proc.WaitForExit(10000)) {
            try { $proc.Kill() } catch { }
            $flavour.Name = "unresponsive (no --version answer within 10s)"
            return $flavour
        }
        $out = $stdoutTask.GetAwaiter().GetResult() + "`n" + $stderrTask.GetAwaiter().GetResult()
    } catch {
        $flavour.Name = "not runnable ($($_.Exception.Message))"
        return $flavour
    }

    $firstLine = ""
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim()) { $firstLine = $line.Trim(); break }
    }
    $flavour.Detail = $firstLine

    if ($out -match "GNU Make") {
        $flavour.IsGnu = $true
        $flavour.Name = "GNU make"
    } elseif ($out -match "Embarcadero|Borland") {
        $flavour.Name = "Borland/Embarcadero MAKE (Delphi's make, not GNU make)"
    } elseif (-not $firstLine) {
        $flavour.Name = "silent -- printed nothing for --version"
    } else {
        $flavour.Name = "not GNU make"
    }
    return $flavour
}

# Print what Find-Make looked at and why it refused it. The old message named only the cure
# ("Install MinGW/MSYS2") and never the disease, so a box holding a perfectly present make.exe
# read as a box with no make at all.
function Report-NoGnuMake {
    Log-Err "No GNU make found. Lazarus cannot be built without it."
    if ($script:MakeRejected.Count -gt 0) {
        Log-ErrDetail "  Candidates were present but REJECTED because they are not GNU make:"
        foreach ($r in $script:MakeRejected) { Log-ErrDetail "    $r" }
        Log-ErrDetail "  A non-GNU make is not a usable substitute: it cannot read the arguments"
        Log-ErrDetail "  this script passes (-C, PP=, FPCDIR=, OPT=) and will print its own usage instead."
    } else {
        Log-ErrDetail "  No make.exe was found on PATH or in any known FPC/MSYS location."
    }
    Log-ErrDetail "  Install MSYS2/MinGW GNU make, or put FPC's own make on PATH, then re-run."
}

function Find-Make {
    $script:MakeRejected = @()
    $makePaths = @(
        (Get-Command "make" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        (Get-Command "mingw32-make" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        "C:\lazarus\fpc\bin\x86_64-win64\make.exe",
        "C:\installs\lazarus\fpc\bin\x86_64-win64\make.exe",
        "C:\FPC\bin\x86_64-win64\make.exe",
        "C:\tools\msys64\usr\bin\make.exe",
        "C:\msys64\usr\bin\make.exe",
        "C:\msys32\usr\bin\make.exe"
    )
    foreach ($p in $makePaths) {
        if ($p -and (Test-Path $p)) {
            $flavour = Get-MakeFlavour -Path $p
            if (-not $flavour.IsGnu) {
                $why = "$p  --  $($flavour.Name)"
                if ($flavour.Detail) { $why = "$why  [$($flavour.Detail)]" }
                $script:MakeRejected += $why
                continue
            }
            # MSYS2 make depends on sibling tools (sh.exe, sed.exe) in the same usr\bin dir;
            # prepend that directory to PATH so child processes can find them.
            $makeDir = Split-Path -Parent $p
            if ($makeDir -match '(?i)msys(64|32)?\\usr\\bin$' -and ($env:PATH -notlike "*$makeDir*")) {
                $env:PATH = "$makeDir;$env:PATH"
            }
            return $p
        }
    }
    foreach ($root in @("C:\lazarus\fpc", "C:\installs\lazarus\fpc", "C:\FPC")) {
        if (Test-Path $root) {
            $versionedDirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+' } |
                Sort-Object Name -Descending
            foreach ($d in $versionedDirs) {
                $candidate = Join-Path $d.FullName "bin\x86_64-win64\make.exe"
                if (Test-Path $candidate) {
                    $flavour = Get-MakeFlavour -Path $candidate
                    if (-not $flavour.IsGnu) {
                        $why = "$candidate  --  $($flavour.Name)"
                        if ($flavour.Detail) { $why = "$why  [$($flavour.Detail)]" }
                        $script:MakeRejected += $why
                        continue
                    }
                    return $candidate
                }
            }
        }
    }
    return $null
}

function Rebuild-Lazbuild {
    Log-Header "Rebuilding lazbuild"

    if (-not (Test-Path $VPCompiler)) {
        Log-Err "VibePascal compiler not found at $VPCompiler"
        return
    }

    Ensure-VPConfig

    $make = Find-Make
    if (-not $make) {
        Report-NoGnuMake
        return
    }

    Log-Info "Using make: $make"
    Log-Info "Using compiler: $VPCompiler"

    $lazbuildExe = Join-Path $LazarusDir "lazbuild.exe"
    $preBuildTime = if (Test-Path $lazbuildExe) { (Get-Item $lazbuildExe).LastWriteTime } else { $null }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $make -C $LazarusDir clean 2>&1 | Select-Object -Last 1

    & $make -C $LazarusDir lazbuild `
        "PP=$VPCompiler" `
        "FPCDIR=$VPDir" `
        "OPT=-n @$VPCfgPath" 2>&1 | Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($buildExit -ne 0) {
        Log-Err "lazbuild build failed with exit code $buildExit"
        return
    }

    if (-not (Test-Path $lazbuildExe)) {
        Log-Err "lazbuild.exe build failed -- binary not found!"
        return
    }

    $postBuildTime = (Get-Item $lazbuildExe).LastWriteTime
    if ($preBuildTime -and $postBuildTime -le $preBuildTime) {
        Log-Err "lazbuild.exe build failed silently -- binary was not updated (stale file from previous build)"
        return
    }

    $size = (Get-Item $lazbuildExe).Length / 1MB
    Log-Ok ("lazbuild.exe rebuilt ({0:N1} MB)" -f $size)
}

function Remove-PackageFromAutoInstall {
    # Purge a package from the IDE's PERSISTED auto-install list so a subsequent
    # --build-ide does not recompile it FROM CONFIG.
    #
    # Why Sanitize-PackageRegistrations is not enough: it deletes staticpackages.inc
    # so "lazbuild will regenerate" it -- and lazbuild regenerates it FROM
    # miscellaneousoptions.xml <StaticAutoInstallPackages>, which is the authoritative
    # list and which nothing in this script touched. lazbuild --add-package ADDS to
    # that list and it is cumulative, so a package that broke the build stays wired in
    # and is recompiled on every retry. Dropping the --add-package argument on attempt
    # 2+ therefore does NOT drop the package: all three attempts fail identically and
    # the box is left with no IDE (GOD mrxp2wpx follow-up, confirmed on GOD's Windows
    # box with commonx PRESENT). Both files have to be cleaned for the fallback to work.
    #
    # c640 -- what is PROVEN and what is not. The MECHANISM was reproduced end to end on
    # lazdev with a real lazbuild and a deliberately-broken throwaway design-time package:
    #   * `lazbuild --add-package <lpk>` persisted the package NAME into
    #     miscellaneousoptions.xml as <StaticAutoInstallPackages Count="2"><ItemN Value=..>,
    #     exactly the shape rewritten below (ide/lazbuild.lpr:1202 stores Package.Name).
    #   * NEGATIVE control: re-running `--build-ide` with NO --add-package argument at all
    #     still compiled that package and died -- "Building IDE: Compile AutoInstall
    #     Packages failed", exit 2. Dropping the argument really does not drop the package
    #     (ide/lazbuild.lpr:679 loads the persisted list, not the command line).
    #   * POSITIVE control: with the entry removed from the list -- the end state this
    #     function produces -- the IDENTICAL command stopped compiling it entirely (0
    #     mentions) and ran on through LCL/codetools/SynEdit, 4691 log lines vs 119.
    #     It did NOT finish a whole IDE: that throwaway pcp later tripped an unrelated
    #     "Can't find unit FpImgReaderMachoFile" in LazDebuggerFp. Unrelated to this fix
    #     (both units are fpdebug.lpk members) and it is downstream of what is under test.
    # c641 -- the "this PowerShell has never executed" caveat that stood here is GONE, and
    # the boundary behind it was never real. lazdev had no pwsh only because nobody had
    # downloaded one; PowerShell 7 ships a self-contained linux-x64 tarball needing no
    # installer and no root. This function has now been EXECUTED on lazdev with both
    # controls, driving the block extracted verbatim from this file:
    #   POSITIVE: a 3-entry StaticAutoInstallPackages containing PackageCommonX_LCL ->
    #     entry removed, Count 3->2, survivors RENUMBERED contiguously Item1/Item2 with
    #     their original order preserved, staticpackages.inc line dropped, both Log-Info
    #     lines fired.
    #   NEGATIVE: the same two files with the package absent -> BOTH left byte-identical
    #     (MD5 unchanged) and ZERO log lines. It does not rewrite what it should not touch.
    # One measured cosmetic effect: [xml]::Save normalises <ItemN Value="X"/> to
    # <ItemN Value="X" />. Standard XML, and laz2_XMLRead reads it back fine.
    # STILL NOT PROVEN, and do not let the above be quoted as if it were: no run on real
    # Windows. Parsing and Linux-side execution of the XML rewrite say nothing about the
    # registry, lazbuild.exe, or path semantics on GOD's box.
    param(
        [Parameter(Mandatory)] [string] $PcpDir,
        [Parameter(Mandatory)] [string] $PackageName
    )

    # 1) miscellaneousoptions.xml -- the authoritative list the IDE reads.
    $miscXml = Join-Path $PcpDir "miscellaneousoptions.xml"
    if (Test-Path $miscXml) {
        try {
            [xml]$mx = Get-Content $miscXml -Raw
            $listNode = $mx.SelectSingleNode("//StaticAutoInstallPackages")
            if ($listNode) {
                $items = @($listNode.ChildNodes | Where-Object { $_.LocalName -match '^Item\d+$' })
                $kept  = @($items | Where-Object { $_.GetAttribute("Value") -ne $PackageName } |
                          ForEach-Object { $_.GetAttribute("Value") })
                if ($kept.Count -ne $items.Count) {
                    foreach ($i in $items) { [void]$listNode.RemoveChild($i) }
                    for ($n = 0; $n -lt $kept.Count; $n++) {
                        $e = $mx.CreateElement("Item$($n+1)")
                        $e.SetAttribute("Value", $kept[$n])
                        [void]$listNode.AppendChild($e)
                    }
                    $listNode.SetAttribute("Count", "$($kept.Count)")
                    $mx.Save($miscXml)
                    Log-Info "Purged $PackageName from StaticAutoInstallPackages (miscellaneousoptions.xml)"
                }
            }
        } catch {
            Log-Warn "Could not rewrite miscellaneousoptions.xml to drop $PackageName -- $($_.Exception.Message)"
        }
    }

    # 2) staticpackages.inc -- generated include; drop the line so a stale copy is not reused.
    #    Sanitize-PackageRegistrations may already have deleted this file; that is fine (it
    #    returns early when packagefiles.xml is absent, so this is not dead code).
    #    c640 NAME CAVEAT, measured on a real generated file: the entries here are NOT package
    #    names. TLazPackageGraph.SaveAutoInstallConfig writes
    #    ExtractFileNameOnly(APackage.GetCompileSourceFilename) -- e.g. package "syneditdsgn"
    #    appears as "allsyneditdsgn". The match below is safe for PackageCommonX_LCL only
    #    because commonx ships lcl/PackageCommonX_LCL.pas, so its compile source happens to
    #    share the package name. Part 1 (the authoritative miscellaneousoptions.xml list) keys
    #    on the real package name and is unaffected.
    #    c642 -- that caveat named the WRONG failure mode, and I only found out by EXECUTING it.
    #    It said a mismatched name would silently no-op here. It would not: the old test was
    #    `-notmatch [regex]::Escape($PackageName)`, i.e. a case-INSENSITIVE SUBSTRING regex, so
    #    it OVER-matched. Two controls, run on lazdev against this exact block:
    #      * purge "SynEditDsgn" -> it DID strip "allsyneditdsgn", by accident, because that
    #        string contains "syneditdsgn". Right outcome, uncontrolled mechanism.
    #      * purge "CommonX" from a list also holding "PackageCommonX_LCL" -> it stripped BOTH
    #        inc lines. The xml half kept PackageCommonX_LCL (that half uses an exact -ne), so
    #        the two files ended up DISAGREEING and an unrelated package was silently
    #        deregistered from the generated include.
    #    Latent, not live: the only call site passes the literal "PackageCommonX_LCL", and that
    #    path is byte-for-byte unchanged by this fix (re-run and confirmed). But the comment
    #    above invites reuse, and a reader who did the compile-source check it asks for would
    #    still have hit the collateral delete. Now an exact whole-entry match: no over-match, no
    #    collateral, and a mismatched compile-source name no-ops exactly as documented -- the
    #    xml is authoritative and lazbuild regenerates this include from it anyway.
    $incFile = Join-Path $PcpDir "staticpackages.inc"
    if (Test-Path $incFile) {
        try {
            $lines = Get-Content $incFile
            $filtered = $lines | Where-Object { $_.Trim().TrimEnd(',').Trim() -ne $PackageName }
            if (@($filtered).Count -ne @($lines).Count) {
                Set-Content -Path $incFile -Value $filtered -Encoding utf8
                Log-Info "Purged $PackageName from staticpackages.inc"
            }
        } catch {
            Log-Warn "Could not rewrite staticpackages.inc to drop $PackageName -- $($_.Exception.Message)"
        }
    }
}

function Sanitize-PackageRegistrations {
    # Strip stale UserPkgLinks from packagefiles.xml that point at OTHER Lazarus
    # checkouts (typically C:\temp\lazarus-* or sibling worktrees). When such a
    # link names a core package like LCL or LCLBase, lazbuild --build-ide writes
    # the stale lib path into idemake.cfg and then loads an outdated themes.ppu
    # from there, causing inexplicable "no method in ancestor class to be
    # overridden" errors on freshly-pulled source (seen post-merge 2026-05-27 on
    # the IsDarkTheme virtual). Also wipe idemake.cfg + staticpackages.inc so
    # lazbuild regenerates them from the now-clean registrations.
    $pcpDir = Join-Path $env:LOCALAPPDATA "lazarus"
    $pkgFilesXml = Join-Path $pcpDir "packagefiles.xml"
    if (-not (Test-Path $pkgFilesXml)) { return }

    $coreLazPackages = @(
        "LCL", "LCLBase", "FCL", "IDEIntf", "SynEdit", "CodeTools",
        "LazUtils", "LazControls", "IdeConfig", "IdePackager", "IdeProject",
        "IdeDebugger", "IdeUtils", "BuildIntf", "DebuggerIntf",
        "LazDebuggerIntf", "Printer4Lazarus", "Printer4LazarusStandalone"
    )

    try {
        [xml]$pkgXml = Get-Content $pkgFilesXml -Raw
        $userLinks = $pkgXml.CONFIG.UserPkgLinks
        if (-not $userLinks) { return }

        $removed = @()
        # Use LocalName because $_.Name is shadowed by the child <Name> element
        # via PowerShell's XML property adapter (returns an XmlElement, not the tag).
        $itemNodes = @($userLinks.ChildNodes | Where-Object { $_.LocalName -match '^Item\d+$' })
        foreach ($it in $itemNodes) {
            $fileNode = $it.SelectSingleNode("Filename")
            $nameNode = $it.SelectSingleNode("Name")
            $file = if ($fileNode) { $fileNode.GetAttribute("Value") } else { $null }
            $pkgName = if ($nameNode) { $nameNode.GetAttribute("Value") } else { "" }
            if (-not $file) { continue }
            if (-not [System.IO.Path]::IsPathRooted($file)) { continue }

            $reason = $null
            if ($coreLazPackages -contains $pkgName -and
                -not $file.StartsWith($LazarusDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $reason = "core package $pkgName pointing outside `$LazarusDir"
            } elseif (-not (Test-Path $file)) {
                $reason = "missing file"
            }

            if ($reason) {
                $removed += "$pkgName -> $file ($reason)"
                [void]$userLinks.RemoveChild($it)
            }
        }

        if ($removed.Count -gt 0) {
            $count = [int]$userLinks.GetAttribute("Count")
            $userLinks.SetAttribute("Count", ($count - $removed.Count).ToString())
            $pkgXml.Save($pkgFilesXml)
            foreach ($r in $removed) {
                Log-Info "Removed stale package registration: $r"
            }
            Log-Ok "Sanitized $($removed.Count) stale UserPkgLink(s) from packagefiles.xml"
        }
    } catch {
        Log-Warn "Could not sanitize packagefiles.xml: $_"
    }

    foreach ($f in @("idemake.cfg", "staticpackages.inc")) {
        $p = Join-Path $pcpDir $f
        if (Test-Path $p) {
            Remove-Item $p -Force -ErrorAction SilentlyContinue
            Log-Info "Removed stale $f (lazbuild will regenerate)"
        }
    }
}

function Clean-StalePackageArtifacts {
    param([string[]]$ExtraPackageLpks = @())

    # Stale .ppu/.o files (compiled with older/different compilers) cause
    # VibePascal ICEs when lazbuild --build-ide= tries to recompile them.
    # Wipe lib/ output dirs for ALL installed packages (external + Lazarus
    # built-in) so they rebuild cleanly from source.
    #
    # c636 (GOD mt93q21h) -- TWO defects fixed here, both mine:
    #   (1) This function only ever ran on the RETRY, and the retry is the attempt that
    #       DROPS commonx. So the one cleanup written for this exact failure could never
    #       run before the one build that needed it. It is now also called before attempt 1.
    #   (2) Section 1 below finds packages via packagefiles.xml only, and cleans just
    #       <pkgDir>\lib. On GOD's run it printed NOTHING for commonx, and typex.pas lives
    #       in the commonx ROOT -- on the package unit search path (OtherUnitFiles
    #       ".;..;..\vcl"), not under lib. A stray ppu there is loaded and kills the compiler:
    #         PPU DESTROY DURING LOAD: symlist[436]=ENetworkError typ=5 in module TYPEX
    #         Error: (1026) Compilation raised exception internally
    #         EListError: List index exceeds bounds (1)
    #         Error: (lazarus) Compile package PackageCommonX_LCL 1.0: stopped with exit code 217
    #       Section 0 handles packages we KNOW we install, by path, independent of any XML.
    # Only compiler OUTPUT is removed. A stray .ppu/.o outside lib is removed only when its
    # own .pas/.pp sits beside it; commonx has ZERO versioned .ppu/.o (checked via svn), so
    # this cannot delete a checked-in file.

    # --- 0. Explicitly named packages (independent of packagefiles.xml) ---
    $script:CommonXArtifactsCleaned = 0
    foreach ($lpk in $ExtraPackageLpks) {
        if (-not $lpk) { continue }
        if (-not (Test-Path $lpk)) { continue }
        $pkgDir = Split-Path -Parent $lpk
        $pkgName = [IO.Path]::GetFileNameWithoutExtension($lpk)
        $removed = 0
        try {
            $libDir = Join-Path $pkgDir "lib"
            if (Test-Path $libDir) {
                $stale = @(Get-ChildItem -Path $libDir -Recurse -Include @("*.ppu","*.o","*.a","*.rsj","*.compiled") -ErrorAction SilentlyContinue)
                foreach ($f in $stale) {
                    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                    $removed++
                }
            }
            foreach ($rel in @(".", "..", "..\vcl")) {
                $d = Join-Path $pkgDir $rel
                if (-not (Test-Path $d)) { continue }
                foreach ($ext in @("*.ppu", "*.o")) {
                    $strays = @(Get-ChildItem -Path $d -Filter $ext -File -ErrorAction SilentlyContinue)
                    foreach ($f in $strays) {
                        $base = Join-Path $f.DirectoryName ([IO.Path]::GetFileNameWithoutExtension($f.Name))
                        if ((Test-Path ($base + ".pas")) -or (Test-Path ($base + ".pp"))) {
                            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                            $removed++
                        }
                    }
                }
            }
        } catch {
            Log-Warn "Could not clean build artifacts for ${pkgName} - $_"
        }
        $script:CommonXArtifactsCleaned += $removed
        if ($removed -gt 0) {
            Log-Info "Cleaned $removed stale build artifact(s) for ${pkgName} in ${pkgDir} before building - stale .ppu/.o make the compiler die with an internal error (1026)."
        } else {
            Log-Info "Package tree for ${pkgName} is clean - no stale build artifacts to remove."
        }
    }

    # --- 1. External packages (from packagefiles.xml) ---
    $pkgFilesXml = Join-Path $env:LOCALAPPDATA "lazarus\packagefiles.xml"
    if (Test-Path $pkgFilesXml) {
        try {
            [xml]$pkgXml = Get-Content $pkgFilesXml -Raw
            $userLinks = $pkgXml.CONFIG.UserPkgLinks
            $itemNodes = $userLinks.ChildNodes | Where-Object { $_.Name -match '^Item\d+$' }
            foreach ($it in $itemNodes) {
                $fileNode = $it.SelectSingleNode("Filename")
                $nameNode = $it.SelectSingleNode("Name")
                $file = if ($fileNode) { $fileNode.GetAttribute("Value") } else { $null }
                $pkgName = if ($nameNode) { $nameNode.GetAttribute("Value") } else { "unknown" }
                if (-not $file) { continue }
                if (-not [System.IO.Path]::IsPathRooted($file)) { continue }
                if ($file.StartsWith($LazarusDir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

                $pkgDir = Split-Path -Parent $file
                $libDir = Join-Path $pkgDir "lib"
                if (-not (Test-Path $libDir)) { continue }

                $stale = @(Get-ChildItem -Path $libDir -Recurse -Include @("*.ppu","*.o","*.a","*.rsj","*.compiled") -ErrorAction SilentlyContinue)
                if ($stale.Count -eq 0) { continue }

                Log-Info "Cleaning stale build artifacts in external package: $pkgName ($($stale.Count) file(s))"
                foreach ($f in $stale) {
                    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Log-Warn "Could not clean external package artifacts: $_"
        }
    }

    # --- 2. Lazarus built-in packages (components, ide packages, lcl, etc.) ---
    try {
        $lazarusLibDirs = @(Get-ChildItem -Path $LazarusDir -Recurse -Directory -Filter "lib" -ErrorAction SilentlyContinue | Where-Object {
            (Get-ChildItem -Path $_.FullName -Recurse -Filter "*.ppu" -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
        })
        foreach ($libDir in $lazarusLibDirs) {
            $stale = @(Get-ChildItem -Path $libDir.FullName -Recurse -Include @("*.ppu","*.o","*.a","*.rsj","*.compiled") -ErrorAction SilentlyContinue)
            if ($stale.Count -gt 0) {
                Log-Info "Cleaning stale build artifacts in Lazarus lib: $($libDir.FullName) ($($stale.Count) file(s))"
                foreach ($f in $stale) {
                    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        Log-Warn "Could not clean Lazarus package artifacts: $_"
    }
}

# c692: strip any unit artifact a previous run compiled from the COMPILER's own source tree
# into a Lazarus package output dir. The .sh half has had this since c655; the .ps1 half
# never did, and Windows is GOD's own workstation.
#
# Why this is reachable on Windows and not only on lazdev: $VPDir is a GIT CLONE of
# adaloveless/vibepascal -- Check-VPUpdates refuses to run without $VPDir\.git -- so the full
# compiler source tree is on disk beside whatever ppcx64.exe the extraction put there. The
# win64 bin tarball is bin-only (21 entries, 0 compiler\*.pas, measured c692 on
# vibepascal-v59-5c89c538b8-win64-bin.tar.gz), but it extracts INTO that clone, so the
# collision exists anyway. Measured c692 on the real trees: 207 compiler sources, 3 of whose
# unit names also exist in Lazarus -- compiler, macho and tokens. macho is the one that
# actually bit lazdev (c672: "Can't find unit FpImgReaderMachoFile", which reads exactly like
# a merge defect and is not).
#
# Preferring bin\ppcx64.exe (see $VPCompiler above) stops NEW wreckage; it does not remove
# wreckage already on disk. An orphaned .ppu/.o fails the build ON ITS OWN, so a box that
# ever ran the legacy compiler\ppcx64.exe layout stays broken on every future run with no
# signal a user could act on -- the same permanent-silent-degradation shape as c634.
#
# What counts as wreckage is decided structurally, never from a name list: for each unit name
# that exists BOTH beside the compiler binary and in the Lazarus tree, any .ppu/.o for that
# name that is NOT under the directory of its own Lazarus source is an orphan. Lazarus itself
# agrees and says so -- `Duplicate unit "macho" ... orphaned ppu "<path>"`.
function Clean-ShadowedUnitArtifacts {
    $ccDir = Split-Path -Parent $VPCompiler
    # After extraction the binary may sit in bin\, so ask the real source tree.
    if (-not (Get-ChildItem -Path $ccDir -Filter *.pas -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $ccDir = Join-Path $VPDir "compiler"
    }
    if (-not (Test-Path $ccDir)) { return }

    # LAST extension, not the first dot: the tree carries dotted unit filenames
    # (chatgpt.Dto.pas, generics.collections.ppu) and keying those on "chatgpt"/"generics"
    # would collide names that are not the same unit at all.
    $stem = { param($n) ($n -replace '\.[^.]*$', '').ToLowerInvariant() }

    $ccNames = @{}
    foreach ($f in (Get-ChildItem -Path $ccDir -Filter *.pas -File -ErrorAction SilentlyContinue)) {
        $ccNames[(& $stem $f.Name)] = $true
    }
    if ($ccNames.Count -eq 0) { return }

    # ONE pass over the Lazarus tree, not one per name: the compiler tree has ~200 sources and
    # the Lazarus tree has thousands of artifacts, so a scan per name would walk the tree 200
    # times for a list that is usually three entries long. Sources build the owner map,
    # artifacts are the candidates, and only names in $ccNames are ever held in memory.
    $owners = @{}
    $artifacts = @()
    foreach ($f in (Get-ChildItem -Path $LazarusDir -Recurse -File -ErrorAction SilentlyContinue)) {
        $b = (& $stem $f.Name)
        if (-not $ccNames.ContainsKey($b)) { continue }
        $ext = $f.Extension.ToLowerInvariant()
        $inOutput = ($f.FullName -match '[\\/](lib|units)[\\/]')
        if (($ext -eq '.pas' -or $ext -eq '.pp') -and (-not $inOutput)) {
            if (-not $owners.ContainsKey($b)) { $owners[$b] = @() }
            $owners[$b] += $f.DirectoryName
        } elseif (($ext -eq '.ppu' -or $ext -eq '.o') -and $inOutput) {
            $artifacts += $f.FullName
        }
    }

    $removed = 0
    foreach ($a in $artifacts) {
        $b = (& $stem (Split-Path -Leaf $a))
        # No Lazarus source owns this name -- not ours to judge, leave it alone.
        if (-not $owners.ContainsKey($b)) { continue }
        $ok = $false
        foreach ($d in $owners[$b]) {
            if ($a.StartsWith(($d + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
        }
        if ($ok) { continue }
        Remove-Item -Force -LiteralPath $a -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $a)) {
            $removed++
            Log-Info "Removed shadowed unit artifact $a -- that unit name also exists beside the compiler binary and this is not its own package's output."
        }
    }

    if ($removed -gt 0) {
        Log-Warn "Removed $removed unit artifact(s) left by an earlier build that compiled a COMPILER source file into a Lazarus package. Left in place they keep failing the IDE build with `"Can't find unit ...`" on every future run."
    }
}

function Rebuild-IDE {
    Log-Header "Rebuilding Lazarus IDE (lazarus.exe)"

    $lazbuildExe = Join-Path $LazarusDir "lazbuild.exe"
    if (-not (Test-Path $lazbuildExe)) {
        Log-Err "lazbuild.exe not found -- cannot build IDE. Run rebuild first."
        return
    }

    if (-not (Test-Path $VPCompiler)) {
        Log-Err "VibePascal compiler not found at $VPCompiler"
        return
    }

    $envDir = Join-Path $env:LOCALAPPDATA "lazarus"
    if (-not (Test-Path $envDir)) {
        New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    }

    Log-Info "Using compiler: $VPCompiler"
    Log-Info "Building IDE with win32 widgetset..."

    $lazarusExe = Join-Path $LazarusDir "lazarus.exe"
    $preBuildTime = if (Test-Path $lazarusExe) { (Get-Item $lazarusExe).LastWriteTime } else { $null }

    # Configure-Environment writes MakeFilename to environmentoptions.xml, but on
    # fresh bootstraps lazbuild has been observed to fall back to PATH lookup for
    # `make` and fail with "Make not found" when MinGW make is in a versioned FPC
    # subdir (Finn 2026-04-21, item #39). Prepend the discovered make dir to PATH
    # for the duration of the lazbuild invocation as defense-in-depth.
    $oldPath = $env:PATH
    $makeForPath = Find-Make
    if ($makeForPath) {
        $makeDir = Split-Path -Parent $makeForPath
        if ($env:PATH -notlike "*$makeDir*") {
            $env:PATH = "$makeDir;$env:PATH"
            Log-Info "PATH prepended with make dir: $makeDir"
        }
    } elseif ($script:MakeRejected.Count -gt 0) {
        # c718 -- say so rather than skipping in silence. Before the GNU check this branch
        # could not be reached on an ex-Delphi box: Find-Make handed back Borland's make and
        # we prepended C:\Program Files (x86)\Embarcadero\...\bin to PATH for lazbuild.
        Log-Warn "Not prepending a make dir to PATH -- no GNU make found (rejected: $($script:MakeRejected -join '; '))"
    }

    # GOD mp3nzr3r: ensure customdrawn LCL controls are installed by default on
    # every site, so users do not need to run `lazbuild --add-package` manually.
    # --build-ide (not --build-ide-minimal) is required because TBuildIDE.Minimal
    # skips LoadAutoInstallPackages.
    # lazbuild CONTRACT (ide/lazbuild.lpr:1668,1725,1760,1578): `--add-package` is a MODE
    # SWITCH that takes NO argument -- the .lpk paths are POSITIONAL args collected into
    # Files (Files.Assign(NonOptions) -> AddPackagesToInstallList(Files)). So the correct
    # shape is ONE --add-package followed by N paths. (Measured on lazdev c625: repeating
    # the switch also exits 0 -- the handler is evaluated once per option NAME -- so this
    # is a contract-correctness fix, NOT a bug fix. But `--add-package=PATH` IS rejected,
    # exit 6 "Option at position 1 does not allow an argument" -- my c291 bug that killed
    # the r6 darwin builds.) Collect paths first, prefix the switch once.
    $addPkgLpks = @()

    $customdrawnLpk = Join-Path $LazarusDir "components\customdrawn\customdrawn.lpk"
    if (Test-Path $customdrawnLpk) {
        $addPkgLpks += $customdrawnLpk
        Log-Info "Including customdrawn LCL controls (--add-package)"
    } else {
        Log-Info "customdrawn.lpk not found at $customdrawnLpk -- skipping"
    }

    # GOD mss4zlof / mt0snq31 (2026-08-20): TAChart (incl. TPieSeries) was missing from
    # auto-update-delivered IDEs. Adding tachartlazaruspkg.lpk to the AutoInstall list so
    # it ships on every build. TAChart compiles clean under -Munleashed after tadrawercanvas.pas:13
    # gained {$MODE ObjFPC} (Wynona 2026-08-11, verified HEAD ce12737bc1). This is a CORE
    # Lazarus component — not optional like commonx — so it does NOT get dropped on retry.
    $tachartLpk = Join-Path $LazarusDir "components\tachart\tachartlazaruspkg.lpk"
    if (Test-Path $tachartLpk) {
        $addPkgLpks += $tachartLpk
        Log-Info "Including TAChart LCL controls (--add-package)"
    } else {
        Log-Warn "TAChart package not found at $tachartLpk -- TPieSeries will be MISSING from the designer palette"
    }

    # GOD mrxnqj9g / mrxnwdze (2026-07-23): TTouchButton is GOD's OWN custom component
    # and lives in the commonx LCL package set. Those packages ship with every build and
    # MUST be installed here, or GOD's components are missing from the designer palette.
    # Same --add-package mechanism as customdrawn above (separate args, NEVER
    # --add-package=PATH -- that form is rejected by lazbuild; my c291 bug killed r6).
    #
    # ONLY PackageCommonX_LCL is added. commonx also carries BGRABitmap/LazActiveX, but
    # this fork already vendors those in-tree (components\bgrabitmap, components\activex);
    # registering commonx's duplicates would reproduce the "duplicate unit name/file name"
    # package-install failure GOD hit in cycle 322 #182.
    # c634: discovery moved to Get-CommonXRoot so the pre-build decision, the build and the
    # post-build verification all resolve the SAME tree. When those lists drift, the checker
    # and the builder disagree and the self-heal trigger below can never be satisfied.
    $commonxRoot = Get-CommonXRoot
    $commonxLpkPath = $null

    # c633 (GOD mt3gtf55): a fix on commonx SVN HEAD only helps if the LOCAL working copy is
    # CURRENT. The updater used to build whatever was on disk, so a stale checkout (predating
    # Knox's r6011/r6014 -Mdelphiunicode fix) re-hit error 3069 on the first attempt and was
    # then silently DROPPED on retry -- an IDE that builds but has NO TBetterWebBrowser /
    # TTouchButton at all (exactly what GOD reported). Refresh the working copy BEFORE
    # building. Non-fatal in every failure mode: worst case is today's behavior (stale commonx
    # dropped on retry), never a missing IDE (the c626 guarantee).
    if ($commonxRoot) {
        $svnCmd = Get-Command svn -ErrorAction SilentlyContinue
        if ($svnCmd) {
            $svnOut = (& svn update $commonxRoot 2>&1 | Out-String)
            if ($LASTEXITCODE -eq 0) {
                Log-Info "Refreshed commonx SVN working copy ($commonxRoot) -- r6011/r6014 -Mdelphiunicode fix picked up."
            } else {
                $svnErrLines = ($svnOut.Trim() -split '[\r\n]+') | Where-Object { $_ } | Select-Object -Last 3
                Log-Warn "svn update of commonx FAILED (exit $LASTEXITCODE). If TBetterWebBrowser/TTouchButton are still missing after this run, run:  svn update $commonxRoot  then re-run auto-update.bat."
                Log-Warn "  svn output tail: $($svnErrLines -join ' ;; ')"
            }
        } else {
            Log-Warn "svn.exe not found on PATH -- cannot refresh commonx automatically. If TBetterWebBrowser/TTouchButton are still missing after this run, run:  svn update $commonxRoot  then re-run auto-update.bat."
        }
    }

    if ($commonxRoot) {
        $commonxLpk = Get-ChildItem -Path $commonxRoot -Filter "PackageCommonX_LCL.lpk" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($commonxLpk) {
            $commonxLpkPath = $commonxLpk.FullName
            $addPkgLpks += $commonxLpkPath
            Log-Info "Including commonx LCL controls incl. TTouchButton ($commonxLpkPath)"
        } else {
            Log-Warn "PackageCommonX_LCL.lpk not found under $commonxRoot -- TTouchButton will be MISSING from the designer palette"
        }
    } else {
        Log-Info "commonx tree not found -- skipping commonx LCL packages (set COMMONX_DIR to override)"
    }

    # ONE switch, then every collected path as a positional arg (see contract note above).
    $addPkgArgs = @()
    if ($addPkgLpks.Count -gt 0) {
        $addPkgArgs = @("--add-package") + $addPkgLpks
    }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    # GOD mrxp2wpx / mt3gtf55: an OPTIONAL THIRD-PARTY package must NEVER be able to take
    # the whole IDE down. commonx is the only --add-package entry whose source this repo does
    # not control. ORIGINAL cause, fixed commonx-side at svn r6011/r6014 (2026-07-23): the
    # .lpk forced `-Mdelphi` (String=AnsiString) while --build-ide compiles
    # `-Munleashed -Scghi` (String=UnicodeString). Under that collision commonx's
    # transitively-compiled CORE units failed to build --
    #   commandline.pas(310,36) -> stringx.SplitString(...; var sLeft, sRight: string; ...)
    #   Error (3069) Call by var for arg no. 4 ... Got "AnsiString" expected "UnicodeString"
    # -- which aborts "Compile AutoInstall Packages" and leaves NO lazarus.exe at all.
    # r6011 flipped the .lpk CustomOptions to -Mdelphiunicode; r6014/r6015 swept
    # {$I DelphiDefs.inc} across the closure (VERIFIED from source c631: HEAD r6017 has
    # CustomOptions=-Mdelphiunicode -dLCL and no {$mode} pin in DelphiDefs.inc). The updater
    #
    # c635 MEASUREMENT (2026-08-25, GOD mt917m2w/mt917vcr) -- READ BEFORE TRUSTING THE c631 CLAIM.
    # Measured on lazdev against commonx SVN HEAD r6142, VibePascal ppcx64 -Twin64 -Scghi -dLCL,
    # the FULL PackageCommonX_LCL closure (167 units, 344,501 lines):
    #   -Mdelphiunicode (what the .lpk sets) -> EXIT 0, clean. commonx source is NOT broken.
    #   -Munleashed     (the IDE build mode) -> FATAL typex.pas(43,3) "( expected but [ found";
    #                                           fixing that exposes typex.pas(226,25) Delphi generics.
    # typex.pas is Delphi-dialect by construction and CANNOT compile under -Munleashed. The
    # "non-member transitive units inherit the package -M" note is UNCONFIRMED for the real
    # --build-ide path -- it is what stopped the investigation last time, and the build still fails.
    # The first-error capture added this cycle is what will settle it from a real Windows run.
    #
    # c636 RESOLVED IT (GOD mt93q21h, 2026-08-25): the real Windows run came back and the failure
    # was NOT the -Munleashed parse error at all -- it was an internal compiler crash loading a
    # stale ppu (PPU DESTROY DURING LOAD ... in module TYPEX / error 1026 / exit 217). typex.pas
    # mode-portability was never what broke GOD's build and is NOT a palette blocker; it stays a
    # real but SEPARATE question owned by Knox as commonx SME.
    # now runs `svn update` on the commonx tree (above) so a lagging checkout cannot
    # silently re-fail -- see the c633 block. This retry remains purely as the LAST-RESORT
    # guarantee: a missing component on the palette is bad, but a machine with no IDE is far
    # worse (c626). If commonx is dropped here despite a successful svn update, the cause is
    # NEW -- read the first 'Error:' line printed above, do not assume the old 3069.
    # c636 (GOD mt93q21h): attempt 1 is the ONLY attempt that includes commonx, so the stale-
    # artifact cleanup has to happen HERE, before it -- not in the retry that drops the package.
    # c692: strip any unit artifact an earlier run compiled from the COMPILER source tree
    # into a Lazarus package output dir. Must run BEFORE attempt 1 -- such an artifact fails
    # the build on its own, even with the compiler moved out of that tree. Mirrors the .sh
    # half, which has called clean_shadowed_unit_artifacts at exactly this point since c655.
    Clean-ShadowedUnitArtifacts

    if ($commonxLpkPath) {
        Clean-StalePackageArtifacts -ExtraPackageLpks @($commonxLpkPath)
    }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Log-Warn "IDE build failed on attempt $($attempt-1); cleaning stale artifacts and retrying..."
            Sanitize-PackageRegistrations
            if ($commonxLpkPath) {
                Clean-StalePackageArtifacts -ExtraPackageLpks @($commonxLpkPath)
            } else {
                Clean-StalePackageArtifacts
            }
            Start-Sleep -Seconds 2
        }

        $attemptPkgArgs = $addPkgArgs
        if ($attempt -gt 1 -and $commonxLpkPath) {
            $keptLpks = @($addPkgLpks | Where-Object { $_ -ne $commonxLpkPath })
            $attemptPkgArgs = @()
            if ($keptLpks.Count -gt 0) { $attemptPkgArgs = @("--add-package") + $keptLpks }
            # Dropping the --add-package argument is NOT enough on its own: the package is
            # still in the IDE's PERSISTED auto-install list and would be recompiled from
            # config, failing this attempt identically to the last one. Purge it from the
            # pcp dir lazbuild is actually passed ($envDir).
            # c640 correction: an earlier note here warned that $envDir might differ from the
            # dir Sanitize-PackageRegistrations hardcodes. Measured -- it does not. Both are
            # Join-Path $env:LOCALAPPDATA "lazarus", computed identically, and --pcp=$envDir is
            # the only pcp this script ever passes. Do not "fix" a divergence that is not there.
            Remove-PackageFromAutoInstall -PcpDir $envDir -PackageName "PackageCommonX_LCL"
            Log-Warn "Retrying WITHOUT commonx (PackageCommonX_LCL) so the IDE still builds."
            Log-Warn "  The updater ran 'svn update' on the commonx tree before this build; if commonx still fails here, a stale checkout is NOT the cause."
            Log-Warn "  The first 'Error:' line printed above is the cause. If it names a commonx unit with error 3069, the svn update did not take effect (see the svn messages from earlier in this run)."
            Log-Warn "  Consequence: commonx components (incl. TTouchButton / TBetterWebBrowser) will NOT be on the designer palette this run."
        }

        # c635 (GOD mt917m2w/mt917vcr): tee attempt 1 to a log so the FIRST compiler error can be
        # replayed in the final failure block. That line was previously printed only mid-build, and
        # a pasted run log is truncated from the TOP -- so the single line naming the failing unit
        # was exactly the line that never reached us. Tee-Object does not change what is displayed
        # (Where-Object still gates that) and $LASTEXITCODE still reports lazbuild, not the pipeline.
        $attemptLog = Join-Path ([IO.Path]::GetTempPath()) ("lazbuild_attempt" + $attempt + ".log")
        # --build-ide=-Sci: lazbuild compiles ide\lazarus.pp with the compiler DIRECTLY and passes
        # no syntax switches of its own, while the IDE sources use C-style operators (`s+=...`).
        # The make route has always added -Sci (ide/Makefile.fpc [compiler] options); without it
        # this step dies at ide\checkcompileropts.pas(199) "C styled assignment operators are
        # turned off" whenever the compiler's fpc.cfg does not already carry -Sc. Idempotent when
        # it does. c699: e08afd4a5a fixed this on auto-update.sh and left the .ps1 -- i.e. fixed
        # it everywhere EXCEPT the platform GOD actually runs (auto-update.bat -> this file).
        & $lazbuildExe --lazarusdir=$LazarusDir --build-ide=-Sci --compiler=$VPCompiler --pcp=$envDir --ws=win32 @attemptPkgArgs 2>&1 |
            Tee-Object -FilePath $attemptLog |
            Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }
        $buildExit = $LASTEXITCODE
        # Only attempt 1 includes commonx, so only its first error explains a dropped package.
        if ($attempt -eq 1 -and $buildExit -ne 0 -and (Test-Path $attemptLog)) {
            try {
                $feMatch = Select-String -Path $attemptLog -Pattern "(Error|Fatal):" | Select-Object -First 1
                if ($feMatch) { $script:CommonXFirstError = ($feMatch.Line).Trim() }
                # c636: "(1026) Compilation raised exception internally" names no unit. The lines
                # that do are the PPU-load lines above it, and they match neither Error: nor Fatal:.
                $ppuMatch = Select-String -Path $attemptLog -Pattern "PPU DESTROY DURING LOAD" | Select-Object -First 1
                if ($ppuMatch) { $script:CommonXPpuHint = ($ppuMatch.Line).Trim() }
            } catch { }
        }
        Remove-Item $attemptLog -Force -ErrorAction SilentlyContinue
        if ($buildExit -eq 0) {
            if ($attempt -gt 1 -and $commonxLpkPath) {
                Log-Warn "IDE built WITHOUT commonx LCL packages -- TTouchButton is MISSING from the palette (see cause above)."
            }
            break
        }
    }

    $ErrorActionPreference = $prevEAP
    $env:PATH = $oldPath

    if ($buildExit -ne 0) {
        Log-Err "lazarus.exe build failed with exit code $buildExit after $maxAttempts attempts"
        return
    }

    if (-not (Test-Path $lazarusExe)) {
        Log-Err "lazarus.exe build failed -- binary not found!"
        return
    }

    $postBuildTime = (Get-Item $lazarusExe).LastWriteTime
    if ($preBuildTime -and $postBuildTime -le $preBuildTime) {
        Log-Err "lazarus.exe build failed silently -- binary was not updated (stale file from previous build)"
        return
    }

    $size = (Get-Item $lazarusExe).Length / 1MB
    Log-Ok ("lazarus.exe rebuilt ({0:N1} MB)" -f $size)

    # GOD directive moehki0x (2026-04-25): MetaDarkStyle dark-mode IDE skin is
    # a flagship feature. Fail loud if Rebuild-IDE produced a binary missing it.
    $mds = Test-MetaDarkStyleInstalled -Dir $LazarusDir
    if ($mds.Ok) {
        Log-Ok "MetaDarkStyle dark mode installed"
        foreach ($n in $mds.Notes) { Log-Info "  $n" }
        Clear-FeatureAttempt -Feature "metadarkstyle"
    } else {
        Log-Err "MetaDarkStyle dark mode NOT installed -- this is a regression GOD will notice."
        foreach ($n in $mds.Notes) { Log-ErrDetail "  $n" }
        Log-ErrDetail "Fix: re-pull origin/main, then run -ResetConfig -ForceRebuild."
        Record-FeatureAttempt -Feature "metadarkstyle"   # c699: lets a steady-state run heal this once
    }

    # GOD mu3jfytu (2026-09-16): the docked "modern Delphi style" layout is the default and
    # rides two core packages. Same rule as MetaDarkStyle above: fail loud when the binary
    # we just built does not carry them, because a floating-window IDE is exactly what GOD
    # asked us to stop shipping.
    $dock = Test-DockedLayoutInstalled -Dir $LazarusDir
    if ($dock.Ok) {
        Log-Ok "Docked IDE layout (AnchorDocking + docked form editor) installed"
        foreach ($n in $dock.Notes) { Log-Info "  $n" }
        Clear-FeatureAttempt -Feature "docked"
    } else {
        Log-Err "Docked IDE layout NOT installed -- the IDE will open as floating windows (GOD mu3jfytu)."
        foreach ($n in $dock.Notes) { Log-ErrDetail "  $n" }
        Log-ErrDetail "Fix: re-pull origin/main, then run -ForceRebuild and read the FIRST 'Error:' line."
        Record-FeatureAttempt -Feature "docked"   # c699: lets a steady-state run heal this once
    }

    # c634 (GOD mt8zo2vh): verify GOD's own components actually made it into the binary.
    # Until now the ONLY signal that PackageCommonX_LCL had been dropped was a Log-Warn
    # buried mid-build, while the run still ended "[OK] lazarus.exe rebuilt" -- so a build
    # that silently lost TBetterWebBrowser / TTouchButton looked identical to a good one.
    # Record the attempted state either way so the pre-build self-heal trigger knows whether
    # retrying is worthwhile.
    $cx = Test-CommonXComponentsInstalled -Dir $LazarusDir
    $stampPath = Get-CommonXStampPath
    if ($cx.Checked -and -not $cx.Ok) {
        Log-Err "commonx components NOT installed: $($cx.Missing -join ', ')"
        Log-ErrDetail "  Forms using them will fail to open in the designer with:"
        Log-ErrDetail '    Unable to find the component class "TBetterWebBrowser" ... it is needed by unit <your form>.pas'
        Log-ErrDetail "  The FIRST 'Error:' line printed above is the cause -- it names the commonx unit that"
        Log-ErrDetail "  failed to compile under the IDE build mode, which is why the retry dropped the package."
        if ($script:CommonXFirstError) {
            Log-ErrDetail "  FIRST COMPILER ERROR from the attempt that included commonx (THIS IS THE CAUSE):"
            Log-ErrDetail ("    " + $script:CommonXFirstError)
            if ($script:CommonXPpuHint) {
                Log-ErrDetail "  ...and this names the unit it died on (an internal compiler error carries no unit):"
                Log-ErrDetail ("    " + $script:CommonXPpuHint)
                Log-ErrDetail "  A 'PPU DESTROY DURING LOAD' + error 1026 pair means a ppu on the search path could not"
                Log-ErrDetail ("  be loaded - normally a stale one. This run removed " + $script:CommonXArtifactsCleaned + " stale artifact(s) before building,")
                Log-ErrDetail "  so if you are still seeing this, staleness is NOT the remaining cause."
            }
        } else {
            Log-ErrDetail "  (no compiler error captured this run -- commonx may have been skipped before the"
            Log-ErrDetail "   build rather than failing during it)"
        }
        try {
            $stampDir = Split-Path -Parent $stampPath
            if (-not (Test-Path $stampDir)) { New-Item -ItemType Directory -Path $stampDir -Force | Out-Null }
            Set-Content -Path $stampPath -Value (Get-CommonXInstallStamp) -Encoding ASCII
        } catch { }
    } elseif ($cx.Checked) {
        Log-Ok "commonx components installed (TBetterWebBrowser, TTouchButton on the 'Digital Tundra' palette)"
        if (Test-Path $stampPath) { Remove-Item $stampPath -Force -ErrorAction SilentlyContinue }
    } else {
        foreach ($n in $cx.Notes) { Log-Info "  $n" }
    }

    $starterExe = Join-Path $LazarusDir "startlazarus.exe"
    if (-not (Test-Path $starterExe)) {
        Log-Info "Building startlazarus..."
        # Use lazbuild against ide/startlazarus.lpi rather than `make starter`.
        # `make starter` invokes raw fpc and the project's generated Makefile only
        # exports static -Fu paths; on fresh extracts where lazbuild built LCL via
        # the package graph, the Makefile's relative LCL paths don't resolve and
        # fpc fails with "(10022) Can't find unit InterfaceBase used by Interfaces"
        # (Bruno/Finn ZENBOOK r19 smoke, 2026-05-25). lazbuild walks the .lpi
        # RequiredPackages chain (IdePackager -> IdeConfig -> IDEIntf -> LCL) and
        # consumes the same .ppus the Rebuild-IDE step just produced.
        $starterLpi = Join-Path $LazarusDir "ide\startlazarus.lpi"
        if (Test-Path $starterLpi) {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & $lazbuildExe --lazarusdir=$LazarusDir --compiler=$VPCompiler --pcp=$envDir --ws=win32 $starterLpi 2>&1 |
                Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }
            $starterExit = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
            if ($starterExit -eq 0 -and (Test-Path $starterExe)) {
                $starterSize = (Get-Item $starterExe).Length / 1MB
                Log-Ok ("startlazarus.exe built ({0:N1} MB)" -f $starterSize)
            } else {
                Log-Err "startlazarus.exe build failed (lazbuild exit $starterExit)"
            }
        } else {
            Log-Err "ide\startlazarus.lpi not found -- cannot build startlazarus"
        }
    }
}

# --- Is the IDE the user LAUNCHES actually built from the source we just synced? ----------
# (Lars, c698 2026-09-17 -- GOD mu5nkho9 / mu24b48i / mu3jfytu; mirror of auto-update.sh)
#
# Print-Summary printed "Lazarus HEAD: <sha>" right after pulling, which READS like a
# statement about lazarus.exe and is not one: on a steady-state box the IDE is never
# rebuilt, so HEAD moves and the binary does not.
#
# Measured 2026-09-17, which is what turns this from tidiness into a defect: all four of
# GOD's UX deliverables -- 7256de3e38 (Linux dark editor default), 9b044e4527 (docked
# layout default), a5ffe414b8 and e08afd4a5a -- landed 2026-09-16 and are NOT ancestors of
# the newest published release tag lazarus-4.99-vp-20260818-r25 (commit ce12737bc1,
# 2026-08-12), which is 99 commits behind main. So someone running a downloaded r25 -- or
# any IDE this updater has not rebuilt since -- can set the dark colour scheme, restart,
# and CORRECTLY report "still broken" while the fix itself is perfectly good.
#
# Compared BY DATE on purpose: the binary carries no commit stamp, so "newer than" is the
# strongest honest claim available. One-sided -- it can prove a binary is STALE, never that
# it is current -- and the message says so. An unreadable git (Get-GitOutput yields "" on
# failure) is UNKNOWN, never "up to date".
function Get-IdeBinaryStaleness {
    $exe = Join-Path $LazarusDir "lazarus.exe"
    if (-not (Test-Path $exe)) { return @{ Status = 'NoBinary' } }
    $binWhen = (Get-Item $exe).LastWriteTime
    $headEpochText = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("log", "-1", "--format=%ct", "HEAD")
    if (-not $headEpochText -or ($headEpochText.Trim() -notmatch '^\d+$')) { return @{ Status = 'Unknown' } }
    $headEpoch = [int64]$headEpochText.Trim()
    $binEpoch = [int64]($binWhen.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
    $behind = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-list", "--count", "--since=@$binEpoch", "HEAD")
    if (-not $behind) { $behind = '?' } else { $behind = $behind.Trim() }
    $headWhen = ([datetime]'1970-01-01').AddSeconds($headEpoch).ToLocalTime()
    if ($binEpoch -ge $headEpoch) {
        return @{ Status = 'Fresh'; BinWhen = $binWhen; HeadWhen = $headWhen; Behind = $behind }
    }
    return @{ Status = 'Stale'; BinWhen = $binWhen; HeadWhen = $headWhen; Behind = $behind }
}

function Report-IdeBinaryStaleness {
    $r = Get-IdeBinaryStaleness
    switch ($r.Status) {
        'Fresh'    { Log-Ok ("IDE binary is newer than every commit in this checkout (lazarus.exe built {0:yyyy-MM-dd HH:mm})" -f $r.BinWhen) }
        'Stale'    {
            # -NoBuild/-Check asked for exactly this outcome, so it is a FINDING, not a
            # failure of the run: same sentence, WARN severity, no ErrorCount/exit 1.
            $msg = ("IDE BINARY IS OLDER THAN YOUR SOURCE -- lazarus.exe was built {0:yyyy-MM-dd HH:mm} and {1} commit(s) have landed since (newest {2:yyyy-MM-dd HH:mm}). The IDE you launch does NOT contain them. Rebuild with: auto-update.bat -ForceRebuild" -f $r.BinWhen, $r.Behind, $r.HeadWhen)
            if ($NoBuild -or $Check) { Log-Warn ($msg + " (not done here: -NoBuild/-Check)") } else { Log-Err $msg }
        }
        'NoBinary' { Log-Warn "No lazarus.exe in $LazarusDir yet -- nothing to compare against the source (run -ForceRebuild)" }
        default    { Log-Warn "Cannot tell whether lazarus.exe matches this source (git could not be read in $LazarusDir) -- verdict UNKNOWN, not 'up to date'" }
    }
}

# --- The summary must report what HAPPENED, not what was AVAILABLE ----------------------
# (Lars, c719 2026-09-18 -- reported by Miles/MonitoringSystemsDeveloper from MVMJ26.)
#
# Miles ran `auto-update.bat -Check` on 2026-09-18 and read "[+] Lazarus updated" over
# "Lazarus HEAD: 7f9f209f0b" -- while his box stayed 16 days and 115 commits stale. Nothing
# was wrong with his clone: it is a real clone of adaloveless/Lazarus on main, tracking
# origin/main, working tree clean (his four `git -C C:\lazarus` lines, 2026-09-18).
#
# The cause is that $script:LazarusUpdated does not mean "updated". Check-LazarusOrigin sets
# it when `HEAD..origin/main` counts MORE THAN ZERO -- i.e. when commits are AVAILABLE -- and
# `-Check` then prints the summary and exits at the early-exit block below, BEFORE
# Pull-LazarusOrigin is ever called. So on the one path advertised as a read-only dry run,
# "[+] Lazarus updated" was printed precisely when nothing had been updated, and the more
# commits the user was missing, the more confidently it said so. $script:VPUpdated and
# $script:UpstreamUpdated carry exactly the same defect on the two lines above it.
#
# The fix is to stop reporting a flag and start reporting the repository: capture HEAD before
# anything pulls and compare it at print time. That is true on every path at once -- it also
# catches a pull that was attempted and FAILED, which the flag never could, and which is the
# other half of Miles's ambiguity (an already-up-to-date `pull --ff-only` leaves no reflog
# entry, so his transcript alone cannot separate "never pulled" from "pulled nothing").
# An unreadable git is UNKNOWN, never "no changes" (c675, Steve's non-repository -Check).
function Report-RepoOutcome {
    param(
        [string]$Label,      # "Lazarus", "VibePascal", "Lazarus upstream"
        [bool]$Available,    # the Check-* flag: new commits were AVAILABLE, which is not the same as applied
        $Before,             # head stamp taken before this run pulled anything ($null = unreadable)
        $After,              # head stamp at print time ($null = unreadable)
        [string]$Detail,     # why an available update may not have landed
        [string]$State = "checked"   # c722: "not-configured" / "unknown" / "checked"
    )
    # c722 -- LABEL, never suppress. A line that vanishes is indistinguishable from a check
    # that silently did not run, so an unchecked comparison says so in the same slot the real
    # verdict would have occupied -- and prints NO sha, because the only sha available here is
    # the origin head and that is exactly what gets misread as an upstream verdict.
    if ($State -eq "not-configured") {
        Write-Host "  [?] $Label : NOT CHECKED -- no 'upstream' remote in $LazarusDir, so this run never compared against fpc/Lazarus. That is not 'no changes'. Add it with: git remote add upstream https://github.com/fpc/Lazarus.git" -ForegroundColor Yellow
        return
    }
    if ($State -eq "unknown") {
        Write-Host "  [?] $Label : UNKNOWN -- the 'upstream' remote is configured but upstream/main could not be read in $LazarusDir, so nothing was compared. That is not 'no changes' -- see the [ERROR] line above." -ForegroundColor Yellow
        return
    }
    if (-not $Before -or -not $After) {
        Write-Host "  [?] $Label : HEAD could not be read, so this run's outcome is UNKNOWN -- not 'no changes'" -ForegroundColor Yellow
        return
    }
    if ($Before.Sha -ne $After.Sha) {
        Write-Host "  [+] $Label updated: $($Before.Short) -> $($After.Short) (HEAD now dated $($After.When))" -ForegroundColor Green
        return
    }
    if ($Available) {
        Write-Host "  [!] $Label NOT updated -- new commit(s) are available but HEAD is still $($After.Short) dated $($After.When). $Detail" -ForegroundColor Yellow
        return
    }
    Write-Host "  [-] $Label : no changes (HEAD $($After.Short) dated $($After.When))" -ForegroundColor Cyan
}

function Print-Summary {
    Log-Header "Update Summary"

    # Read the repositories, not the flags (c719). The HEAD date prints on every branch on
    # purpose: a stale box is then visible on sight, without anyone having to know a sha.
    $lazNow = Get-HeadStamp -WorkDir $LazarusDir
    $vpNow  = Get-HeadStamp -WorkDir $VPDir
    if ($Check) {
        $applyHint = "-Check reports only; it never pulls. Run auto-update.bat to apply them."
    } else {
        $applyHint = "the pull did NOT land -- see the [ERROR]/[WARN] lines above."
    }
    # The upstream merge and the origin pull move the SAME HEAD, so the mid-point stamp is
    # what keeps the two lines attributable. On the -Check path it is $null (neither ran) and
    # both lines correctly compare against the run's starting HEAD.
    if ($script:LazarusHeadAfterUpstream) { $lazMid = $script:LazarusHeadAfterUpstream } else { $lazMid = $lazNow }
    if ($script:LazarusHeadAfterUpstream) { $originBefore = $script:LazarusHeadAfterUpstream } else { $originBefore = $script:LazarusHeadBefore }

    if (-not $script:UpstreamConfigured) {
        $upstreamState = "not-configured"
    } elseif ($script:UpstreamUnknown) {
        $upstreamState = "unknown"
    } else {
        $upstreamState = "checked"
    }

    Report-RepoOutcome -Label "VibePascal" -Available $script:VPUpdated -Before $script:VPHeadBefore -After $vpNow -Detail $applyHint
    Report-RepoOutcome -Label "Lazarus upstream" -Available $script:UpstreamUpdated -Before $script:LazarusHeadBefore -After $lazMid -Detail $applyHint -State $upstreamState
    Report-RepoOutcome -Label "Lazarus" -Available $script:LazarusUpdated -Before $originBefore -After $lazNow -Detail $applyHint

    if ($script:LocalBuildProductsRestored) {
        Write-Host "  [+] Local build products rebuilt" -ForegroundColor Green
    } elseif ($script:BuildProductsWereMissing) {
        Write-Host "  [!] Local build products missing" -ForegroundColor Yellow
    }

    if ($script:CheckFailed) {
        Write-Host ""
        Log-ErrDetail "Verdict UNKNOWN: a repository could not be read or refreshed (see the [ERROR]/[WARN] lines above). This is NOT 'up to date'."
    } elseif (-not $script:VPUpdated -and -not $script:UpstreamUpdated -and -not $script:LazarusUpdated -and -not $script:BuildProductsWereMissing) {
        Write-Host ""
        if ($script:UpstreamConfigured) {
            Log-Ok "Everything is up to date. Nothing to do."
        } else {
            # c722 -- bound the claim by what was actually checked. Upstream was skipped.
            Log-Ok "Everything that was checked is up to date. Nothing to do. (Upstream fpc/Lazarus was NOT among them -- see the line above.)"
        }
    }

    Write-Host ""
    $lazHead = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("log", "--oneline", "-1")
    $vpHead = Get-GitOutput -WorkDir $VPDir -GitArgs @("log", "--oneline", "-1")
    if (-not $lazHead) { $lazHead = "(unreadable -- git log failed in $LazarusDir)" }
    if (-not $vpHead) { $vpHead = "(unreadable -- git log failed in $VPDir)" }
    Write-Host "Lazarus HEAD: $lazHead"
    Write-Host "VibePascal HEAD: $vpHead"

    # c720 -- the VibePascal VERSION as it stands NOW, re-read from dist\LATEST.txt at print
    # time rather than remembered. The mid-run "dist LATEST.txt currently names ..." line is a
    # PRE-PULL reading; this is the end state, and when the two differ it says so outright.
    # Unreadable is reported as UNKNOWN, never as silence (c675).
    $vpVersionNow = Get-VPDistVersion
    if ($vpVersionNow) {
        if ($script:VPVersionBefore -and $script:VPVersionBefore -ne $vpVersionNow) {
            Write-Host "VibePascal version: $vpVersionNow  (was $($script:VPVersionBefore) when this run started)"
        } else {
            Write-Host "VibePascal version: $vpVersionNow"
        }
    } else {
        Write-Host "VibePascal version: UNKNOWN -- $VPDir\dist\...\LATEST.txt is missing or unreadable. This is NOT 'unchanged'."
    }

    # The two HEAD lines above describe the SOURCE. This one describes the BINARY.
    Report-IdeBinaryStaleness
}

function Test-LazarusDirectoryQuality {
    # PowerShell port of CheckLazarusDirectoryQuality from
    # ide/packages/ideconfig/initialsetupproc.pas. Returns:
    #   "Compatible"   = matches IDE version, all subdirs present
    #   "WrongVersion" = structure ok but ide/packages/ideconfig/version.inc != lazversion.pas
    #   "Incomplete"   = required subdir/file missing
    #   "Invalid"      = directory does not exist
    param([string]$Dir)

    if (-not (Test-Path $Dir)) {
        return @{ Quality = "Invalid"; Note = "Directory not found: $Dir" }
    }

    $required = @(
        "lcl",
        "packager\globallinks",
        "ide",
        "components",
        "ide\lazarus.lpi",
        "ide\packages\ideconfig\version.inc"
    )
    foreach ($sub in $required) {
        $full = Join-Path $Dir $sub
        if (-not (Test-Path $full)) {
            return @{ Quality = "Incomplete"; Note = "Missing $sub" }
        }
    }

    # Compare version.inc with lazversion.pas constant (laz_major.laz_minor)
    $versionIncFile = Join-Path $Dir "ide\packages\ideconfig\version.inc"
    $verLine = (Get-Content $versionIncFile -TotalCount 1).Trim()
    if ($verLine -notmatch "^'(.+)'$") {
        return @{ Quality = "Incomplete"; Note = "Malformed version.inc: $verLine" }
    }
    $incVersion = $Matches[1]

    $lazVerFile = Join-Path $Dir "components\lazutils\lazversion.pas"
    if (Test-Path $lazVerFile) {
        $lazVerSrc = Get-Content $lazVerFile -Raw
        if ($lazVerSrc -match "laz_major\s*=\s*(\d+)") {
            $major = [int]$Matches[1]
            if ($lazVerSrc -match "laz_minor\s*=\s*(\d+)") {
                $minor = [int]$Matches[1]
                $expected = "$major.$minor"
                if ($incVersion -ne $expected) {
                    return @{ Quality = "WrongVersion"; Note = "version.inc=$incVersion, lazversion.pas=$expected" }
                }
            }
        }
    }

    return @{ Quality = "Compatible"; Note = "OK ($incVersion)" }
}

function Test-IdePackageLpkConsistency {
    # GOD UX directive mozyeiiu sub-issue (d) (2026-05-10): Windows IDE startup
    # showed "Unit 'IDeDbgExcludedRoutinesSettingsFrame' was not found in the
    # lpk file" -- the IDE's PackageSystem.RegistrationError raised by
    # ide/packages/idepackager/packagesystem.pas line ~2060 when the autogen
    # <pkg>package.pas registers a unit that the loaded <pkg>.lpk does not
    # list. Mirrors that check statically: every RegisterUnit('Name', ...)
    # call in <pkg>package.pas must appear as a <UnitName Value="Name"/> in
    # <pkg>.lpk. Catches stale .lpk vs newer build deployments before the
    # user hits the runtime error at IDE startup.
    param([string]$Dir)

    $result = @{ Ok = $true; Mismatches = @() }
    $packagesDir = Join-Path $Dir "ide\packages"
    if (-not (Test-Path $packagesDir)) {
        return $result
    }

    foreach ($pkgDirInfo in (Get-ChildItem -Path $packagesDir -Directory -ErrorAction SilentlyContinue)) {
        $pkgDir = $pkgDirInfo.FullName
        $pkgName = $pkgDirInfo.Name
        $lpkFile = Join-Path $pkgDir "$pkgName.lpk"
        $autogenFile = Join-Path $pkgDir "$($pkgName)package.pas"
        if (-not (Test-Path $lpkFile) -or -not (Test-Path $autogenFile)) { continue }

        try {
            $xml = [xml](Get-Content $lpkFile -Raw)
        } catch {
            $result.Ok = $false
            $result.Mismatches += "Package '$pkgName': could not parse $lpkFile : $_"
            continue
        }

        $lpkUnitNames = @{}
        foreach ($node in $xml.SelectNodes("//UnitName")) {
            $val = $node.GetAttribute("Value")
            if ($val) { $lpkUnitNames[$val.ToLower()] = $true }
        }

        $autogenSrc = Get-Content $autogenFile -Raw
        $registered = @{}
        foreach ($m in [regex]::Matches($autogenSrc, "RegisterUnit\(\s*'([^']+)'")) {
            $registered[$m.Groups[1].Value.ToLower()] = $m.Groups[1].Value
        }

        foreach ($name in $registered.Keys) {
            if (-not $lpkUnitNames.ContainsKey($name)) {
                $result.Mismatches += "Package '$pkgName': $($pkgName)package.pas calls RegisterUnit('$($registered[$name])') but $pkgName.lpk has no matching <UnitName>"
                $result.Ok = $false
            }
        }
    }

    return $result
}

function Reset-LazarusConfig {
    Log-Header "Resetting Lazarus user config"

    $envOptsDir = Join-Path $env:LOCALAPPDATA "lazarus"
    if (Test-Path $envOptsDir) {
        $backupDir = "$envOptsDir.backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Log-Info "Moving $envOptsDir -> $backupDir"
        Move-Item -Path $envOptsDir -Destination $backupDir -Force
        Log-Ok "Old config preserved at $backupDir"
    } else {
        Log-Info "No existing config at $envOptsDir -- nothing to reset"
    }
}

function Get-CommonXRoot {
    # Single source of truth for locating the commonx working copy. Used by Rebuild-IDE
    # (to pass PackageCommonX_LCL.lpk to lazbuild --add-package), by the pre-build
    # self-heal decision, and by the post-build verification.
    $candidates = @()
    if ($env:COMMONX_DIR) { $candidates += $env:COMMONX_DIR }
    $candidates += @(
        "C:\source\Pascal\FPC\commonx",
        "C:\source\pascal\FPC\commonx",
        (Join-Path (Split-Path -Parent $LazarusDir) "commonx")
    )
    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path $cand)) { return $cand }
    }
    return $null
}

function Test-CommonXComponentsInstalled {
    # GOD mt8zo2vh (2026-08-25, c634), and mss4zlof / mrxnwdze / mt7spkau before it:
    # "Unable to find the component class TBetterWebBrowser ... needed by unit
    # C:\Source\Pascal\FPC\Trick.Player\FormDecks.pas".
    #
    # WHY THIS CHECK EXISTS. The IDE resolves a component class off the COMPONENT PALETTE
    # (ide\sourcefilemanager.pas SearchComponentClass -> TryRegisteredClasses ->
    # IDEComponentPalette.FindRegComponent), so PackageCommonX_LCL must be INSTALLED INTO
    # THE IDE -- present-on-disk and compiles-clean are both insufficient. Until c634
    # nothing verified that end state, and two mechanisms conspired to hide the failure:
    #   1. Rebuild-IDE only runs when $anyUpdated, so on a steady-state box (binaries
    #      present, pull is a no-op) --add-package never executes at all;
    #   2. when attempt 1 fails, the c626 containment drops commonx and the build still
    #      exits 0 with "[OK] lazarus.exe rebuilt" -- the only signal is a mid-log warning.
    # Net effect: an IDE that lost GOD's components stayed broken indefinitely. Same shape
    # as Test-MetaDarkStyleInstalled below, applied to GOD's own components.
    #
    # Detection is a symbol scan of lazarus.exe: RegisterComponents publishes each class
    # name into the linked binary's RTTI, so the names are present iff the design-time
    # package was linked in. This is the identical technique Test-MetaDarkStyleInstalled
    # already relies on in this file.
    param([string]$Dir = $LazarusDir)

    $result = @{ Ok = $true; Missing = @(); Notes = @(); Checked = $false }

    $lazExe = Join-Path $Dir "lazarus.exe"
    if (-not (Test-Path $lazExe)) {
        $result.Notes += "lazarus.exe not present -- nothing to verify yet"
        return $result
    }

    # Only meaningful when a commonx tree exists to install FROM. With no commonx checkout
    # the components are legitimately absent (Rebuild-IDE logs a skip) and forcing rebuilds
    # would spin forever on a box that simply does not have commonx.
    $commonxRoot = Get-CommonXRoot
    if (-not $commonxRoot) {
        $result.Notes += "commonx tree not found -- component check skipped (set COMMONX_DIR to enable)"
        return $result
    }

    # Class names registered by PackageCommonX_LCL: TBetterWebBrowser lives in
    # lcl\BetterWebBrowser.pas, TTouchButton in lcl\touchcontrols_vcl.pas. Both are GOD's
    # components and both ride the same package, so either one missing means the package
    # was not installed.
    $wanted = @("TBetterWebBrowser", "TTouchButton")

    try {
        $bytes = [System.IO.File]::ReadAllBytes($lazExe)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $result.Checked = $true
        # Ordinal Contains, not -match: lazarus.exe is ~175 MB, so a regex pass per symbol
        # over a string that size is needlessly expensive, and Contains needs no escaping.
        foreach ($sym in $wanted) {
            if (-not $text.Contains($sym)) { $result.Missing += $sym }
        }
        if ($result.Missing.Count -gt 0) {
            $result.Ok = $false
            $result.Notes += "lazarus.exe does NOT contain: $($result.Missing -join ', ') -- PackageCommonX_LCL was not installed into the IDE"
        } else {
            $result.Notes += "lazarus.exe contains commonx component symbols ($($wanted -join ', '))"
        }
    } catch {
        $result.Notes += "Could not scan lazarus.exe: $_"
    }

    return $result
}

function Get-CommonXInstallStamp {
    # Identifies the material a commonx install attempt was made against: the Lazarus commit
    # plus the commonx working-copy revision. The self-heal trigger retries only when this
    # CHANGES, so a box where commonx genuinely cannot compile does not pay for a full IDE
    # rebuild on every single run.
    $lazHead = ""
    try { $lazHead = (Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-parse", "HEAD")) -join "" } catch { }
    $commonxRev = ""
    $commonxRoot = Get-CommonXRoot
    if ($commonxRoot -and (Get-Command svn -ErrorAction SilentlyContinue)) {
        try {
            $info = (& svn info $commonxRoot 2>&1 | Out-String)
            if ($info -match "(?m)^Revision:\s*(\d+)") { $commonxRev = $Matches[1] }
        } catch { }
    }
    return "$($lazHead.Trim())|$commonxRev"
}

function Get-CommonXStampPath {
    return (Join-Path (Join-Path $env:LOCALAPPDATA "lazarus") "commonx-install-attempt.txt")
}

# c699 (GOD mu66fghs, 2026-09-17): the pre-build self-heal was commonx-ONLY, so a steady-state
# box whose IDE is missing a DIFFERENT flagship feature never rebuilt and reported success on
# every run. Same stamp discipline, one file per feature. The material that decides whether a
# CORE package links is the Lazarus source alone, so this stamp is HEAD -- no commonx revision.
# An unreadable git yields "nogit" rather than "", so the first run still heals once instead of
# comparing "" to "" and suppressing itself forever (unreadable git is UNKNOWN, not "current").
function Get-FeatureStampPath {
    param([Parameter(Mandatory=$true)][string]$Feature)
    return (Join-Path (Join-Path $env:LOCALAPPDATA "lazarus") ($Feature + "-install-attempt.txt"))
}

function Get-LazarusSourceStamp {
    $lazHead = ""
    try { $lazHead = ((Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-parse", "HEAD")) -join "").Trim() } catch { }
    if (-not $lazHead) { $lazHead = "nogit" }
    return $lazHead
}

function Record-FeatureAttempt {
    # Call AFTER a build that LEFT the feature missing, so the next run can tell whether a
    # retry is worthwhile. Mirrors the commonx stamp written further up in Rebuild-IDE.
    param([Parameter(Mandatory=$true)][string]$Feature)
    try {
        $sp = Get-FeatureStampPath -Feature $Feature
        $sd = Split-Path -Parent $sp
        if (-not (Test-Path $sd)) { New-Item -ItemType Directory -Path $sd -Force | Out-Null }
        Set-Content -Path $sp -Value (Get-LazarusSourceStamp) -Encoding ASCII
    } catch { }
}

function Clear-FeatureAttempt {
    param([Parameter(Mandatory=$true)][string]$Feature)
    try { Remove-Item (Get-FeatureStampPath -Feature $Feature) -Force -ErrorAction SilentlyContinue } catch { }
}

function Test-FeatureAttemptIsNew {
    # $true = the source has CHANGED since the last attempt that failed to install it.
    param([Parameter(Mandatory=$true)][string]$Feature)
    $sp = Get-FeatureStampPath -Feature $Feature
    $last = ""
    if (Test-Path $sp) {
        # [string] cast + try/catch: $ErrorActionPreference is "Stop" script-wide and an empty
        # stamp file makes Get-Content -Raw return $null, so a bare .Trim() would abort the run.
        try { $last = ([string](Get-Content $sp -Raw -ErrorAction SilentlyContinue)).Trim() } catch { $last = "" }
    }
    return ((Get-LazarusSourceStamp) -ne $last)
}

function Test-DockedLayoutInstalled {
    # GOD mu3jfytu (2026-09-16): the docked single-window IDE ("modern Delphi style") is
    # the DEFAULT, carried by two packages that are now CORE (LazarusIDEBasePkgNames in
    # ide\packages\idepackager\pkgsysbasepkgs.pas): AnchorDockingDsgn and DockedFormEditor.
    # Wiring is not the end state (c634): verify the design-time ppus were compiled AND
    # the classes are linked into lazarus.exe -- the same symbol scan that
    # Test-MetaDarkStyleInstalled and Test-CommonXComponentsInstalled rely on.
    param([string]$Dir = $LazarusDir, [string]$Cpu = "x86_64", [string]$Os = "win64", [string]$Ws = "win32")

    $result = @{ Ok = $true; Notes = @() }

    $ppus = @(
        (Join-Path $Dir "components\anchordocking\design\units\$Cpu-$Os\$Ws\anchordockingdsgn.ppu"),
        (Join-Path $Dir "components\dockedformeditor\lib\$Cpu-$Os\$Ws\dockedformeditor.ppu")
    )
    # c690: the BINARY is the end state; a missing intermediate artifact must never veto it.
    # The previous order gated on the two .ppu files and returned BEFORE scanning lazarus.exe,
    # which made this report a false "NOT installed" on a perfectly good build. Measured, not
    # theorised: Clean-StalePackageArtifacts (section 2, "Lazarus built-in packages") deletes
    # every *.ppu under EVERY directory named "lib", and dockedformeditor's output lives at
    # components\dockedformeditor\LIB\<cpu>-<os>\<ws>\ while anchordocking's lives under
    # ...\design\UNITS\..., so that sweep removes exactly one of the two paths below. Two
    # arms over the SAME byte-identical IDE binary (md5 806c055d7741, which provably contains
    # both classes) differed only in that one .ppu and the shipped code answered Ok=True then
    # Ok=False -- telling GOD his docked IDE was broken and to go read a build error that does
    # not exist. Missing .ppus are now a DIAGNOSTIC on failure, never a verdict.
    $missingPpus = @($ppus | Where-Object { -not (Test-Path $_) })

    $lazExe = Join-Path $Dir "lazarus.exe"
    if (-not (Test-Path $lazExe)) {
        # Also c690: the old code left Ok=$true when lazarus.exe was absent, so a tree with
        # ppus and no IDE reported "installed". A verdict with nothing to verify is not a pass.
        $result.Ok = $false
        $result.Notes += "lazarus.exe not found in $Dir -- the IDE has not been built in this tree, so the docked layout cannot be verified."
        foreach ($p in $missingPpus) { $result.Notes += "  (design-time artifact also absent: $p)" }
        return $result
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($lazExe)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $missing = @()
        foreach ($sym in @("TIDEAnchorDockMaster", "TDockedMainIDE")) {
            if (-not $text.Contains($sym)) { $missing += $sym }
        }
        if ($missing.Count -gt 0) {
            $result.Ok = $false
            $result.Notes += "lazarus.exe does NOT contain: $($missing -join ', ') -- the docking packages were not linked. Run -ForceRebuild."
            foreach ($p in $missingPpus) {
                $result.Notes += "  ...and its design-time artifact is missing too: $p (Rebuild-IDE did not compile it -- it is a base package, so read the FIRST 'Error:' line of the build)"
            }
        } else {
            $result.Notes += "lazarus.exe contains the docked-layout classes (TIDEAnchorDockMaster, TDockedMainIDE)"
            foreach ($p in $missingPpus) {
                $result.Notes += "  (build artifact $p is absent, but the classes ARE linked into lazarus.exe -- the stale-artifact cleanup sweeps 'lib' dirs, so this is expected and is NOT a fault)"
            }
        }
    } catch {
        $result.Ok = $false
        $result.Notes += "Could not scan lazarus.exe: $_ -- treating as NOT verified rather than as a pass."
    }

    return $result
}

function Test-MetaDarkStyleInstalled {
    # GOD directive moehki0x (2026-04-25): MetaDarkStyle is a flagship feature.
    # Post-cycle 322 #182: runtime units live in lcl/darkstyle/ (linked via
    # lclbase.lpk), only the design-time package remains at
    # components\metadarkstyle\dsgn\. Verify design-time LPK + PPU + that
    # MetaDarkStyle symbols are linked into lazarus.exe.
    param([string]$Dir = $LazarusDir, [string]$Cpu = "x86_64", [string]$Os = "win64")

    $result = @{ Ok = $true; Notes = @() }

    $dsLpk = Join-Path $Dir "components\metadarkstyle\dsgn\metadarkstyledsgn.lpk"
    if (-not (Test-Path $dsLpk)) {
        $result.Ok = $false
        $result.Notes += "Source missing: $dsLpk (re-pull from upstream fork)"
        return $result
    }

    # c690: SAME defect as Test-DockedLayoutInstalled, second instance of the class, so it is
    # systemic rather than a one-off. metadarkstyledsgn.ppu sits under ...\dsgn\LIB\, which
    # Clean-StalePackageArtifacts sweeps, and gating on it returned before lazarus.exe was ever
    # scanned. The .lpk check above stays a hard gate (missing SOURCE really does block), but a
    # missing compiled artifact is now a diagnostic, never the verdict.
    $dsPpu = Join-Path $Dir "components\metadarkstyle\dsgn\lib\$Cpu-$Os\metadarkstyledsgn.ppu"
    $dsPpuMissing = -not (Test-Path $dsPpu)

    $lazExe = Join-Path $Dir "lazarus.exe"
    if (-not (Test-Path $lazExe)) {
        $result.Ok = $false
        $result.Notes += "lazarus.exe not found in $Dir -- the IDE has not been built in this tree, so MetaDarkStyle cannot be verified."
        if ($dsPpuMissing) { $result.Notes += "  (design-time artifact also absent: $dsPpu)" }
        return $result
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($lazExe)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        if ($text -notmatch "(?i)metadarkstyle") {
            $result.Ok = $false
            $result.Notes += "lazarus.exe does NOT contain MetaDarkStyle symbols -- design-time package was not linked. Run -ForceRebuild."
            if ($dsPpuMissing) {
                $result.Notes += "  ...and its design-time artifact is missing too: $dsPpu (Rebuild-IDE did not compile it -- check uses clause in ide\lazarus.pp)"
            }
        } else {
            $result.Notes += "lazarus.exe contains MetaDarkStyle symbols"
            if ($dsPpuMissing) {
                $result.Notes += "  (build artifact $dsPpu is absent, but the symbols ARE linked into lazarus.exe -- the stale-artifact cleanup sweeps 'lib' dirs, so this is expected and is NOT a fault)"
            }
        }
    } catch {
        $result.Ok = $false
        $result.Notes += "Could not scan lazarus.exe: $_ -- treating as NOT verified rather than as a pass."
    }

    return $result
}

function Invoke-Doctor {
    Log-Header "Lazarus + VibePascal Doctor"

    $problems = 0

    Log-Info "Lazarus directory: $LazarusDir"
    $quality = Test-LazarusDirectoryQuality -Dir $LazarusDir
    if ($quality.Quality -eq "Compatible") {
        Log-Ok "Lazarus dir quality: $($quality.Quality) [$($quality.Note)]"
    } else {
        Log-Err "Lazarus dir quality: $($quality.Quality) [$($quality.Note)]"
        $problems++
    }

    Log-Info "VibePascal directory: $VPDir"
    if (Test-Path $VPCompiler) {
        Log-Ok "VibePascal compiler: $VPCompiler"
    } else {
        Log-Err "VibePascal compiler not found at $VPCompiler"
        $problems++
    }

    $vpCfg = Join-Path $VPDir "bin\fpc.cfg"
    if (Test-Path $vpCfg) {
        $cfgLines = (Get-Content $vpCfg | Where-Object { $_ -match "^-Fu" }).Count
        Log-Ok "VibePascal fpc.cfg: $vpCfg ($cfgLines unit paths)"
    } else {
        Log-Warn "VibePascal fpc.cfg not found at $vpCfg (run -Setup or -ForceRebuild)"
        $problems++
    }

    $envOptsFile = Join-Path $env:LOCALAPPDATA "lazarus\environmentoptions.xml"
    if (Test-Path $envOptsFile) {
        Log-Ok "User config: $envOptsFile"
        try {
            $xml = [xml](Get-Content $envOptsFile -Raw)
            $envOpts = $xml.CONFIG.EnvironmentOptions
            $lazDirNode = $envOpts.SelectSingleNode("LazarusDirectory")
            $cfgLazDir = if ($lazDirNode) { $lazDirNode.GetAttribute("Value") } else { $null }
            $compilerNode = $envOpts.SelectSingleNode("CompilerFilename")
            $cfgCompiler = if ($compilerNode) { $compilerNode.GetAttribute("Value") } else { $null }
            $fpcSrcNode = $envOpts.SelectSingleNode("FPCSourceDirectory")
            $cfgFpcSrc = if ($fpcSrcNode) { $fpcSrcNode.GetAttribute("Value") } else { $null }

            if ($cfgLazDir) {
                $cfgLazDirNorm = $cfgLazDir.TrimEnd('\','/')
                $expectedNorm = $LazarusDir.TrimEnd('\','/')
                if ($cfgLazDirNorm -eq $expectedNorm) {
                    Log-Ok "  LazarusDirectory: $cfgLazDir"
                } else {
                    Log-Err "  LazarusDirectory: $cfgLazDir (expected $LazarusDir)"
                    $problems++
                }
            } else {
                Log-Err "  LazarusDirectory: <missing>"
                $problems++
            }

            if ($cfgCompiler -and (Test-Path $cfgCompiler)) {
                Log-Ok "  CompilerFilename: $cfgCompiler"
            } else {
                Log-Err "  CompilerFilename: $cfgCompiler (not found)"
                $problems++
            }

            if ($cfgFpcSrc -and (Test-Path $cfgFpcSrc)) {
                Log-Ok "  FPCSourceDirectory: $cfgFpcSrc"
            } else {
                Log-Err "  FPCSourceDirectory: $cfgFpcSrc (not found)"
                $problems++
            }
        } catch {
            Log-Err "Could not parse $envOptsFile : $_"
            $problems++
        }
    } else {
        Log-Warn "User config not found at $envOptsFile (run -Setup)"
        $problems++
    }

    $lazExe = Join-Path $LazarusDir "lazarus.exe"
    if (Test-Path $lazExe) {
        $exeMtime = (Get-Item $lazExe).LastWriteTime
        Log-Ok "lazarus.exe: $lazExe ($($exeMtime.ToString('yyyy-MM-dd HH:mm')))"
    } else {
        Log-Warn "lazarus.exe not built yet (run -ForceRebuild)"
    }

    $lazbuildExe = Join-Path $LazarusDir "lazbuild.exe"
    if (Test-Path $lazbuildExe) {
        Log-Ok "lazbuild.exe: $lazbuildExe"
    } else {
        Log-Warn "lazbuild.exe not built yet"
    }

    $mds = Test-MetaDarkStyleInstalled -Dir $LazarusDir
    if ($mds.Ok) {
        Log-Ok "MetaDarkStyle (dark mode IDE skin): installed"
        foreach ($n in $mds.Notes) { Log-Info "  $n" }
    } elseif (-not (Test-Path $lazExe)) {
        # The IDE has never been built in this tree, which the lazarus.exe check above
        # already reported. A missing metadarkstyledsgn.ppu is the GUARANTEED consequence
        # of that, not an independent fault -- reporting it as an ERROR whose note says
        # "check uses clause in ide\lazarus.pp" sends the reader hunting a source bug that
        # cannot exist yet. Steve's 2026-09-11 -Doctor run on a fresh C:\lazarus checkout is
        # exactly this: [WARN] lazarus.exe not built yet, then [ERROR] MetaDarkStyle NOT
        # installed. Downgrade it and name the real cause; do not count it as a problem (c668).
        Log-Warn "MetaDarkStyle (dark mode IDE skin): cannot be present yet -- the IDE has never been built in this tree."
        Log-Warn "  Expected at this stage. Run -ForceRebuild, then re-run -Doctor to get a real answer."
    } else {
        Log-Err "MetaDarkStyle (dark mode IDE skin): NOT installed"
        foreach ($n in $mds.Notes) { Log-ErrDetail "  $n" }
        $problems++
    }

    # GOD mu3jfytu (2026-09-16): docked single-window layout is the default. Same
    # not-built-yet downgrade as MetaDarkStyle above (c668).
    $dock = Test-DockedLayoutInstalled -Dir $LazarusDir
    if ($dock.Ok) {
        Log-Ok "Docked IDE layout (AnchorDocking + docked form editor): installed"
        foreach ($n in $dock.Notes) { Log-Info "  $n" }
    } elseif (-not (Test-Path $lazExe)) {
        Log-Warn "Docked IDE layout: cannot be present yet -- the IDE has never been built in this tree (see lazarus.exe above)."
    } else {
        Log-Err "Docked IDE layout (AnchorDocking + docked form editor): NOT installed"
        foreach ($n in $dock.Notes) { Log-ErrDetail "  $n" }
        $problems++
    }

    $lpkCheck = Test-IdePackageLpkConsistency -Dir $LazarusDir
    if ($lpkCheck.Ok) {
        Log-Ok "IDE package .lpk vs source consistency: OK"
    } else {
        Log-Err "IDE package .lpk vs source mismatches detected ($($lpkCheck.Mismatches.Count)):"
        foreach ($m in $lpkCheck.Mismatches) { Log-ErrDetail "  $m" }
        Log-ErrDetail "  Cause: source pulled but .lpk stale, or .lpk pulled but source not yet rebuilt."
        Log-ErrDetail "  Fix: re-pull origin/main, then run -ForceRebuild."
        $problems++
    }

    Write-Host ""
    if ($problems -eq 0) {
        Log-Ok "No problems found. Toolchain looks healthy."
    } else {
        Log-Err "$problems problem(s) found."
        Log-Info "Suggested fixes:"
        Log-Info "  1. Run: auto-update.bat -ResetConfig -ForceRebuild   (the .bat closes the running IDE first)"
        Log-Info "  2. If problems persist, check that VibePascal tarball is present in dist\\win64\\"
        Log-Info "  3. Verify Lazarus repo is clean: git status -- inside $LazarusDir"
    }
    return $problems
}

function Configure-Environment {
    Log-Header "Configuring Lazarus IDE for VibePascal"

    $envOptsDir = Join-Path $env:LOCALAPPDATA "lazarus"
    $envOptsFile = Join-Path $envOptsDir "environmentoptions.xml"

    if (-not (Test-Path $envOptsDir)) {
        New-Item -ItemType Directory -Path $envOptsDir -Force | Out-Null
        Log-Info "Created Lazarus config directory: $envOptsDir"
    }

    $vpUnitsDir = Join-Path $VPDir "units"
    $vpBinDir = Join-Path $VPDir "bin"
    $vpCompilerPath = Join-Path $vpBinDir "ppcx64.exe"

    if (-not (Test-Path $vpCompilerPath)) {
        $vpCompilerPath = $VPCompiler
    }

    if (Test-Path $envOptsFile) {
        Log-Info "Patching existing environmentoptions.xml"
        $xml = [xml](Get-Content $envOptsFile -Raw)
        $envOpts = $xml.CONFIG.EnvironmentOptions
        # c686 (Otto, 2026-09-17): this rewrites a config the script does not own. On the
        # bash side an updater run from a scratch checkout silently repointed the real
        # shared IDE config at a throwaway rig with no backup and no way back; see
        # configure_environment() in auto-update.sh. Same cure here: write only when
        # something actually moved, and take a rolling backup first.
        $envOptsChanged = $false

        # Always update LazarusDirectory: stale path here is the #1 cause of
        # "Without a proper Lazarus directory you will get a lot of warnings"
        # at IDE startup. It must point at the source tree the user is actually using.
        $lazDirNode = $envOpts.SelectSingleNode("LazarusDirectory")
        if (-not $lazDirNode) {
            $lazDirNode = $xml.CreateElement("LazarusDirectory")
            $envOpts.AppendChild($lazDirNode) | Out-Null
        }
        $oldVal = $lazDirNode.GetAttribute("Value")
        if ($oldVal -ne $LazarusDir) {
            $lazDirNode.SetAttribute("Value", $LazarusDir)
            Log-Info "LazarusDirectory: $oldVal -> $LazarusDir"
            $envOptsChanged = $true
        }

        $compilerNode = $envOpts.SelectSingleNode("CompilerFilename")
        if (-not $compilerNode) {
            $compilerNode = $xml.CreateElement("CompilerFilename")
            $envOpts.AppendChild($compilerNode) | Out-Null
        }
        $oldVal = $compilerNode.GetAttribute("Value")
        if ($oldVal -ne $vpCompilerPath) {
            $compilerNode.SetAttribute("Value", $vpCompilerPath)
            Log-Info "CompilerFilename: $oldVal -> $vpCompilerPath"
            $envOptsChanged = $true
        }

        $fpcSrcNode = $envOpts.SelectSingleNode("FPCSourceDirectory")
        if (-not $fpcSrcNode) {
            $fpcSrcNode = $xml.CreateElement("FPCSourceDirectory")
            $envOpts.AppendChild($fpcSrcNode) | Out-Null
        }
        $oldVal = $fpcSrcNode.GetAttribute("Value")
        if ($oldVal -ne $VPDir) {
            $fpcSrcNode.SetAttribute("Value", $VPDir)
            Log-Info "FPCSourceDirectory: $oldVal -> $VPDir"
            $envOptsChanged = $true
        }

        $makeNode = $envOpts.SelectSingleNode("MakeFilename")
        $makePath = Find-Make
        # c718 -- a make we refused must not be left sitting in the IDE's own config. We warn
        # rather than delete: environmentoptions.xml is the user's file and -Doctor reports it
        # as the healthy part of a broken box, so silently rewriting it is the wrong trade.
        if (-not $makePath -and $makeNode -and $script:MakeRejected.Count -gt 0) {
            $persisted = $makeNode.GetAttribute("Value")
            foreach ($r in $script:MakeRejected) {
                if ($persisted -and $r.StartsWith($persisted)) {
                    Log-Warn "environmentoptions.xml MakeFilename points at a make that is NOT GNU make: $r"
                    Log-Warn "  The IDE will fail to build from source while this is set. Clear it or point it at a GNU make."
                }
            }
        }
        if ($makePath) {
            if (-not $makeNode) {
                $makeNode = $xml.CreateElement("MakeFilename")
                $envOpts.AppendChild($makeNode) | Out-Null
            }
            $oldVal = $makeNode.GetAttribute("Value")
            if ($oldVal -ne $makePath) {
                $makeNode.SetAttribute("Value", $makePath)
                Log-Info "MakeFilename: $oldVal -> $makePath"
                $envOptsChanged = $true
            }
        }

        if (-not $envOptsChanged) {
            Log-Ok "$envOptsFile already matches this VibePascal -- left unchanged"
        } else {
            $envOptsBackup = "$envOptsFile.autoupdate.bak"
            try {
                Copy-Item -LiteralPath $envOptsFile -Destination $envOptsBackup -Force -ErrorAction Stop
                Log-Info "Backed up existing config to $envOptsBackup"
                Log-Info "  undo: Copy-Item -LiteralPath '$envOptsBackup' -Destination '$envOptsFile' -Force"
            } catch {
                Log-Warn "Could not back up $envOptsFile -- patching anyway"
            }
            $xml.Save($envOptsFile)
            Log-Ok "Updated $envOptsFile"
        }
    } else {
        Log-Info "Creating new environmentoptions.xml from template"
        $templateFile = Join-Path $LazarusDir "tools\install\win\environmentoptions.xml"

        if (Test-Path $templateFile) {
            $xml = [xml](Get-Content $templateFile -Raw)
            $envOpts = $xml.CONFIG.EnvironmentOptions

            $lazDirNode = $envOpts.SelectSingleNode("LazarusDirectory")
            if ($lazDirNode) { $lazDirNode.SetAttribute("Value", $LazarusDir) }

            $compilerNode = $envOpts.SelectSingleNode("CompilerFilename")
            if ($compilerNode) { $compilerNode.SetAttribute("Value", $vpCompilerPath) }

            $fpcSrcNode = $envOpts.SelectSingleNode("FPCSourceDirectory")
            if ($fpcSrcNode) { $fpcSrcNode.SetAttribute("Value", $VPDir) }

            $makeNode = $envOpts.SelectSingleNode("MakeFilename")
            if ($makeNode) {
                $makePath = Find-Make
                if ($makePath) { $makeNode.SetAttribute("Value", $makePath) }
            }

            $xml.Save($envOptsFile)
            Log-Ok "Created $envOptsFile"
        } else {
            Log-Err "Template not found at $templateFile"
            return
        }
    }

    if (-not (Test-Path $vpBinDir)) {
        New-Item -ItemType Directory -Path $vpBinDir -Force | Out-Null
        Log-Info "Created VibePascal bin directory: $vpBinDir"
    }

    $vpCfgFile = Join-Path $vpBinDir "fpc.cfg"

    # Always regenerate bin\fpc.cfg with explicit literal paths. The tarball-shipped cfg uses
    # "-Fu$FPCBINDIR../units/$FPCTARGET" which only resolves correctly when ppcx64.exe is run from
    # $VPDir\bin; running from $VPDir\compiler produces an invalid path (compiler../). Explicit
    # paths are robust regardless of where the compiler is launched from.
    $unitPaths = Get-VPUnitPaths
    if ($unitPaths.Count -eq 0) {
        Log-Err "No VibePascal PPU directories found under $VPDir -- cannot configure fpc.cfg"
        return
    }

    $cfgLines = @(
        "# VibePascal compiler config (regenerated by auto-update.ps1)",
        "# Do not hand-edit; this file is overwritten on every update.",
        "",
        "# Unit search paths"
    )
    foreach ($p in $unitPaths) { $cfgLines += "-Fu$p" }
    $cfgLines += @(
        "",
        "# Parsing: allow goto, inline, C-operators",
        "-Sgic",
        "",
        "# Verbosity: info, warnings, notes",
        "-viwn",
        "",
        "# Logo",
        "-l"
    )
    [IO.File]::WriteAllText($vpCfgFile, ($cfgLines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
    Log-Ok "Wrote $vpCfgFile ($($unitPaths.Count) unit path$(if ($unitPaths.Count -ne 1) { 's' }))"

    Log-Ok "IDE configured to use VibePascal. Restart Lazarus to apply."
}

function Fix-LpiFiles {
    param([string]$SearchDir)

    if (-not $SearchDir) { $SearchDir = $LazarusDir }

    Log-Header "Scanning .lpi files for UnitOutputDirectory fixes"

    $lpiFiles = Get-ChildItem -Path $SearchDir -Filter "*.lpi" -Recurse -ErrorAction SilentlyContinue
    $fixCount = 0

    foreach ($lpi in $lpiFiles) {
        try {
            $xml = [xml](Get-Content $lpi.FullName -Raw)

            $compOpts = $xml.SelectSingleNode("//CompilerOptions")
            if (-not $compOpts) { continue }

            $searchPaths = $compOpts.SelectSingleNode("SearchPaths")
            if (-not $searchPaths) {
                $searchPaths = $xml.CreateElement("SearchPaths")
                $compOpts.PrependChild($searchPaths) | Out-Null
            }

            $unitOutDir = $searchPaths.SelectSingleNode("UnitOutputDirectory")
            if (-not $unitOutDir) {
                $unitOutDir = $xml.CreateElement("UnitOutputDirectory")
                $searchPaths.AppendChild($unitOutDir) | Out-Null
            }

            $currentVal = $unitOutDir.GetAttribute("Value")
            if ($currentVal -ne "lib") {
                $oldVal = if ($currentVal) { $currentVal } else { "(empty)" }
                $unitOutDir.SetAttribute("Value", "lib")
                $xml.Save($lpi.FullName)
                Log-Info "$($lpi.Name): UnitOutputDirectory $oldVal -> lib"
                $fixCount++
            }
        } catch {
            Log-Warn "Could not process $($lpi.Name): $_"
        }
    }

    if ($fixCount -eq 0) {
        Log-Ok "All .lpi files already have UnitOutputDirectory = lib"
    } else {
        Log-Ok "Fixed $fixCount .lpi file(s)"
    }
}

# --- Main ---

Log-Header "Lazarus + VibePascal Auto-Updater (Windows)"
Write-Host "  Lazarus:    $LazarusDir"
Write-Host "  VibePascal: $VPDir"
Write-Host "  Compiler:   $VPCompiler"
Write-Host ""

if ($Doctor) {
    $problems = Invoke-Doctor
    exit $(if ($problems -gt 0) { 1 } else { 0 })
}

if ($ResetConfig) {
    Reset-LazarusConfig
    Extract-VPBinaries
    Configure-Environment
    $quality = Test-LazarusDirectoryQuality -Dir $LazarusDir
    if ($quality.Quality -ne "Compatible") {
        Log-Warn "Lazarus directory still flagged $($quality.Quality): $($quality.Note)"
        if (-not $ForceRebuild) {
            Log-Warn "IDE may show 'Without a proper Lazarus directory' on startup. Run -ForceRebuild to rebuild lazarus.exe."
        }
    }
    if ($ForceRebuild) {
        # -ResetConfig -ForceRebuild: rebuild current source after config reset.
        # Calls Rebuild-Lazbuild + Rebuild-IDE directly instead of falling through
        # to the main pipeline, which would re-extract VP, wipe local changes, and
        # pull upstream -- not what the user asked for with -ResetConfig.
        Log-Info "-ResetConfig -ForceRebuild: rebuilding lazbuild + IDE after config reset"
        Rebuild-Lazbuild
        Configure-Environment
        Sanitize-PackageRegistrations
        Clean-StalePackageArtifacts
        Rebuild-IDE
        if ((Test-Path (Join-Path $LazarusDir "lazbuild.exe")) -and (Test-Path (Join-Path $LazarusDir "lazarus.exe"))) {
            Log-Ok "Lazarus rebuilt after ResetConfig"
        }
    }
    exit 0
}

if ($Setup) {
    Extract-VPBinaries
    Configure-Environment
    $quality = Test-LazarusDirectoryQuality -Dir $LazarusDir
    if ($quality.Quality -ne "Compatible") {
        Log-Warn "Lazarus directory flagged $($quality.Quality): $($quality.Note)"
    }
    exit 0
}

if ($FixLpi) {
    Fix-LpiFiles
    exit 0
}


$upstreamRemote = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("remote", "get-url", "upstream")
$script:UpstreamConfigured = [bool]$upstreamRemote   # c722 -- so the summary can say NOT CHECKED instead of "no changes"
if ($upstreamRemote) {
    Invoke-Git -WorkDir $LazarusDir -GitArgs @("fetch", "upstream") | Out-Null
} else {
    Log-Warn "No 'upstream' remote configured -- skipping upstream Lazarus (fpc/Lazarus) checks"
    Log-Info "To add it: git remote add upstream https://github.com/fpc/Lazarus.git"
}

# c719 -- take HEAD BEFORE anything can move it, so Print-Summary can tell "updated" from
# "an update is available". Nothing above this point pulls: the fetches move remote-tracking
# refs only, and Wipe-LocalChanges (reset --hard HEAD) does not move HEAD either.
$script:LazarusHeadBefore = Get-HeadStamp -WorkDir $LazarusDir
$script:VPHeadBefore = Get-HeadStamp -WorkDir $VPDir
$script:VPVersionBefore = Get-VPDistVersion   # c720 -- same instant as the HEADs above, before anything pulls

if (-not $UpstreamOnly) {
    Check-VPUpdates
}
if ($upstreamRemote) {
    Check-LazarusUpstream
}
Check-LazarusOrigin

if ($Check) {
    Print-Summary
    # c675: a -Check that could not read or refresh a repository must not exit 0 (Steve's
    # 2026-09-16 observation: a non-repository directory scored as "Everything is up to date").
    if ($script:CheckFailed) { exit 3 }
    exit 0
}

# c642 -- ORDER IS THE FIX, not a tidy-up. This block used to sit ABOVE the -Check early exit,
# so `auto-update.bat -Check` -- advertised and used as a read-only dry run -- ran
# `git reset --hard HEAD` + `git clean -fdx` over BOTH repos and extracted the VP binaries
# before printing its summary and exiting. A developer asking "is there anything new?" lost
# every uncommitted and untracked file in $LazarusDir and $VPDir to a command that then said
# "Nothing to do." Nothing between the old and new positions needs a clean tree: the fetch and
# all three Check-* helpers are git-query-only (Check-VPUpdates is rev-list HEAD..origin/main),
# and Print-Summary reads only $script: flags that are set further down, past this point.
# $scriptPreHash moves WITH the block so the wipe -> extract -> hash order a non-Check run sees
# is byte-for-byte what it was; for those runs this commit is a pure relocation.
if (-not $KeepLocal) {
    Wipe-LocalChanges -RepoDir $LazarusDir -Label "Lazarus"
    if (-not $UpstreamOnly -and (Test-Path (Join-Path $VPDir ".git"))) {
        Wipe-LocalChanges -RepoDir $VPDir -Label "VibePascal"
    }
} else {
    Log-Info "Keeping local changes (-KeepLocal)"
}

# Extract VibePascal AFTER wipe: extracted binaries (bin\ppcx64.exe, units\x86_64-win64\*.ppu,
# bin\fpc.cfg, .auto-update-extracted.txt marker) live at untracked paths inside $VPDir, so
# `git clean -fdx` during the VibePascal wipe deletes them. Extract first leaves the rebuild
# step with no compiler (GOD mp8h9y4b/mp8har98).
Extract-VPBinaries

$scriptPreHash = (Get-FileHash -Path (Join-Path $LazarusDir "auto-update.ps1") -Algorithm SHA256).Hash

if (-not $UpstreamOnly) {
    Pull-VP
    # Re-extract VibePascal binaries after pulling source changes so the compiler always
    # reflects the latest pulled version (GOD mrfegvha: auto-update.bat reported VP updated
    # but ppcx64.exe stayed stale because Extract-VPBinaries ran only before the pull).
    # The marker-based dedup in Extract-VPBinaries makes this a safe no-op when dist/ has
    # no new tarballs.
    if ($script:VPUpdated) {
        Log-Info "Re-extracting VibePascal binaries after VP source update"
        Extract-VPBinaries
    }
}
Pull-LazarusUpstream
$script:LazarusHeadAfterUpstream = Get-HeadStamp -WorkDir $LazarusDir   # c719: splits the upstream merge from the origin pull, which move the same HEAD
Pull-LazarusOrigin

Relaunch-IfUpdated -PreHash $scriptPreHash

$anyUpdated = $script:VPUpdated -or $script:LazarusUpdated -or $script:UpstreamUpdated

$missingBuildProducts = @()
foreach ($buildProduct in @("lazbuild.exe", "lazarus.exe")) {
    $buildProductPath = Join-Path $LazarusDir $buildProduct
    if (-not (Test-Path $buildProductPath)) {
        $missingBuildProducts += $buildProduct
    }
}
if ($missingBuildProducts.Count -gt 0) {
    $script:BuildProductsWereMissing = $true
    Log-Warn "Missing local build product(s): $($missingBuildProducts -join ', ')"
    if (-not $NoBuild) {
        Log-Info "Forcing rebuild because required local binaries are missing"
        $anyUpdated = $true
    }
}

if ($ForceRebuild) {
    Log-Info "Force rebuild requested"
    $anyUpdated = $true
}

# c634 (GOD mt8zo2vh) -- SELF-HEAL a degraded IDE.
# Rebuild-IDE only runs when $anyUpdated. On a steady-state box (lazarus.exe present, pull
# a no-op) that meant an IDE which had lost PackageCommonX_LCL -- because attempt 1 failed
# once and the c626 containment dropped it -- could never get it back without someone
# knowing to pass -ForceRebuild. That is why GOD saw the same "Unable to find the component
# class TBetterWebBrowser" dialog for weeks: the updater reported success every run and
# never rebuilt. If the components are missing, rebuild.
#
# Guarded by a stamp so this cannot spin: retry only when the Lazarus commit or the commonx
# revision has CHANGED since the last attempt that failed to install them. On a box where
# commonx genuinely cannot compile, the user gets one loud diagnosis, not a full IDE rebuild
# on every run. -ForceRebuild always overrides the guard.
if (-not $anyUpdated -and -not $NoBuild) {
    $cxCheck = Test-CommonXComponentsInstalled -Dir $LazarusDir
    if ($cxCheck.Checked -and -not $cxCheck.Ok) {
        $stampPath = Get-CommonXStampPath
        $currentStamp = Get-CommonXInstallStamp
        # [string] cast + try/catch: $ErrorActionPreference is "Stop" script-wide, and an
        # empty stamp file makes Get-Content -Raw return $null, so a bare .Trim() would
        # abort the whole updater.
        $lastStamp = ""
        if (Test-Path $stampPath) {
            try { $lastStamp = ([string](Get-Content $stampPath -Raw -ErrorAction SilentlyContinue)).Trim() } catch { $lastStamp = "" }
        }

        Log-Warn "IDE is missing GOD's commonx components: $($cxCheck.Missing -join ', ')"
        if ($lastStamp -ne $currentStamp) {
            Log-Info "Forcing IDE rebuild to reinstall PackageCommonX_LCL (source changed since the last attempt)"
            $anyUpdated = $true
        } else {
            Log-Err "PackageCommonX_LCL still not installed, and nothing has changed since the last attempt -- not rebuilding again."
            Log-ErrDetail "  Forms using TBetterWebBrowser / TTouchButton will not load in the designer."
            Log-ErrDetail "  Fix: run  auto-update.bat -ForceRebuild  and read the FIRST 'Error:' line of the build output."
            Log-ErrDetail "  That first error is the commonx unit that fails to compile under the IDE build mode."
        }
    }
}

# c699 (GOD mu66fghs, 2026-09-17) -- SELF-HEAL THE OTHER TWO FLAGSHIP FEATURES.
# The block above has asked exactly one question since c634: "are GOD's commonx components in
# the binary?" An IDE built BEFORE the docking packages became core (9b044e4527, 2026-09-16)
# answers YES, so $anyUpdated stays $false, Rebuild-IDE never runs, and the box keeps a
# floating-window IDE forever while every run ends in success. GOD reported exactly that from
# Windows: "your changes recently seemed to affect the linux builds... but my windows system is
# still the fucking ancient looking delphi 7 style floating shit."
#
# Test-DockedLayoutInstalled and Test-MetaDarkStyleInstalled already existed -- they just ran
# only AFTER a rebuild, i.e. never on the boxes that needed them. Both are pure reads of
# lazarus.exe, so they are safe to run before the build too. Same stamp guard as commonx (one
# stamp per feature) so a box that genuinely cannot build these gets ONE loud diagnosis rather
# than a full IDE rebuild on every run. -ForceRebuild always overrides the guard.
if (-not $anyUpdated -and -not $NoBuild -and (Test-Path (Join-Path $LazarusDir "lazarus.exe"))) {
    $healChecks = @(
        @{ Feature = "docked"
           Verifier = { Test-DockedLayoutInstalled -Dir $LazarusDir }
           Label    = "the docked single-window layout (GOD mu3jfytu)"
           Package  = "AnchorDockingDsgn + DockedFormEditor"
           Loss     = "The IDE will keep opening as floating windows (the Delphi 7 shape GOD asked us to stop shipping)." },
        @{ Feature = "metadarkstyle"
           Verifier = { Test-MetaDarkStyleInstalled -Dir $LazarusDir }
           Label    = "the MetaDarkStyle design-time package (GOD moehki0x)"
           Package  = "metadarkstyledsgn"
           Loss     = 'Tools -> Options -> Environment -> "Theme" stays missing and the dark style is never applied at IDE start.' }
    )
    foreach ($check in $healChecks) {
        $verdict = & $check.Verifier
        if ($verdict.Ok) { continue }
        Log-Warn "IDE is missing $($check.Label)"
        foreach ($n in $verdict.Notes) { Log-Info "  $n" }
        if (Test-FeatureAttemptIsNew -Feature $check.Feature) {
            Log-Info "Forcing IDE rebuild to link $($check.Package) (source changed since the last attempt)"
            $anyUpdated = $true
        } else {
            Log-Err "$($check.Package) still not linked, and the source has not moved since the last attempt -- not rebuilding again."
            Log-ErrDetail "  $($check.Loss)"
            Log-ErrDetail "  Fix: run  auto-update.bat -ForceRebuild  and read the FIRST 'Error:' line of the build output."
        }
    }
}

# Safety gate: never compile a tree that still has unresolved merge conflicts. A forced
# rebuild over conflict markers feeds "<<<<<<< HEAD" to ppcx64 and fails deep in the build
# (Finn/ZENBOOK r23 win64 smoke 2026-07-03: components/codetools/stdcodetools.pas -> exit 1).
$unmergedFiles = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("ls-files", "--unmerged")
if ($unmergedFiles) {
    Log-Err "Working tree in $LazarusDir has unresolved merge conflicts -- refusing to rebuild (would compile conflict markers)."
    Log-Err "Resolve them, or run 'git merge --abort' / 'git reset --hard origin/main' in $LazarusDir, then re-run the updater."
    Print-Summary
    exit 1
}

if ($anyUpdated) {
    if ($NoBuild) {
        Log-Info "Skipping rebuild (-NoBuild)"
    } else {
        Rebuild-Lazbuild
        Configure-Environment
        Sanitize-PackageRegistrations
        Clean-StalePackageArtifacts
        Rebuild-IDE
        if ((Test-Path (Join-Path $LazarusDir "lazbuild.exe")) -and (Test-Path (Join-Path $LazarusDir "lazarus.exe"))) {
            $script:LocalBuildProductsRestored = $true
        }
        if ($Release) {
            Log-Header "Building release"
            Log-Info "Run build-release.sh via WSL or cross-compile from Linux for release tarballs."
            Log-Info "Native Windows release packaging not yet implemented."
        }
    }
}

# Post-rebuild sanity check: fail loudly if the IDE will warn at startup.
$quality = Test-LazarusDirectoryQuality -Dir $LazarusDir
if ($quality.Quality -ne "Compatible") {
    Write-Host ""
    Log-Err "Lazarus directory check FAILED: $($quality.Quality) [$($quality.Note)]"
    Log-ErrDetail "IDE will show 'Without a proper Lazarus directory you will get a lot of warnings' on startup."
    Log-Info "Run: auto-update.bat -Doctor for a full diagnosis."
}

if (-not $NoLaunch) {
    $starter = Join-Path $LazarusDir "startlazarus.exe"
    $lazarus = Join-Path $LazarusDir "lazarus.exe"
    $exeToLaunch = $null
    if (Test-Path $starter) {
        $exeToLaunch = $starter
    } elseif (Test-Path $lazarus) {
        $exeToLaunch = $lazarus
    }
    if ($exeToLaunch) {
        Log-Header "Launching IDE"
        Log-Info "Starting: $exeToLaunch"
        Start-Process -FilePath $exeToLaunch -WorkingDirectory $LazarusDir
        Log-Ok "IDE launched"
    } else {
        Log-Err "Cannot launch IDE - neither startlazarus.exe nor lazarus.exe found in $LazarusDir"
    }
}

Print-Summary

if ($script:ErrorCount -gt 0) {
    Write-Host ""
    Log-Warn "Auto-update completed with $($script:ErrorCount) error(s) -- see [ERROR] lines above. Returning exit 1."
    exit 1
}
exit 0
