# Security policy

This is a private, single-maintainer repository.

## Reporting a problem

Contact [@Ochsyp](https://github.com/Ochsyp) directly. Never paste tokens, keys or logs
that contain them into issues, pull requests or commits.

## Secrets

- `HF_TOKEN` is read from the environment only; nothing secret is stored in this
  repository.
- Open WebUI's signing key and database live in `%LOCALAPPDATA%\open-webui`.
  `.gitignore` blocks them in case that folder is ever redirected here.
- If a secret is ever committed, rotate it first, then remove it from history:
  deleting the file leaves it in earlier commits.

## Automated checks

- gitleaks scans every push and pull request (`.github/workflows/secret-scan.yml`).
- Dependabot keeps the pinned GitHub Actions up to date.
