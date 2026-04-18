#Requires -Version 5.1
param(
    [switch]$Check,
    [switch]$NoBuild,
    [switch]$Release,
    [switch]$UpstreamOnly,
    [switch]$Setup,
    [switch]$FixLpi,
    [switch]$ForceRebuild,
    [string]$VPDir,
    [switch]$SelfUpdated,
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
    Write-Host "  -VPDir <path>   Path to VibePascal source (auto-detected if omitted)"
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

if (-not $VPDir) {
    $parent = Split-Path -Parent $LazarusDir
    $candidates = @(
        (Join-Path $parent "vibepascal"),
        (Join-Path $parent "VibePascal"),
        (Join-Path $parent "fpc"),
        (Join-Path $parent "fpcsrc")
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c ".git")) {
            $VPDir = $c
            break
        }
    }
    if (-not $VPDir) {
        Log-Err "VibePascal directory not found. Use -VPDir to specify its location."
        Log-Err "Searched: $($candidates -join ', ')"
        exit 1
    }
}

$VPCompiler = Join-Path $VPDir "compiler\ppcx64.exe"
if (-not (Test-Path $VPCompiler)) {
    $VPCompiler = Join-Path $VPDir "compiler\ppcx64"
}

function Extract-VPBinaries {
    $compilerExe = Join-Path $VPDir "compiler\ppcx64.exe"
    if (Test-Path $compilerExe) { return }

    Log-Info "VibePascal compiler binary not found, checking dist/ for prebuilt..."
    $distDir = Join-Path $VPDir "dist\win64"
    if (-not (Test-Path $distDir)) {
        $distDir = Join-Path $VPDir "dist"
    }

    $tarballs = @()
    if (Test-Path $distDir) {
        $tarballs = Get-ChildItem -Path $distDir -Filter "*.tar.gz" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    }

    if ($tarballs.Count -eq 0) {
        $tarballs = Get-ChildItem -Path $distDir -Filter "*.zip" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    }

    if ($tarballs.Count -gt 0) {
        $archive = $tarballs[0].FullName
        Log-Info "Extracting VibePascal binaries from $archive"
        $tempDir = Join-Path $env:TEMP "vp-extract-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            if ($archive.EndsWith(".zip")) {
                Expand-Archive -Path $archive -DestinationPath $tempDir -Force
            } else {
                & "$env:SystemRoot\System32\tar.exe" -xzf $archive -C $tempDir 2>&1 | Out-Null
            }
            $found = Get-ChildItem -Path $tempDir -Filter "ppcx64.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $compilerDir = Join-Path $VPDir "compiler"
                if (-not (Test-Path $compilerDir)) { New-Item -ItemType Directory -Path $compilerDir -Force | Out-Null }
                Copy-Item $found.FullName $compilerExe -Force
                Log-Ok "Extracted ppcx64.exe to $compilerExe"
                $script:VPCompiler = $compilerExe
            } else {
                Log-Warn "ppcx64.exe not found in archive"
            }
        } finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    } else {
        Log-Warn "No VibePascal dist archives found at $distDir"
    }
}

$VPCfgPath = Join-Path $VPDir "vibepascal-win64-native.cfg"

function Ensure-VPConfig {
    $rtlUnits = Join-Path $VPDir "rtl\units\x86_64-win64"
    $pkgUnits = Join-Path $VPDir "packages\*\units\x86_64-win64"

    $cfgContent = @"
# VibePascal configuration for native x86_64-win64 builds (auto-generated)
-Fu$rtlUnits
-Fu$pkgUnits
"@
    [IO.File]::WriteAllText($VPCfgPath, $cfgContent, (New-Object System.Text.UTF8Encoding $false))
    Log-Info "Generated VibePascal config: $VPCfgPath"
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
    $scriptPath = $MyInvocation.PSCommandPath
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    if (-not $scriptPath) { return }
    $postHash = (Get-FileHash -Path $scriptPath -Algorithm SHA256).Hash
    if ($PreHash -ne $postHash) {
        Log-Info "auto-update.ps1 was updated by pull -- relaunching with new version"
        $relaunchArgs = @("-SelfUpdated")
        if ($Check) { $relaunchArgs += "-Check" }
        if ($NoBuild) { $relaunchArgs += "-NoBuild" }
        if ($Release) { $relaunchArgs += "-Release" }
        if ($UpstreamOnly) { $relaunchArgs += "-UpstreamOnly" }
        if ($Setup) { $relaunchArgs += "-Setup" }
        if ($FixLpi) { $relaunchArgs += "-FixLpi" }
        if ($ForceRebuild) { $relaunchArgs += "-ForceRebuild" }
        if ($VPDir) { $relaunchArgs += "-VPDir"; $relaunchArgs += $VPDir }
        & $scriptPath @relaunchArgs
        exit $LASTEXITCODE
    }
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

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $make -C $LazarusDir clean 2>&1 | Select-Object -Last 1

    & $make -C $LazarusDir lazbuild `
        "PP=$VPCompiler" `
        "FPCDIR=$VPDir" `
        "OPT=-n @$VPCfgPath" 2>&1 | Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }
    $ErrorActionPreference = $prevEAP

    $lazbuildExe = Join-Path $LazarusDir "lazbuild.exe"
    if (Test-Path $lazbuildExe) {
        $size = (Get-Item $lazbuildExe).Length / 1MB
        Log-Ok ("lazbuild.exe rebuilt ({0:N1} MB)" -f $size)
    } else {
        Log-Err "lazbuild.exe build failed!"
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

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $lazbuildExe --lazarusdir=$LazarusDir --build-ide= --compiler=$VPCompiler --pcp=$envDir --ws=win32 2>&1 |
        Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }
    $ErrorActionPreference = $prevEAP

    $lazarusExe = Join-Path $LazarusDir "lazarus.exe"
    if (Test-Path $lazarusExe) {
        $size = (Get-Item $lazarusExe).Length / 1MB
        Log-Ok ("lazarus.exe rebuilt ({0:N1} MB)" -f $size)
    } else {
        Log-Err "lazarus.exe build failed!"
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

        $compilerNode = $envOpts.SelectSingleNode("CompilerFilename")
        if ($compilerNode) {
            $oldVal = $compilerNode.GetAttribute("Value")
            $compilerNode.SetAttribute("Value", $vpCompilerPath)
            Log-Info "CompilerFilename: $oldVal -> $vpCompilerPath"
        }

        $fpcSrcNode = $envOpts.SelectSingleNode("FPCSourceDirectory")
        if ($fpcSrcNode) {
            $oldVal = $fpcSrcNode.GetAttribute("Value")
            $fpcSrcNode.SetAttribute("Value", $VPDir)
            Log-Info "FPCSourceDirectory: $oldVal -> $VPDir"
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
    if (Test-Path $vpCfgFile) {
        $cfgContent = Get-Content $vpCfgFile -Raw
        if ($cfgContent -notmatch [regex]::Escape($vpUnitsDir)) {
            Add-Content -Path $vpCfgFile -Value "`n-Fu$vpUnitsDir"
            Log-Info "Added VibePascal units path to fpc.cfg"
        } else {
            Log-Ok "VibePascal units path already in fpc.cfg"
        }
    } else {
        Log-Info "Creating VibePascal fpc.cfg"
        $cfgLines = @(
            "# VibePascal compiler config (auto-generated by auto-update.ps1)",
            "-Fu$vpUnitsDir",
            "-Fu$VPDir\rtl\units\x86_64-win64",
            "-Fu$VPDir\packages\*\units\x86_64-win64"
        )
        [IO.File]::WriteAllText($vpCfgFile, ($cfgLines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
        Log-Ok "Created $vpCfgFile"
    }

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

if ($Setup) {
    Extract-VPBinaries
    Configure-Environment
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

Print-Summary
