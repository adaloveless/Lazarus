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

# Where cross-target IDE builds keep their PrimaryConfigPath and compiler wrapper.
# NOT /tmp -- see build_darwin_ide. Single-sourced because three call sites have to
# agree on it: the one that BUILDS the IDE and the two that PACKAGE it.
BUILD_STATE_DIR="$HOME/.cache/lazarus-build"

# --- Build-step status + artifact freshness (Lars, c645 2026-09-10) ---------
# A darwin re-roll was one step from publishing a FOUR-MONTH-OLD IDE binary.
# Two independent mechanisms allowed that, and both are addressed here.
#
# 1. STATUS LAUNDERING. Build steps were written `make ... 2>&1 | tail -N` with
#    pipefail OFF, so the pipeline reports tail's exit 0 and a failed build walks
#    on. build_lazbuild's `| grep -E "...|Error"` was worse: it matched the very
#    word that signals failure and returned 0 for it. Measured, not assumed: a
#    make returning 2 produced exit 0 through both shapes.
# 2. PRESENCE, NEVER FRESHNESS. Every artifact copy tested only `[ -f "$x" ]`, so
#    a binary left by an earlier roll -- or by a DIFFERENT TARGET, when a later
#    link fails after an earlier one succeeded -- was packaged as if just built.
#
# Anything older than BUILD_EPOCH was not produced by this roll.
BUILD_EPOCH="$(date +%s)"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-$HOME/lazarus-build-logs/$DATE_STAMP}"

# run_build_step <logname> <summary-regex> -- <cmd...>
# Runs cmd with the FULL output tee'd to a log that outlives the roll, prints a
# filtered summary, and returns the COMMAND's status -- never the filter's.
# Keeping the whole log is the point: the undefined-symbol list that root-caused
# the darwin startlazarus failure had been cut off by `tail -10` for a month.
run_build_step() {
    local logname=$1; shift
    local summary_re=$1; shift
    [ "$1" = "--" ] && shift
    mkdir -p "$BUILD_LOG_DIR"
    local log="$BUILD_LOG_DIR/${logname}.log"
    local rc=0
    "$@" > "$log" 2>&1 || rc=$?
    grep -E "$summary_re" "$log" | tail -40 || true
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: build step '$logname' FAILED (exit $rc)."
        echo "       Full log retained at: $log"
        # Reprint the causal lines INSIDE the failure block. A human reading a
        # long roll log truncates it from the top, so the one line that names
        # the cause is exactly the line that never comes back.
        echo "--- diagnostics ---"
        grep -nE 'Undefined symbols|symbol\(s\) not found|^ld:|Fatal:|Error:' "$log" | head -20 || true
        echo "--- tail ---"
        tail -20 "$log"
    fi
    return $rc
}

# require_fresh_artifact <path> <label>
# Fails unless <path> exists AND was written by THIS roll. Presence alone is not
# evidence of a build.
require_fresh_artifact() {
    local path=$1
    local label=$2
    if [ ! -f "$path" ]; then
        echo "ERROR: $label MISSING at $path -- this roll never produced it."
        return 1
    fi
    local mtime
    mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo 0)
    if [ "$mtime" -lt "$BUILD_EPOCH" ]; then
        echo "ERROR: $label at $path is STALE."
        echo "       mtime $(date -d "@$mtime" 2>/dev/null || echo "$mtime") predates this roll" \
             "(started $(date -d "@$BUILD_EPOCH" 2>/dev/null || echo "$BUILD_EPOCH"))."
        echo "       Refusing to package a binary this roll did not build."
        return 1
    fi
    return 0
}

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

# resolve_exec_compiler <compiler-path>
# Echo the compiler path a build wrapper should EXEC, which is not always the one
# get_compiler_for_target names.
#
# THE DEFECT. FPC derives its executable path from the REAL path of the binary it
# was started as, and puts that directory on the unit, library and object search
# paths. $VP_DIR/compiler holds 207 .pas files beside the binaries, so exec'ing
# $VP_DIR/compiler/ppcx64 silently adds the compiler's own source tree to every
# search path. Measured here 2026-09-11 with both controls, -vut on a trivial unit
# through a wrapper of exactly the shape build_darwin_ide writes:
#     exec $VP_DIR/compiler/ppcx64 -n @<darwin cfg>  -> "Using executable path:
#         .../vibepascal/compiler/", 9 hits on .../vibepascal/compiler/ in the
#         trace, including "Using unit path: .../vibepascal/compiler/"
#     exec $VP_DIR/bin/ppcx64     -n @<darwin cfg>  -> "Using executable path:
#         .../vibepascal/bin/", 0 hits
# Both produced a .ppu, so the clean one is clean rather than broken. NOTE FPC
# prints the /mnt-prefixed realpath, so a grep for the literal $VP_DIR/compiler
# reads 0 and looks CLEAN when it is VOID -- match a substring.
#
# WHY IT HAS NOT BITTEN THE DARWIN ROLL YET, AND WHY THAT IS NOT PROTECTION.
# In that trace the compiler's own directory is unit path entry 158 OF 158 -- dead
# last, behind all 157 -Fu lines of vibepascal-darwin-x86_64.cfg, one of which
# (line 123) is $LAZARUS_DIR/components/fpdebug. So the right macho.pas wins on
# ORDER. But BOTH darwin cfgs are UNTRACKED in the VibePascal working copy
# (git ls-files --error-unmatch fails on each; the same check fires correctly on a
# file that IS tracked, so that is not a void result). There is no diff to notice
# one of those lines changing and nothing to revert to. That is a coincidence, not
# an immunity -- Bruno (BuildMaster_lazdev) found it, and it is why he authorised
# this change rather than the do-nothing option.
#
# AND THERE ARE THREE COLLISIONS, NOT ONE. Comparing the 207 compiler source names
# against the 3,657 unit names in this tree (excluding the vendored releases/ copy)
# gives exactly three, and all three are inside the IDE build's closure:
#     macho     components/fpdebug/macho.pas
#     compiler  ide/packages/ideconfig/compiler.pp
#     tokens    components/jcf2/Parse/Tokens.pas
# `tokens` needs a case-INSENSITIVE search to find; a lowercase `find -name` says
# it does not exist, which is how it stayed off the list.
#
# The rejections below mirror auto-update.sh resolve_vp_compiler, for the same
# reasons documented there: a symlink is resolved by FPC before exepath is computed
# and hashes as its target so no checksum can see it; bin/ is in upstream FPC's
# .gitignore so in a checkout it can go stale and silently hand the build an OLD
# compiler; sources in bin/ shadow exactly like compiler/ does. Anything rejected
# falls through to a private copy, which has the property by construction.
#
# Failure is NEVER fatal here: every path echoes something runnable. The worst case
# is the status quo, which is what the roll does today.
resolve_exec_compiler() {
    local cc=$1
    local base src_dir installed copy_dir copy reject=""
    [ -x "$cc" ] || { echo "$cc"; return 0; }
    base=$(basename "$cc")
    src_dir=$(dirname "$(readlink -f "$cc" 2>/dev/null || echo "$cc")")

    # Nothing beside the binary to shadow => leave it alone. Checked against the
    # RESOLVED directory: $VP_DIR/compiler/ppcrossaarch64 is itself a symlink to
    # ppcrossa64 in that same directory, so the naive dirname would be right here
    # by luck and wrong for any link that points elsewhere.
    if [ -z "$(find "$src_dir" -maxdepth 1 -name '*.pas' -print -quit 2>/dev/null)" ]; then
        echo "$cc"; return 0
    fi

    installed="$VP_DIR/bin/$base"
    if [ -x "$installed" ]; then
        if [ -L "$installed" ]; then
            reject="it is a symlink and FPC follows it before computing exepath"
        elif [ ! -f "$installed" ]; then
            reject="it is not a regular file"
        elif [ -n "$(find "$VP_DIR/bin" -maxdepth 1 -name '*.pas' -print -quit 2>/dev/null)" ]; then
            reject="$VP_DIR/bin holds Pascal sources, which shadow exactly like compiler/ does"
        elif ! cmp -s "$installed" "$cc"; then
            reject="it differs from $cc, so it is a stale copy of some other build"
        else
            echo "$installed"; return 0
        fi
        echo "       ignoring $installed: $reject" >&2
    fi

    copy_dir="$BUILD_STATE_DIR/compiler"
    copy="$copy_dir/$base"
    mkdir -p "$copy_dir" 2>/dev/null || { echo "$cc"; return 0; }
    if [ ! -f "$copy" ] || [ "$cc" -nt "$copy" ]; then
        cp -f "$cc" "$copy" 2>/dev/null || { echo "$cc"; return 0; }
        chmod +x "$copy" 2>/dev/null || true
    fi
    echo "$copy"
}

# get_darwin_ide_binary <target>
# Where the darwin IDE binary is STAGED for packaging, once build_darwin_ide has
# lifted it out of the per-build PrimaryConfigPath.
#
# lazbuild writes it INSIDE that pcp. MEASURED 2026-09-10 (Bruno), not inferred:
# TBuildLazarusProfile's DefaultTargetDirectory is '$(ConfDir)/bin'
# (ide/packages/ideconfig/miscoptions.pas:267), ConfDir being the PrimaryConfigPath,
# and lazbuild appends $(TargetCPU)-$(TargetOS). A full-log run of build_darwin_ide's
# exact invocation ends the compiler call with
#     Info: (lazarus) Param[12]="-o<pcp>/bin/x86_64-darwin/lazarus"
# and leaves a 69497312-byte Mach-O 64-bit x86_64 executable there. The aarch64 half
# of that shape is corroborated by the May-13 default-pcp artifacts, which lazbuild
# wrote to bin/aarch64-darwin/lazarus back when the default pcp was still in use.
#
# But build_darwin_ide TEARS THE pcp DOWN when it returns, deliberately -- per-build
# isolation, no cross-target leak through staticpackages.inc -- so the packaging
# sites cannot read it there. Pointing them into the pcp only swaps a stale-binary
# abort for a missing-binary abort, and the roll still never finishes. Hence a
# staging path that OUTLIVES the pcp, single-sourced because three sites have to
# agree on it: the one that BUILDS and the two that PACKAGE. That drift is the bug.
#
# It is NOT $HOME/.lazarus/bin/<target>/lazarus. That is the same expression under
# the DEFAULT pcp, and nothing has written it since --pcp came in (da5c70f139,
# 2026-05-13 06:29) -- the copy on this builder is dated 2026-05-13 05:27, 62 minutes
# BEFORE that commit. Reading it is what let r25 ship a four-month-old IDE in BOTH
# darwin .apps: each shipped Contents/MacOS/lazarus-bin is byte-identical (md5
# d939a2af2427d8515deffd4494243766 x86_64, 42845d195b0879fdce30a28cf3fac5af aarch64)
# to that May-13 binary run through `rcodesign sign`. The 905KB size difference was
# the ad-hoc signature, not a rebuild.
get_darwin_ide_binary() {
    local target=$1
    echo "$BUILD_STATE_DIR/ide/${target}/lazarus"
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

get_latest_vp_bin_tarball() {
    # $1 = dist/<subdir>, $2 = target token in the filename.
    # Same version-selection rule as get_latest_win64_bin_tarball (highest numeric v<N>),
    # generalised so the Linux cross targets can use it too.
    find "$VP_DIR/dist/$1" -maxdepth 1 -type f -name "vibepascal-v*-$2-bin.tar.gz" 2>/dev/null |
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

copy_native_linux_compiler_to_staging() {
    # Bundle the NATIVE target-arch VibePascal compiler for a Linux cross target.
    # $1 staging  $2 target  $3 native exename  $4 expected `file` arch substring
    #
    # WHY (D006 class -- "can a user go from extract to a working build with only what is
    # inside?"): these tarballs bundled compiler/ppcross<cpu>, which is an x86_64 ELF. On the
    # Pi the tarball targets it cannot run at all, so the answer was no. Otto ships a genuinely
    # native compiler in dist/<target>/vibepascal-v*-<target>-bin.tar.gz. The cross compiler is
    # still copied alongside (useful on the build host), so this is additive.
    #
    # TWO GUARDS, both learned the hard way -- neither is optional:
    #   D003: hash the extracted binary against the md5 the tarball's own VERSION.txt declares,
    #         so a stale or swapped member cannot ship unnoticed.
    #   ppcarm clobber (2026-09-10): cross and native builds for the same non-host CPU BOTH
    #         default to exename ppc<cpu>, so a native build silently overwrites the cross one.
    #         It had already happened in the shared tree -- compiler/ppcarm was an x86_64 ELF.
    #         The FILENAME is not evidence of the architecture; check `file` output.
    # Either guard failing leaves the cross compiler in place and says so loudly in
    # COMPILER_NOTES.txt, rather than silently shipping a compiler that cannot run.
    local staging=$1 target=$2 exename=$3 arch_pattern=$4
    local notes="$staging/COMPILER_NOTES.txt"
    local tarball member declared actual out="$staging/compiler/$exename"

    tarball=$(get_latest_vp_bin_tarball "$target" "$target")
    if [ -z "$tarball" ]; then
        echo "WARNING: no native $target compiler tarball under dist/$target."
        echo "NOTE: no native $target compiler bundled. compiler/ppcross* is an x86_64 binary and will NOT run on $target." > "$notes"
        return 1
    fi

    member=$(tar -tzf "$tarball" | awk -v n="$exename" '$0 ~ "(^|/)bin/" n "$" { print; exit }')
    if [ -z "$member" ]; then
        echo "WARNING: $(basename "$tarball") does not contain bin/$exename."
        echo "NOTE: no native $target compiler bundled ($(basename "$tarball") has no bin/$exename)." > "$notes"
        return 1
    fi

    tar -xOzf "$tarball" "$member" > "$out" || { rm -f "$out"; return 1; }

    declared=$(tar -xOzf "$tarball" --wildcards '*VERSION.txt' 2>/dev/null |
               awk -v n="$exename" '$0 ~ "bin/" n "[[:space:]]" { for (i=1;i<=NF;i++) if ($i=="md5") { print $(i+1); exit } }')
    actual=$(md5sum "$out" | cut -d' ' -f1)
    if [ -n "$declared" ] && [ "$declared" != "$actual" ]; then
        echo "ERROR: $exename md5 $actual does not match $declared declared in $(basename "$tarball") VERSION.txt."
        rm -f "$out"
        echo "NOTE: native $target compiler REJECTED (md5 mismatch vs its own VERSION.txt). Not bundled." > "$notes"
        return 1
    fi

    if ! file -b "$out" | grep -q "$arch_pattern"; then
        echo "ERROR: $exename is not a $target binary: $(file -b "$out")"
        rm -f "$out"
        echo "NOTE: native $target compiler REJECTED (wrong architecture -- exename clobber). Not bundled." > "$notes"
        return 1
    fi

    chmod +x "$out"
    {
        echo "Bundled native $target VibePascal compiler as compiler/$exename"
        echo "  source: $(basename "$tarball")"
        echo "  md5:    $actual${declared:+ (matches VERSION.txt)}"
        echo "  arch:   $(file -b "$out")"
        echo "compiler/ppcross* is the x86_64 CROSS compiler and runs on the BUILD host, not on $target."
        echo ""
        echo "REQUIRES BINUTILS ON THE TARGET MACHINE. This tarball bundles a compiler and the"
        echo "RTL units, but no assembler and no linker -- verified, the archive contains zero"
        echo "as/ld/ar binaries. compiler/$exename shells out to 'as' and 'ld' from PATH, so"
        echo "$target needs its own binutils installed (Debian/Raspberry Pi OS: apt install"
        echo "binutils). If they are missing, or if PATH resolves them to another architecture,"
        echo "the compile dies at 'Assembling' with an invalid -march= option, or at 'Linking'"
        echo "with 'skipping incompatible ... system.o'. Neither message names the real cause."
    } > "$notes"
    echo "Bundled native $target compiler $exename from $(basename "$tarball")."
    return 0
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

# A package whose loadcheck failure is KNOWN-BENIGN on a given target. Kept tiny and
# dated on purpose: an allowlist is a liability, so every entry names what was measured
# and when, and anything NOT listed still aborts the roll.
vp_loadcheck_known_benign() {
    # $1=target  $2=MODE (the leading all-caps token of the loadcheck line)  $3=package
    #
    # THIS ALLOWLIST IS EMPTY, AND THAT IS THE FINDING RATHER THAN AN OVERSIGHT.
    # It carried exactly one entry for the whole of its life -- x86_64-win64:FAILED:librsvg
    # -- on the justification that rsvg.ppu "genuinely cannot load on this target, it is
    # not staleness and no rebuild fixes it". THAT JUSTIFICATION WAS FALSE, and the
    # measurement that retired it is my own: 2026-09-11, live shared tree,
    #   dist/unit-set-loadcheck.sh x86_64-win64 compiler/ppcx64 $VP_DIR
    #   -> loadcheck x86_64-win64: 111/111 packages load clean, 0 problem(s)   rc=0
    # librsvg loads. So does gstreamer, which had never built for win64 at all.
    #
    # WHY IT WAS REALLY FAILING (Otto, vibepascal 30e82e4fee): a FAILED win64 gtk2 build on
    # 2026-08-18 left buildgtk2.ppu behind as an ORPHAN. The fpmake build driver is the
    # package's only EXPLICIT target, so with that one ppu present fpmake reported
    # "[100%] Compiled package gtk2" and built NOTHING, on every run, forever. Deleting the
    # orphan and re-running the UNCHANGED make line built all 12 units in seconds, and
    # rsvg.ppu then resolved glib2. Nothing in the package sources needed changing and
    # nothing needed allowlisting.
    #
    # SO THE ENTRY WAS NEVER WAVING THROUGH A LIMIT OF THE TARGET. It was waving through a
    # wrecked unit dir for three weeks, and r25's shipped win64 asset was cut from that
    # set. An allowlist entry is a standing promise that a symptom is harmless; this one
    # outlived its evidence and would now HIDE a regression of the exact defect that was
    # just fixed. Removed rather than kept "just in case": a benign failure that nobody can
    # currently reproduce is not benign, it is unmeasured.
    #
    # THE MECHANISM STAYS, KEYED target:MODE:package, because the KEY is the part worth
    # keeping. Every justification is a story about ONE symptom, so an entry may only ever
    # fire on that symptom. FAILED means the unit could not be RESOLVED. RECOMPILED means
    # it resolved and FPC rebuilt it anyway because recorded dependency CRCs no longer
    # matched -- staleness, the exact thing this gate exists to catch. DRIVER-ONLY means
    # the dir holds nothing but the wreckage of a failed build. Three different findings;
    # one entry must never cover two of them.
    #
    # Until 2026-09-11 that scope was FAILED-only BY ACCIDENT: the caller captured with
    # `[^:]*`, which stops at a colon, and a RECOMPILED line carries no colon after the
    # package name -- so the name never reached this function intact and no entry could
    # match it. It failed CLOSED, which is the right direction, but a scope set by a
    # word-splitting bug is one refactor away from silently widening. Found by Lars
    # 2026-09-10; extractor fixed below, scope now written down instead of inferred.
    #
    # TO ADD AN ENTRY: reproduce the symptom on the real tool first and paste the run into
    # the comment. Do not add one from a sentence written about a different symptom.
    case "$1:$2:$3" in
        # No live entries. The shape, deliberately left inert:
        #   x86_64-win64:FAILED:librsvg) return 0 ;;
        *) ;;
    esac
    return 1
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

    # WHY THIS GATE EXISTS. It used to be `pkg_count -lt 10`, an EXISTENCE test standing
    # in for a usability test -- the same shape as D003 (r16 shipped a v39 compiler
    # announced as v42 because packaging checked shape and never content). Measured
    # 2026-09-10: 118 x86_64-darwin package unit dirs sat beside a freshly rebuilt RTL,
    # so this printed "VibePascal packages ready for x86_64-darwin (118 packages)" and
    # SKIPPED -- and the roll died five seconds later with
    # `Fatal: (10022) Can't find unit Variants used by DB`. A count of 118 was true and
    # meaningless. "How many are there" is the wrong question.
    #
    # WHY IT IS NOT AN MTIME SWEEP, WHICH IS WHAT I WROTE FIRST AND PUSHED TO THIS BRANCH.
    # The first version asked "is any package unit older than rtl/units/<target>/system.ppu"
    # and rebuilt a majority-stale set. That predicate is WRONG, and the one target it
    # changed behaviour on is the target it is wrong about:
    #
    #   x86_64-linux, 2026-09-10: 146 of 146 unit dirs are SIXTEEN DAYS older than the
    #   RTL -- and all 146 load clean. The 09-03 RTL rebuild re-emitted BYTE-IDENTICAL
    #   ppus (105 of 105 identical to the installed 3.3.1 set, system.ppu md5
    #   19bbad742165a073b148d8c650cc632c on both sides), so it moved mtimes and changed
    #   nothing else. The mtime gate moved 146 GOOD unit dirs to .stale-units/ and forced
    #   a pointless 146-package rebuild -- driven and confirmed on a fixture, not argued.
    #
    # mtime and ABI validity are INDEPENDENT. What actually kills a roll is a unit whose
    # recorded dependency CRCs no longer match the RTL it is about to be compiled against,
    # so measure THAT, with Otto's dist/unit-set-loadcheck.sh (vibepascal f5d7308485):
    # one program per package using every unit it ships, `-Cn` so a missing .so cannot
    # fake a failure, `-n` so the host's ~/.fpc.cfg cannot resolve units from OUTSIDE the
    # tree, `-FU` at a scratch dir so a silent recompile can neither touch the tree nor
    # pass unnoticed. 45s for x86_64-linux's 146 packages against a 40-minute roll.
    # Verified in BOTH directions before being trusted -- a harness that has quietly
    # stopped being able to fail proves nothing: real tree 146/146 rc=0, and the
    # negative-control tree (~/src/vibepascal-slices/linux-pkg-freshness/) 123/146,
    # 23 problems, rc=1, reproducing this roll's own "Can't find unit Variants used by
    # DB" verbatim.
    #
    # WHY A FAILED LOADCHECK DOES NOT AUTO-REBUILD, WHICH IS THE THIRD VERSION OF THIS
    # GATE AND THE REASON THE SIX-TARGET SWEEP IS MANDATORY. Sweeping all six with the
    # real script on 2026-09-10 says a bare `rc!=0 -> rebuild` rule ALSO over-fires, on
    # two of six targets, for two DIFFERENT reasons neither of which is staleness:
    #
    # FIRST SWEEP, 2026-09-10 22:45Z, against loadcheck de075cff4e -- kept because it is
    # what bought two of the rules below, and deleting the measurement that justified a
    # rule leaves the rule looking arbitrary:
    #
    #   x86_64-linux   146/146 clean      rc=0
    #   arm-linux      142/142 clean      rc=0
    #   x86_64-darwin  118/118 clean      rc=0
    #   aarch64-darwin 115/115 clean      rc=0
    #   x86_64-win64   108/110, 2 fail    -> gtk2 + librsvg
    #   aarch64-linux    0/143, all fail  -> "Fatal error: invalid -march= option:
    #                                        `armv8-a'" -- the HOST ASSEMBLER refusing
    #                                        the job, not a unit failing to load.
    #
    # Both of those were reported to Otto rather than worked around here, and BOTH ARE
    # NOW FIXED IN THE TOOL. RE-SWEPT 2026-09-10 23:20Z against f5d7308485, both changed
    # targets re-measured with the compiler get_compiler_for_target actually passes:
    #
    #   aarch64-linux  143/143 clean      rc=0   <-- was 0/143
    #   x86_64-win64   108/109, 1 fail    rc=1   <-- was 108/110, 2 fail
    #   (the clean four are byte-for-byte the same numbers as above)
    #
    # THE aarch64 FIX WAS `-s`, NOT A CFG OR AN `-XP` PREFIX, and the reason matters to
    # anyone tempted to "help" this gate along by feeding loadcheck a cfg: `-Cn` already
    # suppressed the LINK, but the compiler still ASSEMBLED, while unit loading and
    # dependency-CRC checking both happen at COMPILE time -- so the script never needed
    # an assembler at all. `-s` ("do not call assembler and linker") deletes the binutils
    # dependency outright and needs nothing installed or kept in sync with a roll. A cfg
    # would have been WORSE: it puts the INSTALLED /home/jason/fpc/.../units/<target>
    # dirs back on the search path and defeats the `-n` that stops the sweep resolving
    # units from outside the tree. DO NOT ADD A CFG HERE.
    # (Why arm-linux passed all along while aarch64 did not: arm uses FPC's INTERNAL
    # assembler and never hands arguments to as(1); aarch64 uses external GAS. The host
    # as(1) rejects arm's arguments too -- arm simply never asks. Different code path,
    # not a more robust target.)
    #
    # win64's gtk2 was the tool miscounting an fpmake BUILD DRIVER as a unit; loadcheck
    # now SKIPs build drivers and drops the denominator to 109. librsvg survives as the
    # ONE genuine benign failure -- see vp_loadcheck_known_benign.
    #
    # So: an ALL-FAIL result means the harness cannot run here, not that 143 unit sets
    # rotted simultaneously -- warn and continue. NOTE THAT NO LIVE TARGET TRIGGERS THAT
    # ARM ANY MORE, and it STAYS, because it is what stopped a bad harness answer moving
    # 143 healthy unit dirs aside: a unit set does not rot all at once, a toolchain does.
    # A short, dated allowlist covers the one remaining benign win64 failure. ANYTHING
    # ELSE ABORTS THE ROLL rather than rebuilding it, because on a starved box a
    # half-finished rebuild leaves a PARTIAL unit set that is strictly worse than the one
    # it replaced, and Policy #13 forbids unrequested rebuilding.
    # VP_FORCE_STALE_REBUILD=1 opts into the repair; VP_SKIP_LOADCHECK=1 opts out of the
    # measurement. Either way this NEVER AGAIN prints a bare "ready" over a set it has
    # been told is broken -- that false claim is the actual defect being fixed here.
    #
    # HONEST LIMIT, carry it wherever a green run is quoted: this proves the unit set
    # LOADS, i.e. its recorded dependency CRCs still match. It does NOT prove those
    # objects assemble, link or run -- `-Cn` skips the link and `-s` skips the assembler
    # ON PURPOSE, so a wrong-arch or truncated .o PASSES here. Runtime proof is a
    # separate artifact (dist/arm-runtime-proof.sh, dist/win64-runtime-proof.sh).
    local pkg_dirs pkg_count
    pkg_dirs=$(find "$VP_DIR/packages" -type d -name "$target" -path "*/units/*" 2>/dev/null)
    pkg_count=$(printf '%s' "$pkg_dirs" | grep -c . || true)

    local loadcheck="$VP_DIR/dist/unit-set-loadcheck.sh"
    # NOT /tmp: same reason as build_darwin_ide -- /tmp here is a 2G tmpfs shared by ~30
    # agents and has been seen at 97% full and cleared under a running build.
    local lc_scratch="$BUILD_STATE_DIR/loadcheck"
    local need_rebuild="" verdict="" lc_out="$lc_scratch/$target.loadcheck.log"

    if [ "$pkg_count" -lt 10 ]; then
        need_rebuild="count"
    elif [ -n "${VP_FORCE_STALE_REBUILD:-}" ]; then
        echo "VP_FORCE_STALE_REBUILD set: rebuilding $target packages without measuring."
        need_rebuild="forced"
    elif [ -n "${VP_SKIP_LOADCHECK:-}" ]; then
        verdict="loadcheck SKIPPED at operator request"
        echo "WARNING: VP_SKIP_LOADCHECK is set, so the $target package unit set is NOT"
        echo "         being verified. The count below is an existence check, not a"
        echo "         usability one -- the exact blind spot that let a doomed unit set"
        echo "         into a 40-minute build on 2026-09-10."
    elif [ -x "$loadcheck" ]; then
        echo "Verifying the $target VibePascal package unit set actually LOADS (~45s)..."
        mkdir -p "$lc_scratch"
        local lc_rc=0
        TMPDIR="$lc_scratch" "$loadcheck" "$target" "$compiler" "$VP_DIR" > "$lc_out" 2>&1 || lc_rc=$?
        cat "$lc_out"
        # AN INTERRUPTED SWEEP IS A THIRD OUTCOME AND IT IS NOT READABLE FROM THE rc ALONE.
        # loadcheck grew an EXIT/HUP/INT/TERM trap (vibepascal f791257d51) that prints an
        # ABORTED header plus a summary line and exits 128+signal -- 143 for TERM. Every rc
        # outside {0,1} used to land in the UNAVAILABLE arm below, which says "the harness
        # never ran" and walks on. That is WRONG for this shape and wrongly reassuring: the
        # sweep DID run, it was killed part-way, and the log can already NAME packages that
        # failed before the kill. Bucketing it with "no compiler at <path>" throws measured
        # badness away. So the discriminator is the ABORTED header, not the number:
        #   rc=2      -> harness unusable, says NOTHING about the tree   (cy1110, unchanged)
        #   rc=1      -> tree measured and bad                            (cy1110, unchanged)
        #   ABORTED   -> tree PARTIALLY measured, measurement unfinished  (new, count it)
        # Do NOT collapse any two of those three. Matching on the token rather than on
        # 128+n also means a kill by any signal Otto adds a handler for is caught here
        # without me editing a list -- the same reason this gate counts all-caps headers
        # structurally instead of enumerating the words it knows today.
        local lc_aborted=0
        grep -q '^ABORTED ' "$lc_out" 2>/dev/null && lc_aborted=1
        if [ "$lc_rc" = 0 ] && [ "$lc_aborted" = 0 ]; then
            verdict="loadcheck PASS"
        elif [ "$lc_rc" != 1 ] && [ "$lc_aborted" = 0 ]; then
            # rc>=2 is the SCRIPT failing (no compiler, no RTL, cannot mktemp), not the
            # unit set failing. Do not rebuild 146 packages because a harness broke, and
            # do not silently claim the set is fine either.
            verdict="loadcheck UNAVAILABLE (rc=$lc_rc)"
            echo "WARNING: $loadcheck could not run (rc=$lc_rc)."
            echo "         The $target unit set is UNVERIFIED. If this roll fails with"
            echo "         \"Can't find unit <X> used by <Y>\", it is the unit set, not the source."
        else
            local lc_bad lc_total lc_ok lc_prob lc_unknown lc_real=0 lc_mode p
            # WHAT COUNTS AS A PROBLEM LINE IS THE EMITTER'S DECISION, NOT MINE.
            # loadcheck prints ONE header line per problem package and the leading ALL-CAPS
            # token is the mode: FAILED (could not resolve), RECOMPILED (resolved, then
            # rebuilt on load -- staleness) and, since vibepascal 30e82e4fee, DRIVER-ONLY
            # (the dir holds only fpmake build drivers, i.e. the wreckage of a failed build,
            # whose mere presence then makes every later fpmake run report the package built
            # while doing no work).
            # MATCHING THE TOKEN CLASS RATHER THAN THE THREE NAMES IS DELIBERATE. This file
            # named FAILED|RECOMPILED for exactly one day and the emitter grew a third shape
            # that same night (01:06Z). Measured on the real tool against a real driver-only
            # dir before this change: the name-list version printed
            #   "NOTE: 0 x86_64-win64 package(s) failed the loadcheck and ALL of them are
            #          known-benign for this target. Continuing."
            # and returned PASS on rc=1 -- a green gate asserting a clean bill of health
            # over the precise defect that had kept win64 gtk2 unbuilt for three weeks.
            # A gate that must be edited every time the tool learns a new word is a gate
            # that is silently green in between.
            # SKIPPED IS EXCLUDED, and only SKIPPED: it is the one all-caps line that was
            # never a problem -- the pre-30e82e4fee tool printed it for driver-only dirs and
            # deliberately left them out of its own count. Excluding it keeps this gate
            # correct against an older tool as well as the current one.
            lc_bad=$(grep -E '^[A-Z][A-Z0-9-]* ' "$lc_out" 2>/dev/null | grep -c -v '^SKIPPED ' || true)
            lc_total=$(sed -n 's/.*: \([0-9]*\)\/\([0-9]*\) packages load clean.*/\2/p' "$lc_out" | tail -1)
            [ -n "$lc_total" ] || lc_total=0
            # The NUMERATOR too, and only the INTERRUPTED arm reads it: on a killed sweep
            # "how much got judged" is the only honest thing that can be said, and saying
            # it is what stops "UNVERIFIED" being heard as "nothing happened".
            lc_ok=$(sed -n 's/.*: \([0-9]*\)\/\([0-9]*\) packages load clean.*/\1/p' "$lc_out" | tail -1)
            [ -n "$lc_ok" ] || lc_ok=0
            # THE TOOL'S OWN PROBLEM COUNT, reconciled against my line count. It is the only
            # number in the log that is authoritative about how many packages the tool
            # considered broken, and comparing the two is what catches a shape I cannot
            # parse AT ALL: a problem the tool counted and this gate never saw must not be
            # read as "no problem". -1 means the summary line is missing entirely.
            lc_prob=$(sed -n 's/.*packages load clean, \([0-9]*\) problem(s).*/\1/p' "$lc_out" | tail -1)
            [ -n "$lc_prob" ] || lc_prob=-1
            lc_unknown=0
            [ "$lc_prob" -gt "$lc_bad" ] && lc_unknown=$((lc_prob - lc_bad))
            # ONE LOG LINE IN, ONE PACKAGE NAME OUT. `[^ :]*` stops at the first space OR
            # colon, which is what makes BOTH emitted shapes yield a bare package name:
            #     FAILED <pkg>:                                    <- stops at the colon
            #     RECOMPILED <pkg> -- N unit(s) rebuilt on load:   <- stops at the space
            # The old `[^:]*` ran to the colon at END OF LINE on the RECOMPILED shape, and
            # the unquoted `for p in $( )` then split that phrase into SEVEN words: ONE
            # recompiled package reported as seven, and no allowlist entry could ever match
            # it. lc_bad counts LINES and was always right, so the two numbers disagreed.
            # AND THE LOOP IS FED BY A HEREDOC, NOT A PIPE -- a pipe puts it in a subshell
            # and lc_real silently stays 0 no matter what the log says. Do not "simplify".
            while read -r lc_mode p; do
                [ -n "$p" ] || continue
                # ABORTED IS NOT A PACKAGE. The word after it is the TARGET, and the line
                # means the sweep was killed. It STAYS counted in lc_bad -- Otto counts it
                # in his own problem total (bad+1) precisely so the reconciliation above
                # still closes -- but counting it as a unit set that does not load would
                # print "1 of 24 package unit set(s) do not load" and send the operator to
                # VP_FORCE_STALE_REBUILD=1, rebuilding the whole package set because a
                # process got a signal. lc_real must mean PACKAGES, and only packages.
                [ "$lc_mode" = ABORTED ] && continue
                vp_loadcheck_known_benign "$target" "$lc_mode" "$p" || lc_real=$((lc_real + 1))
            done <<EOF
$(sed -n 's/^\([A-Z][A-Z0-9-]*\) \([^ :]*\).*/\1 \2/p' "$lc_out" | grep -v '^SKIPPED ')
EOF
            if [ "$lc_prob" -lt 0 ]; then
                # rc=1 but NO summary line: the tool died part-way through its own sweep.
                # That is a harness failure, not a unit set failure, so it is handled like
                # rc>=2 -- loud and UNVERIFIED, not a reason to rebuild 146 packages and
                # not a reason to abort a roll.
                verdict="loadcheck UNUSABLE (no summary line)"
                echo "WARNING: $loadcheck exited 1 but printed no summary line, so its own"
                echo "         problem count cannot be read and this gate cannot reconcile"
                echo "         against it. The $target unit set is UNVERIFIED; continuing."
            elif [ "$lc_unknown" -gt 0 ]; then
                echo "ERROR: $loadcheck reported $lc_prob problem(s) on $target but only $lc_bad"
                echo "       of them are in a line shape this gate can classify -- $lc_unknown"
                echo "       problem(s) went unread. A PASS here would be an assertion about"
                echo "       lines that were never examined. Full log: $lc_out"
                echo "       Fix: teach the extractor above the new shape, then re-run."
                exit 1
            elif [ "$lc_aborted" = 1 ]; then
                # THE SWEEP WAS KILLED. Reconciliation has already closed (the ABORTED
                # header is counted on both sides), so whatever WAS measured is readable
                # and must not be thrown away -- that is the whole reason this arm exists
                # ahead of the "every package failed" one. Two outcomes, and they are not
                # the same finding:
                if [ "$lc_real" -gt 0 ]; then
                    echo "ERROR: the $target loadcheck was KILLED mid-sweep, but it had already"
                    echo "       named $lc_real failing package(s) before it died (see above)."
                    echo "       Refusing to build on a unit set that was measured bad -- an"
                    echo "       interrupted measurement does not un-measure what it found, and"
                    echo "       there may be MORE: the packages after the kill were never judged."
                    echo "       Full log: $lc_out"
                    echo "       Re-run the loadcheck to completion; if it still names packages,"
                    echo "       re-run this with VP_FORCE_STALE_REBUILD=1 to rebuild the set."
                    exit 1
                fi
                verdict="loadcheck INTERRUPTED (rc=$lc_rc, $lc_ok/$lc_total judged)"
                echo "WARNING: the $target loadcheck was killed before it finished (rc=$lc_rc)."
                echo "         $lc_ok of $lc_total package(s) were judged and none of them failed,"
                echo "         but the rest were never measured, so this is NOT a pass. The"
                echo "         $target unit set is UNVERIFIED; continuing."
                echo "         If something is killing builds on this box, that is the thing to"
                echo "         fix -- check dmesg for the OOM killer before re-rolling."
            elif [ "$lc_total" -gt 0 ] && [ "$lc_bad" -ge "$lc_total" ]; then
                # EVERY package failed. A unit set does not rot all at once; a toolchain
                # does fail all at once. Treat this as an unusable harness, not as 143
                # simultaneously broken packages.
                verdict="loadcheck UNUSABLE on this host ($lc_bad/$lc_total failed)"
                echo "WARNING: every $target package failed the loadcheck ($lc_bad of $lc_total)."
                echo "         That is a harness/toolchain problem, not a unit set problem --"
                echo "         check the first error above for an assembler or linker message."
                echo "         The $target unit set is UNVERIFIED; continuing."
            elif [ "$lc_real" -gt 0 ]; then
                echo "ERROR: $lc_real of $lc_total $target package unit set(s) do not load against"
                echo "       rtl/units/$target. Named above; full log: $lc_out"
                echo "       Refusing to start a build on them -- it dies on its first unit with"
                echo "       \"Can't find unit <X>\" and blames the SOURCE rather than the unit set."
                echo "       Re-run with VP_FORCE_STALE_REBUILD=1 to rebuild the unit set first."
                exit 1
            elif [ "$lc_bad" -gt 0 ]; then
                verdict="loadcheck PASS ($lc_bad known-benign)"
                echo "NOTE: $lc_bad $target package(s) failed the loadcheck and ALL of them are"
                echo "      known-benign for this target (see vp_loadcheck_known_benign). Continuing."
            else
                # rc=1 with nothing to show for it. DO NOT print "0 package(s) failed and
                # ALL of them are known-benign" -- that sentence is vacuously true and reads
                # as a clean bill of health. It is exactly what this gate printed over a
                # real DRIVER-ONLY defect on 2026-09-11. Belt and braces with lc_unknown
                # above: that branch catches a miscount, this one catches a miscount whose
                # summary line ALSO says zero.
                verdict="loadcheck UNUSABLE (rc=1, no problem package named)"
                echo "WARNING: $loadcheck exited 1 but named no problem package that this gate"
                echo "         could read. The $target unit set is UNVERIFIED; continuing."
            fi
        fi
    else
        verdict="loadcheck ABSENT"
        echo "WARNING: no $loadcheck, so the $target unit set is UNVERIFIED."
        echo "         Expected it in the VibePascal tree (de075cff4e, fixed in f5d7308485)."
    fi

    # INFORMATIONAL ONLY -- NEVER A GATE. Reported because the mtime skew is real, looks
    # alarming, and cost two of us an evening on 2026-09-10 before we established it was
    # harmless. Printing it next to a loadcheck PASS is what stops the next person
    # rediscovering "the landmine" and rebuilding 146 good packages over it.
    case "$verdict" in
    "loadcheck PASS"*)
        if [ -f "$rtl_units/system.ppu" ]; then
            local d older=0
            while IFS= read -r d; do
                [ -n "$d" ] || continue
                if [ -n "$(find "$d" -name '*.ppu' ! -newer "$rtl_units/system.ppu" -print -quit 2>/dev/null)" ]; then
                    older=$((older + 1))
                fi
            done <<EOF
$pkg_dirs
EOF
            if [ "$older" -gt 0 ]; then
                echo "NOTE: $older of $pkg_count $target unit dir(s) predate rtl/units/$target/system.ppu"
                echo "      ($(date -r "$rtl_units/system.ppu" '+%F %T' 2>/dev/null)) and ALL OF THEM LOAD CLEAN."
                echo "      mtime is not the discriminator here -- do not rebuild on this alone."
            fi
        fi ;;
    esac

    if [ -n "$need_rebuild" ]; then
        if [ "$need_rebuild" = count ]; then
            echo "Only $pkg_count VibePascal package unit set(s) found for $target. Building packages..."
        else
            # A plain `make packages` here is a NO-OP and that is the trap: fpmake compares
            # package SOURCES to their units, the sources have not changed, so it returns
            # rc=0 in about a second having rebuilt nothing. Measured 2026-09-10. Moving
            # the unit dir aside is not a workaround for a stubborn tool -- an ABSENT unit
            # dir is the exact input that makes fpmake rebuild it cleanly (Otto recovered
            # 15 x86_64-darwin dirs this way the same day). Moved, never deleted, so a bad
            # rebuild is recoverable.
            local attic="$VP_DIR/.stale-units/$target-$(date -u '+%Y%m%dT%H%M%SZ')"
            mkdir -p "$attic"
            printf '%s\n' "$pkg_dirs" | while IFS= read -r d; do
                [ -n "$d" ] || continue
                mv "$d" "$attic/$(printf '%s' "${d#$VP_DIR/packages/}" | tr / _)" 2>/dev/null || true
            done
            echo "  Previous units moved to $attic"
        fi

        cd "$VP_DIR"
        local os_target=$(echo "$target" | cut -d- -f2)
        local cpu_target=$(echo "$target" | cut -d- -f1)
        make packages PP="$compiler" OS_TARGET="$os_target" CPU_TARGET="$cpu_target" OPT="-n @$cfg" 2>&1 | grep -E "^\[|Compiled package|Fatal|Error" || true
        cd "$LAZARUS_DIR"

        # Re-measure rather than assume. Declaring "ready" over a set that is still broken
        # IS the original defect, so refuse loudly instead of handing a doomed unit set to
        # a 40-minute IDE build that dies on its first unit and blames the source.
        pkg_dirs=$(find "$VP_DIR/packages" -type d -name "$target" -path "*/units/*" 2>/dev/null)
        pkg_count=$(printf '%s' "$pkg_dirs" | grep -c . || true)
        if [ "$pkg_count" -lt 10 ]; then
            echo "ERROR: only $pkg_count VibePascal package unit set(s) for $target after a rebuild."
            echo "       Previous units are in $VP_DIR/.stale-units if this needs unpicking."
            exit 1
        fi
        if [ -x "$loadcheck" ] && [ -z "${VP_SKIP_LOADCHECK:-}" ]; then
            echo "Re-verifying the rebuilt $target unit set..."
            mkdir -p "$lc_scratch"
            local lc_rc2=0
            TMPDIR="$lc_scratch" "$loadcheck" "$target" "$compiler" "$VP_DIR" > "$lc_out" 2>&1 || lc_rc2=$?
            cat "$lc_out"
            # Same three-way split as the first call site, same discriminator -- see the
            # long comment there. This site is the easier one to get wrong: it runs AFTER a
            # rebuild, where a kill is likelier (the box has just done real work) and where
            # the number is read by someone already half-convinced the tree is broken.
            local lc_aborted2=0
            grep -q '^ABORTED ' "$lc_out" 2>/dev/null && lc_aborted2=1
            if [ "$lc_rc2" = 1 ] || [ "$lc_aborted2" = 1 ]; then
                local lc_bad2 lc_total2 lc_ok2 lc_prob2 lc_unknown2 lc_real2=0 lc_mode2 p2
                lc_bad2=$(grep -E '^[A-Z][A-Z0-9-]* ' "$lc_out" 2>/dev/null | grep -c -v '^SKIPPED ' || true)
                lc_total2=$(sed -n 's/.*: \([0-9]*\)\/\([0-9]*\) packages load clean.*/\2/p' "$lc_out" | tail -1)
                [ -n "$lc_total2" ] || lc_total2=0
                lc_ok2=$(sed -n 's/.*: \([0-9]*\)\/\([0-9]*\) packages load clean.*/\1/p' "$lc_out" | tail -1)
                [ -n "$lc_ok2" ] || lc_ok2=0
                lc_prob2=$(sed -n 's/.*packages load clean, \([0-9]*\) problem(s).*/\1/p' "$lc_out" | tail -1)
                [ -n "$lc_prob2" ] || lc_prob2=-1
                lc_unknown2=0
                [ "$lc_prob2" -gt "$lc_bad2" ] && lc_unknown2=$((lc_prob2 - lc_bad2))
                # Same extractor, same heredoc-not-a-pipe rule as the first call site --
                # see the comment there. THIS SITE CARRIED THE IDENTICAL DEFECT and it is
                # the easier one to miss, because it only runs after VP_FORCE_STALE_REBUILD
                # or a rebuild, where the count feeds "STILL does not load after a rebuild".
                while read -r lc_mode2 p2; do
                    [ -n "$p2" ] || continue
                    # ABORTED names the TARGET, not a package -- see the first call site.
                    [ "$lc_mode2" = ABORTED ] && continue
                    vp_loadcheck_known_benign "$target" "$lc_mode2" "$p2" || lc_real2=$((lc_real2 + 1))
                done <<EOF
$(sed -n 's/^\([A-Z][A-Z0-9-]*\) \([^ :]*\).*/\1 \2/p' "$lc_out" | grep -v '^SKIPPED ')
EOF
                if [ "$lc_prob2" -lt 0 ]; then
                    verdict="loadcheck UNUSABLE after rebuild (no summary line)"
                    echo "WARNING: the re-verify exited 1 with no summary line; its own problem"
                    echo "         count cannot be read. $target is UNVERIFIED; continuing."
                elif [ "$lc_unknown2" -gt 0 ]; then
                    echo "ERROR: the $target re-verify reported $lc_prob2 problem(s) but only"
                    echo "       $lc_bad2 are in a shape this gate can classify. Refusing to"
                    echo "       continue on $lc_unknown2 unread problem(s). Log: $lc_out"
                    exit 1
                elif [ "$lc_aborted2" = 1 ]; then
                    if [ "$lc_real2" -gt 0 ]; then
                        echo "ERROR: the $target re-verify was KILLED mid-sweep and had already"
                        echo "       named $lc_real2 failing package(s) before it died. The rebuild"
                        echo "       did NOT fix them and the rest were never judged. Refusing to"
                        echo "       continue. Log: $lc_out"
                        echo "       Previous units are in $VP_DIR/.stale-units if this needs unpicking."
                        exit 1
                    fi
                    verdict="loadcheck INTERRUPTED after rebuild (rc=$lc_rc2, $lc_ok2/$lc_total2 judged)"
                    echo "WARNING: the $target re-verify was killed before it finished (rc=$lc_rc2)."
                    echo "         $lc_ok2 of $lc_total2 judged, none failing, rest unmeasured -- so the"
                    echo "         rebuild is NOT confirmed. UNVERIFIED; continuing."
                elif [ "$lc_total2" -gt 0 ] && [ "$lc_bad2" -ge "$lc_total2" ]; then
                    verdict="loadcheck UNUSABLE on this host ($lc_bad2/$lc_total2 failed)"
                    echo "WARNING: every $target package failed after the rebuild -- harness/toolchain,"
                    echo "         not the unit set. Continuing UNVERIFIED."
                elif [ "$lc_real2" -gt 0 ]; then
                    echo "ERROR: the $target VibePascal package unit set STILL does not load after a"
                    echo "       rebuild ($lc_real2 of $lc_total2). Refusing to continue."
                    echo "       Previous units are in $VP_DIR/.stale-units if this needs unpicking."
                    exit 1
                elif [ "$lc_bad2" -gt 0 ]; then
                    verdict="loadcheck PASS after rebuild ($lc_bad2 known-benign)"
                else
                    # Same reason as the first call site: rc=1 with nothing named is not a
                    # pass. This site is the easier one to miss and the worse one to get
                    # wrong -- its number is read by someone already half-convinced the
                    # tree is broken.
                    verdict="loadcheck UNUSABLE after rebuild (rc=1, no problem package named)"
                    echo "WARNING: the $target re-verify exited 1 but named no problem package"
                    echo "         this gate could read. UNVERIFIED; continuing."
                fi
            elif [ "$lc_rc2" != 0 ]; then
                echo "WARNING: could not re-verify $target after the rebuild (rc=$lc_rc2); continuing UNVERIFIED."
                verdict="loadcheck UNAVAILABLE (rc=$lc_rc2)"
            else
                verdict="loadcheck PASS after rebuild"
            fi
        else
            verdict="rebuilt, UNVERIFIED"
        fi
        # A rebuild legitimately yields FEWER package dirs than the previous set: on
        # 2026-09-10 the x86_64-darwin rebuild returned 103 of 118, and the 15 that
        # dropped out are not Lazarus IDE dependencies -- the IDE build ran straight past
        # them. A shrinking count is not an error; only the <10 floor is.
    fi
    echo "VibePascal packages ready for $target ($pkg_count packages, $verdict)"
}

build_lazbuild() {
    local target=$1
    local cfg=$2
    local compiler=$(get_compiler_for_target "$target")

    echo "=== Building lazbuild for $target ==="
    local os_target=$(echo "$target" | cut -d- -f2)
    local cpu_target=$(echo "$target" | cut -d- -f1)

    # Was `| grep -E "Linking|lines compiled|Fatal|Error"` with pipefail off,
    # which returned grep's status: a make that failed while printing "Error"
    # matched, and the step reported SUCCESS.
    run_build_step "lazbuild-$target" "Linking|lines compiled|Fatal|Error" -- \
        make -C "$LAZARUS_DIR" lazbuild \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        OPT="-n @$cfg"
}

build_darwin_ide() {
    local target=$1
    local cfg=$2
    # What the WRAPPER execs, not what get_compiler_for_target names -- see
    # resolve_exec_compiler. This changes the exec TARGET, never the wrapper's own
    # path, so lazbuild still sees the same --compiler string and no package is
    # rebuilt for it (Bruno, 2026-09-11, who also established the roll rebuilds
    # everything unconditionally anyway: the wrapper is regenerated with cat > on
    # every roll and the stored state carries a fixed Date, so a Date mismatch
    # already forces the rebuild this was once costed against).
    local compiler
    compiler=$(resolve_exec_compiler "$(get_compiler_for_target "$target")")
    local cpu_target=$(echo "$target" | cut -d- -f1)
    # NOT /tmp: on this builder /tmp is a 2G tmpfs shared by ~30 agents and has
    # been observed at 97% full and cleared under running builds. A cross-target
    # --build-ide whose PrimaryConfigPath vanishes mid-run can complete without
    # linking an IDE at all. Keep both under a real filesystem.
    local build_state="$BUILD_STATE_DIR"
    mkdir -p "$build_state"
    local wrapper="$build_state/ppc${cpu_target}-darwin-wrapper"
    local pcp="$build_state/lazbuild-pcp-${target}"

    echo "=== Building Darwin IDE for $target ==="

    # Wrapper must always include the cross-compile cfg, including for lazbuild's
    # detection calls (-iWTOTP, -va compilertest.pas). Without the cfg, the
    # compiler has no unit search paths and lazbuild reports "system.ppu not found".
    # An older variant of this wrapper bypassed the cfg for -i*/-va; that worked
    # only as long as lazbuild's fpcdefines.xml cache covered the wrapper path.
    cat > "$wrapper" << EOF
#!/bin/bash
exec "$compiler" -n @"$cfg" "\$@"
EOF
    chmod +x "$wrapper"

    # Per-build isolated PrimaryConfigPath: customdrawn becomes the only entry in
    # staticpackages.inc, no cross-target leak between IDE builds. Pre-clearing
    # staticpackages.inc keeps the user-install list deterministic across runs.
    rm -rf "$pcp"
    mkdir -p "$pcp"
    # A previous roll's staged IDE binary must not be able to reach packaging if
    # THIS build fails. require_fresh_artifact would catch it on mtime; not leaving
    # it lying there at all is one fewer way to publish the wrong binary.
    rm -f "$(get_darwin_ide_binary "$target")"

    # Build IDE with customdrawn LCL controls installed by default (GOD mp3l6s84:
    # "I want to have customdrawn LCL controls as a default fucking package").
    # --add-package registers + links customdrawn; --build-ide (NOT --build-ide-minimal)
    # is required because TBuildIDE.Minimal skips LoadAutoInstallPackages.
    # `--build-ide 2>&1 | tail -40` kept only the last 40 lines -- all of them
    # routine unit compiles -- so a run that produced no "Linking" line and no
    # IDE binary was indistinguishable from a good one. Keep the whole log.
    run_build_step "darwin-ide-$target" "Linking|lines compiled|Fatal|Error|Fatal:" -- \
        "$LAZARUS_DIR/lazbuild" --pcp="$pcp" --lazarusdir="$LAZARUS_DIR" --compiler="$wrapper" \
        --cpu="$cpu_target" --os=darwin --ws=cocoa \
        --add-package "$LAZARUS_DIR/components/customdrawn/customdrawn.lpk" \
        --build-ide

    # Exit status alone is not evidence -- assert the artifact, at the step that
    # produces it rather than three functions downstream.
    #
    # The absent "Linking" line that prompted this check was a LOGGING artifact,
    # not a build failure (Bruno, 2026-09-10, full-log re-run): the IDE link
    # happens ~400 lines before lazbuild's last output, so `| tail -40` never
    # showed it. The build was fine; the PICKUP PATH was wrong. Both are fixed.
    local built_ide="$pcp/bin/${target}/lazarus"
    if ! require_fresh_artifact "$built_ide" "Darwin IDE binary for $target"; then
        echo "       lazbuild --build-ide reported success but produced no fresh IDE binary."
        return 1
    fi

    # Lift it out of the pcp BEFORE the teardown at the end of this function
    # removes it. -p so the staged copy keeps the link mtime and the downstream
    # freshness asserts still measure when the IDE was LINKED, not when it was
    # copied -- a copy-time mtime would pass require_fresh_artifact by construction
    # and quietly turn it back into a presence check.
    local staged_ide
    staged_ide=$(get_darwin_ide_binary "$target")
    mkdir -p "$(dirname "$staged_ide")"
    rm -f "$staged_ide"
    if ! cp -p "$built_ide" "$staged_ide"; then
        echo "ERROR: could not stage the $target IDE binary out of the build pcp." >&2
        return 1
    fi

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
    # MATCH ON THE WRAPPER'S BASENAME, NOT ITS ABSOLUTE PATH, AND FIND THE FILES
    # WITH find(1) RATHER THAN grep -r. Measured 2026-09-11 against the SHIPPED
    # x86_64-darwin asset of release 372618806: this loop processed ZERO files and
    # 36 of its 244 .compiled members went out carrying
    # `Value="../../../../../.cache/lazarus-build/ppcx86_64-darwin-wrapper" Date="..."`
    # plus an un-stripped `-Tdarwin` in Params -- i.e. BOTH Melissa C326 finding 3
    # and Melissa C18 finding 2, live in a published release. The cause, and then
    # why discovery moved from grep -r to find(1), which is NOT a second cause:
    #   1. THE CAUSE, sufficient on its own. lazbuild stores the compiler path
    #      RELATIVE to the .compiled file, so an absolute "$wrapper" pattern can
    #      never match. Zero files in the tree carry the absolute form; all 36 carry
    #      a ../../../.. form, and the number of .. segments varies with the file's
    #      depth, so no single literal ever could. files-processed 0 -> 36 is the
    #      proof, and it is the only thing the fix rests on.
    #   2. WHY find(1). It has NO ignore semantics under ANY grep, so this loop is
    #      immune to whichever grep a caller's environment supplies. That is worth
    #      buying because the environment really does vary here: an INTERACTIVE
    #      AGENT SHELL on lazdev has `grep` as a bash function dispatching to ugrep
    #      7.8.4, which does skip gitignored paths (`grep -rl --include='*.compiled'
    #      CONFIG .` -> 85 of 206). THAT IS A PROPERTY OF THAT SHELL, NOT OF THIS
    #      BOX. The function is not exported, so a plain .sh like this one gets
    #      /usr/bin/grep (GNU grep 3.11) and sees all 206. grep -r in a build script
    #      here is NOT blind, and grep -r call sites elsewhere do NOT need rewriting.
    # -print0 is portable and the per-file grep -q is a plain non-recursive match,
    # identical under GNU grep and ugrep. The basename is [A-Za-z0-9_-] only, so it
    # needs no regex quoting.
    local wrapper_base
    wrapper_base=$(basename "$wrapper")
    while IFS= read -r -d '' compiled_file; do
        grep -q "$wrapper_base" "$compiled_file" 2>/dev/null || continue
        mtime_ref=$(mktemp)
        touch -r "$compiled_file" "$mtime_ref"
        if sed -i \
            -e "s|Value=\"[^\"]*${wrapper_base}\"\( Date=\"[0-9]*\"\)\{0,1\}|Value=\"\$(LazarusDir)compiler/${user_compiler_name}\"|g" \
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
    done < <(find "$LAZARUS_DIR" -name '*.compiled' -type f -print0 2>/dev/null)

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
    # Same defect and same fix as build_darwin_ide -- see the long comment there.
    # This site had the extra no-Date arm already, which is why it looked correct;
    # it was not, because BOTH arms anchored on the absolute "$wrapper".
    local wrapper_base
    wrapper_base=$(basename "$wrapper")
    while IFS= read -r -d '' compiled_file; do
        grep -q "$wrapper_base" "$compiled_file" 2>/dev/null || continue
        mtime_ref=$(mktemp)
        touch -r "$compiled_file" "$mtime_ref"
        if sed -i \
            -e "s|Value=\"[^\"]*${wrapper_base}\"\( Date=\"[0-9]*\"\)\{0,1\}|Value=\"${replacement}\"|g" \
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
    # subdir-scoped scan missed them. Widening to $LAZARUS_DIR is a no-op for
    # already-clean state files because the per-file grep -q above skips any file
    # that does not contain the wrapper basename. Mirrors build_darwin_ide's scope.
    done < <(find "$LAZARUS_DIR" -name '*.compiled' -type f -print0 2>/dev/null)
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

    # -weak_framework UserNotifications: startlazarus links the cocoa widgetset,
    # and cocoawsextctrls references five UserNotifications.framework ObjC classes
    # (UNUserNotificationCenter, UNMutableNotificationContent, UNNotificationRequest,
    # UNNotificationSound, UNTimeIntervalNotificationTrigger) from
    # TCocoaWSCustomTrayIcon.newUserNotify. That framework is declared ONLY as
    # UsageLinkerOptions in lcl/interfaces/lcl.lpk, which the package system
    # applies -- so lazbuild-built targets link and make-built ones do not. This
    # is why startlazarus has been absent from every darwin .app we have shipped.
    # WEAK, matching the .lpk: the call site has no runtime availability guard,
    # so hard-linking would break app LOAD on macOS older than 10.14.
    # Non-fatal on purpose: a missing startlazarus degrades the bundle, whereas
    # aborting the roll ships nothing at all. The copy sites assert freshness, so
    # a failure here can no longer produce a symlink to a file we never bundled.
    if ! run_build_step "darwin-starter-$target" "Linking|lines compiled|Fatal|Error|Undefined symbols|symbol\(s\) not found" -- \
        make -C "$LAZARUS_DIR" starter \
        PP="$compiler" \
        FPCDIR="$VP_DIR" \
        OS_TARGET="$os_target" \
        CPU_TARGET="$cpu_target" \
        OPT="-n @$cfg -k-weak_framework -kUserNotifications" LCL_PLATFORM=cocoa; then
        echo "WARNING: startlazarus did not build for $target; the .app will ship without it."
    fi
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

stamp_shipped_compiler_hashes() {
    # COMPILER_NOTES.txt is written when the compiler is COPIED into staging, but darwin
    # packaging then ad-hoc signs every bundled Mach-O (sign_darwin_app_machos), and the
    # bundled compiler is hard-linked into the .app by `cp -al`, so that signature rewrites
    # the top-level compiler/ppc* too. The md5 the notes declare -- taken from the UNSIGNED
    # staging binary and quoted as "matches VERSION.txt" -- therefore never matches the file
    # that ships: the 2026-09-10 x86_64 tarball documents 29f2a740e3e79c1dd168843d0ad0f7e8
    # while compiler/ppcx64 inside the archive is 3f10e570fcad85205276ce7fd3ce52c5 (both
    # measured; running `rcodesign sign` on the staged copy reproduces the shipped hash and
    # size exactly). A user who verifies the documented hash concludes the download is
    # corrupt. Stamp the AS-SHIPPED digests last, after every mutation, so the notes
    # describe the artifact instead of an intermediate.
    local staging=$1
    local notes="$staging/COMPILER_NOTES.txt"
    local header_written=0
    local compiler_bin=""

    [ -f "$notes" ] || return 0
    for compiler_bin in "$staging"/compiler/ppc*; do
        [ -f "$compiler_bin" ] || continue
        if [ "$header_written" -eq 0 ]; then
            {
                echo ""
                echo "AS SHIPPED IN THIS TARBALL"
                echo "--------------------------"
                echo "Digests of the bundled compiler(s) as they exist in this archive, computed"
                echo "after packaging finished. Darwin packaging ad-hoc signs every bundled Mach-O"
                echo "with rcodesign, which appends a code signature and CHANGES the file's hash,"
                echo "so any md5/sha256 quoted above (those describe the unsigned staging binary,"
                echo "or VibePascal's own VERSION.txt) will NOT match what you received. These do:"
            } >> "$notes"
            header_written=1
        fi
        {
            echo "  compiler/$(basename "$compiler_bin")"
            echo "    size   $(stat -c%s "$compiler_bin") bytes"
            echo "    md5    $(md5sum "$compiler_bin" | cut -d' ' -f1)"
            echo "    sha256 $(sha256sum "$compiler_bin" | cut -d' ' -f1)"
        } >> "$notes"
    done
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
    #   * Makefile / Makefile.fpc newer than sibling .compiled. TLazPackageGraph
    #     treats these as package source files too, so an unrestored mtime forces
    #     a wasted LazUtils-cascade rebuild on the user's first lazbuild
    #     (Melissa F8, r20 aarch64-darwin smoke).
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
        -name '*.lfm' -o \
        -name 'Makefile' -o \
        -name 'Makefile.fpc' \
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

    # General cross-arch build-state strip (Melissa r20 aarch64-darwin smoke,
    # 2026-05-29: ~60 orphan x86_64-darwin .compiled leaked into the aarch64-darwin
    # tarball). package_release cp -r's lcl/, components/, ide/, packager/, ...
    # which each carry units/<arch>/ + lib/<arch>/ build outputs for EVERY arch
    # built in the shared workdir. The targeted strips above only cover the
    # test/BGRA/mouse/lhelp leaks; this catch-all removes any NON-target arch's
    # units|lib state tree so the tarball ships only its own arch's .compiled/
    # .ppu/.o. -prune stops find descending into a dir we then rm.
    #
    # The optional (-[^/]*)? suffix is REQUIRED, not cosmetic. This regex was
    # originally anchored at the bare arch token on the theory that a widget
    # suffix meant "BGRA dir, already handled above". That was wrong, and it
    # shipped: r25's aarch64-darwin tarball still carried 202 x86_64-darwin files
    # (incl. 4 orphan .compiled) from components/virtualtreeview/lib/ and
    # components/lclextensions/lib/, whose dirs are named <arch>-<widget>
    # (x86_64-darwin-cocoa) and are covered by NO targeted strip above. Verified
    # 2026-09-10 by listing the shipped r25 tarball. A widget suffix says nothing
    # about which ARCH the dir belongs to -- so match the suffix and decide on the
    # arch token instead.
    #
    # Hence the keep-guard is PREFIX-aware ($target or $target-$widget*), not
    # equality: aarch64-darwin-cocoa must survive an aarch64-darwin build. The
    # suffix is pinned to THIS target's widget rather than left open as $target-*,
    # so a right-arch/WRONG-widget dir (aarch64-darwin-gtk2 in an aarch64-darwin
    # build) is stripped as well. Outside the two BGRA libroots that shape is
    # covered by no targeted strip above: components/virtualtreeview/lib and
    # components/lclextensions/lib name their dirs <arch>-<widget>, so a
    # $target-* guard would ship a wrong-widget lib dir -- the same stale-unit
    # class this whole function exists to keep off the search path.
    # Measured 2026-09-10 over BOTH the real shipped r25 tarball landscape and
    # the live workdir landscape, all 6 targets: pinning the widget changes
    # NOTHING that exists today (survivor sets byte-identical to the $target-*
    # form in all 12 runs). With a wrong-widget dir planted in those two libroots
    # the $target-* form keeps it while this form removes it and leaves every
    # right-widget dir intact.
    local cross_arch_dir=""
    local cross_arch_base=""
    while IFS= read -r -d '' cross_arch_dir; do
        cross_arch_base=$(basename "$cross_arch_dir")
        case "$cross_arch_base" in
            "$target"|"$target"-"$widget"*) continue ;;
        esac
        rm -rf "$cross_arch_dir"
    done < <(find "$staging" -type d -regextype posix-extended \
        -regex '.*/(units|lib)/(x86_64|aarch64|arm|i386)-(linux|darwin|win64|win32)(-[^/]*)?' \
        -prune -print0 2>/dev/null)
}

create_darwin_app_bundle() {
    local target=$1
    local cpu_target=$(echo "$target" | cut -d- -f1)

    echo "=== Creating Lazarus.app for $target ==="
    local app_name="lazarus-${cpu_target}-darwin.app"
    local pcp_bin="$(get_darwin_ide_binary "$target")"

    rm -rf "$LAZARUS_DIR/$app_name"
    cp -r "$LAZARUS_DIR/lazarus.app" "$LAZARUS_DIR/$app_name"
    mkdir -p "$LAZARUS_DIR/$app_name/Contents/MacOS"
    rm -f "$LAZARUS_DIR/$app_name/Contents/MacOS/lazarus"

    # Copy IDE binary. FATAL if it is not fresh: this guard used to be a bare
    # `[ -f "$pcp_bin" ]`, and a roll was caught about to package an IDE binary
    # four months old because the file merely existed. Shipping nothing beats
    # shipping a stale IDE under a new version number.
    if ! require_fresh_artifact "$pcp_bin" "IDE binary for $target"; then
        return 1
    fi
    cp "$pcp_bin" "$LAZARUS_DIR/$app_name/Contents/MacOS/lazarus"

    # Copy startlazarus. Non-fatal, but freshness still required: the tree root
    # holds ONE startlazarus for all targets, so a failed link here after a
    # successful one for the other target would otherwise copy the WRONG
    # ARCHITECTURE's binary into this bundle.
    if require_fresh_artifact "$LAZARUS_DIR/startlazarus" "startlazarus for $target"; then
        cp "$LAZARUS_DIR/startlazarus" "$LAZARUS_DIR/$app_name/Contents/MacOS/startlazarus"
    else
        echo "WARNING: bundling $app_name WITHOUT startlazarus."
    fi

    file "$LAZARUS_DIR/$app_name/Contents/MacOS/lazarus" 2>/dev/null || true
}

get_latest_darwin_native_dir() {
    # Pick the newest macOS-hosted VibePascal compiler staging dir for $1 (a darwin target).
    # Prints the path. rc: 0 = found, 1 = none staged, 2 = AMBIGUOUS (two tie for newest).
    #
    # WHY THIS IS NOT `sort | tail -1`, which is what it replaces: the names are
    # vibepascal-native-<target>-<YYYYMMDD>[-v<N>]-<git-sha>, and a git sha carries NO
    # ordering. A lexicographic sort therefore ranks two same-day builds by the hex of
    # their commit -- a coin flip, and it looks completely healthy whichever way it lands.
    # On 2026-09-10 it came up heads only because Otto tagged the newer directory: v56 is
    # sha a187bbac34, v55 is eae5d3e919, same date, and 'a' sorts before 'e'. Untagged,
    # `tail -1` would have bundled the OLDER compiler into both Mac tarballs and nothing
    # anywhere would have said so. That is D003 exactly -- r16 shipped a v39 compiler
    # announced as v42, because packaging checked shape and never content.
    #
    # The linux half of this script has never had the hole: get_latest_vp_bin_tarball
    # parses v<N> and sorts NUMERICALLY. Two halves of one script disagreeing about what
    # "latest" means is the same drift that produced the darwin IDE pickup bug, so this is
    # deliberately written in that function's shape rather than a cleverer one.
    #
    # Key is (date, version), both numeric, version 0 when the name carries no -v<N>-.
    # If the top two candidates TIE on that key, the names genuinely do not say which is
    # newer, so this REFUSES instead of guessing: the caller then ships a tarball with no
    # compiler and a note saying why -- loud and recoverable -- instead of a 50/50 pick
    # that ships silently. The fix for a tie is one rename by whoever staged the build.
    local target=$1 ranked top second top_path second_path
    ranked=$(find "$VP_DIR/dist/darwin-native" -maxdepth 1 -type d \
                  -name "vibepascal-native-${target}-*" 2>/dev/null |
        while IFS= read -r dir; do
            local base rest date_part version
            base=$(basename "$dir")
            rest=${base#vibepascal-native-${target}-}
            date_part=${rest%%-*}
            case "$date_part" in
                ''|*[!0-9]*) continue ;;
            esac
            version=0
            case "$rest" in
                *-v[0-9]*)
                    version=${rest#*-v}
                    version=${version%%-*}
                    case "$version" in
                        ''|*[!0-9]*) version=0 ;;
                    esac
                    ;;
            esac
            printf '%s %08d %s\n' "$date_part" "$version" "$dir"
        done |
        sort -k1,1n -k2,2n)

    [ -z "$ranked" ] && return 1

    top=$(printf '%s\n' "$ranked" | tail -1)
    second=$(printf '%s\n' "$ranked" | tail -2 | head -1)
    top_path=$(printf '%s\n' "$top" | cut -d' ' -f3-)
    second_path=$(printf '%s\n' "$second" | cut -d' ' -f3-)
    if [ "$top" != "$second" ] && \
       [ "$(printf '%s\n' "$top" | cut -d' ' -f1,2)" = "$(printf '%s\n' "$second" | cut -d' ' -f1,2)" ]; then
        echo "ERROR: cannot tell which $target compiler is newest -- these tie on date+version:" >&2
        echo "         $(basename "$top_path")" >&2
        echo "         $(basename "$second_path")" >&2
        echo "       A git sha does not sort. Rename one to carry its version segment" >&2
        echo "       (vibepascal-native-${target}-<date>-v<N>-<sha>) and re-run." >&2
        return 2
    fi
    printf '%s\n' "$top_path"
}

copy_native_darwin_compiler_to_staging() {
    # Bundle the NATIVE macOS-hosted VibePascal compiler for a darwin target.
    # $1 staging  $2 target  $3 native exename  $4 expected `file` arch substring
    #
    # This is the darwin twin of copy_native_linux_compiler_to_staging, and it exists
    # because the two darwin arms it replaces had NEITHER of that function's guards:
    # they tested -x and copied. Otto flagged the asymmetry; the call was mine.
    # Deciding it needed the numbers from a real roll, and the 2026-09-10 re-roll
    # supplied them.
    #
    # THE GUARD MUST RUN HERE, AT COPY TIME, AND NOWHERE LATER. sign_darwin_app_binaries
    # rewrites this file in place with `rcodesign sign` further down the roll, so after
    # that point the shipped bytes CANNOT equal the md5 VERSION.txt declares -- the
    # signature is real content, ~900KB of it on the IDE binary. A check placed after
    # signing fails on a perfectly good compiler, and the obvious "fix" is to delete the
    # check. Measured on the 2026-09-10 roll: staged ppcx64 29f2a740e3e79c1dd168843d0ad0f7e8
    # ships as 3f10e570fcad85205276ce7fd3ce52c5, and signing a copy of the staged binary
    # reproduces the shipped bytes exactly. Anything auditing the PACKAGED tarball has to
    # reproduce the signature rather than compare against VERSION.txt.
    #
    # Same two failure modes as the linux side, and both are silent without the guards:
    #   D003: a stale or swapped member ships unnoticed -- r16 shipped a v39 compiler
    #         announced as v42 because packaging checked shape and never content.
    #   arch: exename is not evidence of architecture. compiler/ppcarm was an x86_64 ELF
    #         in the shared tree for exactly this reason.
    # Either guard failing REMOVES the compiler and says so in COMPILER_NOTES.txt. A
    # tarball with no compiler and a note explaining why beats one carrying a compiler
    # that cannot run -- r25's darwin pair shipped the note without the explanation and
    # the guessed cause was read downstream as current fact for months.
    local staging=$1 target=$2 exename=$3 arch_pattern=$4
    local notes="$staging/COMPILER_NOTES.txt"
    local native_dir declared actual out="$staging/compiler/$exename"
    local sel_rc=0

    # `|| sel_rc=$?` is load-bearing, not defensive noise. A bare
    #     native_dir=$(get_latest_darwin_native_dir "$target")
    # is a SIMPLE COMMAND under this script's `set -e`, so on the rc=2 (ambiguous)
    # return the shell exits AT THE ASSIGNMENT and the branch below never runs. Today
    # that is masked because both call sites in package_release wrap this function in
    # `|| true`, which suspends errexit for the call's whole dynamic extent -- so the
    # degraded path works by accident of the CALLER rather than by anything here.
    # Driven both ways against a genuine tie fixture:
    #   with the caller's `|| true`: rc=2 branch runs, COMPILER_NOTES.txt written, warnings print
    #   without it (bare call):      script DIES here, rc=2, NO note, NO warning -- a silent
    #                                exit 2 with no diagnosis, the exact opposite of the point
    # Capturing the status makes the diagnosis independent of how we are called.
    # (The linux twin needs no such fix: get_latest_vp_bin_tarball ends in a `cut`
    # pipeline, always rc=0, and its caller guards on emptiness rather than on `$?`.)
    native_dir=$(get_latest_darwin_native_dir "$target") || sel_rc=$?
    if [ "$sel_rc" -eq 2 ]; then
        # Ambiguous, not missing. The shipped note must say which one it is: r25's darwin
        # pair shipped a note that guessed a cause, and the guess was read downstream as a
        # current fact for months.
        echo "WARNING: $target roll is DEGRADED -- the newest native compiler is not decidable" >&2
        echo "         from the staging directory names (see the tie reported above)." >&2
        echo "         The tarball will ship WITHOUT compiler/$exename." >&2
        {
            echo "NOTE: this build does not bundle a native $target compiler. Two staged builds on"
            echo "the build host tie on date and version, so which is newer is not decidable from"
            echo "their names, and this script will not guess. Nothing is wrong with this download."
            echo "Cross-compilation from Linux works. To compile on macOS, install FPC separately."
        } > "$notes"
        return 1
    fi

    if [ -z "$native_dir" ] || [ ! -x "$native_dir/bin/$exename" ]; then
        echo "WARNING: $target roll is DEGRADED -- no native compiler found under" >&2
        echo "         $VP_DIR/dist/darwin-native (wanted vibepascal-native-${target}-*/bin/$exename)." >&2
        echo "         The tarball will ship WITHOUT compiler/$exename." >&2
        echo "NOTE: this build does not bundle a native $target compiler." > "$notes"
        echo "Cross-compilation from Linux works. To compile on macOS, install FPC separately." >> "$notes"
        return 1
    fi

    cp "$native_dir/bin/$exename" "$out" || { rm -f "$out"; return 1; }

    # Only the "Binary: bin/<exename>  md5 <hash>" line. VERSION.txt also quotes the
    # PREVIOUS release's md5 in its section-triage prose, so a looser match returns two
    # hashes and the comparison fails against a two-word string no matter what shipped.
    declared=$(awk -v n="$exename" '$0 ~ "bin/" n "[[:space:]]" { for (i=1;i<=NF;i++) if ($i=="md5") { print $(i+1); exit } }' \
                   "$native_dir/VERSION.txt" 2>/dev/null)
    actual=$(md5sum "$out" | cut -d' ' -f1)
    if [ -n "$declared" ] && [ "$declared" != "$actual" ]; then
        echo "ERROR: $exename md5 $actual does not match $declared declared in $(basename "$native_dir")/VERSION.txt." >&2
        rm -f "$out"
        echo "NOTE: native $target compiler REJECTED (md5 mismatch vs its own VERSION.txt). Not bundled." > "$notes"
        return 1
    fi

    if ! file -b "$out" | grep -q "$arch_pattern"; then
        echo "ERROR: $exename is not a $target binary: $(file -b "$out")" >&2
        rm -f "$out"
        echo "NOTE: native $target compiler REJECTED (wrong architecture). Not bundled." > "$notes"
        return 1
    fi

    chmod +x "$out"
    {
        echo "Bundled native $target VibePascal compiler from $(basename "$native_dir")."
        echo "  md5:  $actual${declared:+ (matches VERSION.txt)}"
        echo "  arch: $(file -b "$out")"
        echo "  The md5 above is the UNSIGNED staging binary, which is what this guard checked."
        echo "  For the digests of the file actually in this tarball, read the AS-SHIPPED block"
        echo "  that stamp_shipped_compiler_hashes appends below."
    } > "$notes"
    [ -f "$native_dir/COMPILER_NOTES.txt" ] && cat "$native_dir/COMPILER_NOTES.txt" >> "$notes"
    echo "Bundled native $target compiler $exename from $(basename "$native_dir")."
    return 0
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
        copy_native_linux_compiler_to_staging "$staging" aarch64-linux ppca64 "ARM aarch64" || true
    elif [ "$target" = "arm-linux" ]; then
        cp "$compiler" "$staging/compiler/ppcrossarm"
        copy_native_linux_compiler_to_staging "$staging" arm-linux ppcarm "ARM, EABI5" || true
    elif [ "$target" = "x86_64-darwin" ]; then
        copy_native_darwin_compiler_to_staging "$staging" x86_64-darwin ppcx64 "Mach-O 64-bit x86_64" || true
    elif [ "$target" = "aarch64-darwin" ]; then
        copy_native_darwin_compiler_to_staging "$staging" aarch64-darwin ppca64 "Mach-O 64-bit arm64" || true
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
    #
    # Per-platform inclusion keeps each tarball self-sufficient without shipping
    # maintainer scripts that target a different OS or architecture:
    #   - Linux x86_64: auto-update.sh (Finn/BEHEMOTH smoke path)
    #   - Win64: auto-update.bat + auto-update.ps1 (ZENBOOK smoke path)
    #   - Darwin: none -- the .app bundle ships a pre-built IDE
    #   - ARM Linux: none -- auto-update.sh currently hard-codes the x86_64 path
    case "$target" in
        x86_64-linux)
            [ -f "$LAZARUS_DIR/auto-update.sh" ] && cp "$LAZARUS_DIR/auto-update.sh" "$staging/"
            ;;
        x86_64-win64)
            [ -f "$LAZARUS_DIR/auto-update.bat" ] && cp "$LAZARUS_DIR/auto-update.bat" "$staging/"
            [ -f "$LAZARUS_DIR/auto-update.ps1" ] && cp "$LAZARUS_DIR/auto-update.ps1" "$staging/"
            ;;
        *-darwin|aarch64-linux|arm-linux)
            # No updater scripts for these platforms.
            ;;
        *)
            # Unknown / future platform: default to no updater scripts.
            ;;
    esac

    strip_stale_host_arch_artifacts "$staging" "$target"

    restore_staged_mtimes "$staging"

    if [[ "$target" == *-darwin ]]; then
        materialize_darwin_lhelp_app "$staging/components/chmhelp/lhelp"
    fi

    # Darwin: include IDE binary, startlazarus, and .app bundle
    if [[ "$target" == *-darwin ]]; then
        local cpu_target=$(echo "$target" | cut -d- -f1)
        # Same presence-not-freshness guard as create_darwin_app_bundle had.
        # Both sites must assert, or the .app is fixed while the tarball's
        # bin/lazarus stays stale.
        local pcp_bin="$(get_darwin_ide_binary "$target")"
        if ! require_fresh_artifact "$pcp_bin" "staged IDE binary for $target"; then
            return 1
        fi
        cp "$pcp_bin" "$staging/bin/lazarus"
        if require_fresh_artifact "$LAZARUS_DIR/startlazarus" "staged startlazarus for $target"; then
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
            # Only if the target actually exists in this bundle. Every darwin
            # .app shipped so far carries a startlazarus.app pointing at a
            # Contents/MacOS/startlazarus that was never built, because the link
            # was written unconditionally while the build that produced it had
            # been failing silently.
            if [ -f "$app_macos/startlazarus" ]; then
                ln -sf ../../../../MacOS/startlazarus "$app_resources/startlazarus.app/Contents/MacOS/startlazarus"
            else
                echo "WARNING: no startlazarus in $app_name; removing the inner startlazarus.app rather than shipping a dangling symlink."
                rm -rf "$app_resources/startlazarus.app"
            fi

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

    # Last mutation before the archive is sealed: make COMPILER_NOTES.txt describe the
    # files that actually ship (ad-hoc signatures included), not the staging intermediates.
    stamp_shipped_compiler_hashes "$staging"

    cd "$RELEASE_DIR"
    tar czf "${release_name}.tar.gz" "$release_name"
    echo "Release: $RELEASE_DIR/${release_name}.tar.gz"
    local size=$(du -sh "${release_name}.tar.gz" | cut -f1)
    echo "Size: $size"

    rm -rf "$staging"
    cd "$LAZARUS_DIR"
}

restore_host_lazbuild() {
    # Put an x86_64-linux lazbuild back at the SHARED tree root after a cross roll.
    #
    # The branches in build_platform deliberately restore the TARGET lazbuild to
    # $LAZARUS_DIR/lazbuild before packaging, because package_release copies from exactly
    # that path into the tarball. Nothing then put the host one back, so a darwin,
    # aarch64-linux or arm-linux build ENDED with a binary at the tree root that cannot
    # execute on this box. That root is shared with ~30 other agents who run ./lazbuild;
    # after an arm-linux roll on 2026-09-10 every one of them got
    #   arm-binfmt-P: Could not open '/lib/ld-linux-armhf.so.3'
    # until Lars rebuilt it by hand -- and the next roll clobbered it again 12 minutes later.
    #
    # HABITS has carried "after an osxarm build, rebuild the host lazbuild" as a MANUAL step
    # for months. A manual step that four of six targets need is a missing script step, and it
    # only ever named osxarm because nobody noticed aarch64-linux doing the same thing.
    # x86_64-win64 is exempt for a real reason, not by omission: its lazbuild is lazbuild.exe,
    # a different filename, so it never occupies the host path.
    local target=$1
    [ "$target" = "x86_64-linux" ] && return 0
    [ "$(get_lazbuild_path_for_target "$target")" != "$LAZARUS_DIR/lazbuild" ] && return 0

    echo "=== Restoring host x86_64-linux lazbuild at tree root (last target: $target) ==="
    make -C "$LAZARUS_DIR" lazbuild \
        PP="$VP_DIR/compiler/ppcx64" \
        FPCDIR="$VP_DIR" \
        OS_TARGET=linux \
        CPU_TARGET=x86_64 \
        OPT="-n @$LINUX_CFG" 2>&1 | tail -3

    # Assert rather than assume -- a silent failure here is what makes the box unusable,
    # and the failure mode is invisible until another agent runs ./lazbuild.
    # ELF-qualified: a bare "x86-64" match also accepts a win64 PE, whose file(1)
    # line reads `PE32+ executable (console) x86-64`. Not reachable from here
    # (win64 is exempt above, its lazbuild is lazbuild.exe) but the loose form is
    # worth removing while the change is provably a no-op on everything present.
    if file -b "$LAZARUS_DIR/lazbuild" 2>/dev/null | grep -q "ELF 64-bit.*x86-64"; then
        echo "Host lazbuild restored at tree root: $(file -b "$LAZARUS_DIR/lazbuild" | cut -d, -f1-2)"
        return 0
    fi
    echo "ERROR: tree-root lazbuild is NOT x86-64 after restore -- the shared workdir is left broken." >&2
    echo "ERROR: file says: $(file -b "$LAZARUS_DIR/lazbuild" 2>/dev/null)" >&2
    return 1
}

build_platform() {
    local target=$1
    local cfg=$2

    ensure_vp_packages "$target" "$cfg"

    # A silently failing clean leaves stale objects on the search path, which is
    # the exact class that has twice produced a compiler crash in a shipped IDE.
    if ! run_build_step "clean-$target" "Fatal|Error" -- \
        make -C "$LAZARUS_DIR" clean; then
        echo "ERROR: 'make clean' failed for $target; refusing to build on a dirty tree." >&2
        return 1
    fi

    build_lazbuild "$target" "$cfg"

    # Darwin: build IDE and .app bundle
    if [[ "$target" == *-darwin ]]; then
        # Save darwin lazbuild and restore native lazbuild for IDE build
        local saved_lazbuild="$LAZARUS_DIR/lazbuild-${target}"
        cp "$LAZARUS_DIR/lazbuild" "$saved_lazbuild"
        # Swaps the tree-root lazbuild back to a NATIVE one so package builds can
        # actually execute it. Was `| tail -5` with pipefail off, so a failed
        # rebuild left the CROSS-TARGET binary in place and the next step invoked
        # a non-executable file. restore_host_lazbuild asserts this at the END of
        # the roll; assert it here too, where it can still be acted on.
        if ! run_build_step "native-lazbuild-restore-$target" "Linking|lines compiled|Fatal|Error" -- \
            make -C "$LAZARUS_DIR" lazbuild \
            PP="$VP_DIR/compiler/ppcx64" \
            FPCDIR="$VP_DIR" \
            OS_TARGET=linux \
            CPU_TARGET=x86_64 \
            OPT="-n @$LINUX_CFG"; then
            echo "ERROR: could not rebuild the native lazbuild for $target package builds." >&2
            return 1
        fi
        if ! file -b "$LAZARUS_DIR/lazbuild" 2>/dev/null | grep -q "ELF 64-bit.*x86-64"; then
            echo "ERROR: tree-root lazbuild is not x86-64 after the native rebuild for $target;" >&2
            echo "       package builds would invoke a cross-target binary." >&2
            return 1
        fi

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
        # Swaps the tree-root lazbuild back to a NATIVE one so package builds can
        # actually execute it. Was `| tail -5` with pipefail off, so a failed
        # rebuild left the CROSS-TARGET binary in place and the next step invoked
        # a non-executable file. restore_host_lazbuild asserts this at the END of
        # the roll; assert it here too, where it can still be acted on.
        if ! run_build_step "native-lazbuild-restore-$target" "Linking|lines compiled|Fatal|Error" -- \
            make -C "$LAZARUS_DIR" lazbuild \
            PP="$VP_DIR/compiler/ppcx64" \
            FPCDIR="$VP_DIR" \
            OS_TARGET=linux \
            CPU_TARGET=x86_64 \
            OPT="-n @$LINUX_CFG"; then
            echo "ERROR: could not rebuild the native lazbuild for $target package builds." >&2
            return 1
        fi
        if ! file -b "$LAZARUS_DIR/lazbuild" 2>/dev/null | grep -q "ELF 64-bit.*x86-64"; then
            echo "ERROR: tree-root lazbuild is not x86-64 after the native rebuild for $target;" >&2
            echo "       package builds would invoke a cross-target binary." >&2
            return 1
        fi

        if ! build_bgra_release_packages "$target" "$cfg"; then
            cp "$saved_lazbuild" "$target_lazbuild"
            rm -f "$saved_lazbuild"
            return 1
        fi

        cp "$saved_lazbuild" "$target_lazbuild"
        rm -f "$saved_lazbuild"
    fi

    package_release "$target"

    # Must come AFTER package_release: the tarball is cut from $LAZARUS_DIR/lazbuild, so the
    # target binary has to still be there when packaging runs. By the time package_release
    # returns, the tarball exists and the root is free to hold a host binary again.
    #
    # NON-FATAL BY DECISION, not by oversight (Lars measured the alternative and asked me to
    # choose). This script is `set -e` and the `all` path calls build_platform bare, so a bare
    # call here aborted the WHOLE roll: simulated on aarch64-linux, target 3 of 6, arm-linux
    # and both darwins never built and "Release builds complete" never printed. That is
    # strictly worse than continuing, because restore runs AFTER package_release -- this
    # target's tarball is already cut and safe -- so aborting throws away the remaining
    # targets AND still leaves the shared tree root broken, since nothing downstream repairs
    # it. Continuing costs nothing that was not already lost. The roll still fails loudly at
    # the end with a non-zero exit so a degraded roll cannot be mistaken for a clean one.
    restore_host_lazbuild "$target" || HOST_LAZBUILD_BROKEN=1
}

TARGET="${1:-all}"
mkdir -p "$RELEASE_DIR"

# Set by build_platform when restore_host_lazbuild fails. Checked once at the end.
HOST_LAZBUILD_BROKEN=0

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

# One last repair attempt, then fail the roll if the shared root is still not executable here.
# ~30 agents share this tree and run ./lazbuild; leaving a cross binary at the root breaks all
# of them, and the artifacts above are worthless to me if I cannot say the box is intact.
if [ "$HOST_LAZBUILD_BROKEN" = "1" ]; then
    echo ""
    echo "=== Host lazbuild restore FAILED earlier -- retrying once at end of roll ===" >&2
    # "aarch64-linux" here is not a target being restored FOR -- it is any value that clears
    # both of restore_host_lazbuild's early-return guards, so the rebuild actually runs.
    if restore_host_lazbuild "aarch64-linux"; then
        echo "Host lazbuild recovered on the end-of-roll retry. Artifacts above are complete." >&2
    else
        echo "" >&2
        echo "########################################################################" >&2
        echo "#                          RELEASE DEGRADED                            #" >&2
        echo "########################################################################" >&2
        echo "The tarballs listed above were built and are valid, but the tree root" >&2
        echo "lazbuild is NOT an x86_64-linux binary. Every agent sharing this tree" >&2
        echo "will fail on ./lazbuild until it is rebuilt. Do not announce a release" >&2
        echo "until this is fixed. Rebuild by hand with:" >&2
        echo "" >&2
        echo "  make -C $LAZARUS_DIR lazbuild PP=$VP_DIR/compiler/ppcx64 \\" >&2
        echo "    FPCDIR=$VP_DIR OS_TARGET=linux CPU_TARGET=x86_64 OPT=\"-n @$LINUX_CFG\"" >&2
        echo "" >&2
        exit 1
    fi
fi
