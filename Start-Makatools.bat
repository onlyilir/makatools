@echo off
rem Starts Makatools without installing it (the portable zip). Uses 64-bit PowerShell on 64-bit
rem Windows, even when started from a 32-bit program, and closes this window straight away.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Makatools.ps1"
