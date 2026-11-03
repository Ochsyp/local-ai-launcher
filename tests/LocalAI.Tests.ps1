# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS
# -------------------------------------------------------
#
# Pester 6 tests for src\LocalAI.psm1. Files go to TestDrive: and mutexes get unique names, so
# nothing touches %LOCALAPPDATA%\local-ai, Open WebUI, Ollama or ComfyUI.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\LocalAI.psm1') -Force

    # Write $Text to $Name under TestDrive: as UTF-8 without BOM, creating folders, and return the
    # file's full path.
    function Write-TestFile([string]$Name, [string]$Text) {
        $path = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent)
        [IO.File]::WriteAllText($path, $Text)
        return $path
    }

    # Run $Script with $Arguments in a fresh runspace, which runs on its own thread, and return
    # its output. The runspace is closed before returning.
    function Invoke-OnOtherThread([scriptblock]$Script, [object[]]$Arguments) {
        $shell = [powershell]::Create()
        try {
            $null = $shell.AddScript($Script.ToString())
            foreach ($argument in $Arguments) { $null = $shell.AddArgument($argument) }
            return $shell.Invoke()
        } finally {
            $shell.Dispose()
        }
    }

    # True when another thread can take the named mutex right now; that thread releases it again.
    function Test-MutexFree([string]$Name) {
        $result = Invoke-OnOtherThread -Arguments @($Name) -Script {
            param($Name)
            $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, $Name
            try {
                $free = $mutex.WaitOne(0)
                if ($free) { $mutex.ReleaseMutex() }
                $free
            } catch [System.Threading.AbandonedMutexException] {
                $mutex.ReleaseMutex()
                $true
            } finally {
                $mutex.Dispose()
            }
        }
        return [bool]$result[0]
    }

    # Start a runspace that takes the named mutex and holds it until $Release is set, or for
    # $HoldMilliseconds when that is given. Returns @{ Shell; Handle; Release } once it is held.
    function Enter-MutexOnOtherThread([string]$Name, [int]$HoldMilliseconds = 30000) {
        $acquired = New-Object -TypeName System.Threading.ManualResetEvent -ArgumentList $false
        $release = New-Object -TypeName System.Threading.ManualResetEvent -ArgumentList $false
        $shell = [powershell]::Create()
        $null = $shell.AddScript({
                param($Name, $Acquired, $Release, $HoldMilliseconds)
                $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, $Name
                $null = $mutex.WaitOne()
                $null = $Acquired.Set()
                $null = $Release.WaitOne($HoldMilliseconds)
                $mutex.ReleaseMutex()
                $mutex.Dispose()
            }.ToString()).AddArgument($Name).AddArgument($acquired).AddArgument($release).AddArgument($HoldMilliseconds)
        $handle = $shell.BeginInvoke()
        if (-not $acquired.WaitOne(10000)) { throw 'The holder thread did not take the mutex.' }
        return @{ Shell = $shell; Handle = $handle; Release = $release }
    }

    # Let a holder from Enter-MutexOnOtherThread release its mutex, and wait for its runspace to end.
    function Exit-MutexOnOtherThread([hashtable]$Holder) {
        $null = $Holder.Release.Set()
        $null = $Holder.Shell.EndInvoke($Holder.Handle)
        $Holder.Shell.Dispose()
    }

    # Call the module function $Name, exported or not, inside the module with the parameters $Arguments, and return its output.
    function Invoke-ModuleFunction([string]$Name, [hashtable]$Arguments = @{}) {
        InModuleScope LocalAI -Parameters @{ Name = $Name; Arguments = $Arguments } { param($Name, $Arguments) & $Name @Arguments }
    }

    # The home that pyvenv.cfg names for a venv uv made on the Microsoft Store Python 3.13: the folder of its app execution alias.
    $storeHome = 'C:\Users\User\AppData\Local\Microsoft\WindowsApps\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0'

    # Write the pyvenv.cfg uv writes into the venv folder $Venv for a base Python in the folder $BaseHome at $Version, creating the folder.
    function Write-TestPyVenvConfig([string]$Venv, [string]$BaseHome, [string]$Version) {
        $null = New-Item -ItemType Directory -Force -Path $Venv
        [IO.File]::WriteAllText((Join-Path $Venv 'pyvenv.cfg'), "home = $BaseHome`nimplementation = CPython`nuv = 0.13.1`nversion_info = $Version`ninclude-system-site-packages = false`n")
    }

    # Return the state of a fake git for the update tests: the checkout's Head, Branch ($null when detached), the commit BranchHead its branch names, Origin,
    # Modified files, whether the clone is Shallow, as install's depth-1 clone is, the commits it holds besides (Objects), the remote's tag Tag at Commit (Peeled for an annotated
    # tag), what a fetch brought (Fetched), Fail (call prefix -> @{ Code; Lines }), every call without its global options in Calls, and the prompt variables each
    # call saw in Prompts.
    function Get-FakeGit([string]$Head, [string]$Commit) {
        return @{
            Head = $Head; Branch = 'refs/heads/master'; BranchHead = $Head; Origin = 'https://github.com/comfyanonymous/ComfyUI.git'; Modified = @()
            Shallow = $true; Objects = @(); Tag = 'v0.42.5'; Commit = $Commit; Peeled = $null; Fetched = $null; Fail = @{}
            Calls = New-Object System.Collections.Generic.List[string]; Prompts = New-Object System.Collections.Generic.List[string]
        }
    }

    # The body of a mock of Invoke-Native for git, playing the repository that $git (from Get-FakeGit) describes. A code outside SuccessCode throws as
    # Invoke-Native does.
    $fakeGit = {
        $words = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
            if ($ArgumentList[$i] -ceq '-C' -or $ArgumentList[$i] -ceq '-c') {
                $i++
                continue
            }
            if ($ArgumentList[$i] -ceq '--no-optional-locks') { continue }
            $words.Add($ArgumentList[$i])
        }
        $call = $words -join ' '
        $git.Calls.Add($call)
        $git.Prompts.Add("$env:GIT_TERMINAL_PROMPT/$env:GCM_INTERACTIVE")
        $code = 0
        $failed = @($git.Fail.Keys | Where-Object { $call.StartsWith($_) })
        if ($failed.Count -gt 0) {
            foreach ($line in $git.Fail[$failed[0]].Lines) { $Capture.Add($line) }
            $code = $git.Fail[$failed[0]].Code
        } else {
            switch ($words[0]) {
                'rev-parse' {
                    if ($words[1] -eq 'HEAD') {
                        $Capture.Add($git.Head)
                    } elseif ($words[1] -eq '--is-shallow-repository') {
                        $Capture.Add($(if ($git.Shallow) { 'true' } else { 'false' }))
                    } elseif ($git.Fetched) {
                        $Capture.Add($git.Fetched)
                    } else {
                        $code = 128
                    }
                }
                'cat-file' { if (@($git.Objects) -notcontains ($words[2] -replace '\^\{commit\}\z', '')) { $code = 128 } }
                'symbolic-ref' { if ($git.Branch) { $Capture.Add($git.Branch) } else { $code = 1 } }
                'config' { if ($git.Origin) { $Capture.Add($git.Origin) } else { $code = 1 } }
                'status' { foreach ($file in $git.Modified) { $Capture.Add(" M $file") } }
                'ls-remote' {
                    if ($git.Commit) { $Capture.Add("$($git.Commit)`trefs/tags/$($git.Tag)") }
                    if ($git.Peeled) { $Capture.Add("$($git.Peeled)`trefs/tags/$($git.Tag)^{}") }
                }
                'fetch' { $git.Fetched = if ($git.Peeled) { $git.Peeled } else { $git.Commit } }
                'checkout' {
                    if ($words -contains '--detach') {
                        $git.Head = $words[-1]
                        $git.Branch = $null
                    } else {
                        $git.Branch = "refs/heads/$($words[1])"
                        $git.Head = $git.BranchHead
                    }
                }
                'remote' { if ($words[1] -eq 'remove') { $git.Origin = $null } else { $git.Origin = $words[-1] } }
            }
        }
        $codes = if ($SuccessCode) { $SuccessCode } else { @(0) }
        if ($codes -notcontains $code) { throw "'git $($ArgumentList -join ' ')' failed with exit code $code." }
        $code
    }
}

Describe 'Get-LocalAIPaths' {
    It 'places every runtime path under Root' {
        $paths = Get-LocalAIPaths -Root 'C:\Data\local-ai'
        $paths.Root | Should -Be 'C:\Data\local-ai'
        $paths.Logs | Should -Be 'C:\Data\local-ai\logs'
        $paths.State | Should -Be 'C:\Data\local-ai\state.json'
        $paths.Settings | Should -Be 'C:\Data\local-ai\settings.psd1'
        $paths.InstallStamp | Should -Be 'C:\Data\local-ai\install-stamp.json'
        $paths.Backups | Should -Be 'C:\Data\local-ai\backups'
        $paths.Modelfile | Should -Be 'C:\Data\local-ai\local-chat.Modelfile'
        $paths.FilesKey | Should -Be 'C:\Data\local-ai\files.key'
        $paths.McpoConfig | Should -Be 'C:\Data\local-ai\mcpo.json'
        $paths.FilesServer | Should -Be 'C:\Data\local-ai\files-server'
    }

    It 'defaults Root to %LOCALAPPDATA%\local-ai' {
        (Get-LocalAIPaths).Root | Should -Be (Join-Path $env:LOCALAPPDATA 'local-ai')
    }
}

Describe 'Get-LocalAIVersion' {
    BeforeEach {
        $checkout = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $checkout
    }

    It 'returns <Expected> for a VERSION file that holds <Case>' -ForEach @(
        @{ Case = 'a version and LF, as a release writes it'; Text = "1.2.0`n"; Expected = '1.2.0' }
        @{ Case = 'a version and CRLF'; Text = "0.10.3`r`n"; Expected = '0.10.3' }
        @{ Case = 'a version without a line end'; Text = '2.0.0'; Expected = '2.0.0' }
        @{ Case = 'spaces around the version'; Text = "  10.20.30  `n"; Expected = '10.20.30' }
        @{ Case = 'a BOM before the version'; Text = ([string][char]0xFEFF) + "3.4.5`n"; Expected = '3.4.5' }
    ) {
        [IO.File]::WriteAllText((Join-Path $checkout 'VERSION'), $Text)
        Get-LocalAIVersion -RepoRoot $checkout | Should -BeExactly $Expected
    }

    It 'returns $null for a VERSION file that holds <Case>' -ForEach @(
        @{ Case = 'nothing'; Text = '' }
        @{ Case = 'two numbers'; Text = "1.2`n" }
        @{ Case = 'four numbers'; Text = "1.2.3.4`n" }
        @{ Case = 'a v before the version'; Text = "v1.2.3`n" }
        @{ Case = 'a prerelease'; Text = "1.2.3-rc.1`n" }
        @{ Case = 'two versions'; Text = "1.2.3`n1.2.4`n" }
        @{ Case = 'digits of another script'; Text = ([string][char]0x0661) + ".2.3`n" }
    ) {
        [IO.File]::WriteAllText((Join-Path $checkout 'VERSION'), $Text)
        # $null, not '', which status -Json would write as "version": "".
        ($null -eq (Get-LocalAIVersion -RepoRoot $checkout)) | Should -BeTrue
    }

    It 'returns $null without a VERSION file, as in a git checkout before the first release, and for a folder named VERSION' {
        ($null -eq (Get-LocalAIVersion -RepoRoot $checkout)) | Should -BeTrue
        $null = New-Item -ItemType Directory -Path (Join-Path $checkout 'VERSION')
        ($null -eq (Get-LocalAIVersion -RepoRoot $checkout)) | Should -BeTrue
    }
}

Describe 'Get-LocalAISettings' {
    BeforeAll {
        $env:LOCALAI_TEST_DIR = 'C:\LocalAITest'
        $defaults = Write-TestFile 'settings\defaults.psd1' @'
@{
    Ports     = @{ OpenWebUI = 8080; ComfyUI = 8188; ImageGate = 8190 }
    Model     = @{ Alias = 'local-chat'; Source = 'hf.co/Org/Chat-GGUF:Q6_K'; Sha256 = ''; SupersededAliases = @('old-chat') }
    Shortcuts = @{ Folder = '%LOCALAI_TEST_DIR%\menu' }
    OpenWebUI = @{ DataDir = '%LOCALAI_TEST_DIR%\data'; HealthTimeoutSeconds = 600; InheritEnvironment = @(); Env = @{ WEBUI_AUTH = 'True' } }
    Images    = @{ Enabled = $true; Steps = 6; Resolution = '1024x1024'; Revision = '561086c22aba3925b1e8803a73857f061635c7c3'; UnloadChat = $true; UnloadTimeoutSeconds = 30 }
    ComfyUI   = @{ Args = @('--one', '--two'); Dir = '%LOCALAI_TEST_DIR%\ComfyUI'; Commit = '483dae4326356b81de05d27aca3f433dd323cc25'; ExcludeNewer = '2026-10-23T00:07:14Z'
        InheritEnvironment = @() }
    Winget    = @{ Packages = @{ Node = @{ Id = 'OpenJS.NodeJS.LTS'; Command = 'node'; Scope = 'machine' } } }
    Logs      = @{ Keep = 5 }
    Update    = @{ KeepBackups = 3 }
    Files     = @{
        Root = ''; McpoVersion = '0.0.20'; Python = '3.12'; McpoWith = @('mcp==1.30.0', 'fastapi<0.145'); McpoExcludeNewer = '2026-10-13T00:00:00Z'
        ServerVersion = '2.0.1'; AllowedTools = @('read_text_file', 'list_directory')
        DisabledTools = @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file'); DenyPatterns = @('*.key', '*secret*')
    }
}
'@

        # Write a user settings file holding $Text and return its path.
        function Write-UserSetting([string]$Text) {
            return Write-TestFile 'settings\user.psd1' $Text
        }
    }

    AfterAll {
        Remove-Item -LiteralPath 'Env:\LOCALAI_TEST_DIR' -ErrorAction SilentlyContinue
    }

    It 'returns the defaults when the user file is absent' {
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath (Join-Path $TestDrive 'absent.psd1')
        $settings.Ports.OpenWebUI | Should -Be 8080
        $settings.Model.Alias | Should -Be 'local-chat'
    }

    It 'merges nested tables key by key' {
        $user = Write-UserSetting '@{ Ports = @{ ComfyUI = 9000 } }'
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.Ports.ComfyUI | Should -Be 9000
        $settings.Ports.OpenWebUI | Should -Be 8080
    }

    It 'replaces lists instead of merging them' {
        $user = Write-UserSetting "@{ ComfyUI = @{ Args = @('--three') } }"
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        ($settings.ComfyUI.Args -is [array]) | Should -BeTrue
        $settings.ComfyUI.Args.Count | Should -Be 1
        $settings.ComfyUI.Args[0] | Should -Be '--three'
    }

    It 'replaces single values and keeps their siblings' {
        $user = Write-UserSetting "@{ Model = @{ Alias = 'other-chat' }; Images = @{ Enabled = `$false } }"
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.Model.Alias | Should -Be 'other-chat'
        $settings.Model.Sha256 | Should -Be ''
        $settings.Images.Enabled | Should -BeFalse
        $settings.Images.Steps | Should -Be 6
    }

    It 'rejects an unknown user key and names its dotted path' {
        $user = Write-UserSetting '@{ Ports = @{ Bogus = 9100 } }'
        { Get-LocalAISettings -DefaultsPath $defaults -UserPath $user } |
            Should -Throw -ExpectedMessage "*Unknown setting 'Ports.Bogus'*"
    }

    It 'rejects a plain value where the defaults hold a table' {
        $user = Write-UserSetting '@{ Ports = 8080 }'
        { Get-LocalAISettings -DefaultsPath $defaults -UserPath $user } |
            Should -Throw -ExpectedMessage "*Setting 'Ports' must be a table*"
    }

    It 'accepts new keys under the open map OpenWebUI.Env' {
        $user = Write-UserSetting "@{ OpenWebUI = @{ Env = @{ ENABLE_SIGNUP = 'False' } } }"
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.OpenWebUI.Env.ENABLE_SIGNUP | Should -Be 'False'
        $settings.OpenWebUI.Env.WEBUI_AUTH | Should -Be 'True'
    }

    It 'expands %VAR% in strings from both layers, including inside lists' {
        $user = Write-UserSetting "@{ ComfyUI = @{ Args = @('--dir=%LOCALAI_TEST_DIR%') } }"
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.OpenWebUI.DataDir | Should -Be 'C:\LocalAITest\data'
        $settings.ComfyUI.Args[0] | Should -Be '--dir=C:\LocalAITest'
        $settings.Shortcuts.Folder | Should -Be 'C:\LocalAITest\menu'
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a port below 1024'; Text = '@{ Ports = @{ ComfyUI = 80 } }'; Message = "*'Ports.ComfyUI' = '80' must be a whole number from 1024 to 65535*" }
        @{ Name = 'a port above 65535'; Text = '@{ Ports = @{ ComfyUI = 70000 } }'; Message = "*'Ports.ComfyUI' = '70000' must be*" }
        @{ Name = 'a port written as text'; Text = "@{ Ports = @{ ComfyUI = '8188' } }"; Message = "*'Ports.ComfyUI' = '8188' must be a whole number*" }
        @{ Name = 'two services on one port'; Text = '@{ Ports = @{ ComfyUI = 8080 } }'; Message = '*Ports.ComfyUI, Ports.OpenWebUI all use port 8080*' }
        @{ Name = 'the image gate on the ComfyUI port'; Text = '@{ Ports = @{ ImageGate = 8188 } }'; Message = '*Ports.ComfyUI, Ports.ImageGate all use port 8188*' }
        @{ Name = 'an image gate port below 1024'; Text = '@{ Ports = @{ ImageGate = 819 } }'; Message = "*'Ports.ImageGate' = '819' must be a whole number from 1024 to 65535*" }
        @{ Name = 'the image gate port written as text'; Text = "@{ Ports = @{ ImageGate = '8190' } }"; Message = "*'Ports.ImageGate' = '8190' must be a whole number*" }
        @{ Name = 'Images.UnloadChat written as text'; Text = "@{ Images = @{ UnloadChat = 'yes' } }"; Message = "*'Images.UnloadChat' = 'yes' must be `$true or `$false*" }
        @{ Name = 'an unload timeout of 0 s'; Text = '@{ Images = @{ UnloadTimeoutSeconds = 0 } }'; Message = "*'Images.UnloadTimeoutSeconds' = '0' must be a whole number from 1 to 3600*" }
        @{ Name = 'a SHA-256 of the wrong length'; Text = "@{ Model = @{ Sha256 = 'abc123' } }"; Message = "*'Model.Sha256' = 'abc123' must be 64 hexadecimal characters or empty*" }
        @{ Name = 'a SHA-256 with non-hex characters'; Text = "@{ Model = @{ Sha256 = '$('g' * 64)' } }"; Message = "*'Model.Sha256'*64 hexadecimal*" }
        @{ Name = 'an alias with capitals'; Text = "@{ Model = @{ Alias = 'Local-Chat' } }"; Message = "*'Model.Alias' = 'Local-Chat' may use only*" }
        @{ Name = 'an alias with a space'; Text = "@{ Model = @{ Alias = 'local chat' } }"; Message = "*'Model.Alias'*may use only*" }
        @{ Name = 'Logs.Keep of 0'; Text = '@{ Logs = @{ Keep = 0 } }'; Message = "*'Logs.Keep' = '0' must be a whole number from 1 to 20*" }
        @{ Name = 'Logs.Keep of 21'; Text = '@{ Logs = @{ Keep = 21 } }'; Message = "*'Logs.Keep' = '21' must be*" }
        @{ Name = 'no backup kept'; Text = '@{ Update = @{ KeepBackups = 0 } }'; Message = "*'Update.KeepBackups' = '0' must be a whole number from 1 to 20*" }
        @{ Name = '21 backups kept'; Text = '@{ Update = @{ KeepBackups = 21 } }'; Message = "*'Update.KeepBackups' = '21' must be a whole number from 1 to 20*" }
        @{ Name = 'a backup count written as text'; Text = "@{ Update = @{ KeepBackups = '3' } }"; Message = "*'Update.KeepBackups' = '3' must be a whole number.*" }
        @{ Name = 'a timeout of 0 s'; Text = '@{ OpenWebUI = @{ HealthTimeoutSeconds = 0 } }'; Message = "*'OpenWebUI.HealthTimeoutSeconds' = '0' must be a whole number from 1 to 3600*" }
        @{ Name = 'a timeout above 3600 s'; Text = '@{ OpenWebUI = @{ HealthTimeoutSeconds = 3601 } }'; Message = "*'OpenWebUI.HealthTimeoutSeconds' = '3601' must be*" }
        @{ Name = 'a boolean written as text'; Text = "@{ Images = @{ Enabled = 'false' } }"; Message = "*'Images.Enabled' = 'false' must be `$true or `$false*" }
        @{ Name = 'a whole number written as text'; Text = "@{ Images = @{ Steps = '6' } }"; Message = "*'Images.Steps' = '6' must be a whole number.*" }
        @{ Name = 'a list given as one string'; Text = "@{ ComfyUI = @{ Args = '--one' } }"; Message = "*'ComfyUI.Args' = '--one' must be a list*" }
        @{ Name = 'a winget scope other than user or machine'; Text = "@{ Winget = @{ Packages = @{ Node = @{ Scope = 'global' } } } }"; Message = "*'Winget.Packages.Node.Scope' = 'global' must be 'user' or 'machine'*" }
        @{ Name = 'an empty Open WebUI data folder'; Text = "@{ OpenWebUI = @{ DataDir = '' } }"; Message = "*'OpenWebUI.DataDir' = '' must be a full path on a drive letter*" }
        @{ Name = 'a relative Open WebUI data folder'; Text = "@{ OpenWebUI = @{ DataDir = 'open-webui' } }"; Message = "*'OpenWebUI.DataDir' = 'open-webui' must be a full path*" }
        @{ Name = 'an Open WebUI data folder on a share'; Text = "@{ OpenWebUI = @{ DataDir = '\\server\share\open-webui' } }"; Message = "*'OpenWebUI.DataDir'*must be a full path on a drive letter*" }
        @{ Name = 'a ComfyUI commit in capitals'; Text = "@{ ComfyUI = @{ Commit = '483DAE4326356B81DE05D27ACA3F433DD323CC25' } }"; Message = "*'ComfyUI.Commit'*must be a git commit: 40 lowercase hexadecimal characters*" }
        @{ Name = 'a short ComfyUI commit'; Text = "@{ ComfyUI = @{ Commit = '483dae4' } }"; Message = "*'ComfyUI.Commit' = '483dae4' must be a git commit*" }
        @{ Name = 'a checkpoint revision that names a branch'; Text = "@{ Images = @{ Revision = 'main' } }"; Message = "*'Images.Revision' = 'main' must be a git commit: 40 lowercase hexadecimal characters*" }
        @{ Name = 'an exclude-newer date without a time'; Text = "@{ ComfyUI = @{ ExcludeNewer = '2026-10-23' } }"; Message = "*'ComfyUI.ExcludeNewer' = '2026-10-23' must be a UTC time such as '2026-10-23T00:07:14Z'*" }
        @{ Name = 'an exclude-newer time with an offset'; Text = "@{ ComfyUI = @{ ExcludeNewer = '2026-10-23T00:07:14+00:00' } }"; Message = "*'ComfyUI.ExcludeNewer'*must be a UTC time*" }
        @{ Name = 'a relative ComfyUI folder'; Text = "@{ ComfyUI = @{ Dir = 'ComfyUI' } }"; Message = "*'ComfyUI.Dir' = 'ComfyUI' must be a full path on a drive letter of at most 133 characters*" }
        @{ Name = 'a ComfyUI folder longer than 133 characters'; Text = "@{ ComfyUI = @{ Dir = 'C:\$('d' * 131)' } }"; Message = "*'ComfyUI.Dir'*of at most 133 characters*" }
        @{ Name = 'a resolution with a star'; Text = "@{ Images = @{ Resolution = '1024*1024' } }"; Message = "*'Images.Resolution' = '1024*1024' must be <width>x<height>*" }
        @{ Name = 'a resolution with a unit'; Text = "@{ Images = @{ Resolution = '1024x1024px' } }"; Message = "*'Images.Resolution'*must be <width>x<height>*" }
        @{ Name = 'a resolution with a capital X'; Text = "@{ Images = @{ Resolution = '1024X1024' } }"; Message = "*'Images.Resolution'*must be <width>x<height>*" }
        @{ Name = '0 image steps'; Text = '@{ Images = @{ Steps = 0 } }'; Message = "*'Images.Steps' = '0' must be a whole number from 1 to 100*" }
        @{ Name = '101 image steps'; Text = '@{ Images = @{ Steps = 101 } }'; Message = "*'Images.Steps' = '101' must be a whole number from 1 to 100*" }
        @{ Name = 'a relative file-tools folder'; Text = "@{ Files = @{ Root = 'AI-Files' } }"; Message = "*'Files.Root' = 'AI-Files' must be empty or a full path on a drive letter*" }
        @{ Name = 'a file-tools folder on a share'; Text = "@{ Files = @{ Root = '\\server\share\files' } }"; Message = "*'Files.Root'*must be empty or a full path on a drive letter*" }
        @{ Name = 'an mcpo version range'; Text = "@{ Files = @{ McpoVersion = '>=0.0.20' } }"; Message = "*'Files.McpoVersion' = '>=0.0.20' must be an exact version such as '2.0.1'*" }
        @{ Name = 'a server version with a caret'; Text = "@{ Files = @{ ServerVersion = '^2.0.1' } }"; Message = "*'Files.ServerVersion' = '^2.0.1' must be an exact version*" }
        @{ Name = 'an mcpo Python with a patch version'; Text = "@{ Files = @{ Python = '3.12.16' } }"; Message = "*'Files.Python' = '3.12.16' must be a Python minor version such as '3.12'*" }
        @{ Name = 'an mcpo requirement without a version'; Text = "@{ Files = @{ McpoWith = @('mcp') } }"; Message = "*'Files.McpoWith' = 'mcp' must list package requirements such as 'mcp==1.30.0'*" }
        @{ Name = 'an mcpo requirement that is an option'; Text = "@{ Files = @{ McpoWith = @('mcp==1.30.0', '--index-url=http://x') } }"; Message = "*'Files.McpoWith'*must list package requirements*" }
        @{ Name = 'an mcpo cut-off date without a time'; Text = "@{ Files = @{ McpoExcludeNewer = '2026-10-13' } }"; Message = "*'Files.McpoExcludeNewer' = '2026-10-13' must be empty or a UTC time*" }
        @{ Name = 'a tool name with a comma'; Text = "@{ Files = @{ AllowedTools = @('read_text_file,write_file') } }"; Message = "*'Files.AllowedTools'*must list tool names made of lowercase letters, digits and `"_`"*" }
        @{ Name = 'a tool name in capitals'; Text = "@{ Files = @{ DisabledTools = @('Write_File', 'write_file', 'edit_file', 'create_directory', 'move_file') } }"; Message = "*'Files.DisabledTools'*must list tool names*" }
        @{ Name = 'an empty deny pattern'; Text = "@{ Files = @{ DenyPatterns = @('*.key', ' ') } }"; Message = "*'Files.DenyPatterns'*must list file or folder name patterns, none of them empty*" }
        @{ Name = 'a tool both offered and hidden'; Text = "@{ Files = @{ AllowedTools = @('read_text_file', 'move_file') } }"; Message = '*Files.AllowedTools and Files.DisabledTools both name move_file; a tool is either offered or hidden*' }
        @{ Name = 'a write tool left visible'; Text = "@{ Files = @{ DisabledTools = @('read_file', 'write_file', 'create_directory') } }"; Message = "*'Files.DisabledTools' must hide every write tool, but leaves out edit_file, move_file*" }
        @{ Name = 'no tool offered'; Text = '@{ Files = @{ AllowedTools = @() } }'; Message = "*'Files.AllowedTools' must name at least one tool*" }
        @{ Name = 'Model.Alias among the superseded aliases'; Text = "@{ Model = @{ SupersededAliases = @('old-chat', 'local-chat') } }"; Message = "*'Model.SupersededAliases' names local-chat, which Model.Alias or Model.Source uses; update never removes those*" }
        @{ Name = 'Model.Alias with its tag among the superseded aliases'; Text = "@{ Model = @{ SupersededAliases = @('LOCAL-CHAT:latest') } }"; Message = "*'Model.SupersededAliases' names LOCAL-CHAT:latest, which Model.Alias or Model.Source uses*" }
        @{ Name = 'Model.Source among the superseded aliases'; Text = "@{ Model = @{ SupersededAliases = @('hf.co/Org/Chat-GGUF:Q6_K') } }"; Message = "*'Model.SupersededAliases' names hf.co/Org/Chat-GGUF:Q6_K*" }
        @{ Name = 'a superseded alias with a space'; Text = "@{ Model = @{ SupersededAliases = @('old chat') } }"; Message = "*'Model.SupersededAliases' = 'old chat' must list Ollama model names such as 'old-chat' or 'old-chat:latest'*" }
        @{ Name = 'a superseded alias that is an option'; Text = "@{ Model = @{ SupersededAliases = @('--force') } }"; Message = "*'Model.SupersededAliases'*must list Ollama model names*" }
        @{ Name = 'superseded aliases given as one string'; Text = "@{ Model = @{ SupersededAliases = 'old-chat' } }"; Message = "*'Model.SupersededAliases' = 'old-chat' must be a list*" }
        @{ Name = 'a relative shortcuts folder'; Text = "@{ Shortcuts = @{ Folder = 'Local AI' } }"; Message = "*'Shortcuts.Folder' = 'Local AI' must be a full path on a drive letter*" }
        @{ Name = 'an empty shortcuts folder'; Text = "@{ Shortcuts = @{ Folder = '' } }"; Message = "*'Shortcuts.Folder' = '' must be a full path on a drive letter*" }
        @{ Name = 'an inherited variable with "="'; Text = "@{ OpenWebUI = @{ InheritEnvironment = @('HTTPS_PROXY=http://proxy:3128') } }"
            Message = "*'OpenWebUI.InheritEnvironment' = 'HTTPS_PROXY=http://proxy:3128' must list variable names such as 'HTTPS_PROXY': letters, digits, '_', '.', '-' and parentheses*" }
        @{ Name = 'an inherited variable with a space'; Text = "@{ ComfyUI = @{ InheritEnvironment = @('CUDA DEVICE') } }"; Message = "*'ComfyUI.InheritEnvironment' = 'CUDA DEVICE' must list variable names*" }
        @{ Name = 'an empty inherited variable'; Text = "@{ OpenWebUI = @{ InheritEnvironment = @('HTTPS_PROXY', '') } }"; Message = "*'OpenWebUI.InheritEnvironment'*must list variable names*" }
        @{ Name = 'an inherited variable as a pattern'; Text = "@{ OpenWebUI = @{ InheritEnvironment = @('HF_*') } }"; Message = "*'OpenWebUI.InheritEnvironment' = 'HF_*' must list variable names*" }
        @{ Name = 'an inherited variable left as %VAR%'; Text = "@{ ComfyUI = @{ InheritEnvironment = @('%LOCALAI_TEST_UNSET%') } }"; Message = "*'ComfyUI.InheritEnvironment' = '%LOCALAI_TEST_UNSET%' must list variable names*" }
        @{ Name = 'inherited variables given as one string'; Text = "@{ OpenWebUI = @{ InheritEnvironment = 'HTTPS_PROXY' } }"; Message = "*'OpenWebUI.InheritEnvironment' = 'HTTPS_PROXY' must be a list*" }
        @{ Name = 'an inherited token'; Text = "@{ OpenWebUI = @{ InheritEnvironment = @('HTTPS_PROXY', 'HF_TOKEN') } }"
            Message = "*'OpenWebUI.InheritEnvironment' names HF_TOKEN, which no service gets: start withholds every variable whose name ends in _TOKEN or _API_KEY*" }
        @{ Name = 'an inherited API key in other case'; Text = "@{ ComfyUI = @{ InheritEnvironment = @('Openai_Api_Key') } }"; Message = "*'ComfyUI.InheritEnvironment' names Openai_Api_Key, which no service gets*" }
    ) {
        $user = Write-UserSetting $Text
        { Get-LocalAISettings -DefaultsPath $defaults -UserPath $user } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses <Withheld> in <Setting>, which points Python or Node.js at other code and never reaches a service' -ForEach @(
        @{ Withheld = 'PYTHONHOME'; Setting = 'OpenWebUI' }
        @{ Withheld = 'PYTHONPATH'; Setting = 'ComfyUI' }
        @{ Withheld = 'PYTHONSTARTUP'; Setting = 'OpenWebUI' }
        @{ Withheld = 'pythonuserbase'; Setting = 'ComfyUI' }
        @{ Withheld = 'NODE_OPTIONS'; Setting = 'OpenWebUI' }
        @{ Withheld = 'NODE_PATH'; Setting = 'ComfyUI' }
    ) {
        $user = Write-UserSetting "@{ $Setting = @{ InheritEnvironment = @('$Withheld') } }"
        { Get-LocalAISettings -DefaultsPath $defaults -UserPath $user } |
            Should -Throw -ExpectedMessage "*'$Setting.InheritEnvironment' names $Withheld, which no service gets*point Python or Node.js at other code*"
    }

    It 'accepts more variables for Open WebUI and ComfyUI to inherit, parentheses, dots and dashes included, and none at all' {
        $user = Write-UserSetting ("@{ OpenWebUI = @{ InheritEnvironment = @('HTTPS_PROXY', 'NO_PROXY', 'SSL_CERT_FILE', 'ProgramFiles(x86)') }; " +
            "ComfyUI = @{ InheritEnvironment = @('CUDA_DEVICE_ORDER', 'my.tool-home') } }")
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.OpenWebUI.InheritEnvironment | Should -Be @('HTTPS_PROXY', 'NO_PROXY', 'SSL_CERT_FILE', 'ProgramFiles(x86)')
        $settings.ComfyUI.InheritEnvironment | Should -Be @('CUDA_DEVICE_ORDER', 'my.tool-home')
        # A key of the open map OpenWebUI.Env named so is a value Open WebUI gets, not a list of names.
        $user = Write-UserSetting "@{ OpenWebUI = @{ InheritEnvironment = @(); Env = @{ InheritEnvironment = 'not a name' } } }"
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        @($settings.OpenWebUI.InheritEnvironment) | Should -BeNullOrEmpty
        $settings.OpenWebUI.Env.InheritEnvironment | Should -BeExactly 'not a name'
    }

    It 'accepts another free image gate port and turns the unload off' {
        $user = Write-UserSetting '@{ Ports = @{ ImageGate = 18190 }; Images = @{ UnloadChat = $false; UnloadTimeoutSeconds = 3600 } }'
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.Ports.ImageGate | Should -Be 18190
        $settings.Images.UnloadChat | Should -BeFalse
        $settings.Images.UnloadTimeoutSeconds | Should -Be 3600
    }

    It 'accepts a file-tools folder, other mcpo pins and an empty cut-off date' {
        $user = Write-UserSetting ("@{ Files = @{ Root = 'D:\AI-Folder'; McpoVersion = '0.0.21'; Python = '3.13'; McpoWith = @('mcp>=1.30.0,<2', 'fastapi < 0.145'); " +
            "McpoExcludeNewer = ''; AllowedTools = @('read_text_file'); DenyPatterns = @() } }")
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.Files.Root | Should -BeExactly 'D:\AI-Folder'
        $settings.Files.McpoWith | Should -Be @('mcp>=1.30.0,<2', 'fastapi < 0.145')
        $settings.Files.McpoExcludeNewer | Should -BeExactly ''
        @($settings.Files.AllowedTools) | Should -Be @('read_text_file')
    }

    It 'accepts superseded aliases with and without a tag, none at all, and another shortcuts folder' {
        $user = Write-UserSetting "@{ Model = @{ SupersededAliases = @('old-chat:latest', 'library/older_chat-2.1') }; Shortcuts = @{ Folder = 'D:\Menu\Local AI' } }"
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.Model.SupersededAliases | Should -Be @('old-chat:latest', 'library/older_chat-2.1')
        $settings.Shortcuts.Folder | Should -BeExactly 'D:\Menu\Local AI'
        $user = Write-UserSetting '@{ Model = @{ SupersededAliases = @() } }'
        @((Get-LocalAISettings -DefaultsPath $defaults -UserPath $user).Model.SupersededAliases) | Should -BeNullOrEmpty
    }

    It 'accepts 1 and 20 kept backups' {
        foreach ($count in 1, 20) {
            $user = Write-UserSetting "@{ Update = @{ KeepBackups = $count } }"
            (Get-LocalAISettings -DefaultsPath $defaults -UserPath $user).Update.KeepBackups | Should -Be $count
        }
    }

    It 'accepts a 64-character hex SHA-256' {
        $user = Write-UserSetting "@{ Model = @{ Sha256 = '$('a1' * 32)' } }"
        (Get-LocalAISettings -DefaultsPath $defaults -UserPath $user).Model.Sha256 | Should -Be ('a1' * 32)
    }

    It 'accepts a ComfyUI folder of 133 characters, 1 and 100 image steps and another resolution' {
        $folder = 'C:\' + ('d' * 130)
        $user = Write-UserSetting "@{ ComfyUI = @{ Dir = '$folder' }; Images = @{ Steps = 100; Resolution = '832x1216' } }"
        $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $user
        $settings.ComfyUI.Dir.Length | Should -Be 133
        $settings.Images.Resolution | Should -Be '832x1216'
        $user = Write-UserSetting '@{ Images = @{ Steps = 1 } }'
        (Get-LocalAISettings -DefaultsPath $defaults -UserPath $user).Images.Steps | Should -Be 1
    }

    It 'reports every violation in one error' {
        $user = Write-UserSetting "@{ Ports = @{ ComfyUI = 80; Bogus = 1 }; Model = @{ Alias = 'Bad Name'; Sha256 = 'xyz' }; Logs = @{ Keep = 0 } }"
        $thrown = { Get-LocalAISettings -DefaultsPath $defaults -UserPath $user } | Should -Throw -PassThru
        foreach ($path in 'Ports.Bogus', 'Ports.ComfyUI', 'Model.Alias', 'Model.Sha256', 'Logs.Keep') {
            $thrown.Exception.Message | Should -BeLike "*'$path'*"
        }
    }

    It 'reads a user file saved as UTF-8 without BOM, keeping non-ASCII paths intact' {
        $folder = 'D:\Documents\' + [char]0xDC + '-test'
        $user = Write-UserSetting "@{ OpenWebUI = @{ DataDir = '$folder' } }"
        (Get-LocalAISettings -DefaultsPath $defaults -UserPath $user).OpenWebUI.DataDir | Should -BeExactly $folder
    }

    It 'rejects a user file that is not UTF-8 and names it' {
        $path = Join-Path $TestDrive 'settings\ansi.psd1'
        [IO.File]::WriteAllText($path, "@{ OpenWebUI = @{ DataDir = 'D:\" + [char]0xDC + "' } }", [Text.Encoding]::GetEncoding(1252))
        { Get-LocalAISettings -DefaultsPath $defaults -UserPath $path } |
            Should -Throw -ExpectedMessage "*Cannot read settings file '*ansi.psd1': It is not UTF-8 text*"
    }

    It 'names the file, line and column of a syntax error' {
        $user = Write-UserSetting "@{`r`n    Ports = @{ ComfyUI = 9000 }`r`n"
        { Get-LocalAISettings -DefaultsPath $defaults -UserPath $user } |
            Should -Throw -ExpectedMessage "*Cannot read settings file '*user.psd1': line *, column *"
    }

    It 'refuses a user file that would run code' {
        $user = Write-UserSetting '@{ OpenWebUI = @{ DataDir = $env:USERPROFILE } }'
        { Get-LocalAISettings -DefaultsPath $defaults -UserPath $user } |
            Should -Throw -ExpectedMessage "*Cannot read settings file '*user.psd1'*dynamic expression*"
    }
}

Describe 'ConvertTo-LocalAIHashtable' {
    It 'turns JSON objects into hashtables and keeps arrays as arrays' {
        $json = '{"a":{"b":["x"]},"c":[{"d":2}],"e":null,"f":[]}' | ConvertFrom-Json
        $table = ConvertTo-LocalAIHashtable -InputObject $json
        ($table -is [hashtable]) | Should -BeTrue
        ($table.a -is [hashtable]) | Should -BeTrue
        ($table.a.b -is [array]) | Should -BeTrue
        $table.a.b.Count | Should -Be 1
        ($table.c[0] -is [hashtable]) | Should -BeTrue
        $table.c[0].d | Should -Be 2
        $table.ContainsKey('e') | Should -BeTrue
        $table.e | Should -BeNullOrEmpty
        ($table.f -is [array]) | Should -BeTrue
        $table.f.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-LocalAIJson' {
    It 'reads an object with an empty key, as the root package of an npm lockfile, into hashtables and lists' {
        $table = ConvertFrom-LocalAIJson -Text '{"lockfileVersion": 3, "packages": {"": {"dependencies": {"a": "1.0.0"}}, "node_modules/a": {"version": "1.0.0", "bin": ["x"]}}}'
        ($table -is [hashtable]) | Should -BeTrue
        $table.lockfileVersion | Should -Be 3
        ($table.packages -is [hashtable]) | Should -BeTrue
        $table.packages[''].dependencies.a | Should -BeExactly '1.0.0'
        ($table.packages['node_modules/a'].bin -is [array]) | Should -BeTrue
        $table.packages['node_modules/a'].bin.Count | Should -Be 1
    }

    It 'returns a JSON list as a list, also with one element' {
        $list = ConvertFrom-LocalAIJson -Text '[{"a": null}]'
        ($list -is [array]) | Should -BeTrue
        $list.Count | Should -Be 1
        $list[0].ContainsKey('a') | Should -BeTrue
    }

    It 'throws for text that is not JSON' {
        { ConvertFrom-LocalAIJson -Text '{ "a": ' } | Should -Throw
    }
}

Describe 'Read-LocalAIState and Write-LocalAIState' {
    It 'round-trips nested tables and one-element arrays, creating the folder' {
        $path = Join-Path $TestDrive 'state\deep\state.json'
        Write-LocalAIState -Path $path -State @{
            Name   = 'x'
            Port   = 8080
            Nested = @{ Inner = @{ Value = 'y' }; List = @('only') }
            Many   = @(1, 2)
        }
        $state = Read-LocalAIState -Path $path
        $state.Name | Should -Be 'x'
        $state.Port | Should -Be 8080
        $state.Nested.Inner.Value | Should -Be 'y'
        ($state.Nested.List -is [array]) | Should -BeTrue
        $state.Nested.List.Count | Should -Be 1
        $state.Many.Count | Should -Be 2
    }

    It 'writes state it read back without changing its shape' {
        $first = Join-Path $TestDrive 'reshape\first.json'
        $second = Join-Path $TestDrive 'reshape\second.json'
        Write-LocalAIState -Path $first -State @{ List = @('only'); Nested = @{ Ids = @(7) } }
        Write-LocalAIState -Path $second -State (Read-LocalAIState -Path $first)
        $state = Read-LocalAIState -Path $second
        ($state.List -is [array]) | Should -BeTrue
        $state.List[0] | Should -Be 'only'
        $state.Nested.Ids[0] | Should -Be 7
    }

    It 'round-trips a process start time stored as UTC ticks exactly' {
        $path = Join-Path $TestDrive 'ticks\state.json'
        $ticks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        Write-LocalAIState -Path $path -State @{ Service = @{ StartTicks = $ticks } }
        $back = (Read-LocalAIState -Path $path).Service.StartTicks
        $back | Should -BeOfType [long]
        $back | Should -Be $ticks
    }

    It 'refuses a DateTime and names its path, writing nothing' {
        $folder = Join-Path $TestDrive 'datetime'
        $path = Join-Path $folder 'state.json'
        { Write-LocalAIState -Path $path -State @{ Service = @{ StartTime = (Get-Date) } } } |
            Should -Throw -ExpectedMessage "*'Service.StartTime' is a DateTime*Ticks*"
        Test-Path -LiteralPath $folder | Should -BeFalse
    }

    It 'refuses types other than tables, lists, strings, numbers and booleans' {
        $path = Join-Path $TestDrive 'object\state.json'
        { Write-LocalAIState -Path $path -State @{ Item = @([pscustomobject]@{ A = 1 }) } } |
            Should -Throw -ExpectedMessage "*'Item``[0``]' has type ``[System.Management.Automation.PSCustomObject``]*"
    }

    It 'writes a string read by Get-Content without its extra properties' {
        $source = Write-TestFile 'ets\line.txt' 'hello'
        $path = Join-Path $TestDrive 'ets\state.json'
        Write-LocalAIState -Path $path -State @{ Line = (Get-Content -LiteralPath $source) }
        [IO.File]::ReadAllText($path) | Should -Not -BeLike '*PSPath*'
        (Read-LocalAIState -Path $path).Line | Should -BeExactly 'hello'
    }

    It 'writes UTF-8 without a byte order mark' {
        $path = Join-Path $TestDrive 'bom\state.json'
        Write-LocalAIState -Path $path -State @{ Text = 'plain' }
        [IO.File]::ReadAllBytes($path)[0] | Should -Be ([byte][char]'{')
    }

    It 'writes non-ASCII text raw as UTF-8, or as \u escapes with -Ascii, and reads both back the same' {
        $text = 'D:\' + [char]0xFC + '-test\' + [char]0x4E2D + [char]0xD83D + [char]0xDE00
        $raw = Join-Path $TestDrive 'ascii\raw.json'
        $escaped = Join-Path $TestDrive 'ascii\escaped.json'
        Write-LocalAIState -Path $raw -State @{ Text = $text }
        Write-LocalAIState -Path $escaped -State @{ Text = $text } -Ascii
        @([IO.File]::ReadAllBytes($raw) | Where-Object { $_ -gt 127 }).Count | Should -BeGreaterThan 0
        $bytes = [IO.File]::ReadAllBytes($escaped)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $bytes[0] | Should -Be ([byte][char]'{')
        [Text.Encoding]::ASCII.GetString($bytes) | Should -BeLike '*"D:\\\u00fc-test\\\u4e2d\ud83d\ude00"*'
        (Read-LocalAIState -Path $escaped).Text | Should -BeExactly $text
        (Read-LocalAIState -Path $raw).Text | Should -BeExactly $text
    }

    It 'returns an empty hashtable when the file does not exist' {
        $state = Read-LocalAIState -Path (Join-Path $TestDrive 'absent\state.json')
        ($state -is [hashtable]) | Should -BeTrue
        $state.Count | Should -Be 0
    }

    It 'names the file when it is not valid JSON' {
        $path = Write-TestFile 'corrupt\state.json' '{ not json'
        { Read-LocalAIState -Path $path } | Should -Throw -ExpectedMessage '*corrupt\state.json*not valid JSON*'
    }

    It 'rejects JSON that is not an object' {
        $path = Write-TestFile 'array\state.json' '[1, 2]'
        { Read-LocalAIState -Path $path } | Should -Throw -ExpectedMessage '*array\state.json*does not hold a JSON object*'
    }

    It 'replaces an existing file and leaves no .tmp behind' {
        $folder = Join-Path $TestDrive 'atomic'
        $path = Join-Path $folder 'state.json'
        Write-LocalAIState -Path $path -State @{ Run = 1 }
        Write-LocalAIState -Path $path -State @{ Run = 2 }
        (Read-LocalAIState -Path $path).Run | Should -Be 2
        @(Get-ChildItem -LiteralPath $folder -Force | ForEach-Object Name) | Should -Be @('state.json')
    }

    It 'names the file and removes the .tmp when the replace fails' {
        $folder = Join-Path $TestDrive 'locked'
        $path = Join-Path $folder 'state.json'
        Write-LocalAIState -Path $path -State @{ Run = 1 }
        $reader = [IO.File]::Open($path, 'Open', 'Read', 'Read')
        try {
            { Write-LocalAIState -Path $path -State @{ Run = 2 } } |
                Should -Throw -ExpectedMessage "*Cannot save state file '*locked\state.json'*"
        } finally {
            $reader.Dispose()
        }
        @(Get-ChildItem -LiteralPath $folder -Force | ForEach-Object Name) | Should -Be @('state.json')
        (Read-LocalAIState -Path $path).Run | Should -Be 1
    }
}

Describe 'Invoke-LogRotation' {
    It 'shifts each generation up and drops the oldest' {
        $log = Write-TestFile 'rotate\service.log' 'current'
        $null = Write-TestFile 'rotate\service.log.1' 'one'
        $null = Write-TestFile 'rotate\service.log.2' 'two'
        Invoke-LogRotation -Path $log -Keep 2
        Test-Path -LiteralPath $log | Should -BeFalse
        Get-Content -LiteralPath "$log.1" | Should -Be 'current'
        Get-Content -LiteralPath "$log.2" | Should -Be 'one'
        Test-Path -LiteralPath "$log.3" | Should -BeFalse
    }

    It 'skips generations that do not exist' {
        $log = Write-TestFile 'gaps\service.log' 'current'
        Invoke-LogRotation -Path $log -Keep 5
        Get-Content -LiteralPath "$log.1" | Should -Be 'current'
        { Invoke-LogRotation -Path (Join-Path $TestDrive 'none\service.log') -Keep 5 } | Should -Not -Throw
    }

    It 'names the log when a running process still holds it open' {
        $log = Write-TestFile 'held\service.log' 'current'
        $writer = [IO.File]::Open($log, 'Open', 'Write', 'Read')
        try {
            { Invoke-LogRotation -Path $log -Keep 2 } |
                Should -Throw -ExpectedMessage "*Cannot rotate the log '*held\service.log'*"
        } finally {
            $writer.Dispose()
        }
    }
}

Describe 'Remove-OldLogs' {
    BeforeAll {
        # Create $Name in TestDrive:\$Folder with a last write time $AgeHours in the past.
        function Write-AgedLog([string]$Folder, [string]$Name, [double]$AgeHours) {
            $path = Write-TestFile (Join-Path $Folder $Name) 'log'
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddHours(-$AgeHours)
        }
    }

    It 'keeps only the KeepCount newest matching files' {
        foreach ($i in 1..5) { Write-AgedLog -Folder 'count' -Name "launcher-$i.log" -AgeHours $i }
        Write-AgedLog -Folder 'count' -Name 'other.txt' -AgeHours 100
        $folder = Join-Path $TestDrive 'count'
        Remove-OldLogs -Directory $folder -Filter 'launcher-*.log' -KeepCount 3
        @(Get-ChildItem -LiteralPath $folder -Filter 'launcher-*.log' | ForEach-Object Name | Sort-Object) |
            Should -Be @('launcher-1.log', 'launcher-2.log', 'launcher-3.log')
        Test-Path -LiteralPath (Join-Path $folder 'other.txt') | Should -BeTrue
    }

    It 'deletes files older than MaxAgeDays even below KeepCount' {
        Write-AgedLog -Folder 'age' -Name 'launcher-new.log' -AgeHours 24
        Write-AgedLog -Folder 'age' -Name 'launcher-old.log' -AgeHours (20 * 24)
        $folder = Join-Path $TestDrive 'age'
        Remove-OldLogs -Directory $folder -Filter 'launcher-*.log' -KeepCount 20 -MaxAgeDays 14
        @(Get-ChildItem -LiteralPath $folder | ForEach-Object Name) | Should -Be @('launcher-new.log')
    }

    It 'ignores a missing folder' {
        { Remove-OldLogs -Directory (Join-Path $TestDrive 'absent') -Filter '*.log' } | Should -Not -Throw
    }
}

Describe 'Invoke-Native' {
    BeforeAll {
        # A console program that, given --argv <file>, writes each further argument to <file> in
        # brackets; otherwise it writes UTF-8 bytes to stdout, then a blank line and text to stderr.
        $program = Join-Path $TestDrive 'native\localai-test.exe'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $program -Parent)
        Add-Type -OutputAssembly $program -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class LocalAITestProgram {
    public static int Main(string[] args) {
        if (args.Length > 1 && args[0] == "--argv") {
            string[] lines = new string[args.Length - 2];
            for (int i = 2; i < args.Length; i++) { lines[i - 2] = "[" + args[i] + "]"; }
            File.WriteAllLines(args[1], lines, new UTF8Encoding(false));
            return 0;
        }
        byte[] text = new UTF8Encoding(false).GetBytes("to-stdout \u00DC\u2713\n");
        using (Stream stdout = Console.OpenStandardOutput()) { stdout.Write(text, 0, text.Length); }
        Console.Error.WriteLine();
        Console.Error.WriteLine("to-stderr");
        return 0;
    }
}
'@
    }

    It 'returns an exit code listed in SuccessCode' {
        Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 3' -SuccessCode 0, 3 | Should -Be 3
    }

    It 'throws with the program, its arguments and the code for any other exit code' {
        { Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 3' } |
            Should -Throw -ExpectedMessage "*'cmd.exe /c exit 3' failed with exit code 3*"
    }

    It 'returns only the code when the program writes to stderr' {
        $result = @(Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'echo to-stdout & echo to-stderr 1>&2')
        $result.Count | Should -Be 1
        $result[0] | Should -Be 0
    }

    It 'prints stderr text, blank lines and UTF-8 output as they are' {
        $log = Join-Path $TestDrive 'native\output.log'
        $null = Start-Transcript -LiteralPath $log
        try {
            $null = Invoke-Native -FilePath $program
        } finally {
            $null = Stop-Transcript
        }
        $text = [IO.File]::ReadAllText($log)
        $text | Should -BeLike ('*to-stdout ' + [char]0xDC + [char]0x2713 + '*')
        $text | Should -BeLike '*to-stderr*'
        $text | Should -Not -BeLike '*RemoteException*'
    }

    It 'passes empty arguments, quotes, spaces and trailing backslashes intact' {
        $received = Join-Path $TestDrive 'native\argv.txt'
        $sent = @('first', '', 'C:\My Models\', 'say "hi"', 'a "b c" d', "tab`tx", 'x\\', '\\server\share\', 'trail\', '"', 'q"x', 'last')
        $null = Invoke-Native -FilePath $program -ArgumentList (@('--argv', $received) + $sent)
        @([IO.File]::ReadAllLines($received)) | Should -Be @($sent | ForEach-Object { "[$_]" })
    }

    It 'throws for an argument that 5.1 cannot pass intact' {
        { Invoke-Native -FilePath $program -ArgumentList '--argv', 'unused.txt', '"a b"' } |
            Should -Throw -ExpectedMessage "*cannot pass the argument '`"a b`"' intact*"
    }

    It 'throws when the program cannot be found' {
        { Invoke-Native -FilePath 'local-ai-no-such-program.exe' } |
            Should -Throw -ExpectedMessage "*Cannot find the program 'local-ai-no-such-program.exe'*"
    }

    It 'adds stdout and stderr lines to -Capture instead of printing them' {
        $lines = New-Object System.Collections.Generic.List[string]
        $log = Join-Path $TestDrive 'native\capture.log'
        $null = Start-Transcript -LiteralPath $log
        try {
            $result = @(Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'echo captured-out& echo captured-err 1>&2' -Capture $lines)
        } finally {
            $null = Stop-Transcript
        }
        $result | Should -Be @(0)
        $trimmed = @($lines | ForEach-Object { $_.Trim() })
        $trimmed | Should -Contain 'captured-out'
        $trimmed | Should -Contain 'captured-err'
        [IO.File]::ReadAllText($log) | Should -Not -BeLike '*captured-out*'
    }

    It 'keeps the exit-code contract with -Capture' {
        $lines = New-Object System.Collections.Generic.List[string]
        { Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 3' -Capture $lines } |
            Should -Throw -ExpectedMessage "*'cmd.exe /c exit 3' failed with exit code 3*"
    }

    It 'returns only the exit code with -Console' {
        $result = @(Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'echo on-the-console& exit 3' -SuccessCode 0, 3 -Console)
        $result | Should -Be @(3)
    }

    It 'throws for an exit code outside SuccessCode with -Console' {
        { Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 4' -Console } |
            Should -Throw -ExpectedMessage "*'cmd.exe /c exit 4' failed with exit code 4*"
    }

    It 'passes empty arguments, quotes, spaces and trailing backslashes intact with -Console' {
        $received = Join-Path $TestDrive 'native\argv-console.txt'
        $sent = @('first', '', 'C:\My Models\', 'say "hi"', 'a "b c" d', "tab`tx", 'x\\', '\\server\share\', 'trail\', '"', 'q"x', 'last')
        $null = Invoke-Native -FilePath $program -ArgumentList (@('--argv', $received) + $sent) -Console
        @([IO.File]::ReadAllLines($received)) | Should -Be @($sent | ForEach-Object { "[$_]" })
    }

    It 'does not wait for a process the program leaves running with -Console' {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'start /b ping -n 6 127.0.0.1 >nul' -Console
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 3
    }

    It 'stops a program that outlasts -TimeoutSeconds with -Console, and throws' {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-Native -FilePath 'ping.exe' -ArgumentList '-n', '30', '127.0.0.1' -Console -TimeoutSeconds 1 } |
            Should -Throw -ExpectedMessage "*'ping.exe -n 30 127.0.0.1' did not finish within 1 s and was stopped*"
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 10
    }

    It 'returns the exit code of a program that ends within -TimeoutSeconds' {
        Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 3' -SuccessCode 3 -Console -TimeoutSeconds 30 | Should -Be 3
    }
}

Describe 'Update-SessionPath' {
    It 'appends registry entries after the process entries and drops duplicates' {
        $saved = $env:Path
        try {
            $env:Path = 'C:\Tools;C:\Shared\'
            $output = Update-SessionPath -MachinePath 'c:\shared;C:\Machine\;' -UserPath 'C:\TOOLS\;C:\User;C:\Machine'
            $output | Should -BeNullOrEmpty
            $env:Path | Should -Be 'C:\Tools;C:\Shared\;C:\Machine\;C:\User'
        } finally {
            $env:Path = $saved
        }
    }
}

Describe 'Enter-LocalAILock and Exit-LocalAILock' {
    BeforeEach {
        $name = 'Local\LocalAITest-' + [guid]::NewGuid().ToString('N')
    }

    It 'takes a free mutex and releases it again' {
        $mutex = Enter-LocalAILock -Name $name -TimeoutSeconds 0
        $mutex | Should -BeOfType [System.Threading.Mutex]
        Test-MutexFree -Name $name | Should -BeFalse
        Exit-LocalAILock -Mutex $mutex
        Test-MutexFree -Name $name | Should -BeTrue
    }

    It 'returns $null when another thread holds the mutex past the timeout' {
        $holder = Enter-MutexOnOtherThread -Name $name
        try {
            Enter-LocalAILock -Name $name -TimeoutSeconds 0 | Should -BeNullOrEmpty
        } finally {
            Exit-MutexOnOtherThread -Holder $holder
        }
    }

    It 'counts a mutex abandoned by a finished thread as taken' {
        $null = Invoke-OnOtherThread -Arguments @($name) -Script {
            param($Name)
            $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, $Name
            $null = $mutex.WaitOne()
        }
        $mutex = Enter-LocalAILock -Name $name -TimeoutSeconds 5
        $mutex | Should -BeOfType [System.Threading.Mutex]
        Exit-LocalAILock -Mutex $mutex
    }

    It 'ignores a $null mutex' {
        { Exit-LocalAILock -Mutex $null } | Should -Not -Throw
    }
}

Describe 'Set-LocalAIKeepAwake' {
    It 'sets and clears the request' {
        { Set-LocalAIKeepAwake -Enabled $true; Set-LocalAIKeepAwake -Enabled $false } | Should -Not -Throw
        'LocalAI.NativeMethods' -as [type] | Should -Not -BeNullOrEmpty
    }

    It 'does not compile the binding again once it exists' {
        Set-LocalAIKeepAwake -Enabled $false
        Mock Add-Type -ModuleName LocalAI
        Set-LocalAIKeepAwake -Enabled $true
        Set-LocalAIKeepAwake -Enabled $false
        Should -Invoke Add-Type -ModuleName LocalAI -Times 0 -Exactly
    }
}

Describe 'Invoke-LocalAI' {
    BeforeAll {
        # Verb functions defined inside the module, so the dispatcher accepts them. Each records
        # its context in the module's $TestContext.
        InModuleScope -ModuleName LocalAI -ScriptBlock {
            # Succeed with exit code 0.
            function script:Invoke-TestVerbOk([hashtable]$Context) { $script:TestContext = $Context; 0 }
            # Write a line to the pipeline, then report degraded with exit code 2.
            function script:Invoke-TestVerbNoisy([hashtable]$Context) { $script:TestContext = $Context; 'verb-noise'; 2 }
            # End with text instead of an exit code.
            function script:Invoke-TestVerbNoCode([hashtable]$Context) { $script:TestContext = $Context; 'oops' }
            # Stop the dispatcher's transcript itself, then succeed.
            function script:Invoke-TestVerbStopsTranscript([hashtable]$Context) {
                $script:TestContext = $Context
                $null = Stop-Transcript
                0
            }
            # Record whether the lock named $script:TestLockName exists while the verb runs, then succeed.
            function script:Invoke-TestVerbSeesLock([hashtable]$Context) {
                $script:TestContext = $Context
                $script:TestLockSeen = Test-LocalAILockHeld -Name $script:TestLockName
                0
            }
        }

        # Return a verb table like Get-LocalAIVerb's that maps every verb to $Function, accepting $Switches, with its transcripts in Root\logs but for
        # uninstall, and only status running inside an app package's container.
        function Get-TestVerbTable([string]$Function, [string[]]$Switches = @('Json')) {
            $table = @{}
            $locks = @{ start = 'Fail'; status = 'Probe' }
            foreach ($verb in 'install', 'start', 'stop', 'status', 'update', 'uninstall', 'shortcuts') {
                $lock = if ($locks.ContainsKey($verb)) { $locks[$verb] } else { 'Wait' }
                $redirected = if ($verb -eq 'status') { 'Warn' } else { 'Refuse' }
                $table[$verb] = @{ Function = $Function; Switches = $Switches; SettingsOptional = ($verb -ne 'start'); TranscriptInTemp = ($verb -eq 'uninstall'); Lock = $lock
                    Redirected = $redirected }
            }
            return $table
        }

        # Run Invoke-LocalAI with $Arguments, and return @{ Code; Printed } with the host text joined. LocalAppData and AppData default to folders
        # below TestDrive: that hold no Packages folder, and ShellLocalAppData to LocalAppData, so the AppData probe never touches this PC's.
        function Invoke-Dispatcher([hashtable]$Arguments) {
            $Arguments = $Arguments.Clone()
            foreach ($name in 'LocalAppData', 'AppData') {
                if (-not $Arguments.ContainsKey($name)) { $Arguments[$name] = Join-Path $TestDrive "dispatcher-$name" }
            }
            if (-not $Arguments.ContainsKey('ShellLocalAppData')) { $Arguments.ShellLocalAppData = $Arguments.LocalAppData }
            $output = @(Invoke-LocalAI @Arguments 6>&1)
            $printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                    ForEach-Object { "$($_.MessageData)" }) -join "`n"
            return @{ Code = @($output | Where-Object { $_ -is [int] }); Printed = $printed }
        }
    }

    BeforeEach {
        $lock = 'Local\LocalAITest-' + [guid]::NewGuid().ToString('N')
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'returns 1 and says so for a verb without a function, keeping a transcript' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbMissing' }
        $run = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*The 'status' command is not available in this version.*"
        $run.Printed | Should -BeLike '*Log: *launcher-*-status.log*'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter 'launcher-*-status.log').Count | Should -Be 1
        Test-MutexFree -Name $lock | Should -BeTrue
    }

    It 'passes the context to the verb and returns its code' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $run = Invoke-Dispatcher @{ Verb = 'status'; Json = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        $context = InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }
        $context.Verb | Should -Be 'status'
        $context.Json | Should -BeTrue
        $context.Paths.Root | Should -Be $root
        $context.Settings.Model.Alias | Should -Be 'local-chat'
        $context.SettingsError | Should -BeNullOrEmpty
    }

    It 'gives each run its own transcript' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $null = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        $null = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter 'launcher-*-status.log').Count | Should -Be 2
    }

    It 'prints pipeline output before the exit code and returns that code' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbNoisy' }
        $run = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(2)
        $log = Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter 'launcher-*-status.log'
        [IO.File]::ReadAllText($log.FullName) | Should -BeLike '*verb-noise*'
    }

    It 'fails a verb that does not end with exit code 0, 1 or 2' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbNoCode' }
        $run = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Invoke-TestVerbNoCode returned 'oops' instead of exit code 0, 1 or 2.*"
    }

    It 'still returns the code and releases the lock when the verb stopped the transcript' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbStopsTranscript' }
        $run = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        Test-MutexFree -Name $lock | Should -BeTrue
    }

    It 'passes a settings error to stop, status and uninstall instead of failing' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $null = Write-TestFile ((Split-Path $root -Leaf) + '\settings.psd1') '@{ Ports = @{ Bogus = 1 } }'
        $run = Invoke-Dispatcher @{ Verb = 'stop'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        $context = InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }
        $context.Settings | Should -BeNullOrEmpty
        $context.SettingsError | Should -BeLike "*Unknown setting 'Ports.Bogus'*"
    }

    It 'fails other verbs on a settings error' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $null = Write-TestFile ((Split-Path $root -Leaf) + '\settings.psd1') '@{ Ports = @{ Bogus = 1 } }'
        $run = Invoke-Dispatcher @{ Verb = 'start'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Invalid settings*Unknown setting 'Ports.Bogus'*"
    }

    It 'keeps the uninstall transcript in %TEMP% and leaves Root uncreated' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $temp = Join-Path $TestDrive 'temp'
        $null = New-Item -ItemType Directory -Force -Path $temp
        $saved = $env:TMP, $env:TEMP
        try {
            $env:TMP = $temp
            $env:TEMP = $temp
            $run = Invoke-Dispatcher @{ Verb = 'uninstall'; Root = $root; LockName = $lock }
        } finally {
            $env:TMP, $env:TEMP = $saved
        }
        $run.Code | Should -Be @(0)
        Test-Path -LiteralPath $root | Should -BeFalse
        @(Get-ChildItem -LiteralPath $temp -Filter 'local-ai-launcher-*-uninstall.log').Count | Should -Be 1
    }

    It 'rejects a switch that does not apply to the verb' {
        $run = Invoke-Dispatcher @{ Verb = 'shortcuts'; RemoveData = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*-RemoveData does not apply to 'shortcuts'.*"
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'rejects an unknown verb' {
        $run = Invoke-Dispatcher @{ Verb = 'bogus'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Unknown command 'bogus'*"
    }

    It 'gives up at once when start finds another run holding the lock' {
        $holder = Enter-MutexOnOtherThread -Name $lock
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-Dispatcher @{ Verb = 'start'; Root = $root; LockName = $lock }
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 5
        } finally {
            Exit-MutexOnOtherThread -Holder $holder
        }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Another launcher run is active. Wait for it to finish*'
    }

    It 'says it is waiting when another verb finds the lock held, then runs' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $holder = Enter-MutexOnOtherThread -Name $lock -HoldMilliseconds 1500
        try {
            $run = Invoke-Dispatcher @{ Verb = 'stop'; Root = $root; LockName = $lock }
        } finally {
            Exit-MutexOnOtherThread -Holder $holder
        }
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*Another launcher run is active; waiting up to 300 s*'
    }

    It 'maps the install verb to Install-LocalAI in the module' {
        InModuleScope -ModuleName LocalAI -ScriptBlock { (Get-LocalAIVerb).install.Function } | Should -Be 'Install-LocalAI'
        (Get-Command -Name 'Install-LocalAI' -CommandType Function).ModuleName | Should -Be 'LocalAI'
    }

    It 'maps start and stop to their module functions; start takes -NoBrowser and stop needs no settings' {
        $verbs = InModuleScope -ModuleName LocalAI -ScriptBlock { Get-LocalAIVerb }
        $verbs.start.Function | Should -Be 'Start-LocalAI'
        $verbs.start.Switches | Should -Be @('NoBrowser')
        $verbs.stop.Function | Should -Be 'Stop-LocalAI'
        $verbs.stop.SettingsOptional | Should -BeTrue
        (Get-Command -Name 'Start-LocalAI' -CommandType Function).ModuleName | Should -Be 'LocalAI'
        (Get-Command -Name 'Stop-LocalAI' -CommandType Function).ModuleName | Should -Be 'LocalAI'
    }

    It 'passes -NoBrowser to the verb in the context' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith {
            $table = Get-TestVerbTable -Function 'Invoke-TestVerbOk'
            $table.start.Switches = @('NoBrowser')
            $table
        }
        $run = Invoke-Dispatcher @{ Verb = 'start'; NoBrowser = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).NoBrowser | Should -BeTrue
    }

    It 'rejects -NoBrowser for stop' {
        $run = Invoke-Dispatcher @{ Verb = 'stop'; NoBrowser = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*-NoBrowser does not apply to 'stop'.*"
    }

    It 'maps status to Get-LocalAIStatus with -Json and shortcuts to Set-LocalAIShortcut with -Remove' {
        $verbs = InModuleScope -ModuleName LocalAI -ScriptBlock { Get-LocalAIVerb }
        $verbs.status.Function | Should -Be 'Get-LocalAIStatus'
        $verbs.status.Switches | Should -Be @('Json')
        $verbs.status.SettingsOptional | Should -BeTrue
        $verbs.shortcuts.Function | Should -Be 'Set-LocalAIShortcut'
        $verbs.shortcuts.Switches | Should -Be @('Remove')
        (Get-Command -Name 'Get-LocalAIStatus' -CommandType Function).ModuleName | Should -Be 'LocalAI'
        (Get-Command -Name 'Set-LocalAIShortcut' -CommandType Function).ModuleName | Should -Be 'LocalAI'
    }

    It 'maps uninstall to Uninstall-LocalAI with -RemoveData, without settings and with its transcript in %TEMP%' {
        $verbs = InModuleScope -ModuleName LocalAI -ScriptBlock { Get-LocalAIVerb }
        $verbs.uninstall.Function | Should -Be 'Uninstall-LocalAI'
        $verbs.uninstall.Switches | Should -Be @('RemoveData')
        $verbs.uninstall.SettingsOptional | Should -BeTrue
        $verbs.uninstall.TranscriptInTemp | Should -BeTrue
        $command = Get-Command -Name 'Uninstall-LocalAI' -CommandType Function
        $command.ModuleName | Should -Be 'LocalAI'
        $command.ScriptBlock.Attributes.Where({ $_ -is [System.Management.Automation.CmdletBindingAttribute] })[0].ConfirmImpact | Should -Be 'High'
    }

    It 'prints an error as one JSON document, and nothing else, with -Json' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbMissing' }
        $run = Invoke-Dispatcher @{ Verb = 'status'; Json = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $lines = @($run.Printed -split "`n")
        $lines.Count | Should -Be 1
        $document = ConvertFrom-LocalAIJson -Text $lines[0]
        $document.verb | Should -Be 'status'
        $document.exitCode | Should -Be 1
        $document.health | Should -Be 'error'
        $document.error | Should -BeExactly "The 'status' command is not available in this version."
        $document.log | Should -BeLike '*launcher-*-status.log'
    }

    It 'does not say it is waiting for the lock with -Json' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith {
            $table = Get-TestVerbTable -Function 'Invoke-TestVerbOk'
            $table.status.Lock = 'Wait'
            $table
        }
        $holder = Enter-MutexOnOtherThread -Name $lock -HoldMilliseconds 1500
        try {
            $run = Invoke-Dispatcher @{ Verb = 'status'; Json = $true; Root = $root; LockName = $lock }
        } finally {
            Exit-MutexOnOtherThread -Holder $holder
        }
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeNullOrEmpty
    }

    It 'runs a Probe verb at once beside another run, without taking the lock, and passes LockHeld' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbSeesLock' }
        InModuleScope -ModuleName LocalAI -Parameters @{ Name = $lock } -ScriptBlock { param($Name) $script:TestLockName = $Name }
        $run = Invoke-Dispatcher @{ Verb = 'status'; Json = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        # A run that took the lock would have made the mutex exist.
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestLockSeen } | Should -BeFalse
        (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).LockHeld | Should -BeFalse
        $holder = Enter-MutexOnOtherThread -Name $lock
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-Dispatcher @{ Verb = 'status'; Json = $true; Root = $root; LockName = $lock }
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 5
        } finally {
            Exit-MutexOnOtherThread -Holder $holder
        }
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeNullOrEmpty
        (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).LockHeld | Should -BeTrue
    }

    It 'keeps 20 transcripts of each verb, so status runs never push out those of other verbs' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $logs = Join-Path $root 'logs'
        $null = New-Item -ItemType Directory -Force -Path $logs
        $start = Join-Path $logs 'launcher-20261027-100000-000-start.log'
        [IO.File]::WriteAllText($start, "Error: real start failure`r`n")
        foreach ($i in 1..21) {
            $old = Join-Path $logs ('launcher-20261027-1100{0:00}-000-status.log' -f $i)
            [IO.File]::WriteAllText($old, 'status')
            (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddMinutes(-60 + $i)
        }
        $null = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        Test-Path -LiteralPath $start | Should -BeTrue
        @(Get-ChildItem -LiteralPath $logs -Filter 'launcher-*-status.log').Count | Should -Be 20
    }

    It 'prunes the earlier transcripts of a verb to 19 before its own starts, however late Start-Transcript creates the file' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        # This Start-Transcript writes no file, like one that creates it only on its first write, as on a hosted CI runner.
        Mock Start-Transcript -ModuleName LocalAI
        Mock Stop-Transcript -ModuleName LocalAI
        $logs = Join-Path $root 'logs'
        $null = New-Item -ItemType Directory -Force -Path $logs
        foreach ($i in 1..21) {
            $old = Join-Path $logs ('launcher-20261027-1100{0:00}-000-status.log' -f $i)
            [IO.File]::WriteAllText($old, 'status')
            (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddMinutes(-60 + $i)
        }
        $null = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        @(Get-ChildItem -LiteralPath $logs -Filter 'launcher-*-status.log' | Sort-Object Name | ForEach-Object Name) |
            Should -Be @(3..21 | ForEach-Object { 'launcher-20261027-1100{0:00}-000-status.log' -f $_ })
    }

    It 'keeps the status transcript in %TEMP%, so status writes nothing below Root, and never takes the lock for status' {
        $verbs = InModuleScope -ModuleName LocalAI -ScriptBlock { Get-LocalAIVerb }
        $verbs.status.TranscriptInTemp | Should -BeTrue
        $verbs.status.Lock | Should -Be 'Probe'
        $verbs.start.Lock | Should -Be 'Fail'
        foreach ($verb in 'install', 'stop', 'update', 'uninstall', 'shortcuts') { $verbs[$verb].Lock | Should -Be 'Wait' }
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith {
            $table = Get-TestVerbTable -Function 'Invoke-TestVerbOk'
            $table.status.TranscriptInTemp = $true
            $table
        }
        $temp = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $temp
        $saved = $env:TMP, $env:TEMP
        try {
            $env:TMP = $temp
            $env:TEMP = $temp
            $run = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        } finally {
            $env:TMP, $env:TEMP = $saved
        }
        $run.Code | Should -Be @(0)
        Test-Path -LiteralPath $root | Should -BeFalse
        @(Get-ChildItem -LiteralPath $temp -Filter 'local-ai-launcher-*-status.log').Count | Should -Be 1
    }

    It 'tells whether a lock exists without taking it' {
        Invoke-ModuleFunction 'Test-LocalAILockHeld' @{ Name = $lock } | Should -BeFalse
        $holder = Enter-MutexOnOtherThread -Name $lock
        try {
            Invoke-ModuleFunction 'Test-LocalAILockHeld' @{ Name = $lock } | Should -BeTrue
            Test-MutexFree -Name $lock | Should -BeFalse
        } finally {
            Exit-MutexOnOtherThread -Holder $holder
        }
        Invoke-ModuleFunction 'Test-LocalAILockHeld' @{ Name = $lock } | Should -BeFalse
    }

    It 'lets only status run inside an app package''s container' {
        $verbs = InModuleScope -ModuleName LocalAI -ScriptBlock { Get-LocalAIVerb }
        $verbs.status.Redirected | Should -Be 'Warn'
        foreach ($verb in 'install', 'start', 'stop', 'update', 'uninstall', 'shortcuts') { $verbs[$verb].Redirected | Should -Be 'Refuse' }
    }

    It 'refuses <Verb> inside an app package''s container before it locks, starts a transcript, loads the settings or writes below Root' -ForEach @(
        @{ Verb = 'install'; Route = '' }
        @{ Verb = 'start'; Route = ", or use the Start menu shortcut 'Start Local AI'" }
        @{ Verb = 'stop'; Route = ", or use the Start menu shortcut 'Stop Local AI'" }
        @{ Verb = 'update'; Route = '' }
        @{ Verb = 'uninstall'; Route = '' }
        @{ Verb = 'shortcuts'; Route = '' }
    ) {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        Mock Get-AppDataRedirection -ModuleName LocalAI -MockWith { @{ Package = 'Fake_123'; Store = 'C:\Users\Test\AppData\Local\Packages\Fake_123\LocalCache\Local' } }
        Mock Enter-LocalAILock -ModuleName LocalAI
        Mock Start-Transcript -ModuleName LocalAI
        Mock Get-LocalAISettings -ModuleName LocalAI
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext = $null }
        $run = Invoke-Dispatcher @{ Verb = $Verb; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -Be ("Error: This window runs inside the app package Fake_123, and Windows puts the folders it creates in %LOCALAPPDATA% and %APPDATA% " +
            "into that package's private stores C:\Users\Test\AppData\Local\Packages\Fake_123\LocalCache\Local and " +
            "C:\Users\Test\AppData\Local\Packages\Fake_123\LocalCache\Roaming instead, so the launcher's files would land where other windows never see them. " +
            "Nothing was changed. Run 'local-ai $Verb' from a console window or Windows Terminal$Route.")
        Test-Path -LiteralPath $root | Should -BeFalse
        Should -Invoke Get-AppDataRedirection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $LocalAppData -eq (Join-Path $TestDrive 'dispatcher-LocalAppData') }
        Should -Invoke Enter-LocalAILock -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-Transcript -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Get-LocalAISettings -ModuleName LocalAI -Times 0 -Exactly
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext } | Should -BeNullOrEmpty
    }

    It 'refuses inside an app package''s container with one JSON document, and nothing else, with -Json' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        Mock Get-AppDataRedirection -ModuleName LocalAI -MockWith { @{ Package = 'Fake_123'; Store = 'C:\Store' } }
        $run = Invoke-Dispatcher @{ Verb = 'stop'; Json = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(1)
        $lines = @($run.Printed -split "`n")
        $lines.Count | Should -Be 1
        $document = ConvertFrom-LocalAIJson -Text $lines[0]
        $document.verb | Should -Be 'stop'
        $document.exitCode | Should -Be 1
        $document.error | Should -BeLike ("This window runs inside the app package Fake_123,*private stores C:\Store and C:\Roaming instead*Run 'local-ai stop -Json' " +
            "from a console window or Windows Terminal.")
        $document.log | Should -BeNullOrEmpty
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'still runs status inside an app package''s container, passing the redirection and both AppData folders to it' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        Mock Get-AppDataRedirection -ModuleName LocalAI -MockWith { @{ Package = 'Fake_123'; Store = 'C:\Store' } }
        $local = Join-Path $TestDrive 'status-local'
        $roaming = Join-Path $TestDrive 'status-roaming'
        $run = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock; LocalAppData = $local; AppData = $roaming }
        $run.Code | Should -Be @(0)
        $context = InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }
        $context.Redirection.Package | Should -Be 'Fake_123'
        $context.Redirection.Store | Should -Be 'C:\Store'
        $context.LocalAppData | Should -Be $local
        $context.AppData | Should -Be $roaming
        Should -Invoke Get-AppDataRedirection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $LocalAppData -eq $local }
    }

    It 'names the command with the switches given, and a Start menu shortcut only for one that runs it, when it refuses <Line>' -ForEach @(
        @{ Line = 'shortcuts -Remove'; Arguments = @{ Verb = 'shortcuts'; Remove = $true }; Route = '' }
        @{ Line = 'update -Tools'; Arguments = @{ Verb = 'update'; Tools = $true }; Route = '' }
        @{ Line = 'uninstall -RemoveData'; Arguments = @{ Verb = 'uninstall'; RemoveData = $true }; Route = '' }
        @{ Line = 'start -NoBrowser'; Arguments = @{ Verb = 'start'; NoBrowser = $true }; Route = '' }
        @{ Line = 'start'; Arguments = @{ Verb = 'start' }; Route = ", or use the Start menu shortcut 'Start Local AI'" }
    ) {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Json', 'Tools', 'Remove', 'RemoveData', 'NoBrowser') }
        Mock Get-AppDataRedirection -ModuleName LocalAI -MockWith { @{ Package = 'Fake_123'; Store = 'C:\Store' } }
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext = $null }
        $run = Invoke-Dispatcher ($Arguments + @{ Root = $root; LockName = $lock })
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Nothing was changed. Run 'local-ai $Line' from a console window or Windows Terminal$Route."
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext } | Should -BeNullOrEmpty
    }

    It 'also probes the known LocalAppData folder when %LOCALAPPDATA% names another, and refuses when only that one is redirected' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $shell = Join-Path $TestDrive 'shell-LocalAppData'
        Mock Get-AppDataRedirection -ModuleName LocalAI -MockWith { if ($LocalAppData -eq $shell) { @{ Package = 'Fake_123'; Store = 'C:\Store' } } }
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext = $null }
        $run = Invoke-Dispatcher @{ Verb = 'stop'; Root = $root; LockName = $lock; ShellLocalAppData = $shell }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike 'Error: This window runs inside the app package Fake_123,*'
        Should -Invoke Get-AppDataRedirection -ModuleName LocalAI -Times 2 -Exactly
        Should -Invoke Get-AppDataRedirection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $LocalAppData -eq $shell }
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'probes once when the known LocalAppData folder is %LOCALAPPDATA%, whatever its case or a trailing backslash' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        Mock Get-AppDataRedirection -ModuleName LocalAI
        $local = Join-Path $TestDrive 'same-LocalAppData'
        $run = Invoke-Dispatcher @{ Verb = 'stop'; Root = $root; LockName = $lock; LocalAppData = $local; ShellLocalAppData = ($local.ToUpperInvariant() + '\') }
        $run.Code | Should -Be @(0)
        Should -Invoke Get-AppDataRedirection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $LocalAppData -eq $local }
    }

    It 'passes no redirection to the verb outside a package''s container, after making and deleting its probe' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        # A store of another package, which does not get the probe: what this PC looks like from a console window.
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $local 'Packages\Other_456\LocalCache\Local')
        $seen = @{}
        Mock Find-PackageStoreCopy -ModuleName LocalAI -ParameterFilter { $RelativePath -like 'local-ai-probe-*' } -MockWith {
            $seen[$RelativePath] = [IO.Directory]::Exists([IO.Path]::Combine($LocalAppData, $RelativePath))
        }
        $run = Invoke-Dispatcher @{ Verb = 'stop'; Root = $root; LockName = $lock; LocalAppData = $local }
        $run.Code | Should -Be @(0)
        (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).Redirection | Should -BeNullOrEmpty
        @($seen.Values) | Should -Be @($true)
        @(Get-ChildItem -LiteralPath $local -Force | ForEach-Object { $_.Name }) | Should -Be @('Packages')
        @(Get-ChildItem -LiteralPath (Join-Path $local 'Packages') -Recurse -Force | Where-Object { $_.Name -like 'local-ai-probe-*' }).Count | Should -Be 0
    }

    It 'still runs status, and every other verb as before, when LocalAppData holds a character no path can' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $bad = (Join-Path $TestDrive 'bad-LocalAppData') + '"'
        foreach ($verb in 'status', 'stop') {
            $run = Invoke-Dispatcher @{ Verb = $verb; Root = $root; LockName = $lock; LocalAppData = $bad }
            $run.Code | Should -Be @(0)
            (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).Redirection | Should -BeNullOrEmpty
        }
    }

    It 'refuses <Verb> while a package store holds a private copy of Root, naming it, and leaves no probe behind' -ForEach @(
        @{ Verb = 'install' }
        @{ Verb = 'start' }
        @{ Verb = 'stop' }
        @{ Verb = 'update' }
        @{ Verb = 'uninstall' }
        @{ Verb = 'shortcuts' }
    ) {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        Mock Enter-LocalAILock -ModuleName LocalAI
        Mock Start-Transcript -ModuleName LocalAI
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext = $null }
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $local 'local-ai'
        $copy = Join-Path $local 'Packages\Fake_123\LocalCache\Local\local-ai'
        $null = New-Item -ItemType Directory -Force -Path $copy
        $run = Invoke-Dispatcher @{ Verb = $Verb; Root = $root; LockName = $lock; LocalAppData = $local; AppData = (Join-Path $TestDrive 'copy-roaming') }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -Be ("Error: $copy is a private copy of $root that Windows made for a window inside an app package, and a window inside that " +
            'package sees the copy instead of the real folder. Nothing was changed. Move it aside, out of %LOCALAPPDATA%\Packages (a copy may hold logs or ' +
            "state the real folder lacks), then run 'local-ai $Verb' again.")
        Test-Path -LiteralPath $root | Should -BeFalse
        @(Get-ChildItem -LiteralPath $copy -Force).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $local -Force | ForEach-Object { $_.Name }) | Should -Be @('Packages')
        Should -Invoke Enter-LocalAILock -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-Transcript -ModuleName LocalAI -Times 0 -Exactly
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext } | Should -BeNullOrEmpty
    }

    It 'names every private copy of Root when several package stores hold one' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Json', 'Tools') }
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $local 'local-ai'
        $first = Join-Path $local 'Packages\Fake_123\LocalCache\Local\local-ai'
        $second = Join-Path $local 'Packages\Other_456\LocalCache\Local\local-ai'
        $null = New-Item -ItemType Directory -Force -Path $first, $second
        $run = Invoke-Dispatcher @{ Verb = 'update'; Tools = $true; Root = $root; LockName = $lock; LocalAppData = $local; AppData = (Join-Path $TestDrive 'copy-roaming') }
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike ("Error: $first and $second are private copies of $root that Windows made*Move them aside, out of %LOCALAPPDATA%\Packages*" +
            "then run 'local-ai update -Tools' again.")
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'still runs status while a package store holds a private copy of Root' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $local 'local-ai'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $local 'Packages\Fake_123\LocalCache\Local\local-ai')
        $run = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock; LocalAppData = $local; AppData = (Join-Path $TestDrive 'copy-roaming') }
        $run.Code | Should -Be @(0)
        (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).LocalAppData | Should -Be $local
    }
}

Describe 'Get-AppDataRedirection and Find-LocalAIPrivateCopy' {
    BeforeEach {
        # A %LOCALAPPDATA% holding the store of one app package, with nothing of the launcher's in it.
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $local 'Packages\Other_456\LocalCache\Local\Microsoft')
        $probe = 'local-ai-probe-' + [guid]::NewGuid().ToString('N')
    }

    It 'returns nothing, and leaves no probe behind, when no package store gets the folder it makes' {
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $local; ProbeName = $probe } | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $local -Force | ForEach-Object { $_.Name }) | Should -Be @('Packages')
        @(Get-ChildItem -LiteralPath (Join-Path $local 'Packages') -Recurse -Force | Where-Object { $_.Name -like 'local-ai-probe-*' }).Count | Should -Be 0
    }

    It 'makes its probe, named local-ai-probe- and a GUID, directly in LocalAppData while it looks in the stores' {
        $seen = @{}
        Mock Find-PackageStoreCopy -ModuleName LocalAI -MockWith { $seen[$RelativePath] = [IO.Directory]::Exists([IO.Path]::Combine($LocalAppData, $RelativePath)) }
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $local } | Should -BeNullOrEmpty
        $names = @($seen.Keys)
        $names.Count | Should -Be 1
        $names[0] | Should -Match '^local-ai-probe-[0-9a-f]{32}$'
        $seen[$names[0]] | Should -BeTrue
        Should -Invoke Find-PackageStoreCopy -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $LocalAppData -eq $local -and $Store -eq 'Local' }
        Test-Path -LiteralPath (Join-Path $local $names[0]) | Should -BeFalse
    }

    It 'returns the package and its store when the probe lands in that store, and deletes it from both places' {
        $store = Join-Path $local 'Packages\Fake_123\LocalCache\Local'
        # What Windows does inside the container: the folder made in LocalAppData lives in the store, where the lookup finds it.
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $store $probe)
        $found = Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $local; ProbeName = $probe }
        $found.Package | Should -Be 'Fake_123'
        $found.Store | Should -Be $store
        Test-Path -LiteralPath (Join-Path $local $probe) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $store $probe) | Should -BeFalse
        Test-Path -LiteralPath $store | Should -BeTrue
    }

    It 'returns nothing, and makes nothing, when LocalAppData has no Packages folder or is not given' {
        $bare = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $bare
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $bare; ProbeName = $probe } | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $bare -Force).Count | Should -Be 0
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = '' } | Should -BeNullOrEmpty
    }

    It 'returns nothing, and leaves what is there, when the probe cannot be made' {
        $blocker = Join-Path $local $probe
        [IO.File]::WriteAllText($blocker, 'not a folder')
        Mock Find-PackageStoreCopy -ModuleName LocalAI
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $local; ProbeName = $probe } | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($blocker) | Should -Be 'not a folder'
        Should -Invoke Find-PackageStoreCopy -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'still deletes its probe, and returns nothing, when the lookup throws' {
        Mock Find-PackageStoreCopy -ModuleName LocalAI -MockWith { throw 'lookup boom' }
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $local; ProbeName = $probe } | Should -BeNullOrEmpty
        Should -Invoke Find-PackageStoreCopy -ModuleName LocalAI -Times 1 -Exactly
        Test-Path -LiteralPath (Join-Path $local $probe) | Should -BeFalse
    }

    It 'never deletes a probe folder that something else filled meanwhile' {
        Mock Find-PackageStoreCopy -ModuleName LocalAI -MockWith { [IO.File]::WriteAllText([IO.Path]::Combine($LocalAppData, $RelativePath, 'keep.txt'), 'keep') }
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $local; ProbeName = $probe } | Should -BeNullOrEmpty
        [IO.File]::ReadAllText((Join-Path $local "$probe\keep.txt")) | Should -Be 'keep'
    }

    It 'returns nothing, and does not throw, when LocalAppData or the folder looked for holds a character no path can' {
        { Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = ((Join-Path $TestDrive 'x') + '"') } } | Should -Not -Throw
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = ((Join-Path $TestDrive 'x') + '"') } | Should -BeNullOrEmpty
        Invoke-ModuleFunction 'Find-PackageStoreCopy' @{ LocalAppData = $local; Store = 'Local'; RelativePath = 'local|ai' } | Should -BeNullOrEmpty
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = (Join-Path $local 'local"ai'); LocalAppData = $local } | Should -BeNullOrEmpty
    }

    It 'deletes the empty probes that a killed run left over a minute ago, and nothing else' {
        $old = (Get-Date).ToUniversalTime().AddMinutes(-2)
        foreach ($name in 'local-ai-probe-old', 'local-ai-probe-full', 'local-ai-probe-new', 'local-ai') { $null = New-Item -ItemType Directory -Path (Join-Path $local $name) }
        [IO.File]::WriteAllText((Join-Path $local 'local-ai-probe-full\keep.txt'), 'keep')
        foreach ($name in 'local-ai-probe-old', 'local-ai-probe-full', 'local-ai') { [IO.Directory]::SetCreationTimeUtc((Join-Path $local $name), $old) }
        Invoke-ModuleFunction 'Get-AppDataRedirection' @{ LocalAppData = $local; ProbeName = $probe } | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $local -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('local-ai', 'local-ai-probe-full', 'local-ai-probe-new', 'Packages')
        [IO.File]::ReadAllText((Join-Path $local 'local-ai-probe-full\keep.txt')) | Should -Be 'keep'
    }

    It 'finds the private copy of a folder below LocalAppData in any package store, and changes nothing' {
        $copy = Join-Path $local 'Packages\Fake_123\LocalCache\Local\local-ai'
        $null = New-Item -ItemType Directory -Force -Path $copy
        # Names only: a listing reads folder times from the parent's index, which NTFS updates lazily, so those of folders just made can still change.
        $before = @(Get-ChildItem -LiteralPath $local -Recurse -Force | ForEach-Object { $_.FullName })
        $roaming = Join-Path $TestDrive 'Roaming'
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = (Join-Path $local 'local-ai'); LocalAppData = $local; AppData = $roaming } | Should -Be @($copy)
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = ((Join-Path $local 'local-ai') + '\'); LocalAppData = $local } | Should -Be @($copy)
        @(Get-ChildItem -LiteralPath $local -Recurse -Force | ForEach-Object { $_.FullName }) | Should -Be $before
    }

    It 'finds the private copy of a folder below AppData in the Roaming part of the stores' {
        $roaming = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $copy = Join-Path $local 'Packages\Fake_123\LocalCache\Roaming\open-webui'
        $null = New-Item -ItemType Directory -Force -Path $copy, (Join-Path $local 'Packages\Fake_123\LocalCache\Local\open-webui')
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = (Join-Path $roaming 'open-webui'); LocalAppData = $local; AppData = $roaming } | Should -Be @($copy)
    }

    It 'looks for a copy of the folder itself, not of its parent, which every store may hold' {
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = (Join-Path $local 'Microsoft\local-ai'); LocalAppData = $local } | Should -BeNullOrEmpty
        $copy = Join-Path $local 'Packages\Other_456\LocalCache\Local\Microsoft\local-ai'
        $null = New-Item -ItemType Directory -Force -Path $copy
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = (Join-Path $local 'Microsoft\local-ai'); LocalAppData = $local } | Should -Be @($copy)
    }

    It 'returns nothing for a folder outside LocalAppData and AppData, without a Packages folder, or without a path' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $local 'Packages\Fake_123\LocalCache\Local\local-ai')
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = 'D:\local-ai'; LocalAppData = $local; AppData = (Join-Path $TestDrive 'Roaming') } | Should -BeNullOrEmpty
        $bare = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = (Join-Path $bare 'local-ai'); LocalAppData = $bare } | Should -BeNullOrEmpty
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = ''; LocalAppData = $local } | Should -BeNullOrEmpty
        Invoke-ModuleFunction 'Find-LocalAIPrivateCopy' @{ Path = (Join-Path $local 'local-ai'); LocalAppData = '' } | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-OllamaUrl' {
    It 'turns OLLAMA_HOST "<Value>" into <Expected>' -ForEach @(
        @{ Value = ''; Expected = 'http://127.0.0.1:11434' }
        @{ Value = '0.0.0.0'; Expected = 'http://127.0.0.1:11434' }
        @{ Value = '0.0.0.0:11434'; Expected = 'http://127.0.0.1:11434' }
        @{ Value = '::'; Expected = 'http://127.0.0.1:11434' }
        @{ Value = '[::]:11434'; Expected = 'http://127.0.0.1:11434' }
        @{ Value = ':11500'; Expected = 'http://127.0.0.1:11500' }
        @{ Value = '127.0.0.1'; Expected = 'http://127.0.0.1:11434' }
        @{ Value = '::1'; Expected = 'http://[::1]:11434' }
        @{ Value = '[::1]:8000'; Expected = 'http://[::1]:8000' }
        @{ Value = 'gpu-box.example'; Expected = 'http://gpu-box.example:11434' }
        @{ Value = 'gpu-box.example:8000'; Expected = 'http://gpu-box.example:8000' }
        @{ Value = 'gpu-box.example:port'; Expected = 'http://gpu-box.example:11434' }
        @{ Value = 'http://gpu-box.example'; Expected = 'http://gpu-box.example:80' }
        @{ Value = 'https://gpu-box.example'; Expected = 'https://gpu-box.example:443' }
        @{ Value = 'https://gpu-box.example:8443/ollama/'; Expected = 'https://gpu-box.example:8443/ollama' }
        @{ Value = 'http://0.0.0.0:11434'; Expected = 'http://127.0.0.1:11434' }
        @{ Value = 'ollama.com'; Expected = 'https://ollama.com:443' }
        @{ Value = ' "0.0.0.0:11434" '; Expected = 'http://127.0.0.1:11434' }
    ) {
        Resolve-OllamaUrl -ProcessHost $Value -UserHost '' | Should -BeExactly $Expected
    }

    It 'prefers Ollama.Url and drops its trailing slash' {
        Resolve-OllamaUrl -Setting 'http://127.0.0.1:11500/' -ProcessHost '0.0.0.0:9000' -UserHost '0.0.0.0:9001' |
            Should -BeExactly 'http://127.0.0.1:11500'
    }

    It 'prefers the process OLLAMA_HOST over the User one' {
        Resolve-OllamaUrl -ProcessHost '127.0.0.1:9000' -UserHost '127.0.0.1:9001' | Should -BeExactly 'http://127.0.0.1:9000'
    }

    It 'falls back to the User OLLAMA_HOST' {
        Resolve-OllamaUrl -ProcessHost '' -UserHost '127.0.0.1:9001' | Should -BeExactly 'http://127.0.0.1:9001'
    }

    It 'reads OLLAMA_HOST from this process when -ProcessHost is omitted, leaving it unchanged' {
        $saved = $env:OLLAMA_HOST
        try {
            $env:OLLAMA_HOST = '0.0.0.0:11600'
            Resolve-OllamaUrl -UserHost '' | Should -BeExactly 'http://127.0.0.1:11600'
            $env:OLLAMA_HOST | Should -BeExactly '0.0.0.0:11600'
        } finally {
            $env:OLLAMA_HOST = $saved
        }
    }
}

Describe 'Get-ListenerAddress and Test-LoopbackListener' {
    It 'returns each listening address once, sorted' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ LocalAddress = '::1'; LocalPort = 11434 }
            [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 11434 }
            [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 11434 }
        }
        @(Get-ListenerAddress -Port 11434) | Should -Be @('127.0.0.1', '::1' | Sort-Object)
        Should -Invoke Get-NetTCPConnection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $State -eq 'Listen' -and $LocalPort -eq 11434 }
    }

    It 'returns nothing and writes no error record when no program listens on the port' {
        # As the cmdlet does, the mock reports the miss as an error that -ErrorAction governs.
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith {
            $reason = New-Object System.Exception 'No matching MSFT_NetTCPConnection objects found by CIM query.'
            $record = New-Object System.Management.Automation.ErrorRecord $reason, 'CmdletizationQuery_NotFound,Get-NetTCPConnection', 'ObjectNotFound', $null
            Write-Error -ErrorRecord $record -ErrorAction $PesterBoundParameters['ErrorAction']
        }
        $seen = @(Get-ListenerAddress -Port 11434 -ErrorVariable failures 2>&1)
        $seen.Count | Should -Be 0
        @($failures).Count | Should -Be 0
        # Stop would make Start-Transcript log the caught miss.
        Should -Invoke Get-NetTCPConnection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['ErrorAction'] -eq 'SilentlyContinue' }
    }

    It 'throws any other Get-NetTCPConnection error' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith { throw 'The CIM server is unavailable.' }
        { Get-ListenerAddress -Port 11434 } | Should -Throw -ExpectedMessage '*CIM server is unavailable*'
    }

    It 'throws, as it was reported, another error the cmdlet reports without stopping' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith {
            $reason = New-Object System.Exception 'Access denied.'
            $record = New-Object System.Management.Automation.ErrorRecord $reason, 'HRESULT 0x80041003,Get-NetTCPConnection', 'PermissionDenied', $null
            Write-Error -ErrorRecord $record -ErrorAction $PesterBoundParameters['ErrorAction']
        }
        $caught = $null
        try { $null = Get-ListenerAddress -Port 11434 } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -BeExactly 'Access denied.'
        $caught.FullyQualifiedErrorId | Should -BeLike 'HRESULT 0x80041003,Get-NetTCPConnection*'
        "$($caught.CategoryInfo.Category)" | Should -Be 'PermissionDenied'
    }

    It 'returns nothing for a real loopback port nothing listens on' {
        $probe = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $probe.Start()
        $free = $probe.LocalEndpoint.Port
        $probe.Stop()
        @(Get-ListenerAddress -Port $free 2>&1).Count | Should -Be 0
    }

    It 'returns $true without a warning when only loopback listens' {
        Mock Get-ListenerAddress -ModuleName LocalAI -MockWith { '127.0.0.1'; '::1' }
        Test-LoopbackListener -Port 11434 -Name 'Ollama' -Fix 'Turn it off.' -WarningVariable warnings 3>$null 6>$null | Should -BeTrue
        $warnings.Count | Should -Be 0
    }

    It 'warns naming the address and the fix, and returns $false, for <Address>' -ForEach @(
        @{ Address = '0.0.0.0' }
        @{ Address = '::' }
        @{ Address = '192.0.2.20' }
    ) {
        Mock Get-ListenerAddress -ModuleName LocalAI -MockWith { '127.0.0.1'; $Address }
        Test-LoopbackListener -Port 11434 -Name 'Ollama' -Fix 'Turn it off.' -WarningVariable warnings 3>$null | Should -BeFalse
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*Ollama*port 11434 listens on $Address,*Turn it off.*"
    }

    It 'warns and returns $false when nothing listens' {
        Mock Get-ListenerAddress -ModuleName LocalAI
        Test-LoopbackListener -Port 11434 -Name 'Ollama' -WarningVariable warnings 3>$null | Should -BeFalse
        "$($warnings[0])" | Should -BeLike '*Nothing listens on port 11434*'
    }
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
            # Apps lists what Win32_Process holds; Start adds what Start-OllamaApp leaves running and Returns the PID it gives back.
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
            @{ Version = '0.12.4'; Path = 'C:\Users\User\.local\bin\open-webui.exe'; Python = '3.12.10'; ToolDir = 'C:\Users\User\AppData\Roaming\uv\tools' }
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

    It 'sets up ComfyUI and then the checkpoint after Open WebUI' {
        $order = New-Object System.Collections.Generic.List[string]
        Mock Install-OpenWebUI -ModuleName LocalAI -MockWith { $order.Add('OpenWebUI'); @{ Version = '0.12.4'; Path = 'C:\x\open-webui.exe'; Python = '3.12.10' } }
        Mock Install-ComfyUI -ModuleName LocalAI -MockWith { $order.Add('ComfyUI'); @{ Commit = $comfyCommit; Pinned = $true; Python = $comfyPython } }
        Mock Install-ImageModel -ModuleName LocalAI -MockWith { $order.Add('ImageModel'); @{ Path = 'C:\x'; Sha256 = $checkpointSha } }
        $null = Install-LocalAI -Context $context 6>$null
        $order | Should -Be @('OpenWebUI', 'ComfyUI', 'ImageModel')
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
        $settings = @{ OpenWebUI = @{ Version = '0.12.4'; Python = '3.12'; DataDir = $dataDir; InstallBytes = 2987894996 } }
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

    It 'installs the pin on OpenWebUI.Python, on the console, when uv lists no open-webui' {
        $uv.Lines = @('No tools installed')
        $tool = Install-OpenWebUI -Settings $settings -Paths $paths 6>$null
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'uv' -and ($ArgumentList -join ' ') -eq 'tool install --python 3.12 open-webui==0.12.4' -and [bool]$Console
        }
        $tool.Version | Should -Be '0.12.4'
        $tool.Path | Should -Be 'C:\Users\User\.local\bin\open-webui.exe'
        $tool.Python | Should -Be '3.12.10'
        $tool.ToolDir | Should -Be 'C:\Users\User\AppData\Roaming\uv\tools'
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
    }

    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $base -Leaf
        $paths = Get-LocalAIPaths -Root (Join-Path $base 'local-ai')
        $settings = @{
            Files  = @{ ServerVersion = '2.0.1'; ServerPackage = 'config\files-server'; ServerInstallBytes = 21617057 }
            Winget = @{ Packages = @{ Node = @{ Id = 'OpenJS.NodeJS.LTS'; Command = 'node'; Scope = 'machine' } } }
        }
        $node = Write-TestFile "$leaf\nodejs\node.exe" 'program'
        $npm = Write-TestFile "$leaf\nodejs\node_modules\npm\bin\npm-cli.js" 'npm'
        $target = $paths.FilesServer
        $module = Join-Path $target 'node_modules\@modelcontextprotocol\server-filesystem'
        $runs = @{ NodeVersion = 'v24.22.1'; Installs = '2.0.1'; Copied = @() }
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
        $marker.ServerVersion | Should -Be '2.0.1'
        $marker.PackageSha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'runs no npm ci when the marker records both files and the pinned server is in place' {
        $null = Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null
        $printed = @(Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>&1 |
                Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join "`n"
        Should -Invoke Invoke-Native -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'ci' }
        Should -Invoke Test-FreeSpace -ModuleName LocalAI -Times 1 -Exactly
        $printed | Should -BeLike '*The files server 2.0.1 in*matches the lockfile; nothing to install.*'
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
        @{ Case = 'Files.ServerVersion differs from the package.json pin'; Change = 'setting'; Message = "*package.json pins @modelcontextprotocol/server-filesystem '2.0.1', but Files.ServerVersion is '2.0.0'. Make them agree*" }
        @{ Case = 'node is older than the server needs'; Change = 'old node'; Message = '*Node.js 22.11.0 at *node.exe is older than the >=24 that @modelcontextprotocol/server-filesystem 2.0.1 needs*winget upgrade --id OpenJS.NodeJS.LTS -e*' }
        @{ Case = 'node prints no version'; Change = 'no version'; Message = "*--version' printed no version*" }
        @{ Case = 'there is no npm beside node'; Change = 'no npm'; Message = '*There is no npm beside*npm-cli.js is missing*' }
        @{ Case = 'the lockfile locks another version'; Change = 'lock'; Message = '*package-lock.json does not lock @modelcontextprotocol/server-filesystem 2.0.1. Regenerate it*' }
    ) {
        switch ($Change) {
            'setting' { $settings.Files.ServerVersion = '2.0.0' }
            'old node' { $runs.NodeVersion = 'v22.11.0' }
            'no version' { $runs.NodeVersion = 'Welcome to Node.js' }
            'no npm' { Remove-Item -LiteralPath $npm }
            'lock' {
                $settings.Files.ServerPackage = Join-Path $base 'package'
                $null = Write-TestFile "$leaf\package\package.json" '{"private": true, "dependencies": {"@modelcontextprotocol/server-filesystem": "2.0.1"}}'
                $null = Write-TestFile "$leaf\package\package-lock.json" '{"lockfileVersion": 3, "packages": {"node_modules/@modelcontextprotocol/server-filesystem": {"version": "2.0.0"}}}'
            }
        }
        { Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $repoRoot -NodePath $node 6>$null } | Should -Throw -ExpectedMessage $Message
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
            Should -Throw -ExpectedMessage "*After npm ci, *server-filesystem holds @modelcontextprotocol/server-filesystem '2.0.0' instead of 2.0.1*"
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
        $entry.ServerVersion | Should -Be '2.0.1'
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
        # Only the first run, which installed, looked.
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
            HfCli   = @{ Version = '2.2.0' }
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
            ($ArgumentList -join ' ') -eq ("--from huggingface_hub==2.2.0 hf download Lykon/dreamshaper-xl-lightning Test.safetensors " +
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
    }

    AfterEach {
        # Removes the links only, never what they lead to.
        foreach ($link in $links) { if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link, $false) } }
        if ($denied) {
            $security = $denied.Folder.GetAccessControl()
            $null = $security.RemoveAccessRule($denied.Rule)
            $denied.Folder.SetAccessControl($security)
        }
        # Windows PowerShell 5.1 removes TestDrive with paths of at most 260 characters.
        if ($longTop) { [IO.Directory]::Delete('\\?\' + $longTop, $true) }
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
        $denied = @{ Folder = $folder; Rule = $rule }
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

Describe 'New-McpoConfig' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = Join-Path $folder 'mcpo.json'
        $settings = @{ Files = @{ Root = 'D:\AI-Folder\'; DisabledTools = @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file') } }
        $node = 'C:\Program Files\nodejs\node.exe'
        $script = 'C:\Users\User\AppData\Local\local-ai\files-server\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js'
    }

    It 'writes one stdio server files that runs node on the server script with Files.Root, hiding Files.DisabledTools' {
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
        @($config.PSObject.Properties.Name) | Should -Be @('mcpServers')
        @($config.mcpServers.PSObject.Properties.Name) | Should -Be @('files')
        $files = $config.mcpServers.files
        @($files.PSObject.Properties.Name | Sort-Object) | Should -Be @('args', 'command', 'disabledTools')
        $files.command | Should -BeExactly $node
        @($files.args) | Should -Be @($script, 'D:\AI-Folder')
        @($files.disabledTools) | Should -Be @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file')
    }

    It 'keeps a single disabled tool a JSON list' {
        $settings.Files.DisabledTools = @('write_file')
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        [IO.File]::ReadAllText($path) | Should -Match '"disabledTools":\s*\[\s*"write_file"\s*\]'
    }

    It 'writes ASCII without BOM, with a non-ASCII root as \u escapes, since mcpo reads the file with the ANSI code page' {
        $root = 'D:\Data-' + [char]0xFC + [char]0x4E2D
        $settings.Files.Root = $root
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be ([byte][char]'{')
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        [Text.Encoding]::ASCII.GetString($bytes) | Should -BeLike '*"D:\\Data-\u00fc\u4e2d"*'
        @((ConvertFrom-Json -InputObject ([Text.Encoding]::ASCII.GetString($bytes))).mcpServers.files.args)[1] | Should -BeExactly $root
    }

    It 'hands the server a root typed in another case spelled as on disk, as Test-FilesRoot checked it' {
        $onDisk = Join-Path $folder 'AI-Files'
        $null = New-Item -ItemType Directory -Force -Path $onDisk
        $settings.Files.Root = $onDisk.ToUpperInvariant()
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $expected = & (Get-Module LocalAI) { param($Given) (Resolve-OnDiskPath -Path $Given).Path } $onDisk
        $expected | Should -BeLike '*\AI-Files'
        @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).mcpServers.files.args)[1] | Should -BeExactly $expected
    }

    It 'hands the server a root typed with an 8.3 short name by its long name' {
        $long = Join-Path $env:ProgramFiles 'Common Files'
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:ProgramFiles).ShortPath
        if ($short -eq $env:ProgramFiles -or -not (Test-Path -LiteralPath $long -PathType Container)) {
            Set-ItResult -Skipped -Because "$env:ProgramFiles has no 8.3 short name on this PC"
            return
        }
        $settings.Files.Root = Join-Path $short 'Common Files'
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).mcpServers.files.args)[1] | Should -BeExactly $long
    }

    It 'replaces a config an earlier start wrote, leaving no .tmp' {
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $settings.Files.Root = 'E:\Other'
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).mcpServers.files.args)[1] | Should -BeExactly 'E:\Other'
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
    }
}

Describe 'Get-FilesServerVersion' {
    BeforeAll {
        # Return mcpo's answer $Json as Invoke-WebRequest gives it: the UTF-8 bytes mcpo sends, which name no charset.
        function ConvertTo-TestAnswer([string]$Json) {
            [pscustomobject]@{ StatusCode = 200; RawContentStream = New-Object IO.MemoryStream -ArgumentList (, [Text.Encoding]::UTF8.GetBytes($Json)) }
        }
    }

    BeforeEach {
        $url = 'http://127.0.0.1:18189'
        $key = 'ab' * 32
        $tools = @('read_text_file', 'list_directory', 'search_files', 'get_file_info', 'list_allowed_directories')
        $root = 'D:\AI-Folder'
        # What mcpo 0.0.20 serves for server-filesystem 2.0.1 with the five tools left.
        $answer = @{
            Title  = 'secure-filesystem-server'
            Version = '2.0.1'
            Routes = @('/get_file_info', '/list_allowed_directories', '/list_directory', '/read_text_file', '/search_files')
            Listed = "Allowed directories:`n$root"
        }
        Mock Invoke-WebRequest -ModuleName LocalAI -ParameterFilter { $Uri -eq "$url/files/openapi.json" } -MockWith {
            $paths = [ordered]@{}
            foreach ($route in $answer.Routes) { $paths[$route] = @{ post = @{ operationId = 'tool' + ($route -replace '/', '_') + '_post' } } }
            ConvertTo-TestAnswer (ConvertTo-Json -InputObject @{ openapi = '3.1.0'; info = @{ title = $answer.Title; version = $answer.Version }; paths = $paths } -Depth 6)
        }
        Mock Invoke-WebRequest -ModuleName LocalAI -ParameterFilter { $Uri -eq "$url/files/list_allowed_directories" } -MockWith {
            ConvertTo-TestAnswer (ConvertTo-Json -InputObject $answer.Listed)
        }
    }

    It 'returns the server version, sending the Bearer key to the spec and to list_allowed_directories within 5 s' {
        Get-FilesServerVersion -Url $url -Key $key -Version '2.0.1' -Tools $tools -Root $root | Should -Be '2.0.1'
        Should -Invoke Invoke-WebRequest -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "$url/files/openapi.json" -and $Headers.Authorization -ceq "Bearer $key" -and $TimeoutSec -eq 5 -and $UseBasicParsing
        }
        Should -Invoke Invoke-WebRequest -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "$url/files/list_allowed_directories" -and $Method -eq 'Post' -and $Headers.Authorization -ceq "Bearer $key" -and $Body -eq '{}' -and
            $ContentType -eq 'application/json' -and $TimeoutSec -eq 5 -and $UseBasicParsing
        }
    }

    It 'accepts the root listed in other case and in both spellings the server stores' {
        $answer.Listed = "Allowed directories:`nd:\ai-folder`nD:\AI-Folder"
        Get-FilesServerVersion -Url $url -Key $key -Version '2.0.1' -Tools $tools -Root $root | Should -Be '2.0.1'
    }

    It 'reads the answers as UTF-8, so a root with an umlaut passes' {
        $root = 'D:\B' + [char]0xFC + '-test-' + [char]0x4E2D
        $answer.Listed = "Allowed directories:`n$root"
        Get-FilesServerVersion -Url $url -Key $key -Version '2.0.1' -Tools $tools -Root $root | Should -Be '2.0.1'
    }

    It 'rejects mcpo that <Case>' -ForEach @(
        @{ Case = 'serves its own root spec'; Change = @{ Title = 'MCP OpenAPI Proxy' }; Message = '*did not answer as secure-filesystem-server, so it is not mcpo serving the files server*' }
        @{ Case = 'serves another server version'; Change = @{ Version = '2.0.0' }; Message = '*serves secure-filesystem-server 2.0.0, not Files.ServerVersion 2.0.1*' }
        @{ Case = 'serves no routes, as when its node server did not start'; Change = @{ Routes = @() }; Message = "*serves the routes '', not '/get_file_info*without any, its node server did not start*" }
        @{ Case = 'also serves a write tool'; Change = @{ Routes = @('/get_file_info', '/list_allowed_directories', '/list_directory', '/read_text_file', '/search_files', '/write_file') }; Message = "*serves the routes '*/write_file', not*" }
        @{ Case = 'lacks a tool'; Change = @{ Routes = @('/list_directory', '/read_text_file') }; Message = "*serves the routes '/list_directory, /read_text_file', not*" }
        @{ Case = 'serves another folder'; Change = @{ Listed = "Allowed directories:`nD:\Old-Folder" }; Message = "*serves the folders 'D:\Old-Folder', not Files.Root D:\AI-Folder alone*" }
        @{ Case = 'serves a second folder beside the root'; Change = @{ Listed = "Allowed directories:`nD:\AI-Folder`nD:\Old-Folder" }
            Message = "*serves the folders 'D:\AI-Folder', 'D:\Old-Folder', not Files.Root D:\AI-Folder alone*" }
        @{ Case = 'serves no folder'; Change = @{ Listed = 'Allowed directories:' }; Message = "*serves the folders '', not Files.Root D:\AI-Folder alone*" }
    ) {
        foreach ($name in $Change.Keys) { $answer[$name] = $Change[$name] }
        { Get-FilesServerVersion -Url $url -Key $key -Version '2.0.1' -Tools $tools -Root $root } | Should -Throw -ExpectedMessage $Message
    }

    It 'puts no key into its errors' {
        Mock Invoke-WebRequest -ModuleName LocalAI -ParameterFilter { $Uri -eq "$url/files/openapi.json" } -MockWith { throw 'The remote server returned an error: (403) Forbidden.' }
        $thrown = { Get-FilesServerVersion -Url $url -Key $key -Version '2.0.1' -Tools $tools -Root $root } | Should -Throw -PassThru
        $thrown.Exception.Message | Should -Not -BeLike "*$key*"
    }
}

Describe 'Get-FilesStartProblem' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $lockSha = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'config\files-server\package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $url = 'http://127.0.0.1:11434'
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Files.Root = 'D:\AI-Folder'
        $stamp = @{ Files = @{
                McpoVersion = '0.0.20'; McpoPath = (Write-TestFile "$leaf\bin\mcpo.exe" 'program'); ServerVersion = '2.0.1'; LockSha256 = $lockSha
                Python = $settings.Files.Python; With = @($settings.Files.McpoWith); ExcludeNewer = $settings.Files.McpoExcludeNewer
                Script = (Write-TestFile "$leaf\files-server\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js" 'script')
                Node = @{ Path = (Write-TestFile "$leaf\nodejs\node.exe" 'program'); Version = '24.22.1' }
            } }
        $null = Get-FilesKey -Path $paths.FilesKey -Create
        $ollama = @{ Capabilities = @('completion', 'tools', 'thinking') }
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -eq "$url/api/show" } -MockWith { [pscustomobject]@{ capabilities = $ollama.Capabilities } }
    }

    It 'finds no problem, and warns about nothing, when install set up what the settings name' {
        Get-FilesStartProblem -Settings $settings -Paths $paths -Stamp $stamp -OllamaUrl $url -RepoRoot $repoRoot -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $Body -eq '{"model":"local-chat"}' }
    }

    It 'names the problem when <Case>' -ForEach @(
        @{ Case = 'the stamp records no file tools'; Change = 'no stamp'; Expected = "install-stamp.json does not record them. Run 'local-ai install' to set them up." }
        @{ Case = 'mcpo.exe is gone'; Change = 'no mcpo'; Expected = "install-stamp.json names no mcpo.exe that exists ('*mcpo.exe'). Run 'local-ai install'*" }
        @{ Case = 'the stamp names no node.exe'; Change = 'no node'; Expected = "install-stamp.json names no node.exe that exists (''). Run 'local-ai install'*" }
        @{ Case = 'the server script is gone'; Change = 'no script'; Expected = '*names no files server script that exists*index.js*' }
        @{ Case = 'Files.ServerVersion changed since install'; Change = 'version'; Expected = "install set up server-filesystem 2.0.1, but Files.ServerVersion is 2.0.2. Run 'local-ai install'*" }
        @{ Case = 'files.key is missing'; Change = 'no key'; Expected = "The mcpo key file '*files.key' does not exist. Run 'local-ai install', which creates it." }
        @{ Case = 'files.key holds something else'; Change = 'bad key'; Expected = '*does not hold 64 lowercase hexadecimal characters*' }
        @{ Case = 'local-chat cannot call tools'; Change = 'no tools'; Expected = "Ollama does not report the 'tools' capability for local-chat, so it cannot call them.*" }
        @{ Case = 'Ollama does not answer'; Change = 'no ollama'; Expected = 'Ollama at http://127.0.0.1:11434 did not report the capabilities of local-chat: Unable to connect*' }
    ) {
        switch ($Change) {
            'no stamp' { $stamp.Remove('Files') }
            'no mcpo' { Remove-Item -LiteralPath $stamp.Files.McpoPath }
            'no node' { $stamp.Files.Remove('Node') }
            'no script' { Remove-Item -LiteralPath $stamp.Files.Script }
            'version' { $settings.Files.ServerVersion = '2.0.2' }
            'no key' { Remove-Item -LiteralPath $paths.FilesKey }
            'bad key' { [IO.File]::WriteAllText($paths.FilesKey, 'not-a-key') }
            'no tools' { $ollama.Capabilities = @('completion', 'thinking') }
            'no ollama' { Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -eq "$url/api/show" } -MockWith { throw 'Unable to connect to the remote server' } }
        }
        Get-FilesStartProblem -Settings $settings -Paths $paths -Stamp $stamp -OllamaUrl $url -RepoRoot $repoRoot | Should -BeLike $Expected
    }

    It 'warns, finding no problem, when the tracked lockfile is not the one install ran npm ci with' {
        $stamp.Files.LockSha256 = 'f' * 64
        Get-FilesStartProblem -Settings $settings -Paths $paths -Stamp $stamp -OllamaUrl $url -RepoRoot $repoRoot -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*package-lock.json is not the lockfile install ran npm ci with*'local-ai install', which runs npm ci again."
    }

    It 'warns once, finding no problem, when install set mcpo up for other <Names>' -ForEach @(
        @{ Names = 'Files.McpoWith'; Change = @{ With = @('mcp==1.30.0') } }
        @{ Names = 'Files.McpoExcludeNewer'; Change = @{ ExcludeNewer = '2026-09-08T00:00:00Z' } }
        @{ Names = 'Files.Python'; Change = @{ Python = '3.11' } }
        @{ Names = 'Files.McpoWith, Files.McpoExcludeNewer, Files.Python'; Change = @{ With = @(); ExcludeNewer = ''; Python = '3.13' } }
    ) {
        foreach ($name in $Change.Keys) { $stamp.Files[$name] = $Change[$name] }
        Get-FilesStartProblem -Settings $settings -Paths $paths -Stamp $stamp -OllamaUrl $url -RepoRoot $repoRoot -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeExactly ("install set up mcpo for another $Names than settings.psd1 names, so mcpo runs with packages those pins do not " +
            "choose. Run 'local-ai install', which reinstalls mcpo at its pins.")
    }

    It 'leaves a McpoVersion drift to the service pin warning' {
        $stamp.Files.McpoVersion = '0.0.19'
        Get-FilesStartProblem -Settings $settings -Paths $paths -Stamp $stamp -OllamaUrl $url -RepoRoot $repoRoot -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 0
    }
}

Describe 'Get-OpenWebUIEnvironment' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $url = 'http://127.0.0.1:11434'
    }

    BeforeEach {
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Ports.OpenWebUI = 18431
        $dataDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $settings.OpenWebUI.DataDir = $dataDir
        $settings.OpenWebUI.Env = @{ WEBUI_AUTH = 'True'; ENABLE_PERSISTENT_CONFIG = 'False'; CONTENT_SECURITY_POLICY = "img-src 'self'" }
    }

    It 'passes every OpenWebUI.Env entry, sorted, then the computed keys' {
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url
        @($environment.Keys) | Should -Be @('CONTENT_SECURITY_POLICY', 'ENABLE_PERSISTENT_CONFIG', 'WEBUI_AUTH', 'DATA_DIR', 'DATABASE_URL',
            'OLLAMA_BASE_URL', 'OLLAMA_BASE_URLS', 'CORS_ALLOW_ORIGIN', 'DEFAULT_MODELS', 'TASK_MODEL', 'ENABLE_SIGNUP', 'ENABLE_OLLAMA_API',
            'OLLAMA_API_CONFIGS', 'NO_PROXY', 'ENABLE_IMAGE_GENERATION', 'IMAGE_GENERATION_ENGINE', 'IMAGE_GENERATION_MODEL', 'IMAGE_SIZE', 'IMAGE_STEPS', 'COMFYUI_BASE_URL',
            'COMFYUI_API_KEY', 'COMFYUI_WORKFLOW', 'COMFYUI_WORKFLOW_NODES', 'ENABLE_IMAGE_EDIT', 'TOOL_SERVER_CONNECTIONS', 'DEFAULT_MODEL_METADATA')
        $environment['CONTENT_SECURITY_POLICY'] | Should -BeExactly "img-src 'self'"
        $environment['WEBUI_AUTH'] | Should -BeExactly 'True'
        $environment['ENABLE_PERSISTENT_CONFIG'] | Should -BeExactly 'False'
    }

    It 'computes DATA_DIR, the Ollama URL, both loopback origins, the tagged model and the Ollama switch' {
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url
        $environment['DATA_DIR'] | Should -BeExactly $dataDir
        $environment['OLLAMA_BASE_URL'] | Should -BeExactly $url
        $environment['CORS_ALLOW_ORIGIN'] | Should -BeExactly 'http://127.0.0.1:18431;http://localhost:18431'
        $environment['DEFAULT_MODELS'] | Should -BeExactly 'local-chat:latest'
        $environment['TASK_MODEL'] | Should -BeExactly 'local-chat:latest'
        $environment['ENABLE_OLLAMA_API'] | Should -BeExactly 'True'
    }

    It 'empties DATABASE_URL and OLLAMA_BASE_URLS, which Open WebUI would prefer to DATA_DIR and OLLAMA_BASE_URL' {
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url
        $environment['DATABASE_URL'] | Should -BeExactly ''
        $environment['OLLAMA_BASE_URLS'] | Should -BeExactly ''
    }

    It 'sets ENABLE_SIGNUP to False with and without webui.db' {
        (Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url)['ENABLE_SIGNUP'] | Should -BeExactly 'False'
        $null = Write-TestFile ((Split-Path $dataDir -Leaf) + '\webui.db') 'database'
        (Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url)['ENABLE_SIGNUP'] | Should -BeExactly 'False'
    }

    It 'lets OpenWebUI.Env replace <Key>' -ForEach @(
        @{ Key = 'DEFAULT_MODELS'; Value = 'other-chat:latest' }
        @{ Key = 'TASK_MODEL'; Value = 'small-task:latest' }
        @{ Key = 'ENABLE_SIGNUP'; Value = 'True' }
        @{ Key = 'WEBUI_AUTH'; Value = 'False' }
        @{ Key = 'DATABASE_URL'; Value = 'postgresql://owui@127.0.0.1:5432/owui' }
        @{ Key = 'OLLAMA_API_CONFIGS'; Value = '' }
    ) {
        $settings.OpenWebUI.Env[$Key] = $Value
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -WarningVariable warnings 3>$null
        $environment[$Key] | Should -BeExactly $Value
        @($environment.Keys | Where-Object { $_ -eq $Key }).Count | Should -Be 1
        $warnings.Count | Should -Be 0
    }

    It 'keeps <Key> computed and warns naming <Owner>' -ForEach @(
        @{ Key = 'DATA_DIR'; Owner = 'OpenWebUI.DataDir' }
        @{ Key = 'OLLAMA_BASE_URL'; Owner = 'Ollama.Url' }
        @{ Key = 'OLLAMA_BASE_URLS'; Owner = 'Ollama.Url' }
        @{ Key = 'CORS_ALLOW_ORIGIN'; Owner = 'Ports.OpenWebUI' }
        @{ Key = 'ENABLE_OLLAMA_API'; Owner = 'the launcher' }
        @{ Key = 'ENABLE_IMAGE_GENERATION'; Owner = 'Images.Enabled' }
        @{ Key = 'IMAGE_GENERATION_ENGINE'; Owner = 'Images.Enabled' }
        @{ Key = 'IMAGE_GENERATION_MODEL'; Owner = 'Images.File' }
        @{ Key = 'IMAGE_SIZE'; Owner = 'Images.Resolution' }
        @{ Key = 'IMAGE_STEPS'; Owner = 'Images.Steps' }
        @{ Key = 'COMFYUI_BASE_URL'; Owner = 'Ports.ImageGate or Ports.ComfyUI' }
        @{ Key = 'COMFYUI_API_KEY'; Owner = 'the launcher' }
        @{ Key = 'COMFYUI_WORKFLOW'; Owner = 'Images.Workflow' }
        @{ Key = 'COMFYUI_WORKFLOW_NODES'; Owner = 'Images.WorkflowNodes' }
        @{ Key = 'ENABLE_IMAGE_EDIT'; Owner = 'the launcher' }
        @{ Key = 'TOOL_SERVER_CONNECTIONS'; Owner = 'Files.* and Ports.Files' }
    ) {
        $settings.OpenWebUI.Env[$Key] = 'user-value'
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -WarningVariable warnings 3>$null
        $environment[$Key] | Should -Not -Be 'user-value'
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*OpenWebUI.Env.$Key is ignored*$Owner*"
    }

    It 'writes booleans and numbers as text and keeps an empty value' {
        $settings.OpenWebUI.Env = @{ FLAG_ON = $true; FLAG_OFF = $false; COUNT = 3; CLEARED = '' }
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url
        $environment['FLAG_ON'] | Should -BeExactly 'True'
        $environment['FLAG_OFF'] | Should -BeExactly 'False'
        $environment['COUNT'] | Should -BeExactly '3'
        $environment.Contains('CLEARED') | Should -BeTrue
        $environment['CLEARED'] | Should -BeExactly ''
    }

    It 'rejects a list or a table as a value' {
        $settings.OpenWebUI.Env = @{ LISTED = @('a', 'b') }
        { Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url } |
            Should -Throw -ExpectedMessage "*'OpenWebUI.Env.LISTED' must be text, a number or*"
    }

    It 'points Open WebUI at ComfyUI with the tracked workflow and the image settings when Images.Enabled is on' {
        $settings.Ports.ComfyUI = 18188
        $settings.Images.Steps = 4
        $settings.Images.Resolution = '832x1216'
        $workflow = Get-ImageWorkflow -Settings $settings -RepoRoot $repoRoot
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow $workflow
        $environment['ENABLE_IMAGE_GENERATION'] | Should -BeExactly 'True'
        $environment['IMAGE_GENERATION_ENGINE'] | Should -BeExactly 'comfyui'
        $environment['COMFYUI_BASE_URL'] | Should -BeExactly 'http://127.0.0.1:18188'
        $environment['IMAGE_GENERATION_MODEL'] | Should -BeExactly 'DreamShaperXL_Lightning.safetensors'
        $environment['IMAGE_SIZE'] | Should -BeExactly '832x1216'
        $environment['IMAGE_STEPS'] | Should -BeExactly '4'
        $environment['COMFYUI_API_KEY'] | Should -BeExactly ''
        $environment['ENABLE_IMAGE_EDIT'] | Should -BeExactly 'False'
        $environment['COMFYUI_WORKFLOW'] | Should -BeExactly $workflow.Workflow
        $environment['COMFYUI_WORKFLOW_NODES'] | Should -BeExactly $workflow.Nodes
        ($environment['COMFYUI_WORKFLOW'] | ConvertFrom-Json).'3'.inputs.steps | Should -Be 4
    }

    It 'sends images to the -ImageUrl it is given, the image gate, instead of ComfyUI' {
        $settings.Ports.ComfyUI = 18188
        $workflow = Get-ImageWorkflow -Settings $settings -RepoRoot $repoRoot
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow $workflow -ImageUrl 'http://127.0.0.1:18190'
        $environment['COMFYUI_BASE_URL'] | Should -BeExactly 'http://127.0.0.1:18190'
        $environment['ENABLE_IMAGE_GENERATION'] | Should -BeExactly 'True'
        (Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow $workflow -ImageUrl '')['COMFYUI_BASE_URL'] |
            Should -BeExactly 'http://127.0.0.1:18188'
    }

    It 'leaves COMFYUI_BASE_URL empty without images, whatever -ImageUrl says' {
        $settings.Images.Enabled = $false
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow @{ Workflow = '{}'; Nodes = '[]' } -ImageUrl 'http://127.0.0.1:18190'
        $environment['COMFYUI_BASE_URL'] | Should -BeExactly ''
    }

    It 'turns image generation and editing off and empties the other image keys when <Case>' -ForEach @(
        @{ Case = 'Images.Enabled is off'; Enabled = $false; Workflow = $true }
        @{ Case = 'no workflow is given, as when this start runs no ComfyUI'; Enabled = $true; Workflow = $false }
    ) {
        $settings.Images.Enabled = $Enabled
        $given = if ($Workflow) { @{ Workflow = '{"3": {}}'; Nodes = '[]' } } else { $null }
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow $given
        $environment['ENABLE_IMAGE_GENERATION'] | Should -BeExactly 'False'
        $environment['ENABLE_IMAGE_EDIT'] | Should -BeExactly 'False'
        foreach ($key in 'IMAGE_GENERATION_ENGINE', 'IMAGE_GENERATION_MODEL', 'IMAGE_SIZE', 'IMAGE_STEPS', 'COMFYUI_BASE_URL', 'COMFYUI_API_KEY',
            'COMFYUI_WORKFLOW', 'COMFYUI_WORKFLOW_NODES') {
            $environment.Contains($key) | Should -BeTrue -Because "an empty $key removes an inherited copy"
            $environment[$key] | Should -BeExactly '' -Because "$key is unused without images"
        }
    }

    It 'reads no workflow file itself' {
        # A missing file does not matter, since the caller passes the loaded workflow.
        $settings.Images.Workflow = Join-Path $TestDrive 'absent.json'
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow @{ Workflow = '{"9": {}}'; Nodes = '[]' }
        $environment['COMFYUI_WORKFLOW'] | Should -BeExactly '{"9": {}}'
    }

    It 'stays far below the Windows limit of 32767 characters per variable, quotes included' {
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow (Get-ImageWorkflow -Settings $settings -RepoRoot $repoRoot)
        $environment['COMFYUI_WORKFLOW'] | Should -BeLike '*"class_type":"PreviewImage"*'
        $environment['COMFYUI_WORKFLOW'].Length | Should -BeLessThan 4096
        $environment['COMFYUI_WORKFLOW_NODES'].Length | Should -BeLessThan 4096
    }

    It 'registers no tool server and preselects no tools when <Case>' -ForEach @(
        @{ Case = 'no mcpo key is given, as when this start runs no mcpo'; Root = 'D:\AI-Folder'; Key = '' }
        @{ Case = 'Files.Root is empty'; Root = ''; Key = ('ab' * 32) }
    ) {
        $settings.Files.Root = $Root
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -FilesKey $Key
        $environment['TOOL_SERVER_CONNECTIONS'] | Should -BeExactly '[]'
        $environment['DEFAULT_MODEL_METADATA'] | Should -BeExactly '{}'
    }

    It 'lists only the tagged Model.Alias, the model the image gate unloads' {
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url
        $environment['OLLAMA_API_CONFIGS'] | Should -BeExactly '{"0":{"model_ids":["local-chat:latest"]}}'
    }

    It 'keeps loopback hosts off any proxy, adding them to the NO_PROXY Open WebUI would inherit' -ForEach @(
        @{ Inherited = ''; Expected = '127.0.0.1,localhost,::1' }
        @{ Inherited = 'proxy.example, 198.51.100.5'; Expected = 'proxy.example,198.51.100.5,127.0.0.1,localhost,::1' }
        @{ Inherited = 'LOCALHOST,127.0.0.1'; Expected = 'LOCALHOST,127.0.0.1,::1' }
    ) {
        (Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -NoProxy $Inherited)['NO_PROXY'] | Should -BeExactly $Expected
    }

    It 'adds the hosts OpenWebUI.Env.NO_PROXY names, without a warning' {
        $settings.OpenWebUI.Env['NO_PROXY'] = 'nas.example,localhost'
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -NoProxy 'proxy.example' -WarningVariable warnings 3>$null
        $environment['NO_PROXY'] | Should -BeExactly 'proxy.example,nas.example,localhost,127.0.0.1,::1'
        $warnings.Count | Should -Be 0
    }

    It 'leaves the built-in tools as Open WebUI ships them, with or without the file tools' -ForEach @(
        @{ Root = ''; Key = '' }
        @{ Root = 'D:\AI-Folder'; Key = ('ab' * 32) }
    ) {
        $settings.Files.Root = $Root
        $metadata = ConvertFrom-LocalAIJson -Text (Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -FilesKey $Key)['DEFAULT_MODEL_METADATA']
        $metadata.ContainsKey('builtinTools') | Should -BeFalse
    }

    It 'merges OpenWebUI.Env.DEFAULT_MODEL_METADATA in <Case>, without a warning' -ForEach @(
        @{ Case = 'without the file tools'; Key = ''; ToolIds = @('server:mine') }
        @{ Case = 'with the file tools, keeping them'; Key = ('ab' * 32); ToolIds = @('server:mine', 'server:files') }
    ) {
        $settings.Files.Root = 'D:\AI-Folder'
        $settings.OpenWebUI.Env['DEFAULT_MODEL_METADATA'] = '{"toolIds":["server:mine"],"builtinTools":{"notes":true,"time":false},"capabilities":{"vision":false}}'
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -FilesKey $Key -WarningVariable warnings 3>$null
        $warnings.Count | Should -Be 0
        $metadata = ConvertFrom-LocalAIJson -Text $environment['DEFAULT_MODEL_METADATA']
        @($metadata.toolIds) | Should -Be $ToolIds
        $metadata.builtinTools.notes | Should -BeTrue
        $metadata.builtinTools.time | Should -BeFalse
        @($metadata.builtinTools.Keys | Sort-Object) | Should -Be @('notes', 'time')
        $metadata.capabilities.vision | Should -BeFalse
        $environment['DEFAULT_MODEL_METADATA'] | Should -Not -BeLike "*`n*"
    }

    It 'warns once and keeps only its own metadata when OpenWebUI.Env.DEFAULT_MODEL_METADATA is <Case>' -ForEach @(
        @{ Case = 'not JSON'; Value = '{toolIds' }
        @{ Case = 'a JSON list'; Value = '["server:mine"]' }
    ) {
        $settings.OpenWebUI.Env['DEFAULT_MODEL_METADATA'] = $Value
        $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -WarningVariable warnings 3>$null
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeExactly 'OpenWebUI.Env.DEFAULT_MODEL_METADATA is left out: it is not a JSON object.'
        $environment['DEFAULT_MODEL_METADATA'] | Should -BeExactly '{}'
    }

    Context 'with the file tools' {
        BeforeEach {
            $settings.Files.Root = 'D:\AI-Folder'
            $settings.Ports.Files = 18189
            $key = 'ab' * 32
            $environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -FilesKey $key
            $json = $environment['TOOL_SERVER_CONNECTIONS']
            # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON list as one object, which ForEach-Object unrolls.
            $connections = @(ConvertFrom-Json -InputObject $json | ForEach-Object { $_ })
            $connection = $connections[0]
        }

        It 'registers mcpo as one compact OpenAPI connection in a JSON list' {
            $json.StartsWith('[{') | Should -BeTrue
            $json.EndsWith('}]') | Should -BeTrue
            $json | Should -Not -BeLike "*`n*"
            $connections.Count | Should -Be 1
            $connection.type | Should -BeExactly 'openapi'
            $connection.url | Should -BeExactly 'http://127.0.0.1:18189/files'
            $connection.path | Should -BeExactly 'openapi.json'
            $connection.spec_type | Should -BeExactly 'url'
        }

        It 'authenticates with the mcpo key as a Bearer token and forwards no cookies or extra headers' {
            $connection.auth_type | Should -BeExactly 'bearer'
            $connection.key | Should -BeExactly $key
            @($connection.PSObject.Properties.Name) | Should -Contain 'headers'
            $connection.headers | Should -BeNullOrEmpty
            $connection.forward_cookies | Should -BeFalse
        }

        It "turns the connection on, offers only mcpo's operation ids of Files.AllowedTools and keeps it to the admin" {
            $connection.config.enable | Should -BeTrue
            $connection.config.function_name_filter_list | Should -BeExactly ('tool_read_text_file_post,tool_list_directory_post,tool_search_files_post,' +
                'tool_get_file_info_post,tool_list_allowed_directories_post')
            @($connection.PSObject.Properties.Name) | Should -Contain 'config'
            @($connection.config.PSObject.Properties.Name) | Should -Contain 'access_grants'
            @($connection.config.access_grants).Count | Should -Be 0
            $json | Should -Not -BeLike '*access_control*'
        }

        It 'names the tool server files, shown as Workspace files' {
            $connection.info.id | Should -BeExactly 'files'
            $connection.info.name | Should -BeExactly 'Workspace files'
            $connection.info.description | Should -Not -BeNullOrEmpty
            # Open WebUI drops every tool server when either is null.
            $connection.config | Should -BeOfType [pscustomobject]
            $connection.info | Should -BeOfType [pscustomobject]
        }

        It 'follows Files.AllowedTools and Ports.Files' {
            $settings.Files.AllowedTools = @('read_text_file')
            $settings.Ports.Files = 18190
            $other = @(ConvertFrom-Json -InputObject (Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -FilesKey $key)['TOOL_SERVER_CONNECTIONS'] | ForEach-Object { $_ })[0]
            $other.config.function_name_filter_list | Should -BeExactly 'tool_read_text_file_post'
            $other.url | Should -BeExactly 'http://127.0.0.1:18190/files'
        }

        It 'preselects the file tools for models without tools of their own' {
            $environment['DEFAULT_MODEL_METADATA'] | Should -BeExactly '{"toolIds":["server:files"]}'
        }
    }

    It 'warns about nothing with the tracked defaults, which set no computed key' {
        $tracked = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $environment = Get-OpenWebUIEnvironment -Settings $tracked -OllamaUrl $url -WarningVariable warnings 3>$null
        $warnings.Count | Should -Be 0
        $environment['WEBUI_AUTH'] | Should -BeExactly 'True'
        $environment['ENABLE_PERSISTENT_CONFIG'] | Should -BeExactly 'False'
        $environment['ENV'] | Should -BeExactly 'prod'
        $environment.Contains('WEBUI_SECRET_KEY') | Should -BeFalse
    }
}

Describe 'Get-LocalAIService' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $url = 'http://127.0.0.1:11434'
        # What Windows and Python need to run, which Open WebUI, ComfyUI and the image gate all inherit, in the launcher's order.
        $windowsNames = @('SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'Path', 'TEMP', 'TMP', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH',
            'USERNAME', 'USERDOMAIN', 'COMPUTERNAME', 'APPDATA', 'LOCALAPPDATA', 'ProgramData', 'ALLUSERSPROFILE', 'PUBLIC', 'ProgramFiles',
            'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432', 'OS', 'NUMBER_OF_PROCESSORS',
            'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION', 'DriverData')

        # Fail when the list $Names names a variable that could hold a secret or a proxy's sign-in, or names one twice in any case.
        function Assert-NoSecretName([string[]]$Names) {
            foreach ($name in $Names) {
                foreach ($pattern in '*KEY*', '*TOKEN*', '*SECRET*', '*PASSWORD*', '*PROXY*') { $name | Should -Not -BeLike $pattern }
            }
            @($Names | Sort-Object -Unique).Count | Should -Be @($Names).Count
        }
    }

    BeforeEach {
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Ports.OpenWebUI = 18431
        $dataDir = Join-Path $TestDrive 'service-data'
        $settings.OpenWebUI.DataDir = $dataDir
        $paths = Get-LocalAIPaths -Root (Join-Path $TestDrive 'service-root')
        $installed = @{ Version = '0.12.3'; Path = 'C:\Users\User\.local\bin\open-webui.exe'; Python = '3.11.17' }
        $service = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed)[0]
    }

    It 'describes one required Open WebUI on loopback, run in its data folder with logs under Root' {
        @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed).Count | Should -Be 1
        $service.Name | Should -Be 'OpenWebUI'
        $service.Port | Should -Be 18431
        $service.FilePath | Should -Be 'C:\Users\User\.local\bin\open-webui.exe'
        $service.ArgumentList | Should -Be @('serve', '--host', '127.0.0.1', '--port', '18431')
        $service.WorkingDirectory | Should -Be $dataDir
        $service.Environment['DATA_DIR'] | Should -Be $dataDir
        $service.Url | Should -Be 'http://127.0.0.1:18431'
        $service.HealthUrl | Should -Be 'http://127.0.0.1:18431/health'
        $service.OutLog | Should -Be (Join-Path $paths.Logs 'open-webui.log')
        $service.ErrLog | Should -Be (Join-Path $paths.Logs 'open-webui.err.log')
        $service.TimeoutSeconds | Should -Be 600
        $service.Required | Should -BeTrue
    }

    It 'names the installed version and Python in the repair hint, not the pin' {
        $service.Repair | Should -BeExactly 'uv tool install --python 3.11.17 open-webui==0.12.3 --reinstall'
    }

    It 'carries the pin, its setting and the stamped version for the drift check' {
        $service.Pin.Setting | Should -Be 'OpenWebUI.Version'
        $service.Pin.Version | Should -Be '0.12.4'
        $service.Pin.Stamped | Should -Be '0.12.3'
    }

    It 'lets Open WebUI inherit only what Windows and Python need and where its embedding model is kept' {
        @($service.InheritEnvironment) | Should -Be (@($windowsNames) + @('HF_HOME', 'HF_HUB_CACHE', 'HUGGINGFACE_HUB_CACHE', 'XDG_CACHE_HOME',
                'SENTENCE_TRANSFORMERS_HOME', 'HF_HUB_OFFLINE'))
        Assert-NoSecretName $service.InheritEnvironment
    }

    It 'adds OpenWebUI.InheritEnvironment to that list, each name once whatever its case' {
        $settings.OpenWebUI.InheritEnvironment = @('HTTPS_PROXY', 'path', 'hf_home', 'SSL_CERT_FILE')
        $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed)[0]
        @($listed.InheritEnvironment) | Should -Be (@($service.InheritEnvironment) + @('HTTPS_PROXY', 'SSL_CERT_FILE'))
    }

    It 'leaves the list as it is for settings without OpenWebUI.InheritEnvironment' {
        $settings.OpenWebUI.Remove('InheritEnvironment')
        $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed)[0]
        @($listed.InheritEnvironment) | Should -Be @($service.InheritEnvironment)
    }

    It 'identifies Open WebUI by GET /health and GET /api/version' {
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -eq 'http://127.0.0.1:18431/health' } -MockWith { [pscustomobject]@{ status = $true } }
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -eq 'http://127.0.0.1:18431/api/version' } -MockWith { [pscustomobject]@{ version = '0.12.3'; deployment_id = '' } }
        & $service.Identity $service | Should -Be '0.12.3'
    }

    It 'rejects a foreign responder that <Case>' -ForEach @(
        @{ Case = 'answers /health with status ok'; Health = 'ok'; Version = '0.12.3'; Message = '*/health did not answer*not Open WebUI*' }
        @{ Case = 'serves an HTML page'; Health = 'html'; Version = '0.12.3'; Message = '*/health did not answer*not Open WebUI*' }
        @{ Case = 'has no version'; Health = 'true'; Version = ''; Message = '*/api/version did not answer with a version*' }
    ) {
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/health' } -MockWith {
            if ($Health -eq 'html') { '<html><body>Welcome</body></html>' }
            elseif ($Health -eq 'true') { [pscustomobject]@{ status = $true } }
            else { [pscustomobject]@{ status = $Health } }
        }
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/api/version' } -MockWith { [pscustomobject]@{ version = $Version } }
        { & $service.Identity $service } | Should -Throw -ExpectedMessage $Message
    }

    Context 'with ComfyUI' {
        BeforeEach {
            $settings.Ports.ComfyUI = 18188
            # Images straight to ComfyUI; the 'and the image gate' context turns the gate on.
            $settings.Images.UnloadChat = $false
            $comfyDir = Join-Path $TestDrive 'service-comfy'
            $settings.ComfyUI.Dir = $comfyDir
            $stamped = @{ Commit = 'abcdef0123456789abcdef0123456789abcdef01'; Python = 'C:\Users\User\ComfyUI\.venv\Scripts\python.exe' }
            $workflow = @{ Workflow = '{"9": {"class_type": "PreviewImage", "inputs": {}}}'; Nodes = '[]' }
            $all = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow)
            $comfy = $all[0]
        }

        It 'lists an optional ComfyUI first, then the required Open WebUI with images on' {
            $all.Count | Should -Be 2
            $all[0].Name | Should -Be 'ComfyUI'
            $all[0].Required | Should -BeFalse
            $all[1].Name | Should -Be 'OpenWebUI'
            $all[1].Required | Should -BeTrue
            $all[1].Environment['ENABLE_IMAGE_GENERATION'] | Should -BeExactly 'True'
            $all[1].Environment['COMFYUI_BASE_URL'] | Should -BeExactly 'http://127.0.0.1:18188'
            $all[1].Environment['COMFYUI_WORKFLOW'] | Should -BeExactly $workflow.Workflow
        }

        It 'runs main.py with the stamped venv python, ComfyUI.Args and then the loopback bind, in Dir and with logs under Root' {
            $comfy.FilePath | Should -Be 'C:\Users\User\ComfyUI\.venv\Scripts\python.exe'
            $comfy.ArgumentList | Should -Be @('main.py', '--disable-all-custom-nodes', '--offline', '--disable-smart-memory', '--fp8_e4m3fn-unet',
                '--fp8_e4m3fn-text-enc', '--listen', '127.0.0.1', '--port', '18188')
            $comfy.WorkingDirectory | Should -Be $comfyDir
            $comfy.Port | Should -Be 18188
            $comfy.Url | Should -Be 'http://127.0.0.1:18188'
            $comfy.HealthUrl | Should -Be 'http://127.0.0.1:18188/system_stats'
            $comfy.OutLog | Should -Be (Join-Path $paths.Logs 'comfyui.log')
            $comfy.ErrLog | Should -Be (Join-Path $paths.Logs 'comfyui.err.log')
            $comfy.TimeoutSeconds | Should -Be 300
            $comfy.Environment.Count | Should -Be 0
        }

        It 'lets ComfyUI inherit only what Windows and Python need, its GPU choice and order, the allocator settings and CUDA_PATH' {
            @($comfy.InheritEnvironment) | Should -Be (@($windowsNames) + @('CUDA_VISIBLE_DEVICES', 'CUDA_DEVICE_ORDER', 'PYTORCH_CUDA_ALLOC_CONF', 'PYTORCH_ALLOC_CONF',
                    'CUDA_PATH'))
            Assert-NoSecretName $comfy.InheritEnvironment
        }

        It 'adds ComfyUI.InheritEnvironment to ComfyUI only, each name once whatever its case' {
            $settings.ComfyUI.InheritEnvironment = @('CUDA_CACHE_PATH', 'cuda_visible_devices')
            $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow)
            @($listed[0].InheritEnvironment) | Should -Be (@($comfy.InheritEnvironment) + @('CUDA_CACHE_PATH'))
            @($listed[1].InheritEnvironment) | Should -Not -Contain 'CUDA_CACHE_PATH'
        }

        It 'judges drift by the stamped commit against ComfyUI.Commit' {
            $comfy.Pin.Setting | Should -Be 'ComfyUI.Commit'
            $comfy.Pin.Version | Should -Be '483dae4326356b81de05d27aca3f433dd323cc25'
            $comfy.Pin.Stamped | Should -Be 'abcdef0123456789abcdef0123456789abcdef01'
            $comfy.Pin.Running | Should -BeFalse
            $all[1].Pin.Running | Should -BeTrue
        }

        It 'repairs with a reinstall of the versions the venv holds, then a fresh torch check' {
            $py = 'C:\Users\User\ComfyUI\.venv\Scripts\python.exe'
            $comfy.Repair | Should -BeExactly ("uv pip freeze --python `"$py`" | uv pip install --python `"$py`" --torch-backend cu130 --reinstall -r -, " +
                "then delete `"C:\Users\User\ComfyUI\.venv\local-ai-install.json`" and run 'local-ai install'")
        }

        It 'repairs a venv on the Microsoft Store Python with update, which makes it anew, as uv would launch that Python to reinstall' {
            $venv = Join-Path $TestDrive 'service-store\.venv'
            Write-TestPyVenvConfig -Venv $venv -BaseHome $storeHome -Version '3.13.14'
            $stamped.Python = Join-Path $venv 'Scripts\python.exe'
            $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow)
            $listed[0].Repair | Should -BeExactly ("'local-ai update', which makes ComfyUI's venv anew on a uv-managed Python. The venv runs on the Microsoft Store " +
                'Python, whose launches can fail or hang until Windows restarts')
        }

        It 'identifies ComfyUI by GET /system_stats' {
            Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -eq 'http://127.0.0.1:18188/system_stats' } -MockWith {
                ConvertFrom-Json -InputObject '{"system": {"comfyui_version": "0.42.5"}, "devices": []}'
            }
            & $comfy.Identity $comfy | Should -Be '0.42.5'
        }

        It 'drops <Dropped> from ComfyUI.Args with a warning and keeps the rest' -ForEach @(
            @{ Given = @('--listen', '0.0.0.0', '--offline'); Dropped = '--listen 0.0.0.0'; Kept = @('--offline'); Reason = '--listen 127.0.0.1' }
            @{ Given = @('--offline', '--listen'); Dropped = '--listen'; Kept = @('--offline'); Reason = '--listen 127.0.0.1' }
            @{ Given = @('--listen=0.0.0.0'); Dropped = '--listen=0.0.0.0'; Kept = @(); Reason = '--listen 127.0.0.1' }
            @{ Given = @('--port', '9000', '--disable-smart-memory'); Dropped = '--port 9000'; Kept = @('--disable-smart-memory'); Reason = 'Ports.ComfyUI' }
            @{ Given = @('--enable-manager', '--offline'); Dropped = '--enable-manager'; Kept = @('--offline'); Reason = 'Manager' }
            @{ Given = @('--enable-cors-header', '--offline'); Dropped = '--enable-cors-header'; Kept = @('--offline'); Reason = 'requests come from its own page' }
            @{ Given = @('--enable-cors-header', 'http://evil.example'); Dropped = '--enable-cors-header http://evil.example'; Kept = @(); Reason = 'its own page' }
            # argparse takes a unique abbreviation as the full flag.
            @{ Given = @('--liste', '0.0.0.0', '--offline'); Dropped = '--liste 0.0.0.0'; Kept = @('--offline'); Reason = '--listen 127.0.0.1' }
            @{ Given = @('--liste=0.0.0.0'); Dropped = '--liste=0.0.0.0'; Kept = @(); Reason = '--listen 127.0.0.1' }
            @{ Given = @('--po', '9999'); Dropped = '--po 9999'; Kept = @(); Reason = 'Ports.ComfyUI' }
            @{ Given = @('--enable-cors', '--offline'); Dropped = '--enable-cors'; Kept = @('--offline'); Reason = 'its own page' }
            @{ Given = @('--enable-manager-legacy-ui'); Dropped = '--enable-manager-legacy-ui'; Kept = @(); Reason = 'Manager' }
            @{ Given = @('--enable-manager-l', '--offline'); Dropped = '--enable-manager-l'; Kept = @('--offline'); Reason = 'Manager' }
            @{ Given = @('--offline', '--', 'x'); Dropped = '--'; Kept = @('--offline', 'x'); Reason = 'end the options' }
        ) {
            $settings.ComfyUI.Args = $Given
            $all = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow -WarningVariable warnings 3>$null)
            $all[0].ArgumentList | Should -Be (@('main.py') + $Kept + @('--listen', '127.0.0.1', '--port', '18188'))
            $warnings.Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "ComfyUI.Args '$Dropped' is ignored: *$Reason*"
        }

        It 'keeps flags that only share a beginning with a reserved one, such as <Kept>' -ForEach @(
            @{ Kept = '--list-feature-flags' }
            @{ Kept = '--preview-method' }
            @{ Kept = '--lowvram' }
        ) {
            $settings.ComfyUI.Args = @($Kept)
            $all = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow -WarningVariable warnings 3>$null)
            $all[0].ArgumentList | Should -Be @('main.py', $Kept, '--listen', '127.0.0.1', '--port', '18188')
            $warnings.Count | Should -Be 0
        }

        It 'adds no ComfyUI and turns images off for Open WebUI when <Case>' -ForEach @(
            @{ Case = 'Images.Enabled is off'; Enabled = $false; Stamp = $true; Loaded = $true }
            @{ Case = 'the stamp names none'; Enabled = $true; Stamp = $false; Loaded = $true }
            @{ Case = 'no workflow is given'; Enabled = $true; Stamp = $true; Loaded = $false }
        ) {
            $settings.Images.Enabled = $Enabled
            $record = if ($Stamp) { $stamped } else { $null }
            $given = if ($Loaded) { $workflow } else { $null }
            $all = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $record -ImageWorkflow $given)
            $all.Count | Should -Be 1
            $all[0].Name | Should -Be 'OpenWebUI'
            $all[0].Environment['ENABLE_IMAGE_GENERATION'] | Should -BeExactly 'False'
            $all[0].Environment['COMFYUI_BASE_URL'] | Should -BeExactly ''
        }

        Context 'and the image gate' {
            BeforeEach {
                $settings.Images.UnloadChat = $true
                $settings.Ports.ImageGate = 18190
                $all = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow)
                $gate = $all[1]
                $script = Join-Path (Split-Path (Get-Module LocalAI).Path -Parent) 'image_gate.py'
            }

            It 'lists ComfyUI, then an optional gate waited for first, then Open WebUI with images through the gate' {
                @($all | ForEach-Object { $_.Name }) | Should -Be @('ComfyUI', 'ImageGate', 'OpenWebUI')
                $gate.Required | Should -BeFalse
                $gate.WaitFirst | Should -BeTrue
                $all[2].Environment['COMFYUI_BASE_URL'] | Should -BeExactly 'http://127.0.0.1:18190'
                $all[2].Environment['ENABLE_IMAGE_GENERATION'] | Should -BeExactly 'True'
            }

            It 'runs image_gate.py isolated with the stamped ComfyUI python, in an empty launcher folder, with logs under Root' {
                Test-Path -LiteralPath $script -PathType Leaf | Should -BeTrue
                $gate.FilePath | Should -Be 'C:\Users\User\ComfyUI\.venv\Scripts\python.exe'
                $gate.ArgumentList | Should -Be @('-I', '-B', $script, '--port', '18190', '--upstream', 'http://127.0.0.1:18188', '--ollama', $url,
                    '--model', 'local-chat:latest', '--unload-timeout', '30')
                $gate.WorkingDirectory | Should -Be (Join-Path $paths.Root 'image-gate')
                $gate.Environment.Count | Should -Be 0
                $gate.Port | Should -Be 18190
                $gate.Url | Should -Be 'http://127.0.0.1:18190'
                $gate.HealthUrl | Should -Be 'http://127.0.0.1:18190/local-ai/image-gate'
                $gate.OutLog | Should -Be (Join-Path $paths.Logs 'imagegate.log')
                $gate.ErrLog | Should -Be (Join-Path $paths.Logs 'imagegate.err.log')
            }

            It 'lets the gate inherit only what Windows and Python need, also when ComfyUI.InheritEnvironment names more' {
                @($gate.InheritEnvironment) | Should -Be $windowsNames
                Assert-NoSecretName $gate.InheritEnvironment
                $settings.ComfyUI.InheritEnvironment = @('CUDA_CACHE_PATH')
                $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow)
                @($listed[1].InheritEnvironment) | Should -Be $windowsNames
            }

            It 'waits 15 s for it, carries no pin, names the err log in the repair hint and says what happens without it' {
                $gate.TimeoutSeconds | Should -Be 15
                $gate.Pin | Should -BeNullOrEmpty
                $gate.Repair | Should -BeLike "*'local-ai install'*$(Join-Path $paths.Logs 'imagegate.err.log')*"
                $gate.Fallback | Should -BeExactly 'Images go to ComfyUI directly, so local-chat is not unloaded before images'
            }

            It 'names update in the repair hint when the venv it runs on uses the Microsoft Store Python' {
                $venv = Join-Path $TestDrive 'gate-store\.venv'
                Write-TestPyVenvConfig -Venv $venv -BaseHome $storeHome -Version '3.13.14'
                $stamped.Python = Join-Path $venv 'Scripts\python.exe'
                $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow)
                $listed[1].Repair | Should -BeExactly ("'local-ai update', which makes ComfyUI's venv anew on a uv-managed Python. The venv runs on the Microsoft Store " +
                    "Python, whose launches can fail or hang until Windows restarts; the gate runs on that venv and logs its errors to $(Join-Path $paths.Logs 'imagegate.err.log')")
            }

            It 'passes another alias, port and timeout through' {
                $settings.Model.Alias = 'other-chat'
                $settings.Ports.ImageGate = 18191
                $settings.Images.UnloadTimeoutSeconds = 45
                $other = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow)[1]
                ($other.ArgumentList -join ' ') | Should -BeLike '*--port 18191 *--model other-chat:latest --unload-timeout 45'
                $other.Model | Should -BeExactly 'other-chat:latest'
                $other.Fallback | Should -BeLike '*so other-chat is not unloaded*'
            }

            It 'identifies the gate by GET /local-ai/image-gate when it fronts this ComfyUI and unloads this model from this Ollama' {
                Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -eq 'http://127.0.0.1:18190/local-ai/image-gate' } -MockWith {
                    [pscustomobject]@{ service = 'local-ai-image-gate'; version = '1.0.0'; upstream = 'http://127.0.0.1:18188'; ollama = 'http://127.0.0.1:11434'
                        model = 'local-chat:latest'; unload_timeout = 30 }
                }
                & $gate.Identity $gate | Should -Be '1.0.0'
            }

            It 'rejects a responder that <Case>' -ForEach @(
                @{ Case = 'is ComfyUI'; Change = @{ service = $null; version = $null }; Message = '*did not answer as local-ai-image-gate*not the image gate*' }
                @{ Case = 'names the service in other case'; Change = @{ service = 'Local-AI-Image-Gate' }; Message = '*not the image gate*' }
                @{ Case = 'fronts another ComfyUI'; Change = @{ upstream = 'http://127.0.0.1:8188' }; Message = "*has upstream 'http://127.0.0.1:8188', not 'http://127.0.0.1:18188'*" }
                @{ Case = 'unloads from another Ollama'; Change = @{ ollama = 'http://127.0.0.1:11500' }; Message = "*has ollama 'http://127.0.0.1:11500', not*" }
                @{ Case = 'unloads another model'; Change = @{ model = 'old-chat:latest' }; Message = "*has model 'old-chat:latest', not 'local-chat:latest'*" }
            ) {
                $answer = @{ service = 'local-ai-image-gate'; version = '1.0.0'; upstream = 'http://127.0.0.1:18188'; ollama = 'http://127.0.0.1:11434'; model = 'local-chat:latest' }
                foreach ($key in $Change.Keys) { $answer[$key] = $Change[$key] }
                Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]$answer }
                { & $gate.Identity $gate } | Should -Throw -ExpectedMessage $Message
            }

            It 'accepts Ollama at <Ollama>, a loopback address' -ForEach @(
                @{ Ollama = 'http://localhost:11434' }
                @{ Ollama = 'http://[::1]:11434' }
                @{ Ollama = 'http://127.0.0.2:11434/base' }
            ) {
                $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $Ollama -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow -WarningVariable warnings 3>$null)
                $listed[1].Name | Should -Be 'ImageGate'
                $listed[1].Ollama | Should -BeExactly $Ollama
                $warnings.Count | Should -Be 0
            }

            It 'leaves the gate out, warning once and sending images to ComfyUI, when Ollama is not on a loopback address' {
                $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl 'http://192.0.2.20:11434' -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow -WarningVariable warnings 3>$null)
                @($listed | ForEach-Object { $_.Name }) | Should -Be @('ComfyUI', 'OpenWebUI')
                $listed[1].Environment['COMFYUI_BASE_URL'] | Should -BeExactly 'http://127.0.0.1:18188'
                $warnings.Count | Should -Be 1
                "$($warnings[0])" | Should -BeLike "Images go to ComfyUI directly, so local-chat is not unloaded before images: *http://192.0.2.20:11434*Images.UnloadChat = `$false*"
            }

            It 'adds no gate when ComfyUI is not part of the start' {
                $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $null -ImageWorkflow $workflow)
                @($listed | ForEach-Object { $_.Name }) | Should -Be @('OpenWebUI')
            }

            It 'lists mcpo after ComfyUI and the gate, before Open WebUI, when the file tools are on as well' {
                $settings.Files.Root = 'D:\AI-Folder'
                $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -ComfyUI $stamped -ImageWorkflow $workflow `
                        -Files @{ McpoPath = 'C:\x\mcpo.exe'; McpoVersion = '0.0.20'; Key = ('ab' * 32) })
                @($listed | ForEach-Object { $_.Name }) | Should -Be @('ComfyUI', 'ImageGate', 'Files', 'OpenWebUI')
                $listed[3].Environment['COMFYUI_BASE_URL'] | Should -BeExactly 'http://127.0.0.1:18190'
                $listed[3].Environment['TOOL_SERVER_CONNECTIONS'] | Should -BeLike '*"url":"http://127.0.0.1:8189/files"*'
            }
        }
    }

    Context 'with the file tools' {
        BeforeEach {
            $settings.Files.Root = 'D:\AI-Folder\'
            $settings.Ports.Files = 18189
            $key = 'ab' * 32
            $files = @{ McpoPath = 'C:\Users\User\.local\bin\mcpo.exe'; McpoVersion = '0.0.19'; Key = $key }
            $all = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -Files $files)
            $mcpo = $all[0]
        }

        It 'lists an optional mcpo, waited for first, then Open WebUI with the file tools on' {
            @($all | ForEach-Object { $_.Name }) | Should -Be @('Files', 'OpenWebUI')
            $mcpo.Required | Should -BeFalse
            $mcpo.WaitFirst | Should -BeTrue
            $all[1].Environment['TOOL_SERVER_CONNECTIONS'] | Should -BeLike "*`"url`":`"http://127.0.0.1:18189/files`"*`"key`":`"$key`"*"
            @((ConvertFrom-LocalAIJson -Text $all[1].Environment['DEFAULT_MODEL_METADATA']).toolIds) | Should -Be @('server:files')
        }

        It 'runs mcpo.exe on loopback with the key, strict auth, the two Open WebUI origins, the config and warnings-only logging' {
            $mcpo.FilePath | Should -Be 'C:\Users\User\.local\bin\mcpo.exe'
            $mcpo.ArgumentList | Should -Be @('--host', '127.0.0.1', '--port', '18189', '--api-key', $key, '--strict-auth',
                '--cors-allow-origins', 'http://127.0.0.1:18431', '--cors-allow-origins', 'http://localhost:18431',
                '--config', (Join-Path $paths.Root 'mcpo.json'), '--log-level', 'WARNING')
            # -h would be --host and -v the served API's version.
            @($mcpo.ArgumentList | Where-Object { $_ -match '^-[^-]' }).Count | Should -Be 0
            $mcpo.Environment.Count | Should -Be 0
        }

        It 'lets mcpo, and the node server it hands its environment, inherit only what Windows, Python and Node.js need' {
            @($mcpo.InheritEnvironment | Sort-Object) | Should -Be @('APPDATA', 'ComSpec', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'NUMBER_OF_PROCESSORS', 'Path',
                'PATHEXT', 'PROCESSOR_ARCHITECTURE', 'SystemDrive', 'SystemRoot', 'TEMP', 'TMP', 'USERNAME', 'USERPROFILE', 'windir')
            foreach ($name in $mcpo.InheritEnvironment) { $name | Should -Not -BeLike '*KEY*'; $name | Should -Not -BeLike '*TOKEN*'; $name | Should -Not -BeLike '*SECRET*' }
            # Open WebUI's own list holds every one of them, and more.
            @($mcpo.InheritEnvironment | Where-Object { @($all[1].InheritEnvironment) -notcontains $_ }) | Should -BeNullOrEmpty
            @($all[1].InheritEnvironment).Count | Should -BeGreaterThan @($mcpo.InheritEnvironment).Count
        }

        It 'serves the root spelled as on disk, as New-McpoConfig hands it to the server' {
            $onDisk = Join-Path $TestDrive 'service-files\AI-Files'
            $null = New-Item -ItemType Directory -Force -Path $onDisk
            $settings.Files.Root = $onDisk.ToUpperInvariant()
            $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -Files $files)
            $listed[0].Root | Should -BeExactly (& (Get-Module LocalAI) { param($Given) (Resolve-OnDiskPath -Path $Given).Path } $onDisk)
            $listed[0].Root | Should -BeLike '*\service-files\AI-Files'
        }

        It 'runs in an empty launcher folder with logs under Root, waits Files.HealthTimeoutSeconds and says what happens without it' {
            $mcpo.WorkingDirectory | Should -Be (Join-Path $paths.Root 'mcpo')
            $mcpo.Port | Should -Be 18189
            $mcpo.Url | Should -Be 'http://127.0.0.1:18189'
            $mcpo.HealthUrl | Should -Be 'http://127.0.0.1:18189/files/openapi.json'
            $mcpo.OutLog | Should -Be (Join-Path $paths.Logs 'files.log')
            $mcpo.ErrLog | Should -Be (Join-Path $paths.Logs 'files.err.log')
            $mcpo.TimeoutSeconds | Should -Be 20
            $mcpo.Fallback | Should -BeExactly 'The file tools are off for this start'
            $mcpo.Root | Should -BeExactly 'D:\AI-Folder'
        }

        It 'judges drift by the stamped mcpo version against Files.McpoVersion' {
            $mcpo.Pin.Setting | Should -Be 'Files.McpoVersion'
            $mcpo.Pin.Version | Should -Be '0.0.20'
            $mcpo.Pin.Stamped | Should -Be '0.0.19'
            $mcpo.Pin.Running | Should -BeFalse
            # The pin is mcpo's, while the answers name the server's version.
            $mcpo.Pin.Label | Should -BeExactly 'mcpo'
        }

        It 'repairs with a uv reinstall at the pins or a fresh npm ci, naming the err log' {
            $mcpo.Repair | Should -BeLike ('uv tool install --python 3.12 --managed-python mcpo==0.0.20 --with "mcp==1.30.0" --with "fastapi<0.145" ' +
                '--exclude-newer 2026-10-13T00:00:00Z --reinstall for mcpo*delete "*files-server\local-ai-install.json"*files.err.log')
        }

        It 'identifies mcpo through Get-FilesServerVersion with the key, the server version, the allowed tools and the root' {
            Mock Get-FilesServerVersion -ModuleName LocalAI -MockWith { '2.0.1' }
            & $mcpo.Identity $mcpo | Should -BeExactly 'server-filesystem 2.0.1'
            Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Url -eq 'http://127.0.0.1:18189' -and $Key -eq $key -and $Version -eq '2.0.1' -and $Root -eq 'D:\AI-Folder' -and
                ($Tools -join ',') -eq 'read_text_file,list_directory,search_files,get_file_info,list_allowed_directories'
            }
        }

        It 'adds no mcpo and registers no tool server when <Case>' -ForEach @(
            @{ Case = 'start passes no mcpo'; Root = 'D:\AI-Folder'; Given = $false }
            @{ Case = 'Files.Root is empty'; Root = ''; Given = $true }
        ) {
            $settings.Files.Root = $Root
            $given = if ($Given) { $files } else { $null }
            $listed = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $installed -Files $given)
            @($listed | ForEach-Object { $_.Name }) | Should -Be @('OpenWebUI')
            $listed[0].Environment['TOOL_SERVER_CONNECTIONS'] | Should -BeExactly '[]'
        }
    }
}

Describe 'Get-PortOwner' {
    BeforeAll {
        $start = [datetime]::new(2026, 10, 27, 9, 30, 0, [DateTimeKind]::Local)
    }

    It 'returns the PID, name, path and UTC start ticks of the listener' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ LocalAddress = '::1'; LocalPort = 18431; OwningProcess = 1624 }
            [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 18431; OwningProcess = 1624 }
        }
        Mock Get-Process -ModuleName LocalAI -ParameterFilter { $Id -contains 1624 } -MockWith {
            [pscustomobject]@{ Id = 1624; Name = 'python'; Path = 'C:\uv\python\python.exe'; StartTime = $start }
        }
        $owner = Get-PortOwner -Port 18431
        $owner.Id | Should -Be 1624
        $owner.Name | Should -Be 'python'
        $owner.Path | Should -Be 'C:\uv\python\python.exe'
        $owner.StartTicks | Should -Be $start.ToUniversalTime().Ticks
        Should -Invoke Get-NetTCPConnection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $State -eq 'Listen' -and $LocalPort -eq 18431 }
    }

    It 'returns $null when nothing listens on the port' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith {
            $reason = New-Object System.Exception 'No matching MSFT_NetTCPConnection objects found by CIM query.'
            $record = New-Object System.Management.Automation.ErrorRecord $reason, 'CmdletizationQuery_NotFound,Get-NetTCPConnection', 'ObjectNotFound', $null
            Write-Error -ErrorRecord $record -ErrorAction $PesterBoundParameters['ErrorAction']
        }
        Get-PortOwner -Port 18431 | Should -BeNullOrEmpty
    }

    It 'keeps the PID of an owner that has exited' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith { [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 18431; OwningProcess = 1624 } }
        Mock Get-Process -ModuleName LocalAI -ParameterFilter { $Id -contains 1624 }
        $owner = Get-PortOwner -Port 18431
        $owner.Id | Should -Be 1624
        $owner.Name | Should -BeNullOrEmpty
        $owner.StartTicks | Should -BeNullOrEmpty
    }
}

Describe 'Get-LoopbackClient and Test-ProcessInThisSession' {
    It 'returns each process connected to the port from a loopback address once, leaving out the PIDs it is told to' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ RemoteAddress = '127.0.0.1'; RemotePort = 11434; OwningProcess = 300 }
            [pscustomobject]@{ RemoteAddress = '127.0.0.1'; RemotePort = 11434; OwningProcess = 300 }
            [pscustomobject]@{ RemoteAddress = '::1'; RemotePort = 11434; OwningProcess = 301 }
            [pscustomobject]@{ RemoteAddress = '::ffff:127.0.0.1'; RemotePort = 11434; OwningProcess = 302 }
            [pscustomobject]@{ RemoteAddress = '192.0.2.30'; RemotePort = 11434; OwningProcess = 303 }
            [pscustomobject]@{ RemoteAddress = '127.0.0.1'; RemotePort = 11434; OwningProcess = 400 }
        }
        Mock Get-Process -ModuleName LocalAI -MockWith { if ($Id[0] -ne 302) { [pscustomobject]@{ Id = $Id[0]; Name = "client$($Id[0])" } } }
        $clients = @(Invoke-ModuleFunction 'Get-LoopbackClient' @{ Port = 11434; Exclude = @(400) })
        @($clients | ForEach-Object { $_.Id }) | Should -Be @(300, 301, 302)
        @($clients | ForEach-Object { $_.Name }) | Should -Be @('client300', 'client301', $null)
        Should -Invoke Get-NetTCPConnection -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $State -eq 'Established' -and $RemotePort -eq 11434 -and $PesterBoundParameters['ErrorAction'] -eq 'SilentlyContinue'
        }
    }

    It 'returns nothing when no connection matches, and throws any other Get-NetTCPConnection error' {
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith {
            $reason = New-Object System.Exception 'No matching MSFT_NetTCPConnection objects found by CIM query.'
            $record = New-Object System.Management.Automation.ErrorRecord $reason, 'CmdletizationQuery_NotFound,Get-NetTCPConnection', 'ObjectNotFound', $null
            Write-Error -ErrorRecord $record -ErrorAction $PesterBoundParameters['ErrorAction']
        }
        @(Invoke-ModuleFunction 'Get-LoopbackClient' @{ Port = 11434 }).Count | Should -Be 0
        Mock Get-NetTCPConnection -ModuleName LocalAI -MockWith { throw 'The CIM server is unavailable.' }
        { Invoke-ModuleFunction 'Get-LoopbackClient' @{ Port = 11434 } } | Should -Throw -ExpectedMessage '*CIM server is unavailable*'
    }

    It 'says whether a process runs in this window''s Windows session, and no when its session cannot be read' {
        $own = [Diagnostics.Process]::GetCurrentProcess()
        $session = $own.SessionId
        $own.Dispose()
        $found = @{ Process = [pscustomobject]@{ ProcessId = 100; SessionId = [uint32]$session } }
        Mock Get-CimInstance -ModuleName LocalAI -MockWith { $found.Process }
        Invoke-ModuleFunction 'Test-ProcessInThisSession' @{ ProcessId = 100 } | Should -BeTrue
        Should -Invoke Get-CimInstance -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=100' }
        $found.Process = [pscustomobject]@{ ProcessId = 100; SessionId = [uint32]($session + 1) }
        Invoke-ModuleFunction 'Test-ProcessInThisSession' @{ ProcessId = 100 } | Should -BeFalse
        $found.Process = $null
        Invoke-ModuleFunction 'Test-ProcessInThisSession' @{ ProcessId = 100 } | Should -BeFalse
    }
}

Describe 'Test-RecordedProcess' {
    BeforeAll {
        $start = [datetime]::new(2026, 10, 27, 9, 30, 0, [DateTimeKind]::Local).AddTicks(1234567)
        $exe = 'C:\Users\User\.local\bin\open-webui.exe'
        $record = @{ Pid = 4242; StartTicks = $start.ToUniversalTime().Ticks; Path = $exe }
    }

    BeforeEach {
        $running = @{ StartTime = $start; Path = $exe; Created = $null }
        Mock Get-Process -ModuleName LocalAI -ParameterFilter { $Id -contains 4242 } -MockWith {
            [pscustomobject]@{ Id = 4242; StartTime = $running.StartTime; Path = $running.Path }
        }
        Mock Get-CimInstance -ModuleName LocalAI -MockWith {
            if ($running.Created) { [pscustomobject]@{ ProcessId = 4242; CreationDate = $running.Created; ExecutablePath = $null } }
        }
    }

    It 'passes for the recorded PID, start time and path' {
        Test-RecordedProcess -Record $record | Should -BeTrue
    }

    It 'compares the path without case' {
        $running.Path = $exe.ToUpperInvariant()
        Test-RecordedProcess -Record $record | Should -BeTrue
    }

    It 'allows less than a second between the recorded and the read start time' {
        $running.StartTime = $start.AddMilliseconds(400)
        Test-RecordedProcess -Record $record | Should -BeTrue
    }

    It 'fails for <Case>' -ForEach @(
        @{ Case = 'a PID reused by a process started later'; Seconds = 5; Path = 'C:\Users\User\.local\bin\open-webui.exe' }
        @{ Case = 'a PID that runs another program'; Seconds = 0; Path = 'C:\Windows\System32\notepad.exe' }
        @{ Case = 'a process whose path cannot be read'; Seconds = 0; Path = $null }
    ) {
        $running.StartTime = $start.AddSeconds($Seconds)
        $running.Path = $Path
        Test-RecordedProcess -Record $record | Should -BeFalse
    }

    It 'fails when no process has the PID' {
        Mock Get-Process -ModuleName LocalAI -ParameterFilter { $Id -contains 4242 }
        Test-RecordedProcess -Record $record | Should -BeFalse
    }

    It 'fails when the start time cannot be read' {
        $running.StartTime = $null
        Test-RecordedProcess -Record $record | Should -BeFalse
    }

    It 'fails for a record without a start time' {
        Test-RecordedProcess -Record @{ Pid = 4242; Path = $exe } | Should -BeFalse
        Should -Invoke Get-Process -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'calls the recorded process <State> when <Case>' -ForEach @(
        @{ Case = 'it runs as recorded'; Read = $true; Path = 'C:\Users\User\.local\bin\open-webui.exe'; Created = 0; State = 'match' }
        @{ Case = 'only Win32_Process gives its start time, which matches'; Read = $false; Path = $null; Created = 0; State = 'unreadable' }
        @{ Case = 'neither start time can be read'; Read = $false; Path = $null; Created = $null; State = 'unreadable' }
        @{ Case = 'its start time matches but its path cannot be read'; Read = $true; Path = $null; Created = $null; State = 'unreadable' }
        @{ Case = 'Win32_Process gives a later start time, from a reused PID'; Read = $false; Path = $null; Created = 30; State = 'other' }
        @{ Case = 'it runs another program'; Read = $true; Path = 'C:\Windows\System32\notepad.exe'; Created = $null; State = 'other' }
    ) {
        $running.StartTime = if ($Read) { $start } else { $null }
        $running.Path = $Path
        $running.Created = if ($null -ne $Created) { $start.AddSeconds($Created) } else { $null }
        Get-RecordedProcessState -Record $record | Should -BeExactly $State
    }

    It 'calls a PID without a process other' {
        Mock Get-Process -ModuleName LocalAI -ParameterFilter { $Id -contains 4242 }
        Get-RecordedProcessState -Record $record | Should -BeExactly 'other'
        Should -Invoke Get-CimInstance -ModuleName LocalAI -Times 0 -Exactly
    }
}

Describe 'Test-ProcessDescendant' {
    BeforeEach {
        $base = [datetime]::new(2026, 10, 27, 9, 30, 0, [DateTimeKind]::Local)
        # cmd.exe 4242 > open-webui.exe 5000 > venv launcher 5044 > base python 8496.
        $tree = @{
            4242 = @{ Parent = 900; Created = $base }
            5000 = @{ Parent = 4242; Created = $base.AddMilliseconds(100) }
            5044 = @{ Parent = 5000; Created = $base.AddMilliseconds(200) }
            8496 = @{ Parent = 5044; Created = $base.AddMilliseconds(300) }
            900  = @{ Parent = 4; Created = $base.AddDays(-1) }
        }
        Mock Get-CimInstance -ModuleName LocalAI -MockWith {
            $id = [int]($Filter -replace '^ProcessId=', '')
            if ($tree.ContainsKey($id)) { [pscustomobject]@{ ProcessId = $id; ParentProcessId = $tree[$id].Parent; CreationDate = $tree[$id].Created } }
        }
    }

    It 'passes for the listener three levels below the started process' {
        Test-ProcessDescendant -ProcessId 8496 -AncestorId 4242 | Should -BeTrue
        Should -Invoke Get-CimInstance -ModuleName LocalAI -ParameterFilter { $ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=8496' }
    }

    It 'passes for the started process itself without asking Windows' {
        Test-ProcessDescendant -ProcessId 4242 -AncestorId 4242 | Should -BeTrue
        Should -Invoke Get-CimInstance -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails for a process outside the tree' {
        $tree[7000] = @{ Parent = 900; Created = $base.AddMinutes(5) }
        Test-ProcessDescendant -ProcessId 7000 -AncestorId 4242 | Should -BeFalse
    }

    It 'fails when a parent PID was reused by a process created after its child' {
        $tree[5000].Created = $base.AddHours(1)
        Test-ProcessDescendant -ProcessId 8496 -AncestorId 4242 | Should -BeFalse
    }

    It 'fails when a process on the way has exited' {
        $tree.Remove(5044)
        Test-ProcessDescendant -ProcessId 8496 -AncestorId 4242 | Should -BeFalse
    }

    It 'fails beyond MaxDepth parent steps' {
        Test-ProcessDescendant -ProcessId 8496 -AncestorId 4242 -MaxDepth 2 | Should -BeFalse
    }
}

Describe 'Start-LocalAIService' {
    BeforeAll {
        $names = @('HF_TOKEN', 'LOCALAI_TEST_TOKEN', 'LOCALAI_TEST_API_KEY', 'LOCALAI_KEPT_API_KEY', 'LOCALAI_TEST_NEW', 'LOCALAI_TEST_SET',
            'LOCALAI_TEST_CLEARED', 'PYTHONHOME', 'PYTHONPATH', 'PYTHONSTARTUP', 'PYTHONUSERBASE', 'NODE_OPTIONS', 'NODE_PATH', 'AWS_SECRET_ACCESS_KEY',
            'LOCALAI_PROBE_SECRET')
        $started = [datetime]::new(2026, 10, 27, 9, 30, 0, [DateTimeKind]::Local)
        $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'

        # Return this process's environment as sorted NAME=value lines.
        function Get-TestEnvironment {
            @([Environment]::GetEnvironmentVariables('Process').GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object)
        }
    }

    BeforeEach {
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $env:HF_TOKEN = 'hf-secret'
        $env:LOCALAI_TEST_TOKEN = 'token-secret'
        $env:LOCALAI_TEST_API_KEY = 'key-secret'
        $env:LOCALAI_KEPT_API_KEY = 'launcher-value'
        $env:LOCALAI_TEST_SET = 'before'
        $env:LOCALAI_TEST_CLEARED = 'inherited'
        $env:PYTHONHOME = 'C:\Python27'
        $env:PYTHONPATH = 'C:\dev\lib'
        $env:PYTHONSTARTUP = 'C:\dev\startup.py'
        $env:PYTHONUSERBASE = 'C:\dev\userbase'
        $env:NODE_OPTIONS = '--require C:\dev\preload.js'
        $env:NODE_PATH = 'C:\dev\node_modules'
        [Environment]::SetEnvironmentVariable('LOCALAI_TEST_NEW', $null, 'Process')

        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $service = @{
            Name             = 'OpenWebUI'
            Port             = 18431
            FilePath         = 'C:\Users\User\.local\bin\open-webui.exe'
            ArgumentList     = @('serve', '--host', '127.0.0.1', '--port', '18431', 'C:\My Data\')
            WorkingDirectory = Join-Path $folder 'data'
            Environment      = [ordered]@{ LOCALAI_TEST_NEW = 'new'; LOCALAI_TEST_SET = 'changed'; LOCALAI_TEST_CLEARED = ''; LOCALAI_KEPT_API_KEY = 'service-value'; PYTHONUSERBASE = 'C:\service\userbase' }
            OutLog           = Join-Path $folder 'logs\open-webui.log'
            ErrLog           = Join-Path $folder 'logs\open-webui.err.log'
        }
        $seen = @{}
        Mock Start-Process -ModuleName LocalAI -MockWith {
            $seen.Environment = [Environment]::GetEnvironmentVariables('Process')
            [pscustomobject]@{ Id = 4242; StartTime = $started; Path = $cmd; Handle = [IntPtr]::Zero; HasExited = $false }
        }
    }

    AfterEach {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }

    It 'starts cmd.exe hidden in the working directory, which runs the program with quoted arguments and both logs' {
        $null = Start-LocalAIService -Service $service
        $line = '/d /v:off /s /c ""C:\Users\User\.local\bin\open-webui.exe" "serve" "--host" "127.0.0.1" "--port" "18431" "C:\My Data\\" ' +
            "1>`"$($service.OutLog)`" 2>`"$($service.ErrLog)`"`""
        Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $cmd -and $WindowStyle -eq 'Hidden' -and [bool]$PassThru -and
            $WorkingDirectory -eq $service.WorkingDirectory -and ($ArgumentList -join ' ') -ceq $line
        }
        Test-Path -LiteralPath $service.WorkingDirectory -PathType Container | Should -BeTrue
    }

    It 'leaves out -Redirect* and -NoNewWindow, so ShellExecute hands the program no handle of this process' {
        $null = Start-LocalAIService -Service $service
        Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            -not ($PesterBoundParameters.ContainsKey('RedirectStandardOutput') -or $PesterBoundParameters.ContainsKey('RedirectStandardError') -or
                $PesterBoundParameters.ContainsKey('RedirectStandardInput') -or $PesterBoundParameters.ContainsKey('NoNewWindow'))
        }
    }

    It 'refuses <Part> holding <Char>, which cmd.exe would change' -ForEach @(
        @{ Part = 'a program path'; Char = '%'; Key = 'FilePath'; Value = 'C:\%USERNAME%\open-webui.exe' }
        @{ Part = 'an argument'; Char = 'a double quote'; Key = 'ArgumentList'; Value = @('serve', 'a"b') }
        @{ Part = 'a log path'; Char = '%'; Key = 'ErrLog'; Value = 'C:\logs\100%.log' }
    ) {
        $service[$Key] = $Value
        $before = Get-TestEnvironment
        { Start-LocalAIService -Service $service } | Should -Throw -ExpectedMessage '*contains a double quote, a percent sign or a line break*'
        Should -Invoke Start-Process -ModuleName LocalAI -Times 0 -Exactly
        Get-TestEnvironment | Should -Be $before
    }

    It 'gives the program its environment without inherited tokens, API keys or Python and Node.js code-path variables' {
        $null = Start-LocalAIService -Service $service
        $seen.Environment['LOCALAI_TEST_NEW'] | Should -BeExactly 'new'
        $seen.Environment['LOCALAI_TEST_SET'] | Should -BeExactly 'changed'
        $seen.Environment.ContainsKey('LOCALAI_TEST_CLEARED') | Should -BeFalse
        $seen.Environment['LOCALAI_KEPT_API_KEY'] | Should -BeExactly 'service-value'
        $seen.Environment['PYTHONUSERBASE'] | Should -BeExactly 'C:\service\userbase'
        foreach ($secret in 'HF_TOKEN', 'LOCALAI_TEST_TOKEN', 'LOCALAI_TEST_API_KEY', 'PYTHONHOME', 'PYTHONPATH', 'PYTHONSTARTUP', 'NODE_OPTIONS', 'NODE_PATH') {
            $seen.Environment.ContainsKey($secret) | Should -BeFalse -Because "$secret must not reach the service"
        }
    }

    It 'gives a service that lists InheritEnvironment only those variables, in any case, and its own, restoring this process afterwards' {
        $before = Get-TestEnvironment
        $service.InheritEnvironment = @('systemroot', 'PATH', 'LOCALAI_TEST_SET')
        $service.Environment = [ordered]@{ LOCALAI_TEST_NEW = 'new' }
        $null = Start-LocalAIService -Service $service
        # Empty variables, which a parent such as Git Bash can pass, stay: they hold nothing.
        $named = @($seen.Environment.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { ([string]$_.Key).ToUpperInvariant() } | Sort-Object)
        $named | Should -Be @('LOCALAI_TEST_NEW', 'LOCALAI_TEST_SET', 'PATH', 'SYSTEMROOT')
        $seen.Environment['LOCALAI_TEST_SET'] | Should -BeExactly 'before'
        Get-TestEnvironment | Should -Be $before
    }

    It 'drops an inherited token from a service that lists InheritEnvironment, also when the list names it' {
        $service.InheritEnvironment = @('SystemRoot', 'HF_TOKEN')
        $service.Environment = [ordered]@{}
        $null = Start-LocalAIService -Service $service
        # A shell such as Git Bash hands its programs these names in capitals.
        @($seen.Environment.Keys) -contains 'HF_TOKEN' | Should -BeFalse
        @($seen.Environment.Keys) -contains 'SystemRoot' | Should -BeTrue
    }

    # Not keyed Name: BeforeEach's foreach over $names sets $name, which is the same variable.
    It 'gives <Kind> the list Get-LocalAIService makes: Path, SystemRoot and its own variables, but no other secret such as AWS_SECRET_ACCESS_KEY' -ForEach @(
        @{ Kind = 'OpenWebUI' }
        @{ Kind = 'ComfyUI' }
        @{ Kind = 'ImageGate' }
    ) {
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\defaults.psd1')
        $settings.OpenWebUI.DataDir = Join-Path $folder 'data'
        $listed = @(Get-LocalAIService -Settings $settings -Paths (Get-LocalAIPaths -Root $folder) -OllamaUrl 'http://127.0.0.1:11434' `
                -OpenWebUI @{ Version = '0.12.4'; Path = 'C:\x\open-webui.exe' } -ComfyUI @{ Python = 'C:\x\python.exe'; Commit = 'x' } `
                -ImageWorkflow @{ Workflow = '{}'; Nodes = '[]' })
        $service.InheritEnvironment = @($listed | Where-Object { $_.Name -eq $Kind })[0].InheritEnvironment
        @($service.InheritEnvironment).Count | Should -BeGreaterThan 30
        $env:AWS_SECRET_ACCESS_KEY = 'aws-secret'
        $env:LOCALAI_PROBE_SECRET = 'probe-secret'
        $null = Start-LocalAIService -Service $service
        foreach ($secret in 'AWS_SECRET_ACCESS_KEY', 'LOCALAI_PROBE_SECRET', 'LOCALAI_TEST_CLEARED', 'HF_TOKEN', 'PYTHONPATH') {
            @($seen.Environment.Keys) -contains $secret | Should -BeFalse -Because "$secret must not reach $Kind"
        }
        @($seen.Environment.Keys) -contains 'Path' | Should -BeTrue
        @($seen.Environment.Keys) -contains 'SystemRoot' | Should -BeTrue
        $seen.Environment['LOCALAI_TEST_NEW'] | Should -BeExactly 'new'
        $env:AWS_SECRET_ACCESS_KEY | Should -BeExactly 'aws-secret'
    }

    It 'passes NODE_OPTIONS when the service sets it itself' {
        $service.Environment['NODE_OPTIONS'] = '--max-old-space-size=512'
        $null = Start-LocalAIService -Service $service
        $seen.Environment['NODE_OPTIONS'] | Should -BeExactly '--max-old-space-size=512'
        $env:NODE_OPTIONS | Should -BeExactly '--require C:\dev\preload.js'
    }

    It 'passes environment values with double quotes and percent signs unchanged, since they never reach the cmd.exe line' {
        $json = '{"6":{"inputs":{"text":"100%PATH% & \"quoted\"","clip":["4",1]},"class_type":"CLIPTextEncode"}}'
        $service.Environment['LOCALAI_TEST_NEW'] = $json
        $null = Start-LocalAIService -Service $service
        $seen.Environment['LOCALAI_TEST_NEW'] | Should -BeExactly $json
        Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -notlike '*PATH*' }
    }

    It 'leaves the environment of this process exactly as it was' {
        $before = Get-TestEnvironment
        $null = Start-LocalAIService -Service $service
        Get-TestEnvironment | Should -Be $before
        $env:LOCALAI_TEST_NEW | Should -BeNullOrEmpty
        $env:HF_TOKEN | Should -BeExactly 'hf-secret'
        $env:PYTHONHOME | Should -BeExactly 'C:\Python27'
    }

    It 'restores the environment when the start fails' {
        Mock Start-Process -ModuleName LocalAI -MockWith { throw 'This command cannot be run due to the error: The system cannot find the file specified.' }
        $before = Get-TestEnvironment
        { Start-LocalAIService -Service $service } | Should -Throw -ExpectedMessage '*cannot find the file*'
        Get-TestEnvironment | Should -Be $before
    }

    It 'rotates both logs before the start' {
        $null = Write-TestFile ((Split-Path $folder -Leaf) + '\logs\open-webui.log') 'old out'
        $null = Write-TestFile ((Split-Path $folder -Leaf) + '\logs\open-webui.err.log') 'old err'
        $null = Start-LocalAIService -Service $service -Keep 2
        Get-Content -LiteralPath "$($service.OutLog).1" | Should -Be 'old out'
        Get-Content -LiteralPath "$($service.ErrLog).1" | Should -Be 'old err'
        Test-Path -LiteralPath $service.OutLog | Should -BeFalse
    }

    It 'returns the PID, the UTC start ticks, the path, the port, both logs and the process' {
        $result = Start-LocalAIService -Service $service
        $result.Pid | Should -Be 4242
        $result.StartTicks | Should -Be $started.ToUniversalTime().Ticks
        $result.Path | Should -Be $cmd
        $result.Port | Should -Be 18431
        $result.OutLog | Should -Be $service.OutLog
        $result.ErrLog | Should -Be $service.ErrLog
        $result.Process.Id | Should -Be 4242
    }
}

Describe 'Wait-LocalAIService' {
    BeforeEach {
        Mock Start-Sleep -ModuleName LocalAI -MockWith { [Threading.Thread]::Sleep(20) }
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $answers = @{ Count = 0; SucceedAt = 3 }
        $service = @{
            DisplayName = 'Open WebUI'
            Url         = 'http://127.0.0.1:18431'
            HealthUrl   = 'http://127.0.0.1:18431/health'
            OutLog      = Join-Path $folder 'open-webui.log'
            ErrLog      = Join-Path $folder 'open-webui.err.log'
            Repair      = 'uv tool install --python 3.12 open-webui==0.12.4 --reinstall'
            Port        = 18431
            Identity    = {
                param([hashtable]$Service)
                $answers.Count++
                $answers.Asked = $Service.HealthUrl
                if ($answers.Count -lt $answers.SucceedAt) { throw "Unable to connect to the remote server at $($Service.Url)" }
                '0.12.4'
            }.GetNewClosure()
        }
        $process = [pscustomobject]@{ Id = 4242; HasExited = $false; ExitCode = $null }
        $python = [pscustomobject]@{ Id = 8496; Name = 'python'; Path = 'C:\uv\python\python.exe'; StartTicks = 222 }
        $foreign = [pscustomobject]@{ Id = 9100; Name = 'python'; Path = 'C:\old\python.exe'; StartTicks = 5 }
        $net = @{ Owner = $python }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { $net.Owner }
        Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $ProcessId -eq 8496 -and $AncestorId -eq 4242 }
    }

    It 'polls every 500 ms until the identity check answers, and returns the version and the listener' {
        $ready = Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 30
        $ready.Version | Should -Be '0.12.4'
        $ready.Listener.Id | Should -Be 8496
        $answers.Count | Should -Be 3
        # The identity check gets the whole entry, so it can compare more than the URL.
        $answers.Asked | Should -Be 'http://127.0.0.1:18431/health'
        Should -Invoke Start-Sleep -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $Milliseconds -eq 500 }
        Should -Invoke Test-ProcessDescendant -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 8496 -and $AncestorId -eq 4242 }
    }

    It 'keeps waiting while a program it did not start answers, and names it after the timeout' {
        $answers.SucceedAt = 1
        $net.Owner = $foreign
        { Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 1 } |
            Should -Throw -ExpectedMessage '*did not answer at*within 1 s (another program answered). Port 18431 is held by python (PID 9100, C:\old\python.exe), which this start did not launch.*'
        $answers.Count | Should -BeGreaterThan 1
    }

    It 'accepts the listener once it, not another program, holds the port' {
        $answers.SucceedAt = 1
        $net.Owner = $foreign
        Mock Start-Sleep -ModuleName LocalAI -MockWith { $net.Owner = $python }
        (Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 30).Listener.Id | Should -Be 8496
        Should -Invoke Start-Sleep -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'names the other program when the started process exits' {
        $answers.SucceedAt = 1
        $net.Owner = $foreign
        $exited = [pscustomobject]@{ Id = 4242; HasExited = $true; ExitCode = 1 }
        { Wait-LocalAIService -Service $service -Process $exited -TimeoutSeconds 30 6>$null } |
            Should -Throw -ExpectedMessage '*exited with code 1 before it answered*Port 18431 is held by python (PID 9100, C:\old\python.exe)*'
    }

    It 'fails at once when the process has exited, printing the last 30 lines of both logs and the repair hint' {
        $answers.SucceedAt = 1000
        $null = Write-TestFile ((Split-Path $folder -Leaf) + '\open-webui.err.log') ((1..40 | ForEach-Object { "err line $_" }) -join "`r`n")
        $null = Write-TestFile ((Split-Path $folder -Leaf) + '\open-webui.log') ((1..40 | ForEach-Object { "out line $_" }) -join "`r`n")
        $exited = [pscustomobject]@{ Id = 4242; HasExited = $true; ExitCode = 3 }
        $printed = New-Object System.Collections.ArrayList
        { Wait-LocalAIService -Service $service -Process $exited -TimeoutSeconds 30 6>&1 | ForEach-Object { $null = $printed.Add("$_") } } |
            Should -Throw -ExpectedMessage '*Open WebUI exited with code 3 before it answered at http://127.0.0.1:18431*open-webui.err.log*open-webui.log*'
        $printed | Should -Contain 'err line 40'
        $printed | Should -Contain 'err line 11'
        $printed | Should -Not -Contain 'err line 10'
        $printed | Should -Contain 'out line 40'
        $printed | Should -Not -Contain 'out line 10'
        ($printed -join "`n") | Should -BeLike '*uv tool install --python 3.12 open-webui==0.12.4 --reinstall*'
        Should -Invoke Start-Sleep -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'throws after the timeout naming the health URL, the reason and both logs' {
        $answers.SucceedAt = 100000
        { Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 1 } |
            Should -Throw -ExpectedMessage '*did not answer at http://127.0.0.1:18431/health within 1 s (Unable to connect*open-webui.err.log*open-webui.log*'
    }

    It 'keeps waiting while a foreign program answers on the port' {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Ports.OpenWebUI = 18431
        $real = @(Get-LocalAIService -Settings $settings -Paths (Get-LocalAIPaths -Root $folder) -OllamaUrl 'http://127.0.0.1:11434' -OpenWebUI @{ Version = '0.12.4'; Path = 'C:\x\open-webui.exe' })[0]
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/health' } -MockWith { [pscustomobject]@{ status = $true } }
        Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/api/version' } -MockWith { '<html>another app</html>' }
        { Wait-LocalAIService -Service $real -Process $process -TimeoutSeconds 1 } |
            Should -Throw -ExpectedMessage '*did not answer at http://127.0.0.1:18431/health within 1 s (*did not answer with a version*'
    }

    It 'does not ask while no program holds the port, and names that after the timeout' {
        $net.Owner = $null
        { Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 1 } |
            Should -Throw -ExpectedMessage '*did not answer at http://127.0.0.1:18431/health within 1 s (nothing listens on port 18431).*open-webui.err.log*'
        $answers.Count | Should -Be 0
        Should -Invoke Get-PortOwner -ModuleName LocalAI -ParameterFilter { $Port -eq 18431 }
    }

    It 'asks once a program holds the port' {
        $answers.SucceedAt = 1
        $net.Owner = $null
        Mock Start-Sleep -ModuleName LocalAI -MockWith { $net.Owner = $python }
        (Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 30).Version | Should -Be '0.12.4'
        $answers.Count | Should -Be 1
        Should -Invoke Start-Sleep -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'treats a refused connection as not ready' {
        $probe = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $probe.Start()
        $free = $probe.LocalEndpoint.Port
        $probe.Stop()
        # The module's own check, which a closed port refuses; Get-PortOwner still names a listener.
        $check = & (Get-Module LocalAI) { Get-Command -Name 'Get-OpenWebUIVersion' -CommandType Function }
        $service.Url = "http://127.0.0.1:$free"
        $service.HealthUrl = "http://127.0.0.1:$free/health"
        $service.Identity = { param([hashtable]$Service) & $check -Url $Service.Url }.GetNewClosure()
        { Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 1 } |
            Should -Throw -ExpectedMessage "*did not answer at http://127.0.0.1:$free/health within 1 s (Unable to connect*"
    }
}

Describe 'Wait-LocalAIService and Get-ListenerAddress in a transcript' {
    It 'leave no TerminatingError line for a loopback port nothing listens on' {
        $probe = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $probe.Start()
        $free = $probe.LocalEndpoint.Port
        $probe.Stop()
        $check = & (Get-Module LocalAI) { Get-Command -Name 'Get-OpenWebUIVersion' -CommandType Function }
        $service = @{
            DisplayName = 'Open WebUI'
            Url         = "http://127.0.0.1:$free"
            HealthUrl   = "http://127.0.0.1:$free/health"
            OutLog      = Join-Path $TestDrive 'open-webui.log'
            ErrLog      = Join-Path $TestDrive 'open-webui.err.log'
            Port        = $free
            Identity    = { param([hashtable]$Service) & $check -Url $Service.Url }.GetNewClosure()
        }
        $process = [pscustomobject]@{ Id = 4242; HasExited = $false; ExitCode = $null }
        $log = Join-Path $TestDrive 'transcript.log'
        try {
            $null = Start-Transcript -LiteralPath $log
        } catch {
            Set-ItResult -Skipped -Because "Start-Transcript cannot run in this host: $($_.Exception.Message)"
            return
        }
        $outcome = $null
        try {
            $addresses = @(Get-ListenerAddress -Port $free)
            try { $null = Wait-LocalAIService -Service $service -Process $process -TimeoutSeconds 1 } catch { $outcome = $_.Exception.Message }
        } finally {
            $null = Stop-Transcript
        }
        $addresses.Count | Should -Be 0
        $outcome | Should -BeLike "*within 1 s (nothing listens on port $free).*"
        # The timeout is thrown and caught here, so its own line is expected.
        @(Get-Content -LiteralPath $log | Where-Object { $_ -like '*TerminatingError*' -and $_ -notlike '*did not answer at*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-ComfyUIStartProblem' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $leaf = Split-Path $root -Leaf
        $dir = Join-Path $root 'ComfyUI'
        $python = Write-TestFile "$leaf\ComfyUI\.venv\Scripts\python.exe" 'program'
        $checkpoint = Write-TestFile "$leaf\ComfyUI\models\checkpoints\Test.safetensors" 'checkpoint bytes'
        $sha = (Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash.ToLowerInvariant()
        $file = Get-Item -LiteralPath $checkpoint
        $requirements = Write-TestFile "$leaf\ComfyUI\requirements.txt" "torch`n"
        Write-LocalAIState -Path (Join-Path $dir '.venv\local-ai-install.json') -State @{
            RequirementsSha256 = (Get-FileHash -LiteralPath $requirements -Algorithm SHA256).Hash.ToLowerInvariant() }
        $settings = @{ ComfyUI = @{ Dir = $dir }; Images = @{ File = 'Test.safetensors'; Size = $file.Length; Sha256 = $sha } }
        $stamp = @{ ComfyUI = @{ Dir = $dir; Python = $python }; Images = @{ File = 'Test.safetensors'; Sha256 = $sha } }
        $state = @{ Images = @{ VerifiedFiles = @{ $sha = @{ Length = $file.Length; WriteTicks = $file.LastWriteTimeUtc.Ticks } } } }
    }

    It 'finds no problem, and warns about nothing, when install set up what the settings name' {
        Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 0
    }

    It 'compares ComfyUI.Dir without case and without a trailing backslash' {
        $settings.ComfyUI.Dir = $dir.ToUpperInvariant() + '\'
        Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state | Should -BeNullOrEmpty
    }

    It 'names the problem when <Case>' -ForEach @(
        @{ Case = 'the stamp has no ComfyUI'; Change = 'no stamp'; Expected = "install-stamp.json names no ComfyUI python.exe that exists (''). Run 'local-ai install'*" }
        @{ Case = 'the venv python is gone'; Change = 'no python'; Expected = '*names no ComfyUI python.exe that exists*python.exe*' }
        @{ Case = 'the stamp has no Dir'; Change = 'no dir'; Expected = "install set up ComfyUI in '', but ComfyUI.Dir is '*ComfyUI'. Run 'local-ai install'*" }
        @{ Case = 'install did not finish the checkpoint'; Change = 'no images'; Expected = 'install has not checked Test.safetensors against Images.Sha256 yet*' }
        @{ Case = 'Images.Sha256 changed'; Change = 'other sha'; Expected = '*has not checked Test.safetensors*' }
        @{ Case = 'Images.File differs in case'; Change = 'lower file'; Expected = '*has not checked test.safetensors*' }
        @{ Case = 'the checkpoint is missing'; Change = 'no file'; Expected = '*Test.safetensors is missing or changed since install checked it*' }
        @{ Case = 'the checkpoint has another size'; Change = 'longer'; Expected = '*missing or changed*' }
        @{ Case = 'the checkpoint was written since the check'; Change = 'newer'; Expected = '*missing or changed*' }
        @{ Case = 'state.json has no record of the check'; Change = 'no record'; Expected = "*missing or changed since install checked it. Run 'local-ai install' to check it again*" }
    ) {
        switch ($Change) {
            'no stamp' { $stamp.Remove('ComfyUI') }
            'no python' { Remove-Item -LiteralPath $python }
            'no dir' { $stamp.ComfyUI.Remove('Dir') }
            'no images' { $stamp.Remove('Images') }
            'other sha' { $settings.Images.Sha256 = 'a' * 64 }
            'lower file' { $settings.Images.File = 'test.safetensors' }
            'no file' { Remove-Item -LiteralPath $checkpoint }
            'longer' { [IO.File]::AppendAllText($checkpoint, 'X') }
            'newer' { (Get-Item -LiteralPath $checkpoint).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(1) }
            'no record' { $state.Remove('Images') }
        }
        Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state | Should -BeLike $Expected
    }

    It 'checks only the size when Images.Sha256 is empty' {
        $settings.Images.Sha256 = ''
        $stamp.Images.Sha256 = ''
        $state.Remove('Images')
        Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state | Should -BeNullOrEmpty
    }

    It 'warns, finding no problem, when <Case>' -ForEach @(
        @{ Case = 'requirements.txt changed since the venv marker was written' }
        @{ Case = 'the venv has no marker' }
    ) {
        if ($Case -like 'requirements*') { [IO.File]::AppendAllText($requirements, "blake3`n") } else { Remove-Item -LiteralPath (Join-Path $dir '.venv\local-ai-install.json') }
        Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*requirements.txt is not the one ComfyUI's venv was set up for*"
    }

    It 'warns, naming update and finding no problem, when the venv runs on the Microsoft Store Python, but not when it runs on another' {
        Write-TestPyVenvConfig -Venv (Join-Path $dir '.venv') -BaseHome $storeHome -Version '3.13.14'
        Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeExactly ("ComfyUI's venv runs on the Microsoft Store Python 3.13.14, whose launches can fail or hang until Windows restarts, and " +
            "ComfyUI and the image gate with them. Run 'local-ai update', which makes the venv anew on a uv-managed Python.")
        Write-TestPyVenvConfig -Venv (Join-Path $dir '.venv') -BaseHome 'C:\Users\User\AppData\Roaming\uv\python\cpython-3.13-windows-x86_64-none' -Version '3.13'
        Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 0
    }
}

Describe 'Start-LocalAI' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $python = [pscustomobject]@{ Id = 1624; Name = 'python'; Path = 'C:\uv\python\python.exe'; StartTicks = 222 }

        # Run Start-LocalAI and return @{ Code; Printed; Warnings } with host text and warnings joined.
        function Invoke-StartVerb([hashtable]$Context) {
            $output = @(Start-LocalAI -Context $Context 3>&1 6>&1)
            return @{
                Code     = @($output | Where-Object { $_ -is [int] })
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
            }
        }

        # Leave what install sets up for the file tools: a served folder beside Paths.Root holding one file, the programs and script
        # the stamp names, files.key, and the Files entry, added to $Complete and saved. Sets Files.Root and Ports.Files; returns @{ Root; Key }.
        function Initialize-TestFileTool([hashtable]$Settings, [hashtable]$Paths, [hashtable]$Complete) {
            $leaf = Split-Path $Paths.Root -Leaf
            $served = Join-Path $TestDrive "$leaf-files"
            $null = Write-TestFile "$leaf-files\notes.txt" 'notes'
            $Settings.Files.Root = $served
            $Settings.Ports.Files = 18189
            $lock = Join-Path $repoRoot 'config\files-server\package-lock.json'
            $Complete.Files = @{
                McpoVersion = '0.0.20'; McpoPath = (Write-TestFile "$leaf\bin\mcpo.exe" 'program'); Python = '3.12'; With = @($Settings.Files.McpoWith)
                ExcludeNewer = $Settings.Files.McpoExcludeNewer; ServerVersion = '2.0.1'
                LockSha256 = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant()
                Script = (Write-TestFile "$leaf\files-server\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js" 'script')
                Node = @{ Path = (Write-TestFile "$leaf\nodejs\node.exe" 'program'); Version = '24.22.1' }
            }
            Write-LocalAIState -Path $Paths.InstallStamp -State $Complete
            return @{ Root = $served; Key = (Get-FilesKey -Path $Paths.FilesKey -Create) }
        }

        # Return the hash of the Open WebUI environment and inherited names a start computes for $Settings and $Paths with images and file
        # tools off, as Use-LocalAIService records it; -EnvironmentOnly leaves the names out, as the launcher before InheritEnvironment did.
        function Get-TestWebEnvironmentHash([hashtable]$Settings, [hashtable]$Paths, [hashtable]$OpenWebUI, [switch]$EnvironmentOnly) {
            & (Get-Module LocalAI) {
                param($Settings, $Paths, $OpenWebUI, $EnvironmentOnly)
                $web = @(Get-LocalAIService -Settings $Settings -Paths $Paths -OllamaUrl 'http://127.0.0.1:11434' -OpenWebUI $OpenWebUI | Where-Object { $_.Name -eq 'OpenWebUI' })[0]
                $names = if ($EnvironmentOnly) { $null } else { $web.InheritEnvironment }
                Get-LocalAIEnvironmentHash -Environment $web.Environment -InheritEnvironment $names
            } $Settings $Paths $OpenWebUI ([bool]$EnvironmentOnly)
        }

        # Return the hash of ComfyUI's environment and inherited names a start computes for $Settings and $Paths from the stamp $Stamp, as
        # Use-LocalAIService records it.
        function Get-TestComfyUIHash([hashtable]$Settings, [hashtable]$Paths, [hashtable]$Stamp) {
            & (Get-Module LocalAI) {
                param($Settings, $Paths, $Stamp)
                $comfy = @(Get-LocalAIServicePlan -Settings $Settings -Paths $Paths -Stamp $Stamp -OllamaUrl 'http://127.0.0.1:11434' | Where-Object { $_.Name -eq 'ComfyUI' })[0]
                Get-LocalAIEnvironmentHash -Environment $comfy.Environment -InheritEnvironment $comfy.InheritEnvironment
            } $Settings $Paths $Stamp
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $settings.Ports.OpenWebUI = 18431
        $settings.OpenWebUI.DataDir = Join-Path $root 'open-webui'
        # Open WebUI alone; the 'with images' context turns ComfyUI on.
        $settings.Images.Enabled = $false
        $exe = Write-TestFile ((Split-Path $root -Leaf) + '\bin\open-webui.exe') 'program'
        $context = @{ Verb = 'start'; Paths = $paths; Settings = $settings; RepoRoot = $repoRoot; NoBrowser = $false }
        $complete = @{
            Ollama    = @{ Version = '0.40.11' }
            Model     = @{ Alias = 'local-chat' }
            OpenWebUI = @{ Version = '0.12.4'; Path = $exe; Python = '3.12.10' }
        }
        Write-LocalAIState -Path $paths.InstallStamp -State $complete
        $net = @{ Owner = $null; Version = '0.12.4' }
        $seen = @{}

        Mock Update-SessionPath -ModuleName LocalAI
        Mock Resolve-OllamaUrl -ModuleName LocalAI -MockWith { 'http://127.0.0.1:11434' }
        Mock Install-LocalAI -ModuleName LocalAI -MockWith { 0 }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { if ($PassThru) { [pscustomobject]@{ Version = '0.40.11'; App = $null } } else { '0.40.11' } }
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $true }
        Mock Test-LoopbackListener -ModuleName LocalAI -MockWith { $true }
        Mock Get-OllamaModelBlob -ModuleName LocalAI -MockWith { [pscustomobject]@{ Digest = 'a' * 64; Path = 'C:\models\blobs\a' } }
        Mock Get-PortOwner -ModuleName LocalAI -MockWith { $net.Owner }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'other' }
        Mock Start-LocalAIService -ModuleName LocalAI -MockWith {
            @{ Pid = 4242; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = $Service.Port; OutLog = $Service.OutLog; ErrLog = $Service.ErrLog
                Process = [pscustomobject]@{ Id = 4242; HasExited = $false } }
        }
        Mock Wait-LocalAIService -ModuleName LocalAI -MockWith {
            $seen.State = Read-LocalAIState -Path $paths.State
            $net.Owner = $python
            @{ Version = $net.Version; Listener = $python }
        }
        Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'stopped' }
        Mock Start-Process -ModuleName LocalAI
    }

    It 'starts Open WebUI, records it before waiting, opens the browser, prints the endpoints and returns 0' {
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(0)
        Should -Invoke Install-LocalAI -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Service.Name -eq 'OpenWebUI' -and $Service.Port -eq 18431 -and $Service.FilePath -eq $exe -and $Keep -eq 5
        }
        Should -Invoke Wait-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Process.Id -eq 4242 -and $TimeoutSeconds -eq 600 }
        $seen.State.Services.OpenWebUI.Pid | Should -Be 4242
        $state = Read-LocalAIState -Path $paths.State
        $state.Services.OpenWebUI.StartTicks | Should -Be 111
        $state.Services.OpenWebUI.Port | Should -Be 18431
        $state.Services.OpenWebUI.ContainsKey('Process') | Should -BeFalse
        $state.Services.OpenWebUI.Listener.Pid | Should -Be 1624
        $state.Services.OpenWebUI.Listener.Path | Should -Be 'C:\uv\python\python.exe'
        $state.Services.OpenWebUI.EnvironmentSha256 | Should -BeExactly (Get-TestWebEnvironmentHash -Settings $settings -Paths $paths -OpenWebUI $complete.OpenWebUI)
        $state.Ollama.Url | Should -Be 'http://127.0.0.1:11434'
        $state.Ollama.Alias | Should -Be 'local-chat'
        Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Port -eq 18431 -and $Name -eq 'Open WebUI' }
        Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'http://127.0.0.1:18431' }
        $run.Printed | Should -BeLike '*Web UI:*http://127.0.0.1:18431*'
        $run.Printed | Should -BeLike '*http://127.0.0.1:11434/v1*model local-chat*'
    }

    It 'does not open the browser with -NoBrowser' {
        $context.NoBrowser = $true
        (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
        Should -Invoke Start-Process -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'runs install first when install-stamp.json lacks <Missing>, without repeating its Ollama checks' -ForEach @(
        @{ Missing = 'Ollama' }
        @{ Missing = 'Model' }
        @{ Missing = 'OpenWebUI' }
    ) {
        $partial = @{}
        foreach ($key in $complete.Keys) { if ($key -ne $Missing) { $partial[$key] = $complete[$key] } }
        Write-LocalAIState -Path $paths.InstallStamp -State $partial
        Mock Install-LocalAI -ModuleName LocalAI -MockWith {
            Write-LocalAIState -Path $Context.Paths.InstallStamp -State $complete
            0
        }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*does not record $Missing, so install runs first*"
        Should -Invoke Install-LocalAI -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Name -eq 'Ollama' }
    }

    It 'counts the warnings of the install it runs and adds no drift warning of its own' {
        Write-LocalAIState -Path $paths.InstallStamp -State @{ Ollama = $complete.Ollama; Model = $complete.Model }
        $complete.OpenWebUI.Version = '0.12.3'
        $net.Version = '0.12.3'
        Mock Install-LocalAI -ModuleName LocalAI -MockWith {
            Write-Warning 'Open WebUI 0.12.3 is installed, but OpenWebUI.Version pins 0.12.4.'
            Write-LocalAIState -Path $Context.Paths.InstallStamp -State $complete
            2
        }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(2)
        @($run.Warnings -split "`n" | Where-Object { $_ -like '*pins 0.12.4*' }).Count | Should -Be 1
    }

    It 'checks Ollama and its bind address when install does not run' {
        $null = Invoke-StartVerb -Context $context
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Url -eq 'http://127.0.0.1:11434' -and $PassThru -and $How -eq 'start' }
        Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'Ollama' -and $Port -eq 11434 }
    }

    It 'records the Ollama app its wait started before a later step can throw' {
        $app = @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; StartedTicks = 110; How = 'start' }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.11'; App = $app } }
        Mock Get-OllamaModelBlob -ModuleName LocalAI
        { Start-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage "*has no model 'local-chat'*"
        $ollama = (Read-LocalAIState -Path $paths.State).Ollama
        $ollama.App.Pid | Should -Be 100
        $ollama.App.How | Should -Be 'start'
        $ollama.Url | Should -Be 'http://127.0.0.1:11434'
        $ollama.Alias | Should -Be 'local-chat'
    }

    It 'keeps the app an earlier start recorded <Case>' -ForEach @(
        @{ Case = 'while it runs as recorded'; Found = 'match'; Port = 11434; New = $false; Expected = 90 }
        @{ Case = 'while it runs where this window may not inspect it'; Found = 'unreadable'; Port = 11434; New = $false; Expected = 90 }
        @{ Case = 'only while it runs, dropping it once it does not'; Found = 'other'; Port = 11434; New = $false; Expected = $null }
        @{ Case = 'only while it serves the port of Ollama.Url, whose models stop checks'; Found = 'match'; Port = 11500; New = $false; Expected = $null }
        @{ Case = 'unless its wait started a new one, which wins'; Found = 'match'; Port = 11434; New = $true; Expected = 100 }
    ) {
        $earlier = @{ Pid = 90; StartTicks = 9; Path = 'C:\Ollama\ollama app.exe'; Port = $Port; How = 'start' }
        Write-LocalAIState -Path $paths.State -State @{ Services = @{}; Ollama = @{ Url = "http://127.0.0.1:$Port"; Alias = 'local-chat'; App = $earlier } }
        $app = if ($New) { @{ Pid = 100; StartTicks = 111; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; How = 'start' } } else { $null }
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith { [pscustomobject]@{ Version = '0.40.11'; App = $app } }
        Mock Get-RecordedProcessState -ModuleName LocalAI -ParameterFilter { [int]$Record.Pid -eq 90 } -MockWith { $Found }
        Mock Get-RecordedProcessState -ModuleName LocalAI -ParameterFilter { [int]$Record.Pid -eq 100 } -MockWith { 'match' }
        (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
        $state = Read-LocalAIState -Path $paths.State
        if ($null -eq $Expected) { $state.Ollama.App | Should -BeNullOrEmpty } else { $state.Ollama.App.Pid | Should -Be $Expected }
        $state.Ollama.Url | Should -Be 'http://127.0.0.1:11434'
        $state.Services.OpenWebUI.Pid | Should -Be 4242
    }

    It 'drops the app an earlier start recorded once Ollama.Url names another computer, even on the same port' {
        # 192.0.2.20 stands for another computer, which the Ollama app on this PC never serves.
        Mock Resolve-OllamaUrl -ModuleName LocalAI -MockWith { 'http://192.0.2.20:11434' }
        Mock Test-LocalHostName -ModuleName LocalAI -MockWith { $HostName -ne '192.0.2.20' }
        $earlier = @{ Pid = 90; StartTicks = 9; Path = 'C:\Ollama\ollama app.exe'; Port = 11434; How = 'start' }
        Write-LocalAIState -Path $paths.State -State @{ Services = @{}; Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat'; App = $earlier } }
        Mock Get-RecordedProcessState -ModuleName LocalAI -ParameterFilter { [int]$Record.Pid -eq 90 } -MockWith { 'match' }
        (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
        $ollama = (Read-LocalAIState -Path $paths.State).Ollama
        $ollama.App | Should -BeNullOrEmpty
        $ollama.Url | Should -Be 'http://192.0.2.20:11434'
        Should -Invoke Test-LocalHostName -ModuleName LocalAI -ParameterFilter { $HostName -eq '192.0.2.20' }
    }

    It 'keeps the app the install it runs first recorded' {
        Write-LocalAIState -Path $paths.InstallStamp -State @{ Ollama = $complete.Ollama; Model = $complete.Model }
        Mock Install-LocalAI -ModuleName LocalAI -MockWith {
            Write-LocalAIState -Path $Context.Paths.InstallStamp -State $complete
            Write-LocalAIState -Path $Context.Paths.State -State @{
                Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat'; App = @{ Pid = 300; StartTicks = 3; Path = 'C:\x'; Port = 11434; How = 'install' } }
            }
            0
        }
        Mock Get-RecordedProcessState -ModuleName LocalAI -ParameterFilter { [int]$Record.Pid -eq 300 } -MockWith { 'match' }
        (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
        (Read-LocalAIState -Path $paths.State).Ollama.App.Pid | Should -Be 300
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'leaves the recorded Url and Alias for stop until the model check passes, when Ollama answered without a start' {
        # An earlier start ran the stack with the alias settings.psd1 named then; stop must still unload that one.
        Write-LocalAIState -Path $paths.State -State @{ Services = @{}; Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'old-chat'; App = $null } }
        Mock Get-OllamaModelBlob -ModuleName LocalAI
        { Start-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage "*has no model 'local-chat'*"
        $ollama = (Read-LocalAIState -Path $paths.State).Ollama
        $ollama.Alias | Should -Be 'old-chat'
        $ollama.App | Should -BeNullOrEmpty
    }

    It 'stops before anything when Ollama.Url and the ollama program name different servers' {
        Mock Resolve-OllamaUrl -ModuleName LocalAI -ParameterFilter { $PesterBoundParameters.ContainsKey('UserHost') } -MockWith { 'http://127.0.0.1:11434' }
        Mock Resolve-OllamaUrl -ModuleName LocalAI -ParameterFilter { -not $PesterBoundParameters.ContainsKey('UserHost') } -MockWith { 'http://127.0.0.1:11500' }
        { Start-LocalAI -Context $context 6>$null } |
            Should -Throw -ExpectedMessage '*Ollama at http://127.0.0.1:11500, but the ollama program would use http://127.0.0.1:11434*'
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Get-OllamaModelBlob -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Install-LocalAI -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'stops before starting anything when the stamp names no open-webui.exe that exists' {
        $complete.OpenWebUI.Path = Join-Path $root 'bin\missing.exe'
        Write-LocalAIState -Path $paths.InstallStamp -State $complete
        { Start-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage "*names no open-webui.exe that exists*missing.exe*Run 'local-ai install'*"
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'stops before starting anything when Ollama has no Model.Alias model' {
        Mock Get-OllamaModelBlob -ModuleName LocalAI
        { Start-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage "*has no model 'local-chat'. Run 'local-ai install'*"
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'warns once and returns 2 when the running Open WebUI differs from the pin' {
        $complete.OpenWebUI.Version = '0.12.3'
        Write-LocalAIState -Path $paths.InstallStamp -State $complete
        $net.Version = '0.12.3'
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*Open WebUI 0.12.3 runs, but OpenWebUI.Version pins 0.12.4*'local-ai update'*"
        $run.Warnings | Should -Not -BeLike '*install-stamp.json*'
        @($run.Warnings -split "`n" | Where-Object { $_ -like '*pins 0.12.4*' }).Count | Should -Be 1
        Should -Invoke Install-LocalAI -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'says the stamp is out of date when the running version differs from it and from the pin' {
        $net.Version = '0.12.2'
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike "*Open WebUI 0.12.2 runs, but OpenWebUI.Version pins 0.12.4*install-stamp.json records 0.12.4 instead*"
    }

    It 'does not warn when the running version is the pin, whatever the stamp records' {
        $complete.OpenWebUI.Version = '0.12.3'
        Write-LocalAIState -Path $paths.InstallStamp -State $complete
        (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
    }

    It 'reuses Open WebUI when the process state records holds the port and answers, started with the environment this start computes' {
        $record = @{ Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431; Listener = @{ Pid = 1624; StartTicks = 222; Path = 'C:\uv\python\python.exe' }
            EnvironmentSha256 = (Get-TestWebEnvironmentHash -Settings $settings -Paths $paths -OpenWebUI $complete.OpenWebUI) }
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = $record } }
        $net.Owner = $python
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'match' }
        Mock Get-OpenWebUIVersion -ModuleName LocalAI -MockWith { '0.12.4' }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeNullOrEmpty
        $run.Printed | Should -BeLike '*Open WebUI 0.12.4 is already running at http://127.0.0.1:18431; reusing it.*'
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Get-OpenWebUIVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Url -eq 'http://127.0.0.1:18431' }
        (Read-LocalAIState -Path $paths.State).Services.OpenWebUI.Pid | Should -Be 4242
    }

    It 'warns once and returns 2 when the Open WebUI it reuses was started <Case>' -ForEach @(
        @{ Case = 'with another environment'; Hash = ('0' * 64) }
        @{ Case = 'by a launcher that recorded no environment'; Hash = $null }
        @{ Case = 'with this environment by a launcher that recorded no inherited names'; Hash = 'environment only' }
        @{ Case = 'before OpenWebUI.InheritEnvironment named HTTPS_PROXY'; Hash = 'before the list' }
    ) {
        $record = @{ Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431; Listener = @{ Pid = 1624; StartTicks = 222; Path = 'C:\uv\python\python.exe' } }
        if ($Hash -eq 'environment only') { $Hash = Get-TestWebEnvironmentHash -Settings $settings -Paths $paths -OpenWebUI $complete.OpenWebUI -EnvironmentOnly }
        if ($Hash -eq 'before the list') {
            $Hash = Get-TestWebEnvironmentHash -Settings $settings -Paths $paths -OpenWebUI $complete.OpenWebUI
            $settings.OpenWebUI.InheritEnvironment = @('HTTPS_PROXY')
        }
        if ($Hash) { $record.EnvironmentSha256 = $Hash }
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = $record } }
        $net.Owner = $python
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'match' }
        Mock Get-OpenWebUIVersion -ModuleName LocalAI -MockWith { '0.12.4' }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeExactly ("Open WebUI, which an earlier start left running, keeps the settings it started with, which differ from this start's, " +
            "such as where images go, which file tools it offers and which variables of this window it inherits. Run 'local-ai stop', then start again.")
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails naming the program that holds the port, starting and stopping nothing' {
        $net.Owner = [pscustomobject]@{ Id = 9100; Name = 'nginx'; Path = 'C:\nginx\nginx.exe'; StartTicks = 5 }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Port 18431, which Open WebUI needs, is held by nginx (PID 9100, C:\nginx\nginx.exe)*'
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-Process -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails when the recorded process holds the port but does not answer as Open WebUI' {
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = @{ Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431; Listener = @{ Pid = 1624; StartTicks = 222; Path = 'C:\uv\python\python.exe' } } } }
        $net.Owner = $python
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'match' }
        Mock Get-OpenWebUIVersion -ModuleName LocalAI -MockWith { throw 'GET http://127.0.0.1:18431/health did not answer {"status": true}, so it is not Open WebUI.' }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*does not answer as Open WebUI*Run 'local-ai stop'*"
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'replaces a stale record with the process it starts' {
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = @{ Pid = 7; StartTicks = 1; Path = $exe; Port = 18431 } } }
        (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
        (Read-LocalAIState -Path $paths.State).Services.OpenWebUI.Pid | Should -Be 4242
    }

    It 'returns 1 and stops what it started when Open WebUI exits before it answers' {
        Mock Wait-LocalAIService -ModuleName LocalAI -MockWith { throw 'Open WebUI exited with code 1 before it answered at http://127.0.0.1:18431.' }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Open WebUI exited with code 1 before it answered*'
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'OpenWebUI' -and $Record.Pid -eq 4242 }
        (Read-LocalAIState -Path $paths.State).Services.ContainsKey('OpenWebUI') | Should -BeFalse
        Should -Invoke Start-Process -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'returns 2 when the Open WebUI listener is not loopback only' {
        Mock Test-LoopbackListener -ModuleName LocalAI -ParameterFilter { $Name -eq 'Open WebUI' } -MockWith { Write-Warning 'Open WebUI IS OPEN TO THE NETWORK'; $false }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeLike '*Open WebUI IS OPEN TO THE NETWORK*'
    }

    It 'still stops what it started when saving its record fails' {
        # Every other save goes to the module's own function.
        $realSave = & (Get-Module LocalAI) { Get-Command -Name 'Write-LocalAIState' -CommandType Function }
        Mock Write-LocalAIState -ModuleName LocalAI -MockWith { & $realSave -Path $Path -State $State }
        Mock Write-LocalAIState -ModuleName LocalAI -ParameterFilter { $State.Services -is [hashtable] -and $State.Services.ContainsKey('OpenWebUI') } -MockWith {
            throw "Cannot save state file '$Path': The disk is full."
        }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*The disk is full*'
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'OpenWebUI' -and $Record.Pid -eq 4242 }
        Should -Invoke Wait-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails without starting a second copy when the recorded process runs but does not hold the port' {
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = @{ Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431 } } }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'match' }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*left running (PID 4242) does not listen on port 18431. Run 'local-ai stop'*"
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'fails without starting a second copy when the recorded process cannot be inspected' {
        Write-LocalAIState -Path $paths.State -State @{ Services = @{ OpenWebUI = @{ Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431 } } }
        Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { 'unreadable' }
        $net.Owner = [pscustomobject]@{ Id = 1624; Name = 'python'; Path = $null; StartTicks = $null }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*(PID 4242) cannot be inspected from this window*Run 'local-ai stop' from an elevated window*"
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        (Read-LocalAIState -Path $paths.State).Services.OpenWebUI.Pid | Should -Be 4242
    }

    It 'records no listener and stops only its own process when another Open WebUI took the port' {
        $old =[pscustomobject]@{ Id = 9100; Name = 'python'; Path = 'C:\old\python.exe'; StartTicks = 5 }
        Mock Wait-LocalAIService -ModuleName LocalAI -MockWith {
            throw 'Open WebUI did not answer at http://127.0.0.1:18431/health within 1 s (another program answered). Port 18431 is held by python (PID 9100, C:\old\python.exe), which this start did not launch.'
        }
        $net.Owner = $null
        Mock Start-LocalAIService -ModuleName LocalAI -MockWith {
            $net.Owner = $old
            @{ Pid = 4242; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = $Service.Port; OutLog = $Service.OutLog; ErrLog = $Service.ErrLog
                Process = [pscustomobject]@{ Id = 4242; HasExited = $false } }
        }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*held by python (PID 9100, C:\old\python.exe), which this start did not launch*'
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Record.Pid -eq 4242 -and -not $Record.ContainsKey('Listener') }
        (Read-LocalAIState -Path $paths.State).Services.ContainsKey('OpenWebUI') | Should -BeFalse
    }

    It 'runs the real wait to the same end when another Open WebUI answers on the port' {
        $settings.OpenWebUI.HealthTimeoutSeconds = 1
        # The module's own function, which the mock below hands every call to.
        $realWait = & (Get-Module LocalAI) { Get-Command -Name 'Wait-LocalAIService' -CommandType Function }
        Mock Wait-LocalAIService -ModuleName LocalAI -MockWith { & $realWait -Service $Service -Process $Process -TimeoutSeconds $TimeoutSeconds }
        Mock Get-OpenWebUIVersion -ModuleName LocalAI -MockWith { '0.12.4' }
        Mock Test-ProcessDescendant -ModuleName LocalAI -MockWith { $false }
        Mock Start-Sleep -ModuleName LocalAI -MockWith { [Threading.Thread]::Sleep(20) }
        $net.Owner = $null
        Mock Start-LocalAIService -ModuleName LocalAI -MockWith {
            $net.Owner = [pscustomobject]@{ Id = 9100; Name = 'python'; Path = 'C:\old\python.exe'; StartTicks = 5 }
            @{ Pid = 4242; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = $Service.Port; OutLog = $Service.OutLog; ErrLog = $Service.ErrLog
                Process = [pscustomobject]@{ Id = 4242; HasExited = $false } }
        }
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*held by python (PID 9100, C:\old\python.exe), which this start did not launch*'
        Should -Invoke Test-ProcessDescendant -ModuleName LocalAI -ParameterFilter { $ProcessId -eq 9100 -and $AncestorId -eq 4242 }
        Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Record.Pid -eq 4242 -and -not $Record.ContainsKey('Listener') }
    }

    It 'neither starts ComfyUI nor checks its stamp while Images.Enabled is off' {
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeNullOrEmpty
        $run.Printed | Should -Not -BeLike '*Images:*'
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'ComfyUI' }
    }

    It 'starts no mcpo, checks nothing for it and registers no tool server while Files.Root is empty' {
        Mock Get-FilesStartProblem -ModuleName LocalAI
        $run = Invoke-StartVerb -Context $context
        $run.Code | Should -Be @(0)
        Should -Invoke Get-FilesStartProblem -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Service.Name -eq 'OpenWebUI' -and $Service.Environment['TOOL_SERVER_CONNECTIONS'] -eq '[]'
        }
        Test-Path -LiteralPath $paths.McpoConfig | Should -BeFalse
    }

    Context 'with the file tools' {
        BeforeEach {
            $tool = Initialize-TestFileTool -Settings $settings -Paths $paths -Complete $complete
            $mcpoListener = [pscustomobject]@{ Id = 7950; Name = 'python'; Path = 'C:\uv\python\cpython-3.12\python.exe'; StartTicks = 555 }
            $owners = @{}
            $pids = @{ Files = 4500; OpenWebUI = 4242 }
            $events = New-Object System.Collections.Generic.List[string]
            $ollama = @{ Capabilities = @('completion', 'tools', 'thinking') }
            Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/api/show' } -MockWith { [pscustomobject]@{ capabilities = $ollama.Capabilities } }
            Mock Get-PortOwner -ModuleName LocalAI -MockWith { $owners[[int]$Port] }
            Mock Start-LocalAIService -ModuleName LocalAI -MockWith {
                $events.Add("start $($Service.Name)")
                $id = $pids[$Service.Name]
                @{ Pid = $id; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = $Service.Port; OutLog = $Service.OutLog; ErrLog = $Service.ErrLog
                    Process = [pscustomobject]@{ Id = $id; HasExited = $false } }
            }
            Mock Wait-LocalAIService -ModuleName LocalAI -MockWith {
                $events.Add("wait $($Service.Name)")
                if ($Service.Name -eq 'Files') { $owners[18189] = $mcpoListener; return @{ Version = '2.0.1'; Listener = $mcpoListener } }
                $owners[18431] = $python
                @{ Version = '0.12.4'; Listener = $python }
            }
        }

        It 'starts mcpo and waits for it before Open WebUI, which gets the file tools, writes mcpo.json and returns 0' {
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Warnings | Should -BeNullOrEmpty
            $events | Should -Be @('start Files', 'wait Files', 'start OpenWebUI', 'wait OpenWebUI')
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'Files' -and $Service.FilePath -eq $complete.Files.McpoPath -and ($Service.ArgumentList -join ' ') -like "*--api-key $($tool.Key) --strict-auth *" -and
                ($Service.ArgumentList -join ' ') -like "*--config $($paths.McpoConfig) *"
            }
            Should -Invoke Wait-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Service.Name -eq 'Files' -and $TimeoutSeconds -eq 20 }
            Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Port -eq 18189 -and $Name -eq 'File tools' }
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['TOOL_SERVER_CONNECTIONS'] -like "*`"url`":`"http://127.0.0.1:18189/files`"*`"key`":`"$($tool.Key)`"*" -and
                $Service.Environment['DEFAULT_MODEL_METADATA'] -like '*"toolIds":`["server:files"`]*'
            }
            $config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($paths.McpoConfig))
            @($config.mcpServers.files.args) | Should -Be @($complete.Files.Script, $tool.Root)
            $config.mcpServers.files.command | Should -Be $complete.Files.Node.Path
            $state = Read-LocalAIState -Path $paths.State
            $state.Services.Files.Pid | Should -Be 4500
            $state.Services.Files.Listener.Pid | Should -Be 7950
            $run.Printed | Should -BeLike "*File tools:     $($tool.Root), read-only, through mcpo at http://127.0.0.1:18189*"
        }

        It 'never prints the mcpo key, also when mcpo fails' {
            $run = Invoke-StartVerb -Context $context
            "$($run.Printed)`n$($run.Warnings)" | Should -Not -BeLike "*$($tool.Key)*"
            Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'Files' } -MockWith { throw 'File tools exited with code 1 before it answered at http://127.0.0.1:18189.' }
            Write-LocalAIState -Path $paths.State -State @{}
            $owners.Clear()
            $run = Invoke-StartVerb -Context $context
            "$($run.Printed)`n$($run.Warnings)" | Should -Not -BeLike "*$($tool.Key)*"
        }

        It 'starts Open WebUI without the file tools, with one warning, stops the mcpo it started and returns 2 when mcpo <Case>' -ForEach @(
            @{ Case = 'exits before it answers'; Message = 'File tools exited with code 1 before it answered at http://127.0.0.1:18189.' }
            @{ Case = 'serves no routes'; Message = "File tools did not answer at http://127.0.0.1:18189/files/openapi.json within 60 s (mcpo at http://127.0.0.1:18189 serves the routes '', not '/get_file_info, /list_allowed_directories, /list_directory, /read_text_file, /search_files'; without any, its node server did not start.)." }
        ) {
            Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'Files' } -MockWith { $events.Add('wait Files'); throw $Message }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            @($run.Warnings -split "`n").Count | Should -Be 1
            $run.Warnings | Should -BeExactly "The file tools are off for this start: $Message"
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'Files' -and $Record.Pid -eq 4500 }
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['TOOL_SERVER_CONNECTIONS'] -eq '[]' -and $Service.Environment['DEFAULT_MODEL_METADATA'] -notlike '*toolIds*'
            }
            $events | Should -Be @('start Files', 'wait Files', 'start OpenWebUI', 'wait OpenWebUI')
            (Read-LocalAIState -Path $paths.State).Services.ContainsKey('Files') | Should -BeFalse
            $run.Printed | Should -Not -BeLike '*File tools:*'
        }

        It 'starts no mcpo, warns once and registers no tool server when <Case>' -ForEach @(
            @{ Case = 'install did not set the file tools up'; Change = 'stamp'; Expected = "The file tools are off for this start: install-stamp.json does not record them. Run 'local-ai install'*" }
            @{ Case = 'local-chat lacks the tools capability'; Change = 'tools'; Expected = "The file tools are off for this start: Ollama does not report the 'tools' capability for local-chat*" }
            @{ Case = 'files.key is missing'; Change = 'key'; Expected = "The file tools are off for this start: The mcpo key file '*files.key' does not exist*" }
            @{ Case = 'Files.Root holds a deny-pattern file'; Change = 'deny'; Expected = "Files.Root '*-files' is not served, so the file tools are off: it holds 1 file(s) or folder(s) whose names match Files.DenyPatterns: server.key.*" }
            @{ Case = 'Files.Root is not an existing folder'; Change = 'missing'; Expected = "Files.Root '*' is not served, so the file tools are off: it is not an existing folder." }
        ) {
            switch ($Change) {
                'stamp' { $complete.Remove('Files'); Write-LocalAIState -Path $paths.InstallStamp -State $complete }
                'tools' { $ollama.Capabilities = @('completion') }
                'key' { Remove-Item -LiteralPath $paths.FilesKey }
                'deny' { $null = Write-TestFile ((Split-Path $tool.Root -Leaf) + '\server.key') 'secret' }
                'missing' { $settings.Files.Root = $tool.Root + '-gone' }
            }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            @($run.Warnings -split "`n").Count | Should -Be 1
            $run.Warnings | Should -BeLike $Expected
            $events | Should -Be @('start OpenWebUI', 'wait OpenWebUI')
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['TOOL_SERVER_CONNECTIONS'] -eq '[]'
            }
            Test-Path -LiteralPath $paths.McpoConfig | Should -BeFalse
        }

        It 'warns once about a refused Files.Root when it runs install first, which checked the same folder' {
            $null = Write-TestFile ((Split-Path $tool.Root -Leaf) + '\server.key') 'secret'
            Write-LocalAIState -Path $paths.InstallStamp -State @{ Ollama = $complete.Ollama }
            Mock Install-LocalAI -ModuleName LocalAI -MockWith {
                Write-LocalAIState -Path $Context.Paths.InstallStamp -State $complete
                $null = Test-FilesRoot -Settings $Context.Settings -Paths $Context.Paths -RepoRoot $Context.RepoRoot
                2
            }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $warnings = @($run.Warnings -split "`n" | Where-Object { $_ })
            $warnings.Count | Should -Be 1
            $warnings[0] | Should -BeLike "Files.Root '*-files' is not served, so the file tools are off: it holds 1 file(s) or folder(s) whose names match Files.DenyPatterns: server.key.*"
            $events | Should -Be @('start OpenWebUI', 'wait OpenWebUI')
        }

        It 'still warns about a refused Files.Root when the install it runs first found the folder fine' {
            Write-LocalAIState -Path $paths.InstallStamp -State @{ Ollama = $complete.Ollama }
            Mock Install-LocalAI -ModuleName LocalAI -MockWith {
                Write-LocalAIState -Path $Context.Paths.InstallStamp -State $complete
                $null = Write-TestFile ((Split-Path $tool.Root -Leaf) + '\server.key') 'secret'
                0
            }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            @($run.Warnings -split "`n" | Where-Object { $_ }).Count | Should -Be 1
            $run.Warnings | Should -BeLike '*whose names match Files.DenyPatterns: server.key.*'
        }

        It 'warns once and starts Open WebUI without the file tools when another program holds the mcpo port' {
            $owners[18189] = [pscustomobject]@{ Id = 9200; Name = 'node'; Path = 'C:\tools\node.exe'; StartTicks = 5 }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            @($run.Warnings -split "`n").Count | Should -Be 1
            $run.Warnings | Should -BeLike 'The file tools are off for this start: Port 18189, which File tools needs, is held by node (PID 9200, C:\tools\node.exe)*Ports.Files*'
            $events | Should -Be @('start OpenWebUI', 'wait OpenWebUI')
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'reuses an mcpo an earlier start left running when it serves this root, and hands Open WebUI the file tools' {
            $record = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189; Listener = @{ Pid = 7950; StartTicks = 555; Path = $mcpoListener.Path } }
            Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = $record } }
            $owners[18189] = $mcpoListener
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($Record.Pid -eq 7950) { 'match' } else { 'other' } }
            Mock Get-FilesServerVersion -ModuleName LocalAI -MockWith { '2.0.1' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike '*File tools server-filesystem 2.0.1 is already running at http://127.0.0.1:18189; reusing it.*'
            $events | Should -Be @('start OpenWebUI', 'wait OpenWebUI')
            Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Url -eq 'http://127.0.0.1:18189' -and $Key -eq $tool.Key -and $Root -eq $tool.Root -and $Version -eq '2.0.1'
            }
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['TOOL_SERVER_CONNECTIONS'] -like "*$($tool.Key)*"
            }
        }

        It 'stops an mcpo an earlier start left serving another root, warns once and starts Open WebUI without the file tools' {
            $record = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189; Listener = @{ Pid = 7950; StartTicks = 555; Path = $mcpoListener.Path } }
            Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = $record } }
            $owners[18189] = $mcpoListener
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($Record.Pid -eq 7950) { 'match' } else { 'other' } }
            Mock Get-FilesServerVersion -ModuleName LocalAI -MockWith { throw "mcpo at http://127.0.0.1:18189 serves the folders 'D:\Old-Folder', not Files.Root $($tool.Root) alone." }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            @($run.Warnings -split "`n").Count | Should -Be 1
            $run.Warnings | Should -BeLike "The file tools are off for this start: Port 18189 is held by the File tools an earlier start left running (PID 7950)*D:\Old-Folder*Run 'local-ai stop', then start again."
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'Files' -and $Record.Pid -eq 4500 }
            (Read-LocalAIState -Path $paths.State).Services.ContainsKey('Files') | Should -BeFalse
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['TOOL_SERVER_CONNECTIONS'] -eq '[]'
            }
        }

        It 'stops the mcpo an earlier start left running when this start <Case>, and says the reused Open WebUI still offers the tools' -ForEach @(
            @{ Case = 'refuses Files.Root for a deny-pattern file'; Change = 'deny'; Count = 2; Expected = '*whose names match Files.DenyPatterns: server.key*' }
            @{ Case = 'runs with Files.Root empty'; Change = 'empty'; Count = 1; Expected = '' }
        ) {
            $owners[18189] = $mcpoListener
            $owners[18431] = $python
            $records = @{
                Files     = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189; Listener = @{ Pid = 7950; StartTicks = 555; Path = $mcpoListener.Path } }
                OpenWebUI = @{ Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431; Listener = @{ Pid = 1624; StartTicks = 222; Path = 'C:\uv\python\python.exe' } }
            }
            Write-LocalAIState -Path $paths.State -State @{ Services = $records }
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if (@(7950, 1624) -contains $Record.Pid) { 'match' } else { 'other' } }
            Mock Get-OpenWebUIVersion -ModuleName LocalAI -MockWith { '0.12.4' }
            switch ($Change) {
                'deny' { $null = Write-TestFile ((Split-Path $tool.Root -Leaf) + '\server.key') 'secret' }
                'empty' { $settings.Files.Root = '' }
            }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'Files' -and $Record.Pid -eq 4500 }
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
            $state = Read-LocalAIState -Path $paths.State
            $state.Services.ContainsKey('Files') | Should -BeFalse
            $state.Services.OpenWebUI.Pid | Should -Be 4242
            $warnings = @($run.Warnings -split "`n" | Where-Object { $_ })
            $warnings.Count | Should -Be $Count
            if ($Expected) { $run.Warnings | Should -BeLike $Expected }
            $warnings[-1] | Should -BeExactly ("Open WebUI, which an earlier start left running, still offers the file tools, but the mcpo they call is stopped, so " +
                "calls to them fail. Run 'local-ai stop', then start again.")
            $run.Printed | Should -Not -BeLike '*File tools:*'
        }

        It 'warns that mcpo still serves the file tools when the one an earlier start left running cannot be stopped' {
            $records = @{ Files = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189 } }
            Write-LocalAIState -Path $paths.State -State @{ Services = $records }
            $settings.Files.Root = ''
            Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'failed' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeExactly "The mcpo an earlier start left running still serves the file tools, since it could not be stopped. Run 'local-ai stop'."
            (Read-LocalAIState -Path $paths.State).Services.Files.Pid | Should -Be 4500
        }

        It 'drops a stale mcpo record without a warning when this start runs without the file tools' {
            Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189 } } }
            $settings.Files.Root = ''
            Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'stale' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(0)
            (Read-LocalAIState -Path $paths.State).Services.ContainsKey('Files') | Should -BeFalse
        }

        It 'stops mcpo as well and returns 1 when Open WebUI fails' {
            Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'OpenWebUI' } -MockWith { throw 'Open WebUI exited with code 1 before it answered.' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(1)
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'Files' -and $Record.Pid -eq 4500 }
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'OpenWebUI' }
            (Read-LocalAIState -Path $paths.State).Services.Count | Should -Be 0
        }

        It 'warns once and returns 2 when the stamped mcpo differs from Files.McpoVersion' {
            $complete.Files.McpoVersion = '0.0.19'
            Write-LocalAIState -Path $paths.InstallStamp -State $complete
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeExactly ("mcpo 0.0.19 runs, but Files.McpoVersion pins 0.0.20. Run 'local-ai update' to move to the pin, or " +
                "'local-ai install', which reinstalls mcpo at its pins.")
        }
    }

    Context 'with images' {
        BeforeEach {
            $settings.Images.Enabled = $true
            $settings.Ports.ComfyUI = 18188
            # Images straight to ComfyUI; the 'and the image gate' context turns the gate on.
            $settings.Images.UnloadChat = $false
            $settings.Ports.ImageGate = 18190
            $leaf = Split-Path $root -Leaf
            $comfyDir = Join-Path $root 'ComfyUI'
            $settings.ComfyUI.Dir = $comfyDir
            $comfyPython = Write-TestFile "$leaf\ComfyUI\.venv\Scripts\python.exe" 'program'
            $complete.ComfyUI = @{ Dir = $comfyDir; Commit = $settings.ComfyUI.Commit; Ref = 'v0.42.5'; Pinned = $true; Python = $comfyPython; PythonVersion = '3.13.18'; Torch = '2.14.1+cu130' }
            # What install leaves: a checked checkpoint, its record in state.json and the venv's marker for requirements.txt.
            $checkpoint = Write-TestFile "$leaf\ComfyUI\models\checkpoints\DreamShaperXL_Lightning.safetensors" 'checkpoint bytes'
            $checkpointSha = (Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash.ToLowerInvariant()
            $settings.Images.Size = (Get-Item -LiteralPath $checkpoint).Length
            $settings.Images.Sha256 = $checkpointSha
            $complete.Images = @{ File = 'DreamShaperXL_Lightning.safetensors'; Sha256 = $checkpointSha }
            Write-LocalAIState -Path $paths.InstallStamp -State $complete
            Write-LocalAIState -Path $paths.State -State @{ Images = @{ VerifiedFiles = @{ $checkpointSha = @{
                            Length = (Get-Item -LiteralPath $checkpoint).Length; WriteTicks = (Get-Item -LiteralPath $checkpoint).LastWriteTimeUtc.Ticks } } } }
            $requirements = Write-TestFile "$leaf\ComfyUI\requirements.txt" "torch`n"
            Write-LocalAIState -Path (Join-Path $comfyDir '.venv\local-ai-install.json') -State @{
                RequirementsSha256 = (Get-FileHash -LiteralPath $requirements -Algorithm SHA256).Hash.ToLowerInvariant() }
            Mock Test-ComfyUIDevice -ModuleName LocalAI -MockWith { $true }
            $comfyListener = [pscustomobject]@{ Id = 7804; Name = 'python'; Path = 'C:\uv\python\cpython-3.13\python.exe'; StartTicks = 333 }
            # Each port has its own owner; the waits put the started listeners there.
            $owners = @{}
            $pids = @{ ComfyUI = 4300; ImageGate = 4400; OpenWebUI = 4242 }
            $order = New-Object System.Collections.Generic.List[string]
            Mock Get-PortOwner -ModuleName LocalAI -MockWith { $owners[[int]$Port] }
            Mock Start-LocalAIService -ModuleName LocalAI -MockWith {
                $order.Add($Service.Name)
                $id = $pids[$Service.Name]
                @{ Pid = $id; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = $Service.Port; OutLog = $Service.OutLog; ErrLog = $Service.ErrLog
                    Process = [pscustomobject]@{ Id = $id; HasExited = $false } }
            }
            Mock Wait-LocalAIService -ModuleName LocalAI -MockWith {
                if ($Service.Name -eq 'ComfyUI') {
                    $owners[18188] = $comfyListener
                    return @{ Version = '0.42.5'; Listener = $comfyListener }
                }
                $owners[18431] = $python
                @{ Version = '0.12.4'; Listener = $python }
            }
            Mock Test-ComfyUICheckpoint -ModuleName LocalAI -MockWith { $true }
        }

        It 'starts ComfyUI before Open WebUI, checks the checkpoint and the device, prints the image endpoint and returns 0' {
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Warnings | Should -BeNullOrEmpty
            $order | Should -Be @('ComfyUI', 'OpenWebUI')
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['ENABLE_IMAGE_GENERATION'] -eq 'True' -and
                $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188' -and $Service.Environment['COMFYUI_WORKFLOW'] -like '*"PreviewImage"*'
            }
            Should -Invoke Test-ComfyUIDevice -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Url -eq 'http://127.0.0.1:18188' }
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'ComfyUI' -and $Service.FilePath -eq $comfyPython -and $Service.Port -eq 18188 -and $Service.ArgumentList[0] -eq 'main.py'
            }
            Should -Invoke Wait-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Service.Name -eq 'ComfyUI' -and $TimeoutSeconds -eq 300 }
            Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Port -eq 18188 -and $Name -eq 'ComfyUI' }
            Should -Invoke Test-ComfyUICheckpoint -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Url -eq 'http://127.0.0.1:18188' -and $File -eq 'DreamShaperXL_Lightning.safetensors'
            }
            $state = Read-LocalAIState -Path $paths.State
            $state.Services.ComfyUI.Pid | Should -Be 4300
            $state.Services.ComfyUI.Listener.Pid | Should -Be 7804
            $state.Services.OpenWebUI.Pid | Should -Be 4242
            $run.Printed | Should -BeLike '*Images:*http://127.0.0.1:18188 (ComfyUI, DreamShaperXL_Lightning.safetensors)*'
            Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'http://127.0.0.1:18431' }
        }

        It 'warns, stops only the ComfyUI it started, keeps Open WebUI and returns 2 when ComfyUI <Case>' -ForEach @(
            @{ Case = 'exits before it answers'; Message = 'ComfyUI exited with code 1 before it answered at http://127.0.0.1:18188.' }
            @{ Case = 'does not answer in time'; Message = 'ComfyUI did not answer at http://127.0.0.1:18188/system_stats within 300 s (it has not answered yet).' }
            @{ Case = 'answers as something else'; Message = 'GET http://127.0.0.1:18188/system_stats did not answer with system.comfyui_version, so it is not ComfyUI.' }
        ) {
            Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'ComfyUI' } -MockWith { throw $Message }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike "*ComfyUI is not available, and start goes on without it: $Message*"
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ComfyUI' -and $Record.Pid -eq 4300 }
            $state = Read-LocalAIState -Path $paths.State
            $state.Services.ContainsKey('ComfyUI') | Should -BeFalse
            $state.Services.OpenWebUI.Pid | Should -Be 4242
            Should -Invoke Test-ComfyUICheckpoint -ModuleName LocalAI -Times 0 -Exactly
            Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'http://127.0.0.1:18431' }
            $run.Printed | Should -Not -BeLike '*Images:*'
        }

        It 'keeps the ComfyUI record when it cannot be stopped, still starting Open WebUI' {
            Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'ComfyUI' } -MockWith { throw 'ComfyUI did not answer within 300 s.' }
            Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'failed' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            (Read-LocalAIState -Path $paths.State).Services.ComfyUI.Pid | Should -Be 4300
            $order | Should -Be @('ComfyUI', 'OpenWebUI')
        }

        It 'warns and starts only Open WebUI when another program holds the ComfyUI port' {
            $owners[18188] = [pscustomobject]@{ Id = 9100; Name = 'python'; Path = 'C:\Users\User\ComfyUI\.venv\Scripts\python.exe'; StartTicks = 5 }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike '*ComfyUI is not available*Port 18188, which ComfyUI needs, is held by python (PID 9100*'
            $order | Should -Be @('OpenWebUI')
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'stops ComfyUI as well and returns 1 when Open WebUI fails after it' {
            Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'OpenWebUI' } -MockWith { throw 'Open WebUI exited with code 1 before it answered.' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(1)
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ComfyUI' }
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'OpenWebUI' }
            Should -Invoke Start-Process -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'warns once and returns 2 when the stamped ComfyUI commit differs from ComfyUI.Commit' {
            $complete.ComfyUI.Commit = 'abcdef0123456789abcdef0123456789abcdef01'
            $complete.ComfyUI.Pinned = $false
            Write-LocalAIState -Path $paths.InstallStamp -State $complete
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $drift = @($run.Warnings -split "`n" | Where-Object { $_ -like '*pins 483dae4326356b81de05d27aca3f433dd323cc25*' })
            $drift.Count | Should -Be 1
            $drift[0] | Should -BeLike "ComfyUI abcdef0123456789abcdef0123456789abcdef01 runs, but ComfyUI.Commit pins 483dae4326356b81de05d27aca3f433dd323cc25. Run 'local-ai update' to move to the pin.*"
        }

        It 'returns 2 when ComfyUI does not list the checkpoint' {
            # The module's own check, against ComfyUI's answer.
            $realCheck = & (Get-Module LocalAI) { Get-Command -Name 'Test-ComfyUICheckpoint' -CommandType Function }
            Mock Test-ComfyUICheckpoint -ModuleName LocalAI -MockWith { & $realCheck -Url $Url -File $File }
            Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -eq 'http://127.0.0.1:18188/object_info/CheckpointLoaderSimple' } -MockWith {
                ConvertFrom-Json -InputObject '{"CheckpointLoaderSimple": {"input": {"required": {"ckpt_name": [["other.safetensors"], {"tooltip": "x"}]}}}}'
            }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike "*ComfyUI lists the checkpoints 'other.safetensors', not DreamShaperXL_Lightning.safetensors*"
            $run.Printed | Should -BeLike '*Images:*http://127.0.0.1:18188*'
        }

        It 'warns and starts only Open WebUI, with images off, when the stamp names no ComfyUI python.exe that exists' {
            $complete.Remove('ComfyUI')
            Write-LocalAIState -Path $paths.InstallStamp -State $complete
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike "*Images are off for this start, and ComfyUI does not start: install-stamp.json names no ComfyUI python.exe that exists*Run 'local-ai install'*"
            $order | Should -Be @('OpenWebUI')
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['ENABLE_IMAGE_GENERATION'] -eq 'False' -and $Service.Environment['COMFYUI_BASE_URL'] -eq ''
            }
            Should -Invoke Install-LocalAI -ModuleName LocalAI -Times 0 -Exactly
        }

        It 'starts Open WebUI with images off and no ComfyUI, returning 2, when the image workflow does not load' {
            $settings.Images.Workflow = Write-TestFile "$leaf\broken.workflow.json" '{ "3": '
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike "*Images are off for this start, and ComfyUI does not start: Cannot read Images.Workflow '*broken.workflow.json'*"
            $order | Should -Be @('OpenWebUI')
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['ENABLE_IMAGE_GENERATION'] -eq 'False'
            }
            Should -Invoke Start-Process -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'http://127.0.0.1:18431' }
        }

        It 'starts no ComfyUI when <Case>' -ForEach @(
            @{ Case = 'install has not checked the checkpoint'; Change = 'stamp'; Expected = '*install has not checked DreamShaperXL_Lightning.safetensors*' }
            @{ Case = 'the checkpoint changed since install checked it'; Change = 'file'; Expected = '*DreamShaperXL_Lightning.safetensors is missing or changed since install checked it*' }
            @{ Case = 'ComfyUI.Dir changed since install'; Change = 'dir'; Expected = "*install set up ComfyUI in '*', but ComfyUI.Dir is '*Elsewhere'*" }
        ) {
            switch ($Change) {
                'stamp' { $complete.Remove('Images'); Write-LocalAIState -Path $paths.InstallStamp -State $complete }
                'file' { [IO.File]::AppendAllText($checkpoint, 'X') }
                'dir' { $settings.ComfyUI.Dir = Join-Path $root 'Elsewhere' }
            }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike $Expected
            $order | Should -Be @('OpenWebUI')
        }

        It 'opens the browser once Open WebUI answers, before it waits for ComfyUI' {
            $events = New-Object System.Collections.Generic.List[string]
            Mock Start-Process -ModuleName LocalAI -MockWith { $events.Add('browser') }
            Mock Wait-LocalAIService -ModuleName LocalAI -MockWith {
                $events.Add("wait $($Service.Name)")
                if ($Service.Name -eq 'ComfyUI') { $owners[18188] = $comfyListener; return @{ Version = '0.42.5'; Listener = $comfyListener } }
                $owners[18431] = $python
                @{ Version = '0.12.4'; Listener = $python }
            }
            (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
            $order | Should -Be @('ComfyUI', 'OpenWebUI')
            $events | Should -Be @('wait OpenWebUI', 'browser', 'wait ComfyUI')
        }

        It 'stops the ComfyUI it started and keeps Open WebUI when ComfyUI listens beyond loopback' {
            Mock Test-LoopbackListener -ModuleName LocalAI -ParameterFilter { $Name -eq 'ComfyUI' } -MockWith { Write-Warning 'ComfyUI IS OPEN TO THE NETWORK'; $false }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike '*ComfyUI IS OPEN TO THE NETWORK*ComfyUI is not available, and start goes on without it: port 18188 does not listen on loopback only*'
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ComfyUI' -and $Record.Pid -eq 4300 }
            Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Name -eq 'OpenWebUI' }
            (Read-LocalAIState -Path $paths.State).Services.OpenWebUI.Pid | Should -Be 4242
            Should -Invoke Test-ComfyUICheckpoint -ModuleName LocalAI -Times 0 -Exactly
            $run.Printed | Should -Not -BeLike '*Images:*'
        }

        It 'returns 2 when ComfyUI renders on no CUDA device' {
            Mock Test-ComfyUIDevice -ModuleName LocalAI -MockWith { Write-Warning 'ComfyUI reports cpu (type cpu), not a CUDA GPU.'; $false }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike '*not a CUDA GPU*'
        }

        It 'warns, still starting ComfyUI, when requirements.txt changed since the venv was set up' {
            [IO.File]::AppendAllText($requirements, "blake3`n")
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeLike "*requirements.txt is not the one ComfyUI's venv was set up for*'local-ai install'*"
            $order | Should -Be @('ComfyUI', 'OpenWebUI')
        }

        It 'reuses a ComfyUI an earlier start left running' {
            $record = @{ Pid = 4300; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18188; Listener = @{ Pid = 7804; StartTicks = 333; Path = $comfyListener.Path }
                EnvironmentSha256 = (Get-TestComfyUIHash -Settings $settings -Paths $paths -Stamp $complete) }
            Write-LocalAIState -Path $paths.State -State @{ Services = @{ ComfyUI = $record }; Images = (Read-LocalAIState -Path $paths.State).Images }
            $owners[18188] = $comfyListener
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($Record.Pid -eq 7804) { 'match' } else { 'other' } }
            Mock Get-ComfyUIVersion -ModuleName LocalAI -MockWith { '0.42.5' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Warnings | Should -BeNullOrEmpty
            $run.Printed | Should -BeLike '*ComfyUI 0.42.5 is already running at http://127.0.0.1:18188; reusing it.*'
            $order | Should -Be @('OpenWebUI')
            Should -Invoke Test-ComfyUICheckpoint -ModuleName LocalAI -Times 1 -Exactly
        }

        It 'warns once and returns 2, still reusing it, when the ComfyUI it reuses was started <Case>' -ForEach @(
            @{ Case = 'by a launcher that recorded no inherited names'; Hash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
            @{ Case = 'before ComfyUI.InheritEnvironment named CUDA_CACHE_PATH'; Hash = 'before the list' }
        ) {
            if ($Hash -eq 'before the list') {
                $Hash = Get-TestComfyUIHash -Settings $settings -Paths $paths -Stamp $complete
                $settings.ComfyUI.InheritEnvironment = @('CUDA_CACHE_PATH')
            }
            $record = @{ Pid = 4300; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18188; Listener = @{ Pid = 7804; StartTicks = 333; Path = $comfyListener.Path }
                EnvironmentSha256 = $Hash }
            Write-LocalAIState -Path $paths.State -State @{ Services = @{ ComfyUI = $record }; Images = (Read-LocalAIState -Path $paths.State).Images }
            $owners[18188] = $comfyListener
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($Record.Pid -eq 7804) { 'match' } else { 'other' } }
            Mock Get-ComfyUIVersion -ModuleName LocalAI -MockWith { '0.42.5' }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(2)
            $run.Warnings | Should -BeExactly ("ComfyUI, which an earlier start left running, keeps the variables of this window it started with, which differ " +
                "from those this start lets it inherit, such as the GPU it uses. Run 'local-ai stop', then start again.")
            $order | Should -Be @('OpenWebUI')
        }

        Context 'and the image gate' {
            BeforeEach {
                $settings.Images.UnloadChat = $true
                $gateListener = [pscustomobject]@{ Id = 7900; Name = 'python'; Path = 'C:\uv\python\cpython-3.13\python.exe'; StartTicks = 444 }
                $gateRecord = @{ Pid = 4400; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18190; Listener = @{ Pid = 7900; StartTicks = 444; Path = $gateListener.Path } }
                # Launches and waits in the order they happen.
                $events = New-Object System.Collections.Generic.List[string]
                Mock Start-LocalAIService -ModuleName LocalAI -MockWith {
                    $order.Add($Service.Name)
                    $events.Add("start $($Service.Name)")
                    $id = $pids[$Service.Name]
                    @{ Pid = $id; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = $Service.Port; OutLog = $Service.OutLog; ErrLog = $Service.ErrLog
                        Process = [pscustomobject]@{ Id = $id; HasExited = $false } }
                }
                Mock Wait-LocalAIService -ModuleName LocalAI -MockWith {
                    $events.Add("wait $($Service.Name)")
                    if ($Service.Name -eq 'ComfyUI') { $owners[18188] = $comfyListener; return @{ Version = '0.42.5'; Listener = $comfyListener } }
                    if ($Service.Name -eq 'ImageGate') { $owners[18190] = $gateListener; return @{ Version = '1.0.0'; Listener = $gateListener } }
                    $owners[18431] = $python
                    @{ Version = '0.12.4'; Listener = $python }
                }
            }

            It 'starts ComfyUI and the gate, waits for the gate, then starts Open WebUI with images through it, and returns 0' {
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Warnings | Should -BeNullOrEmpty
                $events | Should -Be @('start ComfyUI', 'start ImageGate', 'wait ImageGate', 'start OpenWebUI', 'wait OpenWebUI', 'wait ComfyUI')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18190' -and
                    $Service.Environment['ENABLE_IMAGE_GENERATION'] -eq 'True'
                }
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'ImageGate' -and $Service.FilePath -eq $comfyPython -and $Service.ArgumentList[0] -eq '-I' -and
                    ($Service.ArgumentList -join ' ') -like '*--upstream http://127.0.0.1:18188 --ollama http://127.0.0.1:11434 --model local-chat:latest --unload-timeout 30'
                }
                Should -Invoke Wait-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Service.Name -eq 'ImageGate' -and $TimeoutSeconds -eq 15 }
                Should -Invoke Test-LoopbackListener -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Port -eq 18190 -and $Name -eq 'Image gate' }
                $state = Read-LocalAIState -Path $paths.State
                $state.Services.ImageGate.Pid | Should -Be 4400
                $state.Services.ImageGate.Listener.Pid | Should -Be 7900
                $run.Printed | Should -BeLike '*Images:*http://127.0.0.1:18188 (ComfyUI, *through http://127.0.0.1:18190, which unloads local-chat from Ollama before each image*'
            }

            It 'sends images to ComfyUI directly with one warning, stops the gate it started and returns 2 when the gate <Case>' -ForEach @(
                @{ Case = 'exits before it answers'; Message = 'Image gate exited with code 1 before it answered at http://127.0.0.1:18190.' }
                @{ Case = 'does not answer in time'; Message = 'Image gate did not answer at http://127.0.0.1:18190/local-ai/image-gate within 15 s (it has not answered yet).' }
            ) {
                Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'ImageGate' } -MockWith { $events.Add('wait ImageGate'); throw $Message }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                @($run.Warnings -split "`n").Count | Should -Be 1
                $run.Warnings | Should -BeExactly "Images go to ComfyUI directly, so local-chat is not unloaded before images: $Message"
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ImageGate' -and $Record.Pid -eq 4400 }
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188' -and
                    $Service.Environment['ENABLE_IMAGE_GENERATION'] -eq 'True'
                }
                $events | Should -Be @('start ComfyUI', 'start ImageGate', 'wait ImageGate', 'start OpenWebUI', 'wait OpenWebUI', 'wait ComfyUI')
                (Read-LocalAIState -Path $paths.State).Services.ContainsKey('ImageGate') | Should -BeFalse
                $run.Printed | Should -BeLike '*Images:*http://127.0.0.1:18188 (ComfyUI*'
                $run.Printed | Should -Not -BeLike '*through http://127.0.0.1:18190*'
            }

            It 'sends images to ComfyUI directly with one warning, stopping nothing, when another program holds the gate port' {
                $owners[18190] = [pscustomobject]@{ Id = 9200; Name = 'node'; Path = 'C:\tools\node.exe'; StartTicks = 5 }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                @($run.Warnings -split "`n").Count | Should -Be 1
                $run.Warnings | Should -BeLike ('Images go to ComfyUI directly, so local-chat is not unloaded before images: Port 18190, which Image gate needs, ' +
                    'is held by node (PID 9200, C:\tools\node.exe)*Ports.ImageGate*')
                $events | Should -Be @('start ComfyUI', 'start OpenWebUI', 'wait OpenWebUI', 'wait ComfyUI')
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188'
                }
            }

            It 'stops the gate it started and sends images to ComfyUI directly when the gate listens beyond loopback' {
                Mock Test-LoopbackListener -ModuleName LocalAI -ParameterFilter { $Name -eq 'Image gate' } -MockWith { Write-Warning 'Image gate IS OPEN TO THE NETWORK'; $false }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike ('*Image gate IS OPEN TO THE NETWORK*Images go to ComfyUI directly, so local-chat is not unloaded before images: ' +
                    'port 18190 does not listen on loopback only*')
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ImageGate' -and $Record.Pid -eq 4400 }
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188'
                }
            }

            It 'reuses a gate an earlier start left running when it fronts this ComfyUI and unloads this model from this Ollama' {
                Write-LocalAIState -Path $paths.State -State @{ Services = @{ ImageGate = $gateRecord }; Images = (Read-LocalAIState -Path $paths.State).Images }
                $owners[18190] = $gateListener
                Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($Record.Pid -eq 7900) { 'match' } else { 'other' } }
                Mock Get-ImageGateVersion -ModuleName LocalAI -MockWith { '1.0.0' }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Printed | Should -BeLike '*Image gate 1.0.0 is already running at http://127.0.0.1:18190; reusing it.*'
                $events | Should -Be @('start ComfyUI', 'start OpenWebUI', 'wait OpenWebUI', 'wait ComfyUI')
                Should -Invoke Get-ImageGateVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Url -eq 'http://127.0.0.1:18190' -and $Upstream -eq 'http://127.0.0.1:18188' -and $Ollama -eq 'http://127.0.0.1:11434' -and $Model -eq 'local-chat:latest'
                }
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18190'
                }
                (Read-LocalAIState -Path $paths.State).Services.ImageGate.Pid | Should -Be 4400
            }

            It 'leaves a gate that unloads another model running, warns once and sends images to ComfyUI directly' {
                Write-LocalAIState -Path $paths.State -State @{ Services = @{ ImageGate = $gateRecord }; Images = (Read-LocalAIState -Path $paths.State).Images }
                $owners[18190] = $gateListener
                Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($Record.Pid -eq 7900) { 'match' } else { 'other' } }
                Mock Get-ImageGateVersion -ModuleName LocalAI -MockWith { throw "The image gate at http://127.0.0.1:18190 has model 'old-chat:latest', not 'local-chat:latest'." }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                @($run.Warnings -split "`n").Count | Should -Be 1
                $run.Warnings | Should -BeLike ('Images go to ComfyUI directly, so local-chat is not unloaded before images: Port 18190 is held by the Image gate an ' +
                    "earlier start left running (PID 7900), but it does not answer as Image gate (*has model 'old-chat:latest'*). Run 'local-ai stop', then start again.")
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
                (Read-LocalAIState -Path $paths.State).Services.ImageGate.Pid | Should -Be 4400
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188'
                }
            }

            It 'stops the gate and ComfyUI as well and returns 1 when Open WebUI fails' {
                Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'OpenWebUI' } -MockWith { throw 'Open WebUI exited with code 1 before it answered.' }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(1)
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ComfyUI' }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ImageGate' }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'OpenWebUI' }
                (Read-LocalAIState -Path $paths.State).Services.Count | Should -Be 0
            }

            It 'starts ComfyUI, the gate and mcpo, then Open WebUI with images straight to ComfyUI but the file tools on, when only the gate fails' {
                $tool = Initialize-TestFileTool -Settings $settings -Paths $paths -Complete $complete
                $pids['Files'] = 4500
                $mcpoListener = [pscustomobject]@{ Id = 7950; Name = 'python'; Path = 'C:\uv\python\cpython-3.12\python.exe'; StartTicks = 555 }
                Mock Invoke-RestMethod -ModuleName LocalAI -ParameterFilter { $Uri -like '*/api/show' } -MockWith { [pscustomobject]@{ capabilities = @('completion', 'tools') } }
                Mock Wait-LocalAIService -ModuleName LocalAI -MockWith {
                    $events.Add("wait $($Service.Name)")
                    if ($Service.Name -eq 'ImageGate') { throw 'Image gate exited with code 1 before it answered at http://127.0.0.1:18190.' }
                    if ($Service.Name -eq 'ComfyUI') { $owners[18188] = $comfyListener; return @{ Version = '0.42.5'; Listener = $comfyListener } }
                    if ($Service.Name -eq 'Files') { $owners[18189] = $mcpoListener; return @{ Version = '2.0.1'; Listener = $mcpoListener } }
                    $owners[18431] = $python
                    @{ Version = '0.12.4'; Listener = $python }
                }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeExactly 'Images go to ComfyUI directly, so local-chat is not unloaded before images: Image gate exited with code 1 before it answered at http://127.0.0.1:18190.'
                $events | Should -Be @('start ComfyUI', 'start ImageGate', 'wait ImageGate', 'start Files', 'wait Files', 'start OpenWebUI', 'wait OpenWebUI', 'wait ComfyUI')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188' -and
                    $Service.Environment['TOOL_SERVER_CONNECTIONS'] -like "*$($tool.Key)*"
                }
                $run.Printed | Should -BeLike '*Images:*http://127.0.0.1:18188*File tools:*'
            }

            It 'starts no gate in front of a program this start did not launch on the ComfyUI port, says so and sends images to that port directly' {
                $owners[18188] = [pscustomobject]@{ Id = 9100; Name = 'python'; Path = 'C:\Users\User\ComfyUI\.venv\Scripts\python.exe'; StartTicks = 5 }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $warnings = @($run.Warnings -split "`n")
                $warnings.Count | Should -Be 2
                $warnings[0] | Should -BeLike 'ComfyUI is not available, and start goes on without it: Port 18188, which ComfyUI needs, is held by python (PID 9100*'
                $warnings[1] | Should -BeExactly ('Images go to ComfyUI directly, so local-chat is not unloaded before images: this start runs no ComfyUI of its ' +
                    'own for the gate to front, as the warning above says.')
                $events | Should -Be @('start OpenWebUI', 'wait OpenWebUI')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188'
                }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly
            }

            It 'stops the gate it started as well when ComfyUI does not answer' {
                Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'ComfyUI' } -MockWith {
                    $events.Add('wait ComfyUI')
                    throw 'ComfyUI did not answer at http://127.0.0.1:18188/system_stats within 300 s (it has not answered yet).'
                }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike '*ComfyUI is not available, and start goes on without it: ComfyUI did not answer*'
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 2 -Exactly
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ComfyUI' -and $Record.Pid -eq 4300 }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'ImageGate' -and $Record.Pid -eq 4400 }
                $state = Read-LocalAIState -Path $paths.State
                $state.Services.ContainsKey('ComfyUI') | Should -BeFalse
                $state.Services.ContainsKey('ImageGate') | Should -BeFalse
                $state.Services.OpenWebUI.Pid | Should -Be 4242
                $run.Printed | Should -Not -BeLike '*Images:*'
            }

            It 'starts no gate when ComfyUI does not start' {
                $complete.Remove('ComfyUI')
                Write-LocalAIState -Path $paths.InstallStamp -State $complete
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $events | Should -Be @('start OpenWebUI', 'wait OpenWebUI')
            }

            It 'starts no gate and warns once when Ollama is not on a loopback address' {
                Mock Resolve-OllamaUrl -ModuleName LocalAI -MockWith { 'http://192.0.2.20:11434' }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                @($run.Warnings -split "`n").Count | Should -Be 1
                $run.Warnings | Should -BeLike 'Images go to ComfyUI directly, so local-chat is not unloaded before images: the image gate unloads only from an Ollama on a loopback address*'
                $events | Should -Be @('start ComfyUI', 'start OpenWebUI', 'wait OpenWebUI', 'wait ComfyUI')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                    $Service.Name -eq 'OpenWebUI' -and $Service.Environment['COMFYUI_BASE_URL'] -eq 'http://127.0.0.1:18188'
                }
            }
        }
    }
}

Describe 'Stop-LocalAI and Stop-LocalAIService' {
    BeforeAll {
        $exe = 'C:\Users\User\.local\bin\open-webui.exe'

        # Run Stop-LocalAI and return @{ Code; Printed } with the host text joined.
        function Invoke-StopVerb([hashtable]$Context) {
            $output = @(Stop-LocalAI -Context $Context 6>&1)
            return @{
                Code    = @($output | Where-Object { $_ -is [int] })
                Printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
            }
        }
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
    BeforeAll {
        # Run Stop-LocalAI with $Arguments added and return @{ Code; Printed } with the host text joined.
        function Invoke-StopVerb([hashtable]$Context, [hashtable]$Arguments = @{}) {
            $output = @(Stop-LocalAI -Context $Context @Arguments 6>&1)
            return @{
                Code    = @($output | Where-Object { $_ -is [int] })
                Printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
            }
        }
    }

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

Describe 'Get-LocalAIStatus' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent

        # Run Get-LocalAIStatus and return @{ Code; Printed; Warnings; Records; Other }: host text and warnings joined, the host records, and any
        # other pipeline output.
        function Invoke-StatusVerb([hashtable]$Context) {
            $output = @(Get-LocalAIStatus -Context $Context 3>&1 6>&1)
            $records = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
            return @{
                Code     = @($output | Where-Object { $_ -is [int] })
                Printed  = @($records | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
                Records  = $records
                Other    = @($output | Where-Object { $_ -isnot [int] -and $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] })
            }
        }

        # Return the lowercase SHA-256 of the file $Path.
        function Get-TestHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
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
                ModelfileSha256 = (Get-TestHash (Join-Path $repoRoot $settings.Model.Modelfile)) }
            OpenWebUI = @{ Version = '0.12.4'; Path = 'C:\uv\bin\open-webui.exe'; Python = '3.12.16' }
            ComfyUI   = @{ Dir = $settings.ComfyUI.Dir; Commit = $settings.ComfyUI.Commit; Python = (Join-Path $settings.ComfyUI.Dir '.venv\Scripts\python.exe') }
            Files     = @{ McpoVersion = '0.0.20'; McpoPath = 'C:\uv\bin\mcpo.exe'; Python = '3.12'; With = @($settings.Files.McpoWith)
                ExcludeNewer = $settings.Files.McpoExcludeNewer; ServerVersion = '2.0.1'; ToolDir = 'C:\uv\tools'
                LockSha256 = (Get-TestHash (Join-Path $repoRoot 'config\files-server\package-lock.json')) }
        }
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
        # A checkout at the pin with origin ComfyUI.Repo, whose venv marker is what Install-ComfyUI writes for it (it holds no requirements.txt).
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $settings.ComfyUI.Dir '.git')
        $venvMarker = @{ RequirementsSha256 = ''; ConstraintsSha256 = (Get-TestHash (Join-Path $repoRoot $settings.ComfyUI.Constraints)); Backend = $settings.ComfyUI.TorchBackend
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
        Write-LocalAIState -Path $paths.State -State @{ Services = $records; Ollama = @{ Url = 'http://127.0.0.1:11434'; Alias = 'local-chat' } }
        $context = @{ Verb = 'status'; Paths = $paths; Settings = $settings; SettingsError = $null; RepoRoot = $repoRoot; Json = $false }
        $world = @{
            Live      = New-Object System.Collections.Generic.List[int]
            Listeners = @{ 11434 = @('127.0.0.1'); 18431 = @('127.0.0.1'); 18432 = @('127.0.0.1'); 18433 = @('127.0.0.1'); 18434 = @('127.0.0.1') }
            Owner     = $null
            Versions  = @{ OpenWebUI = '0.12.4'; ComfyUI = '0.42.5'; ImageGate = '1.0'; Files = '2.0.1' }
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
        $run.Printed | Should -BeLike '*File tools: server-filesystem 2.0.1 runs at http://127.0.0.1:18433 (PID 4400, up 1 h 30 min), listening on 127.0.0.1; install recorded mcpo 0.0.20, as Files.McpoVersion pins.*'
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
        $before = @(foreach ($file in $files) { '{0}|{1}' -f (Get-TestHash $file), (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks })
        $world.Live.Clear()
        $world.Ollama = $null
        $null = Invoke-StatusVerb -Context $context
        $null = Invoke-StatusVerb -Context $context
        @(foreach ($file in $files) { '{0}|{1}' -f (Get-TestHash $file), (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks }) | Should -Be $before
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
        @{ Case = 'ComfyUI commit'; Part = 'ComfyUI'; Field = 'Commit'; Value = 'abcdef0123456789abcdef0123456789abcdef01'; Message = '*ComfyUI in * is at commit abcdef0123456789abcdef0123456789abcdef01, but ComfyUI.Commit pins 483dae4326356b81de05d27aca3f433dd323cc25 (v0.42.5). Run ''local-ai update''.*' }
        @{ Case = 'mcpo version'; Part = 'Files'; Field = 'McpoVersion'; Value = '0.0.19'; Message = "*mcpo was installed with Files.McpoVersion '0.0.19', but settings.psd1 pins '0.0.20'. Run 'local-ai update'.*" }
        @{ Case = 'mcpo requirement list'; Part = 'Files'; Field = 'With'; Value = @('mcp==1.29.0'); Message = "*mcpo was installed with Files.McpoWith 'mcp==1.29.0', but settings.psd1 pins 'mcp==1.30.0 fastapi<0.145'.*" }
        @{ Case = 'files server version'; Part = 'Files'; Field = 'ServerVersion'; Value = '2.0.0'; Message = '*The files server 2.0.0 is installed, but Files.ServerVersion pins 2.0.1. Run ''local-ai update''.*' }
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
        $run.Warnings | Should -BeLike $Message
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
            "Windows Terminal; the Start menu shortcuts 'Start Local AI' and 'Stop Local AI' work too.")
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

        # Run Set-LocalAIShortcut and return @{ Code; Printed } with the host text joined.
        function Invoke-ShortcutVerb([hashtable]$Context) {
            $output = @(Set-LocalAIShortcut -Context $Context 6>&1)
            return @{
                Code    = @($output | Where-Object { $_ -is [int] })
                Printed = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
            }
        }

        # Return a stand-in for WScript.Shell: CreateShortcut gives an object with the fields $Store holds for the path (or a new shortcut's), and
        # its Save stores the fields, adds the path to $Saves and writes a placeholder file there.
        function Get-FakeShell([hashtable]$Store, [System.Collections.Generic.List[string]]$Saves) {
            $shell = [pscustomobject]@{ Store = $Store; Saves = $Saves }
            $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
                param([string]$Path)
                $link = [pscustomobject]@{ FullName = $Path; TargetPath = ''; Arguments = ''; WorkingDirectory = ''; WindowStyle = 1; IconLocation = ',0'; Description = ''; Shell = $this }
                $saved = $this.Store[$Path]
                if ($saved) { foreach ($key in @($saved.Keys)) { $link.$key = $saved[$key] } }
                $link | Add-Member -MemberType ScriptMethod -Name Save -Value {
                    $fields = @{}
                    foreach ($key in 'TargetPath', 'Arguments', 'WorkingDirectory', 'WindowStyle', 'IconLocation', 'Description') { $fields[$key] = $this.$key }
                    $this.Shell.Store[$this.FullName] = $fields
                    $this.Shell.Saves.Add($this.FullName)
                    [IO.File]::WriteAllText($this.FullName, 'lnk')
                }
                $link
            }
            return $shell
        }
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

    It 'creates Start, Stop and Status shortcuts that run local-ai.cmd with their verb in a normal window, with the Ollama icon' {
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        foreach ($verb in 'Start', 'Stop', 'Status') {
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
        $saves.Count | Should -Be 3
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
        $saves.Count | Should -Be 3
        $run.Printed | Should -BeLike "*$folder\Start Local AI.lnk is up to date.*$folder\Stop Local AI.lnk is up to date.*$folder\Status Local AI.lnk is up to date.*"
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
        $saves.Count | Should -Be 4
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

    It 'with -Remove deletes only the three shortcuts, and the folder once nothing else is in it' {
        $null = Invoke-ShortcutVerb -Context $context
        $other = Join-Path $folder 'Other.lnk'
        [IO.File]::WriteAllText($other, 'lnk')
        $context.Remove = $true
        $run = Invoke-ShortcutVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*Removed $folder\Start Local AI.lnk.*Removed $folder\Stop Local AI.lnk.*Removed $folder\Status Local AI.lnk.*Kept $folder, which holds other files.*"
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
        $settings = @{ OpenWebUI = @{ Version = '0.12.4'; Python = '3.12' } }
        $uv = @{ Tool = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' } }
        $stamp = @{ OpenWebUI = @{ Version = '0.12.3'; Python = '3.11.17'; Path = 'C:\uv\bin\open-webui.exe' } }
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
        $stamp = @{ Files = @{ McpoVersion = '0.0.20'; Python = '3.12'; With = @('mcp==1.30.0', 'fastapi<0.145'); ExcludeNewer = '2026-10-13T00:00:00Z'; ServerVersion = '2.0.1'
                LockSha256 = $lockSha } }
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
                $expected = @('files server 2.0.0 -> 2.0.1', "files server lockfile $('b' * 64) -> $lockSha")
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
        $settings = @{ OpenWebUI = @{ Version = '0.12.4'; Python = '3.12'; DataDir = $dataDir; InstallBytes = 2987894996 }; Update = @{ KeepBackups = 3 } }
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
        @($order) | Should -Be @('stop', "tool 0.12.3 3.11.17 $($change.Constraints)", "data $dataDir $($change.Backup) $($paths.Backups)")
        # The stack starts again afterwards against the same Ollama.
        Should -Invoke Stop-LocalAI -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $KeepOllama }
        $entry = (Read-LocalAIState -Path $paths.InstallStamp).OpenWebUI
        $entry.Version | Should -Be '0.12.3'
        $entry.Python | Should -Be '3.11.17'
        $entry.ContainsKey('PreviousVersion') | Should -BeFalse
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
        @{ Case = 'when install-stamp.json records no Ollama'; Setup = 'stamp'; Code = 1 }
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
            'stamp' {
                $stamp = Read-LocalAIState -Path $paths.InstallStamp
                $stamp.Remove('Ollama')
                Write-LocalAIState -Path $paths.InstallStamp -State $stamp
            }
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @($Code)
        $run.Printed | Should -BeLike '*Quitting the Ollama app update started, since Ollama did not run before the update...*'
        @($calls | Where-Object { $_ -like 'stop*' })[-1] | Should -Be 'stop KeepOllama=False'
        @($calls)[-1] | Should -Be 'awake False'
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
            # The recorded app runs until the upgrade; the app that replaces it, or one the wait after it started, is the one Recorded names.
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
        $shortcutNames = @('Start Local AI.lnk', 'Stop Local AI.lnk', 'Status Local AI.lnk')

        # Run Uninstall-LocalAI and return @{ Code; Printed; Warnings } with the host text and the warnings joined.
        function Invoke-UninstallVerb([hashtable]$Context) {
            $output = @(Uninstall-LocalAI -Context $Context 3>&1 6>&1)
            return @{
                Code     = @($output | Where-Object { $_ -is [int] })
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
            }
        }

        # Lay out what install leaves, all below TestDrive: the three shortcuts, the open-webui and mcpo tool folders in $ToolDir, a ComfyUI checkout (marked as cloned
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
        $run.Printed | Should -BeLike ("*Uninstall removes:*the Start menu shortcuts Start Local AI.lnk, Stop Local AI.lnk, Status Local AI.lnk in $folder*" +
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
}
