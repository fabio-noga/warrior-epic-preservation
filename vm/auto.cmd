@echo off
rem Unattended run (LogonCommand of WarriorEpic_auto.wsb): start, screenshots, collect, shut the sandbox down.
rem Breakpoints for bp.ps1 come from out\bp_addrs.txt (one line, space separated); none = no tracer.
set VM=%~dp0
del /q "%VM%out\done.txt" 2>nul
set BPA=
if exist "%VM%out\bp_addrs.txt" set /p BPA=<"%VM%out\bp_addrs.txt"
call "%VM%start.cmd"
rem wehost.dll is injected into both game instances (server, client) by launch.ps1, from start.cmd
rem optional early trace (login phase): addresses in out\bp_early.txt
set BPE=
if exist "%VM%out\bp_early.txt" set /p BPE=<"%VM%out\bp_early.txt"
ping -n 8 127.0.0.1 >nul
if defined BPE start "" /min %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%VM%bp.ps1" -Seconds 120 %BPE%
ping -n 26 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%login.ps1" client > "%VM%out\login.txt" 2>&1
ping -n 31 127.0.0.1 >nul
rem PLAY NOW (fractions of the game window rect), then USA marker, Lobby 1 row
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.730 0.468 > "%VM%out\click.txt" 2>&1
ping -n 11 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.108 0.312 >> "%VM%out\click.txt" 2>&1
rem the room list arrives a few seconds after the USA click (slower with the server instance running): wait, click twice
ping -n 16 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.613 0.308 >> "%VM%out\click.txt" 2>&1
ping -n 3 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.613 0.308 >> "%VM%out\click.txt" 2>&1
ping -n 4 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%shot.ps1"
rem breakpoint logger (32-bit PowerShell) attached around JOIN and the next PLAY NOW
if defined BPA start "" %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%VM%bp.ps1" -Seconds 50 %BPA%
ping -n 6 127.0.0.1 >nul
rem JOIN
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.248 0.812 >> "%VM%out\click.txt" 2>&1
ping -n 11 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%shot.ps1"
rem 3D lobby: create game (first toolbar icon), OK in the New Game panel, then START in the game room
ping -n 16 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.777 0.976 >> "%VM%out\click.txt" 2>&1
ping -n 4 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%shot.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.445 0.65 >> "%VM%out\click.txt" 2>&1
ping -n 11 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%shot.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%click.ps1" 0.61 0.815 >> "%VM%out\click.txt" 2>&1
ping -n 21 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%shot.ps1"
rem dungeon loaded by now (two instances: allow extra time), then attack the Jungle Growth and try skills
ping -n 31 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%shot.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%combat.ps1" > "%VM%out\combat.txt" 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%VM%shot.ps1"
ping -n 11 127.0.0.1 >nul
rem full memory dump of the (possibly hung) game, for offline stack inspection
%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%VM%dump.ps1" > "%VM%out\dump.txt" 2>&1
ping -n 6 127.0.0.1 >nul
taskkill /im WEShell_TGI.exe >nul 2>&1
ping -n 6 127.0.0.1 >nul
taskkill /f /im WEShell_TGI.exe >nul 2>&1
call "%VM%collect.cmd" nopause
echo done %date% %time% > "%VM%out\done.txt"
shutdown /s /t 3
