@echo off
setlocal
title Navidrome Discord presence - troubleshoot
rem  Runs navidrome-presence in this window with details, so you can see what it is doing.
rem  Start a song in your Navidrome app, then watch the lines below. Close the window to stop.

set "DIR=%~dp0.."
for %%I in ("%DIR%") do set "DIR=%%~fI"
set "CFG=%APPDATA%\navidrome-presence\config.ini"
set "PY="
py -3 --version >nul 2>nul && set "PY=py -3"
if not defined PY python --version >nul 2>nul && set "PY=python"
if not defined PY ( echo Python is not installed - run setup.bat first. & pause & exit /b 1 )
if not exist "%CFG%" ( echo No settings yet - run setup.bat first. & pause & exit /b 1 )

rem The background copy would compete with this one, so stop it while troubleshooting.
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'py*.exe' -and $_.ProcessId -ne $PID -and $_.CommandLine -like '*navidrome_presence.py*' } | ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }" >nul 2>nul

echo === Check ===
%PY% "%DIR%\navidrome_presence.py" -c "%CFG%" --check
echo.
echo === Live (play a song now; look for "Presence:" lines; close this window to stop) ===
echo     When you're done, run setup.bat again to restart it in the background.
echo.
%PY% "%DIR%\navidrome_presence.py" -c "%CFG%" -v
pause
