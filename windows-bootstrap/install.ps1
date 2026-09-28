#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Base', 'Core', 'Optional', 'All')]
    [string]$Profile = 'All',
    [string]$StateRoot,
    [switch]$Resume,
    [switch]$Verify,
    [switch]$Report,
    [switch]$CleanupFailed,
    [switch]$DryRun,
    [switch]$NoReboot,
    [switch]$SkipRime,
    [switch]$NoOptional,
    [switch]$NoNetworkCheck,
    [switch]$PassThru,
    [switch]$Force,
    [switch]$NoElevate,
    [switch]$Quiet,
    [switch]$NoProgress,
    [string]$PortableAppsRoot,
    [switch]$LaunchPortableHandoff,
    [switch]$ConfirmPortableHandoff,
    [string]$BootstrapRunId,
    [switch]$BootstrapUserPhaseHandoff
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BootstrapRoot = $PSScriptRoot
$script:RepositoryRoot = Split-Path -Parent $script:BootstrapRoot
$script:LibraryPath = Join-Path $script:BootstrapRoot 'lib\Bootstrap.Core.ps1'
. $script:LibraryPath

function Get-BootstrapComponentFiles([string]$SelectedProfile, [bool]$IncludeOptional) {
    switch ($SelectedProfile) {
        'Base' { return @('base.json') }
        'Core' { return @('base.json', 'core.json') }
        'Optional' { return @('optional.json') }
        default {
            $files = @('base.json', 'core.json')
            if ($IncludeOptional) { $files += 'optional.json' }
            return $files
        }
    }
}

function Test-BootstrapNetwork([bool]$DryRun = $false) {
    if ($DryRun) { return [pscustomobject]@{ available = $false; detail = 'dry-run: network probe skipped' } }
    try {
        $client = New-Object Net.NetworkInformation.Ping
        $reply = $client.Send('github.com', 2500)
        return [pscustomobject]@{ available = ($reply.Status -eq 'Success'); detail = [string]$reply.Status }
    } catch {
        return [pscustomobject]@{ available = $false; detail = $_.Exception.Message }
    }
}

function Add-BootstrapVerificationResult($Context) {
    if ($Context.DryRun) {
        return Add-BootstrapResult $Context 'final-verification' 'core' 'skipped' 'Dry run: final verification not executed' $null
    }
    $checks = Get-BootstrapVerification $Context
    $bad = @($checks | Where-Object { -not $_.ok })
    $status = if ($bad.Count -eq 0) { 'completed' } else { 'manual_required' }
    $message = if ($bad.Count -eq 0) { 'All requested verification checks passed' } else { "Verification gaps: $($bad.name -join ', ')" }
    return Add-BootstrapResult $Context 'final-verification' 'core' $status $message $checks
}

function Get-BootstrapOperation {
    $requested = @()
    if ($Resume) { $requested += 'Resume' }
    if ($Verify) { $requested += 'Verify' }
    if ($Report) { $requested += 'Report' }
    if ($CleanupFailed) { $requested += 'Cleanup' }
    if ($requested.Count -gt 1) {
        throw "Choose only one operation switch: $($requested -join ', ')"
    }
    if ($requested.Count -eq 1) { return $requested[0] }
    return 'Run'
}

function Get-BootstrapUserPhasePlan([string]$Operation) {
    if ($Operation -notin @('Run', 'Resume')) { throw "User phase is not valid for operation: $Operation" }
    $mainStateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-BootstrapDefaultStateRoot } else { [IO.Path]::GetFullPath($StateRoot) }
    $statePath = Join-Path $mainStateRoot 'state.json'
    $existingState = Read-BootstrapJson $statePath
    $selected = if ($NoOptional -and $Profile -eq 'All') { 'Core' } else { $Profile }
    $effectiveNoOptional = [bool]$NoOptional
    $runId = $BootstrapRunId
    if (-not [string]::IsNullOrWhiteSpace($runId) -and -not (Test-BootstrapRunId $runId)) {
        throw "Invalid Windows bootstrap run ID: $runId"
    }
    if ($Operation -eq 'Run') {
        if ($null -ne $existingState) {
            $existingState = Ensure-BootstrapStateShape $existingState
            if ([string]$existingState.phase -ne 'completed' -and -not $Force) {
                throw "Previous Windows bootstrap run is unfinished ($($existingState.phase)); use -Resume or inspect -Report before starting a new run"
            }
        }
    } else {
        if ($null -eq $existingState) { throw "No prior Windows bootstrap state found: $statePath" }
        $existingState = Ensure-BootstrapStateShape $existingState
        $storedRunId = [string]$existingState.runId
        if (-not (Test-BootstrapRunId $storedRunId)) { throw "Prior Windows bootstrap state has an invalid run ID: $statePath" }
        if (-not [string]::IsNullOrWhiteSpace($runId) -and $runId -cne $storedRunId) {
            throw "Requested run ID does not match prior Windows bootstrap state: $statePath"
        }
        if ([bool]$existingState.dryRun) { throw 'Dry-run state has no resumable work; start a normal run instead' }
        if ([string]$existingState.phase -eq 'completed' -and -not $Force) {
            throw 'Previous Windows bootstrap run is already completed; start a new run or use -Report/-Verify'
        }
        $runId = $storedRunId.ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace([string]$existingState.profile)) { $selected = [string]$existingState.profile }
        $options = Get-BootstrapObjectProperty $existingState 'executionOptions'
        if ($null -ne $options -and [bool](Get-BootstrapObjectProperty $options 'noOptional')) { $effectiveNoOptional = $true }
    }
    $files = Get-BootstrapComponentFiles $selected ($selected -eq 'All' -and -not $effectiveNoOptional)
    $items = @(Get-BootstrapManifestItems (Join-Path $script:BootstrapRoot 'packages') $files)
    if ([string]::IsNullOrWhiteSpace($runId)) { $runId = [guid]::NewGuid().ToString('N') }
    return [pscustomobject]@{
        stateRoot = $mainStateRoot
        runId = $runId.ToLowerInvariant()
        profile = $selected
        noOptional = $effectiveNoOptional
        items = $items
        userItems = @(Get-BootstrapUserPhaseItems $items)
    }
}

function Get-BootstrapUserPhaseResultRecord($Item, $Result, $Context) {
    $details = Get-BootstrapObjectProperty $Result 'details'
    $record = [ordered]@{
        name = [string]$Item.name
        mode = [string]$Item.mode
        executionContext = 'user'
        wingetId = if ([string]$Item.mode -eq 'winget') { [string]$Item.wingetId } else { '' }
        status = [string]$Result.status
        at = [DateTime]::UtcNow.ToString('o')
        details = [ordered]@{}
    }
    if ([string]$Item.mode -eq 'portable-handoff') {
        $record.details = [ordered]@{
            portableAppsRoot = [string](Get-BootstrapObjectProperty $details 'portableAppsRoot')
            userPhaseRoot = [string]$Context.StateRoot
            launcherSha256 = [string](Get-BootstrapObjectProperty $details 'launcherSha256')
            coreExecutableSha256 = [string](Get-BootstrapObjectProperty $details 'coreExecutableSha256')
        }
    }
    return [pscustomobject]$record
}

function Assert-BootstrapUserPhaseHost {
    $hostInfo = Get-BootstrapHostInfo
    if ($hostInfo.Platform -ne [PlatformID]::Win32NT) { throw 'Windows 11 is required for the normal-user bootstrap phase' }
    if (-not (Test-BootstrapWindows11 ([string]$hostInfo.ProductName) ([string]$hostInfo.Build))) {
        throw "Windows 11 build 22000 or later is required; detected $($hostInfo.ProductName) build $($hostInfo.Build)"
    }
    if (-not $hostInfo.Is64BitOS -or -not $hostInfo.Is64BitProcess) { throw '64-bit Windows and 64-bit PowerShell are required for the normal-user bootstrap phase' }
    if ($hostInfo.IsAdministrator) { throw 'Normal-user bootstrap phase cannot run from an elevated token' }
    if ([int]$hostInfo.SessionId -lt 1) { throw 'Normal-user bootstrap phase requires an interactive desktop session' }
    return $hostInfo
}

function Invoke-BootstrapUserPhase($Plan) {
    $userHost = Assert-BootstrapUserPhaseHost
    if ([string]$userHost.IntegritySid -cne 'S-1-16-8192') {
        throw "Normal-user bootstrap phase requires a medium-integrity token; detected: $($userHost.IntegritySid)"
    }
    $ownerSid = Get-BootstrapCurrentUserSid
    if ([string]$userHost.UserSid -cne $ownerSid) {
        throw 'Normal-user bootstrap host SID does not match the current user SID'
    }
    $userRoot = Ensure-BootstrapPlainDirectory (Get-BootstrapUserPhaseStateRoot ([string]$Plan.runId))
    Protect-BootstrapUserPhaseRoot $userRoot $ownerSid | Out-Null
    # A declined UAC prompt leaves normal-user work complete. A retry creates
    # a fresh handoff; WinGet's preflight remains non-destructive.
    $context = New-BootstrapContext $userRoot ([string]$Plan.profile) $false 'Run' $script:RepositoryRoot -Force:$true -Quiet:$Quiet -Silent:([bool]$PassThru) -RunId ([string]$Plan.runId)
    Enter-BootstrapLock $context
    try {
        Write-BootstrapConsole $context "Windows bootstrap user phase: $($Plan.userItems.Count) item(s)"
        $winget = Get-BootstrapCommandPath 'winget.exe'
        foreach ($item in @($Plan.userItems)) {
            $stepStarted = Get-Date
            Write-BootstrapConsole $context (Format-BootstrapStepLine 0 $Plan.userItems.Count ([string]$item.name) '' 0)
            switch ([string]$item.mode) {
                'winget' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'user' { Invoke-BootstrapWingetInstall $context $item $winget } | Out-Null
                }
                'portable-handoff' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'user' {
                        Install-BootstrapPortableHandoff $context $item $PortableAppsRoot -Launch:$LaunchPortableHandoff -Confirm:$ConfirmPortableHandoff
                    } | Out-Null
                }
                default {
                    Invoke-BootstrapStep $context ([string]$item.name) 'user' {
                        [pscustomobject]@{ status = 'manual_required'; message = "Unsupported normal-user phase mode: $($item.mode)"; details = $null }
                    } | Out-Null
                }
            }
            $result = Get-BootstrapLatestResult $context ([string]$item.name)
            Write-BootstrapConsole $context (Format-BootstrapStepLine 0 $Plan.userItems.Count ([string]$item.name) ([string]$result.status) (((Get-Date) - $stepStarted).TotalSeconds))
        }
        $records = @()
        foreach ($item in @($Plan.userItems)) {
            $result = Get-BootstrapLatestResult $context ([string]$item.name)
            if ($null -eq $result) {
                $result = [pscustomobject]@{ status = 'failed_uncleaned'; details = $null }
            }
            $records += Get-BootstrapUserPhaseResultRecord $item $result $context
        }
        $handoffPath = Get-BootstrapUserPhaseHandoffPath ([string]$Plan.runId)
        $handoff = [ordered]@{
            format = 1
            kind = 'windows-bootstrap-user-phase'
            runId = [string]$Plan.runId
            ownerSid = $ownerSid
            createdAt = [DateTime]::UtcNow.ToString('o')
            profile = [string]$Plan.profile
            host = $userHost
            manifestFingerprint = Get-BootstrapUserPhaseManifestFingerprint $Plan.items
            results = $records
        }
        Write-BootstrapJson $handoffPath $handoff
        Protect-BootstrapUserPhaseHandoff $handoffPath $ownerSid | Out-Null
        if (-not (Test-BootstrapUserPhasePathSecurity $handoffPath $ownerSid -RequireProtectedDacl)) {
            throw "User phase handoff owner or DACL does not match the required policy: $handoffPath"
        }
        $context.State.userPhase = [ordered]@{ status = 'completed'; runId = [string]$Plan.runId; ownerSid = $ownerSid; handoffPath = $handoffPath; itemCount = $records.Count; host = $userHost }
        $context.State.phase = 'completed'
        $context.State.nextPhase = 'elevated'
        Save-BootstrapContext $context
        return [pscustomobject]@{ runId = [string]$Plan.runId; ownerSid = $ownerSid; handoffPath = $handoffPath; results = $records; host = $userHost }
    } finally {
        Exit-BootstrapLock $context
    }
}

function Add-BootstrapUserPhaseResult($Context, $Item, $Record, [string]$HandoffPath) {
    $details = [ordered]@{
        executionContext = 'user'
        handoffPath = $HandoffPath
        runId = [string]$Context.RunId
    }
    $status = [string](Get-BootstrapObjectProperty $Record 'status')
    if ($status -ne 'completed') {
        return Add-BootstrapResult $Context ([string]$Item.name) 'user' $status "Normal-user phase returned $status" ([pscustomobject]$details)
    }
    if ([string]$Item.mode -eq 'winget') {
        $winget = Get-BootstrapCommandPath 'winget.exe'
        if ($null -eq $winget -or -not (Test-BootstrapWingetInstalled $winget ([string]$Item.wingetId))) {
            return Add-BootstrapResult $Context ([string]$Item.name) 'user' 'manual_required' 'Normal-user phase reported completion, but elevated live WinGet verification did not find the package' ([pscustomobject]$details)
        }
        $details.wingetId = [string]$Item.wingetId
        $details.liveVerification = 'winget-list'
        return Add-BootstrapResult $Context ([string]$Item.name) 'user' 'completed' 'Installed in normal-user phase and verified from the elevated phase' ([pscustomobject]$details)
    }
    if ([string]$Item.mode -eq 'portable-handoff') {
        $detailsFromUser = Get-BootstrapObjectProperty $Record 'details'
        $synthetic = [pscustomobject]@{ details = $detailsFromUser }
        if (-not (Test-BootstrapPortableHandoffCompletion $Context $Item $synthetic)) {
            return Add-BootstrapResult $Context ([string]$Item.name) 'user' 'manual_required' 'Normal-user phase reported PortableApps completion, but archive/layout verification did not pass in the elevated phase' ([pscustomobject]$details)
        }
        $details.portableAppsRoot = [string](Get-BootstrapObjectProperty $detailsFromUser 'portableAppsRoot')
        $details.userPhaseRoot = [string](Get-BootstrapObjectProperty $detailsFromUser 'userPhaseRoot')
        $details.launcherSha256 = [string](Get-BootstrapObjectProperty $detailsFromUser 'launcherSha256')
        $details.coreExecutableSha256 = [string](Get-BootstrapObjectProperty $detailsFromUser 'coreExecutableSha256')
        $details.liveVerification = 'portable-layout-and-hash'
        return Add-BootstrapResult $Context ([string]$Item.name) 'user' 'completed' 'Interactive PortableApps deployment confirmed and reverified from the elevated phase' ([pscustomobject]$details)
    }
    return Add-BootstrapResult $Context ([string]$Item.name) 'user' 'manual_required' "Unsupported normal-user phase mode: $($Item.mode)" ([pscustomobject]$details)
}

function Import-BootstrapUserPhaseHandoff($Context, $Items, [bool]$UserPhaseHandoffExpected) {
    $userItems = @(Get-BootstrapUserPhaseItems $Items)
    if (-not $UserPhaseHandoffExpected) {
        if ($userItems.Count -eq 0) { return }
        $reason = 'This elevated invocation did not originate from a normal-user phase'
        foreach ($item in $userItems) {
            Add-BootstrapResult $Context ([string]$item.name) 'user' 'manual_required' "Normal-user phase unavailable: $reason" @{ executionContext = 'user'; runId = $Context.RunId } | Out-Null
        }
        $Context.State.userPhase = [ordered]@{ status = 'manual_required'; runId = $Context.RunId; reason = $reason; itemCount = $userItems.Count }
        Save-BootstrapContext $Context
        return
    }
    $ownerSid = Get-BootstrapCurrentUserSid
    $handoffPath = ''
    $validation = $null
    try {
        $userRoot = Get-BootstrapUserPhaseStateRoot $Context.RunId
        if (-not (Test-Path -LiteralPath $userRoot -PathType Container)) { throw 'Normal-user phase root is missing' }
        if (-not (Test-BootstrapUserPhasePathSecurity $userRoot $ownerSid -RequireProtectedDacl)) {
            throw 'Normal-user phase root owner or DACL does not match the required policy'
        }
        $handoffPath = Get-BootstrapUserPhaseHandoffPath $Context.RunId
        Assert-BootstrapPlainExistingFile $handoffPath 'Normal-user phase handoff' | Out-Null
        if (-not (Test-BootstrapUserPhasePathSecurity $handoffPath $ownerSid -RequireProtectedDacl)) {
            throw 'Normal-user phase handoff owner or DACL does not match the required policy'
        }
        $handoff = Read-BootstrapJson $handoffPath
        # The handoff marker is provenance, not an optimization hint.
        # Validate every user item even when a live probe says it is installed.
        $validation = Test-BootstrapUserPhaseHandoffData $handoff $Context.RunId $ownerSid $Items ([string]$Context.State.profile)
        if (-not $validation.valid) { throw "Normal-user phase handoff rejected: $($validation.reason)" }
    } catch {
        $reason = $_.Exception.Message
        foreach ($item in $userItems) {
            Add-BootstrapResult $Context ([string]$item.name) 'user' 'recovery_required' "Normal-user phase handoff rejected: $reason" @{ executionContext = 'user'; runId = $Context.RunId } | Out-Null
        }
        $Context.State.userPhase = [ordered]@{ status = 'recovery_required'; runId = $Context.RunId; reason = $reason; itemCount = $userItems.Count }
        Save-BootstrapContext $Context
        throw "Normal-user phase handoff rejected; elevated package work was not started: $reason"
    }
    foreach ($item in $userItems) {
        $record = @($validation.results | Where-Object { [string]$_.name -eq [string]$item.name } | Select-Object -First 1)[0]
        Add-BootstrapUserPhaseResult $Context $item $record $handoffPath | Out-Null
    }
    $Context.State.userPhase = [ordered]@{ status = 'imported'; runId = $Context.RunId; ownerSid = $ownerSid; handoffPath = $handoffPath; itemCount = $userItems.Count; host = $validation.host }
    Save-BootstrapContext $Context
}

function Invoke-BootstrapRun {
    $selected = if ($NoOptional -and $Profile -eq 'All') { 'Core' } else { $Profile }
    $operation = Get-BootstrapOperation
    $context = New-BootstrapContext $StateRoot $selected ([bool]$DryRun) $operation $script:RepositoryRoot -Force:$Force -Quiet:$Quiet -Silent:([bool]$PassThru) -RunId $BootstrapRunId
    $selected = [string]$context.State.profile
    Write-BootstrapConsole $context ("Windows bootstrap: operation={0}, profile={1}" -f $operation, $selected)
    if (-not $context.DryRun) {
        Write-BootstrapConsole $context ("State: {0}" -f $context.StateRoot)
        Write-BootstrapConsole $context ("Log:   {0}" -f $context.LogPath)
    }
    if ($operation -eq 'Report') { return $context }

    if ($operation -in @('Run', 'Resume')) {
        $policy = Get-BootstrapInstallPolicy
        $context | Add-Member -NotePropertyName 'InstallPolicy' -NotePropertyValue $policy -Force
        $context.State.installPolicy = $policy
        $context.Report.installPolicy = $policy
        Write-BootstrapLog $context ("Install policy: preferredRoot={0}, preferSecondaryDrive={1}" -f $policy.preferredRoot, $policy.preferSecondaryDrive)
        $policyNote = if ($policy.preferSecondaryDrive) { ' (D: preferred)' } else { '' }
        Write-BootstrapConsole $context ("Install root: {0}{1}" -f $policy.preferredRoot, $policyNote)
    }

    Enter-BootstrapLock $context
    try {
        if ($operation -eq 'Verify') {
            if ($DryRun) {
                $context.Report.host = [pscustomobject]@{
                    Platform = [Environment]::OSVersion.Platform
                    ProductName = 'not queried in dry-run'
                    Build = 'not queried in dry-run'
                    Is64BitOS = [Environment]::Is64BitOperatingSystem
                    Is64BitProcess = [Environment]::Is64BitProcess
                    PowerShell = [string]$PSVersionTable.PSVersion
                    IsAdministrator = $null
                    dryRun = $true
                }
            } else {
                $context.Report.host = Get-BootstrapHostInfo
            }
            Add-BootstrapVerificationResult $context | Out-Null
            Save-BootstrapContext $context
            return $context
        }
        if ($operation -eq 'Cleanup') {
            $previousPhase = [string]$context.State.phase
            $context.State.phase = 'cleanup'
            Save-BootstrapContext $context
            try {
                $outcomes = Invoke-BootstrapCleanup $context
                $context.Report.cleanup = @($context.Report.cleanup) + $outcomes
                return $context
            } finally {
                $context.State.phase = $previousPhase
                Save-BootstrapContext $context
            }
        }

        if ($DryRun) {
            $context.Report.host = [pscustomobject]@{
                Platform = [Environment]::OSVersion.Platform
                ProductName = 'not queried in dry-run'
                Build = 'not queried in dry-run'
                Is64BitOS = [Environment]::Is64BitOperatingSystem
                Is64BitProcess = [Environment]::Is64BitProcess
                PowerShell = [string]$PSVersionTable.PSVersion
                IsAdministrator = $null
                dryRun = $true
            }
        } else {
            Assert-BootstrapHost $context | Out-Null
        }
        if ($operation -eq 'Run') {
            $context.State.executionOptions = [ordered]@{
                skipRime = [bool]$SkipRime
                noOptional = [bool]$NoOptional
                noNetworkCheck = [bool]$NoNetworkCheck
            }
        } else {
            $savedOptions = $context.State.executionOptions
            if ($null -ne $savedOptions) {
                if ([bool]$savedOptions.skipRime) { $SkipRime = $true }
                if ([bool]$savedOptions.noOptional) { $NoOptional = $true }
                if ([bool]$savedOptions.noNetworkCheck) { $NoNetworkCheck = $true }
            }
        }
        Save-BootstrapContext $context
        if ($operation -eq 'Run') {
            Invoke-BootstrapStep $context 'user-config-backup' 'preflight' { Backup-BootstrapUserFiles $context } | Out-Null
        }
        $context.State.phase = 'preflight'
        $context.State.nextPhase = 'base'
        Save-BootstrapContext $context

        if (-not $NoNetworkCheck) {
            $network = Test-BootstrapNetwork ([bool]$DryRun)
            $networkStatus = if ($network.available -or $DryRun) { 'completed' } else { 'manual_required' }
            $networkMessage = if ($network.available) {
                'Network reachable'
            } elseif ($DryRun) {
                'Dry run: network check recorded only'
            } else {
                "Network check failed: $($network.detail); cached installs may still work"
            }
            Add-BootstrapResult $context 'network' 'preflight' $networkStatus $networkMessage $network | Out-Null
        }
        if ($DryRun) {
            Add-BootstrapResult $context 'winget' 'preflight' 'skipped' 'Dry run: WinGet discovery not executed' @{ dryRun = $true } | Out-Null
            $winget = $null
        } else {
            $winget = Get-BootstrapCommandPath 'winget.exe'
            $wingetStatus = if ($null -ne $winget) { 'completed' } else { 'manual_required' }
            $wingetMessage = if ($winget) { "WinGet: $winget" } else { 'winget.exe unavailable; package items will report failure/manual_required' }
            Add-BootstrapResult $context 'winget' 'preflight' $wingetStatus $wingetMessage @{ path = $winget } | Out-Null
        }

        $manifestDirectory = Join-Path $script:BootstrapRoot 'packages'
        $items = @(Get-BootstrapManifestItems $manifestDirectory (Get-BootstrapComponentFiles $selected ($selected -eq 'All' -and -not $NoOptional)))
        $userPhaseHandoffExpected = [bool]$BootstrapUserPhaseHandoff
        if (-not $DryRun) {
            Import-BootstrapUserPhaseHandoff $context $items $userPhaseHandoffExpected
        }
        $context.State.phase = 'base'
        $itemTotal = $items.Count
        $itemIndex = 0
        $progressEnabled = -not $context.DryRun -and -not [bool]$context.Quiet -and -not [bool]$context.Silent -and -not $NoProgress -and $ProgressPreference -ne 'SilentlyContinue'
        foreach ($item in $items) {
            $itemIndex++
            if ((Get-BootstrapItemExecutionContext $item) -eq 'user') {
                if ($DryRun) {
                    Invoke-BootstrapStep $context ([string]$item.name) 'user' {
                        [pscustomobject]@{ status = 'skipped'; message = 'Dry run: normal-user phase not executed'; details = @{ executionContext = 'user'; dryRun = $true } }
                    } | Out-Null
                }
                $stepResult = Get-BootstrapLatestResult $context ([string]$item.name)
                $status = if ($null -eq $stepResult) { 'manual_required' } else { [string]$stepResult.status }
                Write-BootstrapConsole $context (Format-BootstrapStepLine $itemIndex $itemTotal ([string]$item.name) "$status (normal-user phase)" 0)
                continue
            }
            if ($operation -eq 'Resume' -and (Test-BootstrapComponentStillComplete $context $item)) {
                Write-BootstrapLog $context "Resume: verified completed component, skipping $($item.name)"
                Write-BootstrapConsole $context (Format-BootstrapStepLine $itemIndex $itemTotal ([string]$item.name) 'skipped (already complete)' 0)
                continue
            }
            if ($operation -eq 'Resume' -and ([string]$item.name -in @($context.State.completedComponents))) {
                Write-BootstrapLog $context "Resume: completion record stale; rerunning $($item.name)" 'WARN'
            }
            Write-BootstrapConsole $context (Format-BootstrapStepLine $itemIndex $itemTotal ([string]$item.name) '' 0)
            if ($progressEnabled) {
                Write-Progress -Activity 'Windows bootstrap' -Status ("[$itemIndex/$itemTotal] $($item.name)") -PercentComplete ([int](($itemIndex - 1) * 100 / [Math]::Max(1, $itemTotal)))
            }
            $stepStarted = Get-Date
            $mode = [string]$item.mode
            switch ($mode) {
                'winget' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'base' { Invoke-BootstrapWingetInstall $context $item $winget } | Out-Null
                }
                'download' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'optional' { Install-BootstrapDownloadApp $context $item } | Out-Null
                }
                'wsl' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'core' { Install-BootstrapWsl $context $PSCommandPath -NoReboot:$NoReboot } | Out-Null
                }
                'font' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'core' { Install-BootstrapFonts $context } | Out-Null
                }
                'powershell-profile' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'core' { Install-BootstrapPowerShellConfig $context } | Out-Null
                }
                'rime' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'core' { Invoke-BootstrapRime $context -SkipRime:$SkipRime } | Out-Null
                }
                'input-method' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'core' { Configure-BootstrapMintInputMethod $context } | Out-Null
                }
                'manual' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'optional' { [pscustomobject]@{ status = 'manual_required'; message = [string]$item.reason; details = $item } } | Out-Null
                }
                'portable-handoff' {
                    Invoke-BootstrapStep $context ([string]$item.name) 'optional' { [pscustomobject]@{ status = 'manual_required'; message = 'PortableApps handoff requires the normal-user phase'; details = $item } } | Out-Null
                }
                default {
                    Invoke-BootstrapStep $context ([string]$item.name) 'unknown' { [pscustomobject]@{ status = 'manual_required'; message = "Unsupported manifest mode: $mode"; details = $item } } | Out-Null
                }
            }
            Save-BootstrapContext $context
            $stepResult = Get-BootstrapLatestResult $context ([string]$item.name)
            $stepSeconds = ((Get-Date) - $stepStarted).TotalSeconds
            Write-BootstrapConsole $context (Format-BootstrapStepLine $itemIndex $itemTotal ([string]$item.name) ([string]$stepResult.status) $stepSeconds)
            if ($progressEnabled) {
                Write-Progress -Activity 'Windows bootstrap' -Status ("[$itemIndex/$itemTotal] $($item.name): $($stepResult.status)") -PercentComplete ([int]($itemIndex * 100 / [Math]::Max(1, $itemTotal)))
            }
            if ([string]$context.State.phase -eq 'awaiting-reboot') {
                if ($progressEnabled) { Write-Progress -Activity 'Windows bootstrap' -Completed }
                Save-BootstrapContext $context
                return $context
            }
        }
        if ($progressEnabled) { Write-Progress -Activity 'Windows bootstrap' -Completed }
        $context.State.phase = 'verification'
        $context.State.nextPhase = 'completed'
        Add-BootstrapVerificationResult $context | Out-Null
        if ($context.State.resumeTask) {
            Remove-BootstrapResumeTask ([string]$context.State.resumeTask)
            $context.State.resumeTask = $null
            $context.State.requiresReboot = $false
            Add-BootstrapResult $context 'resume-task-cleanup' 'recovery' 'completed' 'Resume task removed after final phase' $null | Out-Null
        }
        $context.State.phase = 'completed'
        Save-BootstrapContext $context
        return $context
    } catch {
        $context.State.phase = 'failed'
        $context.State.nextPhase = 'manual-review'
        Add-BootstrapResult $context 'bootstrap-run' 'system' 'failed_uncleaned' $_.Exception.Message $null | Out-Null
        Save-BootstrapContext $context
        throw
    } finally {
        Exit-BootstrapLock $context
    }
}

try {
    # DryRun is read-only and never elevates, even though its base operation is Run.
    $operation = Get-BootstrapOperation
    if ($DryRun) { $operation = 'DryRun' }
    $isAdministrator = Test-BootstrapAdministrator
    if (Test-BootstrapElevationRequired $isAdministrator $operation ([bool]$NoElevate)) {
        $relayStateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-BootstrapDefaultStateRoot } else { [IO.Path]::GetFullPath($StateRoot) }
        # User-scoped packages must run before UAC. An elevated process cannot
        # safely create a medium-integrity child with the original token.
        if ($operation -in @('Run', 'Resume')) {
            $plan = Get-BootstrapUserPhasePlan $operation
            if ($plan.userItems.Count -gt 0) {
                $phase = Invoke-BootstrapUserPhase $plan
                $BootstrapRunId = [string]$phase.runId
                $BootstrapUserPhaseHandoff = $true
            } else {
                $BootstrapRunId = [string]$plan.runId
            }
        }
        $hostPath = $null
        try { $hostPath = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { }
        if ([string]::IsNullOrWhiteSpace($hostPath)) { $hostPath = Join-Path $PSHOME 'powershell.exe' }
        $elevationParameters = @{}
        foreach ($name in @($PSBoundParameters.Keys)) { $elevationParameters[$name] = $PSBoundParameters[$name] }
        # Preserve parent resolution when UAC starts from a different working directory.
        $elevationParameters['StateRoot'] = $relayStateRoot
        if ($operation -in @('Run', 'Resume')) { $elevationParameters['BootstrapRunId'] = $BootstrapRunId }
        if ($BootstrapUserPhaseHandoff) {
            $elevationParameters['BootstrapUserPhaseHandoff'] = [System.Management.Automation.SwitchParameter]::new($true)
        }
        if ($PassThru) {
            # UAC starts a separate desktop process, so its stdout cannot be
            # relayed. The parent emits the persisted report after the child.
            [void]$elevationParameters.Remove('PassThru')
            $elevationParameters['Quiet'] = [System.Management.Automation.SwitchParameter]::new($true)
        }
        $elevatedArguments = @(Get-BootstrapElevatedArguments $PSCommandPath $elevationParameters)
        if (-not $PassThru) { Write-Host "Administrator privileges are required for '$operation'; requesting elevation..." }
        try {
            $elevated = Start-Process -FilePath $hostPath -Verb RunAs -ArgumentList ($elevatedArguments -join ' ') -PassThru -Wait -ErrorAction Stop
        } catch {
            Write-Error "Elevation was declined or failed after the normal-user phase: $($_.Exception.Message). Re-run from the same normal-user desktop session to retry the elevated phase."
            exit 1
        }
        if ($PassThru) {
            try {
                $relayPath = Join-Path $relayStateRoot 'report.json'
                $relayReport = Read-BootstrapJson $relayPath
                if ($null -eq $relayReport) { throw "Elevated child did not write a report: $relayPath" }
                if ($operation -in @('Run', 'Resume') -and [string]$relayReport.runId -cne [string]$BootstrapRunId) {
                    throw "Elevated child report run ID does not match the normal-user phase: $relayPath"
                }
                ConvertTo-BootstrapJsonText $relayReport
            } catch {
                Write-Error "Elevated bootstrap report could not be relayed: $($_.Exception.Message)"
            }
        }
        exit [int]$elevated.ExitCode
    }
    $result = Invoke-BootstrapRun
    if ($Report -or $PassThru) {
        if ($result.DryRun) { ConvertTo-BootstrapJsonText $result.Report }
        else { Get-Content -LiteralPath $result.ReportPath -Raw }
    } else {
        Write-BootstrapConsole $result "Windows bootstrap state: $($result.State.phase)"
        if ($result.DryRun) { Write-BootstrapConsole $result 'Report: dry-run only; no report file was written' }
        else {
            Write-BootstrapConsole $result "Report: $($result.ReportPath)"
            Write-BootstrapConsole $result "Log:    $($result.LogPath)"
        }
    }
    $reportObject = if ($result.DryRun) { $result.Report } else { Read-BootstrapJson $result.ReportPath }
    if ($null -ne $reportObject -and (@($reportObject.failed).Count -gt 0 -or @($reportObject.failedCleaned).Count -gt 0 -or @($reportObject.failedUncleaned).Count -gt 0 -or @($reportObject.recoveryRequired).Count -gt 0)) { exit 1 }
} catch {
    Write-Error $_
    exit 1
}
