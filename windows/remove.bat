@echo off
title Navidrome Discord presence - remove
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\navidrome-presence.cmd" 2>nul
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'py*.exe' -and $_.ProcessId -ne $PID -and $_.CommandLine -like '*navidrome_presence.py*' } | ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }"
echo Removed. Your settings are still in %APPDATA%\navidrome-presence - delete that folder to remove them too.
pause
