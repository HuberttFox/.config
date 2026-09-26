#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Action')]
param(
    [Parameter(ParameterSetName = 'Action')]
    [ValidateSet('ice', 'mint', 'moqi')]
    [string]$Profile,
    [Parameter(ParameterSetName = 'Action')]
    [switch]$Toggle,
    [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
    [switch]$Status,
    [string]$RimeRoot,
    [string]$ConfigPath,
    [ValidateSet('Interactive', 'Quiet')]
    [string]$DeployMode = 'Interactive',
    [ValidateRange(30, 3600)]
    [int]$DeployTimeoutSeconds = 600,
    [switch]$MoqiFull,
    [string]$WeaselInstallDirectory,
    [switch]$NoDeploy,
    [switch]$ForceDeploy,
    [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ControlDirectory = $PSScriptRoot
$script:LibraryDirectory = $PSScriptRoot

function Import-RimeLibraries {
    foreach ($name in @('Rime.Core.ps1', 'Rime.Windows.ps1', 'Rime.Switch.ps1', 'Rime.Install.ps1')) {
        $path = Join-Path $script:LibraryDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "RIME control library missing: $path" }
        . $path
    }
}

function Get-RimeSwitchConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { return [IO.Path]::GetFullPath($ConfigPath) }
    return Join-Path $env:LOCALAPPDATA 'config-rime/rime.json'
}

function Resolve-RimeSwitchRoot([string]$ExplicitRoot) {
    $configPath = Get-RimeSwitchConfigPath
    $configured = ''
    if (Test-Path -LiteralPath $configPath -PathType Leaf) { $configured = Read-RimeConfiguredRoot $configPath }
    $managed = ''
    try {
        $selector = Get-RimeWeaselUserDirectory
        if ($selector) { $managed = Get-RimeManagedRootsFromSelector $selector | Select-Object -First 1 }
    } catch { }
    $marked = ''
    $candidate = 'D:\ProgramData\Rime'
    if (Test-Path -LiteralPath (Join-Path $candidate '.config-rime-root.json') -PathType Leaf) { $marked = $candidate }
    $local = Join-Path $env:LOCALAPPDATA 'RimeProfiles'
    $root = Resolve-RimeRoot $ExplicitRoot $configured $managed $marked $local
    if (-not (Test-Path -LiteralPath (Join-Path $root '.config-rime-root.json') -PathType Leaf)) {
        throw "Managed RIME root not found: $root. Run windows/install.ps1 first."
    }
    return [IO.Path]::GetFullPath($root)
}

function Get-RimeProfileFromTarget([string]$Root, [string]$Target) {
    if ([string]::IsNullOrWhiteSpace($Target)) { return $null }
    foreach ($profile in @('ice', 'mint', 'moqi')) {
        $candidate = Get-RimeProfileDirectory $Root $profile
        if ([IO.Path]::GetFullPath($candidate) -ieq [IO.Path]::GetFullPath($Target)) { return $profile }
    }
    return $null
}

function Invoke-RimeSwitchCommand {
    Assert-RimeWindowsHost
    Assert-RimePowerShell7X64 | Out-Null
    $sid = Get-RimeCurrentSid
    Assert-RimeOwnerContext $sid
    $root = Resolve-RimeSwitchRoot $RimeRoot
    Assert-RimeMarker $root $sid
    if ($Status) {
        $adapter = New-RimeStatusAdapter
        $result = Get-RimeStatus $root $sid $adapter
        $result | Add-Member -NotePropertyName ActiveProfile -NotePropertyValue (Get-RimeProfileFromTarget $root $result.Target)
        return $result
    }
    $selector = Get-RimeSelectorPath $root
    if ($NoDeploy) {
        $activeTarget = if (Test-Path -LiteralPath $selector) { Get-RimeJunctionTarget $selector } else { $null }
    } else {
        $installDirectory = Get-RimeWeaselInstallDirectory $WeaselInstallDirectory
        $adapter = New-RimeWindowsAdapter $root $installDirectory ([bool]$MoqiFull)
        $activeTarget = & $adapter.GetActive $selector
    }
    $activeProfile = Get-RimeProfileFromTarget $root $activeTarget
    $requested = $Profile
    if ($Toggle) {
        if (-not $activeProfile) { throw 'Cannot toggle: active RIME selector is missing or outside managed profiles' }
        $requested = Get-RimeNextProfile $activeProfile
    }
    if ([string]::IsNullOrWhiteSpace($requested)) { throw 'Specify -Profile, -Toggle, or -Status' }
    if ($NoDeploy) {
        Write-RimeSwitchState $root @{ requestedProfile = $requested; status = 'manual_required'; note = 'Selector unchanged because -NoDeploy was supplied' }
        return [pscustomobject]@{ Status = 'manual_required'; Profile = $requested; Root = $root }
    }
    # Serialize against a running windows/install.ps1, which rewrites profiles and the
    # Registry selector while holding install.lock. The installer acquires install.lock
    # before switch.lock, so this ordering cannot deadlock.
    try { $installLock = Enter-RimeNamedLock $root 'install.lock' }
    catch { throw "RIME install is running or the root is locked: $root ($($_.Exception.Message))" }
    try {
        return Invoke-RimeProfileSwitch $root $requested $sid $adapter $DeployMode $DeployTimeoutSeconds ([bool]$MoqiFull) -ForceDeploy:$ForceDeploy
    } finally { $installLock.Dispose() }
}

try {
    Import-RimeLibraries
    $result = Invoke-RimeSwitchCommand
    if ($PassThru -or $Status) { $result | ConvertTo-Json -Depth 20 }
    else { Write-Host "RIME profile switched: $($result.Profile)" }
} catch {
    Write-Error $_
    exit 1
}
