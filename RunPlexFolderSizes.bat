@echo off
rem Runs PlexFolderSizes.ps1 as the current user (no elevation: run it as the user running Plex).
rem Any arguments are passed to the script, e.g.:
rem   RunPlexFolderSizes.bat -Depth 2
rem   RunPlexFolderSizes.bat -Depth 3 -Top 5
rem   RunPlexFolderSizes.bat -PlexAppDataDir "%LOCALAPPDATA%\Plex Media Server\Metadata" -GroupBy Library,Type
setlocal

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexFolderSizes.ps1" %*
set "RC=%errorlevel%"

echo.
echo PlexFolderSizes finished with exit code %RC%.
pause
exit /b %RC%
