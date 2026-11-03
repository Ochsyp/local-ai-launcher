# Security policy

This is a single-maintainer project. The launcher is meant for a single-user Windows PC that
you trust.

## Reporting a problem

Report a vulnerability privately through GitHub: on the repository's **Security** tab, choose
*Report a vulnerability*. Do not open a public issue for it. Never paste tokens, keys or logs
that contain them into issues, pull requests, reports or commits.

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

Open WebUI, ComfyUI and the image gate also get an allow-list. Of the variables that hold a
value in the window that runs `start` or `update`, each inherits only these, besides those the
launcher sets for it:

- All three: what Windows and Python need. These are `SystemRoot`, `SystemDrive`, `windir`,
  `ComSpec`, `PATHEXT`, `Path`, `TEMP`, `TMP`, `USERPROFILE`, `HOMEDRIVE`, `HOMEPATH`,
  `USERNAME`, `USERDOMAIN`, `COMPUTERNAME`, `APPDATA`, `LOCALAPPDATA`, `ProgramData`,
  `ALLUSERSPROFILE`, `PUBLIC`, `ProgramFiles`, `ProgramFiles(x86)`, `ProgramW6432`,
  `CommonProgramFiles`, `CommonProgramFiles(x86)`, `CommonProgramW6432`, `OS`,
  `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE`, `PROCESSOR_IDENTIFIER`, `PROCESSOR_LEVEL`,
  `PROCESSOR_REVISION` and `DriverData`.
- Open WebUI also: `HF_HOME`, `HF_HUB_CACHE`, `HUGGINGFACE_HUB_CACHE`, `XDG_CACHE_HOME` and
  `SENTENCE_TRANSFORMERS_HOME`, which say where its embedding model is kept, and
  `HF_HUB_OFFLINE`.
- ComfyUI also: `CUDA_VISIBLE_DEVICES` and `CUDA_DEVICE_ORDER`, which choose its GPU,
  `PYTORCH_CUDA_ALLOC_CONF`, `PYTORCH_ALLOC_CONF` and `CUDA_PATH`.
- The names in `OpenWebUI.InheritEnvironment` and `ComfyUI.InheritEnvironment`. ComfyUI's list
  does not apply to the image gate.

Proxy variables, such as `HTTPS_PROXY`, are not on the lists, since a proxy address can hold a
user name and password, and neither are CA-bundle variables such as `SSL_CERT_FILE`. Add them
to one of the two settings when a service needs them. A listed variable reaches the service with
its value, so Open WebUI and the tools and functions inside it can read a password in the proxy
address. Prefer a proxy that needs no password in its address.

No service inherits a variable whose name ends in `_TOKEN` or `_API_KEY`, or `PYTHONHOME`,
`PYTHONPATH`, `PYTHONSTARTUP`, `PYTHONUSERBASE`, `NODE_OPTIONS` or `NODE_PATH`. The settings
check refuses these names in the two lists. Such a name reaches a service only with a value the
launcher sets for it, such as one from `OpenWebUI.Env`. So a secret in another user or console
variable, such as `AWS_SECRET_ACCESS_KEY`, is not in the environment of Open WebUI or of the
tools and functions that run inside it, and a tool that reads its environment cannot reveal it.

The allow-lists cover only the environment. Code that runs inside a service runs as your
Windows user, so it can still read your user variables in the registry (`HKCU\Environment`) and
the files of your account, such as hf's token file and `files.key`.

`start` warns when it reuses an Open WebUI or a ComfyUI that an earlier start, such as one by an
older launcher, left running with other inherited variables. Such a service keeps its
environment until `local-ai stop`.

The Ollama app is not a service the launcher starts with an allow-list. When Ollama does not
answer, the launcher starts the app, itself or through `ollama list` when the app is not beside
`ollama.exe`. The app and the Ollama server it runs then inherit the whole environment of that
window. `local-ai stop` quits an app that the launcher started and recorded, which ends that,
unless another program has a model loaded in it or is still connected to it, its window is
open, or it runs in another Windows session; the app then keeps that environment until it is
quit. An app started through `ollama list`, or one the launcher cannot tell apart from another
app, is not recorded, so `stop` leaves it running. `start`, also when `update` runs it, forgets
an app recorded for a server that `Ollama.Url` no longer names, and `stop` then leaves that app
running too. An Ollama app that already ran keeps the environment it started with, and `stop`
leaves it running.

## Secrets

- Nothing secret is stored in this repository. `hf download` reads `HF_TOKEN` from the
  environment or from hf's own token file; the launcher never puts it on a command line.
- Open WebUI's signing key `.webui_secret_key` and its database `webui.db` live in
  `%LOCALAPPDATA%\open-webui` (`OpenWebUI.DataDir`).
- `%LOCALAPPDATA%\local-ai\backups` holds copies of `webui.db` and `.webui_secret_key`: those
  that `update` and `install` make, and the data a rollback moves aside. Treat that folder as
  secret. `uninstall -RemoveData` deletes it.
- `.gitignore` blocks `.env` files except `.env.example`, `webui.db` with its `-wal`, `-shm` and
  `-journal` files, `.webui_secret_key` and mcpo's `files.key`, in case a data folder is ever
  redirected here.
- If a secret is ever committed, rotate it first, then remove it from history: deleting the
  file leaves it in earlier commits.

The check that refuses every verb but `status` inside a packaged app, such as the Claude
desktop app, keeps the launcher's files out of that app's private store. It is not a security
control.

## Automated checks

- gitleaks scans the commits of every push and pull request, and the full history once a week
  and on demand (`.github/workflows/secret-scan.yml`).
- `.github/workflows/ci.yml` runs PSScriptAnalyzer, the Pester tests and the image gate's
  unittest tests on `windows-latest`.
- Dependabot proposes weekly updates for the pinned GitHub Actions, the files server's npm
  lockfile (`config/files-server`) and the Python test requirements (`tests`).
