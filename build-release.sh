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

build_darwin_ide() {
    local target=$1
    local cfg=$2
    local compiler=$(get_compiler_for_target "$target")
    local cpu_target=$(echo "$target" | cut -d- -f1)
    local wrapper="/tmp/ppc${cpu_target}-darwin-wrapper"

    echo "=== Building Darwin IDE for $target ==="

    # Wrapper must always include the cross-compile cfg, including for lazbuild's
    # detection calls (-iWTOTP, -va compilertest.pas). Without the cfg, the
    # compiler has no unit search paths and lazbuild reports "system.ppu not found".
    # An older variant of this wrapper bypassed the cfg for -i*/-va; that worked
    # only as long as lazbuild's fpcdefines.xml cache covered the wrapper path.
    cat > "$wrapper" << EOF
#!/bin/bash
exec $compiler -n @$cfg "\$@"
EOF
    chmod +x "$wrapper"

    # Build IDE using native lazbuild. set -o pipefail ensures we surface
    # lazbuild failures even though we tee through tail.
    set -o pipefail
    "$LAZARUS_DIR/lazbuild" --lazarusdir="$LAZARUS_DIR" --compiler="$wrapper" \
        --cpu="$cpu_target" --os=darwin --ws=cocoa --build-ide-minimal 2>&1 | tail -40
    set +o pipefail

    rm -f "$wrapper"
}

build_darwin_starter() {
    local target=$1
    local cfg=$2
    local compiler=$(get_compiler_for_target "$target")

    echo "=== Building Darwin startlazarus for $target ==="
    local os_target=$(echo "$target" | cut -d- -f2)
    local cpu_target=$(echo "$target" | cut -d- -f1)

    make -C "$LAZARUS_DIR" starter \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        OPT="-n @$cfg" LCL_PLATFORM=cocoa 2>&1 | tail -10
}

create_darwin_app_bundle() {
    local target=$1
    local cpu_target=$(echo "$target" | cut -d- -f1)

    echo "=== Creating Lazarus.app for $target ==="
    local app_name="lazarus-${cpu_target}-darwin.app"
    local pcp_bin="$HOME/.lazarus/bin/${target}/lazarus"

    rm -rf "$LAZARUS_DIR/$app_name"
    cp -r "$LAZARUS_DIR/lazarus.app" "$LAZARUS_DIR/$app_name"
    mkdir -p "$LAZARUS_DIR/$app_name/Contents/MacOS"
    rm -f "$LAZARUS_DIR/$app_name/Contents/MacOS/lazarus"

    # Copy IDE binary (from lazbuild primary config path or fallback)
    if [ -f "$pcp_bin" ]; then
        cp "$pcp_bin" "$LAZARUS_DIR/$app_name/Contents/MacOS/lazarus"
    else
        echo "WARNING: IDE binary not found at $pcp_bin"
    fi

    # Copy startlazarus
    if [ -f "$LAZARUS_DIR/startlazarus" ]; then
        cp "$LAZARUS_DIR/startlazarus" "$LAZARUS_DIR/$app_name/Contents/MacOS/startlazarus"
    fi

    file "$LAZARUS_DIR/$app_name/Contents/MacOS/lazarus" 2>/dev/null || true
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
        echo "NOTE: Native x86_64-darwin compiler not yet available (linker issue under investigation)." > "$staging/COMPILER_NOTES.txt"
        echo "Cross-compilation from Linux works; native compiler WIP. Install FPC separately to compile." >> "$staging/COMPILER_NOTES.txt"
    elif [ "$target" = "aarch64-darwin" ]; then
        echo "NOTE: Native aarch64-darwin compiler not yet available (self-compile crash under investigation)." > "$staging/COMPILER_NOTES.txt"
        echo "Cross-compilation from Linux works; native compiler WIP. Install FPC separately to compile." >> "$staging/COMPILER_NOTES.txt"
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

    # Darwin: include IDE binary, startlazarus, and .app bundle
    if [[ "$target" == *-darwin ]]; then
        local cpu_target=$(echo "$target" | cut -d- -f1)
        local pcp_bin="$HOME/.lazarus/bin/${target}/lazarus"
        if [ -f "$pcp_bin" ]; then
            cp "$pcp_bin" "$staging/bin/lazarus"
        fi
        if [ -f "$LAZARUS_DIR/startlazarus" ]; then
            cp "$LAZARUS_DIR/startlazarus" "$staging/bin/startlazarus"
        fi
        local app_name="lazarus-${cpu_target}-darwin.app"
        if [ -d "$LAZARUS_DIR/$app_name" ]; then
            cp -r "$LAZARUS_DIR/$app_name" "$staging/"
            # Fix startlazarus symlink inside the app bundle (should point to bin/startlazarus)
            ln -sf ../../../../../../bin/startlazarus "$staging/$app_name/Contents/Resources/startlazarus.app/Contents/MacOS/startlazarus"
        fi
        # Remove broken lhelp.app symlink (lhelp binary not built in this configuration)
        if [ -L "$staging/components/chmhelp/lhelp/lhelp.app/Contents/MacOS/lhelp" ]; then
            rm -f "$staging/components/chmhelp/lhelp/lhelp.app/Contents/MacOS/lhelp"
        fi
    fi

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

    # Darwin: build IDE and .app bundle
    if [[ "$target" == *-darwin ]]; then
        # Save darwin lazbuild and restore native lazbuild for IDE build
        local saved_lazbuild="$LAZARUS_DIR/lazbuild-${target}"
        cp "$LAZARUS_DIR/lazbuild" "$saved_lazbuild"
        make -C "$LAZARUS_DIR" lazbuild \
            PP="$VP_DIR/compiler/ppcx64" \
            FPCDIR="$VP_DIR" \
            OS_TARGET=linux \
            CPU_TARGET=x86_64 \
            OPT="-n @$LINUX_CFG" 2>&1 | tail -5

        build_darwin_ide "$target" "$cfg"
        build_darwin_starter "$target" "$cfg"
        create_darwin_app_bundle "$target"

        # Restore darwin lazbuild for packaging
        cp "$saved_lazbuild" "$LAZARUS_DIR/lazbuild"
        rm -f "$saved_lazbuild"
    fi

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
