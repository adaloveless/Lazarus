#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAZARUS_DIR="$SCRIPT_DIR"
VP_DIR="/home/jason/src/vibepascal"
VP_COMPILER="$VP_DIR/compiler/ppcx64"
LINUX_CFG="$VP_DIR/vibepascal-linux-x86_64.cfg"
WIN64_CFG="$VP_DIR/vibepascal-win64-x86_64.cfg"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LAZARUS_UPDATED=0
VP_UPDATED=0
UPSTREAM_UPDATED=0

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
    echo "  --build-ide      Also rebuild the full Lazarus IDE (requires GTK2 or Qt5)"
    echo "  --force-rebuild  Force rebuild even if no updates are available"
    echo "  --doctor         Run diagnostics (no state changes); exit 1 if problems found"
    echo "  --help           Show this help"
    echo ""
    echo "Default: pull updates and rebuild lazbuild if anything changed."
    exit 0
}

CHECK_ONLY=0
NO_BUILD=0
BUILD_RELEASE=0
UPSTREAM_ONLY=0
SETUP_ONLY=0
FIX_LPI=0
BUILD_IDE=0
FORCE_REBUILD=0
SELF_UPDATED=0
DOCTOR=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_ONLY=1; shift ;;
        --no-build)    NO_BUILD=1; shift ;;
        --release)     BUILD_RELEASE=1; shift ;;
        --upstream-only) UPSTREAM_ONLY=1; shift ;;
        --setup)       SETUP_ONLY=1; shift ;;
        --fix-lpi)     FIX_LPI=1; shift ;;
        --build-ide)   BUILD_IDE=1; shift ;;
        --force-rebuild) FORCE_REBUILD=1; shift ;;
        --self-updated) SELF_UPDATED=1; shift ;;
        --doctor)      DOCTOR=1; shift ;;
        --help|-h)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_header(){ echo -e "\n${CYAN}=== $1 ===${NC}"; }

# GOD mp8g1me3 (2026-05-16): auto-update is for pristine test envs, not local dev.
# Wipe ALL local changes (tracked + untracked) so test machines pull cleanly.
# If you are a developer with local work, do NOT run auto-update.sh -- use git directly.
wipe_local_changes() {
    log_header "Wiping local changes (pristine test-env mode)"
    log_warn "auto-update.sh discards ALL uncommitted changes and untracked files."
    log_warn "If you are a developer with local work, abort NOW (Ctrl-C)."

    if [ ! -d "$LAZARUS_DIR/.git" ]; then
        log_warn "$LAZARUS_DIR is not a git checkout; skipping local wipe."
        return
    fi

    git -C "$LAZARUS_DIR" reset --hard HEAD 2>&1 | tail -1
    git -C "$LAZARUS_DIR" clean -fdx 2>&1 | tail -1
    log_ok "Lazarus working tree reset + cleaned ($LAZARUS_DIR)"

    if [ "$UPSTREAM_ONLY" -eq 0 ] && [ -d "$VP_DIR/.git" ]; then
        git -C "$VP_DIR" reset --hard HEAD 2>&1 | tail -1
        git -C "$VP_DIR" clean -fdx 2>&1 | tail -1
        log_ok "VibePascal working tree reset + cleaned ($VP_DIR)"
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
        [ "$BUILD_IDE" -eq 1 ] && args+=("--build-ide")
        [ "$FORCE_REBUILD" -eq 1 ] && args+=("--force-rebuild")
        [ "$DOCTOR" -eq 1 ] && args+=("--doctor")
        exec "$script_path" "${args[@]}"
    fi
}

check_vp_updates() {
    log_header "Checking VibePascal (adaloveless/vibepascal)"

    if [ ! -d "$VP_DIR/.git" ]; then
        log_err "VibePascal repo not found at $VP_DIR"
        return 1
    fi

    local before=$(git -C "$VP_DIR" rev-parse HEAD)
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
    # If ff-only pull fails (local branch diverged from origin/main), reset to origin/main.
    # This recovers from the pinning bug where a stale local commit left VP stuck on an old version
    # (GOD mrghu0l5; Finn/ZENBOOK r23 win64 smoke: --ff-only failure + no fallback = pinned forever).
    if ! git -C "$VP_DIR" pull --ff-only origin main 2>&1; then
        log_warn "VP --ff-only pull failed; reset --hard origin/main (pristine mode)"
        git -C "$VP_DIR" reset --hard origin/main || { log_err "VP reset failed"; return 1; }
    fi
    log_ok "VibePascal pulled successfully"

    # LATEST.txt sidecar (GOD mrghu0l5): report current version/source_commit for diagnostics.
    # Linux clients build from source after pull, so no extraction needed -- but the info confirms
    # Otto's latest-pointer is in sync with what we just pulled. LATEST.txt becomes the authoritative
    # version SELECTOR while split-archive pairing stays intact on Windows side.
    local_latest="$VP_DIR/dist/win64/LATEST.txt"
    if [ -f "$local_latest" ]; then
        log_info "LATEST.txt present: $(grep -E '^version:|^source_commit:' "$local_latest" 2>/dev/null | head -2)"
    fi
}

check_lazarus_upstream() {
    log_header "Checking Lazarus upstream (fpc/Lazarus)"

    local behind=$(git -C "$LAZARUS_DIR" rev-list --count HEAD..upstream/main 2>/dev/null || echo "0")

    local local_commits=$(git -C "$LAZARUS_DIR" rev-list --count upstream/main..HEAD 2>/dev/null || echo "0")

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
            git -C "$LAZARUS_DIR" reset --hard origin/main || { log_err "Lazarus reset failed"; return 1; }
        fi
        log_ok "Lazarus origin pulled"
    fi
}

rebuild_vp_packages() {
    log_header "Rebuilding VibePascal packages (x86_64-linux)"

    if [ ! -f "$VP_COMPILER" ]; then
        log_err "VibePascal compiler not found at $VP_COMPILER"
        log_err "Build the compiler first: cd $VP_DIR && make compiler"
        return 1
    fi

    local rtl_units="$VP_DIR/rtl/units/x86_64-linux"
    if [ ! -d "$rtl_units" ]; then
        log_info "Building VibePascal RTL..."
        make -C "$VP_DIR" rtl PP="$VP_COMPILER" OPT="-n @$LINUX_CFG" 2>&1 | tail -3
    fi

    log_info "Building VibePascal packages..."
    make -C "$VP_DIR" packages PP="$VP_COMPILER" OPT="-n @$LINUX_CFG" 2>&1 | grep -cE "Compiling" | xargs -I{} echo "  Compiled {} units"
    log_ok "VibePascal packages rebuilt"
}

rebuild_lazbuild() {
    log_header "Rebuilding lazbuild"

    local pre_mtime=""
    if [ -f "$LAZARUS_DIR/lazbuild" ]; then
        pre_mtime=$(stat -c %Y "$LAZARUS_DIR/lazbuild" 2>/dev/null || stat -f %m "$LAZARUS_DIR/lazbuild" 2>/dev/null)
    fi

    make -C "$LAZARUS_DIR" clean 2>&1 | tail -1

    make -C "$LAZARUS_DIR" lazbuild \
        PP="$VP_COMPILER" \
        FPCDIR="$VP_DIR" \
        OPT="-n @$LINUX_CFG" 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
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

print_summary() {
    log_header "Update Summary"

    local changes=0

    if [ "$VP_UPDATED" -eq 1 ]; then
        echo -e "  ${GREEN}✓${NC} VibePascal updated"
        changes=1
    else
        echo -e "  ${CYAN}-${NC} VibePascal: no changes"
    fi

    if [ "$UPSTREAM_UPDATED" -eq 1 ]; then
        echo -e "  ${GREEN}✓${NC} Lazarus upstream synced"
        changes=1
    else
        echo -e "  ${CYAN}-${NC} Lazarus upstream: no changes"
    fi

    if [ "$LAZARUS_UPDATED" -eq 1 ]; then
        echo -e "  ${GREEN}✓${NC} Lazarus updated"
        changes=1
    else
        echo -e "  ${CYAN}-${NC} Lazarus: no changes"
    fi

    if [ "$changes" -eq 0 ]; then
        echo ""
        log_ok "Everything is up to date. Nothing to do."
    fi

    echo ""
    echo "Lazarus HEAD: $(git -C "$LAZARUS_DIR" log --oneline -1)"
    echo "VibePascal HEAD: $(git -C "$VP_DIR" log --oneline -1)"
}

configure_environment() {
    log_header "Configuring Lazarus IDE for VibePascal"

    local env_dir="$HOME/.lazarus"
    local env_file="$env_dir/environmentoptions.xml"

    mkdir -p "$env_dir"

    if [ -f "$env_file" ]; then
        log_info "Patching existing environmentoptions.xml"
        if command -v xmlstarlet &>/dev/null; then
            xmlstarlet ed -L \
                -u '//CompilerFilename/@Value' -v "$VP_COMPILER" \
                -u '//FPCSourceDirectory/@Value' -v "$VP_DIR" \
                "$env_file"
            log_ok "Updated $env_file via xmlstarlet"
        else
            sed -i "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$VP_COMPILER\"|" "$env_file"
            sed -i "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$VP_DIR\"|" "$env_file"
            log_ok "Updated $env_file via sed"
        fi
    else
        log_info "Creating new environmentoptions.xml"
        local template="$LAZARUS_DIR/tools/install/linux/environmentoptions.xml"
        if [ -f "$template" ]; then
            cp "$template" "$env_file"
            sed -i "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$VP_COMPILER\"|" "$env_file"
            sed -i "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$VP_DIR\"|" "$env_file"
            sed -i "s|LazarusDirectory Value=\"[^\"]*\"|LazarusDirectory Value=\"$LAZARUS_DIR\"|" "$env_file"
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
    for cand in "$COMMONX_DIR" "$(dirname "$LAZARUS_DIR")/commonx" "$HOME/src/commonx"; do
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

# Identifies the material an install attempt was made against (Lazarus commit + commonx
# revision), so the self-heal retry fires only when something has actually CHANGED.
commonx_stamp_path() {
    printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/lazarus-commonx-install-attempt.txt"
}
get_commonx_install_stamp() {
    local laz_head="" cx_rev="" cx_root=""
    laz_head=$(git -C "$LAZARUS_DIR" rev-parse HEAD 2>/dev/null || printf '')
    if cx_root=$(get_commonx_root 2>/dev/null) && command -v svn >/dev/null 2>&1; then
        cx_rev=$(svn info "$cx_root" 2>/dev/null | sed -n 's/^Revision:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    fi
    printf '%s|%s' "$laz_head" "$cx_rev"
}

rebuild_ide() {
    log_header "Rebuilding Lazarus IDE"

    if [ ! -f "$LAZARUS_DIR/lazbuild" ]; then
        log_err "lazbuild not found -- cannot build IDE. Run rebuild first."
        return 1
    fi

    local ws=""
    if pkg-config --exists gtk+-2.0 2>/dev/null; then
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

    if [ -n "$commonx_root" ]; then
        local commonx_lpk
        commonx_lpk=$(find "$commonx_root" -name 'PackageCommonX_LCL.lpk' -print -quit 2>/dev/null)
        if [ -n "$commonx_lpk" ]; then
            commonx_lpk_path="$commonx_lpk"
            add_pkg_lpks="$add_pkg_lpks $commonx_lpk"
            log_info "Including commonx LCL controls incl. TTouchButton ($commonx_lpk)"
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
    "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --build-ide= \
        --compiler="$VP_COMPILER" --ws="$ws" $add_pkg_args 2>&1 | tee "$cx_build_log" | grep -E "Linking|lines compiled|Fatal|Error"
    local build_exit=${PIPESTATUS[0]}
    if [ "$build_exit" -ne 0 ]; then
        COMMONX_FIRST_ERROR=$(grep -m1 -E "(Error|Fatal):" "$cx_build_log" 2>/dev/null)
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
        "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --build-ide= \
            --compiler="$VP_COMPILER" --ws="$ws" $fallback_args 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
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

    local vp_cfg="$VP_DIR/bin/fpc.cfg"
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
        mtime=$(stat -c '%y' "$lazarus_bin" 2>/dev/null | cut -d. -f1)
        [ -z "$mtime" ] && mtime=$(stat -f '%Sm' "$lazarus_bin" 2>/dev/null)
        log_ok "lazarus binary: $lazarus_bin ($mtime)"
    else
        log_warn "lazarus binary not built yet (run --build-ide)"
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
                    sed -i 's|UnitOutputDirectory Value="[^"]*"|UnitOutputDirectory Value="lib"|g' "$lpi"
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

git -C "$LAZARUS_DIR" fetch upstream 2>/dev/null

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

if [ "$ANY_UPDATED" -eq 1 ]; then
    if [ "$NO_BUILD" -eq 1 ]; then
        log_info "Skipping rebuild (--no-build)"
    else
        if [ "$VP_UPDATED" -eq 1 ]; then
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
