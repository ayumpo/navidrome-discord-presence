@echo off
setlocal
title Navidrome Discord presence - setup
rem  Double-click this file. It asks a few questions, tests the connection,
rem  and makes navidrome-presence start in the background when you log in to Windows.
rem  Run it again any time to update or restart it (your settings are kept).

set "DIR=%~dp0.."
for %%I in ("%DIR%") do set "DIR=%%~fI"
set "CFG=%APPDATA%\navidrome-presence\config.ini"
set "LOG=%APPDATA%\navidrome-presence\navidrome-presence.log"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"

set "PY="
set "PYW="
py -3 --version >nul 2>nul && (set "PY=py -3" & set "PYW=pyw -3")
if not defined PY python --version >nul 2>nul && (set "PY=python" & set "PYW=pythonw")
if not defined PY (
  echo Python is not installed yet.
  echo Your browser will open python.org - install Python, tick "Add python.exe to PATH",
  echo then double-click this file again.
  start "" https://www.python.org/downloads/
  pause
  exit /b 1
)

if exist "%CFG%" (
  echo Keeping your existing settings: %CFG%
  echo To change them, delete that file and run this again.
) else (
  %PY% "%DIR%\navidrome_presence.py" --setup "%CFG%"
  if errorlevel 1 (
    echo Setup did not finish. Double-click this file to try again.
    pause
    exit /b 1
  )
)

rem Stop a copy that may already be running in the background (so there is only ever one).
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'py*.exe' -and $_.ProcessId -ne $PID -and $_.CommandLine -like '*navidrome_presence.py*' -and $_.CommandLine -notlike '*--check*' } | ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }" >nul 2>nul

echo.
echo Testing - if Discord is open, a test status shows on your profile for 15 seconds...
%PY% "%DIR%\navidrome_presence.py" -c "%CFG%" --check

> "%STARTUP%\navidrome-presence.cmd" echo @start "" %PYW% "%DIR%\navidrome_presence.py" -c "%CFG%"
start "" %PYW% "%DIR%\navidrome_presence.py" -c "%CFG%"

echo.
echo All set! It now runs in the background and starts when you log in to Windows.
echo  - In Discord: Settings - Activity Privacy - turn on "Share my activity".
echo  - Play a song in your Navidrome app; your status updates within a few seconds.
echo  - Not showing up? Double-click troubleshoot.bat while a song plays.
echo  - Log file: %LOG%
pause
