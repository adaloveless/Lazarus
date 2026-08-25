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
function Log-Header { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

$script:LazarusUpdated = $false
$script:VPUpdated = $false
$script:UpstreamUpdated = $false
$script:BuildProductsWereMissing = $false
$script:LocalBuildProductsRestored = $false
$script:ErrorCount = 0

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
            Log-Err "Searched: $($candidates -join ', ')"
            Log-Err ""
            Log-Err "How to fix manually:"
            Log-Err "  1. Clone next to Lazarus: git clone $cloneRepo ""$parent\vibepascal"""
            Log-Err "  2. Or pass the path:      .\auto-update.bat -VPDir C:\path\to\vibepascal"
            Log-Err "  3. Or set the env var:    setx VPDIR ""C:\path\to\vibepascal"" (then open a new shell)"
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
            Log-Warn "Otto ships v33 units as the stable baseline -- ensure dist/win64 contains vibepascal-v33-win64-units.tar.gz (or newer)"
            return @()
        }
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
    if ($versionedTarball) { Log-Info "LATEST.txt version: $($latestData['version']) commit: $($latestData['source_commit'])" }

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

function Check-VPUpdates {
    Log-Header "Checking VibePascal (adaloveless/vibepascal)"

    if (-not (Test-Path (Join-Path $VPDir ".git"))) {
        Log-Err "VibePascal repo not found at $VPDir"
        return
    }

    Invoke-Git -WorkDir $VPDir -GitArgs @("fetch", "origin") | Out-Null

    $behind = Get-GitOutput -WorkDir $VPDir -GitArgs @("rev-list", "--count", "HEAD..origin/main")
    if (-not $behind) { $behind = "0" }

    if ([int]$behind -gt 0) {
        Log-Warn "VibePascal: $behind new commit(s) available"
        $log = Get-GitOutput -WorkDir $VPDir -GitArgs @("log", "--oneline", "HEAD..origin/main")
        Write-Host $log
        $script:VPUpdated = $true
    } else {
        Log-Ok "VibePascal: up to date"
    }
}

function Pull-VP {
    if (-not $script:VPUpdated) { return }

    Log-Header "Pulling VibePascal updates"
    # If ff-only pull fails (local branch diverged from origin/main), reset to origin/main.
    # Recovers from the pinning bug where a stale local commit leaves VP stuck on an old version
    # (GOD mrghu0l5; Finn/ZENBOOK r23 win64 smoke: --ff-only failure + no fallback = pinned forever).
    $result = Invoke-Git -WorkDir $VPDir -GitArgs @("pull", "--ff-only", "origin", "main")
    if ($result.ExitCode -ne 0) {
        Log-Warn "VP --ff-only pull failed; reset --hard origin/main (pristine mode)"
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

    $behind = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-list", "--count", "HEAD..upstream/main")
    if (-not $behind) { $behind = "0" }

    $localCommits = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-list", "--count", "upstream/main..HEAD")
    if (-not $localCommits) { $localCommits = "0" }

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

    Invoke-Git -WorkDir $LazarusDir -GitArgs @("fetch", "origin") | Out-Null

    $behind = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("rev-list", "--count", "HEAD..origin/main")
    if (-not $behind) { $behind = "0" }

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

function Find-Make {
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
                if (Test-Path $candidate) { return $candidate }
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
        Log-Err "make not found. Install MinGW/MSYS2 or add FPC's make to PATH."
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
    # Stale .ppu/.o files (compiled with older/different compilers) cause
    # VibePascal ICEs when lazbuild --build-ide= tries to recompile them.
    # Wipe lib/ output dirs for ALL installed packages (external + Lazarus
    # built-in) so they rebuild cleanly from source.

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
    $commonxRoot = $null
    $commonxLpkPath = $null
    $commonxCandidates = @()
    if ($env:COMMONX_DIR) { $commonxCandidates += $env:COMMONX_DIR }
    $commonxCandidates += @(
        "C:\source\Pascal\FPC\commonx",
        "C:\source\pascal\FPC\commonx",
        (Join-Path (Split-Path -Parent $LazarusDir) "commonx")
    )
    foreach ($cand in $commonxCandidates) {
        if ($cand -and (Test-Path $cand)) { $commonxRoot = $cand; break }
    }

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
    # now runs `svn update` on the commonx tree (above) so a lagging checkout cannot
    # silently re-fail -- see the c633 block. This retry remains purely as the LAST-RESORT
    # guarantee: a missing component on the palette is bad, but a machine with no IDE is far
    # worse (c626). If commonx is dropped here despite a successful svn update, the cause is
    # NEW -- read the first 'Error:' line printed above, do not assume the old 3069.
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Log-Warn "IDE build failed on attempt $($attempt-1); cleaning stale artifacts and retrying..."
            Sanitize-PackageRegistrations
            Clean-StalePackageArtifacts
            Start-Sleep -Seconds 2
        }

        $attemptPkgArgs = $addPkgArgs
        if ($attempt -gt 1 -and $commonxLpkPath) {
            $keptLpks = @($addPkgLpks | Where-Object { $_ -ne $commonxLpkPath })
            $attemptPkgArgs = @()
            if ($keptLpks.Count -gt 0) { $attemptPkgArgs = @("--add-package") + $keptLpks }
            Log-Warn "Retrying WITHOUT commonx (PackageCommonX_LCL) so the IDE still builds."
            Log-Warn "  The updater ran 'svn update' on the commonx tree before this build; if commonx still fails here, a stale checkout is NOT the cause."
            Log-Warn "  The first 'Error:' line printed above is the cause. If it names a commonx unit with error 3069, the svn update did not take effect (see the svn messages from earlier in this run)."
            Log-Warn "  Consequence: commonx components (incl. TTouchButton / TBetterWebBrowser) will NOT be on the designer palette this run."
        }

        & $lazbuildExe --lazarusdir=$LazarusDir --build-ide= --compiler=$VPCompiler --pcp=$envDir --ws=win32 @attemptPkgArgs 2>&1 |
            Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }
        $buildExit = $LASTEXITCODE
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
    } else {
        Log-Err "MetaDarkStyle dark mode NOT installed -- this is a regression GOD will notice."
        foreach ($n in $mds.Notes) { Log-Err "  $n" }
        Log-Err "Fix: re-pull origin/main, then run -ResetConfig -ForceRebuild."
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

function Print-Summary {
    Log-Header "Update Summary"

    if ($script:VPUpdated) {
        Write-Host "  [+] VibePascal updated" -ForegroundColor Green
    } else {
        Write-Host "  [-] VibePascal: no changes" -ForegroundColor Cyan
    }

    if ($script:UpstreamUpdated) {
        Write-Host "  [+] Lazarus upstream synced" -ForegroundColor Green
    } else {
        Write-Host "  [-] Lazarus upstream: no changes" -ForegroundColor Cyan
    }

    if ($script:LazarusUpdated) {
        Write-Host "  [+] Lazarus updated" -ForegroundColor Green
    } else {
        Write-Host "  [-] Lazarus: no changes" -ForegroundColor Cyan
    }

    if ($script:LocalBuildProductsRestored) {
        Write-Host "  [+] Local build products rebuilt" -ForegroundColor Green
    } elseif ($script:BuildProductsWereMissing) {
        Write-Host "  [!] Local build products missing" -ForegroundColor Yellow
    }

    if (-not $script:VPUpdated -and -not $script:UpstreamUpdated -and -not $script:LazarusUpdated -and -not $script:BuildProductsWereMissing) {
        Write-Host ""
        Log-Ok "Everything is up to date. Nothing to do."
    }

    Write-Host ""
    $lazHead = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("log", "--oneline", "-1")
    $vpHead = Get-GitOutput -WorkDir $VPDir -GitArgs @("log", "--oneline", "-1")
    Write-Host "Lazarus HEAD: $lazHead"
    Write-Host "VibePascal HEAD: $vpHead"
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

    $dsPpu = Join-Path $Dir "components\metadarkstyle\dsgn\lib\$Cpu-$Os\metadarkstyledsgn.ppu"
    if (-not (Test-Path $dsPpu)) {
        $result.Ok = $false
        $result.Notes += "Build artifact missing: $dsPpu (Rebuild-IDE did not compile it -- check uses clause in ide\lazarus.pp)"
        return $result
    }

    $lazExe = Join-Path $Dir "lazarus.exe"
    if (Test-Path $lazExe) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($lazExe)
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            if ($text -notmatch "(?i)metadarkstyle") {
                $result.Ok = $false
                $result.Notes += "lazarus.exe does NOT contain MetaDarkStyle symbols -- design-time package was not linked. Run -ForceRebuild."
            } else {
                $result.Notes += "lazarus.exe contains MetaDarkStyle symbols"
            }
        } catch {
            $result.Notes += "Could not scan lazarus.exe: $_"
        }
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
    } else {
        Log-Err "MetaDarkStyle (dark mode IDE skin): NOT installed"
        foreach ($n in $mds.Notes) { Log-Err "  $n" }
        $problems++
    }

    $lpkCheck = Test-IdePackageLpkConsistency -Dir $LazarusDir
    if ($lpkCheck.Ok) {
        Log-Ok "IDE package .lpk vs source consistency: OK"
    } else {
        Log-Err "IDE package .lpk vs source mismatches detected ($($lpkCheck.Mismatches.Count)):"
        foreach ($m in $lpkCheck.Mismatches) { Log-Err "  $m" }
        Log-Err "  Cause: source pulled but .lpk stale, or .lpk pulled but source not yet rebuilt."
        Log-Err "  Fix: re-pull origin/main, then run -ForceRebuild."
        $problems++
    }

    Write-Host ""
    if ($problems -eq 0) {
        Log-Ok "No problems found. Toolchain looks healthy."
    } else {
        Log-Err "$problems problem(s) found."
        Log-Info "Suggested fixes:"
        Log-Info "  1. Run: .\auto-update.ps1 -ResetConfig -ForceRebuild"
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
        }

        $makeNode = $envOpts.SelectSingleNode("MakeFilename")
        $makePath = Find-Make
        if ($makePath) {
            if (-not $makeNode) {
                $makeNode = $xml.CreateElement("MakeFilename")
                $envOpts.AppendChild($makeNode) | Out-Null
            }
            $oldVal = $makeNode.GetAttribute("Value")
            if ($oldVal -ne $makePath) {
                $makeNode.SetAttribute("Value", $makePath)
                Log-Info "MakeFilename: $oldVal -> $makePath"
            }
        }

        $xml.Save($envOptsFile)
        Log-Ok "Updated $envOptsFile"
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

$upstreamRemote = Get-GitOutput -WorkDir $LazarusDir -GitArgs @("remote", "get-url", "upstream")
if ($upstreamRemote) {
    Invoke-Git -WorkDir $LazarusDir -GitArgs @("fetch", "upstream") | Out-Null
} else {
    Log-Warn "No 'upstream' remote configured -- skipping upstream Lazarus (fpc/Lazarus) checks"
    Log-Info "To add it: git remote add upstream https://github.com/fpc/Lazarus.git"
}

if (-not $UpstreamOnly) {
    Check-VPUpdates
}
if ($upstreamRemote) {
    Check-LazarusUpstream
}
Check-LazarusOrigin

if ($Check) {
    Print-Summary
    exit 0
}

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
    Log-Err "IDE will show 'Without a proper Lazarus directory you will get a lot of warnings' on startup."
    Log-Info "Run: .\auto-update.ps1 -Doctor for a full diagnosis."
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
