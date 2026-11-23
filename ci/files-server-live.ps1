# The live check of the files server, the last step of ci\test.ps1 on a CI runner. It installs the
# pinned mcpo and files server into a temporary folder on the system drive, starts them with the
# launcher's own settings, and fails unless they offer exactly Files.AllowedTools and that folder.
# Outside CI it exits 2 and installs nothing. Exits 0 when the check passes, else 1.

[CmdletBinding()]
param(
    # Set only for the child process that runs the check under the time limit.
    [switch]$Worker,
    [string]$WorkRoot
)

# Return an exception whose $Kind (Download, Difference or Start) picks the advice in Get-LiveFailureText.
function Get-LiveFailure {
    [CmdletBinding()]
    [OutputType([Exception])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Message
    )
    $failure = New-Object System.Exception -ArgumentList $Message
    $failure.Data['LiveKind'] = $Kind
    return $failure
}

# Return the line the log ends with, which says whether to re-run the job or look at the change.
function Get-LiveFailureText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Kind,
        [Parameter(Mandatory)][string]$Message
    )
    switch ($Kind) {
        'Download' { return "LIVE CHECK: a download failed, so nothing was checked. $Message Re-run the failed job." }
        'Difference' { return "LIVE CHECK: the real files server differs from what the launcher expects. $Message Look at the version change in this pull request." }
        'Start' { return "LIVE CHECK: mcpo did not start. $Message Its log is printed above." }
        default { return "LIVE CHECK: the check stopped. $Message" }
    }
}

# Return the path of the newest node.exe of at least $Minimum in the runner's tool cache that has npm beside it,
# as Install-FilesServerPackage needs. The runner's default node is older than the files server allows.
function Get-LiveNodePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ToolCache,
        [int]$Minimum = 24
    )
    $folder = Join-Path $ToolCache 'node'
    $found = @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $version = $null
            if ([version]::TryParse($_.Name, [ref]$version)) {
                [pscustomobject]@{
                    Version = $version
                    Node    = Join-Path $_.FullName 'x64\node.exe'
                    Npm     = Join-Path $_.FullName 'x64\node_modules\npm\bin\npm-cli.js'
                }
            }
        })
    $usable = @($found | Where-Object {
            $_.Version.Major -ge $Minimum -and (Test-Path -LiteralPath $_.Node -PathType Leaf) -and (Test-Path -LiteralPath $_.Npm -PathType Leaf)
        } | Sort-Object -Property Version -Descending)
    if ($usable.Count -eq 0) {
        $seen = if ($found.Count -gt 0) { @($found | ForEach-Object { $_.Version }) -join ', ' } else { 'none' }
        throw "The runner's tool cache has no Node.js $Minimum or newer with npm in $folder (found: $seen)."
    }
    return [string]$usable[0].Node
}

# Return a TCP port that is free on 127.0.0.1 right now. Another program can still take it before mcpo binds it.
function Get-LiveFreePort {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $probe = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $probe.Start()
    try {
        return ([Net.IPEndPoint]$probe.LocalEndpoint).Port
    } finally {
        $probe.Stop()
    }
}

# Return what $Action returns, trying it up to $Tries times while a program it runs fails, as a download does.
# Any other failure is a real difference, such as pins that disagree, and is thrown at once.
function Invoke-LiveDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$Tries = 3,
        [int]$DelaySeconds = 5
    )
    for ($try = 1; ; $try++) {
        try {
            return (& $Action)
        } catch {
            $message = $_.Exception.Message
            # The words Invoke-Native throws when uv, npm or pip ends with an error.
            if ($message -notmatch 'failed with exit code') { throw (Get-LiveFailure -Kind 'Difference' -Message $message) }
            if ($try -ge $Tries) { throw (Get-LiveFailure -Kind 'Download' -Message "$What failed $Tries times: $message") }
            Write-Host "$What failed (try $try of $Tries): $message Trying again."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# Install the uv that tests\requirements-live.txt pins into the folder $Prefix and return its Scripts folder.
function Install-LiveUv {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Prefix
    )
    $requirements = Join-Path $RepoRoot 'tests\requirements-live.txt'
    $arguments = @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--require-hashes', '--only-binary', ':all:',
        '--prefix', $Prefix, '-r', $requirements)
    $null = Invoke-Native -FilePath 'python' -ArgumentList $arguments -Console
    $scripts = Join-Path $Prefix 'Scripts'
    if (-not (Test-Path -LiteralPath (Join-Path $scripts 'uv.exe') -PathType Leaf)) { throw "pip left no uv.exe in $scripts." }
    return $scripts
}

# Return the launcher's settings with Files.Root $Root and Ports.Files $Port, through a settings.psd1 as on a PC, so they pass its validation.
function Get-LiveSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$Port
    )
    $null = [IO.Directory]::CreateDirectory($Paths.Root)
    [IO.File]::WriteAllText($Paths.Settings, "@{ Files = @{ Root = '$Root' }; Ports = @{ Files = $Port } }")
    return Get-LocalAISettings -DefaultsPath (Join-Path $RepoRoot 'config\defaults.psd1') -UserPath $Paths.Settings
}

# Delete $Path, waiting for handles of processes that just ended. A folder that stays only warns: the runner is discarded.
function Clear-LiveFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    for ($try = 1; $try -le 5; $try++) {
        if (-not [IO.Directory]::Exists($Path)) { return }
        try {
            # Unlike Remove-Item in 5.1, Directory.Delete removes a junction, as uv makes, without entering it.
            [IO.Directory]::Delete($Path, $true)
            return
        } catch {
            if ($try -eq 5) { Write-Warning "Could not remove $Path`: $($_.Exception.Message)" } else { Start-Sleep -Seconds 1 }
        }
    }
}

# Return $true once no process names $WorkRoot on its command line, which covers cmd, mcpo, its Python and the node server. After
# $TimeoutSeconds, ends those that remain and returns $false. Leaves out this process, whose own arguments name the folder.
function Wait-LiveProcessEnd {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [int]$TimeoutSeconds = 10
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        } catch {
            Write-Host "Cannot list the running processes: $($_.Exception.Message)"
            return $false
        }
        $left = @($all | Where-Object {
                $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($WorkRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
            })
        if ($left.Count -eq 0) { return $true }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "Still running after the stop: $(@($left | ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" }) -join ', ')."
    foreach ($process in $left) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    return $false
}

# Install and start the real parts under $WorkRoot and check once what mcpo offers, with Get-FilesServerVersion, the check 'start' makes.
# Returns the exit code: 0 for a pass, else 1 after a last line that says what to do. Ends mcpo, removes $WorkRoot and restores the variables.
function Invoke-LiveCheck {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkRoot,
        [string]$ToolCache = $env:RUNNER_TOOL_CACHE,
        [int]$StartTimeoutSeconds = 60,
        [int]$StopTimeoutSeconds = 10
    )
    $names = 'LOCALAPPDATA', 'Path', 'UV_CACHE_DIR', 'UV_TOOL_DIR', 'UV_TOOL_BIN_DIR', 'UV_PYTHON_INSTALL_DIR', 'UV_PYTHON_BIN_DIR'
    $savedVariables = @{}
    foreach ($name in $names) { $savedVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $launched = $null
    $code = 1
    try {
        $root = Join-Path $WorkRoot 'root'
        $null = [IO.Directory]::CreateDirectory($root)
        $env:LOCALAPPDATA = Join-Path $WorkRoot 'appdata'
        $env:UV_CACHE_DIR = Join-Path $WorkRoot 'uv\cache'
        $env:UV_TOOL_DIR = Join-Path $WorkRoot 'uv\tools'
        $env:UV_TOOL_BIN_DIR = Join-Path $WorkRoot 'uv\bin'
        $env:UV_PYTHON_INSTALL_DIR = Join-Path $WorkRoot 'uv\python'
        $env:UV_PYTHON_BIN_DIR = Join-Path $WorkRoot 'uv\python-bin'
        $paths = Get-LocalAIPaths
        $node = Get-LiveNodePath -ToolCache $ToolCache
        $scripts = Invoke-LiveDownload -What 'Installing uv' -Action { Install-LiveUv -RepoRoot $RepoRoot -Prefix (Join-Path $WorkRoot 'uv\package') }
        $env:Path = "$scripts;$env:Path"
        $settings = Get-LiveSetting -RepoRoot $RepoRoot -Paths $paths -Root $root -Port (Get-LiveFreePort)
        $mcpo = Invoke-LiveDownload -What 'Installing mcpo' -Action { Install-Mcpo -Settings $settings }
        $server = Invoke-LiveDownload -What 'Installing the files server' -Action {
            Install-FilesServerPackage -Settings $settings -Paths $paths -RepoRoot $RepoRoot -NodePath $node
        }
        $key = Get-FilesKey -Path $paths.FilesKey -Create
        # The runner hides this value in every later log line, should mcpo ever print its arguments.
        if ($env:GITHUB_ACTIONS -ceq 'true') { Write-Host "::add-mask::$key" }

        $service = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $port = Get-LiveFreePort
            $settings = Get-LiveSetting -RepoRoot $RepoRoot -Paths $paths -Root $root -Port $port
            $null = New-McpoConfig -Settings $settings -Path $paths.McpoConfig -NodePath $node -ServerScript $server.Script
            $files = @{ McpoPath = $mcpo.Path; McpoVersion = $mcpo.Version; Key = $key }
            $service = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl 'http://127.0.0.1:11434' -OpenWebUI @{} -Files $files |
                    Where-Object { $_.Name -eq 'Files' })[0]
            $launched = Start-LocalAIService -Service $service
            # Waits only for mcpo to answer with routes, so the real check below runs once and a wrong answer is not asked again.
            $ready = $service.Clone()
            $ready.Identity = {
                param([hashtable]$Service)
                $answer = Invoke-WebRequest -Uri $Service.HealthUrl -Headers @{ Authorization = "Bearer $($Service.Key)" } -UseBasicParsing -TimeoutSec 5
                $spec = ConvertFrom-LocalAIJson -Text ([Text.Encoding]::UTF8.GetString($answer.RawContentStream.ToArray()))
                if (-not ($spec -is [hashtable] -and $spec['paths'] -is [hashtable] -and $spec['paths'].Count -gt 0)) { throw 'mcpo answers, but offers no routes.' }
                'ready'
            }
            try {
                $null = Wait-LocalAIService -Service $ready -Process $launched.Process -TimeoutSeconds $StartTimeoutSeconds
                break
            } catch {
                $why = $_.Exception.Message
                # The likely cause is another program taking the port after Get-LiveFreePort looked.
                if ($launched.Process.HasExited -and $attempt -eq 1) {
                    $null = Stop-LocalAIService -Name 'Files' -Record $launched
                    $launched = $null
                    Write-Host "mcpo ended on port $port, so it gets one more try on a new port. $why"
                    continue
                }
                throw (Get-LiveFailure -Kind 'Start' -Message $why)
            }
        }
        try {
            $version = & $service.Identity $service
        } catch {
            throw (Get-LiveFailure -Kind 'Difference' -Message $_.Exception.Message)
        }
        Write-Host "LIVE CHECK: passed. mcpo serves $version with exactly the tools $(@($settings.Files.AllowedTools) -join ', ') and one folder."
        $code = 0
    } catch {
        $code = 1
        Write-Host (Get-LiveFailureText -Kind ([string]$_.Exception.Data['LiveKind']) -Message $_.Exception.Message)
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $savedVariables[$name], 'Process') }
        # What still runs decides, not the stop's result: taskkill also reports a failure when a process of the tree ended by
        # itself first, as uv's mcpo.exe does once its Python is gone.
        if ($launched) { $null = Stop-LocalAIService -Name 'Files' -Record $launched }
        if (-not (Wait-LiveProcessEnd -WorkRoot $WorkRoot -TimeoutSeconds $StopTimeoutSeconds)) {
            $code = 1
            Write-Host 'LIVE CHECK: mcpo could not be stopped.'
        }
        Clear-LiveFolder -Path $WorkRoot
    }
    return $code
}

# Run $ScriptPath -Worker in a child process and return its exit code. A child still running after $TimeoutSeconds is ended with
# everything it started, and $WorkRoot removed; returns 1.
function Invoke-LiveWithLimit {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$WorkRoot,
        [int]$TimeoutSeconds = 300
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo -ArgumentList (Join-Path $PSHOME 'powershell.exe')
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Worker -WorkRoot `"$WorkRoot`""
    # Process.Start keeps the handle, so the exit code survives a child that ends at once.
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        if ($process.WaitForExit($TimeoutSeconds * 1000)) { return $process.ExitCode }
        $said = New-Object System.Collections.Generic.List[string]
        # 128: the process ended before taskkill reached it. 255: a process of its tree did.
        $null = Invoke-Native -FilePath 'taskkill' -ArgumentList '/PID', ([string]$process.Id), '/T', '/F' -SuccessCode 0, 128, 255 -Capture $said
        $null = $process.WaitForExit(10000)
        Clear-LiveFolder -Path $WorkRoot
        Write-Host "LIVE CHECK: it did not finish within $TimeoutSeconds s and was stopped. Re-run the failed job; if it fails again, look at the last step above."
        return 1
    } finally {
        $process.Dispose()
    }
}

# Dot-sourcing loads the functions for the tests and runs nothing.
if ($MyInvocation.InvocationName -ne '.') {
    if ($env:GITHUB_ACTIONS -cne 'true') {
        Write-Host 'The live check installs real packages, so it runs only on a CI runner.'
        exit 2
    }
    $ErrorActionPreference = 'Stop'
    $repository = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repository 'src\LocalAI.psm1') -Force
    if ($Worker) { exit (Invoke-LiveCheck -RepoRoot $repository -WorkRoot $WorkRoot) }
    # On the system drive, as the runner's temp path can be an 8.3 name and its D: drive changes file system.
    $folder = Join-Path "$env:SystemDrive\" ('lai-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    exit (Invoke-LiveWithLimit -ScriptPath $PSCommandPath -WorkRoot $folder)
}
