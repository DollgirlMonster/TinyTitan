#!/usr/bin/env bash
# TinyTitan's own, isolated DeepSeek Harness.
#
# `dsh web` is the optional browser window the installer can set up: a local
# page with a prompt box, pointed at the TinyTitan server. This script owns that
# runtime and nothing else.
#
# **Isolation is the point.** A user may already run DeepSeek Harness — their
# own `dsh` on PATH, their own `~/.dsh`, their own UI on 3080. Nothing here may
# touch any of it, so:
#
#   * our `dsh` is installed into a private npm prefix and is never put on PATH;
#   * DSH_HOME points at our own home, so profiles, sessions, settings and the
#     plugin copy live there and the user's ~/.dsh is never read or written;
#   * pnpm's store is redirected into the same private root;
#   * the browser UI binds 7788 (TINYTITAN_DSH_PORT), not DSH's default 3080,
#     and steps up to the next free port if 7788 is already taken. A port held
#     by an earlier run of *this* install is stopped and reused; a port held by
#     anything else is left alone and the search moves on.
#
# Node is reused when the machine already has one, and only fetched into
# ~/.tinytitan/dsh/node when it does not, so this never runs `brew install` and
# never writes a global npm prefix.
#
# The DeepSeek Harness version is **pinned**. It is the version this project
# supports and has tested the plugin against; DSH is in developer preview and
# says outright that it will break compatibility between releases, so a floating
# version here would turn a working install into a broken one overnight. Moving
# the pin is a deliberate change, made with the plugin in hand.
#
#   tools/dsh_local.sh ensure [--port N] [--model ID]
#                                          install or refresh the private runtime,
#                                          and point the harness default at ID
#                                          (default: the first model the route serves)
#   tools/dsh_local.sh web [--dsh-port N]  run our `dsh web` (server already up)
#   tools/dsh_local.sh port [--dsh-port N] print the free port `web` would use
#   tools/dsh_local.sh status              what is installed, and where
#   tools/dsh_local.sh paths               the private paths, for scripting
#   tools/dsh_local.sh --help
#
# Environment:
#   TINYTITAN_DSH_ROOT            private root (default ~/.tinytitan/dsh)
#   TINYTITAN_DSH_VERSION         pinned DeepSeek Harness version
#   TINYTITAN_DSH_NODE_VERSION    pinned Node, used only when the Mac has none
#   TINYTITAN_DSH_PNPM_VERSION    pinned pnpm, installed into the private prefix
#   TINYTITAN_DSH_PORT            browser UI port (default 7788)
#   TINYTITAN_DSH_DRY_RUN=1       print what would happen, change nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/dsh-tinytitan"

# Pinned on purpose; see the header. 0.1.5-rc.2 is the version the plugin was
# written and tested against.
DSH_VERSION="${TINYTITAN_DSH_VERSION:-0.1.5-rc.2}"
NODE_VERSION="${TINYTITAN_DSH_NODE_VERSION:-26.8.2}"
PNPM_VERSION="${TINYTITAN_DSH_PNPM_VERSION:-12.4.2}"
DSH_PORT="${TINYTITAN_DSH_PORT:-7788}"
# The served id the harness should open on. Empty means "the first one the route
# serves", which is what a bare `ensure` from the installer uses.
DEFAULT_MODEL_ID=""

DSH_ROOT="${TINYTITAN_DSH_ROOT:-$HOME/.tinytitan/dsh}"
DSH_HOME_DIR="$DSH_ROOT/home"
DSH_PREFIX="$DSH_ROOT/npm-prefix"
DSH_NODE_DIR="$DSH_ROOT/node"
DSH_STORE="$DSH_ROOT/store"
DSH_BIN_DIR="$DSH_ROOT/bin"
VERSION_MARKER="$DSH_ROOT/.dsh-version"

DRY_RUN=0
[[ "${TINYTITAN_DSH_DRY_RUN:-0}" == "1" ]] && DRY_RUN=1

# Whether `web` lets DSH open the default browser. `--no-open` or
# TINYTITAN_DSH_NO_OPEN=1 turns it off, for an SSH session or a test that must
# not hijack whatever browser happens to be running.
DSH_OPEN=1
[[ "${TINYTITAN_DSH_NO_OPEN:-0}" == "1" ]] && DSH_OPEN=0

# The server port the route should point at: the launcher's default, overridden
# by TINYTITAN_PORT, and set by `ensure --port`.
SERVER_PORT="${TINYTITAN_PORT:-8080}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# run <description> <command…>: one place that honours --dry-run and prints the
# command, so a dry run is a readable transcript rather than a guess.
run() {
  local description="$1"; shift
  if (( DRY_RUN )); then
    printf '  would %s\n    $ ' "$description"
    printf '%q ' "$@"; echo
    return 0
  fi
  "$@"
}

# --- where things are -------------------------------------------------------

dsh_bin() { printf '%s' "$DSH_PREFIX/node_modules/.bin/dsh"; }
pnpm_bin() { printf '%s' "$DSH_BIN_DIR/pnpm"; }

# The Node we will use. An existing node+npm wins; otherwise ours, if it is
# already unpacked; otherwise nothing yet (install_node supplies it).
system_node() { command -v node 2>/dev/null; }
system_npm()  { command -v npm  2>/dev/null; }
private_node(){ [[ -x "$DSH_NODE_DIR/bin/node" ]] && printf '%s' "$DSH_NODE_DIR/bin/node"; }
private_npm() { [[ -x "$DSH_NODE_DIR/bin/npm" ]] && printf '%s' "$DSH_NODE_DIR/bin/npm"; }

node_bin() {
  local system; system="$(system_node || true)"
  if [[ -n "$system" ]]; then printf '%s' "$system"; return 0; fi
  private_node
}

npm_bin() {
  local system; system="$(system_npm || true)"
  if [[ -n "$system" ]]; then printf '%s' "$system"; return 0; fi
  private_npm
}

# `node`, `npm`, `pnpm` and `dsh` are all `#!/usr/bin/env node` scripts, so every
# one of them needs *the Node we chose* on PATH — not merely a path to it. This
# mattered the moment it was tested on a Mac with no Node: the private Node
# unpacked correctly and the very next command died with
# `env: node: No such file or directory`, because nothing had put its bin
# directory on PATH. Use `tool_path` for every invocation of a JS tool.
node_bin_dir() {
  local node; node="$(node_bin)"
  [[ -n "$node" ]] && dirname "$node"
}

tool_path() {
  local node_dir; node_dir="$(node_bin_dir || true)"
  printf '%s' "${node_dir:+$node_dir:}$DSH_BIN_DIR:$DSH_PREFIX/node_modules/.bin:$PATH"
}

# --- node -------------------------------------------------------------------

# Fetch Node into our own root. Only reached when the Mac has no node at all,
# because the alternative — `brew install node` — writes a system-wide package
# for a feature the user may never turn on.
install_node() {
  if [[ -n "$(system_node || true)" && -n "$(system_npm || true)" ]]; then
    ok "Using the Node already on this Mac ($(node --version))"
    return 0
  fi
  if [[ -x "$DSH_NODE_DIR/bin/node" ]]; then
    ok "Using the private Node at $DSH_NODE_DIR ($("$DSH_NODE_DIR/bin/node" --version))"
    return 0
  fi

  [[ "$(uname -m)" == "arm64" ]] \
    || die "TinyTitan is Apple Silicon only; this Mac reports $(uname -m)."
  command -v curl >/dev/null 2>&1 || die "curl is required to fetch Node."

  local tarball="node-v${NODE_VERSION}-darwin-arm64.tar.gz"
  local url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  say "Installing a private Node $NODE_VERSION (no Homebrew, nothing system-wide)"
  echo "  This is about 50 MB and lands only in $DSH_NODE_DIR."
  local tmp; tmp="$(mktemp -d)"

  run "download Node from nodejs.org" curl -fsSL "$url" -o "$tmp/$tarball"
  if (( DRY_RUN )); then rm -rf "$tmp"; return 0; fi
  mkdir -p "$DSH_NODE_DIR"
  tar -xzf "$tmp/$tarball" -C "$DSH_NODE_DIR" --strip-components=1
  rm -rf "$tmp"
  [[ -x "$DSH_NODE_DIR/bin/node" ]] || die "the Node download did not unpack as expected."
  ok "Private Node ready at $DSH_NODE_DIR"
}

# --- the private install ----------------------------------------------------

install_dsh() {
  local installed=""
  [[ -f "$VERSION_MARKER" ]] && installed="$(cat "$VERSION_MARKER")"
  if [[ "$installed" == "$DSH_VERSION" && -x "$(dsh_bin)" ]]; then
    ok "DeepSeek Harness $DSH_VERSION already installed"
    return 0
  fi

  local npm; npm="$(npm_bin)"
  [[ -n "$npm" ]] || die "no npm available (neither the Mac's nor ours)."

  say "Installing the pinned DeepSeek Harness $DSH_VERSION"
  echo "  Into $DSH_PREFIX. Your own dsh and ~/.dsh are not touched."
  run "install @deepseek-ai/dsh@$DSH_VERSION" \
    env PATH="$(tool_path)" \
    "$npm" install --prefix "$DSH_PREFIX" --no-fund --no-audit \
    "@deepseek-ai/dsh@$DSH_VERSION"
  (( DRY_RUN )) && return 0
  [[ -x "$(dsh_bin)" ]] || die "the DeepSeek Harness install produced no dsh binary."
  mkdir -p "$DSH_ROOT"
  printf '%s\n' "$DSH_VERSION" > "$VERSION_MARKER"
  ok "DeepSeek Harness $DSH_VERSION"
}

# `dsh plugin` forwards to pnpm, and pnpm on macOS is a trap worth naming.
#
# The `pnpm` npm package installs a **shebang-less** wrapper whose own comments
# explain why: a bin shim generated from a shebang records the interpreter, and
# pnpm generates the shim before it puts the native binary in place. A shell, or
# glibc's execvp, retries such a file through `sh`; **Apple's libc does not**, and
# neither does Node's spawnSync without a shell — so `dsh plugin`, which spawns
# `pnpm` itself, dies with `spawnSync pnpm ENOEXEC` on macOS.
#
# The fix is to give the private install a shim we control, with a real shebang,
# that execs the native binary the package did unpack (`@pnpm/exe.darwin-arm64`).
# There is a fallback to the package's own `.mjs` entry through Node, so this
# still works on a machine where the native binary was not fetched.
#
# pnpm is installed into our own prefix rather than enabled through corepack,
# which would write shims into whichever Node install happens to be on PATH.
install_pnpm() {
  local shim; shim="$(pnpm_bin)"
  if [[ -x "$shim" ]] && "$shim" --version >/dev/null 2>&1; then
    ok "pnpm already present (private shim)"
    return 0
  fi

  local native="$DSH_PREFIX/node_modules/@pnpm/exe.darwin-arm64/pnpm"
  local mjs="$DSH_PREFIX/node_modules/pnpm/bin/pnpm.mjs"
  if [[ ! -f "$mjs" ]]; then
    local npm; npm="$(npm_bin)"
    run "install pnpm@$PNPM_VERSION (private)" \
      env PATH="$(tool_path)" \
      "$npm" install --prefix "$DSH_PREFIX" --no-fund --no-audit "pnpm@$PNPM_VERSION"
    (( DRY_RUN )) && return 0
  fi

  mkdir -p "$DSH_BIN_DIR"
  if [[ -x "$native" ]]; then
    cat > "$shim" <<SHIM
#!/bin/sh
# TinyTitan's private pnpm, written by tools/dsh_local.sh.
# Execs the native binary directly: the npm package's own shim has no shebang,
# which macOS refuses to exec (ENOEXEC) when a program spawns it without a shell.
exec "$native" "\$@"
SHIM
  else
    local node; node="$(node_bin)"
    [[ -n "$node" ]] || die "no node to run pnpm with."
    cat > "$shim" <<SHIM
#!/bin/sh
# TinyTitan's private pnpm, written by tools/dsh_local.sh.
# The native binary was not installed, so hand over to the package's own entry.
exec "$node" "$mjs" "\$@"
SHIM
  fi
  chmod +x "$shim"
  ok "pnpm $("$shim" --version 2>/dev/null || echo "$PNPM_VERSION") via $shim"
}

# A fresh DSH_HOME has no settings.yaml: DSH creates profiles/ and storages/ but
# leaves the settings file to the user. `tools/dsh_route.sh --write` refuses to
# write into a file that is not there, so we create it — which is also the only
# sane default, because an empty settings file is exactly "no overrides".
ensure_home() {
  if [[ -d "$DSH_HOME_DIR/profiles/web" ]]; then
    ok "Private DSH home already initialised"
  else
    say "Initialising the private DSH home"
    run "initialise the web profile under $DSH_HOME_DIR" \
      env DSH_HOME="$DSH_HOME_DIR" PATH="$(tool_path)" \
      "$(dsh_bin)" --profile web --dump-config
    (( DRY_RUN )) || ok "Private DSH home at $DSH_HOME_DIR"
  fi

  if [[ -f "$DSH_HOME_DIR/settings.yaml" ]]; then
    ok "settings.yaml present"
  else
    (( DRY_RUN )) && { echo "  would create $DSH_HOME_DIR/settings.yaml"; return 0; }
    mkdir -p "$DSH_HOME_DIR"
    cat > "$DSH_HOME_DIR/settings.yaml" <<'YAML'
# TinyTitan's private DeepSeek Harness settings.
#
# This file belongs to the TinyTitan install under ~/.tinytitan, not to your own
# ~/.dsh. The llm-pi-ai route below is generated by tools/dsh_route.sh from the
# models installed in the checkout.
YAML
    ok "Created $DSH_HOME_DIR/settings.yaml"
  fi
}

# The plugin is installed from this checkout on purpose: it is project-internal,
# not published to npm, so there is no registry package to depend on and no
# second copy to keep in step. A `file:` install is a copy, so re-running `add`
# is how a plugin edit reaches the private home.
install_plugin() {
  [[ -d "$PLUGIN_DIR" ]] || die "plugin not found at $PLUGIN_DIR"
  say "Installing the TinyTitan plugin into the private profile"
  # `--store-dir` is passed straight through to pnpm, and it is the only lever
  # that works: pnpm ignores `npm_config_store_dir` and `PNPM_STORE_DIR`, and a
  # `.npmrc` beside the profile did not move the store either. Without it the
  # ~36 MB native pnpm binary would land in the user's own ~/Library/pnpm store.
  run "add dsh-tinytitan from the checkout" \
    env DSH_HOME="$DSH_HOME_DIR" \
        PATH="$(tool_path)" \
        "$(dsh_bin)" plugin --profile web add --store-dir "$DSH_STORE" "file:$PLUGIN_DIR"
  (( DRY_RUN )) && return 0
  [[ -e "$DSH_HOME_DIR/profiles/web/node_modules/dsh-tinytitan" ]] \
    || die "the plugin did not install into the private profile."
  ok "Plugin installed (pinned to this checkout)"
}

# The route is what points DSH at the TinyTitan server. It is generated from the
# installs under models/, so the model the user chose is the model DSH offers.
write_route() {
  say "Writing the TinyTitan route (port $SERVER_PORT)"
  if ! run "generate the llm-pi-ai route into the private settings.yaml" \
      "$REPO_ROOT/tools/dsh_route.sh" --write \
      --settings "$DSH_HOME_DIR/settings.yaml" --port "$SERVER_PORT"; then
    warn "Could not write the route — is a model installed under models/?"
    warn "Install one, then re-run: tools/dsh_local.sh ensure"
    return 1
  fi
  (( DRY_RUN )) || ok "Route written to $DSH_HOME_DIR/settings.yaml"
}

# DeepSeek Harness ships `agent-default-model` pointing at **its own hosted
# route** — `provider: deepseek-official, model: deepseek-flash`. A fresh private
# install therefore opens on a provider we have no key for and fails with
# `MISSING_CREDENTIAL: llm-deepseek`, which is the exact opposite of a window
# that is ready to go. Writing a route is not enough; the default model has to be
# pointed at it. This was found by dry-testing the install, not by reading it.
#
# The settings file is ours (we create it), so this is line surgery on a file we
# own rather than on the user's: drop any existing top-level block, append ours.
write_default_model() {
  local provider="$1" model="$2"
  [[ -n "$model" ]] || return 0
  (( DRY_RUN )) && { echo "  would set agent-default-model to $provider/$model"; return 0; }
  PROVIDER="$provider" MODEL="$model" python3 - "$DSH_HOME_DIR/settings.yaml" <<'PY'
import os, sys

path = sys.argv[1]
provider = os.environ["PROVIDER"]
model = os.environ["MODEL"]
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines = []

out, i = [], 0
while i < len(lines):
    if lines[i].startswith("agent-default-model:"):
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if nxt.strip() == "" or nxt[:1] in (" ", "\t") or nxt.startswith("#"):
                i += 1
                continue
            break
        continue
    out.append(lines[i])
    i += 1
while out and out[-1].strip() == "":
    out.pop()
out += ["", "agent-default-model:", f"  provider: {provider}", f"  model: {model}"]
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(out) + "\n")
PY
  ok "Harness default model: $provider/$model"
}

# The first served id in the route, skipping the `<id>-fast` chat alias: the
# default a bare `ensure` gets when the caller did not name one.
first_served_model() {
  python3 - "$DSH_HOME_DIR/settings.yaml" <<'PY'
import re, sys

try:
    text = open(sys.argv[1], encoding="utf-8").read()
except FileNotFoundError:
    sys.exit(0)
for match in re.finditer(r"^\s*-\s*id:\s*(\S+)\s*$", text, re.M):
    if not match.group(1).endswith("-fast"):
        print(match.group(1))
        break
PY
}

# --- the browser port -------------------------------------------------------

# 7788 is the default, but it is a port like any other: something else may hold
# it. Rather than fail, walk upward to the first free one. The one case worth
# special handling is a previous run of *this* install, which would otherwise
# leave a new UI on 7789, then 7790, one per launch; that one is stopped and its
# port reused. A port held by anything we cannot identify as ours is never
# touched -- the launcher's rule for the server port, applied here.

port_listening() { lsof -i :"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# Is every listener on this port one of our own dsh processes? Our dsh runs from
# the private prefix, and node puts that path in the command line, so the prefix
# is a reliable fingerprint that does not depend on the port.
port_holders_are_ours() {
  local pid found=0
  for pid in $(lsof -ti :"$1" -sTCP:LISTEN 2>/dev/null); do
    found=1
    ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "$DSH_PREFIX" || return 1
  done
  (( found ))
}

stop_ours_on_port() {
  local pid
  for pid in $(lsof -ti :"$1" -sTCP:LISTEN 2>/dev/null); do
    if ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "$DSH_PREFIX"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  local _; for _ in $(seq 1 50); do
    port_listening "$1" || break
    sleep 0.1
  done
}

# resolve_port <preferred> -> the port to use, on stdout.
resolve_port() {
  local base="$1" candidate
  for (( candidate = base; candidate <= base + 100 && candidate <= 65535; candidate++ )); do
    if ! port_listening "$candidate"; then
      (( candidate == base )) || printf '  \033[33m!\033[0m Port %s is taken; using %s instead.\n' "$base" "$candidate" >&2
      printf '%s' "$candidate"
      return 0
    fi
    if port_holders_are_ours "$candidate"; then
      printf '  \033[33m!\033[0m Stopping the DeepSeek Harness this install left on port %s.\n' "$candidate" >&2
      stop_ours_on_port "$candidate"
      if ! port_listening "$candidate"; then printf '%s' "$candidate"; return 0; fi
    fi
  done
  die "ports ${base}-$((base + 100)) are all in use; free one or pass --dsh-port."
}

# --- commands ---------------------------------------------------------------

cmd_paths() {
  printf '%-14s %s\n' root "$DSH_ROOT"
  printf '%-14s %s\n' home "$DSH_HOME_DIR"
  printf '%-14s %s\n' prefix "$DSH_PREFIX"
  printf '%-14s %s\n' node "$DSH_NODE_DIR"
  printf '%-14s %s\n' store "$DSH_STORE"
  printf '%-14s %s\n' dsh "$(dsh_bin)"
  printf '%-14s %s\n' pnpm "$(pnpm_bin)"
  printf '%-14s %s\n' port "$DSH_PORT"
  printf '%-14s %s\n' version "$DSH_VERSION"
  printf '%-14s %s\n' plugin "$PLUGIN_DIR"
}

cmd_status() {
  say "TinyTitan's private DeepSeek Harness"
  echo
  local node; node="$(node_bin || true)"
  if [[ -n "$node" ]]; then
    ok "node: $node ($("$node" --version))"
  else
    warn "node: none found (ensure will fetch one privately)"
  fi
  if [[ -x "$(dsh_bin)" ]]; then
    ok "dsh:  $(dsh_bin) (pinned $DSH_VERSION)"
  else
    warn "dsh:  not installed — run: tools/dsh_local.sh ensure"
  fi
  if [[ -x "$(pnpm_bin)" ]]; then
    ok "pnpm: $(pnpm_bin)"
  else
    warn "pnpm: not installed (needed for the plugin)"
  fi
  if [[ -d "$DSH_HOME_DIR/profiles/web" ]]; then
    ok "home: $DSH_HOME_DIR"
  else
    warn "home: not initialised"
  fi
  if [[ -e "$DSH_HOME_DIR/profiles/web/node_modules/dsh-tinytitan" ]]; then
    ok "plugin: installed"
  else
    warn "plugin: not installed"
  fi
  if [[ -f "$DSH_HOME_DIR/settings.yaml" ]] \
     && grep -q '^llm-pi-ai:' "$DSH_HOME_DIR/settings.yaml"; then
    ok "route: written"
  else
    warn "route: not written"
  fi
  echo
  echo "Your own ~/.dsh and any dsh on PATH are left alone:"
  if [[ -e "$HOME/.dsh" ]]; then
    echo "  $HOME/.dsh exists and is not used by this install."
  else
    echo "  no $HOME/.dsh on this Mac."
  fi
}

cmd_ensure() {
  if [[ ! -f "$REPO_ROOT/Package.swift" ]]; then
    warn "This does not look like a TinyTitan checkout; continuing anyway."
  fi
  say "Setting up TinyTitan's private DeepSeek Harness"
  echo "  Private root: $DSH_ROOT"
  echo "  Nothing outside it is touched; a dsh you already run is left alone."
  echo
  install_node
  install_dsh
  install_pnpm
  ensure_home
  install_plugin
  write_route
  local model="$DEFAULT_MODEL_ID"
  [[ -n "$model" ]] || model="$(first_served_model)"
  write_default_model "tinytitan" "$model"
  echo
  say "Done."
  echo "  Start it with:  $REPO_ROOT/tools/server_launcher.sh --web"
  echo "  Or from the launcher the installer wrote:  ~/.local/bin/tinytitan-web"
}

cmd_web() {
  [[ -x "$(dsh_bin)" ]] || die "DeepSeek Harness is not installed. Run: tools/dsh_local.sh ensure"
  [[ -d "$DSH_HOME_DIR/profiles/web" ]] || die "the private DSH home is not initialised. Run: tools/dsh_local.sh ensure"
  local port; port="$(resolve_port "$DSH_PORT")"
  local open=()
  (( DSH_OPEN )) || open=(--no-open)
  # DSH opens the default browser itself and prints the tokenised URL.
  exec env DSH_HOME="$DSH_HOME_DIR" \
           PATH="$(tool_path)" \
           "$(dsh_bin)" web --port "$port" "${open[@]}" "$@"
}

# What `web` would bind, without starting anything. Prints only the number on
# stdout, so a caller can capture it.
cmd_port() { resolve_port "$DSH_PORT"; }

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; }

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) SERVER_PORT="${2:?--port needs a number}"; shift 2 ;;
    --dsh-port) DSH_PORT="${2:?--dsh-port needs a number}"; shift 2 ;;
    --model) DEFAULT_MODEL_ID="${2:?--model needs a served id}"; shift 2 ;;
    --no-open) DSH_OPEN=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$COMMAND" in
  ensure) cmd_ensure ;;
  web)    cmd_web ;;
  port)   cmd_port ;;
  status) cmd_status ;;
  paths)  cmd_paths ;;
  ""|--help|-h) usage ;;
  *) die "unknown command: $COMMAND (try --help)" ;;
esac
