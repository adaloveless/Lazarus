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
data = releases[0]
tag = data["tag_name"]
tarball_re = re.compile(rf'^lazarus-4\.99-vp-{re.escape(target_arch)}-\d{{8}}(?:-r\d+)?\.tar\.gz$')
sha_re = re.compile(r'^SHA256SUMS-\d{8}(?:-r\d+)?\.txt$')
tarball_url = tarball_name = expected_sha = sha_url = None
for asset in data.get('assets', []):
    name = asset['name']
    if tarball_re.match(name):
        tarball_url = asset['browser_download_url']; tarball_name = name
        dig = asset.get('digest') or ''
        if dig.startswith('sha256:'):
            expected_sha = dig.split(':', 1)[1]
    elif sha_re.match(name):
        sha_url = asset['browser_download_url']
if not tarball_url:
    print('NO_TARBALL', file=sys.stderr); sys.exit(1)
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
Remove-Item Env:\INSTALL_LAZ_HEADERS -ErrorAction SilentlyContinue

$tag          = (Get-Content $metaFile)[0]
$tarballName  = (Get-Content $metaFile)[1]
$tarballUrl   = (Get-Content $metaFile)[2]
$expectedSha  = (Get-Content $metaFile)[3]
$shaUrl       = (Get-Content $metaFile)[4]

Write-Info "Latest release: $tag"
Write-Info "Tarball:        $tarballName"

# --- download ---
function Download-File($url, $out) {
    curl.exe -fsSL --max-time 1500 --retry 1 -o $out $url
}

$tarballPath = Join-Path $tmp $tarballName

Write-Info "Downloading $tarballName..."
Download-File $tarballUrl $tarballPath

# --- determine expected digest (GitHub API per-asset digest preferred; SHA256SUMS asset fallback) ---
if (-not $expectedSha -and $shaUrl) {
    $shaName = Split-Path -Leaf $shaUrl
    $shaPath = Join-Path $tmp $shaName
    Write-Info "Downloading $shaName..."
    Download-File $shaUrl $shaPath
    $expectedSha = (Select-String -Path $shaPath -Pattern "([a-f0-9]{64})\s+$([regex]::Escape($tarballName))").Matches.Groups[1].Value
}
if (-not $expectedSha) {
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
    $ver = & $lazbuildExe --version 2`>`&1
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
    $smokeRun = & $smokeOut 2`>`&1
    if ($smokeRun -notlike "*lazarus-installer-smoke-ok*") {
        Write-ErrorX "Compiler smoke test binary did not run as expected"
        exit 1
    }
    Write-Ok "Compiler smoke test passed"
}

Write-Ok "Lazarus installed successfully at $Prefix"
Write-Info "Add $BinDir to your PATH if it is not already."
