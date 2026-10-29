@echo off
rem Manual breakpoint trace: run this inside the sandbox while the game is running, then do the action
rem (e.g. press START) within 2 minutes. Breakpoints come from out\bp_addrs.txt; output goes to out\bp.txt.
set VM=%~dp0
set BPA=
if exist "%VM%out\bp_addrs.txt" set /p BPA=<"%VM%out\bp_addrs.txt"
if not defined BPA (echo No addresses in out\bp_addrs.txt & pause & exit /b 1)
echo Tracing %BPA% for 120 s - do the action in the game now.
%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%VM%bp.ps1" -Seconds 120 %BPA%
echo Done. Results in out\bp.txt
pause
