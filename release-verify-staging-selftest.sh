#!/bin/bash
#
# release-verify-staging-selftest.sh [vp-dist-dir]
#
# Drives release-verify-staging.sh across all three target SHAPES, in BOTH directions,
# against synthetic staging trees under a scratch dir. Nothing here touches a real
# checkout, a real staging tree or a real release.
#
# WHY THIS EXISTS (c701, 2026-09-18). The gate shipped at c700 had four arms and only ONE
# had ever run -- x86_64-win64, against a real staging tree. Bruno (BuildMaster_lazdev)
# drove the darwin arms cold the same night and found a hole in the ARM ones that was live
# on the download page: aarch64-linux staging with the x86_64 cross compiler and NO native
# ppca64 PASSED, which is exactly what r25 shipped. A gate whose arms nobody re-drives
# after an edit is the same class of problem as a release nobody end-state checks, so the
# arms live here next to the gate instead of in one cycle's scratch dir.
#
# RUN THIS AFTER ANY EDIT TO release-verify-staging.sh.
#
# ON CONTROLS: every FAIL arm is paired with a PASS arm on the same fixture shape, because
# a check that cannot fail proves nothing and a check that cannot pass proves nothing
# either (c628/c629). The one-time sensitivity control for the c701 change -- the pre-fix
# script from git HEAD reading rc 0 on the A2 fixture -- is recorded in aaf3b8bf8b's commit
# message; it cannot live here, because "HEAD" stops meaning "pre-fix" the moment it lands.
#
# An arm whose real native compiler tarball is absent reports SKIPPED, never PASSED: a
# missing input makes that arm prove nothing, and silence about it is how a zero gets
# mistaken for a clean bill of health (c654).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/release-verify-staging.sh"
VP_DIST=${1:-/home/jason/src/vibepascal/dist}
W=$(mktemp -d "${TMPDIR:-/tmp}/relgate-selftest.XXXXXX")
trap 'rm -rf "$W"' EXIT

[ -x "$GATE" ] || { echo "ABORT: $GATE is not executable" >&2; exit 3; }

pass=0; failn=0; skip=0; skipped_arms=()

# ---------------------------------------------------------------- fixtures
mkstaging() {  # mkstaging <dir>
    local d=$1 i
    rm -rf "$d"
    mkdir -p "$d"/{bin,units/rtl,units/packages,ide/packages/idepackager,lcl,components,compiler}
    for i in $(seq 1 60); do : > "$d/units/rtl/u$i.ppu"; done
    for i in $(seq 1 12); do mkdir -p "$d/units/packages/p$i"; done
    printf 'libpAnchorDockingDsgn,\nlibpDockedFormEditor,\n' \
        > "$d/ide/packages/idepackager/pkgsysbasepkgs.pas"
    printf 'uses AnchorDockingDsgn, DockedFormEditor;\n' > "$d/ide/lazarus.pp"
}
mkidebin() { printf 'TMainIDE\nTIDEAnchorDockMaster\nTDockedMainIDE\nmetadarkstyledsgn\n' > "$1"; }

# A real x86_64 ELF, for the cross-compiler slots and for the exename-clobber arm.
X86=$W/x86_elf
cp "$(command -v ls)" "$X86"

# Real compilers out of Otto's dist tarballs. No hand-built stand-ins: the gate reads
# `file -b` output, so the fixture has to be something `file` classifies for real. Used for
# every slot now, not just the native ARM ones -- c702 made the gate check the ARCHITECTURE
# of want_compiler too, so an `ls` stand-in is only valid where the slot really is a host
# x86_64 ELF (the two ARM cross slots and x86_64-linux).
compiler_from_dist() {  # compiler_from_dist <subdir> <tarball-token> <exename> -> path on stdout
    local sub=$1 tok=$2 exe=$3 tarball member out="$W/native_$3"
    tarball=$(find "$VP_DIST/$sub" -maxdepth 1 -type f -name "vibepascal-v*-$tok-bin.tar.gz" 2>/dev/null |
              sort -V | tail -1)
    [ -n "$tarball" ] || return 1
    member=$(tar -tzf "$tarball" | awk -v n="$exe" '$0 ~ "(^|/)bin/" n "$" { print; exit }')
    [ -n "$member" ] || return 1
    tar -xOzf "$tarball" "$member" > "$out" 2>/dev/null || return 1
    [ -s "$out" ] || return 1
    printf '%s' "$out"
}

arm() {  # arm <label> <staging> <target> <srctree> <expect-rc>
    local label=$1 st=$2 tgt=$3 src=$4 exp=$5 rc out
    out=$("$GATE" "$st" "$tgt" "$src" 2>&1); rc=$?
    if [ "$rc" = "$exp" ]; then
        printf '  PASS  %-44s rc=%s\n' "$label" "$rc"; pass=$((pass + 1))
    else
        printf '  FAIL  %-44s rc=%s  EXPECTED %s\n' "$label" "$rc" "$exp"
        printf '%s\n' "$out" | sed 's/^/          /'; failn=$((failn + 1))
    fi
}
skiparm() {
    printf '  SKIP  %-44s %s\n' "$1" "$2"
    skipped_arms+=("$1 -- $2")
    skip=$((skip + 1))
}

# ---------------------------------------------------------------- liveness first (c686)
echo "=== self-test: $GATE"
o=$("$GATE" "$W/definitely-not-a-staging-dir" x86_64-linux 2>&1); r=$?
[ "$r" = 3 ] || { echo "ABORT: the gate did not run (rc $r on a missing staging dir)" >&2; exit 9; }
echo "  liveness: gate runs and exits 3 on a missing staging dir"

# ---------------------------------------------------------------- shape: ARM
echo
echo "--- shape: cross-built ARM (needs BOTH a cross and a native compiler) ---"
for spec in "aarch64-linux aarch64-linux ppca64 ppcrossaarch64" \
            "arm-linux arm-linux ppcarm ppcrossarm"; do
    set -- $spec; tgt=$1 sub=$2 nat=$3 cross=$4
    if nativebin=$(compiler_from_dist "$sub" "$tgt" "$nat"); then
        mkstaging "$W/$tgt-both"
        cp "$X86" "$W/$tgt-both/compiler/$cross"; cp "$nativebin" "$W/$tgt-both/compiler/$nat"
        arm "$tgt cross + native $nat" "$W/$tgt-both" "$tgt" "$W" 0
    else
        skiparm "$tgt cross + native $nat" "no vibepascal-v*-$tgt-bin.tar.gz under $VP_DIST/$sub"
    fi
    mkstaging "$W/$tgt-crossonly"; cp "$X86" "$W/$tgt-crossonly/compiler/$cross"
    arm "$tgt cross ONLY (the r25 defect)" "$W/$tgt-crossonly" "$tgt" "$W" 1
    mkstaging "$W/$tgt-clobber"
    cp "$X86" "$W/$tgt-clobber/compiler/$cross"; cp "$X86" "$W/$tgt-clobber/compiler/$nat"
    arm "$tgt $nat is an x86_64 ELF (clobber)" "$W/$tgt-clobber" "$tgt" "$W" 1
    mkstaging "$W/$tgt-nocross"
    if [ -n "${nativebin:-}" ] && [ -f "${nativebin:-}" ]; then
        cp "$nativebin" "$W/$tgt-nocross/compiler/$nat"
        arm "$tgt native present, CROSS missing" "$W/$tgt-nocross" "$tgt" "$W" 1
    fi
    unset nativebin
done

# ---------------------------------------------------------------- shape: darwin
echo
echo "--- shape: darwin (ships a BUILT IDE -- the end state is a class in a binary) ---"
# The darwin compiler slots hold Mach-O, so the fixtures must too: `ls` renamed ppca64 is
# the exename-clobber shape the gate is now supposed to REJECT, and it gets its own arm.
# Real Mach-O compilers exist under $VP_DIST/{x86_64,aarch64}-darwin (measured v59,
# 2026-09-18). That sentence used to end "-- the roll's own copier does not look there, but
# a fixture may", and 9e38689c9f made it FALSE: the copier now falls back to exactly those
# tarballs when dist/darwin-native is empty. So these fixtures are the bytes a roll stages,
# and the COMPOSITION section below drives that join rather than asserting it.
if machA64=$(compiler_from_dist aarch64-darwin aarch64-darwin ppca64); then
    mkstaging "$W/d-ok"; cp "$machA64" "$W/d-ok/compiler/ppca64"; mkidebin "$W/d-ok/bin/lazarus"
    arm "aarch64-darwin everything present" "$W/d-ok" aarch64-darwin "$W" 0
    mkstaging "$W/d-nobin"; cp "$machA64" "$W/d-nobin/compiler/ppca64"
    arm "aarch64-darwin no bin/lazarus (NOT VERIFIABLE)" "$W/d-nobin" aarch64-darwin "$W" 3
    mkstaging "$W/d-dead"; cp "$machA64" "$W/d-dead/compiler/ppca64"
    printf 'TIDEAnchorDockMaster\nTDockedMainIDE\nmetadarkstyledsgn\n' > "$W/d-dead/bin/lazarus"
    arm "aarch64-darwin liveness marker absent (rc 3, not 1)" "$W/d-dead" aarch64-darwin "$W" 3
    mkstaging "$W/d-nodock"; cp "$machA64" "$W/d-nodock/compiler/ppca64"
    printf 'TMainIDE\nmetadarkstyledsgn\n' > "$W/d-nodock/bin/lazarus"
    arm "aarch64-darwin docked classes absent" "$W/d-nodock" aarch64-darwin "$W" 1
else
    skiparm "aarch64-darwin arms" "no vibepascal-v*-aarch64-darwin-bin.tar.gz under $VP_DIST"
fi
mkstaging "$W/d-nocc"; mkidebin "$W/d-nocc/bin/lazarus"
arm "aarch64-darwin no compiler staged" "$W/d-nocc" aarch64-darwin "$W" 1
mkstaging "$W/d-elf"; cp "$X86" "$W/d-elf/compiler/ppca64"; mkidebin "$W/d-elf/bin/lazarus"
arm "aarch64-darwin ppca64 is a Linux ELF (c702)" "$W/d-elf" aarch64-darwin "$W" 1
if machX64=$(compiler_from_dist x86_64-darwin x86_64-darwin ppcx64); then
    mkstaging "$W/d-x86"; cp "$machX64" "$W/d-x86/compiler/ppcx64"; mkidebin "$W/d-x86/bin/lazarus"
    arm "x86_64-darwin everything present" "$W/d-x86" x86_64-darwin "$W" 0
    mkstaging "$W/d-x86wrong"; cp "$machA64" "$W/d-x86wrong/compiler/ppcx64" 2>/dev/null &&
        { mkidebin "$W/d-x86wrong/bin/lazarus"
          arm "x86_64-darwin slot holds the arm64 Mach-O" "$W/d-x86wrong" x86_64-darwin "$W" 1; }
else
    skiparm "x86_64-darwin arms" "no vibepascal-v*-x86_64-darwin-bin.tar.gz under $VP_DIST"
fi

# ------------------------------------------------ shape: darwin COMPOSITION (c704, Bruno)
# Every darwin arm above hands the gate a compiler slot THE TEST filled in, and every proof
# of the copier read the copier's own notes. Nobody had driven the JOIN: the file a ROLL
# actually stages, fed to the gate that actually ships it. A copier and a gate that are each
# green against their own fixtures can still disagree about the NAME, the MODE or the
# ARCHITECTURE of the file that lands in the tarball, and that disagreement is invisible
# until a roll. These arms call build-release.sh's own copy_native_darwin_compiler_to_staging
# and then run the gate on what it produced.
echo
echo "--- shape: darwin COMPOSITION (the roll's own copier feeds the gate) ---"
BR="$HERE/build-release.sh"
CSHIM="$W/copier-shim.sh"
CFNS="get_latest_darwin_bin_tarball declared_md5_for_dist_member
      stage_darwin_compiler_from_dist_tarball get_latest_darwin_native_dir
      copy_native_darwin_compiler_to_staging"
# Externals the copier is ENTITLED to reach for. MEASURED, never guessed (2026-09-18,
# c040): each name was removed from a mirrored PATH one at a time and the four composition
# arms re-driven against real fixtures. file, md5sum, cut, chmod, basename, tar, find, sort
# and tail each turned 2-4 arms RED with "copier reached OUTSIDE the shim closure"; a run
# with nothing removed read 4 passed / 0 failed. An absent one of these is a MISSING INPUT
# -- this script's header says a missing input makes an arm prove nothing and must SKIP --
# and NOT a defect in build-release.sh, which is what a FAIL here claims. The rest of the
# list is the same family of coreutils, included so a thinner host degrades to SKIP too.
# Deliberately NOT "anything not a build-release.sh function": an unknown name still FAILS
# (see the handler), so a typo or an injected command cannot skip its way to green.
CEXT="awk basename cat chmod cp cut date file find grep head ln md5sum mkdir mktemp
      printf rm sed seq sort stat tail tar touch tr wc"
cshim_ok=no
if [ -r "$BR" ]; then
    { for fn in $CFNS; do
          awk -v f="$fn" 'index($0, f "() {")==1 {p=1} p{print} p && /^}$/{exit}' "$BR"
          echo
      done; } > "$CSHIM"
    # RIG FIRST. A shim that defines nothing scores every arm as "nothing staged", which is
    # exactly what the degraded arm below expects -- so a broken rig would read as a pass on
    # one arm and a fail on the others for the wrong reason. Assert the functions exist
    # before believing any result, and SKIP (never FAIL) when they do not: a build-release.sh
    # that predates the dist fallback is an absent input, not a defect.
    cshim_ok=yes
    bash -n "$CSHIM" 2>/dev/null || cshim_ok=no
    for fn in $CFNS; do
        ( . "$CSHIM" >/dev/null 2>&1; declare -F "$fn" >/dev/null ) || cshim_ok=no
    done
    # WHICH NAMES ARE OURS. The recorder below has to tell a missing build-release.sh
    # HELPER (the shim closure is incomplete -- a defect in this rig, and the reason the
    # recorder exists) from a missing EXTERNAL TOOL (an absent input on a thin host).
    # Anchor that first half on the ARTIFACT rather than on a guess: every top-level
    # function name build-release.sh defines. RIG ASSERT, same spirit as the declare -F
    # sweep above -- if this list cannot even find the five functions we just extracted it
    # cannot classify anything, so SKIP rather than report with a label that may be wrong.
    BRFNS=$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$BR" | sed 's/()//' | tr '\n' ' ')
    for fn in $CFNS; do
        case " $BRFNS " in *" $fn "*) ;; *) cshim_ok=no ;; esac
    done
fi
if [ "$cshim_ok" = yes ]; then
    composearm() {  # composearm <label> <target> <exe> <arch-pat> <vp-dir> <expect-gate-rc> <expect-staged>
        local label=$1 tgt=$2 exe=$3 pat=$4 vp=$5 exg=$6 exs=$7
        local st="$W/compose-$tgt-$RANDOM" staged=no crc grc
        local miss="$st.outside-closure" missext="$st.absent-external"
        mkstaging "$st"; mkidebin "$st/bin/lazarus"; rm -f "$st/compiler/$exe"
        : > "$miss"; : > "$missext"
        # `set +e` AFTER sourcing, not before: the copier returns nonzero on the degraded
        # path BY DESIGN and package_release calls it under `|| true`. Source first, relax
        # errexit second, or this dies at the very return it is here to measure.
        #
        # THE RECORDER IS NOT DECORATION. cshim_ok above asserts the five functions are
        # DEFINED; it does NOT assert their transitive closure is complete. A helper one of
        # them calls that is not in CFNS makes the copier fail for a MISSING-DEPENDENCY
        # reason instead of the reason under test -- and the degraded arms below expect
        # exactly "nothing staged, gate refuses", so they would go on passing after the
        # copier stopped working. Measured 2026-09-18 with one closure function deleted:
        # all three arms recorded the missing name while still reading copier rc=1 and
        # staged=no, byte-for-byte the shape this function scores as a PASS. So score the
        # RECORDER before the expectations, and name what was reached for.
        #
        # AND THE RECORDER MUST SAY WHICH KIND OF MISSING IT FOUND (Lars, c705). A bare
        # command_not_found_handle cannot tell a missing helper of OURS from a missing
        # coreutil: on a host without GNU md5sum the copier reaches for it, the arm prints
        # "copier reached OUTSIDE the shim closure: md5sum" and a MISSING INPUT gets
        # reported as a defect in build-release.sh. Measured here 2026-09-18 before this
        # change: 3 of the 4 arms red on an md5sum-less PATH, 3 on file, 4 on find/sort/
        # tail/cut, 2 on chmod, 3 on basename/tar. So classify: ours -> FAIL, a known
        # external -> SKIP (absent input), anything else -> FAIL, because an unknown name
        # is how a typo or an injected command would otherwise skip its way to green.
        crc=$( BRUNO_SHIM_MISS="$miss"; BRUNO_SHIM_MISS_EXT="$missext"
               BRUNO_BRFNS=" $BRFNS "; BRUNO_CEXT=" $CEXT "
               export BRUNO_SHIM_MISS BRUNO_SHIM_MISS_EXT BRUNO_BRFNS BRUNO_CEXT
               command_not_found_handle() {
                   case "$BRUNO_BRFNS" in
                       *" $1 "*) echo "$1" >> "$BRUNO_SHIM_MISS"; return 127 ;;
                   esac
                   case "$BRUNO_CEXT" in
                       *" $1 "*) echo "$1" >> "$BRUNO_SHIM_MISS_EXT"; return 127 ;;
                   esac
                   echo "$1" >> "$BRUNO_SHIM_MISS"; return 127
               }
               . "$CSHIM"; set +e; VP_DIR="$vp"; export VP_DIR
               copy_native_darwin_compiler_to_staging "$st" "$tgt" "$exe" "$pat" >/dev/null 2>&1
               echo $? )
        [ -f "$st/compiler/$exe" ] && staged=yes
        grc=$("$GATE" "$st" "$tgt" "$W" >/dev/null 2>&1; echo $?)
        if [ -s "$miss" ]; then
            printf '  FAIL  %-44s rc=%s  copier reached OUTSIDE the shim closure: %s\n' \
                "$label" "$grc" "$(sort -u "$miss" | tr '\n' ' ')"; failn=$((failn + 1))
        elif [ -s "$missext" ]; then
            # Failures outrank skips, so this branch is second on purpose: a run that hit
            # BOTH a missing helper and a thin host is still RED.
            skiparm "$label" \
                "external tool absent on this host: $(sort -u "$missext" | tr '\n' ' ')"
        elif [ "$grc" = "$exg" ] && [ "$staged" = "$exs" ]; then
            printf '  PASS  %-44s rc=%s\n' "$label" "$grc"; pass=$((pass + 1))
        else
            printf '  FAIL  %-44s rc=%s  EXPECTED %s (staged=%s want %s, copier rc=%s)\n' \
                "$label" "$grc" "$exg" "$staged" "$exs" "$crc"; failn=$((failn + 1))
        fi
        if [ "$staged" = yes ]; then
            printf '          staged compiler/%s: %s\n' "$exe" "$(file -b "$st/compiler/$exe")"
        fi
        return 0
    }
    VP_ROOT=$(cd "$VP_DIST/.." 2>/dev/null && pwd)
    for spec in "x86_64-darwin ppcx64 Mach-O 64-bit x86_64" \
                "aarch64-darwin ppca64 Mach-O 64-bit arm64"; do
        set -- $spec; ctgt=$1 cexe=$2; shift 2; cpat="$*"
        if [ -n "${VP_ROOT:-}" ] &&
           find "$VP_DIST/$ctgt" -maxdepth 1 -type f -name "vibepascal-v*-$ctgt-bin.tar.gz" \
                2>/dev/null | grep -q .; then
            composearm "$ctgt copier -> gate (from dist)" "$ctgt" "$cexe" "$cpat" "$VP_ROOT" 0 yes
        else
            skiparm "$ctgt composition" "no vibepascal-v*-$ctgt-bin.tar.gz under $VP_DIST/$ctgt"
        fi
    done
    # Degraded: a VP tree with neither dist/darwin-native nor a dist tarball. Needs no real
    # compiler, so it ALWAYS runs -- and it is the shape r25's darwin pair shipped.
    mkdir -p "$W/vp-nothing/dist"
    composearm "darwin nothing to bundle -> gate REFUSES" x86_64-darwin ppcx64 \
        "Mach-O 64-bit x86_64" "$W/vp-nothing" 1 no
    # Wrong ARCHITECTURE inside the dist tarball, declared md5 MATCHING it, so the D003 hash
    # guard is satisfied and only the arch guard can catch it. $X86 is a real ELF.
    mkdir -p "$W/vp-elf/dist/aarch64-darwin" "$W/elfsrc/bin"
    cp "$X86" "$W/elfsrc/bin/ppca64"
    ( cd "$W/elfsrc" && tar -czf \
        "$W/vp-elf/dist/aarch64-darwin/vibepascal-v99-zzzcontrol-aarch64-darwin-bin.tar.gz" \
        bin/ppca64 )
    { echo "VibePascal v99 (aarch64-darwin)"
      echo "  Binary: bin/ppca64  $(stat -c %s "$W/elfsrc/bin/ppca64") bytes"
      echo "      md5  $(md5sum < "$W/elfsrc/bin/ppca64" | cut -d' ' -f1)"
    } > "$W/vp-elf/dist/aarch64-darwin/VERSION.txt"
    composearm "darwin dist member is a Linux ELF -> REFUSED" aarch64-darwin ppca64 \
        "Mach-O 64-bit arm64" "$W/vp-elf" 1 no
else
    skiparm "darwin composition arms" "no build-release.sh beside the gate, or it predates the dist fallback"
fi

# ---------------------------------------------------------------- shape: sources + tools
echo
echo "--- shape: sources + tools (the updater IS the delivery mechanism) ---"
mkdir -p "$W/srctree"
if [ -f "$HERE/auto-update.sh" ]; then
    cp "$HERE/auto-update.sh" "$W/srctree/auto-update.sh"
    mkstaging "$W/l-ok"; cp "$X86" "$W/l-ok/compiler/ppcx64"
    cp "$W/srctree/auto-update.sh" "$W/l-ok/auto-update.sh"
    arm "x86_64-linux updater staged, md5 identical" "$W/l-ok" x86_64-linux "$W/srctree" 0
    mkstaging "$W/l-none"; cp "$X86" "$W/l-none/compiler/ppcx64"
    arm "x86_64-linux updater NOT staged" "$W/l-none" x86_64-linux "$W/srctree" 1
    mkstaging "$W/l-diff"; cp "$X86" "$W/l-diff/compiler/ppcx64"
    { cat "$W/srctree/auto-update.sh"; echo "# the tree moved under the roll"; } > "$W/l-diff/auto-update.sh"
    arm "x86_64-linux updater md5 DIFFERS from tree" "$W/l-diff" x86_64-linux "$W/srctree" 1
    mkdir -p "$W/srctree-nosci"
    sed 's/--build-ide=-Sci/--build-ide=/g' "$W/srctree/auto-update.sh" > "$W/srctree-nosci/auto-update.sh"
    mkstaging "$W/l-nosci"; cp "$X86" "$W/l-nosci/compiler/ppcx64"
    cp "$W/srctree-nosci/auto-update.sh" "$W/l-nosci/auto-update.sh"
    arm "x86_64-linux --build-ide=-Sci stripped" "$W/l-nosci" x86_64-linux "$W/srctree-nosci" 1
else
    skiparm "x86_64-linux updater arms" "no auto-update.sh beside the gate"
fi
mkstaging "$W/u-bad"; cp "$X86" "$W/u-bad/compiler/ppcx64"
rm -f "$W/u-bad/ide/lazarus.pp"
arm "x86_64-linux staged ide/lazarus.pp missing" "$W/u-bad" x86_64-linux "$W/srctree" 1
mkstaging "$W/l-nopkg"; cp "$X86" "$W/l-nopkg/compiler/ppcx64"
printf 'libpSynEdit,\n' > "$W/l-nopkg/ide/packages/idepackager/pkgsysbasepkgs.pas"
arm "x86_64-linux docking not core in pkgsysbasepkgs" "$W/l-nopkg" x86_64-linux "$W/srctree" 1

# ---------------------------------------------------------------- shape: sources + tools, WIN64
# Added c702 (Bruno). x86_64-win64 had ZERO arms here, and it is the target GOD runs, the
# target whose r25 asset was cut from a wrecked unit dir, and the only one with a SECOND
# updater file (auto-update.bat) that nothing else exercises. Its compiler slot is a PE, so
# it is also where the name-only compiler check was most dangerous: copy_win64_compiler_to_
# staging still falls back to the mutable dist/win64/staging path that caused D003, and it
# contains no architecture check of its own (0 `file` calls, against 3 in the linux twin).
echo
echo "--- shape: sources + tools, x86_64-win64 (PE compiler + two updater files) ---"
if [ -f "$HERE/auto-update.ps1" ] && [ -f "$HERE/auto-update.bat" ]; then
    cp "$HERE/auto-update.ps1" "$HERE/auto-update.bat" "$W/srctree/"
    stage_win64() {  # stage_win64 <dir> <srctree> [compiler-binary]
        mkstaging "$1"; rm -f "$1/compiler/ppcx64"
        [ -n "${3:-}" ] && cp "$3" "$1/compiler/ppcx64.exe"
        cp "$2/auto-update.ps1" "$2/auto-update.bat" "$1/"
    }
    if pewin=$(compiler_from_dist win64 win64 ppcx64.exe); then
        stage_win64 "$W/w-ok" "$W/srctree" "$pewin"
        arm "win64 everything present (PE compiler)" "$W/w-ok" x86_64-win64 "$W/srctree" 0
        stage_win64 "$W/w-nobat" "$W/srctree" "$pewin"; rm -f "$W/w-nobat/auto-update.bat"
        arm "win64 auto-update.bat absent" "$W/w-nobat" x86_64-win64 "$W/srctree" 1
        stage_win64 "$W/w-diff" "$W/srctree" "$pewin"
        { cat "$W/srctree/auto-update.ps1"; echo "# the tree moved under the roll"; } > "$W/w-diff/auto-update.ps1"
        arm "win64 ps1 md5 DIFFERS from tree" "$W/w-diff" x86_64-win64 "$W/srctree" 1
        mkdir -p "$W/srctree-w-nosci"; cp "$W/srctree/auto-update.bat" "$W/srctree-w-nosci/"
        sed 's/--build-ide=-Sci/--build-ide=/g' "$W/srctree/auto-update.ps1" > "$W/srctree-w-nosci/auto-update.ps1"
        stage_win64 "$W/w-nosci" "$W/srctree-w-nosci" "$pewin"
        arm "win64 --build-ide=-Sci stripped" "$W/w-nosci" x86_64-win64 "$W/srctree-w-nosci" 1
        mkdir -p "$W/srctree-w-nodock"; cp "$W/srctree/auto-update.bat" "$W/srctree-w-nodock/"
        sed 's/Test-DockedLayoutInstalled/Test-ZzzNotRealVerifier/g' "$W/srctree/auto-update.ps1" \
            > "$W/srctree-w-nodock/auto-update.ps1"
        stage_win64 "$W/w-nodock" "$W/srctree-w-nodock" "$pewin"
        arm "win64 docked-layout verifier stripped" "$W/w-nodock" x86_64-win64 "$W/srctree-w-nodock" 1
        stage_win64 "$W/w-nopkg" "$W/srctree" "$pewin"
        printf 'libpSynEdit,\n' > "$W/w-nopkg/ide/packages/idepackager/pkgsysbasepkgs.pas"
        arm "win64 docking not core in pkgsysbasepkgs" "$W/w-nopkg" x86_64-win64 "$W/srctree" 1
    else
        skiparm "win64 arms needing a real PE compiler" "no vibepascal-v*-win64-bin.tar.gz under $VP_DIST/win64"
    fi
    # These two need no real PE: one has no compiler at all, the other has the WRONG one.
    # Both directions of the same slot, which is what makes either of them mean anything.
    stage_win64 "$W/w-nocc" "$W/srctree"
    arm "win64 no compiler staged" "$W/w-nocc" x86_64-win64 "$W/srctree" 1
    stage_win64 "$W/w-elf" "$W/srctree" "$X86"
    arm "win64 ppcx64.exe is a Linux ELF (c702, D003)" "$W/w-elf" x86_64-win64 "$W/srctree" 1
else
    skiparm "x86_64-win64 arms" "no auto-update.ps1/.bat beside the gate"
fi

echo
echo "=== $pass passed, $failn failed, $skip skipped ==="

# A NONZERO SKIP IS NOT GREEN, AND THE EXIT CODE HAS TO SAY SO (Lars, c703).
# The header above already says a missing input makes an arm prove nothing -- but this
# script still ended on `[ "$failn" = 0 ]`, so a run that silently dropped whole blocks
# exited 0 and read as a pass. Measured at c702: run from a scratch dir, $HERE holds no
# auto-update.* and EVERY win64 arm skips; the tally printed "15 passed, 0 failed, 1
# skipped" with exit 0, and the only thing that caught it was the baseline reading 15
# where the record said 19. A tally line is easy to skim past; an exit code is not.
#   0 = every arm ran and passed
#   1 = an arm FAILED -- failures outrank skips, so a red run still reports 1
#   2 = no failures, but at least one arm block never ran
if [ "$failn" != 0 ]; then
    exit 1
fi
if [ "$skip" != 0 ]; then
    echo
    echo "INCOMPLETE: $skip arm block(s) never ran, so this is NOT a clean bill of health:"
    for s in "${skipped_arms[@]}"; do
        echo "  - $s"
    done
    echo "Re-run where those inputs exist -- the updater scripts resolve from \$HERE,"
    echo "beside the gate -- before treating this run as a pass."
    exit 2
fi
