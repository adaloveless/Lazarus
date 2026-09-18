#!/bin/bash
#
# release-verify-staging.sh <staging-dir> <target> [source-tree]
#
# Verifies the END STATE of a release staging tree, i.e. "is the thing the user needs
# actually in what we are about to ship?" -- BEFORE the tarball is cut and long before
# anything is uploaded.
#
# WHY THIS EXISTS (c700, 2026-09-18). build-release.sh cut 25 releases without a single
# feature-level end-state check: grep for TTouchButton / TBetterWebBrowser / AnchorDock /
# MetaDarkStyle over its 2,966 lines returned ZERO. Its only verifications were
# verify_bgra_release_package_outputs and Otto's VP unit-set loadcheck -- both about build
# INPUTS and intermediate artifacts, neither about the shipped feature. Meanwhile BOTH
# updaters have carried three binary-level end-state checks since c634/c691
# (test_commonx_components_installed, test_docked_layout_installed,
# test_metadarkstyle_installed). The roll that produces what GOD downloads had none, and
# r25 is what that costs: its win64 asset was cut from a wrecked gtk2 unit dir and shipped
# for 32 days, and it contains none of the 2026-09-16 UX fixes. Same class as demerit #389
# -- a build path that can silently drop something the user needs must check whether it did.
#
# THE TWO TARGET SHAPES ARE DIFFERENT DELIVERABLES, and conflating them is how you write a
# verifier that always passes. Measured in build_platform/package_release, not assumed:
#
#   *-darwin           ships a BUILT IDE (build_darwin_ide -> create_darwin_app_bundle ->
#                      `cp "$pcp_bin" "$staging/bin/lazarus"`). The end state is a CLASS IN
#                      A BINARY, so scan the binary.
#   x86_64-win64       ships SOURCES + TOOLS: units, the target ppcx64.exe, bin/lazbuild.exe
#   x86_64-linux       and the auto-update scripts. There is NO lazarus binary in the tarball
#   aarch64/arm-linux  at all -- the user's IDE is built on their own box by auto-update.
#                      The two ARM targets carry a SECOND compiler expectation on top of
#                      that (see want_native): they are cross-built, so the compiler that
#                      did the building cannot run on the machine that receives it.
#                      So the end state is "the sources carry the defaults AND the updater
#                      that builds them is the fixed one". Scanning for a class in a binary
#                      that was never staged would fail every honest roll.
#
# Exit codes -- 3 is NOT a soft 1, and the difference is the whole point (c654 void zero):
#   0  every applicable end-state check passed
#   1  a check FAILED: something the user needs is missing from the staging tree
#   3  NOT VERIFIABLE: the tree or binary could not be read well enough to judge it.
#      A missing liveness marker means the scan itself proves nothing, so this script
#      refuses to report "feature missing" over a file it cannot read. Silence about a
#      broken instrument is how a zero gets mistaken for a clean bill of health.
#
set -u

usage() {
    echo "Usage: $0 <staging-dir> <target> [source-tree]" >&2
    echo "  target: x86_64-linux | x86_64-win64 | aarch64-linux | arm-linux |" >&2
    echo "          x86_64-darwin | aarch64-darwin" >&2
    exit 3
}

[ $# -ge 2 ] || usage
STAGING=$1
TARGET=$2
SRC_TREE=${3:-$(cd "$(dirname "$0")" && pwd)}

# Markers. Kept identical to auto-update.sh's DOCKED_LAYOUT_CLASSES /
# METADARKSTYLE_DSGN_SYMBOL / COMMONX_COMPONENTS on purpose: the roll and the updater must
# agree on what "installed" MEANS, or a release can pass here and fail on the user's box.
#
# IDE_LIVENESS_MARKER is the instrument check, not a feature check. It is present in every
# Lazarus host binary we build (measured c700: in both `lazarus` and `lazbuild`), which is
# exactly what a liveness marker needs -- it proves `grep -a` can read THIS file and that
# the file is one of ours. It deliberately does NOT try to prove the file is the IDE; the
# feature markers do that, and TMainIDE would be the wrong tool for it (it is in lazbuild
# too, as is `metadarkstyledsgn` -- do not reuse either as an is-this-the-IDE test).
IDE_LIVENESS_MARKER="TMainIDE"
DOCKED_LAYOUT_CLASSES="TIDEAnchorDockMaster TDockedMainIDE"
METADARKSTYLE_DSGN_SYMBOL="metadarkstyledsgn"

problems=0
fail() { echo "  MISSING: $*"; problems=$((problems + 1)); }
ok()   { echo "  ok: $*"; }

echo "=== Verifying release staging end state: $TARGET ==="
echo "  staging: $STAGING"

# ---------------------------------------------------------------- shape / readability
[ -d "$STAGING" ] || { echo "NOT VERIFIABLE: no such staging dir: $STAGING" >&2; exit 3; }
for d in bin units ide lcl components compiler; do
    [ -d "$STAGING/$d" ] || {
        echo "NOT VERIFIABLE: $STAGING has no $d/ -- this is not a release staging tree." >&2
        exit 3
    }
done

# ---------------------------------------------------------------- unit set actually staged
rtl_ppu=$(find "$STAGING/units/rtl" -maxdepth 1 -name '*.ppu' 2>/dev/null | wc -l)
pkg_dirs=$(find "$STAGING/units/packages" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
if [ "$rtl_ppu" -lt 50 ]; then
    fail "RTL unit set looks empty ($rtl_ppu .ppu in units/rtl)"
else
    ok "RTL unit set staged ($rtl_ppu .ppu)"
fi
if [ "$pkg_dirs" -lt 10 ]; then
    fail "package unit sets looks empty ($pkg_dirs dirs in units/packages)"
else
    ok "package unit sets staged ($pkg_dirs packages)"
fi

# ---------------------------------------------------------------- shipped compiler
#
# TWO EXPECTATIONS, NOT ONE, AND THE SECOND ONE IS THE r25 DEFECT (Bruno, 2026-09-18).
# want_compiler is the compiler that DID THE BUILDING and must be in the tarball.
# For the cross-built ARM targets that is an x86_64 ppcross* -- correct to ship, useless
# on the target -- so a tree carrying ONLY it passes a one-expectation check while a Pi
# user's first compile dies. Bruno drove exactly that: aarch64-linux staging with
# compiler/ppcrossaarch64 and no ppca64 read rc 0 here, with the control (ppcrossaarch64
# removed) reading rc 1, so the pass was real and the gap was mine. r25 is that tree.
#
# want_native is therefore ADDITIVE: the ppcross* member STAYS (documented by design in
# COMPILER_NOTES.txt -- do not "fix" this by removing it; the bug is the missing native
# one, not the present cross one). native_arch is checked too, because the FILENAME IS NOT
# EVIDENCE OF THE ARCHITECTURE: cross and native builds for the same non-host CPU both
# default to exename ppc<cpu>, and on 2026-09-10 compiler/ppcarm in the shared tree WAS an
# x86_64 ELF. The patterns are kept byte-identical to the ones
# copy_native_linux_compiler_to_staging guards with, so the producer and this gate cannot
# disagree about what "native" means.
want_native=""
native_arch=""
case "$TARGET" in
    x86_64-linux)    want_compiler=ppcx64 ;;
    x86_64-win64)    want_compiler=ppcx64.exe ;;
    aarch64-linux)   want_compiler=ppcrossaarch64; want_native=ppca64; native_arch="ARM aarch64" ;;
    arm-linux)       want_compiler=ppcrossarm;     want_native=ppcarm;  native_arch="ARM, EABI5" ;;
    x86_64-darwin)   want_compiler=ppcx64 ;;
    aarch64-darwin)  want_compiler=ppca64 ;;
    *)               echo "NOT VERIFIABLE: unknown target $TARGET" >&2; exit 3 ;;
esac
if [ -f "$STAGING/compiler/$want_compiler" ]; then
    ok "compiler staged: compiler/$want_compiler"
else
    fail "compiler/$want_compiler (a release with no compiler cannot build anything)"
fi

# The native half. Nothing else in the pipeline covers it -- READ, not assumed:
# build-release.sh calls copy_native_linux_compiler_to_staging "|| true" (:2214/:2217), so a
# failed native copy is non-fatal and was silent here too; assert_shipped_cross_compiler_
# matches_exec (:350) cmp's compiler/<staged_name>, i.e. the CROSS binary, and never looks
# for ppca64/ppcarm; and the ppcx64/ppca64 loop at :2412 is environmentoptions.xml seeding,
# not a gate. The helper DOES write its reason into COMPILER_NOTES.txt, so reprint that
# line here rather than making the reader re-derive the cause (it is the only place the
# "no native tarball" / "md5 mismatch" / "wrong architecture" distinction survives).
if [ -n "$want_native" ]; then
    native="$STAGING/compiler/$want_native"
    if [ ! -f "$native" ]; then
        fail "compiler/$want_native -- $TARGET ships NO natively-hosted compiler, so the"
        echo "         extracted tarball cannot compile anything ON the target. compiler/$want_compiler"
        echo "         is the x86_64 CROSS compiler and runs on the build host only."
        if [ -f "$STAGING/COMPILER_NOTES.txt" ]; then
            echo "         COMPILER_NOTES.txt says: $(grep -m1 '^NOTE:' "$STAGING/COMPILER_NOTES.txt" || echo '(no NOTE: line)')"
        fi
    elif ! command -v file >/dev/null 2>&1; then
        # A zero from an absent tool is VOID, not clean (c654), so refuse to judge rather
        # than passing a tree whose architecture nothing verified.
        echo "NOT VERIFIABLE: compiler/$want_native is staged but 'file' is not installed here," >&2
        echo "                so its architecture cannot be checked and the exename-clobber" >&2
        echo "                class (native overwritten by an x86_64 cross build) is invisible." >&2
        exit 3
    else
        native_desc=$(file -b "$native")
        if printf '%s' "$native_desc" | grep -q -- "$native_arch"; then
            ok "native compiler staged: compiler/$want_native ($native_desc)"
        else
            fail "compiler/$want_native is NOT a $TARGET binary -- exename clobber"
            echo "         expected 'file' to say: $native_arch"
            echo "         it says:                $native_desc"
            echo "         A native build for a non-host CPU defaults to the same exename as the"
            echo "         cross build, so this slot can be silently overwritten (seen 2026-09-10)."
        fi
    fi
fi

# ---------------------------------------------------------------- the two target shapes
if [[ "$TARGET" == *-darwin ]]; then
    echo "  shape: ships a BUILT IDE -- verifying classes are linked into the binary"
    exe="$STAGING/bin/lazarus"
    if [ ! -f "$exe" ]; then
        echo "NOT VERIFIABLE: $exe absent, yet this target is supposed to ship a built IDE." >&2
        echo "                Refusing to call the features missing over a binary that is not there." >&2
        exit 3
    fi
    # LIVENESS FIRST (c686): if the scan cannot find a marker that must be there, every
    # later "absent" is void and reporting it as a feature failure is worse than saying
    # nothing. Same rule as the harness arms -- assert the instrument ran before reading it.
    if ! grep -a -q -- "$IDE_LIVENESS_MARKER" "$exe" 2>/dev/null; then
        echo "NOT VERIFIABLE: '$IDE_LIVENESS_MARKER' not found in $exe." >&2
        echo "                The scan proves nothing about this file (truncated? not ours?)." >&2
        exit 3
    fi
    ok "binary scan is live ($IDE_LIVENESS_MARKER found in bin/lazarus)"
    for sym in $DOCKED_LAYOUT_CLASSES; do
        if grep -a -q -- "$sym" "$exe" 2>/dev/null; then ok "docked layout: $sym linked"
        else fail "docked layout class $sym is NOT in bin/lazarus (GOD mu3jfytu/mu66fghs)"; fi
    done
    if grep -a -q -- "$METADARKSTYLE_DSGN_SYMBOL" "$exe" 2>/dev/null; then
        ok "MetaDarkStyle design-time unit linked ($METADARKSTYLE_DSGN_SYMBOL)"
    else
        fail "$METADARKSTYLE_DSGN_SYMBOL is NOT in bin/lazarus (no Tools->Options->Theme page)"
    fi
else
    echo "  shape: ships SOURCES + TOOLS -- the user's IDE is built by auto-update, so the"
    echo "         deliverable is the sources' defaults plus the updater that builds them"

    # Docked single-window default (9b044e4527): the two packages are CORE, so the proof is
    # in the staged sources themselves, not in a commit id. Content, never provenance (c646).
    pkgbase="$STAGING/ide/packages/idepackager/pkgsysbasepkgs.pas"
    if [ -f "$pkgbase" ]; then
        for sym in libpAnchorDockingDsgn libpDockedFormEditor; do
            if grep -q -- "$sym" "$pkgbase"; then ok "core package enum carries $sym"
            else fail "$sym absent from staged pkgsysbasepkgs.pas -- docking is not core here"; fi
        done
    else
        fail "ide/packages/idepackager/pkgsysbasepkgs.pas (cannot judge the docked default)"
    fi
    if [ -f "$STAGING/ide/lazarus.pp" ]; then
        if grep -qE 'AnchorDockingDsgn, *DockedFormEditor' "$STAGING/ide/lazarus.pp"; then
            ok "ide/lazarus.pp uses AnchorDockingDsgn + DockedFormEditor"
        else
            fail "staged ide/lazarus.pp does not use the docking units"
        fi
    else
        fail "ide/lazarus.pp"
    fi

    # The updater IS the delivery mechanism on these targets, and it is the piece that was
    # broken for GOD twice (c634 commonx, c699 docking + the -Sci flag missing on exactly
    # the platform he runs). Verify it is STAGED and byte-identical to the rolled tree --
    # a stale updater in the tarball would rebuild nothing and report success.
    updaters=""
    case "$TARGET" in
        x86_64-win64) updaters="auto-update.bat auto-update.ps1" ;;
        x86_64-linux) updaters="auto-update.sh" ;;
        *)            echo "  note: $TARGET ships no updater by design (package_release case)" ;;
    esac
    for u in $updaters; do
        if [ ! -f "$STAGING/$u" ]; then
            fail "$u is not in the tarball -- this target has no way to build an IDE"
            continue
        fi
        if [ -f "$SRC_TREE/$u" ]; then
            a=$(md5sum < "$STAGING/$u" | cut -d' ' -f1)
            b=$(md5sum < "$SRC_TREE/$u" | cut -d' ' -f1)
            if [ "$a" = "$b" ]; then ok "$u staged, md5 identical to the rolled tree ($a)"
            else
                # NAME BOTH CAUSES, because they need opposite responses and the wording used
                # to imply only the first. On a checkout 30+ agents share, the likelier one is
                # that somebody edited the tree copy in the seconds between package_release
                # staging it and this check reading it -- the base moved under the roll, which
                # this gate is RIGHT to refuse, but "the updater differs" reads as "the updater
                # is broken" and sends the reader to the wrong file. The mtimes settle it.
                fail "$u in the tarball DIFFERS from the rolled tree ($a staged vs $b in tree)"
                echo "         staged $(date -ur "$STAGING/$u" +%FT%TZ 2>/dev/null)  tree $(date -ur "$SRC_TREE/$u" +%FT%TZ 2>/dev/null)"
                echo "         If the TREE copy is the newer one, the tree moved WHILE this roll"
                echo "         was packaging (another agent edited it) -- re-roll, do not debug $u."
                echo "         If the STAGED copy is newer, package_release staged the wrong file."
            fi
        else
            fail "$SRC_TREE/$u missing -- cannot prove the staged copy is current"
        fi
    done
    # Two specific fixes GOD is waiting on, asserted by CONTENT in the staged file.
    case "$TARGET" in
        x86_64-win64)
            ps1="$STAGING/auto-update.ps1"
            if [ -f "$ps1" ]; then
                grep -q -- '--build-ide=-Sci' "$ps1" \
                    && ok "auto-update.ps1 passes --build-ide=-Sci (e08afd4a5a/da8f854248)" \
                    || fail "auto-update.ps1 has no --build-ide=-Sci: the IDE build will die in checkcompileropts"
                grep -q 'Test-DockedLayoutInstalled' "$ps1" \
                    && ok "auto-update.ps1 carries the docked-layout verifier" \
                    || fail "auto-update.ps1 has no docked-layout verifier: a degraded IDE stays degraded"
            fi ;;
        x86_64-linux)
            sh="$STAGING/auto-update.sh"
            if [ -f "$sh" ]; then
                grep -q -- '--build-ide=-Sci' "$sh" \
                    && ok "auto-update.sh passes --build-ide=-Sci" \
                    || fail "auto-update.sh has no --build-ide=-Sci"
                grep -q 'test_docked_layout_installed' "$sh" \
                    && ok "auto-update.sh carries the docked-layout verifier" \
                    || fail "auto-update.sh has no docked-layout verifier"
            fi ;;
    esac
fi

# ---------------------------------------------------------------- what this asset contains
# Printed so the answer to "what is in this release?" is IN the release, instead of being
# re-derived by hand with merge-base --is-ancestor every time somebody asks (c698, c699).
echo ""
echo "--- RELEASE-INFO ---"
echo "target:            $TARGET"
if git -C "$SRC_TREE" rev-parse HEAD >/dev/null 2>&1; then
    echo "lazarus_commit:    $(git -C "$SRC_TREE" rev-parse HEAD)"
    echo "lazarus_date:      $(git -C "$SRC_TREE" log -1 --format=%cI HEAD)"
    echo "lazarus_branch:    $(git -C "$SRC_TREE" rev-parse --abbrev-ref HEAD)"
else
    # Unreadable git is UNKNOWN, never "up to date" -- the same rule the updaters follow.
    echo "lazarus_commit:    UNKNOWN (no readable git in $SRC_TREE)"
fi
[ -f "$STAGING/compiler/$want_compiler" ] &&
    echo "compiler_md5:      $(md5sum < "$STAGING/compiler/$want_compiler" | cut -d' ' -f1)  ($want_compiler)"
[ -n "$want_native" ] && [ -f "$STAGING/compiler/$want_native" ] &&
    echo "native_md5:        $(md5sum < "$STAGING/compiler/$want_native" | cut -d' ' -f1)  ($want_native)"
echo "rtl_ppu:           $rtl_ppu"
echo "package_unit_sets: $pkg_dirs"
echo "verified_at:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo ""
if [ "$problems" -gt 0 ]; then
    echo "END-STATE VERIFY FAILED: $problems check(s) missing for $TARGET" >&2
    exit 1
fi
echo "END-STATE VERIFY PASSED for $TARGET"
exit 0
