# local-ai-launcher

One-click launcher for a fully local AI stack on Windows: **Ollama** serves the chat
model, **Open WebUI** is the chat front end, **ComfyUI** generates images, and an
optional read-only **Local Agent** runs Qwen Code from inside Open WebUI.

> **Status:** repository bootstrap. The scripts are imported in the next commit;
> full documentation and diagrams follow.

## What it does

`start-local-ai.ps1` brings the whole stack up from nothing:

1. Installs whatever is missing: Ollama, uv, Open WebUI, Git, and ComfyUI with the
   CUDA 13.0 build of PyTorch.
2. Downloads a GGUF chat model from Hugging Face and imports it into Ollama under an
   alias that bakes in the context length.
3. Downloads an SDXL Lightning checkpoint for ComfyUI and, once, points Open WebUI's
   image generation at it.
4. Starts Open WebUI and ComfyUI hidden, bound to `127.0.0.1`, starts `ollama serve`
   hidden unless an Ollama server (usually the tray app) already answers, and opens the
   browser.

`-Stop` shuts Open WebUI and ComfyUI down and unloads the model; Ollama itself keeps
running. It finds the two services by port and force-kills whatever listens on `-Port`
and `-ComfyPort`, so keep other programs off those ports.

| Service | Address |
|---|---|
| Ollama (OpenAI-compatible API under `/v1`) | `http://127.0.0.1:11434` |
| Open WebUI | `http://127.0.0.1:8080` |
| ComfyUI | `http://127.0.0.1:8188` |

## Requirements

- Windows 10 or 11 with `winget`
- Windows PowerShell 5.1 (the launchers call `powershell.exe`)
- An NVIDIA RTX GPU with a CUDA 13.0-capable driver and enough VRAM for the chosen
  model and context length
- Plenty of free disk space: during import the GGUF exists twice (the staging copy and
  Ollama's own), and the SDXL checkpoint, PyTorch and uv's caches add several GB each
- For the Local Agent only: Node.js and `npm install -g @qwen-code/qwen-code`

## Quick start

| Action | How |
|---|---|
| Start everything | Double-click `start-local-ai.cmd` |
| Stop | Double-click `stop-local-ai.cmd` |
| Start Menu shortcuts | `powershell -ExecutionPolicy Bypass -File .\install-shortcuts.ps1` (`-Remove` undoes it; rerun after moving the folder) |

The `.cmd` launchers bypass the execution policy for their own run only. The `.ps1`
helpers need the same `-ExecutionPolicy Bypass` call on a default Windows install.

### Local Agent

1. Install Node.js and Qwen Code (`npm install -g @qwen-code/qwen-code`).
2. Run `start-local-ai.cmd`; it points Qwen Code at the local model.
3. While Open WebUI is running:
   `powershell -ExecutionPolicy Bypass -File .\install-agent.ps1` (add `-Port <port>`
   if you changed the launcher's port).
4. In Open WebUI, open *Admin Panel > Functions > Local Agent > Valves* and set
   `WORKDIR` to the folder the agent may read (and `NODE`, if Node.js is not in
   `C:\Program Files\nodejs`).

## Configuration

`start-local-ai.ps1` parameters; the defaults sit at the top of the script.

| Parameter | Purpose |
|---|---|
| `-HfRepo`, `-HfFile` | Hugging Face GGUF chat model to import. `-HfRepo ''` pulls `-Model` from the Ollama library instead |
| `-Model` | Ollama library model used when `-HfRepo` is empty |
| `-ContextLength` | Context window baked into the Ollama alias (default `32768`) |
| `-ImageRepo`, `-ImageFile` | ComfyUI checkpoint. `-ImageRepo ''` skips ComfyUI |
| `-GgufDir`, `-ComfyDir` | Model staging folder and ComfyUI install folder |
| `-Port`, `-ComfyPort` | Open WebUI and ComfyUI ports (`8080`, `8188`) |
| `-Stop` | Stop Open WebUI and ComfyUI and unload the model instead of starting; Ollama keeps running |

Change the defaults in the script rather than passing arguments: `-Stop` derives the
model alias from the same defaults. Set `HF_TOKEN` in the environment to download gated
or private Hugging Face models.

## Security model

Use the stack only on a single-user PC you trust.

- Open WebUI and ComfyUI listen on `127.0.0.1` only, and Open WebUI's CORS allows only
  its own local origin. Ollama keeps its own bind address, `127.0.0.1` unless
  `OLLAMA_HOST` says otherwise; the launcher does not set it, so make sure it is not
  `0.0.0.0`.
- Open WebUI runs with login disabled (`WEBUI_AUTH=False`), a setting it fixes at its
  first launch. Anything that can reach its port, including any program or other
  Windows user on this PC, signs in as its admin and can install Functions that run
  Python as you. Ollama and ComfyUI have no authentication either. Never expose their
  ports beyond the machine.
- The Local Agent runs Qwen Code in plan (read-only) mode behind a tool allow-list. It
  can read everything in its `WORKDIR`, secrets included, and anything it quotes stays
  in Open WebUI's chat history. `WORKDIR` defaults to a fixed folder set in
  `local_agent_pipe.py`; point it at a folder that holds no secrets before first use.

## Where data lives

Nothing is written inside this repository.

| Data | Location |
|---|---|
| Open WebUI database, logs and signing key | `%LOCALAPPDATA%\open-webui` |
| Open WebUI itself and its Python environment | uv's tool directory (`uv tool dir`) |
| Python builds and the package cache, PyTorch wheels included | uv's Python and cache directories (`uv python dir`, `uv cache dir`) |
| ComfyUI, its virtual environment and checkpoints | `%USERPROFILE%\ComfyUI` |
| GGUF staging, deleted after import | `%USERPROFILE%\models` |
| Imported models | Ollama's own model store |
| Qwen Code's model setting | `%USERPROFILE%\.qwen\settings.json`, rewritten by the launcher |
| Start Menu shortcuts | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Local AI` |

## Repository layout

```text
start-local-ai.cmd      double-click launcher
stop-local-ai.cmd       double-click stopper
start-local-ai.ps1      installs, downloads, starts, configures and stops the stack
install-shortcuts.ps1   creates or removes the Start Menu shortcuts
install-agent.ps1       pushes the Local Agent pipe into Open WebUI
local_agent_pipe.py     Open WebUI Pipe function that runs Qwen Code
```

## Third-party software

The scripts download and run third-party software and model weights (Ollama, uv,
Python, Open WebUI, Git, ComfyUI, PyTorch and their Python dependencies, and the chosen
models), and the Local Agent runs Qwen Code, which you install yourself. Each is under
its own licence. None of it is redistributed here.

## License

MIT License.
