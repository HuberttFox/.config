@echo off
rem Launch the Windows bootstrap without changing the machine or user
rem execution policy. Mutating operations request UAC elevation automatically
rem when the terminal is not already elevated.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
