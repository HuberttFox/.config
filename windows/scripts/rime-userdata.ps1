#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('ice', 'mint', 'moqi')]
    [string]$From,
    [string]$RimeRoot,
    [string]$ConfigPath,
    [string]$ReviewDirectory,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Files,
    [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LibraryDirectory = $PSScriptRoot
function Import-RimeLibraries {
    foreach ($name in @('Rime.Core.ps1', 'Rime.Windows.ps1', 'Rime.Switch.ps1', 'Rime.Install.ps1')) {
        $path = Join-Path $script:LibraryDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "RIME control library missing: $path" }
        . $path
    }
}

function Resolve-RimeUserdataRoot([string]$ExplicitRoot) {
    $config = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Join-Path $env:LOCALAPPDATA 'config-rime/rime.json'
    } else {
        [IO.Path]::GetFullPath($ConfigPath)
    }
    $configured = ''
    if (Test-Path -LiteralPath $config -PathType Leaf) { $configured = Read-RimeConfiguredRoot $config }
    $managed = ''
    try {
        $selector = Get-RimeWeaselUserDirectory
        if ($selector) { $managed = Get-RimeManagedRootsFromSelector $selector | Select-Object -First 1 }
    } catch { }
    $root = Resolve-RimeRoot $ExplicitRoot $configured $managed '' (Join-Path $env:LOCALAPPDATA 'RimeProfiles')
    if (-not (Test-Path -LiteralPath (Join-Path $root '.config-rime-root.json') -PathType Leaf)) { throw "Managed RIME root not found: $root" }
    return [IO.Path]::GetFullPath($root)
}

try {
    Import-RimeLibraries
    Assert-RimeWindowsHost
    Assert-RimePowerShell7X64 | Out-Null
    $sid = Get-RimeCurrentSid
    Assert-RimeOwnerContext $sid
    $root = Resolve-RimeUserdataRoot $RimeRoot
    Assert-RimeMarker $root $sid
    if ([string]::IsNullOrWhiteSpace($From)) {
        $selector = Get-RimeSelectorPath $root
        $target = Get-RimeJunctionTarget $selector
        if (-not $target) { throw 'No active RIME profile to export' }
        foreach ($candidate in @('ice', 'mint', 'moqi')) {
            if ([IO.Path]::GetFullPath((Get-RimeProfileDirectory $root $candidate)) -ieq [IO.Path]::GetFullPath($target)) {
                $From = $candidate; break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($From)) { throw 'Specify -From when active profile cannot be resolved' }
    $source = Get-RimeProfileDirectory $root $From
    if ([string]::IsNullOrWhiteSpace($ReviewDirectory)) {
        $ReviewDirectory = Join-Path $root ('review-export/' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    }
    $result = Export-RimeText $source $ReviewDirectory $Files
    if ($PassThru) { $result | ConvertTo-Json -Depth 20 } else { Write-Host "RIME text export created for review: $ReviewDirectory" }
} catch {
    Write-Error $_
    exit 1
}
