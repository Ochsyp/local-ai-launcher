# -------------------------------------------------------
#                 LOCAL AI RELEASE TOOLS
# -------------------------------------------------------
#
# Functions behind .github\workflows\release.yml and the version check in ci.yml: the rules for
# VERSION and CHANGELOG.md, the release notes, the release zip with its manifest, the check of
# that zip, and SHA256SUMS. CONTRIBUTING.md describes the release contract they keep, and
# tests\Release.Tests.ps1 tests them. They run in Windows PowerShell 5.1 with git on PATH.
# Every function takes its inputs as parameters, so importing the module runs nothing.

# Errors stop the module's functions whatever preference the importing session has.
$ErrorActionPreference = 'Stop'

# The release name: the zip <name>-X.Y.Z.zip holds the folder <name>-X.Y.Z.
$script:ReleaseName = 'local-ai-launcher'
# The manifest at the top of that folder, which the second git archive pass adds.
$script:ManifestName = 'local-ai-release.json'
# The version a dry run builds when there is no VERSION file.
$script:DryRunVersion = '0.0.0'
# What .gitattributes marks export-ignore, folders with a trailing '/'. tests\Release.Tests.ps1 checks that the two agree.
$script:DevPaths = @('.github/', '.githooks/', 'tests/', '.editorconfig', '.gitattributes', '.gitignore', 'PSScriptAnalyzerSettings.psd1', 'CONTRIBUTING.md')
# The extensions .gitattributes gives CRLF and those it marks binary. Every other file of a release has LF line ends only.
$script:CrlfExtensions = @('.ps1', '.psm1', '.psd1', '.cmd', '.bat')
$script:BinaryExtensions = @('.ico', '.lnk', '.gguf', '.safetensors')
# Files every release holds, so an export-ignore line that reaches too far fails the check.
$script:RequiredFiles = @('local-ai.cmd', 'src/local-ai.ps1', 'src/LocalAI.psm1', 'config/defaults.psd1', 'README.md', 'LICENSE')

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

# Return -1, 0 or 1 as the release version $Version is lower than, equal to or greater than $Other, comparing X, Y and Z as numbers.
# Throws when either is no version X.Y.Z. Pure.
function Compare-ReleaseVersion {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Other
    )
    foreach ($text in @($Version, $Other)) {
        if (-not (Test-ReleaseVersionText -Version $text)) { throw "'$text' is no release version X.Y.Z." }
    }
    return [Math]::Sign(([version]$Version).CompareTo([version]$Other))
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

# Return the lines of the section of $Version in the CHANGELOG.md lines $Lines: its '## [$Version]' heading and the lines below it up to
# the next '## [' heading, without link reference lines such as '[1.2.0]: https://...' and without trailing blank lines. Nothing when no
# such heading exists. Pure.
function Get-ReleaseSection {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Version
    )
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -ceq "## [$Version]" -or $Lines[$i].StartsWith("## [$Version] ", [StringComparison]::Ordinal)) {
            $start = $i
            break
        }
    }
    if ($start -lt 0) { return }
    $section = New-Object System.Collections.Generic.List[string]
    $section.Add($Lines[$start])
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].StartsWith('## [', [StringComparison]::Ordinal)) { break }
        if ($Lines[$i] -cmatch '\A {0,3}\[[^\]]+\]:') { continue }
        $section.Add($Lines[$i])
    }
    while ($section.Count -gt 1 -and $section[$section.Count - 1].Trim().Length -eq 0) { $section.RemoveAt($section.Count - 1) }
    return , $section.ToArray()
}

# Return the lines of the CHANGELOG.md text $Text that are not blank between '## [Unreleased]' and the next '## ' heading, without trailing
# spaces and without link reference lines: the changes that no release names yet. Nothing when that section is empty or missing. Pure.
function Get-ReleaseUnreleasedLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $inside = $false
    foreach ($raw in ($Text -split '\r?\n')) {
        $line = $raw.TrimEnd()
        if ($line.StartsWith('## ', [StringComparison]::Ordinal)) {
            if ($inside) { return }
            $inside = $line -ceq '## [Unreleased]'
        } elseif ($inside -and $line.Length -gt 0 -and $line -cnotmatch '\A {0,3}\[[^\]]+\]:') {
            $line
        }
    }
}

# Return one message per release rule that the CHANGELOG.md text $Text breaks, nothing when all hold. '## [Unreleased]' is the first '## '
# heading and comes once, and an '[Unreleased]: ' link exists. With $Version, the first version heading reads '## [$Version] - YYYY-MM-DD'
# with a real date, comes once and lists changes, '[Unreleased]: ' compares v$Version with HEAD, and '[$Version]: ' leads to the release
# v$Version or compares an earlier version with it. Without $Version, as when there is no VERSION file, no version heading may exist. Pure.
function Get-ReleaseChangelogProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Version
    )
    # Markdown ignores spaces at a line's end, and .editorconfig keeps them in *.md.
    $lines = @($Text -split '\r?\n' | ForEach-Object { $_.TrimEnd() })
    $problems = New-Object System.Collections.Generic.List[string]
    $headings = @($lines | Where-Object { $_.StartsWith('## ', [StringComparison]::Ordinal) })
    if ($headings.Count -eq 0) {
        $problems.Add("CHANGELOG.md has no '## [Unreleased]' heading.")
    } elseif ($headings[0] -cne '## [Unreleased]') {
        $problems.Add("The first '## ' heading of CHANGELOG.md must be '## [Unreleased]', but it is '$($headings[0])'.")
    }
    $unreleased = @($headings | Where-Object { $_ -ceq '## [Unreleased]' })
    if ($unreleased.Count -gt 1) { $problems.Add("CHANGELOG.md has $($unreleased.Count) '## [Unreleased]' headings; keep one.") }
    $versionHeadings = @($headings | Where-Object { $_.StartsWith('## [', [StringComparison]::Ordinal) -and $_ -cne '## [Unreleased]' })
    $unreleasedLinks = @($lines | Where-Object { $_.StartsWith('[Unreleased]:', [StringComparison]::Ordinal) })
    if ($unreleasedLinks.Count -eq 0) { $problems.Add("CHANGELOG.md has no '[Unreleased]: ' link line.") }

    if (-not $Version) {
        if ($versionHeadings.Count -gt 0) {
            $problems.Add(("There is no VERSION file, but CHANGELOG.md has the version heading '$($versionHeadings[0])'. Add VERSION with " +
                "that version, or move the entries back under '## [Unreleased]'."))
        }
        return $problems.ToArray()
    }

    $escaped = [regex]::Escape($Version)
    if ($versionHeadings.Count -eq 0) {
        $problems.Add(("VERSION names $Version, but CHANGELOG.md has no version heading. Rename '## [Unreleased]' to " +
            "'## [$Version] - YYYY-MM-DD' and add an empty '## [Unreleased]' above it."))
    } else {
        $first = $versionHeadings[0]
        $parts = [regex]::Match($first, '\A## \[([^\]]*)\] - ([0-9]{4}-[0-9]{2}-[0-9]{2})\z')
        if (-not $parts.Success) {
            $problems.Add("The first version heading of CHANGELOG.md must read '## [$Version] - YYYY-MM-DD', but it reads '$first'.")
        } else {
            if ($parts.Groups[1].Value -cne $Version) {
                $problems.Add("The first version heading of CHANGELOG.md names $($parts.Groups[1].Value), but VERSION names $Version.")
            }
            $date = [DateTime]::MinValue
            if (-not [DateTime]::TryParseExact($parts.Groups[2].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$date)) {
                $problems.Add("The date in '$first' is no real date YYYY-MM-DD.")
            }
        }
    }
    $own = @($versionHeadings | Where-Object { $_ -ceq "## [$Version]" -or $_.StartsWith("## [$Version] ", [StringComparison]::Ordinal) })
    if ($own.Count -gt 1) { $problems.Add("CHANGELOG.md has $($own.Count) headings for $Version; keep one.") }
    $section = Get-ReleaseSection -Lines $lines -Version $Version
    if ($section -and @($section | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count -eq 0) {
        $problems.Add("The section '$($section[0])' of CHANGELOG.md lists no changes.")
    }
    foreach ($link in $unreleasedLinks) {
        if ($link -cnotmatch "\A\[Unreleased\]: https://\S+/compare/v$escaped\.\.\.HEAD\z") {
            $problems.Add(("The link '$link' must compare v$Version with HEAD, as " +
                "'[Unreleased]: https://github.com/OWNER/REPO/compare/v$Version...HEAD' does."))
        }
    }
    $versionLinks = @($lines | Where-Object { $_.StartsWith("[$Version]:", [StringComparison]::Ordinal) })
    if ($versionLinks.Count -eq 0) {
        $problems.Add(("CHANGELOG.md has no '[$Version]: ' link line. Add '[$Version]: https://github.com/OWNER/REPO/releases/tag/v$Version', " +
            "or after the first release '[$Version]: https://github.com/OWNER/REPO/compare/vPREVIOUS...v$Version'."))
    }
    foreach ($link in $versionLinks) {
        if ($link -cnotmatch "\A\[$escaped\]: https://\S+/(releases/tag/v$escaped|compare/v[0-9]+\.[0-9]+\.[0-9]+\.\.\.v$escaped)\z") {
            $problems.Add("The link '$link' must lead to the release v$Version, or compare an earlier version with it.")
        }
    }
    return $problems.ToArray()
}

# Return the version that VERSION in the checkout $RepositoryPath names, or $null when there is no VERSION, as before the first release,
# once VERSION holds one line X.Y.Z and a line feed and CHANGELOG.md keeps the rules of Get-ReleaseChangelogProblem. Throws listing what
# breaks them. Reads only.
function Get-ReleaseVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath
    )
    $root = Resolve-ReleasePath -Path $RepositoryPath
    $problems = New-Object System.Collections.Generic.List[string]
    $version = $null
    $checkChangelog = $true
    $versionPath = Join-Path $root 'VERSION'
    if ([IO.Directory]::Exists($versionPath)) {
        $problems.Add('VERSION is a folder; it must be a file that holds one line X.Y.Z and a line feed.')
        $checkChangelog = $false
    } elseif ([IO.File]::Exists($versionPath)) {
        # Latin-1 maps each byte to one character, so a BOM or a CR shows in the text.
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($versionPath))
        $line = [regex]::Match($text, '\A([^\r\n]*)\n\z')
        if ($line.Success -and (Test-ReleaseVersionText -Version $line.Groups[1].Value)) {
            $version = $line.Groups[1].Value
        } else {
            $problems.Add(("VERSION must hold one line X.Y.Z and a line feed, three whole numbers without leading zeros such as 1.2.0, but " +
                "it holds '$(Format-ReleaseText -Text $text)'."))
            # The CHANGELOG rules depend on the version, so they wait until VERSION is fixed.
            $checkChangelog = $false
        }
    }
    if ($checkChangelog) {
        $changelogPath = Join-Path $root 'CHANGELOG.md'
        if (-not [IO.File]::Exists($changelogPath)) {
            $problems.Add('CHANGELOG.md is missing.')
        } else {
            $changelog = $null
            try {
                $changelog = [IO.File]::ReadAllText($changelogPath, (New-Object Text.UTF8Encoding $false, $true))
            } catch {
                $problems.Add("CHANGELOG.md is not UTF-8 text: $($_.Exception.Message)")
            }
            if ($null -ne $changelog) {
                foreach ($problem in @(Get-ReleaseChangelogProblem -Text $changelog -Version $version)) { $problems.Add($problem) }
            }
        }
    }
    if ($problems.Count -gt 0) {
        throw ("VERSION and CHANGELOG.md in $root break the release rules in CONTRIBUTING.md:`n  " + ($problems -join "`n  "))
    }
    return $version
}

# Return the release notes of $Version from the CHANGELOG.md text $Text: the section from '## [$Version] - YYYY-MM-DD' up to the next
# '## [' heading, without link reference lines, with LF line ends and one final LF. Throws when there is no such section or it lists no
# changes. Pure.
function Get-ReleaseNotes {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Release notes are one text, which gh release create takes as its notes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Version
    )
    $section = Get-ReleaseSection -Lines @($Text -split '\r?\n') -Version $Version
    if (-not $section) { throw "CHANGELOG.md has no section '## [$Version] - YYYY-MM-DD'." }
    if (@($section | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count -eq 0) {
        throw "The section '$($section[0])' of CHANGELOG.md lists no changes."
    }
    return ($section -join "`n") + "`n"
}

# Write the release notes of $Version from CHANGELOG.md in the checkout $RepositoryPath (Get-ReleaseNotes) to the file $Path, as UTF-8
# without BOM, for gh release create --notes-file. Creates the file's folder.
function New-ReleaseNotesFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the release workflow and the tests, which offer no -WhatIf.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Path
    )
    $changelogPath = Join-Path (Resolve-ReleasePath -Path $RepositoryPath) 'CHANGELOG.md'
    $notes = Get-ReleaseNotes -Text ([IO.File]::ReadAllText($changelogPath, (New-Object Text.UTF8Encoding $false, $true))) -Version $Version
    $target = Resolve-ReleasePath -Path $Path
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::WriteAllText($target, $notes, (New-Object Text.UTF8Encoding $false))
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

# Return every entry of the zip file $Path, in its order, as @{ Name; Bytes }: Bytes holds the content, or $null for a folder entry,
# whose name ends with '/'. Reads only.
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
            $entries.Add(@{ Name = $entry.FullName; Bytes = $bytes })
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
# every entry inside local-ai-launcher-$Version/, without '..', '\' or a second entry of one name; no export-ignored path; the files every
# release holds; CRLF line ends only in *.cmd, *.bat, *.ps1, *.psm1 and *.psd1, and no CR in any other file but binary ones; a manifest
# equal to the one ConvertTo-ReleaseManifest writes for the other files; VERSION holding $Version, or with -NoVersionFile none. Reads only.
function Assert-ReleaseZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Commit,
        [switch]$NoVersionFile
    )
    if (-not (Test-ReleaseVersionText -Version $Version)) { throw "'$Version' is no release version X.Y.Z." }
    if ($Commit -cnotmatch '\A[0-9a-f]{40}\z') { throw "'$Commit' is no full commit SHA of 40 lowercase hex digits." }
    $zipPath = Resolve-ReleasePath -Path $Path
    $prefix = "$script:ReleaseName-$Version/"
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $problems = New-Object System.Collections.Generic.List[string]
    $expectedName = "$script:ReleaseName-$Version.zip"
    if ([IO.Path]::GetFileName($zipPath) -cne $expectedName) { $problems.Add("The zip is named $([IO.Path]::GetFileName($zipPath)), not $expectedName.") }
    $files = New-Object 'System.Collections.Generic.Dictionary[string,byte[]]' -ArgumentList ([StringComparer]::Ordinal)
    # Windows extracts two names that differ only in case into one file.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in (Read-ReleaseZip -Path $zipPath)) {
        $name = [string]$entry.Name
        if (-not $seen.Add($name)) {
            $problems.Add("The zip holds $name twice, or in two spellings that differ only in case.")
            continue
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
        $dev = @($script:DevPaths | Where-Object {
                if ($_.EndsWith('/')) { $relative.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) } else { $relative -eq $_ }
            })
        if ($dev.Count -gt 0) {
            $problems.Add("$name is a development file, which .gitattributes marks export-ignore.")
            continue
        }
        if ($null -ne $entry.Bytes) { $files[$relative] = $entry.Bytes }
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
    if ($NoVersionFile) {
        if ($files.ContainsKey('VERSION')) { $problems.Add("The zip holds $($prefix)VERSION, but its commit has no VERSION file.") }
    } elseif (-not $files.ContainsKey('VERSION')) {
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

# Throw when the git remote $Remote of the repository $RepositoryPath has the tag $Tag, as once that version is released. git ls-remote
# reads the remote's tags without fetching anything.
function Assert-ReleaseTagAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Tag,
        [string]$Remote = 'origin'
    )
    $root = Resolve-ReleasePath -Path $RepositoryPath
    $lines = @(Invoke-ReleaseGit -RepositoryPath $root -ArgumentList @('ls-remote', '--tags', $Remote, "refs/tags/$Tag"))
    $pattern = '\A[0-9a-f]{40,64}\trefs/tags/' + [regex]::Escape($Tag) + '(\^\{\})?\z'
    if (@($lines | Where-Object { $_ -cmatch $pattern }).Count -gt 0) {
        throw "Tag $Tag already exists on $Remote, so that version is released. Raise VERSION and the CHANGELOG heading to a new version."
    }
}

# Throw unless the release version $Version is greater than the version of every tag vX.Y.Z on the git remote $Remote of the repository
# $RepositoryPath, so that a release never goes below a published one. Other tags do not count. git ls-remote fetches nothing.
function Assert-ReleaseVersionNewest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Version,
        [string]$Remote = 'origin'
    )
    if (-not (Test-ReleaseVersionText -Version $Version)) { throw "'$Version' is no release version X.Y.Z." }
    $root = Resolve-ReleasePath -Path $RepositoryPath
    $released = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Invoke-ReleaseGit -RepositoryPath $root -ArgumentList @('ls-remote', '--tags', $Remote, 'refs/tags/v*'))) {
        # An annotated tag comes twice, the second time with '^{}' for the commit it points to.
        $tag = [regex]::Match($line, '\A[0-9a-f]{40,64}\trefs/tags/v([^\^]+)(\^\{\})?\z')
        if ($tag.Success -and (Test-ReleaseVersionText -Version $tag.Groups[1].Value)) { $released.Add($tag.Groups[1].Value) }
    }
    if ($released.Contains($Version)) {
        throw "Tag v$Version already exists on $Remote, so that version is released. Raise VERSION and the CHANGELOG heading to a new version."
    }
    $highest = $null
    foreach ($other in $released) {
        if ($null -eq $highest -or (Compare-ReleaseVersion -Version $other -Other $highest) -gt 0) { $highest = $other }
    }
    if ($null -eq $highest) {
        Write-Host "$Remote has no release tag yet, so v$Version is the first release."
    } elseif ((Compare-ReleaseVersion -Version $Version -Other $highest) -lt 0) {
        throw ("VERSION names $Version, but tag v$highest on $Remote is a higher version. A release must raise VERSION and the CHANGELOG " +
            'heading above every released version.')
    } else {
        Write-Host "v$Version is above v$highest, the highest release tag on $Remote."
    }
}

# Return the version that VERSION holds at the commit $Revision of the repository $RepositoryPath, or $null when that commit has no VERSION.
# Throws when the commit is missing, as in a checkout without fetch-depth 2, or its VERSION holds no version X.Y.Z. Reads only.
function Get-ReleaseVersionAt {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Revision
    )
    try {
        $commit = @(Invoke-ReleaseGit -RepositoryPath $RepositoryPath -ArgumentList @('rev-parse', '--verify', '--quiet', "$Revision^{commit}"))[0]
    } catch {
        throw ("Cannot find the commit $Revision in $RepositoryPath; a pull request's version check needs the checkout's fetch-depth at 2 " +
            "or more. $($_.Exception.Message)")
    }
    $listed = @(Invoke-ReleaseGit -RepositoryPath $RepositoryPath -ArgumentList @('ls-tree', '--name-only', $commit, '--', 'VERSION'))
    if ($listed -cnotcontains 'VERSION') { return $null }
    $text = (@(Invoke-ReleaseGit -RepositoryPath $RepositoryPath -ArgumentList @('show', "$($commit):VERSION")) -join "`n").Trim()
    if (-not (Test-ReleaseVersionText -Version $text)) { throw "VERSION at $Revision holds '$(Format-ReleaseText -Text $text)', which is no version X.Y.Z." }
    return $text
}

# On a pull request: when VERSION in the checkout $RepositoryPath differs from VERSION at $BaseRevision, the base branch, throw unless tag
# v<VERSION> is missing on $Remote and, when the base has a VERSION, VERSION is greater than it. Nothing to check when VERSION is unchanged.
function Assert-ReleaseVersionBump {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$BaseRevision,
        [string]$Remote = 'origin'
    )
    $root = Resolve-ReleasePath -Path $RepositoryPath
    $version = [string](Get-ReleaseVersion -RepositoryPath $root)
    $base = [string](Get-ReleaseVersionAt -RepositoryPath $root -Revision $BaseRevision)
    if ($version -ceq $base) {
        Write-Host "VERSION is the same as at $BaseRevision, so no new version needs checking."
        return
    }
    # Without VERSION, Get-ReleaseVersion has checked that CHANGELOG.md names no version either.
    if (-not $version) {
        Write-Host "This change removes VERSION $base."
        return
    }
    Assert-ReleaseTagAbsent -RepositoryPath $root -Tag "v$version" -Remote $Remote
    if ($base -and (Compare-ReleaseVersion -Version $version -Other $base) -le 0) {
        throw "VERSION goes from $base to $version, but a release must raise it."
    }
    $from = if ($base) { "from $base " } else { '' }
    Write-Host "VERSION goes $($from)to $version, and tag v$version does not exist yet."
}

# The version check of ci.yml on the checkout $RepositoryPath: Get-ReleaseVersion, with a notice when there is no VERSION, and with
# -PullRequest also Assert-ReleaseVersionBump against HEAD^1, the base branch side of the pull request's merge commit.
function Invoke-ReleaseVersionCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [switch]$PullRequest,
        [string]$Remote = 'origin'
    )
    $version = Get-ReleaseVersion -RepositoryPath $RepositoryPath
    if ($version) {
        Write-Host "VERSION names $version, and CHANGELOG.md has its section and links."
    } else {
        Write-Host '::notice::There is no VERSION file, so no release is prepared. A release pull request adds it; see CONTRIBUTING.md.'
    }
    if ($PullRequest) { Assert-ReleaseVersionBump -RepositoryPath $RepositoryPath -BaseRevision 'HEAD^1' -Remote $Remote }
}

# Build the release of $Commit in the checkout $RepositoryPath into the new or empty folder $OutputDirectory: check VERSION and CHANGELOG.md,
# require X.Y.Z above each tag on $Remote and an empty '## [Unreleased]', write notes.md, build and check assets\local-ai-launcher-X.Y.Z.zip
# and write assets\SHA256SUMS. -DryRun, for pull requests, skips those two requirements, builds the version 0.0.0 without notes when there
# is no VERSION, and builds the zip again into again\ to show the same bytes. Returns @{ Version; Tag; Commit; Zip; Sha256; Notes; DryRun }.
function Invoke-ReleaseBuild {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Remote = 'origin',
        [switch]$DryRun
    )
    $root = Resolve-ReleasePath -Path $RepositoryPath
    $output = Resolve-ReleasePath -Path $OutputDirectory
    if ([IO.File]::Exists($output)) { throw "The output folder $output is a file." }
    if ([IO.Directory]::Exists($output) -and @([IO.Directory]::GetFileSystemEntries($output)).Count -gt 0) {
        throw "The output folder $output is not empty. Choose a new or empty folder."
    }
    $version = Get-ReleaseVersion -RepositoryPath $root
    $synthetic = $false
    if (-not $version) {
        if (-not $DryRun) { throw 'There is no VERSION file, so there is no release to build. A release pull request adds it; see CONTRIBUTING.md.' }
        $version = $script:DryRunVersion
        $synthetic = $true
        Write-Host "::notice::There is no VERSION file, so this dry run builds the version $version."
    }
    if (-not $DryRun) {
        # A release pull request can be merged with a failed version check, so the build compares the released versions itself.
        Assert-ReleaseVersionNewest -RepositoryPath $root -Version $version -Remote $Remote
        # The build ships every change on main, so a change still listed under [Unreleased] would ship without a line in the notes.
        $changelog = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'), (New-Object Text.UTF8Encoding $false, $true))
        $waiting = @(Get-ReleaseUnreleasedLine -Text $changelog)
        if ($waiting.Count -gt 0) {
            throw ("CHANGELOG.md lists changes under '## [Unreleased]', which v$version would ship while its notes leave them out. Move them " +
                "into the section of $version, as CONTRIBUTING.md describes for a fix of a draft:`n  " + ($waiting -join "`n  "))
        }
    }
    $notes = $null
    if (-not $synthetic) {
        $notes = Join-Path $output 'notes.md'
        New-ReleaseNotesFile -RepositoryPath $root -Version $version -Path $notes
    }
    $assets = Join-Path $output 'assets'
    $zip = New-ReleaseZip -RepositoryPath $root -Commit $Commit -Version $version -OutputDirectory $assets
    Assert-ReleaseZip -Path $zip.Path -Version $version -Commit $zip.Commit -NoVersionFile:$synthetic
    if ($DryRun) {
        $again = New-ReleaseZip -RepositoryPath $root -Commit $Commit -Version $version -OutputDirectory (Join-Path $output 'again')
        if ($again.Sha256 -cne $zip.Sha256) { throw "Two builds of $($zip.Commit) differ: SHA-256 $($zip.Sha256) and $($again.Sha256)." }
    }
    New-ReleaseChecksumFile -Path $zip.Path -OutputPath (Join-Path $assets 'SHA256SUMS')
    $git = @(Invoke-ReleaseGit -RepositoryPath $root -ArgumentList @('--version')) -join ' '
    Write-Host "Built $($zip.Path) from $($zip.Commit) with $git`: $($zip.Files) files, SHA-256 $($zip.Sha256)."
    return [pscustomobject]@{
        Version = $version
        Tag     = "v$version"
        Commit  = $zip.Commit
        Zip     = $zip.Path
        Sha256  = $zip.Sha256
        Notes   = $notes
        DryRun  = [bool]$DryRun
    }
}

Export-ModuleMember -Function @(
    'Compare-ReleaseVersion'
    'Get-ReleaseChangelogProblem'
    'Get-ReleaseUnreleasedLine'
    'Get-ReleaseVersion'
    'Get-ReleaseNotes'
    'New-ReleaseNotesFile'
    'ConvertTo-ReleaseManifest'
    'New-ReleaseZip'
    'Assert-ReleaseZip'
    'New-ReleaseChecksumFile'
    'Assert-ReleaseTagAbsent'
    'Assert-ReleaseVersionNewest'
    'Assert-ReleaseVersionBump'
    'Invoke-ReleaseVersionCheck'
    'Invoke-ReleaseBuild'
)
