# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS: START
# -------------------------------------------------------
#
# Pester 6 tests for src\LocalAI.psm1 at start: the mcpo config, the files server checks, the Open
# WebUI environment, the service table, ports and processes, Start-LocalAIService,
# Wait-LocalAIService and Start-LocalAI. tests\LocalAI.TestSetup.ps1 imports the module and holds
# the shared helpers.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LocalAI.TestSetup.ps1')
}

Describe 'New-McpoConfig' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = Join-Path $folder 'mcpo.json'
        $settings = @{ Files = @{ Root = 'D:\AI-Folder\'; DisabledTools = @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file') } }
        $node = 'C:\Program Files\nodejs\node.exe'
        $script = 'C:\Users\User\AppData\Local\local-ai\files-server\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js'
    }

    It 'writes one stdio server files that runs node on the server script with --read-only and Files.Root, hiding Files.DisabledTools as well' {
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
        @($config.PSObject.Properties.Name) | Should -Be @('mcpServers')
        @($config.mcpServers.PSObject.Properties.Name) | Should -Be @('files')
        $files = $config.mcpServers.files
        @($files.PSObject.Properties.Name | Sort-Object) | Should -Be @('args', 'command', 'disabledTools')
        $files.command | Should -BeExactly $node
        @($files.args) | Should -Be @($script, '--read-only', 'D:\AI-Folder')
        @($files.disabledTools) | Should -Be @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file')
    }

    It 'returns the server entry it wrote, so start hashes exactly what mcpo reads' {
        $entry = New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $entry | Should -BeOfType [hashtable]
        $files = (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).mcpServers.files
        $entry.command | Should -BeExactly $files.command
        @($entry.args) | Should -Be @($files.args)
        @($entry.disabledTools) | Should -Be @($files.disabledTools)
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
        @((ConvertFrom-Json -InputObject ([Text.Encoding]::ASCII.GetString($bytes))).mcpServers.files.args)[-1] | Should -BeExactly $root
    }

    It 'hands the server a root typed in another case spelled as on disk, as Test-FilesRoot checked it' {
        $onDisk = Join-Path $folder 'AI-Files'
        $null = New-Item -ItemType Directory -Force -Path $onDisk
        $settings.Files.Root = $onDisk.ToUpperInvariant()
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $expected = & (Get-Module LocalAI) { param($Given) (Resolve-OnDiskPath -Path $Given).Path } $onDisk
        $expected | Should -BeLike '*\AI-Files'
        @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).mcpServers.files.args)[-1] | Should -BeExactly $expected
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
        @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).mcpServers.files.args)[-1] | Should -BeExactly $long
    }

    It 'replaces a config an earlier start wrote, leaving no .tmp' {
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        $settings.Files.Root = 'E:\Other'
        New-McpoConfig -Settings $settings -Path $path -NodePath $node -ServerScript $script
        @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).mcpServers.files.args)[-1] | Should -BeExactly 'E:\Other'
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
    }
}

Describe 'Get-McpoConfigHash' {
    BeforeAll {
        # Return the hash of a typical mcpo start, with the values $Change names replaced.
        function Get-TestConfigHash([hashtable]$Change = @{}) {
            $values = @{
                FilePath  = 'C:\uv\bin\mcpo.exe'
                Arguments = @('--host', '127.0.0.1', '--port', '8189', '--api-key', 'first-key', '--strict-auth', '--cors-allow-origins',
                    'http://127.0.0.1:8080', '--config', 'C:\local-ai\mcpo.json', '--log-level', 'WARNING')
                Command   = 'C:\Program Files\nodejs\node.exe'
                Server    = @('C:\server\dist\index.js', '--read-only', 'D:\AI-Folder')
                Disabled  = @('read_file', 'write_file', 'edit_file')
                Version   = '2.3.0'
                Lock      = 'a' * 64
            }
            foreach ($key in $Change.Keys) { $values[$key] = $Change[$key] }
            InModuleScope LocalAI -Parameters @{ Values = $values } {
                param($Values)
                Get-McpoConfigHash -FilePath $Values.FilePath -ArgumentList $Values.Arguments -ServerVersion $Values.Version -LockSha256 $Values.Lock -Server @{
                    command = $Values.Command; args = $Values.Server; disabledTools = $Values.Disabled }
            }
        }
    }

    It 'is 64 lowercase hex characters' {
        Get-TestConfigHash | Should -MatchExactly '^[0-9a-f]{64}$'
    }

    It 'stays the same for <Case>' -ForEach @(
        @{ Case = 'the same values'; Change = @{} }
        @{ Case = 'DisabledTools in another order'; Change = @{ Disabled = @('edit_file', 'read_file', 'write_file') } }
        @{ Case = 'another API key'; Change = @{ Arguments = @('--host', '127.0.0.1', '--port', '8189', '--api-key', 'second-key', '--strict-auth',
                    '--cors-allow-origins', 'http://127.0.0.1:8080', '--config', 'C:\local-ai\mcpo.json', '--log-level', 'WARNING') } }
    ) {
        Get-TestConfigHash -Change $Change | Should -BeExactly (Get-TestConfigHash)
    }

    It 'differs for <Case>' -ForEach @(
        @{ Case = 'another mcpo program'; Change = @{ FilePath = 'D:\uv\bin\mcpo.exe' } }
        @{ Case = 'another folder'; Change = @{ Server = @('C:\server\dist\index.js', '--read-only', 'D:\Other-Folder') } }
        @{ Case = 'a missing --read-only'; Change = @{ Server = @('C:\server\dist\index.js', 'D:\AI-Folder') } }
        @{ Case = 'another Node.js path'; Change = @{ Command = 'D:\nodejs\node.exe' } }
        @{ Case = 'another server script'; Change = @{ Server = @('D:\server\dist\index.js', '--read-only', 'D:\AI-Folder') } }
        @{ Case = 'another hidden tool'; Change = @{ Disabled = @('read_file', 'write_file', 'move_file') } }
        @{ Case = 'another port'; Change = @{ Arguments = @('--host', '127.0.0.1', '--port', '8199', '--api-key', 'first-key', '--strict-auth',
                    '--cors-allow-origins', 'http://127.0.0.1:8080', '--config', 'C:\local-ai\mcpo.json', '--log-level', 'WARNING') } }
        @{ Case = 'another Open WebUI port'; Change = @{ Arguments = @('--host', '127.0.0.1', '--port', '8189', '--api-key', 'first-key', '--strict-auth',
                    '--cors-allow-origins', 'http://127.0.0.1:8081', '--config', 'C:\local-ai\mcpo.json', '--log-level', 'WARNING') } }
        @{ Case = 'two server arguments written as one'; Change = @{ Server = @('C:\server\dist\index.js', '--read-only D:\AI-Folder') } }
        @{ Case = 'another installed server version'; Change = @{ Version = '2.4.0' } }
        @{ Case = 'another installed lockfile'; Change = @{ Lock = 'b' * 64 } }
    ) {
        Get-TestConfigHash -Change $Change | Should -Not -BeExactly (Get-TestConfigHash)
    }
}

Describe 'Get-FilesServerRefusedName' {
    It 'names the first part of <Path> that server-filesystem 2.3.0 refuses on Windows: <Expected>' -ForEach @(
        @{ Path = 'C:\AI\aux\root'; Expected = 'aux' }
        @{ Path = 'C:\AI\Con.d\root'; Expected = 'Con.d' }
        @{ Path = 'C:\AI\nul.txt'; Expected = 'nul.txt' }
        @{ Path = 'C:\AI\COM1'; Expected = 'COM1' }
        @{ Path = 'C:\AI\lpt9 .log\x'; Expected = 'lpt9 .log' }
        @{ Path = 'C:\AI\notes \root'; Expected = 'notes ' }
        @{ Path = 'C:\AI\notes..\root'; Expected = 'notes..' }
        @{ Path = 'C:\AI\aux\prn'; Expected = 'aux' }
        @{ Path = 'C:\AI-Files'; Expected = '' }
        @{ Path = 'C:\AI\console\auxiliary\com10\lpt0\nul-files'; Expected = '' }
        @{ Path = 'C:\AI\a.b\.hidden\x y'; Expected = '' }
    ) {
        $name = Invoke-ModuleFunction 'Get-FilesServerRefusedName' @{ Path = $Path }
        if ($Expected) { $name | Should -BeExactly $Expected } else { $name | Should -BeNullOrEmpty }
    }

    It 'takes COM and LPT with a superscript digit, as Windows does' {
        foreach ($code in 0x00B9, 0x00B2, 0x00B3) {
            $part = 'com' + [char]$code
            Invoke-ModuleFunction 'Get-FilesServerRefusedName' @{ Path = "C:\AI\$part\root" } | Should -BeExactly $part
        }
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
                McpoVersion = '0.0.20'; McpoPath = (Write-TestFile "$leaf\bin\mcpo.exe" 'program'); ServerVersion = $settings.Files.ServerVersion; LockSha256 = $lockSha
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
            'version' {
                $stamp.Files.ServerVersion = '2.0.1'
                $settings.Files.ServerVersion = '2.0.2'
            }
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
            $pinned = $settings.Files.ServerVersion
            Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Url -eq 'http://127.0.0.1:18189' -and $Key -eq $key -and $Version -eq $pinned -and $Root -eq 'D:\AI-Folder' -and
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

    It 'records cmd.exe as the path, also when the new process still names its first loaded module' {
        # Read at once, the path of a process can still be ntdll.dll, which no later check of the PID would match.
        Mock Start-Process -ModuleName LocalAI -MockWith {
            [pscustomobject]@{ Id = 4242; StartTime = $started; Path = 'C:\WINDOWS\SYSTEM32\ntdll.dll'; Handle = [IntPtr]::Zero; HasExited = $false }
        }
        $result = Start-LocalAIService -Service $service
        $result.Path | Should -Be $cmd
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
                ExcludeNewer = $Settings.Files.McpoExcludeNewer; ServerVersion = $Settings.Files.ServerVersion
                LockSha256 = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant()
                Script = (Write-TestFile "$leaf\files-server\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js" 'script')
                Node = @{ Path = (Write-TestFile "$leaf\nodejs\node.exe" 'program'); Version = '24.22.1' }
            }
            Write-LocalAIState -Path $Paths.InstallStamp -State $Complete
            return @{ Root = $served; Key = (Get-FilesKey -Path $Paths.FilesKey -Create) }
        }

        # Return the hash of the Open WebUI environment and inherited names a start computes for $Settings and $Paths with images and file
        # tools off, as Use-LocalAIService records it; -EnvironmentOnly leaves the names out, as a launcher without InheritEnvironment records it.
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

        # Return @{ ConfigSha256; EnvironmentSha256; OpenWebUI } that a start with the file tools computes for $Settings, $Paths, the stamp $Stamp
        # and the key $Key: mcpo's two record hashes and Open WebUI's environment hash.
        function Get-TestMcpoHash([hashtable]$Settings, [hashtable]$Paths, [hashtable]$Stamp, [string]$Key) {
            & (Get-Module LocalAI) {
                param($Settings, $Paths, $Stamp, $Key)
                $record = $Stamp.Files
                $server = Get-McpoServerEntry -Settings $Settings -NodePath $record.Node.Path -ServerScript $record.Script
                $services = @(Get-LocalAIService -Settings $Settings -Paths $Paths -OllamaUrl 'http://127.0.0.1:11434' -OpenWebUI $Stamp.OpenWebUI `
                        -Files @{ McpoPath = $record.McpoPath; McpoVersion = $record.McpoVersion; Key = $Key; Server = $server
                            ServerVersion = $record.ServerVersion; LockSha256 = $record.LockSha256 })
                $mcpo = @($services | Where-Object { $_.Name -eq 'Files' })[0]
                $web = @($services | Where-Object { $_.Name -eq 'OpenWebUI' })[0]
                @{
                    ConfigSha256      = $mcpo.ConfigSha256
                    EnvironmentSha256 = (Get-LocalAIEnvironmentHash -Environment $mcpo.Environment -InheritEnvironment $mcpo.InheritEnvironment)
                    OpenWebUI         = (Get-LocalAIEnvironmentHash -Environment $web.Environment -InheritEnvironment $web.InheritEnvironment)
                }
            } $Settings $Paths $Stamp $Key
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
                if ($Service.Name -eq 'Files') { $owners[18189] = $mcpoListener; return @{ Version = $settings.Files.ServerVersion; Listener = $mcpoListener } }
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
            @($config.mcpServers.files.args) | Should -Be @($complete.Files.Script, '--read-only', $tool.Root)
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
            $hashes = Get-TestMcpoHash -Settings $settings -Paths $paths -Stamp $complete -Key $tool.Key
            $record = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189; Listener = @{ Pid = 7950; StartTicks = 555; Path = $mcpoListener.Path }
                ConfigSha256 = $hashes.ConfigSha256; EnvironmentSha256 = $hashes.EnvironmentSha256 }
            Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = $record } }
            $owners[18189] = $mcpoListener
            Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if ($Record.Pid -eq 7950) { 'match' } else { 'other' } }
            $pin = $settings.Files.ServerVersion
            Mock Get-FilesServerVersion -ModuleName LocalAI -MockWith { $pin }
            $run = Invoke-StartVerb -Context $context
            $run.Code | Should -Be @(0)
            $run.Printed | Should -BeLike "*File tools server-filesystem $pin is already running at http://127.0.0.1:18189; reusing it.*"
            $events | Should -Be @('start OpenWebUI', 'wait OpenWebUI')
            Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Url -eq 'http://127.0.0.1:18189' -and $Key -eq $tool.Key -and $Root -eq $tool.Root -and $Version -eq $pin
            }
            Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
                $Service.Name -eq 'OpenWebUI' -and $Service.Environment['TOOL_SERVER_CONNECTIONS'] -like "*$($tool.Key)*"
            }
        }

        It 'stops an mcpo an earlier start left serving another root under matching hashes, warns once and starts Open WebUI without the file tools' {
            $hashes = Get-TestMcpoHash -Settings $settings -Paths $paths -Stamp $complete -Key $tool.Key
            $record = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189; Listener = @{ Pid = 7950; StartTicks = 555; Path = $mcpoListener.Path }
                ConfigSha256 = $hashes.ConfigSha256; EnvironmentSha256 = $hashes.EnvironmentSha256 }
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

        Context 'and an mcpo an earlier start left running' {
            BeforeEach {
                $hashes = Get-TestMcpoHash -Settings $settings -Paths $paths -Stamp $complete -Key $tool.Key
                $mcpoRecord = @{ Pid = 4500; StartTicks = 111; Path = 'C:\WINDOWS\system32\cmd.exe'; Port = 18189
                    Listener = @{ Pid = 7950; StartTicks = 555; Path = $mcpoListener.Path }
                    ConfigSha256 = $hashes.ConfigSha256; EnvironmentSha256 = $hashes.EnvironmentSha256 }
                $webRecord = @{ Pid = 4242; StartTicks = 111; Path = $exe; Port = 18431
                    Listener = @{ Pid = 1624; StartTicks = 222; Path = $python.Path }; EnvironmentSha256 = $hashes.OpenWebUI }
                Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = $mcpoRecord; OpenWebUI = $webRecord } }
                $owners[18189] = $mcpoListener
                $owners[18431] = $python
                $pids.Files = 4600
                $leaf = Split-Path $paths.Root -Leaf
                $pin = $settings.Files.ServerVersion
                $restartLine = "The file tools' settings changed since mcpo started, so start restarts it. A file-tool call running right now fails; ask again."
                Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith { if (@(7950, 1624) -contains $Record.Pid) { 'match' } else { 'other' } }
                Mock Get-OpenWebUIVersion -ModuleName LocalAI -MockWith { '0.12.4' }
                Mock Get-FilesServerVersion -ModuleName LocalAI -MockWith { $pin }
                Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { $events.Add("stop $Name"); $owners.Remove([int]$Record.Port); 'stopped' }
            }

            It 'stops and launches nothing while its settings are the same' {
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Warnings | Should -BeNullOrEmpty
                $events.Count | Should -Be 0
                $run.Printed | Should -Not -BeLike "*$restartLine*"
                $run.Printed | Should -BeLike '*File tools server-filesystem * is already running at http://127.0.0.1:18189; reusing it.*'
            }

            It 'records the hash of a new mcpo without its key, so a second start reuses it' {
                Write-LocalAIState -Path $paths.State -State @{}
                $owners.Clear()
                $pids.Files = 4500
                (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
                $state = Read-LocalAIState -Path $paths.State
                $state.Services.Files.ConfigSha256 | Should -BeExactly $hashes.ConfigSha256
                [IO.File]::ReadAllText($paths.State) | Should -Not -BeLike "*$($tool.Key)*"
                $events.Clear()
                $second = Invoke-StartVerb -Context $context
                $second.Code | Should -Be @(0)
                $second.Warnings | Should -BeNullOrEmpty
                $events.Count | Should -Be 0
            }

            It 'restarts it once, leaves a reused Open WebUI alone and returns 0 when <Case> changed' -ForEach @(
                @{ Case = 'Files.Root'; Change = 'root' }
                @{ Case = 'Files.DisabledTools'; Change = 'hidden' }
                @{ Case = 'the Node.js path'; Change = 'node' }
                @{ Case = 'the server script'; Change = 'script' }
            ) {
                switch ($Change) {
                    'root' {
                        $null = Write-TestFile "$leaf-other\notes.txt" 'notes'
                        $settings.Files.Root = Join-Path $TestDrive "$leaf-other"
                    }
                    'hidden' { $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'made_up_tool' }
                    'node' { $complete.Files.Node.Path = Write-TestFile "$leaf\other-nodejs\node.exe" 'program' }
                    'script' { $complete.Files.Script = Write-TestFile "$leaf\other-server\index.js" 'script' }
                }
                Write-LocalAIState -Path $paths.InstallStamp -State $complete
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Warnings | Should -BeNullOrEmpty
                $run.Printed | Should -BeLike "*$restartLine*"
                $events | Should -Be @('stop Files', 'start Files', 'wait Files')
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'Files' -and $Record.Pid -eq 4500 }
                Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 0 -Exactly
                $state = Read-LocalAIState -Path $paths.State
                $state.Services.Files.Pid | Should -Be 4600
                $state.Services.Files.ConfigSha256 | Should -Not -BeExactly $hashes.ConfigSha256
                $state.Services.OpenWebUI.Pid | Should -Be 4242
                $run.Printed | Should -BeLike '*File tools:*'
            }

            It 'restarts it on a changed Ports.Files, and warns that a reused Open WebUI keeps the old address' {
                $settings.Ports.Files = 18199
                Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'Files' } -MockWith {
                    $events.Add('wait Files')
                    $owners[18199] = $mcpoListener
                    @{ Version = $pin; Listener = $mcpoListener }
                }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $events | Should -Be @('stop Files', 'start Files', 'wait Files')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Service.Name -eq 'Files' -and $Service.Port -eq 18199 }
                $run.Warnings | Should -BeLike 'Open WebUI, which an earlier start left running, keeps the settings it started with*'
            }

            It 'restarts it when the names of the variables it inherits changed' {
                $mcpoRecord.EnvironmentSha256 = 'f' * 64
                Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = $mcpoRecord; OpenWebUI = $webRecord } }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Printed | Should -BeLike "*$restartLine*"
                $events | Should -Be @('stop Files', 'start Files', 'wait Files')
            }

            It 'restarts it when install changed <Case> under it, and leaves a reused Open WebUI alone' -ForEach @(
                @{ Case = 'the files server version'; Field = 'ServerVersion'; Older = '2.2.0' }
                @{ Case = 'the files server lockfile'; Field = 'LockSha256'; Older = 'a' * 64 }
            ) {
                # The running mcpo was recorded with the older value; the stamp on disk holds what install put in since.
                $current = $complete.Files[$Field]
                $complete.Files[$Field] = $Older
                $mcpoRecord.ConfigSha256 = (Get-TestMcpoHash -Settings $settings -Paths $paths -Stamp $complete -Key $tool.Key).ConfigSha256
                $complete.Files[$Field] = $current
                Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = $mcpoRecord; OpenWebUI = $webRecord } }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Warnings | Should -BeNullOrEmpty
                $run.Printed | Should -BeLike "*$restartLine*"
                $events | Should -Be @('stop Files', 'start Files', 'wait Files')
                Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 0 -Exactly
                $state = Read-LocalAIState -Path $paths.State
                $state.Services.Files.ConfigSha256 | Should -BeExactly $hashes.ConfigSha256
                $state.Services.OpenWebUI.Pid | Should -Be 4242
            }

            It 'launches nothing when another program takes a changed port right after the stop, and says the reused Open WebUI still offers the tools' {
                $settings.Ports.Files = 18199
                $other = [pscustomobject]@{ Id = 9200; Name = 'node'; Path = 'C:\tools\node.exe'; StartTicks = 5 }
                Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { $events.Add("stop $Name"); $owners.Remove([int]$Record.Port); $owners[18199] = $other; 'stopped' }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike '*The file tools are off for this start: Port 18199, which File tools needs, is held by node (PID 9200*'
                $run.Warnings | Should -BeLike '*still offers the file tools, but the mcpo they call is stopped*'
                $events | Should -Be @('stop Files')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'Files' }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Record.Pid -eq 9200 }
                (Read-LocalAIState -Path $paths.State).Services.ContainsKey('Files') | Should -BeFalse
            }

            It 'names the other program and says the reused Open WebUI still offers the tools when it took the same port as mcpo ended' {
                $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'made_up_tool'
                $other = [pscustomobject]@{ Id = 9200; Name = 'node'; Path = 'C:\tools\node.exe'; StartTicks = 5 }
                $gone = @{ Mcpo = $false }
                Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith {
                    if ($Record.Pid -eq 1624 -or ($Record.Pid -eq 7950 -and -not $gone.Mcpo)) { 'match' } else { 'other' }
                }
                # As the real one: mcpo has ended and a program that started since holds its port, which counts as stopped.
                Mock Stop-LocalAIService -ModuleName LocalAI -MockWith {
                    $events.Add("stop $Name")
                    $gone.Mcpo = $true
                    $owners[[int]$Record.Port] = $other
                    'stopped'
                }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike '*The file tools are off for this start: Port 18189, which File tools needs, is held by node (PID 9200*'
                $run.Warnings | Should -Not -BeLike '*did not stop for its restart*'
                $run.Warnings | Should -BeLike '*still offers the file tools, but the mcpo they call is stopped*'
                $events | Should -Be @('stop Files')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'Files' }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Record.Pid -eq 9200 }
                (Read-LocalAIState -Path $paths.State).Services.ContainsKey('Files') | Should -BeFalse
            }

            It 'stops once more and names the other program when its start time cannot be read, as for an elevated one' {
                $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'made_up_tool'
                $other = [pscustomobject]@{ Id = 9200; Name = 'node'; Path = 'C:\tools\node.exe'; StartTicks = $null }
                $gone = @{ Mcpo = $false }
                Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith {
                    if ($Record.Pid -eq 1624 -or ($Record.Pid -eq 7950 -and -not $gone.Mcpo)) { 'match' } else { 'other' }
                }
                # As the real one: mcpo has ended, but a program it cannot judge holds the port, so the first stop reports 'failed' and the next finds it gone.
                Mock Stop-LocalAIService -ModuleName LocalAI -MockWith {
                    $events.Add("stop $Name")
                    if ($gone.Mcpo) { return 'stale' }
                    $gone.Mcpo = $true
                    $owners[[int]$Record.Port] = $other
                    'failed'
                }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike '*The file tools are off for this start: Port 18189, which File tools needs, is held by node (PID 9200*'
                $run.Warnings | Should -Not -BeLike '*did not stop for its restart*'
                $events | Should -Be @('stop Files', 'stop Files')
                (Read-LocalAIState -Path $paths.State).Services.ContainsKey('Files') | Should -BeFalse
            }

            It 'still reports a failed restart when a failed stop leaves an mcpo this window cannot inspect' {
                $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'made_up_tool'
                $after = @{ Stop = $false }
                Mock Get-RecordedProcessState -ModuleName LocalAI -MockWith {
                    if ($Record.Pid -eq 1624) { 'match' } elseif ($Record.Pid -eq 7950) { if ($after.Stop) { 'unreadable' } else { 'match' } } else { 'other' }
                }
                Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { $after.Stop = $true; 'failed' }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike '*The file tools are off for this start: mcpo did not stop for its restart, so its new settings do not apply.*'
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'Files' }
                (Read-LocalAIState -Path $paths.State).Services.Files.Pid | Should -Be 4500
            }

            It 'restarts a record without ConfigSha256, from an older launcher, once, and reuses it on the next start' {
                $mcpoRecord.Remove('ConfigSha256')
                Write-LocalAIState -Path $paths.State -State @{ Services = @{ Files = $mcpoRecord; OpenWebUI = $webRecord } }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(0)
                $run.Printed | Should -BeLike "*An older launcher started mcpo, so start restarts it once with this launcher's settings. A file-tool call running right now fails; ask again.*"
                $run.Printed | Should -Not -BeLike "*$restartLine*"
                $events | Should -Be @('stop Files', 'start Files', 'wait Files')
                $events.Clear()
                (Invoke-StartVerb -Context $context).Code | Should -Be @(0)
                $events.Count | Should -Be 0
            }

            It 'launches no new mcpo and keeps the file tools off when it cannot be stopped' {
                $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'made_up_tool'
                Mock Stop-LocalAIService -ModuleName LocalAI -MockWith { 'failed' }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'Files' }
                Should -Invoke Get-FilesServerVersion -ModuleName LocalAI -Times 0 -Exactly
                $run.Warnings | Should -BeLike '*The file tools are off for this start: mcpo did not stop for its restart, so its new settings do not apply.*'
                $run.Warnings | Should -BeLike '*still serves the file tools, since it could not be stopped*'
                (Read-LocalAIState -Path $paths.State).Services.Files.Pid | Should -Be 4500
                $run.Printed | Should -Not -BeLike '*File tools:*'
            }

            It 'keeps the file tools off and says the reused Open WebUI still offers them when the restarted mcpo <Case>' -ForEach @(
                @{ Case = 'does not come up'; Fail = 'wait' }
                @{ Case = 'cannot be launched'; Fail = 'start' }
            ) {
                $settings.Files.DisabledTools = @($settings.Files.DisabledTools) + 'made_up_tool'
                if ($Fail -eq 'wait') {
                    Mock Wait-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'Files' } -MockWith { throw 'File tools exited with code 1 before it answered.' }
                } else {
                    Mock Start-LocalAIService -ModuleName LocalAI -ParameterFilter { $Service.Name -eq 'Files' } -MockWith { throw 'mcpo.exe cannot be launched.' }
                }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike '*The file tools are off for this start:*'
                $run.Warnings | Should -BeLike '*Open WebUI, which an earlier start left running, still offers the file tools, but the mcpo they call is stopped*'
                $state = Read-LocalAIState -Path $paths.State
                $state.Services.ContainsKey('Files') | Should -BeFalse
                $state.Services.OpenWebUI.Pid | Should -Be 4242
                $run.Printed | Should -Not -BeLike '*File tools:*'
            }

            It 'stops it and restarts nothing when the changed folder is refused' {
                $null = Write-TestFile "$leaf-refused\server.key" 'secret'
                $settings.Files.Root = Join-Path $TestDrive "$leaf-refused"
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Printed | Should -Not -BeLike "*$restartLine*"
                $events | Should -Be @('stop Files')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'Files' }
            }

            It 'restarts nothing and never stops another program that holds a changed port' {
                $settings.Ports.Files = 18199
                $owners[18199] = [pscustomobject]@{ Id = 9200; Name = 'node'; Path = 'C:\tools\node.exe'; StartTicks = 5 }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Warnings | Should -BeLike '*Port 18199, which File tools needs, is held by node (PID 9200*'
                $run.Printed | Should -Not -BeLike "*$restartLine*"
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'Files' }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Record.Pid -eq 9200 }
                Should -Invoke Stop-LocalAIService -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Name -eq 'Files' -and $Record.Pid -eq 4500 }
            }

            It 'does not restart it for a new files.key, since a reused Open WebUI holds the old one, and keeps the file tools off' {
                Remove-Item -LiteralPath $paths.FilesKey
                $null = Get-FilesKey -Path $paths.FilesKey -Create
                Mock Get-FilesServerVersion -ModuleName LocalAI -MockWith { throw 'The remote server returned an error: (401) Unauthorized.' }
                $run = Invoke-StartVerb -Context $context
                $run.Code | Should -Be @(2)
                $run.Printed | Should -Not -BeLike "*$restartLine*"
                $events | Should -Be @('stop Files')
                Should -Invoke Start-LocalAIService -ModuleName LocalAI -Times 0 -Exactly -ParameterFilter { $Service.Name -eq 'Files' }
                $run.Warnings | Should -BeLike '*The file tools are off for this start:*'
            }
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
                    if ($Service.Name -eq 'Files') { $owners[18189] = $mcpoListener; return @{ Version = $settings.Files.ServerVersion; Listener = $mcpoListener } }
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
