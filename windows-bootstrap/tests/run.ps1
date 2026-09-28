#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('windows-bootstrap-tests-' + [guid]::NewGuid().ToString('N'))
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Passed = 0
$script:Failed = 0

New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
. (Join-Path $script:RepoRoot 'windows-bootstrap\lib\Bootstrap.Core.ps1')

# Cleanup tests use a temporary root, not a real user profile path.
function Test-BootstrapOwnedCleanupPath([string]$Path) {
    return $true
}

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (actual='$Actual', expected='$Expected')" }
}

function Invoke-TestCase([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS: $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL: $Name :: $($_.Exception.Message)"
    }
}

function New-TestContext([string]$Name) {
    $root = Join-Path $script:TestRoot $Name
    $stateRoot = Join-Path $root 'state'
    $backupRoot = Join-Path $stateRoot 'backups'
    $tempRoot = Join-Path $stateRoot 'temp'
    New-Item -ItemType Directory -Path $backupRoot, $tempRoot -Force | Out-Null
    $runId = [guid]::NewGuid().ToString('N')
    $state = New-BootstrapState $stateRoot $runId 'Core' $false
    $report = New-BootstrapReport $stateRoot $runId 'Core' $false
    return [pscustomobject]@{
        StateRoot = $stateRoot
        StatePath = Join-Path $stateRoot 'state.json'
        ReportPath = Join-Path $stateRoot 'report.json'
        LogPath = Join-Path $stateRoot 'bootstrap.log'
        BackupRoot = $backupRoot
        TempRoot = $tempRoot
        RepoRoot = $script:RepoRoot
        BootstrapRoot = Join-Path $script:RepoRoot 'windows-bootstrap'
        RunId = $runId
        DryRun = $false
        Operation = 'Run'
        State = $state
        Report = $report
        Lock = $null
    }
}

try {
    Invoke-TestCase 'atomic JSON write and replacement' {
        $path = Join-Path $script:TestRoot 'atomic.json'
        Write-BootstrapJson $path ([ordered]@{ value = 'first' })
        Write-BootstrapJson $path ([ordered]@{ value = 'second' })
        $value = (Read-BootstrapJson $path).value
        Assert-Equal $value 'second' 'atomic JSON replacement failed'
        Assert-Test (@(Get-ChildItem -LiteralPath $script:TestRoot -Filter 'atomic.json.*.tmp' -ErrorAction SilentlyContinue).Count -eq 0) 'temporary JSON file remains'
    }

    Invoke-TestCase 'manifest metadata contract' {
        $items = @(Get-BootstrapManifestItems (Join-Path $script:RepoRoot 'windows-bootstrap\packages') @('base.json', 'core.json', 'optional.json'))
        Assert-Test ($items.Count -eq 23) 'unexpected manifest item count'
        Assert-Test (@($items | Where-Object { $_.mode -eq 'download' }).Count -gt 0) 'download item missing'
        Assert-Test (@($items | Where-Object { $_.mode -eq 'winget' -and $_.architecture -eq 'x64' }).Count -gt 0) 'x64 WinGet metadata missing'
        $font = Get-BootstrapFontManifest (Join-Path $script:RepoRoot 'windows-bootstrap')
        Assert-Equal $font.sha256 'fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e' 'font checksum changed'
    }

    Invoke-TestCase 'winget source resolves msstore override and defaults to winget' {
        Assert-Test ((Get-BootstrapWingetSource ([pscustomobject]@{ source = 'winget:Example.Package' })) -eq 'winget') 'winget source prefix did not default to winget'
        Assert-Test ((Get-BootstrapWingetSource ([pscustomobject]@{ source = 'msstore:9PFXXSHC64H3' })) -eq 'msstore') 'msstore source prefix was not honored'
        Assert-Test ((Get-BootstrapWingetSource ([pscustomobject]@{ source = 'winget:Example.Package'; wingetSource = 'msstore' })) -eq 'msstore') 'explicit wingetSource override did not win'
    }

    Invoke-TestCase 'manifest requires a pinned HTTPS url and sha256 for download mode' {
        $directory = Join-Path $script:TestRoot 'bad-download'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $item = [ordered]@{
            name = 'Broken download'
            mode = 'download'
            version = '1.0'
            architecture = 'x64'
            url = 'http://example.com/setup.exe'
            silentInstallArgs = @('/S')
            uninstallCommand = [ordered]@{ type = 'registry-uninstall'; args = @('/S') }
            source = 'download:http://example.com/setup.exe'
            checksum = 'sha256:nothex'
            verification = [ordered]@{ type = 'uninstall-registry'; command = 'Broken App' }
        }
        Write-BootstrapJson (Join-Path $directory 'bad.json') ([ordered]@{ format = 1; items = @($item) })
        $threw = $false
        try { @(Get-BootstrapManifestItems $directory @('bad.json')) | Out-Null } catch { $threw = $true }
        Assert-Test $threw 'download item with an insecure url and invalid checksum was accepted'
    }

    Invoke-TestCase 'uninstall command parsing handles quoted and unquoted paths' {
        $quoted = ConvertFrom-BootstrapCommandLine '"C:\Program Files\App\uninstall.exe" /S'
        Assert-Equal $quoted.Executable 'C:\Program Files\App\uninstall.exe' 'quoted executable parsed'
        Assert-Test ($quoted.Arguments -contains '/S') 'quoted arguments parsed'
        $plain = ConvertFrom-BootstrapCommandLine 'uninstall.exe /S'
        Assert-Equal $plain.Executable 'uninstall.exe' 'plain executable parsed'
        Assert-Test ($plain.Arguments -contains '/S') 'plain arguments parsed'
        $empty = ConvertFrom-BootstrapCommandLine ''
        Assert-Test ($null -eq $empty.Executable) 'empty command line should not parse an executable'
    }

    Invoke-TestCase 'download completion requires a display name' {
        Assert-Test (-not (Test-BootstrapDownloadCompletion ([pscustomobject]@{ details = $null }))) 'missing display name should not be complete'
        Assert-Test (-not (Test-BootstrapDownloadCompletion ([pscustomobject]@{ details = [pscustomobject]@{ displayName = '' } }))) 'empty display name should not be complete'
    }

    Invoke-TestCase 'elevation policy covers mutating operations only' {
        Assert-Test (Test-BootstrapElevationRequired $false 'Run' $false) 'Run should require elevation'
        Assert-Test (Test-BootstrapElevationRequired $false 'Resume' $false) 'Resume should require elevation'
        Assert-Test (Test-BootstrapElevationRequired $false 'Verify' $false) 'Verify should require elevation'
        Assert-Test (Test-BootstrapElevationRequired $false 'Cleanup' $false) 'Cleanup should require elevation'
        Assert-Test (-not (Test-BootstrapElevationRequired $false 'DryRun' $false)) 'DryRun should not require elevation'
        Assert-Test (-not (Test-BootstrapElevationRequired $false 'Report' $false)) 'Report should not require elevation'
        Assert-Test (-not (Test-BootstrapElevationRequired $true 'Run' $false)) 'elevated sessions should not re-elevate'
        Assert-Test (-not (Test-BootstrapElevationRequired $false 'Run' $true)) 'NoElevate should suppress elevation'
    }

    Invoke-TestCase 'elevated relaunch keeps the script path and bound parameters' {
        $bound = @{
            StateRoot = 'D:\state root'
            SkipRime = [System.Management.Automation.SwitchParameter]::new($true)
            DryRun = [System.Management.Automation.SwitchParameter]::new($false)
        }
        $arguments = @(Get-BootstrapElevatedArguments 'D:\repo\windows-bootstrap\install.ps1' $bound)
        Assert-Test ($arguments -contains '-NoProfile') 'profile flag missing'
        Assert-Test ($arguments -contains '-ExecutionPolicy') 'execution policy flag missing'
        Assert-Test ($arguments -contains 'Bypass') 'bypass value missing'
        Assert-Test ($arguments -contains '-File') 'file flag missing'
        Assert-Test ($arguments -contains '"D:\repo\windows-bootstrap\install.ps1"') 'script path missing'
        Assert-Test ($arguments -contains '-StateRoot') 'StateRoot name missing'
        Assert-Test ($arguments -contains '"D:\state root"') 'StateRoot value not quoted'
        Assert-Test ($arguments -contains '-SkipRime') 'enabled switch missing'
        Assert-Test (-not ($arguments -contains '-DryRun')) 'disabled switch should be dropped'
    }

    Invoke-TestCase 'external process timeout is enforced and reported' {
        if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
            $started = Get-Date
            $result = Invoke-BootstrapExternal (Join-Path $env:SystemRoot 'System32\ping.exe') @('-n', '30', '127.0.0.1') -TimeoutSeconds 2
            $elapsed = ((Get-Date) - $started).TotalSeconds
            Assert-Test ($result.ExitCode -eq 124) "timeout exit code was $($result.ExitCode)"
            Assert-Test ($elapsed -lt 20) "timeout did not return promptly: $elapsed seconds"
            Assert-Test ($result.Output -match 'Timed out') 'timeout note missing from output'
        }
    }

    Invoke-TestCase 'process argument quoting only quotes when required' {
        Assert-Equal (ConvertTo-BootstrapProcessArgument '/S') '/S' 'silent switch must stay unquoted'
        Assert-Equal (ConvertTo-BootstrapProcessArgument 'Git.Git') 'Git.Git' 'plain argument must stay unquoted'
        Assert-Equal (ConvertTo-BootstrapProcessArgument 'C:\Program Files\App') '"C:\Program Files\App"' 'argument with spaces must be quoted'
        Assert-Equal (ConvertTo-BootstrapProcessArgument '') '""' 'empty argument must be quoted'
    }

    Invoke-TestCase 'Windows 11 detection accepts registry Windows 10 label by build' {
        Assert-Test (Test-BootstrapWindows11 'Windows 10 Pro' '26200') 'Windows 11 build with legacy ProductName was rejected'
        Assert-Test (-not (Test-BootstrapWindows11 'Windows Server 2025' '26200')) 'Windows Server was accepted as Windows 11'
        Assert-Test (-not (Test-BootstrapWindows11 'Windows 10 Pro' '19045')) 'Windows 10 build was accepted as Windows 11'
    }

    Invoke-TestCase 'manifest rejects incomplete install contract' {
        $directory = Join-Path $script:TestRoot 'bad-manifest'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $manifest = [ordered]@{
            format = 1
            items = @([ordered]@{
                name = 'Broken package'
                mode = 'winget'
                wingetId = 'Broken.Package'
                version = '1.0'
                architecture = 'x64'
                silentInstallArgs = @()
                uninstallCommand = [ordered]@{ type = 'winget'; args = @() }
                source = 'test'
                checksum = 'test'
                verification = [ordered]@{}
            })
        }
        Write-BootstrapJson (Join-Path $directory 'bad.json') $manifest
        $threw = $false
        try { @(Get-BootstrapManifestItems $directory @('bad.json')) | Out-Null } catch { $threw = $true }
        Assert-Test $threw 'manifest with incomplete verification contract was accepted'
    }

    Invoke-TestCase 'backup reference cannot escape bootstrap backup root' {
        $context = New-TestContext 'backup-traversal'
        $source = Join-Path $context.StateRoot 'source.txt'
        $outside = Join-Path $script:TestRoot 'outside-backup.txt'
        [IO.File]::WriteAllText($source, 'source')
        [IO.File]::WriteAllText($outside, 'outside')
        $context.State.backups = @([pscustomobject]@{
            source = [IO.Path]::GetFullPath($source)
            backup = [IO.Path]::GetFullPath($outside)
            sha256 = Get-BootstrapFileSha256 $outside
            usedBy = @('component')
        })
        $context | Add-Member -NotePropertyName ActiveComponent -NotePropertyValue 'component' -Force
        $threw = $false
        try { Backup-BootstrapFile $context $source | Out-Null } catch { $threw = $true }
        Assert-Test $threw 'backup outside bootstrap root was accepted'
    }

    Invoke-TestCase 'dry-run WinGet step does not resolve or invoke host command' {
        $context = New-TestContext 'dry-run-winget'
        $context.DryRun = $true
        $item = [pscustomobject]@{ name = 'Test package'; mode = 'winget'; wingetId = 'Test.Package'; silentInstallArgs = @() }
        $result = Invoke-BootstrapWingetInstall $context $item $null
        Assert-Equal $result.status 'skipped' 'dry-run WinGet step did not skip'
    }

    Invoke-TestCase 'safe external output removes ANSI and control characters' {
        $escape = [string][char]27
        $safe = ConvertTo-BootstrapSafeText ($escape + '[31mred' + $escape + '[0m' + [char]0 + ' text')
        Assert-Equal $safe 'red text' 'ANSI/control output was not sanitized'
        $json = ConvertTo-BootstrapJsonText ([ordered]@{ output = $escape + '[31mred' })
        $parsed = $json | ConvertFrom-Json
        Assert-Equal $parsed.output '[31mred' 'serialized sanitized output is not parseable'
    }

    Invoke-TestCase 'missing registry value is safe under StrictMode' {
        $existingFunction = Get-Command Get-ItemProperty -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        try {
            function Get-ItemProperty {
                param([string]$Path, [string]$Name, [string]$ErrorAction)
                return [pscustomobject]@{ Existing = 'value' }
            }
            Assert-Equal (Get-BootstrapRegistryValue 'HKCU:\Test' 'Missing') $null 'missing registry value did not return null'
            Assert-Equal (Get-BootstrapRegistryValue 'HKCU:\Test' 'Existing') 'value' 'existing registry value was not returned'
        } finally {
            Remove-Item Function:\Get-ItemProperty -ErrorAction SilentlyContinue
            if ($null -ne $existingFunction) {
                Set-Item Function:\Get-ItemProperty -Value $existingFunction.ScriptBlock
            }
        }
    }

    Invoke-TestCase 'font completion accepts in-memory and persisted result details' {
        $fontRoot = Join-Path $script:TestRoot 'font-live'
        New-Item -ItemType Directory -Path $fontRoot -Force | Out-Null
        $fontName = 'JetBrainsMonoNerdFont-Regular.ttf'
        [IO.File]::WriteAllText((Join-Path $fontRoot $fontName), 'font')
        $fontKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        $registryBody = (Get-Command Get-BootstrapRegistryValue -CommandType Function).ScriptBlock
        $testPathCommand = Get-Command Test-Path -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        $testPathBody = if ($null -ne $testPathCommand) { $testPathCommand.ScriptBlock } else { $null }
        try {
            function Get-BootstrapRegistryValue([string]$Path, [string]$Name) {
                if ($Path -eq 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -and $Name -eq 'JetBrainsMonoNerdFont-Regular') {
                    return 'JetBrainsMonoNerdFont-Regular.ttf'
                }
                return $null
            }
            function Test-Path {
                param([string]$LiteralPath, [string]$PathType)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') { return $true }
                if ($PathType -eq 'Leaf') { return [IO.File]::Exists($LiteralPath) }
                if ($PathType -eq 'Container') { return [IO.Directory]::Exists($LiteralPath) }
                return [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath)
            }
            $hashtableResult = [pscustomobject]@{ details = @{ directory = $fontRoot; files = @($fontName) } }
            $objectResult = [pscustomobject]@{ details = [pscustomobject]@{ directory = $fontRoot; files = @($fontName) } }
            Assert-Test (Test-BootstrapFontCompletion $null $hashtableResult) 'in-memory Hashtable font result was rejected'
            Assert-Test (Test-BootstrapFontCompletion $null $objectResult) 'persisted object font result was rejected'
        } finally {
            Set-Item Function:\Get-BootstrapRegistryValue -Value $registryBody
            Remove-Item Function:\Test-Path -ErrorAction SilentlyContinue
            if ($null -ne $testPathBody) { Set-Item Function:\Test-Path -Value $testPathBody }
        }
    }

    Invoke-TestCase 'RIME config conflict is manual and non-destructive' {
        $previousLocalAppData = $env:LOCALAPPDATA
        $localAppData = Join-Path $script:TestRoot 'rime-conflict-localappdata'
        New-Item -ItemType Directory -Path (Join-Path $localAppData 'config-rime') -Force | Out-Null
        $env:LOCALAPPDATA = $localAppData
        $configPath = Join-Path $localAppData 'config-rime\rime.json'
        Write-BootstrapJson $configPath ([ordered]@{ format = 1; root = 'C:\\Users\\tester\\AppData\\Local\\RimeAcceptance'; manager = 'config-rime' })
        $getRegistrySnapshotBody = (Get-Command Get-BootstrapRegistryValueSnapshot -CommandType Function).ScriptBlock
        try {
            function Get-BootstrapRegistryValueSnapshot([string]$Path, [string]$Name) {
                if ($Name -eq 'RimeUserDir') {
                    return [pscustomobject]@{ Exists = $true; Value = 'C:\\Users\\tester\\AppData\\Local\\RimeAcceptance\\RimeConfig' }
                }
                return [pscustomobject]@{ Exists = $false; Value = $null }
            }
            $result = Get-BootstrapRimeConfigCompatibility 'C:\\Users\\tester\\AppData\\Local\\RimeProfiles'
            Assert-Test (-not $result.compatible) 'conflicting RIME config was accepted'
            Assert-Test (@($result.details.conflicts).Count -ge 1) 'RIME conflict details were not recorded'
        } finally {
            Set-Item Function:\Get-BootstrapRegistryValueSnapshot -Value $getRegistrySnapshotBody
            $env:LOCALAPPDATA = $previousLocalAppData
        }
    }

    Invoke-TestCase 'empty RIME selector is fail-closed' {
        $previousLocalAppData = $env:LOCALAPPDATA
        $localAppData = Join-Path $script:TestRoot 'rime-empty-selector-localappdata'
        New-Item -ItemType Directory -Path (Join-Path $localAppData 'config-rime') -Force | Out-Null
        $env:LOCALAPPDATA = $localAppData
        $snapshotBody = (Get-Command Get-BootstrapRegistryValueSnapshot -CommandType Function).ScriptBlock
        try {
            function Get-BootstrapRegistryValueSnapshot([string]$Path, [string]$Name) {
                if ($Name -eq 'RimeUserDir') {
                    return [pscustomobject]@{ Exists = $true; Value = '' }
                }
                return [pscustomobject]@{ Exists = $false; Value = $null }
            }
            $result = Get-BootstrapRimeConfigCompatibility 'C:\\Users\\tester\\AppData\\Local\\RimeProfiles'
            Assert-Test (-not $result.compatible) 'empty RIME selector was accepted'
            Assert-Test (@($result.details.conflicts | Where-Object { $_ -match 'empty' }).Count -eq 1) 'empty selector conflict was not recorded'
        } finally {
            Set-Item Function:\Get-BootstrapRegistryValueSnapshot -Value $snapshotBody
            $env:LOCALAPPDATA = $previousLocalAppData
        }
    }

    Invoke-TestCase 'Verify operation records finishedAt without completing state' {
        $context = New-TestContext 'verify-finished-at'
        $context.Operation = 'Verify'
        $context.State.phase = 'initialized'
        Save-BootstrapContext $context
        Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$context.State.finishedAt)) 'Verify did not record state finishedAt'
        Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$context.Report.finishedAt)) 'Verify did not record report finishedAt'
        Assert-Equal $context.State.phase 'initialized' 'Verify changed state phase'
    }

    Invoke-TestCase 'cleanup root boundary distinguishes sibling paths' {
        $root = Join-Path $script:TestRoot 'owned-root'
        $child = Join-Path $root 'child.txt'
        $sibling = Join-Path $script:TestRoot 'owned-root-other.txt'
        Assert-Test (Test-BootstrapPathWithinRoot $child $root) 'child path rejected inside root'
        Assert-Test (-not (Test-BootstrapPathWithinRoot $sibling $root)) 'sibling path accepted inside root'
    }

    Invoke-TestCase 'empty existing profile is backed up and restored on component failure' {
        $context = New-TestContext 'empty-profile'
        $profile = Join-Path $context.StateRoot 'profile.ps1'
        [IO.File]::WriteAllText($profile, '')
        $context | Add-Member -NotePropertyName ActiveComponent -NotePropertyValue 'PowerShell profiles' -Force
        $update = Update-BootstrapManagedBlock $context $profile '# managed content'
        Assert-Equal $update.status 'completed' 'profile update failed'
        $entry = @($context.State.managedFiles | Select-Object -First 1)[0]
        Assert-Test (Test-Path -LiteralPath $entry.backup -PathType Leaf) 'empty profile backup missing'
        Assert-Equal ([IO.FileInfo]$entry.backup).Length 0 'empty profile backup is not empty'
        Add-BootstrapResult $context 'PowerShell profiles' 'core' 'failed_uncleaned' 'simulated failure' $null | Out-Null
        Invoke-BootstrapCleanup $context | Out-Null
        Assert-Test (Test-Path -LiteralPath $profile -PathType Leaf) 'profile was not restored'
        Assert-Equal ([IO.File]::ReadAllText($profile)) '' 'empty profile content was not restored'
    }

    Invoke-TestCase 'changed managed profile is preserved during cleanup' {
        $context = New-TestContext 'changed-profile'
        $profile = Join-Path $context.StateRoot 'profile.ps1'
        [IO.File]::WriteAllText($profile, "user content`r`n")
        $context | Add-Member -NotePropertyName ActiveComponent -NotePropertyValue 'PowerShell profiles' -Force
        Update-BootstrapManagedBlock $context $profile '# managed content' | Out-Null
        [IO.File]::WriteAllText($profile, "user changed content`r`n")
        Add-BootstrapResult $context 'PowerShell profiles' 'core' 'failed_uncleaned' 'simulated failure' $null | Out-Null
        Invoke-BootstrapCleanup $context | Out-Null
        Assert-Equal ([IO.File]::ReadAllText($profile) -replace "`r`n", "`n") "user changed content`n" 'user-modified profile was overwritten'
    }

    Invoke-TestCase 'new owned profile is removed only after fingerprint match' {
        $context = New-TestContext 'created-profile'
        $profile = Join-Path $context.StateRoot 'new-profile.ps1'
        $context | Add-Member -NotePropertyName ActiveComponent -NotePropertyValue 'PowerShell profiles' -Force
        Update-BootstrapManagedBlock $context $profile '# managed content' | Out-Null
        Assert-Test (Test-Path -LiteralPath $profile -PathType Leaf) 'new profile was not created'
        Add-BootstrapResult $context 'PowerShell profiles' 'core' 'failed_uncleaned' 'simulated failure' $null | Out-Null
        Invoke-BootstrapCleanup $context | Out-Null
        Assert-Test (-not (Test-Path -LiteralPath $profile -PathType Leaf)) 'owned profile was not removed'
    }

    Invoke-TestCase 'managed profile cleanup never falls back to unrelated backup' {
        $context = New-TestContext 'managed-backup-linkage'
        $profile = Join-Path $context.StateRoot 'profile.ps1'
        [IO.File]::WriteAllText($profile, "original`r`n")
        $context | Add-Member -NotePropertyName ActiveComponent -NotePropertyValue 'PowerShell profiles' -Force
        Update-BootstrapManagedBlock $context $profile '# managed content' | Out-Null
        $managed = @($context.State.managedFiles | Select-Object -Last 1)[0]
        $fallback = Join-Path $context.BackupRoot 'unrelated-fallback.bak'
        [IO.File]::WriteAllText($fallback, "stale fallback`r`n")
        $context.State.backups = @($context.State.backups) + [pscustomobject]@{
            source = [IO.Path]::GetFullPath($profile)
            backup = [IO.Path]::GetFullPath($fallback)
            sha256 = Get-BootstrapFileSha256 $fallback
            kind = 'unrelated'
            usedBy = @('other component')
        }
        Remove-Item -LiteralPath $managed.backup -Force
        Remove-Item -LiteralPath $profile -Force
        Add-BootstrapResult $context 'PowerShell profiles' 'core' 'failed_uncleaned' 'simulated failure' $null | Out-Null
        Add-BootstrapResult $context 'other component' 'core' 'failed_uncleaned' 'simulated failure' $null | Out-Null
        Invoke-BootstrapCleanup $context | Out-Null
        Assert-Test (-not (Test-Path -LiteralPath $profile -PathType Leaf)) 'unrelated backup restored over managed cleanup refusal'
    }

    Invoke-TestCase 'successful component is excluded from failed cleanup' {
        $context = New-TestContext 'successful-profile'
        $profile = Join-Path $context.StateRoot 'profile.ps1'
        $context | Add-Member -NotePropertyName ActiveComponent -NotePropertyValue 'PowerShell profiles' -Force
        Update-BootstrapManagedBlock $context $profile '# managed content' | Out-Null
        Add-BootstrapResult $context 'PowerShell profiles' 'core' 'completed' 'ok' $null | Out-Null
        Invoke-BootstrapCleanup $context | Out-Null
        Assert-Test (Test-Path -LiteralPath $profile -PathType Leaf) 'successful component was cleaned'
    }

    Invoke-TestCase 'latest result recomputes state classifications' {
        $context = New-TestContext 'result-state'
        Add-BootstrapResult $context 'component' 'core' 'completed' 'first' $null | Out-Null
        Add-BootstrapResult $context 'component' 'core' 'failed_uncleaned' 'second' $null | Out-Null
        Assert-Test ($context.State.completedComponents -notcontains 'component') 'stale completed state remained after failure'
        Assert-Test ($context.State.failedComponents -contains 'component') 'failed state missing'
        Add-BootstrapResult $context 'component' 'core' 'completed' 'third' $null | Out-Null
        Assert-Test ($context.State.completedComponents -contains 'component') 'latest completed state missing'
        Assert-Test ($context.State.failedComponents -notcontains 'component') 'stale failed state remained after completion'
    }

    Invoke-TestCase 'resume arguments preserve execution options' {
        $context = New-TestContext 'resume-options'
        $context.State.executionOptions = [ordered]@{ skipRime = $true; noOptional = $true; noNetworkCheck = $true }
        $arguments = Get-BootstrapResumeArguments $context 'C:\repo\windows-bootstrap\install.ps1'
        Assert-Test ($arguments -match '(?i)-Resume') 'resume switch missing'
        Assert-Test ($arguments -match '(?i)-SkipRime') 'SkipRime option missing'
        Assert-Test ($arguments -match '(?i)-NoOptional') 'NoOptional option missing'
        Assert-Test ($arguments -match '(?i)-NoNetworkCheck') 'NoNetworkCheck option missing'
    }

    Invoke-TestCase 'dry-run context writes no state or lock files' {
        $root = Join-Path $script:TestRoot 'dry-run'
        $context = New-BootstrapContext $root 'Core' $true 'Run' $script:RepoRoot
        Save-BootstrapContext $context
        Assert-Test (-not (Test-Path -LiteralPath $root)) 'dry-run created state root'
        Assert-Test ($context.Report.dryRun) 'dry-run report flag missing'
    }

    Invoke-TestCase 'fresh Verify context can persist diagnostic state' {
        $root = Join-Path $script:TestRoot 'fresh-verify'
        $context = New-BootstrapContext $root 'Core' $false 'Verify' $script:RepoRoot
        $context.Report.host = [pscustomobject]@{ diagnostic = $true }
        Add-BootstrapResult $context 'diagnostic' 'core' 'manual_required' 'verification-only test' $null | Out-Null
        Save-BootstrapContext $context
        Assert-Test (Test-Path -LiteralPath $context.StatePath -PathType Leaf) 'fresh Verify state was not persisted'
        Assert-Test (Test-Path -LiteralPath $context.ReportPath -PathType Leaf) 'fresh Verify report was not persisted'
        Assert-Equal ([string](Read-BootstrapJson $context.StatePath).phase) 'initialized' 'fresh Verify changed installation phase'
    }

    Invoke-TestCase 'WSL verification handles no matching distro' {
        $getCommandBody = (Get-Command Get-BootstrapCommandPath -CommandType Function).ScriptBlock
        $externalBody = (Get-Command Invoke-BootstrapExternal -CommandType Function).ScriptBlock
        try {
            function Get-BootstrapCommandPath([string]$Name) { return 'wsl.exe' }
            function Invoke-BootstrapExternal([string]$FilePath, [string[]]$Arguments) {
                $output = if (@($Arguments) -contains '--verbose') { '  NAME                   STATE           VERSION' } else { '' }
                return [pscustomobject]@{ ExitCode = 0; Output = $output }
            }
            $check = Test-BootstrapWsl
            Assert-Test (-not $check.distro) 'empty WSL list was treated as installed distro'
            Assert-Test (-not $check.version2) 'empty WSL list was treated as WSL 2'
            Assert-Equal $check.distroName $null 'empty WSL list returned a phantom distro name'
        } finally {
            Set-Item -Path Function:\Get-BootstrapCommandPath -Value $getCommandBody
            Set-Item -Path Function:\Invoke-BootstrapExternal -Value $externalBody
        }
    }

    Invoke-TestCase 'WSL verification removes redirected UTF-16 NUL padding' {
        $getCommandBody = (Get-Command Get-BootstrapCommandPath -CommandType Function).ScriptBlock
        $externalBody = (Get-Command Invoke-BootstrapExternal -CommandType Function).ScriptBlock
        try {
            function Get-BootstrapCommandPath([string]$Name) { return 'wsl.exe' }
            function Invoke-BootstrapExternal([string]$FilePath, [string[]]$Arguments) {
                $plain = if (@($Arguments) -contains '--verbose') {
                    "  NAME                   STATE           VERSION`r`n* Ubuntu-24.04           Running         2"
                } else {
                    'Ubuntu-24.04'
                }
                $output = ($plain.ToCharArray() | ForEach-Object { "$_$([char]0)" }) -join ''
                return [pscustomobject]@{ ExitCode = 0; Output = $output }
            }
            $check = Test-BootstrapWsl
            Assert-Test $check.distro 'NUL-padded WSL list did not detect Ubuntu'
            Assert-Test $check.version2 'NUL-padded WSL verbose output did not detect version 2'
            Assert-Equal $check.distroName 'Ubuntu-24.04' 'NUL-padded WSL list returned wrong distro'
        } finally {
            Set-Item -Path Function:\Get-BootstrapCommandPath -Value $getCommandBody
            Set-Item -Path Function:\Invoke-BootstrapExternal -Value $externalBody
        }
    }

    Invoke-TestCase 'stale completion record is not trusted without live check' {
        $context = New-TestContext 'stale-completion'
        $context.Report.results = @([pscustomobject]@{ name = 'PowerShell profiles'; status = 'completed'; at = [DateTime]::UtcNow.ToString('o'); details = $null })
        $item = [pscustomobject]@{ name = 'PowerShell profiles'; mode = 'powershell-profile' }
        function Test-BootstrapPowerShellProfileCompletion($IgnoredContext) { return $script:LiveCompletion }
        $context.DryRun = $true
        $script:LiveCompletion = $true
        Assert-Test (-not (Test-BootstrapComponentStillComplete $context $item)) 'dry-run performed live completion probe'
        $context.DryRun = $false
        $script:LiveCompletion = $false
        Assert-Test (-not (Test-BootstrapComponentStillComplete $context $item)) 'stale completion was trusted'
        $script:LiveCompletion = $true
        Assert-Test (Test-BootstrapComponentStillComplete $context $item) 'valid live completion was rejected'
    }

    Invoke-TestCase 'RIME completion requires report written during invocation' {
        $previousLocalAppData = $env:LOCALAPPDATA
        $localAppData = Join-Path $script:TestRoot 'rime-localappdata'
        New-Item -ItemType Directory -Path $localAppData -Force | Out-Null
        $env:LOCALAPPDATA = $localAppData
        try {
            $root = Join-Path $localAppData 'RimeProfiles'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $reportPath = Join-Path $root 'install-report.json'
            $staleStarted = [DateTime]::UtcNow.AddMinutes(-10)
            Write-BootstrapJson $reportPath ([ordered]@{
                    format = 1
                    root = $root
                    startedAt = $staleStarted.ToString('o')
                    Results = @([ordered]@{ Profile = 'mint'; Status = 'completed' })
                })
            $staleInvocation = [DateTime]::UtcNow
            $staleWrite = (Get-Item -LiteralPath $reportPath -Force).LastWriteTimeUtc
            $staleHash = Get-BootstrapFileSha256 $reportPath
            $staleResult = [pscustomobject]@{ details = [pscustomobject]@{
                    root = $root
                    reportSha256 = $staleHash
                    invocationStartedAtUtc = $staleInvocation.ToString('o')
                    reportWriteTimeUtc = $staleWrite.ToString('o')
                    reportStartedAtUtc = $staleStarted.ToString('o')
                    fresh = $true
                } }
            Assert-Test (-not (Test-BootstrapRimeCompletion $staleResult)) 'stale RIME report was accepted as resumable'

            $freshStarted = [DateTime]::UtcNow
            Write-BootstrapJson $reportPath ([ordered]@{
                    format = 1
                    root = $root
                    startedAt = $freshStarted.ToString('o')
                    Results = @([ordered]@{ Profile = 'mint'; Status = 'completed' })
                })
            $freshWrite = (Get-Item -LiteralPath $reportPath -Force).LastWriteTimeUtc
            $freshHash = Get-BootstrapFileSha256 $reportPath
            $freshResult = [pscustomobject]@{ details = [pscustomobject]@{
                    root = $root
                    reportSha256 = $freshHash
                    invocationStartedAtUtc = $freshStarted.ToString('o')
                    reportWriteTimeUtc = $freshWrite.ToString('o')
                    reportStartedAtUtc = $freshStarted.ToString('o')
                    fresh = $true
                } }
            Assert-Test (Test-BootstrapRimeCompletion $freshResult) 'fresh RIME report was rejected'
        } finally {
            $env:LOCALAPPDATA = $previousLocalAppData
        }
    }

    Write-Host "Tests: $script:Passed passed, $script:Failed failed"
    if ($script:Failed -gt 0) { exit 1 }
} finally {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
