#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Base', 'Core', 'Optional', 'All', 'Extension')]
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
    [switch]$BootstrapUserPhaseHandoff,
    [string[]]$ExtensionManifest = @(),
    [switch]$PlanOnly,
    [string]$ApprovePlan,
    [string]$BootstrapPackagePlanPath
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
        'Extension' { return @() }
        default {
            $files = @('base.json', 'core.json')
            if ($IncludeOptional) { $files += 'optional.json' }
            return $files
        }
    }
}

function Get-BootstrapSelectedPackagePlan([string]$SelectedProfile, [bool]$IncludeOptional, [string[]]$RequestedExtensions, [string]$SnapshotPath, [string]$RunId, [string]$Approval) {
    $builtInItems = @(Get-BootstrapManifestItems (Join-Path $script:BootstrapRoot 'packages') (Get-BootstrapComponentFiles $SelectedProfile $IncludeOptional))
    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        if ($SelectedProfile -ne 'Extension') { throw 'Bootstrap package-plan snapshots are only valid with Profile Extension' }
        if (@($RequestedExtensions).Count -gt 0) { throw 'Bootstrap package-plan snapshot cannot be combined with ExtensionManifest' }
        return Read-BootstrapPackagePlanSnapshot $SnapshotPath $RunId $SelectedProfile $Approval $builtInItems
    }
    $extensionItems = @(Get-BootstrapExtensionManifestItems $RequestedExtensions $script:BootstrapRoot)
    if ($SelectedProfile -eq 'Extension' -and $extensionItems.Count -eq 0) {
        throw 'Profile Extension requires at least one ExtensionManifest'
    }
    if ($SelectedProfile -ne 'Extension' -and $extensionItems.Count -gt 0) {
        throw 'ExtensionManifest requires Profile Extension; do not mix external packages into a built-in profile'
    }
    return Get-BootstrapPackagePlan ($builtInItems + $extensionItems) (Get-BootstrapExtensionManifestRecords $extensionItems)
}

function Get-BootstrapPlanDisplay($Plan, [string]$SelectedProfile) {
    return [ordered]@{
        format = 1
        profile = $SelectedProfile
        hash = [string]$Plan.hash
        requiresApproval = (@($Plan.extensionManifests).Count -gt 0)
        extensionManifests = @($Plan.extensionManifests)
        items = @($Plan.items | ForEach-Object {
            [ordered]@{
                id = Get-BootstrapPackageItemKey $_
                name = [string](Get-BootstrapObjectProperty $_ 'name')
                provider = Get-BootstrapItemProvider $_
                executionContext = Get-BootstrapItemExecutionContext $_
                source = [string](Get-BootstrapObjectProperty $_ 'source')
                version = [string](Get-BootstrapObjectProperty $_ 'version')
                cleanupMode = [string](Get-BootstrapObjectProperty $_ 'cleanupMode')
            }
        })
    }
}

function Resolve-BootstrapExecutablePackagePlan(
    [string]$SelectedProfile,
    [bool]$IncludeOptional,
    [string[]]$RequestedExtensions,
    [string]$SnapshotPath,
    [string]$RunId,
    [string]$Approval,
    [bool]$RequireApproval,
    [bool]$RequireSnapshot
) {
    $hasSnapshot = -not [string]::IsNullOrWhiteSpace($SnapshotPath)
    $plan = Get-BootstrapSelectedPackagePlan $SelectedProfile $IncludeOptional $RequestedExtensions $SnapshotPath $RunId $Approval
    $hasExtensions = @($plan.extensionManifests).Count -gt 0
    if ($RequireApproval -and $hasExtensions -and -not (Test-BootstrapApprovedPackagePlan $Approval $plan)) {
        throw "Bootstrap extension package plan requires -ApprovePlan $($plan.hash); run -PlanOnly first"
    }
    if ($RequireSnapshot -and $hasExtensions -and -not $hasSnapshot) {
        throw 'Bootstrap extension package plan must be passed to an elevated child through a protected snapshot'
    }
    return [pscustomobject]@{
        plan = $plan
        approvePlan = if ($hasExtensions) { [string]$plan.hash } else { '' }
        snapshotPath = if ($hasSnapshot) { [IO.Path]::GetFullPath($SnapshotPath) } else { '' }
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

function Add-BootstrapVerificationResult($Context, $Items = @()) {
    if ($Context.DryRun) {
        $verificationProfile = if ([string]$Context.State.profile -eq 'Extension') { 'extension' } else { 'core' }
        return Add-BootstrapResult $Context 'final-verification' $verificationProfile 'skipped' 'Dry run: final verification not executed' $null
    }
    $checks = Get-BootstrapVerification $Context $Items
    $bad = @($checks | Where-Object { -not $_.ok })
    $status = if ($bad.Count -eq 0) { 'completed' } else { 'manual_required' }
    $message = if ($bad.Count -eq 0) { 'All requested verification checks passed' } else { "Verification gaps: $($bad.name -join ', ')" }
    $verificationProfile = if ([string]$Context.State.profile -eq 'Extension') { 'extension' } else { 'core' }
    return Add-BootstrapResult $Context 'final-verification' $verificationProfile $status $message $checks
}

function Get-BootstrapPackageResultProfile([string]$SelectedProfile, $Item, [ValidateSet('user', 'elevated')][string]$Phase) {
    if (Test-BootstrapExtensionPackageItem $Item) { return 'extension' }
    if ($Phase -eq 'user') { return 'user' }
    switch (Get-BootstrapItemProvider $Item) {
        'winget' { return 'base' }
        'download' { return 'optional' }
        'wsl' { return 'core' }
        'font' { return 'core' }
        'powershell-profile' { return 'core' }
        'rime' { return 'core' }
        'input-method' { return 'core' }
        'manual' { return 'optional' }
        'portable-handoff' { return 'optional' }
        default { return 'unknown' }
    }
}

function Invoke-BootstrapPackageProvider(
    $Context,
    $Item,
    [string]$Winget,
    [ValidateSet('user', 'elevated')][string]$Phase,
    [string]$ScriptPath
) {
    $provider = Get-BootstrapItemProvider $Item
    $isExtension = Test-BootstrapExtensionPackageItem $Item
    if ($isExtension) {
        # External JSON reaches only repository-owned provider implementations.
        Assert-BootstrapExtensionProviderAvailability @($Item) $script:BootstrapRoot
        if ($Phase -eq 'user' -and $provider -ne 'winget') {
            return [pscustomobject]@{ status = 'manual_required'; message = "Extension provider '$provider' is unavailable in the normal-user phase"; details = $Item }
        }
        switch ($provider) {
            'winget' { return Invoke-BootstrapWingetInstall $Context $Item $Winget }
            'manual' { return [pscustomobject]@{ status = 'manual_required'; message = [string](Get-BootstrapObjectProperty $Item 'reason'); details = $Item } }
            default { throw "Bootstrap extension provider dispatch rejected: $provider" }
        }
    }

    if ($Phase -eq 'user') {
        switch ($provider) {
            'winget' { return Invoke-BootstrapWingetInstall $Context $Item $Winget }
            'portable-handoff' {
                return Install-BootstrapPortableHandoff $Context $Item $PortableAppsRoot -Launch:$LaunchPortableHandoff -Confirm:$ConfirmPortableHandoff
            }
            default {
                return [pscustomobject]@{ status = 'manual_required'; message = "Unsupported normal-user phase provider: $provider"; details = $Item }
            }
        }
    }

    switch ($provider) {
        'winget' { return Invoke-BootstrapWingetInstall $Context $Item $Winget }
        'download' { return Install-BootstrapDownloadApp $Context $Item }
        'wsl' { return Install-BootstrapWsl $Context $ScriptPath -NoReboot:$NoReboot }
        'font' { return Install-BootstrapFonts $Context }
        'powershell-profile' { return Install-BootstrapPowerShellConfig $Context }
        'rime' { return Invoke-BootstrapRime $Context -SkipRime:$SkipRime }
        'input-method' { return Configure-BootstrapMintInputMethod $Context }
        'manual' { return [pscustomobject]@{ status = 'manual_required'; message = [string](Get-BootstrapObjectProperty $Item 'reason'); details = $Item } }
        'portable-handoff' {
            return [pscustomobject]@{ status = 'manual_required'; message = 'PortableApps handoff requires the normal-user phase'; details = $Item }
        }
        default {
            return [pscustomobject]@{ status = 'manual_required'; message = "Unsupported manifest provider: $provider"; details = $Item }
        }
    }
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

function Get-BootstrapPersistedExtensionPlanReference([string]$SelectedProfile, [string]$SelectedOperation, [string]$RequestedStateRoot, [string]$RequestedRunId, [string]$SnapshotPath, [string]$ApprovedPlan) {
    $fallback = [pscustomobject]@{
        isExtension = $false
        profile = $SelectedProfile
        snapshotPath = $SnapshotPath
        approvePlan = $ApprovedPlan
        runId = $RequestedRunId
    }
    if ($SelectedOperation -notin @('Resume', 'Verify', 'Cleanup')) { return $fallback }
    $stateRoot = if ([string]::IsNullOrWhiteSpace($RequestedStateRoot)) { Get-BootstrapDefaultStateRoot } else { [IO.Path]::GetFullPath($RequestedStateRoot) }
    $statePath = Join-Path $stateRoot 'state.json'
    $state = Read-BootstrapJson $statePath
    if ($null -eq $state) {
        if ($SelectedProfile -eq 'Extension' -or $SelectedOperation -in @('Resume', 'Cleanup')) {
            throw "No prior Windows bootstrap state found: $statePath"
        }
        return $fallback
    }
    $state = Ensure-BootstrapStateShape $state
    if ([string](Get-BootstrapObjectProperty $state 'profile') -cne 'Extension') {
        if ($SelectedProfile -eq 'Extension' -and $SelectedOperation -in @('Resume', 'Verify', 'Cleanup')) {
            throw 'Persisted Windows bootstrap state is not an Extension run; Extension Resume/Verify/Cleanup require the original protected plan'
        }
        return $fallback
    }
    $runId = [string](Get-BootstrapObjectProperty $state 'runId')
    if (-not (Test-BootstrapRunId $runId)) { throw 'Persisted Extension state has an invalid run ID' }
    if (-not [string]::IsNullOrWhiteSpace($RequestedRunId) -and $RequestedRunId -cne $runId) {
        throw 'Requested Extension run ID does not match persisted state'
    }
    $reference = Get-BootstrapExtensionResumePlanReference $state $SnapshotPath $ApprovedPlan
    return [pscustomobject]@{
        isExtension = $true
        profile = 'Extension'
        snapshotPath = [string]$reference.snapshotPath
        approvePlan = [string]$reference.approvePlan
        runId = $runId
    }
}

function Get-BootstrapUserPhasePlan([string]$Operation) {
    if ($Operation -notin @('Run', 'Resume')) { throw "User phase is not valid for operation: $Operation" }
    if ($Operation -eq 'Resume' -and @($ExtensionManifest).Count -gt 0) {
        throw 'Resume cannot reload ExtensionManifest; it must use the protected package-plan snapshot recorded by the original run'
    }
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
    if ([string]::IsNullOrWhiteSpace($runId)) { $runId = [guid]::NewGuid().ToString('N') }
    $snapshotPath = $BootstrapPackagePlanPath
    $approval = $ApprovePlan
    if ($Operation -eq 'Resume' -and [string]$selected -eq 'Extension') {
        $resumeReference = Get-BootstrapExtensionResumePlanReference $existingState $snapshotPath $approval
        $snapshotPath = [string]$resumeReference.snapshotPath
        $approval = [string]$resumeReference.approvePlan
    }
    $resolved = Resolve-BootstrapExecutablePackagePlan $selected ($selected -eq 'All' -and -not $effectiveNoOptional) $ExtensionManifest $snapshotPath $runId $approval $true $false
    return [pscustomobject]@{
        stateRoot = $mainStateRoot
        runId = $runId.ToLowerInvariant()
        profile = $selected
        noOptional = $effectiveNoOptional
        plan = $resolved.plan
        packagePlanHash = [string]$resolved.plan.hash
        approvePlan = $resolved.approvePlan
        snapshotPath = $resolved.snapshotPath
        items = @($resolved.plan.items)
        userItems = @(Get-BootstrapUserPhaseItems @($resolved.plan.items))
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
    if ([string]$Plan.profile -eq 'Extension') {
        $snapshotPath = [string](Get-BootstrapObjectProperty $Plan 'snapshotPath')
        $approval = [string](Get-BootstrapObjectProperty $Plan 'approvePlan')
        if ([string]::IsNullOrWhiteSpace($snapshotPath) -or [string]::IsNullOrWhiteSpace($approval)) {
            throw 'Extension normal-user phase requires a protected package-plan snapshot and approval hash'
        }
        # The normal-user phase must consume the same protected record as the
        # UAC child and Resume. It must not rely on a parsed raw manifest object.
        $protectedPlan = Read-BootstrapPackagePlanSnapshot $snapshotPath ([string]$Plan.runId) 'Extension' $approval @()
        if ([string]$Plan.packagePlanHash -cne [string]$protectedPlan.hash) {
            throw 'Extension normal-user phase plan hash does not match its protected snapshot'
        }
        $Plan.plan = $protectedPlan
        $Plan.packagePlanHash = [string]$protectedPlan.hash
        $Plan.items = @($protectedPlan.items)
        $Plan.userItems = @(Get-BootstrapUserPhaseItems @($protectedPlan.items))
    }
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
            Invoke-BootstrapStep $context ([string]$item.name) 'user' {
                Invoke-BootstrapPackageProvider $context $item $winget 'user' $PSCommandPath
            } | Out-Null
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
            packagePlanHash = [string]$Plan.packagePlanHash
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
        $expectedPlanHash = ''
        $recordedPlan = Get-BootstrapObjectProperty $Context.State 'packagePlan'
        if ([string]$Context.State.profile -eq 'Extension') { $expectedPlanHash = [string](Get-BootstrapObjectProperty $recordedPlan 'hash') }
        $validation = Test-BootstrapUserPhaseHandoffData $handoff $Context.RunId $ownerSid $Items ([string]$Context.State.profile) $expectedPlanHash
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
    if ($operation -eq 'Resume' -and @($ExtensionManifest).Count -gt 0) {
        throw 'Resume cannot reload ExtensionManifest; use the protected package-plan snapshot recorded by the original run'
    }
    $context = New-BootstrapContext $StateRoot $selected ([bool]$DryRun) $operation $script:RepositoryRoot -Force:$Force -Quiet:$Quiet -Silent:([bool]$PassThru) -RunId $BootstrapRunId
    $selected = [string]$context.State.profile
    Write-BootstrapConsole $context ("Windows bootstrap: operation={0}, profile={1}" -f $operation, $selected)
    if (-not $context.DryRun) {
        Write-BootstrapConsole $context ("State: {0}" -f $context.StateRoot)
        Write-BootstrapConsole $context ("Log:   {0}" -f $context.LogPath)
    }
    if ($operation -eq 'Report') { return $context }

    if ($operation -in @('Run', 'Resume') -and -not $context.DryRun) {
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
            $verificationSnapshotPath = $BootstrapPackagePlanPath
            $verificationApproval = $ApprovePlan
            if ([string]$selected -eq 'Extension') {
                $verificationReference = Get-BootstrapExtensionResumePlanReference $context.State $verificationSnapshotPath $verificationApproval
                $verificationSnapshotPath = [string]$verificationReference.snapshotPath
                $verificationApproval = [string]$verificationReference.approvePlan
            }
            $verificationResolvedPlan = Resolve-BootstrapExecutablePackagePlan $selected ($selected -eq 'All' -and -not $NoOptional) $ExtensionManifest $verificationSnapshotPath $context.RunId $verificationApproval (-not [bool]$DryRun) (-not [bool]$DryRun)
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
            Add-BootstrapVerificationResult $context $verificationResolvedPlan.plan.items | Out-Null
            Save-BootstrapContext $context
            return $context
        }
        if ($operation -eq 'Cleanup') {
            if ([string]$selected -eq 'Extension') {
                # Cleanup does not dispatch external providers today, but it is
                # still a mutating elevated operation. Validate state-recorded
                # provenance before consuming any Extension lifecycle state.
                $cleanupReference = Get-BootstrapExtensionResumePlanReference $context.State $BootstrapPackagePlanPath $ApprovePlan
                [void](Resolve-BootstrapExecutablePackagePlan 'Extension' $false @() ([string]$cleanupReference.snapshotPath) $context.RunId ([string]$cleanupReference.approvePlan) $true $true)
            }
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
        $snapshotPath = $BootstrapPackagePlanPath
        $approval = $ApprovePlan
        if ($operation -eq 'Resume' -and [string]$selected -eq 'Extension') {
            $resumeReference = Get-BootstrapExtensionResumePlanReference $context.State $snapshotPath $approval
            $snapshotPath = [string]$resumeReference.snapshotPath
            $approval = [string]$resumeReference.approvePlan
        }
        # Validate an extension plan before any stateful preflight step. This
        # prevents a rejected approval from creating backup or package records.
        $resolvedPlan = Resolve-BootstrapExecutablePackagePlan $selected ($selected -eq 'All' -and -not $NoOptional) $ExtensionManifest $snapshotPath $context.RunId $approval (-not [bool]$DryRun) (-not [bool]$DryRun)
        Save-BootstrapContext $context
        if ($operation -eq 'Run' -and [string]$selected -ne 'Extension') {
            Invoke-BootstrapStep $context 'user-config-backup' 'preflight' { Backup-BootstrapUserFiles $context } | Out-Null
        }
        $context.State.phase = if ([string]$selected -eq 'Extension') { 'extension' } else { 'preflight' }
        $context.State.nextPhase = if ([string]$selected -eq 'Extension') { 'extension' } else { 'base' }
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

        $packagePlan = $resolvedPlan.plan
        $context.State.packagePlan = Get-BootstrapPackagePlanRecord $packagePlan
        if (-not [string]::IsNullOrWhiteSpace([string]$resolvedPlan.snapshotPath)) {
            $context.State.packagePlan.snapshotPath = [string]$resolvedPlan.snapshotPath
        }
        Set-BootstrapObjectProperty $context.State.executionOptions 'bootstrapPackagePlanPath' ([string]$resolvedPlan.snapshotPath)
        Set-BootstrapObjectProperty $context.State.executionOptions 'approvedPlan' ([string]$resolvedPlan.approvePlan)
        Save-BootstrapContext $context
        $items = @($packagePlan.items)
        $userPhaseHandoffExpected = [bool]$BootstrapUserPhaseHandoff
        if (-not $DryRun) {
            Import-BootstrapUserPhaseHandoff $context $items $userPhaseHandoffExpected
        }
        $context.State.phase = if ([string]$selected -eq 'Extension') { 'extension' } else { 'base' }
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
            $itemProfile = Get-BootstrapPackageResultProfile $selected $item 'elevated'
            Invoke-BootstrapStep $context ([string]$item.name) $itemProfile {
                Invoke-BootstrapPackageProvider $context $item $winget 'elevated' $PSCommandPath
            } | Out-Null
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
        Add-BootstrapVerificationResult $context $items | Out-Null
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
    # PlanOnly and DryRun are read-only. Neither creates state nor requests UAC.
    $operation = Get-BootstrapOperation
    if ($PlanOnly -and ($Resume -or $Verify -or $Report -or $CleanupFailed -or $DryRun)) {
        throw 'PlanOnly cannot be combined with an operation switch or DryRun'
    }
    if ($PlanOnly) {
        if ([string]::IsNullOrWhiteSpace($BootstrapRunId)) { $BootstrapRunId = [guid]::NewGuid().ToString('N') }
        if (-not (Test-BootstrapRunId $BootstrapRunId)) { throw "Invalid Windows bootstrap run ID: $BootstrapRunId" }
        $selectedPlanProfile = if ($NoOptional -and $Profile -eq 'All') { 'Core' } else { $Profile }
        $plan = Get-BootstrapSelectedPackagePlan $selectedPlanProfile ($selectedPlanProfile -eq 'All' -and -not $NoOptional) $ExtensionManifest '' $BootstrapRunId ''
        ConvertTo-BootstrapJsonText (Get-BootstrapPlanDisplay $plan $selectedPlanProfile)
        exit 0
    }
    $selectedPlanProfile = if ($NoOptional -and $Profile -eq 'All') { 'Core' } else { $Profile }
    $hasRequestedExtensions = @($ExtensionManifest | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0
    if ($hasRequestedExtensions -and $operation -in @('Resume', 'Verify', 'Report', 'Cleanup')) {
        throw 'Only Run, PlanOnly, and DryRun may read ExtensionManifest; Resume, Verify, Report, and Cleanup use persisted protected state'
    }
    if ($hasRequestedExtensions -and $selectedPlanProfile -ne 'Extension') {
        throw 'ExtensionManifest requires Profile Extension; do not mix external packages into a built-in profile'
    }
    $persistedExtension = Get-BootstrapPersistedExtensionPlanReference $selectedPlanProfile $operation $StateRoot $BootstrapRunId $BootstrapPackagePlanPath $ApprovePlan
    if ($persistedExtension.isExtension) {
        $selectedPlanProfile = [string]$persistedExtension.profile
        $BootstrapRunId = [string]$persistedExtension.runId
        $BootstrapPackagePlanPath = [string]$persistedExtension.snapshotPath
        $ApprovePlan = [string]$persistedExtension.approvePlan
    }
    if ($DryRun) { $operation = 'DryRun' }
    $isAdministrator = if ($DryRun) { $false } else { Test-BootstrapAdministrator }
    if ($operation -eq 'Resume' -and $hasRequestedExtensions) {
        throw 'Resume cannot reload ExtensionManifest; use the protected package-plan snapshot recorded by the original run'
    }
    # Reject malformed or unapproved extension input before New-BootstrapContext
    # can create machine state. Normal-user Run then rebuilds this plan once to
    # create the protected snapshot for UAC; no raw manifest crosses that boundary.
    if (-not $DryRun -and $selectedPlanProfile -eq 'Extension' -and $operation -in @('Run', 'Resume', 'Verify', 'Cleanup')) {
        # An already-elevated shell must never parse a raw external manifest.
        # The normal-user parent is solely responsible for parsing it and then
        # passing a protected snapshot to the UAC child. Resume, Verify, and
        # Cleanup validate their persisted snapshot before creating context.
        if ($isAdministrator -and $operation -in @('Run', 'Verify') -and [string]::IsNullOrWhiteSpace($BootstrapPackagePlanPath)) {
            throw 'Elevated Profile Extension requires a protected BootstrapPackagePlanPath created by a normal-user parent'
        }
        $preflightPlan = Get-BootstrapSelectedPackagePlan $selectedPlanProfile $false $ExtensionManifest $BootstrapPackagePlanPath $BootstrapRunId $ApprovePlan
        if (-not (Test-BootstrapApprovedPackagePlan $ApprovePlan $preflightPlan)) {
            throw "Bootstrap extension package plan requires -ApprovePlan $($preflightPlan.hash); run -PlanOnly first"
        }
    }
    if (-not $DryRun -and -not $isAdministrator -and [bool]$NoElevate -and $operation -in @('Run', 'Resume', 'Verify', 'Cleanup')) {
        throw "Administrator privileges are required for '$operation'; -NoElevate forbids the required relaunch"
    }
    if (Test-BootstrapElevationRequired $isAdministrator $operation ([bool]$NoElevate)) {
        $relayStateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-BootstrapDefaultStateRoot } else { [IO.Path]::GetFullPath($StateRoot) }
        $elevationPlan = $null
        $elevationSnapshotPath = ''
        $elevationApproval = $ApprovePlan
        # User-scoped packages must run before UAC. An elevated process cannot
        # safely create a medium-integrity child with the original token.
        if ($operation -in @('Run', 'Resume')) {
            $plan = Get-BootstrapUserPhasePlan $operation
            $BootstrapRunId = [string]$plan.runId
            $elevationPlan = $plan.plan
            $elevationApproval = [string]$plan.approvePlan
            $elevationSnapshotPath = [string]$plan.snapshotPath
            if (@($elevationPlan.extensionManifests).Count -gt 0) {
                if ([string]::IsNullOrWhiteSpace($elevationSnapshotPath)) {
                    $elevationSnapshotPath = Write-BootstrapPackagePlanSnapshot $BootstrapRunId ([string]$plan.profile) $elevationPlan $elevationApproval
                }
                $protected = Resolve-BootstrapExecutablePackagePlan ([string]$plan.profile) $false @() $elevationSnapshotPath $BootstrapRunId $elevationApproval $true $true
                $elevationPlan = $protected.plan
                $elevationApproval = [string]$protected.approvePlan
                $elevationSnapshotPath = [string]$protected.snapshotPath
                $plan.plan = $elevationPlan
                $plan.packagePlanHash = [string]$elevationPlan.hash
                $plan.approvePlan = $elevationApproval
                $plan.snapshotPath = $elevationSnapshotPath
                $plan.items = @($elevationPlan.items)
                $plan.userItems = @(Get-BootstrapUserPhaseItems @($elevationPlan.items))
            }
            if ($plan.userItems.Count -gt 0) {
                $phase = Invoke-BootstrapUserPhase $plan
                $BootstrapUserPhaseHandoff = $true
            }
        } elseif ($operation -in @('Verify', 'Cleanup') -and [string]$selectedPlanProfile -eq 'Extension') {
            if ([string]::IsNullOrWhiteSpace($BootstrapRunId)) { throw "$operation Profile Extension requires BootstrapRunId and a protected package-plan snapshot" }
            $elevationPlan = Get-BootstrapSelectedPackagePlan $selectedPlanProfile $false $ExtensionManifest $BootstrapPackagePlanPath $BootstrapRunId $ApprovePlan
            $elevationApproval = [string]$elevationPlan.hash
            $elevationSnapshotPath = [string]$BootstrapPackagePlanPath
            if ([string]::IsNullOrWhiteSpace($elevationSnapshotPath)) { throw "$operation Profile Extension requires BootstrapPackagePlanPath" }
        }
        $hostPath = $null
        try { $hostPath = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { }
        if ([string]::IsNullOrWhiteSpace($hostPath)) { $hostPath = Join-Path $PSHOME 'powershell.exe' }
        # External source manifests never cross the privilege boundary. The child
        # receives only the protected, hash-bound plan snapshot.
        $elevationParameters = Get-BootstrapElevatedChildParameters $PSBoundParameters $elevationSnapshotPath $elevationApproval
        # Preserve parent resolution when UAC starts from a different working directory.
        $elevationParameters['StateRoot'] = $relayStateRoot
        if ($operation -in @('Run', 'Resume') -or ($operation -in @('Verify', 'Cleanup') -and $selectedPlanProfile -eq 'Extension')) {
            $elevationParameters['BootstrapRunId'] = $BootstrapRunId
        }
        if ($selectedPlanProfile -eq 'Extension') { $elevationParameters['Profile'] = 'Extension' }
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
    if ($isAdministrator -and $operation -in @('Run', 'Verify') -and $Profile -eq 'Extension' -and [string]::IsNullOrWhiteSpace($BootstrapPackagePlanPath) -and -not $DryRun) {
        throw 'Elevated Profile Extension requires a protected BootstrapPackagePlanPath created by a normal-user parent'
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
