# llm-hub

One OpenAI-compatible endpoint in front of a small fleet of Macs that run models
on demand.

```
opencode / MCP clients
        │  http://imac-thunder:4000/v1
        ▼
┌──────────────────────────────────────────────┐
│ imac-thunder  —  control plane, always on    │
│   LiteLLM proxy (the "local openrouter")     │
│   + opencode server, MCPs                    │
└──────────────────────────────────────────────┘
        │ order 1                  │ order 2
        ▼                          ▼
┌────────────────────┐   ┌────────────────────┐
│ m4pro (laptop)     │   │ mini-thunder       │
│ llama-swap :8080   │   │ llama-swap :8080   │
│ Qwen3.5-35B, 64k   │   │ Qwen3-8B, 32k      │
│ loads on demand    │   │ loads on demand    │
└────────────────────┘   └────────────────────┘
      (sometimes)              (always)
```

Clients ask for `auto` and get the 35B when the laptop is around, the 8B when
it isn't. Nothing is loaded while idle. No machine has to be dedicated.

## Why this shape

- **Layer-split RPC across machines is not used.** Measured here: prefill across
  the network hop was the worst part, and it forces every node to hold a slice
  of the model permanently — the opposite of "don't clog the mini".
- **The iMac runs no inference.** 6-core Intel, no useful GPU, 128 GB idle.
  Perfect control plane, bad model host.
- **Each Mac manages its own models.** `llama-swap` starts a model on first
  request and unloads it after `ttl`, so the mini is free when you are not
  using it.
- **The router is LiteLLM, not llama-swap `peers`.** llama-swap can proxy to
  peers, but it "does not manage the peer's lifecycle" and its `warm` selector
  cold-starts the first target when nothing is ready — a dead laptop becomes an
  error, not a fallback. LiteLLM escalates on connection errors via `order`,
  which is exactly the requirement.

## Hosts

| Host | Role | Addresses |
|---|---|---|
| `imac-thunder` | router only (LiteLLM :4000) | `imac-thunder` → 192.168.2.2 (TB), 192.168.1.37 (LAN) |
| `mini-thunder` (m2pro, 16 GB) | model host :8080 | `mini-thunder` → 192.168.2.1 (TB), 192.168.1.26 (LAN) |
| `m4pro` (laptop, 48 GB) | model host :8080 | Wi-Fi; Bonjour name `FM7XXRXT4V.local` |

### Networking notes

- `mini-thunder` and `imac-thunder` both have Ethernet **and** Thunderbolt
  links. Their mDNS names currently resolve to the **Thunderbolt** addresses
  (192.168.2.x), so name-based config automatically uses the fast link.
  **Use hostnames, never IPs**, in the config.
- The m4pro is Wi-Fi only for now. This design does not care: only prompt text
  goes out and tokens come back — a few hundred KB per request, trivial on
  Wi-Fi. There is no model traffic between nodes because there is no RPC.
- Adding a Thunderbolt cable to the m4pro later changes **nothing** in the
  config, provided its hostname still resolves. If you want it on the TB subnet
  specifically, add a second mDNS/static name and change one line in
  `config/router/router.env`.
- `.local` is reserved for Bonjour/mDNS, not ordinary local DNS records. The
  laptop advertises `FM7XXRXT4V.local`; a separate DNS alias `m4pro.local` is
  retained for other uses, but is not used by the router.
- **mDNS does not guarantee fast failure.** Tests with laptop Wi-Fi off still
  returned cached IPv4/IPv6 addresses immediately, followed by TCP timeouts.
  `config/router/connect_timeout.py` sets a separate 3-second HTTP connection
  budget while preserving the 600/900-second response budgets for cold starts.
  This bounds connection establishment, not total failover time: DNS/address
  handling, router overhead and the fallback model's own load/generation can
  add time. An already-connected but stalled backend still uses the long read
  timeout; a stream already in progress cannot migrate seamlessly.

## Files

```
config/router/config.yaml          LiteLLM model routes (big / small / auto)
config/router/router.env.example   copy to router.env and edit hostnames
config/llama-swap/m2pro.yaml       mini-thunder model host
config/llama-swap/m4pro.yaml       m4pro model host
scripts/install-llama-swap.sh      brew install on a model host
scripts/install-router.sh          venv + litellm[proxy] on the iMac
scripts/start-models.sh <role>     run llama-swap for a host role
scripts/start-router.sh            run LiteLLM
scripts/status.sh                  what is up, what is loaded
scripts/smoke.sh                   end-to-end chat completion through the router
scripts/unload.sh <m2pro|m4pro>    free a host's memory now
scripts/install-launchd.sh         autostart via launchd
launchd/*.plist.template           rendered by the script above
```

Clone on each host:

```bash
git clone https://github.com/alepape/llm-hub.git ~/DEV/llm-hub
```

(Anywhere is fine; scripts resolve their own path.)

---

# Host 1 — `imac-thunder` (router)

Requirements: macOS, Homebrew (`/usr/local/bin/brew` on this Intel iMac),
Python ≥ 3.10 (3.13 is installed at `/usr/local/bin/python3`).

```bash
cd ~/DEV/llm-hub
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

Verify:

```bash
KEY=$(grep '^LITELLM_MASTER_KEY=' config/router/router.env | cut -d= -f2)
curl -s -H "Authorization: Bearer $KEY" http://localhost:4000/v1/models | python3 -m json.tool
./scripts/smoke.sh
```

`./scripts/smoke.sh` and `./scripts/status.sh` read the key from
`config/router/router.env` themselves.

Note: probe the router with `/health/liveliness`, not `/health`. `/health` runs
upstream model health checks, returns 500 without a DB, and would cold-load
models.

Autostart:

```bash
./scripts/install-launchd.sh router
```

Do **not** enable LiteLLM background health checks. They would send inference
requests to the model hosts and cold-load a model on the mini while it is idle
— defeating the whole point of `ttl` unloading. Failover at request time plus
cooldown is sufficient.

---

# Host 2 — `mini-thunder` (always-on model host)

```bash
cd ~/DEV/llm-hub
./scripts/install-llama-swap.sh      # brew tap mostlygeek/llama-swap; brew install
./scripts/start-models.sh m2pro      # binds 0.0.0.0:8080
```

### Model storage (including launchd)

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

For persistent host-specific overrides, copy the example and edit it:

```bash
cp config/llama-swap/model.env.example config/llama-swap/m2pro.env
# Edit the quoted LLAMA_CACHE path or LLAMA_SERVER_BIN as needed.
```

`m2pro.env` and `m4pro.env` are gitignored shell files; only source trusted
content. They override inherited environment settings. The laptop keeps
llama.cpp's platform-default cache unless you set `LLAMA_CACHE` in `m4pro.env`
or its environment. Restart the service after changing settings. With launchd:

```bash
launchctl kickstart -k "gui/$(id -u)/com.alepape.llmhub.llama-swap"
```

Verify independently:

```bash
curl -s http://localhost:8080/health
curl -s http://localhost:8080/v1/models | python3 -m json.tool
```

The model is **not** downloaded by these steps. The first request downloads and
loads it (several GB, minutes) and the request waits for that; afterwards it
stays loaded until `ttl` (10 min here) expires.

Autostart:

```bash
./scripts/install-launchd.sh models m2pro
```

Note: `llama-swap` binds `0.0.0.0:8080` so the iMac can reach it. It is
default-allow on your LAN. If that bothers you, add `apiKeys:` to
`config/llama-swap/m2pro.yaml` and set the same key in `LOCAL_KEY`.

---

# Host 3 — `m4pro` (laptop model host)

Same as Host 2, different role:

```bash
cd ~/DEV/llm-hub
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

Autostart on the laptop is optional and can be annoying (it starts on login);
use it if you want the laptop to serve whenever it is open:

```bash
./scripts/install-launchd.sh models m4pro
```

Closing the lid stops the service. That is the intended behaviour: the router
notices, fails over to the mini, and switches back by itself once the laptop is
reachable again (within the ~60 s cooldown).

---

## Model catalogue

| Model ID | Host | Model | Context | TTL | Memory |
|---|---|---|---|---|---|
| `big` | m4pro | `unsloth/Qwen3.5-35B-A3B-GGUF:Q4_K_M` | 65536 | 15 min | ~20 GB weights + KV |
| `small` | mini-thunder (m2pro 16 GB) | `unsloth/Qwen3-8B-GGUF:Q4_K_M` | 32768 | 10 min | ~5 GB + ~2.5 GB KV |
| `auto` | router | `big`, then `small` | — | — | — |

The mini cannot hold the 35B: ~10–12 GB of usable VRAM versus ~20 GB of
weights. Do not try to make the model identical across hosts — use `auto` if
you want uniformity and don't care which one answers.

Both configs use `-fa on -ctk q8_0 -ctv q8_0`, which roughly halves KV cache
and buys context for free. Flash Attention is required for quantised V cache.

To add a model, add it to a `config/llama-swap/*.yaml` and a deployment to
`config/router/config.yaml`. Keep model IDs distinct per host so the router can
tell them apart.

## Client configuration

### M4 Pro away from home (direct local OpenCode)

On the laptop after pulling this repo, run once (Python 3 required):

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

### Router clients

Point anything OpenAI-compatible at the router:

```bash
export OPENAI_BASE_URL=http://imac-thunder:4000/v1
export OPENAI_API_KEY=$(grep '^LITELLM_MASTER_KEY=' ~/DEV/llm-hub/config/router/router.env | cut -d= -f2)
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

## Operations

```bash
./scripts/status.sh              # router up? hosts up? models loaded?
./scripts/smoke.sh               # real completion through the router
./scripts/unload.sh m4pro        # free the laptop now
curl -s http://mini-thunder:8080/running     # what the mini holds
open http://imac-thunder:4000/ui             # LiteLLM UI (needs master_key)
open http://mini-thunder:8080/ui             # llama-swap UI: logs, tokens, load/unload
```

Logs, when run under launchd:

```bash
tail -f ~/Library/Logs/llm-hub-router.log
tail -f ~/Library/Logs/llm-hub-llama-swap.log
```

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

## Deliberate choices

- `num_retries: 0` — a retry against a dead host doubles the wait for nothing.
  `order` already escalates.
- `cooldown_time: 60` — an absent laptop is tried at most once a minute, and is
  re-admitted automatically when it returns.
- `ttl` on both hosts — memory is released when idle. The cost is cold starts.
- No iMac CPU model. It was measured as too slow (especially prefill) and the
  mini already provides an always-on fallback. If you ever want a last-resort
  local model, add a deployment at `order: 3` and a
  `config/llama-swap/imac.yaml` with `-ngl 0`.
- **A master key is mandatory.** LiteLLM refuses to start when every request
  would be accepted unauthenticated, so the installer generates one into
  `router.env` and clients send it. `config/router/router.env` is gitignored;
  no secret is in this repo.
- llama-swap binds `0.0.0.0:8080` and is default-allow on the LAN. Add
  `apiKeys:` to a host config if that is not acceptable to you; set the same
  value as `LOCAL_KEY` in `router.env`.

## Verified

Tested locally before publishing (llama-swap v269, LiteLLM 1.106.6):

- Both llama-swap configs parse and serve `/health`, `/v1/models` (correct model
  id, alias, 32k/64k context, tool-calling capability) and `/running`.
- LiteLLM loads the router config and lists `big`, `small`, `auto`.
- **Failover works:** with `order: 1` pointed at a dead port and `order: 2` at a
  stub server, a request to `auto` was served by the stub — the dead host did
  not fail the request.
- `scripts/status.sh` and `scripts/smoke.sh` run end to end against that setup.

Not verified (needs the real hosts):

- Actual model load/inference on either Mac, and the `-fa`/`-ctk`/`-ctv` flags
  with these specific GGUFs.
- launchd autostart (`scripts/install-launchd.sh`) — plists are syntax-checked
  with `plutil -lint` but have not been bootstrapped.
- Real laptop-off failover timing must be measured after deploying the timeout hook.

### Fast-fail connection policy

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

Tests (no models or real upstream requests):

```bash
.venv/bin/python -m unittest discover -s tests -v
```

These test real LiteLLM routing and its HTTP transport against local stub
servers, simulating a dropped connection and delayed response headers for
both streaming and non-streaming calls. Verified on LiteLLM 1.106.6.

## Not done / possible next steps

- Thunderbolt cable for the m4pro: no config change needed unless you want to
  pin it to the TB subnet.
- A bigger quant when the 35B fits better (`Q6_K` ≈ 28 GB still fits in the
  laptop's ~36 GB usable, minus KV).
- Cloud fallback: add an `order: 3` deployment to `config/router/config.yaml`
  pointing at OpenRouter, so `auto` never fails when both Macs are away.
- `iogpu.wired_limit_mb` tuning on the laptop if you push context/quant.
