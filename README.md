<img width="1774" height="887" alt="image" src="https://github.com/user-attachments/assets/dc91bc31-0cd4-42e6-bc7a-67ffb277efe0" />




# NVMAI

[![Stars](https://img.shields.io/github/stars/Pummelchen/NVMAI?style=flat-square&logo=github&label=Stars&color=e3b341)](https://github.com/Pummelchen/NVMAI/stargazers)
[![Visitors (14d)](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/Pummelchen/NVMAI/main/.github/traffic.json)](https://github.com/Pummelchen/NVMAI)
[![Last Commit](https://img.shields.io/github/last-commit/Pummelchen/NVMAI?style=flat-square&logo=git&label=Last%20Commit&color=2ea44f)](https://github.com/Pummelchen/NVMAI/commits/main)
[![Contact](https://img.shields.io/badge/Contact-0xa0b1%40gmail.com-blue?style=flat-square&logo=gmail&logoColor=white)](mailto:0xa0b1@gmail.com)

NVMAI is the fastest SSD streamer for AI models on Mac - M1 to M6

## New in 5.4

This release first ships the 5.3 work to users, together with the release
verification policy.

- **KAT-Coder-V2.5-Dev 35B-A3B is supported**, at 4-bit and 8-bit. Kwaipilot's
  agentic-coding fine-tune of Qwen 3.6 arrives with its own sampling
  (temperature 1.0), three oracle continuations verified on the real install,
  and a golden baseline per width. **17.86 tok/s** at 4-bit, **6.91** at 8-bit.
- **Both widths of a model install from one download.**
  `tools/install_models.sh <model> both` converts 4-bit and 8-bit in a single
  pass over one ~70 GB checkpoint; asking for one width at a time fetches it
  twice. A second width now reuses the snapshot a previous run left behind.
- **The converter files routed experts by their index, not their arrival
  order.** KAT's checkpoint is the first whose experts ship one tensor per
  expert, and fusing them in arrival order silently paired each routing
  decision with another expert's weights — an install that loaded, passed every
  byte check, and answered nonsense. A `tools/lint.sh` gate now fails if the
  order regresses.
- **The downloader survives a link that truncates.** Shards are fetched in
  length-verified 64 MiB ranges with a small connection pool, so a 5 GB
  truncation costs one chunk instead of the whole shard.
- **The tool scripts pick their own Python**, by capability (3.10+ with
  `numpy`/`ml_dtypes`/`safetensors`) rather than by a pinned version, so they
  work wherever the analysis stack lives.
- **Release verification checks only the models you have installed.** The golden
  gate names every target it could not check instead of skipping it silently,
  refuses to publish unless the release notes repeat that list, and fails if the
  phase changes `models/` at all — so a release is never made to pass by
  downloading, converting or re-installing a model.
- **A native NVMAI app icon**, replacing the upstream fork's bird.

Fixed releases are tagged; the full history is in the
[Changelog](https://github.com/Pummelchen/NVMAI/wiki/Changelog).

## Benchmarks

Peak decode on a base 8-core M3 MacBook Pro with 24 GB.


| Model | Quantization | Peak decode |
| --- | --- | ---: |
| Qwen-AgentWorld 35B-A3B | 4-bit | **21.74 tok/s** |
| Ornith 1.5 35B-A3B | 4-bit | **21.65 tok/s** |
| Qwen 3.6 35B-A3B | 4-bit | **21.41 tok/s** |
| KAT-Coder-V2.5-Dev 35B-A3B | 4-bit | **17.86 tok/s** |
| Qwen 3.6 35B-A3B | 8-bit | **12.37 tok/s** |
| Qwen-AgentWorld 35B-A3B | 8-bit | **12.28 tok/s** |
| Ornith 1.5 35B-A3B | 8-bit | **11.93 tok/s** |
| KAT-Coder-V2.5-Dev 35B-A3B | 8-bit | **6.91 tok/s** |
| Qwen3.8-Flash-Next 125B-A6B | 4-bit | **5.46 tok/s** |
| Qwen3.8-Flash-Next 125B-A6B | 8-bit | **2.10 tok/s** |

The two KAT rows are measured, not quoted: 512-token greedy generations through
`benchmark/nvmai_maxthroughput.py`, taking the highest rate over its four
prompts (KAT 4-bit ranged 11.34-17.86 tok/s, the 8-bit 1.00-6.91). Its 8-bit
build streams 36.9 GB of experts from SSD, so its rate is the most
expert-locality-sensitive of the 35B family, and the `count` prompt is the
worst case in both widths.

### The dense Qwen 3.5 models on both engines

The 2B, 4B and 9B are the models that run on either engine, so they are the
only ones worth tabling twice. These decode rates were measured on this machine
by [One Prompt, Every Model](https://github.com/Pummelchen/NVMAI/wiki/Capital-of-Paris-Smartness),
which ran each install on both engines:

| Model | Quantization | GPU | CPU |
| --- | --- | ---: | ---: |
| Qwen 3.5 2B | 4-bit | **53.73 tok/s** | **15.42 tok/s** |
| Qwen 3.5 2B | 8-bit | **32.77 tok/s** | **15.83 tok/s** |
| Qwen 3.5 4B | 4-bit | **26.18 tok/s** | **7.71 tok/s** |
| Qwen 3.5 4B | 8-bit | **16.14 tok/s** | **7.04 tok/s** |
| Qwen 3.5 9B | 4-bit | **14.93 tok/s** | **4.07 tok/s** |
| Qwen 3.5 9B | 8-bit | **8.90 tok/s** | **4.51 tok/s** |

The CPU engine holds the model resident instead of streaming experts from SSD
the way the GPU path does, so the 9B is the one to watch: at 8.9 GB of weights
it can exceed the RAM of an 8 GB machine and spend its time paging. Prefer
4-bit there, and the GPU wherever the model fits.


### Supported LLMs

- **Qwen3.8-Flash-Next 125B-A6B**
- **KAT-Coder-V2.5-Dev 35B-A3B** — Kwaipilot's agentic-coding fine-tune of
  Qwen 3.6 35B-A3B, at 4-bit and 8-bit
  (`tools/install_models.sh katcoder|katcoder-8bit`). Same geometry as Qwen 3.6,
  with the checkpoint's own sampling (temperature 1.0) rather than the Qwen 3.6
  series' 0.6. Verified on the real install at both widths: the three
  continuations behave (`…France is` → ` Paris`, `Once upon a` → ` time`,
  `…the lazy` → ` dog`), and each width has a stored golden baseline that
  re-checks byte-identical.
- **Qwen-AgentWorld 35B-A3B**
- **Ornith 1.5 35B-A3B**
- **Qwen 3.6 35B-A3B**
- **Qwen 3.5 2B / 4B / 9B** — dense models at 4-bit and 8-bit, on either engine:
  the GPU by default, the CPU on request (`--engine cpu`, or the `@cpu` model id
  for one request). Converted from Qwen's own bf16 release by this project's
  converter (`tools/install_models.sh qwen35-2b|qwen35-4b|qwen35-9b`). The 9B is
  the vision-language build and is converted text-only, like every model here.
  These install as `.gturbo` directories with the same manifest and
  path-bound verification receipt as every other model here. They were affine
  snapshots until the repacker learned the dense shape; the two formats are
  verified equivalent rather than assumed to be, by a byte comparison of every
  resident tensor and by an identical-logits check
  (`tools/repack_dense.sh`, `docs/gturbo-format.md`).


### Usage

- **Easiest install:** one command checks the Mac, builds NVMAI, optionally
  downloads a model, and installs a double-clickable Mac app in
  `~/Applications`. Safe to re-run; it updates instead of cloning twice.
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Pummelchen/NVMAI/main/tools/install_nvmai.sh | bash
  ```
  From a clone, `tools/install_nvmai.sh` does the same. See
  [docs/site](docs/site/) for the plain-language article series, or
  `tools/install_nvmai.sh --help` for its flags.
- **OpenAI-compatible server:** A loopback Chat Completions and Responses API
  for starting NVMAI and connecting supported coding clients.
- **One server, one port, one launcher:** `tools/server_launcher.sh` starts the
  API on its own, or starts it and opens one of the supported clients — Codex,
  Claude Code, Qwen Code, OpenCode or the Zed editor — wiring that client's
  provider config to the model the server advertises. It asks what to launch
  from one list of every installed model and quantization (GPU and CPU), the
  thinking level that model supports, and an optional RAM limit for the expert
  cache (1/2/4/8/16/32 GB; the default is the install's own measured profile).
  It serves on `127.0.0.1:8080` (`NVMAI_PORT` overrides it), and every other
  installed model stays available by name through the API; the server switches
  on demand, keeping one model resident at a time.

```bash
tools/server_launcher.sh                                    # interactive
tools/server_launcher.sh --client codex --model ornith 4     # server + Codex
tools/server_launcher.sh --client zed --model qwen38 4 --ram 16
```

- **Persistent agent memory (optional):** With `NVMAI_MEMORY=1` the model gets
  memory that outlives a conversation, scoped per repository, with six memory
  tools the engine answers itself. It runs inside the server process, so there
  is no database to install and nothing to start. Off by default; see
  [docs/agent-memory.md](docs/agent-memory.md).
- **Three client protocols on one server:** OpenAI Chat Completions, the
  OpenAI Responses API (stored responses, `previous_response_id`, the full
  event grammar) and the Anthropic Messages API (`/v1/messages`,
  `count_tokens`, streaming), so Codex, Claude Code and the OpenAI and
  Anthropic SDKs all talk to the same model; see
  [docs/server-api.md](docs/server-api.md).
- **Tested coding CLIs:** The launch workflow supports Codex, Qwen Code, and
  OpenCode against the local server.
- **Mac app and tools:** NVMAI also provides a native Mac app, direct CLI
  generation, streaming responses, and client-authorized function-tool calls.


### Core Benefits

- NVMAI streams LLM's faster than any other similar project.
- Run large MOE AI models on low RAM Apple Silicon Macs by keeping the AI model on SSD/NVMe. 
- A 125B model on 8 GB of RAM. NVMAI streams experts straight from SSD, so model size is bounded by your disk space, not your memory.
- You set the RAM budget. NVMAI stays inside it. Give it 4 GB or 8 GB — it holds the line, so your Mac stays responsive while the model runs.
- Apple Neural Engine acceleration for prompt processing - 2.3× faster than the GPU cores.
- Our own Metal kernels, our own engine. Purpose-built for Apple silicon and engineered to use your Mac at the physical limit.
- No MLX. No GGUF. NVMAI ships its own high-speed model format and a converter that builds it straight from the original weights.
  

### Special Features

- **Bounded expert RAM:** The resident expert cache is sized per family from
  the model's own expert stride and clamped to half of physical memory, so a
  smaller Mac is not handed a budget tuned on a larger one. `--ram-budget`
  overrides it with any size. Model state, KV cache, and runtime scratch use
  additional memory.
- **Long context:** Native RoPE supports up to 262K tokens, while optional YaRN
  extends the context to 512K or 1M tokens.
- **Compressed KV cache:** Live attention state can use 16-bit, 8-bit, or 4-bit
  storage independently of the installed model quantization.
- **Thinking mode:** Ornith and Qwen support truthful Off/On reasoning control;
  their chat templates do not define Low, Medium, or High effort levels.
- **MTP off by default:** Native speculative decoding remains experimental and
  disabled because measured Ornith runs showed no speed benefit and it
  currently requires greedy decoding, native RoPE, and prompt-cache reuse off.

### Performance Improvements

- **Tiled Top-K sampling:** Production sampling (Top-K 1–64) runs a
  three-stage tiled GPU reduction, cutting per-token sampling cost from
  15.5 ms to 1.4 ms with a token-for-token identical stream — the main
  source of the v4.6 decode gain.
- **ANE prefill:** `NVMAI_PREFILL_ANE=on` runs
  full-attention prefill blocks on the Neural Engine from a one-time
  exported Core ML sidecar, roughly halving long-prompt time to first
  token; short prompts and decode are untouched.
- **Follow-up cache:** Exact live and multi-prefix prompt-state reuse avoids
  repeating compatible prefill work across conversation turns.
- **Concise mode:** An optional terse system prompt reduces generated text for
  workloads that benefit from it; standard responses are the default because
  they generalized more reliably in the coding/tooling qualification.
- **Fast alias:** The chat-only `-fast` model alias strips coding-agent
  boilerplate before prefill for quicker direct answers, while the base alias
  preserves tools and agent loops.


## Core Links

- [Getting started](https://github.com/Pummelchen/NVMAI/wiki/Getting-Started)
- [Features](https://github.com/Pummelchen/NVMAI/wiki/Features)
- [Local server and launchers](https://github.com/Pummelchen/NVMAI/wiki/OpenAI-Compatible-Server)
- [Runtime controls](https://github.com/Pummelchen/NVMAI/wiki/Runtime-Controls)
- [Benchmarks](https://github.com/Pummelchen/NVMAI/wiki/Benchmarks)
- [Changelog](https://github.com/Pummelchen/NVMAI/wiki/Changelog)
- [Repository layout](docs/repository-layout.md) — where everything lives, and
  the naming and file-size conventions

## Credits

NVMAI is a focused fork of
[drumih/turbo-fieldfare](https://github.com/drumih/turbo-fieldfare), which
provides the bounded-memory runtime, installer, CLI, Mac app, and local server.
The Qwen 3.6 integration was created by
[NeelM0906](https://github.com/NeelM0906) in
[upstream PR #29](https://github.com/drumih/turbo-fieldfare/pull/29). Concise
mode is derived from the
[Nail-Qwen3.6-35B-A3B](https://huggingface.co/peculiar-ragdoll/Nail-Qwen3.6-35B-A3B-MLX)
chat template by [peculiar-ragdoll](https://huggingface.co/peculiar-ragdoll).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Copyright (c) 2026 André Borchert.

## Contact

Questions, bug reports and suggestions are always welcome. You can contact André Borchert by email at [0xa0b1@gmail.com](mailto:0xa0b1@gmail.com).
