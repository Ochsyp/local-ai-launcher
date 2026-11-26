# -------------------------------------------------------
#                 LOCAL AI MODULE TESTS: LAUNCHER
# -------------------------------------------------------
#
# Pester 6 tests for the launcher's own releases in src\LocalAI.psm1: their check, download and
# install, self-update and rollback, the shim, local-ai.ps1, and src\install.ps1, which holds a copy
# of the module's release functions and also runs as irm | iex. tests\LocalAI.TestSetup.ps1 imports
# the module and holds the shared helpers.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll and BeforeEach variables with the It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
    Justification = 'The install.ps1 tests run it through Invoke-Expression, as irm | iex does.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LocalAI.TestSetup.ps1')
}

Describe 'Launcher settings' {
    BeforeAll {
        $defaultsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\defaults.psd1'

        # Return the Launcher settings that the defaults with a settings.psd1 holding $Text give.
        function Get-TestLauncherSetting([string]$Text) {
            $user = Write-TestFile ('launcher-settings\' + [guid]::NewGuid().ToString('N') + '.psd1') $Text
            return (Get-LocalAISettings -DefaultsPath $defaultsPath -UserPath $user).Launcher
        }
    }

    It 'accepts <Case>' -ForEach @(
        @{ Case = 'another repository'; Text = "@{ Launcher = @{ Repo = 'other-owner/fork.of_launcher-2' } }"; Key = 'Repo'; Value = 'other-owner/fork.of_launcher-2' }
        @{ Case = 'an owner of 39 characters'; Text = "@{ Launcher = @{ Repo = '$('a' * 39)/x' } }"; Key = 'Repo'; Value = "$('a' * 39)/x" }
        @{ Case = 'a check every hour'; Text = '@{ Launcher = @{ CheckIntervalHours = 1 } }'; Key = 'CheckIntervalHours'; Value = 1 }
        @{ Case = 'a check once a week'; Text = '@{ Launcher = @{ CheckIntervalHours = 168 } }'; Key = 'CheckIntervalHours'; Value = 168 }
        @{ Case = 'two kept versions'; Text = '@{ Launcher = @{ KeepVersions = 2 } }'; Key = 'KeepVersions'; Value = 2 }
        @{ Case = 'five kept versions'; Text = '@{ Launcher = @{ KeepVersions = 5 } }'; Key = 'KeepVersions'; Value = 5 }
        @{ Case = 'no look from start'; Text = '@{ Launcher = @{ CheckForUpdates = $false } }'; Key = 'CheckForUpdates'; Value = $false }
        @{ Case = 'releases that are not immutable'; Text = '@{ Launcher = @{ RequireImmutable = $false } }'; Key = 'RequireImmutable'; Value = $false }
    ) {
        (Get-TestLauncherSetting $Text)[$Key] | Should -Be $Value
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a repository without its owner'; Text = "@{ Launcher = @{ Repo = 'local-ai-launcher' } }"
            Message = "*'Launcher.Repo' = 'local-ai-launcher' must be <owner>/<repository> on GitHub, such as 'Ochsyp/local-ai-launcher'*" }
        @{ Case = 'a repository with a third part'; Text = "@{ Launcher = @{ Repo = 'owner/repo/extra' } }"; Message = "*'Launcher.Repo' = 'owner/repo/extra' must be <owner>/<repository>*" }
        @{ Case = 'a repository URL'; Text = "@{ Launcher = @{ Repo = 'https://github.com/owner/repo' } }"; Message = "*'Launcher.Repo'*must be <owner>/<repository>*" }
        @{ Case = 'an owner that starts with a dash'; Text = "@{ Launcher = @{ Repo = '-owner/repo' } }"; Message = "*'Launcher.Repo'*must be <owner>/<repository>*" }
        @{ Case = 'an owner of 40 characters'; Text = "@{ Launcher = @{ Repo = '$('a' * 40)/repo' } }"; Message = "*'Launcher.Repo'*must be <owner>/<repository>*" }
        @{ Case = "the repository '..'"; Text = "@{ Launcher = @{ Repo = 'owner/..' } }"; Message = "*'Launcher.Repo' = 'owner/..' must be*" }
        @{ Case = "the repository '.'"; Text = "@{ Launcher = @{ Repo = 'owner/.' } }"; Message = "*'Launcher.Repo' = 'owner/.' must be*" }
        @{ Case = "the repository '...'"; Text = "@{ Launcher = @{ Repo = 'owner/...' } }"; Message = "*'Launcher.Repo' = 'owner/...' must be*" }
        @{ Case = 'a repository name that ends in a dot, which .NET drops from the address'; Text = "@{ Launcher = @{ Repo = 'owner/repo.' } }"
            Message = "*'Launcher.Repo' = 'owner/repo.' must be*" }
        @{ Case = 'a repository with a space'; Text = "@{ Launcher = @{ Repo = 'owner/my repo' } }"; Message = "*'Launcher.Repo'*must be <owner>/<repository>*" }
        @{ Case = 'no repository'; Text = "@{ Launcher = @{ Repo = '' } }"; Message = "*'Launcher.Repo' = '' must be*" }
        @{ Case = 'no hours between checks'; Text = '@{ Launcher = @{ CheckIntervalHours = 0 } }'; Message = "*'Launcher.CheckIntervalHours' = '0' must be a whole number from 1 to 168*" }
        @{ Case = 'more than a week between checks'; Text = '@{ Launcher = @{ CheckIntervalHours = 169 } }'; Message = "*'Launcher.CheckIntervalHours' = '169' must be a whole number from 1 to 168*" }
        @{ Case = 'hours written as text'; Text = "@{ Launcher = @{ CheckIntervalHours = '24' } }"; Message = "*'Launcher.CheckIntervalHours' = '24' must be a whole number.*" }
        @{ Case = 'one kept version'; Text = '@{ Launcher = @{ KeepVersions = 1 } }'; Message = "*'Launcher.KeepVersions' = '1' must be a whole number from 2 to 5*" }
        @{ Case = 'six kept versions'; Text = '@{ Launcher = @{ KeepVersions = 6 } }'; Message = "*'Launcher.KeepVersions' = '6' must be a whole number from 2 to 5*" }
        @{ Case = 'CheckForUpdates written as text'; Text = "@{ Launcher = @{ CheckForUpdates = 'yes' } }"; Message = "*'Launcher.CheckForUpdates' = 'yes' must be `$true or `$false*" }
        @{ Case = 'RequireImmutable as a number'; Text = '@{ Launcher = @{ RequireImmutable = 1 } }'; Message = "*'Launcher.RequireImmutable' = '1' must be `$true or `$false*" }
        @{ Case = 'the install folder, which is not a setting'; Text = "@{ Launcher = @{ InstallRoot = 'D:\Launcher' } }"; Message = "*Unknown setting 'Launcher.InstallRoot'*" }
    ) {
        { Get-TestLauncherSetting $Text } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'ConvertTo-LauncherVersion' {
    It 'reads <Tag> as <Expected>' -ForEach @(
        @{ Tag = 'v1.10.0'; Expected = '1.10.0' }
        @{ Tag = 'v0.0.0'; Expected = '0.0.0' }
        @{ Tag = 'v2147483647.0.1'; Expected = '2147483647.0.1' }
    ) {
        [string](Invoke-ModuleFunction 'ConvertTo-LauncherVersion' @{ Tag = $Tag }) | Should -BeExactly $Expected
    }

    It 'orders v1.10.0 above v1.9.9, as versions and not as text' {
        $newer = Invoke-ModuleFunction 'ConvertTo-LauncherVersion' @{ Tag = 'v1.10.0' }
        $older = Invoke-ModuleFunction 'ConvertTo-LauncherVersion' @{ Tag = 'v1.9.9' }
        ($newer -gt $older) | Should -BeTrue
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'two numbers'; Tag = 'v1.2' }
        @{ Case = 'a prerelease suffix'; Tag = 'v1.2.3-rc.1' }
        @{ Case = 'build metadata'; Tag = 'v1.2.3+build.5' }
        @{ Case = 'a capital V'; Tag = 'V1.2.3' }
        @{ Case = 'no v'; Tag = '1.2.3' }
        @{ Case = 'a leading zero'; Tag = 'v01.2.3' }
        @{ Case = 'four numbers'; Tag = 'v1.2.3.4' }
        @{ Case = 'a space after it'; Tag = 'v1.2.3 ' }
        @{ Case = 'a line feed after it'; Tag = "v1.2.3`n" }
        @{ Case = 'a number above 2147483647'; Tag = 'v2147483648.0.0' }
        @{ Case = 'digits of another script'; Tag = 'v1.2.' + [char]0x0663 }
        @{ Case = 'nothing'; Tag = '' }
    ) {
        ($null -eq (Invoke-ModuleFunction 'ConvertTo-LauncherVersion' @{ Tag = $Tag })) | Should -BeTrue
    }
}

Describe 'Test-LauncherRelease' {
    BeforeAll {
        # Return the exception Test-LauncherRelease throws for $Release with $RequireImmutable.
        function Get-TestReleaseProblem([object]$Release, [bool]$RequireImmutable = $true) {
            try {
                $null = Invoke-ModuleFunction 'Test-LauncherRelease' @{ Release = $Release; RequireImmutable = $RequireImmutable }
            } catch {
                return $_.Exception
            }
            throw 'Test-LauncherRelease took the release.'
        }
    }

    It 'returns the tag, version, asset, address, digest and size of a release the launcher may install' {
        $digest = 'sha256:' + ('0123456789abcdef' * 4)
        $checked = Invoke-ModuleFunction 'Test-LauncherRelease' @{ Release = (Get-TestReleaseObject -Tag 'v1.2.0' -Digest $digest) }
        $checked.Tag | Should -BeExactly 'v1.2.0'
        $checked.Version | Should -BeExactly '1.2.0'
        $checked.Asset | Should -BeExactly 'local-ai-launcher-1.2.0.zip'
        $checked.Url | Should -BeExactly 'https://github.com/example-owner/launcher/releases/download/v1.2.0/local-ai-launcher-1.2.0.zip'
        $checked.Digest | Should -BeExactly $digest
        $checked.Size | Should -Be 4096
    }

    It 'takes a release that is not immutable once Launcher.RequireImmutable is off' {
        $release = Get-TestReleaseObject -Fields @{ immutable = $false }
        (Invoke-ModuleFunction 'Test-LauncherRelease' @{ Release = $release; RequireImmutable = $false }).Tag | Should -BeExactly 'v1.1.0'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a draft'; Fields = @{ draft = $true }; Message = 'The release v1.1.0 is a draft, which the launcher never installs.' }
        @{ Case = 'a prerelease'; Fields = @{ prerelease = $true }; Message = 'The release v1.1.0 is a prerelease, which the launcher never installs.' }
        @{ Case = 'a release that is not immutable'; Fields = @{ immutable = $false }; Message = 'The release v1.1.0 is not immutable, so its tag and files could still change*Launcher.RequireImmutable*' }
        @{ Case = 'a release that does not say whether it is immutable'; Fields = @{ immutable = $null }; Message = 'The release v1.1.0 is not immutable*' }
        @{ Case = 'an immutable that is the text true'; Fields = @{ immutable = 'true' }; Message = 'The release v1.1.0 is not immutable*' }
        @{ Case = 'an immutable that is the number 1'; Fields = @{ immutable = 1 }; Message = 'The release v1.1.0 is not immutable*' }
        @{ Case = 'an immutable that is a list holding false'; Fields = @{ immutable = @($false) }; Message = 'The release v1.1.0 is not immutable*' }
        @{ Case = 'an immutable that is an empty list'; Fields = @{ immutable = @() }; Message = 'The release v1.1.0 is not immutable*' }
        @{ Case = 'a tag with a suffix'; Fields = @{ tag_name = 'v1.1.0-rc.1' }; Message = "The release is tagged 'v1.1.0-rc.1', but the launcher installs only a tag vX.Y.Z without a suffix." }
        @{ Case = 'a tag without the v'; Fields = @{ tag_name = '1.1.0' }; Message = "The release is tagged '1.1.0'*" }
        @{ Case = 'no tag'; Fields = @{ tag_name = $null }; Message = 'GitHub answered with no release.' }
        @{ Case = 'no asset'; Fields = @{ assets = @() }; Message = 'The release v1.1.0 holds no asset local-ai-launcher-1.1.0.zip.' }
        @{ Case = 'an asset named with the v of the tag'; Asset = @{ name = 'local-ai-launcher-v1.1.0.zip' }; Message = 'The release v1.1.0 holds no asset local-ai-launcher-1.1.0.zip.' }
        @{ Case = 'an asset not uploaded yet'; Asset = @{ state = 'starter' }; Message = "The asset local-ai-launcher-1.1.0.zip of v1.1.0 is 'starter', not uploaded." }
        @{ Case = 'an asset without a digest'; Asset = @{ digest = $null }; Message = "The asset local-ai-launcher-1.1.0.zip of v1.1.0 has the digest '', not sha256: and 64 lowercase hex digits." }
        @{ Case = 'a digest of another kind'; Asset = @{ digest = 'sha1:' + ('a' * 40) }; Message = "*has the digest 'sha1:*" }
        @{ Case = 'a digest in capitals'; Asset = @{ digest = 'sha256:' + ('A' * 64) }; Message = '*not sha256: and 64 lowercase hex digits.' }
        @{ Case = 'an empty asset'; Asset = @{ size = 0 }; Message = 'The asset local-ai-launcher-1.1.0.zip of v1.1.0 has 0 bytes, not 1 byte to 64 MB.' }
        @{ Case = 'an asset above 64 MB'; Asset = @{ size = 67108865 }; Message = '*has 67108865 bytes, not 1 byte to 64 MB.' }
        @{ Case = 'an asset served over HTTP'; Asset = @{ browser_download_url = 'http://example.invalid/x.zip' }; Message = "*is not served over HTTPS but from 'http://example.invalid/x.zip'." }
    ) {
        $fields = if ($Fields) { $Fields } else { @{} }
        $asset = if ($Asset) { $Asset } else { @{} }
        $problem = Get-TestReleaseProblem -Release (Get-TestReleaseObject -Fields $fields -Asset $asset)
        $problem.Message | Should -BeLike $Message
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
    }

    It 'refuses a release with two assets of the name of the zip' {
        $release = Get-TestReleaseObject
        $release.assets = @($release.assets[0], $release.assets[0])
        (Get-TestReleaseProblem -Release $release).Message | Should -BeExactly 'The release v1.1.0 holds 2 assets named local-ai-launcher-1.1.0.zip.'
    }
}

Describe 'Get-LauncherRelease and Get-LauncherTagCommit' {
    BeforeAll {
        # Return the exception $Script throws.
        function Get-TestThrown([scriptblock]$Script) {
            try { $null = & $Script } catch { return $_.Exception }
            throw 'Nothing was thrown.'
        }
    }

    BeforeEach {
        $seen = New-Object System.Collections.Generic.List[hashtable]
        $world = @{ Release = (Get-TestReleaseObject); Error = $null }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            $seen.Add(@{ Uri = $Uri; Accept = $Headers['Accept']; Version = $Headers['X-GitHub-Api-Version']; UserAgent = $UserAgent; TimeoutSec = $TimeoutSec
                    Basic = [bool]$UseBasicParsing; Protocol = [Net.ServicePointManager]::SecurityProtocol })
            if ($world.Error) { throw $world.Error }
            switch -Wildcard ($Uri) {
                '*/releases/*' { $world.Release }
                '*/git/ref/tags/*' { Get-TestTagRef -Tag 'v1.1.0' -Sha ('d' * 40) -Type 'tag' }
                '*/git/tags/*' { [pscustomobject]@{ object = [pscustomobject]@{ sha = 'e' * 40; type = 'commit' } } }
                default { throw "Unexpected request to $Uri" }
            }
        }
    }

    It 'asks only api.github.com for the latest release, with the API version, a User-Agent and the timeout' {
        $release = Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher'; TimeoutSeconds = 5; UserAgent = 'local-ai-launcher/1.0.0' }
        $release.Tag | Should -BeExactly 'v1.1.0'
        $seen.Count | Should -Be 1
        $seen[0].Uri | Should -BeExactly 'https://api.github.com/repos/example-owner/launcher/releases/latest'
        $seen[0].Accept | Should -BeExactly 'application/vnd.github+json'
        $seen[0].Version | Should -BeExactly '2022-11-28'
        $seen[0].UserAgent | Should -BeExactly 'local-ai-launcher/1.0.0'
        $seen[0].TimeoutSec | Should -Be 5
        $seen[0].Basic | Should -BeTrue
    }

    It 'asks for the release of a tag it is given, and refuses one that is no tag vX.Y.Z before it asks' {
        $world.Release = Get-TestReleaseObject -Tag 'v1.0.3'
        (Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher'; Tag = 'v1.0.3' }).Tag | Should -BeExactly 'v1.0.3'
        $seen[0].Uri | Should -BeExactly 'https://api.github.com/repos/example-owner/launcher/releases/tags/v1.0.3'
        { Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher'; Tag = 'v1.0' } } | Should -Throw -ExpectedMessage "'v1.0' is no launcher version vX.Y.Z."
        { Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher/x' } } | Should -Throw -ExpectedMessage "*is no GitHub repository <owner>/<name>."
        $seen.Count | Should -Be 1
    }

    It "refuses the repository '<Repo>' before it asks, as .NET drops the dots at the end of the name from the address" -ForEach @(
        @{ Repo = 'example-owner/launcher.' }
        @{ Repo = 'example-owner/...' }
        @{ Repo = 'example-owner/..' }
        @{ Repo = 'example-owner/.' }
    ) {
        { Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = $Repo } } | Should -Throw -ExpectedMessage "'$Repo' is no GitHub repository <owner>/<name>."
        $seen.Count | Should -Be 0
    }

    It 'takes a repository name that starts with a dot or holds one, as GitHub allows' {
        $null = Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/.github' }
        $null = Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher.v2' }
        @($seen | ForEach-Object { $_.Uri }) | Should -Be @('https://api.github.com/repos/example-owner/.github/releases/latest',
            'https://api.github.com/repos/example-owner/launcher.v2/releases/latest')
    }

    It 'refuses the release of another tag than the one it asked for' {
        $world.Release = Get-TestReleaseObject -Tag 'v1.0.4'
        $thrown = Get-TestThrown { Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher'; Tag = 'v1.0.3' } }
        $thrown.Message | Should -BeExactly 'GitHub answered with the release v1.0.4 for the tag v1.0.3.'
        $thrown.Data['LauncherProblem'] | Should -Be 'Refused'
    }

    It 'gives the reason and keeps the launcher as it is when <Case>' -ForEach @(
        @{ Case = 'there is no network'; WebStatus = 'ConnectFailure'; Message = 'Unable to connect to the remote server'; Reason = 'Unable to connect to the remote server' }
        @{ Case = 'the name does not resolve'; WebStatus = 'NameResolutionFailure'; Message = "The remote name could not be resolved: 'api.github.com'"
            Reason = "The remote name could not be resolved: 'api.github.com'" }
        @{ Case = 'the request times out'; WebStatus = 'Timeout'; Message = 'The operation has timed out.'; Reason = 'The operation has timed out' }
        @{ Case = 'GitHub has a fault'; Status = 503; Description = 'Service Unavailable'; Reason = 'GitHub answered HTTP 503 Service Unavailable' }
        @{ Case = 'GitHub refuses without saying why'; Status = 403; Description = 'Forbidden'; Reason = 'GitHub answered HTTP 403 Forbidden' }
        @{ Case = 'GitHub asks to wait'; Status = 429; Description = 'Too Many Requests'; Headers = @{ 'Retry-After' = '60' }
            Reason = 'GitHub answered HTTP 429 Too Many Requests and asks to wait 60 s' }
    ) {
        $headers = if ($Headers) { $Headers } else { @{} }
        $world.Error = if ($Status) { Get-TestWebError -Status $Status -Description $Description -Headers $headers } else { Get-TestWebError -WebStatus $WebStatus -Message $Message }
        $thrown = Get-TestThrown { Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher' } }
        $thrown.Message | Should -BeExactly $Reason
        $thrown.Data['LauncherProblem'] | Should -Be 'Unreachable'
        $thrown.Data['Status'] | Should -Be $(if ($Status) { $Status } else { $null })
    }

    It "names the time GitHub's hourly limit of requests resets when it is used up" {
        $world.Error = Get-TestWebError -Status 403 -Description 'rate limit exceeded' -Headers @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '1767225600' }
        $at = [DateTimeOffset]::FromUnixTimeSeconds(1767225600).LocalDateTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $thrown = Get-TestThrown { Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher' } }
        $thrown.Message | Should -BeExactly "GitHub answered HTTP 403 rate limit exceeded, as the requests it answers for this address in an hour are used up until $at"
        $thrown.Data['LauncherProblem'] | Should -Be 'Unreachable'
    }

    It 'says that GitHub lists no published release when it answers 404' {
        $world.Error = Get-TestWebError -Status 404 -Description 'Not Found'
        $thrown = Get-TestThrown { Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher' } }
        $thrown.Message | Should -BeExactly 'GitHub lists no published release of example-owner/launcher: GitHub answered HTTP 404 Not Found'
        $thrown.Data['LauncherProblem'] | Should -Be 'Unreachable'
        $thrown.Data['Status'] | Should -Be 404
    }

    It 'adds TLS 1.2 only to an old protocol setting that lacks it, and puts the setting back' {
        $saved = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls11
            $null = Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher' }
            $seen[0].Protocol | Should -Be ([Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12)
            [Net.ServicePointManager]::SecurityProtocol | Should -Be ([Net.SecurityProtocolType]::Tls11)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::SystemDefault
            $null = Invoke-ModuleFunction 'Get-LauncherRelease' @{ Repo = 'example-owner/launcher' }
            [int]$seen[1].Protocol | Should -Be 0
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $saved
        }
    }

    It 'follows an annotated tag to the commit it names' {
        Invoke-ModuleFunction 'Get-LauncherTagCommit' @{ Repo = 'example-owner/launcher'; Tag = 'v1.1.0' } | Should -BeExactly ('e' * 40)
        @($seen | ForEach-Object { $_.Uri }) | Should -Be @('https://api.github.com/repos/example-owner/launcher/git/ref/tags/v1.1.0',
            "https://api.github.com/repos/example-owner/launcher/git/tags/$('d' * 40)")
    }

    It 'returns the commit a lightweight tag names' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { Get-TestTagRef -Tag 'v1.1.0' -Sha ('f' * 40) }
        Invoke-ModuleFunction 'Get-LauncherTagCommit' @{ Repo = 'example-owner/launcher'; Tag = 'v1.1.0' } | Should -BeExactly ('f' * 40)
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'another tag'; Ref = 'refs/tags/v1.1.00'; Sha = ('f' * 40); Type = 'commit'; Message = "GitHub names no tag v1.1.0 of example-owner/launcher, but 'refs/tags/v1.1.00'." }
        @{ Case = 'a tag of a tree'; Ref = 'refs/tags/v1.1.0'; Sha = ('f' * 40); Type = 'tree'; Message = 'The tag v1.1.0 of example-owner/launcher names a tree, not a commit.' }
        @{ Case = 'an object in capitals'; Ref = 'refs/tags/v1.1.0'; Sha = ('F' * 40); Type = 'commit'; Message = "The tag v1.1.0 of example-owner/launcher names '$('F' * 40)', which is no object of 40 lowercase hex digits." }
    ) {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { [pscustomobject]@{ ref = $Ref; object = [pscustomobject]@{ sha = $Sha; type = $Type } } }
        $thrown = Get-TestThrown { Invoke-ModuleFunction 'Get-LauncherTagCommit' @{ Repo = 'example-owner/launcher'; Tag = 'v1.1.0' } }
        $thrown.Message | Should -BeExactly $Message
        $thrown.Data['LauncherProblem'] | Should -Be 'Refused'
    }

    It 'refuses tags nested deeper than three' {
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            if ($Uri -like '*/git/ref/tags/*') { Get-TestTagRef -Tag 'v1.1.0' -Sha ('d' * 40) -Type 'tag' } else { [pscustomobject]@{ object = [pscustomobject]@{ sha = 'd' * 40; type = 'tag' } } }
        }
        (Get-TestThrown { Invoke-ModuleFunction 'Get-LauncherTagCommit' @{ Repo = 'example-owner/launcher'; Tag = 'v1.1.0' } }).Message |
            Should -BeExactly 'The tag v1.1.0 of example-owner/launcher names tags nested more than three deep, and no commit.'
    }
}

Describe 'Expand-LauncherArchive' {
    BeforeAll {
        # Return the exception Expand-LauncherArchive throws for the zip $Path.
        function Get-TestExtractProblem([string]$Path, [string]$Destination) {
            try {
                Invoke-ModuleFunction 'Expand-LauncherArchive' @{ Path = $Path; Destination = $Destination }
            } catch {
                return $_.Exception
            }
            throw 'Expand-LauncherArchive extracted the zip.'
        }
    }

    BeforeEach {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $work
        $target = Join-Path $work 'tree'
    }

    It 'extracts the folders and files of a zip into a new folder' {
        $zip = Join-Path $work 'good.zip'
        $null = Write-TestReleaseZip -ZipPath $zip -Prefix '' -Extra @{ 'top/' = ''; 'top/a.txt' = 'A'; 'top/sub/b.txt' = 'B'; 'top/empty/' = '' }
        Invoke-ModuleFunction 'Expand-LauncherArchive' @{ Path = $zip; Destination = $target }
        [IO.File]::ReadAllText((Join-Path $target 'top\a.txt')) | Should -BeExactly 'A'
        [IO.File]::ReadAllText((Join-Path $target 'top\sub\b.txt')) | Should -BeExactly 'B'
        Test-Path -LiteralPath (Join-Path $target 'top\empty') -PathType Container | Should -BeTrue
    }

    It 'refuses the entry <Name> before it writes anything' -ForEach @(
        @{ Name = '../evil.txt' }
        @{ Name = '..\evil.txt' }
        @{ Name = 'top/../../evil.txt' }
        @{ Name = '../tree-evil/x.txt' }
        @{ Name = '/rooted.txt' }
        @{ Name = 'C:/rooted.txt' }
        @{ Name = 'top/notes.txt:Zone.Identifier' }
        @{ Name = 'top/./x.txt' }
        @{ Name = 'top//x.txt' }
        @{ Name = 'top/NUL' }
        @{ Name = 'top/con.txt' }
        @{ Name = 'top/dot.' }
        @{ Name = 'top/space ' }
        @{ Name = 'top/what?.txt' }
    ) {
        $zip = Join-Path $work 'evil.zip'
        $null = Write-TestReleaseZip -ZipPath $zip -Prefix '' -Extra @{ 'top/ok.txt' = 'fine'; $Name = 'evil' }
        $problem = Get-TestExtractProblem -Path $zip -Destination $target
        $problem.Message | Should -BeExactly "The zip holds the entry '$Name', which is no plain path inside its folder."
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        Test-Path -LiteralPath $target | Should -BeFalse
        @(Get-ChildItem -LiteralPath $work | ForEach-Object { $_.Name }) | Should -Be @('evil.zip')
        Test-Path -LiteralPath (Join-Path $TestDrive 'evil.txt') | Should -BeFalse
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'two names that differ only in case'; Names = @('top/a.txt', 'TOP/A.TXT'); Message = 'The zip holds * twice, or in two spellings that differ only in case.' }
        @{ Case = 'a file where another entry needs a folder'; Names = @('top/x', 'top/x/y.txt'); Message = 'The zip holds top/x both as a file and as a folder.' }
    ) {
        $zip = Join-Path $work 'odd.zip'
        $extra = New-Object 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([StringComparer]::Ordinal)
        foreach ($name in $Names) { $extra[$name] = $name }
        $null = Write-TestReleaseZip -ZipPath $zip -Prefix '' -Extra $extra
        $problem = Get-TestExtractProblem -Path $zip -Destination $target
        $problem.Message | Should -BeLike $Message
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'refuses a file that is no zip, and a folder that exists already' {
        $zip = Join-Path $work 'broken.zip'
        [IO.File]::WriteAllText($zip, 'not a zip')
        $problem = Get-TestExtractProblem -Path $zip -Destination $target
        $problem.Message | Should -BeLike 'broken.zip is no zip file: *'
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        $null = Write-TestReleaseZip -ZipPath (Join-Path $work 'good.zip') -Prefix '' -Extra @{ 'a.txt' = 'A' }
        $null = New-Item -ItemType Directory -Path $target
        { Invoke-ModuleFunction 'Expand-LauncherArchive' @{ Path = (Join-Path $work 'good.zip'); Destination = $target } } |
            Should -Throw -ExpectedMessage "$target exists already, but a zip is extracted into a new folder only."
    }

    It 'refuses an entry that holds more bytes than the zip states for it, before it writes more than that' {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = Join-Path $work 'lie.zip'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $stream = $archive.CreateEntry('top/big.bin', [IO.Compression.CompressionLevel]::Optimal).Open()
            try { $stream.Write((New-Object byte[] 1MB), 0, 1MB) } finally { $stream.Dispose() }
        } finally {
            $archive.Dispose()
        }
        # The uncompressed size becomes 10 bytes in place of 1 MB, at offset 24 of the central directory header and at offset 22 of the local header.
        $bytes = [IO.File]::ReadAllBytes($zip)
        $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        foreach ($at in @(($text.LastIndexOf('PK' + [char]1 + [char]2) + 24), ($text.IndexOf('PK' + [char]3 + [char]4) + 22))) {
            [Array]::Copy([BitConverter]::GetBytes([uint32]10), 0, $bytes, $at, 4)
        }
        [IO.File]::WriteAllBytes($zip, $bytes)
        $problem = Get-TestExtractProblem -Path $zip -Destination $target
        $problem.Message | Should -BeExactly 'The zip entry top/big.bin holds more bytes than its header says.'
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        (Get-Item -LiteralPath (Join-Path $target 'top\big.bin')).Length | Should -BeLessOrEqual 10
    }

    It 'refuses a zip of more than 10000 entries before it writes anything' {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = Join-Path $work 'many.zip'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            for ($i = 0; $i -le 10000; $i++) { $null = $archive.CreateEntry("top/$i.txt") }
        } finally {
            $archive.Dispose()
        }
        $problem = Get-TestExtractProblem -Path $zip -Destination $target
        $problem.Message | Should -BeExactly 'The zip holds 10001 entries, more than the 10000 a release may hold.'
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        Test-Path -LiteralPath $target | Should -BeFalse
    }
}

Describe 'Test-LauncherFolder' {
    BeforeEach {
        $folder = Write-TestReleaseFolder -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Tag 'v1.2.0' -Files @{ 'config/defaults.psd1' = "@{ }`r`n" }
        $manifestPath = Join-Path $folder 'local-ai-release.json'

        # Return the problems Test-LauncherFolder finds in $Path for $Tag, against $Commit when that is given.
        function Get-TestFolderProblem([string]$Path = $folder, [string]$Tag = 'v1.2.0', [string]$Commit = '') {
            return @(Invoke-ModuleFunction 'Test-LauncherFolder' @{ Path = $Path; Tag = $Tag; Commit = $Commit })
        }

        # Rewrite the manifest after $Change, a script block that changes its parsed table $Manifest.
        function Write-TestManifest([scriptblock]$Change) {
            $Manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath))
            . $Change
            [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $Manifest -Depth 5))
        }
    }

    It 'finds nothing wrong with a whole release folder, also against the commit its tag names' {
        Get-TestFolderProblem | Should -BeNullOrEmpty
        Get-TestFolderProblem -Commit ('c' * 40) | Should -BeNullOrEmpty
    }

    It 'names <Case>' -ForEach @(
        @{ Case = 'a changed file'; Change = { [IO.File]::AppendAllText((Join-Path $folder 'config\defaults.psd1'), '# changed') }
            Expected = 'config/defaults.psd1 differs from the file the release holds' }
        @{ Case = 'a missing file'; Change = { Remove-Item -LiteralPath (Join-Path $folder 'src\local-ai.ps1') }; Expected = 'src/local-ai.ps1 is missing' }
        @{ Case = 'a file the manifest does not list'; Change = { [IO.File]::WriteAllText((Join-Path $folder 'src\extra.ps1'), 'x') }; Expected = 'src/extra.ps1 is not in the manifest' }
        @{ Case = 'a missing manifest'; Change = { Remove-Item -LiteralPath $manifestPath }; Expected = 'it holds no manifest local-ai-release.json' }
        @{ Case = 'a manifest that is not JSON'; Change = { [IO.File]::WriteAllText($manifestPath, '{ broken') }; Expected = 'its manifest is not JSON (*' }
        @{ Case = 'another schema'; Change = { Write-TestManifest { $Manifest.schema = 2 } }; Expected = "its manifest has the schema '2', not 1" }
        @{ Case = 'another name'; Change = { Write-TestManifest { $Manifest.name = 'other-launcher' } }; Expected = "its manifest names 'other-launcher', not local-ai-launcher" }
        @{ Case = 'another version'; Change = { Write-TestManifest { $Manifest.version = '1.2.1' } }; Expected = "its manifest names the version '1.2.1', not 1.2.0" }
        @{ Case = 'another tag'; Change = { Write-TestManifest { $Manifest.tag = 'v1.2.1' } }; Expected = "its manifest names the tag 'v1.2.1', not v1.2.0" }
        @{ Case = 'a commit in capitals'; Change = { Write-TestManifest { $Manifest.commit = 'C' * 40 } }; Expected = "its manifest names the commit '$('C' * 40)', not 40 lowercase hex digits" }
        @{ Case = 'a listed path outside the folder'; Change = { Write-TestManifest { $Manifest.files | Add-Member -NotePropertyName '../outside.txt' -NotePropertyValue ('a' * 64) } }
            Expected = "its manifest lists '../outside.txt', which is no plain path of a file in the folder" }
        @{ Case = 'a hash that is no SHA-256'; Change = { Write-TestManifest { $Manifest.files.'local-ai.cmd' = 'xyz' } }
            Expected = "its manifest lists local-ai.cmd with 'xyz', which is no SHA-256 of 64 lowercase hex digits" }
        @{ Case = 'a manifest without VERSION'; Change = { Write-TestManifest { $Manifest.files.PSObject.Properties.Remove('VERSION') }; Remove-Item -LiteralPath (Join-Path $folder 'VERSION') }
            Expected = 'its manifest lists no VERSION' }
    ) {
        . $Change
        $problems = @(Get-TestFolderProblem)
        $problems.Count | Should -Be 1
        $problems[0] | Should -BeLike $Expected
    }

    It 'names a VERSION that holds another version' {
        $other = Write-TestReleaseFolder -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Tag 'v1.2.0' -Files @{ VERSION = "1.2.1`n" }
        Get-TestFolderProblem -Path $other | Should -Be @("VERSION holds '1.2.1', not 1.2.0")
    }

    It 'names a commit other than the one the tag names' {
        Get-TestFolderProblem -Commit ('d' * 40) | Should -Be @("its manifest names the commit $('c' * 40), but the tag v1.2.0 names $('d' * 40)")
    }

    It 'names a junction inside without entering it' {
        $outside = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $outside
        [IO.File]::WriteAllText((Join-Path $outside 'secret.txt'), 'x')
        $null = New-Item -ItemType Junction -Path (Join-Path $folder 'config\link') -Target $outside
        Get-TestFolderProblem | Should -Be @('config/link is a junction or symbolic link')
    }

    It 'says that a folder is missing or a tag is none' {
        Get-TestFolderProblem -Path (Join-Path $TestDrive 'no-such-folder') | Should -Be @('the folder is missing')
        Get-TestFolderProblem -Tag 'v1.2' | Should -Be @("'v1.2' is no launcher version vX.Y.Z")
    }
}

Describe 'Save-LauncherRelease' {
    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0'
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $world = @{ Zip = (Join-Path $work 'download\local-ai-launcher-1.1.0.zip'); Error = $null }
        $source = Write-TestReleaseFolder -Path (Join-Path $work 'local-ai-launcher-1.1.0') -Tag 'v1.1.0' -Files @{ 'config/defaults.psd1' = "@{ }`r`n" }
        $digest = Write-TestReleaseZip -ZipPath $world.Zip -Folder $source -Prefix 'local-ai-launcher-1.1.0/'
        $release = Invoke-ModuleFunction 'Test-LauncherRelease' @{ Release = (Get-TestReleaseObject -Tag 'v1.1.0' -Digest $digest) }
        $release.Commit = 'c' * 40
        $target = Join-Path $install.Versions 'v1.1.0'
        $staging = Join-Path $install.Root 'staging'
        $downloads = New-Object System.Collections.Generic.List[hashtable]
        Mock Invoke-WebRequest -ModuleName LocalAI -MockWith {
            $downloads.Add(@{ Uri = $Uri; OutFile = $OutFile; Basic = [bool]$UseBasicParsing; TimeoutSec = $TimeoutSec; UserAgent = $UserAgent })
            if ($world.Error) { throw $world.Error }
            Copy-Item -LiteralPath $world.Zip -Destination $OutFile
        }
        $unblocked = New-Object System.Collections.Generic.List[string]
        Mock Unblock-File -ModuleName LocalAI -MockWith { $unblocked.Add($LiteralPath) }

        # Stage $release in the test install and return the result, or the exception Save-LauncherRelease throws.
        function Invoke-TestStaging {
            try {
                return Invoke-ModuleFunction 'Save-LauncherRelease' @{ Release = $release; InstallRoot = $install.Root; UserAgent = 'local-ai-launcher/1.0.0' }
            } catch {
                return $_.Exception
            }
        }

        # Rebuild the zip from the folder $Folder below $Prefix with the entries $Extra, and point $release at its digest.
        function Write-TestStagingZip([string]$Folder = $source, [string]$Prefix = 'local-ai-launcher-1.1.0/', [hashtable]$Extra = @{}) {
            Remove-Item -LiteralPath $world.Zip
            $release.Digest = Write-TestReleaseZip -ZipPath $world.Zip -Folder $Folder -Prefix $Prefix -Extra $Extra
        }
    }

    It 'stages a release as versions\<tag> once the digest and the manifest match, unblocks every file and leaves no staging folder' {
        $result = Invoke-TestStaging
        $result.Path | Should -Be $target
        $result.Downloaded | Should -BeTrue
        @(Invoke-ModuleFunction 'Test-LauncherFolder' @{ Path = $target; Tag = 'v1.1.0'; Commit = ('c' * 40) }) | Should -BeNullOrEmpty
        $downloads.Count | Should -Be 1
        $downloads[0].Uri | Should -BeExactly $release.Url
        $downloads[0].Basic | Should -BeTrue
        $downloads[0].TimeoutSec | Should -Be 120
        $downloads[0].UserAgent | Should -BeExactly 'local-ai-launcher/1.0.0'
        $downloads[0].OutFile | Should -Match ('\A' + [regex]::Escape($staging) + '\\v1\.1\.0-[0-9a-f]{8}\\local-ai-launcher-1\.1\.0\.zip\z')
        $unblocked.Count | Should -Be 5
        @($unblocked | Where-Object { -not $_.StartsWith($staging + '\') }) | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $staging -Force) | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $install.Versions | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('v1.0.0', 'v1.1.0')
    }

    It 'deletes the staging folders older than a day that earlier runs left, and keeps a newer one and any other folder' {
        $old = Join-Path $staging 'v1.1.0-0badf00d'
        $null = New-Item -ItemType Directory -Path (Join-Path $old 'tree')
        [IO.File]::WriteAllText((Join-Path $old 'local-ai-launcher-1.1.0.zip'), 'part of a download')
        (Get-Item -LiteralPath $old).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
        $recent = Join-Path $staging 'v1.1.0-12345678'
        $null = New-Item -ItemType Directory -Path $recent
        $other = Join-Path $staging 'notes'
        $null = New-Item -ItemType Directory -Path $other
        (Get-Item -LiteralPath $other).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
        (Invoke-TestStaging).Path | Should -Be $target
        @(Get-ChildItem -LiteralPath $staging -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('notes', 'v1.1.0-12345678')
    }

    It 'refuses a download whose SHA-256 is not the digest GitHub lists, and keeps nothing of it' {
        $release.Digest = 'sha256:' + ('f' * 64)
        $problem = Invoke-TestStaging
        $problem.Message | Should -BeExactly ("The download of local-ai-launcher-1.1.0.zip has the SHA-256 $((Get-TestFileSha256 $world.Zip)), but GitHub lists " +
            "sha256:$('f' * 64) for it.")
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        Test-Path -LiteralPath $target | Should -BeFalse
        @(Get-ChildItem -LiteralPath $staging -Force) | Should -BeNullOrEmpty
    }

    It 'refuses a zip with an entry outside its folder, writing nothing outside staging' {
        Write-TestStagingZip -Extra @{ '../evil.txt' = 'evil' }
        $problem = Invoke-TestStaging
        $problem.Message | Should -BeExactly "The zip holds the entry '../evil.txt', which is no plain path inside its folder."
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        Test-Path -LiteralPath (Join-Path $install.Root 'evil.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $staging 'evil.txt') | Should -BeFalse
        Test-Path -LiteralPath $target | Should -BeFalse
        @(Get-ChildItem -LiteralPath $staging -Force) | Should -BeNullOrEmpty
    }

    It 'refuses a zip that holds <Case>' -ForEach @(
        @{ Case = 'the folder of another version'; Prefix = 'local-ai-launcher-1.1.1/'; Extra = @{}; Message = 'The zip must hold exactly the folder local-ai-launcher-1.1.0, but it holds local-ai-launcher-1.1.1.' }
        @{ Case = 'a file beside the folder'; Prefix = 'local-ai-launcher-1.1.0/'; Extra = @{ 'README.md' = 'read me' }; Message = 'The zip must hold exactly the folder local-ai-launcher-1.1.0, but it holds *README.md*' }
        @{ Case = 'its files without the folder'; Prefix = ''; Extra = @{}; Message = 'The zip must hold exactly the folder local-ai-launcher-1.1.0, but it holds *local-ai.cmd*' }
    ) {
        Write-TestStagingZip -Prefix $Prefix -Extra $Extra
        $problem = Invoke-TestStaging
        $problem.Message | Should -BeLike $Message
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'refuses a zip whose files do not match its manifest' {
        [IO.File]::AppendAllText((Join-Path $source 'config\defaults.psd1'), '# changed after the build')
        Write-TestStagingZip
        $problem = Invoke-TestStaging
        $problem.Message | Should -BeExactly 'The folder local-ai-launcher-1.1.0 in the zip does not match its manifest: config/defaults.psd1 differs from the file the release holds.'
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'refuses a release whose manifest names another commit than its tag' {
        $release.Commit = 'd' * 40
        $problem = Invoke-TestStaging
        $problem.Message | Should -BeLike "*does not match its manifest: its manifest names the commit $('c' * 40), but the tag v1.1.0 names $('d' * 40).*"
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
    }

    It 'checks a version an earlier run staged instead of downloading it again' {
        $null = Write-TestReleaseFolder -Path $target -Tag 'v1.1.0'
        $result = Invoke-TestStaging
        $result.Path | Should -Be $target
        $result.Downloaded | Should -BeFalse
        $downloads.Count | Should -Be 0
    }

    It 'refuses a version an earlier run staged once it no longer matches its manifest' {
        $null = Write-TestReleaseFolder -Path $target -Tag 'v1.1.0'
        [IO.File]::WriteAllText((Join-Path $target 'src\local-ai.ps1'), 'changed')
        $problem = Invoke-TestStaging
        $problem.Message | Should -BeExactly ("$target, which an earlier run staged, does not match its manifest: src/local-ai.ps1 differs from the file the release holds. " +
            'Move that folder away, then try again.')
        $problem.Data['LauncherProblem'] | Should -Be 'Refused'
        $downloads.Count | Should -Be 0
    }

    It 'says the download failed when it cannot reach the file, and keeps nothing of it' {
        $world.Error = Get-TestWebError -WebStatus 'ConnectFailure' -Message 'Unable to connect to the remote server'
        $problem = Invoke-TestStaging
        $problem.Message | Should -BeExactly 'the download of local-ai-launcher-1.1.0.zip failed: Unable to connect to the remote server'
        $problem.Data['LauncherProblem'] | Should -Be 'Unreachable'
        Test-Path -LiteralPath $target | Should -BeFalse
        @(Get-ChildItem -LiteralPath $staging -Force) | Should -BeNullOrEmpty
    }

    It 'refuses a release without the commit of its tag' {
        $release.Commit = $null
        (Invoke-TestStaging).Message | Should -BeExactly "The release v1.1.0 names no commit of 40 lowercase hex digits ('')."
    }

    It 'stages the zip the release tooling builds from a git repository' {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) '.github\scripts\LocalAIRelease.psm1') -Force
        $repository = Join-Path $work 'repository'
        $null = New-Item -ItemType Directory -Path $repository
        $files = @{
            'local-ai.cmd' = "@echo off`nexit /b 0`n"; 'src/local-ai.ps1' = "param()`n"; 'src/LocalAI.psm1' = "function Get-Test { 1 }`n"; 'config/defaults.psd1' = "@{ }`n"
            'README.md' = "# Test`n"; 'LICENSE' = "MIT License`n"; 'VERSION' = "1.1.0`n"; 'tests/Tool.Tests.ps1' = "Describe 'Tool' { }`n"
        }
        foreach ($name in $files.Keys) {
            $full = Join-Path $repository $name
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent)
            [IO.File]::WriteAllText($full, $files[$name])
        }
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) '.gitattributes') -Destination $repository
        $git = @('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'init.defaultBranch=main', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')
        $savedPreference = $ErrorActionPreference
        try {
            # git writes progress to stderr, which Windows PowerShell 5.1 turns into error records.
            $ErrorActionPreference = 'Continue'
            $null = & git @git init -q $repository 2>&1
            $null = & git @git -C $repository add -A 2>&1
            $null = & git @git -C $repository commit -q -m 'release' 2>&1
            $LASTEXITCODE | Should -Be 0
        } finally {
            $ErrorActionPreference = $savedPreference
        }
        $built = New-ReleaseZip -RepositoryPath $repository -Commit 'HEAD' -Version '1.1.0' -OutputDirectory (Join-Path $work 'built')
        $world.Zip = $built.Path
        $release.Digest = 'sha256:' + $built.Sha256
        $release.Commit = $built.Commit
        $result = Invoke-TestStaging
        $result.Path | Should -Be $target
        $expected = @('config\defaults.psd1', 'LICENSE', 'local-ai-release.json', 'local-ai.cmd', 'README.md', 'src\local-ai.ps1', 'src\LocalAI.psm1', 'VERSION')
        @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object { $_.FullName.Substring($target.Length + 1) } | Sort-Object) | Should -Be @($expected | Sort-Object)
    }
}

Describe 'Get-LauncherInstallKind' {
    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0'
        $kind = { param([string]$Path) Invoke-ModuleFunction 'Get-LauncherInstallKind' @{ RepoRoot = $Path; InstallRoot = $install.Root } }
    }

    It "is 'git' for a checkout whose .git is a folder or, in a worktree, a file" {
        $checkout = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $checkout '.git')
        & $kind $checkout | Should -Be 'git'
        $worktree = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $worktree
        [IO.File]::WriteAllText((Join-Path $worktree '.git'), 'gitdir: C:/repo/.git/worktrees/x')
        & $kind $worktree | Should -Be 'git'
        & $kind (Split-Path $PSScriptRoot -Parent) | Should -Be 'git'
    }

    It "is 'release' for versions\<tag> of the install folder with its manifest, in any case and with a trailing backslash" {
        & $kind (Join-Path $install.Versions 'v1.0.0') | Should -Be 'release'
        & $kind ((Join-Path $install.Versions 'v1.0.0').ToUpperInvariant().Replace('\V1.0.0', '\v1.0.0') + '\') | Should -Be 'release'
    }

    It "is 'folder' for <Case>" -ForEach @(
        @{ Case = 'a version folder without its manifest'; Make = { $null = New-Item -ItemType Directory -Path (Join-Path $install.Versions 'v1.1.0'); Join-Path $install.Versions 'v1.1.0' } }
        @{ Case = 'a folder in versions that is no tag'; Make = { $null = Write-TestReleaseFolder -Path (Join-Path $install.Versions 'v1.1') -Tag 'v1.1.0'; Join-Path $install.Versions 'v1.1' } }
        @{ Case = 'a release folder outside the install folder'; Make = { Write-TestReleaseFolder -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\v1.0.0')) -Tag 'v1.0.0' } }
        @{ Case = 'a zip extracted by hand'; Make = { Write-TestReleaseFolder -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\local-ai-launcher-1.0.0')) -Tag 'v1.0.0' } }
        @{ Case = 'a folder that does not exist'; Make = { Join-Path $TestDrive 'nothing-here' } }
    ) {
        $path = . $Make
        & $kind $path | Should -Be 'folder'
    }

    It "is 'folder' for a version folder when there is no install folder to compare with" {
        Invoke-ModuleFunction 'Get-LauncherInstallKind' @{ RepoRoot = (Join-Path $install.Versions 'v1.0.0'); InstallRoot = $null } | Should -Be 'folder'
    }
}

Describe 'Get-LauncherCurrent and Set-LauncherCurrent' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $current = Join-Path $root 'current'
    }

    It 'writes the tag and CRLF in ASCII, replaces what was there, and leaves no .tmp' {
        Invoke-ModuleFunction 'Set-LauncherCurrent' @{ InstallRoot = $root; Tag = 'v1.2.3' }
        [IO.File]::ReadAllBytes($current) | Should -Be ([Text.Encoding]::ASCII.GetBytes("v1.2.3`r`n"))
        Invoke-ModuleFunction 'Set-LauncherCurrent' @{ InstallRoot = $root; Tag = 'v1.10.0' }
        [IO.File]::ReadAllText($current) | Should -BeExactly "v1.10.0`r`n"
        @(Get-ChildItem -LiteralPath $root | ForEach-Object { $_.Name }) | Should -Be @('current')
        Invoke-ModuleFunction 'Get-LauncherCurrent' @{ InstallRoot = $root } | Should -BeExactly 'v1.10.0'
    }

    It 'refuses a tag that is none and leaves current as it was' {
        Invoke-ModuleFunction 'Set-LauncherCurrent' @{ InstallRoot = $root; Tag = 'v1.2.3' }
        { Invoke-ModuleFunction 'Set-LauncherCurrent' @{ InstallRoot = $root; Tag = 'v1.2' } } | Should -Throw -ExpectedMessage "'v1.2' is no launcher version vX.Y.Z."
        [IO.File]::ReadAllText($current) | Should -BeExactly "v1.2.3`r`n"
    }

    It 'reads <Expected> from <Case>, as the shim reads it' -ForEach @(
        @{ Case = 'the tag and CRLF'; Bytes = "v1.2.3`r`n"; Expected = 'v1.2.3' }
        @{ Case = 'the tag and LF'; Bytes = "v1.2.3`n"; Expected = 'v1.2.3' }
        @{ Case = 'the tag alone'; Bytes = 'v1.2.3'; Expected = 'v1.2.3' }
        @{ Case = 'two lines with CRLF'; Bytes = "v1.2.3`r`nv9.9.9`r`n"; Expected = 'v1.2.3' }
    ) {
        [IO.File]::WriteAllText($current, $Bytes, [Text.Encoding]::ASCII)
        Invoke-ModuleFunction 'Get-LauncherCurrent' @{ InstallRoot = $root } | Should -BeExactly $Expected
    }

    It 'reads no tag from <Case>, which the shim refuses too' -ForEach @(
        @{ Case = 'an empty file'; Text = '' }
        @{ Case = 'two lines with LF'; Text = "v1.2.3`nv9.9.9`n" }
        @{ Case = 'a space after the tag'; Text = "v1.2.3 `r`n" }
        @{ Case = 'a byte order mark'; Text = ([string][char]0xFEFF) + "v1.2.3`r`n" }
        @{ Case = 'another text'; Text = "latest`r`n" }
    ) {
        [IO.File]::WriteAllText($current, $Text, (New-Object Text.UTF8Encoding $false))
        ($null -eq (Invoke-ModuleFunction 'Get-LauncherCurrent' @{ InstallRoot = $root })) | Should -BeTrue
    }

    It 'reads no tag when there is no file current or no install folder' {
        ($null -eq (Invoke-ModuleFunction 'Get-LauncherCurrent' @{ InstallRoot = $root })) | Should -BeTrue
        ($null -eq (Invoke-ModuleFunction 'Get-LauncherCurrent' @{ InstallRoot = '' })) | Should -BeTrue
    }
}

Describe 'Install-LocalAILauncher and the shim' {
    BeforeAll {
        # Run the batch file $Path through cmd.exe and return @{ Code; Lines }.
        function Invoke-TestCmd([string]$Path) {
            $lines = @(& cmd.exe /d /c $Path 2>&1 | ForEach-Object { "$_" })
            return @{ Code = $LASTEXITCODE; Lines = $lines }
        }

        # Run the command line $Line in cmd.exe with the working folder $Folder and $PathFirst first on PATH, and return @{ Code; Lines }.
        function Invoke-TestCmdIn([string]$Folder, [string]$Line, [string]$PathFirst) {
            $start = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList (Join-Path $env:SystemRoot 'System32\cmd.exe')
            $start.Arguments = '/d /s /c "' + $Line + '"'
            $start.WorkingDirectory = $Folder
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.EnvironmentVariables['PATH'] = "$PathFirst;$env:PATH"
            $process = [System.Diagnostics.Process]::Start($start)
            $text = $process.StandardOutput.ReadToEnd()
            $process.WaitForExit()
            return @{ Code = $process.ExitCode; Lines = @($text -split "`r`n" | Where-Object { $_ }) }
        }

        # Replace local-ai.cmd of the version $Tag in $Versions with a stand-in that prints its version and the arguments it got, and exits with
        # LOCALAI_TEST_CODE.
        function Write-TestVersionCmd([string]$Versions, [string]$Tag) {
            [IO.File]::WriteAllText((Join-Path $Versions "$Tag\local-ai.cmd"),
                "@echo off`r`nsetlocal DisableDelayedExpansion`r`necho VERSION $Tag`r`necho ARGS=%*`r`nexit /b %LOCALAI_TEST_CODE%`r`n", [Text.Encoding]::ASCII)
        }
    }

    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0', 'v1.1.0') -Current ''
        $shim = Join-Path $install.Root 'local-ai.cmd'
        $current = Join-Path $install.Root 'current'
        $savedCode = $env:LOCALAI_TEST_CODE
        $env:LOCALAI_TEST_CODE = '7'
        # The shim runs only from %LOCALAPPDATA%\Programs\local-ai-launcher.
        $savedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $install.LocalAppData
        # Arguments with spaces, quotes, an exclamation mark, an ampersand inside quotes and a percent sign.
        $arguments = 'status "a b" "c ""d"" e" !bang! "x&y" 50%% -Json'
    }

    AfterEach {
        $env:LOCALAI_TEST_CODE = $savedCode
        $env:LOCALAPPDATA = $savedLocalAppData
    }

    It 'is exported, writes the shim with CRLF and no label or call, and points current at the tag' {
        (Get-Command -Name 'Install-LocalAILauncher' -CommandType Function).ModuleName | Should -Be 'LocalAI'
        $result = Install-LocalAILauncher -Root $install.Root -Tag 'v1.1.0'
        $result.ShimWritten | Should -BeTrue
        $result.Shim | Should -Be $shim
        [IO.File]::ReadAllText($current) | Should -BeExactly "v1.1.0`r`n"
        $bytes = [IO.File]::ReadAllBytes($shim)
        @($bytes | Where-Object { $_ -gt 0x7F }) | Should -BeNullOrEmpty
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        [regex]::Matches($text, '(?<!\r)\n').Count | Should -Be 0
        $text.EndsWith("`r`n") | Should -BeTrue
        $code = @($text -split "`r`n" | Where-Object { $_ -and $_ -notmatch '^rem ' })
        @($code | Where-Object { $_ -match '^\s*:' -or $_ -match '(?i)\b(call|goto)\b' }) | Should -BeNullOrEmpty
        $code[-1] | Should -BeExactly '"%~dp0versions\%LOCALAI_TAG%\local-ai.cmd" %*'
        @(Get-ChildItem -LiteralPath $install.Root -Filter '*.tmp') | Should -BeNullOrEmpty
    }

    It 'never rewrites a shim that exists, as cmd.exe may be running it' {
        [IO.File]::WriteAllText($shim, "@echo off`r`nrem an older shim`r`n")
        $time = (Get-Date).AddDays(-3)
        (Get-Item -LiteralPath $shim).LastWriteTime = $time
        $result = Install-LocalAILauncher -Root $install.Root -Tag 'v1.0.0'
        $result.ShimWritten | Should -BeFalse
        [IO.File]::ReadAllText($shim) | Should -BeExactly "@echo off`r`nrem an older shim`r`n"
        (Get-Item -LiteralPath $shim).LastWriteTime | Should -Be $time
        [IO.File]::ReadAllText($current) | Should -BeExactly "v1.0.0`r`n"
    }

    It 'refuses a version whose folder is missing or does not match its manifest, leaving current as it was' {
        $null = Install-LocalAILauncher -Root $install.Root -Tag 'v1.0.0'
        { Install-LocalAILauncher -Root $install.Root -Tag 'v2.0.0' } | Should -Throw -ExpectedMessage "*v2.0.0 does not match its manifest local-ai-release.json, so it does not become the active launcher: the folder is missing."
        [IO.File]::WriteAllText((Join-Path $install.Versions 'v1.1.0\VERSION'), "9.9.9`n")
        { Install-LocalAILauncher -Root $install.Root -Tag 'v1.1.0' } | Should -Throw -ExpectedMessage '*VERSION differs from the file the release holds*'
        { Install-LocalAILauncher -Root $install.Root -Tag 'v1.1' } | Should -Throw -ExpectedMessage "'v1.1' is no launcher version vX.Y.Z."
        [IO.File]::ReadAllText($current) | Should -BeExactly "v1.0.0`r`n"
    }

    It 'runs, through cmd.exe, the version current names with every argument as it is, and passes its exit code on' {
        $null = Install-LocalAILauncher -Root $install.Root -Tag 'v1.0.0'
        Write-TestVersionCmd -Versions $install.Versions -Tag 'v1.0.0'
        Write-TestVersionCmd -Versions $install.Versions -Tag 'v1.1.0'
        $viaShim = Write-TestFile ("shim-$([guid]::NewGuid().ToString('N')).cmd") "@`"$shim`" $arguments`r`n"
        $direct = Write-TestFile ("direct-$([guid]::NewGuid().ToString('N')).cmd") "@`"$(Join-Path $install.Versions 'v1.0.0\local-ai.cmd')`" $arguments`r`n"
        $run = Invoke-TestCmd $viaShim
        $run.Code | Should -Be 7
        $run.Lines | Should -Be @('VERSION v1.0.0', 'ARGS=status "a b" "c ""d"" e" !bang! "x&y" 50% -Json')
        $straight = Invoke-TestCmd $direct
        $run.Lines | Should -Be $straight.Lines
        $env:LOCALAI_TEST_CODE = '0'
        Invoke-ModuleFunction 'Set-LauncherCurrent' @{ InstallRoot = $install.Root; Tag = 'v1.1.0' }
        $run = Invoke-TestCmd $viaShim
        $run.Code | Should -Be 0
        $run.Lines[0] | Should -BeExactly 'VERSION v1.1.0'
    }

    It 'stops with exit code 1 and says why when current <Case>' -ForEach @(
        @{ Case = 'is missing'; Bytes = $null; Message = 'The file current beside this one names no launcher version. Run install.ps1 again.' }
        @{ Case = 'is empty'; Bytes = ''; Message = 'The file current beside this one names no launcher version. Run install.ps1 again.' }
        @{ Case = 'holds a command'; Bytes = "v1.0.0 & echo INJECTED`r`n"; Message = 'The file current beside this one names no launcher version. Run install.ps1 again.' }
        @{ Case = 'names a version that is not there'; Bytes = "v9.9.9`r`n"; Message = 'The launcher version v9.9.9 is missing from the folder versions beside this one. Run install.ps1 again.' }
    ) {
        $null = Install-LocalAILauncher -Root $install.Root -Tag 'v1.0.0'
        Write-TestVersionCmd -Versions $install.Versions -Tag 'v1.0.0'
        if ($null -eq $Bytes) { Remove-Item -LiteralPath $current } else { [IO.File]::WriteAllText($current, $Bytes, [Text.Encoding]::ASCII) }
        $run = Invoke-TestCmd (Write-TestFile ("shim-$([guid]::NewGuid().ToString('N')).cmd") "@`"$shim`" status`r`n")
        $run.Code | Should -Be 1
        $run.Lines | Should -Be @($Message)
    }

    It 'refuses <Call> from <Where>, where cmd.exe expands %~dp0 to that folder, and runs nothing from there' -ForEach @(
        @{ Call = '"local-ai" status'; Where = 'another folder'; Make = { Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) } }
        @{ Call = '"local-ai.cmd" status'; Where = 'another folder'; Make = { Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) } }
        @{ Call = '"local-ai" status'; Where = 'the folder that LOCALAPPDATA and Programs\local-ai-launcher name without a backslash between them'
            Make = { "$($install.LocalAppData)Programs\local-ai-launcher" } }
    ) {
        $null = Install-LocalAILauncher -Root $install.Root -Tag 'v1.0.0'
        Write-TestVersionCmd -Versions $install.Versions -Tag 'v1.0.0'
        # A folder laid out like the install folder, whose version is no release.
        $planted = & $Make
        $null = New-Item -ItemType Directory -Path (Join-Path $planted 'versions\v6.6.6')
        [IO.File]::WriteAllText((Join-Path $planted 'current'), "v6.6.6`r`n")
        [IO.File]::WriteAllText((Join-Path $planted 'versions\v6.6.6\local-ai.cmd'), "@echo off`r`necho PLANTED`r`nexit /b 9`r`n")
        $quoted = Invoke-TestCmdIn -Folder $planted -Line $Call -PathFirst $install.Root
        $quoted.Code | Should -Be 1
        $quoted.Lines | Should -Be @('This local-ai.cmd runs only from %LOCALAPPDATA%\Programs\local-ai-launcher; run it by that path, or as local-ai without quotes.')
        $plain = Invoke-TestCmdIn -Folder $planted -Line 'local-ai status' -PathFirst $install.Root
        $plain.Code | Should -Be 7
        $plain.Lines[0] | Should -BeExactly 'VERSION v1.0.0'
    }

    It 'runs from the install folder when LOCALAPPDATA is spelled <Case>' -ForEach @(
        @{ Case = 'with a backslash at its end'; Make = { "$($install.LocalAppData)\" } }
        @{ Case = 'with two backslashes at its end'; Make = { "$($install.LocalAppData)\\" } }
        @{ Case = 'with a dot segment at its end'; Make = { "$($install.LocalAppData)\." } }
        @{ Case = 'in capitals'; Make = { $install.LocalAppData.ToUpperInvariant() } }
    ) {
        $null = Install-LocalAILauncher -Root $install.Root -Tag 'v1.0.0'
        Write-TestVersionCmd -Versions $install.Versions -Tag 'v1.0.0'
        $viaShim = Write-TestFile ("shim-$([guid]::NewGuid().ToString('N')).cmd") "@`"$shim`" status`r`n"
        $env:LOCALAPPDATA = & $Make
        $run = Invoke-TestCmd $viaShim
        $run.Code | Should -Be 7
        $run.Lines[0] | Should -BeExactly 'VERSION v1.0.0'
    }

    It 'refuses to run, even by its full path, when LOCALAPPDATA <Case>' -ForEach @(
        @{ Case = 'names another folder'; Make = { Join-Path $TestDrive 'another-LocalAppData' } }
        @{ Case = 'is not set'; Make = { $null } }
    ) {
        $null = Install-LocalAILauncher -Root $install.Root -Tag 'v1.0.0'
        Write-TestVersionCmd -Versions $install.Versions -Tag 'v1.0.0'
        $viaShim = Write-TestFile ("shim-$([guid]::NewGuid().ToString('N')).cmd") "@`"$shim`" status`r`n"
        $env:LOCALAPPDATA = & $Make
        $run = Invoke-TestCmd $viaShim
        $run.Code | Should -Be 1
        $run.Lines | Should -Be @('This local-ai.cmd runs only from %LOCALAPPDATA%\Programs\local-ai-launcher; run it by that path, or as local-ai without quotes.')
    }
}

Describe 'Remove-OldLauncherVersion' {
    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v0.8.0', 'v0.9.0', 'v0.10.0', 'v1.0.0') -Current 'v1.0.0'
        $null = New-Item -ItemType Directory -Path (Join-Path $install.Versions 'notes')
        $null = Write-TestReleaseFolder -Path (Join-Path $install.Versions 'v1.0') -Tag 'v1.0.0'
        $null = New-Item -ItemType Directory -Path (Join-Path $install.Versions 'v0.7.0')
        $outside = Write-TestReleaseFolder -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Tag 'v0.6.0'
        $null = New-Item -ItemType Junction -Path (Join-Path $install.Versions 'v0.6.0') -Target $outside
        $prune = { param([int]$Keep, [string[]]$Protect) @(Invoke-ModuleFunction 'Remove-OldLauncherVersion' @{ InstallRoot = $install.Root; Keep = $Keep; Protect = $Protect } 3>$null) }
        $left = { @(Get-ChildItem -LiteralPath $install.Versions | ForEach-Object { $_.Name } | Sort-Object) }
    }

    It 'keeps the active, the previous and the running version and the one update stages, counting them first' {
        $removed = & $prune 2 @('v1.0.0', 'v0.8.0', 'v1.0.0', 'v1.1.0')
        @($removed | Sort-Object) | Should -Be @((Join-Path $install.Versions 'v0.10.0'), (Join-Path $install.Versions 'v0.9.0'))
        & $left | Should -Be @('notes', 'v0.6.0', 'v0.7.0', 'v0.8.0', 'v1.0', 'v1.0.0')
        Test-Path -LiteralPath (Join-Path $outside 'local-ai-release.json') | Should -BeTrue
    }

    It 'keeps the newest others, by version and not by name, up to the number to keep' {
        $removed = & $prune 3 @('v1.0.0')
        @($removed) | Should -Be @((Join-Path $install.Versions 'v0.8.0'))
        & $left | Should -Be @('notes', 'v0.10.0', 'v0.6.0', 'v0.7.0', 'v0.9.0', 'v1.0', 'v1.0.0')
    }

    It 'warns and goes on when a version cannot be deleted, as while a window works in it' {
        Mock Remove-LocalAIFolder -ModuleName LocalAI -MockWith { [IO.Directory]::Delete($Path, $true) }
        Mock Remove-LocalAIFolder -ModuleName LocalAI -ParameterFilter { $Path -like '*\v0.9.0' } -MockWith { throw 'Windows refuses to rename it.' }
        $warnings = @(Invoke-ModuleFunction 'Remove-OldLauncherVersion' @{ InstallRoot = $install.Root; Keep = 2; Protect = @('v1.0.0', 'v0.8.0') } 3>&1 |
                Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        $warnings | Should -Be @("Could not delete the old launcher version $(Join-Path $install.Versions 'v0.9.0'): Windows refuses to rename it.")
        Test-Path -LiteralPath (Join-Path $install.Versions 'v0.10.0') | Should -BeFalse
    }

    It 'does nothing without a versions folder' {
        Invoke-ModuleFunction 'Remove-OldLauncherVersion' @{ InstallRoot = (Join-Path $TestDrive 'no-install'); Keep = 2 } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-LauncherSelfUpdate' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent

        # Run Invoke-LauncherSelfUpdate with $Context and return @{ Result; Printed; Warnings }: what it returned, the host text and the warnings joined.
        function Invoke-TestSelfUpdate([hashtable]$Context) {
            $output = @(Invoke-ModuleFunction 'Invoke-LauncherSelfUpdate' @{ Context = $Context } 3>&1 6>&1)
            $records = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
            $other = @($output | Where-Object { $null -ne $_ -and $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] })
            return @{
                Result   = if ($other.Count -gt 0) { $other[-1] } else { $null }
                Printed  = @($records | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
            }
        }
    }

    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $repo = $settings.Launcher.Repo
        $lock = 'Local\LocalAITest-' + [guid]::NewGuid().ToString('N')
        $hold = @{ Mutex = (Enter-LocalAILock -Name $lock); Transcribing = $false }
        $context = @{ Verb = 'update'; Paths = $paths; Settings = $settings; RepoRoot = (Join-Path $install.Versions 'v1.0.0'); InstallRoot = $install.Root; Tools = $false
            Hold = $hold; ActivateLauncher = '' }
        $source = Write-TestReleaseFolder -Path (Join-Path $root 'build\local-ai-launcher-1.1.0') -Tag 'v1.1.0'
        $world = @{ Zip = (Join-Path $root 'build\local-ai-launcher-1.1.0.zip'); Ref = (Get-TestTagRef -Tag 'v1.1.0'); Error = $null; RefError = $null
            DownloadError = $null; ChildCode = 0; Activate = $true; Child = $null; LockFree = $null }
        $world.Digest = Write-TestReleaseZip -ZipPath $world.Zip -Folder $source -Prefix 'local-ai-launcher-1.1.0/'
        $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Digest $world.Digest
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            if ($world.Error) { throw $world.Error }
            switch -Wildcard ($Uri) {
                "https://api.github.com/repos/$repo/releases/latest" { $world.Release }
                "https://api.github.com/repos/$repo/git/ref/tags/*" { if ($world.RefError) { throw $world.RefError } else { $world.Ref } }
                default { throw "Unexpected request to $Uri" }
            }
        }
        Mock Invoke-WebRequest -ModuleName LocalAI -MockWith {
            if ($world.DownloadError) { throw $world.DownloadError }
            Copy-Item -LiteralPath $world.Zip -Destination $OutFile
        }
        # The version handed over to: it activates itself, as a yes does, unless Activate is off.
        Mock Invoke-LauncherChild -ModuleName LocalAI -MockWith {
            $world.Child = @{ Script = $Script; ArgumentList = @($ArgumentList) }
            $world.LockFree = Test-MutexFree -Name $lock
            if ($world.Activate) { [IO.File]::WriteAllText((Join-Path $install.Root 'current'), "v1.1.0`r`n") }
            $world.ChildCode
        }
    }

    AfterEach {
        Exit-LocalAILock -Mutex $hold.Mutex
    }

    It 'leaves the code of a git checkout alone without asking GitHub' {
        $context.RepoRoot = $repoRoot
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Printed | Should -BeExactly ("This launcher runs from the git checkout $repoRoot, so update leaves its own code alone: update it with 'git pull' on main, or " +
            'install a release with install.ps1.')
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
        ($null -ne $hold.Mutex) | Should -BeTrue
    }

    It 'gives the install.ps1 hint for a launcher in another folder, asking GitHub nothing' {
        $context.RepoRoot = Write-TestReleaseFolder -Path (Join-Path $root 'Downloads\local-ai-launcher-1.0.0') -Tag 'v1.0.0'
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Printed | Should -BeLike '*which is no release install, so update leaves its own code alone; install.ps1 of a release installs a launcher that updates itself.'
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'does nothing in the run update handed over to' {
        $context.ActivateLauncher = 'v1.0.0'
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Printed | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'says the launcher is at the latest release, and records the check in state.json' {
        $world.Release = Get-TestReleaseObject -Tag 'v1.0.0' -Digest $world.Digest
        $before = [DateTime]::UtcNow.Ticks
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Printed | Should -BeExactly "Checking $repo for a launcher newer than v1.0.0...`nThe launcher is at the latest release v1.0.0."
        $check = (Read-LocalAIState -Path $paths.State).Launcher.LastCheck
        $check.Latest | Should -BeExactly 'v1.0.0'
        $check.Digest | Should -BeExactly $world.Digest
        ($null -eq $check.Error) | Should -BeTrue
        $check.CheckedAt | Should -BeGreaterOrEqual $before
        Should -Invoke Invoke-WebRequest -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'never downgrades to a latest release that is older' {
        $world.Release = Get-TestReleaseObject -Tag 'v0.9.0' -Digest $world.Digest
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Printed | Should -BeLike '*The launcher v1.0.0 is newer than the latest release v0.9.0, and update never downgrades.'
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'stages a newer release, releases the lock, then hands over to its update with -ActivateLauncher and returns its exit code' {
        $world.ChildCode = 2
        $run = Invoke-TestSelfUpdate -Context $context
        $run.Result | Should -Be 2
        $world.Child.Script | Should -Be (Join-Path $install.Versions 'v1.1.0\src\local-ai.ps1')
        $world.Child.ArgumentList | Should -Be @('update', '-ActivateLauncher', 'v1.1.0')
        $world.LockFree | Should -BeTrue
        ($null -eq $hold.Mutex) | Should -BeTrue
        @(Invoke-ModuleFunction 'Test-LauncherFolder' @{ Path = (Join-Path $install.Versions 'v1.1.0'); Tag = 'v1.1.0'; Commit = ('c' * 40) }) | Should -BeNullOrEmpty
        $run.Printed | Should -BeLike ("*The launcher v1.1.0 is out, and this one is v1.0.0.*Downloading local-ai-launcher-1.1.0.zip from $repo...*" +
            "The download matches the SHA-256 GitHub lists, and every file matches the release's manifest.*Handing over to the launcher v1.1.0 in " +
            "$(Join-Path $install.Versions 'v1.1.0'), which shows the update plan and asks before it changes anything.")
        (Read-LocalAIState -Path $paths.State).Launcher.LastCheck.Latest | Should -BeExactly 'v1.1.0'
    }

    It 'passes -Tools on to the version it hands over to' {
        $context.Tools = $true
        $null = Invoke-TestSelfUpdate -Context $context
        $world.Child.ArgumentList | Should -Be @('update', '-Tools', '-ActivateLauncher', 'v1.1.0')
    }

    It 'says the launcher stays as it is when the version it handed over to changed nothing, which stays staged' {
        $world.Activate = $false
        $world.ChildCode = 2
        $run = Invoke-TestSelfUpdate -Context $context
        $run.Result | Should -Be 2
        $run.Printed | Should -BeLike "*The launcher stays at v1.0.0, and v1.1.0 waits in $(Join-Path $install.Versions 'v1.1.0') for the next update."
        Test-Path -LiteralPath (Join-Path $install.Versions 'v1.1.0\local-ai-release.json') | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $install.Root 'current')) | Should -BeExactly "v1.0.0`r`n"
    }

    It 'returns 1 when the version it handed over to ends with another exit code' {
        $world.ChildCode = -1
        $run = Invoke-TestSelfUpdate -Context $context
        $run.Result | Should -Be 1
        $run.Printed | Should -BeLike "*The launcher in $(Join-Path $install.Versions 'v1.1.0') ended with exit code -1.*"
    }

    It 'warns that it could not check, and goes on in this version, when <Case>' -ForEach @(
        @{ Case = 'there is no network'; Status = 0; Description = ''; Headers = @{}; Reason = 'Unable to connect to the remote server' }
        @{ Case = "GitHub's hourly limit is used up"; Status = 403; Description = 'rate limit exceeded'; Headers = @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '1767225600' }
            Reason = 'GitHub answered HTTP 403 rate limit exceeded, as the requests it answers for this address in an hour are used up until *' }
        @{ Case = 'GitHub has a fault'; Status = 502; Description = 'Bad Gateway'; Headers = @{}; Reason = 'GitHub answered HTTP 502 Bad Gateway' }
        @{ Case = 'GitHub lists no release'; Status = 404; Description = 'Not Found'; Headers = @{}; Reason = "GitHub lists no published release of *: GitHub answered HTTP 404 Not Found" }
    ) {
        $world.Error = if ($Status) { Get-TestWebError -Status $Status -Description $Description -Headers $Headers } else { Get-TestWebError }
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Warnings | Should -BeLike "Could not check for a newer launcher ($Reason); it stays at v1.0.0."
        $check = (Read-LocalAIState -Path $paths.State).Launcher.LastCheck
        $check.Error | Should -BeLike $Reason
        ($null -eq $check.Latest) | Should -BeTrue
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
        ($null -ne $hold.Mutex) | Should -BeTrue
    }

    It 'warns and goes on in this version when GitHub names a newer release but does not answer for its tag' {
        $world.RefError = Get-TestWebError
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Warnings | Should -BeExactly 'Could not check for a newer launcher (Unable to connect to the remote server); it stays at v1.0.0.'
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter { $Uri -like '*/git/ref/tags/v1.1.0' }
        $check = (Read-LocalAIState -Path $paths.State).Launcher.LastCheck
        $check.Error | Should -BeExactly 'Unable to connect to the remote server'
        ($null -eq $check.Latest) | Should -BeTrue
        ($null -eq $check.Digest) | Should -BeTrue
        Should -Invoke Invoke-WebRequest -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $install.Versions 'v1.1.0') | Should -BeFalse
        ($null -ne $hold.Mutex) | Should -BeTrue
    }

    It 'changes nothing and returns 1 when <Case>' -ForEach @(
        @{ Case = 'the release is not immutable'; Setup = { $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Digest $world.Digest -Fields @{ immutable = $false } }
            Message = '*The release v1.1.0 is not immutable*' }
        @{ Case = 'the latest release is a prerelease'; Setup = { $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Digest $world.Digest -Fields @{ prerelease = $true } }
            Message = '*The release v1.1.0 is a prerelease*' }
        @{ Case = 'its tag has a suffix'; Setup = { $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Digest $world.Digest -Fields @{ tag_name = 'v1.1.0-beta' } }
            Message = "*The release is tagged 'v1.1.0-beta'*" }
        @{ Case = 'it holds no zip'; Setup = { $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Digest $world.Digest -Fields @{ assets = @() } }
            Message = '*The release v1.1.0 holds no asset local-ai-launcher-1.1.0.zip.*' }
        @{ Case = 'the download does not match the digest'; Setup = { $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Digest ('sha256:' + ('f' * 64)) }
            Message = '*but GitHub lists sha256:ffff*' }
        @{ Case = 'the manifest names another commit than the tag'; Setup = { $world.Ref = Get-TestTagRef -Tag 'v1.1.0' -Sha ('d' * 40) }; Message = '*but the tag v1.1.0 names dddd*' }
        @{ Case = 'the zip holds an entry outside its folder'
            Setup = {
                Remove-Item -LiteralPath $world.Zip
                $digest = Write-TestReleaseZip -ZipPath $world.Zip -Folder $source -Prefix 'local-ai-launcher-1.1.0/' -Extra @{ '../evil.cmd' = 'evil' }
                $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Digest $digest
            }
            Message = "*The zip holds the entry '../evil.cmd', which is no plain path inside its folder.*" }
    ) {
        # Versions beyond Launcher.KeepVersions, which a refused release must not cost either.
        $install = Write-TestLauncherInstall -Tags @('v0.8.0', 'v0.9.0', 'v1.0.0') -Current 'v1.0.0'
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.InstallRoot = $install.Root
        Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ Version = 'v1.0.0'; Previous = 'v0.9.0' } }
        . $Setup
        $run = Invoke-TestSelfUpdate -Context $context
        $run.Result | Should -Be 1
        $run.Printed | Should -BeLike "$Message`nUpdate changed nothing."
        $run.Printed | Should -Not -BeLike '*Deleted*'
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $install.Versions | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('v0.8.0', 'v0.9.0', 'v1.0.0')
        @(Get-ChildItem -LiteralPath (Join-Path $install.Root 'staging') -Force -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $install.Root 'evil.cmd') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $install.Root 'current')) | Should -BeExactly "v1.0.0`r`n"
    }

    It 'warns and goes on in this version when the download fails' {
        $world.DownloadError = Get-TestWebError
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        $run.Warnings | Should -BeExactly ('Could not download the launcher v1.1.0 (the download of local-ai-launcher-1.1.0.zip failed: Unable to connect to the remote server); it ' +
            'stays at v1.0.0.')
        Test-Path -LiteralPath (Join-Path $install.Versions 'v1.1.0') | Should -BeFalse
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'prunes, once it has staged the new version, the versions Launcher.KeepVersions does not keep, never the previous one' {
        $install = Write-TestLauncherInstall -Tags @('v0.8.0', 'v0.9.0', 'v1.0.0') -Current 'v1.0.0'
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.InstallRoot = $install.Root
        Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ Version = 'v1.0.0'; Previous = 'v0.9.0' } }
        $run = Invoke-TestSelfUpdate -Context $context
        $run.Result | Should -Be 0
        $run.Printed | Should -BeLike ("*The download matches the SHA-256 GitHub lists*`nDeleted the old launcher version $(Join-Path $install.Versions 'v0.8.0'), as " +
            'Launcher.KeepVersions keeps 2.*Handing over to the launcher v1.1.0*')
        @(Get-ChildItem -LiteralPath $install.Versions | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('v0.9.0', 'v1.0.0', 'v1.1.0')
    }

    It 'deletes no version when the download cannot be reached' {
        $install = Write-TestLauncherInstall -Tags @('v0.8.0', 'v0.9.0', 'v1.0.0') -Current 'v1.0.0'
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.InstallRoot = $install.Root
        Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ Version = 'v1.0.0'; Previous = 'v0.9.0' } }
        $world.DownloadError = Get-TestWebError
        $run = Invoke-TestSelfUpdate -Context $context
        ($null -eq $run.Result) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $install.Versions | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('v0.8.0', 'v0.9.0', 'v1.0.0')
    }

    It 'checks a version an earlier update staged instead of downloading it, then hands over' {
        Copy-Item -LiteralPath $source -Destination (Join-Path $install.Versions 'v1.1.0') -Recurse
        $run = Invoke-TestSelfUpdate -Context $context
        $run.Result | Should -Be 0
        $run.Printed | Should -BeLike "*Checking $(Join-Path $install.Versions 'v1.1.0'), which an earlier update staged, against its manifest...*"
        Should -Invoke Invoke-WebRequest -ModuleName LocalAI -Times 0 -Exactly
        $world.Child.ArgumentList | Should -Be @('update', '-ActivateLauncher', 'v1.1.0')
    }
}

Describe 'Update-LocalAI with -ActivateLauncher' {
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
    }

    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0', 'v1.1.0') -Current 'v1.0.0'
        $currentFile = Join-Path $install.Root 'current'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        # Not this PC's Start menu, whose shortcuts update brings up to date once it made the new version active, nor its ComfyUI or OLLAMA_HOST, which
        # the descriptions of the shortcuts read.
        $shortcutFolder = Join-Path $root 'Start Menu\Programs\Local AI'
        $settings.Shortcuts.Folder = $shortcutFolder
        $settings.ComfyUI.Dir = Join-Path $root 'ComfyUI'
        $settings.Ollama.Url = 'http://127.0.0.1:11434'
        $store = @{}
        $saves = New-Object System.Collections.Generic.List[string]
        $shell = Get-FakeShell -Store $store -Saves $saves
        Mock Get-WScriptShell -ModuleName LocalAI -MockWith { $shell }
        Mock Get-OllamaIcon -ModuleName LocalAI
        # Put the Start Local AI shortcut that an earlier 'local-ai shortcuts' made into Shortcuts.Folder, running $Target, by default the shim of the install.
        $addStart = {
            param([string]$Target = (Join-Path $install.Root 'local-ai.cmd'))
            $null = New-Item -ItemType Directory -Force -Path $shortcutFolder
            $start = Join-Path $shortcutFolder 'Start Local AI.lnk'
            [IO.File]::WriteAllText($start, 'lnk')
            $store[$start] = @{ TargetPath = $Target; Arguments = 'start' }
        }
        Write-LocalAIState -Path $paths.InstallStamp -State @{
            Ollama = @{ Version = '0.40.11' }; Model = @{ Alias = 'local-chat' }; OpenWebUI = @{ Version = '0.12.4'; Python = '3.12.16'; Path = 'C:\uv\bin\open-webui.exe' }
        }
        $digest = 'sha256:' + ('b' * 64)
        Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ LastCheck = @{ CheckedAt = [long]1; Latest = 'v1.1.0'; Digest = $digest; Error = $null } } }
        $context = @{ Verb = 'update'; Paths = $paths; Settings = $settings; RepoRoot = (Join-Path $install.Versions 'v1.1.0'); InstallRoot = $install.Root; Tools = $false
            NoBrowser = $false; ActivateLauncher = 'v1.1.0' }
        $calls = New-Object System.Collections.Generic.List[string]
        $world = @{
            Plan  = @{ Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @('weights a -> b'); Problem = $null; Note = $null }); Tools = @(); ToolDir = 'C:\uv\tools' }
            Yes   = $true
            Smoke = @{ OpenWebUI = $null; Problems = @() }
        }
        # The version current names when each step runs.
        $active = { ([IO.File]::ReadAllText($currentFile)).Trim() }
        Mock Invoke-Native -ModuleName LocalAI -MockWith { throw "Unexpected program $FilePath $($ArgumentList -join ' ')" }
        Mock Set-LocalAIKeepAwake -ModuleName LocalAI
        Mock Update-SessionPath -ModuleName LocalAI
        Mock Assert-OllamaCliUrl -ModuleName LocalAI
        Mock Wait-OllamaServer -ModuleName LocalAI -MockWith {
            $calls.Add('wait')
            [pscustomobject]@{ Version = '0.40.11'; App = $null; Started = $false }
        }
        Mock Get-OllamaAppProcess -ModuleName LocalAI
        Mock Get-LocalAIUpdatePlan -ModuleName LocalAI -MockWith { $world.Plan }
        Mock Confirm-LocalAIAction -ModuleName LocalAI -MockWith {
            $calls.Add("ask $Question at $(& $active)")
            $world.Yes
        }
        Mock Get-LocalAIRunningService -ModuleName LocalAI
        Mock Stop-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add("stop at $(& $active)")
            0
        }
        Mock Get-BusyProcess -ModuleName LocalAI
        Mock Get-OllamaModelBlob -ModuleName LocalAI
        Mock Test-ChatModelSpace -ModuleName LocalAI
        Mock Install-ChatModel -ModuleName LocalAI -MockWith {
            $calls.Add("model at $(& $active)")
            $State['Model'] = @{ Alias = 'local-chat'; Source = 'hf.co/x'; BaseDigest = 'a' * 64; ProjectorDigest = 'b' * 64; ModelfileSha256 = 'c' * 64; Modelfile = 'C:\x\local-chat.Modelfile' }
            $State
        }
        Mock Start-LocalAI -ModuleName LocalAI -MockWith {
            $calls.Add('start')
            0
        }
        Mock Test-LocalAIUpdateSmoke -ModuleName LocalAI -MockWith { $world.Smoke }
        Mock Remove-SupersededAlias -ModuleName LocalAI
    }

    It 'shows the launcher first in the plan, asks once, and points current at the new version before any part changes' {
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*Update plan:`n  Launcher: v1.0.0 -> v1.1.0 ($($settings.Launcher.Repo), $digest)`n  Model: weights a -> b*"
        $run.Printed | Should -BeLike '*The launcher is v1.1.0 now; the parts come next.*'
        @($calls | Where-Object { $_ -notlike 'wait' -and $_ -ne 'start' }) | Should -Be @('ask Update these now? at v1.0.0', 'stop at v1.0.0', 'model at v1.1.0', 'stop at v1.1.0')
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
        $launcher = (Read-LocalAIState -Path $paths.State).Launcher
        $launcher.Version | Should -BeExactly 'v1.1.0'
        $launcher.Previous | Should -BeExactly 'v1.0.0'
        $launcher.LastCheck.Digest | Should -BeExactly $digest
        Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'changes nothing when the answer is no: current, state.json and the parts stay, the new version stays staged, and the exit code is 2' {
        $world.Yes = $false
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Nothing was changed, so the parts above still differ from their pins. The launcher stays at v1.0.0.*'
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.0.0`r`n"
        (Read-LocalAIState -Path $paths.State).Launcher.ContainsKey('Version') | Should -BeFalse
        $calls | Should -Not -Contain 'stop at v1.0.0'
        Should -Invoke Install-ChatModel -ModuleName LocalAI -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $install.Versions 'v1.1.0\local-ai-release.json') | Should -BeTrue
    }

    It 'asks for the launcher alone, and stops nothing, when every part matches its pin' {
        $world.Plan.Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @(); Problem = $null; Note = $null })
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike ("*Every part matches its pin.*Update plan:`n  Launcher: v1.0.0 -> v1.1.0 (*)`nOnly the launcher changes, so what runs keeps running; the next " +
            'start runs the new version.*The launcher is v1.1.0 now, and everything matches its pin.')
        @($calls | Where-Object { $_ -like 'ask*' -or $_ -like 'stop*' }) | Should -Be @('ask Update these now? at v1.0.0')
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
    }

    It 'keeps the launcher as it is when the answer is no for the launcher alone' {
        $world.Plan.Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @(); Problem = $null; Note = $null })
        $world.Yes = $false
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Nothing was changed; the launcher stays at v1.0.0.'
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.0.0`r`n"
    }

    It 'changes only the launcher, without waiting for Ollama, before install has set up the parts' {
        Remove-Item -LiteralPath $paths.InstallStamp
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike ("*Update plan:`n  Launcher: v1.0.0 -> v1.1.0 (*)`ninstall-stamp.json does not record Ollama, Model, OpenWebUI, so update changes only the " +
            "launcher; 'local-ai install' sets up the rest.*The launcher is v1.1.0 now. Run 'local-ai install' to set up the rest.")
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 0 -Exactly
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
    }

    It 'shows no launcher line when that version is active already' {
        [IO.File]::WriteAllText($currentFile, "v1.1.0`r`n")
        & $addStart
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith { 0 }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -Not -BeLike '*Launcher:*'
        (Read-LocalAIState -Path $paths.State).Launcher.ContainsKey('Version') | Should -BeFalse
        Should -Invoke Set-LocalAIShortcut -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'goes back to an older version, as update -Rollback hands over to it, only on yes, and records the newer one as the version before' {
        [IO.File]::WriteAllText($currentFile, "v1.1.0`r`n")
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.ActivateLauncher = 'v1.0.0'
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Printed | Should -BeLike "*Update plan:`n  Launcher: v1.1.0 -> v1.0.0 ($($settings.Launcher.Repo))`n  Model: weights a -> b*"
        @($calls | Where-Object { $_ -like 'ask*' -or $_ -like 'model*' }) | Should -Be @('ask Update these now? at v1.1.0', 'model at v1.0.0')
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.0.0`r`n"
        $launcher = (Read-LocalAIState -Path $paths.State).Launcher
        $launcher.Version | Should -BeExactly 'v1.0.0'
        $launcher.Previous | Should -BeExactly 'v1.1.0'
    }

    It 'keeps the newer version active when the answer is no to going back' {
        [IO.File]::WriteAllText($currentFile, "v1.1.0`r`n")
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.ActivateLauncher = 'v1.0.0'
        $world.Yes = $false
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Nothing was changed, so the parts above still differ from their pins. The launcher stays at v1.1.0.*'
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
        (Read-LocalAIState -Path $paths.State).Launcher.ContainsKey('Version') | Should -BeFalse
    }

    It 'keeps current and state.json as they were when going back stops at <Case>, before any part changed' -ForEach @(
        @{ Case = 'the stop'; Setup = { Mock Stop-LocalAI -ModuleName LocalAI -MockWith { 1 } } }
        @{ Case = 'a busy program'; Setup = {
                $world.Plan.Components = @(@{ Name = 'Files'; Display = 'File tools'; Changes = @('mcpo a -> b'); Problem = $null; Note = $null })
                Mock Get-BusyProcess -ModuleName LocalAI -MockWith { [pscustomobject]@{ Name = 'mcpo'; Id = 77; Path = 'C:\uv\tools\mcpo\Scripts\mcpo.exe' } }
            }
        }
    ) {
        . $Setup
        [IO.File]::WriteAllText($currentFile, "v1.1.0`r`n")
        $context.RepoRoot = Join-Path $install.Versions 'v1.0.0'
        $context.ActivateLauncher = 'v1.0.0'
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike '*Update changed nothing*'
        $run.Printed | Should -Not -BeLike '*The launcher is v1.0.0 now*'
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
        (Read-LocalAIState -Path $paths.State).Launcher.ContainsKey('Version') | Should -BeFalse
        Should -Invoke Install-ChatModel -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'starts again what ran before, and passes the error on, when current cannot be written after the stop' {
        Mock Get-LocalAIRunningService -ModuleName LocalAI -MockWith { 'OpenWebUI' }
        Mock Enable-LauncherVersion -ModuleName LocalAI -MockWith { throw 'Access to the path current is denied.' }
        & $addStart
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith { 0 }
        { Update-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage 'Access to the path current is denied.'
        Should -Invoke Start-LocalAI -ModuleName LocalAI -Times 1 -Exactly
        Should -Invoke Install-ChatModel -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Set-LocalAIShortcut -ModuleName LocalAI -Times 0 -Exactly
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.0.0`r`n"
    }

    It 'gives an install whose Start menu folder holds the shortcuts of an earlier version Update Local AI, for the shim of the install folder' {
        [IO.File]::WriteAllText((Join-Path $install.Root 'local-ai.cmd'), 'shim')
        # The shortcuts an earlier version made: this version's Start, Stop and Status, without Update Local AI.
        $null = Set-LocalAIShortcut -Context @{ Settings = $settings; Paths = $paths; RepoRoot = $context.RepoRoot; InstallRoot = $install.Root; Remove = $false } 6>$null
        $update = Join-Path $shortcutFolder 'Update Local AI.lnk'
        Remove-Item -LiteralPath $update
        $store.Remove($update)
        $saves.Clear()
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeNullOrEmpty
        @($saves) | Should -Be @($update)
        $store[$update].TargetPath | Should -BeExactly (Join-Path $install.Root 'local-ai.cmd')
        $store[$update].WorkingDirectory | Should -BeExactly $install.Root
        $store[$update].Arguments | Should -BeExactly 'update'
        $run.Printed | Should -BeLike ("*Bringing the launcher's Start menu shortcuts up to date...*Created $update.*The Start menu folder $shortcutFolder holds " +
            'Start, Stop, Status and Update Local AI.*The launcher is v1.1.0 now; the parts come next.*')
    }

    It 'counts no warning that the descriptions of the shortcuts silence, as one for ComfyUI.Args, when <Case>' -ForEach @(
        @{ Case = 'parts change'; Setup = {} }
        @{ Case = 'only the launcher changes'; Setup = { $world.Plan.Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @(); Problem = $null; Note = $null }) } }
        @{ Case = 'install has not set up the parts yet'; Setup = { Remove-Item -LiteralPath $paths.InstallStamp } }
    ) {
        . $Setup
        [IO.File]::WriteAllText((Join-Path $install.Root 'local-ai.cmd'), 'shim')
        # ComfyUI's start drops this argument with a warning. The shortcut descriptions plan that start too, and their warning is neither printed nor counted.
        $settings.ComfyUI.Args = @('--enable-manager')
        & $addStart
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeNullOrEmpty
        $run.Printed | Should -Not -BeLike '*warning(s)*'
        $store[(Join-Path $shortcutFolder 'Update Local AI.lnk')].Arguments | Should -BeExactly 'update'
    }

    It 'leaves Start menu shortcuts that run a git clone as they are, without a word' {
        [IO.File]::WriteAllText((Join-Path $install.Root 'local-ai.cmd'), 'shim')
        $clone = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $clone '.git')
        [IO.File]::WriteAllText((Join-Path $clone 'local-ai.cmd'), 'clone')
        # The shortcuts 'local-ai shortcuts' made in the clone.
        $null = Set-LocalAIShortcut -Context @{ Settings = $settings; Paths = $paths; RepoRoot = $clone; InstallRoot = $install.Root; Remove = $false } 6>$null
        $saves.Clear()
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        $run.Warnings | Should -BeNullOrEmpty
        $run.Printed | Should -Not -BeLike '*Start menu shortcuts*'
        $saves.Count | Should -Be 0
        foreach ($verb in 'Start', 'Stop', 'Status', 'Update') {
            $store[(Join-Path $shortcutFolder "$verb Local AI.lnk")].TargetPath | Should -BeExactly (Join-Path $clone 'local-ai.cmd')
        }
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
    }

    It 'brings the shortcuts up to date right after current names the new version, before any part changes' {
        & $addStart
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith {
            $calls.Add("shortcuts at $(& $active)")
            0
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { $_ -notlike 'wait' -and $_ -ne 'start' }) |
            Should -Be @('ask Update these now? at v1.0.0', 'stop at v1.0.0', 'shortcuts at v1.1.0', 'model at v1.1.0', 'stop at v1.1.0')
        Should -Invoke Set-LocalAIShortcut -ModuleName LocalAI -Times 1 -Exactly -ParameterFilter {
            $Context.RepoRoot -eq (Join-Path $install.Versions 'v1.1.0') -and $Context.InstallRoot -eq $install.Root -and -not $Context.Remove
        }
    }

    It 'brings the shortcuts up to date also when <Case>' -ForEach @(
        @{ Case = 'only the launcher changes'; Setup = { $world.Plan.Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @(); Problem = $null; Note = $null }) }
            Next = 'The launcher is v1.1.0 now, and everything matches its pin.' }
        @{ Case = 'install has not set up the parts yet'; Setup = { Remove-Item -LiteralPath $paths.InstallStamp }
            Next = "The launcher is v1.1.0 now. Run 'local-ai install' to set up the rest." }
    ) {
        . $Setup
        & $addStart
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith {
            $calls.Add("shortcuts at $(& $active)")
            0
        }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(0)
        @($calls | Where-Object { $_ -like 'shortcuts*' }) | Should -Be @('shortcuts at v1.1.0')
        $run.Printed | Should -BeLike "*Bringing the launcher's Start menu shortcuts up to date...`n$Next"
    }

    It 'warns, keeps the new version and returns 2 when the shortcuts cannot be brought up to date, when <Case>' -ForEach @(
        @{ Case = 'parts change'; Setup = {}; Last = 'Update finished with 1 warning(s); see above.' }
        @{ Case = 'only the launcher changes'; Setup = { $world.Plan.Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @(); Problem = $null; Note = $null }) }
            Last = 'The launcher is v1.1.0 now, and everything matches its pin.' }
        @{ Case = 'install has not set up the parts yet'; Setup = { Remove-Item -LiteralPath $paths.InstallStamp }
            Last = "The launcher is v1.1.0 now. Run 'local-ai install' to set up the rest." }
    ) {
        . $Setup
        & $addStart
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith { throw 'Access to the path is denied.' }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Warnings | Should -BeExactly "Could not bring the Start menu shortcuts up to date: Access to the path is denied. Run 'local-ai shortcuts' to try again."
        $run.Printed | Should -BeLike "*$Last"
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
    }

    It 'still counts a warning from before the activation once the shortcuts are up to date, when <Case>' -ForEach @(
        @{ Case = 'parts change'; Setup = {}; Shown = 'The plan warns.' }
        @{ Case = 'only the launcher changes'; Setup = { $world.Plan.Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @(); Problem = $null; Note = $null }) }
            Shown = 'The plan warns.' }
        # No plan comes before the activation there, so the warning is one the run was handed, which it does not print again.
        @{ Case = 'install has not set up the parts yet'; Setup = { Remove-Item -LiteralPath $paths.InstallStamp; $context.Warnings = @('An earlier step warned.') }
            Shown = '' }
    ) {
        . $Setup
        & $addStart
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith { 0 }
        Mock Get-LocalAIUpdatePlan -ModuleName LocalAI -MockWith {
            Write-Warning 'The plan warns.'
            $world.Plan
        }
        $run = Invoke-UpdateVerb -Context $context
        Should -Invoke Set-LocalAIShortcut -ModuleName LocalAI -Times 1 -Exactly
        $run.Warnings | Should -BeExactly $Shown
        $run.Code | Should -Be @(2)
    }

    It 'leaves the shortcuts alone when the answer is no, and brings them up to date on the yes of the next update' {
        & $addStart
        Mock Set-LocalAIShortcut -ModuleName LocalAI -MockWith { 0 }
        $world.Yes = $false
        (Invoke-UpdateVerb -Context $context).Code | Should -Be @(2)
        Should -Invoke Set-LocalAIShortcut -ModuleName LocalAI -Times 0 -Exactly
        $world.Yes = $true
        (Invoke-UpdateVerb -Context $context).Code | Should -Be @(0)
        Should -Invoke Set-LocalAIShortcut -ModuleName LocalAI -Times 1 -Exactly
    }

    It 'refuses, changing nothing, when this run is <Case>' -ForEach @(
        @{ Case = 'not the version it should activate'; Setup = { $context.ActivateLauncher = 'v1.0.0' }; Message = 'update -ActivateLauncher v1.0.0 runs only from *v1.0.0, not from *v1.1.0. Nothing was changed.' }
        @{ Case = 'a version folder that does not match its manifest'; Setup = { [IO.File]::WriteAllText((Join-Path $install.Versions 'v1.1.0\src\local-ai.ps1'), 'changed') }
            Message = '*v1.1.0 does not match its manifest local-ai-release.json, so it does not become the active launcher: src/local-ai.ps1 differs from the file the release holds. Nothing was changed.' }
        @{ Case = 'a git checkout'; Setup = { $context.RepoRoot = $repoRoot }; Message = 'update -ActivateLauncher v1.1.0 runs only from *' }
    ) {
        . $Setup
        { Update-LocalAI -Context $context 6>$null } | Should -Throw -ExpectedMessage $Message
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.0.0`r`n"
        Should -Invoke Wait-OllamaServer -ModuleName LocalAI -Times 0 -Exactly
    }

    It "names update -Rollback when the update fails after the launcher changed" {
        $world.Smoke = @{ OpenWebUI = 'Unable to connect to the remote server'; Problems = @() }
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike "*Update failed: *To go back to the launcher v1.0.0, run 'local-ai update -Rollback'."
    }

    It 'counts the warnings of the release check before it as warnings of update' {
        $context.ActivateLauncher = ''
        $context.Warnings = @('Could not check for a newer launcher (offline); it stays at v1.0.0.')
        $world.Plan.Components = @(@{ Name = 'Model'; Display = 'Model'; Changes = @(); Problem = $null; Note = $null })
        $run = Invoke-UpdateVerb -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Everything matches its pin.*'
    }
}

Describe 'Invoke-LauncherRollback' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent

        # Run Invoke-LauncherRollback and return @{ Code; Printed; Warnings }.
        function Invoke-TestRollback([hashtable]$Context) {
            $output = @(Invoke-ModuleFunction 'Invoke-LauncherRollback' @{ Context = $Context } 3>&1 6>&1)
            return @{
                Code     = @($output | Where-Object { $_ -is [int] })
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join "`n"
            }
        }
    }

    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0', 'v1.1.0') -Current 'v1.1.0'
        $currentFile = Join-Path $install.Root 'current'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        Write-LocalAIState -Path $paths.State -State @{
            Launcher = @{ Version = 'v1.1.0'; Previous = 'v1.0.0'; LastCheck = @{ CheckedAt = [long]5; Latest = 'v1.1.0'; Digest = ('sha256:' + ('b' * 64)); Error = $null } }
        }
        $lock = 'Local\LocalAITest-' + [guid]::NewGuid().ToString('N')
        $hold = @{ Mutex = (Enter-LocalAILock -Name $lock); Transcribing = $false }
        $context = @{ Verb = 'update'; Paths = $paths; Settings = $settings; RepoRoot = (Join-Path $install.Versions 'v1.1.0'); InstallRoot = $install.Root; Tools = $false
            Hold = $hold; Rollback = $true }
        $world = @{ Yes = $true; Child = $null; LockFree = $null; Questions = (New-Object System.Collections.Generic.List[string]); ChildCode = 0; Activate = $true
            CurrentAtHandover = $null; LauncherAtHandover = $null }
        Mock Confirm-LocalAIAction -ModuleName LocalAI -MockWith {
            $world.Questions.Add("$Question|$Word")
            $world.Yes
        }
        # The version before: what it finds when it starts, and then it points current back, as its yes does, unless Activate is off.
        Mock Invoke-LauncherChild -ModuleName LocalAI -MockWith {
            $world.Child = @{ Script = $Script; ArgumentList = @($ArgumentList) }
            $world.LockFree = Test-MutexFree -Name $lock
            $world.CurrentAtHandover = [IO.File]::ReadAllText($currentFile)
            $world.LauncherAtHandover = (Read-LocalAIState -Path $paths.State).Launcher
            if ($world.Activate) { [IO.File]::WriteAllText($currentFile, "v1.0.0`r`n") }
            $world.ChildCode
        }
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw "Unexpected request to $Uri" }
        Mock Invoke-WebRequest -ModuleName LocalAI -MockWith { throw "Unexpected download of $Uri" }
    }

    AfterEach {
        Exit-LocalAILock -Mutex $hold.Mutex
    }

    It 'asks for the typed word rollback and hands over to the update of the version before, offline, with current and state.json still as they were' {
        $run = Invoke-TestRollback -Context $context
        $run.Code | Should -Be @(0)
        @($world.Questions) | Should -Be @('Go back to the launcher v1.0.0?|rollback')
        # So that the version before shows 'Launcher: v1.1.0 -> v1.0.0', and only its yes, once its settings loaded, points current back.
        $world.CurrentAtHandover | Should -BeExactly "v1.1.0`r`n"
        $world.LauncherAtHandover.Version | Should -BeExactly 'v1.1.0'
        $world.LauncherAtHandover.Previous | Should -BeExactly 'v1.0.0'
        $world.LauncherAtHandover.LastCheck.Latest | Should -BeExactly 'v1.1.0'
        $world.Child.Script | Should -Be (Join-Path $install.Versions 'v1.0.0\src\local-ai.ps1')
        $world.Child.ArgumentList | Should -Be @('update', '-ActivateLauncher', 'v1.0.0')
        $world.LockFree | Should -BeTrue
        $run.Printed | Should -BeLike ("*Rollback plan:`n  Launcher: v1.1.0 -> v1.0.0, from $(Join-Path $install.Versions 'v1.0.0')*Handing over to the update of v1.0.0 in " +
            "$(Join-Path $install.Versions 'v1.0.0').")
        $run.Warnings | Should -BeLike "Open WebUI may meet data that v1.1.0 has already migrated*the backups in $($paths.Backups) are the fallback."
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'says the launcher stays at this version when the update of the version before changes nothing, so that a rollback can run again' {
        $world.Activate = $false
        $world.ChildCode = 2
        $run = Invoke-TestRollback -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike "*The launcher stays at v1.1.0, and 'local-ai update -Rollback' can still go back to v1.0.0."
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
        $launcher = (Read-LocalAIState -Path $paths.State).Launcher
        $launcher.Version | Should -BeExactly 'v1.1.0'
        $launcher.Previous | Should -BeExactly 'v1.0.0'
    }

    It 'passes -Tools on' {
        $context.Tools = $true
        $null = Invoke-TestRollback -Context $context
        $world.Child.ArgumentList | Should -Be @('update', '-Tools', '-ActivateLauncher', 'v1.0.0')
    }

    It 'changes nothing and returns 2 without the typed word' {
        $world.Yes = $false
        $run = Invoke-TestRollback -Context $context
        $run.Code | Should -Be @(2)
        $run.Printed | Should -BeLike '*Nothing was changed; the launcher stays at v1.1.0.'
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
        (Read-LocalAIState -Path $paths.State).Launcher.Version | Should -BeExactly 'v1.1.0'
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
        ($null -ne $hold.Mutex) | Should -BeTrue
    }

    It 'refuses, asking and changing nothing, when <Case>' -ForEach @(
        @{ Case = 'state.json records no version before'; Setup = { Write-LocalAIState -Path $paths.State -State @{} }
            Message = 'state.json records no launcher version before v1.1.0, so there is nothing to go back to. Nothing was changed.' }
        @{ Case = 'the version before is the active one'; Setup = { Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ Previous = 'v1.1.0' } } }
            Message = 'state.json records no launcher version before v1.1.0, so there is nothing to go back to. Nothing was changed.' }
        @{ Case = 'its folder is gone'; Setup = { Remove-Item -LiteralPath (Join-Path $install.Versions 'v1.0.0') -Recurse -Force }
            Message = 'v1.0.0, the launcher version before v1.1.0, is no longer in *, so there is nothing to go back to. Nothing was changed.' }
        @{ Case = 'its folder does not match its manifest'; Setup = { [IO.File]::WriteAllText((Join-Path $install.Versions 'v1.0.0\local-ai.cmd'), 'changed') }
            Message = ('*v1.0.0 does not match its manifest local-ai-release.json, so update -Rollback does not go back to it: local-ai.cmd differs from the file the ' +
                'release holds. Nothing was changed.') }
    ) {
        . $Setup
        $run = Invoke-TestRollback -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeLike $Message
        [IO.File]::ReadAllText($currentFile) | Should -BeExactly "v1.1.0`r`n"
        Should -Invoke Confirm-LocalAIAction -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-LauncherChild -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'refuses for a git checkout, which keeps no earlier version' {
        $context.RepoRoot = $repoRoot
        $run = Invoke-TestRollback -Context $context
        $run.Code | Should -Be @(1)
        $run.Printed | Should -BeExactly ("update -Rollback goes back to the launcher version that ran before the last update, which only a release install keeps, but this " +
            "launcher runs from $repoRoot. Nothing was changed.")
    }
}

Describe 'Enable-LauncherVersion' {
    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0', 'v1.1.0') -Current 'v1.0.0'
        $state = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))\state.json"
    }

    It 'points current at the tag, then records it and the version before in state.json, keeping the rest' {
        Write-LocalAIState -Path $state -State @{ Services = @{ OpenWebUI = @{ Pid = 1 } }; Launcher = @{ LastCheck = @{ CheckedAt = [long]7; Latest = 'v1.1.0'; Digest = 'd'; Error = $null } } }
        Invoke-ModuleFunction 'Enable-LauncherVersion' @{ InstallRoot = $install.Root; Tag = 'v1.1.0'; StatePath = $state } | Should -BeExactly 'v1.0.0'
        [IO.File]::ReadAllText((Join-Path $install.Root 'current')) | Should -BeExactly "v1.1.0`r`n"
        $written = Read-LocalAIState -Path $state
        $written.Launcher.Version | Should -BeExactly 'v1.1.0'
        $written.Launcher.Previous | Should -BeExactly 'v1.0.0'
        $written.Launcher.LastCheck.CheckedAt | Should -Be 7
        $written.Services.OpenWebUI.Pid | Should -Be 1
    }

    It 'changes nothing when state.json is not valid JSON' {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $state -Parent)
        [IO.File]::WriteAllText($state, '{ broken')
        { Invoke-ModuleFunction 'Enable-LauncherVersion' @{ InstallRoot = $install.Root; Tag = 'v1.1.0'; StatePath = $state } } | Should -Throw -ExpectedMessage '*is not valid JSON*'
        [IO.File]::ReadAllText((Join-Path $install.Root 'current')) | Should -BeExactly "v1.0.0`r`n"
    }

    It 'records no version before when current named none' {
        Remove-Item -LiteralPath (Join-Path $install.Root 'current')
        ($null -eq (Invoke-ModuleFunction 'Enable-LauncherVersion' @{ InstallRoot = $install.Root; Tag = 'v1.1.0'; StatePath = $state })) | Should -BeTrue
        (Read-LocalAIState -Path $state).Launcher.ContainsKey('Previous') | Should -BeFalse
    }

    It 'points current back, and passes the error on, when state.json cannot be written' {
        # Write-LocalAIState's own -State would hide $state in the filter.
        $statePath = $state
        Mock Write-LocalAIState -ModuleName LocalAI -ParameterFilter { $Path -eq $statePath } -MockWith { throw 'There is not enough space on the disk.' }
        { Invoke-ModuleFunction 'Enable-LauncherVersion' @{ InstallRoot = $install.Root; Tag = 'v1.1.0'; StatePath = $state } } |
            Should -Throw -ExpectedMessage 'There is not enough space on the disk.'
        [IO.File]::ReadAllText((Join-Path $install.Root 'current')) | Should -BeExactly "v1.0.0`r`n"
    }
}

Describe 'Get-LauncherStatus' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $now = (New-Object DateTime -ArgumentList 2026, 11, 4, 12, 0, 0, ([DateTimeKind]::Utc)).Ticks

        # Return Get-LauncherStatus for the launcher in $RepoRoot of the test install with state.json $State and $Settings.
        function Get-TestStatus([string]$RepoRoot, [hashtable]$State = @{}, [hashtable]$Settings) {
            $arguments = @{ RepoRoot = $RepoRoot; InstallRoot = $install.Root; State = $State; Settings = $Settings; DefaultRepo = 'Ochsyp/local-ai-launcher'; NowTicks = $now }
            return Invoke-ModuleFunction 'Get-LauncherStatus' $arguments
        }

        # Return the texts of the lines of $Status at $Level.
        function Select-TestLine([hashtable]$Status, [string]$Level) { @($Status.Lines | Where-Object { $_.level -eq $Level } | ForEach-Object { $_.text }) }

        # Return a state.json table whose Launcher records the previous version $Previous and a check $Hours hours before now that found $Latest or failed with $Failure.
        function Get-TestState([string]$Previous = 'v1.0.0', [double]$Hours = 1, [string]$Latest = 'v1.2.0', [string]$Failure = '') {
            $check = @{ CheckedAt = $now - [long]([TimeSpan]::FromHours($Hours).Ticks); Latest = $(if ($Latest) { $Latest } else { $null }); Digest = 'sha256:' + ('b' * 64)
                Error = $(if ($Failure) { $Failure } else { $null }) }
            return @{ Launcher = @{ Version = 'v1.1.0'; Previous = $Previous; LastCheck = $check } }
        }

        # Return the time $Hours hours before now as status shows it.
        function Get-TestShown([double]$Hours) {
            (New-Object DateTime -ArgumentList ($now - [long]([TimeSpan]::FromHours($Hours).Ticks)), ([DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        }
    }

    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0', 'v1.1.0') -Current 'v1.1.0'
        $active = Join-Path $install.Versions 'v1.1.0'
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith { throw 'status asked the network' }
        Mock Invoke-WebRequest -ModuleName LocalAI -MockWith { throw 'status asked the network' }
        Mock Write-LocalAIState -ModuleName LocalAI -MockWith { throw 'status wrote a state file' }
    }

    It 'reports a release install, the version kept for a rollback, its manifest and a newer release the last check found, as facts and for -Json' {
        $status = Get-TestStatus -RepoRoot $active -State (Get-TestState) -Settings $settings
        $status.Data.kind | Should -Be 'release'
        $status.Data.latest | Should -BeExactly 'v1.2.0'
        $status.Data.updateAvailable | Should -BeTrue
        $status.Data.checkedAt | Should -BeExactly '2026-11-04T11:00:00Z'
        ($null -eq $status.Data.checkError) | Should -BeTrue
        Select-TestLine $status 'fact' | Should -Be @("Release install in $($install.Root), where current names v1.1.0.", "Every file of v1.1.0 in $($install.Versions) matches its manifest.",
            "v1.0.0, the version before, stays in $($install.Versions) for 'local-ai update -Rollback'.")
        Select-TestLine $status 'info' | Should -Be @("The launcher v1.2.0 is out, checked $(Get-TestShown 1); 'local-ai update' installs it.")
        Select-TestLine $status 'degraded' | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -ModuleName LocalAI -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -ModuleName LocalAI -Times 0 -Exactly
    }

    It 'says <Case>' -ForEach @(
        @{ Case = 'the latest release is this one, from a recent check'; Hours = 2; Latest = 'v1.1.0'; Level = 'fact'; Text = 'v1.1.0 is the latest release, checked {0}.' }
        @{ Case = "'last checked' for a check older than 7 days that found nothing newer"; Hours = 200; Latest = 'v1.1.0'; Level = 'info'
            Text = "v1.1.0 was the latest release when last checked {0}; 'local-ai update' checks again." }
        @{ Case = "'last checked' for an old check that found a newer release"; Hours = 200; Latest = 'v1.2.0'; Level = 'info'; Text = "The launcher v1.2.0 is out, last checked {0}; 'local-ai update' installs it." }
    ) {
        $status = Get-TestStatus -RepoRoot $active -State (Get-TestState -Hours $Hours -Latest $Latest) -Settings $settings
        Select-TestLine $status $Level | Should -Contain ($Text -f (Get-TestShown $Hours))
        $status.Data.updateAvailable | Should -Be ($Latest -eq 'v1.2.0')
    }

    It 'says why the last check failed' {
        $status = Get-TestStatus -RepoRoot $active -State (Get-TestState -Latest '' -Failure 'Unable to connect to the remote server') -Settings $settings
        $status.Data.checkError | Should -BeExactly 'Unable to connect to the remote server'
        ($null -eq $status.Data.latest) | Should -BeTrue
        Select-TestLine $status 'info' | Should -Contain "The last check for a newer launcher, on $(Get-TestShown 1), failed: Unable to connect to the remote server"
    }

    It 'says no check has run yet, and that none keeps a version for a rollback' {
        $status = Get-TestStatus -RepoRoot $active -State @{} -Settings $settings
        ($null -eq $status.Data.checkedAt) | Should -BeTrue
        Select-TestLine $status 'info' | Should -Be @("No earlier version is kept in $($install.Versions), so 'local-ai update -Rollback' has nothing to go back to.",
            "No check for a newer launcher has run yet; 'local-ai update' checks.")
    }

    It 'is degraded when the active folder differs from its manifest' {
        [IO.File]::WriteAllText((Join-Path $active 'src\local-ai.ps1'), 'changed')
        [IO.File]::WriteAllText((Join-Path $active 'notes.txt'), 'mine')
        $status = Get-TestStatus -RepoRoot $active -State (Get-TestState) -Settings $settings
        Select-TestLine $status 'degraded' | Should -Be @(("$active does not match its manifest local-ai-release.json: src/local-ai.ps1 differs from the file the release holds; notes.txt is " +
                'not in the manifest. A release folder never changes after install; to put it back, move the folder aside, then run install.ps1 -Tag v1.1.0.'))
    }

    It 'is degraded when current names no version' {
        Remove-Item -LiteralPath (Join-Path $install.Root 'current')
        $status = Get-TestStatus -RepoRoot $active -State (Get-TestState) -Settings $settings
        Select-TestLine $status 'degraded' | Should -Be @(("The file current in $($install.Root) names no launcher version, so its local-ai.cmd and the Start menu shortcuts cannot " +
                'start the launcher. Run install.ps1 again.'))
    }

    It 'notes a run of another version than current names' {
        $status = Get-TestStatus -RepoRoot (Join-Path $install.Versions 'v1.0.0') -State (Get-TestState -Previous '') -Settings $settings
        Select-TestLine $status 'info' | Should -Contain ("This run is v1.0.0 from $(Join-Path $install.Versions 'v1.0.0'), but current names v1.1.0, which local-ai.cmd in " +
            "$($install.Root) and the Start menu shortcuts run.")
    }

    It 'names Launcher.Repo when it is not the default, and Launcher.CheckForUpdates when it is off' {
        $settings.Launcher.Repo = 'other-owner/fork'
        $settings.Launcher.CheckForUpdates = $false
        $status = Get-TestStatus -RepoRoot $active -State (Get-TestState) -Settings $settings
        Select-TestLine $status 'info' | Should -Contain ('Launcher.Repo names other-owner/fork, not Ochsyp/local-ai-launcher, so update installs the releases of other-owner/fork: ' +
            'settings.psd1 trusts whoever publishes them with the code the launcher runs.')
        Select-TestLine $status 'info' | Should -Contain 'Launcher.CheckForUpdates is off, so start does not check for a newer launcher; update still does.'
        $settings.Launcher.Repo = 'OCHSYP/Local-AI-Launcher'
        @(Select-TestLine (Get-TestStatus -RepoRoot $active -State (Get-TestState) -Settings $settings) 'info' | Where-Object { $_ -like 'Launcher.Repo*' }) | Should -BeNullOrEmpty
    }

    It "reports a git checkout as such, and a folder of another kind, with nothing to check" {
        $git = Get-TestStatus -RepoRoot $repoRoot -State (Get-TestState) -Settings $settings
        $git.Data.kind | Should -Be 'git'
        ($null -eq $git.Data.latest) | Should -BeTrue
        $git.Data.updateAvailable | Should -BeFalse
        @($git.Lines | ForEach-Object { "$($_.level): $($_.text)" }) | Should -Be @("fact: This is a git checkout, so update leaves the launcher's own code to git ('git pull' on main).")
        $folder = Write-TestReleaseFolder -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\local-ai-launcher-1.0.0')) -Tag 'v1.0.0'
        $other = Get-TestStatus -RepoRoot $folder -State (Get-TestState) -Settings $settings
        $other.Data.kind | Should -Be 'folder'
        Select-TestLine $other 'info' | Should -Be @(("$folder is no release install and no git checkout, so update leaves the launcher's own code alone; install.ps1 of a release " +
                'installs a launcher that updates itself.'))
    }
}

Describe 'Invoke-LauncherPassiveCheck' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $now = (New-Object DateTime -ArgumentList 2026, 11, 4, 12, 0, 0, ([DateTimeKind]::Utc)).Ticks

        # Run Invoke-LauncherPassiveCheck for $context at $now and return @{ Printed; Returned; Other } with the host text joined, what it returned and
        # anything else it wrote.
        function Invoke-TestPassiveCheck {
            $output = @(Invoke-ModuleFunction 'Invoke-LauncherPassiveCheck' @{ Context = $context; NowTicks = $now } 3>&1 6>&1)
            return @{
                Printed  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
                Returned = @($output | Where-Object { $_ -is [bool] })
                Other    = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [bool] })
            }
        }
    }

    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = Get-LocalAIPaths -Root $root
        $settings = Get-LocalAISettings -DefaultsPath (Join-Path $repoRoot 'config\defaults.psd1')
        $context = @{ Verb = 'start'; Paths = $paths; Settings = $settings; RepoRoot = (Join-Path $install.Versions 'v1.0.0'); InstallRoot = $install.Root }
        $world = @{ Release = (Get-TestReleaseObject -Tag 'v1.1.0'); Error = $null }
        $seen = New-Object System.Collections.Generic.List[hashtable]
        Mock Invoke-RestMethod -ModuleName LocalAI -MockWith {
            $seen.Add(@{ Uri = $Uri; TimeoutSec = $TimeoutSec })
            if ($world.Error) { throw $world.Error }
            $world.Release
        }
    }

    It 'asks GitHub with a 5 s timeout, records the answer and says in one line that a newer launcher is out, naming the update shortcut' {
        $run = Invoke-TestPassiveCheck
        $run.Other | Should -BeNullOrEmpty
        $run.Returned | Should -Be @($true)
        $run.Printed | Should -BeExactly "The launcher v1.1.0 is out, and this one is v1.0.0; 'local-ai update' or the Start menu shortcut 'Update Local AI' installs it."
        $seen.Count | Should -Be 1
        $seen[0].Uri | Should -BeExactly "https://api.github.com/repos/$($settings.Launcher.Repo)/releases/latest"
        $seen[0].TimeoutSec | Should -Be 5
        $check = (Read-LocalAIState -Path $paths.State).Launcher.LastCheck
        $check.CheckedAt | Should -Be $now
        $check.Latest | Should -BeExactly 'v1.1.0'
        $check.Digest | Should -BeExactly $world.Release.assets[0].digest
        ($null -eq $check.Error) | Should -BeTrue
    }

    It 'prints nothing when this is the latest release' {
        $world.Release = Get-TestReleaseObject -Tag 'v1.0.0'
        $run = Invoke-TestPassiveCheck
        $run.Printed | Should -BeNullOrEmpty
        $run.Returned | Should -Be @($false)
        (Read-LocalAIState -Path $paths.State).Launcher.LastCheck.Latest | Should -BeExactly 'v1.0.0'
    }

    It 'asks at most once per Launcher.CheckIntervalHours' {
        Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ LastCheck = @{ CheckedAt = ($now - [TimeSpan]::FromHours(23).Ticks); Latest = 'v1.0.0'; Digest = ''; Error = $null } } }
        $null = Invoke-TestPassiveCheck
        $seen.Count | Should -Be 0
        $settings.Launcher.CheckIntervalHours = 12
        $null = Invoke-TestPassiveCheck
        $seen.Count | Should -Be 1
    }

    It 'says nothing and returns $false between checks, also while the last check found a newer launcher, and says it again at the next check' {
        Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ LastCheck = @{ CheckedAt = ($now - [TimeSpan]::FromHours(23).Ticks); Latest = 'v1.1.0'; Digest = ''; Error = $null } } }
        $run = Invoke-TestPassiveCheck
        $run.Printed | Should -BeNullOrEmpty
        $run.Returned | Should -Be @($false)
        $seen.Count | Should -Be 0
        $settings.Launcher.CheckIntervalHours = 12
        $run = Invoke-TestPassiveCheck
        $run.Printed | Should -BeLike 'The launcher v1.1.0 is out, *'
        $run.Returned | Should -Be @($true)
    }

    It 'asks again when the last check lies in the future, as after the clock was set back' {
        Write-LocalAIState -Path $paths.State -State @{ Launcher = @{ LastCheck = @{ CheckedAt = ($now + [TimeSpan]::FromHours(5).Ticks); Latest = 'v1.0.0'; Digest = ''; Error = $null } } }
        $null = Invoke-TestPassiveCheck
        $seen.Count | Should -Be 1
    }

    It 'asks nothing and writes nothing for <Case>' -ForEach @(
        @{ Case = 'Launcher.CheckForUpdates off'; Setup = { $settings.Launcher.CheckForUpdates = $false } }
        @{ Case = 'a git checkout'; Setup = { $context.RepoRoot = $repoRoot } }
        @{ Case = 'a launcher in another folder'; Setup = { $context.RepoRoot = Write-TestReleaseFolder -Path (Join-Path $root 'Downloads\local-ai-launcher-1.0.0') -Tag 'v1.0.0' } }
    ) {
        . $Setup
        $run = Invoke-TestPassiveCheck
        $run.Printed | Should -BeNullOrEmpty
        $run.Returned | Should -Be @($false)
        $seen.Count | Should -Be 0
        Test-Path -LiteralPath $paths.State | Should -BeFalse
    }

    It 'records why the check failed and prints nothing, for <Case>' -ForEach @(
        @{ Case = 'no network'; Setup = { $world.Error = Get-TestWebError }; Failure = 'Unable to connect to the remote server' }
        @{ Case = 'a release the launcher would refuse'; Setup = { $world.Release = Get-TestReleaseObject -Tag 'v1.1.0' -Fields @{ immutable = $false } }; Failure = 'The release v1.1.0 is not immutable*' }
    ) {
        . $Setup
        $run = Invoke-TestPassiveCheck
        $run.Printed | Should -BeNullOrEmpty
        $run.Returned | Should -Be @($false)
        $run.Other | Should -BeNullOrEmpty
        $check = (Read-LocalAIState -Path $paths.State).Launcher.LastCheck
        $check.Error | Should -BeLike $Failure
        ($null -eq $check.Latest) | Should -BeTrue
    }

    It 'never throws, also when state.json is not valid JSON, and then returns $false' {
        $null = New-Item -ItemType Directory -Force -Path $paths.Root
        [IO.File]::WriteAllText($paths.State, '{ broken')
        (Invoke-TestPassiveCheck).Returned | Should -Be @($false)
        [IO.File]::ReadAllText($paths.State) | Should -BeExactly '{ broken'
    }
}

Describe 'New-LauncherCleanupCommand and Start-LauncherCleanup' {
    BeforeEach {
        $install = Write-TestLauncherInstall -Tags @('v1.0.0') -Current 'v1.0.0' -Shim
        $log = Join-Path $TestDrive 'temp\local-ai-uninstall-cleanup.log'
        $command = Invoke-ModuleFunction 'New-LauncherCleanupCommand' @{ InstallRoot = $install.Root; LogPath = $log; TempPath = 'C:\Users\User\AppData\Local\Temp\'
            WaitFor = @(@{ Id = 4321; StartTicks = 638000000000000000 }, @{ Id = 99; StartTicks = 5 }); CurrentTicks = 639000000000000007 }
    }

    It 'runs hidden Windows PowerShell on the script, passed as -EncodedCommand and never from a file, in the temp folder' {
        $command.FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $command.WorkingDirectory | Should -BeExactly 'C:\Users\User\AppData\Local\Temp\'
        $command.ArgumentList | Should -Match '\A-NoLogo -NoProfile -NonInteractive -EncodedCommand [A-Za-z0-9+/]+={0,2}\z'
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($command.ArgumentList -split ' ')[-1])) | Should -BeExactly $command.Script
    }

    It 'deletes exactly the install folder, once those processes have exited, within 15 minutes, and notes the outcome in its log' {
        $script = $command.Script
        $script | Should -BeLike "*`$root = '$($install.Root)'*"
        $script | Should -BeLike "*`$log = '$log'*"
        $script | Should -BeLike '*$waits = @(@{ Id = 4321; Ticks = 638000000000000000 }, @{ Id = 99; Ticks = 5 })*'
        $script | Should -Match '\$written = 639000000000000007\r?\n'
        $script | Should -BeLike '*AddMinutes(15)*WaitForExit*'
        # Square brackets would make a wildcard pattern, so the type names are left out. A current written after uninstall, as install.ps1 writes it when
        # it sets the folder up again, keeps the folder.
        $script | Should -BeLike ("*ReparsePoint*Combine(`$root, 'current')*Combine(`$root, 'versions')*while (`$true)*::GetLastWriteTimeUtc(*Combine(`$root, " +
            "'current')).Ticks -ne `$written*it was set up again after uninstall.*exit 0*::Move(`$root, `$aside)*::Delete(`$aside, `$true)*")
        # Once the folder was moved aside, only that copy goes, and the log says so when the folder was set up again meanwhile.
        $script | Should -BeLike '*::Delete($aside, $true)*::Exists($root)*was set up again meanwhile and stays.*Deleted $root.*'
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        # The only paths it names are the install folder and its log.
        @([regex]::Matches($script, "'[A-Za-z]:\\[^']*'") | ForEach-Object { $_.Value } | Select-Object -Unique) | Should -Be @("'$($install.Root)'", "'$log'")
    }

    It 'quotes paths with <Case> for the script, which keeps them whole' -ForEach @(
        @{ Case = 'a single quote'; Name = "O'Brien" }
        @{ Case = 'a typographic single quote, which PowerShell also reads as one'; Name = "O$([char]0x2019)Brien" }
    ) {
        $quoted = Join-Path $TestDrive "$Name\Programs\local-ai-launcher"
        $quotedLog = Join-Path $TestDrive "$Name\Temp\local-ai-uninstall-cleanup.log"
        $script = (Invoke-ModuleFunction 'New-LauncherCleanupCommand' @{ InstallRoot = $quoted; LogPath = $quotedLog; CurrentTicks = 1 }).Script
        $tokens = $null
        $errors = $null
        $parsed = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $strings = @($parsed.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
        $strings | Should -Contain $quoted
        $strings | Should -Contain $quotedLog
    }

    It 'keeps the folder when install.ps1 sets it up again while a window still works in it, so that the script retries the move' {
        $currentFile = Join-Path $install.Root 'current'
        $runLog = Join-Path $TestDrive 'held\local-ai-uninstall-cleanup.log'
        $null = New-Item -ItemType Directory -Path (Split-Path $runLog -Parent)
        $built = Invoke-ModuleFunction 'New-LauncherCleanupCommand' @{ InstallRoot = $install.Root; LogPath = $runLog; TempPath = $TestDrive
            CurrentTicks = [IO.File]::GetLastWriteTimeUtc($currentFile).Ticks }
        # A process whose working folder is the install folder keeps it from being moved, as a window that ran uninstall there does.
        $holder = Start-Process -FilePath $built.FilePath -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 20' `
            -WorkingDirectory $install.Root -WindowStyle Hidden -PassThru
        $cleanup = $null
        try {
            $cleanup = Start-Process -FilePath $built.FilePath -ArgumentList $built.ArgumentList -WorkingDirectory $built.WorkingDirectory -WindowStyle Hidden -PassThru
            # Read now, so the exit code stays readable once the process has exited.
            $null = $cleanup.Handle
            Start-Sleep -Seconds 2
            # As install.ps1 writes current when it sets the folder up again.
            [IO.File]::WriteAllText($currentFile, "v1.0.0`r`n")
            [IO.File]::SetLastWriteTimeUtc($currentFile, [DateTime]::UtcNow.AddMinutes(1))
            $cleanup.WaitForExit(40000) | Should -BeTrue
            $cleanup.ExitCode | Should -Be 0
        } finally {
            if (-not $holder.HasExited) { $holder.Kill() }
            if ($cleanup -and -not $cleanup.HasExited) { $cleanup.Kill() }
        }
        Test-Path -LiteralPath $currentFile | Should -BeTrue
        [IO.File]::ReadAllText($runLog) | Should -BeLike "*Did not delete $($install.Root), as it was set up again after uninstall.*"
    }

    It "refuses any folder but the launcher's install folder, such as its data folder" {
        { Invoke-ModuleFunction 'New-LauncherCleanupCommand' @{ InstallRoot = (Join-Path $install.LocalAppData 'local-ai'); LogPath = $log; CurrentTicks = 1 } } |
            Should -Throw -ExpectedMessage '*local-ai is no install folder of the launcher, so uninstall does not delete it.'
    }

    It 'starts that process hidden, waiting for the processes of this window, with its log in the temp folder' {
        Mock Get-LauncherConsoleProcess -ModuleName LocalAI -MockWith { @{ Id = 4321; StartTicks = 1 }; @{ Id = 4320; StartTicks = 2 } }
        $started = New-Object System.Collections.Generic.List[hashtable]
        Mock Start-Process -ModuleName LocalAI -MockWith {
            $started.Add(@{ FilePath = $FilePath; ArgumentList = [string]$ArgumentList; WorkingDirectory = $WorkingDirectory; WindowStyle = [string]$WindowStyle; Wait = [bool]$Wait })
        }
        $logPath = Invoke-ModuleFunction 'Start-LauncherCleanup' @{ InstallRoot = $install.Root }
        $logPath | Should -Be ([IO.Path]::Combine([IO.Path]::GetTempPath(), 'local-ai-uninstall-cleanup.log'))
        $started.Count | Should -Be 1
        $started[0].WindowStyle | Should -Be 'Hidden'
        $started[0].Wait | Should -BeFalse
        $started[0].WorkingDirectory | Should -Be ([IO.Path]::GetTempPath())
        $script = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($started[0].ArgumentList -split ' ')[-1]))
        $script | Should -BeLike '*$waits = @(@{ Id = 4321; Ticks = 1 }, @{ Id = 4320; Ticks = 2 })*'
        $script | Should -BeLike "*`$log = '$logPath'*"
        $script | Should -Match ('\$written = ' + [IO.File]::GetLastWriteTimeUtc((Join-Path $install.Root 'current')).Ticks + '\r?\n')
        Test-Path -LiteralPath (Join-Path $install.Root 'current') | Should -BeTrue
    }

    It 'names this process, and the cmd.exe that started it when there is one, for the removal to wait for' {
        $processes = @(Invoke-ModuleFunction 'Get-LauncherConsoleProcess')
        $processes[0].Id | Should -Be $PID
        $processes[0].StartTicks | Should -Be ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
        $processes.Count | Should -BeLessOrEqual 2
        foreach ($other in @($processes | Select-Object -Skip 1)) { (Get-Process -Id $other.Id).ProcessName | Should -Be 'cmd' }
    }
}

Describe 'The user Path in the registry' {
    BeforeEach {
        $entry = Join-Path $env:LOCALAPPDATA 'Programs\local-ai-launcher'
        $key = Get-TestEnvironmentKey -Value '%USERPROFILE%\bin;C:\Tools'
        Mock Get-LauncherEnvironmentKey -ModuleName LocalAI -MockWith { $key }
    }

    It 'adds the folder at the end, reading the Path unexpanded and keeping REG_EXPAND_SZ' {
        Invoke-ModuleFunction 'Add-LauncherUserPath' @{ Entry = $entry } | Should -BeTrue
        $key.Values['Path'] | Should -BeExactly "%USERPROFILE%\bin;C:\Tools;$entry"
        $key.Kinds['Path'] | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.Options | Should -Be ([Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $key.Disposed | Should -Be 1
    }

    It 'keeps a REG_SZ Path a REG_SZ, and adds no second separator after a trailing one' {
        $key = Get-TestEnvironmentKey -Value 'C:\Tools;' -Kind ([Microsoft.Win32.RegistryValueKind]::String)
        Invoke-ModuleFunction 'Add-LauncherUserPath' @{ Entry = $entry } | Should -BeTrue
        $key.Values['Path'] | Should -BeExactly "C:\Tools;$entry"
        $key.Kinds['Path'] | Should -Be ([Microsoft.Win32.RegistryValueKind]::String)
    }

    It 'creates a Path as REG_EXPAND_SZ when there is none' {
        $key = Get-TestEnvironmentKey -Value $null
        Invoke-ModuleFunction 'Add-LauncherUserPath' @{ Entry = $entry } | Should -BeTrue
        $key.Values['Path'] | Should -BeExactly $entry
        $key.Kinds['Path'] | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
    }

    It 'adds no second entry for the folder when the Path names it <Case>' -ForEach @(
        @{ Case = 'in other case'; Make = { "C:\Tools;$($entry.ToUpperInvariant())" } }
        @{ Case = 'with a trailing backslash'; Make = { "$entry\;C:\Tools" } }
        @{ Case = 'through %LOCALAPPDATA%'; Make = { 'C:\Tools;%LOCALAPPDATA%\Programs\local-ai-launcher' } }
    ) {
        $key = Get-TestEnvironmentKey -Value (& $Make)
        Invoke-ModuleFunction 'Add-LauncherUserPath' @{ Entry = $entry } | Should -BeFalse
        $key.Writes.Count | Should -Be 0
        Invoke-ModuleFunction 'Test-LauncherUserPath' @{ Entry = $entry } | Should -BeTrue
    }

    It 'removes only the entries that name the folder, keeping the others and the kind' {
        $key = Get-TestEnvironmentKey -Value "%USERPROFILE%\bin;$entry;$entry-old;$($entry.ToLowerInvariant())\;C:\Tools" -Kind ([Microsoft.Win32.RegistryValueKind]::String)
        Invoke-ModuleFunction 'Remove-LauncherUserPath' @{ Entry = $entry } | Should -BeTrue
        $key.Values['Path'] | Should -BeExactly "%USERPROFILE%\bin;$entry-old;C:\Tools"
        $key.Kinds['Path'] | Should -Be ([Microsoft.Win32.RegistryValueKind]::String)
        $key.Disposed | Should -Be 1
    }

    It 'deletes a Path that names nothing else, and writes nothing when no entry names the folder' {
        $key = Get-TestEnvironmentKey -Value "$entry\"
        Invoke-ModuleFunction 'Remove-LauncherUserPath' @{ Entry = $entry } | Should -BeTrue
        $key.Values.ContainsKey('Path') | Should -BeFalse
        @($key.Writes) | Should -Be @('delete Path')
        $key = Get-TestEnvironmentKey -Value 'C:\Tools'
        Invoke-ModuleFunction 'Remove-LauncherUserPath' @{ Entry = $entry } | Should -BeFalse
        $key.Writes.Count | Should -Be 0
        Invoke-ModuleFunction 'Test-LauncherUserPath' @{ Entry = $entry } | Should -BeFalse
    }

    It 'leaves a Path that holds no text alone' {
        $key = Get-TestEnvironmentKey -Value 5 -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)
        { Invoke-ModuleFunction 'Add-LauncherUserPath' @{ Entry = $entry } } | Should -Throw -ExpectedMessage "The user's Path in HKCU\Environment is a DWord value, not text, so it is left as it is."
        { Invoke-ModuleFunction 'Remove-LauncherUserPath' @{ Entry = $entry } } | Should -Throw -ExpectedMessage "*is a DWord value, not text*"
        $key.Writes.Count | Should -Be 0
    }
}

Describe 'Invoke-LauncherChild' {
    It 'runs local-ai.ps1 of the other version in Windows PowerShell with RemoteSigned on this console, waits for it and returns its exit code' {
        $seen = @{}
        Mock Start-Process -ModuleName LocalAI -MockWith {
            $process = [pscustomobject]@{ Handle = [IntPtr]1; ExitCode = 2; Waited = $false }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $this.Waited = $true }
            $seen.FilePath = $FilePath
            $seen.ArgumentList = [string]$ArgumentList
            $seen.NoNewWindow = [bool]$NoNewWindow
            $seen.PassThru = [bool]$PassThru
            $seen.Wait = [bool]$Wait
            $seen.Process = $process
            $seen.ModulePath = $env:PSModulePath
            $process
        }
        $script = 'C:\Users\User Name\AppData\Local\Programs\local-ai-launcher\versions\v1.1.0\src\local-ai.ps1'
        $savedModulePath = $env:PSModulePath
        try {
            # As PowerShell 7 hands it on: Windows PowerShell must not inherit it, and this process keeps it.
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules;' + $savedModulePath
            Invoke-ModuleFunction 'Invoke-LauncherChild' @{ Script = $script; ArgumentList = @('update', '-Tools', '-ActivateLauncher', 'v1.1.0') } | Should -Be 2
            $seen.ModulePath | Should -BeNullOrEmpty
            $env:PSModulePath | Should -BeExactly ('C:\Program Files\PowerShell\7\Modules;' + $savedModulePath)
        } finally {
            $env:PSModulePath = $savedModulePath
        }
        $seen.FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $seen.ArgumentList | Should -BeExactly "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File `"$script`" update -Tools -ActivateLauncher v1.1.0"
        $seen.NoNewWindow | Should -BeTrue
        $seen.PassThru | Should -BeTrue
        $seen.Wait | Should -BeFalse
        $seen.Process.Waited | Should -BeTrue
    }
}

Describe 'local-ai.ps1' {
    BeforeAll {
        $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\local-ai.ps1'
        $command = Get-Command -Name $script
    }

    It 'takes -Rollback and the hidden -ActivateLauncher <tag> of the contract between launcher versions' {
        $command.Parameters['Rollback'].SwitchParameter | Should -BeTrue
        $activate = $command.Parameters['ActivateLauncher']
        $activate.ParameterType | Should -Be ([string])
        @($activate.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.DontShow }).Count | Should -Be 1
    }

    It 'binds only the verb by position, so a stray argument fails before anything runs' {
        { & $script update stray } | Should -Throw -ExpectedMessage "*cannot be found that accepts argument 'stray'*"
        { & $script update -ActivateLauncher } | Should -Throw -ExpectedMessage "*Missing an argument for parameter 'ActivateLauncher'*"
    }
}

Describe 'install.ps1' {
    BeforeAll {
        $installPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\install.ps1'
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\LocalAI.psm1'
        $tokens = $null
        $parseErrors = $null
        $installAst = [Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$tokens, [ref]$parseErrors)
        $installFunctions = @($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
        # Its functions, the copied block among them, defined here, so that the tests can call and mock them.
        foreach ($function in $installFunctions) { . ([scriptblock]::Create($function.Extent.Text)) }

        # Return the lines of the file $Path from '# BEGIN LAUNCHER RELEASE FUNCTIONS' to '# END LAUNCHER RELEASE FUNCTIONS', which it must hold once each.
        function Get-TestReleaseBlock([string]$Path) {
            $lines = [IO.File]::ReadAllLines($Path)
            $begin = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -ceq '# BEGIN LAUNCHER RELEASE FUNCTIONS') { $i } })
            $end = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -ceq '# END LAUNCHER RELEASE FUNCTIONS') { $i } })
            $begin.Count | Should -Be 1 -Because "$Path holds the BEGIN line once"
            $end.Count | Should -Be 1 -Because "$Path holds the END line once"
            return , $lines[$begin[0]..$end[0]]
        }
    }

    It 'holds a verbatim copy of the release functions of src\LocalAI.psm1' {
        $module = Get-TestReleaseBlock $modulePath
        $copy = Get-TestReleaseBlock $installPath
        $module.Count | Should -BeGreaterThan 100
        ($copy -join "`n") | Should -BeExactly ($module -join "`n")
    }

    It 'never calls exit, never reads its own path, and runs as one script block called with the arguments the file got' {
        $parseErrors.Count | Should -Be 0
        @($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] }, $true)).Count | Should -Be 0
        $own = @($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and
                    @('PSScriptRoot', 'PSCommandPath', 'MyInvocation') -contains $node.VariablePath.UserPath }, $true))
        $own.Count | Should -Be 0
        # So under iex its functions and variables stay inside that block, and a run as a file passes its parameters on.
        $installAst.ParamBlock | Should -BeNullOrEmpty
        $statements = @($installAst.EndBlock.Statements)
        $statements.Count | Should -Be 1
        $command = $statements[0].PipelineElements[0]
        $command.InvocationOperator | Should -Be ([Management.Automation.Language.TokenKind]::Ampersand)
        $command.CommandElements[0] | Should -BeOfType ([Management.Automation.Language.ScriptBlockExpressionAst])
        $command.CommandElements[1].Splatted | Should -BeTrue
        $command.CommandElements[1].VariablePath.UserPath | Should -BeExactly 'args'
    }

    It 'calls only its own functions and cmdlets of Windows PowerShell, and uses no script or global variable, as it runs without the module' {
        $own = @($installFunctions | ForEach-Object { $_.Name })
        $calls = @($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ } | Select-Object -Unique)
        $calls.Count | Should -BeGreaterThan 20
        foreach ($name in $calls) {
            if ($own -ccontains $name) { continue }
            # Windows PowerShell's own modules, where some commands, such as Get-FileHash, are functions.
            $builtin = @(Get-Command -Name $name -Module 'Microsoft.PowerShell.*' -CommandType Cmdlet, Function -ErrorAction SilentlyContinue)
            $builtin | Should -Not -BeNullOrEmpty -Because "install.ps1 calls $name, which is neither its own function nor a command of Windows PowerShell"
        }
        $scoped = @($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and
                    ($node.VariablePath.IsScript -or $node.VariablePath.IsGlobal) }, $true) | ForEach-Object { $_.Extent.Text })
        $scoped | Should -BeNullOrEmpty
    }

    It 'runs through the shim, and names as the next step, only verbs that the release contract in CONTRIBUTING.md keeps' {
        $shimCalls = @($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and
                    $node.CommandElements[0] -is [Management.Automation.Language.VariableExpressionAst] -and $node.CommandElements[0].VariablePath.UserPath -ceq 'shim' }, $true))
        $verbs = @($shimCalls | ForEach-Object { $_.CommandElements[1].Value })
        $verbs | Should -Be @('shortcuts')
        $known = InModuleScope LocalAI { Get-LocalAIVerb }
        $contributing = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'CONTRIBUTING.md'))
        $contract = $contributing.Substring($contributing.IndexOf('## Release contract'))
        foreach ($verb in @($verbs) + @('install')) {
            $known.ContainsKey($verb) | Should -BeTrue -Because "install.ps1 relies on the verb $verb"
            $contract.Contains("``$verb``") | Should -BeTrue -Because "the release contract names the verb $verb"
        }
    }

    It 'takes -Tag, -AddToPath and -Shortcuts, and installs the releases of the repository that config\defaults.psd1 names' {
        $block = $installAst.EndBlock.Statements[0].PipelineElements[0].CommandElements[0].ScriptBlock
        @($block.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('Tag', 'AddToPath', 'Shortcuts')
        $main = @($installFunctions | Where-Object { $_.Name -ceq 'Install-LauncherFromRelease' })[0]
        $repo = @($main.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Repo' })[0]
        $repo.DefaultValue.Value | Should -BeExactly (Get-LocalAISettings -DefaultsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\defaults.psd1')).Launcher.Repo
    }

    It 'Invoke-LauncherSetup runs Install-LocalAILauncher of the staged version in Windows PowerShell with RemoteSigned on this console' {
        $seen = @{}
        Mock Start-Process {
            $process = [pscustomobject]@{ Handle = [IntPtr]1; ExitCode = 0; Waited = $false }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $this.Waited = $true }
            $seen.FilePath = $FilePath
            $seen.ArgumentList = [string]$ArgumentList
            $seen.NoNewWindow = [bool]$NoNewWindow
            $seen.Wait = [bool]$Wait
            $seen.Process = $process
            $seen.ModulePath = $env:PSModulePath
            $process
        }
        # A path with a space and a single quote, which the command must keep whole.
        $setupRoot = Join-Path $TestDrive "setup\it's here\Programs\local-ai-launcher"
        $setupFolder = Write-TestReleaseFolder -Path (Join-Path $setupRoot 'versions\v1.1.0') -Tag 'v1.1.0' -Files @{ 'src/LocalAI.psm1' = [IO.File]::ReadAllText($modulePath) }
        $savedModulePath = $env:PSModulePath
        try {
            # install.ps1 may run in PowerShell 7, whose module path Windows PowerShell must not inherit; this session keeps it.
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules;' + $savedModulePath
            Invoke-LauncherSetup -Folder $setupFolder -Root $setupRoot -Tag 'v1.1.0' | Should -Be 0
            $seen.ModulePath | Should -BeNullOrEmpty
            $env:PSModulePath | Should -BeExactly ('C:\Program Files\PowerShell\7\Modules;' + $savedModulePath)
        } finally {
            $env:PSModulePath = $savedModulePath
        }
        $seen.FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $seen.ArgumentList | Should -BeLike '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -Command "*"'
        $seen.NoNewWindow | Should -BeTrue
        $seen.Wait | Should -BeFalse
        $seen.Process.Waited | Should -BeTrue
        # The command itself, run as powershell.exe would run it, in a runspace of its own.
        $command = [regex]::Match($seen.ArgumentList, '-Command "(.*)"\z').Groups[1].Value
        $null = Invoke-OnOtherThread -Script ([scriptblock]::Create($command))
        [IO.File]::ReadAllText((Join-Path $setupRoot 'current')) | Should -BeExactly "v1.1.0`r`n"
        Test-Path -LiteralPath (Join-Path $setupRoot 'local-ai.cmd') | Should -BeTrue
    }

    Context 'Install-LauncherFromRelease' {
        BeforeEach {
            $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $dest = Join-Path $local 'Programs\local-ai-launcher'
            $destShim = Join-Path $dest 'local-ai.cmd'
            $releaseFiles = @{}
            Mock Get-AppDataRedirection
            Mock Get-LauncherRelease {
                @{ Tag = 'v1.1.0'; Version = '1.1.0'; Asset = 'local-ai-launcher-1.1.0.zip'; Url = 'https://example.invalid/local-ai-launcher-1.1.0.zip'
                    Digest = 'sha256:' + ('a' * 64); Size = 4096 }
            }
            Mock Get-LauncherTagCommit { 'c' * 40 }
            Mock Save-LauncherRelease {
                $path = Join-Path $InstallRoot "versions\$($Release.Tag)"
                if (-not (Test-Path -LiteralPath $path)) { $null = Write-TestReleaseFolder -Path $path -Tag $Release.Tag -Files $releaseFiles }
                @{ Path = $path; Downloaded = $true }
            }
            # What Windows PowerShell does there, here in this session: the module's own Install-LocalAILauncher.
            Mock Invoke-LauncherSetup { $null = Install-LocalAILauncher -Root $Root -Tag $Tag; 0 }
            Mock Send-LauncherSettingChange
            $key = Get-TestEnvironmentKey -Value '%USERPROFILE%\bin;C:\Tools'
            Mock Get-LauncherEnvironmentKey { $key }
            # Run it for the folder $local with $Arguments, and return what it printed.
            $install = {
                param([hashtable]$Arguments = @{})
                Install-LauncherFromRelease @Arguments -LocalAppData $local -ShellLocalAppData $local 6>&1 | ForEach-Object { "$_" }
            }
            # The shim runs only from %LOCALAPPDATA%\Programs\local-ai-launcher, so the tests that run it set LOCALAPPDATA to $local.
            $savedLocalAppData = $env:LOCALAPPDATA
        }

        AfterEach {
            $env:LOCALAPPDATA = $savedLocalAppData
        }

        It 'installs the latest release: checks and stages it, has that version set up the shim and current, and names the next step' {
            $printed = & $install
            Should -Invoke Get-AppDataRedirection -Times 1 -Exactly -ParameterFilter { $LocalAppData -eq $local }
            Should -Invoke Get-LauncherRelease -Times 1 -Exactly -ParameterFilter { $Repo -ceq 'Ochsyp/local-ai-launcher' -and $Tag -eq '' -and $TimeoutSeconds -eq 15 }
            Should -Invoke Get-LauncherTagCommit -Times 1 -Exactly -ParameterFilter { $Tag -ceq 'v1.1.0' -and $TimeoutSeconds -eq 15 }
            Should -Invoke Save-LauncherRelease -Times 1 -Exactly -ParameterFilter { $InstallRoot -eq $dest -and $Release.Commit -ceq ('c' * 40) }
            Should -Invoke Invoke-LauncherSetup -Times 1 -Exactly -ParameterFilter { $Folder -eq (Join-Path $dest 'versions\v1.1.0') -and $Root -eq $dest -and $Tag -ceq 'v1.1.0' }
            [IO.File]::ReadAllText((Join-Path $dest 'current')) | Should -BeExactly "v1.1.0`r`n"
            Test-Path -LiteralPath $destShim | Should -BeTrue
            Should -Invoke Get-LauncherEnvironmentKey -Times 0 -Exactly
            $printed | Should -Contain "The launcher v1.1.0 is installed in $dest."
            $printed | Should -Contain "Next, run: & `"$destShim`" install"
        }

        It 'asks GitHub for the release that -Tag names' {
            $null = & $install @{ Tag = 'v1.1.0' }
            Should -Invoke Get-LauncherRelease -Times 1 -Exactly -ParameterFilter { $Tag -ceq 'v1.1.0' }
        }

        It 'names <Next> as the next step when install-stamp.json <Case>' -ForEach @(
            @{ Case = 'records Ollama, Model and OpenWebUI, as after an install from a git clone'; Next = 'status'
                Stamp = '{"Ollama": {"Version": "0.40.11"}, "Model": {"Alias": "local-chat"}, "OpenWebUI": {"Version": "0.12.4"}, "ComfyUI": {"Commit": "a"}}' }
            @{ Case = 'records no OpenWebUI'; Next = 'install'; Stamp = '{"Ollama": {"Version": "0.40.11"}, "Model": {"Alias": "local-chat"}}' }
            @{ Case = 'records a part as no object'; Next = 'install'; Stamp = '{"Ollama": "0.40.11", "Model": {"Alias": "local-chat"}, "OpenWebUI": {"Version": "0.12.4"}}' }
            @{ Case = 'is not JSON'; Next = 'install'; Stamp = '{ broken' }
        ) {
            $null = Write-TestFile "$(Split-Path $local -Leaf)\local-ai\install-stamp.json" $Stamp
            $printed = @(& $install)
            $printed | Should -Contain "Next, run: & `"$destShim`" $Next"
            $reason = @($printed | Where-Object { $_ -like '*records the parts as installed*' })
            if ($Next -eq 'status') {
                $reason | Should -Be @("$(Join-Path $local 'local-ai\install-stamp.json') records the parts as installed, so status comes next; it names " +
                    "'local-ai update' when they differ from the pins of v1.1.0.")
            } else {
                $reason | Should -BeNullOrEmpty
            }
        }

        It 'names status for a new console window with -AddToPath when install-stamp.json records the parts' {
            $null = Write-TestFile "$(Split-Path $local -Leaf)\local-ai\install-stamp.json" '{"Ollama": {"Version": "0.40.11"}, "Model": {"Alias": "local-chat"}, "OpenWebUI": {"Version": "0.12.4"}}'
            $printed = & $install @{ AddToPath = $true }
            $printed | Should -Contain 'Next, open a new console window and run: local-ai status'
        }

        It 'refuses inside an app package, which the probe of <Case> finds, before it asks GitHub' -ForEach @(
            @{ Case = '%LOCALAPPDATA%'; Shell = ''; Probed = 1 }
            @{ Case = 'the known folder, when %LOCALAPPDATA% names another one'; Shell = 'C:\Users\User\AppData\Local'; Probed = 2 }
        ) {
            Mock Get-AppDataRedirection {
                if (($Shell -and $LocalAppData -eq $Shell) -or (-not $Shell -and $LocalAppData -eq $local)) {
                    @{ Package = 'Fake_123'; Store = 'C:\Users\User\AppData\Local\Packages\Fake_123\LocalCache\Local' }
                }
            }
            { Install-LauncherFromRelease -LocalAppData $local -ShellLocalAppData $Shell 6>$null } |
                Should -Throw -ExpectedMessage '*app package Fake_123*so the launcher would land where other windows never see it. Nothing was changed. Run install.ps1 from a console window*'
            Should -Invoke Get-AppDataRedirection -Times $Probed -Exactly
            Should -Invoke Get-LauncherRelease -Times 0 -Exactly
            Test-Path -LiteralPath $local | Should -BeFalse
        }

        It 'changes nothing when the download cannot be reached, and removes the empty folders it made' {
            Mock Save-LauncherRelease {
                $null = New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot 'staging')
                throw (New-LauncherProblem -Kind 'Unreachable' -Message 'the download of local-ai-launcher-1.1.0.zip failed: Unable to connect to the remote server')
            }
            { & $install } | Should -Throw -ExpectedMessage ('Could not get the launcher from GitHub (the download of local-ai-launcher-1.1.0.zip failed: Unable to ' +
                'connect to the remote server). Nothing was changed.')
            Test-Path -LiteralPath $dest | Should -BeFalse
            Should -Invoke Invoke-LauncherSetup -Times 0 -Exactly
        }

        It 'stops on a release that fails a check, and keeps an install folder that was there' {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dest 'staging')
            Mock Get-LauncherRelease { throw (New-LauncherProblem -Kind 'Refused' -Message 'The release v1.1.0 is a draft, which the launcher never installs.') }
            { & $install } | Should -Throw -ExpectedMessage 'The release v1.1.0 is a draft, which the launcher never installs. Nothing was changed.'
            Should -Invoke Save-LauncherRelease -Times 0 -Exactly
            Test-Path -LiteralPath (Join-Path $dest 'staging') | Should -BeTrue
        }

        It 'refuses while the whole version <Active> runs there, <Case>' -ForEach @(
            @{ Active = 'v1.2.0'; Case = 'as it never goes back'
                Message = "*runs v1.2.0, which is newer than v1.1.0, and install.ps1 never goes back; 'local-ai update -Rollback' returns*Nothing was changed." }
            @{ Active = 'v1.0.0'; Case = 'as update moves between versions'
                Message = "*runs v1.0.0 already; 'local-ai update' moves it to v1.1.0 and brings the parts to that version's pins. Nothing was changed." }
        ) {
            $existing = Write-TestLauncherInstall -Tags @($Active) -Current $Active
            { Install-LauncherFromRelease -LocalAppData $existing.LocalAppData -ShellLocalAppData $existing.LocalAppData 6>$null } | Should -Throw -ExpectedMessage $Message
            Should -Invoke Save-LauncherRelease -Times 0 -Exactly
            [IO.File]::ReadAllText((Join-Path $existing.Root 'current')) | Should -BeExactly "$Active`r`n"
        }

        It 'replaces a version that current names but that is missing, and sets up the version that runs again' {
            $missing = Write-TestLauncherInstall -Tags @() -Current 'v1.0.0'
            $printed = Install-LauncherFromRelease -LocalAppData $missing.LocalAppData -ShellLocalAppData $missing.LocalAppData 6>&1 | ForEach-Object { "$_" }
            $printed | Should -Contain 'The version v1.0.0 that current names is missing or damaged, so v1.1.0 takes its place.'
            [IO.File]::ReadAllText((Join-Path $missing.Root 'current')) | Should -BeExactly "v1.1.0`r`n"
            $same = Write-TestLauncherInstall -Tags @('v1.1.0') -Current 'v1.1.0'
            $printed = Install-LauncherFromRelease -LocalAppData $same.LocalAppData -ShellLocalAppData $same.LocalAppData 6>&1 | ForEach-Object { "$_" }
            $printed | Should -Contain "v1.1.0 is in $($same.Root)\versions already; checking its files again."
            Test-Path -LiteralPath (Join-Path $same.Root 'local-ai.cmd') | Should -BeTrue
        }

        It 'fails, naming the exit code, when the setup in Windows PowerShell fails, and then leaves the Path alone' {
            Mock Invoke-LauncherSetup { 1 }
            { & $install @{ AddToPath = $true } } | Should -Throw -ExpectedMessage "Windows PowerShell could not set up $dest with the LocalAI.psm1 of v1.1.0 (exit code 1). v1.1.0 stays in*"
            Should -Invoke Get-LauncherEnvironmentKey -Times 0 -Exactly
        }

        It '-AddToPath adds the install folder to the user Path in the registry, keeping its kind, and tells running programs' {
            $printed = & $install @{ AddToPath = $true }
            $key.Values['Path'] | Should -BeExactly "%USERPROFILE%\bin;C:\Tools;$dest"
            $key.Kinds['Path'] | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
            $key.Options | Should -Be ([Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $key.Disposed | Should -Be 1
            Should -Invoke Send-LauncherSettingChange -Times 1 -Exactly
            $printed | Should -Contain 'Next, open a new console window and run: local-ai install'
        }

        It '-AddToPath only warns when Windows cannot tell running programs, as the Path holds the folder already' {
            Mock Send-LauncherSettingChange { throw 'Add-Type could not compile the binding.' }
            $printed = @(& $install @{ AddToPath = $true } 3>&1 | ForEach-Object { "$_" })
            $key.Values['Path'] | Should -BeExactly "%USERPROFILE%\bin;C:\Tools;$dest"
            $printed | Should -Contain 'Windows could not tell running programs that your Path changed, so it may take a new sign-in: Add-Type could not compile the binding.'
            $printed | Should -Contain "Added $dest to your Path, which console windows opened from now on read."
            $printed | Should -Contain 'Next, open a new console window and run: local-ai install'
        }

        It '-AddToPath writes nothing and tells nobody when the Path names the folder already' {
            $key = Get-TestEnvironmentKey -Value "C:\Tools;$($dest.ToUpperInvariant())\" -Kind ([Microsoft.Win32.RegistryValueKind]::String)
            $printed = & $install @{ AddToPath = $true }
            $key.Writes.Count | Should -Be 0
            Should -Invoke Send-LauncherSettingChange -Times 0 -Exactly
            $printed | Should -Contain "Your Path names $dest already."
        }

        It '-AddToPath leaves a Path that holds no text alone, and says that the launcher is installed' {
            $key = Get-TestEnvironmentKey -Value 5 -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)
            { & $install @{ AddToPath = $true } } |
                Should -Throw -ExpectedMessage "The launcher v1.1.0 is installed in $dest, but your Path is unchanged: The user's Path in HKCU\Environment is a DWord value*"
            $key.Writes.Count | Should -Be 0
        }

        It '-Shortcuts runs local-ai shortcuts through the shim it set up' {
            $env:LOCALAPPDATA = $local
            $releaseFiles = @{ 'local-ai.cmd' = "@echo off`r`necho %*> `"%~dp0arguments.txt`"`r`nexit /b 0`r`n" }
            $null = & $install @{ Shortcuts = $true }
            [IO.File]::ReadAllText((Join-Path $dest 'versions\v1.1.0\arguments.txt')).Trim() | Should -BeExactly 'shortcuts'
        }

        It '-Shortcuts only warns when local-ai shortcuts ends with warnings' {
            $env:LOCALAPPDATA = $local
            $releaseFiles = @{ 'local-ai.cmd' = "@echo off`r`nexit /b 2`r`n" }
            $printed = @(& $install @{ Shortcuts = $true } 3>&1 | ForEach-Object { "$_" })
            $printed | Should -Contain "'local-ai shortcuts' finished with warnings, which it printed above."
            $printed | Should -Contain "The launcher v1.1.0 is installed in $dest."
        }

        It '-Shortcuts fails, saying that the launcher is installed, when local-ai shortcuts fails' {
            $env:LOCALAPPDATA = $local
            $releaseFiles = @{ 'local-ai.cmd' = "@echo off`r`nexit /b 1`r`n" }
            { & $install @{ Shortcuts = $true } } | Should -Throw -ExpectedMessage "The launcher v1.1.0 is installed in $dest, but 'local-ai shortcuts' failed with exit code 1;*"
            [IO.File]::ReadAllText((Join-Path $dest 'current')) | Should -BeExactly "v1.1.0`r`n"
        }
    }
}

Describe 'install.ps1 run as irm | iex runs it' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $installText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\install.ps1'))
        Import-Module (Join-Path $repoRoot '.github\scripts\LocalAIRelease.psm1') -Force
        # The release v1.1.0 as the release tooling builds it, from a git repository that holds this launcher's runtime files.
        $repository = Join-Path $TestDrive 'iex-repository'
        foreach ($name in 'local-ai.cmd', 'src\local-ai.ps1', 'src\LocalAI.psm1', 'src\install.ps1', 'config\defaults.psd1', 'README.md', 'LICENSE', '.gitattributes') {
            $target = Join-Path $repository $name
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent)
            Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination $target
        }
        [IO.File]::WriteAllText((Join-Path $repository 'VERSION'), "1.1.0`n")
        $git = @('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'init.defaultBranch=main', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')
        $savedPreference = $ErrorActionPreference
        try {
            # git writes progress to stderr, which Windows PowerShell 5.1 turns into error records.
            $ErrorActionPreference = 'Continue'
            $null = & git @git init -q $repository 2>&1
            $null = & git @git -C $repository add -A 2>&1
            $null = & git @git -C $repository commit -q -m 'release' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git could not commit the test release in $repository." }
        } finally {
            $ErrorActionPreference = $savedPreference
        }
        $built = New-ReleaseZip -RepositoryPath $repository -Commit 'HEAD' -Version '1.1.0' -OutputDirectory (Join-Path $TestDrive 'iex-built')

        # install.ps1's own functions are no commands here, so these stand-ins give Mock a command to replace.
        function Get-AppDataRedirection { }
        function Get-LauncherEnvironmentKey { }
        function Send-LauncherSettingChange { }
    }

    BeforeEach {
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dest = Join-Path $local 'Programs\local-ai-launcher'
        $savedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $local
        Mock Get-AppDataRedirection
        Mock Invoke-RestMethod {
            if ($Uri -like '*/git/ref/tags/*') { return Get-TestTagRef -Tag 'v1.1.0' -Sha $built.Commit }
            Get-TestReleaseObject -Tag 'v1.1.0' -Digest "sha256:$($built.Sha256)" -Asset @{ size = (Get-Item -LiteralPath $built.Path).Length }
        }
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $built.Path -Destination $OutFile }
        # The powershell.exe that sets up the folder: the same command, run in a runspace of its own.
        Mock Start-Process {
            $command = [regex]::Match([string]$ArgumentList, '-Command "(.*)"\z').Groups[1].Value
            $null = Invoke-OnOtherThread -Script ([scriptblock]::Create($command))
            $process = [pscustomobject]@{ Handle = [IntPtr]1; ExitCode = 0 }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
            $process
        }
    }

    AfterEach {
        $env:LOCALAPPDATA = $savedLocalAppData
    }

    It 'installs the latest release, and leaves no function, variable, module or preference of its own in the session' {
        $preference = $ErrorActionPreference
        Invoke-Expression $installText 6>$null
        [IO.File]::ReadAllText((Join-Path $dest 'current')) | Should -BeExactly "v1.1.0`r`n"
        Test-Path -LiteralPath (Join-Path $dest 'local-ai.cmd') | Should -BeTrue
        Invoke-ModuleFunction 'Test-LauncherFolder' @{ Path = (Join-Path $dest 'versions\v1.1.0'); Tag = 'v1.1.0'; Commit = $built.Commit } | Should -BeNullOrEmpty
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
        $ErrorActionPreference | Should -Be $preference
        @(Get-Module -Name LocalAI | Where-Object { $_.Path -like "$local*" }) | Should -BeNullOrEmpty
        foreach ($name in 'Install-LauncherFromRelease', 'Invoke-LauncherSetup', 'Get-LauncherRelease', 'Save-LauncherRelease') {
            Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "$name stays inside install.ps1"
        }
        foreach ($name in 'Tag', 'AddToPath', 'Shortcuts') {
            Get-Variable -Name $name -Scope 0 -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "`$$name stays inside install.ps1"
        }
    }

    It 'takes -Tag and -AddToPath through a script block made of its text' {
        $key = Get-TestEnvironmentKey -Value 'C:\Tools'
        Mock Get-LauncherEnvironmentKey { $key }
        Mock Send-LauncherSettingChange
        & ([scriptblock]::Create($installText)) -Tag v1.1.0 -AddToPath 6>$null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -ceq 'https://api.github.com/repos/Ochsyp/local-ai-launcher/releases/tags/v1.1.0' }
        $key.Values['Path'] | Should -BeExactly "C:\Tools;$dest"
        Should -Invoke Send-LauncherSettingChange -Times 1 -Exactly
        [IO.File]::ReadAllText((Join-Path $dest 'current')) | Should -BeExactly "v1.1.0`r`n"
    }

    It 'throws when GitHub cannot be reached, which changes nothing and leaves the window open' {
        Mock Invoke-RestMethod { throw (Get-TestWebError) }
        { Invoke-Expression $installText 6>$null } | Should -Throw -ExpectedMessage 'Could not get the launcher from GitHub (Unable to connect to the remote server). Nothing was changed.'
        Test-Path -LiteralPath $local | Should -BeFalse
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}
