@echo off
rem Prepare a checkout from your own copy of the disc, then build the port:
rem the same steps as setup.sh (see there), with port\build.bat.
setlocal
cd /d "%~dp0"
call tools\build.bat
if errorlevel 1 exit /b 1
tools\bof4tools.exe setup
if errorlevel 1 exit /b 1
call port\build.bat %*
if errorlevel 1 exit /b 1
echo built port\bof4.exe: run it from port\ (cd port ^&^& bof4)
