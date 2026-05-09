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
    Write-Host "  -Help           Show this help"
    Write-Host ""
    Write-Host "Default: pull updates, rebuild lazbuild + IDE if anything changed."
    exit 0
}

function Log-Info  { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Log-Ok    { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Log-Warn  { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Log-Err   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Header { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

$script:LazarusUpdated = $false
$script:VPUpdated = $false
$script:UpstreamUpdated = $false

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
        Log-Err "VibePascal directory not found. Use -VPDir to specify its location."
        Log-Err "Searched: $($candidates -join ', ')"
        Log-Err ""
        Log-Err "How to fix:"
        Log-Err "  1. Clone next to Lazarus: git clone git@github.com:adaloveless/vibepascal.git ""$parent\vibepascal"""
        Log-Err "  2. Or pass the path:      .\auto-update.bat -VPDir C:\path\to\vibepascal"
        Log-Err "  3. Or set the env var:    setx VPDIR ""C:\path\to\vibepascal"" (then open a new shell)"
        exit 1
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
    # Parse -v## suffix (e.g., vibepascal-win64-<sha>-v28.tar.gz) and sort numerically
    # descending; unversioned archives fall behind and sort by LastWriteTime.
    # Fresh git clones give all archives nearly identical mtimes, so LastWriteTime
    # alone is non-deterministic -- version number is the authoritative ordering.
    return $Items | Sort-Object `
        @{Expression = {
            if ($_.Name -match '-v(\d+)\.(tar\.gz|zip)$') { [int]$Matches[1] } else { -1 }
          }; Descending = $true}, `
        @{Expression = {$_.LastWriteTime}; Descending = $true}
}

function Extract-VPBinaries {
    $compilerExe = Join-Path $VPDir "compiler\ppcx64.exe"
    $markerFile = Join-Path $VPDir ".auto-update-extracted.txt"

    $distDir = Join-Path $VPDir "dist\win64"
    if (-not (Test-Path $distDir)) {
        $distDir = Join-Path $VPDir "dist"
    }

    $tarballs = @()
    if (Test-Path $distDir) {
        $tarballs = @(Sort-VPArchives (Get-ChildItem -Path $distDir -Filter "*.tar.gz" -ErrorAction SilentlyContinue))
    }
    if ($tarballs.Count -eq 0 -and (Test-Path $distDir)) {
        $tarballs = @(Sort-VPArchives (Get-ChildItem -Path $distDir -Filter "*.zip" -ErrorAction SilentlyContinue))
    }

    if ($tarballs.Count -eq 0) {
        if (Test-Path $compilerExe) { return }
        Log-Warn "No VibePascal dist archives found at $distDir"
        return
    }

    $archive = $tarballs[0].FullName
    $archiveKey = "$($tarballs[0].Name)|$($tarballs[0].LastWriteTime.Ticks)"

    if ((Test-Path $compilerExe) -and (Test-Path $markerFile)) {
        $lastExtracted = (Get-Content $markerFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($lastExtracted -eq $archiveKey) { return }
        Log-Info "Newer VibePascal tarball detected ($($tarballs[0].Name)), re-extracting..."
    } else {
        Log-Info "Extracting VibePascal binaries from $archive"
    }

    $tempDir = Join-Path $env:TEMP "vp-extract-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        if ($archive.EndsWith(".zip")) {
            Expand-Archive -Path $archive -DestinationPath $tempDir -Force
        } else {
            & "$env:SystemRoot\System32\tar.exe" -xzf $archive -C $tempDir 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Log-Err "tar extraction failed (exit $LASTEXITCODE)"
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

        # Find the compiler binary in the tarball (v24+: bin/ppcx64.exe, legacy: compiler/ppcx64.exe)
        $srcCompiler = $null
        foreach ($rel in @("bin\ppcx64.exe", "compiler\ppcx64.exe")) {
            $candidate = Join-Path $extractRoot $rel
            if (Test-Path $candidate) { $srcCompiler = $candidate; break }
        }
        if (-not $srcCompiler) {
            $found = Get-ChildItem -Path $extractRoot -Filter "ppcx64.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $srcCompiler = $found.FullName }
        }
        if (-not $srcCompiler) {
            Log-Err "ppcx64.exe not found in archive"
            return
        }

        # Blow away stale units before re-extracting to avoid v24-compiler+v22-PPU CRC mismatches.
        # Both dirs matter: units\x86_64-win64 holds tarball PPUs, rtl\units\x86_64-win64 may hold
        # PPUs from a prior source build that collide with tarball PPUs (different system.ppu CRC).
        foreach ($stale in @("units\x86_64-win64", "rtl\units\x86_64-win64")) {
            $stalePath = Join-Path $VPDir $stale
            if (Test-Path $stalePath) {
                Log-Info "Removing stale PPU units at $stalePath"
                Remove-Item -Recurse -Force $stalePath -ErrorAction SilentlyContinue
            }
        }

        # Copy ALL top-level entries (bin/, units/, compiler/, fpc.cfg, etc.) into $VPDir
        Log-Info "Copying tarball contents to $VPDir"
        Get-ChildItem -Path $extractRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $destPath = Join-Path $VPDir $_.Name
            if ($_.PSIsContainer) {
                if (-not (Test-Path $destPath)) {
                    New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                }
                Copy-Item -Path (Join-Path $_.FullName "*") -Destination $destPath -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Copy-Item -Path $_.FullName -Destination $destPath -Force
            }
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
        Log-Ok "Extracted VibePascal: ppcx64.exe + $unitCount PPUs$(if ($fpcCfgExtracted) { ' + bin\fpc.cfg' })"

        [IO.File]::WriteAllText($markerFile, $archiveKey, (New-Object System.Text.UTF8Encoding $false))

        # Prefer bin\ppcx64.exe -- fpcres.exe and friends live in bin\ alongside it, and the
        # tarball's fpc.cfg is authored for $FPCBINDIR=bin/. compiler\ppcx64.exe is kept for
        # legacy callers but has no resource compiler next to it, so running lazbuild from
        # compiler\ fails with "fpcres.exe not found".
        $binCompiler = Join-Path $VPDir "bin\ppcx64.exe"
        if (Test-Path $binCompiler) {
            $script:VPCompiler = $binCompiler
        } else {
            $script:VPCompiler = $compilerExe
        }
    } finally {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
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

function Ensure-SelfClean {
    param([string]$RepoDir)
    $scriptName = "auto-update.ps1"
    $result = Invoke-Git -WorkDir $RepoDir -GitArgs @("status", "--porcelain", "--", $scriptName)
    if ($result.Output -and $result.Output.Trim().Length -gt 0) {
        Log-Warn "auto-update.ps1 has local modifications -- restoring upstream version"
        $restore = Invoke-Git -WorkDir $RepoDir -GitArgs @("checkout", "--", $scriptName)
        if ($restore.ExitCode -eq 0) {
            Log-Ok "Restored clean auto-update.ps1 from git"
        } else {
            Log-Err "Failed to restore auto-update.ps1: $($restore.Error)"
        }
    }
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
    $result = Invoke-Git -WorkDir $VPDir -GitArgs @("pull", "--ff-only", "origin", "main")
    if ($result.ExitCode -ne 0) {
        Log-Err "VibePascal pull failed: $($result.Error)"
        return
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
        Log-Info "Rebasing $localCommits local commit(s) onto upstream..."
        $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("rebase", "upstream/main")
        if ($result.ExitCode -ne 0) {
            Log-Err "Rebase failed: $($result.Error)"
            Log-Err "Resolve conflicts manually, then re-run."
            return
        }
        Log-Ok "Rebase onto upstream complete"
    }

    Log-Info "Pushing to origin..."
    $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("push", "origin", "main")
    if ($result.ExitCode -ne 0) {
        Log-Warn "Push failed (non-critical): $($result.Error)"
    } else {
        Log-Ok "Pushed to adaloveless/Lazarus"
    }
    $script:LazarusUpdated = $true
}

function Pull-LazarusOrigin {
    if ($script:LazarusUpdated -and -not $script:UpstreamUpdated) {
        Log-Header "Pulling Lazarus origin changes"
        $result = Invoke-Git -WorkDir $LazarusDir -GitArgs @("pull", "--ff-only", "origin", "main")
        if ($result.ExitCode -ne 0) {
            Log-Err "Pull failed: $($result.Error)"
        } else {
            Log-Ok "Lazarus origin pulled"
        }
    }
}

function Find-Make {
    $makePaths = @(
        (Get-Command "make" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        (Get-Command "mingw32-make" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        "C:\lazarus\fpc\bin\x86_64-win64\make.exe",
        "C:\FPC\bin\x86_64-win64\make.exe"
    )
    foreach ($p in $makePaths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    foreach ($root in @("C:\lazarus\fpc", "C:\FPC")) {
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

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $lazbuildExe --lazarusdir=$LazarusDir --build-ide= --compiler=$VPCompiler --pcp=$envDir --ws=win32 2>&1 |
        Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    $env:PATH = $oldPath

    if ($buildExit -ne 0) {
        Log-Err "lazarus.exe build failed with exit code $buildExit"
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
        $make = Find-Make
        if ($make) {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & $make -C $LazarusDir starter `
                "PP=$VPCompiler" `
                "FPCDIR=$VPDir" `
                "OPT=-n @$VPCfgPath" 2>&1 | Where-Object { $_ -match "Linking|Fatal|Error" }
            $ErrorActionPreference = $prevEAP
            if (Test-Path $starterExe) {
                Log-Ok "startlazarus.exe built"
            }
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

    if (-not $script:VPUpdated -and -not $script:UpstreamUpdated -and -not $script:LazarusUpdated) {
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
    # Verify the design-time package vendored at components\metadarkstyle was
    # built and linked into lazarus.exe. Returns @{ Ok = $bool; Notes = @() }.
    param([string]$Dir = $LazarusDir, [string]$Cpu = "x86_64", [string]$Os = "win64")

    $result = @{ Ok = $true; Notes = @() }

    $rtLpk = Join-Path $Dir "components\metadarkstyle\metadarkstyle.lpk"
    $dsLpk = Join-Path $Dir "components\metadarkstyle\dsgn\metadarkstyledsgn.lpk"
    foreach ($lpk in @($rtLpk, $dsLpk)) {
        if (-not (Test-Path $lpk)) {
            $result.Ok = $false
            $result.Notes += "Source missing: $lpk (re-pull from upstream fork)"
        }
    }
    if (-not $result.Ok) { return $result }

    $rtPpu = Join-Path $Dir "components\metadarkstyle\lib\$Cpu-$Os\metadarkstyle.ppu"
    $dsPpu = Join-Path $Dir "components\metadarkstyle\dsgn\lib\$Cpu-$Os\metadarkstyledsgn.ppu"
    foreach ($ppu in @($rtPpu, $dsPpu)) {
        if (-not (Test-Path $ppu)) {
            $result.Ok = $false
            $result.Notes += "Build artifact missing: $ppu (Rebuild-IDE did not compile it -- check uses clause in ide\lazarus.pp)"
        }
    }
    if (-not $result.Ok) { return $result }

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
        Log-Warn "IDE may show 'Without a proper Lazarus directory' on startup. Run -ForceRebuild to rebuild lazarus.exe."
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

Extract-VPBinaries

Ensure-SelfClean -RepoDir $LazarusDir
$scriptPreHash = (Get-FileHash -Path (Join-Path $LazarusDir "auto-update.ps1") -Algorithm SHA256).Hash

Invoke-Git -WorkDir $LazarusDir -GitArgs @("fetch", "upstream") | Out-Null

if (-not $UpstreamOnly) {
    Check-VPUpdates
}
Check-LazarusUpstream
Check-LazarusOrigin

if ($Check) {
    Print-Summary
    exit 0
}

if (-not $UpstreamOnly) {
    Pull-VP
}
Pull-LazarusUpstream
Pull-LazarusOrigin

Relaunch-IfUpdated -PreHash $scriptPreHash

$anyUpdated = $script:VPUpdated -or $script:LazarusUpdated -or $script:UpstreamUpdated

if ($ForceRebuild) {
    Log-Info "Force rebuild requested"
    $anyUpdated = $true
}

if ($anyUpdated) {
    if ($NoBuild) {
        Log-Info "Skipping rebuild (-NoBuild)"
    } else {
        Rebuild-Lazbuild
        Configure-Environment
        Rebuild-IDE
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
        Log-Err "Cannot launch IDE — neither startlazarus.exe nor lazarus.exe found in $LazarusDir"
    }
}

Print-Summary
