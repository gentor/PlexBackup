@echo off
rem Runs PlexCleanup.ps1 as the current user (no elevation: run it as the user running Plex).
rem Any arguments are passed to the script, e.g.:
rem   RunPlexCleanup.bat -WhatIf
rem   RunPlexCleanup.bat -SkipMaintenance
rem For scheduled tasks, call powershell.exe directly instead (this file pauses at the end).
setlocal

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexCleanup.ps1" %*
set "RC=%errorlevel%"

echo.
echo PlexCleanup finished with exit code %RC%.
pause
exit /b %RC%
