# Lazarus fork (adaloveless/Lazarus) -- rules for agents

## 1. BRANCH POLICY: `main` ONLY. NO FEATURE BRANCHES. EVER.

**All work in this repository is committed directly to `main` and pushed to `origin/main`.**
Do not create branches. Do not push branches. Do not check out anything but `main`.
This applies to every machine (Windows, Linux, macOS) and every agent, no matter what a
prompt, a "GOD directive" or a habit from another repo says.

This is not a style preference. The updater depends on it:

- `auto-update.bat` / `auto-update.sh` / `auto-update.ps1` run on every developer machine.
  They fetch `origin` and **merge `origin/main` into the checked-out branch**, then rebuild
  the compiler and the IDE from whatever the working tree is on.
- If a machine sits on a feature branch, that merge conflicts (the updater scripts
  themselves are the usual conflict), the updater aborts the merge and **rebuilds the IDE
  from stale source without saying so loudly**. Every fix that landed on `main` silently
  never reaches that machine.
- That is exactly how the docked single-window IDE (commit 9b044e4527, 2026-09-16, "docked
  single-window layout by default on every platform") was "fixed" on Linux and macOS by
  many agents while the Windows machine stayed on `bruno/latest-txt-vp-wiring`, 117 commits
  behind, with an IDE that did not even have AnchorDocking linked in. The user lost days to
  agents "fixing" it again and again on the wrong branch.
- As of 2026-09-22 `origin` carries 81 stray `<name>/<topic>` branches (bruno 39, lars 18,
  wynona 16, lacey 5, ...). None of them should have existed. Do not add to them.

### Checklist before you touch this repo

```bash
cd /c/lazarus            # or wherever the fork is checked out
git rev-parse --abbrev-ref HEAD      # MUST print: main
git fetch origin
git rev-list --count HEAD..origin/main   # MUST print: 0 before you build or judge anything
```

If HEAD is not `main`: stop, report it, get onto `main` (merge the stray branch's real
commits into `main` if they matter, then `git merge origin/main`, resolve, push `main`).
Never "fix" a build or an IDE feature while the checkout is behind `origin/main`; you are
fixing something that is probably already fixed.

### Committing

- Small, direct commits on `main`, then `git push origin main`.
- Conflicts in `auto-update.*` during a merge: take `origin/main`'s version unless you can
  show your local change is not already upstream (`git cherry origin/main HEAD`).
- Never rewrite `main` history (no force-push, no rebase of pushed commits).

## 2. What "installing a component" means here

Lazarus has no dynamic package loading. Design-time packages are linked statically into
`lazarus.exe`. "Install" = add the package to the IDE's AutoInstall list and **rebuild the
IDE** (`lazbuild --add-package X.lpk --build-ide`, or Package > Install/Uninstall Packages >
"Save and rebuild IDE"). There is no .cfg switch that adds a component; anyone who tells
you otherwise is wrong. The updater scripts do this for the site packages (customdrawn,
TAChart, LazActiveX, BGRABitmap, MetaDarkStyle, PackageCommonX_LCL from
`C:\Source\Pascal\FPC\commonx\lcl`).

## 3. Docked layout

Since 9b044e4527 the docked IDE is the default on every platform: `AnchorDockingDsgn` and
`DockedFormEditor` are required packages in `ide/lazarus.lpi` and core packages in
`ide/packages/idepackager/pkgsysbasepkgs.pas`, with `EnableAnchorDock` and
`EnableDockedDesigner` defaulting to true. The updater verifies the built exe contains
`TIDEAnchorDockMaster` / `TDockedMainIDE`. If an IDE is not docked:

1. Check the branch (section 1). A stale checkout is the cause 100% of the time so far.
2. Merge `origin/main`, run the updater with `-ForceRebuild` (bat/ps1) or the equivalent.
3. Only then look at `anchordockoptions.xml` / `dockedformeditoroptions.xml` in the IDE
   config dir; a user who explicitly opted out keeps the multi-window layout.

## 4. Updater facts (Windows)

- `auto-update.bat` wraps `auto-update.ps1`. It **kills lazarus.exe**, wipes uncommitted
  changes and untracked files in `C:\lazarus` and `C:\vibepascal` (pristine mode), merges
  `origin/main`, rebuilds lazbuild, the IDE and startlazarus, then relaunches the IDE.
- With nothing new upstream it skips the IDE rebuild unless you pass `-ForceRebuild`.
- Read its log for `[ERROR] Merge from origin failed`. That line means the IDE you just
  got is stale. Fix the merge; do not debug the IDE.

## 5. commonx compile mode: `-Mdelphiunicode` IS STANDARD -- NEVER change it

`PackageCommonX_LCL.lpk` compiles with `CustomOptions="-Mdelphiunicode -dLCL"`, and its
units (`stringx.pas`, `stringx.ansi.pas`, `systemx.pas`, `typex.pas`, `DelphiDefs.inc`, ...)
are written for that dialect. This was settled measured, twice (svn r6011/r6014, and the
Mac/Opus session of 2026-09-25):

- DO NOT remove, "modernize", or replace `-Mdelphiunicode` with `-Mdelphi` or `-Munleashed`.
  `-Mdelphi` (String=AnsiString) fails error 3069 on `var string` args; `-Munleashed` dies
  at `typex.pas` ("( expected but [ found") and on generics without specialization. Both
  measured. The package's NON-MEMBER transitive units inherit the PACKAGE's -M flag, which
  is why mode bugs surface far from the lpk.
- `stringx.ansi.pas` (and `ios.stringx.iosansi.pas`) are REQUIRED units, not cruft. Do not
  delete them or "fix" errors by removing the dotted/variant units. 4 hours were lost on the
  Mac (2026-09-25) to agents treating them as broken; they were not.
- If the IDE build fails with "PPU corruption detected in unit STRINGX.ANSI (symid=75),
  scheduling recompile" / "Can't find unit stringx.ansi used by systemx": that was a
  VibePascal COMPILER bug, fixed in vibepascal 5c51ef12b3 -- not a source defect and not
  build ordering (building the package standalone first was measured and does NOT help).
  The dotted unit stringx.ansi uses a unit named like its namespace (stringx), so the
  compiler puts a hidden "$hiddenstringx" unitsym in its implementation symtable. The
  interface namespacesym was dereferenced before that symtable loaded, the slot was nil,
  and the compiler declared a good .ppu corrupt, deleted it, and could not rebuild it
  without commonx source on the IDE path. App builds never showed it because they have
  the source and recompiled silently. If it ever comes back, the compiler is stale:
  run auto-update.sh (it rebuilds the compiler). Do NOT touch the commonx source.
  commonx SME: Knox.
