## TinyTitan 5.11 — a browser chat window that installs without a registry, and an installer that refuses what cannot finish

The Mac app is gone; the chat window is now a local DeepSeek Harness carrying this
project's plugin, and it installs straight from the release with no npm account on
either side. The model installer also gains two habits of a careful tool: it refuses
a download that cannot finish, and it keeps its staging inside the install root.

### The chat window: what `dsh-tinytitan` is, and how to install it

- **What it is.** A DeepSeek Harness (DSH) bundle. DSH is an open-source agent UI,
  and the bundle points it at the TinyTitan server on loopback, keeps that route
  current as models are installed, and forces thinking off for the harness's own
  compaction calls, so a local reasoning model does not spend a summariser's whole
  budget thinking.
- **Why a bundle and not an app.** The harness's own adapter serves the models, so
  this adds configuration, not a protocol: nothing is patched, no protocol copy can
  drift, and it composes with a harness the user already runs.
- **Install.** Run the installer and accept the chat window when it is offered; a
  model has to be installed first:
  `bash -c "$(curl -fsSL https://raw.githubusercontent.com/Pummelchen/TinyTitan/main/tools/install_tinytitan.sh)"`.
  Then start it with `~/.local/bin/tinytitan-web`, or `tools/server_launcher.sh
  --web` from a checkout. The harness **and** the bundle come from the release
  tag's source archive, which carries `plugins/`; `dsh_local.sh ensure` adds them
  with a `file:` install, and the plugin is deliberately not published to npm.
  Reference: [TinyTitan Plugin](https://github.com/Pummelchen/TinyTitan/wiki/TinyTitan-Plugin).
- **Benefits.** One command sets up engine, models, window and route; the harness is
  private and pinned under `~/.tinytitan/dsh`, so a DSH you already run is never
  read, written or stopped, including its npm and pnpm caches; the model list
  follows `models/` without a restart; and installing a model cannot quietly fill
  the disk.
- **Limitations.** It supports exactly one harness release (`0.1.6-alpha.2`) and
  refuses any other, by design — DSH is a developer preview that says it will break
  compatibility. It is loopback-only, so reaching it from another machine is
  upstream's call (TT-020), and session titles are not covered by the compaction
  row. macOS Apple Silicon only, and the binaries are not notarized.

### Also in this release

- **The model installer refuses a download that cannot finish**, before fetching a
  byte: the staging volume needs the install size × 1.25 plus 12 GB, the models
  volume the install size plus 3 GB. It prints both numbers and both ways out —
  free space, or `TINYTITAN_WORK_DIR` on another volume — with
  `TINYTITAN_SKIP_DISK_CHECK=1` to override.
- **Staging stays inside the install root.** It used to be a relative `.build/…`,
  which for a factory-new install meant `~/.build` in the user's home. A converted
  snapshot is deleted once every width that reuses it is installed, and
  `install_models.sh clean` reclaims the rest.
- **An EOF at the model menu installs nothing.** Ctrl-D or a closed stdin used to
  fall through to the recommended model and begin a 36.9 GB download.
- **Memory keeps one address per fact.** Two sessions in one project could distil
  at once, so the later one read a store the earlier had not written yet, invented a
  parallel key, and both values stayed live; distillations are now chained per
  project.
- **`--ram` help says what it accepts**: any whole GB from 4 up, not only the
  interactive menu's 4/8/16/32. No behaviour change.

### Performance

Measured on this commit for this release against the 5.10 record
(`benchmark/internal-speeds/v5.11.json`), on the 4B dense install, with residual
background load (load average 2.4–3.0):

- GPU QKV GEMV **74.1 GB/s** (+9.9%), routed MoE **41.8 GB/s** (+1.0%), GDN
  in-projection **82.2 GB/s** (+7.0%); CPU int8 GEMV **60.8 GB/s** (+11.2%);
- prefill **28.0 tok/s** (+8.0%), decode **28.3 tok/s** (+8.5%), effective decode
  **76.6 GB/s** (+8.4%), first token **0.25 s** (−7.4%); ANE prefill **52.1 tok/s**
  (+4.1%);
- every metric inside the 10% gate and none regressed. The greedy response is
  byte-identical to 5.10 and coverage and repetition are unchanged, so nothing here
  moved arithmetic — the uniformly better readings are the machine's condition, not
  a code change.

### Verification

The dry run and the publish pass, on the tagged tree:

- six lint gates clean (2,031 functions, 20 scripts); **1,493 tests in 223 suites**;
- **7 golden baselines byte-identical** — qwen36-4, qwen36-8, qwen38-4,
  qwen35-4b-4, qwen35-4b-8, qwen35-9b-4, qwen35-9b-8;
- a clean scratch release build, warning scan clean, and the archive packaged from
  that tree;
- the bundle's install path is pinned by tests rather than by hand: 13 route tests
  and 13 isolation tests, both plugin suites in CI.

**Not checked, because their install is not under `models/` and nothing may be
fetched to change that**: `ornith-8`, `ornith-4`, `qwen38-8`, `agentworld-4`,
`agentworld-8`, `katcoder-4`, `katcoder-8`, `qwen35-2b-4`, `qwen35-2b-8`.

### Checksum

`tinytitan-5.11-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.11-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
