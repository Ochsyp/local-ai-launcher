# -------------------------------------------------------
#                 LOCAL AI RELEASE TESTS
# -------------------------------------------------------
#
# Pester 6 tests for .github\scripts\LocalAIRelease.psm1, which release.yml and ci.yml run: the
# rules for VERSION and CHANGELOG.md, the release notes, the manifest and SHA256SUMS formats, the
# asset install.ps1, full builds in git repositories made in TestDrive:, and the export-ignore
# rules of this repository's .gitattributes. git must be on PATH; every remote is a folder in
# TestDrive:.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\.github\scripts\LocalAIRelease.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $repoRoot = Split-Path $PSScriptRoot -Parent
    # Latin-1 maps each byte to one character, so test texts are exact bytes, CR and LF included.
    $latin1 = [Text.Encoding]::GetEncoding(28591)

    # Run git with $Arguments, a test identity and no signing, and return its output lines; a non-zero exit code throws.
    function Invoke-TestGit([string[]]$Arguments) {
        $ErrorActionPreference = 'Continue'
        $config = @('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'init.defaultBranch=main', '-c', 'core.safecrlf=false',
            '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false')
        $output = @(& git @config @Arguments 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
        return $output
    }

    # Write $Text to the file $Path byte for byte, creating its folder.
    function Write-ReleaseTestFile([string]$Path, [string]$Text) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
        [IO.File]::WriteAllBytes($Path, $latin1.GetBytes($Text))
    }

    # Return the lowercase hex SHA-256 of the bytes of $Text.
    function Get-TestHash([string]$Text) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($latin1.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    }

    # Return a CHANGELOG.md text with LF line ends and an empty [Unreleased] section above the release $Version of 2026-05-04, and above
    # it the release $Previous of 2026-04-01 when that is given, with the links Keep a Changelog writes. Without $Version, the entries sit
    # under [Unreleased], as before the first release.
    function Get-TestChangelog([string]$Version = '1.2.3', [string]$Previous = '') {
        $url = 'https://github.com/example/launcher'
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in '# Changelog', '', 'All notable changes to this project are listed here.', '', '## [Unreleased]', '') { $lines.Add($line) }
        if (-not $Version) {
            foreach ($line in '### Added', '', '- A release check.', '', "[Unreleased]: $url/commits/main") { $lines.Add($line) }
            return ($lines -join "`n") + "`n"
        }
        foreach ($line in "## [$Version] - 2026-05-04", '', '### Added', '', '- A release check.', '', '### Fixed', '', '- A typo.', '') { $lines.Add($line) }
        if ($Previous) {
            foreach ($line in "## [$Previous] - 2026-04-01", '', '### Added', '', '- The first release.', '') { $lines.Add($line) }
        }
        $lines.Add("[Unreleased]: $url/compare/v$Version...HEAD")
        if ($Previous) {
            $lines.Add("[$Version]: $url/compare/v$Previous...v$Version")
            $lines.Add("[$Previous]: $url/releases/tag/v$Previous")
        } else {
            $lines.Add("[$Version]: $url/releases/tag/v$Version")
        }
        return ($lines -join "`n") + "`n"
    }

    # Commit everything in the repository $Path as of 2026-01-02T03:04:05Z, and return the commit's SHA.
    function Add-TestCommit([string]$Path, [string]$Message = 'change') {
        $null = Invoke-TestGit @('-C', $Path, 'add', '-A')
        $saved = @($env:GIT_AUTHOR_DATE, $env:GIT_COMMITTER_DATE)
        try {
            $env:GIT_AUTHOR_DATE = '2026-01-02T03:04:05Z'
            $env:GIT_COMMITTER_DATE = '2026-01-02T03:04:05Z'
            $null = Invoke-TestGit @('-C', $Path, 'commit', '-q', '-m', $Message)
        } finally {
            $env:GIT_AUTHOR_DATE = $saved[0]
            $env:GIT_COMMITTER_DATE = $saved[1]
        }
        return @(Invoke-TestGit @('-C', $Path, 'rev-parse', 'HEAD'))[-1]
    }

    # Create a git repository at $Path that holds this repository's .gitattributes and the files $Files (path -> text, written byte for
    # byte), commit them, and return the commit's SHA.
    function Initialize-TestRepository([string]$Path, [hashtable]$Files) {
        $null = New-Item -ItemType Directory -Force -Path $Path
        $null = Invoke-TestGit @('init', '-q', $Path)
        Copy-Item -LiteralPath (Join-Path $repoRoot '.gitattributes') -Destination (Join-Path $Path '.gitattributes')
        foreach ($name in $Files.Keys) { Write-ReleaseTestFile (Join-Path $Path $name) $Files[$name] }
        return Add-TestCommit -Path $Path -Message 'first'
    }

    # Return the entries of the zip $Path as an ordered table: name -> @{ Text (the bytes as Latin-1, $null for a folder); Time }.
    function Read-TestZip([string]$Path) {
        $table = [ordered]@{}
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $zip.Entries) {
                $text = $null
                if (-not $entry.FullName.EndsWith('/')) {
                    $reader = New-Object IO.StreamReader -ArgumentList $entry.Open(), $latin1, $false
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
                $table[$entry.FullName] = @{ Text = $text; Time = $entry.LastWriteTime.DateTime }
            }
        } finally {
            $zip.Dispose()
        }
        return $table
    }

    # A small launcher: its runtime files, with LF or CRLF in the working tree, and development files that export-ignore leaves out.
    $runtimeFiles = @{
        'local-ai.cmd'                     = "@echo off`nexit /b 0`n"
        'src/local-ai.ps1'                 = "param()`r`nImport-Module LocalAI`r`n"
        'src/LocalAI.psm1'                 = "function Get-Test { 1 }`n"
        'src/install.ps1'                  = "& { 'install' }`n"
        'src/image_gate.py'                = "print('gate')`r`n"
        'config/defaults.psd1'             = "@{ }`n"
        'config/local-chat.Modelfile'      = "FROM test`nPARAMETER num_ctx 32768`n"
        'config/files-server/package.json' = "{`r`n  `"private`": true`r`n}`r`n"
        'README.md'                        = "# Test`r`n`r`nRead me.`r`n"
        'LICENSE'                          = "MIT License`n"
        'SECURITY.md'                      = "# Security`n"
    }
    $devFiles = @{
        'CONTRIBUTING.md'               = "# Contributing`n"
        '.editorconfig'                 = "root = true`n"
        '.gitignore'                    = "*.log`n"
        'PSScriptAnalyzerSettings.psd1' = "@{ }`n"
        '.github/workflows/ci.yml'      = "name: ci`n"
        '.github/scripts/Tool.psm1'     = "function Get-Tool { }`n"
        '.githooks/pre-commit'          = "#!/bin/sh`n"
        'tests/Tool.Tests.ps1'          = "Describe 'Tool' { }`n"
    }
    # How the zip holds each runtime file: CRLF in the cmd and PowerShell files, LF in the others, whatever the working tree held.
    $zippedFiles = @{
        'local-ai.cmd'                     = "@echo off`r`nexit /b 0`r`n"
        'src/local-ai.ps1'                 = "param()`r`nImport-Module LocalAI`r`n"
        'src/LocalAI.psm1'                 = "function Get-Test { 1 }`r`n"
        'src/install.ps1'                  = "& { 'install' }`r`n"
        'src/image_gate.py'                = "print('gate')`n"
        'config/defaults.psd1'             = "@{ }`r`n"
        'config/local-chat.Modelfile'      = "FROM test`nPARAMETER num_ctx 32768`n"
        'config/files-server/package.json' = "{`n  `"private`": true`n}`n"
        'README.md'                        = "# Test`n`nRead me.`n"
        'LICENSE'                          = "MIT License`n"
        'SECURITY.md'                      = "# Security`n"
    }

    # Return the files of a launcher checkout whose VERSION holds $Version (none when it is empty), with a CHANGELOG.md that fits it.
    function Get-TestLauncher([string]$Version = '1.2.3') {
        $files = $runtimeFiles.Clone()
        foreach ($name in $devFiles.Keys) { $files[$name] = $devFiles[$name] }
        $files['CHANGELOG.md'] = Get-TestChangelog -Version $Version
        if ($Version) { $files['VERSION'] = "$Version`n" }
        return $files
    }
}

Describe 'Compare-ReleaseVersion' {
    It 'orders <Version> against <Other> as <Expected>' -ForEach @(
        @{ Version = '1.10.0'; Other = '1.9.9'; Expected = 1 }
        @{ Version = '2.0.0'; Other = '1.99.99'; Expected = 1 }
        @{ Version = '0.1.0'; Other = '0.0.10'; Expected = 1 }
        @{ Version = '1.2.3'; Other = '1.2.3'; Expected = 0 }
        @{ Version = '1.2.3'; Other = '1.2.4'; Expected = -1 }
    ) {
        Compare-ReleaseVersion -Version $Version -Other $Other | Should -Be $Expected
    }

    It 'refuses <Text>, which is no release version' -ForEach @(
        @{ Text = '1.2' }
        @{ Text = '01.2.3' }
        @{ Text = 'v1.2.3' }
        @{ Text = '1.2.3-rc.1' }
        @{ Text = '2147483648.0.0' }
    ) {
        { Compare-ReleaseVersion -Version $Text -Other '1.0.0' } | Should -Throw -ExpectedMessage "'$Text' is no release version X.Y.Z."
    }
}

Describe 'Get-ReleaseChangelogProblem' {
    It 'finds nothing wrong in <Case>' -ForEach @(
        @{ Case = 'a first release with its links'; Version = '1.2.3'; Previous = ''; LineEnd = "`n" }
        @{ Case = 'a later release whose link compares the one before'; Version = '1.2.3'; Previous = '1.2.2'; LineEnd = "`n" }
        @{ Case = 'CRLF line ends'; Version = '1.2.3'; Previous = ''; LineEnd = "`r`n" }
        @{ Case = 'spaces at the end of every line'; Version = '1.2.3'; Previous = ''; LineEnd = "  `n" }
        @{ Case = 'the Unreleased section alone, when there is no VERSION'; Version = ''; Previous = ''; LineEnd = "`n" }
    ) {
        $text = (Get-TestChangelog -Version $Version -Previous $Previous).Replace("`n", $LineEnd)
        @(Get-ReleaseChangelogProblem -Text $text -Version $Version) | Should -BeNullOrEmpty
    }

    # Built names the release in the text (none when empty), Old and New change it, and Version is what VERSION holds.
    It 'reports <Case>' -ForEach @(
        @{ Case = 'a version heading without VERSION'; Built = '1.2.3'; Version = ''; Old = ''; New = ''
            Problem = "There is no VERSION file, but CHANGELOG.md has the version heading '## [1.2.3] - 2026-05-04'." }
        @{ Case = 'VERSION without a version heading'; Built = ''; Version = '1.2.3'; Old = ''; New = ''
            Problem = 'VERSION names 1.2.3, but CHANGELOG.md has no version heading.' }
        @{ Case = 'a version heading above Unreleased'; Built = '1.2.3'; Version = '1.2.3'; Old = "## [Unreleased]`n`n"; New = ''
            Problem = "The first '## ' heading of CHANGELOG.md must be '## [Unreleased]', but it is '## [1.2.3] - 2026-05-04'." }
        @{ Case = 'no heading at all'; Built = ''; Version = ''; Old = "## [Unreleased]`n"; New = ''
            Problem = "CHANGELOG.md has no '## [Unreleased]' heading." }
        @{ Case = 'two Unreleased headings'; Built = '1.2.3'; Version = '1.2.3'; Old = '## [1.2.3]'; New = "## [Unreleased]`n`n## [1.2.3]"
            Problem = "CHANGELOG.md has 2 '## [Unreleased]' headings; keep one." }
        @{ Case = 'no Unreleased link'; Built = '1.2.3'; Version = '1.2.3'; Old = "[Unreleased]: https://github.com/example/launcher/compare/v1.2.3...HEAD`n"; New = ''
            Problem = "CHANGELOG.md has no '[Unreleased]: ' link line." }
        @{ Case = 'a heading that names another version'; Built = '1.2.3'; Version = '1.2.4'; Old = ''; New = ''
            Problem = 'The first version heading of CHANGELOG.md names 1.2.3, but VERSION names 1.2.4.' }
        @{ Case = 'a heading without a date'; Built = '1.2.3'; Version = '1.2.3'; Old = '## [1.2.3] - 2026-05-04'; New = '## [1.2.3]'
            Problem = "The first version heading of CHANGELOG.md must read '## [1.2.3] - YYYY-MM-DD', but it reads '## [1.2.3]'." }
        @{ Case = 'a date in another form'; Built = '1.2.3'; Version = '1.2.3'; Old = '2026-05-04'; New = '04.05.2026'
            Problem = "The first version heading of CHANGELOG.md must read '## [1.2.3] - YYYY-MM-DD', but it reads '## [1.2.3] - 04.05.2026'." }
        @{ Case = 'a date that does not exist'; Built = '1.2.3'; Version = '1.2.3'; Old = '2026-05-04'; New = '2026-02-30'
            Problem = "The date in '## [1.2.3] - 2026-02-30' is no real date YYYY-MM-DD." }
        @{ Case = 'two headings of the version'; Built = '1.2.3'; Version = '1.2.3'; Old = '[Unreleased]: '; New = "## [1.2.3] - 2026-05-05`n`n- Again.`n`n[Unreleased]: "
            Problem = 'CHANGELOG.md has 2 headings for 1.2.3; keep one.' }
        @{ Case = 'a section without changes'; Built = '1.2.3'; Version = '1.2.3'; Old = "### Added`n`n- A release check.`n`n### Fixed`n`n- A typo.`n"; New = ''
            Problem = "The section '## [1.2.3] - 2026-05-04' of CHANGELOG.md lists no changes." }
        @{ Case = 'an Unreleased link that still names main'; Built = '1.2.3'; Version = '1.2.3'; Old = 'compare/v1.2.3...HEAD'; New = 'commits/main'
            Problem = "The link '[Unreleased]: https://github.com/example/launcher/commits/main' must compare v1.2.3 with HEAD" }
        @{ Case = 'an Unreleased link from the version before'; Built = '1.2.3'; Version = '1.2.3'; Old = 'compare/v1.2.3...HEAD'; New = 'compare/v1.2.2...HEAD'
            Problem = "The link '[Unreleased]: https://github.com/example/launcher/compare/v1.2.2...HEAD' must compare v1.2.3 with HEAD" }
        @{ Case = 'no link for the version'; Built = '1.2.3'; Version = '1.2.3'; Old = "[1.2.3]: https://github.com/example/launcher/releases/tag/v1.2.3`n"; New = ''
            Problem = "CHANGELOG.md has no '[1.2.3]: ' link line." }
        @{ Case = 'a version link to another release'; Built = '1.2.3'; Version = '1.2.3'; Old = 'releases/tag/v1.2.3'; New = 'releases/tag/v1.2.2'
            Problem = "The link '[1.2.3]: https://github.com/example/launcher/releases/tag/v1.2.2' must lead to the release v1.2.3" }
        @{ Case = 'a version link over http'; Built = '1.2.3'; Version = '1.2.3'; Old = 'https://github.com/example/launcher/releases'; New = 'http://github.com/example/launcher/releases'
            Problem = "The link '[1.2.3]: http://github.com/example/launcher/releases/tag/v1.2.3' must lead to the release v1.2.3" }
    ) {
        $text = Get-TestChangelog -Version $Built
        if ($Old) { $text = $text.Replace($Old, $New) }
        $problems = @(Get-ReleaseChangelogProblem -Text $text -Version $Version)
        @($problems | Where-Object { $_.StartsWith($Problem, [StringComparison]::Ordinal) }).Count | Should -Be 1 -Because ($problems -join ' | ')
    }
}

Describe 'Get-ReleaseVersion' {
    BeforeEach {
        $checkout = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-ReleaseTestFile (Join-Path $checkout 'CHANGELOG.md') (Get-TestChangelog)
    }

    It 'returns the version that VERSION holds with a line feed, also for a relative path' {
        Write-ReleaseTestFile (Join-Path $checkout 'VERSION') "1.2.3`n"
        Get-ReleaseVersion -RepositoryPath $checkout | Should -BeExactly '1.2.3'
        Push-Location -LiteralPath $checkout
        try {
            Get-ReleaseVersion -RepositoryPath '.' | Should -BeExactly '1.2.3'
        } finally {
            Pop-Location
        }
    }

    It 'returns $null without VERSION, as before the first release, while CHANGELOG.md names no version' {
        Write-ReleaseTestFile (Join-Path $checkout 'CHANGELOG.md') (Get-TestChangelog -Version '')
        Get-ReleaseVersion -RepositoryPath $checkout | Should -BeNullOrEmpty
    }

    It 'refuses a VERSION file that holds <Case>' -ForEach @(
        @{ Case = 'no line feed'; Text = '1.2.3' }
        @{ Case = 'CRLF'; Text = "1.2.3`r`n" }
        @{ Case = 'a BOM'; Text = ([string][char]0xEF + [char]0xBB + [char]0xBF) + "1.2.3`n" }
        @{ Case = 'two line feeds'; Text = "1.2.3`n`n" }
        @{ Case = 'a trailing space'; Text = "1.2.3 `n" }
        @{ Case = 'a v before the version'; Text = "v1.2.3`n" }
        @{ Case = 'a leading zero'; Text = "1.02.3`n" }
        @{ Case = 'two numbers'; Text = "1.2`n" }
        @{ Case = 'a prerelease'; Text = "1.2.3-rc.1`n" }
        @{ Case = 'a number above 2147483647'; Text = "2147483648.0.0`n" }
    ) {
        Write-ReleaseTestFile (Join-Path $checkout 'VERSION') $Text
        { Get-ReleaseVersion -RepositoryPath $checkout } | Should -Throw -ExpectedMessage '*VERSION must hold one line X.Y.Z and a line feed*'
    }

    It 'refuses a folder named VERSION, and a missing or broken CHANGELOG.md' {
        $null = New-Item -ItemType Directory -Path (Join-Path $checkout 'VERSION')
        { Get-ReleaseVersion -RepositoryPath $checkout } | Should -Throw -ExpectedMessage '*VERSION is a folder*'
        [IO.Directory]::Delete((Join-Path $checkout 'VERSION'))
        Write-ReleaseTestFile (Join-Path $checkout 'CHANGELOG.md') ("# Changelog`n" + [char]0xFF + "`n")
        { Get-ReleaseVersion -RepositoryPath $checkout } | Should -Throw -ExpectedMessage '*CHANGELOG.md is not UTF-8 text*'
        Remove-Item -LiteralPath (Join-Path $checkout 'CHANGELOG.md')
        { Get-ReleaseVersion -RepositoryPath $checkout } | Should -Throw -ExpectedMessage '*CHANGELOG.md is missing.*'
    }

    It 'lists what CHANGELOG.md breaks for the version VERSION names, and for a missing VERSION' {
        Write-ReleaseTestFile (Join-Path $checkout 'VERSION') "1.2.4`n"
        $thrown = { Get-ReleaseVersion -RepositoryPath $checkout } | Should -Throw -PassThru
        $thrown.Exception.Message | Should -BeLike "VERSION and CHANGELOG.md in $checkout break the release rules in CONTRIBUTING.md:*"
        $thrown.Exception.Message | Should -BeLike '*names 1.2.3, but VERSION names 1.2.4.*'
        $thrown.Exception.Message | Should -BeLike '*must compare v1.2.4 with HEAD*'
        Remove-Item -LiteralPath (Join-Path $checkout 'VERSION')
        { Get-ReleaseVersion -RepositoryPath $checkout } | Should -Throw -ExpectedMessage '*There is no VERSION file, but CHANGELOG.md has the version heading*'
    }
}

Describe 'Get-ReleaseNotes' {
    BeforeAll {
        $notes123 = (@('## [1.2.3] - 2026-05-04', '', '### Added', '', '- A release check.', '', '### Fixed', '', '- A typo.') -join "`n") + "`n"
    }

    It 'returns the first release from its heading up to the links, without them, ending in one LF' {
        Get-ReleaseNotes -Text (Get-TestChangelog) -Version '1.2.3' | Should -BeExactly $notes123
    }

    It 'stops at the heading of the release before, and writes LF for CRLF' {
        $text = (Get-TestChangelog -Previous '1.2.2').Replace("`n", "`r`n")
        Get-ReleaseNotes -Text $text -Version '1.2.3' | Should -BeExactly $notes123
        Get-ReleaseNotes -Text $text -Version '1.2.2' | Should -BeExactly ((@('## [1.2.2] - 2026-04-01', '', '### Added', '', '- The first release.') -join "`n") + "`n")
    }

    It 'refuses a version without a section, and a section that lists no changes' {
        $thrown = { Get-ReleaseNotes -Text (Get-TestChangelog) -Version '1.2.4' } | Should -Throw -PassThru
        $thrown.Exception.Message | Should -BeExactly "CHANGELOG.md has no section '## [1.2.4] - YYYY-MM-DD'."
        $empty = (Get-TestChangelog).Replace("### Added`n`n- A release check.`n`n### Fixed`n`n- A typo.`n", '')
        $thrown = { Get-ReleaseNotes -Text $empty -Version '1.2.3' } | Should -Throw -PassThru
        $thrown.Exception.Message | Should -BeExactly "The section '## [1.2.3] - 2026-05-04' of CHANGELOG.md lists no changes."
    }

    It 'writes the notes of a checkout to a file as UTF-8 without BOM' {
        $checkout = Join-Path $TestDrive 'notes'
        Write-ReleaseTestFile (Join-Path $checkout 'CHANGELOG.md') (Get-TestChangelog)
        $path = Join-Path $TestDrive 'notes-out\notes.md'
        New-ReleaseNotesFile -RepositoryPath $checkout -Version '1.2.3' -Path $path
        $latin1.GetString([IO.File]::ReadAllBytes($path)) | Should -BeExactly $notes123
    }
}

Describe 'Get-ReleaseUnreleasedLine' {
    It 'finds nothing under the empty [Unreleased] of a release, with <Case>' -ForEach @(
        @{ Case = 'LF line ends'; LineEnd = "`n" }
        @{ Case = 'CRLF line ends'; LineEnd = "`r`n" }
        @{ Case = 'spaces at the end of every line'; LineEnd = "  `n" }
    ) {
        $text = (Get-TestChangelog -Previous '1.2.2').Replace("`n", $LineEnd)
        @(Get-ReleaseUnreleasedLine -Text $text) | Should -BeNullOrEmpty
    }

    It 'returns the lines under [Unreleased] up to the next heading, without blank lines and trailing spaces' {
        $text = (Get-TestChangelog).Replace("## [Unreleased]`n", "## [Unreleased]`n`n### Fixed  `n`n- The fix of a draft,`n  which ships in 1.2.3.`n`n")
        @(Get-ReleaseUnreleasedLine -Text $text) | Should -Be @('### Fixed', '- The fix of a draft,', '  which ships in 1.2.3.')
    }

    It 'returns the entries before the first release, without the link line below them' {
        @(Get-ReleaseUnreleasedLine -Text (Get-TestChangelog -Version '')) | Should -Be @('### Added', '- A release check.')
    }

    It 'finds nothing without an [Unreleased] heading' {
        @(Get-ReleaseUnreleasedLine -Text "# Changelog`n`n## [1.0.0] - 2026-01-01`n`n- The first release.`n") | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-ReleaseManifest' {
    It 'lists the files in ordinal order, with ASCII escapes, two-space indents and LF line ends' {
        $files = @{ 'src/b.txt' = ('b' * 64); 'B.txt' = ('1' * 64); 'a.txt' = ('a' * 64); 'src.txt' = ('c' * 64); ('caf' + [char]0xE9 + '.md') = ('d' * 64) }
        $commit = ('0123456789abcdef' * 2) + '01234567'
        $expected = (@(
                '{'
                '  "schema": 1,'
                '  "name": "local-ai-launcher",'
                '  "version": "2.0.1",'
                '  "tag": "v2.0.1",'
                "  `"commit`": `"$commit`","
                '  "files": {'
                "    `"B.txt`": `"$('1' * 64)`","
                "    `"a.txt`": `"$('a' * 64)`","
                "    `"caf$('\')u00e9.md`": `"$('d' * 64)`","
                "    `"src.txt`": `"$('c' * 64)`","
                "    `"src/b.txt`": `"$('b' * 64)`""
                '  }'
                '}'
            ) -join "`n") + "`n"
        ConvertTo-ReleaseManifest -Version '2.0.1' -Commit $commit -File $files | Should -BeExactly $expected
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a version with a v'; Version = 'v1.0.0'; Commit = ('a' * 40); Path = 'a'; Hash = ('a' * 64); Message = "'v1.0.0' is no release version X.Y.Z." }
        @{ Case = 'a short commit'; Version = '1.0.0'; Commit = 'abc1234'; Path = 'a'; Hash = ('a' * 64); Message = "*'abc1234' is no full commit SHA*" }
        @{ Case = 'an uppercase commit'; Version = '1.0.0'; Commit = ('A' * 40); Path = 'a'; Hash = ('a' * 64); Message = '*is no full commit SHA*' }
        @{ Case = 'an uppercase hash'; Version = '1.0.0'; Commit = ('a' * 40); Path = 'a'; Hash = ('A' * 64); Message = '*is not 64 lowercase hex digits*' }
        @{ Case = 'a backslash in a path'; Version = '1.0.0'; Commit = ('a' * 40); Path = 'src\a.ps1'; Hash = ('a' * 64); Message = "*'src\a.ps1' is no path inside the release folder*" }
        @{ Case = 'a path that climbs out'; Version = '1.0.0'; Commit = ('a' * 40); Path = '../a'; Hash = ('a' * 64); Message = "*'../a' is no path inside the release folder*" }
        @{ Case = 'a leading slash'; Version = '1.0.0'; Commit = ('a' * 40); Path = '/a'; Hash = ('a' * 64); Message = "*'/a' is no path inside the release folder*" }
    ) {
        { ConvertTo-ReleaseManifest -Version $Version -Commit $Commit -File @{ $Path = $Hash } } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses a manifest without files' {
        { ConvertTo-ReleaseManifest -Version '1.0.0' -Commit ('a' * 40) -File @{} } | Should -Throw -ExpectedMessage 'A release manifest lists at least one file.'
    }
}

Describe 'New-ReleaseChecksumFile' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-ReleaseTestFile (Join-Path $folder 'b-asset.zip') 'zip bytes'
        Write-ReleaseTestFile (Join-Path $folder 'A.ps1') "x`r`n"
        $out = Join-Path $folder 'SHA256SUMS'
    }

    It 'writes per asset its SHA-256 in lowercase hex, two spaces and its name, sorted by name, with LF in ASCII' {
        New-ReleaseChecksumFile -Path (Join-Path $folder 'b-asset.zip'), (Join-Path $folder 'A.ps1') -OutputPath $out
        $bytes = [IO.File]::ReadAllBytes($out)
        $latin1.GetString($bytes) | Should -BeExactly ("$(Get-TestHash "x`r`n")  A.ps1`n$(Get-TestHash 'zip bytes')  b-asset.zip`n")
        (Get-FileHash -LiteralPath (Join-Path $folder 'b-asset.zip') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly (Get-TestHash 'zip bytes')
        @($bytes | Where-Object { $_ -gt 0x7F -or $_ -eq 13 }) | Should -BeNullOrEmpty
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a name with a space'; Name = 'my asset.zip'; Message = "The asset name 'my asset.zip' must be ASCII letters, digits, '.', '_', '+' and '-'." }
        @{ Case = 'SHA256SUMS itself'; Name = 'SHA256SUMS'; Message = 'SHA256SUMS cannot list itself.' }
    ) {
        Write-ReleaseTestFile (Join-Path $folder $Name) 'x'
        { New-ReleaseChecksumFile -Path (Join-Path $folder $Name) -OutputPath (Join-Path $folder 'sums.txt') } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses two assets of one name' {
        Write-ReleaseTestFile (Join-Path $folder 'other\A.ps1') 'y'
        { New-ReleaseChecksumFile -Path (Join-Path $folder 'A.ps1'), (Join-Path $folder 'other\A.ps1') -OutputPath $out } | Should -Throw -ExpectedMessage 'Two assets are named A.ps1.'
    }
}

Describe 'New-ReleaseZip and Assert-ReleaseZip' {
    BeforeAll {
        $base = Join-Path $TestDrive 'zip'
        $repository = Join-Path $base 'repo'
        $commit = Initialize-TestRepository -Path $repository -Files (Get-TestLauncher)
        $build = New-ReleaseZip -RepositoryPath $repository -Commit 'HEAD' -Version '1.2.3' -OutputDirectory (Join-Path $base 'out')
        $entries = Read-TestZip $build.Path
        $prefix = 'local-ai-launcher-1.2.3/'

        # Copy the zip $Source into a new folder under its own name, let $Change edit the copy as a ZipArchive in update mode, and return
        # the copy's path.
        function Edit-TestZip([string]$Source, [scriptblock]$Change) {
            $folder = Join-Path $TestDrive ('edited-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $folder
            $copy = Join-Path $folder (Split-Path $Source -Leaf)
            Copy-Item -LiteralPath $Source -Destination $copy
            $zip = [IO.Compression.ZipFile]::Open($copy, [IO.Compression.ZipArchiveMode]::Update)
            try { & $Change $zip } finally { $zip.Dispose() }
            return $copy
        }

        # Add the entry $Name with the bytes of $Text to the open zip $Zip, after deleting an entry of that name unless -Again is set.
        function Write-TestZipEntry($Zip, [string]$Name, [string]$Text, [switch]$Again) {
            $old = $Zip.GetEntry($Name)
            if ($old -and -not $Again) { $old.Delete() }
            $stream = $Zip.CreateEntry($Name).Open()
            try {
                $bytes = $latin1.GetBytes($Text)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    }

    It 'returns the zip local-ai-launcher-1.2.3.zip of the full commit, and puts every entry inside the folder local-ai-launcher-1.2.3/' {
        $build.Path | Should -Be (Join-Path $base 'out\local-ai-launcher-1.2.3.zip')
        $build.Version | Should -BeExactly '1.2.3'
        $build.Commit | Should -BeExactly $commit
        $build.Sha256 | Should -BeExactly (Get-FileHash -LiteralPath $build.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $build.Files | Should -Be 14
        @($entries.Keys | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::Ordinal) }) | Should -BeNullOrEmpty
        $entries.Contains($prefix) | Should -BeTrue
    }

    It 'holds the runtime files, VERSION, CHANGELOG.md and the manifest, and none of the files export-ignore names' {
        $names = @($entries.Keys | Where-Object { -not $_.EndsWith('/') } | ForEach-Object { $_.Substring($prefix.Length) } | Sort-Object)
        $names | Should -Be @(@($runtimeFiles.Keys) + @('VERSION', 'CHANGELOG.md', 'local-ai-release.json') | Sort-Object)
        foreach ($name in $devFiles.Keys) { $entries.Contains($prefix + $name) | Should -BeFalse -Because "$name is export-ignore" }
        @($entries.Keys | Where-Object { $_ -match '/(\.github|\.githooks|tests)/' }) | Should -BeNullOrEmpty
        $entries.Contains($prefix + '.gitattributes') | Should -BeFalse
    }

    It 'writes CRLF into the cmd and PowerShell files and LF into the others, whatever the working tree held' {
        foreach ($name in $zippedFiles.Keys) { $entries[$prefix + $name].Text | Should -BeExactly $zippedFiles[$name] -Because $name }
        $entries[$prefix + 'VERSION'].Text | Should -BeExactly "1.2.3`n"
        $entries[$prefix + 'CHANGELOG.md'].Text | Should -BeExactly (Get-TestChangelog)
    }

    It 'writes the manifest of every other file, in ordinal order, as JSON with two-space indents in ASCII with LF' {
        $listed = @{ 'VERSION' = (Get-TestHash "1.2.3`n"); 'CHANGELOG.md' = (Get-TestHash (Get-TestChangelog)) }
        foreach ($name in $zippedFiles.Keys) { $listed[$name] = Get-TestHash $zippedFiles[$name] }
        $order = [string[]]@($listed.Keys)
        [Array]::Sort($order, [StringComparer]::Ordinal)
        $order[0] | Should -BeExactly 'CHANGELOG.md'
        [Array]::IndexOf($order, 'src/LocalAI.psm1') | Should -BeLessThan ([Array]::IndexOf($order, 'src/image_gate.py'))
        $fileLines = @(for ($i = 0; $i -lt $order.Count; $i++) {
                $comma = if ($i -lt $order.Count - 1) { ',' } else { '' }
                "    `"$($order[$i])`": `"$($listed[$order[$i]])`"$comma"
            })
        $head = @('{', '  "schema": 1,', '  "name": "local-ai-launcher",', '  "version": "1.2.3",', '  "tag": "v1.2.3",', "  `"commit`": `"$commit`",", '  "files": {')
        $manifest = $entries[$prefix + 'local-ai-release.json'].Text
        $manifest | Should -BeExactly (((@($head) + $fileLines + @('  }', '}')) -join "`n") + "`n")
        $parsed = ConvertFrom-Json -InputObject $manifest
        $parsed.files.'src/LocalAI.psm1' | Should -BeExactly (Get-TestHash $zippedFiles['src/LocalAI.psm1'])
    }

    It 'stamps every entry, the manifest included, with the commit time in UTC' {
        foreach ($name in $entries.Keys) {
            # A zip keeps the time in steps of 2 s.
            $entries[$name].Time | Should -Be ([datetime]'2026-01-02 03:04:04') -Because $name
        }
    }

    It 'gives the same bytes again, from a clone with another core.autocrlf, and whatever TZ the caller has' {
        $again = New-ReleaseZip -RepositoryPath $repository -Commit $commit -Version '1.2.3' -OutputDirectory (Join-Path $base 'again')
        $again.Sha256 | Should -BeExactly $build.Sha256
        $clone = Join-Path $base 'clone'
        $null = Invoke-TestGit @('clone', '-q', '-c', 'core.autocrlf=input', $repository, $clone)
        $saved = $env:TZ
        try {
            $env:TZ = 'JST-9'
            $other = New-ReleaseZip -RepositoryPath $clone -Commit $commit -Version '1.2.3' -OutputDirectory (Join-Path $base 'other')
            $env:TZ | Should -BeExactly 'JST-9'
        } finally {
            $env:TZ = $saved
        }
        $other.Sha256 | Should -BeExactly $build.Sha256
        (Get-FileHash -LiteralPath $other.Path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $build.Sha256
    }

    It 'refuses a commit the repository lacks, a version that is no X.Y.Z, and a tracked manifest at the top' {
        { New-ReleaseZip -RepositoryPath $repository -Commit ('0' * 40) -Version '1.2.3' -OutputDirectory (Join-Path $base 'none') } |
            Should -Throw -ExpectedMessage "The repository $repository holds no commit '$('0' * 40)'*"
        { New-ReleaseZip -RepositoryPath $repository -Commit $commit -Version '1.2' -OutputDirectory (Join-Path $base 'none') } |
            Should -Throw -ExpectedMessage "'1.2' is no release version X.Y.Z."
        $tracked = Join-Path $base 'tracked'
        $files = Get-TestLauncher
        $files['local-ai-release.json'] = "{}`n"
        $trackedCommit = Initialize-TestRepository -Path $tracked -Files $files
        { New-ReleaseZip -RepositoryPath $tracked -Commit $trackedCommit -Version '1.2.3' -OutputDirectory (Join-Path $base 'none') } |
            Should -Throw -ExpectedMessage "$trackedCommit tracks local-ai-release.json at the top of the repository*"
    }

    It 'passes the zip it built, and refuses it with -NoVersionFile, under another name or for another commit' {
        { Assert-ReleaseZip -Path $build.Path -Version '1.2.3' -Commit $commit 6>$null } | Should -Not -Throw
        { Assert-ReleaseZip -Path $build.Path -Version '1.2.3' -Commit $commit -NoVersionFile } |
            Should -Throw -ExpectedMessage '*The zip holds local-ai-launcher-1.2.3/VERSION, but its commit has no VERSION file.*'
        $renamed = Join-Path $base 'renamed\other.zip'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $renamed -Parent)
        Copy-Item -LiteralPath $build.Path -Destination $renamed
        { Assert-ReleaseZip -Path $renamed -Version '1.2.3' -Commit $commit } | Should -Throw -ExpectedMessage '*The zip is named other.zip, not local-ai-launcher-1.2.3.zip.*'
        { Assert-ReleaseZip -Path $build.Path -Version '1.2.3' -Commit ('a' * 40) } | Should -Throw -ExpectedMessage '*local-ai-release.json does not match the zip''s files: its line 6 reads*'
        { Assert-ReleaseZip -Path $build.Path -Version '1.2.3' -Commit 'HEAD' } | Should -Throw -ExpectedMessage "'HEAD' is no full commit SHA*"
    }

    It 'refuses a zip with <Case>' -ForEach @(
        @{ Case = 'LF line ends in a .ps1 file'; Name = 'src/local-ai.ps1'; Text = "param()`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/src/local-ai.ps1 must end every line with CRLF, but has 1 LF and 0 CR without the other.*' }
        @{ Case = 'a bare CR in a .cmd file'; Name = 'local-ai.cmd'; Text = "@echo off`r`nexit`r"; Again = $false
            Message = '*local-ai.cmd must end every line with CRLF, but has 0 LF and 1 CR without the other.*' }
        @{ Case = 'CRLF line ends in a .md file'; Name = 'README.md'; Text = "# Test`r`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/README.md must end its lines with LF only, but has 1 CR.*' }
        @{ Case = 'a CR in a .json file'; Name = 'config/files-server/package.json'; Text = "{`r}`n"; Again = $false
            Message = '*package.json must end its lines with LF only, but has 1 CR.*' }
        @{ Case = 'a development file'; Name = 'tests/Tool.Tests.ps1'; Text = "x`r`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/tests/Tool.Tests.ps1 is a development file, which .gitattributes marks export-ignore.*' }
        @{ Case = 'a development file in another case'; Name = '.GitHub/workflows/ci.yml'; Text = "x`n"; Again = $false
            Message = '*.GitHub/workflows/ci.yml is a development file*' }
        @{ Case = 'a changed file'; Name = 'LICENSE'; Text = "Changed`n"; Again = $false
            Message = "*local-ai-release.json does not match the zip's files: its line * reads '    `"LICENSE`": *" }
        @{ Case = 'a file the manifest does not list'; Name = 'src/extra.txt'; Text = "x`n"; Again = $false
            Message = "*does not match the zip's files*where '    `"src/extra.txt`": *" }
        @{ Case = 'another VERSION'; Name = 'VERSION'; Text = "1.2.4`n"; Again = $false
            Message = "*local-ai-launcher-1.2.3/VERSION holds '1.2.4\n', not 1.2.3 and a line feed.*" }
        @{ Case = 'an entry outside the folder'; Name = '../evil.txt'; Text = "x`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/../evil.txt is no plain path inside local-ai-launcher-1.2.3/.*' }
        @{ Case = 'a second entry of one name'; Name = 'LICENSE'; Text = "MIT License`n"; Again = $true
            Message = '*The zip holds local-ai-launcher-1.2.3/LICENSE twice, or in two spellings that differ only in case.*' }
        @{ Case = 'a device name'; Name = 'docs/aux.md'; Text = "x`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/docs/aux.md holds a name that Windows changes or refuses: a device name such as NUL*' }
        @{ Case = 'a name that ends in a dot'; Name = 'notes.'; Text = "x`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/notes. holds a name that Windows changes or refuses*' }
        @{ Case = 'a folder name that ends in a space'; Name = 'docs /a.md'; Text = "x`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/docs /a.md holds a name that Windows changes or refuses*' }
        @{ Case = 'a colon'; Name = 'src/a:b.txt'; Text = "x`n"; Again = $false
            Message = '*local-ai-launcher-1.2.3/src/a:b.txt holds a name that Windows changes or refuses*' }
        @{ Case = 'a file named as a folder entry is in another case'; Name = 'Config'; Text = "x`n"; Again = $false
            Message = '*The zip holds local-ai-launcher-1.2.3/Config twice, or in two spellings that differ only in case.*' }
        @{ Case = 'a folder that a file has the name of in another case'; Name = 'license/x.txt'; Text = "x`n"; Again = $false
            Message = '*The zip holds local-ai-launcher-1.2.3/LICENSE both as a file and as a folder.*' }
    ) {
        $edited = Edit-TestZip -Source $build.Path -Change { param($zip) Write-TestZipEntry -Zip $zip -Name ($prefix + $Name) -Text $Text -Again:$Again }
        { Assert-ReleaseZip -Path $edited -Version '1.2.3' -Commit $commit } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses a zip <Case>' -ForEach @(
        @{ Case = 'without the manifest'; Name = 'local-ai-release.json'; Message = '*The zip lacks the manifest local-ai-launcher-1.2.3/local-ai-release.json.*' }
        @{ Case = 'without src/LocalAI.psm1'; Name = 'src/LocalAI.psm1'; Message = '*The zip lacks local-ai-launcher-1.2.3/src/LocalAI.psm1, which every release holds.*' }
        @{ Case = 'without src/install.ps1'; Name = 'src/install.ps1'; Message = '*The zip lacks local-ai-launcher-1.2.3/src/install.ps1, which every release holds.*' }
        @{ Case = 'without VERSION'; Name = 'VERSION'; Message = '*The zip lacks local-ai-launcher-1.2.3/VERSION.*' }
    ) {
        $edited = Edit-TestZip -Source $build.Path -Change { param($zip) $zip.GetEntry($prefix + $Name).Delete() }
        { Assert-ReleaseZip -Path $edited -Version '1.2.3' -Commit $commit } | Should -Throw -ExpectedMessage $Message
    }

    It 'writes the zip''s src/install.ps1 as the asset install.ps1, byte for byte, and refuses a zip without it' {
        $out = Join-Path $base 'install-asset'
        $path = Save-ReleaseInstallScript -ZipPath $build.Path -Version '1.2.3' -OutputDirectory $out
        $path | Should -Be (Join-Path $out 'install.ps1')
        $latin1.GetString([IO.File]::ReadAllBytes($path)) | Should -BeExactly $zippedFiles['src/install.ps1']
        $edited = Edit-TestZip -Source $build.Path -Change { param($zip) $zip.GetEntry($prefix + 'src/install.ps1').Delete() }
        { Save-ReleaseInstallScript -ZipPath $edited -Version '1.2.3' -OutputDirectory (Join-Path $base 'no-asset') } |
            Should -Throw -ExpectedMessage "The release zip $edited holds no local-ai-launcher-1.2.3/src/install.ps1, which the asset install.ps1 is."
        Test-Path -LiteralPath (Join-Path $base 'no-asset') | Should -BeFalse
        { Save-ReleaseInstallScript -ZipPath $build.Path -Version '1.2' -OutputDirectory $out } | Should -Throw -ExpectedMessage "'1.2' is no release version X.Y.Z."
    }

    It 'refuses a zip with an entry outside its folder' {
        $edited = Edit-TestZip -Source $build.Path -Change { param($zip) Write-TestZipEntry -Zip $zip -Name 'evil.txt' -Text "x`n" }
        { Assert-ReleaseZip -Path $edited -Version '1.2.3' -Commit $commit } | Should -Throw -ExpectedMessage '*evil.txt lies outside the folder local-ai-launcher-1.2.3/.*'
    }

    It 'refuses a zip that states another size for an entry than the entry holds, as every installed launcher refuses it' {
        $folder = Join-Path $TestDrive ('stated-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $folder
        $copy = Join-Path $folder (Split-Path $build.Path -Leaf)
        # The uncompressed size at offset 24 of LICENSE's central directory header, which starts 46 bytes before its name.
        $bytes = [IO.File]::ReadAllBytes($build.Path)
        $central = $latin1.GetString($bytes).LastIndexOf($prefix + 'LICENSE') - 46
        $latin1.GetString($bytes, $central, 4) | Should -BeExactly ('PK' + [char]1 + [char]2)
        [Array]::Copy([BitConverter]::GetBytes([uint32]10), 0, $bytes, $central + 24, 4)
        [IO.File]::WriteAllBytes($copy, $bytes)
        { Assert-ReleaseZip -Path $copy -Version '1.2.3' -Commit $commit } | Should -Throw -ExpectedMessage '*local-ai-launcher-1.2.3/LICENSE holds * bytes, but the zip states 10 for it.*'
    }

    It 'keeps the limits that every installed launcher applies to a release: 64 MB of zip, 10000 entries and 256 MB extracted' {
        InModuleScope LocalAIRelease { $script:ReleaseLimits.Clone() } | ForEach-Object { $_.ZipBytes; $_.Entries; $_.ExtractedBytes } | Should -Be @(64MB, 10000, 256MB)
    }

    It 'refuses a zip beyond the limit of <Case> that every installed launcher applies' -ForEach @(
        @{ Case = 'its bytes'; Key = 'ZipBytes'; Message = '*The zip has * bytes, more than the 10 bytes an installed launcher downloads.*' }
        @{ Case = 'its entries'; Key = 'Entries'; Message = '*The zip holds * entries, more than the 10 an installed launcher extracts.*' }
        @{ Case = 'its bytes once extracted'; Key = 'ExtractedBytes'; Message = '*The zip holds * bytes once extracted, more than the 10 bytes an installed launcher extracts.*' }
    ) {
        $saved = InModuleScope LocalAIRelease -Parameters @{ Key = $Key } { param($Key) $value = $script:ReleaseLimits[$Key]; $script:ReleaseLimits[$Key] = 10; $value }
        try {
            { Assert-ReleaseZip -Path $build.Path -Version '1.2.3' -Commit $commit } | Should -Throw -ExpectedMessage $Message
        } finally {
            InModuleScope LocalAIRelease -Parameters @{ Key = $Key; Value = $saved } { param($Key, $Value) $script:ReleaseLimits[$Key] = $Value }
        }
    }
}

Describe 'Assert-ReleaseTagAbsent, Assert-ReleaseVersionNewest and Assert-ReleaseVersionBump' {
    BeforeAll {
        $base = Join-Path $TestDrive 'bump'
        # The remote: v1.2.3 is a lightweight tag, as a published release makes, and v2.0.0 an annotated one. v3.0.0-rc.1 and v4.0 name no
        # release version X.Y.Z.
        $remote = Join-Path $base 'remote'
        $null = Initialize-TestRepository -Path $remote -Files @{ 'README.md' = "remote`n" }
        $null = Invoke-TestGit @('-C', $remote, 'tag', 'v1.2.3')
        $null = Invoke-TestGit @('-C', $remote, 'tag', '-a', '-m', 'annotated', 'v2.0.0')
        $null = Invoke-TestGit @('-C', $remote, 'tag', 'v3.0.0-rc.1')
        $null = Invoke-TestGit @('-C', $remote, 'tag', 'v4.0')
        $remoteUrl = ([uri]$remote).AbsoluteUri

        # Return a checkout named $Name with origin at the remote, whose first commit holds VERSION $BaseVersion and whose second, HEAD,
        # holds VERSION $Version, each none when empty, with a CHANGELOG.md that fits it.
        function Initialize-BumpCheckout([string]$Name, [string]$BaseVersion, [string]$Version) {
            $path = Join-Path $base $Name
            $files = @{ 'CHANGELOG.md' = (Get-TestChangelog -Version $BaseVersion) }
            if ($BaseVersion) { $files['VERSION'] = "$BaseVersion`n" }
            $null = Initialize-TestRepository -Path $path -Files $files
            $previous = if ($BaseVersion -and $BaseVersion -ne $Version) { $BaseVersion } else { '' }
            Write-ReleaseTestFile (Join-Path $path 'CHANGELOG.md') (Get-TestChangelog -Version $Version -Previous $previous)
            if ($Version) {
                Write-ReleaseTestFile (Join-Path $path 'VERSION') "$Version`n"
            } elseif ($BaseVersion) {
                Remove-Item -LiteralPath (Join-Path $path 'VERSION')
            }
            Write-ReleaseTestFile (Join-Path $path 'change.txt') "$Name`n"
            $null = Add-TestCommit -Path $path -Message 'second'
            $null = Invoke-TestGit @('-C', $path, 'remote', 'add', 'origin', $remoteUrl)
            return $path
        }
    }

    It 'finds no tag <Tag> on the remote' -ForEach @(
        @{ Tag = 'v1.2.4' }
        @{ Tag = 'v1.2' }
        @{ Tag = 'v2.0' }
    ) {
        $checkout = Initialize-BumpCheckout -Name "absent-$Tag" -BaseVersion '' -Version ''
        { Assert-ReleaseTagAbsent -RepositoryPath $checkout -Tag $Tag } | Should -Not -Throw
    }

    It 'finds the <Kind> tag <Tag> on the remote' -ForEach @(
        @{ Kind = 'lightweight'; Tag = 'v1.2.3' }
        @{ Kind = 'annotated'; Tag = 'v2.0.0' }
    ) {
        $checkout = Initialize-BumpCheckout -Name "present-$Tag" -BaseVersion '' -Version ''
        { Assert-ReleaseTagAbsent -RepositoryPath $checkout -Tag $Tag } | Should -Throw -ExpectedMessage "Tag $Tag already exists on origin, so that version is released.*"
    }

    It 'fails when git cannot read the remote' {
        $checkout = Initialize-BumpCheckout -Name 'no-remote' -BaseVersion '' -Version ''
        { Assert-ReleaseTagAbsent -RepositoryPath $checkout -Tag 'v1.0.0' -Remote 'nowhere' } | Should -Throw -ExpectedMessage "'git ls-remote --tags nowhere refs/tags/v1.0.0' in * failed with exit code *"
        { Assert-ReleaseVersionNewest -RepositoryPath $checkout -Version '1.0.0' -Remote 'nowhere' } | Should -Throw -ExpectedMessage "'git ls-remote --tags nowhere refs/tags/v*' in * failed with exit code *"
    }

    It 'passes the version <Version>, which is above every release tag on the remote' -ForEach @(
        @{ Version = '2.0.1' }
        @{ Version = '2.1.0' }
        @{ Version = '10.0.0' }
    ) {
        $checkout = Initialize-BumpCheckout -Name "newest-$Version" -BaseVersion '' -Version ''
        $printed = @(Assert-ReleaseVersionNewest -RepositoryPath $checkout -Version $Version 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $printed | Should -BeExactly "v$Version is above v2.0.0, the highest release tag on origin."
    }

    It 'refuses the version <Version>, <Case>' -ForEach @(
        @{ Version = '1.2.3'; Case = 'whose lightweight tag exists'; Message = 'Tag v1.2.3 already exists on origin, so that version is released.*' }
        @{ Version = '2.0.0'; Case = 'whose annotated tag exists'; Message = 'Tag v2.0.0 already exists on origin, so that version is released.*' }
        @{ Version = '1.10.0'; Case = 'which is below the release v2.0.0'; Message = 'VERSION names 1.10.0, but tag v2.0.0 on origin is a higher version.*' }
        @{ Version = '1.2.4'; Case = 'which lies between two releases'; Message = 'VERSION names 1.2.4, but tag v2.0.0 on origin is a higher version.*' }
    ) {
        $checkout = Initialize-BumpCheckout -Name "below-$Version" -BaseVersion '' -Version ''
        { Assert-ReleaseVersionNewest -RepositoryPath $checkout -Version $Version } | Should -Throw -ExpectedMessage $Message
    }

    It 'passes any version while the remote has no release tag' {
        $checkout = Initialize-BumpCheckout -Name 'newest-first' -BaseVersion '' -Version ''
        # A remote whose only tag, vnext, names no version.
        $first = Join-Path $base 'first'
        $null = Initialize-TestRepository -Path $first -Files @{ 'README.md' = "first`n" }
        $null = Invoke-TestGit @('-C', $first, 'tag', 'vnext')
        $null = Invoke-TestGit @('-C', $checkout, 'remote', 'add', 'first', ([uri]$first).AbsoluteUri)
        $printed = @(Assert-ReleaseVersionNewest -RepositoryPath $checkout -Version '0.1.0' -Remote 'first' 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $printed | Should -BeExactly 'first has no release tag yet, so v0.1.0 is the first release.'
    }

    It 'passes a pull request that <Case>' -ForEach @(
        @{ Case = 'adds VERSION 1.0.0, whose tag is missing'; BaseVersion = ''; Version = '1.0.0' }
        @{ Case = 'raises VERSION from 1.2.3 to 1.3.0'; BaseVersion = '1.2.3'; Version = '1.3.0' }
        @{ Case = 'raises VERSION from 1.9.0 to 1.10.0'; BaseVersion = '1.9.0'; Version = '1.10.0' }
        @{ Case = 'keeps VERSION 1.2.3, although its tag exists'; BaseVersion = '1.2.3'; Version = '1.2.3' }
        @{ Case = 'has no VERSION on either side'; BaseVersion = ''; Version = '' }
    ) {
        $checkout = Initialize-BumpCheckout -Name ([guid]::NewGuid().ToString('N')) -BaseVersion $BaseVersion -Version $Version
        { Assert-ReleaseVersionBump -RepositoryPath $checkout -BaseRevision 'HEAD^1' 6>$null } | Should -Not -Throw
    }

    It 'refuses a pull request that <Case>' -ForEach @(
        @{ Case = 'adds VERSION 1.2.3, whose lightweight tag exists'; BaseVersion = ''; Version = '1.2.3'; Message = 'Tag v1.2.3 already exists on origin*' }
        @{ Case = 'raises VERSION to 2.0.0, whose annotated tag exists'; BaseVersion = '1.2.3'; Version = '2.0.0'; Message = 'Tag v2.0.0 already exists on origin*' }
        @{ Case = 'lowers VERSION from 1.3.0 to 1.2.4'; BaseVersion = '1.3.0'; Version = '1.2.4'; Message = 'VERSION goes from 1.3.0 to 1.2.4, but a release must raise it.' }
    ) {
        $checkout = Initialize-BumpCheckout -Name ([guid]::NewGuid().ToString('N')) -BaseVersion $BaseVersion -Version $Version
        { Assert-ReleaseVersionBump -RepositoryPath $checkout -BaseRevision 'HEAD^1' } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses a base commit the checkout lacks, as with fetch-depth 1' {
        $single = Join-Path $base 'single'
        $null = Initialize-TestRepository -Path $single -Files @{ 'CHANGELOG.md' = (Get-TestChangelog -Version ''); 'README.md' = "x`n" }
        { Assert-ReleaseVersionBump -RepositoryPath $single -BaseRevision 'HEAD^1' } | Should -Throw -ExpectedMessage '*needs the checkout''s fetch-depth at 2 or more*'
    }

    It 'gives a notice without VERSION, and checks the version change of a pull request with -PullRequest' {
        $none = Initialize-BumpCheckout -Name 'notice' -BaseVersion '' -Version ''
        $printed = @(Invoke-ReleaseVersionCheck -RepositoryPath $none 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $printed | Should -BeLike '*::notice::There is no VERSION file, so no release is prepared.*'
        $taken = Initialize-BumpCheckout -Name 'taken' -BaseVersion '' -Version '1.2.3'
        { Invoke-ReleaseVersionCheck -RepositoryPath $taken 6>$null } | Should -Not -Throw
        { Invoke-ReleaseVersionCheck -RepositoryPath $taken -PullRequest 6>$null } | Should -Throw -ExpectedMessage 'Tag v1.2.3 already exists on origin*'
    }
}

Describe 'Invoke-ReleaseBuild' {
    BeforeAll {
        $base = Join-Path $TestDrive 'build'
        $remote = Join-Path $base 'remote'
        $null = Initialize-TestRepository -Path $remote -Files @{ 'README.md' = "remote`n" }
        $null = Invoke-TestGit @('-C', $remote, 'tag', 'v1.2.3')
        $remoteUrl = ([uri]$remote).AbsoluteUri

        # Return a launcher checkout named $Name with VERSION $Version (none when empty) and origin at the remote.
        function Initialize-BuildCheckout([string]$Name, [string]$Version) {
            $path = Join-Path $base $Name
            $null = Initialize-TestRepository -Path $path -Files (Get-TestLauncher -Version $Version)
            $null = Invoke-TestGit @('-C', $path, 'remote', 'add', 'origin', $remoteUrl)
            return $path
        }
    }

    It 'builds the zip, install.ps1, SHA256SUMS and notes.md of the version VERSION names, once its tag is missing' {
        $checkout = Initialize-BuildCheckout -Name 'release' -Version '1.2.4'
        $out = Join-Path $base 'release-out'
        $release = Invoke-ReleaseBuild -RepositoryPath $checkout -Commit 'HEAD' -OutputDirectory $out 6>$null
        $release.Version | Should -BeExactly '1.2.4'
        $release.Tag | Should -BeExactly 'v1.2.4'
        $release.Commit | Should -BeExactly @(Invoke-TestGit @('-C', $checkout, 'rev-parse', 'HEAD'))[-1]
        $release.DryRun | Should -BeFalse
        $release.Zip | Should -Be (Join-Path $out 'assets\local-ai-launcher-1.2.4.zip')
        @(Get-ChildItem -LiteralPath (Join-Path $out 'assets') | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('install.ps1', 'local-ai-launcher-1.2.4.zip', 'SHA256SUMS')
        # install.ps1 is the zip's src/install.ps1, CRLF and all, and SHA256SUMS lists both assets in ordinal order.
        $release.InstallScript | Should -Be (Join-Path $out 'assets\install.ps1')
        $latin1.GetString([IO.File]::ReadAllBytes($release.InstallScript)) | Should -BeExactly $zippedFiles['src/install.ps1']
        $latin1.GetString([IO.File]::ReadAllBytes((Join-Path $out 'assets\SHA256SUMS'))) |
            Should -BeExactly "$(Get-TestHash $zippedFiles['src/install.ps1'])  install.ps1`n$($release.Sha256)  local-ai-launcher-1.2.4.zip`n"
        $release.Notes | Should -Be (Join-Path $out 'notes.md')
        $latin1.GetString([IO.File]::ReadAllBytes($release.Notes)) | Should -BeExactly ((@('## [1.2.4] - 2026-05-04', '', '### Added', '', '- A release check.', '',
                    '### Fixed', '', '- A typo.') -join "`n") + "`n")
        Test-Path -LiteralPath (Join-Path $out 'again') | Should -BeFalse
        { Assert-ReleaseZip -Path $release.Zip -Version '1.2.4' -Commit $release.Commit 6>$null } | Should -Not -Throw
    }

    It 'refuses to build a version whose tag exists, a checkout without VERSION, and an output folder that is not empty' {
        $released = Initialize-BuildCheckout -Name 'released' -Version '1.2.3'
        { Invoke-ReleaseBuild -RepositoryPath $released -Commit 'HEAD' -OutputDirectory (Join-Path $base 'released-out') } |
            Should -Throw -ExpectedMessage 'Tag v1.2.3 already exists on origin*'
        $unversioned = Initialize-BuildCheckout -Name 'unversioned' -Version ''
        { Invoke-ReleaseBuild -RepositoryPath $unversioned -Commit 'HEAD' -OutputDirectory (Join-Path $base 'unversioned-out') } |
            Should -Throw -ExpectedMessage 'There is no VERSION file, so there is no release to build.*'
        $full = Join-Path $base 'full-out'
        Write-ReleaseTestFile (Join-Path $full 'left.txt') 'x'
        { Invoke-ReleaseBuild -RepositoryPath $released -Commit 'HEAD' -OutputDirectory $full -DryRun } |
            Should -Throw -ExpectedMessage "The output folder $full is not empty. Choose a new or empty folder."
    }

    It 'refuses to build a version below a released one, and changes still listed under [Unreleased], which a dry run builds' {
        $below = Initialize-BuildCheckout -Name 'below' -Version '1.2.2'
        { Invoke-ReleaseBuild -RepositoryPath $below -Commit 'HEAD' -OutputDirectory (Join-Path $base 'below-out') } |
            Should -Throw -ExpectedMessage 'VERSION names 1.2.2, but tag v1.2.3 on origin is a higher version.*'
        # A fix merged after the release pull request, whose entry went under [Unreleased] instead of into the section of 1.2.4.
        $waiting = Initialize-BuildCheckout -Name 'waiting' -Version '1.2.4'
        $changelog = (Get-TestChangelog -Version '1.2.4').Replace("## [Unreleased]`n", "## [Unreleased]`n`n### Fixed`n`n- The fix of a draft.`n")
        Write-ReleaseTestFile (Join-Path $waiting 'CHANGELOG.md') $changelog
        $null = Add-TestCommit -Path $waiting -Message 'fix'
        $thrown = { Invoke-ReleaseBuild -RepositoryPath $waiting -Commit 'HEAD' -OutputDirectory (Join-Path $base 'waiting-out') 6>$null } |
            Should -Throw -PassThru
        $thrown.Exception.Message | Should -BeExactly ("CHANGELOG.md lists changes under '## [Unreleased]', which v1.2.4 would ship while its notes " +
            "leave them out. Move them into the section of 1.2.4, as CONTRIBUTING.md describes for a fix of a draft:`n  ### Fixed`n  - The fix of a draft.")
        Test-Path -LiteralPath (Join-Path $base 'waiting-out\notes.md') | Should -BeFalse
        $dry = Invoke-ReleaseBuild -RepositoryPath $waiting -Commit 'HEAD' -OutputDirectory (Join-Path $base 'waiting-dry') -DryRun 6>$null
        $dry.Version | Should -BeExactly '1.2.4'
    }

    It 'dry-runs the version 0.0.0 without VERSION: no tag check and no notes, and a second build with the same bytes' {
        $checkout = Initialize-BuildCheckout -Name 'dry' -Version ''
        $out = Join-Path $base 'dry-out'
        # Captured, so that the notice stays out of the output of the checks, where GitHub Actions would read it as a workflow command.
        $output = @(Invoke-ReleaseBuild -RepositoryPath $checkout -Commit 'HEAD' -OutputDirectory $out -DryRun -Remote 'nowhere' 6>&1)
        $release = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) |
            Should -Contain '::notice::There is no VERSION file, so this dry run builds the version 0.0.0.'
        $release.Version | Should -BeExactly '0.0.0'
        $release.DryRun | Should -BeTrue
        $release.Notes | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $out 'notes.md') | Should -BeFalse
        (Read-TestZip $release.Zip).Contains('local-ai-launcher-0.0.0/VERSION') | Should -BeFalse
        (Get-FileHash -LiteralPath (Join-Path $out 'again\local-ai-launcher-0.0.0.zip') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $release.Sha256
        $latin1.GetString([IO.File]::ReadAllBytes((Join-Path $out 'assets\install.ps1'))) | Should -BeExactly $zippedFiles['src/install.ps1']
    }

    It 'dry-runs the version VERSION names, also when its tag exists' {
        $checkout = Initialize-BuildCheckout -Name 'dry-released' -Version '1.2.3'
        $release = Invoke-ReleaseBuild -RepositoryPath $checkout -Commit 'HEAD' -OutputDirectory (Join-Path $base 'dry-released-out') -DryRun 6>$null
        $release.Version | Should -BeExactly '1.2.3'
        Test-Path -LiteralPath $release.Notes | Should -BeTrue
    }
}

Describe 'This repository' {
    It 'exports exactly the runtime files: what git ls-files lists, less what git check-attr marks export-ignore' {
        $tracked = @(Invoke-TestGit @('-C', $repoRoot, '-c', 'core.quotepath=off', 'ls-files'))
        $tracked.Count | Should -BeGreaterThan 10
        # Each file and each folder above it, as git archive checks a folder with its trailing '/'.
        $candidates = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
        foreach ($file in $tracked) {
            $null = $candidates.Add($file)
            $parts = $file.Split('/')
            for ($i = 1; $i -lt $parts.Count; $i++) { $null = $candidates.Add((($parts[0..($i - 1)]) -join '/') + '/') }
        }
        $marked = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
        foreach ($line in @(Invoke-TestGit (@('-C', $repoRoot, '-c', 'core.quotepath=off', 'check-attr', 'export-ignore', '--') + @($candidates)))) {
            if ($line.EndsWith(': export-ignore: set')) { $null = $marked.Add($line.Substring(0, $line.Length - ': export-ignore: set'.Length)) }
        }
        $exported = @($tracked | Where-Object {
                $file = $_
                $parts = $file.Split('/')
                $folders = @(for ($i = 1; $i -lt $parts.Count; $i++) { (($parts[0..($i - 1)]) -join '/') + '/' })
                -not ($marked.Contains($file) -or @($folders | Where-Object { $marked.Contains($_) }).Count -gt 0)
            })
        $runtime = @($tracked | Where-Object {
                $_ -ceq 'local-ai.cmd' -or $_.StartsWith('src/', [StringComparison]::Ordinal) -or $_.StartsWith('config/', [StringComparison]::Ordinal) -or
                @('README.md', 'CHANGELOG.md', 'LICENSE', 'SECURITY.md', 'VERSION') -ccontains $_
            })
        $exported | Should -Be $runtime
        foreach ($required in 'local-ai.cmd', 'src/local-ai.ps1', 'src/LocalAI.psm1', 'src/image_gate.py', 'config/defaults.psd1', 'README.md',
            'CHANGELOG.md', 'LICENSE', 'SECURITY.md') {
            $exported | Should -Contain $required
        }
    }

    It 'names in LocalAIRelease.psm1 the export-ignore, CRLF and binary rules that .gitattributes holds' {
        $lines = @([IO.File]::ReadAllLines((Join-Path $repoRoot '.gitattributes')))
        $ignored = @($lines | ForEach-Object { if ($_ -cmatch '\A/(\S+) export-ignore\z') { $Matches[1] } })
        $crlf = @($lines | ForEach-Object { if ($_ -cmatch '\A\*(\.\w+) text eol=crlf\z') { $Matches[1] } })
        $binary = @($lines | ForEach-Object { if ($_ -cmatch '\A\*(\.\w+) binary\z') { $Matches[1] } })
        $module = InModuleScope LocalAIRelease { @{ Dev = $script:DevPaths; Crlf = $script:CrlfExtensions; Binary = $script:BinaryExtensions } }
        @($ignored | Sort-Object) | Should -Be @($module.Dev | Sort-Object)
        @($crlf | Sort-Object) | Should -Be @($module.Crlf | Sort-Object)
        @($binary | Sort-Object) | Should -Be @($module.Binary | Sort-Object)
    }

    It 'keeps the release rules for VERSION and CHANGELOG.md' {
        { Get-ReleaseVersion -RepositoryPath $repoRoot } | Should -Not -Throw
    }
}
