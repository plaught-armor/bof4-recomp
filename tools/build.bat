@echo off
rem Build the checkout's tools into tools\bof4tools.exe (see main.odin).
setlocal
cd /d "%~dp0"
if not defined PS_RECOMP set PS_RECOMP=..\ps-recomp
odin build . -out:bof4tools.exe -o:speed -collection:ps=%PS_RECOMP%
