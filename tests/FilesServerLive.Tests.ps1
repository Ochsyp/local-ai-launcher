# Pester 6 tests of ci\files-server-live.ps1 and of how ci\test.ps1 calls it. A stand-in for mcpo
# serves made-up answers on a free loopback port, so these tests download and install nothing.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll variables with the It blocks.')]
param()

BeforeDiscovery {
    # Pester builds -ForEach data here, before BeforeAll runs.
    $discoveredTools = @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot '..\config\defaults.psd1')).Files.AllowedTools)
    # As $readOnlyTools below.
    $discoveredReadOnly = @($discoveredTools) + @('read_file', 'read_multiple_files', 'read_media_file', 'directory_tree', 'list_directory_with_sizes')
}

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $liveScript = Join-Path $repoRoot 'ci\files-server-live.ps1'
    Import-Module (Join-Path $repoRoot 'src\LocalAI.psm1') -Force
    . $liveScript

    $defaults = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
    $allowedTools = @($defaults.Files.AllowedTools)
    $serverVersion = $defaults.Files.ServerVersion
    # What server-filesystem offers with --read-only alone: the allowed tools and the five read tools DisabledTools hides.
    $readOnlyTools = @($allowedTools) + @('read_file', 'read_multiple_files', 'read_media_file', 'directory_tree', 'list_directory_with_sizes')
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

    It 'sends a failed restart to the start and stop code' {
        $text = Get-LiveFailureText -Kind 'Restart' -Message 'start did not restart mcpo.'
        $text | Should -Match '^LIVE CHECK: the restart after a settings change failed\. start did not restart mcpo\.'
        $text | Should -Match 'start and stop code'
    }

    It 'sends a stop that fails during the check to the stop code, or to a re-run' {
        $text = Get-LiveFailureText -Kind 'Stop' -Message 'mcpo could not be stopped.'
        $text | Should -Match 'mcpo could not be stopped\.'
        $text | Should -Match 'stop code'
        $text | Should -Match 're-run'
    }

    It 'sends a read-only flag that withholds too much or too little to the version change and the expected list' {
        $text = Get-LiveFailureText -Kind 'ReadOnly' -Message 'mcpo serves /write_file.'
        $text | Should -Match '/write_file'
        $text | Should -Match 'version change'
        $text | Should -Match 'Get-LiveReadOnlyTool'
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
        # spec.json from its folder, or spec-open.json when mcpo.json hides no tool, follows mode.txt, adds its port
        # and PID to started.txt, and what mcpo.json hides and whether it passes --read-only to config.txt. As the real server
        # does, it lists the folder that the mcpo.json named by --config gives, then those in extra.txt; with mode
        # KeepFolder it lists the folder of its first start instead, as an mcpo that kept its old settings would.
        $standInDir = Join-Path $TestDrive 'stand-in'
        $null = New-Item -ItemType Directory -Path $standInDir
        $standIn = Join-Path $standInDir 'mcpo.exe'
        Add-Type -OutputType ConsoleApplication -OutputAssembly $standIn -ReferencedAssemblies 'System.Web.Extensions' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Web.Script.Serialization;

public static class McpoStandIn {
    public static int Main(string[] args) {
        int port = 0;
        string config = null;
        for (int i = 0; i + 1 < args.Length; i++) {
            if (args[i] == "--port") { port = int.Parse(args[i + 1]); }
            if (args[i] == "--config") { config = args[i + 1]; }
        }
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        string started = Path.Combine(folder, "started.txt");
        int earlier = File.Exists(started) ? File.ReadAllLines(started).Length : 0;
        File.AppendAllText(started, port + " " + System.Diagnostics.Process.GetCurrentProcess().Id + Environment.NewLine);
        string mode = File.ReadAllText(Path.Combine(folder, "mode.txt")).Trim();
        if (mode == "ExitAlways" || (mode == "ExitFirst" && earlier == 0)) { return 3; }
        if (mode == "NoRoutes") { Console.Error.WriteLine("The node server did not start."); }
        JavaScriptSerializer json = new JavaScriptSerializer();
        Dictionary<string, object> servers = (Dictionary<string, object>)((Dictionary<string, object>)json.DeserializeObject(File.ReadAllText(config)))["mcpServers"];
        Dictionary<string, object> files = (Dictionary<string, object>)servers["files"];
        object[] serverArgs = (object[])files["args"];
        string root = (string)serverArgs[serverArgs.Length - 1];
        int hidden = files.ContainsKey("disabledTools") ? ((object[])files["disabledTools"]).Length : 0;
        File.AppendAllText(Path.Combine(folder, "config.txt"), "hidden=" + hidden + " read-only=" + (Array.IndexOf(serverArgs, "--read-only") >= 0) + Environment.NewLine);
        string roots = Path.Combine(folder, "folders.txt");
        File.AppendAllText(roots, root + Environment.NewLine);
        if (mode == "KeepFolder") { root = File.ReadAllLines(roots)[0]; }
        List<string> lines = new List<string>();
        lines.Add("Allowed directories:");
        lines.Add(root);
        foreach (string extra in File.ReadAllLines(Path.Combine(folder, "extra.txt"))) { if (extra.Trim().Length > 0) { lines.Add(extra); } }
        byte[] spec = File.ReadAllBytes(Path.Combine(folder, hidden == 0 ? "spec-open.json" : "spec.json"));
        byte[] listed = Encoding.UTF8.GetBytes(json.Serialize(string.Join("\n", lines.ToArray())));
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
        # Returns @{ Code; Said; Last; Work; Started (one 'port PID' line per start); Folders and Configs (one per start that served) }.
        function Invoke-StandInCheck {
            param([hashtable]$Change = @{}, [int]$StopTimeoutSeconds = 10, [int]$StartTimeoutSeconds = 30)
            $answer = @{ Version = $serverVersion; Tools = $allowedTools; OpenTools = $readOnlyTools; ExtraFolders = @(); Mode = 'Serve' }
            foreach ($key in $Change.Keys) { $answer[$key] = $Change[$key] }
            $work = Join-Path $TestDrive ('work-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            foreach ($file in @{ 'spec.json' = $answer.Tools; 'spec-open.json' = $answer.OpenTools }.GetEnumerator()) {
                $routes = @{}
                foreach ($tool in $file.Value) { $routes["/$tool"] = @{ post = @{ operationId = $tool } } }
                $spec = ConvertTo-Json -Depth 6 -InputObject @{ openapi = '3.1.0'; info = @{ title = 'secure-filesystem-server'; version = $answer.Version }; paths = $routes }
                [IO.File]::WriteAllText((Join-Path $standInDir $file.Key), $spec)
            }
            [IO.File]::WriteAllText((Join-Path $standInDir 'extra.txt'), (@($answer.ExtraFolders) -join "`r`n"))
            [IO.File]::WriteAllText((Join-Path $standInDir 'mode.txt'), $answer.Mode)
            $startedFile = Join-Path $standInDir 'started.txt'
            Remove-Item -LiteralPath $startedFile, (Join-Path $standInDir 'folders.txt'), (Join-Path $standInDir 'config.txt') -Force -ErrorAction SilentlyContinue
            $script:said = New-Object System.Collections.Generic.List[string]
            Mock Write-Host { $script:said.Add([string]$Object) }
            $code = Invoke-LiveCheck -RepoRoot $repoRoot -WorkRoot $work -ToolCache 'unused' -StartTimeoutSeconds $StartTimeoutSeconds -StopTimeoutSeconds $StopTimeoutSeconds
            return @{
                Code    = $code
                Said    = ($script:said -join "`n")
                Last    = $script:said[$script:said.Count - 1]
                Work    = $work
                Started = @(if (Test-Path -LiteralPath $startedFile) { Get-Content -LiteralPath $startedFile })
                Folders = @(if (Test-Path -LiteralPath (Join-Path $standInDir 'folders.txt')) { Get-Content -LiteralPath (Join-Path $standInDir 'folders.txt') })
                Configs = @(if (Test-Path -LiteralPath (Join-Path $standInDir 'config.txt')) { Get-Content -LiteralPath (Join-Path $standInDir 'config.txt') })
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
        $run.Started.Count | Should -Be 3 -Because 'the restart and the read-only check start mcpo once more each'
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
        $run.Started.Count | Should -Be 4 -Because 'two first starts, the restart and the read-only check'
        ($run.Started[0] -split ' ')[0] | Should -Not -Be ($run.Started[1] -split ' ')[0]
        Test-StandInGone $run.Started | Should -BeTrue
    }

    It 'tries once more on a new port when another program holds the first before start looks' {
        $holder = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $holder.Start()
        try {
            $script:heldPort = ([Net.IPEndPoint]$holder.LocalEndpoint).Port
            $script:ports = 0
            # The second port asked for is the first start's.
            Mock Get-LiveFreePort {
                $script:ports++
                if ($script:ports -eq 2) { return $script:heldPort }
                $probe = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
                $probe.Start()
                try { ([Net.IPEndPoint]$probe.LocalEndpoint).Port } finally { $probe.Stop() }
            }
            $run = Invoke-StandInCheck
        } finally {
            $holder.Stop()
        }
        $run.Code | Should -Be 0 -Because $run.Said
        $run.Said | Should -Match "mcpo could not start on port $($script:heldPort), so it gets one more try"
        $run.Started.Count | Should -Be 3 -Because 'start refused the held port, so mcpo started on the second, then for the restart and the read-only check'
        ($run.Started[0] -split ' ')[0] | Should -Not -Be ([string]$script:heldPort)
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
        $run.Started.Count | Should -Be 4 -Because 'two first starts, the restart and the read-only check'
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

    It 'fails a check that passed when the last mcpo cannot be stopped, and ends it itself' {
        $script:stops = 0
        # The first stop ends the restarted mcpo before the read-only start; the last one throws.
        Mock Stop-LocalAIService {
            $script:stops++
            if ($script:stops -ge 2) { throw 'Get-NetTCPConnection failed.' }
            $null = & taskkill.exe /PID $Record.Pid /T /F 2>&1
            'stopped'
        }
        $run = Invoke-StandInCheck -StopTimeoutSeconds 1
        $run.Code | Should -Be 1
        $run.Last | Should -BeExactly 'LIVE CHECK: mcpo answered correctly, but could not be stopped.'
        $script:stops | Should -Be 2
        Test-StandInGone $run.Started | Should -BeTrue
        Test-Path -LiteralPath $run.Work | Should -BeFalse
    }

    It 'still ends mcpo and removes its folder when the stop throws' {
        Mock Stop-LocalAIService { throw 'Get-NetTCPConnection failed.' }
        $run = Invoke-StandInCheck -StopTimeoutSeconds 1
        $run.Code | Should -Be 1
        $run.Last | Should -Match 'The restarted mcpo could not be stopped, so the start with --read-only alone did not run\.'
        $run.Last | Should -Match 'Look at the stop code'
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

    Context 'the restart after a settings change' {
        It 'restarts mcpo through start''s own code on the same port, and the new one serves only the new folder' {
            $run = Invoke-StandInCheck
            $run.Code | Should -Be 0 -Because $run.Said
            $run.Started.Count | Should -Be 3
            ($run.Started[1] -split ' ')[0] | Should -Be ($run.Started[0] -split ' ')[0] -Because 'only Files.Root changed'
            $run.Folders[0] | Should -BeLike '*\root'
            $run.Folders[1] | Should -BeLike '*\root2'
            $run.Said | Should -Match "The file tools' settings changed since mcpo started, so start restarts it\."
            $run.Last | Should -Match 'restarted it for a new folder'
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }

        It 'fails naming the restart when start reuses mcpo, as it does when the second mcpo.json is the first' {
            $script:configs = 0
            Mock New-McpoConfig {
                $script:configs++
                if ($script:configs -eq 1) {
                    $given = @{ Settings = $Settings; Path = $Path; NodePath = $NodePath; ServerScript = $ServerScript }
                    $script:firstEntry = & (Get-Module LocalAI) { param($Given) New-McpoConfig @Given } $given
                }
                $script:firstEntry
            }
            $run = Invoke-StandInCheck
            $run.Code | Should -Be 1
            $run.Last | Should -Match '^LIVE CHECK: the restart after a settings change failed\.'
            $run.Last | Should -Match 'did not restart mcpo'
            $run.Started.Count | Should -Be 1
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }

        It 'fails naming the restart when the old mcpo does not stop' {
            Mock -ModuleName LocalAI Stop-LocalAIService { 'failed' }
            $run = Invoke-StandInCheck
            $run.Code | Should -Be 1
            $run.Last | Should -Match '^LIVE CHECK: the restart after a settings change failed\.'
            $run.Last | Should -Match 'mcpo did not stop for its restart'
            $run.Started.Count | Should -Be 1
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }

        It 'fails when the stop for the restart says in red that it failed, although a second try worked' {
            $script:moduleStops = 0
            Mock -ModuleName LocalAI Stop-LocalAIService {
                $script:moduleStops++
                if ($script:moduleStops -gt 1) { return 'stale' }
                $null = & taskkill.exe /PID $Record.Pid /T /F 2>&1
                Wait-Process -Id $Record.Pid -Timeout 5 -ErrorAction SilentlyContinue
                # In the module, where this test's own stand-in for Write-Host does not reach, as for the real stop.
                & (Get-Module LocalAI) { Write-Host 'Files (PID 1) still runs, or port 1 is still held, 10 s after taskkill.' -ForegroundColor Red }
                'failed'
            }
            $run = Invoke-StandInCheck
            $run.Code | Should -Be 1
            $run.Last | Should -Match '^LIVE CHECK: the restart after a settings change failed\.'
            $run.Last | Should -Match 'said in red: Files \(PID 1\) still runs'
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }

        It 'fails when the new mcpo still lists the old folder' {
            $run = Invoke-StandInCheck -Change @{ Mode = 'KeepFolder' }
            $run.Code | Should -Be 1
            $run.Last | Should -Match '^LIVE CHECK: the restart after a settings change failed\.'
            $run.Last | Should -Match "folders '[^']*\\root', not Files\.Root [^ ]*\\root2 alone"
            $run.Started.Count | Should -Be 2
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }

        It 'fails when the old mcpo still runs after a restart that start reported' {
            Mock Test-RecordedProcess { $true }
            $run = Invoke-StandInCheck
            $run.Code | Should -Be 1
            $run.Last | Should -Match '^LIVE CHECK: the restart after a settings change failed\.'
            $run.Last | Should -Match 'The old mcpo \(PID \d+\) still runs'
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }
    }

    Context 'the read-only flag alone' {
        It 'starts mcpo once more on a new port with --read-only and no hidden tools, and passes with exactly the ten read tools' {
            $run = Invoke-StandInCheck
            $run.Code | Should -Be 0 -Because $run.Said
            $run.Started.Count | Should -Be 3
            ($run.Started[2] -split ' ')[0] | Should -Not -Be ($run.Started[1] -split ' ')[0]
            $run.Configs[0] | Should -Be "hidden=$($defaults.Files.DisabledTools.Count) read-only=True"
            $run.Configs[2] | Should -Be 'hidden=0 read-only=True'
            $run.Folders[2] | Should -BeLike '*\root2'
            $run.Last | Should -Match '--read-only alone withholds every tool but the 10 read tools\.$'
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }

        It 'fails naming <Name>, and cleans up' -ForEach @(
            @{ Name = 'a write tool'; Change = @{ OpenTools = @($discoveredReadOnly) + 'write_file' }; Expected = '/write_file' }
            @{ Name = 'a tool it does not know'; Change = @{ OpenTools = @($discoveredReadOnly) + 'zip_files' }; Expected = '/zip_files' }
            @{ Name = 'a missing read tool'; Change = @{ OpenTools = @($discoveredReadOnly | Where-Object { $_ -ne 'directory_tree' }) }; Expected = "not '/directory_tree" }
        ) {
            $run = Invoke-StandInCheck -Change $Change
            $run.Code | Should -Be 1
            $run.Last | Should -Match '^LIVE CHECK: with --read-only alone and no hidden tools'
            $run.Last | Should -Match $Expected
            $run.Started.Count | Should -Be 3
            Test-StandInGone $run.Started | Should -BeTrue
            Test-Path -LiteralPath $run.Work | Should -BeFalse
        }
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
