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

> **Running it:** per-node setup, client configuration, day-to-day commands, and
> troubleshooting live in [OPERATIONS.md](OPERATIONS.md).

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

## How it works

1. A client calls `/v1/chat/completions` with `auto`, `big`, or `small`.
2. `auto` is a LiteLLM deployment with `order: 1` (m4pro, 35B) and
   `order: 2` (mini, 8B). A connection failure on the first is escalated to the
   second instead of failing the request.
3. Each host's `llama-swap` starts the requested model on first use and unloads
   it after its `ttl`. Cold starts are expected; idle memory is not held.
4. An absent laptop is retried at most once per 60-second cooldown, and is
   re-admitted automatically when it returns.
5. Connection establishment is bounded separately from the long model-loading
   and read budget, so an offline laptop does not hold a request open for
   minutes. Details in
   [OPERATIONS.md](OPERATIONS.md#fast-fail-connection-policy).

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

## Design decisions

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

## Repository layout

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

Unlike the design notes here, the setup steps are host-specific: see
[OPERATIONS.md](OPERATIONS.md).

## Status

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
- Real laptop-off failover timing must be measured after deploying the timeout
  hook.

## What's next

- Thunderbolt cable for the m4pro: no config change needed unless you want to
  pin it to the TB subnet.
- A bigger quant when the 35B fits better (`Q6_K` ≈ 28 GB still fits in the
  laptop's ~36 GB usable, minus KV).
- Cloud fallback: add an `order: 3` deployment to `config/router/config.yaml`
  pointing at OpenRouter, so `auto` never fails when both Macs are away.
- `iogpu.wired_limit_mb` tuning on the laptop if you push context/quant.
