# Running llm-hub

All three nodes are already set up. This document starts with how to run, verify,
and operate them. From-scratch installation is at the end, for a new or rebuilt
node only.

For the architecture and design rationale, see [README.md](README.md).

## Paths

Examples use `$REPO` for the clone location:

```bash
export REPO=~/DEV/gits/llm-hub        # imac-thunder
# export REPO=~/DEV/opencode/llm-hub  # mini-thunder
```

Set it to the clone path on whichever host you are on.

---

## What runs where

| Node | Process | Port | Start command | launchd label |
|---|---|---|---|---|
| `imac-thunder` | LiteLLM proxy | 4000 | `./scripts/start-router.sh` | `com.alepape.llmhub.router` |
| `mini-thunder` | llama-swap (m2pro) | 8080 | `./scripts/start-models.sh m2pro` | `com.alepape.llmhub.llama-swap` |
| `m4pro` | llama-swap (m4pro) | 8080 | `./scripts/start-models.sh m4pro` | `com.alepape.llmhub.llama-swap` |

Run each command on its own host, from `$REPO`.

## Starting and stopping

### imac-thunder — router

Foreground (Ctrl-C to stop):

```bash
cd "$REPO"
./scripts/start-router.sh
```

Under launchd, restart in place:

```bash
launchctl kickstart -k "gui/$(id -u)/com.alepape.llmhub.router"
```

`kickstart -k` restarts an installed agent. `launchctl bootstrap` is only for
loading a plist that is not loaded yet; on an already-loaded job it fails with
the misleading `Bootstrap failed: 5: Input/output error`.

Probe with `/health/liveliness`, not `/health`. `/health` runs upstream model
health checks, returns 500 without a DB, and would cold-load models.

Do **not** enable LiteLLM background health checks. They would send inference
requests to the model hosts and cold-load a model on the mini while it is idle
— defeating the whole point of `ttl` unloading. Failover at request time plus
cooldown is sufficient.

### mini-thunder — always-on model host

```bash
cd "$REPO"
./scripts/start-models.sh m2pro      # binds 0.0.0.0:8080
```

Under launchd:

```bash
launchctl kickstart -k "gui/$(id -u)/com.alepape.llmhub.llama-swap"
```

Requires `/Volumes/Fast Data` to be mounted; startup fails rather than writing
models to the internal disk. The model is **not** pre-downloaded: the first
request downloads and loads it (several GB, minutes) and waits for that.
Afterwards it stays loaded until `ttl` (10 min here) expires.

### m4pro — laptop model host

```bash
cd "$REPO"
./scripts/start-models.sh m4pro
```

Under launchd:

```bash
launchctl kickstart -k "gui/$(id -u)/com.alepape.llmhub.llama-swap"
```

Closing the lid stops the service. That is intended: the router notices, fails
over to the mini, and switches back once the laptop is reachable again (within
the ~60 s cooldown).

## Verifying

```bash
./scripts/status.sh                  # router up? hosts up? models loaded?
./scripts/smoke.sh                   # real completion through the router
./scripts/smoke.sh auto              # exercise the failover route
```

Individual hosts:

```bash
curl -s http://localhost:8080/health                 # on a model host
curl -s http://localhost:8080/v1/models | python3 -m json.tool
curl -s -H "Authorization: Bearer $KEY" \
  http://localhost:4000/v1/models | python3 -m json.tool   # on the router
```

`./scripts/smoke.sh` and `./scripts/status.sh` read the key from
`config/router/router.env` themselves.

---

## Client configuration

### Router clients

Point anything OpenAI-compatible at the router:

```bash
export OPENAI_BASE_URL=http://imac-thunder:4000/v1
export OPENAI_API_KEY=$(grep '^LITELLM_MASTER_KEY=' "$REPO/config/router/router.env" | cut -d= -f2)
```

opencode (example, adjust to your version) — substitute the generated key for
`<LITELLM_MASTER_KEY>`:

```json
{
  "provider": {
    "llm-hub": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llm-hub",
      "options": { "baseURL": "http://imac-thunder:4000/v1", "apiKey": "<LITELLM_MASTER_KEY>" },
      "models": { "auto": {}, "big": {}, "small": {} }
    }
  }
}
```

Naming advice: use `auto` for "just work", and `big` when quality matters — it
fails loudly if the laptop is away instead of silently answering with an 8B.
Tool-calling quality differs a lot between the two.

### M4 Pro away from home (direct local OpenCode)

On the laptop, if this has not been run yet (Python 3 required):

```bash
git pull
python3 scripts/setup-opencode-local.py
```

This configures OpenCode **V2** globally with provider `m4pro-local`, model
`qwen35-35b`, and endpoint `http://127.0.0.1:8080/v1`. No router, SSH, home
network, or LiteLLM key is involved. `sk-local` is a placeholder for the
default unauthenticated llama-swap configuration, not a secret. If you add
`apiKeys` to llama-swap, update this provider's key locally too.

The installer preserves other providers and MCPs, backs up changed configs,
and updates an existing `~/.opencode` default override as well. JSONC comments
are preserved in the backups; edited files are formatted as JSON. It respects
`XDG_CONFIG_HOME` and is safe to run again. Project-specific model defaults
can still override the global one.

Start the model host **using the existing script unchanged**, or leave its
existing launchd service running (do not start a duplicate):

```bash
./scripts/start-models.sh m4pro
```

In another terminal, open OpenCode. New sessions default to the local model;
for existing sessions, use `/reload` if needed and select
**Qwen3.5 35B (M4 Pro, offline/local)** in `/models`. First inference cold-loads
the model, and idle unloading still works. Download the model once while
online before relying on it away from home. Existing remote MCPs and cloud
providers still require their respective networks; this makes **inference**
local, not every tool.

To return to home routing, select `llm-hub/auto` in `/models` (if configured).
To restore it as the default, change `model` back in the affected config files
or restore the timestamped backups. The installer does not touch model-host
configuration or services.

---

## Day-to-day operations

```bash
./scripts/status.sh              # router up? hosts up? models loaded?
./scripts/smoke.sh               # real completion through the router
./scripts/unload.sh m4pro        # free the laptop now
curl -s http://mini-thunder:8080/running     # what the mini holds
open http://imac-thunder:4000/ui             # LiteLLM UI (needs master_key)
open http://mini-thunder:8080/ui             # llama-swap UI: logs, tokens, load/unload
```

Logs, when run under launchd (the path includes the full agent label):

```bash
tail -f ~/Library/Logs/llm-hub-com.alepape.llmhub.router.log
tail -f ~/Library/Logs/llm-hub-com.alepape.llmhub.llama-swap.log
```

`llama-swap` also has a web UI at `http://host:8080/ui` with per-request logs.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| First request takes 30–60 s | model was unloaded (`ttl`) and is cold-loading | expected; raise `ttl` in the host config to keep it warm longer |
| Requests hang for minutes, then fail | old router config, or a connected backend stalled while loading | pull and restart the router to activate its connect-timeout callback; check backend logs for read stalls |
| `auto` always answers with the 8B | laptop unreachable, or still in cooldown | `./scripts/status.sh`; cooldown is 60 s for re-admission |
| Router returns 400 "context too long" | prompt exceeds the host's context | use `big` (64k); pre-call checks filter deployments whose `max_input_tokens` is too small |
| `llama-swap` starts, model fails | `LLAMA_SERVER_BIN` wrong | `echo $LLAMA_SERVER_BIN; $LLAMA_SERVER_BIN --version` |
| Model reloads on every request | request never reaches the model (proxy error) or `ttl` is tiny | check `http://host:8080/logs` |
| Port 8080 already in use | leftover `llama-server` from an old tmux session | `pgrep -fl llama-server`, kill it |
| `launchctl kickstart` says "Could not find service" | the launchd agent is not installed on this node | run `./scripts/install-launchd.sh router` (or `models <role>`) once, then kickstart again |
| `launchctl bootstrap` says "Input/output error" (5) | the job is already loaded; launchd reports this instead of "already loaded" | `launchctl list \| grep llmhub`; restart with `kickstart -k`, do not bootstrap again |
| Node is down after re-running `install-launchd.sh` | the old job had not finished unloading, so the immediate bootstrap failed and the script stopped | update the repo, then re-run `install-launchd.sh`; the current version waits for the unload and retries the bootstrap |

---

## Fast-fail connection policy

The router loads `connect_timeout.timeout_policy` as a deployment callback.
`start-router.sh` sets its module search path automatically, also under launchd.
Keep the numeric `timeout` / `stream_timeout` values in YAML: the callback
constructs an `httpx.Timeout` only after deployment selection. This separates
the connection deadline from the long model-loading/read budget. Override
`HUB_CONNECT_TIMEOUT=3` in `config/router/router.env` if needed.

After pulling on the iMac, restart the foreground router (Ctrl-C, then
`./scripts/start-router.sh`), or its launchd agent if installed:

```bash
launchctl kickstart -k "gui/$(id -u)/com.alepape.llmhub.router"
```

Then test `./scripts/smoke.sh auto` with the laptop online, turn its Wi-Fi off,
and repeat. Confirm the new POST appears in the mini's logs. A cold mini can
still take time to load: the goal is to remove the long wait for an absent
laptop, not to eliminate cold starts. Re-enable Wi-Fi and allow the router's
cooldown to expire before checking that it prefers the laptop again.

---

## Tests

No models or real upstream requests are needed:

```bash
.venv/bin/python -m unittest discover -s tests -v
```

These test real LiteLLM routing and its HTTP transport against local stub
servers, simulating a dropped connection and delayed response headers for
both streaming and non-streaming calls. Verified on LiteLLM 1.106.6.

---

# First-time setup

Only needed for a new or rebuilt node. If the node is already serving, skip this
whole section.

Clone the repo on each host (set `$REPO` first, see [Paths](#paths)):

```bash
git clone https://github.com/alepape/llm-hub.git "$REPO"
```

Anywhere is fine; scripts resolve their own path.

## imac-thunder — router install

Requirements: macOS, Homebrew (`/usr/local/bin/brew` on this Intel iMac),
Python ≥ 3.10 (3.13 is installed at `/usr/local/bin/python3`).

```bash
cd "$REPO"
./scripts/install-router.sh          # creates .venv, installs litellm[proxy], makes router.env
$EDITOR config/router/router.env     # set M4PRO_BASE / M2PRO_BASE
./scripts/start-router.sh            # foreground; Ctrl-C to stop
```

`install-router.sh` creates `config/router/router.env` from the example and
fills in a generated client key (it prints it). Use `LITELLM_MASTER_KEY` from
that file wherever a client asks for an API key.

`config/router/router.env`:

```bash
M4PRO_BASE=http://FM7XXRXT4V.local:8080/v1
M2PRO_BASE=http://mini-thunder:8080/v1
LOCAL_KEY=sk-local
```

Autostart:

```bash
./scripts/install-launchd.sh router
```

## mini-thunder — model host install

```bash
cd "$REPO"
./scripts/install-llama-swap.sh      # brew tap mostlygeek/llama-swap; brew install
./scripts/start-models.sh m2pro      # binds 0.0.0.0:8080
```

### Model storage

The mini automatically exports `LLAMA_CACHE="/Volumes/Fast Data/LLM/llama.cpp"`.
Downloads made with `-hf` go there; the directory is created as needed, but
**only after checking that `/Volumes/Fast Data` is actually mounted**. If the
drive is missing or the cache is not writable, startup fails instead of
downloading models onto the internal disk. Existing downloads elsewhere are
not moved automatically.

No terminal export or plist edit is needed: foreground and launchd both call
`scripts/start-models.sh`, which applies the same settings. If the drive is
unavailable at login, launchd retries (at its configured 30-second throttle).
Keep the drive connected while serving models. macOS may require permission
for the service to access removable volumes; check its logs if access fails.

Autostart:

```bash
./scripts/install-launchd.sh models m2pro
```

Note: `llama-swap` binds `0.0.0.0:8080` so the iMac can reach it. It is
default-allow on your LAN. If that bothers you, add `apiKeys:` to
`config/llama-swap/m2pro.yaml` and set the same key in `LOCAL_KEY`.

## m4pro — laptop model host install

Same as the mini, different role:

```bash
cd "$REPO"
./scripts/install-llama-swap.sh
./scripts/start-models.sh m4pro
```

The laptop needs a llama.cpp build with Metal:

```bash
# option A: build it
git clone https://github.com/ggml-org/llama.cpp ~/DEV/gits/llama.cpp
cmake -B ~/DEV/gits/llama.cpp/build -S ~/DEV/gits/llama.cpp -DGGML_METAL=ON
cmake --build ~/DEV/gits/llama.cpp/build --config Release -j

# option B: homebrew build
brew install llama.cpp
```

Both scripts default `LLAMA_SERVER_BIN` to
`$HOME/DEV/gits/llama.cpp/build/bin/llama-server`; override for option B:

```bash
export LLAMA_SERVER_BIN="$(command -v llama-server)"
./scripts/start-models.sh m4pro
```

**The hosts do not need matching llama.cpp versions.** There is no RPC, so each
host is independent. Only LiteLLM's routing ties them together.

**Set the laptop's real name.** If it is not `FM7XXRXT4V.local`, either fix
`M4PRO_BASE` in `config/router/router.env` on the iMac, or add a local name:

```bash
scutil --get LocalHostName    # what mDNS advertises
```

Autostart is optional and can be annoying (it starts on login); use it if you
want the laptop to serve whenever it is open:

```bash
./scripts/install-launchd.sh models m4pro
```

## Per-host environment overrides

For persistent overrides, copy the example and edit it:

```bash
cp config/llama-swap/model.env.example config/llama-swap/m2pro.env
# Edit the quoted LLAMA_CACHE path or LLAMA_SERVER_BIN as needed.
```

`m2pro.env` and `m4pro.env` are gitignored shell files; only source trusted
content. They override inherited environment settings. The laptop keeps
llama.cpp's platform-default cache unless you set `LLAMA_CACHE` in `m4pro.env`
or its environment. Restart the service after changing settings:

```bash
launchctl kickstart -k "gui/$(id -u)/com.alepape.llmhub.llama-swap"
```
