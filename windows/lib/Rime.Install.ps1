#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-RimeInstallPlan(
    [string]$Root,
    [string[]]$Profiles,
    [bool]$MoqiFull = $false,
    [ValidateSet('Interactive', 'Quiet')][string]$DeployMode = 'Interactive'
) {
    if ($Profiles.Count -eq 0) { throw 'At least one profile is required' }
    $entries = New-Object Collections.Generic.List[object]
    foreach ($profile in $Profiles) {
        $definition = Get-RimeProfileDefinition $profile $MoqiFull
        [void]$entries.Add([pscustomobject]@{
            Name = $definition.Name
            Variant = $definition.Variant
            Schemas = $definition.Schemas
            Source = $definition.Source
        })
    }
    return [pscustomobject]@{
        RuntimeVersion = '0.17.4'
        Root = $Root
        Profiles = $entries.ToArray()
        DeployMode = $DeployMode
        DeployTimeoutSeconds = 600
        MoqiFull = $MoqiFull
    }
}

function Get-RimeInitialProfile([string]$ExplicitProfile, [string[]]$RequestedProfiles, [string[]]$InstalledProfiles) {
    $installed = @($InstalledProfiles | Select-Object -Unique)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitProfile)) {
        if ($ExplicitProfile -notin @('ice', 'mint', 'moqi')) { throw "Unknown initial profile: $ExplicitProfile" }
        if ($ExplicitProfile -notin $installed) { throw "Initial profile was not installed successfully: $ExplicitProfile" }
        return $ExplicitProfile
    }
    foreach ($profile in @($RequestedProfiles | Select-Object -Unique)) {
        if ($profile -in $installed) { return $profile }
    }
    throw 'No successfully installed profile is available for initial deployment'
}

function New-RimeInstallReport([string]$Root) {
    return [pscustomobject]@{
        format = 1
        root = $Root
        startedAt = [DateTime]::UtcNow.ToString('o')
        Results = New-Object Collections.Generic.List[object]
    }
}

function Add-RimeInstallResult($Report, [string]$Profile, [string]$Status, [string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Profile)) { throw 'Install result profile is required' }
    if ($Status -notin @('completed', 'failed', 'manual_required', 'recovery_required')) {
        throw "Invalid install result status: $Status"
    }
    [void]$Report.Results.Add([pscustomobject]@{
        Profile = $Profile
        Status = $Status
        Message = $Message
        at = [DateTime]::UtcNow.ToString('o')
    })
    return $Report
}

function Invoke-RimeInstallComponent($Report, [string]$Profile, [scriptblock]$Action) {
    if ($null -eq $Report -or $null -eq $Action) { throw 'Install component report and action are required' }
    try {
        $result = & $Action
        if ($null -eq $result -or $null -eq $result.PSObject.Properties['Status']) {
            throw "Install component returned no status: $Profile"
        }
        $status = [string]$result.Status
        $message = if ($null -ne $result.PSObject.Properties['Message']) { [string]$result.Message } else { '' }
        Add-RimeInstallResult $Report $Profile $status $message | Out-Null
        return $result
    } catch {
        $message = $_.Exception.Message
        Add-RimeInstallResult $Report $Profile 'failed' $message | Out-Null
        return [pscustomobject]@{ Status = 'failed'; Message = $message }
    }
}

function Save-RimeInstallReport($Report, [string]$Root) {
    $path = Join-Path $Root 'install-report.json'
    Write-RimeJson $path $Report
    return $path
}

function Install-RimeRaycastScripts([string]$SourceDirectory, [string]$DestinationDirectory) {
    $names = @('Rime-Ice.bat', 'Rime-Mint.bat', 'Rime-Moqi.bat', 'Rime-Toggle.bat', 'Rime-Status.bat')
    if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
        return [pscustomobject]@{ Status = 'manual_required'; Copied = @(); Conflicts = @(); Message = "Copy five scripts from $SourceDirectory to Raycast's configured script directory" }
    }
    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) { throw "Raycast source missing: $SourceDirectory" }
    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        return [pscustomobject]@{ Status = 'manual_required'; Copied = @(); Conflicts = @(); Message = "Raycast script directory does not exist: $DestinationDirectory" }
    }
    Assert-RimePlainPath $SourceDirectory
    Assert-RimePlainPath $DestinationDirectory
    $result = Copy-RimeManagedFiles $SourceDirectory $DestinationDirectory $names (Join-Path $DestinationDirectory '.config-rime-raycast.json')
    $status = if ($result.Conflicts.Count -gt 0) { 'manual_required' } else { 'completed' }
    $message = if ($result.Conflicts.Count -gt 0) { 'User-edited Raycast scripts preserved: ' + ($result.Conflicts -join ', ') } else { '' }
    return [pscustomobject]@{ Status = $status; Copied = $result.Copied; Conflicts = $result.Conflicts; Message = $message }
}

function Install-RimeControlFiles([string]$WindowsDirectory, [string]$LibraryDirectory, [string]$DestinationDirectory) {
    if (-not (Test-Path -LiteralPath $WindowsDirectory -PathType Container)) { throw "Windows source missing: $WindowsDirectory" }
    if (-not (Test-Path -LiteralPath $LibraryDirectory -PathType Container)) { throw "Library source missing: $LibraryDirectory" }
    $WindowsDirectory = Assert-RimePlainExistingDirectory $WindowsDirectory 'Windows RIME source directory'
    $LibraryDirectory = Assert-RimePlainExistingDirectory $LibraryDirectory 'Windows RIME library directory'
    $scriptSource = Assert-RimePlainExistingDirectory (Join-Path $WindowsDirectory 'scripts') 'Windows RIME script source directory'
    $files = @('rime-switch.ps1', 'rime-userdata.ps1', 'Rime.Core.ps1', 'Rime.Windows.ps1', 'Rime.Switch.ps1', 'Rime.Install.ps1')
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DestinationDirectory))
    Ensure-RimePlainDirectory $parent | Out-Null
    $stage = Join-Path $parent ('.config-rime-control-' + [guid]::NewGuid().ToString('N'))
    $stageOwned = $false
    try {
        New-RimePlainDirectory $stage 'RIME control staging directory' | Out-Null
        $stageOwned = $true
        Copy-RimeSelectedFiles $scriptSource $stage @('rime-switch.ps1', 'rime-userdata.ps1') | Out-Null
        Copy-RimeSelectedFiles $LibraryDirectory $stage @('Rime.Core.ps1', 'Rime.Windows.ps1', 'Rime.Switch.ps1', 'Rime.Install.ps1') | Out-Null
        Ensure-RimePlainDirectory $DestinationDirectory | Out-Null
        $result = Copy-RimeManagedFiles $stage $DestinationDirectory $files (Join-Path $DestinationDirectory '.config-rime-control.json')
        $status = if ($result.Conflicts.Count -gt 0) { 'manual_required' } else { 'completed' }
        return [pscustomobject]@{ Status = $status; Copied = $result.Copied; Conflicts = $result.Conflicts; Directory = $DestinationDirectory }
    } finally {
        if ($stageOwned -and (Test-Path -LiteralPath $stage -PathType Container)) {
            $stage = Assert-RimePlainDirectoryTree $stage 'RIME control staging directory'
            [IO.Directory]::Delete($stage, $true)
        }
    }
}

function Read-RimeConfiguredRoot([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "RIME config file missing: $ConfigPath" }
    $config = Read-RimeJson $ConfigPath
    $property = $config.PSObject.Properties['root']
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw 'RIME config requires root' }
    $root = [string]$property.Value
    if (-not [IO.Path]::IsPathRooted($root)) { throw 'RIME configured root must be absolute' }
    Assert-RimePlainPath $root
    return $root
}

function Find-RimeArchiveContentRoot([string]$ExtractedDirectory, [string]$RequiredRelativePath) {
    if (-not (Test-Path -LiteralPath $ExtractedDirectory -PathType Container)) { throw "Extracted directory missing: $ExtractedDirectory" }
    if ([string]::IsNullOrWhiteSpace($RequiredRelativePath)) { throw 'Archive content marker required' }
    $candidates = New-Object Collections.Generic.List[string]
    $direct = Join-Path $ExtractedDirectory $RequiredRelativePath
    if (Test-Path -LiteralPath $direct -PathType Leaf) { [void]$candidates.Add([IO.Path]::GetFullPath($ExtractedDirectory)) }
    foreach ($directory in Get-ChildItem -LiteralPath $ExtractedDirectory -Directory -Force) {
        $candidate = Join-Path $directory.FullName $RequiredRelativePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { [void]$candidates.Add($directory.FullName) }
    }
    if ($candidates.Count -eq 0) { throw "Archive contains no required file: $RequiredRelativePath" }
    if ($candidates.Count -gt 1) { throw "Archive content root is ambiguous for: $RequiredRelativePath" }
    return $candidates[0]
}

function Find-RimeArchiveRoot([string]$ExtractedDirectory) {
    return Find-RimeArchiveContentRoot $ExtractedDirectory 'default.yaml'
}

function Get-RimeProfileStatePath([string]$ProfileDirectory) {
    return Get-RimeChildPath $ProfileDirectory '.config-rime-profile.json'
}

function Write-RimeProfileState([string]$ProfileDirectory, [string]$Profile, [string]$Variant) {
    if ($Profile -notin @('ice', 'mint', 'moqi')) { throw "Unknown profile: $Profile" }
    if ($Variant -notin @('standard', 'lite', 'full')) { throw "Unknown profile variant: $Variant" }
    Write-RimeJson (Get-RimeProfileStatePath $ProfileDirectory) @{
        format = 1
        profile = $Profile
        variant = $Variant
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
}

function Assert-RimeProfileVariantAllowed([string]$ProfileDirectory, [string]$Profile, [string]$Variant) {
    $path = Get-RimeProfileStatePath $ProfileDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $state = Read-RimeJson $path
    if ($state.profile -ne $Profile) { throw "Profile state mismatch: expected $Profile" }
    if ($state.variant -eq 'full' -and $Variant -eq 'lite') {
        throw 'Refusing automatic Moqi Full downgrade; explicit migration required'
    }
}

function Get-RimeManagedRootsFromSelector([string]$Selector) {
    if ([string]::IsNullOrWhiteSpace($Selector) -or -not [IO.Path]::IsPathRooted($Selector)) {
        throw 'RIME selector is not a managed absolute RimeConfig path'
    }
    try { $fullSelector = [IO.Path]::GetFullPath($Selector) }
    catch { throw "Invalid RIME selector path: $Selector" }
    if ([IO.Path]::GetFileName($fullSelector) -ine 'RimeConfig') {
        throw 'RIME selector is not a managed RimeConfig path'
    }
    $parent = [IO.Directory]::GetParent($fullSelector)
    if ($null -eq $parent) { throw 'RIME selector has no root parent' }
    try { $root = Assert-RimePlainExistingDirectory $parent.FullName 'RIME selector root directory' }
    catch { throw "RIME selector root is not managed: $($parent.FullName) ($($_.Exception.Message))" }
    try { $markerPath = Assert-RimePlainExistingFile (Get-RimeChildPath $root '.config-rime-root.json') 'RIME selector root marker' }
    catch { throw "RIME selector root is not managed: $root ($($_.Exception.Message))" }
    $marker = Read-RimeJson $markerPath
    if ($marker.format -ne 1 -or $marker.manager -ne 'config-rime') {
        throw "RIME selector root has invalid marker: $root"
    }
    try { Assert-RimePlainExistingDirectory (Get-RimeChildPath $root 'profiles') 'RIME selector managed profiles directory' | Out-Null }
    catch { throw "RIME selector root is not managed: $root ($($_.Exception.Message))" }
    return @($root)
}

function Get-RimeDefaultRoot([string]$ExplicitRoot, [string]$ConfigPath, [string]$ManagedRoot, [string]$MarkedRoot) {
    $configured = ''
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $configured = Read-RimeConfiguredRoot $ConfigPath
    }
    $local = Join-Path $env:LOCALAPPDATA 'RimeProfiles'
    return Resolve-RimeRoot $ExplicitRoot $configured $ManagedRoot $MarkedRoot $local
}

function Add-RimeMoqiStageLockIdentityParts($Parts, [string]$Name, $Entry) {
    # Names are plain lock source names; overlay entries are labelled with their
    # declared position ("overlay[<n>]-<name>") so a reorder changes the identity.
    if ($Name -notmatch '^(?:[a-z0-9._-]+|overlay\[\d+\]-[a-z0-9._-]+)$' -or $null -eq $Entry) {
        throw "Invalid Moqi stage lock entry: $Name"
    }
    foreach ($property in @('repository', 'commit', 'url', 'sha256')) {
        $entryProperty = $Entry.PSObject.Properties[$property]
        if ($null -eq $entryProperty -or [string]::IsNullOrWhiteSpace([string]$entryProperty.Value)) {
            throw "Moqi stage lock entry has no ${property}: $Name"
        }
        $value = [string]$entryProperty.Value
        if ($property -eq 'commit' -and $value -notmatch '^[0-9a-fA-F]{40}$') {
            throw "Moqi stage lock commit is invalid: $Name"
        }
        if ($property -eq 'sha256' -and $value -notmatch '^[0-9a-fA-F]{64}$') {
            throw "Moqi stage lock checksum is invalid: $Name"
        }
        [void]$Parts.Add("$Name/$property=$value")
    }
}

function Add-RimeMoqiStageVariantIdentityParts($Parts, $Entry, [bool]$Full) {
    $variantsProperty = $Entry.PSObject.Properties['variants']
    if ($null -eq $variantsProperty -or $null -eq $variantsProperty.Value) {
        throw 'Moqi stage lock has no variants definition'
    }
    $variantName = if ($Full) { 'full' } else { 'lite' }
    $variantProperty = $variantsProperty.Value.PSObject.Properties[$variantName]
    if ($null -eq $variantProperty -or $null -eq $variantProperty.Value) {
        throw "Moqi stage lock has no $variantName variant definition"
    }
    $properties = @($variantProperty.Value.PSObject.Properties | Sort-Object Name)
    if ($properties.Count -eq 0) { throw "Moqi stage $variantName variant definition is empty" }
    foreach ($property in $properties) {
        $name = [string]$property.Name
        if ($name -notmatch '^[a-zA-Z0-9._-]+$') { throw "Moqi stage variant property is invalid: $name" }
        $value = $property.Value
        if ($null -eq $value) { throw "Moqi stage variant property is null: $name" }
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            $index = 0
            foreach ($entryValue in @($value)) {
                if ($null -eq $entryValue -or $entryValue -is [System.Collections.IEnumerable] -and -not ($entryValue -is [string])) {
                    throw "Moqi stage variant array value is invalid: $name"
                }
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$entryValue))
                [void]$Parts.Add("main/variant/$variantName/$name/$index=$encoded")
                $index++
            }
            if ($index -eq 0) { [void]$Parts.Add("main/variant/$variantName/$name=<empty>") }
            continue
        }
        if ($value -isnot [string] -and $value -isnot [ValueType]) {
            throw "Moqi stage variant property is not scalar: $name"
        }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$value))
        [void]$Parts.Add("main/variant/$variantName/$name=$encoded")
    }
}

function Get-RimeMoqiStageIdentityParts(
    $Lock,
    [bool]$Full,
    [string[]]$MainPatterns,
    [object[]]$OverlayDefinitions,
    [string]$StageFormat = 'moqi-stage-v4'
) {
    if ($null -eq $Lock -or $null -eq $Lock.PSObject.Properties['sources'] -or
        $null -eq $Lock.sources.PSObject.Properties['moqi']) {
        throw 'Moqi stage lock sources are incomplete'
    }
    if ($StageFormat -notmatch '^moqi-stage-v\d+$') { throw "Invalid Moqi stage format: $StageFormat" }
    if ($null -eq $MainPatterns -or $MainPatterns.Count -eq 0) { throw 'Moqi stage requires main source patterns' }
    $parts = New-Object Collections.Generic.List[string]
    [void]$parts.Add("format=$StageFormat")
    Add-RimeMoqiStageLockIdentityParts $parts 'main' $Lock.sources.moqi
    Add-RimeMoqiStageVariantIdentityParts $parts $Lock.sources.moqi $Full
    foreach ($pattern in $MainPatterns) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { throw 'Moqi main source pattern is invalid' }
        [void]$parts.Add("main/pattern=$pattern")
    }
    $seenOverlays = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    # Overlay objects may arrive from different collection types, so enumerate them in a
    # stable order. The declared position still enters the identity: staging applies
    # overlays in declaration order, so a reorder changes the staged bytes.
    $declaredOverlays = @($OverlayDefinitions)
    $declaredPositions = @{}
    for ($declaredIndex = 0; $declaredIndex -lt $declaredOverlays.Count; $declaredIndex++) {
        $declaredOverlay = $declaredOverlays[$declaredIndex]
        if ($null -eq $declaredOverlay -or $null -eq $declaredOverlay.PSObject.Properties['Name']) {
            throw 'Moqi stage overlay definition is incomplete'
        }
        $declaredPositions[[string]$declaredOverlay.Name] = $declaredIndex
    }
    foreach ($overlay in @($declaredOverlays | Sort-Object { [string]$_.Name })) {
        if ($null -eq $overlay -or $null -eq $overlay.PSObject.Properties['Name'] -or
            $null -eq $overlay.PSObject.Properties['Entry'] -or $null -eq $overlay.PSObject.Properties['Patterns']) {
            throw 'Moqi stage overlay definition is incomplete'
        }
        $name = [string]$overlay.Name
        if ($name -notmatch '^[a-z0-9._-]+$' -or -not $seenOverlays.Add($name)) {
            throw "Moqi stage overlay name is invalid: $name"
        }
        $position = if ($declaredPositions.ContainsKey($name)) { [int]$declaredPositions[$name] } else { -1 }
        $label = "overlay[$position]-$name"
        Add-RimeMoqiStageLockIdentityParts $parts $label $overlay.Entry
        $patterns = @($overlay.Patterns)
        if ($patterns.Count -eq 0) { throw "Moqi stage overlay patterns are empty: $name" }
        foreach ($pattern in $patterns) {
            if ([string]::IsNullOrWhiteSpace([string]$pattern)) { throw "Moqi stage overlay pattern is invalid: $name" }
            [void]$parts.Add("$label/pattern=$pattern")
        }
    }
    [void]$parts.Add($(if ($Full) { 'variant=full' } else { 'variant=lite' }))
    return $parts.ToArray()
}

function Get-RimeSourceRootForProfile([string]$Profile, [bool]$Full, [string]$CachePath, $Lock) {
    $entry = $Lock.sources.$Profile
    if ($null -eq $entry) { throw "Source lock entry missing: $Profile" }
    $archive = Get-RimeSourceArchive $entry $CachePath $Profile
    $main = Get-RimeArchiveSourceRoot $archive $CachePath $Profile
    if ($Profile -ne 'moqi') { return $main }

    $mainPatterns = @(Get-RimeProfileSourcePatterns $Profile $Full)
    $overlayDefinitions = New-Object Collections.Generic.List[object]
    foreach ($dependency in @('cangjie', 'stroke', 'luna')) {
        $depEntry = $Lock.sources.$dependency
        if ($null -eq $depEntry) { throw "Moqi dependency lock entry missing: $dependency" }
        $depArchive = Get-RimeSourceArchive $depEntry $CachePath $dependency
        $required = switch ($dependency) {
            cangjie { 'cangjie5.schema.yaml' }
            stroke { 'stroke.schema.yaml' }
            luna { 'luna_pinyin.schema.yaml' }
            default { throw "Unknown Moqi dependency: $dependency" }
        }
        $depRoot = Get-RimeArchiveSourceRoot $depArchive $CachePath $dependency $required
        $patterns = switch ($dependency) {
            cangjie { @('cangjie5.schema.yaml', 'cangjie5.dict.yaml', 'cangjie5.base.dict.yaml', 'cangjie5.stem.dict.yaml', 'cangjie5.extended.dict.yaml') }
            stroke { @('stroke.schema.yaml', 'stroke.dict.yaml') }
            luna { @('luna_pinyin.schema.yaml', 'luna_quanpin.schema.yaml', 'luna_pinyin.dict.yaml', 'pinyin.yaml') }
            default { throw "Unknown Moqi dependency: $dependency" }
        }
        [void]$overlayDefinitions.Add([pscustomobject]@{ Name = $dependency; Entry = $depEntry; Root = $depRoot; Patterns = $patterns })
    }
    $identityParts = Get-RimeMoqiStageIdentityParts $Lock $Full $mainPatterns $overlayDefinitions.ToArray()
    $identity = Get-RimeProfileStageIdentity $identityParts
    return Get-RimeCachedProfileStage $main $overlayDefinitions.ToArray() $CachePath 'moqi' $identity $mainPatterns -MoqiLite:(-not $Full)
}

function Get-RimeCacheEntries([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Cache directory missing: $Directory" }
    Assert-RimePlainPath $Directory
    $root = Normalize-RimePath $Directory
    $entries = New-Object Collections.Generic.List[object]
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe reparse point in managed cache: $($item.FullName)" }
        $relative = $item.FullName.Substring($root.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
        if ($relative -eq '.config-rime-cache.json') { continue }
        if ($item.PSIsContainer) {
            [void]$entries.Add([pscustomobject][ordered]@{ path = $relative; type = 'directory'; length = 0; sha256 = '' })
        } else {
            [void]$entries.Add([pscustomobject][ordered]@{ path = $relative; type = 'file'; length = $item.Length; sha256 = Get-RimeFileHash $item.FullName })
        }
    }
    return @($entries | Sort-Object path)
}

function Write-RimeCacheMarker([string]$Directory, [string]$Kind, [string]$Identity) {
    if ($Kind -notin @('extraction', 'stage')) { throw "Invalid cache kind: $Kind" }
    Write-RimeNewJson (Join-Path $Directory '.config-rime-cache.json') ([ordered]@{
        format = 1
        manager = 'config-rime'
        kind = $Kind
        identity = $Identity
        entries = @(Get-RimeCacheEntries $Directory)
        createdAt = [DateTime]::UtcNow.ToString('o')
    })
}

function Assert-RimeCacheMarker([string]$Directory, [string]$Kind, [string]$Identity) {
    $markerPath = Join-Path $Directory '.config-rime-cache.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw "Cache directory is not managed: $Directory" }
    $marker = Read-RimeJson $markerPath
    if ($marker.format -ne 1 -or $marker.manager -ne 'config-rime' -or $marker.kind -ne $Kind -or $marker.identity -ne $Identity) {
        throw "Cache directory has invalid ownership marker: $Directory"
    }
    if ($null -eq $marker.PSObject.Properties['entries']) { throw "Cache directory marker has no entries: $Directory" }
    return $marker
}

function Test-RimeCacheIntegrity([string]$Directory, [string]$Kind, [string]$Identity) {
    $marker = Assert-RimeCacheMarker $Directory $Kind $Identity
    $expected = @($marker.entries)
    $actual = @(Get-RimeCacheEntries $Directory)
    if ($expected.Count -ne $actual.Count) { return $false }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        # A structurally incomplete marker must report "not intact" so the owned cache
        # is rebuilt, not throw an error that aborts the rebuild.
        if ($null -eq $expected[$index]) { return $false }
        foreach ($property in @('path', 'type', 'length', 'sha256')) {
            $expectedProperty = $expected[$index].PSObject.Properties[$property]
            $actualProperty = $actual[$index].PSObject.Properties[$property]
            if ($null -eq $expectedProperty -or $null -eq $actualProperty) { return $false }
            if ([string]$expectedProperty.Value -cne [string]$actualProperty.Value) { return $false }
        }
    }
    return $true
}

function Remove-RimeOwnedCacheDirectory([string]$Directory, [string]$Kind, [string]$Identity) {
    Assert-RimeCacheMarker $Directory $Kind $Identity | Out-Null
    Get-RimeCacheEntries $Directory | Out-Null
    $Directory = Assert-RimePlainDirectoryTree $Directory 'Owned RIME cache directory'
    [IO.Directory]::Delete($Directory, $true)
}

function Copy-RimeHttpsUriToNewFile([Uri]$Uri, [string]$Destination, [string]$Purpose = 'RIME HTTPS download') {
    if ($null -eq $Uri -or -not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https') {
        throw 'RIME download URL must use HTTPS'
    }
    $destinationPath = Assert-RimePlainNewWriteTarget $Destination "$Purpose destination"
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $response = $null
    $currentUri = $Uri
    try {
        for ($redirects = 0; $redirects -le 5; $redirects++) {
            $response = $client.GetAsync($currentUri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                $location = $response.Headers.Location
                $response.Dispose()
                $response = $null
                if ($null -eq $location) { throw "RIME HTTPS download redirect has no location: $currentUri" }
                $nextUri = if ($location.IsAbsoluteUri) { $location } else { [Uri]::new($currentUri, $location) }
                if (-not $nextUri.IsAbsoluteUri -or $nextUri.Scheme -ne 'https') {
                    throw "RIME HTTPS download redirect is not HTTPS: $nextUri"
                }
                $currentUri = $nextUri
                continue
            }
            if (-not $response.IsSuccessStatusCode) {
                throw "RIME HTTPS download failed with status ${status}: $currentUri"
            }
            $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $destinationPath = Assert-RimePlainNewWriteTarget $destinationPath "$Purpose destination"
                $output = Open-RimeNewFileForWrite $destinationPath "$Purpose destination"
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
            return Assert-RimePlainExistingFile $destinationPath "$Purpose destination"
        }
        throw "RIME HTTPS download exceeded redirect limit: $Uri"
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Get-RimeSourceArchive($Entry, [string]$CacheDirectory, [string]$Name) {
    if ($null -eq $Entry -or $Name -notmatch '^[A-Za-z0-9._-]+$' -or
        [string]::IsNullOrWhiteSpace([string]$Entry.url) -or
        [string]$Entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Invalid source archive lock entry: $Name"
    }
    $rawUrl = [string]$Entry.url
    $sourceFile = $null
    $uri = $null
    if ([IO.Path]::IsPathRooted($rawUrl)) {
        $sourceFile = Assert-RimePlainExistingFile $rawUrl 'Local source archive'
    } else {
        try { $uri = [Uri]$rawUrl } catch { throw "Invalid source archive URL: $rawUrl" }
        if (-not $uri.IsAbsoluteUri) { throw "Source archive URL must be absolute: $rawUrl" }
        if ($uri.IsFile) {
            $sourceFile = Assert-RimePlainExistingFile $uri.LocalPath 'Local source archive'
        } elseif ($uri.Scheme -ne 'https') {
            throw "Network source archive must use HTTPS: $rawUrl"
        }
    }
    Ensure-RimePlainDirectory $CacheDirectory | Out-Null
    $sha256 = ([string]$Entry.sha256).ToLowerInvariant()
    $extension = if ($rawUrl -match '(?i)\.exe(?:\?|$)') { '.exe' } else { '.zip' }
    $identity = 'pinned'
    foreach ($property in @('commit', 'version')) {
        $candidate = $Entry.PSObject.Properties[$property]
        if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate.Value)) {
            $identity = [string]$candidate.Value
            break
        }
    }
    if ($identity -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid source identity: $Name" }
    $destination = Assert-RimePlainWriteTarget (Join-Path $CacheDirectory ("$Name-$identity-$($sha256.Substring(0, 12))$extension"))
    $lock = Enter-RimeNamedLockWait $CacheDirectory ("$Name-$($sha256.Substring(0, 12)).download.lock")
    try {
        if (Test-Path -LiteralPath $destination) {
            $destination = Assert-RimePlainExistingFile $destination 'Pinned RIME cache artifact'
            if (Test-RimePinnedHash $destination $sha256) { return $destination }
            throw "Refusing to replace mismatched pinned cache artifact: $destination"
        }
        $temporary = Assert-RimePlainNewWriteTarget "$destination.$([guid]::NewGuid().ToString('N')).download" 'Pinned RIME cache download'
        try {
            if ($null -ne $sourceFile) {
                $sourceFile = Assert-RimePlainExistingFile $sourceFile 'Local source archive'
                $temporary = Copy-RimeFileToNewFile $sourceFile $temporary 'Pinned RIME cache download'
            } else {
                $temporary = Copy-RimeHttpsUriToNewFile $uri $temporary 'Pinned RIME cache download'
            }
            Assert-RimePinnedHash $temporary $sha256
            $temporary = Assert-RimePlainExistingFile $temporary 'Pinned RIME cache download'
            $destination = Assert-RimePlainWriteTarget $destination
            if (Test-Path -LiteralPath $destination) { throw "Pinned RIME cache artifact appeared during download: $destination" }
            [IO.File]::Move($temporary, $destination)
            return $destination
        } finally {
            # Preserve any failed temporary download. A final path check cannot prove
            # that a replacement file is still ours, so deletion would be unsafe.
        }
    } finally { $lock.Dispose() }
}

function Get-RimeArchiveSourceRoot([string]$Archive, [string]$CachePath, [string]$Name, [string]$RequiredRelativePath = 'default.yaml') {
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid archive cache name: $Name" }
    $Archive = Assert-RimePlainExistingFile $Archive 'RIME archive'
    Ensure-RimePlainDirectory $CachePath | Out-Null
    $hash = Get-RimeFileHash $Archive
    $identity = "$Name-$hash"
    $extract = Join-Path $CachePath "$Name-$hash-extracted"
    $lock = Enter-RimeNamedLockWait $CachePath ("$Name-$($hash.Substring(0, 12)).extract.lock")
    try {
        if (Test-Path -LiteralPath $extract) {
            $extract = Assert-RimePlainExistingDirectory $extract 'Archive cache directory'
            if (Test-RimeCacheIntegrity $extract 'extraction' $identity) {
                return Find-RimeArchiveContentRoot $extract $RequiredRelativePath
            }
            Remove-RimeOwnedCacheDirectory $extract 'extraction' $identity
        }
        $temporary = "$extract.$([guid]::NewGuid().ToString('N')).tmp"
        $temporaryManaged = $false
        try {
            Expand-RimeArchiveSafe $Archive $temporary | Out-Null
            Find-RimeArchiveContentRoot $temporary $RequiredRelativePath | Out-Null
            Write-RimeCacheMarker $temporary 'extraction' $identity
            $temporaryManaged = $true
            $temporary = Assert-RimePlainDirectoryTree $temporary 'RIME archive extraction staging directory'
            Assert-RimePlainPath $extract
            if (Test-Path -LiteralPath $extract) { throw "Archive cache destination appeared during extraction: $extract" }
            [IO.Directory]::Move($temporary, $extract)
        } finally {
            if ($temporaryManaged -and (Test-Path -LiteralPath $temporary -PathType Container)) {
                try { Remove-RimeOwnedCacheDirectory $temporary 'extraction' $identity } catch { }
            }
        }
        return Find-RimeArchiveContentRoot $extract $RequiredRelativePath
    } finally { $lock.Dispose() }
}

function Get-RimeProfileStageIdentity([string[]]$Parts) {
    if ($Parts.Count -eq 0 -or @($Parts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'Profile stage identity requires non-empty parts'
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Parts -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 32) }
    finally { $sha.Dispose() }
}

function Update-RimeMoqiLiteDictionaryReferences([string]$Directory) {
    # Rime's custom patch files did not override every moqi_wan.extended
    # reference from the included moqi.yaml on Weasel 0.17.4: the flypymo
    # schema still failed with "dictionary 'moqi_wan.extended' failed to
    # compile" until the staged sources themselves were rewritten. Lite
    # therefore rewrites the staged references before the stage is cached, so
    # managed hashes and the stage identity stay consistent.
    $replaced = New-Object Collections.Generic.List[string]
    foreach ($name in @('moqi_wan_flypymo.schema.yaml', 'moqi_single_xh.schema.yaml', 'moqi.yaml')) {
        $path = Get-RimeChildPath $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $path = Assert-RimePlainExistingFile $path "Moqi Lite source $name"
        $text = [IO.File]::ReadAllText($path)
        if ($text -notmatch 'moqi_wan\.extended') { continue }
        $updated = $text -replace 'moqi_wan\.extended', 'moqi_wan.lite'
        [IO.File]::WriteAllText($path, $updated, (New-Object Text.UTF8Encoding($false)))
        [void]$replaced.Add($name)
    }
    return $replaced.ToArray()
}

function Get-RimeCachedProfileStage(
    [string]$MainSource,
    [object[]]$Overlays,
    [string]$CachePath,
    [string]$Name,
    [string]$Identity,
    [string[]]$MainPatterns,
    [switch]$MoqiLite
) {
    if ($Name -notmatch '^[A-Za-z0-9._-]+$' -or $Identity -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid profile stage identity' }
    # Validate every source tree before creating or locking the managed cache.
    [void]@(Select-RimeSourceFiles $MainSource $MainPatterns)
    foreach ($overlay in @($Overlays)) {
        [void]@(Select-RimeSourceFiles ([string]$overlay.Root) ([string[]]$overlay.Patterns))
    }
    Ensure-RimePlainDirectory $CachePath | Out-Null
    $markerIdentity = "$Name-$Identity"
    $stage = Join-Path $CachePath "$Name-$Identity-staged"
    $lock = Enter-RimeNamedLockWait $CachePath ("$Name-$Identity.stage.lock")
    try {
        if (Test-Path -LiteralPath $stage) {
            $stage = Assert-RimePlainExistingDirectory $stage 'Profile stage cache directory'
            if (Test-RimeCacheIntegrity $stage 'stage' $markerIdentity) { return $stage }
            Remove-RimeOwnedCacheDirectory $stage 'stage' $markerIdentity
        }
        $temporary = "$stage.$([guid]::NewGuid().ToString('N')).tmp"
        $temporaryManaged = $false
        try {
            New-RimeProfileSourceStage $MainSource $Overlays $temporary $MainPatterns | Out-Null
            if ($MoqiLite) { [void](Update-RimeMoqiLiteDictionaryReferences $temporary) }
            Write-RimeCacheMarker $temporary 'stage' $markerIdentity
            $temporaryManaged = $true
            $temporary = Assert-RimePlainDirectoryTree $temporary 'RIME profile stage directory'
            Assert-RimePlainPath $stage
            if (Test-Path -LiteralPath $stage) { throw "Profile stage destination appeared during staging: $stage" }
            [IO.Directory]::Move($temporary, $stage)
        } finally {
            if ($temporaryManaged -and (Test-Path -LiteralPath $temporary -PathType Container)) {
                try { Remove-RimeOwnedCacheDirectory $temporary 'stage' $markerIdentity } catch { }
            }
        }
        return $stage
    } finally { $lock.Dispose() }
}

function Backup-RimeLegacyState([string]$Root, [string]$BackupParent, $SelectorInfo = $null) {
    $legacy = @(Find-RimeLegacyLayout $Root)
    $hasSelector = $null -ne $SelectorInfo -and -not [string]::IsNullOrWhiteSpace([string]$SelectorInfo.LegacyProfile)
    if ($legacy.Count -eq 0 -and -not $hasSelector) {
        return [pscustomobject]@{ Status = 'none'; Path = $null; Entries = @() }
    }
    Assert-RimePlainPath $Root
    # Validate all legacy trees before creating a recovery directory.
    foreach ($name in $legacy) {
        $source = Join-Path $Root $name
        Assert-RimePlainPath $source
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Legacy layout entry is not a directory: $source" }
        Get-RimeDirectoryFingerprint $source | Out-Null
    }
    Ensure-RimePlainDirectory $BackupParent | Out-Null
    $backup = Join-Path $BackupParent ('legacy-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-RimePlainDirectory $backup 'RIME legacy backup directory' | Out-Null
    foreach ($name in $legacy) {
        $source = Assert-RimePlainDirectoryTree (Join-Path $Root $name) 'Legacy RIME backup source'
        $copied = Copy-RimePlainDirectoryTree $source (Join-Path $backup $name) 'Legacy RIME backup'
        if (-not (Test-RimeDirectoryTreeEqual $source $copied)) { throw "Legacy RIME backup verification failed: $name" }
    }
    if ($hasSelector) {
        Write-RimeNewJson (Join-Path $backup 'selector.json') ([ordered]@{
            selector = Get-RimeSelectorPath $Root
            target = [string]$SelectorInfo.Target
            profile = [string]$SelectorInfo.LegacyProfile
        })
    }
    return [pscustomobject]@{ Status = 'backup_created'; Path = $backup; Entries = $legacy }
}

function Backup-RimeLegacyLayout([string]$Root, [string]$BackupParent) {
    return Backup-RimeLegacyState $Root $BackupParent $null
}

function Initialize-RimeManagedManifestFromSource(
    [string]$Source,
    [string]$Destination,
    [string[]]$Files,
    [string]$ManifestPath
) {
    if (Test-Path -LiteralPath $ManifestPath) { throw "Managed manifest already exists: $ManifestPath" }
    $claimed = New-Object Collections.Generic.List[string]
    $entries = New-Object Collections.Generic.List[object]
    foreach ($relative in $Files) {
        $sourcePath = Get-RimeChildPath $Source $relative
        $destinationPath = Get-RimeChildPath $Destination $relative
        if (-not [IO.File]::Exists($sourcePath) -or -not [IO.File]::Exists($destinationPath)) { continue }
        $sourceHash = Get-RimeFileHash $sourcePath
        if ((Get-RimeFileHash $destinationPath) -eq $sourceHash) {
            [void]$claimed.Add($relative)
            [void]$entries.Add([pscustomobject]@{ path = $relative; sha256 = $sourceHash })
        }
    }
    Write-RimeNewJson $ManifestPath @{ format = 1; manager = 'config-rime'; files = $entries.ToArray(); updated = [DateTime]::UtcNow.ToString('o') }
    return [pscustomobject]@{ Claimed = $claimed.ToArray() }
}

function Get-RimeDirectoryFingerprint([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Directory missing: $Directory" }
    Assert-RimePlainPath $Directory
    $root = Normalize-RimePath $Directory
    $entries = New-Object Collections.Generic.List[object]
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe reparse point in legacy profile: $($item.FullName)" }
        $relative = $item.FullName.Substring($root.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
        if ($item.PSIsContainer) {
            [void]$entries.Add([pscustomobject]@{ path = $relative; type = 'directory'; length = 0; sha256 = '' })
        } else {
            [void]$entries.Add([pscustomobject]@{ path = $relative; type = 'file'; length = $item.Length; sha256 = Get-RimeFileHash $item.FullName })
        }
    }
    return @($entries | Sort-Object path)
}

function Test-RimeDirectoryTreeEqual([string]$Left, [string]$Right) {
    $leftEntries = @(Get-RimeDirectoryFingerprint $Left)
    $rightEntries = @(Get-RimeDirectoryFingerprint $Right)
    if ($leftEntries.Count -ne $rightEntries.Count) { return $false }
    for ($index = 0; $index -lt $leftEntries.Count; $index++) {
        foreach ($property in @('path', 'type', 'length', 'sha256')) {
            if ([string]$leftEntries[$index].$property -cne [string]$rightEntries[$index].$property) { return $false }
        }
    }
    return $true
}

function Copy-RimePlainDirectoryTree([string]$Source, [string]$Destination, [string]$Purpose = 'RIME directory copy') {
    $Source = Assert-RimePlainDirectoryTree $Source "$Purpose source"
    Assert-RimePlainPath $Destination
    if (Test-Path -LiteralPath $Destination) { throw "$Purpose destination already exists: $Destination" }
    New-RimePlainDirectory $Destination "$Purpose destination" | Out-Null
    $sourceRoot = Normalize-RimePath $Source
    $directories = New-Object Collections.Generic.List[string]
    $files = New-Object Collections.Generic.List[string]
    foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Purpose source contains unsafe reparse point: $($item.FullName)" }
        $relative = $item.FullName.Substring($sourceRoot.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
        Assert-RimeSafeRelativePath $relative
        if ($item.PSIsContainer) { [void]$directories.Add($relative) }
        else { [void]$files.Add($relative) }
    }
    foreach ($relative in @($directories | Sort-Object { $_.Length })) {
        $sourceDirectory = Assert-RimePlainExistingDirectory (Get-RimeChildPath $Source $relative) "$Purpose source directory $relative"
        $destinationDirectory = Get-RimeChildPath $Destination $relative
        Assert-RimePlainExistingDirectory $sourceDirectory "$Purpose source directory $relative" | Out-Null
        New-RimePlainDirectory $destinationDirectory "$Purpose destination directory $relative" | Out-Null
    }
    Copy-RimeSelectedFiles $Source $Destination $files.ToArray() | Out-Null
    return Assert-RimePlainDirectoryTree $Destination "$Purpose destination"
}

function Copy-RimeLegacyProfiles([string]$Root) {
    Assert-RimePlainPath $Root
    $profiles = Join-Path $Root 'profiles'
    Ensure-RimePlainDirectory $profiles | Out-Null
    $copied = New-Object Collections.Generic.List[string]
    $alreadyPresent = New-Object Collections.Generic.List[string]
    foreach ($mapping in @(
        @{ Legacy = 'Rime_Ice'; Profile = 'ice' },
        @{ Legacy = 'Rime_Mint'; Profile = 'mint' },
        @{ Legacy = 'Rime_Moqi'; Profile = 'moqi' }
    )) {
        $source = Join-Path $Root $mapping.Legacy
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        $source = Assert-RimePlainDirectoryTree $source 'Legacy RIME profile'
        $destination = Get-RimeProfileDirectory $Root $mapping.Profile
        if (Test-Path -LiteralPath $destination) {
            if (-not (Test-RimeDirectoryTreeEqual $source $destination)) {
                throw "Managed profile differs from legacy source during adoption: $destination"
            }
            [void]$alreadyPresent.Add($mapping.Profile)
            continue
        }
        Copy-RimePlainDirectoryTree $source $destination 'Legacy RIME profile' | Out-Null
        if (-not (Test-RimeDirectoryTreeEqual $source $destination)) { throw "Legacy profile copy verification failed: $destination" }
        [void]$copied.Add($mapping.Profile)
    }
    return [pscustomobject]@{ Copied = $copied.ToArray(); AlreadyPresent = $alreadyPresent.ToArray() }
}

function Ensure-RimeRootLayout([string]$Root, [string]$OwnerSid, [switch]$AllowExistingMarker) {
    Ensure-RimePlainDirectory $Root | Out-Null
    $marker = Get-RimeRootMarker $Root
    if ($null -ne $marker) {
        Assert-RimeMarker $Root $OwnerSid
        if (-not $AllowExistingMarker) { throw 'Managed RIME root already exists; use update mode' }
    } else {
        $legacy = @(Find-RimeLegacyLayout $Root)
        if ($legacy.Count -gt 0) { throw 'Unmarked legacy RIME layout requires explicit backup before adoption' }
        New-RimeRootMarker $Root $OwnerSid | Out-Null
    }
    foreach ($name in @('profiles', 'review-export')) {
        $path = Join-Path $Root $name
        Ensure-RimePlainDirectory $path | Out-Null
    }
    return $Root
}

function New-RimeProfileSourceStage([string]$MainSource, [object[]]$Overlays, [string]$Destination, [string[]]$MainPatterns = @('*', '**/*')) {
    if (Test-Path -LiteralPath $Destination) { throw "Profile source stage already exists: $Destination" }
    # Scan every source before creating the destination so a hostile source tree
    # cannot leave a partly-created managed stage behind.
    $mainFiles = @(Select-RimeSourceFiles $MainSource $MainPatterns)
    $overlayPlans = New-Object Collections.Generic.List[object]
    foreach ($overlay in @($Overlays)) {
        $overlayRoot = [string]$overlay.Root
        $patterns = [string[]]$overlay.Patterns
        [void]$overlayPlans.Add([pscustomobject]@{ Root = $overlayRoot; Files = @(Select-RimeSourceFiles $overlayRoot $patterns) })
    }
    New-RimePlainDirectory $Destination 'RIME profile source stage' | Out-Null
    # Overlay order is declared precedence: later overlays win. Resolve every
    # collision before copying so staging stays exclusive-create throughout.
    $selected = @{}
    foreach ($relative in $mainFiles) {
        if ($relative -notmatch '(^|/)(\.git|\.github|\.gitignore)(/|$)') {
            $selected[$relative] = [pscustomobject]@{ Root = $MainSource; Relative = $relative }
        }
    }
    foreach ($overlay in $overlayPlans) {
        foreach ($relative in @($overlay.Files)) {
            $selected[$relative] = [pscustomobject]@{ Root = [string]$overlay.Root; Relative = $relative }
        }
    }
    $files = New-Object Collections.Generic.List[string]
    foreach ($item in @($selected.Values | Sort-Object Relative)) {
        Copy-RimeSelectedFiles ([string]$item.Root) $Destination @([string]$item.Relative) | Out-Null
        [void]$files.Add([string]$item.Relative)
    }
    Assert-RimePlainDirectoryTree $Destination 'RIME profile source stage' | Out-Null
    return [pscustomobject]@{ Root = $Destination; Files = $files.ToArray() }
}

function Install-RimeProfileFromSource(
    [string]$SourceDirectory,
    [string]$Root,
    [ValidateSet('ice', 'mint', 'moqi')][string]$Profile,
    [bool]$MoqiFull = $false
) {
    $definition = Get-RimeProfileDefinition $Profile $MoqiFull
    $variant = $definition.Variant
    $destination = Get-RimeProfileDirectory $Root $Profile
    $patterns = @(Get-RimeProfileSourcePatterns $Profile $MoqiFull)
    # Select-RimeSourceFiles validates all descendants before any profile path is created.
    $files = @(Select-RimeSourceFiles $SourceDirectory $patterns)
    if ($files.Count -eq 0) { throw "No managed source files selected for profile: $Profile" }
    Ensure-RimePlainDirectory $destination | Out-Null
    Assert-RimeProfileVariantAllowed $destination $Profile $variant
    $manifest = Join-Path $destination 'managed-files.json'
    $result = Copy-RimeManagedFiles $SourceDirectory $destination $files $manifest
    $conflicts = New-Object Collections.Generic.List[string]
    foreach ($name in @($result.Conflicts)) { [void]$conflicts.Add([string]$name) }
    if ($Profile -eq 'moqi') {
        if ($MoqiFull) {
            $cleanup = Remove-RimeMoqiLiteArtifacts $destination
            foreach ($name in @($cleanup.Preserved)) { [void]$conflicts.Add([string]$name) }
        } else {
            $moqiDictionary = Write-RimeMoqiLiteDictionary $destination
            foreach ($name in @($moqiDictionary.Conflicts)) { [void]$conflicts.Add([string]$name) }
            $moqiPatches = Write-RimeMoqiLiteSchemaPatch $destination
            foreach ($name in @($moqiPatches.Conflicts)) { [void]$conflicts.Add([string]$name) }
        }
    }
    $patches = Write-RimePatches $destination $definition.Schemas
    foreach ($name in @($patches.Conflicts)) { [void]$conflicts.Add([string]$name) }
    Write-RimeProfileState $destination $Profile $variant
    return [pscustomobject]@{
        Profile = $Profile
        Variant = $variant
        Destination = $destination
        Files = $files
        Conflicts = @($conflicts | Sort-Object -Unique)
    }
}
