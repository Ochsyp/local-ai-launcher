# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There are no releases yet.

## [Unreleased]

The launcher was redesigned. These entries compare it with the earlier set of scripts.

### Added

- One launcher, `local-ai.cmd`, with the verbs `install`, `start [-NoBrowser]`, `stop`,
  `status [-Json]`, `update [-Tools]`, `uninstall [-RemoveData]` and `shortcuts [-Remove]`.
  Without a verb it runs `start`. It exits with 0 when done, 1 on a failure and 2 on warnings.
- `config\defaults.psd1`, which holds every default and every version pin.
  `%LOCALAPPDATA%\local-ai\settings.psd1` overrides it key by key. An unknown key or a value of
  the wrong kind is an error.
- Version pins: Open WebUI 0.12.4 on Python 3.12, ComfyUI v0.42.5 at commit `483dae4`, mcpo
  0.0.20 and `@modelcontextprotocol/server-filesystem` 2.0.1. The image checkpoint is pinned to
  a revision.
- SHA-256 checks for the chat model, its vision projector and the image checkpoint.
- The chat model `local-chat`, built from `config\local-chat.Modelfile` with a context of 32768
  tokens. It keeps the model's vision projector, so it reads images.
- The image gate, `src\image_gate.py`. Before each image it unloads `local-chat` from Ollama, so
  the image does not share the GPU's memory with the chat model.
- Optional read-only file tools: mcpo and the MCP files server let the model read one folder,
  `Files.Root`. `start` checks the folder before each start.
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

### Changed

- Open WebUI runs on Python 3.12 instead of 3.11.
- Open WebUI takes its settings from its environment at every start. Changes in *Admin
  Settings* revert at the next start, so put lasting settings in `OpenWebUI.Env`.
- Open WebUI lists only `local-chat`.
- ComfyUI runs from its pinned tag with core nodes only and with `--offline`. Its images go to a
  preview node, which ComfyUI keeps only in its temp folder until its next start.
- `stop` stops only the services that `start` recorded, instead of whatever listened on the
  ports.
- Ollama pulls the chat model from Hugging Face itself.
- The logs moved out of the Open WebUI and ComfyUI folders.
- `start` no longer points Qwen Code at the model. Run
  `ollama launch qwen --model local-chat --config --yes` once instead.

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

### Security

- Open WebUI asks for a sign-in, and sign-up closes after the first account.
- Open WebUI gets a content security policy that blocks content from other hosts, and HTML in
  answers runs no scripts by default. Web search, code execution and the update check are off.
- `local-ai.cmd` runs PowerShell with the execution policy `RemoteSigned` instead of `Bypass`.
- mcpo and the files server get only the environment variables that Windows, Python and
  Node.js need. Variables whose names end in `_TOKEN` or `_API_KEY` reach no service, unless
  `OpenWebUI.Env` sets them for Open WebUI.
- The file tools are read-only and need an API key. `start` refuses a folder with names that
  look secret, such as `.env` or `*.key`, or with hard links to files outside it.
- The image gate refuses a request with a foreign `Host` or `Origin` header, and a browser's
  cross-site fetch.
- Dependabot also proposes updates for the files server's npm lockfile and the Python test
  requirements.

[Unreleased]: https://github.com/Ochsyp/local-ai-launcher/commits/main
