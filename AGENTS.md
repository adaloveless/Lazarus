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

## 6. Designer zoom (docked form editor): cocoa and win32

The zoom bar under the docked Form page (and Ctrl/Cmd + wheel, Ctrl/Cmd + +/-/0,
Fit) scales the VIEW of the designed form only. The form and its controls keep
their real Left/Top/Width/Height; the Object Inspector and the .lfm never see
zoomed values. Never "fix" zoom by changing control bounds.

How it hangs together:
- LCL hook `LCLIntf.SetWindowContentScale(Handle, Scale)` /
  `GetWindowEffectiveScale(Handle)` (lcl/include/lclintf*.inc). Base widgetset:
  unsupported (returns False for Scale <> 1, scale 1) -> the zoom bar disables
  itself. `TControl.ClientOrigin/ScreenToClient/ClientToScreen` map through the
  effective scale (lcl/include/control.inc, `ControlClientScale`); at scale 1
  they run the old integer code.
- Docked editor: `TResizer` (zoom bar, SetZoom, Fit), `TResizeControl.AdjustFormContainer`
  (container = zoomed frame, then SetWindowContentScale on FormContainer),
  `TDesignForm.Zoom/ZoomFit`. Designer: `FormClientPosFromScreen` in
  designer/designerprocs.pas, grabber/marker size in controlselection.pp.
- cocoa (DONE, verified in the real IDE 2026-09-25, 2d7fc4eda5): native NSView
  bounds scaling in lcl/interfaces/cocoa/cocoalclintf.inc. Clicks, drags,
  graphic controls, Fit and Cmd+wheel measured correct; .lfm untouched.
- win32 (native regression and IDE interaction tested 2026-09-25): win32 cannot scale
  child windows, so the scale is a window property (`Win32SetContentScale`,
  lcl/interfaces/win32/win32proc.pp) applied at the widgetset boundary:
  native bounds = LCL bounds * parent scale (PrepareCreateWindow,
  TWin32WSWinControl.SetBounds; forms: client scaled, border native in
  TWin32WSCustomForm.SetBounds + GetWindowSize), scaled HFONT for native
  controls (TWin32WSWinControl.SetFont), MM_ANISOTROPIC mapping on LCL paint
  DCs (SendPaintMessage), GetDC and the designer overlay DC (GetDesignerDC);
  divided back in GetWindowSize, GetWindowRelativePosition, GetClientBounds,
  ScreenToClient, mouse messages (UnscaleMousePos) and the overlay's
  WM_NCHITTEST. `ScaledWindowCount = 0` (nothing zoomed) short-circuits it all.

Windows follow-up fixes (2026-09-25): applying a scale is a view-only transaction;
native move/size callbacks must not update LCL bounds or trigger designer layout.
Compare scales at the window property's fixed-point precision. Preserve odd
logical bounds/client sizes when native pixel rounding matches them. The designer
also calls `LCLIntf.SetWindowPos` after `RealizeBounds`: that path must scale too,
or each drag at 50% doubles the saved dimensions. Skip native form tracking limits
on the scaled view; logical constraints have already been applied by the LCL.
Dark native painters must use the scaled window font. Combo font changes during
zoom must not rewrite logical height/ItemHeight. Destroying windows releases the
scale/font properties and counters.

Regression: build `lcl/tests/testwin32designerzoom.lpi` with `lazbuild --ws=win32`
and run `lcl/tests/lib/x86_64-win64/testwin32designerzoom.exe`. It uses real HWNDs,
checks serialized form properties through repeated 10%-400% zoom (including
fractional scales and invalidated client caches), native geometry, nested controls,
the designer's direct SetWindowPos path, coordinate conversion, and destruction.
It also forces dark mode and exercises the FormDecks-style row of aligned
checkboxes through repaint and bounds synchronization at 125%. Dark checkbox
placement must compare native rectangles with scaled bounds, otherwise painting
undoes zoom and can cause an endless layout/repaint loop.
CommonX TZD previews have a separate bitmap presentation path: on Windows,
`PasZD.LCL.pas` must use StretchDIBits with a logical destination size rather
than SetDIBitsToDevice, so the rendered bitmap follows the designer DC mapping.
That source lives in the external CommonX SVN working copy, not this repository.
Real IDE checks also covered dark rendering, a 40px drag at 50% (80 logical units,
grid-snapped), native/graphic control selection and dragging, resize, Fit and reset.

Windows test checklist (do these in order, on `main`, after auto-update.bat):
1. IDE at 100% behaves exactly as before (no zoom touched). Any difference
   here is a regression of the draft: bisect the win32 hunks of the commit.
2. Open a form bigger than the page, zoom 50%: controls, captions (scaled
   fonts), TLabel/TShape/TSpeedButton (DC mapping) all drawn at half size and
   in the right place; no red/garbage container area.
3. Click-select a windowed control, a graphic control, a control inside a
   panel; drag one: at 50% a 40 px mouse drag must move it 80 (grid-snapped).
   Resize via grabbers. Check the .lfm/OI values are real, not halved.
4. Fit, Ctrl+wheel around the cursor, Ctrl + +/-/0, back to 100%: form
   Width/Height unchanged, nothing left scaled.
5. MetaDarkStyle: themed parts drawn through DrawThemeBackground/Text into a
   mapped DC may ignore the mapping -> watch for 100%-size artwork inside a
   zoomed form (uwin32widgetsetdark.pas hooks). Known gaps to expect: group box
   caption offset (GetLCLClientBoundsOffset is native px), scroll bar
   positions inside scaled scroll boxes, WS classes that override SetFont
   without calling the base (they keep the unscaled font).
