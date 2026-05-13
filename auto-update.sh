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
        --help|-h)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_header(){ echo -e "\n${CYAN}=== $1 ===${NC}"; }

ensure_self_clean() {
    local script_name="auto-update.sh"
    local status
    status=$(git -C "$LAZARUS_DIR" status --porcelain -- "$script_name" 2>/dev/null || true)
    if [ -n "$status" ]; then
        log_warn "auto-update.sh has local modifications -- restoring upstream version"
        git -C "$LAZARUS_DIR" checkout -- "$script_name" 2>/dev/null && \
            log_ok "Restored clean auto-update.sh from git" || \
            log_err "Failed to restore auto-update.sh"
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
    git -C "$VP_DIR" pull --ff-only origin main 2>&1
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
        log_header "Pulling Lazarus origin changes"
        git -C "$LAZARUS_DIR" pull --ff-only origin main 2>&1
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
    local customdrawn_lpk="$LAZARUS_DIR/components/customdrawn/customdrawn.lpk"
    local add_pkg_args=""
    if [ -f "$customdrawn_lpk" ]; then
        add_pkg_args="--add-package $customdrawn_lpk"
        log_info "Including customdrawn LCL controls (--add-package)"
    else
        log_info "customdrawn.lpk not found at $customdrawn_lpk -- skipping --add-package"
    fi

    "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --build-ide= \
        --compiler="$VP_COMPILER" --ws="$ws" $add_pkg_args 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
    local build_exit=${PIPESTATUS[0]}

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

ensure_self_clean
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
