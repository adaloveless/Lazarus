#!/bin/bash
# auto-update-mac.sh -- macOS (darwin) sibling of auto-update.sh (Linux) and
# auto-update.bat/.ps1 (Windows). Pulls VibePascal + Lazarus updates and
# rebuilds lazbuild on a pristine macOS test env.
#
# Darwin is self-hosted (no cross-compile wrapper like build-release.sh):
# the native compiler binary in the VP tree is used directly. aarch64-darwin
# (Apple Silicon) builds name it ppc1, x86_64-darwin builds name it ppcx64.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAZARUS_DIR="$SCRIPT_DIR"
VP_DIR="${VP_DIR:-$HOME/source/vibepascal}"
HOST_ARCH="$(uname -m)"
SDK_PATH=""

case "$HOST_ARCH" in
    arm64)
        TARGET="aarch64-darwin"
        MAC_CFG="$VP_DIR/vibepascal-darwin-aarch64.cfg"
        ;;
    x86_64)
        TARGET="x86_64-darwin"
        MAC_CFG="$VP_DIR/vibepascal-darwin-x86_64.cfg"
        ;;
    *)
        echo "auto-update-mac.sh: unsupported architecture: $HOST_ARCH" >&2
        exit 1
        ;;
esac

VP_COMPILER="${VP_COMPILER:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LAZARUS_UPDATED=0
VP_UPDATED=0
UPSTREAM_UPDATED=0

usage() {
    echo "Lazarus + VibePascal Auto-Updater (macOS)"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --check         Check for updates only (no pull, no build)"
    echo "  --no-build      Pull updates but skip rebuild"
    echo "  --release       Also rebuild release tarballs after updating"
    echo "  --upstream-only  Only sync upstream Lazarus (skip VibePascal)"
    echo "  --setup         Configure Lazarus IDE to use VibePascal compiler"
    echo "  --fix-lpi       Scan and fix .lpi files (set UnitOutputDirectory to 'lib')"
    echo "  --build-ide     Also rebuild the full Lazarus IDE (Cocoa widgetset)"
    echo "  --force-rebuild  Force rebuild even if no updates are available"
    echo "  --doctor         Run diagnostics (no state changes); exit 1 if problems found"
    echo "  --help           Show this help"
    echo ""
    echo "Default: pull updates and rebuild lazbuild if anything changed."
    echo ""
    echo "Environment:"
    echo "  VP_DIR        VibePascal source tree (default: \$HOME/source/vibepascal)"
    echo "  VP_COMPILER   VibePascal compiler binary (default: auto-detected in VP tree)"
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

# macOS ships no GNU coreutils: sha256sum is absent, but shasum is always
# present. Some third-party installs rename shasum to sha256sum; keep both.
sha256_of() {
    local f="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$f" 2>/dev/null | cut -d' ' -f1
    else
        shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1
    fi
}

# The self-hosted compiler name differs by architecture and by how the VP tree
# was built (`make build` produces ppc1; install/rename produces ppca64 on
# Apple Silicon, ppcx64 on Intel). Detect whichever exists.
find_vp_compiler() {
    local candidates=""
    if [ "$HOST_ARCH" = "arm64" ]; then
        candidates="$VP_DIR/compiler/ppc1 $VP_DIR/compiler/ppcaarch64 $VP_DIR/compiler/ppca64"
    else
        candidates="$VP_DIR/compiler/ppcx64 $VP_DIR/compiler/ppc1"
    fi
    local c
    for c in $candidates; do
        if [ -x "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

if [ -n "$VP_COMPILER" ]; then
    :
elif VP_COMPILER=$(find_vp_compiler); then
    :
else
    VP_COMPILER=""
fi

# GOD mp8g1me3 (2026-05-16): auto-update is for pristine test envs, not local dev.
# Wipe ALL local changes (tracked + untracked) so test machines pull cleanly.
# If you are a developer with local work, do NOT run auto-update-mac.sh -- use git directly.
wipe_local_changes() {
    log_header "Wiping local changes (pristine test-env mode)"
    log_warn "auto-update-mac.sh discards ALL uncommitted changes and untracked files."
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
    local script_path="$LAZARUS_DIR/auto-update-mac.sh"
    local post_hash
    post_hash=$(sha256_of "$script_path")
    if [ -n "$pre_hash" ] && [ "$pre_hash" != "$post_hash" ]; then
        log_info "auto-update-mac.sh was updated by pull -- relaunching with new version"
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

# Generate a VP-tree-local fpc.cfg for $TARGET. The VP compiler has no baked-in
# unit search path on macOS (it relies on an fpc.cfg), and the existing
# hand-written ~/.fpc.cfg points at the installed release app, not the source
# tree. Sibling of build-release.sh's DARWIN_*_CFG. Idempotent: creates the base
# file on first call, then appends -Fu lines for package/utils units as those
# dirs appear (FPC's '*' includes all subdirectories -- same trick ~/.fpc.cfg
# uses; missing dirs are harmless).
ensure_mac_cfg() {
    if [ ! -f "$MAC_CFG" ]; then
        log_header "Generating $MAC_CFG"

        if [ -z "$SDK_PATH" ]; then
            SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
            if [ -z "$SDK_PATH" ] || [ ! -d "$SDK_PATH" ]; then
                SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
            fi
        fi

        local rtl_units="$VP_DIR/rtl/units/$TARGET"
        local compiler_dir
        compiler_dir="$(dirname "$VP_COMPILER")"

        cat > "$MAC_CFG" << EOF
# Auto-generated by auto-update-mac.sh ($(date +%Y-%m-%d)).
# Points the VibePascal compiler at its in-tree RTL and at the macOS SDK so
# libc / frameworks resolve, and forces the classic linker (-k-ld_classic):
# Apple's new linker (Xcode 15+) rejects FPC's Objective-C method-list layout
# with "malformed method list atom". Mirrors ~/.fpc.cfg which the installed
# release app used to carry.

-Fu$rtl_units
-Fi$rtl_units
-FD$compiler_dir

-XR$SDK_PATH
-k-syslibroot
-k$SDK_PATH
-k-ld_classic
EOF
        log_ok "Generated $MAC_CFG"
    fi

    # Refresh -Fu lines for package/utils units as their dirs appear post-build.
    local extra_dir
    for extra_dir in "$VP_DIR/packages/units/$TARGET" "$VP_DIR/utils/units/$TARGET"; do
        if [ -d "$extra_dir" ] && ! grep -qF -- "-Fu$extra_dir/*" "$MAC_CFG"; then
            echo "-Fu$extra_dir/*" >> "$MAC_CFG"
            log_info "Added $extra_dir unit path to $MAC_CFG"
        fi
    done
    return 0
}

# git clean -fdx in wipe_local_changes deletes the native compiler (ppc1 is a
# gitignored build artifact), so after a pristine pull there is NO compiler and
# nothing to rebuild with. Rebuild it from the VP source tree using any working
# fpc (Homebrew /usr fpc are tried, or set FPC_BOOTSTRAP).
ensure_vp_compiler() {
    if [ -n "$VP_COMPILER" ] && [ -x "$VP_COMPILER" ]; then
        return 0
    fi

    log_header "Bootstrapping VibePascal compiler (had no built binary)"
    local bootstrap=""
    local b
    for b in "$FPC_BOOTSTRAP" /opt/homebrew/bin/fpc /usr/local/bin/fpc /usr/bin/fpc fpc; do
        if [ -n "$b" ] && command -v "$b" >/dev/null 2>&1 && "$b" -iV >/dev/null 2>&1; then
            bootstrap="$(command -v "$b")"
            break
        fi
    done
    if [ -z "$bootstrap" ]; then
        log_err "No bootstrap fpc found to rebuild the VibePascal compiler."
        log_err "Install one (e.g. brew install fpc) or set FPC_BOOTSTRAP."
        return 1
    fi

    log_info "Bootstrap compiler: $bootstrap ($("$bootstrap" -iV 2>/dev/null))"
    log_info "Building VP compiler (this takes a while)..."
    if ! make -C "$VP_DIR" compiler FPC="$bootstrap" 2>&1 | tail -30; then
        log_err "VP compiler build failed"
        return 1
    fi
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        log_err "VP compiler build failed"
        return 1
    fi

    if ! VP_COMPILER=$(find_vp_compiler); then
        log_err "Compiler build produced no binary under $VP_DIR/compiler"
        return 1
    fi
    log_ok "VibePascal compiler built: $VP_COMPILER"
    return 0
}

# The wiped tree also lost rtl/units; lazbuild/IDE need system.ppu and friends
# before anything compiles. Build the RTL with the (re)built compiler.
ensure_vp_rtl() {
    ensure_vp_compiler || return 1
    ensure_mac_cfg || return 1

    local rtl_units="$VP_DIR/rtl/units/$TARGET"
    if [ -d "$rtl_units" ]; then
        return 0
    fi

    log_header "Building VibePascal RTL ($TARGET)"
    if ! make -C "$VP_DIR" rtl PP="$VP_COMPILER" OPT="-n @$MAC_CFG" 2>&1 | tail -20; then
        log_err "RTL build failed"
        return 1
    fi
    if [ ! -d "$rtl_units" ]; then
        log_err "RTL build failed -- no units at $rtl_units"
        return 1
    fi
    log_ok "VibePascal RTL built"
    return 0
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
        # This fork carries its own IDE/build changes, so a plain merge hits
        # conflicts whenever upstream rewrote the same files (upstream even
        # deleted lcl/Makefile* which this fork's make-based build still uses).
        # -X ours keeps the fork side on overlapping hunks; resolve_ours_conflicts
        # finishes the merge for the add/delete cases -X ours cannot decide.
        log_info "Merging upstream into local branch ($local_commits local commit(s) preserved)..."
        git -C "$LAZARUS_DIR" merge --no-edit -X ours upstream/main 2>&1 || resolve_ours_conflicts
        log_ok "Merge from upstream complete"
    fi

    # Fold in any commits other developers pushed to origin that upstream/main
    # does not contain (upstream merged one side of history, origin the other),
    # so the push below is a clean fast-forward of origin/main. No-op when local
    # already descends from origin/main; without this the push would be rejected
    # as non-fast-forward and abort the auto-update.
    git -C "$LAZARUS_DIR" merge --no-edit -X ours origin/main 2>&1 || resolve_ours_conflicts

    log_info "Pushing to origin..."
    git -C "$LAZARUS_DIR" push origin main 2>&1
    log_ok "Pushed to adaloveless/Lazarus"
    LAZARUS_UPDATED=1
}

# git leaves add/delete (modify/delete) conflicts hanging even after -X ours,
# which would wedge an unattended auto-update. Prefer the fork version of every
# remaining conflicted path, then commit the in-progress merge. Returns non-zero
# only if the merge still cannot be completed.
resolve_ours_conflicts() {
    local conflicted
    conflicted=$(git -C "$LAZARUS_DIR" ls-files -u 2>/dev/null | awk '{print $4}' | sort -u)
    if [ -n "$conflicted" ]; then
        log_warn "Resolving $(echo "$conflicted" | wc -l | tr -d ' ') conflicted path(s) in favor of the fork version"
        local f
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            git -C "$LAZARUS_DIR" checkout --ours -- "$f" 2>/dev/null
            git -C "$LAZARUS_DIR" add -- "$f"
        done <<< "$conflicted"
    fi
    if [ -f "$LAZARUS_DIR/.git/MERGE_HEAD" ]; then
        git -C "$LAZARUS_DIR" commit --no-edit 2>&1 || return 1
    fi
    return 0
}

pull_lazarus_origin() {
    if [ "$LAZARUS_UPDATED" -eq 1 ] && [ "$UPSTREAM_UPDATED" -eq 0 ]; then
        log_header "Pulling Lazarus origin changes"
        # If HEAD already carries a fresh upstream merge, origin/main diverged
        # from it and ff-only/reset --hard origin/main would silently DROP that
        # merge. Merge origin in instead (fork-preferring on conflict). Plain
        # pristine envs (no upstream merge) keep the old ff-only + reset fallback.
        if git -C "$LAZARUS_DIR" merge-base --is-ancestor upstream/main HEAD 2>/dev/null; then
            git -C "$LAZARUS_DIR" merge --no-edit -X ours origin/main 2>&1 || resolve_ours_conflicts
            log_ok "Lazarus origin merged"
        else
            if ! git -C "$LAZARUS_DIR" pull --ff-only origin main 2>&1; then
                log_warn "Lazarus --ff-only pull failed; reset --hard origin/main (pristine mode)"
                git -C "$LAZARUS_DIR" reset --hard origin/main || { log_err "Lazarus reset failed"; return 1; }
            fi
            log_ok "Lazarus origin pulled"
        fi
    fi
}

rebuild_vp_packages() {
    log_header "Rebuilding VibePascal packages ($TARGET)"

    ensure_vp_compiler || return 1
    ensure_vp_rtl || return 1

    log_info "Building VibePascal packages..."
    make -C "$VP_DIR" packages PP="$VP_COMPILER" OPT="-n @$MAC_CFG" 2>&1 | grep -cE "Compiling" | xargs -I{} echo "  Compiled {} units"
    log_ok "VibePascal packages rebuilt"
}

rebuild_lazbuild() {
    log_header "Rebuilding lazbuild"

    ensure_mac_cfg || return 1

    local pre_mtime=""
    if [ -f "$LAZARUS_DIR/lazbuild" ]; then
        pre_mtime=$(stat -c %Y "$LAZARUS_DIR/lazbuild" 2>/dev/null || stat -f %m "$LAZARUS_DIR/lazbuild" 2>/dev/null)
    fi

    make -C "$LAZARUS_DIR" clean 2>&1 | tail -1

    make -C "$LAZARUS_DIR" lazbuild \
        PP="$VP_COMPILER" \
        FPCDIR="$VP_DIR" \
        OPT="-n @$MAC_CFG" 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
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
    echo "Lazarus HEAD: $(git -C "$LAZARUS_DIR" log --oneline -1 2>/dev/null)"
    echo "VibePascal HEAD: $(git -C "$VP_DIR" log --oneline -1 2>/dev/null)"
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
            sed -i '' "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$VP_COMPILER\"|" "$env_file"
            sed -i '' "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$VP_DIR\"|" "$env_file"
            log_ok "Updated $env_file via sed"
        fi
    else
        log_info "Creating new environmentoptions.xml"
        local template="$LAZARUS_DIR/tools/install/macosx/environmentoptions.xml"
        if [ ! -f "$template" ]; then
            template="$LAZARUS_DIR/tools/install/linux/environmentoptions.xml"
        fi
        if [ -f "$template" ]; then
            cp "$template" "$env_file"
            sed -i '' "s|CompilerFilename Value=\"[^\"]*\"|CompilerFilename Value=\"$VP_COMPILER\"|" "$env_file"
            sed -i '' "s|FPCSourceDirectory Value=\"[^\"]*\"|FPCSourceDirectory Value=\"$VP_DIR\"|" "$env_file"
            sed -i '' "s|LazarusDirectory Value=\"[^\"]*\"|LazarusDirectory Value=\"$LAZARUS_DIR\"|" "$env_file"
            log_ok "Created $env_file from template"
        else
            log_err "Template not found at $template"
            return 1
        fi
    fi

    log_ok "IDE configured to use VibePascal. Restart Lazarus to apply."
}

rebuild_ide() {
    log_header "Rebuilding Lazarus IDE (Cocoa)"

    if [ ! -f "$LAZARUS_DIR/lazbuild" ]; then
        log_err "lazbuild not found -- cannot build IDE. Run rebuild first."
        return 1
    fi

    ensure_mac_cfg || return 1

    # Native darwin build: no pkg-config/widgetset probing like the Linux
    # script (GTK2/Qt5). Cocoa is the only ws. lazbuild must get the cfg too,
    # so wrap the compiler exactly like build-release.sh's build_darwin_ide:
    # without it lazbuild reports "system.ppu not found" on its -i*/-va probes.
    local wrapper="/tmp/ppc$(echo "$TARGET" | cut -d- -f1)-darwin-wrapper"
    cat > "$wrapper" << EOF
#!/bin/bash
exec $VP_COMPILER -n @$MAC_CFG "\$@"
EOF
    chmod +x "$wrapper"

    local ws="cocoa"

    log_info "Building IDE with widgetset: $ws"

    local pre_mtime=""
    if [ -f "$LAZARUS_DIR/lazarus" ]; then
        pre_mtime=$(stat -c %Y "$LAZARUS_DIR/lazarus" 2>/dev/null || stat -f %m "$LAZARUS_DIR/lazarus" 2>/dev/null)
    fi

    # GOD mp3nzr3r: ensure customdrawn LCL controls are installed by default on
    # every site, so users do not need to run `lazbuild --add-package` manually.
    # --build-ide (not --build-ide-minimal) is required because TBuildIDE.Minimal
    # skips LoadAutoInstallPackages.
    local add_pkg_lpks=""
    local customdrawn_lpk="$LAZARUS_DIR/components/customdrawn/customdrawn.lpk"
    local add_pkg_args=""
    if [ -f "$customdrawn_lpk" ]; then
        add_pkg_lpks="$customdrawn_lpk"
        log_info "Including customdrawn LCL controls (--add-package)"
    else
        log_info "customdrawn.lpk not found at $customdrawn_lpk -- skipping"
    fi

    # GOD mrxnqj9g / mrxnwdze (2026-07-23): TTouchButton is GOD's OWN component, shipped
    # in the commonx LCL package set, which must be installed by auto-update or GOD's
    # components go missing from the designer palette. Parity with auto-update.ps1.
    # ONLY PackageCommonX_LCL -- commonx's BGRABitmap/LazActiveX duplicate this fork's
    # in-tree components/ copies and would trigger duplicate-unit install failures (#182).
    local commonx_root=""
    local commonx_lpk_path=""
    for cand in "$COMMONX_DIR" "$(dirname "$LAZARUS_DIR")/commonx" "$HOME/src/commonx"; do
        if [ -n "$cand" ] && [ -d "$cand" ]; then commonx_root="$cand"; break; fi
    done
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

    # ONE switch, then every collected path (see contract note in auto-update.sh).
    if [ -n "$add_pkg_lpks" ]; then
        add_pkg_args="--add-package $add_pkg_lpks"
    fi

    set -o pipefail
    "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --build-ide= \
        --compiler="$wrapper" --ws="$ws" $add_pkg_args 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
    local build_exit=${PIPESTATUS[0]}
    set +o pipefail

    # GOD mrxp2wpx (2026-07-23): parity with auto-update.ps1 -- an OPTIONAL THIRD-PARTY
    # package must NEVER be able to take the whole IDE down. Keep this retry regardless of
    # whether the original cause is fixed: the guarantee is "worst case = a missing
    # component, never a missing IDE". See auto-update.sh for the full original-cause note.
    if [ "$build_exit" -ne 0 ] && [ -n "$commonx_lpk_path" ]; then
        log_warn "IDE build failed with commonx included; retrying WITHOUT commonx so the IDE still builds."
        local kept_lpks=""
        local p
        for p in $add_pkg_lpks; do
            if [ "$p" != "$commonx_lpk_path" ]; then kept_lpks="$kept_lpks $p"; fi
        done
        kept_lpks="${kept_lpks# }"
        local fallback_args=""
        if [ -n "$kept_lpks" ]; then fallback_args="--add-package $kept_lpks"; fi
        set -o pipefail
        "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --build-ide= \
            --compiler="$wrapper" --ws="$ws" $fallback_args 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
        build_exit=${PIPESTATUS[0]}
        set +o pipefail
        if [ "$build_exit" -eq 0 ]; then
            log_warn "IDE built WITHOUT commonx LCL packages -- TTouchButton is MISSING from the palette (see cause above)."
        fi
    fi

    rm -f "$wrapper"

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
}

test_ide_package_lpk_consistency() {
    # Mirrors Test-IdePackageLpkConsistency in auto-update.ps1 (cycle 232 / #114).
    # Static mirror of the "Unit 'X' was not found in the lpk file" check from
    # ide/packages/idepackager/packagesystem.pas; see auto-update.sh.
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
        log_err "  Fix: cd $LAZARUS_DIR && git pull && ./auto-update-mac.sh --force-rebuild"
        return 1
    fi
}

invoke_doctor() {
    log_header "Lazarus + VibePascal Doctor (macOS)"
    local problems=0

    log_info "Lazarus directory: $LAZARUS_DIR"
    if [ -d "$LAZARUS_DIR/lcl" ] && [ -d "$LAZARUS_DIR/ide" ] && [ -d "$LAZARUS_DIR/components" ]; then
        log_ok "Lazarus dir structure: lcl/ ide/ components/ all present"
    else
        log_err "Lazarus dir incomplete: missing one of lcl/ ide/ components/"
        problems=$((problems + 1))
    fi

    log_info "VibePascal directory: $VP_DIR"
    if [ -n "$VP_COMPILER" ] && [ -x "$VP_COMPILER" ]; then
        log_ok "VibePascal compiler: $VP_COMPILER"
    else
        log_err "VibePascal compiler not found (looked under $VP_DIR/compiler)"
        problems=$((problems + 1))
    fi

    local vp_cfg="$MAC_CFG"
    if [ -f "$vp_cfg" ]; then
        log_ok "VibePascal cfg: $vp_cfg"
    else
        log_warn "VibePascal cfg not found at $vp_cfg (run --force-rebuild to generate)"
    fi

    local rtl_units="$VP_DIR/rtl/units/$TARGET"
    if [ -d "$rtl_units" ]; then
        log_ok "VibePascal RTL units: $rtl_units"
    else
        log_warn "VibePascal RTL units not built at $rtl_units"
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
        log_info "  2. ./auto-update-mac.sh --force-rebuild"
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
                    sed -i '' 's|UnitOutputDirectory Value="[^"]*"|UnitOutputDirectory Value="lib"|g' "$lpi"
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

log_header "Lazarus + VibePascal Auto-Updater (macOS $TARGET)"
echo "  Lazarus:    $LAZARUS_DIR"
echo "  VibePascal: $VP_DIR"
echo "  Compiler:   $VP_COMPILER"
echo "  Cfg:        $MAC_CFG"
echo ""

SCRIPT_PRE_HASH=$(sha256_of "$LAZARUS_DIR/auto-update-mac.sh")

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

if [ "$ANY_UPDATED" -eq 1 ]; then
    if [ "$NO_BUILD" -eq 1 ]; then
        log_info "Skipping rebuild (--no-build)"
    else
        # The pristine wipe removed the gitignored compiler + RTL even when
        # VibePascal itself had no new commits -- rebuild them unconditionally
        # so lazbuild/IDE always have system.ppu and a working compiler.
        if ! ensure_vp_compiler || ! ensure_vp_rtl; then
            exit 1
        fi
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
