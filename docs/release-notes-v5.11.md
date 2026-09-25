## TinyTitan 5.11 — the installer is the delivery, and it refuses what cannot finish

The chat window no longer depends on any registry: the installer already
downloads the release tag's source archive, and this release makes that the
delivery — the bundle installs from there, the private DeepSeek Harness keeps
every cache inside its own root, and it finds the engine and the models where an
installed copy actually keeps them. The model installer gains two guarantees for
a machine whose disk is somebody's only disk: it refuses a download that cannot
finish before fetching a byte, and it stages under the install root instead of
the caller's home. Also here: a memory distillation no longer reads memory
before the previous session has written.

### The chat window arrives without a registry, and writes only inside its own root

`dsh-tinytitan` is deliberately **not** published to npm, and this release makes
that the supported path rather than a gap. `tools/install_tinytitan.sh` downloads
`archive/refs/tags/<tag>.tar.gz`, which carries `plugins/` beside `tools/`, and
`tools/dsh_local.sh ensure` adds the bundle from there with a `file:` install —
so the plugin reaches a user straight from the web and nobody needs a registry
account, ours or theirs. Verified end to end in a factory-new simulated home: the
engine and the tag's source were laid down, the plugin installed from
`<root>/src/plugins/dsh-tinytitan`, and the profile's dependency was that `file:`
path. The catalogue listing stays and points at the repository. The plugin code
itself is unchanged since 5.10; what changes is that it now arrives and runs on
an installed copy.

The private harness keeps every write under `~/.tinytitan/dsh`. Two escapes were
measured in that simulated home and are closed: `npm install --prefix <private>`
still wrote `~/.npm/_cacache` and `~/.npm/_logs` and read the user's `~/.npmrc`
(`--prefix` moves where packages are unpacked, not where npm keeps its cache),
and pnpm created `~/Library/pnpm` even with `--store-dir`. Every npm invocation
now carries `npm_config_cache` and `npm_config_userconfig`, and `PNPM_HOME` plus a
private XDG cache and state directory are set. `HOME`, `XDG_CONFIG_HOME` and
`XDG_DATA_HOME` stay the user's on purpose — the agent works inside their
repositories and must be able to read their git identity and their
`gh`/registry credentials. This is about what the bundle writes, not about
blinding the tools it drives.

Both installed-layout resolutions were wrong, in opposite directions, and are
fixed. `tools/dsh_route.sh` knew only `$BASE_DIR/.build/release`, so the
installer's own advice — re-run `tools/dsh_local.sh ensure` from a shell, where
`TINYTITAN_BIN_DIR` and `TINYTITAN_MODELS_DIR` are unset — failed with "no server
binary at …/.build/release/…", which a user reads as a missing model. It now
checks the installed layout (`../bin`, `../models`) before giving up.
`tools/dsh_local.sh` then handed the harness a hard-coded `$REPO_ROOT/models`; on
an installed copy that path is `<root>/src/models`, which holds no models, and
because the variable was set the route writer's own fallback could never run —
so the plugin's boot-time route refresh died with "no catalog (it lists no
installed models)". The models directory is now resolved once (explicit
variable, then `models/`, then `../models`) and `tools/dsh_local.sh paths` prints
it, so the resolution is observable rather than inferred.
`benchmark/test_dsh_route.py` pins the route writer's two fallbacks with a stub
engine that records its arguments, and `benchmark/test_dsh_isolation.py` pins the
three models-directory cases and refuses the hard-coded export.

### The model installer refuses a download that cannot finish

A download is a decision, and it now names what it needs before it starts. For
the chosen model, `tools/install_models.sh` checks both volumes and refuses to
begin when either cannot hold the work: the staging volume needs the catalogue's
install size plus a quarter more for the quantized snapshot plus a flat 12 GB for
the shard stream, the manifest and the receipt, and the models volume needs the
install size plus 3 GB. A snapshot already on disk is not fetched again and is
not counted twice; an unreadable `df` checks nothing, the same rule the runtime's
own guard follows. The refusal prints both numbers, both ways out — free space,
or `TINYTITAN_WORK_DIR=/Volumes/scratch/tt` on another volume — and
`TINYTITAN_SKIP_DISK_CHECK=1` to start anyway.

### Staging lives under the install root, and is reclaimed as widths complete

Every staging path used to be a bare `.build/...` and the script never changes
directory, so where tens to hundreds of GB landed depended on where the caller
happened to be standing. For a factory-new install, which runs the installer from
the user's home, that was `~/.build`: outside `~/.tinytitan`, invisible to
"removing those two directories removes the install", and on the Qwen3.8 path
alone it would hold 162–220 GB beside the same again in the install. Staging is
now `$ROOT/.build`, absolute and derived from the script's own path, so a release
install stages under `~/.tinytitan/src/.build` and a checkout under the repo's
`.build` as before; `TINYTITAN_WORK_DIR` moves it to another volume.

Staging also leaves as soon as it cannot save a future download. A converted
snapshot goes once every width that reuses it is installed (the paired MoE
widths, and the shared shard directory for Qwen3.8 and dense Qwen 3.5), and a
draft head's source shards go as soon as its install exists. What survives is
named with its size and how to reclaim it: `tools/install_models.sh clean` applies
the same rules to every model, reports what is left and why, and the installer
prints the hint once a model is in.

### An EOF at the model menu is not a choice

`tools/install_models.sh --choose` treats an empty line as "take the recommended
model", which is right — but a `read` that failed (Ctrl-D, or a caller that
closed stdin) left the same empty reply and began the recommended 36.9 GB
download with nobody choosing anything. Measured 2026-09-24 with stdin closed.
EOF now prints "No answer given; nothing was installed." and returns 2; only a
real empty line takes the default. `benchmark/test_install_models_menu.py` pins
both directions with the installer stubbed, so a regression prints `INSTALLED`
instead of downloading, and CI runs it beside the isolation gates.

### A memory distillation reads memory only after the one before it wrote

Two sessions in one scope distil through the same backend, and the later
extraction's prompt is built from a read of the store. When that read overtook
the earlier write, the later session saw an empty store, invented a parallel
namespace, and both values stayed live with no supersession possible. The
`contract` memory benchmark's logs have the shape exactly: session 2's extraction
was requested at 04:44:57 and wrote at 04:46:54, session 3's was requested in the
same minute and wrote `agreement/*` at 04:52:42 — which is why not one
`consolidation routed` line appears in any of the three runs. Distillations are
now chained per scope, so a later one reads only after the earlier one has
written. Waiting costs nothing real: the earlier generation already held the one
generation gate.

The address router stays as narrow as it was. Resolving prefixes by shared
segments would route `characters/tomas/location` onto `setting/location` and give
one character another character's fact — the false positive the router was
narrowed to prevent — so where the model reshapes a path
(`state/msa/notice_days` against `msa/commercial/termination_notice_days`) the
side-engine duplicate check remains the guard. Two tests pin the behaviour, one
of which reproduces two live addresses if the chain is removed.

### Also in this release

- **The launcher's `--ram` documentation says what the script does**: any whole
  number of GB from 4 up, with the interactive menu offering 4/8/16/32. The
  behaviour is unchanged since 5.10 — this corrects help text and the README that
  listed the menu's four choices as if they were the accepted set, and
  `benchmark/test_launcher_port.py` already passed `9` deliberately.

### Performance

Measured on this commit for this release against the 5.10 record
(`benchmark/internal-speeds/v5.11.json`): PENDING.

### Verification

Measured on this commit by the release dry run: PENDING.

**Nine golden targets are not checked**, because their install is not under
`models/` and nothing may be fetched to change that: `ornith-8`, `ornith-4`,
`qwen38-8`, `agentworld-4`, `agentworld-8`, `katcoder-4`, `katcoder-8`,
`qwen35-2b-4`, `qwen35-2b-8`.

### Checksum

`tinytitan-5.11-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.11-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
