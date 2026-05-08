#!/bin/bash
set -e

LAZARUS_DIR="$(cd "$(dirname "$0")" && pwd)"
VP_DIR="/home/jason/src/vibepascal"
RELEASE_DIR="$LAZARUS_DIR/releases"
LAZARUS_VERSION="4.99-vp"
DATE_STAMP=$(date +%Y%m%d)

LINUX_CFG="$VP_DIR/vibepascal-linux-x86_64.cfg"
WIN64_CFG="$VP_DIR/vibepascal-win64-x86_64.cfg"
AARCH64_LINUX_CFG="$VP_DIR/vibepascal-aarch64-linux.cfg"
ARM_LINUX_CFG="$VP_DIR/vibepascal-arm-linux.cfg"
DARWIN_X86_64_CFG="$VP_DIR/vibepascal-darwin-x86_64.cfg"
DARWIN_AARCH64_CFG="$VP_DIR/vibepascal-darwin-aarch64.cfg"

get_compiler_for_target() {
    local target=$1
    case "$target" in
        x86_64-linux|x86_64-win64|x86_64-darwin)
            echo "$VP_DIR/compiler/ppcx64"
            ;;
        aarch64-linux|aarch64-darwin)
            echo "$VP_DIR/compiler/ppcrossaarch64"
            ;;
        arm-linux)
            echo "$VP_DIR/compiler/ppcrossarm"
            ;;
        *)
            echo "$VP_DIR/compiler/ppcx64"
            ;;
    esac
}

usage() {
    echo "Usage: $0 [linux|win64|pi64|pi32|osx64|osxarm|all]"
    echo "  linux  - Build Lazarus for x86_64-linux"
    echo "  win64  - Build Lazarus for x86_64-win64 (cross-compile)"
    echo "  pi64   - Build Lazarus for aarch64-linux (Pi 4/5)"
    echo "  pi32   - Build Lazarus for arm-linux (Pi 3 and older)"
    echo "  osx64  - Build Lazarus for x86_64-darwin (macOS Intel)"
    echo "  osxarm - Build Lazarus for aarch64-darwin (macOS Apple Silicon)"
    echo "  all    - Build for all platforms"
    exit 1
}

ensure_vp_packages() {
    local target=$1
    local cfg=$2
    local compiler=$(get_compiler_for_target "$target")
    local rtl_units="$VP_DIR/rtl/units/$target"

    if [ ! -d "$rtl_units" ]; then
        echo "ERROR: VibePascal RTL units not found for $target"
        echo "Build VibePascal RTL first: cd $VP_DIR && make rtl PP=$compiler OS_TARGET=... CPU_TARGET=..."
        exit 1
    fi

    local pkg_count=$(find "$VP_DIR/packages" -type d -name "$target" -path "*/units/*" 2>/dev/null | wc -l)
    if [ "$pkg_count" -lt 10 ]; then
        echo "Only $pkg_count VibePascal packages found for $target. Building packages..."
        cd "$VP_DIR"
        local os_target=$(echo "$target" | cut -d- -f2)
        local cpu_target=$(echo "$target" | cut -d- -f1)
        make packages PP="$compiler" OS_TARGET="$os_target" CPU_TARGET="$cpu_target" OPT="-n @$cfg" 2>&1 | grep -E "^\[|Compiled package|Fatal|Error" || true
        cd "$LAZARUS_DIR"
    fi
    echo "VibePascal packages ready for $target ($pkg_count packages)"
}

build_lazbuild() {
    local target=$1
    local cfg=$2
    local compiler=$(get_compiler_for_target "$target")

    echo "=== Building lazbuild for $target ==="
    local os_target=$(echo "$target" | cut -d- -f2)
    local cpu_target=$(echo "$target" | cut -d- -f1)

    make -C "$LAZARUS_DIR" lazbuild \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        OPT="-n @$cfg" 2>&1 | grep -E "Linking|lines compiled|Fatal|Error"
}

package_release() {
    local target=$1
    local ext=""
    [ "$target" = "x86_64-win64" ] && ext=".exe"

    local release_name="lazarus-${LAZARUS_VERSION}-${target}-${DATE_STAMP}"
    local staging="$RELEASE_DIR/$release_name"

    echo "=== Packaging $release_name ==="
    mkdir -p "$staging/bin"
    mkdir -p "$staging/compiler"
    mkdir -p "$staging/units"

    cp "$LAZARUS_DIR/lazbuild${ext}" "$staging/bin/"

    local compiler=$(get_compiler_for_target "$target")
    if [ "$target" = "x86_64-linux" ]; then
        cp "$compiler" "$staging/compiler/ppcx64"
    elif [ "$target" = "x86_64-win64" ]; then
        if [ -f "$VP_DIR/dist/win64/staging/bin/ppcx64.exe" ]; then
            cp "$VP_DIR/dist/win64/staging/bin/ppcx64.exe" "$staging/compiler/"
        else
            echo "WARNING: Win64 ppcx64.exe not found in VibePascal dist. Skipping compiler."
        fi
    elif [ "$target" = "aarch64-linux" ]; then
        cp "$compiler" "$staging/compiler/ppcrossaarch64"
    elif [ "$target" = "arm-linux" ]; then
        cp "$compiler" "$staging/compiler/ppcrossarm"
    elif [ "$target" = "x86_64-darwin" ]; then
        cp "$compiler" "$staging/compiler/ppcrossx64"
    elif [ "$target" = "aarch64-darwin" ]; then
        cp "$compiler" "$staging/compiler/ppcrossaarch64"
    fi

    cp -r "$VP_DIR/rtl/units/$target" "$staging/units/rtl"

    mkdir -p "$staging/units/packages"
    for pkg_dir in "$VP_DIR/packages"/*/units/"$target"; do
        if [ -d "$pkg_dir" ]; then
            pkg_name=$(echo "$pkg_dir" | sed "s|.*/packages/\([^/]*\)/.*|\1|")
            cp -r "$pkg_dir" "$staging/units/packages/$pkg_name"
        fi
    done

    cp -r "$LAZARUS_DIR/components" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/lcl" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/packager" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/ide" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/ideintf" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/debugger" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/converter" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/designer" "$staging/" 2>/dev/null || true
    cp -r "$LAZARUS_DIR/tools" "$staging/" 2>/dev/null || true

    cd "$RELEASE_DIR"
    tar czf "${release_name}.tar.gz" "$release_name"
    echo "Release: $RELEASE_DIR/${release_name}.tar.gz"
    local size=$(du -sh "${release_name}.tar.gz" | cut -f1)
    echo "Size: $size"

    rm -rf "$staging"
    cd "$LAZARUS_DIR"
}

build_platform() {
    local target=$1
    local cfg=$2

    ensure_vp_packages "$target" "$cfg"

    make -C "$LAZARUS_DIR" clean 2>&1 | tail -1

    build_lazbuild "$target" "$cfg"
    package_release "$target"
}

TARGET="${1:-all}"
mkdir -p "$RELEASE_DIR"

echo "Lazarus Release Builder (VibePascal)"
echo "Compiler: $VP_COMPILER"
echo "Version: $LAZARUS_VERSION"
echo ""

case "$TARGET" in
    linux)
        build_platform "x86_64-linux" "$LINUX_CFG"
        ;;
    win64)
        build_platform "x86_64-win64" "$WIN64_CFG"
        ;;
    pi64)
        build_platform "aarch64-linux" "$AARCH64_LINUX_CFG"
        ;;
    pi32)
        build_platform "arm-linux" "$ARM_LINUX_CFG"
        ;;
    osx64)
        build_platform "x86_64-darwin" "$DARWIN_X86_64_CFG"
        ;;
    osxarm)
        build_platform "aarch64-darwin" "$DARWIN_AARCH64_CFG"
        ;;
    all)
        build_platform "x86_64-linux" "$LINUX_CFG"
        build_platform "x86_64-win64" "$WIN64_CFG"
        build_platform "aarch64-linux" "$AARCH64_LINUX_CFG"
        build_platform "arm-linux" "$ARM_LINUX_CFG"
        build_platform "x86_64-darwin" "$DARWIN_X86_64_CFG"
        build_platform "aarch64-darwin" "$DARWIN_AARCH64_CFG"
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "=== Release builds complete ==="
ls -lh "$RELEASE_DIR"/*.tar.gz 2>/dev/null
