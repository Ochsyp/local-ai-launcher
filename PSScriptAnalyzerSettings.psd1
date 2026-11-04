# -------------------------------------------------------
#              PSSCRIPTANALYZER SETTINGS
# -------------------------------------------------------
#
# Rules for PSScriptAnalyzer 1.25.0, whose -Path takes one folder per call:
#   'src', 'config', 'tests', '.github' | ForEach-Object {
#       Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings .\PSScriptAnalyzerSettings.psd1 }
# The launcher targets Windows PowerShell 5.1.

@{
    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # An interactive console tool: Write-Host is its output, not a diagnostic stream.
        'PSAvoidUsingWriteHost'
        # Functions carry the repository's short comment above them instead of comment help.
        'PSProvideCommentHelp'
    )

    Rules        = @{
        # Syntax must parse on 5.1; 7.6 keeps the door open for pwsh later.
        PSUseCompatibleSyntax         = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.6')
        }
        # Commands and parameters must exist in Windows PowerShell 5.1 on Windows 10/11 x64. The
        # profile knows only the in-box Pester 3.4, so the Pester 6 test commands are skipped.
        PSUseCompatibleCommands       = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
            IgnoreCommands = @('Describe', 'Context', 'It', 'Should', 'BeforeDiscovery', 'BeforeAll',
                'AfterAll', 'BeforeEach', 'AfterEach', 'Mock', 'InModuleScope', 'Set-ItResult')
        }
        # .NET types and members used directly, such as [IO.File]::Replace, must exist there too.
        PSUseCompatibleTypes          = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        # 5.1 reads a BOM-less non-ASCII script as ANSI, so such files need a BOM.
        PSUseBOMForUnicodeEncodedFile = @{
            Enable = $true
        }
    }
}
