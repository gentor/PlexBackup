@echo off
rem Runs CheckUsbDisks.ps1 as Administrator (prompts for elevation via UAC).
rem Any arguments are passed to the script, e.g.:
rem   RunCheckUsbDisks.bat -WhatIf
rem   RunCheckUsbDisks.bat -DriveLetter H,I
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

rem Do not keep the current directory on a disk that is about to be dismounted.
cd /d "%SystemRoot%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CheckUsbDisks.ps1" %*
set "RC=%errorlevel%"

echo.
echo CheckUsbDisks finished with exit code %RC%.
pause
exit /b %RC%
