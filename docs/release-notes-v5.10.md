## TinyTitan 5.10 — the RAM flag means the whole process, and Qwen3.8's sampling rows are real

`--ram` used to name the expert cache alone, so `--ram 8` produced a process using
11.6 GiB. It now targets the whole process, with a floor and a printed estimate —
a deliberate change to an existing flag, and this release's headline. Beside it:
Qwen3.8's two published sampling rows are implemented, the C kernels compile at
`-O2`, the expert-cache ceiling is a third of physical memory, twelve decode
switches that measured a wash or a loss are gone, and converting Qwen3.8 resumes
instead of restarting a 360 GB fetch.

### `--ram` is a target for the whole process, with a 4 GB floor

The flag bounded the expert cache, so the number and the memory used were
different things: `--ram 8` built a 7.92 GiB cache and, with 3.8 GiB of weights,
runtime and KV on top, used **11.63 GiB**. The cache now gets
`target - (model_weights.bin + residentRuntimeReserveBytes)`, where the 512 MiB
reserve is measured (the server loads at 3.75 GiB against a 3.22 GiB weight file,
and the smallest cache takes it to 4.74 GiB — exactly the cache delta), and the
slot count is the largest supported rung whose cache fits, **stepping down** so
the estimate never exceeds the number given. Every start prints it:

```
TinyTitan ram target=8.00G cache=3.96G slots=32 resident_floor=3.72G estimate=7.68G
```

Below the floor (about 4 GiB on the 125B install) the target is refused with the
real floor named; 4G is the minimum accepted. **This changes an existing flag**:
`--ram 8` now gives 32 slots where it gave 64 (cache 3.96 GiB against 7.92), so a
4-bit Qwen3.8 run at that setting is slower than it was on 5.9, and `--ram 12`
(64 slots, 7.92 GiB cache, 11.71 GiB peak) is the flag that reproduces the old
behaviour. Measured on the 24 GiB M3 with peak RSS sampled every 0.5 s (qwen38
4-bit, 256 greedy tokens), peak now tracks the estimate to within 0.2 GiB at
every rung: 4→8 slots/4.73 GiB, 6→16/5.84, 8→32/7.83, 10→48/9.83, 12→64/11.71.
On an idle machine and a 198-token prompt, two interleaved rounds: `--ram 8G`
gives 32 slots, **8,057 MiB peak in both rounds** and 3.34–3.58 tok/s; `--ram
10G` gives 48 slots, **10,098 MiB both rounds** and 3.97 tok/s; neither grows
swap and both answers are byte-identical. With the machine busy (load 6.5) the
rates fell ~15% and the 10G arm paged — load moves the rate and the peak, not the
plan.

### Qwen3.8's two sampling rows are implemented, and the row follows the request

The engine refused every non-zero presence penalty: the sampler's validation threw
and the OpenAI layer rejected `presence_penalty` outright. Qwen3.8's card asks for
1.5 outside thinking mode, so this implements it.

- Applied in the same host-side, pre-softmax window as the repetition penalty, in
  the softcap's space, once per distinct id in the history.
- Two explicit rows replace the single one: **thinking** 1.0 / top-p 0.95 /
  top-k 20, and **instruct** 0.7 / 0.80 / 20 with presence **1.5**. A request's
  own temperature, top-p or top-k still beats the row.
- The row is chosen from the request's `thinking` mode, so a non-thinking request
  no longer runs at thinking's temperature with no presence penalty.
- `--presence-penalty` (−2…2, OpenAI's range) joins the CLI, and `--thinking`
  selects the row, so the scripted path can express the instruct row at all.
- `min_p` is accepted but must be zero: the filter does not exist, and refusing
  beats sampling as if it did. Every shipped row uses 0.0.

### The expert-cache ceiling is a third of physical memory, not a half

`min(wanted, physicalMemory / 2)` handed a 24 GiB machine a 12 GiB budget and 64
slots — 4.22 GiB of cache against a 70.8 MB slot — which pages: swap **855 →
1,610 MB** at 5.58 tok/s, against flat swap at **7.29 tok/s** for the 40 slots a
third selects. A third also reproduces the budget the decode constants were tuned
on and scales down where a constant could not (an 8 GB mini previously got 64
slots). The cost on the large machine is small: **−1.3% decode** (16.55 against
16.76 tok/s, three interleaved pairs) with first token **improving** (1.27–1.32 s
against 1.44–1.56 s). A floor at the tuned budget, so only machines below the
tune are cut, is the obvious next experiment and is not done here.

### The C kernels compile at `-O2`

SwiftPM's `swiftbuild` compiles C at `-Os` where the older native planner used
`-O2`, which is not neutral here: the CPU int8 affine GEMV (8192×8192, 8 threads)
runs **2.35 ms** a pass at `-Os` against **1.94 ms** at `-O2`, minimum of six
interleaved rounds each with an identical checksum — **1.21×**. `Package.swift`
sets `.unsafeFlags(["-O2"])` on `TinyTitanKernelsC`, so the portable build carries
it; the price is that `.unsafeFlags` makes the package unusable as a dependency,
which is fine for an application nothing depends on. The internal-speed re-record
on the `-O2` default reads decode **+2.5%**, prefill **+6.5%**, first token
**−6.1%**.

### Twelve decode switches that measured a wash or a loss are gone

Each was measured on this build, recorded, and deleted rather than left in its
losing position; the shipped path is unchanged, which the goldens confirm
(qwen38-4 and qwen35-4b-4 byte-identical). Removed: `TINYTITAN_PREFETCH_PER_EXPERT`
(−2.0%/−3.3%), `…_PREFETCH_AHEAD=2` (−2.8%), `…_PREFETCH_TOP_M` (−6.6%/−9.8%),
`…_PREFETCH_MIN_MARGIN` (−4.2%), `…_PREFETCH_IO_TIER` (−0.1%/−0.6%),
`…_EXPERT_CACHE_POLICY` (washes), `…_CACHE_DECAY_HALFLIFE`, `…_EXPERT_CACHE_LAYOUT`
(−0.75%), `…_EARLY_HITS` (+2.2%, 1 of 2 runs), `…_KEEP_WIRED` (−0.37%),
`…_PARALLEL_IO` (+0.4%, 2 of 3 runs) and `…_PREFILL_LAYER_MAJOR` (−2.7×). Setting
one is now inert: the winning default is what runs. The options kept are product
API or hold an unmeasured balance, and the wiki's runtime-controls page lists
them.

### Converting Qwen3.8 resumes, and mirrors work

Building the Qwen3.8 snapshot means fetching 131 shards, 360 GB, and any
interruption used to mean fetching all of it again. The conversion now:

- **adopts the output shards a previous run finished** and skips the checkpoint
  shards whose every tensor is already present. A shard is adopted only when its
  payload matches the header's declared size — a kill mid-write leaves a file
  whose header parses and whose payload is short, and trusting the header alone
  is how a truncated snapshot gets indexed as complete. Flushes are written beside
  the destination and renamed, so a kill leaves a `*.partial` the next run
  deletes.
- **reuses a finished n-gram table in place** when its size and the constants
  addressing it match, builds a new one under a temporary name and renames it only
  when whole, and copies rather than hardlinking across filesystems; the installer
  passes `--share-ngram-table` only when staging and the install share a device.
- **retries a shard six times with backoff and a 20-minute `--max-time`**, and
  treats curl exit 33 (a mirror answering a range request with 200) as "drop the
  partial and start that file again" instead of retrying a request that can never
  progress.
- **fetches through a mirror** via `HF_ENDPOINT` or `--endpoint` on the Hub's URL
  layout, for the weights, the small JSON files and the tokenizer alike.
- **refuses two states rather than duplicating work**: a directory with finished
  `model-*-of-*.safetensors` but no index, and a resume whose recorded width
  differs from the `--bits` in hand.

Thirty-six end-to-end cases (`benchmark/test_qwen38_resume_e2e.py`) run the real
converter and real `curl` against a local mirror with injected drops,
truncations, 404s, stalls and refused ranges, apply a real `SIGKILL`
mid-conversion and a cross-filesystem copy, and require every recovery to end
byte-identical to a clean run. They run in CI.

### Also in this release

- **Prefetch depth 1 is the Qwen3.8 profile default**, re-measured on this engine:
  decode **+15.7%** at a 7-token prompt and **+14.6%** at ~500 tokens, expert
  misses −17% / −11%, responses byte-identical. The 8-bit row inherits it by
  inference — the ring is family-level and width-independent, and that install is
  not present to A/B — and the row comment says so.
- **The native-build experiment is gone**: `tools/build-native.sh` was dropped
  after its CPU flag measured ~1% (noise) on top of the `-O2` default, and the
  finding stays in `AGENTS.md` for a non-portable build.
- **The RAM-budget curve is measured 1–16 GB**, the page-cache trade is +4–5%
  decode for nothing on prefill, and three lines are closed with numbers:
  layer-major prefill (−2.7×), lossless compression of expert reads, and moving
  the decompression to another engine stage.

### Performance

Measured on this commit for this release against the 5.9 record
(`benchmark/internal-speeds/v5.10.json`).

### Verification

Measured on this commit by the release dry run. Nine golden targets are **not
checked**, because their install is not under `models/` and nothing may be fetched
to change that: `ornith-8`, `ornith-4`, `qwen38-8`, `agentworld-4`,
`agentworld-8`, `katcoder-4`, `katcoder-8`, `qwen35-2b-4`, `qwen35-2b-8`.

### Checksum

`tinytitan-5.10-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.10-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
