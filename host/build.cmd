@echo off
rem Builds host\wehost.dll (32-bit) and copies it to vm\ for the sandbox. Host-side only; never run the DLL here.
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat" >nul 2>nul
cd /d "%~dp0"
cl /nologo /LD /O1 /W3 /GS- wehost.c user32.lib ws2_32.lib /Fe:wehost.dll /link /NOLOGO || exit /b 1
copy /y wehost.dll ..\vm\wehost.dll >nul
del /q *.obj *.exp *.lib 2>nul
echo built vm\wehost.dll
