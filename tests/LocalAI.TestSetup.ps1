# -------------------------------------------------------
#                 LOCAL AI MODULE TEST SETUP
# -------------------------------------------------------
#
# Dot-sourced by the BeforeAll of every tests\LocalAI.*.Tests.ps1 file: imports src\LocalAI.psm1
# and defines the helpers and stand-ins those tests share. Files go to TestDrive: and mutexes get
# unique names, so nothing touches %LOCALAPPDATA%\local-ai, the launcher's install folder, Open
# WebUI, Ollama or ComfyUI. The launcher's own releases come from zips built in TestDrive: and
# mocked web calls. Pester runs only *.Tests.ps1 files, so not this one.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
param()

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

# Return the lowercase hex SHA-256 of the file $Path.
function Get-TestFileSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# Write a release folder of the launcher for $Tag at $Path: local-ai.cmd, src\local-ai.ps1, VERSION and the files $Files (path with '/' -> text), and the
# manifest local-ai-release.json listing them with the commit $Commit, as the release workflow writes it; $Manifest replaces its fields, $null leaving one
# out. Returns $Path.
function Write-TestReleaseFolder([string]$Path, [string]$Tag, [hashtable]$Files = @{}, [string]$Commit = ('c' * 40), [hashtable]$Manifest = @{}) {
    $version = $Tag.Substring(1)
    $all = @{ 'local-ai.cmd' = "@echo off`r`nexit /b 0`r`n"; 'src/local-ai.ps1' = "param()`r`n"; 'VERSION' = "$version`n" }
    foreach ($key in $Files.Keys) { $all[$key] = $Files[$key] }
    $hashes = [ordered]@{}
    foreach ($key in @($all.Keys | Sort-Object)) {
        $full = Join-Path $Path ($key.Replace('/', '\'))
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent)
        [IO.File]::WriteAllText($full, $all[$key])
        $hashes[$key] = Get-TestFileSha256 $full
    }
    $fields = [ordered]@{ schema = 1; name = 'local-ai-launcher'; version = $version; tag = $Tag; commit = $Commit; files = $hashes }
    foreach ($key in $Manifest.Keys) {
        if ($null -eq $Manifest[$key]) { $fields.Remove($key) } else { $fields[$key] = $Manifest[$key] }
    }
    [IO.File]::WriteAllText((Join-Path $Path 'local-ai-release.json'), (ConvertTo-Json -InputObject $fields -Depth 5))
    return $Path
}

# Write the zip $ZipPath as git archive writes a release: every folder and file of $Folder below the prefix $Prefix, folders as entries that end in
# '/', then the entries $Extra (name -> text, also names that differ only in case) as given. Returns its digest, 'sha256:' and the lowercase hex SHA-256.
function Write-TestReleaseZip([string]$ZipPath, [string]$Folder, [string]$Prefix, [System.Collections.IDictionary]$Extra = @{}) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $ZipPath -Parent)
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = New-Object System.Collections.Generic.List[object]
        if ($Folder) {
            $base = (Get-Item -LiteralPath $Folder).FullName.TrimEnd('\')
            foreach ($item in @(Get-ChildItem -LiteralPath $base -Recurse -Force | Sort-Object FullName)) {
                $relative = $item.FullName.Substring($base.Length + 1).Replace('\', '/')
                if ($item.PSIsContainer) { $entries.Add(@("$Prefix$relative/", $null)) } else { $entries.Add(@("$Prefix$relative", [IO.File]::ReadAllBytes($item.FullName))) }
            }
        }
        foreach ($name in $Extra.Keys) { $entries.Add(@([string]$name, [Text.Encoding]::ASCII.GetBytes([string]$Extra[$name]))) }
        foreach ($pair in $entries) {
            $entry = $zip.CreateEntry([string]$pair[0])
            if ($null -eq $pair[1] -or $pair[1].Length -eq 0) { continue }
            $stream = $entry.Open()
            try { $stream.Write($pair[1], 0, $pair[1].Length) } finally { $stream.Dispose() }
        }
    } finally {
        $zip.Dispose()
    }
    return 'sha256:' + (Get-TestFileSha256 $ZipPath)
}

# Return a release as Invoke-RestMethod gives it from GitHub's API for $Tag, with one asset, the zip whose digest is $Digest; $Fields and $Asset change
# the release and the asset.
function Get-TestReleaseObject([string]$Tag = 'v1.1.0', [string]$Digest = ('sha256:' + ('a' * 64)), [hashtable]$Fields = @{}, [hashtable]$Asset = @{}) {
    $version = $Tag.Substring(1)
    $file = [ordered]@{ name = "local-ai-launcher-$version.zip"; state = 'uploaded'; size = 4096; digest = $Digest
        browser_download_url = "https://github.com/example-owner/launcher/releases/download/$Tag/local-ai-launcher-$version.zip" }
    foreach ($key in $Asset.Keys) { $file[$key] = $Asset[$key] }
    $release = [ordered]@{ tag_name = $Tag; draft = $false; prerelease = $false; immutable = $true; assets = @([pscustomobject]$file) }
    foreach ($key in $Fields.Keys) { $release[$key] = $Fields[$key] }
    return [pscustomobject]$release
}

# Return GitHub's answer for the tag ref of $Tag, naming the object $Sha of the type $Type.
function Get-TestTagRef([string]$Tag, [string]$Sha = ('c' * 40), [string]$Type = 'commit') {
    return [pscustomobject]@{ ref = "refs/tags/$Tag"; object = [pscustomobject]@{ sha = $Sha; type = $Type } }
}

# Return the error record Invoke-RestMethod throws for the HTTP status $Status, with $Description and the headers $Headers, or without $Status for the
# network error $WebStatus with $Message. The response is an HttpWebResponse whose fields are set through reflection, as nothing public builds one.
function Get-TestWebError([int]$Status = 0, [string]$Description = '', [hashtable]$Headers = @{}, [string]$WebStatus = 'ConnectFailure',
    [string]$Message = 'Unable to connect to the remote server') {
    if ($Status) {
        $flags = [Reflection.BindingFlags]'NonPublic, Instance'
        $type = [Net.HttpWebResponse]
        $response = New-Object Net.HttpWebResponse
        $type.GetField('m_StatusCode', $flags).SetValue($response, [Enum]::ToObject([Net.HttpStatusCode], $Status))
        $type.GetField('m_StatusDescription', $flags).SetValue($response, $Description)
        $collection = New-Object Net.WebHeaderCollection
        foreach ($name in $Headers.Keys) { $collection.Add($name, [string]$Headers[$name]) }
        $type.GetField('m_HttpResponseHeaders', $flags).SetValue($response, $collection)
        $exception = New-Object Net.WebException -ArgumentList "The remote server returned an error: ($Status) $Description.", $null, ([Net.WebExceptionStatus]::ProtocolError), $response
    } else {
        $exception = New-Object Net.WebException -ArgumentList $Message, ([Net.WebExceptionStatus]$WebStatus)
    }
    return New-Object Management.Automation.ErrorRecord -ArgumentList $exception, 'WebCmdletWebResponseException', ([Management.Automation.ErrorCategory]::InvalidOperation), $null
}

# Return a stand-in for HKCU\Environment, the registry key Get-LauncherEnvironmentKey opens, holding Path $Value (none for $null) of the kind $Kind. It
# keeps Values, Kinds, the Options GetValue was last given, the Writes made and how often it was disposed.
function Get-TestEnvironmentKey([AllowNull()][object]$Value, [Microsoft.Win32.RegistryValueKind]$Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString) {
    $key = [pscustomobject]@{ Values = @{}; Kinds = @{}; Options = $null; Writes = (New-Object System.Collections.Generic.List[string]); Disposed = 0 }
    if ($null -ne $Value) {
        $key.Values['Path'] = $Value
        $key.Kinds['Path'] = $Kind
    }
    $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @($this.Values.Keys) }
    $key | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value { param([string]$Name) $this.Kinds[$Name] }
    $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
        param([string]$Name, $Default, $Options)
        $this.Options = $Options
        if ($this.Values.ContainsKey($Name)) { $this.Values[$Name] } else { $Default }
    }
    $key | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
        param([string]$Name, $Value, $Kind)
        $this.Values[$Name] = $Value
        $this.Kinds[$Name] = $Kind
        $this.Writes.Add("set $Name")
    }
    # DeleteValue's second argument, whether a missing value throws, lands in $args and is ignored.
    $key | Add-Member -MemberType ScriptMethod -Name DeleteValue -Value {
        param([string]$Name)
        $this.Values.Remove($Name)
        $this.Kinds.Remove($Name)
        $this.Writes.Add("delete $Name")
    }
    $key | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed++ }
    return $key
}

# Lay out a release install below a new folder in TestDrive: versions\<tag> for each tag in $Tags (Write-TestReleaseFolder), current naming $Current, and
# with $Shim the shim local-ai.cmd. Returns @{ LocalAppData; Root; Versions }.
function Write-TestLauncherInstall([string[]]$Tags = @('v1.0.0'), [string]$Current = 'v1.0.0', [switch]$Shim) {
    $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $root = Join-Path $local 'Programs\local-ai-launcher'
    foreach ($tag in $Tags) { $null = Write-TestReleaseFolder -Path (Join-Path $root "versions\$tag") -Tag $tag }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'versions')
    if ($Current) { [IO.File]::WriteAllText((Join-Path $root 'current'), "$Current`r`n") }
    if ($Shim) { [IO.File]::WriteAllText((Join-Path $root 'local-ai.cmd'), (InModuleScope LocalAI { Get-LauncherShimText }), [Text.Encoding]::ASCII) }
    return @{ LocalAppData = $local; Root = $root; Versions = (Join-Path $root 'versions') }
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
