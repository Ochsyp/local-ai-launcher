# -------------------------------------------------------
#                LOCAL AI DEFAULT SETTINGS
# -------------------------------------------------------
#
# Tracked defaults and every version pin. Override any key in
# %LOCALAPPDATA%\local-ai\settings.psd1 using the same layout: tables merge key by key, single
# values and lists replace. %VAR% expands in every string. Paths starting with config\ are
# relative to this repository.

@{
    # Loopback ports for the services the launcher starts; each must be free and distinct.
    Ports     = @{
        OpenWebUI = 8080
        ComfyUI   = 8188
        # mcpo, which serves the read-only file tools to Open WebUI.
        Files     = 8189
        # The image gate in front of ComfyUI (Images.UnloadChat). IANA lists 8190 only for gcp-rphy,
        # a cable-network control protocol.
        ImageGate = 8190
    }

    Ollama    = @{
        # Empty: taken from OLLAMA_HOST (process, then User scope), else http://127.0.0.1:11434,
        # with 0.0.0.0 and :: mapped to 127.0.0.1. The launcher never sets OLLAMA_HOST itself, and
        # the ollama program that install runs for pull and create always follows OLLAMA_HOST.
        Url = ''
    }

    # The chat model, pulled into Ollama's store and served under a stable alias.
    Model     = @{
        # The name Open WebUI and agents use. It stays put when the weights or context change.
        Alias     = 'local-chat'
        # Argument to `ollama pull`; must match the FROM line of the Modelfile.
        Source    = 'hf.co/HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive:Q6_K'
        # SHA-256 of the Q6_K GGUF (7359259008 bytes), equal to the model layer of the Ollama
        # manifest. hf.co pulls cannot pin a revision, so the digests are the integrity pins.
        Sha256    = 'c0ba7beb68fd3fe47891bd549486d38dcf62d00817296ea314ad37017f5a4986'
        # SHA-256 of the BF16 vision projector layer (921704448 bytes) the same manifest carries.
        # local-chat keeps it, so it reads images; Ollama loads it on the GPU with every model load
        # and reserves 1 GiB of headroom for it, about 2 GB of VRAM beyond the text model.
        ProjectorSha256 = '05f662501f8bd45607b079723a3e238a4e888fd085a10a53f4057a0e250f6934'
        # Bytes the pull of Source stores: the GGUF (7359259008), the projector (921704448) and
        # the config (481). install wants the part not stored yet plus 10 percent free.
        Size      = 8280963937
        # Context length, template and sampling. %LOCALAPPDATA%\local-ai\local-chat.Modelfile
        # replaces it when that file exists.
        Modelfile = 'config\local-chat.Modelfile'
        # Aliases of earlier chat models, such as 'old-chat'. status lists those Ollama still holds,
        # and update offers to remove each with its own confirmation; never Alias or Source. None
        # by default; add the old alias here when Alias is renamed.
        SupersededAliases = @()
    }

    # Open WebUI, installed as a uv tool and configured through its environment only.
    OpenWebUI = @{
        # Installed by install; a changed pin is applied only by update, which backs up the data
        # folder first.
        Version              = '0.12.4'
        # 0.12.4 requires Python >=3.11,<3.13.
        Python               = '3.12'
        # DATA_DIR and working directory, so .webui_secret_key stays beside webui.db. A full path
        # on a drive letter. When install finds no open-webui tool but a webui.db here, it copies
        # webui.db and .webui_secret_key to %LOCALAPPDATA%\local-ai\backups first.
        DataDir              = '%LOCALAPPDATA%\open-webui'
        # Free space install wants, plus 10 percent, on the uv tools drive before it installs Open
        # WebUI: the 0.12.3 tool environment as measured (1937858153 bytes), a uv-managed Python
        # (73088127) and the embedding model the first start downloads (976948716).
        InstallBytes         = 2987894996
        # How long start waits for /health and /api/version. Open WebUI opens its port only after
        # startup, which on a fresh machine includes downloading its embedding model (about 1 GB).
        HealthTimeoutSeconds = 600
        # More variable names that Open WebUI inherits from the window that runs start, such as
        # HTTPS_PROXY. Open WebUI, and the tools and functions inside it, get only what Windows and
        # Python need, where huggingface_hub and sentence-transformers keep the embedding model
        # (HF_HOME, HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE, XDG_CACHE_HOME, SENTENCE_TRANSFORMERS_HOME),
        # HF_HUB_OFFLINE, Env with the keys the launcher computes, and the names listed here. A name
        # ending in _TOKEN or _API_KEY, and PYTHONHOME, PYTHONPATH, PYTHONSTARTUP, PYTHONUSERBASE,
        # NODE_OPTIONS and NODE_PATH, never reach a service from the window, so the settings check
        # refuses them here. Env sets a value in settings.psd1; a name listed here passes the
        # window's value on instead. Either way the tools and functions inside Open WebUI can read
        # the value, such as a password in a proxy address.
        InheritEnvironment   = @()
        # Environment for every start. With ENABLE_PERSISTENT_CONFIG False these values win over
        # the database and Admin Settings edits revert on restart, so add any further Open WebUI
        # setting here; any key is accepted, and an empty value removes the variable. The launcher
        # adds DATA_DIR, OLLAMA_BASE_URL, CORS_ALLOW_ORIGIN, ENABLE_OLLAMA_API and an empty
        # OLLAMA_BASE_URLS, which this table cannot change, and DEFAULT_MODELS, TASK_MODEL,
        # ENABLE_SIGNUP ('False') and an empty DATABASE_URL, which it can. The empty values remove
        # copies inherited from Windows, which Open WebUI would use instead of the computed ones.
        # It also sets the image keys from Images, Ports.ComfyUI and Ports.ImageGate, which this table
        # cannot change: ENABLE_IMAGE_GENERATION, IMAGE_GENERATION_ENGINE, IMAGE_GENERATION_MODEL,
        # IMAGE_SIZE, IMAGE_STEPS, COMFYUI_BASE_URL (the image gate while it runs, else ComfyUI), an
        # empty COMFYUI_API_KEY, COMFYUI_WORKFLOW, COMFYUI_WORKFLOW_NODES and ENABLE_IMAGE_EDIT
        # ('False'; no edit workflow is set up). Images are on only for a start that launches ComfyUI;
        # Open WebUI reads these when it starts. From Files and Ports.Files it sets
        # TOOL_SERVER_CONNECTIONS (the file tools, or '[]' for a start without them), which this table
        # cannot change either. OLLAMA_API_CONFIGS lists only Model.Alias, the model the image gate
        # unloads; an empty value here lists every Ollama model. NO_PROXY gets 127.0.0.1, localhost
        # and ::1 added to any inherited or given value, so no proxy sees the file tools' key; with
        # NO_PROXY set Python ignores the Windows proxy setting, so a PC that reaches the internet
        # only through one needs HTTPS_PROXY here, or in InheritEnvironment, for the Hugging Face
        # check. DEFAULT_MODEL_METADATA,
        # merged into a model's metadata where it has none, turns the file tools on in every new chat
        # (checked in the browser with 0.12.3) and is '{}' without them, which leaves Open WebUI's
        # built-in tools as it ships them; a JSON object given here is merged in, for example
        # {"builtinTools":{"notes":false}}. A model saved in Workspace > Models keeps the tools it was
        # saved with instead, so turn on Workspace files there.
        Env                  = @{
            ENABLE_PERSISTENT_CONFIG                     = 'False'
            WEBUI_AUTH                                   = 'True'
            ENABLE_OPENAI_API                            = 'False'
            # Background generations queue behind answers on Ollama's single slot.
            ENABLE_TAGS_GENERATION                       = 'False'
            ENABLE_FOLLOW_UP_GENERATION                  = 'False'
            ENABLE_WEB_SEARCH                            = 'False'
            ENABLE_CODE_INTERPRETER                      = 'False'
            ENABLE_CODE_EXECUTION                        = 'False'
            ENABLE_COMMUNITY_SHARING                     = 'False'
            ENABLE_PIP_INSTALL_FRONTMATTER_REQUIREMENTS  = 'False'
            # Saves a chat-model call, and its VRAM, before each image.
            ENABLE_IMAGE_PROMPT_GENERATION               = 'False'
            # Seconds a tool call to a tool server such as mcpo may take; unset, it has no limit.
            AIOHTTP_CLIENT_TIMEOUT_TOOL_SERVER           = '60'
            # The signed-in UI would otherwise ask api.github.com for the latest release.
            ENABLE_VERSION_UPDATE_CHECK                  = 'False'
            # 'dev', the default, serves /docs and /openapi.json without sign-in.
            ENV                                          = 'prod'
            # Read by huggingface_hub, which Open WebUI uses for its embedding model. Each start
            # still asks huggingface.co whether sentence-transformers/all-MiniLM-L6-v2 changed, and
            # the first start downloads it to %USERPROFILE%\.cache\huggingface. Once it is there,
            # RAG_EMBEDDING_MODEL_AUTO_UPDATE = 'False' makes starts use the local copy only.
            HF_HUB_DISABLE_TELEMETRY                     = '1'
            REFERRER_POLICY                              = 'no-referrer'
            # Lets the page and the HTML artifacts Open WebUI renders from answers, which inherit
            # it, load nothing from other hosts: no script, style sheet, font, prefetch, image,
            # media, frame, connection or form target that a prompt injection could use to send
            # chat or file content out. 'unsafe-inline' and 'unsafe-eval' keep the UI's own inline
            # bootstrap and libraries working. A markdown link remains, and needs a click.
            CONTENT_SECURITY_POLICY                      = "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data: blob:; media-src 'self' data: blob:; connect-src 'self'; frame-src 'self' blob:; worker-src 'self' blob:; object-src 'none'; base-uri 'self'; form-action 'self'"
            # Defaults for each account's Settings > Interface, which it can change: an HTML answer
            # opens as an artifact only on request, and HTML in answers and artifacts runs no
            # scripts, which the policy above cannot stop from leaking through WebRTC.
            DEFAULT_INTERFACE_SETTINGS                   = '{"detectArtifacts":false,"iframeSandboxAllowScripts":false}'
        }
    }

    # SDXL checkpoint that ComfyUI renders Open WebUI's images with.
    Images    = @{
        # $false skips ComfyUI and turns Open WebUI's image button off.
        Enabled              = $true
        Repo                 = 'Lykon/dreamshaper-xl-lightning'
        # Also the ckpt_name in the workflow and IMAGE_GENERATION_MODEL.
        File                 = 'DreamShaperXL_Lightning.safetensors'
        # Commit passed to `hf download --revision`, so the file cannot change under the pin.
        Revision             = '561086c22aba3925b1e8803a73857f061635c7c3'
        # Byte count and LFS SHA-256 checked before ComfyUI uses the file. Hugging Face also
        # lists a xetHash; that is a different hash.
        Size                 = 6939220250
        Sha256               = 'fdbe56354b8f876b736f24d3ad867ecd4140c019f57642ec8ddd878088d44f64'
        # ComfyUI API-format workflow and Open WebUI's node mapping for it, passed as compact JSON.
        # The workflow holds CFG 2, the dpmpp_sde sampler with the karras scheduler, and a
        # PreviewImage output, which ComfyUI keeps only in its temp folder until its next start.
        Workflow             = 'config\comfyui\sdxl-lightning.workflow.json'
        WorkflowNodes        = 'config\comfyui\sdxl-lightning.nodes.json'
        # The author's settings for this checkpoint are CFG 2 with 3 to 6 steps of DPM++ SDE Karras
        # (Civitai); the Hugging Face model card's example uses 4 steps. Also IMAGE_STEPS.
        Steps                = 6
        # Width x height, also IMAGE_SIZE; 1024x1024 is SDXL's native size.
        Resolution           = '1024x1024'
        # $true: images go through the image gate (src\image_gate.py on Ports.ImageGate), which unloads
        # Model.Alias from Ollama before each one. On the test GPU: about 8 s per image
        # instead of 32 to 38 s, chat keeps its full speed, and the next chat reloads local-chat in 7 to
        # 10 s. That reload commits about 11 GB of virtual memory; when a system-managed page file has
        # shrunk on a PC with little RAM, such a reload can fail ('CUDA error: shared object
        # initialization failed'). A fixed page file of about 20 GB or more should avoid that (not yet
        # measured). $false: Open WebUI talks to ComfyUI directly and no gate runs.
        UnloadChat           = $true
        # How long the gate waits for that unload, an answer still streaming included, before it sends
        # the image to ComfyUI anyway. An idle unload takes about 0.3 s, and an image beside a loaded
        # local-chat takes 32 to 38 s, which a longer wait could not beat.
        UnloadTimeoutSeconds = 30
    }

    # ComfyUI as a git checkout with its own uv venv.
    ComfyUI   = @{
        # A full path on a drive letter, at most 133 characters: the Python files a v0.42.5 .venv
        # imports add up to 126 more, and Windows limits a path to 259 unless long paths are on.
        Dir                  = '%USERPROFILE%\ComfyUI'
        Repo                 = 'https://github.com/Comfy-Org/ComfyUI.git'
        # A lightweight tag; install clones it with --depth 1.
        Ref                  = 'v0.42.5'
        # The commit Ref named when it was pinned. install clones beside Dir and moves the clone in
        # only when its HEAD is this commit, since a tag can move, and leaves an existing checkout at
        # another commit for update to move.
        Commit               = '483dae4326356b81de05d27aca3f433dd323cc25'
        # Passed to uv pip install as --exclude-newer, the time Commit was made: the packages that
        # requirements.txt leaves unpinned resolve to their newest release uploaded before it, so a
        # fresh .venv gets the same versions on any day. Installed packages that satisfy the
        # requirements are kept, also when they are newer.
        ExcludeNewer         = '2026-10-23T00:07:14Z'
        # Minor version of the .venv. install creates a missing one on a uv-managed CPython
        # (--managed-python); without that flag uv takes the Microsoft Store Python 3.13, whose patch
        # version follows Store updates. An existing .venv keeps its interpreter if the minor matches.
        Python               = '3.13'
        # uv --torch-backend: CUDA 13.0 wheels, because PyPI's Windows torch is CPU-only.
        TorchBackend         = 'cu130'
        # Passed with -c to uv pip install; pins torch and torchvision, which v0.42.5's
        # requirements.txt lists without versions.
        Constraints          = 'config\comfyui\constraints.txt'
        # Free space install wants, plus 10 percent, on Dir's drive before it clones ComfyUI or
        # creates its .venv: a used venv as measured (4414856773 bytes), a v0.42.5 depth-1 clone
        # (64339404) and a uv-managed Python (73088127). uv hard-links venv files to its cache when
        # both are on one drive and copies them otherwise.
        InstallBytes         = 4552284304
        # How long start waits for /system_stats. ComfyUI opens its port last, after importing
        # torch and its nodes, and the first start after install also compiles Python bytecode.
        HealthTimeoutSeconds = 300
        # Each flag exists in v0.42.5: core nodes only, since custom nodes run code at start;
        # --offline leaves out the paid partner nodes and gives the web page a CSP that blocks
        # outside content; models leave VRAM after each image; UNet and text-encoder weights are
        # kept as fp8, half the bytes of fp16 (an older card may lack fp8 compute, so each layer is
        # cast up when it runs).
        # The launcher drops --listen, --port, --enable-manager, --enable-manager-legacy-ui,
        # --enable-cors-header, their abbreviations and '--' from this list, then passes
        # --listen 127.0.0.1 and --port after it, since ComfyUI takes the last value given.
        Args                 = @('--disable-all-custom-nodes', '--offline', '--disable-smart-memory', '--fp8_e4m3fn-unet', '--fp8_e4m3fn-text-enc')
        # More variable names that ComfyUI, not the image gate, inherits from the window that runs
        # start. ComfyUI gets only what Windows and Python need, the GPU choice and allocator
        # settings (CUDA_VISIBLE_DEVICES, CUDA_DEVICE_ORDER, PYTORCH_CUDA_ALLOC_CONF,
        # PYTORCH_ALLOC_CONF), CUDA_PATH and the names listed here; the names OpenWebUI.InheritEnvironment refuses are refused
        # here too. The image gate gets only what Windows and Python need.
        InheritEnvironment   = @()
    }

    # Read-only file tools: mcpo serving @modelcontextprotocol/server-filesystem to Open WebUI, which
    # offers them to the model through native function calling.
    Files     = @{
        # The only folder the tools may read, as a full path on a drive letter; empty turns them off
        # and needs no Node.js. Use a dedicated folder that only you write to and that holds nothing
        # secret: the model may quote any file in it, and NTFS alternate streams such as
        # Zone.Identifier are readable as well (read_text_file of 'file.txt:Zone.Identifier' answered).
        # read_text_file returns a whole file unless the model asks for its head or tail, and a text
        # file of 300 KB overflows local-chat's 32K context, which leaves the answer unusable.
        # start refuses a drive root, %USERPROFILE% or a folder above it, a path through a link, a
        # folder inside or around %LOCALAPPDATA%\local-ai, this repository, uv's tool folder,
        # OpenWebUI.DataDir or ComfyUI.Dir, and a folder holding a hard link to a file with a name
        # outside it, as a uv-made .venv has. Each start checks the folder against DenyPatterns;
        # files added while mcpo runs are not checked. The server gets the folder spelled as on disk
        # and repeats its full path on every search result line, so a short path such as C:\AI-Files
        # works best.
        Root                 = ''
        # mcpo, installed as a uv tool on a uv-managed Python of this minor version. install
        # reinstalls it when McpoVersion, McpoWith, McpoExcludeNewer or Python differ from what
        # install-stamp.json records, since uv keeps an installed tool's packages otherwise. mcpo
        # 0.0.20 takes its API key (%LOCALAPPDATA%\local-ai\files.key) only on its command line,
        # where programs running as the same user can read it, as they can in Open WebUI's
        # TOOL_SERVER_CONNECTIONS.
        McpoVersion          = '0.0.20'
        Python               = '3.12'
        # Passed with --with, since mcpo 0.0.20 sets no upper bounds: mcp 2.x removed
        # streamablehttp_client, which mcpo imports at startup (open-webui/mcpo#303), and FastAPI
        # 0.145.0 removed the **extra that mcpo's FastAPI(ssl_certfile=...) call needs. pydantic
        # 2.14.1 works with server-filesystem 2.0.1, so it needs no cap.
        McpoWith             = @('mcp==1.30.0', 'fastapi<0.145')
        # Passed as --exclude-newer: mcpo's other dependencies resolve to their newest release
        # uploaded before this time (44 packages, tested with server-filesystem 2.0.1). Empty lifts
        # it, and the fastapi cap above still holds: on 2026-10-27 that resolved FastAPI 0.144.0 with
        # mcp 1.30.0 (44 packages), and mcpo started and served the tools.
        McpoExcludeNewer     = '2026-10-13T00:00:00Z'
        # @modelcontextprotocol/server-filesystem, which needs node >= 24. 2.0.1 is the first release
        # with the 2026-10-25 path-check fixes (GHSA-7rgq-gccq-qphx, GHSA-4gxg-m5jx-9j57), which
        # affect its read tools in 1.0.0 and 2.0.0; it was 2 days old when pinned. Must equal the
        # version that ServerPackage\package.json pins; install runs npm ci on that folder's lockfile.
        # Its overrides hold @modelcontextprotocol/server and core at 2.3.1 (2026-10-05), which
        # server-filesystem's ^2.3.1 accepts, since 2.4.0 was 4 days old; every other locked package
        # was at least 14 days old.
        ServerVersion        = '2.0.1'
        ServerPackage        = 'config\files-server'
        # The tools Open WebUI offers the model, as the server names them. Open WebUI sees them under
        # mcpo's operation ids, tool_<name>_post, and the model calls them by those names.
        AllowedTools         = @('read_text_file', 'list_directory', 'search_files', 'get_file_info', 'list_allowed_directories')
        # The tools mcpo hides: every write tool (write_file, edit_file, create_directory and
        # move_file must stay listed), the deprecated read_file alias, and the tools most likely to
        # flood a 32K context.
        DisabledTools        = @('read_file', 'write_file', 'edit_file', 'create_directory', 'move_file', 'read_multiple_files', 'read_media_file', 'directory_tree', 'list_directory_with_sizes')
        # mcpo is not started while Root holds a file or folder whose name matches one of these, in
        # any case, because server-filesystem has no deny list of its own; a matching folder, such as
        # .git or .ssh, counts as a whole. Root must also hold no folder start cannot list. The check
        # does not follow links inside Root; the server refuses any link that leads outside it.
        DenyPatterns         = @('.env', '.env.*', '*.pem', '*.key', '*.pfx', '*.p12', '*.kdbx', 'id_rsa*', 'id_ed25519*', '*secret*', '.git-credentials', '*.ovpn',
            '*.ppk', '*.jks', '*.keystore', '*.gpg', '.npmrc', '.netrc', '_netrc', '.pypirc', 'credentials', 'credentials.*', 'key4.db', 'logins.json',
            '.git', '.ssh', '.aws', '.azure', '.gnupg', '.kube', '.docker')
        # How long start waits for mcpo, which opens its port once the node server has listed its
        # tools, before Open WebUI starts without them: 2 to 4 s measured, 8.8 s on the first start
        # after install, which compiles bytecode.
        HealthTimeoutSeconds = 20
        # Free space install wants, plus 10 percent, on the uv tools drive before it installs mcpo:
        # the tool environment after its first start (60340864 bytes), a uv-managed Python 3.12
        # (58674545) and the mcpo.exe trampoline (47104).
        InstallBytes         = 119062513
        # Free space install wants, plus 10 percent, on the %LOCALAPPDATA% drive before npm ci: the
        # server's node_modules and package files (21075512 bytes).
        ServerInstallBytes   = 21075512
    }

    HfCli     = @{
        # huggingface_hub for `hf download`, run through uvx. Pin a release at least 14 days old
        # that is not yanked.
        Version = '2.2.0'
    }

    Winget    = @{
        # Prerequisites, installed when missing and upgraded only by `update -Tools`. Id is the
        # winget package, Command the program whose presence on PATH counts as installed, and
        # Scope the winget --scope: 'user', or 'machine', which asks for administrator approval.
        # unverified: whether uv's Microsoft.VCRedist.2015+.x64 dependency asks for elevation.
        Packages = @{
            Ollama = @{ Id = 'Ollama.Ollama'; Command = 'ollama'; Scope = 'user' }
            Uv     = @{ Id = 'astral-sh.uv'; Command = 'uv'; Scope = 'user' }
            Git    = @{ Id = 'Git.Git'; Command = 'git'; Scope = 'user' }
            # Runs server-filesystem. OpenJS.NodeJS.LTS has no user-scope installer.
            Node   = @{ Id = 'OpenJS.NodeJS.LTS'; Command = 'node'; Scope = 'machine' }
        }
    }

    Logs      = @{
        # Rotated generations kept per service log (.1 to .5). Launcher transcripts are pruned
        # to the newest 20 of each verb and to 14 days; those of status and uninstall go to %TEMP%.
        Keep = 5
    }

    Update    = @{
        # Backups of Open WebUI's data that update keeps in %LOCALAPPDATA%\local-ai\backups, newest
        # first (1 to 20). update makes one before it changes Open WebUI: webui.db with its -wal and
        # -shm, .webui_secret_key, uploads and vector_db, which grow with the chats and uploads,
        # plus the old tool environment's package list. Only folders update made, which hold
        # local-ai-backup.json, are pruned, and only once the new version passed update's check;
        # install's backup and the data a rollback moved aside (open-webui-failed-*) stay.
        KeepBackups = 3
    }

    Shortcuts = @{
        # The Start menu folder where 'local-ai shortcuts' creates Start, Stop and Status Local AI,
        # which run local-ai.cmd; install creates none. The verb replaces other shortcuts of those
        # names in this folder, and -Remove deletes those three names only. A full path on a drive
        # letter.
        Folder = '%APPDATA%\Microsoft\Windows\Start Menu\Programs\Local AI'
    }
}
