@echo off
rem Runs PlexBackup.ps1 as Administrator (prompts for elevation via UAC).
rem Always runs with -Verbose -RawOutput; other arguments are passed to the script, e.g.:
rem   RunPlexBackup.bat -Inactive
rem   RunPlexBackup.bat -Mode Restore
rem For scheduled tasks, call powershell.exe directly instead (this file pauses at the end).
setlocal

rem Relaunch elevated if not running as Administrator.
fltmc >nul 2>&1
if errorlevel 1 (
    set "SELF=%~f0"
    set "ARGS=%*"
    powershell -NoProfile -Command "$p = @{ FilePath = $env:SELF; Verb = 'RunAs' }; if ($env:ARGS) { $p.ArgumentList = $env:ARGS }; Start-Process @p"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexBackup.ps1" -Verbose -RawOutput %*
set "RC=%errorlevel%"

echo.
echo PlexBackup finished with exit code %RC%.
pause
exit /b %RC%
