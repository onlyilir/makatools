@echo off
rem Installs Makatools for this Windows account (Start menu + Desktop shortcuts). No admin rights needed.
rem Extract the whole zip first, then double-click this file.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0setup\Install.ps1"
