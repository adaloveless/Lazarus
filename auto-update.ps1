#Requires -Version 5.1
param(
    [switch]$Check,
    [switch]$NoBuild,
    [switch]$Release,
    [switch]$UpstreamOnly,
    [switch]$Setup,
    [string]$VPDir,
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
    Write-Host "  -VPDir <path>   Path to VibePascal source (auto-detected if omitted)"
    Write-Host "  -Help           Show this help"
    Write-Host ""
    Write-Host "Default: pull updates and rebuild lazbuild if anything changed."
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

$VPCfgPath = Join-Path $VPDir "vibepascal-win64-native.cfg"

function Ensure-VPConfig {
    $rtlUnits = Join-Path $VPDir "rtl\units\x86_64-win64"
    $pkgUnits = Join-Path $VPDir "packages\*\units\x86_64-win64"

    $cfgContent = @"
# VibePascal configuration for native x86_64-win64 builds (auto-generated)
-Fu$rtlUnits
-Fu$pkgUnits
"@
    Set-Content -Path $VPCfgPath -Value $cfgContent -Encoding UTF8
    Log-Info "Generated VibePascal config: $VPCfgPath"
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
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
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

    & $make -C $LazarusDir clean 2>&1 | Select-Object -Last 1

    & $make -C $LazarusDir lazbuild `
        "PP=$VPCompiler" `
        "FPCDIR=$VPDir" `
        "OPT=-n @$VPCfgPath" 2>&1 | Where-Object { $_ -match "Linking|lines compiled|Fatal|Error" }

    $lazbuildExe = Join-Path $LazarusDir "lazbuild.exe"
    if (Test-Path $lazbuildExe) {
        $size = (Get-Item $lazbuildExe).Length / 1MB
        Log-Ok ("lazbuild.exe rebuilt ({0:N1} MB)" -f $size)
    } else {
        Log-Err "lazbuild.exe build failed!"
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
        Set-Content -Path $vpCfgFile -Value ($cfgLines -join "`n") -Encoding UTF8
        Log-Ok "Created $vpCfgFile"
    }

    Log-Ok "IDE configured to use VibePascal. Restart Lazarus to apply."
}

# --- Main ---

Log-Header "Lazarus + VibePascal Auto-Updater (Windows)"
Write-Host "  Lazarus:    $LazarusDir"
Write-Host "  VibePascal: $VPDir"
Write-Host "  Compiler:   $VPCompiler"
Write-Host ""

if ($Setup) {
    Configure-Environment
    exit 0
}

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

$anyUpdated = $script:VPUpdated -or $script:LazarusUpdated -or $script:UpstreamUpdated

if ($anyUpdated) {
    if ($NoBuild) {
        Log-Info "Skipping rebuild (-NoBuild)"
    } else {
        Rebuild-Lazbuild
        if ($Release) {
            Log-Header "Building release"
            Log-Info "Run build-release.sh via WSL or cross-compile from Linux for release tarballs."
            Log-Info "Native Windows release packaging not yet implemented."
        }
    }
}

Print-Summary
