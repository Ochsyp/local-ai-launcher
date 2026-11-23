# Pester 6 tests of ci\files-server-live.ps1 and of how ci\test.ps1 calls it. A stand-in for mcpo
# serves made-up answers on a free loopback port, so these tests download and install nothing.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll variables with the It blocks.')]
param()

BeforeDiscovery {
    # Pester builds -ForEach data here, before BeforeAll runs.
    $discoveredTools = @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot '..\config\defaults.psd1')).Files.AllowedTools)
}

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $liveScript = Join-Path $repoRoot 'ci\files-server-live.ps1'
    Import-Module (Join-Path $repoRoot 'src\LocalAI.psm1') -Force
    . $liveScript

    $defaults = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
    $allowedTools = @($defaults.Files.AllowedTools)
    $serverVersion = $defaults.Files.ServerVersion
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

    It 'never retries a failure that is no download, and reports it as a setup failure' {
        $thrown = {
            Invoke-LiveDownload -What 'the files server' -DelaySeconds 0 -Action {
                $script:calls++
                throw 'package.json pins 9.9.9, but Files.ServerVersion is 2.3.0. Make them agree.'
            }
        } | Should -Throw -PassThru
        $script:calls | Should -Be 1
        $thrown.Exception.Data['LiveKind'] | Should -Be 'Setup'
        $thrown.Exception.Message | Should -Match 'Make them agree'
    }
}

Describe 'Get-LiveFailureText' {
    It 'tells a failed download to re-run the job' {
        Get-LiveFailureText -Kind 'Download' -Message 'uv failed.' | Should -Match 'Re-run the failed job'
    }

    It 'names the pins as the next place to look when a re-run fails the same way' {
        Get-LiveFailureText -Kind 'Download' -Message 'uv failed.' | Should -Match 'if it fails the same way, look at the pins'
    }

    It 'sends a real difference to the upgrade, not to a re-run' {
        $text = Get-LiveFailureText -Kind 'Difference' -Message 'mcpo serves write_file.'
        $text | Should -Match 'write_file'
        $text | Should -Match 'version change'
        $text | Should -Not -Match 'Re-run'
    }

    It 'does not call a failed setup step a difference in the files server' {
        $text = Get-LiveFailureText -Kind 'Setup' -Message 'Drive C: has 0.1 GB free.'
        $text | Should -Match 'Drive C:'
        $text | Should -Not -Match 'differs'
        $text | Should -Not -Match 'version change'
    }
}

Describe 'Invoke-LiveCheck against a stand-in for mcpo' {
    BeforeAll {
        # A compiled program, as a PowerShell stand-in costs seconds per start on a CI runner. It answers with
        # spec.json and listed.json from its folder, follows mode.txt, and adds its port and PID to started.txt.
        $standInDir = Join-Path $TestDrive 'stand-in'
        $null = New-Item -ItemType Directory -Path $standInDir
        $standIn = Join-Path $standInDir 'mcpo.exe'
        Add-Type -OutputType ConsoleApplication -OutputAssembly $standIn -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

public static class McpoStandIn {
    public static int Main(string[] args) {
        int port = 0;
        for (int i = 0; i + 1 < args.Length; i++) { if (args[i] == "--port") { port = int.Parse(args[i + 1]); } }
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        string started = Path.Combine(folder, "started.txt");
        int earlier = File.Exists(started) ? File.ReadAllLines(started).Length : 0;
        File.AppendAllText(started, port + " " + System.Diagnostics.Process.GetCurrentProcess().Id + Environment.NewLine);
        string mode = File.ReadAllText(Path.Combine(folder, "mode.txt")).Trim();
        if (mode == "ExitAlways" || (mode == "ExitFirst" && earlier == 0)) { return 3; }
        if (mode == "NoRoutes") { Console.Error.WriteLine("The node server did not start."); }
        byte[] spec = File.ReadAllBytes(Path.Combine(folder, "spec.json"));
        byte[] listed = File.ReadAllBytes(Path.Combine(folder, "listed.json"));
        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        while (true) {
            using (TcpClient client = listener.AcceptTcpClient()) {
                try { Answer(client.GetStream(), spec, listed); } catch (IOException) { }
            }
        }
    }

    static void Answer(NetworkStream stream, byte[] spec, byte[] listed) {
        StreamReader reader = new StreamReader(stream, Encoding.ASCII);
        string first = reader.ReadLine();
        int length = 0;
        bool expect = false;
        string line;
        while (!string.IsNullOrEmpty(line = reader.ReadLine())) {
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) { length = int.Parse(line.Substring(15).Trim()); }
            if (line.StartsWith("Expect:", StringComparison.OrdinalIgnoreCase)) { expect = true; }
        }
        if (expect) {
            byte[] go = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
            stream.Write(go, 0, go.Length);
        }
        char[] body = new char[length];
        for (int read = 0, got = 1; read < length && got > 0; read += got) { got = reader.Read(body, read, length - read); }
        byte[] answer = first.Contains("openapi.json") ? spec : listed;
        byte[] head = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + answer.Length + "\r\nConnection: close\r\n\r\n");
        stream.Write(head, 0, head.Length);
        stream.Write(answer, 0, answer.Length);
        stream.Flush();
    }
}
'@

        # Run the live check against the stand-in with the answer $Change makes from the correct one.
        # Returns @{ Code; Said; Work; Started (one 'port PID' line per start) }.
        function Invoke-StandInCheck {
            param([hashtable]$Change = @{}, [int]$StopTimeoutSeconds = 10, [int]$StartTimeoutSeconds = 30)
            $answer = @{ Version = $serverVersion; Tools = $allowedTools; ExtraFolders = @(); Mode = 'Serve' }
            foreach ($key in $Change.Keys) { $answer[$key] = $Change[$key] }
            $work = Join-Path $TestDrive ('work-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            # The folder as the launcher spells it to the server.
            $root = & (Get-Module LocalAI) { param($Path) (Resolve-OnDiskPath -Path $Path).Path } (Join-Path $work 'root')
            $routes = @{}
            foreach ($tool in $answer.Tools) { $routes["/$tool"] = @{ post = @{ operationId = $tool } } }
            $spec = ConvertTo-Json -Depth 6 -InputObject @{ openapi = '3.1.0'; info = @{ title = 'secure-filesystem-server'; version = $answer.Version }; paths = $routes }
            $listed = ConvertTo-Json -InputObject ((@('Allowed directories:', $root) + @($answer.ExtraFolders)) -join "`n")
            [IO.File]::WriteAllText((Join-Path $standInDir 'spec.json'), $spec)
            [IO.File]::WriteAllText((Join-Path $standInDir 'listed.json'), $listed)
            [IO.File]::WriteAllText((Join-Path $standInDir 'mode.txt'), $answer.Mode)
            $startedFile = Join-Path $standInDir 'started.txt'
            Remove-Item -LiteralPath $startedFile -Force -ErrorAction SilentlyContinue
            $script:said = New-Object System.Collections.Generic.List[string]
            Mock Write-Host { $script:said.Add([string]$Object) }
            $code = Invoke-LiveCheck -RepoRoot $repoRoot -WorkRoot $work -ToolCache 'unused' -StartTimeoutSeconds $StartTimeoutSeconds -StopTimeoutSeconds $StopTimeoutSeconds
            return @{
                Code    = $code
                Said    = ($script:said -join "`n")
                Last    = $script:said[$script:said.Count - 1]
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

    BeforeEach {
        Mock Install-LiveUv { $TestDrive }
        Mock Get-LiveNodePath { 'X:\node\node.exe' }
        Mock Install-Mcpo { @{ Version = '0.0.20'; Path = $standIn; Python = '3.12.0'; ToolDir = 'X:\tools' } }
        Mock Install-FilesServerPackage { @{ Script = 'X:\server\dist\index.js'; LockSha256 = 'ab'; Node = '24.22.3' } }
    }

    AfterEach {
        # A failed test must not leave a stand-in that holds the test drive.
        Get-Process -Name 'mcpo' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $standIn } | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    It 'passes, leaves no mcpo and no folder behind, and restores the variables it changed' {
        $before = $env:LOCALAPPDATA
        $path = $env:Path
        $run = Invoke-StandInCheck
        $run.Code | Should -Be 0 -Because $run.Said
        $run.Said | Should -Match ([regex]::Escape($serverVersion))
        $run.Started.Count | Should -Be 1
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
        $env:LOCALAPPDATA | Should -Be $before
        $env:Path | Should -Be $path
        $env:UV_TOOL_DIR | Should -BeNullOrEmpty
    }

    It 'fails naming <Name>, and cleans up' -ForEach @(
        @{ Name = 'an extra tool'; Change = @{ Tools = @($discoveredTools) + 'write_file' }; Expected = "/search_files, /write_file', not '" }
        @{ Name = 'a missing tool'; Change = @{ Tools = @($discoveredTools | Where-Object { $_ -ne 'search_files' }) }; Expected = "routes '[^']*/read_text_file', not '.*/search_files" }
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
        $run = Invoke-StandInCheck -Change @{ Mode = 'ExitFirst' }
        $run.Code | Should -Be 0 -Because $run.Said
        $run.Started.Count | Should -Be 2
        ($run.Started[0] -split ' ')[0] | Should -Not -Be ($run.Started[1] -split ' ')[0]
        Test-StandInGone $run.Started | Should -BeTrue
    }

    It 'fails after two starts when mcpo never starts, and cleans up' {
        $run = Invoke-StandInCheck -Change @{ Mode = 'ExitAlways' }
        $run.Code | Should -Be 1
        $run.Said | Should -Match 'mcpo did not start'
        $run.Last | Should -Not -Match ([regex]::Escape($run.Work)) -Because 'the folder of its logs is gone by then'
        $run.Started.Count | Should -Be 2
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'prints the logs of an mcpo that stays up without routes, and names no deleted log' {
        $run = Invoke-StandInCheck -Change @{ Mode = 'NoRoutes'; Tools = @() } -StartTimeoutSeconds 3
        $run.Code | Should -Be 1
        $run.Said | Should -Match 'The node server did not start\.'
        $run.Last | Should -Match 'mcpo did not start'
        $run.Last | Should -Match 'offers no routes'
        $run.Last | Should -Match 'printed above'
        $run.Last | Should -Not -Match ([regex]::Escape($run.Work))
        $run.Started.Count | Should -Be 1 -Because 'an mcpo that runs did not lose its port'
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'still tries the new port when the stop of the first mcpo throws' {
        $script:stops = 0
        Mock Stop-LocalAIService {
            $script:stops++
            if ($script:stops -eq 1) { throw 'Get-NetTCPConnection failed.' }
            $null = & taskkill.exe /PID $Record.Pid /T /F 2>&1
            'stopped'
        }
        $run = Invoke-StandInCheck -Change @{ Mode = 'ExitFirst' }
        $run.Code | Should -Be 0 -Because $run.Said
        $run.Started.Count | Should -Be 2
        Test-StandInGone $run.Started | Should -BeTrue
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

    It 'passes when the stop reports a failure although mcpo has ended' {
        # taskkill exits 255 when a process of the tree ended by itself first, as uv's mcpo.exe does once its Python is gone.
        Mock Stop-LocalAIService {
            $null = & taskkill.exe /PID $Record.Pid /T /F 2>&1
            Write-Host 'Could not stop Files.'
            'failed'
        }
        $run = Invoke-StandInCheck
        $run.Code | Should -Be 0 -Because $run.Said
        $run.Last | Should -Match '^LIVE CHECK: passed' -Because 'the verdict is the last line'
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'still ends mcpo and removes its folder when the stop throws' {
        Mock Stop-LocalAIService { throw 'Get-NetTCPConnection failed.' }
        $run = Invoke-StandInCheck -StopTimeoutSeconds 1
        $run.Code | Should -Be 1
        $run.Last | Should -Match 'could not be stopped'
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'fails, and ends mcpo itself, when mcpo still runs after the stop' {
        Mock Stop-LocalAIService { 'failed' }
        $run = Invoke-StandInCheck -StopTimeoutSeconds 1
        $run.Code | Should -Be 1
        $run.Last | Should -Match 'could not be stopped'
        $run.Last | Should -Not -Match 'passed'
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'keeps the reason of a failed check in the last line when mcpo also cannot be stopped' {
        Mock Stop-LocalAIService { 'failed' }
        $run = Invoke-StandInCheck -Change @{ Version = '9.9.9' } -StopTimeoutSeconds 1
        $run.Code | Should -Be 1
        $run.Last | Should -Match '9\.9\.9'
        $run.Last | Should -Match 'could not be stopped'
    }

    It 'handles a folder path that holds an apostrophe' {
        $settings = Get-LiveSetting -RepoRoot $repoRoot -Paths (Get-LocalAIPaths -Root (Join-Path $TestDrive "quote'd\local-ai")) -Root "C:\quote'd\root" -Port 18189
        $settings.Files.Root | Should -BeExactly "C:\quote'd\root"
    }
}

Describe 'Wait-LiveProcessEnd' {
    BeforeEach {
        Mock Write-Host {}
        $work = Join-Path $TestDrive ('end-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $work
    }

    It 'does not fail on one process listing that fails' {
        $script:listings = 0
        Mock Get-CimInstance {
            $script:listings++
            if ($script:listings -eq 1) { throw 'WMI is busy.' }
        }
        Wait-LiveProcessEnd -WorkRoot $work -TimeoutSeconds 5 | Should -BeTrue
        $script:listings | Should -Be 2
    }

    It 'returns false, saying why, when no listing works within the limit' {
        Mock Get-CimInstance { throw 'WMI is busy.' }
        Wait-LiveProcessEnd -WorkRoot $work -TimeoutSeconds 1 | Should -BeFalse
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*WMI is busy*' }
    }

    It 'ends a process that runs from the folder without naming it on its command line, as uv can' {
        # On disk, as Windows reports a program's path with long names and the runner's temp path can be an 8.3 name.
        $long = & (Get-Module LocalAI) { param($Path) (Resolve-OnDiskPath -Path $Path).Path } $work
        Add-Type -OutputType ConsoleApplication -OutputAssembly (Join-Path $long 'live-uv.exe') -TypeDefinition (
            'public static class LiveUv { public static void Main() { System.Threading.Thread.Sleep(120000); } }')
        $savedPath = $env:Path
        try {
            # A bare name on the command line, which Windows finds through the Path.
            $env:Path = "$long;$env:Path"
            $startInfo = New-Object Diagnostics.ProcessStartInfo -ArgumentList 'live-uv.exe'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $running = [Diagnostics.Process]::Start($startInfo)
        } finally {
            $env:Path = $savedPath
        }
        try {
            Wait-LiveProcessEnd -WorkRoot $long -TimeoutSeconds 1 | Should -BeFalse
            $running.WaitForExit(5000) | Should -BeTrue
        } finally {
            if (-not $running.HasExited) { $running.Kill() }
            $running.Dispose()
        }
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
        Invoke-LiveWithLimit -ScriptPath $child -WorkRoot $work -TimeoutSeconds 60 | Should -Be 7
    }

    It 'ends a check past the limit with its children and removes its folder, also when taskkill finds one already gone' {
        $marker = Join-Path $TestDrive ('grandchild-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $child -Value @"
`$grandchild = Start-Process -FilePath 'ping.exe' -ArgumentList '-n 120 127.0.0.1' -WindowStyle Hidden -PassThru
Set-Content -LiteralPath '$($marker -replace "'", "''")' -Value `$grandchild.Id
Start-Sleep -Seconds 120
"@
        # Ends the tree as taskkill does and exits 255, its code when a process of the tree ended by itself first.
        Mock Invoke-Native {
            $null = & taskkill.exe /PID $ArgumentList[1] /T /F 2>&1
            if ($SuccessCode -notcontains 255) { throw "'taskkill' failed with exit code 255." }
            255
        }
        # Long enough for a child PowerShell to start on a slow runner.
        $code = Invoke-LiveWithLimit -ScriptPath $child -WorkRoot $work -TimeoutSeconds 25
        $code | Should -Be 1
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*did not finish within 25 s*' }
        Test-Path -LiteralPath $work | Should -BeFalse
        Test-Path -LiteralPath $marker | Should -BeTrue -Because 'the child must have started its own child before the limit'
        Get-Process -Id ([int](Get-Content -LiteralPath $marker)) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'ends what taskkill left behind, also when taskkill itself fails' {
        Set-Content -LiteralPath $child -Value 'Start-Sleep -Seconds 120'
        Mock Invoke-Native { throw "'taskkill' failed with exit code 1." }
        # The child's command line names $work from its first moment, so it need not have finished starting.
        $code = Invoke-LiveWithLimit -ScriptPath $child -WorkRoot $work -TimeoutSeconds 1 -StopTimeoutSeconds 1
        $code | Should -Be 1
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*did not finish within 1 s*' }
        Wait-LiveProcessEnd -WorkRoot $work -TimeoutSeconds 5 | Should -BeTrue
        Test-Path -LiteralPath $work | Should -BeFalse
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
        # A copy of ci\test.ps1 with cmd stand-ins for powershell and python, which start in milliseconds. Each
        # writes what it was asked to run to calls.txt and exits with the code in its STAND_IN_ variable.
        $stage = Join-Path $TestDrive 'stage'
        $bin = Join-Path $TestDrive 'stage-bin'
        $calls = Join-Path $TestDrive 'stage-calls.txt'
        foreach ($folder in (Join-Path $stage 'ci'), (Join-Path $stage 'tests'), $bin) { $null = New-Item -ItemType Directory -Path $folder }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'ci\test.ps1') -Destination (Join-Path $stage 'ci\test.ps1')
        Set-Content -LiteralPath (Join-Path $stage 'tests\requirements.txt') -Value ''
        Set-Content -LiteralPath (Join-Path $bin 'powershell.cmd') -Encoding Ascii -Value @"
@echo %~n5>>"$calls"
@if "%~n5"=="run-checks" exit /b %STAND_IN_PESTER%
@exit /b %STAND_IN_LIVE%
"@
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
                $env:STAND_IN_PESTER = $Pester
                $env:STAND_IN_UNITTEST = $Unittest
                $env:STAND_IN_LIVE = $Live
                $real = Join-Path $PSHOME 'powershell.exe'
                $env:Path = "$bin;$env:Path"
                $null = & $real -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage 'ci\test.ps1') 2>&1
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
        $run.Calls | Should -Contain 'run-checks'
        $run.Calls | Should -Not -Contain 'files-server-live'
    }

    It 'runs it last on a CI runner and exits with its code' {
        $run = Invoke-TestStage -Actions 'true' -Live 5
        $run.Code | Should -Be 5
        $run.Calls[-1] | Should -Be 'files-server-live'
    }

    It 'does not run it after a failed Pester run' {
        $run = Invoke-TestStage -Actions 'true' -Pester 1
        $run.Code | Should -Be 1
        $run.Calls | Should -Not -Contain 'files-server-live'
    }

    It 'does not run it after failed image gate tests' {
        $run = Invoke-TestStage -Actions 'true' -Unittest 4
        $run.Code | Should -Be 4
        $run.Calls | Should -Not -Contain 'files-server-live'
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
