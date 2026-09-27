#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-RimeWindows11([string]$ProductName, [string]$BuildNumber) {
    if ([string]::IsNullOrWhiteSpace($ProductName)) { return $false }
    # Windows Server shares Windows 11 build numbers; reject it by name.
    if ($ProductName -match '(?i)\bServer\b') { return $false }
    # Microsoft never updated the registry ProductName on most Windows 11
    # installs: it still reads "Windows 10 ...". Accept either product name and
    # let the build number discriminate, because Windows 10 tops out at 19045.
    if ($ProductName -notmatch '(?i)\bWindows 1[01]\b') { return $false }
    $build = 0
    if (-not [int]::TryParse($BuildNumber, [ref]$build)) { return $false }
    return $build -ge 22000
}

function Get-RimeWindowsHostInfo {
    $platform = [Environment]::OSVersion.Platform
    $productName = ''
    $buildNumber = ''
    if ($platform -eq [PlatformID]::Win32NT) {
        try {
            $currentVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $productName = [string]$currentVersion.ProductName
            $buildNumber = [string]$currentVersion.CurrentBuildNumber
        } catch {
            throw "Unable to determine Windows product/build: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        Platform = $platform
        ProductName = $productName
        BuildNumber = $buildNumber
        Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
        Is64BitProcess = [Environment]::Is64BitProcess
        PowerShellMajor = [int]$PSVersionTable.PSVersion.Major
    }
}

function Test-RimeWindowsHost {
    $info = Get-RimeWindowsHostInfo
    return $info.Platform -eq [PlatformID]::Win32NT -and
        [bool]$info.Is64BitOperatingSystem -and
        (Test-RimeWindows11 ([string]$info.ProductName) ([string]$info.BuildNumber))
}

function Assert-RimeWindowsHost {
    $info = Get-RimeWindowsHostInfo
    if ($info.Platform -ne [PlatformID]::Win32NT) { throw 'Windows 11 x64 is required for this operation' }
    if (-not (Test-RimeWindows11 ([string]$info.ProductName) ([string]$info.BuildNumber))) {
        throw "Windows 11 build 22000 or later is required; detected $($info.ProductName) build $($info.BuildNumber)"
    }
    if (-not [bool]$info.Is64BitOperatingSystem) { throw '64-bit Windows is required' }
    # Deliberately emit nothing: callers use this as a guard, and a leaked host
    # info object corrupts their return values (for example Get-RimeCurrentSid).
}

function Assert-RimePowerShell7X64 {
    $info = Get-RimeWindowsHostInfo
    if ([int]$info.PowerShellMajor -lt 7 -or -not [bool]$info.Is64BitProcess) {
        throw '64-bit PowerShell 7 is required'
    }
    # See Assert-RimeWindowsHost: guard only, never pipeline output.
}

function Get-RimeCurrentSid {
    Assert-RimeWindowsHost
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) { throw 'Current Windows SID unavailable' }
    return $identity.User.Value
}

function Assert-RimeOwnerContext([string]$OwnerSid) {
    $current = Get-RimeCurrentSid
    if ([string]::IsNullOrWhiteSpace($OwnerSid) -or $current -ne $OwnerSid) {
        throw "Current user SID does not match managed owner: $current"
    }
    if ($current -eq 'S-1-5-18') { throw 'SYSTEM context is not allowed for daily RIME switching' }
}

function Convert-RimeAccountToSid([string]$Account) {
    if ([string]::IsNullOrWhiteSpace($Account)) { return $null }
    try {
        return ([Security.Principal.NTAccount]$Account).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Normalize-RimeWindowsPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full -eq $root) { return $full }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Get-RimeCurrentSessionId {
    # Isolated so process enumeration stays testable off-Windows, where
    # Process.SessionId is not supported.
    return [Diagnostics.Process]::GetCurrentProcess().SessionId
}

function Get-RimeTrustedPowerShellHostFromFacts($Facts) {
    if ($null -eq $Facts) { throw 'Trusted PowerShell host facts are required' }
    $processPathProperty = $Facts.PSObject.Properties['ProcessPath']
    $psHomePathProperty = $Facts.PSObject.Properties['PSHomePath']
    $signatureStatusProperty = $Facts.PSObject.Properties['SignatureStatus']
    $signerSubjectProperty = $Facts.PSObject.Properties['SignerSubject']
    if ($null -eq $processPathProperty -or $null -eq $psHomePathProperty -or
        $null -eq $signatureStatusProperty -or $null -eq $signerSubjectProperty) {
        throw 'Trusted PowerShell host facts are incomplete'
    }
    $processPath = [string]$processPathProperty.Value
    $psHomePath = [string]$psHomePathProperty.Value
    if ([string]::IsNullOrWhiteSpace($processPath) -or [string]::IsNullOrWhiteSpace($psHomePath)) {
        throw 'Trusted PowerShell host path is unavailable'
    }
    Assert-RimePlainPath $processPath
    Assert-RimePlainPath $psHomePath
    $normalizedProcess = Normalize-RimeWindowsPath $processPath
    $normalizedPsHome = Normalize-RimeWindowsPath $psHomePath
    if ((Split-Path -Leaf $normalizedProcess) -ine 'pwsh.exe' -or (Split-Path -Leaf $normalizedPsHome) -ine 'pwsh.exe') {
        throw 'Trusted PowerShell host must be pwsh.exe'
    }
    if ($normalizedProcess -ine $normalizedPsHome) {
        throw 'Current PowerShell process does not match PSHOME pwsh.exe'
    }
    if (-not (Test-Path -LiteralPath $normalizedProcess -PathType Leaf)) {
        throw "Trusted PowerShell host is missing: $normalizedProcess"
    }
    $item = Get-Item -LiteralPath $normalizedProcess -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Trusted PowerShell host is unsafe: $normalizedProcess"
    }
    if ([string]$signatureStatusProperty.Value -ne 'Valid' -or
        [string]$signerSubjectProperty.Value -notmatch '(?i)(?:^|,\s*)CN=Microsoft Corporation(?:,|$)') {
        throw 'Trusted PowerShell host signature is invalid'
    }
    return $normalizedProcess
}

function Get-RimeTrustedPowerShellHost {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $processPath = [string]$process.Path
    if ([string]::IsNullOrWhiteSpace($processPath)) { throw 'Current PowerShell executable path is unavailable' }
    $signature = Get-AuthenticodeSignature -FilePath $processPath -ErrorAction Stop
    $subject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
    return Get-RimeTrustedPowerShellHostFromFacts ([pscustomobject]@{
        ProcessPath = $processPath
        PSHomePath = Join-Path $PSHOME 'pwsh.exe'
        SignatureStatus = [string]$signature.Status
        SignerSubject = $subject
    })
}

function Get-RimeRootMarker([string]$Root) {
    $path = Join-Path $Root '.config-rime-root.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Read-RimeJson $path
}

function New-RimeRootMarker([string]$Root, [string]$OwnerSid) {
    if ([string]::IsNullOrWhiteSpace($OwnerSid)) { throw 'Owner SID required for root marker' }
    Ensure-RimePlainDirectory $Root | Out-Null
    $marker = [ordered]@{
        format = 1
        manager = 'config-rime'
        ownerSid = $OwnerSid
        createdAt = [DateTime]::UtcNow.ToString('o')
    }
    Write-RimeNewJson (Join-Path $Root '.config-rime-root.json') $marker 'RIME root marker'
    return [pscustomobject]$marker
}

function Find-RimeLegacyLayout([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $names = @('Rime_Ice', 'Rime_Mint', 'Rime_Moqi', 'RimeConfig')
    $found = New-Object Collections.Generic.List[string]
    foreach ($name in $names) {
        $path = Join-Path $Root $name
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [void]$found.Add($name) }
        }
    }
    return @($found)
}

function Assert-RimeManagedTarget([string]$Link, [string]$Target) {
    $root = Split-Path -Parent $Link
    $normalizedTarget = Normalize-RimeWindowsPath $Target
    $allowed = @(
        (Normalize-RimeWindowsPath (Join-Path $root 'profiles/Rime_Ice')),
        (Normalize-RimeWindowsPath (Join-Path $root 'profiles/Rime_Mint')),
        (Normalize-RimeWindowsPath (Join-Path $root 'profiles/Rime_Moqi'))
    )
    if (-not ($allowed | Where-Object { $_ -ieq $normalizedTarget })) {
        throw "Junction target is outside managed profiles: $Target"
    }
}

function Assert-RimeLegacyTarget([string]$Link, [string]$Target) {
    $root = Split-Path -Parent $Link
    $normalizedTarget = Normalize-RimeWindowsPath $Target
    $allowed = @(
        (Normalize-RimeWindowsPath (Join-Path $root 'Rime_Ice')),
        (Normalize-RimeWindowsPath (Join-Path $root 'Rime_Mint')),
        (Normalize-RimeWindowsPath (Join-Path $root 'Rime_Moqi'))
    )
    if (-not ($allowed | Where-Object { $_ -ieq $normalizedTarget })) {
        throw "Junction target is outside known legacy profiles: $Target"
    }
}

function Assert-RimeSelectorTarget([string]$Link, [string]$Target, [bool]$AllowLegacyTarget = $false) {
    try { Assert-RimeManagedTarget $Link $Target; return }
    catch {
        if (-not $AllowLegacyTarget) { throw }
    }
    Assert-RimeLegacyTarget $Link $Target
}

function Get-RimeProfileFromLegacyTarget([string]$Root, [string]$Target) {
    $selector = Join-Path $Root 'RimeConfig'
    Assert-RimeLegacyTarget $selector $Target
    foreach ($mapping in @(
        @{ Name = 'ice'; Directory = 'Rime_Ice' },
        @{ Name = 'mint'; Directory = 'Rime_Mint' },
        @{ Name = 'moqi'; Directory = 'Rime_Moqi' }
    )) {
        if ((Normalize-RimeWindowsPath (Join-Path $Root $mapping.Directory)) -ieq (Normalize-RimeWindowsPath $Target)) {
            return $mapping.Name
        }
    }
    throw "Legacy selector target cannot be mapped: $Target"
}

function Assert-RimeSelectorLinkPath([string]$Link) {
    if ([string]::IsNullOrWhiteSpace($Link) -or -not [IO.Path]::IsPathRooted($Link)) {
        throw 'RIME selector link path must be absolute'
    }
    try { $full = [IO.Path]::GetFullPath($Link) }
    catch { throw "Invalid RIME selector link path: $Link" }
    if ((Split-Path -Leaf $full) -ine 'RimeConfig') { throw "Unexpected RIME selector link path: $Link" }
    $parent = Assert-RimePlainExistingDirectory (Split-Path -Parent $full) 'RIME selector link parent directory'
    return Join-Path $parent 'RimeConfig'
}

function Get-RimeJunctionTarget([string]$Link) {
    if (-not (Test-Path -LiteralPath $Link)) { return $null }
    $item = Get-Item -LiteralPath $Link -Force
    if (-not ($item.PSIsContainer) -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "RimeConfig is not a Junction: $Link"
    }
    if ($item.PSObject.Properties.Name -contains 'LinkType' -and $item.LinkType -ne 'Junction') {
        throw "RimeConfig reparse point is not a Junction: $Link"
    }
    $target = @($item.Target) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
    if ($null -eq $target) { throw "Junction target unavailable: $Link" }
    return Normalize-RimeWindowsPath ([string]$target)
}

function Assert-RimeJunction([string]$Link, [string]$ExpectedTarget) {
    $actual = Get-RimeJunctionTarget $Link
    if ($null -eq $actual) { throw "Junction missing: $Link" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedTarget) -and $actual -ine (Normalize-RimeWindowsPath $ExpectedTarget)) {
        throw "Junction target mismatch: expected $ExpectedTarget, got $actual"
    }
    return $actual
}

function New-RimeJunction([string]$Link, [string]$Target, [bool]$AllowLegacyTarget = $false) {
    Assert-RimeWindowsHost
    $Link = Assert-RimeSelectorLinkPath $Link
    if (Test-Path -LiteralPath $Link) { throw "Junction already exists: $Link" }
    $Target = Assert-RimePlainExistingDirectory $Target 'RIME Junction target directory'
    Assert-RimeSelectorTarget $Link $Target $AllowLegacyTarget
    $parent = Assert-RimePlainExistingDirectory (Split-Path -Parent $Link) 'RIME Junction parent directory'
    $Link = Join-Path $parent 'RimeConfig'
    $Target = Assert-RimePlainExistingDirectory $Target 'RIME Junction target directory'
    if (Test-Path -LiteralPath $Link) { throw "Junction appeared during creation: $Link" }
    New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
    Assert-RimeJunction $Link $Target | Out-Null
}

function Remove-RimeJunction([string]$Link, [string]$ExpectedTarget) {
    Assert-RimeWindowsHost
    $Link = Assert-RimeSelectorLinkPath $Link
    Assert-RimeJunction $Link $ExpectedTarget | Out-Null
    Assert-RimeJunction $Link $ExpectedTarget | Out-Null
    Remove-Item -LiteralPath $Link -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Link) { throw "Failed to remove Junction: $Link" }
}

function Recover-RimeJunctionTransaction([string]$Root, [string]$TransactionId, [bool]$AllowLegacyTarget = $false) {
    if ($TransactionId -notmatch '^[A-Za-z0-9-]+$') { throw "Invalid Junction transaction ID: $TransactionId" }
    Assert-RimePlainPath $Root
    $selector = Get-RimeSelectorPath $Root
    $backup = Join-Path $Root ('.RimeConfig.' + $TransactionId + '.previous')
    if (-not (Test-Path -LiteralPath $backup)) {
        return [pscustomobject]@{ Status = 'none'; Transaction = $TransactionId }
    }
    try {
        $previousTarget = Get-RimeJunctionTarget $backup
        Assert-RimeSelectorTarget $selector $previousTarget $AllowLegacyTarget
    } catch {
        throw "Pending selector backup is not a managed Junction: $backup ($($_.Exception.Message))"
    }
    $statePath = Join-Path $Root 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Pending Junction transaction has no state journal: $backup"
    }
    $state = Read-RimeJson $statePath
    if ([string]$state.transaction -ne $TransactionId) {
        throw "Pending Junction transaction does not match state journal: $backup"
    }
    if ([string]$state.status -eq 'completed' -and (Test-Path -LiteralPath $selector)) {
        $currentTarget = Get-RimeJunctionTarget $selector
        Assert-RimeManagedTarget $selector $currentTarget
        if ([string]$state.target -and [IO.Path]::GetFullPath($currentTarget) -ine [IO.Path]::GetFullPath([string]$state.target)) {
            throw "Completed Junction transaction points to unexpected selector target: $selector"
        }
        Assert-RimeJunction $backup $previousTarget | Out-Null
        Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
        return [pscustomobject]@{ Status = 'cleanup'; Transaction = $TransactionId; Previous = $previousTarget; Target = $currentTarget }
    }
    if (Test-Path -LiteralPath $selector) {
        $currentTarget = Get-RimeJunctionTarget $selector
        Assert-RimeSelectorTarget $selector $currentTarget $false
        Remove-Item -LiteralPath $selector -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $selector) { throw "Junction selector appeared during recovery: $selector" }
    Move-Item -LiteralPath $backup -Destination $selector -ErrorAction Stop
    Assert-RimeJunction $selector $previousTarget | Out-Null
    return [pscustomobject]@{ Status = 'recovered'; Transaction = $TransactionId; Previous = $previousTarget }
}

function Recover-RimeJunctionTransactions([string]$Root, [bool]$AllowLegacyTarget = $false) {
    Assert-RimePlainPath $Root
    $results = New-Object Collections.Generic.List[object]
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\.RimeConfig\.([A-Za-z0-9-]+)\.previous$' })) {
        $transaction = $item.Name -replace '^\.RimeConfig\.([A-Za-z0-9-]+)\.previous$', '$1'
        [void]$results.Add((Recover-RimeJunctionTransaction $Root $transaction $AllowLegacyTarget))
    }
    return $results.ToArray()
}

function Complete-RimeJunctionTransaction([string]$Link, [string]$Target, [string]$TransactionId, [bool]$AllowLegacyTarget = $false) {
    Assert-RimeWindowsHost
    if ($TransactionId -notmatch '^[A-Za-z0-9-]+$') { throw "Invalid Junction transaction ID: $TransactionId" }
    $Link = Assert-RimeSelectorLinkPath $Link
    $root = Split-Path -Parent $Link
    $backup = Join-Path $root ('.RimeConfig.' + $TransactionId + '.previous')
    if (-not (Test-Path -LiteralPath $backup)) { return }
    $current = Assert-RimeJunction $Link $Target
    Assert-RimeSelectorTarget $Link $current $AllowLegacyTarget
    Assert-RimeJunction $backup $null | Out-Null
    Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
}

function Set-RimeJunctionTarget([string]$Link, [string]$Target, [string]$TransactionId, [bool]$AllowLegacyTarget = $false) {
    Assert-RimeWindowsHost
    if ($TransactionId -notmatch '^[A-Za-z0-9-]+$') { throw "Invalid Junction transaction ID: $TransactionId" }
    $Link = Assert-RimeSelectorLinkPath $Link
    $root = Split-Path -Parent $Link
    $Target = Assert-RimePlainExistingDirectory $Target 'RIME selector target directory'
    Assert-RimeSelectorTarget $Link $Target $AllowLegacyTarget
    $oldTarget = $null
    $backup = Join-Path $root ('.RimeConfig.' + $TransactionId + '.previous')
    if (Test-Path -LiteralPath $backup) { throw "Unresolved Junction transaction exists: $backup" }
    if (Test-Path -LiteralPath $Link) {
        $oldTarget = Assert-RimeJunction $Link $null
        Assert-RimeSelectorTarget $Link $oldTarget $AllowLegacyTarget
        if ($oldTarget -ieq (Normalize-RimeWindowsPath $Target)) { return $oldTarget }
        if (Test-Path -LiteralPath $backup) { throw "Junction backup appeared during switch: $backup" }
        Move-Item -LiteralPath $Link -Destination $backup -ErrorAction Stop
    }
    try {
        New-RimeJunction $Link $Target $AllowLegacyTarget
        return $oldTarget
    } catch {
        $failure = $_.Exception.Message
        try {
            if (Test-Path -LiteralPath $Link) {
                $newTarget = Get-RimeJunctionTarget $Link
                Remove-RimeJunction $Link $newTarget
            }
            if (Test-Path -LiteralPath $backup) {
                if (Test-Path -LiteralPath $Link) { throw "Junction selector appeared during recovery: $Link" }
                Move-Item -LiteralPath $backup -Destination $Link -ErrorAction Stop
            }
        } catch { throw "Junction switch failed and recovery failed: $failure; $($_.Exception.Message)" }
        throw $failure
    }
}

function Test-RimeVersionMatch([string]$Actual, [string]$Expected) {
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    if ($Expected -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') { throw "Invalid pinned version: $Expected" }
    $expectedParts = @([int]$Matches.major, [int]$Matches.minor, [int]$Matches.patch)
    if ($Actual.Trim() -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:\.(?<build>\d+))?(?:[+-].*)?$') { return $false }
    $actualParts = @([int]$Matches.major, [int]$Matches.minor, [int]$Matches.patch)
    for ($index = 0; $index -lt 3; $index++) {
        if ($actualParts[$index] -ne $expectedParts[$index]) { return $false }
    }
    return -not $Matches.ContainsKey('build') -or [int]$Matches['build'] -eq 0
}

function Get-RimeWeaselInstallDirectory([string]$ExplicitDirectory) {
    $candidate = $ExplicitDirectory
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        # Weasel 0.17.4 is a 32-bit installer and writes its machine key under
        # WOW6432Node, invisible to this 64-bit process through the native view.
        # Read the property defensively: member access on a missing registry value
        # is an error under Set-StrictMode -Version Latest, not $null.
        foreach ($registryPath in @('HKLM:\Software\Rime\Weasel', 'HKLM:\Software\WOW6432Node\Rime\Weasel')) {
            $registered = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
            if ($null -eq $registered) { continue }
            # WeaselRoot points at the versioned runtime directory that holds
            # WeaselServer.exe; InstallDir is the parent and is only a fallback.
            foreach ($valueName in @('WeaselRoot', 'InstallDir')) {
                $property = $registered.PSObject.Properties[$valueName]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $candidate = [string]$property.Value
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { throw 'Weasel InstallDir not found; install Weasel 0.17.4 first' }
    $full = Normalize-RimeWindowsPath $candidate
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Weasel InstallDir missing: $full" }
    Assert-RimePlainPath $full
    return $full
}

function Get-RimeWeaselUserDirectorySnapshot {
    Assert-RimeWindowsHost
    $path = 'HKCU:\Software\Rime\Weasel'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    $properties = Get-ItemProperty -Path $path -ErrorAction Stop
    $property = $properties.PSObject.Properties['RimeUserDir']
    if ($null -eq $property) {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    return [pscustomobject]@{ Exists = $true; Value = [string]$property.Value }
}

function Test-RimeWeaselUserDirectorySnapshotMatch($Expected, $Actual) {
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    foreach ($snapshot in @($Expected, $Actual)) {
        if ($null -eq $snapshot.PSObject.Properties['Exists']) { return $false }
    }
    if ([bool]$Expected.Exists -ne [bool]$Actual.Exists) { return $false }
    if (-not [bool]$Expected.Exists) { return $true }
    if ($null -eq $Expected.PSObject.Properties['Value'] -or $null -eq $Actual.PSObject.Properties['Value']) { return $false }
    return [string]$Expected.Value -ceq [string]$Actual.Value
}

function Assert-RimeSelectorRegistryPath([string]$Selector) {
    if ([string]::IsNullOrWhiteSpace($Selector) -or -not [IO.Path]::IsPathRooted($Selector)) {
        throw 'RIME selector path must be absolute'
    }
    try { $full = [IO.Path]::GetFullPath($Selector) }
    catch { throw "Invalid RIME selector path: $Selector" }
    if ((Split-Path -Leaf $full) -ine 'RimeConfig') { throw "Unexpected RIME selector path: $Selector" }
    $parent = Assert-RimePlainExistingDirectory (Split-Path -Parent $full) 'RIME selector parent directory'
    $full = Join-Path $parent 'RimeConfig'
    [void]@(Get-RimeManagedRootsFromSelector $full)
    if (Test-Path -LiteralPath $full) {
        $target = Get-RimeJunctionTarget $full
        Assert-RimeSelectorTarget $full $target $true
    }
    return $full
}

function Set-RimeWeaselUserDirectory([string]$Selector) {
    Assert-RimeWindowsHost
    $full = Assert-RimeSelectorRegistryPath $Selector
    New-Item -Path 'HKCU:\Software\Rime\Weasel' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir -Value $full -Type String
    $actual = Get-RimeWeaselUserDirectorySnapshot
    if (-not $actual.Exists -or (Normalize-RimeWindowsPath ([string]$actual.Value)) -ine $full) {
        throw 'RimeUserDir registry verification failed'
    }
}

function Restore-RimeWeaselUserDirectorySnapshot($Snapshot) {
    Assert-RimeWindowsHost
    if ($null -eq $Snapshot -or $null -eq $Snapshot.PSObject.Properties['Exists']) {
        throw 'RimeUserDir registry snapshot is invalid'
    }
    $path = 'HKCU:\Software\Rime\Weasel'
    if ([bool]$Snapshot.Exists) {
        if ($null -eq $Snapshot.PSObject.Properties['Value']) { throw 'RimeUserDir registry snapshot value is missing' }
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name RimeUserDir -Value ([string]$Snapshot.Value) -Type String
    } else {
        $current = Get-RimeWeaselUserDirectorySnapshot
        if ($current.Exists) {
            Remove-ItemProperty -Path $path -Name RimeUserDir -ErrorAction Stop
        }
    }
    $actual = Get-RimeWeaselUserDirectorySnapshot
    if (-not (Test-RimeWeaselUserDirectorySnapshotMatch $Snapshot $actual)) {
        throw 'RimeUserDir registry rollback verification failed'
    }
    return $actual
}

function Get-RimeWeaselUserDirectory {
    $snapshot = Get-RimeWeaselUserDirectorySnapshot
    if (-not $snapshot.Exists -or [string]::IsNullOrWhiteSpace([string]$snapshot.Value)) { return $null }
    return Normalize-RimeWindowsPath ([string]$snapshot.Value)
}

function Invoke-RimeSelectorTransition([string]$Selector, [scriptblock]$Action) {
    if ([string]::IsNullOrWhiteSpace($Selector)) { throw 'New RimeUserDir selector is required' }
    if ($null -eq $Action) { throw 'Rime selector transition action is required' }
    $previous = Get-RimeWeaselUserDirectorySnapshot
    try {
        Set-RimeWeaselUserDirectory $Selector
        & $Action
        return [pscustomobject]@{ Status = 'completed'; Previous = $previous; Error = $null; RecoveryError = $null }
    } catch {
        $failure = $_.Exception.Message
        try {
            Restore-RimeWeaselUserDirectorySnapshot $previous | Out-Null
            return [pscustomobject]@{ Status = 'failed'; Previous = $previous; Error = $failure; RecoveryError = $null }
        } catch {
            return [pscustomobject]@{ Status = 'recovery_required'; Previous = $previous; Error = $failure; RecoveryError = $_.Exception.Message }
        }
    }
}

function Assert-RimeAclRootPath([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root) -or $Root -notmatch '^[A-Za-z]:[\\/]') {
        throw 'ACL root path must be an absolute local drive directory'
    }
    if ($Root -match '^[A-Za-z]:[\\/]*$') { throw 'ACL root path must not be a filesystem root' }
    Assert-RimePlainPath $Root
    try { $full = Normalize-RimeWindowsPath $Root }
    catch { throw "ACL root path is invalid: $Root" }
    $filesystemRoot = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($filesystemRoot) -or $full -ieq $filesystemRoot) {
        throw 'ACL root path must not be a filesystem root'
    }
    return $full
}

function New-RimeAclElevatedCommand([string]$Root, [string]$OwnerSid) {
    $Root = Assert-RimeAclRootPath $Root
    if ($OwnerSid -notmatch '^S-\d+(?:-\d+)+$') { throw 'ACL owner SID is invalid' }
    $payloadJson = @{ root = $Root; sid = $OwnerSid } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload'))
`$payload = `$payloadJson | ConvertFrom-Json
if (`$payload.sid -notmatch '^S-\d+(?:-\d+)+$') { throw 'Invalid SID payload' }
`$payloadRoot = [string]`$payload.root
if ([string]::IsNullOrWhiteSpace(`$payloadRoot) -or `$payloadRoot -notmatch '^[A-Za-z]:[\\/]' -or `$payloadRoot -match '^(?:\\\\|//|\\)' -or `$payloadRoot -match '[*?\[\]\x00-\x1f]') { throw 'Invalid root payload' }
if (`$payloadRoot -match '^[A-Za-z]:[\\/]*$') { throw 'Invalid root payload: filesystem root' }
`$payloadRemainder = `$payloadRoot.Substring(2)
if (`$payloadRemainder.Contains(':')) { throw 'Invalid root payload: alternate data stream' }
`$payloadSegments = @(`$payloadRemainder -split '[\\/]') | Where-Object { -not [string]::IsNullOrEmpty(`$_) }
foreach (`$segment in `$payloadSegments) {
    if (`$segment -in @('.', '..') -or `$segment -match '[. ]$' -or `$segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
        throw 'Invalid root payload: Windows path alias'
    }
}
`$payloadRoot = [IO.Path]::GetFullPath(`$payloadRoot)
`$payloadPathRoot = [IO.Path]::GetPathRoot(`$payloadRoot)
if ([string]::IsNullOrWhiteSpace(`$payloadPathRoot) -or `$payloadRoot -ieq `$payloadPathRoot) { throw 'Invalid root payload: filesystem root' }
`$cursor = `$payloadRoot
while (`$cursor) {
    if (Test-Path -LiteralPath `$cursor) {
        `$item = Get-Item -LiteralPath `$cursor -Force -ErrorAction Stop
        if (`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe ReparsePoint path: `$cursor" }
    }
    `$parent = [IO.Path]::GetDirectoryName(`$cursor)
    if ([string]::IsNullOrEmpty(`$parent) -or `$parent -eq `$cursor) { break }
    `$cursor = `$parent
}
function Assert-RimePayloadPlainDirectoryTree([string]`$Path) {
    `$root = [IO.Path]::GetFullPath(`$Path)
    if (-not (Test-Path -LiteralPath `$root -PathType Container)) { return }
    `$pending = New-Object 'System.Collections.Generic.Stack[string]'
    `$pending.Push(`$root)
    while (`$pending.Count -gt 0) {
        `$directory = `$pending.Pop()
        `$item = Get-Item -LiteralPath `$directory -Force -ErrorAction Stop
        if (`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe ReparsePoint path: `$directory" }
        foreach (`$child in @(Get-ChildItem -LiteralPath `$directory -Force -ErrorAction Stop)) {
            if (`$child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe ReparsePoint path: `$(`$child.FullName)" }
            if (`$child.PSIsContainer) { `$pending.Push(`$child.FullName) }
        }
    }
}
Assert-RimePayloadPlainDirectoryTree `$payloadRoot
if (-not (Test-Path -LiteralPath `$payloadRoot -PathType Container)) {
    New-Item -ItemType Directory -Path `$payloadRoot -Force -ErrorAction Stop | Out-Null
}
`$item = Get-Item -LiteralPath `$payloadRoot -Force -ErrorAction Stop
if (`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe ReparsePoint path: `$payloadRoot" }
Assert-RimePayloadPlainDirectoryTree `$payloadRoot
`$systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
if ([string]::IsNullOrWhiteSpace(`$systemDirectory)) { throw 'Windows system directory is unavailable' }
`$systemDirectory = [IO.Path]::GetFullPath(`$systemDirectory)
`$icaclsPath = [IO.Path]::GetFullPath((Join-Path `$systemDirectory 'icacls.exe'))
if ([IO.Path]::GetDirectoryName(`$icaclsPath) -ine `$systemDirectory) { throw 'Trusted icacls path is invalid' }
`$systemCursor = `$icaclsPath
while (`$systemCursor) {
    if (Test-Path -LiteralPath `$systemCursor) {
        `$systemItem = Get-Item -LiteralPath `$systemCursor -Force -ErrorAction Stop
        if (`$systemItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe ReparsePoint path: `$systemCursor" }
    }
    `$systemParent = [IO.Path]::GetDirectoryName(`$systemCursor)
    if ([string]::IsNullOrEmpty(`$systemParent) -or `$systemParent -eq `$systemCursor) { break }
    `$systemCursor = `$systemParent
}
`$icaclsItem = Get-Item -LiteralPath `$icaclsPath -Force -ErrorAction Stop
if (`$icaclsItem.PSIsContainer -or (`$icaclsItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Trusted icacls executable is unsafe' }
& `$icaclsPath `$payloadRoot /grant:r ("*{0}:(OI)(CI)M" -f `$payload.sid) /T /C
if (`$LASTEXITCODE -ne 0) { throw "icacls failed with exit code `$LASTEXITCODE" }
"@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
}

function Invoke-RimeElevatedRootAcl([string]$Root, [string]$OwnerSid) {
    Assert-RimeWindowsHost
    Assert-RimePowerShell7X64 | Out-Null
    $Root = Assert-RimeAclRootPath $Root
    $pwsh = Get-RimeTrustedPowerShellHost
    $encoded = New-RimeAclElevatedCommand $Root $OwnerSid
    $process = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) { throw "Elevated RIME ACL setup failed with exit code $($process.ExitCode)" }
}

function Test-RimeRootWriteAccess([string]$Root) {
    $probe = $null
    $probeOwned = $false
    $probeText = 'probe:' + [guid]::NewGuid().ToString('N')
    $writable = $false
    $clean = $true
    try {
        $Root = Assert-RimePlainExistingDirectory $Root 'RIME root write probe directory'
        $probe = Assert-RimePlainWriteTarget (Get-RimeChildPath $Root ('.config-rime-write-' + [guid]::NewGuid().ToString('N') + '.tmp'))
        if ([IO.File]::Exists($probe)) { return $false }
        $stream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $probeOwned = $true
        try {
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($probeText)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
        $probe = Assert-RimePlainExistingFile $probe 'RIME root write probe file'
        $writable = [IO.File]::Exists($probe)
    } catch { $writable = $false }
    finally {
        if ($probeOwned -and $null -ne $probe -and [IO.File]::Exists($probe)) {
            try {
                $probe = Assert-RimePlainExistingFile $probe 'RIME root write probe file'
                if ([IO.File]::ReadAllText($probe) -ceq $probeText) {
                    $probe = Assert-RimePlainExistingFile $probe 'RIME root write probe file'
                    if ([IO.File]::ReadAllText($probe) -ceq $probeText) { [IO.File]::Delete($probe) }
                }
                if ([IO.File]::Exists($probe)) { $clean = $false }
            } catch { $clean = $false }
        }
    }
    return $writable -and $clean
}

function Grant-RimeModifyAcl([string]$Root, [string]$OwnerSid) {
    Assert-RimeWindowsHost
    Assert-RimeOwnerContext $OwnerSid
    $Root = Assert-RimeAclRootPath $Root
    $acl = Get-Acl -LiteralPath $Root
    $sid = New-Object Security.Principal.SecurityIdentifier($OwnerSid)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'Modify', $inheritance, [Security.AccessControl.PropagationFlags]::None, 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Root -AclObject $acl
}

function Ensure-RimeModifyAccess([string]$Root, [string]$OwnerSid) {
    Assert-RimeWindowsHost
    Assert-RimeOwnerContext $OwnerSid
    # Safety validation stays outside permission fallbacks: invalid/reparse paths must never be elevated.
    $Root = Assert-RimeAclRootPath $Root
    # Never grant or elevate on a root that an existing marker attributes to another
    # SID. The grant is recursive and would otherwise run before the ownership check
    # that is supposed to refuse it.
    $marker = Get-RimeRootMarker $Root
    if ($null -ne $marker) { Assert-RimeMarker $Root $OwnerSid }
    try {
        Ensure-RimePlainDirectory $Root | Out-Null
        Grant-RimeModifyAcl $Root $OwnerSid
    } catch {
        # Revalidate after any failed create/ACL operation before crossing UAC.
        $Root = Assert-RimeAclRootPath $Root
        Invoke-RimeElevatedRootAcl $Root $OwnerSid
    }
    $Root = Assert-RimeAclRootPath $Root
    if (-not (Test-RimeRootWriteAccess $Root)) { throw "RIME root is not writable after ACL setup: $Root" }
}

function Get-RimeMatchingServerProcesses([string]$InstallDirectory, [string]$OwnerSid) {
    Assert-RimeWindowsHost
    $InstallDirectory = Assert-RimePlainExistingDirectory $InstallDirectory 'Weasel installation directory'
    $server = Assert-RimePlainExistingFile (Get-RimeChildPath $InstallDirectory 'WeaselServer.exe') 'WeaselServer executable'
    $expected = Normalize-RimeWindowsPath $server
    $session = Get-RimeCurrentSessionId
    $records = New-Object Collections.Generic.List[object]
    $unverified = 0
    foreach ($candidate in @(Get-Process -Name WeaselServer -ErrorAction SilentlyContinue)) {
        $candidateSession = $null
        try { $candidateSession = [int]$candidate.SessionId }
        catch { $unverified++; continue }
        # Another session's server is intentionally out of scope, not a failure.
        if ($candidateSession -ne $session) { continue }
        try {
            $process = Get-Process -Id $candidate.Id -IncludeUserName -ErrorAction Stop
            $path = Normalize-RimeWindowsPath (Assert-RimePlainExistingFile ([string]$process.Path) 'WeaselServer executable')
            $sid = Convert-RimeAccountToSid $process.UserName
            $started = $process.StartTime.ToUniversalTime()
            if ($path -ieq $expected -and $process.SessionId -eq $session -and $sid -eq $OwnerSid) {
                [void]$records.Add([pscustomobject]@{
                    Id = $process.Id
                    Path = $path
                    Sid = $sid
                    SessionId = $process.SessionId
                    StartTimeUtc = $started
                })
            }
        } catch { $unverified++ }
    }
    # An uninspectable current-session candidate may be ours. Reporting it as "no
    # matching server" would let a switch proceed against a running runtime.
    if ($unverified -gt 0) {
        throw "Cannot inspect $unverified current-session WeaselServer process(es); refusing to proceed without verified runtime identity"
    }
    # ToArray() rather than @(): PowerShell 7.6.6 rejects @() around a
    # List[object] with "Argument types do not match".
    return $records.ToArray()
}

function Get-RimeVerifiedServerProcess($Record, [string]$InstallDirectory, [string]$OwnerSid) {
    if ($null -eq $Record) { return $null }
    foreach ($property in @('Id', 'Path', 'Sid', 'SessionId', 'StartTimeUtc')) {
        if ($null -eq $Record.PSObject.Properties[$property]) { return $null }
    }
    try {
        $InstallDirectory = Assert-RimePlainExistingDirectory $InstallDirectory 'Weasel installation directory'
        $expected = Normalize-RimeWindowsPath (Assert-RimePlainExistingFile (Get-RimeChildPath $InstallDirectory 'WeaselServer.exe') 'WeaselServer executable')
        $session = Get-RimeCurrentSessionId
        $process = Get-Process -Id ([int]$Record.Id) -IncludeUserName -ErrorAction Stop
        $path = Normalize-RimeWindowsPath (Assert-RimePlainExistingFile ([string]$process.Path) 'WeaselServer executable')
        $sid = Convert-RimeAccountToSid $process.UserName
        $started = $process.StartTime.ToUniversalTime()
        $recordStarted = ([DateTime]$Record.StartTimeUtc).ToUniversalTime()
        if ($path -ine $expected -or $path -ine [string]$Record.Path -or
            $sid -ne $OwnerSid -or $sid -ne [string]$Record.Sid -or
            $process.SessionId -ne $session -or $process.SessionId -ne [int]$Record.SessionId -or
            $started.Ticks -ne $recordStarted.Ticks) {
            return $null
        }
        return $process
    } catch { return $null }
}

function Stop-RimeWeasel([string]$InstallDirectory, [string]$OwnerSid, [int]$TimeoutSeconds = 15) {
    Assert-RimeWindowsHost
    Assert-RimeOwnerContext $OwnerSid
    if ($TimeoutSeconds -lt 0) { throw 'Weasel stop timeout cannot be negative' }
    $matching = @(Get-RimeMatchingServerProcesses $InstallDirectory $OwnerSid)
    if ($matching.Count -eq 0) { return }
    # Named-pipe shutdown has no PID/SID/session selector and is intentionally unused.
    # Use only revalidated process objects so another session/user cannot receive a shutdown request.
    foreach ($record in $matching) {
        $process = Get-RimeVerifiedServerProcess $record $InstallDirectory $OwnerSid
        if ($null -eq $process) { continue }
        try {
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) { [void]$process.CloseMainWindow() }
        } catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-RimeMatchingServerProcesses $InstallDirectory $OwnerSid).Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    }
    foreach ($record in @(Get-RimeMatchingServerProcesses $InstallDirectory $OwnerSid)) {
        $process = Get-RimeVerifiedServerProcess $record $InstallDirectory $OwnerSid
        if ($null -eq $process) { continue }
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
    }
    if (@(Get-RimeMatchingServerProcesses $InstallDirectory $OwnerSid).Count -gt 0) {
        throw 'Unable to stop matching WeaselServer process'
    }
}

function Start-RimeWeasel([string]$InstallDirectory) {
    Assert-RimeWindowsHost
    $InstallDirectory = Assert-RimePlainExistingDirectory $InstallDirectory 'Weasel installation directory'
    $server = Assert-RimePlainExistingFile (Get-RimeChildPath $InstallDirectory 'WeaselServer.exe') 'WeaselServer executable'
    Start-Process -FilePath $server -WindowStyle Hidden -ErrorAction Stop | Out-Null
}

function Get-RimeDeployerStartOptions([string]$DeployMode) {
    switch ($DeployMode) {
        Interactive { return @{} }
        Quiet { return @{ ArgumentList = @('/deploy'); WindowStyle = 'Hidden' } }
        default { throw "DeployMode must be Interactive or Quiet: $DeployMode" }
    }
}

function Invoke-RimeDeployer([string]$InstallDirectory, [string]$DeployMode, [int]$TimeoutSeconds) {
    Assert-RimeWindowsHost
    $InstallDirectory = Assert-RimePlainExistingDirectory $InstallDirectory 'Weasel installation directory'
    $deployer = Assert-RimePlainExistingFile (Get-RimeChildPath $InstallDirectory 'WeaselDeployer.exe') 'WeaselDeployer executable'
    $start = @{ FilePath = $deployer; PassThru = $true; ErrorAction = 'Stop' }
    foreach ($entry in (Get-RimeDeployerStartOptions $DeployMode).GetEnumerator()) { $start[$entry.Key] = $entry.Value }
    $process = Start-Process @start
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250; $process.Refresh() }
    if (-not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
        throw "manual_required: Weasel deployment timed out after $TimeoutSeconds seconds"
    }
    if ($process.ExitCode -ne 0) { throw "Weasel deployment failed with exit code $($process.ExitCode)" }
}

function Get-RimePrismArtifacts($Definition) {
    if ($null -ne $Definition.PSObject.Properties['PrismArtifacts']) { return @($Definition.PrismArtifacts) }
    return @($Definition.Schemas)
}

function Invoke-RimeDeploy([string]$InstallDirectory, [string]$ProfileDirectory, [string]$Profile, [bool]$MoqiFull, [string]$DeployMode, [int]$TimeoutSeconds, $Before, [DateTime]$StartedAt) {
    $definition = Get-RimeProfileDefinition $Profile $MoqiFull
    Invoke-RimeDeployer $InstallDirectory $DeployMode $TimeoutSeconds
    Assert-RimeBuildArtifacts $ProfileDirectory (Get-RimePrismArtifacts $definition) $definition.Dictionaries $Before $StartedAt
}

function New-RimeStatusAdapter {
    return [pscustomobject]@{
        GetActive = { param($selector) Get-RimeJunctionTarget $selector }
    }
}

function New-RimeWindowsAdapter(
    [string]$Root,
    [string]$InstallDirectory,
    [bool]$MoqiFull = $false,
    [bool]$AllowLegacyActive = $false
) {
    $getActive = ({ param($selector) Get-RimeJunctionTarget $selector }).GetNewClosure()
    $recover = ({ param($managedRoot) Recover-RimeJunctionTransactions $managedRoot $AllowLegacyActive | Out-Null }).GetNewClosure()
    $validateActive = ({ param($selector, $target) Assert-RimeSelectorTarget $selector $target $AllowLegacyActive }).GetNewClosure()
    $snapshot = ({ param($target) Get-RimeBuildSnapshot $target }).GetNewClosure()
    $switchTarget = ({ param($selector, $target, $transaction) Set-RimeJunctionTarget $selector $target $transaction $false | Out-Null }).GetNewClosure()
    $commit = ({ param($selector, $target, $transaction) Complete-RimeJunctionTransaction $selector $target $transaction $AllowLegacyActive }).GetNewClosure()
    $restore = ({
        param($selector, $target, $transaction)
        $restoreTransaction = 'restore-' + $transaction
        Set-RimeJunctionTarget $selector $target $restoreTransaction $AllowLegacyActive | Out-Null
        Complete-RimeJunctionTransaction $selector $target $restoreTransaction $AllowLegacyActive
    }).GetNewClosure()
    $clear = ({ param($selector, $target, $transaction) Remove-RimeJunction $selector $target }).GetNewClosure()
    $stop = ({ param($unused) Stop-RimeWeasel $InstallDirectory (Get-RimeCurrentSid) }).GetNewClosure()
    $deploy = ({ param($target, $mode, $timeout, $profile, $before, $started) Invoke-RimeDeploy $InstallDirectory $target $profile $MoqiFull $mode $timeout $before $started; Start-RimeWeasel $InstallDirectory }).GetNewClosure()
    $verify = ({ param($target, $profile, $before, $started) $definition = Get-RimeProfileDefinition $profile $MoqiFull; Assert-RimeJunction (Get-RimeSelectorPath $Root) $target | Out-Null; Assert-RimeBuildArtifacts $target (Get-RimePrismArtifacts $definition) $definition.Dictionaries $before $started; return $true }).GetNewClosure()
    $restart = ({ param($target) Start-RimeWeasel $InstallDirectory }).GetNewClosure()
    return [pscustomobject]@{
        GetActive = $getActive
        Recover = $recover
        ValidateActive = $validateActive
        Snapshot = $snapshot
        Switch = $switchTarget
        Commit = $commit
        Restore = $restore
        Clear = $clear
        Stop = $stop
        Deploy = $deploy
        Verify = $verify
        Restart = $restart
    }
}
