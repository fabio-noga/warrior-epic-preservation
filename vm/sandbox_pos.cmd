@echo off
rem Remember / restore the Windows Sandbox window position (two-monitor setups). Runs on the host, moves a window only.
rem   sandbox_pos.cmd save      record where the open sandbox window is now
rem   sandbox_pos.cmd start     start WarriorEpic_test1.wsb and put its window there
rem   sandbox_pos.cmd start WarriorEpic_auto.wsb
if "%1"=="" (set ACT=start) else (set ACT=%1)
if "%2"=="" (set WSB=WarriorEpic_test1.wsb) else (set WSB=%2)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sandbox_pos.ps1" %ACT% -Wsb %WSB%
if "%ACT%"=="save" pause
