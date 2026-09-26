#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-RimePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full -eq $root) { return $full }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-RimeRoot($Explicit, $Configured, $Managed, $Marked, $Local) {
    foreach ($candidate in @($Explicit, $Configured, $Managed, $Marked, $Local)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }
    throw 'No RIME root available'
}

function Get-RimeNextProfile([string]$Current) {
    switch ($Current) {
        ice { return 'mint' }
        mint { return 'moqi' }
        moqi { return 'ice' }
        default { throw "Unknown profile: $Current" }
    }
}

function Get-RimeProfileDirectory([string]$Root, [string]$Profile) {
    $definition = Get-RimeProfileDefinition $Profile $false
    $name = switch ($definition.Name) {
        ice { 'Rime_Ice' }
        mint { 'Rime_Mint' }
        moqi { 'Rime_Moqi' }
        default { throw "Unknown profile: $Profile" }
    }
    return Get-RimeChildPath $Root (Join-Path 'profiles' $name)
}

function Get-RimeSelectorPath([string]$Root) {
    Assert-RimePlainPath $Root
    return [IO.Path]::GetFullPath((Join-Path $Root 'RimeConfig'))
}

function Get-RimeJsonValue([string]$Path, [string]$Property) {
    $object = Read-RimeJson $Path
    $entry = $object.PSObject.Properties[$Property]
    if ($null -eq $entry) { throw "Missing JSON property: $Property" }
    return [string]$entry.Value
}

function Assert-RimePlainPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is required' }
    $raw = [string]$Path
    # Managed roots are local directories. Reject UNC, Win32/NT device namespaces,
    # drive-relative paths, and alternate data streams before normalization.
    if ($raw -match '^(?:\\\\|//|\\)') { throw "Unsafe UNC or device path: $Path" }
    if ($raw -match '[\x00-\x1f]') { throw "Invalid path: $Path" }
    if ($raw -match '[*?\[\]]') { throw "Unsafe provider wildcard path: $Path" }
    if ($raw -match '^[A-Za-z]:') {
        if ($raw.Length -le 2 -or $raw[2] -notin @([char]92, [char]47)) {
            throw "Unsafe drive-relative path: $Path"
        }
        $remainder = $raw.Substring(2)
    } else {
        $remainder = $raw
    }
    if ($remainder.Contains(':')) { throw "Unsafe alternate data stream path: $Path" }
    $segments = @($remainder -split '[\\/]') | Where-Object { -not [string]::IsNullOrEmpty($_) }
    foreach ($segment in $segments) {
        if ($segment -in @('.', '..') -or $segment -match '[. ]$' -or
            $segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "Unsafe Windows path alias: $Path"
        }
    }
    # Inspect existing ancestors too: a harmless leaf below a Junction is not safe.
    try { $cursor = [IO.Path]::GetFullPath($raw) }
    catch { throw "Invalid path: $Path" }
    while ($cursor) {
        $item = $null
        try {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        } catch {
            if ([string]$_.CategoryInfo.Category -ne 'ObjectNotFound') {
                throw "Cannot inspect path safely: $cursor ($($_.Exception.Message))"
            }
        }
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unsafe reparse path: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Ensure-RimePlainDirectory([string]$Path) {
    Assert-RimePlainPath $Path
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "RIME directory path is not a directory: $Path" }
    } else {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
    }
    Assert-RimePlainPath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "RIME directory creation failed: $Path" }
    return [IO.Path]::GetFullPath($Path)
}

function New-RimePlainDirectory([string]$Path, [string]$Purpose = 'RIME directory') {
    Assert-RimePlainPath $Path
    $full = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) { throw "$Purpose already exists: $full" }
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw "$Purpose has no parent directory: $full" }
    Ensure-RimePlainDirectory $parent | Out-Null
    Assert-RimePlainExistingDirectory $parent "$Purpose parent directory" | Out-Null
    Assert-RimePlainPath $full
    if (Test-Path -LiteralPath $full) { throw "$Purpose appeared during creation: $full" }
    try {
        New-Item -ItemType Directory -Path $full -ErrorAction Stop | Out-Null
    } catch {
        if (Test-Path -LiteralPath $full) { throw "$Purpose appeared during creation: $full ($($_.Exception.Message))" }
        throw
    }
    return Assert-RimePlainExistingDirectory $full $Purpose
}

function Assert-RimeSafeRelativePath([string]$Relative, [bool]$AllowTrailingSlash = $false) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw "Unsafe relative path: $Relative" }
    $normalized = $Relative -replace '\\', '/'
    if ($AllowTrailingSlash) { $normalized = $normalized.TrimEnd('/') }
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        ((-not $AllowTrailingSlash) -and $normalized.EndsWith('/')) -or
        $normalized -match '(^/|//|[:<>"|?*\x00-\x1f]|(^|/)\.\.?(/|$))') {
        throw "Unsafe relative path: $Relative"
    }
    foreach ($segment in $normalized.Split('/')) {
        if ($segment -match '[. ]$' -or $segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "Unsafe relative path: $Relative"
        }
    }
}

function Get-RimeChildPath([string]$Root, [string]$Relative) {
    Assert-RimePlainPath $Root
    Assert-RimeSafeRelativePath $Relative
    $path = Join-Path $Root ($Relative -replace '[/\\]', [IO.Path]::DirectorySeparatorChar)
    Assert-RimePlainPath $path
    return [IO.Path]::GetFullPath($path)
}

function Assert-RimePlainExistingFile([string]$Path, [string]$Purpose = 'RIME file') {
    Assert-RimePlainPath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Purpose is missing or is not a file: $Path" }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$Purpose is not a plain file: $Path"
    }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-RimePlainExistingDirectory([string]$Path, [string]$Purpose = 'RIME directory') {
    Assert-RimePlainPath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Purpose is missing or is not a directory: $Path" }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$Purpose is not a plain directory: $Path"
    }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-RimePlainDirectoryTree([string]$Path, [string]$Purpose = 'RIME directory tree') {
    $root = Assert-RimePlainExistingDirectory $Path $Purpose
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $directory = Assert-RimePlainExistingDirectory $pending.Pop() $Purpose
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Purpose contains unsafe reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $child = Assert-RimePlainExistingDirectory $item.FullName $Purpose
                $pending.Push($child)
            } else {
                Assert-RimePlainExistingFile $item.FullName $Purpose | Out-Null
            }
        }
    }
    return Assert-RimePlainExistingDirectory $root $Purpose
}

function Assert-RimePlainWriteTarget([string]$Path) {
    Assert-RimePlainPath $Path
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw "RIME write target has no parent: $Path" }
    Ensure-RimePlainDirectory $parent | Out-Null
    # Recheck after parent creation because another writer can replace an ancestor.
    Assert-RimePlainPath $parent
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "RIME write target is not a plain file: $full"
        }
    }
    Assert-RimePlainPath $full
    return $full
}

function Assert-RimePlainNewWriteTarget([string]$Path, [string]$Purpose = 'RIME file') {
    $target = Assert-RimePlainWriteTarget $Path
    if ([IO.File]::Exists($target)) { throw "$Purpose already exists: $target" }
    return $target
}

function Open-RimeNewFileForWrite([string]$Path, [string]$Purpose = 'RIME file') {
    $target = Assert-RimePlainNewWriteTarget $Path $Purpose
    try {
        return [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw "$Purpose appeared during create: $target ($($_.Exception.Message))"
    }
}

function Write-RimeNewTextFile([string]$Path, [string]$Content, [string]$Purpose = 'RIME generated file') {
    $stream = Open-RimeNewFileForWrite $Path $Purpose
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    return Assert-RimePlainExistingFile $Path $Purpose
}

function Copy-RimeFileToNewFile([string]$Source, [string]$Destination, [string]$Purpose = 'RIME file copy') {
    $sourcePath = Assert-RimePlainExistingFile $Source "$Purpose source"
    $destinationPath = Assert-RimePlainNewWriteTarget $Destination "$Purpose destination"
    $sourcePath = Assert-RimePlainExistingFile $sourcePath "$Purpose source"
    $input = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $output = Open-RimeNewFileForWrite $destinationPath "$Purpose destination"
        try { $input.CopyTo($output) } finally { $output.Dispose() }
    } finally { $input.Dispose() }
    return Assert-RimePlainExistingFile $destinationPath "$Purpose destination"
}

function Write-RimeNewJson([string]$Path, $Value, [string]$Purpose = 'RIME JSON file') {
    $text = $Value | ConvertTo-Json -Depth 20
    # Deliberately emit nothing: callers treat this as a side-effect writer, and a
    # leaked return value turns their result objects into mixed arrays.
    Write-RimeNewTextFile $Path $text $Purpose | Out-Null
}

function Read-RimeJson([string]$Path) {
    $file = Assert-RimePlainExistingFile $Path 'RIME JSON file'
    return ([IO.File]::ReadAllText($file) | ConvertFrom-Json)
}

function Write-RimeJson([string]$Path, $Value) {
    $destination = Assert-RimePlainWriteTarget $Path
    $temporary = Assert-RimePlainWriteTarget "$destination.$([guid]::NewGuid().ToString('N')).tmp"
    $text = $Value | ConvertTo-Json -Depth 20
    $temporary = Write-RimeNewTextFile $temporary $text 'RIME JSON temporary file'
    $temporary = Assert-RimePlainExistingFile $temporary 'RIME JSON temporary file'
    $destination = Assert-RimePlainWriteTarget $destination
    if ([IO.File]::Exists($destination)) {
        $temporary = Assert-RimePlainExistingFile $temporary 'RIME JSON temporary file'
        $destination = Assert-RimePlainExistingFile $destination 'RIME JSON destination file'
        [IO.File]::Replace($temporary, $destination, [NullString]::Value)
        return
    }
    $temporary = Assert-RimePlainExistingFile $temporary 'RIME JSON temporary file'
    $destination = Assert-RimePlainWriteTarget $destination
    if ([IO.File]::Exists($destination)) { throw "RIME JSON destination appeared during write: $destination" }
    [IO.File]::Move($temporary, $destination)
    # On any earlier failure, preserve the unique temporary file. Without a
    # handle-relative identity check, cleanup could delete a replacement file.
}

function Enter-RimeNamedLock([string]$Directory, [string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid lock name: $Name" }
    Ensure-RimePlainDirectory $Directory | Out-Null
    $path = Assert-RimePlainWriteTarget (Get-RimeChildPath $Directory $Name)
    try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw "RIME lock unavailable: $path ($($_.Exception.Message))" }
}

function Enter-RimeNamedLockWait([string]$Directory, [string]$Name, [int]$TimeoutMilliseconds = 30000) {
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid lock name: $Name" }
    if ($TimeoutMilliseconds -lt 1) { throw 'Lock timeout must be positive' }
    Ensure-RimePlainDirectory $Directory | Out-Null
    $path = Get-RimeChildPath $Directory $Name
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        try {
            $path = Assert-RimePlainWriteTarget $path
            return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "RIME lock timed out: $path" }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Enter-RimeLock([string]$Root) {
    try { return Enter-RimeNamedLock $Root 'switch.lock' }
    catch { throw "RIME root locked or not writable: $Root ($($_.Exception.Message))" }
}

function Assert-RimeMarker([string]$Root, [string]$Sid) {
    $marker = Read-RimeJson (Get-RimeChildPath $Root '.config-rime-root.json')
    if ($marker.format -ne 1 -or $marker.manager -ne 'config-rime') { throw 'Invalid root marker' }
    if ($marker.ownerSid -ne $Sid) { throw 'Root owner SID mismatch' }
}

function Write-RimePatches([string]$Directory, [string[]]$Schemas) {
    $lines = @('patch:', '  schema_list:')
    foreach ($schema in $Schemas) {
        if ($schema -notmatch '^[a-z0-9_]+$') { throw 'Invalid schema ID' }
        $lines += "    - schema: $schema"
    }
    $defaultContent = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    $uiContent = @'
customization:
  distribution_code_name: Weasel
  distribution_version: 0.17.4
  generator: "Weasel::UIStyleSettings"
patch:
  "style/horizontal": true
  "style/candidate_list_layout": linear
  "style/inline_preedit": false
  "style/font_face": "Cascadia Code NF, Microsoft YaHei"
  "style/label_font_face": "Cascadia Code NF, Microsoft YaHei"
  "style/comment_font_face": "Cascadia Code NF, Microsoft YaHei"
  "style/font_point": 14
'@ + "`n"
    $generated = [ordered]@{
        'default.custom.yaml' = $defaultContent
        'weasel.custom.yaml' = $uiContent
    }
    $created = New-Object Collections.Generic.List[string]
    $conflicts = New-Object Collections.Generic.List[string]
    foreach ($name in $generated.Keys) {
        $path = Get-RimeChildPath $Directory $name
        if ([IO.File]::Exists($path)) {
            $path = Assert-RimePlainExistingFile $path "Generated RIME patch $name"
            if ([IO.File]::ReadAllText($path) -ne $generated[$name]) { [void]$conflicts.Add($name) }
            continue
        }
        $path = Write-RimeNewTextFile $path $generated[$name] "Generated RIME patch $name"
        [void]$created.Add($name)
    }
    return [pscustomobject]@{ Created = $created.ToArray(); Conflicts = $conflicts.ToArray() }
}

function Get-RimePowerShell7Command { return 'pwsh.exe' }

function Test-RimePinnedHash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid expected checksum' }
    $actual = Get-RimeFileHash $Path
    if ($actual -ne $Expected.ToLowerInvariant()) { return $false }
    return $true
}

function Assert-RimePinnedHash([string]$Path, [string]$Expected) {
    if (-not (Test-RimePinnedHash $Path $Expected)) { throw "Archive checksum verification failed: $Path" }
}

function Get-RimeProfileSourcePatterns([string]$Profile, [bool]$MoqiFull) {
    switch ($Profile) {
        ice {
            return @(
                'default.yaml', 'weasel.yaml', 'symbols_v.yaml', 'symbols_caps_v.yaml',
                '*.schema.yaml', '*.dict.yaml', 'rime.lua', 'custom_phrase.txt',
                'cn_dicts/**/*', 'en_dicts/**/*', 'opencc/**/*', 'lua/**/*'
            )
        }
        mint {
            return @(
                'default.yaml', 'weasel.yaml', 'squirrel.yaml', 'symbols.yaml',
                '*.schema.yaml', '*.dict.yaml', 'rime_mint_flypy.schema.yaml', 'rime_mint.dict.yaml', 'rime.lua',
                'opencc/**/*', 'dicts/**/*', 'lua/**/*'
            )
        }
        moqi {
            $patterns = @(
                'default.yaml', 'weasel.yaml', 'symbols.yaml', 'symbols_caps_v.yaml',
                'moqi.yaml', 'moqi_speller.yaml', 'moqi_wan_flypymo.schema.yaml', 'moqi_single_xh.schema.yaml',
                'moqi_single.dict.yaml', 'reverse_moqima.schema.yaml', 'reverse_moqima.dict.yaml',
                'radical_flypy.schema.yaml', 'radical_flypy.dict.yaml', 'zrlf.schema.yaml', 'zrlf.dict.yaml',
                'cangjie5.schema.yaml', 'cangjie5.dict.yaml', 'cangjie5.base.dict.yaml', 'cangjie5.stem.dict.yaml', 'cangjie5.extended.dict.yaml',
                'stroke.schema.yaml', 'stroke.dict.yaml',
                'luna_pinyin.schema.yaml', 'luna_quanpin.schema.yaml', 'luna_pinyin.dict.yaml', 'pinyin.yaml',
                'emoji.schema.yaml', 'emoji.dict.yaml', 'easy_en.schema.yaml', 'easy_en.dict.yaml',
                'jp_sela.schema.yaml', 'jp_sela.dict.yaml', 'opencc/**/*', 'lua/**/*', 'zh-moqi.gram', 'zhs-moqi.gram',
                'custom_phrase/**/*', 'cn_dicts_common/jian.dict.yaml', 'cn_dicts_common/word.dict.yaml', 'cn_dicts_common/4jian_no_conflict.dict.yaml',
                'cn_dicts_common/changcijian.dict.yaml', 'cn_dicts_common/changcijian3.dict.yaml',
                'cn_dicts/8105.dict.yaml', 'cn_dicts/base.dict.yaml', 'cn_dicts/ext.dict.yaml', 'cn_dicts/others.dict.yaml'
            )
            if ($MoqiFull) {
                $patterns += @('moqi_wan.extended.dict.yaml', 'cn_dicts/**/*', 'cn_dicts_common/**/*', 'cn_dicts_cell/**/*')
            }
            return $patterns
        }
        default { throw "Unknown profile: $Profile" }
    }
}

function Convert-RimeGlobToRegex([string]$Pattern) {
    $normalized = $Pattern -replace '\\', '/'
    $builder = New-Object Text.StringBuilder
    for ($index = 0; $index -lt $normalized.Length; $index++) {
        $character = $normalized[$index]
        if ($character -eq '*' -and $index + 1 -lt $normalized.Length -and $normalized[$index + 1] -eq '*') {
            if ($index + 2 -lt $normalized.Length -and $normalized[$index + 2] -eq '/') {
                [void]$builder.Append('(?:.*/)?'); $index += 2; continue
            }
            [void]$builder.Append('.*'); $index++; continue
        }
        if ($character -eq '*') { [void]$builder.Append('[^/]*'); continue }
        if ($character -eq '?') { [void]$builder.Append('[^/]'); continue }
        [void]$builder.Append([Regex]::Escape([string]$character))
    }
    return '^' + $builder.ToString() + '$'
}

function Select-RimeSourceFiles([string]$Source, [string[]]$Patterns) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Source directory missing: $Source" }
    Assert-RimePlainPath $Source
    $regexes = @($Patterns | ForEach-Object { Convert-RimeGlobToRegex $_ })
    $selected = New-Object Collections.Generic.List[string]
    foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Unsafe reparse point in source tree: $($item.FullName)"
        }
        if ($item.PSIsContainer) { continue }
        $file = $item
        $relative = $file.FullName.Substring($Source.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
        if ($relative -match '(?i)(^|/)build(/|$)|userdb|\.userdb|\.bin$') { continue }
        foreach ($regex in $regexes) {
            if ($relative -match $regex) { [void]$selected.Add($relative); break }
        }
    }
    return @($selected | Sort-Object -Unique)
}

function Get-RimeDeployArguments([string]$DeployMode) {
    switch ($DeployMode) {
        Interactive { return [string[]]@() }
        Quiet { return [string[]]@('/deploy') }
        default { throw "DeployMode must be Interactive or Quiet: $DeployMode" }
    }
}

function Get-RimeBuildSnapshot([string]$ProfileDirectory) {
    $snapshot = @{}
    $build = Join-Path $ProfileDirectory 'build'
    if (-not (Test-Path -LiteralPath $build -PathType Container) -or (Get-Item -LiteralPath $build).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $snapshot
    }
    foreach ($file in Get-ChildItem -LiteralPath $build -File -Recurse -Force) {
        $relative = $file.FullName.Substring($ProfileDirectory.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
        $snapshot[$relative] = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
    }
    return $snapshot
}

function Test-RimeBuildArtifacts(
    [string]$ProfileDirectory,
    [string[]]$Schemas,
    [string[]]$Dictionaries,
    $Before,
    [DateTime]$StartedAt
) {
    $required = New-Object Collections.Generic.List[string]
    foreach ($schema in $Schemas) { [void]$required.Add("build/$schema.prism.bin") }
    foreach ($dictionary in $Dictionaries) { [void]$required.Add("build/$dictionary.table.bin") }
    foreach ($relative in @($required | Sort-Object -Unique)) {
        $path = Join-Path $ProfileDirectory ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not [IO.File]::Exists($path)) { return $false }
        $file = Get-Item -LiteralPath $path -Force
        $stamp = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
        $old = if ($Before -is [hashtable] -and $Before.ContainsKey($relative)) { $Before[$relative] } else { $null }
        if ($file.LastWriteTimeUtc -lt $StartedAt.AddSeconds(-2) -or ($null -ne $old -and $old -eq $stamp)) { return $false }
    }
    return $true
}

function Assert-RimeBuildArtifacts(
    [string]$ProfileDirectory,
    [string[]]$Schemas,
    [string[]]$Dictionaries,
    $Before,
    [DateTime]$StartedAt
) {
    if (-not (Test-RimeBuildArtifacts $ProfileDirectory $Schemas $Dictionaries $Before $StartedAt)) {
        throw 'Deployment artifacts missing, stale, or incomplete'
    }
}

function Get-RimeProfileDefinition([string]$Profile, [bool]$MoqiFull) {
    switch ($Profile) {
        ice {
            return [pscustomobject]@{
                Name = 'ice'; Schemas = @('rime_ice'); Dictionaries = @('rime_ice'); MoqiDictionary = $null
                Variant = 'standard'; Source = 'iDvel/rime-ice'
            }
        }
        mint {
            return [pscustomobject]@{
                Name = 'mint'; Schemas = @('rime_mint_flypy'); Dictionaries = @('rime_mint'); MoqiDictionary = $null
                Variant = 'standard'; Source = 'Mintimate/oh-my-rime'
            }
        }
        moqi {
            $dictionary = if ($MoqiFull) { 'moqi_wan.extended' } else { 'moqi_wan.lite' }
            $variant = if ($MoqiFull) { 'full' } else { 'lite' }
            return [pscustomobject]@{
                Name = 'moqi'; Schemas = @('moqi_wan_flypymo', 'moqi_single_xh')
                Dictionaries = @($dictionary, 'moqi_single')
                MoqiDictionary = $dictionary; Variant = $variant
                Source = 'gaboolic/rime-shuangpin-fuzhuma'
            }
        }
        default { throw "Unknown profile: $Profile" }
    }
}

function Get-RimeFileHash([string]$Path) {
    $Path = Assert-RimePlainExistingFile $Path 'RIME hash input'
    $sha = New-Object Security.Cryptography.SHA256Managed
    try {
        $Path = Assert-RimePlainExistingFile $Path 'RIME hash input'
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Expand-RimeArchiveSafe([string]$ArchivePath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ArchivePath = Assert-RimePlainExistingFile $ArchivePath 'RIME archive'
    Assert-RimePlainPath $Destination
    if (Test-Path -LiteralPath $Destination) { throw "Archive destination already exists: $Destination" }
    $destinationFull = Normalize-RimePath $Destination
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @($archive.Entries)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $entries) {
            $name = $entry.FullName -replace '\\', '/'
            try { Assert-RimeSafeRelativePath $name $true }
            catch { throw "Unsafe archive path: $($entry.FullName)" }
            if (-not $seen.Add($name.TrimEnd('/'))) { throw "Duplicate archive path: $($entry.FullName)" }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination ($name -replace '/', [IO.Path]::DirectorySeparatorChar)))
            if ($target -ne $destinationFull -and -not $target.StartsWith($destinationFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe archive path: $($entry.FullName)"
            }
        }
        New-RimePlainDirectory $Destination 'RIME archive destination' | Out-Null
        Assert-RimePlainPath $Destination
        foreach ($entry in $entries) {
            $name = $entry.FullName -replace '\\', '/'
            $target = [IO.Path]::GetFullPath((Join-Path $Destination ($name -replace '/', [IO.Path]::DirectorySeparatorChar)))
            if ($name.EndsWith('/')) {
                Ensure-RimePlainDirectory $target | Out-Null
                Assert-RimePlainPath $target
                continue
            }
            $target = Assert-RimePlainWriteTarget $target
            $input = $entry.Open()
            try {
                $output = Open-RimeNewFileForWrite $target 'RIME archive entry'
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $archive.Dispose() }
    return $Destination
}

function Copy-RimeSelectedFiles([string]$Source, [string]$Destination, [string[]]$Files) {
    $copied = New-Object Collections.Generic.List[string]
    foreach ($relative in $Files) {
        $sourcePath = Assert-RimePlainExistingFile (Get-RimeChildPath $Source $relative) "Selected RIME source $relative"
        # Selected copies build a new staging/tree destination. Callers must resolve
        # source precedence first; an appearing destination is never overwritten.
        $destinationPath = Assert-RimePlainNewWriteTarget (Get-RimeChildPath $Destination $relative) "Selected RIME destination $relative"
        $sourcePath = Assert-RimePlainExistingFile $sourcePath "Selected RIME source $relative"
        Copy-RimeFileToNewFile $sourcePath $destinationPath "Selected RIME destination $relative" | Out-Null
        [void]$copied.Add($relative)
    }
    return $copied.ToArray()
}

function Get-RimeManagedManifest([string]$ManifestPath, [string]$Destination) {
    $ManifestPath = Assert-RimePlainWriteTarget $ManifestPath
    $Destination = Assert-RimePlainExistingDirectory $Destination 'Managed RIME destination directory'
    $expectedDirectory = Normalize-RimePath $Destination
    $actualDirectory = Normalize-RimePath ([IO.Path]::GetDirectoryName($ManifestPath))
    if ($actualDirectory -ine $expectedDirectory) { throw "Managed RIME manifest is outside destination: $ManifestPath" }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return [pscustomobject]@{ Path = $ManifestPath; Existed = $false; Entries = @{} }
    }
    $manifestFile = Assert-RimePlainExistingFile $ManifestPath 'Managed RIME manifest'
    $beforeHash = Get-RimeFileHash $manifestFile
    $manifest = Read-RimeJson $manifestFile
    $afterHash = Get-RimeFileHash $manifestFile
    if ($beforeHash -cne $afterHash) { throw "Managed RIME manifest changed during read: $ManifestPath" }
    $formatProperty = $manifest.PSObject.Properties['format']
    $managerProperty = $manifest.PSObject.Properties['manager']
    $filesProperty = $manifest.PSObject.Properties['files']
    if ($null -eq $formatProperty -or $null -eq $managerProperty -or $null -eq $filesProperty -or
        $formatProperty.Value -ne 1 -or [string]$managerProperty.Value -cne 'config-rime') {
        throw "Managed RIME manifest is not owned: $ManifestPath"
    }
    $entries = @{}
    foreach ($item in @($filesProperty.Value)) {
        if ($null -eq $item -or $null -eq $item.PSObject.Properties['path'] -or $null -eq $item.PSObject.Properties['sha256']) {
            throw "Managed RIME manifest entry is invalid: $ManifestPath"
        }
        $relative = [string]$item.path
        try { Assert-RimeSafeRelativePath $relative } catch { throw "Managed RIME manifest entry is invalid: $ManifestPath" }
        $hash = [string]$item.sha256
        if ($hash -notmatch '^[0-9a-f]{64}$') { throw "Managed RIME manifest entry is invalid: $ManifestPath" }
        Get-RimeChildPath $Destination $relative | Out-Null
        if ($entries.ContainsKey($relative)) { throw "Managed RIME manifest contains duplicate path: $relative" }
        $entries[$relative] = $hash
    }
    return [pscustomobject]@{ Path = $ManifestPath; Existed = $true; Hash = $afterHash; Entries = $entries }
}

function Write-RimeManagedManifest($Manifest, $Entries) {
    if ($null -eq $Manifest -or $null -eq $Manifest.PSObject.Properties['Path'] -or $null -eq $Manifest.PSObject.Properties['Existed']) {
        throw 'Managed RIME manifest state is invalid'
    }
    $path = [string]$Manifest.Path
    $value = [ordered]@{
        format = 1
        manager = 'config-rime'
        files = $Entries
        updated = [DateTime]::UtcNow.ToString('o')
    }
    if ([bool]$Manifest.Existed) {
        if ($null -eq $Manifest.PSObject.Properties['Hash']) { throw 'Managed RIME manifest state has no hash' }
        $path = Assert-RimePlainExistingFile $path 'Managed RIME manifest'
        if ((Get-RimeFileHash $path) -cne [string]$Manifest.Hash) {
            throw "Managed RIME manifest changed during update: $path"
        }
        Write-RimeJson $path $value
    } else {
        Write-RimeNewJson $path $value 'Managed RIME manifest'
    }
}

function Copy-RimeManagedFiles([string]$Source, [string]$Destination, [string[]]$Files, [string]$ManifestPath) {
    $manifest = Get-RimeManagedManifest $ManifestPath $Destination
    $old = $manifest.Entries
    $conflicts = New-Object Collections.Generic.List[string]
    $copied = New-Object Collections.Generic.List[string]
    $removed = New-Object Collections.Generic.List[string]
    $next = New-Object Collections.Generic.List[object]
    $currentPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $Files) {
        if (-not $currentPaths.Add($relative)) { throw "Duplicate managed source: $relative" }
        $sourcePath = Assert-RimePlainExistingFile (Get-RimeChildPath $Source $relative) "Managed RIME source $relative"
        $destinationPath = Get-RimeChildPath $Destination $relative
        $sourceHash = Get-RimeFileHash $sourcePath
        $previousHash = $null
        $nextHash = $null
        $canReplace = -not [IO.File]::Exists($destinationPath)
        if (-not $canReplace) {
            $destinationPath = Assert-RimePlainExistingFile $destinationPath "Managed RIME destination $relative"
            $previousHash = $old[$relative]
            $canReplace = ($null -ne $previousHash -and (Get-RimeFileHash $destinationPath) -eq $previousHash)
        }
        if ($canReplace) {
            $sourcePath = Assert-RimePlainExistingFile $sourcePath "Managed RIME source $relative"
            if ($null -eq $previousHash) {
                $destinationPath = Assert-RimePlainNewWriteTarget $destinationPath "Managed RIME destination $relative"
                $destinationPath = Copy-RimeFileToNewFile $sourcePath $destinationPath "Managed RIME destination $relative"
                if ((Get-RimeFileHash $destinationPath) -cne $sourceHash) {
                    throw "Managed RIME source changed during copy: $sourcePath"
                }
                [void]$copied.Add($relative)
                $nextHash = $sourceHash
            } else {
                $temporary = "$destinationPath.$([guid]::NewGuid().ToString('N')).tmp"
                $temporary = Copy-RimeFileToNewFile $sourcePath $temporary "Managed RIME replacement temporary $relative"
                if ((Get-RimeFileHash $temporary) -cne $sourceHash) {
                    throw "Managed RIME source changed during copy: $sourcePath"
                }
                $destinationPath = Assert-RimePlainExistingFile $destinationPath "Managed RIME destination $relative"
                if ((Get-RimeFileHash $destinationPath) -cne $previousHash) {
                    # Preserve the unique temporary file. It cannot safely be deleted
                    # after a concurrent path replacement, and the user edit wins.
                    [void]$conflicts.Add($relative)
                    $nextHash = $previousHash
                } else {
                    # File.Replace only operates on an existing owned file. Final
                    # rechecks narrow races; handle-relative identity remains native-only.
                    $temporary = Assert-RimePlainExistingFile $temporary "Managed RIME replacement temporary $relative"
                    $destinationPath = Assert-RimePlainExistingFile $destinationPath "Managed RIME destination $relative"
                    [IO.File]::Replace($temporary, $destinationPath, [NullString]::Value)
                    $destinationPath = Assert-RimePlainExistingFile $destinationPath "Managed RIME destination $relative"
                    if ((Get-RimeFileHash $destinationPath) -cne $sourceHash) {
                        throw "Managed RIME destination changed during replacement: $destinationPath"
                    }
                    [void]$copied.Add($relative)
                    $nextHash = $sourceHash
                }
            }
        } else {
            [void]$conflicts.Add($relative)
            if ($null -ne $previousHash) { $nextHash = $previousHash }
        }
        if ($null -ne $nextHash) {
            [void]$next.Add([pscustomobject]@{ path = $relative; sha256 = $nextHash })
        }
    }
    foreach ($relative in @($old.Keys)) {
        if ($currentPaths.Contains([string]$relative)) { continue }
        $destinationPath = Get-RimeChildPath $Destination ([string]$relative)
        if (-not (Test-Path -LiteralPath $destinationPath)) { continue }
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            [void]$conflicts.Add([string]$relative)
            continue
        }
        $destinationPath = Assert-RimePlainExistingFile $destinationPath "Managed stale RIME file $relative"
        if ((Get-RimeFileHash $destinationPath) -eq [string]$old[$relative]) {
            $destinationPath = Assert-RimePlainExistingFile $destinationPath "Managed stale RIME file $relative"
            [IO.File]::Delete($destinationPath)
            [void]$removed.Add([string]$relative)
        } else {
            [void]$conflicts.Add([string]$relative)
        }
    }
    Write-RimeManagedManifest $manifest $next.ToArray()
    return [pscustomobject]@{ Copied = $copied.ToArray(); Removed = $removed.ToArray(); Conflicts = $conflicts.ToArray() }
}

function Write-RimeMoqiLiteDictionary([string]$Directory) {
    $path = Get-RimeChildPath $Directory 'moqi_wan.lite.dict.yaml'
    $content = @'
# Generated by config-rime. Source schema remains upstream-owned.
---
name: moqi_wan.lite
version: "2024.05.11-lite"
sort: by_weight
use_preset_vocabulary: false

import_tables:
  - cn_dicts/8105
  - cn_dicts/base
  - cn_dicts/ext
  - cn_dicts/others
  - cn_dicts_common/jian
  - cn_dicts_common/word
  - cn_dicts_common/changcijian
  - cn_dicts_common/changcijian3
'@
    if ([IO.File]::Exists($path)) {
        $path = Assert-RimePlainExistingFile $path 'Generated Moqi Lite dictionary'
        [string[]]$conflicts = @()
        if ([IO.File]::ReadAllText($path) -ne $content) { $conflicts = @('moqi_wan.lite.dict.yaml') }
        return [pscustomobject]@{ Path = $path; Created = [string[]]@(); Conflicts = $conflicts }
    }
    $path = Write-RimeNewTextFile $path $content 'Generated Moqi Lite dictionary'
    return [pscustomobject]@{ Path = $path; Created = @('moqi_wan.lite.dict.yaml'); Conflicts = @() }
}

function Write-RimeMoqiLiteSchemaPatch([string]$Directory) {
    $patches = @{
        'moqi_wan_flypymo.custom.yaml' = @'
# Generated by config-rime. Preserve upstream moqi algebra/schema.
patch:
  translator/dictionary: moqi_wan.lite
  reverse_lookup/dictionary: moqi_wan.lite
  add_user_dict/dictionary: moqi_wan.lite
  user_dict_set/dictionary: moqi_wan.lite
'@;
        'moqi_single_xh.custom.yaml' = @'
# Generated by config-rime. Preserve upstream moqi algebra/schema.
patch:
  reverse_lookup/dictionary: moqi_wan.lite
'@
    }
    $created = New-Object Collections.Generic.List[string]
    $conflicts = New-Object Collections.Generic.List[string]
    foreach ($name in $patches.Keys) {
        $path = Get-RimeChildPath $Directory $name
        $content = $patches[$name]
        if ([IO.File]::Exists($path)) {
            $path = Assert-RimePlainExistingFile $path "Generated Moqi Lite patch $name"
            if ([IO.File]::ReadAllText($path) -ne $content) { [void]$conflicts.Add($name) }
        } else {
            $path = Write-RimeNewTextFile $path $content "Generated Moqi Lite patch $name"
            [void]$created.Add($name)
        }
    }
    return [pscustomobject]@{
        Path = Get-RimeChildPath $Directory 'moqi_wan_flypymo.custom.yaml'
        Created = $created.ToArray()
        Conflicts = $conflicts.ToArray()
    }
}

function Remove-RimeMoqiLiteArtifacts([string]$Directory) {
    $generated = @{
        'moqi_wan.lite.dict.yaml' = @'
# Generated by config-rime. Source schema remains upstream-owned.
---
name: moqi_wan.lite
version: "2024.05.11-lite"
sort: by_weight
use_preset_vocabulary: false

import_tables:
  - cn_dicts/8105
  - cn_dicts/base
  - cn_dicts/ext
  - cn_dicts/others
  - cn_dicts_common/jian
  - cn_dicts_common/word
  - cn_dicts_common/changcijian
  - cn_dicts_common/changcijian3
'@;
        'moqi_wan_flypymo.custom.yaml' = @'
# Generated by config-rime. Preserve upstream moqi algebra/schema.
patch:
  translator/dictionary: moqi_wan.lite
  reverse_lookup/dictionary: moqi_wan.lite
  add_user_dict/dictionary: moqi_wan.lite
  user_dict_set/dictionary: moqi_wan.lite
'@;
        'moqi_single_xh.custom.yaml' = @'
# Generated by config-rime. Preserve upstream moqi algebra/schema.
patch:
  reverse_lookup/dictionary: moqi_wan.lite
'@
    }
    $removed = New-Object Collections.Generic.List[string]
    $preserved = New-Object Collections.Generic.List[string]
    foreach ($name in $generated.Keys) {
        $path = Get-RimeChildPath $Directory $name
        if (-not [IO.File]::Exists($path)) { continue }
        $path = Assert-RimePlainExistingFile $path "Generated Moqi Lite artifact $name"
        if ([IO.File]::ReadAllText($path) -eq $generated[$name]) {
            # Confirm twice before deleting so a concurrent replacement of the path
            # cannot make us delete content we never verified as generated.
            $path = Assert-RimePlainExistingFile $path "Generated Moqi Lite artifact $name"
            if ([IO.File]::ReadAllText($path) -eq $generated[$name]) {
                [IO.File]::Delete($path); [void]$removed.Add($name)
            } else { [void]$preserved.Add($name) }
        } else { [void]$preserved.Add($name) }
    }
    return [pscustomobject]@{ Removed = $removed.ToArray(); Preserved = $preserved.ToArray() }
}

function Assert-RimeExportPath([string]$Relative) {
    $normalized = $Relative -replace '\\', '/'
    try { Assert-RimeSafeRelativePath $normalized }
    catch { throw "Not an allowed text export: $Relative" }
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        $normalized -match '(^/|^[A-Za-z]:|(^|/)\.\.?(/|$)|[\x00-\x1f])' -or
        $normalized -match '(?i)(userdb|\.bin($|\.)|(^|/)build(/|$))' -or
        $normalized -notmatch '^(custom_phrase/[^/]+\.txt|[^/]+\.custom\.yaml)$') {
        throw "Not an allowed text export: $Relative"
    }
}

function Export-RimeText([string]$Source, [string]$Review, [string[]]$Files) {
    Assert-RimePlainPath $Source
    Assert-RimePlainPath $Review
    if (Test-Path -LiteralPath $Review) { throw 'Review destination already exists' }
    if (-not $Files.Count) { throw 'Explicit user-managed text file list required' }
    $normalizedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # Validate complete list before creating any destination.
    foreach ($relative in $Files) {
        Assert-RimeExportPath $relative
        $normalized = $relative -replace '\\', '/'
        if (-not $normalizedFiles.Add($normalized)) { throw "Duplicate export file: $relative" }
        $path = Assert-RimePlainExistingFile (Get-RimeChildPath $Source $normalized) "RIME export source $relative"
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes -contains 0) { throw "Binary text export refused: $relative" }
        [void](New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    New-RimePlainDirectory $Review 'RIME review export destination' | Out-Null
    foreach ($relative in $normalizedFiles) {
        $source = Assert-RimePlainExistingFile (Get-RimeChildPath $Source $relative) "RIME export source $relative"
        $dest = Assert-RimePlainNewWriteTarget (Get-RimeChildPath $Review $relative) "RIME export destination $relative"
        Copy-RimeFileToNewFile $source $dest "RIME export destination $relative" | Out-Null
    }
    $metadata = [ordered]@{ source = $Source; files = @($normalizedFiles); status = 'review_required'; created = [DateTime]::UtcNow.ToString('o') }
    Write-RimeJson (Join-Path $Review 'export.json') $metadata
    return [pscustomobject]$metadata
}
