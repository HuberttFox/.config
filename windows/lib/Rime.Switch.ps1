#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-RimeSwitchState([string]$Root, [hashtable]$Values) {
    $path = Join-Path $Root 'state.json'
    $current = @{}
    if (Test-Path -LiteralPath $path) {
        $old = Read-RimeJson $path
        foreach ($property in $old.PSObject.Properties) { $current[$property.Name] = $property.Value }
    }
    foreach ($key in $Values.Keys) { $current[$key] = $Values[$key] }
    Write-RimeJson $path $current
}

function Invoke-RimeProfileSwitch(
    [string]$Root,
    [ValidateSet('ice', 'mint', 'moqi')][string]$Profile,
    [string]$OwnerSid,
    $Adapter,
    [ValidateSet('Interactive', 'Quiet')][string]$DeployMode = 'Interactive',
    [int]$DeployTimeoutSeconds = 600,
    [bool]$MoqiFull = $false,
    [switch]$ForceDeploy
) {
    $lock = $null
    $previous = $null
    $selectorChanged = $false
    $serverStopAttempted = $false
    $serverStopped = $false
    $target = Get-RimeProfileDirectory $Root $Profile
    $selector = Get-RimeSelectorPath $Root
    $transaction = [guid]::NewGuid().ToString('N')
    try {
        Assert-RimeMarker $Root $OwnerSid
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Profile directory missing: $target" }
        $lock = Enter-RimeLock $Root
        if ($Adapter.PSObject.Properties.Name -contains 'Recover') {
            & $Adapter.Recover $Root
        }
        $previous = & $Adapter.GetActive $selector
        if ($null -ne $previous -and $Adapter.PSObject.Properties.Name -contains 'ValidateActive') {
            & $Adapter.ValidateActive $selector $previous
        }
        if ($Profile -eq 'moqi' -and -not $MoqiFull) {
            Assert-RimeProfileVariantAllowed $target $Profile 'lite'
        }
        if (-not $ForceDeploy -and $previous -and [IO.Path]::GetFullPath($previous) -eq [IO.Path]::GetFullPath($target)) {
            Write-RimeSwitchState $Root @{ currentProfile = $Profile; status = 'completed'; transaction = $transaction }
            return [pscustomobject]@{ Status = 'completed'; Profile = $Profile; Previous = $previous; Target = $target; Changed = $false }
        }
        Write-RimeSwitchState $Root @{ status = 'switching'; requestedProfile = $Profile; previousTarget = $previous; transaction = $transaction }
        $before = if ($Adapter.PSObject.Properties.Name -contains 'Snapshot') { & $Adapter.Snapshot $target } else { @{} }
        $started = [DateTime]::UtcNow
        $serverStopAttempted = $true
        & $Adapter.Stop $null
        $serverStopped = $true
        & $Adapter.Switch $selector $target $transaction
        $selectorChanged = $true
        & $Adapter.Deploy $target $DeployMode $DeployTimeoutSeconds $Profile $before $started
        if (-not (& $Adapter.Verify $target $Profile $before $started)) { throw 'Deployment verification failed' }
        Write-RimeSwitchState $Root @{ currentProfile = $Profile; status = 'completed'; target = $target; transaction = $transaction }
        if ($Adapter.PSObject.Properties.Name -contains 'Commit') {
            & $Adapter.Commit $selector $target $transaction
        }
        return [pscustomobject]@{ Status = 'completed'; Profile = $Profile; Previous = $previous; Target = $target; Changed = $true }
    } catch {
        $message = $_.Exception.Message
        try {
            if (-not $selectorChanged -and $null -ne $lock) {
                $observed = & $Adapter.GetActive $selector
                if ($null -eq $previous) {
                    $selectorChanged = $null -ne $observed
                } else {
                    $selectorChanged = $null -eq $observed -or [IO.Path]::GetFullPath($observed) -ne [IO.Path]::GetFullPath($previous)
                }
            }
            if ($selectorChanged -and $null -ne $previous) {
                if ($Adapter.PSObject.Properties.Name -contains 'Restore') { & $Adapter.Restore $selector $previous $transaction }
                else { & $Adapter.Switch $selector $previous $transaction }
            } elseif ($selectorChanged -and $Adapter.PSObject.Properties.Name -contains 'Clear') {
                & $Adapter.Clear $selector $target $transaction
            }
            if (($serverStopAttempted -or $serverStopped) -and $null -ne $previous -and $Adapter.PSObject.Properties.Name -contains 'Restart') {
                & $Adapter.Restart $previous
            }
            Write-RimeSwitchState $Root @{ status = 'failed'; requestedProfile = $Profile; previousTarget = $previous; error = $message; transaction = $transaction }
        } catch {
            Write-RimeSwitchState $Root @{ status = 'recovery_required'; requestedProfile = $Profile; previousTarget = $previous; error = $message; recoveryError = $_.Exception.Message; transaction = $transaction }
        }
        throw
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

function Get-RimeStatus([string]$Root, [string]$OwnerSid, $Adapter) {
    Assert-RimeMarker $Root $OwnerSid
    $selector = Get-RimeSelectorPath $Root
    $statePath = Join-Path $Root 'state.json'
    $state = if (Test-Path $statePath) { Read-RimeJson $statePath } else { [pscustomobject]@{ status = 'uninitialized' } }
    $target = & $Adapter.GetActive $selector
    return [pscustomobject]@{ State = $state; Target = $target; Selector = $selector }
}
