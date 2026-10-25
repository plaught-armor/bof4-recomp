@echo off
rem Build the port on Windows: the same build as build.sh (see there for
rem BOF4_OPT, BOF4_ARCH and BOF4_GL_DEBUG), plus an 8 MB main stack (the
rem recompiled code's call frames live on it; Windows gives 1 MB) and
rem SDL2.dll from Odin's vendor folder next to bof4.exe.
setlocal
cd /d "%~dp0"
if not defined BOF4_OPT set BOF4_OPT=speed
if not defined BOF4_ARCH set BOF4_ARCH=native
if not defined BOF4_GL_DEBUG set BOF4_GL_DEBUG=false
if not defined PS_RECOMP set PS_RECOMP=..\ps-recomp
odin build src -out:bof4.exe -use-separate-modules -debug -o:%BOF4_OPT% -microarch:%BOF4_ARCH% -define:GL_DEBUG=%BOF4_GL_DEBUG% -collection:ps=%PS_RECOMP% -define:ENV_PREFIX=BOF4_ -extra-linker-flags:/STACK:8388608 %*
if errorlevel 1 exit /b 1
for /f "delims=" %%r in ('odin root') do set ODIN_ROOT=%%r
copy /y "%ODIN_ROOT%\vendor\sdl2\SDL2.dll" . >nul
