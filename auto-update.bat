@echo off
REM Lazarus + VibePascal Auto-Updater (Windows)
REM Wrapper for auto-update.ps1 -- double-click or run from cmd.
REM
REM Usage: auto-update.bat [options]
REM   -Check          Check for updates only (no pull, no build)
REM   -NoBuild        Pull updates but skip rebuild
REM   -Release        Also build release tarballs
REM   -UpstreamOnly   Only sync upstream Lazarus (skip VibePascal)
REM   -Setup          Configure Lazarus IDE to use VibePascal compiler
REM   -FixLpi         Scan and fix .lpi files
REM   -ForceRebuild   Force rebuild even if no updates are available
REM   -ResetConfig    Wipe %%LOCALAPPDATA%%\lazarus and re-run -Setup
REM   -Doctor         Diagnose toolchain + IDE config (read-only)
REM   -VPDir <path>   Path to VibePascal source
REM   -NoLaunch       Do not launch the IDE after a successful rebuild
REM   -AllowPush      Opt-in: push post-upstream-merge to origin/main
REM   -KeepLocal      Preserve uncommitted changes and untracked files
REM   -Help           Show full ps1 help

REM --- Close any running Lazarus IDE so the updater can replace its files. ---
REM A running lazarus.exe / startlazarus.exe locks the binaries on Windows, so
REM the rebuild step fails silently (stale-binary error). Skip the kill for
REM operations that never touch the installed binaries.
echo %* | findstr /i "Check Doctor Help NoBuild Setup FixLpi ResetConfig" >nul
if errorlevel 1 (
    echo Closing any running Lazarus IDE so its files can be updated...
    taskkill /F /IM lazarus.exe      >nul 2>&1
    taskkill /F /IM startlazarus.exe >nul 2>&1
    REM Also kill any running compiler instances -- a crashed or hung ppcx64.exe
    REM locks its own binary, causing git clean -fdx and tarball extraction to fail.
    taskkill /F /IM ppcx64.exe       >nul 2>&1
    taskkill /F /IM fpc.exe          >nul 2>&1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-update.ps1" %*
set "AU_EXIT=%ERRORLEVEL%"

if not "%AU_EXIT%"=="0" (
    echo.
    echo Auto-update finished with errors. See output above.
) else (
    echo.
    echo Auto-update complete.
)

exit /b %AU_EXIT%
