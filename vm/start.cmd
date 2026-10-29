@echo off
rem Warrior Epic VM test 1: copy game, add DebugConfig.cfg, start logging stub, start the game.
set VM=%~dp0
set WE=C:\WE
set SRC=C:\orig
if not exist "%SRC%\WEShell_TGI.exe" set SRC=%VM%game
if not exist "%SRC%\WEShell_TGI.exe" (
  echo Game folder not found. Map "Warrior Epic" to C:\orig, or copy it to %VM%game
  pause & exit /b 1
)
if not exist "%WE%\WEShell_TGI.exe" (
  echo Copying game to %WE% ^(1.4 GB, takes a minute^)...
  robocopy "%SRC%" "%WE%" /E /NFL /NDL /NJH /NJS /NP
)
copy /y "%VM%DebugConfig.cfg" "%WE%\DebugConfig.cfg" >nul
mkdir "%VM%out" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%patch.ps1" > "%VM%out\patch.txt" 2>&1
if errorlevel 1 (
  type "%VM%out\patch.txt"
  echo Exe patch failed, game not started.
  exit /b 1
)
mkdir "%VM%out" 2>nul
dir /s /b /a-d "%APPDATA%" "%LOCALAPPDATA%" "%TEMP%" > "%VM%out\userfiles_before.txt" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%fixaudio.ps1" >nul 2>&1
start "WE stub server" powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%stub.ps1"
ping -n 4 127.0.0.1 >nul
cd /d "%WE%"
start "" WEShell_TGI.exe
rem in-memory patches M1/M2 (CHANGES.md): waits for WEHallUI.dll, verifies bytes, patches; logs to out\patchmem.txt
start "" /min %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%VM%patchmem.ps1"
echo.
echo Game started. Play until it stops (e.g. "Connecting to IS..." or a login screen),
echo note what you see, close the game, then run collect.cmd.
