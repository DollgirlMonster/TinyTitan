## NVMAI 5.4 — KAT-Coder-V2.5-Dev, and verification that never fetches a model

This release first ships the 5.3 work to users — 5.3 was tagged but never
published — together with a hardened release gate and a native app icon.

### KAT-Coder-V2.5-Dev 35B-A3B

Kwaipilot's agentic-coding fine-tune of Qwen 3.6 35B-A3B joins the family at
4-bit and 8-bit (`tools/install_models.sh katcoder`, `katcoder-8bit`, or
`katcoder both`). Same geometry as Qwen 3.6 and its own sampling — temperature
1.0, from the checkpoint's `generation_config.json`, not the series' 0.6.

Verified on the real install at both widths: the three continuations this
project uses behave (`The capital of France is` → ` Paris`, `Once upon a` →
` time`, `The quick brown fox jumps over the lazy` → ` dog`), each receipt
verifies, and each width has a golden baseline that re-checks byte-identical.
The baselines' 96-token answer is coherent technical prose about mutexes.

Measured on this base M3 with 24 GB through `benchmark/nvmai_maxthroughput.py`,
512-token greedy generations: **17.86 tok/s** at 4-bit and **6.91** at 8-bit. The
8-bit build streams 36.9 GB of routed experts from SSD, which makes it the most
expert-locality-sensitive install of the 35B family; its `count` prompt is the
worst case at both widths (11.34–17.86 tok/s at 4-bit, 1.00–6.91 at 8-bit).

### The expert axis was ordered by arrival, not by index

KAT's checkpoint is the first this project has converted whose routed experts
ship **one tensor per expert** rather than fused. The converter stacked them by
appending, which is only correct when they arrive in ascending index order. They
do not: the checkpoint index is lexicographically sorted, so layer 0's experts
arrive `0, 1, 10, 100, … 109, 11, 110, …` — 48 non-consecutive steps — and 12 of
the 40 layers also split their experts across two shards. The fused axis was
ordered by arrival, so the runtime routed to expert *k* and read expert *j*'s
weights.

**Nothing in the pipeline could see it.** Every expert's bytes matched the
checkpoint exactly; the shapes, the manifest and the `packed_experts` layout
were right; `validateRoleUniformity` passed; the receipt verified; and
`gturbo_diff_snapshot` reported all 613 resident tensors byte-identical. The
model answered fluently and *partly* correctly — "the capital of France"
appeared, then collapsed into repetition — at both widths, because the logits
came from the wrong experts.

It was found by converting Qwen 3.6 through the same converter as a control:
same geometry, but its source ships experts already fused, and it answered
correctly. That isolated the fault to the per-expert path, and comparing **expert
255** rather than 0 or 1 exposed the ordering — two earlier readings had called
the fusion correct because they spot-checked the first two experts, which happen
to arrive first.

The accumulator now preallocates the expert axis and files each expert at its own
index, rejecting a duplicate instead of overwriting. `tools/lint.sh converter`
feeds experts in shuffled order and asserts each lands at its index; reverting to
append reproduces `[3,0,7,1,5,2,6,4]` and fails it. It lives in the lint gate
rather than the Swift suite because no Swift test can observe a Python converter
bug.

### Three size caps that refused legitimate files

Found in the same run, each a literal chosen when an unbounded read was made
bounded, and each below what a real checkpoint produces:

- **The snapshot index** was capped at 4 MiB and KAT's is 9.7 MB, because the
  bound scales with tensors × key length and the converter's renames roughly
  double key length. The same literal was copied into the remote loader, so
  neither install path could build the model.
- **The resident index** was capped by the per-worker *staging* budget (1 MB)
  rather than the format's own ceiling, refusing an index of about 28 MB.
- **The runtime's manifest cap** was 4 MiB while `--verify-install` accepted the
  same 6.25 MB file against its own 64 MiB cap — so the install verified and
  then refused to load. A cross-module test now asserts the two ceilings agree.

### The runtime now streams KAT's experts from SSD

Before the fusion fix, KAT's routed experts were classified as *resident*
weights: the install declared `expertsPerLayer: 0`, carried no packed expert
files, and would have held all 256 experts per layer in RAM instead of
streaming them. The install built by this release declares **256** experts,
`expertStride 1769472`, **41 packed expert files**, and 1.8 GB of resident
weights with 17 GB streamed.

### Release verification uses only the models already installed

`models/` is deliberately kept below the full supported set to save disk, and the
golden gate now says so out loud instead of skipping silently:

- a target with no install is printed as **not checked** and collected;
- `--publish` refuses unless the release notes name **every** target that was not
  checked, absent ones included;
- an installed model that no `check_golden` line covers is a hard error, so a
  model cannot join the fleet unchecked; an intentional exception is declared in
  `NON_GOLDEN_INSTALLS` with its reason — the MTP draft head, and the dense
  Qwen 3.5 2B/4B/9B, which have no stored baseline at all;
- the phase fingerprints every `verified-install.json` before and after and fails
  if `models/` changed at all.

No release step downloads, converts, repacks or re-installs a model to make a
check pass. `docs/release-process.md` §5 states the policy and
`tools/release.sh` enforces it.

### Also in this release

- **`tools/install_models.sh <model> both`** installs 4-bit and 8-bit from one
  download for every Qwen3.5-MoE checkpoint (Ornith 1.5, Qwen 3.6,
  Qwen-AgentWorld, KAT). One width alone already converted both and kept the
  other snapshot; the install path now reuses it in either spelling, so a
  second width never re-fetches the checkpoint.
- **A downloader that survives a truncating link.** Shards are fetched as
  length-checked 64 MiB ranges, three at a time, with `--http1.1` (this host
  resets HTTP/2 streams continuously), a stall floor that aborts a dead
  connection, and no resume that could append to a truncated prefix. A
  truncation costs one chunk instead of 5 GB.
- **The tool scripts resolve their own Python** by capability — 3.10+ with
  `numpy`, `ml_dtypes` and `safetensors` — instead of a pinned `python3.13`, so
  they work wherever the analysis stack lives; `NVMAI_PYTHON` overrides.
- **A native NVMAI app icon**, replacing the upstream fork's bird. It uses the
  wordmark's own palette and is reproducible with `tools/make_app_icon.py`
  (issue #5).
- **The archive carries `NOTICE`.** The binary distribution now ships `LICENSE`,
  `NOTICE` and `THIRD_PARTY_NOTICES.md`: Apache-2.0 requires the first two to
  travel with the binaries, and the third carries the upstream attributions.
- **The app recognizes both KAT widths**, with descriptors carrying each
  snapshot's own fingerprint, and the install table in
  `AppModelInstallTests` covers ten builds.
- **`benchmark/nvmai_maxthroughput.py --engine cpu|gpu`** selects the engine and
  folds it into the result label, so a CPU row cannot be read as a GPU one.
- **The README benchmark table** carries KAT's measured rows and a
  GPU-versus-CPU table for the dense Qwen 3.5 models.

### Performance

KAT's rows are the only numbers this project measured itself, on this base M3
with 24 GB, through `benchmark/nvmai_maxthroughput.py`; they are in the README
table above and were **not** re-measured for 5.4. The dense Qwen 3.5
GPU-versus-CPU table added to the README is **not** a fresh measurement either: it
quotes the decode rates already recorded on the wiki's
[One Prompt, Every Model](https://github.com/Pummelchen/NVMAI/wiki/Capital-of-Paris-Smartness)
page, which was measured on this machine. Attempts to re-run the dense CPU
numbers were abandoned as unreliable — the 9B 8-bit thrashes on the CPU engine
(0.4–1.2 tok/s, one 512-token generation taking 1225 s) because that engine holds
the model resident instead of streaming experts — and the recorded numbers are
short-generation rates, not 512-token peaks like the rows above them.

### Verification

_To be completed from the dry run on the tagged commit before publishing._

The gate verifies every golden target that has an install under `models/` and
reports the rest. On the machine this was cut on, four targets are installed and
six are not, and the six are named here because they are **not** checked and must
not be assumed: **ornith-8**, **ornith-4**, **qwen36-4**, **qwen36-8**,
**agentworld-4** and **agentworld-8**. They are absent because the operator
deleted those installs to save disk; they were not downloaded to satisfy this
gate, and they must not be.

The four that are checked are **qwen38-4**, **qwen38-8**, **katcoder-4** and
**katcoder-8**.

### Checksum

`nvmai-5.4-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
