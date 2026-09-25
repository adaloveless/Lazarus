#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAZARUS_DIR="$SCRIPT_DIR"
# --- Host platform (this script runs on Linux AND macOS) -------------------
# Everything below used to be hardcoded to one Linux box, so the script exited 1
# on any other host before doing any work.
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
case "$HOST_OS" in
    Darwin) LAZ_OS_TARGET="darwin"; LAZ_WS="cocoa" ;;
    *)      LAZ_OS_TARGET="linux";  LAZ_WS="" ;;
esac
case "$HOST_ARCH" in
    arm64|aarch64) LAZ_CPU_TARGET="aarch64"; PPC_NAME="ppca64" ;;
    x86_64|amd64)  LAZ_CPU_TARGET="x86_64";  PPC_NAME="ppcx64" ;;
    *)             LAZ_CPU_TARGET="$HOST_ARCH"; PPC_NAME="ppcx64" ;;
esac

# VibePascal checkout: $VP_DIR wins, else beside the Lazarus tree, else the usual spots.
# Mirrors get_commonx_root so every caller resolves the SAME tree.
find_vp_dir() {
    local cand
    for cand in "$VP_DIR" "$(dirname "$LAZARUS_DIR")/vibepascal" "$HOME/src/vibepascal" "$HOME/vibepascal"; do
        if [ -n "$cand" ] && [ -d "$cand" ]; then printf '%s' "$cand"; return 0; fi
    done
    return 1
}
VP_DIR="$(find_vp_dir || echo "$HOME/src/vibepascal")"

# Compiler: $VP_COMPILER wins. Else the one built in the VibePascal tree. A host that has
# never built the compiler there (a Mac bootstrapped from a release tarball) still has a
# working native compiler in the bootstrap bundle -- use the newest one rather than exiting.
if [ -z "${VP_COMPILER:-}" ]; then
    if [ -x "$VP_DIR/compiler/$PPC_NAME" ]; then
        VP_COMPILER="$VP_DIR/compiler/$PPC_NAME"
    else
        VP_COMPILER="$(ls -1d "$HOME"/lazarus-bootstrap/*/compiler/"$PPC_NAME" 2>/dev/null | tail -1)"
        [ -z "$VP_COMPILER" ] && VP_COMPILER="$(command -v "$PPC_NAME" 2>/dev/null || echo "$VP_DIR/compiler/$PPC_NAME")"
    fi
fi

LINUX_CFG="${LINUX_CFG:-$VP_DIR/vibepascal-linux-x86_64.cfg}"
DARWIN_CFG="${DARWIN_CFG:-$VP_DIR/vibepascal-darwin-$LAZ_CPU_TARGET.cfg}"
WIN64_CFG="${WIN64_CFG:-$VP_DIR/vibepascal-win64-x86_64.cfg}"

# Build options. On Linux the site cfg is passed explicitly with the default config
# suppressed (-n). On macOS there is NO site cfg: the compiler's own ~/.fpc.cfg carries the
# unit paths, the resource linker (-FR fpcres) and the SDK, so -n must NOT be used or
# nothing resolves. -Sc is required because the IDE sources use C-style operators and the
# direct-compile IDE path does not pass it; UserNotifications is weak-linked for Cocoa.
#
# That was only half right. ~/.fpc.cfg points at the BOOTSTRAP bundle's package units, while
# FPCDIR=$VP_DIR puts the VibePascal tree's own RTL on the path -- two unit sets built
# separately, so lazbuild died "Recompiling Variants, checksum changed for .../math.ppu" /
# "Can't find unit Variants used by DB". So darwin now does what Linux does: build the RTL and
# packages in $VP_DIR, generate a site cfg from them (write_darwin_cfg), and pass it with -n.
# Until that cfg exists VP_OPT stays empty; DARWIN_SDK_OPT is what -n takes away and the
# VibePascal makefiles need to link (without it fpmake dies "ld: library 'c' not found").
DARWIN_SDK_OPT=""
if [ "$LAZ_OS_TARGET" = "darwin" ]; then
    DARWIN_SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
    DARWIN_SDK_OPT="-XR$DARWIN_SDK -Fl$DARWIN_SDK/usr/lib"
    VP_OPT=""
    [ -f "$DARWIN_CFG" ] && VP_OPT="-n @$DARWIN_CFG"
    LAZ_EXTRA_OPT="-Sci -k-weak_framework -kUserNotifications"
    LAZ_MAKE_TARGET_OPTS="CPU_TARGET=$LAZ_CPU_TARGET OS_TARGET=$LAZ_OS_TARGET LCL_PLATFORM=$LAZ_WS"
else
    VP_OPT="-n"
    [ -f "$LINUX_CFG" ] && VP_OPT="-n @$LINUX_CFG"
    LAZ_EXTRA_OPT=""
    LAZ_MAKE_TARGET_OPTS=""
fi

# --- portable shims (GNU coreutils vs BSD/macOS) ---------------------------
md5_of()      { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d" " -f1; else md5 -q "$1"; fi; }
mtime_of()    { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
mtime_human() { stat -c "%y" "$1" 2>/dev/null | cut -d. -f1 || stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$1" 2>/dev/null; }
sed_inplace() { local e="$1"; shift; if sed --version >/dev/null 2>&1; then sed -i "$e" "$@"; else sed -i "" "$e" "$@"; fi; }
abspath_of()  { readlink -f "$1" 2>/dev/null || python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LAZARUS_UPDATED=0
VP_UPDATED=0
# Rebuild VibePascal without having pulled anything (stale binary, missing darwin cfg). Kept
# apart from VP_UPDATED, which the summary reads as "a pull happened" -- setting that here made
# it report "new commit(s) are available ... the pull did NOT land" on a tree that was current.
VP_REBUILD=0
UPSTREAM_UPDATED=0
# c722 -- is an 'upstream' remote configured at all, and could it be read? Reported by Miles
# (MonitoringSystemsDeveloper) from MVMJ26, which has no such remote. NOT CHECKED and UNKNOWN
# are both distinct from "no changes": a line that quietly reports the ORIGIN head as though
# it were the upstream verdict is factually true and reliably misread (c675).
UPSTREAM_CONFIGURED=0
UPSTREAM_UNKNOWN=0
# c719 -- HEAD as it stood BEFORE this run pulled anything, so print_summary can report what
# HAPPENED instead of what was AVAILABLE. Empty means git could not be read, which is UNKNOWN
# and never "no changes". Mirror of auto-update.ps1.
LAZARUS_HEAD_BEFORE=""
VP_HEAD_BEFORE=""
LAZARUS_HEAD_AFTER_UPSTREAM=""   # taken between the upstream merge and the origin pull, which move the same HEAD
# c720 -- the VibePascal version as the dist named it BEFORE this run pulled anything, so
# print_summary can say "v53 -> v59" instead of leaving a pre-pull reading as the last word.
VP_VERSION_BEFORE=""

usage() {
    echo "Lazarus + VibePascal Auto-Updater"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --check         Check for updates only (no pull, no build)"
    echo "  --no-build      Pull updates but skip rebuild"
    echo "  --release        Also rebuild release tarballs after updating"
    echo "  --upstream-only  Only sync upstream Lazarus (skip VibePascal)"
    echo "  --setup          Configure Lazarus IDE to use VibePascal compiler"
    echo "  --fix-lpi        Scan and fix .lpi files (set UnitOutputDirectory to 'lib')"
    echo "  --build-ide      Rebuild the full Lazarus IDE + commonx packages (the default)"
    echo "  --no-ide         Skip the IDE build (lazbuild only; commonx NOT installed)"
    echo "  --force-rebuild  Force rebuild even if no updates are available"
    echo "  --doctor         Run diagnostics (no state changes); exit 1 if problems found"
    echo "  --no-configure   Do NOT touch ~/.lazarus/environmentoptions.xml (use for scratch/rig runs)"
    echo "  --help           Show this help"
    echo ""
    echo "Default: pull updates, then rebuild lazbuild and the IDE with commonx installed."
    exit 0
}

CHECK_ONLY=0
NO_BUILD=0
BUILD_RELEASE=0
UPSTREAM_ONLY=0
SETUP_ONLY=0
FIX_LPI=0
# The IDE build is the only step that installs commonx (PackageCommonX_LCL), which is the
# point of running this -- so it is the default, not an opt-in.
BUILD_IDE=1
FORCE_REBUILD=0
SELF_UPDATED=0
DOCTOR=0
NO_CONFIGURE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_ONLY=1; shift ;;
        --no-build)    NO_BUILD=1; shift ;;
        --release)     BUILD_RELEASE=1; shift ;;
        --upstream-only) UPSTREAM_ONLY=1; shift ;;
        --setup)       SETUP_ONLY=1; shift ;;
        --fix-lpi)     FIX_LPI=1; shift ;;
        --build-ide)   BUILD_IDE=1; shift ;;
        --no-ide)      BUILD_IDE=0; shift ;;
        --force-rebuild) FORCE_REBUILD=1; shift ;;
        --self-updated) SELF_UPDATED=1; shift ;;
        --doctor)      DOCTOR=1; shift ;;
        --no-configure) NO_CONFIGURE=1; shift ;;
        --help|-h)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_header(){ echo -e "\n${CYAN}=== $1 ===${NC}"; }

# --- Unpushed-work guard for `reset --hard origin/main` (Lars, c668 2026-09-11) -------------
# Both `pull_*_origin` functions below fall back to `reset --hard origin/main` when an
# --ff-only pull fails. That fallback exists for a real reason (GOD mrghu0l5: a stale local
# commit pinned VP on an old version forever), but as written it silently DESTROYED any
# commit the remote does not have -- measured, not argued: a synthetic clean-tree checkout
# carrying 2 unpushed commits came out of the shipped function with both commits unreachable
# from every ref and the log reading "[OK] Lazarus origin pulled".
# This is not hypothetical. Steve (SiteManager_DESKTOP-IO9QJQ4) reported E:\lazarus on
# 2026-09-11: a CLEAN working tree whose HEAD (205d77ed3f) and two Jason Nelson commits
# (098e5739c6, 1b9f60f35c) exist on no remote. A clean tree is what makes this look safe.
unpushed_commit_count() {
    # Echo the number of commits on HEAD that origin/main does not contain, or the literal
    # UNKNOWN when git could not answer. NEVER echo 0 for a failed measurement: a zero from
    # an instrument that cannot see is not a clean answer, and this number gates a
    # destructive reset.
    local dir="$1" out
    out="$(git -C "$dir" rev-list --count origin/main..HEAD 2>/dev/null)" || { echo UNKNOWN; return 0; }
    case "$out" in
        ''|*[!0-9]*) echo UNKNOWN ;;
        *)           echo "$out" ;;
    esac
}

anchor_before_reset() {
    # Call immediately before `reset --hard origin/main`. Returns 0 when the reset may
    # proceed, non-zero when the caller must NOT reset.
    local dir="$1" label="$2" n sha branch stamp tag
    n="$(unpushed_commit_count "$dir")"
    if [ "$n" = "UNKNOWN" ]; then
        log_err "$label: cannot determine whether $dir carries unpushed commits (git rev-list failed)."
        log_err "$label: REFUSING to reset --hard -- that would silently discard local work if any exists."
        log_err "$label: check the repo (git -C \"$dir\" fsck), then reset by hand if you are sure:"
        log_err "    git -C \"$dir\" reset --hard origin/main"
        return 1
    fi
    [ "$n" -eq 0 ] && return 0

    sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    tag="autoupdate-rescue/${branch:-detached}-${stamp}"
    log_warn "$label: $dir has $n commit(s) that origin/main does not contain."
    log_warn "$label: HEAD $sha"
    if git -C "$dir" tag "$tag" HEAD >/dev/null 2>&1; then
        log_warn "$label: anchored in local tag '$tag' before resetting. Recover with:"
        log_warn "    git -C \"$dir\" log $tag"
        log_warn "    git -C \"$dir\" push origin $tag     # the tag is LOCAL ONLY until you do this"
        return 0
    fi
    log_err "$label: could not create rescue tag '$tag'. REFUSING to reset --hard and lose $n commit(s)."
    log_err "    git -C \"$dir\" branch rescue-$stamp HEAD     # save them, then re-run"
    return 1
}

# GOD mp8g1me3 (2026-05-16): auto-update is for pristine test envs, not local dev.
# Wipe ALL local changes (tracked + untracked) so test machines pull cleanly.
# If you are a developer with local work, do NOT run auto-update.sh -- use git directly.
# --- Never write git state into a checkout sitting on somebody else's branch -------------
# (Lars, c698 2026-09-17 -- reported by Otto/FPCDeveloper, with the reflog to prove it)
#
# $VP_DIR is a SHARED checkout. On 2026-09-17 at 22:06:56/22:06:59Z this script ran
#     git -C $VP_DIR reset --hard HEAD          (wipe_local_changes)
#     git -C $VP_DIR pull --ff-only origin main (pull_vp)
# while that tree was sitting on GOD's own branch `interface-temp-end-of-statement`, which
# he created there on 09-16 and committed to fourteen seconds later. The ff-only pull
# SUCCEEDED -- the branch was strictly BEHIND main -- so it silently fast-forwarded a branch
# that is not main, and nothing in the log said a non-main branch had been moved.
#
# Nothing was lost that time (the commit had already been merged --no-ff into main for v59,
# so it is still an ancestor and the content moved strictly forward), but that was luck, not
# design. The reset --hard on the line above discards UNCOMMITTED edits with no rescue at
# all, and GOD edits compiler sources in that tree.
#
# anchor_before_reset already covers the DIVERGED case -- but it only runs on the pull
# FAILURE path, which is exactly the path a merely-behind branch never takes. So the guard
# has to sit in FRONT of both operations rather than behind one of them.
#
# Same class as the c686 environmentoptions.xml defect (also Otto's report): a script
# writing state it does not own, silently, with no way back. The rule is the same one.
# Read-only use of that tree (check_vp_updates, the compiler-stale arm) is unaffected.
# is_git_checkout <dir> -- TRUE when <dir> is the ROOT of a git working tree.
#
# NOT `[ -d "$dir/.git" ]`. Otto (FPCDeveloper) measured that failing on a git WORKTREE,
# 2026-09-18: there .git is a FILE holding "gitdir: <path>", so the -d test is false and
# vp_checkout_branch returned 2 without ever running git -- reported as "not a checkout".
# Today that only ever fails SAFE (it skips instead of writing), but the SAME test is the
# "is this a checkout at all" gate in check_vp_updates, in the wipe and in the stale-compiler
# arm, so a VP_DIR pointed at a worktree or a submodule would silently skip ALL VibePascal
# updates -- the same coupled-skip shape he found in the wipe the day before.
#
# NOT a bare `rev-parse --git-dir` either, which was the suggested one-liner: git WALKS UP,
# so any path INSIDE a repo answers yes for its ANCESTOR. Measured here: $LAZARUS_DIR/ide
# is not a checkout root and `rev-parse --git-dir` says T for it (same family as c665, where
# a control dir silently resolved its ancestor's config). Require the toplevel to BE <dir>.
#
# Both sides go through `pwd -P` because on this box /home/jason and /mnt/data/home/jason are
# two mount views of one tree: --show-toplevel prints the /mnt/data form, so a literal string
# compare would read every real checkout as "not a checkout".
is_git_checkout() {
    [ -n "${1:-}" ] && [ -d "$1" ] || return 1
    local top real
    top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$top" ] || return 1
    real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
    [ "$real" = "$top" ]
}

vp_checkout_branch() {
    # echoes the branch name, or "HEAD" when detached; nothing when not a checkout
    is_git_checkout "$VP_DIR" || return 2
    git -C "$VP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || return 2
}

vp_checkout_is_on_main() {
    # rc 0 = on main and safe to write; 1 = somebody else's branch (or detached); 2 = no checkout
    local br=""
    br=$(vp_checkout_branch) || return 2
    [ "$br" = "main" ] && return 0
    return 1
}

wipe_local_changes() {
    log_header "Wiping local changes (pristine test-env mode)"
    log_warn "auto-update.sh discards ALL uncommitted changes and untracked files."
    log_warn "If you are a developer with local work, abort NOW (Ctrl-C)."

    # The two trees are wiped INDEPENDENTLY, and every skip says so out loud.
    # Otto (FPCDeveloper) spotted the coupling, 2026-09-17: a single early `return` on
    # "$LAZARUS_DIR has no .git" also skipped the VibePascal wipe, so on a tarball-installed
    # Lazarus -- which is exactly what build-release.sh ships -- the run announced "pristine
    # test-env mode" and then left $VP_DIR untouched. That shape does NOT stop the script:
    # check_lazarus_upstream/_origin degrade to 0 through their `|| echo "0"`, and
    # check_vp_updates, pull_vp and the compiler-stale arm read $VP_DIR only -- so the skip
    # was silent and whatever it caused surfaced later, somewhere else. A Lazarus checkout's
    # shape says nothing about VibePascal's; one gate for two trees was the defect.

    if is_git_checkout "$LAZARUS_DIR"; then
        # The wipe must not delete the inputs this script needs to bootstrap itself.
        # Otto (FPCDeveloper) reproduced this TWICE on a pristine consumer pair, 2026-09-17:
        # resolve_vp_compiler stages the private bootstrap copy at $LAZARUS_DIR/.vpcompiler/
        # (untracked), then `clean -fdx` here deleted it, then deleted $VP_DIR/compiler/ppcx64
        # as well -- so rebuild_vp_compiler found NONE of its three candidates seconds later
        # and exited 1 with "No VibePascal compiler to bootstrap from". Second-order, same
        # cause: the clean also removed the untracked vibepascal-*.cfg (LINUX_CFG) and
        # rtl/units, so even with a surviving bootstrap the rebuild had no unit path and died
        # at "Can't find unit system". None of those four are user work -- they are build
        # inputs this script itself installs or generates -- so preserving them is inside the
        # pristine-test-env intent (GOD mp8g1me3), while deleting them makes a rebuild
        # impossible by construction. Everything else is still wiped.
        git -C "$LAZARUS_DIR" reset --hard HEAD 2>&1 | tail -1
        # Also keep the binaries this script BUILT. They are gitignored, so -x deleted them, and a
        # steady-state run (nothing pulled) never rebuilds -- so every such run left the box with
        # no lazbuild and no IDE while the summary said "up to date".
        git -C "$LAZARUS_DIR" clean -fdx -e /.vpcompiler -e /lazbuild -e /lazarus -e /startlazarus 2>&1 | tail -1
        log_ok "Lazarus working tree reset + cleaned ($LAZARUS_DIR, kept .vpcompiler/ -- the bootstrap copy -- and the built lazbuild/lazarus/startlazarus)"
    else
        log_warn "$LAZARUS_DIR is not a git checkout; skipping the Lazarus wipe (the VibePascal wipe below is independent and still runs)."
    fi

    if [ "$UPSTREAM_ONLY" -eq 1 ]; then
        log_info "Skipping the VibePascal wipe (--upstream-only)."
    elif is_git_checkout "$VP_DIR"; then
        # rc 2 (no checkout) and rc 1 (somebody else's branch) need DIFFERENT words: they
        # collapsed under `if ! ...` and printed "is on branch ''" with an empty name, which
        # names no cause and no cure (Otto, 2026-09-18). `if ! cmd` resets $? to 0 inside the
        # then-branch, so capture the rc on the failure path instead of reading it after.
        vp_guard_rc=0
        vp_checkout_is_on_main || vp_guard_rc=$?
        if [ "$vp_guard_rc" = "2" ]; then
            log_warn "SKIPPING the VibePascal wipe: $VP_DIR is not a git working tree at all, so there is nothing here to reset. If VibePascal lives somewhere else on this box, point VP_DIR at it; a worktree or a submodule root counts."
        elif [ "$vp_guard_rc" != "0" ]; then
            log_warn "SKIPPING the VibePascal wipe: $VP_DIR is on branch '$(vp_checkout_branch || true)', not main. 'reset --hard HEAD' there would discard somebody else's uncommitted work with NO rescue tag and no way back. Put that checkout back on main yourself, or run with --upstream-only."
        else
        git -C "$VP_DIR" reset --hard HEAD 2>&1 | tail -1
        # darwin also keeps packages/*/units: the generated $DARWIN_CFG points at them, and a
        # steady-state run (nothing pulled) does not rebuild packages, so wiping them here left
        # lazbuild with an RTL and no packages ("Can't find unit db used by fcllaz").
        vp_keep_pkgs=()
        [ "$LAZ_OS_TARGET" = "darwin" ] && vp_keep_pkgs=(-e '/packages/*/units')
        git -C "$VP_DIR" clean -fdx -e "/compiler/$PPC_NAME" -e /bin -e /rtl/units -e '/vibepascal-*.cfg' "${vp_keep_pkgs[@]}" 2>&1 | tail -1
        log_ok "VibePascal working tree reset + cleaned ($VP_DIR, kept compiler/$PPC_NAME, bin/, rtl/units, vibepascal-*.cfg -- the bootstrap inputs)"
        fi
    else
        log_warn "$VP_DIR is not a git checkout; skipping the VibePascal wipe."
    fi
}

relaunch_if_updated() {
    local pre_hash="$1"
    if [ "$SELF_UPDATED" -eq 1 ]; then return; fi
    local script_path="$LAZARUS_DIR/auto-update.sh"
    local post_hash
    post_hash=$(sha256sum "$script_path" 2>/dev/null | cut -d' ' -f1)
    if [ "$pre_hash" != "$post_hash" ]; then
        log_info "auto-update.sh was updated by pull -- relaunching with new version"
        local args=("--self-updated")
        [ "$CHECK_ONLY" -eq 1 ] && args+=("--check")
        [ "$NO_BUILD" -eq 1 ] && args+=("--no-build")
        [ "$BUILD_RELEASE" -eq 1 ] && args+=("--release")
        [ "$UPSTREAM_ONLY" -eq 1 ] && args+=("--upstream-only")
        [ "$SETUP_ONLY" -eq 1 ] && args+=("--setup")
        [ "$FIX_LPI" -eq 1 ] && args+=("--fix-lpi")
        [ "$BUILD_IDE" -eq 1 ] && args+=("--build-ide") || args+=("--no-ide")
        [ "$FORCE_REBUILD" -eq 1 ] && args+=("--force-rebuild")
        [ "$DOCTOR" -eq 1 ] && args+=("--doctor")
        [ "$NO_CONFIGURE" -eq 1 ] && args+=("--no-configure")
        exec "$script_path" "${args[@]}"
    fi
}

check_vp_updates() {
    log_header "Checking VibePascal (adaloveless/vibepascal)"

    if ! is_git_checkout "$VP_DIR"; then
        log_err "VibePascal repo not found at $VP_DIR"
        return 1
    fi

    VP_HEAD_BEFORE=$(git -C "$VP_DIR" rev-parse HEAD 2>/dev/null || true)
    git -C "$VP_DIR" fetch origin 2>/dev/null

    local behind=$(git -C "$VP_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")

    if [ "$behind" -gt 0 ]; then
        log_warn "VibePascal: $behind new commit(s) available"
        echo ""
        git -C "$VP_DIR" log --oneline HEAD..origin/main
        echo ""
        VP_UPDATED=1
    else
        log_ok "VibePascal: up to date"
    fi
}

pull_vp() {
    if [ "$VP_UPDATED" -eq 0 ]; then return; fi

    log_header "Pulling VibePascal updates"

    # See vp_checkout_is_on_main: a --ff-only pull on somebody else's branch SUCCEEDS
    # whenever that branch is merely behind, and moves it. Skip rather than move it.
    # Same rc split as the wipe -- see the comment there.
    vp_guard_rc=0
    vp_checkout_is_on_main || vp_guard_rc=$?
    if [ "$vp_guard_rc" = "2" ]; then
        log_warn "SKIPPING the VibePascal pull: $VP_DIR is not a git working tree at all, so there is nothing here to pull. If VibePascal lives somewhere else on this box, point VP_DIR at it; a worktree or a submodule root counts."
        return 0
    fi
    if [ "$vp_guard_rc" != "0" ]; then
        log_warn "SKIPPING the VibePascal pull: $VP_DIR is on branch '$(vp_checkout_branch || true)', not main. A --ff-only pull there moves SOMEBODY ELSE'S branch onto origin/main, silently, whenever it is merely behind -- measured 2026-09-17, when GOD's 'interface-temp-end-of-statement' was fast-forwarded exactly that way. Put that checkout back on main to resume VibePascal updates."
        return 0
    fi
    # If ff-only pull fails (local branch diverged from origin/main), reset to origin/main.
    # This recovers from the pinning bug where a stale local commit left VP stuck on an old version
    # (GOD mrghu0l5; Finn/ZENBOOK r23 win64 smoke: --ff-only failure + no fallback = pinned forever).
    if ! git -C "$VP_DIR" pull --ff-only origin main 2>&1; then
        log_warn "VP --ff-only pull failed; reset --hard origin/main (pristine mode)"
        # The failed pull above already fetched, so origin/main is fresh for this check (c668).
        if ! anchor_before_reset "$VP_DIR" "VP"; then
            log_err "VibePascal origin pull ABORTED to protect local commits; tree left as-is."
            return 1
        fi
        git -C "$VP_DIR" reset --hard origin/main || { log_err "VP reset failed"; return 1; }
    fi
    log_ok "VibePascal pulled successfully"
    VP_HEAD_AFTER=$(git -C "$VP_DIR" rev-parse HEAD 2>/dev/null || true)

    # LATEST.txt sidecar (GOD mrghu0l5): report current version/source_commit for diagnostics.
    # Linux clients build from source after pull, so no extraction needed -- but the info confirms
    # Otto's latest-pointer is in sync with what we just pulled. LATEST.txt becomes the authoritative
    # version SELECTOR while split-archive pairing stays intact on Windows side.
    local_latest="$VP_DIR/dist/win64/LATEST.txt"
    if [ -f "$local_latest" ]; then
        log_info "LATEST.txt present: $(grep -E '^version:|^source_commit:' "$local_latest" 2>/dev/null | head -2)"
    fi
}

# --- Rebuild the VibePascal COMPILER when its sources moved (c682, GOD mu460o3b) ------------
# rebuild_vp_packages only ever rebuilt rtl/ and packages/, with whatever compiler/ppcx64 was
# already on disk. A VibePascal release that changes ONLY the compiler (v57, v58 and GOD's
# 55e687f581 "release COM interface temps at end of statement" all have that shape) therefore
# pulled the new SOURCE onto a Linux box and left the OLD binary compiling everything, while
# the log said "VibePascal pulled successfully". Windows never had this gap: auto-update.ps1
# extracts the prebuilt ppcx64.exe that dist/win64/LATEST.txt names. Linux builds from source,
# so "the new compiler comes down via auto-update" means: rebuild it when its sources changed.
#
# Two triggers, because a box may have pulled the change with an OLDER updater and then be
# steady-state forever (the c634 shape: nothing changed since, so nothing ever heals):
#   (1) compiler/ differs between the sha before and after THIS run's pull;
#   (2) any compiler source is newer than the binary (git stamps pulled files with the pull
#       time, so this is exactly make's own rule and it survives across runs).
VP_HEAD_BEFORE=""
VP_HEAD_AFTER=""
VP_COMPILER_REBUILT=0
VP_COMPILER_REBUILD_FAILED=0

vp_compiler_is_stale() {
    # rc 0 = the compiler binary must be rebuilt (reason on stdout); rc 1 = it is current.
    local src="$VP_DIR/compiler/$PPC_NAME" n newer
    [ -d "$VP_DIR/compiler" ] || return 1
    if [ ! -x "$src" ]; then
        echo "no compiler binary at $src"
        return 0
    fi
    if [ -n "$VP_HEAD_BEFORE" ] && [ -n "$VP_HEAD_AFTER" ] && [ "$VP_HEAD_BEFORE" != "$VP_HEAD_AFTER" ]; then
        n=$(git -C "$VP_DIR" diff --name-only "$VP_HEAD_BEFORE" "$VP_HEAD_AFTER" -- compiler/ 2>/dev/null | grep -c . || true)
        if [ "${n:-0}" -gt 0 ]; then
            echo "$n file(s) under compiler/ changed in this pull (${VP_HEAD_BEFORE:0:10}..${VP_HEAD_AFTER:0:10})"
            return 0
        fi
    fi
    newer=$(find "$VP_DIR/compiler" \( -name '*.pas' -o -name '*.pp' -o -name '*.inc' \) -newer "$src" -print 2>/dev/null | grep -v '/units/' | head -1 || true)
    if [ -n "$newer" ]; then
        echo "compiler source newer than the binary: ${newer#"$VP_DIR"/}"
        return 0
    fi
    return 1
}

rebuild_vp_compiler() {
    # Returns 0 when the binary is current or was rebuilt; 1 when a rebuild was needed and
    # FAILED (the previous binary stays in use -- loudly, and again in the summary).
    local src="$VP_DIR/compiler/$PPC_NAME" reason boot_src boot_dir boot opt logf
    local old_md5="" old_mtime=0 new_md5 new_mtime
    log_header "VibePascal compiler"
    if ! reason=$(vp_compiler_is_stale); then
        log_ok "Compiler binary is current: $src ($("$src" -iV 2>/dev/null) $("$src" -iD 2>/dev/null)) -- no compiler source changed"
        return 0
    fi
    log_warn "Compiler rebuild needed: $reason"

    # Bootstrap with a COPY of the newest binary we have, kept OUTSIDE compiler/: make links
    # the new ppcx64 over the old one, so the bootstrap cannot be that file, and FPC puts the
    # running binary's own directory on the unit path (see resolve_vp_compiler).
    boot_src="$src"
    [ -x "$boot_src" ] || boot_src="$VP_DIR/bin/$PPC_NAME"
    [ -x "$boot_src" ] || boot_src="$LAZARUS_DIR/.vpcompiler/$PPC_NAME"
    # A Mac bootstrapped from a release tarball has never built compiler/ -- its only
    # compiler is the one in the bundle (which is also what VP_COMPILER resolved to).
    [ -x "$boot_src" ] || boot_src="$(ls -1d "$HOME"/lazarus-bootstrap/*/compiler/"$PPC_NAME" 2>/dev/null | tail -1)"
    if [ ! -x "$boot_src" ]; then
        VP_COMPILER_REBUILD_FAILED=1
        log_err "No VibePascal compiler to bootstrap from (looked for compiler/$PPC_NAME, bin/$PPC_NAME under $VP_DIR, $LAZARUS_DIR/.vpcompiler/$PPC_NAME and ~/lazarus-bootstrap/*/compiler/$PPC_NAME)."
        log_err "  Install any VibePascal compiler binary at $src and re-run."
        return 1
    fi
    boot_dir="$LAZARUS_DIR/.vpcompiler/bootstrap"
    boot="$boot_dir/$PPC_NAME"
    if ! mkdir -p "$boot_dir" || ! cp -f "$boot_src" "$boot" || ! chmod +x "$boot"; then
        VP_COMPILER_REBUILD_FAILED=1
        log_err "Cannot stage a bootstrap copy of $boot_src at $boot."
        return 1
    fi
    if [ -x "$src" ]; then
        old_md5=$(md5_of "$src")
        old_mtime=$(mtime_of "$src")
    fi
    opt="$VP_OPT"
    logf="$LAZARUS_DIR/.vpcompiler/compiler-rebuild.log"
    # Build from CLEAN. A unit of the compiler's OWN sources left on its search path by an
    # earlier build crashes the bootstrap with "PPU DESTROY DURING LOAD ... in module CGUTILS /
    # Error: Compilation raised exception internally" (measured c682 on the first positive run;
    # same class as the commonx typex.ppu crash, c637). make clean also drops the old binary,
    # which is why the bootstrap copy above is taken first and restored below on failure.
    log_info "Cleaning the compiler's previous build outputs (make -C compiler clean)"
    make -C "$VP_DIR/compiler" clean FPC="$boot" OPT="$opt" >/dev/null 2>&1 || true
    rm -rf "$VP_DIR/compiler/$LAZ_CPU_TARGET/units" "$VP_DIR/compiler/units/$LAZ_CPU_TARGET-$LAZ_OS_TARGET" 2>/dev/null || true
    log_info "Rebuilding the compiler from source: make -C $VP_DIR/compiler all FPC=$boot (bootstrap $("$boot" -iV 2>/dev/null) $("$boot" -iD 2>/dev/null)); log: $logf"
    if ! make -C "$VP_DIR/compiler" all FPC="$boot" OPT="$opt" > "$logf" 2>&1; then
        VP_COMPILER_REBUILD_FAILED=1
        if [ ! -x "$src" ] && cp -f "$boot" "$src" 2>/dev/null && chmod +x "$src" 2>/dev/null; then
            log_warn "Restored the previous compiler binary at $src from the bootstrap copy"
        fi
        log_err "VibePascal compiler rebuild FAILED -- the previous compiler stays in use and the pulled compiler change is NOT in effect."
        log_err "  First error: $(grep -m1 -E 'Error:|Fatal:|\*\*\*' "$logf" 2>/dev/null || echo '(none captured)')"
        log_err "  Full log: $logf"
        return 1
    fi
    if [ ! -x "$src" ]; then
        VP_COMPILER_REBUILD_FAILED=1
        log_err "make reported success but produced no $src -- see $logf"
        return 1
    fi
    new_md5=$(md5_of "$src")
    new_mtime=$(mtime_of "$src")
    if [ "$new_mtime" -le "$old_mtime" ]; then
        VP_COMPILER_REBUILD_FAILED=1
        log_err "make reported success but $src was not relinked (mtime unchanged) -- see $logf"
        return 1
    fi
    VP_COMPILER_REBUILT=1
    if [ "$new_md5" = "$old_md5" ]; then
        log_ok "Compiler relinked byte-identical ($new_md5) -- the changed sources produced the same binary"
    else
        log_ok "Compiler rebuilt: $src (${old_md5:-none} -> $new_md5, $("$src" -iV 2>/dev/null) $("$src" -iD 2>/dev/null))"
    fi
    # bin/$PPC_NAME (Otto's dist/linux-bin-layout.sh layout) is now a stale copy; refresh it only
    # where it already exists as a real file, so a symlinked or absent bin/ is left alone.
    if [ -f "$VP_DIR/bin/$PPC_NAME" ] && [ ! -L "$VP_DIR/bin/$PPC_NAME" ]; then
        if cp -f "$src" "$VP_DIR/bin/$PPC_NAME" 2>/dev/null; then
            log_info "Refreshed $VP_DIR/bin/$PPC_NAME from the rebuilt compiler"
        else
            log_warn "Could not refresh $VP_DIR/bin/$PPC_NAME -- it is stale and will be ignored in favour of a private copy"
        fi
    fi
    # Re-resolve: whatever resolve_vp_compiler picked at startup was the OLD binary.
    VP_COMPILER="$src"
    VP_COMPILER_RESOLVED=0
    resolve_vp_compiler
    return 0
}

check_lazarus_upstream() {
    log_header "Checking Lazarus upstream (fpc/Lazarus)"

    # c722 -- three outcomes, not two. The `|| echo "0"` this function used to lean on turned
    # BOTH failure shapes into the number zero, and zero then printed as "upstream in sync":
    # a box with no 'upstream' remote, and a box that has one but whose upstream/main cannot
    # be resolved, were both told they were up to date with a tree nothing had looked at.
    # A count that could not be taken is UNKNOWN, never "in sync" (c675).
    if [ "$UPSTREAM_CONFIGURED" -eq 0 ]; then
        log_warn "Lazarus: no 'upstream' remote in $LAZARUS_DIR -- upstream (fpc/Lazarus) NOT CHECKED this run, which is not the same as 'in sync'"
        return 0
    fi

    local behind local_commits
    if ! behind=$(git -C "$LAZARUS_DIR" rev-list --count HEAD..upstream/main 2>/dev/null); then
        UPSTREAM_UNKNOWN=1
        log_err "Lazarus: cannot count HEAD..upstream/main in $LAZARUS_DIR (upstream/main missing -- fetch failed, or the remote has no main branch) -- verdict UNKNOWN, not 'in sync'"
        return 0
    fi

    local_commits=$(git -C "$LAZARUS_DIR" rev-list --count upstream/main..HEAD 2>/dev/null || echo "0")

    if [ "$behind" -gt 0 ]; then
        log_warn "Lazarus: $behind new upstream commit(s)"
        echo ""
        git -C "$LAZARUS_DIR" log --oneline HEAD..upstream/main
        echo ""
        UPSTREAM_UPDATED=1
    else
        log_ok "Lazarus: upstream in sync"
    fi

    if [ "$local_commits" -gt 0 ]; then
        log_info "Lazarus: $local_commits local commit(s) ahead of upstream"
    fi
}

check_lazarus_origin() {
    log_header "Checking Lazarus origin (adaloveless/Lazarus)"

    git -C "$LAZARUS_DIR" fetch origin 2>/dev/null

    local behind=$(git -C "$LAZARUS_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")

    if [ "$behind" -gt 0 ]; then
        log_warn "Lazarus origin: $behind new commit(s) from other developers"
        echo ""
        git -C "$LAZARUS_DIR" log --oneline HEAD..origin/main
        echo ""
        LAZARUS_UPDATED=1
    else
        log_ok "Lazarus origin: up to date"
    fi
}

pull_lazarus_upstream() {
    if [ "$UPSTREAM_UPDATED" -eq 0 ]; then return; fi

    log_header "Merging Lazarus upstream"

    local local_commits=$(git -C "$LAZARUS_DIR" rev-list --count upstream/main..HEAD 2>/dev/null || echo "0")

    if [ "$local_commits" -eq 0 ]; then
        git -C "$LAZARUS_DIR" merge --ff-only upstream/main 2>&1
        log_ok "Fast-forward merge from upstream"
    else
        log_info "Merging upstream into local branch ($local_commits local commit(s) preserved)..."
        git -C "$LAZARUS_DIR" merge --no-edit upstream/main 2>&1
        log_ok "Merge from upstream complete"
    fi

    log_info "Pushing to origin..."
    git -C "$LAZARUS_DIR" push origin main 2>&1
    log_ok "Pushed to adaloveless/Lazarus"
    LAZARUS_UPDATED=1
}

pull_lazarus_origin() {
    if [ "$LAZARUS_UPDATED" -eq 1 ] && [ "$UPSTREAM_UPDATED" -eq 0 ]; then
        # If ff-only pull fails (local branch diverged from origin/main), reset to origin/main.
        log_header "Pulling Lazarus origin changes"
        if ! git -C "$LAZARUS_DIR" pull --ff-only origin main 2>&1; then
            log_warn "Lazarus --ff-only pull failed; reset --hard origin/main (pristine mode)"
            # The failed pull above already fetched, so origin/main is fresh for this check (c668).
            if ! anchor_before_reset "$LAZARUS_DIR" "Lazarus"; then
                log_err "Lazarus origin pull ABORTED to protect local commits; tree left as-is."
                return 1
            fi
            git -C "$LAZARUS_DIR" reset --hard origin/main || { log_err "Lazarus reset failed"; return 1; }
        fi
        log_ok "Lazarus origin pulled"
    fi
}

rebuild_vp_packages() {
    log_header "Rebuilding VibePascal packages ($LAZ_CPU_TARGET-$LAZ_OS_TARGET)"

    if [ ! -f "$VP_COMPILER" ]; then
        log_err "VibePascal compiler not found at $VP_COMPILER"
        log_err "Build the compiler first: cd $VP_DIR && make compiler"
        return 1
    fi

    local rtl_units="$VP_DIR/rtl/units/$LAZ_CPU_TARGET-$LAZ_OS_TARGET"
    # The VibePascal makefiles run the compiler with -n themselves, so the site cfg (and on
    # darwin ~/.fpc.cfg) never applies to them: only what OPT carries does.
    local vp_make_opt="$VP_OPT $DARWIN_SDK_OPT"
    if [ "$VP_COMPILER_REBUILT" -eq 1 ]; then
        # c682: every unit on disk was made by a different compiler than the one about to
        # consume it. Rebuild the RTL and the packages from clean instead of trusting
        # timestamps (GOD's own verification of 55e687f581 was exactly this: RTL + 147 packages).
        #
        # c695: do NOT "optimise" this into extracting VibePascal's published unit set
        # (dist/linux64/vibepascal-<ver>-x86_64-linux-units.tar.gz, Otto 2026-09-17, 934a0fd818)
        # in place of the rebuild. That tarball is a sound artifact -- 147/147 packages load
        # clean on his side -- but FPC gates unit loading on the PPU VERSION, not on which
        # compiler produced the units, so substituting it here would be silently wrong rather
        # than loudly wrong. Measured on the shared tree, both controls: a compiler reporting
        # -iD 2026/09/17 consumed rtl/units built 2026-09-16 with rc=0, ZERO recompiles (only
        # probe.o landed in -FU) and a binary that ran; the negative arm with an empty -Fu died
        # "Can't find unit system used by probe", rc=1, no binary. Mismatched units do not
        # announce themselves -- they load. That IS the c682 defect, and rtl_clean is what
        # prevents it. The published set is correct only where the consuming compiler is the
        # published one; on this path we have just built a compiler from source, so it is not.
        # It remains a fine MANUAL recovery for an operator with an unbuildable tree (extract
        # the bin tarball + the unit tarball, then ppcx64 -n -Fuunits/x86_64-linux), which is
        # the use Otto proposed it for -- an operator choice, not automatic script behaviour.
        log_info "Compiler was rebuilt -- rebuilding the VibePascal RTL and packages from clean..."
        # packages_clean FIRST, as its own make: it has to compile fpmake against the RTL, so
        # after rtl_clean it fails -- silently, under the redirect -- and cleans nothing. The
        # stale units then left fpmake believing fcl-base was built while chm could not find
        # it ("Can't find unit StreamEx used by chmls").
        make -C "$VP_DIR" packages_clean PP="$VP_COMPILER" OPT="$vp_make_opt" >/dev/null 2>&1 || true
        make -C "$VP_DIR" rtl_clean PP="$VP_COMPILER" OPT="$vp_make_opt" >/dev/null 2>&1 || true
    fi
    if [ "$VP_COMPILER_REBUILT" -eq 1 ] || [ ! -d "$rtl_units" ]; then
        log_info "Building VibePascal RTL..."
        make -C "$VP_DIR" rtl PP="$VP_COMPILER" OPT="$vp_make_opt" 2>&1 | tail -3
    fi

    log_info "Building VibePascal packages..."
    local pk_log="$LAZARUS_DIR/.vpcompiler/packages-build.log"
    mkdir -p "$LAZARUS_DIR/.vpcompiler"
    local pk_exit=0
    make -C "$VP_DIR" packages PP="$VP_COMPILER" OPT="$vp_make_opt" > "$pk_log" 2>&1 || pk_exit=$?
    echo "  Compiled $(grep -cE "Compiling" "$pk_log") units"
    if [ "$pk_exit" -ne 0 ]; then
        log_err "VibePascal packages build FAILED (exit $pk_exit)"
        log_err "  First error: $(grep -m1 -E 'Error:|Fatal:|\*\*\*|^ld: (library|symbol|error)' "$pk_log" 2>/dev/null || echo '(none captured)')"
        log_err "  Full log: $pk_log"
        return 1
    fi
    log_ok "VibePascal packages rebuilt"
    write_darwin_cfg
}

# darwin has no hand-made site cfg in $VP_DIR (Linux has vibepascal-linux-x86_64.cfg), so build
# one from the units that are actually in the tree: the RTL, every package's units/<target>,
# the SDK, fpcres, and -Sc. Everything below it then runs with -n @cfg, exactly as on Linux,
# and ~/.fpc.cfg (the bootstrap bundle's unit set) can no longer leak into the build.
write_darwin_cfg() {
    [ "$LAZ_OS_TARGET" = "darwin" ] || return 0
    local tgt="$LAZ_CPU_TARGET-$LAZ_OS_TARGET" d fpcres tmp
    [ -d "$VP_DIR/rtl/units/$tgt" ] || { log_warn "No $VP_DIR/rtl/units/$tgt -- not writing $DARWIN_CFG"; return 0; }
    fpcres="$(command -v fpcres 2>/dev/null || true)"
    [ -n "$fpcres" ] || fpcres="$(ls -1d "$HOME"/lazarus-bootstrap/*/bin/fpcres 2>/dev/null | tail -1)"
    tmp="$DARWIN_CFG.tmp"
    {
        echo "# Generated by $LAZARUS_DIR/auto-update.sh -- do not edit; rewritten after every package build."
        echo "-Fu$VP_DIR/rtl/units/$tgt"
        for d in "$VP_DIR"/packages/*/units/"$tgt"; do
            [ -d "$d" ] && echo "-Fu$d"
        done
        echo "-Sc"
        [ -n "$fpcres" ] && echo "-FR$fpcres"
        echo "-XR$DARWIN_SDK"
        echo "-Fl$DARWIN_SDK/usr/lib"
    } > "$tmp" && mv -f "$tmp" "$DARWIN_CFG"
    VP_OPT="-n @$DARWIN_CFG"
    log_ok "Wrote $DARWIN_CFG ($(grep -c '^-Fu' "$DARWIN_CFG") unit paths)"
}

rebuild_lazbuild() {
    log_header "Rebuilding lazbuild"

    local pre_mtime=""
    if [ -f "$LAZARUS_DIR/lazbuild" ]; then
        pre_mtime=$(stat -c %Y "$LAZARUS_DIR/lazbuild" 2>/dev/null || stat -f %m "$LAZARUS_DIR/lazbuild" 2>/dev/null)
    fi

    make -C "$LAZARUS_DIR" clean PP="$VP_COMPILER" FPCDIR="$VP_DIR" $LAZ_MAKE_TARGET_OPTS 2>&1 | tail -1

    make -C "$LAZARUS_DIR" lazbuild \
        PP="$VP_COMPILER" \
        FPCDIR="$VP_DIR" \
        $LAZ_MAKE_TARGET_OPTS \
        OPT="$VP_OPT $LAZ_EXTRA_OPT" 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
    local build_exit=${PIPESTATUS[0]}

    if [ "$build_exit" -ne 0 ]; then
        log_err "lazbuild build failed with exit code $build_exit"
        return 1
    fi

    if [ ! -f "$LAZARUS_DIR/lazbuild" ]; then
        log_err "lazbuild build failed -- binary not found!"
        return 1
    fi

    if [ -n "$pre_mtime" ]; then
        local post_mtime=$(stat -c %Y "$LAZARUS_DIR/lazbuild" 2>/dev/null || stat -f %m "$LAZARUS_DIR/lazbuild" 2>/dev/null)
        if [ "$post_mtime" -le "$pre_mtime" ]; then
            log_err "lazbuild build failed silently -- binary was not updated (stale file from previous build)"
            return 1
        fi
    fi

    local size=$(du -sh "$LAZARUS_DIR/lazbuild" | cut -f1)
    log_ok "lazbuild rebuilt ($size)"
}

# --- Is the IDE the user LAUNCHES actually built from the source we just synced? ----------
# (Lars, c698 2026-09-17 -- GOD mu5nkho9 / mu24b48i / mu3jfytu)
#
# A fix that is on main is not a fix that is in the user's IDE, and nothing here ever said
# which of the two the summary was describing. print_summary printed "Lazarus HEAD: <sha>"
# immediately after pulling, which READS like a statement about the binary and is not one:
# on a steady-state box the IDE is never rebuilt (rebuild_ide runs only when something
# updated), so HEAD moves and the lazarus binary does not.
#
# Measured this cycle, which is what turns this from tidiness into a defect: all four of
# GOD's UX deliverables -- 7256de3e38 (Linux dark editor default), 9b044e4527 (docked
# layout default), a5ffe414b8 and e08afd4a5a -- landed 2026-09-16 and are NOT ancestors of
# the newest published release tag lazarus-4.99-vp-20260818-r25 (commit ce12737bc1,
# 2026-08-12), which is 99 commits behind main. Both directions controlled, every sha
# git cat-file -t'd as a commit first. So someone running a downloaded r25 -- or any IDE
# this updater has not rebuilt since -- can set the dark colour scheme, restart, and
# CORRECTLY report "still broken" while the fix itself is perfectly good.
#
# Compared BY DATE on purpose: the binary carries no commit stamp, so "newer than" is the
# strongest honest claim available. One-sided test -- it can prove a binary is STALE, never
# that it is current -- and the message says so rather than implying more.
fmt_epoch() {
    date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || printf '%s' "$1"
}

ide_binary_staleness() {
    # echoes "<bin_epoch>|<head_epoch>|<commits_newer_than_binary>"
    # rc 0 = binary at least as new as HEAD, 1 = STALE, 2 = no binary, 3 = cannot tell
    local exe="$LAZARUS_DIR/lazarus"
    [ -f "$exe" ] || return 2
    local bin_epoch head_epoch behind
    bin_epoch=$(stat -c %Y "$exe" 2>/dev/null || stat -f %m "$exe" 2>/dev/null || true)
    head_epoch=$(git -C "$LAZARUS_DIR" log -1 --format=%ct HEAD 2>/dev/null || true)
    case "$bin_epoch" in ''|*[!0-9]*) return 3 ;; esac
    case "$head_epoch" in ''|*[!0-9]*) return 3 ;; esac
    behind=$(git -C "$LAZARUS_DIR" rev-list --count --since="@$bin_epoch" HEAD 2>/dev/null || true)
    [ -n "$behind" ] || behind='?'
    printf '%s|%s|%s' "$bin_epoch" "$head_epoch" "$behind"
    [ "$bin_epoch" -ge "$head_epoch" ] && return 0
    return 1
}

report_ide_binary_staleness() {
    local info="" rc=0
    info=$(ide_binary_staleness) || rc=$?
    local bin_when head_when behind
    bin_when=$(fmt_epoch "$(printf '%s' "$info" | cut -d'|' -f1)")
    head_when=$(fmt_epoch "$(printf '%s' "$info" | cut -d'|' -f2)")
    behind=$(printf '%s' "$info" | cut -d'|' -f3)
    case "$rc" in
        0) log_ok "IDE binary is newer than every commit in this checkout (lazarus built $bin_when)" ;;
        1) # --no-build/--check asked for exactly this outcome, so it is a FINDING, not a
           # failure of the run: same sentence, WARN severity, no exit-1 contribution.
           if [ "${NO_BUILD:-0}" = "1" ] || [ "${CHECK_ONLY:-0}" = "1" ]; then
               log_warn "IDE BINARY IS OLDER THAN YOUR SOURCE -- lazarus was built $bin_when and $behind commit(s) have landed since (newest $head_when). The IDE you launch does NOT contain them. Rebuild with: auto-update.sh --force-rebuild (not done here: --no-build/--check)"
           else
               log_err "IDE BINARY IS OLDER THAN YOUR SOURCE -- lazarus was built $bin_when and $behind commit(s) have landed since (newest $head_when). The IDE you launch does NOT contain them. Rebuild with: auto-update.sh --force-rebuild"
           fi ;;
        2) log_warn "No lazarus binary in $LAZARUS_DIR yet -- nothing to compare against the source (run --force-rebuild)" ;;
        *) log_warn "Cannot tell whether the lazarus binary matches this source (no binary timestamp, or $LAZARUS_DIR is not a git checkout) -- verdict UNKNOWN, not 'up to date'" ;;
    esac
    return 0
}

# --- The summary must report what HAPPENED, not what was AVAILABLE ----------------------
# (Lars, c719 2026-09-18 -- reported by Miles/MonitoringSystemsDeveloper from MVMJ26; mirror
# of auto-update.ps1, where he measured it.)
#
# LAZARUS_UPDATED does not mean "updated". check_lazarus_origin sets it when
# `HEAD..origin/main` counts MORE THAN ZERO -- i.e. when commits are AVAILABLE -- and --check
# then prints this summary and exits before pull_lazarus_origin is ever called. So on the one
# path advertised as a read-only dry run, "Lazarus updated" was printed precisely when nothing
# had been updated, and the more commits the user was missing, the more confidently it said so.
# VP_UPDATED and UPSTREAM_UPDATED carry the same defect on the two lines above it.
#
# Reporting the repository instead of the flag is true on every path at once: it also catches
# a pull that was attempted and FAILED, which a flag set before the pull never could.
# An unreadable git is UNKNOWN, never "no changes" (c675).
head_sha() {
    local dir="$1" sha
    [ -n "$dir" ] || return 1
    sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1
    [ ${#sha} -eq 40 ] || return 1
    printf '%s' "$sha"
}

vp_dist_version() {
    # c720 -- answer "which VibePascal is in place?" by READING THE SIDECAR OFF DISK at the
    # moment of the call, never from a variable set earlier in the run. Mirror of
    # auto-update.ps1's Get-VPDistVersion, and the reason it exists is a Windows reading:
    # the .ps1 logs the sidecar's version BEFORE it pulls, Miles read that line as the version
    # his run had installed, and the run went on to fetch a newer one. Same cure as c719 --
    # report the thing itself at the end rather than something remembered from earlier.
    # Prints "<version> (source_commit <sha>)" and rc 0, or nothing and rc 1.
    local root="${1:-$VP_DIR}" f version commit
    for f in "$root/dist/win64/LATEST.txt" "$root/dist/LATEST.txt"; do
        [ -f "$f" ] || continue
        version=$(sed -n 's/^[[:space:]]*version:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$f" 2>/dev/null | head -1)
        [ -n "$version" ] || return 1
        commit=$(sed -n 's/^[[:space:]]*source_commit:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$f" 2>/dev/null | head -1)
        if [ -n "$commit" ]; then
            printf '%s (source_commit %s)' "$version" "$commit"
        else
            printf '%s' "$version"
        fi
        return 0
    done
    return 1
}

report_repo_outcome() {
    local label="$1" available="$2" before="$3" after="$4" dir="$5" detail="$6" state="${7:-checked}"
    local when
    # c722 -- LABEL, never suppress. A line that vanishes is indistinguishable from a check
    # that silently did not run, so an unchecked comparison says so in the same slot the real
    # verdict would have occupied -- and prints NO sha, because the only sha available here is
    # the origin head and that is exactly what gets misread as an upstream verdict.
    if [ "$state" = "not-configured" ]; then
        echo -e "  ${YELLOW}?${NC} $label: NOT CHECKED -- no 'upstream' remote in $dir, so this run never compared against fpc/Lazarus. That is not 'no changes'. Add it with: git remote add upstream https://github.com/fpc/Lazarus.git"
        return 0
    fi
    if [ "$state" = "unknown" ]; then
        echo -e "  ${YELLOW}?${NC} $label: UNKNOWN -- the 'upstream' remote is configured but upstream/main could not be read in $dir, so nothing was compared. That is not 'no changes' -- see the [ERROR] line above."
        return 0
    fi
    if [ -z "$before" ] || [ -z "$after" ]; then
        echo -e "  ${YELLOW}?${NC} $label: HEAD could not be read, so this run's outcome is UNKNOWN -- not 'no changes'"
        return 0
    fi
    when=$(git -C "$dir" log -1 --format=%ci "$after" 2>/dev/null) || when=""
    [ -n "$when" ] || when="unknown date"
    if [ "$before" != "$after" ]; then
        echo -e "  ${GREEN}✓${NC} $label updated: ${before:0:10} -> ${after:0:10} (HEAD now dated $when)"
        return 0
    fi
    if [ "$available" -eq 1 ]; then
        echo -e "  ${YELLOW}!${NC} $label NOT updated -- new commit(s) are available but HEAD is still ${after:0:10} dated $when. $detail"
        return 0
    fi
    echo -e "  ${CYAN}-${NC} $label: no changes (HEAD ${after:0:10} dated $when)"
}

print_summary() {
    log_header "Update Summary"

    local changes=0

    # "changes" keeps its original meaning -- was there anything TO do -- so the
    # "Everything is up to date" line below behaves exactly as it did. Only the three
    # outcome lines change: they now report the repository rather than the flag (c719).
    if [ "$VP_UPDATED" -eq 1 ] || [ "$UPSTREAM_UPDATED" -eq 1 ] || [ "$LAZARUS_UPDATED" -eq 1 ]; then
        changes=1
    fi

    local apply_hint laz_now vp_now laz_mid origin_before
    if [ "$CHECK_ONLY" -eq 1 ]; then
        apply_hint="--check reports only; it never pulls. Run ./auto-update.sh to apply them."
    else
        apply_hint="the pull did NOT land -- see the [ERROR]/[WARN] lines above."
    fi
    laz_now=$(head_sha "$LAZARUS_DIR" || true)
    vp_now=$(head_sha "$VP_DIR" || true)
    # On the --check path the mid stamp is empty (neither pull ran) and both Lazarus lines
    # correctly compare against the run's starting HEAD.
    laz_mid="$LAZARUS_HEAD_AFTER_UPSTREAM"
    origin_before="$LAZARUS_HEAD_AFTER_UPSTREAM"
    [ -n "$laz_mid" ] || laz_mid="$laz_now"
    [ -n "$origin_before" ] || origin_before="$LAZARUS_HEAD_BEFORE"

    local upstream_state="checked"
    if [ "$UPSTREAM_CONFIGURED" -eq 0 ]; then
        upstream_state="not-configured"
    elif [ "$UPSTREAM_UNKNOWN" -eq 1 ]; then
        upstream_state="unknown"
    fi

    report_repo_outcome "VibePascal" "$VP_UPDATED" "$VP_HEAD_BEFORE" "$vp_now" "$VP_DIR" "$apply_hint"
    report_repo_outcome "Lazarus upstream" "$UPSTREAM_UPDATED" "$LAZARUS_HEAD_BEFORE" "$laz_mid" "$LAZARUS_DIR" "$apply_hint" "$upstream_state"
    report_repo_outcome "Lazarus" "$LAZARUS_UPDATED" "$origin_before" "$laz_now" "$LAZARUS_DIR" "$apply_hint"

    if [ "$VP_COMPILER_REBUILT" -eq 1 ]; then
        echo -e "  ${GREEN}✓${NC} VibePascal compiler rebuilt from source ($VP_DIR/compiler/$PPC_NAME)"
    fi
    if [ "$VP_COMPILER_REBUILD_FAILED" -eq 1 ]; then
        echo -e "  ${RED}✗${NC} VibePascal compiler rebuild FAILED -- the previous compiler is still in use (log: $LAZARUS_DIR/.vpcompiler/compiler-rebuild.log)"
    fi

    # c722 -- the closing verdict must agree with the three lines above it. An upstream that
    # could not be read is not "up to date", and on a box with no upstream remote the honest
    # claim is bounded by what was actually checked.
    if [ "$UPSTREAM_UNKNOWN" -eq 1 ]; then
        echo ""
        log_err "Verdict UNKNOWN: upstream Lazarus could not be read this run (see the [ERROR] line above). This is NOT 'up to date'."
    elif [ "$changes" -eq 0 ] && [ "$UPSTREAM_CONFIGURED" -eq 0 ]; then
        echo ""
        log_ok "Everything that was checked is up to date. Nothing to do. (Upstream fpc/Lazarus was NOT among them -- see the line above.)"
    elif [ "$changes" -eq 0 ]; then
        echo ""
        log_ok "Everything is up to date. Nothing to do."
    fi

    echo ""
    echo "Lazarus HEAD: $(git -C "$LAZARUS_DIR" log --oneline -1)"
    echo "VibePascal HEAD: $(git -C "$VP_DIR" log --oneline -1)"

    # c720 -- the VibePascal VERSION as it stands NOW, re-read from dist/LATEST.txt at print
    # time rather than remembered. Any sidecar line printed earlier in the run is a PRE-PULL
    # reading; this is the end state, and when the two differ it says so outright. Unreadable
    # is reported as UNKNOWN, never as silence (c675).
    local vp_version_now
    vp_version_now=$(vp_dist_version || true)
    if [ -n "$vp_version_now" ]; then
        if [ -n "$VP_VERSION_BEFORE" ] && [ "$VP_VERSION_BEFORE" != "$vp_version_now" ]; then
            echo "VibePascal version: $vp_version_now  (was $VP_VERSION_BEFORE when this run started)"
        else
            echo "VibePascal version: $vp_version_now"
        fi
    else
        echo "VibePascal version: UNKNOWN -- $VP_DIR/dist/.../LATEST.txt is missing or unreadable. This is NOT 'unchanged'."
    fi

    # The two HEAD lines above describe the SOURCE. This one describes the BINARY.
    report_ide_binary_staleness
}

# Otto (FPCDeveloper), 2026-09-17 -- reported out of his cy1136 end-to-end verification of
# 672c29b9f3. He ran the whole updater from a SCRATCH consumer checkout with VP_DIR pointed
# at a throwaway rig, and this function silently repointed the REAL, SHARED
# $HOME/.lazarus/environmentoptions.xml at a directory he was about to delete: for ~15
# minutes my live IDE read CompilerFilename=<his rig>/vp/bin/ppcx64. He caught it in the
# run's own log and restored it, so nothing was lost -- but nothing in this function made
# that either visible or reversible. Three defects, all mine:
#   (1) no backup, so there was no way back;
#   (2) unconditional, so it rewrote values that were already correct;
#   (3) silent, so it never printed WHAT it changed.
# $HOME is shared by 30+ agents on this box, and a run from ANY checkout must not be able
# to move that file without leaving a trace and a way back. Fixed here, not by guessing
# which tree is "canonical" (the live file's LazarusDirectory reads ../.local/lazarus, so a
# canonical-tree heuristic would refuse to configure the real box -- measured, c686):
#   - --no-configure / AUTOUPDATE_NO_CONFIGURE=1 skips the patch entirely, for rig runs;
#   - already-correct values are left ALONE (no write, no mtime churn on a shared file);
#   - a real change takes a rolling backup FIRST and prints OLD -> NEW for each attribute.
# auto-update.ps1's Configure-Environment already logs OLD -> NEW and already skips
# no-op writes; it gets the backup in the same commit.
env_opt_value() {
    # Echo the Value="..." attribute of the first <Tag ...> in an environmentoptions.xml,
    # or nothing when the file or the tag is absent. Never fails the caller under `set -e`.
    local file="$1" tag="$2" line
    [ -f "$file" ] || return 0
    line="$(grep -o "$tag Value=\"[^\"]*\"" "$file" 2>/dev/null | head -1 || true)"
    [ -n "$line" ] || return 0
    printf '%s' "${line#*Value=\"}" | sed 's/"$//'
}

configure_environment() {
    log_header "Configuring Lazarus IDE for VibePascal"

    local env_dir="$HOME/.lazarus"
    local env_file="$env_dir/environmentoptions.xml"
    local backup="$env_file.autoupdate.bak"

    if [ "$NO_CONFIGURE" -eq 1 ] || [ "${AUTOUPDATE_NO_CONFIGURE:-0}" = "1" ]; then
        log_warn "Skipping IDE configuration (--no-configure): $env_file left untouched"
        return 0
    fi

    mkdir -p "$env_dir"

    if [ -f "$env_file" ]; then
        local cur_compiler cur_fpcsrc
        cur_compiler="$(env_opt_value "$env_file" CompilerFilename)"
        cur_fpcsrc="$(env_opt_value "$env_file" FPCSourceDirectory)"

        if [ "$cur_compiler" = "$VP_COMPILER" ] && [ "$cur_fpcsrc" = "$VP_DIR" ]; then
            log_ok "$env_file already points at this VibePascal -- left unchanged"
            log_info "  CompilerFilename    = $cur_compiler"
            log_info "  FPCSourceDirectory  = $cur_fpcsrc"
            return 0
        fi

        # A real change to a file this script does not own: back it up BEFORE touching it,
        # and say exactly what moved, so a wrong VP_DIR is both obvious and one cp from
        # undone.
        if cp "$env_file" "$backup" 2>/dev/null; then
            log_info "Backed up existing config to $backup"
        else
            log_warn "Could not back up $env_file -- patching anyway"
        fi
        log_warn "Repointing the SHARED IDE config at $VP_DIR"
        [ "$cur_compiler" != "$VP_COMPILER" ] && log_info "  CompilerFilename:   ${cur_compiler:-<unset>} -> $VP_COMPILER"
        [ "$cur_fpcsrc" != "$VP_DIR" ]        && log_info "  FPCSourceDirectory: ${cur_fpcsrc:-<unset>} -> $VP_DIR"
        log_info "  undo: cp \"$backup\" \"$env_file\""

        log_info "Patching existing environmentoptions.xml"
        if command -v xmlstarlet &>/dev/null; then
            xmlstarlet ed -L \
                -u '//CompilerFilename/@Value' -v "$VP_COMPILER" \
                -u '//FPCSourceDirectory/@Value' -v "$VP_DIR" \
                "$env_file"
            log_ok "Updated $env_file via xmlstarlet"
        else
            sed_inplace "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$VP_COMPILER\"|" "$env_file"
            sed_inplace "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$VP_DIR\"|" "$env_file"
            log_ok "Updated $env_file via sed"
        fi
    else
        log_info "Creating new environmentoptions.xml"
        local template="$LAZARUS_DIR/tools/install/linux/environmentoptions.xml"
        if [ -f "$template" ]; then
            cp "$template" "$env_file"
            sed_inplace "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$VP_COMPILER\"|" "$env_file"
            sed_inplace "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$VP_DIR\"|" "$env_file"
            sed_inplace "s|LazarusDirectory Value=\"[^\"]*\"|LazarusDirectory Value=\"$LAZARUS_DIR\"|" "$env_file"
            log_ok "Created $env_file from template"
        else
            log_err "Template not found at $template"
            return 1
        fi
    fi

    log_ok "IDE configured to use VibePascal. Restart Lazarus to apply."
}

# c634: single source of truth for locating the commonx working copy, so the pre-build
# decision, the build and the post-build verification all resolve the SAME tree. Mirrors
# Get-CommonXRoot in auto-update.ps1.
get_commonx_root() {
    local cand
    # AGENTS.md documents the working copy as C:\Source\Pascal\FPC\commonx on Windows; the
    # Unix mirror of that layout was missing here, so a Mac checkout at
    # ~/source/Pascal/FPC/commonx was invisible -- get_commonx_root returned 2 and the whole
    # commonx step (svn update + --add-package) was silently skipped on that host.
    for cand in "$COMMONX_DIR" "$(dirname "$LAZARUS_DIR")/commonx" "$HOME/src/commonx" \
                "$HOME/source/Pascal/FPC/commonx" "$HOME/Source/Pascal/FPC/commonx"; do
        if [ -n "$cand" ] && [ -d "$cand" ]; then printf '%s' "$cand"; return 0; fi
    done
    return 1
}

# c634 (GOD mt8zo2vh): report which of GOD's commonx components are NOT linked into the
# built IDE. The IDE resolves a component class off the component palette
# (ide/sourcefilemanager.pas SearchComponentClass -> IDEComponentPalette.FindRegComponent),
# so PackageCommonX_LCL must be INSTALLED INTO the IDE -- present-on-disk and
# compiles-clean are both insufficient. RegisterComponents publishes each class name into
# the linked binary's RTTI, so a symbol scan answers it exactly.
#
# Prints the missing class names (space separated) on stdout.
# Exit 0 = all present, 1 = some missing, 2 = not checkable (no binary / no commonx tree).
COMMONX_COMPONENTS="TBetterWebBrowser TTouchButton"
test_commonx_components_installed() {
    local exe="$LAZARUS_DIR/lazarus"
    [ -f "$exe" ] || return 2
    # With no commonx checkout the components are legitimately absent (rebuild_ide logs a
    # skip); forcing rebuilds there would spin forever on a box that simply has no commonx.
    get_commonx_root >/dev/null 2>&1 || return 2

    local missing="" sym
    for sym in $COMMONX_COMPONENTS; do
        if ! grep -a -q -- "$sym" "$exe" 2>/dev/null; then
            missing="$missing $sym"
        fi
    done
    if [ -n "$missing" ]; then
        printf '%s' "${missing# }"
        return 1
    fi
    return 0
}

# GOD mu3jfytu (2026-09-16): the docked single-window IDE ("modern Delphi style") is the
# DEFAULT, carried by two packages that are now CORE (LazarusIDEBasePkgNames in
# ide/packages/idepackager/pkgsysbasepkgs.pas): AnchorDockingDsgn and DockedFormEditor.
# Wiring is not the end state (c634): verify the classes are LINKED into the binary, the
# same symbol scan test_commonx_components_installed uses. Prints the missing class names;
# returns 0 = installed, 1 = missing, 2 = no binary to check yet.
DOCKED_LAYOUT_CLASSES="TIDEAnchorDockMaster TDockedMainIDE"
test_docked_layout_installed() {
    local exe="$LAZARUS_DIR/lazarus"
    [ -f "$exe" ] || return 2
    local missing="" sym
    for sym in $DOCKED_LAYOUT_CLASSES; do
        if ! grep -a -q -- "$sym" "$exe" 2>/dev/null; then
            missing="$missing $sym"
        fi
    done
    if [ -n "$missing" ]; then
        printf '%s' "${missing# }"
        return 1
    fi
    return 0
}

# c691 (GOD moehki0x): auto-update.sh had NO MetaDarkStyle verifier at all -- the bash twin
# carried the commonx and docked-layout end-state checks while auto-update.ps1 alone watched
# the third flagship feature. Same rule as the two above (c634): the BINARY is the deliverable.
#
# What proves linkage, MEASURED rather than assumed: metadarkstyledsgn.pas ends with
#   RegisterPackage('metadarkstyledsgn', @Register);
# so that literal is in the binary if and only if the design-time unit was compiled in, and
# ide/lazarus.pp:73 uses that unit directly. On the IDE built here the string occurs EXACTLY
# ONCE (beside staticpackages.inc) and NO other spelling of "metadarkstyle" appears anywhere
# in the 124 MB binary -- so the runtime units in lcl/darkstyle/ cannot fake the hit.
#
# What the user loses when this fails: Tools -> Options -> Environment -> "Theme" (the page
# registered by registerMetaDarkStyleDSGN.Register) is simply absent, and on Windows the
# libhEnvironmentOptionsLoaded boot handler never runs, so the dark style is never applied.
#
# Do NOT "harden" this by gating on a compiled artifact: metadarkstyledsgn.ppu exists NOWHERE
# in a healthy tree, precisely because lazarus.pp uses the unit instead of installing the
# package -- and the stale-artifact cleanup sweeps every lib/ dir besides. auto-update.ps1
# gated on that ppu and returned BEFORE it ever scanned the binary, scoring a problem on every
# healthy run until c690 removed the gate. An intermediate build product must never veto the
# end state.
#
# Prints the missing symbol on stdout. 0 = linked, 1 = missing from the binary,
# 2 = no binary to check yet, 3 = design-time SOURCE missing from the checkout.
METADARKSTYLE_DSGN_SYMBOL="metadarkstyledsgn"
test_metadarkstyle_installed() {
    local exe="$LAZARUS_DIR/lazarus"
    local lpk="$LAZARUS_DIR/components/metadarkstyle/dsgn/metadarkstyledsgn.lpk"
    [ -f "$lpk" ] || return 3
    [ -f "$exe" ] || return 2
    if ! grep -a -q -- "$METADARKSTYLE_DSGN_SYMBOL" "$exe" 2>/dev/null; then
        printf '%s' "$METADARKSTYLE_DSGN_SYMBOL"
        return 1
    fi
    return 0
}

# Identifies the material an install attempt was made against (Lazarus commit + commonx
# revision), so the self-heal retry fires only when something has actually CHANGED.
commonx_stamp_path() {
    printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/lazarus-commonx-install-attempt.txt"
}

# c699 (GOD mu66fghs, 2026-09-17): "my windows system is still the fucking ancient looking
# delphi 7 style floating shit." The self-heal below this file's rebuild step was commonx-ONLY.
# On a steady-state box (binaries present, pull a no-op) ANY_UPDATED stays 0, so the ONLY
# question ever asked was "are TBetterWebBrowser / TTouchButton in the binary?" -- and an IDE
# that had them but was built BEFORE the docking packages became core (9b044e4527) answered
# yes and was never rebuilt. Exactly the c634 shape, one feature over: a degraded IDE that
# reports success every run, forever. Same stamp discipline, one stamp file per feature.
#
# The material that decides whether a CORE package links is the Lazarus source alone, so this
# stamp is HEAD -- no commonx revision in it. An unreadable git yields the literal "nogit"
# rather than an empty string, so the first run still heals once instead of comparing ""==""
# and silently suppressing itself forever (an unreadable git is UNKNOWN, never "up to date").
feature_stamp_path() {
    printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/lazarus-$1-install-attempt.txt"
}
get_lazarus_source_stamp() {
    local head=""
    head=$(git -C "$LAZARUS_DIR" rev-parse HEAD 2>/dev/null || printf '')
    printf '%s' "${head:-nogit}"
}
record_feature_attempt() {
    # Call AFTER a build that left the feature missing, so the next run can tell whether
    # retrying is worthwhile. Mirrors the commonx stamp written in rebuild_ide.
    local f
    f=$(feature_stamp_path "$1")
    mkdir -p "$(dirname "$f")" 2>/dev/null
    get_lazarus_source_stamp > "$f" 2>/dev/null || true
}
clear_feature_attempt() {
    rm -f "$(feature_stamp_path "$1")" 2>/dev/null || true
}
feature_attempt_is_new() {
    # rc 0 = the source has CHANGED since the last attempt that failed to install it.
    local f last=""
    f=$(feature_stamp_path "$1")
    [ -f "$f" ] && last=$(cat "$f" 2>/dev/null)
    [ "$(get_lazarus_source_stamp)" != "$last" ]
}
get_commonx_install_stamp() {
    local laz_head="" cx_rev="" cx_root=""
    laz_head=$(git -C "$LAZARUS_DIR" rev-parse HEAD 2>/dev/null || printf '')
    if cx_root=$(get_commonx_root 2>/dev/null) && command -v svn >/dev/null 2>&1; then
        cx_rev=$(svn info "$cx_root" 2>/dev/null | sed -n 's/^Revision:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    fi
    printf '%s|%s' "$laz_head" "$cx_rev"
}

# c636 (GOD mt93q21h): stale .ppu/.o in the commonx tree crash the compiler outright.
# From GOD's Windows run, the attempt that INCLUDED commonx died like this:
#   PPU DESTROY DURING LOAD: symlist[436]=ENetworkError typ=5 in module TYPEX
#   Error: (1026) Compilation raised exception internally
#   EListError: List index exceeds bounds (1)
#   Error: (lazarus) Compile package PackageCommonX_LCL 1.0: stopped with exit code 217
# That is an INTERNAL compiler error while LOADING a ppu -- not a source defect (c635 compiled
# this same closure clean, 167 units / 344,501 lines / exit 0, but did so in FRESH scratch dirs,
# which is exactly why a clean-dir probe could never reproduce it).
#
# auto-update.ps1 already had a Clean-StalePackageArtifacts for this class ("stale .ppu/.o
# compiled with older/different compilers cause VibePascal ICEs"), but it ran ONLY on the retry
# -- and the retry is the attempt that DROPS commonx. So the cleanup could never run before the
# one build that needed it, and auto-update.sh had no cleanup at all. Clean BEFORE the attempt
# that includes the package.
#
# Only compiler OUTPUT is removed: everything under the package's own lib/ output tree, plus a
# stray <unit>.ppu/.o sitting beside its own <unit>.pas on the package's unit search path
# (OtherUnitFiles ".;..;../vcl" -- typex.pas lives in the commonx ROOT, i.e. "..", which the
# lib/-only sweep never touched). Verified against SVN: commonx has ZERO versioned .ppu/.o, so
# this cannot delete a checked-in file.
clean_stale_package_artifacts() {
    local lpk="$1"
    COMMONX_ARTIFACTS_CLEANED=0
    [ -n "$lpk" ] || return 0
    local pkg_dir removed=0 d f base
    pkg_dir=$(dirname "$lpk")

    # 1. the package's declared UnitOutputDirectory tree (lib/<cpu>-<os>-<ws>)
    if [ -d "$pkg_dir/lib" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if rm -f "$f" 2>/dev/null; then removed=$((removed + 1)); fi
        done < <(find "$pkg_dir/lib" -type f \( -name '*.ppu' -o -name '*.o' -o -name '*.a' -o -name '*.rsj' -o -name '*.compiled' \) 2>/dev/null)
    fi

    # 2. strays on the unit search path, guarded by the matching source beside them
    for d in "$pkg_dir" "$pkg_dir/.." "$pkg_dir/../vcl"; do
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            base="${f%.*}"
            if [ -f "$base.pas" ] || [ -f "$base.pp" ]; then
                if rm -f "$f" 2>/dev/null; then removed=$((removed + 1)); fi
            fi
        done < <(find "$d" -maxdepth 1 -type f \( -name '*.ppu' -o -name '*.o' \) 2>/dev/null)
    done

    COMMONX_ARTIFACTS_CLEANED="$removed"
    if [ "$removed" -gt 0 ]; then
        log_info "Cleaned $removed stale build artifact(s) from the commonx package tree ($pkg_dir) before building -- stale .ppu/.o make the compiler die with an internal error (1026)."
    else
        log_info "commonx package tree clean -- no stale build artifacts to remove ($pkg_dir)."
    fi
    return 0
}

# THE COMPILER MUST NOT RUN FROM ITS OWN SOURCE DIRECTORY (c655).
#
# FPC appends the running compiler binary's OWN directory to the unit search path,
# after every -Fu. VibePascal's ppcx64 lives in $VP_DIR/compiler, which is the
# compiler SOURCE tree: 207 .pas files, three of whose unit names collide with
# Lazarus units -- macho (components/fpdebug), compiler (ide/packages/ideconfig)
# and tokens (components/jcf2/Parse). The names are not hardcoded below; they are
# recomputed, because the collision set is a property of two trees that both move.
#
# MEASURED, not reasoned: `lazbuild --build-ide --compiler=$VP_DIR/compiler/ppcx64`
# for x86_64-linux/gtk2 dies at
#     Fatal: (10022) Can't find unit FpImgReaderMachoFile used by FpImgReaderMacho
# because LazDebuggerFp gets fpdebug's macho.ppu on its path but NOT fpdebug's
# source dir, so the only macho.pas FPC can see is the compiler's own -- a
# different file (2106 lines vs 2101). It recompiles macho into LazDebuggerFp's
# output dir with a different CRC, which invalidates fpimgreadermachofile.ppu,
# whose source is not on that path either. Same binary copied to an empty
# directory: exit 0, IDE linked. A SYMLINK DOES NOT WORK -- FPC resolves the real
# path of the executable, so it must be a real copy.
#
# Windows already avoids this: auto-update.ps1 prefers bin\ppcx64.exe for a
# related reason ($FPCBINDIR is derived from the binary's directory). This gives
# the bash path the same property when no bin/ layout exists.
VP_COMPILER_RESOLVED=0
resolve_vp_compiler() {
    [ "$VP_COMPILER_RESOLVED" -eq 1 ] && return 0
    VP_COMPILER_RESOLVED=1
    [ -x "$VP_COMPILER" ] || return 0

    local base src_dir
    base=$(basename "$VP_COMPILER")
    src_dir=$(dirname "$VP_COMPILER")

    # 1. The installed layout, when there is one. Preferred over a copy because it
    #    is what the tarball's own fpc.cfg expects.
    #
    #    But only when that entry has the property we are preferring it FOR. The
    #    first version of this test was a bare `[ -x ]`, which is true of a
    #    symlink, of a stale copy and of a bin/ that someone dropped sources into
    #    -- and in all three cases the log line below would have claimed a
    #    guarantee the entry does not provide. Each rejection falls through to the
    #    private copy in step 3, which always has the property by construction.
    local installed="$VP_DIR/bin/$base" reject=""
    if [ -x "$installed" ]; then
        if [ -L "$installed" ]; then
            # A SYMLINK IS NOT A FIX, AND NO CHECKSUM CAN SEE THAT -- a symlink
            # hashes as its target, so an md5 comparison against compiler/ passes.
            # FPC resolves the executable to its real path BEFORE it computes
            # exepath, so a symlinked bin/ puts the compiler's own 207-file source
            # tree back on the unit search path in full while looking exactly like
            # the fix. Measured here on the real ppcx64, both controls: symlink in
            # an empty dir -> "Using unit path: .../vibepascal/compiler/" (7 hits
            # in a -vut trace); real copy in the same empty dir -> 0 hits.
            # Populating bin/ with symlinks is the obvious way to do it, so this is
            # a live trap, not a theoretical one. Found by Otto (FPCDeveloper),
            # who measured it before shipping the real copies.
            reject="it is a symlink to $(abspath_of "$installed" || echo 'another directory'), and FPC follows it -- that directory, not bin/, is what lands on the unit search path"
        elif [ ! -f "$installed" ]; then
            reject="it is not a regular file"
        elif [ -n "$(find "$VP_DIR/bin" -maxdepth 1 -name '*.pas' -print -quit 2>/dev/null)" ]; then
            reject="$VP_DIR/bin holds Pascal sources, so running the compiler from there shadows units exactly like the compiler's own source dir does"
        elif ! cmp -s "$installed" "$VP_COMPILER"; then
            # bin/ cannot be committed (it is in upstream FPC's .gitignore), so in
            # a git checkout it is a copy that goes stale the moment VibePascal is
            # bootstrapped. Silently handing the build an OLD compiler is a worse
            # failure than the loud one this function exists to prevent: v56 and
            # earlier hang forever on a half-written .ppu. Otto's
            # dist/linux-bin-layout.sh refreshes bin/ and I considered calling it
            # from here, but declined -- that writes into a tree this project does
            # not own, from a script a user runs. Detecting the skew and using our
            # own copy needs nobody's permission and cannot race his bootstrap.
            reject="it differs from $VP_COMPILER, so it is a stale copy of some other build"
        else
            VP_COMPILER="$installed"
            log_info "Using $VP_COMPILER (bin/ layout -- real file, current, no Pascal sources beside it, so the compiler's own source tree stays off the unit search path)."
            return 0
        fi
        log_warn "Ignoring $installed: $reject. Falling back to a private copy of $VP_COMPILER."
    fi

    # 2. No Pascal sources beside the binary => nothing to shadow, leave it alone.
    if [ -z "$(find "$src_dir" -maxdepth 1 -name '*.pas' -print -quit 2>/dev/null)" ]; then
        return 0
    fi

    # 3. Copy it out. Refreshed whenever the real compiler is newer, so a VibePascal
    #    pull is picked up on the next run rather than pinning an old compiler.
    local copy_dir="$LAZARUS_DIR/.vpcompiler"
    local copy="$copy_dir/$base"
    if ! mkdir -p "$copy_dir" 2>/dev/null; then
        log_warn "Cannot create $copy_dir -- running the compiler from its own source dir ($src_dir). If the IDE build dies with \"Can't find unit FpImgReaderMachoFile\", that is why."
        return 0
    fi
    if [ ! -f "$copy" ] || [ "$VP_COMPILER" -nt "$copy" ]; then
        if ! cp -f "$VP_COMPILER" "$copy" 2>/dev/null; then
            log_warn "Could not copy $VP_COMPILER to $copy -- continuing with the in-tree compiler."
            return 0
        fi
        chmod +x "$copy" 2>/dev/null || true
    fi
    VP_COMPILER="$copy"
    log_info "Using a copy of the compiler at $copy -- $src_dir holds the compiler's own sources and FPC puts that directory on every unit search path."
    return 0
}

# REMOVE THE WRECKAGE A PREVIOUS RUN LEFT, or the fix above helps only new boxes.
#
# Once the shadow above has fired even once, the wrong macho.ppu is sitting in
# LazDebuggerFp's output directory. That directory is ALSO a unit search path, so
# the build keeps failing with the identical error after the compiler is moved --
# verified here: isolated compiler + leftover ppu = still exit 2, remove the ppu
# as well = exit 0 and a linked 34 MB lazarus. A fix that leaves an already-broken
# box broken is not a fix (c634).
#
# What counts as wreckage is decided structurally: for each unit name that exists
# BOTH beside the compiler binary and in the Lazarus tree, any .ppu/.o for that
# name that is NOT under the directory of its Lazarus source is an orphan. Lazarus
# itself agrees and says so -- `Duplicate unit "macho" ... orphaned ppu "<path>"`.
clean_shadowed_unit_artifacts() {
    local cc_dir removed=0 tmp f
    cc_dir=$(dirname "$VP_COMPILER")
    # After resolve_vp_compiler the binary may be a copy, so ask the real tree.
    [ -n "$(find "$cc_dir" -maxdepth 1 -name '*.pas' -print -quit 2>/dev/null)" ] || cc_dir="$VP_DIR/compiler"
    [ -d "$cc_dir" ] || return 0

    # Three single passes, not one pass per unit name: the compiler tree has ~200
    # sources and the Lazarus tree has thousands of artifacts, so a find per name
    # would walk the tree 200 times for a list that is usually three entries long.
    tmp=$(mktemp 2>/dev/null) || return 0
    {
        find "$cc_dir" -maxdepth 1 -name '*.pas' -printf 'C %f\n' 2>/dev/null
        find "$LAZARUS_DIR" \( -name '*.pas' -o -name '*.pp' \) 2>/dev/null \
            | grep -v '/lib/\|/units/' | sed 's/^/S /'
        find "$LAZARUS_DIR" \( -name '*.ppu' -o -name '*.o' \) 2>/dev/null \
            | grep '/lib/\|/units/' | sed 's/^/A /'
    } | awk '
        function base(p,   n,a) { n=split(p,a,"/"); return a[n] }
        # LAST extension, not the first dot: the tree carries 143 dotted unit
        # filenames (chatgpt.Dto.pas, generics.collections.ppu), and keying them
        # on "chatgpt"/"generics" would collide names that are not the same unit.
        function stem(b)        { sub(/\.[^.]*$/,"",b); return b }
        function lc(x)          { return tolower(x) }
        $1=="C" { cc[lc(stem($2))]=1; next }
        $1=="S" { b=lc(stem(base($2)))
                  d=$2; sub(/\/[^\/]*$/,"",d)
                  owner[b]=owner[b] d "\n"; next }
        $1=="A" { art[++na]=$2; next }
        END {
          for (i=1;i<=na;i++) {
            b=lc(stem(base(art[i])))
            if (!(b in cc) || !(b in owner)) continue
            n=split(owner[b],dirs,"\n"); ok=0
            for (j=1;j<=n;j++) if (dirs[j]!="" && index(art[i],dirs[j] "/")==1) ok=1
            if (!ok) print art[i]
          }
        }' > "$tmp"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if rm -f "$f" 2>/dev/null; then
            removed=$((removed + 1))
            log_info "Removed shadowed unit artifact $f -- that unit name also exists beside the compiler binary and this is not its own package's output."
        fi
    done < "$tmp"
    rm -f "$tmp" 2>/dev/null || true

    if [ "$removed" -gt 0 ]; then
        log_warn "Removed $removed unit artifact(s) left by an earlier build that compiled a COMPILER source file into a Lazarus package. Left in place they keep failing the IDE build with \"Can't find unit ...\" on every future run."
    fi
    return 0
}

rebuild_ide() {
    log_header "Rebuilding Lazarus IDE"

    if [ ! -f "$LAZARUS_DIR/lazbuild" ]; then
        log_err "lazbuild not found -- cannot build IDE. Run rebuild first."
        return 1
    fi

    local ws="$LAZ_WS"
    if [ -n "$ws" ]; then
        : # platform has a fixed widgetset (cocoa on macOS)
    elif pkg-config --exists gtk+-2.0 2>/dev/null; then
        ws="gtk2"
    elif pkg-config --exists Qt5Pas 2>/dev/null; then
        ws="qt5"
    else
        log_err "Neither GTK2 nor Qt5 dev packages found."
        log_err "Install libgtk2.0-dev or libqt5pas-dev, then re-run with --build-ide."
        return 1
    fi

    log_info "Building IDE with widgetset: $ws"

    local pre_mtime=""
    if [ -f "$LAZARUS_DIR/lazarus" ]; then
        pre_mtime=$(stat -c %Y "$LAZARUS_DIR/lazarus" 2>/dev/null || stat -f %m "$LAZARUS_DIR/lazarus" 2>/dev/null)
    fi

    # GOD mp3nzr3r: ensure customdrawn LCL controls are installed by default on
    # every site, so users do not need to run `lazbuild --add-package` manually.
    # --build-ide (not --build-ide-minimal) is required because TBuildIDE.Minimal
    # skips LoadAutoInstallPackages.
    # lazbuild CONTRACT (ide/lazbuild.lpr:1668,1725,1760,1578): --add-package is a MODE
    # SWITCH taking NO argument; .lpk paths are POSITIONAL (Files). ONE switch + N paths.
    # (Measured c625: repeating the switch also exits 0; this is contract-correctness, not
    # a bug fix. `--add-package=PATH` however IS rejected, exit 6 -- the c291 r6 killer.)
    local add_pkg_lpks=""
    local customdrawn_lpk="$LAZARUS_DIR/components/customdrawn/customdrawn.lpk"
    local add_pkg_args=""
    if [ -f "$customdrawn_lpk" ]; then
        add_pkg_lpks="$customdrawn_lpk"
        log_info "Including customdrawn LCL controls (--add-package)"
    else
        log_info "customdrawn.lpk not found at $customdrawn_lpk -- skipping"
    fi

    # GOD mss4zlof / mt0snq31 (2026-08-20): TAChart (incl. TPieSeries) must reach the
    # designer palette on every delivered build. Parity with auto-update.ps1.
    # Verified compile: lazbuild --bm=unleashed -B tachartlazaruspkg.lpk exits 0 at
    # HEAD ce12737bc1 (tadrawercanvas.pas gained {$MODE ObjFPC} -- Wynona 2026-08-11).
    # Core Lazarus component -- NOT dropped on retry (only commonx has that fallback).
    local tachart_lpk="$LAZARUS_DIR/components/tachart/tachartlazaruspkg.lpk"
    if [ -f "$tachart_lpk" ]; then
        add_pkg_lpks="$add_pkg_lpks $tachart_lpk"
        log_info "Including TAChart LCL controls (--add-package)"
    else
        log_warn "TAChart package not found at $tachart_lpk -- TPieSeries will be MISSING from the palette"
    fi

    # GOD mrxnqj9g / mrxnwdze (2026-07-23): TTouchButton is GOD's OWN component, shipped
    # in the commonx LCL package set, which must be installed by auto-update or GOD's
    # components go missing from the designer palette. Parity with auto-update.ps1.
    # ONLY PackageCommonX_LCL -- commonx's BGRABitmap/LazActiveX duplicate this fork's
    # in-tree components/ copies and would trigger duplicate-unit install failures (#182).
    # c634: discovery moved to get_commonx_root so the pre-build decision, the build and the
    # post-build verification all resolve the SAME tree. When those lists drift, the checker
    # and the builder disagree and the self-heal trigger can never be satisfied.
    # `|| true` is required under `set -e`: get_commonx_root returns 1 when there is no
    # commonx tree, which is a normal, non-fatal state here.
    local commonx_root=""
    local commonx_lpk_path=""
    commonx_root=$(get_commonx_root || true)

    # c633 (GOD mt3gtf55): a fix on commonx SVN HEAD only helps if the LOCAL working copy is
    # CURRENT. The updater used to build whatever was on disk, so a stale checkout (predating
    # Knox's r6011/r6014 -Mdelphiunicode fix) re-hit error 3069 on the first attempt and was
    # then silently DROPPED on retry -- an IDE that builds but has NO TBetterWebBrowser /
    # TTouchButton at all. Refresh the working copy BEFORE building. Non-fatal in every
    # failure mode: worst case is today's behavior (stale commonx dropped), never a missing IDE.
    if [ -n "$commonx_root" ]; then
        if command -v svn >/dev/null 2>&1; then
            svn_rc=0
            svn_out=$(svn update "$commonx_root" 2>&1) || svn_rc=$?
            if [ "$svn_rc" -eq 0 ]; then
                log_info "Refreshed commonx SVN working copy ($commonx_root) -- r6011/r6014 -Mdelphiunicode fix picked up."
            else
                log_warn "svn update of commonx FAILED (exit $svn_rc). If TBetterWebBrowser/TTouchButton are still missing after this run, run:  svn update $commonx_root  then re-run this updater."
                log_warn "  svn output tail: $(printf '%s' "$svn_out" | grep -v '^$' | tail -n 3 | tr '\n' ' ')"
            fi
        else
            log_warn "svn not found on PATH -- cannot refresh commonx automatically. If TBetterWebBrowser/TTouchButton are still missing after this run, run:  svn update $commonx_root  then re-run this updater."
        fi
    fi

    # c655: strip any unit artifact a previous run compiled from the COMPILER's own
    # source tree into a Lazarus package output dir. Must run BEFORE attempt 1 --
    # such an artifact fails the build on its own, even with the compiler moved.
    clean_shadowed_unit_artifacts

    if [ -n "$commonx_root" ]; then
        local commonx_lpk
        commonx_lpk=$(find "$commonx_root" -name 'PackageCommonX_LCL.lpk' -print -quit 2>/dev/null)
        if [ -n "$commonx_lpk" ]; then
            commonx_lpk_path="$commonx_lpk"
            add_pkg_lpks="$add_pkg_lpks $commonx_lpk"
            log_info "Including commonx LCL controls incl. TTouchButton ($commonx_lpk)"
            # c636: clean BEFORE the attempt that includes commonx (see the function comment).
            clean_stale_package_artifacts "$commonx_lpk"
        else
            log_warn "PackageCommonX_LCL.lpk not found under $commonx_root -- TTouchButton will be MISSING from the palette"
        fi
    else
        log_info "commonx tree not found -- skipping commonx LCL packages (set COMMONX_DIR to override)"
    fi

    # ONE switch, then every collected path (see contract note above).
    if [ -n "$add_pkg_lpks" ]; then
        add_pkg_args="--add-package $add_pkg_lpks"
    fi

    # c635 (GOD mt917m2w/mt917vcr): tee attempt 1 to a log so the FIRST compiler error can be
    # replayed in the final failure block. Until now that line was printed only mid-build, and a
    # pasted log gets truncated from the TOP -- so the one line naming the failing unit was exactly
    # the line that never made it back to us. grep still gates what is shown live; tee does not
    # change the displayed output, and PIPESTATUS[0] still reports lazbuild, not tee/grep.
    local cx_build_log
    cx_build_log=$(mktemp 2>/dev/null || echo "$LAZARUS_DIR/.lazbuild_attempt1.log")
    COMMONX_FIRST_ERROR=""
    COMMONX_PPU_HINT=""
    # --build-ide=-Sci: lazbuild compiles ide/lazarus.pp with the compiler DIRECTLY and passes
    # no syntax switches of its own, while the IDE sources use C-style operators (`s+=...`).
    # The make route has always added -Sci (ide/Makefile.fpc [compiler] options); without it
    # this step dies at ide/checkcompileropts.pas(199) "C styled assignment operators are
    # turned off" whenever the compiler's fpc.cfg does not already carry -Sc (measured on
    # lazdev 2026-09-16 with the r25 linux cfg: exit 2 without, exit 0 with). Idempotent when
    # the cfg has it too.
    "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --build-ide=-Sci \
        --compiler="$VP_COMPILER" --cpu="$LAZ_CPU_TARGET" --os="$LAZ_OS_TARGET" --ws="$ws" $add_pkg_args 2>&1 | tee "$cx_build_log" | grep -E "Linking|lines compiled|Fatal|Error"
    local build_exit=${PIPESTATUS[0]}
    if [ "$build_exit" -ne 0 ]; then
        COMMONX_FIRST_ERROR=$(grep -m1 -E "(Error|Fatal):" "$cx_build_log" 2>/dev/null)
        # c636: "Error: (1026) Compilation raised exception internally" does not say WHICH unit.
        # The lines that do are the PPU-load lines just above it, and they match neither
        # "Error:" nor "Fatal:" -- so the c635 capture printed the symptom without the subject.
        COMMONX_PPU_HINT=$(grep -m1 -E "PPU DESTROY DURING LOAD" "$cx_build_log" 2>/dev/null || true)
    fi
    rm -f "$cx_build_log" 2>/dev/null || true

    # GOD mrxp2wpx (2026-07-23): parity with auto-update.ps1 -- an OPTIONAL THIRD-PARTY
    # package must NEVER be able to take the whole IDE down. Keep this retry regardless of
    # whether the original cause is fixed: the guarantee is "worst case = a missing
    # component, never a missing IDE".
    #
    # ORIGINAL cause (fixed commonx-side 2026-07-23, svn r6011/r6014): PackageCommonX_LCL.lpk
    # set -Mdelphi (String=AnsiString) while its transitively-compiled core units --
    # commandline.pas/stringx.pas, which are NOT package members -- straddled that boundary,
    # so a "var string" arg failed error 3069 and aborted the entire build. r6011 flipped the
    # .lpk to -Mdelphiunicode and dropped the {$mode delphiunicode} pin from DelphiDefs.inc;
    # r6014 swept {$I DelphiDefs.inc} across the closure so every unit floats to the same mode.
    #
    # MECHANISM (verified on lazdev, two controls, 2026-07-24): a package's NON-MEMBER
    # transitive units inherit the PACKAGE's CustomOptions -M flag -- they are NOT compiled
    # with the IDE's -Munleashed. So this failure mode tracks the .lpk's own mode setting.
    #
    # c635 MEASUREMENT (2026-08-25, GOD mt917m2w/mt917vcr) -- READ THIS BEFORE TRUSTING THE LINE ABOVE.
    # Measured on lazdev against commonx SVN HEAD r6142, VibePascal ppcx64 -Twin64 -Scghi -dLCL,
    # the FULL PackageCommonX_LCL closure (167 units, 344,501 lines):
    #   -Mdelphiunicode (what the .lpk sets) -> EXIT 0, clean. commonx source is NOT broken.
    #   -Munleashed     (the IDE build mode) -> FATAL at typex.pas(43,3) "( expected but [ found",
    #                                           and after fixing that, again at typex.pas(226,25)
    #                                           "Generics without specialization".
    # So typex.pas is Delphi-dialect by construction and CANNOT compile under -Munleashed; the
    # "inherits the package -M" claim above is what stopped us looking last time, and GOD's build
    # is still failing. Treat that claim as UNCONFIRMED for the real --build-ide path until someone
    # reads the captured first-error line (now replayed at the end of the run) from a real Windows run.
    #
    # c636 RESOLVED IT (GOD mt93q21h, 2026-08-25): the real Windows run came back and the
    # failure was NOT the -Munleashed parse error at all. It was an internal compiler crash
    # loading a stale ppu (PPU DESTROY DURING LOAD ... in module TYPEX / error 1026 / exit 217).
    # So typex.pas mode-portability was never what was breaking GOD's build, and it is NOT a
    # blocker for the palette. It stays a real but SEPARATE question owned by Knox as commonx SME.
    if [ "$build_exit" -ne 0 ] && [ -n "$commonx_lpk_path" ]; then
        log_warn "IDE build failed with commonx included; retrying WITHOUT commonx so the IDE still builds."
        log_warn "  The updater ran 'svn update' on the commonx tree before this build; if commonx still fails here, a stale checkout is NOT the cause."
        log_warn "  The first 'Error:' line printed above is the cause. If it names a commonx unit with error 3069, the svn update did not take effect (see the svn messages from earlier in this run)."
        log_warn "  Consequence: commonx components (incl. TTouchButton / TBetterWebBrowser) will NOT be on the designer palette until that is fixed."
        local kept_lpks=""
        local p
        for p in $add_pkg_lpks; do
            if [ "$p" != "$commonx_lpk_path" ]; then kept_lpks="$kept_lpks $p"; fi
        done
        kept_lpks="${kept_lpks# }"
        local fallback_args=""
        if [ -n "$kept_lpks" ]; then fallback_args="--add-package $kept_lpks"; fi
        "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --build-ide=-Sci \
            --compiler="$VP_COMPILER" --cpu="$LAZ_CPU_TARGET" --os="$LAZ_OS_TARGET" --ws="$ws" $fallback_args 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
        build_exit=${PIPESTATUS[0]}
        if [ "$build_exit" -eq 0 ]; then
            log_warn "IDE built WITHOUT commonx LCL packages -- TTouchButton is MISSING from the palette (see cause above)."
        fi
    fi

    if [ "$build_exit" -ne 0 ]; then
        log_err "lazarus build failed with exit code $build_exit"
        return 1
    fi

    if [ ! -f "$LAZARUS_DIR/lazarus" ]; then
        log_err "lazarus build failed -- binary not found!"
        return 1
    fi

    if [ -n "$pre_mtime" ]; then
        local post_mtime=$(stat -c %Y "$LAZARUS_DIR/lazarus" 2>/dev/null || stat -f %m "$LAZARUS_DIR/lazarus" 2>/dev/null)
        if [ "$post_mtime" -le "$pre_mtime" ]; then
            log_err "lazarus build failed silently -- binary was not updated (stale file from previous build)"
            return 1
        fi
    fi

    local size=$(du -sh "$LAZARUS_DIR/lazarus" | cut -f1)
    log_ok "lazarus rebuilt ($size)"

    # GOD mu3jfytu (2026-09-16): the docked "modern Delphi style" layout is the default and
    # rides two core packages. Fail loud when the binary we just built does not carry them.
    local dock_missing="" dock_rc=0
    dock_missing=$(test_docked_layout_installed) || dock_rc=$?
    if [ "$dock_rc" -eq 0 ]; then
        log_ok "Docked IDE layout (AnchorDocking + docked form editor) installed"
        clear_feature_attempt docked
    elif [ "$dock_rc" -eq 1 ]; then
        log_err "Docked IDE layout NOT installed -- lazarus does not contain: $dock_missing"
        log_err "  The IDE will open as floating windows, which GOD asked us to stop shipping (mu3jfytu)."
        log_err "  Fix: re-pull origin/main, run --force-rebuild, and read the FIRST 'Error:' line of the build."
        # c699: record the material this attempt was made against, so a steady-state run can
        # self-heal once when the source moves -- and only once (see the self-heal block).
        record_feature_attempt docked
    fi

    # c691 (GOD moehki0x): MetaDarkStyle is the third flagship feature whose design-time
    # package is linked straight into the IDE (ide/lazarus.pp uses metadarkstyledsgn), and
    # the bash path has never verified it. A build that quietly loses it looks identical to a
    # good one -- the same failure shape as commonx below.
    local mds_missing="" mds_rc=0
    mds_missing=$(test_metadarkstyle_installed) || mds_rc=$?
    if [ "$mds_rc" -eq 0 ]; then
        log_ok "MetaDarkStyle design-time package linked into the IDE"
        clear_feature_attempt metadarkstyle
    elif [ "$mds_rc" -eq 1 ]; then
        record_feature_attempt metadarkstyle   # c699, same reason as the docked stamp above
        log_err "MetaDarkStyle NOT linked -- lazarus does not contain: $mds_missing"
        log_err "  Tools -> Options -> Environment -> \"Theme\" will be missing, and on Windows the"
        log_err "  dark style is never applied at IDE start (the boot handler is in that package)."
        log_err "  Fix: re-pull origin/main, run --force-rebuild, and read the FIRST 'Error:' line of the build."
    elif [ "$mds_rc" -eq 3 ]; then
        log_err "MetaDarkStyle design-time SOURCE is missing from the checkout:"
        log_err "  components/metadarkstyle/dsgn/metadarkstyledsgn.lpk -- re-pull origin/main."
    fi

    # c634 (GOD mt8zo2vh): verify GOD's own components actually made it into the binary.
    # Until now the ONLY signal that PackageCommonX_LCL had been dropped was a log_warn
    # buried mid-build, while the run still ended "lazarus rebuilt" -- so a build that
    # silently lost TBetterWebBrowser / TTouchButton looked identical to a good one. Record
    # the attempted state either way, so the self-heal trigger knows whether a retry is
    # worthwhile.
    local cx_missing="" cx_rc=0
    cx_missing=$(test_commonx_components_installed) || cx_rc=$?
    if [ "$cx_rc" -eq 1 ]; then
        log_err "commonx components NOT installed: $cx_missing"
        log_err "  Forms using them will fail to open in the designer with:"
        log_err "    Unable to find the component class \"TBetterWebBrowser\" ... it is needed by unit <your form>.pas"
        log_err "  The first 'Error:' line printed above is the cause -- it names the commonx unit that"
        log_err "  failed to compile under the IDE build mode, which is why the retry dropped the package."
        if [ -n "$COMMONX_FIRST_ERROR" ]; then
            log_err "  FIRST COMPILER ERROR from the attempt that included commonx (THIS IS THE CAUSE):"
            log_err "    $COMMONX_FIRST_ERROR"
            if [ -n "$COMMONX_PPU_HINT" ]; then
                log_err "  ...and this names the unit it died on (an internal compiler error carries no unit):"
                log_err "    $COMMONX_PPU_HINT"
                log_err "  A 'PPU DESTROY DURING LOAD' + error 1026 pair means a ppu on the search path could not"
                log_err "  be loaded -- normally a stale one. This run removed ${COMMONX_ARTIFACTS_CLEANED:-0} stale artifact(s) before building,"
                log_err "  so if you are still seeing this, staleness is NOT the remaining cause."
            fi
        else
            log_err "  (no compiler error captured this run -- commonx may have been skipped before the"
            log_err "   build rather than failing during it)"
        fi
        mkdir -p "$(dirname "$(commonx_stamp_path)")" 2>/dev/null
        get_commonx_install_stamp > "$(commonx_stamp_path)" 2>/dev/null || true
    elif [ "$cx_rc" -eq 0 ]; then
        log_ok "commonx components installed ($COMMONX_COMPONENTS on the 'Digital Tundra' palette)"
        rm -f "$(commonx_stamp_path)" 2>/dev/null || true
    fi
}

test_ide_package_lpk_consistency() {
    # Mirrors Test-IdePackageLpkConsistency in auto-update.ps1 (cycle 232 / #114).
    # GOD UX directive mozyeiiu sub-issue (d): IDE startup raised "Unit 'X' was
    # not found in the lpk file" from ide/packages/idepackager/packagesystem.pas
    # line ~2060 because <pkg>package.pas listed a RegisterUnit('X', ...) call
    # but the loaded <pkg>.lpk had no matching <UnitName Value="X"/>. This is
    # the static mirror -- catches the same condition before the IDE launches.
    local packages_dir="$LAZARUS_DIR/ide/packages"
    local mismatch_count=0

    if [ ! -d "$packages_dir" ]; then
        log_ok "IDE package .lpk vs source consistency: OK (no ide/packages dir)"
        return 0
    fi

    for pkg_dir in "$packages_dir"/*/; do
        [ -d "$pkg_dir" ] || continue
        local pkg_name
        pkg_name=$(basename "$pkg_dir")
        local lpk_file="${pkg_dir}${pkg_name}.lpk"
        local autogen_file="${pkg_dir}${pkg_name}package.pas"

        [ -f "$lpk_file" ] && [ -f "$autogen_file" ] || continue

        local lpk_unit_names
        if command -v xmlstarlet &>/dev/null; then
            lpk_unit_names=$(xmlstarlet sel -t -v '//UnitName/@Value' -n "$lpk_file" 2>/dev/null \
                | tr '[:upper:]' '[:lower:]' | sort -u)
        else
            lpk_unit_names=$(grep -oE '<UnitName Value="[^"]+"' "$lpk_file" 2>/dev/null \
                | sed -E 's/.*<UnitName Value="([^"]+)".*/\1/' \
                | tr '[:upper:]' '[:lower:]' | sort -u)
        fi

        while IFS= read -r name; do
            [ -n "$name" ] || continue
            local name_lower
            name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
            if ! grep -qFx "$name_lower" <<< "$lpk_unit_names"; then
                log_err "Package '$pkg_name': ${pkg_name}package.pas calls RegisterUnit('$name') but $pkg_name.lpk has no matching <UnitName>"
                mismatch_count=$((mismatch_count + 1))
            fi
        done < <(grep -oE "RegisterUnit\(\s*'[^']+'" "$autogen_file" 2>/dev/null \
            | sed -E "s/.*RegisterUnit\(\s*'([^']+)'.*/\1/")
    done

    if [ "$mismatch_count" -eq 0 ]; then
        log_ok "IDE package .lpk vs source consistency: OK"
        return 0
    else
        log_err "  Cause: source pulled but .lpk stale, or .lpk pulled but source not yet rebuilt."
        log_err "  Fix: cd $LAZARUS_DIR && git pull && ./auto-update.sh --force-rebuild"
        return 1
    fi
}

invoke_doctor() {
    log_header "Lazarus + VibePascal Doctor"
    local problems=0

    log_info "Lazarus directory: $LAZARUS_DIR"
    if [ -d "$LAZARUS_DIR/lcl" ] && [ -d "$LAZARUS_DIR/ide" ] && [ -d "$LAZARUS_DIR/components" ]; then
        log_ok "Lazarus dir structure: lcl/ ide/ components/ all present"
    else
        log_err "Lazarus dir incomplete: missing one of lcl/ ide/ components/"
        problems=$((problems + 1))
    fi

    log_info "VibePascal directory: $VP_DIR"
    if [ -x "$VP_COMPILER" ]; then
        log_ok "VibePascal compiler: $VP_COMPILER"
    else
        log_err "VibePascal compiler not found at $VP_COMPILER"
        problems=$((problems + 1))
    fi

    # macOS has no site cfg in the VibePascal tree: the compiler reads ~/.fpc.cfg (which is
    # where FPC looks with no PPC_CONFIG_PATH set -- a GUI-launched IDE inherits no env).
    local vp_cfg="$VP_DIR/bin/fpc.cfg"
    [ ! -f "$vp_cfg" ] && [ "$LAZ_OS_TARGET" = "darwin" ] && [ -f "$DARWIN_CFG" ] && vp_cfg="$DARWIN_CFG"
    [ ! -f "$vp_cfg" ] && [ "$LAZ_OS_TARGET" = "darwin" ] && [ -f "$HOME/.fpc.cfg" ] && vp_cfg="$HOME/.fpc.cfg"
    if [ -f "$vp_cfg" ]; then
        local cfg_paths
        cfg_paths=$(grep -c '^-Fu' "$vp_cfg" 2>/dev/null || echo 0)
        log_ok "VibePascal fpc.cfg: $vp_cfg ($cfg_paths unit paths)"
    else
        log_warn "VibePascal fpc.cfg not found at $vp_cfg (run --setup or --force-rebuild)"
    fi

    local user_cfg="$HOME/.lazarus/environmentoptions.xml"
    if [ -f "$user_cfg" ]; then
        log_ok "User config: $user_cfg"
    else
        log_warn "User config not found at $user_cfg (run --setup)"
    fi

    local lazarus_bin="$LAZARUS_DIR/lazarus"
    if [ -x "$lazarus_bin" ]; then
        local mtime
        mtime=$(mtime_human "$lazarus_bin")
        [ -z "$mtime" ] && mtime=$(stat -f '%Sm' "$lazarus_bin" 2>/dev/null)
        log_ok "lazarus binary: $lazarus_bin ($mtime)"
    else
        log_warn "lazarus binary not built yet (run --build-ide)"
    fi

    # GOD mu3jfytu (2026-09-16): docked single-window layout is the default. rc 2 (no
    # binary) is already covered by the WARN just above, so it is not a second finding.
    local dock_missing="" dock_rc=0
    dock_missing=$(test_docked_layout_installed) || dock_rc=$?
    if [ "$dock_rc" -eq 0 ]; then
        log_ok "Docked IDE layout (AnchorDocking + docked form editor): installed"
    elif [ "$dock_rc" -eq 1 ]; then
        log_err "Docked IDE layout: NOT installed -- lazarus does not contain: $dock_missing (run --force-rebuild)"
        problems=$((problems + 1))
    fi

    # c691 (GOD moehki0x): MetaDarkStyle, the third flagship feature -- the bash updater has
    # never checked it while the .ps1 doctor always did. rc 2 (no binary) is the WARN above.
    local mds_missing="" mds_rc=0
    mds_missing=$(test_metadarkstyle_installed) || mds_rc=$?
    if [ "$mds_rc" -eq 0 ]; then
        log_ok "MetaDarkStyle design-time package: linked into the IDE"
    elif [ "$mds_rc" -eq 1 ]; then
        log_err "MetaDarkStyle: NOT linked -- lazarus does not contain: $mds_missing (run --force-rebuild)"
        log_err "  Tools -> Options -> Environment -> \"Theme\" will be missing from the IDE."
        problems=$((problems + 1))
    elif [ "$mds_rc" -eq 3 ]; then
        log_err "MetaDarkStyle: design-time SOURCE missing -- components/metadarkstyle/dsgn/metadarkstyledsgn.lpk is not in the checkout (re-pull origin/main)"
        problems=$((problems + 1))
    fi

    local lazbuild_bin="$LAZARUS_DIR/lazbuild"
    if [ -x "$lazbuild_bin" ]; then
        log_ok "lazbuild binary: $lazbuild_bin"
    else
        log_warn "lazbuild binary not built yet"
    fi

    if ! test_ide_package_lpk_consistency; then
        problems=$((problems + 1))
    fi

    echo ""
    if [ "$problems" -eq 0 ]; then
        log_ok "No problems found. Toolchain looks healthy."
    else
        log_err "$problems problem(s) found."
        log_info "Suggested fixes:"
        log_info "  1. cd $LAZARUS_DIR && git pull"
        log_info "  2. ./auto-update.sh --force-rebuild"
        log_info "  3. If problems persist, verify VibePascal at $VP_DIR"
    fi
    return $problems
}

fix_lpi_files() {
    local search_dir="${1:-$LAZARUS_DIR}"
    log_header "Scanning .lpi files for UnitOutputDirectory fixes"

    local fix_count=0
    while IFS= read -r -d '' lpi; do
        if command -v xmlstarlet &>/dev/null; then
            local current
            current=$(xmlstarlet sel -t -v '//CompilerOptions/SearchPaths/UnitOutputDirectory/@Value' "$lpi" 2>/dev/null || echo "")
            if [ "$current" != "lib" ]; then
                xmlstarlet ed -L \
                    -s '//CompilerOptions/SearchPaths[not(UnitOutputDirectory)]' -t elem -n UnitOutputDirectory -v "" \
                    -i '//CompilerOptions/SearchPaths/UnitOutputDirectory[not(@Value)]' -t attr -n Value -v "lib" \
                    -u '//CompilerOptions/SearchPaths/UnitOutputDirectory/@Value' -v "lib" \
                    "$lpi" 2>/dev/null
                log_info "$(basename "$lpi"): UnitOutputDirectory ${current:-(empty)} -> lib"
                fix_count=$((fix_count + 1))
            fi
        else
            if grep -q 'UnitOutputDirectory' "$lpi"; then
                if ! grep -q 'UnitOutputDirectory Value="lib"' "$lpi"; then
                    sed_inplace 's|UnitOutputDirectory Value="[^"]*"|UnitOutputDirectory Value="lib"|g' "$lpi"
                    log_info "$(basename "$lpi"): fixed UnitOutputDirectory -> lib"
                    fix_count=$((fix_count + 1))
                fi
            fi
        fi
    done < <(find "$search_dir" -name "*.lpi" -print0 2>/dev/null)

    if [ "$fix_count" -eq 0 ]; then
        log_ok "All .lpi files already have UnitOutputDirectory = lib"
    else
        log_ok "Fixed $fix_count .lpi file(s)"
    fi
}

resolve_vp_compiler

if [ "$DOCTOR" -eq 1 ]; then
    invoke_doctor
    exit $?
fi

if [ "$FIX_LPI" -eq 1 ]; then
    fix_lpi_files
    exit 0
fi

if [ "$SETUP_ONLY" -eq 1 ]; then
    configure_environment
    exit 0
fi

log_header "Lazarus + VibePascal Auto-Updater"
echo "  Lazarus:    $LAZARUS_DIR"
echo "  VibePascal: $VP_DIR"
echo "  Compiler:   $VP_COMPILER"
echo ""

SCRIPT_PRE_HASH=$(sha256sum "$LAZARUS_DIR/auto-update.sh" 2>/dev/null | cut -d' ' -f1)

# c722 -- MEASURED ON A SCRATCH CLONE WITH NO 'upstream' REMOTE, which is MVMJ26's shape:
# this fetch used to run unguarded, and `set -e` plus `2>/dev/null` turned a missing remote
# into the END of the run -- rc 128 immediately after the banner above, with no summary, no
# error text and nothing checked. Miles reported the .ps1's misleading summary line; the bash
# half never reached its summary at all. Probe the remote, say so out loud, keep going.
UPSTREAM_CONFIGURED=0
if git -C "$LAZARUS_DIR" remote get-url upstream >/dev/null 2>&1; then
    UPSTREAM_CONFIGURED=1
    if ! git -C "$LAZARUS_DIR" fetch upstream 2>/dev/null; then
        log_warn "Lazarus: 'git fetch upstream' failed -- the upstream comparison below uses whatever upstream/main this clone already had, if any"
    fi
else
    log_warn "No 'upstream' remote configured in $LAZARUS_DIR -- upstream Lazarus (fpc/Lazarus) will NOT be checked this run"
    log_info "To add it: git remote add upstream https://github.com/fpc/Lazarus.git"
fi

# c719 -- take HEAD BEFORE anything can move it. Nothing above this point pulls: the fetch
# moves remote-tracking refs only, and wipe_local_changes (reset --hard HEAD) runs later and
# does not move HEAD either.
LAZARUS_HEAD_BEFORE=$(head_sha "$LAZARUS_DIR" || true)
VP_HEAD_BEFORE=$(head_sha "$VP_DIR" || true)
VP_VERSION_BEFORE=$(vp_dist_version || true)   # c720 -- same instant as the HEADs above, before anything pulls

if [ "$UPSTREAM_ONLY" -eq 0 ]; then
    check_vp_updates
fi
check_lazarus_upstream
check_lazarus_origin

if [ "$CHECK_ONLY" -eq 1 ]; then
    print_summary
    exit 0
fi

wipe_local_changes

if [ "$UPSTREAM_ONLY" -eq 0 ]; then
    pull_vp
fi
pull_lazarus_upstream
LAZARUS_HEAD_AFTER_UPSTREAM=$(head_sha "$LAZARUS_DIR" || true)   # c719: splits the upstream merge from the origin pull, which move the same HEAD
pull_lazarus_origin

relaunch_if_updated "$SCRIPT_PRE_HASH"

ANY_UPDATED=0
if [ "$VP_UPDATED" -eq 1 ] || [ "$LAZARUS_UPDATED" -eq 1 ] || [ "$UPSTREAM_UPDATED" -eq 1 ]; then
    ANY_UPDATED=1
fi

if [ "$FORCE_REBUILD" -eq 1 ]; then
    log_info "Force rebuild requested"
    ANY_UPDATED=1
fi

# c634 (GOD mt8zo2vh) -- SELF-HEAL a degraded IDE.
# rebuild_ide only runs when ANY_UPDATED. On a steady-state box (binaries present, pull a
# no-op) that meant an IDE which had lost PackageCommonX_LCL -- because the build failed
# once and the retry dropped it -- could never get it back without someone knowing to pass
# --force-rebuild. That is why GOD saw the same "Unable to find the component class
# TBetterWebBrowser" dialog for weeks: the updater reported success every run and never
# rebuilt. If the components are missing, rebuild.
#
# Guarded by a stamp so this cannot spin: retry only when the Lazarus commit or the commonx
# revision has CHANGED since the last attempt that failed to install them.
if [ "$ANY_UPDATED" -eq 0 ] && [ "$NO_BUILD" -eq 0 ] && [ "$BUILD_IDE" -eq 1 ]; then
    cx_missing=""; cx_rc=0
    cx_missing=$(test_commonx_components_installed) || cx_rc=$?
    if [ "$cx_rc" -eq 1 ]; then
        log_warn "IDE is missing GOD's commonx components: $cx_missing"
        current_stamp=$(get_commonx_install_stamp)
        last_stamp=""
        [ -f "$(commonx_stamp_path)" ] && last_stamp=$(cat "$(commonx_stamp_path)" 2>/dev/null)
        if [ "$current_stamp" != "$last_stamp" ]; then
            log_info "Forcing IDE rebuild to reinstall PackageCommonX_LCL (source changed since the last attempt)"
            ANY_UPDATED=1
        else
            log_err "PackageCommonX_LCL still not installed, and nothing has changed since the last attempt -- not rebuilding again."
            log_err "  Forms using TBetterWebBrowser / TTouchButton will not load in the designer."
            log_err "  Fix: run  ./auto-update.sh --force-rebuild  and read the FIRST 'Error:' line of the build output."
        fi
    fi
fi

# c699 (GOD mu66fghs, 2026-09-17) -- SELF-HEAL THE OTHER TWO FLAGSHIP FEATURES.
# The block above has asked exactly one question since c634: "are GOD's commonx components in
# the binary?" An IDE built BEFORE the docking packages became core (9b044e4527) answers YES,
# so ANY_UPDATED stays 0, rebuild_ide never runs, and the user keeps a floating-window IDE
# forever while every run prints success. GOD reported precisely that on Windows: "your changes
# recently seemed to affect the linux builds... but my windows system is still the fucking
# ancient looking delphi 7 style floating shit."
#
# The verifiers already existed -- they just ran only AFTER a rebuild, i.e. never on the boxes
# that needed them. Same stamp guard as commonx, one stamp per feature, so a box that genuinely
# cannot build these gets ONE loud diagnosis instead of a full IDE rebuild every run.
if [ "$ANY_UPDATED" -eq 0 ] && [ "$NO_BUILD" -eq 0 ] && [ "$BUILD_IDE" -eq 1 ]; then
    heal_missing=""; heal_rc=0
    heal_missing=$(test_docked_layout_installed) || heal_rc=$?
    if [ "$heal_rc" -eq 1 ]; then
        log_warn "IDE is missing the docked single-window layout (GOD mu3jfytu): $heal_missing"
        if feature_attempt_is_new docked; then
            log_info "Forcing IDE rebuild to link AnchorDockingDsgn + DockedFormEditor (source changed since the last attempt)"
            ANY_UPDATED=1
        else
            log_err "Docked layout still not linked, and the source has not moved since the last attempt -- not rebuilding again."
            log_err "  The IDE will keep opening as floating windows (the Delphi 7 shape GOD asked us to stop shipping)."
            log_err "  Fix: run  ./auto-update.sh --force-rebuild  and read the FIRST 'Error:' line of the build output."
        fi
    fi

    heal_missing=""; heal_rc=0
    heal_missing=$(test_metadarkstyle_installed) || heal_rc=$?
    if [ "$heal_rc" -eq 1 ]; then
        log_warn "IDE is missing the MetaDarkStyle design-time package (GOD moehki0x): $heal_missing"
        if feature_attempt_is_new metadarkstyle; then
            log_info "Forcing IDE rebuild to link metadarkstyledsgn (source changed since the last attempt)"
            ANY_UPDATED=1
        else
            log_err "MetaDarkStyle still not linked, and the source has not moved since the last attempt -- not rebuilding again."
            log_err "  Tools -> Options -> Environment -> \"Theme\" stays missing until this builds."
            log_err "  Fix: run  ./auto-update.sh --force-rebuild  and read the FIRST 'Error:' line of the build output."
        fi
    fi
fi

# c682 -- a box that pulled a compiler change with an OLDER updater (which never rebuilt the
# compiler) is steady-state now: nothing new to pull, so nothing above would ever fix it.
if [ "$ANY_UPDATED" -eq 0 ] && [ "$NO_BUILD" -eq 0 ] && [ "$UPSTREAM_ONLY" -eq 0 ] && is_git_checkout "$VP_DIR"; then
    stale_reason=""
    if stale_reason=$(vp_compiler_is_stale); then
        log_warn "VibePascal compiler binary is behind its sources ($stale_reason) -- rebuilding it"
        VP_REBUILD=1
        ANY_UPDATED=1
    fi
fi

# darwin: lazbuild and the IDE compile against $DARWIN_CFG. A box that has never had one
# (every Mac before this change) must build the VibePascal RTL + packages once to get it, even
# when nothing was pulled -- otherwise VP_OPT stays empty and the build mixes unit sets again.
if [ "$LAZ_OS_TARGET" = "darwin" ] && [ "$NO_BUILD" -eq 0 ] && [ "$UPSTREAM_ONLY" -eq 0 ] && [ ! -f "$DARWIN_CFG" ]; then
    log_warn "No $DARWIN_CFG yet -- building the VibePascal RTL and packages to generate it"
    VP_REBUILD=1
    ANY_UPDATED=1
fi

if [ "$ANY_UPDATED" -eq 1 ]; then
    if [ "$NO_BUILD" -eq 1 ]; then
        log_info "Skipping rebuild (--no-build)"
    else
        if [ "$VP_UPDATED" -eq 1 ] || [ "$VP_REBUILD" -eq 1 ]; then
            rebuild_vp_compiler || true
            rebuild_vp_packages
        fi
        rebuild_lazbuild
        configure_environment
        if [ "$BUILD_IDE" -eq 1 ]; then
            rebuild_ide
        fi
        if [ "$BUILD_RELEASE" -eq 1 ]; then
            log_header "Building release tarballs"
            "$LAZARUS_DIR/build-release.sh" all
        fi
    fi
fi

print_summary
