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
    echo "  --help           Show this help"
    echo ""
    echo "Default: pull updates and rebuild lazbuild if anything changed."
    exit 0
}

CHECK_ONLY=0
NO_BUILD=0
BUILD_RELEASE=0
UPSTREAM_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_ONLY=1; shift ;;
        --no-build)    NO_BUILD=1; shift ;;
        --release)     BUILD_RELEASE=1; shift ;;
        --upstream-only) UPSTREAM_ONLY=1; shift ;;
        --help|-h)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_header(){ echo -e "\n${CYAN}=== $1 ===${NC}"; }

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
        log_info "Rebasing $local_commits local commit(s) onto upstream..."
        git -C "$LAZARUS_DIR" rebase upstream/main 2>&1
        log_ok "Rebase onto upstream complete"
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

    make -C "$LAZARUS_DIR" clean 2>&1 | tail -1

    make -C "$LAZARUS_DIR" lazbuild \
        PP="$VP_COMPILER" \
        FPCDIR="$VP_DIR" \
        OPT="-n @$LINUX_CFG" 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"

    if [ -f "$LAZARUS_DIR/lazbuild" ]; then
        local size=$(du -sh "$LAZARUS_DIR/lazbuild" | cut -f1)
        log_ok "lazbuild rebuilt ($size)"
    else
        log_err "lazbuild build failed!"
        return 1
    fi
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

log_header "Lazarus + VibePascal Auto-Updater"
echo "  Lazarus:    $LAZARUS_DIR"
echo "  VibePascal: $VP_DIR"
echo "  Compiler:   $VP_COMPILER"
echo ""

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

if [ "$VP_UPDATED" -eq 1 ] || [ "$LAZARUS_UPDATED" -eq 1 ] || [ "$UPSTREAM_UPDATED" -eq 1 ]; then
    if [ "$NO_BUILD" -eq 1 ]; then
        log_info "Skipping rebuild (--no-build)"
    else
        if [ "$VP_UPDATED" -eq 1 ]; then
            rebuild_vp_packages
        fi
        rebuild_lazbuild
        if [ "$BUILD_RELEASE" -eq 1 ]; then
            log_header "Building release tarballs"
            "$LAZARUS_DIR/build-release.sh" all
        fi
    fi
fi

print_summary
