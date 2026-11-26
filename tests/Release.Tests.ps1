# -------------------------------------------------------
#                 LOCAL AI RELEASE TESTS
# -------------------------------------------------------
#
# Pester 6 tests for .github\scripts\LocalAIRelease.psm1 and ci\release-build.ps1, which the
# standard's release.yml runs: the manifest and SHA256SUMS formats, the release zip and its check,
# the asset install.ps1, builds in git repositories made in TestDrive:, and the export-ignore rules
# of this repository's .gitattributes. git must be on PATH.

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

    # Return a CHANGELOG.md text with LF line ends and an empty [Unreleased] section above the release $Version of 2026-05-04, with the
    # links Keep a Changelog writes.
    function Get-TestChangelog([string]$Version = '1.2.3') {
        $url = 'https://github.com/example/launcher'
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in '# Changelog', '', 'All notable changes to this project are listed here.', '', '## [Unreleased]', '') { $lines.Add($line) }
        foreach ($line in "## [$Version] - 2026-05-04", '', '### Added', '', '- A release check.', '', '### Fixed', '', '- A typo.', '') { $lines.Add($line) }
        $lines.Add("[Unreleased]: $url/compare/v$Version...HEAD")
        $lines.Add("[$Version]: $url/releases/tag/v$Version")
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

    # Return the files of a launcher checkout whose VERSION holds $Version, with a CHANGELOG.md that fits it.
    function Get-TestLauncher([string]$Version = '1.2.3') {
        $files = $runtimeFiles.Clone()
        foreach ($name in $devFiles.Keys) { $files[$name] = $devFiles[$name] }
        $files['CHANGELOG.md'] = Get-TestChangelog -Version $Version
        $files['VERSION'] = "$Version`n"
        return $files
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

    It 'passes the zip it built, and refuses it under another name or for another commit' {
        { Assert-ReleaseZip -Path $build.Path -Version '1.2.3' -Commit $commit 6>$null } | Should -Not -Throw
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

Describe 'Invoke-ReleaseHookBuild and ci\release-build.ps1' {
    BeforeAll {
        $hookBase = Join-Path $TestDrive 'hook'
        $hookScript = Join-Path $repoRoot 'ci\release-build.ps1'
        $checkout = Join-Path $hookBase 'checkout'
        $commit = Initialize-TestRepository -Path $checkout -Files (Get-TestLauncher -Version '1.2.4')

        # Run ci\release-build.ps1 with $Arguments in the folder $Path, as the standard's release-build runs it. Returns @{ Code; Output }.
        function Invoke-TestHook([string]$Path, [string[]]$Arguments) {
            $powershell = Join-Path $PSHOME 'powershell.exe'
            Push-Location -LiteralPath $Path
            try {
                $output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $hookScript @Arguments 2>&1 | ForEach-Object { "$_" })
                return @{ Code = $LASTEXITCODE; Output = ($output -join "`n") }
            } finally {
                Pop-Location
            }
        }
    }

    It 'writes only assets\: the zip, install.ps1 and SHA256SUMS' {
        $out = Join-Path $hookBase 'function-out'
        $null = New-Item -ItemType Directory -Path (Join-Path $out 'assets')
        $built = Invoke-ReleaseHookBuild -RepositoryPath $checkout -Version '1.2.4' -Commit $commit -OutputDirectory $out 6>$null
        @(Get-ChildItem -LiteralPath $out | ForEach-Object { $_.Name }) | Should -Be @('assets')
        @(Get-ChildItem -LiteralPath (Join-Path $out 'assets') | ForEach-Object { $_.Name } | Sort-Object) |
            Should -Be @('install.ps1', 'local-ai-launcher-1.2.4.zip', 'SHA256SUMS')
        $built.Zip | Should -Be (Join-Path $out 'assets\local-ai-launcher-1.2.4.zip')
        $built.Commit | Should -BeExactly $commit
    }

    It 'refuses a version that VERSION at the commit does not name' {
        $out = Join-Path $hookBase 'wrong-out'
        { Invoke-ReleaseHookBuild -RepositoryPath $checkout -Version '1.2.5' -Commit $commit -OutputDirectory $out 6>$null } |
            Should -Throw -ExpectedMessage "*local-ai-launcher-1.2.5/VERSION holds '1.2.4\n', not 1.2.5 and a line feed.*"
    }

    It 'builds through the script with the arguments of the standard''s release-build, a dry run too, in the current folder' {
        foreach ($dry in @(@(), @('--dry-run'))) {
            $out = Join-Path $hookBase ('script-out' + $dry.Count)
            $null = New-Item -ItemType Directory -Path (Join-Path $out 'assets')
            # As the standard passes it: a Windows path with forward slashes.
            $run = Invoke-TestHook -Path $checkout -Arguments (@('--version', '1.2.4', '--commit', $commit, '--out', $out.Replace('\', '/')) + $dry)
            $run.Code | Should -Be 0 -Because $run.Output
            @(Get-ChildItem -LiteralPath (Join-Path $out 'assets') | ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be @('install.ps1', 'local-ai-launcher-1.2.4.zip', 'SHA256SUMS')
        }
    }

    It 'exits 64 with its usage for <Name>' -ForEach @(
        @{ Name = 'no --out'; Arguments = @('--version', '1.2.4', '--commit', 'HEAD') }
        @{ Name = 'an unknown argument'; Arguments = @('--version', '1.2.4', '--commit', 'HEAD', '--out', 'x', '--zip') }
        @{ Name = 'a value missing'; Arguments = @('--version', '1.2.4', '--commit', 'HEAD', '--out') }
        @{ Name = 'a flag where a value belongs'; Arguments = @('--version', '1.2.4', '--commit', 'HEAD', '--out', '--dry-run') }
    ) {
        $run = Invoke-TestHook -Path $checkout -Arguments $Arguments
        $run.Code | Should -Be 64
        $run.Output | Should -Match 'usage: ci/release-build.ps1 --version X.Y.Z --commit SHA --out DIR \[--dry-run\]'
    }

    It 'exits 1 naming the reason when the build fails' {
        $run = Invoke-TestHook -Path $checkout -Arguments @('--version', '1.2.5', '--commit', $commit, '--out', (Join-Path $hookBase 'failed-out'))
        $run.Code | Should -Be 1
        $run.Output | Should -Match '^ci/release-build.ps1: '
    }
}

Describe 'This repository' {
    It 'tells the standard''s release tools the name, kind, manifest and asset this module builds' {
        $conf = @{}
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $repoRoot '.github\standard.conf'))) {
            if ($line -cmatch '\A([A-Z_]+)=(.*)\z' -and $Matches[1] -cne 'PRIVACY_ALLOW' -and $Matches[1] -cne 'PRIVACY_HISTORY_ACCEPT') { $conf[$Matches[1]] = $Matches[2] }
        }
        $module = InModuleScope LocalAIRelease { @{ Name = $script:ReleaseName; Manifest = $script:ManifestName; Install = $script:InstallScriptPath } }
        $conf['RELEASE_KIND'] | Should -BeExactly 'zip'
        $conf['RELEASE_RUNNER'] | Should -BeExactly 'windows' -Because 'the hook runs in Windows PowerShell 5.1'
        # The standard expects the asset <NAME>-X.Y.Z.zip with the folder <NAME>-X.Y.Z/ inside, which holds the manifest and the asset.
        $conf['NAME'] | Should -BeExactly $module.Name
        $conf['RELEASE_MANIFEST'] | Should -BeExactly $module.Manifest
        $conf['RELEASE_ASSETS'] | Should -BeExactly $module.Install
        Test-Path -LiteralPath (Join-Path $repoRoot 'ci\release-build.ps1') -PathType Leaf | Should -BeTrue
    }

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
}
