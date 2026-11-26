# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS: CORE
# -------------------------------------------------------
#
# Pester 6 tests for src\LocalAI.psm1: paths, version, settings, JSON and state files, logs,
# Invoke-Native, the lock, the keep-awake request, the verb dispatch of Invoke-LocalAI, the
# packaged-app check and the loopback helpers. tests\LocalAI.TestSetup.ps1 imports the module and
# holds the shared helpers.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LocalAI.TestSetup.ps1')
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
    OpenWebUI = @{ DataDir = '%LOCALAI_TEST_DIR%\data'; HealthTimeoutSeconds = 600; InheritEnvironment = @(); Env = @{ WEBUI_AUTH = 'True' }; ExcludeNewer = '2026-10-25T08:10:00Z' }
    HfCli     = @{ Version = '2.2.0'; ExcludeNewer = '2026-10-08T15:31:00Z' }
    Images    = @{ Enabled = $true; Steps = 6; Resolution = '1024x1024'; Revision = '561086c22aba3925b1e8803a73857f061635c7c3'; UnloadChat = $true; UnloadTimeoutSeconds = 30 }
    ComfyUI   = @{ Args = @('--one', '--two'); Dir = '%LOCALAI_TEST_DIR%\ComfyUI'; Commit = '483dae4326356b81de05d27aca3f433dd323cc25'; ExcludeNewer = '2026-10-23T00:07:14Z'
        InheritEnvironment = @() }
    Winget    = @{ Packages = @{ Node = @{ Id = 'OpenJS.NodeJS.LTS'; Command = 'node'; Scope = 'machine' } } }
    Logs      = @{ Keep = 5 }
    Update    = @{ KeepBackups = 3 }
    Files     = @{
        Root = ''; McpoVersion = '0.0.20'; Python = '3.12'; McpoWith = @('mcp==1.30.0', 'fastapi<0.145'); McpoExcludeNewer = '2026-10-13T00:00:00Z'
        ServerVersion = '2.0.1'; AllowedTools = @('read_text_file', 'list_directory')
        DisabledTools = @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file', 'append_file', 'copy_file'); DenyPatterns = @('*.key', '*secret*')
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
        @{ Name = 'an Open WebUI cut-off date without a time'; Text = "@{ OpenWebUI = @{ ExcludeNewer = '2026-10-25' } }"; Message = "*'OpenWebUI.ExcludeNewer' = '2026-10-25' must be empty or a UTC time*" }
        @{ Name = 'an hf cut-off in local time'; Text = "@{ HfCli = @{ ExcludeNewer = '2026-10-08T15:31:00+02:00' } }"; Message = "*'HfCli.ExcludeNewer' = '2026-10-08T15:31:00+02:00' must be empty or a UTC time*" }
        @{ Name = 'a tool name with a comma'; Text = "@{ Files = @{ AllowedTools = @('read_text_file,write_file') } }"; Message = "*'Files.AllowedTools'*must list tool names made of lowercase letters, digits and `"_`"*" }
        @{ Name = 'a tool name in capitals'; Text = "@{ Files = @{ DisabledTools = @('Write_File', 'write_file', 'edit_file', 'create_directory', 'move_file', 'append_file', 'copy_file') } }"; Message = "*'Files.DisabledTools'*must list tool names*" }
        @{ Name = 'an empty deny pattern'; Text = "@{ Files = @{ DenyPatterns = @('*.key', ' ') } }"; Message = "*'Files.DenyPatterns'*must list file or folder name patterns, none of them empty*" }
        @{ Name = 'a tool both offered and hidden'; Text = "@{ Files = @{ AllowedTools = @('read_text_file', 'move_file') } }"; Message = '*Files.AllowedTools and Files.DisabledTools both name move_file; a tool is either offered or hidden*' }
        @{ Name = 'a write tool left visible'; Text = "@{ Files = @{ DisabledTools = @('read_file', 'write_file', 'create_directory') } }"; Message = "*'Files.DisabledTools' must hide every write tool, but leaves out edit_file, move_file, append_file, copy_file*" }
        @{ Name = 'a write tool that server-filesystem 2.2.0 added left visible'; Text = "@{ Files = @{ DisabledTools = @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file') } }"
            Message = "*'Files.DisabledTools' must hide every write tool, but leaves out append_file, copy_file*" }
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

    It 'keeps the exit code of a program that ends at once with -Console, as it holds the handle from the start and runs no Start-Process' {
        Mock Start-Process -ModuleName LocalAI -MockWith { throw 'Start-Process can lose the exit code of a program that ends before its handle opens.' }
        foreach ($attempt in 1..25) {
            Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 3' -SuccessCode 0, 3 -Console | Should -Be 3
        }
        Should -Invoke Start-Process -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'runs the program in the current location with -Console, as Start-Process did' {
        $folder = Join-Path $TestDrive 'native\here'
        $null = New-Item -ItemType Directory -Force -Path $folder
        [IO.File]::WriteAllText((Join-Path $folder 'marker.txt'), 'x')
        Push-Location -LiteralPath $folder
        try {
            Invoke-Native -FilePath 'cmd.exe' -ArgumentList '/c', 'if exist marker.txt (exit 5) else (exit 6)' -SuccessCode 5, 6 -Console | Should -Be 5
        } finally {
            Pop-Location
        }
    }

    It 'throws naming the program when Windows cannot start it with -Console' {
        $broken = Write-TestFile 'native\broken.exe' 'not a program'
        { Invoke-Native -FilePath $broken -ArgumentList '/x' -Console } | Should -Throw -ExpectedMessage "Cannot start '$broken /x': *"
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
            # Fail with exit code 1.
            function script:Invoke-TestVerbFailing([hashtable]$Context) { $script:TestContext = $Context; 1 }
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
        @{ Verb = 'update'; Route = ", or use the Start menu shortcut 'Update Local AI'" }
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

    It "starts update with the launcher's own release check, and runs no part of update when that check refuses or hands over" {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Tools', 'Rollback') }
        foreach ($expected in 1, 2) {
            Mock Invoke-LauncherSelfUpdate -ModuleName LocalAI -MockWith { $expected }
            InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext = $null }
            $run = Invoke-Dispatcher @{ Verb = 'update'; Root = $root; LockName = $lock }
            $run.Code | Should -Be @($expected)
            InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext } | Should -BeNullOrEmpty
        }
        Should -Invoke Invoke-LauncherSelfUpdate -ModuleName LocalAI -Times 2 -Exactly -ParameterFilter { $Context.InstallRoot -eq (Join-Path $TestDrive 'dispatcher-LocalAppData\Programs\local-ai-launcher') }
        Test-MutexFree -Name $lock | Should -BeTrue
    }

    It 'hands the warnings of that check to update, which counts them' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Tools', 'Rollback') }
        Mock Invoke-LauncherSelfUpdate -ModuleName LocalAI -MockWith {
            Write-Warning 'Could not check for a newer launcher (offline); it stays at v1.0.0.'
            $null
        }
        $run = Invoke-Dispatcher @{ Verb = 'update'; Root = $root; LockName = $lock } 3>$null
        $run.Code | Should -Be @(0)
        @((InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).Warnings) | Should -Be @('Could not check for a newer launcher (offline); it stays at v1.0.0.')
    }

    It 'leaves the own code of a git checkout alone and runs update' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Tools', 'Rollback') }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw "Unexpected request to $Uri" }
        $run = Invoke-Dispatcher @{ Verb = 'update'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*This launcher runs from the git checkout $(Split-Path $PSScriptRoot -Parent), so update leaves its own code alone*"
        (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).Verb | Should -Be 'update'
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'goes back with -Rollback instead of checking for a newer launcher, and runs no part of update itself' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Tools', 'Rollback') }
        Mock Invoke-LauncherRollback -ModuleName LocalAI -MockWith { 2 }
        Mock Invoke-LauncherSelfUpdate -ModuleName LocalAI
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext = $null }
        $run = Invoke-Dispatcher @{ Verb = 'update'; Rollback = $true; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(2)
        Should -Invoke Invoke-LauncherRollback -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Context.Rollback }
        Should -Invoke Invoke-LauncherSelfUpdate -ModuleName LocalAI -Times 0 -Exactly
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext } | Should -BeNullOrEmpty
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = '-Rollback for start'; Arguments = @{ Verb = 'start'; Rollback = $true }; Message = "*-Rollback does not apply to 'start'.*" }
        @{ Case = '-ActivateLauncher for status'; Arguments = @{ Verb = 'status'; ActivateLauncher = 'v1.1.0' }; Message = "*-ActivateLauncher does not apply to 'status'.*" }
        @{ Case = '-ActivateLauncher without a tag'; Arguments = @{ Verb = 'update'; ActivateLauncher = 'latest' }; Message = "*-ActivateLauncher 'latest' names no launcher version vX.Y.Z.*" }
        @{ Case = '-ActivateLauncher with -Rollback'; Arguments = @{ Verb = 'update'; ActivateLauncher = 'v1.1.0'; Rollback = $true }; Message = '*-ActivateLauncher does not go with -Rollback.*' }
    ) {
        $run = Invoke-Dispatcher ($Arguments + @{ Root = $root; LockName = $lock })
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike $Message
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'passes -ActivateLauncher on to update, and checks for no newer launcher in the run handed over to' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Tools', 'Rollback') }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw "Unexpected request to $Uri" }
        $run = Invoke-Dispatcher @{ Verb = 'update'; ActivateLauncher = 'v1.1.0'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        $run.Printed | Should -Not -BeLike '*git checkout*'
        (InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext }).ActivateLauncher | Should -BeExactly 'v1.1.0'
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'looks for a newer launcher after start only, keeping the exit code start gave' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbNoisy' }
        Mock Invoke-LauncherPassiveCheck -ModuleName LocalAI -MockWith { Write-Host 'The launcher v9.9.9 is out.' }
        $run = Invoke-Dispatcher @{ Verb = 'start'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*The launcher v9.9.9 is out.*'
        Should -Invoke Invoke-LauncherPassiveCheck -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Context.Verb -eq 'start' }
        $null = Invoke-Dispatcher @{ Verb = 'status'; Root = $root; LockName = $lock }
        Should -Invoke Invoke-LauncherPassiveCheck -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'waits for a key once the lock is free when start said that a newer launcher is out and ends with 0, keeping that exit code' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' }
        Mock Invoke-LauncherPassiveCheck -ModuleName LocalAI -MockWith {
            Write-Host 'The launcher v9.9.9 is out.'
            $true
        }
        $seen = @{ Free = $null }
        Mock Wait-LocalAIConsoleKey -ModuleName LocalAI -MockWith { $seen.Free = Test-MutexFree -Name $lock }
        $run = Invoke-Dispatcher @{ Verb = 'start'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike '*The launcher v9.9.9 is out.*'
        Should -Invoke Wait-LocalAIConsoleKey -ModuleName LocalAI -Times 1 -Exactly
        $seen.Free | Should -BeTrue
    }

    It 'does not wait for a key after start <Case>' -ForEach @(
        @{ Case = 'without a newer launcher'; Function = 'Invoke-TestVerbOk'; Noticed = $false; Code = 0 }
        @{ Case = 'that ends with 2, after which local-ai.cmd pauses'; Function = 'Invoke-TestVerbNoisy'; Noticed = $true; Code = 2 }
        @{ Case = 'that ends with 1, after which local-ai.cmd pauses'; Function = 'Invoke-TestVerbFailing'; Noticed = $true; Code = 1 }
    ) {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function $Function }
        Mock Invoke-LauncherPassiveCheck -ModuleName LocalAI -MockWith { $Noticed }
        Mock Wait-LocalAIConsoleKey -ModuleName LocalAI
        $run = Invoke-Dispatcher @{ Verb = 'start'; Root = $root; LockName = $lock }
        $run.Code | Should -Be @($Code)
        Should -Invoke Invoke-LauncherPassiveCheck -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Wait-LocalAIConsoleKey -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'hands over to another version only after it has stopped the transcript and released the lock, and returns its exit code' {
        Mock Get-LocalAIVerb -ModuleName LocalAI -MockWith { Get-TestVerbTable -Function 'Invoke-TestVerbOk' -Switches @('Tools', 'Rollback') }
        $seen = @{ Free = $null; Transcribing = $null }
        Mock Invoke-LauncherChild -ModuleName LocalAI -MockWith {
            $seen.Free = Test-MutexFree -Name $lock
            2
        }
        Mock Invoke-LauncherSelfUpdate -ModuleName LocalAI -MockWith {
            $seen.Transcribing = $Context.Hold.Transcribing
            InModuleScope -ModuleName LocalAI -Parameters @{ Context = $Context } -ScriptBlock {
                param($Context)
                Invoke-LauncherHandover -Context $Context -Script 'C:\Launcher\versions\v1.1.0\src\local-ai.ps1' -ArgumentList @('update', '-ActivateLauncher', 'v1.1.0')
            }
        }
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext = $null }
        $local = Join-Path $TestDrive 'dispatcher-LocalAppData'
        $output = @(Invoke-LocalAI -Verb 'update' -Root $root -LockName $lock -LocalAppData $local -ShellLocalAppData $local -AppData (Join-Path $TestDrive 'dispatcher-AppData') 3>&1 6>&1)
        @($output | Where-Object { $_ -is [int] }) | Should -Be @(2)
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) | Should -BeNullOrEmpty
        $seen.Transcribing | Should -BeTrue
        $seen.Free | Should -BeTrue
        InModuleScope -ModuleName LocalAI -ScriptBlock { $script:TestContext } | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter 'launcher-*-update.log').Count | Should -Be 1
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
