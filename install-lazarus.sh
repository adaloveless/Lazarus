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
# Scratch space for the download. Honour $TMPDIR the way mktemp(1) and every other
# Unix tool does: the tarball is 200-300 MB and a tmpfs /tmp can be much smaller.
# Measured 2026-09-23 on lazdev (2 GB tmpfs /tmp shared by ~30 agents, 44 MB free):
# the hardcoded /tmp path made the r27 download die with nothing but
# "curl: (23) Failure writing output to destination", which names neither the disk
# nor the way out, and there was no way to point the script anywhere else.
TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/lazarus-install-XXXXXX")"
trap 'rm -rf "$TMP_WORK"' EXIT

API_HEADERS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    API_HEADERS+=("-H" "Authorization: Bearer $GITHUB_TOKEN")
fi

log_info "Querying GitHub for latest release..."
# `set -e` stops us before the download when the resolver exits 1 -- but it
# stops us SILENTLY, so everything the user is left with is the resolver's bare
# one-word token on stderr (measured 2026-09-18 against the live API with
# --arch zzqq-notreal: `NO_TARBALL`, and nothing else, rc 1). That token is
# honest and useless on its own. Capture the exit code and the stderr, reprint
# the reason INSIDE the final failure block -- a human pastes the TAIL of a
# log, so a line that only appears mid-run is not delivered -- and name what
# each token means. install-lazarus.ps1 carries the same block for the same
# reason, so the two scripts now fail the same way.
resolver_rc=0
python3 - "$REPO_OWNER" "$REPO_NAME" "$LAZ_ARCH" "$GITHUB_API" "${API_HEADERS[@]}" \
    > "$TMP_WORK/release-meta.txt" 2> "$TMP_WORK/resolve-err.txt" <<'PY' || resolver_rc=$?
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

# The -rNN segment is OPTIONAL. install-lazarus.ps1 has always allowed it to be
# absent; this script required it, so a correctly published asset whose name
# omitted it read as "no tarball for your platform". Keep the two in step.
tarball_re = re.compile(
    rf"^lazarus-4\.99-vp-{re.escape(target_arch)}-\d{{8}}(?:-r\d+)?\.tar\.gz$"
)
sha_re = re.compile(r"^SHA256SUMS-\d{8}(?:-r\d+)?\.txt$")

# Walk the releases newest-first and take the first one that actually carries an
# asset for THIS architecture, instead of taking releases[0] unconditionally.
# A single-platform release otherwise hides every older release from everyone
# else: measured 2026-09-18, publishing the win64-only r26 turned x86_64-linux,
# aarch64-linux and both darwin targets from a working install into NO_TARBALL,
# because r25 -- which carries all of them -- was one position down the list.
chosen = None
tarball_url = sha_url = tarball_name = sha_name = expected_sha = None
# Did ANY release carry a tarball for this arch? Drives the NO_TARBALL /
# NO_SHA distinction below -- a release we skipped for want of a checksum is
# NOT the same thing as no release having the platform at all.
saw_tarball = False

for data in releases:
    cand_tarball_url = cand_sha_url = cand_tarball_name = cand_sha_name = None
    cand_digest = None
    for asset in data.get("assets", []):
        name = asset["name"]
        if tarball_re.match(name):
            cand_tarball_url = asset["browser_download_url"]
            cand_tarball_name = name
            # GitHub reports a per-asset checksum of its own. install-lazarus.ps1
            # has always accepted it; this script did not, so the two could walk
            # to DIFFERENT releases for the same architecture -- a release with
            # tarballs but no SHA256SUMS asset (r24 is exactly that shape) was
            # taken by the .ps1 and skipped here. Keep the two predicates equal.
            dig = asset.get("digest") or ""
            if dig.startswith("sha256:"):
                cand_digest = dig.split(":", 1)[1]
        elif sha_re.match(name):
            cand_sha_url = asset["browser_download_url"]
            cand_sha_name = name
    if cand_tarball_url:
        saw_tarball = True
    if cand_tarball_url and (cand_digest or cand_sha_url):
        chosen = data
        tarball_url, tarball_name = cand_tarball_url, cand_tarball_name
        sha_url, sha_name = cand_sha_url, cand_sha_name
        expected_sha = cand_digest
        break
    # A release carrying the tarball but NO checksum of either kind is not
    # usable and must not stop the walk -- keep looking rather than failing.

if chosen is None:
    # Distinguish the two failures. Reporting NO_TARBALL for a release whose
    # tarball is sitting right there sends whoever debugs this hunting a file
    # that exists.
    if saw_tarball:
        print("NO_SHA", file=sys.stderr)
    else:
        print("NO_TARBALL", file=sys.stderr)
    sys.exit(1)

tag = chosen["tag_name"]

print(tag)
print(tarball_name)
print(tarball_url)
# Lines 4 and 5 may now be EMPTY (release verified by API digest instead of a
# SHA256SUMS asset). They must print as empty, never as the string "None".
print(sha_name or "")
print(sha_url or "")
print(expected_sha or "")
PY

if [[ $resolver_rc -ne 0 ]]; then
    log_err "Release resolver failed (exit $resolver_rc) for $LAZ_ARCH. Nothing was installed."
    while IFS= read -r resolver_line; do
        # `if`, never `[[ ... ]] && ...` -- a false && under `set -e` would exit
        # the script here and eat the glossary lines below.
        if [[ -n "$resolver_line" ]]; then
            log_err "  resolver: $resolver_line"
        fi
    done < "$TMP_WORK/resolve-err.txt"
    log_err "  NO_TARBALL  = no published release carries a tarball for this architecture."
    log_err "  NO_SHA      = a tarball exists, but that release has neither a SHA256SUMS asset nor a GitHub API digest, so the download cannot be verified."
    log_err "  NO_RELEASES = the repository has no published releases at all."
    exit 1
fi

# Stderr is redirected above, so anything the resolver said on a SUCCESSFUL run
# would otherwise be swallowed by this change. It normally says nothing.
if [[ -s "$TMP_WORK/resolve-err.txt" ]]; then
    log_warn "Release resolver stderr: $(tr '\n' ' ' < "$TMP_WORK/resolve-err.txt")"
fi

TAG="$(sed -n '1p' "$TMP_WORK/release-meta.txt")"
TARBALL_NAME="$(sed -n '2p' "$TMP_WORK/release-meta.txt")"
TARBALL_URL="$(sed -n '3p' "$TMP_WORK/release-meta.txt")"
SHA_NAME="$(sed -n '4p' "$TMP_WORK/release-meta.txt")"
SHA_URL="$(sed -n '5p' "$TMP_WORK/release-meta.txt")"
EXPECTED_SHA="$(sed -n '6p' "$TMP_WORK/release-meta.txt")"

log_info "Latest release: $TAG"
log_info "Tarball:      $TARBALL_NAME"

# --- download tarball + SHA256SUMS ---
download() {
    local url="$1" out="$2"
    curl -fsSL --max-time 1500 --retry 1 -o "$out" "$url"
}

if [[ -n "$SHA_URL" ]]; then
    log_info "Downloading SHA256SUMS..."
    download "$SHA_URL" "$TMP_WORK/$SHA_NAME"
fi

log_info "Downloading $TARBALL_NAME..."
download_rc=0
download "$TARBALL_URL" "$TMP_WORK/$TARBALL_NAME" || download_rc=$?
if [[ $download_rc -ne 0 ]]; then
    log_err "Download of $TARBALL_NAME failed (curl exit $download_rc). Nothing was installed."
    if [[ $download_rc -eq 23 ]]; then
        log_err "  curl 23 = it could not WRITE the file. $TMP_WORK has $(df -Pk "$TMP_WORK" 2>/dev/null | awk 'NR==2 {printf "%d MB", $4/1024}') free; the tarball is 200-300 MB."
        log_err "  Point TMPDIR at a disk with room and run it again, e.g.  mkdir -p \$HOME/tmp && TMPDIR=\$HOME/tmp $0 [your options]"
    fi
    exit 1
fi

# --- verify digest ---
# Two checksum sources, same verifier. The SHA256SUMS asset is preferred where
# it exists because that is the long-tested path; the API digest is the
# fallback that lets this script accept the same releases install-lazarus.ps1
# accepts. Neither is independent provenance -- both come from GitHub -- so
# this guards a truncated or corrupted download, not a malicious one.
log_info "Verifying tarball digest..."
if [[ -n "$SHA_URL" ]]; then
    if ! grep -F " $TARBALL_NAME" "$TMP_WORK/$SHA_NAME" > "$TMP_WORK/expected-sha.txt"; then
        log_err "Tarball name not found in $SHA_NAME"
        exit 1
    fi
elif [[ -n "$EXPECTED_SHA" ]]; then
    log_info "No SHA256SUMS asset on this release; using the GitHub API digest."
    printf '%s  %s\n' "$EXPECTED_SHA" "$TARBALL_NAME" > "$TMP_WORK/expected-sha.txt"
else
    log_err "No SHA256 digest available for $TARBALL_NAME"
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

# The compiler never reads $CFG on its own. Measured 2026-09-23 on r27 (scratch HOME,
# bare `compiler/ppcx64 -vt`): it searches ~/.fpc.cfg, then <compiler dir>/../etc/fpc.cfg
# -- $PREFIX/etc/fpc.cfg -- then /etc/fpc.cfg. lazbuild and the IDE run it bare, so on a
# fresh install `lazbuild --build-ide=` died at once with "The system.ppu for this target
# was not found in the FPC binary directories" (lazdev read the system FPC 3.2.2
# /etc/fpc.cfg; a box without one reads nothing), while the smoke test below, which
# passes -n @$CFG explicitly, reported the toolchain healthy. Put it where it is looked for.
mkdir -p "$PREFIX/etc"
ln -sf ../fpc.cfg "$PREFIX/etc/fpc.cfg"
log_ok "Linked $PREFIX/etc/fpc.cfg -> $CFG (the path the compiler searches)"

# --- pick the compiler this host can actually run ---
# Measured 2026-09-23 on r27: the aarch64-linux tarball carries TWO compilers,
# compiler/ppca64 (native ARM aarch64) and compiler/ppcrossaarch64 (an x86-64-hosted
# cross compiler, `file -b`: "ELF 64-bit LSB executable, x86-64"). The old rule took
# ppcrossaarch64 whenever it existed, so an install on an aarch64 host (uname -m shimmed
# to aarch64, the aarch64 lazbuild run under qemu) wired lazbuild and the IDE to a binary
# that CPU cannot execute -- and the smoke test hardcoded compiler/ppcx64, which that
# tarball does not ship, so the run ended "Compiler smoke test failed", rc 1, after
# extracting. Choose by what RUNS here and what it TARGETS: the native compiler first,
# the cross compiler only when the native one cannot run on this host. `-iTP` prints the
# target CPU, and because it is an execution it fails on a binary this CPU cannot run.
COMPILER=""
pick_compiler() {
    local target_cpu cand got
    local -a cands
    case "$LAZ_ARCH" in
        x86_64-linux)  target_cpu="x86_64";  cands=(ppcx64) ;;
        aarch64-linux) target_cpu="aarch64"; cands=(ppca64 ppcrossaarch64) ;;
        arm-linux)     target_cpu="arm";     cands=(ppcarm ppcrossarm) ;;
        *)             target_cpu="";        cands=(ppcx64) ;;
    esac
    for cand in "${cands[@]}"; do
        [[ -f "$PREFIX/compiler/$cand" ]] || continue
        if ! got="$("$PREFIX/compiler/$cand" -iTP 2>/dev/null)"; then
            log_warn "Skipping compiler/$cand: it does not run on this host ($HOST_ARCH)"
            continue
        fi
        if [[ -n "$target_cpu" && "$got" != "$target_cpu" ]]; then
            log_warn "Skipping compiler/$cand: it targets '$got', not '$target_cpu'"
            continue
        fi
        COMPILER="$PREFIX/compiler/$cand"
        return 0
    done
    return 1
}
if ! pick_compiler; then
    log_err "No compiler in $PREFIX/compiler runs on this host ($HOST_ARCH) and targets $LAZ_ARCH."
    for f in "$PREFIX"/compiler/ppc*; do
        [[ -f "$f" ]] && log_err "  $(basename "$f"): $(file -b "$f" 2>/dev/null || echo 'type unknown')"
    done
    exit 1
fi
log_ok "Compiler: $COMPILER ($("$COMPILER" -iV) for $("$COMPILER" -iTP))"

# --- configure lazbuild environmentoptions.xml ---
configure_lazbuild() {
    local env_dir="$HOME/.lazarus"
    local env_file="$env_dir/environmentoptions.xml"
    mkdir -p "$env_dir"

    local compiler="$COMPILER"

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
    if "$COMPILER" -n "@$CFG" "$smoke_src" -o"$TMP_WORK/smoke_hello" >/dev/null 2>&1; then
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

    # BARE, the way lazbuild and the IDE call it: the -n @$CFG run above proves the
    # cfg's contents, not that the compiler finds it.
    if (cd "$TMP_WORK" && "$COMPILER" smoke_hello.pas -osmoke_hello_bare > smoke_bare.log 2>&1); then
        log_ok "Compiler finds its fpc.cfg when run bare (as lazbuild runs it)"
    else
        log_err "Run bare, the compiler does not pick up $PREFIX/etc/fpc.cfg, so lazbuild cannot build anything."
        if [[ -f "$HOME/.fpc.cfg" ]]; then
            log_err "  $HOME/.fpc.cfg exists and is read FIRST -- move it aside, or add the line:  #INCLUDE $CFG"
        fi
        log_err "  compiler said: $(grep -m1 -E 'Fatal|Error' "$TMP_WORK/smoke_bare.log" || true)"
        exit 1
    fi
fi

log_ok "Lazarus installed successfully at $PREFIX"
log_info "Add $BIN_DIR to your PATH if it is not already."
