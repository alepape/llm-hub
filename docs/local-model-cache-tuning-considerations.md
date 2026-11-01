# Local model cache tuning — considerations for later

Status: investigation notes only; no tuning changes applied.

Source: `Why Your Mac Is Slow at Local AI (And It's Not the Chip).txt` in
this directory, compared with this repository's model-host configuration and
the mini's installed `llama-server` help output.

## Summary

Fast token generation can hide expensive repeated prompt processing. Prefix
cache reuse, rather than decode speed alone, is important for coding agents.
The transcript does not establish that this setup currently suffers from
excessive reprocessing: measurements are needed before changing defaults.

The M4 Pro's hybrid Qwen3.5 model is the strongest candidate for investigating
recurrent-state checkpoint behavior. The mini's dense Qwen3 model has different
cache characteristics and tighter memory constraints.

## Existing configuration

Both `config/llama-swap/m4pro.yaml` and `config/llama-swap/m2pro.yaml` use:

- GPU offloading: `-ngl 99`.
- Flash Attention: `-fa on`.
- Quantized KV cache: `-ctk q8_0 -ctv q8_0`.
- Explicit context sizes: 65536 on M4 Pro and 32768 on mini.

The mini's installed binary reports prompt caching enabled by default. Adding
`--cache-prompt` alone would not introduce a missing feature there.

The transcript's Ollama context-default issue and Claude Code-specific
attribution-header workaround do not directly apply to this OpenCode and
llama.cpp setup. Its numerical performance claims should not be treated as
measurements of these machines.

## Candidate experiments

### M4 Pro: recurrent-state checkpoint spacing

Qwen3.5's hybrid architecture cannot always rewind its cached state to an
arbitrary token. A changed prompt prefix may require restoring a checkpoint
and reprocessing the subsequent tokens, or a full reprocessing if no usable
state remains.

The mini's installed binary exposes:

```text
--ctx-checkpoints       default: 32 per slot
--checkpoint-min-step   default: 8192 tokens
```

First verify supported flags and defaults on the M4 Pro's own binary; they
were not checked remotely because the laptop does not run SSH.

Potential experiment: reduce `--checkpoint-min-step` to 2048 while initially
keeping the checkpoint count unchanged. This is not a guaranteed speedup:
checkpoint creation costs time and memory, and a smaller spacing does not
guarantee checkpoints at every interval. Benchmark realistic conversation
changes before adopting it.

### Both nodes: deliberate concurrency

Neither model config currently specifies `--parallel`. The mini's binary
reports automatic slot selection as its default.

For primarily one active coding session, test:

```text
--parallel 1
```

This can make resource use and cache behavior more predictable, but concurrent
OpenCode sessions and subagents will queue behind one inference slot. Compare
against normal multi-session use before changing defaults.

Do not assume four slots necessarily divide the context into four equal
parts: behavior depends on the llama.cpp version and unified-KV configuration.

### Mini: additional RAM prompt-cache limit

The mini's installed binary reports an 8192 MiB default limit for
`--cache-ram`. This is a ceiling, not an immediate 8 GB allocation, but it
deserves review on a 16 GB daily-driver machine.

Potential experiment: `--cache-ram 1024`, observing memory pressure, swap,
cache reuse, and response latency. Reducing the limit may increase cache
evictions and reprocessing.

Distinguish these separate caches:

- `LLAMA_CACHE`: downloaded model files on disk.
- Active inference KV/recurrent state: needed for the current context.
- `--cache-ram`: additional server prompt-cache storage.

### Retention and reasoning: leave unchanged initially

Current idle unloading is intentional:

- M4 Pro: 15 minutes.
- Mini: 10 minutes.

Unloading discards in-process inference cache state. A cold prompt after an
unload is expected, not proof of broken caching. Longer retention may help
interrupted work but conflicts with freeing memory while idle.

Do not blindly apply the transcript's recommendation to use medium reasoning
effort. Supported values and their effects depend on the model and template.
Reasoning preservation also depends on what OpenCode and the proxy send back
on subsequent turns, not just a server setting.

## Measurement plan

1. Record each node's llama.cpp version, supported options, and effective
   startup settings before testing.
2. Establish a baseline using repeated conversation turns, tool calls, and
   switching between two sessions.
3. Measure cached tokens, newly processed prompt tokens, prefill time,
   time to first token, decode speed, and memory pressure. Separate model
   cold-loading from cold prompt processing.
4. Temporarily use llama-server verbosity 4 and capture model subprocess
   output, not only llama-swap HTTP logs. Look for checkpoint restoration and
   full prompt reprocessing messages. Avoid full-prompt logging and redact
   any sensitive content before sharing diagnostics.
5. Test one change at a time: M4 Pro checkpoint spacing, mini RAM-cache limit,
   and explicit concurrency on each node.
6. Compare equivalent direct-local and router requests to investigate whether
   request formatting affects prefix reuse. Include actual OpenCode turns:
   a synthetic repeated prompt alone cannot validate the client's behavior.
7. Keep only changes that improve realistic workloads without unacceptable
   memory pressure, reduced concurrency, or quality regressions.

## Possible implementation direction

Prefer opt-in diagnostics and per-host tuning controls over immediately
replacing working defaults. Most server flags belong in
`config/llama-swap/{m4pro,m2pro}.yaml`; the existing
`scripts/start-models.sh` does not need a rewrite solely for these experiments.

No speedup is promised, and no model-host settings were changed during this
review.
