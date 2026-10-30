# Security policy

This is a private, single-maintainer repository. The launcher is meant for a single-user
Windows PC that you trust.

## Reporting a problem

Contact [@Ochsyp](https://github.com/Ochsyp) directly. Never paste tokens, keys or logs
that contain them into issues, pull requests or commits.

## Network

- Open WebUI, ComfyUI, the image gate and mcpo listen on `127.0.0.1` only. The launcher drops
  flags such as `--listen`, `--enable-manager` and `--enable-cors-header` from `ComfyUI.Args`.
- Ollama is the exception: the Ollama app chooses its own address, and the launcher never sets
  `OLLAMA_HOST`. `install`, `start` and `status` warn when Ollama listens beyond loopback.
- Any program on this PC can reach these ports. Ollama and ComfyUI have no sign-in. The image
  gate refuses a foreign `Host` or `Origin` and a browser's cross-site fetch.

## Open WebUI

- `WEBUI_AUTH` is `True` and `ENABLE_SIGNUP` is `False`. Open WebUI 0.12.4 still lets the first
  account on a fresh data folder sign up, and that account becomes the admin. Then sign-up is
  closed.
- `CORS_ALLOW_ORIGIN` names only its own two local addresses. `ENV` is `prod`, so Open WebUI
  does not serve `/docs` and `/openapi.json` at all.
- `CONTENT_SECURITY_POLICY` lets the page, and the HTML artifacts it renders from answers, load
  nothing from other hosts: `default-src`, `connect-src` and `form-action` are `'self'`, and
  `object-src` is `'none'`. Scripts keep `'unsafe-inline'` and `'unsafe-eval'`, which the UI
  needs.
- `DEFAULT_INTERFACE_SETTINGS` is `{"detectArtifacts":false,"iframeSandboxAllowScripts":false}`.
  So HTML in an answer opens as an artifact only on request and runs no scripts. Each account can
  change this under *Settings > Interface*.
- Web search, code execution, the code interpreter, community sharing, pip installs from tool
  front matter and the update check are off.
- `CORS_ALLOW_ORIGIN` follows `Ports.OpenWebUI` only. The other values are defaults: the
  launcher sets `ENABLE_SIGNUP`, and `config\defaults.psd1` holds the rest. `OpenWebUI.Env` in
  `settings.psd1` can change them, so keep them as they are.

## File tools

- They are read-only. mcpo hides every write tool, and the settings check refuses a
  `Files.DisabledTools` that leaves one out. Only the admin account gets the tools.
- `start` refuses a `Files.Root` that is a drive root, `%USERPROFILE%` or a folder above it, a
  link or a path through one, or a folder in or around `%LOCALAPPDATA%\local-ai`, this
  repository, uv's tool folder, `OpenWebUI.DataDir` or `ComfyUI.Dir`. It also refuses a folder
  that holds a name `Files.DenyPatterns` matches, or a hard link to a file that has a name
  outside it, as a `.venv` that uv made does.
- The check does not follow links inside the folder; the files server refuses those that lead
  outside it. Files added while mcpo runs are not checked.
- NTFS alternate data streams, such as `file.txt:Zone.Identifier`, are readable.
- mcpo's API key is in `%LOCALAPPDATA%\local-ai\files.key`, which only your account may open.
  mcpo 0.0.20 takes the key only on its command line, and Open WebUI gets it in
  `TOOL_SERVER_CONNECTIONS`. Other programs of the same Windows user can read it in both places.
- mcpo and the files server get an allow-list of environment variables: only those that Windows,
  Python and Node.js need.

## Environment of the other services

Open WebUI, ComfyUI and the image gate inherit the environment of the window that runs `start`
or `update`. The launcher removes only variables whose names end in `_TOKEN` or `_API_KEY`, and
`PYTHONHOME`, `PYTHONPATH`, `PYTHONSTARTUP`, `PYTHONUSERBASE`, `NODE_OPTIONS` and `NODE_PATH`.
This is a known limit: a secret in any other user or console variable reaches Open WebUI and
the tools and functions that run inside it.

## Secrets

- Nothing secret is stored in this repository. `hf download` reads `HF_TOKEN` from the
  environment or from hf's own token file; the launcher never puts it on a command line.
- Open WebUI's signing key `.webui_secret_key` and its database `webui.db` live in
  `%LOCALAPPDATA%\open-webui` (`OpenWebUI.DataDir`).
- `%LOCALAPPDATA%\local-ai\backups` holds copies of `webui.db` and `.webui_secret_key`: those
  that `update` and `install` make, and the data a rollback moves aside. Treat that folder as
  secret. `uninstall -RemoveData` deletes it.
- `.gitignore` blocks `webui.db` and `.webui_secret_key` in case a data folder is ever
  redirected here.
- If a secret is ever committed, rotate it first, then remove it from history: deleting the
  file leaves it in earlier commits.

The check that refuses every verb but `status` inside a packaged app, such as the Claude
desktop app, keeps the launcher's files out of that app's private store. It is not a security
control.

## Automated checks

- gitleaks scans the full history on every push and pull request
  (`.github/workflows/secret-scan.yml`).
- `.github/workflows/ci.yml` runs PSScriptAnalyzer, the Pester tests and the image gate's
  unittest tests on `windows-latest`.
- Dependabot proposes weekly updates for the pinned GitHub Actions, the files server's npm
  lockfile (`config/files-server`) and the Python test requirements (`tests`).
