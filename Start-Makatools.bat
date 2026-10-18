@echo off
rem Launches Makatools. Right-click and choose "Run as administrator" for full features.
rem Uses 64-bit PowerShell on 64-bit Windows, even when started from a 32-bit program.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Makatools.ps1"
