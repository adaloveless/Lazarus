# Headless / agentic installer for Lazarus + VibePascal release tarballs on Windows.
# Non-interactive, no GUI. Downloads the latest GitHub release for x86_64-win64,
# verifies the release SHA-256 digest, extracts, writes a self-contained compilerpc.cfg,
# and creates a lazbuild wrapper on the PATH.
#
# Usage:
#   .\install-lazarus.ps1 [-Prefix <dir>] [-Arch <arch>] [-BinDir <dir>] [-SkipSmoke]
#
# Environment overrides:
#   $env:LAZARUS_PREFIX  - install directory (default: C:\lazarus if writable, else %LOCALAPPDATA%\lazarus)
#   $env:LAZARUS_BIN_DIR - directory for lazbuild.cmd wrapper (default: %USERPROFILE%\bin)
#   $env:GITHUB_TOKEN    - optional PAT for api.github.com rate-limit relief
#   $env:LAZARUS_RELEASES_API - releases API base (default: this repo on api.github.com).
#                          A file:// URL works: a directory holding a `releases` JSON
#                          whose assets point at local files installs a tarball through
#                          the same resolve / download / digest path before it is
#                          published. install-lazarus.sh takes the same variable.

[CmdletBinding()]
param(
    [string]$Prefix = "",
    [ValidateSet("x86_64-win64")]
    [string]$Arch = "x86_64-win64",
    [string]$BinDir = "",
    [switch]$SkipSmoke
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoOwner = "adaloveless"
$RepoName = "Lazarus"
$ApiBase = "https://api.github.com/repos/${RepoOwner}/${RepoName}"
if ($env:LAZARUS_RELEASES_API) { $ApiBase = $env:LAZARUS_RELEASES_API }

function Write-Info  { param([string]$m) Write-Host -ForegroundColor Cyan    "[INFO] $m" }
function Write-Ok    { param([string]$m) Write-Host -ForegroundColor Green   "[OK]   $m" }
function Write-Warn  { param([string]$m) Write-Host -ForegroundColor Yellow  "[WARN] $m" }
function Write-ErrorX { param([string]$m) Write-Host -ForegroundColor Red     "[ERROR] $m" }

# --- defaults ---
if (-not $Prefix) {
    $Prefix = $env:LAZARUS_PREFIX
    if (-not $Prefix) {
        try {
            $testPath = Join-Path $env:SystemDrive "lazarus-test-write"
            [void](New-Item -ItemType Directory -Path $testPath -Force)
            Remove-Item $testPath -Recurse -Force
            $Prefix = "${env:SystemDrive}\lazarus"
        } catch {
            $Prefix = "${env:LOCALAPPDATA}\lazarus"
        }
    }
}
if (-not $BinDir) {
    $BinDir = $env:LAZARUS_BIN_DIR
    if (-not $BinDir) { $BinDir = "${env:USERPROFILE}\bin" }
}

Write-Info "Target architecture: $Arch"
Write-Info "Install prefix:      $Prefix"
Write-Info "Bin directory:       $BinDir"

# --- dependency checks ---
$deps = @("curl", "tar", "python")
foreach ($d in $deps) {
    if (-not (Get-Command $d -ErrorAction SilentlyContinue)) {
        Write-ErrorX "Required command not found: $d"
        exit 1
    }
}

# --- fetch release metadata via Python for robust JSON/regex ---
$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("lazarus-install-" + [Guid]::NewGuid().ToString().Substring(0,8))) -Force
$metaFile = Join-Path $tmp "release-meta.txt"

$headers = @{}
if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)" }

$py = @"
import json, os, re, sys, urllib.request
api_base, target_arch = sys.argv[1], sys.argv[2]
headers = json.loads(os.environ.get("INSTALL_LAZ_HEADERS", "{}"))
url = f"{api_base}/releases"
req = urllib.request.Request(url, headers=headers)
with urllib.request.urlopen(req, timeout=60) as resp:
    releases = json.load(resp)
if not releases:
    print("NO_RELEASES", file=sys.stderr); sys.exit(1)
tarball_re = re.compile(rf'^lazarus-4\.99-vp-{re.escape(target_arch)}-\d{{8}}(?:-r\d+)?\.tar\.gz$')
sha_re = re.compile(r'^SHA256SUMS-\d{8}(?:-r\d+)?\.txt$')
# Walk newest-first for the first release carrying an asset for THIS arch, rather
# than taking releases[0]. Measured 2026-09-18: the win64-only r26 turned the two
# linux and both darwin targets from a working install into NO_TARBALL, because
# r25 -- which carries all of them -- sat one position down the list.
tag = tarball_url = tarball_name = expected_sha = sha_url = None
# Did ANY release carry a tarball for this arch? Without this, a release we
# skipped for want of a checksum reports as NO_TARBALL, which sends whoever
# debugs it hunting a tarball that is sitting right there on the release.
# install-lazarus.sh makes the same distinction; keep the two in step.
saw_tarball = False
for data in releases:
    c_url = c_name = c_sha = c_shaurl = None
    for asset in data.get('assets', []):
        name = asset['name']
        if tarball_re.match(name):
            c_url = asset['browser_download_url']; c_name = name
            dig = asset.get('digest') or ''
            if dig.startswith('sha256:'):
                c_sha = dig.split(':', 1)[1]
        elif sha_re.match(name):
            c_shaurl = asset['browser_download_url']
    if c_url:
        saw_tarball = True
    if c_url and (c_sha or c_shaurl):
        tag = data['tag_name']
        tarball_url, tarball_name, expected_sha, sha_url = c_url, c_name, c_sha, c_shaurl
        break
if not tarball_url:
    print('NO_SHA' if saw_tarball else 'NO_TARBALL', file=sys.stderr); sys.exit(1)
print(tag)
print(tarball_name)
print(tarball_url)
print(expected_sha or '')
print(sha_url or '')
"@

$pyFile = Join-Path $tmp "fetch-release-meta.py"
Set-Content -Path $pyFile -Value $py -Encoding ASCII
$headersJson = $headers | ConvertTo-Json -Compress
$env:INSTALL_LAZ_HEADERS = $headersJson
python $pyFile $ApiBase $Arch | Set-Content $metaFile
$resolverExit = $LASTEXITCODE
Remove-Item Env:\INSTALL_LAZ_HEADERS -ErrorAction SilentlyContinue
# The resolver's exit code MUST be checked here. Unchecked, a resolver that
# exits 1 (NO_TARBALL / NO_SHA) leaves $metaFile absent or empty, $tag and
# $tarballUrl come back $null, and this script walks on to download from a
# null URL -- so the honest one-word reason the resolver printed is buried
# under a wall of "Cannot index into a null array". install-lazarus.sh gets
# the WALK-ON half of this for free from `set -euo pipefail` (measured: it
# aborts before the next statement) but NOT the diagnosis half -- it died
# printing the bare token and nothing else, so it now carries the same named
# block; PowerShell gets neither for free. Deliberately NOT
# redirecting the resolver's stderr -- 2> plus $ErrorActionPreference="Stop"
# behaves differently on Windows PowerShell 5.1, which cannot be tested on
# lazdev, and the token is already on the console line directly above.
if ($resolverExit -ne 0) {
    Write-ErrorX "Release resolver failed (exit $resolverExit) for $Arch. Its one-word reason is printed directly above: NO_TARBALL = no published release carries a tarball for this architecture; NO_SHA = a tarball exists but the release has neither a SHA256SUMS asset nor a GitHub API digest, so the download cannot be verified. Nothing was installed."
    exit 1
}

$tag          = (Get-Content $metaFile)[0]
$tarballName  = (Get-Content $metaFile)[1]
$tarballUrl   = (Get-Content $metaFile)[2]
$apiSha       = (Get-Content $metaFile)[3]
$shaUrl       = (Get-Content $metaFile)[4]

Write-Info "Latest release: $tag"
Write-Info "Tarball:        $tarballName"

# --- download ---
function Download-File($url, $out) {
    curl.exe -fsSL --max-time 1500 --retry 1 -o $out $url
    # curl.exe is a NATIVE command, so a non-zero exit does NOT throw -- not even under
    # the $ErrorActionPreference = "Stop" set at the top of this script.
    # $PSNativeCommandUseErrorActionPreference is False on the pwsh this was measured on
    # (7.6.6) and this script never sets it; Windows PowerShell 5.1 has no such setting at
    # all, so the walk-on happens on BOTH hosts. Measured 2026-09-18 by driving this file
    # with a curl.exe that exits 22: the run printed "Downloading ..." and then walked
    # straight on to "Verifying tarball digest...", dying inside Get-FileHash on a tarball
    # that was never written. That is the same walk-on shape the resolver exit check above
    # exists to prevent, one function down -- and the symptom a user reports is a path error
    # or a bogus "SHA256 mismatch" rather than "the download failed". install-lazarus.sh
    # gets the abort for free from `set -euo pipefail`; PowerShell gets nothing for free.
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorX "Download failed (curl exit $LASTEXITCODE) for $url. Nothing was installed."
        exit 1
    }
}

$tarballPath = Join-Path $tmp $tarballName

Write-Info "Downloading $tarballName..."
Download-File $tarballUrl $tarballPath

# --- determine expected digest (SHA256SUMS asset preferred; GitHub API per-asset digest fallback) ---
# The SHA256SUMS file wins whenever the release has one, as in install-lazarus.sh.
# This script used to prefer the API digest, and that is the one that goes stale.
# Measured 2026-09-23, after the r27 Apple Silicon tarball was replaced at 08:34:26Z:
# 17 minutes later GET /releases and /releases/tags/<tag> still listed the DELETED
# asset and its digest, while the by-name download URLs already served the new
# tarball and the new SHA256SUMS. install-lazarus.sh verified that download. This
# script, replayed against the same kind of listing for win64, stopped on
# "SHA256 mismatch" without ever fetching the SUMS file -- after every asset
# replacement, for as long as GitHub serves the old listing.
if ($shaUrl) {
    $shaName = Split-Path -Leaf $shaUrl
    $shaPath = Join-Path $tmp $shaName
    Write-Info "Downloading $shaName..."
    Download-File $shaUrl $shaPath
    $shaLine = Select-String -Path $shaPath -Pattern ('^([a-f0-9]{64})\s+\*?' + [regex]::Escape($tarballName) + '\s*$') | Select-Object -First 1
    if (-not $shaLine) {
        Write-ErrorX "Tarball name not found in $shaName. Nothing was installed."
        exit 1
    }
    $expectedSha = $shaLine.Matches[0].Groups[1].Value
} elseif ($apiSha) {
    Write-Info "No SHA256SUMS asset on this release; using the GitHub API digest."
    $expectedSha = $apiSha
} else {
    Write-ErrorX "No SHA256 digest available for $tarballName"
    exit 1
}

# --- verify digest ---
Write-Info "Verifying tarball digest..."
$actual = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash.ToLower()
if ($expectedSha.ToLower() -ne $actual) {
    Write-ErrorX "SHA256 mismatch for $tarballName`nExpected: $expectedSha`nActual:   $actual"
    exit 1
}
Write-Ok "Digest verified"

# --- extract ---
if (Test-Path $Prefix) {
    Write-Warn "Install directory already exists: $Prefix"
    $backup = "${Prefix}.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Warn "Backing up to $backup"
    Rename-Item $Prefix $backup
}

Write-Info "Extracting to $Prefix..."
New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
$proc = Start-Process -FilePath "tar.exe" -ArgumentList @("-xzf", $tarballPath, "-C", $Prefix, "--strip-components=1") -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-ErrorX "tar extraction failed"
    exit 1
}
Write-Ok "Extracted to $Prefix"

# --- generate self-contained compiler\fpc.cfg ---
$compilerDir = Join-Path $Prefix "compiler"
$cfgPath = Join-Path $compilerDir "fpc.cfg"
Write-Info "Generating $cfgPath..."
$lines = @("# Self-contained fpc.cfg generated by install-lazarus.ps1", "# Release: $tag")
$lines += "-Fu$Prefix\units\rtl"
$pkgRoot = Join-Path $Prefix "units\packages"
if (Test-Path $pkgRoot) {
    Get-ChildItem -Path $pkgRoot -Directory | Sort-Object Name | ForEach-Object {
        $lines += "-Fu$($_.FullName)"
    }
}
# Library search paths for MSVC/Windows SDK and common fallbacks
$lines += "-Fl$env:SystemRoot\system32"
$lines += "-Fl$env:SystemRoot"
$lines += "-Fl$Prefix\compiler"
Set-Content -Path $cfgPath -Value $lines -Encoding ASCII
Write-Ok "Wrote $cfgPath"

# --- configure lazbuild environmentoptions.xml ---
$envDir = Join-Path $env:LOCALAPPDATA "lazarus"
$envFile = Join-Path $envDir "environmentoptions.xml"
New-Item -ItemType Directory -Path $envDir -Force | Out-Null
$compilerExe = Join-Path $compilerDir "ppcx64.exe"
if (Test-Path $envFile) {
    Write-Info "Patching existing $envFile"
    $xml = Get-Content $envFile -Raw
    $xml = $xml -replace 'CompilerFilename Value="[^"]*"', "CompilerFilename Value=`"$compilerExe`""
    $xml = $xml -replace 'FPCSourceDirectory Value="[^"]*"', "FPCSourceDirectory Value=`"$Prefix`""
    $xml = $xml -replace 'LazarusDirectory Value="[^"]*"', "LazarusDirectory Value=`"$Prefix`""
    Set-Content -Path $envFile -Value $xml -Encoding UTF8
} else {
    Write-Info "Creating $envFile"
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<CONFIG>
  <EnvironmentOptions>
    <CompilerFilename Value="$compilerExe"/>
    <FPCSourceDirectory Value="$Prefix"/>
    <LazarusDirectory Value="$Prefix"/>
  </EnvironmentOptions>
</CONFIG>
"@
    Set-Content -Path $envFile -Value $xml -Encoding UTF8
}

# --- create lazbuild wrapper on PATH ---
Write-Info "Creating lazbuild wrapper in $BinDir..."
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
$wrapper = Join-Path $BinDir "lazbuild.cmd"
$lazbuildExe = Join-Path $Prefix "bin\lazbuild.exe"
Set-Content -Path $wrapper -Value "@`"$lazbuildExe`" %*" -Encoding ASCII
Write-Ok "lazbuild.cmd -> $lazbuildExe"

# --- smoke test ---
if (-not $SkipSmoke) {
    Write-Info "Running smoke test..."
    $ver = & $lazbuildExe --version
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorX "lazbuild --version failed"
        exit 1
    }
    Write-Ok "lazbuild --version works"

    $smokeSrc = Join-Path $tmp "smoke_hello.pas"
    Set-Content -Path $smokeSrc -Value @"
program smoke_hello;
begin
  Writeln('lazarus-installer-smoke-ok');
end.
"@ -Encoding ASCII
    $smokeOut = Join-Path $tmp "smoke_hello.exe"
    $smokeLog = Join-Path $tmp "smoke_compile.log"
    & $compilerExe -n "@$cfgPath" $smokeSrc "-o$smokeOut" *> $smokeLog
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorX "Compiler smoke test failed (log: $smokeLog) -- compiler output:"
        Get-Content $smokeLog | ForEach-Object { Write-Host "    $_" }
        exit 1
    }
    $smokeRun = (& $smokeOut) | Out-String
    if ($smokeRun -notlike "*lazarus-installer-smoke-ok*") {
        Write-ErrorX "Compiler smoke test binary did not run as expected"
        exit 1
    }
    Write-Ok "Compiler smoke test passed"
}

Write-Ok "Lazarus installed successfully at $Prefix"
Write-Info "Add $BinDir to your PATH if it is not already."
