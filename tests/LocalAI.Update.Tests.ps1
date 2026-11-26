# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS: UPDATE AND UNINSTALL
# -------------------------------------------------------
#
# Pester 6 tests for src\LocalAI.psm1 at update and uninstall: the update plans and steps of each
# part, Update-LocalAI, and Uninstall-LocalAI. tests\LocalAI.TestSetup.ps1 imports the module and
# holds the shared helpers.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LocalAI.TestSetup.ps1')
}

Describe 'Update helpers' {
    It "reads the minor version '<Expected>' from '<Version>'" -ForEach @(
        @{ Version = '3.12.16'; Expected = '3.12' }
        @{ Version = '3.11'; Expected = '3.11' }
        @{ Version = 'none'; Expected = 'none' }
    ) {
        Invoke-ModuleFunction 'Get-PythonMinor' @{ Version = $Version } | Should -BeExactly $Expected
    }

    It 'tells whether this window can ask, as .NET reports its input' {
        Invoke-ModuleFunction 'Test-LocalAIConsoleInput' | Should -Be ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
    }

    It 'tells whether this window shows the output, as .NET reports it' {
        Invoke-ModuleFunction 'Test-LocalAIConsoleOutput' | Should -Be (-not [Console]::IsOutputRedirected)
    }

    It 'drops pending console keys, and leaves a host without a console buffer alone' {
        { Invoke-ModuleFunction 'Clear-LocalAIConsoleInput' } | Should -Not -Throw
    }

    It 'returns the recorded services whose process or listener runs, sorted, and none without a readable state file' {
        $path = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))\state.json"
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if (@(4100, 4301) -contains [int]$Record.Pid) { 'match' } else { 'other' } }
        @(Invoke-ModuleFunction 'Get-LocalAIRunningService' @{ Path = $path }).Count | Should -Be 0
        Write-LocalAIState -Path $path -State @{ Services = @{ OpenWebUI = @{ Pid = 4100 }; ImageGate = @{ Pid = 4300; Listener = @{ Pid = 4301 } }; ComfyUI = @{ Pid = 4200 } } }
        @(Invoke-ModuleFunction 'Get-LocalAIRunningService' @{ Path = $path }) | Should -Be @('ImageGate', 'OpenWebUI')
        [IO.File]::WriteAllText($path, 'not json')
        @(Invoke-ModuleFunction 'Get-LocalAIRunningService' @{ Path = $path }).Count | Should -Be 0
    }
}

Describe 'Wait-LocalAIConsoleKey' {
    BeforeAll {
        # Run Wait-LocalAIConsoleKey and return @{ Printed; Other } with the host texts joined by '|' and anything else it wrote.
        function Invoke-TestWait {
            $output = @(Invoke-ModuleFunction 'Wait-LocalAIConsoleKey' 3>&1 6>&1)
            return @{
                Printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join '|'
                Other   = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
            }
        }
    }

    BeforeEach {
        $order = New-Object System.Collections.Generic.List[string]
        Mock Test-LocalAIConsoleInput -ModuleName LocalAI -MockWith { $true }
        # Not this test run's output, which a runner may redirect, nor its command line, which may hold -NonInteractive.
        Mock Test-LocalAIConsoleOutput -ModuleName LocalAI -MockWith { $true }
        Mock Test-LocalAINonInteractive -ModuleName LocalAI -MockWith { $false }
        Mock Clear-LocalAIConsoleInput -ModuleName LocalAI -MockWith { $order.Add('flush') }
        # Never the real key, which would wait for a person at this console; 13 is Enter.
        Mock Read-LocalAIConsoleKey -ModuleName LocalAI -MockWith {
            $order.Add('read')
            13
        }
    }

    It 'drops the keys typed ahead, then asks for any key and waits for one, writing nothing else' {
        $run = Invoke-TestWait
        @($order) | Should -Be @('flush', 'read')
        $run.Printed | Should -BeExactly 'Press any key to continue . . .|'
        $run.Other | Should -BeNullOrEmpty
    }

    It 'goes on waiting while only Alt, Shift, a Windows key, Ctrl or a lock key goes down, as for Alt+Tab, and ends at the next key, such as Ctrl+C' {
        $keys = New-Object System.Collections.Generic.Queue[int]
        # Alt, Shift, the left and the right Windows key, Ctrl, Caps Lock, Num Lock, Scroll Lock, then C.
        foreach ($code in 18, 16, 91, 92, 17, 20, 144, 145, 67) { $keys.Enqueue($code) }
        Mock Read-LocalAIConsoleKey -ModuleName LocalAI -MockWith {
            $order.Add('read')
            $keys.Dequeue()
        }
        $null = Invoke-TestWait
        @($order) | Should -Be (@('flush') + @('read') * 9)
        $keys.Count | Should -Be 0
    }

    It 'returns at once, printing nothing, when this window cannot ask, as when a program or a test redirects its input' {
        Mock Test-LocalAIConsoleInput -ModuleName LocalAI -MockWith { $false }
        $run = Invoke-TestWait
        $run.Printed | Should -BeNullOrEmpty
        @($order) | Should -BeNullOrEmpty
        Should -Invoke Read-LocalAIConsoleKey -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'returns at once, printing nothing, when its output goes to a file or a pipe, as when a program reads it, although the window could ask' {
        Mock Test-LocalAIConsoleOutput -ModuleName LocalAI -MockWith { $false }
        $run = Invoke-TestWait
        $run.Printed | Should -BeNullOrEmpty
        $run.Other | Should -BeNullOrEmpty
        @($order) | Should -BeNullOrEmpty
        Should -Invoke Read-LocalAIConsoleKey -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'returns at once, printing nothing, when PowerShell runs with -NonInteractive, as a scheduled task may start it, although the window could ask' {
        Mock Test-LocalAINonInteractive -ModuleName LocalAI -MockWith { $true }
        $run = Invoke-TestWait
        $run.Printed | Should -BeNullOrEmpty
        $run.Other | Should -BeNullOrEmpty
        @($order) | Should -BeNullOrEmpty
        Should -Invoke Read-LocalAIConsoleKey -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'never throws when this host reads no keys' {
        Mock Read-LocalAIConsoleKey -ModuleName LocalAI -MockWith { throw 'The method or operation is not implemented.' }
        $run = Invoke-TestWait
        $run.Printed | Should -BeExactly 'Press any key to continue . . .|'
        $run.Other | Should -BeNullOrEmpty
    }
}

Describe 'Test-LocalAINonInteractive' {
    It 'is <Expected> for the command line <Line>' -ForEach @(
        @{ Line = 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File C:\Launcher\src\local-ai.ps1 start'; Expected = $true }
        @{ Line = 'powershell.exe -noni -File C:\Launcher\src\local-ai.ps1'; Expected = $true }
        @{ Line = 'powershell.exe /NONINTER -Command Get-Date'; Expected = $true }
        @{ Line = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File C:\Launcher\src\local-ai.ps1 update'; Expected = $false }
        @{ Line = 'powershell.exe -non -NoExit'; Expected = $false }
        @{ Line = '-noni.exe -NoProfile'; Expected = $false }
        @{ Line = 'powershell.exe -NoProfile -File C:\x-noninteractive\src\local-ai.ps1 start'; Expected = $false }
    ) {
        Invoke-ModuleFunction 'Test-LocalAINonInteractive' @{ CommandLine = @($Line -split ' ') } | Should -Be $Expected
    }

    It 'takes the switch after an en dash, an em dash or a horizontal bar, as powershell.exe does' {
        foreach ($code in 0x2013, 0x2014, 0x2015) {
            Invoke-ModuleFunction 'Test-LocalAINonInteractive' @{ CommandLine = @('powershell.exe', ([string][char]$code + 'NonInteractive')) } | Should -BeTrue
        }
    }

    It 'reads the command line of the powershell.exe it runs in, which here <Case>' -ForEach @(
        @{ Case = 'has -NonInteractive'; Switches = @('-NoProfile', '-NonInteractive'); Expected = $true }
        @{ Case = 'has none'; Switches = @('-NoProfile'); Expected = $false }
    ) {
        $module = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\LocalAI.psm1'
        $quoted = "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($module) + "'"
        # Without progress records, which powershell.exe writes to stderr as CLIXML while its output is redirected.
        $command = "`$ProgressPreference = 'SilentlyContinue'; Import-Module $quoted; & (Get-Module LocalAI) { Test-LocalAINonInteractive }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $said = @(& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @Switches -EncodedCommand $encoded)
        $said | Should -Be @([string]$Expected)
    }
}

Describe 'Git helpers for update' {
    BeforeAll {
        $pin = '483dae4326356b81de05d27aca3f433dd323cc25'
        $old = 'abcdef0123456789abcdef0123456789abcdef01'
        $repo = 'https://github.com/Comfy-Org/ComfyUI.git'
        $oldOrigin = 'https://github.com/comfyanonymous/ComfyUI.git'
    }

    BeforeEach {
        $dir = Join-Path $TestDrive 'ComfyUI'
        $git = Get-FakeGit -Head $old -Commit $pin
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' } -MockWith $fakeGit
        $settings = @{ ComfyUI = @{ Repo = $repo; Ref = 'v0.42.5'; Commit = $pin } }
        $state = { Invoke-ModuleFunction 'Get-GitCheckoutState' @{ Dir = $dir } }
        $move = { param([hashtable]$Before) Invoke-ModuleFunction 'Move-ComfyUICheckout' @{ Settings = $settings; Dir = $dir; Before = $Before } }
        $prompt = "$env:GIT_TERMINAL_PROMPT/$env:GCM_INTERACTIVE"
    }

    It 'reads HEAD, the branch, origin and the changed tracked files, leaving the index alone' {
        $git.Modified = @('comfyui_version.py', 'nodes.py')
        $found = & $state
        $found.Head | Should -Be $old
        $found.Branch | Should -Be 'refs/heads/master'
        $found.Origin | Should -Be $oldOrigin
        $found.Modified | Should -Be @('comfyui_version.py', 'nodes.py')
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -ceq "-C $dir --no-optional-locks status --porcelain --untracked-files=no"
        }
    }

    It 'reads a detached HEAD and a missing origin as $null, and a clean tree as no files' {
        $git.Branch = $null
        $git.Origin = $null
        $found = & $state
        $found.Branch | Should -BeNullOrEmpty
        $found.Origin | Should -BeNullOrEmpty
        @($found.Modified).Count | Should -Be 0
    }

    It "names the tag's commit with ls-remote and prompts off, preferring the peeled line of an annotated tag" {
        Invoke-ModuleFunction 'Get-GitRemoteTag' @{ Repo = $repo; Ref = 'v0.42.5' } | Should -Be $pin
        $git.Calls | Should -Contain "ls-remote $repo refs/tags/v0.42.5 refs/tags/v0.42.5^{}"
        $git.Prompts[-1] | Should -Be '0/Never'
        "$env:GIT_TERMINAL_PROMPT/$env:GCM_INTERACTIVE" | Should -Be $prompt
        $git.Peeled = $old
        Invoke-ModuleFunction 'Get-GitRemoteTag' @{ Repo = $repo; Ref = 'v0.42.5' } | Should -Be $old
    }

    It 'returns $null when the remote has no such tag' {
        $git.Commit = $null
        Invoke-ModuleFunction 'Get-GitRemoteTag' @{ Repo = $repo; Ref = 'v0.42.5' } | Should -BeNullOrEmpty
    }

    It "throws with git's text when the remote cannot be reached" {
        $git.Fail['ls-remote'] = @{ Code = 128; Lines = @("fatal: unable to access '$repo/': Could not resolve host: github.com") }
        { Invoke-ModuleFunction 'Get-GitRemoteTag' @{ Repo = $repo; Ref = 'v0.42.5' } } |
            Should -Throw -ExpectedMessage '*failed with exit code 128. git said: fatal: unable to access*Could not resolve host: github.com'
    }

    It 'sets origin to another URL, leaves a matching one alone, removes it for an empty URL and adds a missing one' {
        Invoke-ModuleFunction 'Set-GitOrigin' @{ Dir = $dir; Url = $repo }
        $git.Origin | Should -Be $repo
        $git.Calls | Should -Contain "remote set-url origin $repo"
        $git.Calls.Clear()
        Invoke-ModuleFunction 'Set-GitOrigin' @{ Dir = $dir; Url = $repo }
        @($git.Calls | Where-Object { $_ -like 'remote *' }).Count | Should -Be 0
        Invoke-ModuleFunction 'Set-GitOrigin' @{ Dir = $dir; Url = '' }
        $git.Origin | Should -BeNullOrEmpty
        $git.Calls | Should -Contain 'remote remove origin'
        Invoke-ModuleFunction 'Set-GitOrigin' @{ Dir = $dir; Url = $repo }
        $git.Calls | Should -Contain "remote add origin $repo"
        $git.Origin | Should -Be $repo
    }

    It 'fetches the tag by URL with prompts off, checks it out detached without overwriting ignored files, then points origin at Repo' {
        & $move (& $state)
        $git.Head | Should -Be $pin
        $git.Branch | Should -BeNullOrEmpty
        $git.Origin | Should -Be $repo
        @($git.Calls | Where-Object { $_ -match '^(fetch|checkout|remote) ' }) | Should -Be @(
            "fetch --depth 1 --no-tags $repo refs/tags/v0.42.5"
            "checkout --detach --no-overwrite-ignore $pin"
            "remote set-url origin $repo"
        )
        $git.Calls | Should -Contain 'rev-parse FETCH_HEAD^{commit}'
        $git.Prompts[$git.Calls.IndexOf("fetch --depth 1 --no-tags $repo refs/tags/v0.42.5")] | Should -Be '0/Never'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -ceq "-C $dir -c advice.detachedHead=false checkout --detach --no-overwrite-ignore $pin"
        }
    }

    It 'fetches the tag without --depth into a full clone, which stays full, and fetches nothing when the clone holds the commit' {
        $git.Shallow = $false
        & $move (& $state)
        $git.Head | Should -Be $pin
        $git.Calls | Should -Contain "fetch --no-tags $repo refs/tags/v0.42.5"
        @($git.Calls | Where-Object { $_ -like 'fetch --depth*' }).Count | Should -Be 0
        $git.Head = $old
        $git.Branch = 'refs/heads/master'
        $git.Origin = $oldOrigin
        $git.Objects = @($pin)
        $git.Calls.Clear()
        & $move (& $state)
        $git.Head | Should -Be $pin
        $git.Origin | Should -Be $repo
        @($git.Calls | Where-Object { $_ -like 'fetch*' -or $_ -like 'rev-parse FETCH_HEAD*' }).Count | Should -Be 0
        $git.Calls | Should -Contain "cat-file -e $pin^{commit}"
    }

    It 'leaves the checkout unchanged when the fetched tag is another commit' {
        $git.Peeled = 'f' * 40
        { & $move (& $state) } | Should -Throw -ExpectedMessage "v0.42.5 from $repo is commit $('f' * 40), not ComfyUI.Commit $pin, so the tag has moved and $dir is unchanged.*"
        $git.Head | Should -Be $old
        $git.Origin | Should -Be $oldOrigin
        @($git.Calls | Where-Object { $_ -like 'checkout*' -or $_ -like 'remote *' }).Count | Should -Be 0
    }

    It 'leaves the checkout unchanged when the fetch fails' {
        $git.Fail['fetch'] = @{ Code = 128; Lines = @("fatal: couldn't find remote ref refs/tags/v0.42.5") }
        { & $move (& $state) } | Should -Throw -ExpectedMessage "Cannot fetch v0.42.5 from $repo, so $dir is unchanged: *git said: fatal: couldn't find remote ref refs/tags/v0.42.5"
        @($git.Calls | Where-Object { $_ -like 'checkout*' -or $_ -like 'remote *' }).Count | Should -Be 0
    }

    It 'stays where it was when git refuses the checkout, as for an untracked file at a path the tag adds' {
        $git.Fail['checkout --detach --no-overwrite-ignore'] = @{ Code = 1
            Lines = @('error: The following untracked working tree files would be overwritten by checkout:', "`tapp/agent_host.py", 'Aborting') }
        { & $move (& $state) } |
            Should -Throw -ExpectedMessage "Cannot move $dir to v0.42.5: *untracked working tree files would be overwritten*app/agent_host.py* $dir is back at $old."
        $git.Head | Should -Be $old
        $git.Branch | Should -Be 'refs/heads/master'
        $git.Origin | Should -Be $oldOrigin
    }

    It 'moves HEAD back when origin cannot be changed' {
        $git.Fail['remote set-url'] = @{ Code = 255; Lines = @('error: could not lock config file .git/config: Permission denied') }
        { & $move (& $state) } | Should -Throw -ExpectedMessage "Cannot move $dir to v0.42.5: *could not lock config file*$dir is back at $old."
        $git.Head | Should -Be $old
        $git.Branch | Should -Be 'refs/heads/master'
    }

    It 'puts a detached HEAD back at its commit and removes the origin it did not have' {
        $git.Branch = $null
        $git.Origin = $null
        $before = & $state
        & $move $before
        $git.Origin | Should -Be $repo
        Invoke-ModuleFunction 'Restore-ComfyUICheckout' @{ Dir = $dir; Before = $before }
        $git.Head | Should -Be $old
        $git.Branch | Should -BeNullOrEmpty
        $git.Origin | Should -BeNullOrEmpty
        $git.Calls | Should -Contain "checkout --detach $old"
        $git.Calls | Should -Contain 'remote remove origin'
    }
}

Describe 'Move-ComfyUICheckout and Restore-ComfyUICheckout with git' {
    BeforeAll {
        # Run git with $Arguments and a test identity, and return its output lines; a non-zero exit code throws.
        function Invoke-TestGit([string[]]$Arguments) {
            $ErrorActionPreference = 'Continue'
            $output = @(& git -c user.name=Test -c user.email=test@example.invalid -c init.defaultBranch=master -c core.safecrlf=false @Arguments 2>&1 |
                    ForEach-Object { "$_" })
            if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
            return $output
        }

        # Write $Text to the file $Path, creating its folder.
        function Write-GitFile([string]$Path, [string]$Text) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
            [IO.File]::WriteAllText($Path, $Text)
        }
    }

    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $upstream = Join-Path $base 'upstream'
        $work = Join-Path $base 'ComfyUI'
        Write-GitFile (Join-Path $upstream 'main.py') "print('old')`n"
        Write-GitFile (Join-Path $upstream '.gitignore') "models/`n"
        $null = Invoke-TestGit @('-C', $upstream, 'init', '-q')
        $null = Invoke-TestGit @('-C', $upstream, 'add', '-A')
        $null = Invoke-TestGit @('-C', $upstream, 'commit', '-q', '-m', 'old')
        $oldCommit = @(Invoke-TestGit @('-C', $upstream, 'rev-parse', 'HEAD'))[-1]
        $url = ([uri]$upstream).AbsoluteUri
        $null = Invoke-TestGit @('clone', '-q', '--depth', '1', $url, $work)
        # The pinned tag comes later, on a branch of its own, as ComfyUI's releases do.
        $null = Invoke-TestGit @('-C', $upstream, 'checkout', '-q', '-b', 'release')
        Write-GitFile (Join-Path $upstream 'main.py') "print('new')`n"
        Write-GitFile (Join-Path $upstream 'app\agent_host.py') "pass`n"
        $null = Invoke-TestGit @('-C', $upstream, 'add', '-A')
        $null = Invoke-TestGit @('-C', $upstream, 'commit', '-q', '-m', 'new')
        $newCommit = @(Invoke-TestGit @('-C', $upstream, 'rev-parse', 'HEAD'))[-1]
        $null = Invoke-TestGit @('-C', $upstream, 'tag', 'v1')
        # The real checkout's origin names another URL than ComfyUI.Repo.
        $oldUrl = 'https://example.invalid/old/ComfyUI.git'
        $null = Invoke-TestGit @('-C', $work, 'remote', 'set-url', 'origin', $oldUrl)
        Write-GitFile (Join-Path $work 'notes.txt') 'mine'
        Write-GitFile (Join-Path $work 'models\x.bin') 'weights'
        $settings = @{ ComfyUI = @{ Repo = $url; Ref = 'v1'; Commit = $newCommit } }
        $state = { Invoke-ModuleFunction 'Get-GitCheckoutState' @{ Dir = $work } }
    }

    It 'moves a shallow clone to the tag in place, keeping untracked and ignored files, and puts it back without the remote' {
        $before = & $state
        $before.Head | Should -Be $oldCommit
        $before.Branch | Should -Be 'refs/heads/master'
        $before.Origin | Should -Be $oldUrl
        Invoke-ModuleFunction 'Move-ComfyUICheckout' @{ Settings = $settings; Dir = $work; Before = $before }
        $after = & $state
        $after.Head | Should -Be $newCommit
        $after.Branch | Should -BeNullOrEmpty
        $after.Origin | Should -Be $url
        @($after.Modified).Count | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $work 'main.py')).Trim() | Should -Be "print('new')"
        Test-Path -LiteralPath (Join-Path $work 'app\agent_host.py') | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $work 'notes.txt')) | Should -Be 'mine'
        [IO.File]::ReadAllText((Join-Path $work 'models\x.bin')) | Should -Be 'weights'
        # The previous commit stays in the clone, so the way back needs no remote.
        Remove-Item -LiteralPath $upstream -Recurse -Force
        Invoke-ModuleFunction 'Restore-ComfyUICheckout' @{ Dir = $work; Before = $before }
        $back = & $state
        $back.Head | Should -Be $oldCommit
        $back.Branch | Should -Be 'refs/heads/master'
        $back.Origin | Should -Be $oldUrl
        [IO.File]::ReadAllText((Join-Path $work 'main.py')).Trim() | Should -Be "print('old')"
        Test-Path -LiteralPath (Join-Path $work 'app\agent_host.py') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $work 'notes.txt')) | Should -Be 'mine'
        [IO.File]::ReadAllText((Join-Path $work 'models\x.bin')) | Should -Be 'weights'
    }

    It 'keeps a full clone full when it fetches the tag, and after the way back' {
        $full = Join-Path $base 'Full'
        $null = Invoke-TestGit @('clone', '-q', '--single-branch', '--branch', 'master', $url, $full)
        $null = Invoke-TestGit @('-C', $full, 'remote', 'set-url', 'origin', $oldUrl)
        $before = Invoke-ModuleFunction 'Get-GitCheckoutState' @{ Dir = $full }
        Invoke-ModuleFunction 'Move-ComfyUICheckout' @{ Settings = $settings; Dir = $full; Before = $before }
        @(Invoke-TestGit @('-C', $full, 'rev-parse', 'HEAD'))[-1] | Should -Be $newCommit
        @(Invoke-TestGit @('-C', $full, 'rev-parse', '--is-shallow-repository'))[-1] | Should -Be 'false'
        Invoke-ModuleFunction 'Restore-ComfyUICheckout' @{ Dir = $full; Before = $before }
        @(Invoke-TestGit @('-C', $full, 'rev-parse', 'HEAD'))[-1] | Should -Be $oldCommit
        @(Invoke-TestGit @('-C', $full, 'rev-parse', '--is-shallow-repository'))[-1] | Should -Be 'false'
    }

    It 'moves a clone that already holds the pinned commit without asking the remote' {
        $full = Join-Path $base 'Full'
        $null = Invoke-TestGit @('clone', '-q', $url, $full)
        $null = Invoke-TestGit @('-C', $full, 'checkout', '-q', 'master')
        $before = Invoke-ModuleFunction 'Get-GitCheckoutState' @{ Dir = $full }
        $before.Head | Should -Be $oldCommit
        Remove-Item -LiteralPath $upstream -Recurse -Force
        Invoke-ModuleFunction 'Move-ComfyUICheckout' @{ Settings = $settings; Dir = $full; Before = $before }
        @(Invoke-TestGit @('-C', $full, 'rev-parse', 'HEAD'))[-1] | Should -Be $newCommit
        @(Invoke-TestGit @('-C', $full, 'rev-parse', '--is-shallow-repository'))[-1] | Should -Be 'false'
    }

    It 'refuses to overwrite an ignored file at a path the tag adds, leaving the checkout as it was' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $work '.git\info')
        Add-Content -LiteralPath (Join-Path $work '.git\info\exclude') -Value 'app/'
        Write-GitFile (Join-Path $work 'app\agent_host.py') 'my own'
        $before = & $state
        { Invoke-ModuleFunction 'Move-ComfyUICheckout' @{ Settings = $settings; Dir = $work; Before = $before } } |
            Should -Throw -ExpectedMessage "Cannot move $work to v1: *agent_host.py*"
        $after = & $state
        $after.Head | Should -Be $oldCommit
        $after.Branch | Should -Be 'refs/heads/master'
        $after.Origin | Should -Be $oldUrl
        [IO.File]::ReadAllText((Join-Path $work 'app\agent_host.py')) | Should -Be 'my own'
    }
}

Describe 'Remove-LocalAITree and Measure-LocalAIPath' {
    BeforeEach {
        $leaf = [guid]::NewGuid().ToString('N')
        $tree = Join-Path $TestDrive "$leaf\tree"
        $null = Write-TestFile "$leaf\tree\a.txt" 'aaaa'
        $readOnly = Write-TestFile "$leaf\tree\sub\b.txt" 'bb'
        Set-ItemProperty -LiteralPath $readOnly -Name IsReadOnly -Value $true
        $kept = Write-TestFile "$leaf-outside\kept.txt" 'kept text'
        $link = Join-Path $tree 'linked'
        $null = New-Item -ItemType Junction -Path $link -Target (Split-Path $kept -Parent)
    }

    AfterEach {
        # Removes the link only, never what it leads to.
        if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link, $false) }
    }

    It 'counts the bytes below a folder without entering a junction in it, those of a file, and 0 for a missing path' {
        Invoke-ModuleFunction 'Measure-LocalAIPath' @{ Path = $tree } | Should -Be 6
        Invoke-ModuleFunction 'Measure-LocalAIPath' @{ Path = $readOnly } | Should -Be 2
        Invoke-ModuleFunction 'Measure-LocalAIPath' @{ Path = (Join-Path $tree 'none') } | Should -Be 0
    }

    It 'counts and deletes a tree whose paths pass 259 characters' {
        $deep = Join-Path $TestDrive "$leaf-long"
        $folder = '\\?\' + $deep
        foreach ($level in 1..4) { $folder += '\' + ('d{0:00}' -f $level) + ('x' * 70) }
        $null = [IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllText($folder + '\upload.txt', 'twelve bytes')
        ($folder.Length - 4) | Should -BeGreaterThan 259
        Invoke-ModuleFunction 'Measure-LocalAIPath' @{ Path = $deep } | Should -Be 12
        Invoke-ModuleFunction 'Measure-LocalAIPath' @{ Path = ($folder.Substring(4) + '\upload.txt') } | Should -Be 12
        Invoke-ModuleFunction 'Remove-LocalAITree' @{ Path = $deep }
        [IO.Directory]::Exists($deep) | Should -BeFalse
    }

    It 'deletes a folder with read-only files, removing a junction inside as a link and keeping what it leads to' {
        Invoke-ModuleFunction 'Remove-LocalAITree' @{ Path = $tree }
        Test-Path -LiteralPath $tree | Should -BeFalse
        [IO.File]::ReadAllText($kept) | Should -Be 'kept text'
    }

    It 'removes a junction given as the path itself as a link, and ignores a missing path' {
        Invoke-ModuleFunction 'Remove-LocalAITree' @{ Path = $link }
        Test-Path -LiteralPath $link | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tree 'a.txt') | Should -BeTrue
        [IO.File]::ReadAllText($kept) | Should -Be 'kept text'
        { Invoke-ModuleFunction 'Remove-LocalAITree' @{ Path = (Join-Path $tree 'none') } } | Should -Not -Throw
    }
}

Describe 'Open WebUI backups for update' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $dataDir = Join-Path $root 'open-webui'
        $backups = Join-Path $root 'local-ai\backups'
        $data = [ordered]@{
            'webui.db' = 'db'; 'webui.db-wal' = 'wal-rows'; 'webui.db-shm' = 'shm'; '.webui_secret_key' = 'key'; 'uploads\f_notes.txt' = 'upload'
            'vector_db\chroma.sqlite3' = 'vec'; 'vector_db\hnsw\data_level0.bin' = 'hnsw'; 'webui.log' = 'log'
        }
        foreach ($name in $data.Keys) { $null = Write-TestFile "$leaf\open-webui\$name" $data[$name] }
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'cache\audio\speech')
        $space = @{ Bytes = $null; Path = $null }
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith {
            $space.Bytes = $RequiredBytes
            $space.Path = $Path
        }
        # Return the files below $Folder as paths relative to it, in ordinal order.
        $list = {
            param([string]$Folder)
            $names = [string[]]@(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Folder.Length + 1) })
            [Array]::Sort($names, [StringComparer]::Ordinal)
            $names
        }
        $backup = { Invoke-ModuleFunction 'New-OpenWebUIBackup' @{ DataDir = $dataDir; BackupRoot = $backups; Version = '0.12.3'; Python = '3.11.17' } }
        # Mark the folder $Name below $backups as one update made.
        $mark = { param([string]$Name) Write-LocalAIState -Path (Join-Path $backups "$Name\local-ai-backup.json") -State @{ Kind = 'open-webui-update' } }
    }

    It 'copies webui.db with its WAL and SHM, the key, uploads and vector_db after a free-space check for their bytes, and marks the folder' {
        $folder = & $backup
        Split-Path $folder -Parent | Should -Be $backups
        Split-Path $folder -Leaf | Should -Match '^open-webui-\d{8}-\d{6}\z'
        @(& $list $folder) | Should -Be @('.webui_secret_key', 'local-ai-backup.json', 'uploads\f_notes.txt', 'vector_db\chroma.sqlite3', 'vector_db\hnsw\data_level0.bin',
            'webui.db', 'webui.db-shm', 'webui.db-wal')
        [IO.File]::ReadAllText((Join-Path $folder 'webui.db-wal')) | Should -Be 'wal-rows'
        $space.Path | Should -Be $backups
        $space.Bytes | Should -Be 29
        $marker = Read-LocalAIState -Path (Join-Path $folder 'local-ai-backup.json')
        $marker.Kind | Should -Be 'open-webui-update'
        $marker.Version | Should -Be '0.12.3'
        $marker.Python | Should -Be '3.11.17'
        $marker.DataDir | Should -Be $dataDir
    }

    It 'makes a marked backup holding the key alone when there is no webui.db yet' {
        foreach ($name in 'webui.db', 'webui.db-wal', 'webui.db-shm', 'uploads', 'vector_db') { Remove-Item -LiteralPath (Join-Path $dataDir $name) -Recurse -Force }
        $folder = & $backup
        @(& $list $folder) | Should -Be @('.webui_secret_key', 'local-ai-backup.json')
    }

    It 'copies nothing when the free-space check fails' {
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith { throw 'Drive C: has 0.0 GB free' }
        { & $backup } | Should -Throw -ExpectedMessage '*Drive C: has 0.0 GB free*'
        @(Get-ChildItem -LiteralPath $backups -Force).Count | Should -Be 0
    }

    It 'deletes only the backups update made beyond Keep, oldest first, and returns them' {
        foreach ($name in 'open-webui-20260101-000000', 'open-webui-20260201-000000', 'open-webui-20260301-000000', 'open-webui-failed-20260210-000000') { & $mark $name }
        $null = Write-TestFile "$leaf\local-ai\backups\open-webui-20260115-000000\webui.db" 'install made it'
        $null = Write-TestFile "$leaf\local-ai\backups\notes\a.txt" 'mine'
        $removed = @(Invoke-ModuleFunction 'Remove-OldOpenWebUIBackup' @{ BackupRoot = $backups; Keep = 2 })
        $removed | Should -Be @((Join-Path $backups 'open-webui-20260101-000000'))
        $left = [string[]]@(Get-ChildItem -LiteralPath $backups -Directory | ForEach-Object { $_.Name })
        [Array]::Sort($left, [StringComparer]::Ordinal)
        $left | Should -Be @('notes', 'open-webui-20260115-000000', 'open-webui-20260201-000000', 'open-webui-20260301-000000', 'open-webui-failed-20260210-000000')
    }

    It 'never deletes the backup just made, and orders the others by the time their marker records, not by name' {
        # The newest by its marker, though its name sorts first, as after the clock was set back.
        $made = [DateTime]::UtcNow.Ticks
        Write-LocalAIState -Path (Join-Path $backups 'open-webui-20260301-000000\local-ai-backup.json') -State @{ Kind = 'open-webui-update'; CreatedTicks = $made - 3000 }
        Write-LocalAIState -Path (Join-Path $backups 'open-webui-20260201-000000\local-ai-backup.json') -State @{ Kind = 'open-webui-update'; CreatedTicks = $made - 1000 }
        Write-LocalAIState -Path (Join-Path $backups 'open-webui-20260101-000000\local-ai-backup.json') -State @{ Kind = 'open-webui-update'; CreatedTicks = $made }
        $current = Join-Path $backups 'open-webui-20260101-000000'
        $removed = @(Invoke-ModuleFunction 'Remove-OldOpenWebUIBackup' @{ BackupRoot = $backups; Keep = 1; Current = $current })
        @($removed | Sort-Object) | Should -Be @((Join-Path $backups 'open-webui-20260201-000000'), (Join-Path $backups 'open-webui-20260301-000000'))
        Test-Path -LiteralPath $current | Should -BeTrue
        Write-LocalAIState -Path (Join-Path $backups 'open-webui-20261001-000000\local-ai-backup.json') -State @{ Kind = 'open-webui-update'; CreatedTicks = $made - 5000 }
        @(Invoke-ModuleFunction 'Remove-OldOpenWebUIBackup' @{ BackupRoot = $backups; Keep = 2; Current = $current }).Count | Should -Be 0
        @(Invoke-ModuleFunction 'Remove-OldOpenWebUIBackup' @{ BackupRoot = $backups; Keep = 1; Current = $current }) | Should -Be @((Join-Path $backups 'open-webui-20261001-000000'))
        Test-Path -LiteralPath $current | Should -BeTrue
    }

    It 'stops before Open WebUI changes when a folder cannot be copied, naming a path too long for Windows PowerShell 5.1' {
        # Pester 6 runs no real command when a filter does not match, so the file copies go through a default mock.
        Mock Copy-Item -ModuleName LocalAI -MockWith { Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop }
        Mock Copy-Item -ModuleName LocalAI -ParameterFilter { $Recurse } -MockWith { throw (New-Object IO.PathTooLongException 'The specified path, file name, or both are too long.') }
        { & $backup } | Should -Throw -ExpectedMessage ("Cannot back up $(Join-Path $dataDir 'uploads') to *: The specified path, file name, or both are too long. A file below it may " +
            'have a path longer than the 259 characters Windows PowerShell 5.1 copies; shorten or move that file. Open WebUI was not changed, and the incomplete backup has no local-ai-backup.json.')
        @(Get-ChildItem -LiteralPath $backups -Recurse -Filter 'local-ai-backup.json').Count | Should -Be 0
    }

    It 'warns and goes on when an old backup cannot be deleted, and does nothing without a backup folder' {
        foreach ($name in 'open-webui-20260101-000000', 'open-webui-20260201-000000') { & $mark $name }
        Mock Remove-LocalAITree -ModuleName LocalAI -MockWith { throw 'Access is denied.' }
        $output = @(Invoke-ModuleFunction 'Remove-OldOpenWebUIBackup' @{ BackupRoot = $backups; Keep = 1 } 3>&1)
        @($output | Where-Object { $_ -is [string] }).Count | Should -Be 0
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) |
            Should -Be @("Could not delete the old Open WebUI backup $(Join-Path $backups 'open-webui-20260101-000000'): Access is denied.")
        @(Invoke-ModuleFunction 'Remove-OldOpenWebUIBackup' @{ BackupRoot = (Join-Path $root 'none'); Keep = 1 }).Count | Should -Be 0
    }

    It 'puts the backup back as one set, moving the failed data aside whole, without the marker and the package list' {
        $folder = & $backup
        [IO.File]::WriteAllText((Join-Path $folder 'open-webui-packages.txt'), "open-webui==0.12.3`n")
        # What the failed version did to the data.
        [IO.File]::WriteAllText((Join-Path $dataDir 'webui.db'), 'db-new')
        [IO.File]::WriteAllText((Join-Path $dataDir 'webui.db-wal'), 'wal-new')
        [IO.File]::WriteAllText((Join-Path $dataDir 'uploads\g_new.txt'), 'new upload')
        Remove-Item -LiteralPath (Join-Path $dataDir 'vector_db\hnsw\data_level0.bin')
        $aside = Invoke-ModuleFunction 'Restore-OpenWebUIData' @{ DataDir = $dataDir; Backup = $folder; BackupRoot = $backups }
        Split-Path $aside -Parent | Should -Be $backups
        Split-Path $aside -Leaf | Should -Match '^open-webui-failed-\d{8}-\d{6}\z'
        @(& $list $aside) | Should -Be @('.webui_secret_key', 'uploads\f_notes.txt', 'uploads\g_new.txt', 'vector_db\chroma.sqlite3', 'webui.db', 'webui.db-shm',
            'webui.db-wal', 'webui.log')
        [IO.File]::ReadAllText((Join-Path $aside 'webui.db')) | Should -Be 'db-new'
        @(& $list $dataDir) | Should -Be @('.webui_secret_key', 'uploads\f_notes.txt', 'vector_db\chroma.sqlite3', 'vector_db\hnsw\data_level0.bin', 'webui.db',
            'webui.db-shm', 'webui.db-wal')
        [IO.File]::ReadAllText((Join-Path $dataDir 'webui.db')) | Should -Be 'db'
        [IO.File]::ReadAllText((Join-Path $dataDir 'webui.db-wal')) | Should -Be 'wal-rows'
        Test-Path -LiteralPath $folder | Should -BeTrue
    }

    It 'copies the backup into a data folder that is gone, returning $null, and refuses a backup that does not exist' {
        $folder = & $backup
        { Invoke-ModuleFunction 'Restore-OpenWebUIData' @{ DataDir = $dataDir; Backup = (Join-Path $backups 'none'); BackupRoot = $backups } } |
            Should -Throw -ExpectedMessage "The backup $(Join-Path $backups 'none') does not exist."
        [IO.File]::ReadAllText((Join-Path $dataDir 'webui.db')) | Should -Be 'db'
        Remove-Item -LiteralPath $dataDir -Recurse -Force
        Invoke-ModuleFunction 'Restore-OpenWebUIData' @{ DataDir = $dataDir; Backup = $folder; BackupRoot = $backups } | Should -BeNullOrEmpty
        [IO.File]::ReadAllText((Join-Path $dataDir 'webui.db-wal')) | Should -Be 'wal-rows'
    }
}

Describe 'Save-UvFreeze and Restore-OpenWebUITool' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $list = Join-Path $root 'open-webui-packages.txt'
        $uv = @{
            Freeze       = @('Using Python 3.11.17 environment at: C:\uv\tools\open-webui', 'aiohttp==3.13.2', 'open-webui==0.12.3', 'torch==2.14.1', '')
            FailWithList = $false
            Installs     = New-Object System.Collections.Generic.List[string]
        }
        # Any call the filters below miss throws, so a changed argument order never reaches the real uv and its tool folder.
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[0] -eq 'pip' } -MockWith {
            foreach ($line in $uv.Freeze) { $Capture.Add($line) }
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[1] -eq 'install' } -MockWith {
            $uv.Installs.Add($ArgumentList -join ' ')
            if ($uv.FailWithList -and $ArgumentList -contains '-c') { throw "'uv tool install' failed with exit code 1." }
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uv' -and $ArgumentList[1] -eq 'list' } -MockWith {
            $Capture.Add('open-webui v0.12.3 [CPython 3.11.17] (C:\uv\tools\open-webui)')
            $Capture.Add('- open-webui (C:\uv\bin\open-webui.exe)')
            0
        }
        $restore = { param([string]$Constraints) Invoke-ModuleFunction 'Restore-OpenWebUITool' @{ Version = '0.12.3'; Python = '3.11.17'; Constraints = $Constraints } }
    }

    It "writes the name==version lines 'uv pip freeze' prints and returns how many" {
        Invoke-ModuleFunction 'Save-UvFreeze' @{ Python = 'C:\uv\tools\open-webui\Scripts\python.exe'; Path = $list } | Should -Be 3
        [IO.File]::ReadAllLines($list) | Should -Be @('aiohttp==3.13.2', 'open-webui==0.12.3', 'torch==2.14.1')
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'pip freeze --python C:\uv\tools\open-webui\Scripts\python.exe' -and $null -ne $Capture
        }
    }

    It 'throws, writing nothing, when uv lists no packages' {
        $uv.Freeze = @('Using Python 3.11.17 environment at: C:\uv\tools\open-webui')
        { Invoke-ModuleFunction 'Save-UvFreeze' @{ Python = 'C:\py.exe'; Path = $list } } | Should -Throw -ExpectedMessage "'uv pip freeze --python C:\py.exe' listed no packages."
        Test-Path -LiteralPath $list | Should -BeFalse
    }

    It 'reinstalls the old version under the saved list, which uv takes with -c' {
        [IO.File]::WriteAllText($list, "open-webui==0.12.3`n")
        $tool = & $restore $list
        $tool.Version | Should -Be '0.12.3'
        $tool.Path | Should -Be 'C:\uv\bin\open-webui.exe'
        @($uv.Installs) | Should -Be @("tool install --python 3.11.17 open-webui==0.12.3 -c $list --reinstall")
    }

    It 'resolves the old version as of the cut-off it was installed with, under the list and without it' {
        [IO.File]::WriteAllText($list, "open-webui==0.12.3`n")
        $uv.FailWithList = $true
        $null = Invoke-ModuleFunction 'Restore-OpenWebUITool' @{ Version = '0.12.3'; Python = '3.11.17'; Constraints = $list; ExcludeNewer = '2026-10-01T00:00:00Z' } 6>$null
        @($uv.Installs) | Should -Be @("tool install --python 3.11.17 open-webui==0.12.3 --exclude-newer 2026-10-01T00:00:00Z -c $list --reinstall",
            'tool install --python 3.11.17 open-webui==0.12.3 --exclude-newer 2026-10-01T00:00:00Z --reinstall')
    }

    It 'tries again without the list when the install under it fails, and installs without one when there is none' {
        [IO.File]::WriteAllText($list, "open-webui==0.12.3`n")
        $uv.FailWithList = $true
        $printed = @(& $restore $list 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join "`n"
        @($uv.Installs) | Should -Be @("tool install --python 3.11.17 open-webui==0.12.3 -c $list --reinstall", 'tool install --python 3.11.17 open-webui==0.12.3 --reinstall')
        $printed | Should -BeLike '*with its saved package list failed*trying without it*'
        $uv.Installs.Clear()
        $null = & $restore (Join-Path $root 'missing.txt')
        @($uv.Installs) | Should -Be @('tool install --python 3.11.17 open-webui==0.12.3 --reinstall')
    }
}

Describe 'Get-OpenWebUIUpdatePlan' {
    BeforeEach {
        $settings = @{ OpenWebUI = @{ Version = '0.12.4'; Python = '3.12'; ExcludeNewer = '2026-10-25T08:10:00Z' } }
        $uv = @{ Tool = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' } }
        $stamp = @{ OpenWebUI = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe'; ExcludeNewer = '2026-10-25T08:10:00Z' } }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Get-UvTool -ModuleName LocalAI -ParameterFilter { $Name -eq 'open-webui' } -MockWith { $uv.Tool }
        $plan = { Invoke-ModuleFunction 'Get-OpenWebUIUpdatePlan' @{ Settings = $settings; Stamp = $stamp } }
    }

    It 'plans a reinstall from the version and Python uv lists to the pins' {
        $result = & $plan
        $result.Reinstall | Should -BeTrue
        $result.Problem | Should -BeNullOrEmpty
        @($result.Changes) | Should -Be @('0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12, after a backup of its data')
        $result.Tool.Path | Should -Be 'C:\uv\bin\open-webui.exe'
    }

    It 'plans a reinstall when only the Python minor differs' {
        $uv.Tool = @{ Version = '0.12.4'; Python = '3.11.18'; Path = 'C:\uv\bin\open-webui.exe' }
        (& $plan).Reinstall | Should -BeTrue
    }

    It 'plans nothing when uv lists the pin on a patch of the pinned minor, as install-stamp.json records it' {
        $uv.Tool = @{ Version = '0.12.4'; Python = '3.12.16'; Path = 'C:\uv\bin\open-webui.exe' }
        $stamp.OpenWebUI = $uv.Tool.Clone()
        $stamp.OpenWebUI.ExcludeNewer = '2026-10-25T08:10:00Z'
        $result = & $plan
        $result.Reinstall | Should -BeFalse
        @($result.Changes).Count | Should -Be 0
    }

    It 'plans a reinstall of the same version when install-stamp.json records <Case>' -ForEach @(
        @{ Case = 'another cut-off'; Recorded = '2026-10-01T00:00:00Z'; Pin = '2026-10-25T08:10:00Z'; Text = 'resolved as of 2026-10-01T00:00:00Z -> resolved as of 2026-10-25T08:10:00Z' }
        @{ Case = 'no cut-off, as installs before 1.2.0'; Recorded = $null; Pin = '2026-10-25T08:10:00Z'; Text = 'resolved at an unrecorded time -> resolved as of 2026-10-25T08:10:00Z' }
        @{ Case = 'a cut-off that settings.psd1 lifts'; Recorded = '2026-10-01T00:00:00Z'; Pin = ''; Text = 'resolved as of 2026-10-01T00:00:00Z -> resolved as uv picks them that day' }
    ) {
        $uv.Tool = @{ Version = '0.12.4'; Python = '3.12.16'; Path = 'C:\uv\bin\open-webui.exe' }
        $stamp.OpenWebUI = $uv.Tool.Clone()
        if ($null -ne $Recorded) { $stamp.OpenWebUI.ExcludeNewer = $Recorded }
        $settings.OpenWebUI.ExcludeNewer = $Pin
        $result = & $plan
        $result.Reinstall | Should -BeTrue
        @($result.Changes) | Should -Be @("0.12.4 on Python 3.12.16: packages $Text, after a backup of its data")
    }

    It 'plans nothing when settings.psd1 lifts the cut-off and install-stamp.json records none' {
        $uv.Tool = @{ Version = '0.12.4'; Python = '3.12.16'; Path = 'C:\uv\bin\open-webui.exe' }
        $stamp.OpenWebUI = $uv.Tool.Clone()
        $settings.OpenWebUI.ExcludeNewer = ''
        $result = & $plan
        $result.Reinstall | Should -BeFalse
        @($result.Changes).Count | Should -Be 0
    }

    It 'plans only a new record when install-stamp.json records another install than uv lists' {
        $uv.Tool = @{ Version = '0.12.4'; Python = '3.12.16'; Path = 'C:\uv\bin\open-webui.exe' }
        $result = & $plan
        $result.Reinstall | Should -BeFalse
        @($result.Changes) | Should -Be @('install-stamp.json records 0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12.16, as uv lists it')
    }

    It 'cannot update an Open WebUI that uv does not list with an entry point (<Case>)' -ForEach @(
        @{ Case = 'no tool'; Path = $false }
        @{ Case = 'no entry point'; Path = $true }
    ) {
        $uv.Tool = if ($Path) { @{ Version = '0.12.3'; Python = '3.11.17'; Path = $null } } else { $null }
        (& $plan).Problem | Should -BeLike "uv lists no open-webui tool with an entry point*Run 'local-ai install'*"
    }
}

Describe 'Get-ComfyUIUpdatePlan' {
    BeforeAll {
        $pin = '483dae4326356b81de05d27aca3f433dd323cc25'
        $old = 'abcdef0123456789abcdef0123456789abcdef01'
        $repo = 'https://github.com/Comfy-Org/ComfyUI.git'
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $dir = Join-Path $root 'ComfyUI'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir '.git')
        $requirements = Write-TestFile "$leaf\ComfyUI\requirements.txt" "torch`ntorchvision`n"
        $constraints = Write-TestFile "$leaf\constraints.txt" "torch==2.14.1`ntorchvision==0.29.1`n"
        $settings = @{ ComfyUI = @{ Dir = $dir; Repo = $repo; Ref = 'v0.42.5'; Commit = $pin; TorchBackend = 'cu130'; ExcludeNewer = '2026-10-23T00:07:14Z'; Constraints = $constraints } }
        $python = Join-Path $dir '.venv\Scripts\python.exe'
        $stamp = @{ ComfyUI = @{ Dir = $dir; Commit = $old; Ref = $null; Python = $python } }
        $git = Get-FakeGit -Head $old -Commit $pin
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' } -MockWith $fakeGit
        $plan = { Invoke-ModuleFunction 'Get-ComfyUIUpdatePlan' @{ Settings = $settings; Stamp = $stamp; RepoRoot = $TestDrive } }
        # Write the marker install leaves in the venv, for the requirements and constraints at hand, with the fields in $Change replaced.
        $writeMarker = {
            param([hashtable]$Change = @{})
            $marker = @{
                RequirementsSha256 = (Get-FileHash -LiteralPath $requirements -Algorithm SHA256).Hash.ToLowerInvariant()
                ConstraintsSha256  = (Get-FileHash -LiteralPath $constraints -Algorithm SHA256).Hash.ToLowerInvariant()
                Backend = 'cu130'; ExcludeNewer = '2026-10-23T00:07:14Z'; Torch = '2.14.1+cu130'
            }
            foreach ($key in $Change.Keys) { $marker[$key] = $Change[$key] }
            Write-LocalAIState -Path (Join-Path $dir '.venv\local-ai-install.json') -State $marker
        }
    }

    It 'plans the move to the tag, the origin and the venv when the remote tag is the pin, changing nothing yet' {
        $result = & $plan
        $result.Migrate | Should -BeTrue
        $result.Problem | Should -BeNullOrEmpty
        $result.Dir | Should -Be $dir
        $result.Checkout.Head | Should -Be $old
        @($result.Changes) | Should -Be @(
            "commit $old (branch master) -> v0.42.5 ($pin), moved in place; models, output, input, user, custom_nodes and .venv stay"
            "origin https://github.com/comfyanonymous/ComfyUI.git -> $repo"
            'venv: the requirements of v0.42.5, installed by uv as install does'
        )
        $git.Calls | Should -Contain "ls-remote $repo refs/tags/v0.42.5 refs/tags/v0.42.5^{}"
        @($git.Calls | Where-Object { $_ -match '^(fetch|checkout|remote) ' }).Count | Should -Be 0
    }

    It 'refuses the move while tracked files are changed, listing ten of them, without asking the remote' {
        $git.Modified = @(1..12 | ForEach-Object { "file$_.py" })
        $result = & $plan
        $result.Problem | Should -BeLike ("$dir has changes to tracked files, which moving it to v0.42.5 would overwrite or carry along: file1.py, file2.py, *, file10.py and 2 more. " +
            "Undo them, or keep them with 'git -C `"$dir`" stash', then run update again.")
        @($git.Calls | Where-Object { $_ -like 'ls-remote*' }).Count | Should -Be 0
    }

    It 'refuses the move when the remote tag <Case>' -ForEach @(
        @{ Case = 'names another commit'; Kind = 'moved' }
        @{ Case = 'is missing'; Kind = 'missing' }
        @{ Case = 'cannot be read'; Kind = 'unreachable' }
    ) {
        switch ($Kind) {
            'moved' {
                $git.Commit = 'f' * 40
                $message = "The tag v0.42.5 at $repo names commit $('f' * 40), not ComfyUI.Commit $pin, so the tag has moved.*"
            }
            'missing' {
                $git.Commit = $null
                $message = "$repo has no tag v0.42.5.*"
            }
            'unreachable' {
                $git.Fail['ls-remote'] = @{ Code = 128; Lines = @('fatal: unable to access: Could not resolve host: github.com') }
                $message = "Cannot check the tag v0.42.5 at ${repo}: *Could not resolve host: github.com"
            }
        }
        (& $plan).Problem | Should -BeLike $message
    }

    It 'plans only the origin when HEAD is the pin and the venv and the record match' {
        $git.Head = $pin
        $stamp.ComfyUI = @{ Dir = $dir; Commit = $pin; Ref = 'v0.42.5'; Python = $python }
        & $writeMarker
        $result = & $plan
        $result.Migrate | Should -BeFalse
        @($result.Changes) | Should -Be @("origin https://github.com/comfyanonymous/ComfyUI.git -> $repo")
        @($git.Calls | Where-Object { $_ -like 'ls-remote*' }).Count | Should -Be 0
    }

    It 'plans nothing when ComfyUI is at its pins' {
        $git.Head = $pin
        $git.Origin = $repo
        $stamp.ComfyUI = @{ Dir = $dir; Commit = $pin; Ref = 'v0.42.5'; Python = $python }
        & $writeMarker
        $result = & $plan
        @($result.Changes).Count | Should -Be 0
        $result.Rebuild | Should -BeFalse
    }

    It 'plans a new venv for a venv on the Microsoft Store Python, at the pin and with the move to the tag alike' {
        $settings.ComfyUI.Python = '3.13'
        Write-TestPyVenvConfig -Venv (Join-Path $dir '.venv') -BaseHome $storeHome -Version '3.13.14'
        $change = 'venv on the Microsoft Store Python 3.13.14, whose launches can fail or hang until Windows restarts -> a new venv on a uv-managed Python 3.13'
        $git.Head = $pin
        $git.Origin = $repo
        $stamp.ComfyUI = @{ Dir = $dir; Commit = $pin; Ref = 'v0.42.5'; Python = $python }
        & $writeMarker
        $result = & $plan
        $result.Rebuild | Should -BeTrue
        $result.Migrate | Should -BeFalse
        @($result.Changes) | Should -Be @($change)
        $git.Head = $old
        $moving = & $plan
        $moving.Migrate | Should -BeTrue
        $moving.Rebuild | Should -BeTrue
        @($moving.Changes) | Should -Contain $change
        @($moving.Changes) | Should -Contain 'venv: the requirements of v0.42.5, installed by uv as install does'
    }

    It 'plans the venv when its marker records other requirements, and torch when it is not the constrained version' {
        $git.Head = $pin
        $git.Origin = $repo
        $stamp.ComfyUI = @{ Dir = $dir; Commit = $pin; Ref = 'v0.42.5'; Python = $python }
        & $writeMarker @{ RequirementsSha256 = 'a' * 64; Torch = '2.13.0+cu130' }
        @((& $plan).Changes) | Should -Be @(
            'venv set up for another RequirementsSha256 -> requirements.txt, the constraints, cu130 and 2026-10-23T00:07:14Z'
            'torch 2.13.0+cu130 -> 2.14.1'
        )
    }

    It 'plans an origin for a checkout without one, and every venv field for a venv without a marker' {
        $git.Head = $pin
        $git.Origin = $null
        $stamp.ComfyUI = @{ Dir = $dir; Commit = $pin; Ref = 'v0.42.5'; Python = $python }
        @((& $plan).Changes) | Should -Be @(
            "origin none -> $repo"
            'venv set up for another RequirementsSha256, ConstraintsSha256, Backend, ExcludeNewer -> requirements.txt, the constraints, cu130 and 2026-10-23T00:07:14Z'
        )
    }

    It 'plans a new record when install-stamp.json records another commit than HEAD' {
        $git.Head = $pin
        $git.Origin = $repo
        & $writeMarker
        @((& $plan).Changes) | Should -Be @("install-stamp.json records commit $old -> $pin (v0.42.5)")
    }

    It 'leaves ComfyUI out with a note, running no git, when <Case>' -ForEach @(
        @{ Case = 'install has not set it up'; Kind = 'none' }
        @{ Case = 'uninstall removed its venv'; Kind = 'novenv' }
        @{ Case = 'install set it up in another folder'; Kind = 'elsewhere' }
        @{ Case = 'the folder is no git checkout'; Kind = 'nogit' }
    ) {
        switch ($Kind) {
            'none' {
                $stamp.Remove('ComfyUI')
                $message = 'install has not set up ComfyUI, so update leaves it out.*'
            }
            'novenv' {
                $stamp.ComfyUI = @{ Dir = $dir; Cloned = $true }
                $message = 'install has not set up ComfyUI, so update leaves it out.*'
            }
            'elsewhere' {
                $stamp.ComfyUI.Dir = 'D:\ComfyUI'
                $message = "install set up ComfyUI in 'D:\ComfyUI', but ComfyUI.Dir is '$dir'*"
            }
            'nogit' {
                Remove-Item -LiteralPath (Join-Path $dir '.git')
                $message = "$dir is no git checkout*"
            }
        }
        $result = & $plan
        $result.Note | Should -BeLike $message
        @($result.Changes).Count | Should -Be 0
        $git.Calls.Count | Should -Be 0
    }
}

Describe 'Get-FilesUpdatePlan' {
    BeforeEach {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Files.Root = 'C:\AI-Files'
        $lockSha = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'config\files-server\package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $stamp = @{ Files = @{ McpoVersion = '0.0.20'; Python = '3.12'; With = @('mcp==1.30.0', 'fastapi<0.145'); ExcludeNewer = '2026-10-13T00:00:00Z'
                ServerVersion = $settings.Files.ServerVersion; LockSha256 = $lockSha } }
        $uv = @{ Tool = @{ Version = '0.0.20'; Python = '3.12.16'; Path = 'C:\uv\bin\mcpo.exe' } }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Get-UvTool -ModuleName LocalAI -ParameterFilter { $Name -eq 'mcpo' } -MockWith { $uv.Tool }
        $plan = { Invoke-ModuleFunction 'Get-FilesUpdatePlan' @{ Settings = $settings; Stamp = $stamp; RepoRoot = $repoRoot } }
    }

    It 'plans nothing when mcpo and the files server are at their pins' {
        @((& $plan).Changes).Count | Should -Be 0
    }

    It 'plans each mcpo pin that install-stamp.json records otherwise' {
        $stamp.Files.With = @('mcp<2')
        $stamp.Files.Python = '3.11'
        @((& $plan).Changes) | Should -Be @("mcpo Files.McpoWith 'mcp<2' -> 'mcp==1.30.0 fastapi<0.145'", "mcpo Files.Python '3.11' -> '3.12'")
    }

    It 'plans <Case>' -ForEach @(
        @{ Case = 'another mcpo than uv lists'; Kind = 'version' }
        @{ Case = 'mcpo when uv lists none'; Kind = 'none' }
        @{ Case = 'the files server and its lockfile'; Kind = 'server' }
    ) {
        switch ($Kind) {
            'version' {
                $uv.Tool = @{ Version = '0.0.19'; Python = '3.12.16'; Path = 'C:\uv\bin\mcpo.exe' }
                $expected = @('mcpo 0.0.19 on Python 3.12.16 -> 0.0.20 on Python 3.12')
            }
            'none' {
                $uv.Tool = $null
                $expected = @("mcpo: none in uv's list -> 0.0.20")
            }
            'server' {
                $stamp.Files.ServerVersion = '2.0.0'
                $stamp.Files.LockSha256 = 'b' * 64
                $expected = @("files server 2.0.0 -> $($settings.Files.ServerVersion)", "files server lockfile $('b' * 64) -> $lockSha")
            }
        }
        @((& $plan).Changes) | Should -Be $expected
    }

    It 'leaves the file tools out with a note when install has not set them up' {
        $stamp.Remove('Files')
        $result = & $plan
        $result.Note | Should -BeLike 'install has not set up the file tools, so update leaves them out.*'
        Should -Invoke Get-UvTool -ModuleName LocalAI -Times 0 -Exactly
    }
}

Describe 'Get-ModelUpdatePlan' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $paths = Get-LocalAIPaths -Root (Join-Path $root 'local-ai')
        $modelfile = Write-TestFile "$leaf\local-chat.Modelfile" "FROM hf.co/Org/Chat:Q6_K`n"
        $sha = (Get-FileHash -LiteralPath $modelfile -Algorithm SHA256).Hash.ToLowerInvariant()
        $settings = @{ Model = @{ Alias = 'local-chat'; Source = 'hf.co/Org/Chat:Q6_K'; Sha256 = 'a' * 64; ProjectorSha256 = 'b' * 64; Modelfile = $modelfile } }
        $stamp = @{ Model = @{ Alias = 'local-chat'; BaseDigest = 'a' * 64; ProjectorDigest = 'b' * 64; ModelfileSha256 = $sha } }
        $ollama = @{ Blobs = @([pscustomobject]@{ Digest = 'a' * 64; Path = 'C:\m\a' }, [pscustomobject]@{ Digest = 'b' * 64; Path = 'C:\m\b' }) }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Get-OllamaModelBlob -ModuleName LocalAI -MockWith { $ollama.Blobs }
        $plan = { Invoke-ModuleFunction 'Get-ModelUpdatePlan' @{ Settings = $settings; Paths = $paths; Stamp = $stamp; RepoRoot = $TestDrive } }
    }

    It 'plans nothing when the alias, its blobs and the Modelfile match, asking Ollama about the alias' {
        @((& $plan).Changes).Count | Should -Be 0
        Should -Invoke Get-OllamaModelBlob -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'local-chat' }
    }

    It 'plans every pin that install-stamp.json records otherwise' {
        $stamp.Model = @{ Alias = 'old-chat'; BaseDigest = 'c' * 64; ProjectorDigest = 'd' * 64; ModelfileSha256 = 'e' * 64 }
        @((& $plan).Changes) | Should -Be @(
            'alias old-chat -> local-chat'
            "weights $('c' * 64) -> $('a' * 64), pulled from hf.co/Org/Chat:Q6_K unless Ollama holds them"
            "vision projector $('d' * 64) -> $('b' * 64)"
            "Modelfile $('e' * 64) -> $sha ($modelfile)"
        )
    }

    It 'plans the alias when Ollama lacks it or builds it on other blobs' {
        $ollama.Blobs = @()
        @((& $plan).Changes) | Should -Be @("local-chat: none in Ollama -> created from $modelfile")
        $ollama.Blobs = @([pscustomobject]@{ Digest = 'c' * 64; Path = 'C:\m\c' }, [pscustomobject]@{ Digest = 'b' * 64; Path = 'C:\m\b' })
        @((& $plan).Changes) | Should -Be @("local-chat on the blobs $('c' * 64), $('b' * 64) -> on the pinned ones")
    }

    It "judges the Modelfile in the launcher's folder when there is one" {
        $own = Write-TestFile "$leaf\local-ai\local-chat.Modelfile" "FROM hf.co/Org/Chat:Q6_K`nPARAMETER num_ctx 8192`n"
        $ownSha = (Get-FileHash -LiteralPath $own -Algorithm SHA256).Hash.ToLowerInvariant()
        @((& $plan).Changes) | Should -Be @("Modelfile $sha -> $ownSha ($own)")
    }
}

Describe 'Get-CheckpointUpdatePlan' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $file = Write-TestFile "$leaf\ComfyUI\models\checkpoints\model.safetensors" 'weights'
        $written = (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks
        $settings = @{ ComfyUI = @{ Dir = (Join-Path $root 'ComfyUI') }; Images = @{ File = 'model.safetensors'; Sha256 = 'c' * 64; Size = 7; Repo = 'Org/Model' } }
        $stamp = @{ Images = @{ File = 'model.safetensors'; Sha256 = 'c' * 64 } }
        $state = @{ Images = @{ VerifiedFiles = @{ ('c' * 64) = @{ Length = 7; WriteTicks = $written } } } }
        $plan = { Invoke-ModuleFunction 'Get-CheckpointUpdatePlan' @{ Settings = $settings; Stamp = $stamp; State = $state } }
    }

    It 'plans nothing when install checked the pinned file and it is unchanged' {
        @((& $plan).Changes).Count | Should -Be 0
    }

    It 'plans a check of the file when install-stamp.json checked another pin, and a download when it is missing' {
        $stamp.Images.Sha256 = 'd' * 64
        @((& $plan).Changes) | Should -Be @("model.safetensors ($('d' * 64)) -> model.safetensors ($('c' * 64)), checked against Images.Sha256")
        Remove-Item -LiteralPath $file
        @((& $plan).Changes) | Should -Be @("model.safetensors ($('d' * 64)) -> model.safetensors ($('c' * 64)), downloaded from Org/Model (1 KB)")
        $stamp.Images.Sha256 = 'c' * 64
        @((& $plan).Changes) | Should -Be @("$file missing -> downloaded from Org/Model (1 KB)")
    }

    It 'plans a new check when the file changed since install hashed it' {
        (Get-Item -LiteralPath $file).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
        @((& $plan).Changes) | Should -Be @("$file changed since install checked it -> checked against Images.Size and Images.Sha256 again")
    }
}

Describe 'Winget upgrades for update -Tools' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $listed = @{ Lines = @(); Code = 0 }
        $upgrade = @{ Code = 0 }
        # Any call the filters below miss throws, so a changed argument order never reaches the real winget.
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'winget' -and $ArgumentList[0] -eq 'list' } -MockWith {
            foreach ($line in $listed.Lines) { $Capture.Add($line) }
            if ($SuccessCode -notcontains $listed.Code) { throw "'winget list --id $($ArgumentList[2])' failed with exit code $($listed.Code)." }
            $listed.Code
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'winget' -and $ArgumentList[0] -eq 'upgrade' } -MockWith {
            if ($SuccessCode -notcontains $upgrade.Code) { throw "'winget upgrade --id $($ArgumentList[2])' failed with exit code $($upgrade.Code)." }
            $upgrade.Code
        }
        Mock Update-SessionPath -ModuleName LocalAI
        $ollama = @{ Id = 'Ollama.Ollama'; Command = 'ollama'; Scope = 'user' }
        $find = { param([hashtable]$Package) Invoke-ModuleFunction 'Get-WingetUpgrade' @{ Package = $Package } }
        $run = { param([hashtable]$Package) Invoke-ModuleFunction 'Update-WingetPackage' @{ Package = $Package; LogDir = $root } }
    }

    It 'reads the installed and the available version from the row, also when the name holds spaces' {
        $listed.Lines = @(
            'Name                   Id            Version Available Source'
            '-------------------------------------------------------------'
            'Ollama version 0.40.11 Ollama.Ollama 0.40.11 0.40.12   winget'
            '1 upgrades available.'
        )
        $found = & $find $ollama
        $found.Installed | Should -Be '0.40.11'
        $found.Available | Should -Be '0.40.12'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'list --id Ollama.Ollama -e --upgrade-available --accept-source-agreements --disable-interactivity' -and $null -ne $Capture
        }
    }

    It 'reads a version that winget shows with a less-than sign' {
        $listed.Lines = @('Git Git.Git < 2.56.0 2.57.0 winget')
        $found = & $find @{ Id = 'Git.Git' }
        $found.Installed | Should -Be '< 2.56.0'
        $found.Available | Should -Be '2.57.0'
    }

    It 'returns nothing when winget shows no upgrade (exit code <Code>)' -ForEach @(
        @{ Code = 0 }
        @{ Code = -1978335212 }
    ) {
        $listed.Lines = @('No installed package found matching input criteria.')
        $listed.Code = $Code
        & $find $ollama | Should -BeNullOrEmpty
    }

    It 'throws with what winget said when the list fails otherwise' {
        $listed.Lines = @('Failed when searching source: winget')
        $listed.Code = -1978335217
        { & $find $ollama } | Should -Throw -ExpectedMessage '*failed with exit code -1978335217. winget said: Failed when searching source: winget'
    }

    It 'plans uv, Git, Node.js and Ollama last, each only when winget offers an upgrade' {
        $settings = @{ Images = @{ Enabled = $true }; Files = @{ Root = 'C:\AI-Files' }; Winget = @{ Packages = @{
                    Ollama = @{ Id = 'Ollama.Ollama' }; Uv = @{ Id = 'astral-sh.uv' }; Git = @{ Id = 'Git.Git' }; Node = @{ Id = 'OpenJS.NodeJS.LTS' } } } }
        $asked = New-Object System.Collections.Generic.List[string]
        Mock Get-WingetUpgrade -ModuleName LocalAI -MockWith {
            $asked.Add($Package.Id)
            if ($Package.Id -ne 'Git.Git') { @{ Installed = '1.0'; Available = '2.0' } }
        }
        $plan = @(Invoke-ModuleFunction 'Get-WingetUpdatePlan' @{ Settings = $settings; Stamp = @{ Node = @{ InstalledByLauncher = $true } } } 6>$null)
        @($asked) | Should -Be @('astral-sh.uv', 'Git.Git', 'OpenJS.NodeJS.LTS', 'Ollama.Ollama')
        @($plan | ForEach-Object { $_.Display }) | Should -Be @('uv', 'Node.js', 'Ollama')
        $plan[2].Package.Id | Should -Be 'Ollama.Ollama'
        $plan[0].Upgrade.Available | Should -Be '2.0'
        # Images off: Git is not the launcher's. Node.js counts only once install put it in, also while Files.Root is off.
        $settings.Images.Enabled = $false
        $settings.Files.Root = ''
        $asked.Clear()
        $null = Invoke-ModuleFunction 'Get-WingetUpdatePlan' @{ Settings = $settings; Stamp = @{} } 6>$null
        @($asked) | Should -Be @('astral-sh.uv', 'Ollama.Ollama')
        $asked.Clear()
        $null = Invoke-ModuleFunction 'Get-WingetUpdatePlan' @{ Settings = $settings; Stamp = @{ Node = @{ InstalledByLauncher = $true } } } 6>$null
        @($asked) | Should -Be @('astral-sh.uv', 'OpenJS.NodeJS.LTS', 'Ollama.Ollama')
    }

    It 'leaves a Node.js that install found in place alone, also with Files.Root set, and says how to upgrade it' -ForEach @(
        @{ Case = 'install found it'; Stamp = @{ Node = @{ InstalledByLauncher = $false } } }
        @{ Case = 'nothing recorded'; Stamp = @{} }
    ) {
        $settings = @{ Images = @{ Enabled = $false }; Files = @{ Root = 'C:\AI-Files' }; Winget = @{ Packages = @{
                    Ollama = @{ Id = 'Ollama.Ollama' }; Uv = @{ Id = 'astral-sh.uv' }; Node = @{ Id = 'OpenJS.NodeJS.LTS'; Scope = 'machine' } } } }
        $asked = New-Object System.Collections.Generic.List[string]
        Mock Get-WingetUpgrade -ModuleName LocalAI -MockWith { $asked.Add($Package.Id); @{ Installed = '24.22.1'; Available = '26.13.0' } }
        $output = @(Invoke-ModuleFunction 'Get-WingetUpdatePlan' @{ Settings = $settings; Stamp = $Stamp } 6>&1)
        @($asked) | Should -Be @('astral-sh.uv', 'Ollama.Ollama')
        @($output | Where-Object { $_ -is [hashtable] } | ForEach-Object { $_.Name }) | Should -Be @('Uv', 'Ollama')
        @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) | Should -Be @(
            "Node.js stays as it is: install-stamp.json does not record that install put it in, so update -Tools leaves it to you; 'winget upgrade --id OpenJS.NodeJS.LTS -e' upgrades it.")
    }

    It 'upgrades on the console with its log in LogDir and returns <Outcome> for exit code <Code>' -ForEach @(
        @{ Code = 0; Outcome = 'upgraded'; Warning = '' }
        @{ Code = -1978335189; Outcome = 'current'; Warning = '' }
        @{ Code = -1978335153; Outcome = 'current'; Warning = '' }
        @{ Code = -1978334967; Outcome = 'restart'; Warning = 'Restart Windows to finish upgrading Ollama.Ollama.' }
        @{ Code = -1978335128; Outcome = 'pinned'; Warning = "winget holds Ollama.Ollama at a pinned version, so it was not upgraded; 'winget pin remove --id Ollama.Ollama' lifts the pin." }
        @{ Code = -1978335212; Outcome = 'missing'; Warning = 'winget lists no installed Ollama.Ollama, so it was not upgraded.' }
    ) {
        $upgrade.Code = $Code
        $output = @(& $run $ollama 3>&1 6>$null)
        @($output | Where-Object { $_ -is [string] }) | Should -Be @($Outcome)
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        if ($Warning) { $warnings | Should -Be @($Warning) } else { $warnings.Count | Should -Be 0 }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            [bool]$Console -and ($ArgumentList -join ' ') -ceq ('upgrade --id Ollama.Ollama -e --source winget --silent --disable-interactivity --accept-source-agreements ' +
                "--accept-package-agreements --log $(Join-Path $root 'winget-upgrade-Ollama.Ollama.log')")
        }
    }

    It 'names the reason winget documents for <Case>, and the log' -ForEach @(
        @{ Case = 'a package in use'; Code = -1978334975; Reason = "Ollama.Ollama is in use; close it, then run 'local-ai update -Tools' again. " }
        @{ Case = 'a declined administrator prompt'; Code = -1978334964; Reason = 'the installation was cancelled, as when the administrator prompt is declined. ' }
        @{ Case = 'a code without a documented reason'; Code = 1; Reason = '' }
    ) {
        $upgrade.Code = $Code
        { & $run $ollama 6>$null } | Should -Throw -ExpectedMessage ("winget could not upgrade Ollama.Ollama: 'winget upgrade --id Ollama.Ollama' failed with exit code $Code. " +
            "$Reason'winget error <code>' explains the code; the log is *winget-upgrade-Ollama.Ollama.log.")
    }

    It 'says that Windows asks for approval for a package installed for all users' {
        $printed = @(& $run @{ Id = 'OpenJS.NodeJS.LTS'; Scope = 'machine' } 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join "`n"
        $printed | Should -BeLike '*Upgrading OpenJS.NodeJS.LTS for all users: Windows asks for administrator approval (UAC).*Upgraded OpenJS.NodeJS.LTS.*'
    }
}

Describe 'Remove-SupersededAlias' {
    BeforeEach {
        $settings = @{ Model = @{ Alias = 'local-chat'; Source = 'hf.co/Org/Chat:Q6_K'; SupersededAliases = @('old-chat', 'older-chat', 'gone-chat') } }
        $ollama = @{
            Listed  = @('NAME                 ID              SIZE      MODIFIED', 'local-chat:latest    a5fa4a664b7d    8.3 GB    2 days ago',
                'old-chat:latest      b1b1b1b1b1b1    8.3 GB    3 weeks ago', 'older-chat           c2c2c2c2c2c2    4.0 GB    1 month ago')
            Fails   = $false
            Removed = New-Object System.Collections.Generic.List[string]
        }
        # Any call the filters below miss throws, so a changed argument order never reaches the real ollama.
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'ollama' -and $ArgumentList[0] -eq 'list' } -MockWith {
            foreach ($line in $ollama.Listed) { $Capture.Add($line) }
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'ollama' -and $ArgumentList[0] -eq 'rm' } -MockWith {
            if ($ollama.Fails) {
                $Capture.Add("$([char]27)[?25l$([char]27)[2KError: model is in use$([char]27)[K")
                throw "'ollama rm $($ArgumentList[1])' failed with exit code 1."
            }
            $ollama.Removed.Add($ArgumentList[1])
            0
        }
        $answers = @{ 'old-chat' = $true }
        $asked = New-Object System.Collections.Generic.List[string]
        Mock Confirm-LocalAIAction -ModuleName LocalAI -MockWith {
            $null = $Question -match 'holds (\S+), '
            $asked.Add($Matches[1])
            [bool]$answers[$Matches[1]]
        }
        # Not this PC's %USERPROFILE%\.qwen\settings.json.
        Mock Get-QwenCodeModel -ModuleName LocalAI
        # Ollama answers unless a test says otherwise.
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ version = '0.40.12' } }
        # Run Remove-SupersededAlias and return @{ Removed; Printed; Warnings }.
        $run = {
            $output = @(Invoke-ModuleFunction 'Remove-SupersededAlias' @{ Settings = $settings; Url = 'http://127.0.0.1:11434' } 3>&1 6>&1)
            @{
                Removed  = @($output | Where-Object { $_ -is [string] })
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
            }
        }
    }

    It 'asks about each superseded alias Ollama lists, removes only those answered yes, and returns them' {
        $result = & $run
        $result.Removed | Should -Be @('old-chat')
        @($asked) | Should -Be @('old-chat', 'older-chat')
        @($ollama.Removed) | Should -Be @('old-chat')
        $result.Printed | Should -BeLike '*Removed old-chat from Ollama.*Kept older-chat.*'
        Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Question -ceq "Ollama still holds old-chat, the alias of an earlier chat model. Remove it with 'ollama rm old-chat'? Blobs that local-chat uses stay."
        }
    }

    It 'never offers Model.Alias or Model.Source, with or without the tag latest' {
        $settings.Model.SupersededAliases = @('local-chat:latest', 'LOCAL-CHAT', 'hf.co/Org/Chat:Q6_K', 'old-chat')
        $ollama.Listed += 'hf.co/Org/Chat:Q6_K  d3d3d3d3d3d3  8.3 GB  2 days ago'
        $null = & $run
        @($asked) | Should -Be @('old-chat')
    }

    It 'asks nothing and runs no ollama when no alias is superseded' {
        $settings.Model.SupersededAliases = @()
        $null = & $run
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'asks Ollama for its version at the given Url before it runs ollama list' {
        $null = & $run
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Uri -eq 'http://127.0.0.1:11434/api/version' }
    }

    It 'warns, asks nothing and runs no ollama when Ollama <Case>, as ollama list would start the Ollama app' -ForEach @(
        @{ Case = 'does not answer'; Answer = 'throw'; Reason = 'Unable to connect to the remote server' }
        @{ Case = 'answers without a version'; Answer = 'empty'; Reason = 'it answered without a version' }
    ) {
        if ($Answer -eq 'throw') {
            Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'Unable to connect to the remote server' }
        } else {
            Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ error = 'not found' } }
        }
        $result = & $run
        $result.Removed.Count | Should -Be 0
        $result.Warnings | Should -BeExactly ("Could not list Ollama's models to offer removing the superseded aliases: Ollama does not answer at " +
            "http://127.0.0.1:11434/api/version ($Reason).")
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'warns without the terminal control sequences when ollama rm fails' {
        $ollama.Fails = $true
        $result = & $run
        $result.Removed.Count | Should -Be 0
        $result.Warnings | Should -BeExactly "Could not remove old-chat: 'ollama rm old-chat' failed with exit code 1. ollama said: Error: model is in use"
    }

    It 'removes nothing when this window cannot ask' {
        Mock Confirm-LocalAIAction -ModuleName LocalAI -MockWith { throw "This window cannot ask 'x'." }
        $result = & $run
        $result.Printed | Should -BeLike "*old-chat stays: This window cannot ask 'x'.*"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'rm' }
        Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'warns when Ollama cannot list its models' {
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'ollama' -and $ArgumentList[0] -eq 'list' } -MockWith { throw "Cannot find the program 'ollama'." }
        (& $run).Warnings | Should -BeExactly "Could not list Ollama's models to offer removing the superseded aliases: Cannot find the program 'ollama'."
    }

    It 'says before the question that Qwen Code still uses the alias, with the command that points it at Model.Alias' {
        Mock Get-QwenCodeModel -ModuleName LocalAI -MockWith { 'old-chat:latest' }
        $result = & $run
        $result.Removed | Should -Be @('old-chat')
        $result.Printed | Should -BeLike ('*old-chat: Qwen Code still uses it (model.name in its settings.json); point Qwen Code at local-chat first with: ' +
            'ollama launch qwen --model local-chat --config --yes*Removed old-chat from Ollama.*')
        $result.Printed | Should -Not -BeLike '*older-chat: Qwen Code*'
        $result.Warnings | Should -BeNullOrEmpty
    }

    It 'asks about every listed alias even when Shortcuts.Folder holds Start and Stop shortcuts' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($name in 'Start Local AI.lnk', 'Stop Local AI.lnk') { $null = Write-TestFile ((Split-Path $folder -Leaf) + "\$name") 'lnk' }
        $settings.Shortcuts = @{ Folder = $folder }
        $result = & $run
        $result.Removed | Should -Be @('old-chat')
        @($asked) | Should -Be @('old-chat', 'older-chat')
    }
}

Describe 'Get-QwenCodeModel' {
    It 'reads model.name from <Case>' -ForEach @(
        @{ Case = 'a settings file that names a model'; Text = '{"model":{"name":"qwen3.5-9b-old-32k"},"security":{}}'; Expected = 'qwen3.5-9b-old-32k' }
        @{ Case = 'a file whose model is a string'; Text = '{"model":"local-chat"}'; Expected = 'local-chat' }
        @{ Case = 'a file without a model'; Text = '{"theme":"dark"}'; Expected = $null }
        @{ Case = 'a file that is not JSON'; Text = '{ // a comment'; Expected = $null }
    ) {
        $path = Write-TestFile "qwen-$([guid]::NewGuid().ToString('N'))\settings.json" $Text
        Invoke-ModuleFunction 'Get-QwenCodeModel' @{ Path = $path } | Should -Be $Expected
    }

    It 'gives $null for a missing file' {
        Invoke-ModuleFunction 'Get-QwenCodeModel' @{ Path = (Join-Path $TestDrive 'none\settings.json') } | Should -BeNullOrEmpty
    }
}

Describe 'Update-OpenWebUITool' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $paths = Get-LocalAIPaths -Root (Join-Path $root 'local-ai')
        $dataDir = Join-Path $root 'open-webui'
        foreach ($name in 'webui.db', 'webui.db-wal', '.webui_secret_key', 'uploads\a.txt') { $null = Write-TestFile "$leaf\open-webui\$name" $name }
        $settings = @{ OpenWebUI = @{ Version = '0.12.4'; Python = '3.12'; ExcludeNewer = '2026-10-25T08:10:00Z'; DataDir = $dataDir; InstallBytes = 2987894996 }; Update = @{ KeepBackups = 3 } }
        $old = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' }
        $plan = @{ Name = 'OpenWebUI'; Reinstall = $true; Tool = $old }
        Write-LocalAIState -Path $paths.InstallStamp -State @{ OpenWebUI = $old.Clone(); Model = @{ Alias = 'local-chat' } }
        $uv = @{ FailNew = $false; FailOld = $false; FailList = $false; WrongNew = $false; Installs = New-Object System.Collections.Generic.List[string] }
        $order = New-Object System.Collections.Generic.List[string]
        # uv runs only through the mocks below; anything that reaches a program throws.
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Test-FreeSpace -ModuleName LocalAI -MockWith { $order.Add("space $Path") }
        Mock Save-UvFreeze -ModuleName LocalAI -MockWith {
            # Whether the backup beside which the list goes holds the database yet.
            $order.Add("freeze, backup holds webui.db: $(Test-Path -LiteralPath (Join-Path (Split-Path $Path -Parent) 'webui.db'))")
            [IO.File]::WriteAllText($Path, "open-webui==0.12.3`n")
            245
        }
        Mock Install-UvTool -ModuleName LocalAI -MockWith {
            $order.Add("install $Package")
            $uv.Installs.Add("$Package on $Python, list '$Constraints', reinstall $([bool]$Reinstall)")
            if ($Package -eq 'open-webui==0.12.4') {
                if ($uv.FailNew) { throw 'error: Failed to download torch' }
                # As when uv keeps the old environment and reports success.
                if ($uv.WrongNew) { return @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' } }
                return @{ Version = '0.12.4'; Python = '3.12.16'; Path = 'C:\uv\bin\open-webui.exe' }
            }
            if ($uv.FailOld -or ($uv.FailList -and $Constraints)) { throw 'error: No solution found' }
            @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' }
        }
        $run = { Invoke-ModuleFunction 'Update-OpenWebUITool' @{ Settings = $settings; Paths = $paths; Plan = $plan; ToolDir = 'C:\uv\tools' } }
    }

    It 'backs up the data, saves the old versions beside the backup, reinstalls the pin and records it with the previous version' {
        $result = & $run 6>$null
        Split-Path $result.Backup -Parent | Should -Be $paths.Backups
        Test-Path -LiteralPath (Join-Path $result.Backup 'webui.db-wal') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.Backup 'uploads\a.txt') | Should -BeTrue
        $result.Constraints | Should -Be (Join-Path $result.Backup 'open-webui-packages.txt')
        Should -Invoke Save-UvFreeze -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Python -eq 'C:\uv\tools\open-webui\Scripts\python.exe' }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\uv\tools' -and $RequiredBytes -eq 2987894996 }
        @($uv.Installs) | Should -Be @("open-webui==0.12.4 on 3.12, list '', reinstall True")
        $result.Done | Should -Be 'Open WebUI: 0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12.16'
        $result.Previous.Version | Should -Be '0.12.3'
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp.OpenWebUI.Version | Should -Be '0.12.4'
        $stamp.OpenWebUI.Python | Should -Be '3.12.16'
        $stamp.OpenWebUI.PreviousVersion | Should -Be '0.12.3'
        $stamp.OpenWebUI.PreviousPython | Should -Be '3.11.17'
        $stamp.OpenWebUI.Backup | Should -Be $result.Backup
        $stamp.OpenWebUI.ToolDir | Should -Be 'C:\uv\tools'
        $stamp.OpenWebUI.DataDir | Should -Be $dataDir
        $stamp.Model.Alias | Should -Be 'local-chat'
        $result.ToolDir | Should -Be 'C:\uv\tools'
    }

    It 'reinstalls as of OpenWebUI.ExcludeNewer and records it, and puts an old version back as of its own recorded cut-off' {
        $null = & $run 6>$null
        Should -Invoke Install-UvTool -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Package -eq 'open-webui==0.12.4' -and $ExcludeNewer -ceq '2026-10-25T08:10:00Z' }
        (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI.ExcludeNewer | Should -BeExactly '2026-10-25T08:10:00Z'
        $recorded = $old.Clone()
        $recorded.ExcludeNewer = '2026-10-01T00:00:00Z'
        Write-LocalAIState -Path $paths.InstallStamp -State @{ OpenWebUI = $recorded }
        $uv.FailNew = $true
        { & $run 6>$null } | Should -Throw
        Should -Invoke Install-UvTool -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Package -eq 'open-webui==0.12.3' -and $ExcludeNewer -ceq '2026-10-01T00:00:00Z' }
        (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI.ExcludeNewer | Should -BeExactly '2026-10-01T00:00:00Z'
    }

    It 'returns the cut-off install-stamp.json recorded for the old version with it, for a rollback' {
        $recorded = $old.Clone()
        $recorded.ExcludeNewer = '2026-10-01T00:00:00Z'
        Write-LocalAIState -Path $paths.InstallStamp -State @{ OpenWebUI = $recorded }
        (& $run 6>$null).Previous.ExcludeNewer | Should -BeExactly '2026-10-01T00:00:00Z'
    }

    It 'keeps the recorded cut-off when it only records what uv lists' {
        $plan.Reinstall = $false
        $recorded = $old.Clone()
        $recorded.ExcludeNewer = '2026-10-01T00:00:00Z'
        Write-LocalAIState -Path $paths.InstallStamp -State @{ OpenWebUI = $recorded }
        $null = & $run 6>$null
        (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI.ExcludeNewer | Should -BeExactly '2026-10-01T00:00:00Z'
    }

    It 'backs up the data before it saves the package list beside it, and both before the space check and the reinstall' {
        $null = & $run 6>$null
        @($order) | Should -Be @("space $($paths.Backups)", 'freeze, backup holds webui.db: True', 'space C:\uv\tools', 'install open-webui==0.12.4')
    }

    It 'puts the old version back and throws when uv lists another version than the pin after the reinstall' {
        $uv.WrongNew = $true
        { & $run 6>$null } | Should -Throw -ExpectedMessage ('Open WebUI 0.12.4 could not be installed: uv lists Open WebUI 0.12.3 on Python 3.11.17 afterwards, not ' +
            '0.12.4 on Python 3.12 with an entry point. Open WebUI 0.12.3 on Python 3.11.17 is installed again, and its data was not touched.')
        $uv.Installs.Count | Should -Be 2
        $uv.Installs[1] | Should -BeLike "open-webui==0.12.3 on 3.11.17, list '*open-webui-packages.txt', reinstall True"
        (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI.ContainsKey('PreviousVersion') | Should -BeFalse
    }

    It 'deletes no older backup itself, which update does once the new version passed its check' {
        $settings.Update.KeepBackups = 1
        $older = Join-Path $paths.Backups 'open-webui-20260101-000000'
        Write-LocalAIState -Path (Join-Path $older 'local-ai-backup.json') -State @{ Kind = 'open-webui-update' }
        $null = & $run 6>$null
        Test-Path -LiteralPath $older | Should -BeTrue
    }

    It 'records the tool and data folders when it only records what uv lists, and after the old version is back' {
        $plan.Reinstall = $false
        $null = & $run 6>$null
        $entry = (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI
        $entry.ToolDir | Should -Be 'C:\uv\tools'
        $entry.DataDir | Should -Be $dataDir
        $plan.Reinstall = $true
        $uv.FailNew = $true
        { & $run 6>$null } | Should -Throw
        $entry = (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI
        $entry.Version | Should -Be '0.12.3'
        $entry.ToolDir | Should -Be 'C:\uv\tools'
        $entry.DataDir | Should -Be $dataDir
    }

    It 'only records what uv lists when nothing needs reinstalling, backing up nothing' {
        $plan.Reinstall = $false
        $result = & $run 6>$null
        $uv.Installs.Count | Should -Be 0
        Test-Path -LiteralPath $paths.Backups | Should -BeFalse
        $result.Previous | Should -BeNullOrEmpty
        $result.Done | Should -Be 'Open WebUI: install-stamp.json records 0.12.3 on Python 3.11.17, as uv lists it'
    }

    It 'puts the old version back under the saved list when the reinstall fails, and throws saying so' {
        $uv.FailNew = $true
        { & $run 6>$null } | Should -Throw -ExpectedMessage ('Open WebUI 0.12.4 could not be installed: error: Failed to download torch Open WebUI 0.12.3 on Python 3.11.17 is ' +
            'installed again, and its data was not touched.')
        $uv.Installs[1] | Should -BeLike "open-webui==0.12.3 on 3.11.17, list '*open-webui-packages.txt', reinstall True"
        $entry = (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI
        $entry.Version | Should -Be '0.12.3'
        $entry.ContainsKey('PreviousVersion') | Should -BeFalse
    }

    It 'tries the rollback again without the list when the install under it fails' {
        $uv.FailNew = $true
        $uv.FailList = $true
        { & $run 6>$null } | Should -Throw -ExpectedMessage '*Open WebUI 0.12.3 on Python 3.11.17 is installed again*'
        $uv.Installs.Count | Should -Be 3
        $uv.Installs[2] | Should -Be "open-webui==0.12.3 on 3.11.17, list '', reinstall True"
    }

    It 'names the command that reinstalls the old version when the rollback fails too' {
        $uv.FailNew = $true
        $uv.FailOld = $true
        { & $run 6>$null } | Should -Throw -ExpectedMessage ('*Putting back Open WebUI 0.12.3 failed too (error: No solution found), so Open WebUI may not be installed now; ' +
            'its data was not touched, and the backup is *. Reinstall it with: uv tool install --python 3.11.17 open-webui==0.12.3 -c "*open-webui-packages.txt" --reinstall')
    }

    It 'warns and goes on without a list when uv cannot list the old packages' {
        Mock Save-UvFreeze -ModuleName LocalAI -MockWith { throw "'uv pip freeze --python x' listed no packages." }
        $output = @(& $run 3>&1 6>$null)
        @($output | Where-Object { $_ -is [hashtable] })[0].Constraints | Should -BeNullOrEmpty
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) |
            Should -Be @("Could not save the package versions of Open WebUI 0.12.3, so a rollback would resolve its packages anew: 'uv pip freeze --python x' listed no packages.")
    }

    It 'reinstalls nothing when the space check for the new version fails' {
        Mock Test-FreeSpace -ModuleName LocalAI -ParameterFilter { $Path -eq 'C:\uv\tools' } -MockWith { throw 'Drive C: has 1.0 GB free' }
        { & $run 6>$null } | Should -Throw -ExpectedMessage '*Drive C: has 1.0 GB free*'
        $uv.Installs.Count | Should -Be 0
    }
}

Describe 'Undo-OpenWebUIUpdate' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root (Join-Path $root 'local-ai')
        $dataDir = Join-Path $root 'open-webui'
        $context = @{ Paths = $paths; Settings = @{ OpenWebUI = @{ Version = '0.12.4'; DataDir = $dataDir } } }
        $change = @{ Previous = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' }; Backup = 'C:\b\open-webui-20261028-120000'
            Constraints = 'C:\b\open-webui-20261028-120000\open-webui-packages.txt'; ToolDir = 'C:\uv\tools' }
        Write-LocalAIState -Path $paths.InstallStamp -State @{ OpenWebUI = @{ Version = '0.12.4'; Python = '3.12.16'; Path = 'C:\uv\bin\open-webui.exe'; PreviousVersion = '0.12.3' } }
        $order = New-Object System.Collections.Generic.List[string]
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $order.Add('stop')
            0
        }
        Mock Restore-OpenWebUITool -ModuleName LocalAI -MockWith {
            $order.Add("tool $Version $Python $Constraints")
            $order.Add("cut-off '$ExcludeNewer'")
            @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' }
        }
        Mock Restore-OpenWebUIData -ModuleName LocalAI -MockWith {
            $order.Add("data $DataDir $Backup $BackupRoot")
            'C:\b\open-webui-failed-20261028-121500'
        }
        $run = { Invoke-ModuleFunction 'Undo-OpenWebUIUpdate' @{ Context = $context; Change = $change } }
    }

    It 'stops the stack, reinstalls the previous version under its package list, records it and puts the data back' {
        & $run | Should -BeExactly ('Open WebUI 0.12.3 on Python 3.11.17 is installed again, with its data back as C:\b\open-webui-20261028-120000 holds it, and the data ' +
            'the new version used is in C:\b\open-webui-failed-20261028-121500.')
        @($order) | Should -Be @('stop', "tool 0.12.3 3.11.17 $($change.Constraints)", "cut-off ''", "data $dataDir $($change.Backup) $($paths.Backups)")
        # The stack starts again afterwards against the same Ollama.
        Should -Invoke Stop-LocalAI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $KeepOllama }
        $entry = (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI
        $entry.Version | Should -Be '0.12.3'
        $entry.Python | Should -Be '3.11.17'
        $entry.ContainsKey('PreviousVersion') | Should -BeFalse
        $entry.ContainsKey('ExcludeNewer') | Should -BeFalse
    }

    It 'puts the previous version back as of the cut-off it was installed with, and records that' {
        $change.Previous.ExcludeNewer = '2026-10-01T00:00:00Z'
        $null = & $run
        @($order) | Should -Contain "cut-off '2026-10-01T00:00:00Z'"
        (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI.ExcludeNewer | Should -BeExactly '2026-10-01T00:00:00Z'
        $entry.ToolDir | Should -Be 'C:\uv\tools'
        $entry.DataDir | Should -Be $dataDir
    }

    It 'reinstalls nothing when the stack cannot be stopped, and says how to roll back by hand' {
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith { 1 }
        & $run | Should -BeLike ("It could not be stopped for the rollback, so the new version stays; once it is stopped, reinstall the previous one with: uv tool install " +
            "--python 3.11.17 open-webui==0.12.3 -c `"$($change.Constraints)`" --reinstall. Then move $dataDir aside and copy what $($change.Backup) holds into it*")
        Should -Invoke Restore-OpenWebUITool -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'leaves the data as the new version used it when the reinstall fails' {
        Mock Restore-OpenWebUITool -ModuleName LocalAI -MockWith { throw 'error: No solution found' }
        & $run | Should -BeLike 'Reinstalling Open WebUI 0.12.3 failed (error: No solution found), so its data was left as the new version used it.*'
        Should -Invoke Restore-OpenWebUIData -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI.Version | Should -Be '0.12.4'
    }

    It 'says to put the data back by hand when that fails' {
        Mock Restore-OpenWebUIData -ModuleName LocalAI -MockWith { throw 'Access is denied.' }
        & $run | Should -BeLike 'Open WebUI 0.12.3 on Python 3.11.17 is installed again, but putting back its data failed (Access is denied.); move * by hand.'
    }
}

Describe 'Update-ComfyUICheckout' {
    BeforeAll {
        $pin = '483dae4326356b81de05d27aca3f433dd323cc25'
        $old = 'abcdef0123456789abcdef0123456789abcdef01'
        $repo = 'https://github.com/Comfy-Org/ComfyUI.git'
        $oldOrigin = 'https://github.com/comfyanonymous/ComfyUI.git'
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root (Join-Path $root 'local-ai')
        $dir = Join-Path $root 'ComfyUI'
        $settings = @{ ComfyUI = @{ Dir = $dir; Repo = $repo; Ref = 'v0.42.5'; Commit = $pin } }
        Write-LocalAIState -Path $paths.InstallStamp -State @{ ComfyUI = @{ Dir = $dir; Commit = $old; Ref = $null; Pinned = $false; Cloned = $true }; Model = @{ Alias = 'local-chat' } }
        $git = Get-FakeGit -Head $old -Commit $pin
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'git' } -MockWith $fakeGit
        $comfy = @{ Fail = $null }
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith {
            if ($comfy.Fail) { throw $comfy.Fail }
            @{ Dir = $dir; Commit = $git.Head; Pinned = ($git.Head -eq $pin); Python = "$dir\.venv\Scripts\python.exe"; PythonVersion = '3.13.14'; Torch = '2.14.1+cu130' }
        }
        $plan = @{ Name = 'ComfyUI'; Dir = $dir; Migrate = $true }
        $run = { Invoke-ModuleFunction 'Update-ComfyUICheckout' @{ Settings = $settings; Paths = $paths; Plan = $plan; RepoRoot = $TestDrive } }
    }

    It 'moves the checkout to the tag, runs the venv step and records the pin with the previous commit, branch and origin, keeping other fields' {
        & $run 6>$null | Should -Be "ComfyUI: $old -> v0.42.5 ($pin), torch 2.14.1+cu130"
        $git.Head | Should -Be $pin
        $git.Origin | Should -Be $repo
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $RepoRoot -eq $TestDrive }
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $entry = $stamp.ComfyUI
        $entry.Commit | Should -Be $pin
        $entry.Ref | Should -Be 'v0.42.5'
        $entry.Pinned | Should -BeTrue
        $entry.Python | Should -Be "$dir\.venv\Scripts\python.exe"
        $entry.PythonVersion | Should -Be '3.13.14'
        $entry.Torch | Should -Be '2.14.1+cu130'
        $entry.PreviousCommit | Should -Be $old
        $entry.PreviousBranch | Should -Be 'refs/heads/master'
        $entry.PreviousOrigin | Should -Be $oldOrigin
        $entry.Cloned | Should -BeTrue
        $stamp.Model.Alias | Should -Be 'local-chat'
    }

    It 'only points origin at Repo and runs the venv step when HEAD is the pin' {
        $git.Head = $pin
        $git.Branch = $null
        & $run 6>$null | Should -Be "ComfyUI: v0.42.5 ($pin) with origin $repo, torch 2.14.1+cu130"
        @($git.Calls | Where-Object { $_ -like 'fetch*' -or $_ -like 'checkout*' }).Count | Should -Be 0
        $git.Origin | Should -Be $repo
        (Read-LocalAIState -Path $paths.InstallStamp).ComfyUI.ContainsKey('PreviousCommit') | Should -BeFalse
    }

    It 'puts the checkout back, marks the venv stale and says what it may hold when the venv step fails after the move' {
        $comfy.Fail = 'The torch check failed.'
        $markerPath = Join-Path $dir '.venv\local-ai-install.json'
        Write-LocalAIState -Path $markerPath -State @{ CreatedVenv = $true; RequirementsSha256 = 'e' * 64; ConstraintsSha256 = 'f' * 64; Torch = '2.14.1+cu130' }
        { & $run 6>$null } | Should -Throw -ExpectedMessage ("ComfyUI's venv step failed after the move to v0.42.5: The torch check failed. ComfyUI in $dir is back at $old " +
            "with origin $oldOrigin. Its venv may hold packages uv had installed for v0.42.5 by then; 'local-ai install' installs the requirements of the checkout into it " +
            'again, and start warns until then.')
        $git.Head | Should -Be $old
        $git.Branch | Should -Be 'refs/heads/master'
        $git.Origin | Should -Be $oldOrigin
        (Read-LocalAIState -Path $paths.InstallStamp).ComfyUI.Commit | Should -Be $old
        $marker = Read-LocalAIState -Path $markerPath
        $marker.ContainsKey('RequirementsSha256') | Should -BeFalse
        $marker.CreatedVenv | Should -BeTrue
        $marker.ConstraintsSha256 | Should -Be ('f' * 64)
    }

    It 'says how to mark the venv stale by hand when its marker cannot be rewritten' {
        $comfy.Fail = 'The torch check failed.'
        $markerPath = Join-Path $dir '.venv\local-ai-install.json'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $markerPath -Parent)
        [IO.File]::WriteAllText($markerPath, '{ not json')
        { & $run 6>$null } | Should -Throw -ExpectedMessage "*by then; its marker $markerPath could not be marked stale (*); remove RequirementsSha256 from it, then run 'local-ai install'*"
        $git.Head | Should -Be $old
    }

    It 'throws without moving anything back when the venv step fails at the pin' {
        $git.Head = $pin
        $git.Origin = $repo
        $comfy.Fail = 'uv failed.'
        { & $run 6>$null } | Should -Throw -ExpectedMessage "ComfyUI's venv step failed: uv failed."
        @($git.Calls | Where-Object { $_ -like 'checkout*' }).Count | Should -Be 0
    }

    It 'makes the venv anew with Reset-ComfyUIVenv instead of Install-ComfyUI when the plan says so, naming the new venv in its line' {
        $git.Head = $pin
        $git.Branch = $null
        $plan.Migrate = $false
        $plan.Rebuild = $true
        Mock Reset-ComfyUIVenv -ModuleName LocalAI -MockWith {
            @{ Dir = $dir; Commit = $git.Head; Pinned = $true; Python = "$dir\.venv\Scripts\python.exe"; PythonVersion = '3.13.18'; Torch = '2.14.1+cu130'; Rebuilt = $true }
        }
        & $run 6>$null | Should -Be "ComfyUI: v0.42.5 ($pin) with origin $repo, torch 2.14.1+cu130, in a new venv on Python 3.13.18"
        Should -Invoke Reset-ComfyUIVenv -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $RepoRoot -eq $TestDrive }
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path $paths.InstallStamp).ComfyUI.PythonVersion | Should -Be '3.13.18'
    }

    It "puts the checkout back and leaves the old venv's marker alone when the new venv fails after the move and the old one is back" {
        $plan.Rebuild = $true
        $markerPath = Join-Path $dir '.venv\local-ai-install.json'
        Write-LocalAIState -Path $markerPath -State @{ CreatedVenv = $false; RequirementsSha256 = 'e' * 64 }
        Write-TestPyVenvConfig -Venv (Join-Path $dir '.venv') -BaseHome $storeHome -Version '3.13.14'
        Mock Reset-ComfyUIVenv -ModuleName LocalAI -MockWith {
            throw "The new venv on a uv-managed Python failed: uv failed. ComfyUI's venv is back on the Microsoft Store Python, as it was."
        }
        { & $run 6>$null } | Should -Throw -ExpectedMessage ("ComfyUI's venv step failed after the move to v0.42.5: The new venv on a uv-managed Python failed: uv " +
            "failed. ComfyUI's venv is back on the Microsoft Store Python, as it was. ComfyUI in $dir is back at $old with origin $oldOrigin.")
        $git.Head | Should -Be $old
        (Read-LocalAIState -Path $markerPath).RequirementsSha256 | Should -Be ('e' * 64)
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'refuses to move a checkout whose tracked files changed after the plan' {
        $git.Modified = @('main.py')
        { & $run 6>$null } | Should -Throw -ExpectedMessage "$dir has changes to tracked files, so it was not moved: main.py."
        Should -Invoke Install-ComfyUI -ModuleName LocalAI -Times 0 -Exactly
    }
}

Describe 'Test-LocalAIUpdateSmoke' {
    BeforeEach {
        $paths = Get-LocalAIPaths -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Write-LocalAIState -Path $paths.InstallStamp -State @{ OpenWebUI = @{ Version = '0.12.4' } }
        $answers = @{ OpenWebUI = '0.12.4'; ComfyUI = '0.42.5'; ImageGate = '1.0'; Files = 'server-filesystem 2.0.1'; Cuda = $true }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Get-LocalAIServicePlan -ModuleName LocalAI -MockWith {
            foreach ($name in 'ComfyUI', 'ImageGate', 'Files', 'OpenWebUI') {
                @{ Name = $name; DisplayName = $name; Url = "http://127.0.0.1/$name"; Required = ($name -eq 'OpenWebUI')
                    Identity = { param([hashtable]$Service) if (-not $answers[$Service.Name]) { throw 'Unable to connect to the remote server' }; $answers[$Service.Name] } }
            }
        }
        Mock Test-ComfyUIDevice -ModuleName LocalAI -MockWith {
            if ($answers.Cuda) { return $true }
            Write-Warning 'ComfyUI reports cpu (type cpu), not a CUDA GPU, so each image takes many minutes.'
            $false
        }
        $run = { param([string]$Version = '0.12.4') Invoke-ModuleFunction 'Test-LocalAIUpdateSmoke' @{ Settings = @{}; Paths = $paths; OllamaUrl = 'http://127.0.0.1:11434'; OpenWebUIVersion = $Version } }
    }

    It 'passes when every service answers as itself, Open WebUI with the expected version and ComfyUI on CUDA' {
        $result = & $run 6>$null
        $result.OpenWebUI | Should -BeNullOrEmpty
        @($result.Problems).Count | Should -Be 0
        Should -Invoke Get-LocalAIServicePlan -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Stamp.OpenWebUI.Version -eq '0.12.4' -and $OllamaUrl -eq 'http://127.0.0.1:11434' }
        Should -Invoke Test-ComfyUIDevice -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Url -eq 'http://127.0.0.1/ComfyUI' }
    }

    It 'fails Open WebUI when it answers as another version or not at all' {
        (& $run '0.12.5' 6>$null).OpenWebUI | Should -BeExactly 'it answers as Open WebUI 0.12.4, not 0.12.5.'
        $answers.OpenWebUI = $null
        (& $run 6>$null).OpenWebUI | Should -BeExactly 'Unable to connect to the remote server'
    }

    It 'lists each optional service that fails, ComfyUI on the CPU included, as a problem' {
        $answers.Files = $null
        $answers.Cuda = $false
        $result = & $run 6>$null
        $result.OpenWebUI | Should -BeNullOrEmpty
        @($result.Problems) | Should -Be @(
            'ComfyUI fails the check after the update: ComfyUI reports cpu (type cpu), not a CUDA GPU, so each image takes many minutes.'
            'Files fails the check after the update: Unable to connect to the remote server'
        )
    }
}

Describe 'Get-LocalAIUpdatePlan' {
    BeforeEach {
        $order = New-Object System.Collections.Generic.List[string]
        $notes = @{}
        # Return a plan part called $Name, noting the call.
        $part = {
            param([string]$Name)
            $order.Add($Name)
            @{ Name = $Name; Display = $Name; Changes = @(); Problem = $null; Note = $notes[$Name] }
        }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Get-OpenWebUIUpdatePlan -ModuleName LocalAI -MockWith { & $part 'OpenWebUI' }
        Mock Get-ComfyUIUpdatePlan -ModuleName LocalAI -MockWith { & $part 'ComfyUI' }
        Mock Get-FilesUpdatePlan -ModuleName LocalAI -MockWith { & $part 'Files' }
        Mock Get-ModelUpdatePlan -ModuleName LocalAI -MockWith { & $part 'Model' }
        Mock Get-CheckpointUpdatePlan -ModuleName LocalAI -MockWith { & $part 'Checkpoint' }
        Mock Get-WingetUpdatePlan -ModuleName LocalAI -MockWith { @{ Name = 'Uv' } }
        Mock Get-UvToolDir -ModuleName LocalAI -MockWith { 'C:\uv\tools' }
        $settings = @{ Images = @{ Enabled = $true }; Files = @{ Root = 'C:\AI-Files' } }
        $run = { param([bool]$Tools) Invoke-ModuleFunction 'Get-LocalAIUpdatePlan' @{ Settings = $settings; Paths = @{}; Stamp = @{}; State = @{}; RepoRoot = 'C:\repo'; Tools = $Tools } }
    }

    It 'plans Open WebUI, ComfyUI, the file tools, the model and the checkpoint in that order, and no tools without -Tools' {
        $plan = & $run $false 3>$null
        @($order) | Should -Be @('OpenWebUI', 'ComfyUI', 'Files', 'Model', 'Checkpoint')
        @($plan.Components | ForEach-Object { $_.Name }) | Should -Be @('OpenWebUI', 'ComfyUI', 'Files', 'Model', 'Checkpoint')
        @($plan.Tools).Count | Should -Be 0
        $plan.ToolDir | Should -Be 'C:\uv\tools'
        Should -Invoke Get-WingetUpdatePlan -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'plans the winget packages with -Tools' {
        $plan = & $run $true 3>$null
        @($plan.Tools).Count | Should -Be 1
        $plan.Tools[0].Name | Should -Be 'Uv'
    }

    It 'leaves out ComfyUI and the checkpoint without images, and the file tools without Files.Root' {
        $settings.Images.Enabled = $false
        $settings.Files.Root = ''
        $null = & $run $false
        @($order) | Should -Be @('OpenWebUI', 'Model')
    }

    It 'warns for each part a note leaves out, and plans no checkpoint while ComfyUI has one' {
        $notes['ComfyUI'] = 'install has not set up ComfyUI, so update leaves it out.'
        $output = @(& $run $false 3>&1)
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) |
            Should -Be @('ComfyUI: install has not set up ComfyUI, so update leaves it out.')
        $order | Should -Not -Contain 'Checkpoint'
    }
}

Describe 'Update-LocalAI' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent

        # Run Update-LocalAI and return @{ Code; Printed; Warnings } with the host text and the warnings joined.
        function Invoke-UpdateVerb([hashtable]$Context) {
            $output = @(Update-LocalAI -Context $Context 3>&1 6>&1)
            return @{
                Code     = @($output | Where-Object { $_ -is [int] })
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
            }
        }

        # Return a part of update's plan called $Name, shown as the plan functions show it, with the changes $Changes and the fields $Extra.
        function Get-TestPlanPart([string]$Name, [string[]]$Changes = @(), [hashtable]$Extra = @{}) {
            $displays = @{ OpenWebUI = 'Open WebUI'; Files = 'File tools' }
            $display = if ($displays.ContainsKey($Name)) { $displays[$Name] } else { $Name }
            $part = @{ Name = $Name; Display = $display; Changes = @($Changes); Problem = $null; Note = $null }
            foreach ($key in $Extra.Keys) { $part[$key] = $Extra[$key] }
            return $part
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.ComfyUI.Dir = Join-Path $root 'ComfyUI'
        $settings.OpenWebUI.DataDir = Join-Path $root 'open-webui'
        Write-LocalAIState -Path $paths.InstallStamp -State @{
            Ollama = @{ Version = '0.40.11' }; Model = @{ Alias = 'local-chat' }; OpenWebUI = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' }
        }
        $context = @{ Verb = 'update'; Paths = $paths; Settings = $settings; RepoRoot = $repoRoot; Tools = $false; NoBrowser = $false }
        $calls = New-Object System.Collections.Generic.List[string]
        $webTool = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' }
        $world = @{
            Plan    = @{
                Components = @(
                    (Get-TestPlanPart -Name 'OpenWebUI' -Changes '0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12, after a backup of its data' -Extra @{ Reinstall = $true; Tool = $webTool })
                    (Get-TestPlanPart -Name 'ComfyUI' -Changes 'commit e087 (branch master) -> v0.42.5 (483d)' -Extra @{ Dir = $settings.ComfyUI.Dir; Migrate = $true })
                    (Get-TestPlanPart -Name 'Model')
                )
                Tools      = @()
                ToolDir    = 'C:\uv\tools'
            }
            Yes     = $true
            Running = @()
            Busy    = @()
            Stop    = 0
            # Whether the check's start gets as far as launching Open WebUI.
            Launch  = $true
            Smoke   = @{ OpenWebUI = $null; Problems = @() }
        }
        $webChange = @{ Done = 'Open WebUI: 0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12.16'; Previous = $webTool; Backup = 'C:\b\open-webui-1'
            Constraints = 'C:\b\open-webui-1\open-webui-packages.txt' }
        # Every program update runs goes through the mocked steps below; anything that reaches one throws.
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Set-LocalAIKeepAwake -ModuleName LocalAI -MockWith { $calls.Add("awake $Enabled") }
        Mock Update-SessionPath -ModuleName LocalAI
        Mock Assert-OllamaCliUrl -ModuleName LocalAI
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { if ($PassThru) { [pscustomobject]@{ Version = '0.40.12'; App = $null } } else { '0.40.12' } }
        # No Ollama app is recorded or listed unless a test says so.
        Mock Get-OllamaAppProcess -ModuleName LocalAI
        Mock Get-LocalAIUpdatePlan -ModuleName LocalAI -MockWith {
            $calls.Add("plan Tools=$([bool]$Tools)")
            $world.Plan
        }
        Mock Confirm-LocalAIAction -ModuleName LocalAI -MockWith {
            $calls.Add("ask $Question")
            $world.Yes
        }
        Mock Get-LocalAIRunningService -ModuleName LocalAI -MockWith {
            $calls.Add('running')
            $world.Running
        }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add('stop')
            $world.Stop
        }
        Mock Get-BusyProcess -ModuleName LocalAI -MockWith {
            $calls.Add('busy')
            $world.Busy
        }
        Mock Update-OpenWebUITool -ModuleName LocalAI -MockWith {
            $calls.Add('webui')
            $webChange
        }
        Mock Update-ComfyUICheckout -ModuleName LocalAI -MockWith {
            $calls.Add('comfy')
            'ComfyUI: e087 -> v0.42.5 (483d), torch 2.14.1+cu130'
        }
        Mock Install-FilesServer -ModuleName LocalAI -MockWith {
            $calls.Add('files')
            @{ McpoVersion = '0.0.20'; ServerVersion = '2.0.1' }
        }
        Mock Install-ChatModel -ModuleName LocalAI -MockWith {
            $calls.Add('model')
            $State['Model'] = @{ Alias = 'local-chat'; Source = 'hf.co/x'; BaseDigest = 'a' * 64; ProjectorDigest = 'b' * 64; ModelfileSha256 = 'c' * 64; Modelfile = 'C:\repo\local-chat.Modelfile' }
            $State
        }
        Mock Install-ImageModel -ModuleName LocalAI -MockWith {
            $calls.Add('checkpoint')
            $Verified['d' * 64] = @{ Length = 1; WriteTicks = 2 }
            @{ Path = 'C:\x'; Sha256 = $Settings.Images.Sha256 }
        }
        Mock Update-WingetPackage -ModuleName LocalAI -MockWith {
            $calls.Add("winget $($Package.Id)")
            'upgraded'
        }
        Mock Start-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("start NoBrowser=$($Context.NoBrowser)")
            if ($world.Launch -and $Context.Launched -is [System.Collections.Generic.List[string]]) { $Context.Launched.Add('OpenWebUI') }
            0
        }
        Mock Test-LocalAIUpdateSmoke -ModuleName LocalAI -MockWith {
            $calls.Add("smoke $OpenWebUIVersion")
            $world.Smoke
        }
        Mock Remove-OldOpenWebUIBackup -ModuleName LocalAI -MockWith { $calls.Add("prune $Keep $Current") }
        Mock Get-OllamaModelBlob -ModuleName LocalAI
        Mock Test-ChatModelSpace -ModuleName LocalAI -MockWith { $calls.Add('space') }
        Mock Undo-OpenWebUIUpdate -ModuleName LocalAI -MockWith {
            $calls.Add('undo')
            'Open WebUI 0.12.3 on Python 3.11.17 is installed again.'
        }
        Mock Stop-StartedLocalAIService -ModuleName LocalAI -MockWith {
            $calls.Add("stop $Name")
            'stopped'
        }
        Mock Remove-SupersededAlias -ModuleName LocalAI -MockWith { $calls.Add('superseded') }
    }

    It 'asks, stops the stack, runs the planned steps in order, checks the stack, offers the superseded aliases and stops it again' {
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        # What ran before is read before the stop, and the programs the stop missed are looked for after it. The offer comes before the stop at the end,
        # which may quit the Ollama app.
        @($calls) | Should -Be @('awake True', 'plan Tools=False', 'ask Update these now?', 'running', 'stop', 'busy', 'webui', 'comfy', 'start NoBrowser=True',
            'smoke 0.12.4', 'prune 3 C:\b\open-webui-1', 'superseded', 'stop', 'awake False')
        Should -Invoke Remove-SupersededAlias -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Url -eq 'http://127.0.0.1:11434' }
        $run.Printed | Should -BeLike ('*Update plan:*Open WebUI: 0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12, after a backup of its data*' +
            'ComfyUI: commit e087 (branch master) -> v0.42.5 (483d)*')
        $run.Printed | Should -BeLike "*Open WebUI's data is backed up to $($paths.Backups) first*"
        $run.Printed | Should -BeLike ('*Updated:*Open WebUI: 0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12.16*ComfyUI: e087 -> v0.42.5 (483d), torch 2.14.1+cu130*' +
            'Update finished; everything matches its pin.*')
        Should -Invoke Get-BusyProcess -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            ($Folder -join '|') -eq "C:\uv\tools\open-webui|$($settings.ComfyUI.Dir)" -and ($File -join '|') -eq 'C:\uv\bin\open-webui.exe'
        }
        Should -Invoke Update-OpenWebUITool -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ToolDir -eq 'C:\uv\tools' -and $Plan.Name -eq 'OpenWebUI' }
    }

    It "says in the plan how ComfyUI's venv is made anew only when the plan makes it anew" {
        $text = ("ComfyUI's new venv gets the same pinned packages, from uv's cache where it holds them. The old venv is moved aside to " +
            "$($settings.ComfyUI.Dir).local-ai-old-venv and deleted once the new one passes the torch check, or put back when it does not. Models, input, output, " +
            'user and custom_nodes stay; packages added to the venv by hand are not carried over.')
        (Invoke-UpdateVerb -Context $context).Printed | Should -Not -BeLike "*ComfyUI's new venv*"
        $world.Plan.Components[1].Rebuild = $true
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*Update plan:*ComfyUI: commit e087*$text*"
    }

    It 'leaves the whole stack running when it ran before, as Open WebUI was started against what the check started besides' {
        $world.Running = @('OpenWebUI')
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = @{ Pid = 1 }; ComfyUI = @{ Pid = 2 } } }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'stop*' }) | Should -Be @('stop')
        $run.Printed | Should -BeLike '*The stack ran before the update, so what the check started stays running.*'
        Should -Invoke Stop-StartedLocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'keeps the new Open WebUI and its backup when the check could not start it, as when Ollama did not answer after its upgrade' {
        $world.Launch = $false
        Mock Start-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add('start')
            throw 'Ollama did not answer at http://127.0.0.1:11434 within 60 s.'
        }
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @() }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        Should -Invoke Undo-OpenWebUIUpdate -ModuleName LocalAI -Times 0 -Exactly
        $calls | Should -Not -Contain 'undo'
        @($calls | Where-Object { $_ -like 'prune*' }).Count | Should -Be 0
        $run.Printed | Should -BeLike ('*Update failed: The check did not get to start Open WebUI 0.12.4: Ollama did not answer at http://127.0.0.1:11434 within 60 s. ' +
            "Unable to connect to the remote server. It stays installed, its data is unchanged and the backup C:\b\open-webui-1 stays; fix that, then run 'local-ai start'.*")
        $run.Printed | Should -BeLike '*Updated:*Open WebUI: 0.12.3 on Python 3.11.17 -> 0.12.4 on Python 3.12.16*'
    }

    It 'checks the space in the model store before the model step pulls' {
        $world.Plan.Components = @((Get-TestPlanPart -Name 'Model' -Changes 'weights a -> b'))
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { @('space', 'model') -contains $_ }) | Should -Be @('space', 'model')
        Should -Invoke Get-OllamaModelBlob -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq $settings.Model.Source }
        Should -Invoke Test-ChatModelSpace -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Settings.Model.Alias -eq 'local-chat' }
    }

    It 'counts a warning that the check repeats as one' {
        $world.Plan.Components = @((Get-TestPlanPart -Name 'Model' -Changes 'alias old -> local-chat'))
        Mock Start-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add('start')
            Write-Warning 'Files.Root is not served.' -WarningAction SilentlyContinue
            Write-Warning 'Files.Root is not served.'
            2
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Update finished with 1 warning(s); see above.*'
    }

    It 'says everything matches its pin and stops nothing when no part differs, still offering the superseded aliases' {
        $world.Plan.Components = @((Get-TestPlanPart -Name 'OpenWebUI' -Extra @{ Reinstall = $false; Tool = $webTool }), (Get-TestPlanPart -Name 'Model'))
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Everything matches its pin.*'
        @($calls) | Should -Be @('awake True', 'plan Tools=False', 'superseded', 'awake False')
    }

    It 'returns 2 when nothing differs but the plan warned' {
        $world.Plan.Components = @((Get-TestPlanPart -Name 'Model'))
        Mock Get-LocalAIUpdatePlan -ModuleName LocalAI -MockWith {
            Write-Warning 'ComfyUI: install has not set up ComfyUI, so update leaves it out.'
            $world.Plan
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike '*install has not set up ComfyUI*'
    }

    It 'changes nothing and returns 2 when the answer is no' {
        $world.Yes = $false
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Nothing was changed, so the parts above still differ from their pins.*'
        $calls | Should -Not -Contain 'stop'
        Should -Invoke Update-OpenWebUITool -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'changes nothing and returns 1, naming the problem, when a part cannot be updated' {
        $world.Plan.Components[1].Problem = 'The tag v0.42.5 at https://github.com/Comfy-Org/ComfyUI.git names commit ffff, so the tag has moved.'
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*ComfyUI: The tag v0.42.5 at https://github.com/Comfy-Org/ComfyUI.git names commit ffff, so the tag has moved.*Update changed nothing.*'
        Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Stop-LocalAI -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'refuses before planning when install-stamp.json records no <Key>' -ForEach @(
        @{ Key = 'OpenWebUI' }
        @{ Key = 'Model' }
        @{ Key = 'Ollama' }
    ) {
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp.Remove($Key)
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*install-stamp.json does not record $Key, so there is nothing to update yet. Run 'local-ai install' first.*"
        Should -Invoke Get-LocalAIUpdatePlan -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'changes nothing and returns 1 when the stack cannot be stopped' {
        $world.Stop = 1
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Update changed nothing, because not everything the launcher runs could be stopped*'
        Should -Invoke Update-OpenWebUITool -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-LocalAI -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'changes nothing while a program the launcher did not start runs from what it would replace, and starts the stack again when it ran before' {
        $world.Running = @('OpenWebUI')
        $world.Busy = @([pscustomobject]@{ Id = 7950; Name = 'python'; Path = 'C:\uv\tools\open-webui\Scripts\python.exe' })
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike ('*Update changed nothing: python (PID 7950, C:\uv\tools\open-webui\Scripts\python.exe) still run from what it would replace*' +
            'another program may have started them*')
        Should -Invoke Update-OpenWebUITool -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-LocalAI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Context.NoBrowser }
    }

    It 'checks the stack after a failed step, skips the later steps and returns 1' {
        $world.Plan.Components = @(
            (Get-TestPlanPart -Name 'ComfyUI' -Changes 'commit e087 -> v0.42.5' -Extra @{ Dir = $settings.ComfyUI.Dir; Migrate = $true })
            (Get-TestPlanPart -Name 'Files' -Changes 'mcpo Files.McpoVersion 0.0.19 -> 0.0.20')
        )
        Mock Update-ComfyUICheckout -ModuleName LocalAI -MockWith {
            $calls.Add('comfy')
            throw 'Cannot move C:\ComfyUI to v0.42.5: git refused.'
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $calls | Should -Not -Contain 'files'
        $calls | Should -Contain 'smoke 0.12.3'
        $calls | Should -Not -Contain 'superseded'
        $run.Printed | Should -BeLike '*Error: Cannot move C:\ComfyUI to v0.42.5: git refused.*Update failed: Cannot move C:\ComfyUI to v0.42.5: git refused.*'
    }

    It 'rolls Open WebUI back when it fails the check, starts the stack again when it ran before, and returns 1' {
        $world.Running = @('OpenWebUI')
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @() }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        @($calls | Where-Object { $_ -like 'start*' -or $_ -eq 'undo' }) | Should -Be @('start NoBrowser=True', 'undo', 'start NoBrowser=True')
        $run.Printed | Should -BeLike ('*Update failed: Open WebUI 0.12.4 failed the check after the update: Unable to connect to the remote server. Open WebUI 0.12.3 ' +
            'on Python 3.11.17 is installed again.*')
        $run.Printed | Should -Not -BeLike '*0.12.4 on Python 3.12.16*'
        $run.Printed | Should -Not -BeLike '*did not start again*'
        Should -Invoke Undo-OpenWebUIUpdate -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Change.Backup -eq 'C:\b\open-webui-1' }
        $calls | Should -Not -Contain 'superseded'
        @($calls | Where-Object { $_ -like 'prune*' }).Count | Should -Be 0
    }

    It 'skips the optional services when the start failed for Open WebUI, which stops them again, and says the start stopped with an error' {
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @('ComfyUI fails the check after the update: Unable to connect to the remote server') }
        Mock Start-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add('start')
            $Context.Launched.Add('OpenWebUI')
            1
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Warnings | Should -Not -BeLike '*ComfyUI fails the check*'
        $run.Printed | Should -BeLike '*Open WebUI fails the check: Unable to connect to the remote server. The start stopped with the error shown above. Putting back 0.12.3...*'
        $run.Printed | Should -BeLike '*The other services were not checked, since the start stops them again when Open WebUI does not come up.*'
        $run.Printed | Should -BeLike ('*Update failed: Open WebUI 0.12.4 failed the check after the update: Unable to connect to the remote server. The start stopped with ' +
            'the error shown above. Open WebUI 0.12.3 on Python 3.11.17 is installed again.*')
        Should -Invoke Undo-OpenWebUIUpdate -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'still warns about the optional services when the start went through but Open WebUI fails the check' {
        $world.Plan.Components = @((Get-TestPlanPart -Name 'ComfyUI' -Changes 'commit e087 -> v0.42.5' -Extra @{ Dir = $settings.ComfyUI.Dir }))
        $world.Smoke = @{ OpenWebUI = 'it answers as Open WebUI 0.12.2, not 0.12.3.'; Problems = @('Image gate fails the check after the update: it did not answer.') }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Warnings | Should -BeLike '*Image gate fails the check after the update: it did not answer.*'
        $run.Printed | Should -BeLike '*Update failed: Open WebUI fails the check after the update: it answers as Open WebUI 0.12.2, not 0.12.3.*'
        $run.Printed | Should -Not -BeLike '*The start stopped with the error shown above.*'
    }

    It 'says so when the stack that ran before does not start again after the rollback' {
        $world.Running = @('OpenWebUI')
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @() }
        $world.Starts = 0
        Mock Start-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add('start')
            $world.Starts++
            if ($world.Starts -eq 1) { $Context.Launched.Add('OpenWebUI'); 0 } else { 1 }
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        @($calls | Where-Object { $_ -eq 'start' -or $_ -eq 'undo' }) | Should -Be @('start', 'undo', 'start')
        $run.Printed | Should -BeLike ("*is installed again. The stack, which ran before the update, did not start again after the rollback; see above, then run 'local-ai start'.*")
    }

    It 'says so when starting the stack again after the rollback throws' {
        $world.Running = @('OpenWebUI')
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @() }
        $world.Starts = 0
        Mock Start-LocalAI -ModuleName LocalAI -MockWith {
            $world.Starts++
            if ($world.Starts -eq 1) { $Context.Launched.Add('OpenWebUI'); 0 } else { throw 'Ollama did not answer.' }
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Could not start the stack again: Ollama did not answer.*did not start again after the rollback*'
    }

    It 'rolls back nothing when Open WebUI fails the check but this update left it alone' {
        $world.Plan.Components = @((Get-TestPlanPart -Name 'ComfyUI' -Changes 'commit e087 -> v0.42.5' -Extra @{ Dir = $settings.ComfyUI.Dir }))
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @() }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        Should -Invoke Undo-OpenWebUIUpdate -ModuleName LocalAI -Times 0 -Exactly
        $run.Printed | Should -BeLike '*Update failed: Open WebUI fails the check after the update: Unable to connect to the remote server*'
    }

    It 'returns 2 and warns when an optional service fails the check' {
        $world.Smoke = @{ OpenWebUI = $null; Problems = @('ComfyUI fails the check after the update: ComfyUI reports cpu (type cpu), not a CUDA GPU.') }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike '*ComfyUI fails the check after the update*'
        $run.Printed | Should -BeLike '*Update finished with 1 warning(s); see above.*'
    }

    It 'reinstalls the file tools, the model and the checkpoint and records each' {
        $world.Plan.Components = @(
            (Get-TestPlanPart -Name 'Files' -Changes 'files server 2.0.0 -> 2.0.1')
            (Get-TestPlanPart -Name 'Model' -Changes 'alias old -> local-chat')
            (Get-TestPlanPart -Name 'Checkpoint' -Changes 'missing -> downloaded')
        )
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp['Files'] = @{ McpoVersion = '0.0.19'; ServerVersion = '2.0.0' }
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { @('files', 'model', 'checkpoint') -contains $_ }) | Should -Be @('files', 'model', 'checkpoint')
        Should -Invoke Install-FilesServer -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Recorded.McpoVersion -eq '0.0.19' }
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp.Files.McpoVersion | Should -Be '0.0.20'
        $stamp.Model.BaseDigest | Should -Be ('a' * 64)
        $stamp.Model.ModelfileSha256 | Should -Be ('c' * 64)
        $stamp.Images.File | Should -Be $settings.Images.File
        $stamp.Images.Sha256 | Should -Be $settings.Images.Sha256
        (Read-LocalAIState -Path $paths.State).Images.VerifiedFiles[('d' * 64)].WriteTicks | Should -Be 2
        $run.Printed | Should -BeLike ("*File tools: mcpo 0.0.19 -> 0.0.20, files server 2.0.0 -> 2.0.1*Model: local-chat on $('a' * 64), from C:\repo\local-chat.Modelfile*" +
            "Checkpoint: $($settings.Images.File), checked against Images.Sha256*")
    }

    It 'with -Tools upgrades the planned packages in order, Ollama last, and records the Ollama version' {
        $context.Tools = $true
        $world.Plan.Components = @((Get-TestPlanPart -Name 'Model'))
        $world.Plan.Tools = @(
            @{ Name = 'Uv'; Display = 'uv'; Package = $settings.Winget.Packages.Uv; Upgrade = @{ Installed = '0.13.5'; Available = '0.13.6' } }
            @{ Name = 'Ollama'; Display = 'Ollama'; Package = $settings.Winget.Packages.Ollama; Upgrade = @{ Installed = '0.40.11'; Available = '0.40.12' } }
        )
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'winget*' -or $_ -like 'plan*' }) | Should -Be @('plan Tools=True', 'winget astral-sh.uv', 'winget Ollama.Ollama')
        (Read-LocalAIState -Path $paths.InstallStamp).Ollama.Version | Should -Be '0.40.12'
        $run.Printed | Should -BeLike '*uv: 0.13.5 -> 0.13.6, with winget upgrade astral-sh.uv*Upgrading Ollama last*Updated:*uv: 0.13.5 -> 0.13.6*Ollama: 0.40.11 -> 0.40.12*'
        $run.Warnings | Should -BeLike "*Ollama's installer stops the Ollama app in the tray*"
    }

    It 'lets the PC sleep again when it throws' {
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { throw 'Ollama did not answer' }
        { Update-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage 'Ollama did not answer'
        @($calls) | Should -Be @('awake True', 'awake False')
    }

    It 'stops the stack without Ollama before updating, and afterwards, when the stack did not run before, <Case>' -ForEach @(
        @{ Case = 'keeps an Ollama that answered at once'; Started = $false; Keep = 'True' }
        @{ Case = 'quits the Ollama its own wait started'; Started = $true; Keep = 'False' }
    ) {
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $null; Started = $Started } }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("stop KeepOllama=$([bool]$KeepOllama)")
            0
        }
        (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'stop*' }) | Should -Be @('stop KeepOllama=True', "stop KeepOllama=$Keep")
    }

    It 'records at once the Ollama app its first wait started, as start does' {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'update' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $app; Started = $true } }
        $world.Plan.Components = @((Get-TestPlanPart -Name 'Model' -Changes 'weights a -> b'))
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("stop KeepOllama=$([bool]$KeepOllama) app=$((Read-LocalAIState -Path $paths.State).Ollama.App.Pid)")
            0
        }
        (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $PassThru -and $How -eq 'update' }
        $ollama = (Read-LocalAIState -Path $paths.State).Ollama
        $ollama.App.Pid | Should -Be 100
        $ollama.Alias | Should -Be 'local-chat'
        # Recorded before the stop before the update, and quit by the stop at its end.
        @($calls | Where-Object { $_ -like 'stop*' }) | Should -Be @('stop KeepOllama=True app=100', 'stop KeepOllama=False app=100')
    }

    It 'offers the superseded aliases before the stop at its end quits the Ollama app its first wait started, while Ollama still answers' {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'update' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $app; Started = $true } }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("stop KeepOllama=$([bool]$KeepOllama)")
            0
        }
        (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'stop*' -or $_ -eq 'superseded' }) | Should -Be @('stop KeepOllama=True', 'superseded', 'stop KeepOllama=False')
    }

    It 'leaves the recorded Url and Alias for the stop before the update when Ollama answered without a start' {
        # The stack still runs with the alias settings.psd1 named before; the stop before the update must unload that one.
        Write-LocalAIState -Path $paths.State -State @{ Services = @{}; Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'old-chat'; App = $null } }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("stop KeepOllama=$([bool]$KeepOllama) alias=$((Read-LocalAIState -Path $paths.State).Ollama.Alias)")
            0
        }
        (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'stop*' })[0] | Should -Be 'stop KeepOllama=True alias=old-chat'
    }

    It 'quits the Ollama app its first wait started when it ends early <Case>, as Ollama did not run before' -ForEach @(
        @{ Case = 'with everything at its pin'; Setup = 'pin'; Code = 0 }
        @{ Case = 'on a declined plan'; Setup = 'declined'; Code = 2 }
        @{ Case = 'on a part it cannot update'; Setup = 'blocked'; Code = 1 }
        @{ Case = 'when a program it did not start runs from what it would replace'; Setup = 'busy'; Code = 1 }
    ) {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'update' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $app; Started = $true } }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("stop KeepOllama=$([bool]$KeepOllama)")
            0
        }
        switch ($Setup) {
            'pin' { $world.Plan.Components = @((Get-TestPlanPart -Name 'Model')) }
            'declined' { $world.Yes = $false }
            'blocked' { $world.Plan.Components[1].Problem = 'The tag v0.42.5 has moved.' }
            'busy' { $world.Busy = @([pscustomobject]@{ Id = 7950; Name = 'python'; Path = 'C:\uv\tools\open-webui\Scripts\python.exe' }) }
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @($Code)
        $run.Printed | Should -BeLike '*Quitting the Ollama app update started, since Ollama did not run before the update...*'
        @($calls | Where-Object { $_ -like 'stop*' })[-1] | Should -Be 'stop KeepOllama=False'
        @($calls)[-1] | Should -Be 'awake False'
    }

    It 'waits for no Ollama, and so starts no Ollama app, when install-stamp.json records no Ollama' {
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp.Remove('Ollama')
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*install-stamp.json does not record Ollama, so there is nothing to update yet. Run 'local-ai install' first.*"
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Stop-LocalAI -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'returns <Code> when the Ollama app its first wait started cannot be quit <Case>' -ForEach @(
        @{ Case = 'after everything matched its pin, as that is a warning'; Setup = 'pin'; Quit = 'fails'; Code = 2
            Warning = "The Ollama app update started could not be quit; see above, then run 'local-ai stop'." }
        @{ Case = 'because the stop throws, after everything matched its pin'; Setup = 'pin'; Quit = 'throws'; Code = 2
            Warning = "The Ollama app update started could not be quit: state.json is not valid JSON. Run 'local-ai stop'." }
        @{ Case = 'on a declined plan, which already returns 2'; Setup = 'declined'; Quit = 'fails'; Code = 2
            Warning = "The Ollama app update started could not be quit; see above, then run 'local-ai stop'." }
        @{ Case = 'on a part it cannot update, which stays a failure'; Setup = 'blocked'; Quit = 'fails'; Code = 1
            Warning = "The Ollama app update started could not be quit; see above, then run 'local-ai stop'." }
    ) {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'update' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $app; Started = $true } }
        if ($Quit -eq 'throws') { Mock Stop-LocalAI -ModuleName LocalAI -MockWith { throw 'state.json is not valid JSON.' } } else { $world.Stop = 1 }
        switch ($Setup) {
            'pin' { $world.Plan.Components = @((Get-TestPlanPart -Name 'Model')) }
            'declined' { $world.Yes = $false }
            'blocked' { $world.Plan.Components[1].Problem = 'The tag v0.42.5 has moved.' }
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @($Code)
        $run.Printed | Should -BeLike '*Quitting the Ollama app update started, since Ollama did not run before the update...*'
        $run.Warnings | Should -BeExactly $Warning
        Should -Invoke Stop-LocalAI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { -not $KeepOllama }
        @($calls)[-1] | Should -Be 'awake False'
    }

    It 'leaves the Ollama app its first wait started running when it ends early while the stack runs' {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'update' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $app; Started = $true } }
        $world.Plan.Components = @((Get-TestPlanPart -Name 'Model'))
        $world.Running = @('OpenWebUI')
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        Should -Invoke Stop-LocalAI -ModuleName LocalAI -Times 0 -Exactly
        $run.Printed | Should -Not -BeLike '*Quitting the Ollama app*'
    }

    It 'quits the Ollama app its first wait started also when it throws, and still lets the PC sleep' {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'update' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $app; Started = $true } }
        Mock Get-LocalAIUpdatePlan -ModuleName LocalAI -MockWith { throw 'git is not on PATH' }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith { throw 'state.json is not valid JSON.' }
        $warnings = $null
        $failure = $null
        try {
            $null = Update-LocalAI -Context $context -WarningVariable warnings 3>$null 6>$null
        } catch {
            $failure = $_.Exception.Message
        }
        $failure | Should -Be 'git is not on PATH'
        Should -Invoke Stop-LocalAI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { -not $KeepOllama }
        @($warnings | Where-Object { "$_" -like "*The Ollama app update started could not be quit: state.json is not valid JSON. Run 'local-ai stop'.*" }).Count | Should -Be 1
        @($calls)[-1] | Should -Be 'awake False'
    }

    It 'stops the stack and the Ollama app its first wait started after a rollback, when the stack did not run before' {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'update' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.12'; App = $app; Started = $true } }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("stop KeepOllama=$([bool]$KeepOllama)")
            0
        }
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @() }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        @($calls | Where-Object { $_ -like 'stop*' -or $_ -like 'start*' -or $_ -eq 'undo' }) |
            Should -Be @('stop KeepOllama=True', 'start NoBrowser=True', 'undo', 'stop KeepOllama=False')
        $run.Printed | Should -BeLike '*Stopping the stack again, since it did not run before the update...*'
        $run.Printed | Should -Not -BeLike '*Quitting the Ollama app*'
    }

    Context 'when -Tools upgrades Ollama' {
        BeforeEach {
            $context.Tools = $true
            $world.Plan.Components = @((Get-TestPlanPart -Name 'Model'))
            $world.Plan.Tools = @(@{ Name = 'Ollama'; Display = 'Ollama'; Package = $settings.Winget.Packages.Ollama; Upgrade = @{ Installed = '0.40.11'; Available = '0.40.12' } })
            $appExe = 'C:\Users\User\AppData\Local\Programs\Ollama\ollama app.exe'
            $recorded = @{ Pid = 100; StartTicks = 111; Path = $appExe; Port = 11434; StartedTicks = 110; How = 'start' }
            Write-LocalAIState -Path $paths.State -State @{ Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat'; App = $recorded } }
            # The installer ends the recorded app and starts another, which Win32_Process lists from then on.
            $apps = @{ List = @([pscustomobject]@{ Id = 100; Path = $appExe; StartTicks = [DateTime]::UtcNow.AddMinutes(-30).Ticks; ParentId = 9 }); Upgraded = $false }
            Mock Get-OllamaAppProcess -ModuleName LocalAI -MockWith { $apps.List }
            Mock Update-WingetPackage -ModuleName LocalAI -MockWith {
                $calls.Add("winget $($Package.Id)")
                $apps.Upgraded = $true
                $apps.List = @([pscustomobject]@{ Id = 300; Path = $appExe; StartTicks = [DateTime]::UtcNow.Ticks; ParentId = 9 })
                'upgraded'
            }
            # Before the upgrade the recorded app matches its record; after it, the app whose PID Recorded holds matches: its replacement, or one the wait started.
            $apps.Runs = $true
            $apps.Recorded = 300
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith {
                if (([int]$Record.Pid -eq 100 -and $apps.Runs -and -not $apps.Upgraded) -or ([int]$Record.Pid -eq $apps.Recorded -and $apps.Upgraded)) { 'match' } else { 'other' }
            }
            Mock Resolve-OllamaAppPath -ModuleName LocalAI -MockWith { $appExe }
            Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
            Mock Get-PortOwner -ModuleName LocalAI -MockWith { [pscustomobject]@{ Id = 301; Name = 'ollama'; Path = 'C:\Ollama\ollama.exe'; StartTicks = 5 } }
            Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $ProcessId -eq 301 -and $AncestorId -eq 300 -and $MaxDepth -eq 1 }
        }

        It 'records the app the Ollama installer starts again when the app local-ai started ran until the upgrade' {
            $run = Invoke-UpdateVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike '*The Ollama installer started the Ollama app again (PID 300); local-ai stop quits it.*'
            $app = (Read-LocalAIState -Path $paths.State).Ollama.App
            $app.Pid | Should -Be 300
            $app.How | Should -Be 'update'
            $app.Listener.Pid | Should -Be 301
            (Read-LocalAIState -Path $paths.InstallStamp).Ollama.Version | Should -Be '0.40.12'
        }

        It 'records no app after the upgrade when the recorded app no longer ran before it' {
            $apps.Runs = $false
            (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
            (Read-LocalAIState -Path $paths.State).Ollama.App | Should -BeNullOrEmpty
            Should -Invoke Get-OllamaAppProcess -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'records the app its wait after the upgrade started, in place of the app local-ai started' {
            $started = @{ Pid = 310; StartTicks = 333; Path = $appExe; Port = 11434; StartedTicks = 330; How = 'update' }
            $apps.Recorded = 310
            $waits = @{ Count = 0 }
            Mock Wait-OllamaServer -ModuleName LocalAI -MockWith {
                $waits.Count++
                $own = if ($waits.Count -eq 2) { $started } else { $null }
                [pscustomobject]@{ Version = '0.40.12'; App = $own; Started = $null -ne $own }
            }
            (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
            (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 310
        }

        It 'records no app its wait after the upgrade started when the app before it was not local-ai''s, and says stop leaves it running' {
            Write-LocalAIState -Path $paths.State -State @{ Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat'; App = $null } }
            $started = @{ Pid = 310; StartTicks = 333; Path = $appExe; Port = 11434; StartedTicks = 330; How = 'update' }
            $waits = @{ Count = 0 }
            Mock Wait-OllamaServer -ModuleName LocalAI -MockWith {
                $waits.Count++
                $own = if ($waits.Count -eq 2) { $started } else { $null }
                [pscustomobject]@{ Version = '0.40.12'; App = $own; Started = $null -ne $own }
            }
            Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
                $calls.Add("stop KeepOllama=$([bool]$KeepOllama)")
                0
            }
            $run = Invoke-UpdateVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*The Ollama app local-ai started (PID 310) replaces one that state.json does not record as local-ai's, so local-ai stop leaves it running.*"
            (Read-LocalAIState -Path $paths.State).Ollama.App | Should -BeNullOrEmpty
            Should -Invoke Get-OllamaAppProcess -ModuleName LocalAI -Times 0 -Exactly
            # Ollama answered when update began, so the stop at its end keeps it.
            @($calls | Where-Object { $_ -like 'stop*' })[-1] | Should -Be 'stop KeepOllama=True'
        }

        It 'records no app when another app began beside the one the installer started' {
            Mock Update-WingetPackage -ModuleName LocalAI -MockWith {
                $apps.Upgraded = $true
                $apps.List = @(
                    [pscustomobject]@{ Id = 300; Path = $appExe; StartTicks = [DateTime]::UtcNow.Ticks; ParentId = 9 }
                    [pscustomobject]@{ Id = 302; Path = $appExe; StartTicks = [DateTime]::UtcNow.Ticks; ParentId = 9 }
                )
                'upgraded'
            }
            (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
            (Read-LocalAIState -Path $paths.State).Ollama.App | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-LocalAIFallbackSetting' {
    BeforeAll {
        $defaults = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\defaults.psd1'
    }

    It 'merges every value of settings.psd1 that fits the defaults, expands %VAR% and lists what it skipped' {
        $folder = Join-Path $TestDrive 'fallback-menu'
        $user = Write-TestFile 'fallback\settings.psd1' ("@{ Ports = @{ Bogus = 1; OpenWebUI = 'x' }; Shortcuts = @{ Folder = '$folder' }; " +
            "OpenWebUI = @{ DataDir = '%LOCALAI_TEST_DATA%\owui' }; Model = @{ Alias = 'Not Valid' } }")
        $problems = New-Object System.Collections.Generic.List[string]
        $saved = $env:LOCALAI_TEST_DATA
        try {
            $env:LOCALAI_TEST_DATA = 'D:\Data'
            $settings = Invoke-ModuleFunction 'Get-LocalAIFallbackSetting' @{ DefaultsPath = $defaults; UserPath = $user; Problems = $problems }
        } finally {
            $env:LOCALAI_TEST_DATA = $saved
        }
        $settings.Shortcuts.Folder | Should -Be $folder
        $settings.OpenWebUI.DataDir | Should -Be 'D:\Data\owui'
        # Values of the right kind are taken as they are; Get-LocalAISettings would refuse this one.
        $settings.Model.Alias | Should -Be 'Not Valid'
        $settings.Ports.OpenWebUI | Should -Be 8080
        $settings.Ports.ContainsKey('Bogus') | Should -BeFalse
        $problems.Count | Should -Be 2
        $problems | Should -Contain "Unknown setting 'Ports.Bogus'."
        $problems | Should -Contain "Setting 'Ports.OpenWebUI' = 'x' must be a whole number."
    }

    It 'keeps the defaults, names the file and says it did not load when settings.psd1 does not parse' {
        $user = Write-TestFile 'fallback-broken\settings.psd1' '@{ Ports = @{ OpenWebUI = 18080 '
        $problems = New-Object System.Collections.Generic.List[string]
        $loaded = $true
        $settings = Invoke-ModuleFunction 'Get-LocalAIFallbackSetting' @{ DefaultsPath = $defaults; UserPath = $user; Problems = $problems; UserLoaded = ([ref]$loaded) }
        $settings.Ports.OpenWebUI | Should -Be 8080
        $settings.Shortcuts.Folder | Should -Be ([Environment]::ExpandEnvironmentVariables('%APPDATA%\Microsoft\Windows\Start Menu\Programs\Local AI'))
        $problems.Count | Should -Be 1
        $problems[0] | Should -BeLike "Cannot read settings file '$user'*"
        $loaded | Should -BeFalse
    }

    It 'uses the defaults without a settings.psd1, counting that as loaded' {
        $problems = New-Object System.Collections.Generic.List[string]
        $loaded = $false
        $settings = Invoke-ModuleFunction 'Get-LocalAIFallbackSetting' @{ DefaultsPath = $defaults; UserPath = (Join-Path $TestDrive 'none\settings.psd1'); Problems = $problems
            UserLoaded = ([ref]$loaded) }
        $settings.Model.Alias | Should -Be 'local-chat'
        $problems.Count | Should -Be 0
        $loaded | Should -BeTrue
    }

    It 'counts a settings.psd1 that parses as loaded, also when some values do not merge' {
        $user = Write-TestFile 'fallback-merge\settings.psd1' '@{ Ports = @{ Bogus = 1 } }'
        $problems = New-Object System.Collections.Generic.List[string]
        $loaded = $false
        $null = Invoke-ModuleFunction 'Get-LocalAIFallbackSetting' @{ DefaultsPath = $defaults; UserPath = $user; Problems = $problems; UserLoaded = ([ref]$loaded) }
        $problems.Count | Should -Be 1
        $loaded | Should -BeTrue
    }
}

Describe 'Get-LocalAIRemovalProblem' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $problem = { param([string]$Path, [hashtable]$Keep = @{}) Invoke-ModuleFunction 'Get-LocalAIRemovalProblem' @{ Path = $Path; RepoRoot = $repoRoot; Keep = $Keep } }
    }

    It 'allows an ordinary folder' {
        $folder = Join-Path $TestDrive 'removal\owui'
        $null = New-Item -ItemType Directory -Force -Path $folder
        & $problem $folder | Should -BeNullOrEmpty
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a drive root'; Path = 'C:\'; Expected = 'it is a drive root' }
        @{ Name = 'a relative path'; Path = 'owui'; Expected = 'it is not a full path on a drive letter' }
        @{ Name = 'a share'; Path = '\\server\share\owui'; Expected = 'it is not a full path on a drive letter' }
    ) {
        & $problem $Path | Should -BeExactly $Expected
    }

    It 'refuses %<Variable>% and a folder that holds it' -ForEach @(
        @{ Variable = 'USERPROFILE' }
        @{ Variable = 'LOCALAPPDATA' }
        @{ Variable = 'APPDATA' }
        @{ Variable = 'TEMP' }
    ) {
        $value = [Environment]::GetEnvironmentVariable($Variable, 'Process')
        & $problem $value | Should -BeLike '*it is or holds *'
        & $problem (Split-Path $value -Parent) | Should -BeLike '*it is or holds *'
    }

    It "refuses the shell's own folders, also when a variable points elsewhere" {
        & $problem ([Environment]::GetFolderPath('LocalApplicationData')) | Should -BeLike '*it is or holds *'
        & $problem ([Environment]::GetFolderPath('Windows')) | Should -BeLike '*it is or holds *'
        & $problem (Join-Path $env:USERPROFILE 'Downloads') | Should -BeLike '*it is or holds %USERPROFILE%\Downloads*'
    }

    It 'refuses the repository, a folder that holds it and a folder in it' {
        & $problem $repoRoot | Should -BeLike '*it is or holds the launcher repository*'
        & $problem (Split-Path $repoRoot -Parent) | Should -BeLike '*it is or holds the launcher repository*'
        & $problem (Join-Path $repoRoot 'config') | Should -BeLike '*it lies in the launcher repository*'
    }

    It 'refuses a folder that holds one uninstall keeps, compared without case' {
        $folder = Join-Path $TestDrive 'removal-keep\data'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $folder 'files')
        & $problem $folder @{ 'Files.Root' = (Join-Path $folder 'FILES') } | Should -BeLike '*it is or holds Files.Root, *'
        & $problem (Join-Path $folder 'files') @{ 'Files.Root' = $folder } | Should -BeNullOrEmpty
    }

    It 'refuses a folder with a junction on its path, or that is one' {
        $base = Join-Path $TestDrive 'removal-link'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $base 'Real\data')
        $junction = Join-Path $base 'Via'
        $null = New-Item -ItemType Junction -Path $junction -Target (Join-Path $base 'Real')
        & $problem (Join-Path $junction 'data') | Should -BeLike "$junction on its path is a junction or symbolic link*"
        & $problem $junction | Should -BeLike "$junction on its path is a junction or symbolic link*"
        & $problem (Join-Path $base 'Real\data') | Should -BeNullOrEmpty
    }
}

Describe 'Remove-LocalAIFolder' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $base 'data'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $folder 'sub')
        [IO.File]::WriteAllText((Join-Path $folder 'sub\webui.db'), 'db')
    }

    It 'deletes the folder, removing a junction inside as a link so what it leads to stays' {
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Force -Path $outside
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'mine')
        $null = New-Item -ItemType Junction -Path (Join-Path $folder 'link') -Target $outside
        Invoke-ModuleFunction 'Remove-LocalAIFolder' @{ Path = $folder }
        Test-Path -LiteralPath $folder | Should -BeFalse
        @(Get-ChildItem -LiteralPath $base | ForEach-Object { $_.Name }) | Should -Be @('outside')
        [IO.File]::ReadAllText((Join-Path $outside 'keep.txt')) | Should -Be 'mine'
    }

    It 'leaves the folder whole while a program holds a file in it open' {
        $stream = [IO.File]::Open((Join-Path $folder 'sub\webui.db'), 'Open', 'ReadWrite', 'ReadWrite')
        try {
            { Invoke-ModuleFunction 'Remove-LocalAIFolder' @{ Path = $folder } } |
                Should -Throw -ExpectedMessage "Cannot delete ${folder}: Windows refuses to rename it, as when a program still has a file in it open*Close that program, then try again."
        } finally {
            $stream.Dispose()
        }
        Test-Path -LiteralPath (Join-Path $folder 'sub\webui.db') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $base).Count | Should -Be 1
    }

    It 'says where the rest is when the delete stops part-way' {
        Mock Remove-LocalAITree -ModuleName LocalAI -MockWith { throw "Cannot delete 'x': Access is denied." }
        { Invoke-ModuleFunction 'Remove-LocalAIFolder' @{ Path = $folder } } |
            Should -Throw -ExpectedMessage "Deleting $folder stopped part-way: Cannot delete 'x': Access is denied. What is left is in $folder.local-ai-removing-*; delete it once nothing uses it."
    }

    It 'does nothing for a missing folder' {
        { Invoke-ModuleFunction 'Remove-LocalAIFolder' @{ Path = (Join-Path $base 'missing') } } | Should -Not -Throw
    }
}

Describe 'Invoke-UvToolUninstall and Remove-OllamaModel' {
    BeforeEach {
        $seen = @{ ToolDir = $null; Arguments = $null }
        $savedToolDir = $env:UV_TOOL_DIR
        $env:UV_TOOL_DIR = 'C:\before'
    }

    AfterEach {
        $env:UV_TOOL_DIR = $savedToolDir
    }

    It "runs 'uv tool uninstall' with UV_TOOL_DIR set for that call only" {
        Mock Invoke-Native -ModuleName LocalAI -MockWith {
            $seen.ToolDir = $env:UV_TOOL_DIR
            $seen.Arguments = $ArgumentList -join ' '
            $Capture.Add('Uninstalled 1 executable: open-webui.exe')
            0
        }
        Invoke-ModuleFunction 'Invoke-UvToolUninstall' @{ Name = 'open-webui'; ToolDir = 'C:\uv\tools' } | Should -Be 'removed'
        $seen.ToolDir | Should -Be 'C:\uv\tools'
        $seen.Arguments | Should -Be 'tool uninstall open-webui'
        $env:UV_TOOL_DIR | Should -Be 'C:\before'
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'uv' -and ($SuccessCode -join ',') -eq '0,2' -and $null -ne $Capture }
    }

    It 'returns absent when uv says the tool is not installed' {
        Mock Invoke-Native -ModuleName LocalAI -MockWith { $Capture.Add('error: `mcpo` is not installed'); 2 }
        Invoke-ModuleFunction 'Invoke-UvToolUninstall' @{ Name = 'mcpo'; ToolDir = 'C:\uv\tools' } | Should -Be 'absent'
    }

    It "throws with uv's text on another failure, restoring UV_TOOL_DIR" {
        Mock Invoke-Native -ModuleName LocalAI -MockWith { $Capture.Add('error: failed to remove directory: Access is denied. (os error 5)'); 2 }
        { Invoke-ModuleFunction 'Invoke-UvToolUninstall' @{ Name = 'mcpo'; ToolDir = 'C:\uv\tools' } } |
            Should -Throw -ExpectedMessage "'uv tool uninstall mcpo' failed with exit code 2. uv said: error: failed to remove directory: Access is denied. (os error 5)"
        Mock Invoke-Native -ModuleName LocalAI -MockWith { $Capture.Add('error: boom'); throw "'uv tool uninstall mcpo' failed with exit code 1." }
        { Invoke-ModuleFunction 'Invoke-UvToolUninstall' @{ Name = 'mcpo'; ToolDir = 'C:\uv\tools' } } |
            Should -Throw -ExpectedMessage "'uv tool uninstall mcpo' failed with exit code 1. uv said: error: boom"
        $env:UV_TOOL_DIR | Should -Be 'C:\before'
    }

    It "removes a model with 'ollama rm' and throws with its text, without control sequences, on a failure" {
        Mock Invoke-Native -ModuleName LocalAI -MockWith { 0 }
        Invoke-ModuleFunction 'Remove-OllamaModel' @{ Name = 'local-chat' }
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'ollama' -and ($ArgumentList -join ' ') -eq 'rm local-chat' }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { $Capture.Add("$([char]27)[?25lError: model 'x' not found$([char]27)[K"); throw "'ollama rm x' failed with exit code 1." }
        { Invoke-ModuleFunction 'Remove-OllamaModel' @{ Name = 'x' } } | Should -Throw -ExpectedMessage "'ollama rm x' failed with exit code 1. ollama said: Error: model 'x' not found"
    }
}

Describe 'Uninstall-LocalAI' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $shortcutNames = @('Start Local AI.lnk', 'Stop Local AI.lnk', 'Status Local AI.lnk', 'Update Local AI.lnk')

        # Run Uninstall-LocalAI and return @{ Code; Printed; Warnings } with the host text and the warnings joined.
        function Invoke-UninstallVerb([hashtable]$Context) {
            $output = @(Uninstall-LocalAI -Context $Context 3>&1 6>&1)
            return @{
                Code     = @($output | Where-Object { $_ -is [int] })
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
            }
        }

        # Lay out what install leaves, all below TestDrive: the four shortcuts, the open-webui and mcpo tool folders in $ToolDir, a ComfyUI checkout (marked as cloned
        # when $Cloned) whose venv marker records $CreatedVenv ($null: no marker), the file tools' files, Open WebUI's data, a file in Files.Root, state.json and the stamp.
        function Write-TestInstall([hashtable]$Settings, [hashtable]$Paths, [string]$ToolDir, [bool]$Cloned, $CreatedVenv, [bool]$NodeByLauncher) {
            $folder = $Settings.Shortcuts.Folder
            $null = New-Item -ItemType Directory -Force -Path $folder
            foreach ($name in $shortcutNames) { [IO.File]::WriteAllText((Join-Path $folder $name), 'lnk') }
            foreach ($tool in 'open-webui', 'mcpo') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $ToolDir "$tool\Scripts") }
            $dir = $Settings.ComfyUI.Dir
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir '.git'), (Join-Path $dir '.venv\Scripts'), (Join-Path $dir 'models\checkpoints')
            [IO.File]::WriteAllText((Join-Path $dir 'main.py'), 'print()')
            [IO.File]::WriteAllText((Join-Path $dir 'models\checkpoints\model.safetensors'), 'weights')
            if ($Cloned) { Write-LocalAIState -Path (Join-Path $dir '.git\local-ai-clone.json') -State @{ Kind = 'local-ai-clone' } }
            if ($null -ne $CreatedVenv) { Write-LocalAIState -Path (Join-Path $dir '.venv\local-ai-install.json') -State @{ CreatedVenv = $CreatedVenv; Torch = '2.14.1+cu130' } }
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $Paths.FilesServer 'node_modules'), (Join-Path $Paths.Root 'image-gate'), (Join-Path $Paths.Root 'mcpo'), $Paths.Logs
            [IO.File]::WriteAllText($Paths.FilesKey, ('a' * 64))
            [IO.File]::WriteAllText($Paths.McpoConfig, '{}')
            [IO.File]::WriteAllText((Join-Path $Paths.Logs 'open-webui.log'), 'log')
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $Settings.OpenWebUI.DataDir 'uploads'), $Settings.Files.Root
            [IO.File]::WriteAllText((Join-Path $Settings.OpenWebUI.DataDir 'webui.db'), 'database')
            [IO.File]::WriteAllText((Join-Path $Settings.OpenWebUI.DataDir 'uploads\notes.txt'), 'notes')
            [IO.File]::WriteAllText((Join-Path $Settings.Files.Root 'doc.txt'), 'mine')
            Write-LocalAIState -Path $Paths.State -State @{ Services = @{}; Model = @{ Source = $Settings.Model.Source } }
            Write-LocalAIState -Path $Paths.InstallStamp -State @{
                Ollama    = @{ Version = '0.40.11' }
                Model     = @{ Alias = 'local-chat' }
                OpenWebUI = @{ Version = '0.12.4'; Python = '3.12.16'; Path = (Join-Path (Split-Path $ToolDir -Parent) 'bin\open-webui.exe') }
                Files     = @{ McpoVersion = '0.0.20'; McpoPath = (Join-Path (Split-Path $ToolDir -Parent) 'bin\mcpo.exe'); ToolDir = $ToolDir }
                ComfyUI   = @{ Dir = $dir; Cloned = $Cloned; Python = (Join-Path $dir '.venv\Scripts\python.exe') }
                Images    = @{ File = 'model.safetensors' }
                Node      = @{ InstalledByLauncher = $NodeByLauncher }
            }
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root (Join-Path $root 'local-ai')
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Shortcuts.Folder = Join-Path $root 'Start Menu\Local AI'
        $settings.ComfyUI.Dir = Join-Path $root 'ComfyUI'
        $settings.OpenWebUI.DataDir = Join-Path $root 'open-webui'
        $settings.Files.Root = Join-Path $root 'files'
        # Every folder uninstall may touch lies in TestDrive.
        foreach ($value in $settings.Shortcuts.Folder, $settings.ComfyUI.Dir, $settings.OpenWebUI.DataDir, $settings.Files.Root, $paths.Root) {
            if (-not $value.StartsWith($TestDrive)) { throw "The test path $value lies outside TestDrive." }
        }
        $toolDir = Join-Path $root 'uv\tools'
        $source = $settings.Model.Source
        $context = @{ Verb = 'uninstall'; Paths = $paths; Settings = $settings; SettingsError = $null; RepoRoot = $repoRoot; RemoveData = $false }
        $world = @{ Answers = New-Object System.Collections.Generic.Queue[bool]; Stop = 0; Running = @(); Busy = @{}; UvAbsent = @(); Listed = @('local-chat:latest', "${source}") }
        $questions = New-Object System.Collections.Generic.List[string]
        $calls = New-Object System.Collections.Generic.List[string]
        Mock Update-SessionPath -ModuleName LocalAI
        Mock Confirm-LocalAIAction -ModuleName LocalAI -MockWith {
            $questions.Add($Question)
            if ($world.Answers.Count -gt 0) { $world.Answers.Dequeue() } else { $false }
        }
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add('stop')
            $world.Stop
        }
        Mock Get-LocalAIRunningService -ModuleName LocalAI -MockWith { $world.Running }
        Mock Get-BusyProcess -ModuleName LocalAI -MockWith {
            foreach ($item in $Folder) { if ($world.Busy.ContainsKey($item)) { [pscustomobject]@{ Name = 'python'; Id = $world.Busy[$item]; Path = "$item\python.exe" } } }
        }
        Mock Get-UvToolDir -ModuleName LocalAI -MockWith { Join-Path $root 'uv\elsewhere' }
        Mock Get-Command -ModuleName LocalAI -ParameterFilter { @('uv', 'ollama') -contains $Name } -MockWith { [pscustomobject]@{ Name = "$Name.exe"; Path = "C:\x\$Name.exe" } }
        Mock Resolve-OllamaUrl -ModuleName LocalAI -MockWith { 'http://127.0.0.1:11434' }
        Mock Assert-OllamaCliUrl -ModuleName LocalAI
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith {
            $calls.Add('ollama up')
            if ($PassThru) { [pscustomobject]@{ Version = '0.40.11'; App = $null } } else { '0.40.11' }
        }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected call: $FilePath $($ArgumentList -join ' ')" }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'uv' } -MockWith {
            $calls.Add("uv $env:UV_TOOL_DIR|$($ArgumentList -join ' ')")
            $name = $ArgumentList[-1]
            if ($world.UvAbsent -contains $name) {
                $Capture.Add("error: ``$name`` is not installed")
                return 2
            }
            Remove-Item -LiteralPath (Join-Path $env:UV_TOOL_DIR $name) -Recurse -Force
            $Capture.Add("Uninstalled 1 executable: $name.exe")
            0
        }
        Mock Invoke-Native -ModuleName LocalAI -ParameterFilter { $FilePath -eq 'ollama' } -MockWith {
            $calls.Add("ollama $($ArgumentList -join ' ')")
            if ($ArgumentList[0] -eq 'list') {
                $Capture.Add('NAME                  ID              SIZE      MODIFIED')
                foreach ($name in $world.Listed) { $Capture.Add("$name    00e51270919c    8.3 GB    2 days ago") }
            }
            0
        }
    }

    It 'asks once, stops the stack and removes what install set up, keeping the data, Ollama, uv, Git and the base model' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
        $world.Answers.Enqueue($true)
        $world.Running = @('OpenWebUI')
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        @($questions) | Should -Be @('Uninstall these now?')
        $folder = $settings.Shortcuts.Folder
        $run.Printed | Should -BeLike ("*Uninstall removes:*the Start menu shortcuts Start Local AI.lnk, Stop Local AI.lnk, Status Local AI.lnk, Update Local AI.lnk in $folder*" +
            "Open WebUI 0.12.4: the uv tool open-webui in $toolDir\open-webui*mcpo 0.0.20, which serves the file tools: the uv tool mcpo in $toolDir\mcpo*" +
            "ComfyUI's venv $($settings.ComfyUI.Dir)\.venv, which install created*the Ollama model local-chat, which install created from $source, whose weights stay*" +
            'It first stops what the launcher runs: OpenWebUI.*Your data stays:*')
        @($calls) | Should -Be @('stop', "uv $toolDir|tool uninstall open-webui", "uv $toolDir|tool uninstall mcpo", 'ollama up', 'ollama list', 'ollama rm local-chat')
        Test-Path -LiteralPath $folder | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $toolDir 'open-webui') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir '.venv') | Should -BeFalse
        foreach ($gone in $paths.FilesServer, $paths.FilesKey, $paths.McpoConfig, (Join-Path $paths.Root 'image-gate'), (Join-Path $paths.Root 'mcpo')) {
            Test-Path -LiteralPath $gone | Should -BeFalse
        }
        # The data, the checkout with its models, the launcher's folder and Files.Root stay.
        Test-Path -LiteralPath (Join-Path $settings.OpenWebUI.DataDir 'webui.db') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'models\checkpoints\model.safetensors') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $paths.Logs 'open-webui.log') | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $settings.Files.Root 'doc.txt')) | Should -Be 'mine'
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        @($stamp.Keys | Sort-Object) | Should -Be @('ComfyUI', 'Images', 'Node', 'Ollama')
        $stamp.ComfyUI.Cloned | Should -BeTrue
        $run.Printed | Should -BeLike ('*Ollama, uv, Git stay installed. Uninstall each with winget once nothing else needs it:*winget uninstall --id Ollama.Ollama -e*' +
            "winget uninstall --id astral-sh.uv -e*winget uninstall --id Git.Git -e*'ollama rm $source' removes those weights.*Uninstall finished.")
        $run.Printed | Should -Not -BeLike '*OpenJS.NodeJS.LTS*'
        $env:UV_TOOL_DIR | Should -Not -Be $toolDir
    }

    It 'prints the winget command for Node.js only when a launcher install put it in' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $true
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Printed | Should -BeLike '*Ollama, uv, Git, Node.js stay installed.*winget uninstall --id OpenJS.NodeJS.LTS -e*'
    }

    It 'removes nothing and stops nothing when the answer is No' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Nothing was removed.*'
        $calls.Count | Should -Be 0
        foreach ($name in $shortcutNames) { Test-Path -LiteralPath (Join-Path $settings.Shortcuts.Folder $name) | Should -BeTrue }
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir '.venv') | Should -BeTrue
        (Read-LocalAIState -Path $paths.InstallStamp).ContainsKey('OpenWebUI') | Should -BeTrue
    }

    It 'asks nothing and creates nothing when nothing is installed' {
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $questions.Count | Should -Be 0
        $calls.Count | Should -Be 0
        $run.Printed | Should -BeLike '*None of the parts install sets up is left to remove.*Uninstall finished.*'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'removes nothing when the stack cannot be stopped' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $world.Answers.Enqueue($true)
        $world.Stop = 1
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Uninstall removed nothing, because not everything the launcher runs could be stopped*"
        @($calls) | Should -Be @('stop')
        Test-Path -LiteralPath (Join-Path $toolDir 'open-webui') | Should -BeTrue
    }

    It 'keeps a venv that install found in place, and says nothing of one without a marker' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $false -NodeByLauncher $false
        $world.Answers.Enqueue($true)
        $venv = Join-Path $settings.ComfyUI.Dir '.venv'
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*It leaves:*ComfyUI's venv ${venv}: install found it in place, as another program left it, and only installed into it.*"
        Test-Path -LiteralPath $venv | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $venv 'local-ai-install.json')
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Printed | Should -Not -BeLike "*ComfyUI's venv*"
        Test-Path -LiteralPath $venv | Should -BeTrue
    }

    It 'removes the folders an interrupted install left beside and in ComfyUI.Dir' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $null -NodeByLauncher $false
        $clone = $settings.ComfyUI.Dir + '.local-ai-clone'
        $download = Join-Path $settings.ComfyUI.Dir 'models\.local-ai-download'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $clone '.git'), $download
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Printed | Should -BeLike "*$clone, which an interrupted install left*$download, which an interrupted install left*"
        Test-Path -LiteralPath $clone | Should -BeFalse
        Test-Path -LiteralPath $download | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'models\checkpoints\model.safetensors') | Should -BeTrue
    }

    It 'removes the old venv that update moved aside beside ComfyUI.Dir, keeping the checkout and the venv install found in place' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $false -NodeByLauncher $false
        $oldVenv = $settings.ComfyUI.Dir + '.local-ai-old-venv'
        Write-TestPyVenvConfig -Venv $oldVenv -BaseHome $storeHome -Version '3.13.14'
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*ComfyUI's old venv $oldVenv, which update moved aside*"
        Test-Path -LiteralPath $oldVenv | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir '.venv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'models\checkpoints\model.safetensors') | Should -BeTrue
    }

    It 'never removes Model.Source, also when install-stamp.json names it as the alias' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp.Model.Alias = $source
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*$source in Ollama: it is Model.Source itself, which uninstall never removes.*"
        @($calls | Where-Object { $_ -like 'ollama*' }).Count | Should -Be 0
        (Read-LocalAIState -Path $paths.InstallStamp).ContainsKey('Model') | Should -BeTrue
    }

    It 'goes on past a tool that still runs, keeping its stamp entry and returning 1 with what stayed' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $world.Answers.Enqueue($true)
        $world.Busy[(Join-Path $toolDir 'open-webui')] = 4242
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike ("*Could not remove Open WebUI 0.12.4: the uv tool open-webui in $toolDir\open-webui: python (PID 4242) still runs from it*" +
            'Uninstall finished, but these stay:*Open WebUI 0.12.4*PID 4242*')
        Test-Path -LiteralPath (Join-Path $toolDir 'open-webui') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $toolDir 'mcpo') | Should -BeFalse
        @((Read-LocalAIState -Path $paths.InstallStamp).Keys | Sort-Object) | Should -Be @('ComfyUI', 'Images', 'Node', 'Ollama', 'OpenWebUI')
    }

    It 'counts a tool uv does not list as gone, and an alias Ollama does not hold' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $world.Answers.Enqueue($true)
        $world.UvAbsent = @('mcpo')
        $world.Listed = @()
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*uv lists no mcpo in $toolDir, so it removed nothing there.*Ollama holds no local-chat.*"
        @($calls | Where-Object { $_ -like 'ollama rm*' }).Count | Should -Be 0
        (Read-LocalAIState -Path $paths.InstallStamp).ContainsKey('Model') | Should -BeFalse
    }

    It 'finds a recorded tool without a recorded folder where uv puts tools, and leaves one install-stamp.json does not record, naming its command' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir (Join-Path $root 'uv\elsewhere') -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp.Remove('Files')
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'uv *' }) | Should -Be @("uv $root\uv\elsewhere|tool uninstall open-webui")
        $run.Printed | Should -BeLike ("*It leaves:*the uv tool mcpo in $root\uv\elsewhere\mcpo: install-stamp.json does not record it, so uninstall leaves it; " +
            "'uv tool uninstall mcpo' removes it.*")
        Test-Path -LiteralPath (Join-Path $root 'uv\elsewhere\mcpo') | Should -BeTrue
    }

    It 'uninstalls each tool from the folder its install-stamp.json entry records' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $own = Join-Path $root 'uv\own'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $own 'open-webui')
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp.OpenWebUI.ToolDir = $own
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        $world.Answers.Enqueue($true)
        $null = Invoke-UninstallVerb -Context $context
        @($calls | Where-Object { $_ -like 'uv *' }) | Should -Be @("uv $own|tool uninstall open-webui", "uv $toolDir|tool uninstall mcpo")
        Test-Path -LiteralPath (Join-Path $toolDir 'open-webui') | Should -BeTrue
    }

    It 'keeps only Dir and Cloned of the ComfyUI entry once it removed the venv, so status and update see no install' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
        $world.Answers.Enqueue($true)
        $null = Invoke-UninstallVerb -Context $context
        $entry = (Read-LocalAIState -Path $paths.InstallStamp).ComfyUI
        @($entry.Keys | Sort-Object) | Should -Be @('Cloned', 'Dir')
        $entry.Dir | Should -Be $settings.ComfyUI.Dir
        $entry.Cloned | Should -BeTrue
    }

    It 'keeps the ComfyUI entry whole when the venv could not be removed' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
        $world.Answers.Enqueue($true)
        $world.Busy[(Join-Path $settings.ComfyUI.Dir '.venv')] = 99
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(1)
        (Read-LocalAIState -Path $paths.InstallStamp).ComfyUI.Python | Should -Be (Join-Path $settings.ComfyUI.Dir '.venv\Scripts\python.exe')
    }

    It 'leaves the uv tools alone, naming their commands, when install-stamp.json is not JSON' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir (Join-Path $root 'uv\elsewhere') -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        [IO.File]::WriteAllText($paths.InstallStamp, '{ not json')
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'uv *' }).Count | Should -Be 0
        $run.Printed | Should -BeLike "*the uv tool open-webui in $root\uv\elsewhere\open-webui: install-stamp.json does not record it*the uv tool mcpo in*"
        foreach ($tool in 'open-webui', 'mcpo') { Test-Path -LiteralPath (Join-Path $root "uv\elsewhere\$tool") | Should -BeTrue }
    }

    It 'plans without failing when the folders lie on a drive this PC does not have now' {
        $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        $free = @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z' | Where-Object { $used -notcontains $_ })[0]
        $settings.Shortcuts.Folder = "${free}:\Menu"
        $settings.ComfyUI.Dir = "${free}:\ComfyUI"
        Write-LocalAIState -Path $paths.State -State @{ Services = @{} }
        Write-LocalAIState -Path $paths.InstallStamp -State @{ ComfyUI = @{ Dir = "${free}:\ComfyUI"; Python = "${free}:\ComfyUI\.venv\Scripts\python.exe" }
            Files = @{ ToolDir = "${free}:\uv\tools" }; OpenWebUI = @{ Version = '0.12.4' } }
        $plan = Invoke-ModuleFunction 'Get-LocalAIUninstallPlan' @{ Settings = $settings; Paths = $paths; Stamp = (Read-LocalAIState -Path $paths.InstallStamp)
            State = @{} }
        @($plan.Items | Where-Object { $_.Kind -ne 'Alias' }).Count | Should -Be 0
    }

    It 'works when the settings do not load, going by the values settings.psd1 sets and install-stamp.json' {
        $folder = Join-Path $root 'Menu of the user'
        $settings.Shortcuts.Folder = $folder
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        $null = Write-TestFile ($paths.Settings.Substring($TestDrive.Length + 1)) ("@{ Ports = @{ Bogus = 1 }; Shortcuts = @{ Folder = '$folder' }; " +
            "ComfyUI = @{ Dir = '$($settings.ComfyUI.Dir)' }; OpenWebUI = @{ DataDir = '$($settings.OpenWebUI.DataDir)' }; Files = @{ Root = '$($settings.Files.Root)' } }")
        # The fallback must reach only TestDrive before uninstall runs on it.
        $problems = New-Object System.Collections.Generic.List[string]
        $fallback = Invoke-ModuleFunction 'Get-LocalAIFallbackSetting' @{ DefaultsPath = (Join-Path $repoRoot 'config\defaults.psd1'); UserPath = $paths.Settings; Problems = $problems }
        foreach ($value in $fallback.Shortcuts.Folder, $fallback.ComfyUI.Dir, $fallback.OpenWebUI.DataDir, $fallback.Files.Root) { $value | Should -BeLike "$TestDrive*" }
        $context.Settings = $null
        $context.SettingsError = "Invalid settings ($($paths.Settings)):`n  Unknown setting 'Ports.Bogus'."
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeLike "The settings do not load, so uninstall goes by state.json, install-stamp.json and the defaults with the values settings.psd1 sets. It skips what does not merge: Unknown setting 'Ports.Bogus'.*"
        Test-Path -LiteralPath $folder | Should -BeFalse
        @($calls | Where-Object { $_ -like 'uv *' }).Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir '.venv') | Should -BeFalse
    }

    It 'leaves the alias and the clone alone when install-stamp.json is not JSON' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
        [IO.File]::WriteAllText($paths.InstallStamp, '{ not json')
        $world.Answers.Enqueue($true)
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeLike '*uninstall reads it as empty, so it leaves the alias install created and a ComfyUI checkout it cloned alone.*'
        @($calls | Where-Object { $_ -like 'ollama*' }).Count | Should -Be 0
        # Without the stamp only uv's own tool folder is searched, and it holds none of them here.
        @($calls | Where-Object { $_ -like 'uv *' }).Count | Should -Be 0
        [IO.File]::ReadAllText($paths.InstallStamp) | Should -Be '{ not json'
        # The clone keeps its files and its mark; only the venv its marker says install created goes.
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'main.py') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir '.git\local-ai-clone.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'models\checkpoints\model.safetensors') | Should -BeTrue
    }

    It 'reads what runs before it asks, and looks for programs the stop missed only after the stop' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        Mock Get-LocalAIRunningService -ModuleName LocalAI -MockWith {
            $calls.Add('running')
            @('OpenWebUI')
        }
        Mock Confirm-LocalAIAction -ModuleName LocalAI -MockWith {
            $calls.Add('ask')
            $true
        }
        Mock Get-BusyProcess -ModuleName LocalAI -MockWith { $calls.Add("busy $($Folder -join '|')") }
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls)[0..4] | Should -Be @('running', 'ask', 'stop', "busy $toolDir\open-webui", "uv $toolDir|tool uninstall open-webui")
    }

    It 'refuses to run when state.json is not JSON, removing nothing' {
        Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
        [IO.File]::WriteAllText($paths.State, 'nope')
        $run = Invoke-UninstallVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*is not valid JSON*So uninstall cannot tell what the launcher runs, and it removed nothing.*delete $($paths.State)*"
        $questions.Count | Should -Be 0
    }

    Context 'with an Ollama app local-ai started' {
        BeforeEach {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
            $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'start' }
            $state = Read-LocalAIState -Path $paths.State
            $state['Ollama'] = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat'; App = $app }
            Write-LocalAIState -Path $paths.State -State $state
            $world.Quit = @{ Result = 'stopped'; Reason = 'Quit the Ollama app local-ai started (PID 100).' }
            $world.Found = 'match'
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { $world.Found }
            Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
                $calls.Add("stop KeepOllama=$([bool]$KeepOllama)")
                $world.Stop
            }
            Mock Stop-OllamaApp -ModuleName LocalAI -MockWith {
                $calls.Add("quit $($Record.Pid) $Url $Alias")
                $world.Quit
            }
        }

        It 'keeps Ollama through the stop, removes the alias, then quits the app and drops its record' {
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike '*Last it quits the Ollama app local-ai started (PID 100), unless another program has a model loaded in it or its window is open.*'
            @($calls | Where-Object { $_ -like 'stop*' -or $_ -like 'ollama*' -or $_ -like 'quit*' }) |
                Should -Be @('stop KeepOllama=True', 'ollama up', 'ollama list', 'ollama rm local-chat', 'quit 100 http://127.0.0.1:11434 local-chat')
            (Read-LocalAIState -Path $paths.State).Ollama.App | Should -BeNullOrEmpty
        }

        It 'counts the running app as work to ask about, also when nothing else is left and <Case>' -ForEach @(
            @{ Case = 'this window can inspect it'; Found = 'match' }
            @{ Case = 'this window may not inspect it, as stop and status still count it'; Found = 'unreadable' }
        ) {
            $world.Found = $Found
            Remove-Item -LiteralPath $paths.InstallStamp
            foreach ($gone in $settings.Shortcuts.Folder, $paths.FilesServer, $paths.FilesKey, $paths.McpoConfig, (Join-Path $paths.Root 'image-gate'), (Join-Path $paths.Root 'mcpo'),
                (Join-Path $settings.ComfyUI.Dir '.venv')) {
                Remove-Item -LiteralPath $gone -Recurse -Force
            }
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            @($questions) | Should -Be @('Uninstall these now?')
            $run.Printed | Should -BeLike '*Last it quits the Ollama app local-ai started (PID 100)*'
            $calls | Should -Contain 'quit 100 http://127.0.0.1:11434 local-chat'
        }

        It 'neither lists nor asks about an app that no longer runs as recorded' {
            $world.Found = 'other'
            Remove-Item -LiteralPath $paths.InstallStamp
            foreach ($gone in $settings.Shortcuts.Folder, $paths.FilesServer, $paths.FilesKey, $paths.McpoConfig, (Join-Path $paths.Root 'image-gate'), (Join-Path $paths.Root 'mcpo'),
                (Join-Path $settings.ComfyUI.Dir '.venv')) {
                Remove-Item -LiteralPath $gone -Recurse -Force
            }
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $questions.Count | Should -Be 0
            $run.Printed | Should -Not -BeLike '*Last it quits*'
        }

        It 'quits the app its own wait started to remove the alias' {
            $state = Read-LocalAIState -Path $paths.State
            $state.Remove('Ollama')
            Write-LocalAIState -Path $paths.State -State $state
            $started = @{ Pid = 300; StartTicks = 333; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 330; How = 'uninstall' }
            Mock Wait-OllamaServer -ModuleName LocalAI -MockWith {
                $calls.Add('ollama up')
                [pscustomobject]@{ Version = '0.40.11'; App = $started }
            }
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -Not -BeLike '*Last it quits*'
            Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $PassThru -and $How -eq 'uninstall' }
            @($calls | Where-Object { $_ -like 'quit*' }) | Should -Be @('quit 300 http://127.0.0.1:11434 local-chat')
        }

        It 'returns 1 naming the app when it cannot be quit, keeping its record and the launcher folder' {
            $context.RemoveData = $true
            $world.Quit = @{ Result = 'failed'; Reason = 'The Ollama app local-ai started (PID 100), or its server on port 11434, still runs; see above.' }
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $run.Printed | Should -BeLike '*Kept *, since the next uninstall run needs its install-stamp.json*Uninstall finished, but these stay:*The Ollama app local-ai started (PID 100), or its server on port 11434, still runs*'
            (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 100
        }

        It 'keeps the record when the app keeps running for another program, without failing' {
            $world.Quit = @{ Result = 'kept'; Reason = 'Ollama still has qwen3:8b loaded, which another program may be using, so the Ollama app local-ai started (PID 100) keeps running.' }
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 100
            $run.Printed | Should -Not -BeLike '*no longer tracks*'
        }

        It 'says local-ai no longer tracks an app it kept once -RemoveData deleted state.json with the launcher folder' {
            $context.RemoveData = $true
            $world.Quit = @{ Result = 'kept'; Reason = 'The Ollama app local-ai started (PID 100) has a window open, so it keeps running.' }
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike ("*Deleted $($paths.Root).*local-ai no longer tracks the Ollama app it started (PID 100), which keeps running; quit it from " +
                'its tray icon once you are done with it.*')
            Test-Path -LiteralPath $paths.Root | Should -BeFalse
        }
    }

    Context 'with -RemoveData' {
        BeforeEach {
            $context.RemoveData = $true
        }

        It 'asks again, listing each folder with its size, then deletes the data, the checkout install cloned and the launcher folder' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            @($questions) | Should -Be @('Uninstall these now?', 'Delete these folders and everything in them? This cannot be undone.')
            $run.Printed | Should -BeLike ('*-RemoveData also deletes these folders with everything in them:*' +
                "$($settings.OpenWebUI.DataDir) (1 KB): Open WebUI's data*$($settings.ComfyUI.Dir) (* KB): ComfyUI, which install cloned*" +
                "$($paths.Root) (* KB): the launcher's folder*Deleted $($settings.OpenWebUI.DataDir).*Deleted $($settings.ComfyUI.Dir).*Deleted $($paths.Root).*Uninstall finished.")
            $run.Printed | Should -Not -BeLike '*Your data stays*'
            foreach ($gone in $settings.OpenWebUI.DataDir, $settings.ComfyUI.Dir, $paths.Root) { Test-Path -LiteralPath $gone | Should -BeFalse }
            [IO.File]::ReadAllText((Join-Path $settings.Files.Root 'doc.txt')) | Should -Be 'mine'
            @(Get-ChildItem -LiteralPath $root -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('files', 'Start Menu', 'uv')
            # A typed word, so keys pressed ahead for the first question cannot answer the second.
            Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Word -eq 'delete' -and $Question -like 'Delete these folders*' }
            Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { -not $Word -and $Question -eq 'Uninstall these now?' }
        }

        It 'refuses a data folder other than the one install-stamp.json records, naming both' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            $stamp = Read-LocalAIState -Path $paths.InstallStamp
            $stamp.OpenWebUI.DataDir = Join-Path $root 'owui-of-the-launcher'
            Write-LocalAIState -Path $paths.InstallStamp -State $stamp
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $run.Printed | Should -BeLike ("*Not $($settings.OpenWebUI.DataDir), because install recorded Open WebUI's data folder as $root\owui-of-the-launcher, not this " +
                "one, which OpenWebUI.DataDir names; delete the one that holds the launcher's data by hand.*")
            Test-Path -LiteralPath (Join-Path $settings.OpenWebUI.DataDir 'webui.db') | Should -BeTrue
        }

        Context 'when settings.psd1 does not load' {
            BeforeEach {
                # The defaults would name this PC's folders, so the fallback stands in, naming a folder of another Open WebUI as OpenWebUI.DataDir.
                $other = Join-Path $root 'open-webui-of-another-install'
                $null = New-Item -ItemType Directory -Force -Path $other
                [IO.File]::WriteAllText((Join-Path $other 'webui.db'), 'theirs')
                $fallback = @{}
                foreach ($key in $settings.Keys) { $fallback[$key] = $settings[$key] }
                $fallback.OpenWebUI = @{} + $settings.OpenWebUI
                $fallback.OpenWebUI.DataDir = $other
                $fallback.Files = @{} + $settings.Files
                $fallback.Files.Root = ''
                Mock Get-LocalAIFallbackSetting -ModuleName LocalAI -MockWith {
                    $Problems.Add("Cannot read settings file '$UserPath': it does not parse.")
                    $UserLoaded.Value = $false
                    $fallback
                }
                $context.Settings = $null
                $context.SettingsError = "Cannot read settings file '$($paths.Settings)': it does not parse."
            }

            It 'deletes the data folder install-stamp.json records, not the one the defaults name, and keeps Files.Root the stamp records' {
                Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
                $stamp = Read-LocalAIState -Path $paths.InstallStamp
                $stamp.OpenWebUI.DataDir = $settings.OpenWebUI.DataDir
                $stamp.Files.Root = $settings.Files.Root
                Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                $world.Answers.Enqueue($true)
                $world.Answers.Enqueue($true)
                $run = Invoke-UninstallVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Warnings | Should -BeLike "*the defaults, as settings.psd1 does not load; Open WebUI's data folder comes from install-stamp.json only.*"
                $run.Printed | Should -BeLike "*-RemoveData also deletes these folders*$($settings.OpenWebUI.DataDir) (*): Open WebUI's data*"
                Test-Path -LiteralPath $settings.OpenWebUI.DataDir | Should -BeFalse
                [IO.File]::ReadAllText((Join-Path $other 'webui.db')) | Should -Be 'theirs'
                [IO.File]::ReadAllText((Join-Path $settings.Files.Root 'doc.txt')) | Should -Be 'mine'
            }

            It 'deletes no data folder, saying why, when install-stamp.json records none' {
                Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
                $world.Answers.Enqueue($true)
                $world.Answers.Enqueue($true)
                $run = Invoke-UninstallVerb -Context $context
                $run.Code | Should -Be @(1)
                $run.Printed | Should -BeLike ("*Not $other, because settings.psd1 does not load and install-stamp.json records no data folder of Open WebUI, so uninstall " +
                    "cannot tell whether the launcher used this one; delete the launcher's data folder by hand once you know which it is.*")
                [IO.File]::ReadAllText((Join-Path $other 'webui.db')) | Should -Be 'theirs'
                Test-Path -LiteralPath (Join-Path $settings.OpenWebUI.DataDir 'webui.db') | Should -BeTrue
            }
        }

        It 'keeps a ComfyUI checkout install did not clone, naming it' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $true -NodeByLauncher $false
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*It keeps ComfyUI in $($settings.ComfyUI.Dir): install did not clone this checkout, so it stays with its models and output.*"
            Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'models\checkpoints\model.safetensors') | Should -BeTrue
            Test-Path -LiteralPath $settings.OpenWebUI.DataDir | Should -BeFalse
        }

        It 'keeps a checkout the stamp calls cloned when its clone mark is gone, as one put there by hand' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            Remove-Item -LiteralPath (Join-Path $settings.ComfyUI.Dir '.git\local-ai-clone.json')
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Printed | Should -BeLike "*It keeps ComfyUI in $($settings.ComfyUI.Dir): install did not clone this checkout*"
            Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'main.py') | Should -BeTrue
        }

        It 'keeps the data when the second answer is No' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($false)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike '*The data folders stay.*'
            foreach ($kept in $settings.OpenWebUI.DataDir, (Join-Path $settings.ComfyUI.Dir 'main.py'), $paths.InstallStamp) { Test-Path -LiteralPath $kept | Should -BeTrue }
            Test-Path -LiteralPath (Join-Path $toolDir 'open-webui') | Should -BeFalse
        }

        It 'refuses a data folder that holds Files.Root, deleting the rest and returning 1' {
            $settings.Files.Root = Join-Path $settings.OpenWebUI.DataDir 'files'
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $run.Printed | Should -BeLike "*Not $($settings.OpenWebUI.DataDir), because it is or holds Files.Root, *these stay:*$($settings.OpenWebUI.DataDir): -RemoveData does not delete it*"
            [IO.File]::ReadAllText((Join-Path $settings.Files.Root 'doc.txt')) | Should -Be 'mine'
            Test-Path -LiteralPath (Join-Path $settings.OpenWebUI.DataDir 'webui.db') | Should -BeTrue
            Test-Path -LiteralPath $settings.ComfyUI.Dir | Should -BeFalse
            Test-Path -LiteralPath $paths.Root | Should -BeFalse
        }

        It 'goes on past a data folder it cannot delete, keeps the launcher folder and returns 1 naming it' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $world.Busy[$settings.OpenWebUI.DataDir] = 5150
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $data = $settings.OpenWebUI.DataDir
            $run.Printed | Should -BeLike ("*Could not delete ${data}: python (PID 5150) still runs from it*Deleted $($settings.ComfyUI.Dir).*Kept $($paths.Root), since the " +
                "next uninstall run needs its install-stamp.json*Uninstall finished, but these stay:*${data}: python (PID 5150) still runs from it*")
            Test-Path -LiteralPath (Join-Path $data 'webui.db') | Should -BeTrue
            Test-Path -LiteralPath $settings.ComfyUI.Dir | Should -BeFalse
            Test-Path -LiteralPath $paths.InstallStamp | Should -BeTrue
        }

        It 'keeps a cloned checkout and the alias when install-stamp.json is not JSON, naming the checkout' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            [IO.File]::WriteAllText($paths.InstallStamp, '{ not json')
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*It keeps ComfyUI in $($settings.ComfyUI.Dir): install did not clone this checkout, so it stays with its models and output.*"
            Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'main.py') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $settings.ComfyUI.Dir 'models\checkpoints\model.safetensors') | Should -BeTrue
            @($calls | Where-Object { $_ -like 'ollama*' }).Count | Should -Be 0
            Test-Path -LiteralPath $settings.OpenWebUI.DataDir | Should -BeFalse
        }

        It 'keeps the launcher folder, which the next run needs, when a part could not be removed' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $true -CreatedVenv $true -NodeByLauncher $false
            $world.Answers.Enqueue($true)
            $world.Answers.Enqueue($true)
            $world.Busy[(Join-Path $toolDir 'mcpo')] = 77
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $run.Printed | Should -BeLike "*Kept $($paths.Root), since the next uninstall run needs its install-stamp.json to remove what stays above.*"
            Test-Path -LiteralPath $settings.OpenWebUI.DataDir | Should -BeFalse
            (Read-LocalAIState -Path $paths.InstallStamp).ContainsKey('Files') | Should -BeTrue
        }

        It 'deletes the data without a first question when nothing else is left' {
            $null = New-Item -ItemType Directory -Force -Path $settings.OpenWebUI.DataDir
            [IO.File]::WriteAllText((Join-Path $settings.OpenWebUI.DataDir 'webui.db'), 'database')
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            @($questions) | Should -Be @('Delete these folders and everything in them? This cannot be undone.')
            @($calls) | Should -Be @('stop')
            Test-Path -LiteralPath $settings.OpenWebUI.DataDir | Should -BeFalse
        }
    }

    Context 'for a release install' {
        BeforeEach {
            $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0' -Shim
            $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
            $context.InstallRoot = $install.Root
            $key = Get-TestEnvironmentKey -Value "%USERPROFILE%\bin;$($install.Root)\;C:\Tools\bin"
            Mock Get-LauncherEnvironmentKey -ModuleName LocalAI -MockWith { $key }
            Mock Send-LauncherSettingChange -ModuleName LocalAI -MockWith { $calls.Add('broadcast') }
            Mock Get-LauncherConsoleProcess -ModuleName LocalAI -MockWith { @{ Id = 4321; StartTicks = 638000000000000000 } }
            $started = New-Object System.Collections.Generic.List[hashtable]
            Mock Start-Process -ModuleName LocalAI -MockWith {
                $started.Add(@{ FilePath = $FilePath; ArgumentList = [string]$ArgumentList; WorkingDirectory = $WorkingDirectory; WindowStyle = [string]$WindowStyle })
            }
        }

        It 'lists the launcher and its Path entry, removes that entry and starts the hidden removal of exactly its install folder, which it never runs itself' {
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*Uninstall removes:*the entry $($install.Root) in your user Path*the launcher itself in $($install.Root), once this window has closed*"
            $key.Values['Path'] | Should -BeExactly '%USERPROFILE%\bin;C:\Tools\bin'
            $key.Kinds['Path'] | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
            @($calls) | Should -Be @('stop', 'broadcast')
            $started.Count | Should -Be 1
            $started[0].WindowStyle | Should -Be 'Hidden'
            $started[0].WorkingDirectory | Should -Be ([IO.Path]::GetTempPath())
            $started[0].FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            $encoded = [regex]::Match($started[0].ArgumentList, '-EncodedCommand (\S+)').Groups[1].Value
            $script = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            $script | Should -BeLike "*`$root = '$($install.Root)'*"
            $script | Should -BeLike '*$waits = @(@{ Id = 4321; Ticks = 638000000000000000 })*'
            # The write time of current at uninstall, which install.ps1 changes when it sets the folder up again.
            $script | Should -Match ('\$written = ' + [IO.File]::GetLastWriteTimeUtc((Join-Path $install.Root 'current')).Ticks + '\r?\n')
            $run.Printed | Should -BeLike ("*The launcher's own folder $($install.Root) goes once this window has closed; " +
                "$([IO.Path]::Combine([IO.Path]::GetTempPath(), 'local-ai-uninstall-cleanup.log')) says how that went.*")
            Test-Path -LiteralPath (Join-Path $install.Root 'current') | Should -BeTrue
        }

        It 'keeps the launcher, its Path entry and its folder when another part could not be removed, as the next run needs them' {
            Write-TestInstall -Settings $settings -Paths $paths -ToolDir $toolDir -Cloned $false -CreatedVenv $null -NodeByLauncher $false
            $world.Answers.Enqueue($true)
            $world.Busy[(Join-Path $toolDir 'mcpo')] = 77
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $run.Printed | Should -BeLike "*Kept the launcher in $($install.Root), since the next uninstall run needs it to remove what stays above.*"
            $key.Values['Path'] | Should -BeExactly "%USERPROFILE%\bin;$($install.Root)\;C:\Tools\bin"
            $key.Writes.Count | Should -Be 0
            $started.Count | Should -Be 0
        }

        It 'removes nothing when the answer is no' {
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            @($questions) | Should -Be @('Uninstall these now?')
            $key.Writes.Count | Should -Be 0
            $started.Count | Should -Be 0
        }

        It 'counts the Path entry as removed, with a warning, when only telling running programs fails' {
            Mock Send-LauncherSettingChange -ModuleName LocalAI -MockWith { throw 'Add-Type could not compile the binding.' }
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $key.Values['Path'] | Should -BeExactly '%USERPROFILE%\bin;C:\Tools\bin'
            $run.Warnings | Should -BeLike '*Windows could not tell running programs that your Path changed, so it may take a new sign-in: Add-Type could not compile the binding.*'
            $run.Printed | Should -BeLike "*Removed $($install.Root) from your user Path.*Uninstall finished.*"
            $run.Printed | Should -Not -BeLike '*Could not remove*'
            $started.Count | Should -Be 1
        }

        It 'names the Path entry that stays, and still starts the removal of the folder, when the Path cannot be written' {
            $key | Add-Member -MemberType ScriptMethod -Name SetValue -Value { throw 'Access to the registry key is denied.' } -Force
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $run.Printed | Should -BeLike "*Could not remove $($install.Root) from your user Path: *Access to the registry key is denied.*"
            $run.Printed | Should -BeLike "*Uninstall finished, but these stay:*the entry $($install.Root) in your user Path: *Access to the registry key is denied.*"
            $key.Values['Path'] | Should -BeExactly "%USERPROFILE%\bin;$($install.Root)\;C:\Tools\bin"
            $calls | Should -Not -Contain 'broadcast'
            $started.Count | Should -Be 1
        }

        It 'keeps the folder, and says to delete it by hand, when the hidden removal cannot start' {
            Mock Start-LauncherCleanup -ModuleName LocalAI -MockWith { throw 'The system cannot find the file specified.' }
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(1)
            $run.Printed | Should -BeLike "*Could not start the removal of $($install.Root): The system cannot find the file specified.*"
            $run.Printed | Should -BeLike ("*Uninstall finished, but these stay:*$($install.Root): The system cannot find the file specified. Delete it once this window " +
                'has closed.*')
            $key.Values['Path'] | Should -BeExactly '%USERPROFILE%\bin;C:\Tools\bin'
            Test-Path -LiteralPath (Join-Path $install.Root 'current') | Should -BeTrue
        }

        It "starts the removal without touching the user's Path when it does not name the launcher" {
            $key = Get-TestEnvironmentKey -Value 'C:\Tools\bin;C:\Users\User\AppData\Local\Programs\local-ai-launcher-old'
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -Not -BeLike '*in your user Path*'
            $key.Writes.Count | Should -Be 0
            $calls | Should -Not -Contain 'broadcast'
            $started.Count | Should -Be 1
        }

        It 'never removes the launcher of a git checkout, nor looks at the Path for it' {
            $context.RepoRoot = $repoRoot
            $world.Answers.Enqueue($true)
            $run = Invoke-UninstallVerb -Context $context
            $run.Printed | Should -Not -BeLike '*the launcher itself*'
            Should -Invoke Get-LauncherEnvironmentKey -ModuleName LocalAI -Times 0 -Exactly
            $started.Count | Should -Be 0
        }
    }
}
