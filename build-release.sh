#!/bin/bash
set -e

LAZARUS_DIR="$(cd "$(dirname "$0")" && pwd)"
VP_DIR="/home/jason/src/vibepascal"
RELEASE_DIR="$LAZARUS_DIR/releases"
LAZARUS_VERSION="4.99-vp"
DATE_STAMP="${DATE_STAMP:-$(date +%Y%m%d)}"

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

get_cfg_for_target() {
    local target=$1
    case "$target" in
        x86_64-linux)
            echo "$LINUX_CFG"
            ;;
        x86_64-win64)
            echo "$WIN64_CFG"
            ;;
        aarch64-linux)
            echo "$AARCH64_LINUX_CFG"
            ;;
        arm-linux)
            echo "$ARM_LINUX_CFG"
            ;;
        x86_64-darwin)
            echo "$DARWIN_X86_64_CFG"
            ;;
        aarch64-darwin)
            echo "$DARWIN_AARCH64_CFG"
            ;;
        *)
            echo "$LINUX_CFG"
            ;;
    esac
}

get_latest_win64_bin_tarball() {
    find "$VP_DIR/dist/win64" -maxdepth 1 -type f -name 'vibepascal-v*-win64-bin.tar.gz' 2>/dev/null |
        while IFS= read -r tarball; do
            local base version
            base=$(basename "$tarball")
            version=${base#vibepascal-v}
            version=${version%%-*}
            case "$version" in
                ''|*[!0-9]*) continue ;;
            esac
            printf '%08d %s\n' "$version" "$tarball"
        done |
        sort -n |
        tail -1 |
        cut -d' ' -f2-
}

copy_win64_compiler_to_staging() {
    local staging=$1
    local tarball member

    tarball=$(get_latest_win64_bin_tarball)
    if [ -n "$tarball" ]; then
        member=$(tar -tzf "$tarball" | awk '/(^|\/)bin\/ppcx64\.exe$/ { print; exit }')
        if [ -n "$member" ]; then
            tar -xOzf "$tarball" "$member" > "$staging/compiler/ppcx64.exe"
            echo "Bundled Win64 VibePascal compiler from $(basename "$tarball")."
            return 0
        fi
        echo "WARNING: $(basename "$tarball") does not contain bin/ppcx64.exe."
    fi

    if [ -f "$VP_DIR/compiler/ppcx64.exe" ]; then
        cp "$VP_DIR/compiler/ppcx64.exe" "$staging/compiler/"
        echo "Bundled Win64 VibePascal compiler from compiler/ppcx64.exe."
        return 0
    fi

    if [ -f "$VP_DIR/dist/win64/staging/bin/ppcx64.exe" ]; then
        cp "$VP_DIR/dist/win64/staging/bin/ppcx64.exe" "$staging/compiler/"
        echo "WARNING: Bundled Win64 VibePascal compiler from legacy dist/win64/staging."
        return 0
    fi

    echo "ERROR: Win64 ppcx64.exe not found in VibePascal dist or compiler tree." >&2
    return 1
}

build_darwin_fpcres() {
    local target=$1
    local dest=$2
    local compiler=$(get_compiler_for_target "$target")
    local cfg=$(get_cfg_for_target "$target")
    local os_target=$(echo "$target" | cut -d- -f2)
    local cpu_target=$(echo "$target" | cut -d- -f1)
    local tmp_dir="$RELEASE_DIR/.fpcres-build-$target"

    if [ ! -f "$VP_DIR/utils/fpcres/fpcres.pas" ]; then
        echo "WARNING: VibePascal fpcres source not found; skipping Darwin fpcres bundle."
        return 1
    fi

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir" "$(dirname "$dest")"
    "$compiler" \
        -T"$os_target" \
        -P"$cpu_target" \
        -n @"$cfg" \
        -Fu"$VP_DIR/utils/fpcres" \
        -FU"$tmp_dir" \
        -FE"$tmp_dir" \
        -ofpcres \
        "$VP_DIR/utils/fpcres/fpcres.pas" >/tmp/build-darwin-fpcres-"$target".log 2>&1
    cp "$tmp_dir/fpcres" "$dest"
    chmod +x "$dest"
    rm -rf "$tmp_dir"
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
    local pcp="/tmp/lazbuild-pcp-${target}"

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

    # Per-build isolated PrimaryConfigPath: customdrawn becomes the only entry in
    # staticpackages.inc, no cross-target leak between IDE builds. Pre-clearing
    # staticpackages.inc keeps the user-install list deterministic across runs.
    rm -rf "$pcp"
    mkdir -p "$pcp"

    # Build IDE with customdrawn LCL controls installed by default (GOD mp3l6s84:
    # "I want to have customdrawn LCL controls as a default fucking package").
    # --add-package registers + links customdrawn; --build-ide (NOT --build-ide-minimal)
    # is required because TBuildIDE.Minimal skips LoadAutoInstallPackages.
    set -o pipefail
    "$LAZARUS_DIR/lazbuild" --pcp="$pcp" --lazarusdir="$LAZARUS_DIR" --compiler="$wrapper" \
        --cpu="$cpu_target" --os=darwin --ws=cocoa \
        --add-package "$LAZARUS_DIR/components/customdrawn/customdrawn.lpk" \
        --build-ide 2>&1 | tail -40
    set +o pipefail

    # Rewrite the build-side wrapper path in every .compiled state file so user
    # invocations of `lazbuild --compiler=<tarball>/compiler/ppcX` don't trip
    # the "compiler changed" check and force a rebuild that fails without an
    # fpc.cfg in the tarball. The Date attribute is stripped because the user
    # side compiler binary has a different mtime than the build-side wrapper.
    # Melissa C326 finding 3 (2026-05-16).
    local user_compiler_name
    case "$target" in
        x86_64-darwin)  user_compiler_name=ppcx64 ;;
        aarch64-darwin) user_compiler_name=ppca64 ;;
        *)              user_compiler_name=ppcx64 ;;
    esac
    # $(LazarusDir) always expands WITH trailing slash (Sterling/Melissa C346 r15
    # smoke). $(LazarusDir)/compiler/X -> <lazdir>//compiler/X -> Lars 29bdfd5afc
    # collapses the // post-expand, but older IDEs (pre-29bdfd5afc tarballs,
    # third-party Lazarus installs) still string-compare and trip "Compiler
    # filename changed for FCL 1.0.1" -> forced FCL rebuild. Drop the separator
    # slash here so the stored Value is double-slash-free regardless of which
    # Lazarus consumes it.
    #
    # Also strip -T<os> and -P<cpu> from <Params Value="..."/> lines. Melissa C18
    # finding 2 (r15 smoke RED, 2026-05-16): packaging-time build records
    # `<Params Value="-Tdarwin -Paarch64 -Munleashed -Scghi ...">` because lazbuild
    # passes --os/--cpu to the wrapper. Runtime IDE invocation of ppca64 does NOT
    # pass -Tdarwin/-Paarch64 (target+CPU auto-detect from the compiler binary
    # itself), so IDE compare on the Params Value string trips "Compiler params
    # changed for FCL 1.0.1" -> forced FCL rebuild. Stripping at packaging time
    # makes the stored Params symmetric with runtime, no rebuild trigger. Lars-side
    # alternative is to extend RemoveFPCVerbosityParams to also strip target/CPU;
    # filed as r17 candidate for architectural cleanup.
    # Preserve each state file's original mtime. Lazarus uses .compiled mtimes
    # to decide whether dependent packages are stale; touching only the rewritten
    # Lazarus-format files can make FCL look newer than LazUtils and force a
    # user-side rebuild.
    local compiled_file
    local mtime_ref
    while IFS= read -r -d '' compiled_file; do
        mtime_ref=$(mktemp)
        touch -r "$compiled_file" "$mtime_ref"
        if sed -i \
            -e "s|Value=\"${wrapper}\" Date=\"[0-9]*\"|Value=\"\$(LazarusDir)compiler/${user_compiler_name}\"|g" \
            -e '/Params Value=/ s/-T[A-Za-z0-9_]\+ *//g' \
            -e '/Params Value=/ s/-P[A-Za-z0-9_]\+ *//g' \
            -e '/Params Value=/ s/ \+"/"/g' \
            "$compiled_file"; then
            touch -r "$mtime_ref" "$compiled_file"
            rm -f "$mtime_ref"
        else
            rm -f "$mtime_ref"
            return 1
        fi
    done < <(grep -rlZ --include='*.compiled' "$wrapper" "$LAZARUS_DIR" 2>/dev/null || true)

    rm -f "$wrapper"
    rm -rf "$pcp"
}

get_lcl_widget_for_target() {
    local target=$1
    case "$target" in
        x86_64-win64)
            echo "win32"
            ;;
        *-darwin)
            echo "cocoa"
            ;;
        *)
            echo "gtk2"
            ;;
    esac
}

get_release_compiler_name_for_target() {
    local target=$1
    case "$target" in
        x86_64-linux)
            echo "ppcx64"
            ;;
        x86_64-win64)
            echo "ppcx64.exe"
            ;;
        aarch64-linux)
            echo "ppcrossaarch64"
            ;;
        arm-linux)
            echo "ppcrossarm"
            ;;
        x86_64-darwin)
            echo "ppcx64"
            ;;
        aarch64-darwin)
            echo "ppca64"
            ;;
        *)
            echo "ppcx64"
            ;;
    esac
}

get_lazbuild_path_for_target() {
    local target=$1
    if [ "$target" = "x86_64-win64" ]; then
        echo "$LAZARUS_DIR/lazbuild.exe"
    else
        echo "$LAZARUS_DIR/lazbuild"
    fi
}

clean_bgra_release_package_outputs() {
    local target=$1
    local widget=$2

    rm -rf "$LAZARUS_DIR/components/mouseandkeyinput/lib/$target/$widget"
    rm -rf "$LAZARUS_DIR/components/bgrabitmap/bgrabitmap/lib/${target}-${widget}-"*
    rm -rf "$LAZARUS_DIR/components/bgracontrols/lib/${target}-${widget}-"*
}

rewrite_bgra_compiled_state() {
    local target=$1
    local wrapper=$2
    local compiler_name
    compiler_name=$(get_release_compiler_name_for_target "$target")

    local compiled_file=""
    local mtime_ref=""
    local replacement="\$(LazarusDir)compiler/${compiler_name}"
    while IFS= read -r -d '' compiled_file; do
        mtime_ref=$(mktemp)
        touch -r "$compiled_file" "$mtime_ref"
        if sed -i \
            -e "s|Value=\"${wrapper}\" Date=\"[0-9]*\"|Value=\"${replacement}\"|g" \
            -e "s|Value=\"${wrapper}\"|Value=\"${replacement}\"|g" \
            -e '/Params Value=/ s/-T[A-Za-z0-9_]\+ *//g' \
            -e '/Params Value=/ s/-P[A-Za-z0-9_]\+ *//g' \
            -e '/Params Value=/ s/ \+"/"/g' \
            "$compiled_file"; then
            touch -r "$mtime_ref" "$compiled_file"
            rm -f "$mtime_ref"
        else
            rm -f "$mtime_ref"
            return 1
        fi
    # Whole-tree scan. build_bgra_release_packages runs lazbuild on the BGRA
    # .lpk set, which rebuilds FCL/LCL/LazUtils/IDEintf and other core packages
    # as dependencies -- stamping THEIR .compiled files with the wrapper path
    # too (Melissa r18 aarch64-darwin F7, 2026-05-19: 11 core packages carried
    # the stale /tmp/lazrelease-*-compiler-wrapper path + -Tdarwin Params). A
    # subdir-scoped grep missed them. grep -l only returns files that CONTAIN
    # "$wrapper", so widening to $LAZARUS_DIR is a no-op for already-clean
    # state files. Mirrors build_darwin_ide's rewrite scope.
    done < <(grep -rlZ --include='*.compiled' "$wrapper" "$LAZARUS_DIR" 2>/dev/null || true)
}

verify_bgra_release_package_outputs() {
    local target=$1
    local widget=$2
    local missing=0

    shopt -s nullglob
    local mouse_compiled=("$LAZARUS_DIR"/components/mouseandkeyinput/lib/"$target"/"$widget"/lazmouseandkeyinput.compiled)
    local bgra_compiled=("$LAZARUS_DIR"/components/bgrabitmap/bgrabitmap/lib/"${target}-${widget}-"*/bgrabitmappack.compiled)
    local controls_compiled=("$LAZARUS_DIR"/components/bgracontrols/lib/"${target}-${widget}-"*/bgracontrols.compiled)
    local mouse_ppu=("$LAZARUS_DIR"/components/mouseandkeyinput/lib/"$target"/"$widget"/*.ppu)
    local bgra_ppu=("$LAZARUS_DIR"/components/bgrabitmap/bgrabitmap/lib/"${target}-${widget}-"*/*.ppu)
    local controls_ppu=("$LAZARUS_DIR"/components/bgracontrols/lib/"${target}-${widget}-"*/*.ppu)
    shopt -u nullglob

    if [ "${#mouse_compiled[@]}" -eq 0 ]; then
        echo "ERROR: lazmouseandkeyinput compiled output missing for $target/$widget" >&2
        missing=1
    fi
    if [ "${#bgra_compiled[@]}" -eq 0 ]; then
        echo "ERROR: BGRABitmapPack compiled output missing for $target/$widget" >&2
        missing=1
    fi
    if [ "${#controls_compiled[@]}" -eq 0 ]; then
        echo "ERROR: bgracontrols compiled output missing for $target/$widget" >&2
        missing=1
    fi
    if [ "${#mouse_ppu[@]}" -eq 0 ]; then
        echo "ERROR: lazmouseandkeyinput ppu output missing for $target/$widget" >&2
        missing=1
    fi
    if [ "${#bgra_ppu[@]}" -eq 0 ]; then
        echo "ERROR: BGRABitmapPack ppu output missing for $target/$widget" >&2
        missing=1
    fi
    if [ "${#controls_ppu[@]}" -eq 0 ]; then
        echo "ERROR: bgracontrols ppu output missing for $target/$widget" >&2
        missing=1
    fi

    [ "$missing" -eq 0 ]
}

build_bgra_release_packages() {
    local target=$1
    local cfg=$2
    local compiler
    compiler=$(get_compiler_for_target "$target")
    local os_target=$(echo "$target" | cut -d- -f2)
    local cpu_target=$(echo "$target" | cut -d- -f1)
    local widget
    widget=$(get_lcl_widget_for_target "$target")
    local wrapper="/tmp/lazrelease-${target}-compiler-wrapper"
    local pcp="/tmp/lazrelease-bgra-pcp-${target}"
    local package=""

    echo "=== Building BGRA release packages for $target ($widget) ==="
    clean_bgra_release_package_outputs "$target" "$widget"

    cat > "$wrapper" << EOF
#!/bin/bash
exec "$compiler" -n @"$cfg" "\$@"
EOF
    chmod +x "$wrapper"
    rm -rf "$pcp"
    mkdir -p "$pcp"

    set -o pipefail
    for package in \
        components/mouseandkeyinput/lazmouseandkeyinput.lpk \
        components/bgrabitmap/bgrabitmap/bgrabitmappack.lpk \
        components/bgracontrols/bgracontrols.lpk
    do
        echo "=== lazbuild $package for $target ($widget) ==="
        if ! "$LAZARUS_DIR/lazbuild" \
            --pcp="$pcp" \
            --lazarusdir="$LAZARUS_DIR" \
            --compiler="$wrapper" \
            --cpu="$cpu_target" \
            --os="$os_target" \
            --ws="$widget" \
            "$LAZARUS_DIR/$package" 2>&1 | tail -60; then
            set +o pipefail
            rm -f "$wrapper"
            rm -rf "$pcp"
            return 1
        fi
    done
    set +o pipefail

    if ! rewrite_bgra_compiled_state "$target" "$wrapper"; then
        rm -f "$wrapper"
        rm -rf "$pcp"
        return 1
    fi
    if ! verify_bgra_release_package_outputs "$target" "$widget"; then
        rm -f "$wrapper"
        rm -rf "$pcp"
        return 1
    fi

    rm -f "$wrapper"
    rm -rf "$pcp"
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

build_darwin_lhelp() {
    local target=$1
    local cfg=$2
    local compiler=$(get_compiler_for_target "$target")

    echo "=== Building Darwin lhelp for $target ==="
    local os_target=$(echo "$target" | cut -d- -f2)
    local cpu_target=$(echo "$target" | cut -d- -f1)

    set -o pipefail
    make -C "$LAZARUS_DIR/components/turbopower_ipro" \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        LAZDIR="$LAZARUS_DIR" \
        OPT="-n @$cfg" LCL_PLATFORM=cocoa 2>&1 | tail -20
    make -C "$LAZARUS_DIR/components/chmhelp/packages/help" \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        LAZDIR="$LAZARUS_DIR" \
        OPT="-n @$cfg" LCL_PLATFORM=cocoa 2>&1 | tail -20
    make -C "$LAZARUS_DIR/components/chmhelp/lhelp" \
        clean \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        LAZDIR="$LAZARUS_DIR" \
        OPT="-n @$cfg" LCL_PLATFORM=cocoa 2>&1 | tail -10
    make -C "$LAZARUS_DIR/components/chmhelp/lhelp" \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        LAZDIR="$LAZARUS_DIR" \
        OPT="-n @$cfg" LCL_PLATFORM=cocoa 2>&1 | tail -20
    set +o pipefail
}

sign_darwin_app_machos() {
    local app_root=$1
    local file_info=""
    local signed_count=0

    if ! command -v rcodesign >/dev/null 2>&1; then
        echo "WARNING: rcodesign not found; shipping Darwin app Mach-O files without build-time ad-hoc signatures."
        return 0
    fi

    echo "=== Ad-hoc signing $(basename "$app_root") Mach-O files with rcodesign ==="
    while IFS= read -r -d '' candidate; do
        file_info=$(file "$candidate")
        if echo "$file_info" | grep -Eq 'Mach-O .*executable|Mach-O .*dynamically linked shared library|Mach-O .*bundle'; then
            rcodesign sign "$candidate"
            signed_count=$((signed_count + 1))
        fi
    done < <(find "$app_root" -type f -perm /111 -print0)
    echo "Signed $signed_count Mach-O file(s) inside $(basename "$app_root")."
}

rewrite_darwin_lpk_output_dirs() {
    local bundle_root=$1
    local lpk_file=""
    local rel_dir=""
    local pcp_prefix=""

    while IFS= read -r -d '' lpk_file; do
        rel_dir=$(dirname "${lpk_file#$bundle_root/}")
        [ "$rel_dir" = "." ] && rel_dir="_root"
        rel_dir=${rel_dir//\\/\/}
        pcp_prefix="\$(PrimaryConfigPath)/lib/$rel_dir"
        LPK_PCP_PREFIX="$pcp_prefix" perl -0pi -e '
            my $prefix = $ENV{"LPK_PCP_PREFIX"};
            s{<UnitOutputDirectory Value="([^"]*)"/>}{
                my $value = $1;
                $value =~ s{\\}{/}g;
                $value =~ s{^\./}{};
                qq{<UnitOutputDirectory Value="$prefix/$value"/>}
            }ge;
        ' "$lpk_file"
    done < <(find "$bundle_root" -name '*.lpk' -print0)
}

materialize_darwin_lhelp_app() {
    local lhelp_dir=$1
    local lhelp_bin="$lhelp_dir/lhelp"
    local lhelp_app_bin="$lhelp_dir/lhelp.app/Contents/MacOS/lhelp"

    [ -d "$lhelp_dir/lhelp.app/Contents/MacOS" ] || return 0

    if [ -x "$lhelp_bin" ]; then
        rm -f "$lhelp_app_bin"
        cp "$lhelp_bin" "$lhelp_app_bin"
        chmod +x "$lhelp_app_bin"
        return 0
    fi

    if [ -L "$lhelp_app_bin" ]; then
        echo "WARNING: lhelp binary not built for Darwin; removing broken lhelp.app executable symlink."
        rm -f "$lhelp_app_bin"
    fi
}

restore_staged_mtimes() {
    local staging=$1
    local staged_file=""
    local rel_path=""
    local source_file=""

    # cp -r resets destination mtimes, which can make copied source/.compiled
    # files look newer or older than their source-tree counterparts. Two
    # rebuild-trigger traps this prevents:
    #   * Package-directory copy order making FCL .compiled look newer than
    #     LazUtils, forcing LazUtils rebuild (Melissa F4, cycle 352).
    #   * Source .pas/.lpk mtimes ending up ~5 min newer than .compiled state,
    #     tripping TLazPackageGraph's "source disk file modified" check and
    #     forcing package rebuild from source (Melissa F5, cycle 363).
    # Restore source-tree mtimes before creating the Darwin .app hardlinks and
    # the tarball, so user-side IDE sees a consistent timeline.
    while IFS= read -r -d '' staged_file; do
        rel_path="${staged_file#$staging/}"
        source_file="$LAZARUS_DIR/$rel_path"
        [ -f "$source_file" ] || continue
        touch -r "$source_file" "$staged_file"
    done < <(find "$staging" -type f \( \
        -name '*.compiled' -o \
        -name '*.pas' -o \
        -name '*.pp' -o \
        -name '*.lpk' -o \
        -name '*.inc' -o \
        -name '*.lpr' -o \
        -name '*.lfm' \
        \) -print0)
}

strip_stale_host_arch_artifacts() {
    # Strip host-arch test/dev binaries and non-target build intermediates that
    # leak from the source tree via `cp -r components/`. Without this, an
    # x86_64-linux build host ships its own runtestscodetools/lhelp ELF inside
    # every cross-arch tarball (Sterling C378 r17 finding: runtestscodetools
    # was ELF x86-64 LSB inside the aarch64-darwin tarball).
    local staging=$1
    local target=$2
    local widget
    widget=$(get_lcl_widget_for_target "$target")

    rm -f "$staging/components/codetools/tests/runtestscodetools" \
          "$staging/components/codetools/tests/runtestscodetools.exe" \
          "$staging/components/chmhelp/lhelp/lhelp" \
          "$staging/components/chmhelp/lhelp/lhelp.exe"

    # Remove non-target tests/lib intermediate dirs (e.g., tests/lib/x86_64-linux
    # inside an aarch64-darwin staging). End users do not need test
    # intermediates and they trip lazbuild ambiguous-unit checks.
    local libdir=""
    while IFS= read -r libdir; do
        local arch
        arch=$(basename "$libdir")
        [ "$arch" = "$target" ] && continue
        rm -rf "$libdir"
    done < <(find "$staging/components" -path '*/tests/lib/*' -type d -mindepth 4 -maxdepth 5 2>/dev/null)

    # Keep only the BGRA package outputs for this release target. In an `all`
    # build, previous platform passes leave their lib dirs in the source tree;
    # package_release copies the whole components tree for each target.
    local libroot=""
    local bgra_dir=""
    local bgra_base=""
    for libroot in \
        "$staging/components/bgrabitmap/bgrabitmap/lib" \
        "$staging/components/bgracontrols/lib"
    do
        [ -d "$libroot" ] || continue
        while IFS= read -r bgra_dir; do
            bgra_base=$(basename "$bgra_dir")
            case "$bgra_base" in
                ${target}-${widget}-*) ;;
                *) rm -rf "$bgra_dir" ;;
            esac
        done < <(find "$libroot" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    done

    local mouse_root="$staging/components/mouseandkeyinput/lib"
    local mouse_dir=""
    local mouse_base=""
    if [ -d "$mouse_root" ]; then
        while IFS= read -r mouse_dir; do
            mouse_base=$(basename "$mouse_dir")
            [ "$mouse_base" = "$target" ] || rm -rf "$mouse_dir"
        done < <(find "$mouse_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

        if [ -d "$mouse_root/$target" ]; then
            while IFS= read -r mouse_dir; do
                mouse_base=$(basename "$mouse_dir")
                [ "$mouse_base" = "$widget" ] || rm -rf "$mouse_dir"
            done < <(find "$mouse_root/$target" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        fi
    fi

    # Strip macOS-only artifacts from non-darwin tarballs. lhelp.app contains a
    # relative symlink (Contents/MacOS/lhelp -> ../../../lhelp) that aborts the
    # default Windows tar.exe mid-extract, leaving the user with a partial
    # tree (Wynona C95 r17 finding). The .app bundle is macOS-specific and
    # provides no value in win64/linux tarballs. Darwin tarballs keep the
    # bundle and the materialize_darwin_lhelp_app pass below replaces the
    # symlink with a real binary.
    if [[ "$target" != *-darwin ]]; then
        rm -rf "$staging/components/chmhelp/lhelp/lhelp.app"
    fi
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
        copy_win64_compiler_to_staging "$staging"
    elif [ "$target" = "aarch64-linux" ]; then
        cp "$compiler" "$staging/compiler/ppcrossaarch64"
    elif [ "$target" = "arm-linux" ]; then
        cp "$compiler" "$staging/compiler/ppcrossarm"
    elif [ "$target" = "x86_64-darwin" ]; then
        local native_dir=$(find "$VP_DIR/dist/darwin-native" -maxdepth 1 -type d -name 'vibepascal-native-x86_64-darwin-*' 2>/dev/null | sort | tail -1)
        if [ -n "$native_dir" ] && [ -x "$native_dir/bin/ppcx64" ]; then
            cp "$native_dir/bin/ppcx64" "$staging/compiler/ppcx64"
            chmod +x "$staging/compiler/ppcx64"
            echo "Bundled native x86_64-darwin VibePascal compiler from $(basename "$native_dir")." > "$staging/COMPILER_NOTES.txt"
            [ -f "$native_dir/COMPILER_NOTES.txt" ] && cat "$native_dir/COMPILER_NOTES.txt" >> "$staging/COMPILER_NOTES.txt"
        else
            echo "NOTE: Native x86_64-darwin compiler not yet available (linker issue under investigation)." > "$staging/COMPILER_NOTES.txt"
            echo "Cross-compilation from Linux works; native compiler WIP. Install FPC separately to compile." >> "$staging/COMPILER_NOTES.txt"
        fi
    elif [ "$target" = "aarch64-darwin" ]; then
        local native_dir=$(find "$VP_DIR/dist/darwin-native" -maxdepth 1 -type d -name 'vibepascal-native-aarch64-darwin-*' 2>/dev/null | sort | tail -1)
        if [ -n "$native_dir" ] && [ -x "$native_dir/bin/ppca64" ]; then
            cp "$native_dir/bin/ppca64" "$staging/compiler/ppca64"
            chmod +x "$staging/compiler/ppca64"
            echo "Bundled native aarch64-darwin VibePascal compiler from $(basename "$native_dir")." > "$staging/COMPILER_NOTES.txt"
            [ -f "$native_dir/COMPILER_NOTES.txt" ] && cat "$native_dir/COMPILER_NOTES.txt" >> "$staging/COMPILER_NOTES.txt"
        else
            echo "NOTE: Native aarch64-darwin compiler not yet available (self-compile crash under investigation)." > "$staging/COMPILER_NOTES.txt"
            echo "Cross-compilation from Linux works; native compiler WIP. Install FPC separately to compile." >> "$staging/COMPILER_NOTES.txt"
        fi
    fi

    if [[ "$target" == *-darwin ]]; then
        echo "Bundling native Darwin fpcres for $target..."
        build_darwin_fpcres "$target" "$staging/bin/fpcres"
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
    cp -r "$LAZARUS_DIR/images" "$staging/" 2>/dev/null || true

    # Ship the auto-update helper scripts at tarball root so users can refresh
    # and rebuild the IDE from the source tree this tarball delivers. The copies
    # above bring only subtrees (components/, lcl/, ide/, ...) -- never repo-root
    # files -- so the updater scripts were absent (GOD mpd5wmli: "no
    # auto-update.bat script was included").
    for updater in auto-update.bat auto-update.ps1 auto-update.sh; do
        [ -f "$LAZARUS_DIR/$updater" ] && cp "$LAZARUS_DIR/$updater" "$staging/"
    done

    strip_stale_host_arch_artifacts "$staging" "$target"

    restore_staged_mtimes "$staging"

    if [[ "$target" == *-darwin ]]; then
        materialize_darwin_lhelp_app "$staging/components/chmhelp/lhelp"
    fi

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
            local app_root="$staging/$app_name"
            local app_macos="$app_root/Contents/MacOS"
            local app_resources="$app_root/Contents/Resources"
            local bundled_laz="$app_resources/lazarus"

            # Retarget the inner startlazarus.app helper symlink so it resolves INSIDE the .app
            # bundle. Old target ../../../../../../bin/startlazarus escapes the bundle (works
            # only with the unpacked tarball; breaks on drag-to-/Applications). New target
            # ../../../../MacOS/startlazarus lands on the outer Contents/MacOS/startlazarus
            # binary that create_darwin_app_bundle already places, so the .app stays
            # self-contained no matter where it lives.
            ln -sf ../../../../MacOS/startlazarus "$app_resources/startlazarus.app/Contents/MacOS/startlazarus"

            # Also make the app self-contained for Finder drag-to-/Applications installs.
            # LazarusDirectory quality checks require these source-tree neighbors; if they
            # live only beside the .app at tarball root, dragging just the .app loses them.
            rm -rf "$bundled_laz"
            mkdir -p "$bundled_laz"
            for bundle_dir in bin components lcl packager ide ideintf debugger converter designer tools units compiler images; do
                if [ -e "$staging/$bundle_dir" ]; then
                    cp -al "$staging/$bundle_dir" "$bundled_laz/" 2>/dev/null || cp -a "$staging/$bundle_dir" "$bundled_laz/"
                fi
            done
            rewrite_darwin_lpk_output_dirs "$bundled_laz"
            materialize_darwin_lhelp_app "$bundled_laz/components/chmhelp/lhelp"

            # Launch through a tiny wrapper so the per-user primary config points
            # LazarusDirectory and CompilerFilename back inside the moved .app.
            if [ -f "$app_macos/lazarus" ] && [ ! -f "$app_macos/lazarus-bin" ]; then
                mv "$app_macos/lazarus" "$app_macos/lazarus-bin"
            fi
            cat > "$app_macos/lazarus" << 'DARWINLAUNCH'
#!/bin/bash
set -e

contents_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_root="$(cd "$contents_dir/.." && pwd)"
app_name="$(basename "$app_root")"
resources_dir="$contents_dir/Resources"
pcp_dir="${LAZARUS_PCP:-$HOME/Library/Application Support/Lazarus/$app_name}"
lazarus_dir="$resources_dir/lazarus"
compiler=""
env_file="$pcp_dir/environmentoptions.xml"
desktop_seed_marker="$pcp_dir/.object-inspector-visible-seeded"
pcp_lib="$pcp_dir/lib"

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

seed_object_inspector_desktop() {
    [ -f "$desktop_seed_marker" ] && return 0
    [ -f "$env_file" ] || return 0

    perl -0pi -e '
        if (m{<ObjectInspectorDlg>.*?</ObjectInspectorDlg>}s) {
            s{(<ObjectInspectorDlg>.*?<Visible Value=")[^"]*(".*?</ObjectInspectorDlg>)}{$1True$2}s
                or s{(<ObjectInspectorDlg>.*?)(</ObjectInspectorDlg>)}{$1\n        <Visible Value="True"/>\n      $2}s;
        } elsif (m{<Desktop1\b}s) {
            s{(</Desktop1>)}{      <ObjectInspectorDlg>\n        <Caption Value="ObjectInspectorDlg"/>\n        <Visible Value="True"/>\n      </ObjectInspectorDlg>\n    $1}s;
        } elsif (m{</CONFIG>}s) {
            s{</CONFIG>}{  <Desktops Count="1" ActiveDesktop="default">\n    <Desktop1 Name="default">\n      <Desktop Version="2" FormIdCount="1">\n        <FormIdList a1="ObjectInspectorDlg"/>\n      </Desktop>\n      <ObjectInspectorDlg>\n        <Caption Value="ObjectInspectorDlg"/>\n        <Visible Value="True"/>\n      </ObjectInspectorDlg>\n    </Desktop1>\n  </Desktops>\n</CONFIG>}s;
        }
    ' "$env_file"
    : > "$desktop_seed_marker"
}

mkdir -p "$pcp_dir"
seed_marker="$pcp_lib/.bundle-unit-cache-seeded"
if [ ! -f "$seed_marker" ]; then
    mkdir -p "$pcp_lib"
    for seed_root in "$lazarus_dir/packager" "$lazarus_dir/lcl" "$lazarus_dir/components" "$lazarus_dir/ide"; do
        [ -d "$seed_root" ] || continue
        find "$seed_root" -type d \( -name units -o -name lib \) -print | while IFS= read -r source_dir; do
            rel_path="${source_dir#$lazarus_dir/}"
            dest_dir="$pcp_lib/$rel_path"
            mkdir -p "$(dirname "$dest_dir")"
            if [ ! -e "$dest_dir" ]; then
                if command -v ditto >/dev/null 2>&1; then
                    ditto "$source_dir" "$dest_dir"
                else
                    cp -R "$source_dir" "$dest_dir"
                fi
            fi
        done
    done
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$seed_marker"
fi
lazarus_xml=$(xml_escape "$lazarus_dir/")
compiler_value=""
for compiler_name in ppcx64 ppca64; do
    candidate="$lazarus_dir/compiler/$compiler_name"
    if [ -x "$candidate" ]; then
        compiler_value="$candidate"
        break
    fi
done
compiler_xml=$(xml_escape "$compiler_value")

rewrite_env=0
if [ ! -f "$env_file" ] || ! grep -F "LazarusDirectory Value=\"$lazarus_dir/\"" "$env_file" >/dev/null 2>&1; then
    rewrite_env=1
else
    current_compiler="$(sed -n 's/.*<CompilerFilename Value="\([^"]*\)".*/\1/p' "$env_file" | head -1)"
    if [ -n "$compiler_value" ] && { [ -z "$current_compiler" ] || [ ! -x "$current_compiler" ]; }; then
        rewrite_env=1
    fi
fi

if [ "$rewrite_env" -eq 1 ]; then
    cat > "$env_file" << EOF
<?xml version="1.0"?>
<CONFIG>
  <EnvironmentOptions>
    <Version Value="112" Lazarus="4.99"/>
    <LazarusDirectory Value="$lazarus_xml"/>
    <CompilerFilename Value="$compiler_xml"/>
    <TestBuildDirectory Value="~/tmp/"/>
  </EnvironmentOptions>
  <Desktops Count="1" ActiveDesktop="default">
    <Desktop1 Name="default">
      <Desktop Version="2" FormIdCount="1">
        <FormIdList a1="ObjectInspectorDlg"/>
      </Desktop>
      <ObjectInspectorDlg>
        <Caption Value="ObjectInspectorDlg"/>
        <Visible Value="True"/>
      </ObjectInspectorDlg>
    </Desktop1>
  </Desktops>
</CONFIG>
EOF
fi
seed_object_inspector_desktop

fpc_cfg="$pcp_dir/fpc.cfg"
if [ -n "$compiler_value" ] && [ -d "$lazarus_dir/units/rtl" ]; then
    sdk_path=""
    if command -v xcrun >/dev/null 2>&1; then
        sdk_path="$(xcrun --show-sdk-path 2>/dev/null || true)"
    fi
    {
        printf '%s\n' "# Lazarus bundled fpc.cfg -- auto-generated by Contents/MacOS/lazarus on launch."
        printf '%s\n' "# Hand edits will be overwritten; put per-user overrides in ~/.fpc.cfg instead."
        printf '%s\n' "-Sc"
        [ -d "$lazarus_dir/bin" ] && printf '%s\n' "-FD$lazarus_dir/bin"
        printf '%s\n' "-Fu$lazarus_dir/units/rtl"
        for package_units in "$lazarus_dir/units/packages"/*; do
            [ -d "$package_units" ] && printf '%s\n' "-Fu$package_units"
        done
        if [ -n "$sdk_path" ] && [ -d "$sdk_path" ]; then
            printf '%s\n' "-XR$sdk_path"
        fi
    } > "$fpc_cfg"
fi
export PPC_CONFIG_PATH="$pcp_dir"
export PATH="$lazarus_dir/bin:$lazarus_dir/compiler:$PATH"

exec "$contents_dir/MacOS/lazarus-bin" "--pcp=$pcp_dir" "$@"
DARWINLAUNCH
            chmod +x "$app_macos/lazarus"

            sign_darwin_app_machos "$app_root"
        fi
        # Gatekeeper de-quarantine + ad-hoc sign helper. rcodesign gives bundled Mach-O
        # files Linux-built ad-hoc signatures, but browser downloads can still carry quarantine
        # and there is no Apple Developer ID notarization yet. README + .command remain
        # the recovery path for Finder/Safari installs (GOD report moz5231r).
        cat > "$staging/README-MACOS.txt" << 'MACREADME'
Lazarus on macOS -- First-Run Setup
====================================

IMPORTANT: Run fix-macos.command BEFORE you attempt to launch the .app for
the first time. Double-clicking the .app first can leave the bundle sealed
in a way that prevents the fix-up step from working. If that happens,
re-extract the .app from the tarball into a fresh directory and run
fix-macos.command on that fresh copy.

Where the build is:

    Downloaded .tar.gz: usually in ~/Downloads unless your browser is set
    differently.

    Extracted .app: exactly where you unpacked the tarball. Finder does not
    move it automatically.

    Permanent install location: /Applications/lazarus-<arch>-darwin.app.
    After running fix-macos.command successfully, double-click
    install-macos.command to copy the app there. The script prints the exact
    installed path when it finishes.

Mach-O files inside this .app are ad-hoc signed during packaging, but the app
is not signed with an Apple Developer ID and it is not notarized yet. After
downloading, Safari/Chrome can stamp the .tar.gz with a
com.apple.quarantine extended attribute that Finder's Archive Utility
propagates onto the .app. On Apple Silicon, Gatekeeper can still present a
misleading error:

    "lazarus-<arch>-darwin" is damaged and can't be opened.

Nothing is actually damaged. The fix in one step:

    Double-click fix-macos.command  (Finder opens Terminal, runs it.)

If macOS blocks fix-macos.command with the same "damaged" message, do this
once: right-click fix-macos.command -> Open -> Open. macOS remembers the
override after the first run.

Manual equivalent (Terminal) -- adjust the path:

    xattr -dr com.apple.quarantine /path/to/lazarus-<arch>-darwin.app
    codesign --force --deep --sign - /path/to/lazarus-<arch>-darwin.app

After either path, double-clicking the .app launches Lazarus normally.

If you later move the .app to /Applications, re-run the same two commands
against the moved copy. Quarantine attaches per-file, not per-bundle.

The shipped install-macos.command does that move and re-sign step for the
standard /Applications location.

Permanent zero-touch fix is Apple Developer ID + notarization. Until that
lands, build-time Mach-O ad-hoc signing plus this README + fix-macos.command
is the supported flow.
MACREADME
        cat > "$staging/fix-macos.command" << 'MACFIX'
#!/bin/bash
# fix-macos.command -- de-quarantine + ad-hoc sign Lazarus.app
# Double-click in Finder OR run from Terminal.
#
# IMPORTANT: Run this BEFORE you launch the .app for the first time. A
# previously-launched bundle can be sealed by launchd in a way that breaks
# the codesign --deep step below. If that happens, re-extract from the
# tarball into a fresh directory and run this script first.
set -e
cd "$(dirname "$0")"

pause_if_interactive() {
    if [ -t 0 ]; then
        read -p "$1" _
    fi
}

APP=$(ls -d lazarus-*-darwin.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
    echo "ERROR: No lazarus-*-darwin.app found in $(pwd)"
    echo "Place this script next to the .app or run it from the unpacked tarball directory."
    pause_if_interactive "Press Return to close..."
    exit 1
fi

echo "Target: $APP"
targets=("$APP")
if [ -d compiler ]; then
    targets+=("compiler")
fi

echo "Removing com.apple.quarantine xattr..."
# || true keeps us going so the verification step below can give a precise
# diagnosis if removal actually failed (e.g. sealed bundle).
for target in "${targets[@]}"; do
    xattr -dr com.apple.quarantine "$target" || true
done

remaining=0
for target in "${targets[@]}"; do
    count=$(xattr -lr "$target" 2>/dev/null | grep -c "com.apple.quarantine" || true)
    remaining=$((remaining + count))
done
if [ "${remaining:-0}" -gt 0 ]; then
    echo ""
    echo "WARNING: $remaining file(s) still carry com.apple.quarantine after xattr -dr."
    echo "This usually means the .app was launched once before this script ran,"
    echo "and macOS sealed the bundle so xattr can no longer modify it."
    echo "Fix: re-extract the .app from the tarball into a fresh directory"
    echo "     and run fix-macos.command BEFORE double-clicking the .app."
    pause_if_interactive "Press Return to close..."
    exit 1
fi

echo "Applying ad-hoc code signature (this may take a minute)..."
if ! codesign --force --deep --sign - "$APP"; then
    echo ""
    echo "ERROR: codesign --deep failed."
    echo "If the message mentioned 'internal error in Code Signing subsystem',"
    echo "the .app was launched before this script ran and is now sealed."
    echo "Fix: re-extract the .app from the tarball into a fresh directory"
    echo "     and run fix-macos.command BEFORE double-clicking the .app."
    pause_if_interactive "Press Return to close..."
    exit 1
fi
if [ -d compiler ]; then
    for compiler_bin in compiler/ppc*; do
        [ -f "$compiler_bin" ] && [ -x "$compiler_bin" ] || continue
        if ! codesign --force --sign - "$compiler_bin"; then
            echo ""
            echo "ERROR: codesign failed on $compiler_bin."
            echo "Fix: re-extract the tarball into a fresh directory"
            echo "     and run fix-macos.command BEFORE double-clicking the .app."
            pause_if_interactive "Press Return to close..."
            exit 1
        fi
    done
fi
if [ -x bin/fpcres ]; then
    if ! codesign --force --sign - bin/fpcres; then
        echo ""
        echo "ERROR: codesign failed on bin/fpcres."
        echo "Fix: re-extract the tarball into a fresh directory"
        echo "     and run fix-macos.command BEFORE double-clicking the .app."
        pause_if_interactive "Press Return to close..."
        exit 1
    fi
fi

echo ""
echo "Done. Double-click $APP to launch Lazarus."
pause_if_interactive "Press Return to close this window..."
MACFIX
        chmod +x "$staging/fix-macos.command"
        cat > "$staging/install-macos.command" << 'MACINSTALL'
#!/bin/bash
# install-macos.command -- copy the packaged Lazarus.app to /Applications.
# Run fix-macos.command first, then run this helper when you want a stable
# Finder-visible install location.
set -e
cd "$(dirname "$0")"

pause_if_interactive() {
    if [ -t 0 ]; then
        read -p "$1" _
    fi
}

APP=$(ls -d lazarus-*-darwin.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
    echo "ERROR: No lazarus-*-darwin.app found in $(pwd)"
    echo "Place this script next to the .app or run it from the unpacked tarball directory."
    pause_if_interactive "Press Return to close..."
    exit 1
fi

DEST="/Applications/$APP"

echo "Installing $APP to $DEST"
if [ -e "$DEST" ]; then
    echo "Removing existing $DEST"
    rm -rf "$DEST"
fi

cp -R "$APP" "$DEST"

targets=("$DEST")
if [ -d compiler ]; then
    targets+=("compiler")
fi

echo "Removing quarantine from installed app and bundled compiler tools..."
for target in "${targets[@]}"; do
    xattr -dr com.apple.quarantine "$target" || true
done

remaining=0
for target in "${targets[@]}"; do
    count=$(xattr -lr "$target" 2>/dev/null | grep -c "com.apple.quarantine" || true)
    remaining=$((remaining + count))
done
if [ "${remaining:-0}" -gt 0 ]; then
    echo ""
    echo "WARNING: $remaining file(s) still carry com.apple.quarantine after install."
    echo "Fix: delete $DEST, re-extract the tarball, run fix-macos.command first,"
    echo "     then run install-macos.command again."
    pause_if_interactive "Press Return to close..."
    exit 1
fi

echo "Applying ad-hoc code signature to installed app..."
if ! codesign --force --deep --sign - "$DEST"; then
    echo ""
    echo "ERROR: codesign --deep failed on $DEST"
    echo "Fix: delete $DEST, re-extract the tarball, run fix-macos.command first,"
    echo "     then run install-macos.command again."
    pause_if_interactive "Press Return to close..."
    exit 1
fi
if [ -d compiler ]; then
    for compiler_bin in compiler/ppc*; do
        [ -f "$compiler_bin" ] && [ -x "$compiler_bin" ] || continue
        if ! codesign --force --sign - "$compiler_bin"; then
            echo ""
            echo "ERROR: codesign failed on $compiler_bin"
            echo "Fix: delete $DEST, re-extract the tarball, run fix-macos.command first,"
            echo "     then run install-macos.command again."
            pause_if_interactive "Press Return to close..."
            exit 1
        fi
    done
fi
if [ -x bin/fpcres ]; then
    if ! codesign --force --sign - bin/fpcres; then
        echo ""
        echo "ERROR: codesign failed on bin/fpcres"
        echo "Fix: delete $DEST, re-extract the tarball, run fix-macos.command first,"
        echo "     then run install-macos.command again."
        pause_if_interactive "Press Return to close..."
        exit 1
    fi
fi

echo ""
echo "Installed Lazarus at: $DEST"
echo "Open it from Finder > Applications, or run: open \"$DEST\""
pause_if_interactive "Press Return to close this window..."
MACINSTALL
        chmod +x "$staging/install-macos.command"
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
        build_darwin_lhelp "$target" "$cfg"
        create_darwin_app_bundle "$target"
        if ! build_bgra_release_packages "$target" "$cfg"; then
            cp "$saved_lazbuild" "$LAZARUS_DIR/lazbuild"
            rm -f "$saved_lazbuild"
            return 1
        fi

        # Restore darwin lazbuild for packaging
        cp "$saved_lazbuild" "$LAZARUS_DIR/lazbuild"
        rm -f "$saved_lazbuild"
    elif [ "$target" = "x86_64-linux" ]; then
        build_bgra_release_packages "$target" "$cfg"
    else
        # Cross-target lazbuild binaries are not executable on this Linux build
        # host. Use a native lazbuild with a per-target compiler wrapper to
        # produce package artifacts, then restore the target lazbuild for
        # packaging.
        local target_lazbuild
        target_lazbuild=$(get_lazbuild_path_for_target "$target")
        local saved_lazbuild="$LAZARUS_DIR/lazbuild-${target}"
        [ "$target" = "x86_64-win64" ] && saved_lazbuild="${saved_lazbuild}.exe"
        if [ ! -f "$target_lazbuild" ]; then
            echo "ERROR: target lazbuild not found at $target_lazbuild" >&2
            return 1
        fi
        cp "$target_lazbuild" "$saved_lazbuild"
        make -C "$LAZARUS_DIR" lazbuild \
            PP="$VP_DIR/compiler/ppcx64" \
            FPCDIR="$VP_DIR" \
            OS_TARGET=linux \
            CPU_TARGET=x86_64 \
            OPT="-n @$LINUX_CFG" 2>&1 | tail -5

        if ! build_bgra_release_packages "$target" "$cfg"; then
            cp "$saved_lazbuild" "$target_lazbuild"
            rm -f "$saved_lazbuild"
            return 1
        fi

        cp "$saved_lazbuild" "$target_lazbuild"
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
