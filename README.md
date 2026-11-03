# local-ai-launcher

[![CI](https://github.com/Ochsyp/local-ai-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/Ochsyp/local-ai-launcher/actions/workflows/ci.yml)

A launcher for a local AI stack on one Windows PC. **Ollama** serves the chat model
`local-chat`, **Open WebUI** is the chat front end, **ComfyUI** draws images, an **image gate**
frees the GPU for each image, and optional **file tools** let the model read one folder.
`local-ai.cmd` installs, starts, stops, checks, updates and removes the stack.

## What it runs

| Service | Address | Runs when |
|---|---|---|
| Ollama, with an OpenAI-compatible API under `/v1` | `http://127.0.0.1:11434` | always; the Ollama tray app, which the launcher starts when it does not run |
| Open WebUI 0.12.4 | `http://127.0.0.1:8080` | always |
| ComfyUI v0.42.5 | `http://127.0.0.1:8188` | `Images.Enabled` is `$true` (the default) |
| Image gate (`src\image_gate.py`) | `http://127.0.0.1:8190` | `Images.UnloadChat` is `$true` (the default) |
| File tools (mcpo and the files server) | `http://127.0.0.1:8189` | `Files.Root` names a folder |

The launcher starts every service on `127.0.0.1` only. Ollama is the one exception: the Ollama
app chooses its own bind address. The launcher never sets `OLLAMA_HOST`, and `install`,
`start` and `status` warn when Ollama listens beyond loopback. If that happens, turn off *Expose Ollama to
the network* in the Ollama app's settings and restart the app.

The launcher never runs `ollama serve`. When Ollama does not answer, `install`, `start`,
`update` and `uninstall` start the Ollama app hidden, as the `ollama` program does:
`ollama app.exe --hide --fast-startup` from the folder of `ollama.exe`. When the app is not
there, they run `ollama list` instead. They only wait, and start nothing, while Ollama's
installer runs, when `Ollama.Url` names another computer, or while another program holds its
port.

The launcher records in `state.json` an Ollama app that it started, and `local-ai stop` quits
that app again. That includes the app Ollama's installer starts when `install` installs Ollama,
and the one it starts again when `update -Tools` upgrades an app the launcher started. An app
started through `ollama list`, or one the launcher cannot tell apart from another app, is not
recorded; the launcher says so, and `stop` leaves it running. An Ollama that already ran keeps
running. So does an app the launcher started while another program has a model loaded in it or
is still connected to it, while the Ollama window is open, or while it runs in another Windows
session, whose windows `stop` cannot see; `stop` then says so.

After you point `Ollama.Url` at another server, run `local-ai stop` before `start` or `update`.
Until then `status` names the app the launcher recorded for the old server, and `stop` quits it.
Once `start` runs, also the start that `update` runs for its check, the launcher forgets that
app, and it keeps running until you quit it from its tray icon.

## Requirements

- Windows 10 or 11 with `winget`.
- Windows PowerShell 5.1. `local-ai.cmd` runs `powershell.exe`; PowerShell 7 is not used.
- An NVIDIA GPU for images, with a driver for the CUDA 13.0 builds of PyTorch that ComfyUI
  gets. Chat uses the GPU too. The settings are tuned for an NVIDIA GPU with a mid-range amount of
  VRAM. `local-chat` reads images, so it needs about 2 GB of VRAM beyond the text model.
- Free disk space. `install` checks each part first and wants its size plus 10 percent: the
  chat model about 8.3 GB, Open WebUI about 3 GB, ComfyUI's environment about 4.6 GB and the
  image checkpoint about 6.9 GB.
- An internet connection for `install` and `update`.

`install` gets these with `winget` when they are missing:

| Package | When | Scope |
|---|---|---|
| Ollama (`Ollama.Ollama`) | always | user |
| uv (`astral-sh.uv`) | always | user |
| Git (`Git.Git`) | with `Images.Enabled` | user |
| Node.js LTS (`OpenJS.NodeJS.LTS`) | only for the file tools | machine; Windows asks for administrator approval |

uv then installs Open WebUI and mcpo as uv tools, and the Pythons they need.

## Quick start

1. Clone the repository. If you downloaded it as a ZIP file, unblock the files first, since
   Windows refuses to run downloaded scripts:

   ```powershell
   Get-ChildItem -LiteralPath 'C:\path\to\local-ai-launcher' -Recurse -File | Unblock-File
   ```

2. Open a console window or Windows Terminal in the repository folder. Do not use a terminal
   inside a packaged app; see [Where to run it](#where-to-run-it).
3. Run `.\local-ai.cmd install`. The first install downloads several GB.
4. Run `.\local-ai.cmd start`. The browser opens Open WebUI at `http://127.0.0.1:8080`.
5. Create your account. On a fresh data folder the first account becomes the admin; see
   [Signing in](#signing-in).
6. Optionally run `.\local-ai.cmd shortcuts` for Start menu shortcuts.

In `cmd.exe` in the repository folder, `local-ai start` works as well. The launcher's own
messages write commands that way. `local-ai.cmd` without a verb runs `start`.

`local-ai.cmd` sets the execution policy `RemoteSigned` for its own run only, so the PC's
policy stays as it is. The window pauses after `status` and after any exit code other than 0,
so a window that a shortcut opened stays readable. With `-Json` it never pauses.

## Commands

| Command | What it does |
|---|---|
| `local-ai install` | Installs what is missing: the winget packages, the chat model, Open WebUI, and with their settings the file tools and ComfyUI with its checkpoint. It never changes an installed Open WebUI version; that is `update`'s job. |
| `local-ai start [-NoBrowser]` | Runs `install` first when parts are missing. Starts ComfyUI, the image gate, the file tools and Open WebUI, then opens the browser unless `-NoBrowser` is given. It prints the web address and the endpoint for coding tools. |
| `local-ai stop` | Stops what `start` started, unloads `local-chat` and quits the Ollama app when the launcher started it. An Ollama that already ran keeps running, and so does one that holds another program's model, still has another program connected, such as a coding tool on the `/v1` endpoint, or shows its window. |
| `local-ai status [-Json]` | Reports what runs and what needs attention, and changes nothing. `-Json` prints one line of JSON and nothing else. |
| `local-ai update [-Tools]` | Brings every part to the versions the settings pin (`config\defaults.psd1`, or `settings.psd1` where it sets a pin), after it shows the plan and you confirm. `-Tools` also upgrades the winget packages. |
| `local-ai uninstall [-RemoveData]` | Removes what `install` set up, after you confirm. `-RemoveData` also deletes the data folders. |
| `local-ai shortcuts [-Remove]` | Creates the Start menu shortcuts, or with `-Remove` deletes them. |

A switch that does not belong to the verb is an error. `start` does not wait: while any other
launcher run is active, it stops at once with exit code 1. `install`, `stop`, `update`,
`uninstall` and `shortcuts` wait up to 300 s for another run to finish. `status` runs beside
any of them.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Done. For `status`: everything the settings turn on runs and is healthy. |
| 1 | Failed. For `status`: Ollama or Open WebUI is down or not running. |
| 2 | Done, with warnings. For `status`: degraded. |

By verb:

- `install`: 2 when a step warned, or when the file tools or images failed while chat works.
  1 when Ollama, uv, the chat model or Open WebUI failed.
- `start`: 2 when it started with warnings, for example with images or file tools off.
  1 when Open WebUI did not come up.
- `stop`: 1 when something could not be stopped, such as an Ollama app the launcher started.
- `update`: 2 when it finished with warnings or you declined the plan. 1 when it failed.
- `uninstall`: 0 also when you decline. 1 when something stays.
- Every verb returns 1 on an error, for example a refused run inside a packaged app.

`status` advice lines never change the exit code.

## What status checks

`status` reads only. It never starts the Ollama app. Its sections are:

- **Launcher**: the repository and state folder, another run in progress, settings that do not
  load, and packaged-app redirection.
- **Ollama**: the version, whether the launcher started the Ollama app, so that `stop` quits
  it, whether it listens beyond loopback, the loaded models and their share of VRAM, whether
  `local-chat` exists, and superseded aliases it still holds.
- **Services**: each service's process, port, version and pin.
- **GPU and Ollama environment**: what `nvidia-smi` reports, and `OLLAMA_KV_CACHE_TYPE`.
- **File tools folder**: whether `start` would serve `Files.Root`, and why not.
- **Pins**: what `install-stamp.json` records against the pins. A difference names
  `local-ai update`; a missing part names `local-ai install`.
- **Doctor checks**: the PowerShell version, Group Policy execution policies, launcher files
  that carry the download mark (`Zone.Identifier`), and the page file.
- **Logs**: the log files, the last error of the newest launcher run, and partial downloads
  left behind.

## Start menu shortcuts

`local-ai shortcuts` creates three shortcuts in
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Local AI`:

- **Start Local AI** runs `local-ai.cmd start`.
- **Stop Local AI** runs `local-ai.cmd stop`.
- **Status Local AI** runs `local-ai.cmd status`.

They use the Ollama app's icon when it is installed. `install` creates no shortcuts. The
shortcuts point at this repository, so run `local-ai shortcuts` again after you move it.
`local-ai shortcuts -Remove` deletes the three shortcuts, and the folder when it is then empty.
`Shortcuts.Folder` sets another folder.

## Where to run it

Run `local-ai.cmd` from a console window, Windows Terminal or the Start menu shortcuts.

Do not run it from a terminal inside a packaged app, such as the Claude desktop app. Windows
puts the folders that such an app's processes create in `%LOCALAPPDATA%` and `%APPDATA%` into
the package's private store. Other windows never see them there. The launcher detects this.
Every verb but `status` then refuses to run and changes nothing, and `status` reports it.

A private copy of `%LOCALAPPDATA%\local-ai` below `%LOCALAPPDATA%\Packages` also blocks every
verb but `status`. Check whether the copy holds logs or state that the real folder lacks, then
move it out of `%LOCALAPPDATA%\Packages`.

## Settings

`config\defaults.psd1` holds every default and every version pin. To change a setting, put
the same keys in `%LOCALAPPDATA%\local-ai\settings.psd1`. Do not edit the tracked file.

- Tables merge key by key. Single values and lists replace the default.
- An unknown key or a value of the wrong kind is an error. Then only `stop`, `status` and
  `uninstall` run until you fix it.
- `%VAR%` expands in every string. Paths that start with `config\` are relative to the
  repository.

An example `settings.psd1`:

```powershell
@{
    Files     = @{ Root = 'C:\AI-Files' }
    Images    = @{ UnloadChat = $true }
    OpenWebUI = @{ Env = @{ RAG_EMBEDDING_MODEL_AUTO_UPDATE = 'False' } }
}
```

Common keys:

| Key | Default | Purpose |
|---|---|---|
| `Model.Alias` | `'local-chat'` | The model name Open WebUI and coding tools use. It stays when the weights change. |
| `Model.Modelfile` | `'config\local-chat.Modelfile'` | Context length (32768), template and sampling. A copy at `%LOCALAPPDATA%\local-ai\local-chat.Modelfile` replaces it. |
| `Model.SupersededAliases` | `@()` | Aliases of earlier chat models. `status` lists those Ollama still holds, and `update` offers to remove each one. Never `Model.Alias` or `Model.Source`. |
| `Ports.OpenWebUI`, `.ComfyUI`, `.Files`, `.ImageGate` | 8080, 8188, 8189, 8190 | Loopback ports, each from 1024 to 65535 and distinct. |
| `Ollama.Url` | `''` | Empty: `OLLAMA_HOST`, else `http://127.0.0.1:11434`. |
| `Images.Enabled` | `$true` | `$false` skips ComfyUI and turns Open WebUI's image button off. |
| `Images.UnloadChat` | `$true` | Send images through the image gate, which unloads `local-chat` first. |
| `Files.Root` | `''` | The one folder the file tools may read. Empty turns them off. |
| `OpenWebUI.Env` | a table | Open WebUI's environment for every start. Any key is accepted, and an empty value removes the variable. |
| `OpenWebUI.InheritEnvironment` | `@()` | More variable names that Open WebUI inherits from the window that runs `start`, such as `HTTPS_PROXY`. |
| `OpenWebUI.DataDir` | `'%LOCALAPPDATA%\open-webui'` | Open WebUI's database, uploads and secret key. |
| `ComfyUI.Dir` | `'%USERPROFILE%\ComfyUI'` | The ComfyUI checkout, at most 133 characters. |
| `ComfyUI.InheritEnvironment` | `@()` | More variable names that ComfyUI, not the image gate, inherits from the window that runs `start`. |
| `Update.KeepBackups` | 3 | How many of its own Open WebUI backups `update` keeps. |

Open WebUI runs with `ENABLE_PERSISTENT_CONFIG` set to `False`. So `OpenWebUI.Env` wins over
the database, and changes in *Admin Settings* revert at the next start. Put any lasting Open
WebUI setting in `OpenWebUI.Env`. The launcher sets some variables itself, such as
`DATA_DIR`, `OLLAMA_BASE_URL`, the image keys and `TOOL_SERVER_CONNECTIONS`. It ignores those
in `OpenWebUI.Env` with a warning.

Open WebUI reads its environment only when it starts, so run `stop` and then `start` after a
change. After you change a pin, `status` shows under **Pins** whether `install` or `update`
applies it.

Open WebUI, ComfyUI, the image gate and mcpo do not inherit your whole environment. Open WebUI,
ComfyUI and the image gate get only the variables that Windows and Python need, those the
launcher sets for them, and a few more: for Open WebUI the Hugging Face cache names, such as
`HF_HOME`, and `HF_HUB_OFFLINE`; for ComfyUI `CUDA_VISIBLE_DEVICES`, `CUDA_DEVICE_ORDER`,
`PYTORCH_CUDA_ALLOC_CONF`, `PYTORCH_ALLOC_CONF` and `CUDA_PATH`. [SECURITY.md](SECURITY.md)
lists them all. So a setting in your Windows user variables reaches Open WebUI only through
`OpenWebUI.Env`, or through `OpenWebUI.InheritEnvironment`, which passes the window's value on.
For a proxy, `OpenWebUI.InheritEnvironment = @('HTTPS_PROXY')` keeps a password in the proxy
address out of `settings.psd1`, but Open WebUI and the tools and functions inside it can still
read it. The settings check refuses a name that ends in `_TOKEN` or `_API_KEY`, and
`PYTHONHOME`, `PYTHONPATH`, `PYTHONSTARTUP`, `PYTHONUSERBASE`, `NODE_OPTIONS` and `NODE_PATH`:
none of these services inherits those. The Ollama app is the exception: when the launcher
starts it, it inherits the whole environment of that window.

## Signing in

Open WebUI runs with `WEBUI_AUTH` set to `True` and `ENABLE_SIGNUP` set to `False`. On a fresh
data folder, Open WebUI 0.12.4 still lets the first account sign up, and that account becomes
the admin. After that, sign-up is closed. A data folder that already holds accounts keeps them.

Other settings the launcher sets for Open WebUI:

- `ENV` is `prod`, so Open WebUI does not serve `/docs` and `/openapi.json` at all.
- A content security policy keeps the page, and the HTML that answers render, from loading
  anything from other hosts.
- HTML in answers opens as an artifact only on request and runs no scripts. Each account can
  change this under *Settings > Interface*.
- Web search, code execution, community sharing and the update check are off.

## Images

With `Images.Enabled`, `install` clones ComfyUI v0.42.5 into `ComfyUI.Dir` with its own uv
environment and the CUDA 13.0 build of PyTorch. It downloads the SDXL checkpoint
`DreamShaperXL_Lightning.safetensors` at a pinned revision and checks its SHA-256. Open WebUI's
image button then renders 1024x1024 images in 6 steps through ComfyUI.

- ComfyUI runs with its core nodes only and with `--offline`. The launcher drops flags such as
  `--listen`, `--enable-manager` and `--enable-cors-header` from `ComfyUI.Args`.
- Images are on only for a `start` that launches ComfyUI. Otherwise the image button is off.
- Image editing is off, because no editing workflow is set up.
- The workflow ends in a preview node, which ComfyUI keeps only in its temp folder until its
  next start.

### The image gate

An image is slow while `local-chat` holds the GPU's memory. With `Images.UnloadChat`, Open
WebUI sends images to the image gate on port 8190 instead of to ComfyUI. Before each
image, the gate unloads `local-chat` from Ollama and waits until Ollama no longer lists it.
Then it forwards the image to ComfyUI.

- On the test GPU: about 8 s per image instead of 32 to 38 s.
- The next chat reloads `local-chat`, which takes 7 to 10 s.
- The gate waits at most `Images.UnloadTimeoutSeconds` (30 s), an answer still streaming
  included. On an Ollama error or a timeout it logs a warning and forwards the image anyway.
- It unloads only `Model.Alias`, and only from an Ollama on a loopback address.
- It refuses requests from web pages: a foreign `Origin`, a cross-site fetch or a foreign
  `Host`.
- Its log holds one line per event, never prompt text.

With `Images.UnloadChat = $false`, Open WebUI talks to ComfyUI directly and no gate runs.

### Page file

Each reload of `local-chat` after an image commits about 11 GB of virtual memory. On a PC
with little RAM and a system-managed page file that Windows has shrunk, a reload can fail
with `CUDA error: shared object initialization failed`.

Set a fixed page file of about 20 GB or more under *System Properties > Advanced > Performance
Settings > Advanced > Virtual memory > Change*. The launcher never changes the page file.
`status` gives this advice while images unload chat and the page file is system-managed or
smaller than 20 GB.

## File tools

The file tools let the model read one folder. To turn them on:

1. Create a dedicated folder that only you write to and that holds nothing secret. A short
   path such as `C:\AI-Files` works best.
2. Set `Files.Root` to it in `settings.psd1`.
3. Run `local-ai install`. It installs Node.js, mcpo 0.0.20 and
   `@modelcontextprotocol/server-filesystem` 2.0.1 from the lockfile in `config\files-server`,
   and creates the key file.
4. Run `local-ai start`.

Open WebUI offers them as **Workspace files**: `read_text_file`, `list_directory`,
`search_files`, `get_file_info` and `list_allowed_directories`. The tools are read-only. Every
write tool is hidden, and the settings check refuses a `Files.DisabledTools` that leaves one
out. Only the admin account gets the tools.

Each `start` checks the folder first. It leaves the file tools off, with a warning, when
`Files.Root`:

- is not a full path on a drive letter, or is a drive root;
- is `%USERPROFILE%` or a folder above it;
- is a link (a junction or symbolic link), or has one on its path;
- lies in or around `%LOCALAPPDATA%\local-ai`, this repository, uv's tool folder,
  `OpenWebUI.DataDir` or `ComfyUI.Dir`;
- holds a file or folder whose name matches `Files.DenyPatterns`, such as `.env`, `*.key`,
  `*secret*`, `.git` or `.ssh`;
- holds a hard link to a file that also has a name outside it, as a `.venv` that uv made does;
- holds a folder this account cannot list, or more than 100000 entries.

The check does not follow links inside the folder; the files server refuses those that lead
outside it. Files added while mcpo runs are not checked. `status` shows under **File tools
folder** whether `start` would serve the folder.

Know these limits:

- The model may quote any file in the folder.
- NTFS alternate data streams, such as `file.txt:Zone.Identifier`, are readable too.
- `read_text_file` returns a whole file unless the model asks for its head or tail. A text file
  of about 300 KB overflows `local-chat`'s 32K context and leaves the answer unusable.
- The mcpo API key lives in `%LOCALAPPDATA%\local-ai\files.key`, which only your account may
  open. mcpo 0.0.20 takes the key only on its command line, so other programs that run as the
  same user can read it there, as they can in Open WebUI's `TOOL_SERVER_CONNECTIONS`.
- mcpo and the files server get only the environment variables Windows, Python and Node.js
  need, so no secret from your console window reaches them. Their list is fixed and narrower
  than Open WebUI's, and neither `InheritEnvironment` setting adds to it.

## The model list and tools in chats

Open WebUI lists only `local-chat`, because the launcher sets `OLLAMA_API_CONFIGS` to that
model. Your other Ollama models stay hidden there. To list them all, set
`OpenWebUI.Env.OLLAMA_API_CONFIGS = ''`. The image gate unloads only `local-chat`, so another
model stays in VRAM while an image renders.

With the file tools on, every new chat starts with **Workspace files** selected. A model saved
in *Workspace > Models* keeps the tools it was saved with instead, so turn on **Workspace
files** there. To change Open WebUI's built-in tools for every model, set
`OpenWebUI.Env.DEFAULT_MODEL_METADATA`, for example to `'{"builtinTools":{"notes":false}}'`.

## Using local-chat from coding tools

Ollama serves an OpenAI-compatible API at `http://127.0.0.1:11434/v1`. Use the model name
`local-chat`. `start` prints this endpoint.

To point Qwen Code at it:

```text
ollama launch qwen --model local-chat --config --yes
```

- Ollama answers one request at a time, so a coding tool and a chat wait for each other.
- The context is 32768 tokens, as `config\local-chat.Modelfile` sets it.
- After an image, the next request reloads `local-chat` first.

## Updates and backups

`local-ai update` compares what is installed with the pins in the settings: those of
`config\defaults.psd1`, and those that `settings.psd1` sets instead. When something differs, it
shows the plan and asks. Then it:

1. stops the stack, but not Ollama, which it still needs;
2. backs up Open WebUI's data to `%LOCALAPPDATA%\local-ai\backups` before it changes Open
   WebUI: `webui.db` with its `-wal` and `-shm` files, `.webui_secret_key`, `uploads`,
   `vector_db` and the old package versions;
3. updates Open WebUI, ComfyUI (moved to its tag), the file tools, the model and the
   checkpoint, as needed, and with `-Tools` also the winget packages: uv, Git with images,
   Node.js and Ollama;
4. starts the stack and checks each service;
5. rolls Open WebUI back when the new version fails the check: it reinstalls the old version
   with its saved package versions and restores the data from the backup;
6. when the update did not fail, offers to remove each superseded alias that Ollama still
   holds, with its own question;
7. leaves the stack running only when it ran before.

When everything already matches its pin, `update` changes nothing else but still makes that
offer.

`update` leaves Ollama as it found it. When Ollama did not answer at its start, `update` quits
the Ollama app it started again at its end, also when it ends early, unless the stack runs then.
An Ollama that answered at its start keeps running.

A rollback moves the data the new version used to `backups\open-webui-failed-<time>`, which
nothing deletes. `update` keeps the newest `Update.KeepBackups` (3) of its own backups, and
deletes older ones only after the new version passed the check. The backup that `install`
makes of an existing `webui.db` stays as well.

Ollama's installer stops the Ollama app and any loaded model, so `update -Tools` upgrades
Ollama last. `-Tools` upgrades Node.js only when `install` put it in. Run `local-ai install`
first when `install-stamp.json` records no install yet.

## Uninstall

`local-ai uninstall` lists what it removes and asks once; the default answer is No. Then it
stops the stack and removes:

- the Start menu shortcuts;
- the uv tools `open-webui` and `mcpo`, when `install-stamp.json` records them;
- ComfyUI's `.venv`, when `install` created it;
- the files server, `files.key` and mcpo's configuration;
- the Ollama model `local-chat`. The weights of `Model.Source` stay in Ollama.

Last it quits the Ollama app when the launcher started it, as `stop` does. It keeps Ollama, uv,
Git, Node.js and every other Ollama model, and prints the `winget uninstall` commands for them.
Your data stays as well.

`local-ai uninstall -RemoveData` also deletes, after you type `delete`:

- Open WebUI's data folder: accounts, chats, uploads, knowledge and its secret key;
- the ComfyUI checkout, with its models and output, only when `install` cloned it;
- `%LOCALAPPDATA%\local-ai`: `settings.psd1`, the state files, the logs and Open WebUI's
  backups. When uninstall keeps an Ollama app the launcher started running, as `stop` would,
  it says so: once `state.json` is gone, quit that app from its tray icon.

It never deletes `Files.Root`, `OLLAMA_MODELS`, a ComfyUI checkout that `install` did not
clone, your profile or other system folders, or this repository. `stop`, `status` and
`uninstall` also work when `settings.psd1` does not load.

## Where data lives

Nothing is written inside this repository.

| Data | Location |
|---|---|
| Launcher settings, `state.json`, `install-stamp.json`, logs, backups, `files.key`, the files server | `%LOCALAPPDATA%\local-ai` |
| Open WebUI's database, uploads and secret key | `%LOCALAPPDATA%\open-webui` (`OpenWebUI.DataDir`) |
| Open WebUI and mcpo | uv's tool folder (`uv tool dir`) |
| Open WebUI's embedding model, downloaded at its first start | `%USERPROFILE%\.cache\huggingface` |
| ComfyUI, its `.venv` and the checkpoint | `%USERPROFILE%\ComfyUI` (`ComfyUI.Dir`) |
| The chat model | Ollama's store (`OLLAMA_MODELS`, else `%USERPROFILE%\.ollama\models`) |
| Start menu shortcuts | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Local AI` |

## Logs

The service logs are in `%LOCALAPPDATA%\local-ai\logs`: `open-webui.log`, `comfyui.log`,
`imagegate.log` and `files.log`, each with an `.err.log`. The launcher keeps 5 rotated copies
of each (`Logs.Keep`). Each run also writes a transcript there. Those of `status` and
`uninstall` go to `%TEMP%`. The newest 20 transcripts of each verb are kept, for at most 14
days. When a verb stops on an error, it prints the path of its transcript.

## Security notes

Use the stack only on a single-user PC you trust.

- Every service the launcher starts listens on `127.0.0.1` only, and `install`, `start` and
  `status` warn when Ollama, whose app picks its own address, listens beyond loopback. Any program on this PC can
  reach those ports. Ollama and ComfyUI have no sign-in. Never expose the ports beyond the
  machine.
- Open WebUI asks for a sign-in, and its CORS setting allows only its own local address.
- The file tools' key is readable by other programs of the same user; see
  [File tools](#file-tools).
- Open WebUI gets `NO_PROXY` with `127.0.0.1`, `localhost` and `::1` added, so no proxy sees
  the file tools' key or the files they read.
- Open WebUI, ComfyUI, the image gate and mcpo inherit only the environment variables on their
  allow-lists, so a secret in any other variable, such as `AWS_SECRET_ACCESS_KEY`, is not in
  their environment. Code inside them runs as your Windows user, so it can still read your user
  variables in the registry. When the launcher starts the Ollama app, the app and the Ollama
  server it runs inherit the whole environment of that window until the app quits; `local-ai
  stop` quits it unless it keeps it running for one of the reasons in
  [What it runs](#what-it-runs). An app that already ran keeps the environment it started with.
  See [Settings](#settings).

[SECURITY.md](SECURITY.md) has the security policy, where secrets live and the known limits.

## Development

Run the checks in Windows PowerShell 5.1 from the repository root. They need PSScriptAnalyzer
1.25.0 and Pester 6.2.0:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-checks.ps1
```

The script points `LOCALAPPDATA` at a temporary folder, so the tests leave the real install
alone.

The image gate tests need a Python 3.12 or newer that has the packages in
`tests\requirements.txt`:

```text
<python> -I -B -m unittest discover -s tests -p "test_*.py"
```

CI (`.github\workflows\ci.yml`) runs the same checks on `windows-latest`.
[CHANGELOG.md](CHANGELOG.md) lists the changes.

Every change reaches `main` through a reviewed pull request. [CONTRIBUTING.md](CONTRIBUTING.md)
describes the branches, the changelog entry and the git hooks that refuse commits and pushes to
`main`. Turn the hooks on once per clone:

```text
git config core.hooksPath .githooks
```

## Repository layout

```text
local-ai.cmd                        entry point; runs src\local-ai.ps1 with Windows PowerShell 5.1
src\local-ai.ps1                    parses the verb and switches, then calls Invoke-LocalAI
src\LocalAI.psm1                    the launcher: settings, install, start, stop, status, update, uninstall, shortcuts
src\image_gate.py                   the image gate in front of ComfyUI
config\defaults.psd1                every default setting and version pin
config\local-chat.Modelfile         builds the local-chat alias in Ollama
config\comfyui\                     the image workflow, its node mapping for Open WebUI, and the torch pins
config\files-server\                package.json and lockfile of the files server
tests\LocalAI.Tests.ps1             Pester tests for the module
tests\Config.Tests.ps1              Pester checks on the tracked configuration
tests\test_image_gate.py            unittest tests for the image gate
tests\run-checks.ps1                runs PSScriptAnalyzer and the Pester tests
tests\requirements.txt              Python packages the image gate tests need
PSScriptAnalyzerSettings.psd1       PSScriptAnalyzer rules
.githooks\                          refuse commits and pushes to main
.github\                            CI, gitleaks secret scan, Dependabot and the pull request template
.editorconfig, .gitattributes       editor settings and line endings
.gitignore                          keeps secrets, weights and logs out of git
SECURITY.md                         security policy
CHANGELOG.md                        changes
CONTRIBUTING.md                     how changes reach main
LICENSE                             MIT License
```

## Third-party software

The launcher downloads and runs third-party software and model weights: Ollama, uv, Python,
Open WebUI, Git, ComfyUI, PyTorch, Node.js, mcpo, the MCP files server, their dependencies,
and the chat and image models. Each is under its own licence. None of it is redistributed here.

## License

MIT License.
