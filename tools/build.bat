@echo off
rem Build the checkout's tools into tools\bof4tools.exe (see main.odin).
setlocal
cd /d "%~dp0"
odin build . -out:bof4tools.exe -o:speed
