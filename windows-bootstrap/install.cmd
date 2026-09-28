@echo off
rem Launch the Windows bootstrap without changing the machine or user
rem execution policy. Run this from an elevated terminal for install, resume,
rem verify, report, and cleanup operations.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
