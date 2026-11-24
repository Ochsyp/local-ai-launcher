# The live check of the files server, the last step of ci\test.ps1 on a CI runner. It installs the
# pinned mcpo and files server into a temporary folder on the system drive, starts them with the
# launcher's own settings, and fails unless they offer exactly Files.AllowedTools and that folder.
# Then it changes Files.Root, and fails unless start's own code restarts mcpo, which must serve the
# new folder alone. Last it starts mcpo with no hidden tools, and fails unless the server's --read-only
# alone withholds every tool but Get-LiveReadOnlyTool. Outside CI it exits 2 and installs nothing.
# Exits 0 when the check passes, else 1.

[CmdletBinding()]
param(
    # Set only for the child process that runs the check under the time limit.
    [switch]$Worker,
    [string]$WorkRoot
)

# Return an exception whose $Kind (Download, Setup, Difference or Start) picks the advice in Get-LiveFailureText.
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
        # uv and npm end the same way for a lost connection and for a pin that cannot be installed.
        'Download' { return "LIVE CHECK: an install step failed, so nothing was checked. $Message Re-run the failed job; if it fails the same way, look at the pins in this pull request." }
        'Setup' { return "LIVE CHECK: a setup step failed, so nothing was checked. $Message" }
        'Difference' { return "LIVE CHECK: the real files server differs from what the launcher expects. $Message Look at the version change in this pull request." }
        'Start' { return "LIVE CHECK: mcpo did not start. $Message Its log is printed above." }
        'Restart' { return "LIVE CHECK: the restart after a settings change failed. $Message Look at the start and stop code in this pull request." }
        'ReadOnly' {
            return ("LIVE CHECK: with --read-only alone and no hidden tools, the files server does not offer exactly the read tools this check expects. " +
                "$Message Look at the version change in this pull request: a write tool must never appear, and a new read tool belongs in " +
                'Get-LiveReadOnlyTool in ci\files-server-live.ps1 and in Files.DisabledTools or Files.AllowedTools.')
        }
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
# Any other failure, such as pins that disagree or a full disk, is thrown at once as a setup failure.
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
            if ($message -notmatch 'failed with exit code') { throw (Get-LiveFailure -Kind 'Setup' -Message $message) }
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
    $quoted = $Root -replace "'", "''"
    [IO.File]::WriteAllText($Paths.Settings, "@{ Files = @{ Root = '$quoted' }; Ports = @{ Files = $Port } }")
    return Get-LocalAISettings -DefaultsPath (Join-Path $RepoRoot 'config\defaults.psd1') -UserPath $Paths.Settings
}

# Run the launcher's function $Name with $Parameters inside its module, as start calls it: Use-LocalAIService, Complete-LocalAIService and
# Get-McpoServiceInput are not exported.
function Invoke-LiveLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Parameters
    )
    & (Get-Module LocalAI) { param($Command, $Arguments) & $Command @Arguments } $Name $Parameters
}

# Return the launcher's Files service for $Settings, built as start builds it: mcpo.json written by New-McpoConfig, and its entry, the installs of mcpo
# $Mcpo and of the server $Server, and the key $Key handed to Get-LocalAIService, so the service carries the ConfigSha256 a restart compares.
function Get-LiveService {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Mcpo,
        [Parameter(Mandatory)][hashtable]$Server,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$NodePath
    )
    $entry = New-McpoConfig -Settings $Settings -Path $Paths.McpoConfig -NodePath $NodePath -ServerScript $Server.Script
    # The fields of install-stamp.json's Files entry that start hands on.
    $record = @{ McpoPath = $Mcpo.Path; McpoVersion = $Mcpo.Version; ServerVersion = $Settings.Files.ServerVersion; LockSha256 = $Server.LockSha256 }
    $files = Invoke-LiveLauncher -Name 'Get-McpoServiceInput' -Parameters @{ Record = $record; Key = $Key; Server = $entry }
    return @(Get-LocalAIService -Settings $Settings -Paths $Paths -OllamaUrl 'http://127.0.0.1:11434' -OpenWebUI @{} -Files $files |
            Where-Object { $_.Name -eq 'Files' })[0]
}

# Return a copy of $Service whose Identity only waits for mcpo to answer with routes, within $TimeoutSeconds, so the real check runs once after
# it and a wrong answer is not asked again.
function Get-LiveReadyService {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $ready = $Service.Clone()
    $ready.TimeoutSeconds = $TimeoutSeconds
    $ready.Identity = {
        param([hashtable]$Service)
        $answer = Invoke-WebRequest -Uri $Service.HealthUrl -Headers @{ Authorization = "Bearer $($Service.Key)" } -UseBasicParsing -TimeoutSec 5
        $spec = ConvertFrom-LocalAIJson -Text ([Text.Encoding]::UTF8.GetString($answer.RawContentStream.ToArray()))
        if (-not ($spec -is [hashtable] -and $spec['paths'] -is [hashtable] -and $spec['paths'].Count -gt 0)) { throw 'mcpo answers, but offers no routes.' }
        # Start prints "<name> <this> is up at <URL>."
        '(mcpo with routes)'
    }
    return $ready
}

# Hand the running mcpo, which $State records as start does, the settings of $Service through start's own Use-LocalAIService, and wait for the new
# mcpo. Throws a Restart failure unless start printed the file tools' restart note, stopped the old mcpo without a red line, and started the new one,
# which must serve $Service.Root alone. Returns the version the new mcpo serves.
function Invoke-LiveRestart {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [int]$StartTimeoutSeconds = 60
    )
    $old = $State.Services['Files']
    $restarted = New-Object System.Collections.Generic.List[string]
    $said = New-Object System.Collections.Generic.List[string]
    $red = New-Object System.Collections.Generic.List[string]
    # Use-LocalAIService's result, the only output that is no line.
    $results = New-Object System.Collections.Generic.List[object]
    $parameters = @{ Service = $Service; State = $State; StatePath = $StatePath; Started = (New-Object System.Collections.Generic.List[string]); Restarted = $restarted }
    try {
        # Write-Host's lines arrive here as records, so the red ones, which the stop prints when it fails, can be told apart. Each is printed again.
        Invoke-LiveLauncher -Name 'Use-LocalAIService' -Parameters $parameters 6>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.InformationRecord]) {
                $line = [string]$_.MessageData
                Write-Host $line
                $said.Add($line)
                if ($_.MessageData.ForegroundColor -eq [ConsoleColor]::Red) { $red.Add($line) }
            } else {
                $results.Add($_)
            }
        }
    } catch {
        $why = if ($restarted.Contains('Files')) { "start restarted mcpo, but then: $($_.Exception.Message)" } else { "start did not restart mcpo: $($_.Exception.Message)" }
        throw (Get-LiveFailure -Kind 'Restart' -Message $why)
    }
    $problems = @(
        if (-not $restarted.Contains('Files')) { "start did not restart mcpo, although Files.Root changed; it reused the running one." }
        if (-not $said.Contains($Service.RestartNote)) { "start did not print the file tools' restart note, so the first start recorded no ConfigSha256 or another one." }
        if ($red.Count -gt 0) { "The stop for the restart said in red: $($red -join ' ')" }
        foreach ($part in @($old, $(if ($old -is [hashtable]) { $old.Listener }))) {
            if ($part -is [hashtable] -and (Test-RecordedProcess -Record $part)) { "The old mcpo (PID $($part.Pid)) still runs." }
        }
    )
    if ($problems.Count -gt 0) { throw (Get-LiveFailure -Kind 'Restart' -Message ($problems -join ' ')) }
    try {
        $null = Invoke-LiveLauncher -Name 'Complete-LocalAIService' -Parameters @{
            Service = (Get-LiveReadyService -Service $Service -TimeoutSeconds $StartTimeoutSeconds); Process = $results[0].Process; State = $State; StatePath = $StatePath
        }
    } catch {
        $why = $_.Exception.Message
        if ($why -notlike '*exited with code*') { Write-LiveLog -Service $Service }
        $why = $why.Replace("Its logs are $($Service.ErrLog) and $($Service.OutLog).", '').Trim()
        throw (Get-LiveFailure -Kind 'Restart' -Message "The new mcpo did not start: $why")
    }
    try {
        return (& $Service.Identity $Service)
    } catch {
        throw (Get-LiveFailure -Kind 'Restart' -Message "The new mcpo answers, but: $($_.Exception.Message)")
    }
}

# Return the tools server-filesystem 2.3.0 offers with --read-only alone: the five of Files.AllowedTools, and the five read tools
# Files.DisabledTools hides beside the write tools. A server version that changes this list fails the check until the list here is updated.
function Get-LiveReadOnlyTool {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @('read_text_file', 'list_directory', 'search_files', 'get_file_info', 'list_allowed_directories',
        'read_file', 'read_multiple_files', 'read_media_file', 'directory_tree', 'list_directory_with_sizes')
}

# Start mcpo once more as start would, on a new port and for Files.Root of $Settings, but with mcpo.json hiding no tool, so only the server's
# --read-only withholds any. Records it in $State.Services as 'ReadOnly' for the stop at the end. Throws a ReadOnly failure unless it offers
# exactly Get-LiveReadOnlyTool, which names any write tool or new tool it offers.
function Invoke-LiveReadOnlyCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Mcpo,
        [Parameter(Mandatory)][hashtable]$Server,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][hashtable]$State,
        [int]$StartTimeoutSeconds = 60
    )
    $open = Get-LiveSetting -RepoRoot $RepoRoot -Paths $Paths -Root $Settings.Files.Root -Port (Get-LiveFreePort)
    # After the settings' own checks, which would refuse a list without the write tools.
    $open.Files = $open.Files.Clone()
    $open.Files.DisabledTools = @()
    $service = Get-LiveService -Settings $open -Paths $Paths -Mcpo $Mcpo -Server $Server -Key $Key -NodePath $NodePath
    $launched = Start-LocalAIService -Service $service
    $State.Services['ReadOnly'] = $launched
    try {
        $null = Wait-LocalAIService -Service (Get-LiveReadyService -Service $service -TimeoutSeconds $StartTimeoutSeconds) -Process $launched.Process `
            -TimeoutSeconds $StartTimeoutSeconds
    } catch {
        $why = $_.Exception.Message
        if ($why -notlike '*exited with code*') { Write-LiveLog -Service $service }
        $why = $why.Replace("Its logs are $($service.ErrLog) and $($service.OutLog).", '').Trim()
        throw (Get-LiveFailure -Kind 'Start' -Message "This was its start with no hidden tools, for the read-only check: $why")
    }
    try {
        $null = Get-FilesServerVersion -Url $service.Url -Key $Key -Version $open.Files.ServerVersion -Tools (Get-LiveReadOnlyTool) -Root $service.Root
    } catch {
        throw (Get-LiveFailure -Kind 'ReadOnly' -Message $_.Exception.Message)
    }
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

# Return $true once no process runs from $WorkRoot or names it on its command line, which covers cmd, uv, mcpo, its Python and the
# node server. A listing that fails is tried again. After $TimeoutSeconds, ends those last seen and returns $false. Leaves out this
# process, whose own arguments name the folder.
function Wait-LiveProcessEnd {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [int]$TimeoutSeconds = 10
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $left = @()
    while ($true) {
        $problem = ''
        try {
            $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
            $left = @($all | Where-Object {
                    $_.ProcessId -ne $PID -and "$($_.ExecutablePath) $($_.CommandLine)".IndexOf($WorkRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
                })
            if ($left.Count -eq 0) { return $true }
        } catch {
            $problem = $_.Exception.Message
        }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($problem) { Write-Host "Cannot list the running processes: $problem" }
    if ($left.Count -gt 0) { Write-Host "Still running after the stop: $(@($left | ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" }) -join ', ')." }
    foreach ($process in $left) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    return $false
}

# Stop mcpo through the launcher. A stop that throws only prints, as Wait-LiveProcessEnd judges what still runs.
function Invoke-LiveStop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Record
    )
    try {
        $null = Stop-LocalAIService -Name 'Files' -Record $Record
    } catch {
        Write-Host "The stop failed: $($_.Exception.Message)"
    }
}

# Print the last $Lines lines of both logs of $Service, which the removal of the work folder would lose.
function Write-LiveLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [int]$Lines = 30
    )
    foreach ($log in $Service.ErrLog, $Service.OutLog) {
        Write-Host "--- Last $Lines lines of $(Split-Path -Path $log -Leaf) ---"
        try {
            foreach ($line in @(Get-Content -LiteralPath $log -Tail $Lines -ErrorAction Stop)) { Write-Host $line }
        } catch {
            Write-Host "It cannot be read: $($_.Exception.Message)"
        }
    }
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
    # As start's state.json: Use-LocalAIService records each mcpo here, and the stop at the end reads it.
    $state = @{ Services = @{} }
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
        $lists = @{ Started = (New-Object System.Collections.Generic.List[string]); Restarted = (New-Object System.Collections.Generic.List[string]) }
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $port = Get-LiveFreePort
            $settings = Get-LiveSetting -RepoRoot $RepoRoot -Paths $paths -Root $root -Port $port
            $service = Get-LiveService -Settings $settings -Paths $paths -Mcpo $mcpo -Server $server -Key $key -NodePath $node
            # As start launches it, so the record holds the hashes the restart below compares.
            $use = Invoke-LiveLauncher -Name 'Use-LocalAIService' -Parameters (@{ Service = $service; State = $state; StatePath = $paths.State } + $lists)
            try {
                # Adds the listening process to the record, as start does, so the restart finds the mcpo that holds the port.
                $null = Invoke-LiveLauncher -Name 'Complete-LocalAIService' -Parameters @{
                    Service = (Get-LiveReadyService -Service $service -TimeoutSeconds $StartTimeoutSeconds); Process = $use.Process; State = $state
                    StatePath = $paths.State
                }
                break
            } catch {
                $why = $_.Exception.Message
                # The likely cause is another program taking the port after Get-LiveFreePort looked.
                if ($use.Process.HasExited -and $attempt -eq 1) {
                    if ($state.Services['Files']) { Invoke-LiveStop -Record $state.Services['Files'] }
                    $state.Services.Remove('Files')
                    Write-Host "mcpo ended on port $port, so it gets one more try on a new port. $why"
                    continue
                }
                # Wait-LocalAIService prints the logs only for a process that ended.
                if ($why -notlike '*exited with code*') { Write-LiveLog -Service $service }
                # Its message names the log files, which are gone by the time the verdict prints.
                $why = $why.Replace("Its logs are $($service.ErrLog) and $($service.OutLog).", '').Trim()
                throw (Get-LiveFailure -Kind 'Start' -Message $why)
            }
        }
        try {
            $version = & $service.Identity $service
        } catch {
            throw (Get-LiveFailure -Kind 'Difference' -Message $_.Exception.Message)
        }

        # A new folder, as a user who changes Files.Root in settings.psd1 and runs start again.
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $root2 = Join-Path $WorkRoot 'root2'
        $null = [IO.Directory]::CreateDirectory($root2)
        $settings2 = Get-LiveSetting -RepoRoot $RepoRoot -Paths $paths -Root $root2 -Port $settings.Ports.Files
        $service2 = Get-LiveService -Settings $settings2 -Paths $paths -Mcpo $mcpo -Server $server -Key $key -NodePath $node
        $null = Invoke-LiveRestart -Service $service2 -State $state -StatePath $paths.State -StartTimeoutSeconds $StartTimeoutSeconds
        Write-Host "The restart for a new folder took $([int]$timer.Elapsed.TotalSeconds) s."

        # Both guards are on above, so this start proves the server's flag on its own. It writes the same logs, which the running mcpo holds
        # open, so that one ends first; as below, what still runs decides, not the stop's result.
        $timer.Restart()
        Invoke-LiveStop -Record $state.Services['Files']
        $state.Services.Remove('Files')
        if (-not (Wait-LiveProcessEnd -WorkRoot $WorkRoot -TimeoutSeconds $StopTimeoutSeconds)) {
            throw 'The restarted mcpo could not be stopped, so the start with --read-only alone did not run.'
        }
        Invoke-LiveReadOnlyCheck -RepoRoot $RepoRoot -Paths $paths -Settings $settings2 -Mcpo $mcpo -Server $server -Key $key -NodePath $node -State $state `
            -StartTimeoutSeconds $StartTimeoutSeconds
        Write-Host "The start with --read-only alone took $([int]$timer.Elapsed.TotalSeconds) s."

        $verdict = ("LIVE CHECK: passed. mcpo serves $version with exactly the tools $(@($settings.Files.AllowedTools) -join ', ') and one folder, " +
            "start restarted it for a new folder, which it then served alone, and --read-only alone withholds every tool but the " +
            "$(@(Get-LiveReadOnlyTool).Count) read tools.")
        $code = 0
    } catch {
        $code = 1
        $verdict = Get-LiveFailureText -Kind ([string]$_.Exception.Data['LiveKind']) -Message $_.Exception.Message
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $savedVariables[$name], 'Process') }
        # What still runs decides, not the stop's result: a stop that fails or throws leaves Wait-LiveProcessEnd to end what runs from
        # $WorkRoot, and reports it.
        foreach ($name in 'Files', 'ReadOnly') { if ($state.Services[$name]) { Invoke-LiveStop -Record $state.Services[$name] } }
        if (-not (Wait-LiveProcessEnd -WorkRoot $WorkRoot -TimeoutSeconds $StopTimeoutSeconds)) {
            $verdict = if ($code -eq 0) { 'LIVE CHECK: mcpo answered correctly, but could not be stopped.' } else { "$verdict mcpo could not be stopped either." }
            $code = 1
        }
        Clear-LiveFolder -Path $WorkRoot
    }
    # Last, because the stop prints its own lines and a reader looks at the end of the log.
    Write-Host $verdict
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
        [int]$TimeoutSeconds = 300,
        [int]$StopTimeoutSeconds = 10
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo -ArgumentList (Join-Path $PSHOME 'powershell.exe')
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Worker -WorkRoot `"$WorkRoot`""
    # Process.Start keeps the handle, so the exit code survives a child that ends at once.
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        if ($process.WaitForExit($TimeoutSeconds * 1000)) { return $process.ExitCode }
        $said = New-Object System.Collections.Generic.List[string]
        try {
            # 128: the process ended before taskkill reached it. 255: a process of its tree did.
            $null = Invoke-Native -FilePath 'taskkill' -ArgumentList '/PID', ([string]$process.Id), '/T', '/F' -SuccessCode 0, 128, 255 -Capture $said
        } catch {
            Write-Host "taskkill failed: $($_.Exception.Message) $($said -join ' ')"
        }
        # The child names the folder and uv runs from it, so this also ends what taskkill missed.
        $null = Wait-LiveProcessEnd -WorkRoot $WorkRoot -TimeoutSeconds $StopTimeoutSeconds
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
