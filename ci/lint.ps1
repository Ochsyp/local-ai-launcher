# The CI stage lint of the repository standard: PSScriptAnalyzer over src, config, tests, ci and
# .github, through tests\run-checks.ps1 without Pester. Exits with its code.
# Continue, so a line the checks write to stderr does not stop this script; the exit code decides.
$ErrorActionPreference = 'Continue'
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\tests\run-checks.ps1') -SkipPester
exit $LASTEXITCODE
