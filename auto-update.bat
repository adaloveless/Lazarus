@echo off
REM Lazarus + VibePascal Auto-Updater (Windows)
REM Wrapper for auto-update.ps1 — double-click or run from cmd.
REM
REM Usage: auto-update.bat [options]
REM   -Check          Check for updates only
REM   -NoBuild        Pull updates but skip rebuild
REM   -Release        Also build release tarballs
REM   -UpstreamOnly   Only sync upstream Lazarus
REM   -VPDir <path>   Path to VibePascal source

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-update.ps1" %*

if %ERRORLEVEL% neq 0 (
    echo.
    echo Auto-update finished with errors. See output above.
    pause
) else (
    echo.
    echo Auto-update complete.
    timeout /t 5
)
