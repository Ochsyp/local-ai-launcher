# -------------------------------------------------------
#                 LOCAL AI LAUNCHER CORE
# -------------------------------------------------------
#
# Functions behind src\local-ai.ps1: layered settings, the state file, native commands, PATH
# refresh, log rotation, the single-instance lock, keep-awake, winget prerequisites, the Ollama
# server and chat model, Open WebUI and its environment, ComfyUI, the image checkpoint and the
# image workflow, the image gate (image_gate.py beside this file), the read-only file tools (mcpo
# and the files server), the service table, the install, start, stop, status, update, uninstall and
# shortcuts verbs, the launcher's own releases (the release check and staging install.ps1 shares,
# the shim, activation, rollback and the uninstall cleanup) and the verb dispatcher.
# Every function takes its inputs as parameters, so importing the module runs nothing.

# Errors stop the module's functions whatever preference the importing session has.
$ErrorActionPreference = 'Stop'

# Return the launcher's runtime paths under $Root: Root, Logs, State (state.json), Settings (settings.psd1), InstallStamp
# (install-stamp.json), Backups, Modelfile (local-chat.Modelfile, which replaces the tracked one when it exists), FilesKey
# (files.key, mcpo's API key), McpoConfig (mcpo.json) and FilesServer (the files server's npm folder). Pure: touches no files.
function Get-LocalAIPaths {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The launcher design names this function.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Root = (Join-Path $env:LOCALAPPDATA 'local-ai')
    )
    return @{
        Root         = $Root
        Logs         = Join-Path $Root 'logs'
        State        = Join-Path $Root 'state.json'
        Settings     = Join-Path $Root 'settings.psd1'
        InstallStamp = Join-Path $Root 'install-stamp.json'
        Backups      = Join-Path $Root 'backups'
        Modelfile    = Join-Path $Root 'local-chat.Modelfile'
        FilesKey     = Join-Path $Root 'files.key'
        McpoConfig   = Join-Path $Root 'mcpo.json'
        FilesServer  = Join-Path $Root 'files-server'
    }
}

# Return the launcher's version, such as '1.2.0', from the VERSION file in $RepoRoot, trimmed; $null when that file is missing, as in a git
# checkout before the first release, cannot be read, or holds no version of the form X.Y.Z. Reads only.
function Get-LocalAIVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $path = $RepoRoot
    try {
        # Combine, unlike Join-Path, does not refuse a drive this PC does not have now.
        $path = [IO.Path]::Combine($RepoRoot, 'VERSION')
        if (-not [IO.File]::Exists($path)) { return $null }
        $text = [IO.File]::ReadAllText($path).Trim()
    } catch {
        Write-Verbose "Cannot read $path`: $($_.Exception.Message)"
        return $null
    }
    # [0-9], as \d also matches digits of other scripts.
    if ($text -cmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z') { return $text }
    return $null
}

# Return the table in the PowerShell data file at $Path without running any code in it. The text
# is read as UTF-8 unless a BOM names another encoding. Throws an error naming the file when it
# is missing, not UTF-8, not valid syntax or holds anything but plain data.
function Import-LocalAIDataFile {
    param([string]$Path)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    try {
        $text = [IO.File]::ReadAllText($fullPath, (New-Object Text.UTF8Encoding $false, $true))
        $tokens = $null
        $syntaxErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, $fullPath, [ref]$tokens, [ref]$syntaxErrors)
        if ($syntaxErrors.Count -gt 0) {
            $where = foreach ($syntaxError in $syntaxErrors) {
                'line {0}, column {1}: {2}' -f $syntaxError.Extent.StartLineNumber, $syntaxError.Extent.StartColumnNumber, $syntaxError.Message
            }
            throw ($where -join '; ')
        }
        $table = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
        if (-not $table) { throw 'It holds no table, @{ ... }.' }
        return $table.SafeGetValue()
    } catch {
        $reason = $_.Exception
        while ($reason.InnerException) { $reason = $reason.InnerException }
        $message = $reason.Message
        if ($reason -is [System.Text.DecoderFallbackException]) { $message = 'It is not UTF-8 text. Save it as UTF-8.' }
        throw "Cannot read settings file '$fullPath': $message"
    }
}

# Merge $Overlay into $Base in place: nested tables recurse, single values and lists replace.
# An unknown key, or a value whose kind (table, list, boolean, whole number) differs from the
# default, adds a message to $Errors instead. Tables whose dotted path is in $OpenMaps take any key.
function Merge-LocalAISetting {
    param(
        [hashtable]$Base,
        [hashtable]$Overlay,
        [string]$Prefix = '',
        [string[]]$OpenMaps = @(),
        [System.Collections.Generic.List[string]]$Errors
    )
    $open = $OpenMaps -contains $Prefix
    foreach ($key in @($Overlay.Keys)) {
        $path = if ($Prefix) { "$Prefix.$key" } else { [string]$key }
        $value = $Overlay[$key]
        $default = $Base[$key]
        if ($open) {
            $Base[$key] = $value
        } elseif (-not $Base.ContainsKey($key)) {
            $Errors.Add("Unknown setting '$path'.")
        } elseif ($default -is [hashtable]) {
            if ($value -is [hashtable]) {
                Merge-LocalAISetting -Base $default -Overlay $value -Prefix $path -OpenMaps $OpenMaps -Errors $Errors
            } else {
                $Errors.Add("Setting '$path' must be a table, @{ ... }.")
            }
        } elseif ($value -is [hashtable]) {
            $Errors.Add("Setting '$path' must be a single value or a list, not a table.")
        } elseif ($default -is [bool] -and $value -isnot [bool]) {
            $Errors.Add("Setting '$path' = '$value' must be `$true or `$false.")
        } elseif (($default -is [int] -or $default -is [long]) -and -not ($value -is [int] -or $value -is [long])) {
            $Errors.Add("Setting '$path' = '$value' must be a whole number.")
        } elseif ($default -is [array] -and $value -isnot [array]) {
            $Errors.Add("Setting '$path' = '$value' must be a list, @( ... ).")
        } else {
            $Base[$key] = $value
        }
    }
}

# Return a copy of $Value with %VAR% expanded in every string, recursing into tables and lists.
# Lists stay lists, even with one element; other values come back unchanged.
function Expand-LocalAISetting {
    param($Value)
    if ($Value -is [string]) { return [Environment]::ExpandEnvironmentVariables($Value) }
    if ($Value -is [hashtable]) {
        $copy = @{}
        foreach ($key in $Value.Keys) { $copy[$key] = Expand-LocalAISetting -Value $Value[$key] }
        return $copy
    }
    if ($Value -is [array]) {
        $items = @(foreach ($item in $Value) { Expand-LocalAISetting -Value $item })
        return , $items
    }
    return $Value
}

# Return one message per rule the merged $Settings break, nothing when all hold: each value against the rule table below, every Ports key
# distinct, Model.SupersededAliases never naming Model.Alias or Source, Files.AllowedTools and DisabledTools disjoint with every write tool hidden,
# and OpenWebUI.InheritEnvironment and ComfyUI.InheritEnvironment naming no variable Test-LocalAIWithheldName matches.
function Test-LocalAISetting {
    param([hashtable]$Settings)
    # Ports 1024 to 65535, *Sha256, ComfyUI.Commit and ExcludeNewer, Images.Revision, Model.Alias and SupersededAliases, Logs.Keep, Update.KeepBackups,
    # *TimeoutSeconds, the folders (OpenWebUI.DataDir, ComfyUI.Dir, Shortcuts.Folder, Files.Root), Images.Resolution and Steps, winget Scopes, Files,
    # the InheritEnvironment lists, and Launcher.Repo, CheckIntervalHours and KeepVersions.
    $rules = @(
        @{ Like = 'Ports.*'; Text = 'must be a whole number from 1024 to 65535'
            Test = { param($v) $v -is [int] -and $v -ge 1024 -and $v -le 65535 } }
        # A relative path would follow the current folder, and cmd.exe, which starts the services,
        # cannot run in a \\server\share folder.
        @{ Like = 'OpenWebUI.DataDir'; Text = 'must be a full path on a drive letter, such as %LOCALAPPDATA%\open-webui'
            Test = { param($v) $v -is [string] -and $v -match '^[A-Za-z]:\\' } }
        # The Python files a ComfyUI v0.42.5 .venv imports add up to 126 characters below the folder,
        # and Windows limits a path to 259 unless long paths are turned on.
        @{ Like = 'ComfyUI.Dir'; Text = 'must be a full path on a drive letter of at most 133 characters, such as %USERPROFILE%\ComfyUI'
            Test = { param($v) $v -is [string] -and $v -match '^[A-Za-z]:\\' -and $v.Length -le 133 } }
        @{ Like = '*Sha256'; Text = 'must be 64 hexadecimal characters or empty'
            Test = { param($v) $v -is [string] -and $v -match '^(?:[0-9a-fA-F]{64})?\z' } }
        # git rev-parse prints a commit in lowercase. A branch name such as 'main' would move under the pin.
        @{ Like = 'ComfyUI.Commit'; Text = 'must be a git commit: 40 lowercase hexadecimal characters'
            Test = { param($v) $v -is [string] -and $v -cmatch '^[0-9a-f]{40}\z' } }
        @{ Like = 'Images.Revision'; Text = 'must be a git commit: 40 lowercase hexadecimal characters'
            Test = { param($v) $v -is [string] -and $v -cmatch '^[0-9a-f]{40}\z' } }
        @{ Like = 'ComfyUI.ExcludeNewer'; Text = "must be a UTC time such as '2026-10-23T00:07:14Z'"
            Test = { param($v) $v -is [string] -and $v -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z' } }
        # Open WebUI splits IMAGE_SIZE at a lowercase 'x' and reads each side with int().
        @{ Like = 'Images.Resolution'; Text = "must be <width>x<height>, such as '1024x1024'"
            Test = { param($v) $v -is [string] -and $v -cmatch '^\d+x\d+\z' } }
        @{ Like = 'Images.Steps'; Text = 'must be a whole number from 1 to 100'
            Test = { param($v) $v -is [int] -and $v -ge 1 -and $v -le 100 } }
        @{ Like = 'Model.Alias'; Text = 'may use only a-z, 0-9, ".", "_" and "-"'
            Test = { param($v) $v -is [string] -and $v -cmatch '^[a-z0-9._-]+\z' } }
        # Passed to 'ollama rm' as one argument.
        @{ Like = 'Model.SupersededAliases'; Text = "must list Ollama model names such as 'old-chat' or 'old-chat:latest'"
            Test = { param($v) @($v | Where-Object { -not ($_ -is [string] -and $_ -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*(?::[A-Za-z0-9._-]+)?\z') }).Count -eq 0 } }
        @{ Like = 'Shortcuts.Folder'; Text = 'must be a full path on a drive letter, such as %APPDATA%\Microsoft\Windows\Start Menu\Programs\Local AI'
            Test = { param($v) $v -is [string] -and $v -match '^[A-Za-z]:\\' } }
        @{ Like = 'Logs.Keep'; Text = 'must be a whole number from 1 to 20'
            Test = { param($v) $v -is [int] -and $v -ge 1 -and $v -le 20 } }
        @{ Like = 'Update.KeepBackups'; Text = 'must be a whole number from 1 to 20'
            Test = { param($v) $v -is [int] -and $v -ge 1 -and $v -le 20 } }
        @{ Like = '*TimeoutSeconds'; Text = 'must be a whole number from 1 to 3600'
            Test = { param($v) $v -is [int] -and $v -ge 1 -and $v -le 3600 } }
        @{ Like = 'Winget.Packages.*.Scope'; Text = "must be 'user' or 'machine'"
            Test = { param($v) $v -is [string] -and @('user', 'machine') -contains $v } }
        @{ Like = 'Files.Root'; Text = 'must be empty or a full path on a drive letter, such as C:\AI-Files'
            Test = { param($v) $v -is [string] -and ($v -eq '' -or $v -match '^[A-Za-z]:\\') } }
        # mcpo is installed with ==, and package.json pins the server exactly.
        @{ Like = 'Files.*Version'; Text = "must be an exact version such as '2.0.1'"
            Test = { param($v) $v -is [string] -and $v -cmatch '^\d+\.\d+\.\d+\z' } }
        @{ Like = 'Files.Python'; Text = "must be a Python minor version such as '3.12'"
            Test = { param($v) $v -is [string] -and $v -cmatch '^\d+\.\d+\z' } }
        @{ Like = 'Files.McpoWith'; Text = "must list package requirements such as 'mcp==1.30.0'"
            Test = { param($v) @($v | Where-Object { -not ($_ -is [string] -and $_ -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\s*(?:===|==|!=|~=|<=|>=|<|>)\s*[A-Za-z0-9.*+!_-]+(?:\s*,\s*(?:===|==|!=|~=|<=|>=|<|>)\s*[A-Za-z0-9.*+!_-]+)*\z') }).Count -eq 0 } }
        @{ Like = 'Files.McpoExcludeNewer'; Text = "must be empty or a UTC time such as '2026-10-13T00:00:00Z'"
            Test = { param($v) $v -is [string] -and $v -cmatch '^(?:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)?\z' } }
        # Open WebUI splits its tool filter list at ','.
        @{ Like = 'Files.*Tools'; Text = 'must list tool names made of lowercase letters, digits and "_"'
            Test = { param($v) @($v | Where-Object { -not ($_ -is [string] -and $_ -cmatch '^[a-z0-9_]+\z') }).Count -eq 0 } }
        @{ Like = 'Files.DenyPatterns'; Text = 'must list file or folder name patterns, none of them empty'
            Test = { param($v) @($v | Where-Object { -not ($_ -is [string] -and $_.Trim()) }).Count -eq 0 } }
        # OpenWebUI's and ComfyUI's, not a key of the open map OpenWebUI.Env. Start-LocalAIService compares whole names, so a
        # pattern such as HF_* or a %VAR% left unexpanded would match nothing.
        @{ Like = '*UI.InheritEnvironment'; Text = "must list variable names such as 'HTTPS_PROXY': letters, digits, '_', '.', '-' and parentheses"
            Test = { param($v) @($v | Where-Object { -not ($_ -is [string] -and $_ -cmatch '^[A-Za-z_][A-Za-z0-9_.()-]*\z') }).Count -eq 0 } }
        # Part of the API address update asks; a GitHub owner has at most 39 characters, a repository at most 100. No name that ends in a dot, which .NET drops
        # from the address, as Get-LauncherRelease checks too.
        @{ Like = 'Launcher.Repo'; Text = "must be <owner>/<repository> on GitHub, such as 'Ochsyp/local-ai-launcher'"
            Test = { param($v) $v -is [string] -and $v -cmatch '\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{0,99}[A-Za-z0-9_-]\z' } }
        @{ Like = 'Launcher.CheckIntervalHours'; Text = 'must be a whole number from 1 to 168'
            Test = { param($v) $v -is [int] -and $v -ge 1 -and $v -le 168 } }
        # At least the active version and the one update -Rollback goes back to.
        @{ Like = 'Launcher.KeepVersions'; Text = 'must be a whole number from 2 to 5'
            Test = { param($v) $v -is [int] -and $v -ge 2 -and $v -le 5 } }
    )
    # Flatten nested tables into dotted paths; lists and single values are the leaves.
    $leaves = @{}
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue(@('', $Settings))
    while ($pending.Count -gt 0) {
        $prefix, $table = $pending.Dequeue()
        foreach ($key in $table.Keys) {
            $path = if ($prefix) { "$prefix.$key" } else { [string]$key }
            if ($table[$key] -is [hashtable]) { $pending.Enqueue(@($path, $table[$key])) }
            else { $leaves[$path] = $table[$key] }
        }
    }
    foreach ($path in ($leaves.Keys | Sort-Object)) {
        foreach ($rule in $rules) {
            if ($path -clike $rule.Like -and -not (& $rule.Test $leaves[$path])) {
                "Setting '$path' = '$($leaves[$path])' $($rule.Text)."
            }
        }
    }
    $ports = @($leaves.Keys | Where-Object { $_ -clike 'Ports.*' } | Sort-Object)
    foreach ($group in ($ports | Group-Object { $leaves[$_] } | Where-Object { $_.Count -gt 1 })) {
        "Settings $($group.Group -join ', ') all use port $($group.Name); each needs its own."
    }
    if ($leaves.ContainsKey('Model.SupersededAliases')) {
        # Ollama adds the tag latest to a name without one.
        $kept = @(foreach ($key in 'Model.Alias', 'Model.Source') { if ($leaves[$key]) { [string]$leaves[$key]; "$($leaves[$key]):latest" } })
        $named = @(@($leaves['Model.SupersededAliases']) | Where-Object { $kept -contains $_ -or $kept -contains "${_}:latest" })
        if ($named.Count -gt 0) { "Setting 'Model.SupersededAliases' names $($named -join ', '), which Model.Alias or Model.Source uses; update never removes those." }
    }
    if ($leaves.ContainsKey('Files.AllowedTools') -and $leaves.ContainsKey('Files.DisabledTools')) {
        $allowed = @($leaves['Files.AllowedTools'])
        $disabled = @($leaves['Files.DisabledTools'])
        if ($allowed.Count -eq 0) { "Setting 'Files.AllowedTools' must name at least one tool." }
        $both = @($allowed | Where-Object { $disabled -contains $_ })
        if ($both.Count -gt 0) { "Settings Files.AllowedTools and Files.DisabledTools both name $($both -join ', '); a tool is either offered or hidden." }
        # The tools of server-filesystem 2.2.0 that change files; append_file and copy_file are new in 2.2.0.
        $open = @(foreach ($tool in 'write_file', 'edit_file', 'create_directory', 'move_file', 'append_file', 'copy_file') { if ($disabled -notcontains $tool) { $tool } })
        if ($open.Count -gt 0) { "Setting 'Files.DisabledTools' must hide every write tool, but leaves out $($open -join ', ')." }
    }
    # Start-LocalAIService withholds these whatever a list names, so naming one would only mislead.
    foreach ($path in @($leaves.Keys | Where-Object { $_ -clike '*UI.InheritEnvironment' } | Sort-Object)) {
        $withheld = @(@($leaves[$path]) | Where-Object { $_ -is [string] -and $_ -and (Test-LocalAIWithheldName -Name $_) })
        if ($withheld.Count -gt 0) {
            ("Setting '$path' names $($withheld -join ', '), which no service gets: start withholds every variable whose name ends in _TOKEN or " +
                '_API_KEY, and those that point Python or Node.js at other code, such as PYTHONPATH and NODE_OPTIONS.')
        }
    }
}

# Load the tracked defaults, deep-merge the optional user file over them, expand %VAR% in every
# string and validate. Returns the merged hashtable, or throws one error listing every unknown
# key and invalid value. Tables named in -OpenMaps (dotted paths) accept keys absent from defaults.
function Get-LocalAISettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The launcher design names this function.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$DefaultsPath,
        [string]$UserPath,
        [string[]]$OpenMaps = @('OpenWebUI.Env')
    )
    $settings = Import-LocalAIDataFile -Path $DefaultsPath
    $problems = New-Object System.Collections.Generic.List[string]
    $source = $DefaultsPath
    if ($UserPath -and (Test-Path -LiteralPath $UserPath -PathType Leaf)) {
        $user = Import-LocalAIDataFile -Path $UserPath
        Merge-LocalAISetting -Base $settings -Overlay $user -OpenMaps $OpenMaps -Errors $problems
        $source = "$DefaultsPath with $UserPath"
    }
    $settings = Expand-LocalAISetting -Value $settings
    foreach ($problem in @(Test-LocalAISetting -Settings $settings)) { $problems.Add($problem) }
    if ($problems.Count -gt 0) {
        throw ("Invalid settings ({0}):`n  {1}" -f $source, ($problems -join "`n  "))
    }
    return $settings
}

# Convert ConvertFrom-Json output (PSCustomObject, object[]) or other dictionaries into hashtables
# and arrays, recursively, since Windows PowerShell 5.1 has no -AsHashtable. Arrays stay arrays even
# with one element; strings, numbers, booleans and $null come back as they are.
function ConvertTo-LocalAIHashtable {
    [CmdletBinding()]
    [OutputType([hashtable], [object[]])]
    param(
        [AllowNull()]$InputObject
    )
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-LocalAIHashtable -InputObject $property.Value
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) { $table[$key] = ConvertTo-LocalAIHashtable -InputObject $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [array]) {
        $items = @(foreach ($item in $InputObject) { ConvertTo-LocalAIHashtable -InputObject $item })
        return , $items
    }
    return $InputObject
}

# Return the JSON $Text as hashtables and lists, as ConvertTo-LocalAIHashtable makes them, also when an object has an empty
# key, such as the root package of an npm lockfile, which Windows PowerShell 5.1's ConvertFrom-Json refuses. Loads
# System.Web.Extensions for its JavaScriptSerializer. Throws when $Text is not JSON.
function ConvertFrom-LocalAIJson {
    [CmdletBinding()]
    [OutputType([hashtable], [object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    return , (ConvertTo-LocalAIHashtable -InputObject $serializer.DeserializeObject($Text))
}

# Return the JSON state file at $Path as a hashtable; a missing file gives an empty one.
# Throws an error naming the file when it is not valid JSON or not a JSON object.
function Read-LocalAIState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not [IO.File]::Exists($fullPath)) { return @{} }
    try {
        $state = ConvertTo-LocalAIHashtable -InputObject (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($fullPath)))
    } catch {
        throw "State file '$fullPath' is not valid JSON: $($_.Exception.Message)"
    }
    if ($state -isnot [hashtable]) { throw "State file '$fullPath' does not hold a JSON object." }
    return $state
}

# Return $Value as plain JSON data (tables with string keys, lists, strings, numbers, booleans,
# $null), with PowerShell's extra properties stripped so ConvertTo-Json cannot grow them. Any
# other type throws naming its dotted $Path; a DateTime is refused because JSON loses its precision.
function ConvertTo-LocalAIStateValue {
    param($Value, [string]$Path)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $Value.Keys) {
            $keyPath = if ($Path) { "$Path.$key" } else { [string]$key }
            $table[[string]$key] = ConvertTo-LocalAIStateValue -Value $Value[$key] -Path $keyPath
        }
        return $table
    }
    if ($Value -is [System.Collections.IList]) {
        $items = @(for ($i = 0; $i -lt $Value.Count; $i++) { ConvertTo-LocalAIStateValue -Value $Value[$i] -Path "$Path[$i]" })
        return , $items
    }
    $base = $Value.PSObject.BaseObject
    if ($base -is [datetime]) {
        throw "State value '$Path' is a DateTime, which JSON brings back as UTC cut to milliseconds. Store its .ToUniversalTime().Ticks instead."
    }
    $code = [Type]::GetTypeCode($base.GetType())
    $plain = $code -eq 'String' -or $code -eq 'Boolean' -or ($code -ge [TypeCode]::SByte -and $code -le [TypeCode]::Decimal)
    if ($base -is [enum] -or -not $plain) {
        throw "State value '$Path' has type [$($base.GetType().FullName)]; state holds only tables, lists, strings, numbers and booleans."
    }
    return $base
}

# Save $State to $Path as UTF-8 JSON without BOM (-Ascii: characters above 0x7F as \uXXXX escapes, for readers using the ANSI
# code page) through a flushed .tmp that replaces the file in one step, so a crash never leaves it truncated. Values must be plain
# data (store times as [long] UTC ticks); anything else, or a failed save, throws naming the path and removes the .tmp.
function Write-LocalAIState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State,
        [switch]$Ascii
    )
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $json = ConvertTo-Json -InputObject (ConvertTo-LocalAIStateValue -Value $State) -Depth 10
    # Outside strings JSON is ASCII, so only string characters change.
    if ($Ascii) { $json = [regex]::Replace($json, '[^\x00-\x7F]', { param($found) '\u{0:x4}' -f [int][char]$found.Value }) }
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($json)
    $temp = "$fullPath.tmp"
    try {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
        $stream = New-Object IO.FileStream -ArgumentList $temp, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temp, $fullPath, [NullString]::Value)
        } else {
            [IO.File]::Move($temp, $fullPath)
        }
    } catch {
        $reason = $_.Exception
        while ($reason.InnerException) { $reason = $reason.InnerException }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw "Cannot save state file '$fullPath': $($reason.Message)"
    }
}

# Return $Argument written so that 5.1's legacy argument passing delivers it unchanged under the
# CommandLineToArgvW rules (empty, spaces, quotes, trailing '\'); -Quote adds the quotes 5.1 would
# add. Throws when no such form exists, which is when every space follows an odd number of quotes.
function ConvertTo-NativeArgument {
    param([string]$Argument, [switch]$Quote)
    if ($Argument.Length -eq 0) { return '""' }
    # 5.1 wraps the argument in plain quotes when some whitespace follows an even number of quotes,
    # counting escaped ones too, and passes it untouched otherwise.
    $quotes = 0
    $spaced = $false
    $wrapped = $false
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '"') {
            $quotes++
        } elseif ([char]::IsWhiteSpace($char)) {
            $spaced = $true
            if ($quotes % 2 -eq 0) { $wrapped = $true }
        }
    }
    if ($spaced -and -not $wrapped) {
        throw "Windows PowerShell 5.1 cannot pass the argument '$Argument' intact: every space in it follows an odd number of double quotes."
    }
    # A quote becomes \" with the backslashes before it doubled; inside 5.1's quotes, trailing ones double too.
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    if ($wrapped) { $escaped = [regex]::Replace($escaped, '(\\+)\z', '$1$1') }
    if ($Quote -and $wrapped) { return '"' + $escaped + '"' }
    return $escaped
}

# Run $FilePath with $ArgumentList quoted for 5.1 and return only its exit code, printing stdout and stderr (UTF-8) to the host, adding them
# to -Capture, or with -Console leaving them on this console, which the transcript misses. A code outside $SuccessCode throws naming the
# command and the code; with -Console, -TimeoutSeconds above 0 kills the program and throws once that time has passed.
function Invoke-Native {
    [CmdletBinding(DefaultParameterSetName = 'Host')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessCode = @(0),
        [Parameter(ParameterSetName = 'Capture')][System.Collections.Generic.List[string]]$Capture,
        [Parameter(ParameterSetName = 'Console')][switch]$Console,
        [Parameter(ParameterSetName = 'Console')][ValidateRange(0, 86400)][int]$TimeoutSeconds = 0
    )
    # Windows PowerShell 5.1 turns redirected stderr lines into error records, which 'Stop'
    # would make terminating; under 'Continue' they are printed like stdout.
    $ErrorActionPreference = 'Continue'
    $program = @(Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue)
    if ($program.Count -eq 0) {
        throw "Cannot find the program '$FilePath'."
    }
    $capturing = $null -ne $Capture
    $passed = @(foreach ($argument in $ArgumentList) { ConvertTo-NativeArgument -Argument $argument -Quote:$Console })
    # The host decodes child output with the console's OEM code page unless told otherwise.
    $savedEncoding = $null
    try {
        $savedEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    } catch {
        $savedEncoding = $null
    }
    try {
        if ($Console) {
            # The program inherits this console, so progress bars draw, and a process it leaves
            # running, such as the Ollama app, holds no pipe for this call to wait on. Process.Start
            # keeps the handle CreateProcess returns: the Process that Start-Process -NoNewWindow
            # gives in 5.1 holds none, so a program that ended before this call opened one lost its
            # exit code. WaitForExit waits for the program alone, where Start-Process -Wait also
            # waits for every child process.
            $startInfo = New-Object Diagnostics.ProcessStartInfo -ArgumentList $program[0].Path
            $startInfo.UseShellExecute = $false
            if ($passed.Count -gt 0) { $startInfo.Arguments = $passed -join ' ' }
            # As Start-Process: the current FileSystem location, which the process's own current
            # directory does not follow.
            $startInfo.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
            try {
                $process = [Diagnostics.Process]::Start($startInfo)
            } catch {
                throw "Cannot start '$((@($FilePath) + $ArgumentList) -join ' ')': $($_.Exception.GetBaseException().Message)"
            }
            try {
                if ($TimeoutSeconds -gt 0) {
                    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                        try { $process.Kill() } catch { Write-Verbose "Could not stop $FilePath`: $($_.Exception.Message)" }
                        throw "'$((@($FilePath) + $ArgumentList) -join ' ')' did not finish within $TimeoutSeconds s and was stopped."
                    }
                } else {
                    $process.WaitForExit()
                }
                $code = $process.ExitCode
            } finally {
                $process.Dispose()
            }
        } else {
            # A blank stderr line is an error record whose text would read 'RemoteException'.
            & $FilePath @passed 2>&1 | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
                if ($capturing) { $Capture.Add($line) } else { $line }
            } | Out-Host
            $code = $LASTEXITCODE
        }
    } finally {
        if ($savedEncoding) { [Console]::OutputEncoding = $savedEncoding }
    }
    if ($SuccessCode -notcontains $code) {
        throw "'$((@($FilePath) + $ArgumentList) -join ' ')' failed with exit code $code."
    }
    return $code
}

# Merge the registry PATH (Machine, then User) into $env:Path, keeping this process's entries
# first and dropping duplicates, compared without case or a trailing '\'. -MachinePath and
# -UserPath stand in for the registry values. Returns nothing.
function Update-SessionPath {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$MachinePath,
        [string]$UserPath
    )
    if (-not $PSBoundParameters.ContainsKey('MachinePath')) {
        $MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    }
    if (-not $PSBoundParameters.ContainsKey('UserPath')) {
        $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    $seen = @{}
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in ((@($env:Path, $MachinePath, $UserPath) -join ';') -split ';')) {
        $trimmed = $entry.Trim()
        $key = $trimmed.TrimEnd('\')
        if (-not $key -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $entries.Add($trimmed)
    }
    if ($PSCmdlet.ShouldProcess('$env:Path', 'Merge the registry PATH')) {
        $env:Path = $entries -join ';'
    }
}

# Shift $Path to $Path.1, $Path.1 to $Path.2 and so on up to $Path.$Keep, dropping the oldest,
# so a service's next start writes a fresh log. Missing generations are skipped; one that cannot
# be moved, such as a log a running process still holds open, throws naming the file.
function Invoke-LogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 20)][int]$Keep = 5
    )
    for ($i = $Keep - 1; $i -ge 0; $i--) {
        $source = if ($i -gt 0) { "$Path.$i" } else { $Path }
        if (Test-Path -LiteralPath $source) {
            try {
                Move-Item -LiteralPath $source -Destination "$Path.$($i + 1)" -Force
            } catch {
                throw "Cannot rotate the log '$source': $($_.Exception.Message)"
            }
        }
    }
}

# Delete files in $Directory matching $Filter beyond the $KeepCount newest, and any older than
# $MaxAgeDays, by last write time. A missing folder is not an error.
function Remove-OldLogs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The launcher design names this function.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Filter,
        [ValidateRange(0, 1000)][int]$KeepCount = 20,
        [ValidateRange(0, 3650)][int]$MaxAgeDays = 14
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File | Sort-Object LastWriteTime -Descending)
    for ($i = 0; $i -lt $files.Count; $i++) {
        if ($i -ge $KeepCount -or $files[$i].LastWriteTime -lt $cutoff) {
            if ($PSCmdlet.ShouldProcess($files[$i].FullName, 'Delete old log')) {
                Remove-Item -LiteralPath $files[$i].FullName -Force
            }
        }
    }
}

# Take the named mutex $Name, waiting up to $TimeoutSeconds. Returns the held Mutex, or $null on
# timeout; a mutex left behind by a crashed launcher counts as taken. Release it with
# Exit-LocalAILock on the same thread.
function Enter-LocalAILock {
    [CmdletBinding()]
    [OutputType([System.Threading.Mutex])]
    param(
        [string]$Name = 'Local\LocalAILauncher',
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 0
    )
    $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, $Name
    try {
        if ($mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) { return $mutex }
    } catch [System.Threading.AbandonedMutexException] {
        return $mutex
    }
    $mutex.Dispose()
    return $null
}

# Release and dispose a mutex taken by Enter-LocalAILock. $null is ignored, so a caller can pass
# the result of a timed-out Enter-LocalAILock unchanged.
function Exit-LocalAILock {
    [CmdletBinding()]
    param(
        [System.Threading.Mutex]$Mutex
    )
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

# Return $true when the named mutex $Name exists, that is while another launcher run holds it or
# waits for it, without taking it, so a start beside this run is never refused. Windows deletes the
# mutex when the last process with a handle to it exits.
function Test-LocalAILockHeld {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Name = 'Local\LocalAILauncher'
    )
    $mutex = $null
    if (-not [System.Threading.Mutex]::TryOpenExisting($Name, [ref]$mutex)) { return $false }
    $mutex.Dispose()
    return $true
}

# Ask Windows to keep the PC awake while this thread runs (-Enabled $true), or hand sleep back
# to the power plan (-Enabled $false). Changes no setting, and Windows drops the request when the
# process exits. The kernel32 binding is compiled once per session.
function Set-LocalAIKeepAwake {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][bool]$Enabled
    )
    if (-not ('LocalAI.NativeMethods' -as [type])) {
        Add-Type -Namespace LocalAI -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
    }
    # ES_CONTINUOUS (0x80000000) keeps the request until changed; ES_SYSTEM_REQUIRED (0x1) blocks sleep.
    $flags = [uint32]2147483648
    if ($Enabled) { $flags = [uint32]($flags + 1) }
    if ($PSCmdlet.ShouldProcess('this thread', "SetThreadExecutionState $flags")) {
        if (('LocalAI.NativeMethods' -as [type])::SetThreadExecutionState($flags) -eq 0) {
            Write-Warning 'Windows refused the keep-awake request.'
        }
    }
}

# Return the Ollama base URL without a trailing '/': $Setting when it is not empty, else OLLAMA_HOST
# from this process, then the User environment, parsed as Ollama parses OLLAMA_HOST, with 0.0.0.0,
# :: or no host turned into 127.0.0.1. -ProcessHost and -UserHost stand in for the environment.
function Resolve-OllamaUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Setting,
        [string]$ProcessHost,
        [string]$UserHost
    )
    $value = $Setting
    if (-not $value) {
        if (-not $PSBoundParameters.ContainsKey('ProcessHost')) {
            $ProcessHost = [Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'Process')
        }
        if (-not $PSBoundParameters.ContainsKey('UserHost')) {
            $UserHost = [Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User')
        }
        $value = if ($ProcessHost) { $ProcessHost } else { $UserHost }
    }
    # Ollama 0.40.11 envconfig.Host(): no scheme means http on port 11434, an explicit http or
    # https without a port means 80 or 443, and a path after the host is kept.
    $value = ([string]$value).Trim().Trim('"', "'").Trim()
    $scheme = 'http'
    $defaultPort = '11434'
    $hostPort = $value
    $cut = $value.IndexOf('://')
    if ($cut -ge 0) {
        $scheme = $value.Substring(0, $cut)
        $hostPort = $value.Substring($cut + 3)
        if ($scheme -ceq 'http') { $defaultPort = '80' } elseif ($scheme -ceq 'https') { $defaultPort = '443' }
    } elseif ($value -ceq 'ollama.com') {
        $scheme = 'https'
        $hostPort = 'ollama.com:443'
    }
    $path = ''
    $slash = $hostPort.IndexOf('/')
    if ($slash -ge 0) {
        $path = $hostPort.Substring($slash + 1)
        $hostPort = $hostPort.Substring(0, $slash)
    }
    # Go's net.SplitHostPort takes host:port or [host]:port; anything else is a bare host or IP.
    if ($hostPort -match '^\[([^\[\]]*)\]:([^\[\]:]*)\z' -or $hostPort -match '^([^\[\]:]*):([^\[\]:]*)\z') {
        $name = $Matches[1]
        $port = $Matches[2]
    } else {
        $name = $hostPort.Trim('[', ']')
        $port = $defaultPort
    }
    if ($port -notmatch '^\d{1,5}\z' -or [int]$port -gt 65535) { $port = $defaultPort }
    # 0.0.0.0 and :: are bind addresses; a client cannot connect to them on Windows.
    $address = $null
    if (-not $name -or ([Net.IPAddress]::TryParse($name, [ref]$address) -and
            ($address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::IPv6Any)))) {
        $name = '127.0.0.1'
    }
    if ($name.Contains(':')) { $name = "[$name]" }
    $url = '{0}://{1}:{2}' -f $scheme, $name, [int]$port
    if ($path) { $url += '/' + $path }
    return $url.TrimEnd('/')
}

# Return the Get-NetTCPConnection objects listening on TCP $Port, or nothing when no program
# listens there. Any other Get-NetTCPConnection error is thrown. The no-match error is collected, not
# thrown, as Start-Transcript in Windows PowerShell 5.1 logs every thrown error, even a caught one.
function Get-TcpListener {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port
    )
    Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue -ErrorVariable failures
    foreach ($failure in @($failures)) {
        # The no-match error is CmdletizationQuery_NotFound,Get-NetTCPConnection.
        if ($failure.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') { throw $failure }
    }
}

# Return the local addresses listening on TCP $Port, sorted and without repeats, or nothing when
# no program listens there. Any other Get-NetTCPConnection error is thrown.
function Get-ListenerAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port
    )
    Get-TcpListener -Port $Port | ForEach-Object { [string]$_.LocalAddress } | Sort-Object -Unique
}

# Return the process listening on TCP $Port as Id, Name, Path and StartTicks (UTC), or $null when
# nothing listens there; with several owners the lowest PID wins. Name, Path and StartTicks are
# $null for a process that has exited or cannot be read.
function Get-PortOwner {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port
    )
    $ids = @(Get-TcpListener -Port $Port | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { return $null }
    $owner = [pscustomobject]@{ Id = $ids[0]; Name = $null; Path = $null; StartTicks = $null }
    $process = Get-Process -Id $ids[0] -ErrorAction SilentlyContinue
    if ($process) {
        $owner.Name = [string]$process.Name
        $owner.Path = [string]$process.Path
        try { $owner.StartTicks = $process.StartTime.ToUniversalTime().Ticks } catch { $owner.StartTicks = $null }
    }
    return $owner
}

# Return each process that holds an open TCP connection to port $Port on a loopback address, once, as Id and Name ($null when its name cannot be
# read), leaving out the PIDs in $Exclude. Reads only; returns nothing when no connection matches and throws any other Get-NetTCPConnection error.
function Get-LoopbackClient {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [int[]]$Exclude = @()
    )
    $connections = @(Get-NetTCPConnection -State Established -RemotePort $Port -ErrorAction SilentlyContinue -ErrorVariable failures)
    foreach ($failure in @($failures)) {
        # The no-match error, collected as in Get-TcpListener.
        if ($failure.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') { throw $failure }
    }
    $ids = @(foreach ($connection in $connections) {
            $address = $null
            # A dual-stack socket shows an IPv4 peer as ::ffff:a.b.c.d.
            $text = ([string]$connection.RemoteAddress) -replace '^::ffff:', ''
            if ([Net.IPAddress]::TryParse($text, [ref]$address) -and [Net.IPAddress]::IsLoopback($address)) { [int]$connection.OwningProcess }
        })
    foreach ($id in @($ids | Sort-Object -Unique)) {
        if ($Exclude -contains $id) { continue }
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        $name = if ($process) { [string]$process.Name } else { $null }
        [pscustomobject]@{ Id = $id; Name = $name }
    }
}

# Return 'match' when a process with $Record.Pid runs, started within one second of $Record.StartTicks (UTC
# ticks) from $Record.Path (any case); 'unreadable' when that PID started then but this window cannot read its
# path or start time, as with an elevated process; else 'other': no such process, a reused PID or no record.
function Get-RecordedProcessState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Record
    )
    if (-not ($Record.Pid -and $Record.StartTicks -and $Record.Path)) { return 'other' }
    $id = [int]$Record.Pid
    $process = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $process) { return 'other' }
    $ticks = $null
    try { $ticks = $process.StartTime.ToUniversalTime().Ticks } catch { $ticks = $null }
    if ($null -eq $ticks) {
        # Win32_Process gives the creation time of any process, also one this window may not open.
        $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if ($cim -and $cim.CreationDate) { $ticks = $cim.CreationDate.ToUniversalTime().Ticks }
    }
    if ($null -ne $ticks -and [math]::Abs($ticks - [long]$Record.StartTicks) -ge [TimeSpan]::TicksPerSecond) { return 'other' }
    $path = [string]$process.Path
    if ($null -eq $ticks -or -not $path) { return 'unreadable' }
    if ($path -eq [string]$Record.Path) { return 'match' }
    return 'other'
}

# Return $true when Get-RecordedProcessState finds the process $Record names running as recorded
# (PID, start time within one second, path), so a reused PID never passes; any other answer is $false.
function Test-RecordedProcess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Record
    )
    return (Get-RecordedProcessState -Record $Record) -eq 'match'
}

# Return @{ Match; Unreadable }: the parts of the state.json service $Record (the record, then its
# Listener) whose process runs as recorded, and those Get-RecordedProcessState cannot inspect.
function Get-LiveRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Record
    )
    $live = @{ Match = @(); Unreadable = @() }
    foreach ($part in @($Record, $Record.Listener)) {
        if ($part -isnot [hashtable]) { continue }
        $found = Get-RecordedProcessState -Record $part
        if ($found -eq 'match') { $live.Match += $part } elseif ($found -eq 'unreadable') { $live.Unreadable += $part }
    }
    return $live
}

# Return $true when process $ProcessId is $AncestorId or descends from it within $MaxDepth parent steps,
# per Win32_Process. Each parent must have been created no later than its child, so a reused parent PID
# breaks the chain; a process that has exited or cannot be read on the way gives $false.
function Test-ProcessDescendant {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int]$AncestorId,
        [ValidateRange(1, 16)][int]$MaxDepth = 4
    )
    if ($ProcessId -eq $AncestorId) { return $true }
    $child = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    for ($step = 0; $step -lt $MaxDepth -and $child; $step++) {
        $parentId = [int]$child.ParentProcessId
        $parent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$parentId" -ErrorAction SilentlyContinue
        if (-not ($parent -and $parent.CreationDate -and $child.CreationDate) -or $parent.CreationDate -gt $child.CreationDate) { return $false }
        if ($parentId -eq $AncestorId) { return $true }
        $child = $parent
    }
    return $false
}

# Return $true when process $ProcessId runs in this window's Windows session, whose desktop EnumWindows lists; $false when it runs in another session,
# as a program started over SSH or by a scheduled task that runs while nobody is signed in does, or when its session cannot be read.
function Test-ProcessInThisSession {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$ProcessId
    )
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $process -or $null -eq $process.SessionId) { return $false }
    $own = [Diagnostics.Process]::GetCurrentProcess()
    try {
        return [int]$process.SessionId -eq $own.SessionId
    } finally {
        $own.Dispose()
    }
}

# Return $true when only loopback addresses listen on TCP $Port. Otherwise warn, naming $Name, the
# exposed addresses and $Fix (how to bind it to loopback again), and return $false; a port nothing
# listens on also warns and returns $false.
function Test-LoopbackListener {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory)][string]$Name,
        [string]$Fix
    )
    $addresses = @(Get-ListenerAddress -Port $Port)
    if ($addresses.Count -eq 0) {
        Write-Warning "Nothing listens on port $Port, so the address $Name is bound to cannot be checked."
        return $false
    }
    $exposed = @(foreach ($address in $addresses) {
            $ip = $null
            if (-not ([Net.IPAddress]::TryParse($address, [ref]$ip) -and [Net.IPAddress]::IsLoopback($ip))) { $address }
        })
    if ($exposed.Count -gt 0) {
        Write-Warning ("$Name IS OPEN TO THE NETWORK: port $Port listens on $($exposed -join ', '), not only on " +
            "127.0.0.1 or ::1, so other devices that reach this PC can use it. $Fix").TrimEnd()
        return $false
    }
    Write-Host "$Name listens on $($addresses -join ', ') port $Port only."
    return $true
}

# Make sure the winget package $Package (Id, Command, Scope) is installed, never upgrading it: it
# counts as present when Command is on PATH or winget lists Id, else it is installed with its log in
# $LogDir. Returns 'present', 'installed' or 'restart'; any other winget result throws naming the log.
function Install-WingetPackage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Package,
        [Parameter(Mandatory)][string]$LogDir
    )
    $id = $Package.Id
    Update-SessionPath
    if (Get-Command -Name $Package.Command -CommandType Application -ErrorAction SilentlyContinue) {
        Write-Host "$id is installed ($($Package.Command) is on PATH)."
        return 'present'
    }
    # 0x8A150014 NO_APPLICATIONS_FOUND: winget lists no such package.
    $listed = New-Object System.Collections.Generic.List[string]
    try {
        $code = Invoke-Native -FilePath 'winget' -ArgumentList 'list', '--id', $id, '-e', '--accept-source-agreements',
            '--disable-interactivity' -SuccessCode 0, -1978335212 -Capture $listed
    } catch {
        $said = @($listed | Where-Object { $_.Trim() }) -join ' '
        throw "$($_.Exception.Message) winget said: $said"
    }
    if ($code -eq 0) {
        Write-Host "$id is installed (winget lists it)."
        return 'present'
    }
    # winget's documented return codes (doc/windows/package-manager/winget/returnCodes.md).
    $outcomes = @{
        0           = 'installed'
        # 0x8A150061 PACKAGE_ALREADY_INSTALLED, what --no-upgrade returns for an installed package.
        -1978335135 = 'present'
        # 0x8A15010D INSTALL_ALREADY_INSTALLED, mapped from installer exit codes.
        -1978334963 = 'present'
        # 0x8A15002B UPDATE_NOT_APPLICABLE and 0x8A15004F UPGRADE_VERSION_NOT_NEWER.
        -1978335189 = 'present'
        -1978335153 = 'present'
        # 0x8A150109 INSTALL_REBOOT_REQUIRED_TO_FINISH. INSTALL_REBOOT_INITIATED (0x8A15010B) is not
        # listed: Windows is already restarting, so install must stop rather than carry on.
        -1978334967 = 'restart'
    }
    $null = [IO.Directory]::CreateDirectory($LogDir)
    $log = Join-Path $LogDir "winget-$id.log"
    if ($Package.Scope -eq 'machine') {
        Write-Host "Installing $id for all users: Windows asks for administrator approval (UAC)." -ForegroundColor Yellow
    } else {
        Write-Host "Installing $id..."
    }
    try {
        $code = Invoke-Native -FilePath 'winget' -ArgumentList 'install', '--id', $id, '-e', '--source', 'winget',
            '--scope', $Package.Scope, '--no-upgrade', '--silent', '--disable-interactivity',
            '--accept-source-agreements', '--accept-package-agreements', '--log', $log -SuccessCode @($outcomes.Keys) -Console
    } catch {
        throw "winget could not install ${id}: $($_.Exception.Message) 'winget error <code>' explains the code; the log is $log."
    }
    Update-SessionPath
    $outcome = $outcomes[$code]
    if ($outcome -eq 'restart') { Write-Warning "Restart Windows to finish installing $id." }
    return $outcome
}

# Return each running 'ollama app.exe', the Ollama tray app, from Win32_Process as Id, Path, StartTicks (UTC creation time) and ParentId; Path is $null
# when this window may not read it. Throws when Win32_Process cannot be read, so that a caller never takes a failed query for no app at all.
function Get-OllamaAppProcess {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='ollama app.exe'" -ErrorAction Stop)) {
        $ticks = if ($process.CreationDate) { $process.CreationDate.ToUniversalTime().Ticks } else { $null }
        $path = if ($process.ExecutablePath) { [string]$process.ExecutablePath } else { $null }
        [pscustomobject]@{ Id = [int]$process.ProcessId; Path = $path; StartTicks = $ticks; ParentId = [int]$process.ParentProcessId }
    }
}

# Return the full path of 'ollama app.exe' beside the ollama program on PATH, the first place the ollama CLI looks for the app (cmd/start_windows.go
# in Ollama v0.40.13), or $null when either file is missing.
function Resolve-OllamaAppPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $program = @(Get-Command -Name 'ollama' -CommandType Application -ErrorAction SilentlyContinue)
    if ($program.Count -eq 0 -or -not $program[0].Path) { return $null }
    $app = Join-Path (Split-Path $program[0].Path -Parent) 'ollama app.exe'
    if (Test-Path -LiteralPath $app -PathType Leaf) { return $app }
    return $null
}

# Start the Ollama app at $Path hidden, with the arguments the ollama CLI gives it, in its own folder, and return its PID without waiting. Without
# -NoNewWindow, Start-Process uses ShellExecute, so the app holds no handle of this window's output. An app started while another runs exits at once.
# Throws when Start-Process fails.
function Start-OllamaApp {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the install, start, update and uninstall verbs, which offer no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $process = Start-Process -FilePath $Path -ArgumentList '--hide', '--fast-startup' -WorkingDirectory (Split-Path $Path -Parent) -PassThru -ErrorAction Stop
    return [int]$process.Id
}

# Return $true while OllamaSetup.exe, the Ollama installer, runs. The ollama CLI then refuses to start the app, and the installer starts it once it is done.
function Test-OllamaSetupRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $found = [Diagnostics.Process]::GetProcessesByName('OllamaSetup')
    try {
        return $found.Count -gt 0
    } finally {
        foreach ($process in $found) { $process.Dispose() }
    }
}

# Return the state.json record of the Ollama app a start began, @{ Pid; StartTicks; Path; Port; StartedTicks; How; Listener } as Get-RecordedProcessState
# reads it, or $null with the reason as a verbose message. The app counts only when $Before (Get-OllamaAppProcess before the start) is empty, exactly one app
# began at or after $Since (UTC ticks), it is $ProcessId unless that is 0, it runs from $ExpectedPath, $Url names this PC and a direct child holds its port.
function Get-OllamaOwnStart {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()][object[]]$Before = @(),
        [Parameter(Mandatory)][long]$Since,
        [Parameter(Mandatory)][string]$Url,
        [AllowEmptyString()][string]$ExpectedPath = '',
        [int]$ProcessId = 0,
        [ValidateSet('start', 'install', 'update', 'uninstall')][string]$How = 'start'
    )
    $uri = [uri]$Url
    $app = $null
    $owner = $null
    $why = $null
    $Before = @($Before)
    if ($Before.Count -gt 0) {
        # A second app exits at once, and one already starting answers in its own time.
        $why = "an Ollama app already ran (PID $($Before[0].Id))"
    } else {
        $new = @()
        try {
            $new = @(Get-OllamaAppProcess | Where-Object { $null -ne $_.StartTicks -and [long]$_.StartTicks -ge $Since })
        } catch {
            $why = "the Ollama apps cannot be listed: $($_.Exception.Message)"
        }
        if ($why) {
            Write-Verbose "local-ai records no Ollama app: $why"
            return $null
        }
        if ($new.Count -ne 1) {
            $why = "$($new.Count) Ollama apps began since the start"
        } elseif ($ProcessId -gt 0 -and [int]$new[0].Id -ne $ProcessId) {
            $why = "the app it started (PID $ProcessId) has exited, as one does while another app runs"
        } elseif (-not $ExpectedPath -or -not [string]::Equals([string]$new[0].Path, $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $why = "the app runs from '$($new[0].Path)', not from '$ExpectedPath'"
        } else {
            try {
                if (-not (Test-LocalHostName -HostName $uri.Host)) {
                    $why = "$Url is not on this PC"
                } else {
                    # ollama.exe serve, which the app runs as its direct child, holds the API port.
                    $owner = Get-PortOwner -Port $uri.Port
                    if ($owner -and (Test-ProcessDescendant -ProcessId $owner.Id -AncestorId ([int]$new[0].Id) -MaxDepth 1)) {
                        $app = $new[0]
                    } else {
                        $why = "port $($uri.Port) is not held by a child of the app (PID $($new[0].Id))"
                    }
                }
            } catch {
                $why = "the holder of port $($uri.Port) cannot be read: $($_.Exception.Message)"
            }
        }
    }
    if (-not $app) {
        Write-Verbose "local-ai records no Ollama app: $why"
        return $null
    }
    return @{
        Pid          = [int]$app.Id
        StartTicks   = [long]$app.StartTicks
        Path         = [string]$app.Path
        Port         = [int]$uri.Port
        StartedTicks = $Since
        How          = $How
        Listener     = @{ Pid = [int]$owner.Id; StartTicks = $owner.StartTicks; Path = $owner.Path }
    }
}

# Return the type that binds the user32 calls behind Get-TopLevelWindow and Send-OllamaAppClose, compiling it on first use. The type outlives the module,
# so a second import finds it and compiles nothing; GetTopLevelWindows keeps its callback referenced until EnumWindows returns. Throws when the binding
# cannot be compiled, as where Add-Type is blocked.
function Get-LocalAIWindowApi {
    [CmdletBinding()]
    [OutputType([type])]
    param()
    $api = 'LocalAI.WindowApi' -as [type]
    if ($api) { return $api }
    Add-Type -Namespace LocalAI -Name WindowApi -UsingNamespace 'System.Collections.Generic', 'System.Text' -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

public class TopLevelWindow {
    public IntPtr Handle;
    public string ClassName;
    public int ProcessId;
    public bool Visible;
    public bool Owned;
}

[DllImport("user32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

[DllImport("user32.dll")]
private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

[DllImport("user32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
private static extern bool IsWindowVisible(IntPtr hWnd);

[DllImport("user32.dll")]
private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

[DllImport("user32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

// Every top-level window of this desktop, hidden ones included, with its class, the PID that created it, whether it is visible and whether it has an owner.
public static TopLevelWindow[] GetTopLevelWindows() {
    List<TopLevelWindow> found = new List<TopLevelWindow>();
    EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam) {
        StringBuilder name = new StringBuilder(256);
        GetClassName(hWnd, name, name.Capacity);
        uint processId;
        GetWindowThreadProcessId(hWnd, out processId);
        TopLevelWindow window = new TopLevelWindow();
        window.Handle = hWnd;
        window.ClassName = name.ToString();
        window.ProcessId = (int)processId;
        window.Visible = IsWindowVisible(hWnd);
        // GW_OWNER (4): a dialog or popup has an owner, a main window none.
        window.Owned = GetWindow(hWnd, 4) != IntPtr.Zero;
        found.Add(window);
        return true;
    };
    EnumWindows(callback, IntPtr.Zero);
    GC.KeepAlive(callback);
    return found.ToArray();
}
'@
    return 'LocalAI.WindowApi' -as [type]
}

# Return each top-level window of this desktop, hidden ones included, as Handle, ClassName, ProcessId (of the process that created it), Visible and Owned
# (it has an owner window). Reads only; throws as Get-LocalAIWindowApi does.
function Get-TopLevelWindow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $api = Get-LocalAIWindowApi
    foreach ($window in $api::GetTopLevelWindows()) {
        [pscustomobject]@{ Handle = $window.Handle; ClassName = $window.ClassName; ProcessId = $window.ProcessId; Visible = $window.Visible; Owned = $window.Owned }
    }
}

# Return the handle of the hidden window of class 'OllamaClass' that the Ollama app with PID $ProcessId owns, the window its tray icon's Quit closes, or
# [IntPtr]::Zero when it has none. A window of that class owned by any other process never counts. Throws as Get-LocalAIWindowApi does.
function Find-OllamaAppWindow {
    [CmdletBinding()]
    [OutputType([IntPtr])]
    param(
        [Parameter(Mandatory)][int]$ProcessId
    )
    foreach ($window in @(Get-TopLevelWindow)) {
        if ([string]$window.ClassName -ceq 'OllamaClass' -and [int]$window.ProcessId -eq $ProcessId) { return [IntPtr]$window.Handle }
    }
    return [IntPtr]::Zero
}

# Post WM_CLOSE to the window $Handle without waiting, as the Ollama tray icon's Quit does (app/wintray/eventloop.go in Ollama v0.40.13). Returns $true
# when Windows queued it, $false when it refused, as for a window that is gone or belongs to an elevated process; throws as Get-LocalAIWindowApi does.
function Send-OllamaAppClose {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][IntPtr]$Handle
    )
    $api = Get-LocalAIWindowApi
    # 0x0010 is WM_CLOSE.
    return [bool]$api::PostMessage($Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
}

# Return $true when the Ollama app with PID $ProcessId shows a window of its own, such as its chat window, judged as Process.MainWindowHandle judges one:
# visible and without an owner. Its tray window is hidden. A quit posted while such a window is open may leave the app running without its tray icon.
# Throws as Get-LocalAIWindowApi does.
function Test-OllamaAppWindowOpen {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$ProcessId
    )
    return @(Get-TopLevelWindow | Where-Object { [int]$_.ProcessId -eq $ProcessId -and $_.Visible -and -not $_.Owned }).Count -gt 0
}

# Return the version Ollama reports at $Url/api/version, or with -PassThru @{ Version; App; Started }: App is Get-OllamaOwnStart's record (marked $How) of
# the Ollama app this call started, else $null, and Started says whether it tried to start one. When nothing answers it starts the app once, itself when
# Resolve-OllamaAppPath finds it, else with 'ollama list', and polls every 500 ms; while OllamaSetup.exe runs, $Url names another computer or another
# program holds its port, it only polls. Throws when the ollama program is missing or nothing answers within $TimeoutSeconds; never runs 'ollama serve'.
function Wait-OllamaServer {
    [CmdletBinding()]
    [OutputType([string], [pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [switch]$PassThru,
        [ValidateSet('start', 'install', 'update', 'uninstall')][string]$How = 'start'
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $uri = [uri]$Url
    $local = $null
    $triggered = $false
    $upgrading = $false
    # Why the app is not started yet: 'upgrade', 'remote' or 'held' (by $holder), each said once.
    $blocked = $null
    $holder = $null
    $reason = $null
    $startError = $null
    $appPath = $null
    $startedId = 0
    $before = $null
    $since = [long]0
    while ($true) {
        $version = $null
        try {
            $answer = Invoke-RestMethod -Uri "$Url/api/version" -UseBasicParsing -TimeoutSec 5
            if ($answer.version) { $version = [string]$answer.version } else { $reason = 'it answered without a version' }
        } catch {
            $reason = $_.Exception.Message
        }
        if ($version) {
            if (-not $PassThru) { return $version }
            $app = $null
            if ($triggered) {
                # Only an app this call started itself, with the apps before it listed, can be local-ai's; after an upgrade the installer starts one too.
                if ($startedId -gt 0 -and $null -ne $before -and -not $upgrading) {
                    $app = Get-OllamaOwnStart -Before $before -Since $since -Url $Url -ExpectedPath $appPath -ProcessId $startedId -How $How
                }
                if ($app) {
                    Write-Host "Started the Ollama app (PID $($app.Pid)); local-ai stop quits it again."
                } elseif (-not $startError -and ($null -eq $before -or $before.Count -eq 0)) {
                    # An app that ran before answers for itself, and stop leaves it as one local-ai did not start.
                    Write-Host 'local-ai cannot tell that the Ollama app answering now is the one it started, so local-ai stop leaves it running.'
                }
            }
            return [pscustomobject]@{ Version = $version; App = $app; Started = $triggered }
        }
        if (-not $triggered) {
            if ($null -eq $local) { $local = Test-LocalHostName -HostName $uri.Host }
            $was = $blocked
            $holder = $null
            if (Test-OllamaSetupRunning) {
                # The ollama CLI refuses to start the app during an upgrade (cmd/start_windows.go), and the installer starts it once it is done.
                $upgrading = $true
                $blocked = 'upgrade'
            } elseif (-not $local) {
                # The app serves this PC only.
                $blocked = 'remote'
            } else {
                # As the CLI starts the app only when the connection is refused: its server could not take a port another program holds.
                try { $holder = Get-PortOwner -Port $uri.Port } catch { $holder = $null }
                $blocked = if ($holder) { 'held' } else { $null }
            }
            $holderText = if (-not $holder) { '' } elseif ($holder.Name) { "$($holder.Name) (PID $($holder.Id))" } else { "a program (PID $($holder.Id))" }
            if ($blocked -and $blocked -ne $was) {
                $why = switch ($blocked) {
                    'upgrade' { 'while its installer, OllamaSetup.exe, runs; waiting for the upgrade...' }
                    'remote' { "and $($uri.Host) is another computer, so local-ai does not start the Ollama app here; waiting for it..." }
                    'held' { "but $holderText holds port $($uri.Port), so local-ai does not start the Ollama app; waiting for it to answer..." }
                }
                Write-Host "Ollama does not answer at $Url $why"
            }
            if (-not $blocked) {
                $triggered = $true
                if (-not (Get-Command -Name 'ollama' -CommandType Application -ErrorAction SilentlyContinue)) {
                    throw "Ollama does not answer at $Url ($reason), and the ollama program is not on PATH. Install Ollama, then try again."
                }
                $appPath = Resolve-OllamaAppPath
                if ($PassThru -and $appPath) {
                    try {
                        $before = @(Get-OllamaAppProcess)
                    } catch {
                        Write-Verbose "The Ollama apps cannot be listed, so local-ai records no app it starts now: $($_.Exception.Message)"
                    }
                }
                # A second early, as Win32_Process and this clock are read apart.
                $since = [DateTime]::UtcNow.AddSeconds(-1).Ticks
                Write-Host "Ollama does not answer at $Url; starting the Ollama app..."
                try {
                    if ($appPath) {
                        # The arguments the CLI starts it with, so a pending update of the app waits as it does then.
                        $startedId = Start-OllamaApp -Path $appPath
                    } else {
                        # When no server answers, the CLI runs 'ollama app.exe --hide --fast-startup' from where it finds it and waits up to 5 s.
                        $left = [int][math]::Max(1, [math]::Ceiling($TimeoutSeconds - $timer.Elapsed.TotalSeconds))
                        $null = Invoke-Native -FilePath 'ollama' -ArgumentList 'list' -Console -TimeoutSeconds $left
                    }
                } catch {
                    $startError = $_.Exception.Message
                }
                continue
            }
        }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            if ($blocked -eq 'remote') {
                throw ("Ollama did not answer at $Url/api/version within $TimeoutSeconds s ($reason). $($uri.Host) is another computer, so local-ai does not " +
                    'start the Ollama app for it; start Ollama there, or point Ollama.Url at this PC, then try again.')
            }
            if ($blocked -eq 'held') {
                $name = if ($holder.Name) { $holder.Name } else { 'a program' }
                $where = if ($holder.Path) { ", $($holder.Path)" } else { '' }
                throw ("Ollama did not answer at $Url/api/version within $TimeoutSeconds s ($reason), and $name (PID $($holder.Id)$where) holds port " +
                    "$($uri.Port), so local-ai did not start the Ollama app. Close that program, or point Ollama.Url at the Ollama server, then try again.")
            }
            if (-not $triggered) {
                throw ("Ollama did not answer at $Url/api/version within $TimeoutSeconds s while its upgrade (OllamaSetup.exe) was running ($reason). " +
                    'Wait for the upgrade to finish, then try again.')
            }
            $with = if ($appPath) { "'$appPath'" } else { "'ollama list'" }
            $also = ''
            if ($startError) {
                $also = " Starting it with $with failed: $startError"
            } elseif ($startedId -gt 0) {
                $also = " The Ollama app local-ai started (PID $startedId) may still come up; local-ai stop leaves it running."
            }
            throw ("Ollama did not answer at $Url/api/version within $TimeoutSeconds s ($reason).$also " +
                'Start the Ollama app from the Start menu, wait for its tray icon, then try again.')
        }
        Start-Sleep -Milliseconds 500
    }
}

# Return $true while the state.json record $App still names the Ollama app local-ai started for the server at $Url: Get-RecordedProcessState finds it
# running as recorded, or running where this window may not inspect it, as stop and status treat it, and it serves $Url's port on this PC. An app on
# another port, or a $Url on another computer, is another server's, whose loaded models stop would not see. No record, or a $Url that is no absolute URL,
# gives $false.
function Test-OllamaAppRecord {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [hashtable]$App,
        [AllowEmptyString()][string]$Url = ''
    )
    if (-not $App -or -not $Url) { return $false }
    $port = 0
    $hostName = ''
    try {
        $uri = [uri]$Url
        $port = $uri.Port
        $hostName = $uri.Host
    } catch {
        return $false
    }
    if ([int]$App.Port -ne $port) { return $false }
    # The app serves this PC only, so a record never names a server of the same port on another computer.
    if (-not $hostName -or -not (Test-LocalHostName -HostName $hostName)) { return $false }
    return @('match', 'unreadable') -contains (Get-RecordedProcessState -Record $App)
}

# Save state.json at $Path with Ollama = @{ Url; Alias; App }: App is $App when given, else the App state.json records while Test-OllamaAppRecord still
# finds it serving $Url, else $null, so stop never quits an app that has gone, a reused PID or the app of another server. Returns the App kept; throws as
# the state file does.
function Save-OllamaRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Url,
        [AllowEmptyString()][string]$Alias = '',
        [hashtable]$App
    )
    $state = Read-LocalAIState -Path $Path
    $kept = $App
    $previous = $state['Ollama']
    if (-not $kept -and $previous -is [hashtable] -and $previous.App -is [hashtable] -and (Test-OllamaAppRecord -App $previous.App -Url $Url)) { $kept = $previous.App }
    $state['Ollama'] = @{ Url = $Url; Alias = $Alias; App = $kept }
    Write-LocalAIState -Path $Path -State $state
    return $kept
}

# Return one object (Digest, Path) per FROM line of 'ollama show --modelfile $Name', in order: the weights first, then any vision projector.
# Returns nothing when there is no such model; throws on other failures. The server must be up, or the CLI starts the Ollama app, which
# inherits this call's output pipe and can hold it open.
function Get-OllamaModelBlob {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $code = Invoke-Native -FilePath 'ollama' -ArgumentList 'show', '--modelfile', $Name -SuccessCode 0, 1 -Capture $lines
    $text = ($lines -join ' ').Trim()
    if ($code -ne 0) {
        # Ollama 0.40.11 prints: Error: model '<name>:<tag>' not found
        if ($text -match "model '[^']*' not found") { return }
        throw "'ollama show --modelfile $Name' failed with exit code ${code}: $text"
    }
    $blobs = @(foreach ($line in $lines) {
            if ($line -match '^FROM\s+(.+?)\s*\z') {
                $from = $Matches[1]
                if ($from -notmatch '[\\/]sha256-([0-9a-fA-F]{64})\z') {
                    throw "The weights of '$Name' are not an Ollama blob: 'ollama show --modelfile' prints FROM $from."
                }
                [pscustomobject]@{ Digest = $Matches[1].ToLowerInvariant(); Path = $from }
            }
        })
    if ($blobs.Count -eq 0) { throw "'ollama show --modelfile $Name' printed no FROM line." }
    foreach ($blob in $blobs) { $blob }
}

# Throw, naming $Path, both hashes and then $Fix, unless the file hashes to the SHA-256 $Digest. A pass is recorded
# in $Verified (digest -> Length and LastWriteTimeUtc ticks), and a later call whose file still has that length and
# time skips the hash, which takes a while for a multi-GB file. Changes the table passed in.
function Confirm-FileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Digest,
        [Parameter(Mandatory)][hashtable]$Verified,
        [Parameter(Mandatory)][string]$Fix
    )
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $seen = $Verified[$Digest]
    if ($seen -is [hashtable] -and $seen.Length -eq $file.Length -and $seen.WriteTicks -eq $file.LastWriteTimeUtc.Ticks) { return }
    Write-Host ("Checking the SHA-256 of {0} ({1:0.0} GB, once)..." -f $file.Name, ($file.Length / 1GB))
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -ne $Digest) { throw "$Path hashes to $actual, not to $Digest. $Fix" }
    $Verified[$Digest] = @{ Length = $file.Length; WriteTicks = $file.LastWriteTimeUtc.Ticks }
}

# Return $true when $HostName names this PC: localhost, a loopback address, the computer name, or an
# address (given or resolved through DNS) that one of this PC's network adapters holds.
function Test-LocalHostName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostName
    )
    $name = $HostName.Trim('[', ']')
    if ($name -eq 'localhost' -or $name -eq [Environment]::MachineName) { return $true }
    $ip = $null
    if ([Net.IPAddress]::TryParse($name, [ref]$ip)) {
        $candidates = @($ip)
    } else {
        try { $candidates = @([Net.Dns]::GetHostAddresses($name)) } catch { $candidates = @() }
    }
    $local = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_.IPAddress -split '%')[0] })
    foreach ($candidate in $candidates) {
        if ([Net.IPAddress]::IsLoopback($candidate) -or $local -contains ($candidate.ToString() -split '%')[0]) { return $true }
    }
    return $false
}

# Throw, naming the drive and the free and needed GB, when the drive holding $Path has less than
# $RequiredBytes plus 10 percent free. $Path need not exist yet. A path without a drive letter,
# such as a UNC share, only warns, because its free space is not read here.
function Test-FreeSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$RequiredBytes
    )
    if ($RequiredBytes -le 0) { return }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $needed = [long][math]::Ceiling($RequiredBytes * 1.1)
    $neededGB = ($needed / 1GB).ToString('0.0', $culture)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([IO.Path]::GetPathRoot($fullPath) -notmatch '^([A-Za-z]):') {
        Write-Warning "Cannot read the free space for '$fullPath'; make sure it has $neededGB GB free."
        return
    }
    $letter = $Matches[1].ToUpperInvariant()
    $free = [long](Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction Stop).Free
    if ($free -lt $needed) {
        throw ("Drive {0}: has {1} GB free, but '{2}' needs {3} GB ({4} GB plus 10 percent headroom). Free up space on {0}:, then try again." -f
            $letter, ($free / 1GB).ToString('0.0', $culture), $fullPath, $neededGB, ($RequiredBytes / 1GB).ToString('0.0', $culture))
    }
}

# Return $true when $Blobs (from Get-OllamaModelBlob) are the weights and the vision projector that
# $Model pins in Sha256 and ProjectorSha256. An empty pin accepts any blob; no blobs at all is $false.
function Test-ChatModelPin {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [object[]]$Blobs = @(),
        [Parameter(Mandatory)][hashtable]$Model
    )
    $Blobs = @($Blobs)
    if ($Blobs.Count -eq 0) { return $false }
    if ($Model.Sha256 -and $Blobs[0].Digest -ne $Model.Sha256) { return $false }
    if ($Model.ProjectorSha256 -and ($Blobs.Count -lt 2 -or $Blobs[1].Digest -ne $Model.ProjectorSha256)) { return $false }
    return $true
}

# Return the settings path $Path unchanged when it is rooted, else joined to $RepoRoot, the repository whose
# config\defaults.psd1 was loaded (Context.RepoRoot), as config\ paths in the settings are meant. Touches no files.
function Resolve-RepoPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $RepoRoot $Path
}

# Return the lowercase SHA-256 of the file $Path, or '' when no file is there, as the install-stamp.json and venv marker comparisons
# want it. Throws when the file exists but cannot be read.
function Get-LocalAIFileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    if (-not ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf))) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

# Return the Modelfile Install-ChatModel builds Model.Alias from: Paths.Modelfile when that file exists, as it replaces the tracked one,
# else Model.Modelfile resolved against $RepoRoot, whether or not that file exists. Reads only.
function Resolve-ChatModelfile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if ($Paths.Modelfile -and (Test-Path -LiteralPath $Paths.Modelfile -PathType Leaf)) { return [string]$Paths.Modelfile }
    return Resolve-RepoPath -Path $Settings.Model.Modelfile -RepoRoot $RepoRoot
}

# Return the capabilities, such as completion, tools and thinking, that Ollama at $Url reports for the model $Name in
# POST /api/show; nothing when it reports none. Throws when Ollama does not answer within 60 s or knows no such model.
function Get-OllamaModelCapability {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Name
    )
    $body = ConvertTo-Json -InputObject @{ model = $Name } -Depth 2 -Compress
    $show = Invoke-RestMethod -Method Post -Uri "$Url/api/show" -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 60
    foreach ($capability in @($show.capabilities)) { if ($capability) { [string]$capability } }
}

# Pull Model.Source unless Ollama holds its pinned blobs, hash-check them once (recording the write time create
# gives them), create Model.Alias from the Modelfile when missing or changed and check it uses the same blobs. Sets
# and returns $State.Model (changing the table passed in); needs the server up. Throws on other blobs or no completion.
function Install-ChatModel {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [hashtable]$State = @{},
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $model = $Settings.Model
    $modelfile = Resolve-ChatModelfile -Settings $Settings -Paths $Paths -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $modelfile -PathType Leaf)) { throw "Cannot find the Modelfile '$modelfile'." }
    # Ollama builds from the last FROM line, so a second one would slip past a check of the first.
    $froms = @(foreach ($line in [IO.File]::ReadAllLines($modelfile)) {
            if ($line -match '^\s*FROM\s+(.+?)\s*\z') { $Matches[1].Trim('"') }
        })
    if ($froms.Count -ne 1 -or $froms[0] -ne $model.Source) {
        throw ("The Modelfile '$modelfile' builds FROM '$($froms -join "', '")', but Model.Source is '$($model.Source)'. " +
            'It needs exactly one FROM line, naming Model.Source.')
    }

    # The pull reuses blobs Ollama already stores; the pin check runs on every install.
    $sourceBlobs = @(Get-OllamaModelBlob -Name $model.Source)
    if (Test-ChatModelPin -Blobs $sourceBlobs -Model $model) {
        Write-Host "$($model.Source) is already in Ollama; nothing to download."
    } else {
        Write-Host "Pulling $($model.Source)..."
        $null = Invoke-Native -FilePath 'ollama' -ArgumentList 'pull', $model.Source -Console
        $sourceBlobs = @(Get-OllamaModelBlob -Name $model.Source)
        if ($sourceBlobs.Count -eq 0) { throw "'ollama pull $($model.Source)' succeeded, but Ollama has no such model afterwards." }
    }
    $digests = @($sourceBlobs | ForEach-Object { $_.Digest })
    $base = $digests[0]
    $projector = if ($digests.Count -gt 1) { $digests[1] } else { $null }
    if (-not $model.Sha256) {
        Write-Warning "Model.Sha256 is empty, so the weights of $($model.Source) (SHA-256 $base) are not checked."
    } elseif ($base -ne $model.Sha256) {
        throw ("The weights of $($model.Source) have SHA-256 $base, but Model.Sha256 pins $($model.Sha256). The file on " +
            'Hugging Face may have changed; check it, then set Model.Sha256 and Model.Size in settings.psd1 to accept it.')
    }
    if ($model.ProjectorSha256 -and $projector -ne $model.ProjectorSha256) {
        $found = if ($projector) { "has SHA-256 $projector" } else { 'is missing' }
        throw ("The vision projector of $($model.Source) $found, but Model.ProjectorSha256 pins $($model.ProjectorSha256). " +
            'Check the repository on Hugging Face, then set Model.ProjectorSha256 and Model.Size in settings.psd1 to accept it.')
    } elseif ($projector -and -not $model.ProjectorSha256) {
        Write-Warning "Model.ProjectorSha256 is empty, so the vision projector of $($model.Source) (SHA-256 $projector) is not checked."
    }

    # The pull skips a blob it finds by name without hashing it, so the pinned ones are hashed here.
    $recorded = $State['Model']
    if ($recorded -isnot [hashtable]) { $recorded = @{} }
    $verified = $recorded['VerifiedBlobs']
    if ($verified -isnot [hashtable]) { $verified = @{} }
    foreach ($blob in $sourceBlobs) {
        if (@($model.Sha256, $model.ProjectorSha256) -contains $blob.Digest) {
            Confirm-FileHash -Path $blob.Path -Digest $blob.Digest -Verified $verified -Fix ('That Ollama blob is damaged, since its ' +
                'name promises that hash. Delete that file, then run install again: the pull downloads it again.')
        }
    }

    $modelfileSha = (Get-FileHash -LiteralPath $modelfile -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $aliasDigests = @(Get-OllamaModelBlob -Name $model.Alias | ForEach-Object { $_.Digest })
    $reason = $null
    if ($aliasDigests.Count -eq 0) {
        $reason = 'it does not exist yet'
    } elseif ($recorded.Alias -ne $model.Alias -or -not $recorded.ModelfileSha256) {
        $reason = 'state.json does not record how it was built'
    } elseif ($recorded.ModelfileSha256 -ne $modelfileSha) {
        $reason = 'the Modelfile changed'
    } elseif ($recorded.BaseDigest -ne $base -or ($aliasDigests -join ',') -ne ($digests -join ',')) {
        $reason = "its blobs differ from $($model.Source)"
    }
    if ($reason) {
        Write-Host "Creating $($model.Alias) from $modelfile ($reason)..."
        $null = Invoke-Native -FilePath 'ollama' -ArgumentList 'create', $model.Alias, '-f', $modelfile -Console
        $aliasDigests = @(Get-OllamaModelBlob -Name $model.Alias | ForEach-Object { $_.Digest })
        if (($aliasDigests -join ',') -ne ($digests -join ',')) {
            throw ("After 'ollama create', $($model.Alias) uses the blobs '$($aliasDigests -join ', ')' instead of " +
                "'$($digests -join ', ')' from $($model.Source). Check $modelfile.")
        }
        # Ollama 0.40.11's create sets a new write time on the blobs it reuses, which this run checked above, so the
        # record follows it; otherwise the next install would hash them again. A blob whose length changed keeps its old record.
        foreach ($blob in $sourceBlobs) {
            $seen = $verified[$blob.Digest]
            $file = Get-Item -LiteralPath $blob.Path -ErrorAction SilentlyContinue
            if ($seen -is [hashtable] -and $file -and $file.Length -eq $seen.Length) { $seen['WriteTicks'] = $file.LastWriteTimeUtc.Ticks }
        }
    } else {
        Write-Host "$($model.Alias) is up to date."
    }

    $capabilities = @(Get-OllamaModelCapability -Url $Url -Name $model.Alias)
    if ($capabilities -notcontains 'completion') {
        throw "Ollama does not report the 'completion' capability for $($model.Alias) (it reports '$($capabilities -join ', ')'). Check $modelfile."
    }
    $missing = @(foreach ($capability in 'tools', 'thinking') { if ($capabilities -notcontains $capability) { $capability } })
    if ($missing.Count -gt 0) {
        Write-Warning "Ollama does not report the $($missing -join ' or ') capability for $($model.Alias). Check the RENDERER and PARSER lines in $modelfile."
    }
    $State['Model'] = @{
        Alias               = $model.Alias
        Source              = $model.Source
        BaseDigest          = $base
        ProjectorDigest     = $projector
        VerifiedBlobs       = $verified
        Modelfile           = $modelfile
        ModelfileSha256     = $modelfileSha
        Capabilities        = $capabilities
        MissingCapabilities = $missing
    }
    return $State
}

# Check, unless $Blobs (Get-OllamaModelBlob for Model.Source) already pass Test-ChatModelPin, that Ollama's store (OLLAMA_MODELS from
# this process, then the User environment, else %USERPROFILE%\.ollama\models) has room for the pull of Model.Source: Model.Size less
# the pinned blobs it already holds, such as the weights of an older alias. Returns nothing; throws or warns as Test-FreeSpace does.
function Test-ChatModelSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [AllowEmptyCollection()][object[]]$Blobs = @()
    )
    if (Test-ChatModelPin -Blobs $Blobs -Model $Settings.Model) { return }
    $store = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Process')
    if (-not $store) { $store = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User') }
    if (-not $store) { $store = Join-Path $env:USERPROFILE '.ollama\models' }
    # The pull skips blobs the store already holds.
    $required = [long]$Settings.Model.Size
    foreach ($digest in @($Settings.Model.Sha256, $Settings.Model.ProjectorSha256)) {
        $blob = if ($digest) { Join-Path $store "blobs\sha256-$digest" } else { $null }
        if ($blob -and (Test-Path -LiteralPath $blob -PathType Leaf)) { $required -= (Get-Item -LiteralPath $blob).Length }
    }
    Test-FreeSpace -Path $store -RequiredBytes $required
}

# Throw unless the ollama program, which reads OLLAMA_HOST from this process only, talks to the server at
# $Url that the REST calls use, so list, show, pull and create reach that server. Returns nothing.
function Assert-OllamaCliUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url
    )
    $cliUrl = Resolve-OllamaUrl -Setting '' -UserHost ''
    if ($Url -ne $cliUrl) {
        throw ("The REST checks would use Ollama at $Url, but the ollama program would use $cliUrl, because it " +
            'reads OLLAMA_HOST from this window only. Set OLLAMA_HOST to the server Ollama.Url names (or clear ' +
            'Ollama.Url), open a new window, then try again.')
    }
}

# The install verb, with the PC kept awake: install Ollama, uv (and Git for images) with winget, the chat model, Open WebUI, with
# Files.Root the file tools and a Test-FilesRoot check, and with Images.Enabled ComfyUI, its checkpoint and a workflow check, saving state.json
# and install-stamp.json after each part. An Ollama app that its waits or the Ollama installer started is recorded in state.json at once, for stop.
# Returns 0, or 2 when a step warned or the file or image part failed (chat stays usable); chat failures throw.
function Install-LocalAI {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $settings = $Context.Settings
    $paths = $Context.Paths
    $warned = @()
    Set-LocalAIKeepAwake -Enabled $true
    try {
        Update-SessionPath
        $url = Resolve-OllamaUrl -Setting $settings.Ollama.Url
        Assert-OllamaCliUrl -Url $url

        # An installed Ollama tells whether the model still has to be downloaded.
        $blobs = @()
        if (Get-Command -Name 'ollama' -CommandType Application -ErrorAction SilentlyContinue) {
            $wait = Wait-OllamaServer -Url $url -PassThru -How 'install'
            # Saved at once, so stop quits the app this wait started also when a later step throws.
            if ($wait.App) { $null = Save-OllamaRecord -Path $paths.State -Url $url -Alias $settings.Model.Alias -App $wait.App }
            $blobs = @(Get-OllamaModelBlob -Name $settings.Model.Source)
        }
        Test-ChatModelSpace -Settings $settings -Blobs $blobs -WarningVariable +warned

        # Ollama's installer starts the app when it is done. That app counts as this install's only when no app ran before (Get-OllamaOwnStart).
        $appsBefore = $null
        try {
            $appsBefore = @(Get-OllamaAppProcess)
        } catch {
            Write-Verbose "The Ollama apps cannot be listed, so install records no app the Ollama installer starts: $($_.Exception.Message)"
        }
        $since = [DateTime]::UtcNow.AddSeconds(-1).Ticks
        $packages = @($settings.Winget.Packages.Ollama, $settings.Winget.Packages.Uv)
        # ComfyUI is a git checkout.
        if ($settings.Images.Enabled) { $packages += $settings.Winget.Packages.Git }
        foreach ($package in $packages) {
            $null = Install-WingetPackage -Package $package -LogDir $paths.Logs -WarningVariable +warned
        }
        $wait = Wait-OllamaServer -Url $url -PassThru -How 'install'
        $version = $wait.Version
        $app = $wait.App
        if (-not $app -and $null -ne $appsBefore -and $appsBefore.Count -eq 0) {
            $app = Get-OllamaOwnStart -Before @() -Since $since -Url $url -ExpectedPath ([string](Resolve-OllamaAppPath)) -How 'install'
            if ($app) { Write-Host "The Ollama installer started the Ollama app (PID $($app.Pid)); local-ai stop quits it again." }
        }
        if ($app) { $null = Save-OllamaRecord -Path $paths.State -Url $url -Alias $settings.Model.Alias -App $app }
        Write-Host "Ollama $version answers at $url."
        $null = Test-OllamaLoopback -Url $url -WarningVariable +warned

        $state = Read-LocalAIState -Path $paths.State
        $state = Install-ChatModel -Settings $settings -Paths $paths -State $state -Url $url -RepoRoot $Context.RepoRoot -WarningVariable +warned
        Write-LocalAIState -Path $paths.State -State $state
        $openWebUI = Install-OpenWebUI -Settings $settings -Paths $paths -WarningVariable +warned
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
        $stamp['Ollama'] = @{ Version = $version }
        $stamp['Model'] = @{
            Alias           = $state.Model.Alias
            BaseDigest      = $state.Model.BaseDigest
            ProjectorDigest = $state.Model.ProjectorDigest
            ModelfileSha256 = $state.Model.ModelfileSha256
        }
        $stamp['OpenWebUI'] = Get-OpenWebUIStampEntry -Tool $openWebUI -ToolDir ([string]$openWebUI.ToolDir) -DataDir $settings.OpenWebUI.DataDir
        # The file and image entries are written back step by step, so a run that fails or is stopped part-way leaves none
        # that start would trust. Saved before those parts, so start can bring up chat even when they fail.
        $recordedFiles = $stamp['Files']
        if ($settings.Files.Root) { $stamp.Remove('Files') }
        if ($settings.Images.Enabled) {
            $stamp.Remove('ComfyUI')
            $stamp.Remove('Images')
        }
        Write-LocalAIState -Path $paths.InstallStamp -State $stamp

        $filesReady = $false
        if ($settings.Files.Root) {
            try {
                $stamp['Files'] = Install-FilesServer -Settings $settings -Paths $paths -RepoRoot $Context.RepoRoot -Stamp $stamp -Recorded $recordedFiles `
                    -WarningVariable +warned
                Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                # start serves no folder Test-FilesRoot refuses, so install names the problem too; it warns with the reason.
                $filesReady = Test-FilesRoot -Settings $settings -Paths $paths -RepoRoot $Context.RepoRoot -ToolDir ([string]$stamp['Files'].ToolDir) -WarningVariable +warned
            } catch {
                Write-Warning ("The file tools are not set up: $($_.Exception.Message) Chat works without them; fix that, then run " +
                    "'local-ai install' again, or set Files.Root = '' in settings.psd1.") -WarningVariable +warned
            }
        }

        $imagesReady = $false
        if ($settings.Images.Enabled) {
            try {
                $comfy = Install-ComfyUI -Settings $settings -RepoRoot $Context.RepoRoot -WarningVariable +warned
                $stamp['ComfyUI'] = @{
                    Dir           = $comfy.Dir
                    Commit        = $comfy.Commit
                    Ref           = $(if ($comfy.Pinned) { $settings.ComfyUI.Ref } else { $null })
                    Pinned        = $comfy.Pinned
                    # Whether uninstall -RemoveData may delete the checkout.
                    Cloned        = [bool]$comfy.Cloned
                    Python        = $comfy.Python
                    PythonVersion = $comfy.PythonVersion
                    Torch         = $comfy.Torch
                }
                Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                $images = $state['Images']
                if ($images -isnot [hashtable]) { $images = @{} }
                $verified = $images['VerifiedFiles']
                if ($verified -isnot [hashtable]) { $verified = @{} }
                $checkpoint = Install-ImageModel -Settings $settings -Verified $verified -WarningVariable +warned
                $state['Images'] = @{ VerifiedFiles = $verified }
                Write-LocalAIState -Path $paths.State -State $state
                $stamp['Images'] = @{ File = $settings.Images.File; Sha256 = $checkpoint.Sha256 }
                Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                # start turns images off while the workflow files do not load, so install names the problem too.
                $null = Get-ImageWorkflow -Settings $settings -RepoRoot $Context.RepoRoot
                $imagesReady = $true
            } catch {
                Write-Warning ("Images are not set up: $($_.Exception.Message) Chat works without them; fix that, then run " +
                    "'local-ai install' again, or set Images.Enabled = `$false in settings.psd1.") -WarningVariable +warned
            }
        }
    } finally {
        Set-LocalAIKeepAwake -Enabled $false
    }
    if ($warned.Count -gt 0) {
        Write-Host "Install finished with $($warned.Count) warning(s); see above." -ForegroundColor Yellow
        return 2
    }
    $done = "$($settings.Model.Alias) is ready in Ollama, and Open WebUI $($openWebUI.Version) is installed"
    if ($filesReady) { $done += ", as are the file tools for $($settings.Files.Root)" }
    if ($imagesReady) { $done += ", as are ComfyUI and $($settings.Images.File)" }
    Write-Host "Install finished. $done." -ForegroundColor Green
    return 0
}

# Return @{ Version; Python; Path } for the uv tool $Name as 'uv tool list' shows it: Python is the
# tool environment's interpreter version and Path the entry point of the same name, $null when uv
# shows none. Returns $null when uv lists no such tool; throws when uv is missing or fails.
function Get-UvTool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $null = Invoke-Native -FilePath 'uv' -ArgumentList 'tool', 'list', '--show-paths', '--show-python', '--color', 'never' -Capture $lines
    # uv 0.13.6 prints '<name> v<version> [CPython 3.11.17] (<tool dir>)', then '- <entry point> (<path>)'
    # per executable. 'No tools installed' and warnings go to stderr and match neither form.
    $tool = $null
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^([^\s-]\S*) v(\d\S*)(.*)\z') {
            $current = $Matches[1]
            if ($current -eq $Name) {
                $tool = @{ Version = $Matches[2]; Python = $null; Path = $null }
                if ($Matches[3] -match '\[[A-Za-z]+ (\d[^\]\s]*)\]') { $tool.Python = $Matches[1] }
            }
        } elseif ($tool -and $current -eq $Name -and $line -match '^- (.+?) \((.+)\)\s*\z' -and $Matches[1] -eq $Name) {
            $tool.Path = $Matches[2]
        }
    }
    return $tool
}

# Return the folder uv installs tools into, the last line 'uv tool dir' prints; uv takes it from UV_TOOL_DIR when that is
# set. Throws when uv fails or prints no folder.
function Get-UvToolDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $lines = New-Object System.Collections.Generic.List[string]
    $null = Invoke-Native -FilePath 'uv' -ArgumentList 'tool', 'dir' -Capture $lines
    $folders = @($lines | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    if ($folders.Count -eq 0) { throw "'uv tool dir' printed no folder." }
    return $folders[-1]
}

# Run 'uv tool install' on the console for the requirement $Package on Python $Python, adding --managed-python, one --with
# per $With entry, --exclude-newer $ExcludeNewer, -c $Constraints (a constraints file) and --reinstall as given, and return
# Get-UvTool for $Name. Throws when uv fails or lists no such tool afterwards.
function Install-UvTool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Python,
        [string[]]$With = @(),
        [string]$ExcludeNewer,
        [string]$Constraints,
        [switch]$ManagedPython,
        [switch]$Reinstall
    )
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in 'tool', 'install', '--python', $Python) { $arguments.Add($argument) }
    if ($ManagedPython) { $arguments.Add('--managed-python') }
    $arguments.Add($Package)
    foreach ($requirement in $With) { $arguments.Add('--with'); $arguments.Add($requirement) }
    if ($ExcludeNewer) { $arguments.Add('--exclude-newer'); $arguments.Add($ExcludeNewer) }
    if ($Constraints) { $arguments.Add('-c'); $arguments.Add($Constraints) }
    if ($Reinstall) { $arguments.Add('--reinstall') }
    $null = Invoke-Native -FilePath 'uv' -ArgumentList $arguments.ToArray() -Console
    $tool = Get-UvTool -Name $Name
    if (-not $tool) { throw "'uv tool install $Package' succeeded, but 'uv tool list' does not list $Name." }
    return $tool
}

# Copy webui.db (with any -wal and -shm file) and .webui_secret_key from $DataDir into the folder
# $BackupRoot\open-webui-<yyyyMMdd-HHmmss>, created here, and return its path, or $null when $DataDir
# holds no webui.db. Throws when a copy fails, keeping what was copied.
function Backup-OpenWebUIData {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$BackupRoot
    )
    if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'webui.db') -PathType Leaf)) { return $null }
    $target = Join-Path $BackupRoot ('open-webui-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    $null = New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop
    foreach ($file in 'webui.db', 'webui.db-wal', 'webui.db-shm', '.webui_secret_key') {
        $source = Join-Path $DataDir $file
        if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop }
    }
    return $target
}

# Return install-stamp.json's OpenWebUI entry for the uv tool $Tool (@{ Version; Path; Python }) in the tool folder $ToolDir, run on the data
# folder $DataDir as a full path, plus the keys of $Extra. uninstall removes the tool only from ToolDir, and -RemoveData with settings.psd1 that
# do not load deletes only that DataDir. Pure.
function Get-OpenWebUIStampEntry {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Tool,
        [AllowEmptyString()][string]$ToolDir,
        [AllowEmptyString()][string]$DataDir,
        [hashtable]$Extra = @{}
    )
    $entry = @{
        Version = $Tool.Version
        Path    = $Tool.Path
        Python  = $Tool.Python
        ToolDir = $(if ($ToolDir) { $ToolDir } else { $null })
        DataDir = $(if ($DataDir) { Resolve-FolderPath -Path $DataDir } else { $null })
    }
    foreach ($key in $Extra.Keys) { $entry[$key] = $Extra[$key] }
    return $entry
}

# Install the uv tool open-webui when absent: OpenWebUI.Version on OpenWebUI.Python, after an InstallBytes free-space check and a
# backup of any webui.db; an installed one is never changed, as update owns its one-way migrations. Returns @{ Version; Path; Python;
# ToolDir (uv's tool folder) } as uv lists it; throws when uv fails or lists no entry point.
function Install-OpenWebUI {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths
    )
    $pin = $Settings.OpenWebUI.Version
    $python = $Settings.OpenWebUI.Python
    $tool = Get-UvTool -Name 'open-webui'
    $toolDir = Get-UvToolDir
    if (-not $tool) {
        Test-FreeSpace -Path $toolDir -RequiredBytes $Settings.OpenWebUI.InstallBytes
        # The pin's first start migrates an existing database one way.
        $dataDir = $Settings.OpenWebUI.DataDir
        $backup = Backup-OpenWebUIData -DataDir $dataDir -BackupRoot $Paths.Backups
        if ($backup) { Write-Host "$dataDir holds a database; it is backed up to $backup before Open WebUI $pin migrates it." }
        Write-Host "Installing Open WebUI $pin on Python $python with uv..."
        $tool = Install-UvTool -Name 'open-webui' -Package "open-webui==$pin" -Python $python
    } elseif ($tool.Version -ne $pin) {
        # Only a warning: the pin's first start would migrate the database one way.
        Write-Warning ("Open WebUI $($tool.Version) is installed, but OpenWebUI.Version pins $pin; it is left as it is. Run " +
            "'local-ai update' to change versions: it backs up the data folder first, because Open WebUI's database migrations cannot be undone.")
    } else {
        Write-Host "Open WebUI $pin is installed."
    }
    if (-not $tool.Path) { throw "'uv tool list' shows no open-webui entry point for the open-webui tool. Reinstall it with uv." }
    return @{ Version = $tool.Version; Path = $tool.Path; Python = $tool.Python; ToolDir = $toolDir }
}

# Return the base URL's Open WebUI version: GET /health must answer {"status": true} and GET
# /api/version a version string, each within 5 s. Throws naming the URL for any other responder.
function Get-OpenWebUIVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url
    )
    $health = Invoke-RestMethod -Uri "$Url/health" -UseBasicParsing -TimeoutSec 5
    if (-not ($health.status -is [bool] -and $health.status)) {
        throw "GET $Url/health did not answer {`"status`": true}, so it is not Open WebUI."
    }
    $answer = Invoke-RestMethod -Uri "$Url/api/version" -UseBasicParsing -TimeoutSec 5
    if (-not ($answer.version -is [string] -and $answer.version)) {
        throw "GET $Url/api/version did not answer with a version, so it is not Open WebUI."
    }
    return $answer.version
}

# Return the version ComfyUI reports at the base URL: GET /system_stats must answer within 5 s with a
# system.comfyui_version string. Throws naming the URL for any other responder.
function Get-ComfyUIVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url
    )
    $answer = Invoke-RestMethod -Uri "$Url/system_stats" -UseBasicParsing -TimeoutSec 5
    $version = $answer.system.comfyui_version
    if (-not ($version -is [string] -and $version)) {
        throw "GET $Url/system_stats did not answer with system.comfyui_version, so it is not ComfyUI."
    }
    return $version
}

# Return the version the image gate at the base URL reports: GET /local-ai/image-gate must answer within 5 s as the service
# local-ai-image-gate in front of $Upstream, unloading $Model from $Ollama, each compared with case. Throws naming what differs.
function Get-ImageGateVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Upstream,
        [Parameter(Mandatory)][string]$Ollama,
        [Parameter(Mandatory)][string]$Model
    )
    $answer = Invoke-RestMethod -Uri "$Url/local-ai/image-gate" -UseBasicParsing -TimeoutSec 5
    if (-not ($answer.service -is [string] -and $answer.service -ceq 'local-ai-image-gate' -and $answer.version -is [string] -and $answer.version)) {
        throw "GET $Url/local-ai/image-gate did not answer as local-ai-image-gate with a version, so it is not the image gate."
    }
    $wanted = [ordered]@{ upstream = $Upstream; ollama = $Ollama; model = $Model }
    foreach ($key in $wanted.Keys) {
        if ([string]$answer.$key -cne $wanted[$key]) {
            throw "The image gate at $Url has $key '$($answer.$key)', not '$($wanted[$key])'."
        }
    }
    return $answer.version
}

# Return $true when ComfyUI at the base URL lists the checkpoint $File, with its exact case as ComfyUI compares it, in GET
# /object_info/CheckpointLoaderSimple. Otherwise warn, naming what it lists or why the request failed, and return $false.
function Test-ComfyUICheckpoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$File
    )
    try {
        $answer = Invoke-RestMethod -Uri "$Url/object_info/CheckpointLoaderSimple" -UseBasicParsing -TimeoutSec 30
    } catch {
        Write-Warning "Could not read the checkpoints ComfyUI lists at $Url/object_info/CheckpointLoaderSimple: $($_.Exception.Message)"
        return $false
    }
    # ckpt_name is [[<file names>], {"tooltip": ...}].
    $listed = @(@($answer.CheckpointLoaderSimple.input.required.ckpt_name)[0] | Where-Object { $_ -is [string] })
    if ($listed -ccontains $File) { return $true }
    $names = if ($listed.Count -gt 0) { "'$($listed -join "', '")'" } else { 'none' }
    Write-Warning ("ComfyUI lists the checkpoints $names, not $File, so Open WebUI's images fail. Run 'local-ai install', " +
        'which puts the pinned checkpoint in place.')
    return $false
}

# Return $true when ComfyUI at the base URL lists a CUDA device first in GET /system_stats, the one it renders on. Otherwise
# warn, naming the device it reports or why the request failed, and return $false.
function Test-ComfyUIDevice {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Url
    )
    try {
        $answer = Invoke-RestMethod -Uri "$Url/system_stats" -UseBasicParsing -TimeoutSec 5
    } catch {
        Write-Warning "Could not read the device ComfyUI renders on at $Url/system_stats: $($_.Exception.Message)"
        return $false
    }
    $device = @($answer.devices)[0]
    if ($device -and [string]$device.type -eq 'cuda') { return $true }
    $what = if ($device) { "$($device.name) (type $($device.type))" } else { 'no device' }
    Write-Warning ("ComfyUI reports $what, not a CUDA GPU, so each image takes many minutes. Check the NVIDIA driver with " +
        'nvidia-smi, then start again.')
    return $false
}

# Return the base Python that the venv $Venv names in its pyvenv.cfg as @{ Home (its folder, '' when none is named); Version (as written, such as '3.13.14',
# or '3.13' for a uv-managed Python; $null when none is named); Minor ('3.13', or $null); Store ($true when Home lies in a WindowsApps folder, as the Microsoft
# Store Python does) }, or $null when the venv has no pyvenv.cfg. uv writes version_info, Python's own venv module writes version. Reads only.
function Get-VenvBasePython {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Venv
    )
    $config = [IO.Path]::Combine($Venv, 'pyvenv.cfg')
    if (-not [IO.File]::Exists($config)) { return $null }
    $folder = ''
    $version = $null
    $minor = $null
    foreach ($line in [IO.File]::ReadAllLines($config)) {
        if ($line -match '^\s*home\s*=\s*(.*?)\s*\z') {
            $folder = $Matches[1]
        } elseif ($line -match '^\s*version(?:_info)?\s*=\s*((\d+)\.(\d+)\S*)') {
            $version = $Matches[1]
            $minor = "$($Matches[2]).$($Matches[3])"
        }
    }
    # The Store Python's app execution alias lies in %LOCALAPPDATA%\Microsoft\WindowsApps, its files in %ProgramFiles%\WindowsApps. The venv's python.exe
    # launches the base Python through that alias, which can fail or hang until Windows restarts.
    return @{ Home = $folder; Version = $version; Minor = $minor; Store = $folder -match '(?:^|\\)WindowsApps(?:\\|\z)' }
}

# Return why start cannot run ComfyUI, or $null when it can: install-stamp.json $Stamp names a venv python.exe that exists in the
# current ComfyUI.Dir and the Images.File and Images.Sha256 install checked, and the file still has the length and write time
# state.json $State recorded (no hashing). Warns, without stopping ComfyUI, when requirements.txt changed since the venv was set up,
# and when the venv runs on the Microsoft Store Python.
function Get-ComfyUIStartProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][hashtable]$State
    )
    $install = "Run 'local-ai install' to set it up."
    $comfyUI = $Stamp['ComfyUI']
    if ($comfyUI -isnot [hashtable] -or -not ($comfyUI.Python -and (Test-Path -LiteralPath $comfyUI.Python -PathType Leaf))) {
        return "install-stamp.json names no ComfyUI python.exe that exists ('$($comfyUI.Python)'). $install"
    }
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Settings.ComfyUI.Dir)
    if ($dir.Length -gt 3) { $dir = $dir.TrimEnd('\') }
    if ([string]$comfyUI.Dir -ne $dir) {
        return "install set up ComfyUI in '$($comfyUI.Dir)', but ComfyUI.Dir is '$dir'. $install"
    }
    $images = $Settings.Images
    $checked = $Stamp['Images']
    if ($checked -isnot [hashtable] -or $checked.File -cne $images.File -or $checked.Sha256 -ne $images.Sha256) {
        return "install has not checked $($images.File) against Images.Sha256 yet. $install"
    }
    $target = Join-Path $dir "models\checkpoints\$($images.File)"
    $file = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
    $seen = $null
    if ($images.Sha256) {
        $verified = $State['Images']
        if ($verified -is [hashtable] -and $verified['VerifiedFiles'] -is [hashtable]) { $seen = $verified['VerifiedFiles'][$images.Sha256] }
    }
    if (-not $file -or $file.Length -ne [long]$images.Size -or
        ($images.Sha256 -and -not ($seen -is [hashtable] -and $seen.Length -eq $file.Length -and $seen.WriteTicks -eq $file.LastWriteTimeUtc.Ticks))) {
        return "$target is missing or changed since install checked it. Run 'local-ai install' to check it again."
    }
    # A checkout moved by hand may need other packages than the venv holds.
    $requirements = Join-Path $dir 'requirements.txt'
    $marker = @{}
    try { $marker = Read-LocalAIState -Path (Join-Path $dir '.venv\local-ai-install.json') } catch { $marker = @{} }
    $sha = if (Test-Path -LiteralPath $requirements -PathType Leaf) {
        (Get-FileHash -LiteralPath $requirements -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } else { '' }
    if ($marker['RequirementsSha256'] -ne $sha) {
        Write-Warning ("$requirements is not the one ComfyUI's venv was set up for, so ComfyUI may lack packages it needs. Run " +
            "'local-ai install', which updates the venv.")
    }
    $base = Get-VenvBasePython -Venv (Join-Path $dir '.venv')
    if ($base -and $base.Store) {
        Write-Warning ("ComfyUI's venv runs on the Microsoft Store Python $($base.Version), whose launches can fail or hang until Windows restarts, and " +
            "ComfyUI and the image gate with them. Run 'local-ai update', which makes the venv anew on a uv-managed Python.")
    }
    return $null
}

# Return the commit git reports as HEAD of the checkout in $Dir. Throws with git's own text when git fails, as in a folder
# whose clone was interrupted or that git refuses for its owner, or when git prints no commit.
function Get-GitHead {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Dir
    )
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        $null = Invoke-Native -FilePath 'git' -ArgumentList '-C', $Dir, 'rev-parse', 'HEAD' -Capture $lines
    } catch {
        throw "$($_.Exception.Message) git said: $(@($lines | Where-Object { $_.Trim() }) -join ' ')"
    }
    $heads = @($lines | Where-Object { $_ -match '^[0-9a-f]{40}\z' })
    if ($heads.Count -eq 0) { throw "'git -C $Dir rev-parse HEAD' printed no commit." }
    return $heads[-1]
}

# Return the running processes, as Get-Process lists them, whose program is one of the files $File or lies below one of the folders $Folder,
# compared without case. Processes whose path this window cannot read are left out. Changes nothing.
function Get-BusyProcess {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [string[]]$Folder = @(),
        [string[]]$File = @()
    )
    $below = @(foreach ($item in $Folder) { if ($item) { $item.TrimEnd('\') + '\' } })
    $programs = @($File | Where-Object { $_ })
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $path = [string]$_.Path
        $path -and (@($programs | Where-Object { $path.Equals($_, $ignoreCase) }).Count -gt 0 -or
            @($below | Where-Object { $path.StartsWith($_, $ignoreCase) }).Count -gt 0)
    }
}

# Make ComfyUI.Dir a ComfyUI checkout with a .venv: clone ComfyUI.Ref beside a missing or empty Dir and move it in only when HEAD is
# ComfyUI.Commit, keep another checkout as it is with a warning, create a missing .venv on a uv-managed Python and keep one found in place,
# with a warning when it runs on the Microsoft Store Python, then unless .venv\local-ai-install.json matches, pip-install requirements.txt
# and check for CUDA torch. Returns @{ Dir; Commit; Pinned; Cloned (.git\local-ai-clone.json marks a clone of its own); Python; PythonVersion; Torch; TorchVision; Cuda }.
function Install-ComfyUI {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $comfy = $Settings.ComfyUI
    foreach ($program in 'git', 'uv') {
        if (-not (Get-Command -Name $program -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "Installing ComfyUI needs $program, which is not on PATH."
        }
    }
    if ($comfy.Python -notmatch '^(\d+)\.(\d+)') { throw "ComfyUI.Python '$($comfy.Python)' must name a Python version such as '3.13'." }
    $wanted = "$($Matches[1]).$($Matches[2])"
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($comfy.Dir)
    # A trailing '\' would put the clone folder inside Dir instead of beside it.
    if ($dir.Length -gt 3) { $dir = $dir.TrimEnd('\') }
    $venv = Join-Path $dir '.venv'
    $python = Join-Path $venv 'Scripts\python.exe'

    if (Test-Path -LiteralPath $dir -PathType Leaf) { throw "ComfyUI.Dir '$dir' is a file, not a folder." }
    $empty = -not (Test-Path -LiteralPath $dir) -or @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop | Select-Object -First 1).Count -eq 0
    if (-not $empty -and -not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        throw ("ComfyUI.Dir '$dir' holds files but is not a git checkout, so install does not clone ComfyUI into it. " +
            'Set ComfyUI.Dir in settings.psd1 to a missing or empty folder, or move those files away.')
    }
    if ($empty -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
        Test-FreeSpace -Path $dir -RequiredBytes $comfy.InstallBytes
    }
    if ($empty) {
        # Cloned beside Dir and moved in only at the pin, so a tag that has moved leaves no checkout that a later run would adopt.
        # The folder is the launcher's own; one an interrupted run left is of no use.
        $clone = $dir + '.local-ai-clone'
        if (Test-Path -LiteralPath $clone) { Remove-Item -LiteralPath $clone -Recurse -Force -ErrorAction Stop }
        Write-Host "Cloning ComfyUI $($comfy.Ref) into $dir..."
        try {
            $null = Invoke-Native -FilePath 'git' -ArgumentList '-c', 'advice.detachedHead=false', 'clone', '--depth', '1', '--branch', $comfy.Ref,
                $comfy.Repo, $clone -Console
            $commit = Get-GitHead -Dir $clone
            if ($commit -ne $comfy.Commit) {
                throw ("The clone of $($comfy.Ref) from $($comfy.Repo) is at commit $commit, not at ComfyUI.Commit $($comfy.Commit), so the tag " +
                    'has moved. Check that release and make ComfyUI.Ref and ComfyUI.Commit agree, then run install again.')
            }
            # Inside .git, which git neither tracks nor copies, so the mark stays with this checkout only: uninstall -RemoveData deletes a
            # checkout install cloned, never one it adopted.
            Write-LocalAIState -Path (Join-Path $clone '.git\local-ai-clone.json') -State @{ Kind = 'local-ai-clone'; Repo = $comfy.Repo; Ref = $comfy.Ref; Commit = $commit }
            # Delete refuses a folder that is not empty; on one drive the move is a rename.
            if (Test-Path -LiteralPath $dir) { [IO.Directory]::Delete($dir) }
            [IO.Directory]::Move($clone, $dir)
        } finally {
            if (Test-Path -LiteralPath $clone) {
                Remove-Item -LiteralPath $clone -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $clone) { Write-Warning "Could not remove $clone; delete it to free its space." }
            }
        }
    } else {
        $commit = Get-GitHead -Dir $dir
    }
    $cloneMark = @{}
    try { $cloneMark = Read-LocalAIState -Path (Join-Path $dir '.git\local-ai-clone.json') } catch { $cloneMark = @{} }
    $cloned = $cloneMark['Kind'] -eq 'local-ai-clone'
    $pinned = $commit -eq $comfy.Commit
    if ($pinned) {
        Write-Host "ComfyUI in $dir is at $($comfy.Ref) ($commit)."
    } else {
        Write-Warning ("ComfyUI in $dir is at commit $commit, but ComfyUI.Commit pins $($comfy.Commit) ($($comfy.Ref)); it is left " +
            "as it is. Run 'local-ai update' to move it to the pin.")
    }

    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        if (Test-Path -LiteralPath $venv) {
            throw "$venv exists but has no Scripts\python.exe, so it is not a usable venv. Move it away, then run install again."
        }
        Write-Host "Creating $venv on a uv-managed Python $($comfy.Python)..."
        $null = Invoke-Native -FilePath 'uv' -ArgumentList 'venv', '--python', $comfy.Python, '--managed-python', $venv -Console
        # Kept through every later marker, so uninstall removes only a venv install made, not one it found in place, such as another program's.
        Write-LocalAIState -Path (Join-Path $venv 'local-ai-install.json') -State @{ CreatedVenv = $true }
    }
    # uv writes version_info, Python's own venv module writes version.
    $config = Join-Path $venv 'pyvenv.cfg'
    $base = Get-VenvBasePython -Venv $venv
    $minor = if ($base) { $base.Minor } else { $null }
    if (-not $minor) { throw "$config names no Python version, so $venv is not a Python venv." }
    if ($minor -ne $wanted) {
        throw ("$venv runs Python $minor, but ComfyUI.Python is $($comfy.Python). install never deletes a venv: move $venv away, so " +
            "install creates a Python $wanted one, or set ComfyUI.Python to '$minor' in settings.psd1. Then run install again.")
    }
    if ($base.Store) {
        Write-Warning ("$venv runs on the Microsoft Store Python $($base.Version), whose launches can fail or hang until Windows restarts, and ComfyUI " +
            "and the image gate with them. install never deletes a venv; run 'local-ai update', which makes it anew on a uv-managed Python $wanted with the same pins.")
    }

    $constraints = Resolve-RepoPath -Path $comfy.Constraints -RepoRoot $RepoRoot
    $requirements = Join-Path $dir 'requirements.txt'
    $wantedMarker = @{
        RequirementsSha256 = (Get-FileHash -LiteralPath $requirements -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        ConstraintsSha256  = (Get-FileHash -LiteralPath $constraints -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        Backend            = $comfy.TorchBackend
        ExcludeNewer       = $comfy.ExcludeNewer
    }
    $markerPath = Join-Path $venv 'local-ai-install.json'
    $marker = @{}
    try {
        $marker = Read-LocalAIState -Path $markerPath
    } catch {
        Write-Host "Ignoring the install marker: $($_.Exception.Message)"
    }
    $stale = @(foreach ($key in $wantedMarker.Keys) { if ($marker[$key] -ne $wantedMarker[$key]) { $key } })
    if ($stale.Count -eq 0) {
        Write-Host "The ComfyUI venv matches requirements.txt, the constraints and the $($comfy.TorchBackend) backend; nothing to install."
        $build = @{ python = $marker.Python; torch = $marker.Torch; torchvision = $marker.TorchVision; cuda = $marker.Cuda }
    } else {
        # Windows locks the files a running Python has loaded, so uv could replace only part of the venv. The image gate runs on it too.
        $busy = @(Get-BusyProcess -Folder $venv)
        if ($busy.Count -gt 0) {
            throw ("ComfyUI or the image gate runs from $venv (PID $(@($busy | ForEach-Object { $_.Id }) -join ', ')), so uv cannot replace its " +
                "files. Run 'local-ai stop', or close the ComfyUI another program started, then run install again.")
        }
        # uv changes only packages that do not satisfy a requirement, so a venv install found in place keeps what fits.
        Write-Host "Installing ComfyUI's requirements into $venv with uv..."
        $null = Invoke-Native -FilePath 'uv' -ArgumentList 'pip', 'install', '--python', $python, '--torch-backend', $comfy.TorchBackend,
            '--exclude-newer', $comfy.ExcludeNewer, '-c', $constraints, '-r', $requirements -Console
        # -I keeps the current folder and PYTHON* variables out of the check.
        $code = "import json, platform, torch, torchvision; ok = torch.cuda.is_available(); print(json.dumps({'python': " +
            "platform.python_version(), 'torch': torch.__version__, 'torchvision': torchvision.__version__, 'cuda': torch.version.cuda, " +
            "'available': ok, 'device': torch.cuda.get_device_name(0) if ok else None}))"
        $said = New-Object System.Collections.Generic.List[string]
        try {
            $null = Invoke-Native -FilePath $python -ArgumentList '-I', '-c', $code -Capture $said
        } catch {
            throw "The torch check in $venv failed: $($_.Exception.Message) Python said: $(@($said | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' ')"
        }
        $printed = @($said | Where-Object { $_ -match '^\s*\{.*\}\s*\z' })
        if ($printed.Count -eq 0) { throw "The torch check in $venv printed no result: $($said -join ' ')" }
        $build = ConvertTo-LocalAIHashtable -InputObject (ConvertFrom-Json -InputObject $printed[-1])
        $pins = @{}
        foreach ($line in [IO.File]::ReadAllLines($constraints)) {
            if ($line -match '^\s*(torch|torchvision)\s*==\s*([^\s;#]+)') { $pins[$Matches[1].ToLowerInvariant()] = $Matches[2] }
        }
        $replace = ("uv pip install --python `"$python`" --torch-backend $($comfy.TorchBackend) -c `"$constraints`" " +
            '--reinstall-package torch --reinstall-package torchvision torch torchvision')
        # A CPU build, or one for another CUDA, satisfies the constraints, so uv does not replace it by itself.
        if (-not $build.cuda) {
            throw "$venv has the CPU torch $($build.torch), which cannot use the GPU. Replace it with: $replace. Then run install again."
        }
        foreach ($name in 'torch', 'torchvision') {
            if ($pins[$name] -and ([string]$build[$name] -split '\+')[0] -ne $pins[$name]) {
                throw "$venv has $name $($build[$name]), but $constraints pins $($pins[$name]). Replace it with: $replace. Then run install again."
            }
        }
        # A backend such as cu130 names the local version tag of its builds; 'auto' names none.
        if ($comfy.TorchBackend -match '^cu\d+\z') {
            foreach ($name in 'torch', 'torchvision') {
                if ([string]$build[$name] -notlike "*+$($comfy.TorchBackend)") {
                    throw ("$venv has $name $($build[$name]), not the +$($comfy.TorchBackend) build ComfyUI.TorchBackend names. Replace it " +
                        "with: $replace. Then run install again.")
                }
            }
        }
        if (-not $build.available) {
            throw "torch $($build.torch) in $venv finds no CUDA device. Check the NVIDIA driver with nvidia-smi, then run install again."
        }
        Write-Host "ComfyUI's venv has torch $($build.torch) with CUDA $($build.cuda) on $($build.device)."
        Write-LocalAIState -Path $markerPath -State @{
            Commit             = $commit
            Python             = [string]$build.python
            Torch              = [string]$build.torch
            TorchVision        = [string]$build.torchvision
            Cuda               = [string]$build.cuda
            RequirementsSha256 = $wantedMarker.RequirementsSha256
            ConstraintsSha256  = $wantedMarker.ConstraintsSha256
            Backend            = $wantedMarker.Backend
            ExcludeNewer       = $wantedMarker.ExcludeNewer
            CreatedVenv        = $marker['CreatedVenv'] -eq $true
        }
    }
    $version = if ($build.python) { [string]$build.python } else { $minor }
    return @{
        Dir = $dir; Commit = $commit; Pinned = $pinned; Cloned = $cloned; Python = $python; PythonVersion = $version
        Torch = [string]$build.torch; TorchVision = [string]$build.torchvision; Cuda = [string]$build.cuda
    }
}

# Make ComfyUI's .venv anew for update when it runs on the Microsoft Store Python: move it aside to ComfyUI.Dir.local-ai-old-venv, have Install-ComfyUI create
# a new one on a uv-managed Python and install the pinned requirements into it, then delete the old one, only warning when that fails. When the new venv fails,
# delete it and move the old one back, then throw saying so. A venv on another Python goes to Install-ComfyUI as it is. Returns what Install-ComfyUI returns,
# with Rebuilt $true when the venv was made anew.
function Reset-ComfyUIVenv {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which asks before it changes anything.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Settings.ComfyUI.Dir)
    if ($dir.Length -gt 3) { $dir = $dir.TrimEnd('\') }
    $venv = Join-Path $dir '.venv'
    # Read again, as the plan was made before the stack stopped.
    $base = Get-VenvBasePython -Venv $venv
    if (-not ($base -and $base.Store)) { return Install-ComfyUI -Settings $Settings -RepoRoot $RepoRoot }
    $aside = $dir + '.local-ai-old-venv'
    if (Test-Path -LiteralPath $aside) {
        throw ("$aside holds the venv that an earlier update moved aside, so $venv was not replaced. Delete $aside, or move it back to $venv when that is " +
            'missing, then run update again.')
    }
    # Windows refuses to rename a folder while a program has a file in it open, as a running Python has the files it loaded.
    $busy = @(Get-BusyProcess -Folder $venv)
    if ($busy.Count -gt 0) {
        throw ("ComfyUI or the image gate runs from $venv (PID $(@($busy | ForEach-Object { $_.Id }) -join ', ')), so it cannot be moved aside. Run " +
            "'local-ai stop', or close the ComfyUI another program started, then run update again.")
    }
    Write-Host "Moving ComfyUI's venv on the Microsoft Store Python $($base.Version) aside to $aside..."
    try {
        [IO.Directory]::Move($venv, $aside)
    } catch {
        $reason = $_.Exception
        while ($reason.InnerException) { $reason = $reason.InnerException }
        throw ("Cannot move $venv aside: Windows refuses to rename it, as when a program still has a file in it open ($($reason.Message)). Close that " +
            'program, such as a Python that still runs from it, then run update again.')
    }
    try {
        $result = Install-ComfyUI -Settings $Settings -RepoRoot $RepoRoot
    } catch {
        $reason = $_.Exception.Message
        # Remove-LocalAIFolder renames the new venv before it deletes it, so the old one can move back also when that delete stops part-way.
        $removal = ''
        try { Remove-LocalAIFolder -Path $venv } catch { $removal = " $($_.Exception.Message)" }
        try {
            [IO.Directory]::Move($aside, $venv)
            $back = "ComfyUI's venv is back on the Microsoft Store Python, as it was.$removal"
        } catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            $back = ("The old venv could not be moved back ($($inner.Message)), so it stays in $aside.$removal Delete $venv if it is still there, move " +
                "$aside to $venv, then run update again.")
        }
        throw "The new venv on a uv-managed Python failed: $reason $back"
    }
    try {
        Remove-LocalAITree -Path $aside
        Write-Host "Deleted the old venv $aside."
    } catch {
        Write-Warning "Could not delete the old venv ${aside}: $($_.Exception.Message) Delete it to free its space."
    }
    $result['Rebuilt'] = $true
    return $result
}

# Put Images.File into ComfyUI.Dir\models\checkpoints and return @{ Path; Sha256 }. A present file must have Images.Size bytes and
# Images.Sha256 (hashed once, cached in $Verified, which this changes); an absent one is downloaded with the pinned hf CLI to a folder
# beside it, checked and moved in. The caller keeps the PC awake. Throws naming the file on a mismatch; never deletes a present file.
function Install-ImageModel {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Verified
    )
    $images = $Settings.Images
    $size = [long]$images.Size
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Settings.ComfyUI.Dir)
    $folder = Join-Path $dir 'models\checkpoints'
    $target = Join-Path $folder $images.File
    # Beside models\checkpoints, whose subfolders ComfyUI lists too, and on its drive, so the move only renames.
    $staging = Join-Path $dir 'models\.local-ai-download'
    $present = Test-Path -LiteralPath $target -PathType Leaf
    if ($present) {
        $path = $target
        $fix = "Delete $target, then run 'local-ai install' again to download the pinned file."
    } else {
        # A run that was killed leaves its partial download here, which hf cannot resume and which the space check would count.
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $staging) { Write-Warning "Could not remove $staging, which an earlier download left; delete it to free its space." }
        }
        Test-FreeSpace -Path $folder -RequiredBytes $size
        $path = Join-Path $staging $images.File
        $fix = 'The download does not match the pin; check Images.Repo, Images.File and Images.Revision.'
    }
    try {
        if (-not $present) {
            Write-Host ("Downloading {0} ({1:0.0} GB) from {2} at {3}..." -f $images.File, ($size / 1GB), $images.Repo, $images.Revision)
            # hf takes a token from HF_TOKEN or its token file, never from this command line.
            $null = Invoke-Native -FilePath 'uvx' -ArgumentList '--from', "huggingface_hub==$($Settings.HfCli.Version)", 'hf', 'download',
                $images.Repo, $images.File, '--revision', $images.Revision, '--local-dir', $staging -Console
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "'hf download' finished, but $path does not exist." }
        }
        $length = (Get-Item -LiteralPath $path -ErrorAction Stop).Length
        if ($length -ne $size) { throw "$path has $length bytes, but Images.Size pins $size, so it is another or an incomplete file. $fix" }
        if ($images.Sha256) {
            Confirm-FileHash -Path $path -Digest $images.Sha256 -Verified $Verified -Fix $fix
        } else {
            Write-Warning "Images.Sha256 is empty, so the content of $path is not checked."
        }
        if (-not $present) {
            $null = [IO.Directory]::CreateDirectory($folder)
            Move-Item -LiteralPath $path -Destination $target -ErrorAction Stop
        }
    } finally {
        if (-not $present) {
            # hf 2.2.0 starts a download from zero in every run, so a partial one is of no use.
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $staging) { Write-Warning "Could not remove $staging; delete it to free its space." }
        }
    }
    if ($present) { Write-Host "$($images.File) is in place; nothing to download." } else { Write-Host "Downloaded $target." }
    return @{ Path = $target; Sha256 = $images.Sha256 }
}

# Return @{ Workflow; Nodes }: Images.Workflow (ComfyUI API format) and Images.WorkflowNodes (Open WebUI's mapping) as compact JSON,
# with Images.File, Steps and Resolution written to the mapped inputs; config\ paths resolve against $RepoRoot. Throws naming the
# file for bad JSON, a bad shape, or a node or input name it lacks, compared with case as ComfyUI and Open WebUI compare them.
function Get-ImageWorkflow {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $images = $Settings.Images
    $files = @{}
    $loaded = @{}
    foreach ($key in 'Workflow', 'WorkflowNodes') {
        $path = Resolve-RepoPath -Path $images[$key] -RepoRoot $RepoRoot
        $files[$key] = $path
        try {
            $text = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding $false, $true))
            $loaded[$key] = ConvertTo-LocalAIHashtable -InputObject (ConvertFrom-Json -InputObject $text)
        } catch {
            $reason = $_.Exception
            while ($reason.InnerException) { $reason = $reason.InnerException }
            throw "Cannot read Images.$key '$path': $($reason.Message)"
        }
    }
    $workflow = $loaded.Workflow
    $where = "Images.Workflow '$($files.Workflow)'"
    if ($workflow -isnot [hashtable] -or $workflow.Count -eq 0) {
        throw "$where must hold a JSON object of nodes keyed by id, in ComfyUI's API format."
    }
    # These tables ignore case in their keys; Python's dictionaries do not.
    foreach ($id in $workflow.Keys) {
        $node = $workflow[$id]
        if (-not ($node -is [hashtable] -and @($node.Keys) -ccontains 'class_type' -and @($node.Keys) -ccontains 'inputs' -and
                $node.class_type -is [string] -and $node.class_type -and $node.inputs -is [hashtable])) {
            throw "Node '$id' in $where needs a class_type and an inputs object, spelled in lowercase."
        }
    }
    $nodes = $loaded.WorkflowNodes
    $where = "Images.WorkflowNodes '$($files.WorkflowNodes)'"
    if ($nodes -isnot [array]) { throw "$where must hold a JSON list of {type, key, node_ids} objects." }
    foreach ($entry in $nodes) {
        # Open WebUI's key defaults to 'text' and its model list reads every entry's type.
        if (-not ($entry -is [hashtable] -and @($entry.Keys) -ccontains 'type' -and @($entry.Keys) -ccontains 'key' -and
                @($entry.Keys) -ccontains 'node_ids' -and $entry.key -is [string] -and $entry.key -and
                $entry.node_ids -is [array] -and $entry.node_ids.Count -gt 0)) {
            throw "Every entry in $where needs a type, a key naming an input, and a list of node_ids, spelled in lowercase."
        }
        foreach ($id in $entry.node_ids) {
            if ($id -isnot [string]) { throw "$where lists node id $id as a number; Open WebUI accepts only text, such as `"$id`"." }
            if (@($workflow.Keys) -cnotcontains $id) { throw "$where maps node '$id', which the workflow lacks." }
            if (@($workflow[$id].inputs.Keys) -cnotcontains $entry.key) {
                throw "$where maps input '$($entry.key)' of node '$id' ($($workflow[$id].class_type)), which that node lacks."
            }
        }
    }
    if ($images.Resolution -notmatch '^(\d+)x(\d+)\z') { throw "Images.Resolution '$($images.Resolution)' must be <width>x<height>." }
    $values = @{ model = $images.File; steps = $images.Steps; width = [int]$Matches[1]; height = [int]$Matches[2] }
    foreach ($entry in $nodes) {
        if ($entry.type -and $values.ContainsKey([string]$entry.type)) {
            foreach ($id in $entry.node_ids) { $workflow[$id].inputs[$entry.key] = $values[[string]$entry.type] }
        }
    }
    # Plain values keep one- and two-element lists, such as node links, as JSON arrays.
    $json = @{
        Workflow      = ConvertTo-Json -InputObject (ConvertTo-LocalAIStateValue -Value $workflow) -Depth 20 -Compress
        WorkflowNodes = ConvertTo-Json -InputObject (ConvertTo-LocalAIStateValue -Value $nodes) -Depth 20 -Compress
    }
    # Windows refuses an environment variable of 32767 characters or more.
    foreach ($key in $json.Keys) {
        if ($json[$key].Length -ge 32767) {
            throw "Images.$key '$($files[$key])' is $($json[$key].Length) characters as compact JSON; an environment variable takes at most 32766."
        }
    }
    return @{ Workflow = $json.Workflow; Nodes = $json.WorkflowNodes }
}

# Return the folder $Path as a full path, with '.' and '..' resolved, without a trailing '\' unless it is a drive root.
# A relative path resolves against this process's current folder. Touches no files.
function Resolve-FolderPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

# Return mcpo's API key from the file $Path: 64 lowercase hexadecimal characters. With -Create a missing file is made first from
# 32 random bytes (RNGCryptoServiceProvider), written to a .tmp that only the current user may open and then moved into place, so
# no other account can read it at any point. Throws naming the file when it is missing or holds anything else; never prints the key.
function Get-FilesKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Create
    )
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($Create -and -not [IO.File]::Exists($fullPath)) {
        $bytes = New-Object byte[] 32
        $random = New-Object Security.Cryptography.RNGCryptoServiceProvider
        try { $random.GetBytes($bytes) } finally { $random.Dispose() }
        # Hex never holds the '"' or '%' that the cmd.exe line of mcpo's start refuses.
        $text = -join @(foreach ($byte in $bytes) { $byte.ToString('x2') })
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = New-Object Security.AccessControl.FileSecurity
        # Protected and without inherited entries, so the folder's permissions do not reach the file.
        $security.SetAccessRuleProtection($true, $false)
        $security.SetOwner($user)
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList $user,
                ([Security.AccessControl.FileSystemRights]::FullControl), ([Security.AccessControl.AccessControlType]::Allow)))
        $temp = "$fullPath.tmp"
        try {
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
            $stream = New-Object IO.FileStream -ArgumentList $temp, ([IO.FileMode]::CreateNew), ([Security.AccessControl.FileSystemRights]::Write),
                ([IO.FileShare]::None), 4096, ([IO.FileOptions]::None), $security
            try {
                $data = [Text.Encoding]::ASCII.GetBytes($text)
                $stream.Write($data, 0, $data.Length)
                $stream.Flush($true)
            } finally {
                $stream.Dispose()
            }
            # A move on one volume keeps the file's permissions.
            [IO.File]::Move($temp, $fullPath)
        } catch {
            $reason = $_.Exception
            while ($reason.InnerException) { $reason = $reason.InnerException }
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            throw "Cannot create the mcpo key file '$fullPath': $($reason.Message)"
        }
    }
    if (-not [IO.File]::Exists($fullPath)) { throw "The mcpo key file '$fullPath' does not exist. Run 'local-ai install', which creates it." }
    $key = [IO.File]::ReadAllText($fullPath).Trim()
    if ($key -cnotmatch '^[0-9a-f]{64}\z') {
        throw ("The mcpo key file '$fullPath' does not hold 64 lowercase hexadecimal characters. Delete it, then run 'local-ai install', " +
            'which creates a new one.')
    }
    return $key
}

# Return the names of the mcpo pins, Files.McpoVersion, Files.McpoWith (in order), Files.McpoExcludeNewer and Files.Python, whose value in
# $Settings differs from the Files entry $Recorded that install-stamp.json holds; all four when there is no entry. Pure.
function Get-McpoPinDrift {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [hashtable]$Recorded
    )
    $files = $Settings.Files
    $none = $Recorded -isnot [hashtable]
    if ($none -or $Recorded.McpoVersion -ne $files.McpoVersion) { 'Files.McpoVersion' }
    if ($none -or (@($Recorded.With) -join ' ') -cne (@($files.McpoWith) -join ' ')) { 'Files.McpoWith' }
    if ($none -or [string]$Recorded.ExcludeNewer -cne [string]$files.McpoExcludeNewer) { 'Files.McpoExcludeNewer' }
    if ($none -or $Recorded.Python -ne $files.Python) { 'Files.Python' }
}

# Return @{ Setting; Pinned; Installed } for each pin Get-McpoPinDrift names, with lists joined by spaces; Installed comes from the Files
# entry $Recorded, which names McpoWith With and McpoExcludeNewer ExcludeNewer. Pure.
function Get-McpoPinChange {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [hashtable]$Recorded
    )
    $recordedAs = @{ McpoVersion = 'McpoVersion'; McpoWith = 'With'; McpoExcludeNewer = 'ExcludeNewer'; Python = 'Python' }
    foreach ($setting in @(Get-McpoPinDrift -Settings $Settings -Recorded $Recorded)) {
        $key = $setting.Substring('Files.'.Length)
        $installed = if ($Recorded -is [hashtable]) { @($Recorded[$recordedAs[$key]]) -join ' ' } else { '' }
        @{ Setting = $setting; Pinned = (@($Settings.Files[$key]) -join ' '); Installed = $installed }
    }
}

# Make the uv tool mcpo match Files.McpoVersion, McpoWith, McpoExcludeNewer and Python: install it on a uv-managed Python after an InstallBytes
# free-space check when uv lists none, else reinstall it when it or $Recorded (the Files entry install-stamp.json held) differs, since uv keeps an
# installed tool's packages otherwise. Returns @{ Version; Path; Python; ToolDir (uv's tool folder) }; throws when uv fails or mcpo runs.
function Install-Mcpo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [hashtable]$Recorded
    )
    $files = $Settings.Files
    $version = $files.McpoVersion
    # uv's receipt does not record --managed-python, and without it uv may take a Python whose patch version changes under it.
    $install = @{ Name = 'mcpo'; Package = "mcpo==$version"; Python = $files.Python; With = @($files.McpoWith); ExcludeNewer = $files.McpoExcludeNewer; ManagedPython = $true }
    $tool = Get-UvTool -Name 'mcpo'
    # Also the folder start keeps out of Files.Root, as it holds the mcpo and Open WebUI environments.
    $toolDir = Get-UvToolDir
    $reason = $null
    if ($tool) {
        if ($tool.Version -ne $version) {
            $reason = "uv lists mcpo $($tool.Version)"
        } elseif ([string]$tool.Python -notlike "$($files.Python).*") {
            $reason = "it runs on Python $($tool.Python)"
        } elseif (@(Get-McpoPinDrift -Settings $Settings -Recorded $Recorded).Count -gt 0) {
            $reason = 'install-stamp.json records no install with these pins'
        }
    }
    if ($tool -and -not $reason) {
        Write-Host "mcpo $version is installed."
    } else {
        # Windows locks the files a running Python has loaded; a reinstall that cannot remove them leaves the tool without its packages.
        $folder = Join-Path $toolDir 'mcpo'
        $busy = @(Get-BusyProcess -Folder $folder -File @($tool.Path))
        if ($busy.Count -gt 0) {
            throw ("mcpo runs from $folder (PID $(@($busy | ForEach-Object { $_.Id }) -join ', ')), so uv cannot replace its files. Run " +
                "'local-ai stop', then run install again.")
        }
        if ($tool) {
            Write-Host "Reinstalling mcpo $version with uv ($reason)..."
            $tool = Install-UvTool @install -Reinstall
        } else {
            Test-FreeSpace -Path $toolDir -RequiredBytes $files.InstallBytes
            Write-Host "Installing mcpo $version on a uv-managed Python $($files.Python) with uv..."
            $tool = Install-UvTool @install
        }
    }
    if (-not $tool.Path) { throw "'uv tool list' shows no mcpo entry point for the mcpo tool. Reinstall it with uv." }
    return @{ Version = $tool.Version; Path = $tool.Path; Python = $tool.Python; ToolDir = $toolDir }
}

# Install the files server into Paths.FilesServer from package.json and package-lock.json in Files.ServerPackage with 'npm ci --omit=dev
# --ignore-scripts', run by $NodePath on the npm-cli.js beside it, unless local-ai-install.json there records both files and the server is
# Files.ServerVersion. node must meet the server's engines field. Returns @{ Script; LockSha256; Node }; throws naming what does not match.
function Install-FilesServerPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$NodePath
    )
    $files = $Settings.Files
    $version = $files.ServerVersion
    $name = '@modelcontextprotocol/server-filesystem'
    $source = Resolve-RepoPath -Path $files.ServerPackage -RepoRoot $RepoRoot
    $tracked = [ordered]@{}
    foreach ($file in 'package.json', 'package-lock.json') {
        $path = Join-Path $source $file
        try {
            $text = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding $false, $true))
            $tracked[$file] = @{
                Path   = $path
                Data   = ConvertFrom-LocalAIJson -Text $text
                Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            }
        } catch {
            $reason = $_.Exception
            while ($reason.InnerException) { $reason = $reason.InnerException }
            throw "Cannot read '$path': $($reason.Message)"
        }
    }
    $manifest = $tracked['package.json']
    $pinned = $null
    if ($manifest.Data -is [hashtable] -and $manifest.Data['dependencies'] -is [hashtable]) { $pinned = $manifest.Data['dependencies'][$name] }
    if ($pinned -cne $version) {
        throw "$($manifest.Path) pins $name '$pinned', but Files.ServerVersion is '$version'. Make them agree, then run install again."
    }
    $lock = $tracked['package-lock.json']
    $entry = $null
    if ($lock.Data -is [hashtable] -and $lock.Data['packages'] -is [hashtable]) { $entry = $lock.Data['packages']["node_modules/$name"] }
    if ($entry -isnot [hashtable] -or $entry['version'] -cne $version) {
        throw "$($lock.Path) does not lock $name $version. Regenerate it in $source with 'npm install --package-lock-only --ignore-scripts'."
    }
    # npm only warns when node is older than a package's engines field.
    $engines = if ($entry['engines'] -is [hashtable]) { [string]$entry['engines']['node'] } else { '' }
    $needed = $null
    if ($engines) {
        if ($engines -notmatch '^\s*>=\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?\s*\z') {
            throw "$($lock.Path) asks for node '$engines' for $name, which install cannot compare; it reads only '>=<version>'."
        }
        $needed = New-Object Version -ArgumentList ([int]$Matches[1]), ([int]('0' + $Matches[2])), ([int]('0' + $Matches[3]))
    }
    $said = New-Object System.Collections.Generic.List[string]
    $null = Invoke-Native -FilePath $NodePath -ArgumentList '--version' -Capture $said
    $printed = @($said | Where-Object { $_ -match '^\s*v\d+\.\d+\.\d+' })
    if ($printed.Count -eq 0) { throw "'$NodePath --version' printed no version: $($said -join ' ')" }
    $null = $printed[-1] -match '^\s*v(\d+)\.(\d+)\.(\d+)'
    $node = New-Object Version -ArgumentList ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3])
    if ($needed -and $node -lt $needed) {
        throw ("Node.js $node at $NodePath is older than the $engines that $name $version needs. Update Node.js, for example with " +
            "'winget upgrade --id $($Settings.Winget.Packages.Node.Id) -e', then run install again.")
    }

    $target = $Paths.FilesServer
    $module = Join-Path $target 'node_modules\@modelcontextprotocol\server-filesystem'
    $script = Join-Path $module 'dist\index.js'
    $marker = Join-Path $target 'local-ai-install.json'
    # The version the installed package.json names, or '' when there is none.
    $readInstalled = {
        try { [string](ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $module 'package.json')))).version } catch { '' }
    }
    $wanted = @{ PackageSha256 = $manifest.Sha256; LockSha256 = $lock.Sha256; ServerVersion = $version }
    $recorded = @{}
    try {
        $recorded = Read-LocalAIState -Path $marker
    } catch {
        Write-Host "Ignoring the install marker: $($_.Exception.Message)"
    }
    $stale = @(foreach ($key in $wanted.Keys) { if ($recorded[$key] -ne $wanted[$key]) { $key } })
    if ($stale.Count -eq 0 -and (& $readInstalled) -eq $version -and (Test-Path -LiteralPath $script -PathType Leaf)) {
        Write-Host "The files server $version in $target matches the lockfile; nothing to install."
    } else {
        # node.exe runs npm itself: the npm.cmd shim would pass every argument through cmd.exe, and npm.ps1 is no program Invoke-Native runs.
        $npm = Join-Path (Split-Path $NodePath -Parent) 'node_modules\npm\bin\npm-cli.js'
        if (-not (Test-Path -LiteralPath $npm -PathType Leaf)) { throw "There is no npm beside $NodePath ($npm is missing). Reinstall Node.js, then run install again." }
        Test-FreeSpace -Path $target -RequiredBytes $files.ServerInstallBytes
        $null = [IO.Directory]::CreateDirectory($target)
        # A run that fails part-way leaves no marker, so the next one installs again.
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        foreach ($file in $tracked.Values) { Copy-Item -LiteralPath $file.Path -Destination $target -Force -ErrorAction Stop }
        Write-Host "Installing the files server $version into $target with npm ci..."
        # --ignore-scripts: the package ships its built dist folder, so no install script needs to run. --no-update-notifier: npm
        # would otherwise ask the registry for a newer npm and print advice to install it globally.
        $null = Invoke-Native -FilePath $NodePath -ArgumentList $npm, 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund', '--no-update-notifier',
            '--prefix', $target -Console
        $installed = & $readInstalled
        if ($installed -ne $version -or -not (Test-Path -LiteralPath $script -PathType Leaf)) {
            throw "After npm ci, $module holds $name '$installed' instead of $version, or has no dist\index.js."
        }
        Write-LocalAIState -Path $marker -State $wanted
    }
    return @{ Script = $script; LockSha256 = $lock.Sha256; Node = [string]$node }
}

# Set up the read-only file tools: Node.js through Install-WingetPackage when node is missing, noting in $Stamp.Node, saved to Paths.InstallStamp
# at once, whether a launcher install ever put it in; mcpo with Install-Mcpo (judged against $Recorded, the Files entry the stamp held), the files
# server with Install-FilesServerPackage and files.key with Get-FilesKey -Create. Returns the Files entry for the stamp; throws naming the failed step.
function Install-FilesServer {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [hashtable]$Recorded
    )
    $files = $Settings.Files
    $nodeInstall = Install-WingetPackage -Package $Settings.Winget.Packages.Node -LogDir $Paths.Logs
    # Kept across installs and saved before the steps that can fail, so uninstall can tell a Node.js the launcher put in from one that was there before.
    $byLauncher = $nodeInstall -ne 'present' -or ($Stamp['Node'] -is [hashtable] -and $Stamp['Node'].InstalledByLauncher -eq $true)
    $Stamp['Node'] = @{ InstalledByLauncher = [bool]$byLauncher }
    Write-LocalAIState -Path $Paths.InstallStamp -State $Stamp
    $node = @(Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue)
    if ($node.Count -eq 0) { throw 'node is not on PATH after the Node.js install. Open a new window, then run install again.' }
    $nodePath = [string]$node[0].Path
    $mcpo = Install-Mcpo -Settings $Settings -Recorded $Recorded
    $server = Install-FilesServerPackage -Settings $Settings -Paths $Paths -RepoRoot $RepoRoot -NodePath $nodePath
    $null = Get-FilesKey -Path $Paths.FilesKey -Create
    $mcp = @($files.McpoWith | Where-Object { $_ -match '^mcp\s*[<>=!~]' })
    return @{
        McpoVersion   = $mcpo.Version
        McpoPath      = $mcpo.Path
        McpoPython    = $mcpo.Python
        ToolDir       = $mcpo.ToolDir
        Python        = $files.Python
        With          = @($files.McpoWith)
        Mcp           = $(if ($mcp.Count -gt 0) { $mcp[0] } else { '' })
        ExcludeNewer  = $files.McpoExcludeNewer
        ServerVersion = $files.ServerVersion
        Script        = $server.Script
        LockSha256    = $server.LockSha256
        Node          = @{ Path = $nodePath; Version = $server.Node }
        # The folder uninstall -RemoveData keeps out of what it deletes when settings.psd1 does not load.
        Root          = [string]$files.Root
    }
}

# Return @{ Path; Link } for the full folder path $Path: Path with every existing folder on it spelled as on disk, so an 8.3 short name
# such as PROGRA~1 becomes its long name, and Link the first of those folders that is a junction or symbolic link, else $null. The part
# below a folder that does not exist or cannot be listed stays as given. Reads only.
function Resolve-OnDiskPath {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $parts = (Resolve-FolderPath -Path $Path).TrimEnd('\').Split('\')
    $current = $parts[0] + '\'
    $link = $null
    $known = $true
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $name = $parts[$i]
        if ($known) {
            # Windows matches a short name as well as the long one, and lists the entry under its long name.
            $found = @()
            try { $found = @((New-Object IO.DirectoryInfo -ArgumentList $current).GetDirectories($name)) } catch { $found = @() }
            $exact = @($found | Where-Object { $_.Name -eq $name })
            $entry = if ($exact.Count -gt 0) { $exact[0] } elseif ($found.Count -eq 1) { $found[0] } else { $null }
            if ($entry) {
                $name = $entry.Name
                if (-not $link -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $link = $current.TrimEnd('\') + '\' + $name }
            } else {
                $known = $false
            }
        }
        # Join-Path would refuse a drive this PC does not have.
        $current = $current.TrimEnd('\') + '\' + $name
    }
    return @{ Path = $current; Link = $link }
}

# Return, for each file in $Path (full paths, also in the \\?\ form), how many of its names (hard links) are not in $Path: 0 when every name is
# listed, -1 when it cannot be opened. Opens each file without access rights and without following a link, so a file another program holds open
# is counted too. Compiles the kernel32 binding once per session.
function Get-OutsideLinkCount {
    [CmdletBinding()]
    [OutputType([int[]], [object[]])]
    param(
        [AllowEmptyCollection()][string[]]$Path = @()
    )
    if (-not ('LocalAI.FileLinks' -as [type])) {
        Add-Type -Namespace LocalAI -Name FileLinks -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
private static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
[StructLayout(LayoutKind.Sequential)]
private struct FileInformation {
    public uint Attributes; public uint CreatedLow; public uint CreatedHigh; public uint AccessedLow; public uint AccessedHigh; public uint WrittenLow;
    public uint WrittenHigh; public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IndexHigh; public uint IndexLow;
}
[DllImport("kernel32.dll", SetLastError = true)]
private static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle file, out FileInformation information);
public static int[] CountOutside(string[] paths) {
    int[] counts = new int[paths.Length];
    string[] ids = new string[paths.Length];
    var listed = new System.Collections.Generic.Dictionary<string, int>();
    for (int i = 0; i < paths.Length; i++) {
        counts[i] = -1;
        // Share all, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT.
        using (var file = CreateFileW(paths[i], 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            FileInformation information;
            if (file.IsInvalid || !GetFileInformationByHandle(file, out information)) { continue; }
            counts[i] = (int)information.Links;
            ids[i] = information.Volume + ":" + information.IndexHigh + ":" + information.IndexLow;
            int seen;
            listed.TryGetValue(ids[i], out seen);
            listed[ids[i]] = seen + 1;
        }
    }
    for (int i = 0; i < paths.Length; i++) { if (ids[i] != null) { counts[i] -= listed[ids[i]]; } }
    return counts;
}
'@
    }
    return , ([LocalAI.FileLinks]::CountOutside([string[]]@($Path)))
}

# Return $true when Files.Root may be served: an existing folder, as a full drive-letter path through no link, no drive root, not $UserProfile or above it,
# not in or around Paths.Root, $RepoRoot, $ToolDir, OpenWebUI.DataDir or ComfyUI.Dir (8.3 names expanded), holding within $MaxEntries entries only folders it
# can list, no name Files.DenyPatterns matches (any case) and no hard link with a name outside it; links inside are not followed. Else warns once, $false.
function Test-FilesRoot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [string]$RepoRoot,
        [string]$ToolDir,
        [string]$UserProfile = $env:USERPROFILE,
        [ValidateRange(1, 10000000)][int]$MaxEntries = 100000
    )
    $given = [string]$Settings.Files.Root
    $problem = $null
    # $Inner is $Outer or a folder below it; both are full paths without a trailing '\'.
    $within = {
        param([string]$Inner, [string]$Outer)
        $Inner.Equals($Outer, [StringComparison]::OrdinalIgnoreCase) -or $Inner.StartsWith("$Outer\", [StringComparison]::OrdinalIgnoreCase)
    }
    $choose = 'Choose a folder that holds only what the model may read.'
    if ($given -notmatch '^[A-Za-z]:\\') {
        $problem = 'it is not a full path on a drive letter.'
    } else {
        $root = Resolve-FolderPath -Path $given
        $folder = New-Object IO.DirectoryInfo -ArgumentList $root
        if ($root.Length -le 3) {
            $problem = "it is a drive root. $choose"
        } elseif (-not $folder.Exists) {
            $problem = 'it is not an existing folder.'
        } else {
            # The checks below compare paths as written, and the files server serves the folder a link or short name leads to.
            $onDisk = Resolve-OnDiskPath -Path $root
            if ($onDisk.Link -and $onDisk.Link -eq $onDisk.Path) {
                $problem = 'it is a link (a junction or symbolic link). Set it to the folder the link leads to.'
            } elseif ($onDisk.Link) {
                $problem = "the folder $($onDisk.Link) on its path is a link (a junction or symbolic link). Set it to the path the link leads to."
            } elseif ($UserProfile -and (& $within (Resolve-OnDiskPath -Path $UserProfile).Path $onDisk.Path)) {
                $problem = "it is %USERPROFILE% or a folder above it. $choose"
            } else {
                $own = [ordered]@{
                    "the launcher's folder"     = $Paths.Root
                    "the launcher's repository" = $RepoRoot
                    # The mcpo and Open WebUI environments.
                    "uv's tool folder"          = $ToolDir
                    'OpenWebUI.DataDir'         = $Settings.OpenWebUI.DataDir
                    'ComfyUI.Dir'               = $Settings.ComfyUI.Dir
                }
                foreach ($label in $own.Keys) {
                    if (-not $own[$label]) { continue }
                    $other = (Resolve-OnDiskPath -Path ([string]$own[$label])).Path
                    if ((& $within $onDisk.Path $other) -or (& $within $other $onDisk.Path)) {
                        $problem = "it is inside or holds $label, $other. $choose"
                        break
                    }
                }
            }
        }
    }

    $hits = New-Object System.Collections.Generic.List[string]
    $links = New-Object System.Collections.Generic.List[string]
    $unread = New-Object System.Collections.Generic.List[string]
    $files = New-Object System.Collections.Generic.List[string]
    $fileNames = New-Object System.Collections.Generic.List[string]
    $shared = New-Object System.Collections.Generic.List[string]
    $uncounted = New-Object System.Collections.Generic.List[string]
    if (-not $problem) {
        $patterns = @(foreach ($pattern in @($Settings.Files.DenyPatterns)) {
                New-Object Management.Automation.WildcardPattern -ArgumentList $pattern, ([Management.Automation.WildcardOptions]::IgnoreCase)
            })
        # A walk that does not enter links, so a junction loop or one that leads outside cannot make it run long or look elsewhere.
        # Get-ChildItem -Recurse -Include follows junctions in 5.1, and with -LiteralPath it ignores -Include. The \\?\ form lets 5.1
        # list folders whose entries lie beyond 260 characters, which the files server reads as well.
        $prefix = '\\?\' + $root
        $relativeOf = { param([string]$Full) if ($Full.Length -gt $prefix.Length) { $Full.Substring($prefix.Length + 1) } else { '.' } }
        $pending = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
        $pending.Push((New-Object IO.DirectoryInfo -ArgumentList $prefix))
        $seen = 0
        while ($pending.Count -gt 0 -and -not $problem) {
            $current = $pending.Pop()
            try {
                $entries = $current.GetFileSystemInfos()
            } catch {
                # The server can still read a file there by its exact name, so an unchecked folder blocks.
                $unread.Add((& $relativeOf $current.FullName))
                continue
            }
            foreach ($entry in $entries) {
                $seen++
                if ($seen -gt $MaxEntries) {
                    $problem = "it holds more than $MaxEntries files and folders, more than start checks against Files.DenyPatterns. Choose a smaller folder."
                    break
                }
                # Inline, as a script block call per entry would take most of the walk's time; every entry lies below the root.
                $relative = $entry.FullName.Substring($prefix.Length + 1)
                # A folder such as .ssh is a hit as a whole and is not entered.
                $matched = $false
                foreach ($pattern in $patterns) {
                    if ($pattern.IsMatch($entry.Name)) {
                        $matched = $true
                        break
                    }
                }
                if ($matched) {
                    $hits.Add($relative)
                } elseif ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $links.Add($relative)
                } elseif ($entry.Attributes -band [IO.FileAttributes]::Directory) {
                    $pending.Push([IO.DirectoryInfo]$entry)
                } else {
                    $files.Add($entry.FullName)
                    $fileNames.Add($relative)
                }
            }
        }
        # A hard link is the same file under a second name, which may lie anywhere on the volume, and the server reads it through the name inside.
        if (-not $problem -and $hits.Count -eq 0 -and $files.Count -gt 0) {
            $outside = Get-OutsideLinkCount -Path $files.ToArray()
            for ($i = 0; $i -lt $outside.Count; $i++) {
                if ($outside[$i] -gt 0) { $shared.Add($fileNames[$i]) } elseif ($outside[$i] -lt 0) { $uncounted.Add($fileNames[$i]) }
            }
        }
    }
    # Up to five entries of $List, sorted, then how many more there are.
    $list = {
        param($List)
        $sorted = @($List | Sort-Object)
        $more = if ($sorted.Count -gt 5) { " and $($sorted.Count - 5) more" } else { '' }
        (@($sorted | Select-Object -First 5) -join ', ') + $more
    }
    if (-not $problem -and $hits.Count -gt 0) {
        $problem = ("it holds $($hits.Count) file(s) or folder(s) whose names match Files.DenyPatterns: $(& $list $hits). Move them out of it, " +
            'or choose another folder.')
    } elseif (-not $problem -and $shared.Count -gt 0) {
        $problem = ("it holds $($shared.Count) hard link(s) to files that also have a name outside it, which the file tools would read: " +
            "$(& $list $shared). Move them out of it, or choose another folder.")
    } elseif (-not $problem -and $unread.Count -gt 0) {
        $problem = ("it holds $($unread.Count) folder(s) this account cannot list, so start cannot check them against Files.DenyPatterns: " +
            "$(& $list $unread). Choose another folder, or let this account list them.")
    } elseif (-not $problem -and $uncounted.Count -gt 0) {
        $problem = ("it holds $($uncounted.Count) file(s) this account cannot open to count their names, so start cannot tell whether they are " +
            "hard links to files outside it: $(& $list $uncounted). Choose another folder, or let this account open them.")
    }
    if ($problem) {
        Write-Warning "Files.Root '$given' is not served, so the file tools are off: $problem"
        return $false
    }
    if ($links.Count -gt 0) {
        Write-Host ("Files.Root holds $($links.Count) link(s), which the deny check does not follow; the files server refuses those that lead " +
            "outside Files.Root: $(& $list $links).")
    }
    return $true
}

# Write mcpo's config to $Path, replacing it in one step: the one stdio server 'files', which runs $NodePath on $ServerScript with Files.Root (full,
# spelled as on disk as Test-FilesRoot checked it, without a trailing '\') as its only folder and hides Files.DisabledTools. ASCII with \u escapes and
# no BOM, as mcpo 0.0.20 reads it with the ANSI code page. No env entry: mcpo hands the server its own environment, which Start-LocalAIService limits.
function New-McpoConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the start verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerScript
    )
    $server = @{
        command       = $NodePath
        # One folder: a second would widen what the tools read, and with none the server exits. The server lists a root given in another
        # spelling twice, as given and as on disk, so it gets the on-disk one. From 2.1.0 on, it also serves a path that spells it in another case.
        args          = @($ServerScript, (Resolve-OnDiskPath -Path $Settings.Files.Root).Path)
        disabledTools = @($Settings.Files.DisabledTools)
    }
    Write-LocalAIState -Path $Path -State @{ mcpServers = @{ files = $server } } -Ascii
}

# Return the files server version mcpo at the base URL serves: GET /files/openapi.json with the Bearer $Key must answer within 5 s as
# secure-filesystem-server $Version with routes for exactly $Tools, and POST /files/list_allowed_directories must list $Root alone (any case).
# Throws naming what differs, as for an mcpo whose node server did not start, which serves a spec without routes.
function Get-FilesServerVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string[]]$Tools,
        [Parameter(Mandatory)][string]$Root
    )
    $headers = @{ Authorization = "Bearer $Key" }
    # The JSON at $Uri, sent $Body when there is one. mcpo sends UTF-8 without naming a charset, which Invoke-RestMethod in Windows
    # PowerShell 5.1 would read as ISO-8859-1, garbling a folder name such as one with an umlaut.
    $fetch = {
        param([string]$Uri, [string]$Body)
        $request = @{ Uri = $Uri; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 5 }
        if ($Body) {
            $request.Method = 'Post'
            $request.Body = $Body
            $request.ContentType = 'application/json'
        }
        $response = Invoke-WebRequest @request
        ConvertFrom-LocalAIJson -Text ([Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()))
    }
    $spec = & $fetch "$Url/files/openapi.json"
    $info = if ($spec -is [hashtable] -and $spec['info'] -is [hashtable]) { $spec['info'] } else { @{} }
    if (-not ($info['title'] -is [string] -and $info['title'] -ceq 'secure-filesystem-server')) {
        throw "GET $Url/files/openapi.json did not answer as secure-filesystem-server, so it is not mcpo serving the files server."
    }
    if ([string]$info['version'] -cne $Version) {
        throw "mcpo at $Url serves secure-filesystem-server $($info['version']), not Files.ServerVersion $Version."
    }
    $routes = @(if ($spec['paths'] -is [hashtable]) { $spec['paths'].Keys }) | Sort-Object
    $wanted = @($Tools | ForEach-Object { "/$_" }) | Sort-Object
    if ((@($routes) -join ', ') -cne (@($wanted) -join ', ')) {
        throw "mcpo at $Url serves the routes '$(@($routes) -join ', ')', not '$(@($wanted) -join ', ')'; without any, its node server did not start."
    }
    # A single text result comes back as a JSON string: 'Allowed directories:' and one folder per line.
    $listed = & $fetch "$Url/files/list_allowed_directories" '{}'
    $folders = @(([string]$listed -split '\r?\n') | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # A second folder, such as the one a reused mcpo was started for, would widen what the tools read.
    if ($folders.Count -eq 0 -or @($folders | Where-Object { $_.TrimEnd('\') -ne $Root }).Count -gt 0) {
        throw "mcpo at $Url serves the folders '$($folders -join "', '")', not Files.Root $Root alone."
    }
    return [string]$info['version']
}

# Return why start cannot run the file tools, or $null when it can: install-stamp.json $Stamp records them for Files.ServerVersion with an
# mcpo.exe, node.exe and server script that exist, files.key holds a key, and Ollama at $OllamaUrl reports the 'tools' capability for Model.Alias.
# Warns, finding no problem, when the lockfile in Files.ServerPackage or an mcpo pin other than McpoVersion is not the one install used.
function Get-FilesStartProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$OllamaUrl,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $install = "Run 'local-ai install' to set them up."
    $files = $Stamp['Files']
    if ($files -isnot [hashtable]) { return "install-stamp.json does not record them. $install" }
    $node = $files['Node']
    $programs = [ordered]@{ 'mcpo.exe' = $files.McpoPath; 'node.exe' = $(if ($node -is [hashtable]) { $node.Path } else { $null }); 'files server script' = $files.Script }
    foreach ($what in $programs.Keys) {
        if (-not ($programs[$what] -and (Test-Path -LiteralPath $programs[$what] -PathType Leaf))) {
            return "install-stamp.json names no $what that exists ('$($programs[$what])'). $install"
        }
    }
    if ($files.ServerVersion -ne $Settings.Files.ServerVersion) {
        return "install set up server-filesystem $($files.ServerVersion), but Files.ServerVersion is $($Settings.Files.ServerVersion). $install"
    }
    $lock = Join-Path (Resolve-RepoPath -Path $Settings.Files.ServerPackage -RepoRoot $RepoRoot) 'package-lock.json'
    if ((Get-LocalAIFileSha256 -Path $lock) -ne $files.LockSha256) {
        Write-Warning ("$lock is not the lockfile install ran npm ci with, so the files server may lack packages it needs. Run " +
            "'local-ai install', which runs npm ci again.")
    }
    # The service's pin warns about Files.McpoVersion.
    $drift = @(Get-McpoPinDrift -Settings $Settings -Recorded $files | Where-Object { $_ -ne 'Files.McpoVersion' })
    if ($drift.Count -gt 0) {
        Write-Warning ("install set up mcpo for another $($drift -join ', ') than settings.psd1 names, so mcpo runs with packages those pins " +
            "do not choose. Run 'local-ai install', which reinstalls mcpo at its pins.")
    }
    try {
        $null = Get-FilesKey -Path $Paths.FilesKey
    } catch {
        return $_.Exception.Message
    }
    $alias = $Settings.Model.Alias
    try {
        $capabilities = @(Get-OllamaModelCapability -Url $OllamaUrl -Name $alias)
    } catch {
        return "Ollama at $OllamaUrl did not report the capabilities of ${alias}: $($_.Exception.Message)"
    }
    if ($capabilities -notcontains 'tools') {
        return "Ollama does not report the 'tools' capability for $alias, so it cannot call them. Check the RENDERER and PARSER lines in its Modelfile."
    }
    return $null
}

# Return Open WebUI's environment as an ordered table: every OpenWebUI.Env entry (sorted), then the computed keys: images only for Images.Enabled and an
# $ImageWorkflow, sent to $ImageUrl (the gate) or else ComfyUI; file tools only for Files.Root and mcpo's $FilesKey; NO_PROXY adds $NoProxy. An Env entry
# replaces DATABASE_URL, DEFAULT_MODELS, TASK_MODEL, ENABLE_SIGNUP or OLLAMA_API_CONFIGS, adds to NO_PROXY and DEFAULT_MODEL_METADATA, else warns. '' unsets.
function Get-OpenWebUIEnvironment {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$OllamaUrl,
        [hashtable]$ImageWorkflow,
        [string]$ImageUrl,
        [string]$FilesKey,
        [string]$NoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY', 'Process')
    )
    $port = $Settings.Ports.OpenWebUI
    $model = "$($Settings.Model.Alias):latest"
    $dataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Settings.OpenWebUI.DataDir)
    # The entries of the comma-separated lists $Lists, trimmed, each once whatever its case, in order, joined with ','.
    $joinHosts = {
        param([string[]]$Lists)
        $seen = @{}
        $hosts = foreach ($entry in ((@($Lists) | Where-Object { $_ }) -join ',') -split ',') {
            $trimmed = $entry.Trim()
            if ($trimmed -and -not $seen.ContainsKey($trimmed)) {
                $seen[$trimmed] = $true
                $trimmed
            }
        }
        @($hosts) -join ','
    }
    $loopback = '127.0.0.1,localhost,::1'
    # Owner names the setting that changes a key instead; $null marks a key OpenWebUI.Env may replace, or with Merge add to.
    # Empty values remove a variable inherited from Windows, which would otherwise win over the computed one.
    $computed = [ordered]@{
        DATA_DIR          = @{ Value = $dataDir; Owner = 'OpenWebUI.DataDir' }
        # Open WebUI uses DATABASE_URL instead of DATA_DIR\webui.db when it is set.
        DATABASE_URL      = @{ Value = ''; Owner = $null }
        OLLAMA_BASE_URL   = @{ Value = $OllamaUrl; Owner = 'Ollama.Url' }
        # Open WebUI uses OLLAMA_BASE_URLS instead of OLLAMA_BASE_URL when it is set.
        OLLAMA_BASE_URLS  = @{ Value = ''; Owner = 'Ollama.Url' }
        # Split on ';' without trimming; a space or a trailing ';' stops Open WebUI from starting.
        CORS_ALLOW_ORIGIN = @{ Value = "http://127.0.0.1:$port;http://localhost:$port"; Owner = 'Ports.OpenWebUI' }
        # The tagged id that Ollama's /api/tags lists.
        DEFAULT_MODELS    = @{ Value = $model; Owner = $null }
        TASK_MODEL        = @{ Value = $model; Owner = $null }
        # Open WebUI 0.12.4 still lets the first account sign up and become admin.
        ENABLE_SIGNUP     = @{ Value = 'False'; Owner = $null }
        ENABLE_OLLAMA_API = @{ Value = 'True'; Owner = 'the launcher, which needs the Ollama connection' }
        # Lists only the model the image gate unloads before images. Keyed by the index of OLLAMA_BASE_URL's one entry.
        OLLAMA_API_CONFIGS = @{ Value = (ConvertTo-Json -InputObject @{ '0' = @{ model_ids = @($model) } } -Depth 4 -Compress); Owner = $null }
        # Open WebUI's HTTP client follows proxy variables, which would carry the file tools' key and the files they read to a proxy.
        # Python reads the Windows proxy setting only while no proxy variable, NO_PROXY included, is set.
        NO_PROXY          = @{ Value = (& $joinHosts @($NoProxy, $loopback)); Owner = $null
            Merge = { param([string]$Text) & $joinHosts @($NoProxy, $Text, $loopback) } }
    }
    # Open WebUI 0.12.4 reads these at startup; with ENABLE_PERSISTENT_CONFIG False the database cannot override them.
    # Without images every one but the two switches is empty, which removes copies inherited from Windows, and the
    # image button stays hidden instead of pointing at a ComfyUI this start does not run.
    $images = $Settings.Images
    $image = [ordered]@{
        ENABLE_IMAGE_GENERATION = @{ Value = 'False'; Owner = 'Images.Enabled' }
        IMAGE_GENERATION_ENGINE = @{ Value = ''; Owner = 'Images.Enabled' }
        # Written into the mapped ckpt_name input, so it must be the file name ComfyUI lists.
        IMAGE_GENERATION_MODEL  = @{ Value = ''; Owner = 'Images.File' }
        IMAGE_SIZE              = @{ Value = ''; Owner = 'Images.Resolution' }
        # Read with int() at startup; the default of 50 steps would go to the mapped steps input.
        IMAGE_STEPS             = @{ Value = ''; Owner = 'Images.Steps' }
        # Used as given, without a trailing '/': the client appends /prompt, /history, /view and /ws to it.
        COMFYUI_BASE_URL        = @{ Value = ''; Owner = 'Ports.ImageGate or Ports.ComfyUI' }
        # Sent as a Bearer token, which a local ComfyUI ignores.
        COMFYUI_API_KEY         = @{ Value = ''; Owner = 'the launcher, since the local ComfyUI takes no key' }
        COMFYUI_WORKFLOW        = @{ Value = ''; Owner = 'Images.Workflow' }
        COMFYUI_WORKFLOW_NODES  = @{ Value = ''; Owner = 'Images.WorkflowNodes' }
        # Editing needs its own IMAGES_EDIT_COMFYUI_* workflow; while off, an attached image is ignored.
        ENABLE_IMAGE_EDIT       = @{ Value = 'False'; Owner = 'the launcher, which sets up no image-editing workflow' }
    }
    if ($images.Enabled -and $ImageWorkflow) {
        $image.ENABLE_IMAGE_GENERATION.Value = 'True'
        $image.IMAGE_GENERATION_ENGINE.Value = 'comfyui'
        $image.IMAGE_GENERATION_MODEL.Value = [string]$images.File
        $image.IMAGE_SIZE.Value = [string]$images.Resolution
        $image.IMAGE_STEPS.Value = [string]$images.Steps
        $image.COMFYUI_BASE_URL.Value = if ($ImageUrl) { $ImageUrl } else { "http://127.0.0.1:$($Settings.Ports.ComfyUI)" }
        $image.COMFYUI_WORKFLOW.Value = [string]$ImageWorkflow.Workflow
        $image.COMFYUI_WORKFLOW_NODES.Value = [string]$ImageWorkflow.Nodes
    }
    foreach ($key in $image.Keys) { $computed[$key] = $image[$key] }
    # Read once at startup, as a JSON list; Open WebUI fetches each spec again for every chat and tool list, so an mcpo that
    # comes up later is used without a restart.
    $computed['TOOL_SERVER_CONNECTIONS'] = @{ Value = '[]'; Owner = 'Files.* and Ports.Files' }
    $files = $Settings['Files']
    $withFiles = [bool]($files -is [hashtable] -and $files.Root -and $FilesKey)
    # Merged into every model, key by key where the model's own metadata has none. toolIds makes the browser preselect the file tools in a
    # new chat; without them this is '{}', Open WebUI's own default, so its built-in tools stay as Open WebUI ships them.
    $metadata = [ordered]@{}
    if ($withFiles) { $metadata['toolIds'] = @('server:files') }
    # $metadata with the JSON object $Text merged in as compact JSON: its keys win, and its toolIds keep the file tools. A $Text that is
    # not a JSON object is left out with a warning.
    $mergeMetadata = {
        param([string]$Text)
        $merged = [ordered]@{}
        foreach ($key in $metadata.Keys) { $merged[$key] = $metadata[$key] }
        $given = @{}
        if ($Text) {
            try { $given = ConvertFrom-LocalAIJson -Text $Text } catch { $given = $null }
            if ($given -isnot [hashtable]) {
                Write-Warning 'OpenWebUI.Env.DEFAULT_MODEL_METADATA is left out: it is not a JSON object.'
                $given = @{}
            }
        }
        foreach ($key in $given.Keys) {
            $value = $given[$key]
            if ($key -eq 'toolIds' -and $metadata.Contains('toolIds')) {
                $merged['toolIds'] = @(@($value) + @($metadata['toolIds']) | Select-Object -Unique)
            } else {
                $merged[$key] = $value
            }
        }
        ConvertTo-Json -InputObject $merged -Depth 20 -Compress
    }
    $computed['DEFAULT_MODEL_METADATA'] = @{ Value = (& $mergeMetadata ''); Owner = $null; Merge = $mergeMetadata }
    if ($withFiles) {
        $connection = [ordered]@{
            type            = 'openapi'
            # Open WebUI joins url and path with one '/'.
            url             = "http://127.0.0.1:$($Settings.Ports.Files)/files"
            path            = 'openapi.json'
            spec_type       = 'url'
            # Sent with the spec fetch and with every tool call; mcpo runs with --strict-auth.
            auth_type       = 'bearer'
            key             = $FilesKey
            headers         = $null
            forward_cookies = $false
            config          = [ordered]@{
                enable                   = $true
                # Matched as suffixes of mcpo's operation ids, which are tool_<name>_post.
                function_name_filter_list = @(foreach ($tool in @($files.AllowedTools)) { "tool_${tool}_post" }) -join ','
                # Empty: the admin only, which the signed-in account of this single-user setup is.
                access_grants            = @()
            }
            # The tool id becomes server:files.
            info            = [ordered]@{ id = 'files'; name = 'Workspace files'; description = 'Read-only access to one folder on this PC' }
        }
        # -InputObject keeps the one-element list a list, which piping would unroll.
        $computed['TOOL_SERVER_CONNECTIONS'].Value = ConvertTo-Json -InputObject @($connection) -Depth 6 -Compress
    }
    $userEnv = $Settings.OpenWebUI.Env
    if ($userEnv -isnot [hashtable]) { $userEnv = @{} }
    $environment = [ordered]@{}
    foreach ($key in @($userEnv.Keys | Sort-Object)) {
        $value = $userEnv[$key]
        if ($value -is [hashtable] -or $value -is [array]) {
            throw "Setting 'OpenWebUI.Env.$key' must be text, a number or `$true or `$false."
        }
        $text = if ($value -is [bool]) { if ($value) { 'True' } else { 'False' } } else { [string]$value }
        if (-not $computed.Contains($key)) {
            $environment[$key] = $text
        } elseif ($computed[$key].Owner) {
            Write-Warning "OpenWebUI.Env.$key is ignored: the launcher sets $key from $($computed[$key].Owner)."
        } elseif ($computed[$key].Merge) {
            $computed[$key].Value = & $computed[$key].Merge $text
        } else {
            $computed[$key].Value = $text
        }
    }
    foreach ($key in $computed.Keys) { $environment[$key] = $computed[$key].Value }
    return $environment
}

# Return whether no service may inherit the variable $Name from this window, whatever its InheritEnvironment names: a token or an API key by
# the end of its name, or a Python or Node.js code path. Compares without case, as Windows does. Pure.
function Test-LocalAIWithheldName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    # These would point the service's Python, or the node server mcpo starts with mcpo's environment, at other code or another
    # interpreter; NODE_OPTIONS can preload a script.
    $codePaths = @('PYTHONHOME', 'PYTHONPATH', 'PYTHONSTARTUP', 'PYTHONUSERBASE', 'NODE_OPTIONS', 'NODE_PATH')
    return $Name -like '*_TOKEN' -or $Name -like '*_API_KEY' -or $codePaths -contains $Name
}

# Return the names of the variables Open WebUI, ComfyUI or the image gate inherits from this window: what Windows and Python need to run, then
# each of $Extra, every name once whatever its case. Start-LocalAIService still withholds those Test-LocalAIWithheldName matches. Pure.
function Get-LocalAIInheritedName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][AllowNull()][string[]]$Extra = @()
    )
    # Folders, the shell, the program search path and processor facts, all set by Windows itself and none secret. Python's ntpath reads
    # USERPROFILE for ~, tempfile TEMP and TMP, subprocess ComSpec and SystemRoot, shutil PATHEXT, site APPDATA, and platform
    # PROCESSOR_ARCHITECTURE and PROCESSOR_IDENTIFIER.
    $names = @('SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'Path', 'TEMP', 'TMP', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH',
        'USERNAME', 'USERDOMAIN', 'COMPUTERNAME', 'APPDATA', 'LOCALAPPDATA', 'ProgramData', 'ALLUSERSPROFILE', 'PUBLIC', 'ProgramFiles',
        'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432', 'OS', 'NUMBER_OF_PROCESSORS',
        'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION', 'DriverData')
    # Keys compare without case.
    $seen = @{}
    foreach ($name in @($names) + @($Extra | Where-Object { $_ })) {
        if (-not $seen.ContainsKey($name)) {
            $seen[$name] = $true
            $name
        }
    }
}

# Return the service table in start order: optional ComfyUI from $ComfyUI (stamp: Commit, Python) for Images.Enabled and an $ImageWorkflow, with
# Images.UnloadChat the image gate, for Files.Root mcpo from $Files (McpoPath, McpoVersion, Key), then required Open WebUI from $OpenWebUI. Identity
# takes the entry and returns the version to show or throws; Pin and Repair name the pin and the install; InheritEnvironment names the variables
# each may inherit from this window. Warns for dropped Args or gate.
function Get-LocalAIService {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$OllamaUrl,
        [Parameter(Mandatory)][hashtable]$OpenWebUI,
        [hashtable]$ComfyUI,
        [hashtable]$ImageWorkflow,
        [hashtable]$Files
    )
    $withComfyUI = [bool]($Settings.Images.Enabled -and $ComfyUI -and $ImageWorkflow)
    $gateUrl = ''
    if ($withComfyUI) {
        $comfy = $Settings.ComfyUI
        $comfyPort = $Settings.Ports.ComfyUI
        $comfyBase = "http://127.0.0.1:$comfyPort"
        $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($comfy.Dir)
        # These would undo the loopback bind, add code that runs at start, or let any web page send ComfyUI work. ComfyUI's
        # argparse also takes a unique abbreviation, such as --liste or --enable-cors, and a longer flag that implies one.
        $reserved = [ordered]@{
            '--listen'                   = 'the launcher passes --listen 127.0.0.1'
            '--port'                     = 'the launcher passes --port from Ports.ComfyUI'
            '--enable-manager'           = 'the ComfyUI Manager installs and loads custom nodes'
            '--enable-manager-legacy-ui' = 'the ComfyUI Manager installs and loads custom nodes'
            '--enable-cors-header'       = "it turns off ComfyUI's check that requests come from its own page"
        }
        # Of these, --port takes a value and --listen and --enable-cors-header may.
        $valued = @('--listen', '--port', '--enable-cors-header')
        $ordinal = [StringComparison]::Ordinal
        $arguments = New-Object System.Collections.Generic.List[string]
        $arguments.Add('main.py')
        $given = @($comfy.Args)
        for ($i = 0; $i -lt $given.Count; $i++) {
            $argument = [string]$given[$i]
            if ($argument -eq '--') {
                Write-Warning "ComfyUI.Args '--' is ignored: it would end the options before the launcher's --listen and --port."
                continue
            }
            $flag = ($argument -split '=', 2)[0]
            $matched = @(if ($flag.StartsWith('--', $ordinal) -and $flag.Length -gt 2) {
                    foreach ($name in $reserved.Keys) { if ($name.StartsWith($flag, $ordinal) -or $flag.StartsWith($name, $ordinal)) { $name } }
                })
            if ($matched.Count -eq 0) {
                $arguments.Add($argument)
                continue
            }
            # A value given as the next argument goes too.
            $dropped = $argument
            $takesValue = @($matched | Where-Object { $valued -contains $_ }).Count -gt 0
            if ($takesValue -and $argument -notlike '*=*' -and $i + 1 -lt $given.Count -and -not ([string]$given[$i + 1]).StartsWith('-')) {
                $i++
                $dropped += " $($given[$i])"
            }
            Write-Warning "ComfyUI.Args '$dropped' is ignored: $(@($matched | ForEach-Object { $reserved[$_] } | Select-Object -Unique) -join '; ')."
        }
        # Last, because argparse keeps the last value given for a flag.
        foreach ($argument in '--listen', '127.0.0.1', '--port', [string]$comfyPort) { $arguments.Add($argument) }
        $venv = Split-Path (Split-Path $ComfyUI.Python -Parent) -Parent
        $marker = Join-Path $venv 'local-ai-install.json'
        # A reinstall in place would have uv launch the venv's base Python too, so a venv on the Microsoft Store Python is made anew instead.
        $basePython = $null
        try { $basePython = Get-VenvBasePython -Venv $venv } catch { Write-Verbose "The pyvenv.cfg of $venv cannot be read: $($_.Exception.Message)" }
        $rebuild = $null
        if ($basePython -and $basePython.Store) {
            $rebuild = ("'local-ai update', which makes ComfyUI's venv anew on a uv-managed Python. The venv runs on the Microsoft Store Python, whose " +
                'launches can fail or hang until Windows restarts')
        }
        @{
            Name             = 'ComfyUI'
            DisplayName      = 'ComfyUI'
            Port             = $comfyPort
            Url              = $comfyBase
            HealthUrl        = "$comfyBase/system_stats"
            Identity         = { param([hashtable]$Service) Get-ComfyUIVersion -Url $Service.Url }
            FilePath         = $ComfyUI.Python
            ArgumentList     = $arguments.ToArray()
            WorkingDirectory = $dir
            Environment      = [ordered]@{}
            # Also the GPU choice main.py and the CUDA driver read, with the order the driver numbers GPUs in for it, the allocator settings
            # cuda_malloc.py and torch read, the CUDA toolkit torch's runtime compiler looks in, and ComfyUI.InheritEnvironment.
            InheritEnvironment = @(Get-LocalAIInheritedName -Extra (@('CUDA_VISIBLE_DEVICES', 'CUDA_DEVICE_ORDER', 'PYTORCH_CUDA_ALLOC_CONF', 'PYTORCH_ALLOC_CONF',
                        'CUDA_PATH') + @($comfy.InheritEnvironment)))
            OutLog           = Join-Path $Paths.Logs 'comfyui.log'
            ErrLog           = Join-Path $Paths.Logs 'comfyui.err.log'
            TimeoutSeconds   = $comfy.HealthTimeoutSeconds
            # /system_stats reports only the version, so drift is judged by the commit install recorded.
            Pin              = @{ Setting = 'ComfyUI.Commit'; Version = $comfy.Commit; Stamped = $ComfyUI.Commit; Running = $false; Hint = '' }
            # Reinstalls every package at the version the venv holds, with a pipe that cmd.exe and PowerShell both run; the
            # deleted marker makes the next install check torch again.
            Repair           = $(if ($rebuild) { $rebuild } else {
                    ("uv pip freeze --python `"$($ComfyUI.Python)`" | uv pip install --python `"$($ComfyUI.Python)`" " +
                    "--torch-backend $($comfy.TorchBackend) --reinstall -r -, then delete `"$marker`" and run 'local-ai install'")
                })
            Required         = $false
        }

        # The gate's Python talks to loopback addresses only, and it can free only this PC's GPU.
        $alias = $Settings.Model.Alias
        $fallback = "Images go to ComfyUI directly, so $alias is not unloaded before images"
        $ollamaHost = ([uri]$OllamaUrl).Host.Trim('[', ']')
        $ip = $null
        $loopback = $ollamaHost -eq 'localhost' -or ([Net.IPAddress]::TryParse($ollamaHost, [ref]$ip) -and [Net.IPAddress]::IsLoopback($ip))
        if ($Settings.Images.UnloadChat -and -not $loopback) {
            Write-Warning ("${fallback}: the image gate unloads only from an Ollama on a loopback address, and Ollama.Url or OLLAMA_HOST " +
                "names $OllamaUrl. If Ollama runs on another computer, set Images.UnloadChat = `$false in settings.psd1.")
        } elseif ($Settings.Images.UnloadChat) {
            $gatePort = $Settings.Ports.ImageGate
            $gateUrl = "http://127.0.0.1:$gatePort"
            # The name /api/ps lists, as DEFAULT_MODELS has it.
            $chatModel = "${alias}:latest"
            $gateErr = Join-Path $Paths.Logs 'imagegate.err.log'
            @{
                Name             = 'ImageGate'
                DisplayName      = 'Image gate'
                Port             = $gatePort
                Url              = $gateUrl
                HealthUrl        = "$gateUrl/local-ai/image-gate"
                # A ComfyUI that answered on the gate's port would not pass, as the gate's own route is not proxied.
                Identity         = { param([hashtable]$Service) Get-ImageGateVersion -Url $Service.Url -Upstream $Service.Upstream -Ollama $Service.Ollama -Model $Service.Model }
                Upstream         = $comfyBase
                Ollama           = $OllamaUrl
                Model            = $chatModel
                # ComfyUI's venv has aiohttp. -I keeps PYTHON* variables, the script's folder and the working folder off sys.path; -B
                # writes no bytecode next to the script.
                FilePath         = $ComfyUI.Python
                ArgumentList     = @('-I', '-B', (Join-Path $PSScriptRoot 'image_gate.py'), '--port', [string]$gatePort, '--upstream', $comfyBase,
                    '--ollama', $OllamaUrl, '--model', $chatModel, '--unload-timeout', [string]$Settings.Images.UnloadTimeoutSeconds)
                # Launcher-owned and empty, so nothing in it can be imported.
                WorkingDirectory = Join-Path $Paths.Root 'image-gate'
                Environment      = [ordered]@{}
                # Its clients read no proxy variable (trust_env=False), and -I has Python ignore the PYTHON* ones.
                InheritEnvironment = @(Get-LocalAIInheritedName)
                OutLog           = Join-Path $Paths.Logs 'imagegate.log'
                ErrLog           = $gateErr
                # It answers within about a second; Open WebUI starts only after it, since it reads COMFYUI_BASE_URL once.
                TimeoutSeconds   = 15
                WaitFirst        = $true
                Fallback         = $fallback
                # It ships with the launcher, so there is no pin to drift from.
                Pin              = $null
                Repair           = $(if ($rebuild) { "$rebuild; the gate runs on that venv and logs its errors to $gateErr" } else {
                        "'local-ai install', which sets up the ComfyUI venv whose aiohttp the gate uses; the gate logs its errors to $gateErr"
                    })
                Required         = $false
            }
        }
    }

    $filesKey = ''
    if ($Settings.Files.Root -and $Files) {
        $tools = $Settings.Files
        $filesKey = $Files.Key
        $filesPort = $Settings.Ports.Files
        $filesBase = "http://127.0.0.1:$filesPort"
        $webPort = $Settings.Ports.OpenWebUI
        $filesErr = Join-Path $Paths.Logs 'files.err.log'
        $with = @(foreach ($requirement in @($tools.McpoWith)) { "--with `"$requirement`"" })
        $exclude = if ($tools.McpoExcludeNewer) { @('--exclude-newer', $tools.McpoExcludeNewer) } else { @() }
        $reinstall = @('uv tool install --python', $tools.Python, '--managed-python', "mcpo==$($tools.McpoVersion)") + $with + $exclude + @('--reinstall')
        @{
            Name             = 'Files'
            DisplayName      = 'File tools'
            Port             = $filesPort
            Url              = $filesBase
            HealthUrl        = "$filesBase/files/openapi.json"
            # A 200 alone proves little: mcpo serves a spec without routes when its node server did not start. The answer names the server,
            # as mcpo's own version, which the pin judges, is another.
            Identity         = {
                param([hashtable]$Service)
                'server-filesystem ' + (Get-FilesServerVersion -Url $Service.Url -Key $Service.Key -Version $Service.ServerVersion -Tools $Service.Tools -Root $Service.Root)
            }
            Key              = $Files.Key
            ServerVersion    = $tools.ServerVersion
            Tools            = @($tools.AllowedTools)
            # As New-McpoConfig hands it to the server.
            Root             = (Resolve-OnDiskPath -Path $tools.Root).Path
            FilePath         = $Files.McpoPath
            # Long flags only, since -h is --host and -v the served API's version. mcpo 0.0.20 reads its key from no variable or file,
            # so it goes on the command line; --strict-auth puts the specs behind it too. Open WebUI calls mcpo from its backend only,
            # so the two origins it allows serve as a limit, not as a need. At INFO mcpo would log every call with its file paths.
            ArgumentList     = @('--host', '127.0.0.1', '--port', [string]$filesPort, '--api-key', $Files.Key, '--strict-auth',
                '--cors-allow-origins', "http://127.0.0.1:$webPort", '--cors-allow-origins', "http://localhost:$webPort",
                '--config', $Paths.McpoConfig, '--log-level', 'WARNING')
            # Launcher-owned and empty; the node server inherits it, as mcpo ignores a cwd in its config.
            WorkingDirectory = Join-Path $Paths.Root 'mcpo'
            Environment      = [ordered]@{}
            # mcpo hands the node server its whole environment, which text the model reads could get it to reveal, so both get only what
            # Windows, Python and Node.js need to run, and no secret a variable of this window may hold.
            InheritEnvironment = @('SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'Path', 'TEMP', 'TMP', 'USERPROFILE', 'HOMEDRIVE',
                'HOMEPATH', 'USERNAME', 'APPDATA', 'LOCALAPPDATA', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE')
            OutLog           = Join-Path $Paths.Logs 'files.log'
            ErrLog           = $filesErr
            TimeoutSeconds   = $tools.HealthTimeoutSeconds
            # Open WebUI reads TOOL_SERVER_CONNECTIONS only when it starts.
            WaitFirst        = $true
            Fallback         = 'The file tools are off for this start'
            # mcpo serves no version of its own, so drift is judged by what install recorded.
            Pin              = @{ Setting = 'Files.McpoVersion'; Version = $tools.McpoVersion; Stamped = $Files.McpoVersion; Running = $false; Label = 'mcpo'
                Hint = ", or 'local-ai install', which reinstalls mcpo at its pins" }
            Repair           = ("$($reinstall -join ' ') for mcpo, or for the files server delete `"$(Join-Path $Paths.FilesServer 'local-ai-install.json')`" " +
                "and run 'local-ai install'; mcpo logs its own errors and the server's to $filesErr")
            Required         = $false
        }
    }

    $port = $Settings.Ports.OpenWebUI
    $base = "http://127.0.0.1:$port"
    $workflow = if ($withComfyUI) { $ImageWorkflow } else { $null }
    $environment = Get-OpenWebUIEnvironment -Settings $Settings -OllamaUrl $OllamaUrl -ImageWorkflow $workflow -ImageUrl $gateUrl -FilesKey $filesKey
    $python = if ($OpenWebUI.Python) { $OpenWebUI.Python } else { $Settings.OpenWebUI.Python }
    $version = if ($OpenWebUI.Version) { $OpenWebUI.Version } else { $Settings.OpenWebUI.Version }
    @{
        Name             = 'OpenWebUI'
        DisplayName      = 'Open WebUI'
        Port             = $port
        Url              = $base
        HealthUrl        = "$base/health"
        Identity         = { param([hashtable]$Service) Get-OpenWebUIVersion -Url $Service.Url }
        FilePath         = $OpenWebUI.Path
        # serve listens on 0.0.0.0:8080 unless told otherwise.
        ArgumentList     = @('serve', '--host', '127.0.0.1', '--port', [string]$port)
        # serve keeps .webui_secret_key in its working directory, not in DATA_DIR.
        WorkingDirectory = $environment['DATA_DIR']
        Environment      = $environment
        # Tools and functions run inside Open WebUI, so it gets no secret of this window either. Also where huggingface_hub and
        # sentence-transformers keep the embedding model, which would otherwise download again elsewhere, whether they may go
        # online, and OpenWebUI.InheritEnvironment.
        InheritEnvironment = @(Get-LocalAIInheritedName -Extra (@('HF_HOME', 'HF_HUB_CACHE', 'HUGGINGFACE_HUB_CACHE', 'XDG_CACHE_HOME',
                    'SENTENCE_TRANSFORMERS_HOME', 'HF_HUB_OFFLINE') + @($Settings.OpenWebUI.InheritEnvironment)))
        OutLog           = Join-Path $Paths.Logs 'open-webui.log'
        ErrLog           = Join-Path $Paths.Logs 'open-webui.err.log'
        TimeoutSeconds   = $Settings.OpenWebUI.HealthTimeoutSeconds
        Pin              = @{ Setting = 'OpenWebUI.Version'; Version = $Settings.OpenWebUI.Version; Stamped = $OpenWebUI.Version; Running = $true
            Hint = '; it backs up the data folder first' }
        Repair           = "uv tool install --python $python open-webui==$version --reinstall"
        Required         = $true
    }
}

# Start $Service hidden through cmd.exe, which writes OutLog and ErrLog (rotated first, keeping $Keep), with its Environment set and the inherited
# variables it does not set removed when Test-LocalAIWithheldName matches them (tokens, API keys, Python and Node.js code paths), or, when it lists
# InheritEnvironment, not named there; this process's variables are restored. Returns Pid, StartTicks (UTC), Path, Port, OutLog, ErrLog, Process; throws for '"' or '%'.
function Start-LocalAIService {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the start verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [ValidateRange(1, 20)][int]$Keep = 5
    )
    # cmd.exe expands %VAR% even inside quotes, and a '"' would end the quoting.
    foreach ($part in @($Service.FilePath, $Service.OutLog, $Service.ErrLog) + @($Service.ArgumentList)) {
        if ([string]$part -match '["%\r\n]') {
            throw "Cannot start $($Service.Name) through cmd.exe: '$part' contains a double quote, a percent sign or a line break."
        }
    }
    foreach ($log in $Service.OutLog, $Service.ErrLog) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($log))
        Invoke-LogRotation -Path $log -Keep $Keep
    }
    $null = [IO.Directory]::CreateDirectory($Service.WorkingDirectory)
    $wanted = $Service.Environment
    if ($null -eq $wanted) { $wanted = @{} }
    # Names compare without case, as Windows compares them. An empty variable holds nothing, and .NET would remove it instead of setting it back.
    $kept = $Service.InheritEnvironment
    $dropped = @([Environment]::GetEnvironmentVariables('Process').GetEnumerator() | Where-Object {
            $name = [string]$_.Key
            [string]$_.Value -and -not $wanted.Contains($name) -and ((Test-LocalAIWithheldName -Name $name) -or
                ($null -ne $kept -and @($kept) -notcontains $name))
        } | ForEach-Object { [string]$_.Key })
    $saved = @{}
    foreach ($name in @($dropped) + @($wanted.Keys)) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    # Without -Redirect*, Start-Process uses ShellExecute, which hands the child no handle of this process,
    # so a caller reading this window's output does not wait until the service stops. Every argument is
    # quoted, with trailing '\' doubled for the program's own parser; /s strips only the outer quotes.
    $quoted = @(foreach ($argument in $Service.ArgumentList) { '"' + ([string]$argument -replace '(\\+)\z', '$1$1') + '"' })
    $line = @('"' + $Service.FilePath + '"') + $quoted + @("1>`"$($Service.OutLog)`"", "2>`"$($Service.ErrLog)`"")
    $shell = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    $start = @{
        FilePath         = $shell
        # /d skips AutoRun commands, /v:off keeps '!' literal.
        ArgumentList     = '/d /v:off /s /c "' + ($line -join ' ') + '"'
        WorkingDirectory = $Service.WorkingDirectory
        WindowStyle      = 'Hidden'
        PassThru         = $true
        ErrorAction      = 'Stop'
    }
    try {
        foreach ($name in $dropped) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        # Windows removes a variable set to an empty value.
        foreach ($name in @($wanted.Keys)) { [Environment]::SetEnvironmentVariable($name, [string]$wanted[$name], 'Process') }
        $process = Start-Process @start
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    # 5.1 reports no ExitCode unless the handle was opened while the process ran.
    $null = $process.Handle
    $path = [string]$process.Path
    if (-not $path) { $path = $shell }
    return @{
        Pid        = $process.Id
        StartTicks = $process.StartTime.ToUniversalTime().Ticks
        Path       = $path
        Port       = $Service.Port
        OutLog     = $Service.OutLog
        ErrLog     = $Service.ErrLog
        Process    = $process
    }
}

# Poll $Service.Identity, called with $Service, every 500 ms until it answers while $Process (from Start-LocalAIService) runs
# and it or a descendant holds the port; returns @{ Version; Listener (from Get-PortOwner) }. Throws at once when the process
# exits, printing the last 30 lines of both logs and the repair hint, and after $TimeoutSeconds, naming any other owner.
function Wait-LocalAIService {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [Parameter(Mandatory)]$Process,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
    )
    $name = $Service.DisplayName
    $logs = "Its logs are $($Service.ErrLog) and $($Service.OutLog)."
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $reason = 'it has not answered yet'
    $foreign = ''
    while ($true) {
        $version = $null
        $listener = $null
        # Ask only once a program holds the port: Start-Transcript in Windows PowerShell 5.1 logs each
        # refused request the identity check throws, even a caught one.
        if (-not (Get-PortOwner -Port $Service.Port)) {
            $reason = "nothing listens on port $($Service.Port)"
        } else {
            try {
                $version = & $Service.Identity $Service
            } catch {
                $reason = $_.Exception.Message
            }
        }
        if ($version) {
            # Another copy, such as one another program starts, can bind the port first and answer instead.
            $owner = Get-PortOwner -Port $Service.Port
            if ($owner -and (Test-ProcessDescendant -ProcessId $owner.Id -AncestorId $Process.Id)) {
                $listener = $owner
            } elseif ($owner) {
                $reason = 'another program answered'
                $foreign = " Port $($Service.Port) is held by $($owner.Name) (PID $($owner.Id), $($owner.Path)), which this start did not launch."
            }
        }
        if ($Process.HasExited) {
            foreach ($log in $Service.ErrLog, $Service.OutLog) {
                Write-Host "--- Last 30 lines of $log ---" -ForegroundColor DarkGray
                if (Test-Path -LiteralPath $log -PathType Leaf) {
                    Get-Content -LiteralPath $log -Tail 30 | ForEach-Object { Write-Host $_ }
                }
            }
            if ($Service.Repair) { Write-Host "If the log shows a damaged install, repair it with: $($Service.Repair)" -ForegroundColor Yellow }
            throw "$name exited with code $($Process.ExitCode) before it answered at $($Service.Url).$foreign $logs"
        }
        if ($listener) { return @{ Version = [string]$version; Listener = $listener } }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "$name did not answer at $($Service.HealthUrl) within $TimeoutSeconds s ($reason).$foreign $logs"
        }
        Start-Sleep -Milliseconds 500
    }
}

# Stop service $Name from its state.json $Record with 'taskkill /PID <pid> /T /F' when Get-LiveRecord proves the PID
# (or its recorded Listener) is still that process, then wait up to $TimeoutSeconds for it to exit and free Record.Port.
# Returns 'stopped', 'stale' (nothing killed) or 'failed', also when the process runs but cannot be inspected.
function Stop-LocalAIService {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the stop and start verbs, which offer no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Record,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 10
    )
    $port = [int]$Record.Port
    $found = Get-LiveRecord -Record $Record
    $live = @($found.Match)
    if ($live.Count -eq 0 -and $found.Unreadable.Count -gt 0) {
        Write-Host ("$Name (PID $($found.Unreadable[0].Pid)) still runs, but this window may not inspect it, as when it was " +
            "started from an elevated window, so nothing was stopped. Run 'local-ai stop' from an elevated window.") -ForegroundColor Red
        return 'failed'
    }
    if ($live.Count -eq 0) {
        $now = ''
        if ($port -gt 0) {
            $owner = Get-PortOwner -Port $port
            $now = if ($owner) { " Port $port is now held by $($owner.Name) (PID $($owner.Id), $($owner.Path))." } else { " Port $port is free." }
        }
        Write-Host "$Name (PID $($Record.Pid)) is no longer running, or its PID belongs to another program now, so nothing was stopped.$now"
        return 'stale'
    }
    $target = $live[0]
    $said = New-Object System.Collections.Generic.List[string]
    try {
        # 128: the process ended before taskkill reached it.
        $null = Invoke-Native -FilePath 'taskkill' -ArgumentList '/PID', ([string]$target.Pid), '/T', '/F' -SuccessCode 0, 128 -Capture $said
    } catch {
        $text = @($said | Where-Object { $_.Trim() }) -join ' '
        Write-Host "Could not stop $Name (PID $($target.Pid)): $($_.Exception.Message) taskkill said: $text" -ForegroundColor Red
        return 'failed'
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ((Test-RecordedProcess -Record $target) -or ($port -gt 0 -and (Get-PortOwner -Port $port))) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Host "$Name (PID $($target.Pid)) still runs, or port $port is still held, $TimeoutSeconds s after taskkill." -ForegroundColor Red
            return 'failed'
        }
        Start-Sleep -Milliseconds 500
    }
    # Get-LiveRecord lists the record before its Listener, so another target is the server that the recorded process left running.
    if ([object]::ReferenceEquals($target, $Record)) {
        Write-Host "Stopped $Name (PID $($target.Pid))."
    } else {
        Write-Host "Stopped the server (PID $($target.Pid)) that $Name (PID $($Record.Pid)) left running."
    }
    return 'stopped'
}

# Return the SHA-256 (lowercase hex) of the environment table $Environment as NAME=value lines sorted by name, then, when $InheritEnvironment is
# given, one line of those names, so start can tell whether a service it reuses was started with the variables it computes now and with those it
# lets the service inherit. No table and no list hash the empty text. Pure.
function Get-LocalAIEnvironmentHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Collections.IDictionary]$Environment,
        [AllowNull()][AllowEmptyCollection()][string[]]$InheritEnvironment
    )
    $lines = @(if ($Environment) { foreach ($key in @($Environment.Keys | Sort-Object)) { "$key=$($Environment[$key])" } })
    # Upper case and sorted, as names compare without case and the order does not matter; the line has no '=', so no NAME=value line equals it.
    if ($null -ne $InheritEnvironment) {
        $lines = @($lines) + @('InheritEnvironment ' + (@($InheritEnvironment | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object -Unique) -join ' '))
    }
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return -join @(foreach ($byte in $sha.ComputeHash($bytes)) { $byte.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

# Launch $Service for the start verb without waiting: reuse it when the process $State.Services records holds its port and Identity answers for
# $Service, else start it, recording it with Get-LocalAIEnvironmentHash in $State and $Started and saving $StatePath. Returns @{ Version; Stale } when
# reused, Stale when it has an Environment or an InheritEnvironment whose hash it was not started with, else @{ Process }; throws when another program
# holds the port or a record is unreadable.
function Use-LocalAIService {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [ValidateRange(1, 20)][int]$Keep = 5,
        [System.Collections.Generic.List[string]]$Started
    )
    $name = $Service.Name
    $display = $Service.DisplayName
    $port = $Service.Port
    $record = $State.Services[$name]
    $ours = @()
    if ($record -is [hashtable]) {
        $found = Get-LiveRecord -Record $record
        $ours = @($found.Match)
        if ($ours.Count -eq 0 -and $found.Unreadable.Count -gt 0) {
            throw ("The $display an earlier start left running (PID $($found.Unreadable[0].Pid)) cannot be inspected from this " +
                "window, as when it was started from an elevated window. Run 'local-ai stop' from an elevated window, then start again.")
        }
    }
    $owner = Get-PortOwner -Port $port
    if ($owner) {
        if (@($ours | Where-Object { [int]$_.Pid -eq $owner.Id }).Count -eq 0) {
            $hint = if ($ours.Count -gt 0) { " If it is the $display an earlier start left running, run 'local-ai stop' first." } else { '' }
            throw ("Port $port, which $display needs, is held by $($owner.Name) (PID $($owner.Id), $($owner.Path)), not by a process " +
                "this launcher started. Close that program or set Ports.$name in settings.psd1.$hint")
        }
        try {
            $version = & $Service.Identity $Service
        } catch {
            throw ("Port $port is held by the $display an earlier start left running (PID $($owner.Id)), but it does not answer " +
                "as $display ($($_.Exception.Message)). Run 'local-ai stop', then start again.")
        }
        Write-Host "$display $version is already running at $($Service.Url); reusing it."
        # A service reads its environment only when it starts; a record without a hash comes from a launcher that kept none.
        $stale = $false
        if (($Service.Environment -and $Service.Environment.Count -gt 0) -or $null -ne $Service.InheritEnvironment) {
            $stale = [string]$record['EnvironmentSha256'] -ne (Get-LocalAIEnvironmentHash -Environment $Service.Environment -InheritEnvironment $Service.InheritEnvironment)
        }
        return @{ Version = [string]$version; Process = $null; Stale = $stale }
    }
    if ($ours.Count -gt 0) {
        throw "The $display an earlier start left running (PID $($ours[0].Pid)) does not listen on port $port. Run 'local-ai stop', then start again."
    }
    Write-Host "Starting $display..."
    $launched = Start-LocalAIService -Service $Service -Keep $Keep
    $record = @{}
    foreach ($key in 'Pid', 'StartTicks', 'Path', 'Port', 'OutLog', 'ErrLog') { $record[$key] = $launched[$key] }
    $record['EnvironmentSha256'] = Get-LocalAIEnvironmentHash -Environment $Service.Environment -InheritEnvironment $Service.InheritEnvironment
    # Registered before the save, so the caller can still stop it when the save fails.
    $State.Services[$name] = $record
    if ($null -ne $Started) { $Started.Add($name) }
    Write-LocalAIState -Path $StatePath -State $State
    return @{ Version = $null; Process = $launched.Process }
}

# Wait for $Service, which Use-LocalAIService started as $Process, with Wait-LocalAIService, then add the process that listens
# to its record in $State.Services and save $StatePath. Returns the version; throws as Wait-LocalAIService does.
function Complete-LocalAIService {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath
    )
    $display = $Service.DisplayName
    # Only a service given minutes to answer, such as Open WebUI or ComfyUI, gets the note.
    $note = if ($Service.TimeoutSeconds -ge 120) { '; its first start takes a few minutes' } else { '' }
    Write-Host "Waiting up to $($Service.TimeoutSeconds) s for $display at $($Service.Url)$note..."
    $ready = Wait-LocalAIService -Service $Service -Process $Process -TimeoutSeconds $Service.TimeoutSeconds
    # The listener is a descendant, behind cmd.exe, the uv trampoline and the venv launcher.
    $listener = $ready.Listener
    $record = $State.Services[$Service.Name]
    if ($record -is [hashtable] -and $listener.Id -ne $record.Pid) {
        $record['Listener'] = @{ Pid = $listener.Id; StartTicks = $listener.StartTicks; Path = $listener.Path }
        Write-LocalAIState -Path $StatePath -State $State
    }
    Write-Host "$display $($ready.Version) is up at $($Service.Url)."
    return $ready.Version
}

# Stop service $Name when this start launched it (it is in $Started), or with -AnyStart whenever $State.Services records it, dropping it from
# $State.Services and $Started unless Stop-LocalAIService failed, then save $StatePath. Returns Stop-LocalAIService's 'stopped', 'stale' or
# 'failed', or '' when the service is none of these; Stop-LocalAIService kills only a process the record proves is the launcher's.
function Stop-StartedLocalAIService {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the start verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Started,
        [switch]$AnyStart
    )
    if (-not ($Started.Contains($Name) -or ($AnyStart -and $State.Services.ContainsKey($Name)))) { return '' }
    $record = $State.Services[$Name]
    $result = if ($record -is [hashtable]) { Stop-LocalAIService -Name $Name -Record $record } else { 'stale' }
    if ($result -ne 'failed') {
        $State.Services.Remove($Name)
        $null = $Started.Remove($Name)
    }
    Write-LocalAIState -Path $StatePath -State $State
    return $result
}

# Warn that the optional $Service is not part of this start because of $Reason, leading with its Fallback, which says what happens
# instead, or else with '<name> is not available, and start goes on without it'. Returns nothing.
function Write-LocalAIServiceWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [Parameter(Mandatory)][string]$Reason
    )
    $lead = if ($Service.Fallback) { $Service.Fallback } else { "$($Service.DisplayName) is not available, and start goes on without it" }
    Write-Warning "${lead}: $Reason"
}

# Finish the optional $Service that Use-LocalAIService launched or reused ($Use): wait for a launched one, check that it listens on
# loopback only and, unless $Installed, its pin. Returns its version; on a failure warns with Write-LocalAIServiceWarning, stops it when
# this start launched it (it is in $Started, and $StatePath is saved) and returns $null.
function Complete-OptionalLocalAIService {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [Parameter(Mandatory)][hashtable]$Use,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Started,
        [bool]$Installed
    )
    try {
        $version = if ($Use.Process) { Complete-LocalAIService -Service $Service -Process $Use.Process -State $State -StatePath $StatePath } else { $Use.Version }
        $fix = "The launcher starts it on 127.0.0.1; run 'local-ai stop' and check what else uses port $($Service.Port)."
        if (-not (Test-LoopbackListener -Port $Service.Port -Name $Service.DisplayName -Fix $fix)) {
            throw "port $($Service.Port) does not listen on loopback only, as the warning above says."
        }
    } catch {
        Write-LocalAIServiceWarning -Service $Service -Reason $_.Exception.Message
        $null = Stop-StartedLocalAIService -Name $Service.Name -State $State -StatePath $StatePath -Started $Started
        return $null
    }
    # install has already warned about an installed version other than the pin.
    if (-not $Installed) { $null = Test-LocalAIServicePin -Service $Service -Version $version }
    return [string]$version
}

# Warn when Ollama at $Url runs on this PC but listens beyond loopback, naming the app setting to change.
# A server on another computer only gets a note. Returns $false when the bind check warned, else $true.
function Test-OllamaLoopback {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Url
    )
    $uri = [uri]$Url
    # A LAN address or the computer name in OLLAMA_HOST is still this PC, and is exposed.
    if (Test-LocalHostName -HostName $uri.Host) {
        $fix = "Turn off 'Expose Ollama to the network' in the Ollama app's settings, make sure OLLAMA_HOST is unset or names 127.0.0.1, then quit and restart the Ollama app."
        return Test-LoopbackListener -Port $uri.Port -Name 'Ollama' -Fix $fix
    }
    Write-Host "Ollama at $Url runs on another computer, so its bind address is not checked."
    return $true
}

# Return $true when GET $Url/api/ps lists $Alias, alone or as $Alias:latest, among the loaded models.
# Throws when Ollama does not answer within 5 s.
function Test-OllamaModelLoaded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Alias
    )
    $answer = Invoke-RestMethod -Uri "$Url/api/ps" -UseBasicParsing -TimeoutSec 5
    $names = @(foreach ($model in @($answer.models)) { if ($model) { [string]$model.name; [string]$model.model } })
    return ($names -contains $Alias) -or ($names -contains "${Alias}:latest")
}

# Return $true when $Service runs at its pin, judged by the running $Version or, when Pin.Running is $false, by the stamped value.
# Otherwise warn, naming both, the component (Pin.Label, else DisplayName) and 'local-ai update', and return $false. No Pin passes.
function Test-LocalAIServicePin {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Service,
        [string]$Version
    )
    $pin = $Service.Pin
    if (-not $pin) { return $true }
    $actual = if ($pin.Running) { $Version } else { $pin.Stamped }
    if ($actual -eq $pin.Version) { return $true }
    $stale = ''
    if ($pin.Running -and $pin.Stamped -ne $Version) { $stale = " install-stamp.json records $($pin.Stamped) instead; 'local-ai install' records what is installed." }
    $label = if ($pin.Label) { $pin.Label } else { $Service.DisplayName }
    Write-Warning ("$label $actual runs, but $($pin.Setting) pins $($pin.Version). Run 'local-ai update' to move " +
        "to the pin$($pin.Hint).$stale")
    return $false
}

# Stop the mcpo that $State.Services records, also one an earlier start left running, with Stop-StartedLocalAIService -AnyStart, saving
# $StatePath. Warns when it runs but cannot be stopped, since it then still serves Files.Root to any program with the key. Returns $true when it stopped one.
function Stop-RecordedFilesService {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the start verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Started
    )
    $result = Stop-StartedLocalAIService -Name 'Files' -State $State -StatePath $StatePath -Started $Started -AnyStart
    if ($result -eq 'failed') {
        Write-Warning "The mcpo an earlier start left running still serves the file tools, since it could not be stopped. Run 'local-ai stop'."
    }
    return $result -eq 'stopped'
}

# The start verb: install first when install-stamp.json lacks Ollama, Model or OpenWebUI, else wait for Ollama; record in state.json at once an Ollama app
# either started (Save-OllamaRecord); check Ollama has Model.Alias; stop a recorded mcpo this start leaves out; launch ComfyUI, the image gate and mcpo,
# waiting for the last two at once, then Open WebUI using those that answered; open the browser, then check ComfyUI. Adds each service it launched to
# Context.Launched (a List[string]). Returns 0; 2 on warnings; 1 when Open WebUI fails.
function Start-LocalAI {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A launcher verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $settings = $Context.Settings
    $paths = $Context.Paths
    $warned = @()
    Update-SessionPath
    $url = Resolve-OllamaUrl -Setting $settings.Ollama.Url
    # Wait-OllamaServer and Get-OllamaModelBlob run the ollama program.
    Assert-OllamaCliUrl -Url $url
    $stamp = Read-LocalAIState -Path $paths.InstallStamp
    $missing = @(foreach ($key in 'Ollama', 'Model', 'OpenWebUI') { if ($stamp[$key] -isnot [hashtable]) { $key } })
    $installed = $missing.Count -gt 0
    $alias = $settings.Model.Alias
    if ($installed) {
        Write-Host "install-stamp.json does not record $($missing -join ', '), so install runs first."
        # It records any Ollama app it started at once.
        $null = Install-LocalAI -Context $Context -WarningVariable +warned
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
    } else {
        # install has just done both.
        $wait = Wait-OllamaServer -Url $url -PassThru -How 'start'
        # Saved before any later step can throw, so stop quits the app this wait started. A server that was down held no model; otherwise the recorded
        # Url and Alias stay until the checks below pass, as stop unloads the alias they name.
        if ($wait.App) { $null = Save-OllamaRecord -Path $paths.State -Url $url -Alias $alias -App $wait.App }
        $null = Test-OllamaLoopback -Url $url -WarningVariable +warned
    }
    if (@(Get-OllamaModelBlob -Name $alias).Count -eq 0) {
        throw "Ollama at $url has no model '$alias'. Run 'local-ai install' to create it."
    }
    $openWebUI = $stamp['OpenWebUI']
    if ($openWebUI -isnot [hashtable] -or -not ($openWebUI.Path -and (Test-Path -LiteralPath $openWebUI.Path -PathType Leaf))) {
        throw "install-stamp.json names no open-webui.exe that exists ('$($openWebUI.Path)'). Run 'local-ai install'."
    }
    $state = Read-LocalAIState -Path $paths.State
    if ($state['Services'] -isnot [hashtable]) { $state['Services'] = @{} }
    # Without ComfyUI, Open WebUI starts with images off, so its image button does not point at a ComfyUI that is not there.
    $comfyUI = $null
    $workflow = $null
    if ($settings.Images.Enabled) {
        try {
            $workflow = Get-ImageWorkflow -Settings $settings -RepoRoot $Context.RepoRoot
            $problem = Get-ComfyUIStartProblem -Settings $settings -Stamp $stamp -State $state -WarningVariable +warned
        } catch {
            $problem = $_.Exception.Message
        }
        if ($problem) {
            Write-Warning "Images are off for this start, and ComfyUI does not start: $problem" -WarningVariable +warned
            $workflow = $null
        } else {
            $comfyUI = $stamp['ComfyUI']
        }
    }
    # Without mcpo, Open WebUI starts with TOOL_SERVER_CONNECTIONS '[]'.
    $files = $null
    if ($settings.Files.Root) {
        $problem = $null
        try {
            $problem = Get-FilesStartProblem -Settings $settings -Paths $paths -Stamp $stamp -OllamaUrl $url -RepoRoot $Context.RepoRoot -WarningVariable +warned
            if (-not $problem) {
                $record = $stamp['Files']
                # Test-FilesRoot names its own reason. The install this start may have run first checked the same folder, so a warning it gave
                # already is not repeated.
                $rootWarnings = @()
                $served = Test-FilesRoot -Settings $settings -Paths $paths -RepoRoot $Context.RepoRoot -ToolDir ([string]$record.ToolDir) `
                    -WarningVariable rootWarnings -WarningAction SilentlyContinue
                foreach ($warning in $rootWarnings) {
                    if (@($warned | Where-Object { "$_" -ceq "$warning" }).Count -eq 0) { Write-Warning "$warning" -WarningVariable +warned }
                }
                if ($served) {
                    $files = @{ McpoPath = $record.McpoPath; McpoVersion = $record.McpoVersion; Key = (Get-FilesKey -Path $paths.FilesKey) }
                    New-McpoConfig -Settings $settings -Path $paths.McpoConfig -NodePath $record.Node.Path -ServerScript $record.Script
                }
            }
        } catch {
            $problem = $_.Exception.Message
            $files = $null
        }
        if ($problem) { Write-Warning "The file tools are off for this start: $problem" -WarningVariable +warned }
    }
    # The image gate starts only when ComfyUI launched, and mcpo only when Get-FilesStartProblem and Test-FilesRoot passed above.
    $services = @(Get-LocalAIService -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUI $openWebUI -ComfyUI $comfyUI -ImageWorkflow $workflow `
            -Files $files -WarningVariable +warned)

    # stop unloads this model from this server without reading settings, and quits the Ollama app recorded with them: the one this start's wait or install
    # recorded above, or an earlier one while Test-OllamaAppRecord finds it serving this server.
    $app = if ($state['Ollama'] -is [hashtable] -and $state['Ollama'].App -is [hashtable]) { $state['Ollama'].App } else { $null }
    if ($app -and -not (Test-OllamaAppRecord -App $app -Url $url)) { $app = $null }
    $state['Ollama'] = @{ Url = $url; Alias = $alias; App = $app }
    Write-LocalAIState -Path $paths.State -State $state
    $webUrl = @($services | Where-Object { $_.Name -eq 'OpenWebUI' })[0].Url
    $gate = @($services | Where-Object { $_.Name -eq 'ImageGate' })
    $tools = @($services | Where-Object { $_.Name -eq 'Files' })
    $started = New-Object System.Collections.Generic.List[string]
    # mcpo serves Files.Root to any program with the key, a reused Open WebUI included, so one an earlier start left running stops when this
    # start leaves the file tools out: it would go on serving a folder the checks above refused, or one Files.Root no longer names.
    $filesStopped = $false
    if ($tools.Count -eq 0 -and $state.Services['Files'] -is [hashtable]) {
        $filesStopped = Stop-RecordedFilesService -State $state -StatePath $paths.State -Started $started -WarningVariable +warned
    }
    $up = New-Object System.Collections.Generic.List[string]
    $launched = @{}
    $failure = $null
    $requiredUp = $false
    $completed = $false
    try {
        # Each service is launched before any is waited for, so ComfyUI's slow start overlaps Open WebUI's. Those marked WaitFirst, the
        # image gate and mcpo, are waited for at once, since Open WebUI reads COMFYUI_BASE_URL and TOOL_SERVER_CONNECTIONS only when it starts.
        foreach ($service in $services) {
            # The gate would front whatever holds ComfyUI's port, which ComfyUI's warning names; images then go to that port directly.
            if ($service.Name -eq 'ImageGate' -and -not $launched.ContainsKey('ComfyUI')) {
                Write-LocalAIServiceWarning -Service $service -Reason 'this start runs no ComfyUI of its own for the gate to front, as the warning above says.' `
                    -WarningVariable +warned
                continue
            }
            if ($service.Name -eq 'OpenWebUI' -and @($services | Where-Object { $_.WaitFirst -and -not $up.Contains($_.Name) }).Count -gt 0) {
                # Images then go to ComfyUI itself, and the file tools stay off. The table was built for every service up, and its
                # warnings are counted already.
                $imageUrl = if ($up.Contains('ImageGate')) { $gate[0].Url } else { '' }
                $filesKey = if ($up.Contains('Files')) { $tools[0].Key } else { '' }
                $service.Environment = Get-OpenWebUIEnvironment -Settings $settings -OllamaUrl $url -ImageWorkflow $workflow -ImageUrl $imageUrl `
                    -FilesKey $filesKey -WarningAction SilentlyContinue
            }
            try {
                $launched[$service.Name] = Use-LocalAIService -Service $service -State $state -StatePath $paths.State -Keep $settings.Logs.Keep -Started $started -WarningVariable +warned
            } catch {
                if ($service.Required) {
                    $failure = $_.Exception.Message
                    break
                }
                Write-LocalAIServiceWarning -Service $service -Reason $_.Exception.Message -WarningVariable +warned
                $null = Stop-StartedLocalAIService -Name $service.Name -State $state -StatePath $paths.State -Started $started
                # A recorded mcpo that does not answer for this start's root, server and key would serve what this start did not check.
                if ($service.Name -eq 'Files' -and (Stop-RecordedFilesService -State $state -StatePath $paths.State -Started $started -WarningVariable +warned)) {
                    $filesStopped = $true
                }
                continue
            }
            # update rolls Open WebUI back only once this start launched it.
            if ($launched[$service.Name].Process -and $Context.Launched -is [System.Collections.Generic.List[string]]) { $Context.Launched.Add($service.Name) }
            if ($service.WaitFirst) {
                $version = Complete-OptionalLocalAIService -Service $service -Use $launched[$service.Name] -State $state -StatePath $paths.State `
                    -Started $started -Installed $installed -WarningVariable +warned
                if ($version) { $up.Add($service.Name) }
            }
        }
        foreach ($service in @($services | Where-Object { $_.Required -and -not $failure })) {
            $use = $launched[$service.Name]
            try {
                $version = if ($use.Process) { Complete-LocalAIService -Service $service -Process $use.Process -State $state -StatePath $paths.State } else { $use.Version }
            } catch {
                $failure = $_.Exception.Message
                break
            }
            $up.Add($service.Name)
            # install has already warned about an installed version other than the pin.
            if (-not $installed) { $null = Test-LocalAIServicePin -Service $service -Version $version -WarningVariable +warned }
            $fix = "The launcher starts it on 127.0.0.1; run 'local-ai stop' and check what else uses port $($service.Port)."
            $null = Test-LoopbackListener -Port $service.Port -Name $service.DisplayName -Fix $fix -WarningVariable +warned
        }
        if (-not $failure) {
            # Open WebUI reads COMFYUI_BASE_URL and TOOL_SERVER_CONNECTIONS only when it starts.
            if ($filesStopped -and -not $launched['OpenWebUI'].Process) {
                Write-Warning ("Open WebUI, which an earlier start left running, still offers the file tools, but the mcpo they call is stopped, " +
                    "so calls to them fail. Run 'local-ai stop', then start again.") -WarningVariable +warned
            } elseif ($launched['OpenWebUI'].Stale) {
                Write-Warning ("Open WebUI, which an earlier start left running, keeps the settings it started with, which differ from this start's, " +
                    "such as where images go, which file tools it offers and which variables of this window it inherits. Run 'local-ai stop', " +
                    "then start again.") -WarningVariable +warned
            }
            # The browser need not wait for the optional services, which only warn from here on.
            $requiredUp = $true
            if (-not $Context.NoBrowser) {
                try {
                    Start-Process -FilePath $webUrl
                } catch {
                    Write-Warning "Could not open the browser at ${webUrl}: $($_.Exception.Message)" -WarningVariable +warned
                }
            }
            foreach ($service in @($services | Where-Object { -not $_.Required -and -not $_.WaitFirst -and $launched.ContainsKey($_.Name) })) {
                $version = Complete-OptionalLocalAIService -Service $service -Use $launched[$service.Name] -State $state -StatePath $paths.State `
                    -Started $started -Installed $installed -WarningVariable +warned
                if (-not $version) {
                    # The gate this start put in front of it would hold ComfyUI's venv for nothing.
                    if ($service.Name -eq 'ComfyUI') { $null = Stop-StartedLocalAIService -Name 'ImageGate' -State $state -StatePath $paths.State -Started $started }
                    continue
                }
                $up.Add($service.Name)
                if ($service.Name -eq 'ComfyUI') {
                    $null = Test-ComfyUICheckpoint -Url $service.Url -File $settings.Images.File -WarningVariable +warned
                    $null = Test-ComfyUIDevice -Url $service.Url -WarningVariable +warned
                    # ComfyUI.InheritEnvironment changes what ComfyUI inherits; the gate's script reads none of its variables, so an older gate may stay.
                    if ($launched[$service.Name].Stale) {
                        Write-Warning ("ComfyUI, which an earlier start left running, keeps the variables of this window it started with, which differ " +
                            "from those this start lets it inherit, such as the GPU it uses. Run 'local-ai stop', then start again.") -WarningVariable +warned
                    }
                }
            }
        }
        $completed = -not $failure
    } finally {
        # Also runs on Ctrl+C, so an interrupted wait leaves nothing behind; once Open WebUI answers, only what has not answered stops.
        if (-not $completed) {
            $pending = @($started | Where-Object { -not ($requiredUp -and $up.Contains($_)) })
            if ($pending.Count -gt 0) { Write-Host 'Stopping what this start launched...' }
            foreach ($name in $pending) { $null = Stop-StartedLocalAIService -Name $name -State $state -StatePath $paths.State -Started $started }
        }
    }
    if ($failure) {
        Write-Host "Error: $failure" -ForegroundColor Red
        return 1
    }

    Write-Host ''
    Write-Host "Web UI:         $webUrl" -ForegroundColor Green
    Write-Host "Agent endpoint: $url/v1 (OpenAI-compatible), model $alias"
    if ($up.Contains('ComfyUI')) {
        $comfyUrl = @($services | Where-Object { $_.Name -eq 'ComfyUI' })[0].Url
        Write-Host "Images:         $comfyUrl (ComfyUI, $($settings.Images.File))"
        if ($up.Contains('ImageGate')) { Write-Host "                through $($gate[0].Url), which unloads $alias from Ollama before each image" }
    }
    if ($up.Contains('Files')) { Write-Host "File tools:     $($tools[0].Root), read-only, through mcpo at $($tools[0].Url)" }
    if ($warned.Count -gt 0) {
        Write-Host "Start finished with $($warned.Count) warning(s); see above." -ForegroundColor Yellow
        return 2
    }
    return 0
}

# Quit the Ollama app that the state.json record $Record says local-ai started, for the server at $Url, printing why; returns @{ Result; Reason }, Reason
# being the last line printed. Result: 'stale' when $Url is not on this PC or the app no longer runs as recorded; 'kept' when /api/ps lists a model other
# than $Alias or cannot say, another program holds a connection to the port, or the app runs in another Windows session or shows a window; 'stopped' once
# it ended, through the tray's own quit (WM_CLOSE) within $TimeoutSeconds or by itself; 'forced' after taskkill /T /F (Stop-LocalAIService) of its tree,
# or of its recorded server when only that still ran; 'failed' when it cannot be inspected or still runs afterwards. Kills nothing else.
function Stop-OllamaApp {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the stop and uninstall verbs, which offer no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$Url,
        [AllowEmptyString()][string]$Alias = '',
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 20
    )
    $id = [int]$Record.Pid
    $uri = [uri]$Url
    $port = if ([int]$Record.Port -gt 0) { [int]$Record.Port } else { $uri.Port }
    $report = {
        param([string]$Result, [string]$Reason)
        if ($Result -eq 'failed') { Write-Host $Reason -ForegroundColor Red } else { Write-Host $Reason }
        return @{ Result = $Result; Reason = $Reason }
    }
    if (-not (Test-LocalHostName -HostName $uri.Host)) {
        return & $report 'stale' "Ollama at $Url runs on another computer, so stop quits no Ollama app for it."
    }
    $found = Get-RecordedProcessState -Record $Record
    if ($found -eq 'other') {
        return & $report 'stale' "The Ollama app local-ai started (PID $id) no longer runs, or was restarted by an update or by you, so stop leaves Ollama as it is."
    }
    if ($found -eq 'unreadable') {
        return & $report 'failed' ("The Ollama app local-ai started (PID $id) still runs, but this window may not inspect it, as when it was started from an " +
            "elevated window, so it was not quit. Run 'local-ai stop' from an elevated window.")
    }
    # Quitting unloads every model Ollama holds, also one another program loaded.
    $others = @()
    try {
        $ps = Invoke-RestMethod -Uri "$Url/api/ps" -UseBasicParsing -TimeoutSec 5
        $others = @(foreach ($model in @($ps.models)) {
                if (-not $model) { continue }
                $names = @([string]$model.name, [string]$model.model)
                if (-not ($names -contains $Alias -or $names -contains "${Alias}:latest")) { [string]$model.name }
            })
    } catch {
        $why = $_.Exception.Message
        # Without a server on the port no model is loaded, so the quit cuts nothing off.
        if (Get-PortOwner -Port $port) {
            return & $report 'kept' ("Ollama does not list its loaded models at $Url/api/ps ($why), so stop cannot tell whether another program uses it, and " +
                "the Ollama app local-ai started (PID $id) keeps running; quit it from its tray icon, or run 'local-ai stop' again.")
        }
    }
    if ($others.Count -gt 0) {
        return & $report 'kept' ("Ollama still has $($others -join ', ') loaded, which another program may be using, so the Ollama app local-ai started " +
            "(PID $id) keeps running. Ollama unloads an idle model after its keep-alive (5 minutes by default); run 'local-ai stop' again then, or quit the " +
            'app from its tray icon.')
    }
    # The launcher's services have stopped by now, so a connection from outside the app is another program's, such as a coding tool on the /v1 endpoint.
    try {
        $clients = @(Get-LoopbackClient -Port $port -Exclude @($PID, $id) | Where-Object { -not (Test-ProcessDescendant -ProcessId $_.Id -AncestorId $id) })
    } catch {
        return & $report 'kept' ("Cannot tell which programs are connected to Ollama on port $port ($($_.Exception.Message)), so the Ollama app local-ai " +
            "started (PID $id) keeps running; quit it from its tray icon, or run 'local-ai stop' again.")
    }
    if ($clients.Count -gt 0) {
        $who = @($clients | ForEach-Object { if ($_.Name) { "$($_.Name) (PID $($_.Id))" } else { "PID $($_.Id)" } }) -join ', '
        return & $report 'kept' ("Ollama at $Url still has connections from $who, which may still use it, so the Ollama app local-ai started (PID $id) " +
            "keeps running; run 'local-ai stop' again once they are done, or quit the app from its tray icon.")
    }
    # EnumWindows lists only this session's windows, so from another session the app would seem to have none, open or hidden.
    if (-not (Test-ProcessInThisSession -ProcessId $id)) {
        return & $report 'kept' ("The Ollama app local-ai started (PID $id) runs in another Windows session, whose windows stop cannot see, so it keeps " +
            "running; run 'local-ai stop' on that desktop, or quit the app from its tray icon.")
    }
    try {
        $open = Test-OllamaAppWindowOpen -ProcessId $id
    } catch {
        # As where Add-Type is not allowed; without the windows, neither the check nor the quit can run.
        return & $report 'failed' ("Cannot tell whether the Ollama app local-ai started (PID $id) has a window open, so it was not quit: " +
            "$($_.Exception.Message) Quit it from its tray icon.")
    }
    if ($open) {
        return & $report 'kept' ("The Ollama app local-ai started (PID $id) has a window open, so it keeps running; close that window, then run " +
            "'local-ai stop' again, or quit the app from its tray icon.")
    }
    # The server, ollama.exe serve, is the app's direct child; the app gives it a new PID when it restarts it.
    $serve = Get-PortOwner -Port $port
    if ($serve -and -not (Test-ProcessDescendant -ProcessId $serve.Id -AncestorId $id -MaxDepth 1)) { $serve = $null }
    $held = {
        $owner = Get-PortOwner -Port $port
        [bool]($owner -and (($serve -and $owner.Id -eq $serve.Id -and $owner.StartTicks -eq $serve.StartTicks) -or
                (Test-ProcessDescendant -ProcessId $owner.Id -AncestorId $id -MaxDepth 1)))
    }
    $handle = Find-OllamaAppWindow -ProcessId $id
    if ($handle -eq [IntPtr]::Zero) {
        $why = 'has no window to ask it to quit'
    } elseif (-not (Send-OllamaAppClose -Handle $handle)) {
        $why = 'refused the request to quit'
    } else {
        # The app gives its server 5 s to stop before it kills it (app/server/server.go in Ollama v0.40.13).
        for ($poll = 1; $poll -le $TimeoutSeconds * 2; $poll++) {
            Start-Sleep -Milliseconds 500
            if (-not (Test-RecordedProcess -Record $Record) -and -not (& $held)) {
                return & $report 'stopped' "Quit the Ollama app local-ai started (PID $id)."
            }
        }
        $why = "did not quit within $TimeoutSeconds s"
    }
    # /T takes the server and its runners along, as Ollama's own installer does; the app alone would leave its server holding the port. Stop-LocalAIService
    # checks the record again, so it kills the app's tree, or the recorded server once the app has ended, or nothing.
    $appRan = Test-RecordedProcess -Record $Record
    $result = Stop-LocalAIService -Name 'Ollama app' -Record $Record -TimeoutSeconds ([math]::Min(10, $TimeoutSeconds))
    if ($result -eq 'stopped') {
        $what = if ($appRan) { 'it, its server and the models it held' } else { 'the server it left running, with the models it held' }
        return & $report 'forced' "The Ollama app local-ai started (PID $id) $why, so taskkill /T /F ended $what."
    }
    if ($result -eq 'stale' -and -not (& $held)) {
        return & $report 'stopped' "The Ollama app local-ai started (PID $id) ended before taskkill ran."
    }
    return & $report 'failed' "The Ollama app local-ai started (PID $id), or its server on port $port, still runs; see above."
}

# The stop verb, which reads only state.json: stop every recorded service with Stop-LocalAIService, dropping the records it stopped or found stale, unload the
# recorded model from the recorded server when /api/ps lists it, then, unless -KeepOllama, quit the Ollama app state.json records as local-ai's with
# Stop-OllamaApp; an Ollama that ran before stays. Returns 0, or 1 when anything could not be stopped; throws when state.json is not JSON.
function Stop-LocalAI {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A launcher verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        # For update and uninstall, which still need Ollama afterwards.
        [switch]$KeepOllama
    )
    $statePath = $Context.Paths.State
    $state = Read-LocalAIState -Path $statePath
    $services = $state['Services']
    if ($services -isnot [hashtable]) { $services = @{} }
    $done = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    # Name order stops ComfyUI, Files and ImageGate before OpenWebUI, the client of the others; /T takes mcpo's node server along.
    foreach ($name in @($services.Keys | Sort-Object)) {
        $record = $services[$name]
        $result = if ($record -is [hashtable]) { Stop-LocalAIService -Name $name -Record $record } else { 'stale' }
        if ($result -eq 'failed') {
            $failed.Add($name)
            continue
        }
        if ($result -eq 'stopped') { $done.Add($name) }
        $services.Remove($name)
        $state['Services'] = $services
        Write-LocalAIState -Path $statePath -State $state
    }

    $ollama = $state['Ollama']
    $answers = $false
    if ($ollama -is [hashtable] -and $ollama.Url -and $ollama.Alias) {
        $alias = [string]$ollama.Alias
        $loaded = $false
        try {
            $loaded = Test-OllamaModelLoaded -Url $ollama.Url -Alias $alias
            $answers = $true
            if (-not $loaded) { Write-Host "$alias is not loaded in Ollama." }
        } catch {
            Write-Host "Ollama does not answer at $($ollama.Url), so $alias is not loaded there."
        }
        if ($loaded) {
            try {
                # The request 'ollama stop' sends, but to the recorded server rather than to this window's OLLAMA_HOST.
                $body = ConvertTo-Json -InputObject @{ model = $alias; keep_alive = 0 } -Depth 2 -Compress
                $null = Invoke-RestMethod -Method Post -Uri "$($ollama.Url)/api/generate" -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30
                $timer = [Diagnostics.Stopwatch]::StartNew()
                while (Test-OllamaModelLoaded -Url $ollama.Url -Alias $alias) {
                    if ($timer.Elapsed.TotalSeconds -ge 10) { throw "/api/ps still lists $alias 10 s after the unload request." }
                    Start-Sleep -Milliseconds 500
                }
                $done.Add($alias)
                Write-Host "Unloaded $alias."
            } catch {
                Write-Host "Could not unload ${alias}: $($_.Exception.Message)" -ForegroundColor Red
                $failed.Add($alias)
            }
        }
    }

    # Last, once its clients have stopped and the alias is unloaded.
    $ollamaRuns = $answers
    if (-not $KeepOllama -and $ollama -is [hashtable] -and $ollama.Url) {
        if ($ollama.App -is [hashtable]) {
            $quit = Stop-OllamaApp -Record $ollama.App -Url ([string]$ollama.Url) -Alias ([string]$ollama.Alias)
            if ($quit.Result -eq 'failed') {
                $failed.Add('Ollama')
            } elseif ($quit.Result -eq 'kept') {
                $ollamaRuns = $true
            } else {
                if ($quit.Result -ne 'stale') {
                    $done.Add('Ollama')
                    $ollamaRuns = $false
                }
                $ollama['App'] = $null
                $state['Ollama'] = $ollama
                Write-LocalAIState -Path $statePath -State $state
            }
        } elseif ($answers) {
            # Also an app local-ai started but could not tell apart, which Wait-OllamaServer says when it starts it.
            Write-Host 'Ollama keeps running, since state.json records no Ollama app that local-ai started.'
        }
    }

    if ($failed.Count -gt 0) {
        Write-Host "Stop finished, but $($failed -join ', ') could not be stopped; see above." -ForegroundColor Red
        return 1
    }
    $what = @()
    if ($done.Count -gt 0) { $what += "stopped $($done -join ', ')" } elseif (-not $ollamaRuns) { $what += 'nothing was running' }
    if ($ollamaRuns) { $what += 'Ollama keeps running' }
    Write-Host "Stop finished: $($what -join '; ')." -ForegroundColor Green
    return 0
}

# Return $Value as one line of compact JSON in which every character above 0x7F is a \uXXXX escape, so any console code page carries it
# intact. $Value holds tables, lists, strings, numbers, booleans and $null only. Pure.
function ConvertTo-LocalAIJsonText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Value
    )
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($found) '\u{0:x4}' -f [int][char]$found.Value })
}

# Return the text of the file $Path as UTF-8, or as its byte order mark says, opened so that a program writing or replacing it meanwhile is
# not disturbed; $null when it does not exist. Throws when it cannot be read.
function Read-SharedText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not [IO.File]::Exists($Path)) { return $null }
    $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]'ReadWrite, Delete')
    try {
        $reader = New-Object IO.StreamReader -ArgumentList $stream, (New-Object Text.UTF8Encoding $false), $true
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

# Return $Seconds as a short duration: '3 d 4 h', '2 h 5 min', '7 min' or '40 s'; a negative value counts as 0. Pure.
function Format-LocalAIDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][double]$Seconds
    )
    $span = [TimeSpan]::FromSeconds([math]::Max(0, $Seconds))
    if ($span.TotalDays -ge 1) { return '{0} d {1} h' -f [int][math]::Floor($span.TotalDays), $span.Hours }
    if ($span.TotalHours -ge 1) { return '{0} h {1} min' -f $span.Hours, $span.Minutes }
    if ($span.TotalMinutes -ge 1) { return '{0} min' -f $span.Minutes }
    return '{0} s' -f $span.Seconds
}

# Return $Bytes as '8.0 GB', '512 MB' or '12 KB', with a point as the decimal mark in any culture. Pure.
function Format-LocalAISize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][double]$Bytes
    )
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return ($Bytes / 1GB).ToString('0.0', $culture) + ' GB' }
    if ($Bytes -ge 1MB) { return ($Bytes / 1MB).ToString('0', $culture) + ' MB' }
    return ([math]::Ceiling($Bytes / 1KB)).ToString($culture) + ' KB'
}

# Return the addresses in $Address that are not loopback, such as 0.0.0.0, :: or a LAN address, in their order. Pure.
function Select-ExposedAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][string[]]$Address = @()
    )
    foreach ($item in $Address) {
        $ip = $null
        if (-not ([Net.IPAddress]::TryParse($item, [ref]$ip) -and [Net.IPAddress]::IsLoopback($ip))) { $item }
    }
}

# Return the files (FileInfo) below the folder $Root whose extension is one of $Extension, in any case, without entering links or folders named in
# $SkipFolder, and stopping after $MaxEntries entries. A missing folder gives nothing, and a folder that cannot be listed is passed over. Reads only.
function Find-LocalAIFile {
    [CmdletBinding()]
    [OutputType([IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Extension,
        [string[]]$SkipFolder = @(),
        [ValidateRange(1, 10000000)][int]$MaxEntries = 100000
    )
    if (-not [IO.Directory]::Exists($Root)) { return }
    # Get-ChildItem -Recurse would follow junctions in Windows PowerShell 5.1.
    $pending = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $pending.Push((New-Object IO.DirectoryInfo -ArgumentList $Root))
    $seen = 0
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try {
            $entries = $current.GetFileSystemInfos()
        } catch {
            Write-Verbose "Cannot list $($current.FullName): $($_.Exception.Message)"
            continue
        }
        foreach ($entry in $entries) {
            $seen++
            if ($seen -gt $MaxEntries) { return }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry.Attributes -band [IO.FileAttributes]::Directory) {
                if ($SkipFolder -notcontains $entry.Name) { $pending.Push([IO.DirectoryInfo]$entry) }
            } elseif ($Extension -contains $entry.Extension) {
                $entry
            }
        }
    }
}

# Return the full paths of the .ps1, .psm1, .psd1 and .cmd files below $Root, outside .git, that carry a Zone.Identifier stream, the mark
# Windows gives downloaded files and RemoteSigned refuses for scripts. Reads only; never removes a mark.
function Get-ZoneMarkedFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root
    )
    foreach ($file in @(Find-LocalAIFile -Root $Root -Extension '.ps1', '.psm1', '.psd1', '.cmd' -SkipFolder '.git')) {
        if (Get-Item -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) { $file.FullName }
    }
}

# Return the page file as Windows reports it through CIM: @{ Automatic (system-managed for all drives); Settings (@{ Name; InitialMB; MaximumMB }
# per configured file, 0 and 0 meaning system-managed); Files (@{ Name; CurrentMB } per file in use); CommitLimitBytes }. Throws when CIM fails.
function Get-PageFileStatus {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $configured = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop | ForEach-Object {
            @{ Name = [string]$_.Name; InitialMB = [long]$_.InitialSize; MaximumMB = [long]$_.MaximumSize }
        })
    $used = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.Name; CurrentMB = [long]$_.AllocatedBaseSize } })
    # TotalVirtualMemorySize, in KB, equals the commit limit that GlobalMemoryStatusEx reports.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    return @{ Automatic = [bool]$system.AutomaticManagedPagefile; Settings = $configured; Files = $used; CommitLimitBytes = [long]$os.TotalVirtualMemorySize * 1024 }
}

# Return a WScript.Shell COM object, whose CreateShortcut loads an existing .lnk file and writes it only on Save.
function Get-WScriptShell {
    [CmdletBinding()]
    param()
    return New-Object -ComObject WScript.Shell
}

# Return the model Qwen Code uses, model.name in its settings file $Path (by default %USERPROFILE%\.qwen\settings.json), or $null when the file is missing,
# is not JSON or names none. Reads only.
function Get-QwenCodeModel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path
    )
    if (-not $Path) {
        if (-not $env:USERPROFILE) { return $null }
        $Path = [IO.Path]::Combine($env:USERPROFILE, '.qwen\settings.json')
    }
    try {
        $text = Read-SharedText -Path $Path
        if (-not $text) { return $null }
        $data = ConvertFrom-LocalAIJson -Text $text
    } catch {
        Write-Verbose "Qwen Code's settings $Path cannot be read: $($_.Exception.Message)"
        return $null
    }
    if ($data -isnot [hashtable]) { return $null }
    $model = $data['model']
    if ($model -is [hashtable]) { $model = $model['name'] }
    if ($model -is [string] -and $model) { return $model }
    return $null
}

# Return what still uses the superseded alias $Name: that Qwen Code (Get-QwenCodeModel) does, with the command that points it at $Alias, or $null when
# nothing does. Reads files only.
function Get-SupersededAliasNote {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Alias
    )
    $qwen = Get-QwenCodeModel
    if ($qwen -and ($qwen -eq $Name -or $qwen -eq "${Name}:latest")) {
        return ("Qwen Code still uses it (model.name in its settings.json); point Qwen Code at $Alias first with: " +
            "ollama launch qwen --model $Alias --config --yes")
    }
    return $null
}

# Return the app.ico beside the ollama program on PATH, the icon of the Ollama app, or $null when there is none.
function Get-OllamaIcon {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $program = @(Get-Command -Name 'ollama' -CommandType Application -ErrorAction SilentlyContinue)
    if ($program.Count -eq 0) { return $null }
    $icon = Join-Path (Split-Path $program[0].Path -Parent) 'app.ico'
    if (Test-Path -LiteralPath $icon -PathType Leaf) { return $icon }
    return $null
}

# Return Get-LocalAIService's table for $Settings from the install-stamp.json table $Stamp, with a stand-in for each part install has not recorded, so
# every service the settings turn on is listed; mcpo gets the key in Paths.FilesKey, or '' when it cannot be read. Reads files only, and never prints the key.
function Get-LocalAIServicePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$OllamaUrl
    )
    $openWebUI = $Stamp['OpenWebUI']
    if ($openWebUI -isnot [hashtable]) { $openWebUI = @{ Version = $null; Path = $null; Python = $null } }
    $comfyUI = $null
    $workflow = $null
    if ($Settings.Images.Enabled) {
        $comfyUI = $Stamp['ComfyUI']
        if ($comfyUI -isnot [hashtable] -or -not $comfyUI.Python) {
            # GetFullPath and Combine, unlike the provider and Join-Path, do not refuse a drive this PC does not have now.
            $comfyUI = @{ Python = [IO.Path]::Combine([IO.Path]::GetFullPath([string]$Settings.ComfyUI.Dir), '.venv\Scripts\python.exe'); Commit = $null }
        }
        # Only Open WebUI's image keys take it, and the callers do not start Open WebUI.
        $workflow = @{ Workflow = ''; Nodes = '' }
    }
    $files = $null
    if ($Settings.Files.Root) {
        $key = ''
        try { $key = Get-FilesKey -Path $Paths.FilesKey } catch { $key = '' }
        $record = $Stamp['Files']
        if ($record -isnot [hashtable]) { $record = @{} }
        $files = @{ McpoPath = $record.McpoPath; McpoVersion = $record.McpoVersion; Key = $key }
    }
    Get-LocalAIService -Settings $Settings -Paths $Paths -OllamaUrl $OllamaUrl -OpenWebUI $openWebUI -ComfyUI $comfyUI -ImageWorkflow $workflow `
        -Files $files -WarningAction SilentlyContinue
}

# Return a new, empty status section: Key names it in the -Json document, Title heads it on screen, Data holds its facts for -Json, and Lines
# its lines, each [ordered]@{ level; text } with level fact, info, advice, degraded (exit code 2) or down (exit code 1). Pure.
function Get-StatusSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Title
    )
    return @{ Key = $Key; Title = $Title; Data = [ordered]@{}; Lines = New-Object System.Collections.Generic.List[object] }
}

# Return the status section for Ollama at $Url: its version against $Stamp, whether the Ollama app is the one state.json records as local-ai's ($App) for
# this server, so that stop quits it, a listener beyond loopback, the loaded models with their share of VRAM, whether $Alias exists and which $Superseded
# aliases remain, with what still uses each (Get-SupersededAliasNote). 'down' when Ollama does not answer. REST, process, listener and file reads only, so
# the Ollama app is never started, and a stale $App record stays for stop to drop.
function Get-StatusOllamaSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Alias,
        [string[]]$Superseded = @(),
        [hashtable]$Stamp = @{},
        [hashtable]$App
    )
    $section = Get-StatusSection -Key 'ollama' -Title 'Ollama'
    $data = $section.Data
    $add = { param([string]$Level, [string]$Text) $section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $stamped = if ($Stamp['Ollama'] -is [hashtable]) { [string]$Stamp['Ollama'].Version } else { '' }
    $data.url = $Url
    $data.version = $null
    $data.stampedVersion = $stamped
    $uri = [uri]$Url
    # As stop judges it: an app that runs as recorded, or that this window may not inspect, is local-ai's. It is this server's only when the record names
    # the port of $Url on this PC, as Test-OllamaAppRecord requires.
    $appState = $null
    $serves = $false
    if ($App) {
        try { $appState = Get-RecordedProcessState -Record $App } catch { $appState = 'other' }
        $serves = [int]$App.Port -eq $uri.Port -and (Test-LocalHostName -HostName $uri.Host)
    }
    $data.startedByLauncher = $serves -and @('match', 'unreadable') -contains $appState
    $data.appPid = $null
    $data.appStartedUtc = $null
    if ($data.startedByLauncher) {
        $data.appPid = [int]$App.Pid
        try {
            $data.appStartedUtc = ([datetime]::new([long]$App.StartTicks, [DateTimeKind]::Utc)).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            Write-Verbose "state.json records no start time of the Ollama app that a date can hold: $($_.Exception.Message)"
        }
    }
    $reason = 'it answered without a version'
    try {
        $answer = Invoke-RestMethod -Uri "$Url/api/version" -UseBasicParsing -TimeoutSec 5
        if ($answer.version) { $data.version = [string]$answer.version }
    } catch {
        $reason = $_.Exception.Message
    }
    if (-not $data.version) {
        & $add 'down' "Ollama does not answer at $Url/api/version ($reason). Start the Ollama app from the Start menu, wait for its tray icon, then run 'local-ai start'."
        return $section
    }
    $recorded = if ($stamped -and $stamped -ne $data.version) { "; install recorded $stamped" } else { '' }
    & $add 'fact' "Ollama $($data.version) answers at $Url$recorded."
    if ($data.startedByLauncher -and $appState -eq 'match') {
        & $add 'fact' "Started by local-ai (app PID $($data.appPid)); local-ai stop quits it."
    } elseif ($data.startedByLauncher) {
        & $add 'info' ("Started by local-ai (app PID $($data.appPid)), but this window may not inspect the app, as when it was started from an elevated " +
            "window; run 'local-ai stop' from an elevated window to quit it.")
    } else {
        if ($appState -eq 'other') {
            & $add 'info' ("state.json records an Ollama app local-ai started (PID $($App.Pid)), but it no longer runs, or was restarted by an update or by " +
                'you; local-ai stop drops that record.')
        } elseif ($appState) {
            # stop goes by the server state.json records, which Ollama.Url no longer names once it changed after the last start.
            $quit = if ($appState -eq 'unreadable') { "run 'local-ai stop' from an elevated window to quit it" } else { 'local-ai stop quits it' }
            & $add 'info' "state.json records an Ollama app local-ai started (PID $($App.Pid)) for port $($App.Port) on this PC, not for $Url; $quit."
        }
        & $add 'fact' 'Not started by local-ai; local-ai stop leaves it running.'
    }

    $data.listeners = @()
    if (Test-LocalHostName -HostName $uri.Host) {
        try {
            $data.listeners = @(Get-ListenerAddress -Port $uri.Port)
            $exposed = @(Select-ExposedAddress -Address $data.listeners)
            if ($exposed.Count -gt 0) {
                & $add 'degraded' ("Ollama IS OPEN TO THE NETWORK: port $($uri.Port) listens on $($exposed -join ', '), not only on 127.0.0.1 or ::1, so other " +
                    "devices that reach this PC can use it. Turn off 'Expose Ollama to the network' in the Ollama app's settings, make sure OLLAMA_HOST " +
                    'is unset or names 127.0.0.1, then quit and restart the Ollama app.')
            } elseif ($data.listeners.Count -gt 0) {
                & $add 'fact' "It listens on $($data.listeners -join ', ') port $($uri.Port) only."
            }
        } catch {
            & $add 'info' "The addresses Ollama listens on cannot be read: $($_.Exception.Message)"
        }
    } else {
        & $add 'info' "Ollama at $Url runs on another computer, so its bind address is not checked."
    }

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $loaded = New-Object System.Collections.Generic.List[object]
    $data.loaded = $loaded
    try {
        $ps = Invoke-RestMethod -Uri "$Url/api/ps" -UseBasicParsing -TimeoutSec 5
        foreach ($model in @($ps.models)) {
            if (-not $model) { continue }
            $size = [double]$model.size
            $vram = [double]$model.size_vram
            # Floored, so a model with any part on the CPU never shows 100.
            $percent = if ($size -gt 0) { [int][math]::Floor($vram * 100 / $size) } else { 0 }
            # Windows PowerShell 5.1 leaves the time as text, PowerShell 7 makes it a DateTime.
            $expires = if ($model.expires_at -is [datetime]) { $model.expires_at.ToString('o', $culture) } else { [string]$model.expires_at }
            $loaded.Add([ordered]@{ name = [string]$model.name; size = [long]$size; sizeVram = [long]$vram; gpuPercent = $percent
                    contextLength = $model.context_length; expiresAt = $expires })
            $until = $expires
            $parsed = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($expires, $culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                $until = $parsed.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss', $culture)
            }
            $bytes = Format-LocalAISize -Bytes $size
            & $add 'fact' "Loaded: $($model.name), $bytes, $percent percent of it in VRAM, context $($model.context_length), unloads at $until."
            if ($percent -lt 100) {
                & $add 'degraded' ("$($model.name) has only $percent percent of its $bytes in VRAM, so the rest runs on the CPU and answers come slowly. " +
                    "Close other programs that use the GPU, then unload it with 'ollama stop $($model.name)'; the next chat loads it again.")
            }
        }
        if ($loaded.Count -eq 0) { & $add 'fact' 'No model is loaded.' }
    } catch {
        & $add 'degraded' "Ollama does not list its loaded models at $Url/api/ps: $($_.Exception.Message)"
    }

    $data.aliasPresent = $null
    $data.superseded = @()
    try {
        $tags = Invoke-RestMethod -Uri "$Url/api/tags" -UseBasicParsing -TimeoutSec 5
        $names = @(foreach ($model in @($tags.models)) { if ($model) { [string]$model.name } })
        # Ollama lists a name given without a tag under its tag latest.
        $holds = { param([string]$Name) $names -contains $Name -or $names -contains "${Name}:latest" }
        if ($Alias) {
            $data.aliasPresent = [bool](& $holds $Alias)
            if ($data.aliasPresent) {
                & $add 'fact' "Ollama holds $Alias."
            } else {
                & $add 'degraded' "Ollama has no model '$Alias', so chat cannot answer. Run 'local-ai install' to create it."
            }
        }
        $data.superseded = @($Superseded | Where-Object { $_ -and (& $holds $_) })
        foreach ($name in $data.superseded) {
            $note = Get-SupersededAliasNote -Name $name -Alias $Alias
            $text = "Ollama still holds the superseded alias $name; 'local-ai update' offers to remove it."
            if ($note) { $text += " $note" }
            & $add 'info' $text
        }
    } catch {
        & $add 'degraded' "Ollama does not list its models at $Url/api/tags: $($_.Exception.Message)"
    }
    return $section
}

# Add to status section $Section (Data.services and Lines) what holds for $Service, an entry of the service table, and its state.json $Record: whether
# the recorded process runs, its PIDs and uptime, the addresses on its port and who holds it, the version Identity reports against the pin and, for
# ComfyUI, the device. A problem is 'down' for a required service, 'degraded' for an optional one and 'info' when -Disabled. Reads only.
function Add-StatusService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Section,
        [Parameter(Mandatory)][hashtable]$Service,
        [hashtable]$Record,
        [switch]$Disabled
    )
    $display = $Service.DisplayName
    $port = [int]$Service.Port
    $add = { param([string]$Level, [string]$Text) $Section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $problem = if ($Disabled) { 'info' } elseif ($Service.Required) { 'down' } else { 'degraded' }
    $item = [ordered]@{
        name = $Service.Name; displayName = $display; enabled = -not $Disabled; required = [bool]$Service.Required; port = $port; url = $Service.Url
        state = 'not running'; pid = $null; listenerPid = $null; uptimeSeconds = $null; listeners = @(); version = $null; error = $null
        pinSetting = $null; pin = $null; installed = $null; cuda = $null; outLog = $Service.OutLog; errLog = $Service.ErrLog
    }
    $Section.Data.services.Add($item)
    $pin = $Service.Pin
    if ($pin) {
        $item.pinSetting = $pin.Setting
        $item.pin = $pin.Version
        $item.installed = $pin.Stamped
    }
    if ($Record) {
        $found = Get-LiveRecord -Record $Record
        $item.state = if ($found.Match.Count -gt 0) { 'running' } elseif ($found.Unreadable.Count -gt 0) { 'unreadable' } else { 'stale record' }
        $item.pid = $Record.Pid
        if ($Record.Listener -is [hashtable]) { $item.listenerPid = $Record.Listener.Pid }
        if ($item.state -eq 'running' -and $Record.StartTicks) {
            $item.uptimeSeconds = [long](([DateTime]::UtcNow.Ticks - [long]$Record.StartTicks) / [TimeSpan]::TicksPerSecond)
        }
    }
    $live = $item.state -eq 'running' -or $item.state -eq 'unreadable'
    $addresses = @()
    if ($port -gt 0) {
        try {
            $addresses = @(Get-ListenerAddress -Port $port)
        } catch {
            $item.error = "the listeners on port $port cannot be read: $($_.Exception.Message)"
        }
    }
    $item.listeners = $addresses
    if ($addresses.Count -gt 0 -and $Service.Identity) {
        if ($Service.Name -eq 'Files' -and -not $Service.Key) {
            $item.error = "files.key cannot be read, so mcpo's answer is not checked"
        } else {
            try { $item.version = [string](& $Service.Identity $Service) } catch { $item.error = $_.Exception.Message }
        }
    }
    $ids = "PID $($item.pid)"
    if ($item.listenerPid -and $item.listenerPid -ne $item.pid) { $ids += ", listener PID $($item.listenerPid)" }

    # Every line leads with the service's name and a colon, as names such as File tools are plural.
    if ($Disabled) {
        if ($live) {
            & $add 'info' "${display}: still runs from an earlier start ($ids), although the settings now leave it out. 'local-ai stop' stops it."
        } else {
            & $add 'info' "${display}: state.json still records $ids, which has exited; 'local-ai stop' clears the record."
        }
    } elseif ($live -and $item.version) {
        $up = if ($null -ne $item.uptimeSeconds) { ", up $(Format-LocalAIDuration -Seconds $item.uptimeSeconds)" } else { '' }
        $pinNote = ''
        if ($pin) {
            $label = if ($pin.Label) { $pin.Label } else { $display }
            if ($pin.Running) {
                $pinNote = if ($item.version -eq $pin.Version) { ', the pinned version' } else { ", but $($pin.Setting) pins $($pin.Version)" }
            } elseif ($pin.Stamped -eq $pin.Version) {
                $pinNote = "; install recorded $label $($pin.Stamped), as $($pin.Setting) pins"
            } else {
                $pinNote = "; install recorded $label $($pin.Stamped), but $($pin.Setting) pins $($pin.Version)"
            }
        }
        & $add 'fact' "${display}: $($item.version) runs at $($Service.Url) ($ids$up), listening on $($addresses -join ', ')$pinNote."
        # A pin that differs from install-stamp.json is the pins section's to report.
        if ($pin -and $pin.Running -and $item.version -ne $pin.Version -and $pin.Stamped -eq $pin.Version) {
            & $add 'degraded' "${display}: $($item.version) runs, but install has put in $($pin.Version), the pin. Run 'local-ai stop', then 'local-ai start', so that one runs."
        }
        if ($Service.Name -eq 'ComfyUI') {
            $deviceWarnings = @()
            $item.cuda = [bool](Test-ComfyUIDevice -Url $Service.Url -WarningAction SilentlyContinue -WarningVariable deviceWarnings)
            if (-not $item.cuda) { & $add 'degraded' (@($deviceWarnings | ForEach-Object { [string]$_.Message }) -join ' ') }
        }
    } elseif ($live) {
        if ($addresses.Count -eq 0) {
            & $add $problem ("${display}: runs ($ids), but nothing listens on port ${port}: it may still be starting, as a first start takes a few minutes, " +
                "or it failed. Its logs are $($Service.ErrLog) and $($Service.OutLog).")
        } elseif (-not $Service.Identity) {
            & $add 'fact' "${display}: runs at $($Service.Url) ($ids), listening on $($addresses -join ', '); without the settings its answer is not checked."
        } else {
            & $add $problem "${display}: runs ($ids), but does not answer at $($Service.Url) as ${display}: $($item.error)"
        }
    } else {
        $text = "${display}: not running"
        if ($item.state -eq 'stale record') { $text += " (state.json still records $ids, which has exited)" }
        $text += '.'
        if ($addresses.Count -gt 0) {
            $owner = $null
            try { $owner = Get-PortOwner -Port $port } catch { $owner = $null }
            $who = if ($owner) { "$($owner.Name) (PID $($owner.Id), $($owner.Path))" } else { 'another program' }
            $text += " Port $port is held by $who, which this launcher did not start"
            if ($item.version) { $text += ", and it answers as $display $($item.version)." } else { $text += '.' }
            # start refuses a port held by a program it did not start, and stop stops only what state.json records.
            $text += " Close that program, or set Ports.$($Service.Name) in settings.psd1, then run 'local-ai start'."
        } else {
            $text += " Run 'local-ai start'."
        }
        & $add $problem $text
    }
    if ($item.state -eq 'unreadable' -and -not $Disabled) {
        & $add 'degraded' ("${display}: runs ($ids), but this window may not inspect it, as when it was started from an elevated window, so 'local-ai stop' " +
            'must run in an elevated window too.')
    }
    $exposed = @(Select-ExposedAddress -Address $addresses)
    if ($exposed.Count -gt 0) {
        & $add 'degraded' ("${display}: IS OPEN TO THE NETWORK: port $port listens on $($exposed -join ', '), not only on 127.0.0.1 or ::1, so other devices " +
            "that reach this PC can use it. The launcher starts it on 127.0.0.1; run 'local-ai stop' and check what else uses port $port.")
    }
}

# Return the status section for the services. With $Settings: each entry of the table Get-LocalAIServicePlan builds from $Stamp, Open WebUI first, a line
# for each the settings turn off, and as -Disabled any other service $State records. Without settings, or when the table cannot be built: the services
# $State records, judged by what their records hold, with Open WebUI required even when it has no record. Reads only.
function Get-StatusServiceSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$OllamaUrl
    )
    $section = Get-StatusSection -Key 'services' -Title 'Services'
    $section.Data.services = New-Object System.Collections.Generic.List[object]
    $add = { param([string]$Level, [string]$Text) $section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $records = $State['Services']
    if ($records -isnot [hashtable]) { $records = @{} }
    $listed = @{}
    $plan = $null
    if ($Settings) {
        try {
            $plan = @(Get-LocalAIServicePlan -Settings $Settings -Paths $Paths -Stamp $Stamp -OllamaUrl $OllamaUrl)
        } catch {
            & $add 'degraded' "The service table cannot be built from the settings, so the services are judged by their state.json records: $($_.Exception.Message)"
        }
    }
    if ($null -ne $plan) {
        foreach ($service in @($plan | Where-Object { $_.Required }) + @($plan | Where-Object { -not $_.Required })) {
            $record = if ($records[$service.Name] -is [hashtable]) { $records[$service.Name] } else { $null }
            Add-StatusService -Section $section -Service $service -Record $record
            $listed[$service.Name] = $true
        }
        if (-not $Settings.Images.Enabled) {
            & $add 'fact' 'ComfyUI and the image gate are off: Images.Enabled is $false.'
        } elseif (-not $Settings.Images.UnloadChat) {
            & $add 'fact' 'The image gate is off: Images.UnloadChat is $false, so images go to ComfyUI directly.'
        } elseif (-not $listed['ImageGate']) {
            & $add 'fact' "The image gate is off: Ollama at $OllamaUrl is not on a loopback address, so images go to ComfyUI directly."
        }
        if (-not $Settings.Files.Root) { & $add 'fact' 'The file tools are off: Files.Root is empty.' }
    }
    $known = @{ OpenWebUI = 'Open WebUI'; ComfyUI = 'ComfyUI'; ImageGate = 'Image gate'; Files = 'File tools' }
    foreach ($name in @($records.Keys | Where-Object { -not $listed[$_] } | Sort-Object { $_ -ne 'OpenWebUI' }, { $_ })) {
        $record = $records[$name]
        if ($record -isnot [hashtable]) { continue }
        $port = [int]$record.Port
        # Without the settings only these two can be told by their answers alone.
        $identity = $null
        if ($name -eq 'OpenWebUI') { $identity = { param([hashtable]$Service) Get-OpenWebUIVersion -Url $Service.Url } }
        if ($name -eq 'ComfyUI') { $identity = { param([hashtable]$Service) Get-ComfyUIVersion -Url $Service.Url } }
        $service = @{
            Name = $name; DisplayName = $(if ($known[$name]) { $known[$name] } else { $name }); Port = $port; Url = "http://127.0.0.1:$port"
            OutLog = $record.OutLog; ErrLog = $record.ErrLog; Required = ($null -eq $plan -and $name -eq 'OpenWebUI'); Pin = $null; Identity = $identity
        }
        Add-StatusService -Section $section -Service $service -Record $record -Disabled:($null -ne $plan)
        $listed[$name] = $true
    }
    if ($null -eq $plan -and -not $listed['OpenWebUI']) {
        $section.Data.services.Add([ordered]@{ name = 'OpenWebUI'; displayName = 'Open WebUI'; enabled = $true; required = $true; state = 'not running' })
        & $add 'down' "Open WebUI: not running, as state.json records no start of it. Run 'local-ai start'."
    }
    return $section
}

# Return the status section for the GPU, from the driver version and memory use nvidia-smi reports, and for OLLAMA_KV_CACHE_TYPE in this process and
# in the User environment. 'degraded' when nvidia-smi is missing or fails. Runs nvidia-smi only.
function Get-StatusSystemSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $section = Get-StatusSection -Key 'system' -Title 'GPU and Ollama environment'
    $add = { param([string]$Level, [string]$Text) $section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $gpus = New-Object System.Collections.Generic.List[object]
    $section.Data.gpus = $gpus
    $said = New-Object System.Collections.Generic.List[string]
    try {
        $null = Invoke-Native -FilePath 'nvidia-smi' -ArgumentList '--query-gpu=driver_version,memory.used,memory.total', '--format=csv,noheader,nounits' -Capture $said
        # One line per GPU, such as '555.85, 512, 8192' (MiB).
        $rows = @($said | Where-Object { $_ -match '^\s*[^,\s]+\s*,\s*\d+\s*,\s*\d+\s*\z' })
        if ($rows.Count -eq 0) { throw "it printed '$(@($said) -join ' ')'" }
        foreach ($row in $rows) {
            $driver, $used, $total = @($row.Trim() -split '\s*,\s*')
            $gpus.Add([ordered]@{ driver = $driver; memoryUsedMiB = [int]$used; memoryTotalMiB = [int]$total })
            & $add 'fact' "NVIDIA driver $driver; $used of $total MiB of VRAM in use."
        }
    } catch {
        & $add 'degraded' ("nvidia-smi cannot report the GPU ($($_.Exception.Message)), so Ollama and ComfyUI may run on the CPU. Install or repair the " +
            'NVIDIA driver, which brings nvidia-smi.')
    }
    $process = [Environment]::GetEnvironmentVariable('OLLAMA_KV_CACHE_TYPE', 'Process')
    $user = [Environment]::GetEnvironmentVariable('OLLAMA_KV_CACHE_TYPE', 'User')
    $section.Data.kvCacheType = [ordered]@{ process = $process; user = $user }
    $shown = { param([string]$Value) if ($Value) { "'$Value'" } else { 'unset' } }
    & $add 'fact' ("OLLAMA_KV_CACHE_TYPE is $(& $shown $process) in this window and $(& $shown $user) in the User environment, which programs " +
        'started later inherit; unset means f16.')
    return $section
}

# Return the status section for the file tools' folder: off when Files.Root is empty, else whether Test-FilesRoot lets start serve it, with its
# reason as 'degraded' when not. Test-FilesRoot walks the folder, reading only.
function Get-StatusFilesSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [string]$RepoRoot
    )
    $section = Get-StatusSection -Key 'files' -Title 'File tools folder'
    $add = { param([string]$Level, [string]$Text) $section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $root = [string]$Settings.Files.Root
    $section.Data.root = $root
    $section.Data.served = $false
    $section.Data.reason = $null
    if (-not $root) {
        & $add 'fact' 'The file tools are off: Files.Root is empty.'
        return $section
    }
    $toolDir = if ($Stamp['Files'] -is [hashtable]) { [string]$Stamp['Files'].ToolDir } else { '' }
    $rootWarnings = @()
    $notes = @()
    try {
        $said = @(Test-FilesRoot -Settings $Settings -Paths $Paths -RepoRoot $RepoRoot -ToolDir $toolDir -WarningAction SilentlyContinue -WarningVariable rootWarnings 6>&1)
        $section.Data.served = @($said | Where-Object { $_ -is [bool] }) -contains $true
        $notes = @($said | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
    } catch {
        $rootWarnings = @("Files.Root '$root' cannot be checked: $($_.Exception.Message)")
    }
    if ($section.Data.served) {
        & $add 'fact' "Files.Root $root passes the checks start runs, so start serves it read-only."
    } else {
        $section.Data.reason = @($rootWarnings | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $_.Message } else { [string]$_ } }) -join ' '
        & $add 'degraded' $section.Data.reason
    }
    foreach ($note in $notes) { & $add 'info' $note }
    return $section
}

# Return the status section that compares what install-stamp.json $Stamp records with the pins in $Settings: Open WebUI's version and Python, ComfyUI's
# commit, origin and venv (Get-ComfyUIPinDrift), mcpo, the files server, and the model. Each difference is 'degraded' and names 'local-ai update'; a
# part the settings turn on that install has not recorded names 'local-ai install'. Reads files and runs 'git config --get' only.
function Get-StatusPinSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $section = Get-StatusSection -Key 'pins' -Title 'Pins'
    $add = { param([string]$Level, [string]$Text) $section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $drift = New-Object System.Collections.Generic.List[object]
    $section.Data.drift = $drift
    $section.Data.missing = New-Object System.Collections.Generic.List[string]
    # Record one difference: the part, the setting that pins it, the pin and what install recorded.
    $differ = {
        param([string]$Component, [string]$Setting, [string]$Pinned, [string]$Installed, [string]$Text)
        $drift.Add([ordered]@{ component = $Component; setting = $Setting; pinned = $Pinned; installed = $Installed })
        & $add 'degraded' "$Text Run 'local-ai update'."
    }
    $missing = {
        param([string]$What)
        $section.Data.missing.Add($What)
        & $add 'degraded' "install-stamp.json records no $What. Run 'local-ai install'."
    }

    $web = $Stamp['OpenWebUI']
    $pins = $Settings.OpenWebUI
    if ($web -isnot [hashtable]) {
        & $missing 'Open WebUI install'
    } else {
        if ([string]$web.Version -ne $pins.Version) {
            & $differ 'Open WebUI' 'OpenWebUI.Version' $pins.Version $web.Version "Open WebUI $($web.Version) is installed, but OpenWebUI.Version pins $($pins.Version)."
        }
        # uv reports the patch version, such as 3.12.16, and the setting names the minor.
        $minor = if ([string]$web.Python -match '^(\d+\.\d+)') { $Matches[1] } else { [string]$web.Python }
        if ($minor -ne $pins.Python) {
            & $differ 'Open WebUI' 'OpenWebUI.Python' $pins.Python $web.Python "Open WebUI runs on Python $($web.Python), but OpenWebUI.Python pins $($pins.Python)."
        }
    }
    if ($Settings.Images.Enabled) {
        $comfy = $Stamp['ComfyUI']
        # uninstall keeps only Dir and Cloned of an entry whose venv it removed.
        if ($comfy -isnot [hashtable] -or -not $comfy.Python) {
            & $missing 'ComfyUI install, which Images.Enabled asks for'
        } elseif ($comfy.Commit -ne $Settings.ComfyUI.Commit) {
            & $differ 'ComfyUI' 'ComfyUI.Commit' $Settings.ComfyUI.Commit $comfy.Commit ("ComfyUI in $($comfy.Dir) is at commit $($comfy.Commit), but " +
                "ComfyUI.Commit pins $($Settings.ComfyUI.Commit) ($($Settings.ComfyUI.Ref)).")
        } else {
            # At the pinned commit, update still changes an origin other than ComfyUI.Repo and a venv set up for other requirements.
            $dir = [string]$comfy.Dir
            try {
                $git = [IO.Path]::Combine($dir, '.git')
                if (-not ([IO.Directory]::Exists($git) -or [IO.File]::Exists($git))) { throw "$dir is no git checkout" }
                $remote = Invoke-GitCommand -Dir $dir -ArgumentList 'config', '--get', 'remote.origin.url' -SuccessCode 0, 1
                $origin = if ($remote.Code -eq 0 -and $remote.Lines.Count -gt 0) { $remote.Lines[-1].Trim() } else { '' }
                foreach ($change in @(Get-ComfyUIPinDrift -Settings $Settings -Dir $dir -Origin $origin -RepoRoot $RepoRoot)) {
                    & $differ 'ComfyUI' $change.Setting $change.Pinned $change.Installed "ComfyUI in ${dir}: $($change.Text)."
                }
            } catch {
                & $add 'info' "ComfyUI's origin and venv in $dir cannot be checked: $($_.Exception.Message)"
            }
        }
    }
    if ($Settings.Files.Root) {
        $files = $Stamp['Files']
        if ($files -isnot [hashtable]) {
            & $missing 'file tools install, which Files.Root asks for'
        } else {
            foreach ($change in @(Get-McpoPinChange -Settings $Settings -Recorded $files)) {
                & $differ 'mcpo' $change.Setting $change.Pinned $change.Installed ("mcpo was installed with $($change.Setting) '$($change.Installed)', but " +
                    "settings.psd1 pins '$($change.Pinned)'.")
            }
            if ($files.ServerVersion -ne $Settings.Files.ServerVersion) {
                & $differ 'files server' 'Files.ServerVersion' $Settings.Files.ServerVersion $files.ServerVersion ("The files server $($files.ServerVersion) is " +
                    "installed, but Files.ServerVersion pins $($Settings.Files.ServerVersion).")
            }
            $lock = Join-Path (Resolve-RepoPath -Path $Settings.Files.ServerPackage -RepoRoot $RepoRoot) 'package-lock.json'
            $lockSha = Get-LocalAIFileSha256 -Path $lock
            if ($lockSha -ne $files.LockSha256) {
                & $differ 'files server' 'Files.ServerPackage' $lockSha $files.LockSha256 "The files server was installed from another package-lock.json than $lock."
            }
        }
    }
    $model = $Stamp['Model']
    $pins = $Settings.Model
    if ($model -isnot [hashtable]) {
        & $missing 'chat model'
    } else {
        if ($model.Alias -ne $pins.Alias) {
            & $differ 'model' 'Model.Alias' $pins.Alias $model.Alias "install created the alias $($model.Alias), but Model.Alias is $($pins.Alias)."
        }
        if ($pins.Sha256 -and $model.BaseDigest -ne $pins.Sha256) {
            & $differ 'model' 'Model.Sha256' $pins.Sha256 $model.BaseDigest "The weights install used have SHA-256 $($model.BaseDigest), but Model.Sha256 pins $($pins.Sha256)."
        }
        if ($pins.ProjectorSha256 -and $model.ProjectorDigest -ne $pins.ProjectorSha256) {
            & $differ 'model' 'Model.ProjectorSha256' $pins.ProjectorSha256 $model.ProjectorDigest ("The vision projector install used has SHA-256 " +
                "$($model.ProjectorDigest), but Model.ProjectorSha256 pins $($pins.ProjectorSha256).")
        }
        $modelfile = Resolve-ChatModelfile -Settings $Settings -Paths $Paths -RepoRoot $RepoRoot
        $modelfileSha = Get-LocalAIFileSha256 -Path $modelfile
        if ($modelfileSha -ne $model.ModelfileSha256) {
            & $differ 'model' 'Model.Modelfile' $modelfileSha $model.ModelfileSha256 "$($model.Alias) was created from another Modelfile than $modelfile."
        }
    }
    if ($section.Lines.Count -eq 0) { & $add 'fact' 'Everything install-stamp.json records matches its pin.' }
    return $section
}

# Return the status section of doctor checks, which never change the exit code: the PowerShell version, Group Policy execution policies, Zone.Identifier
# marks in $RepoRoot, and the page file, with advice while $Settings has Images.UnloadChat on. Reads only.
function Get-StatusDoctorSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Settings,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $section = Get-StatusSection -Key 'doctor' -Title 'Doctor checks'
    $data = $section.Data
    $add = { param([string]$Level, [string]$Text) $section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $data.powerShell = [string]$PSVersionTable.PSVersion
    & $add 'fact' "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))."

    try {
        $policies = @(Get-ExecutionPolicy -List)
        $data.executionPolicy = [ordered]@{}
        foreach ($policy in $policies) { $data.executionPolicy[[string]$policy.Scope] = [string]$policy.ExecutionPolicy }
        $set = @($policies | Where-Object { [string]$_.ExecutionPolicy -ne 'Undefined' })
        $shown = if ($set.Count -gt 0) { @($set | ForEach-Object { "$($_.Scope) $($_.ExecutionPolicy)" }) -join ', ' } else { 'Undefined in every scope' }
        & $add 'fact' "Execution policy: $shown; local-ai.cmd asks for RemoteSigned for its own run."
        foreach ($policy in @($set | Where-Object { @('MachinePolicy', 'UserPolicy') -contains [string]$_.Scope })) {
            & $add 'advice' ("Group Policy sets the execution policy $($policy.ExecutionPolicy) for $($policy.Scope), which overrides the RemoteSigned that " +
                "local-ai.cmd asks for, so the launcher runs only while that policy lets its unsigned scripts run. If it stops starting, ask whoever manages this PC's policies.")
        }
    } catch {
        & $add 'info' "The execution policies cannot be read: $($_.Exception.Message)"
    }

    # A marked src\local-ai.ps1 or LocalAI.psm1 stops status itself from loading, so this can find marks only on the other files.
    $marked = @(Get-ZoneMarkedFile -Root $RepoRoot)
    $data.zoneMarked = $marked
    if ($marked.Count -gt 0) {
        $names = @($marked | Select-Object -First 5 | ForEach-Object { $_.Substring($RepoRoot.TrimEnd('\').Length + 1) })
        $more = if ($marked.Count -gt 5) { " and $($marked.Count - 5) more" } else { '' }
        & $add 'advice' ("$($marked.Count) launcher file(s) carry the Zone.Identifier mark Windows gives downloaded files, which RemoteSigned refuses to run: " +
            "$($names -join ', ')$more. Unblock them with: Get-ChildItem -LiteralPath '$RepoRoot' -Recurse -File | Unblock-File")
    } else {
        & $add 'fact' 'No launcher script carries the Zone.Identifier mark of a download.'
    }

    try {
        $page = Get-PageFileStatus
        $data.pageFile = [ordered]@{ automatic = $page.Automatic; settings = @($page.Settings); files = @($page.Files); commitLimitBytes = $page.CommitLimitBytes }
        $managed = $page.Automatic -or @($page.Settings | Where-Object { $_.InitialMB -eq 0 -and $_.MaximumMB -eq 0 }).Count -gt 0
        $fixedMB = [long](@($page.Settings | ForEach-Object { [long]$_.InitialMB }) | Measure-Object -Sum).Sum
        if ($page.Automatic) {
            $how = 'system-managed'
        } elseif ($page.Settings.Count -eq 0) {
            $how = 'none set'
        } else {
            $how = @($page.Settings | ForEach-Object {
                    if ($_.InitialMB -eq 0 -and $_.MaximumMB -eq 0) { "$($_.Name) system-managed" } else { "$($_.Name) $($_.InitialMB) to $($_.MaximumMB) MB" }
                }) -join ', '
        }
        $now = if ($page.Files.Count -gt 0) { @($page.Files | ForEach-Object { "$($_.Name) $($_.CurrentMB) MB" }) -join ', ' } else { 'none in use' }
        & $add 'fact' "Page file: $how; now $now. Commit limit $(Format-LocalAISize -Bytes $page.CommitLimitBytes)."
        # Reloading local-chat after an image commits about 11 GB. With a system-managed page file that Windows has shrunk, such a reload can fail
        # once the commit limit runs out, soonest on a PC with little RAM. A fixed page file of 20 GB or more leaves room for it.
        if ($Settings -and $Settings.Images.Enabled -and $Settings.Images.UnloadChat -and ($managed -or $fixedMB -lt 20480)) {
            & $add 'advice' ("Images.UnloadChat makes Ollama reload $($Settings.Model.Alias) after every image, which commits about 11 GB of memory; with a " +
                "system-managed page file that Windows has shrunk, such a reload can fail ('CUDA error: shared object initialization failed'). Set a fixed " +
                'page file of about 20 GB or more under System Properties > Advanced > Performance Settings > Advanced > Virtual memory > Change; the ' +
                'launcher never changes it.')
        }
    } catch {
        & $add 'info' "The page file settings cannot be read: $($_.Exception.Message)"
    }
    return $section
}

# Return the status section for the logs: the log files of each entry in $Services (the services section's data), the newest launcher transcript in
# Paths.Logs other than a status one with its last 'Error: ' line, the 'Session closed during call' lines in mcpo's files.err.log, and *.part files
# left below ComfyUI.Dir\models. Reads files only.
function Get-StatusLogSection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [AllowEmptyCollection()][object[]]$Services = @()
    )
    $section = Get-StatusSection -Key 'logs' -Title 'Logs'
    $data = $section.Data
    $add = { param([string]$Level, [string]$Text) $section.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $data.folder = $Paths.Logs
    foreach ($service in $Services) {
        $files = @(@($service['outLog'], $service['errLog']) | Where-Object { $_ })
        if ($files.Count -gt 0) { & $add 'fact' "$($service['displayName']): $($files -join ', ')" }
    }

    $data.transcript = $null
    $data.lastError = $null
    $transcripts = @()
    if ([IO.Directory]::Exists($Paths.Logs)) {
        # A status run's own transcript is the newest one and tells nothing about the others.
        $transcripts = @(Get-ChildItem -LiteralPath $Paths.Logs -Filter 'launcher-*.log' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '*-status.log' } | Sort-Object LastWriteTimeUtc -Descending)
    }
    if ($transcripts.Count -gt 0) {
        $newest = $transcripts[0]
        $data.transcript = [string]$newest.FullName
        $written = $newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        & $add 'fact' "Newest launcher log: $($newest.FullName), written $written."
        try {
            $errors = @(([string](Read-SharedText -Path $newest.FullName)) -split '\r?\n' | Where-Object { $_ -like 'Error: *' })
            if ($errors.Count -gt 0) {
                $data.lastError = $errors[-1]
                & $add 'info' "Its last error line: $($errors[-1])"
            }
        } catch {
            & $add 'info' "It cannot be read: $($_.Exception.Message)"
        }
    } else {
        & $add 'fact' "$($Paths.Logs) holds no launcher log but those of status."
    }

    $mcpoLog = Join-Path $Paths.Logs 'files.err.log'
    $data.sessionClosed = $null
    if ([IO.File]::Exists($mcpoLog)) {
        try {
            $data.sessionClosed = [regex]::Matches([string](Read-SharedText -Path $mcpoLog), 'Session closed during call').Count
            & $add 'fact' "mcpo's error log $mcpoLog holds $($data.sessionClosed) 'Session closed during call' line(s)."
        } catch {
            & $add 'info' "mcpo's error log $mcpoLog cannot be read: $($_.Exception.Message)"
        }
    }

    $parts = @()
    $comfyDir = if ($Settings) { [string]$Settings.ComfyUI.Dir } elseif ($Stamp['ComfyUI'] -is [hashtable]) { [string]$Stamp['ComfyUI'].Dir } else { '' }
    # Combine, unlike Join-Path, does not refuse a drive this PC does not have now.
    if ($comfyDir) { $parts = @(Find-LocalAIFile -Root ([IO.Path]::Combine($comfyDir, 'models')) -Extension '.part') }
    $data.partFiles = @($parts | ForEach-Object { [ordered]@{ path = [string]$_.FullName; bytes = [long]$_.Length } })
    if ($parts.Count -gt 0) {
        $listedParts = @($parts | ForEach-Object { "$($_.FullName) ($(Format-LocalAISize -Bytes $_.Length))" }) -join ', '
        & $add 'advice' "Partial downloads are left over: $listedParts. Delete them once no download runs, to free the space."
    }
    return $section
}

# Return the status report for the launcher context $Context as @{ Sections; ExitCode; Health }: ExitCode 1 (Health 'down') when a line is 'down', else 2
# ('degraded') when one is 'degraded', else 0 ('healthy'). Works without settings from state.json and install-stamp.json; starts, stops, installs and
# writes nothing.
function Get-LocalAIStatusReport {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $settings = $Context.Settings
    $paths = $Context.Paths
    $repoRoot = [string]$Context.RepoRoot
    $launcher = Get-StatusSection -Key 'launcher' -Title 'Launcher'
    $add = { param([string]$Level, [string]$Text) $launcher.Lines.Add([ordered]@{ level = $Level; text = $Text }) }
    $launcher.Data.repository = $repoRoot
    $launcher.Data.root = $paths.Root
    # A release names its version in VERSION; a git checkout before the first release has none.
    $launcher.Data.version = Get-LocalAIVersion -RepoRoot $repoRoot
    $launcher.Data.settingsLoaded = $null -ne $settings
    $launcher.Data.settingsError = $Context.SettingsError
    if ($launcher.Data.version) {
        & $add 'fact' "Launcher $($launcher.Data.version)."
    } else {
        & $add 'info' "No VERSION file in $repoRoot names the launcher's version, as in a git checkout before the first release."
    }
    & $add 'fact' "The launcher in $repoRoot keeps its state in $($paths.Root)."
    $launcher.Data.otherRunActive = [bool]$Context.LockHeld
    if ($Context.LockHeld) {
        & $add 'info' 'Another launcher run (install, start, stop, update, uninstall or shortcuts) is in progress, so what follows may change shortly.'
    }
    # Invoke-LocalAI probed for the redirection before status ran (Get-AppDataRedirection); every other verb refuses on either finding.
    $redirection = $Context.Redirection
    $launcher.Data.appDataRedirection = $null
    if ($redirection) {
        $launcher.Data.appDataRedirection = [ordered]@{ package = [string]$redirection.Package; store = [string]$redirection.Store }
        & $add 'degraded' ("$(Format-AppDataRedirection -Redirection $redirection), where other windows never see them. status runs here, but every other " +
            "verb refuses to, so that the launcher's files never land there. Run those, such as 'local-ai start', from a console window or Windows Terminal; " +
            "the Start menu shortcuts 'Start Local AI', 'Stop Local AI' and 'Update Local AI' work too.")
    }
    $folders = @($paths.Root)
    if ($settings) { $folders += [string]$settings.OpenWebUI.DataDir }
    $copies = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $folders) {
        foreach ($copy in @(Find-LocalAIPrivateCopy -Path $folder -LocalAppData ([string]$Context.LocalAppData) -AppData ([string]$Context.AppData))) {
            $copies.Add($copy)
            $refused = if ($folder -eq $paths.Root) { ' Until then every verb but status refuses to run.' } else { '' }
            & $add 'degraded' ("$copy is a private copy of $folder that Windows made for a window inside an app package, and a window inside that package " +
                "sees it instead of the real folder. Move it aside, out of %LOCALAPPDATA%\Packages, once you have checked whether it holds anything the " +
                "real folder lacks.$refused")
        }
    }
    $launcher.Data.privateCopies = $copies.ToArray()
    if (-not $settings) {
        & $add 'degraded' ("The settings do not load, so status reports only what state.json and install-stamp.json record, and every verb but stop, status " +
            "and uninstall refuses to run: $($Context.SettingsError)")
    }
    $state = @{}
    try { $state = Read-LocalAIState -Path $paths.State } catch { & $add 'degraded' "$($_.Exception.Message) status reads it as empty." }
    $stamp = @{}
    try { $stamp = Read-LocalAIState -Path $paths.InstallStamp } catch { & $add 'degraded' "$($_.Exception.Message) status reads it as empty." }
    # The launcher's own releases, from what update and start recorded; status never asks GitHub.
    $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
    $defaultRepo = ''
    try { $defaultRepo = [string](Import-LocalAIDataFile -Path (Join-Path $repoRoot 'config\defaults.psd1')).Launcher.Repo } catch { $defaultRepo = '' }
    $release = Get-LauncherStatus -RepoRoot $repoRoot -InstallRoot $installRoot -State $state -Settings $settings -DefaultRepo $defaultRepo
    foreach ($key in $release.Data.Keys) { $launcher.Data[$key] = $release.Data[$key] }
    foreach ($line in $release.Lines) { $launcher.Lines.Add($line) }
    # start records the server and the alias it used, and the Ollama app it started, for stop.
    $recorded = if ($state['Ollama'] -is [hashtable]) { $state['Ollama'] } else { @{} }
    if ($settings) {
        $url = Resolve-OllamaUrl -Setting $settings.Ollama.Url
        $alias = [string]$settings.Model.Alias
        $superseded = @($settings.Model.SupersededAliases)
    } else {
        $url = if ($recorded.Url) { [string]$recorded.Url } else { Resolve-OllamaUrl -Setting '' }
        $alias = if ($recorded.Alias) { [string]$recorded.Alias } elseif ($stamp['Model'] -is [hashtable]) { [string]$stamp['Model'].Alias } else { '' }
        $superseded = @()
    }
    $sections = New-Object System.Collections.Generic.List[hashtable]
    $sections.Add($launcher)
    $app = if ($recorded.App -is [hashtable]) { $recorded.App } else { $null }
    $sections.Add((Get-StatusOllamaSection -Url $url -Alias $alias -Superseded $superseded -Stamp $stamp -App $app))
    $services = Get-StatusServiceSection -Settings $settings -Paths $paths -State $state -Stamp $stamp -OllamaUrl $url
    $sections.Add($services)
    $sections.Add((Get-StatusSystemSection))
    if ($settings) {
        $sections.Add((Get-StatusFilesSection -Settings $settings -Paths $paths -Stamp $stamp -RepoRoot $repoRoot))
        $sections.Add((Get-StatusPinSection -Settings $settings -Paths $paths -Stamp $stamp -RepoRoot $repoRoot))
    }
    $sections.Add((Get-StatusDoctorSection -Settings $settings -RepoRoot $repoRoot))
    # ToArray, since Windows PowerShell 5.1's @() throws 'Argument types do not match' on a list holding one table.
    $sections.Add((Get-StatusLogSection -Settings $settings -Paths $paths -Stamp $stamp -Services $services.Data.services.ToArray()))
    $levels = @(foreach ($section in $sections) { foreach ($line in $section.Lines) { $line.level } })
    $code = if ($levels -contains 'down') { 1 } elseif ($levels -contains 'degraded') { 2 } else { 0 }
    $health = if ($code -eq 1) { 'down' } elseif ($code -eq 2) { 'degraded' } else { 'healthy' }
    return @{ Sections = $sections; ExitCode = $code; Health = $health }
}

# Print the status $Report from Get-LocalAIStatusReport: each section's title and lines, 'degraded' ones as warnings, 'down' ones in red and 'advice' ones
# in cyan, then one closing line for its exit code. Returns nothing.
function Write-LocalAIStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Report
    )
    $warnings = 0
    foreach ($section in $Report.Sections) {
        if ($section.Lines.Count -eq 0) { continue }
        Write-Host ''
        Write-Host "== $($section.Title) =="
        foreach ($line in $section.Lines) {
            switch ($line.level) {
                'degraded' {
                    Write-Warning $line.text
                    $warnings++
                }
                'down' { Write-Host "  $($line.text)" -ForegroundColor Red }
                'advice' { Write-Host "  Advice: $($line.text)" -ForegroundColor Cyan }
                default { Write-Host "  $($line.text)" }
            }
        }
    }
    Write-Host ''
    if ($Report.ExitCode -eq 0) {
        Write-Host 'Status: everything the settings turn on runs and is healthy.' -ForegroundColor Green
    } elseif ($Report.ExitCode -eq 2) {
        Write-Host "Status: degraded, with $warnings warning(s); see above." -ForegroundColor Yellow
    } else {
        Write-Host 'Status: Ollama or Open WebUI is down; see above.' -ForegroundColor Red
    }
}

# The status verb, read-only: Get-LocalAIStatusReport printed by Write-LocalAIStatus, or with -Json one line of compact JSON on the host and nothing else,
# holding each section's facts and lines (with their levels) and the exit code. Returns 0 when everything the settings turn on runs and is healthy, 1 when
# Ollama or Open WebUI is down or not running, else 2 when anything is degraded; advice never changes it.
function Get-LocalAIStatus {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $report = Get-LocalAIStatusReport -Context $Context
    if ($Context.Json) {
        $document = [ordered]@{ verb = 'status'; exitCode = $report.ExitCode; health = $report.Health; settingsError = $Context.SettingsError }
        foreach ($section in $report.Sections) {
            $entry = [ordered]@{}
            foreach ($key in $section.Data.Keys) { $entry[$key] = $section.Data[$key] }
            $entry['lines'] = $section.Lines.ToArray()
            $document[$section.Key] = $entry
        }
        Write-Host (ConvertTo-LocalAIJsonText -Value $document)
    } else {
        Write-LocalAIStatus -Report $report
    }
    return $report.ExitCode
}

# Return the launcher's four Start menu shortcuts as @{ Name; Arguments; Description } in the order Start, Stop, Status, Update; the descriptions of the
# first three name the services Get-LocalAIServicePlan lists for $Settings and the stamp in $Paths, Open WebUI first.
function Get-LocalAIShortcutSpec {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths
    )
    $plan = @()
    try {
        $stamp = Read-LocalAIState -Path $Paths.InstallStamp
        $plan = @(Get-LocalAIServicePlan -Settings $Settings -Paths $Paths -Stamp $stamp -OllamaUrl (Resolve-OllamaUrl -Setting $Settings.Ollama.Url))
    } catch {
        Write-Verbose "The descriptions name Open WebUI alone: $($_.Exception.Message)"
    }
    # 'Image gate' and 'File tools' read as 'the image gate' and 'the file tools' within a sentence; a name such as Open WebUI keeps its case.
    $names = @(foreach ($service in @($plan | Where-Object { $_.Required }) + @($plan | Where-Object { -not $_.Required })) {
            if ($service.DisplayName -cmatch '^[A-Z][a-z]+ [a-z]+\z') { 'the ' + $service.DisplayName.ToLowerInvariant() } else { $service.DisplayName }
        })
    if ($names.Count -eq 0) { $names = @('Open WebUI') }
    # $Items joined as 'a', 'a and b' or 'a, b and c'.
    $join = { param([string[]]$Items) if ($Items.Count -gt 1) { ($Items[0..($Items.Count - 2)] -join ', ') + ' and ' + $Items[-1] } else { $Items -join '' } }
    $alias = $Settings.Model.Alias
    @{ Name = 'Start Local AI.lnk'; Arguments = 'start'; Description = "Start $(& $join $names), with $alias in Ollama" }
    @{ Name = 'Stop Local AI.lnk'; Arguments = 'stop'; Description = "Stop $(& $join $names), unload $alias from Ollama, and quit the Ollama app when local-ai started it" }
    @{ Name = 'Status Local AI.lnk'; Arguments = 'status'; Description = "Show whether $(& $join (@('Ollama') + $names)) run, and what needs attention" }
    @{ Name = 'Update Local AI.lnk'; Arguments = 'update'; Description = ('Bring a release install of the launcher to its latest release and every part to ' +
            'its pin, after showing the plan and asking') }
}

# The shortcuts verb: create or replace Start, Stop, Status and Update Local AI.lnk in Shortcuts.Folder, each running this repository's local-ai.cmd with its
# verb in a normal window, with the Ollama app's icon when there is one; a shortcut that already matches is left alone. For a release install they run the
# shim local-ai.cmd in the install folder, which is also their working folder, never a version folder, which update may delete. With -Remove it deletes
# those four names only, and the folder when that leaves it empty. Returns 0; throws when local-ai.cmd is missing or a shortcut cannot be saved or removed.
function Set-LocalAIShortcut {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A launcher verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $settings = $Context.Settings
    $folder = Resolve-FolderPath -Path $settings.Shortcuts.Folder
    $specs = @(Get-LocalAIShortcutSpec -Settings $settings -Paths $Context.Paths)
    if ($Context.Remove) {
        $removed = 0
        foreach ($spec in $specs) {
            $path = Join-Path $folder $spec.Name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                Write-Host "Removed $path."
                $removed++
            }
        }
        if ($removed -eq 0) { Write-Host "$folder holds none of the launcher's shortcuts." }
        if ([IO.Directory]::Exists($folder)) {
            if (@([IO.Directory]::GetFileSystemEntries($folder)).Count -eq 0) {
                # Delete refuses a folder that is not empty.
                [IO.Directory]::Delete($folder)
                Write-Host "Removed the empty folder $folder."
            } else {
                Write-Host "Kept $folder, which holds other files."
            }
        }
        return 0
    }

    # A window works in its folder, which Windows then refuses to rename or delete.
    $workFolder = [string]$Context.RepoRoot
    $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
    if ((Get-LauncherInstallKind -RepoRoot $workFolder -InstallRoot $installRoot) -eq 'release') { $workFolder = [IO.Path]::GetFullPath($installRoot).TrimEnd('\') }
    $target = Join-Path $workFolder 'local-ai.cmd'
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Cannot find $target, which the shortcuts run." }
    Update-SessionPath
    $icon = Get-OllamaIcon
    # WScript.Shell reads an icon back as '<file>,<index>', and as ',0' when none is set; it refuses ''.
    $iconLocation = if ($icon) { "$icon,0" } else { ',0' }
    $null = [IO.Directory]::CreateDirectory($folder)
    $shell = Get-WScriptShell
    foreach ($spec in $specs) {
        $path = Join-Path $folder $spec.Name
        $existed = Test-Path -LiteralPath $path -PathType Leaf
        # CreateShortcut loads an existing file and writes nothing until Save.
        $link = $shell.CreateShortcut($path)
        # WindowStyle 1 is a normal window, which stays open for the pause local-ai.cmd makes after status, update or an error.
        $wanted = [ordered]@{
            TargetPath = $target; Arguments = $spec.Arguments; WorkingDirectory = $workFolder; WindowStyle = 1
            IconLocation = $iconLocation; Description = $spec.Description
        }
        $differs = @(foreach ($key in $wanted.Keys) { if ([string]$link.$key -ne [string]$wanted[$key]) { $key } })
        if ($existed -and $differs.Count -eq 0) {
            Write-Host "$path is up to date."
            continue
        }
        $ran = ("$($link.TargetPath) $($link.Arguments)").Trim()
        foreach ($key in $wanted.Keys) { $link.$key = $wanted[$key] }
        $link.Save()
        if (-not $existed) {
            Write-Host "Created $path."
        } elseif ($differs -contains 'TargetPath' -or $differs -contains 'Arguments') {
            Write-Host "Replaced $path, which ran '$ran'."
        } else {
            Write-Host "Updated $path."
        }
    }
    Write-Host "The Start menu folder $folder holds Start, Stop, Status and Update Local AI." -ForegroundColor Green
    return 0
}

# For update, once it made another launcher version active: when Shortcuts.Folder holds this install's Start Local AI.lnk, the one that runs the shim
# local-ai.cmd in the install folder, rewrite the launcher's shortcuts there (Set-LocalAIShortcut) for the launcher Context.RepoRoot and Context.InstallRoot
# name, so that they match that version, as one that adds Update Local AI. A folder without that shortcut gets none, and one whose Start Local AI runs another
# local-ai.cmd, such as a git clone's, stays as it is. Returns the text of its warning when reading that shortcut or writing the shortcuts fails, else nothing.
# update counts that text instead of a -WarningVariable, which would also collect the warnings Get-LocalAIShortcutSpec silences, such as one for ComfyUI.Args.
function Update-LocalAIShortcut {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which asks before it changes anything.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    try {
        $folder = Resolve-FolderPath -Path $Context.Settings.Shortcuts.Folder
        $start = [IO.Path]::Combine($folder, 'Start Local AI.lnk')
        if (-not [IO.File]::Exists($start)) { return }
        # The target Set-LocalAIShortcut gives the shortcuts of a release install.
        $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
        $shim = [IO.Path]::Combine([IO.Path]::GetFullPath($installRoot).TrimEnd('\'), 'local-ai.cmd')
        # CreateShortcut loads an existing file and writes nothing until Save.
        $ran = [string](Get-WScriptShell).CreateShortcut($start).TargetPath
        if (-not [string]::Equals($ran, $shim, [StringComparison]::OrdinalIgnoreCase)) { return }
        Write-Host "Bringing the launcher's Start menu shortcuts up to date..."
        $shortcuts = @{ Settings = $Context.Settings; Paths = $Context.Paths; RepoRoot = $Context.RepoRoot; InstallRoot = $Context.InstallRoot; Remove = $false }
        $null = Set-LocalAIShortcut -Context $shortcuts
    } catch {
        $text = "Could not bring the Start menu shortcuts up to date: $($_.Exception.Message) Run 'local-ai shortcuts' to try again."
        Write-Warning $text
        return $text
    }
}

# Return the Python minor version, such as '3.12', that $Version, such as '3.12.16', starts with; $Version itself when it names none. Pure.
function Get-PythonMinor {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Version
    )
    if ($Version -match '^(\d+\.\d+)') { return $Matches[1] }
    return $Version
}

# Return $true when this process can ask the person at the console a question: it runs for a user and its input is not redirected. Reads only.
function Test-LocalAIConsoleInput {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $redirected = $true
    try { $redirected = [Console]::IsInputRedirected } catch { $redirected = $true }
    return [Environment]::UserInteractive -and -not $redirected
}

# Return $true when what this process prints shows in its console window: its output goes to no file or pipe, as when a program reads it. Reads only.
function Test-LocalAIConsoleOutput {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $redirected = $true
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    return -not $redirected
}

# Return $true when PowerShell runs with -NonInteractive, as a scheduled task may start it, where nobody can answer: when an argument after the program in
# $CommandLine, by default this process's command line, starts with -noni, as -NonInteractive and each shorter form powershell.exe takes do, in any case and
# also with / or a typographic dash for the -. local-ai.ps1 refuses any argument that starts so. Reads only.
function Test-LocalAINonInteractive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$CommandLine = [Environment]::GetCommandLineArgs()
    )
    # powershell.exe reads a switch after an en dash, an em dash or a horizontal bar too.
    $pattern = '^[-/' + [char]0x2013 + [char]0x2014 + [char]0x2015 + ']noni'
    return @($CommandLine | Select-Object -Skip 1 | Where-Object { $_ -match $pattern }).Count -gt 0
}

# Drop the keys typed into this console that no program has read yet, so a key pressed while the launcher was busy cannot answer the next question.
# Returns nothing; a host without a console buffer, such as the ISE, is left alone.
function Clear-LocalAIConsoleInput {
    [CmdletBinding()]
    param()
    try {
        $Host.UI.RawUI.FlushInputBuffer()
    } catch {
        Write-Verbose "This host keeps no console input to drop: $($_.Exception.Message)"
    }
}

# Wait until the person at the console presses a key down, Ctrl+C included, and return its virtual key code. Throws when this host reads no keys, as one
# without a console.
function Read-LocalAIConsoleKey {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    # AllowCtrlC reads Ctrl+C as a key, so that it cannot stop the run that waits and change its exit code.
    return [int]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown,AllowCtrlC').VirtualKeyCode
}

# Keep this console window open until the person at it presses a key, as the pause of local-ai.cmd does, so that the last lines stay readable in a window a
# Start menu shortcut opened. Waits only when this window can ask (Test-LocalAIConsoleInput), shows what this run prints (Test-LocalAIConsoleOutput), and
# PowerShell runs without -NonInteractive (Test-LocalAINonInteractive), whose ReadKey would still wait. So a program or a test that redirects the input or
# reads the output never waits, nor does a powershell.exe -NonInteractive that runs local-ai.ps1 itself; local-ai.cmd starts its PowerShell without
# -NonInteractive. Keys typed before are dropped first. Returns nothing and never throws.
function Wait-LocalAIConsoleKey {
    [CmdletBinding()]
    param()
    if (-not (Test-LocalAIConsoleInput) -or -not (Test-LocalAIConsoleOutput) -or (Test-LocalAINonInteractive)) { return }
    Clear-LocalAIConsoleInput
    Write-Host 'Press any key to continue . . .' -NoNewline
    # Shift, Ctrl, Alt, the Windows keys and the lock keys alone end no wait, as with pause, so that switching windows with Alt+Tab keeps this one open.
    $alone = @(16, 17, 18, 20, 91, 92, 144, 145)
    try {
        do { $key = Read-LocalAIConsoleKey } while ($alone -contains $key)
    } catch {
        Write-Verbose "This host reads no keys: $($_.Exception.Message)"
    }
    Write-Host ''
}

# Return $true only when the person at the console answers y or yes to $Question, or with $Word exactly that word in any case; any other answer, an empty one
# included, is No. Keys typed before the question shows are dropped first. Throws when this window cannot ask, as when its input is redirected or PowerShell
# runs with -NonInteractive, so nothing changes unasked.
function Confirm-LocalAIAction {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Word
    )
    $refused = ("This window cannot ask '$Question', since its input is redirected or PowerShell runs non-interactively, so nothing was changed. Run " +
        'the command again in a console window.')
    if (-not (Test-LocalAIConsoleInput)) { throw $refused }
    Clear-LocalAIConsoleInput
    $prompt = if ($Word) { "$Question Type $Word to go ahead [$Word/N]" } else { "$Question [y/N]" }
    try {
        $answer = Read-Host -Prompt $prompt
    } catch {
        throw "$refused ($($_.Exception.Message))"
    }
    if ($Word) { return [bool]([string]$answer -match ('^\s*' + [regex]::Escape($Word) + '\s*\z')) }
    return [bool]([string]$answer -match '^\s*y(?:es)?\s*\z')
}

# Run git with $ArgumentList in the checkout $Dir and return @{ Code; Lines (its output lines that are not blank) }. A code outside $SuccessCode throws
# naming the command, the code and what git said.
function Invoke-GitCommand {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int[]]$SuccessCode = @(0)
    )
    $said = New-Object System.Collections.Generic.List[string]
    try {
        $code = Invoke-Native -FilePath 'git' -ArgumentList (@('-C', $Dir) + $ArgumentList) -SuccessCode $SuccessCode -Capture $said
    } catch {
        throw "$($_.Exception.Message) git said: $(@($said | Where-Object { $_.Trim() }) -join ' ')"
    }
    return @{ Code = $code; Lines = @($said | Where-Object { $_.Trim() }) }
}

# Run git with $ArgumentList, adding its output to $Capture, with GIT_TERMINAL_PROMPT=0 and GCM_INTERACTIVE=Never for this call only, so a remote that asks
# for a sign-in fails at once instead of opening a prompt of Git Credential Manager, which the system gitconfig names. Returns the exit code; a code outside
# $SuccessCode throws as Invoke-Native does.
function Invoke-GitNoPrompt {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Capture,
        [int[]]$SuccessCode = @(0)
    )
    $quiet = @{ GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'Never' }
    $saved = @{}
    foreach ($name in $quiet.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $quiet[$name], 'Process')
    }
    try {
        return Invoke-Native -FilePath 'git' -ArgumentList $ArgumentList -SuccessCode $SuccessCode -Capture $Capture
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

# Return @{ Head; Branch (refs/heads/<name>, or $null when HEAD is detached); Origin (remote.origin.url, or $null without origin); Modified (the entries
# 'git status --porcelain --untracked-files=no' lists, which a checkout would refuse to overwrite or carry along) } for the checkout in $Dir. Reads only and
# leaves the index alone; throws with git's text when git fails.
function Get-GitCheckoutState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Dir
    )
    $head = Get-GitHead -Dir $Dir
    # Exit code 1: HEAD is detached.
    $symbolic = Invoke-GitCommand -Dir $Dir -ArgumentList 'symbolic-ref', '-q', 'HEAD' -SuccessCode 0, 1
    $branch = if ($symbolic.Code -eq 0 -and $symbolic.Lines.Count -gt 0) { $symbolic.Lines[-1].Trim() } else { $null }
    # Exit code 1: no such key.
    $remote = Invoke-GitCommand -Dir $Dir -ArgumentList 'config', '--get', 'remote.origin.url' -SuccessCode 0, 1
    $origin = if ($remote.Code -eq 0 -and $remote.Lines.Count -gt 0) { $remote.Lines[-1].Trim() } else { $null }
    # Unlike 'git diff', status also lists a file whose line endings alone changed, which checkout refuses as well. --no-optional-locks keeps it from
    # rewriting the index.
    $status = Invoke-GitCommand -Dir $Dir -ArgumentList '--no-optional-locks', 'status', '--porcelain', '--untracked-files=no'
    $modified = @(foreach ($line in $status.Lines) { if ($line -match '^.. (.+)\z') { $Matches[1] } })
    return @{ Head = $head; Branch = $branch; Origin = $origin; Modified = $modified }
}

# Return the commit the tag $Ref names in the repository at $Repo, as 'git ls-remote' reports it without downloading objects (an annotated tag's peeled ^{} line
# wins), or $null when $Repo has no such tag. Prompts stay off; throws with git's text when git cannot reach $Repo.
function Get-GitRemoteTag {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Ref
    )
    $said = New-Object System.Collections.Generic.List[string]
    try {
        $null = Invoke-GitNoPrompt -ArgumentList 'ls-remote', $Repo, "refs/tags/$Ref", "refs/tags/$Ref^{}" -Capture $said
    } catch {
        throw "$($_.Exception.Message) git said: $(@($said | Where-Object { $_.Trim() }) -join ' ')"
    }
    $tagged = $null
    $peeled = $null
    foreach ($line in $said) {
        if ($line -match '^([0-9a-f]{40})\s+(\S+)\s*\z') {
            if ($Matches[2] -ceq "refs/tags/$Ref^{}") { $peeled = $Matches[1] } elseif ($Matches[2] -ceq "refs/tags/$Ref") { $tagged = $Matches[1] }
        }
    }
    if ($peeled) { return $peeled }
    return $tagged
}

# Make the remote origin of the checkout $Dir point at $Url: set-url when origin has another URL, add when there is none, remove it when $Url is empty, and
# change nothing when it already matches. Throws with git's text when git fails.
function Set-GitOrigin {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Dir,
        [AllowEmptyString()][string]$Url
    )
    $current = Invoke-GitCommand -Dir $Dir -ArgumentList 'config', '--get', 'remote.origin.url' -SuccessCode 0, 1
    $now = if ($current.Code -eq 0 -and $current.Lines.Count -gt 0) { $current.Lines[-1].Trim() } else { '' }
    if ($now -ceq $Url) { return }
    if (-not $Url) {
        $null = Invoke-GitCommand -Dir $Dir -ArgumentList 'remote', 'remove', 'origin'
    } elseif ($now) {
        $null = Invoke-GitCommand -Dir $Dir -ArgumentList 'remote', 'set-url', 'origin', $Url
    } else {
        $null = Invoke-GitCommand -Dir $Dir -ArgumentList 'remote', 'add', 'origin', $Url
    }
}

# Put the checkout $Dir back as $Before (Get-GitCheckoutState) holds it: on its branch, or detached at its commit, with its origin URL, or without origin. Works
# offline, since the previous commit stays in the clone. Throws naming the git command that failed.
function Restore-ComfyUICheckout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][hashtable]$Before
    )
    if ($Before.Branch) {
        $null = Invoke-GitCommand -Dir $Dir -ArgumentList 'checkout', ($Before.Branch -replace '^refs/heads/', '')
    } else {
        $null = Invoke-GitCommand -Dir $Dir -ArgumentList '-c', 'advice.detachedHead=false', 'checkout', '--detach', $Before.Head
    }
    Set-GitOrigin -Dir $Dir -Url ([string]$Before.Origin)
}

# Move the ComfyUI checkout $Dir in place to ComfyUI.Ref: fetch the tag from ComfyUI.Repo unless the clone holds ComfyUI.Commit, require it to be that commit,
# check it out detached and point origin at ComfyUI.Repo; untracked and ignored files stay. A failure after the fetch puts HEAD and origin back as $Before
# (Get-GitCheckoutState) holds them; every failure throws saying so. Returns nothing.
function Move-ComfyUICheckout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][hashtable]$Before
    )
    $comfy = $Settings.ComfyUI
    # Exit code 128 (or 1): no such commit in this clone.
    $present = (Invoke-GitCommand -Dir $Dir -ArgumentList 'cat-file', '-e', "$($comfy.Commit)^{commit}" -SuccessCode 0, 1, 128).Code -eq 0
    if (-not $present) {
        # A depth-1 fetch into a full clone would make it shallow for good, cutting off the history behind the tag.
        $shallow = @((Invoke-GitCommand -Dir $Dir -ArgumentList 'rev-parse', '--is-shallow-repository').Lines | ForEach-Object { $_.Trim() }) -contains 'true'
        $depth = if ($shallow) { @('--depth', '1') } else { @() }
        $said = New-Object System.Collections.Generic.List[string]
        try {
            # With prompts off. By URL, so origin changes only once the fetched commit is the pinned one. The FETCH_HEAD form is not refused by a local tag of
            # that name. Update's plan has checked with ls-remote that the tag names ComfyUI.Commit; this checks what arrived.
            $null = Invoke-GitNoPrompt -ArgumentList (@('-C', $Dir, 'fetch') + $depth + @('--no-tags', $comfy.Repo, "refs/tags/$($comfy.Ref)")) -Capture $said
        } catch {
            throw ("Cannot fetch $($comfy.Ref) from $($comfy.Repo), so $Dir is unchanged: $($_.Exception.Message) git said: " +
                "$(@($said | Where-Object { $_.Trim() }) -join ' ')")
        }
        $fetched = @((Invoke-GitCommand -Dir $Dir -ArgumentList 'rev-parse', 'FETCH_HEAD^{commit}').Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9a-f]{40}\z' })
        $commit = if ($fetched.Count -gt 0) { $fetched[-1] } else { 'none' }
        if ($commit -ne $comfy.Commit) {
            throw ("$($comfy.Ref) from $($comfy.Repo) is commit $commit, not ComfyUI.Commit $($comfy.Commit), so the tag has moved and $Dir is unchanged. " +
                'Check that release and make ComfyUI.Ref and ComfyUI.Commit agree, then run update again.')
        }
    }
    try {
        # Without --no-overwrite-ignore, an ignored file of the user's at a path the tag adds would be overwritten, and deleted on the way back.
        $null = Invoke-GitCommand -Dir $Dir -ArgumentList '-c', 'advice.detachedHead=false', 'checkout', '--detach', '--no-overwrite-ignore', $comfy.Commit
        Set-GitOrigin -Dir $Dir -Url $comfy.Repo
    } catch {
        $reason = $_.Exception.Message
        try {
            Restore-ComfyUICheckout -Dir $Dir -Before $Before
            $back = "$Dir is back at $($Before.Head)."
        } catch {
            $back = "Putting $Dir back at $($Before.Head) failed too: $($_.Exception.Message)"
        }
        throw "Cannot move $Dir to $($comfy.Ref): $reason $back"
    }
}

# Return $Path as a full path in the \\?\ form (\\?\UNC\ for a share), which Windows PowerShell 5.1's .NET reaches also beyond 259 characters; a path already
# in that form is returned as it is. Pure.
function ConvertTo-LocalAILongPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if ($Path.StartsWith('\\?\')) { return $Path }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

# Return the bytes of the file $Path, or of the files below the folder $Path walked without entering links, also beyond 259 characters; 0 when it does not
# exist. Reads only.
function Measure-LocalAIPath {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $long = ConvertTo-LocalAILongPath -Path $Path
    $file = New-Object IO.FileInfo -ArgumentList $long
    if ($file.Exists) { return [long]$file.Length }
    $root = New-Object IO.DirectoryInfo -ArgumentList $long
    if (-not $root.Exists) { return [long]0 }
    $total = [long]0
    $pending = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        foreach ($entry in $pending.Pop().GetFileSystemInfos()) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry) } else { $total += $entry.Length }
        }
    }
    return $total
}

# Delete the folder $Path and everything in it without entering links: a junction or symbolic link inside, or $Path itself when it is one, is removed as a
# link, so what it leads to stays, and a hard link loses only this name. Read-only entries are deleted too. A missing $Path is no error; throws naming the
# entry that cannot be deleted.
function Remove-LocalAITree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $long = ConvertTo-LocalAILongPath -Path $Path
    $root = New-Object IO.DirectoryInfo -ArgumentList $long
    if (-not $root.Exists) { return }
    $remove = {
        param([IO.FileSystemInfo]$Entry)
        $folder = $Entry -is [IO.DirectoryInfo]
        if ($folder -and -not ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            foreach ($child in $Entry.GetFileSystemInfos()) { & $remove $child }
        }
        try {
            if ($Entry.Attributes -band [IO.FileAttributes]::ReadOnly) {
                $Entry.Attributes = [IO.FileAttributes]([int]$Entry.Attributes -band -bnot [int][IO.FileAttributes]::ReadOnly)
            }
            # Without recursion, a folder's Delete removes a link itself and refuses a folder that is not empty.
            if ($folder) { ([IO.DirectoryInfo]$Entry).Delete($false) } else { $Entry.Delete() }
        } catch {
            throw "Cannot delete '$($Entry.FullName.Replace('\\?\', ''))': $($_.Exception.Message)"
        }
    }
    & $remove $root
}

# Back up the Open WebUI data folder $DataDir for update into a new $BackupRoot\open-webui-<yyyyMMdd-HHmmss>, after a free-space check: webui.db with its -wal
# and -shm, .webui_secret_key, uploads, vector_db, and the marker local-ai-backup.json naming Open WebUI $Version on Python $Python. Returns the folder, also
# for a data folder without webui.db; throws when a copy fails.
function New-OpenWebUIBackup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Version,
        [AllowEmptyString()][string]$Python
    )
    # Backup-OpenWebUIData copies the four files (the WAL can hold every row while webui.db holds none); the file and knowledge rows point into
    # the two folders.
    $files = @('webui.db', 'webui.db-wal', 'webui.db-shm', '.webui_secret_key')
    $folders = @('uploads', 'vector_db')
    $bytes = [long]0
    foreach ($name in $files + $folders) { $bytes += Measure-LocalAIPath -Path (Join-Path $DataDir $name) }
    $null = [IO.Directory]::CreateDirectory($BackupRoot)
    Test-FreeSpace -Path $BackupRoot -RequiredBytes $bytes
    $target = Backup-OpenWebUIData -DataDir $DataDir -BackupRoot $BackupRoot
    if (-not $target) {
        # No database yet, but a key that a rollback keeps with whatever data the new version makes.
        $target = Join-Path $BackupRoot ('open-webui-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
        $null = New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop
        $key = Join-Path $DataDir '.webui_secret_key'
        if (Test-Path -LiteralPath $key -PathType Leaf) { Copy-Item -LiteralPath $key -Destination $target -ErrorAction Stop }
    }
    foreach ($name in $folders) {
        $source = Join-Path $DataDir $name
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        try {
            Copy-Item -LiteralPath $source -Destination $target -Recurse -ErrorAction Stop
        } catch {
            $reason = $_.Exception
            while ($reason.InnerException) { $reason = $reason.InnerException }
            # Copy-Item in Windows PowerShell 5.1 stops at 259 characters, as an upload with a long name can reach.
            $long = if ($reason -is [IO.PathTooLongException] -or $reason -is [IO.DirectoryNotFoundException]) {
                ' A file below it may have a path longer than the 259 characters Windows PowerShell 5.1 copies; shorten or move that file.'
            } else { '' }
            throw "Cannot back up $source to ${target}: $($reason.Message)$long Open WebUI was not changed, and the incomplete backup has no local-ai-backup.json."
        }
    }
    Write-LocalAIState -Path (Join-Path $target 'local-ai-backup.json') -State @{
        Kind = 'open-webui-update'; Version = $Version; Python = $Python; DataDir = $DataDir; CreatedTicks = [DateTime]::UtcNow.Ticks
    }
    return $target
}

# Delete update's own Open WebUI backups in $BackupRoot beyond the $Keep newest, those whose local-ai-backup.json says open-webui-update; $Current is never
# deleted and counts as one of the $Keep, and install's backups, the data a rollback moved aside and anything else stay. Returns the deleted folders; one
# that cannot be deleted only warns.
function Remove-OldOpenWebUIBackup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [ValidateRange(1, 20)][int]$Keep = 3,
        [string]$Current
    )
    if (-not [IO.Directory]::Exists($BackupRoot)) { return }
    $currentFull = if ($Current) { Resolve-FolderPath -Path $Current } else { '' }
    $own = New-Object System.Collections.Generic.List[object]
    foreach ($folder in @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction Stop)) {
        if ($folder.Name -notmatch '^open-webui-\d{8}-\d{6}\z' -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $marker = @{}
        try { $marker = Read-LocalAIState -Path (Join-Path $folder.FullName 'local-ai-backup.json') } catch { $marker = @{} }
        if ($marker['Kind'] -ne 'open-webui-update') { continue }
        $ticks = [long]0
        if ($null -ne $marker['CreatedTicks']) { $ticks = [long]$marker['CreatedTicks'] }
        $own.Add([pscustomobject]@{ Folder = $folder; Ticks = $ticks; Current = ($currentFull -and $folder.FullName.Equals($currentFull, [StringComparison]::OrdinalIgnoreCase)) })
    }
    # Newest first by the UTC time the marker records, then by name, which follows the local clock: a clock set back, or the repeated hour of a change
    # from summer time, gives a newer backup a name that sorts first.
    $older = @($own | Where-Object { -not $_.Current } | Sort-Object @{ Expression = 'Ticks'; Descending = $true }, @{ Expression = { $_.Folder.Name }; Descending = $true })
    $slots = $Keep - @($own | Where-Object { $_.Current }).Count
    foreach ($folder in @($older | Select-Object -Skip ([math]::Max(0, $slots)) | ForEach-Object { $_.Folder })) {
        try {
            Remove-LocalAITree -Path $folder.FullName
            $folder.FullName
        } catch {
            Write-Warning "Could not delete the old Open WebUI backup $($folder.FullName): $($_.Exception.Message)"
        }
    }
}

# Put the Open WebUI data folder $DataDir back as the backup $Backup (from New-OpenWebUIBackup) holds it: move $DataDir as it is to
# $BackupRoot\open-webui-failed-<yyyyMMdd-HHmmss>, which nothing deletes, then copy in all the backup holds but its marker and package list, so webui.db, its -wal
# and -shm, uploads and vector_db come back as one set with their .webui_secret_key. Returns where the data went, or $null when $DataDir was missing; throws on a failed step.
function Restore-OpenWebUIData {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$Backup,
        [Parameter(Mandatory)][string]$BackupRoot
    )
    if (-not [IO.Directory]::Exists($Backup)) { throw "The backup $Backup does not exist." }
    $aside = $null
    if ([IO.Directory]::Exists($DataDir)) {
        $aside = Join-Path $BackupRoot ('open-webui-failed-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
        $null = [IO.Directory]::CreateDirectory($BackupRoot)
        if ([IO.Path]::GetPathRoot((Resolve-FolderPath -Path $DataDir)) -eq [IO.Path]::GetPathRoot((Resolve-FolderPath -Path $BackupRoot))) {
            # On one drive the move is a rename.
            [IO.Directory]::Move($DataDir, $aside)
        } else {
            Copy-Item -LiteralPath $DataDir -Destination $aside -Recurse -ErrorAction Stop
            Remove-LocalAITree -Path $DataDir
        }
    }
    $null = [IO.Directory]::CreateDirectory($DataDir)
    foreach ($item in @(Get-ChildItem -LiteralPath $Backup -Force -ErrorAction Stop)) {
        if (@('local-ai-backup.json', 'open-webui-packages.txt') -contains $item.Name) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $DataDir -Recurse -Force -ErrorAction Stop
    }
    return $aside
}

# Write the packages of the Python environment whose interpreter is $Python to $Path as the 'name==version' lines 'uv pip freeze' prints, for a later -c that
# installs the same versions again. Returns how many it wrote; throws when uv fails or lists none.
function Save-UvFreeze {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$Path
    )
    $said = New-Object System.Collections.Generic.List[string]
    try {
        $null = Invoke-Native -FilePath 'uv' -ArgumentList 'pip', 'freeze', '--python', $Python -Capture $said
    } catch {
        throw "$($_.Exception.Message) uv said: $(@($said | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' ')"
    }
    # uv also prints 'Using Python <version> environment at: <folder>'.
    $pins = @($said | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9._-]*==[^\s;]+\s*\z' } | ForEach-Object { $_.Trim() })
    if ($pins.Count -eq 0) { throw "'uv pip freeze --python $Python' listed no packages." }
    [IO.File]::WriteAllLines($Path, [string[]]$pins, (New-Object Text.UTF8Encoding $false))
    return $pins.Count
}

# Reinstall Open WebUI $Version on Python $Python with uv for a rollback, under the package list $Constraints (from Save-UvFreeze) when it exists, so every package
# comes back at the version it had; when that fails, or there is no list, as uv resolves them today. Returns Get-UvTool's entry; throws when uv fails both ways.
function Restore-OpenWebUITool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Python,
        [string]$Constraints
    )
    $install = @{ Name = 'open-webui'; Package = "open-webui==$Version"; Python = $Python; Reinstall = $true }
    if ($Constraints -and (Test-Path -LiteralPath $Constraints -PathType Leaf)) {
        try {
            return Install-UvTool @install -Constraints $Constraints
        } catch {
            Write-Host ("Reinstalling Open WebUI $Version with its saved package list failed ($($_.Exception.Message)); trying without it, so its packages " +
                'resolve as uv picks them today.') -ForegroundColor Yellow
        }
    }
    return Install-UvTool @install
}

# Return Open WebUI's part of update's plan: @{ Name; Display; Changes (one 'old -> new' text each); Problem (why update cannot run); Reinstall (uv lists another
# version, or a Python of another minor, than OpenWebUI.Version and .Python); Tool (Get-UvTool's entry) }. A record in install-stamp.json $Stamp that differs
# from what uv lists is a change of its own. Runs 'uv tool list' only.
function Get-OpenWebUIUpdatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Stamp
    )
    $pins = $Settings.OpenWebUI
    $plan = @{ Name = 'OpenWebUI'; Display = 'Open WebUI'; Changes = New-Object System.Collections.Generic.List[string]; Problem = $null; Note = $null; Reinstall = $false; Tool = $null }
    $tool = Get-UvTool -Name 'open-webui'
    $plan.Tool = $tool
    if (-not ($tool -and $tool.Path)) {
        $plan.Problem = "uv lists no open-webui tool with an entry point, so there is no Open WebUI to update. Run 'local-ai install', which installs Open WebUI $($pins.Version)."
        return $plan
    }
    $recorded = $Stamp['OpenWebUI']
    if ($tool.Version -ne $pins.Version -or (Get-PythonMinor -Version $tool.Python) -ne $pins.Python) {
        $plan.Reinstall = $true
        $plan.Changes.Add("$($tool.Version) on Python $($tool.Python) -> $($pins.Version) on Python $($pins.Python), after a backup of its data")
    } elseif ($recorded -isnot [hashtable] -or $recorded.Version -ne $tool.Version -or $recorded.Python -ne $tool.Python -or $recorded.Path -ne $tool.Path) {
        $plan.Changes.Add("install-stamp.json records $($recorded.Version) on Python $($recorded.Python) -> $($tool.Version) on Python $($tool.Python), as uv lists it")
    }
    return $plan
}

# Return @{ Setting; Pinned; Installed; Text ('old -> new') } for each change update makes to the ComfyUI checkout $Dir besides its commit: origin $Origin
# other than ComfyUI.Repo, a venv on the Microsoft Store Python, which update makes anew (that change has Rebuild $true), then a venv whose marker differs
# from what Install-ComfyUI would set up, or whose torch is not the constraints' pin. With -Moving, the venv gets the moved checkout's requirements instead.
# Reads files only; status and update share it.
function Get-ComfyUIPinDrift {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Dir,
        [AllowEmptyString()][string]$Origin,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Moving
    )
    $comfy = $Settings.ComfyUI
    if ($Origin -cne $comfy.Repo) {
        $shown = if ($Origin) { $Origin } else { 'none' }
        @{ Setting = 'ComfyUI.Repo'; Pinned = $comfy.Repo; Installed = $Origin; Text = "origin $shown -> $($comfy.Repo)" }
    }
    # install creates a venv on a uv-managed Python, but keeps one found in place, such as one the earlier scripts made on the Microsoft Store Python.
    $base = Get-VenvBasePython -Venv ([IO.Path]::Combine($Dir, '.venv'))
    if ($base -and $base.Store) {
        @{ Setting = 'ComfyUI.Python'; Pinned = "uv-managed $($comfy.Python)"; Installed = $base.Home; Rebuild = $true
            Text = "venv on the Microsoft Store Python $($base.Version), whose launches can fail or hang until Windows restarts -> a new venv on a uv-managed Python $($comfy.Python)" }
    }
    if ($Moving) {
        @{ Setting = 'ComfyUI.Ref'; Pinned = $comfy.Ref; Installed = ''; Text = "venv: the requirements of $($comfy.Ref), installed by uv as install does" }
        return
    }
    # As Install-ComfyUI judges the venv. Combine, unlike Join-Path, does not refuse a drive this PC does not have now.
    $constraints = Resolve-RepoPath -Path $comfy.Constraints -RepoRoot $RepoRoot
    $wanted = [ordered]@{
        RequirementsSha256 = (Get-LocalAIFileSha256 -Path ([IO.Path]::Combine($Dir, 'requirements.txt')))
        ConstraintsSha256  = (Get-LocalAIFileSha256 -Path $constraints)
        Backend            = $comfy.TorchBackend
        ExcludeNewer       = $comfy.ExcludeNewer
    }
    $marker = @{}
    try { $marker = Read-LocalAIState -Path ([IO.Path]::Combine($Dir, '.venv\local-ai-install.json')) } catch { $marker = @{} }
    $stale = @(foreach ($key in $wanted.Keys) { if ($marker[$key] -ne $wanted[$key]) { $key } })
    if ($stale.Count -gt 0) {
        @{ Setting = 'ComfyUI.Constraints'; Pinned = 'requirements.txt, ComfyUI.Constraints, ComfyUI.TorchBackend and ComfyUI.ExcludeNewer'; Installed = "another $($stale -join ', ')"
            Text = "venv set up for another $($stale -join ', ') -> requirements.txt, the constraints, $($comfy.TorchBackend) and $($comfy.ExcludeNewer)" }
    }
    $pinned = $null
    if (Test-Path -LiteralPath $constraints -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($constraints)) { if ($line -match '^\s*torch\s*==\s*([^\s;#]+)') { $pinned = $Matches[1] } }
    }
    if ($pinned -and $marker['Torch'] -and ([string]$marker['Torch'] -split '\+')[0] -ne $pinned) {
        @{ Setting = 'ComfyUI.Constraints'; Pinned = $pinned; Installed = [string]$marker['Torch']; Text = "torch $($marker['Torch']) -> $pinned" }
    }
}

# Return ComfyUI's part of update's plan: @{ Name; Display; Changes; Problem; Note (why update leaves it out); Migrate (HEAD is not ComfyUI.Commit); Rebuild (the
# venv runs on the Microsoft Store Python, so update makes it anew); Dir; Checkout (Get-GitCheckoutState) }. A move needs no changed tracked file and ComfyUI.Ref
# at ComfyUI.Commit in ComfyUI.Repo, which 'git ls-remote' checks without downloading; at the pin, the venv is judged as Install-ComfyUI judges it, and torch
# against the constraints. Reads only.
function Get-ComfyUIUpdatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $comfy = $Settings.ComfyUI
    $plan = @{ Name = 'ComfyUI'; Display = 'ComfyUI'; Changes = New-Object System.Collections.Generic.List[string]; Problem = $null; Note = $null; Migrate = $false
        Rebuild = $false; Dir = $null; Checkout = $null }
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($comfy.Dir)
    if ($dir.Length -gt 3) { $dir = $dir.TrimEnd('\') }
    $plan.Dir = $dir
    $recorded = $Stamp['ComfyUI']
    # uninstall keeps only Dir and Cloned of an entry whose venv it removed.
    if ($recorded -isnot [hashtable] -or -not $recorded.Python) {
        $plan.Note = "install has not set up ComfyUI, so update leaves it out. Run 'local-ai install', which sets it up."
        return $plan
    }
    if ([string]$recorded.Dir -ne $dir) {
        $plan.Note = "install set up ComfyUI in '$($recorded.Dir)', but ComfyUI.Dir is '$dir', so update leaves it out. Run 'local-ai install', which sets it up there."
        return $plan
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        $plan.Note = "$dir is no git checkout, so update leaves ComfyUI out. Run 'local-ai install', which says what to do about it."
        return $plan
    }
    $checkout = Get-GitCheckoutState -Dir $dir
    $plan.Checkout = $checkout
    $where = if ($checkout.Branch) { 'branch ' + ($checkout.Branch -replace '^refs/heads/', '') } else { 'detached' }
    if ($checkout.Head -ne $comfy.Commit) {
        $plan.Migrate = $true
        $plan.Changes.Add("commit $($checkout.Head) ($where) -> $($comfy.Ref) ($($comfy.Commit)), moved in place; models, output, input, user, custom_nodes and .venv stay")
        if ($checkout.Modified.Count -gt 0) {
            $listed = @($checkout.Modified | Select-Object -First 10) -join ', '
            $more = if ($checkout.Modified.Count -gt 10) { " and $($checkout.Modified.Count - 10) more" } else { '' }
            $plan.Problem = ("$dir has changes to tracked files, which moving it to $($comfy.Ref) would overwrite or carry along: $listed$more. Undo them, or keep " +
                "them with 'git -C `"$dir`" stash', then run update again.")
            return $plan
        }
        try {
            $tagged = Get-GitRemoteTag -Repo $comfy.Repo -Ref $comfy.Ref
        } catch {
            $plan.Problem = "Cannot check the tag $($comfy.Ref) at $($comfy.Repo): $($_.Exception.Message)"
            return $plan
        }
        if (-not $tagged) {
            $plan.Problem = "$($comfy.Repo) has no tag $($comfy.Ref). Check ComfyUI.Repo and ComfyUI.Ref in settings.psd1."
        } elseif ($tagged -ne $comfy.Commit) {
            $plan.Problem = ("The tag $($comfy.Ref) at $($comfy.Repo) names commit $tagged, not ComfyUI.Commit $($comfy.Commit), so the tag has moved. Check " +
                'that release and make ComfyUI.Ref and ComfyUI.Commit agree, then run update again.')
        }
    }
    foreach ($change in @(Get-ComfyUIPinDrift -Settings $Settings -Dir $dir -Origin ([string]$checkout.Origin) -RepoRoot $RepoRoot -Moving:$plan.Migrate)) {
        $plan.Changes.Add($change.Text)
        if ($change.Rebuild) { $plan.Rebuild = $true }
    }
    if ($plan.Migrate) { return $plan }
    if ($recorded.Commit -ne $checkout.Head -or $recorded.Ref -ne $comfy.Ref) {
        $plan.Changes.Add("install-stamp.json records commit $($recorded.Commit) -> $($checkout.Head) ($($comfy.Ref))")
    }
    return $plan
}

# Return the file tools' part of update's plan: @{ Name; Display; Changes; Problem; Note (why update leaves them out) }, from Get-McpoPinDrift against the Files
# entry of install-stamp.json $Stamp, the mcpo that 'uv tool list' shows, Files.ServerVersion and the hash of Files.ServerPackage's package-lock.json. Reads only.
function Get-FilesUpdatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $files = $Settings.Files
    $plan = @{ Name = 'Files'; Display = 'File tools'; Changes = New-Object System.Collections.Generic.List[string]; Problem = $null; Note = $null }
    $recorded = $Stamp['Files']
    if ($recorded -isnot [hashtable]) {
        $plan.Note = "install has not set up the file tools, so update leaves them out. Run 'local-ai install', which sets them up for Files.Root."
        return $plan
    }
    $drift = @(Get-McpoPinChange -Settings $Settings -Recorded $recorded)
    foreach ($change in $drift) { $plan.Changes.Add("mcpo $($change.Setting) '$($change.Installed)' -> '$($change.Pinned)'") }
    $tool = Get-UvTool -Name 'mcpo'
    if (-not $tool) {
        $plan.Changes.Add("mcpo: none in uv's list -> $($files.McpoVersion)")
    } elseif ($drift.Count -eq 0 -and ($tool.Version -ne $files.McpoVersion -or (Get-PythonMinor -Version $tool.Python) -ne $files.Python)) {
        $plan.Changes.Add("mcpo $($tool.Version) on Python $($tool.Python) -> $($files.McpoVersion) on Python $($files.Python)")
    }
    if ($recorded.ServerVersion -ne $files.ServerVersion) { $plan.Changes.Add("files server $($recorded.ServerVersion) -> $($files.ServerVersion)") }
    $lock = Join-Path (Resolve-RepoPath -Path $files.ServerPackage -RepoRoot $RepoRoot) 'package-lock.json'
    $sha = Get-LocalAIFileSha256 -Path $lock
    if ($sha -ne $recorded.LockSha256) { $plan.Changes.Add("files server lockfile $($recorded.LockSha256) -> $sha") }
    return $plan
}

# Return the chat model's part of update's plan: @{ Name; Display; Changes; Problem; Note }: Model.Alias, the weights and projector digests and the hash of the
# Modelfile Install-ChatModel uses against the Model entry of install-stamp.json $Stamp, and whether Ollama holds Model.Alias on the pinned blobs ('ollama show').
# Needs the Ollama server up; changes nothing.
function Get-ModelUpdatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $model = $Settings.Model
    $plan = @{ Name = 'Model'; Display = 'Model'; Changes = New-Object System.Collections.Generic.List[string]; Problem = $null; Note = $null }
    $recorded = $Stamp['Model']
    if ($recorded -isnot [hashtable]) { $recorded = @{} }
    if ($recorded.Alias -ne $model.Alias) { $plan.Changes.Add("alias $($recorded.Alias) -> $($model.Alias)") }
    if ($model.Sha256 -and $recorded.BaseDigest -ne $model.Sha256) { $plan.Changes.Add("weights $($recorded.BaseDigest) -> $($model.Sha256), pulled from $($model.Source) unless Ollama holds them") }
    if ($model.ProjectorSha256 -and $recorded.ProjectorDigest -ne $model.ProjectorSha256) { $plan.Changes.Add("vision projector $($recorded.ProjectorDigest) -> $($model.ProjectorSha256)") }
    $modelfile = Resolve-ChatModelfile -Settings $Settings -Paths $Paths -RepoRoot $RepoRoot
    $sha = Get-LocalAIFileSha256 -Path $modelfile
    if ($sha -ne $recorded.ModelfileSha256) { $plan.Changes.Add("Modelfile $($recorded.ModelfileSha256) -> $sha ($modelfile)") }
    $blobs = @(Get-OllamaModelBlob -Name $model.Alias)
    if ($blobs.Count -eq 0) {
        $plan.Changes.Add("$($model.Alias): none in Ollama -> created from $modelfile")
    } elseif (-not (Test-ChatModelPin -Blobs $blobs -Model $model)) {
        $plan.Changes.Add("$($model.Alias) on the blobs $(@($blobs | ForEach-Object { $_.Digest }) -join ', ') -> on the pinned ones")
    }
    return $plan
}

# Return the image checkpoint's part of update's plan: @{ Name; Display; Changes; Problem; Note }, with a change when install-stamp.json $Stamp checked another
# Images.File or Images.Sha256, or the file in ComfyUI.Dir\models\checkpoints is missing, or its length or write time differs from what state.json $State recorded
# when it was hashed. Reads only.
function Get-CheckpointUpdatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][hashtable]$State
    )
    $images = $Settings.Images
    $plan = @{ Name = 'Checkpoint'; Display = 'Checkpoint'; Changes = New-Object System.Collections.Generic.List[string]; Problem = $null; Note = $null }
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Settings.ComfyUI.Dir)
    $target = Join-Path $dir "models\checkpoints\$($images.File)"
    $file = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
    $download = "downloaded from $($images.Repo) ($(Format-LocalAISize -Bytes ([long]$images.Size)))"
    $checked = $Stamp['Images']
    if ($checked -isnot [hashtable] -or $checked.File -cne $images.File -or $checked.Sha256 -ne $images.Sha256) {
        $old = if ($checked -is [hashtable]) { "$($checked.File) ($($checked.Sha256))" } else { 'none checked' }
        $how = if ($file) { 'checked against Images.Sha256' } else { $download }
        $plan.Changes.Add("$old -> $($images.File) ($($images.Sha256)), $how")
        return $plan
    }
    if (-not $file) {
        $plan.Changes.Add("$target missing -> $download")
        return $plan
    }
    $seen = $null
    if ($images.Sha256 -and $State['Images'] -is [hashtable] -and $State['Images']['VerifiedFiles'] -is [hashtable]) { $seen = $State['Images']['VerifiedFiles'][$images.Sha256] }
    if ($file.Length -ne [long]$images.Size -or ($images.Sha256 -and -not ($seen -is [hashtable] -and $seen.Length -eq $file.Length -and $seen.WriteTicks -eq $file.LastWriteTimeUtc.Ticks))) {
        $plan.Changes.Add("$target changed since install checked it -> checked against Images.Size and Images.Sha256 again")
    }
    return $plan
}

# Return @{ Installed; Available } when 'winget list --upgrade-available', which changes nothing, shows the package $Package (Id) with a newer version; $null when it
# shows none or the package is not installed. Throws when winget fails otherwise.
function Get-WingetUpgrade {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Package
    )
    $id = $Package.Id
    $said = New-Object System.Collections.Generic.List[string]
    try {
        # 0x8A150014 NO_APPLICATIONS_FOUND: not installed.
        $null = Invoke-Native -FilePath 'winget' -ArgumentList 'list', '--id', $id, '-e', '--upgrade-available', '--accept-source-agreements', '--disable-interactivity' `
            -SuccessCode 0, -1978335212 -Capture $said
    } catch {
        throw "$($_.Exception.Message) winget said: $(@($said | Where-Object { $_.Trim() }) -join ' ')"
    }
    # winget 1.29 exits 0 with or without an upgrade, so the row decides: Name (which may hold spaces), Id, Version, Available, Source.
    foreach ($line in $said) {
        $tokens = @($line.Trim() -split '\s+')
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -ne $id) { continue }
            $after = @($tokens | Select-Object -Skip ($i + 1))
            # A version winget cannot read in full shows as '< 2.1'.
            if ($after.Count -ge 2 -and $after[0] -eq '<') { $after = @("< $($after[1])") + @($after | Select-Object -Skip 2) }
            if ($after.Count -ge 3) { return @{ Installed = $after[0]; Available = $after[1] } }
        }
    }
    return $null
}

# Return the winget packages update -Tools upgrades that winget offers a newer version of, as @{ Name; Display; Package; Upgrade (Get-WingetUpgrade) }, in the order
# uv, Git (with Images.Enabled), Node.js (only when install-stamp.json $Stamp says install put it in) and Ollama last. Reads winget's list only.
function Get-WingetUpdatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Stamp
    )
    $displays = @{ Uv = 'uv'; Git = 'Git'; Node = 'Node.js'; Ollama = 'Ollama' }
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add('Uv')
    if ($Settings.Images.Enabled) { $names.Add('Git') }
    # A Node.js that install found in place is the user's, as uninstall treats it; its machine-wide upgrade would ask for administrator approval.
    if ($Stamp['Node'] -is [hashtable] -and $Stamp['Node'].InstalledByLauncher -eq $true) {
        $names.Add('Node')
    } elseif ($Settings.Files.Root -and $Settings.Winget.Packages['Node'] -is [hashtable]) {
        Write-Host ("Node.js stays as it is: install-stamp.json does not record that install put it in, so update -Tools leaves it to you; " +
            "'winget upgrade --id $($Settings.Winget.Packages['Node'].Id) -e' upgrades it.")
    }
    # Last, since its installer stops the Ollama app.
    $names.Add('Ollama')
    foreach ($name in $names) {
        $package = $Settings.Winget.Packages[$name]
        if ($package -isnot [hashtable]) { continue }
        $upgrade = Get-WingetUpgrade -Package $package
        if ($upgrade) { @{ Name = $name; Display = $displays[$name]; Package = $package; Upgrade = $upgrade } }
    }
}

# Upgrade the winget package $Package (Id, Scope) with 'winget upgrade' on the console, logging to $LogDir\winget-upgrade-<Id>.log. Returns 'upgraded', 'current'
# (no applicable upgrade), 'restart' (Windows must restart to finish), 'pinned' (winget holds it at a version) or 'missing' (winget lists no installed copy); the
# last three warn. Any other winget result throws naming the code, the log and, where winget documents one, the reason.
function Update-WingetPackage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which asks before it changes anything.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Package,
        [Parameter(Mandatory)][string]$LogDir
    )
    $id = $Package.Id
    # winget's documented return codes (doc/windows/package-manager/winget/returnCodes.md).
    $outcomes = @{
        0           = 'upgraded'
        # 0x8A15002B UPDATE_NOT_APPLICABLE and 0x8A15004F UPGRADE_VERSION_NOT_NEWER.
        -1978335189 = 'current'
        -1978335153 = 'current'
        # 0x8A150109 INSTALL_REBOOT_REQUIRED_TO_FINISH.
        -1978334967 = 'restart'
        # 0x8A150068 PACKAGE_IS_PINNED.
        -1978335128 = 'pinned'
        # 0x8A150014 NO_APPLICATIONS_FOUND.
        -1978335212 = 'missing'
    }
    $reasons = @{
        # 0x8A150101 INSTALL_PACKAGE_IN_USE and 0x8A150111 IN_USE_BY_APPLICATION.
        -1978334975 = "$id is in use; close it, then run 'local-ai update -Tools' again"
        -1978334959 = "a program that uses $id runs; close it, then run 'local-ai update -Tools' again"
        # 0x8A150102 INSTALL_IN_PROGRESS.
        -1978334974 = "another installation runs; let it finish, then run 'local-ai update -Tools' again"
        # 0x8A15010C CANCELLED_BY_USER, as when the administrator prompt is declined.
        -1978334964 = 'the installation was cancelled, as when the administrator prompt is declined'
        # 0x8A15010F BLOCKED_BY_POLICY.
        -1978334961 = 'a policy blocks it'
        # 0x8A15010A REBOOT_REQUIRED_FOR_INSTALL and 0x8A15010B INSTALL_REBOOT_INITIATED.
        -1978334966 = "Windows must restart first; restart, then run 'local-ai update -Tools' again"
        -1978334965 = 'Windows is restarting'
    }
    $null = [IO.Directory]::CreateDirectory($LogDir)
    $log = Join-Path $LogDir "winget-upgrade-$id.log"
    if ($Package.Scope -eq 'machine') {
        Write-Host "Upgrading $id for all users: Windows asks for administrator approval (UAC)." -ForegroundColor Yellow
    } else {
        Write-Host "Upgrading $id..."
    }
    try {
        $code = Invoke-Native -FilePath 'winget' -ArgumentList 'upgrade', '--id', $id, '-e', '--source', 'winget', '--silent', '--disable-interactivity',
            '--accept-source-agreements', '--accept-package-agreements', '--log', $log -SuccessCode @($outcomes.Keys) -Console
    } catch {
        $message = $_.Exception.Message
        $why = ''
        if ($message -match 'exit code (-?\d+)\.' -and $reasons.ContainsKey([int]$Matches[1])) { $why = " $($reasons[[int]$Matches[1]])." }
        throw "winget could not upgrade ${id}: $message$why 'winget error <code>' explains the code; the log is $log."
    }
    Update-SessionPath
    $outcome = $outcomes[$code]
    switch ($outcome) {
        'upgraded' { Write-Host "Upgraded $id." }
        'current' { Write-Host "winget has no applicable upgrade for $id, so it stays as it is." }
        'restart' { Write-Warning "Restart Windows to finish upgrading $id." }
        'pinned' { Write-Warning "winget holds $id at a pinned version, so it was not upgraded; 'winget pin remove --id $id' lifts the pin." }
        'missing' { Write-Warning "winget lists no installed $id, so it was not upgraded." }
    }
    return $outcome
}

# Return the names in $Name that 'ollama list' shows, as given, also those it shows with the tag latest added. Needs the Ollama server up; throws when ollama fails.
function Get-OllamaListedModel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$Name = @()
    )
    $said = New-Object System.Collections.Generic.List[string]
    $null = Invoke-Native -FilePath 'ollama' -ArgumentList 'list' -Capture $said
    # Ollama 0.40.11 prints a NAME, ID, SIZE, MODIFIED header, then one model per line, its name first.
    $listed = @(foreach ($line in $said) { $first = @($line.Trim() -split '\s+')[0]; if ($first) { $first } })
    foreach ($item in $Name) { if ($item -and ($listed -contains $item -or $listed -contains "${item}:latest")) { $item } }
}

# Offer each Model.SupersededAliases name that 'ollama list' shows, never Model.Alias or Model.Source, for removal with its own Confirm-LocalAIAction (default No),
# saying first what still uses it, and run 'ollama rm' only on a yes. Returns the names it removed; a failed removal warns, and a window that cannot ask
# removes nothing. Warns and runs no ollama when the server at $Url, the one the ollama program uses (Assert-OllamaCliUrl), does not answer.
function Remove-SupersededAlias {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It asks before each removal itself.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Url
    )
    $model = $Settings.Model
    # Also with the tag latest, which Ollama adds to a name without one.
    $kept = @(foreach ($name in @($model.Alias, $model.Source)) { if ($name) { [string]$name; "${name}:latest" } })
    $offered = @(@($model.SupersededAliases) | Where-Object { $_ -and $kept -notcontains $_ -and $kept -notcontains "${_}:latest" })
    if ($offered.Count -eq 0) { return }
    # Without a server the ollama program starts the Ollama app, which would hold the captured output open (Get-OllamaModelBlob) and stay running.
    $reason = $null
    try {
        $answer = Invoke-RestMethod -Uri "$Url/api/version" -UseBasicParsing -TimeoutSec 5
        if (-not $answer.version) { $reason = 'it answered without a version' }
    } catch {
        $reason = $_.Exception.Message
    }
    if ($reason) {
        Write-Warning "Could not list Ollama's models to offer removing the superseded aliases: Ollama does not answer at $Url/api/version ($reason)."
        return
    }
    try {
        $listed = @(Get-OllamaListedModel -Name $offered)
    } catch {
        Write-Warning "Could not list Ollama's models to offer removing the superseded aliases: $($_.Exception.Message)"
        return
    }
    foreach ($name in $listed) {
        # What still uses it, said before the question.
        $note = Get-SupersededAliasNote -Name $name -Alias $model.Alias
        if ($note) { Write-Host "${name}: $note" -ForegroundColor Yellow }
        try {
            $yes = Confirm-LocalAIAction -Question "Ollama still holds $name, the alias of an earlier chat model. Remove it with 'ollama rm $name'? Blobs that $($model.Alias) uses stay."
        } catch {
            Write-Host "$name stays: $($_.Exception.Message)"
            return
        }
        if (-not $yes) {
            Write-Host "Kept $name."
            continue
        }
        $said = New-Object System.Collections.Generic.List[string]
        try {
            $null = Invoke-Native -FilePath 'ollama' -ArgumentList 'rm', $name -Capture $said
            Write-Host "Removed $name from Ollama."
            $name
        } catch {
            # Ollama 0.40.11 writes terminal control sequences even when its output is captured.
            $text = @($said | ForEach-Object { $_ -replace '\x1b\[[0-9;?]*[A-Za-z]', '' } | Where-Object { $_.Trim() }) -join ' '
            Write-Warning "Could not remove ${name}: $($_.Exception.Message) ollama said: $text"
        }
    }
}

# Return the names of the services state.json at $Path records whose process, or recorded listener, still runs as recorded (Get-LiveRecord), sorted. Reads only;
# a missing or unreadable state file gives none.
function Get-LocalAIRunningService {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $state = @{}
    try { $state = Read-LocalAIState -Path $Path } catch { return }
    $records = $state['Services']
    if ($records -isnot [hashtable]) { return }
    foreach ($name in @($records.Keys | Sort-Object)) {
        $record = $records[$name]
        if ($record -is [hashtable] -and @((Get-LiveRecord -Record $record).Match).Count -gt 0) { [string]$name }
    }
}

# Return what update's check of the started stack finds: @{ OpenWebUI (why Open WebUI fails it, or $null); Problems (one text per optional service that fails) }.
# Each service in Get-LocalAIServicePlan's table for the current install-stamp.json must answer its Identity: Open WebUI /api/version with $OpenWebUIVersion,
# mcpo with exactly Files.AllowedTools as routes, the image gate as itself, and ComfyUI must render on CUDA. Reads only.
function Test-LocalAIUpdateSmoke {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$OllamaUrl,
        [string]$OpenWebUIVersion
    )
    $result = @{ OpenWebUI = $null; Problems = New-Object System.Collections.Generic.List[string] }
    $stamp = Read-LocalAIState -Path $Paths.InstallStamp
    foreach ($service in @(Get-LocalAIServicePlan -Settings $Settings -Paths $Paths -Stamp $stamp -OllamaUrl $OllamaUrl)) {
        try {
            $version = [string](& $service.Identity $service)
            if ($service.Name -eq 'OpenWebUI' -and $OpenWebUIVersion -and $version -ne $OpenWebUIVersion) {
                throw "it answers as Open WebUI $version, not $OpenWebUIVersion."
            }
            if ($service.Name -eq 'ComfyUI') {
                $device = @()
                if (-not (Test-ComfyUIDevice -Url $service.Url -WarningAction SilentlyContinue -WarningVariable device)) {
                    throw (@($device | ForEach-Object { [string]$_.Message }) -join ' ')
                }
            }
            Write-Host "$($service.DisplayName) passes the check: $version at $($service.Url)."
        } catch {
            if ($service.Required) {
                $result.OpenWebUI = $_.Exception.Message
            } else {
                $result.Problems.Add("$($service.DisplayName) fails the check after the update: $($_.Exception.Message)")
            }
        }
    }
    return $result
}

# Bring Open WebUI to its pins for update: back up its data, save the old package versions beside the backup, reinstall OpenWebUI.Version on OpenWebUI.Python
# in $ToolDir (a failure puts the old version back and throws), and record it with the previous version in install-stamp.json; without $Plan.Reinstall, only
# record what uv lists. Returns @{ Done; Previous (old version, Python and path, or $null); Backup; Constraints; ToolDir }; prunes no backup.
function Update-OpenWebUITool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which asks before it changes anything.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$ToolDir
    )
    $pins = $Settings.OpenWebUI
    $old = $Plan.Tool
    $previous = @{ Version = $old.Version; Path = $old.Path; Python = $old.Python }
    $dataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($pins.DataDir)
    if (-not $Plan.Reinstall) {
        $stamp = Read-LocalAIState -Path $Paths.InstallStamp
        $stamp['OpenWebUI'] = Get-OpenWebUIStampEntry -Tool $previous -ToolDir $ToolDir -DataDir $dataDir
        Write-LocalAIState -Path $Paths.InstallStamp -State $stamp
        return @{ Done = "Open WebUI: install-stamp.json records $($old.Version) on Python $($old.Python), as uv lists it"; Previous = $null; Backup = $null; Constraints = $null
            ToolDir = $ToolDir }
    }
    $backup = New-OpenWebUIBackup -DataDir $dataDir -BackupRoot $Paths.Backups -Version $old.Version -Python $old.Python
    Write-Host "Backed up Open WebUI's data from $dataDir to $backup."
    # Without the list, a reinstall of the old version resolves its dependencies anew, to newer versions than it had.
    $constraints = Join-Path $backup 'open-webui-packages.txt'
    try {
        $count = Save-UvFreeze -Python (Join-Path $ToolDir 'open-webui\Scripts\python.exe') -Path $constraints
        Write-Host "Saved the versions of the $count packages of Open WebUI $($old.Version) to $constraints, for a rollback."
    } catch {
        $constraints = $null
        Write-Warning "Could not save the package versions of Open WebUI $($old.Version), so a rollback would resolve its packages anew: $($_.Exception.Message)"
    }
    Test-FreeSpace -Path $ToolDir -RequiredBytes $pins.InstallBytes
    Write-Host "Reinstalling Open WebUI $($pins.Version) on Python $($pins.Python) with uv..."
    try {
        $new = Install-UvTool -Name 'open-webui' -Package "open-webui==$($pins.Version)" -Python $pins.Python -Reinstall
        if ($new.Version -ne $pins.Version -or (Get-PythonMinor -Version $new.Python) -ne $pins.Python -or -not $new.Path) {
            throw "uv lists Open WebUI $($new.Version) on Python $($new.Python) afterwards, not $($pins.Version) on Python $($pins.Python) with an entry point."
        }
    } catch {
        $reason = $_.Exception.Message
        # With another Python minor, uv deletes the old environment before it downloads, so a failed download leaves no Open WebUI at all.
        Write-Host "Reinstalling Open WebUI $($pins.Version) failed; putting back $($old.Version) on Python $($old.Python)..." -ForegroundColor Yellow
        try {
            $back = Restore-OpenWebUITool -Version $old.Version -Python $old.Python -Constraints $constraints
            $stamp = Read-LocalAIState -Path $Paths.InstallStamp
            $stamp['OpenWebUI'] = Get-OpenWebUIStampEntry -Tool $back -ToolDir $ToolDir -DataDir $dataDir
            Write-LocalAIState -Path $Paths.InstallStamp -State $stamp
            $after = "Open WebUI $($back.Version) on Python $($back.Python) is installed again, and its data was not touched."
        } catch {
            $list = if ($constraints) { " -c `"$constraints`"" } else { '' }
            $after = ("Putting back Open WebUI $($old.Version) failed too ($($_.Exception.Message)), so Open WebUI may not be installed now; its data was not " +
                "touched, and the backup is $backup. Reinstall it with: uv tool install --python $($old.Python) open-webui==$($old.Version)$list --reinstall")
        }
        throw "Open WebUI $($pins.Version) could not be installed: $reason $after"
    }
    $stamp = Read-LocalAIState -Path $Paths.InstallStamp
    $stamp['OpenWebUI'] = Get-OpenWebUIStampEntry -Tool $new -ToolDir $ToolDir -DataDir $dataDir -Extra @{
        PreviousVersion = $old.Version; PreviousPython = $old.Python; Backup = $backup
    }
    Write-LocalAIState -Path $Paths.InstallStamp -State $stamp
    # The caller prunes the older backups once the new version passed its check.
    return @{
        Done        = "Open WebUI: $($old.Version) on Python $($old.Python) -> $($new.Version) on Python $($new.Python)"
        Previous    = $previous
        Backup      = $backup
        Constraints = $constraints
        ToolDir     = $ToolDir
    }
}

# Put Open WebUI back as it was before update's change $Change (from Update-OpenWebUITool) once the new version failed the check: stop the stack but not Ollama,
# reinstall the previous version on the previous Python under the saved package list, record it in install-stamp.json, then restore the data folder from the
# backup, moving the failed data aside. Returns one text saying what was done and where the data went; a failed step is named in it, never thrown, and no data
# is deleted.
function Undo-OpenWebUIUpdate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Change
    )
    $paths = $Context.Paths
    $previous = $Change.Previous
    $dataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Context.Settings.OpenWebUI.DataDir)
    $list = if ($Change.Constraints) { " -c `"$($Change.Constraints)`"" } else { '' }
    $reinstall = "uv tool install --python $($previous.Python) open-webui==$($previous.Version)$list --reinstall"
    $restore = "move $dataDir aside and copy what $($Change.Backup) holds into it, but local-ai-backup.json and open-webui-packages.txt"
    # The stack starts again afterwards, against the same Ollama.
    if ((Stop-LocalAI -Context $Context -KeepOllama) -ne 0) {
        return "It could not be stopped for the rollback, so the new version stays; once it is stopped, reinstall the previous one with: $reinstall. Then $restore."
    }
    try {
        $tool = Restore-OpenWebUITool -Version $previous.Version -Python $previous.Python -Constraints $Change.Constraints
    } catch {
        return ("Reinstalling Open WebUI $($previous.Version) failed ($($_.Exception.Message)), so its data was left as the new version used it. Reinstall it " +
            "with: $reinstall. Then $restore.")
    }
    $stamp = Read-LocalAIState -Path $paths.InstallStamp
    $stamp['OpenWebUI'] = Get-OpenWebUIStampEntry -Tool $tool -ToolDir ([string]$Change.ToolDir) -DataDir $dataDir
    Write-LocalAIState -Path $paths.InstallStamp -State $stamp
    $done = "Open WebUI $($tool.Version) on Python $($tool.Python) is installed again"
    try {
        $aside = Restore-OpenWebUIData -DataDir $dataDir -Backup $Change.Backup -BackupRoot $paths.Backups
        $where = if ($aside) { ", and the data the new version used is in $aside" } else { '' }
        return "$done, with its data back as $($Change.Backup) holds it$where."
    } catch {
        return "$done, but putting back its data failed ($($_.Exception.Message)); $restore by hand."
    }
}

# Bring ComfyUI to its pins for update: move the checkout to ComfyUI.Ref when HEAD differs, else point origin at ComfyUI.Repo; run Install-ComfyUI's venv step,
# or with $Plan.Rebuild Reset-ComfyUIVenv, which makes the venv anew, and record the result with the previous commit, branch and origin in install-stamp.json.
# A failed venv step after a move puts the checkout back and throws; unless the rebuild put the old venv back, it marks the venv stale and says what it may
# hold. Returns the line for update's summary.
function Update-ComfyUICheckout {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which asks before it changes anything.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $comfy = $Settings.ComfyUI
    $dir = $Plan.Dir
    # Read again, as the plan was made before the stack stopped.
    $before = Get-GitCheckoutState -Dir $dir
    $moved = $false
    if ($before.Head -ne $comfy.Commit) {
        if ($before.Modified.Count -gt 0) { throw "$dir has changes to tracked files, so it was not moved: $($before.Modified -join ', ')." }
        Write-Host "Moving ComfyUI in $dir from $($before.Head) to $($comfy.Ref)..."
        Move-ComfyUICheckout -Settings $Settings -Dir $dir -Before $before
        $moved = $true
    } else {
        Set-GitOrigin -Dir $dir -Url $comfy.Repo
    }
    try {
        $result = if ($Plan.Rebuild) { Reset-ComfyUIVenv -Settings $Settings -RepoRoot $RepoRoot } else { Install-ComfyUI -Settings $Settings -RepoRoot $RepoRoot }
    } catch {
        $reason = $_.Exception.Message
        if (-not $moved) { throw "ComfyUI's venv step failed: $reason" }
        $origin = if ($before.Origin) { "origin $($before.Origin)" } else { 'no origin' }
        # A failed rebuild puts the old venv back as it was, still on the Store Python, or says why it could not; that marker still fits the checkout put back
        # below.
        $kept = $false
        if ($Plan.Rebuild) {
            try {
                $base = Get-VenvBasePython -Venv ([IO.Path]::Combine($dir, '.venv'))
                $kept = [bool]($base -and $base.Store)
            } catch {
                Write-Verbose "The venv's pyvenv.cfg cannot be read, so its marker is marked stale: $($_.Exception.Message)"
            }
        }
        $left = ''
        if (-not $kept) {
            # The marker still names the old checkout's requirements, which would let install and start take the venv uv may have changed as up to date;
            # without its requirements hash they take it as stale.
            $markerPath = [IO.Path]::Combine($dir, '.venv\local-ai-install.json')
            try {
                if ([IO.File]::Exists($markerPath)) {
                    $marker = Read-LocalAIState -Path $markerPath
                    $marker.Remove('RequirementsSha256')
                    Write-LocalAIState -Path $markerPath -State $marker
                }
                $stale = "'local-ai install' installs the requirements of the checkout into it again, and start warns until then"
            } catch {
                $stale = ("its marker $markerPath could not be marked stale ($($_.Exception.Message)); remove RequirementsSha256 from it, then run 'local-ai install', " +
                    'which installs the requirements of the checkout into it again')
            }
            $left = " Its venv may hold packages uv had installed for $($comfy.Ref) by then; $stale."
        }
        try {
            Restore-ComfyUICheckout -Dir $dir -Before $before
            $back = "ComfyUI in $dir is back at $($before.Head) with $origin."
        } catch {
            $back = "Putting $dir back at $($before.Head) with $origin failed too: $($_.Exception.Message)"
        }
        throw "ComfyUI's venv step failed after the move to $($comfy.Ref): $reason $back$left"
    }
    # Other fields of the entry, such as Cloned, stay.
    $stamp = Read-LocalAIState -Path $Paths.InstallStamp
    $entry = if ($stamp['ComfyUI'] -is [hashtable]) { $stamp['ComfyUI'] } else { @{} }
    $entry['Dir'] = $result.Dir
    $entry['Commit'] = $result.Commit
    $entry['Ref'] = $(if ($result.Pinned) { $comfy.Ref } else { $null })
    $entry['Pinned'] = $result.Pinned
    $entry['Python'] = $result.Python
    $entry['PythonVersion'] = $result.PythonVersion
    $entry['Torch'] = $result.Torch
    if ($moved) {
        $entry['PreviousCommit'] = $before.Head
        $entry['PreviousBranch'] = $before.Branch
        $entry['PreviousOrigin'] = $before.Origin
    }
    $stamp['ComfyUI'] = $entry
    Write-LocalAIState -Path $Paths.InstallStamp -State $stamp
    $venvNote = if ($result.Rebuilt) { ", in a new venv on Python $($result.PythonVersion)" } else { '' }
    if ($moved) { return "ComfyUI: $($before.Head) -> $($comfy.Ref) ($($result.Commit)), torch $($result.Torch)$venvNote" }
    return "ComfyUI: $($comfy.Ref) ($($result.Commit)) with origin $($comfy.Repo), torch $($result.Torch)$venvNote"
}

# Return update's plan: @{ Components (each part's plan with Name, Display, Changes, Problem and Note, in the order update runs them: Open WebUI, ComfyUI with
# Images.Enabled, the file tools with Files.Root, the model, and the checkpoint once ComfyUI is set up); Tools (with $Tools, Get-WingetUpdatePlan's list); ToolDir
# (uv's tool folder) }, judged against install-stamp.json $Stamp and state.json $State. Warns for each part a Note leaves out. Reads only; Ollama must answer.
function Get-LocalAIUpdatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Tools
    )
    $components = New-Object System.Collections.Generic.List[hashtable]
    $components.Add((Get-OpenWebUIUpdatePlan -Settings $Settings -Stamp $Stamp))
    $comfy = $null
    if ($Settings.Images.Enabled) {
        $comfy = Get-ComfyUIUpdatePlan -Settings $Settings -Stamp $Stamp -RepoRoot $RepoRoot
        $components.Add($comfy)
    }
    if ($Settings.Files.Root) { $components.Add((Get-FilesUpdatePlan -Settings $Settings -Stamp $Stamp -RepoRoot $RepoRoot)) }
    $components.Add((Get-ModelUpdatePlan -Settings $Settings -Paths $Paths -Stamp $Stamp -RepoRoot $RepoRoot))
    # The checkpoint lies in ComfyUI.Dir, which install sets up first.
    if ($comfy -and -not $comfy.Note) { $components.Add((Get-CheckpointUpdatePlan -Settings $Settings -Stamp $Stamp -State $State)) }
    foreach ($component in $components) { if ($component.Note) { Write-Warning "$($component.Display): $($component.Note)" } }
    $upgrades = @()
    if ($Tools) { $upgrades = @(Get-WingetUpdatePlan -Settings $Settings -Stamp $Stamp) }
    return @{ Components = $components.ToArray(); Tools = $upgrades; ToolDir = (Get-UvToolDir) }
}

# Print update's plan $Plan: first the launcher's own change $Launcher (Get-LauncherActivation) when there is one, then each change as '<part>: <old> -> <new>',
# each tool upgrade, what update does around them, and for an Ollama upgrade a warning that its installer stops the Ollama app. Returns nothing.
function Write-LocalAIUpdatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][hashtable]$Paths,
        [AllowNull()][hashtable]$Launcher
    )
    Write-Host ''
    Write-Host 'Update plan:'
    if ($Launcher) { Write-Host "  $($Launcher.Line)" }
    foreach ($component in $Plan.Components) { foreach ($change in $component.Changes) { Write-Host "  $($component.Display): $change" } }
    foreach ($tool in $Plan.Tools) { Write-Host "  $($tool.Display): $($tool.Upgrade.Installed) -> $($tool.Upgrade.Available), with winget upgrade $($tool.Package.Id)" }
    Write-Host 'update first stops what the launcher runs, then starts the stack to check it, and leaves it running only when it ran before.'
    if (@($Plan.Components | Where-Object { $_.Name -eq 'OpenWebUI' -and $_.Reinstall }).Count -gt 0) {
        Write-Host "Open WebUI's data is backed up to $($Paths.Backups) first, and Open WebUI is put back as it was when the new version fails the check."
    }
    foreach ($comfy in @($Plan.Components | Where-Object { $_.Name -eq 'ComfyUI' -and $_.Rebuild })) {
        Write-Host ("ComfyUI's new venv gets the same pinned packages, from uv's cache where it holds them. The old venv is moved aside to " +
            "$($comfy.Dir).local-ai-old-venv and deleted once the new one passes the torch check, or put back when it does not. Models, input, output, user " +
            'and custom_nodes stay; packages added to the venv by hand are not carried over.')
    }
    if (@($Plan.Tools | Where-Object { $_.Name -eq 'Ollama' }).Count -gt 0) {
        Write-Warning "Ollama's installer stops the Ollama app in the tray, and with it any model it has loaded; update starts the app again afterwards."
    }
}

# The update verb, with the PC kept awake: when anything differs from its pin (Get-LocalAIUpdatePlan), show the plan and ask, stop the stack but not Ollama,
# update each part and, with -Tools, the winget packages; then start the stack to check it, roll Open WebUI back when the new version fails, offer to remove
# superseded aliases while Ollama still answers, and leave the stack running only when it ran before. Ollama ends as update found it: the app its first wait
# started, recorded as start records it, is quit again unless the stack runs, also after an early return or a throw. In the run another launcher version
# handed over to (Context.ActivateLauncher, Get-LauncherActivation), the plan starts with the launcher's change, asked about with the parts, and a yes makes
# this version active (Enable-LauncherVersion) once the stop and the check for busy programs passed, before any part changes, and without a stop when
# nothing else differs; the launcher's Start menu shortcuts then follow it (Update-LocalAIShortcut). Context.Warnings count as warnings.
# Returns 0; 2 when degraded or declined, or when that quit fails; 1 on a failure.
function Update-LocalAI {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A launcher verb, which asks through Confirm-LocalAIAction instead of -WhatIf.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'stopDone',
        Justification = 'The finally reads what the dot-sourced body sets.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $settings = $Context.Settings
    $paths = $Context.Paths
    # Those of the launcher's own update before this, such as a release check GitHub did not answer.
    $warned = @(@($Context.Warnings) | Where-Object { $_ })
    # -WarningVariable also collects warnings a nested call silenced and then repeated, so distinct texts are counted.
    $count = { @($warned | ForEach-Object { [string]$_ } | Select-Object -Unique).Count }
    # The smoke test opens no browser, and Launched names what it started.
    $launchedNames = New-Object System.Collections.Generic.List[string]
    $quiet = @{}
    foreach ($key in $Context.Keys) { $quiet[$key] = $Context[$key] }
    $quiet['NoBrowser'] = $true
    $quiet['Launched'] = $launchedNames
    # The finally below reads both, and sets $quitFailed when it cannot quit the Ollama app the first wait started.
    $firstWait = $null
    $stopDone = $false
    $quitFailed = $false
    Set-LocalAIKeepAwake -Enabled $true
    try {
        # Dot-sourced, so its variables are this function's and each return leaves only the block, whose result the finally can still change.
        $code = . {
            # Before anything changes: a run handed over to must be that version, whose folder matches its manifest.
            $activation = $null
            if ($Context.ActivateLauncher) { $activation = Get-LauncherActivation -Context $Context }
            Update-SessionPath
            # Before the wait, which may start the Ollama app for nothing.
            $stamp = Read-LocalAIState -Path $paths.InstallStamp
            $missing = @(foreach ($key in 'Ollama', 'Model', 'OpenWebUI') { if ($stamp[$key] -isnot [hashtable]) { $key } })
            if ($missing.Count -gt 0 -and -not $activation) {
                Write-Host "install-stamp.json does not record $($missing -join ', '), so there is nothing to update yet. Run 'local-ai install' first." -ForegroundColor Red
                return 1
            }
            if ($missing.Count -gt 0) {
                # Only the launcher can change before install has set up the parts.
                Write-Host ''
                Write-Host 'Update plan:'
                Write-Host "  $($activation.Line)"
                Write-Host "install-stamp.json does not record $($missing -join ', '), so update changes only the launcher; 'local-ai install' sets up the rest."
                if (-not (Confirm-LocalAIAction -Question 'Update these now?')) {
                    Write-Host "Nothing was changed; the launcher stays at $($activation.From)." -ForegroundColor Yellow
                    return 2
                }
                $null = Enable-LauncherVersion -InstallRoot $activation.InstallRoot -Tag $activation.To -StatePath $paths.State
                $warned = @($warned) + @(Update-LocalAIShortcut -Context $Context)
                Write-Host "The launcher is $($activation.To) now. Run 'local-ai install' to set up the rest." -ForegroundColor Green
                if ((& $count) -gt 0) { return 2 }
                return 0
            }
            $url = Resolve-OllamaUrl -Setting $settings.Ollama.Url
            Assert-OllamaCliUrl -Url $url
            $firstWait = Wait-OllamaServer -Url $url -PassThru -How 'update'
            # An Ollama that answered without this wait's start, the user's own or one an earlier start recorded, stays running after update.
            $ollamaWasUp = -not $firstWait.Started
            # As start records it, at once, so the app this wait started is quit again also when update ends early. Otherwise the recorded Url and Alias stay
            # until the stack is stopped below, as that stop unloads the alias they name.
            if ($firstWait.App) { $null = Save-OllamaRecord -Path $paths.State -Url $url -Alias $settings.Model.Alias -App $firstWait.App }
            Write-Host 'Comparing what is installed with the pins...'
            $plan = Get-LocalAIUpdatePlan -Settings $settings -Paths $paths -Stamp $stamp -State (Read-LocalAIState -Path $paths.State) -RepoRoot $Context.RepoRoot `
                -Tools:([bool]$Context.Tools) -WarningVariable +warned
            $blocked = @($plan.Components | Where-Object { $_.Problem })
            if ($blocked.Count -gt 0) {
                foreach ($component in $blocked) { Write-Host "$($component.Display): $($component.Problem)" -ForegroundColor Red }
                Write-Host 'Update changed nothing.' -ForegroundColor Red
                return 1
            }
            $pending = @($plan.Components | Where-Object { $_.Changes.Count -gt 0 })
            if ($pending.Count -eq 0 -and @($plan.Tools).Count -eq 0) {
                if ($activation) {
                    # The launcher alone, which needs no stop: what runs keeps running, and the next start runs the new version.
                    Write-Host 'Every part matches its pin.' -ForegroundColor Green
                    Write-Host ''
                    Write-Host 'Update plan:'
                    Write-Host "  $($activation.Line)"
                    Write-Host 'Only the launcher changes, so what runs keeps running; the next start runs the new version.'
                    if (-not (Confirm-LocalAIAction -Question 'Update these now?')) {
                        Write-Host "Nothing was changed; the launcher stays at $($activation.From)." -ForegroundColor Yellow
                        return 2
                    }
                    $null = Enable-LauncherVersion -InstallRoot $activation.InstallRoot -Tag $activation.To -StatePath $paths.State
                    $warned = @($warned) + @(Update-LocalAIShortcut -Context $Context)
                    Write-Host "The launcher is $($activation.To) now, and everything matches its pin." -ForegroundColor Green
                } else {
                    Write-Host 'Everything matches its pin.' -ForegroundColor Green
                }
                $null = Remove-SupersededAlias -Settings $settings -Url $url -WarningVariable +warned
                if ((& $count) -gt 0) { return 2 }
                return 0
            }
            Write-LocalAIUpdatePlan -Plan $plan -Paths $paths -Launcher $activation
            if (-not (Confirm-LocalAIAction -Question 'Update these now?')) {
                $stays = if ($activation) { " The launcher stays at $($activation.From)." } else { '' }
                Write-Host "Nothing was changed, so the parts above still differ from their pins.$stays" -ForegroundColor Yellow
                return 2
            }

            $before = @(Get-LocalAIRunningService -Path $paths.State)
            # Ollama stays: the model step and the check need it.
            if ((Stop-LocalAI -Context $Context -KeepOllama) -ne 0) {
                Write-Host ("Update changed nothing, because not everything the launcher runs could be stopped; see above. Run 'local-ai stop', then " +
                    'update again.') -ForegroundColor Red
                return 1
            }
            # 'local-ai stop' stops only what state.json records, not what another program started, for example. Windows locks what a running Python loaded,
            # and a uv reinstall that cannot remove it leaves a broken environment that 'uv tool list' still lists.
            $folders = New-Object System.Collections.Generic.List[string]
            $programs = New-Object System.Collections.Generic.List[string]
            foreach ($component in $pending) {
                if ($component.Name -eq 'OpenWebUI' -and $component.Reinstall) {
                    $folders.Add((Join-Path $plan.ToolDir 'open-webui'))
                    $programs.Add([string]$component.Tool.Path)
                }
                if ($component.Name -eq 'ComfyUI') { $folders.Add($component.Dir) }
                if ($component.Name -eq 'Files') { $folders.Add((Join-Path $plan.ToolDir 'mcpo')) }
            }
            $busy = @()
            if ($folders.Count -gt 0) { $busy = @(Get-BusyProcess -Folder $folders.ToArray() -File $programs.ToArray()) }
            if ($busy.Count -gt 0) {
                $what = @($busy | ForEach-Object { "$($_.Name) (PID $($_.Id), $($_.Path))" }) -join ', '
                Write-Host ("Update changed nothing: $what still run from what it would replace, although 'local-ai stop' stopped what the launcher started; " +
                    'another program may have started them. Close them, then run update again.') -ForegroundColor Red
                if ($before.Count -gt 0) { $null = Start-LocalAI -Context $quiet }
                return 1
            }
            # The launcher first, before any part changes, so that the parts follow the pins of the version that is active. Only once the stop and the
            # check for busy programs passed, so that a refusal there leaves current as it was and update -Rollback can run again.
            if ($activation) {
                try {
                    $null = Enable-LauncherVersion -InstallRoot $activation.InstallRoot -Tag $activation.To -StatePath $paths.State
                } catch {
                    $failed = $_
                    # As when a program is busy: what ran before runs again, and the error stays this one.
                    if ($before.Count -gt 0) {
                        try { $null = Start-LocalAI -Context $quiet } catch { Write-Warning "Could not start the stack again: $($_.Exception.Message)" }
                    }
                    throw $failed
                }
                $warned = @($warned) + @(Update-LocalAIShortcut -Context $Context)
                Write-Host "The launcher is $($activation.To) now; the parts come next."
            }

            $done = New-Object System.Collections.Generic.List[string]
            $failure = $null
            $webChange = $null
            # In the plan's order: Open WebUI after a backup, ComfyUI moved to its tag, the file tools, the model and the checkpoint; then uv, Git, Node.js and
            # Ollama last with winget. The backups are pruned only once the new Open WebUI passed the check below.
            try {
                foreach ($component in $pending) {
                    switch ($component.Name) {
                        'OpenWebUI' {
                            $result = Update-OpenWebUITool -Settings $settings -Paths $paths -Plan $component -ToolDir $plan.ToolDir -WarningVariable +warned
                            if ($result.Previous) { $webChange = $result }
                            $done.Add($result.Done)
                        }
                        'ComfyUI' {
                            $done.Add((Update-ComfyUICheckout -Settings $settings -Paths $paths -Plan $component -RepoRoot $Context.RepoRoot -WarningVariable +warned))
                        }
                        'Files' {
                            $stamp = Read-LocalAIState -Path $paths.InstallStamp
                            $recorded = $stamp['Files']
                            $stamp['Files'] = Install-FilesServer -Settings $settings -Paths $paths -RepoRoot $Context.RepoRoot -Stamp $stamp -Recorded $recorded `
                                -WarningVariable +warned
                            Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                            $done.Add("File tools: mcpo $($recorded.McpoVersion) -> $($stamp.Files.McpoVersion), files server $($recorded.ServerVersion) -> $($stamp.Files.ServerVersion)")
                        }
                        'Model' {
                            # A changed Model.Sha256 pulls the weights again.
                            Test-ChatModelSpace -Settings $settings -Blobs @(Get-OllamaModelBlob -Name $settings.Model.Source) -WarningVariable +warned
                            $state = Install-ChatModel -Settings $settings -Paths $paths -State (Read-LocalAIState -Path $paths.State) -Url $url -RepoRoot $Context.RepoRoot `
                                -WarningVariable +warned
                            Write-LocalAIState -Path $paths.State -State $state
                            $stamp = Read-LocalAIState -Path $paths.InstallStamp
                            $stamp['Model'] = @{
                                Alias           = $state.Model.Alias
                                BaseDigest      = $state.Model.BaseDigest
                                ProjectorDigest = $state.Model.ProjectorDigest
                                ModelfileSha256 = $state.Model.ModelfileSha256
                            }
                            Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                            $done.Add("Model: $($state.Model.Alias) on $($state.Model.BaseDigest), from $($state.Model.Modelfile)")
                        }
                        'Checkpoint' {
                            $state = Read-LocalAIState -Path $paths.State
                            $images = $state['Images']
                            if ($images -isnot [hashtable]) { $images = @{} }
                            $verified = $images['VerifiedFiles']
                            if ($verified -isnot [hashtable]) { $verified = @{} }
                            $checkpoint = Install-ImageModel -Settings $settings -Verified $verified -WarningVariable +warned
                            $state['Images'] = @{ VerifiedFiles = $verified }
                            Write-LocalAIState -Path $paths.State -State $state
                            $stamp = Read-LocalAIState -Path $paths.InstallStamp
                            $stamp['Images'] = @{ File = $settings.Images.File; Sha256 = $checkpoint.Sha256 }
                            Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                            $done.Add("Checkpoint: $($settings.Images.File), checked against Images.Sha256")
                        }
                    }
                }
                foreach ($tool in $plan.Tools) {
                    $appsBefore = $null
                    $ownedBefore = $false
                    $since = [long]0
                    if ($tool.Name -eq 'Ollama') {
                        Write-Host 'Upgrading Ollama last; its installer stops the Ollama app and any model it has loaded.' -ForegroundColor Yellow
                        # The installer starts the app again with a new PID. That one is local-ai's only when the app local-ai started ran until now.
                        $entry = (Read-LocalAIState -Path $paths.State)['Ollama']
                        if ($entry -is [hashtable] -and $entry.App -is [hashtable] -and (Test-RecordedProcess -Record $entry.App)) {
                            $ownedBefore = $true
                            $ownedId = [int]$entry.App.Pid
                            try {
                                $appsBefore = @(Get-OllamaAppProcess | Where-Object { [int]$_.Id -ne $ownedId })
                            } catch {
                                Write-Verbose "The Ollama apps cannot be listed, so update records no app the Ollama installer starts: $($_.Exception.Message)"
                            }
                            $since = [DateTime]::UtcNow.AddSeconds(-1).Ticks
                        }
                    }
                    $outcome = Update-WingetPackage -Package $tool.Package -LogDir $paths.Logs -WarningVariable +warned
                    if (@('upgraded', 'restart') -contains $outcome) { $done.Add("$($tool.Display): $($tool.Upgrade.Installed) -> $($tool.Upgrade.Available)") }
                    if ($tool.Name -eq 'Ollama') {
                        $wait = Wait-OllamaServer -Url $url -PassThru -How 'update'
                        $version = $wait.Version
                        # Only in place of the app local-ai started, so one that replaces the user's own Ollama stays one stop leaves running.
                        $app = $null
                        if ($ownedBefore) {
                            $app = $wait.App
                            if (-not $app -and $null -ne $appsBefore) {
                                $app = Get-OllamaOwnStart -Before $appsBefore -Since $since -Url $url -ExpectedPath ([string](Resolve-OllamaAppPath)) -How 'update'
                                if ($app) { Write-Host "The Ollama installer started the Ollama app again (PID $($app.Pid)); local-ai stop quits it." }
                            }
                        } elseif ($wait.App) {
                            Write-Host ("The Ollama app local-ai started (PID $($wait.App.Pid)) replaces one that state.json does not record as local-ai's, so " +
                                'local-ai stop leaves it running.')
                        }
                        # Without a new app, the one recorded before stays only while it still runs, as when winget changed nothing. The stop above unloaded
                        # the alias the recorded Url and Alias named, so the new ones hold from here.
                        $null = Save-OllamaRecord -Path $paths.State -Url $url -Alias $settings.Model.Alias -App $app
                        $stamp = Read-LocalAIState -Path $paths.InstallStamp
                        $stamp['Ollama'] = @{ Version = $version }
                        Write-LocalAIState -Path $paths.InstallStamp -State $stamp
                    }
                }
            } catch {
                # The parts done so far stay; the smoke test below checks them.
                $failure = $_.Exception.Message
                Write-Host "Error: $failure" -ForegroundColor Red
            }

            Write-Host ''
            Write-Host 'Starting the stack to check the update...'
            $startError = $null
            $startCode = $null
            try {
                $startCode = @(Start-LocalAI -Context $quiet -WarningVariable +warned)[-1]
            } catch {
                $startError = $_.Exception.Message
            }
            # Start-LocalAI returns 1 when Open WebUI does not come up, after stopping every service it launched.
            $startFailed = [bool]$startError -or $startCode -eq 1
            $expected = if ($webChange) { $settings.OpenWebUI.Version } else { [string](Read-LocalAIState -Path $paths.InstallStamp)['OpenWebUI'].Version }
            $check = Test-LocalAIUpdateSmoke -Settings $settings -Paths $paths -OllamaUrl $url -OpenWebUIVersion $expected
            $rolledBack = $false
            if ($check.OpenWebUI) {
                $why = ([string]$check.OpenWebUI).TrimEnd()
                # A .NET message such as 'Unable to connect to the remote server' ends without a period, and more text follows.
                if ($why -notmatch '[.!?]\z') { $why += '.' }
                if ($startError) { $why = "$startError $why" } elseif ($startFailed) { $why += ' The start stopped with the error shown above.' }
                if ($webChange -and $launchedNames.Contains('OpenWebUI')) {
                    Write-Host "Open WebUI fails the check: $why Putting back $($webChange.Previous.Version)..." -ForegroundColor Red
                    $undone = Undo-OpenWebUIUpdate -Context $Context -Change $webChange
                    $rolledBack = $true
                    $null = $done.Remove($webChange.Done)
                    $why = "Open WebUI $($settings.OpenWebUI.Version) failed the check after the update: $why $undone"
                } elseif ($webChange) {
                    # It never ran, so its data is as the backup holds it, and a rollback would undo the update for a problem elsewhere, such as Ollama.
                    $why = ("The check did not get to start Open WebUI $($settings.OpenWebUI.Version): $why It stays installed, its data is unchanged and the backup " +
                        "$($webChange.Backup) stays; fix that, then run 'local-ai start'.")
                } else {
                    $why = "Open WebUI fails the check after the update: $why"
                }
                $failure = if ($failure) { "$failure $why" } else { $why }
            } elseif ($webChange) {
                # Only now, so a failed update never loses an older backup, and never the one it made.
                foreach ($removed in @(Remove-OldOpenWebUIBackup -BackupRoot $paths.Backups -Keep $settings.Update.KeepBackups -Current $webChange.Backup -WarningVariable +warned)) {
                    Write-Host "Deleted the older backup $removed, as Update.KeepBackups keeps $($settings.Update.KeepBackups)."
                }
            }
            # Before the stop below, which may quit the Ollama app; a rollback adds to a failure set above, so it never reaches the offer.
            if (-not $failure) { $null = Remove-SupersededAlias -Settings $settings -Url $url -WarningVariable +warned }
            if ($rolledBack -and $before.Count -gt 0) {
                $again = $null
                try {
                    $again = @(Start-LocalAI -Context $quiet)[-1]
                } catch {
                    Write-Host "Could not start the stack again: $($_.Exception.Message)" -ForegroundColor Red
                }
                if (-not ($again -eq 0 -or $again -eq 2)) {
                    $failure += " The stack, which ran before the update, did not start again after the rollback; see above, then run 'local-ai start'."
                }
            } elseif ($before.Count -eq 0) {
                # Also after a rollback, whose stop kept Ollama: the app this update started goes too, an Ollama that answered at its start stays.
                $stopDone = $true
                Write-Host 'Stopping the stack again, since it did not run before the update...'
                if ((Stop-LocalAI -Context $Context -KeepOllama:$ollamaWasUp) -ne 0) {
                    Write-Warning "Not everything could be stopped again; run 'local-ai stop'." -WarningVariable +warned
                }
            } else {
                # As one unit: Open WebUI reads where images and the file tools are only when it starts, so stopping a service the check started besides
                # would leave it pointing at a stopped one.
                Write-Host 'The stack ran before the update, so what the check started stays running.'
            }
            if ($startFailed -and $check.Problems.Count -gt 0) {
                # Their answers would only say that the failed start stopped them again.
                Write-Host 'The other services were not checked, since the start stops them again when Open WebUI does not come up.'
            } else {
                foreach ($problem in $check.Problems) { Write-Warning $problem -WarningVariable +warned }
            }
            if ($done.Count -gt 0) {
                Write-Host ''
                Write-Host 'Updated:'
                foreach ($line in $done) { Write-Host "  $line" }
            }
            if ($failure) {
                Write-Host "Update failed: $failure" -ForegroundColor Red
                # The parts stay at the pins of the version now active, as the check judged them.
                if ($activation -and (ConvertTo-LauncherVersion -Tag $activation.From)) { Write-Host "To go back to the launcher $($activation.From), run 'local-ai update -Rollback'." }
                return 1
            }
            $warnings = & $count
            if ($warnings -gt 0) {
                Write-Host "Update finished with $warnings warning(s); see above." -ForegroundColor Yellow
                return 2
            }
            Write-Host 'Update finished; everything matches its pin.' -ForegroundColor Green
            return 0
        }
    } finally {
        try {
            # After an early return or a throw, the Ollama app the first wait started goes again, unless the stack runs on it.
            if (-not $stopDone -and $firstWait -and $firstWait.App -and @(Get-LocalAIRunningService -Path $paths.State).Count -eq 0) {
                Write-Host 'Quitting the Ollama app update started, since Ollama did not run before the update...'
                if ((Stop-LocalAI -Context $Context) -ne 0) {
                    $quitFailed = $true
                    Write-Warning "The Ollama app update started could not be quit; see above, then run 'local-ai stop'."
                }
            }
        } catch {
            $quitFailed = $true
            Write-Warning "The Ollama app update started could not be quit: $($_.Exception.Message) Run 'local-ai stop'."
        } finally {
            Set-LocalAIKeepAwake -Enabled $false
        }
    }
    # Reached only after a return, as a throw goes on past the finally. An Ollama app left running is a warning, so it turns a 0 into a 2.
    if ($quitFailed -and $code -eq 0) { $code = 2 }
    return $code
}

# Return the settings uninstall goes by when Get-LocalAISettings refuses them: the defaults at $DefaultsPath with every value of $UserPath that merges, %VAR% expanded and
# not validated, adding one text per value or file it skipped to $Problems. A user file that does not load leaves the defaults, and sets $UserLoaded to $false (else
# $true, also without a user file), since those defaults may name folders the launcher never used; throws when the defaults do not load.
function Get-LocalAIFallbackSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$DefaultsPath,
        [string]$UserPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems,
        [ref]$UserLoaded
    )
    $settings = Import-LocalAIDataFile -Path $DefaultsPath
    $loaded = $true
    if ($UserPath -and (Test-Path -LiteralPath $UserPath -PathType Leaf)) {
        try {
            $user = Import-LocalAIDataFile -Path $UserPath
        } catch {
            $loaded = $false
            $Problems.Add($_.Exception.Message)
        }
        if ($loaded) {
            try {
                Merge-LocalAISetting -Base $settings -Overlay $user -OpenMaps @('OpenWebUI.Env') -Errors $Problems
            } catch {
                $loaded = $false
                $Problems.Add($_.Exception.Message)
            }
        }
    }
    if ($UserLoaded) { $UserLoaded.Value = $loaded }
    return Expand-LocalAISetting -Value $settings
}

# Return why uninstall -RemoveData must not delete the folder $Path, or $null when it may: it must be a full path on a drive letter with no junction or symbolic link on it,
# itself included, must not be or hold a drive root, a profile, Windows or temporary folder, the repository $RepoRoot or a folder in $Keep (name -> path), and must not lie
# in $RepoRoot. Compares long names (Resolve-OnDiskPath) without case. Reads only.
function Get-LocalAIRemovalProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot,
        [hashtable]$Keep = @{}
    )
    if ($Path -notmatch '^[A-Za-z]:\\') { return 'it is not a full path on a drive letter' }
    $resolved = Resolve-OnDiskPath -Path $Path
    $full = $resolved.Path.TrimEnd('\')
    if ($full -match '^[A-Za-z]:\z') { return 'it is a drive root' }
    if ($resolved.Link) { return "$($resolved.Link) on its path is a junction or symbolic link, so it may lead elsewhere" }
    $protected = New-Object System.Collections.Generic.List[hashtable]
    foreach ($name in 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP', 'SystemRoot', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData', 'PUBLIC', 'OneDrive') {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($value) { $protected.Add(@{ Name = "%$name%"; Path = $value }) }
    }
    # The shell's own folders, also when this window's variables point elsewhere.
    foreach ($folder in 'UserProfile', 'LocalApplicationData', 'ApplicationData', 'Desktop', 'MyDocuments', 'MyPictures', 'MyMusic', 'MyVideos', 'Windows', 'ProgramFiles',
        'CommonApplicationData') {
        $value = [Environment]::GetFolderPath($folder)
        if ($value) { $protected.Add(@{ Name = "the $folder folder"; Path = $value }) }
    }
    if ($env:USERPROFILE) {
        foreach ($child in 'Downloads', '.ollama', '.cache', '.local') { $protected.Add(@{ Name = "%USERPROFILE%\$child"; Path = Join-Path $env:USERPROFILE $child }) }
    }
    $protected.Add(@{ Name = 'the launcher repository'; Path = $RepoRoot })
    foreach ($name in $Keep.Keys) { if ($Keep[$name]) { $protected.Add(@{ Name = [string]$name; Path = [string]$Keep[$name] }) } }
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    foreach ($entry in $protected) {
        if ($entry.Path -notmatch '^[A-Za-z]:\\') { continue }
        $other = (Resolve-OnDiskPath -Path $entry.Path).Path.TrimEnd('\')
        if ($full.Equals($other, $ignoreCase) -or $other.StartsWith($full + '\', $ignoreCase)) { return "it is or holds $($entry.Name), $other" }
    }
    $repo = (Resolve-OnDiskPath -Path $RepoRoot).Path.TrimEnd('\')
    if ($full.StartsWith($repo + '\', $ignoreCase)) { return "it lies in the launcher repository $repo" }
    return $null
}

# Delete the folder $Path for uninstall: rename it first to '<name>.local-ai-removing-<yyyyMMddHHmmss>' beside it, which Windows refuses while a program holds a file in it
# open or works in it, so a folder in use stays whole, then Remove-LocalAITree, which removes the links inside as links. A missing $Path is no error; throws naming the
# folder, and where the rest is when the delete stopped part-way.
function Remove-LocalAIFolder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the uninstall verb, which asks before it changes anything.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $full = Resolve-FolderPath -Path $Path
    if (-not [IO.Directory]::Exists($full)) { return }
    $aside = '{0}.local-ai-removing-{1:yyyyMMddHHmmss}' -f $full, (Get-Date)
    try {
        [IO.Directory]::Move($full, $aside)
    } catch {
        $reason = $_.Exception
        while ($reason.InnerException) { $reason = $reason.InnerException }
        throw "Cannot delete ${full}: Windows refuses to rename it, as when a program still has a file in it open ($($reason.Message)). Close that program, then try again."
    }
    try {
        Remove-LocalAITree -Path $aside
    } catch {
        throw "Deleting $full stopped part-way: $($_.Exception.Message) What is left is in $aside; delete it once nothing uses it."
    }
}

# Throw naming the processes that Get-BusyProcess finds running a program below the folder $Path or one of the files $File, which keep Windows from deleting what they
# loaded; 'local-ai stop' does not stop what another program started. Returns nothing when none runs.
function Assert-LocalAIIdle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][AllowNull()][string[]]$File = @()
    )
    $busy = @(Get-BusyProcess -Folder $Path -File @($File | Where-Object { $_ }))
    if ($busy.Count -gt 0) {
        throw ("$(@($busy | ForEach-Object { "$($_.Name) (PID $($_.Id))" }) -join ', ') still runs from it, although 'local-ai stop' stopped what the launcher " +
            'started. Close it, then run uninstall again.')
    }
}

# Run 'uv tool uninstall $Name' with UV_TOOL_DIR set to $ToolDir for this call only, so uv looks where install put the tool, and return 'removed', or 'absent' when uv says
# it is not installed. Throws with uv's text on any other failure.
function Invoke-UvToolUninstall {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ToolDir
    )
    $saved = [Environment]::GetEnvironmentVariable('UV_TOOL_DIR', 'Process')
    $said = New-Object System.Collections.Generic.List[string]
    try {
        [Environment]::SetEnvironmentVariable('UV_TOOL_DIR', $ToolDir, 'Process')
        # uv 0.13.6 exits 2 with "error: `<name>` is not installed".
        $code = Invoke-Native -FilePath 'uv' -ArgumentList 'tool', 'uninstall', $Name -SuccessCode 0, 2 -Capture $said
    } catch {
        throw "$($_.Exception.Message) uv said: $(@($said | Where-Object { $_.Trim() }) -join ' ')"
    } finally {
        [Environment]::SetEnvironmentVariable('UV_TOOL_DIR', $saved, 'Process')
    }
    $text = @($said | Where-Object { $_.Trim() }) -join ' '
    if ($code -eq 0) { return 'removed' }
    if ($text -match 'is not installed') { return 'absent' }
    throw "'uv tool uninstall $Name' failed with exit code $code. uv said: $text"
}

# Remove the model $Name from Ollama with 'ollama rm'; the server must be up. Throws with what ollama said, without the terminal control sequences it writes, on a failure.
function Remove-OllamaModel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the uninstall verb, which asks before it changes anything.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $said = New-Object System.Collections.Generic.List[string]
    try {
        $null = Invoke-Native -FilePath 'ollama' -ArgumentList 'rm', $Name -Capture $said
    } catch {
        # Ollama 0.40.11 writes them even when its output is captured.
        $text = @($said | ForEach-Object { $_ -replace '\x1b\[[0-9;?]*[A-Za-z]', '' } | Where-Object { $_.Trim() }) -join ' '
        throw "$($_.Exception.Message) ollama said: $text"
    }
}

# Return what uninstall removes, changing nothing: @{ Items (in removal order, each @{ Kind (Shortcuts, UvTool, Folder, File or Alias); Text; Path; Name; ToolDir; Program;
# Stamp (its install-stamp.json entry) }); Kept (one text per part it leaves, and why); Source (the model the alias was made from) }, judged from $Settings, $Stamp,
# $State and $Paths. A uv tool counts only when $Stamp records it, and a ComfyUI venv only when its marker says install created it.
function Get-LocalAIUninstallPlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][hashtable]$State
    )
    $items = New-Object System.Collections.Generic.List[hashtable]
    $kept = New-Object System.Collections.Generic.List[string]
    # Combine, unlike Join-Path, does not refuse a drive this PC does not have now, such as an unplugged disk.
    $folder = [string]$Settings.Shortcuts.Folder
    if ($folder -match '^[A-Za-z]:\\') {
        $folder = Resolve-FolderPath -Path $folder
        $present = @(Get-LocalAIShortcutSpec -Settings $Settings -Paths $Paths | Where-Object { [IO.File]::Exists([IO.Path]::Combine($folder, $_.Name)) } | ForEach-Object { $_.Name })
        if ($present.Count -gt 0) { $items.Add(@{ Kind = 'Shortcuts'; Path = $folder; Text = "the Start menu shortcuts $($present -join ', ') in $folder" }) }
    } elseif ($folder) {
        $kept.Add("the shortcuts: Shortcuts.Folder '$folder' is not a full path on a drive letter.")
    }

    # Only a tool whose install-stamp.json entry exists, in the folder it records; an older entry without one is looked for beside mcpo, which install
    # puts beside open-webui, then where uv puts tools now.
    $web = if ($Stamp['OpenWebUI'] -is [hashtable]) { $Stamp['OpenWebUI'] } else { $null }
    $files = if ($Stamp['Files'] -is [hashtable]) { $Stamp['Files'] } else { $null }
    $uvDir = $null
    if (Get-Command -Name 'uv' -CommandType Application -ErrorAction SilentlyContinue) {
        try { $uvDir = Get-UvToolDir } catch { Write-Verbose "uv names no tool folder: $($_.Exception.Message)" }
    }
    $tools = @(
        @{ Name = 'open-webui'; Entry = $web; Dirs = @($web.ToolDir, $files.ToolDir, $uvDir); Display = ('Open WebUI ' + $web.Version).Trim(); Program = [string]$web.Path
            Stamp = 'OpenWebUI' }
        @{ Name = 'mcpo'; Entry = $files; Dirs = @($files.ToolDir, $uvDir); Display = ('mcpo ' + $files.McpoVersion).Trim() + ', which serves the file tools'
            Program = [string]$files.McpoPath; Stamp = 'Files' }
    )
    foreach ($tool in $tools) {
        $found = @($tool.Dirs | Where-Object { $_ -and [IO.Directory]::Exists([IO.Path]::Combine([string]$_, $tool.Name)) } | Select-Object -First 1)
        if ($found.Count -eq 0) { continue }
        $path = [IO.Path]::Combine([string]$found[0], $tool.Name)
        if ($tool.Entry -is [hashtable]) {
            $items.Add(@{ Kind = 'UvTool'; Name = $tool.Name; ToolDir = [string]$found[0]; Path = $path; Program = $tool.Program; Stamp = $tool.Stamp
                    Text = "$($tool.Display): the uv tool $($tool.Name) in $path" })
        } else {
            $kept.Add("the uv tool $($tool.Name) in ${path}: install-stamp.json does not record it, so uninstall leaves it; 'uv tool uninstall $($tool.Name)' removes it.")
        }
    }

    $comfyDirs = New-Object System.Collections.Generic.List[string]
    $recorded = if ($Stamp['ComfyUI'] -is [hashtable]) { [string]$Stamp['ComfyUI'].Dir } else { '' }
    $recordedDir = if ($recorded -match '^[A-Za-z]:\\') { Resolve-FolderPath -Path $recorded } else { '' }
    foreach ($candidate in @($recorded, [string]$Settings.ComfyUI.Dir)) {
        if ($candidate -match '^[A-Za-z]:\\') {
            $dir = Resolve-FolderPath -Path $candidate
            if (@($comfyDirs | Where-Object { $_ -eq $dir }).Count -eq 0) { $comfyDirs.Add($dir) }
        }
    }
    foreach ($dir in $comfyDirs) {
        $venv = [IO.Path]::Combine($dir, '.venv')
        $markerPath = [IO.Path]::Combine($venv, 'local-ai-install.json')
        if ([IO.Directory]::Exists($venv)) {
            $marker = @{}
            try { $marker = Read-LocalAIState -Path $markerPath } catch { $marker = @{} }
            if ($marker['CreatedVenv'] -eq $true) {
                # The venv of the checkout $Stamp records belongs to its ComfyUI entry, which then names a python.exe that is gone.
                $owner = if ($recordedDir -and $dir.Equals($recordedDir, [StringComparison]::OrdinalIgnoreCase)) { 'ComfyUI' } else { $null }
                $items.Add(@{ Kind = 'Folder'; Path = $venv; Text = "ComfyUI's venv $venv, which install created"; Stamp = $owner })
            } elseif ([IO.File]::Exists($markerPath)) {
                $kept.Add("ComfyUI's venv ${venv}: install found it in place, as another program left it, and only installed into it. Delete it yourself once nothing needs it.")
            }
        }
        foreach ($leftover in @(($dir + '.local-ai-clone'), [IO.Path]::Combine($dir, 'models\.local-ai-download'))) {
            if ([IO.Directory]::Exists($leftover)) { $items.Add(@{ Kind = 'Folder'; Path = $leftover; Text = "$leftover, which an interrupted install left" }) }
        }
        # Reset-ComfyUIVenv deletes the old venv once the new one works, or moves it back; one is left only when that failed or update was interrupted.
        $oldVenv = $dir + '.local-ai-old-venv'
        if ([IO.Directory]::Exists($oldVenv)) { $items.Add(@{ Kind = 'Folder'; Path = $oldVenv; Text = "ComfyUI's old venv $oldVenv, which update moved aside" }) }
    }

    $own = @(
        @{ Kind = 'Folder'; Path = $Paths.FilesServer; Text = "the files server in $($Paths.FilesServer)"; Stamp = 'Files' }
        @{ Kind = 'File'; Path = $Paths.FilesKey; Text = "mcpo's key file $($Paths.FilesKey)"; Stamp = 'Files' }
        @{ Kind = 'File'; Path = $Paths.McpoConfig; Text = "mcpo's configuration $($Paths.McpoConfig)" }
        @{ Kind = 'Folder'; Path = (Join-Path $Paths.Root 'image-gate'); Text = "the image gate's working folder $(Join-Path $Paths.Root 'image-gate')" }
        @{ Kind = 'Folder'; Path = (Join-Path $Paths.Root 'mcpo'); Text = "mcpo's working folder $(Join-Path $Paths.Root 'mcpo')" }
    )
    foreach ($item in $own) {
        $exists = if ($item.Kind -eq 'File') { [IO.File]::Exists($item.Path) } else { [IO.Directory]::Exists($item.Path) }
        if ($exists) { $items.Add($item) }
    }

    $source = [string]$Settings.Model.Source
    if (-not $source -and $State['Model'] -is [hashtable]) { $source = [string]$State['Model'].Source }
    $alias = if ($Stamp['Model'] -is [hashtable]) { [string]$Stamp['Model'].Alias } else { '' }
    if ($alias) {
        # Ollama adds the tag latest to a name without one.
        $base = @(if ($source) { $source; "${source}:latest" })
        if ($base -contains $alias -or $base -contains "${alias}:latest") {
            $kept.Add("$alias in Ollama: it is Model.Source itself, which uninstall never removes.")
        } else {
            $from = if ($source) { " from $source, whose weights stay" } else { '' }
            $items.Add(@{ Kind = 'Alias'; Name = $alias; Stamp = 'Model'; Text = "the Ollama model $alias, which install created$from" })
        }
    }
    return @{ Items = $items.ToArray(); Kept = $kept.ToArray(); Source = $source }
}

# Return what uninstall -RemoveData deletes, changing nothing: @{ Items (the data folder, a ComfyUI checkout install cloned and Paths.Root, each when it exists, as
# @{ Path; Text; Root; Bytes (-1 when unknown); Problem (why not, or $null) }); Kept (one text per ComfyUI checkout it keeps) }. With -StampOnly the data folder and
# Files.Root come from $Stamp alone. Files.Root, OLLAMA_MODELS and a kept checkout are never inside what it deletes.
function Get-LocalAIDataPlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][hashtable]$Stamp,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$StampOnly
    )
    $kept = New-Object System.Collections.Generic.List[string]
    $keep = @{}
    $web = if ($Stamp['OpenWebUI'] -is [hashtable]) { $Stamp['OpenWebUI'] } else { @{} }
    $filesEntry = if ($Stamp['Files'] -is [hashtable]) { $Stamp['Files'] } else { @{} }
    $filesRoot = if ($StampOnly) { [string]$filesEntry.Root } else { [string]$Settings.Files.Root }
    if ($filesRoot -match '^[A-Za-z]:\\') { $keep['Files.Root'] = $filesRoot }
    foreach ($scope in 'Process', 'User') {
        $store = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', $scope)
        if ($store) { $keep["Ollama's models (OLLAMA_MODELS)"] = $store }
    }
    $candidates = New-Object System.Collections.Generic.List[hashtable]
    # The data folder is OpenWebUI.DataDir, refused when $Stamp records another. -StampOnly is for a settings.psd1 that did not load: then only the
    # folder $Stamp records counts, and without one nothing is deleted there.
    $dataText = "Open WebUI's data: accounts, chats, uploads, knowledge and its secret key"
    $stampedData = [string]$web.DataDir
    if ($StampOnly -and $stampedData) {
        $candidates.Add(@{ Path = $stampedData; Text = $dataText; Root = $false })
    } elseif ($StampOnly) {
        $candidates.Add(@{ Path = [string]$Settings.OpenWebUI.DataDir; Text = $dataText; Root = $false
                Problem = ('settings.psd1 does not load and install-stamp.json records no data folder of Open WebUI, so uninstall cannot tell whether the launcher ' +
                    "used this one; delete the launcher's data folder by hand once you know which it is") })
    } else {
        $settingsData = [string]$Settings.OpenWebUI.DataDir
        $problem = $null
        if ($stampedData -and $settingsData -match '^[A-Za-z]:\\' -and $stampedData -match '^[A-Za-z]:\\' -and
            -not (Resolve-OnDiskPath -Path $settingsData).Path.TrimEnd('\').Equals((Resolve-OnDiskPath -Path $stampedData).Path.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            $problem = "install recorded Open WebUI's data folder as $stampedData, not this one, which OpenWebUI.DataDir names; delete the one that holds the launcher's data by hand"
        }
        $candidates.Add(@{ Path = $settingsData; Text = $dataText; Root = $false; Problem = $problem })
    }

    # Only a checkout that $Stamp records as cloned and whose .git\local-ai-clone.json still marks it.
    $entry = if ($Stamp['ComfyUI'] -is [hashtable]) { $Stamp['ComfyUI'] } else { @{} }
    $clone = $null
    if ([string]$entry.Dir -match '^[A-Za-z]:\\' -and $entry.Cloned -eq $true) {
        $dir = Resolve-FolderPath -Path ([string]$entry.Dir)
        $mark = @{}
        try { $mark = Read-LocalAIState -Path (Join-Path $dir '.git\local-ai-clone.json') } catch { $mark = @{} }
        # A checkout put there by hand since then has no such mark.
        if ($mark['Kind'] -eq 'local-ai-clone') { $clone = $dir }
    }
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @([string]$entry.Dir, [string]$Settings.ComfyUI.Dir)) {
        if ($candidate -notmatch '^[A-Za-z]:\\') { continue }
        $dir = Resolve-FolderPath -Path $candidate
        if (@($seen | Where-Object { $_ -eq $dir }).Count -gt 0 -or -not [IO.Directory]::Exists($dir)) { continue }
        $seen.Add($dir)
        if ($dir -eq $clone) {
            $candidates.Add(@{ Path = $dir; Text = 'ComfyUI, which install cloned, with its venv, models, output, input, user settings and custom nodes'; Root = $false })
        } else {
            $kept.Add("ComfyUI in ${dir}: install did not clone this checkout, so it stays with its models and output.")
            $keep["the ComfyUI checkout in $dir"] = $dir
        }
    }
    $candidates.Add(@{ Path = $Paths.Root; Text = "the launcher's folder: settings.psd1, state.json, install-stamp.json, the logs and Open WebUI's backups"; Root = $true })

    $items = New-Object System.Collections.Generic.List[hashtable]
    foreach ($candidate in $candidates) {
        $path = $candidate.Path
        if (-not $path) { continue }
        if ($path -match '^[A-Za-z]:\\') {
            $path = Resolve-FolderPath -Path $path
            if (-not [IO.Directory]::Exists($path)) { continue }
        }
        # Why the data folder may not be the launcher's, or what Get-LocalAIRemovalProblem refuses.
        $problem = if ($candidate.Problem) { $candidate.Problem } else { Get-LocalAIRemovalProblem -Path $path -RepoRoot $RepoRoot -Keep $keep }
        $bytes = [long]-1
        if (-not $problem) {
            try { $bytes = Measure-LocalAIPath -Path $path } catch { $bytes = [long]-1 }
        }
        $items.Add(@{ Path = $path; Text = $candidate.Text; Root = $candidate.Root; Bytes = $bytes; Problem = $problem })
    }
    return @{ Items = $items.ToArray(); Kept = $kept.ToArray() }
}

# The uninstall verb: list what goes (Get-LocalAIUninstallPlan), ask once (default No), stop the stack and remove it, keeping Ollama, uv, Git, Node.js and every other
# model, then quit the Ollama app state.json records as local-ai's (Stop-OllamaApp), also one it started to remove the alias; -RemoveData asks again for a typed
# word, then also deletes what Get-LocalAIDataPlan lists. A release install goes last, once all that is gone: its entry in the user's Path, then its install
# folder, which a hidden process deletes once this window has closed (Start-LauncherCleanup); a git checkout or another folder stays. Works without settings,
# going by state.json and install-stamp.json. Returns 0, or 1 naming what stayed.
function Uninstall-LocalAI {
    # High, as it deletes what install made; it asks through Confirm-LocalAIAction, whose default is No, rather than ShouldProcess, whose default is Yes.
    [CmdletBinding(ConfirmImpact = 'High')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $paths = $Context.Paths
    $settings = $Context.Settings
    Update-SessionPath
    # Whether settings.psd1 itself was read; when not, the defaults may name another data folder than the launcher used.
    $userLoaded = $true
    if (-not $settings) {
        $skipped = New-Object System.Collections.Generic.List[string]
        $settings = Get-LocalAIFallbackSetting -DefaultsPath (Join-Path $Context.RepoRoot 'config\defaults.psd1') -UserPath $paths.Settings -Problems $skipped `
            -UserLoaded ([ref]$userLoaded)
        $without = if ($skipped.Count -gt 0) { " It skips what does not merge: $($skipped -join ' ')" } else { '' }
        $basis = if ($userLoaded) { 'the defaults with the values settings.psd1 sets' } else { "the defaults, as settings.psd1 does not load; Open WebUI's data folder comes from install-stamp.json only" }
        Write-Warning "The settings do not load, so uninstall goes by state.json, install-stamp.json and $basis.$without $($Context.SettingsError)"
    }
    $stamp = @{}
    $stampRead = $true
    try {
        $stamp = Read-LocalAIState -Path $paths.InstallStamp
    } catch {
        $stampRead = $false
        Write-Warning "$($_.Exception.Message) uninstall reads it as empty, so it leaves the alias install created and a ComfyUI checkout it cloned alone."
    }
    try {
        $state = Read-LocalAIState -Path $paths.State
    } catch {
        Write-Host ("$($_.Exception.Message) So uninstall cannot tell what the launcher runs, and it removed nothing. Close Open WebUI, ComfyUI, the image gate " +
            "and mcpo, delete $($paths.State), then run uninstall again.") -ForegroundColor Red
        return 1
    }
    $plan = Get-LocalAIUninstallPlan -Settings $settings -Paths $paths -Stamp $stamp -State $state
    $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
    # The launcher's own files, for a release install only.
    $launcher = Get-LauncherUninstallPlan -RepoRoot ([string]$Context.RepoRoot) -InstallRoot $installRoot
    $running = @(Get-LocalAIRunningService -Path $paths.State)
    $removeData = [bool]$Context.RemoveData
    # An Ollama app an earlier start, install or update began, which uninstall quits last; as stop judges it, also one this window may not inspect.
    $recordedApp = if ($state['Ollama'] -is [hashtable] -and $state['Ollama'].App -is [hashtable]) { $state['Ollama'].App } else { $null }
    $appRuns = $null -ne $recordedApp -and @('match', 'unreadable') -contains (Get-RecordedProcessState -Record $recordedApp)

    Write-Host ''
    if ($plan.Items.Count -gt 0 -or $launcher) {
        Write-Host 'Uninstall removes:'
        foreach ($item in $plan.Items) { Write-Host "  $($item.Text)" }
        if ($launcher -and $launcher.PathEntry) { Write-Host "  the entry $($launcher.Root) in your user Path" }
        if ($launcher) { Write-Host "  the launcher itself in $($launcher.Root), once this window has closed" }
    } else {
        Write-Host 'None of the parts install sets up is left to remove.'
    }
    if ($running.Count -gt 0) { Write-Host "It first stops what the launcher runs: $($running -join ', ')." }
    if ($appRuns) {
        Write-Host ("Last it quits the Ollama app local-ai started (PID $($recordedApp.Pid)), unless another program has a model loaded in it or its " +
            'window is open.')
    }
    if ($plan.Kept.Count -gt 0) {
        Write-Host 'It leaves:'
        foreach ($line in $plan.Kept) { Write-Host "  $line" }
    }
    if (-not $removeData) {
        $left = New-Object System.Collections.Generic.List[string]
        $dataDir = [string]$settings.OpenWebUI.DataDir
        if (-not $userLoaded) { $dataDir = if ($stamp['OpenWebUI'] -is [hashtable]) { [string]$stamp['OpenWebUI'].DataDir } else { '' } }
        if ($dataDir -and [IO.Directory]::Exists($dataDir)) { $left.Add("Open WebUI's in $dataDir") }
        $comfyDir = [string]$settings.ComfyUI.Dir
        if ($comfyDir -and [IO.Directory]::Exists($comfyDir)) { $left.Add("ComfyUI with its models in $comfyDir") }
        if ([IO.Directory]::Exists($paths.Root)) { $left.Add("the launcher's settings, logs and backups in $($paths.Root)") }
        if ($left.Count -gt 0) {
            $joined = if ($left.Count -gt 1) { ($left[0..($left.Count - 2)] -join ', ') + ' and ' + $left[-1] } else { $left[0] }
            Write-Host "Your data stays: $joined. 'local-ai uninstall -RemoveData' deletes it too, but not a ComfyUI checkout that install did not clone."
        }
    }
    $work = $plan.Items.Count -gt 0 -or $running.Count -gt 0 -or $appRuns -or $null -ne $launcher
    if ($work -and -not (Confirm-LocalAIAction -Question 'Uninstall these now?')) {
        Write-Host 'Nothing was removed.' -ForegroundColor Yellow
        return 0
    }

    $data = @()
    $refused = New-Object System.Collections.Generic.List[string]
    if ($removeData) {
        # Open WebUI's data folder (the one install-stamp.json records when settings.psd1 does not load), a ComfyUI checkout install cloned and Paths.Root.
        $dataPlan = Get-LocalAIDataPlan -Settings $settings -Paths $paths -Stamp $stamp -RepoRoot $Context.RepoRoot -StampOnly:(-not $userLoaded)
        $data = @($dataPlan.Items | Where-Object { -not $_.Problem })
        Write-Host ''
        Write-Host '-RemoveData also deletes these folders with everything in them:'
        foreach ($item in $data) {
            $size = if ($item.Bytes -ge 0) { Format-LocalAISize -Bytes $item.Bytes } else { 'size unknown' }
            Write-Host "  $($item.Path) ($size): $($item.Text)"
        }
        if ($data.Count -eq 0) { Write-Host '  none' }
        foreach ($item in @($dataPlan.Items | Where-Object { $_.Problem })) {
            $refused.Add("$($item.Path): -RemoveData does not delete it, because $($item.Problem).")
            Write-Host "  Not $($item.Path), because $($item.Problem)." -ForegroundColor Yellow
        }
        foreach ($line in $dataPlan.Kept) { Write-Host "  It keeps $line" }
        # A typed word, so a y or Enter pressed ahead for the first question cannot answer this one.
        if ($data.Count -gt 0 -and -not (Confirm-LocalAIAction -Question 'Delete these folders and everything in them? This cannot be undone.' -Word 'delete')) {
            Write-Host 'The data folders stay.' -ForegroundColor Yellow
            $data = @()
            # Kept by the answer, so the refusals no longer matter.
            $refused.Clear()
        }
    }

    $failed = New-Object System.Collections.Generic.List[string]
    if ($work -or $data.Count -gt 0) {
        # Ollama stays until the alias is removed; the app local-ai started is quit at the end.
        if ((Stop-LocalAI -Context $Context -KeepOllama) -ne 0) {
            Write-Host ("Uninstall removed nothing, because not everything the launcher runs could be stopped; see above. Run 'local-ai stop', then uninstall " +
                'again.') -ForegroundColor Red
            return 1
        }
    }
    # The shortcuts, the open-webui and mcpo uv tools install-stamp.json records, a ComfyUI venv install created, the file tools' files and the alias install
    # created, in that order. Blocked names the install-stamp.json entries whose parts are not all gone.
    $blocked = New-Object System.Collections.Generic.List[string]
    $aliasGone = $false
    foreach ($item in $plan.Items) {
        try {
            switch ($item.Kind) {
                'Shortcuts' {
                    $null = Set-LocalAIShortcut -Context @{ Settings = $settings; Paths = $paths; RepoRoot = $Context.RepoRoot; Remove = $true }
                }
                'UvTool' {
                    Assert-LocalAIIdle -Path $item.Path -File @($item.Program)
                    if ((Invoke-UvToolUninstall -Name $item.Name -ToolDir $item.ToolDir) -eq 'absent') {
                        Write-Host "uv lists no $($item.Name) in $($item.ToolDir), so it removed nothing there."
                    } else {
                        Write-Host "Removed the uv tool $($item.Name) from $($item.ToolDir)."
                    }
                }
                'Folder' {
                    Assert-LocalAIIdle -Path $item.Path
                    Remove-LocalAIFolder -Path $item.Path
                    Write-Host "Removed $($item.Path)."
                }
                'File' {
                    Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop
                    Write-Host "Removed $($item.Path)."
                }
                'Alias' {
                    if (-not (Get-Command -Name 'ollama' -CommandType Application -ErrorAction SilentlyContinue)) {
                        Write-Host "The ollama program is not on PATH, so there is no $($item.Name) to remove."
                    } else {
                        $url = Resolve-OllamaUrl -Setting $settings.Ollama.Url
                        Assert-OllamaCliUrl -Url $url
                        $wait = Wait-OllamaServer -Url $url -PassThru -How 'uninstall'
                        # Saved at once; the end of uninstall quits it, or a later 'local-ai stop' when uninstall stops early.
                        if ($wait.App) { $null = Save-OllamaRecord -Path $paths.State -Url $url -Alias $item.Name -App $wait.App }
                        if (@(Get-OllamaListedModel -Name $item.Name).Count -eq 0) {
                            Write-Host "Ollama holds no $($item.Name)."
                        } else {
                            Remove-OllamaModel -Name $item.Name
                            Write-Host "Removed $($item.Name) from Ollama."
                        }
                    }
                    $aliasGone = $true
                }
            }
        } catch {
            $failed.Add("$($item.Text): $($_.Exception.Message)")
            if ($item.Stamp) { $blocked.Add($item.Stamp) }
            Write-Host "Could not remove $($item.Text): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    # So start, status and update see the parts as missing rather than broken.
    if ($stampRead -and [IO.File]::Exists($paths.InstallStamp)) {
        $dropped = @(foreach ($key in 'OpenWebUI', 'Files') { if ($stamp.ContainsKey($key) -and $blocked -notcontains $key) { $key } })
        if ($aliasGone -and $stamp.ContainsKey('Model')) { $dropped += 'Model' }
        foreach ($key in $dropped) { $stamp.Remove($key) }
        # Dir and Cloned stay, so a later -RemoveData still knows whether install cloned the checkout; the checkpoint below it stays too.
        $venvGone = @($plan.Items | Where-Object { $_.Stamp -eq 'ComfyUI' }).Count -gt 0 -and $blocked -notcontains 'ComfyUI' -and $stamp['ComfyUI'] -is [hashtable]
        if ($venvGone) { $stamp['ComfyUI'] = @{ Dir = $stamp['ComfyUI'].Dir; Cloned = $stamp['ComfyUI'].Cloned } }
        if ($dropped.Count -gt 0 -or $venvGone) { Write-LocalAIState -Path $paths.InstallStamp -State $stamp }
    }

    # Ollama last, as stop quits it: the app state.json records as local-ai's, also one the wait above started. Before -RemoveData deletes state.json.
    $final = @{}
    try {
        $final = Read-LocalAIState -Path $paths.State
    } catch {
        Write-Verbose "state.json cannot be read again, so uninstall quits no Ollama app: $($_.Exception.Message)"
    }
    $ollama = $final['Ollama']
    $keptApp = $null
    if ($ollama -is [hashtable] -and $ollama.App -is [hashtable] -and $ollama.Url) {
        $quit = Stop-OllamaApp -Record $ollama.App -Url ([string]$ollama.Url) -Alias ([string]$ollama.Alias)
        if ($quit.Result -eq 'failed') {
            $failed.Add($quit.Reason)
        } elseif ($quit.Result -eq 'kept') {
            $keptApp = $ollama.App
        } else {
            $ollama['App'] = $null
            try {
                Write-LocalAIState -Path $paths.State -State $final
            } catch {
                Write-Warning "The Ollama app is no longer running, but state.json still records it: $($_.Exception.Message)"
            }
        }
    }

    foreach ($item in $data) {
        if ($item.Root -and $failed.Count -gt 0) {
            Write-Host "Kept $($item.Path), since the next uninstall run needs its install-stamp.json to remove what stays above." -ForegroundColor Yellow
            continue
        }
        try {
            Assert-LocalAIIdle -Path $item.Path
            Remove-LocalAIFolder -Path $item.Path
            Write-Host "Deleted $($item.Path)."
            if ($item.Root -and $keptApp) {
                # Its record went with state.json, so 'local-ai stop' can no longer quit it.
                Write-Host ("local-ai no longer tracks the Ollama app it started (PID $($keptApp.Pid)), which keeps running; quit it from its tray icon once " +
                    'you are done with it.') -ForegroundColor Yellow
            }
        } catch {
            $failed.Add("$($item.Path): $($_.Exception.Message)")
            Write-Host "Could not delete $($item.Path): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # The launcher's own files last, and only once everything else is gone, as the next uninstall run needs them.
    if ($launcher -and $failed.Count -gt 0) {
        Write-Host "Kept the launcher in $($launcher.Root), since the next uninstall run needs it to remove what stays above." -ForegroundColor Yellow
    } elseif ($launcher) {
        if ($launcher.PathEntry) {
            $removed = $false
            try {
                $removed = Remove-LauncherUserPath -Entry $launcher.Root
            } catch {
                $failed.Add("the entry $($launcher.Root) in your user Path: $($_.Exception.Message)")
                Write-Host "Could not remove $($launcher.Root) from your user Path: $($_.Exception.Message)" -ForegroundColor Red
            }
            if ($removed) {
                # The entry is gone already, so only windows that run now miss the news.
                try {
                    Send-LauncherSettingChange
                } catch {
                    Write-Warning "Windows could not tell running programs that your Path changed, so it may take a new sign-in: $($_.Exception.Message)"
                }
                Write-Host "Removed $($launcher.Root) from your user Path."
            }
        }
        try {
            # cmd.exe still reads local-ai.cmd there once this run ends, and a window may work in that folder, so it cannot go before the window closes.
            $note = Start-LauncherCleanup -InstallRoot $launcher.Root
            Write-Host "The launcher's own folder $($launcher.Root) goes once this window has closed; $note says how that went." -ForegroundColor Yellow
        } catch {
            $failed.Add("$($launcher.Root): $($_.Exception.Message) Delete it once this window has closed.")
            Write-Host "Could not start the removal of $($launcher.Root): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ''
    $packages = $settings.Winget.Packages
    $names = @('Ollama', 'Uv', 'Git')
    # Only a Node.js that a launcher install put in; one that was there before is the user's.
    if ($stamp['Node'] -is [hashtable] -and $stamp['Node'].InstalledByLauncher -eq $true) { $names += 'Node' }
    $displays = @{ Ollama = 'Ollama'; Uv = 'uv'; Git = 'Git'; Node = 'Node.js' }
    Write-Host "$(@($names | ForEach-Object { $displays[$_] }) -join ', ') stay installed. Uninstall each with winget once nothing else needs it:"
    foreach ($name in $names) {
        $package = $packages[$name]
        if ($package -is [hashtable] -and $package.Id) { Write-Host "  winget uninstall --id $($package.Id) -e" }
    }
    if ($plan.Source) { Write-Host "Ollama keeps the weights of $($plan.Source) and every other model; 'ollama rm $($plan.Source)' removes those weights." }
    Write-Host "uv keeps its cache and the Pythons it downloaded; 'uv cache clean' and 'uv python uninstall <version>' remove them."
    foreach ($line in $refused) { $failed.Add($line) }
    if ($failed.Count -gt 0) {
        Write-Host 'Uninstall finished, but these stay:' -ForegroundColor Red
        foreach ($line in $failed) { Write-Host "  $line" -ForegroundColor Red }
        return 1
    }
    Write-Host 'Uninstall finished.' -ForegroundColor Green
    return 0
}

# Return the full paths of the private copies of the folder $Path that app package stores hold (Find-PackageStoreCopy), which Windows made for a process
# inside a package's container that created it, when $Path lies below $LocalAppData or $AppData; nothing for a folder elsewhere. Reads only.
function Find-LocalAIPrivateCopy {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path,
        [string]$LocalAppData,
        [string]$AppData
    )
    if (-not $Path -or -not $LocalAppData) { return }
    $folder = $Path.TrimEnd('\')
    # The stores of both live below %LOCALAPPDATA%\Packages.
    foreach ($base in @(@{ Root = $LocalAppData; Store = 'Local' }, @{ Root = $AppData; Store = 'Roaming' })) {
        if (-not $base.Root) { continue }
        $prefix = $base.Root.TrimEnd('\') + '\'
        if (-not $folder.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($copy in @(Find-PackageStoreCopy -LocalAppData $LocalAppData -Store $base.Store -RelativePath $folder.Substring($prefix.Length))) {
            [string]$copy.Path
        }
    }
}

# BEGIN LAUNCHER RELEASE FUNCTIONS
# What update and install.ps1 share, from the line above to the END line below: the packaged-app probe, the release check, the staging, the file current
# and the user's Path. install.ps1 holds a copy of this block, which a test compares with this one, so these functions call nothing else of this module and
# keep no variable outside themselves.

# Return @{ Package; Store; Path } for each app package folder in $LocalAppData\Packages whose private store LocalCache\$Store (Local or Roaming)
# holds $RelativePath; nothing when Packages is missing or cannot be listed, or a path holds a character no path can. Reads only, and never throws.
function Find-PackageStoreCopy {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$LocalAppData,
        [Parameter(Mandatory)][ValidateSet('Local', 'Roaming')][string]$Store,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $packages = @()
    try {
        $packages = @([IO.Directory]::GetDirectories([IO.Path]::Combine($LocalAppData, 'Packages')))
    } catch {
        $packages = @()
    }
    foreach ($package in $packages) {
        try {
            $storePath = [IO.Path]::Combine($package, 'LocalCache', $Store)
            $path = [IO.Path]::Combine($storePath, $RelativePath)
        } catch {
            # Combine refuses a character such as a double quote in $RelativePath, which then no store holds.
            return
        }
        if ([IO.Directory]::Exists($path)) { @{ Package = [IO.Path]::GetFileName($package); Store = $storePath; Path = $path } }
    }
}

# Return @{ Package; Store } when Windows puts a folder made directly in $LocalAppData into an app package's private store instead, else $null. It does that
# for a process inside the Claude desktop app's container, which has no package identity to ask about. Makes the empty folder $ProbeName to find out, and
# always deletes it again, and the empty probes a killed run left; never throws, so a probe that cannot be made or a failed lookup returns $null too.
function Get-AppDataRedirection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$LocalAppData,
        [string]$ProbeName = ('local-ai-probe-' + [guid]::NewGuid().ToString('N'))
    )
    try {
        # Without a Packages folder there is no store to redirect into, so nothing is made. Combine throws on a character such as a double quote.
        if (-not $LocalAppData -or -not [IO.Directory]::Exists([IO.Path]::Combine($LocalAppData, 'Packages'))) { return $null }
        $probe = [IO.Path]::Combine($LocalAppData, $ProbeName)
    } catch {
        return $null
    }
    # A run killed between making and deleting its probe leaves it behind; inside the container this listing shows those in the store too. One older
    # than a minute belongs to no run still probing, and Delete removes an empty folder only.
    $stale = @()
    try {
        $stale = @([IO.Directory]::GetDirectories($LocalAppData, 'local-ai-probe-*'))
    } catch {
        $stale = @()
    }
    foreach ($path in $stale) {
        try {
            if ([IO.Directory]::GetCreationTimeUtc($path) -lt [DateTime]::UtcNow.AddMinutes(-1)) { [IO.Directory]::Delete($path) }
        } catch {
            Write-Verbose "The AppData probe $path that an earlier run left cannot be deleted: $($_.Exception.Message)"
        }
    }
    $found = @()
    try {
        # Made inside the try, so that the finally deletes it whatever stops the lookup.
        $null = [IO.Directory]::CreateDirectory($probe)
        # Inside the container the redirected probe shows at $probe too, so only the stores tell where it went.
        $found = @(Find-PackageStoreCopy -LocalAppData $LocalAppData -Store 'Local' -RelativePath $ProbeName)
    } catch {
        $found = @()
    } finally {
        # Delete removes an empty folder only. Inside the container deleting $probe also deletes the store's copy, which is then gone already.
        foreach ($path in @(@($probe) + @($found | ForEach-Object { $_.Path }))) {
            try {
                if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path) }
            } catch {
                Write-Verbose "The AppData probe $path cannot be deleted: $($_.Exception.Message)"
            }
        }
    }
    if ($found.Count -eq 0) { return $null }
    return @{ Package = [string]$found[0].Package; Store = [string]$found[0].Store }
}

# Return the clause that the refusal and status start with for the redirection $Redirection (Get-AppDataRedirection): the package and its private stores,
# LocalCache\Local, which the probe found, for %LOCALAPPDATA%, and LocalCache\Roaming beside it for %APPDATA%.
function Format-AppDataRedirection {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Redirection
    )
    $store = [string]$Redirection.Store
    $roaming = [IO.Path]::Combine([IO.Path]::GetDirectoryName($store), 'Roaming')
    return ("This window runs inside the app package $($Redirection.Package), and Windows puts the folders it creates in %LOCALAPPDATA% and %APPDATA% " +
        "into that package's private stores $store and $roaming instead")
}

# Return the folder of a release install, $LocalAppData\Programs\local-ai-launcher, which is not a setting; $null when $LocalAppData is empty or holds a
# character no path can. Pure.
function Get-LauncherInstallRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$LocalAppData
    )
    if (-not $LocalAppData) { return $null }
    try {
        return [IO.Path]::Combine($LocalAppData, 'Programs', 'local-ai-launcher')
    } catch {
        Write-Verbose "No install folder lies below '$LocalAppData': $($_.Exception.Message)"
        return $null
    }
}

# Return $Tag, such as 'v1.10.0', as the [version] 1.10.0 when it is a launcher tag: a lowercase v and three whole numbers without leading zeros or a suffix,
# each at most 2147483647; $null for any other text, such as 'v1.2', 'v1.2.3-rc.1', 'V1.2.3', 'v01.2.3' or '1.2.3'. Pure.
function ConvertTo-LauncherVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Tag
    )
    # [0-9], as \d also matches digits of other scripts.
    if ($Tag -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') { return $null }
    $numbers = New-Object 'System.Collections.Generic.List[int]'
    foreach ($index in 1, 2, 3) {
        $number = 0
        if (-not [int]::TryParse($Matches[$index], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
        $numbers.Add($number)
    }
    return New-Object Version -ArgumentList $numbers[0], $numbers[1], $numbers[2]
}

# Return a new exception holding $Message whose Data['LauncherProblem'] is $Kind: 'Unreachable' when GitHub or the download did not answer, so the launcher
# stays as it is and update goes on, or 'Refused' when a release or a version folder fails a check, which stops update. Pure.
function New-LauncherProblem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: it only makes an exception object.')]
    [CmdletBinding()]
    [OutputType([InvalidOperationException])]
    param(
        [Parameter(Mandatory)][ValidateSet('Unreachable', 'Refused')][string]$Kind,
        [Parameter(Mandatory)][string]$Message
    )
    $exception = New-Object InvalidOperationException -ArgumentList $Message
    $exception.Data['LauncherProblem'] = $Kind
    return $exception
}

# Add TLS 1.2 to the protocols this process offers when they are neither the system default nor include it, as with an old .NET setting, and return the
# value before, which the caller puts back; $null when nothing changed. Never removes a protocol, so TLS 1.3 stays wherever Windows offers it.
function Enable-LauncherTls12 {
    [CmdletBinding()]
    [OutputType([Net.SecurityProtocolType])]
    param()
    $saved = [Net.ServicePointManager]::SecurityProtocol
    # 0 is SystemDefault, which lets Windows choose.
    if ([int]$saved -eq 0 -or ($saved -band [Net.SecurityProtocolType]::Tls12) -eq [Net.SecurityProtocolType]::Tls12) { return $null }
    [Net.ServicePointManager]::SecurityProtocol = $saved -bor [Net.SecurityProtocolType]::Tls12
    return $saved
}

# Return @{ Status; Reason } for the error record $ErrorRecord of a web request: Status its HTTP status code, $null without one; Reason that code with its
# text and, when GitHub says the requests it answers for this address in an hour are used up, the time that limit resets, or else the error's own message,
# as for no network, a timeout or a name that does not resolve. Pure.
function Get-LauncherWebProblem {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    $reason = ([string]$ErrorRecord.Exception.Message).Trim().TrimEnd('.')
    $web = $ErrorRecord.Exception
    while ($null -ne $web -and $web -isnot [Net.WebException]) { $web = $web.InnerException }
    $response = if ($null -ne $web) { $web.Response } else { $null }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['StatusCode']) { return @{ Status = $null; Reason = $reason } }
    $status = [int]$response.StatusCode
    $text = "GitHub answered HTTP $status"
    if ($response.PSObject.Properties['StatusDescription'] -and $response.StatusDescription) { $text += " $($response.StatusDescription)" }
    $remaining = ''
    $reset = ''
    $retry = ''
    if ($null -ne $response.Headers) {
        $remaining = [string]$response.Headers['X-RateLimit-Remaining']
        $reset = [string]$response.Headers['X-RateLimit-Reset']
        $retry = [string]$response.Headers['Retry-After']
    }
    if (($status -eq 403 -or $status -eq 429) -and $remaining -eq '0' -and $reset -cmatch '\A[0-9]{1,12}\z') {
        $at = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset).LocalDateTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $text += ", as the requests it answers for this address in an hour are used up until $at"
    } elseif ($retry -cmatch '\A[0-9]{1,6}\z') {
        $text += " and asks to wait $retry s"
    }
    return @{ Status = $status; Reason = $text }
}

# Return the JSON the GitHub API answers at $Uri, asked with GET, $TimeoutSeconds, the API version 2022-11-28 and the User-Agent $UserAgent. Any failure throws
# an 'Unreachable' problem (New-LauncherProblem) with the reason Get-LauncherWebProblem gives and, in Data['Status'], the HTTP status code when there is one.
function Invoke-LauncherApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 15,
        [string]$UserAgent = 'local-ai-launcher'
    )
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $saved = Enable-LauncherTls12
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -UserAgent $UserAgent -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
    } catch {
        $found = Get-LauncherWebProblem -ErrorRecord $_
        $problem = New-LauncherProblem -Kind 'Unreachable' -Message $found.Reason
        $problem.Data['Status'] = $found.Status
        throw $problem
    } finally {
        if ($null -ne $saved) { [Net.ServicePointManager]::SecurityProtocol = $saved }
    }
}

# Return the GitHub release object $Release as @{ Tag; Version; Asset; Url; Digest; Size } when the launcher may install it: a tag vX.Y.Z
# (ConvertTo-LauncherVersion), no draft or prerelease, immutable while $RequireImmutable is on, and exactly one asset local-ai-launcher-X.Y.Z.zip, uploaded,
# of 1 byte to 64 MB, served over HTTPS and with the digest sha256:<64 lowercase hex digits>. Throws a 'Refused' problem naming the rule it breaks. Pure.
function Test-LauncherRelease {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][object]$Release,
        [bool]$RequireImmutable = $true
    )
    $refuse = { param([string]$Why) throw (New-LauncherProblem -Kind 'Refused' -Message $Why) }
    $tag = if ($null -ne $Release) { [string]$Release.tag_name } else { '' }
    if (-not $tag) { & $refuse 'GitHub answered with no release.' }
    if (-not (ConvertTo-LauncherVersion -Tag $tag)) { & $refuse "The release is tagged '$tag', but the launcher installs only a tag vX.Y.Z without a suffix." }
    if ($Release.draft -isnot [bool] -or $Release.draft) { & $refuse "The release $tag is a draft, which the launcher never installs." }
    if ($Release.prerelease -isnot [bool] -or $Release.prerelease) { & $refuse "The release $tag is a prerelease, which the launcher never installs." }
    if ($RequireImmutable -and ($Release.immutable -isnot [bool] -or -not $Release.immutable)) {
        & $refuse ("The release $tag is not immutable, so its tag and files could still change, and Launcher.RequireImmutable lets the launcher install " +
            'only immutable releases.')
    }
    $version = $tag.Substring(1)
    $name = "local-ai-launcher-$version.zip"
    $assets = @(@($Release.assets) | Where-Object { $null -ne $_ -and [string]$_.name -ceq $name })
    if ($assets.Count -eq 0) { & $refuse "The release $tag holds no asset $name." }
    if ($assets.Count -gt 1) { & $refuse "The release $tag holds $($assets.Count) assets named $name." }
    $asset = $assets[0]
    if ([string]$asset.state -cne 'uploaded') { & $refuse "The asset $name of $tag is '$($asset.state)', not uploaded." }
    $digest = [string]$asset.digest
    if ($digest -cnotmatch '\Asha256:[0-9a-f]{64}\z') { & $refuse "The asset $name of $tag has the digest '$digest', not sha256: and 64 lowercase hex digits." }
    $size = [long]0
    if (-not [long]::TryParse([string]$asset.size, [ref]$size) -or $size -lt 1 -or $size -gt 64MB) { & $refuse "The asset $name of $tag has $($asset.size) bytes, not 1 byte to 64 MB." }
    $url = [string]$asset.browser_download_url
    if (-not $url.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { & $refuse "The asset $name of $tag is not served over HTTPS but from '$url'." }
    return @{ Tag = $tag; Version = $version; Asset = $name; Url = $url; Digest = $digest; Size = $size }
}

# Return the release of the GitHub repository $Repo that update or install.ps1 installs, checked by Test-LauncherRelease with $RequireImmutable: the latest
# one, or with $Tag that tag's. Throws an 'Unreachable' problem when GitHub does not answer, also when it lists no such release (HTTP 404), and a 'Refused'
# one when the release fails a check.
function Get-LauncherRelease {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [AllowEmptyString()][string]$Tag = '',
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 15,
        [bool]$RequireImmutable = $true,
        [string]$UserAgent = 'local-ai-launcher'
    )
    # No name that ends in a dot, which .NET drops from the address, so that it would ask about another repository.
    if ($Repo -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{0,99}[A-Za-z0-9_-]\z') { throw "'$Repo' is no GitHub repository <owner>/<name>." }
    if ($Tag -and -not (ConvertTo-LauncherVersion -Tag $Tag)) { throw "'$Tag' is no launcher version vX.Y.Z." }
    $which = if ($Tag) { "tags/$Tag" } else { 'latest' }
    try {
        $release = Invoke-LauncherApi -Uri "https://api.github.com/repos/$Repo/releases/$which" -TimeoutSeconds $TimeoutSeconds -UserAgent $UserAgent
    } catch {
        if ($_.Exception.Data['Status'] -eq 404) {
            $what = if ($Tag) { "no published release $Tag" } else { 'no published release' }
            $problem = New-LauncherProblem -Kind 'Unreachable' -Message "GitHub lists $what of $Repo`: $($_.Exception.Message)"
            $problem.Data['Status'] = 404
            throw $problem
        }
        throw
    }
    $checked = Test-LauncherRelease -Release $release -RequireImmutable $RequireImmutable
    if ($Tag -and $checked.Tag -cne $Tag) { throw (New-LauncherProblem -Kind 'Refused' -Message "GitHub answered with the release $($checked.Tag) for the tag $Tag.") }
    return $checked
}

# Return the commit, 40 lowercase hex digits, that the tag $Tag of the GitHub repository $Repo names, following an annotated tag to its commit. Throws an
# 'Unreachable' problem when GitHub does not answer and a 'Refused' one when it names no such tag or no commit for it.
function Get-LauncherTagCommit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Tag,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 15,
        [string]$UserAgent = 'local-ai-launcher'
    )
    $refuse = { param([string]$Why) throw (New-LauncherProblem -Kind 'Refused' -Message $Why) }
    $api = "https://api.github.com/repos/$Repo/git"
    $answer = Invoke-LauncherApi -Uri "$api/ref/tags/$Tag" -TimeoutSeconds $TimeoutSeconds -UserAgent $UserAgent
    if ([string]$answer.ref -cne "refs/tags/$Tag") { & $refuse "GitHub names no tag $Tag of $Repo, but '$($answer.ref)'." }
    $object = $answer.object
    # An annotated tag names a tag object, which may name another before the commit.
    for ($depth = 0; $depth -lt 4; $depth++) {
        $sha = [string]$object.sha
        $type = [string]$object.type
        if ($sha -cnotmatch '\A[0-9a-f]{40}\z') { & $refuse "The tag $Tag of $Repo names '$sha', which is no object of 40 lowercase hex digits." }
        if ($type -ceq 'commit') { return $sha }
        if ($type -cne 'tag') { & $refuse "The tag $Tag of $Repo names a $type, not a commit." }
        $object = (Invoke-LauncherApi -Uri "$api/tags/$sha" -TimeoutSeconds $TimeoutSeconds -UserAgent $UserAgent).object
    }
    & $refuse "The tag $Tag of $Repo names tags nested more than three deep, and no commit."
}

# Return $true when $Text is a plain relative path with forward slashes that stays inside its folder on Windows: each segment is not empty, '.' or '..', holds
# no backslash, colon, wildcard, quote, angle bracket, pipe or control character, does not end in a dot or a space, which Windows drops, and is no device
# name such as NUL or COM1. Pure.
function Test-LauncherPathText {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text
    )
    if (-not $Text) { return $false }
    foreach ($segment in $Text.Split('/')) {
        if ($segment.Length -eq 0 -or $segment -eq '.' -or $segment -eq '..') { return $false }
        if ($segment -match '[\x00-\x1f"*:<>?\\|]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) { return $false }
        if ($segment.Split('.')[0].Trim() -match '\A(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])\z') { return $false }
    }
    return $true
}

# Return the files below the folder $Path as a dictionary from their paths there, with forward slashes and in any case, to their full paths, without entering
# a junction or symbolic link: the path of each one is added to $Links instead. Reads only.
function Get-LauncherFileList {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][System.Collections.Generic.List[string]]$Links
    )
    $files = New-Object 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $root = (New-Object IO.DirectoryInfo -ArgumentList $Path).FullName.TrimEnd('\')
    $pending = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $pending.Push((New-Object IO.DirectoryInfo -ArgumentList $root))
    while ($pending.Count -gt 0) {
        foreach ($entry in $pending.Pop().GetFileSystemInfos()) {
            $relative = $entry.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($null -ne $Links) { $Links.Add($relative) }
            } elseif ($entry -is [IO.DirectoryInfo]) {
                $pending.Push($entry)
            } else {
                $files[$relative] = $entry.FullName
            }
        }
    }
    # PowerShell passes a dictionary on whole.
    return $files
}

# Return what is wrong with the release folder $Path for the tag $Tag, one clause each, nothing when it is whole: its manifest local-ai-release.json must be
# JSON with schema 1, the name local-ai-launcher, the version and tag of $Tag and a commit of 40 lowercase hex digits, $Commit when that is given; every file
# it lists must be there with its SHA-256, no other file but the manifest and no link, and VERSION must hold the version. Reads only.
function Test-LauncherFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Tag,
        [AllowEmptyString()][string]$Commit = ''
    )
    if (-not (ConvertTo-LauncherVersion -Tag $Tag)) { return "'$Tag' is no launcher version vX.Y.Z" }
    $version = $Tag.Substring(1)
    if (-not [IO.Directory]::Exists($Path)) { return 'the folder is missing' }
    $manifestPath = [IO.Path]::Combine($Path, 'local-ai-release.json')
    if (-not [IO.File]::Exists($manifestPath)) { return 'it holds no manifest local-ai-release.json' }
    try {
        $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath, (New-Object Text.UTF8Encoding $false, $true))) -ErrorAction Stop
    } catch {
        return "its manifest is not JSON ($($_.Exception.Message))"
    }
    if ($manifest -isnot [System.Management.Automation.PSCustomObject]) { return 'its manifest holds no JSON object' }
    if ([string]$manifest.schema -cne '1') { "its manifest has the schema '$($manifest.schema)', not 1" }
    if ([string]$manifest.name -cne 'local-ai-launcher') { "its manifest names '$($manifest.name)', not local-ai-launcher" }
    if ([string]$manifest.version -cne $version) { "its manifest names the version '$($manifest.version)', not $version" }
    if ([string]$manifest.tag -cne $Tag) { "its manifest names the tag '$($manifest.tag)', not $Tag" }
    $named = [string]$manifest.commit
    if ($named -cnotmatch '\A[0-9a-f]{40}\z') {
        "its manifest names the commit '$named', not 40 lowercase hex digits"
    } elseif ($Commit -and $named -cne $Commit) {
        "its manifest names the commit $named, but the tag $Tag names $Commit"
    }
    $links = New-Object System.Collections.Generic.List[string]
    $found = Get-LauncherFileList -Path $Path -Links $links
    $listed = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    if ($manifest.files -isnot [System.Management.Automation.PSCustomObject]) {
        'its manifest lists no files'
    } else {
        foreach ($property in $manifest.files.PSObject.Properties) {
            $relative = [string]$property.Name
            $hash = [string]$property.Value
            if (-not (Test-LauncherPathText -Text $relative) -or $relative -ieq 'local-ai-release.json') {
                "its manifest lists '$relative', which is no plain path of a file in the folder"
                continue
            }
            $null = $listed.Add($relative)
            if ($hash -cnotmatch '\A[0-9a-f]{64}\z') {
                "its manifest lists $relative with '$hash', which is no SHA-256 of 64 lowercase hex digits"
                continue
            }
            if (-not $found.ContainsKey($relative)) {
                "$relative is missing"
                continue
            }
            try {
                $actual = (Get-FileHash -LiteralPath $found[$relative] -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            } catch {
                "$relative cannot be read ($($_.Exception.Message))"
                continue
            }
            if ($actual -cne $hash) { "$relative differs from the file the release holds" }
        }
    }
    foreach ($relative in @($found.Keys | Sort-Object)) {
        if ($relative -ine 'local-ai-release.json' -and -not $listed.Contains($relative)) { "$relative is not in the manifest" }
    }
    foreach ($relative in $links) { "$relative is a junction or symbolic link" }
    if (-not $listed.Contains('VERSION')) {
        'its manifest lists no VERSION'
    } elseif ($found.ContainsKey('VERSION')) {
        $held = ''
        try { $held = [IO.File]::ReadAllText($found['VERSION']).Trim() } catch { $held = '' }
        if ($held -cne $version) { "VERSION holds '$held', not $version" }
    }
}

# Extract the zip file $Path into the new folder $Destination after checking every entry: a plain relative path (Test-LauncherPathText; a folder entry ends in
# '/'), no name twice in any case, no file where another entry needs a folder, and at most 10000 entries and 256 MB in all, so nothing lands outside it.
# Throws a 'Refused' problem naming the first bad entry, or a file that is no zip, before it writes anything; and one for an entry that holds more bytes than
# the zip states for it, before it writes more than that.
function Expand-LauncherArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    $refuse = { param([string]$Why) throw (New-LauncherProblem -Kind 'Refused' -Message $Why) }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $target = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target)) { throw "$target exists already, but a zip is extracted into a new folder only." }
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    } catch {
        & $refuse "$([IO.Path]::GetFileName($Path)) is no zip file: $($_.Exception.Message)"
    }
    try {
        $entries = @($zip.Entries)
        if ($entries.Count -gt 10000) { & $refuse "The zip holds $($entries.Count) entries, more than the 10000 a release may hold." }
        $names = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
        $folders = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
        $plan = New-Object System.Collections.Generic.List[hashtable]
        $total = [long]0
        foreach ($entry in $entries) {
            $name = [string]$entry.FullName
            $folder = $name.EndsWith('/')
            $relative = if ($folder) { $name.Substring(0, $name.Length - 1) } else { $name }
            if (-not (Test-LauncherPathText -Text $relative)) { & $refuse "The zip holds the entry '$name', which is no plain path inside its folder." }
            if (-not $names.Add($relative)) { & $refuse "The zip holds $relative twice, or in two spellings that differ only in case." }
            $segments = $relative.Split('/')
            for ($i = 1; $i -lt $segments.Count; $i++) { $null = $folders.Add(($segments[0..($i - 1)] -join '/')) }
            if ($folder) { $null = $folders.Add($relative) }
            $full = [IO.Path]::GetFullPath([IO.Path]::Combine($target, $relative.Replace('/', '\')))
            if (-not $full.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { & $refuse "The zip entry '$name' would land outside the folder it is extracted to." }
            $total += $entry.Length
            if ($total -gt 256MB) { & $refuse 'The zip holds more than the 256 MB a release may hold.' }
            $plan.Add(@{ Entry = $entry; Full = $full; Folder = $folder; Relative = $relative })
        }
        foreach ($item in $plan) {
            if (-not $item.Folder -and $folders.Contains($item.Relative)) { & $refuse "The zip holds $($item.Relative) both as a file and as a folder." }
        }
        $null = [IO.Directory]::CreateDirectory($target)
        foreach ($item in $plan) {
            if ($item.Folder) {
                $null = [IO.Directory]::CreateDirectory($item.Full)
                continue
            }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item.Full))
            $source = $item.Entry.Open()
            try {
                $file = New-Object IO.FileStream -ArgumentList $item.Full, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
                try {
                    # No more than the size the zip states, which the total above counts and .NET does not check against what it inflates.
                    $buffer = New-Object byte[] 81920
                    $left = [long]$item.Entry.Length
                    while ($true) {
                        $read = $source.Read($buffer, 0, $buffer.Length)
                        if ($read -le 0) { break }
                        $left -= $read
                        if ($left -lt 0) { & $refuse "The zip entry $($item.Relative) holds more bytes than its header says." }
                        $file.Write($buffer, 0, $read)
                    }
                } finally {
                    $file.Dispose()
                }
            } finally {
                $source.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

# Stage the release $Release (Get-LauncherRelease, with the Commit its tag names) in the install folder $InstallRoot as versions\<tag>: download its zip into
# a new staging\<tag>-<random> folder, compare its SHA-256 with the digest, extract it (Expand-LauncherArchive), require exactly the folder
# local-ai-launcher-X.Y.Z, matching its manifest (Test-LauncherFolder), unblock every file and rename that folder into place. A versions\<tag> that exists,
# as after a declined update, is checked instead of downloaded. The staging folder goes in any case, and so do those older than a day that earlier runs left.
# Returns @{ Path; Downloaded }; throws an 'Unreachable' problem when the download fails and a 'Refused' one when a check fails.
function Save-LauncherRelease {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Release,
        [Parameter(Mandatory)][string]$InstallRoot,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
        [string]$UserAgent = 'local-ai-launcher'
    )
    $refuse = { param([string]$Why) throw (New-LauncherProblem -Kind 'Refused' -Message $Why) }
    $tag = [string]$Release.Tag
    if (-not (ConvertTo-LauncherVersion -Tag $tag)) { throw "'$tag' is no launcher version vX.Y.Z." }
    $commit = [string]$Release.Commit
    if ($commit -cnotmatch '\A[0-9a-f]{40}\z') { throw "The release $tag names no commit of 40 lowercase hex digits ('$commit')." }
    $version = $tag.Substring(1)
    $name = "local-ai-launcher-$version.zip"
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $versions = [IO.Path]::Combine($root, 'versions')
    $target = [IO.Path]::Combine($versions, $tag)
    if ([IO.Directory]::Exists($target)) {
        $problems = @(Test-LauncherFolder -Path $target -Tag $tag -Commit $commit)
        if ($problems.Count -gt 0) {
            & $refuse "$target, which an earlier run staged, does not match its manifest: $($problems -join '; '). Move that folder away, then try again."
        }
        return @{ Path = $target; Downloaded = $false }
    }
    # A run that was stopped, or whose window was closed, leaves its staging folder. Those older than a day go, so that a run in another window keeps its own.
    $stagingRoot = [IO.Path]::Combine($root, 'staging')
    if ([IO.Directory]::Exists($stagingRoot)) {
        foreach ($old in (New-Object IO.DirectoryInfo -ArgumentList $stagingRoot).GetDirectories()) {
            if (($old.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $old.Name -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-[0-9a-f]{8}\z' -or
                $old.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-1)) { continue }
            try {
                [IO.Directory]::Delete($old.FullName, $true)
            } catch {
                Write-Warning "Could not delete the old staging folder $($old.FullName): $($_.Exception.Message)"
            }
        }
    }
    $staging = [IO.Path]::Combine($stagingRoot, ('{0}-{1}' -f $tag, [guid]::NewGuid().ToString('N').Substring(0, 8)))
    $null = [IO.Directory]::CreateDirectory($staging)
    try {
        $zip = [IO.Path]::Combine($staging, $name)
        # Windows PowerShell 5.1 draws a progress bar for each block it downloads, which slows the download down.
        $ProgressPreference = 'SilentlyContinue'
        $saved = Enable-LauncherTls12
        try {
            Invoke-WebRequest -Uri ([string]$Release.Url) -OutFile $zip -UseBasicParsing -TimeoutSec $TimeoutSeconds -UserAgent $UserAgent -ErrorAction Stop
        } catch {
            $found = Get-LauncherWebProblem -ErrorRecord $_
            throw (New-LauncherProblem -Kind 'Unreachable' -Message "the download of $name failed: $($found.Reason)")
        } finally {
            if ($null -ne $saved) { [Net.ServicePointManager]::SecurityProtocol = $saved }
        }
        if (-not [IO.File]::Exists($zip)) { & $refuse "The download of $name wrote no file." }
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ("sha256:$hash" -cne [string]$Release.Digest) { & $refuse "The download of $name has the SHA-256 $hash, but GitHub lists $($Release.Digest) for it." }
        $tree = [IO.Path]::Combine($staging, 'tree')
        Expand-LauncherArchive -Path $zip -Destination $tree
        $folderName = "local-ai-launcher-$version"
        $folder = [IO.Path]::Combine($tree, $folderName)
        $top = @([IO.Directory]::GetFileSystemEntries($tree) | ForEach-Object { [IO.Path]::GetFileName($_) })
        if ($top.Count -ne 1 -or $top[0] -cne $folderName -or -not [IO.Directory]::Exists($folder)) {
            $held = if ($top.Count -gt 0) { $top -join ', ' } else { 'nothing' }
            & $refuse "The zip must hold exactly the folder $folderName, but it holds $held."
        }
        $problems = @(Test-LauncherFolder -Path $folder -Tag $tag -Commit $commit)
        if ($problems.Count -gt 0) { & $refuse "The folder $folderName in the zip does not match its manifest: $($problems -join '; ')." }
        foreach ($file in @((Get-LauncherFileList -Path $folder).Values)) { Unblock-File -LiteralPath $file -ErrorAction Stop }
        $null = [IO.Directory]::CreateDirectory($versions)
        [IO.Directory]::Move($folder, $target)
        return @{ Path = $target; Downloaded = $true }
    } finally {
        if ([IO.Directory]::Exists($staging)) {
            try {
                [IO.Directory]::Delete($staging, $true)
            } catch {
                Write-Warning "Could not delete the staging folder $staging`: $($_.Exception.Message)"
            }
        }
    }
}

# Return the tag the file current in the install folder $InstallRoot names, read as the shim's set /p reads it: the text up to the first CR, without the line
# feeds that end it, which must be a tag vX.Y.Z; $null when the file is missing, cannot be read or names anything else. Reads only.
function Get-LauncherCurrent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$InstallRoot
    )
    if (-not $InstallRoot) { return $null }
    try {
        $path = [IO.Path]::Combine($InstallRoot, 'current')
        if (-not [IO.File]::Exists($path)) { return $null }
        # As ASCII, so that a byte order mark or another byte the shim's set /p would keep fails the check below.
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path))
    } catch {
        Write-Verbose "Cannot read the file current in $InstallRoot`: $($_.Exception.Message)"
        return $null
    }
    # set /p stops at a CR, so two lines with LF line ends make one value, which the shim refuses.
    $cr = $text.IndexOf("`r")
    if ($cr -ge 0) { $text = $text.Substring(0, $cr) }
    $line = $text.TrimEnd("`n")
    if (ConvertTo-LauncherVersion -Tag $line) { return $line }
    return $null
}

# Return HKCU\Environment opened for writing through the registry API, which reads and writes a REG_EXPAND_SZ value as it is, unlike
# [Environment]::SetEnvironmentVariable. The caller disposes it.
function Get-LauncherEnvironmentKey {
    [CmdletBinding()]
    param()
    return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
}

# Return @{ Exists; Value; Kind } for the user's Path in the registry key $Key: its text with %VAR% left as it is, and its kind, String or ExpandString, which
# is ExpandString for a Path that does not exist yet. Throws when the value holds anything but text. Reads only.
function Read-LauncherUserPath {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Key
    )
    if (@($Key.GetValueNames()) -notcontains 'Path') { return @{ Exists = $false; Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString } }
    $kind = $Key.GetValueKind('Path')
    if ($kind -ne [Microsoft.Win32.RegistryValueKind]::String -and $kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) {
        throw "The user's Path in HKCU\Environment is a $kind value, not text, so it is left as it is."
    }
    $value = [string]$Key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return @{ Exists = $true; Value = $value; Kind = $kind }
}

# Return $true when the entry $Item of a Path value names the folder $Entry once %VAR% is expanded, ignoring case, spaces around it and a trailing '\'. Pure.
function Test-LauncherPathEntry {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$Item,
        [Parameter(Mandatory)][string]$Entry
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Item).Trim().TrimEnd('\')
    return $expanded.Length -gt 0 -and $expanded.Equals($Entry.Trim().TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

# Return $true when the user's Path in HKCU\Environment has an entry naming the folder $Entry (Test-LauncherPathEntry). Reads only.
function Test-LauncherUserPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Entry
    )
    $key = Get-LauncherEnvironmentKey
    try {
        $path = Read-LauncherUserPath -Key $key
        return @($path.Value.Split(';') | Where-Object { Test-LauncherPathEntry -Item $_ -Entry $Entry }).Count -gt 0
    } finally {
        $key.Dispose()
    }
}

# Add the folder $Entry to the end of the user's Path in HKCU\Environment unless an entry names it already, keeping the value's kind, REG_EXPAND_SZ for a new
# value, and every other entry as it is. Returns $true when it added it; throws when the Path holds no text or cannot be written.
function Add-LauncherUserPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Entry
    )
    $key = Get-LauncherEnvironmentKey
    try {
        $path = Read-LauncherUserPath -Key $key
        if (@($path.Value.Split(';') | Where-Object { Test-LauncherPathEntry -Item $_ -Entry $Entry }).Count -gt 0) { return $false }
        $value = if (-not $path.Value) { $Entry } elseif ($path.Value.EndsWith(';')) { $path.Value + $Entry } else { "$($path.Value);$Entry" }
        $key.SetValue('Path', $value, $path.Kind)
        return $true
    } finally {
        $key.Dispose()
    }
}

# Remove each entry of the user's Path in HKCU\Environment that names the folder $Entry, and nothing else, keeping the value's kind and the other entries as
# they are; a Path left empty is deleted. Returns $true when it removed an entry.
function Remove-LauncherUserPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the uninstall verb, which asks before it changes anything.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Entry
    )
    $key = Get-LauncherEnvironmentKey
    try {
        $path = Read-LauncherUserPath -Key $key
        $items = @($path.Value.Split(';'))
        $kept = @($items | Where-Object { -not (Test-LauncherPathEntry -Item $_ -Entry $Entry) })
        if ($kept.Count -eq $items.Count) { return $false }
        $value = $kept -join ';'
        if ($value.Trim(';', ' ')) { $key.SetValue('Path', $value, $path.Kind) } else { $key.DeleteValue('Path', $false) }
        return $true
    } finally {
        $key.Dispose()
    }
}

# Tell running programs, such as Explorer, that the environment changed (WM_SETTINGCHANGE with 'Environment'), so that windows opened from then on see the
# new Path; waits at most 5 s for each window. Compiles the user32 binding once per session.
function Send-LauncherSettingChange {
    [CmdletBinding()]
    param()
    if (-not ('LocalAI.SettingChange' -as [type])) {
        Add-Type -Namespace LocalAI -Name SettingChange -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE and SMTO_ABORTIFHUNG.
    $null = ('LocalAI.SettingChange' -as [type])::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}
# END LAUNCHER RELEASE FUNCTIONS

# Return how the launcher in $RepoRoot is installed: 'git' when $RepoRoot\.git exists, as a folder or, in a worktree, as a file; 'release' when $RepoRoot is
# $InstallRoot\versions\<tag> for a tag vX.Y.Z and holds local-ai-release.json; else 'folder', as for a zip extracted by hand. Reads only.
function Get-LauncherInstallKind {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][AllowNull()][string]$InstallRoot = (Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA)
    )
    try {
        $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
        $git = [IO.Path]::Combine($root, '.git')
        if ([IO.Directory]::Exists($git) -or [IO.File]::Exists($git)) { return 'git' }
        if ($InstallRoot) {
            $versions = [IO.Path]::Combine([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\'), 'versions')
            $parent = [IO.Path]::GetDirectoryName($root)
            if ($parent -and $parent.Equals($versions, [StringComparison]::OrdinalIgnoreCase) -and (ConvertTo-LauncherVersion -Tag ([IO.Path]::GetFileName($root))) -and
                [IO.File]::Exists([IO.Path]::Combine($root, 'local-ai-release.json'))) {
                return 'release'
            }
        }
    } catch {
        Write-Verbose "Cannot tell how $RepoRoot is installed: $($_.Exception.Message)"
    }
    return 'folder'
}

# Point the file current in the install folder $InstallRoot at the version $Tag, written as the tag and CRLF in ASCII to a flushed .tmp that replaces it in one
# step, so the shim never reads half a name. Throws naming the file when $Tag is no tag vX.Y.Z or the write fails, and removes the .tmp.
function Set-LauncherCurrent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by install.ps1 and the update verb, which ask before they change anything.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Tag
    )
    if (-not (ConvertTo-LauncherVersion -Tag $Tag)) { throw "'$Tag' is no launcher version vX.Y.Z." }
    $path = [IO.Path]::Combine([IO.Path]::GetFullPath($InstallRoot), 'current')
    $temp = "$path.tmp"
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Tag`r`n")
    try {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        $stream = New-Object IO.FileStream -ArgumentList $temp, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temp, $path, [NullString]::Value)
        } else {
            [IO.File]::Move($temp, $path)
        }
    } catch {
        $reason = $_.Exception
        while ($reason.InnerException) { $reason = $reason.InnerException }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw "Cannot write $path`: $($reason.Message)"
    }
}

# Return the text of the shim local-ai.cmd in the install folder, with CRLF line ends: it reads the tag in the file current beside it with set /p, checks that
# it is a v with digits and dots and that versions\<tag>\local-ai.cmd exists, then runs that file with every argument and without call, so that its exit code
# reaches the caller. No label, which cmd.exe misreads in a file with LF line ends, and delayed expansion only for the check, so a '!' in an argument stays.
# When cmd.exe found it through PATH under a quoted name such as "local-ai", %~dp0 is the working folder instead of its own, so it first refuses to run from
# anywhere but %LOCALAPPDATA%\Programs\local-ai-launcher, which for's %~f spells in full as cmd.exe spells %~dp0, and when LOCALAPPDATA is not set. Pure.
function Get-LauncherShimText {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $refuse = '(echo This local-ai.cmd runs only from %%LOCALAPPDATA%%\Programs\local-ai-launcher; run it by that path, or as local-ai without quotes.& exit /b 1)'
    $lines = @(
        '@echo off'
        'rem Local AI launcher: runs local-ai.cmd of the version that the file current beside this one names, from versions, with every argument.'
        'rem install.ps1 writes this file once and nothing ever rewrites it, since cmd.exe reads a running batch file again after each command.'
        'rem Without call, so that local-ai.cmd takes over and its exit code reaches the caller. No label, which cmd.exe misreads in a file with LF line ends.'
        'setlocal DisableDelayedExpansion'
        # Unset, the next line would name a folder on the current drive.
        ('if not defined LOCALAPPDATA ' + $refuse)
        'for %%i in ("%LOCALAPPDATA%\Programs\local-ai-launcher\.") do set "LOCALAI_HOME=%%~fi\"'
        ('if /i not "%~dp0"=="%LOCALAI_HOME%" ' + $refuse)
        'set "LOCALAI_TAG="'
        'if exist "%~dp0current" set /p LOCALAI_TAG=<"%~dp0current"'
        'setlocal EnableDelayedExpansion'
        'set "LOCALAI_REST=x!LOCALAI_TAG!"'
        'for %%c in (0 1 2 3 4 5 6 7 8 9 .) do set "LOCALAI_REST=!LOCALAI_REST:%%c=!"'
        'if not "!LOCALAI_REST!"=="xv" (echo The file current beside this one names no launcher version. Run install.ps1 again.& exit /b 1)'
        'endlocal'
        ('if not exist "%~dp0versions\%LOCALAI_TAG%\local-ai.cmd" (echo The launcher version %LOCALAI_TAG% is missing from the folder versions beside this one. ' +
            'Run install.ps1 again.& exit /b 1)')
        '"%~dp0versions\%LOCALAI_TAG%\local-ai.cmd" %*'
    )
    return ($lines -join "`r`n") + "`r`n"
}

# Set up the release install $Root for the version $Tag, which install.ps1 has staged in $Root\versions\$Tag (Save-LauncherRelease): create versions, write the
# shim local-ai.cmd (Get-LauncherShimText) only when it is missing, as nothing may rewrite a batch file that may be running, and point current at $Tag in one
# step. Throws when $Tag is no tag vX.Y.Z or its folder does not match its manifest. Returns @{ Root; Tag; Shim; ShimWritten }.
function Install-LocalAILauncher {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Tag
    )
    if (-not (ConvertTo-LauncherVersion -Tag $Tag)) { throw "'$Tag' is no launcher version vX.Y.Z." }
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $versions = [IO.Path]::Combine($full, 'versions')
    $null = [IO.Directory]::CreateDirectory($versions)
    $folder = [IO.Path]::Combine($versions, $Tag)
    $problems = @(Test-LauncherFolder -Path $folder -Tag $Tag)
    if ($problems.Count -gt 0) {
        throw "$folder does not match its manifest local-ai-release.json, so it does not become the active launcher: $($problems -join '; ')."
    }
    $shim = [IO.Path]::Combine($full, 'local-ai.cmd')
    $written = $false
    if (-not [IO.File]::Exists($shim)) {
        $temp = "$shim.tmp"
        [IO.File]::WriteAllText($temp, (Get-LauncherShimText), [Text.Encoding]::ASCII)
        try {
            [IO.File]::Move($temp, $shim)
        } finally {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
        $written = $true
    }
    Set-LauncherCurrent -InstallRoot $full -Tag $Tag
    return @{ Root = $full; Tag = $Tag; Shim = $shim; ShimWritten = $written }
}

# Return state.json's Launcher entry in $StatePath, @{ Version; Previous; LastCheck }, as a table, empty when it records none. Throws when state.json is not
# valid JSON. Reads only.
function Read-LauncherRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$StatePath
    )
    $state = Read-LocalAIState -Path $StatePath
    if ($state['Launcher'] -is [hashtable]) { return $state['Launcher'] }
    return @{}
}

# Record the release check $Check, @{ CheckedAt (UTC ticks); Latest (the tag, or $null); Digest; Error (why it failed, or $null) }, as state.json's
# Launcher.LastCheck in $StatePath, keeping the rest of state.json.
function Save-LauncherCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][hashtable]$Check
    )
    $state = Read-LocalAIState -Path $StatePath
    $record = if ($state['Launcher'] -is [hashtable]) { $state['Launcher'] } else { @{} }
    $record['LastCheck'] = @{ CheckedAt = [long]$Check.CheckedAt; Latest = $Check.Latest; Digest = $Check.Digest; Error = $Check.Error }
    $state['Launcher'] = $record
    Write-LocalAIState -Path $StatePath -State $state
}

# Delete the release folders in $InstallRoot\versions beyond the $Keep newest, never one $Protect names (the active, the previous and the running version and
# the one update stages), which count first. Only a folder named vX.Y.Z that holds local-ai-release.json and is no link counts. Each goes through
# Remove-LocalAIFolder, and one that cannot be deleted, as while a window works in it, gives a warning. Returns the folders it deleted.
function Remove-OldLauncherVersion {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the update verb, which offers no -WhatIf.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][ValidateRange(1, 100)][int]$Keep,
        [AllowEmptyCollection()][AllowNull()][string[]]$Protect = @()
    )
    $versions = [IO.Path]::Combine($InstallRoot, 'versions')
    if (-not [IO.Directory]::Exists($versions)) { return }
    $protected = @($Protect | Where-Object { $_ })
    $found = @(foreach ($folder in (New-Object IO.DirectoryInfo -ArgumentList $versions).GetDirectories()) {
            if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $version = ConvertTo-LauncherVersion -Tag $folder.Name
            if (-not $version -or -not [IO.File]::Exists([IO.Path]::Combine($folder.FullName, 'local-ai-release.json'))) { continue }
            [pscustomobject]@{ Tag = $folder.Name; Version = $version; Path = $folder.FullName }
        })
    $count = @($found | Where-Object { $protected -ccontains $_.Tag }).Count
    foreach ($item in @($found | Sort-Object -Property Version -Descending)) {
        if ($protected -ccontains $item.Tag) { continue }
        if ($count -lt $Keep) {
            $count++
            continue
        }
        try {
            Remove-LocalAIFolder -Path $item.Path
            $item.Path
        } catch {
            Write-Warning "Could not delete the old launcher version $($item.Path): $($_.Exception.Message)"
        }
    }
}

# Run $Script, the local-ai.ps1 of another launcher version, with $ArgumentList in Windows PowerShell with -NoProfile and the execution policy RemoteSigned for
# that run only, as local-ai.cmd does, on this console, so its questions reach the person at it; waits for it and returns its exit code.
function Invoke-LauncherChild {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Script,
        [AllowEmptyCollection()][string[]]$ArgumentList = @()
    )
    $powershell = [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $passed = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', $Script) + @($ArgumentList)
    $line = @($passed | ForEach-Object { ConvertTo-NativeArgument -Argument $_ -Quote }) -join ' '
    # No -Wait, which in 5.1 also waits for every process the child leaves running, such as the Ollama app.
    $process = Start-Process -FilePath $powershell -ArgumentList $line -NoNewWindow -PassThru -ErrorAction Stop
    # 5.1 reports no ExitCode unless the handle was opened while the process ran.
    $null = $process.Handle
    $process.WaitForExit()
    return [int]$process.ExitCode
}

# Hand this run over to another launcher version: stop the transcript and release the single-instance lock that Context.Hold holds (Invoke-LocalAI), so that
# the other version's run, which waits for the lock, can take it; then run its local-ai.ps1 $Script with $ArgumentList (Invoke-LauncherChild) and return its
# exit code, or 1 for a code other than 0, 1 and 2.
function Invoke-LauncherHandover {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Script,
        [AllowEmptyCollection()][string[]]$ArgumentList = @()
    )
    $hold = $Context.Hold
    if ($hold -is [hashtable]) {
        if ($hold.Transcribing) {
            $hold.Transcribing = $false
            try { $null = Stop-Transcript } catch { Write-Verbose "The transcript was stopped already: $($_.Exception.Message)" }
        }
        Exit-LocalAILock -Mutex $hold.Mutex
        $hold.Mutex = $null
    }
    $code = Invoke-LauncherChild -Script $Script -ArgumentList $ArgumentList
    if (@(0, 1, 2) -notcontains $code) {
        Write-Host "The launcher in $(Split-Path (Split-Path $Script -Parent) -Parent) ended with exit code $code." -ForegroundColor Red
        return 1
    }
    return $code
}

# The first step of update, before Update-LocalAI, unless this run is the one update handed over to (Context.ActivateLauncher): a release install asks
# Launcher.Repo for its latest release (Get-LauncherRelease, 15 s) and records the answer as state.json's Launcher.LastCheck. A newer one is staged
# (Save-LauncherRelease), then old ones are pruned (Remove-OldLauncherVersion), and this run hands over to it with update -ActivateLauncher <tag>. Returns
# $null to go on in this version: for a git checkout or another folder, when there is no newer release, and with a warning when GitHub or the download
# cannot be reached; else the exit code of the version handed over to, or 1 when the release or the staged folder fails a check, which changes nothing.
function Invoke-LauncherSelfUpdate {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    if ($Context.ActivateLauncher) { return $null }
    $repoRoot = [string]$Context.RepoRoot
    $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
    $kind = Get-LauncherInstallKind -RepoRoot $repoRoot -InstallRoot $installRoot
    if ($kind -eq 'git') {
        Write-Host ("This launcher runs from the git checkout $repoRoot, so update leaves its own code alone: update it with 'git pull' on main, or " +
            'install a release with install.ps1.')
        return $null
    }
    if ($kind -eq 'folder') {
        Write-Host ("This launcher runs from $repoRoot, which is no release install, so update leaves its own code alone; install.ps1 of a release installs " +
            'a launcher that updates itself.')
        return $null
    }
    $running = [IO.Path]::GetFileName($repoRoot.TrimEnd('\'))
    $launcher = $Context.Settings.Launcher
    $repo = [string]$launcher.Repo
    $agent = "local-ai-launcher/$($running.Substring(1))"
    $refused = {
        param([string]$Why)
        Write-Host $Why -ForegroundColor Red
        Write-Host 'Update changed nothing.' -ForegroundColor Red
    }
    Write-Host "Checking $repo for a launcher newer than $running..."
    $check = @{ CheckedAt = [DateTime]::UtcNow.Ticks; Latest = $null; Digest = $null; Error = $null }
    $stage = $null
    try {
        $release = Get-LauncherRelease -Repo $repo -TimeoutSeconds 15 -RequireImmutable ([bool]$launcher.RequireImmutable) -UserAgent $agent
        $check.Latest = $release.Tag
        $check.Digest = $release.Digest
        $order = (ConvertTo-LauncherVersion -Tag $release.Tag).CompareTo((ConvertTo-LauncherVersion -Tag $running))
        if ($order -eq 0) {
            Write-Host "The launcher is at the latest release $running."
        } elseif ($order -lt 0) {
            Write-Host "The launcher $running is newer than the latest release $($release.Tag), and update never downgrades."
        } else {
            $release.Commit = Get-LauncherTagCommit -Repo $repo -Tag $release.Tag -TimeoutSeconds 15 -UserAgent $agent
            $stage = $release
        }
    } catch {
        $problem = $_.Exception.Data['LauncherProblem']
        $check.Latest = $null
        $check.Digest = $null
        $check.Error = $_.Exception.Message
        Save-LauncherCheck -StatePath $Context.Paths.State -Check $check
        if ($problem -eq 'Unreachable') {
            Write-Warning "Could not check for a newer launcher ($($_.Exception.Message)); it stays at $running."
            return $null
        }
        & $refused $_.Exception.Message
        return 1
    }
    Save-LauncherCheck -StatePath $Context.Paths.State -Check $check
    if (-not $stage) { return $null }

    Write-Host "The launcher $($stage.Tag) is out, and this one is $running."
    $target = [IO.Path]::Combine($installRoot, 'versions', $stage.Tag)
    if ([IO.Directory]::Exists($target)) {
        Write-Host "Checking $target, which an earlier update staged, against its manifest..."
    } else {
        Write-Host "Downloading $($stage.Asset) from $repo..."
    }
    try {
        $staged = Save-LauncherRelease -Release $stage -InstallRoot $installRoot -UserAgent $agent
    } catch {
        if ($_.Exception.Data['LauncherProblem'] -eq 'Unreachable') {
            Write-Warning "Could not download the launcher $($stage.Tag) ($($_.Exception.Message)); it stays at $running."
            return $null
        }
        & $refused $_.Exception.Message
        return 1
    }
    if ($staged.Downloaded) { Write-Host "The download matches the SHA-256 GitHub lists, and every file matches the release's manifest." }
    # Only once the new version is in place, so that a release that fails a check deletes nothing, and that version counts.
    $previous = [string](Read-LauncherRecord -StatePath $Context.Paths.State)['Previous']
    $protect = @((Get-LauncherCurrent -InstallRoot $installRoot), $previous, $running, $stage.Tag)
    foreach ($removed in @(Remove-OldLauncherVersion -InstallRoot $installRoot -Keep ([int]$launcher.KeepVersions) -Protect $protect)) {
        Write-Host "Deleted the old launcher version $removed, as Launcher.KeepVersions keeps $($launcher.KeepVersions)."
    }
    Write-Host "Handing over to the launcher $($stage.Tag) in $($staged.Path), which shows the update plan and asks before it changes anything."
    $arguments = @('update')
    if ($Context.Tools) { $arguments += '-Tools' }
    $arguments += @('-ActivateLauncher', $stage.Tag)
    $code = Invoke-LauncherHandover -Context $Context -Script ([IO.Path]::Combine($staged.Path, 'src\local-ai.ps1')) -ArgumentList $arguments
    if ((Get-LauncherCurrent -InstallRoot $installRoot) -cne $stage.Tag) {
        Write-Host "The launcher stays at $running, and $($stage.Tag) waits in $($staged.Path) for the next update." -ForegroundColor Yellow
    }
    return $code
}

# Return what update -ActivateLauncher <tag> changes, after it checks that this run is that version, InstallRoot\versions\<tag>, whose folder matches its
# manifest: @{ From (the version current names, or 'none'); To; Line, the plan's first line 'Launcher: <from> -> <to> (<Launcher.Repo>, <digest>)' with the
# digest that state.json's last check recorded for <tag>; InstallRoot }; $null when <tag> is active already. Throws when a check fails.
function Get-LauncherActivation {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $tag = [string]$Context.ActivateLauncher
    $repoRoot = [string]$Context.RepoRoot
    $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
    if ((Get-LauncherInstallKind -RepoRoot $repoRoot -InstallRoot $installRoot) -ne 'release' -or [IO.Path]::GetFileName($repoRoot.TrimEnd('\')) -cne $tag) {
        throw "update -ActivateLauncher $tag runs only from $([IO.Path]::Combine([string]$installRoot, 'versions', $tag)), not from $repoRoot. Nothing was changed."
    }
    $problems = @(Test-LauncherFolder -Path $repoRoot -Tag $tag)
    if ($problems.Count -gt 0) {
        throw "$repoRoot does not match its manifest local-ai-release.json, so it does not become the active launcher: $($problems -join '; '). Nothing was changed."
    }
    $current = Get-LauncherCurrent -InstallRoot $installRoot
    if ($current -ceq $tag) { return $null }
    $check = (Read-LauncherRecord -StatePath $Context.Paths.State)['LastCheck']
    $digest = if ($check -is [hashtable] -and [string]$check.Latest -ceq $tag) { [string]$check.Digest } else { '' }
    # A current that names no version, which the shim refuses, as when this version runs straight from its folder.
    $from = if ($current) { $current } else { 'none' }
    $source = @(@([string]$Context.Settings.Launcher.Repo, $digest) | Where-Object { $_ }) -join ', '
    return @{ From = $from; To = $tag; Line = "Launcher: $from -> $tag ($source)"; InstallRoot = $installRoot }
}

# Make $Tag the active launcher version of the install folder $InstallRoot: write current (Set-LauncherCurrent), then record in state.json at $StatePath
# Launcher.Version $Tag and Launcher.Previous, the version current named before, keeping Launcher.LastCheck. Reads state.json first, so a broken one stops it
# before anything changes, and points current back when state.json cannot be written, so that it changes all or nothing. Returns the version current named
# before.
function Enable-LauncherVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$StatePath
    )
    $state = Read-LocalAIState -Path $StatePath
    $before = Get-LauncherCurrent -InstallRoot $InstallRoot
    Set-LauncherCurrent -InstallRoot $InstallRoot -Tag $Tag
    try {
        $record = if ($state['Launcher'] -is [hashtable]) { $state['Launcher'] } else { @{} }
        $record['Version'] = $Tag
        if ($before -and $before -cne $Tag) { $record['Previous'] = $before }
        $state['Launcher'] = $record
        Write-LocalAIState -Path $StatePath -State $state
    } catch {
        $failed = $_
        if ($before -and $before -cne $Tag) {
            try {
                Set-LauncherCurrent -InstallRoot $InstallRoot -Tag $before
            } catch {
                Write-Warning "Could not point current back at $before`: $($_.Exception.Message)"
            }
        }
        throw $failed
    }
    return $before
}

# update -Rollback, which asks GitHub nothing itself: go back to the launcher version state.json records as Launcher.Previous, when its folder in versions
# matches its manifest. Warns that Open WebUI may meet data the newer version migrated, asks for the typed word rollback and hands over to its update (update
# -ActivateLauncher <tag>) while current still names this version. So that run's plan starts with 'Launcher: <this> -> <tag>', and only its yes, once its
# settings loaded, the parts were checked and what runs was stopped, points current back (Enable-LauncherVersion) and brings the parts back to its pins.
# Returns that run's exit code; 2 when declined; 1 when this is no release install or there is no version to go back to.
function Invoke-LauncherRollback {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )
    $repoRoot = [string]$Context.RepoRoot
    $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
    if ((Get-LauncherInstallKind -RepoRoot $repoRoot -InstallRoot $installRoot) -ne 'release') {
        Write-Host ("update -Rollback goes back to the launcher version that ran before the last update, which only a release install keeps, but this launcher " +
            "runs from $repoRoot. Nothing was changed.") -ForegroundColor Red
        return 1
    }
    $current = Get-LauncherCurrent -InstallRoot $installRoot
    if (-not $current) { $current = [IO.Path]::GetFileName($repoRoot.TrimEnd('\')) }
    $previous = [string](Read-LauncherRecord -StatePath $Context.Paths.State)['Previous']
    $versions = [IO.Path]::Combine($installRoot, 'versions')
    $folder = if (ConvertTo-LauncherVersion -Tag $previous) { [IO.Path]::Combine($versions, $previous) } else { $null }
    $problem = $null
    if (-not $folder -or $previous -ceq $current) {
        $problem = "state.json records no launcher version before $current, so there is nothing to go back to."
    } elseif (-not [IO.Directory]::Exists($folder)) {
        $problem = "$previous, the launcher version before $current, is no longer in $versions, so there is nothing to go back to."
    } else {
        $problems = @(Test-LauncherFolder -Path $folder -Tag $previous)
        if ($problems.Count -gt 0) { $problem = "$folder does not match its manifest local-ai-release.json, so update -Rollback does not go back to it: $($problems -join '; ')." }
    }
    if ($problem) {
        Write-Host "$problem Nothing was changed." -ForegroundColor Red
        return 1
    }
    Write-Host ''
    Write-Host 'Rollback plan:'
    Write-Host "  Launcher: $current -> $previous, from $folder"
    Write-Host "Then the update of $previous shows its own plan, with the launcher and the parts back at its pins, and asks before it changes anything."
    Write-Warning ("Open WebUI may meet data that $current has already migrated to its newer version, which an older Open WebUI may not read; the backups in " +
        "$($Context.Paths.Backups) are the fallback.")
    if (-not (Confirm-LocalAIAction -Question "Go back to the launcher ${previous}?" -Word 'rollback')) {
        Write-Host "Nothing was changed; the launcher stays at $current." -ForegroundColor Yellow
        return 2
    }
    # current stays until that run's yes, so a no, or settings that version does not accept, leave the launcher as it is.
    Write-Host "Handing over to the update of $previous in $folder."
    $arguments = @('update')
    if ($Context.Tools) { $arguments += '-Tools' }
    $arguments += @('-ActivateLauncher', $previous)
    $code = Invoke-LauncherHandover -Context $Context -Script ([IO.Path]::Combine($folder, 'src\local-ai.ps1')) -ArgumentList $arguments
    if ((Get-LauncherCurrent -InstallRoot $installRoot) -cne $previous) {
        Write-Host "The launcher stays at $current, and 'local-ai update -Rollback' can still go back to $previous." -ForegroundColor Yellow
    }
    return $code
}

# start's look for a newer launcher, which never changes start's exit code or throws: while Launcher.CheckForUpdates is on, for a release install, at most
# once per Launcher.CheckIntervalHours after state.json's Launcher.LastCheck, ask Launcher.Repo for its latest release (Get-LauncherRelease, 5 s), record the
# answer or the reason it failed as LastCheck, and print one line, naming 'local-ai update' and the Start menu shortcut Update Local AI, when that release is
# newer than this one. A start before the check is due again prints nothing, also while LastCheck records a newer release. $NowTicks stands in for the time.
# Returns $true when it printed that line, else $false.
function Invoke-LauncherPassiveCheck {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [long]$NowTicks = [DateTime]::UtcNow.Ticks
    )
    try {
        $launcher = $Context.Settings.Launcher
        if ($launcher -isnot [hashtable] -or -not $launcher.CheckForUpdates) { return $false }
        $repoRoot = [string]$Context.RepoRoot
        $installRoot = if ($Context.InstallRoot) { [string]$Context.InstallRoot } else { Get-LauncherInstallRoot -LocalAppData $env:LOCALAPPDATA }
        if ((Get-LauncherInstallKind -RepoRoot $repoRoot -InstallRoot $installRoot) -ne 'release') { return $false }
        $last = (Read-LauncherRecord -StatePath $Context.Paths.State)['LastCheck']
        $checkedAt = if ($last -is [hashtable]) { [long]$last.CheckedAt } else { [long]0 }
        $interval = [TimeSpan]::FromHours([int]$launcher.CheckIntervalHours).Ticks
        # A check in the future, as after the clock was set back, counts as due.
        if ($checkedAt -gt 0 -and $checkedAt -le $NowTicks -and $NowTicks - $checkedAt -lt $interval) { return $false }
        $running = [IO.Path]::GetFileName($repoRoot.TrimEnd('\'))
        $check = @{ CheckedAt = $NowTicks; Latest = $null; Digest = $null; Error = $null }
        try {
            $release = Get-LauncherRelease -Repo ([string]$launcher.Repo) -TimeoutSeconds 5 -RequireImmutable ([bool]$launcher.RequireImmutable) `
                -UserAgent "local-ai-launcher/$($running.Substring(1))"
            $check.Latest = $release.Tag
            $check.Digest = $release.Digest
        } catch {
            $check.Error = $_.Exception.Message
        }
        Save-LauncherCheck -StatePath $Context.Paths.State -Check $check
        if ($check.Latest -and (ConvertTo-LauncherVersion -Tag $check.Latest) -gt (ConvertTo-LauncherVersion -Tag $running)) {
            Write-Host ("The launcher $($check.Latest) is out, and this one is $running; 'local-ai update' or the Start menu shortcut 'Update Local AI' " +
                'installs it.') -ForegroundColor Cyan
            return $true
        }
    } catch {
        Write-Verbose "The look for a newer launcher failed: $($_.Exception.Message)"
    }
    return $false
}

# Return what status shows about the launcher's own releases for the launcher in $RepoRoot, without the network and writing nothing: @{ Data (kind, latest,
# checkedAt, updateAvailable and checkError, for -Json); Lines }. For a release install in $InstallRoot: the active and the previous version, the active
# folder against its manifest (degraded on a change), the latest release state.json's Launcher.LastCheck in $State records, 'last checked' once that is
# older than 7 days, and Launcher.Repo of $Settings when it is not $DefaultRepo. $NowTicks stands in for the time.
function Get-LauncherStatus {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][AllowNull()][string]$InstallRoot,
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()][hashtable]$Settings,
        [AllowEmptyString()][AllowNull()][string]$DefaultRepo,
        [long]$NowTicks = [DateTime]::UtcNow.Ticks
    )
    $kind = Get-LauncherInstallKind -RepoRoot $RepoRoot -InstallRoot $InstallRoot
    $data = [ordered]@{ kind = $kind; latest = $null; checkedAt = $null; updateAvailable = $false; checkError = $null }
    $lines = New-Object System.Collections.Generic.List[object]
    $add = { param([string]$Level, [string]$Text) $lines.Add([ordered]@{ level = $Level; text = $Text }) }
    if ($kind -eq 'git') {
        & $add 'fact' "This is a git checkout, so update leaves the launcher's own code to git ('git pull' on main)."
        return @{ Data = $data; Lines = $lines }
    }
    if ($kind -eq 'folder') {
        & $add 'info' ("$RepoRoot is no release install and no git checkout, so update leaves the launcher's own code alone; install.ps1 of a release installs " +
            'a launcher that updates itself.')
        return @{ Data = $data; Lines = $lines }
    }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $running = [IO.Path]::GetFileName($RepoRoot.TrimEnd('\'))
    $versions = [IO.Path]::Combine($InstallRoot, 'versions')
    $current = Get-LauncherCurrent -InstallRoot $InstallRoot
    if (-not $current) {
        & $add 'degraded' ("The file current in $InstallRoot names no launcher version, so its local-ai.cmd and the Start menu shortcuts cannot start the " +
            'launcher. Run install.ps1 again.')
    } else {
        & $add 'fact' "Release install in $InstallRoot, where current names $current."
        if ($current -cne $running) {
            & $add 'info' "This run is $running from $RepoRoot, but current names $current, which local-ai.cmd in $InstallRoot and the Start menu shortcuts run."
        }
        $active = [IO.Path]::Combine($versions, $current)
        $problems = @(Test-LauncherFolder -Path $active -Tag $current)
        if ($problems.Count -gt 0) {
            $more = if ($problems.Count -gt 5) { "; and $($problems.Count - 5) more" } else { '' }
            & $add 'degraded' ("$active does not match its manifest local-ai-release.json: $(@($problems | Select-Object -First 5) -join '; ')$more. A release folder " +
                "never changes after install; to put it back, move the folder aside, then run install.ps1 -Tag $current.")
        } else {
            & $add 'fact' "Every file of $current in $versions matches its manifest."
        }
    }
    $record = if ($State['Launcher'] -is [hashtable]) { $State['Launcher'] } else { @{} }
    $previous = [string]$record['Previous']
    if ((ConvertTo-LauncherVersion -Tag $previous) -and $previous -cne $current -and [IO.Directory]::Exists([IO.Path]::Combine($versions, $previous))) {
        & $add 'fact' "$previous, the version before, stays in $versions for 'local-ai update -Rollback'."
    } else {
        & $add 'info' "No earlier version is kept in $versions, so 'local-ai update -Rollback' has nothing to go back to."
    }
    $launcher = if ($Settings -and $Settings.Launcher -is [hashtable]) { $Settings.Launcher } else { $null }
    $check = $record['LastCheck']
    $base = if ($current) { $current } else { $running }
    if ($check -is [hashtable] -and [long]$check.CheckedAt -gt 0) {
        $when = New-Object DateTime -ArgumentList ([long]$check.CheckedAt), ([DateTimeKind]::Utc)
        $data.checkedAt = $when.ToString('yyyy-MM-ddTHH:mm:ssZ', $culture)
        $shown = $when.ToLocalTime().ToString('yyyy-MM-dd HH:mm', $culture)
        $stale = $NowTicks - [long]$check.CheckedAt -gt [TimeSpan]::FromDays(7).Ticks
        $latest = [string]$check.Latest
        if ($check.Error) {
            $data.checkError = [string]$check.Error
            & $add 'info' "The last check for a newer launcher, on $shown, failed: $($check.Error)"
        } elseif (ConvertTo-LauncherVersion -Tag $latest) {
            $data.latest = $latest
            $data.updateAvailable = (ConvertTo-LauncherVersion -Tag $latest) -gt (ConvertTo-LauncherVersion -Tag $base)
            $checked = if ($stale) { "last checked $shown" } else { "checked $shown" }
            if ($data.updateAvailable) {
                & $add 'info' "The launcher $latest is out, $checked; 'local-ai update' installs it."
            } elseif ($stale) {
                & $add 'info' "$latest was the latest release when last checked $shown; 'local-ai update' checks again."
            } else {
                & $add 'fact' "$latest is the latest release, checked $shown."
            }
        }
    } else {
        & $add 'info' "No check for a newer launcher has run yet; 'local-ai update' checks."
    }
    if ($launcher -and -not $launcher.CheckForUpdates) {
        & $add 'info' 'Launcher.CheckForUpdates is off, so start does not check for a newer launcher; update still does.'
    }
    if ($launcher -and $DefaultRepo -and [string]$launcher.Repo -ine $DefaultRepo) {
        & $add 'info' ("Launcher.Repo names $($launcher.Repo), not $DefaultRepo, so update installs the releases of $($launcher.Repo): settings.psd1 trusts " +
            'whoever publishes them with the code the launcher runs.')
    }
    return @{ Data = $data; Lines = $lines }
}

# Return what uninstall removes of the launcher itself: @{ Root; PathEntry } for a release install, its install folder $InstallRoot and whether the user's
# Path names it (Test-LauncherUserPath); $null for a git checkout or another folder, whose files uninstall never deletes. Reads only.
function Get-LauncherUninstallPlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][AllowNull()][string]$InstallRoot
    )
    if ((Get-LauncherInstallKind -RepoRoot $RepoRoot -InstallRoot $InstallRoot) -ne 'release') { return $null }
    $inPath = $false
    try {
        $inPath = Test-LauncherUserPath -Entry $InstallRoot
    } catch {
        Write-Verbose "The user's Path cannot be read: $($_.Exception.Message)"
    }
    return @{ Root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\'); PathEntry = $inPath }
}

# Return @{ Id; StartTicks } for this PowerShell process and, when cmd.exe started it, for that cmd.exe, which still runs local-ai.cmd once PowerShell has
# exited: the processes the uninstall cleanup waits for. Reads only.
function Get-LauncherConsoleProcess {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $own = [Diagnostics.Process]::GetCurrentProcess()
    try {
        @{ Id = $own.Id; StartTicks = $own.StartTime.ToUniversalTime().Ticks }
        $self = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($own.Id)" -ErrorAction SilentlyContinue
        if (-not $self) { return }
        $parent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$([int]$self.ParentProcessId)" -ErrorAction SilentlyContinue
        # A parent created after this process holds a PID that was used again.
        if ($parent -and [string]$parent.Name -eq 'cmd.exe' -and $parent.CreationDate -and $self.CreationDate -and $parent.CreationDate -le $self.CreationDate) {
            @{ Id = [int]$parent.ProcessId; StartTicks = $parent.CreationDate.ToUniversalTime().Ticks }
        }
    } finally {
        $own.Dispose()
    }
}

# Return the hidden process that deletes the install folder $InstallRoot once uninstall's window has closed: @{ FilePath (powershell.exe); ArgumentList, with
# the script as -EncodedCommand, never from a file in that folder; WorkingDirectory ($TempPath); Script }. The script waits for each process of $WaitFor,
# @{ Id; StartTicks }, to exit, then deletes exactly $InstallRoot, only while it holds current and versions and is no link, and while current still has the
# write time $CurrentTicks (UTC ticks) that it had at uninstall, as install.ps1 writes current anew; within 15 minutes in all, and notes what it did or why
# it gave up in $LogPath. Throws for a folder not named local-ai-launcher. Pure.
function New-LauncherCleanupCommand {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: it only builds the command.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [AllowEmptyCollection()][hashtable[]]$WaitFor = @(),
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][long]$CurrentTicks,
        [string]$TempPath = [IO.Path]::GetTempPath()
    )
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if ([IO.Path]::GetFileName($root) -cne 'local-ai-launcher') { throw "$root is no install folder of the launcher, so uninstall does not delete it." }
    # A process whose PID and start time match is the one uninstall ran in; a PID used again since then is another process. The write time of current is
    # checked before each try to move the folder aside, as a window still working in the folder can keep it for a while; once moved, only that copy goes.
    $template = @'
$ErrorActionPreference = 'Stop'
$root = @ROOT@
$log = @LOG@
$waits = @(@WAITS@)
$written = @WRITTEN@
$deadline = [DateTime]::UtcNow.AddMinutes(15)
function Write-Note([string]$Text) {
    try { [IO.File]::AppendAllText($log, ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text) + "`r`n") } catch { $null = $_ }
}
foreach ($wait in $waits) {
    try { $process = [Diagnostics.Process]::GetProcessById([int]$wait.Id) } catch { continue }
    try { $ticks = $process.StartTime.ToUniversalTime().Ticks } catch { continue }
    if ([Math]::Abs($ticks - [long]$wait.Ticks) -ge [TimeSpan]::TicksPerSecond) { continue }
    $left = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($left -le 0 -or -not $process.WaitForExit([int]$left)) {
        Write-Note "Gave up after 15 minutes, as the window that ran local-ai uninstall (PID $($wait.Id)) is still open. $root stays; delete it once that window is closed."
        exit 1
    }
}
$folder = New-Object IO.DirectoryInfo -ArgumentList $root
if (-not $folder.Exists) {
    Write-Note "$root is gone already."
    exit 0
}
if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    Write-Note "Did not delete $root, as it is a junction or symbolic link."
    exit 1
}
if (-not ([IO.File]::Exists([IO.Path]::Combine($root, 'current')) -and [IO.Directory]::Exists([IO.Path]::Combine($root, 'versions')))) {
    Write-Note "Did not delete $root, as it does not hold current and versions as the launcher's install folder does."
    exit 1
}
$aside = '{0}.local-ai-removing-{1:yyyyMMddHHmmss}' -f $root, (Get-Date)
while ($true) {
    try {
        if (-not [IO.Directory]::Exists($aside) -and [IO.Directory]::Exists($root)) {
            if ([IO.File]::GetLastWriteTimeUtc([IO.Path]::Combine($root, 'current')).Ticks -ne $written) {
                Write-Note "Did not delete $root, as it was set up again after uninstall."
                exit 0
            }
            [IO.Directory]::Move($root, $aside)
        }
        [IO.Directory]::Delete($aside, $true)
        if ([IO.Directory]::Exists($root)) {
            Write-Note "Deleted $aside, where uninstall had moved $root. $root was set up again meanwhile and stays."
        } else {
            Write-Note "Deleted $root."
        }
        exit 0
    } catch {
        if ([DateTime]::UtcNow -ge $deadline) {
            $left = if ([IO.Directory]::Exists($aside)) { $aside } else { $root }
            Write-Note "Gave up after 15 minutes, as $left cannot be deleted: $($_.Exception.Message) Delete it once nothing uses it."
            exit 1
        }
        Start-Sleep -Seconds 5
    }
}
'@
    # PowerShell also reads the typographic single quotes, which a user name may hold, as quotes.
    $quote = { param([string]$Text) "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'" }
    $waits = @(foreach ($process in $WaitFor) { '@{{ Id = {0}; Ticks = {1} }}' -f [int]$process.Id, [long]$process.StartTicks }) -join ', '
    $script = $template.Replace('@ROOT@', (& $quote $root)).Replace('@LOG@', (& $quote $LogPath)).Replace('@WAITS@', $waits).Replace('@WRITTEN@',
        $CurrentTicks.ToString([Globalization.CultureInfo]::InvariantCulture))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    return @{
        FilePath         = [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\powershell.exe')
        ArgumentList     = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
        WorkingDirectory = $TempPath
        Script           = $script
    }
}

# Start, hidden, the process New-LauncherCleanupCommand builds to delete the install folder $InstallRoot once this run's console processes
# (Get-LauncherConsoleProcess) have exited, unless current was written since then, with its log local-ai-uninstall-cleanup.log in the temp folder. Returns
# that log's path; throws when the process cannot start.
function Start-LauncherCleanup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the uninstall verb, which asks before it changes anything.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$InstallRoot
    )
    $log = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'local-ai-uninstall-cleanup.log')
    $written = [IO.File]::GetLastWriteTimeUtc([IO.Path]::Combine($InstallRoot, 'current')).Ticks
    $command = New-LauncherCleanupCommand -InstallRoot $InstallRoot -WaitFor @(Get-LauncherConsoleProcess) -LogPath $log -CurrentTicks $written
    Start-Process -FilePath $command.FilePath -ArgumentList $command.ArgumentList -WorkingDirectory $command.WorkingDirectory -WindowStyle Hidden -ErrorAction Stop
    return $log
}

# Return the launcher verbs: the module function each runs, the switches it accepts, whether it
# still runs when settings fail to load (Settings is then $null and SettingsError says why), whether its
# transcript goes to %TEMP%, how it takes the single-instance lock (Lock), and Redirected.
function Get-LocalAIVerb {
    # TranscriptInTemp: uninstall may delete Root, and status writes nothing below it. Lock: Fail
    # gives up when another run holds the lock, Wait waits up to 300 s for it, and Probe never takes
    # it, so a start is not refused, and only notes another run (LockHeld). Redirected: Refuse stops the
    # verb when Windows would put its AppData folders into an app package's private store, or Root has a
    # private copy there; Warn runs it, so status can report both.
    return @{
        install   = @{ Function = 'Install-LocalAI'; Switches = @(); SettingsOptional = $false; TranscriptInTemp = $false; Lock = 'Wait'; Redirected = 'Refuse' }
        start     = @{ Function = 'Start-LocalAI'; Switches = @('NoBrowser'); SettingsOptional = $false; TranscriptInTemp = $false; Lock = 'Fail'; Redirected = 'Refuse' }
        stop      = @{ Function = 'Stop-LocalAI'; Switches = @(); SettingsOptional = $true; TranscriptInTemp = $false; Lock = 'Wait'; Redirected = 'Refuse' }
        status    = @{ Function = 'Get-LocalAIStatus'; Switches = @('Json'); SettingsOptional = $true; TranscriptInTemp = $true; Lock = 'Probe'; Redirected = 'Warn' }
        update    = @{ Function = 'Update-LocalAI'; Switches = @('Tools', 'Rollback'); SettingsOptional = $false; TranscriptInTemp = $false; Lock = 'Wait'; Redirected = 'Refuse' }
        uninstall = @{ Function = 'Uninstall-LocalAI'; Switches = @('RemoveData'); SettingsOptional = $true; TranscriptInTemp = $true; Lock = 'Wait'; Redirected = 'Refuse' }
        shortcuts = @{ Function = 'Set-LocalAIShortcut'; Switches = @('Remove'); SettingsOptional = $false; TranscriptInTemp = $false; Lock = 'Wait'; Redirected = 'Refuse' }
    }
}

# Run one launcher verb under the single-instance lock, as its Lock says, with a transcript (Root\logs, or %TEMP% for status and uninstall), calling
# its module function with a context table; first refuse it, unless its Redirected is Warn, when $LocalAppData or the known folder $ShellLocalAppData is
# redirected into an app package's store, or Root has a private copy there. update starts with the launcher's own release (Invoke-LauncherSelfUpdate, or
# Invoke-LauncherRollback with -Rollback), which may hand the run over to another version; -ActivateLauncher <tag> marks the run handed over to. After start,
# Invoke-LauncherPassiveCheck; when that printed that a newer launcher is out and start ends with 0, Wait-LocalAIConsoleKey once the transcript has stopped
# and the lock is released. Prints any error with its stack and the transcript path, as one JSON line with -Json. Returns 0, 1 or 2 (degraded).
function Invoke-LocalAI {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$Verb = 'start',
        [switch]$Json,
        [switch]$Tools,
        [switch]$Remove,
        [switch]$RemoveData,
        [switch]$NoBrowser,
        [switch]$Rollback,
        [string]$ActivateLauncher = '',
        [string]$Root = (Join-Path $env:LOCALAPPDATA 'local-ai'),
        [string]$DefaultsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\defaults.psd1'),
        [string]$LockName = 'Local\LocalAILauncher',
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$AppData = $env:APPDATA,
        [string]$ShellLocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
    )
    $transcript = $null
    # The lock and whether the transcript runs, in a table, so that a handover to another launcher version (Invoke-LauncherHandover) can end both first.
    $hold = @{ Mutex = $null; Transcribing = $false }
    try {
        $verbs = Get-LocalAIVerb
        $Verb = $Verb.ToLowerInvariant()
        if (-not $verbs.ContainsKey($Verb)) {
            throw "Unknown command '$Verb'. Use one of: $(@($verbs.Keys | Sort-Object) -join ', ')."
        }
        $spec = $verbs[$Verb]
        $given = [ordered]@{ Json = [bool]$Json; Tools = [bool]$Tools; Remove = [bool]$Remove; RemoveData = [bool]$RemoveData; NoBrowser = [bool]$NoBrowser
            Rollback = [bool]$Rollback }
        foreach ($name in $given.Keys) {
            if ($given[$name] -and $spec.Switches -notcontains $name) { throw "-$name does not apply to '$Verb'." }
        }
        # The hidden part of update's contract between launcher versions, which the one that hands over passes.
        if ($ActivateLauncher) {
            if ($Verb -ne 'update') { throw "-ActivateLauncher does not apply to '$Verb'." }
            if (-not (ConvertTo-LauncherVersion -Tag $ActivateLauncher)) { throw "-ActivateLauncher '$ActivateLauncher' names no launcher version vX.Y.Z." }
            if ($Rollback) { throw '-ActivateLauncher does not go with -Rollback.' }
        }

        # A process inside an app package's container, such as one the Claude desktop app starts, has its new AppData folders put into the package's
        # private store, where other windows never see them (Get-AppDataRedirection). So before the lock, the transcript, the settings or the state, a
        # verb whose Redirected is Refuse stops there, and while a private copy of Root exists; status runs and reports both.
        $resolve = $ExecutionContext.SessionState.Path
        $paths = Get-LocalAIPaths -Root $resolve.GetUnresolvedProviderPathFromPSPath($Root)
        $redirection = Get-AppDataRedirection -LocalAppData $LocalAppData
        # The container redirects the known folder, which installers and the shortcuts use, also while %LOCALAPPDATA% names another folder.
        $sameFolder = [string]::Equals($ShellLocalAppData.TrimEnd('\'), $LocalAppData.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        if (-not $redirection -and $ShellLocalAppData -and -not $sameFolder) { $redirection = Get-AppDataRedirection -LocalAppData $ShellLocalAppData }
        if ($spec.Redirected -ne 'Warn') {
            # The command to run elsewhere keeps the switches given; the Start menu shortcuts run start, stop and update without any.
            $line = (@($Verb) + @($given.Keys | Where-Object { $given[$_] } | ForEach-Object { "-$_" })) -join ' '
            if ($redirection) {
                $shortcut = @{ start = 'Start Local AI'; stop = 'Stop Local AI'; update = 'Update Local AI' }[$line]
                $route = if ($shortcut) { ", or use the Start menu shortcut '$shortcut'" } else { '' }
                throw ("$(Format-AppDataRedirection -Redirection $redirection), so the launcher's files would land where other windows never see them. " +
                    "Nothing was changed. Run 'local-ai $line' from a console window or Windows Terminal$route.")
            }
            $copies = @(Find-LocalAIPrivateCopy -Path $paths.Root -LocalAppData $LocalAppData -AppData $AppData)
            if ($copies.Count -gt 0) {
                $named = if ($copies.Count -gt 1) { "$($copies[0..($copies.Count - 2)] -join ', ') and $($copies[-1]) are private copies" } else { "$($copies[0]) is a private copy" }
                $them = if ($copies.Count -gt 1) { 'them' } else { 'it' }
                throw ("$named of $($paths.Root) that Windows made for a window inside an app package, and a window inside that package sees the copy " +
                    "instead of the real folder. Nothing was changed. Move $them aside, out of %LOCALAPPDATA%\Packages (a copy may hold logs or state the " +
                    "real folder lacks), then run 'local-ai $line' again.")
            }
        }

        # A second start gives up at once; status, which only reads, runs beside another run; the other verbs queue behind it.
        $lockHeld = $false
        if ($spec.Lock -eq 'Probe') {
            $lockHeld = Test-LocalAILockHeld -Name $LockName
        } else {
            $hold.Mutex = Enter-LocalAILock -Name $LockName -TimeoutSeconds 0
            if (-not $hold.Mutex) {
                if ($spec.Lock -eq 'Fail') { throw 'Another launcher run is active. Wait for it to finish, then try again.' }
                # -Json output holds one JSON document and nothing else.
                if (-not $Json) { Write-Host 'Another launcher run is active; waiting up to 300 s for it to finish...' }
                $hold.Mutex = Enter-LocalAILock -Name $LockName -TimeoutSeconds 300
                if (-not $hold.Mutex) { throw 'Another launcher run held the lock for 300 s. Try again once it has finished.' }
            }
        }

        $defaults = $resolve.GetUnresolvedProviderPathFromPSPath($DefaultsPath)
        if ($spec.TranscriptInTemp) {
            $logDir = [IO.Path]::GetTempPath()
            $prefix = 'local-ai-launcher'
        } else {
            $logDir = $paths.Logs
            $prefix = 'launcher'
            $null = [IO.Directory]::CreateDirectory($logDir)
        }
        $transcript = Join-Path $logDir ('{0}-{1:yyyyMMdd-HHmmss-fff}-{2}.log' -f $prefix, (Get-Date), $Verb)
        # The newest 20 per verb stay, so frequent status runs never push out the transcript of an install or update. The earlier
        # ones are pruned to 19 before this run's starts, as Start-Transcript may create its file only once it first writes.
        Remove-OldLogs -Directory $logDir -Filter "$prefix-*-$Verb.log" -KeepCount 19
        $null = Start-Transcript -LiteralPath $transcript
        $hold.Transcribing = $true

        $moduleName = $MyInvocation.MyCommand.ModuleName
        $command = Get-Command -Name $spec.Function -CommandType Function -ErrorAction SilentlyContinue |
            Where-Object { $_.ModuleName -eq $moduleName }
        if (-not $command) { throw "The '$Verb' command is not available in this version." }

        # stop, status and uninstall must work while settings.psd1 is broken, so they get the error.
        $settings = $null
        $settingsError = $null
        try {
            $settings = Get-LocalAISettings -DefaultsPath $defaults -UserPath $paths.Settings
        } catch {
            if (-not $spec.SettingsOptional) { throw }
            $settingsError = $_.Exception.Message
        }

        # The verb function prints through the host and ends by returning 0, 1 or 2; anything it
        # writes to the pipeline before that is printed too.
        $context = @{
            Verb          = $Verb
            Paths         = $paths
            Settings      = $settings
            SettingsError = $settingsError
            RepoRoot      = Split-Path (Split-Path $defaults -Parent) -Parent
            Json          = [bool]$Json
            Tools         = [bool]$Tools
            Remove        = [bool]$Remove
            RemoveData    = [bool]$RemoveData
            NoBrowser     = [bool]$NoBrowser
            # Only a Probe verb sees another run; the others hold the lock.
            LockHeld      = $lockHeld
            # Only a verb whose Redirected is Warn runs while Redirection is set; status looks for private copies with LocalAppData and AppData.
            Redirection      = $redirection
            LocalAppData     = $LocalAppData
            AppData          = $AppData
            Rollback         = [bool]$Rollback
            ActivateLauncher = [string]$ActivateLauncher
            # The folder of a release install, which is not a setting; $null for a LocalAppData that holds a character no path can.
            InstallRoot      = Get-LauncherInstallRoot -LocalAppData $LocalAppData
            Hold             = $hold
            # The warnings of the launcher's own update, which count for update's exit code.
            Warnings         = @()
        }
        if ($Verb -eq 'update') {
            $launcherWarnings = @()
            $handed = if ($Rollback) { Invoke-LauncherRollback -Context $context } else { Invoke-LauncherSelfUpdate -Context $context -WarningVariable launcherWarnings }
            if ($null -ne $handed) { return [int]$handed }
            $context.Warnings = @($launcherWarnings | ForEach-Object { [string]$_ })
        }
        $output = @(& $command -Context $context)
        $code = $null
        if ($output.Count -gt 0) { $code = $output[-1] }
        if ($output.Count -gt 1) { $output[0..($output.Count - 2)] | Out-Host }
        if (-not ($code -is [int] -and @(0, 1, 2) -contains $code)) {
            throw "$($spec.Function) returned '$code' instead of exit code 0, 1 or 2."
        }
        # It never changes the exit code, and it never throws.
        $noticed = $false
        if ($Verb -eq 'start') { $noticed = Invoke-LauncherPassiveCheck -Context $context }
        # local-ai.cmd pauses after any other exit code, so only a start that ends with 0 waits below.
        if (-not ($noticed -and $code -eq 0)) { return $code }
    } catch {
        if ($Json) {
            Write-Host (ConvertTo-LocalAIJsonText -Value ([ordered]@{
                        verb = $Verb; exitCode = 1; health = 'error'; error = $_.Exception.Message; stackTrace = $_.ScriptStackTrace; log = $transcript
                    }))
        } else {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            if ($hold.Transcribing) {
                Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
                Write-Host "Log: $transcript"
            }
        }
        return 1
    } finally {
        if ($hold.Transcribing) {
            try { $null = Stop-Transcript } catch { Write-Warning "Could not stop the transcript: $($_.Exception.Message)" }
        }
        Exit-LocalAILock -Mutex $hold.Mutex
    }
    # Reached only when start printed that a newer launcher is out and ends with 0, which local-ai.cmd does not pause after: the window a Start menu shortcut
    # opened stays open to read that line. Only now, so that no other run waits for the lock while this one waits for a key.
    Wait-LocalAIConsoleKey
    return $code
}

Export-ModuleMember -Function @(
    'Get-LocalAIPaths'
    'Get-LocalAIVersion'
    'Get-LocalAISettings'
    'ConvertTo-LocalAIHashtable'
    'ConvertFrom-LocalAIJson'
    'Read-LocalAIState'
    'Write-LocalAIState'
    'Invoke-Native'
    'Update-SessionPath'
    'Invoke-LogRotation'
    'Remove-OldLogs'
    'Enter-LocalAILock'
    'Exit-LocalAILock'
    'Set-LocalAIKeepAwake'
    'Resolve-OllamaUrl'
    'Get-ListenerAddress'
    'Test-LoopbackListener'
    'Install-WingetPackage'
    'Wait-OllamaServer'
    'Get-OllamaModelBlob'
    'Confirm-FileHash'
    'Test-LocalHostName'
    'Test-FreeSpace'
    'Install-ChatModel'
    'Install-LocalAI'
    'Get-PortOwner'
    'Get-RecordedProcessState'
    'Test-RecordedProcess'
    'Test-ProcessDescendant'
    'Install-OpenWebUI'
    'Get-ComfyUIVersion'
    'Get-ImageGateVersion'
    'Test-ComfyUICheckpoint'
    'Test-ComfyUIDevice'
    'Get-ComfyUIStartProblem'
    'Install-ComfyUI'
    'Install-ImageModel'
    'Get-ImageWorkflow'
    'Get-FilesKey'
    'Install-Mcpo'
    'Install-FilesServerPackage'
    'Install-FilesServer'
    'Test-FilesRoot'
    'New-McpoConfig'
    'Get-FilesServerVersion'
    'Get-FilesStartProblem'
    'Get-OpenWebUIEnvironment'
    'Get-LocalAIService'
    'Start-LocalAIService'
    'Wait-LocalAIService'
    'Stop-LocalAIService'
    'Start-LocalAI'
    'Stop-LocalAI'
    'Get-LocalAIStatus'
    'Set-LocalAIShortcut'
    'Update-LocalAI'
    'Uninstall-LocalAI'
    'Install-LocalAILauncher'
    'Invoke-LocalAI'
)
