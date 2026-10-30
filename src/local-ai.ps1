# -------------------------------------------------------
#                   LOCAL AI LAUNCHER
# -------------------------------------------------------
#
# Command-line entry behind local-ai.cmd. Accepts one verb plus switches, hands them to
# Invoke-LocalAI in LocalAI.psm1 and exits with its code: 0 ok, 1 failed, 2 degraded.
# Settings live in config\defaults.psd1 and %LOCALAPPDATA%\local-ai\settings.psd1, not here.

#Requires -Version 5.1

# An advanced script, so a mistyped switch or a stray argument fails instead of being ignored.
[CmdletBinding()]
param(
    [ValidateSet('install', 'start', 'stop', 'status', 'update', 'uninstall', 'shortcuts')]
    [string]$Verb = 'start',
    [switch]$Json,
    [switch]$Tools,
    [switch]$Remove,
    [switch]$RemoveData,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 parses web responses with Internet Explorer's engine unless told not to.
$PSDefaultParameterValues['Invoke-WebRequest:UseBasicParsing'] = $true

Import-Module (Join-Path $PSScriptRoot 'LocalAI.psm1') -Force
$code = Invoke-LocalAI -Verb $Verb -Json:$Json -Tools:$Tools -Remove:$Remove -RemoveData:$RemoveData -NoBrowser:$NoBrowser
exit $code
