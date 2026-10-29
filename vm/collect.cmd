@echo off
rem Gathers logs and anything the game wrote into out\ (visible on the host).
set VM=%~dp0
set O=%VM%out
mkdir "%O%" 2>nul
robocopy C:\WE "%O%\WE_new_files" /E /XF *.pak /MAXAGE:1 /NJH /NJS /NP > "%O%\robocopy.txt"
dir /s /b /a-d "%APPDATA%" "%LOCALAPPDATA%" "%TEMP%" > "%O%\userfiles_after.txt" 2>nul
dir /s /a-d /od C:\WE > "%O%\WE_listing.txt"
tasklist > "%O%\tasklist.txt"
echo Done. Copy back the folder: %O%
if /i not "%~1"=="nopause" pause
