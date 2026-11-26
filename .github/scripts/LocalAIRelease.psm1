# -------------------------------------------------------
#                 LOCAL AI RELEASE TOOLS
# -------------------------------------------------------
#
# Functions behind ci\release-build.ps1, which the standard's release.yml runs: the release zip
# with its manifest, the check of that zip, the asset install.ps1 taken from it, and SHA256SUMS.
# The standard's own tools check VERSION, CHANGELOG.md and the tags, and write the release notes.
# CONTRIBUTING.md describes the release contract they keep, and tests\Release.Tests.ps1 tests them.
# They run in Windows PowerShell 5.1 with git on PATH.
# Every function takes its inputs as parameters, so importing the module runs nothing.

# Errors stop the module's functions whatever preference the importing session has.
$ErrorActionPreference = 'Stop'

# The release name: the zip <name>-X.Y.Z.zip holds the folder <name>-X.Y.Z.
$script:ReleaseName = 'local-ai-launcher'
# The manifest at the top of that folder, which the second git archive pass adds.
$script:ManifestName = 'local-ai-release.json'
# What .gitattributes marks export-ignore, folders with a trailing '/'. tests\Release.Tests.ps1 checks that the two agree.
$script:DevPaths = @('.github/', '.githooks/', 'ci/', 'tests/', '.editorconfig', '.gitattributes', '.gitignore', '.gitleaksignore', '.shellcheckrc',
    'PSScriptAnalyzerSettings.psd1', 'CONTRIBUTING.md')
# The extensions .gitattributes gives CRLF and those it marks binary. Every other file of a release has LF line ends only.
$script:CrlfExtensions = @('.ps1', '.psm1', '.psd1', '.cmd', '.bat')
$script:BinaryExtensions = @('.ico', '.lnk', '.gguf', '.safetensors')
# The bootstrap that installs a release, which every release also attaches on its own as the asset install.ps1.
$script:InstallScriptPath = 'src/install.ps1'
# Files every release holds, so an export-ignore line that reaches too far fails the check.
$script:RequiredFiles = @('local-ai.cmd', 'src/local-ai.ps1', 'src/LocalAI.psm1', $script:InstallScriptPath, 'config/defaults.psd1', 'README.md', 'LICENSE')
# The limits every installed launcher and install.ps1 apply to a release, in Test-LauncherRelease and Expand-LauncherArchive of src\LocalAI.psm1: the bytes of
# the zip, its entries, and the bytes of its files once extracted.
$script:ReleaseLimits = @{ ZipBytes = 64MB; Entries = 10000; ExtractedBytes = 256MB }

# Return $Path as a full path without a trailing '\', a relative one taken from the current location, which .NET calls do not follow in
# Windows PowerShell 5.1. Touches nothing.
function Resolve-ReleasePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    # A trailing '\' would escape the closing quote that 5.1 adds around an argument with a space.
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

# Return $Text for a message: at most $MaxLength characters, with CR, LF and tab written as \r, \n and \t. Pure.
function Format-ReleaseText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Text,
        [int]$MaxLength = 60
    )
    $shown = $Text.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    if ($shown.Length -gt $MaxLength) { $shown = $shown.Substring(0, $MaxLength - 3) + '...' }
    return $shown
}

# True when $Version is a release version X.Y.Z: three whole numbers without leading zeros, as Semantic Versioning writes them, each at
# most 2147483647, so that [version] reads it. Pure.
function Test-ReleaseVersionText {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$Version
    )
    if ($Version -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') { return $false }
    foreach ($part in $Version.Split('.')) {
        $number = 0
        if (-not [int]::TryParse($part, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $false }
    }
    return $true
}

# Return the lowercase hex SHA-256 of $Bytes. Pure.
function Get-ReleaseSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    } finally {
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

# Run git with $ArgumentList in the repository $RepositoryPath, without ever asking for credentials, and return its stdout lines. A
# non-zero exit code throws naming the command, the code and what git printed.
function Invoke-ReleaseGit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    if (-not (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Cannot find git on PATH.' }
    # Windows PowerShell 5.1 turns redirected stderr lines into error records, which 'Stop' would make terminating.
    $ErrorActionPreference = 'Continue'
    $output = New-Object System.Collections.Generic.List[string]
    $printed = New-Object System.Collections.Generic.List[string]
    $savedPrompt = $env:GIT_TERMINAL_PROMPT
    $savedInteractive = $env:GCM_INTERACTIVE
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        & git -C $RepositoryPath @ArgumentList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $printed.Add($_.Exception.Message) } else { $output.Add([string]$_) }
        }
        $code = $LASTEXITCODE
    } finally {
        $env:GIT_TERMINAL_PROMPT = $savedPrompt
        $env:GCM_INTERACTIVE = $savedInteractive
    }
    if ($code -ne 0) {
        throw "'git $($ArgumentList -join ' ')' in $RepositoryPath failed with exit code $code`: $((@($printed) + @($output)) -join ' ')"
    }
    return $output.ToArray()
}

# Return $Text as a JSON string literal in ASCII: quotes, backslashes, control characters and every character above 0x7E as escapes. Pure.
function ConvertTo-ReleaseJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Text
    )
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    foreach ($char in $Text.ToCharArray()) {
        $code = [int]$char
        if ($code -eq 0x22) {
            $null = $builder.Append('\"')
        } elseif ($code -eq 0x5C) {
            $null = $builder.Append('\\')
        } elseif ($code -lt 0x20 -or $code -gt 0x7E) {
            $null = $builder.Append(('\u{0:x4}' -f $code))
        } else {
            $null = $builder.Append($char)
        }
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

# Return the manifest local-ai-release.json of release $Version built from $Commit, whose $File maps each path in the release folder (with
# forward slashes) to the lowercase hex SHA-256 of its bytes: JSON indented by two spaces with the files in ordinal order, ASCII with \u
# escapes, LF line ends and a final LF, so the same input always gives the same bytes. Throws on a path or hash out of that form. Pure.
function ConvertTo-ReleaseManifest {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][System.Collections.IDictionary]$File
    )
    if (-not (Test-ReleaseVersionText -Version $Version)) { throw "'$Version' is no release version X.Y.Z." }
    if ($Commit -cnotmatch '\A[0-9a-f]{40}\z') { throw "'$Commit' is no full commit SHA of 40 lowercase hex digits." }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($key in $File.Keys) { $paths.Add([string]$key) }
    if ($paths.Count -eq 0) { throw 'A release manifest lists at least one file.' }
    $paths.Sort([StringComparer]::Ordinal)
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append("{`n")
    $null = $builder.Append("  `"schema`": 1,`n")
    $null = $builder.Append("  `"name`": $(ConvertTo-ReleaseJsonString -Text $script:ReleaseName),`n")
    $null = $builder.Append("  `"version`": $(ConvertTo-ReleaseJsonString -Text $Version),`n")
    $null = $builder.Append("  `"tag`": $(ConvertTo-ReleaseJsonString -Text "v$Version"),`n")
    $null = $builder.Append("  `"commit`": $(ConvertTo-ReleaseJsonString -Text $Commit),`n")
    $null = $builder.Append("  `"files`": {`n")
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $path = $paths[$i]
        $segments = $path.Split('/')
        if ($path.Contains('\') -or @($segments | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
            throw "'$path' is no path inside the release folder with forward slashes."
        }
        $hash = [string]$File[$path]
        if ($hash -cnotmatch '\A[0-9a-f]{64}\z') { throw "The SHA-256 of $path, '$hash', is not 64 lowercase hex digits." }
        $comma = if ($i -lt $paths.Count - 1) { ',' } else { '' }
        $null = $builder.Append("    $(ConvertTo-ReleaseJsonString -Text $path): $(ConvertTo-ReleaseJsonString -Text $hash)$comma`n")
    }
    $null = $builder.Append("  }`n")
    $null = $builder.Append("}`n")
    return $builder.ToString()
}

# Return every entry of the zip file $Path, in its order, as @{ Name; Bytes; Length }: Bytes holds the content, or $null for a folder
# entry, whose name ends with '/', and Length the size the zip states for it. Reads only.
function Read-ReleaseZip {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $entries = New-Object System.Collections.Generic.List[hashtable]
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $bytes = $null
            if (-not $entry.FullName.EndsWith('/', [StringComparison]::Ordinal)) {
                $memory = New-Object IO.MemoryStream
                try {
                    $stream = $entry.Open()
                    try {
                        $stream.CopyTo($memory)
                    } finally {
                        $stream.Dispose()
                    }
                    $bytes = $memory.ToArray()
                } finally {
                    $memory.Dispose()
                }
            }
            $entries.Add(@{ Name = $entry.FullName; Bytes = $bytes; Length = [long]$entry.Length })
        }
    } finally {
        $zip.Dispose()
    }
    return , $entries.ToArray()
}

# Build local-ai-launcher-$Version.zip in $OutputDirectory from $Commit of the git repository $RepositoryPath. git archive writes the
# folder local-ai-launcher-$Version/ with the export-ignore and eol attributes of that commit; a second pass adds the manifest of the
# first pass's files with --add-file. TZ is UTC meanwhile, so every entry carries the commit time in UTC and the same commit gives the
# same bytes with the same git. Returns @{ Path; Sha256; Version; Commit; Files }.
function New-ReleaseZip {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the release workflow and the tests, which offer no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if (-not (Test-ReleaseVersionText -Version $Version)) { throw "'$Version' is no release version X.Y.Z." }
    $root = Resolve-ReleasePath -Path $RepositoryPath
    $output = Resolve-ReleasePath -Path $OutputDirectory
    try {
        $resolved = @(Invoke-ReleaseGit -RepositoryPath $root -ArgumentList @('rev-parse', '--verify', '--quiet', "$Commit^{commit}"))
    } catch {
        throw "The repository $root holds no commit '$Commit': $($_.Exception.Message)"
    }
    $sha = if ($resolved.Count -eq 1) { $resolved[0].Trim() } else { '' }
    if ($sha -cnotmatch '\A[0-9a-f]{40}\z') { throw "git names no full commit SHA for '$Commit': '$($resolved -join ' ')'." }
    $prefix = "$script:ReleaseName-$Version/"
    $zipPath = Join-Path $output "$script:ReleaseName-$Version.zip"
    $work = Join-Path ([IO.Path]::GetTempPath()) ('local-ai-release-' + [guid]::NewGuid().ToString('N'))
    $first = Join-Path $work 'first.zip'
    $manifestPath = Join-Path $work $script:ManifestName
    $savedZone = $env:TZ
    try {
        $null = [IO.Directory]::CreateDirectory($work)
        $null = [IO.Directory]::CreateDirectory($output)
        # git writes each entry's time as the commit time in the local time zone, which TZ sets.
        $env:TZ = 'UTC'
        $null = Invoke-ReleaseGit -RepositoryPath $root -ArgumentList @('archive', '--format=zip', "--prefix=$prefix", '-o', $first, $sha)
        $files = New-Object 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([StringComparer]::Ordinal)
        foreach ($entry in (Read-ReleaseZip -Path $first)) {
            if (-not $entry.Name.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "git archive wrote $($entry.Name) outside $prefix." }
            if ($null -eq $entry.Bytes) { continue }
            $files[$entry.Name.Substring($prefix.Length)] = Get-ReleaseSha256 -Bytes $entry.Bytes
        }
        if ($files.ContainsKey($script:ManifestName)) {
            throw "$sha tracks $script:ManifestName at the top of the repository, where the release manifest goes."
        }
        [IO.File]::WriteAllText($manifestPath, (ConvertTo-ReleaseManifest -Version $Version -Commit $sha -File $files), [Text.Encoding]::ASCII)
        # --add-file puts the file at the last --prefix plus its name, with the commit time as for the other entries.
        $null = Invoke-ReleaseGit -RepositoryPath $root -ArgumentList @('archive', '--format=zip', "--prefix=$prefix", "--add-file=$manifestPath",
            '-o', $zipPath, $sha)
    } finally {
        $env:TZ = $savedZone
        foreach ($file in @($first, $manifestPath)) {
            if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
        }
        if ([IO.Directory]::Exists($work)) { [IO.Directory]::Delete($work) }
    }
    return [pscustomobject]@{
        Path    = $zipPath
        Sha256  = Get-ReleaseSha256 -Bytes ([IO.File]::ReadAllBytes($zipPath))
        Version = $Version
        Commit  = $sha
        Files   = $files.Count + 1
    }
}

# Check the release zip $Path of $Version built from $Commit against the release contract, and throw listing every breach: its name;
# every entry inside local-ai-launcher-$Version/, without '..', '\' or a second entry of one name, with no name that Windows changes or
# refuses, no file where another entry needs a folder, and the size the zip states for it; no export-ignored path; the files every release
# holds; CRLF line ends only in *.cmd, *.bat, *.ps1, *.psm1 and *.psd1, and no CR in any other file but binary ones; a manifest equal to the
# one ConvertTo-ReleaseManifest writes for the other files; VERSION holding $Version; and the limits of
# $script:ReleaseLimits. Reads only.
function Assert-ReleaseZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Commit
    )
    if (-not (Test-ReleaseVersionText -Version $Version)) { throw "'$Version' is no release version X.Y.Z." }
    if ($Commit -cnotmatch '\A[0-9a-f]{40}\z') { throw "'$Commit' is no full commit SHA of 40 lowercase hex digits." }
    $zipPath = Resolve-ReleasePath -Path $Path
    $prefix = "$script:ReleaseName-$Version/"
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $problems = New-Object System.Collections.Generic.List[string]
    $expectedName = "$script:ReleaseName-$Version.zip"
    if ([IO.Path]::GetFileName($zipPath) -cne $expectedName) { $problems.Add("The zip is named $([IO.Path]::GetFileName($zipPath)), not $expectedName.") }
    $zipBytes = (New-Object IO.FileInfo -ArgumentList $zipPath).Length
    if ($zipBytes -gt $script:ReleaseLimits.ZipBytes) {
        $problems.Add("The zip has $zipBytes bytes, more than the $($script:ReleaseLimits.ZipBytes) bytes an installed launcher downloads.")
    }
    $files = New-Object 'System.Collections.Generic.Dictionary[string,byte[]]' -ArgumentList ([StringComparer]::Ordinal)
    # As Expand-LauncherArchive in src\LocalAI.psm1 counts them: Windows extracts two names that differ only in case, a folder entry's
    # with or without its '/', into one, and no file may have the name of a folder that another entry needs.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $folders = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $fileNames = New-Object System.Collections.Generic.List[string]
    $count = 0
    $extracted = [long]0
    foreach ($entry in (Read-ReleaseZip -Path $zipPath)) {
        $count++
        # The sizes the zip states, which an installed launcher adds up and holds each entry to.
        $extracted += [long]$entry.Length
        $name = [string]$entry.Name
        $plain = $name.TrimEnd('/')
        if (-not $seen.Add($plain)) {
            $problems.Add("The zip holds $name twice, or in two spellings that differ only in case.")
            continue
        }
        $parts = $plain.Split('/')
        for ($i = 1; $i -lt $parts.Count; $i++) { $null = $folders.Add(($parts[0..($i - 1)] -join '/')) }
        if ($name.EndsWith('/')) { $null = $folders.Add($plain) } else { $fileNames.Add($plain) }
        if ($null -ne $entry.Bytes -and $entry.Bytes.Length -ne [long]$entry.Length) {
            $problems.Add("$name holds $($entry.Bytes.Length) bytes, but the zip states $($entry.Length) for it.")
        }
        if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal)) {
            $problems.Add("$name lies outside the folder $prefix.")
            continue
        }
        $relative = $name.Substring($prefix.Length)
        if ($relative.Length -eq 0) { continue }
        $segments = $relative.TrimEnd('/').Split('/')
        if ($relative.Contains('\') -or @($segments | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
            $problems.Add("$name is no plain path inside $prefix.")
            continue
        }
        # As Test-LauncherPathText in src\LocalAI.psm1 refuses them for every installed launcher.
        $odd = @($segments | Where-Object {
                $_ -match '[\x00-\x1f"*:<>?|]' -or $_.EndsWith('.') -or $_.EndsWith(' ') -or $_.Split('.')[0].Trim() -match '\A(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])\z'
            })
        if ($odd.Count -gt 0) {
            $problems.Add("$name holds a name that Windows changes or refuses: a device name such as NUL, a dot or a space at its end, or "" * : < > ? | or a control character.")
            continue
        }
        $dev = @($script:DevPaths | Where-Object {
                if ($_.EndsWith('/')) { $relative.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) } else { $relative -eq $_ }
            })
        if ($dev.Count -gt 0) {
            $problems.Add("$name is a development file, which .gitattributes marks export-ignore.")
            continue
        }
        if ($null -ne $entry.Bytes) { $files[$relative] = $entry.Bytes }
    }
    foreach ($fileName in $fileNames) {
        if ($folders.Contains($fileName)) { $problems.Add("The zip holds $fileName both as a file and as a folder.") }
    }
    if ($count -gt $script:ReleaseLimits.Entries) {
        $problems.Add("The zip holds $count entries, more than the $($script:ReleaseLimits.Entries) an installed launcher extracts.")
    }
    if ($extracted -gt $script:ReleaseLimits.ExtractedBytes) {
        $problems.Add("The zip holds $extracted bytes once extracted, more than the $($script:ReleaseLimits.ExtractedBytes) bytes an installed launcher extracts.")
    }
    foreach ($required in $script:RequiredFiles) {
        if (-not $files.ContainsKey($required)) { $problems.Add("The zip lacks $prefix$required, which every release holds.") }
    }
    foreach ($relative in $files.Keys) {
        $extension = [IO.Path]::GetExtension($relative)
        if ($script:BinaryExtensions -contains $extension) { continue }
        $text = $latin1.GetString($files[$relative])
        $pairs = [regex]::Matches($text, '\r\n').Count
        $bareLf = [regex]::Matches($text, '(?<!\r)\n').Count
        $bareCr = [regex]::Matches($text, '\r(?!\n)').Count
        if ($script:CrlfExtensions -contains $extension) {
            if ($bareLf + $bareCr -gt 0) {
                $problems.Add("$prefix$relative must end every line with CRLF, but has $bareLf LF and $bareCr CR without the other.")
            }
        } elseif ($pairs + $bareCr -gt 0) {
            $problems.Add("$prefix$relative must end its lines with LF only, but has $($pairs + $bareCr) CR.")
        }
    }
    if (-not $files.ContainsKey('VERSION')) {
        $problems.Add("The zip lacks $($prefix)VERSION.")
    } else {
        $held = $latin1.GetString($files['VERSION'])
        if ($held -cne "$Version`n") { $problems.Add("$($prefix)VERSION holds '$(Format-ReleaseText -Text $held)', not $Version and a line feed.") }
    }
    if (-not $files.ContainsKey($script:ManifestName)) {
        $problems.Add("The zip lacks the manifest $prefix$script:ManifestName.")
    } else {
        $hashes = New-Object 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([StringComparer]::Ordinal)
        foreach ($relative in $files.Keys) {
            if ($relative -cne $script:ManifestName) { $hashes[$relative] = Get-ReleaseSha256 -Bytes $files[$relative] }
        }
        $expected = ''
        try {
            $expected = ConvertTo-ReleaseManifest -Version $Version -Commit $Commit -File $hashes
        } catch {
            $problems.Add("No manifest can describe the zip's files: $($_.Exception.Message)")
        }
        $actual = $latin1.GetString($files[$script:ManifestName])
        if ($expected -and $actual -cne $expected) {
            $want = $expected.Split("`n")
            $have = $actual.Split("`n")
            $at = 0
            while ($at -lt $want.Count -and $at -lt $have.Count -and $want[$at] -ceq $have[$at]) { $at++ }
            $wanted = if ($at -lt $want.Count) { $want[$at] } else { '(end of file)' }
            $found = if ($at -lt $have.Count) { $have[$at] } else { '(end of file)' }
            $problems.Add(("$prefix$script:ManifestName does not match the zip's files: its line $($at + 1) reads " +
                "'$(Format-ReleaseText -Text $found -MaxLength 200)' where '$(Format-ReleaseText -Text $wanted -MaxLength 200)' belongs."))
        }
    }
    if ($problems.Count -gt 0) {
        throw ("The release zip $zipPath breaks the release contract in CONTRIBUTING.md:`n  " + ($problems -join "`n  "))
    }
    Write-Host "The release zip $zipPath holds $($files.Count) files in $prefix and keeps the release contract."
}

# Write the asset install.ps1 into the folder $OutputDirectory: the bytes of local-ai-launcher-$Version/src/install.ps1 in the release zip $ZipPath,
# so the asset is that file of the release, its CRLF line ends included. Throws when the zip lacks it. Returns the path it wrote.
function Save-ReleaseInstallScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if (-not (Test-ReleaseVersionText -Version $Version)) { throw "'$Version' is no release version X.Y.Z." }
    $zip = Resolve-ReleasePath -Path $ZipPath
    $name = "$script:ReleaseName-$Version/$script:InstallScriptPath"
    # Read-ReleaseZip returns its entries as one array, so foreach walks them, not a pipeline.
    $found = New-Object System.Collections.Generic.List[byte[]]
    foreach ($entry in (Read-ReleaseZip -Path $zip)) {
        if ($entry.Name -ceq $name -and $null -ne $entry.Bytes) { $found.Add([byte[]]$entry.Bytes) }
    }
    if ($found.Count -ne 1) { throw "The release zip $zip holds no $name, which the asset install.ps1 is." }
    $output = Resolve-ReleasePath -Path $OutputDirectory
    $null = [IO.Directory]::CreateDirectory($output)
    $path = Join-Path $output 'install.ps1'
    [IO.File]::WriteAllBytes($path, $found[0])
    return $path
}

# Write SHA256SUMS at $OutputPath for the asset files $Path: per file one line of its SHA-256 in lowercase hex, two spaces and its name,
# ending in LF, sorted by name in ordinal order, in ASCII through [IO.File]::WriteAllText. Throws on a name that is not plain ASCII without
# spaces, on two files of one name, and on SHA256SUMS itself.
function New-ReleaseChecksumFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the release workflow and the tests, which offer no -WhatIf.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $sums = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' -ArgumentList ([StringComparer]::Ordinal)
    foreach ($item in $Path) {
        $full = Resolve-ReleasePath -Path $item
        $name = [IO.Path]::GetFileName($full)
        if ($name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._+-]*\z') { throw "The asset name '$name' must be ASCII letters, digits, '.', '_', '+' and '-'." }
        if ($name -ceq 'SHA256SUMS') { throw 'SHA256SUMS cannot list itself.' }
        if ($sums.ContainsKey($name)) { throw "Two assets are named $name." }
        $sums[$name] = Get-ReleaseSha256 -Bytes ([IO.File]::ReadAllBytes($full))
    }
    $builder = New-Object Text.StringBuilder
    foreach ($name in $sums.Keys) { $null = $builder.Append("$($sums[$name])  $name`n") }
    [IO.File]::WriteAllText((Resolve-ReleasePath -Path $OutputPath), $builder.ToString(), [Text.Encoding]::ASCII)
}

# Build the release assets of $Commit for the repository standard's release-build, which runs ci\release-build.ps1 in the checkout
# $RepositoryPath and checks VERSION, CHANGELOG.md and the tags itself: assets\local-ai-launcher-$Version.zip, checked by
# Assert-ReleaseZip, its src/install.ps1 as assets\install.ps1 and assets\SHA256SUMS of both, and nothing else in
# $OutputDirectory. Throws when the zip does not hold the release $Version. Returns @{ Version; Commit; Zip; Sha256; InstallScript }.
function Invoke-ReleaseHookBuild {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $root = Resolve-ReleasePath -Path $RepositoryPath
    $assets = Join-Path (Resolve-ReleasePath -Path $OutputDirectory) 'assets'
    $zip = New-ReleaseZip -RepositoryPath $root -Commit $Commit -Version $Version -OutputDirectory $assets
    Assert-ReleaseZip -Path $zip.Path -Version $Version -Commit $zip.Commit
    $installScript = Save-ReleaseInstallScript -ZipPath $zip.Path -Version $Version -OutputDirectory $assets
    New-ReleaseChecksumFile -Path @($zip.Path, $installScript) -OutputPath (Join-Path $assets 'SHA256SUMS')
    Write-Host "Built $($zip.Path) from $($zip.Commit): $($zip.Files) files, SHA-256 $($zip.Sha256), and $installScript from it."
    return [pscustomobject]@{
        Version       = $Version
        Commit        = $zip.Commit
        Zip           = $zip.Path
        Sha256        = $zip.Sha256
        InstallScript = $installScript
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-ReleaseManifest'
    'New-ReleaseZip'
    'Assert-ReleaseZip'
    'Save-ReleaseInstallScript'
    'New-ReleaseChecksumFile'
    'Invoke-ReleaseHookBuild'
)
