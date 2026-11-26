# The build hook of the repository standard: its release-build runs this script in the checkout,
# under Windows PowerShell 5.1, as
#   ci/release-build.ps1 --version X.Y.Z --commit SHA --out DIR [--dry-run]
# and checks VERSION, CHANGELOG.md, the tags, SHA256SUMS and the two builds of a dry run itself.
# It writes DIR\assets\local-ai-launcher-X.Y.Z.zip, install.ps1 and SHA256SUMS through
# Invoke-ReleaseHookBuild of .github\scripts\LocalAIRelease.psm1. Exits 0 when the build worked,
# 1 when it failed, 64 for wrong arguments.

$ErrorActionPreference = 'Stop'
$usage = 'usage: ci/release-build.ps1 --version X.Y.Z --commit SHA --out DIR [--dry-run]'
$given = @{}
for ($i = 0; $i -lt $args.Count; $i++) {
    $name = [string]$args[$i]
    if ($name -ceq '--dry-run') { continue }
    # A value that starts with -- is a flag given where the value is missing.
    if (@('--version', '--commit', '--out') -cnotcontains $name -or $i + 1 -ge $args.Count -or ([string]$args[$i + 1]).StartsWith('--')) {
        Write-Host $usage
        exit 64
    }
    $i++
    $given[$name] = [string]$args[$i]
}
foreach ($name in '--version', '--commit', '--out') {
    if (-not $given[$name]) {
        Write-Host $usage
        exit 64
    }
}

try {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) '.github\scripts\LocalAIRelease.psm1') -Force
    # A dry run builds the same way: the standard's release-build runs this script twice and compares the results.
    $null = Invoke-ReleaseHookBuild -RepositoryPath (Get-Location).Path -Version $given['--version'] -Commit $given['--commit'] `
        -OutputDirectory $given['--out']
} catch {
    Write-Host "ci/release-build.ps1: $($_.Exception.Message)"
    exit 1
}
exit 0
