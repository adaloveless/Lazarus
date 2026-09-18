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

pass=0; failn=0; skip=0

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

# Real native compilers out of Otto's dist tarballs. No hand-built stand-ins: the gate
# reads `file -b` output, so the fixture has to be something `file` classifies for real.
native_from_dist() {  # native_from_dist <subdir> <target-token> <exename> -> path on stdout
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
skiparm() { printf '  SKIP  %-44s %s\n' "$1" "$2"; skip=$((skip + 1)); }

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
    if nativebin=$(native_from_dist "$sub" "$tgt" "$nat"); then
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
mkstaging "$W/d-ok"; cp "$X86" "$W/d-ok/compiler/ppca64"; mkidebin "$W/d-ok/bin/lazarus"
arm "aarch64-darwin everything present" "$W/d-ok" aarch64-darwin "$W" 0
mkstaging "$W/d-nocc"; mkidebin "$W/d-nocc/bin/lazarus"
arm "aarch64-darwin no compiler staged" "$W/d-nocc" aarch64-darwin "$W" 1
mkstaging "$W/d-nobin"; cp "$X86" "$W/d-nobin/compiler/ppca64"
arm "aarch64-darwin no bin/lazarus (NOT VERIFIABLE)" "$W/d-nobin" aarch64-darwin "$W" 3
mkstaging "$W/d-dead"; cp "$X86" "$W/d-dead/compiler/ppca64"
printf 'TIDEAnchorDockMaster\nTDockedMainIDE\nmetadarkstyledsgn\n' > "$W/d-dead/bin/lazarus"
arm "aarch64-darwin liveness marker absent (rc 3, not 1)" "$W/d-dead" aarch64-darwin "$W" 3
mkstaging "$W/d-nodock"; cp "$X86" "$W/d-nodock/compiler/ppca64"
printf 'TMainIDE\nmetadarkstyledsgn\n' > "$W/d-nodock/bin/lazarus"
arm "aarch64-darwin docked classes absent" "$W/d-nodock" aarch64-darwin "$W" 1
mkstaging "$W/d-x86"; cp "$X86" "$W/d-x86/compiler/ppcx64"; mkidebin "$W/d-x86/bin/lazarus"
arm "x86_64-darwin everything present" "$W/d-x86" x86_64-darwin "$W" 0

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

echo
echo "=== $pass passed, $failn failed, $skip skipped ==="
[ "$failn" = 0 ]
