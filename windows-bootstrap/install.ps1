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
    [switch]$NoElevate
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

function Invoke-BootstrapRun {
    $selected = if ($NoOptional -and $Profile -eq 'All') { 'Core' } else { $Profile }
    $operation = Get-BootstrapOperation
    $context = New-BootstrapContext $StateRoot $selected ([bool]$DryRun) $operation $script:RepositoryRoot -Force:$Force
    $selected = [string]$context.State.profile
    if ($operation -eq 'Report') { return $context }

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
        $context.State.phase = 'base'
        foreach ($item in $items) {
            if ($operation -eq 'Resume' -and (Test-BootstrapComponentStillComplete $context $item)) {
                Write-BootstrapLog $context "Resume: verified completed component, skipping $($item.name)"
                continue
            }
            if ($operation -eq 'Resume' -and ([string]$item.name -in @($context.State.completedComponents))) {
                Write-BootstrapLog $context "Resume: completion record stale; rerunning $($item.name)" 'WARN'
            }
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
                default {
                    Invoke-BootstrapStep $context ([string]$item.name) 'unknown' { [pscustomobject]@{ status = 'manual_required'; message = "Unsupported manifest mode: $mode"; details = $item } } | Out-Null
                }
            }
            Save-BootstrapContext $context
            if ([string]$context.State.phase -eq 'awaiting-reboot') {
                Save-BootstrapContext $context
                return $context
            }
        }
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
    if (Test-BootstrapElevationRequired (Test-BootstrapAdministrator) $operation ([bool]$NoElevate)) {
        Write-Host "Administrator privileges are required for '$operation'; requesting elevation..."
        $hostPath = $null
        try { $hostPath = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { }
        if ([string]::IsNullOrWhiteSpace($hostPath)) { $hostPath = Join-Path $PSHOME 'powershell.exe' }
        $elevatedArguments = @(Get-BootstrapElevatedArguments $PSCommandPath $PSBoundParameters)
        try {
            $elevated = Start-Process -FilePath $hostPath -Verb RunAs -ArgumentList ($elevatedArguments -join ' ') -PassThru -Wait -ErrorAction Stop
        } catch {
            Write-Error "Elevation was declined or failed: $($_.Exception.Message) (re-run from an elevated window, or pass -NoElevate to keep the old behaviour)"
            exit 1
        }
        exit [int]$elevated.ExitCode
    }
    $result = Invoke-BootstrapRun
    if ($Report -or $PassThru) {
        if ($result.DryRun) { ConvertTo-BootstrapJsonText $result.Report }
        else { Get-Content -LiteralPath $result.ReportPath -Raw }
    } else {
        Write-Host "Windows bootstrap state: $($result.State.phase)"
        if ($result.DryRun) { Write-Host 'Report: dry-run only; no report file was written' }
        else { Write-Host "Report: $($result.ReportPath)" }
    }
    $reportObject = if ($result.DryRun) { $result.Report } else { Read-BootstrapJson $result.ReportPath }
    if ($null -ne $reportObject -and (@($reportObject.failed).Count -gt 0 -or @($reportObject.failedCleaned).Count -gt 0 -or @($reportObject.failedUncleaned).Count -gt 0 -or @($reportObject.recoveryRequired).Count -gt 0)) { exit 1 }
} catch {
    Write-Error $_
    exit 1
}
