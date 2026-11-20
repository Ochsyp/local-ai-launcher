# The CI stage test of the repository standard: the Pester tests through tests\run-checks.ps1,
# then the image gate's unittest tests with the packages of tests\requirements.txt. Needs a
# python on the Path, which CI sets up (PYTHON in .github\standard.conf).
# Continue, so a line written to stderr, as unittest writes its report, does not stop this
# script; each exit code decides.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\run-checks.ps1') -SkipAnalyzer
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
python -m pip install --disable-pip-version-check --no-input -r (Join-Path $root 'tests\requirements.txt')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
python -I -B -m unittest discover -s (Join-Path $root 'tests') -p 'test_*.py'
exit $LASTEXITCODE
