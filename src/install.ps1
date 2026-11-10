# -------------------------------------------------------
#                LOCAL AI LAUNCHER INSTALL
# -------------------------------------------------------
#
# Installs the launcher from a GitHub release into %LOCALAPPDATA%\Programs\local-ai-launcher: the
# latest release, or the release -Tag vX.Y.Z. It checks the release as local-ai update does, puts
# it into versions\<tag>, and has that version's own LocalAI.psm1 write the shim local-ai.cmd and
# the file current. -AddToPath adds the folder to the user's Path, and -Shortcuts creates the
# Start menu shortcuts. Every release attaches this file as its asset install.ps1. Run it as a
# file, or from the web as the README shows:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install.ps1 [-Tag vX.Y.Z] [-AddToPath] [-Shortcuts]
#   irm https://github.com/Ochsyp/local-ai-launcher/releases/download/vX.Y.Z/install.ps1 | iex
#   & ([scriptblock]::Create((irm <that address>))) -Tag vX.Y.Z -AddToPath
# So it never calls exit, which would close the window under iex, never reads its own path, and
# keeps its functions and variables inside the script block below. A failure throws, which ends a
# run as a file with exit code 1 and leaves a window under iex open.
#
# The lines from BEGIN LAUNCHER RELEASE FUNCTIONS to END LAUNCHER RELEASE FUNCTIONS are a copy of
# the block of that name in src\LocalAI.psm1, which tests\LocalAI.Tests.ps1 compares with it.
# Change the two together.

& {
    [CmdletBinding()]
    param(
        [string]$Tag = '',
        [switch]$AddToPath,
        [switch]$Shortcuts
    )

    $ErrorActionPreference = 'Stop'

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

    # Set up the install folder $Root for the version $Tag, which $Folder holds, through that version's own src\LocalAI.psm1: its Install-LocalAILauncher writes
    # the shim and current. It runs in Windows PowerShell with the execution policy RemoteSigned for that run only, as local-ai.cmd does, on this console, so
    # that neither this window's execution policy nor its session matters or changes. Waits for it and returns its exit code.
    function Invoke-LauncherSetup {
        [CmdletBinding()]
        [OutputType([int])]
        param(
            [Parameter(Mandatory)][string]$Folder,
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Tag
        )
        $quote = { param([string]$Text) "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'" }
        $module = [IO.Path]::Combine($Folder, 'src', 'LocalAI.psm1')
        $command = ("`$ErrorActionPreference = 'Stop'; Import-Module $(& $quote $module) -Force; " +
            "`$null = Install-LocalAILauncher -Root $(& $quote $Root) -Tag $(& $quote $Tag)")
        $powershell = [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\powershell.exe')
        # No Windows path holds a double quote, so one pair of them carries the command whole.
        $line = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -Command `"$command`""
        $process = Start-Process -FilePath $powershell -ArgumentList $line -NoNewWindow -PassThru -ErrorAction Stop
        # 5.1 reports no ExitCode unless the handle was opened while the process ran.
        $null = $process.Handle
        $process.WaitForExit()
        return [int]$process.ExitCode
    }

    # Install the launcher release $Tag of the GitHub repository $Repo, or its latest release, into $LocalAppData\Programs\local-ai-launcher, as the top of this
    # file describes, and print the next step. Refuses inside an app package's container, which a probe of $LocalAppData or $ShellLocalAppData, the known
    # folder, shows, and while another version that is whole runs there, as moving between versions is update's job. Throws on any failure, saying what changed.
    function Install-LauncherFromRelease {
        [CmdletBinding()]
        param(
            [AllowEmptyString()][string]$Tag = '',
            [switch]$AddToPath,
            [switch]$Shortcuts,
            [string]$Repo = 'Ochsyp/local-ai-launcher',
            [AllowEmptyString()][AllowNull()][string]$LocalAppData = $env:LOCALAPPDATA,
            [AllowEmptyString()][AllowNull()][string]$ShellLocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
        )
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'install.ps1 installs the launcher on Windows only. Nothing was changed.' }
        $running = $PSVersionTable.PSVersion
        if ($running.Major -lt 5 -or ($running.Major -eq 5 -and $running.Minor -lt 1)) {
            throw "install.ps1 needs Windows PowerShell 5.1 or later, but this is PowerShell $running. Nothing was changed."
        }

        # As local-ai does for its verbs: the container redirects the known folder also while %LOCALAPPDATA% names another one.
        $redirection = Get-AppDataRedirection -LocalAppData $LocalAppData
        $sameFolder = [string]::Equals(([string]$ShellLocalAppData).TrimEnd('\'), ([string]$LocalAppData).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        if (-not $redirection -and $ShellLocalAppData -and -not $sameFolder) { $redirection = Get-AppDataRedirection -LocalAppData $ShellLocalAppData }
        if ($redirection) {
            throw ("$(Format-AppDataRedirection -Redirection $redirection), so the launcher would land where other windows never see it. Nothing was changed. " +
                'Run install.ps1 from a console window or Windows Terminal that you open from the Start menu.')
        }
        $root = Get-LauncherInstallRoot -LocalAppData $LocalAppData
        if (-not $root) { throw '%LOCALAPPDATA% names no folder, so install.ps1 does not know where to install the launcher. Nothing was changed.' }
        $root = [IO.Path]::GetFullPath($root).TrimEnd('\')
        Write-Host "Installing the Local AI launcher into $root."

        # Until a version is in versions, a failure leaves the install folder as it was, and removes the empty folders it made in a new one.
        $existed = [IO.Directory]::Exists($root)
        try {
            $which = if ($Tag) { "the release $Tag" } else { 'the latest release' }
            Write-Host "Asking GitHub for $which of $Repo."
            $release = Get-LauncherRelease -Repo $Repo -Tag $Tag -TimeoutSeconds 15
            $release.Commit = Get-LauncherTagCommit -Repo $Repo -Tag $release.Tag -TimeoutSeconds 15
            $active = Get-LauncherCurrent -InstallRoot $root
            if ($active -and $active -cne $release.Tag) {
                $whole = @(Test-LauncherFolder -Path ([IO.Path]::Combine($root, 'versions', $active)) -Tag $active).Count -eq 0
                if ($whole -and (ConvertTo-LauncherVersion -Tag $active) -gt (ConvertTo-LauncherVersion -Tag $release.Tag)) {
                    throw ("The launcher in $root runs $active, which is newer than $($release.Tag), and install.ps1 never goes back; " +
                        "'local-ai update -Rollback' returns to the version before.")
                }
                if ($whole) {
                    throw "The launcher in $root runs $active already; 'local-ai update' moves it to $($release.Tag) and brings the parts to that version's pins."
                }
                Write-Host "The version $active that current names is missing or damaged, so $($release.Tag) takes its place." -ForegroundColor Yellow
            }
            if ([IO.Directory]::Exists([IO.Path]::Combine($root, 'versions', $release.Tag))) {
                Write-Host "$($release.Tag) is in $root\versions already; checking its files again."
            } else {
                Write-Host "Downloading $($release.Asset) of $($release.Tag), $($release.Size) bytes, and checking it against $($release.Digest)."
            }
            $saved = Save-LauncherRelease -Release $release -InstallRoot $root
        } catch {
            $why = $_.Exception.Message
            if ($_.Exception.Data['LauncherProblem'] -eq 'Unreachable') { $why = "Could not get the launcher from GitHub ($why)." }
            if (-not $existed) {
                foreach ($path in @([IO.Path]::Combine($root, 'staging'), [IO.Path]::Combine($root, 'versions'), $root)) {
                    try {
                        if ([IO.Directory]::Exists($path) -and @([IO.Directory]::GetFileSystemEntries($path)).Count -eq 0) { [IO.Directory]::Delete($path) }
                    } catch {
                        Write-Verbose "Could not remove the empty folder $path`: $($_.Exception.Message)"
                    }
                }
            }
            throw "$why Nothing was changed."
        }
        $tag = $release.Tag
        if ($saved.Downloaded) {
            Write-Host "The zip matches its digest, and every file of $tag matches the release's manifest."
        } else {
            Write-Host "Every file of $tag still matches the release's manifest."
        }

        Write-Host "Setting up $root with $tag`: the shim local-ai.cmd and the file current."
        $code = Invoke-LauncherSetup -Folder $saved.Path -Root $root -Tag $tag
        $shim = [IO.Path]::Combine($root, 'local-ai.cmd')
        if ($code -ne 0 -or (Get-LauncherCurrent -InstallRoot $root) -cne $tag -or -not [IO.File]::Exists($shim)) {
            throw ("Windows PowerShell could not set up $root with the LocalAI.psm1 of $tag (exit code $code). $tag stays in $($saved.Path); fix what it " +
                'named above, then run install.ps1 again.')
        }

        if ($AddToPath) {
            try {
                $added = Add-LauncherUserPath -Entry $root
            } catch {
                throw "The launcher $tag is installed in $root, but your Path is unchanged: $($_.Exception.Message)"
            }
            if ($added) {
                try {
                    Send-LauncherSettingChange
                } catch {
                    Write-Warning "Windows could not tell running programs that your Path changed, so it may take a new sign-in: $($_.Exception.Message)"
                }
                Write-Host "Added $root to your Path, which console windows opened from now on read."
            } else {
                Write-Host "Your Path names $root already."
            }
        }

        if ($Shortcuts) {
            Write-Host 'Creating the Start menu shortcuts with local-ai shortcuts.'
            & $shim shortcuts
            $result = $LASTEXITCODE
            if ($result -eq 2) {
                Write-Warning "'local-ai shortcuts' finished with warnings, which it printed above."
            } elseif ($result -ne 0) {
                throw "The launcher $tag is installed in $root, but 'local-ai shortcuts' failed with exit code $result; run it again once the problem it named is fixed."
            }
        }

        Write-Host ''
        Write-Host "The launcher $tag is installed in $root." -ForegroundColor Green
        if ($AddToPath) {
            Write-Host 'Next, open a new console window and run: local-ai install'
        } else {
            Write-Host "Next, run: & `"$shim`" install"
            Write-Host 'With -AddToPath, install.ps1 also puts local-ai on your Path.'
        }
    }

    Install-LauncherFromRelease -Tag $Tag -AddToPath:$AddToPath -Shortcuts:$Shortcuts
} @args
