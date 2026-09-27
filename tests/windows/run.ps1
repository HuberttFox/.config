#requires -Version 7.0
# Run with PowerShell 7 (pwsh). Never touches live RIME state.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:passed = 0
$script:failed = 0
$script:skipped = 0
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected error: $Pattern"
}
function Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith('SKIP:')) { $script:skipped++; Write-Host "SKIP $Name : $message" }
        else { $script:failed++; Write-Host "FAIL $Name : $_" }
    }
}
$core = Join-Path $repo 'windows/lib/Rime.Core.ps1'
$windows = Join-Path $repo 'windows/lib/Rime.Windows.ps1'
$switch = Join-Path $repo 'windows/lib/Rime.Switch.ps1'
$install = Join-Path $repo 'windows/lib/Rime.Install.ps1'
if (Test-Path $core) { . $core }
if (Test-Path $windows) { . $windows }
if (Test-Path $switch) { . $switch }
if (Test-Path $install) { . $install }
$temp = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.rime-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    Case 'root selection honors explicit then config then managed then marked fallback' {
        Assert ((Resolve-RimeRoot 'explicit' 'config' 'managed' 'marked' 'local') -eq 'explicit') 'explicit lost'
        Assert ((Resolve-RimeRoot '' 'config' 'managed' 'marked' 'local') -eq 'config') 'config lost'
        Assert ((Resolve-RimeRoot '' '' 'managed' 'marked' 'local') -eq 'managed') 'managed lost'
        Assert ((Resolve-RimeRoot '' '' '' 'marked' 'local') -eq 'marked') 'marker ignored'
        Assert ((Resolve-RimeRoot '' '' '' '' 'local') -eq 'local') 'default lost'
    }
    Case 'path normalization preserves filesystem roots' {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($temp))
        Assert (-not [string]::IsNullOrWhiteSpace($root)) 'test filesystem root unavailable'
        Assert ((Normalize-RimePath $root) -eq $root) 'core normalization converted filesystem root into a relative path'
        Assert ((Normalize-RimeWindowsPath $root) -eq $root) 'Windows normalization converted filesystem root into a relative path'
    }
    Case 'profile selection cycles and rejects unknown profiles' {
        Assert ((Get-RimeNextProfile ice) -eq 'mint') 'ice order'
        Assert ((Get-RimeNextProfile mint) -eq 'moqi') 'mint order'
        Assert ((Get-RimeNextProfile moqi) -eq 'ice') 'moqi order'
        Throws { Get-RimeNextProfile unknown } 'Unknown profile'
    }
    Case 'child paths reject traversal rooted paths and database export' {
        Throws { Get-RimeChildPath $temp '../escape' } 'Unsafe'
        Throws { Get-RimeChildPath $temp '/escape' } 'Unsafe'
        Throws { Get-RimeChildPath $temp 'a:stream' } 'Unsafe'
        Throws { Get-RimeChildPath $temp 'folder/file. ' } 'Unsafe'
        Throws { Get-RimeChildPath $temp 'folder/CON.yaml' } 'Unsafe'
        Throws { Get-RimeChildPath $temp 'folder/name?.yaml' } 'Unsafe'
        Throws { Get-RimeChildPath $temp 'folder/' } 'Unsafe'
        Assert ((Get-RimeChildPath $temp 'custom_phrase/test.txt') -eq (Join-Path $temp 'custom_phrase/test.txt')) 'child path'
        Throws { Assert-RimeExportPath 'custom_phrase/test.userdb.txt' } 'export'
        Throws { Assert-RimeExportPath 'build/test.yaml' } 'export'
        Throws { Assert-RimeExportPath 'CON.custom.yaml' } 'export'
        Throws { Assert-RimeExportPath 'name?.custom.yaml' } 'export'
        Throws { Assert-RimeExportPath 'custom_phrase/name. txt' } 'export'
        Assert-RimeExportPath 'custom_phrase/personal.txt'
        Assert-RimeExportPath 'personal.custom.yaml'
    }
    Case 'plain path validation rejects UNC device stream wildcard and Windows alias paths' {
        foreach ($unsafe in @('\\server\share\rime', '\\?\C:\Rime', '\\.\PIPE\rime', '\??\C:\Rime', 'C:\Rime\profile:stream', 'C:\Rime\CON', 'C:\Rime\alias. ', 'C:\Rime\child\..\other', (Join-Path $temp 'wild*card'), (Join-Path $temp 'wild?card'), (Join-Path $temp 'wild[card]'))) {
            Throws { Assert-RimePlainPath $unsafe } 'UNC|device|stream|wildcard|alias|unsafe'
        }
    }
    Case 'directory creation validates reparse parent before mutation' {
        $real = Join-Path $temp 'lock-real'; $link = Join-Path $temp 'lock-link'; $unsafe = Join-Path $link 'new-root'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Throws { Enter-RimeNamedLock $unsafe 'switch.lock' } 'reparse'
        Assert (-not (Test-Path -LiteralPath (Join-Path $real 'new-root'))) 'unsafe lock directory was created'
    }
    Case 'plain path validation rejects reparse ancestors' {
        $real = Join-Path $temp 'real-parent'; $link = Join-Path $temp 'linked-parent'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null
            Throws { Assert-RimePlainPath (Join-Path $link 'child') } 'reparse'
        } catch {
            if ($_.Exception.Message -match 'reparse') { throw }
            throw 'SKIP: symbolic-link fixture unavailable' }
    }
    Case 'JSON replacement is readable and lock excludes a second writer' {
        $path = Join-Path $temp 'state.json'
        Write-RimeJson $path @{ value = 1 }
        Write-RimeJson $path @{ value = 2 }
        Assert ((Read-RimeJson $path).value -eq 2) 'atomic update lost'
        $lock = Enter-RimeLock $temp
        try { Throws { Enter-RimeLock $temp } 'locked' } finally { $lock.Dispose() }
        $lock = Enter-RimeLock $temp; $lock.Dispose()
    }
    Case 'JSON temporary collision is preserved rather than deleted as owned state' {
        $jsonPath = Join-Path $temp 'collision-state.json'
        $assertFunction = (Get-Command Assert-RimePlainWriteTarget -CommandType Function).ScriptBlock
        $script:jsonCollisionPath = $null
        try {
            function Assert-RimePlainWriteTarget([string]$Path) {
                $result = & $assertFunction $Path
                $prefix = [IO.Path]::GetFullPath($jsonPath) + '.'
                if ($null -eq $script:jsonCollisionPath -and [IO.Path]::GetFullPath($Path).StartsWith($prefix, [StringComparison]::Ordinal) -and $Path.EndsWith('.tmp')) {
                    [IO.File]::WriteAllText($result, 'attacker')
                    $script:jsonCollisionPath = $result
                }
                return $result
            }
            Throws { Write-RimeJson $jsonPath @{ state = 'managed' } } 'already exists|appeared'
        } finally {
            Set-Item -Path Function:Assert-RimePlainWriteTarget -Value $assertFunction
        }
        Assert ($null -ne $script:jsonCollisionPath) 'test did not create JSON temporary collision'
        Assert ([IO.File]::ReadAllText($script:jsonCollisionPath) -eq 'attacker') 'JSON cleanup deleted an unowned temporary collision'
    }
    Case 'new managed directory refuses a directory appearing after validation' {
        if ($null -eq (Get-Command New-RimePlainDirectory -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'New-RimePlainDirectory missing'
        }
        $path = Join-Path $temp 'appeared-directory'
        $assertFunction = (Get-Command Assert-RimePlainPath -CommandType Function).ScriptBlock
        $script:directoryCreateInjected = $false
        try {
            function Assert-RimePlainPath([string]$Path) {
                & $assertFunction $Path
                if (-not $script:directoryCreateInjected -and [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($path)) {
                    [IO.Directory]::CreateDirectory($path) | Out-Null
                    $script:directoryCreateInjected = $true
                }
            }
            Throws { New-RimePlainDirectory $path 'test managed directory' } 'already exists|appeared'
        } finally {
            Set-Item -Path Function:Assert-RimePlainPath -Value $assertFunction
        }
        Assert $script:directoryCreateInjected 'test did not create directory collision'
        Assert (Test-Path -LiteralPath $path -PathType Container) 'directory collision was unexpectedly removed'
    }
    Case 'new managed text write refuses a file appearing after final validation' {
        if ($null -eq (Get-Command Write-RimeNewTextFile -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Write-RimeNewTextFile missing'
        }
        $path = Join-Path $temp 'appeared-generated.yaml'
        $assertFunction = (Get-Command Assert-RimePlainWriteTarget -CommandType Function).ScriptBlock
        $script:generatedWriteInjected = $false
        try {
            function Assert-RimePlainWriteTarget([string]$Path) {
                $result = & $assertFunction $Path
                if (-not $script:generatedWriteInjected -and [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($path)) {
                    [IO.File]::WriteAllText($result, 'attacker')
                    $script:generatedWriteInjected = $true
                }
                return $result
            }
            Throws { Write-RimeNewTextFile $path 'managed' 'test generated file' } 'already exists|appeared'
        } finally {
            Set-Item -Path Function:Assert-RimePlainWriteTarget -Value $assertFunction
        }
        Assert $script:generatedWriteInjected 'test did not create generated-file collision'
        Assert ([IO.File]::ReadAllText($path) -eq 'attacker') 'generated write overwrote file appearing after validation'
    }
    Case 'archive extraction refuses a file appearing after final validation' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $temp 'archive-appeared.zip'; $destination = Join-Path $temp 'archive-appeared'; $target = Join-Path $destination 'safe.txt'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('safe.txt'); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('managed'); $writer.Dispose()
        } finally { $archive.Dispose() }
        $assertFunction = (Get-Command Assert-RimePlainWriteTarget -CommandType Function).ScriptBlock
        $script:archiveWriteInjected = $false
        try {
            function Assert-RimePlainWriteTarget([string]$Path) {
                $result = & $assertFunction $Path
                if (-not $script:archiveWriteInjected -and [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($target)) {
                    [IO.File]::WriteAllText($result, 'attacker')
                    $script:archiveWriteInjected = $true
                }
                return $result
            }
            Throws { Expand-RimeArchiveSafe $zip $destination } 'appeared|exists|already'
        } finally {
            Set-Item -Path Function:Assert-RimePlainWriteTarget -Value $assertFunction
        }
        Assert $script:archiveWriteInjected 'test did not create archive-file collision'
        Assert ([IO.File]::ReadAllText($target) -eq 'attacker') 'archive extraction overwrote file appearing after validation'
    }
    Case 'new root marker refuses a colliding file without overwriting it' {
        $root = Join-Path $temp 'root-marker-collision'; $markerPath = Join-Path $root '.config-rime-root.json'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllText($markerPath, 'attacker marker')
        Throws { New-RimeRootMarker $root 'S-test' } 'already exists|appeared'
        Assert ([IO.File]::ReadAllText($markerPath) -eq 'attacker marker') 'new root marker overwrote colliding file'
    }
    Case 'marker refuses different user and invalid ownership' {
        $path = Join-Path $temp '.config-rime-root.json'
        Write-RimeJson $path @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        Assert-RimeMarker $temp 'S-test'
        Throws { Assert-RimeMarker $temp 'S-other' } 'owner'
        Write-RimeJson $path @{ format = 5; ownerSid = 'S-test'; manager = 'config-rime' }
        Throws { Assert-RimeMarker $temp 'S-test' } 'marker'
    }
    Case 'schema customization preserves native upstream files' {
        $dir = Join-Path $temp 'profile'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'moqi.yaml'), 'native algebra')
        Write-RimePatches $dir @('moqi_wan_flypymo', 'moqi_single_xh')
        $patch = [IO.File]::ReadAllText((Join-Path $dir 'default.custom.yaml'))
        Assert ($patch -match 'schema: moqi_wan_flypymo' -and $patch -match 'schema: moqi_single_xh') 'schemas missing'
        Assert ([IO.File]::ReadAllText((Join-Path $dir 'moqi.yaml')) -eq 'native algebra') 'upstream changed'
        Assert ([IO.File]::ReadAllText((Join-Path $dir 'weasel.custom.yaml')) -match 'inline_preedit.+false') 'UI patch missing'
        $defaultBefore = [IO.File]::ReadAllText((Join-Path $dir 'default.custom.yaml'))
        $weaselBefore = [IO.File]::ReadAllText((Join-Path $dir 'weasel.custom.yaml'))
        Write-RimePatches $dir @('ice')
        Assert ([IO.File]::ReadAllText((Join-Path $dir 'default.custom.yaml')) -eq $defaultBefore) 'default custom overwritten'
        Assert ([IO.File]::ReadAllText((Join-Path $dir 'weasel.custom.yaml')) -eq $weaselBefore) 'weasel custom overwritten'
        $partial = Join-Path $temp 'partial-profile'; [IO.Directory]::CreateDirectory($partial) | Out-Null
        [IO.File]::WriteAllText((Join-Path $partial 'default.custom.yaml'), 'user-owned')
        $patchResult = Write-RimePatches $partial @('mint')
        Assert ([IO.File]::ReadAllText((Join-Path $partial 'default.custom.yaml')) -eq 'user-owned') 'partial custom overwritten'
        Assert (Test-Path (Join-Path $partial 'weasel.custom.yaml')) 'missing generated UI patch'
        Assert ($patchResult.Conflicts -contains 'default.custom.yaml') 'preserved default customization conflict not reported'
        Assert ([IO.File]::ReadAllText((Join-Path $partial 'weasel.custom.yaml')) -match 'generator: "Weasel::UIStyleSettings"') 'official UI generator missing'
    }
    Case 'text export creates review copy without changing target or copying databases' {
        $from = Join-Path $temp 'export-source'; $review = Join-Path $temp 'review'
        [IO.Directory]::CreateDirectory((Join-Path $from 'custom_phrase')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $from 'custom_phrase/personal.txt'), 'personal phrase')
        [IO.File]::WriteAllText((Join-Path $from 'custom_phrase/private.userdb.txt'), 'private db')
        Export-RimeText $from $review @('custom_phrase/personal.txt')
        Assert ([IO.File]::ReadAllText((Join-Path $review 'custom_phrase/personal.txt')) -eq 'personal phrase') 'copy missing'
        Assert (-not (Test-Path (Join-Path $review 'custom_phrase/private.userdb.txt'))) 'database copied'
        Throws { Export-RimeText $from $review @('custom_phrase/personal.txt') } 'exists'
    }
    Case 'profile definitions make Moqi Lite default and Full explicit' {
        $lite = Get-RimeProfileDefinition 'moqi' $false
        $full = Get-RimeProfileDefinition 'moqi' $true
        Assert ($lite.MoqiDictionary -eq 'moqi_wan.lite') 'Lite dictionary wrong'
        Assert ($full.MoqiDictionary -eq 'moqi_wan.extended') 'Full dictionary wrong'
        Assert ($lite.Schemas[0] -eq 'moqi_wan_flypymo' -and $lite.Schemas[1] -eq 'moqi_single_xh') 'Moqi schemas wrong'
        Assert ((Get-RimeProfileDefinition 'ice' $false).Schemas[0] -eq 'rime_ice') 'Ice schema wrong'
        Assert ((Get-RimeProfileDefinition 'mint' $false).Dictionaries[0] -eq 'rime_mint') 'Mint dictionary artifact wrong'
        Assert ($lite.Dictionaries -contains 'moqi_wan.lite' -and $lite.Dictionaries -contains 'moqi_single') 'Moqi Lite dictionary artifacts wrong'
        Assert ($full.Dictionaries -contains 'moqi_wan.extended' -and $full.Dictionaries -contains 'moqi_single') 'Moqi Full dictionary artifacts wrong'
        Throws { Get-RimeProfileDefinition 'other' $false } 'Unknown profile'
    }
    Case 'archive extraction rejects traversal before writing any file' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $temp 'fixture.zip'; $extract = Join-Path $temp 'extract'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('../escape.txt'); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('bad'); $writer.Dispose()
        } finally { $archive.Dispose() }
        Throws { Expand-RimeArchiveSafe $zip $extract } 'Unsafe archive path'
        Assert (-not (Test-Path (Join-Path $temp 'escape.txt'))) 'archive escaped'
    }
    Case 'archive extraction validates destination before writing' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $real = Join-Path $temp 'archive-real'; $link = Join-Path $temp 'archive-link'; $destination = Join-Path $link 'extract'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        $zip = Join-Path $temp 'fixture-destination.zip'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('safe.txt'); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('safe'); $writer.Dispose()
        } finally { $archive.Dispose() }
        Throws { Expand-RimeArchiveSafe $zip $destination } 'reparse'
        Assert (-not (Test-Path -LiteralPath (Join-Path $real 'extract'))) 'unsafe archive destination was created'
    }
    Case 'archive extraction rejects Windows alternate data streams before writing' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $temp 'fixture-ads.zip'; $extract = Join-Path $temp 'extract-ads'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('folder/file.txt:stream'); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('bad'); $writer.Dispose()
        } finally { $archive.Dispose() }
        Throws { Expand-RimeArchiveSafe $zip $extract } 'Unsafe archive path'
        Assert (-not (Test-Path $extract)) 'unsafe archive created destination'
    }
    Case 'archive extraction rejects NTFS aliases before writing' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($unsafe in @('folder/file. ', 'folder/CON.yaml', 'folder/name?.yaml')) {
            $zip = Join-Path $temp ('fixture-alias-' + [guid]::NewGuid().ToString('N') + '.zip')
            $extract = Join-Path $temp ('extract-alias-' + [guid]::NewGuid().ToString('N'))
            $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $archive.CreateEntry($unsafe); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('bad'); $writer.Dispose()
            } finally { $archive.Dispose() }
            Throws { Expand-RimeArchiveSafe $zip $extract } 'Unsafe archive path'
            Assert (-not (Test-Path $extract)) "unsafe archive created destination for <$unsafe>"
        }
    }
    Case 'selected source copy refuses a destination file appearing after validation' {
        $source = Join-Path $temp 'selected-copy-source'; $destination = Join-Path $temp 'selected-copy-destination'; $relative = 'nested/current.yaml'; $sourcePath = Join-Path $source $relative; $destinationPath = Join-Path $destination $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourcePath)) | Out-Null
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        [IO.File]::WriteAllText($sourcePath, 'managed')
        $assertFunction = (Get-Command Assert-RimePlainWriteTarget -CommandType Function).ScriptBlock
        $script:selectedCopyDestinationChecks = 0
        try {
            function Assert-RimePlainWriteTarget([string]$Path) {
                $result = & $assertFunction $Path
                if ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($destinationPath)) {
                    $script:selectedCopyDestinationChecks++
                    if ($script:selectedCopyDestinationChecks -eq 2) { [IO.File]::WriteAllText($result, 'attacker') }
                }
                return $result
            }
            Throws { Copy-RimeSelectedFiles $source $destination @($relative) } 'already exists|appeared'
        } finally {
            Set-Item -Path Function:Assert-RimePlainWriteTarget -Value $assertFunction
        }
        Assert ($script:selectedCopyDestinationChecks -ge 2) 'test did not inject selected-copy collision'
        Assert ([IO.File]::ReadAllText($destinationPath) -eq 'attacker') 'selected source copy overwrote appearing file'
    }
    Case 'managed file update refuses a destination file appearing after validation' {
        $source = Join-Path $temp 'managed-copy-source'; $destination = Join-Path $temp 'managed-copy-destination'; $relative = 'nested/current.yaml'; $sourcePath = Join-Path $source $relative; $destinationPath = Join-Path $destination $relative; $manifest = Join-Path $destination 'managed-files.json'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourcePath)) | Out-Null
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        [IO.File]::WriteAllText($sourcePath, 'managed')
        $assertFunction = (Get-Command Assert-RimePlainWriteTarget -CommandType Function).ScriptBlock
        $script:managedCopyDestinationChecks = 0
        try {
            function Assert-RimePlainWriteTarget([string]$Path) {
                $result = & $assertFunction $Path
                if ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($destinationPath)) {
                    $script:managedCopyDestinationChecks++
                    if ($script:managedCopyDestinationChecks -eq 2) { [IO.File]::WriteAllText($result, 'attacker') }
                }
                return $result
            }
            Throws { Copy-RimeManagedFiles $source $destination @($relative) $manifest } 'already exists|appeared'
        } finally {
            Set-Item -Path Function:Assert-RimePlainWriteTarget -Value $assertFunction
        }
        Assert ($script:managedCopyDestinationChecks -ge 2) 'test did not inject managed-copy collision'
        Assert ([IO.File]::ReadAllText($destinationPath) -eq 'attacker') 'managed file update overwrote appearing file'
    }
    Case 'managed manifest collision after initial discovery is preserved' {
        $source = Join-Path $temp 'manifest-race-source'; $destinationRoot = Join-Path $temp 'manifest-race-destination'; $manifest = Join-Path $destinationRoot 'managed-files.json'; $sourcePath = Join-Path $source 'current.yaml'
        [IO.Directory]::CreateDirectory($source) | Out-Null; [IO.Directory]::CreateDirectory($destinationRoot) | Out-Null
        [IO.File]::WriteAllText($sourcePath, 'managed')
        $copyFunction = (Get-Command Copy-RimeFileToNewFile -CommandType Function).ScriptBlock
        $script:manifestCollisionInjected = $false
        # Capture the case-scope paths: the product caller also has a $manifest,
        # and dynamic lookup would otherwise resolve to that object.
        $script:manifestCollisionPath = $manifest
        $script:manifestCollisionRoot = $destinationRoot
        try {
            function Copy-RimeFileToNewFile([string]$Source, [string]$Destination, [string]$Purpose = 'RIME file copy') {
                $result = & $copyFunction $Source $Destination $Purpose
                if (-not $script:manifestCollisionInjected -and [IO.Path]::GetFullPath($Destination) -eq [IO.Path]::GetFullPath((Join-Path $script:manifestCollisionRoot 'current.yaml'))) {
                    [IO.File]::WriteAllText($script:manifestCollisionPath, 'attacker manifest')
                    $script:manifestCollisionInjected = $true
                }
                return $result
            }
            Throws { Copy-RimeManagedFiles $source $destinationRoot @('current.yaml') $manifest } 'already exists|appeared'
        } finally {
            Set-Item -Path Function:Copy-RimeFileToNewFile -Value $copyFunction
        }
        Assert $script:manifestCollisionInjected 'test did not create manifest collision'
        Assert ([IO.File]::ReadAllText($manifest) -eq 'attacker manifest') 'managed manifest collision was overwritten'
    }
    Case 'managed update rejects an unowned manifest before any mutation' {
        $source = Join-Path $temp 'unowned-manifest-source'; $destination = Join-Path $temp 'unowned-manifest-destination'; $manifest = Join-Path $destination 'managed-files.json'; $stale = Join-Path $destination 'stale.yaml'
        [IO.Directory]::CreateDirectory($source) | Out-Null; [IO.Directory]::CreateDirectory($destination) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'current.yaml'), 'managed')
        [IO.File]::WriteAllText($stale, 'user-owned')
        Write-RimeJson $manifest @{ format = 1; files = @([pscustomobject]@{ path = 'stale.yaml'; sha256 = Get-RimeFileHash $stale }) }
        Throws { Copy-RimeManagedFiles $source $destination @('current.yaml') $manifest } 'manifest.*owned|owned.*manifest'
        Assert ([IO.File]::ReadAllText($stale) -eq 'user-owned') 'unowned manifest authorized stale-file deletion'
        Assert (-not (Test-Path -LiteralPath (Join-Path $destination 'current.yaml'))) 'unowned manifest allowed a new managed write'
    }
    Case 'managed file update removes stale owned files but preserves edits' {
        $source = Join-Path $temp 'stale-source'; $dest = Join-Path $temp 'stale-profile'; $managed = Join-Path $dest 'managed-files.json'
        [IO.Directory]::CreateDirectory($source) | Out-Null; [IO.Directory]::CreateDirectory($dest) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'current.yaml'), 'current')
        [IO.File]::WriteAllText((Join-Path $source 'obsolete.yaml'), 'obsolete')
        Copy-RimeManagedFiles $source $dest @('current.yaml', 'obsolete.yaml') $managed | Out-Null
        $result = Copy-RimeManagedFiles $source $dest @('current.yaml') $managed
        Assert ($result.Removed -contains 'obsolete.yaml') 'stale owned file was not removed'
        Assert (-not (Test-Path (Join-Path $dest 'obsolete.yaml'))) 'stale owned file remains'
        [IO.File]::WriteAllText((Join-Path $source 'obsolete.yaml'), 'obsolete-v2')
        Copy-RimeManagedFiles $source $dest @('current.yaml', 'obsolete.yaml') $managed | Out-Null
        [IO.File]::WriteAllText((Join-Path $dest 'obsolete.yaml'), 'user edit')
        $result = Copy-RimeManagedFiles $source $dest @('current.yaml') $managed
        Assert ($result.Conflicts -contains 'obsolete.yaml') 'stale user edit was not reported'
        Assert ([IO.File]::ReadAllText((Join-Path $dest 'obsolete.yaml')) -eq 'user edit') 'stale user edit was removed'
    }
    Case 'managed file update preserves user edits and generated databases' {
        $source = Join-Path $temp 'source'; $dest = Join-Path $temp 'profile'; $managed = Join-Path $dest 'managed-files.json'
        [IO.Directory]::CreateDirectory($source) | Out-Null; [IO.Directory]::CreateDirectory($dest) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'schema.yaml'), 'upstream-v1')
        [IO.File]::WriteAllText((Join-Path $dest 'schema.yaml'), 'user-edit')
        [IO.File]::WriteAllText((Join-Path $dest 'schema.userdb'), 'learned')
        $result = Copy-RimeManagedFiles $source $dest @('schema.yaml') $managed
        Assert ($result.Conflicts -contains 'schema.yaml') 'user edit overwritten'
        Assert ([IO.File]::ReadAllText((Join-Path $dest 'schema.yaml')) -eq 'user-edit') 'user edit lost'
        Assert ([IO.File]::ReadAllText((Join-Path $dest 'schema.userdb')) -eq 'learned') 'database lost'
        [IO.File]::WriteAllText((Join-Path $source 'schema.yaml'), 'upstream-v2')
        $result = Copy-RimeManagedFiles $source $dest @('schema.yaml') $managed
        Assert ($result.Conflicts -contains 'schema.yaml') 'untracked edit replaced'
    }
    Case 'Moqi Lite dictionary is deterministic and excludes full-only tables' {
        $dir = Join-Path $temp 'moqi-lite'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        Write-RimeMoqiLiteDictionary $dir
        $text = [IO.File]::ReadAllText((Join-Path $dir 'moqi_wan.lite.dict.yaml'))
        Assert ($text -match 'name: moqi_wan\.lite') 'Lite name missing'
        Assert ($text -match 'cn_dicts/8105' -and $text -match 'cn_dicts/base') 'Lite base missing'
        Assert ($text -notmatch 'cn_dicts/41448|cn_dicts/GB18030|cn_dicts_cell/') 'Full tables leaked into Lite'
        Assert ($text -notmatch 'custom_phrase/\\*') 'custom phrase wildcard is not a dictionary import'
        $before = $text
        $unchanged = Write-RimeMoqiLiteDictionary $dir
        Assert ($unchanged.Conflicts.Count -eq 0) 'unchanged Lite dictionary conflicted'
        Assert ([IO.File]::ReadAllText((Join-Path $dir 'moqi_wan.lite.dict.yaml')) -eq $before) 'Lite overwritten'
        [IO.File]::WriteAllText((Join-Path $dir 'moqi_wan.lite.dict.yaml'), 'user-owned Lite dictionary')
        $modified = Write-RimeMoqiLiteDictionary $dir
        Assert ($modified.Conflicts -contains 'moqi_wan.lite.dict.yaml') 'modified Lite dictionary conflict not reported'
        Assert ([IO.File]::ReadAllText((Join-Path $dir 'moqi_wan.lite.dict.yaml')) -eq 'user-owned Lite dictionary') 'modified Lite dictionary overwritten'
    }
    Case 'Moqi Lite patches every full dictionary reference used by both schemas' {
        $dir = Join-Path $temp 'moqi-patches'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        Write-RimeMoqiLiteSchemaPatch $dir | Out-Null
        $main = [IO.File]::ReadAllText((Join-Path $dir 'moqi_wan_flypymo.custom.yaml'))
        $single = [IO.File]::ReadAllText((Join-Path $dir 'moqi_single_xh.custom.yaml'))
        foreach ($path in @('translator/dictionary', 'reverse_lookup/dictionary', 'add_user_dict/dictionary', 'user_dict_set/dictionary')) {
            Assert ($main -match [Regex]::Escape($path)) "main patch missing $path"
        }
        Assert ($single -match 'reverse_lookup/dictionary') 'single schema reverse lookup not patched'
        Assert ($main -notmatch 'moqi_wan\.extended' -and $single -notmatch 'moqi_wan\.extended') 'Full dictionary leaked into Lite patches'
        [IO.File]::WriteAllText((Join-Path $dir 'moqi_single_xh.custom.yaml'), 'user-owned patch')
        $result = Write-RimeMoqiLiteSchemaPatch $dir
        Assert ($result.Conflicts -contains 'moqi_single_xh.custom.yaml') 'Moqi custom patch conflict not reported'
        Assert ([IO.File]::ReadAllText((Join-Path $dir 'moqi_single_xh.custom.yaml')) -eq 'user-owned patch') 'Moqi custom patch overwritten'
    }
    Case 'lock manifest pins release and source checksums' {
        $lockPath = Join-Path $repo 'windows/manifests/rime.lock.json'
        Assert (Test-Path $lockPath) 'lock manifest missing'
        $lock = Read-RimeJson $lockPath
        Assert ($lock.weasel.version -eq '0.17.4') 'Weasel not pinned'
        Assert ($lock.weasel.sha256 -match '^[0-9a-f]{64}$') 'Weasel hash missing'
        foreach ($name in @('ice', 'mint', 'moqi', 'stroke', 'cangjie', 'luna')) {
            Assert ($lock.sources.$name.commit -match '^[0-9a-f]{40}$') "$name commit missing"
            Assert ($lock.sources.$name.sha256 -match '^[0-9a-f]{64}$') "$name hash missing"
        }
        Assert ($lock.sources.luna.repository -eq 'rime/rime-luna-pinyin') 'Luna source is not official'
        Assert ($lock.sources.moqi.variants.lite) 'Moqi Lite missing'
        Assert ($lock.sources.moqi.variants.full) 'Moqi Full missing'
    }
    Case 'profile directory names stay isolated under profiles' {
        Assert ((Get-RimeProfileDirectory $temp ice) -eq (Join-Path $temp 'profiles/Rime_Ice')) 'Ice path wrong'
        Assert ((Get-RimeProfileDirectory $temp mint) -eq (Join-Path $temp 'profiles/Rime_Mint')) 'Mint path wrong'
        Assert ((Get-RimeProfileDirectory $temp moqi) -eq (Join-Path $temp 'profiles/Rime_Moqi')) 'Moqi path wrong'
        Throws { Get-RimeProfileDirectory $temp legacy } 'Unknown profile'
    }
    Case 'source patterns exclude generated state and separate Moqi Lite Full' {
        $ice = @(Get-RimeProfileSourcePatterns 'ice' $false)
        $mint = @(Get-RimeProfileSourcePatterns 'mint' $false)
        $lite = @(Get-RimeProfileSourcePatterns 'moqi' $false)
        $full = @(Get-RimeProfileSourcePatterns 'moqi' $true)
        Assert (-not ($ice -match '(^|/)build|userdb')) 'Ice includes generated state'
        Assert ($mint -contains 'rime_mint_flypy.schema.yaml') 'Mint schema missing'
        Assert ($lite -contains 'moqi_wan_flypymo.schema.yaml') 'Moqi Lite schema missing'
        Assert (-not ($lite -match '^cn_dicts_cell/')) 'Moqi Lite includes cell dictionaries'
        Assert ($lite -contains 'custom_phrase/**/*') 'Moqi Lite phrase defaults missing'
        Assert (($full -match '^cn_dicts_cell/').Count -gt 0) 'Moqi Full omits cell dictionaries'
        Assert ($full -contains 'cn_dicts_common/**/*') 'Moqi Full common dictionaries incomplete'
        Assert ($full -contains 'custom_phrase/**/*') 'Moqi Full phrase files incomplete'
        Assert ($lite -contains 'cangjie5.schema.yaml' -and $lite -contains 'stroke.schema.yaml') 'Moqi dependencies incomplete'
        Assert ($lite -contains 'luna_pinyin.schema.yaml' -and $lite -contains 'luna_quanpin.schema.yaml' -and $lite -contains 'luna_pinyin.dict.yaml') 'Luna dependencies incomplete'
    }
    Case 'source file selector rejects reparse descendants' {
        $source = Join-Path $temp 'source-reparse'; $real = Join-Path $temp 'source-reparse-real'; $link = Join-Path $source 'linked'
        [IO.Directory]::CreateDirectory($source) | Out-Null; [IO.Directory]::CreateDirectory($real) | Out-Null
        [IO.File]::WriteAllText((Join-Path $real 'linked.yaml'), 'linked')
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Throws { Select-RimeSourceFiles $source @('**/*') } 'reparse'
    }
    Case 'source file selector matches safe archive-relative patterns' {
        $source = Join-Path $temp 'source-tree'; [IO.Directory]::CreateDirectory((Join-Path $source 'lua/sub')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'default.yaml'), 'default')
        [IO.File]::WriteAllText((Join-Path $source 'lua/sub/test.lua'), 'lua')
        [IO.Directory]::CreateDirectory((Join-Path $source 'build')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'build/stale.bin'), 'stale')
        $files = @(Select-RimeSourceFiles $source @('default.yaml', 'lua/**/*'))
        Assert ($files -contains 'default.yaml' -and $files -contains 'lua/sub/test.lua') 'pattern match failed'
        Assert (-not ($files -contains 'build/stale.bin')) 'build file selected'
    }
    Case 'pinned archive hash check rejects tampered bytes' {
        $file = Join-Path $temp 'download.bin'; [IO.File]::WriteAllText($file, 'bytes')
        $hash = Get-RimeFileHash $file
        Assert (Test-RimePinnedHash $file $hash) 'valid hash rejected'
        Throws { Assert-RimePinnedHash $file ('0' * 64) } 'checksum'
    }
    Case 'elevated installer revalidates its pinned cache file immediately before UAC' {
        $installerText = [IO.File]::ReadAllText((Join-Path $repo 'windows/install.ps1'))
        Assert ($installerText -match 'function Invoke-RimeElevatedInstaller\(\[string\]\$InstallerPath, \[string\]\$Arguments, \[string\]\$ExpectedSha256\)') 'installer launcher has no expected checksum parameter'
        Assert ($installerText -match 'Assert-RimePinnedHash \$InstallerPath \$ExpectedSha256') 'installer launcher skips final pinned checksum validation'
        Assert ($installerText -match 'Invoke-RimeElevatedInstaller \$installer \(\[string\]\$lock\.weasel\.installArgs\) \(\[string\]\$lock\.weasel\.sha256\)') 'runtime installer call does not supply pinned checksum'
        $launcher = [regex]::Match($installerText, 'function Invoke-RimeElevatedInstaller[\s\S]*?\n\}').Value
        Assert ($launcher -notmatch '-Verb RunAs[^\r\n]*-Wait\b') 'installer launcher waits on the installer process tree (WeaselServer keeps it alive)'
        Assert ($launcher -match 'WaitForExit\(\)') 'installer launcher does not wait for the installer process'
    }
    Case 'Weasel InstallDir lookup covers the 32-bit registry view' {
        $body = (Get-Command Get-RimeWeaselInstallDirectory -CommandType Function).ScriptBlock.ToString()
        Assert ($body -match 'WOW6432Node') 'Weasel InstallDir lookup ignores the 32-bit registry view'
        Assert ($body -match 'WeaselRoot') 'Weasel InstallDir lookup ignores the versioned WeaselRoot value'
    }
    Case 'control scripts define libraries in script scope' {
        $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -eq $pwshCommand) { throw 'SKIP: pwsh unavailable' }
        $dir = Join-Path $temp 'control-import'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        $controlRoot = Join-Path $temp 'control-import-root'; [IO.Directory]::CreateDirectory($controlRoot) | Out-Null
        if ($IsWindows) {
            Set-Content -LiteralPath (Join-Path $controlRoot '.config-rime-root.json') -Value (@{ format = 1; manager = 'config-rime'; ownerSid = (Get-RimeCurrentSid) } | ConvertTo-Json)
        }
        Copy-Item (Join-Path $repo 'windows/scripts/rime-switch.ps1') $dir
        Copy-Item (Join-Path $repo 'windows/lib/*.ps1') $dir
        $controlOut = & $pwshCommand.Source -NoProfile -File (Join-Path $dir 'rime-switch.ps1') -RimeRoot $controlRoot -Profile ice -NoDeploy 2>&1
        $controlText = ($controlOut | Out-String)
        Assert ($controlText -notmatch 'not recognized|CommandNotFoundException|Import-RimeLibraries') 'control script lost its libraries to function scope'
    }
    Case 'Moqi Lite rewrites staged full-dictionary references' {
        $dir = Join-Path $temp 'moqi-lite-rewrite'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'moqi_wan_flypymo.schema.yaml'), "translator:`n  dictionary: moqi_wan.extended`n")
        [IO.File]::WriteAllText((Join-Path $dir 'moqi.yaml'), "big_char_and_user_dict:`n  user_dict_set:`n    dictionary: moqi_wan.extended`n")
        [IO.File]::WriteAllText((Join-Path $dir 'moqi_single_xh.schema.yaml'), "schema_id: moqi_single_xh`n")
        $replaced = @(Update-RimeMoqiLiteDictionaryReferences $dir)
        Assert ($replaced -contains 'moqi_wan_flypymo.schema.yaml' -and $replaced -contains 'moqi.yaml') 'Lite rewrite missed staged sources'
        $remaining = (@(Get-ChildItem $dir -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) | Out-String)
        Assert ($remaining -notmatch 'moqi_wan\.extended') 'staged source still references moqi_wan.extended'
    }
    Case 'Moqi prism artifacts use dictionary-derived names' {
        $definition = Get-RimeProfileDefinition 'moqi' $false
        Assert ($null -ne $definition.PSObject.Properties['PrismArtifacts']) 'moqi definition has no prism artifact list'
        Assert ((@($definition.PrismArtifacts)) -contains 'moqi_single') 'moqi prism list lost the dictionary-derived prism'
        Assert (-not ((@($definition.PrismArtifacts)) -contains 'moqi_single_xh')) 'moqi prism list still expects the schema-derived name'
    }
    Case 'build artifact check accepts unchanged incremental artifacts' {
        $dir = Join-Path $temp 'artifact-check'; [IO.Directory]::CreateDirectory((Join-Path $dir 'build')) | Out-Null
        $file = Join-Path $dir 'build/schema.prism.bin'; [IO.File]::WriteAllText($file, 'compiled')
        [IO.File]::SetLastWriteTimeUtc($file, (Get-Date).ToUniversalTime().AddSeconds(-30))
        $stamp = "$((Get-Item -LiteralPath $file).Length):$((Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks)"
        $started = [DateTime]::UtcNow
        Assert (Test-RimeBuildArtifacts $dir @('schema') @() @{ 'build/schema.prism.bin' = $stamp } $started) 'unchanged previously deployed artifact was rejected'
        Assert (-not (Test-RimeBuildArtifacts $dir @('schema') @() @{} $started)) 'old artifact without prior deployment was accepted'
        [IO.File]::WriteAllText($file, 'recompiled')
        Assert (Test-RimeBuildArtifacts $dir @('schema') @() @{ 'build/schema.prism.bin' = $stamp } $started) 'fresh artifact was rejected'
    }
    Case 'completed switch state clears stale failure evidence' {
        $dir = Join-Path $temp 'state-clear'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        Write-RimeSwitchState $dir @{ status = 'failed'; error = 'old failure'; requestedProfile = 'ice' }
        Write-RimeSwitchState $dir @{ status = 'completed'; currentProfile = 'ice' }
        $state = Get-Content -Raw -LiteralPath (Join-Path $dir 'state.json') | ConvertFrom-Json
        Assert ($state.status -eq 'completed') 'state status not completed'
        Assert ($null -eq $state.PSObject.Properties['error']) 'stale error persisted after completion'
        Assert ($state.currentProfile -eq 'ice') 'completed state lost profile'
    }
    Case 'Weasel launch refuses a reparse install directory before Start-Process' {
        $real = Join-Path $temp 'weasel-launch-real'; $link = Join-Path $temp 'weasel-launch-link'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        [IO.File]::WriteAllText((Join-Path $real 'WeaselServer.exe'), 'fixture')
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: Weasel launch symbolic-link fixture unavailable' }
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $startProcessFunction = Get-Item -Path Function:Start-Process -ErrorAction SilentlyContinue
        $script:weaselLaunchCalls = 0
        try {
            function Assert-RimeWindowsHost { }
            function Start-Process { param($FilePath, $WindowStyle, $ErrorAction) $script:weaselLaunchCalls++ }
            Throws { Start-RimeWeasel $link } 'reparse'
            Assert ($script:weaselLaunchCalls -eq 0) 'reparse install directory reached process launch'
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
            if ($null -eq $startProcessFunction) { Remove-Item -Path Function:Start-Process -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Start-Process -Value $startProcessFunction.ScriptBlock }
        }
    }
    Case 'junction selector paths require fixed RimeConfig leaf and plain parent' {
        if ($null -eq (Get-Command Assert-RimeSelectorLinkPath -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Assert-RimeSelectorLinkPath missing'
        }
        $root = Join-Path $temp 'junction-selector-path'; [IO.Directory]::CreateDirectory($root) | Out-Null
        $selector = Join-Path $root 'RimeConfig'
        Assert ((Assert-RimeSelectorLinkPath $selector) -eq $selector) 'valid selector path changed'
        Throws { Assert-RimeSelectorLinkPath (Join-Path $root 'not-selector') } 'selector'
        $real = Join-Path $temp 'junction-selector-real'; $link = Join-Path $temp 'junction-selector-link'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null
            Throws { Assert-RimeSelectorLinkPath (Join-Path $link 'RimeConfig') } 'reparse'
        } catch {
            if ($_.Exception.Message -match 'reparse') { throw }
            throw 'SKIP: junction-selector symbolic-link fixture unavailable' }
        $newBody = (Get-Command New-RimeJunction -CommandType Function).ScriptBlock.ToString()
        $removeBody = (Get-Command Remove-RimeJunction -CommandType Function).ScriptBlock.ToString()
        $setBody = (Get-Command Set-RimeJunctionTarget -CommandType Function).ScriptBlock.ToString()
        Assert ($newBody -match 'Assert-RimeSelectorLinkPath' -and $removeBody -match 'Assert-RimeSelectorLinkPath' -and $setBody -match 'Assert-RimeSelectorLinkPath') 'Junction mutation bypasses selector path validation'
    }
    Case 'junction switch rejects unsafe transaction IDs before selector mutation' {
        $root = Join-Path $temp 'junction-unsafe-transaction'; $selector = Join-Path $root 'RimeConfig'; $target = Join-Path $root 'profiles/Rime_Ice'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        try {
            function Assert-RimeWindowsHost { }
            Throws { Set-RimeJunctionTarget $selector $target '../outside' } 'Invalid Junction transaction ID'
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
        }
        Assert (-not (Test-Path -LiteralPath $selector)) 'unsafe transaction ID mutated selector'
    }
    Case 'junction switch rejects a foreign existing target before backup mutation' {
        $root = Join-Path $temp 'junction-foreign-existing'; $selector = Join-Path $root 'RimeConfig'; $target = Join-Path $root 'profiles/Rime_Ice'; $foreign = Join-Path $temp 'foreign-RimeConfig'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        [IO.Directory]::CreateDirectory($selector) | Out-Null
        [IO.Directory]::CreateDirectory($foreign) | Out-Null
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $junctionFunction = (Get-Command Assert-RimeJunction -CommandType Function).ScriptBlock
        $targetFunction = (Get-Command Assert-RimeSelectorTarget -CommandType Function).ScriptBlock
        $moveFunction = Get-Item -Path Function:Move-Item -ErrorAction SilentlyContinue
        $script:junctionForeignBackupMoves = 0
        try {
            function Assert-RimeWindowsHost { }
            function Assert-RimeJunction { param($Link, $ExpectedTarget) if ($Link -eq $selector) { return $foreign }; return $ExpectedTarget }
            function Assert-RimeSelectorTarget { param($Link, $Candidate, $AllowLegacyTarget) if ($Candidate -eq $foreign) { throw 'Junction target is outside managed profiles' } }
            function Move-Item { param($LiteralPath, $Destination, $ErrorAction) $script:junctionForeignBackupMoves++ }
            Throws { Set-RimeJunctionTarget $selector $target 'foreign-existing' } 'outside managed profiles'
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
            Set-Item -Path Function:Assert-RimeJunction -Value $junctionFunction
            Set-Item -Path Function:Assert-RimeSelectorTarget -Value $targetFunction
            if ($null -eq $moveFunction) { Remove-Item -Path Function:Move-Item -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Move-Item -Value $moveFunction.ScriptBlock }
        }
        Assert ($script:junctionForeignBackupMoves -eq 0) 'foreign selector target was moved into transaction backup'
    }
    Case 'junction recovery never force-overwrites a selector appearing after removal' {
        $recoveryBody = (Get-Command Recover-RimeJunctionTransaction -CommandType Function).ScriptBlock.ToString()
        Assert ($recoveryBody -notmatch 'Move-Item\s+-LiteralPath\s+\$backup\s+-Destination\s+\$selector\s+-Force') 'junction recovery force-overwrites a selector that appears during recovery'
        Assert ($recoveryBody -match 'Junction selector appeared during recovery') 'junction recovery does not reject a selector appearing before restore move'
    }
    Case 'verified Weasel process rejects a reparse runtime before process lookup' {
        $real = Join-Path $temp 'verified-server-real'; $link = Join-Path $temp 'verified-server-link'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        [IO.File]::WriteAllText((Join-Path $real 'WeaselServer.exe'), 'fixture')
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: verified-server symbolic-link fixture unavailable' }
        $processFunction = Get-Item -Path Function:Get-Process -ErrorAction SilentlyContinue
        $sidFunction = (Get-Command Convert-RimeAccountToSid -CommandType Function).ScriptBlock
        $script:verifiedProcessLookups = 0
        try {
            function Get-Process { param($Id, [switch]$IncludeUserName, $ErrorAction) $script:verifiedProcessLookups++; return [pscustomobject]@{ Id = $Id; Path = (Join-Path $link 'WeaselServer.exe'); UserName = 'fixture'; SessionId = 1; StartTime = [DateTime]::UtcNow } }
            function Convert-RimeAccountToSid { param($Account) return 'S-test' }
            $record = [pscustomobject]@{ Id = 901; Path = (Join-Path $link 'WeaselServer.exe'); Sid = 'S-test'; SessionId = 1; StartTimeUtc = [DateTime]::UtcNow }
            $verified = Get-RimeVerifiedServerProcess $record $link 'S-test'
            Assert ($null -eq $verified) 'reparse runtime produced a verified process'
            Assert ($script:verifiedProcessLookups -eq 0) 'reparse runtime reached process lookup'
        } finally {
            if ($null -eq $processFunction) { Remove-Item -Path Function:Get-Process -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Get-Process -Value $processFunction.ScriptBlock }
            Set-Item -Path Function:Convert-RimeAccountToSid -Value $sidFunction
        }
    }
    Case 'junction adapter refuses ordinary directory and validates target' {
        $link = Join-Path $temp 'RimeConfig'; $target = Join-Path $temp 'profiles/Rime_Ice'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        Assert-RimeManagedTarget $link $target
        $legacy = Join-Path $temp 'Rime_Ice'; [IO.Directory]::CreateDirectory($legacy) | Out-Null
        Assert-RimeLegacyTarget $link $legacy
        Throws { Assert-RimeManagedTarget $link $legacy } 'outside managed profiles'
        Throws { Assert-RimeLegacyTarget $link (Join-Path $temp 'foreign') } 'outside known legacy profiles'
        [IO.Directory]::CreateDirectory($link) | Out-Null
        Throws { Assert-RimeJunction $link $target } 'Junction'
        Remove-Item -LiteralPath $link -Force -Recurse
        if ($IsWindows) {
            New-RimeJunction $link $target
            Assert-RimeJunction $link $target
            Throws { New-RimeJunction $link $target } 'already'
            Remove-RimeJunction $link $target
            Assert (-not (Test-Path $link)) 'junction not removed'
        }
    }
    Case 'root layout validates reparse parent before mutation' {
        $real = Join-Path $temp 'layout-real'; $link = Join-Path $temp 'layout-link'; $unsafeRoot = Join-Path $link 'new-root'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Throws { Ensure-RimeRootLayout $unsafeRoot 'S-test' } 'reparse'
        Assert (-not (Test-Path -LiteralPath (Join-Path $real 'new-root'))) 'unsafe root directory was created'
    }
    Case 'root marker records current owner and never adopts unknown legacy layout' {
        $root = Join-Path $temp 'root-marker'; [IO.Directory]::CreateDirectory($root) | Out-Null
        $marker = New-RimeRootMarker $root 'S-test'
        Assert ($marker.ownerSid -eq 'S-test' -and $marker.manager -eq 'config-rime') 'marker fields wrong'
        Assert-RimeMarker $root 'S-test'
        $legacy = Join-Path $root 'Rime_Ice'; [IO.Directory]::CreateDirectory($legacy) | Out-Null
        $report = @(Find-RimeLegacyLayout $root)
        Assert ($report.Count -eq 1 -and $report[0] -eq 'Rime_Ice') 'legacy detection wrong'
    }
    Case 'configured root rejects a reparse ancestor before use' {
        $real = Join-Path $temp 'configured-root-real'; $link = Join-Path $temp 'configured-root-link'; $config = Join-Path $temp 'configured-root.json'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Write-RimeJson $config @{ root = (Join-Path $link 'child') }
        Throws { Read-RimeConfiguredRoot $config } 'reparse'
    }
    Case 'public control config path resolves explicit managed root' {
        $config = Join-Path $temp 'custom-config/rime.json'; $root = Join-Path $temp 'custom-root'
        Ensure-RimeRootLayout $root 'S-test' | Out-Null
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($config)) | Out-Null
        Write-RimeJson $config @{ format = 1; root = $root; manager = 'config-rime' }
        Assert ((Read-RimeConfiguredRoot $config) -eq $root) 'custom config root lost'
        Throws { Read-RimeConfiguredRoot (Join-Path $temp 'missing.json') } 'missing'
    }
    Case 'status adapter has no runtime or mutation operations' {
        $adapter = New-RimeStatusAdapter
        Assert ($adapter.PSObject.Properties.Name -contains 'GetActive') 'status adapter lacks selector reader'
        Assert (-not ($adapter.PSObject.Properties.Name -contains 'Stop')) 'status adapter can stop runtime'
        Assert (-not ($adapter.PSObject.Properties.Name -contains 'Switch')) 'status adapter can mutate selector'
    }
    Case 'status reports uninitialized root without selector' {
        $root = Join-Path $temp 'status-empty'; Ensure-RimeRootLayout $root 'S-test' | Out-Null
        $result = Get-RimeStatus $root 'S-test' (New-RimeStatusAdapter)
        Assert ($result.State.status -eq 'uninitialized') 'empty status state wrong'
        Assert ($null -eq $result.Target) 'empty status target should be null'
    }
    Case 'Raycast wrappers do not forward arbitrary command arguments' {
        foreach ($path in Get-ChildItem (Join-Path $repo 'windows/raycast') -Filter '*.bat') {
            $text = [IO.File]::ReadAllText($path.FullName)
            Assert ($text -notmatch '%\*') "wrapper forwards arbitrary arguments: $($path.Name)"
            Assert ($text -match 'pwsh\.exe -NoProfile -File') "wrapper missing PowerShell 7 call: $($path.Name)"
        }
    }
    Case 'public no-deploy path avoids runtime discovery' {
        $switchText = [IO.File]::ReadAllText((Join-Path $repo 'windows/scripts/rime-switch.ps1'))
        $noDeployIndex = $switchText.IndexOf('if ($NoDeploy)')
        $runtimeIndex = $switchText.IndexOf('$installDirectory = Get-RimeWeaselInstallDirectory')
        Assert ($noDeployIndex -ge 0 -and $runtimeIndex -gt $noDeployIndex) 'NoDeploy still requires Weasel runtime discovery'
    }
    Case 'public scripts support explicit config path and status avoids runtime discovery' {
        $switchText = [IO.File]::ReadAllText((Join-Path $repo 'windows/scripts/rime-switch.ps1'))
        $userdataText = [IO.File]::ReadAllText((Join-Path $repo 'windows/scripts/rime-userdata.ps1'))
        Assert ($switchText -match '\[string\]\$ConfigPath') 'switch ConfigPath parameter missing'
        Assert ($userdataText -match '\[string\]\$ConfigPath') 'userdata ConfigPath parameter missing'
        Assert ($userdataText -match '\[string\]\$ConfigPath' -and $userdataText -match 'GetFullPath\(\$ConfigPath\)') 'userdata does not use explicit config path'
        $statusIndex = $switchText.IndexOf('if ($Status)')
        $runtimeIndex = $switchText.IndexOf('$installDirectory = Get-RimeWeaselInstallDirectory')
        Assert ($statusIndex -ge 0 -and $runtimeIndex -gt $statusIndex) 'status still resolves runtime before reading state'
    }
    Case 'Windows adapter allows only explicit legacy selector during adoption' {
        $root = Join-Path $temp 'legacy-adapter'
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'Rime_Ice')) | Out-Null
        $selector = Join-Path $root 'RimeConfig'
        $legacy = Join-Path $root 'Rime_Ice'
        $normal = New-RimeWindowsAdapter $root $temp $false
        Throws { & $normal.ValidateActive $selector $legacy } 'outside managed profiles'
        $migration = New-RimeWindowsAdapter $root $temp $false $true
        & $migration.ValidateActive $selector $legacy
        Throws { & $migration.ValidateActive $selector (Join-Path $temp 'foreign') } 'outside known legacy profiles'
    }
    Case 'legacy selector target maps to one known profile' {
        $root = Join-Path $temp 'legacy-map'
        Assert ((Get-RimeProfileFromLegacyTarget $root (Join-Path $root 'Rime_Ice')) -eq 'ice') 'legacy Ice mapping failed'
        Assert ((Get-RimeProfileFromLegacyTarget $root (Join-Path $root 'Rime_Mint')) -eq 'mint') 'legacy Mint mapping failed'
        Assert ((Get-RimeProfileFromLegacyTarget $root (Join-Path $root 'Rime_Moqi')) -eq 'moqi') 'legacy Moqi mapping failed'
        Throws { Get-RimeProfileFromLegacyTarget $root (Join-Path $temp 'foreign') } 'outside known legacy profiles'
    }
    Case 'elevated ACL command encodes hostile path and owner SID as data' {
        $root = 'C:\Program Data\Rime % ! " 中文'
        $sid = 'S-1-5-21-123-456-789-1001'
        $encoded = New-RimeAclElevatedCommand $root $sid
        $scriptText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        Assert ($scriptText -notmatch [Regex]::Escape($root)) 'root was interpolated into elevated script'
        Assert ($scriptText -match 'FromBase64String') 'elevated payload is not encoded'
        Assert ($scriptText -match 'icacls\.exe') 'ACL command missing'
        Assert ($scriptText -match 'ReparsePoint') 'elevated ACL payload does not reject reparse paths itself'
        Assert ($scriptText -match 'Get-ChildItem\s+-LiteralPath') 'elevated ACL payload does not inspect recursive ACL descendants'
        Assert ($scriptText -match 'payloadRemainder') 'elevated ACL payload does not independently reject alternate data streams'
        Assert ($scriptText -match 'payloadSegments') 'elevated ACL payload does not independently validate Windows path segments'
        Assert ($scriptText -match [Regex]::Escape("segment -in @('.', '..')")) 'elevated ACL payload does not reject dot traversal aliases'
        Assert ($scriptText -match '(?i)com\[1-9\].*lpt\[1-9\]') 'elevated ACL payload does not reject reserved device aliases'
        Assert ($scriptText -match '\[\. \]\$') 'elevated ACL payload does not reject trailing dot or space aliases'
        Assert ($scriptText -match 'SpecialFolder\]::System') 'elevated ACL payload does not derive icacls from Windows system directory'
        Assert ($scriptText -notmatch '&\s+icacls\.exe') 'elevated ACL payload resolves icacls through PATH'
        $treeChecks = [Regex]::Matches($scriptText, 'Assert-RimePayloadPlainDirectoryTree\s+\$payloadRoot').Count
        Assert ($treeChecks -ge 2) 'elevated ACL payload does not recheck descendants immediately before recursive ACL mutation'
        Throws { New-RimeAclElevatedCommand $root 'not-a-sid' } 'SID'
        foreach ($unsafeRoot in @('/', 'C:\', '\\server\share\Rime', 'C:\Rime:stream', 'C:relative\Rime', 'C:\Rime\wild*card', 'C:\Rime\..\outside', 'C:\CON\Rime', 'C:\Rime\alias. ')) {
            Throws { New-RimeAclElevatedCommand $unsafeRoot $sid } 'ACL root path|Unsafe|wildcard|drive-relative|stream'
        }
    }
    Case 'ACL setup refuses a root marker owned by another SID' {
        $root = Join-Path $temp 'acl-owner-gate'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-other'; manager = 'config-rime' }
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $ownerFunction = (Get-Command Assert-RimeOwnerContext -CommandType Function).ScriptBlock
        $aclRootFunction = (Get-Command Assert-RimeAclRootPath -CommandType Function).ScriptBlock
        $grantFunction = (Get-Command Grant-RimeModifyAcl -CommandType Function).ScriptBlock
        $elevatedFunction = (Get-Command Invoke-RimeElevatedRootAcl -CommandType Function).ScriptBlock
        $script:aclGrantCalls = 0; $script:aclElevatedCalls = 0
        try {
            function Assert-RimeWindowsHost { }
            function Assert-RimeOwnerContext { param($OwnerSid) }
            function Assert-RimeAclRootPath { param($Root) return $Root }
            function Grant-RimeModifyAcl { param($Root, $OwnerSid) $script:aclGrantCalls++ }
            function Invoke-RimeElevatedRootAcl { param($Root, $OwnerSid) $script:aclElevatedCalls++ }
            Throws { Ensure-RimeModifyAccess $root 'S-test' } 'owner'
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
            Set-Item -Path Function:Assert-RimeOwnerContext -Value $ownerFunction
            Set-Item -Path Function:Assert-RimeAclRootPath -Value $aclRootFunction
            Set-Item -Path Function:Grant-RimeModifyAcl -Value $grantFunction
            Set-Item -Path Function:Invoke-RimeElevatedRootAcl -Value $elevatedFunction
        }
        Assert ($script:aclGrantCalls -eq 0) 'ACL grant ran before the owner-SID gate'
        Assert ($script:aclElevatedCalls -eq 0) 'elevated ACL fallback ran before the owner-SID gate'
    }
    Case 'root write probe creates no persistent state and rejects reparse roots' {
        $root = Join-Path $temp 'write-probe'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Assert (Test-RimeRootWriteAccess $root) 'writable root rejected'
        Assert (@(Get-ChildItem -LiteralPath $root -Force).Count -eq 0) 'write probe left state'
        $real = Join-Path $temp 'write-probe-real'; $link = Join-Path $temp 'write-probe-link'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null
            Assert (-not (Test-RimeRootWriteAccess $link)) 'write probe accepted reparse root'
            Assert (@(Get-ChildItem -LiteralPath $real -Force).Count -eq 0) 'write probe mutated reparse target'
        } catch {
            if ($_.Exception.Message -match 'write probe accepted|write probe mutated') { throw }
            throw 'SKIP: write-probe symbolic-link fixture unavailable' }
    }
    Case 'root write probe preserves a file colliding before exclusive creation' {
        $root = Join-Path $temp 'write-probe-collision'; [IO.Directory]::CreateDirectory($root) | Out-Null
        $assertFunction = (Get-Command Assert-RimePlainWriteTarget -CommandType Function).ScriptBlock
        $script:probeCollisionPath = $null
        try {
            function Assert-RimePlainWriteTarget([string]$Path) {
                $result = & $assertFunction $Path
                if ($null -eq $script:probeCollisionPath -and $Path -match '\.config-rime-write-[0-9a-f]+\.tmp$') {
                    [IO.File]::WriteAllText($result, 'attacker')
                    $script:probeCollisionPath = $result
                }
                return $result
            }
            Assert (-not (Test-RimeRootWriteAccess $root)) 'write probe accepted colliding path'
        } finally {
            Set-Item -Path Function:Assert-RimePlainWriteTarget -Value $assertFunction
        }
        Assert ($null -ne $script:probeCollisionPath) 'test did not create write-probe collision'
        Assert ([IO.File]::ReadAllText($script:probeCollisionPath) -eq 'attacker') 'write probe deleted colliding file'
    }
    Case 'all Windows RIME scripts require PowerShell 7' {
        foreach ($path in Get-ChildItem (Join-Path $repo 'windows') -Recurse -Filter '*.ps1') {
            $first = (Get-Content -LiteralPath $path.FullName -TotalCount 1)
            Assert ($first -eq '#requires -Version 7.0') "PowerShell 7 requirement missing: $($path.FullName)"
        }
    }
    Case 'Windows RIME PowerShell sources parse without errors' {
        $sources = Get-ChildItem (Join-Path $repo 'windows'), (Join-Path $repo 'tests/windows') -Recurse -Filter '*.ps1'
        $parseFailures = foreach ($source in $sources) {
            $tokens = $null; $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
            if ($parseErrors.Count) { "$($source.FullName): $(($parseErrors | ForEach-Object { $_.Message }) -join '; ')" }
        }
        Assert (-not $parseFailures) "PowerShell parse errors: $($parseFailures -join ' | ')"
    }
    Case 'PowerShell 7 is default and deployment mode arguments are explicit' {
        Assert ((Get-RimePowerShell7Command) -eq 'pwsh.exe') 'PowerShell 7 default changed'
        Assert ((@(Get-RimeDeployArguments 'Interactive')).Count -eq 0) 'Interactive unexpectedly quiet'
        $quiet = @(Get-RimeDeployArguments 'Quiet')
        Assert ($quiet.Count -eq 1 -and $quiet[0] -eq '/deploy') 'Quiet deploy argument wrong'
        $interactiveStart = Get-RimeDeployerStartOptions 'Interactive'
        $quietStart = Get-RimeDeployerStartOptions 'Quiet'
        Assert (-not $interactiveStart.ContainsKey('WindowStyle')) 'Interactive deploy GUI is hidden'
        Assert (-not $interactiveStart.ContainsKey('ArgumentList')) 'Interactive deploy received arguments'
        Assert ($quietStart.WindowStyle -eq 'Hidden' -and $quietStart.ArgumentList[0] -eq '/deploy') 'Quiet deploy start options wrong'
        Throws { Get-RimeDeployArguments 'Bogus' } 'DeployMode'
    }
    Case 'Weasel runtime version matching accepts only pinned release' {
        Assert (Test-RimeVersionMatch '0.17.4.0' '0.17.4') 'four-part pinned version rejected'
        Assert (Test-RimeVersionMatch '0.17.4' '0.17.4') 'three-part pinned version rejected'
        Assert (Test-RimeVersionMatch '0.17.4+release' '0.17.4') 'release metadata rejected'
        Assert (-not (Test-RimeVersionMatch '0.17.3.0' '0.17.4')) 'older version accepted'
        Assert (-not (Test-RimeVersionMatch '0.17.40.0' '0.17.4')) 'prefix-only version accepted'
        Assert (-not (Test-RimeVersionMatch '' '0.17.4')) 'empty version accepted'
    }
    Case 'artifact verification requires fresh expected binaries' {
        $profile = Join-Path $temp 'artifact-profile'; [IO.Directory]::CreateDirectory((Join-Path $profile 'build')) | Out-Null
        $definition = Get-RimeProfileDefinition 'mint' $false
        $before = Get-RimeBuildSnapshot $profile
        [IO.File]::WriteAllText((Join-Path $profile 'build/rime_mint_flypy.prism.bin'), 'fresh')
        [IO.File]::WriteAllText((Join-Path $profile 'build/rime_mint.table.bin'), 'fresh')
        $started = [DateTime]::UtcNow.AddSeconds(-2)
        Assert (Test-RimeBuildArtifacts $profile $definition.Schemas $definition.Dictionaries $before $started) 'fresh schema and dictionary artifacts rejected'
        Assert (-not (Test-Path (Join-Path $profile 'build/rime_mint_flypy.table.bin'))) 'test created invalid schema-named table artifact'
        Remove-Item -LiteralPath (Join-Path $profile 'build/rime_mint.table.bin')
        Throws { Assert-RimeBuildArtifacts $profile $definition.Schemas $definition.Dictionaries $before $started } 'artifacts'
    }
    Case 'switch recovers pending selector transaction before reading active target' {
        $root = Join-Path $temp 'switch-recovery-hook'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $script:recoveryEvents = New-Object Collections.Generic.List[string]
        $adapter = [pscustomobject]@{
            Recover = { param($managedRoot) [void]$script:recoveryEvents.Add('recover') }
            GetActive = { param($link) [void]$script:recoveryEvents.Add('active'); return (Join-Path $root 'profiles/Rime_Ice') }
            Switch = { param($link, $target, $transaction) }
            Stop = { param($install) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) }
            Verify = { param($target, $profile, $before, $started) return $true }
        }
        Invoke-RimeProfileSwitch $root mint 'S-test' $adapter | Out-Null
        Assert (($script:recoveryEvents -join ',') -eq 'recover,active') 'pending selector recovery did not run before active read'
    }
    Case 'switch attempts to restart previous runtime when stop fails' {
        $root = Join-Path $temp 'switch-stop-failure'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $script:stopFailureEvents = New-Object Collections.Generic.List[string]
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return (Join-Path $root 'profiles/Rime_Ice') }
            Stop = { param($install) [void]$script:stopFailureEvents.Add('stop'); throw 'stop failed after partial shutdown' }
            Restart = { param($target) [void]$script:stopFailureEvents.Add('restart') }
            Switch = { param($link, $target, $transaction) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) }
            Verify = { param($target, $profile, $before, $started) return $true }
        }
        Throws { Invoke-RimeProfileSwitch $root mint 'S-test' $adapter } 'stop failed'
        Assert (($script:stopFailureEvents -join ',') -eq 'stop,restart') 'partial stop did not trigger previous runtime restart'
    }
    Case 'switch refuses implicit Moqi Full to Lite downgrade' {
        $root = Join-Path $temp 'switch-full-downgrade'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        $target = Join-Path $root 'profiles/Rime_Moqi'; [IO.Directory]::CreateDirectory($target) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        Write-RimeProfileState $target 'moqi' 'full'
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return (Join-Path $root 'profiles/Rime_Ice') }
            Stop = { param($install) throw 'must not stop before variant validation' }
            Switch = { param($link, $targetPath, $transaction) }
            Deploy = { param($targetPath, $mode, $timeout, $profile, $before, $started) }
            Verify = { param($targetPath, $profile, $before, $started) return $true }
        }
        Throws { Invoke-RimeProfileSwitch $root moqi 'S-test' $adapter } 'downgrade'
    }
    Case 'switch commits selector backup only after completed state write' {
        $root = Join-Path $temp 'switch-commit'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $script:commitTarget = $null; $script:commitSawCompleted = $false
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return (Join-Path $root 'profiles/Rime_Ice') }
            Stop = { param($unused) }
            Switch = { param($link, $target, $transaction) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) }
            Verify = { param($target, $profile, $before, $started) return $true }
            Commit = {
                param($link, $target, $transaction)
                $script:commitTarget = $target
                $state = Read-RimeJson (Join-Path $root 'state.json')
                $script:commitSawCompleted = $state.status -eq 'completed' -and $state.target -eq $target -and $state.transaction -eq $transaction
            }
        }
        $result = Invoke-RimeProfileSwitch $root mint 'S-test' $adapter
        Assert ($result.Status -eq 'completed') 'switch did not complete before commit'
        Assert ($script:commitTarget -like '*Rime_Mint') 'commit did not receive active target'
        Assert $script:commitSawCompleted 'selector backup commit ran before completed state journal'
    }
    Case 'legacy selector commit honors explicit legacy allowance' {
        $root = Join-Path $temp 'legacy-commit'; [IO.Directory]::CreateDirectory($root) | Out-Null
        $link = Join-Path $root 'RimeConfig'; $target = Join-Path $root 'Rime_Ice'; $transaction = 'legacy-commit'
        $backup = Join-Path $root ('.RimeConfig.' + $transaction + '.previous')
        [IO.File]::WriteAllText($backup, 'junction-fixture')
        $script:legacyCommitAllow = $null
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $junctionFunction = (Get-Command Assert-RimeJunction -CommandType Function).ScriptBlock
        $targetFunction = (Get-Command Assert-RimeSelectorTarget -CommandType Function).ScriptBlock
        try {
            function Assert-RimeWindowsHost { }
            function Assert-RimeJunction { param($selector, $expected) return $expected }
            function Assert-RimeSelectorTarget { param($selector, $candidate, $allowLegacy) $script:legacyCommitAllow = $allowLegacy }
            Complete-RimeJunctionTransaction $link $target $transaction $true
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
            Set-Item -Path Function:Assert-RimeJunction -Value $junctionFunction
            Set-Item -Path Function:Assert-RimeSelectorTarget -Value $targetFunction
        }
        Assert ($script:legacyCommitAllow -eq $true) 'legacy allowance was discarded during selector commit'
        Assert (-not (Test-Path -LiteralPath $backup)) 'committed selector backup was not removed'
    }
    Case 'switch success updates selector state through adapter' {
        $root = Join-Path $temp 'switch-success'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $script:activeTarget = (Join-Path $root 'profiles/Rime_Ice')
        $script:events = New-Object Collections.Generic.List[string]
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return $script:activeTarget }
            Switch = { param($link, $target, $transaction) $script:activeTarget = $target; [void]$script:events.Add("switch:$target") }
            Stop = { param($install) [void]$script:events.Add('stop') }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) [void]$script:events.Add("deploy:$mode") }
            Verify = { param($target, $profile, $before, $started) return $true }
        }
        $result = Invoke-RimeProfileSwitch $root mint 'S-test' $adapter
        Assert ($result.Status -eq 'completed' -and $result.Profile -eq 'mint') 'switch result wrong'
        Assert ($script:activeTarget -like '*Rime_Mint') 'target not switched'
        Assert ((Get-RimeJsonValue (Join-Path $root 'state.json') 'currentProfile') -eq 'mint') 'state not updated'
        Assert (($script:events -join ',') -eq 'stop,switch:' + (Join-Path $root 'profiles/Rime_Mint') + ',deploy:Interactive') 'event order wrong'
    }
    Case 'invalid active selector fails before stopping runtime' {
        $root = Join-Path $temp 'switch-invalid-active'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        $script:stoppedInvalid = $false
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return (Join-Path $root 'outside') }.GetNewClosure()
            ValidateActive = { param($link, $target) throw 'outside managed profiles' }
            Switch = { param($link, $target, $transaction) }
            Stop = { param($unused) $script:stoppedInvalid = $true }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) }
            Verify = { param($target, $profile, $before, $started) return $true }
        }
        Throws { Invoke-RimeProfileSwitch $root ice 'S-test' $adapter } 'outside managed profiles'
        Assert (-not $script:stoppedInvalid) 'runtime stopped before active selector validation'
    }
    Case 'force deploy refreshes an already active profile' {
        $root = Join-Path $temp 'switch-force'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        $script:activeTarget = (Join-Path $root 'profiles/Rime_Ice'); $script:forceEvents = New-Object Collections.Generic.List[string]
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return $script:activeTarget }
            Switch = { param($link, $target, $transaction) [void]$script:forceEvents.Add('switch') }
            Stop = { param($unused) [void]$script:forceEvents.Add('stop') }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) [void]$script:forceEvents.Add('deploy') }
            Verify = { param($target, $profile, $before, $started) return $true }
        }
        $result = Invoke-RimeProfileSwitch $root ice 'S-test' $adapter -ForceDeploy
        Assert $result.Changed 'force deploy reported no change'
        Assert (($script:forceEvents -join ',') -eq 'stop,switch,deploy') 'force deploy skipped transaction phases'
    }
    Case 'lock failure never clears an untouched selector' {
        $root = Join-Path $temp 'switch-lock-failure'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        $script:clearCalled = $false
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return $null }
            Switch = { param($link, $target, $transaction) }
            Clear = { param($link, $target, $transaction) $script:clearCalled = $true }
            Stop = { param($unused) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) }
            Verify = { param($target, $profile, $before, $started) return $true }
        }
        $held = Enter-RimeLock $root
        try { Throws { Invoke-RimeProfileSwitch $root ice 'S-test' $adapter } 'locked' } finally { $held.Dispose() }
        Assert (-not $script:clearCalled) 'preflight failure cleared selector that was never changed'
    }
    Case 'orphan selector backup is recovered only with matching transaction' {
        $root = Join-Path $temp 'orphan-recovery'; [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $selector = Join-Path $root 'RimeConfig'; $backup = Join-Path $root '.RimeConfig.txn.previous'
        if ($IsWindows) {
            New-RimeJunction $selector (Join-Path $root 'profiles/Rime_Ice')
            Move-Item -LiteralPath $selector -Destination $backup
            New-RimeJunction $selector (Join-Path $root 'profiles/Rime_Mint')
            Write-RimeJson (Join-Path $root 'state.json') @{ status = 'switching'; transaction = 'txn' }
            $result = Recover-RimeJunctionTransaction $root 'txn'
            Assert ($result.Status -eq 'recovered') 'orphan selector was not recovered'
            Assert ((Get-RimeJunctionTarget $selector) -like '*Rime_Ice') 'recovery restored wrong selector'
        }
        $foreign = Join-Path $root '.RimeConfig.foreign.previous'; [IO.Directory]::CreateDirectory($foreign) | Out-Null
        Throws { Recover-RimeJunctionTransaction $root 'foreign' } 'not a managed Junction'
    }
    Case 'partial selector mutation during adapter failure is restored' {
        $root = Join-Path $temp 'switch-partial-mutation'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $script:activeTarget = (Join-Path $root 'profiles/Rime_Ice'); $script:partialRestored = $false
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return $script:activeTarget }
            Switch = { param($link, $target, $transaction) $script:activeTarget = $target; throw 'switch adapter interrupted' }
            Restore = { param($link, $target, $transaction) $script:activeTarget = $target; $script:partialRestored = $true }
            Stop = { param($unused) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) }
            Verify = { param($target, $profile, $before, $started) return $true }
            Restart = { param($target) }
        }
        Throws { Invoke-RimeProfileSwitch $root mint 'S-test' $adapter } 'switch adapter interrupted'
        Assert $script:partialRestored 'partial selector mutation was not restored'
        Assert ($script:activeTarget -like '*Rime_Ice') 'partial mutation left wrong selector'
        Assert ((Get-RimeJsonValue (Join-Path $root 'state.json') 'status') -eq 'failed') 'partial mutation recovery not recorded'
    }
    Case 'failed deployment restores previous selector and records failure' {
        $root = Join-Path $temp 'switch-failure'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $script:activeTarget = (Join-Path $root 'profiles/Rime_Ice')
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return $script:activeTarget }
            Switch = { param($link, $target, $transaction) $script:activeTarget = $target }
            Restore = { param($link, $target, $transaction) $script:activeTarget = $target }
            Stop = { param($install) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) throw 'deploy failed' }
            Verify = { param($target, $profile, $before, $started) return $true }
            Restart = { param($target) }
        }
        Throws { Invoke-RimeProfileSwitch $root mint 'S-test' $adapter } 'deploy failed'
        Assert ($script:activeTarget -like '*Rime_Ice') 'previous selector not restored'
        Assert ((Get-RimeJsonValue (Join-Path $root 'state.json') 'status') -eq 'failed') 'failure not recorded'
    }
    Case 'switch deploy adapter receives target and failure restarts previous runtime' {
        $root = Join-Path $temp 'switch-contract'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Ice')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Mint')) | Out-Null
        $script:activeTarget = (Join-Path $root 'profiles/Rime_Ice'); $script:deployTarget = $null; $script:restarted = $false
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return $script:activeTarget }
            Switch = { param($link, $target, $transaction) $script:activeTarget = $target }
            Restore = { param($link, $target, $transaction) $script:activeTarget = $target }
            Stop = { param($unused) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) $script:deployTarget = $target; throw 'contract deploy failure' }
            Verify = { param($target, $profile, $before, $started) return $true }
            Restart = { param($target) $script:restarted = $true }
        }
        Throws { Invoke-RimeProfileSwitch $root mint 'S-test' $adapter } 'contract deploy failure'
        Assert ($script:deployTarget -like '*Rime_Mint') 'deploy target missing'
        Assert $script:restarted 'previous runtime was not restarted'
    }
    Case 'first switch failure clears newly created selector and records failed state' {
        $root = Join-Path $temp 'switch-first-failure'; [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-RimeJson (Join-Path $root '.config-rime-root.json') @{ format = 1; ownerSid = 'S-test'; manager = 'config-rime' }
        [IO.Directory]::CreateDirectory((Join-Path $root 'profiles/Rime_Moqi')) | Out-Null
        $script:activeTarget = $null; $script:cleared = $false
        $adapter = [pscustomobject]@{
            GetActive = { param($link) return $script:activeTarget }
            Switch = { param($link, $target, $transaction) $script:activeTarget = $target }
            Clear = { param($link, $target, $transaction) $script:cleared = $true; $script:activeTarget = $null }
            Stop = { param($unused) }
            Deploy = { param($target, $mode, $timeout, $profile, $before, $started) throw 'first deploy failed' }
            Verify = { param($target, $profile, $before, $started) return $true }
        }
        Throws { Invoke-RimeProfileSwitch $root moqi 'S-test' $adapter } 'first deploy failed'
        Assert $script:cleared 'new selector was not cleared'
        Assert ($null -eq $script:activeTarget) 'selector remained after first failure'
        Assert ((Get-RimeJsonValue (Join-Path $root 'state.json') 'status') -eq 'failed') 'first failure not recorded'
    }
    Case 'config root parsing rejects malformed and relative roots' {
        $config = Join-Path $temp 'config.json'
        $absolute = Join-Path $temp 'Managed/Rime'
        Write-RimeJson $config @{ root = $absolute }
        Assert ((Read-RimeConfiguredRoot $config) -eq $absolute) 'configured root lost'
        Write-RimeJson $config @{ root = 'relative\Rime' }
        Throws { Read-RimeConfiguredRoot $config } 'absolute'
        Write-RimeJson $config @{ other = 'C:\Managed\Rime' }
        Throws { Read-RimeConfiguredRoot $config } 'root'
    }
    Case 'archive root finder rejects ambiguous archives' {
        $one = Join-Path $temp 'one'; [IO.Directory]::CreateDirectory((Join-Path $one 'top')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $one 'top/default.yaml'), 'x')
        Assert ((Find-RimeArchiveRoot $one) -eq (Join-Path $one 'top')) 'archive root wrong'
        [IO.Directory]::CreateDirectory((Join-Path $one 'second')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $one 'second/default.yaml'), 'y')
        Throws { Find-RimeArchiveRoot $one } 'ambiguous'
        $dependency = Join-Path $temp 'dependency'; [IO.Directory]::CreateDirectory((Join-Path $dependency 'top')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $dependency 'top/cangjie5.schema.yaml'), 'schema')
        Assert ((Find-RimeArchiveContentRoot $dependency 'cangjie5.schema.yaml') -eq (Join-Path $dependency 'top')) 'dependency root wrong'
    }
    Case 'profile state prevents automatic Moqi Full downgrade' {
        $profile = Join-Path $temp 'state-profile'; [IO.Directory]::CreateDirectory($profile) | Out-Null
        Write-RimeProfileState $profile 'moqi' 'full'
        Assert-RimeProfileVariantAllowed $profile 'moqi' 'full'
        Throws { Assert-RimeProfileVariantAllowed $profile 'moqi' 'lite' } 'downgrade'
        $iceProfile = Join-Path $temp 'state-ice'; [IO.Directory]::CreateDirectory($iceProfile) | Out-Null
        Assert-RimeProfileVariantAllowed $iceProfile 'ice' 'standard'
    }
    Case 'installer operation plan keeps runtime and profiles separate' {
        $plan = New-RimeInstallPlan $temp @('ice', 'mint', 'moqi') $false 'Interactive'
        Assert ($plan.RuntimeVersion -eq '0.17.4') 'runtime version wrong'
        Assert ($plan.Profiles.Count -eq 3) 'profile plan incomplete'
        Assert ($plan.Profiles[2].Variant -eq 'lite') 'Moqi default not Lite'
        $full = New-RimeInstallPlan $temp @('moqi') $true 'Quiet'
        Assert ($full.Profiles[0].Variant -eq 'full') 'Moqi Full option ignored'
        Assert ($full.DeployMode -eq 'Quiet') 'deploy mode lost'
        Assert ((Get-RimeInitialProfile '' @('mint', 'moqi') @('moqi', 'mint')) -eq 'mint') 'requested profile order not preserved'
        Assert ((Get-RimeInitialProfile '' @('ice', 'mint', 'moqi') @('mint', 'moqi')) -eq 'mint') 'failed requested profile was not skipped'
        Assert ((Get-RimeInitialProfile 'mint' @('ice', 'mint') @('ice', 'mint')) -eq 'mint') 'explicit initial profile ignored'
        Throws { Get-RimeInitialProfile 'moqi' @('ice', 'mint') @('ice', 'mint') } 'not installed'
    }
    Case 'legacy ownership seed claims only files matching pinned source' {
        $source = Join-Path $temp 'adopt-source'; $destination = Join-Path $temp 'adopt-destination'
        [IO.Directory]::CreateDirectory($source) | Out-Null; [IO.Directory]::CreateDirectory($destination) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'same.yaml'), 'same')
        [IO.File]::WriteAllText((Join-Path $source 'edited.yaml'), 'upstream')
        [IO.File]::WriteAllText((Join-Path $destination 'same.yaml'), 'same')
        [IO.File]::WriteAllText((Join-Path $destination 'edited.yaml'), 'user edit')
        $manifest = Join-Path $destination 'managed-files.json'
        $seed = Initialize-RimeManagedManifestFromSource $source $destination @('same.yaml', 'edited.yaml') $manifest
        Assert ($seed.Claimed -contains 'same.yaml') 'matching legacy file not claimed'
        Assert (-not ($seed.Claimed -contains 'edited.yaml')) 'edited legacy file claimed'
        $result = Copy-RimeManagedFiles $source $destination @('same.yaml', 'edited.yaml') $manifest
        Assert ($result.Conflicts -contains 'edited.yaml') 'edited legacy file not preserved as conflict'
        Assert (-not ($result.Conflicts -contains 'same.yaml')) 'matching legacy file conflicted'
    }
    Case 'legacy backup records selector even without legacy profile directories' {
        $root = Join-Path $temp 'selector-only-root'; $backupParent = Join-Path $root 'backups'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $selectorInfo = [pscustomobject]@{ Target = (Join-Path $root 'Rime_Ice'); LegacyProfile = 'ice' }
        $backup = Backup-RimeLegacyState $root $backupParent $selectorInfo
        Assert ($backup.Status -eq 'backup_created' -and (Test-Path $backup.Path -PathType Container)) 'selector-only backup missing'
        $metadata = Read-RimeJson (Join-Path $backup.Path 'selector.json')
        Assert ($metadata.profile -eq 'ice' -and $metadata.target -eq $selectorInfo.Target) 'selector metadata missing'
    }
    Case 'legacy profile adoption creates managed parent and preserves sources' {
        $root = Join-Path $temp 'legacy-copy'
        [IO.Directory]::CreateDirectory((Join-Path $root 'Rime_Ice/empty')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'Rime_Ice/default.yaml'), 'legacy')
        $result = Copy-RimeLegacyProfiles $root
        Assert ($result.Copied -contains 'ice') 'legacy Ice not copied'
        Assert ([IO.File]::ReadAllText((Join-Path $root 'profiles/Rime_Ice/default.yaml')) -eq 'legacy') 'managed copy missing'
        Assert (Test-Path -LiteralPath (Join-Path $root 'profiles/Rime_Ice/empty') -PathType Container) 'legacy empty directory missing'
        Assert ([IO.File]::ReadAllText((Join-Path $root 'Rime_Ice/default.yaml')) -eq 'legacy') 'legacy source changed'
        $retry = Copy-RimeLegacyProfiles $root
        Assert ($retry.AlreadyPresent -contains 'ice') 'exact interrupted adoption was not resumable'
        [IO.File]::WriteAllText((Join-Path $root 'profiles/Rime_Ice/default.yaml'), 'different')
        Throws { Copy-RimeLegacyProfiles $root } 'differs'
    }
    Case 'Full transition preserves a generated artifact replaced between reads' {
        $profile = Join-Path $temp 'variant-race-profile'; [IO.Directory]::CreateDirectory($profile) | Out-Null
        Write-RimeMoqiLiteDictionary $profile | Out-Null
        $dictionary = Join-Path $profile 'moqi_wan.lite.dict.yaml'
        $assertFunction = (Get-Command Assert-RimePlainExistingFile -CommandType Function).ScriptBlock
        $script:moqiArtifactReads = 0
        try {
            function Assert-RimePlainExistingFile([string]$Path, [string]$Purpose = 'RIME file') {
                $result = & $assertFunction $Path $Purpose
                if ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($dictionary)) {
                    $script:moqiArtifactReads++
                    if ($script:moqiArtifactReads -eq 2) { [IO.File]::WriteAllText($result, 'user replacement') }
                }
                return $result
            }
            $result = Remove-RimeMoqiLiteArtifacts $profile
        } finally {
            Set-Item -Path Function:Assert-RimePlainExistingFile -Value $assertFunction
        }
        Assert ($script:moqiArtifactReads -ge 2) 'test did not reach the second artifact read'
        Assert ($result.Preserved -contains 'moqi_wan.lite.dict.yaml') 'replaced artifact was not preserved'
        Assert ([IO.File]::ReadAllText($dictionary) -eq 'user replacement') 'replaced artifact was deleted'
    }
    Case 'Full transition removes only unchanged generated Lite artifacts' {
        $profile = Join-Path $temp 'variant-profile'; [IO.Directory]::CreateDirectory($profile) | Out-Null
        Write-RimeMoqiLiteDictionary $profile | Out-Null
        Write-RimeMoqiLiteSchemaPatch $profile | Out-Null
        $result = Remove-RimeMoqiLiteArtifacts $profile
        Assert ($result.Removed.Count -eq 3) 'generated Lite artifacts not removed'
        Assert (-not (Test-Path (Join-Path $profile 'moqi_wan.lite.dict.yaml'))) 'Lite dictionary remains'
        Write-RimeMoqiLiteDictionary $profile | Out-Null
        [IO.File]::WriteAllText((Join-Path $profile 'moqi_wan_flypymo.custom.yaml'), 'user edit')
        $result = Remove-RimeMoqiLiteArtifacts $profile
        Assert ($result.Preserved -contains 'moqi_wan_flypymo.custom.yaml') 'user patch removed'
        Assert ([IO.File]::ReadAllText((Join-Path $profile 'moqi_wan_flypymo.custom.yaml')) -eq 'user edit') 'user patch changed'
    }
    Case 'installer report preserves partial failures and manual Raycast state' {
        $report = New-RimeInstallReport $temp
        Add-RimeInstallResult $report 'ice' 'completed' ''
        Add-RimeInstallResult $report 'mint' 'failed' 'download failed'
        Add-RimeInstallResult $report 'raycast' 'manual_required' 'directory not configured'
        Assert ($report.Results.Count -eq 3) 'report results lost'
        Assert (($report.Results | Where-Object Profile -eq 'mint').Status -eq 'failed') 'failure missing'
        Assert (($report.Results | Where-Object Profile -eq 'raycast').Status -eq 'manual_required') 'manual state missing'
    }
    Case 'profile staging copies pinned files and remains idempotent' {
        $source = Join-Path $temp 'ice-source'; [IO.Directory]::CreateDirectory($source) | Out-Null
        foreach ($name in @('default.yaml', 'weasel.yaml', 'rime_ice.schema.yaml', 'rime_ice.dict.yaml', 'melt_eng.schema.yaml', 'melt_eng.dict.yaml', 'radical_pinyin.schema.yaml', 'radical_pinyin.dict.yaml')) {
            [IO.File]::WriteAllText((Join-Path $source $name), $name)
        }
        $root = Join-Path $temp 'staged-root'; Ensure-RimeRootLayout $root 'S-test' | Out-Null
        $first = Install-RimeProfileFromSource $source $root 'ice' $false
        Assert (Test-Path (Join-Path $root 'profiles/Rime_Ice/rime_ice.schema.yaml')) 'profile file missing'
        Assert (Test-Path (Join-Path $root 'profiles/Rime_Ice/default.custom.yaml')) 'schema patch missing'
        Assert ((Read-RimeJson (Join-Path $root 'profiles/Rime_Ice/.config-rime-profile.json')).variant -eq 'standard') 'profile state missing'
        $second = Install-RimeProfileFromSource $source $root 'ice' $false
        Assert ($second.Conflicts.Count -eq 0) 'idempotent staging conflicted'
        [IO.File]::WriteAllText((Join-Path $root 'profiles/Rime_Ice/default.custom.yaml'), 'user schema list')
        $third = Install-RimeProfileFromSource $source $root 'ice' $false
        Assert ($third.Conflicts -contains 'default.custom.yaml') 'profile customization conflict not propagated'
        Assert ([IO.File]::ReadAllText((Join-Path $root 'profiles/Rime_Ice/default.custom.yaml')) -eq 'user schema list') 'profile customization overwritten'
    }
    Case 'Moqi Full staging removes unchanged generated Lite artifacts only' {
        $source = Join-Path $temp 'moqi-transition-source'; [IO.Directory]::CreateDirectory($source) | Out-Null
        foreach ($name in @('default.yaml', 'weasel.yaml', 'moqi.yaml', 'moqi_wan_flypymo.schema.yaml', 'moqi_single_xh.schema.yaml', 'moqi_wan.extended.dict.yaml', 'moqi_single.dict.yaml', 'cn_dicts/8105.dict.yaml', 'cn_dicts/base.dict.yaml', 'cn_dicts/ext.dict.yaml', 'cn_dicts/others.dict.yaml', 'cn_dicts/41448.dict.yaml', 'cn_dicts_cell/animal.dict.yaml', 'cn_dicts_common/jian.dict.yaml', 'cn_dicts_common/word.dict.yaml', 'cn_dicts_common/changcijian.dict.yaml', 'cn_dicts_common/changcijian3.dict.yaml')) {
            $path = Join-Path $source $name; [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null; [IO.File]::WriteAllText($path, $name)
        }
        $root = Join-Path $temp 'moqi-transition-root'; Ensure-RimeRootLayout $root 'S-test' | Out-Null
        Install-RimeProfileFromSource $source $root 'moqi' $false | Out-Null
        $profile = Join-Path $root 'profiles/Rime_Moqi'
        Assert (Test-Path (Join-Path $profile 'moqi_wan.lite.dict.yaml')) 'Lite artifact missing'
        Install-RimeProfileFromSource $source $root 'moqi' $true | Out-Null
        Assert (-not (Test-Path (Join-Path $profile 'moqi_wan.lite.dict.yaml'))) 'Lite artifact not removed on Full transition'
        Assert ((Read-RimeJson (Join-Path $profile '.config-rime-profile.json')).variant -eq 'full') 'Full state missing'
    }
    Case 'Raycast installation reports manual fallback and preserves conflicts' {
        $source = Join-Path $temp 'raycast-source'; $destination = Join-Path $temp 'raycast-destination'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        foreach ($name in @('Rime-Ice.bat', 'Rime-Mint.bat', 'Rime-Moqi.bat', 'Rime-Toggle.bat', 'Rime-Status.bat')) {
            [IO.File]::WriteAllText((Join-Path $source $name), "@echo $name`n")
        }
        $manual = Install-RimeRaycastScripts $source ''
        Assert ($manual.Status -eq 'manual_required') 'manual fallback missing'
        $missing = Install-RimeRaycastScripts $source $destination
        Assert ($missing.Status -eq 'manual_required') 'missing Raycast directory was auto-created'
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        $installed = Install-RimeRaycastScripts $source $destination
        Assert ($installed.Status -eq 'completed' -and $installed.Copied.Count -eq 5) 'Raycast copy incomplete'
        [IO.File]::WriteAllText((Join-Path $source 'Rime-Ice.bat'), 'managed update')
        $updated = Install-RimeRaycastScripts $source $destination
        Assert ($updated.Status -eq 'completed') 'managed Raycast update failed'
        Assert ([IO.File]::ReadAllText((Join-Path $destination 'Rime-Ice.bat')) -eq 'managed update') 'unchanged managed Raycast file not upgraded'
        [IO.File]::WriteAllText((Join-Path $destination 'Rime-Ice.bat'), 'user edit')
        $again = Install-RimeRaycastScripts $source $destination
        Assert ($again.Conflicts -contains 'Rime-Ice.bat') 'Raycast conflict lost'
        Assert ([IO.File]::ReadAllText((Join-Path $destination 'Rime-Ice.bat')) -eq 'user edit') 'Raycast edit overwritten'
    }
    Case 'control script installation upgrades owned files and preserves edits' {
        $windowsSource = Join-Path $temp 'control-source'; $librarySource = Join-Path $temp 'control-lib'; $destination = Join-Path $temp 'control-destination'
        [IO.Directory]::CreateDirectory((Join-Path $windowsSource 'scripts')) | Out-Null
        [IO.Directory]::CreateDirectory($librarySource) | Out-Null
        foreach ($name in @('rime-switch.ps1', 'rime-userdata.ps1')) { [IO.File]::WriteAllText((Join-Path $windowsSource "scripts/$name"), "v1-$name") }
        foreach ($name in @('Rime.Core.ps1', 'Rime.Windows.ps1', 'Rime.Switch.ps1', 'Rime.Install.ps1')) { [IO.File]::WriteAllText((Join-Path $librarySource $name), "v1-$name") }
        $first = Install-RimeControlFiles $windowsSource $librarySource $destination
        Assert ($first.Status -eq 'completed' -and $first.Copied.Count -eq 6) 'control files not installed'
        [IO.File]::WriteAllText((Join-Path $windowsSource 'scripts/rime-switch.ps1'), 'v2-switch')
        $second = Install-RimeControlFiles $windowsSource $librarySource $destination
        Assert ([IO.File]::ReadAllText((Join-Path $destination 'rime-switch.ps1')) -eq 'v2-switch') 'owned control file not upgraded'
        [IO.File]::WriteAllText((Join-Path $destination 'rime-userdata.ps1'), 'user edit')
        [IO.File]::WriteAllText((Join-Path $windowsSource 'scripts/rime-userdata.ps1'), 'v2-userdata')
        $third = Install-RimeControlFiles $windowsSource $librarySource $destination
        Assert ($third.Status -eq 'manual_required' -and $third.Conflicts -contains 'rime-userdata.ps1') 'control conflict not reported'
        Assert ([IO.File]::ReadAllText((Join-Path $destination 'rime-userdata.ps1')) -eq 'user edit') 'control edit overwritten'
    }
    Case 'profile installation validates source before creating destination' {
        $source = Join-Path $temp 'profile-preflight-source'; $real = Join-Path $temp 'profile-preflight-real'; $link = Join-Path $source 'linked'; $root = Join-Path $temp 'profile-preflight-root'
        [IO.Directory]::CreateDirectory($source) | Out-Null; [IO.Directory]::CreateDirectory($real) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'default.yaml'), 'default')
        [IO.File]::WriteAllText((Join-Path $source 'rime_ice.schema.yaml'), 'schema')
        [IO.File]::WriteAllText((Join-Path $source 'rime_ice.dict.yaml'), 'dictionary')
        [IO.File]::WriteAllText((Join-Path $real 'foreign.yaml'), 'foreign')
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Throws { Install-RimeProfileFromSource $source $root 'ice' $false } 'reparse'
        Assert (-not (Test-Path -LiteralPath (Join-Path $root 'profiles/Rime_Ice'))) 'unsafe source created profile destination'
    }
    Case 'source staging validates all sources before creating destination' {
        $main = Join-Path $temp 'stage-preflight-main'; $real = Join-Path $temp 'stage-preflight-real'; $link = Join-Path $main 'linked'; $stage = Join-Path $temp 'stage-preflight-destination'
        [IO.Directory]::CreateDirectory($main) | Out-Null; [IO.Directory]::CreateDirectory($real) | Out-Null
        [IO.File]::WriteAllText((Join-Path $main 'default.yaml'), 'main')
        [IO.File]::WriteAllText((Join-Path $real 'foreign.yaml'), 'foreign')
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Throws { New-RimeProfileSourceStage $main @() $stage @('default.yaml') } 'reparse'
        Assert (-not (Test-Path -LiteralPath $stage)) 'unsafe source created staging destination'
    }
    Case 'legacy backup validates source tree before creating backup' {
        $root = Join-Path $temp 'legacy-backup-preflight'; $legacy = Join-Path $root 'Rime_Ice'; $real = Join-Path $temp 'legacy-backup-real'; $link = Join-Path $legacy 'linked'; $backupParent = Join-Path $root 'backups'
        [IO.Directory]::CreateDirectory($legacy) | Out-Null; [IO.Directory]::CreateDirectory($real) | Out-Null
        [IO.File]::WriteAllText((Join-Path $real 'foreign.yaml'), 'foreign')
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Throws { Backup-RimeLegacyState $root $backupParent } 'reparse'
        Assert (-not (Test-Path -LiteralPath $backupParent)) 'unsafe legacy source created backup directory'
    }
    Case 'source archive validates local input before creating cache' {
        $cache = Join-Path $temp 'archive-preflight-cache'; $missing = Join-Path $temp 'missing-source.zip'
        $entry = [pscustomobject]@{ url = $missing; sha256 = ('a' * 64); commit = ('a' * 40) }
        Throws { Get-RimeSourceArchive $entry $cache 'missing' } 'missing'
        Assert (-not (Test-Path -LiteralPath $cache)) 'missing local source created cache directory'
    }
    Case 'archive extraction validates archive before creating cache' {
        $cache = Join-Path $temp 'extract-preflight-cache'; $missing = Join-Path $temp 'missing-extract.zip'
        Throws { Get-RimeArchiveSourceRoot $missing $cache 'missing' } 'missing or is not a file|Could not find|cannot find|path'
        Assert (-not (Test-Path -LiteralPath $cache)) 'missing archive created extraction cache directory'
    }
    Case 'cached stage validates source tree before creating cache' {
        $main = Join-Path $temp 'cached-stage-preflight-main'; $real = Join-Path $temp 'cached-stage-preflight-real'; $link = Join-Path $main 'linked'; $cache = Join-Path $temp 'cached-stage-preflight-cache'
        [IO.Directory]::CreateDirectory($main) | Out-Null; [IO.Directory]::CreateDirectory($real) | Out-Null
        [IO.File]::WriteAllText((Join-Path $main 'default.yaml'), 'main')
        [IO.File]::WriteAllText((Join-Path $real 'foreign.yaml'), 'foreign')
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: symbolic-link fixture unavailable' }
        Throws { Get-RimeCachedProfileStage $main @() $cache 'ice' 'preflight' @('default.yaml') } 'reparse'
        Assert (-not (Test-Path -LiteralPath $cache)) 'unsafe staged source created cache directory'
    }
    Case 'source staging resolves main and overlay collisions before exclusive writes' {
        $main = Join-Path $temp 'stage-collision-main'; $overlay = Join-Path $temp 'stage-collision-overlay'; $stage = Join-Path $temp 'stage-collision-output'
        [IO.Directory]::CreateDirectory($main) | Out-Null; [IO.Directory]::CreateDirectory($overlay) | Out-Null
        [IO.File]::WriteAllText((Join-Path $main 'default.yaml'), 'main')
        [IO.File]::WriteAllText((Join-Path $overlay 'default.yaml'), 'overlay')
        $result = New-RimeProfileSourceStage $main @(@{ Root = $overlay; Patterns = @('default.yaml') }) $stage @('default.yaml')
        Assert ([IO.File]::ReadAllText((Join-Path $stage 'default.yaml')) -eq 'overlay') 'overlay did not retain declared precedence'
        Assert ($result.Files.Count -eq 1 -and $result.Files[0] -eq 'default.yaml') 'stage output listed collision twice'
    }
    Case 'source staging overlays pinned dependency archives without copying git metadata' {
        $main = Join-Path $temp 'main-source'; $dep = Join-Path $temp 'dep-source'; $stage = Join-Path $temp 'stage-source'
        [IO.Directory]::CreateDirectory($main) | Out-Null; [IO.Directory]::CreateDirectory($dep) | Out-Null
        [IO.File]::WriteAllText((Join-Path $main 'default.yaml'), 'main')
        [IO.File]::WriteAllText((Join-Path $main 'ignored.txt'), 'ignored')
        [IO.File]::WriteAllText((Join-Path $main '.git'), 'metadata')
        [IO.File]::WriteAllText((Join-Path $dep 'cangjie5.schema.yaml'), 'dependency')
        $result = New-RimeProfileSourceStage $main @(@{ Root = $dep; Patterns = @('cangjie5.schema.yaml') }) $stage @('default.yaml')
        Assert (Test-Path (Join-Path $stage 'default.yaml')) 'main source missing'
        Assert ([IO.File]::ReadAllText((Join-Path $stage 'cangjie5.schema.yaml')) -eq 'dependency') 'dependency overlay missing'
        Assert (-not (Test-Path (Join-Path $stage '.git'))) 'metadata copied'
        Assert (-not (Test-Path (Join-Path $stage 'ignored.txt'))) 'unselected source copied'
        Assert ($result.Files.Count -eq 2) 'stage manifest incomplete'
    }
    Case 'Moqi staged source closes Cangjie Stroke and Luna dependencies' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $sourceDirectory = Join-Path $temp 'moqi-closure-sources'; $cache = Join-Path $temp 'moqi-closure-cache'
        [IO.Directory]::CreateDirectory($sourceDirectory) | Out-Null
        function New-RimeTestArchive([string]$Path, [hashtable]$Entries) {
            $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($relative in $Entries.Keys) {
                    $entry = $archive.CreateEntry([string]$relative)
                    $writer = New-Object IO.StreamWriter($entry.Open())
                    try { $writer.Write([string]$Entries[$relative]) } finally { $writer.Dispose() }
                }
            } finally { $archive.Dispose() }
        }
        $archives = @{}
        $contents = @{
            moqi = @{
                'moqi/default.yaml' = 'default'; 'moqi/moqi_wan_flypymo.schema.yaml' = 'main'; 'moqi/moqi_single_xh.schema.yaml' = 'single'
                'moqi/cn_dicts/41448.dict.yaml' = 'full-only'
            }
            cangjie = @{
                'cangjie/cangjie5.schema.yaml' = 'schema'; 'cangjie/cangjie5.dict.yaml' = 'dictionary'
                'cangjie/cangjie5.base.dict.yaml' = 'base'; 'cangjie/cangjie5.stem.dict.yaml' = 'stem'; 'cangjie/cangjie5.extended.dict.yaml' = 'extended'
            }
            stroke = @{ 'stroke/stroke.schema.yaml' = 'schema'; 'stroke/stroke.dict.yaml' = 'dictionary' }
            luna = @{
                'luna/luna_pinyin.schema.yaml' = 'schema'; 'luna/luna_quanpin.schema.yaml' = 'schema'
                'luna/luna_pinyin.dict.yaml' = 'dictionary'; 'luna/pinyin.yaml' = 'settings'
            }
        }
        foreach ($name in $contents.Keys) {
            $path = Join-Path $sourceDirectory "$name.zip"
            New-RimeTestArchive $path $contents[$name]
            $archives[$name] = [pscustomobject]@{ repository = "example/$name"; url = $path; sha256 = Get-RimeFileHash $path; commit = ([string]([int][char]$name[0])).PadLeft(40, '0') }
        }
        $archives['moqi'] | Add-Member -NotePropertyName variants -NotePropertyValue ([pscustomobject]@{
            lite = [pscustomobject]@{ default = $true; dictionary = 'moqi_wan.lite'; schemas = @('moqi_wan_flypymo', 'moqi_single_xh'); omits = @('cn_dicts/41448') }
            full = [pscustomobject]@{ default = $false; dictionary = 'moqi_wan.extended'; schemas = @('moqi_wan_flypymo', 'moqi_single_xh'); recipe = 'recipes/full.recipe.yaml' }
        })
        $lock = [pscustomobject]@{ sources = [pscustomobject]$archives }
        $lite = Get-RimeSourceRootForProfile 'moqi' $false $cache $lock
        foreach ($relative in @('moqi_wan_flypymo.schema.yaml', 'cangjie5.schema.yaml', 'stroke.schema.yaml', 'luna_pinyin.schema.yaml', 'luna_quanpin.schema.yaml', 'luna_pinyin.dict.yaml', 'pinyin.yaml')) {
            Assert (Test-Path -LiteralPath (Join-Path $lite $relative) -PathType Leaf) "Moqi dependency missing from Lite stage: $relative"
        }
        Assert (-not (Test-Path -LiteralPath (Join-Path $lite 'cn_dicts/41448.dict.yaml'))) 'Lite stage includes Full-only dictionary'
        $full = Get-RimeSourceRootForProfile 'moqi' $true $cache $lock
        Assert (Test-Path -LiteralPath (Join-Path $full 'cn_dicts/41448.dict.yaml') -PathType Leaf) 'Full stage omits Full-only dictionary'
    }
    Case 'source archive cache downloads once and verifies pinned bytes' {
        $payload = Join-Path $temp 'payload.zip'; $cache = Join-Path $temp 'cache'
        [IO.File]::WriteAllText($payload, 'archive bytes')
        $hash = Get-RimeFileHash $payload
        $entry = [pscustomobject]@{ url = $payload; sha256 = $hash; commit = ('a' * 40) }
        $first = Get-RimeSourceArchive $entry $cache 'fixture'
        $second = Get-RimeSourceArchive $entry $cache 'fixture'
        Assert ($first -eq $second -and (Test-Path $first)) 'cache path unstable'
        Assert ((Split-Path $first -Leaf) -match [Regex]::Escape($hash.Substring(0, 12))) 'cache path is not hash keyed'
        Assert ((Get-RimeFileHash $first) -eq $hash) 'cached hash wrong'
        $bad = [pscustomobject]@{ url = $payload; sha256 = ('0' * 64); commit = ('a' * 40) }
        Throws { Get-RimeSourceArchive $bad $cache 'bad' } 'checksum'
        $http = [pscustomobject]@{ url = 'http://example.invalid/archive.zip'; sha256 = $hash; commit = ('a' * 40) }
        Throws { Get-RimeSourceArchive $http $cache 'http-source' } 'HTTPS'
        $ownedName = 'owned-' + ('b' * 40) + '-' + $hash.Substring(0, 12) + '.zip'
        $ownedPath = Join-Path $cache $ownedName
        [IO.File]::WriteAllText($ownedPath, 'unexpected cache bytes')
        $ownedEntry = [pscustomobject]@{ url = $payload; sha256 = $hash; commit = ('b' * 40) }
        Throws { Get-RimeSourceArchive $ownedEntry $cache 'owned' } 'pinned cache artifact'
        Assert ([IO.File]::ReadAllText($ownedPath) -eq 'unexpected cache bytes') 'mismatched cache artifact was deleted'
    }
    Case 'new source-cache transfer refuses an existing destination' {
        if ($null -eq (Get-Command Copy-RimeFileToNewFile -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Copy-RimeFileToNewFile missing'
        }
        $source = Join-Path $temp 'new-cache-transfer-source.zip'; $destination = Join-Path $temp 'new-cache-transfer-destination.download'
        [IO.File]::WriteAllText($source, 'managed bytes')
        [IO.File]::WriteAllText($destination, 'attacker bytes')
        Throws { Copy-RimeFileToNewFile $source $destination 'test source-cache transfer' } 'already exists|appeared'
        Assert ([IO.File]::ReadAllText($destination) -eq 'attacker bytes') 'new source-cache transfer overwrote existing destination'
        $installText = [IO.File]::ReadAllText((Join-Path $repo 'windows/lib/Rime.Install.ps1'))
        Assert ($installText -match 'Copy-RimeFileToNewFile\s+\$sourceFile\s+\$temporary') 'source-cache local transfer bypasses exclusive-create helper'
        Assert ($installText -notmatch '\[IO\.File\]::Copy\(\$sourceFile,\s*\$temporary,\s*\$true\)') 'source-cache local transfer overwrites reserved temporary path'
        Assert ($installText -notmatch 'Invoke-WebRequest\s+-Uri\s+\$uri\s+-OutFile\s+\$temporary') 'source-cache network transfer overwrites reserved temporary path'
    }
    Case 'cache lock waits bounded time instead of racing writers' {
        $directory = Join-Path $temp 'cache-lock'; [IO.Directory]::CreateDirectory($directory) | Out-Null
        $held = Enter-RimeNamedLock $directory 'archive.lock'
        try { Throws { Enter-RimeNamedLockWait $directory 'archive.lock' 100 } 'timed out' } finally { $held.Dispose() }
        $acquired = Enter-RimeNamedLockWait $directory 'archive.lock' 100
        $acquired.Dispose()
    }
    Case 'failed cache download preserves its ambiguous temporary file' {
        $source = Join-Path $temp 'failed-cache-download-source.zip'; $cache = Join-Path $temp 'failed-cache-download-cache'
        [IO.File]::WriteAllText($source, 'download bytes')
        $entry = [pscustomobject]@{ url = $source; sha256 = ('0' * 64); commit = ('f' * 40) }
        Throws { Get-RimeSourceArchive $entry $cache 'failed-download' } 'checksum'
        $temporary = @(Get-ChildItem -LiteralPath $cache -Filter '*.download' -File -Force)
        Assert ($temporary.Count -eq 1) 'failed download temporary was deleted despite uncertain ownership'
        Assert ([IO.File]::ReadAllText($temporary[0].FullName) -eq 'download bytes') 'failed download temporary contents changed'
    }
    Case 'hash keyed extraction repairs owned tampering and rejects unknown cache directories' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $temp 'cache-fixture.zip'; $cache = Join-Path $temp 'extract-cache'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('source/default.yaml'); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('expected'); $writer.Dispose()
        } finally { $archive.Dispose() }
        $first = Get-RimeArchiveSourceRoot $zip $cache 'fixture' 'default.yaml'
        Assert ([IO.File]::ReadAllText((Join-Path $first 'default.yaml')) -eq 'expected') 'initial extraction failed'
        [IO.File]::WriteAllText((Join-Path $first 'default.yaml'), 'tampered')
        $second = Get-RimeArchiveSourceRoot $zip $cache 'fixture' 'default.yaml'
        Assert ($second -eq $first) 'hash keyed extraction path changed'
        Assert ([IO.File]::ReadAllText((Join-Path $second 'default.yaml')) -eq 'expected') 'owned extraction tampering not repaired'
        $hash = Get-RimeFileHash $zip
        $foreign = Join-Path $cache ("foreign-$hash-extracted")
        [IO.Directory]::CreateDirectory($foreign) | Out-Null
        Throws { Get-RimeArchiveSourceRoot $zip $cache 'foreign' 'default.yaml' } 'not managed'
        Assert (Test-Path $foreign) 'unknown cache directory was deleted'
    }
    Case 'cache staging failure preserves a colliding unowned temporary directory' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $temp 'collision-cache.zip'; $cache = Join-Path $temp 'collision-cache'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('source/default.yaml'); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('managed'); $writer.Dispose()
        } finally { $archive.Dispose() }
        $directoryFunction = (Get-Command New-RimePlainDirectory -CommandType Function).ScriptBlock
        $script:cacheCollisionDirectory = $null
        try {
            function New-RimePlainDirectory([string]$Path, [string]$Purpose = 'RIME directory') {
                if ($Purpose -eq 'RIME archive destination') {
                    [IO.Directory]::CreateDirectory($Path) | Out-Null
                    [IO.File]::WriteAllText((Join-Path $Path 'attacker.txt'), 'attacker')
                    $script:cacheCollisionDirectory = $Path
                    throw 'injected archive staging collision'
                }
                return & $directoryFunction $Path $Purpose
            }
            Throws { Get-RimeArchiveSourceRoot $zip $cache 'collision' 'default.yaml' } 'injected archive staging collision'
        } finally {
            Set-Item -Path Function:New-RimePlainDirectory -Value $directoryFunction
        }
        Assert ($null -ne $script:cacheCollisionDirectory) 'test did not create cache-stage collision directory'
        Assert (Test-Path -LiteralPath (Join-Path $script:cacheCollisionDirectory 'attacker.txt') -PathType Leaf) 'cache cleanup deleted colliding unowned directory'
    }
    Case 'profile stage identity includes every source pin and variant' {
        $lite = Get-RimeProfileStageIdentity @('stage-v2', 'main-commit', 'cangjie-commit', 'stroke-commit', 'pattern:default.yaml', 'lite')
        $full = Get-RimeProfileStageIdentity @('stage-v2', 'main-commit', 'cangjie-commit', 'stroke-commit', 'pattern:default.yaml', 'full')
        $changedDependency = Get-RimeProfileStageIdentity @('stage-v2', 'main-commit', 'other-cangjie', 'stroke-commit', 'pattern:default.yaml', 'lite')
        $changedPattern = Get-RimeProfileStageIdentity @('stage-v2', 'main-commit', 'cangjie-commit', 'stroke-commit', 'pattern:other.yaml', 'lite')
        Assert ($lite -match '^[a-f0-9]{32}$') 'stage identity is not a bounded hash'
        Assert ($lite -ne $full) 'Lite and Full stage identities collide'
        Assert ($lite -ne $changedDependency) 'dependency pin change did not change stage identity'
        Assert ($lite -ne $changedPattern) 'source pattern change did not change stage identity'
    }
    Case 'cached profile stage detects tampering and rebuilds only owned stage' {
        $main = Join-Path $temp 'cached-main'; $cache = Join-Path $temp 'stage-cache'
        [IO.Directory]::CreateDirectory($main) | Out-Null
        [IO.File]::WriteAllText((Join-Path $main 'default.yaml'), 'expected')
        $first = Get-RimeCachedProfileStage $main @() $cache 'moqi' 'identity-lite' @('default.yaml')
        [IO.File]::WriteAllText((Join-Path $first 'default.yaml'), 'tampered')
        $second = Get-RimeCachedProfileStage $main @() $cache 'moqi' 'identity-lite' @('default.yaml')
        Assert ($second -eq $first) 'cached stage path changed'
        Assert ([IO.File]::ReadAllText((Join-Path $second 'default.yaml')) -eq 'expected') 'owned stage tampering not repaired'
    }
    Case 'Windows host policy requires Windows 11 x64 and PowerShell 7 x64' {
        foreach ($name in @('Get-RimeWindowsHostInfo', 'Assert-RimePowerShell7X64')) {
            if ($null -eq (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { throw "$name missing" }
        }
        $hostInfoFunction = (Get-Command Get-RimeWindowsHostInfo -CommandType Function).ScriptBlock
        $assertHostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $assertPowerShellFunction = (Get-Command Assert-RimePowerShell7X64 -CommandType Function).ScriptBlock
        try {
            function Get-RimeWindowsHostInfo {
                return [pscustomobject]@{ Platform = [PlatformID]::Win32NT; ProductName = 'Windows 10 Pro'; BuildNumber = '19045'; Is64BitOperatingSystem = $true; Is64BitProcess = $true; PowerShellMajor = 7 }
            }
            Throws { Assert-RimeWindowsHost } 'Windows 11'
            function Get-RimeWindowsHostInfo {
                return [pscustomobject]@{ Platform = [PlatformID]::Win32NT; ProductName = 'Windows 11 Pro'; BuildNumber = '21999'; Is64BitOperatingSystem = $true; Is64BitProcess = $true; PowerShellMajor = 7 }
            }
            Throws { Assert-RimeWindowsHost } '22000'
            function Get-RimeWindowsHostInfo {
                return [pscustomobject]@{ Platform = [PlatformID]::Win32NT; ProductName = 'Windows 10 Pro'; BuildNumber = '26200'; Is64BitOperatingSystem = $true; Is64BitProcess = $true; PowerShellMajor = 7 }
            }
            Assert-RimeWindowsHost
            function Get-RimeWindowsHostInfo {
                return [pscustomobject]@{ Platform = [PlatformID]::Win32NT; ProductName = 'Windows Server 2025'; BuildNumber = '26100'; Is64BitOperatingSystem = $true; Is64BitProcess = $true; PowerShellMajor = 7 }
            }
            Throws { Assert-RimeWindowsHost } 'Windows 11'
            function Get-RimeWindowsHostInfo {
                return [pscustomobject]@{ Platform = [PlatformID]::Win32NT; ProductName = 'Windows 11 Pro'; BuildNumber = '22000'; Is64BitOperatingSystem = $true; Is64BitProcess = $false; PowerShellMajor = 7 }
            }
            Assert-RimeWindowsHost
            Assert (@(Assert-RimeWindowsHost).Count -eq 0) 'Windows host assertion leaked host info output'
            Throws { Assert-RimePowerShell7X64 } '64-bit PowerShell 7'
            function Get-RimeWindowsHostInfo {
                return [pscustomobject]@{ Platform = [PlatformID]::Win32NT; ProductName = 'Windows 11 Pro'; BuildNumber = '22631'; Is64BitOperatingSystem = $true; Is64BitProcess = $true; PowerShellMajor = 7 }
            }
            Assert-RimeWindowsHost
            Assert (@(Assert-RimePowerShell7X64).Count -eq 0) 'PowerShell assertion leaked host info output'
            Assert-RimePowerShell7X64
        } finally {
            Set-Item -Path Function:Get-RimeWindowsHostInfo -Value $hostInfoFunction
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $assertHostFunction
            Set-Item -Path Function:Assert-RimePowerShell7X64 -Value $assertPowerShellFunction
        }
    }
    Case 'trusted elevated PowerShell host ignores hostile PATH candidates' {
        if ($null -eq (Get-Command Get-RimeTrustedPowerShellHostFromFacts -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Get-RimeTrustedPowerShellHostFromFacts missing'
        }
        $hostDirectory = Join-Path $temp 'trusted-pwsh'; $fakeDirectory = Join-Path $temp 'hostile-pwsh'
        [IO.Directory]::CreateDirectory($hostDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($fakeDirectory) | Out-Null
        $trusted = Join-Path $hostDirectory 'pwsh.exe'; $hostile = Join-Path $fakeDirectory 'pwsh.exe'
        [IO.File]::WriteAllText($trusted, 'trusted')
        [IO.File]::WriteAllText($hostile, 'hostile')
        $oldPath = $env:PATH
        try {
            $env:PATH = $fakeDirectory + [IO.Path]::PathSeparator + $oldPath
            $facts = [pscustomobject]@{
                ProcessPath = $trusted
                PSHomePath = $trusted
                SignatureStatus = 'Valid'
                SignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation'
            }
            $resolved = Get-RimeTrustedPowerShellHostFromFacts $facts
            Assert ($resolved -eq [IO.Path]::GetFullPath($trusted)) 'trusted host did not come from current host facts'
            Assert ($resolved -ne [IO.Path]::GetFullPath($hostile)) 'hostile PATH candidate was selected'
            $facts.SignatureStatus = 'NotSigned'
            Throws { Get-RimeTrustedPowerShellHostFromFacts $facts } 'signature'
            $facts.SignatureStatus = 'Valid'; $facts.SignerSubject = 'CN=Not Microsoft Corporation'
            Throws { Get-RimeTrustedPowerShellHostFromFacts $facts } 'signature'
            $facts.SignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation'; $facts.PSHomePath = $hostile
            Throws { Get-RimeTrustedPowerShellHostFromFacts $facts } 'match'
            $facts.PSHomePath = $trusted; $facts.ProcessPath = (Join-Path $hostDirectory 'powershell.exe')
            [IO.File]::WriteAllText($facts.ProcessPath, 'wrong leaf')
            Throws { Get-RimeTrustedPowerShellHostFromFacts $facts } 'pwsh.exe'
            $facts.ProcessPath = $trusted
            $linkedDirectory = Join-Path $temp 'trusted-pwsh-link'
            try {
                New-Item -ItemType SymbolicLink -Path $linkedDirectory -Target $hostDirectory -ErrorAction Stop | Out-Null
                $facts.ProcessPath = Join-Path $linkedDirectory 'pwsh.exe'; $facts.PSHomePath = $facts.ProcessPath
                Throws { Get-RimeTrustedPowerShellHostFromFacts $facts } 'reparse|unsafe'
            } catch {
                if ($_.Exception.Message -match 'reparse|unsafe') { throw }
                throw 'SKIP: PowerShell host symbolic-link fixture unavailable' }
        } finally {
            $env:PATH = $oldPath
        }
    }
    Case 'registry selector setter rejects reparse parents before mutation' {
        $real = Join-Path $temp 'registry-selector-real'; $link = Join-Path $temp 'registry-selector-link'
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { throw 'SKIP: registry-selector symbolic-link fixture unavailable' }
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $newItemFunction = Get-Item -Path Function:New-Item -ErrorAction SilentlyContinue
        $setPropertyFunction = Get-Item -Path Function:Set-ItemProperty -ErrorAction SilentlyContinue
        $snapshotFunction = (Get-Command Get-RimeWeaselUserDirectorySnapshot -CommandType Function -ErrorAction SilentlyContinue)
        $script:registrySelectorMutations = 0
        try {
            function Assert-RimeWindowsHost { }
            function New-Item { param($Path, [switch]$Force) $script:registrySelectorMutations++ }
            function Set-ItemProperty { param($Path, $Name, $Value, $Type) $script:registrySelectorMutations++ }
            function Get-RimeWeaselUserDirectorySnapshot { return [pscustomobject]@{ Exists = $true; Value = (Join-Path $real 'RimeConfig') } }
            Throws { Set-RimeWeaselUserDirectory (Join-Path $link 'RimeConfig') } 'reparse'
            Assert ($script:registrySelectorMutations -eq 0) 'unsafe selector reached Registry mutation'
            $unmanaged = Join-Path $temp 'registry-selector-unmanaged'; [IO.Directory]::CreateDirectory($unmanaged) | Out-Null
            Throws { Set-RimeWeaselUserDirectory (Join-Path $unmanaged 'RimeConfig') } 'managed'
            Assert ($script:registrySelectorMutations -eq 0) 'unmanaged selector reached Registry mutation'
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
            if ($null -eq $newItemFunction) { Remove-Item -Path Function:New-Item -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:New-Item -Value $newItemFunction.ScriptBlock }
            if ($null -eq $setPropertyFunction) { Remove-Item -Path Function:Set-ItemProperty -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Set-ItemProperty -Value $setPropertyFunction.ScriptBlock }
            if ($null -eq $snapshotFunction) { Remove-Item -Path Function:Get-RimeWeaselUserDirectorySnapshot -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Get-RimeWeaselUserDirectorySnapshot -Value $snapshotFunction.ScriptBlock }
        }
    }
    Case 'selector transition exposes registry rollback failure as recovery required' {
        foreach ($name in @('Invoke-RimeSelectorTransition', 'Test-RimeWeaselUserDirectorySnapshotMatch')) {
            if ($null -eq (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { throw "$name missing" }
        }
        $snapshotFunction = (Get-Command Get-RimeWeaselUserDirectorySnapshot -CommandType Function -ErrorAction SilentlyContinue)
        $setFunction = (Get-Command Set-RimeWeaselUserDirectory -CommandType Function).ScriptBlock
        $restoreFunction = (Get-Command Restore-RimeWeaselUserDirectorySnapshot -CommandType Function -ErrorAction SilentlyContinue)
        try {
            function Get-RimeWeaselUserDirectorySnapshot { return [pscustomobject]@{ Exists = $true; Value = 'D:\Old\RimeConfig' } }
            function Set-RimeWeaselUserDirectory { param($Selector) }
            function Restore-RimeWeaselUserDirectorySnapshot { param($Snapshot) throw 'registry restore denied' }
            $result = Invoke-RimeSelectorTransition 'D:\New\RimeConfig' { throw 'deployment failed' }
            Assert ($result.Status -eq 'recovery_required') 'rollback failure was reported as ordinary switch failure'
            Assert ($result.Error -match 'deployment failed') 'original switch error lost'
            Assert ($result.RecoveryError -match 'registry restore denied') 'rollback error lost'
            Assert (Test-RimeWeaselUserDirectorySnapshotMatch ([pscustomobject]@{ Exists = $false; Value = $null }) ([pscustomobject]@{ Exists = $false; Value = $null })) 'absent selector snapshot did not compare equal'
            Assert (-not (Test-RimeWeaselUserDirectorySnapshotMatch ([pscustomobject]@{ Exists = $false; Value = $null }) ([pscustomobject]@{ Exists = $true; Value = 'D:\Unexpected' }))) 'selector snapshot treated unexpected value as absent'
        } finally {
            if ($null -eq $snapshotFunction) { Remove-Item -Path Function:Get-RimeWeaselUserDirectorySnapshot -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Get-RimeWeaselUserDirectorySnapshot -Value $snapshotFunction.ScriptBlock }
            Set-Item -Path Function:Set-RimeWeaselUserDirectory -Value $setFunction
            if ($null -eq $restoreFunction) { Remove-Item -Path Function:Restore-RimeWeaselUserDirectorySnapshot -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Restore-RimeWeaselUserDirectorySnapshot -Value $restoreFunction.ScriptBlock }
        }
    }
    Case 'process enumeration refuses uninspectable current-session candidates' {
        $install = Join-Path $temp 'enum-unverified-runtime'; [IO.Directory]::CreateDirectory($install) | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'WeaselServer.exe'), 'fixture')
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $sessionFunction = (Get-Command Get-RimeCurrentSessionId -CommandType Function -ErrorAction SilentlyContinue)
        $processFunction = Get-Item -Path Function:Get-Process -ErrorAction SilentlyContinue
        $script:enumeratedSession = 1
        try {
            function Assert-RimeWindowsHost { }
            function Get-RimeCurrentSessionId { return 1 }
            function Get-Process {
                [CmdletBinding()]
                param($Name, $Id, [switch]$IncludeUserName)
                if ($PSBoundParameters.ContainsKey('Name')) { return [pscustomobject]@{ Id = 4242; SessionId = $script:enumeratedSession } }
                throw 'Access is denied.'
            }
            Throws { Get-RimeMatchingServerProcesses $install 'S-test' } 'Cannot inspect'
            $script:enumeratedSession = 2
            $otherSession = @(Get-RimeMatchingServerProcesses $install 'S-test')
            Assert ($otherSession.Count -eq 0) 'another session produced a matching record'
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
            if ($null -eq $sessionFunction) { Remove-Item -Path Function:Get-RimeCurrentSessionId -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Get-RimeCurrentSessionId -Value $sessionFunction.ScriptBlock }
            if ($null -eq $processFunction) { Remove-Item -Path Function:Get-Process -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Get-Process -Value $processFunction.ScriptBlock }
        }
    }
    Case 'Weasel stop never reaches broad quit IPC after process identity changes' {
        if ($null -eq (Get-Command Get-RimeVerifiedServerProcess -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Get-RimeVerifiedServerProcess missing'
        }
        $stopBody = (Get-Command Stop-RimeWeasel -CommandType Function).ScriptBlock.ToString()
        $broadPipeToken = '/' + 'quit'
        Assert ($stopBody -notmatch [Regex]::Escape($broadPipeToken)) 'Weasel stop still contains broad pipe shutdown IPC'
        Assert ($stopBody -notmatch '(?i)Start-Process') 'Weasel stop launches a process instead of targeting verified PIDs'
        $hostFunction = (Get-Command Assert-RimeWindowsHost -CommandType Function).ScriptBlock
        $ownerFunction = (Get-Command Assert-RimeOwnerContext -CommandType Function).ScriptBlock
        $matchingFunction = (Get-Command Get-RimeMatchingServerProcesses -CommandType Function).ScriptBlock
        $verifiedFunction = (Get-Command Get-RimeVerifiedServerProcess -CommandType Function).ScriptBlock
        $startProcessFunction = Get-Item -Path Function:Start-Process -ErrorAction SilentlyContinue
        $stopProcessFunction = Get-Item -Path Function:Stop-Process -ErrorAction SilentlyContinue
        $install = Join-Path $temp 'stop-scope-runtime'; [IO.Directory]::CreateDirectory($install) | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'WeaselServer.exe'), 'fixture')
        $script:broadQuitCalls = 0; $script:forcedStopCalls = 0
        try {
            function Assert-RimeWindowsHost { }
            function Assert-RimeOwnerContext { param($OwnerSid) }
            function Get-RimeMatchingServerProcesses {
                param($InstallDirectory, $OwnerSid)
                return @([pscustomobject]@{ Id = 777; Path = (Join-Path $InstallDirectory 'WeaselServer.exe'); Sid = $OwnerSid; SessionId = 1; StartTimeUtc = [DateTime]::UtcNow })
            }
            function Get-RimeVerifiedServerProcess { param($Record, $InstallDirectory, $OwnerSid) return $null }
            function Start-Process {
                [CmdletBinding()]
                param($FilePath, $ArgumentList, $WindowStyle, [switch]$Wait, [switch]$PassThru)
                $script:broadQuitCalls++
            }
            function Stop-Process {
                [CmdletBinding()]
                param($Id, [switch]$Force)
                $script:forcedStopCalls++
            }
            Throws { Stop-RimeWeasel $install 'S-test' 0 } 'Unable to stop matching'
            Assert ($script:broadQuitCalls -eq 0) 'process stop launched broad Weasel quit IPC'
            Assert ($script:forcedStopCalls -eq 0) 'identity-changed process was force stopped'
        } finally {
            Set-Item -Path Function:Assert-RimeWindowsHost -Value $hostFunction
            Set-Item -Path Function:Assert-RimeOwnerContext -Value $ownerFunction
            Set-Item -Path Function:Get-RimeMatchingServerProcesses -Value $matchingFunction
            Set-Item -Path Function:Get-RimeVerifiedServerProcess -Value $verifiedFunction
            if ($null -eq $startProcessFunction) { Remove-Item -Path Function:Start-Process -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Start-Process -Value $startProcessFunction.ScriptBlock }
            if ($null -eq $stopProcessFunction) { Remove-Item -Path Function:Stop-Process -ErrorAction SilentlyContinue }
            else { Set-Item -Path Function:Stop-Process -Value $stopProcessFunction.ScriptBlock }
        }
    }
    Case 'Moqi stage identity includes lock bytes rules format and variant' {
        if ($null -eq (Get-Command Get-RimeMoqiStageIdentityParts -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Get-RimeMoqiStageIdentityParts missing'
        }
        function New-RimeTestStageLock([string]$MoqiSha = ('1' * 64), [string]$MoqiUrl = 'https://example.test/moqi.zip', [string]$CangjieSha = ('2' * 64)) {
            return [pscustomobject]@{ sources = [pscustomobject]@{
                moqi = [pscustomobject]@{
                    repository = 'example/moqi'; commit = ('a' * 40); url = $MoqiUrl; sha256 = $MoqiSha
                    variants = [pscustomobject]@{
                        lite = [pscustomobject]@{ default = $true; dictionary = 'moqi_wan.lite'; schemas = @('moqi_wan_flypymo', 'moqi_single_xh'); omits = @('cn_dicts/41448') }
                        full = [pscustomobject]@{ default = $false; dictionary = 'moqi_wan.extended'; schemas = @('moqi_wan_flypymo', 'moqi_single_xh'); recipe = 'recipes/full.recipe.yaml' }
                    }
                }
                cangjie = [pscustomobject]@{ repository = 'example/cangjie'; commit = ('b' * 40); url = 'https://example.test/cangjie.zip'; sha256 = $CangjieSha }
                stroke = [pscustomobject]@{ repository = 'example/stroke'; commit = ('c' * 40); url = 'https://example.test/stroke.zip'; sha256 = ('3' * 64) }
                luna = [pscustomobject]@{ repository = 'example/luna'; commit = ('d' * 40); url = 'https://example.test/luna.zip'; sha256 = ('4' * 64) }
            } }
        }
        function New-RimeTestStageOverlays($Lock, [string[]]$CangjiePatterns = @('cangjie5.schema.yaml')) {
            return @(
                [pscustomobject]@{ Name = 'cangjie'; Entry = $Lock.sources.cangjie; Patterns = $CangjiePatterns },
                [pscustomobject]@{ Name = 'stroke'; Entry = $Lock.sources.stroke; Patterns = @('stroke.schema.yaml') },
                [pscustomobject]@{ Name = 'luna'; Entry = $Lock.sources.luna; Patterns = @('luna_pinyin.schema.yaml') }
            )
        }
        $lock = New-RimeTestStageLock
        $main = @('default.yaml', 'moqi_wan_flypymo.schema.yaml')
        $overlays = New-RimeTestStageOverlays $lock
        $baseline = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $lock $false $main $overlays 'moqi-stage-v3')
        $reordered = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $lock $false $main @($overlays[2], $overlays[0], $overlays[1]) 'moqi-stage-v3')
        Assert ($reordered -ne $baseline) 'Moqi stage identity ignored declared overlay position'
        $shaChanged = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts (New-RimeTestStageLock ('9' * 64)) $false $main (New-RimeTestStageOverlays (New-RimeTestStageLock ('9' * 64))) 'moqi-stage-v3')
        $urlChangedLock = New-RimeTestStageLock; $urlChangedLock.sources.moqi.url = 'https://mirror.example.test/moqi.zip'
        $urlChanged = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $urlChangedLock $false $main (New-RimeTestStageOverlays $urlChangedLock) 'moqi-stage-v3')
        $patternChanged = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $lock $false @('default.yaml') $overlays 'moqi-stage-v3')
        $overlayPatternChanged = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $lock $false $main (New-RimeTestStageOverlays $lock @('cangjie5.schema.yaml', 'cangjie5.dict.yaml')) 'moqi-stage-v3')
        $dependencyChangedLock = New-RimeTestStageLock ('1' * 64) 'https://example.test/moqi.zip' ('8' * 64)
        $dependencyChanged = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $dependencyChangedLock $false $main (New-RimeTestStageOverlays $dependencyChangedLock) 'moqi-stage-v3')
        $variantRuleChangedLock = New-RimeTestStageLock
        $variantRuleChangedLock.sources.moqi.variants.lite.dictionary = 'moqi_wan.other'
        $variantRuleChanged = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $variantRuleChangedLock $false $main (New-RimeTestStageOverlays $variantRuleChangedLock) 'moqi-stage-v3')
        $full = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $lock $true $main $overlays 'moqi-stage-v3')
        $formatChanged = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $lock $false $main $overlays 'moqi-stage-v4')
        foreach ($identity in @($shaChanged, $urlChanged, $patternChanged, $overlayPatternChanged, $dependencyChanged, $variantRuleChanged, $full, $formatChanged)) {
            Assert ($identity -ne $baseline) 'Moqi stage identity omitted a lock, rule, format, or variant input'
        }
    }
    Case 'install component failures remain in the report with prior results' {
        if ($null -eq (Get-Command Invoke-RimeInstallComponent -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Invoke-RimeInstallComponent missing'
        }
        $report = New-RimeInstallReport $temp
        Add-RimeInstallResult $report 'ice' 'completed' '' | Out-Null
        $control = Invoke-RimeInstallComponent $report 'control' { throw 'control copy denied' }
        $raycast = Invoke-RimeInstallComponent $report 'raycast' { throw 'raycast copy denied' }
        Assert ($control.Status -eq 'failed' -and $raycast.Status -eq 'failed') 'component exception escaped report boundary'
        Assert (($report.Results | Where-Object Profile -eq 'ice').Status -eq 'completed') 'prior profile result was lost'
        Assert (($report.Results | Where-Object Profile -eq 'control').Message -match 'control copy denied') 'control failure message missing'
        Assert (($report.Results | Where-Object Profile -eq 'raycast').Message -match 'raycast copy denied') 'Raycast failure message missing'
        $installerText = [IO.File]::ReadAllText((Join-Path $repo 'windows/install.ps1'))
        Assert ($installerText.Contains("Invoke-RimeInstallComponent `$report 'switch'")) 'switch exceptions bypass install report boundary'
    }
    Case 'Windows RIME docs state PowerShell 7 x64 and native-only acceptance' {
        $english = Join-Path $repo 'windows/README.md'; $chinese = Join-Path $repo 'windows/README.zh-CN.md'
        Assert (Test-Path -LiteralPath $english -PathType Leaf) 'English Windows RIME guide missing'
        Assert (Test-Path -LiteralPath $chinese -PathType Leaf) 'Chinese Windows RIME guide missing'
        $englishText = [IO.File]::ReadAllText($english)
        $chineseText = [IO.File]::ReadAllText($chinese)
        $planText = [IO.File]::ReadAllText((Join-Path $repo 'docs/windows-rime-plan.md'))
        $architectureText = [IO.File]::ReadAllText((Join-Path $repo 'docs/architecture.md'))
        Assert ($englishText -match 'PowerShell 7 x64' -and $chineseText -match 'PowerShell 7 x64') 'Windows RIME guides omit PowerShell 7 x64 contract'
        Assert ($englishText.Contains('../docs/architecture.md#native-windows-acceptance')) 'English native acceptance link is not repo-relative'
        Assert ($planText -match 'PowerShell 7 x64' -and $planText -match 'unsupported') 'Windows implementation plan omits the current PowerShell contract'
        Assert ($architectureText -match '(?m)^## Native Windows acceptance$') 'architecture lacks native Windows acceptance boundary'
        Assert ($chineseText -match '原生') 'Chinese guide omits portable/native boundary'
    }
    Case 'public control scripts require 64-bit PowerShell before root discovery' {
        $switchScript = [IO.File]::ReadAllText((Join-Path $repo 'windows/scripts/rime-switch.ps1'))
        $userdataScript = [IO.File]::ReadAllText((Join-Path $repo 'windows/scripts/rime-userdata.ps1'))
        $switchAssertion = $switchScript.IndexOf('Assert-RimePowerShell7X64')
        $switchRootDiscovery = $switchScript.IndexOf('$root = Resolve-RimeSwitchRoot')
        $userdataAssertion = $userdataScript.IndexOf('Assert-RimePowerShell7X64')
        $userdataRootDiscovery = $userdataScript.IndexOf('$root = Resolve-RimeUserdataRoot')
        Assert ($switchAssertion -ge 0 -and $switchAssertion -lt $switchRootDiscovery) 'switch script discovers root before PowerShell x64 assertion'
        Assert ($userdataAssertion -ge 0 -and $userdataAssertion -lt $userdataRootDiscovery) 'userdata script discovers root before PowerShell x64 assertion'
    }
    Case 'directory tree validation rejects a reparse descendant before recursive cleanup' {
        $root = Join-Path $temp 'directory-tree-check'; $real = Join-Path $temp 'directory-tree-real'; $link = Join-Path $root 'linked-child'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory($real) | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null
            Throws { Assert-RimePlainDirectoryTree $root 'test directory tree' } 'reparse'
        } catch {
            if ($_.Exception.Message -match 'reparse') { throw }
            throw 'SKIP: directory-tree symbolic-link fixture unavailable' }
    }
    Case 'profile stage revalidates destination after parent changes to reparse point' {
        $source = Join-Path $temp 'final-stage-source'; $stage = Join-Path $temp 'final-stage-destination'; $external = Join-Path $temp 'final-stage-external'
        $sourcePath = Join-Path $source 'sub/current.yaml'; $stageParent = Join-Path $stage 'sub'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourcePath)) | Out-Null
        [IO.Directory]::CreateDirectory($external) | Out-Null
        [IO.File]::WriteAllText($sourcePath, 'new')
        [IO.File]::WriteAllText((Join-Path $external 'current.yaml'), 'old')
        $ensureFunction = (Get-Command Ensure-RimePlainDirectory -CommandType Function).ScriptBlock
        $script:stageReparseInjected = $false
        try {
            function Ensure-RimePlainDirectory([string]$Path) {
                $result = & $ensureFunction $Path
                if (-not $script:stageReparseInjected -and [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($stageParent)) {
                    Remove-Item -LiteralPath $stageParent -Recurse -Force
                    try { New-Item -ItemType SymbolicLink -Path $stageParent -Target $external -ErrorAction Stop | Out-Null }
                    catch { throw 'SKIP: symbolic-link fixture unavailable' }
                    $script:stageReparseInjected = $true
                }
                return $result
            }
            Throws { New-RimeProfileSourceStage $source @() $stage @('sub/current.yaml') } 'reparse'
        } finally {
            Set-Item -Path Function:Ensure-RimePlainDirectory -Value $ensureFunction
        }
        Assert $script:stageReparseInjected 'test did not create profile-stage reparse race'
        Assert ([IO.File]::ReadAllText((Join-Path $external 'current.yaml')) -eq 'old') 'profile staging followed reparse point after final validation'
    }
    Case 'managed copy revalidates destination after its parent changes to reparse point' {
        $source = Join-Path $temp 'final-copy-source'; $destination = Join-Path $temp 'final-copy-destination'; $external = Join-Path $temp 'final-copy-external'
        $sourcePath = Join-Path $source 'sub/current.yaml'; $destinationParent = Join-Path $destination 'sub'; $destinationPath = Join-Path $destinationParent 'current.yaml'; $manifest = Join-Path $destination 'managed-files.json'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourcePath)) | Out-Null
        [IO.Directory]::CreateDirectory($destinationParent) | Out-Null
        [IO.Directory]::CreateDirectory($external) | Out-Null
        [IO.File]::WriteAllText($sourcePath, 'old')
        Copy-RimeManagedFiles $source $destination @('sub/current.yaml') $manifest | Out-Null
        [IO.File]::WriteAllText($sourcePath, 'new')
        [IO.File]::WriteAllText((Join-Path $external 'current.yaml'), 'old')
        $ensureFunction = (Get-Command Ensure-RimePlainDirectory -CommandType Function).ScriptBlock
        $script:reparseInjected = $false
        try {
            function Ensure-RimePlainDirectory([string]$Path) {
                $result = & $ensureFunction $Path
                if (-not $script:reparseInjected -and [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($destinationParent)) {
                    Remove-Item -LiteralPath $destinationParent -Recurse -Force
                    try { New-Item -ItemType SymbolicLink -Path $destinationParent -Target $external -ErrorAction Stop | Out-Null }
                    catch { throw 'SKIP: symbolic-link fixture unavailable' }
                    $script:reparseInjected = $true
                }
                return $result
            }
            Throws { Copy-RimeManagedFiles $source $destination @('sub/current.yaml') $manifest } 'reparse'
        } finally {
            Set-Item -Path Function:Ensure-RimePlainDirectory -Value $ensureFunction
        }
        Assert $script:reparseInjected 'test did not create final-operation reparse race'
        Assert ([IO.File]::ReadAllText((Join-Path $external 'current.yaml')) -eq 'old') 'managed copy followed reparse point after final validation'
    }
    Case 'managed root discovery rejects unknown and reparse registry selectors' {
        $root = Join-Path $temp 'managed-root'; Ensure-RimeRootLayout $root 'S-test' | Out-Null
        $selector = Join-Path $root 'RimeConfig'
        $roots = Get-RimeManagedRootsFromSelector $selector
        Assert ($roots -contains $root) 'managed selector root not found'
        Throws { Get-RimeManagedRootsFromSelector (Join-Path $temp 'foreign/RimeConfig') } 'managed'
        $link = Join-Path $temp 'managed-root-link'
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $root -ErrorAction Stop | Out-Null
            Throws { Get-RimeManagedRootsFromSelector (Join-Path $link 'RimeConfig') } 'reparse'
        } catch {
            if ($_.Exception.Message -match 'reparse') { throw }
            throw 'SKIP: managed-root symbolic-link fixture unavailable' }
    }
} finally {
    if (Test-Path -LiteralPath $temp) {
        # .NET recursive delete aborts on a Junction in the tree with
        # "The parameter is incorrect"; remove reparse points (deepest first)
        # before deleting the remaining temporary directory.
        $reparsePoints = @(Get-ChildItem -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        foreach ($reparsePoint in ($reparsePoints | Sort-Object { $_.FullName.Length } -Descending)) {
            Remove-Item -LiteralPath $reparsePoint.FullName -Force -ErrorAction SilentlyContinue
        }
        [IO.Directory]::Delete($temp, $true)
    }
}
Write-Host "Tests: $script:passed passed, $script:failed failed, $script:skipped skipped"
if ($script:failed) { exit 1 }
