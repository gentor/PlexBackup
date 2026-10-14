@echo off
rem Runs RegisterScheduledTask.ps1 as Administrator (prompts for elevation via UAC).
rem Run it as the user running Plex Media Server. Any arguments are passed to the script, e.g.:
rem   RegisterScheduledTask.bat -Task Cleanup,Backup
rem   RegisterScheduledTask.bat -Task CheckUsbDisks -DriveLetter E,F,G
rem   RegisterScheduledTask.bat -Task CheckUsbDisks -Unregister
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RegisterScheduledTask.ps1" %*
set "RC=%errorlevel%"

echo.
echo RegisterScheduledTask finished with exit code %RC%.
pause
exit /b %RC%
