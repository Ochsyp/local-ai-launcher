# Pester 6 tests of ci\files-server-live.ps1 and of how ci\test.ps1 calls it. A stand-in for mcpo
# serves made-up answers on a free loopback port, so these tests download and install nothing.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll variables with the It blocks.')]
param()

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $liveScript = Join-Path $repoRoot 'ci\files-server-live.ps1'
    Import-Module (Join-Path $repoRoot 'src\LocalAI.psm1') -Force
    . $liveScript

    $defaults = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
    $allowedTools = @($defaults.Files.AllowedTools)
    $serverVersion = $defaults.Files.ServerVersion

    # The stand-in takes mcpo's arguments, reads the folder from the config New-McpoConfig wrote, and
    # answers as answer.json in its folder says. Every start adds its port and PID to started.txt.
    $standInDir = Join-Path $TestDrive 'stand-in'
    $null = New-Item -ItemType Directory -Path $standInDir
    $standInCmd = Join-Path $standInDir 'mcpo.cmd'
    Set-Content -LiteralPath $standInCmd -Encoding Ascii -Value (
        '@"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0stand-in.ps1" %*')
    Set-Content -LiteralPath (Join-Path $standInDir 'stand-in.ps1') -Encoding Ascii -Value @'
$port = 0
$config = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--port') { $port = [int]$args[$i + 1] }
    if ($args[$i] -eq '--config') { $config = [string]$args[$i + 1] }
}
$started = Join-Path $PSScriptRoot 'started.txt'
$earlier = @(if (Test-Path -LiteralPath $started) { Get-Content -LiteralPath $started }).Count
Add-Content -LiteralPath $started -Value "$port $PID"
$answer = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'answer.json') -Raw | ConvertFrom-Json
if ($answer.ExitAlways -or ($answer.ExitFirst -and $earlier -eq 0)) { exit 3 }
$root = @((Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).mcpServers.files.args)[-1]
$paths = @{}
foreach ($tool in $answer.Tools) { $paths["/$tool"] = @{ post = @{ operationId = $tool } } }
$spec = ConvertTo-Json -Depth 6 -InputObject @{ openapi = '3.1.0'; info = @{ title = 'secure-filesystem-server'; version = $answer.Version }; paths = $paths }
$listed = ConvertTo-Json -InputObject ((@('Allowed directories:', $root) + @($answer.ExtraFolders)) -join "`n")
$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port
$listener.Start()
while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader -ArgumentList $stream, ([Text.Encoding]::ASCII)
        $first = $reader.ReadLine()
        $length = 0
        $expect = $false
        while ($line = $reader.ReadLine()) {
            if ($line -match '^Content-Length:\s*(\d+)') { $length = [int]$Matches[1] }
            if ($line -match '^Expect:\s*100') { $expect = $true }
        }
        if ($expect) {
            $go = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
            $stream.Write($go, 0, $go.Length)
        }
        if ($length -gt 0) { $null = $reader.Read((New-Object char[] $length), 0, $length) }
        $body = [Text.Encoding]::UTF8.GetBytes($(if ($first -like '*openapi.json*') { $spec } else { $listed }))
        $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($head, 0, $head.Length)
        $stream.Write($body, 0, $body.Length)
        $stream.Flush()
    } catch {
        Write-Output "The stand-in dropped a request: $($_.Exception.Message)"
    } finally {
        $client.Close()
    }
}
'@

    # Run the live check against the stand-in with the answer $Change makes from the correct one.
    # Returns @{ Code; Said; Work; Started (one 'port PID' line per start) }.
    function Invoke-StandInCheck {
        param([hashtable]$Change = @{})
        $answer = @{ Version = $serverVersion; Tools = $allowedTools; ExtraFolders = @(); ExitFirst = $false; ExitAlways = $false }
        foreach ($key in $Change.Keys) { $answer[$key] = $Change[$key] }
        Set-Content -LiteralPath (Join-Path $standInDir 'answer.json') -Encoding Ascii -Value (ConvertTo-Json -InputObject $answer -Depth 4)
        Remove-Item -LiteralPath (Join-Path $standInDir 'started.txt') -Force -ErrorAction SilentlyContinue
        $work = Join-Path $TestDrive ('work-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:said = New-Object System.Collections.Generic.List[string]
        Mock Write-Host { $script:said.Add([string]$Object) }
        $code = Invoke-LiveCheck -RepoRoot $repoRoot -WorkRoot $work -ToolCache 'unused' -StartTimeoutSeconds 30
        $startedFile = Join-Path $standInDir 'started.txt'
        return @{
            Code    = $code
            Said    = ($script:said -join "`n")
            Work    = $work
            Started = @(if (Test-Path -LiteralPath $startedFile) { Get-Content -LiteralPath $startedFile })
        }
    }

    # $true when no stand-in of the 'port PID' lines $Started still runs.
    function Test-StandInGone([string[]]$Started) {
        foreach ($line in $Started) {
            if (Get-Process -Id ([int]($line -split ' ')[1]) -ErrorAction SilentlyContinue) { return $false }
        }
        return $true
    }
}

Describe 'Get-LiveNodePath' {
    BeforeEach {
        $cache = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N'))
        function Add-CachedNode([string]$Version, [switch]$NoNpm) {
            $folder = Join-Path $cache "node\$Version\x64"
            $null = New-Item -ItemType Directory -Path (Join-Path $folder 'node_modules\npm\bin') -Force
            Set-Content -LiteralPath (Join-Path $folder 'node.exe') -Value ''
            if (-not $NoNpm) { Set-Content -LiteralPath (Join-Path $folder 'node_modules\npm\bin\npm-cli.js') -Value '' }
        }
    }

    It 'takes the newest Node.js of at least 24, comparing versions as numbers' {
        '22.11.0', '24.9.0', '24.22.3' | ForEach-Object { Add-CachedNode $_ }
        Get-LiveNodePath -ToolCache $cache | Should -Be (Join-Path $cache 'node\24.22.3\x64\node.exe')
    }

    It 'skips a version that has no npm beside it' {
        Add-CachedNode '24.9.0'
        Add-CachedNode '24.22.3' -NoNpm
        Get-LiveNodePath -ToolCache $cache | Should -Be (Join-Path $cache 'node\24.9.0\x64\node.exe')
    }

    It 'fails naming what it found when no version is new enough' {
        Add-CachedNode '22.11.0'
        { Get-LiveNodePath -ToolCache $cache } | Should -Throw -ExpectedMessage '*22.11.0*'
    }

    It 'fails when the tool cache holds no Node.js' {
        { Get-LiveNodePath -ToolCache $cache } | Should -Throw -ExpectedMessage '*none*'
    }
}

Describe 'Get-LiveFreePort' {
    It 'returns a loopback port that can be bound' {
        $port = Get-LiveFreePort
        $probe = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port
        { $probe.Start() } | Should -Not -Throw
        $probe.Stop()
    }
}

Describe 'Invoke-LiveDownload' {
    BeforeEach {
        Mock Write-Host {}
        $script:calls = 0
    }

    It 'tries a failing download three times, then reports it as a download' {
        $thrown = {
            Invoke-LiveDownload -What 'uv' -DelaySeconds 0 -Action {
                $script:calls++
                throw "'uv tool install' failed with exit code 2."
            }
        } | Should -Throw -PassThru
        $script:calls | Should -Be 3
        $thrown.Exception.Data['LiveKind'] | Should -Be 'Download'
    }

    It 'returns the result of a try that works after a failure' {
        $result = Invoke-LiveDownload -What 'uv' -DelaySeconds 0 -Action {
            $script:calls++
            if ($script:calls -eq 1) { throw "'npm ci' failed with exit code 1." }
            'installed'
        }
        $result | Should -Be 'installed'
        $script:calls | Should -Be 2
    }

    It 'never retries a failure that is no download' {
        $thrown = {
            Invoke-LiveDownload -What 'the files server' -DelaySeconds 0 -Action {
                $script:calls++
                throw 'package.json pins 9.9.9, but Files.ServerVersion is 2.3.0. Make them agree.'
            }
        } | Should -Throw -PassThru
        $script:calls | Should -Be 1
        $thrown.Exception.Data['LiveKind'] | Should -Be 'Difference'
    }
}

Describe 'Get-LiveFailureText' {
    It 'tells a failed download to re-run the job' {
        Get-LiveFailureText -Kind 'Download' -Message 'uv failed.' | Should -Match 'Re-run the failed job'
    }

    It 'sends a real difference to the upgrade, not to a re-run' {
        $text = Get-LiveFailureText -Kind 'Difference' -Message 'mcpo serves write_file.'
        $text | Should -Match 'write_file'
        $text | Should -Match 'version change'
        $text | Should -Not -Match 'Re-run'
    }
}

Describe 'Invoke-LiveCheck against a stand-in for mcpo' {
    BeforeEach {
        Mock Install-LiveUv { $TestDrive }
        Mock Get-LiveNodePath { 'X:\node\node.exe' }
        Mock Install-Mcpo { @{ Version = '0.0.20'; Path = $standInCmd; Python = '3.12.0'; ToolDir = 'X:\tools' } }
        Mock Install-FilesServerPackage { @{ Script = 'X:\server\dist\index.js'; LockSha256 = 'ab'; Node = '24.22.3' } }
    }

    It 'passes, and leaves no mcpo and no folder behind, when the server offers what the launcher expects' {
        $run = Invoke-StandInCheck
        $run.Code | Should -Be 0 -Because $run.Said
        $run.Said | Should -Match ([regex]::Escape($serverVersion))
        $run.Started.Count | Should -Be 1
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'restores the variables it changed' {
        $before = $env:LOCALAPPDATA
        $path = $env:Path
        $null = Invoke-StandInCheck
        $env:LOCALAPPDATA | Should -Be $before
        $env:Path | Should -Be $path
        $env:UV_TOOL_DIR | Should -BeNullOrEmpty
    }

    It 'fails naming <Name>, and cleans up' -ForEach @(
        @{ Name = 'an extra tool'; Change = @{ Tools = @($defaults.Files.AllowedTools) + 'write_file' }; Expected = 'write_file' }
        @{ Name = 'a missing tool'; Change = @{ Tools = @($defaults.Files.AllowedTools | Where-Object { $_ -ne 'search_files' }) }; Expected = 'search_files' }
        @{ Name = 'a second folder'; Change = @{ ExtraFolders = @('D:\Second-Folder') }; Expected = 'Second-Folder' }
        @{ Name = 'a wrong version'; Change = @{ Version = '9.9.9' }; Expected = '9\.9\.9' }
    ) {
        $run = Invoke-StandInCheck -Change $Change
        $run.Code | Should -Be 1
        $run.Said | Should -Match $Expected
        $run.Said | Should -Match 'version change'
        $run.Started.Count | Should -Be 1 -Because 'a failed check is not tried again'
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'tries once more on a new port when mcpo cannot start on the first' {
        $run = Invoke-StandInCheck -Change @{ ExitFirst = $true }
        $run.Code | Should -Be 0 -Because $run.Said
        $run.Started.Count | Should -Be 2
        ($run.Started[0] -split ' ')[0] | Should -Not -Be ($run.Started[1] -split ' ')[0]
        Test-StandInGone $run.Started | Should -BeTrue
    }

    It 'fails after two starts when mcpo never starts, and cleans up' {
        $run = Invoke-StandInCheck -Change @{ ExitAlways = $true }
        $run.Code | Should -Be 1
        $run.Said | Should -Match 'mcpo did not start'
        $run.Started.Count | Should -Be 2
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'reports a failed download with the advice to re-run, and starts nothing' {
        Mock Start-Sleep {}
        Mock Install-Mcpo { throw "'uv tool install' failed with exit code 2." }
        $run = Invoke-StandInCheck
        $run.Code | Should -Be 1
        $run.Said | Should -Match 'Re-run the failed job'
        Should -Invoke Install-Mcpo -Times 3 -Exactly
        $run.Started.Count | Should -Be 0
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }
}

Describe 'Invoke-LiveWithLimit' {
    BeforeEach {
        Mock Write-Host {}
        $child = Join-Path $TestDrive ('child-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $work = Join-Path $TestDrive ('limit-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $work
    }

    It 'returns the exit code of the check' {
        Set-Content -LiteralPath $child -Value 'exit 7'
        Invoke-LiveWithLimit -ScriptPath $child -WorkRoot $work -TimeoutSeconds 30 | Should -Be 7
    }

    It 'ends a check that passes the limit, with its children, and removes its folder' {
        $pidFile = Join-Path $work 'grandchild.txt'
        $outside = Join-Path $TestDrive ('grandchild-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $child -Value @"
`$grandchild = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru
Set-Content -LiteralPath '$outside' -Value `$grandchild.Id
Set-Content -LiteralPath '$pidFile' -Value `$grandchild.Id
Start-Sleep -Seconds 60
"@
        $code = Invoke-LiveWithLimit -ScriptPath $child -WorkRoot $work -TimeoutSeconds 6
        $code | Should -Be 1
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*did not finish within 6 s*' }
        Test-Path -LiteralPath $work | Should -BeFalse
        Test-Path -LiteralPath $outside | Should -BeTrue -Because 'the child must have started its own child before the limit'
        Get-Process -Id ([int](Get-Content -LiteralPath $outside)) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'files-server-live.ps1 outside CI' {
    It 'exits 2 and installs nothing' {
        $saved = $env:GITHUB_ACTIONS
        try {
            $env:GITHUB_ACTIONS = $null
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $liveScript 2>&1
            $LASTEXITCODE | Should -Be 2
        } finally {
            $env:GITHUB_ACTIONS = $saved
        }
    }
}

Describe 'ci\test.ps1' {
    BeforeAll {
        # A copy of ci\test.ps1 with stand-ins for what it runs: each writes its name to calls.txt and exits with
        # the code in its STAND_IN_ variable.
        $stage = Join-Path $TestDrive 'stage'
        $bin = Join-Path $TestDrive 'stage-bin'
        $calls = Join-Path $TestDrive 'stage-calls.txt'
        foreach ($folder in (Join-Path $stage 'ci'), (Join-Path $stage 'tests'), $bin) { $null = New-Item -ItemType Directory -Path $folder }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'ci\test.ps1') -Destination (Join-Path $stage 'ci\test.ps1')
        Set-Content -LiteralPath (Join-Path $stage 'tests\requirements.txt') -Value ''
        Set-Content -LiteralPath (Join-Path $stage 'tests\run-checks.ps1') -Value "Add-Content -LiteralPath '$calls' -Value 'pester'; exit [int]`$env:STAND_IN_PESTER"
        Set-Content -LiteralPath (Join-Path $stage 'ci\files-server-live.ps1') -Value "Add-Content -LiteralPath '$calls' -Value 'live'; exit [int]`$env:STAND_IN_LIVE"
        Set-Content -LiteralPath (Join-Path $bin 'python.cmd') -Encoding Ascii -Value @"
@echo python>>"$calls"
@if "%2"=="pip" exit /b 0
@exit /b %STAND_IN_UNITTEST%
"@

        # Run the copy with GITHUB_ACTIONS set to $Actions. Returns @{ Code; Calls }.
        function Invoke-TestStage {
            param([string]$Actions, [int]$Pester = 0, [int]$Unittest = 0, [int]$Live = 0)
            $savedActions = $env:GITHUB_ACTIONS
            $savedPath = $env:Path
            Remove-Item -LiteralPath $calls -Force -ErrorAction SilentlyContinue
            try {
                $env:GITHUB_ACTIONS = $Actions
                $env:Path = "$bin;$env:Path"
                $env:STAND_IN_PESTER = $Pester
                $env:STAND_IN_UNITTEST = $Unittest
                $env:STAND_IN_LIVE = $Live
                $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage 'ci\test.ps1') 2>&1
                $code = $LASTEXITCODE
            } finally {
                $env:GITHUB_ACTIONS = $savedActions
                $env:Path = $savedPath
                $env:STAND_IN_PESTER = $null
                $env:STAND_IN_UNITTEST = $null
                $env:STAND_IN_LIVE = $null
            }
            return @{ Code = $code; Calls = @(if (Test-Path -LiteralPath $calls) { Get-Content -LiteralPath $calls }) }
        }
    }

    It 'does not run the live check on a PC' {
        $run = Invoke-TestStage -Actions ''
        $run.Code | Should -Be 0
        $run.Calls | Should -Not -Contain 'live'
    }

    It 'does not run it for a GITHUB_ACTIONS that is not exactly true' {
        (Invoke-TestStage -Actions 'false').Calls | Should -Not -Contain 'live'
    }

    It 'runs it last on a CI runner' {
        $run = Invoke-TestStage -Actions 'true'
        $run.Code | Should -Be 0
        $run.Calls[-1] | Should -Be 'live'
    }

    It 'exits with the code of a failed live check' {
        (Invoke-TestStage -Actions 'true' -Live 5).Code | Should -Be 5
    }

    It 'does not run it after a failed Pester run' {
        $run = Invoke-TestStage -Actions 'true' -Pester 1
        $run.Code | Should -Be 1
        $run.Calls | Should -Not -Contain 'live'
    }

    It 'does not run it after failed image gate tests' {
        $run = Invoke-TestStage -Actions 'true' -Unittest 4
        $run.Code | Should -Be 4
        $run.Calls | Should -Not -Contain 'live'
    }
}

Describe 'tests\requirements-live.txt' {
    It 'pins uv alone, to one exact version with a SHA-256 hash' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'tests\requirements-live.txt'))
        # Dependabot may write further hashes on continuation lines.
        $joined = $text -replace '\\\r?\n', ' '
        $lines = @($joined -split '\r?\n' | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^uv==\d+\.\d+\.\d+\s+--hash=sha256:[0-9a-f]{64}(\s+--hash=sha256:[0-9a-f]{64})*\s*$'
    }
}
