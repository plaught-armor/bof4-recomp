@echo off
rem Build the port on Windows: the same build as build.sh (see there for
rem `debug`, BOF4_OPT and BOF4_ARCH), plus an 8 MB main stack (the
rem recompiled code's call frames live on it; Windows gives 1 MB) and
rem SDL2.dll from Odin's vendor folder next to bof4.exe.
setlocal
cd /d "%~dp0"
if not defined BOF4_OPT set BOF4_OPT=speed
if not defined BOF4_ARCH set BOF4_ARCH=native
if not defined PS_RECOMP set PS_RECOMP=..\ps-recomp
rem %* is passed on as typed: cmd splits arguments at = , ; too, so
rem gathering them one by one would break -define:NAME=value.
set DEBUG=
set ARGS=%*
if not "%~1"=="debug" goto build
set DEBUG=-debug
set ARGS=%ARGS:*debug=%
:build
odin build src -out:bof4.exe -use-separate-modules %DEBUG% -o:%BOF4_OPT% -microarch:%BOF4_ARCH% -collection:ps=%PS_RECOMP% -define:ENV_PREFIX=BOF4_ -extra-linker-flags:/STACK:8388608 %ARGS%
if errorlevel 1 exit /b 1
for /f "delims=" %%r in ('odin root') do set ODIN_ROOT=%%r
copy /y "%ODIN_ROOT%\vendor\sdl2\SDL2.dll" . >nul
