# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS: STOP
# -------------------------------------------------------
#
# Pester 6 tests for src\LocalAI.psm1 at stop: Stop-LocalAI, the Ollama app, and the helpers that
# stop and check the services. tests\LocalAI.TestSetup.ps1 imports the module and holds the shared
# helpers.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LocalAI.TestSetup.ps1')
}

Describe 'Stop-LocalAI and Stop-LocalAIService' {
    BeforeAll {
        $exe = 'C:\Users\User\.local\bin\open-webui.exe'
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $context = @{ Verb = 'stop'; Paths = $paths; Settings = $null; SettingsError = 'Invalid settings' }
        $record = @{
            Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431
            Listener = @{ Pid = 1624; StartTicks = 222; Path = 'C:\uv\python\python.exe' }
        }
        Write-LocalAIState -Path $paths.State -State @{
            Services = @{ OpenWebUI = $record }
            Ollama   = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat' }
            Model    = @{ Alias = 'local-chat' }
        }
        $world = @{ Alive = $true; Loaded = $false; Other = $null }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($world.Alive) { 'match' } else { 'other' } }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith {
            if ($world.Alive) { [pscustomobject]@{ Id = 1624; Name = 'python'; Path = 'C:\uv\python\python.exe'; StartTicks = 222 } } else { $world.Other }
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith { $world.Alive = $false; 0 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'ollama' } -MockWith { 0 }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            $models = @()
            if ($world.Loaded) { $models = @([pscustomobject]@{ name = 'local-chat:latest'; model = 'local-chat:latest' }) }
            [pscustomobject]@{ models = $models }
        }
        # What Ollama 0.40.11 answers to an unload request.
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Method -eq 'Post' } -MockWith {
            $world.Loaded = $false
            [pscustomobject]@{ model = 'local-chat'; done = $true; done_reason = 'unload' }
        }
        Mock Start-Sleep -ModuleName LocalAI -MockWith { [Threading.Thread]::Sleep(10) }
    }

    It 'stops a recorded service whose PID still matches with taskkill /T /F and drops its record' {
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 4242 /T /F'
        }
        $run.Printed | Should -BeLike '*Stopped OpenWebUI (PID 4242)*'
        (Read-LocalAIState -Path $paths.State).Services.ContainsKey('OpenWebUI') | Should -BeFalse
    }

    It 'stops ComfyUI, mcpo and the image gate, each with its process tree, before Open WebUI' {
        $comfyRecord = @{ Pid = 4300; StartTicks = 333; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18188 }
        $gateRecord = @{ Pid = 4400; StartTicks = 444; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18190; Listener = @{ Pid = 7900; StartTicks = 445; Path = 'C:\uv\python\python.exe' } }
        $filesRecord = @{ Pid = 4500; StartTicks = 555; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189; Listener = @{ Pid = 7950; StartTicks = 556; Path = 'C:\uv\python\python.exe' } }
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = $record; ImageGate = $gateRecord; ComfyUI = $comfyRecord; Files = $filesRecord } }
        $killed = New-Object System.Collections.Generic.List[string]
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($killed -contains [string]$Record.Pid) { 'other' } else { 'match' } }
        Mock Get-PortOwner -ModuleName LocalAI
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith { $killed.Add($ArgumentList[1]); 0 }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $killed | Should -Be @('4300', '4500', '4400', '4242')
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 4400 /T /F' }
        # /T takes the node server mcpo started along.
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 4500 /T /F' }
        $run.Printed | Should -BeLike '*Stopped ComfyUI (PID 4300)*Stopped Files (PID 4500)*Stopped ImageGate (PID 4400)*Stopped OpenWebUI (PID 4242)*'
        (Read-LocalAIState -Path $paths.State).Services.Count | Should -Be 0
    }

    It 'kills the recorded listener when only it still runs, and names it as the server the service left running' {
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($world.Alive -and $Record.Pid -eq 1624) { 'match' } else { 'other' } }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 1624 /T /F'
        }
        $run.Printed | Should -BeLike '*Stopped the server (PID 1624) that OpenWebUI (PID 4242) left running.*'
        $run.Printed | Should -Not -BeLike '*Stopped OpenWebUI (PID*'
    }

    It 'counts taskkill exit code 128, a process that already ended, as stopped once the poll confirms it' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            if ($SuccessCode -notcontains 128) { throw "'taskkill' failed with exit code 128." }
            $world.Alive = $false
            128
        }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Stopped OpenWebUI (PID 4242)*'
        Should -Invoke Get-RecordedProcessState -ModuleName LocalAI -ParameterFilter { $Record.Pid -eq 4242 }
        (Read-LocalAIState -Path $paths.State).Services.ContainsKey('OpenWebUI') | Should -BeFalse
    }

    It 'counts taskkill exit code 255, a process of the tree that ended by itself first, as stopped once the poll confirms it' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            $Capture.Add('Reason: There is no running instance of the task.')
            if ($SuccessCode -notcontains 255) { throw "'taskkill /PID 4242 /T /F' failed with exit code 255." }
            $world.Alive = $false
            255
        }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Stopped OpenWebUI (PID 4242).*'
        $run.Printed | Should -Not -BeLike '*Could not stop*'
        Should -Invoke Get-RecordedProcessState -ModuleName LocalAI -ParameterFilter { $Record.Pid -eq 4242 }
        (Read-LocalAIState -Path $paths.State).Services.ContainsKey('OpenWebUI') | Should -BeFalse
    }

    It 'still reports failed after taskkill exit code 255 when the process outlives the wait' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            if ($SuccessCode -notcontains 255) { throw "'taskkill /PID 4242 /T /F' failed with exit code 255." }
            255
        }
        $output = @(Stop-LocalAIService -Name 'OpenWebUI' -Record $record -TimeoutSeconds 1 6>&1)
        @($output | Where-Object { $_ -is [string] }) | Should -Be @('failed')
        $printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
        $printed | Should -Be 'OpenWebUI (PID 4242) still runs, or port 18431 is still held, 1 s after taskkill.'
    }

    It 'returns 1, keeps the record and prints in red when taskkill exits 255 but the process still runs after the wait' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            $Capture.Add('Reason: There is no running instance of the task.')
            if ($SuccessCode -notcontains 255) { throw "'taskkill /PID 4242 /T /F' failed with exit code 255." }
            255
        }
        # The verb waits its full 10 s.
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*OpenWebUI (PID 4242) still runs, or port 18431 is still held, 10 s after taskkill.*'
        $run.Printed | Should -BeLike '*could not be stopped*'
        $run.Printed | Should -Not -BeLike '*Stopped OpenWebUI*'
        (Read-LocalAIState -Path $paths.State).Services.OpenWebUI.Pid | Should -Be 4242
    }

    It 'reports stopped, names the program that took the port after taskkill, returns 0 and drops the record' {
        $other = [pscustomobject]@{ Id = 9100; Name = 'nginx'; Path = 'C:\nginx\nginx.exe'; StartTicks = $null }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            $world.Alive = $false
            # It started a second after taskkill ran.
            $other.StartTicks = [DateTime]::UtcNow.AddSeconds(1).Ticks
            $world.Other = $other
            0
        }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Stopped OpenWebUI (PID 4242). Port 18431 is now held by another program, nginx (PID 9100, C:\nginx\nginx.exe).*'
        $run.Printed | Should -Not -BeLike '*still runs*'
        (Read-LocalAIState -Path $paths.State).Services.ContainsKey('OpenWebUI') | Should -BeFalse
    }

    It 'still reports failed after the wait when the process ended but the program on the port <Case>' -ForEach @(
        @{ Case = 'started before taskkill ran, so it may belong to the tree it killed'; Owner = @{ Id = 9100; Name = 'nginx'; Path = 'C:\nginx\nginx.exe'; StartTicks = 5 } }
        @{ Case = 'has a start time that cannot be read'; Owner = @{ Id = 9100; Name = $null; Path = $null; StartTicks = $null } }
        @{ Case = 'is the recorded listener'; Owner = @{ Id = 1624; Name = 'python'; Path = 'C:\uv\python\python.exe'; StartTicks = 222 } }
    ) {
        $world.Other = [pscustomobject]$Owner
        $output = @(Stop-LocalAIService -Name 'OpenWebUI' -Record $record -TimeoutSeconds 1 6>&1)
        @($output | Where-Object { $_ -is [string] }) | Should -Be @('failed')
        $printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
        $printed | Should -Be 'OpenWebUI (PID 4242) still runs, or port 18431 is still held, 1 s after taskkill.'
    }

    It 'returns 1, kills nothing and keeps the record when the process runs but cannot be inspected' {
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'unreadable' }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*OpenWebUI (PID 4242) still runs, but this window may not inspect it*Run 'local-ai stop' from an elevated window*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' }
        (Read-LocalAIState -Path $paths.State).Services.OpenWebUI.Pid | Should -Be 4242
    }

    It 'drops a stale record without killing anything and names what holds the port now' {
        $world.Alive = $false
        $world.Other = [pscustomobject]@{ Id = 9100; Name = 'nginx'; Path = 'C:\nginx\nginx.exe'; StartTicks = 5 }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' }
        $run.Printed | Should -BeLike '*nothing was stopped*Port 18431 is now held by nginx (PID 9100, C:\nginx\nginx.exe)*'
        (Read-LocalAIState -Path $paths.State).Services.ContainsKey('OpenWebUI') | Should -BeFalse
    }

    It 'returns 1 and keeps the record when taskkill fails, printing what it said' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            $Capture.Add('ERROR: The process with PID 4242 (child process of PID 9) could not be terminated.')
            $Capture.Add('Reason: Access is denied.')
            throw "'taskkill /PID 4242 /T /F' failed with exit code 1."
        }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Could not stop OpenWebUI (PID 4242)*exit code 1*Access is denied*'
        (Read-LocalAIState -Path $paths.State).Services.OpenWebUI.Pid | Should -Be 4242
    }

    It 'reports failed when the process outlives the wait after taskkill' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith { 0 }
        Stop-LocalAIService -Name 'OpenWebUI' -Record $record -TimeoutSeconds 1 6>$null | Should -Be 'failed'
    }

    It 'unloads the chat model from the recorded server over REST and confirms it through /api/ps, leaving Ollama running' {
        $world.Loaded = $true
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq 'http://127.0.0.1:11434/api/generate' -and $ContentType -eq 'application/json' -and
            (@('{"model":"local-chat","keep_alive":0}', '{"keep_alive":0,"model":"local-chat"}') -contains $Body)
        }
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $Uri -eq 'http://127.0.0.1:11434/api/ps' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'ollama' }
        # state.json records no Ollama app, so local-ai did not start the one that runs.
        $run.Printed | Should -BeLike ('*Unloaded local-chat.*Ollama keeps running, since state.json records no Ollama app that local-ai started.*' +
            'Stop finished: stopped OpenWebUI, local-chat; Ollama keeps running.')
    }

    It 'sends no unload request when <Case>' -ForEach @(
        @{ Case = 'the model is not loaded'; Answers = $true }
        @{ Case = 'Ollama does not answer'; Answers = $false }
    ) {
        if (-not $Answers) { Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' } }
        (Invoke-StopVerb -Context $context).Code | Should -Be @(0)
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
    }

    It 'returns 1 when the unload request fails' {
        $world.Loaded = $true
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Method -eq 'Post' } -MockWith { throw 'The remote server returned an error: (500) Internal Server Error.' }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Could not unload local-chat*(500)*'
    }

    It 'says nothing was running when state.json records nothing' {
        Remove-Item -LiteralPath $paths.State
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*nothing was running*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }
}

Describe 'Stop-OllamaApp' {
    BeforeEach {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'start'
            Listener = @{ Pid = 200; StartTicks = 222; Path = 'C:\Ollama\ollama.exe' } }
        $serve = [pscustomobject]@{ Id = 200; Name = 'ollama'; Path = 'C:\Ollama\ollama.exe'; StartTicks = 222 }
        # Alive: the app and its server run; Held: the server holds the port; Quits: the app ends on WM_CLOSE; Free: polls until the port frees after it.
        $world = @{ Alive = $true; Held = $true; Quits = $true; Free = 0; Models = @(); Window = $false; Handle = [IntPtr]0x1234 }
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($world.Alive -and @(100, 200) -contains [int]$Record.Pid) { 'match' } else { 'other' } }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith {
            if ($world.Free -gt 0) {
                $world.Free--
                if ($world.Free -eq 0) { $world.Held = $false }
            }
            if ($world.Held) { $serve }
        }
        Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $world.Alive -and $ProcessId -eq 200 -and $AncestorId -eq 100 }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ models = @($world.Models) } }
        # No other program is connected to Ollama, and the app runs in this Windows session.
        Mock Get-LoopbackClient -ModuleName LocalAI
        Mock Test-ProcessInThisSession -ModuleName LocalAI -MockWith { $true }
        Mock Test-OllamaAppWindowOpen -ModuleName LocalAI -MockWith { $world.Window }
        Mock Find-OllamaAppWindow -ModuleName LocalAI -MockWith { $world.Handle }
        Mock Send-OllamaAppClose -ModuleName LocalAI -MockWith {
            if ($world.Quits) {
                $world.Alive = $false
                if ($world.Free -eq 0) { $world.Held = $false }
            }
            $true
        }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            $world.Alive = $false
            $world.Held = $false
            0
        }
        Mock Start-Sleep -ModuleName LocalAI
        # Run Stop-OllamaApp with $Extra added to its arguments and return @{ Result (its table); Printed (the host text joined) }.
        $quit = {
            param([hashtable]$Extra = @{})
            $arguments = @{ Record = $app; Url = 'http://127.0.0.1:11434'; Alias = 'local-chat' }
            foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
            $output = @(Invoke-ModuleFunction 'Stop-OllamaApp' $arguments 6>&1)
            @{
                Result  = @($output | Where-Object { $_ -is [hashtable] })[0]
                Printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
            }
        }
    }

    It 'quits the app through the window its PID owns, as the tray does, and waits for the app to end and the port to free' {
        # The look before the quit, and two polls after it, still find the server on the port.
        $world.Free = 4
        $run = & $quit
        $run.Result.Result | Should -Be 'stopped'
        $run.Printed | Should -Be 'Quit the Ollama app local-ai started (PID 100).'
        $run.Result.Reason | Should -Be $run.Printed
        Should -Invoke Find-OllamaAppWindow -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 100 }
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Handle -eq [IntPtr]0x1234 }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' }
        Should -Invoke Start-Sleep -ModuleName LocalAI -Times 3 -Exactly
    }

    It 'ends the app with taskkill /PID /T /F once, never /IM, when it does not quit within the timeout, and says so once it did' {
        $world.Quits = $false
        $run = & $quit
        $run.Result.Result | Should -Be 'forced'
        $run.Printed | Should -Be ("Stopped Ollama app (PID 100).`nThe Ollama app local-ai started (PID 100) did not quit within 20 s, so taskkill /T /F ended it, " +
            'its server and the models it held.')
        $run.Result.Reason | Should -BeLike 'The Ollama app local-ai started (PID 100) did not quit within 20 s*'
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Start-Sleep -ModuleName LocalAI -Times 40 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 100 /T /F' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains '/IM' }
    }

    It 'reports it forced and names the program that took the port after taskkill ended the app and its server' {
        $world.Quits = $false
        $other = [pscustomobject]@{ Id = 9300; Name = 'llama-server'; Path = 'C:\llama\llama-server.exe'; StartTicks = $null }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            $world.Alive = $false
            $world.Held = $false
            $other.StartTicks = [DateTime]::UtcNow.AddSeconds(1).Ticks
            $world.Other = $other
            0
        }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { if ($world.Held) { $serve } elseif ($world.Other) { $world.Other } }
        $run = & $quit
        $run.Result.Result | Should -Be 'forced'
        $run.Printed | Should -BeLike ('Stopped Ollama app (PID 100). Port 11434 is now held by another program, llama-server (PID 9300, C:\llama\llama-server.exe).*' +
            'taskkill /T /F ended it, its server and the models it held.')
    }

    It 'goes straight to taskkill for the verified PID when <Case>' -ForEach @(
        @{ Case = 'the app has no window'; NoWindow = $true; Why = 'has no window to ask it to quit' }
        @{ Case = 'Windows refuses the quit'; NoWindow = $false; Why = 'refused the request to quit' }
    ) {
        if ($NoWindow) { $world.Handle = [IntPtr]::Zero } else { Mock Send-OllamaAppClose -ModuleName LocalAI -MockWith { $false } }
        $run = & $quit
        $run.Result.Result | Should -Be 'forced'
        $run.Printed | Should -BeLike "Stopped Ollama app (PID 100).*The Ollama app local-ai started (PID 100) $Why, so taskkill /T /F ended it, its server*"
        Should -Invoke Start-Sleep -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 100 /T /F' }
        if ($NoWindow) { Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 0 -Exactly }
    }

    It 'keeps the app running when <Case>, killing nothing' -ForEach @(
        @{ Case = 'another program has a model loaded'; Setup = 'model'
            Message = ('Ollama still has qwen3:8b loaded, which another program may be using, so the Ollama app local-ai started (PID 100) keeps running. ' +
                "Ollama unloads an idle model after its keep-alive (5 minutes by default); run 'local-ai stop' again then, or quit the app from its tray icon.")
        }
        @{ Case = 'its window is open'; Setup = 'window'; Message = "The Ollama app local-ai started (PID 100) has a window open, so it keeps running; close that window*" }
        @{ Case = 'Ollama does not list its models while a server holds the port'; Setup = 'no list'; Message = 'Ollama does not list its loaded models at http://127.0.0.1:11434/api/ps (timed out)*keeps running*' }
        @{ Case = 'another program is still connected to Ollama'; Setup = 'client'
            Message = ('Ollama at http://127.0.0.1:11434 still has connections from node (PID 4400), PID 4401, which may still use it, so the Ollama app local-ai ' +
                "started (PID 100) keeps running; run 'local-ai stop' again once they are done, or quit the app from its tray icon.")
        }
        @{ Case = 'the programs connected to Ollama cannot be listed'; Setup = 'no clients'; Message = 'Cannot tell which programs are connected to Ollama on port 11434 (Access denied.)*keeps running*' }
        @{ Case = 'the app runs in another Windows session, whose windows stop cannot see'; Setup = 'session'
            Message = ("The Ollama app local-ai started (PID 100) runs in another Windows session, whose windows stop cannot see, so it keeps running; run " +
                "'local-ai stop' on that desktop, or quit the app from its tray icon.")
        }
    ) {
        switch ($Setup) {
            'model' { $world.Models = @([pscustomobject]@{ name = 'local-chat:latest'; model = 'local-chat:latest' }, [pscustomobject]@{ name = 'qwen3:8b'; model = 'qwen3:8b' }) }
            'window' { $world.Window = $true }
            'no list' { Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'timed out' } }
            'client' {
                Mock Get-LoopbackClient -ModuleName LocalAI -MockWith {
                    [pscustomobject]@{ Id = 4400; Name = 'node' }
                    [pscustomobject]@{ Id = 4401; Name = $null }
                }
            }
            'no clients' { Mock Get-LoopbackClient -ModuleName LocalAI -MockWith { throw 'Access denied.' } }
            'session' { Mock Test-ProcessInThisSession -ModuleName LocalAI -MockWith { $false } }
        }
        $run = & $quit
        $run.Result.Result | Should -Be 'kept'
        $run.Printed | Should -BeLike $Message
        $run.Result.Reason | Should -Be $run.Printed
        Should -Invoke Find-OllamaAppWindow -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'counts no connection of this window or of the app and its own processes as another program''s' {
        Mock Get-LoopbackClient -ModuleName LocalAI -MockWith { [pscustomobject]@{ Id = 210; Name = 'msedgewebview2' } }
        Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { ($world.Alive -and $ProcessId -eq 200 -and $AncestorId -eq 100) -or ($ProcessId -eq 210 -and $AncestorId -eq 100) }
        (& $quit).Result.Result | Should -Be 'stopped'
        Should -Invoke Get-LoopbackClient -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Port -eq 11434 -and $Exclude -contains $PID -and $Exclude -contains 100 }
        Should -Invoke Test-ProcessInThisSession -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 100 }
    }

    It 'ends with taskkill /PID <server> /T /F the server the app left running when the app ended only after the wait' {
        $world.Quits = $false
        $life = @{ App = $true; Serve = $true; Sleeps = 0 }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith {
            switch ([int]$Record.Pid) {
                100 { if ($life.App) { 'match' } else { 'other' } }
                200 { if ($life.Serve) { 'match' } else { 'other' } }
                default { 'other' }
            }
        }
        # The app ends at the last poll, and its server keeps the port.
        Mock Start-Sleep -ModuleName LocalAI -MockWith {
            $life.Sleeps++
            if ($life.Sleeps -eq 40) { $life.App = $false }
        }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { if ($life.Serve) { $serve } }
        Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $life.App -and $ProcessId -eq 200 -and $AncestorId -eq 100 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            if (($ArgumentList -join ' ') -eq '/PID 200 /T /F') { $life.Serve = $false }
            0
        }
        $run = & $quit
        $run.Result.Result | Should -Be 'forced'
        $run.Printed | Should -Be ("Stopped the server (PID 200) that Ollama app (PID 100) left running.`nThe Ollama app local-ai started (PID 100) did not quit " +
            'within 20 s, so taskkill /T /F ended the server it left running, with the models it held.')
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 200 /T /F' }
    }

    It 'fails, killing nothing, when neither the app nor its recorded server runs but the server the app ran last still holds the port' {
        $world.Quits = $false
        $life = @{ App = $true; Sleeps = 0 }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ([int]$Record.Pid -eq 100 -and $life.App) { 'match' } else { 'other' } }
        Mock Start-Sleep -ModuleName LocalAI -MockWith {
            $life.Sleeps++
            if ($life.Sleeps -eq 40) { $life.App = $false }
        }
        # The app restarted its server since state.json recorded the one before, PID 150; the newer one, PID 200, keeps the port after the app ends.
        $restarted = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'start'
            Listener = @{ Pid = 150; StartTicks = 150; Path = 'C:\Ollama\ollama.exe' } }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { $serve }
        Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $life.App -and $ProcessId -eq 200 -and $AncestorId -eq 100 }
        $run = & $quit @{ Record = $restarted }
        $run.Result.Result | Should -Be 'failed'
        $run.Printed | Should -BeLike ('*Ollama app (PID 100) is no longer running, or its PID belongs to another program now, so nothing was stopped. Port 11434 is ' +
            'now held by ollama (PID 200, C:\Ollama\ollama.exe).*The Ollama app local-ai started (PID 100), or its server on port 11434, still runs; see above.')
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'says the app ended by itself, killing nothing, when it is gone before taskkill and the port is free' {
        # The app ends just as stop finds it has no window.
        Mock Find-OllamaAppWindow -ModuleName LocalAI -MockWith {
            $world.Alive = $false
            $world.Held = $false
            [IntPtr]::Zero
        }
        $run = & $quit
        $run.Result.Result | Should -Be 'stopped'
        $run.Printed | Should -BeLike '*so nothing was stopped. Port 11434 is free.*The Ollama app local-ai started (PID 100) ended before taskkill ran.'
        $run.Printed | Should -Not -BeLike '*taskkill /T /F ended*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'quits the app when only the alias is loaded, or when nothing serves the port to list models' {
        $world.Models = @([pscustomobject]@{ name = 'local-chat:latest'; model = 'local-chat:latest' })
        (& $quit).Result.Result | Should -Be 'stopped'
        $world.Alive = $true
        $world.Held = $false
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        (& $quit).Result.Result | Should -Be 'stopped'
    }

    It 'leaves Ollama alone when <Case>' -ForEach @(
        @{ Case = 'the recorded app no longer runs'; Setup = 'gone'; Message = 'The Ollama app local-ai started (PID 100) no longer runs, or was restarted by an update or by you, so stop leaves Ollama as it is.' }
        @{ Case = 'the server is on another computer'; Setup = 'remote'; Message = 'Ollama at http://127.0.0.1:11434 runs on another computer, so stop quits no Ollama app for it.' }
    ) {
        if ($Setup -eq 'gone') { $world.Alive = $false } else { Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $false } }
        $run = & $quit
        $run.Result.Result | Should -Be 'stale'
        $run.Printed | Should -Be $Message
        Should -Invoke Find-OllamaAppWindow -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails without killing anything when the app cannot be inspected' {
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'unreadable' }
        $run = & $quit
        $run.Result.Result | Should -Be 'failed'
        $run.Printed | Should -BeLike "*still runs, but this window may not inspect it*Run 'local-ai stop' from an elevated window.*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails without killing anything when the windows cannot be read' {
        Mock Test-OllamaAppWindowOpen -ModuleName LocalAI -MockWith { throw 'Cannot add type. Compilation is not allowed.' }
        $run = & $quit
        $run.Result.Result | Should -Be 'failed'
        $run.Printed | Should -BeLike '*Cannot tell whether the Ollama app local-ai started (PID 100) has a window open*Compilation is not allowed.*'
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails when the app or its server outlives taskkill' {
        $world.Quits = $false
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith { 0 }
        $run = & $quit @{ TimeoutSeconds = 1 }
        $run.Result.Result | Should -Be 'failed'
        $run.Printed | Should -BeLike '*Ollama app (PID 100) still runs, or port 11434 is still held, 1 s after taskkill.*The Ollama app local-ai started (PID 100), or its server on port 11434, still runs; see above.'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' }
    }
}

Describe 'Stop-LocalAI and the Ollama app' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $context = @{ Verb = 'stop'; Paths = $paths; Settings = $null; SettingsError = 'Invalid settings' }
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'start'
            Listener = @{ Pid = 200; StartTicks = 222; Path = 'C:\Ollama\ollama.exe' } }
        $serve = [pscustomobject]@{ Id = 200; Name = 'ollama'; Path = 'C:\Ollama\ollama.exe'; StartTicks = 222 }
        Write-LocalAIState -Path $paths.State -State @{ Services = @{}; Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat'; App = $app } }
        $world = @{ Alive = $true; Quits = $true; Loaded = $true; Models = @(); Window = $false; Handle = [IntPtr]0x1234; Answers = $true }
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($world.Alive -and @(100, 200) -contains [int]$Record.Pid) { 'match' } else { 'other' } }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { if ($world.Alive) { $serve } }
        Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $world.Alive -and $ProcessId -eq 200 -and $AncestorId -eq 100 }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            if (-not $world.Answers) { throw 'Unable to connect to the remote server' }
            $models = @($world.Models)
            if ($world.Loaded) { $models += [pscustomobject]@{ name = 'local-chat:latest'; model = 'local-chat:latest' } }
            [pscustomobject]@{ models = $models }
        }
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Method -eq 'Post' } -MockWith {
            $world.Loaded = $false
            [pscustomobject]@{ model = 'local-chat'; done = $true; done_reason = 'unload' }
        }
        # Clients holds the programs still connected to Ollama; Session says whether the app runs in this Windows session.
        $world.Clients = @()
        $world.Session = $true
        Mock Get-LoopbackClient -ModuleName LocalAI -MockWith { $world.Clients }
        Mock Test-ProcessInThisSession -ModuleName LocalAI -MockWith { $world.Session }
        Mock Test-OllamaAppWindowOpen -ModuleName LocalAI -MockWith { $world.Window }
        Mock Find-OllamaAppWindow -ModuleName LocalAI -MockWith { $world.Handle }
        Mock Send-OllamaAppClose -ModuleName LocalAI -MockWith {
            if ($world.Quits) { $world.Alive = $false }
            $true
        }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'taskkill' } -MockWith {
            $world.Alive = $false
            0
        }
        Mock Start-Sleep -ModuleName LocalAI
    }

    It 'unloads the alias, then quits the app local-ai started through its window, never with taskkill, and drops the record' {
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Unloaded local-chat.*Quit the Ollama app local-ai started (PID 100).*Stop finished: stopped local-chat, Ollama.'
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Handle -eq [IntPtr]0x1234 }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        $state = Read-LocalAIState -Path $paths.State
        $state.Ollama.App | Should -BeNullOrEmpty
        $state.Ollama.Url | Should -Be 'http://127.0.0.1:11434'
    }

    It 'ends the app with taskkill /T /F on its PID exactly once, never /IM, when it does not quit in time' {
        $world.Quits = $false
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Stopped Ollama app (PID 100).*did not quit within 20 s, so taskkill /T /F ended it, its server and the models it held.*Stop finished: stopped local-chat, Ollama.'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 100 /T /F' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains '/IM' }
        (Read-LocalAIState -Path $paths.State).Ollama.App | Should -BeNullOrEmpty
    }

    It 'ends the verified app with taskkill when it has no window to ask' {
        $world.Handle = [IntPtr]::Zero
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*has no window to ask it to quit, so taskkill /T /F ended it, its server and the models it held.*Stop finished: stopped local-chat, Ollama.'
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'taskkill' -and ($ArgumentList -join ' ') -eq '/PID 100 /T /F' }
    }

    It 'says Ollama keeps running, and quits nothing, when state.json records no app' {
        Write-LocalAIState -Path $paths.State -State @{ Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat' } }
        $world.Loaded = $false
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Ollama keeps running, since state.json records no Ollama app that local-ai started.*Stop finished: Ollama keeps running.'
        Should -Invoke Find-OllamaAppWindow -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'says nothing of an Ollama that does not answer when state.json records no app' {
        Write-LocalAIState -Path $paths.State -State @{ Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat' } }
        $world.Answers = $false
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -Not -BeLike '*records no Ollama app*'
        $run.Printed | Should -BeLike '*Stop finished: nothing was running.'
    }

    It 'drops a stale record, killing nothing, and says why Ollama is left as it is' {
        $world.Alive = $false
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*The Ollama app local-ai started (PID 100) no longer runs, or was restarted by an update or by you*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        $state = Read-LocalAIState -Path $paths.State
        $state.Ollama.ContainsKey('App') | Should -BeTrue
        $state.Ollama.App | Should -BeNullOrEmpty
    }

    It 'returns 1, killing nothing and keeping the record, when the app cannot be inspected' {
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'unreadable' }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Stop finished, but Ollama could not be stopped; see above.'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 100
    }

    It 'returns 0 and keeps the app and its record when <Case>' -ForEach @(
        @{ Case = 'another program has a model loaded'; Setup = 'model'; Message = '*Ollama still has qwen3:8b loaded, which another program may be using*' }
        @{ Case = 'another program is still connected'; Setup = 'client'; Message = '*still has connections from python (PID 4500), which may still use it*' }
        @{ Case = 'the app runs in another Windows session'; Setup = 'session'; Message = '*runs in another Windows session, whose windows stop cannot see*' }
        @{ Case = 'the Ollama window is open'; Setup = 'window'; Message = '*has a window open, so it keeps running*' }
    ) {
        switch ($Setup) {
            'model' { $world.Models = @([pscustomobject]@{ name = 'qwen3:8b'; model = 'qwen3:8b' }) }
            'client' { $world.Clients = @([pscustomobject]@{ Id = 4500; Name = 'python' }) }
            'session' { $world.Session = $false }
            'window' { $world.Window = $true }
        }
        $run = Invoke-StopVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike $Message
        $run.Printed | Should -BeLike '*Stop finished: stopped local-chat; Ollama keeps running.'
        Should -Invoke Send-OllamaAppClose -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 100
    }

    It 'never quits Ollama with -KeepOllama, keeping the record' {
        Mock Stop-OllamaApp -ModuleName LocalAI
        $run = Invoke-StopVerb -Context $context -Arguments @{ KeepOllama = $true }
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Unloaded local-chat.*Stop finished: stopped local-chat; Ollama keeps running.'
        Should -Invoke Stop-OllamaApp -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Find-OllamaAppWindow -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 100
    }

    It 'stops the services first, then unloads the alias, then quits the app' {
        Write-LocalAIState -Path $paths.State -State @{
            Services = @{ OpenWebUI = @{ Pid = 4242; StartTicks = 1; Path = 'C:\uv\bin\open-webui.exe'; Port = 18431 } }
            Ollama   = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat'; App = $app }
        }
        $order = New-Object System.Collections.Generic.List[string]
        Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { $order.Add("service $Name"); 'stopped' }
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Method -eq 'Post' } -MockWith {
            $order.Add('unload')
            $world.Loaded = $false
            [pscustomobject]@{ done = $true }
        }
        Mock Stop-OllamaApp -ModuleName LocalAI -MockWith {
            $order.Add("quit $($Record.Pid) $Url $Alias")
            @{ Result = 'stopped'; Reason = 'Quit the Ollama app local-ai started (PID 100).' }
        }
        (Invoke-StopVerb -Context $context).Code | Should -Be @(0)
        @($order) | Should -Be @('service OpenWebUI', 'unload', 'quit 100 http://127.0.0.1:11434 local-chat')
    }
}

Describe 'Get-McpoPinDrift' {
    BeforeEach {
        $settings = @{ Files = @{ McpoVersion = '0.0.20'; McpoWith = @('mcp==1.30.0', 'fastapi<0.145'); McpoExcludeNewer = '2026-10-13T00:00:00Z'; Python = '3.12' } }
        $recorded = @{ McpoVersion = '0.0.20'; With = @('mcp==1.30.0', 'fastapi<0.145'); ExcludeNewer = '2026-10-13T00:00:00Z'; Python = '3.12' }
    }

    It 'names no pin when the stamp records the settings' {
        @(InModuleScope LocalAI -Parameters @{ S = $settings; R = $recorded } { param($S, $R) Get-McpoPinDrift -Settings $S -Recorded $R }) | Should -BeNullOrEmpty
    }

    It 'names all four pins when the stamp records no file tools' {
        InModuleScope LocalAI -Parameters @{ S = $settings } { param($S) Get-McpoPinDrift -Settings $S -Recorded $null } |
            Should -Be @('Files.McpoVersion', 'Files.McpoWith', 'Files.McpoExcludeNewer', 'Files.Python')
    }

    It 'names <Pin> when only it changed' -ForEach @(
        @{ Pin = 'Files.McpoVersion'; Key = 'McpoVersion'; Value = '0.0.19' }
        @{ Pin = 'Files.McpoWith'; Key = 'With'; Value = @('fastapi<0.145', 'mcp==1.30.0') }
        @{ Pin = 'Files.McpoExcludeNewer'; Key = 'ExcludeNewer'; Value = '' }
        @{ Pin = 'Files.Python'; Key = 'Python'; Value = '3.11' }
    ) {
        $recorded[$Key] = $Value
        InModuleScope LocalAI -Parameters @{ S = $settings; R = $recorded } { param($S, $R) Get-McpoPinDrift -Settings $S -Recorded $R } | Should -Be @($Pin)
    }
}

Describe 'Resolve-FolderPath' {
    It 'returns <Expected> for <Given>' -ForEach @(
        @{ Given = 'C:\Data\AI-Files\'; Expected = 'C:\Data\AI-Files' }
        @{ Given = 'C:\Data\notes\..\AI-Files\.'; Expected = 'C:\Data\AI-Files' }
        @{ Given = 'C:\'; Expected = 'C:\' }
    ) {
        InModuleScope LocalAI -Parameters @{ Given = $Given } { param($Given) Resolve-FolderPath -Path $Given } | Should -BeExactly $Expected
    }
}

Describe 'Resolve-OnDiskPath' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $base 'Real\Inner')
        $junction = Join-Path $base 'Via'
        $null = New-Item -ItemType Junction -Path $junction -Target (Join-Path $base 'Real')
        # Resolve <Given> in the module.
        $resolve = { param($Given) InModuleScope LocalAI -Parameters @{ Given = $Given } { param($Given) Resolve-OnDiskPath -Path $Given } }
        $onDiskBase = (& $resolve $base).Path
    }

    AfterEach {
        if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction, $false) }
    }

    It 'spells every existing folder as on disk and finds no link' {
        $found = & $resolve (Join-Path $base 'REAL\inner').ToUpperInvariant()
        $found.Path | Should -BeExactly (Join-Path $onDiskBase 'Real\Inner')
        $found.Link | Should -BeNullOrEmpty
    }

    It 'keeps a missing tail as given' {
        $found = & $resolve (Join-Path $base 'real\Missing\deeper')
        $found.Path | Should -BeExactly (Join-Path $onDiskBase 'Real\Missing\deeper')
        $found.Link | Should -BeNullOrEmpty
    }

    It 'names the first junction on the path' {
        $found = & $resolve (Join-Path $junction 'Inner')
        $found.Link | Should -BeExactly (Join-Path $onDiskBase 'Via')
        $found.Path | Should -BeExactly (Join-Path $onDiskBase 'Via\Inner')
    }

    It 'expands an 8.3 short name to the long one' {
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:ProgramFiles).ShortPath
        if ($short -eq $env:ProgramFiles) {
            Set-ItResult -Skipped -Because "$env:ProgramFiles has no 8.3 short name on this PC"
            return
        }
        (& $resolve $short).Path | Should -BeExactly $env:ProgramFiles
    }
}

Describe 'Get-OutsideLinkCount' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $first = Write-TestFile ((Split-Path $base -Leaf) + '\first.txt') 'one'
        $second = Join-Path $base 'second.txt'
        $null = New-Item -ItemType HardLink -Path $second -Target $first
        $alone = Write-TestFile ((Split-Path $base -Leaf) + '\alone.txt') 'alone'
        # Count the names of <Paths> in the module.
        $count = { param([string[]]$Paths) InModuleScope LocalAI -Parameters @{ Paths = $Paths } { param($Paths) Get-OutsideLinkCount -Path $Paths } }
    }

    It 'counts 0 for a file with one name and for a hard link whose names are all listed' {
        (& $count @($first, $second, $alone)) -join ',' | Should -Be '0,0,0'
    }

    It 'counts the names that are not listed, also in the \\?\ form' {
        (& $count @("\\?\$first", $alone)) -join ',' | Should -Be '1,0'
    }

    It 'counts a file another program holds open without sharing' {
        $stream = [IO.File]::Open($first, 'Open', 'ReadWrite', 'None')
        try { (& $count @($first)) -join ',' | Should -Be '1' } finally { $stream.Dispose() }
    }

    It 'gives -1 for a file that cannot be opened, and an empty list for none' {
        (& $count @((Join-Path $base 'missing.txt'), $alone)) -join ',' | Should -Be '-1,0'
        (& $count @()) -join ',' | Should -BeExactly ''
    }
}

Describe 'Get-BusyProcess' {
    BeforeEach {
        Mock Get-Process -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ Id = 10; Path = 'C:\Users\User\.local\bin\MCPO.exe' }
            [pscustomobject]@{ Id = 11; Path = 'C:\Users\User\AppData\Roaming\uv\tools\mcpo\Scripts\python.exe' }
            [pscustomobject]@{ Id = 12; Path = 'C:\Users\User\AppData\Roaming\uv\tools\mcpo-other\Scripts\python.exe' }
            [pscustomobject]@{ Id = 13; Path = $null }
        }
        # The PIDs Get-BusyProcess returns for <Folder> and <File>.
        $busy = { param([string[]]$Folder, [string[]]$File) @(InModuleScope LocalAI -Parameters @{ Folder = $Folder; File = $File } { param($Folder, $File) Get-BusyProcess -Folder $Folder -File $File } | ForEach-Object { $_.Id }) }
    }

    It 'finds a program by its file in any case' {
        & $busy @() @('c:\users\user\.local\bin\mcpo.exe') | Should -Be @(10)
    }

    It 'finds programs below a folder in any case, with or without a trailing backslash, but not in a folder that only starts alike' {
        & $busy @('C:\USERS\USER\AppData\Roaming\uv\tools\MCPO\') @() | Should -Be @(11)
        & $busy @('C:\Users\User\AppData\Roaming\uv\tools\mcpo') @() | Should -Be @(11)
    }

    It 'finds nothing for no folder and no file' {
        & $busy @() @() | Should -BeNullOrEmpty
    }
}

Describe 'Stop-RecordedFilesService' {
    BeforeEach {
        $statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\state.json')
        $state = @{ Services = @{ Files = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189 } } }
        $started = New-Object System.Collections.Generic.List[string]
        # Run Stop-RecordedFilesService in the module and return @{ Result; Warnings }.
        $stop = {
            $output = @(InModuleScope LocalAI -Parameters @{ State = $state; StatePath = $statePath; Started = $started } {
                    param($State, $StatePath, $Started)
                    Stop-RecordedFilesService -State $State -StatePath $StatePath -Started $Started 3>&1 6>$null
                })
            @{ Result = @($output | Where-Object { $_ -is [bool] }); Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) }
        }
    }

    It 'returns $true and drops the record when it stops the recorded mcpo' {
        Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'stopped' }
        $run = & $stop
        $run.Result | Should -Be @($true)
        $run.Warnings.Count | Should -Be 0
        $state.Services.ContainsKey('Files') | Should -BeFalse
        (Read-LocalAIState -Path $statePath).Services.ContainsKey('Files') | Should -BeFalse
    }

    It 'returns $false without a warning for a stale record, which it drops' {
        Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'stale' }
        $run = & $stop
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 0
        $state.Services.ContainsKey('Files') | Should -BeFalse
    }

    It 'returns $false, keeps the record and warns that mcpo still serves the folder when it cannot stop it' {
        Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'failed' }
        $run = & $stop
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        "$($run.Warnings[0])" | Should -BeExactly "The mcpo an earlier start left running still serves the file tools, since it could not be stopped. Run 'local-ai stop'."
        $state.Services.Files.Pid | Should -Be 4500
    }

    It 'stops nothing when state.json records no mcpo' {
        Mock Stop-LocalAIService -ModuleName LocalAI
        $state.Services.Remove('Files')
        (& $stop).Result | Should -Be @($false)
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }
}

Describe 'Write-LocalAIServiceWarning' {
    It 'leads with the Fallback of <Case>' -ForEach @(
        @{ Case = 'a service that has one'; Service = @{ DisplayName = 'Image gate'; Fallback = 'Images go to ComfyUI directly' }; Expected = 'Images go to ComfyUI directly: port 18190 is held.' }
        @{ Case = 'a service without one, with the generic text'; Service = @{ DisplayName = 'ComfyUI' }; Expected = 'ComfyUI is not available, and start goes on without it: port 18190 is held.' }
    ) {
        $warnings = @(InModuleScope LocalAI -Parameters @{ Service = $Service } { param($Service) Write-LocalAIServiceWarning -Service $Service -Reason 'port 18190 is held.' 3>&1 })
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeExactly $Expected
    }
}

Describe 'Complete-OptionalLocalAIService' {
    BeforeEach {
        $statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\state.json')
        $state = @{ Services = @{ ImageGate = @{ Pid = 4400; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18190 } } }
        $started = New-Object System.Collections.Generic.List[string]
        $started.Add('ImageGate')
        $service = @{ Name = 'ImageGate'; DisplayName = 'Image gate'; Port = 18190; Url = 'http://127.0.0.1:18190'; TimeoutSeconds = 15
            Fallback = 'Images go to ComfyUI directly'; Pin = @{ Setting = 'X.Version'; Version = '1.0.0'; Stamped = '0.9.0'; Running = $false; Hint = '' } }
        Mock Complete-LocalAIService -ModuleName LocalAI -MockWith { '1.0.0' }
        Mock Test-LoopbackListener -ModuleName LocalAI -MockWith { $true }
        Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'stopped' }
        # Run Complete-OptionalLocalAIService in the module with <Use> and <Installed>; return @{ Result; Warnings } with the warnings' text.
        $complete = {
            param([hashtable]$Use, [bool]$Installed)
            $output = @(InModuleScope LocalAI -Parameters @{ Service = $service; Use = $Use; State = $state; StatePath = $statePath; Started = $started; Installed = $Installed } {
                    param($Service, $Use, $State, $StatePath, $Started, $Installed)
                    Complete-OptionalLocalAIService -Service $Service -Use $Use -State $State -StatePath $StatePath -Started $Started -Installed $Installed 3>&1 6>$null
                })
            @{ Result = @($output | Where-Object { $_ -is [string] }); Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) }
        }
    }

    It 'waits for a service it launched, checks loopback and the pin, and returns its version' {
        $run = & $complete @{ Process = [pscustomobject]@{ Id = 4400 } } $false
        $run.Result | Should -Be @('1.0.0')
        Should -Invoke Complete-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Process.Id -eq 4400 -and $Service.Name -eq 'ImageGate' }
        Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Port -eq 18190 -and $Name -eq 'Image gate' }
        $run.Warnings | Should -Be @("Image gate 0.9.0 runs, but X.Version pins 1.0.0. Run 'local-ai update' to move to the pin.")
    }

    It 'takes the version of a reused service without waiting, and skips the pin right after install' {
        $run = & $complete @{ Version = '1.0.0'; Process = $null } $true
        $run.Result | Should -Be @('1.0.0')
        $run.Warnings.Count | Should -Be 0
        Should -Invoke Complete-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'warns with the Fallback, stops what this start launched and returns nothing when <Case>' -ForEach @(
        @{ Case = 'the wait fails'; Change = 'wait'; Expected = 'Images go to ComfyUI directly: Image gate exited with code 1.' }
        @{ Case = 'it listens beyond loopback'; Change = 'loopback'; Expected = 'Images go to ComfyUI directly: port 18190 does not listen on loopback only, as the warning above says.' }
    ) {
        switch ($Change) {
            'wait' { Mock Complete-LocalAIService -ModuleName LocalAI -MockWith { throw 'Image gate exited with code 1.' } }
            'loopback' { Mock Test-LoopbackListener -ModuleName LocalAI -MockWith { $false } }
        }
        $run = & $complete @{ Process = [pscustomobject]@{ Id = 4400 } } $true
        $run.Result | Should -BeNullOrEmpty
        $run.Warnings | Should -Be @($Expected)
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ImageGate' -and $Record.Pid -eq 4400 }
        $state.Services.ContainsKey('ImageGate') | Should -BeFalse
    }
}

Describe 'Get-OllamaModelCapability' {
    It 'posts the model to /api/show within 60 s and returns the capabilities it reports' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ capabilities = @('completion', 'tools', 'thinking') } }
        InModuleScope LocalAI { Get-OllamaModelCapability -Url 'http://127.0.0.1:11434' -Name 'local-chat' } | Should -Be @('completion', 'tools', 'thinking')
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq 'http://127.0.0.1:11434/api/show' -and $Body -eq '{"model":"local-chat"}' -and $TimeoutSec -eq 60 -and $UseBasicParsing
        }
    }

    It 'returns nothing when Ollama reports no capabilities' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ details = @{} } }
        @(InModuleScope LocalAI { Get-OllamaModelCapability -Url 'http://127.0.0.1:11434' -Name 'local-chat' }) | Should -BeNullOrEmpty
    }

    It 'throws when Ollama does not answer' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        { InModuleScope LocalAI { Get-OllamaModelCapability -Url 'http://127.0.0.1:11434' -Name 'local-chat' } } | Should -Throw -ExpectedMessage '*Unable to connect*'
    }
}

Describe 'Get-LocalAIEnvironmentHash' {
    # The hash of <Environment> in the module.
    BeforeAll {
        $hash = { param($Environment) InModuleScope LocalAI -Parameters @{ Environment = $Environment } { param($Environment) Get-LocalAIEnvironmentHash -Environment $Environment } }
    }

    It 'hashes NAME=value lines sorted by name, so the order of the table does not matter' {
        $expected = -join @([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("A=1`nB=2")) | ForEach-Object { $_.ToString('x2') })
        & $hash ([ordered]@{ B = '2'; A = '1' }) | Should -BeExactly $expected
        & $hash ([ordered]@{ A = '1'; B = '2' }) | Should -BeExactly $expected
    }

    It 'gives another hash when a value changes, also an empty one' {
        & $hash ([ordered]@{ A = '1'; B = '' }) | Should -Not -Be (& $hash ([ordered]@{ A = '1'; B = '2' }))
    }

    It 'hashes no table as the empty text' {
        & $hash $null | Should -BeExactly 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }

    Context 'with inherited names' {
        BeforeAll {
            # The hash of <Environment> and the names <Names> in the module.
            $hashWith = { param($Environment, $Names) InModuleScope LocalAI -Parameters @{ Environment = $Environment; Names = $Names } {
                    param($Environment, $Names) Get-LocalAIEnvironmentHash -Environment $Environment -InheritEnvironment $Names } }
            $sha = { param([string]$Text) -join @([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) }
        }

        It 'adds one line of the names in upper case, sorted and once each, after the NAME=value lines' {
            & $hashWith ([ordered]@{ B = '2'; A = '1' }) @('Path', 'cuda_path', 'PATH') | Should -BeExactly (& $sha "A=1`nB=2`nInheritEnvironment CUDA_PATH PATH")
            & $hashWith ([ordered]@{ A = '1' }) @('Path') | Should -BeExactly (& $sha "A=1`nInheritEnvironment PATH")
            & $hashWith $null @() | Should -BeExactly (& $sha 'InheritEnvironment ')
        }

        It 'gives another hash when a name is added, and the same hash when only the order or case of the names changes' {
            $environment = [ordered]@{ A = '1' }
            & $hashWith $environment @('Path', 'TEMP') | Should -Not -Be (& $hashWith $environment @('Path', 'TEMP', 'HTTPS_PROXY'))
            & $hashWith $environment @('Path', 'TEMP') | Should -BeExactly (& $hashWith $environment @('temp', 'PATH'))
        }

        It 'hashes no list as the table alone, as a record from before InheritEnvironment has it' {
            & $hashWith ([ordered]@{ A = '1' }) $null | Should -BeExactly (& $hash ([ordered]@{ A = '1' }))
            & $hashWith ([ordered]@{ A = '1' }) @() | Should -Not -Be (& $hash ([ordered]@{ A = '1' }))
        }
    }
}
