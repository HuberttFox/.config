#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('ice', 'mint', 'moqi')]
    [string[]]$Profiles = @('ice', 'mint', 'moqi'),
    [ValidateSet('ice', 'mint', 'moqi')]
    [string]$InitialProfile,
    [switch]$MoqiFull,
    [ValidateSet('Interactive', 'Quiet')]
    [string]$DeployMode = 'Interactive',
    [ValidateRange(30, 3600)]
    [int]$DeployTimeoutSeconds = 600,
    [string]$RimeRoot,
    [string]$ConfigPath,
    [string]$CacheDirectory,
    [string]$RaycastScriptDir,
    [string]$WeaselInstallDirectory,
    [switch]$SkipWeaselInstall,
    [switch]$SkipDeploy,
    [switch]$BackupLegacy,
    [switch]$NoRaycast,
    [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WindowsDirectory = $PSScriptRoot
$script:RepositoryRoot = Split-Path $script:WindowsDirectory -Parent
$script:LibraryDirectory = Join-Path $script:WindowsDirectory 'lib'

. (Join-Path $script:LibraryDirectory 'Rime.Core.ps1')
. (Join-Path $script:LibraryDirectory 'Rime.Windows.ps1')
. (Join-Path $script:LibraryDirectory 'Rime.Switch.ps1')
. (Join-Path $script:LibraryDirectory 'Rime.Install.ps1')

function Write-RimeInstallLog([string]$Message) {
    Write-Host "[RIME] $Message"
}

function Assert-RimeInstallContext {
    Assert-RimeWindowsHost | Out-Null
    Assert-RimePowerShell7X64 | Out-Null
    $sid = Get-RimeCurrentSid
    Assert-RimeOwnerContext $sid
    return $sid
}

function Get-RimeCanonicalConfigPath {
    return Join-Path $env:LOCALAPPDATA 'config-rime/rime.json'
}

function Get-RimeRequestedConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { return [IO.Path]::GetFullPath($ConfigPath) }
    return Get-RimeCanonicalConfigPath
}

function Get-RimeCacheDefaultPath {
    if (-not [string]::IsNullOrWhiteSpace($CacheDirectory)) { return [IO.Path]::GetFullPath($CacheDirectory) }
    return Join-Path $env:LOCALAPPDATA 'config-rime/downloads'
}

function Get-RimeMarkedRootCandidate {
    $candidate = 'D:\ProgramData\Rime'
    $markerPath = Join-Path $candidate '.config-rime-root.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return '' }
    try {
        $marker = Read-RimeJson $markerPath
        if ($marker.format -eq 1 -and $marker.manager -eq 'config-rime') { return $candidate }
    } catch { }
    return ''
}

function Get-RimeManagedRootCandidate {
    try {
        $selector = Get-RimeWeaselUserDirectory
        if ([string]::IsNullOrWhiteSpace($selector)) { return '' }
        return (Get-RimeManagedRootsFromSelector $selector | Select-Object -First 1)
    } catch { return '' }
}

function Resolve-RimeInstallRoot {
    $config = Get-RimeRequestedConfigPath
    $configured = ''
    if (Test-Path -LiteralPath $config -PathType Leaf) { $configured = Read-RimeConfiguredRoot $config }
    $managed = Get-RimeManagedRootCandidate
    $marked = Get-RimeMarkedRootCandidate
    $local = Join-Path $env:LOCALAPPDATA 'RimeProfiles'
    $resolved = Resolve-RimeRoot $RimeRoot $configured $managed $marked $local
    if ([string]::IsNullOrWhiteSpace($resolved)) { throw 'Unable to resolve RIME root' }
    return [IO.Path]::GetFullPath($resolved)
}

function Ensure-RimeConfigDirectory([string]$Path) {
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    Ensure-RimePlainDirectory $parent | Out-Null
}

function Write-RimeRootConfig([string]$Path, [string]$Root) {
    Ensure-RimeConfigDirectory $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = Read-RimeConfiguredRoot $Path
        if ([IO.Path]::GetFullPath($existing) -ine [IO.Path]::GetFullPath($Root)) {
            throw "Existing RIME config points elsewhere: $existing"
        }
    }
    Write-RimeJson $Path ([ordered]@{
        format = 1
        root = $Root
        manager = 'config-rime'
        updatedAt = [DateTime]::UtcNow.ToString('o')
    })
}

function Write-RimeConfigFiles([string]$Root) {
    $requested = Get-RimeRequestedConfigPath
    $canonical = Get-RimeCanonicalConfigPath
    Write-RimeRootConfig $requested $Root
    if ([IO.Path]::GetFullPath($requested) -ine [IO.Path]::GetFullPath($canonical)) {
        Write-RimeRootConfig $canonical $Root
    }
}

function Get-RimeWeaselBinaryVersion([string]$Path) {
    $Path = Assert-RimePlainExistingFile $Path 'Weasel binary'
    $versionInfo = (Get-Item -LiteralPath $Path -Force).VersionInfo
    if ($null -ne $versionInfo.FileVersionRaw) { return $versionInfo.FileVersionRaw.ToString() }
    if (-not [string]::IsNullOrWhiteSpace([string]$versionInfo.FileVersion)) { return [string]$versionInfo.FileVersion }
    throw "Weasel binary version unavailable: $Path"
}

function Assert-RimeWeaselRuntime([string]$InstallDirectory, [string]$ExpectedVersion = '0.17.4') {
    if ([string]::IsNullOrWhiteSpace($InstallDirectory)) { throw 'Weasel install directory is required' }
    $full = Get-RimeWeaselInstallDirectory $InstallDirectory
    foreach ($name in @('WeaselServer.exe', 'WeaselDeployer.exe')) {
        $path = Join-Path $full $name
        $actual = Get-RimeWeaselBinaryVersion $path
        if (-not (Test-RimeVersionMatch $actual $ExpectedVersion)) {
            throw "Weasel runtime version mismatch for ${name}: expected $ExpectedVersion, got $actual"
        }
    }
    return $full
}

function Get-RimeInstalledWeaselDirectory([string]$ExplicitDirectory) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitDirectory)) {
        return Assert-RimeWeaselRuntime $ExplicitDirectory '0.17.4'
    }
    try {
        $candidate = Get-RimeWeaselInstallDirectory ''
        return Assert-RimeWeaselRuntime $candidate '0.17.4'
    } catch { return '' }
}

function Invoke-RimeElevatedInstaller([string]$InstallerPath, [string]$Arguments, [string]$ExpectedSha256) {
    $InstallerPath = Assert-RimePlainExistingFile $InstallerPath 'Weasel installer'
    Assert-RimePinnedHash $InstallerPath $ExpectedSha256
    $InstallerPath = Assert-RimePlainExistingFile $InstallerPath 'Weasel installer'
    Assert-RimePinnedHash $InstallerPath $ExpectedSha256
    $process = Start-Process -FilePath $InstallerPath -ArgumentList @($Arguments) -Verb RunAs -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) { throw "Weasel installer failed with exit code $($process.ExitCode)" }
}

function Ensure-RimeWeaselRuntime([string]$CachePath) {
    $existing = Get-RimeInstalledWeaselDirectory $WeaselInstallDirectory
    if ($existing) { return [pscustomobject]@{ Status = 'existing'; Directory = $existing } }
    if (-not [string]::IsNullOrWhiteSpace($WeaselInstallDirectory)) {
        throw "Explicit Weasel 0.17.4 runtime is invalid: $WeaselInstallDirectory"
    }
    if ($SkipWeaselInstall) { throw 'Weasel 0.17.4 runtime not found and -SkipWeaselInstall was supplied' }
    $lock = Read-RimeJson (Join-Path $script:WindowsDirectory 'manifests/rime.lock.json')
    if ($lock.weasel.version -ne '0.17.4') { throw "Unexpected pinned Weasel version: $($lock.weasel.version)" }
    $installer = Get-RimeSourceArchive $lock.weasel $CachePath 'weasel'
    Write-RimeInstallLog 'Installing Weasel 0.17.4 with UAC for machine-level runtime'
    Invoke-RimeElevatedInstaller $installer ([string]$lock.weasel.installArgs) ([string]$lock.weasel.sha256)
    $installed = Get-RimeInstalledWeaselDirectory ''
    if (-not $installed) { throw 'Weasel installer completed but exact runtime verification failed' }
    return [pscustomobject]@{ Status = 'installed'; Directory = $installed }
}

function Get-RimeSelectorInfo([string]$Root) {
    $selector = Get-RimeSelectorPath $Root
    if (-not (Test-Path -LiteralPath $selector)) {
        return [pscustomobject]@{ Exists = $false; Target = $null; LegacyProfile = $null }
    }
    $target = Get-RimeJunctionTarget $selector
    try {
        Assert-RimeManagedTarget $selector $target
        return [pscustomobject]@{ Exists = $true; Target = $target; LegacyProfile = $null }
    } catch {
        $profile = Get-RimeProfileFromLegacyTarget $Root $target
        return [pscustomobject]@{ Exists = $true; Target = $target; LegacyProfile = $profile }
    }
}

function Prepare-RimeRoot([string]$Root, [string]$OwnerSid) {
    # Ownership gate first. Never create, grant, or elevate an ACL on a root that an
    # existing marker attributes to a different SID: the grant is recursive and
    # would run before the ownership check that is supposed to refuse it.
    $marker = Get-RimeRootMarker $Root
    if ($null -ne $marker) { Assert-RimeMarker $Root $OwnerSid }
    Ensure-RimeModifyAccess $Root $OwnerSid
    $marker = Get-RimeRootMarker $Root
    $legacy = @(Find-RimeLegacyLayout $Root)
    if ($legacy -contains 'RimeConfig') {
        throw 'Legacy RimeConfig is an ordinary directory; move or review it manually before installing a managed Junction'
    }
    $selectorInfo = Get-RimeSelectorInfo $Root
    $hasLegacy = $legacy.Count -gt 0 -or $null -ne $selectorInfo.LegacyProfile

    if ($null -eq $marker) {
        if ($hasLegacy -and -not $BackupLegacy) {
            throw 'Unmarked legacy RIME layout found; rerun with -BackupLegacy to create a recovery copy before adoption'
        }
        if ($hasLegacy) {
            $backup = Backup-RimeLegacyState $Root (Join-Path $Root 'backups') $selectorInfo
            Write-RimeInstallLog "Legacy backup created: $($backup.Path)"
        }
        New-RimeRootMarker $Root $OwnerSid | Out-Null
    } else {
        Assert-RimeMarker $Root $OwnerSid
    }

    Ensure-RimeRootLayout $Root $OwnerSid -AllowExistingMarker | Out-Null
    if ($hasLegacy -and $BackupLegacy) {
        $copy = Copy-RimeLegacyProfiles $Root
        if ($copy.Copied.Count -gt 0) { Write-RimeInstallLog ('Legacy profiles copied: ' + ($copy.Copied -join ', ')) }
    }
    if (-not (Test-RimeRootWriteAccess $Root)) { throw "RIME root is not writable: $Root" }
    return $selectorInfo
}

function Get-RimeRaycastControlDirectory {
    return Join-Path $env:LOCALAPPDATA 'config-rime/scripts'
}

function Invoke-RimeInstall {
    $ownerSid = Assert-RimeInstallContext
    $root = Resolve-RimeInstallRoot
    $cache = Get-RimeCacheDefaultPath
    Ensure-RimePlainDirectory $cache | Out-Null

    $selectorInfo = Prepare-RimeRoot $root $ownerSid
    Write-RimeConfigFiles $root
    $report = New-RimeInstallReport $root
    $installLock = $null
    try {
        $installLock = Enter-RimeNamedLockWait $root 'install.lock'
        $lock = Read-RimeJson (Join-Path $script:WindowsDirectory 'manifests/rime.lock.json')
        $runtime = $null
        try {
            $runtime = Ensure-RimeWeaselRuntime $cache
            Add-RimeInstallResult $report 'runtime' 'completed' "Weasel 0.17.4: $($runtime.Status)" | Out-Null
        } catch {
            Add-RimeInstallResult $report 'runtime' 'failed' $_.Exception.Message | Out-Null
        }

        foreach ($profile in @($Profiles | Select-Object -Unique)) {
            try {
                $source = Get-RimeSourceRootForProfile $profile ([bool]$MoqiFull) $cache $lock
                $destination = Get-RimeProfileDirectory $root $profile
                $managedManifest = Join-Path $destination 'managed-files.json'
                if ((Test-Path -LiteralPath $destination -PathType Container) -and -not (Test-Path -LiteralPath $managedManifest -PathType Leaf)) {
                    $seedFiles = @(Select-RimeSourceFiles $source (Get-RimeProfileSourcePatterns $profile ([bool]$MoqiFull)))
                    Initialize-RimeManagedManifestFromSource $source $destination $seedFiles $managedManifest | Out-Null
                }
                $result = Install-RimeProfileFromSource $source $root $profile ([bool]$MoqiFull)
                $status = if ($result.Conflicts.Count -gt 0) { 'manual_required' } else { 'completed' }
                $message = if ($result.Conflicts.Count -gt 0) { 'User-edited files preserved; review before deploy: ' + ($result.Conflicts -join ', ') } else { '' }
                Add-RimeInstallResult $report $profile $status $message | Out-Null
            } catch {
                Add-RimeInstallResult $report $profile 'failed' $_.Exception.Message | Out-Null
            }
        }

        $completed = @($report.Results | Where-Object { $_.Profile -in @('ice', 'mint', 'moqi') -and $_.Status -eq 'completed' } | ForEach-Object Profile)
        Invoke-RimeInstallComponent $report 'switch' {
            if ($SkipDeploy) {
                return [pscustomobject]@{ Status = 'manual_required'; Message = 'Deployment skipped; Registry and selector were not changed' }
            }
            if ($null -eq $runtime) {
                return [pscustomobject]@{ Status = 'failed'; Message = 'Deployment unavailable because exact Weasel 0.17.4 runtime validation failed' }
            }
            if ($completed.Count -eq 0) {
                return [pscustomobject]@{ Status = 'manual_required'; Message = 'No conflict-free profile is available for automatic deployment' }
            }
            $preferred = $InitialProfile
            if ([string]::IsNullOrWhiteSpace($preferred) -and $null -ne $selectorInfo.LegacyProfile -and $selectorInfo.LegacyProfile -in $completed) {
                $preferred = $selectorInfo.LegacyProfile
            }
            $initial = Get-RimeInitialProfile $preferred $Profiles $completed
            $transition = Invoke-RimeSelectorTransition (Get-RimeSelectorPath $root) {
                $adapter = New-RimeWindowsAdapter $root $runtime.Directory ([bool]$MoqiFull) ($null -ne $selectorInfo.LegacyProfile)
                Invoke-RimeProfileSwitch $root $initial $ownerSid $adapter $DeployMode $DeployTimeoutSeconds ([bool]$MoqiFull) -ForceDeploy | Out-Null
            }
            if ($transition.Status -eq 'completed') {
                return [pscustomobject]@{ Status = 'completed'; Message = "Active profile: $initial" }
            }
            if ($transition.Status -eq 'recovery_required') {
                return [pscustomobject]@{
                    Status = 'recovery_required'
                    Message = "Profile switch failed: $($transition.Error); Registry rollback requires recovery: $($transition.RecoveryError)"
                }
            }
            return [pscustomobject]@{
                Status = 'failed'
                Message = "Profile switch failed and Registry selector was restored: $($transition.Error)"
            }
        } | Out-Null

        Invoke-RimeInstallComponent $report 'control' {
            $control = Install-RimeControlFiles $script:WindowsDirectory $script:LibraryDirectory (Get-RimeRaycastControlDirectory)
            $controlMessage = if ($control.Conflicts.Count -gt 0) { 'User-edited control scripts preserved: ' + ($control.Conflicts -join ', ') } else { "Control scripts: $($control.Directory)" }
            return [pscustomobject]@{ Status = $control.Status; Message = $controlMessage }
        } | Out-Null

        if (-not $NoRaycast) {
            Invoke-RimeInstallComponent $report 'raycast' {
                return Install-RimeRaycastScripts (Join-Path $script:WindowsDirectory 'raycast') $RaycastScriptDir
            } | Out-Null
        }
    } finally {
        if ($null -ne $installLock) { $installLock.Dispose() }
        Save-RimeInstallReport $report $root | Out-Null
    }
    return $report
}

try {
    $result = Invoke-RimeInstall
    if ($PassThru) { $result | ConvertTo-Json -Depth 20 }
    $failed = @($result.Results | Where-Object { $_.Status -in @('failed', 'recovery_required') })
    if ($failed.Count -gt 0) { exit 1 }
} catch {
    Write-Error $_
    exit 1
}
