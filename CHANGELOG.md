# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- The Start menu shortcut Update Local AI, which runs `local-ai.cmd update`. `local-ai
  shortcuts` creates it beside Start, Stop and Status Local AI, and `uninstall` and
  `shortcuts -Remove` remove it with them. The refusal inside a packaged app and its line in
  `status` name it too.
- When `update` makes another launcher version active and the Start menu folder holds the
  Start Local AI shortcut of that install, it brings the shortcuts up to date as `local-ai
  shortcuts` does, so an existing install gets Update Local AI with its next update. When that
  fails, `update` warns and returns 2. Shortcuts that point at a git clone or another folder
  stay as they are.

### Changed

- `local-ai.cmd` pauses after `update`, as after `status`, so its result stays readable in a
  window that a shortcut opened. With `-Json` it still never pauses.
- The line `start` prints when a newer launcher is out also names the Start menu shortcut
  Update Local AI. When `start` printed it and ends with exit code 0, it waits for a key, so a
  window that a shortcut opened stays open to read it. It never waits when its input or output
  is redirected, as with `cmd /c "local-ai start < NUL"`, or when the `powershell.exe` that
  runs `src\local-ai.ps1` has `-NonInteractive`. As before, `start` prints the line only when
  its check runs, at most once per `Launcher.CheckIntervalHours`.

## [1.0.1] - 2026-11-11

### Changed

- `install.ps1` names `local-ai status` as the next step, instead of `local-ai install`, when
  `install-stamp.json` in `%LOCALAPPDATA%\local-ai` records the parts already, as on a PC that
  ran the launcher from a git clone.

### Fixed

- A program the launcher runs in its own console window, such as winget, `ollama pull` or
  `npm ci`, no longer loses its exit code when it ends within moments of starting. Windows
  PowerShell's `Start-Process` gave no handle to such a program in time, so the step failed with
  an empty exit code.

## [1.0.0] - 2026-11-11

The launcher was redesigned. These entries compare it with the earlier set of scripts.

### Added

- One launcher, `local-ai.cmd`, with the verbs `install`, `start [-NoBrowser]`, `stop`,
  `status [-Json]`, `update [-Tools]`, `uninstall [-RemoveData]` and `shortcuts [-Remove]`.
  Without a verb it runs `start`. It exits with 0 when done, 1 on a failure and 2 on warnings.
- `config\defaults.psd1`, which holds every default and every version pin.
  `%LOCALAPPDATA%\local-ai\settings.psd1` overrides it key by key. An unknown key or a value of
  the wrong kind is an error.
- Version pins: Open WebUI 0.12.4 on Python 3.12, ComfyUI v0.42.5 at commit `483dae4`, mcpo
  0.0.20 and `@modelcontextprotocol/server-filesystem` 2.1.0. The image checkpoint is pinned to
  a revision.
- SHA-256 checks for the chat model, its vision projector and the image checkpoint.
- The chat model `local-chat`, built from `config\local-chat.Modelfile` with a context of 32768
  tokens. It keeps the model's vision projector, so it reads images.
- The image gate, `src\image_gate.py`. Before each image it unloads `local-chat` from Ollama, so
  the image does not share the GPU's memory with the chat model.
- Optional read-only file tools: mcpo and the MCP files server let the model read one folder,
  `Files.Root`. `start` checks the folder before each start. The files server's `search_files`
  stops with an error after visiting more than 100000 entries.
- `update`, which shows a plan, backs up Open WebUI's data, brings each part to its pin, checks
  the stack and rolls Open WebUI back when the new version fails.
- `uninstall`, which removes the shortcuts, the uv tools, ComfyUI's `.venv`, the files server
  and `local-chat`. It keeps Ollama, uv, Git, Node.js and your data. `-RemoveData` also
  deletes the data folders.
- `status`, which reads only and reports the services, pins and logs. Its doctor checks cover
  the PowerShell version, Group Policy execution policies, launcher files with the download mark
  and the page file. `-Json` prints one line of JSON.
- The Start menu shortcuts Start Local AI, Stop Local AI and Status Local AI.
- A guard that refuses every verb but `status` when Windows would redirect the launcher's
  folders into a packaged app's private store.
- A lock, so only one launcher run changes the stack at a time.
- Service logs and a transcript of each run in `%LOCALAPPDATA%\local-ai\logs`. The
  transcripts of `status` and `uninstall` go to `%TEMP%`.
- CI: `.github/workflows/ci.yml` runs PSScriptAnalyzer, the Pester tests and the image gate
  tests on `windows-latest`. `tests\run-checks.ps1` runs the same checks locally.
- `CONTRIBUTING.md`, a pull request template and two git hooks in `.githooks`: every change
  reaches `main` through a reviewed pull request, and the hooks refuse commits and pushes to
  `main`.
- Releases. A pull request that adds or raises `VERSION` and moves the `[Unreleased]` entries
  under `## [X.Y.Z] - YYYY-MM-DD` makes `.github/workflows/release.yml` build
  `local-ai-launcher-X.Y.Z.zip`, `SHA256SUMS` and a build provenance attestation, and create the
  draft release `vX.Y.Z`, which the maintainer publishes. CI checks `VERSION` against the
  CHANGELOG, and a pull request that changes the release tooling or `VERSION` gets a dry run of
  the build. CONTRIBUTING.md describes the steps and the release contract, and the README how to
  check a download.
- `status` names the launcher's version from `VERSION`, and `-Json` reports it as
  `launcher.version`, which is null in a git checkout before the first release.
- Release installs that update themselves. `install.ps1`, which every release also attaches,
  installs the latest release, or `-Tag vX.Y.Z`, into `%LOCALAPPDATA%\Programs\local-ai-launcher`:
  the release in `versions\vX.Y.Z`, the file `current` that names it, and a `local-ai.cmd` that
  runs the version `current` names. `-AddToPath` adds that folder to the user Path, and
  `-Shortcuts` creates the Start menu shortcuts. It runs as a file or as `irm <address> | iex`,
  and refuses inside a packaged app.
- `update` first brings a release install to the latest release: it checks the release on
  GitHub, puts it into `versions` and hands over to it. The new version's plan starts with the
  line `Launcher: vOLD -> vNEW` and asks once. `update -Rollback` returns to the version before,
  which stays in `versions`. `start` checks for a newer release at most once a day and prints one
  line when one is out. A git checkout never updates its own code.
- `status` says how the launcher is installed and, for a release install, checks the active
  version against its manifest, names the version kept for a rollback and the latest release the
  last check found. `-Json` adds `launcher.kind`, `launcher.latest`, `launcher.checkedAt`,
  `launcher.updateAvailable` and `launcher.checkError`.
- The `Launcher` settings `Repo`, `CheckForUpdates`, `CheckIntervalHours`, `KeepVersions` and
  `RequireImmutable`.
- Releases also attach `install.ps1`, the zip's `src\install.ps1`. `SHA256SUMS` lists it, and the
  check of a published release compares it with the zip.

### Changed

- Open WebUI runs on Python 3.12 instead of 3.11.
- Open WebUI takes its settings from its environment at every start. Changes in *Admin
  Settings* revert at the next start, so put lasting settings in `OpenWebUI.Env`.
- Open WebUI lists only `local-chat`.
- ComfyUI runs from its pinned tag with core nodes only and with `--offline`. Its images go to a
  preview node, which ComfyUI keeps only in its temp folder until its next start.
- `stop` stops only the services that `start` recorded, instead of whatever listened on the
  ports.
- `stop` also quits the Ollama app when the launcher started it, and leaves an Ollama that
  already ran alone. It keeps the app running, and says why, while another program has a model
  loaded in it or is still connected to it, while the Ollama window is open, or while the app
  runs in another Windows session. It asks the app to quit as its tray icon does, and ends it
  with `taskkill /T /F` only when it has no window to ask or does not quit within 20 s.
  `update` and `uninstall` keep Ollama while they need it: `uninstall` quits the app at its end,
  and `update` quits only an app that it started itself, unless the stack runs at its end.
- When Ollama does not answer, the launcher starts the Ollama app itself, with the arguments
  the `ollama` program uses (`--hide --fast-startup`), instead of through `ollama list`, and
  records it in `state.json`. That includes the app Ollama's installer starts when `install`
  installs Ollama, and the one it starts again when `update -Tools` upgrades an app the
  launcher started. An app it cannot tell apart from another, or one started through
  `ollama list`, is not recorded, and `stop` leaves it running. It only waits, and starts
  nothing, while Ollama's installer runs, when `Ollama.Url` names another computer, or while
  another program holds its port.
- `status` says whether the launcher started the Ollama app, so that `stop` quits it, and notes
  a record of an app that no longer runs, or of one for another server than `Ollama.Url` names.
  `-Json` reports `ollama.startedByLauncher`, `ollama.appPid` and `ollama.appStartedUtc`.
- Ollama pulls the chat model from Hugging Face itself.
- The logs moved out of the Open WebUI and ComfyUI folders.
- `start` no longer points Qwen Code at the model. Run
  `ollama launch qwen --model local-chat --config --yes` once instead.
- Open WebUI, ComfyUI and the image gate no longer inherit the whole environment of the window
  that runs `start`, only an allow-list. `OpenWebUI.InheritEnvironment` and
  `ComfyUI.InheritEnvironment` name more variables, such as `HTTPS_PROXY`, for Open WebUI and
  for ComfyUI. `start` warns when an Open WebUI or a ComfyUI that it reuses inherited other
  variables.
- The git history was rewritten on 2026-10-31 and the GitHub repository was recreated. Example
  paths, addresses, host names and hardware details in the tests, comments and README were
  replaced with neutral values, and commit dates are recorded in UTC. Every commit ID changed:
  re-clone, or reset an existing clone with `git fetch` and `git reset --hard origin/main`. Do not
  pull or merge the old history.
- `update` reads `install-stamp.json` before it waits for Ollama, so it no longer starts the
  Ollama app only to say that `install` must run first.
- For a release install, the Start menu shortcuts run `local-ai.cmd` in the install folder. Its
  `uninstall` also removes that folder's entry from the user Path and deletes the folder once the
  window has closed.

### Removed

- The scripts `start-local-ai.ps1`, `start-local-ai.cmd`, `stop-local-ai.cmd`,
  `install-agent.ps1`, `install-shortcuts.ps1` and `local_agent_pipe.py`.
- The Local Agent pipe, which ran Qwen Code inside Open WebUI. Coding tools use Ollama's
  OpenAI-compatible API at `http://127.0.0.1:11434/v1` instead.
- Running Open WebUI with `WEBUI_AUTH` set to `False`. The launcher sets it to `True`.

To move from the earlier scripts, run `local-ai install`, then `local-ai update`. `update`
backs up Open WebUI's data first, then moves Open WebUI to 0.12.4 on Python 3.12. The data
folder that the earlier scripts made holds the account `admin@localhost` with Open WebUI's
default password, as they ran Open WebUI without sign-in. Sign in and change the password
at once. Run `local-ai shortcuts` to replace the old Start menu shortcuts. Delete the Local
Agent function in Open WebUI under *Admin Panel > Functions*; the launcher does not remove it.
`Model.SupersededAliases` is empty by default. To have `status` and `update` offer to remove
the old alias, set it in `settings.psd1` to
the name that the earlier scripts gave it, such as `@('old-chat')`.

When the earlier scripts made ComfyUI's `.venv` on the Microsoft Store Python, `update` also
makes it anew on a uv-managed Python; the Fixed entry below says how.

Open WebUI variables set in your Windows user environment, such as `WEBUI_NAME` or
`RAG_EMBEDDING_MODEL`, no longer reach Open WebUI. Put them in `OpenWebUI.Env` in
`settings.psd1`. The same goes for the variables that hold Open WebUI's own keys, such as
`WEBUI_SECRET_KEY`. Without it, Open WebUI makes a new key, which signs everyone out, and it
can no longer read what it encrypted with the old one, such as MFA secrets. If you set
`WEBUI_SECRET_KEY` in Windows, add its name to `OpenWebUI.InheritEnvironment` instead, which
keeps the key out of `settings.psd1`. Names that a proxy needs, such as `HTTPS_PROXY` or
`SSL_CERT_FILE`, go in `OpenWebUI.InheritEnvironment` or `ComfyUI.InheritEnvironment`. A
service that an earlier start left running keeps the environment it started with, so run
`local-ai stop`, then `local-ai start`.

### Fixed

- Each verb keeps its newest 20 transcripts also where Windows creates the new transcript file
  late, as on GitHub's hosted runners, where one more was kept.
- ComfyUI's `.venv` no longer stays on the Microsoft Store Python when `install` found it there,
  as in a venv that the earlier scripts made. Launches of the Store Python can fail or hang
  until Windows restarts, and ComfyUI and the image gate, which runs on the same venv, fail with
  them. `status` counts such a venv as a difference from the pins, and `start` and `install`
  warn about it. After a failed ComfyUI or image gate start, the repair hint names `update`
  instead of a reinstall that would launch the same Python. `update` makes the venv anew on a
  uv-managed Python 3.13: it moves the old venv aside to `<ComfyUI.Dir>.local-ai-old-venv`,
  installs the same pinned packages into the new one, which uv takes from its cache where it
  holds them, and deletes the old venv once the new one passes the torch check. When the new
  venv fails, it deletes it and moves the old one back. Models, input, output, user and
  custom_nodes stay; packages added to the venv by hand are not carried over. `uninstall`
  removes the new venv, and an old one that `update` left aside.

### Security

- Open WebUI asks for a sign-in, and sign-up closes after the first account.
- Open WebUI gets a content security policy that blocks content from other hosts, and HTML in
  answers runs no scripts by default. Web search, code execution and the update check are off.
- `local-ai.cmd` runs PowerShell with the execution policy `RemoteSigned` instead of `Bypass`.
- mcpo and the files server get only the environment variables that Windows, Python and
  Node.js need. Open WebUI, ComfyUI and the image gate get those that Windows and Python need.
  Open WebUI also gets the Hugging Face cache names and `HF_HUB_OFFLINE`, and ComfyUI the GPU
  and allocator names and `CUDA_PATH`. So a secret in another variable, such as
  `AWS_SECRET_ACCESS_KEY`, is in the environment of none of them. Code inside them still runs
  as your Windows user and can read your user variables in the registry. The Ollama app, which
  the launcher starts when Ollama does not answer, inherits the whole environment of that
  window until it quits; `stop` quits an app the launcher recorded unless it keeps it running
  for another program, its open window or another Windows session.
- Variables whose names end in `_TOKEN` or `_API_KEY`, and `PYTHONHOME`, `PYTHONPATH`,
  `PYTHONSTARTUP`, `PYTHONUSERBASE`, `NODE_OPTIONS` and `NODE_PATH`, reach no service, unless
  `OpenWebUI.Env` sets them for Open WebUI. The settings check refuses them in the
  `InheritEnvironment` lists.
- `.gitignore` also blocks mcpo's `files.key` and the `-wal`, `-shm` and `-journal` files of
  `webui.db`.
- The file tools are read-only and need an API key. `start` refuses a folder with names that
  look secret, such as `.env` or `*.key`, or with hard links to files outside it.
- The image gate refuses a request with a foreign `Host` or `Origin` header, and a browser's
  cross-site fetch.
- Dependabot also proposes updates for the files server's npm lockfile and the Python test
  requirements.
- Vulnerabilities are reported privately through GitHub's *Report a vulnerability* on the
  repository's Security tab, as SECURITY.md now says.
- gitleaks also scans the full history once a week. A push or pull request scans only its own
  commits, which the workflow comment and SECURITY.md now say instead of claiming a full scan.
- The files server's lockfile holds glob 14.0.3 and minimatch 11.0.3, through npm overrides, for
  GHSA-3g3m-2fjr-6pw4 (an aborted glob walk kept reading folders) and GHSA-g3hv-75wg-m249 (a
  minimatch pattern could grow into enough parts to use a lot of CPU and memory). glob 14.0.2,
  which Dependabot names as the fix, still bundles minimatch code from before the second fix.
  `@modelcontextprotocol/server-filesystem` 2.1.0, as 2.0.1, asks for glob 13 and minimatch 10,
  which have no fix. It never loads glob, and it calls minimatch without the optimization level that the
  flaw needs, so neither was reachable through the file tools. Where the file tools are set up,
  `local-ai update` runs npm ci again with the new lockfile.
- The launcher installs a release of itself only when it is tagged `vX.Y.Z`, is no draft or
  prerelease and is immutable, when its zip matches the digest GitHub lists, and when every file
  matches the manifest, which must name the commit of the tag. A failed check stops `update`
  before it changes anything. The extraction writes no more of an entry than the zip states for
  it. The `local-ai.cmd` of a release install runs only from its own folder, so a quoted
  `"local-ai"` that `cmd.exe` finds through the Path cannot run a version from the `versions`
  folder of the working folder. SECURITY.md describes what this trusts, also for
  `Launcher.Repo` and the one-liner.

[Unreleased]: https://github.com/Ochsyp/local-ai-launcher/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/Ochsyp/local-ai-launcher/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Ochsyp/local-ai-launcher/releases/tag/v1.0.0
