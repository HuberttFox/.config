@echo off
setlocal
set "RIME_CONTROL=%LOCALAPPDATA%\config-rime\scripts"
if not exist "%RIME_CONTROL%\rime-switch.ps1" (
  echo RIME control scripts missing. Run windows\install.ps1 first. 1>&2
  exit /b 2
)
pwsh.exe -NoProfile -File "%RIME_CONTROL%\rime-switch.ps1" -Status
exit /b %ERRORLEVEL%
