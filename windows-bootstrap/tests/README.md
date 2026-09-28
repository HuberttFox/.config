# Windows Bootstrap tests

Tests run on Windows PowerShell 5.1 or PowerShell 7 on a Windows 11 host. They
must not invoke real WinGet, WSL install, reboot, input-method mutation, or
application installers. Use `-DryRun` and temporary `-StateRoot` for
orchestration checks.
