# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS: INSTALL
# -------------------------------------------------------
#
# Pester 6 tests for src\LocalAI.psm1 at install: winget, the Ollama server and app helpers, model
# and file checks, Install-LocalAI and the install of Open WebUI, mcpo, the files server, ComfyUI
# and the image model, and Test-FilesRoot. tests\LocalAI.TestSetup.ps1 imports the module and holds
# the shared helpers.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LocalAI.TestSetup.ps1')
}

Describe 'Install-WingetPackage' {
    BeforeAll {
        $package = @{ Id = 'Ollama.Ollama'; Command = 'ollama'; Scope = 'user' }
        $logDir = Join-Path $TestDrive 'winget-logs'
        $log = Join-Path $logDir 'winget-Ollama.Ollama.log'
    }

    BeforeEach {
        Mock Update-SessionPath -ModuleName LocalAI
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' }
        # 0x8A150014 NO_APPLICATIONS_FOUND, which 'winget list' returns for a missing package.
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'list' } -MockWith { -1978335212 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'install' } -MockWith { 0 }
    }

    It 'counts the package as present when its command is on PATH' {
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' } -MockWith { [pscustomobject]@{ Name = 'ollama.exe' } }
        Install-WingetPackage -Package $package -LogDir $logDir 6>$null | Should -Be 'present'
        Should -Invoke Update-SessionPath -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'counts the package as present when winget lists it' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'list' } -MockWith { 0 }
        Install-WingetPackage -Package $package -LogDir $logDir 6>$null | Should -Be 'present'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'list --id Ollama.Ollama -e --accept-source-agreements --disable-interactivity' -and
            $SuccessCode -contains -1978335212 -and $null -ne $Capture
        }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' }
    }

    It 'installs a missing package with --no-upgrade, its scope and a log, on the console' {
        Install-WingetPackage -Package $package -LogDir $logDir 6>$null | Should -Be 'installed'
        $expected = "install --id Ollama.Ollama -e --source winget --scope user --no-upgrade --silent --disable-interactivity --accept-source-agreements --accept-package-agreements --log $log"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq $expected -and [bool]$Console
        }
        Should -Invoke Update-SessionPath -ModuleName LocalAI -Times 2 -Exactly
        Test-Path -LiteralPath $logDir -PathType Container | Should -BeTrue
    }

    It 'maps winget exit code <Code> (<Meaning>) to <Outcome>' -ForEach @(
        @{ Code = 0; Meaning = 'success'; Outcome = 'installed' }
        @{ Code = -1978335135; Meaning = '0x8A150061 PACKAGE_ALREADY_INSTALLED'; Outcome = 'present' }
        @{ Code = -1978334963; Meaning = '0x8A15010D INSTALL_ALREADY_INSTALLED'; Outcome = 'present' }
        @{ Code = -1978335189; Meaning = '0x8A15002B UPDATE_NOT_APPLICABLE'; Outcome = 'present' }
        @{ Code = -1978335153; Meaning = '0x8A15004F UPGRADE_VERSION_NOT_NEWER'; Outcome = 'present' }
        @{ Code = -1978334967; Meaning = '0x8A150109 INSTALL_REBOOT_REQUIRED_TO_FINISH'; Outcome = 'restart' }
    ) {
        # Behaves like Invoke-Native: a code outside SuccessCode throws.
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'install' } -MockWith {
            if ($SuccessCode -notcontains $Code) { throw "'winget install' failed with exit code $Code." }
            $Code
        }
        Install-WingetPackage -Package $package -LogDir $logDir -WarningVariable warnings 3>$null 6>$null | Should -Be $Outcome
        $warnings.Count | Should -Be ([int]($Outcome -eq 'restart'))
    }

    It 'throws naming the log for exit code <Code> (<Meaning>)' -ForEach @(
        @{ Code = -1978335216; Meaning = '0x8A150010 NO_APPLICABLE_INSTALLER' }
        @{ Code = -1978334966; Meaning = '0x8A15010A INSTALL_REBOOT_REQUIRED_FOR_INSTALL' }
        @{ Code = -1978334965; Meaning = '0x8A15010B INSTALL_REBOOT_INITIATED' }
        @{ Code = 1; Meaning = 'an installer failure' }
    ) {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'install' } -MockWith {
            if ($SuccessCode -notcontains $Code) { throw "'winget install' failed with exit code $Code." }
            $Code
        }
        { Install-WingetPackage -Package $package -LogDir $logDir 6>$null } |
            Should -Throw -ExpectedMessage "*winget could not install Ollama.Ollama*exit code $Code.*$log*"
    }

    It 'adds what winget printed when the presence check fails unexpectedly' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'list' } -MockWith {
            $Capture.Add('Failed in attempting to update the source: winget')
            $Capture.Add('')
            throw "'winget list' failed with exit code -1978335217."
        }
        { Install-WingetPackage -Package $package -LogDir $logDir 6>$null } |
            Should -Throw -ExpectedMessage '*exit code -1978335217. winget said: Failed in attempting to update the source: winget'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' }
    }

    It 'says that machine scope asks for administrator approval before installing' {
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'node' }
        $node = @{ Id = 'OpenJS.NodeJS.LTS'; Command = 'node'; Scope = 'machine' }
        $printed = @(Install-WingetPackage -Package $node -LogDir $logDir 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $printed | Should -BeLike '*OpenJS.NodeJS.LTS for all users*administrator approval*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'install' -and ($ArgumentList -join ' ') -like '*--scope machine*'
        }
    }
}

Describe 'Wait-OllamaServer' {
    BeforeEach {
        Mock Start-Sleep -ModuleName LocalAI -MockWith { [Threading.Thread]::Sleep(50) }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { 0 }
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' } -MockWith { [pscustomobject]@{ Name = 'ollama.exe' } }
        # No app beside ollama.exe, so the start goes through 'ollama list'; the context below starts the app itself.
        Mock Resolve-OllamaAppPath -ModuleName LocalAI
        Mock Test-OllamaSetupRunning -ModuleName LocalAI -MockWith { $false }
        Mock Get-OllamaAppProcess -ModuleName LocalAI
        Mock Start-OllamaApp -ModuleName LocalAI -MockWith { throw 'Start-OllamaApp ran.' }
        # A server on this PC, and nothing holds its port.
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
        Mock Get-PortOwner -ModuleName LocalAI
    }

    It 'returns the version at once when the server answers' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ version = '0.40.11' } }
        Wait-OllamaServer -Url 'http://127.0.0.1:11434' 6>$null | Should -Be '0.40.11'
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Uri -eq 'http://127.0.0.1:11434/api/version' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'runs ollama list once on the console, then polls until the server answers' {
        $calls = @{ Count = 0 }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            $calls.Count++
            if ($calls.Count -lt 3) { throw 'Unable to connect to the remote server' }
            [pscustomobject]@{ version = '0.40.11' }
        }
        Wait-OllamaServer -Url 'http://127.0.0.1:11434' 6>$null | Should -Be '0.40.11'
        $calls.Count | Should -Be 3
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'ollama' -and ($ArgumentList -join ' ') -eq 'list' -and [bool]$Console -and
            $TimeoutSeconds -ge 1 -and $TimeoutSeconds -le 60
        }
    }

    It 'throws naming the URL and the reason after the timeout, never running serve' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        { Wait-OllamaServer -Url 'http://127.0.0.1:11434' -TimeoutSeconds 1 6>$null } |
            Should -Throw -ExpectedMessage '*did not answer at http://127.0.0.1:11434/api/version within 1 s (Unable to connect*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'serve' }
    }

    It 'adds the ollama list error to the timeout message' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "'ollama list' failed with exit code 1." }
        { Wait-OllamaServer -Url 'http://127.0.0.1:11434' -TimeoutSeconds 1 6>$null } |
            Should -Throw -ExpectedMessage "*Starting it with 'ollama list' failed: 'ollama list' failed with exit code 1.*"
    }

    It 'throws at once when the ollama program is not on PATH' {
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        { Wait-OllamaServer -Url 'http://127.0.0.1:11434' 6>$null } | Should -Throw -ExpectedMessage '*ollama program is not on PATH*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'only polls while OllamaSetup.exe runs, then throws naming the upgrade, starting nothing' {
        Mock Test-OllamaSetupRunning -ModuleName LocalAI -MockWith { $true }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        $printed = $null
        $failure = $null
        try {
            $null = Wait-OllamaServer -Url 'http://127.0.0.1:11434' -TimeoutSeconds 1 -PassThru -InformationVariable printed 6>$null
        } catch {
            $failure = $_.Exception.Message
        }
        $failure | Should -BeLike '*within 1 s while its upgrade (OllamaSetup.exe) was running*Wait for the upgrade to finish*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Get-OllamaAppProcess -ModuleName LocalAI -Times 0 -Exactly
        @($printed | Where-Object { "$_" -like '*waiting for the upgrade*' }).Count | Should -Be 1
    }

    It 'claims no app it started through ollama list, whose path it cannot know, and says stop leaves it running' {
        $calls = @{ Count = 0 }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            $calls.Count++
            if ($calls.Count -lt 2) { throw 'Unable to connect to the remote server' }
            [pscustomobject]@{ version = '0.40.13' }
        }
        $output = @(Wait-OllamaServer -Url 'http://127.0.0.1:11434' -PassThru 6>&1)
        $result = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
        $result.Version | Should -Be '0.40.13'
        $result.App | Should -BeNullOrEmpty
        $result.Started | Should -BeTrue
        $printed | Should -BeLike '*local-ai cannot tell that the Ollama app answering now is the one it started, so local-ai stop leaves it running.*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'ollama' -and ($ArgumentList -join ' ') -eq 'list' }
        Should -Invoke Get-OllamaAppProcess -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'only polls a server on another computer, starting nothing here, and throws naming it after the timeout' {
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $false }
        $calls = @{ Count = 0 }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            $calls.Count++
            if ($calls.Count -lt 3) { throw 'Unable to connect to the remote server' }
            [pscustomobject]@{ version = '0.40.13' }
        }
        $output = @(Wait-OllamaServer -Url 'http://gpu-box:11434' -PassThru 6>&1)
        $result = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
        $result.Version | Should -Be '0.40.13'
        $result.App | Should -BeNullOrEmpty
        $result.Started | Should -BeFalse
        # Said once, though it polled twice.
        @($printed | Where-Object { $_ -like '*gpu-box is another computer, so local-ai does not start the Ollama app here*' }).Count | Should -Be 1
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        { Wait-OllamaServer -Url 'http://gpu-box:11434' -TimeoutSeconds 1 6>$null } |
            Should -Throw -ExpectedMessage '*gpu-box is another computer, so local-ai does not start the Ollama app for it*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Get-PortOwner -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'only polls while another program holds the port, and throws naming it after the timeout' {
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { [pscustomobject]@{ Id = 4321; Name = 'java'; Path = 'C:\Tools\java.exe'; StartTicks = 5 } }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'The operation has timed out.' }
        $printed = $null
        $failure = $null
        try {
            $null = Wait-OllamaServer -Url 'http://127.0.0.1:11434' -TimeoutSeconds 1 -PassThru -InformationVariable printed 6>$null
        } catch {
            $failure = $_.Exception.Message
        }
        $failure | Should -BeLike ('*within 1 s (The operation has timed out.), and java (PID 4321, C:\Tools\java.exe) holds port 11434, so local-ai did not start ' +
            'the Ollama app. Close that program*')
        @($printed | Where-Object { "$_" -like '*but java (PID 4321) holds port 11434, so local-ai does not start the Ollama app*' }).Count | Should -Be 1
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'starts the app once the program that held the port has left it' {
        $world = @{ Calls = 0 }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { if ($world.Calls -lt 2) { [pscustomobject]@{ Id = 4321; Name = $null; Path = $null; StartTicks = 5 } } }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            $world.Calls++
            if ($world.Calls -lt 4) { throw 'Unable to connect to the remote server' }
            [pscustomobject]@{ version = '0.40.13' }
        }
        $printed = @(Wait-OllamaServer -Url 'http://127.0.0.1:11434' 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
        @($printed | Where-Object { $_ -like '*but a program (PID 4321) holds port 11434*' }).Count | Should -Be 1
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'ollama' -and ($ArgumentList -join ' ') -eq 'list' }
    }

    Context 'when the Ollama app lies beside ollama.exe' {
        BeforeEach {
            $appExe = 'C:\Users\User\AppData\Local\Programs\Ollama\ollama app.exe'
            $serve = [pscustomobject]@{ Id = 200; Name = 'ollama'; Path = 'C:\Users\User\AppData\Local\Programs\Ollama\ollama.exe'; StartTicks = 555 }
            # Apps lists what Win32_Process holds. Start-OllamaApp adds the PIDs in Start to it and gives back the PID in Returns.
            $world = @{ Apps = New-Object System.Collections.Generic.List[object]; Fails = 2; Calls = 0; Start = @(100); Returns = 100; Setup = 0 }
            Mock Resolve-OllamaAppPath -ModuleName LocalAI -MockWith { $appExe }
            Mock Get-OllamaAppProcess -ModuleName LocalAI -MockWith { $world.Apps.ToArray() }
            Mock Start-OllamaApp -ModuleName LocalAI -MockWith {
                foreach ($id in $world.Start) { $world.Apps.Add([pscustomobject]@{ Id = $id; Path = $appExe; StartTicks = [DateTime]::UtcNow.Ticks; ParentId = 9 }) }
                $world.Returns
            }
            Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
                $world.Calls++
                if ($world.Calls -le $world.Fails) { throw 'Unable to connect to the remote server' }
                [pscustomobject]@{ version = '0.40.13' }
            }
            Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
            # The server holds the port once it answers.
            Mock Get-PortOwner -ModuleName LocalAI -MockWith { if ($world.Calls -gt $world.Fails) { $serve } }
            Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $ProcessId -eq 200 -and $AncestorId -eq 100 -and $MaxDepth -eq 1 }
        }

        It 'starts nothing and claims no app when the server answers at once' {
            $world.Fails = 0
            $result = Wait-OllamaServer -Url 'http://127.0.0.1:11434' -PassThru 6>$null
            $result.Version | Should -Be '0.40.13'
            $result.App | Should -BeNullOrEmpty
            $result.Started | Should -BeFalse
            Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 0 -Exactly
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
            Should -Invoke Get-OllamaAppProcess -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'starts the app itself, not through ollama list, and returns the record of the app it started' {
            $output = @(Wait-OllamaServer -Url 'http://127.0.0.1:11434' -PassThru -How 'install' 6>&1)
            $result = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
            $printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
            $result.Version | Should -Be '0.40.13'
            $result.Started | Should -BeTrue
            $app = $result.App
            $app.Pid | Should -Be 100
            $app.Path | Should -Be $appExe
            $app.StartTicks | Should -Be $world.Apps[0].StartTicks
            $app.StartedTicks | Should -BeLessOrEqual $app.StartTicks
            $app.Port | Should -Be 11434
            $app.How | Should -Be 'install'
            $app.Listener.Pid | Should -Be 200
            $app.Listener.StartTicks | Should -Be 555
            $app.Listener.Path | Should -Be $serve.Path
            $printed | Should -BeLike '*Started the Ollama app (PID 100); local-ai stop quits it again.*'
            Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq $appExe }
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
            Should -Invoke Test-ProcessDescendant -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 200 -and $AncestorId -eq 100 -and $MaxDepth -eq 1 }
            # What Get-RecordedProcessState and Write-LocalAIState take.
            Write-LocalAIState -Path (Join-Path $TestDrive 'app-record.json') -State @{ Ollama = @{ App = $app } }
        }

        It 'still returns the version string without -PassThru, listing no apps' {
            $output = @(Wait-OllamaServer -Url 'http://127.0.0.1:11434' 6>&1)
            @($output | Where-Object { $_ -is [string] }) | Should -Be @('0.40.13')
            @($output | Where-Object { "$_" -like '*Started the Ollama app*' }).Count | Should -Be 0
            Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 1 -Exactly
            Should -Invoke Get-OllamaAppProcess -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'claims no app when <Case>' -ForEach @(
            @{ Case = 'an app already ran before the start'; Setup = 'before'; Says = $false }
            @{ Case = 'another program holds the port'; Setup = 'foreign listener'; Says = $true }
            @{ Case = 'two apps began'; Setup = 'two apps'; Says = $true }
            @{ Case = 'the app it started exited, as a second one does, while another began'; Setup = 'exited'; Says = $true }
            @{ Case = 'the app runs from another folder'; Setup = 'other path'; Says = $true }
        ) {
            switch ($Setup) {
                'before' {
                    $world.Apps.Add([pscustomobject]@{ Id = 50; Path = $appExe; StartTicks = [DateTime]::UtcNow.AddMinutes(-5).Ticks; ParentId = 9 })
                    # The second app exits at once, as one does while another runs.
                    $world.Start = @()
                }
                'foreign listener' { Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $false } }
                'two apps' { $world.Start = @(100, 101) }
                'exited' { $world.Start = @(101) }
                'other path' { Mock Resolve-OllamaAppPath -ModuleName LocalAI -MockWith { 'C:\Other\ollama app.exe' } }
            }
            $output = @(Wait-OllamaServer -Url 'http://127.0.0.1:11434' -PassThru 6>&1)
            $result = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
            $printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
            $result.Version | Should -Be '0.40.13'
            $result.App | Should -BeNullOrEmpty
            $result.Started | Should -BeTrue
            Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 1 -Exactly
            # An app that ran before answers for itself; for one it started but cannot tell apart, it says that stop leaves it running.
            ($printed -like '*cannot tell that the Ollama app answering now is the one it started, so local-ai stop leaves it running.*') | Should -Be $Says
            $printed | Should -Not -BeLike '*Started the Ollama app (PID*'
        }

        It 'starts the app once the upgrade has finished, but claims none, as the installer starts one too' {
            $world.Fails = 4
            Mock Test-OllamaSetupRunning -ModuleName LocalAI -MockWith {
                $world.Setup++
                $world.Setup -le 2
            }
            $printed = $null
            $result = Wait-OllamaServer -Url 'http://127.0.0.1:11434' -PassThru -InformationVariable printed 6>$null
            $result.Version | Should -Be '0.40.13'
            $result.App | Should -BeNullOrEmpty
            $result.Started | Should -BeTrue
            Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 1 -Exactly
            Should -Invoke Test-OllamaSetupRunning -ModuleName LocalAI -Times 3 -Exactly
            @($printed | Where-Object { "$_" -like '*waiting for the upgrade*' }).Count | Should -Be 1
            @($printed | Where-Object { "$_" -like '*Started the Ollama app (PID*' }).Count | Should -Be 0
        }

        It 'names the app in the timeout message when starting it failed' {
            Mock Start-OllamaApp -ModuleName LocalAI -MockWith { throw 'Access is denied.' }
            Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
            { Wait-OllamaServer -Url 'http://127.0.0.1:11434' -TimeoutSeconds 1 -PassThru 6>$null } |
                Should -Throw -ExpectedMessage "*Starting it with '$appExe' failed: Access is denied.*"
        }

        It 'names the app it started in the timeout message, as stop leaves an app it never claimed running' {
            Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
            { Wait-OllamaServer -Url 'http://127.0.0.1:11434' -TimeoutSeconds 1 -PassThru 6>$null } |
                Should -Throw -ExpectedMessage '*within 1 s (Unable to connect to the remote server). The Ollama app local-ai started (PID 100) may still come up; local-ai stop leaves it running.*'
            Should -Invoke Start-OllamaApp -ModuleName LocalAI -Times 1 -Exactly
        }
    }
}

Describe 'Ollama app helpers' {
    It 'lists the Ollama apps Win32_Process holds with their UTC start ticks' {
        $created = [datetime]::new(2026, 11, 2, 9, 30, 0, [DateTimeKind]::Local)
        Mock Get-CimInstance -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ ProcessId = [uint32]100; ExecutablePath = 'C:\Ollama\ollama app.exe'; CreationDate = $created; ParentProcessId = [uint32]9 }
            [pscustomobject]@{ ProcessId = [uint32]101; ExecutablePath = $null; CreationDate = $created; ParentProcessId = [uint32]9 }
        }
        $apps = @(Invoke-ModuleFunction 'Get-OllamaAppProcess')
        $apps.Count | Should -Be 2
        $apps[0].Id | Should -Be 100
        $apps[0].Path | Should -Be 'C:\Ollama\ollama app.exe'
        $apps[0].StartTicks | Should -Be $created.ToUniversalTime().Ticks
        $apps[0].ParentId | Should -Be 9
        $apps[1].Path | Should -BeNullOrEmpty
        Should -Invoke Get-CimInstance -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_Process' -and $Filter -eq "Name='ollama app.exe'" }
    }

    It 'throws when Win32_Process cannot be read, rather than reporting no app' {
        Mock Get-CimInstance -ModuleName LocalAI -MockWith { throw 'The RPC server is unavailable.' }
        { Invoke-ModuleFunction 'Get-OllamaAppProcess' } | Should -Throw -ExpectedMessage '*RPC server*'
    }

    It 'finds ollama app.exe beside the ollama program on PATH, and nothing when either is missing' {
        $folder = Join-Path $TestDrive 'Programs\Ollama'
        $null = Write-TestFile 'Programs\Ollama\ollama.exe' 'program'
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' } -MockWith { [pscustomobject]@{ Name = 'ollama.exe'; Path = (Join-Path $folder 'ollama.exe') } }
        Invoke-ModuleFunction 'Resolve-OllamaAppPath' | Should -BeNullOrEmpty
        $app = Write-TestFile 'Programs\Ollama\ollama app.exe' 'program'
        Invoke-ModuleFunction 'Resolve-OllamaAppPath' | Should -Be $app
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' }
        Invoke-ModuleFunction 'Resolve-OllamaAppPath' | Should -BeNullOrEmpty
    }

    It 'starts the app hidden, with the CLI''s arguments, from its own folder and without the console, returning its PID' {
        Mock Start-Process -ModuleName LocalAI -MockWith { [pscustomobject]@{ Id = 4321 } }
        Invoke-ModuleFunction 'Start-OllamaApp' @{ Path = 'C:\Ollama\ollama app.exe' } | Should -Be 4321
        Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Ollama\ollama app.exe' -and ($ArgumentList -join ' ') -eq '--hide --fast-startup' -and $WorkingDirectory -eq 'C:\Ollama' -and
            $PassThru -and -not $NoNewWindow
        }
    }

    It 'finds only the OllamaClass window of the given PID' {
        Mock Get-TopLevelWindow -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ Handle = [IntPtr]0x1111; ClassName = 'OllamaClass'; ProcessId = 7; Visible = $false; Owned = $false }
            [pscustomobject]@{ Handle = [IntPtr]0x2222; ClassName = 'Chrome_WidgetWin_1'; ProcessId = 100; Visible = $true; Owned = $false }
            [pscustomobject]@{ Handle = [IntPtr]0x3333; ClassName = 'ollamaclass'; ProcessId = 100; Visible = $false; Owned = $false }
            [pscustomobject]@{ Handle = [IntPtr]0x4444; ClassName = 'OllamaClass'; ProcessId = 100; Visible = $false; Owned = $false }
        }
        Invoke-ModuleFunction 'Find-OllamaAppWindow' @{ ProcessId = 100 } | Should -Be ([IntPtr]0x4444)
        Invoke-ModuleFunction 'Find-OllamaAppWindow' @{ ProcessId = 8 } | Should -Be ([IntPtr]::Zero)
    }

    It 'counts only a visible window without an owner of the given PID as an open window' {
        $windows = New-Object System.Collections.Generic.List[object]
        Mock Get-TopLevelWindow -ModuleName LocalAI -MockWith { $windows.ToArray() }
        $windows.Add([pscustomobject]@{ Handle = [IntPtr]0x4444; ClassName = 'OllamaClass'; ProcessId = 100; Visible = $false; Owned = $false })
        $windows.Add([pscustomobject]@{ Handle = [IntPtr]0x5555; ClassName = '#32768'; ProcessId = 100; Visible = $true; Owned = $true })
        $windows.Add([pscustomobject]@{ Handle = [IntPtr]0x6666; ClassName = 'Chrome_WidgetWin_1'; ProcessId = 7; Visible = $true; Owned = $false })
        Invoke-ModuleFunction 'Test-OllamaAppWindowOpen' @{ ProcessId = 100 } | Should -BeFalse
        $windows.Add([pscustomobject]@{ Handle = [IntPtr]0x7777; ClassName = 'Chrome_WidgetWin_1'; ProcessId = 100; Visible = $true; Owned = $false })
        Invoke-ModuleFunction 'Test-OllamaAppWindowOpen' @{ ProcessId = 100 } | Should -BeTrue
    }

    # Compiles the binding, as the keep-awake test does; it calls neither EnumWindows nor PostMessage.
    It 'compiles the window binding once, with the calls the helpers use' {
        $api = Invoke-ModuleFunction 'Get-LocalAIWindowApi'
        $api.FullName | Should -Be 'LocalAI.WindowApi'
        $api.GetMethod('GetTopLevelWindows') | Should -Not -BeNullOrEmpty
        $api.GetMethod('PostMessage') | Should -Not -BeNullOrEmpty
        Mock Add-Type -ModuleName LocalAI
        Invoke-ModuleFunction 'Get-LocalAIWindowApi' | Should -Be $api
        Should -Invoke Add-Type -ModuleName LocalAI -Times 0 -Exactly
    }

    Context 'Save-OllamaRecord' {
        BeforeEach {
            $statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\state.json')
            $earlier = @{ Pid = 90; StartTicks = 9; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; How = 'start' }
            $new = @{ Pid = 100; StartTicks = 10; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; How = 'update' }
            Write-LocalAIState -Path $statePath -State @{ Services = @{ OpenWebUI = @{ Pid = 4242 } }; Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'old'; App = $earlier } }
            $found = @{ State = 'match' }
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { $found.State }
            # 192.0.2.20 stands for another computer.
            Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $HostName -ne '192.0.2.20' }
            $save = {
                param([hashtable]$App, [string]$Url = 'http://127.0.0.1:11434')
                Invoke-ModuleFunction 'Save-OllamaRecord' @{ Path = $statePath; Url = $Url; Alias = 'local-chat'; App = $App }
            }
        }

        It 'records a new app over an earlier one, keeping the rest of state.json' {
            (& $save $new 'http://127.0.0.1:11500').Pid | Should -Be 100
            $state = Read-LocalAIState -Path $statePath
            $state.Ollama.App.Pid | Should -Be 100
            $state.Ollama.App.How | Should -Be 'update'
            $state.Ollama.Url | Should -Be 'http://127.0.0.1:11500'
            $state.Ollama.Alias | Should -Be 'local-chat'
            $state.Services.OpenWebUI.Pid | Should -Be 4242
            Should -Invoke Get-RecordedProcessState -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'keeps the earlier app while it runs as recorded <Case>, and drops it once it does not' -ForEach @(
            @{ Case = 'and this window can inspect it'; State = 'match' }
            @{ Case = 'but this window may not inspect it, as stop and status still count it'; State = 'unreadable' }
        ) {
            $found.State = $State
            (& $save $null).Pid | Should -Be 90
            (Read-LocalAIState -Path $statePath).Ollama.App.Pid | Should -Be 90
            Should -Invoke Get-RecordedProcessState -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Record.Pid -eq 90 }
            $found.State = 'other'
            & $save $null | Should -BeNullOrEmpty
            $state = Read-LocalAIState -Path $statePath
            $state.Ollama.ContainsKey('App') | Should -BeTrue
            $state.Ollama.App | Should -BeNullOrEmpty
        }

        It 'drops an earlier app that serves another port than the new Url, whose models stop would not see' {
            & $save $null 'http://127.0.0.1:11500' | Should -BeNullOrEmpty
            (Read-LocalAIState -Path $statePath).Ollama.App | Should -BeNullOrEmpty
            Should -Invoke Get-RecordedProcessState -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'drops an earlier app when the new Url names another computer, even on the same port' {
            & $save $null 'http://192.0.2.20:11434' | Should -BeNullOrEmpty
            $state = Read-LocalAIState -Path $statePath
            $state.Ollama.App | Should -BeNullOrEmpty
            $state.Ollama.Url | Should -Be 'http://192.0.2.20:11434'
            Should -Invoke Test-LocalHostName -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $HostName -eq '192.0.2.20' }
            Should -Invoke Get-RecordedProcessState -ModuleName LocalAI -Times 0 -Exactly
        }
    }
}

Describe 'Get-OllamaModelBlob' {
    BeforeAll {
        $pin = 'c0ba7beb68fd3fe47891bd549486d38dcf62d00817296ea314ad37017f5a4986'
        $projector = '05f662501f8bd45607b079723a3e238a4e888fd085a10a53f4057a0e250f6934'
        # 'ollama show --modelfile' output of Ollama 0.40.11 for a model imported from a GGUF, with
        # the user folder renamed.
        $imported = @(
            '# Modelfile generated by "ollama show"'
            '# To build a new Modelfile based on this, replace FROM with:'
            '# FROM old-chat:latest'
            ''
            "FROM C:\Users\User\.ollama\models\blobs\sha256-$pin"
            'TEMPLATE {{ .Prompt }}'
            'PARAMETER num_ctx 32768'
            ''
        )
        $shown = @{ Code = 0; Lines = $imported }
    }

    BeforeEach {
        Mock Invoke-Native -ModuleName LocalAI -MockWith {
            foreach ($line in $shown.Lines) { $Capture.Add($line) }
            $shown.Code
        }
    }

    It 'returns the digest and path from the FROM line Ollama 0.40.11 prints' {
        $shown.Code = 0
        $shown.Lines = $imported
        $blobs = @(Get-OllamaModelBlob -Name 'old-chat')
        $blobs.Count | Should -Be 1
        $blobs[0].Digest | Should -BeExactly $pin
        $blobs[0].Path | Should -BeExactly "C:\Users\User\.ollama\models\blobs\sha256-$pin"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'ollama' -and ($ArgumentList -join ' ') -eq 'show --modelfile old-chat' -and
            $SuccessCode -contains 1
        }
    }

    It 'returns the weights first, then the vision projector' {
        $shown.Code = 0
        $shown.Lines = @(
            '# Modelfile generated by "ollama show"'
            "FROM C:\Users\User\.ollama\models\blobs\sha256-$pin"
            "FROM C:\Users\User\.ollama\models\blobs\sha256-$($projector.ToUpperInvariant())"
            'RENDERER qwen3.5'
        )
        @(Get-OllamaModelBlob -Name 'local-chat' | ForEach-Object { $_.Digest }) | Should -Be @($pin, $projector)
    }

    It 'returns nothing when Ollama has no such model' {
        $shown.Code = 1
        $shown.Lines = @("Error: model 'hf.co/HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive:Q6_K' not found")
        @(Get-OllamaModelBlob -Name 'hf.co/HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive:Q6_K').Count | Should -Be 0
    }

    It 'throws with the output on any other failure' {
        $shown.Code = 1
        $shown.Lines = @('Error: could not connect to ollama app, is it running?')
        { Get-OllamaModelBlob -Name 'local-chat' } |
            Should -Throw -ExpectedMessage '*failed with exit code 1: Error: could not connect to ollama app*'
    }

    It 'throws when a FROM line is not a blob path' {
        $shown.Code = 0
        $shown.Lines = @('FROM qwen3.5:9b')
        { Get-OllamaModelBlob -Name 'local-chat' } | Should -Throw -ExpectedMessage '*not an Ollama blob*FROM qwen3.5:9b*'
    }

    It 'throws when there is no FROM line' {
        $shown.Code = 0
        $shown.Lines = @('# Modelfile generated by "ollama show"', 'PARAMETER num_ctx 32768')
        { Get-OllamaModelBlob -Name 'local-chat' } | Should -Throw -ExpectedMessage '*printed no FROM line*'
    }
}

Describe 'Confirm-FileHash' {
    BeforeEach {
        $blob = Write-TestFile ("blobs\" + [guid]::NewGuid().ToString('N')) 'weights'
        $digest = (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant()
        $verified = @{}
        $fix = 'Delete that file, then run install again.'
    }

    It 'hashes the file and records its length and write time' {
        Confirm-FileHash -Path $blob -Digest $digest -Verified $verified -Fix $fix 6>$null
        $file = Get-Item -LiteralPath $blob
        $verified[$digest].Length | Should -Be $file.Length
        $verified[$digest].WriteTicks | Should -Be $file.LastWriteTimeUtc.Ticks
    }

    It 'skips the hash while length and write time are unchanged' {
        Confirm-FileHash -Path $blob -Digest $digest -Verified $verified -Fix $fix 6>$null
        Mock Get-FileHash -ModuleName LocalAI
        Confirm-FileHash -Path $blob -Digest $digest -Verified $verified -Fix $fix 6>$null
        Should -Invoke Get-FileHash -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'hashes again after the file changed, and throws naming both hashes and the fix when it no longer matches' {
        Confirm-FileHash -Path $blob -Digest $digest -Verified $verified -Fix $fix 6>$null
        [IO.File]::WriteAllText($blob, 'damaged')
        (Get-Item -LiteralPath $blob).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(1)
        $actual = (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant()
        { Confirm-FileHash -Path $blob -Digest $digest -Verified $verified -Fix $fix 6>$null } |
            Should -Throw -ExpectedMessage "$blob hashes to $actual, not to $digest. Delete that file, then run install again."
    }

    It 'throws when the file is missing' {
        { Confirm-FileHash -Path (Join-Path $TestDrive 'blobs\missing') -Digest $digest -Verified $verified -Fix $fix } | Should -Throw
    }
}

Describe 'Test-LocalHostName' {
    BeforeEach {
        Mock Get-NetIPAddress -ModuleName LocalAI -MockWith {
            @([pscustomobject]@{ IPAddress = '192.0.2.20' }, [pscustomobject]@{ IPAddress = 'fe80::1%12' })
        }
    }

    It 'treats <HostName> as this PC' -ForEach @(
        @{ HostName = 'localhost' }
        @{ HostName = '127.0.0.1' }
        @{ HostName = '127.0.0.2' }
        @{ HostName = '[::1]' }
        @{ HostName = '192.0.2.20' }
        @{ HostName = '[fe80::1]' }
    ) {
        Test-LocalHostName -HostName $HostName | Should -BeTrue
    }

    It 'treats the computer name as this PC' {
        Test-LocalHostName -HostName ([Environment]::MachineName) | Should -BeTrue
    }

    It 'treats an address no adapter holds as another computer' {
        Test-LocalHostName -HostName '203.0.113.5' | Should -BeFalse
    }

    It 'treats a name DNS cannot resolve as another computer' {
        Test-LocalHostName -HostName 'local-ai-no-such-host.invalid' | Should -BeFalse
    }
}

Describe 'Test-ChatModelPin' {
    BeforeAll {
        $weights = [pscustomobject]@{ Digest = 'a' * 64; Path = 'C:\blobs\a' }
        $projector = [pscustomobject]@{ Digest = 'b' * 64; Path = 'C:\blobs\b' }
    }

    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'both pins matching'; Blobs = 2; WeightsPin = 'a'; ProjectorPin = 'b'; Expected = $true }
        @{ Case = 'no model'; Blobs = 0; WeightsPin = 'a'; ProjectorPin = 'b'; Expected = $false }
        @{ Case = 'other weights'; Blobs = 2; WeightsPin = 'c'; ProjectorPin = 'b'; Expected = $false }
        @{ Case = 'other projector'; Blobs = 2; WeightsPin = 'a'; ProjectorPin = 'c'; Expected = $false }
        @{ Case = 'a missing projector'; Blobs = 1; WeightsPin = 'a'; ProjectorPin = 'b'; Expected = $false }
        @{ Case = 'empty pins'; Blobs = 1; WeightsPin = ''; ProjectorPin = ''; Expected = $true }
    ) {
        $model = @{
            Sha256          = $(if ($WeightsPin) { $WeightsPin * 64 } else { '' })
            ProjectorSha256 = $(if ($ProjectorPin) { $ProjectorPin * 64 } else { '' })
        }
        $given = @($weights, $projector)[0..($Blobs - 1)]
        if ($Blobs -eq 0) { $given = @() }
        InModuleScope LocalAI -Parameters @{ Given = $given; Model = $model } {
            param($Given, $Model)
            Test-ChatModelPin -Blobs $Given -Model $Model
        } | Should -Be $Expected
    }
}

Describe 'Test-FreeSpace' {
    It 'passes when the drive has the bytes plus 10 percent free' {
        Mock Get-PSDrive -ModuleName LocalAI -MockWith { [pscustomobject]@{ Free = 12GB } }
        { Test-FreeSpace -Path 'C:\Users\User\.ollama\models' -RequiredBytes 10GB } | Should -Not -Throw
        Should -Invoke Get-PSDrive -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'C' }
    }

    It 'throws naming the drive, the free and the needed GB' {
        Mock Get-PSDrive -ModuleName LocalAI -MockWith { [pscustomobject]@{ Free = 5GB } }
        { Test-FreeSpace -Path 'd:\models' -RequiredBytes 10GB } |
            Should -Throw -ExpectedMessage "*Drive D: has 5.0 GB free, but 'd:\models' needs 11.0 GB (10.0 GB plus 10 percent headroom)*"
    }

    It 'counts the 10 percent headroom' {
        Mock Get-PSDrive -ModuleName LocalAI -MockWith { [pscustomobject]@{ Free = 10.5GB } }
        { Test-FreeSpace -Path 'C:\models' -RequiredBytes 10GB } | Should -Throw -ExpectedMessage '*needs 11.0 GB*'
    }

    It 'does nothing when no bytes are needed' {
        Mock Get-PSDrive -ModuleName LocalAI
        Test-FreeSpace -Path 'C:\models' -RequiredBytes 0
        Should -Invoke Get-PSDrive -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'only warns for a path without a drive letter' {
        Mock Get-PSDrive -ModuleName LocalAI
        Test-FreeSpace -Path '\\server\share\models' -RequiredBytes 1GB -WarningVariable warnings 3>$null
        "$($warnings[0])" | Should -BeLike "*Cannot read the free space for '\\server\share\models'*1.1 GB*"
        Should -Invoke Get-PSDrive -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'reads a real drive for a folder that does not exist yet' {
        { Test-FreeSpace -Path (Join-Path $TestDrive 'not\yet\there') -RequiredBytes 1 } | Should -Not -Throw
    }
}

Describe 'Install-ChatModel' {
    BeforeAll {
        $source = 'hf.co/Example/Chat-GGUF:Q6_K'
        $pin = 'c0ba7beb68fd3fe47891bd549486d38dcf62d00817296ea314ad37017f5a4986'
        $projector = '05f662501f8bd45607b079723a3e238a4e888fd085a10a53f4057a0e250f6934'
        $other = 'ab' * 32
        $url = 'http://127.0.0.1:11434'
    }

    BeforeEach {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $tracked = Write-TestFile ((Split-Path $repo -Leaf) + '\config\local-chat.Modelfile') "# Tracked.`nFROM $source`nPARAMETER num_ctx 32768`n"
        $trackedSha = (Get-FileHash -LiteralPath $tracked -Algorithm SHA256).Hash.ToLowerInvariant()
        $paths = Get-LocalAIPaths -Root (Join-Path $repo 'root')
        $settings = @{ Model = @{
                Alias = 'local-chat'; Source = $source; Sha256 = $pin; ProjectorSha256 = $projector; Size = 100
                Modelfile = 'config\local-chat.Modelfile'
            }
        }
        # What Ollama holds: the blob digests per model name (weights, then projector), and the
        # alias's capabilities.
        $ollama = @{ Digests = @{ $source = @($pin, $projector); 'local-chat' = @($pin, $projector) }; Capabilities = @('completion', 'tools', 'thinking') }
        # State as install leaves it when local-chat matches the tracked Modelfile and the pins.
        $current = @{ Model = @{ Alias = 'local-chat'; BaseDigest = $pin; ModelfileSha256 = $trackedSha } }
        $install = @{ Settings = $settings; Paths = $paths; Url = $url; RepoRoot = $repo }

        Mock Get-OllamaModelBlob -ModuleName LocalAI -MockWith {
            foreach ($digest in @($ollama.Digests[$Name])) {
                if ($digest) { [pscustomobject]@{ Digest = $digest; Path = "C:\models\blobs\sha256-$digest" } }
            }
        }
        Mock Confirm-FileHash -ModuleName LocalAI
        Mock Invoke-Native -ModuleName LocalAI -MockWith { 0 }
        # Like Ollama, a create from Model.Source gives the alias the source's blobs.
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'create' } -MockWith {
            $ollama.Digests['local-chat'] = $ollama.Digests[$source]
            0
        }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ capabilities = $ollama.Capabilities } }
    }

    It 'pulls, checks and creates when neither model exists, and records the result' {
        $ollama.Digests = @{}
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'pull' } -MockWith { $ollama.Digests[$source] = @($pin, $projector); 0 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'create' } -MockWith { $ollama.Digests['local-chat'] = @($pin, $projector); 0 }
        $state = Install-ChatModel @install -State @{} 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq "pull $source" -and [bool]$Console
        }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq "create local-chat -f $tracked" -and [bool]$Console
        }
        $state.Model.Alias | Should -Be 'local-chat'
        $state.Model.Source | Should -Be $source
        $state.Model.BaseDigest | Should -Be $pin
        $state.Model.ProjectorDigest | Should -Be $projector
        $state.Model.ModelfileSha256 | Should -Be $trackedSha
        $state.Model.Modelfile | Should -Be $tracked
        $state.Model.Capabilities | Should -Be @('completion', 'tools', 'thinking')
        $state.Model.MissingCapabilities.Count | Should -Be 0
    }

    It 'skips the pull and the create when the weights match the pin and state matches' {
        $state = Install-ChatModel @install -State $current 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        $state.Model.BaseDigest | Should -Be $pin
    }

    It 'creates the alias again, without a pull, when the Modelfile changed' {
        $current.Model.ModelfileSha256 = 'f' * 64
        $null = Install-ChatModel @install -State $current 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'create' }
    }

    It 'creates the alias when it is missing although state records it' {
        $ollama.Digests.Remove('local-chat')
        $null = Install-ChatModel @install -State $current 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'create' }
    }

    It 'creates the alias again when it was built on other weights' {
        $ollama.Digests['local-chat'] = @($other, $projector)
        $null = Install-ChatModel @install -State $current 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'create' }
    }

    It 'creates the alias when state has no record of it' {
        $null = Install-ChatModel @install -State @{} 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'create' }
    }

    It 'stops with both digests when the pulled weights differ from the pin, creating nothing' {
        $ollama.Digests[$source] = @($other, $projector)
        { Install-ChatModel @install -State $current 6>$null } |
            Should -Throw -ExpectedMessage "*SHA-256 $other, but Model.Sha256 pins $pin*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'pull' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'create' }
    }

    It 'warns and records it when the tools capability is missing' {
        $ollama.Capabilities = @('completion', 'thinking')
        $state = Install-ChatModel @install -State $current -WarningVariable warnings 3>$null 6>$null
        "$($warnings[0])" | Should -BeLike '*the tools capability for local-chat*'
        $state.Model.MissingCapabilities | Should -Be @('tools')
        $state.Model.Capabilities | Should -Be @('completion', 'thinking')
    }

    It 'throws without the completion capability' {
        $ollama.Capabilities = @('tools')
        { Install-ChatModel @install -State $current 6>$null } | Should -Throw -ExpectedMessage "*'completion' capability for local-chat*"
    }

    It 'reads the capabilities with POST /api/show for the alias' {
        $null = Install-ChatModel @install -State $current 6>$null
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq "$url/api/show" -and $Body -eq '{"model":"local-chat"}'
        }
    }

    It 'builds from the Modelfile in Root when it exists' {
        $override = Write-TestFile ((Split-Path $repo -Leaf) + '\root\local-chat.Modelfile') "FROM $source`nPARAMETER num_ctx 65536`n"
        $state = Install-ChatModel @install -State $current 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq "create local-chat -f $override"
        }
        $state.Model.Modelfile | Should -Be $override
    }

    It 'refuses a Modelfile whose FROM differs from Model.Source' {
        $null = Write-TestFile ((Split-Path $repo -Leaf) + '\root\local-chat.Modelfile') "FROM qwen3.5:9b`n"
        { Install-ChatModel @install -State $current 6>$null } | Should -Throw -ExpectedMessage "*builds FROM 'qwen3.5:9b', but Model.Source is '$source'*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'refuses a Modelfile with a second FROM line, which Ollama would build from' {
        $null = Write-TestFile ((Split-Path $repo -Leaf) + '\root\local-chat.Modelfile') "FROM $source`nFROM other-model`n"
        { Install-ChatModel @install -State $current 6>$null } | Should -Throw -ExpectedMessage '*exactly one FROM line*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'throws when the alias does not use the source blobs after create' {
        $ollama.Digests.Remove('local-chat')
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'create' } -MockWith {
            $ollama.Digests['local-chat'] = @($other)
            0
        }
        { Install-ChatModel @install -State $current 6>$null } |
            Should -Throw -ExpectedMessage "*local-chat uses the blobs '$other' instead of '$pin, $projector'*"
    }

    It 'stops when the vision projector differs from its pin' {
        $ollama.Digests[$source] = @($pin, $other)
        { Install-ChatModel @install -State $current 6>$null } |
            Should -Throw -ExpectedMessage "*projector of $source has SHA-256 $other, but Model.ProjectorSha256 pins $projector*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'create' }
    }

    It 'pulls when the pinned projector is missing, and stops when the pull does not bring it' {
        $ollama.Digests[$source] = @($pin)
        { Install-ChatModel @install -State $current 6>$null } |
            Should -Throw -ExpectedMessage "*projector of $source is missing, but Model.ProjectorSha256 pins $projector*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'pull' }
    }

    It 'warns about empty pins, skips the pull for a model that exists and checks no blob' {
        $settings.Model.Sha256 = ''
        $settings.Model.ProjectorSha256 = ''
        $state = Install-ChatModel @install -State $current -WarningVariable warnings 3>$null 6>$null
        @($warnings | ForEach-Object { "$_" }) | Should -BeLike '*is empty*'
        $warnings.Count | Should -Be 2
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'pull' }
        Should -Invoke Confirm-FileHash -ModuleName LocalAI -Times 0 -Exactly
        $state.Model.BaseDigest | Should -Be $pin
    }

    It 'hash-checks the pinned weights and projector and keeps the record in state' {
        Mock Confirm-FileHash -ModuleName LocalAI -MockWith { $Verified[$Digest] = @{ Length = 1; WriteTicks = 2 } }
        $state = Install-ChatModel @install -State $current 6>$null
        Should -Invoke Confirm-FileHash -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Digest -eq $pin -and $Path -eq "C:\models\blobs\sha256-$pin" -and $Fix -like '*Ollama blob is damaged*Delete that file*pull downloads it again*'
        }
        Should -Invoke Confirm-FileHash -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Digest -eq $projector }
        @($state.Model.VerifiedBlobs.Keys | Sort-Object) | Should -Be @(@($pin, $projector) | Sort-Object)
    }

    Context 'when create touches the blobs' {
        BeforeEach {
            # Real blob files, so the record holds their length and write time as Confirm-FileHash keeps them.
            $blobs = @{}
            foreach ($digest in $pin, $projector) {
                $blobs[$digest] = Write-TestFile ((Split-Path $repo -Leaf) + "\blobs\sha256-$digest") ('x' * 10)
                [IO.File]::SetLastWriteTimeUtc($blobs[$digest], [datetime]::new(2026, 10, 16, 0, 0, 0, [DateTimeKind]::Utc))
            }
            Mock Get-OllamaModelBlob -ModuleName LocalAI -MockWith {
                foreach ($digest in @($ollama.Digests[$Name])) { [pscustomobject]@{ Digest = $digest; Path = $blobs[$digest] } }
            }
            Mock Confirm-FileHash -ModuleName LocalAI -MockWith {
                $file = Get-Item -LiteralPath $Path
                $Verified[$Digest] = @{ Length = $file.Length; WriteTicks = $file.LastWriteTimeUtc.Ticks }
            }
            $touched = [datetime]::new(2026, 10, 27, 6, 59, 23, [DateTimeKind]::Utc)
            # Like Ollama 0.40.11, the create sets a new write time on the blobs the alias reuses.
            Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'create' } -MockWith {
                foreach ($path in $blobs.Values) { [IO.File]::SetLastWriteTimeUtc($path, $touched) }
                $ollama.Digests['local-chat'] = $ollama.Digests[$source]
                0
            }
            $current.Model.ModelfileSha256 = 'f' * 64
        }

        It 'records the write time the create left, so the next install does not hash them again' {
            $state = Install-ChatModel @install -State $current 6>$null
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'create' }
            foreach ($digest in $pin, $projector) {
                $state.Model.VerifiedBlobs[$digest].WriteTicks | Should -Be $touched.Ticks
                $state.Model.VerifiedBlobs[$digest].Length | Should -Be 10
            }
        }

        It 'keeps the old record of a blob whose length changed, so the next install hashes it' {
            Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq 'create' } -MockWith {
                [IO.File]::WriteAllText($blobs[$projector], 'x' * 11)
                [IO.File]::SetLastWriteTimeUtc($blobs[$projector], $touched)
                $ollama.Digests['local-chat'] = $ollama.Digests[$source]
                0
            }
            $state = Install-ChatModel @install -State $current 6>$null
            $before = [datetime]::new(2026, 10, 16, 0, 0, 0, [DateTimeKind]::Utc).Ticks
            $state.Model.VerifiedBlobs[$projector].WriteTicks | Should -Be $before
            $state.Model.VerifiedBlobs[$projector].Length | Should -Be 10
            $state.Model.VerifiedBlobs[$pin].WriteTicks | Should -Be $before
        }
    }
}

Describe 'Install-LocalAI' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $pin = 'c0ba7beb68fd3fe47891bd549486d38dcf62d00817296ea314ad37017f5a4986'
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $context = @{
            Verb     = 'install'
            Paths    = Get-LocalAIPaths -Root $root
            Settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
            RepoRoot = $repoRoot
        }
        Mock Set-LocalAIKeepAwake -ModuleName LocalAI
        Mock Update-SessionPath -ModuleName LocalAI
        Mock Resolve-OllamaUrl -ModuleName LocalAI -MockWith { 'http://127.0.0.1:11434' }
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' } -MockWith { [pscustomobject]@{ Name = 'ollama.exe' } }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { if ($PassThru) { [pscustomobject]@{ Version = '0.40.11'; App = $null } } else { '0.40.11' } }
        # No Ollama app runs, and none starts.
        Mock Get-OllamaAppProcess -ModuleName LocalAI
        Mock Resolve-OllamaAppPath -ModuleName LocalAI
        Mock Get-OllamaModelBlob -ModuleName LocalAI
        Mock Test-FreeSpace -ModuleName LocalAI
        Mock Install-WingetPackage -ModuleName LocalAI -MockWith { 'present' }
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
        Mock Test-LoopbackListener -ModuleName LocalAI -MockWith { $true }
        Mock Install-ChatModel -ModuleName LocalAI -MockWith {
            $State['Model'] = @{ Alias = 'local-chat'; BaseDigest = $pin; ModelfileSha256 = ('d' * 64) }
            $State
        }
        Mock Install-OpenWebUI -ModuleName LocalAI -MockWith {
            @{ Version = '0.12.4'; Path = 'C:\Users\User\.local\bin\open-webui.exe'; Python = '3.12.10'; ToolDir = 'C:\Users\User\AppData\Roaming\uv\tools'
                ExcludeNewer = '2026-10-25T08:10:00Z' }
        }
        $comfyPython = 'C:\Users\User\ComfyUI\.venv\Scripts\python.exe'
        $comfyCommit = $context.Settings.ComfyUI.Commit
        $checkpointSha = $context.Settings.Images.Sha256
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith {
            @{ Dir = 'C:\Users\User\ComfyUI'; Commit = $comfyCommit; Pinned = $true; Python = $comfyPython; PythonVersion = '3.13.18'
                Torch = '2.14.1+cu130'; TorchVision = '0.29.1+cu130'; Cuda = '13.0' }
        }
        Mock Install-ImageModel -ModuleName LocalAI -MockWith {
            $Verified[$checkpointSha] = @{ Length = 6939220250; WriteTicks = 42 }
            @{ Path = 'C:\Users\User\ComfyUI\models\checkpoints\DreamShaperXL_Lightning.safetensors'; Sha256 = $checkpointSha }
        }
        $filesEntry = @{ McpoVersion = '0.0.20'; McpoPath = 'C:\Users\User\.local\bin\mcpo.exe'; Python = '3.12'; With = @('mcp==1.30.0', 'fastapi<0.145')
            ServerVersion = '2.0.1'; Script = 'C:\x\index.js'; LockSha256 = ('5' * 64); Node = @{ Path = 'C:\Program Files\nodejs\node.exe'; Version = '24.22.1' }
            ToolDir = 'C:\Users\User\AppData\Roaming\uv\tools' }
        Mock Install-FilesServer -ModuleName LocalAI -MockWith { $filesEntry }
        Mock Test-FilesRoot -ModuleName LocalAI -MockWith { $true }
        # An empty model store of its own, so the free-space step never sees this PC's blobs.
        $savedStore = $env:OLLAMA_MODELS
        $store = Join-Path $root 'models'
        $env:OLLAMA_MODELS = $store
    }

    AfterEach {
        $env:OLLAMA_MODELS = $savedStore
    }

    It 'keeps the cut-off install-stamp.json recorded for an Open WebUI it left as it was, and records none it does not know' -ForEach @(
        @{ Case = 'recorded'; Recorded = @{ Version = '0.12.4'; ExcludeNewer = '2026-10-01T00:00:00Z' }; Expected = '2026-10-01T00:00:00Z' }
        @{ Case = 'never recorded'; Recorded = @{ Version = '0.12.4' }; Expected = $null }
    ) {
        Write-LocalAIState -Path (Join-Path $root 'install-stamp.json') -State @{ OpenWebUI = $Recorded }
        Mock Install-OpenWebUI -ModuleName LocalAI -MockWith {
            @{ Version = '0.12.4'; Path = 'C:\Users\User\.local\bin\open-webui.exe'; Python = '3.12.10'; ToolDir = 'C:\Users\User\AppData\Roaming\uv\tools' }
        }
        $null = @(Install-LocalAI -Context $context 6>&1)
        $entry = (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).OpenWebUI
        $entry.Version | Should -Be '0.12.4'
        if ($null -eq $Expected) { $entry.ContainsKey('ExcludeNewer') | Should -BeFalse } else { $entry.ExcludeNewer | Should -BeExactly $Expected }
    }

    It 'installs Ollama, uv, Git, the chat model, Open WebUI, ComfyUI and the checkpoint and writes the stamp and state, returning 0' {
        $printed = @(Install-LocalAI -Context $context 6>&1)
        @($printed | Where-Object { $_ -is [int] }) | Should -Be @(0)
        ($printed -join "`n") | Should -BeLike '*Open WebUI 0.12.4 is installed, as are ComfyUI and DreamShaperXL_Lightning.safetensors.*'
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 3 -Exactly
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Package.Id -eq 'Ollama.Ollama' -and $Package.Command -eq 'ollama' -and $LogDir -eq (Join-Path $root 'logs')
        }
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Package.Id -eq 'astral-sh.uv' -and $Package.Command -eq 'uv' -and $LogDir -eq (Join-Path $root 'logs')
        }
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Package.Id -eq 'Git.Git' -and $Package.Command -eq 'git' }
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Settings.ComfyUI.Ref -eq 'v0.42.5' -and $RepoRoot -eq $repoRoot }
        Should -Invoke Install-ImageModel -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Settings.Images.File -eq 'DreamShaperXL_Lightning.safetensors' }
        Should -Invoke Install-OpenWebUI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Settings.OpenWebUI.Version -eq '0.12.4' -and $Paths.Root -eq $root }
        Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Port -eq 11434 -and $Name -eq 'Ollama' -and $Fix -like "*'Expose Ollama to the network'*" -and $Fix -like '*OLLAMA_HOST*'
        }
        Should -Invoke Install-ChatModel -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Url -eq 'http://127.0.0.1:11434' -and $RepoRoot -eq $repoRoot
        }
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.Ollama.Version | Should -Be '0.40.11'
        $stamp.Model.Alias | Should -Be 'local-chat'
        $stamp.Model.BaseDigest | Should -Be $pin
        $stamp.Model.ModelfileSha256 | Should -Be ('d' * 64)
        $stamp.OpenWebUI.Version | Should -Be '0.12.4'
        $stamp.OpenWebUI.Path | Should -Be 'C:\Users\User\.local\bin\open-webui.exe'
        $stamp.OpenWebUI.Python | Should -Be '3.12.10'
        # What uninstall goes by: the tool folder, and the data folder when settings.psd1 does not load.
        $stamp.OpenWebUI.ToolDir | Should -Be 'C:\Users\User\AppData\Roaming\uv\tools'
        $stamp.OpenWebUI.DataDir | Should -Be ([IO.Path]::GetFullPath($context.Settings.OpenWebUI.DataDir))
        $stamp.OpenWebUI.ExcludeNewer | Should -BeExactly '2026-10-25T08:10:00Z'
        $stamp.ComfyUI.Dir | Should -Be 'C:\Users\User\ComfyUI'
        $stamp.ComfyUI.Commit | Should -Be $comfyCommit
        $stamp.ComfyUI.Ref | Should -Be 'v0.42.5'
        $stamp.ComfyUI.Pinned | Should -BeTrue
        $stamp.ComfyUI.Python | Should -Be $comfyPython
        $stamp.ComfyUI.PythonVersion | Should -Be '3.13.18'
        $stamp.ComfyUI.Torch | Should -Be '2.14.1+cu130'
        $stamp.Images.File | Should -Be 'DreamShaperXL_Lightning.safetensors'
        $stamp.Images.Sha256 | Should -Be $checkpointSha
        $state = Read-LocalAIState -Path (Join-Path $root 'state.json')
        $state.Model.BaseDigest | Should -Be $pin
        $state.Images.VerifiedFiles[$checkpointSha].Length | Should -Be 6939220250
    }

    It 'installs Git in the images step: after the chat parts and the file tools, before ComfyUI and the checkpoint' {
        $context.Settings.Files.Root = 'C:\Users\User\Documents'
        $order = New-Object System.Collections.Generic.List[string]
        Mock Install-WingetPackage -ModuleName LocalAI -MockWith { $order.Add($Package.Id); 'present' }
        Mock Install-ChatModel -ModuleName LocalAI -MockWith {
            $order.Add('ChatModel')
            $State['Model'] = @{ Alias = 'local-chat'; BaseDigest = $pin; ModelfileSha256 = ('d' * 64) }
            $State
        }
        Mock Install-OpenWebUI -ModuleName LocalAI -MockWith { $order.Add('OpenWebUI'); @{ Version = '0.12.4'; Path = 'C:\x\open-webui.exe'; Python = '3.12.10' } }
        Mock Install-FilesServer -ModuleName LocalAI -MockWith { $order.Add('Files'); $filesEntry }
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith { $order.Add('ComfyUI'); @{ Commit = $comfyCommit; Pinned = $true; Python = $comfyPython } }
        Mock Install-ImageModel -ModuleName LocalAI -MockWith { $order.Add('ImageModel'); @{ Path = 'C:\x'; Sha256 = $checkpointSha } }
        $null = Install-LocalAI -Context $context 6>$null
        $order | Should -Be @('Ollama.Ollama', 'astral-sh.uv', 'ChatModel', 'OpenWebUI', 'Files', 'Git.Git', 'ComfyUI', 'ImageModel')
    }

    It 'still installs the chat model and Open WebUI when Git fails, warns that images are not set up, and returns 2' {
        $said = 'winget could not install Git.Git (exit code 0x8A15000F); see C:\x\winget-Git.Git.log.'
        Mock Install-WingetPackage -ModuleName LocalAI -ParameterFilter { $Package.Id -eq 'Git.Git' } -MockWith { throw $said }
        $output = @(Install-LocalAI -Context $context 3>&1 6>&1)
        @($output | Where-Object { $_ -is [int] }) | Should -Be @(2)
        $warning = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        $warning.Count | Should -Be 1
        $warning[0] | Should -BeLike "Images are not set up: $said Chat works without them*'local-ai install' again*Images.Enabled*"
        ($output -join "`n") | Should -BeLike '*Install finished with 1 warning(s); see above.*'
        Should -Invoke Install-ChatModel -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Install-OpenWebUI -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Install-ImageModel -ModuleName LocalAI -Times 0 -Exactly
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.Model.Alias | Should -Be 'local-chat'
        $stamp.OpenWebUI.Version | Should -Be '0.12.4'
        $stamp.ContainsKey('ComfyUI') | Should -BeFalse
        $stamp.ContainsKey('Images') | Should -BeFalse
    }

    It 'stops with no chat model when <Id> fails, as before' -ForEach @(
        @{ Id = 'Ollama.Ollama' }
        @{ Id = 'astral-sh.uv' }
    ) {
        Mock Install-WingetPackage -ModuleName LocalAI -ParameterFilter { $Package.Id -eq $Id } -MockWith { throw 'winget failed' }
        { Install-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage 'winget failed'
        Should -Invoke Install-ChatModel -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Package.Id -eq 'Git.Git' }
    }

    It 'passes the checkpoint record state.json keeps to the checkpoint step' {
        Write-LocalAIState -Path (Join-Path $root 'state.json') -State @{ Images = @{ VerifiedFiles = @{ $checkpointSha = @{ Length = 1; WriteTicks = 2 } } } }
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Install-ImageModel -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Verified[$checkpointSha] -is [hashtable] }
    }

    It 'records no ComfyUI.Ref for a checkout at another commit' {
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith {
            Write-Warning 'ComfyUI in C:\Users\User\ComfyUI is at commit abcdef0123456789abcdef0123456789abcdef01.'
            @{ Commit = 'abcdef0123456789abcdef0123456789abcdef01'; Pinned = $false; Python = $comfyPython; PythonVersion = '3.13.14'; Torch = '2.14.1+cu130' }
        }
        Install-LocalAI -Context $context 3>$null 6>$null | Should -Be 2
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.ComfyUI.Commit | Should -Be 'abcdef0123456789abcdef0123456789abcdef01'
        $stamp.ComfyUI.Pinned | Should -BeFalse
        $stamp.ComfyUI.ContainsKey('Ref') | Should -BeTrue
        $stamp.ComfyUI.Ref | Should -BeNullOrEmpty
    }

    It 'records in the stamp whether install cloned the ComfyUI checkout, which uninstall -RemoveData reads' {
        Install-LocalAI -Context $context 6>$null | Should -Be 0
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).ComfyUI.Cloned | Should -BeFalse
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith {
            @{ Dir = 'C:\Users\User\ComfyUI'; Commit = $comfyCommit; Pinned = $true; Cloned = $true; Python = $comfyPython; PythonVersion = '3.13.18'; Torch = '2.14.1+cu130' }
        }
        Install-LocalAI -Context $context 6>$null | Should -Be 0
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).ComfyUI.Cloned | Should -BeTrue
    }

    It 'skips Git, ComfyUI and the checkpoint when Images.Enabled is off' {
        $context.Settings.Images.Enabled = $false
        Install-LocalAI -Context $context 6>$null | Should -Be 0
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 2 -Exactly
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Package.Id -eq 'Git.Git' }
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Install-ImageModel -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).ContainsKey('ComfyUI') | Should -BeFalse
    }

    It 'warns and returns 2 when <Step> fails, keeping the chat part of the stamp' -ForEach @(
        @{ Step = 'ComfyUI'; Command = 'Install-ComfyUI'; Message = 'torch 2.14.1 finds no CUDA device.' }
        @{ Step = 'the checkpoint'; Command = 'Install-ImageModel'; Message = 'The checkpoint has 5 bytes, but Images.Size pins 6939220250.' }
    ) {
        Mock $Command -ModuleName LocalAI -MockWith { throw $Message }
        $output = @(Install-LocalAI -Context $context 3>&1 6>$null)
        @($output | Where-Object { $_ -is [int] }) | Should -Be @(2)
        $warning = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        $warning.Count | Should -Be 1
        $warning[0] | Should -BeLike "Images are not set up: $Message Chat works without them*'local-ai install' again*Images.Enabled*"
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.OpenWebUI.Version | Should -Be '0.12.4'
        $stamp.Model.Alias | Should -Be 'local-chat'
        $stamp.ContainsKey('Images') | Should -BeFalse
        Should -Invoke Set-LocalAIKeepAwake -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { -not $Enabled }
    }

    It 'writes no checkpoint step after ComfyUI fails' {
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith { throw 'ComfyUI.Dir holds files but is not a git checkout.' }
        $null = Install-LocalAI -Context $context 3>$null 6>$null
        Should -Invoke Install-ImageModel -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).ContainsKey('ComfyUI') | Should -BeFalse
    }

    It 'drops the image entries an earlier install stamped when <Step> fails, so start cannot trust them' -ForEach @(
        @{ Step = 'ComfyUI'; Command = 'Install-ComfyUI'; KeepsComfyUI = $false }
        @{ Step = 'the checkpoint'; Command = 'Install-ImageModel'; KeepsComfyUI = $true }
    ) {
        $old = @{ Commit = 'abcdef0123456789abcdef0123456789abcdef01'; Python = 'C:\old\python.exe'; Dir = 'C:\old' }
        Write-LocalAIState -Path (Join-Path $root 'install-stamp.json') -State @{ ComfyUI = $old; Images = @{ File = 'DreamShaperXL_Lightning.safetensors'; Sha256 = $checkpointSha } }
        Mock $Command -ModuleName LocalAI -MockWith { throw 'it failed' }
        Install-LocalAI -Context $context 3>$null 6>$null | Should -Be 2
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.ContainsKey('Images') | Should -BeFalse
        $stamp.ContainsKey('ComfyUI') | Should -Be $KeepsComfyUI
        if ($KeepsComfyUI) { $stamp.ComfyUI.Python | Should -Be $comfyPython }
    }

    It 'keeps the image entries of an earlier install while Images.Enabled is off' {
        Write-LocalAIState -Path (Join-Path $root 'install-stamp.json') -State @{ ComfyUI = @{ Python = 'C:\old\python.exe' } }
        $context.Settings.Images.Enabled = $false
        $null = Install-LocalAI -Context $context 6>$null
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).ComfyUI.Python | Should -Be 'C:\old\python.exe'
    }

    It 'warns and returns 2 when the image workflow files do not load, which turns images off at start' {
        $context.Settings.Images.Workflow = Write-TestFile ((Split-Path $root -Leaf) + '\broken.json') '{ "3": '
        $output = @(Install-LocalAI -Context $context 3>&1 6>$null)
        @($output | Where-Object { $_ -is [int] }) | Should -Be @(2)
        "$(@($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })[0])" | Should -BeLike "Images are not set up: Cannot read Images.Workflow '*broken.json'*"
    }

    It 'keeps the PC awake while it runs and hands sleep back afterwards' {
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Set-LocalAIKeepAwake -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Enabled }
        Should -Invoke Set-LocalAIKeepAwake -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { -not $Enabled }
    }

    It 'checks free space for Model.Size when the model is not pulled' {
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $RequiredBytes -eq 8280963937 }
    }

    It 'skips the free-space check when the pulled blobs match the pins' {
        Mock Get-OllamaModelBlob -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ Digest = $context.Settings.Model.Sha256; Path = 'C:\models\blobs\w' }
            [pscustomobject]@{ Digest = $context.Settings.Model.ProjectorSha256; Path = 'C:\models\blobs\p' }
        }
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'counts only the blobs the store does not hold yet' {
        # The weights of an older alias already sit in the store under their digest.
        $null = Write-TestFile ((Split-Path $root -Leaf) + "\models\blobs\sha256-$pin") ('x' * 1000)
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $RequiredBytes -eq (8280963937 - 1000) -and $Path -eq $store
        }
    }

    It 'checks free space and waits for the server only after winget when Ollama is missing' {
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'ollama' }
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Get-OllamaModelBlob -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'stops before any step when Ollama.Url and the ollama program name different servers' {
        Mock Resolve-OllamaUrl -ModuleName LocalAI -ParameterFilter { $PesterBoundParameters.ContainsKey('UserHost') } -MockWith { 'http://127.0.0.1:11434' }
        Mock Resolve-OllamaUrl -ModuleName LocalAI -ParameterFilter { -not $PesterBoundParameters.ContainsKey('UserHost') } -MockWith { 'http://127.0.0.1:11500' }
        { Install-LocalAI -Context $context 6>$null } |
            Should -Throw -ExpectedMessage '*Ollama at http://127.0.0.1:11500, but the ollama program would use http://127.0.0.1:11434*'
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Set-LocalAIKeepAwake -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { -not $Enabled }
    }

    It 'checks the bind address when OLLAMA_HOST names this PC by a LAN address' {
        Mock Resolve-OllamaUrl -ModuleName LocalAI -MockWith { 'http://192.0.2.20:11434' }
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Test-LocalHostName -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $HostName -eq '192.0.2.20' }
        Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Port -eq 11434 }
    }

    It 'skips the bind check for Ollama on another computer' {
        Mock Resolve-OllamaUrl -ModuleName LocalAI -MockWith { 'http://203.0.113.5:11434' }
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $false }
        $printed = @(Install-LocalAI -Context $context 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $printed | Should -BeLike '*runs on another computer*'
        Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'keeps stamp entries written by other steps, the file tools included while Files.Root is empty' {
        Write-LocalAIState -Path (Join-Path $root 'install-stamp.json') -State @{ Files = @{ McpoVersion = '0.0.20' } }
        $null = Install-LocalAI -Context $context 6>$null
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).Files.McpoVersion | Should -Be '0.0.20'
        Should -Invoke Install-FilesServer -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'sets up the file tools for Files.Root after Open WebUI and before ComfyUI, and stamps them' {
        $context.Settings.Files.Root = 'D:\AI-Folder'
        $order = New-Object System.Collections.Generic.List[string]
        Mock Install-OpenWebUI -ModuleName LocalAI -MockWith { $order.Add('OpenWebUI'); @{ Version = '0.12.4'; Path = 'C:\x\open-webui.exe'; Python = '3.12.10' } }
        Mock Install-FilesServer -ModuleName LocalAI -MockWith { $order.Add('Files'); $filesEntry }
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith { $order.Add('ComfyUI'); @{ Commit = $comfyCommit; Pinned = $true; Python = $comfyPython } }
        $printed = @(Install-LocalAI -Context $context 6>&1)
        @($printed | Where-Object { $_ -is [int] }) | Should -Be @(0)
        ($printed -join "`n") | Should -BeLike '*Open WebUI 0.12.4 is installed, as are the file tools for D:\AI-Folder, as are ComfyUI*'
        $order | Should -Be @('OpenWebUI', 'Files', 'ComfyUI')
        Should -Invoke Install-FilesServer -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Settings.Files.Root -eq 'D:\AI-Folder' -and $Paths.Root -eq $root -and $RepoRoot -eq $repoRoot -and $null -eq $Recorded -and $Stamp.OpenWebUI.Version -eq '0.12.4'
        }
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.Files.McpoPath | Should -Be 'C:\Users\User\.local\bin\mcpo.exe'
        $stamp.Files.With | Should -Be @('mcp==1.30.0', 'fastapi<0.145')
        $stamp.Files.Node.Version | Should -Be '24.22.1'
        Should -Invoke Test-FilesRoot -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Settings.Files.Root -eq 'D:\AI-Folder' -and $Paths.Root -eq $root -and $RepoRoot -eq $repoRoot -and $ToolDir -eq 'C:\Users\User\AppData\Roaming\uv\tools'
        }
    }

    It 'keeps the note that it installed Node.js in the stamp when a later file-tool step fails' {
        $context.Settings.Files.Root = 'D:\AI-Folder'
        # The real step, with winget installing Node.js and mcpo failing after it. Get-Command is mocked here.
        $realStep = (Get-Module LocalAI).ExportedFunctions['Install-FilesServer']
        Mock Install-FilesServer -ModuleName LocalAI -MockWith { & $realStep -Settings $Settings -Paths $Paths -RepoRoot $RepoRoot -Stamp $Stamp -Recorded $Recorded }
        Mock Install-WingetPackage -ModuleName LocalAI -ParameterFilter { $Package.Id -eq 'OpenJS.NodeJS.LTS' } -MockWith { 'installed' }
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'node' } -MockWith { [pscustomobject]@{ Path = 'C:\Program Files\nodejs\node.exe' } }
        Mock Install-Mcpo -ModuleName LocalAI -MockWith { throw "'uv tool install' failed with exit code 2." }
        $output = @(Install-LocalAI -Context $context 3>&1 6>$null)
        @($output | Where-Object { $_ -is [int] }) | Should -Be @(2)
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.Node.InstalledByLauncher | Should -BeTrue
        $stamp.ContainsKey('Files') | Should -BeFalse
        $stamp.OpenWebUI.Version | Should -Be '0.12.4'
    }

    It 'keeps the file tools installed and stamped but returns 2 without calling them ready when Test-FilesRoot refuses the folder' {
        $context.Settings.Files.Root = 'D:\AI-Folder'
        Mock Test-FilesRoot -ModuleName LocalAI -MockWith {
            Write-Warning "Files.Root 'D:\AI-Folder' is not served, so the file tools are off: it holds 1 file(s) or folder(s) whose names match Files.DenyPatterns: server.key."
            $false
        }
        $output = @(Install-LocalAI -Context $context 3>&1 6>&1)
        @($output | Where-Object { $_ -is [int] }) | Should -Be @(2)
        $warning = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        $warning.Count | Should -Be 1
        $warning[0] | Should -BeLike '*server.key*'
        ($output -join "`n") | Should -Not -BeLike '*as are the file tools*'
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).Files.McpoVersion | Should -Be '0.0.20'
    }

    It 'checks no folder while Files.Root is empty' {
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Test-FilesRoot -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'hands the file-tools entry an earlier install stamped to the step, so it can tell whether mcpo needs a reinstall' {
        $context.Settings.Files.Root = 'D:\AI-Folder'
        Write-LocalAIState -Path (Join-Path $root 'install-stamp.json') -State @{ Files = @{ McpoVersion = '0.0.19'; With = @('mcp<2') } }
        $null = Install-LocalAI -Context $context 6>$null
        Should -Invoke Install-FilesServer -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Recorded.McpoVersion -eq '0.0.19' }
        (Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')).Files.McpoVersion | Should -Be '0.0.20'
    }

    It 'warns once, returns 2, keeps chat and images and drops the old file-tools entry when the file tools fail' {
        $context.Settings.Files.Root = 'D:\AI-Folder'
        Write-LocalAIState -Path (Join-Path $root 'install-stamp.json') -State @{ Files = @{ McpoVersion = '0.0.19' } }
        Mock Install-FilesServer -ModuleName LocalAI -MockWith { throw 'Node.js 22.11.0 at C:\Program Files\nodejs\node.exe is older than the >=24 it needs.' }
        $output = @(Install-LocalAI -Context $context 3>&1 6>$null)
        @($output | Where-Object { $_ -is [int] }) | Should -Be @(2)
        $warning = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        $warning.Count | Should -Be 1
        $warning[0] | Should -BeLike "The file tools are not set up: Node.js 22.11.0*older than*Chat works without them*'local-ai install' again, or set Files.Root = ''*"
        $stamp = Read-LocalAIState -Path (Join-Path $root 'install-stamp.json')
        $stamp.ContainsKey('Files') | Should -BeFalse
        $stamp.OpenWebUI.Version | Should -Be '0.12.4'
        $stamp.Images.File | Should -Be 'DreamShaperXL_Lightning.safetensors'
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'returns 2 when <Step> warns, still writing the stamp' -ForEach @(
        @{ Step = 'the loopback check'; Command = 'Test-LoopbackListener'; Result = $false }
        @{ Step = 'winget'; Command = 'Install-WingetPackage'; Result = 'restart' }
        @{ Step = 'the chat model'; Command = 'Install-ChatModel'; Result = $null }
        @{ Step = 'Open WebUI'; Command = 'Install-OpenWebUI'; Result = @{ Version = '0.12.3'; Path = 'C:\Users\User\.local\bin\open-webui.exe'; Python = '3.11.17' } }
        @{ Step = 'ComfyUI'; Command = 'Install-ComfyUI'; Result = @{ Commit = 'abcdef0123456789abcdef0123456789abcdef01'; Pinned = $false; Python = 'C:\x\python.exe' } }
    ) {
        if ($Command -eq 'Install-ChatModel') {
            Mock Install-ChatModel -ModuleName LocalAI -MockWith {
                Write-Warning "Ollama does not report the 'tools' capability for local-chat."
                $State['Model'] = @{ Alias = 'local-chat'; BaseDigest = $pin; ModelfileSha256 = ('d' * 64) }
                $State
            }
        } else {
            Mock $Command -ModuleName LocalAI -MockWith { Write-Warning 'test warning'; $Result }
        }
        Install-LocalAI -Context $context 3>$null 6>$null | Should -Be 2
        Test-Path -LiteralPath (Join-Path $root 'install-stamp.json') | Should -BeTrue
    }

    It 'hands sleep back and writes no stamp when a step fails' {
        Mock Install-ChatModel -ModuleName LocalAI -MockWith { throw 'pull failed' }
        { Install-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage '*pull failed*'
        Should -Invoke Set-LocalAIKeepAwake -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { -not $Enabled }
        Test-Path -LiteralPath (Join-Path $root 'install-stamp.json') | Should -BeFalse
    }

    It 'records at once the Ollama app its first wait started, so stop quits it also when a later step fails' {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'install' }
        $waits = @{ Count = 0 }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith {
            $waits.Count++
            $started = if ($waits.Count -eq 1) { $app } else { $null }
            [pscustomobject]@{ Version = '0.40.11'; App = $started }
        }
        Mock Test-RecordedProcess -ModuleName LocalAI -MockWith { $true }
        Mock Install-ChatModel -ModuleName LocalAI -MockWith { throw 'pull failed' }
        { Install-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage '*pull failed*'
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $PassThru -and $How -eq 'install' }
        $ollama = (Read-LocalAIState -Path (Join-Path $root 'state.json')).Ollama
        $ollama.App.Pid | Should -Be 100
        $ollama.App.How | Should -Be 'install'
        $ollama.Url | Should -Be 'http://127.0.0.1:11434'
        $ollama.Alias | Should -Be 'local-chat'
    }

    Context 'when the Ollama installer starts the app' {
        BeforeEach {
            $appExe = 'C:\Users\User\AppData\Local\Programs\Ollama\ollama app.exe'
            # Apps holds what Win32_Process lists; the Ollama package's winget step leaves New running, as its installer does.
            $world = @{ Apps = New-Object System.Collections.Generic.List[object]; New = @(300) }
            Mock Get-OllamaAppProcess -ModuleName LocalAI -MockWith { $world.Apps.ToArray() }
            Mock Install-WingetPackage -ModuleName LocalAI -ParameterFilter { $Package.Id -eq 'Ollama.Ollama' } -MockWith {
                foreach ($id in $world.New) { $world.Apps.Add([pscustomobject]@{ Id = $id; Path = $appExe; StartTicks = [DateTime]::UtcNow.Ticks; ParentId = 9 }) }
                'installed'
            }
            Mock Resolve-OllamaAppPath -ModuleName LocalAI -MockWith { $appExe }
            Mock Get-PortOwner -ModuleName LocalAI -MockWith { [pscustomobject]@{ Id = 301; Name = 'ollama'; Path = 'C:\Ollama\ollama.exe'; StartTicks = 5 } }
            Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $ProcessId -eq 301 -and $AncestorId -eq 300 -and $MaxDepth -eq 1 }
        }

        It 'records the app the installer started when no app ran before' {
            $printed = @(Install-LocalAI -Context $context 6>&1 | ForEach-Object { "$_" }) -join "`n"
            $printed | Should -BeLike '*The Ollama installer started the Ollama app (PID 300); local-ai stop quits it again.*'
            $app = (Read-LocalAIState -Path (Join-Path $root 'state.json')).Ollama.App
            $app.Pid | Should -Be 300
            $app.Path | Should -Be $appExe
            $app.How | Should -Be 'install'
            $app.Listener.Pid | Should -Be 301
        }

        It 'records no app when one ran before the winget step, or when <Case>' -ForEach @(
            @{ Case = 'two apps began'; New = @(300, 302) }
            @{ Case = 'none began'; New = @() }
        ) {
            $world.New = $New
            $null = Install-LocalAI -Context $context 6>$null
            (Read-LocalAIState -Path (Join-Path $root 'state.json')).ContainsKey('Ollama') | Should -BeFalse
            $world.Apps.Clear()
            $world.Apps.Add([pscustomobject]@{ Id = 50; Path = $appExe; StartTicks = [DateTime]::UtcNow.AddMinutes(-5).Ticks; ParentId = 9 })
            $world.New = @(300)
            $null = Install-LocalAI -Context $context 6>$null
            (Read-LocalAIState -Path (Join-Path $root 'state.json')).ContainsKey('Ollama') | Should -BeFalse
        }
    }
}

Describe 'Install-OpenWebUI' {
    BeforeAll {
        # 'uv tool list --show-paths --show-python --color never' of uv 0.13.6, with the user folder
        # renamed and an mcpo entry added.
        $installed = @(
            'mcpo v0.0.20 [CPython 3.12.10] (C:\Users\User\AppData\Roaming\uv\tools\mcpo)'
            '- mcpo (C:\Users\User\.local\bin\mcpo.exe)'
            'open-webui v0.12.3 [CPython 3.11.17] (C:\Users\User\AppData\Roaming\uv\tools\open-webui)'
            '- open-webui (C:\Users\User\.local\bin\open-webui.exe)'
        )
        $pinned = @(
            'open-webui v0.12.4 [CPython 3.12.10] (C:\Users\User\AppData\Roaming\uv\tools\open-webui)'
            '- open-webui (C:\Users\User\.local\bin\open-webui.exe)'
        )
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dataDir = Join-Path $root 'open-webui'
        $paths = Get-LocalAIPaths -Root (Join-Path $root 'local-ai')
        $settings = @{ OpenWebUI = @{ Version = '0.12.4'; Python = '3.12'; ExcludeNewer = '2026-10-25T08:10:00Z'; DataDir = $dataDir; InstallBytes = 2987894996 } }
        $uv = @{ Lines = $installed; Backups = $null }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'list' } -MockWith {
            foreach ($line in $uv.Lines) { $Capture.Add($line) }
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'dir' } -MockWith {
            $Capture.Add('C:\Users\User\AppData\Roaming\uv\tools')
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'install' } -MockWith {
            $uv.Backups = @(Get-ChildItem -LiteralPath $paths.Backups -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            $uv.Lines = $pinned
            0
        }
        Mock Test-FreeSpace -ModuleName LocalAI
    }

    It 'installs the pin on OpenWebUI.Python, resolved as of OpenWebUI.ExcludeNewer, on the console, when uv lists no open-webui' {
        $uv.Lines = @('No tools installed')
        $tool = Install-OpenWebUI -Settings $settings -Paths $paths 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'uv' -and ($ArgumentList -join ' ') -eq 'tool install --python 3.12 open-webui==0.12.4 --exclude-newer 2026-10-25T08:10:00Z' -and [bool]$Console
        }
        $tool.ExcludeNewer | Should -BeExactly '2026-10-25T08:10:00Z'
        $tool.Version | Should -Be '0.12.4'
        $tool.Path | Should -Be 'C:\Users\User\.local\bin\open-webui.exe'
        $tool.Python | Should -Be '3.12.10'
        $tool.ToolDir | Should -Be 'C:\Users\User\AppData\Roaming\uv\tools'
    }

    It 'installs without a cut-off when OpenWebUI.ExcludeNewer is empty, and says so in what it returns' {
        $uv.Lines = @('No tools installed')
        $settings.OpenWebUI.ExcludeNewer = ''
        $tool = Install-OpenWebUI -Settings $settings -Paths $paths 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'tool install --python 3.12 open-webui==0.12.4' }
        $tool.ExcludeNewer | Should -BeExactly ''
    }

    It 'checks free space for InstallBytes on the uv tools folder before the install' {
        $uv.Lines = @('No tools installed')
        $null = Install-OpenWebUI -Settings $settings -Paths $paths 6>$null
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\Users\User\AppData\Roaming\uv\tools' -and $RequiredBytes -eq 2987894996
        }
    }

    It 'installs nothing when the free-space check fails' {
        $uv.Lines = @('No tools installed')
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith { throw 'Drive C: has 1.0 GB free' }
        { Install-OpenWebUI -Settings $settings -Paths $paths 6>$null } | Should -Throw -ExpectedMessage '*Drive C: has 1.0 GB free*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
    }

    It 'backs up an existing webui.db and its secret key before installing over it' {
        $uv.Lines = @('No tools installed')
        $leaf = Split-Path $root -Leaf
        $null = Write-TestFile "$leaf\open-webui\webui.db" 'database'
        $null = Write-TestFile "$leaf\open-webui\.webui_secret_key" 'key'
        $null = Write-TestFile "$leaf\open-webui\uploads\file.txt" 'upload'
        $printed = @(Install-OpenWebUI -Settings $settings -Paths $paths 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join "`n"
        @($uv.Backups | Sort-Object) | Should -Be @('.webui_secret_key', 'webui.db')
        $folder = @(Get-ChildItem -LiteralPath $paths.Backups -Directory)
        $folder.Count | Should -Be 1
        $folder[0].Name | Should -Match '^open-webui-\d{8}-\d{6}\z'
        Get-Content -LiteralPath (Join-Path $folder[0].FullName 'webui.db') | Should -Be 'database'
        $printed | Should -BeLike "*backed up to $($folder[0].FullName)*"
    }

    It 'makes no backup when the data folder holds no webui.db' {
        $uv.Lines = @('No tools installed')
        $null = Install-OpenWebUI -Settings $settings -Paths $paths 6>$null
        Test-Path -LiteralPath $paths.Backups | Should -BeFalse
    }

    It 'reads uv tool list with paths and Python versions, uncoloured' {
        $uv.Lines = $pinned
        $null = Install-OpenWebUI -Settings $settings -Paths $paths 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'uv' -and ($ArgumentList -join ' ') -eq 'tool list --show-paths --show-python --color never' -and $null -ne $Capture
        }
    }

    It 'leaves the pinned version as it is, checking no space and backing up nothing' {
        $uv.Lines = $pinned
        $null = Write-TestFile ((Split-Path $root -Leaf) + '\open-webui\webui.db') 'database'
        $tool = Install-OpenWebUI -Settings $settings -Paths $paths -WarningVariable warnings 3>$null 6>$null
        $tool.Version | Should -Be '0.12.4'
        # It installed nothing, so it cannot say as of when the installed packages were resolved.
        $tool.ContainsKey('ExcludeNewer') | Should -BeFalse
        $warnings.Count | Should -Be 0
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 0 -Exactly
        Test-Path -LiteralPath $paths.Backups | Should -BeFalse
    }

    It 'keeps another installed version, warns that update changes it, and returns what is installed' {
        $tool = Install-OpenWebUI -Settings $settings -Paths $paths -WarningVariable warnings 3>$null 6>$null
        $tool.Version | Should -Be '0.12.3'
        $tool.Python | Should -Be '3.11.17'
        $tool.Path | Should -Be 'C:\Users\User\.local\bin\open-webui.exe'
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*Open WebUI 0.12.3 is installed, but OpenWebUI.Version pins 0.12.4*'local-ai update'*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
    }

    It 'throws when uv still lists no open-webui after the install' {
        $uv.Lines = @()
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'install' } -MockWith { 0 }
        { Install-OpenWebUI -Settings $settings -Paths $paths 6>$null } | Should -Throw -ExpectedMessage "*'uv tool list' does not list open-webui*"
    }

    It 'throws when uv shows no open-webui entry point' {
        $uv.Lines = @('open-webui v0.12.4 [CPython 3.12.10] (C:\Users\User\AppData\Roaming\uv\tools\open-webui)')
        { Install-OpenWebUI -Settings $settings -Paths $paths 6>$null } | Should -Throw -ExpectedMessage '*no open-webui entry point*'
    }
}

Describe 'Install-Mcpo' {
    BeforeAll {
        # 'uv tool list --show-paths --show-python --color never' of uv 0.13.6, with the user folder renamed.
        $pinned = @(
            'mcpo v0.0.20 [CPython 3.12.16] (C:\Users\User\AppData\Roaming\uv\tools\mcpo)'
            '- mcpo (C:\Users\User\.local\bin\mcpo.exe)'
            'open-webui v0.12.4 [CPython 3.12.10] (C:\Users\User\AppData\Roaming\uv\tools\open-webui)'
            '- open-webui (C:\Users\User\.local\bin\open-webui.exe)'
        )
        $command = 'tool install --python 3.12 --managed-python mcpo==0.0.20 --with mcp==1.30.0 --with fastapi<0.145 --exclude-newer 2026-10-13T00:00:00Z'
    }

    BeforeEach {
        $settings = @{ Files = @{ McpoVersion = '0.0.20'; Python = '3.12'; McpoWith = @('mcp==1.30.0', 'fastapi<0.145'); McpoExcludeNewer = '2026-10-13T00:00:00Z'
                InstallBytes = 119062513 } }
        $recorded = @{ McpoVersion = '0.0.20'; Python = '3.12'; With = @('mcp==1.30.0', 'fastapi<0.145'); ExcludeNewer = '2026-10-13T00:00:00Z' }
        $uv = @{ Lines = $pinned }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'list' } -MockWith {
            foreach ($line in $uv.Lines) { $Capture.Add($line) }
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'dir' } -MockWith {
            $Capture.Add('C:\Users\User\AppData\Roaming\uv\tools')
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'install' } -MockWith {
            $uv.Lines = $pinned
            0
        }
        Mock Test-FreeSpace -ModuleName LocalAI
        $running = @{ Processes = @([pscustomobject]@{ Id = 1; Path = 'C:\Windows\System32\svchost.exe' }, [pscustomobject]@{ Id = 2; Path = $null }) }
        Mock Get-Process -ModuleName LocalAI -MockWith { $running.Processes }
    }

    It 'installs the pins on a uv-managed Python, on the console, after a free-space check, when uv lists no mcpo' {
        $uv.Lines = @('No tools installed')
        $tool = Install-Mcpo -Settings $settings -Recorded $null 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'uv' -and ($ArgumentList -join ' ') -ceq $command -and [bool]$Console
        }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\Users\User\AppData\Roaming\uv\tools' -and $RequiredBytes -eq 119062513
        }
        $tool.Version | Should -Be '0.0.20'
        $tool.Path | Should -Be 'C:\Users\User\.local\bin\mcpo.exe'
        $tool.Python | Should -Be '3.12.16'
        $tool.ToolDir | Should -Be 'C:\Users\User\AppData\Roaming\uv\tools'
    }

    It 'changes nothing when uv lists the pin on the pinned Python and the stamp records the same pins' {
        $tool = Install-Mcpo -Settings $settings -Recorded $recorded 6>$null
        $tool.Path | Should -Be 'C:\Users\User\.local\bin\mcpo.exe'
        # The folder start keeps out of Files.Root, also when nothing is installed.
        $tool.ToolDir | Should -Be 'C:\Users\User\AppData\Roaming\uv\tools'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'reinstalls with the same pins and --reinstall when <Case>, since uv would keep the old packages' -ForEach @(
        @{ Case = 'uv lists another mcpo'; Lines = @('mcpo v0.0.19 [CPython 3.12.16] (C:\x\mcpo)', '- mcpo (C:\x\mcpo.exe)'); Change = @{} }
        @{ Case = 'mcpo runs on another Python'; Lines = @('mcpo v0.0.20 [CPython 3.11.17] (C:\x\mcpo)', '- mcpo (C:\x\mcpo.exe)'); Change = @{} }
        @{ Case = 'the stamp records other --with pins'; Lines = $null; Change = @{ With = @('mcp<2') } }
        @{ Case = 'the stamp records another cut-off'; Lines = $null; Change = @{ ExcludeNewer = '' } }
        @{ Case = 'the stamp records another Python'; Lines = $null; Change = @{ Python = '3.11' } }
        @{ Case = 'the stamp records no file tools'; Lines = $null; Change = $null }
    ) {
        if ($Lines) { $uv.Lines = $Lines }
        $given = $null
        if ($null -ne $Change) {
            $given = $recorded.Clone()
            foreach ($key in $Change.Keys) { $given[$key] = $Change[$key] }
        }
        $tool = Install-Mcpo -Settings $settings -Recorded $given 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[1] -eq 'install' -and ($ArgumentList -join ' ') -ceq "$command --reinstall" -and [bool]$Console
        }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 0 -Exactly
        $tool.Version | Should -Be '0.0.20'
    }

    It 'refuses to <Case> while <Program> runs, naming the PID, and runs no uv install' -ForEach @(
        @{ Case = 'reinstall'; Program = 'the mcpo.exe entry point'; Lines = @('mcpo v0.0.19 [CPython 3.12.16] (C:\x\mcpo)', '- mcpo (C:\Users\User\.local\bin\mcpo.exe)')
            Path = 'C:\Users\User\.local\bin\mcpo.exe' }
        @{ Case = 'reinstall'; Program = "the tool environment's python.exe"; Lines = @('mcpo v0.0.19 [CPython 3.12.16] (C:\x\mcpo)', '- mcpo (C:\x\mcpo.exe)')
            Path = 'C:\Users\User\AppData\Roaming\uv\tools\mcpo\Scripts\python.exe' }
        @{ Case = 'install'; Program = 'a python.exe left in the tool folder'; Lines = @('No tools installed'); Path = 'C:\Users\User\AppData\Roaming\uv\tools\MCPO\Scripts\python.exe' }
    ) {
        $uv.Lines = $Lines
        $running.Processes += [pscustomobject]@{ Id = 7950; Path = $Path }
        { Install-Mcpo -Settings $settings -Recorded $recorded 6>$null } |
            Should -Throw -ExpectedMessage "mcpo runs from C:\Users\User\AppData\Roaming\uv\tools\mcpo (PID 7950), so uv cannot replace its files. Run 'local-ai stop', then run install again."
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
    }

    It 'looks for no running mcpo when nothing needs installing' {
        $null = Install-Mcpo -Settings $settings -Recorded $recorded 6>$null
        Should -Invoke Get-Process -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'reinstalls when only another tool runs from the uv tool folder' {
        $uv.Lines = @('mcpo v0.0.19 [CPython 3.12.16] (C:\x\mcpo)', '- mcpo (C:\x\mcpo.exe)')
        $running.Processes += [pscustomobject]@{ Id = 7951; Path = 'C:\Users\User\AppData\Roaming\uv\tools\mcpo-other\Scripts\python.exe' }
        $null = Install-Mcpo -Settings $settings -Recorded $recorded 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
    }

    It 'reads a uv tool list line that also shows the version specifiers and the with list' {
        $uv.Lines = @(
            'mcpo v0.0.20 [required: ==0.0.20] [with: mcp==1.30.0, fastapi<0.145] [CPython 3.12.16] (C:\Users\User\AppData\Roaming\uv\tools\mcpo)'
            '- mcpo (C:\Users\User\.local\bin\mcpo.exe)'
        )
        $tool = Install-Mcpo -Settings $settings -Recorded $recorded 6>$null
        $tool.Version | Should -Be '0.0.20'
        $tool.Python | Should -Be '3.12.16'
        $tool.Path | Should -Be 'C:\Users\User\.local\bin\mcpo.exe'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
    }

    It 'leaves out --exclude-newer when McpoExcludeNewer is empty' {
        $uv.Lines = @('No tools installed')
        $settings.Files.McpoExcludeNewer = ''
        $null = Install-Mcpo -Settings $settings 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'tool install --python 3.12 --managed-python mcpo==0.0.20 --with mcp==1.30.0 --with fastapi<0.145'
        }
    }

    It 'installs nothing when the free-space check fails' {
        $uv.Lines = @('No tools installed')
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith { throw 'Drive C: has 0.1 GB free' }
        { Install-Mcpo -Settings $settings 6>$null } | Should -Throw -ExpectedMessage '*Drive C: has 0.1 GB free*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'install' }
    }

    It 'throws when uv still lists no mcpo after the install, or shows no entry point' {
        $uv.Lines = @()
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'install' } -MockWith { 0 }
        { Install-Mcpo -Settings $settings 6>$null } | Should -Throw -ExpectedMessage "*'uv tool install mcpo==0.0.20' succeeded, but 'uv tool list' does not list mcpo*"
        $uv.Lines = @('mcpo v0.0.20 [CPython 3.12.16] (C:\x\mcpo)')
        { Install-Mcpo -Settings $settings -Recorded $recorded 6>$null } | Should -Throw -ExpectedMessage '*no mcpo entry point*'
    }
}

Describe 'Install-FilesServerPackage' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $trackedLock = Join-Path $repoRoot 'config\files-server\package-lock.json'
        $lockSha = (Get-FileHash -LiteralPath $trackedLock -Algorithm SHA256).Hash.ToLowerInvariant()
        # The version the tracked package.json pins, which Files.ServerVersion in config\defaults.psd1 equals; the messages below name it as PINNED.
        $pinned = (Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')).Files.ServerVersion
    }

    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $base -Leaf
        $paths = Get-LocalAIPaths -Root (Join-Path $base 'local-ai')
        $settings = @{
            Files  = @{ ServerVersion = $pinned; ServerPackage = 'config\files-server'; ServerInstallBytes = 21617057 }
            Winget = @{ Packages = @{ Node = @{ Id = 'OpenJS.NodeJS.LTS'; Command = 'node'; Scope = 'machine' } } }
        }
        $node = Write-TestFile "$leaf\nodejs\node.exe" 'program'
        $npm = Write-TestFile "$leaf\nodejs\node_modules\npm\bin\npm-cli.js" 'npm'
        $target = $paths.FilesServer
        $module = Join-Path $target 'node_modules\@modelcontextprotocol\server-filesystem'
        $runs = @{ NodeVersion = 'v24.22.1'; Installs = $pinned; Copied = @() }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[0] -eq '--version' } -MockWith {
            $Capture.Add($runs.NodeVersion)
            0
        }
        # What npm ci leaves: the package with its version and its built entry point.
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $ArgumentList[1] -eq 'ci' } -MockWith {
            $runs.Copied = @(Get-ChildItem -LiteralPath $target -File | ForEach-Object { $_.Name } | Sort-Object)
            $runs.MarkerDuringCi = Test-Path -LiteralPath (Join-Path $target 'local-ai-install.json')
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $module 'dist')
            [IO.File]::WriteAllText((Join-Path $module 'package.json'), "{`"name`": `"@modelcontextprotocol/server-filesystem`", `"version`": `"$($runs.Installs)`"}")
            [IO.File]::WriteAllText((Join-Path $module 'dist\index.js'), '#!/usr/bin/env node')
            0
        }
        Mock Test-FreeSpace -ModuleName LocalAI
    }

    It 'runs npm ci through node on the npm-cli.js beside it, for the files-server folder, after copying both tracked files' {
        $result = Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $node -and ($ArgumentList -join ' ') -eq "$npm ci --omit=dev --ignore-scripts --no-audit --no-fund --no-update-notifier --prefix $target" -and [bool]$Console
        }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq $target -and $RequiredBytes -eq 21617057 }
        $runs.Copied.Count | Should -Be 2
        $runs.Copied | Should -Contain 'package.json'
        $runs.Copied | Should -Contain 'package-lock.json'
        $runs.MarkerDuringCi | Should -BeFalse
        (Get-FileHash -LiteralPath (Join-Path $target 'package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $lockSha
        $result.Script | Should -Be (Join-Path $module 'dist\index.js')
        $result.LockSha256 | Should -Be $lockSha
        $result.Node | Should -Be '24.22.1'
        $marker = Read-LocalAIState -Path (Join-Path $target 'local-ai-install.json')
        $marker.LockSha256 | Should -Be $lockSha
        $marker.ServerVersion | Should -Be $pinned
        $marker.PackageSha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'runs no npm ci when the marker records both files and the pinned server is in place' {
        $null = Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null
        $printed = @(Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>&1 |
                Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join "`n"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'ci' }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly
        $printed | Should -BeLike "*The files server $pinned in*matches the lockfile; nothing to install.*"
    }

    It 'runs npm ci again when <Case>' -ForEach @(
        @{ Case = 'the marker records another lockfile'; Change = 'lock' }
        @{ Case = 'the marker is not JSON'; Change = 'broken' }
        @{ Case = 'the installed server has another version'; Change = 'version' }
        @{ Case = 'the entry point is gone'; Change = 'script' }
    ) {
        $null = Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null
        $marker = Join-Path $target 'local-ai-install.json'
        switch ($Change) {
            'lock' { $state = Read-LocalAIState -Path $marker; $state.LockSha256 = 'f' * 64; Write-LocalAIState -Path $marker -State $state }
            'broken' { [IO.File]::WriteAllText($marker, '{ not json') }
            'version' { [IO.File]::WriteAllText((Join-Path $module 'package.json'), '{"version": "2.0.0"}') }
            'script' { Remove-Item -LiteralPath (Join-Path $module 'dist\index.js') }
        }
        $null = Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'ci' }
    }

    It 'throws before npm when <Case>' -ForEach @(
        @{ Case = 'Files.ServerVersion differs from the package.json pin'; Change = 'setting'; Message = "*package.json pins @modelcontextprotocol/server-filesystem 'PINNED', but Files.ServerVersion is '2.0.0'. Make them agree*" }
        @{ Case = 'node is older than the server needs'; Change = 'old node'; Message = '*Node.js 22.11.0 at *node.exe is older than the >=24 that @modelcontextprotocol/server-filesystem PINNED needs*winget upgrade --id OpenJS.NodeJS.LTS -e*' }
        @{ Case = 'node prints no version'; Change = 'no version'; Message = "*--version' printed no version*" }
        @{ Case = 'there is no npm beside node'; Change = 'no npm'; Message = '*There is no npm beside*npm-cli.js is missing*' }
        @{ Case = 'the lockfile locks another version'; Change = 'lock'; Message = '*package-lock.json does not lock @modelcontextprotocol/server-filesystem PINNED. Regenerate it*' }
    ) {
        switch ($Change) {
            'setting' { $settings.Files.ServerVersion = '2.0.0' }
            'old node' { $runs.NodeVersion = 'v22.11.0' }
            'no version' { $runs.NodeVersion = 'Welcome to Node.js' }
            'no npm' { Remove-Item -LiteralPath $npm }
            'lock' {
                $settings.Files.ServerPackage = Join-Path $base 'package'
                $null = Write-TestFile "$leaf\package\package.json" "{`"private`": true, `"dependencies`": {`"@modelcontextprotocol/server-filesystem`": `"$pinned`"}}"
                $null = Write-TestFile "$leaf\package\package-lock.json" '{"lockfileVersion": 3, "packages": {"node_modules/@modelcontextprotocol/server-filesystem": {"version": "2.0.0"}}}'
            }
        }
        { Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null } | Should -Throw -ExpectedMessage $Message.Replace('PINNED', $pinned)
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'ci' }
    }

    It 'accepts node <Version>, at or above the >=24 the lockfile names for the server' -ForEach @(
        @{ Version = 'v24.0.0' }
        @{ Version = 'v25.1.0' }
    ) {
        $runs.NodeVersion = $Version
        (Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null).Node | Should -Be $Version.TrimStart('v')
    }

    It 'throws, writing no marker, when npm ci leaves another server version' {
        $runs.Installs = '2.0.0'
        { Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null } |
            Should -Throw -ExpectedMessage "*After npm ci, *server-filesystem holds @modelcontextprotocol/server-filesystem '2.0.0' instead of $pinned*"
        Test-Path -LiteralPath (Join-Path $target 'local-ai-install.json') | Should -BeFalse
    }
}

Describe 'Get-FilesKey' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = Join-Path $folder 'files.key'
    }

    It 'creates a key of 64 lowercase hex characters once and returns the same key afterwards' {
        $key = Get-FilesKey -Path $path -Create
        $key | Should -MatchExactly '^[0-9a-f]{64}$'
        Get-FilesKey -Path $path -Create | Should -BeExactly $key
        Get-FilesKey -Path $path | Should -BeExactly $key
        [IO.File]::ReadAllText($path) | Should -BeExactly $key
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
    }

    It 'gives only the current user access, with no inherited entries' {
        $null = Get-FilesKey -Path $path -Create
        $acl = Get-Acl -LiteralPath $path
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AreAccessRulesProtected | Should -BeTrue
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $rules.Count | Should -Be 1
        $rules[0].IdentityReference | Should -Be $user
        $rules[0].AccessControlType | Should -Be 'Allow'
        $rules[0].FileSystemRights | Should -Be 'FullControl'
        $rules[0].IsInherited | Should -BeFalse
        $acl.GetOwner([Security.Principal.SecurityIdentifier]) | Should -Be $user
    }

    It 'makes a different key for each new file' {
        $first = Get-FilesKey -Path $path -Create
        $second = Get-FilesKey -Path (Join-Path $folder 'other.key') -Create
        $second | Should -Not -Be $first
    }

    It 'prints nothing, so the key reaches no transcript' {
        $output = @(Get-FilesKey -Path $path -Create 3>&1 6>&1)
        $output.Count | Should -Be 1
        $output[0] | Should -BeOfType [string]
    }

    It 'replaces a .tmp an interrupted run left behind' {
        $null = Write-TestFile ((Split-Path $folder -Leaf) + '\files.key.tmp') 'partial'
        Get-FilesKey -Path $path -Create | Should -MatchExactly '^[0-9a-f]{64}$'
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
    }

    It 'throws naming the file and install when it is missing and -Create is not given' {
        { Get-FilesKey -Path $path } | Should -Throw -ExpectedMessage "*mcpo key file '*files.key' does not exist. Run 'local-ai install'*"
    }

    It 'throws, without the content, when the file holds <Case>' -ForEach @(
        @{ Case = 'too few characters'; Text = 'abc123' }
        @{ Case = 'capitals'; Text = ('AB' * 32) }
    ) {
        $null = Write-TestFile ((Split-Path $folder -Leaf) + '\files.key') $Text
        $thrown = { Get-FilesKey -Path $path -Create } | Should -Throw -ExpectedMessage '*does not hold 64 lowercase hexadecimal characters. Delete it*' -PassThru
        $thrown.Exception.Message | Should -Not -BeLike "*$Text*"
    }
}

Describe 'Install-FilesServer' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Files.Root = 'D:\AI-Folder'
        $order = New-Object System.Collections.Generic.List[string]
        $stamp = @{ OpenWebUI = @{ Version = '0.12.4' } }
        Mock Install-WingetPackage -ModuleName LocalAI -MockWith { $order.Add('winget'); 'present' }
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'node' } -MockWith { [pscustomobject]@{ Path = 'C:\Program Files\nodejs\node.exe' } }
        Mock Install-Mcpo -ModuleName LocalAI -MockWith {
            $order.Add('mcpo')
            @{ Version = '0.0.20'; Path = 'C:\Users\User\.local\bin\mcpo.exe'; Python = '3.12.16'; ToolDir = 'C:\Users\User\AppData\Roaming\uv\tools' }
        }
        Mock Install-FilesServerPackage -ModuleName LocalAI -MockWith { $order.Add('server'); @{ Script = 'C:\x\dist\index.js'; LockSha256 = ('5' * 64); Node = '24.22.1' } }
        Mock Get-FilesKey -ModuleName LocalAI -MockWith { $order.Add('key'); 'ab' * 32 }
    }

    It 'installs Node.js with the machine-scope winget entry, then mcpo, the server and the key, and returns the stamp entry' {
        $recorded = @{ McpoVersion = '0.0.19' }
        $entry = Install-FilesServer -Settings $settings -Paths $paths -RepoRoot $repoRoot -Stamp $stamp -Recorded $recorded
        $order | Should -Be @('winget', 'mcpo', 'server', 'key')
        Should -Invoke Install-WingetPackage -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Package.Id -eq 'OpenJS.NodeJS.LTS' -and $Package.Scope -eq 'machine' -and $LogDir -eq $paths.Logs
        }
        Should -Invoke Install-Mcpo -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Recorded.McpoVersion -eq '0.0.19' }
        Should -Invoke Install-FilesServerPackage -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $NodePath -eq 'C:\Program Files\nodejs\node.exe' -and $RepoRoot -eq $repoRoot -and $Paths.FilesServer -eq (Join-Path $root 'files-server')
        }
        Should -Invoke Get-FilesKey -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $root 'files.key') -and $Create }
        $entry.McpoVersion | Should -Be '0.0.20'
        $entry.McpoPath | Should -Be 'C:\Users\User\.local\bin\mcpo.exe'
        $entry.McpoPython | Should -Be '3.12.16'
        $entry.Python | Should -Be '3.12'
        $entry.With | Should -Be @('mcp==1.30.0', 'fastapi<0.145')
        $entry.Mcp | Should -Be 'mcp==1.30.0'
        $entry.ExcludeNewer | Should -Be '2026-10-13T00:00:00Z'
        $entry.ServerVersion | Should -Be $settings.Files.ServerVersion
        $entry.Root | Should -Be 'D:\AI-Folder'
        $entry.Script | Should -Be 'C:\x\dist\index.js'
        $entry.LockSha256 | Should -Be ('5' * 64)
        $entry.Node.Path | Should -Be 'C:\Program Files\nodejs\node.exe'
        $entry.Node.Version | Should -Be '24.22.1'
        $entry.ToolDir | Should -Be 'C:\Users\User\AppData\Roaming\uv\tools'
        $entry.ContainsKey('Key') | Should -BeFalse
        $stamp.Node.InstalledByLauncher | Should -BeFalse
    }

    It 'notes in the stamp whether the launcher put Node.js in, keeping that across later installs, when winget <Case>' -ForEach @(
        @{ Case = 'installs it now'; Result = 'installed'; Noted = $null; Expected = $true }
        @{ Case = 'installs it and asks for a restart'; Result = 'restart'; Noted = $null; Expected = $true }
        @{ Case = 'finds it, which an earlier install put in'; Result = 'present'; Noted = $true; Expected = $true }
        @{ Case = 'finds it, which was there before'; Result = 'present'; Noted = $false; Expected = $false }
    ) {
        Mock Install-WingetPackage -ModuleName LocalAI -MockWith { $Result }
        if ($null -ne $Noted) { $stamp.Node = @{ InstalledByLauncher = $Noted } }
        $null = Install-FilesServer -Settings $settings -Paths $paths -RepoRoot $repoRoot -Stamp $stamp
        $stamp.Node.InstalledByLauncher | Should -Be $Expected
        (Read-LocalAIState -Path $paths.InstallStamp).Node.InstalledByLauncher | Should -Be $Expected
    }

    It 'has saved the note that it put Node.js in when mcpo then fails, keeping what the stamp held' {
        Mock Install-WingetPackage -ModuleName LocalAI -MockWith { 'installed' }
        Mock Install-Mcpo -ModuleName LocalAI -MockWith { throw "'uv tool install' failed with exit code 2." }
        { Install-FilesServer -Settings $settings -Paths $paths -RepoRoot $repoRoot -Stamp $stamp } | Should -Throw -ExpectedMessage '*exit code 2*'
        $saved = Read-LocalAIState -Path $paths.InstallStamp
        $saved.Node.InstalledByLauncher | Should -BeTrue
        $saved.OpenWebUI.Version | Should -Be '0.12.4'
    }

    It 'throws naming the fix when node is still not on PATH after winget' {
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq 'node' }
        { Install-FilesServer -Settings $settings -Paths $paths -RepoRoot $repoRoot -Stamp $stamp } | Should -Throw -ExpectedMessage '*node is not on PATH after the Node.js install. Open a new window*'
        Should -Invoke Install-Mcpo -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'stops at the step that fails' {
        Mock Install-Mcpo -ModuleName LocalAI -MockWith { throw "'uv tool install' failed with exit code 2." }
        { Install-FilesServer -Settings $settings -Paths $paths -RepoRoot $repoRoot -Stamp $stamp } | Should -Throw -ExpectedMessage '*exit code 2*'
        Should -Invoke Install-FilesServerPackage -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Get-FilesKey -ModuleName LocalAI -Times 0 -Exactly
    }
}

Describe 'Get-ImageWorkflow' {
    BeforeAll {
        $workflowText = @'
{
  "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "old.safetensors"}},
  "2": {"class_type": "EmptyLatentImage", "inputs": {"width": 512, "height": 512, "batch_size": 1}},
  "3": {"class_type": "KSampler", "inputs": {"seed": 0, "steps": 20, "cfg": 2, "model": ["1", 0], "latent_image": ["2", 0]}},
  "4": {"class_type": "PreviewImage", "inputs": {"images": ["3", 0]}}
}
'@
        $nodesText = @'
[
  {"type": "model", "key": "ckpt_name", "node_ids": ["1"]},
  {"type": "width", "key": "width", "node_ids": ["2"]},
  {"type": "height", "key": "height", "node_ids": ["2"]},
  {"type": "steps", "key": "steps", "node_ids": ["3"]},
  {"type": "seed", "key": "seed", "node_ids": ["3"]}
]
'@
    }

    BeforeEach {
        $folder = [guid]::NewGuid().ToString('N')
        $settings = @{ Images = @{
                File = 'DreamShaperXL_Lightning.safetensors'; Steps = 6; Resolution = '1024x768'
                Workflow = Write-TestFile "$folder\workflow.json" $workflowText
                WorkflowNodes = Write-TestFile "$folder\nodes.json" $nodesText
            }
        }
    }

    It 'writes Images.File, Images.Steps and Images.Resolution into the mapped inputs' {
        $workflow = (Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive).Workflow | ConvertFrom-Json
        $workflow.'1'.inputs.ckpt_name | Should -BeExactly 'DreamShaperXL_Lightning.safetensors'
        $workflow.'3'.inputs.steps | Should -Be 6
        $workflow.'2'.inputs.width | Should -Be 1024
        $workflow.'2'.inputs.height | Should -Be 768
        $workflow.'2'.inputs.batch_size | Should -Be 1
        $workflow.'3'.inputs.seed | Should -Be 0
        $workflow.'3'.inputs.cfg | Should -Be 2
    }

    It 'returns both as compact JSON without a BOM, keeping node links and single node ids as arrays' {
        $result = Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive
        $result.Workflow | Should -Not -Match '[\r\n]'
        $result.Nodes | Should -Not -Match '[\r\n]'
        $result.Workflow[0] | Should -BeExactly '{'
        $result.Nodes[0] | Should -BeExactly '['
        # Contains, since '[' starts a character class in a wildcard.
        $result.Workflow.Contains('"model":["1",0]') | Should -BeTrue
        $result.Workflow.Contains('"images":["3",0]') | Should -BeTrue
        $result.Nodes.Contains('"node_ids":["1"]') | Should -BeTrue
        $nodes = ConvertFrom-Json -InputObject $result.Nodes
        $nodes.Count | Should -Be 5
        foreach ($entry in $nodes) {
            ($entry.node_ids -is [array]) | Should -BeTrue
            $entry.node_ids[0] | Should -BeOfType [string]
        }
    }

    It 'reads the same values back after a second round trip through the JSON' {
        $first = Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive
        $null = Write-TestFile "$folder\again.json" $first.Workflow
        $settings.Images.Workflow = Join-Path $TestDrive "$folder\again.json"
        $second = Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive
        $second.Workflow.Length | Should -Be $first.Workflow.Length
        $workflow = $second.Workflow | ConvertFrom-Json
        $workflow.'3'.inputs.model | Should -Be @('1', 0)
        $workflow.'4'.inputs.images | Should -Be @('3', 0)
        $workflow.'1'.inputs.ckpt_name | Should -BeExactly 'DreamShaperXL_Lightning.safetensors'
    }

    It 'resolves relative paths against the repository root it is given' {
        $settings.Images.Workflow = "$folder\workflow.json"
        $settings.Images.WorkflowNodes = "$folder\nodes.json"
        $workflow = (Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive).Workflow | ConvertFrom-Json
        $workflow.'1'.inputs.ckpt_name | Should -BeExactly 'DreamShaperXL_Lightning.safetensors'
    }

    It 'throws naming <Setting> and the file when it <Case>' -ForEach @(
        @{ Case = 'is not JSON'; Setting = 'Workflow'; Text = '{ "1": '; Message = "*Cannot read Images.Workflow '*workflow.json'*" }
        @{ Case = 'is missing'; Setting = 'WorkflowNodes'; Text = $null; Message = "*Cannot read Images.WorkflowNodes '*nodes.json'*" }
        @{ Case = 'holds a list of nodes'; Setting = 'Workflow'; Text = '[{"class_type": "KSampler", "inputs": {}}]'; Message = "*Images.Workflow '*workflow.json' must hold a JSON object of nodes*" }
        @{ Case = 'has a node without class_type'; Setting = 'Workflow'; Text = '{"1": {"inputs": {}}}'; Message = "*Node '1' in Images.Workflow '*workflow.json' needs a class_type*" }
        @{ Case = 'holds an object instead of a list'; Setting = 'WorkflowNodes'; Text = '{"type": "model", "key": "ckpt_name", "node_ids": ["1"]}'; Message = "*Images.WorkflowNodes '*nodes.json' must hold a JSON list*" }
        @{ Case = 'has an entry without a key'; Setting = 'WorkflowNodes'; Text = '[{"type": "model", "node_ids": ["1"]}]'; Message = '*needs a type, a key naming an input, and a list of node_ids*' }
        @{ Case = 'has an entry without a type'; Setting = 'WorkflowNodes'; Text = '[{"key": "ckpt_name", "node_ids": ["1"]}]'; Message = '*needs a type, a key*' }
        @{ Case = 'lists a node id as a number'; Setting = 'WorkflowNodes'; Text = '[{"type": "model", "key": "ckpt_name", "node_ids": [1]}]'; Message = '*lists node id 1 as a number*"1"*' }
        @{ Case = 'maps a node the workflow lacks'; Setting = 'WorkflowNodes'; Text = '[{"type": "prompt", "key": "text", "node_ids": ["6"]}]'; Message = "*maps node '6', which the workflow lacks*" }
        @{ Case = 'maps an input the node lacks'; Setting = 'WorkflowNodes'; Text = '[{"type": "n", "key": "batch_size", "node_ids": ["3"]}]'; Message = "*maps input 'batch_size' of node '3' (KSampler), which that node lacks*" }
        # ComfyUI and Open WebUI compare names with case.
        @{ Case = 'spells class_type with capitals'; Setting = 'Workflow'; Text = '{"3": {"Class_Type": "KSampler", "inputs": {"steps": 20}}}'; Message = "*Node '3' in Images.Workflow '*workflow.json' needs a class_type and an inputs object, spelled in lowercase*" }
        @{ Case = 'spells inputs with capitals'; Setting = 'Workflow'; Text = '{"3": {"class_type": "KSampler", "Inputs": {"steps": 20}}}'; Message = "*Node '3'*spelled in lowercase*" }
        @{ Case = 'maps an input whose case differs'; Setting = 'WorkflowNodes'; Text = '[{"type": "steps", "key": "Steps", "node_ids": ["3"]}]'; Message = "*maps input 'Steps' of node '3' (KSampler), which that node lacks*" }
        @{ Case = 'spells an entry key with capitals'; Setting = 'WorkflowNodes'; Text = '[{"type": "steps", "Key": "steps", "node_ids": ["3"]}]'; Message = '*needs a type, a key naming an input, and a list of node_ids, spelled in lowercase*' }
    ) {
        $path = $settings.Images[$Setting]
        if ($null -eq $Text) { Remove-Item -LiteralPath $path } else { [IO.File]::WriteAllText($path, $Text) }
        { Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive } | Should -Throw -ExpectedMessage $Message
    }

    It 'throws when a mapped node id differs from the workflow only in case' {
        $settings.Images.Workflow = Write-TestFile "$folder\letters.json" '{"ks": {"class_type": "KSampler", "inputs": {"steps": 20}}}'
        $settings.Images.WorkflowNodes = Write-TestFile "$folder\upper.json" '[{"type": "steps", "key": "steps", "node_ids": ["KS"]}]'
        { Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive } | Should -Throw -ExpectedMessage "*maps node 'KS', which the workflow lacks*"
    }

    It 'throws when the workflow would not fit in an environment variable' {
        [IO.File]::WriteAllText($settings.Images.Workflow, $workflowText.Replace('"old.safetensors"', '"' + ('x' * 33000) + '"'))
        $settings.Images.WorkflowNodes = Write-TestFile "$folder\none.json" '[{"type": "steps", "key": "steps", "node_ids": ["3"]}]'
        { Get-ImageWorkflow -Settings $settings -RepoRoot $TestDrive } | Should -Throw -ExpectedMessage "*Images.Workflow '*workflow.json' is * characters as compact JSON; an environment variable takes at most 32766*"
    }
}

Describe 'Get-ComfyUIVersion and Test-ComfyUICheckpoint' {
    BeforeAll {
        $base = 'http://127.0.0.1:18188'
        # The shape of GET /object_info/CheckpointLoaderSimple in ComfyUI v0.42.5, listing $Files.
        function ConvertTo-ObjectInfo([string[]]$Files) {
            $list = ConvertTo-Json -InputObject @($Files) -Compress
            $text = '{"CheckpointLoaderSimple": {"input": {"required": {"ckpt_name": [' + $list + ', {"tooltip": "The name of the checkpoint (model) to load."}]}}, ' +
                '"input_order": {"required": ["ckpt_name"]}, "output": ["MODEL", "CLIP", "VAE"], "name": "CheckpointLoaderSimple"}}'
            return ConvertFrom-Json -InputObject $text
        }
    }

    It 'returns system.comfyui_version from GET /system_stats' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            ConvertFrom-Json -InputObject '{"system": {"os": "win32", "comfyui_version": "0.42.5", "pytorch_version": "2.14.1+cu130"}, "devices": []}'
        }
        Get-ComfyUIVersion -Url $base | Should -BeExactly '0.42.5'
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Uri -eq "$base/system_stats" -and $TimeoutSec -eq 5 }
    }

    It 'rejects a responder that <Case>' -ForEach @(
        @{ Case = 'serves an HTML page'; Answer = '<html><body>Welcome</body></html>' }
        @{ Case = 'answers without system'; Answer = '{"status": true}' }
        @{ Case = 'reports a number'; Answer = '{"system": {"comfyui_version": 42}}' }
    ) {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { if ($Answer.StartsWith('{')) { ConvertFrom-Json -InputObject $Answer } else { $Answer } }
        { Get-ComfyUIVersion -Url $base } | Should -Throw -ExpectedMessage "*GET $base/system_stats did not answer with system.comfyui_version, so it is not ComfyUI*"
    }

    It 'finds the checkpoint when ComfyUI lists <Count> file(s)' -ForEach @(
        @{ Count = 1; Files = @('DreamShaperXL_Lightning.safetensors') }
        @{ Count = 3; Files = @('a.safetensors', 'sub\b.safetensors', 'DreamShaperXL_Lightning.safetensors') }
    ) {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { ConvertTo-ObjectInfo -Files $Files }
        Test-ComfyUICheckpoint -Url $base -File 'DreamShaperXL_Lightning.safetensors' -WarningVariable warnings 3>$null | Should -BeTrue
        $warnings.Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Uri -eq "$base/object_info/CheckpointLoaderSimple" }
    }

    It 'warns naming what ComfyUI lists and returns $false when <Case>' -ForEach @(
        @{ Case = 'the file is missing'; Files = @('other.safetensors'); Listed = "*lists the checkpoints 'other.safetensors', not DreamShaperXL_Lightning.safetensors*" }
        @{ Case = 'only the case differs'; Files = @('dreamshaperxl_lightning.safetensors'); Listed = "*'dreamshaperxl_lightning.safetensors', not DreamShaperXL_Lightning.safetensors*" }
        @{ Case = 'the folder is empty'; Files = @(); Listed = '*lists the checkpoints none, not DreamShaperXL_Lightning.safetensors*' }
    ) {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { ConvertTo-ObjectInfo -Files $Files }
        Test-ComfyUICheckpoint -Url $base -File 'DreamShaperXL_Lightning.safetensors' -WarningVariable warnings 3>$null | Should -BeFalse
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike $Listed
        "$($warnings[0])" | Should -BeLike "*'local-ai install'*"
    }

    It 'warns and returns $false when ComfyUI does not answer' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        Test-ComfyUICheckpoint -Url $base -File 'DreamShaperXL_Lightning.safetensors' -WarningVariable warnings 3>$null | Should -BeFalse
        "$($warnings[0])" | Should -BeLike "*Could not read the checkpoints ComfyUI lists at $base/object_info/CheckpointLoaderSimple: Unable to connect*"
    }

    It 'accepts a first device of type cuda in GET /system_stats' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            ConvertFrom-Json -InputObject '{"system": {"comfyui_version": "0.42.5"}, "devices": [{"name": "cuda:0 NVIDIA Test GPU : cudaMallocAsync", "type": "cuda", "index": 0}]}'
        }
        Test-ComfyUIDevice -Url $base -WarningVariable warnings 3>$null | Should -BeTrue
        $warnings.Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Uri -eq "$base/system_stats" }
    }

    It 'warns naming what ComfyUI renders on and returns $false when it <Case>' -ForEach @(
        @{ Case = 'reports the CPU'; Devices = '[{"name": "cpu", "type": "cpu", "index": null}]'; Expected = '*ComfyUI reports cpu (type cpu), not a CUDA GPU*nvidia-smi*' }
        @{ Case = 'reports no device'; Devices = '[]'; Expected = '*ComfyUI reports no device, not a CUDA GPU*' }
    ) {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { ConvertFrom-Json -InputObject ('{"system": {}, "devices": ' + $Devices + '}') }
        Test-ComfyUIDevice -Url $base -WarningVariable warnings 3>$null | Should -BeFalse
        "$($warnings[0])" | Should -BeLike $Expected
    }

    It 'warns and returns $false when /system_stats does not answer' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        Test-ComfyUIDevice -Url $base -WarningVariable warnings 3>$null | Should -BeFalse
        "$($warnings[0])" | Should -BeLike "*Could not read the device ComfyUI renders on at $base/system_stats: Unable to connect*"
    }
}

Describe 'Get-VenvBasePython' {
    BeforeEach {
        $venv = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $venv
        $read = { Invoke-ModuleFunction 'Get-VenvBasePython' @{ Venv = $venv } }
    }

    It 'reads home and version_info from a venv uv made on its own Python, through its link for the minor' {
        Write-TestPyVenvConfig -Venv $venv -BaseHome 'C:\Users\User\AppData\Roaming\uv\python\cpython-3.13-windows-x86_64-none' -Version '3.13'
        $base = & $read
        $base.Home | Should -BeExactly 'C:\Users\User\AppData\Roaming\uv\python\cpython-3.13-windows-x86_64-none'
        $base.Version | Should -BeExactly '3.13'
        $base.Minor | Should -BeExactly '3.13'
        $base.Store | Should -BeFalse
    }

    It 'flags a venv on the Microsoft Store Python by its <Case>' -ForEach @(
        @{ Case = 'app execution alias'; Folder = 'C:\Users\User\AppData\Local\Microsoft\WindowsApps\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0' }
        @{ Case = 'package folder'; Folder = 'C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.13_3.13.2032.0_x64__qbz5n2kfra8p0' }
        @{ Case = 'alias folder in lower case'; Folder = 'c:\users\user\appdata\local\microsoft\windowsapps' }
    ) {
        [IO.File]::WriteAllText((Join-Path $venv 'pyvenv.cfg'), "home = $Folder`r`nimplementation = CPython`r`nuv = 0.13.1`r`nversion_info = 3.13.14`r`ninclude-system-site-packages = false`r`n")
        $base = & $read
        $base.Store | Should -BeTrue
        $base.Home | Should -BeExactly $Folder
        $base.Version | Should -BeExactly '3.13.14'
        $base.Minor | Should -BeExactly '3.13'
    }

    It "reads the version Python's own venv module writes, and does not flag a folder whose name only starts with WindowsApps" {
        [IO.File]::WriteAllText((Join-Path $venv 'pyvenv.cfg'), ("home = C:\Tools\WindowsAppsPython\Python313`ninclude-system-site-packages = false`nversion = 3.13.9`n" +
            "executable = C:\Tools\WindowsAppsPython\Python313\python.exe`n"))
        $base = & $read
        $base.Home | Should -BeExactly 'C:\Tools\WindowsAppsPython\Python313'
        $base.Version | Should -BeExactly '3.13.9'
        $base.Store | Should -BeFalse
    }

    It 'returns nothing without a pyvenv.cfg, and no home or version for one that names none' {
        & $read | Should -BeNullOrEmpty
        [IO.File]::WriteAllText((Join-Path $venv 'pyvenv.cfg'), "include-system-site-packages = false`n")
        $base = & $read
        $base.Home | Should -BeExactly ''
        $base.Version | Should -BeNullOrEmpty
        $base.Minor | Should -BeNullOrEmpty
        $base.Store | Should -BeFalse
    }
}

Describe 'Install-ComfyUI' {
    BeforeAll {
        $pin = '483dae4326356b81de05d27aca3f433dd323cc25'
        $old = 'abcdef0123456789abcdef0123456789abcdef01'
        # What the torch check prints for a CUDA build on an NVIDIA GPU.
        $cuda = @{ python = '3.13.18'; torch = '2.14.1+cu130'; torchvision = '0.29.1+cu130'; cuda = '13.0'; available = $true; device = 'NVIDIA Test GPU' }

        # Lay out a .venv in $Dir as uv makes it, on Python $Version in the folder $BaseHome.
        function Write-TestVenv([string]$Dir, [string]$Version, [string]$BaseHome = 'C:\Python') {
            $scripts = Join-Path $Dir '.venv\Scripts'
            $null = New-Item -ItemType Directory -Force -Path $scripts
            [IO.File]::WriteAllText((Join-Path $scripts 'python.exe'), 'program')
            [IO.File]::WriteAllText((Join-Path $Dir '.venv\pyvenv.cfg'), "home = $BaseHome`nimplementation = CPython`nuv = 0.13.6`nversion_info = $Version`ninclude-system-site-packages = false`n")
        }

        # Lay out a ComfyUI checkout in $Dir (.git and requirements.txt), with a .venv on Python $Version in the folder $BaseHome when $Version is given.
        function Write-TestCheckout([string]$Dir, [string]$Version, [string]$BaseHome = 'C:\Python') {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $Dir '.git')
            [IO.File]::WriteAllText((Join-Path $Dir 'requirements.txt'), "comfyui-frontend-package==1.55.18`ntorch`ntorchvision`n")
            if ($Version) { Write-TestVenv -Dir $Dir -Version $Version -BaseHome $BaseHome }
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dir = Join-Path $root 'ComfyUI'
        $venv = Join-Path $dir '.venv'
        $python = Join-Path $venv 'Scripts\python.exe'
        $marker = Join-Path $venv 'local-ai-install.json'
        $constraints = Write-TestFile ((Split-Path $root -Leaf) + '\constraints.txt') "# Pins.`ntorch==2.14.1`ntorchvision==0.29.1`n"
        $clone = "$dir.local-ai-clone"
        $settings = @{ ComfyUI = @{
                Dir = $dir; Repo = 'https://github.com/Comfy-Org/ComfyUI.git'; Ref = 'v0.42.5'; Commit = $pin; Python = '3.13'
                TorchBackend = 'cu130'; ExcludeNewer = '2026-10-23T00:07:14Z'; Constraints = $constraints; InstallBytes = 4552284304
            }
        }
        $world = @{ Head = $pin; Build = $cuda.Clone() }
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { @('git', 'uv') -contains $Name } -MockWith { [pscustomobject]@{ Name = "$Name.exe" } }
        Mock Test-FreeSpace -ModuleName LocalAI
        # No process runs from the venv.
        Mock Get-Process -ModuleName LocalAI
        # git clone writes the checkout into the folder it is given, the last argument.
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' -and $ArgumentList -contains 'clone' } -MockWith { Write-TestCheckout -Dir $ArgumentList[-1]; 0 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' -and $ArgumentList -contains 'rev-parse' } -MockWith { $Capture.Add($world.Head); 0 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' } -MockWith { Write-TestVenv -Dir $dir -Version '3.13.18'; 0 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' } -MockWith { 0 }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq $python } -MockWith {
            $Capture.Add("UserWarning: a torch warning on stderr")
            $Capture.Add((ConvertTo-Json -InputObject $world.Build -Compress))
            0
        }
    }

    It 'clones Ref beside a missing Dir and moves it in, creates a uv-managed venv, installs under the constraints, checks CUDA and writes the marker' {
        $result = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq $dir -and $RequiredBytes -eq 4552284304 }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq "-c advice.detachedHead=false clone --depth 1 --branch v0.42.5 https://github.com/Comfy-Org/ComfyUI.git $clone" -and [bool]$Console
        }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'git' -and ($ArgumentList -join ' ') -eq "-C $clone rev-parse HEAD" -and $null -ne $Capture
        }
        Test-Path -LiteralPath (Join-Path $dir '.git') | Should -BeTrue
        Test-Path -LiteralPath $clone | Should -BeFalse
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'uv' -and ($ArgumentList -join ' ') -eq "venv --python 3.13 --managed-python $venv" -and [bool]$Console
        }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'uv' -and [bool]$Console -and ($ArgumentList -join ' ') -eq
            "pip install --python $python --torch-backend cu130 --exclude-newer 2026-10-23T00:07:14Z -c $constraints -r $dir\requirements.txt"
        }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $python -and $ArgumentList[0] -eq '-I' -and $ArgumentList[1] -eq '-c' -and $ArgumentList[2] -like '*torch.cuda.is_available()*' -and
            $ArgumentList[2] -notlike '*"*' -and $null -ne $Capture
        }
        $result.Dir | Should -Be $dir
        $result.Commit | Should -Be $pin
        $result.Pinned | Should -BeTrue
        $result.Python | Should -Be $python
        $result.PythonVersion | Should -Be '3.13.18'
        $result.Torch | Should -Be '2.14.1+cu130'
        $result.TorchVision | Should -Be '0.29.1+cu130'
        $result.Cuda | Should -Be '13.0'
        $written = Read-LocalAIState -Path $marker
        $written.Commit | Should -Be $pin
        $written.Python | Should -Be '3.13.18'
        $written.Torch | Should -Be '2.14.1+cu130'
        $written.TorchVision | Should -Be '0.29.1+cu130'
        $written.Cuda | Should -Be '13.0'
        $written.Backend | Should -Be 'cu130'
        $written.ExcludeNewer | Should -Be '2026-10-23T00:07:14Z'
        $written.RequirementsSha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $dir 'requirements.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
        $written.ConstraintsSha256 | Should -Be (Get-FileHash -LiteralPath $constraints -Algorithm SHA256).Hash.ToLowerInvariant()
        @(Get-ChildItem -LiteralPath $venv -Filter '*.tmp').Count | Should -Be 0
    }

    It 'marks a checkout it cloned in .git, reporting Cloned on this and later runs, and records in the marker that it created the venv' {
        (Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null).Cloned | Should -BeTrue
        $mark = Read-LocalAIState -Path (Join-Path $dir '.git\local-ai-clone.json')
        $mark.Kind | Should -Be 'local-ai-clone'
        $mark.Repo | Should -Be 'https://github.com/Comfy-Org/ComfyUI.git'
        $mark.Ref | Should -Be 'v0.42.5'
        $mark.Commit | Should -Be $pin
        (Read-LocalAIState -Path $marker).CreatedVenv | Should -BeTrue
        # A later run that installs again keeps both facts.
        [IO.File]::AppendAllText((Join-Path $dir 'requirements.txt'), "blake3`n")
        (Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null).Cloned | Should -BeTrue
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' }
        (Read-LocalAIState -Path $marker).CreatedVenv | Should -BeTrue
    }

    It 'reports an adopted checkout as not cloned and records that it did not create the venv it found' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        (Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null).Cloned | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir '.git\local-ai-clone.json') | Should -BeFalse
        (Read-LocalAIState -Path $marker).CreatedVenv | Should -BeFalse
    }

    It 'records that it created a venv it made in an adopted checkout, even when the first install into it failed' {
        Write-TestCheckout -Dir $dir
        $world.Build.available = $false
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage '*finds no CUDA device*'
        $world.Build.available = $true
        $result = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        $result.Cloned | Should -BeFalse
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' }
        (Read-LocalAIState -Path $marker).CreatedVenv | Should -BeTrue
    }

    It 'clones into an existing empty Dir' {
        $null = New-Item -ItemType Directory -Force -Path $dir
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'clone' }
        Test-Path -LiteralPath (Join-Path $dir 'requirements.txt') | Should -BeTrue
        Test-Path -LiteralPath $clone | Should -BeFalse
    }

    It 'clones beside Dir also when ComfyUI.Dir ends in a backslash' {
        $settings.ComfyUI.Dir = "$dir\"
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'clone' -and $ArgumentList[-1] -eq $clone }
        Test-Path -LiteralPath (Join-Path $dir '.git') | Should -BeTrue
    }

    It 'removes a clone folder an interrupted run left before it clones again' {
        $null = Write-TestFile ((Split-Path $root -Leaf) + '\ComfyUI.local-ai-clone\.git\half') 'partial'
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' -and $ArgumentList -contains 'clone' } -MockWith {
            if (Test-Path -LiteralPath $ArgumentList[-1]) { throw "fatal: destination path '$($ArgumentList[-1])' already exists and is not an empty directory." }
            Write-TestCheckout -Dir $ArgumentList[-1]
            0
        }
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Test-Path -LiteralPath (Join-Path $dir '.git\half') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'requirements.txt') | Should -BeTrue
    }

    It 'clones nothing when the free-space check fails' {
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith { throw 'Drive C: has 1.0 GB free' }
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage '*Drive C: has 1.0 GB free*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'throws when a fresh clone is not at ComfyUI.Commit, leaving Dir as it was and creating no venv' {
        $world.Head = $old
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } |
            Should -Throw -ExpectedMessage "*clone of v0.42.5 from https://github.com/Comfy-Org/ComfyUI.git is at commit $old, not at ComfyUI.Commit $pin, so the tag has moved*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
        Test-Path -LiteralPath $dir | Should -BeFalse
        Test-Path -LiteralPath $clone | Should -BeFalse
    }

    It 'does not adopt the clone of a moved tag on the next run either' {
        $world.Head = $old
        $null = New-Item -ItemType Directory -Force -Path $dir
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage '*so the tag has moved*'
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage '*so the tag has moved*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $ArgumentList -contains 'clone' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
        @(Get-ChildItem -LiteralPath $dir -Force).Count | Should -Be 0
    }

    It "throws with git's own text when rev-parse fails in an existing checkout" {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' -and $ArgumentList -contains 'rev-parse' } -MockWith {
            $Capture.Add('HEAD')
            $Capture.Add("fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.")
            throw "'git -C $dir rev-parse HEAD' failed with exit code 128."
        }
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } |
            Should -Throw -ExpectedMessage "*rev-parse HEAD' failed with exit code 128. git said: HEAD fatal: ambiguous argument 'HEAD'*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
    }

    It 'keeps a checkout at the pin and its venv, cloning nothing and checking no space' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $result = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive -WarningVariable warnings 3>$null 6>$null
        $result.Pinned | Should -BeTrue
        $warnings.Count | Should -Be 0
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'clone' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'warns naming both commits and local-ai update for a checkout at another commit, and leaves it as it is' {
        $world.Head = $old
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $result = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive -WarningVariable warnings 3>$null 6>$null
        $result.Pinned | Should -BeFalse
        $result.Commit | Should -Be $old
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*is at commit $old, but ComfyUI.Commit pins $pin (v0.42.5); it is left as it is. Run 'local-ai update'*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'git' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'git' -and $ArgumentList -contains 'rev-parse' }
    }

    It 'refuses a Dir that holds files but is not a git checkout, running nothing' {
        $null = Write-TestFile ((Split-Path $root -Leaf) + '\ComfyUI\notes.txt') 'mine'
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage "*ComfyUI.Dir '$dir' holds files but is not a git checkout*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $dir 'notes.txt') | Should -BeTrue
    }

    It 'refuses to start without <Program>' -ForEach @(
        @{ Program = 'git' }
        @{ Program = 'uv' }
    ) {
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { $Name -eq $Program }
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage "*Installing ComfyUI needs $Program, which is not on PATH*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'checks free space before it creates a missing venv in an existing checkout' {
        Write-TestCheckout -Dir $dir
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq $dir }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' }
    }

    It 'skips pip and the torch check when the marker matches requirements.txt, the constraints and the backend' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        $result = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq $python }
        $result.Torch | Should -Be '2.14.1+cu130'
        $result.Cuda | Should -Be '13.0'
        $result.PythonVersion | Should -Be '3.13.18'
    }

    It 'installs again when <Changed> changed since the marker was written' -ForEach @(
        @{ Changed = 'requirements.txt' }
        @{ Changed = 'the constraints' }
        @{ Changed = 'the backend' }
        @{ Changed = 'ComfyUI.ExcludeNewer' }
    ) {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        switch ($Changed) {
            'requirements.txt' { [IO.File]::AppendAllText((Join-Path $dir 'requirements.txt'), "blake3`n") }
            'the constraints' { [IO.File]::AppendAllText($constraints, "# Another comment.`n") }
            'the backend' { $settings.ComfyUI.TorchBackend = 'auto' }
            'ComfyUI.ExcludeNewer' { $settings.ComfyUI.ExcludeNewer = '2026-10-27T00:00:00Z' }
        }
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $FilePath -eq $python }
    }

    It 'treats a marker that is not JSON as missing' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        [IO.File]::WriteAllText($marker, '{ not json')
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' }
        (Read-LocalAIState -Path $marker).Torch | Should -Be '2.14.1+cu130'
    }

    It 'adopts a venv found in place, which has no JSON marker: pip and the torch check run, no venv is created' {
        $world.Head = $old
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        [IO.File]::WriteAllText((Join-Path $venv 'installed'), '')
        $world.Build.python = '3.13.14'
        $result = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 3>$null 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq $python }
        $result.PythonVersion | Should -Be '3.13.14'
        (Read-LocalAIState -Path $marker).Commit | Should -Be $old
        Test-Path -LiteralPath (Join-Path $venv 'installed') | Should -BeTrue
    }

    It 'refuses a venv on another minor Python, deleting and installing nothing' {
        Write-TestCheckout -Dir $dir -Version '3.11'
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } |
            Should -Throw -ExpectedMessage "*$venv runs Python 3.11, but ComfyUI.Python is 3.13. install never deletes a venv: move $venv away*ComfyUI.Python to '3.11'*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
        Test-Path -LiteralPath $python | Should -BeTrue
    }

    It 'refuses a .venv without python.exe, deleting nothing' {
        Write-TestCheckout -Dir $dir
        $null = Write-TestFile ((Split-Path $root -Leaf) + '\ComfyUI\.venv\pyvenv.cfg') 'version_info = 3.13.14'
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage "*$venv exists but has no Scripts\python.exe*Move it away*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
        Test-Path -LiteralPath (Join-Path $venv 'pyvenv.cfg') | Should -BeTrue
    }

    It 'throws with the reinstall command for a CPU torch, writing no marker' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $world.Build.torch = '2.14.1+cpu'
        $world.Build.torchvision = '0.29.1+cpu'
        $world.Build.cuda = $null
        $world.Build.available = $false
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } |
            Should -Throw -ExpectedMessage "*$venv has the CPU torch 2.14.1+cpu, which cannot use the GPU. Replace it with: uv pip install --python `"$python`" --torch-backend cu130 -c `"$constraints`" --reinstall-package torch --reinstall-package torchvision torch torchvision*"
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'throws when <Name> is not the constrained version' -ForEach @(
        @{ Name = 'torch'; Found = '2.13.0+cu130'; Wanted = '2.14.1' }
        @{ Name = 'torchvision'; Found = '0.28.0+cu130'; Wanted = '0.29.1' }
    ) {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $world.Build[$Name] = $Found
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage "*has $Name $Found, but $constraints pins $Wanted. Replace it with*"
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'throws with the reinstall command for a <Name> built for another CUDA, writing no marker' -ForEach @(
        @{ Name = 'torch'; Found = '2.14.1+cu128' }
        @{ Name = 'torchvision'; Found = '0.29.1+cu128' }
    ) {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $world.Build[$Name] = $Found
        $world.Build.cuda = '12.8'
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } |
            Should -Throw -ExpectedMessage "*$venv has $Name $Found, not the +cu130 build ComfyUI.TorchBackend names. Replace it with: uv pip install*--reinstall-package torch*"
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'accepts any CUDA build when ComfyUI.TorchBackend is auto' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $settings.ComfyUI.TorchBackend = 'auto'
        $world.Build.torch = '2.14.1+cu128'
        $world.Build.torchvision = '0.29.1+cu128'
        (Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null).Torch | Should -Be '2.14.1+cu128'
        (Read-LocalAIState -Path $marker).Backend | Should -Be 'auto'
    }

    It 'refuses to run pip while a process runs from the venv, naming it' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        Mock Get-Process -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ Id = 7804; Path = $python }
            [pscustomobject]@{ Id = 1; Path = 'C:\Windows\System32\svchost.exe' }
            [pscustomobject]@{ Id = 2; Path = $null }
        }
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } |
            Should -Throw -ExpectedMessage "*ComfyUI or the image gate runs from $venv (PID 7804), so uv cannot replace its files. Run 'local-ai stop'*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
    }

    It 'does not look for processes when the marker matches, as nothing is replaced' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        Mock Get-Process -ModuleName LocalAI -MockWith { [pscustomobject]@{ Id = 7804; Path = $python } }
        $null = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null
        # Only the first run, which installs, looks.
        Should -Invoke Get-Process -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'throws when torch finds no CUDA device' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        $world.Build.available = $false
        $world.Build.device = $null
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage '*finds no CUDA device. Check the NVIDIA driver with nvidia-smi*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'throws naming what Python said when the torch check fails' {
        Write-TestCheckout -Dir $dir -Version '3.13.14'
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq $python } -MockWith {
            $Capture.Add("ModuleNotFoundError: No module named 'torch'")
            throw "'$python -I -c ...' failed with exit code 1."
        }
        { Install-ComfyUI -Settings $settings -RepoRoot $TestDrive 6>$null } | Should -Throw -ExpectedMessage "*torch check in $venv failed*No module named 'torch'*"
    }

    It 'keeps a venv on the Microsoft Store Python, warning once with update named, and creates no other' {
        Write-TestCheckout -Dir $dir -Version '3.13.14' -BaseHome $storeHome
        $result = Install-ComfyUI -Settings $settings -RepoRoot $TestDrive -WarningVariable warnings 3>$null 6>$null
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeExactly ("$venv runs on the Microsoft Store Python 3.13.14, whose launches can fail or hang until Windows restarts, and ComfyUI " +
            "and the image gate with them. install never deletes a venv; run 'local-ai update', which makes it anew on a uv-managed Python 3.13 with the same pins.")
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' }
        $result.Python | Should -Be $python
        (Read-LocalAIState -Path $marker).CreatedVenv | Should -BeFalse
    }

    Context 'Reset-ComfyUIVenv' {
        BeforeEach {
            # The earlier scripts' venv on the Store Python, with the marker of a venv install found in place and a package added by hand.
            Write-TestCheckout -Dir $dir -Version '3.13.14' -BaseHome $storeHome
            Write-LocalAIState -Path $marker -State @{ CreatedVenv = $false; Torch = '2.14.1+cu130' }
            $leaf = Split-Path $root -Leaf
            $byHand = Write-TestFile "$leaf\ComfyUI\.venv\Lib\site-packages\by-hand.py" 'mine'
            $checkpoint = Write-TestFile "$leaf\ComfyUI\models\checkpoints\model.safetensors" 'weights'
            $image = Write-TestFile "$leaf\ComfyUI\output\image.png" 'pixels'
            $aside = "$dir.local-ai-old-venv"
            $reset = { Invoke-ModuleFunction 'Reset-ComfyUIVenv' @{ Settings = $settings; RepoRoot = $TestDrive } }
            $baseOf = { Invoke-ModuleFunction 'Get-VenvBasePython' @{ Venv = $venv } }
        }

        It 'moves the venv aside, creates one on a uv-managed Python with the pinned requirements, then deletes the old one and nothing else' {
            $result = & $reset 6>$null
            Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq $dir -and $RequiredBytes -eq 4552284304 }
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'uv' -and ($ArgumentList -join ' ') -eq "venv --python 3.13 --managed-python $venv" -and [bool]$Console
            }
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'uv' -and ($ArgumentList -join ' ') -eq
                "pip install --python $python --torch-backend cu130 --exclude-newer 2026-10-23T00:07:14Z -c $constraints -r $dir\requirements.txt"
            }
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq $python }
            $result.Rebuilt | Should -BeTrue
            $result.Python | Should -Be $python
            $result.PythonVersion | Should -Be '3.13.18'
            $result.Torch | Should -Be '2.14.1+cu130'
            (& $baseOf).Store | Should -BeFalse
            $written = Read-LocalAIState -Path $marker
            $written.CreatedVenv | Should -BeTrue
            $written.Python | Should -Be '3.13.18'
            Test-Path -LiteralPath $byHand | Should -BeFalse
            Test-Path -LiteralPath $aside | Should -BeFalse
            Test-Path -LiteralPath $checkpoint | Should -BeTrue
            Test-Path -LiteralPath $image | Should -BeTrue
        }

        It 'deletes the new venv and puts the old one back as it was when <Case>' -ForEach @(
            @{ Case = 'torch finds no CUDA device'; Kind = 'torch'; Expected = '*finds no CUDA device*' }
            @{ Case = 'uv fails halfway through creating the venv'; Kind = 'venv'; Expected = "'uv venv' failed with exit code 2." }
            @{ Case = 'the drive lacks the space'; Kind = 'space'; Expected = 'Drive C: has 1.0 GB free' }
        ) {
            switch ($Kind) {
                'torch' { $world.Build.available = $false }
                'venv' {
                    Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' } -MockWith {
                        Write-TestVenv -Dir $dir -Version '3.13'
                        throw "'uv venv' failed with exit code 2."
                    }
                }
                'space' { Mock Test-FreeSpace -ModuleName LocalAI -MockWith { throw 'Drive C: has 1.0 GB free' } }
            }
            { & $reset 6>$null } | Should -Throw -ExpectedMessage "The new venv on a uv-managed Python failed: $Expected ComfyUI's venv is back on the Microsoft Store Python, as it was."
            $back = & $baseOf
            $back.Store | Should -BeTrue
            $back.Version | Should -Be '3.13.14'
            Test-Path -LiteralPath $byHand | Should -BeTrue
            $kept = Read-LocalAIState -Path $marker
            $kept.CreatedVenv | Should -BeFalse
            $kept.ContainsKey('RequirementsSha256') | Should -BeFalse
            Test-Path -LiteralPath $aside | Should -BeFalse
            @(Get-ChildItem -LiteralPath $dir -Force -Filter '*.local-ai-removing-*').Count | Should -Be 0
            Test-Path -LiteralPath $checkpoint | Should -BeTrue
        }

        It 'says where the old venv is and how to put it back when the new one cannot be deleted' {
            $world.Build.available = $false
            Mock Remove-LocalAIFolder -ModuleName LocalAI -MockWith { throw "Cannot delete ${Path}: Windows refuses to rename it." }
            { & $reset 6>$null } | Should -Throw -ExpectedMessage ("The new venv on a uv-managed Python failed: *finds no CUDA device* The old venv could not be moved back (*), " +
                "so it stays in $aside. Cannot delete ${venv}: Windows refuses to rename it. Delete $venv if it is still there, move $aside to $venv, then run update again.")
            Test-Path -LiteralPath (Join-Path $aside 'Lib\site-packages\by-hand.py') | Should -BeTrue
        }

        It 'refuses, moving and creating nothing, when an earlier update left a venv aside' {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $aside 'Scripts')
            { & $reset 6>$null } | Should -Throw -ExpectedMessage ("$aside holds the venv that an earlier update moved aside, so $venv was not replaced. Delete $aside, or " +
                "move it back to $venv when that is missing, then run update again.")
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
            (& $baseOf).Store | Should -BeTrue
        }

        It 'refuses, naming the process, while one runs from the venv' {
            Mock Get-Process -ModuleName LocalAI -MockWith { [pscustomobject]@{ Id = 7804; Path = $python } }
            { & $reset 6>$null } | Should -Throw -ExpectedMessage "ComfyUI or the image gate runs from $venv (PID 7804), so it cannot be moved aside. Run 'local-ai stop'*"
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' }
            Test-Path -LiteralPath $aside | Should -BeFalse
        }

        It 'keeps the new venv and warns when the old one cannot be deleted' {
            Mock Remove-LocalAITree -ModuleName LocalAI -ParameterFilter { $Path -eq $aside } -MockWith { throw "Cannot delete '$aside\Lib\torch.dll': in use." }
            $output = @(& $reset 3>&1 6>$null)
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -BeExactly "Could not delete the old venv ${aside}: Cannot delete '$aside\Lib\torch.dll': in use. Delete it to free its space."
            @($output | Where-Object { $_ -is [hashtable] })[-1].Rebuilt | Should -BeTrue
            (& $baseOf).Store | Should -BeFalse
            Test-Path -LiteralPath $aside | Should -BeTrue
        }

        It 'hands a venv that no longer runs on the Store Python to Install-ComfyUI as it is' {
            Write-TestVenv -Dir $dir -Version '3.13.14'
            $result = & $reset 6>$null
            $result.ContainsKey('Rebuilt') | Should -BeFalse
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'venv' }
            Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' }
            Test-Path -LiteralPath $byHand | Should -BeTrue
            Test-Path -LiteralPath $aside | Should -BeFalse
        }
    }
}

Describe 'Install-ImageModel' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $content = 'checkpoint bytes'
        $pinned = Write-TestFile "$leaf\pinned.bin" $content
        $sha = (Get-FileHash -LiteralPath $pinned -Algorithm SHA256).Hash.ToLowerInvariant()
        $size = (Get-Item -LiteralPath $pinned).Length
        $dir = Join-Path $root 'ComfyUI'
        $folder = Join-Path $dir 'models\checkpoints'
        $target = Join-Path $folder 'Test.safetensors'
        $staging = Join-Path $dir 'models\.local-ai-download'
        $settings = @{
            ComfyUI = @{ Dir = $dir }
            HfCli   = @{ Version = '2.2.0'; ExcludeNewer = '2026-10-08T15:31:00Z' }
            Images  = @{ Repo = 'Lykon/dreamshaper-xl-lightning'; File = 'Test.safetensors'; Revision = '561086c22aba3925b1e8803a73857f061635c7c3'; Size = $size; Sha256 = $sha }
        }
        $verified = @{}
        $hf = @{ Content = $content; Write = $true }
        Mock Test-FreeSpace -ModuleName LocalAI
        # Like hf download --local-dir: the file plus its .cache\huggingface metadata folder.
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uvx' } -MockWith {
            $localDir = $ArgumentList[[array]::IndexOf($ArgumentList, '--local-dir') + 1]
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $localDir '.cache\huggingface\download')
            if ($hf.Write) { [IO.File]::WriteAllText((Join-Path $localDir 'Test.safetensors'), $hf.Content) }
            0
        }
    }

    It 'checks a present file once, then skips the hash while its length and write time are unchanged' {
        $null = Write-TestFile "$leaf\ComfyUI\models\checkpoints\Test.safetensors" $content
        $result = Install-ImageModel -Settings $settings -Verified $verified 6>$null
        $result.Path | Should -Be $target
        $result.Sha256 | Should -Be $sha
        $verified[$sha].Length | Should -Be $size
        Mock Get-FileHash -ModuleName LocalAI
        $null = Install-ImageModel -Settings $settings -Verified $verified 6>$null
        Should -Invoke Get-FileHash -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'throws naming the file, its size and the fix when a present file has another size, keeping it' {
        $null = Write-TestFile "$leaf\ComfyUI\models\checkpoints\Test.safetensors" 'short'
        { Install-ImageModel -Settings $settings -Verified $verified 6>$null } |
            Should -Throw -ExpectedMessage "*$target has 5 bytes, but Images.Size pins $size*Delete $target, then run 'local-ai install' again*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It 'throws naming both hashes when a present file of the right size has other content, keeping it' {
        $null = Write-TestFile "$leaf\ComfyUI\models\checkpoints\Test.safetensors" ('X' * $size)
        { Install-ImageModel -Settings $settings -Verified $verified 6>$null } |
            Should -Throw -ExpectedMessage "*$target hashes to *, not to $sha. Delete $target*"
        $verified.Count | Should -Be 0
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It 'downloads an absent file with the pinned hf CLI to a staging folder, checks it, moves it in and removes the staging folder' {
        $result = Install-ImageModel -Settings $settings -Verified $verified 6>$null
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq $folder -and $RequiredBytes -eq $size }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq ("--from huggingface_hub==2.2.0 --exclude-newer 2026-10-08T15:31:00Z hf download Lykon/dreamshaper-xl-lightning Test.safetensors " +
                "--revision 561086c22aba3925b1e8803a73857f061635c7c3 --local-dir $staging") -and [bool]$Console -and $ArgumentList -notcontains '--token'
        }
        Get-Content -LiteralPath $target -Raw | Should -BeExactly $content
        Test-Path -LiteralPath $staging | Should -BeFalse
        $result.Path | Should -Be $target
        $result.Sha256 | Should -Be $sha
        $verified[$sha].WriteTicks | Should -Be (Get-Item -LiteralPath $target).LastWriteTimeUtc.Ticks
    }

    It 'removes the staging folder, moves nothing and throws when the download <Case>' -ForEach @(
        @{ Case = 'has another size'; Download = 'short'; Written = $true; Message = '*has 5 bytes, but Images.Size pins*check Images.Repo, Images.File and Images.Revision*' }
        @{ Case = 'has another hash'; Download = 'CHECKPOINT BYTES'; Written = $true; Message = '*hashes to *, not to *check Images.Repo*' }
        @{ Case = 'is missing'; Download = ''; Written = $false; Message = "*'hf download' finished, but *Test.safetensors does not exist*" }
    ) {
        $hf.Content = $Download
        $hf.Write = $Written
        { Install-ImageModel -Settings $settings -Verified $verified 6>$null } | Should -Throw -ExpectedMessage $Message
        Test-Path -LiteralPath $target | Should -BeFalse
        Test-Path -LiteralPath $staging | Should -BeFalse
        $verified.Count | Should -Be 0
    }

    It 'removes the staging folder when hf fails' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uvx' } -MockWith {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $staging '.cache\huggingface\download')
            [IO.File]::WriteAllText((Join-Path $staging '.cache\huggingface\download\x.incomplete'), 'part')
            throw "'uvx --from huggingface_hub==2.2.0 hf download ...' failed with exit code 1."
        }
        { Install-ImageModel -Settings $settings -Verified $verified 6>$null } | Should -Throw -ExpectedMessage '*failed with exit code 1*'
        Test-Path -LiteralPath $staging | Should -BeFalse
    }

    It 'downloads nothing when the free-space check fails' {
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith { throw 'Drive C: has 1.0 GB free' }
        { Install-ImageModel -Settings $settings -Verified $verified 6>$null } | Should -Throw -ExpectedMessage '*Drive C: has 1.0 GB free*'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'removes the partial download a killed run left before it checks the free space' {
        $null = Write-TestFile "$leaf\ComfyUI\models\.local-ai-download\.cache\huggingface\download\x.incomplete" 'part'
        $seen = @{}
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith { $seen.Staging = Test-Path -LiteralPath $staging; throw 'Drive C: has 1.0 GB free' }
        { Install-ImageModel -Settings $settings -Verified $verified 6>$null } | Should -Throw -ExpectedMessage '*Drive C: has 1.0 GB free*'
        $seen.Staging | Should -BeFalse
        Test-Path -LiteralPath $staging | Should -BeFalse
    }

    It 'warns and checks only the size when Images.Sha256 is empty' {
        $settings.Images.Sha256 = ''
        $null = Write-TestFile "$leaf\ComfyUI\models\checkpoints\Test.safetensors" ('X' * $size)
        $null = Install-ImageModel -Settings $settings -Verified $verified -WarningVariable warnings 3>$null 6>$null
        "$($warnings[0])" | Should -BeLike "*Images.Sha256 is empty, so the content of $target is not checked*"
    }
}

Describe 'Test-FilesRoot' {
    BeforeAll {
        $patterns = @((Get-LocalAISettings -DefaultsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\defaults.psd1')).Files.DenyPatterns)

        # Run Test-FilesRoot and return @{ Result; Printed; Warnings } with host text and warnings joined.
        function Invoke-RootTest([hashtable]$Settings, [hashtable]$Paths, [string]$UserProfile, [int]$MaxEntries = 100000, [string]$RepoRoot, [string]$ToolDir) {
            $output = @(Test-FilesRoot -Settings $Settings -Paths $Paths -UserProfile $UserProfile -MaxEntries $MaxEntries -RepoRoot $RepoRoot -ToolDir $ToolDir 3>&1 6>&1)
            return @{
                Result   = @($output | Where-Object { $_ -is [bool] })
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            }
        }

        # Turns a privilege of this process's token on or off and returns whether it was on. Git Bash turns on
        # SeBackupPrivilege for an administrator, as on CI's runner, and its children inherit it; with it on, a folder
        # opens for listing despite a Deny rule, so the test of such a folder turns it off first.
        if (-not ('LocalAITestTokenPrivilege' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class LocalAITestTokenPrivilege
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct TokenPrivilege { public uint Count; public uint LuidLow; public int LuidHigh; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivilege state, uint length, ref TokenPrivilege previous, out uint returned);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static bool Set(string name, bool enable)
    {
        IntPtr token;
        // TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
        if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out token)) { throw new Win32Exception(); }
        try
        {
            long luid;
            if (!LookupPrivilegeValue(null, name, out luid)) { throw new Win32Exception(); }
            TokenPrivilege state = new TokenPrivilege { Count = 1, LuidLow = (uint)luid, LuidHigh = (int)(luid >> 32), Attributes = enable ? 2u : 0u };
            TokenPrivilege previous = new TokenPrivilege();
            uint returned;
            if (!AdjustTokenPrivileges(token, false, ref state, (uint)Marshal.SizeOf(previous), ref previous, out returned)) { throw new Win32Exception(); }
            // previous lists the privilege only when its state changed; ERROR_NOT_ALL_ASSIGNED means the token lacks it.
            if (previous.Count == 0) { return Marshal.GetLastWin32Error() == 1300 ? false : enable; }
            return (previous.Attributes & 2u) != 0;
        }
        finally { CloseHandle(token); }
    }
}
'@
        }
    }

    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $base -Leaf
        $root = Join-Path $base 'AI-Files'
        $null = Write-TestFile "$leaf\AI-Files\readme.md" 'read me'
        $null = Write-TestFile "$leaf\AI-Files\notes\plan.txt" 'plan'
        $null = Write-TestFile "$leaf\AI-Files\notes\deep\more\idea.txt" 'idea'
        # Matches every deny pattern but lies outside Files.Root.
        $outside = Join-Path $base 'outside'
        $null = Write-TestFile "$leaf\outside\server.key" 'secret'
        $null = Write-TestFile "$leaf\outside\my-secret-notes.txt" 'secret'
        $userProfile = Join-Path $base 'profile'
        $settings = @{
            Files     = @{ Root = $root; DenyPatterns = $patterns }
            OpenWebUI = @{ DataDir = Join-Path $base 'open-webui' }
            ComfyUI   = @{ Dir = Join-Path $base 'ComfyUI' }
        }
        $paths = Get-LocalAIPaths -Root (Join-Path $base 'local-ai')
        $links = New-Object System.Collections.Generic.List[string]
        $denied = $null
        $longTop = $null
        $oddTop = $null
    }

    AfterEach {
        # Removes the links only, never what they lead to.
        foreach ($link in $links) { if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link, $false) } }
        if ($denied) {
            if ($denied.Backup) { $null = [LocalAITestTokenPrivilege]::Set('SeBackupPrivilege', $true) }
            $security = $denied.Folder.GetAccessControl()
            $null = $security.RemoveAccessRule($denied.Rule)
            $denied.Folder.SetAccessControl($security)
        }
        # Windows PowerShell 5.1 removes TestDrive with paths of at most 260 characters.
        if ($longTop) { [IO.Directory]::Delete('\\?\' + $longTop, $true) }
        # A folder with a device name, which only the \\?\ form removes on every Windows.
        if ($oddTop) { [IO.Directory]::Delete('\\?\' + $oddTop, $true) }
    }

    It 'refuses a folder whose path holds <Name>, as server-filesystem 2.3.0 refuses every path through it' -ForEach @(
        @{ Name = 'aux' }
        @{ Name = 'Con.d' }
    ) {
        # Made through \\?\, since Windows takes such a name for a device only as the last part of a path as written.
        $oddTop = Join-Path $base $Name
        $odd = Join-Path $oddTop 'AI-Files'
        $null = [IO.Directory]::CreateDirectory('\\?\' + $odd)
        [IO.File]::WriteAllText('\\?\' + (Join-Path $odd 'readme.md'), 'read me')
        $settings.Files.Root = $odd
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings | Should -BeLike "*is not served*the name '$Name' on its path is a Windows device name or ends in a dot or a space*"
    }

    It 'serves a folder whose file names match no deny pattern, warning about nothing' {
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($true)
        $run.Warnings.Count | Should -Be 0
        $run.Printed | Should -BeNullOrEmpty
    }

    It 'refuses a folder holding <Name>, naming it by its path inside Files.Root' -ForEach @(
        @{ Name = 'a hidden key file deep down'; File = 'notes\deep\server.key'; Hidden = $true }
        @{ Name = 'a file with secret in its name'; File = 'my-secret-notes.txt'; Hidden = $false }
        @{ Name = 'an SSH key in capitals'; File = 'notes\ID_RSA'; Hidden = $false }
        @{ Name = 'a certificate with a capital extension'; File = 'cert.PEM'; Hidden = $false }
        @{ Name = 'a git credential store'; File = '.git-credentials'; Hidden = $true }
    ) {
        $path = Write-TestFile "$leaf\AI-Files\$File" 'secret'
        if ($Hidden) { (Get-Item -LiteralPath $path -Force).Attributes = 'Hidden' }
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike ("Files.Root '$root' is not served, so the file tools are off: it holds 1 file(s) or folder(s) whose names match " +
            "Files.DenyPatterns: $File. Move them out of it*")
    }

    It 'refuses a folder holding the file <File>, which a default pattern names' -ForEach @(
        @{ File = 'putty.ppk' }, @{ File = 'app.jks' }, @{ File = 'app.keystore' }, @{ File = 'mail.gpg' }, @{ File = '.npmrc' }, @{ File = '.netrc' }
        @{ File = '_netrc' }, @{ File = '.pypirc' }, @{ File = 'credentials' }, @{ File = 'Credentials.json' }, @{ File = 'key4.db' }, @{ File = 'logins.json' }
    ) {
        $null = Write-TestFile "$leaf\AI-Files\notes\$File" 'secret'
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings[0] | Should -BeLike "*it holds 1 file(s) or folder(s) whose names match Files.DenyPatterns: notes\$File. Move them*"
    }

    It 'refuses a folder holding a folder named <Folder>, counted as one hit and not entered' -ForEach @(
        @{ Folder = '.git' }, @{ Folder = '.ssh' }, @{ Folder = '.aws' }, @{ Folder = '.azure' }, @{ Folder = '.gnupg' }, @{ Folder = '.kube' }, @{ Folder = '.docker' }
    ) {
        $null = Write-TestFile "$leaf\AI-Files\project\$Folder\config" 'remote with a token'
        $null = Write-TestFile "$leaf\AI-Files\project\$Folder\deploy.key" 'secret'
        (Get-Item -LiteralPath (Join-Path $root "project\$Folder") -Force).Attributes = 'Hidden, Directory'
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike "*it holds 1 file(s) or folder(s) whose names match Files.DenyPatterns: project\$Folder. Move them*"
    }

    It 'lists five matches, sorted, and says how many more there are' {
        foreach ($name in 'g', 'a', 'f', 'b', 'e', 'c', 'd') { $null = Write-TestFile "$leaf\AI-Files\keys\$name.key" 'secret' }
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings[0] | Should -BeLike '*it holds 7 file(s) or folder(s) whose names match Files.DenyPatterns: keys\a.key, keys\b.key, keys\c.key, keys\d.key, keys\e.key and 2 more.*'
    }

    It 'finds a deny-pattern file whose path is longer than 260 characters, which the files server can read' {
        $deep = $root
        foreach ($i in 1..5) { $deep = Join-Path $deep ("deep$i-" + ('x' * 45)) }
        $longTop = Join-Path $root ("deep1-" + ('x' * 45))
        $null = [IO.Directory]::CreateDirectory('\\?\' + $deep)
        [IO.File]::WriteAllText('\\?\' + (Join-Path $deep 'server.key'), 'secret')
        (Join-Path $deep 'server.key').Length | Should -BeGreaterThan 260
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike "*whose names match Files.DenyPatterns: deep1-x*\deep5-x*\server.key. Move them*"
    }

    It 'refuses a folder holding a folder this account cannot list, which the server could still read files in by name' {
        $locked = Join-Path $root 'notes\locked'
        $null = Write-TestFile "$leaf\AI-Files\notes\locked\server-notes.txt" 'hidden'
        $folder = New-Object IO.DirectoryInfo -ArgumentList $locked
        $rule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent().User),
            ([Security.AccessControl.FileSystemRights]::ListDirectory), ([Security.AccessControl.AccessControlType]::Deny)
        $security = $folder.GetAccessControl()
        $security.AddAccessRule($rule)
        $folder.SetAccessControl($security)
        $denied = @{ Folder = $folder; Rule = $rule; Backup = [LocalAITestTokenPrivilege]::Set('SeBackupPrivilege', $false) }
        { [IO.Directory]::GetFileSystemEntries($locked) } | Should -Throw -Because 'this account must be unable to list the folder'
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike ("*it holds 1 folder(s) this account cannot list, so start cannot check them against Files.DenyPatterns: notes\locked. " +
            'Choose another folder, or let this account list them.')
    }

    It 'follows neither a junction loop nor a junction to outside, lists both and still serves the folder' {
        $loop = Join-Path $root 'notes\loop'
        $exit = Join-Path $root 'ext'
        $null = New-Item -ItemType Junction -Path $loop -Target $root
        $links.Add($loop)
        $null = New-Item -ItemType Junction -Path $exit -Target $outside
        $links.Add($exit)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 10
        $run.Result | Should -Be @($true)
        $run.Warnings.Count | Should -Be 0
        $run.Printed | Should -BeLike '*Files.Root holds 2 link(s), which the deny check does not follow*refuses those that lead outside Files.Root: ext, notes\loop.*'
    }

    It 'refuses a folder that is a junction itself' {
        $junction = Join-Path $base 'linked'
        $null = New-Item -ItemType Junction -Path $junction -Target $root
        $links.Add($junction)
        $settings.Files.Root = $junction
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings[0] | Should -BeLike '*is not served*it is a link (a junction or symbolic link). Set it to the folder the link leads to.'
    }

    It 'refuses a folder reached through a junction above it, which the other checks could not see through' {
        $via = Join-Path $base 'via'
        $null = New-Item -ItemType Junction -Path $via -Target $base
        $links.Add($via)
        # Through the junction, the launcher's own folder looks like a folder beside it.
        $settings.Files.Root = Join-Path $via 'local-ai'
        $null = New-Item -ItemType Directory -Force -Path $paths.Root
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike "*is not served*the folder *\$leaf\via on its path is a link (a junction or symbolic link). Set it to the path the link leads to."
    }

    It 'compares folders by their long names, so an 8.3 short name does not get past <Case>' -ForEach @(
        @{ Case = 'a forbidden folder given short'; Short = 'DataDir' }
        @{ Case = 'Files.Root given short'; Short = 'Root' }
    ) {
        $long = Join-Path $env:ProgramFiles 'Common Files'
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:ProgramFiles).ShortPath
        if ($short -eq $env:ProgramFiles -or -not (Test-Path -LiteralPath $long -PathType Container)) {
            Set-ItResult -Skipped -Because "$env:ProgramFiles has no 8.3 short name on this PC"
            return
        }
        $settings.Files.Root = $long
        $settings.OpenWebUI.DataDir = $long
        switch ($Short) {
            'Root' { $settings.Files.Root = Join-Path $short 'Common Files' }
            'DataDir' { $settings.OpenWebUI.DataDir = Join-Path $short 'Common Files' }
        }
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings[0] | Should -BeLike "*it is inside or holds OpenWebUI.DataDir, $long. Choose a folder*"
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a drive root'; Target = 'C:\'; Message = '*it is a drive root. Choose a folder that holds only what the model may read.' }
        @{ Case = 'a relative path'; Target = 'AI-Files'; Message = '*it is not a full path on a drive letter.' }
        @{ Case = 'a missing folder'; Target = 'missing'; Message = '*it is not an existing folder.' }
        @{ Case = 'the profile folder'; Target = 'profile'; Message = '*it is %USERPROFILE% or a folder above it.*' }
        @{ Case = 'a folder above the profile'; Target = 'base'; Message = '*it is %USERPROFILE% or a folder above it.*' }
        @{ Case = "a folder inside the launcher's"; Target = 'local-ai\logs'; Message = "*it is inside or holds the launcher's folder, *local-ai.*" }
        @{ Case = "a folder that holds the launcher's"; Target = 'holder'; Message = "*it is inside or holds the launcher's folder, *local-ai.*" }
        @{ Case = 'the Open WebUI data folder in other case'; Target = 'OPEN-WEBUI'; Message = '*it is inside or holds OpenWebUI.DataDir, *open-webui.*' }
        @{ Case = 'a folder inside ComfyUI'; Target = 'ComfyUI\output'; Message = '*it is inside or holds ComfyUI.Dir, *ComfyUI.*' }
    ) {
        switch ($Target) {
            'C:\' { $settings.Files.Root = 'C:\' }
            'AI-Files' { $settings.Files.Root = 'AI-Files' }
            'base' { $settings.Files.Root = $base }
            'profile' { $userProfile = $root }
            'holder' { $paths = Get-LocalAIPaths -Root (Join-Path $root 'local-ai') }
            default { $settings.Files.Root = Join-Path $base $Target }
        }
        foreach ($folder in 'local-ai\logs', 'open-webui', 'ComfyUI\output') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $base $folder) }
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike $Message
    }

    It "refuses <Case>, which holds the launcher's own code or tool environments" -ForEach @(
        @{ Case = "a folder inside the launcher's repository"; Target = 'repo\config'; Message = "*it is inside or holds the launcher's repository, *repo.*" }
        @{ Case = "a folder that holds uv's tool folder"; Target = 'uv'; Message = "*it is inside or holds uv's tool folder, *uv\tools.*" }
        @{ Case = "a folder inside uv's tool folder"; Target = 'uv\tools\mcpo'; Message = "*it is inside or holds uv's tool folder, *uv\tools.*" }
    ) {
        foreach ($folder in 'repo\config', 'uv\tools\mcpo') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $base $folder) }
        $settings.Files.Root = Join-Path $base $Target
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile -RepoRoot (Join-Path $base 'repo') -ToolDir (Join-Path $base 'uv\tools')
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike $Message
    }

    It 'serves a folder beside the repository and the tool folder it is given' {
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile -RepoRoot (Join-Path $base 'repo') -ToolDir (Join-Path $base 'uv\tools')
        $run.Result | Should -Be @($true)
    }

    It 'refuses a hard link to a file outside the folder, naming it by its path inside, and leaves the file alone' {
        $null = New-Item -ItemType HardLink -Path (Join-Path $root 'notes\copy.txt') -Target (Join-Path $outside 'server.key')
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings.Count | Should -Be 1
        $run.Warnings[0] | Should -BeLike ("Files.Root '$root' is not served, so the file tools are off: it holds 1 hard link(s) to files that also have a " +
            'name outside it, which the file tools would read: notes\copy.txt. Move them out of it, or choose another folder.')
        [IO.File]::ReadAllText((Join-Path $outside 'server.key')) | Should -BeExactly 'secret'
    }

    It 'serves a folder whose hard links all have their names inside it' {
        $null = New-Item -ItemType HardLink -Path (Join-Path $root 'notes\readme-again.md') -Target (Join-Path $root 'readme.md')
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($true)
        $run.Warnings.Count | Should -Be 0
    }

    It 'refuses a folder holding a file whose names it cannot count, as when the file went away during the check' {
        Mock Get-OutsideLinkCount -ModuleName LocalAI -MockWith { , [int[]]@(foreach ($item in $Path) { if ($item -like '*plan.txt') { -1 } else { 0 } }) }
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile
        $run.Result | Should -Be @($false)
        $run.Warnings[0] | Should -BeLike ('*it holds 1 file(s) this account cannot open to count their names, so start cannot tell whether they are hard links ' +
            'to files outside it: notes\plan.txt. Choose another folder*')
    }

    It 'counts no names when a file already matches a deny pattern' {
        Mock Get-OutsideLinkCount -ModuleName LocalAI
        $null = Write-TestFile "$leaf\AI-Files\server.key" 'secret'
        (Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile).Result | Should -Be @($false)
        Should -Invoke Get-OutsideLinkCount -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'refuses a folder with more entries than it scans, which keeps a start bounded' {
        $run = Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile -MaxEntries 3
        $run.Result | Should -Be @($false)
        $run.Warnings[0] | Should -BeLike '*it holds more than 3 files and folders, more than start checks against Files.DenyPatterns. Choose a smaller folder.'
    }

    It 'trims a trailing backslash before it compares folders' {
        $settings.Files.Root = "$root\"
        (Invoke-RootTest -Settings $settings -Paths $paths -UserProfile $userProfile).Result | Should -Be @($true)
    }
}
