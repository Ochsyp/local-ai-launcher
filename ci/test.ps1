# The CI stage test of the repository standard: the Pester tests through tests\run-checks.ps1,
# then the image gate's unittest tests with the packages of tests\requirements.txt, and on a CI
# runner the live check of the files server. Needs a python on the Path, which CI sets up (PYTHON
# in .github\standard.conf).
# Continue, so a line written to stderr, as unittest writes its report, does not stop this
# script; each exit code decides.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\run-checks.ps1') -SkipAnalyzer
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# Every package with its hashes and as a wheel, as the live check installs uv, so no new upload of a dependency reaches the job that gates releases.
python -m pip install --disable-pip-version-check --no-input --require-hashes --only-binary :all: -r (Join-Path $root 'tests\requirements.txt')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
python -I -B -m unittest discover -s (Join-Path $root 'tests') -p 'test_*.py'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# It installs real packages, so it never runs on a PC.
if ($env:GITHUB_ACTIONS -ceq 'true') {
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'files-server-live.ps1')
    exit $LASTEXITCODE
}
exit 0
