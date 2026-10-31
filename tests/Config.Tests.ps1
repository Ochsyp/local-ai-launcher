# -------------------------------------------------------
#                 LOCAL AI CONFIG TESTS
# -------------------------------------------------------
#
# Pester 6 checks on the tracked configuration and source files: defaults.psd1 must load and
# validate on its own, its hash and commit pins, shortcut folder and backup count must be set,
# it must list no superseded alias and no further variable for a service to inherit, the
# tracked Modelfile must match Model.Source, the ComfyUI workflow, node mapping and constraints
# must have the shape the image path needs, the files server's package.json and lockfile must
# pin Files.ServerVersion and the overridden MCP packages, and source files must stay ASCII.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeDiscovery and BeforeAll variables with the It blocks.')]
param()

BeforeDiscovery {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    # Windows PowerShell 5.1 ignores -Include together with -LiteralPath, so the extension
    # filter is a Where-Object.
    $sourceFiles = @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
            Where-Object { @('.ps1', '.psm1', '.psd1', '.cmd', '.Modelfile', '.json', '.txt', '.py') -contains $_.Extension } |
            Where-Object { $_.FullName -notmatch '\\\.git\\' } |
            ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); Path = $_.FullName } }
    )
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\LocalAI.psm1') -Force
    $defaultsPath = Join-Path $PSScriptRoot '..\config\defaults.psd1'
}

Describe 'config\defaults.psd1' {
    # Get-LocalAISettings applies every rule, including 64 hex characters or empty for *Sha256.
    It 'loads and passes validation without a user settings file' {
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        $settings.Model.Alias | Should -Be 'local-chat'
        $settings.OpenWebUI.Env.WEBUI_AUTH | Should -Be 'True'
        $settings.OpenWebUI.Env.ENABLE_PERSISTENT_CONFIG | Should -Be 'False'
    }

    It 'pins the model and the image checkpoint by SHA-256' {
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        $settings.Model.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $settings.Model.ProjectorSha256 | Should -Match '^[0-9a-f]{64}$'
        $settings.Images.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'pins ComfyUI to the v0.42.5 tag and its full lowercase commit' {
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        $settings.ComfyUI.Ref | Should -BeExactly 'v0.42.5'
        $settings.ComfyUI.Commit | Should -MatchExactly '^[0-9a-f]{40}$'
        $settings.ComfyUI.Commit | Should -BeExactly '483dae4326356b81de05d27aca3f433dd323cc25'
        $settings.ComfyUI.Repo | Should -BeExactly 'https://github.com/Comfy-Org/ComfyUI.git'
        # The time of that commit, so unpinned requirements resolve as they stood when v0.42.5 was cut.
        $settings.ComfyUI.ExcludeNewer | Should -BeExactly '2026-10-23T00:07:14Z'
    }

    It 'pins the checkpoint download to a full Hugging Face commit' {
        (Get-LocalAISettings -DefaultsPath $defaultsPath).Images.Revision | Should -MatchExactly '^[0-9a-f]{40}$'
    }

    It 'unloads local-chat before images through the image gate on port 8190, which src\image_gate.py serves' {
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        $settings.Ports.ImageGate | Should -Be 8190
        $settings.Images.UnloadChat | Should -BeTrue
        $settings.Images.UnloadTimeoutSeconds | Should -Be 30
        Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\src\image_gate.py') -PathType Leaf | Should -BeTrue
    }

    It "lets Open WebUI's pages and artifacts load nothing from other hosts, and runs no scripts in answers by default" {
        $env = (Get-LocalAISettings -DefaultsPath $defaultsPath).OpenWebUI.Env
        $policy = @($env.CONTENT_SECURITY_POLICY -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $policy | Should -Contain "default-src 'self'"
        $policy | Should -Contain "object-src 'none'"
        $policy | Should -Contain "base-uri 'self'"
        foreach ($directive in $policy) { $directive | Should -Not -BeLike '*http*' -Because 'no other host may be named' }
        $interface = ConvertFrom-LocalAIJson -Text $env.DEFAULT_INTERFACE_SETTINGS
        $interface.detectArtifacts | Should -BeFalse
        $interface.iframeSandboxAllowScripts | Should -BeFalse
    }

    It "puts the shortcuts in the Local AI folder of the Start menu's programs" {
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        $settings.Shortcuts.Folder | Should -Be (Join-Path ([Environment]::GetFolderPath('Programs')) 'Local AI')
    }

    # Model.SupersededAliases stays a list a settings.psd1 can fill; the rules for its names, never Model.Alias or Model.Source,
    # are tested with Get-LocalAISettings in LocalAI.Tests.ps1.
    It 'lists no superseded alias, as an empty list' {
        $defaults = Import-PowerShellDataFile -LiteralPath $defaultsPath
        ($defaults.Model.SupersededAliases -is [array]) | Should -BeTrue
        @($defaults.Model.SupersededAliases).Count | Should -Be 0
        @((Get-LocalAISettings -DefaultsPath $defaultsPath).Model.SupersededAliases) | Should -BeNullOrEmpty
    }

    # The lists of names Open WebUI and ComfyUI inherit beyond their own stay empty lists a settings.psd1 can fill; the rules for those
    # names are tested with Get-LocalAISettings, and the names each service inherits with Get-LocalAIService, in LocalAI.Tests.ps1.
    It 'names no further variable for Open WebUI or ComfyUI to inherit, as empty lists' {
        $defaults = Import-PowerShellDataFile -LiteralPath $defaultsPath
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        foreach ($service in 'OpenWebUI', 'ComfyUI') {
            ($defaults[$service].InheritEnvironment -is [array]) | Should -BeTrue -Because "$service.InheritEnvironment must be a list"
            @($defaults[$service].InheritEnvironment).Count | Should -Be 0
            @($settings[$service].InheritEnvironment) | Should -BeNullOrEmpty
        }
    }

    It 'keeps the 3 newest Open WebUI backups that update makes' {
        (Get-LocalAISettings -DefaultsPath $defaultsPath).Update.KeepBackups | Should -Be 3
    }

    It 'gives every winget package an Id, a Command and a Scope' {
        $packages = (Get-LocalAISettings -DefaultsPath $defaultsPath).Winget.Packages
        foreach ($name in $packages.Keys) {
            $packages[$name].Id | Should -Not -BeNullOrEmpty -Because "Winget.Packages.$name needs an Id"
            $packages[$name].Command | Should -Not -BeNullOrEmpty -Because "Winget.Packages.$name needs a Command"
        }
        $packages.Ollama.Scope | Should -Be 'user'
        $packages.Node.Scope | Should -Be 'machine'
    }
}

Describe 'config\local-chat.Modelfile' {
    BeforeAll {
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        $modelfile = Join-Path (Split-Path $PSScriptRoot -Parent) $settings.Model.Modelfile
        # Ollama reads one command per line; '#' starts a comment line.
        $commands = @([IO.File]::ReadAllLines($modelfile) | Where-Object { $_ -match '^\s*[^#\s]' } | ForEach-Object { $_.Trim() })
    }

    It 'builds FROM Model.Source, on a single FROM line' {
        @($commands | Where-Object { $_ -match '^FROM\s' }) | Should -BeExactly @("FROM $($settings.Model.Source)")
    }

    It 'sets num_ctx and num_predict' {
        @($commands | Where-Object { $_ -match '^PARAMETER num_ctx \d+$' }).Count | Should -Be 1
        @($commands | Where-Object { $_ -match '^PARAMETER num_predict \d+$' }).Count | Should -Be 1
    }
}

Describe 'config\comfyui' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath

        # Return the tracked JSON file at the repository-relative $Path as hashtables and lists.
        function Read-TrackedJson([string]$Path) {
            $text = [IO.File]::ReadAllText((Join-Path $repoRoot $Path))
            return ConvertTo-LocalAIHashtable -InputObject (ConvertFrom-Json -InputObject $text)
        }

        $workflow = Read-TrackedJson $settings.Images.Workflow
        # The list arrives as one object, like ConvertTo-LocalAIHashtable returns it.
        $nodes = Read-TrackedJson $settings.Images.WorkflowNodes
    }

    It 'parses both JSON files' {
        ($workflow -is [hashtable]) | Should -BeTrue
        $workflow.Count | Should -Be 7
        $nodes.Count | Should -BeGreaterThan 0
    }

    It 'has node <Id> of class <Class>' -ForEach @(
        @{ Id = '3'; Class = 'KSampler' }
        @{ Id = '4'; Class = 'CheckpointLoaderSimple' }
        @{ Id = '5'; Class = 'EmptyLatentImage' }
        @{ Id = '6'; Class = 'CLIPTextEncode' }
        @{ Id = '7'; Class = 'CLIPTextEncode' }
        @{ Id = '8'; Class = 'VAEDecode' }
        @{ Id = '9'; Class = 'PreviewImage' }
    ) {
        $workflow[$Id].class_type | Should -BeExactly $Class
    }

    It 'samples with the Lightning settings: seed 0, Images.Steps, CFG 2, dpmpp_sde with karras, full denoise' {
        $inputs = $workflow['3'].inputs
        $inputs.seed | Should -Be 0
        $inputs.steps | Should -Be $settings.Images.Steps
        $inputs.cfg | Should -Be 2
        $inputs.sampler_name | Should -BeExactly 'dpmpp_sde'
        $inputs.scheduler | Should -BeExactly 'karras'
        $inputs.denoise | Should -Be 1
    }

    It 'loads Images.File into one 1024x1024 latent and wires the nodes together' {
        $workflow['4'].inputs.ckpt_name | Should -BeExactly $settings.Images.File
        $workflow['5'].inputs.width | Should -Be 1024
        $workflow['5'].inputs.height | Should -Be 1024
        $workflow['5'].inputs.batch_size | Should -Be 1
        $workflow['3'].inputs.model | Should -Be @('4', 0)
        $workflow['3'].inputs.positive | Should -Be @('6', 0)
        $workflow['3'].inputs.negative | Should -Be @('7', 0)
        $workflow['3'].inputs.latent_image | Should -Be @('5', 0)
        $workflow['6'].inputs.clip | Should -Be @('4', 1)
        $workflow['7'].inputs.clip | Should -Be @('4', 1)
        $workflow['8'].inputs.samples | Should -Be @('3', 0)
        $workflow['8'].inputs.vae | Should -Be @('4', 2)
        $workflow['9'].inputs.images | Should -Be @('8', 0)
        $workflow['7'].inputs.text | Should -BeExactly ''
    }

    It 'maps prompt, model, width, height, n, steps and seed, each with an explicit key, and not the negative prompt' {
        $mapped = @{}
        foreach ($entry in $nodes) { $mapped[$entry.type] = "$($entry.node_ids -join ',')/$($entry.key)" }
        $mapped.Count | Should -Be $nodes.Count
        $mapped['prompt'] | Should -BeExactly '6/text'
        $mapped['model'] | Should -BeExactly '4/ckpt_name'
        $mapped['width'] | Should -BeExactly '5/width'
        $mapped['height'] | Should -BeExactly '5/height'
        $mapped['n'] | Should -BeExactly '5/batch_size'
        $mapped['steps'] | Should -BeExactly '3/steps'
        $mapped['seed'] | Should -BeExactly '3/seed'
        $mapped.ContainsKey('negative_prompt') | Should -BeFalse
    }

    It 'maps only nodes the workflow has, by text ids, and only inputs those nodes have' {
        foreach ($entry in $nodes) {
            foreach ($id in $entry.node_ids) {
                $id | Should -BeOfType [string]
                $workflow.ContainsKey($id) | Should -BeTrue -Because "node $id is mapped"
                $workflow[$id].inputs.ContainsKey($entry.key) | Should -BeTrue -Because "input $($entry.key) of node $id is mapped"
            }
        }
    }

    It 'passes Get-ImageWorkflow with the tracked settings' {
        $result = Get-ImageWorkflow -Settings $settings -RepoRoot $repoRoot
        ($result.Workflow | ConvertFrom-Json).'9'.class_type | Should -BeExactly 'PreviewImage'
        # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON list as one object.
        $parsed = ConvertFrom-Json -InputObject $result.Nodes
        $parsed.Count | Should -Be $nodes.Count
    }

    It 'pins torch and torchvision in the constraints' {
        $lines = @([IO.File]::ReadAllLines((Join-Path $repoRoot $settings.ComfyUI.Constraints)) | Where-Object { $_ -match '^\s*[^#\s]' } | ForEach-Object { $_.Trim() })
        $lines | Should -Contain 'torch==2.14.1'
        $lines | Should -Contain 'torchvision==0.29.1'
        $lines.Count | Should -Be 2
    }
}

Describe 'config\files-server' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $settings = Get-LocalAISettings -DefaultsPath $defaultsPath
        $folder = Join-Path $repoRoot $settings.Files.ServerPackage
        $name = '@modelcontextprotocol/server-filesystem'
        $manifest = ConvertFrom-LocalAIJson -Text ([IO.File]::ReadAllText((Join-Path $folder 'package.json')))
        # Windows PowerShell 5.1's ConvertFrom-Json refuses the lockfile's empty key for the root package.
        $lock = ConvertFrom-LocalAIJson -Text ([IO.File]::ReadAllText((Join-Path $folder 'package-lock.json')))
    }

    It 'is a private package that depends on exactly Files.ServerVersion of the server and nothing else' {
        $manifest.private | Should -BeTrue
        @($manifest.dependencies.Keys) | Should -Be @($name)
        $manifest.dependencies[$name] | Should -BeExactly $settings.Files.ServerVersion
        @($manifest.Keys | Sort-Object) | Should -Be @('dependencies', 'overrides', 'private')
    }

    It 'locks the server at Files.ServerVersion in a version 3 lockfile, with an integrity hash for every package' {
        $lock.lockfileVersion | Should -Be 3
        $lock.packages[''].dependencies[$name] | Should -BeExactly $settings.Files.ServerVersion
        $entry = $lock.packages["node_modules/$name"]
        $entry.version | Should -BeExactly $settings.Files.ServerVersion
        $entry.integrity | Should -Match '^sha512-[A-Za-z0-9+/]+={0,2}$'
        $entry.engines.node | Should -Match '^>=\d+'
        foreach ($key in @($lock.packages.Keys | Where-Object { $_ })) {
            $lock.packages[$key].integrity | Should -Match '^sha512-' -Because "$key needs an integrity hash"
            $lock.packages[$key].resolved | Should -BeLike 'https://registry.npmjs.org/*' -Because "$key comes from the npm registry"
            $lock.packages[$key].ContainsKey('hasInstallScript') | Should -BeFalse -Because 'npm ci runs with --ignore-scripts'
        }
    }

    It 'pins the version 2.0.1, the first with the 2026-10-25 path-check fixes' {
        $settings.Files.ServerVersion | Should -BeExactly '2.0.1'
    }

    It 'holds @modelcontextprotocol/server and core at exact versions through overrides, and the lockfile at those' {
        @($manifest.overrides.Keys | Sort-Object) | Should -Be @('@modelcontextprotocol/core', '@modelcontextprotocol/server')
        foreach ($package in $manifest.overrides.Keys) {
            $manifest.overrides[$package] | Should -MatchExactly '^\d+\.\d+\.\d+$' -Because "$package is pinned exactly"
            $lock.packages["node_modules/$package"].version | Should -BeExactly $manifest.overrides[$package]
        }
        # 2.4.0 of both was 4 days old when the lockfile was made; 2.3.1 satisfies the server's ^2.3.1.
        $manifest.overrides['@modelcontextprotocol/server'] | Should -BeExactly '2.3.1'
        $lock.packages["node_modules/$name"].dependencies['@modelcontextprotocol/server'] | Should -BeExactly '^2.3.1'
    }
}

Describe 'Files tool lists and mcpo pins' {
    BeforeAll {
        $files = (Get-LocalAISettings -DefaultsPath $defaultsPath).Files
    }

    It 'keeps the file tools off until Files.Root is set' {
        $files.Root | Should -BeExactly ''
    }

    It 'offers and hides disjoint sets of tools, hiding every write tool and read_file' {
        @($files.AllowedTools | Where-Object { $files.DisabledTools -contains $_ }) | Should -BeNullOrEmpty
        foreach ($tool in 'write_file', 'edit_file', 'create_directory', 'move_file', 'read_file') {
            $files.DisabledTools | Should -Contain $tool
        }
        # server-filesystem 2.0.1 serves these 14 tools.
        @(@($files.AllowedTools) + @($files.DisabledTools) | Sort-Object) | Should -Be @('create_directory', 'directory_tree', 'edit_file',
            'get_file_info', 'list_allowed_directories', 'list_directory', 'list_directory_with_sizes', 'move_file', 'read_file',
            'read_media_file', 'read_multiple_files', 'read_text_file', 'search_files', 'write_file')
    }

    It 'denies secret files and the folders that hold credentials, such as .ssh and .git' {
        foreach ($pattern in '*.key', '*.pem', '*secret*', '.git-credentials', '*.ppk', '.npmrc', '.netrc', '_netrc', 'credentials', 'credentials.*',
            'key4.db', 'logins.json', '.git', '.ssh', '.aws', '.azure', '.gnupg', '.kube', '.docker') {
            $files.DenyPatterns | Should -Contain $pattern
        }
    }

    It 'waits a short time for mcpo, so chat does not wait long for the file tools' {
        $files.HealthTimeoutSeconds | Should -Be 20
    }

    It 'installs mcpo 0.0.20 with mcp 1.30.0 and FastAPI below 0.145 on Python 3.12, resolved as of a fixed time' {
        $files.McpoVersion | Should -BeExactly '0.0.20'
        $files.McpoWith | Should -Be @('mcp==1.30.0', 'fastapi<0.145')
        $files.Python | Should -BeExactly '3.12'
        $files.McpoExcludeNewer | Should -MatchExactly '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }
}

Describe 'Source file encoding' {
    It '<Name> is ASCII-only' -ForEach $sourceFiles {
        # Latin-1 maps each byte to one character, so a BOM or UTF-8 sequence shows up as well.
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
        $match = [regex]::Match($text, '[^\x00-\x7F]')
        $match.Success | Should -BeFalse -Because "byte $($match.Index) of $Name is outside ASCII"
    }
}
