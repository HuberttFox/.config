#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-BootstrapJsonText($Value) {
    $json = $Value | ConvertTo-Json -Depth 20
    # Windows PowerShell 5.1 rejects JSON strings containing an escaped ANSI
    # escape character. External output is sanitized before this point, but keep
    # the serializer defensive for data supplied by providers or child tools.
    return [regex]::Replace($json, '\\u001b', '')
}

function Read-BootstrapJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json)
}

function ConvertTo-BootstrapSafeText([string]$Text) {
    if ($null -eq $Text) { return '' }
    $ansiPattern = [string][char]27 + '\[[0-?]*[ -/]*[@-~]'
    $clean = [regex]::Replace([string]$Text, $ansiPattern, '')
    $clean = [regex]::Replace($clean, '\\u001b', '')
    $builder = New-Object Text.StringBuilder
    foreach ($character in $clean.ToCharArray()) {
        $code = [int][char]$character
        if ($code -eq 9 -or $code -eq 10 -or $code -eq 13 -or ($code -ge 32 -and $code -ne 127)) {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-BootstrapRegistryValueSnapshot([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Name)) {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    try {
        $properties = Get-ItemProperty -Path $Path -ErrorAction Stop
        $property = $properties.PSObject.Properties[$Name]
        if ($null -eq $property) { return [pscustomobject]@{ Exists = $false; Value = $null } }
        return [pscustomobject]@{ Exists = $true; Value = $property.Value }
    } catch {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ Exists = $false; Value = $null }
        }
        throw
    }
}

function Get-BootstrapRegistryValue([string]$Path, [string]$Name) {
    $snapshot = Get-BootstrapRegistryValueSnapshot $Path $Name
    if (-not $snapshot.Exists) { return $null }
    return $snapshot.Value
}

function Get-BootstrapObjectProperty($Object, [string]$Name) {
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-BootstrapUtcDateTime($Value) {
    if ($null -eq $Value) { throw 'Bootstrap timestamp is missing' }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return ([DateTime]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )).ToUniversalTime()
}

function Write-BootstrapJson([string]$Path, $Value) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, (ConvertTo-BootstrapJsonText $Value), $encoding)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
        } else {
            Move-Item -LiteralPath $temporary -Destination $Path -ErrorAction Stop
        }
    } catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Write-BootstrapTextAtomic([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $Text, $encoding)
    try {
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Get-BootstrapDefaultStateRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        return Join-Path $env:ProgramData 'WindowsBootstrap'
    }
    $temporary = if ([string]::IsNullOrWhiteSpace($env:TEMP)) { [IO.Path]::GetTempPath() } else { $env:TEMP }
    return Join-Path $temporary 'WindowsBootstrap'
}

function Get-BootstrapScriptRoot {
    # Library lives in <repo>\windows-bootstrap\lib; return repository root.
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-BootstrapRoot([string]$RepositoryRoot) {
    return Join-Path $RepositoryRoot 'windows-bootstrap'
}

function Test-BootstrapRunId([string]$RunId) {
    return -not [string]::IsNullOrWhiteSpace($RunId) -and $RunId -match '^[0-9a-fA-F]{32}$'
}

function Assert-BootstrapPlainPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Bootstrap path is empty' }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { throw "Invalid bootstrap path: $Path" }
    $cursor = $full
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = $null
        try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop } catch {
            if ([string]$_.CategoryInfo.Category -ne 'ObjectNotFound') {
                throw "Cannot inspect bootstrap path safely: $cursor ($($_.Exception.Message))"
            }
        }
        if ($null -ne $item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Unsafe reparse path: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Ensure-BootstrapPlainDirectory([string]$Path) {
    $full = Assert-BootstrapPlainPath $Path
    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Bootstrap path is not a directory: $full" }
    } else {
        [IO.Directory]::CreateDirectory($full) | Out-Null
    }
    $full = Assert-BootstrapPlainPath $full
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Bootstrap directory creation failed: $full" }
    return $full
}

function Assert-BootstrapPlainExistingFile([string]$Path, [string]$Purpose = 'Bootstrap file') {
    $full = Assert-BootstrapPlainPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Purpose is missing or is not a plain file: $full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Purpose is not a plain file: $full"
    }
    return $full
}

function Test-BootstrapSafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path -replace '/', '\'
    if ($normalized -match '(^\\|^[A-Za-z]:|[<>:"|?*\x00-\x1f]|(^|\\)\.\.?(\\|$))') { return $false }
    foreach ($segment in @($normalized -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -match '[. ]$' -or
            $segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            return $false
        }
    }
    return $true
}

function Get-BootstrapCurrentUserSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity -or $null -eq $identity.User -or [string]::IsNullOrWhiteSpace([string]$identity.User.Value)) {
        throw 'Current Windows user SID is unavailable'
    }
    return [string]$identity.User.Value
}

function Get-BootstrapUserPhaseStateRoot([string]$RunId, [string]$LocalAppData = '') {
    if (-not (Test-BootstrapRunId $RunId)) { throw "Invalid user-phase run ID: $RunId" }
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw 'LOCALAPPDATA is required for the user bootstrap phase' }
    $base = Assert-BootstrapPlainPath $LocalAppData
    return Assert-BootstrapPlainPath (Join-Path (Join-Path (Join-Path $base 'WindowsBootstrap') 'UserPhase') $RunId.ToLowerInvariant())
}

function Get-BootstrapUserPhaseHandoffPath([string]$RunId, [string]$LocalAppData = '') {
    return Join-Path (Get-BootstrapUserPhaseStateRoot $RunId $LocalAppData) 'handoff.json'
}

function Get-BootstrapItemExecutionContext($Item) {
    $value = [string](Get-BootstrapObjectProperty $Item 'executionContext')
    if ([string]::IsNullOrWhiteSpace($value)) { return 'elevated' }
    return $value
}

function Get-BootstrapUserPhaseItems($Items) {
    return @($Items | Where-Object { (Get-BootstrapItemExecutionContext $_) -eq 'user' })
}

function Test-BootstrapWinGetUserScope([string[]]$InstallArguments) {
    $arguments = @($InstallArguments)
    $hasScope = $false
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        if ([string]$arguments[$index] -ine '--scope') { continue }
        $hasScope = $true
        if ($index + 1 -ge $arguments.Count -or [string]$arguments[$index + 1] -ine 'user') { return $false }
    }
    return $hasScope
}

function Get-BootstrapPathOwnerSid([string]$Path) {
    $full = Assert-BootstrapPlainPath $Path
    $acl = Get-Acl -LiteralPath $full -ErrorAction Stop
    $owner = [string]$acl.Owner
    if ([string]::IsNullOrWhiteSpace($owner)) { throw "Owner is unavailable for bootstrap path: $full" }
    if ($owner -match '^S-1-\d+(?:-\d+)+$') { return $owner }
    return ([Security.Principal.NTAccount]$owner).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Test-BootstrapUserPhasePathSecurity([string]$Path, [string]$OwnerSid, [switch]$RequireProtectedDacl) {
    try {
        if ([string]::IsNullOrWhiteSpace($OwnerSid)) { return $false }
        $fullPath = Assert-BootstrapPlainPath $Path
        $acl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
        if ((Get-BootstrapPathOwnerSid $fullPath) -cne $OwnerSid) { return $false }
        if ($RequireProtectedDacl -and -not [bool]$acl.AreAccessRulesProtected) { return $false }
        $sidType = [System.Security.Principal.SecurityIdentifier]
        $rules = @($acl.GetAccessRules($true, $true, $sidType))
        if ($rules.Count -eq 0) { return $false }
        $allowedSids = @($OwnerSid, 'S-1-5-18')
        $requiredSids = @{}
        $fullControl = [long][System.Security.AccessControl.FileSystemRights]::FullControl
        foreach ($rule in $rules) {
            $sid = [string]$rule.IdentityReference.Value
            if ($sid -notin $allowedSids) { return $false }
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { return $false }
            if (([long]$rule.FileSystemRights -band $fullControl) -ne $fullControl) { return $false }
            $requiredSids[$sid] = $true
        }
        return $requiredSids.ContainsKey($OwnerSid) -and $requiredSids.ContainsKey('S-1-5-18')
    } catch {
        return $false
    }
}

function Protect-BootstrapUserPhasePath([string]$Path, [string]$OwnerSid, [switch]$Directory) {
    $fullPath = Assert-BootstrapPlainPath $Path
    $expectedType = if ($Directory) { 'directory' } else { 'file' }
    $exists = if ($Directory) {
        Test-Path -LiteralPath $fullPath -PathType Container
    } else {
        Test-Path -LiteralPath $fullPath -PathType Leaf
    }
    if (-not $exists) { throw "User phase $expectedType is missing: $fullPath" }
    if ((Get-BootstrapPathOwnerSid $fullPath) -cne $OwnerSid) {
        throw "User phase $expectedType owner does not match current user: $fullPath"
    }
    $acl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    $sidType = [System.Security.Principal.SecurityIdentifier]
    foreach ($rule in @($acl.GetAccessRules($true, $true, $sidType))) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    $inheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($sid in @($OwnerSid, 'S-1-5-18')) {
        $identity = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $sid
        $rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @($identity, $fullControl, $inheritance, $propagation, $allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $fullPath -AclObject $acl -ErrorAction Stop
    if (-not (Test-BootstrapUserPhasePathSecurity $fullPath $OwnerSid -RequireProtectedDacl)) {
        throw "User phase $expectedType DACL does not match the required owner/SYSTEM policy: $fullPath"
    }
    return $fullPath
}

function Protect-BootstrapUserPhaseRoot([string]$Path, [string]$OwnerSid) {
    return Protect-BootstrapUserPhasePath $Path $OwnerSid -Directory
}

function Protect-BootstrapUserPhaseHandoff([string]$Path, [string]$OwnerSid) {
    return Protect-BootstrapUserPhasePath $Path $OwnerSid
}

function ConvertTo-BootstrapCanonicalJsonValue($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $record = [ordered]@{}
        foreach ($name in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $record[$name] = ConvertTo-BootstrapCanonicalJsonValue (Get-BootstrapObjectProperty $Value $name)
        }
        return [pscustomobject]$record
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $values = @()
        foreach ($entry in $Value) {
            $values += ,(ConvertTo-BootstrapCanonicalJsonValue $entry)
        }
        return ,$values
    }
    $record = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        $record[[string]$property.Name] = ConvertTo-BootstrapCanonicalJsonValue $property.Value
    }
    return [pscustomobject]$record
}

function Get-BootstrapUserPhaseManifestFingerprint($Items) {
    # This is carried by the user-phase handoff, but covers every selected
    # manifest item. The elevated child must reject a changed machine phase.
    $payload = [ordered]@{
        format = 1
        selectedItems = ConvertTo-BootstrapCanonicalJsonValue @($Items)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-BootstrapJsonText $payload))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha.ComputeHash($bytes))) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-BootstrapUserPhaseHandoffData($Handoff, [string]$RunId, [string]$OwnerSid, $Items, [string]$ExpectedProfile = '') {
    $invalid = {
        param([string]$Reason)
        return [pscustomobject]@{ valid = $false; reason = $Reason; results = @(); host = $null }
    }
    if (-not (Test-BootstrapRunId $RunId)) { return & $invalid 'requested run ID is invalid' }
    if ($null -eq $Handoff) { return & $invalid 'handoff JSON is missing' }
    if ([int](Get-BootstrapObjectProperty $Handoff 'format') -ne 1) { return & $invalid 'handoff format is unsupported' }
    if ([string](Get-BootstrapObjectProperty $Handoff 'kind') -cne 'windows-bootstrap-user-phase') { return & $invalid 'handoff kind is unsupported' }
    if ([string](Get-BootstrapObjectProperty $Handoff 'runId') -cne $RunId) { return & $invalid 'handoff run ID does not match' }
    if ([string](Get-BootstrapObjectProperty $Handoff 'ownerSid') -cne $OwnerSid) { return & $invalid 'handoff owner SID does not match current user' }
    $handoffHost = Get-BootstrapObjectProperty $Handoff 'host'
    if ($null -eq $handoffHost) { return & $invalid 'handoff normal-user host metadata is missing' }
    if ([string](Get-BootstrapObjectProperty $handoffHost 'UserSid') -cne $OwnerSid) { return & $invalid 'handoff normal-user host SID does not match current user' }
    if ([bool](Get-BootstrapObjectProperty $handoffHost 'IsAdministrator')) { return & $invalid 'handoff normal-user host is elevated' }
    if ([int](Get-BootstrapObjectProperty $handoffHost 'SessionId') -lt 1) { return & $invalid 'handoff normal-user host has no interactive desktop session' }
    if ([string](Get-BootstrapObjectProperty $handoffHost 'IntegritySid') -cne 'S-1-16-8192') {
        return & $invalid 'handoff normal-user host does not have medium integrity'
    }
    $manifestFingerprint = [string](Get-BootstrapObjectProperty $Handoff 'manifestFingerprint')
    if ($manifestFingerprint -notmatch '^[0-9a-fA-F]{64}$') { return & $invalid 'handoff manifest fingerprint is invalid' }
    if ($manifestFingerprint -cne (Get-BootstrapUserPhaseManifestFingerprint $Items)) {
        return & $invalid 'handoff manifest fingerprint does not match current selected items'
    }
    $handoffProfile = [string](Get-BootstrapObjectProperty $Handoff 'profile')
    if ($handoffProfile -notin @('Base', 'Core', 'Optional', 'All')) { return & $invalid 'handoff profile is invalid' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedProfile) -and $handoffProfile -cne $ExpectedProfile) {
        return & $invalid 'handoff profile does not match current run'
    }
    try {
        $createdAt = ConvertTo-BootstrapUtcDateTime (Get-BootstrapObjectProperty $Handoff 'createdAt')
        $age = [DateTime]::UtcNow - $createdAt
        if ($age.TotalHours -gt 24 -or $age.TotalMinutes -lt -5) { return & $invalid 'handoff is stale or has a future timestamp' }
    } catch { return & $invalid 'handoff timestamp is invalid' }
    $expected = @{}
    foreach ($item in @(Get-BootstrapUserPhaseItems $Items)) {
        $name = [string](Get-BootstrapObjectProperty $item 'name')
        if ([string]::IsNullOrWhiteSpace($name)) { return & $invalid 'manifest user-phase item has no name' }
        $expected[$name] = $item
    }
    $received = @((Get-BootstrapObjectProperty $Handoff 'results'))
    if ($received.Count -ne $expected.Count) { return & $invalid 'handoff result count does not match manifest user-phase items' }
    $seen = @{}
    $allowedStatuses = @('completed', 'failed', 'failed_cleaned', 'failed_uncleaned', 'skipped', 'manual_required', 'recovery_required')
    foreach ($result in $received) {
        $name = [string](Get-BootstrapObjectProperty $result 'name')
        if (-not $expected.ContainsKey($name)) { return & $invalid "handoff contains unexpected item: $name" }
        if ($seen.ContainsKey($name)) { return & $invalid "handoff contains duplicate item: $name" }
        $seen[$name] = $true
        $item = $expected[$name]
        if ([string](Get-BootstrapObjectProperty $result 'mode') -cne [string](Get-BootstrapObjectProperty $item 'mode')) {
            return & $invalid "handoff mode does not match manifest for: $name"
        }
        if ([string](Get-BootstrapObjectProperty $result 'executionContext') -cne 'user') {
            return & $invalid "handoff execution context is invalid for: $name"
        }
        if ([string](Get-BootstrapItemExecutionContext $item) -cne 'user') {
            return & $invalid "handoff item is not a user-context item: $name"
        }
        if ([string](Get-BootstrapObjectProperty $item 'mode') -eq 'winget' -and
            [string](Get-BootstrapObjectProperty $result 'wingetId') -cne [string](Get-BootstrapObjectProperty $item 'wingetId')) {
            return & $invalid "handoff WinGet ID does not match manifest for: $name"
        }
        $resultStatus = [string](Get-BootstrapObjectProperty $result 'status')
        if ($resultStatus -notin $allowedStatuses) {
            return & $invalid "handoff status is invalid for: $name"
        }
        if ([string](Get-BootstrapObjectProperty $item 'mode') -eq 'portable-handoff' -and $resultStatus -eq 'completed') {
            $details = Get-BootstrapObjectProperty $result 'details'
            foreach ($field in @('portableAppsRoot', 'userPhaseRoot', 'launcherSha256', 'coreExecutableSha256')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-BootstrapObjectProperty $details $field))) {
                    return & $invalid "portable handoff completion has no ${field}: $name"
                }
            }
            foreach ($field in @('launcherSha256', 'coreExecutableSha256')) {
                if ([string](Get-BootstrapObjectProperty $details $field) -notmatch '^[0-9a-fA-F]{64}$') {
                    return & $invalid "portable handoff completion has an invalid ${field}: $name"
                }
            }
        }
    }
    return [pscustomobject]@{ valid = $true; reason = ''; results = $received; host = $handoffHost }
}

function New-BootstrapState([string]$StateRoot, [string]$RunId, [string]$SelectedProfile, [bool]$DryRun) {
    return [ordered]@{
        format = 1
        runId = $RunId
        startedAt = [DateTime]::UtcNow.ToString('o')
        finishedAt = $null
        stateRoot = $StateRoot
        profile = $SelectedProfile
        dryRun = $DryRun
        phase = 'initialized'
        nextPhase = 'preflight'
        completedComponents = @()
        failedComponents = @()
        skippedComponents = @()
        manualComponents = @()
        recoveryComponents = @()
        requiresReboot = $false
        resumeTask = $null
        backups = @()
        createdPaths = @()
        ownedFiles = @()
        managedFiles = @()
        createdRegistryValues = @()
        installedPackages = @()
        installedDownloads = @()
        failedDownloads = @()
        installPolicy = $null
        cleanup = @()
        languageSnapshotBefore = $null
        executionOptions = @{}
        userPhase = $null
    }
}

function New-BootstrapReport([string]$StateRoot, [string]$RunId, [string]$SelectedProfile, [bool]$DryRun) {
    return [ordered]@{
        format = 1
        runId = $RunId
        startedAt = [DateTime]::UtcNow.ToString('o')
        finishedAt = $null
        stateRoot = $StateRoot
        profile = $SelectedProfile
        dryRun = $DryRun
        logPath = $null
        installPolicy = $null
        host = $null
        results = @()
        success = @()
        failed = @()
        failedCleaned = @()
        failedUncleaned = @()
        skipped = @()
        manualRequired = @()
        recoveryRequired = @()
        cleanup = @()
        requiresReboot = $false
        resumeTask = $null
        userPhase = $null
    }
}

function Ensure-BootstrapStateShape($State) {
    foreach ($name in @('completedComponents', 'failedComponents', 'skippedComponents', 'manualComponents', 'recoveryComponents', 'backups', 'createdPaths', 'ownedFiles', 'managedFiles', 'createdRegistryValues', 'installedPackages', 'installedDownloads', 'failedDownloads', 'cleanup')) {
        $property = $State.PSObject.Properties[$name]
        if ($null -eq $property) {
            $State | Add-Member -NotePropertyName $name -NotePropertyValue @()
        } elseif ($null -eq $property.Value) {
            $property.Value = @()
        }
    }
    foreach ($name in @('languageSnapshotBefore', 'requiresReboot', 'resumeTask', 'nextPhase', 'executionOptions', 'installPolicy', 'userPhase')) {
        if ($null -eq $State.PSObject.Properties[$name]) {
            $default = switch ($name) {
                'languageSnapshotBefore' { $null }
                'requiresReboot' { $false }
                'nextPhase' { 'preflight' }
                'executionOptions' { @{} }
                default { $null }
            }
            $State | Add-Member -NotePropertyName $name -NotePropertyValue $default
        }
    }
    return $State
}

function Ensure-BootstrapReportShape($Report) {
    foreach ($name in @('results', 'success', 'failed', 'failedCleaned', 'failedUncleaned', 'skipped', 'manualRequired', 'recoveryRequired', 'cleanup')) {
        $property = $Report.PSObject.Properties[$name]
        if ($null -eq $property) {
            $Report | Add-Member -NotePropertyName $name -NotePropertyValue @()
        } elseif ($null -eq $property.Value) {
            $property.Value = @()
        }
    }
    foreach ($name in @('host', 'finishedAt', 'requiresReboot', 'resumeTask', 'logPath', 'installPolicy', 'userPhase')) {
        if ($null -eq $Report.PSObject.Properties[$name]) {
            $default = if ($name -eq 'requiresReboot') { $false } else { $null }
            $Report | Add-Member -NotePropertyName $name -NotePropertyValue $default
        }
    }
    return $Report
}

function Save-BootstrapPriorRun([string]$Path, [string]$RunId) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $destination = Join-Path $parent ("$leaf.$RunId")
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $destination = Join-Path $parent ("$leaf.$RunId.$([guid]::NewGuid().ToString('N'))")
    }
    Copy-Item -LiteralPath $Path -Destination $destination -ErrorAction Stop
}

function Get-BootstrapLatestResults($Results) {
    $latestByName = @{}
    foreach ($result in @($Results)) {
        $nameProperty = $result.PSObject.Properties['name']
        if ($null -eq $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) { continue }
        $latestByName[[string]$nameProperty.Value] = $result
    }
    return @($latestByName.Values)
}

function Get-BootstrapLatestResult($Context, [string]$Name) {
    $latest = $null
    foreach ($result in @($Context.Report.results)) {
        if ([string]$result.name -eq $Name) { $latest = $result }
    }
    return $latest
}

function New-BootstrapContext(
    [string]$StateRoot,
    [string]$SelectedProfile,
    [bool]$DryRun,
    [ValidateSet('Run', 'Resume', 'Verify', 'Report', 'Cleanup')]
    [string]$Operation,
    [string]$RepoRoot,
    [switch]$Force,
    [switch]$Quiet,
    [switch]$Silent,
    [string]$RunId
) {
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Get-BootstrapDefaultStateRoot }
    if (-not [string]::IsNullOrWhiteSpace($RunId) -and -not (Test-BootstrapRunId $RunId)) {
        throw "Invalid Windows bootstrap run ID: $RunId"
    }
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    $statePath = Join-Path $StateRoot 'state.json'
    $reportPath = Join-Path $StateRoot 'report.json'
    $logDirectory = Join-Path $StateRoot 'logs'
    $backupDirectory = Join-Path $StateRoot 'backups'
    $tempDirectory = Join-Path $StateRoot 'temp'
    $existingState = Read-BootstrapJson $statePath
    $existingReport = Read-BootstrapJson $reportPath
    $requiresExisting = $Operation -in @('Resume', 'Report', 'Cleanup')
    if ($requiresExisting -and $null -eq $existingState) {
        throw "No prior Windows bootstrap state found: $statePath"
    }
    if ($Operation -eq 'Report' -and $null -eq $existingReport) {
        throw "No prior Windows bootstrap report found: $reportPath"
    }

    $runId = if ([string]::IsNullOrWhiteSpace($RunId)) { [guid]::NewGuid().ToString('N') } else { $RunId.ToLowerInvariant() }
    $state = $null
    $report = $null
    if ($Operation -eq 'Run') {
        if ($null -ne $existingState) {
            $existingState = Ensure-BootstrapStateShape $existingState
            if ([string]$existingState.phase -ne 'completed' -and -not $Force -and -not $DryRun) {
                throw "Previous Windows bootstrap run is unfinished ($($existingState.phase)); use -Resume or inspect -Report before starting a new run"
            }
            if (-not $DryRun) {
                Save-BootstrapPriorRun $statePath ([string]$existingState.runId)
                if ($null -ne $existingReport) { Save-BootstrapPriorRun $reportPath ([string]$existingState.runId) }
            }
        }
        $state = New-BootstrapState $StateRoot $runId $SelectedProfile $DryRun
        $report = New-BootstrapReport $StateRoot $runId $SelectedProfile $DryRun
    } elseif ($null -ne $existingState) {
        $state = Ensure-BootstrapStateShape $existingState
        $runId = [string]$state.runId
        if ([string]::IsNullOrWhiteSpace($runId)) { throw "Prior Windows bootstrap state has no run ID: $statePath" }
        if (-not (Test-BootstrapRunId $runId)) { throw "Prior Windows bootstrap state has an invalid run ID: $statePath" }
        $runId = $runId.ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($RunId) -and $runId -cne $RunId.ToLowerInvariant()) {
            throw "Requested run ID does not match prior Windows bootstrap state: $statePath"
        }
        if ([string]$state.profile) { $SelectedProfile = [string]$state.profile }
        if ($Operation -eq 'Resume' -and [bool]$state.dryRun) { throw 'Dry-run state has no resumable work; start a normal run instead' }
        if ($Operation -eq 'Resume' -and [string]$state.phase -eq 'completed' -and -not $Force) {
            throw 'Previous Windows bootstrap run is already completed; start a new run or use -Report/-Verify'
        }
        if ($null -ne $existingReport) {
            $report = Ensure-BootstrapReportShape $existingReport
        } else {
            $report = New-BootstrapReport $StateRoot $runId $SelectedProfile ([bool]$state.dryRun)
        }
    } else {
        # Verification may run without a prior installation. It records a
        # diagnostic report but does not imply that an installation completed.
        $state = New-BootstrapState $StateRoot $runId $SelectedProfile $DryRun
        $report = New-BootstrapReport $StateRoot $runId $SelectedProfile $DryRun
    }

    if (-not $DryRun -and $Operation -ne 'Report') {
        foreach ($directory in @($StateRoot, $logDirectory)) {
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
        }
        if ($Operation -in @('Run', 'Resume', 'Cleanup')) {
            foreach ($directory in @($backupDirectory, $tempDirectory)) {
                if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                    New-Item -ItemType Directory -Path $directory -Force | Out-Null
                }
            }
        }
    }

    $resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        Get-BootstrapScriptRoot
    } else {
        [IO.Path]::GetFullPath($RepoRoot)
    }
    $logPath = Join-Path $logDirectory 'bootstrap.log'
    if ($null -ne $report) {
        if ($report -is [System.Collections.IDictionary]) {
            $report['logPath'] = $logPath
        } elseif ($null -ne $report.PSObject.Properties['logPath']) {
            $report.logPath = $logPath
        } else {
            $report | Add-Member -NotePropertyName 'logPath' -NotePropertyValue $logPath
        }
    }
    return [pscustomobject]@{
        StateRoot = $StateRoot
        StatePath = $statePath
        ReportPath = $reportPath
        LogPath = $logPath
        BackupRoot = $backupDirectory
        TempRoot = $tempDirectory
        RepoRoot = $resolvedRepoRoot
        BootstrapRoot = Get-BootstrapRoot $resolvedRepoRoot
        RunId = $runId
        DryRun = $DryRun
        Operation = $Operation
        Quiet = [bool]$Quiet
        Silent = [bool]$Silent
        State = $state
        Report = $report
        Lock = $null
    }
}

function Write-BootstrapLog($Context, [string]$Message, [string]$Level = 'INFO') {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Write-Verbose $line
    if (-not $Context.DryRun) {
        try { Add-Content -LiteralPath $Context.LogPath -Value $line -Encoding UTF8 } catch { }
    }
}

function Write-BootstrapConsole($Context, [string]$Message) {
    if ([bool](Get-BootstrapObjectProperty $Context 'Quiet')) { return }
    if ([bool](Get-BootstrapObjectProperty $Context 'Silent')) { return }
    Write-Host $Message
}

function Format-BootstrapStepLine([int]$Index, [int]$Total, [string]$Name, [string]$Status, [double]$Seconds) {
    $counter = if ($Total -gt 0) { '[' + $Index + '/' + $Total + ']' } else { '[' + $Index + ']' }
    if ([string]::IsNullOrWhiteSpace($Status)) { return ($counter + ' ' + $Name + ' ...') }
    return ('{0} {1} - {2} ({3:n1}s)' -f $counter, $Name, $Status, $Seconds)
}

function Save-BootstrapContext($Context) {
    $terminalOperation = $Context.State.phase -eq 'completed' -or $Context.Operation -eq 'Verify'
    if ($terminalOperation) {
        $finishedAt = [DateTime]::UtcNow.ToString('o')
        if ([string]::IsNullOrWhiteSpace([string]$Context.State.finishedAt)) { $Context.State.finishedAt = $finishedAt }
        if ([string]::IsNullOrWhiteSpace([string]$Context.Report.finishedAt)) { $Context.Report.finishedAt = $finishedAt }
    }
    $Context.Report.requiresReboot = [bool]$Context.State.requiresReboot
    $Context.Report.resumeTask = $Context.State.resumeTask
    $Context.Report.userPhase = $Context.State.userPhase
    $latest = @(Get-BootstrapLatestResults $Context.Report.results)
    $Context.Report.success = @($latest | Where-Object { $_.status -eq 'completed' })
    $Context.Report.failed = @($latest | Where-Object { $_.status -eq 'failed' })
    $Context.Report.failedCleaned = @($latest | Where-Object { $_.status -eq 'failed_cleaned' })
    $Context.Report.failedUncleaned = @($latest | Where-Object { $_.status -eq 'failed_uncleaned' })
    $Context.Report.skipped = @($latest | Where-Object { $_.status -eq 'skipped' })
    $Context.Report.manualRequired = @($latest | Where-Object { $_.status -eq 'manual_required' })
    $Context.Report.recoveryRequired = @($latest | Where-Object { $_.status -eq 'recovery_required' })
    $Context.State.completedComponents = @($latest | Where-Object { $_.status -eq 'completed' } | ForEach-Object { [string]$_.name })
    $Context.State.failedComponents = @($latest | Where-Object { $_.status -in @('failed', 'failed_cleaned', 'failed_uncleaned') } | ForEach-Object { [string]$_.name })
    $Context.State.skippedComponents = @($latest | Where-Object { $_.status -eq 'skipped' } | ForEach-Object { [string]$_.name })
    $Context.State.manualComponents = @($latest | Where-Object { $_.status -eq 'manual_required' } | ForEach-Object { [string]$_.name })
    $Context.State.recoveryComponents = @($latest | Where-Object { $_.status -eq 'recovery_required' } | ForEach-Object { [string]$_.name })
    if (-not $Context.DryRun) {
        Write-BootstrapJson $Context.StatePath $Context.State
        Write-BootstrapJson $Context.ReportPath $Context.Report
    }
}

function Add-BootstrapResult($Context, [string]$Name, [string]$Profile, [string]$Status, [string]$Message, $Details) {
    $allowed = @('completed', 'failed', 'failed_cleaned', 'failed_uncleaned', 'skipped', 'manual_required', 'recovery_required')
    if ($Status -notin $allowed) { throw "Invalid bootstrap result status: $Status" }
    $result = [ordered]@{
        name = $Name
        profile = $Profile
        status = $Status
        message = $Message
        at = [DateTime]::UtcNow.ToString('o')
        details = $Details
    }
    $Context.Report.results = @($Context.Report.results) + [pscustomobject]$result
    switch ($Status) {
        'completed' { $Context.State.completedComponents = @($Context.State.completedComponents) + $Name }
        'failed' { $Context.State.failedComponents = @($Context.State.failedComponents) + $Name }
        'failed_cleaned' { $Context.State.failedComponents = @($Context.State.failedComponents) + $Name }
        'failed_uncleaned' { $Context.State.failedComponents = @($Context.State.failedComponents) + $Name }
        'skipped' { $Context.State.skippedComponents = @($Context.State.skippedComponents) + $Name }
        'manual_required' { $Context.State.manualComponents = @($Context.State.manualComponents) + $Name }
        'recovery_required' { $Context.State.recoveryComponents = @($Context.State.recoveryComponents) + $Name }
    }
    $level = if ($Status -in @('failed', 'failed_cleaned', 'failed_uncleaned', 'recovery_required')) { 'ERROR' } else { 'INFO' }
    Write-BootstrapLog $Context "$Name [$Status] $Message" $level
    Save-BootstrapContext $Context
    return [pscustomobject]$result
}

function Invoke-BootstrapStep($Context, [string]$Name, [string]$Profile, [scriptblock]$Action) {
    $Context | Add-Member -NotePropertyName ActiveComponent -NotePropertyValue $Name -Force
    try {
        $result = & $Action
        if ($null -eq $result) { return Add-BootstrapResult $Context $Name $Profile 'completed' '' $null }
        if ($null -eq $result.PSObject.Properties['status']) {
            return Add-BootstrapResult $Context $Name $Profile 'completed' ([string]$result) $null
        }
        return Add-BootstrapResult $Context $Name $Profile ([string]$result.status) ([string]$result.message) $result.details
    } catch {
        return Add-BootstrapResult $Context $Name $Profile 'failed_uncleaned' $_.Exception.Message $null
    } finally {
        $Context.PSObject.Properties.Remove('ActiveComponent')
    }
}

function Enter-BootstrapLock($Context) {
    if ($Context.DryRun) { return }
    $path = Join-Path $Context.StateRoot 'bootstrap.lock'
    try {
        $Context.Lock = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw "Windows bootstrap is already running or lock is unavailable: $path"
    }
}

function Exit-BootstrapLock($Context) {
    if ($null -ne $Context.Lock) {
        $Context.Lock.Dispose()
        $Context.Lock = $null
    }
}

function Test-BootstrapAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-BootstrapTokenIntegritySid {
    try {
        $whoami = Join-Path $env:SystemRoot 'System32\whoami.exe'
        if (-not (Test-Path -LiteralPath $whoami -PathType Leaf)) { return '' }
        $output = (& $whoami /groups 2>$null | Out-String)
        $match = [regex]::Match($output, 'S-1-16-\d+')
        if ($match.Success) { return [string]$match.Value }
    } catch { }
    return ''
}

function Test-BootstrapElevationRequired([bool]$IsAdministrator, [string]$Operation, [bool]$NoElevate) {
    if ($IsAdministrator -or $NoElevate) { return $false }
    return [string]$Operation -in @('Run', 'Resume', 'Verify', 'Cleanup')
}

function Get-BootstrapElevatedArguments([string]$ScriptPath, $BoundParameters) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath))
    foreach ($name in @($BoundParameters.Keys)) {
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $arguments += ('-{0}' -f $name) }
            continue
        }
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $arguments += ('-{0}' -f $name)
        $arguments += ('"{0}"' -f ([string]$value -replace '"', '\"'))
    }
    return $arguments
}

function Get-BootstrapDriveFacts([string]$DeviceId) {
    $id = if ([string]::IsNullOrWhiteSpace($DeviceId)) { '' } else { $DeviceId.TrimEnd('\') }
    $disk = $null
    try { $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $id) -ErrorAction Stop | Select-Object -First 1 } catch { }
    if ($null -eq $disk) { return [pscustomobject]@{ Exists = $false; DriveType = 0; FreeBytes = 0 } }
    return [pscustomobject]@{ Exists = $true; DriveType = [int]$disk.DriveType; FreeBytes = [long]$disk.FreeSpace }
}

function Test-BootstrapPreferSecondaryDrive([int]$DriveType, [long]$FreeBytes, [long]$MinimumFreeBytes) {
    # DriveType 3 is a local fixed disk; removable/network drives are never preferred.
    return ($DriveType -eq 3) -and ($FreeBytes -ge $MinimumFreeBytes)
}

function Get-BootstrapInstallPolicy([long]$MinimumFreeBytes = 10737418240) {
    $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { 'C:' } else { $env:SystemDrive }
    $systemProgramFiles = if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) { ($systemDrive.TrimEnd('\') + '\Program Files') } else { $env:ProgramFiles }
    $facts = Get-BootstrapDriveFacts 'D:'
    $prefer = $facts.Exists -and (Test-BootstrapPreferSecondaryDrive $facts.DriveType $facts.FreeBytes $MinimumFreeBytes)
    return [pscustomobject]@{
        preferSecondaryDrive = [bool]$prefer
        preferredRoot = if ($prefer) { 'D:\Program Files' } else { $systemProgramFiles }
        fallbackRoot = $systemProgramFiles
        secondaryDrive = 'D:'
        secondaryDriveFreeBytes = [long]$facts.FreeBytes
        minimumFreeBytes = [long]$MinimumFreeBytes
    }
}

function Get-BootstrapItemInstallLocation($Item, $Context) {
    $template = [string](Get-BootstrapObjectProperty $Item 'installLocation')
    if ([string]::IsNullOrWhiteSpace($template)) { return '' }
    if ([string](Get-BootstrapObjectProperty $Item 'locationSupport') -eq 'none') { return '' }
    $policy = Get-BootstrapObjectProperty $Context 'InstallPolicy'
    if ($null -eq $policy) { return '' }
    if ([bool](Get-BootstrapObjectProperty $policy 'preferSecondaryDrive')) { return $template }
    $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { 'C:' } else { $env:SystemDrive }
    return ($template -replace '^[A-Za-z]:', $systemDrive)
}

function Get-BootstrapInstalledLocation($Item, [string]$RequestedLocation) {
    $probe = [string](Get-BootstrapObjectProperty $Item 'locationProbe')
    if ([string]::IsNullOrWhiteSpace($probe)) { return '' }
    $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { 'C:' } else { $env:SystemDrive }
    foreach ($candidate in @($RequestedLocation, ($RequestedLocation -replace '^[A-Za-z]:', $systemDrive))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate $probe) -PathType Leaf) { return $candidate }
    }
    return ''
}

function Test-BootstrapWindows11([string]$ProductName, [string]$BuildNumber) {
    if ([string]::IsNullOrWhiteSpace($ProductName)) { return $false }
    if ($ProductName -match '(?i)\bServer\b') { return $false }
    # Windows 11 commonly retains a Windows 10 ProductName in registry.
    if ($ProductName -notmatch '(?i)Windows\s+1[01]') { return $false }
    $build = 0
    if (-not [int]::TryParse([string]$BuildNumber, [ref]$build)) { return $false }
    return $build -ge 22000
}

function Get-BootstrapHostInfo {
    $version = $null
    $product = ''
    $build = ''
    try {
        $version = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $product = [string]$version.ProductName
        $build = [string]$version.CurrentBuildNumber
    } catch { }
    $identity = $null
    $sessionId = $null
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    } catch { }
    $integrityLevel = Get-BootstrapTokenIntegritySid
    return [pscustomobject]@{
        Platform = [Environment]::OSVersion.Platform
        ProductName = $product
        Build = $build
        Is64BitOS = [Environment]::Is64BitOperatingSystem
        Is64BitProcess = [Environment]::Is64BitProcess
        PowerShell = [string]$PSVersionTable.PSVersion
        IsAdministrator = Test-BootstrapAdministrator
        UserName = if ($null -ne $identity) { [string]$identity.Name } else { '' }
        UserSid = if ($null -ne $identity -and $null -ne $identity.User) { [string]$identity.User.Value } else { '' }
        SessionId = $sessionId
        IntegritySid = $integrityLevel
    }
}

function Assert-BootstrapHost($Context) {
    $info = Get-BootstrapHostInfo
    $Context.Report.host = $info
    if ($info.Platform -ne [PlatformID]::Win32NT) { throw 'Windows 11 is required' }
    if (-not (Test-BootstrapWindows11 ([string]$info.ProductName) ([string]$info.Build))) {
        throw "Windows 11 build 22000 or later is required; detected $($info.ProductName) build $($info.Build)"
    }
    if (-not $info.Is64BitOS) { throw '64-bit Windows is required' }
    if (-not $info.Is64BitProcess) { throw '64-bit PowerShell process is required' }
    if (-not $info.IsAdministrator) { throw 'Administrator privileges are required' }
    return $info
}

function Get-BootstrapCommandPath([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    foreach ($propertyName in @('Path', 'Source', 'Definition')) {
        $property = $command.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return $null
}

function Get-BootstrapPwshPath {
    $candidates = @()
    if ($PSVersionTable.PSVersion.Major -ge 7 -and -not [string]::IsNullOrWhiteSpace($PSHOME)) {
        $candidates += (Join-Path $PSHOME 'pwsh.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles})) {
        $candidates += (Join-Path ${env:ProgramFiles} 'PowerShell\7\pwsh.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe')
    }
    $command = Get-BootstrapCommandPath 'pwsh.exe'
    if ($command) { $candidates += $command }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function ConvertTo-BootstrapProcessArgument([string]$Argument) {
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    # Quote only when required: NSIS and other installers do not recognize
    # switches such as "/S" when they arrive wrapped in literal quotes.
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = [regex]::Replace([string]$Argument, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Stop-BootstrapProcessTree($Process) {
    if ($null -eq $Process) { return }
    $processId = $Process.Id
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
    try { & taskkill.exe /T /F /PID $processId 2>&1 | Out-Null } catch { }
}

function Copy-BootstrapStreamDelta([string]$Path, [int]$Position, [string]$LogPath, [bool]$Final = $false) {
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return $Position }
    $text = ''
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $Position }
    if ($text.Length -le $Position) { return $Position }
    $limit = $text.Length
    if (-not $Final) {
        $lastNewline = $text.LastIndexOf("`n")
        if ($lastNewline -lt 0) { return $Position }
        $limit = $lastNewline + 1
    }
    if ($limit -le $Position) { return $Position }
    $delta = $text.Substring($Position, $limit - $Position)
    foreach ($line in @($delta -split "`r?`n")) {
        $clean = ConvertTo-BootstrapSafeText $line
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        try { Add-Content -LiteralPath $LogPath -Value $clean -Encoding UTF8 } catch { }
    }
    return $limit
}

function Invoke-BootstrapExternalStreaming([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$LogPath) {
    # Redirect to temp files and tail them while the child runs, so long
    # installers (winget, Weasy/Dwall setup) leave a live trail in the log.
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    $argumentText = (@($Arguments) | ForEach-Object { ConvertTo-BootstrapProcessArgument ([string]$_) }) -join ' '
    $process = $null
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $argumentText -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -ErrorAction Stop
        $stdoutPosition = 0
        $stderrPosition = 0
        $timedOut = $false
        $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { $null }
        while (-not $process.HasExited) {
            $stdoutPosition = Copy-BootstrapStreamDelta $stdoutFile $stdoutPosition $LogPath
            $stderrPosition = Copy-BootstrapStreamDelta $stderrFile $stderrPosition $LogPath
            if ($null -ne $deadline -and (Get-Date) -gt $deadline) { $timedOut = $true; Stop-BootstrapProcessTree $process; break }
            Start-Sleep -Milliseconds 300
        }
        try { $process.WaitForExit() } catch { }
        $stdoutPosition = Copy-BootstrapStreamDelta $stdoutFile $stdoutPosition $LogPath $true
        $stderrPosition = Copy-BootstrapStreamDelta $stderrFile $stderrPosition $LogPath $true
        $stdout = ''
        $stderr = ''
        try { $stdout = [IO.File]::ReadAllText($stdoutFile) } catch { }
        try { $stderr = [IO.File]::ReadAllText($stderrFile) } catch { }
        $parts = @()
        if (-not [string]::IsNullOrEmpty($stdout)) { $parts += $stdout }
        if (-not [string]::IsNullOrEmpty($stderr)) { $parts += $stderr }
        $exitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }
        if ($timedOut) { $parts += "Timed out after $TimeoutSeconds seconds" }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = (ConvertTo-BootstrapSafeText (($parts | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)) }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-BootstrapExternal([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0, [string]$LogPath = '') {
    # wsl.exe writes redirected streams as UTF-16LE. Direct invocation lets the
    # host shell decode those bytes with its native-command code page, producing
    # NUL padding or corrupted diagnostics. Use explicit stream encoding only
    # for WSL; retain normal PowerShell native invocation for other tools.
    # A positive TimeoutSeconds forces the redirected path so a stalled
    # installer can be killed instead of blocking the whole run.
    $isWsl = [IO.Path]::GetFileName($FilePath) -ieq 'wsl.exe'
    $streaming = (-not $isWsl) -and (-not [string]::IsNullOrWhiteSpace($LogPath))
    $useProcess = $isWsl -or $TimeoutSeconds -gt 0 -or $streaming
    if ($streaming) {
        return Invoke-BootstrapExternalStreaming $FilePath $Arguments $TimeoutSeconds $LogPath
    }
    if ($useProcess) {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $argumentList = $startInfo.PSObject.Properties['ArgumentList']
        if ($null -ne $argumentList) {
            foreach ($argument in @($Arguments)) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        } else {
            $startInfo.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-BootstrapProcessArgument ([string]$_) }) -join ' '
        }
        if ([IO.Path]::GetFileName($FilePath) -ieq 'wsl.exe') {
            $startInfo.StandardOutputEncoding = [Text.Encoding]::Unicode
            $startInfo.StandardErrorEncoding = [Text.Encoding]::Unicode
        }
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { throw "Could not start external process: $FilePath" }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $timedOut = $false
            if ($TimeoutSeconds -gt 0) {
                if (-not $process.WaitForExit([int]($TimeoutSeconds * 1000))) {
                    $timedOut = $true
                    Stop-BootstrapProcessTree $process
                }
            } else {
                $process.WaitForExit()
            }
            $stdout = ''
            $stderr = ''
            try { $stdout = $stdoutTask.Result } catch { }
            try { $stderr = $stderrTask.Result } catch { }
            $parts = @()
            if (-not [string]::IsNullOrEmpty($stdout)) { $parts += $stdout }
            if (-not [string]::IsNullOrEmpty($stderr)) { $parts += $stderr }
            $exitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }
            if ($timedOut) { $parts += "Timed out after $TimeoutSeconds seconds" }
            return [pscustomobject]@{ ExitCode = $exitCode; Output = (ConvertTo-BootstrapSafeText ($parts -join [Environment]::NewLine)) }
        } finally {
            $process.Dispose()
        }
    }
    $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = (ConvertTo-BootstrapSafeText ($output -join [Environment]::NewLine)) }
}

function Get-BootstrapManifestItems([string]$ManifestDirectory, [string[]]$Files) {
    $items = @()
    $required = @('version', 'architecture', 'silentInstallArgs', 'uninstallCommand', 'source', 'checksum', 'verification')
    foreach ($file in $Files) {
        $path = Join-Path $ManifestDirectory $file
        $manifest = Read-BootstrapJson $path
        if ($null -eq $manifest -or $manifest.format -ne 1) { throw "Invalid bootstrap package manifest: $path" }
        foreach ($item in @($manifest.items)) {
            if ([string]::IsNullOrWhiteSpace([string]$item.name)) { throw "Package manifest item has no name: $path" }
            if ([string]::IsNullOrWhiteSpace([string]$item.mode)) { throw "Package manifest item has no mode: $($item.name)" }
            foreach ($field in $required) {
                if ($null -eq $item.PSObject.Properties[$field]) { throw "Package manifest item is missing '$field': $($item.name)" }
            }
            if ([string]$item.architecture -notin @('x64', 'all')) { throw "Unsupported package architecture for $($item.name): $($item.architecture)" }
            if ([string]::IsNullOrWhiteSpace([string]$item.version)) { throw "Package manifest item has no version policy: $($item.name)" }
            if ([string]::IsNullOrWhiteSpace([string]$item.source)) { throw "Package manifest item has no source: $($item.name)" }
            if ([string]::IsNullOrWhiteSpace([string]$item.checksum)) { throw "Package manifest item has no checksum/verification policy: $($item.name)" }
            if ($item.silentInstallArgs -is [string] -or $null -eq $item.silentInstallArgs) { throw "Package manifest item has invalid silentInstallArgs: $($item.name)" }
            if ($null -eq $item.uninstallCommand -or $item.uninstallCommand -is [string] -or [string]::IsNullOrWhiteSpace([string]$item.uninstallCommand.type)) { throw "Package manifest item has invalid uninstallCommand: $($item.name)" }
            if ($null -eq $item.uninstallCommand.args) { throw "Package manifest item uninstallCommand has no args: $($item.name)" }
            if ($null -eq $item.verification -or $item.verification -is [string] -or [string]::IsNullOrWhiteSpace([string]$item.verification.type)) { throw "Package manifest item has no verification metadata: $($item.name)" }
            if ($item.mode -eq 'winget' -and [string]::IsNullOrWhiteSpace([string]$item.wingetId)) { throw "WinGet item has no package ID: $($item.name)" }
            if ($item.mode -eq 'winget' -and $null -ne $item.PSObject.Properties['wingetSource'] -and [string]$item.wingetSource -notin @('winget', 'msstore')) { throw "Unsupported WinGet source for $($item.name): $($item.wingetSource)" }
            $itemExecutionContext = Get-BootstrapItemExecutionContext $item
            if ($itemExecutionContext -notin @('elevated', 'user')) { throw "Unsupported execution context for $($item.name): $itemExecutionContext" }
            if ($itemExecutionContext -eq 'user' -and [string]$item.mode -eq 'winget' -and
                -not (Test-BootstrapWinGetUserScope -InstallArguments @($item.silentInstallArgs))) {
                throw "User-context WinGet item requires --scope user: $($item.name)"
            }
            if ($item.mode -eq 'manual' -and [string]::IsNullOrWhiteSpace([string](Get-BootstrapObjectProperty $item 'reason'))) { throw "Manual item has no reason: $($item.name)" }
            $locationSupport = [string](Get-BootstrapObjectProperty $item 'locationSupport')
            if (-not [string]::IsNullOrWhiteSpace($locationSupport) -and $locationSupport -notin @('inno', 'msi', 'nsis', 'exe', 'portable', 'none')) { throw "Unsupported install location type for $($item.name): $locationSupport" }
            if ($item.mode -eq 'download') {
                $downloadUrl = [string](Get-BootstrapObjectProperty $item 'url')
                if ([string]::IsNullOrWhiteSpace($downloadUrl) -or $downloadUrl -notmatch '(?i)^https://') { throw "Download item has no HTTPS url: $($item.name)" }
                if ([string]$item.checksum -notmatch '(?i)^sha256:[0-9a-f]{64}$') { throw "Download item needs a sha256 checksum: $($item.name)" }
                if ([string]$item.uninstallCommand.type -ne 'registry-uninstall') { throw "Download item needs a registry-uninstall contract: $($item.name)" }
                if ([string]$item.verification.type -ne 'uninstall-registry' -or [string]::IsNullOrWhiteSpace([string]$item.verification.command)) { throw "Download item needs an uninstall-registry verification target: $($item.name)" }
            }
            if ($item.mode -eq 'portable-handoff') {
                $downloadUrl = [string](Get-BootstrapObjectProperty $item 'url')
                if ($itemExecutionContext -ne 'user') { throw "Portable handoff must use the user execution context: $($item.name)" }
                if ([string]::IsNullOrWhiteSpace($downloadUrl) -or $downloadUrl -notmatch '(?i)^https://') { throw "Portable handoff has no HTTPS url: $($item.name)" }
                if ([string]$item.checksum -notmatch '(?i)^sha256:[0-9a-f]{64}$') { throw "Portable handoff needs a sha256 checksum: $($item.name)" }
                if (@($item.silentInstallArgs).Count -ne 0) { throw "Portable handoff must not declare unattended installer arguments: $($item.name)" }
                if ([string]$item.uninstallCommand.type -ne 'manual') { throw "Portable handoff has an invalid uninstall contract: $($item.name)" }
                if ([string]::IsNullOrWhiteSpace([string](Get-BootstrapObjectProperty $item 'reason'))) { throw "Portable handoff has no interactive-boundary reason: $($item.name)" }
                if ([string]$item.verification.type -ne 'portable-layout' -or
                    -not (Test-BootstrapSafeRelativePath ([string](Get-BootstrapObjectProperty $item.verification 'launcher'))) -or
                    -not (Test-BootstrapSafeRelativePath ([string](Get-BootstrapObjectProperty $item.verification 'coreExecutable'))) -or
                    -not (Test-BootstrapSafeRelativePath ([string](Get-BootstrapObjectProperty $item 'portableDirectory')))) {
                    throw "Portable handoff has an invalid layout contract: $($item.name)"
                }
            }
            $items += $item
        }
    }
    return $items
}

function Test-BootstrapWingetInstalled([string]$Winget, [string]$Id) {
    $result = Invoke-BootstrapExternal $Winget @('list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ($result.ExitCode -ne 0) { return $false }
    return $result.Output -match [regex]::Escape($Id)
}

function Get-BootstrapWingetSource($Item) {
    $property = $Item.PSObject.Properties['wingetSource']
    if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return [string]$property.Value }
    $source = [string]$Item.source
    if ($source -match '(?i)^msstore:') { return 'msstore' }
    return 'winget'
}

function Invoke-BootstrapWingetInstall($Context, $Item, [string]$Winget) {
    if ([string]$Item.mode -eq 'manual') {
        return [pscustomobject]@{ status = 'manual_required'; message = [string]$Item.reason; details = $Item }
    }
    if ([string]$Item.mode -ne 'winget') {
        return [pscustomobject]@{ status = 'skipped'; message = 'Package has no supported unattended source'; details = $Item }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Item.wingetId)) {
        return [pscustomobject]@{ status = 'manual_required'; message = 'WinGet package ID is missing'; details = $Item }
    }
    if ($Context.DryRun) {
        return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: WinGet discovery/install not executed'; details = @{ id = $Item.wingetId; dryRun = $true } }
    }
    if ($null -eq $Winget) {
        return [pscustomobject]@{ status = 'failed_uncleaned'; message = 'winget.exe is unavailable'; details = $Item }
    }
    $before = Test-BootstrapWingetInstalled $Winget ([string]$Item.wingetId)
    if ($before) {
        return [pscustomobject]@{ status = 'completed'; message = 'Already installed'; details = @{ id = $Item.wingetId; before = $true; installed = $false } }
    }
    $args = @('install', '--id', [string]$Item.wingetId, '--exact', '--source', (Get-BootstrapWingetSource $Item))
    foreach ($argument in @($Item.silentInstallArgs)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$argument)) { $args += [string]$argument }
    }
    $requestedLocation = Get-BootstrapItemInstallLocation $Item $Context
    if (-not [string]::IsNullOrWhiteSpace($requestedLocation)) { $args += @('--location', $requestedLocation) }
    $result = Invoke-BootstrapExternal $Winget $args -TimeoutSeconds 900 -LogPath $Context.LogPath
    Write-BootstrapLog $Context ("winget $($Item.wingetId): $($result.Output)")
    if ($result.ExitCode -eq 0 -and (Test-BootstrapWingetInstalled $Winget ([string]$Item.wingetId))) {
        $Context.State.installedPackages = @($Context.State.installedPackages) + [pscustomobject]@{ id = $Item.wingetId; name = $Item.name; before = $false; at = [DateTime]::UtcNow.ToString('o') }
        Save-BootstrapContext $Context
        $details = @{ id = $Item.wingetId; before = $false; output = $result.Output }
        if (-not [string]::IsNullOrWhiteSpace($requestedLocation)) {
            $details.attemptedLocation = $requestedLocation
            $actualLocation = Get-BootstrapInstalledLocation $Item $requestedLocation
            if (-not [string]::IsNullOrWhiteSpace($actualLocation)) { $details.actualLocation = $actualLocation }
        }
        return [pscustomobject]@{ status = 'completed'; message = 'Installed and verified'; details = $details }
    }
    $cleanup = 'not attempted'
    if ([string]$Item.cleanupMode -eq 'winget-uninstall-if-new' -and (Test-BootstrapWingetInstalled $Winget ([string]$Item.wingetId))) {
        $uninstall = $Item.uninstallCommand
        if ($null -eq $uninstall -or $uninstall -is [string]) {
            $removeArgs = @('uninstall', '--id', [string]$Item.wingetId, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
        } else {
            $removeArgs = @()
            foreach ($argument in @($uninstall.args)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$argument)) { $removeArgs += ([string]$argument -replace '\{wingetId\}', [string]$Item.wingetId) }
            }
        }
        $remove = Invoke-BootstrapExternal $Winget $removeArgs -TimeoutSeconds 300 -LogPath $Context.LogPath
        $cleanup = if ($remove.ExitCode -eq 0 -and -not (Test-BootstrapWingetInstalled $Winget ([string]$Item.wingetId))) { 'removed' } else { 'incomplete' }
        $Context.State.cleanup = @($Context.State.cleanup) + [pscustomobject]@{ name = $Item.name; action = 'winget-uninstall'; status = $cleanup }
        Save-BootstrapContext $Context
    }
    $status = if ($cleanup -eq 'removed') { 'failed_cleaned' } else { 'failed_uncleaned' }
    return [pscustomobject]@{ status = $status; message = "WinGet install failed (exit $($result.ExitCode)); cleanup=$cleanup"; details = @{ id = $Item.wingetId; output = $result.Output; cleanup = $cleanup } }
}

function Get-BootstrapPathDigest([string]$Path) {
    $bytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (([BitConverter]::ToString($sha.ComputeHash($bytes))) -replace '-', '').Substring(0, 16).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Backup-BootstrapFile($Context, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $existing = @($Context.State.backups | Where-Object { $_.source -ieq $fullPath })
    if ($existing.Count -gt 0) {
        $entry = $existing[0]
        if (-not (Test-BootstrapPathWithinRoot ([string]$entry.backup) $Context.BackupRoot)) {
            throw "Bootstrap backup is outside backup root: $($entry.backup)"
        }
        if (-not (Test-Path -LiteralPath ([string]$entry.backup) -PathType Leaf) -or
            (Get-BootstrapFileSha256 ([string]$entry.backup)) -ne [string]$entry.sha256) {
            throw "Bootstrap backup is missing or changed: $($entry.backup)"
        }
        $changed = $false
        if ($Context.PSObject.Properties['ActiveComponent']) {
            if ($null -eq $entry.PSObject.Properties['usedBy']) {
                $entry | Add-Member -NotePropertyName usedBy -NotePropertyValue @()
                $changed = $true
            }
            if ([string]$Context.ActiveComponent -notin @($entry.usedBy)) {
                $entry.usedBy = @($entry.usedBy) + [string]$Context.ActiveComponent
                $changed = $true
            }
        }
        if ($changed) { Save-BootstrapContext $Context }
        return [string]$existing[0].backup
    }
    $name = ('{0}.{1}.{2}.bak' -f [IO.Path]::GetFileName($fullPath), $Context.RunId, (Get-BootstrapPathDigest $fullPath))
    $destination = Join-Path $Context.BackupRoot $name
    Copy-Item -LiteralPath $fullPath -Destination $destination -ErrorAction Stop
    $usedBy = @()
    if ($Context.PSObject.Properties['ActiveComponent']) { $usedBy = @([string]$Context.ActiveComponent) }
    $entry = [pscustomobject]@{
        source = $fullPath
        backup = $destination
        sha256 = Get-BootstrapFileSha256 $fullPath
        kind = 'preflight'
        usedBy = $usedBy
        at = [DateTime]::UtcNow.ToString('o')
    }
    $Context.State.backups = @($Context.State.backups) + $entry
    Save-BootstrapContext $Context
    return $destination
}

function Update-BootstrapManagedBlock($Context, [string]$Path, [string]$Block) {
    $start = '# >>> my-windows-config >>>'
    $end = '# <<< my-windows-config <<<'
    $wasPresent = Test-Path -LiteralPath $Path -PathType Leaf
    $old = ''
    if ($wasPresent) {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($null -ne $raw) { $old = [string]$raw }
    }
    $hasStart = $old.Contains($start)
    $hasEnd = $old.Contains($end)
    if ($hasStart -xor $hasEnd) { throw "PowerShell profile has an incomplete managed block: $Path" }
    if ($Context.DryRun) { return [pscustomobject]@{ status = 'skipped'; message = "Dry run: profile not changed: $Path"; details = @{ path = $Path } } }
    $managed = $start + [Environment]::NewLine + $Block.Trim() + [Environment]::NewLine + $end
    if ($hasStart) {
        $pattern = [regex]::Escape($start) + '.*?' + [regex]::Escape($end)
        $new = [regex]::Replace($old, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $managed }, [Text.RegularExpressions.RegexOptions]::Singleline)
    } elseif ([string]::IsNullOrWhiteSpace($old)) {
        $new = $managed + [Environment]::NewLine
    } else {
        $new = $old.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $managed + [Environment]::NewLine
    }
    if ($new -ceq $old) {
        return [pscustomobject]@{ status = 'completed'; message = "Managed block already current: $Path"; details = @{ path = $Path; changed = $false } }
    }
    $backup = $null
    if ($wasPresent) { $backup = Backup-BootstrapFile $Context $Path }
    Write-BootstrapTextAtomic $Path $new
    $managedHash = Get-BootstrapFileSha256 $Path
    if (-not $wasPresent) {
        $Context.State.createdPaths = @($Context.State.createdPaths) + $Path
        $Context.State.ownedFiles = @($Context.State.ownedFiles) + [pscustomobject]@{ path = [IO.Path]::GetFullPath($Path); sha256 = $managedHash; kind = 'profile-created'; component = [string]$Context.ActiveComponent }
    } else {
        $Context.State.managedFiles = @($Context.State.managedFiles) + [pscustomobject]@{ path = [IO.Path]::GetFullPath($Path); sha256 = $managedHash; backup = $backup; kind = 'profile-managed'; component = [string]$Context.ActiveComponent }
    }
    Save-BootstrapContext $Context
    return [pscustomobject]@{ status = 'completed'; message = "Managed block updated: $Path"; details = @{ path = $Path; changed = $true } }
}

function Remove-BootstrapResumeTask([string]$TaskName) {
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
    }
}

function Get-BootstrapResumeArguments($Context, [string]$ScriptPath) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath), '-Resume', '-StateRoot', ('"{0}"' -f $Context.StateRoot), '-Profile', [string]$Context.State.profile)
    $options = $Context.State.executionOptions
    if ($null -ne $options) {
        if ([bool]$options.skipRime) { $arguments += '-SkipRime' }
        if ([bool]$options.noOptional) { $arguments += '-NoOptional' }
        if ([bool]$options.noNetworkCheck) { $arguments += '-NoNetworkCheck' }
    }
    return ($arguments -join ' ')
}

function Register-BootstrapResumeTask($Context, [string]$ScriptPath, [string]$TaskName) {
    if ($Context.DryRun) {
        return [pscustomobject]@{ status = 'skipped'; message = "Dry run: resume task not created ($TaskName)"; details = @{ task = $TaskName } }
    }
    $pwsh = Get-BootstrapPwshPath
    $engine = if ($pwsh) { $pwsh } else { (Get-BootstrapCommandPath 'powershell.exe') }
    if (-not $engine) { return [pscustomobject]@{ status = 'manual_required'; message = 'No PowerShell host available to create resume task'; details = $null } }
    $arguments = Get-BootstrapResumeArguments $Context $ScriptPath
    try {
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            $action = New-ScheduledTaskAction -Execute $engine -Argument $arguments
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            # Resume from a normal user token. The entry point then runs any
            # user-context items before requesting one UAC elevation.
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        } else {
            & schtasks.exe /Create /TN $TaskName /SC ONLOGON /TR "`"$engine`" $arguments" /RL LIMITED /F | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "schtasks failed with exit code $LASTEXITCODE" }
        }
        $Context.State.resumeTask = $TaskName
        $Context.State.requiresReboot = $true
        Save-BootstrapContext $Context
        return [pscustomobject]@{ status = 'completed'; message = "Resume task created: $TaskName"; details = @{ task = $TaskName } }
    } catch {
        return [pscustomobject]@{ status = 'manual_required'; message = "Could not create resume task: $($_.Exception.Message)"; details = @{ task = $TaskName } }
    }
}

function ConvertFrom-BootstrapWslOutput([string]$Text) {
    if ($null -eq $Text) { return '' }
    # wsl.exe emits UTF-16-style NUL padding when stdout is redirected.
    return ([string]$Text).Replace(([string][char]0), [string]::Empty).Replace(([string][char]0xFEFF), [string]::Empty)
}

function Test-BootstrapWsl([string]$Distro = 'Ubuntu-24.04') {
    $wsl = Get-BootstrapCommandPath 'wsl.exe'
    if (-not $wsl) {
        return [pscustomobject]@{ available = $false; distro = $false; distroName = $null; version2 = $false; message = 'wsl.exe unavailable' }
    }
    $list = Invoke-BootstrapExternal $wsl @('--list', '--quiet')
    $listOutput = ConvertFrom-BootstrapWslOutput $list.Output
    $distroMatches = @($listOutput -split "`r?`n" | ForEach-Object { $_.Trim(' ', "`t") } | Where-Object { $_ -match '(?i)^Ubuntu(?:-[0-9]{2}\.[0-9]{2})?$' } | Select-Object -First 1)
    $distroName = if ($distroMatches.Count -gt 0) { [string]$distroMatches[0] } else { $null }
    $verbose = Invoke-BootstrapExternal $wsl @('--list', '--verbose')
    $verboseOutput = ConvertFrom-BootstrapWslOutput $verbose.Output
    $version2 = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$distroName)) {
        $escaped = [regex]::Escape([string]$distroName)
        $version2 = $verboseOutput -match "(?im)^\s*\*?\s*$escaped\s+\S+\s+2\s*$"
    }
    return [pscustomobject]@{
        available = ($list.ExitCode -eq 0 -and $verbose.ExitCode -eq 0)
        distro = -not [string]::IsNullOrWhiteSpace([string]$distroName)
        distroName = $distroName
        version2 = $version2
        message = ($verboseOutput.Trim())
    }
}

function Install-BootstrapWsl($Context, [string]$ScriptPath, [switch]$NoReboot) {
    if ($Context.DryRun) {
        return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: WSL discovery/installation not executed'; details = $null }
    }
    $wsl = Get-BootstrapCommandPath 'wsl.exe'
    if (-not $wsl) { return [pscustomobject]@{ status = 'failed_uncleaned'; message = 'wsl.exe is unavailable'; details = $null } }
    $before = Test-BootstrapWsl
    if ($before.distro -and $before.version2) {
        return [pscustomobject]@{ status = 'completed'; message = 'WSL 2 Ubuntu is already ready'; details = $before }
    }
    $result = Invoke-BootstrapExternal $wsl @('--install', '--distribution', 'Ubuntu-24.04', '--no-launch')
    Write-BootstrapLog $Context ("wsl install: $($result.Output)")
    $rebootText = $result.Output -match '(?i)restart|reboot|重新启动' -or $result.ExitCode -eq 3010
    if ($rebootText) {
        $taskName = 'WindowsBootstrap-Resume-' + $Context.RunId
        $resume = Register-BootstrapResumeTask $Context $ScriptPath $taskName
        if ($resume.status -eq 'completed') {
            $Context.State.nextPhase = 'wsl-verify'
            $Context.State.phase = 'awaiting-reboot'
            Save-BootstrapContext $Context
            if (-not $NoReboot) {
                Restart-Computer -Force
                return [pscustomobject]@{ status = 'skipped'; message = 'Restart initiated for WSL setup; resume task will verify WSL after logon'; details = @{ rebootPending = $true; task = $taskName } }
            }
            return [pscustomobject]@{ status = 'manual_required'; message = 'WSL requires restart; resume task is registered for the next interactive logon'; details = @{ rebootPending = $true; task = $taskName; output = $result.Output } }
        }
        return [pscustomobject]@{ status = 'manual_required'; message = 'WSL requires restart, but the resume task could not be created'; details = @{ output = $result.Output; resume = $resume } }
    }
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ status = 'failed_uncleaned'; message = "WSL install failed with exit code $($result.ExitCode)"; details = @{ output = $result.Output } }
    }
    $setDefault = Invoke-BootstrapExternal $wsl @('--set-default-version', '2')
    if ($setDefault.ExitCode -ne 0) {
        return [pscustomobject]@{ status = 'failed_uncleaned'; message = 'WSL default version could not be set to 2'; details = @{ output = $setDefault.Output } }
    }
    $after = Test-BootstrapWsl
    if (-not $after.distro) { return [pscustomobject]@{ status = 'manual_required'; message = 'WSL installed but Ubuntu distribution is not visible yet'; details = $after } }
    if (-not $after.version2) {
        $setVersion = Invoke-BootstrapExternal $wsl @('--set-version', [string]$after.distroName, '2')
        if ($setVersion.ExitCode -ne 0) { return [pscustomobject]@{ status = 'failed_uncleaned'; message = 'Ubuntu could not be converted to WSL 2'; details = @{ output = $setVersion.Output } } }
    }
    return [pscustomobject]@{ status = 'completed'; message = 'WSL 2 Ubuntu verified'; details = (Test-BootstrapWsl) }
}

function Get-BootstrapProfilePaths {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) { $documents = Join-Path $HOME 'Documents' }
    return @(
        (Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1')
    )
}

function Backup-BootstrapUserFiles($Context) {
    if ($Context.DryRun) {
        return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: user configuration was not copied'; details = $null }
    }
    $paths = @(Get-BootstrapProfilePaths)
    $backed = @()
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $backed += Backup-BootstrapFile $Context $path
        }
    }
    return [pscustomobject]@{ status = 'completed'; message = "Captured $($backed.Count) existing user configuration backup(s)"; details = @{ paths = $backed } }
}

function Get-BootstrapProfileBlock([string]$BootstrapRoot) {
    $path = Join-Path $BootstrapRoot 'config\powershell\profile.ps1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "PowerShell profile template missing: $path" }
    return Get-Content -LiteralPath $path -Raw
}

function Install-BootstrapPowerShellConfig($Context) {
    $block = Get-BootstrapProfileBlock $Context.BootstrapRoot
    $results = @()
    foreach ($path in (Get-BootstrapProfilePaths)) {
        $results += Update-BootstrapManagedBlock $Context $path $block
    }
    if (@($results | Where-Object { $_.status -eq 'manual_required' -or $_.status -like 'failed*' }).Count -gt 0) {
        return [pscustomobject]@{ status = 'manual_required'; message = 'One or more PowerShell profiles need review'; details = $results }
    }
    if ($Context.DryRun) { return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: PowerShell profiles unchanged'; details = $results } }
    return [pscustomobject]@{ status = 'completed'; message = 'PowerShell 5.1 and 7 profiles updated idempotently'; details = $results }
}

function Get-BootstrapFontManifest([string]$BootstrapRoot) {
    $path = Join-Path $BootstrapRoot 'packages\fonts.json'
    $manifest = Read-BootstrapJson $path
    if ($null -eq $manifest -or $manifest.format -ne 1) { throw "Invalid font manifest: $path" }
    foreach ($field in @('version', 'architecture', 'url', 'sha256', 'filePattern', 'source', 'checksum', 'verification')) {
        if ($null -eq $manifest.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$manifest.$field)) { throw "Font manifest is missing '$field': $path" }
    }
    if ([string]$manifest.architecture -notin @('all', 'x64')) { throw "Unsupported font architecture: $($manifest.architecture)" }
    if ([string]$manifest.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Font manifest SHA-256 is invalid: $path" }
    if ($null -eq $manifest.verification.type) { throw "Font manifest verification type is missing: $path" }
    return $manifest
}

function Get-BootstrapFileSha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha.ComputeHash($stream))) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Install-BootstrapFonts($Context) {
    $manifest = Get-BootstrapFontManifest $Context.BootstrapRoot
    $cache = Join-Path $Context.StateRoot 'downloads'
    $archive = Join-Path $cache ([IO.Path]::GetFileName(([Uri]$manifest.url).AbsolutePath))
    if ($Context.DryRun) { return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: font download/install not executed'; details = $manifest } }
    if (-not (Test-Path -LiteralPath $cache -PathType Container)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        Invoke-WebRequest -Uri ([string]$manifest.url) -OutFile "$archive.download" -UseBasicParsing -ErrorAction Stop
        $hash = Get-BootstrapFileSha256 "$archive.download"
        if ($hash -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw "Font archive SHA-256 mismatch: $hash" }
        Move-Item -LiteralPath "$archive.download" -Destination $archive -Force
    } elseif ((Get-BootstrapFileSha256 $archive) -ne ([string]$manifest.sha256).ToLowerInvariant()) {
        throw "Cached font archive SHA-256 mismatch: $archive"
    }
    $extract = Join-Path $Context.TempRoot ('font-' + $Context.RunId)
    if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $fontRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path -LiteralPath $fontRoot -PathType Container)) { New-Item -ItemType Directory -Path $fontRoot -Force | Out-Null }
    $fontKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path -LiteralPath $fontKey)) { New-Item -Path $fontKey -Force | Out-Null }
    $installed = @()
    $files = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object { $_.Name -match [string]$manifest.filePattern })
    if ($files.Count -eq 0) { throw 'JetBrains Mono Nerd Font archive contains no selected TTF files' }
    foreach ($file in $files) {
        $destination = Join-Path $fontRoot $file.Name
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            if ((Get-BootstrapFileSha256 $destination) -ne (Get-BootstrapFileSha256 $file.FullName)) {
                return [pscustomobject]@{ status = 'manual_required'; message = "Existing font differs; preserved: $destination"; details = @{ path = $destination } }
            }
        } else {
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
            $Context.State.createdPaths = @($Context.State.createdPaths) + $destination
            $Context.State.ownedFiles = @($Context.State.ownedFiles) + [pscustomobject]@{ path = [IO.Path]::GetFullPath($destination); sha256 = Get-BootstrapFileSha256 $destination; kind = 'font-file'; component = [string]$Context.ActiveComponent }
        }
        $display = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $property = Get-BootstrapRegistryValue $fontKey $display
        if ($null -eq $property) {
            New-ItemProperty -Path $fontKey -Name $display -Value $file.Name -PropertyType String -Force | Out-Null
            $Context.State.createdRegistryValues = @($Context.State.createdRegistryValues) + [pscustomobject]@{ path = $fontKey; name = $display; value = $file.Name; kind = 'font-registration'; component = [string]$Context.ActiveComponent }
        } elseif ([string]$property -ne [string]$file.Name) {
            return [pscustomobject]@{ status = 'manual_required'; message = "Existing font registration differs: $display"; details = @{ path = $fontKey; value = $property } }
        }
        $installed += $file.Name
    }
    Save-BootstrapContext $Context
    return [pscustomobject]@{ status = 'completed'; message = "Installed/verified $($installed.Count) JetBrains Mono Nerd Font files"; details = @{ files = $installed; directory = $fontRoot } }
}

function ConvertFrom-BootstrapCommandLine([string]$CommandLine) {
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return [pscustomobject]@{ Executable = $null; Arguments = @() } }
    $text = $CommandLine.Trim()
    $executable = $text
    $rest = ''
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -lt 1) { return [pscustomobject]@{ Executable = $null; Arguments = @() } }
        $executable = $text.Substring(1, $end - 1)
        $rest = $text.Substring($end + 1).Trim()
    } else {
        $space = $text.IndexOf(' ')
        if ($space -ge 0) {
            $executable = $text.Substring(0, $space)
            $rest = $text.Substring($space + 1).Trim()
        }
    }
    $arguments = if ([string]::IsNullOrWhiteSpace($rest)) { @() } else { @($rest -split '\s+') }
    return [pscustomobject]@{ Executable = $executable; Arguments = $arguments }
}

function Get-BootstrapUninstallEntry([string]$DisplayName) {
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return $null }
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($item in @(Get-ItemProperty $keys -ErrorAction SilentlyContinue)) {
        $nameProperty = $item.PSObject.Properties['DisplayName']
        if ($null -eq $nameProperty -or [string]$nameProperty.Value -ine $DisplayName) { continue }
        return [pscustomobject]@{
            DisplayName = [string]$nameProperty.Value
            DisplayVersion = [string](Get-BootstrapObjectProperty $item 'DisplayVersion')
            Publisher = [string](Get-BootstrapObjectProperty $item 'Publisher')
            InstallLocation = [string](Get-BootstrapObjectProperty $item 'InstallLocation')
            UninstallString = [string](Get-BootstrapObjectProperty $item 'UninstallString')
            QuietUninstallString = [string](Get-BootstrapObjectProperty $item 'QuietUninstallString')
        }
    }
    return $null
}

function Uninstall-BootstrapDownloadedApp($Context, $Item) {
    $displayName = [string]$Item.verification.command
    $entry = Get-BootstrapUninstallEntry $displayName
    if ($null -eq $entry) { return [pscustomobject]@{ status = 'absent'; message = "No uninstall entry for $displayName"; details = $null } }
    $command = if (-not [string]::IsNullOrWhiteSpace($entry.QuietUninstallString)) { $entry.QuietUninstallString } else { $entry.UninstallString }
    $parsed = ConvertFrom-BootstrapCommandLine $command
    if ([string]::IsNullOrWhiteSpace($parsed.Executable) -or -not (Test-Path -LiteralPath $parsed.Executable -PathType Leaf)) {
        return [pscustomobject]@{ status = 'failed'; message = "Uninstaller is unavailable for $displayName"; details = $entry }
    }
    $arguments = @($parsed.Arguments)
    foreach ($argument in @($Item.uninstallCommand.args)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$argument) -and -not ($arguments -contains [string]$argument)) { $arguments += [string]$argument }
    }
    $result = Invoke-BootstrapExternal $parsed.Executable $arguments -TimeoutSeconds 300 -LogPath $Context.LogPath
    Start-Sleep -Seconds 3
    if ($null -ne (Get-BootstrapUninstallEntry $displayName)) {
        return [pscustomobject]@{ status = 'failed'; message = "Uninstall did not remove $displayName (exit $($result.ExitCode))"; details = @{ output = $result.Output; entry = $entry } }
    }
    return [pscustomobject]@{ status = 'removed'; message = "Uninstalled $displayName"; details = @{ output = $result.Output } }
}

function Test-BootstrapDownloadCompletion($Result) {
    $details = Get-BootstrapObjectProperty $Result 'details'
    $displayName = [string](Get-BootstrapObjectProperty $details 'displayName')
    if ([string]::IsNullOrWhiteSpace($displayName)) { return $false }
    return ($null -ne (Get-BootstrapUninstallEntry $displayName))
}

function Install-BootstrapDownloadApp($Context, $Item) {
    $displayName = [string]$Item.verification.command
    if ([string]::IsNullOrWhiteSpace($displayName)) { return [pscustomobject]@{ status = 'manual_required'; message = 'Download item has no verification display name'; details = $Item } }
    $existing = Get-BootstrapUninstallEntry $displayName
    if ($null -ne $existing) {
        return [pscustomobject]@{ status = 'completed'; message = 'Already installed'; details = @{ displayName = $displayName; before = $true; installed = $false; version = $existing.DisplayVersion } }
    }
    if ($Context.DryRun) { return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: installer download not executed'; details = @{ url = [string]$Item.url; dryRun = $true } } }
    if ([string]$Item.checksum -notmatch '(?i)^sha256:([0-9a-f]{64})$') {
        return [pscustomobject]@{ status = 'failed_uncleaned'; message = "Invalid checksum policy: $($Item.checksum)"; details = $Item }
    }
    $expected = $Matches[1].ToLowerInvariant()
    $uri = [Uri]([string]$Item.url)
    $folder = Join-Path (Join-Path $Context.StateRoot 'downloads') ([string]$Item.name -replace '[^A-Za-z0-9._-]', '_')
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $file = Join-Path $folder ([IO.Path]::GetFileName($uri.AbsolutePath))
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile "$file.download" -UseBasicParsing -ErrorAction Stop
        $hash = Get-BootstrapFileSha256 "$file.download"
        if ($hash -ne $expected) {
            Remove-Item -LiteralPath "$file.download" -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ status = 'failed_uncleaned'; message = "Installer SHA-256 mismatch: $hash"; details = @{ url = $uri.AbsoluteUri; expected = $expected; actual = $hash } }
        }
        Move-Item -LiteralPath "$file.download" -Destination $file -Force
    } elseif ((Get-BootstrapFileSha256 $file) -ne $expected) {
        return [pscustomobject]@{ status = 'failed_uncleaned'; message = "Cached installer SHA-256 mismatch: $file"; details = @{ url = $uri.AbsoluteUri; expected = $expected } }
    }
    $arguments = @()
    foreach ($argument in @($Item.silentInstallArgs)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$argument)) { $arguments += [string]$argument }
    }
    $result = Invoke-BootstrapExternal $file $arguments -TimeoutSeconds 900 -LogPath $Context.LogPath
    # Tauri/NSIS registration can land slightly after the installer process
    # exits; poll instead of relying on a single fixed sleep.
    $entry = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds 2
        $entry = Get-BootstrapUninstallEntry $displayName
        if ($null -ne $entry) { break }
    }
    $details = [ordered]@{
        displayName = $displayName
        url = $uri.AbsoluteUri
        sha256 = $expected
        installer = $file
        output = $result.Output
        installed = ($null -ne $entry)
    }
    if ($null -ne $entry) {
        $details.version = $entry.DisplayVersion
        $details.installLocation = $entry.InstallLocation
        $Context.State.installedDownloads = @($Context.State.installedDownloads) + [pscustomobject]@{ name = $Item.name; displayName = $displayName; at = [DateTime]::UtcNow.ToString('o') }
        Save-BootstrapContext $Context
        return [pscustomobject]@{ status = 'completed'; message = "Installed and verified: $($entry.DisplayVersion)"; details = [pscustomobject]$details }
    }
    $cleanup = 'not attempted'
    if ([string]$Item.cleanupMode -eq 'download-uninstall-if-new') {
        $removal = Uninstall-BootstrapDownloadedApp $Context $Item
        $cleanup = [string]$removal.status
        $Context.State.cleanup = @($Context.State.cleanup) + [pscustomobject]@{ name = $Item.name; action = 'download-uninstall'; status = $cleanup }
    }
    $status = if ($cleanup -eq 'removed') { 'failed_cleaned' } else { 'failed_uncleaned' }
    if ($status -eq 'failed_uncleaned') {
        $Context.State.failedDownloads = @($Context.State.failedDownloads) + [pscustomobject]@{ name = [string]$Item.name; displayName = $displayName; uninstallArgs = @($Item.uninstallCommand.args) }
    }
    Save-BootstrapContext $Context
    return [pscustomobject]@{ status = $status; message = "Installer failed (exit $($result.ExitCode)); cleanup=$cleanup"; details = [pscustomobject]$details }
}

function Get-BootstrapPortableHandoffArchivePath([string]$StateRoot, $Item, [switch]$EnsureDirectory) {
    $uri = [Uri]([string](Get-BootstrapObjectProperty $Item 'url'))
    $leaf = [IO.Path]::GetFileName($uri.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Portable handoff URL has an unsafe archive name: $($uri.AbsoluteUri)"
    }
    $name = ([string](Get-BootstrapObjectProperty $Item 'name') -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Portable handoff item has no safe name' }
    $root = Assert-BootstrapPlainPath (Join-Path (Join-Path $StateRoot 'downloads') $name)
    if ($EnsureDirectory) { $root = Ensure-BootstrapPlainDirectory $root }
    return Assert-BootstrapPlainPath (Join-Path $root $leaf)
}

function Get-BootstrapPortableHandoffTarget($Item, [string]$PortableAppsRoot) {
    if ([string]::IsNullOrWhiteSpace($PortableAppsRoot)) { return '' }
    $directory = [string](Get-BootstrapObjectProperty $Item 'portableDirectory')
    if (-not (Test-BootstrapSafeRelativePath $directory)) { throw "Portable handoff directory is unsafe: $directory" }
    $root = Assert-BootstrapPlainPath $PortableAppsRoot
    if (Test-Path -LiteralPath $root -PathType Leaf) { throw "PortableApps root is not a directory: $root" }
    $target = Assert-BootstrapPlainPath (Join-Path $root ($directory -replace '/', '\\'))
    if (-not (Test-BootstrapPathWithinRoot $target $root)) { throw "Portable handoff target escapes the selected root: $target" }
    return $target
}

function Get-BootstrapPortableHandoffLayout($Item, [string]$PortableAppsRoot) {
    $target = Get-BootstrapPortableHandoffTarget $Item $PortableAppsRoot
    if ([string]::IsNullOrWhiteSpace($target)) {
        return [pscustomobject]@{ valid = $false; reason = 'PortableApps root was not supplied'; target = ''; launcher = ''; coreExecutable = '' }
    }
    $launcherRelative = [string](Get-BootstrapObjectProperty (Get-BootstrapObjectProperty $Item 'verification') 'launcher')
    $coreRelative = [string](Get-BootstrapObjectProperty (Get-BootstrapObjectProperty $Item 'verification') 'coreExecutable')
    $launcher = Assert-BootstrapPlainPath (Join-Path $target ($launcherRelative -replace '/', [string][IO.Path]::DirectorySeparatorChar))
    $core = Assert-BootstrapPlainPath (Join-Path $target ($coreRelative -replace '/', [string][IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        return [pscustomobject]@{ valid = $false; reason = 'Selected PortableApps application directory is absent'; target = $target; launcher = $launcher; coreExecutable = $core }
    }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        return [pscustomobject]@{ valid = $false; reason = 'PortableApps launcher is absent'; target = $target; launcher = $launcher; coreExecutable = $core }
    }
    if (-not (Test-Path -LiteralPath $core -PathType Leaf)) {
        return [pscustomobject]@{ valid = $false; reason = 'PotPlayer core executable is absent'; target = $target; launcher = $launcher; coreExecutable = $core }
    }
    try {
        $launcher = Assert-BootstrapPlainExistingFile $launcher 'PortableApps launcher'
        $core = Assert-BootstrapPlainExistingFile $core 'PotPlayer core executable'
    } catch {
        return [pscustomobject]@{ valid = $false; reason = $_.Exception.Message; target = $target; launcher = $launcher; coreExecutable = $core }
    }
    return [pscustomobject]@{
        valid = $true
        reason = ''
        target = $target
        launcher = $launcher
        coreExecutable = $core
        launcherSha256 = Get-BootstrapFileSha256 $launcher
        coreExecutableSha256 = Get-BootstrapFileSha256 $core
    }
}

function Get-BootstrapAuthenticodeInfo([string]$Path) {
    try {
        $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        $subject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
        $thumbprint = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Thumbprint } else { '' }
        return [pscustomobject]@{ status = [string]$signature.Status; subject = $subject; thumbprint = $thumbprint }
    } catch {
        return [pscustomobject]@{ status = 'unavailable'; subject = ''; thumbprint = ''; error = $_.Exception.Message }
    }
}

function Test-BootstrapPortableHandoffCompletion($Context, $Item, $Result) {
    $details = Get-BootstrapObjectProperty $Result 'details'
    $portableAppsRoot = [string](Get-BootstrapObjectProperty $details 'portableAppsRoot')
    $userPhaseRoot = [string](Get-BootstrapObjectProperty $details 'userPhaseRoot')
    if ([string]::IsNullOrWhiteSpace($portableAppsRoot) -or [string]::IsNullOrWhiteSpace($userPhaseRoot)) { return $false }
    try {
        $expectedRoot = Get-BootstrapUserPhaseStateRoot $Context.RunId
        if ([IO.Path]::GetFullPath($userPhaseRoot) -ine [IO.Path]::GetFullPath($expectedRoot)) { return $false }
        $archive = Get-BootstrapPortableHandoffArchivePath $userPhaseRoot $Item
        $archive = Assert-BootstrapPlainExistingFile $archive 'PortableApps archive'
        $expected = ([string](Get-BootstrapObjectProperty $Item 'checksum') -replace '(?i)^sha256:', '').ToLowerInvariant()
        if ((Get-BootstrapFileSha256 $archive) -ne $expected) { return $false }
        $layout = Get-BootstrapPortableHandoffLayout $Item $portableAppsRoot
        if (-not [bool]$layout.valid) { return $false }
        foreach ($field in @('launcherSha256', 'coreExecutableSha256')) {
            $recorded = [string](Get-BootstrapObjectProperty $details $field)
            $live = [string](Get-BootstrapObjectProperty $layout $field)
            if ([string]::IsNullOrWhiteSpace($recorded) -or $recorded -notmatch '^[0-9a-f]{64}$' -or $recorded -cne $live) { return $false }
        }
        return $true
    } catch { return $false }
}

function Install-BootstrapPortableHandoff($Context, $Item, [string]$PortableAppsRoot, [switch]$Launch, [switch]$Confirm) {
    if ($Context.DryRun) {
        return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: PortableApps download and interactive handoff not executed'; details = @{ url = [string]$Item.url; dryRun = $true } }
    }
    if ([string]$Item.checksum -notmatch '(?i)^sha256:([0-9a-f]{64})$') {
        return [pscustomobject]@{ status = 'failed_uncleaned'; message = "Invalid PortableApps checksum policy: $($Item.checksum)"; details = $Item }
    }
    $expected = $Matches[1].ToLowerInvariant()
    $uri = [Uri]([string]$Item.url)
    $archive = Get-BootstrapPortableHandoffArchivePath $Context.StateRoot $Item -EnsureDirectory
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        $temporary = "$archive.download"
        try {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $temporary -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop
            $actual = Get-BootstrapFileSha256 $temporary
            if ($actual -ne $expected) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ status = 'failed_cleaned'; message = "PortableApps archive SHA-256 mismatch: $actual"; details = @{ url = $uri.AbsoluteUri; expected = $expected; actual = $actual } }
            }
            Move-Item -LiteralPath $temporary -Destination $archive -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ status = 'failed_cleaned'; message = "PortableApps download failed: $($_.Exception.Message)"; details = @{ url = $uri.AbsoluteUri; archive = $archive } }
        }
    }
    $archive = Assert-BootstrapPlainExistingFile $archive 'PortableApps archive'
    $actual = Get-BootstrapFileSha256 $archive
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ status = 'failed_cleaned'; message = "Cached PortableApps archive SHA-256 mismatch: $actual"; details = @{ archive = $archive; expected = $expected; actual = $actual } }
    }
    $signature = Get-BootstrapAuthenticodeInfo $archive
    $layout = Get-BootstrapPortableHandoffLayout $Item $PortableAppsRoot
    $details = [ordered]@{
        url = $uri.AbsoluteUri
        archive = $archive
        sha256 = $expected
        signature = $signature
        portableAppsRoot = $PortableAppsRoot
        userPhaseRoot = $Context.StateRoot
        launcherSha256 = [string](Get-BootstrapObjectProperty $layout 'launcherSha256')
        coreExecutableSha256 = [string](Get-BootstrapObjectProperty $layout 'coreExecutableSha256')
        layout = $layout
    }
    if ($layout.valid -and $Confirm) {
        return [pscustomobject]@{ status = 'completed'; message = 'Interactive PortableApps deployment explicitly confirmed; launcher and core executable verified'; details = [pscustomobject]$details }
    }
    if ($layout.valid) {
        return [pscustomobject]@{ status = 'manual_required'; message = 'PortableApps layout exists, but user confirmation is required before recording interactive deployment as complete'; details = [pscustomobject]$details }
    }
    if ($Launch) {
        if ([string]::IsNullOrWhiteSpace($PortableAppsRoot)) {
            return [pscustomobject]@{ status = 'manual_required'; message = 'PortableApps archive verified; select -PortableAppsRoot before explicitly launching its interactive installer'; details = [pscustomobject]$details }
        }
        if ([string]$signature.status -in @('HashMismatch', 'NotTrusted', 'UnknownError')) {
            return [pscustomobject]@{ status = 'manual_required'; message = "PortableApps archive hash is verified, but Authenticode status '$($signature.status)' blocks automatic launch; inspect it manually"; details = [pscustomobject]$details }
        }
        try {
            $process = Start-Process -FilePath $archive -PassThru -ErrorAction Stop
            $details.launchPid = [int]$process.Id
            return [pscustomobject]@{ status = 'manual_required'; message = 'Verified PortableApps installer launched interactively; choose the requested destination, then rerun with -ConfirmPortableHandoff to verify the layout'; details = [pscustomobject]$details }
        } catch {
            return [pscustomobject]@{ status = 'manual_required'; message = "PortableApps archive verified but interactive launch failed: $($_.Exception.Message)"; details = [pscustomobject]$details }
        }
    }
    return [pscustomobject]@{ status = 'manual_required'; message = 'PortableApps archive downloaded and SHA-256 verified; inspect it and explicitly launch the interactive installer when ready' ; details = [pscustomobject]$details }
}

function Get-BootstrapRimeConfigCompatibility([string]$TargetRoot) {
    $configDirectory = Join-Path $env:LOCALAPPDATA 'config-rime'
    $configPath = Join-Path $configDirectory 'rime.json'
    $registryPath = 'HKCU:\Software\Rime\Weasel'
    $details = [ordered]@{
        configPath = $configPath
        targetRoot = $TargetRoot
        configuredRoot = $null
        selector = $null
        conflicts = @()
    }
    $conflicts = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = Read-BootstrapJson $configPath
            $formatProperty = $config.PSObject.Properties['format']
            $managerProperty = $config.PSObject.Properties['manager']
            $rootProperty = $config.PSObject.Properties['root']
            if ($null -eq $formatProperty -or $formatProperty.Value -ne 1 -or
                $null -eq $managerProperty -or [string]$managerProperty.Value -cne 'config-rime') {
                [void]$conflicts.Add("canonical config is not a managed config-rime file: $configPath")
            } elseif ($null -eq $rootProperty -or [string]::IsNullOrWhiteSpace([string]$rootProperty.Value)) {
                [void]$conflicts.Add("canonical config has no root: $configPath")
            } else {
                $configuredRoot = [string]$rootProperty.Value
                $details.configuredRoot = $configuredRoot
                if ([IO.Path]::GetFullPath($configuredRoot) -ine [IO.Path]::GetFullPath($TargetRoot)) {
                    [void]$conflicts.Add("canonical config points elsewhere: $configuredRoot")
                }
            }
        } catch {
            [void]$conflicts.Add("canonical config is unreadable: $configPath")
        }
    }
    $selectorSnapshot = $null
    try {
        $selectorSnapshot = Get-BootstrapRegistryValueSnapshot $registryPath 'RimeUserDir'
    } catch {
        [void]$conflicts.Add("RimeUserDir cannot be read: $registryPath")
        $selectorSnapshot = [pscustomobject]@{ Exists = $false; Value = $null }
    }
    if ($selectorSnapshot.Exists) {
        $selectorValue = [string]$selectorSnapshot.Value
        $details.selector = $selectorValue
        if ([string]::IsNullOrWhiteSpace($selectorValue)) {
            [void]$conflicts.Add('RimeUserDir exists but is empty')
        } else {
            try {
                $selectorFull = [IO.Path]::GetFullPath($selectorValue)
                if ([IO.Path]::GetFileName($selectorFull) -ine 'RimeConfig') {
                    [void]$conflicts.Add("RimeUserDir is not a RimeConfig selector: $selectorValue")
                } elseif ([IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($selectorFull)) -ine [IO.Path]::GetFullPath($TargetRoot)) {
                    [void]$conflicts.Add("RimeUserDir points elsewhere: $selectorValue")
                }
            } catch {
                [void]$conflicts.Add("RimeUserDir is not a valid local path: $selectorValue")
            }
        }
    }
    $details.conflicts = @($conflicts)
    if ($conflicts.Count -gt 0) {
        return [pscustomobject]@{
            compatible = $false
            message = 'Existing RIME configuration points to another root; preserved it for manual review'
            details = [pscustomobject]$details
        }
    }
    return [pscustomobject]@{
        compatible = $true
        message = 'Existing RIME configuration is compatible with bootstrap root'
        details = [pscustomobject]$details
    }
}

function Invoke-BootstrapRime($Context, [switch]$SkipRime) {
    if ($SkipRime) { return [pscustomobject]@{ status = 'skipped'; message = 'RIME component disabled by parameter'; details = $null } }
    $script = Join-Path $Context.RepoRoot 'windows\install.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { return [pscustomobject]@{ status = 'failed_uncleaned'; message = "RIME installer missing: $script"; details = $null } }
    if ($Context.DryRun) { return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: Mint RIME installer not executed'; details = @{ script = $script } } }
    $pwsh = Get-BootstrapPwshPath
    if (-not $pwsh) { return [pscustomobject]@{ status = 'manual_required'; message = 'PowerShell 7 is required for Mint RIME installer'; details = $null } }
    $rimeRoot = Join-Path $env:LOCALAPPDATA 'RimeProfiles'
    $configCheck = Get-BootstrapRimeConfigCompatibility $rimeRoot
    if (-not $configCheck.compatible) {
        return [pscustomobject]@{ status = 'manual_required'; message = [string]$configCheck.message; details = $configCheck.details }
    }
    $cache = Join-Path $Context.StateRoot 'downloads\rime'
    $reportPath = Join-Path $rimeRoot 'install-report.json'
    $beforeHash = $null
    $beforeWrite = [DateTime]::MinValue
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $beforeHash = Get-BootstrapFileSha256 $reportPath
        $beforeWrite = (Get-Item -LiteralPath $reportPath -Force).LastWriteTimeUtc
    }
    $startedAt = [DateTime]::UtcNow
    $args = @('-NoProfile','-File',$script,'-Profiles','mint','-InitialProfile','mint','-DeployMode','Quiet','-RimeRoot',$rimeRoot,'-CacheDirectory',$cache,'-NoRaycast','-PassThru')
    $result = Invoke-BootstrapExternal $pwsh $args -LogPath $Context.LogPath
    Write-BootstrapLog $Context ("Mint RIME: $($result.Output)")
    $reportHash = $null
    $report = $null
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $reportHash = Get-BootstrapFileSha256 $reportPath
        try { $report = Read-BootstrapJson $reportPath } catch { }
    }
    $reportWrite = if (Test-Path -LiteralPath $reportPath -PathType Leaf) { (Get-Item -LiteralPath $reportPath -Force).LastWriteTimeUtc } else { [DateTime]::MinValue }
    $reportStartedAt = [DateTime]::MinValue
    if ($null -ne $report -and $null -ne $report.PSObject.Properties['startedAt']) {
        try { $reportStartedAt = ConvertTo-BootstrapUtcDateTime $report.startedAt } catch { }
    }
    $details = [ordered]@{
        output = $result.Output
        root = $rimeRoot
        reportSha256 = $reportHash
        invocationStartedAtUtc = $startedAt.ToUniversalTime().ToString('o')
        reportWriteTimeUtc = $reportWrite.ToUniversalTime().ToString('o')
        reportStartedAtUtc = $reportStartedAt.ToString('o')
        fresh = $false
    }
    if ($result.ExitCode -ne 0) { return [pscustomobject]@{ status = 'failed_uncleaned'; message = "Mint RIME installer failed with exit code $($result.ExitCode)"; details = [pscustomobject]$details } }
    $freshWindowStart = $startedAt.AddSeconds(-2)
    $fresh = (Test-Path -LiteralPath $reportPath -PathType Leaf) -and
        ($reportWrite -ge $freshWindowStart) -and
        ($reportStartedAt -ge $startedAt) -and
        (-not $beforeHash -or $reportWrite -gt $beforeWrite) -and
        ($null -eq $beforeHash -or $reportHash -ne $beforeHash) -and
        ($null -ne $report) -and
        ($null -ne $report.PSObject.Properties['root']) -and
        ([IO.Path]::GetFullPath([string]$report.root) -ieq [IO.Path]::GetFullPath($rimeRoot))
    $details.fresh = [bool]$fresh
    if (-not $fresh) { return [pscustomobject]@{ status = 'failed_uncleaned'; message = 'Mint RIME installer returned success without a fresh readable install-report.json written during this invocation'; details = [pscustomobject]$details } }
    $mint = @($report.Results | Where-Object { [string]$_.Profile -eq 'mint' -and [string]$_.Status -eq 'completed' })
    if ($mint.Count -eq 0) { return [pscustomobject]@{ status = 'failed_uncleaned'; message = 'Mint RIME report has no completed mint result'; details = [pscustomobject]$details } }
    return [pscustomobject]@{ status = 'completed'; message = 'Mint RIME profile installed; input-method registration follows'; details = [pscustomobject]$details }
}

function Get-BootstrapLanguageSnapshot {
    $command = Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    $list = @(Get-WinUserLanguageList)
    return @($list | ForEach-Object { [pscustomobject]@{ LanguageTag = [string]$_.LanguageTag; InputMethodTips = @($_.InputMethodTips) } })
}

function Configure-BootstrapMintInputMethod($Context) {
    if ($Context.DryRun) {
        return [pscustomobject]@{ status = 'skipped'; message = 'Dry run: current-user input method discovery/configuration not executed'; details = $null }
    }
    $getList = Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue
    $setDefault = Get-Command Set-WinDefaultInputMethodOverride -ErrorAction SilentlyContinue
    if (-not $getList -or -not $setDefault) {
        return [pscustomobject]@{ status = 'manual_required'; message = 'Windows language cmdlets unavailable; configure Mint RIME in current-user language settings'; details = $null }
    }
    $before = Get-BootstrapLanguageSnapshot
    $Context.State.languageSnapshotBefore = $before
    Save-BootstrapContext $Context
    $rimeTip = $null
    $expectedTip = '0804:E0210804'
    $hasChinese = @($before | Where-Object { $_.LanguageTag -match '(?i)^zh' }).Count -gt 0
    $rimeEntry = @($before | ForEach-Object {
        foreach ($tip in @($_.InputMethodTips)) {
            if ([string]$tip -match '(?i)^0804:E02\d+0804$') { [pscustomobject]@{ Tip = [string]$tip } }
        }
    } | Select-Object -First 1)
    if ($rimeEntry.Count -gt 0) { $rimeTip = [string]$rimeEntry[0].Tip }
    $hasRime = -not [string]::IsNullOrWhiteSpace($rimeTip)
    if (-not $hasRime) { $rimeTip = $expectedTip }
    if (-not $hasChinese) {
        return [pscustomobject]@{ status = 'manual_required'; message = 'Chinese language is not present; preserved existing language list and did not add one automatically'; details = @{ before = $before } }
    }
    if (-not $hasRime) {
        return [pscustomobject]@{ status = 'manual_required'; message = 'Mint/Weasel input tip is not registered; preserved existing input methods'; details = @{ before = $before; expectedTip = $rimeTip } }
    }
    Set-WinDefaultInputMethodOverride -InputTip $rimeTip -ErrorAction Stop
    $after = Get-BootstrapLanguageSnapshot
    $english = @($after | Where-Object { $_.LanguageTag -match '(?i)^en' }).Count -gt 0
    if (-not $english) { return [pscustomobject]@{ status = 'manual_required'; message = 'Mint became available, but no English language entry was found; no existing entry was removed'; details = @{ after = $after } } }
    return [pscustomobject]@{ status = 'completed'; message = 'Mint/Weasel set as default Chinese input method; English entry preserved'; details = @{ inputTip = $rimeTip; before = $before; after = $after } }
}

function Get-BootstrapVerification($Context) {
    if ($Context.DryRun) { return @() }
    $checks = @()
    foreach ($entry in @(
        @{ Name = 'git'; Command = 'git.exe' },
        @{ Name = 'powershell7'; Command = 'pwsh.exe' },
        @{ Name = 'terminal'; Command = 'wt.exe' }
    )) {
        $checks += [pscustomobject]@{ name = $entry.Name; ok = ($null -ne (Get-BootstrapCommandPath $entry.Command)); detail = $entry.Command }
    }
    $wsl = Test-BootstrapWsl
    $checks += [pscustomobject]@{ name = 'wsl'; ok = $wsl.available -and $wsl.distro -and $wsl.version2; detail = $wsl.message }
    foreach ($path in (Get-BootstrapProfilePaths)) {
        $checks += [pscustomobject]@{ name = 'profile'; ok = ((Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-Content -LiteralPath $path -Raw) -match '# >>> my-windows-config >>>')); detail = $path }
    }
    # A completed component result is only trustworthy when its live state still
    # matches. Missing results are skipped for fresh -Verify diagnostics.
    foreach ($item in @(
        [pscustomobject]@{ name = 'JetBrains Mono Nerd Font'; mode = 'font' },
        [pscustomobject]@{ name = 'Mint RIME'; mode = 'rime' },
        [pscustomobject]@{ name = 'Mint input method default'; mode = 'input-method' },
        [pscustomobject]@{ name = 'PowerShell profiles'; mode = 'powershell-profile' }
    )) {
        $result = Get-BootstrapLatestResult $Context ([string]$item.name)
        if ($null -eq $result) { continue }
        $ok = Test-BootstrapComponentStillComplete $Context $item
        $checks += [pscustomobject]@{
            name = "component:$($item.name)"
            ok = [bool]$ok
            detail = if ($ok) { 'live completion check passed' } else { "live completion check failed for recorded status $($result.status)" }
        }
    }
    return $checks
}

function Test-BootstrapPathWithinRoot([string]$Path, [string]$Root) {
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $rootFull = [IO.Path]::GetFullPath($Root)
        if ($rootFull.Length -gt 1) { $rootFull = $rootFull.TrimEnd([char[]]@('\', '/')) }
        return $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-BootstrapOwnedCleanupPath([string]$Path) {
    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $roots += $env:LOCALAPPDATA }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if (-not [string]::IsNullOrWhiteSpace($documents)) { $roots += $documents }
    foreach ($root in $roots) {
        if (Test-BootstrapPathWithinRoot $Path ([string]$root)) { return $true }
    }
    return $false
}

function Test-BootstrapComponentNeedsCleanup($Context, [string]$Component) {
    if ([string]::IsNullOrWhiteSpace($Component)) { return $false }
    $result = Get-BootstrapLatestResult $Context $Component
    if ($null -eq $result) { return $false }
    return [string]$result.status -in @('failed', 'failed_cleaned', 'failed_uncleaned', 'recovery_required')
}

function Test-BootstrapPowerShellProfileCompletion($Context) {
    $block = Get-BootstrapProfileBlock $Context.BootstrapRoot
    $start = '# >>> my-windows-config >>>'
    $end = '# <<< my-windows-config <<<'
    $expected = $start + [Environment]::NewLine + $block.Trim() + [Environment]::NewLine + $end
    foreach ($path in (Get-BootstrapProfilePaths)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $text = Get-Content -LiteralPath $path -Raw
        $match = [regex]::Match($text, [regex]::Escape($start) + '.*?' + [regex]::Escape($end), [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $match.Success -or $match.Value.TrimEnd() -cne $expected.TrimEnd()) { return $false }
    }
    return $true
}

function Test-BootstrapFontCompletion($Context, $Result) {
    $details = Get-BootstrapObjectProperty $Result 'details'
    $files = @((Get-BootstrapObjectProperty $details 'files'))
    $directory = [string](Get-BootstrapObjectProperty $details 'directory')
    if ([string]::IsNullOrWhiteSpace($directory) -or $files.Count -eq 0) { return $false }
    $fontKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path -LiteralPath $fontKey)) { return $false }
    foreach ($name in $files) {
        $path = Join-Path $directory ([IO.Path]::GetFileName([string]$name))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $display = [IO.Path]::GetFileNameWithoutExtension([string]$name)
        $property = Get-BootstrapRegistryValue $fontKey $display
        if ([string]$property -ne [string]$name) { return $false }
    }
    return $true
}

function Test-BootstrapInputMethodCompletion($Result) {
    $details = Get-BootstrapObjectProperty $Result 'details'
    $inputTip = [string](Get-BootstrapObjectProperty $details 'inputTip')
    if ([string]::IsNullOrWhiteSpace($inputTip)) { return $false }
    try {
        $current = Get-BootstrapLanguageSnapshot
        if ($null -eq $current) { return $false }
        $hasTip = @($current | ForEach-Object {
            foreach ($tip in @($_.InputMethodTips)) {
                if ([string]$tip -ieq $inputTip) { $_ }
            }
        }).Count -gt 0
        $hasEnglish = @($current | Where-Object { $_.LanguageTag -match '(?i)^en' }).Count -gt 0
        if (-not $hasTip -or -not $hasEnglish) { return $false }
        $getDefault = Get-Command Get-WinDefaultInputMethodOverride -ErrorAction SilentlyContinue
        if ($null -ne $getDefault) {
            $default = Get-WinDefaultInputMethodOverride -ErrorAction Stop
            $defaultProperty = $default.PSObject.Properties['InputTip']
            if ($null -ne $defaultProperty -and [string]$defaultProperty.Value -ine $inputTip) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-BootstrapRimeCompletion($Result) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $false }
    $root = Join-Path $env:LOCALAPPDATA 'RimeProfiles'
    $reportPath = Join-Path $root 'install-report.json'
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { return $false }
    try {
        $details = Get-BootstrapObjectProperty $Result 'details'
        foreach ($field in @('root', 'reportSha256', 'invocationStartedAtUtc', 'reportWriteTimeUtc', 'reportStartedAtUtc', 'fresh')) {
            if ($null -eq (Get-BootstrapObjectProperty $details $field)) { return $false }
        }
        if (-not [bool](Get-BootstrapObjectProperty $details 'fresh')) { return $false }
        $resultRoot = [string](Get-BootstrapObjectProperty $details 'root')
        if ([string]::IsNullOrWhiteSpace($resultRoot) -or [IO.Path]::GetFullPath($resultRoot) -ine [IO.Path]::GetFullPath($root)) { return $false }
        $resultHash = [string](Get-BootstrapObjectProperty $details 'reportSha256')
        if ([string]::IsNullOrWhiteSpace($resultHash) -or $resultHash -notmatch '^[0-9a-fA-F]{64}$') { return $false }
        $invocationStartedAt = ConvertTo-BootstrapUtcDateTime (Get-BootstrapObjectProperty $details 'invocationStartedAtUtc')
        $recordedWrite = ConvertTo-BootstrapUtcDateTime (Get-BootstrapObjectProperty $details 'reportWriteTimeUtc')
        $recordedReportStartedAt = ConvertTo-BootstrapUtcDateTime (Get-BootstrapObjectProperty $details 'reportStartedAtUtc')
        $currentWrite = (Get-Item -LiteralPath $reportPath -Force).LastWriteTimeUtc
        if ($currentWrite -lt $invocationStartedAt.AddSeconds(-2) -or $currentWrite -lt $recordedWrite) { return $false }
        $report = Read-BootstrapJson $reportPath
        $reportStartedAt = ConvertTo-BootstrapUtcDateTime $report.startedAt
        if ($reportStartedAt -lt $invocationStartedAt -or $reportStartedAt -lt $recordedReportStartedAt) { return $false }
        if ($null -eq $report.PSObject.Properties['root'] -or [IO.Path]::GetFullPath([string]$report.root) -ine [IO.Path]::GetFullPath($root)) { return $false }
        $matches = @($report.Results | Where-Object { [string]$_.Profile -eq 'mint' -and [string]$_.Status -eq 'completed' })
        if ($matches.Count -eq 0) { return $false }
        return (Get-BootstrapFileSha256 $reportPath) -eq $resultHash.ToLowerInvariant()
    } catch { return $false }
}

function Test-BootstrapComponentStillComplete($Context, $Item) {
    if ($Context.DryRun) { return $false }
    try {
        $name = [string]$Item.name
        $result = Get-BootstrapLatestResult $Context $name
        if ($null -eq $result -or [string]$result.status -ne 'completed') { return $false }
        switch ([string]$Item.mode) {
            'winget' {
                $winget = Get-BootstrapCommandPath 'winget.exe'
                return ($null -ne $winget -and (Test-BootstrapWingetInstalled $winget ([string]$Item.wingetId)))
            }
            'wsl' {
                $check = Test-BootstrapWsl
                return ($check.available -and $check.distro -and $check.version2)
            }
            'font' { return (Test-BootstrapFontCompletion $Context $result) }
            'download' { return (Test-BootstrapDownloadCompletion $result) }
            'portable-handoff' { return (Test-BootstrapPortableHandoffCompletion $Context $Item $result) }
            'powershell-profile' { return (Test-BootstrapPowerShellProfileCompletion $Context) }
            'rime' { return (Test-BootstrapRimeCompletion $result) }
            'input-method' { return (Test-BootstrapInputMethodCompletion $result) }
            default { return $false }
        }
    } catch {
        Write-BootstrapLog $Context "Live completion check failed for $($Item.name): $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-BootstrapCleanup($Context) {
    if ($Context.DryRun) {
        return @([pscustomobject]@{ status = 'skipped'; reason = 'dry run: cleanup not executed' })
    }
    $outcomes = @()
    foreach ($entry in @($Context.State.ownedFiles)) {
        if (-not (Test-BootstrapComponentNeedsCleanup $Context ([string]$entry.component))) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$entry.path)) { continue }
        $full = [IO.Path]::GetFullPath([string]$entry.path)
        if (-not (Test-BootstrapOwnedCleanupPath $full)) {
            $outcomes += [pscustomobject]@{ path = $full; status = 'refused'; reason = 'outside owned cleanup roots' }
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $outcomes += [pscustomobject]@{ path = $full; status = 'absent' }
            } elseif ((Get-BootstrapFileSha256 $full) -ne [string]$entry.sha256) {
                $outcomes += [pscustomobject]@{ path = $full; status = 'preserved'; reason = 'file changed after bootstrap created it' }
            } else {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                $outcomes += [pscustomobject]@{ path = $full; status = 'removed' }
            }
        } catch {
            $outcomes += [pscustomobject]@{ path = $full; status = 'failed'; reason = $_.Exception.Message }
        }
    }
    foreach ($entry in @($Context.State.createdRegistryValues)) {
        if (-not (Test-BootstrapComponentNeedsCleanup $Context ([string]$entry.component)) ) { continue }
        if ([string]$entry.path -ine 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') {
            $outcomes += [pscustomobject]@{ path = "$($entry.path)::$($entry.name)"; status = 'refused'; reason = 'registry path is outside bootstrap-owned font registrations' }
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath ([string]$entry.path) -PathType Container)) {
                $outcomes += [pscustomobject]@{ path = "$($entry.path)::$($entry.name)"; status = 'absent' }
                continue
            }
            $property = (Get-ItemProperty -Path ([string]$entry.path) -Name ([string]$entry.name) -ErrorAction SilentlyContinue).PSObject.Properties[[string]$entry.name]
            if ($null -eq $property) {
                $outcomes += [pscustomobject]@{ path = "$($entry.path)::$($entry.name)"; status = 'absent' }
            } elseif ([string]$property.Value -ne [string]$entry.value) {
                $outcomes += [pscustomobject]@{ path = "$($entry.path)::$($entry.name)"; status = 'preserved'; reason = 'registry value changed after bootstrap created it' }
            } else {
                Remove-ItemProperty -Path ([string]$entry.path) -Name ([string]$entry.name) -ErrorAction Stop
                $outcomes += [pscustomobject]@{ path = "$($entry.path)::$($entry.name)"; status = 'removed' }
            }
        } catch {
            $outcomes += [pscustomobject]@{ path = "$($entry.path)::$($entry.name)"; status = 'failed'; reason = $_.Exception.Message }
        }
    }
    foreach ($entry in @($Context.State.failedDownloads)) {
        if (-not (Test-BootstrapComponentNeedsCleanup $Context ([string]$entry.name))) { continue }
        $synthetic = [pscustomobject]@{
            verification = [pscustomobject]@{ command = [string]$entry.displayName }
            uninstallCommand = [pscustomobject]@{ args = @($entry.uninstallArgs) }
        }
        $outcome = Uninstall-BootstrapDownloadedApp $Context $synthetic
        $outcomes += [pscustomobject]@{ path = [string]$entry.displayName; status = $outcome.status; reason = $outcome.message }
    }
    $restoredSources = @()
    $managedLatest = @{}
    $managedSources = @{}
    foreach ($entry in @($Context.State.managedFiles)) {
        $key = [string]$entry.path
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $fullKey = [IO.Path]::GetFullPath($key).ToLowerInvariant()
            $managedLatest[$fullKey] = $entry
            $managedSources[$fullKey] = $true
        }
    }
    foreach ($entry in @($managedLatest.Values)) {
        if (-not (Test-BootstrapComponentNeedsCleanup $Context ([string]$entry.component))) { continue }
        $source = [string]$entry.path
        $copy = [string]$entry.backup
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($copy)) {
            $outcomes += [pscustomobject]@{ path = $source; status = 'preserved'; reason = 'managed profile backup is unavailable' }
            continue
        }
        $full = [IO.Path]::GetFullPath($source)
        if (-not (Test-BootstrapOwnedCleanupPath $full)) {
            $outcomes += [pscustomobject]@{ path = $full; status = 'refused'; reason = 'outside owned cleanup roots' }
            continue
        }
        if (-not (Test-BootstrapPathWithinRoot $copy $Context.BackupRoot)) {
            $outcomes += [pscustomobject]@{ path = $full; status = 'refused'; reason = 'managed profile backup is outside bootstrap backup root' }
            continue
        }
        $copy = [IO.Path]::GetFullPath($copy)
        try {
            $backupEntry = @($Context.State.backups | Where-Object {
                [string]$_.backup -ieq $copy -and [string]$_.source -ieq $full
            } | Select-Object -First 1)
            if ($backupEntry.Count -eq 0 -or -not (Test-Path -LiteralPath $copy -PathType Leaf) -or
                (Get-BootstrapFileSha256 $copy) -ne [string]$backupEntry[0].sha256) {
                $outcomes += [pscustomobject]@{ path = $full; status = 'preserved'; reason = 'managed profile backup is missing or changed' }
                continue
            }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $parent = Split-Path -Parent $full
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item -LiteralPath $copy -Destination $full -ErrorAction Stop
                $restoredSources += $full
                $outcomes += [pscustomobject]@{ path = $full; status = 'restored' }
            } elseif ((Get-BootstrapFileSha256 $full) -ne [string]$entry.sha256) {
                $outcomes += [pscustomobject]@{ path = $full; status = 'preserved'; reason = 'managed profile changed after bootstrap update' }
            } else {
                Copy-Item -LiteralPath $copy -Destination $full -Force -ErrorAction Stop
                $restoredSources += $full
                $outcomes += [pscustomobject]@{ path = $full; status = 'restored' }
            }
        } catch {
            $outcomes += [pscustomobject]@{ path = $full; status = 'failed'; reason = $_.Exception.Message }
        }
    }
    foreach ($backup in @($Context.State.backups)) {
        $usedBy = @()
        if ($null -ne $backup.PSObject.Properties['usedBy']) { $usedBy = @($backup.usedBy) }
        $needsCleanup = @($usedBy | Where-Object { Test-BootstrapComponentNeedsCleanup $Context ([string]$_) }).Count -gt 0
        if (-not $needsCleanup) { continue }
        $source = [string]$backup.source
        $copy = [string]$backup.backup
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($copy)) { continue }
        $fullSource = [IO.Path]::GetFullPath($source)
        # A source tracked by managedFiles has a newer, component-specific
        # fingerprint. Never let an older generic backup record restore it when
        # managed cleanup intentionally preserved or skipped the latest write.
        if ($managedSources.ContainsKey($fullSource.ToLowerInvariant())) { continue }
        if (-not (Test-BootstrapOwnedCleanupPath $fullSource)) {
            $outcomes += [pscustomobject]@{ path = $fullSource; status = 'refused'; reason = 'outside owned cleanup roots' }
            continue
        }
        if (-not (Test-BootstrapPathWithinRoot $copy $Context.BackupRoot)) {
            $outcomes += [pscustomobject]@{ path = $fullSource; status = 'refused'; reason = 'backup outside bootstrap backup root' }
            continue
        }
        $copy = [IO.Path]::GetFullPath($copy)
        if ($restoredSources -contains $fullSource) { continue }
        try {
            $parent = Split-Path -Parent $fullSource
            if (-not (Test-Path -LiteralPath $copy -PathType Leaf) -or
                (Get-BootstrapFileSha256 $copy) -ne [string]$backup.sha256) {
                $outcomes += [pscustomobject]@{ path = $source; status = 'preserved'; reason = 'backup unavailable or changed' }
            } elseif (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item -LiteralPath $copy -Destination $source -ErrorAction Stop
                $outcomes += [pscustomobject]@{ path = $source; status = 'restored' }
            } elseif ((Get-BootstrapFileSha256 $source) -eq [string]$backup.sha256) {
                $outcomes += [pscustomobject]@{ path = $source; status = 'unchanged' }
            } else {
                $outcomes += [pscustomobject]@{ path = $source; status = 'preserved'; reason = 'file changed after bootstrap update' }
            }
        } catch {
            $outcomes += [pscustomobject]@{ path = $source; status = 'failed'; reason = $_.Exception.Message }
        }
    }
    $Context.State.cleanup = @($Context.State.cleanup) + $outcomes
    Save-BootstrapContext $Context
    return $outcomes
}
