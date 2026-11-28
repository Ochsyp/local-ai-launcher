# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS: STATUS
# -------------------------------------------------------
#
# Pester 6 tests for src\LocalAI.psm1 for status: Get-LocalAIStatus and its helpers, the shortcuts,
# local-ai.cmd and Confirm-LocalAIAction. tests\LocalAI.TestSetup.ps1 imports the module and holds
# the shared helpers.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LocalAI.TestSetup.ps1')
}

Describe 'Get-LocalAIStatus' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent

        # Return @{ <service name> = @{ EnvironmentSha256; ConfigSha256 } } as a start that brings every service up records them for $Settings, $Paths,
        # the stamp $Stamp and the key $Key. Built the way Start-LocalAI builds its table, with the real image workflow and mcpo.json's entry, and not
        # through status's own code, so a status that hashes anything else shows an advice line on a healthy stack.
        function Get-TestStartHash([hashtable]$Settings, [hashtable]$Paths, [hashtable]$Stamp, [string]$Key) {
            & (Get-Module LocalAI) {
                param($Settings, $Paths, $Stamp, $Key, $RepoRoot)
                $record = $Stamp.Files
                $server = Get-McpoServerEntry -Settings $Settings -NodePath $record.Node.Path -ServerScript $record.Script
                $files = @{ McpoPath = $record.McpoPath; McpoVersion = $record.McpoVersion; Key = $Key; Server = $server
                    ServerVersion = $record.ServerVersion; LockSha256 = $record.LockSha256 }
                $workflow = Get-ImageWorkflow -Settings $Settings -RepoRoot $RepoRoot
                $hashes = @{}
                foreach ($service in @(Get-LocalAIService -Settings $Settings -Paths $Paths -OllamaUrl (Resolve-OllamaUrl -Setting $Settings.Ollama.Url) `
                            -OpenWebUI $Stamp.OpenWebUI -ComfyUI $Stamp.ComfyUI -ImageWorkflow $workflow -Files $files -WarningAction SilentlyContinue)) {
                    $hashes[$service.Name] = @{
                        EnvironmentSha256 = (Get-LocalAIEnvironmentHash -Environment $service.Environment -InheritEnvironment $service.InheritEnvironment)
                        ConfigSha256      = $service.ConfigSha256
                    }
                }
                $hashes
            } $Settings $Paths $Stamp $Key $repoRoot
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Ports.OpenWebUI = 18431
        $settings.Ports.ComfyUI = 18432
        $settings.Ports.Files = 18433
        $settings.Ports.ImageGate = 18434
        $settings.OpenWebUI.DataDir = Join-Path $root 'open-webui'
        $settings.ComfyUI.Dir = Join-Path $root 'ComfyUI'
        $settings.Shortcuts.Folder = Join-Path $root 'menu'
        $settings.Files.Root = Join-Path $TestDrive "$leaf-files"
        $null = Write-TestFile "$leaf-files\notes.txt" 'notes'
        $key = Get-FilesKey -Path $paths.FilesKey -Create
        $stamp = @{
            Ollama    = @{ Version = '0.40.11' }
            Model     = @{ Alias = 'local-chat'; BaseDigest = $settings.Model.Sha256; ProjectorDigest = $settings.Model.ProjectorSha256
                ModelfileSha256 = (Get-TestFileSha256 (Join-Path $repoRoot $settings.Model.Modelfile)) }
            OpenWebUI = @{ Version = '0.12.4'; Path = 'C:\uv\bin\open-webui.exe'; Python = '3.12.16'; ExcludeNewer = $settings.OpenWebUI.ExcludeNewer }
            ComfyUI   = @{ Dir = $settings.ComfyUI.Dir; Commit = $settings.ComfyUI.Commit; Python = (Join-Path $settings.ComfyUI.Dir '.venv\Scripts\python.exe') }
            Files     = @{ McpoVersion = '0.0.20'; McpoPath = 'C:\uv\bin\mcpo.exe'; Python = '3.12'; With = @($settings.Files.McpoWith)
                ExcludeNewer = $settings.Files.McpoExcludeNewer; ServerVersion = $settings.Files.ServerVersion; ToolDir = 'C:\uv\tools'
                LockSha256 = (Get-TestFileSha256 (Join-Path $repoRoot 'config\files-server\package-lock.json'))
                Script = (Join-Path $root 'files-server\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js')
                Node = @{ Path = 'C:\nodejs\node.exe'; Version = '24.22.1' } }
        }
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        # A checkout at the pin with origin ComfyUI.Repo, whose venv marker is what Install-ComfyUI writes for it (it holds no requirements.txt).
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $settings.ComfyUI.Dir '.git')
        $venvMarker = @{ RequirementsSha256 = ''; ConstraintsSha256 = (Get-TestFileSha256 (Join-Path $repoRoot $settings.ComfyUI.Constraints)); Backend = $settings.ComfyUI.TorchBackend
            ExcludeNewer = $settings.ComfyUI.ExcludeNewer; Torch = '2.14.1+cu130'; CreatedVenv = $true }
        Write-LocalAIState -Path (Join-Path $settings.ComfyUI.Dir '.venv\local-ai-install.json') -State $venvMarker
        $git = Get-FakeGit -Head $settings.ComfyUI.Commit -Commit $settings.ComfyUI.Commit
        $git.Origin = $settings.ComfyUI.Repo
        $started = [DateTime]::UtcNow.AddMinutes(-90).Ticks
        $records = @{}
        $pids = @{ OpenWebUI = 4100; ComfyUI = 4200; ImageGate = 4300; Files = 4400 }
        foreach ($name in $pids.Keys) {
            $records[$name] = @{ Pid = $pids[$name]; StartTicks = $started; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = $settings.Ports[$name]
                OutLog = (Join-Path $paths.Logs "$name.log"); ErrLog = (Join-Path $paths.Logs "$name.err.log") }
        }
        $records.OpenWebUI.Listener = @{ Pid = 4101; StartTicks = $started; Path = 'C:\uv\python\python.exe' }
        # What a start with these settings recorded, so no service runs with older settings.
        $hashes = Get-TestStartHash -Settings $settings -Paths $paths -Stamp $stamp -Key $key
        foreach ($name in $pids.Keys) { $records[$name].EnvironmentSha256 = $hashes[$name].EnvironmentSha256 }
        $records.Files.ConfigSha256 = $hashes.Files.ConfigSha256
        Write-LocalAIState -Path $paths.State -State @{ Services = $records; Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat' } }
        $context = @{ Verb = 'status'; Paths = $paths; Settings = $settings; SettingsError = $null; RepoRoot = $repoRoot; Json = $false }
        $world = @{
            Live      = New-Object System.Collections.Generic.List[int]
            Listeners = @{ 11434 = @('127.0.0.1'); 18431 = @('127.0.0.1'); 18432 = @('127.0.0.1'); 18433 = @('127.0.0.1'); 18434 = @('127.0.0.1') }
            Owner     = $null
            Versions  = @{ OpenWebUI = '0.12.4'; ComfyUI = '0.42.5'; ImageGate = '1.0'; Files = $settings.Files.ServerVersion }
            Cuda      = $true
            Ollama    = '0.40.11'
            Loaded    = @([pscustomobject]@{ name = 'local-chat:latest'; size = 8040000000; size_vram = 8040000000; context_length = 32768
                    expires_at = '2026-01-15T10:30:00.1234567-07:00' })
            Tags      = @('local-chat:latest', 'hf.co/HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive:Q6_K')
            Gpu       = '555.85, 512, 8192'
            Page      = @{ Automatic = $false; Settings = @(@{ Name = 'C:\pagefile.sys'; InitialMB = 20480; MaximumMB = 20480 })
                Files = @(@{ Name = 'C:\pagefile.sys'; CurrentMB = 20480 }); CommitLimitBytes = 34359738368 }
            Policies  = @(foreach ($scope in 'MachinePolicy', 'UserPolicy', 'Process', 'CurrentUser') { [pscustomobject]@{ Scope = $scope; ExecutionPolicy = 'Undefined' } }) +
                @([pscustomobject]@{ Scope = 'LocalMachine'; ExecutionPolicy = 'RemoteSigned' })
            Marked    = @()
            Parts     = @()
            Served    = $true
            # What Get-LocalAIVersion finds in VERSION: none, as in a git checkout before the first release.
            Version   = $null
        }
        foreach ($id in 4100, 4101, 4200, 4300, 4400) { $world.Live.Add($id) }

        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($world.Live -contains [int]$Record.Pid) { 'match' } else { 'other' } }
        # Nothing at all, as Get-ListenerAddress returns for a free port.
        Mock Get-ListenerAddress -ModuleName LocalAI -MockWith { if ($world.Listeners.ContainsKey([int]$Port)) { $world.Listeners[[int]$Port] } }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { $world.Owner }
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
        Mock Get-OpenWebUIVersion -ModuleName LocalAI -MockWith { if ($world.Versions.OpenWebUI) { $world.Versions.OpenWebUI } else { throw 'Unable to connect to the remote server' } }
        Mock Get-ComfyUIVersion -ModuleName LocalAI -MockWith { if ($world.Versions.ComfyUI) { $world.Versions.ComfyUI } else { throw 'Unable to connect to the remote server' } }
        Mock Get-ImageGateVersion -ModuleName LocalAI -MockWith { $world.Versions.ImageGate }
        Mock Get-FilesServerVersion -ModuleName LocalAI -MockWith { $world.Versions.Files }
        Mock Test-ComfyUIDevice -ModuleName LocalAI -MockWith {
            if ($world.Cuda) { return $true }
            Write-Warning 'ComfyUI reports cpu (type cpu), not a CUDA GPU, so each image takes many minutes.'
            $false
        }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            if (-not $world.Ollama) { throw 'Unable to connect to the remote server' }
            switch -Wildcard ($Uri) {
                '*/api/version' { [pscustomobject]@{ version = $world.Ollama } }
                '*/api/ps' { [pscustomobject]@{ models = @($world.Loaded) } }
                '*/api/tags' { [pscustomobject]@{ models = @($world.Tags | ForEach-Object { [pscustomobject]@{ name = $_ } }) } }
                default { throw "Unexpected request to $Uri" }
            }
        }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'nvidia-smi' } -MockWith {
            if (-not $world.Gpu) { throw "Cannot find the program 'nvidia-smi'." }
            $Capture.Add($world.Gpu)
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' } -MockWith $fakeGit
        Mock Get-PageFileStatus -ModuleName LocalAI -MockWith { $world.Page }
        Mock Get-ExecutionPolicy -ModuleName LocalAI -MockWith { $world.Policies }
        Mock Get-ZoneMarkedFile -ModuleName LocalAI -MockWith { $world.Marked }
        Mock Find-LocalAIFile -ModuleName LocalAI -ParameterFilter { $Extension -contains '.part' } -MockWith {
            $world.Parts | Where-Object { $_.FullName.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) }
        }
        # Not this PC's %USERPROFILE%\.qwen\settings.json.
        Mock Get-QwenCodeModel -ModuleName LocalAI
        # Not the VERSION file of this checkout.
        Mock Get-LocalAIVersion -ModuleName LocalAI -MockWith { $world.Version }
        Mock Test-FilesRoot -ModuleName LocalAI -MockWith {
            if ($world.Served) { return $true }
            Write-Warning "Files.Root '$($Settings.Files.Root)' is not served, so the file tools are off: it holds 1 file(s) or folder(s) whose names match Files.DenyPatterns: id_rsa."
            $false
        }
        # status changes nothing.
        Mock Write-LocalAIState -ModuleName LocalAI -MockWith { throw 'status wrote a state file' }
        Mock Start-LocalAIService -ModuleName LocalAI -MockWith { throw 'status started a service' }
        Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { throw 'status stopped a service' }
        Mock Start-Process -ModuleName LocalAI -MockWith { throw 'status started a program' }
    }

    It 'returns 0 and prints every service, Ollama, the GPU and the pins when everything runs as pinned' {
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeNullOrEmpty
        $run.Other | Should -BeNullOrEmpty
        $run.Printed | Should -BeLike '*Ollama 0.40.11 answers at http://127.0.0.1:11434.*It listens on 127.0.0.1 port 11434 only.*'
        # In this PC's time zone, whichever it is.
        $until = [DateTimeOffset]::Parse('2026-01-15T10:30:00.1234567-07:00', [Globalization.CultureInfo]::InvariantCulture).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        $run.Printed | Should -BeLike "*Loaded: local-chat:latest, 7.5 GB, 100 percent of it in VRAM, context 32768, unloads at $until.*"
        $run.Printed | Should -BeLike '*Ollama holds local-chat.*'
        $run.Printed | Should -BeLike ('*Open WebUI: 0.12.4 runs at http://127.0.0.1:18431 (PID 4100, listener PID 4101, up 1 h 30 min), listening on 127.0.0.1, ' +
            'the pinned version.*')
        $run.Printed | Should -BeLike "*ComfyUI: 0.42.5 runs at http://127.0.0.1:18432 (PID 4200, up 1 h 30 min), listening on 127.0.0.1; install recorded ComfyUI $($settings.ComfyUI.Commit), as ComfyUI.Commit pins.*"
        $run.Printed | Should -BeLike '*Image gate: 1.0 runs at http://127.0.0.1:18434 (PID 4300, up 1 h 30 min)*'
        $run.Printed | Should -BeLike ("*File tools: server-filesystem $($settings.Files.ServerVersion) runs at http://127.0.0.1:18433 (PID 4400, up 1 h 30 min), " +
            'listening on 127.0.0.1; install recorded mcpo 0.0.20, as Files.McpoVersion pins.*')
        $run.Printed | Should -BeLike '*NVIDIA driver 555.85; 512 of 8192 MiB of VRAM in use.*'
        $run.Printed | Should -BeLike "*Files.Root $($settings.Files.Root) passes the checks start runs*"
        $run.Printed | Should -BeLike '*Everything install-stamp.json records matches its pin.*'
        $run.Printed | Should -BeLike '*Page file: C:\pagefile.sys 20480 to 20480 MB; now C:\pagefile.sys 20480 MB. Commit limit 32.0 GB.*'
        $run.Printed | Should -Not -BeLike '*Advice:*'
        $run.Printed | Should -BeLike '*Status: everything the settings turn on runs and is healthy.'
        Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Key -eq $key -and $Url -eq 'http://127.0.0.1:18433' }
        $run.Printed | Should -Not -BeLike "*$key*"
        Should -Invoke Test-ComfyUIDevice -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Url -eq 'http://127.0.0.1:18432' }
    }

    It 'never writes state.json, the stamp, the settings or the key, and never starts or stops anything' {
        $null = Write-TestFile ((Split-Path $root -Leaf) + '\settings.psd1') '@{ }'
        $files = @($paths.State, $paths.InstallStamp, $paths.Settings, $paths.FilesKey)
        $before = @(foreach ($file in $files) { '{0}|{1}' -f (Get-TestFileSha256 $file), (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks })
        $world.Live.Clear()
        $world.Ollama = $null
        $null = Invoke-StatusVerb -Context $context
        $null = Invoke-StatusVerb -Context $context
        @(foreach ($file in $files) { '{0}|{1}' -f (Get-TestFileSha256 $file), (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks }) | Should -Be $before
        Should -Invoke Write-LocalAIState -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-Process -ModuleName LocalAI -Times 0 -Exactly
        # Only nvidia-smi, and git reading ComfyUI's origin.
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -ne 'nvidia-smi' -and $FilePath -ne 'git' }
        @($git.Calls | Select-Object -Unique) | Should -Be @('config --get remote.origin.url')
    }

    It 'returns 1 and prints in red that Open WebUI does not run when its recorded process has exited' {
        foreach ($id in 4100, 4101) { $null = $world.Live.Remove($id) }
        $world.Listeners.Remove(18431)
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Open WebUI: not running (state.json still records PID 4100, listener PID 4101, which has exited). Run 'local-ai start'.*"
        $run.Printed | Should -BeLike '*Status: Ollama or Open WebUI is down; see above.'
        Should -Invoke Get-OpenWebUIVersion -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'returns 1 when Open WebUI runs but does not answer as Open WebUI' {
        $world.Versions.OpenWebUI = $null
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Open WebUI: runs (PID 4100, listener PID 4101), but does not answer at http://127.0.0.1:18431 as Open WebUI: Unable to connect*'
    }

    It 'returns 1 when Open WebUI runs but does not listen yet, naming its logs' {
        $world.Listeners.Remove(18431)
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Open WebUI: runs (PID 4100, listener PID 4101), but nothing listens on port 18431: it may still be starting*Its logs are $($paths.Logs)\open-webui.err.log*"
    }

    It 'returns 1 when Ollama does not answer, without asking it anything else' {
        $world.Ollama = $null
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Ollama does not answer at http://127.0.0.1:11434/api/version (Unable to connect to the remote server). Start the Ollama app*"
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'names the program that holds a port the launcher did not start, and what it answers as' {
        foreach ($id in 4100, 4101) { $null = $world.Live.Remove($id) }
        $world.Versions.OpenWebUI = '0.12.3'
        $world.Owner = [pscustomobject]@{ Id = 9100; Name = 'python'; Path = 'C:\old\python.exe'; StartTicks = 5 }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike ("*Open WebUI: not running (state.json still records PID 4100, listener PID 4101, which has exited). Port 18431 is held by python " +
            "(PID 9100, C:\old\python.exe), which this launcher did not start, and it answers as Open WebUI 0.12.3. Close that program, or set Ports.OpenWebUI " +
            "in settings.psd1, then run 'local-ai start'.*")
        $run.Printed | Should -Not -BeLike "*it answers as Open WebUI 0.12.3. Run 'local-ai start'.*"
    }

    It 'returns 2 with a warning when an optional service is down' {
        $null = $world.Live.Remove(4200)
        $world.Listeners.Remove(18432)
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*ComfyUI: not running (state.json still records PID 4200, which has exited). Run 'local-ai start'.*"
        $run.Printed | Should -BeLike '*Status: degraded, with 1 warning(s); see above.'
    }

    It 'returns 2 when a service has no record at all' {
        $state = Read-LocalAIState -Path $paths.State
        $state.Services.Remove('Files')
        [IO.File]::WriteAllText($paths.State, (ConvertTo-Json -InputObject $state -Depth 6))
        $world.Listeners.Remove(18433)
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*File tools: not running. Run 'local-ai start'.*"
    }

    It 'returns 2 when <Name> listens beyond loopback' -ForEach @(
        @{ Name = 'ComfyUI'; Port = 18432; Address = '0.0.0.0'; Message = '*ComfyUI: IS OPEN TO THE NETWORK: port 18432 listens on 0.0.0.0, not only on 127.0.0.1 or ::1*' }
        @{ Name = 'Ollama'; Port = 11434; Address = '::'; Message = "*Ollama IS OPEN TO THE NETWORK: port 11434 listens on ::, not only on 127.0.0.1 or ::1*Turn off 'Expose Ollama to the network'*" }
    ) {
        $world.Listeners[$Port] = @('127.0.0.1', $Address)
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike $Message
    }

    It 'returns 2 when a loaded model is not wholly in VRAM, and lists its context and unload time' {
        $world.Loaded = @([pscustomobject]@{ name = 'local-chat:latest'; size = 8000000000; size_vram = 6000000000; context_length = 32768; expires_at = 'soon' })
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Loaded: local-chat:latest, 7.5 GB, 75 percent of it in VRAM, context 32768, unloads at soon.*'
        $run.Warnings | Should -BeLike "*local-chat:latest has only 75 percent of its 7.5 GB in VRAM, so the rest runs on the CPU*'ollama stop local-chat:latest'*"
    }

    It 'says when no model is loaded' {
        $world.Loaded = @()
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*No model is loaded.*'
    }

    It 'returns 2 when Ollama has no Model.Alias' {
        $world.Tags = @('other:latest')
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*Ollama has no model 'local-chat', so chat cannot answer. Run 'local-ai install' to create it.*"
    }

    It 'notes a superseded alias Ollama still holds without changing the exit code, and none while the list is empty' {
        $world.Tags += 'old-chat:latest'
        $run = Invoke-StatusVerb -Context $context
        $run.Printed | Should -Not -BeLike '*superseded alias*'
        $settings.Model.SupersededAliases = @('old-chat', 'gone-chat')
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*Ollama still holds the superseded alias old-chat; 'local-ai update' offers to remove it.*"
        $run.Printed | Should -Not -BeLike '*gone-chat*'
    }

    It 'notes the Ollama version install recorded when another one runs' {
        $world.Ollama = '0.40.12'
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Ollama 0.40.12 answers at http://127.0.0.1:11434; install recorded 0.40.11.*'
    }

    It 'says the Ollama app was not started by local-ai when state.json records none, in the text and in -Json' {
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Ollama 0.40.11 answers at http://127.0.0.1:11434.*Not started by local-ai; local-ai stop leaves it running.*'
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.ollama.startedByLauncher | Should -BeFalse
        $document.ollama.ContainsKey('appPid') | Should -BeTrue
        $document.ollama.appPid | Should -BeNullOrEmpty
        $document.ollama.appStartedUtc | Should -BeNullOrEmpty
    }

    It 'says local-ai started the Ollama app, so stop quits it, with its PID and start time in -Json' {
        $state = Read-LocalAIState -Path $paths.State
        $state.Ollama['App'] = @{ Pid = 4600; StartTicks = $started; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; How = 'start' }
        Write-LocalAIState -Path $paths.State -State $state
        $world.Live.Add(4600)
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Started by local-ai (app PID 4600); local-ai stop quits it.*'
        $run.Printed | Should -Not -BeLike '*Not started by local-ai*'
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.ollama.startedByLauncher | Should -BeTrue
        $document.ollama.appPid | Should -Be 4600
        $document.ollama.appStartedUtc | Should -Be ([datetime]::new($started, [DateTimeKind]::Utc).ToString('o', [Globalization.CultureInfo]::InvariantCulture))
    }

    It 'says the Ollama at Ollama.Url was not started by local-ai when state.json records the app for <Case>, naming that app' -ForEach @(
        @{ Case = 'another port'; Url = ''; Port = 11500; Expected = 'http://127.0.0.1:11434' }
        @{ Case = 'this PC while Ollama.Url names another computer on the same port'; Url = 'http://192.0.2.20:11434'; Port = 11434; Expected = 'http://192.0.2.20:11434' }
    ) {
        # 192.0.2.20 stands for another computer.
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $HostName -ne '192.0.2.20' }
        $settings.Ollama.Url = $Url
        $state = Read-LocalAIState -Path $paths.State
        $state.Ollama['App'] = @{ Pid = 4600; StartTicks = $started; Path = 'C:\Ollama\ollama app.exe'; Port = $Port; How = 'start' }
        Write-LocalAIState -Path $paths.State -State $state
        $world.Live.Add(4600)
        $run = Invoke-StatusVerb -Context $context
        $run.Printed | Should -BeLike ("*Ollama 0.40.11 answers at $Expected.*state.json records an Ollama app local-ai started (PID 4600) for port $Port on this PC, " +
            "not for $Expected; local-ai stop quits it.*Not started by local-ai; local-ai stop leaves it running.*")
        $run.Printed | Should -Not -BeLike '*Started by local-ai (app PID 4600)*'
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.ollama.startedByLauncher | Should -BeFalse
        $document.ollama.appPid | Should -BeNullOrEmpty
        $document.ollama.appStartedUtc | Should -BeNullOrEmpty
        Should -Invoke Write-LocalAIState -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'notes a stale app record without changing the exit code, and leaves it for stop to drop' {
        $state = Read-LocalAIState -Path $paths.State
        $state.Ollama['App'] = @{ Pid = 4600; StartTicks = $started; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; How = 'start' }
        Write-LocalAIState -Path $paths.State -State $state
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike ('*state.json records an Ollama app local-ai started (PID 4600), but it no longer runs, or was restarted by an update or by you; ' +
            'local-ai stop drops that record.*Not started by local-ai; local-ai stop leaves it running.*')
        Should -Invoke Write-LocalAIState -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 4600
    }

    It 'returns 2 when ComfyUI renders on the CPU' {
        $world.Cuda = $false
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike '*ComfyUI reports cpu (type cpu), not a CUDA GPU*'
    }

    It 'returns 2 when nvidia-smi is missing' {
        $world.Gpu = $null
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*nvidia-smi cannot report the GPU (Cannot find the program 'nvidia-smi'.), so Ollama and ComfyUI may run on the CPU.*"
    }

    It 'reports OLLAMA_KV_CACHE_TYPE from this process' {
        $saved = $env:OLLAMA_KV_CACHE_TYPE
        try {
            $env:OLLAMA_KV_CACHE_TYPE = 'q8_0'
            $run = Invoke-StatusVerb -Context $context
        } finally {
            $env:OLLAMA_KV_CACHE_TYPE = $saved
        }
        $run.Printed | Should -BeLike "*OLLAMA_KV_CACHE_TYPE is 'q8_0' in this window and * in the User environment*unset means f16.*"
    }

    It 'returns 2 with the reason when Files.Root is not served' {
        $world.Served = $false
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*Files.Root '*' is not served, so the file tools are off: *id_rsa.*"
    }

    It 'says the file tools are off without running the folder check when Files.Root is empty' {
        $settings.Files.Root = ''
        $state = Read-LocalAIState -Path $paths.State
        $state.Services.Remove('Files')
        [IO.File]::WriteAllText($paths.State, (ConvertTo-Json -InputObject $state -Depth 6))
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*The file tools are off: Files.Root is empty.*'
        Should -Invoke Test-FilesRoot -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'notes a service the settings leave out that still runs from an earlier start' {
        $settings.Files.Root = ''
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*File tools: still runs from an earlier start (PID 4400), although the settings now leave it out. 'local-ai stop' stops it.*"
    }

    It 'says which services the settings turn off' {
        $settings.Images.Enabled = $false
        $settings.Files.Root = ''
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = (Read-LocalAIState -Path $paths.State).Services.OpenWebUI } }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*ComfyUI and the image gate are off: Images.Enabled is $false.*The file tools are off: Files.Root is empty.*'
    }

    It 'returns 2 when a service runs but this window cannot inspect it' {
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ([int]$Record.Pid -eq 4200) { 'unreadable' } elseif ($world.Live -contains [int]$Record.Pid) { 'match' } else { 'other' } }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*ComfyUI: 0.42.5 runs at http://127.0.0.1:18432 (PID 4200)*'
        $run.Warnings | Should -BeLike "*ComfyUI: runs (PID 4200), but this window may not inspect it, as when it was started from an elevated window*"
    }

    It 'returns 2 when Open WebUI runs another version than the one install put in' {
        $world.Versions.OpenWebUI = '0.12.3'
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Open WebUI: 0.12.3 runs at *, but OpenWebUI.Version pins 0.12.4.*'
        $run.Warnings | Should -BeLike "*Open WebUI: 0.12.3 runs, but install has put in 0.12.4, the pin. Run 'local-ai stop', then 'local-ai start'*"
    }

    It 'returns 2 and names local-ai update when install recorded another <Case>' -ForEach @(
        @{ Case = 'Open WebUI version'; Part = 'OpenWebUI'; Field = 'Version'; Value = '0.12.3'; Message = '*Open WebUI 0.12.3 is installed, but OpenWebUI.Version pins 0.12.4. Run ''local-ai update''.*' }
        @{ Case = 'Open WebUI Python'; Part = 'OpenWebUI'; Field = 'Python'; Value = '3.11.17'; Message = '*Open WebUI runs on Python 3.11.17, but OpenWebUI.Python pins 3.12. Run ''local-ai update''.*' }
        @{ Case = 'Open WebUI cut-off it never recorded'; Part = 'OpenWebUI'; Field = 'ExcludeNewer'; Value = $null; Message = "*Open WebUI's packages were resolved at an unrecorded time, but OpenWebUI.ExcludeNewer pins *. Run 'local-ai update'.*" }
        @{ Case = 'Open WebUI cut-off'; Part = 'OpenWebUI'; Field = 'ExcludeNewer'; Value = '2026-10-01T00:00:00Z'; Message = "*Open WebUI's packages were resolved as of 2026-10-01T00:00:00Z, but OpenWebUI.ExcludeNewer pins *. Run 'local-ai update'.*" }
        @{ Case = 'ComfyUI commit'; Part = 'ComfyUI'; Field = 'Commit'; Value = 'abcdef0123456789abcdef0123456789abcdef01'; Message = '*ComfyUI in * is at commit abcdef0123456789abcdef0123456789abcdef01, but ComfyUI.Commit pins 483dae4326356b81de05d27aca3f433dd323cc25 (v0.42.5). Run ''local-ai update''.*' }
        @{ Case = 'mcpo version'; Part = 'Files'; Field = 'McpoVersion'; Value = '0.0.19'; Message = "*mcpo was installed with Files.McpoVersion '0.0.19', but settings.psd1 pins '0.0.20'. Run 'local-ai update'.*" }
        @{ Case = 'mcpo requirement list'; Part = 'Files'; Field = 'With'; Value = @('mcp==1.29.0'); Message = "*mcpo was installed with Files.McpoWith 'mcp==1.29.0', but settings.psd1 pins 'mcp==1.30.0 fastapi<0.145'.*" }
        @{ Case = 'files server version'; Part = 'Files'; Field = 'ServerVersion'; Value = '2.0.0'; Message = '*The files server 2.0.0 is installed, but Files.ServerVersion pins PINNED. Run ''local-ai update''.*' }
        @{ Case = 'files server lockfile'; Part = 'Files'; Field = 'LockSha256'; Value = ('0' * 64); Message = '*The files server was installed from another package-lock.json than *package-lock.json. Run ''local-ai update''.*' }
        @{ Case = 'model alias'; Part = 'Model'; Field = 'Alias'; Value = 'old-chat'; Message = '*install created the alias old-chat, but Model.Alias is local-chat.*' }
        @{ Case = 'model weights'; Part = 'Model'; Field = 'BaseDigest'; Value = ('a' * 64); Message = "*The weights install used have SHA-256 $('a' * 64), but Model.Sha256 pins *" }
        @{ Case = 'vision projector'; Part = 'Model'; Field = 'ProjectorDigest'; Value = ('b' * 64); Message = "*The vision projector install used has SHA-256 $('b' * 64)*" }
        @{ Case = 'Modelfile'; Part = 'Model'; Field = 'ModelfileSha256'; Value = ('c' * 64); Message = '*local-chat was created from another Modelfile than *local-chat.Modelfile. Run ''local-ai update''.*' }
    ) {
        # Not $Key, which BeforeEach sets to the mcpo key; variable names ignore case.
        $stamp[$Part][$Field] = $Value
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        # PINNED stands for Files.ServerVersion of config\defaults.psd1.
        $run.Warnings | Should -BeLike $Message.Replace('PINNED', $settings.Files.ServerVersion)
        $run.Printed | Should -Not -BeLike '*Everything install-stamp.json records matches its pin.*'
    }

    It 'judges the Modelfile in the launcher folder, which replaces the tracked one' {
        $own = Write-TestFile ((Split-Path $root -Leaf) + '\local-chat.Modelfile') "FROM $($settings.Model.Source)`r`nPARAMETER num_ctx 16384`r`n"
        $run = Invoke-StatusVerb -Context $context
        $run.Warnings | Should -BeLike "*local-chat was created from another Modelfile than $own.*"
    }

    It 'returns 2 and names local-ai install when install-stamp.json records no <What>' -ForEach @(
        @{ What = 'Open WebUI install'; Part = 'OpenWebUI' }
        @{ What = 'ComfyUI install, which Images.Enabled asks for'; Part = 'ComfyUI' }
        @{ What = 'file tools install, which Files.Root asks for'; Part = 'Files' }
        @{ What = 'chat model'; Part = 'Model' }
    ) {
        $stamp.Remove($Part)
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*install-stamp.json records no $What. Run 'local-ai install'.*"
    }

    It 'gives the doctor advice <Case> without changing the exit code' -ForEach @(
        @{ Case = 'for a Group Policy execution policy'; Message = '*Advice: Group Policy sets the execution policy AllSigned for MachinePolicy, which overrides the RemoteSigned*' }
        @{ Case = 'for scripts marked as downloaded'; Message = "*Advice: 1 launcher file(s) carry the Zone.Identifier mark*: tests\Config.Tests.ps1. Unblock them with: Get-ChildItem -LiteralPath '*' -Recurse -File | Unblock-File*" }
        @{ Case = 'for a system-managed page file'; Message = '*Page file: system-managed; now C:\pagefile.sys 4096 MB. Commit limit 19.1 GB.*Advice: Images.UnloadChat makes Ollama reload local-chat after every image*fixed page file of about 20 GB or more*' }
        @{ Case = 'for a fixed page file below 20 GB'; Message = '*Advice: Images.UnloadChat makes Ollama reload local-chat*' }
        @{ Case = 'for partial downloads'; Message = '*Advice: Partial downloads are left over: *half.safetensors.part (3 KB). Delete them once no download runs*' }
    ) {
        switch -Wildcard ($Case) {
            '*execution policy' { $world.Policies[0] = [pscustomobject]@{ Scope = 'MachinePolicy'; ExecutionPolicy = 'AllSigned' } }
            # A file status does not load, since a marked src\local-ai.ps1 or LocalAI.psm1 keeps status from running at all.
            '*downloaded' { $world.Marked = @(Join-Path $repoRoot 'tests\Config.Tests.ps1') }
            '*system-managed*' {
                $world.Page = @{ Automatic = $true; Settings = @(); Files = @(@{ Name = 'C:\pagefile.sys'; CurrentMB = 4096 }); CommitLimitBytes = 20480000000 }
            }
            '*below 20 GB' { $world.Page.Settings = @(@{ Name = 'C:\pagefile.sys'; InitialMB = 16384; MaximumMB = 32768 }) }
            '*partial downloads' { $world.Parts = @(Get-Item -LiteralPath (Write-TestFile ((Split-Path $root -Leaf) + '\ComfyUI\models\half.safetensors.part') ('x' * 3000))) }
        }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike $Message
    }

    It 'gives no page file advice while Images.UnloadChat is off' {
        $settings.Images.UnloadChat = $false
        $state = Read-LocalAIState -Path $paths.State
        $state.Services.Remove('ImageGate')
        [IO.File]::WriteAllText($paths.State, (ConvertTo-Json -InputObject $state -Depth 6))
        $world.Page = @{ Automatic = $true; Settings = @(); Files = @(); CommitLimitBytes = 20480000000 }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Page file: system-managed; now none in use.*'
        $run.Printed | Should -Not -BeLike '*Advice: Images.UnloadChat*'
    }

    It "reads nothing in Open WebUI's data folder and runs no Python, whatever it holds" {
        foreach ($name in 'webui.db', 'webui.db-wal', 'config.json') { $null = Write-TestFile ((Split-Path $root -Leaf) + "\open-webui\$name") 'x' }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -Not -BeLike '*webui.db*'
        $run.Printed | Should -Not -BeLike '*config.json*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -like '*python*' }
    }

    It 'lists the log files, the newest launcher log other than status ones with its last error, and mcpo''s session errors' {
        $logs = Split-Path $root -Leaf
        $start = Write-TestFile "$logs\logs\launcher-20261028-100000-000-start.log" "Transcript`r`nError: first`r`nwork`r`nError: Port 18431 is held.`r`nLog: x`r`n"
        $status = Write-TestFile "$logs\logs\launcher-20261028-110000-000-status.log" "Error: from status`r`n"
        (Get-Item -LiteralPath $start).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        (Get-Item -LiteralPath $status).LastWriteTimeUtc = [DateTime]::UtcNow
        $null = Write-TestFile "$logs\logs\files.err.log" "ERROR Session closed during call`r`nok`r`nERROR Session closed during call`r`n"
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*Open WebUI: $($paths.Logs)\open-webui.log, $($paths.Logs)\open-webui.err.log*"
        $run.Printed | Should -BeLike "*File tools: $($paths.Logs)\files.log, $($paths.Logs)\files.err.log*"
        $run.Printed | Should -BeLike "*Newest launcher log: $start, written *Its last error line: Error: Port 18431 is held.*"
        $run.Printed | Should -BeLike "*mcpo's error log $($paths.Logs)\files.err.log holds 2 'Session closed during call' line(s).*"
    }

    It 'prints exactly one line of JSON with -Json, holding the facts, the lines and the exit code but not the key' {
        $context.Json = $true
        $null = $world.Live.Remove(4200)
        $world.Listeners.Remove(18432)
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeNullOrEmpty
        $run.Other | Should -BeNullOrEmpty
        $run.Records.Count | Should -Be 1
        $text = [string]$run.Records[0].MessageData
        $text | Should -Not -Match '[^\x00-\x7F]'
        $text | Should -Not -Match '\r|\n'
        $text | Should -Not -BeLike "*$key*"
        $document = ConvertFrom-LocalAIJson -Text $text
        $document.verb | Should -Be 'status'
        $document.exitCode | Should -Be 2
        $document.health | Should -Be 'degraded'
        $document.ollama.version | Should -Be '0.40.11'
        $document.ollama.loaded[0].gpuPercent | Should -Be 100
        @($document.services.services | ForEach-Object { "$($_.name):$($_.state)" }) | Should -Be @('OpenWebUI:running', 'ComfyUI:stale record', 'ImageGate:running', 'Files:running')
        $document.services.services[0].uptimeSeconds | Should -BeGreaterThan 5390
        $document.services.services[0].listeners | Should -Be @('127.0.0.1')
        @($document.services.lines | Where-Object { $_.level -eq 'degraded' }).Count | Should -Be 1
        $document.system.gpus[0].memoryTotalMiB | Should -Be 8192
        $document.pins.drift.Count | Should -Be 0
        $document.doctor.executionPolicy.LocalMachine | Should -Be 'RemoteSigned'
        $document.launcher.settingsLoaded | Should -BeTrue
    }

    It 'keeps a single-line list and a list of one service as JSON lists' {
        $context.Json = $true
        $settings.Images.Enabled = $false
        $settings.Files.Root = ''
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = (Read-LocalAIState -Path $paths.State).Services.OpenWebUI } }
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.exitCode | Should -Be 0
        ($document.services.services -is [array]) | Should -BeTrue
        $document.services.services.Count | Should -Be 1
        ($document.files.lines -is [array]) | Should -BeTrue
        $document.files.lines.Count | Should -Be 1
    }

    It 'works without settings from state.json and the stamp, printing why the settings do not load' {
        $context.Settings = $null
        $context.SettingsError = "Invalid settings (defaults.psd1 with settings.psd1):`n  Unknown setting 'Ports.Bogus'."
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*The settings do not load, so status reports only what state.json and install-stamp.json record*Unknown setting 'Ports.Bogus'.*"
        $run.Printed | Should -BeLike '*Open WebUI: 0.12.4 runs at http://127.0.0.1:18431 (PID 4100, listener PID 4101, up 1 h 30 min), listening on 127.0.0.1.*'
        $run.Printed | Should -BeLike '*ComfyUI: 0.42.5 runs at http://127.0.0.1:18432*'
        $run.Printed | Should -BeLike '*Image gate: runs at http://127.0.0.1:18434 (PID 4300), listening on 127.0.0.1; without the settings its answer is not checked.*'
        $run.Printed | Should -BeLike '*== Doctor checks ==*Execution policy: *Page file: *== Logs ==*'
        Should -Invoke Get-OpenWebUIVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Url -eq 'http://127.0.0.1:18431' }
        Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Test-FilesRoot -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'returns 1 without settings when state.json records no Open WebUI' {
        $context.Settings = $null
        $context.SettingsError = 'Invalid settings'
        Remove-Item -LiteralPath $paths.State
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Open WebUI: not running, as state.json records no start of it. Run 'local-ai start'.*"
    }

    It 'reads a state.json that is not JSON as empty, with a warning' {
        [IO.File]::WriteAllText($paths.State, '{ broken')
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Warnings | Should -BeLike "*State file '*state.json' is not valid JSON*status reads it as empty.*"
        $run.Printed | Should -BeLike ("*Open WebUI: not running. Port 18431 is held by another program, which this launcher did not start, and it answers as Open WebUI " +
            '0.12.4. Close that program*or set Ports.OpenWebUI in settings.psd1, then run ''local-ai start''.*')
    }

    It 'notes another launcher run that is in progress, in the text and in -Json' {
        $context.LockHeld = $true
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Another launcher run (install, start, stop, update, uninstall or shortcuts) is in progress, so what follows may change shortly.*'
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.launcher.otherRunActive | Should -BeTrue
    }

    It 'names the launcher version that VERSION holds, in the text and as launcher.version in -Json' {
        $world.Version = '1.2.0'
        # Not $repoRoot, which RepoRoot would hide inside the filter; variable names ignore case.
        $checkout = $repoRoot
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*== Launcher ==*Launcher 1.2.0.*The launcher in $repoRoot keeps its state in $root.*"
        $run.Printed | Should -Not -BeLike '*No VERSION file*'
        Should -Invoke Get-LocalAIVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $RepoRoot -eq $checkout }
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.launcher.version | Should -BeExactly '1.2.0'
        @($document.launcher.lines | Where-Object { $_.text -eq 'Launcher 1.2.0.' }).level | Should -Be 'fact'
    }

    It 'says that no VERSION file names the version, as in a git checkout before the first release, without changing the exit code' {
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeNullOrEmpty
        $run.Printed | Should -BeLike "*== Launcher ==*No VERSION file in $repoRoot names the launcher's version, as in a git checkout before the first release.*"
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.exitCode | Should -Be 0
        $document.launcher.ContainsKey('version') | Should -BeTrue
        # null, not an empty string.
        ($null -eq $document.launcher.version) | Should -BeTrue
    }

    It 'returns 2, saying that only status runs here, inside an app package''s container, in the text and in -Json' {
        $context.Redirection = @{ Package = 'Fake_123'; Store = 'C:\Users\Test\AppData\Local\Packages\Fake_123\LocalCache\Local' }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -Be ("This window runs inside the app package Fake_123, and Windows puts the folders it creates in %LOCALAPPDATA% and " +
            "%APPDATA% into that package's private stores C:\Users\Test\AppData\Local\Packages\Fake_123\LocalCache\Local and " +
            "C:\Users\Test\AppData\Local\Packages\Fake_123\LocalCache\Roaming instead, where other windows never see them. status runs here, but " +
            "every other verb refuses to, so that the launcher's files never land there. Run those, such as 'local-ai start', from a console window or " +
            "Windows Terminal; the Start menu shortcuts 'Start Local AI', 'Stop Local AI' and 'Update Local AI' work too.")
        $run.Printed | Should -BeLike '*Status: degraded, with 1 warning(s); see above.'
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.exitCode | Should -Be 2
        $document.health | Should -Be 'degraded'
        $document.launcher.appDataRedirection.package | Should -Be 'Fake_123'
        $document.launcher.appDataRedirection.store | Should -Be 'C:\Users\Test\AppData\Local\Packages\Fake_123\LocalCache\Local'
        $document.launcher.privateCopies | Should -BeNullOrEmpty
    }

    It 'returns 2 with a warning for each private copy of Root and of the data folder that a package store holds' {
        $roaming = Join-Path $TestDrive "$leaf-roaming"
        $settings.OpenWebUI.DataDir = Join-Path $roaming "$leaf-open-webui"
        $context.LocalAppData = $TestDrive
        $context.AppData = $roaming
        $rootCopy = Join-Path $TestDrive "Packages\Fake_123\LocalCache\Local\$leaf"
        $dataCopy = Join-Path $TestDrive "Packages\Fake_123\LocalCache\Roaming\$leaf-open-webui"
        $null = New-Item -ItemType Directory -Force -Path $rootCopy, $dataCopy
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $warnings = @($run.Warnings -split "`n")
        $warnings | Should -Be @(
            ("$rootCopy is a private copy of $root that Windows made for a window inside an app package, and a window inside that package sees it instead of " +
                'the real folder. Move it aside, out of %LOCALAPPDATA%\Packages, once you have checked whether it holds anything the real folder lacks. Until ' +
                'then every verb but status refuses to run.')
            ("$dataCopy is a private copy of $($settings.OpenWebUI.DataDir) that Windows made for a window inside an app package, and a window inside that " +
                'package sees it instead of the real folder. Move it aside, out of %LOCALAPPDATA%\Packages, once you have checked whether it holds anything the ' +
                'real folder lacks.')
        )
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.exitCode | Should -Be 2
        $document.launcher.appDataRedirection | Should -BeNullOrEmpty
        @($document.launcher.privateCopies) | Should -Be @($rootCopy, $dataCopy)
    }

    It 'says what still uses a superseded alias: Qwen Code, with the command that points it at Model.Alias' {
        $settings.Model.SupersededAliases = @('old-chat')
        $world.Tags += 'old-chat:latest'
        Mock Get-QwenCodeModel -ModuleName LocalAI -MockWith { 'old-chat' }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike ("*Ollama still holds the superseded alias old-chat; 'local-ai update' offers to remove it. Qwen Code still uses it (model.name " +
            'in its settings.json); point Qwen Code at local-chat first with: ollama launch qwen --model local-chat --config --yes*')
    }

    It 'reports, rather than fails, when the data folder and ComfyUI lie on a drive this PC does not have now' {
        $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        $free = @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z' | Where-Object { $used -notcontains $_ })[0]
        $settings.OpenWebUI.DataDir = "${free}:\owui"
        $settings.ComfyUI.Dir = "${free}:\ComfyUI"
        $stamp.ComfyUI.Dir = $settings.ComfyUI.Dir
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $run = Invoke-StatusVerb -Context $context
        @(0, 2) | Should -Contain $run.Code[0]
        $run.Printed | Should -Not -BeLike '*Cannot find drive*'
        $run.Printed | Should -BeLike '*== Doctor checks ==*== Logs ==*'
    }

    It 'names local-ai install for a ComfyUI entry whose venv uninstall removed, which keeps only Dir and Cloned' {
        $stamp.ComfyUI = @{ Dir = $settings.ComfyUI.Dir; Cloned = $true }
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*install-stamp.json records no ComfyUI install, which Images.Enabled asks for. Run 'local-ai install'.*"
        $run.Warnings | Should -Not -BeLike "*is at commit , but ComfyUI.Commit pins*"
    }

    It 'returns 2 and names local-ai update, as update would change it, for a checkout at the pin whose <Case>' -ForEach @(
        @{ Case = 'origin is another remote'; Message = "*ComfyUI in *ComfyUI: origin https://github.com/comfyanonymous/ComfyUI.git -> https://github.com/Comfy-Org/ComfyUI.git. Run 'local-ai update'.*" }
        @{ Case = 'venv was set up for other constraints'; Message = "*ComfyUI in *ComfyUI: venv set up for another ConstraintsSha256 -> requirements.txt, the constraints, cu130 and 2026-10-23T00:07:14Z. Run 'local-ai update'.*" }
        @{ Case = 'torch is not the constrained version'; Message = "*ComfyUI in *ComfyUI: torch 2.13.0+cu130 -> 2.14.1. Run 'local-ai update'.*" }
    ) {
        switch -Wildcard ($Case) {
            'origin*' { $git.Origin = 'https://github.com/comfyanonymous/ComfyUI.git' }
            'venv*' { $venvMarker.ConstraintsSha256 = 'a' * 64 }
            'torch*' { $venvMarker.Torch = '2.13.0+cu130' }
        }
        Write-LocalAIState -Path (Join-Path $settings.ComfyUI.Dir '.venv\local-ai-install.json') -State $venvMarker
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike $Message
        $run.Printed | Should -Not -BeLike '*Everything install-stamp.json records matches its pin.*'
        # The plan update makes from the same checkout names the same change.
        $plan = Invoke-ModuleFunction 'Get-ComfyUIUpdatePlan' @{ Settings = $settings; Stamp = (Read-LocalAIState -Path $paths.InstallStamp); RepoRoot = $repoRoot }
        $change = ($Message -replace '^\*ComfyUI in \*ComfyUI: ', '') -replace '\. Run .*\z', ''
        @($plan.Changes) | Should -Contain $change
    }

    It 'returns 2 and names local-ai update for a venv on the Microsoft Store Python, which update makes anew' {
        Write-TestPyVenvConfig -Venv (Join-Path $settings.ComfyUI.Dir '.venv') -BaseHome $storeHome -Version '3.13.14'
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike ("*ComfyUI in *ComfyUI: venv on the Microsoft Store Python 3.13.14, whose launches can fail or hang until Windows restarts -> " +
            "a new venv on a uv-managed Python 3.13. Run 'local-ai update'.*")
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $drift = @($document.pins.drift | Where-Object { $_.setting -eq 'ComfyUI.Python' })
        $drift.Count | Should -Be 1
        $drift[0].component | Should -Be 'ComfyUI'
        $drift[0].pinned | Should -Be 'uv-managed 3.13'
        $drift[0].installed | Should -Be $storeHome
    }

    It 'notes, without changing the exit code, when the origin of a checkout at the pin cannot be read' {
        $git.Fail['config'] = @{ Code = 128; Lines = @('fatal: not a git repository') }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*ComfyUI's origin and venv in $($settings.ComfyUI.Dir) cannot be checked: *fatal: not a git repository*"
    }

    It 'checks no answer of mcpo when files.key cannot be read, and never prints or creates it' {
        Remove-Item -LiteralPath $paths.FilesKey
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike ("*File tools: runs (PID 4400), but does not answer at http://127.0.0.1:18433 as File tools: files.key cannot be read, so mcpo's " +
            "answer is not checked*")
        Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 0 -Exactly
        Test-Path -LiteralPath $paths.FilesKey | Should -BeFalse
        $run.Printed | Should -Not -BeLike "*$key*"
    }

    It 'returns 2 with its degraded line when <Case>' -ForEach @(
        @{ Case = 'api/ps throws'; Message = '*Ollama does not list its loaded models at http://127.0.0.1:11434/api/ps: boom*' }
        @{ Case = 'api/tags throws'; Message = '*Ollama does not list its models at http://127.0.0.1:11434/api/tags: boom*' }
        @{ Case = 'the service table cannot be built'; Message = '*The service table cannot be built from the settings, so the services are judged by their state.json records: plan boom*' }
        @{ Case = 'nvidia-smi prints no GPU'; Message = "*nvidia-smi cannot report the GPU (it printed 'NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.')*" }
        @{ Case = 'the folder check throws'; Message = "*Files.Root '*' cannot be checked: root boom*" }
        @{ Case = 'install-stamp.json is not JSON'; Message = '*install-stamp.json* is not valid JSON*status reads it as empty.*' }
    ) {
        switch ($Case) {
            'api/ps throws' { Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/api/ps' } -MockWith { throw 'boom' } }
            'api/tags throws' { Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/api/tags' } -MockWith { throw 'boom' } }
            'the service table cannot be built' { Mock Get-LocalAIServicePlan -ModuleName LocalAI -MockWith { throw 'plan boom' } }
            'nvidia-smi prints no GPU' { $world.Gpu = "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver." }
            'the folder check throws' { Mock Test-FilesRoot -ModuleName LocalAI -MockWith { throw 'root boom' } }
            'install-stamp.json is not JSON' { [IO.File]::WriteAllText($paths.InstallStamp, '{ broken') }
        }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike $Message
    }

    It 'looks for partial downloads below ComfyUI.Dir\models only, not below %USERPROFILE%\models' {
        $null = Invoke-StatusVerb -Context $context
        Should -Invoke Find-LocalAIFile -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Extension -contains '.part' }
        Should -Invoke Find-LocalAIFile -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Root -eq (Join-Path $settings.ComfyUI.Dir 'models') }
        Should -Invoke Find-LocalAIFile -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Root -eq (Join-Path $env:USERPROFILE 'models') }
    }

    It "adds the launcher's kind and its last release check to the launcher section, the kind git for this checkout" {
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.exitCode | Should -Be 0
        $document.launcher.kind | Should -Be 'git'
        foreach ($key in 'latest', 'checkedAt', 'checkError') {
            $document.launcher.ContainsKey($key) | Should -BeTrue -Because "launcher.$key is part of -Json"
            ($null -eq $document.launcher[$key]) | Should -BeTrue
        }
        $document.launcher.updateAvailable | Should -BeFalse
        @($document.launcher.lines | Where-Object { $_.text -like 'This is a git checkout*' }).level | Should -Be 'fact'
    }

    It 'reports what Get-LauncherStatus finds, a release folder that changed as degraded, without asking GitHub' {
        $checkout = $repoRoot
        Mock Get-LauncherStatus -ModuleName LocalAI -MockWith {
            @{ Data = [ordered]@{ kind = 'release'; latest = 'v1.2.0'; checkedAt = '2026-11-04T11:00:00Z'; updateAvailable = $true; checkError = $null }
                Lines = @([ordered]@{ level = 'degraded'; text = 'versions\v1.1.0 does not match its manifest.' }) }
        }
        $run = Invoke-StatusVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike '*versions\v1.1.0 does not match its manifest.*'
        $context.Json = $true
        $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $context).Records[0].MessageData)
        $document.launcher.kind | Should -Be 'release'
        $document.launcher.latest | Should -BeExactly 'v1.2.0'
        $document.launcher.checkedAt | Should -BeExactly '2026-11-04T11:00:00Z'
        $document.launcher.updateAvailable | Should -BeTrue
        Should -Invoke Get-LauncherStatus -ModuleName LocalAI -ParameterFilter { $RepoRoot -eq $checkout -and $DefaultRepo -ceq 'Ochsyp/local-ai-launcher' }
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Uri -like '*api.github.com*' }
    }

    Context 'with settings that changed since start' {
        BeforeAll {
            $filesLine = "File tools: runs with older settings than this launcher would start it with. Run 'local-ai start', which restarts it."
            $comfyLine = "ComfyUI: runs with older settings than this launcher would start it with. Run 'local-ai stop', then 'local-ai start'."
            $webLine = "Open WebUI: runs with older settings than this launcher would start it with. Run 'local-ai stop', then 'local-ai start'."

            # Return status -Json's services as a table of settingsCurrent by name.
            function Get-TestSettingsCurrent([hashtable]$Context) {
                $Context.Json = $true
                $document = ConvertFrom-LocalAIJson -Text ([string](Invoke-StatusVerb -Context $Context).Records[0].MessageData)
                $Context.Json = $false
                $current = @{}
                foreach ($service in @($document.services.services)) { $current[$service.name] = $service.settingsCurrent }
                return $current
            }
        }

        It 'adds no line and gives settingsCurrent true while every service runs with what a start would record now, the real image workflow included' {
            $run = Invoke-StatusVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -Not -BeLike '*older settings*'
            $current = Get-TestSettingsCurrent -Context $context
            $current.OpenWebUI | Should -BeTrue
            $current.ComfyUI | Should -BeTrue
            $current.Files | Should -BeTrue
            # The gate's script reads none of its variables, and start never restarts it for them.
            $current.ContainsKey('ImageGate') | Should -BeTrue
            $current.ImageGate | Should -BeNullOrEmpty
        }

        It 'names local-ai start for the file tools, as advice that keeps the exit code, when <Case> changed' -ForEach @(
            @{ Case = 'Files.Root'; Code = 0 }
            @{ Case = 'Files.DisabledTools'; Code = 0 }
            @{ Case = 'Ports.Files'; Code = 2 }
        ) {
            switch ($Case) {
                'Files.Root' {
                    $null = Write-TestFile "$leaf-other\notes.txt" 'notes'
                    $settings.Files.Root = Join-Path $TestDrive "$leaf-other"
                }
                'Files.DisabledTools' { $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'search_files' }
                # Nothing listens on the new port, so status also finds the file tools down and exits with 2.
                'Ports.Files' { $settings.Ports.Files = 18435 }
            }
            $run = Invoke-StatusVerb -Context $context
            $run.Code | Should -Be @($Code)
            $run.Printed | Should -BeLike "*  Advice: $filesLine*"
            $run.Warnings | Should -Not -BeLike '*older settings*'
            (Get-TestSettingsCurrent -Context $context).Files | Should -BeFalse
        }

        It 'names local-ai start for an mcpo record without ConfigSha256, which an older launcher wrote' {
            $state = Read-LocalAIState -Path $paths.State
            $state.Services.Files.Remove('ConfigSha256')
            [IO.File]::WriteAllText($paths.State, (ConvertTo-Json -InputObject $state -Depth 6))
            $run = Invoke-StatusVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*  Advice: $filesLine*"
            (Get-TestSettingsCurrent -Context $context).Files | Should -BeFalse
        }

        It 'names local-ai stop, then local-ai start, for a ComfyUI whose inherited variables changed' {
            $settings.ComfyUI.InheritEnvironment = @('HIP_VISIBLE_DEVICES')
            $run = Invoke-StatusVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*  Advice: $comfyLine*"
            $run.Printed | Should -Not -BeLike '*Open WebUI: runs with older settings*'
            $current = Get-TestSettingsCurrent -Context $context
            $current.ComfyUI | Should -BeFalse
            $current.OpenWebUI | Should -BeTrue
        }

        It 'names local-ai stop, then local-ai start, for an Open WebUI whose <Case> changed while every part runs, below its own lines' -ForEach @(
            @{ Case = 'inherited variables' }
            # Only the real workflow carries the steps, so this proves status reads it.
            @{ Case = 'image steps' }
        ) {
            switch ($Case) {
                'inherited variables' { $settings.OpenWebUI.InheritEnvironment = @('HF_ENDPOINT') }
                'image steps' { $settings.Images.Steps = [int]$settings.Images.Steps + 1 }
            }
            $run = Invoke-StatusVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*Open WebUI: 0.12.4 runs at*`n  Advice: $webLine`n*ComfyUI: 0.42.5 runs at*"
            (Get-TestSettingsCurrent -Context $context).OpenWebUI | Should -BeFalse
        }

        It 'gives Open WebUI no line and settingsCurrent null while <Name>, which its settings depend on, is down' -ForEach @(
            @{ Name = 'ComfyUI'; Id = 4200; Port = 18432 }
            @{ Name = 'ImageGate'; Id = 4300; Port = 18434 }
            @{ Name = 'Files'; Id = 4400; Port = 18433 }
        ) {
            $settings.OpenWebUI.InheritEnvironment = @('HF_ENDPOINT')
            $null = $world.Live.Remove($Id)
            $world.Listeners.Remove($Port)
            $run = Invoke-StatusVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Printed | Should -Not -BeLike '*older settings*'
            $current = Get-TestSettingsCurrent -Context $context
            $current.OpenWebUI | Should -BeNullOrEmpty
            $current[$Name] | Should -BeNullOrEmpty
        }

        It 'gives Open WebUI no line and settingsCurrent null while mcpo runs but does not answer, as without files.key' {
            $settings.OpenWebUI.InheritEnvironment = @('HF_ENDPOINT')
            Remove-Item -LiteralPath $paths.FilesKey
            $run = Invoke-StatusVerb -Context $context
            $run.Printed | Should -Not -BeLike '*Open WebUI: runs with older settings*'
            (Get-TestSettingsCurrent -Context $context).OpenWebUI | Should -BeNullOrEmpty
        }

        It 'gives Open WebUI no line and settingsCurrent null when the image workflow cannot be read' {
            $settings.Images.Workflow = Join-Path $TestDrive "$leaf-missing-workflow.json"
            $run = Invoke-StatusVerb -Context $context
            $run.Printed | Should -Not -BeLike '*Open WebUI: runs with older settings*'
            $current = Get-TestSettingsCurrent -Context $context
            $current.OpenWebUI | Should -BeNullOrEmpty
            # The others do not depend on it.
            $current.ComfyUI | Should -BeTrue
            $current.Files | Should -BeTrue
        }

        It 'does not fail for a Files.Root that no longer exists, and names local-ai start' {
            $settings.Files.Root = Join-Path $TestDrive "$leaf-gone"
            $run = Invoke-StatusVerb -Context $context
            $run.Other | Should -BeNullOrEmpty
            $run.Printed | Should -BeLike "*  Advice: $filesLine*"
            $run.Printed | Should -BeLike '*== Doctor checks ==*'
        }

        It 'gives a service that does not run, or that the settings leave out, no line and settingsCurrent null' {
            $settings.ComfyUI.InheritEnvironment = @('HIP_VISIBLE_DEVICES')
            $null = $world.Live.Remove(4200)
            $world.Listeners.Remove(18432)
            $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'search_files'
            $settings.Files.Root = ''
            $run = Invoke-StatusVerb -Context $context
            $run.Printed | Should -Not -BeLike '*older settings*'
            $current = Get-TestSettingsCurrent -Context $context
            $current.ComfyUI | Should -BeNullOrEmpty
            $current.Files | Should -BeNullOrEmpty
        }

        It 'stays read-only and never shows the key, on screen or in -Json, when settings changed' {
            $settings.Ports.Files = 18435
            $settings.OpenWebUI.InheritEnvironment = @('HF_ENDPOINT')
            $before = Get-TestFileSha256 $paths.State
            $run = Invoke-StatusVerb -Context $context
            $run.Printed | Should -BeLike '*older settings*'
            "$($run.Printed)`n$($run.Warnings)" | Should -Not -BeLike "*$key*"
            $context.Json = $true
            [string](Invoke-StatusVerb -Context $context).Records[0].MessageData | Should -Not -BeLike "*$key*"
            Get-TestFileSha256 $paths.State | Should -Be $before
            Test-Path -LiteralPath $paths.McpoConfig | Should -BeFalse
            Should -Invoke Write-LocalAIState -ModuleName LocalAI -Times 0 -Exactly
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        }
    }
}

Describe 'Status helpers' {
    It 'formats <Seconds> s as <Expected>' -ForEach @(
        @{ Seconds = 40; Expected = '40 s' }
        @{ Seconds = 420; Expected = '7 min' }
        @{ Seconds = 7500; Expected = '2 h 5 min' }
        @{ Seconds = 273600; Expected = '3 d 4 h' }
        @{ Seconds = -5; Expected = '0 s' }
    ) {
        InModuleScope LocalAI -Parameters @{ Seconds = $Seconds } { param($Seconds) Format-LocalAIDuration -Seconds $Seconds } | Should -BeExactly $Expected
    }

    It 'formats <Bytes> bytes as <Expected> with a point in any culture' -ForEach @(
        @{ Bytes = 8040000000; Expected = '7.5 GB' }
        @{ Bytes = 536870912; Expected = '512 MB' }
        @{ Bytes = 3000; Expected = '3 KB' }
        @{ Bytes = 0; Expected = '0 KB' }
    ) {
        $saved = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            InModuleScope LocalAI -Parameters @{ Bytes = $Bytes } { param($Bytes) Format-LocalAISize -Bytes $Bytes } | Should -BeExactly $Expected
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
    }

    It 'selects the addresses that are not loopback' {
        $exposed = InModuleScope LocalAI { Select-ExposedAddress -Address @('127.0.0.1', '::1', '0.0.0.0', '::', '192.0.2.5', '127.0.0.2') }
        $exposed | Should -Be @('0.0.0.0', '::', '192.0.2.5')
        @(InModuleScope LocalAI { Select-ExposedAddress -Address @() }) | Should -BeNullOrEmpty
    }

    It 'writes JSON on one line with every non-ASCII character escaped' {
        $text = InModuleScope LocalAI { ConvertTo-LocalAIJsonText -Value ([ordered]@{ path = 'C:\B' + [char]0xFC + '-test'; list = @(1); none = $null }) }
        $text | Should -BeExactly '{"path":"C:\\B\u00fc-test","list":[1],"none":null}'
    }

    It 'reads a file another program holds open for writing, and gives $null for a missing one' {
        $path = Write-TestFile 'shared\held.log' "line one`r`n"
        $writer = New-Object IO.FileStream -ArgumentList $path, ([IO.FileMode]::Append), ([IO.FileAccess]::Write), ([IO.FileShare]::ReadWrite)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes("line two`r`n")
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            InModuleScope LocalAI -Parameters @{ Path = $path } { param($Path) Read-SharedText -Path $Path } | Should -BeExactly "line one`r`nline two`r`n"
        } finally {
            $writer.Dispose()
        }
        InModuleScope LocalAI -Parameters @{ Path = (Join-Path $TestDrive 'shared\none.log') } { param($Path) Read-SharedText -Path $Path } | Should -BeNullOrEmpty
    }

    It 'reads the page file through CIM, with the commit limit in bytes' {
        Mock Get-CimInstance -ModuleName LocalAI -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith { [pscustomobject]@{ AutomaticManagedPagefile = $false } }
        Mock Get-CimInstance -ModuleName LocalAI -ParameterFilter { $ClassName -eq 'Win32_PageFileSetting' } -MockWith {
            [pscustomobject]@{ Name = 'C:\pagefile.sys'; InitialSize = [uint32]20480; MaximumSize = [uint32]20480 }
            [pscustomobject]@{ Name = 'D:\pagefile.sys'; InitialSize = [uint32]0; MaximumSize = [uint32]0 }
        }
        Mock Get-CimInstance -ModuleName LocalAI -ParameterFilter { $ClassName -eq 'Win32_PageFileUsage' } -MockWith { [pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = [uint32]20480 } }
        Mock Get-CimInstance -ModuleName LocalAI -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } -MockWith { [pscustomobject]@{ TotalVirtualMemorySize = [uint64]20000000 } }
        $page = InModuleScope LocalAI { Get-PageFileStatus }
        $page.Automatic | Should -BeFalse
        $page.Settings.Count | Should -Be 2
        $page.Settings[1].Name | Should -Be 'D:\pagefile.sys'
        $page.Settings[1].InitialMB | Should -Be 0
        $page.Files[0].CurrentMB | Should -Be 20480
        $page.CommitLimitBytes | Should -Be 20480000000
    }

    It 'finds the app.ico beside the ollama program, and none <Case>' -ForEach @(
        @{ Case = 'without an icon there'; KeepIcon = $false; HasProgram = $true }
        @{ Case = 'without the program'; KeepIcon = $true; HasProgram = $false }
    ) {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Write-TestFile ((Split-Path $folder -Leaf) + '\ollama.exe') 'program'
        $iconFile = Write-TestFile ((Split-Path $folder -Leaf) + '\app.ico') 'icon'
        $found = @{ Program = $true }
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' } -MockWith {
            if ($found.Program) { [pscustomobject]@{ Name = 'ollama.exe'; Path = (Join-Path $folder 'ollama.exe') } }
        }
        InModuleScope LocalAI { Get-OllamaIcon } | Should -Be $iconFile
        if (-not $KeepIcon) { Remove-Item -LiteralPath $iconFile }
        $found.Program = $HasProgram
        InModuleScope LocalAI { Get-OllamaIcon } | Should -BeNullOrEmpty
    }

    It 'gives a WScript.Shell whose CreateShortcut writes nothing before Save' {
        $path = Join-Path $TestDrive 'shell-probe\none.lnk'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent)
        # The shell may create Microsoft\Windows\Caches below %LOCALAPPDATA%.
        $savedLocal = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'shell-probe-local'
            $link = (InModuleScope LocalAI { Get-WScriptShell }).CreateShortcut($path)
            $link.TargetPath | Should -BeNullOrEmpty
        } finally {
            $env:LOCALAPPDATA = $savedLocal
        }
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'Find-LocalAIFile and Get-ZoneMarkedFile' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $outside = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $link = Join-Path $base 'linked'
        # Write $Name below $base, marked as downloaded when -Marked is set, and return its path.
        function Write-ZoneFile([string]$Folder, [string]$Name, [switch]$Marked) {
            $path = Join-Path $Folder $Name
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent)
            [IO.File]::WriteAllText($path, 'x')
            if ($Marked) { Set-Content -LiteralPath $path -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" }
            return $path
        }
        $marked = Write-ZoneFile $base 'a.ps1' -Marked
        $null = Write-ZoneFile $base 'b.cmd'
        $null = Write-ZoneFile $base '.git\hooks\c.ps1' -Marked
        $deep = Write-ZoneFile $base 'sub\d.PSM1' -Marked
        $null = Write-ZoneFile $base 'e.txt' -Marked
        $null = Write-ZoneFile $base 'f.psd1'
        $null = Write-ZoneFile $outside 'g.ps1' -Marked
        $null = New-Item -ItemType Junction -Path $link -Target $outside
    }

    AfterEach {
        # Removes the link only, never what it leads to.
        if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link, $false) }
    }

    It 'returns the marked scripts, in any case of extension, outside .git and without entering links' {
        $found = @(InModuleScope LocalAI -Parameters @{ Root = $base } { param($Root) Get-ZoneMarkedFile -Root $Root }) | Sort-Object
        $found | Should -Be @($marked, $deep)
    }

    It 'finds files by extension without entering links, and stops after MaxEntries entries' {
        $all = @(InModuleScope LocalAI -Parameters @{ Root = $base } { param($Root) Find-LocalAIFile -Root $Root -Extension '.ps1', '.txt' } | ForEach-Object { $_.Name }) | Sort-Object
        $all | Should -Be @('a.ps1', 'c.ps1', 'e.txt')
        @(InModuleScope LocalAI -Parameters @{ Root = $base } { param($Root) Find-LocalAIFile -Root $Root -Extension '.ps1', '.cmd', '.txt', '.psd1' -MaxEntries 1 }).Count | Should -BeLessOrEqual 1
        @(InModuleScope LocalAI -Parameters @{ Root = (Join-Path $base 'missing') } { param($Root) Find-LocalAIFile -Root $Root -Extension '.ps1' }) | Should -BeNullOrEmpty
    }
}

Describe 'Set-LocalAIShortcut' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $target = Join-Path $repoRoot 'local-ai.cmd'
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $folder = Join-Path $root 'Start Menu\Programs\Local AI'
        $settings.Shortcuts.Folder = $folder
        $settings.ComfyUI.Dir = Join-Path $root 'ComfyUI'
        $context = @{ Verb = 'shortcuts'; Paths = $paths; Settings = $settings; RepoRoot = $repoRoot; Remove = $false }
        $store = @{}
        $saves = New-Object System.Collections.Generic.List[string]
        $shell = Get-FakeShell -Store $store -Saves $saves
        $icon = 'C:\Users\User\AppData\Local\Programs\Ollama\app.ico'
        Mock Get-WScriptShell -ModuleName LocalAI -MockWith { $shell }
        Mock Get-OllamaIcon -ModuleName LocalAI -MockWith { $icon }
        Mock Update-SessionPath -ModuleName LocalAI
    }

    It 'creates Start, Stop, Status and Update shortcuts that run local-ai.cmd with their verb in a normal window, with the Ollama icon' {
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        foreach ($verb in 'Start', 'Stop', 'Status', 'Update') {
            $fields = $store[(Join-Path $folder "$verb Local AI.lnk")]
            $fields.TargetPath | Should -BeExactly $target
            $fields.Arguments | Should -BeExactly $verb.ToLowerInvariant()
            $fields.WorkingDirectory | Should -BeExactly $repoRoot
            $fields.WindowStyle | Should -Be 1
            $fields.IconLocation | Should -BeExactly "$icon,0"
            $run.Printed | Should -BeLike "*Created $folder\$verb Local AI.lnk.*"
        }
        $store[(Join-Path $folder 'Start Local AI.lnk')].Description | Should -BeExactly 'Start Open WebUI, ComfyUI and the image gate, with local-chat in Ollama'
        $store[(Join-Path $folder 'Stop Local AI.lnk')].Description |
            Should -BeExactly 'Stop Open WebUI, ComfyUI and the image gate, unload local-chat from Ollama, and quit the Ollama app when local-ai started it'
        $store[(Join-Path $folder 'Status Local AI.lnk')].Description | Should -BeExactly 'Show whether Ollama, Open WebUI, ComfyUI and the image gate run, and what needs attention'
        $store[(Join-Path $folder 'Update Local AI.lnk')].Description |
            Should -BeExactly 'Bring a release install of the launcher to its latest release and every part to its pin, after showing the plan and asking'
        $saves.Count | Should -Be 4
        $run.Printed | Should -BeLike "*The Start menu folder $folder holds Start, Stop, Status and Update Local AI."
    }

    It 'names the file tools when Files.Root is set and leaves images out when they are off' {
        $settings.Images.Enabled = $false
        $settings.Files.Root = Join-Path $TestDrive 'files'
        $null = Invoke-ShortcutVerb -Context $context
        $store[(Join-Path $folder 'Start Local AI.lnk')].Description | Should -BeExactly 'Start Open WebUI and the file tools, with local-chat in Ollama'
    }

    It 'leaves shortcuts that already match alone' {
        $null = Invoke-ShortcutVerb -Context $context
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        $saves.Count | Should -Be 4
        $run.Printed | Should -BeLike ("*$folder\Start Local AI.lnk is up to date.*$folder\Stop Local AI.lnk is up to date.*$folder\Status Local AI.lnk is up to date.*" +
            "$folder\Update Local AI.lnk is up to date.*")
    }

    It 'adds Update Local AI beside the Start, Stop and Status shortcuts an earlier version made, leaving those alone' {
        $null = Invoke-ShortcutVerb -Context $context
        $update = Join-Path $folder 'Update Local AI.lnk'
        Remove-Item -LiteralPath $update
        $store.Remove($update)
        $saves.Clear()
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        @($saves) | Should -Be @($update)
        $run.Printed | Should -BeLike "*Start Local AI.lnk is up to date.*Stop Local AI.lnk is up to date.*Status Local AI.lnk is up to date.*Created $update.*"
        $store[$update].TargetPath | Should -BeExactly $target
        $store[$update].Arguments | Should -BeExactly 'update'
    }

    It 'replaces a Start shortcut of the same name that runs another program, and says what it ran' {
        $old = Join-Path $folder 'Start Local AI.lnk'
        $null = New-Item -ItemType Directory -Force -Path $folder
        [IO.File]::WriteAllText($old, 'lnk')
        $store[$old] = @{ TargetPath = 'C:\Tools\other.cmd'; Arguments = ''; WorkingDirectory = 'C:\Tools'; WindowStyle = 1; IconLocation = "$icon,0"; Description = 'Start Ollama and Open WebUI' }
        $run = Invoke-ShortcutVerb -Context $context
        $run.Printed | Should -BeLike "*Replaced $old, which ran 'C:\Tools\other.cmd'.*"
        $store[$old].TargetPath | Should -BeExactly $target
        $store[$old].Arguments | Should -BeExactly 'start'
    }

    It 'updates a shortcut whose target matches but whose description differs' {
        $null = Invoke-ShortcutVerb -Context $context
        $store[(Join-Path $folder 'Stop Local AI.lnk')].Description = 'old text'
        $run = Invoke-ShortcutVerb -Context $context
        $run.Printed | Should -BeLike "*Updated $folder\Stop Local AI.lnk.*"
        $saves.Count | Should -Be 5
    }

    It 'sets no icon when the Ollama app has none' {
        Mock Get-OllamaIcon -ModuleName LocalAI -MockWith { $null }
        $null = Invoke-ShortcutVerb -Context $context
        $store[(Join-Path $folder 'Start Local AI.lnk')].IconLocation | Should -BeExactly ',0'
    }

    It 'throws when the repository has no local-ai.cmd' {
        $context.RepoRoot = Join-Path $TestDrive 'not-a-repo'
        { Set-LocalAIShortcut -Context $context 6>$null } | Should -Throw -ExpectedMessage '*Cannot find *not-a-repo\local-ai.cmd, which the shortcuts run.'
        $saves.Count | Should -Be 0
    }

    It 'with -Remove deletes only the four shortcuts, and the folder once nothing else is in it' {
        $null = Invoke-ShortcutVerb -Context $context
        $other = Join-Path $folder 'Other.lnk'
        [IO.File]::WriteAllText($other, 'lnk')
        $context.Remove = $true
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike ("*Removed $folder\Start Local AI.lnk.*Removed $folder\Stop Local AI.lnk.*Removed $folder\Status Local AI.lnk.*" +
            "Removed $folder\Update Local AI.lnk.*Kept $folder, which holds other files.*")
        @(Get-ChildItem -LiteralPath $folder | ForEach-Object { $_.Name }) | Should -Be @('Other.lnk')
        Remove-Item -LiteralPath $other
        $run = Invoke-ShortcutVerb -Context $context
        $run.Printed | Should -BeLike "*$folder holds none of the launcher's shortcuts.*Removed the empty folder $folder.*"
        Test-Path -LiteralPath $folder | Should -BeFalse
        Test-Path -LiteralPath (Split-Path $folder -Parent) | Should -BeTrue
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*$folder holds none of the launcher's shortcuts.*"
    }

    It 'writes shortcuts that WScript.Shell reads back, and removes them again' {
        Mock Get-WScriptShell -ModuleName LocalAI -MockWith { New-Object -ComObject WScript.Shell }
        # The shell creates Microsoft\Windows\Caches below %LOCALAPPDATA% when it saves a shortcut.
        $savedLocal = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'shell-local'
            $run = Invoke-ShortcutVerb -Context $context
            $run.Code | Should -Be @(0)
            $real = New-Object -ComObject WScript.Shell
            $link = $real.CreateShortcut((Join-Path $folder 'Status Local AI.lnk'))
            $link.TargetPath | Should -Be $target
            $link.Arguments | Should -BeExactly 'status'
            $link.WorkingDirectory | Should -Be $repoRoot
            $link.WindowStyle | Should -Be 1
            $link.IconLocation | Should -Be "$icon,0"
            (Invoke-ShortcutVerb -Context $context).Printed | Should -BeLike "*Status Local AI.lnk is up to date.*"
            $context.Remove = $true
            $null = Invoke-ShortcutVerb -Context $context
        } finally {
            $env:LOCALAPPDATA = $savedLocal
        }
        Test-Path -LiteralPath $folder | Should -BeFalse
    }

    It 'points the shortcuts of a release install at the shim in its install folder, which is also their working folder, never a version folder' {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0' -Shim
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.InstallRoot = $install.Root
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        foreach ($verb in 'Start', 'Stop', 'Status', 'Update') {
            $fields = $store[(Join-Path $folder "$verb Local AI.lnk")]
            $fields.TargetPath | Should -BeExactly (Join-Path $install.Root 'local-ai.cmd')
            $fields.WorkingDirectory | Should -BeExactly $install.Root
            $fields.Arguments | Should -BeExactly $verb.ToLowerInvariant()
        }
    }

    It 'replaces the shortcuts of a git checkout once a release install runs the verb, saying what they ran' {
        $null = Invoke-ShortcutVerb -Context $context
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0' -Shim
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.InstallRoot = $install.Root
        $run = Invoke-ShortcutVerb -Context $context
        $run.Printed | Should -BeLike "*Replaced $folder\Start Local AI.lnk, which ran '$target start'.*"
        $store[(Join-Path $folder 'Start Local AI.lnk')].TargetPath | Should -BeExactly (Join-Path $install.Root 'local-ai.cmd')
    }

    It 'throws when a release install has no shim' {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0'
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.InstallRoot = $install.Root
        { Set-LocalAIShortcut -Context $context 6>$null } | Should -Throw -ExpectedMessage "Cannot find $(Join-Path $install.Root 'local-ai.cmd'), which the shortcuts run."
        $saves.Count | Should -Be 0
    }
}

Describe 'Update-LocalAIShortcut' {
    BeforeAll {
        # Run Update-LocalAIShortcut and return @{ Printed; Warnings; Other } with the host text and the warnings joined, and anything else it wrote.
        function Invoke-TestShortcutUpdate([hashtable]$Context) {
            $output = @(Invoke-ModuleFunction 'Update-LocalAIShortcut' @{ Context = $Context } 3>&1 6>&1)
            return @{
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
                Other    = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] })
            }
        }
    }

    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.1.0') -Current 'v1.1.0'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\defaults.psd1')
        $folder = Join-Path $root 'Start Menu\Programs\Local AI'
        $settings.Shortcuts.Folder = $folder
        $context = @{ Verb = 'update'; Paths = (Get-LocalAIPaths -Root $root); Settings = $settings; RepoRoot = (Join-Path $install.Versions 'v1.1.0')
            InstallRoot = $install.Root; Remove = $false }
        $store = @{}
        $saves = New-Object System.Collections.Generic.List[string]
        $shell = Get-FakeShell -Store $store -Saves $saves
        Mock Get-WScriptShell -ModuleName LocalAI -MockWith { $shell }
        $seen = New-Object System.Collections.Generic.List[hashtable]
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith {
            $seen.Add($Context)
            0
        }
        # Put a Start Local AI shortcut that runs $Target into Shortcuts.Folder.
        $addStart = {
            param([string]$Target)
            $null = New-Item -ItemType Directory -Force -Path $folder
            $start = Join-Path $folder 'Start Local AI.lnk'
            [IO.File]::WriteAllText($start, 'lnk')
            $store[$start] = @{ TargetPath = $Target; Arguments = 'start' }
        }
    }

    It 'rewrites the launcher''s shortcuts for the launcher of this run when Shortcuts.Folder holds the Start Local AI of this install, named <Case>' -ForEach @(
        @{ Case = 'as Set-LocalAIShortcut names it'; Target = { Join-Path $install.Root 'local-ai.cmd' } }
        @{ Case = 'in capitals'; Target = { (Join-Path $install.Root 'local-ai.cmd').ToUpperInvariant() } }
    ) {
        & $addStart (& $Target)
        $run = Invoke-TestShortcutUpdate -Context $context
        $run.Printed | Should -BeExactly "Bringing the launcher's Start menu shortcuts up to date..."
        $run.Warnings | Should -BeNullOrEmpty
        $run.Other | Should -BeNullOrEmpty
        $seen.Count | Should -Be 1
        $seen[0].RepoRoot | Should -BeExactly (Join-Path $install.Versions 'v1.1.0')
        $seen[0].InstallRoot | Should -BeExactly $install.Root
        $seen[0].Remove | Should -BeFalse
        $seen[0].Settings.Shortcuts.Folder | Should -BeExactly $folder
        $saves.Count | Should -Be 0
    }

    It 'creates no shortcuts where Shortcuts.Folder is missing or holds no Start Local AI, also when it holds the other shortcuts' {
        $run = Invoke-TestShortcutUpdate -Context $context
        $run.Printed | Should -BeNullOrEmpty
        Test-Path -LiteralPath $folder | Should -BeFalse
        $null = New-Item -ItemType Directory -Force -Path $folder
        foreach ($name in 'Stop Local AI.lnk', 'Status Local AI.lnk') { [IO.File]::WriteAllText((Join-Path $folder $name), 'lnk') }
        $run = Invoke-TestShortcutUpdate -Context $context
        $run.Printed | Should -BeNullOrEmpty
        $run.Warnings | Should -BeNullOrEmpty
        $seen.Count | Should -Be 0
    }

    It 'leaves the shortcuts alone, without a word, when Start Local AI runs <Case>' -ForEach @(
        @{ Case = 'the local-ai.cmd of a git clone'; Target = { Join-Path $TestDrive 'clone\local-ai.cmd' } }
        @{ Case = 'nothing'; Target = { '' } }
    ) {
        & $addStart (& $Target)
        $run = Invoke-TestShortcutUpdate -Context $context
        $run.Printed | Should -BeNullOrEmpty
        $run.Warnings | Should -BeNullOrEmpty
        $run.Other | Should -BeNullOrEmpty
        $seen.Count | Should -Be 0
    }

    It 'warns instead of throwing when the shortcuts cannot be written, naming the shortcuts verb, and returns that warning' {
        & $addStart (Join-Path $install.Root 'local-ai.cmd')
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith { throw 'Access to the path is denied.' }
        $run = Invoke-TestShortcutUpdate -Context $context
        $text = "Could not bring the Start menu shortcuts up to date: Access to the path is denied. Run 'local-ai shortcuts' to try again."
        $run.Warnings | Should -BeExactly $text
        $run.Other | Should -Be @($text)
    }

    It 'warns and returns that warning when Start Local AI cannot be read' {
        & $addStart (Join-Path $install.Root 'local-ai.cmd')
        Mock Get-WScriptShell -ModuleName LocalAI -MockWith { throw 'Unable to open the shortcut.' }
        $run = Invoke-TestShortcutUpdate -Context $context
        $text = "Could not bring the Start menu shortcuts up to date: Unable to open the shortcut. Run 'local-ai shortcuts' to try again."
        $run.Warnings | Should -BeExactly $text
        $run.Other | Should -Be @($text)
        $seen.Count | Should -Be 0
    }
}

Describe 'local-ai.cmd' {
    BeforeAll {
        # A copy of local-ai.cmd beside a stub src\local-ai.ps1 that prints a marker and exits with LOCALAI_STUB_CODE.
        $folder = Join-Path $TestDrive 'cmd'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $folder 'src')
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'local-ai.cmd') -Destination $folder
        [IO.File]::WriteAllText((Join-Path $folder 'src\local-ai.ps1'), "param([string]`$Verb = 'start', [switch]`$Json)`r`nWrite-Output 'STUB-OUT'`r`nexit [int]`$env:LOCALAI_STUB_CODE`r`n")
        $cmd = Join-Path $folder 'local-ai.cmd'
    }

    It 'pauses <When>: <Arguments>, exit code <Code>' -ForEach @(
        @{ When = 'after status'; Arguments = 'status'; Code = 0; Pauses = $true }
        @{ When = 'after a degraded status'; Arguments = 'STATUS'; Code = 2; Pauses = $true }
        @{ When = 'not after status -Json'; Arguments = 'status -Json'; Code = 0; Pauses = $false }
        @{ When = 'not after a degraded status -json'; Arguments = 'status -json'; Code = 2; Pauses = $false }
        @{ When = 'not after status -j, a prefix PowerShell binds to -Json'; Arguments = 'status -j'; Code = 0; Pauses = $false }
        @{ When = 'not after a degraded status -JSO'; Arguments = 'status -JSO'; Code = 2; Pauses = $false }
        @{ When = 'not after status --json'; Arguments = 'status --json'; Code = 0; Pauses = $false }
        @{ When = 'after a failed status -NoBrowser, which is no -Json'; Arguments = 'status -NoBrowser'; Code = 1; Pauses = $true }
        @{ When = 'not after a start that succeeded'; Arguments = 'start'; Code = 0; Pauses = $false }
        @{ When = 'not after no verb'; Arguments = ''; Code = 0; Pauses = $false }
        @{ When = 'after a failed start'; Arguments = 'start'; Code = 1; Pauses = $true }
        @{ When = 'after a degraded stop'; Arguments = 'stop'; Code = 2; Pauses = $true }
        @{ When = 'after an update that succeeded'; Arguments = 'update'; Code = 0; Pauses = $true }
        @{ When = 'after an Update that succeeded, in any case'; Arguments = 'Update'; Code = 0; Pauses = $true }
    ) {
        $saved = $env:LOCALAI_STUB_CODE
        try {
            $env:LOCALAI_STUB_CODE = [string]$Code
            # echo. answers the pause, whose prompt follows the stub's output in the language of Windows.
            $output = @(& cmd.exe /d /c "echo.| `"$cmd`" $Arguments" 2>&1 | ForEach-Object { [string]$_ })
            $exit = $LASTEXITCODE
        } finally {
            $env:LOCALAI_STUB_CODE = $saved
        }
        $exit | Should -Be $Code
        $marker = [array]::IndexOf($output, 'STUB-OUT')
        $marker | Should -BeGreaterOrEqual 0
        $after = @($output | Select-Object -Skip ($marker + 1) | Where-Object { $_.Trim() })
        ($after.Count -gt 0) | Should -Be $Pauses
    }

    It 'gives Windows PowerShell its own module path, also when PowerShell 7 hands it one that names its own modules first' {
        # As PowerShell 7 does when it runs local-ai.cmd: its module path, which cmd.exe passes on unchanged, names its own Microsoft.PowerShell.Utility
        # first. Windows PowerShell cannot load that module and then lacks the commands its own one adds, such as Get-FileHash.
        $probeFolder = Join-Path $TestDrive 'cmd-modules'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $probeFolder 'src')
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'local-ai.cmd') -Destination $probeFolder
        [IO.File]::WriteAllText((Join-Path $probeFolder 'src\local-ai.ps1'), (@(
                    "`$found = if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) { 'found' } else { 'missing' }"
                    "Write-Output `"Get-FileHash `$found`""
                    "Write-Output `"PSModulePath `$env:PSModulePath`""
                ) -join "`r`n") + "`r`n")
        $core = Join-Path $TestDrive 'core-modules'
        $utility = Join-Path $core 'Microsoft.PowerShell.Utility'
        $null = New-Item -ItemType Directory -Force -Path $utility
        [IO.File]::WriteAllText((Join-Path $utility 'Microsoft.PowerShell.Utility.psd1'), (@(
                    '@{'
                    "    GUID = '1da87e53-152b-403e-98dc-74d7b4d63d59'"
                    "    ModuleVersion = '7.0.0.0'"
                    "    CompatiblePSEditions = @('Core')"
                    "    PowerShellVersion = '7.0'"
                    "    CmdletsToExport = @('Get-FileHash')"
                    '}'
                ) -join "`r`n") + "`r`n")
        $saved = $env:PSModulePath
        try {
            $env:PSModulePath = "$core;$saved"
            $output = @(& cmd.exe /d /c "echo.| `"$(Join-Path $probeFolder 'local-ai.cmd')`" start" 2>&1 | ForEach-Object { [string]$_ })
        } finally {
            $env:PSModulePath = $saved
        }
        $output | Should -Contain 'Get-FileHash found'
        $line = @($output | Where-Object { $_.StartsWith('PSModulePath ', [StringComparison]::Ordinal) })[0]
        $line | Should -Not -BeNullOrEmpty
        $line.IndexOf($core, [StringComparison]::OrdinalIgnoreCase) | Should -Be -1
    }
}

Describe 'Confirm-LocalAIAction' {
    BeforeEach {
        $answer = @{ Text = '' }
        $order = New-Object System.Collections.Generic.List[string]
        Mock Test-LocalAIConsoleInput -ModuleName LocalAI -MockWith { $true }
        Mock Clear-LocalAIConsoleInput -ModuleName LocalAI -MockWith { $order.Add('flush') }
        Mock Read-Host -ModuleName LocalAI -MockWith { $order.Add('ask'); $answer.Text }
    }

    It 'drops the keys typed ahead before it asks' {
        $answer.Text = 'y'
        $null = Invoke-ModuleFunction 'Confirm-LocalAIAction' @{ Question = 'Uninstall these now?' }
        @($order) | Should -Be @('flush', 'ask')
    }

    It "takes only the word '<Word>' as yes, in any case, when one is asked for: '<Text>' gives <Expected>" -ForEach @(
        @{ Word = 'delete'; Text = 'delete'; Expected = $true }
        @{ Word = 'delete'; Text = ' DELETE '; Expected = $true }
        @{ Word = 'delete'; Text = 'y'; Expected = $false }
        @{ Word = 'delete'; Text = 'yes'; Expected = $false }
        @{ Word = 'delete'; Text = ''; Expected = $false }
        @{ Word = 'delete'; Text = 'deleted'; Expected = $false }
    ) {
        $answer.Text = $Text
        Invoke-ModuleFunction 'Confirm-LocalAIAction' @{ Question = 'Delete these folders?'; Word = $Word } | Should -Be $Expected
        Should -Invoke Read-Host -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Prompt -ceq 'Delete these folders? Type delete to go ahead [delete/N]' }
    }

    It "returns <Expected> for the answer '<Text>', showing No as the default" -ForEach @(
        @{ Text = 'y'; Expected = $true }
        @{ Text = 'YES'; Expected = $true }
        @{ Text = ' yes '; Expected = $true }
        @{ Text = ''; Expected = $false }
        @{ Text = 'n'; Expected = $false }
        @{ Text = 'oui'; Expected = $false }
        @{ Text = 'yes please'; Expected = $false }
    ) {
        $answer.Text = $Text
        Invoke-ModuleFunction 'Confirm-LocalAIAction' @{ Question = 'Update these now?' } | Should -Be $Expected
        Should -Invoke Read-Host -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Prompt -ceq 'Update these now? [y/N]' }
    }

    It 'refuses without asking when this window cannot ask' {
        Mock Test-LocalAIConsoleInput -ModuleName LocalAI -MockWith { $false }
        { Invoke-ModuleFunction 'Confirm-LocalAIAction' @{ Question = 'Update these now?' } } | Should -Throw -ExpectedMessage ("This window cannot ask 'Update these now?', " +
            'since its input is redirected or PowerShell runs non-interactively, so nothing was changed. Run the command again in a console window.')
        Should -Invoke Read-Host -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'refuses when Read-Host cannot prompt, as with -NonInteractive' {
        Mock Read-Host -ModuleName LocalAI -MockWith { throw 'PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.' }
        { Invoke-ModuleFunction 'Confirm-LocalAIAction' @{ Question = 'Remove it?' } } |
            Should -Throw -ExpectedMessage "This window cannot ask 'Remove it?'*(PowerShell is in NonInteractive mode.*"
    }
}
