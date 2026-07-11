#!/bin/bash
# Headless / agentic installer for Lazarus + VibePascal release tarballs.
# Non-interactive, no GUI. Downloads the latest GitHub release for this
# platform, verifies SHA256SUMS, extracts, writes a self-contained fpc.cfg,
# and wires lazbuild into the PATH.
#
# Usage:
#   ./install-lazarus.sh [--prefix <dir>] [--arch <arch>] [--bin-dir <dir>] [--skip-smoke] [--help]
#
# Environment overrides:
#   LAZARUS_PREFIX   - install directory (default: /opt/lazarus if writable, else ~/.local/lazarus)
#   LAZARUS_BIN_DIR  - directory for lazbuild symlink (default: ~/.local/bin)
#   GITHUB_TOKEN     - optional PAT for api.github.com rate-limit relief

set -euo pipefail

REPO_OWNER="adaloveless"
REPO_NAME="Lazarus"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<'EOF'
Usage: install-lazarus.sh [options]

Options:
  --prefix <dir>    Install directory (env: LAZARUS_PREFIX)
  --arch <arch>     Force target arch instead of auto-detect
  --bin-dir <dir>   Directory for lazbuild symlink (env: LAZARUS_BIN_DIR)
  --skip-smoke      Skip post-install smoke test
  --help            Show this help
EOF
    exit 0
}

# --- argument parsing ---
PREFIX=""
FORCE_ARCH=""
BIN_DIR=""
SKIP_SMOKE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)   PREFIX="$2"; shift 2 ;;
        --arch)     FORCE_ARCH="$2"; shift 2 ;;
        --bin-dir)  BIN_DIR="$2"; shift 2 ;;
        --skip-smoke) SKIP_SMOKE=1; shift ;;
        --help|-h)  usage ;;
        *)          log_err "Unknown option: $1"; usage ;;
    esac
done

# --- defaults ---
if [[ -z "$PREFIX" ]]; then
    PREFIX="${LAZARUS_PREFIX:-}"
    if [[ -z "$PREFIX" ]]; then
        if [[ -w /opt ]]; then
            PREFIX="/opt/lazarus"
        else
            PREFIX="${HOME}/.local/lazarus"
        fi
    fi
fi
if [[ -z "$BIN_DIR" ]]; then
    BIN_DIR="${LAZARUS_BIN_DIR:-${HOME}/.local/bin}"
fi

# --- arch detection ---
HOST_ARCH="$(uname -m)"
LAZ_ARCH="${FORCE_ARCH:-}"
if [[ -z "$LAZ_ARCH" ]]; then
    case "$HOST_ARCH" in
        x86_64|amd64)  LAZ_ARCH="x86_64-linux" ;;
        aarch64|arm64) LAZ_ARCH="aarch64-linux" ;;
        armv7l|armv7)  LAZ_ARCH="arm-linux" ;;
        *)
            log_err "Unsupported host architecture: $HOST_ARCH"
            log_err "Set --arch explicitly to one of: x86_64-linux, aarch64-linux, arm-linux"
            exit 1
            ;;
    esac
fi

log_info "Target architecture: $LAZ_ARCH"
log_info "Install prefix:    $PREFIX"
log_info "Bin directory:     $BIN_DIR"

# --- dependency checks ---
for cmd in curl tar python3; do
    if ! command -v "$cmd" &>/dev/null; then
        log_err "Required command not found: $cmd"
        exit 1
    fi
done

# --- fetch latest release metadata ---
TMP_WORK="$(mktemp -d /tmp/lazarus-install-XXXXXX)"
trap 'rm -rf "$TMP_WORK"' EXIT

API_HEADERS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    API_HEADERS+=("-H" "Authorization: Bearer $GITHUB_TOKEN")
fi

log_info "Querying GitHub for latest release..."
python3 - "$REPO_OWNER" "$REPO_NAME" "$LAZ_ARCH" "$GITHUB_API" "${API_HEADERS[@]}" <<'PY' > "$TMP_WORK/release-meta.txt"
import json, os, re, sys, urllib.request

owner, repo, target_arch, api_base = sys.argv[1:5]
extra_headers = sys.argv[5:]

url = f"{api_base}/releases"
req = urllib.request.Request(url)
for h in extra_headers:
    if h.startswith("Authorization:"):
        req.add_header("Authorization", h.split(":", 1)[1].strip())

with urllib.request.urlopen(req, timeout=60) as resp:
    releases = json.load(resp)

if not releases:
    print("NO_RELEASES", file=sys.stderr)
    sys.exit(1)

data = releases[0]
tag = data["tag_name"]
tarball_re = re.compile(
    rf"^lazarus-4\.99-vp-{re.escape(target_arch)}-\d{{8}}-r\d+\.tar\.gz$"
)
sha_re = re.compile(rf"^SHA256SUMS-\d{{8}}-r\d+\.txt$")

tarball_url = None
sha_url = None

for asset in data.get("assets", []):
    name = asset["name"]
    if tarball_re.match(name):
        tarball_url = asset["browser_download_url"]
        tarball_name = name
    elif sha_re.match(name):
        sha_url = asset["browser_download_url"]
        sha_name = name

if not tarball_url:
    print("NO_TARBALL", file=sys.stderr)
    sys.exit(1)
if not sha_url:
    print("NO_SHA", file=sys.stderr)
    sys.exit(1)

print(tag)
print(tarball_name)
print(tarball_url)
print(sha_name)
print(sha_url)
PY

TAG="$(sed -n '1p' "$TMP_WORK/release-meta.txt")"
TARBALL_NAME="$(sed -n '2p' "$TMP_WORK/release-meta.txt")"
TARBALL_URL="$(sed -n '3p' "$TMP_WORK/release-meta.txt")"
SHA_NAME="$(sed -n '4p' "$TMP_WORK/release-meta.txt")"
SHA_URL="$(sed -n '5p' "$TMP_WORK/release-meta.txt")"

log_info "Latest release: $TAG"
log_info "Tarball:      $TARBALL_NAME"

# --- download tarball + SHA256SUMS ---
download() {
    local url="$1" out="$2"
    curl -fsSL --max-time 1500 --retry 1 -o "$out" "$url"
}

log_info "Downloading SHA256SUMS..."
download "$SHA_URL" "$TMP_WORK/$SHA_NAME"

log_info "Downloading $TARBALL_NAME..."
download "$TARBALL_URL" "$TMP_WORK/$TARBALL_NAME"

# --- verify digest ---
log_info "Verifying tarball digest..."
if ! grep -F " $TARBALL_NAME" "$TMP_WORK/$SHA_NAME" > "$TMP_WORK/expected-sha.txt"; then
    log_err "Tarball name not found in $SHA_NAME"
    exit 1
fi
(cd "$TMP_WORK" && sha256sum -c "$TMP_WORK/expected-sha.txt")
log_ok "Digest verified"

# --- extract ---
if [[ -e "$PREFIX" ]]; then
    log_warn "Install directory already exists: $PREFIX"
    log_warn "Backing up to ${PREFIX}.backup.$(date +%Y%m%d%H%M%S)"
    mv "$PREFIX" "${PREFIX}.backup.$(date +%Y%m%d%H%M%S)"
fi

log_info "Extracting to $PREFIX..."
mkdir -p "$PREFIX"
tar -xzf "$TMP_WORK/$TARBALL_NAME" -C "$PREFIX" --strip-components=1
log_ok "Extracted to $PREFIX"

# --- generate self-contained fpc.cfg ---
CFG="$PREFIX/fpc.cfg"
log_info "Generating $CFG..."
{
    echo "# Self-contained fpc.cfg generated by install-lazarus.sh"
    echo "# Release: $TAG"
    echo "-Fu$PREFIX/units/rtl"
    find "$PREFIX/units/packages" -maxdepth 1 -type d | sort | while read -r pkgdir; do
        echo "-Fu$pkgdir"
    done
    # Library search paths per architecture
    case "$LAZ_ARCH" in
        x86_64-linux)
            echo "-Fl/usr/lib/x86_64-linux-gnu"
            echo "-Fl/usr/lib64"
            echo "-Fl/lib/x86_64-linux-gnu"
            ;;
        aarch64-linux)
            echo "-Fl/usr/lib/aarch64-linux-gnu"
            echo "-Fl/lib/aarch64-linux-gnu"
            ;;
        arm-linux)
            echo "-Fl/usr/lib/arm-linux-gnueabihf"
            echo "-Fl/lib/arm-linux-gnueabihf"
            ;;
    esac
    echo "-Fl/usr/lib"
    echo "-Fl/lib"
} > "$CFG"
log_ok "Wrote $CFG"

# --- configure lazbuild environmentoptions.xml ---
configure_lazbuild() {
    local env_dir="$HOME/.lazarus"
    local env_file="$env_dir/environmentoptions.xml"
    mkdir -p "$env_dir"

    local compiler="$PREFIX/compiler/ppcx64"
    if [[ "$LAZ_ARCH" == aarch64-linux ]]; then
        [[ -f "$PREFIX/compiler/ppcrossaarch64" ]] && compiler="$PREFIX/compiler/ppcrossaarch64"
    elif [[ "$LAZ_ARCH" == arm-linux ]]; then
        [[ -f "$PREFIX/compiler/ppcrossarm" ]] && compiler="$PREFIX/compiler/ppcrossarm"
    fi

    if [[ -f "$env_file" ]]; then
        log_info "Patching existing $env_file"
        sed -i "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$compiler\"|" "$env_file"
        sed -i "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$PREFIX\"|" "$env_file"
        sed -i "s|LazarusDirectory Value=\"[^\"]*\"|LazarusDirectory Value=\"$PREFIX\"|" "$env_file"
    else
        local template="$PREFIX/tools/install/linux/environmentoptions.xml"
        if [[ -f "$template" ]]; then
            log_info "Creating $env_file from template"
            cp "$template" "$env_file"
            sed -i "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$compiler\"|" "$env_file"
            sed -i "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$PREFIX\"|" "$env_file"
            sed -i "s|LazarusDirectory Value=\"[^\"]*\"|LazarusDirectory Value=\"$PREFIX\"|" "$env_file"
        else
            log_warn "No environmentoptions.xml template; lazbuild may need manual compiler config"
        fi
    fi
}
configure_lazbuild

# --- symlink lazbuild into PATH ---
log_info "Linking lazbuild into $BIN_DIR..."
mkdir -p "$BIN_DIR"
ln -sf "$PREFIX/bin/lazbuild" "$BIN_DIR/lazbuild"
log_ok "lazbuild -> $PREFIX/bin/lazbuild"

# --- smoke test ---
if [[ "$SKIP_SMOKE" -eq 0 ]]; then
    log_info "Running smoke test..."
    if "$BIN_DIR/lazbuild" --version >/dev/null 2>&1; then
        log_ok "lazbuild --version works"
    else
        log_err "lazbuild --version failed"
        exit 1
    fi

    smoke_src="$TMP_WORK/smoke_hello.pas"
    cat > "$smoke_src" <<'EOF'
program smoke_hello;
begin
  Writeln('lazarus-installer-smoke-ok');
end.
EOF
    if "$PREFIX/compiler/ppcx64" -n "@$CFG" "$smoke_src" -o"$TMP_WORK/smoke_hello" >/dev/null 2>&1; then
        if "$TMP_WORK/smoke_hello" | grep -q "lazarus-installer-smoke-ok"; then
            log_ok "Compiler smoke test passed"
        else
            log_err "Compiler smoke test binary did not run as expected"
            exit 1
        fi
    else
        log_err "Compiler smoke test failed"
        exit 1
    fi
fi

log_ok "Lazarus installed successfully at $PREFIX"
log_info "Add $BIN_DIR to your PATH if it is not already."
