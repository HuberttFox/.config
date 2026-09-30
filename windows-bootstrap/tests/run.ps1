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
    $logPath = Join-Path $stateRoot 'bootstrap.log'
    $report.logPath = $logPath
    return [pscustomobject]@{
        StateRoot = $stateRoot
        StatePath = Join-Path $stateRoot 'state.json'
        ReportPath = Join-Path $stateRoot 'report.json'
        LogPath = $logPath
        BackupRoot = $backupRoot
        TempRoot = $tempRoot
        RepoRoot = $script:RepoRoot
        BootstrapRoot = Join-Path $script:RepoRoot 'windows-bootstrap'
        RunId = $runId
        DryRun = $false
        Operation = 'Run'
        Quiet = $false
        Silent = $false
        State = $state
        Report = $report
        Lock = $null
    }
}

function Test-Throws([scriptblock]$Action) {
    try {
        & $Action
        return $false
    } catch {
        return $true
    }
}

function New-TestExtensionWingetItem(
    [string]$Id,
    [string]$Name,
    [ValidateSet('elevated', 'user')][string]$ItemContext = 'elevated',
    [string]$WingetId = 'Contoso.ExtensionFixture'
) {
    $scope = if ($ItemContext -eq 'user') { 'user' } else { 'machine' }
    return [ordered]@{
        id = $Id
        name = $Name
        provider = 'winget'
        version = 'winget-latest-stable'
        architecture = 'x64'
        executionContext = $ItemContext
        source = "winget:$WingetId"
        wingetId = $WingetId
        wingetSource = 'winget'
        install = [ordered]@{ scope = $scope; silent = $true; timeoutSeconds = 120 }
    }
}

function New-TestExtensionManualItem([string]$Id, [string]$Name, [string]$Reason = 'Requires a visible vendor workflow') {
    return [ordered]@{
        id = $Id
        name = $Name
        provider = 'manual'
        version = 'manual-review'
        architecture = 'x64'
        executionContext = 'elevated'
        source = "manual:fixture/$Id"
        checksum = 'manual-review'
        reason = $Reason
    }
}

function Write-TestExtensionManifest(
    [string]$Directory,
    [string]$ExtensionId,
    $Items,
    [string]$FileName = 'extension.json',
    [switch]$Utf8Bom
) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory $FileName
    $document = [ordered]@{ format = 2; id = $ExtensionId; items = @($Items) }
    if ($Utf8Bom) {
        $encoding = New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($path, (ConvertTo-BootstrapJsonText $document), $encoding)
    } else {
        Write-BootstrapJson $path $document
    }
    return $path
}

function Get-TestExtensionPlan([string[]]$Paths) {
    $bootstrapRoot = Join-Path $script:RepoRoot 'windows-bootstrap'
    $items = @(Get-BootstrapExtensionManifestItems $Paths $bootstrapRoot)
    return Get-BootstrapPackagePlan $items (Get-BootstrapExtensionManifestRecords $items)
}

function Invoke-TestBootstrapEntry([string[]]$Arguments) {
    $engine = ''
    try { $engine = [string](Get-Process -Id $PID -ErrorAction Stop).Path } catch { }
    if ([string]::IsNullOrWhiteSpace($engine)) {
        $candidate = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
        $engine = Join-Path $PSHOME $candidate
    }
    $scriptPath = Join-Path $script:RepoRoot 'windows-bootstrap\install.ps1'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $engine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (@('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + @($Arguments) |
        ForEach-Object { ConvertTo-BootstrapProcessArgument ([string]$_) }) -join ' '
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start the bootstrap entry test process' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            exitCode = [int]$process.ExitCode
            output = @($stdoutTask.Result, $stderrTask.Result | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }
    } finally {
        $process.Dispose()
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

    Invoke-TestCase 'manifest fingerprint is stable and binds machine items' {
        $user = [pscustomobject]@{ name = 'Spotify'; mode = 'winget'; wingetId = 'Spotify.Spotify'; executionContext = 'user'; silentInstallArgs = @('--scope', 'user') }
        $machine = [pscustomobject]@{ name = 'Git'; mode = 'winget'; wingetId = 'Git.Git'; executionContext = 'elevated'; silentInstallArgs = @('--scope', 'machine') }
        $first = Get-BootstrapUserPhaseManifestFingerprint @($user, $machine)
        $second = Get-BootstrapUserPhaseManifestFingerprint @($user, $machine)
        Assert-Equal $first $second 'manifest fingerprint is not stable'
        $changedMachine = [pscustomobject]@{ name = 'Git'; mode = 'winget'; wingetId = 'Git.Git'; executionContext = 'elevated'; silentInstallArgs = @('--scope', 'user') }
        Assert-Test ($first -ne (Get-BootstrapUserPhaseManifestFingerprint @($user, $changedMachine))) 'manifest fingerprint did not bind machine item details'
    }

    Invoke-TestCase 'user phase handoff DACL is owner/SYSTEM-only and idempotent' {
        if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
        $root = Join-Path $script:TestRoot 'handoff-acl'
        $ownerSid = Get-BootstrapCurrentUserSid
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Protect-BootstrapUserPhaseRoot $root $ownerSid | Out-Null
        Protect-BootstrapUserPhaseRoot $root $ownerSid | Out-Null
        $handoff = Join-Path $root 'handoff.json'
        Write-BootstrapJson $handoff ([ordered]@{ format = 1 })
        Protect-BootstrapUserPhaseHandoff $handoff $ownerSid | Out-Null
        Protect-BootstrapUserPhaseHandoff $handoff $ownerSid | Out-Null
        Assert-Test (Test-BootstrapUserPhasePathSecurity $root $ownerSid -RequireProtectedDacl) 'protected user phase root was rejected'
        Assert-Test (Test-BootstrapUserPhasePathSecurity $handoff $ownerSid -RequireProtectedDacl) 'protected handoff DACL was rejected'
        $acl = Get-Acl -LiteralPath $handoff
        Assert-Test $acl.AreAccessRulesProtected 'handoff DACL stayed inherited'
    }

    Invoke-TestCase 'manifest metadata contract' {
        $items = @(Get-BootstrapManifestItems (Join-Path $script:RepoRoot 'windows-bootstrap\packages') @('base.json', 'core.json', 'optional.json'))
        Assert-Test ($items.Count -eq 36) 'unexpected manifest item count'
        Assert-Test (@($items | Where-Object { $_.mode -eq 'download' }).Count -gt 0) 'download item missing'
        Assert-Test (@($items | Where-Object { $_.mode -eq 'portable-handoff' }).Count -eq 1) 'portable handoff item missing'
        Assert-Test (@($items | Where-Object { $_.mode -eq 'winget' -and $_.architecture -eq 'x64' }).Count -gt 0) 'x64 WinGet metadata missing'
        $font = Get-BootstrapFontManifest (Join-Path $script:RepoRoot 'windows-bootstrap')
        Assert-Equal $font.sha256 'fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e' 'font checksum changed'
    }

    Invoke-TestCase 'extension manifest schema is restrictive and supports singleton arrays' {
        $directory = Join-Path $script:TestRoot 'extension-schema'
        $unicodeReason = 'Caf' + [char]0x00E9 + ' vendor workflow'
        $manual = New-TestExtensionManualItem 'manual-review' 'Manual review' $unicodeReason
        $items = @(
            (New-TestExtensionWingetItem -Id 'machine-cli' -Name 'Machine CLI' -ItemContext elevated -WingetId 'Contoso.MachineCli'),
            (New-TestExtensionWingetItem -Id 'user-cli' -Name 'User CLI' -ItemContext user -WingetId 'Contoso.UserCli'),
            $manual
        )
        $path = Write-TestExtensionManifest $directory 'fixture-tools' $items 'valid.json' -Utf8Bom
        $parsed = @(Get-BootstrapExtensionManifestItems @($path) (Join-Path $script:RepoRoot 'windows-bootstrap'))
        Assert-Test ($parsed.Count -eq 3) 'valid extension items were not parsed'
        Assert-Equal ([string]@($parsed | Where-Object { $_.id -eq 'fixture-tools/manual-review' })[0].reason) $unicodeReason 'UTF-8 BOM/non-ASCII manual reason changed'
        Assert-Equal (Get-BootstrapItemExecutionContext @($parsed | Where-Object { $_.id -eq 'fixture-tools/user-cli' })[0]) 'user' 'user WinGet context was not retained'
        $registry = Get-BootstrapProviderRegistry (Join-Path $script:RepoRoot 'windows-bootstrap')
        Assert-Test (@($registry['manual'].executionContexts).Count -eq 1) 'singleton provider execution-context array was not retained'
        Assert-Equal ([string]@($registry['manual'].executionContexts)[0]) 'elevated' 'manual provider context changed'

        $unsafe = New-TestExtensionWingetItem -Id 'unsafe-command' -Name 'Unsafe command' -WingetId 'Contoso.UnsafeCommand'
        $unsafe['installCommand'] = 'Start-Process calc.exe'
        $unsafePath = Write-TestExtensionManifest $directory 'unsafe-command' @($unsafe) 'unsafe-command.json'
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($unsafePath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'extension installCommand was accepted'

        $duplicateFieldPath = Join-Path $directory 'duplicate-field.json'
        $duplicateFieldJson = '{"format":2,"id":"duplicate-field","items":[{"id":"duplicate-item","id":"other-item","name":"Duplicate field","provider":"manual","version":"manual-review","architecture":"x64","executionContext":"elevated","source":"manual:fixture/duplicate","checksum":"manual-review","reason":"Requires manual review"}]}'
        [IO.File]::WriteAllText($duplicateFieldPath, $duplicateFieldJson, (New-Object Text.UTF8Encoding($false)))
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($duplicateFieldPath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'extension JSON with duplicate fields was accepted'

        $escapedDuplicateFieldPath = Join-Path $directory 'escaped-duplicate-field.json'
        $escapedDuplicateFieldJson = '{"format":2,"id":"escaped-duplicate-field","items":[{"id":"escaped-item","\u0069d":"other-item","name":"Escaped duplicate field","provider":"manual","version":"manual-review","architecture":"x64","executionContext":"elevated","source":"manual:fixture/escaped-duplicate","checksum":"manual-review","reason":"Requires manual review"}]}'
        [IO.File]::WriteAllText($escapedDuplicateFieldPath, $escapedDuplicateFieldJson, (New-Object Text.UTF8Encoding($false)))
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($escapedDuplicateFieldPath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'extension JSON with escaped duplicate fields was accepted'

        $unknown = New-TestExtensionWingetItem -Id 'unknown-provider' -Name 'Unknown provider' -WingetId 'Contoso.UnknownProvider'
        $unknown['provider'] = 'download'
        $unknownPath = Write-TestExtensionManifest $directory 'unknown-provider' @($unknown) 'unknown-provider.json'
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($unknownPath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'unknown extension provider was accepted'

        $badSource = New-TestExtensionWingetItem -Id 'bad-source' -Name 'Bad source' -WingetId 'Contoso.BadSource'
        $badSource['source'] = 'winget:Contoso.OtherSource'
        $badSourcePath = Write-TestExtensionManifest $directory 'bad-source' @($badSource) 'bad-source.json'
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($badSourcePath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'WinGet source/ID mismatch was accepted'

        $badScope = New-TestExtensionWingetItem -Id 'bad-scope' -Name 'Bad scope' -ItemContext user -WingetId 'Contoso.BadScope'
        $badScope.install.scope = 'machine'
        $badScopePath = Write-TestExtensionManifest $directory 'bad-scope' @($badScope) 'bad-scope.json'
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($badScopePath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'user WinGet item with machine scope was accepted'

        $firstDuplicatePath = Write-TestExtensionManifest $directory 'duplicate-one' @((New-TestExtensionManualItem 'same-item' 'First duplicate')) 'duplicate-one.json'
        $secondDuplicatePath = Write-TestExtensionManifest $directory 'duplicate-two' @((New-TestExtensionManualItem 'same-item' 'Second duplicate')) 'duplicate-two.json'
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($firstDuplicatePath, $secondDuplicatePath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'duplicate extension item IDs were accepted'

        $duplicateWingetPath = Write-TestExtensionManifest $directory 'duplicate-winget' @(
            (New-TestExtensionWingetItem -Id 'first' -Name 'First package' -WingetId 'Contoso.Duplicate'),
            (New-TestExtensionWingetItem -Id 'second' -Name 'Second package' -WingetId 'Contoso.Duplicate')
        ) 'duplicate-winget.json'
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($duplicateWingetPath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'duplicate extension WinGet IDs were accepted'

        $tooManyPaths = @()
        foreach ($index in 1..17) { $tooManyPaths += (Join-Path $directory ("limit-$index.json")) }
        Assert-Test (Test-Throws { Get-BootstrapExtensionManifestPaths ([string[]]$tooManyPaths) | Out-Null }) 'more than 16 extension manifests were accepted'

        $tooManyItems = @()
        foreach ($index in 1..65) {
            $tooManyItems += New-TestExtensionManualItem ("item-$index") ("Manual $index")
        }
        $tooManyItemsPath = Write-TestExtensionManifest $directory 'too-many-items' $tooManyItems 'too-many-items.json'
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($tooManyItemsPath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'more than 64 items in an extension manifest were accepted'

        $oversizedPath = Join-Path $directory 'oversized.json'
        [IO.File]::WriteAllBytes($oversizedPath, (New-Object byte[] 262145))
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems @($oversizedPath) (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'an extension manifest over 256 KiB was accepted'

        $globalPaths = @()
        foreach ($manifestIndex in 1..5) {
            $globalItems = @()
            foreach ($itemIndex in 1..64) {
                $globalItems += New-TestExtensionManualItem ("global-$manifestIndex-$itemIndex") ("Global manual $manifestIndex-$itemIndex")
            }
            $globalPaths += Write-TestExtensionManifest $directory ("global-$manifestIndex") $globalItems ("global-$manifestIndex.json")
        }
        Assert-Test (Test-Throws { @(Get-BootstrapExtensionManifestItems $globalPaths (Join-Path $script:RepoRoot 'windows-bootstrap')) | Out-Null }) 'more than 256 total extension items were accepted'
    }

    Invoke-TestCase 'extension snapshot binds approval and rejects manifest or snapshot tampering' {
        if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
        $previousLocalAppData = $env:LOCALAPPDATA
        $localAppData = Join-Path $script:TestRoot 'extension-snapshot-localappdata'
        $directory = Join-Path $script:TestRoot 'extension-snapshot-manifest'
        New-Item -ItemType Directory -Path $localAppData -Force | Out-Null
        $env:LOCALAPPDATA = $localAppData
        try {
            $path = Write-TestExtensionManifest $directory 'snapshot-tools' @(
                (New-TestExtensionWingetItem -Id 'snapshot-cli' -Name 'Snapshot CLI' -WingetId 'Contoso.SnapshotCli'),
                (New-TestExtensionManualItem 'snapshot-manual' 'Snapshot manual')
            )
            $plan = Get-TestExtensionPlan @($path)
            $runId = [guid]::NewGuid().ToString('N')
            $snapshotPath = Write-BootstrapPackagePlanSnapshot $runId 'Extension' $plan $plan.hash
            $loaded = Read-BootstrapPackagePlanSnapshot $snapshotPath $runId 'Extension' $plan.hash @()
            Assert-Equal $loaded.hash $plan.hash 'protected snapshot did not reconstruct the approved plan'
            Assert-Test (Test-BootstrapUserPhasePathSecurity $snapshotPath (Get-BootstrapCurrentUserSid) -RequireProtectedDacl) 'snapshot DACL was not protected'

            $mutated = New-TestExtensionManualItem 'snapshot-manual' 'Snapshot manual' 'Changed raw manifest after approval'
            $ignoredManifestPath = Write-TestExtensionManifest $directory 'snapshot-tools' @(
                (New-TestExtensionWingetItem -Id 'snapshot-cli' -Name 'Snapshot CLI' -WingetId 'Contoso.SnapshotCli'),
                $mutated
            )
            $reloaded = Read-BootstrapPackagePlanSnapshot $snapshotPath $runId 'Extension' $plan.hash @()
            Assert-Equal $reloaded.hash $plan.hash 'snapshot reader reloaded a changed raw extension manifest'

            $snapshot = Read-BootstrapJson $snapshotPath
            $snapshot.plan.items[0].wingetId = 'Contoso.Tampered'
            Write-BootstrapJson $snapshotPath $snapshot
            Protect-BootstrapUserPhaseHandoff $snapshotPath (Get-BootstrapCurrentUserSid) | Out-Null
            Assert-Test (Test-Throws { Read-BootstrapPackagePlanSnapshot $snapshotPath $runId 'Extension' $plan.hash @() | Out-Null }) 'tampered snapshot was accepted'
        } finally {
            $env:LOCALAPPDATA = $previousLocalAppData
        }
    }

    Invoke-TestCase 'extension entry PlanOnly and DryRun leave no state before approval' {
        if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
        $previousLocalAppData = $env:LOCALAPPDATA
        $localAppData = Join-Path $script:TestRoot 'extension-entry-localappdata'
        $directory = Join-Path $script:TestRoot 'extension-entry-manifest'
        $planOnlyStateRoot = Join-Path $script:TestRoot 'extension-entry-planonly-state'
        $dryRunStateRoot = Join-Path $script:TestRoot 'extension-entry-dryrun-state'
        $unapprovedStateRoot = Join-Path $script:TestRoot 'extension-entry-unapproved-state'
        New-Item -ItemType Directory -Path $localAppData -Force | Out-Null
        $env:LOCALAPPDATA = $localAppData
        try {
            $path = Write-TestExtensionManifest $directory 'entry-tools' @(
                (New-TestExtensionWingetItem -Id 'entry-cli' -Name 'Entry CLI' -WingetId 'Contoso.EntryCli'),
                (New-TestExtensionManualItem 'entry-manual' 'Entry manual')
            )
            $expectedPlan = Get-TestExtensionPlan @($path)
            $planOnly = Invoke-TestBootstrapEntry @(
                '-Profile', 'Extension', '-ExtensionManifest', $path,
                '-StateRoot', $planOnlyStateRoot, '-PlanOnly'
            )
            Assert-Equal $planOnly.exitCode 0 "PlanOnly failed: $($planOnly.output)"
            $display = $planOnly.output | ConvertFrom-Json
            Assert-Equal ([string]$display.hash) ([string]$expectedPlan.hash) 'PlanOnly returned the wrong extension plan hash'
            Assert-Test (-not (Test-Path -LiteralPath $planOnlyStateRoot)) 'PlanOnly created state'

            $dryRun = Invoke-TestBootstrapEntry @(
                '-Profile', 'Extension', '-ExtensionManifest', $path,
                '-StateRoot', $dryRunStateRoot, '-DryRun', '-PassThru', '-Quiet', '-NoProgress'
            )
            Assert-Equal $dryRun.exitCode 0 "Extension DryRun failed: $($dryRun.output)"
            $report = $dryRun.output | ConvertFrom-Json
            Assert-Test ([bool]$report.dryRun) 'extension DryRun did not return a dry-run report'
            Assert-Test (@($report.results | Where-Object { $_.name -eq 'Entry CLI' -and $_.status -eq 'skipped' }).Count -eq 1) 'extension DryRun did not skip the WinGet item'
            Assert-Test (-not (Test-Path -LiteralPath $dryRunStateRoot)) 'extension DryRun created state/report/log/lock/cache'
            Assert-Test (-not (Test-Path -LiteralPath (Join-Path $localAppData 'WindowsBootstrap'))) 'extension DryRun created user-phase storage'

            $unapproved = Invoke-TestBootstrapEntry @(
                '-Profile', 'Extension', '-ExtensionManifest', $path,
                '-StateRoot', $unapprovedStateRoot, '-NoElevate', '-Quiet', '-NoProgress'
            )
            Assert-Test ($unapproved.exitCode -ne 0) 'unapproved extension execution succeeded'
            Assert-Test ($unapproved.output -match '(?i)ApprovePlan|protected BootstrapPackagePlanPath') 'unapproved extension did not fail at the approval/snapshot boundary'
            Assert-Test (-not (Test-Path -LiteralPath $unapprovedStateRoot)) 'unapproved extension created machine state before rejection'

            $invalid = New-TestExtensionWingetItem -Id 'entry-invalid' -Name 'Entry invalid' -WingetId 'Contoso.EntryInvalid'
            $invalid['installCommand'] = 'Start-Process calc.exe'
            $invalidPath = Write-TestExtensionManifest $directory 'entry-invalid' @($invalid) 'entry-invalid.json'
            $invalidStateRoot = Join-Path $script:TestRoot 'extension-entry-invalid-state'
            $invalidResult = Invoke-TestBootstrapEntry @(
                '-Profile', 'Extension', '-ExtensionManifest', $invalidPath,
                '-StateRoot', $invalidStateRoot, '-DryRun', '-PassThru', '-Quiet', '-NoProgress'
            )
            Assert-Test ($invalidResult.exitCode -ne 0) 'invalid extension schema succeeded through the entrypoint'
            Assert-Test ($invalidResult.output -match '(?i)unsupported field|installCommand') 'invalid extension schema did not fail at parsing'
            Assert-Test (-not (Test-Path -LiteralPath $invalidStateRoot)) 'invalid extension schema created machine state before rejection'
        } finally {
            $env:LOCALAPPDATA = $previousLocalAppData
        }
    }

    Invoke-TestCase 'persisted Extension Verify and Cleanup use protected provenance' {
        if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
        $previousLocalAppData = $env:LOCALAPPDATA
        $localAppData = Join-Path $script:TestRoot 'extension-persisted-localappdata'
        $directory = Join-Path $script:TestRoot 'extension-persisted-manifest'
        $stateRoot = Join-Path $script:TestRoot 'extension-persisted-state'
        New-Item -ItemType Directory -Path $localAppData, $stateRoot -Force | Out-Null
        $env:LOCALAPPDATA = $localAppData
        try {
            $path = Write-TestExtensionManifest $directory 'persisted-tools' @(
                (New-TestExtensionManualItem 'persisted-manual' 'Persisted manual')
            )
            $plan = Get-TestExtensionPlan @($path)
            $runId = [guid]::NewGuid().ToString('N')
            $snapshotPath = Write-BootstrapPackagePlanSnapshot $runId 'Extension' $plan $plan.hash
            $state = New-BootstrapState $stateRoot $runId 'Extension' $false
            $state.packagePlan = Get-BootstrapPackagePlanRecord $plan
            $state.packagePlan.snapshotPath = $snapshotPath
            $statePath = Join-Path $stateRoot 'state.json'
            Write-BootstrapJson $statePath $state
            $stateHash = Get-BootstrapFileSha256 $statePath

            $verify = Invoke-TestBootstrapEntry @(
                '-Verify', '-DryRun', '-StateRoot', $stateRoot,
                '-PassThru', '-Quiet', '-NoProgress'
            )
            Assert-Equal $verify.exitCode 0 "persisted Extension Verify dry-run failed: $($verify.output)"
            $verifyReport = $verify.output | ConvertFrom-Json
            Assert-Equal ([string]$verifyReport.profile) 'Extension' 'Verify did not derive Extension profile from persisted state'
            Assert-Test ([bool]$verifyReport.dryRun) 'Verify did not remain dry-run'

            $cleanup = Invoke-TestBootstrapEntry @(
                '-CleanupFailed', '-DryRun', '-StateRoot', $stateRoot,
                '-PassThru', '-Quiet', '-NoProgress'
            )
            Assert-Equal $cleanup.exitCode 0 "persisted Extension Cleanup dry-run failed: $($cleanup.output)"
            $cleanupReport = $cleanup.output | ConvertFrom-Json
            Assert-Equal ([string]$cleanupReport.profile) 'Extension' 'Cleanup did not derive Extension profile from persisted state'
            Assert-Test ([bool]$cleanupReport.dryRun) 'Cleanup did not remain dry-run'
            Assert-Equal (Get-BootstrapFileSha256 $statePath) $stateHash 'persisted Extension dry-run mutated state'
            Assert-Test (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'report.json'))) 'persisted Extension dry-run created a report'
            Assert-Test (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'bootstrap.lock'))) 'persisted Extension dry-run created a lock'

            $substituted = Invoke-TestBootstrapEntry @(
                '-Verify', '-DryRun', '-StateRoot', $stateRoot,
                '-BootstrapPackagePlanPath', (Join-Path $localAppData 'other-plan.json'),
                '-PassThru', '-Quiet', '-NoProgress'
            )
            Assert-Test ($substituted.exitCode -ne 0) 'persisted Extension Verify accepted a substituted snapshot path'
            Assert-Test ($substituted.output -match '(?i)snapshot path does not match persisted\s+state') "substituted snapshot path failed for the wrong reason: $($substituted.output)"
            Assert-Equal (Get-BootstrapFileSha256 $statePath) $stateHash 'substituted persisted Verify mutated state'

            $rawResume = Invoke-TestBootstrapEntry @(
                '-Resume', '-DryRun', '-StateRoot', $stateRoot,
                '-ExtensionManifest', $path, '-PassThru', '-Quiet', '-NoProgress'
            )
            Assert-Test ($rawResume.exitCode -ne 0) 'Resume accepted a raw ExtensionManifest'
            Assert-Test ($rawResume.output -match '(?i)only Run, PlanOnly, and DryRun may read ExtensionManifest') 'raw Resume failed for the wrong provenance boundary'
            Assert-Equal (Get-BootstrapFileSha256 $statePath) $stateHash 'raw Resume mutated state'
        } finally {
            $env:LOCALAPPDATA = $previousLocalAppData
        }
    }

    Invoke-TestCase 'extension plan canonical hash preserves arrays and manifest order' {
        $singleArray = [pscustomobject]@{ items = @('one') }
        Assert-Equal (ConvertTo-BootstrapCanonicalJsonText $singleArray) '{"items":["one"]}' 'canonical JSON collapsed a singleton array'
        Assert-Test ((Get-BootstrapCanonicalValueSha256 $singleArray) -ne (Get-BootstrapCanonicalValueSha256 ([pscustomobject]@{ items = 'one' }))) 'canonical hash did not distinguish scalar from singleton array'
        $left = [pscustomobject][ordered]@{ z = 2; a = 1 }
        $right = [pscustomobject][ordered]@{ a = 1; z = 2 }
        Assert-Equal (Get-BootstrapCanonicalValueSha256 $left) (Get-BootstrapCanonicalValueSha256 $right) 'canonical object hash depends on property insertion order'

        $directory = Join-Path $script:TestRoot 'extension-order'
        $zetaPath = Write-TestExtensionManifest $directory 'zeta' @((New-TestExtensionManualItem 'manual-z' 'Zeta manual')) 'zeta.json'
        $alphaPath = Write-TestExtensionManifest $directory 'alpha' @((New-TestExtensionManualItem 'manual-a' 'Alpha manual')) 'alpha.json'
        $first = Get-TestExtensionPlan @($zetaPath, $alphaPath)
        $second = Get-TestExtensionPlan @($alphaPath, $zetaPath)
        Assert-Equal $first.hash $second.hash 'package-plan hash depends on ExtensionManifest argument order'
        Assert-Equal ([string]$first.extensionManifests[0].id) 'alpha' 'extension manifests were not ordinal-sorted'
    }

    Invoke-TestCase 'winget installed-list matching tolerates exact-query misses' {
        $row = "PyCharm 2026.1.1 JetBrains.PyCharm 2026.1.1 2026.2.3 winget"
        Assert-Test (Test-BootstrapWingetListOutput $row 'JetBrains.PyCharm') 'installed row with the exact id token was not matched'
        Assert-Test (-not (Test-BootstrapWingetListOutput "PyCharm Community JetBrains.PyCharm.Community 1.0 winget" 'JetBrains.PyCharm')) 'prefix-colliding id was accepted'
        Assert-Test (-not (Test-BootstrapWingetListOutput 'No installed package found matching input criteria.' 'JetBrains.PyCharm')) 'not-found text was accepted as an installed row'
        Assert-Test (-not (Test-BootstrapWingetListOutput '' 'JetBrains.PyCharm')) 'empty output was accepted'
        Assert-Test (-not (Test-BootstrapWingetListOutput $row '')) 'empty id was accepted'
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

    Invoke-TestCase 'step progress lines report counter, status, and duration' {
        $started = Format-BootstrapStepLine 3 14 'Mint RIME' '' 0
        Assert-Test ($started -match '^\[3/14\] Mint RIME \.\.\.$') "unexpected start line: $started"
        $finished = Format-BootstrapStepLine 3 14 'Mint RIME' 'completed' 12.34
        Assert-Test ($finished -match '^\[3/14\] Mint RIME - completed \(12\.\ds\)$') "unexpected finish line: $finished"
    }

    Invoke-TestCase 'context report records the per-run log path' {
        $context = New-TestContext 'log-path'
        Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$context.Report.logPath)) 'report logPath missing'
        Assert-Equal ([string]$context.Report.logPath) ([string]$context.LogPath) 'report logPath does not match the context log'
        $constructedRoot = Join-Path $script:TestRoot 'constructed-log-path'
        $constructed = New-BootstrapContext $constructedRoot 'Core' $false 'Run' $script:RepoRoot
        Assert-Equal ([string](Get-BootstrapObjectProperty $constructed.Report 'logPath')) ([string]$constructed.LogPath) 'constructed report logPath does not match the context log'
    }

    Invoke-TestCase 'external output streams into the log file' {
        if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
            $log = Join-Path $script:TestRoot 'stream.log'
            $result = Invoke-BootstrapExternal 'powershell.exe' @('-NoProfile', '-Command', '1..3 | ForEach-Object { ''line'' + $_; Start-Sleep -Milliseconds 150 }') -TimeoutSeconds 60 -LogPath $log
            Assert-Test ($result.ExitCode -eq 0) "streaming run exit code was $($result.ExitCode)"
            $text = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
            Assert-Test ($text -match 'line1' -and $text -match 'line3') 'streamed log is missing child output'
            Assert-Test ($result.Output -match 'line3') 'captured output is missing child output'
        }
    }

    Invoke-TestCase 'install policy prefers a fixed secondary drive with enough free space' {
        Assert-Test (Test-BootstrapPreferSecondaryDrive 3 214748364800 10737418240) 'fixed drive with space should be preferred'
        Assert-Test (-not (Test-BootstrapPreferSecondaryDrive 2 214748364800 10737418240)) 'removable drive must not be preferred'
        Assert-Test (-not (Test-BootstrapPreferSecondaryDrive 3 1073741824 10737418240)) 'low-space drive must not be preferred'
    }

    Invoke-TestCase 'install location follows the drive policy' {
        $item = [pscustomobject]@{ installLocation = 'D:\Program Files\Git'; locationSupport = 'inno' }
        $prefer = [pscustomobject]@{ preferSecondaryDrive = $true }
        $fallback = [pscustomobject]@{ preferSecondaryDrive = $false }
        Assert-Equal (Get-BootstrapItemInstallLocation $item ([pscustomobject]@{ InstallPolicy = $prefer })) 'D:\Program Files\Git' 'preferred location mismatch'
        $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { 'C:' } else { $env:SystemDrive }
        Assert-Equal (Get-BootstrapItemInstallLocation $item ([pscustomobject]@{ InstallPolicy = $fallback })) ($systemDrive + '\Program Files\Git') 'fallback location mismatch'
        $none = [pscustomobject]@{ installLocation = 'D:\Program Files\Git'; locationSupport = 'none' }
        Assert-Equal (Get-BootstrapItemInstallLocation $none ([pscustomobject]@{ InstallPolicy = $prefer })) '' 'locationSupport none must disable --location'
    }

    Invoke-TestCase 'Git manifest carries a location preference' {
        $items = @(Get-BootstrapManifestItems (Join-Path $script:RepoRoot 'windows-bootstrap\packages') @('base.json'))
        $git = @($items | Where-Object { $_.name -eq 'Git' })[0]
        Assert-Equal ([string]$git.installLocation) 'D:\Program Files\Git' 'Git installLocation missing'
        Assert-Equal ([string]$git.locationProbe) 'cmd\git.exe' 'Git locationProbe missing'
        Assert-Equal ([string]$git.locationSupport) 'inno' 'Git locationSupport missing'
        Assert-Test ($git.silentInstallArgs -contains '--scope') 'Git --scope missing'
        Assert-Test ($git.silentInstallArgs -contains 'machine') 'Git machine scope value missing'
    }

    Invoke-TestCase 'VS Code manifest carries a D: location preference' {
        $items = @(Get-BootstrapManifestItems (Join-Path $script:RepoRoot 'windows-bootstrap\packages') @('optional.json'))
        $code = @($items | Where-Object { $_.name -eq 'Visual Studio Code' })[0]
        Assert-Equal ([string]$code.wingetId) 'Microsoft.VisualStudioCode' 'VS Code winget ID missing'
        Assert-Equal ([string]$code.installLocation) 'D:\Program Files\Microsoft VS Code' 'VS Code installLocation missing'
        Assert-Equal ([string]$code.locationProbe) 'Code.exe' 'VS Code locationProbe missing'
        Assert-Test ($code.silentInstallArgs -contains '--scope') 'VS Code --scope missing'
        Assert-Test ($code.silentInstallArgs -contains 'machine') 'VS Code machine scope value missing'
    }

    Invoke-TestCase 'PyCharm manifest carries a D: location preference' {
        $items = @(Get-BootstrapManifestItems (Join-Path $script:RepoRoot 'windows-bootstrap\packages') @('optional.json'))
        $pycharm = @($items | Where-Object { $_.name -eq 'PyCharm Community Edition' })[0]
        Assert-Equal ([string]$pycharm.wingetId) 'JetBrains.PyCharm.Community' 'PyCharm winget ID missing'
        Assert-Equal ([string]$pycharm.installLocation) 'D:\Program Files\JetBrains\PyCharm Community Edition' 'PyCharm installLocation missing'
        Assert-Equal ([string]$pycharm.locationProbe) 'bin\pycharm64.exe' 'PyCharm locationProbe missing'
        Assert-Equal ([string]$pycharm.locationSupport) 'nsis' 'PyCharm locationSupport missing'
        Assert-Test ($pycharm.silentInstallArgs -contains '--scope') 'PyCharm --scope missing'
        Assert-Test ($pycharm.silentInstallArgs -contains 'machine') 'PyCharm machine scope value missing'
    }

    Invoke-TestCase 'requested Windows software contracts are present' {
        $items = @(Get-BootstrapManifestItems (Join-Path $script:RepoRoot 'windows-bootstrap\packages') @('optional.json'))
        foreach ($id in @('Mozilla.Firefox', 'Microsoft.Edge', 'Google.Chrome', 'Python.Python.3.14', '7zip.7zip', 'zufuliu.notepad4', 'SumatraPDF.SumatraPDF', 'LiErHeXun.Quicker', 'PixPin.PixPin', 'Daum.PotPlayer', 'Spotify.Spotify')) {
            Assert-Test (@($items | Where-Object { [string](Get-BootstrapObjectProperty $_ 'wingetId') -eq $id }).Count -eq 1) "requested package missing: $id"
        }
        $spotify = @($items | Where-Object { [string](Get-BootstrapObjectProperty $_ 'wingetId') -eq 'Spotify.Spotify' })[0]
        Assert-Equal ([string]$spotify.mode) 'winget' 'Spotify must use WinGet in the normal-user phase'
        Assert-Equal (Get-BootstrapItemExecutionContext $spotify) 'user' 'Spotify execution context must be user'
        Assert-Test (Test-BootstrapWinGetUserScope -InstallArguments @($spotify.silentInstallArgs)) 'Spotify must have an ordered --scope user contract'
        Assert-Test (-not (Test-BootstrapWinGetUserScope -InstallArguments @('--scope', 'machine', 'user'))) 'misordered/machine WinGet scope was accepted'
        $potPlayer = @($items | Where-Object { [string](Get-BootstrapObjectProperty $_ 'wingetId') -eq 'Daum.PotPlayer' })[0]
        Assert-Equal ([string]$potPlayer.mode) 'portable-handoff' 'PotPlayer must use controlled PortableApps handoff'
        Assert-Equal (Get-BootstrapItemExecutionContext $potPlayer) 'user' 'PotPlayer execution context must be user'
        Assert-Equal ([string]$potPlayer.checksum) 'sha256:9c6b0364be94af7bbd117dd05df7485dfd965ee8785e44af6a0129c745f21913' 'PotPlayer PortableApps hash changed'
        Assert-Equal ([string]$potPlayer.verification.launcher) 'PotPlayerPortable.exe' 'PotPlayer launcher contract missing'
        Assert-Equal ([string]$potPlayer.verification.coreExecutable) 'App\PotPlayer\PotPlayerMini64.exe' 'PotPlayer core executable contract missing'
    }

    Invoke-TestCase 'portable and executable location metadata are accepted' {
        $items = @(Get-BootstrapManifestItems (Join-Path $script:RepoRoot 'windows-bootstrap\packages') @('optional.json'))
        $notepad = @($items | Where-Object { $_.name -eq 'Notepad4' })[0]
        $sumatra = @($items | Where-Object { $_.name -eq 'SumatraPDF' })[0]
        Assert-Equal ([string]$notepad.locationSupport) 'portable' 'Notepad4 portable locationSupport missing'
        Assert-Equal ([string]$sumatra.locationSupport) 'exe' 'SumatraPDF executable locationSupport missing'
        Assert-Equal ([string]$notepad.homepage) 'https://github.com/zufuliu/notepad4' 'Notepad4 upstream missing'
        Assert-Equal ([string]$sumatra.homepage) 'https://github.com/sumatrapdfreader/sumatrapdf' 'SumatraPDF upstream missing'
    }

    Invoke-TestCase 'user execution and portable handoff contracts are constrained' {
        $directory = Join-Path $script:TestRoot 'user-context-contract'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $item = [ordered]@{
            name = 'Broken user WinGet package'
            mode = 'winget'
            wingetId = 'Broken.User.Package'
            version = '1.0'
            architecture = 'x64'
            executionContext = 'user'
            silentInstallArgs = @('--silent')
            uninstallCommand = [ordered]@{ type = 'winget'; args = @() }
            source = 'winget:Broken.User.Package'
            checksum = 'winget-source-signed'
            verification = [ordered]@{ type = 'winget-list'; command = 'Broken.User.Package' }
        }
        Write-BootstrapJson (Join-Path $directory 'user.json') ([ordered]@{ format = 1; items = @($item) })
        $missingScope = $false
        try { @(Get-BootstrapManifestItems $directory @('user.json')) | Out-Null } catch { $missingScope = $true }
        Assert-Test $missingScope 'user-context WinGet item without --scope user was accepted'
        $item.mode = 'portable-handoff'
        $item.wingetId = 'Broken.Portable'
        $item.silentInstallArgs = @()
        $item.uninstallCommand = [ordered]@{ type = 'manual'; args = @() }
        $item.url = 'https://example.com/PotPlayerPortable.paf.exe'
        $item.checksum = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $item.verification = [ordered]@{ type = 'portable-layout'; launcher = '..\unsafe.exe'; coreExecutable = 'App\PotPlayer\PotPlayerMini64.exe' }
        $item.portableDirectory = 'PotPlayerPortable'
        Write-BootstrapJson (Join-Path $directory 'user.json') ([ordered]@{ format = 1; items = @($item) })
        $unsafeLayout = $false
        try { @(Get-BootstrapManifestItems $directory @('user.json')) | Out-Null } catch { $unsafeLayout = $true }
        Assert-Test $unsafeLayout 'portable handoff with traversal layout was accepted'
    }

    Invoke-TestCase 'manual items require a reason and location type is constrained' {
        $directory = Join-Path $script:TestRoot 'manual-contract'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $item = [ordered]@{
            name = 'Manual package'
            mode = 'manual'
            version = 'manual-review'
            architecture = 'x64'
            silentInstallArgs = @()
            uninstallCommand = [ordered]@{ type = 'manual'; args = @() }
            source = 'manual:test'
            checksum = 'manual-review'
            verification = [ordered]@{ type = 'manual' }
            cleanupMode = 'manual'
        }
        Write-BootstrapJson (Join-Path $directory 'manual.json') ([ordered]@{ format = 1; items = @($item) })
        $missingReason = $false
        try { @(Get-BootstrapManifestItems $directory @('manual.json')) | Out-Null } catch { $missingReason = $true }
        Assert-Test $missingReason 'manual item without a reason was accepted'
        $item.reason = 'Requires an interactive session'
        $item.locationSupport = 'unknown-installer'
        Write-BootstrapJson (Join-Path $directory 'manual.json') ([ordered]@{ format = 1; items = @($item) })
        $unknownLocation = $false
        try { @(Get-BootstrapManifestItems $directory @('manual.json')) | Out-Null } catch { $unknownLocation = $true }
        Assert-Test $unknownLocation 'unsupported install location type was accepted'
    }

    Invoke-TestCase 'user phase handoff rejects stale, foreign, and extra results' {
        $runId = '0123456789abcdef0123456789abcdef'
        $items = @([pscustomobject]@{ name = 'Spotify'; mode = 'winget'; wingetId = 'Spotify.Spotify'; executionContext = 'user' })
        $handoff = [pscustomobject]@{
            format = 1
            kind = 'windows-bootstrap-user-phase'
            runId = $runId
            ownerSid = 'S-1-5-21-1-2-3-1001'
            createdAt = [DateTime]::UtcNow.ToString('o')
            profile = 'Optional'
            host = [pscustomobject]@{ UserSid = 'S-1-5-21-1-2-3-1001'; IsAdministrator = $false; SessionId = 1; IntegritySid = 'S-1-16-8192' }
            manifestFingerprint = Get-BootstrapUserPhaseManifestFingerprint $items
            results = @([pscustomobject]@{ name = 'Spotify'; mode = 'winget'; executionContext = 'user'; wingetId = 'Spotify.Spotify'; status = 'completed' })
        }
        Assert-Test (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items 'Optional').valid 'valid user phase handoff was rejected'
        Assert-Equal ([string](Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items 'Optional').host.IntegritySid) 'S-1-16-8192' 'valid handoff did not retain normal-user host metadata'
        $handoff.profile = 'Core'
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items 'Optional').valid) 'cross-profile user phase handoff was accepted'
        $handoff.profile = 'Optional'
        $handoff.host.IntegritySid = 'S-1-16-12288'
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items).valid) 'elevated normal-user handoff was accepted'
        $handoff.host.IntegritySid = 'S-1-16-8192'
        $handoff.host.SessionId = 0
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items).valid) 'session-zero normal-user handoff was accepted'
        $handoff.host.SessionId = 1
        $handoff.results[0].executionContext = 'elevated'
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items 'Optional').valid) 'wrong user phase execution context was accepted'
        $handoff.results[0].executionContext = 'user'
        $handoff.ownerSid = 'S-1-5-21-foreign'
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items).valid) 'foreign user phase handoff was accepted'
        $handoff.ownerSid = 'S-1-5-21-1-2-3-1001'
        $handoff.createdAt = [DateTime]::UtcNow.AddHours(-25).ToString('o')
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items).valid) 'stale user phase handoff was accepted'
        $handoff.createdAt = [DateTime]::UtcNow.ToString('o')
        $handoff.manifestFingerprint = ('a' * 64)
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items).valid) 'user phase handoff with foreign manifest fingerprint was accepted'
        $handoff.manifestFingerprint = Get-BootstrapUserPhaseManifestFingerprint $items
        $expandedItems = @($items) + [pscustomobject]@{ name = 'Machine item'; mode = 'winget'; wingetId = 'Machine.Package'; executionContext = 'elevated' }
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $expandedItems).valid) 'user phase handoff was accepted after machine-phase manifest changed'
        $handoff.results = @($handoff.results) + [pscustomobject]@{ name = 'Injected'; mode = 'winget'; wingetId = 'Injected.Package'; status = 'completed' }
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId 'S-1-5-21-1-2-3-1001' $items).valid) 'user phase handoff with injected item was accepted'
    }

    Invoke-TestCase 'extension user-phase handoff binds the protected package plan hash' {
        $runId = '0123456789abcdef0123456789abcdef'
        $ownerSid = 'S-1-5-21-1-2-3-1001'
        $planHash = (('c' * 64) -join '')
        $items = @([pscustomobject]@{
            id = 'extension-tools/user-cli'
            name = 'Extension user CLI'
            mode = 'winget'
            provider = 'winget'
            wingetId = 'Contoso.ExtensionUserCli'
            executionContext = 'user'
            extensionManifest = 'C:\\fixture\\tools.json'
        })
        $handoff = [pscustomobject]@{
            format = 1
            kind = 'windows-bootstrap-user-phase'
            runId = $runId
            ownerSid = $ownerSid
            createdAt = [DateTime]::UtcNow.ToString('o')
            profile = 'Extension'
            host = [pscustomobject]@{ UserSid = $ownerSid; IsAdministrator = $false; SessionId = 1; IntegritySid = 'S-1-16-8192' }
            manifestFingerprint = Get-BootstrapUserPhaseManifestFingerprint $items
            packagePlanHash = $planHash
            results = @([pscustomobject]@{
                name = 'Extension user CLI'
                mode = 'winget'
                executionContext = 'user'
                wingetId = 'Contoso.ExtensionUserCli'
                status = 'completed'
            })
        }
        Assert-Test (Test-BootstrapUserPhaseHandoffData $handoff $runId $ownerSid $items 'Extension' $planHash).valid 'extension handoff with matching plan hash was rejected'
        $handoff.packagePlanHash = (('d' * 64) -join '')
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId $ownerSid $items 'Extension' $planHash).valid) 'extension handoff with a changed plan hash was accepted'
        $handoff.PSObject.Properties.Remove('packagePlanHash')
        Assert-Test (-not (Test-BootstrapUserPhaseHandoffData $handoff $runId $ownerSid $items 'Extension' $planHash).valid) 'extension handoff without a plan hash was accepted'
    }

    Invoke-TestCase 'run IDs are constrained and survive explicit context construction' {
        Assert-Test (Test-BootstrapRunId '0123456789abcdef0123456789abcdef') 'valid run ID rejected'
        Assert-Test (-not (Test-BootstrapRunId '../bad')) 'unsafe run ID accepted'
        $root = Join-Path $script:TestRoot 'explicit-run-id'
        $context = New-BootstrapContext $root 'Core' $true 'Run' $script:RepoRoot -RunId '0123456789abcdef0123456789abcdef'
        Assert-Equal $context.RunId '0123456789abcdef0123456789abcdef' 'explicit run ID was not retained'
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
        $bound.BootstrapRunId = '0123456789abcdef0123456789abcdef'
        $bound.BootstrapUserPhaseHandoff = [System.Management.Automation.SwitchParameter]::new($true)
        $arguments = @(Get-BootstrapElevatedArguments 'D:\repo\windows-bootstrap\install.ps1' $bound)
        Assert-Test ($arguments -contains '-BootstrapRunId') 'user-phase run ID name missing'
        Assert-Test ($arguments -contains '"0123456789abcdef0123456789abcdef"') 'user-phase run ID value missing'
        Assert-Test ($arguments -contains '-BootstrapUserPhaseHandoff') 'user-phase handoff marker missing'
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

    Invoke-TestCase 'UAC child and Extension resume only carry protected plan provenance' {
        $approval = (('a' * 64) -join '')
        $bound = @{
            Profile = 'Extension'
            ExtensionManifest = @('C:\users\owner\tools.json')
            PlanOnly = [System.Management.Automation.SwitchParameter]::new($true)
            BootstrapPackagePlanPath = 'C:\attacker\plan.json'
            ApprovePlan = 'b' * 64
            StateRoot = 'C:\state'
        }
        $child = Get-BootstrapElevatedChildParameters $bound 'C:\Users\owner\AppData\Local\WindowsBootstrap\UserPhase\0123456789abcdef0123456789abcdef\package-plan.json' $approval
        Assert-Test (-not $child.ContainsKey('ExtensionManifest')) 'UAC child retained raw ExtensionManifest'
        Assert-Test (-not $child.ContainsKey('PlanOnly')) 'UAC child retained PlanOnly'
        Assert-Equal ([string]$child.BootstrapPackagePlanPath) 'C:\Users\owner\AppData\Local\WindowsBootstrap\UserPhase\0123456789abcdef0123456789abcdef\package-plan.json' 'UAC child snapshot path was not replaced'
        Assert-Equal ([string]$child.ApprovePlan) $approval 'UAC child approval was not replaced'

        $context = New-TestContext 'extension-resume-options'
        $context.State.profile = 'Extension'
        $context.State.packagePlan = [ordered]@{
            hash = $approval
            snapshotPath = 'C:\Users\owner\AppData\Local\WindowsBootstrap\UserPhase\0123456789abcdef0123456789abcdef\package-plan.json'
        }
        $context.State.executionOptions = [ordered]@{
            bootstrapPackagePlanPath = 'C:\attacker\plan.json'
            approvedPlan = (('b' * 64) -join '')
        }
        $arguments = Get-BootstrapResumeArguments $context 'C:\repo\windows-bootstrap\install.ps1'
        Assert-Test ($arguments -match [regex]::Escape($context.State.packagePlan.snapshotPath)) 'Resume did not use state snapshot path'
        Assert-Test ($arguments -match $approval) 'Resume did not use state approval hash'
        Assert-Test ($arguments -notmatch 'C:\\attacker\\plan\.json') 'Resume used mutable executionOptions snapshot path'
        Assert-Test (Test-Throws { Get-BootstrapExtensionResumePlanReference $context.State 'C:\other\plan.json' $approval | Out-Null }) 'Resume accepted substituted snapshot path'
        Assert-Test (Test-Throws { Get-BootstrapExtensionResumePlanReference $context.State $context.State.packagePlan.snapshotPath (('b' * 64) -join '') | Out-Null }) 'Resume accepted substituted approval hash'
    }

    Invoke-TestCase 'persisted Extension state rejects missing or substituted provenance' {
        $approval = (('e' * 64) -join '')
        $state = New-BootstrapState 'C:\state' '0123456789abcdef0123456789abcdef' 'Extension' $false
        $state.packagePlan = [ordered]@{
            hash = $approval
            snapshotPath = 'C:\Users\owner\AppData\Local\WindowsBootstrap\UserPhase\0123456789abcdef0123456789abcdef\package-plan.json'
        }
        $reference = Get-BootstrapExtensionResumePlanReference $state
        Assert-Equal ([string]$reference.approvePlan) $approval 'persisted Extension approval hash changed'
        Assert-Test (Test-Throws { Get-BootstrapExtensionResumePlanReference $state 'C:\other\package-plan.json' '' | Out-Null }) 'persisted Extension state accepted a substituted path'
        $state.packagePlan = [ordered]@{ hash = $approval }
        Assert-Test (Test-Throws { Get-BootstrapExtensionResumePlanReference $state | Out-Null }) 'persisted Extension state accepted a missing snapshot path'
        $state.packagePlan = [ordered]@{
            hash = 'not-a-sha256'
            snapshotPath = 'C:\Users\owner\AppData\Local\WindowsBootstrap\UserPhase\0123456789abcdef0123456789abcdef\package-plan.json'
        }
        Assert-Test (Test-Throws { Get-BootstrapExtensionResumePlanReference $state | Out-Null }) 'persisted Extension state accepted an invalid approval hash'
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
    exit 0
} finally {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
