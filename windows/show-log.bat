@echo off
set "LOG=%APPDATA%\navidrome-presence\navidrome-presence.log"
if exist "%LOG%" ( start "" notepad "%LOG%" ) else ( echo No log yet - it is created when navidrome-presence runs in the background. & pause )
