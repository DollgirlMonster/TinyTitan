#!/usr/bin/env bash
# Install TinyTitan for someone who has never used a terminal.
#
# Two ways to run it:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Pummelchen/TinyTitan/main/tools/install_tinytitan.sh)"
#   bash tools/install_tinytitan.sh                 # from a clone or an unzipped download
#
# Use those forms rather than `curl ... | bash`. A pipe makes this script's stdin
# the pipe, so it cannot ask anything and silently takes the default at every
# step — including "no model" and "no browser window". `bash -c "$(curl ...)"`
# downloads the script first and runs it with the terminal still on stdin, so the
# questions work. `bash tools/install_tinytitan.sh` never needs `chmod +x`
# either, which matters because a zip that lost the executable bit still runs.
#
# Nothing here needs Homebrew. Python is not needed to build the engine; only the
# model *converters* use it, and the installer says so if this Mac has none.
#
# It checks the Mac, gets the source, builds the server, optionally downloads a
# model, and installs a `tinytitan` command that starts it. The aim is a working
# **TinyTitan server**: at the end it offers to start one and stays in the
# foreground as it runs, so you finish with a base URL a client can be pointed at.
#
# It can also set up a **chat window**: TinyTitan's own DeepSeek Harness, a local
# page with a prompt box that opens in the default browser, already pointed at
# the server. That is offered once a model is installed, because a window with
# nothing to load is not a working thing. It lives under ~/.tinytitan and is kept
# entirely separate from any DeepSeek Harness you run yourself; see
# tools/dsh_local.sh.
#
# Nothing here is destructive. It never deletes a model, never removes a
# directory, and never touches anything outside its own folders:
#   ~/TinyTitan                 the checkout (a clone started by this script)
#   ~/.local/bin/tinytitan      the command that starts the server
#   ~/.local/bin/tinytitan-web  the command that starts it with the browser window
#   ~/.tinytitan                the private DeepSeek Harness, only with --web
# Re-running it is safe: it updates an existing checkout instead of cloning
# a second time.
#
# Flags:
#   --yes, -y        answer yes to every question (unattended install)
#   --model NAME     install this model without asking. Omit it and, with a
#                    terminal, the installer shows the model list to choose from
#                    (`tools/install_models.sh --choose`); through a pipe it
#                    takes ornith15-8bit rather than hanging on a question.
#   --no-model       build only; download no model
#   --web            also set up the browser chat window (asked interactively;
#                    --yes alone does not install it, so an unattended run stays
#                    a server and nothing else)
#   --no-web         do not offer the browser chat window
#   --dir PATH       where to clone when there is no checkout (default ~/TinyTitan)
#   --help, -h       this text
set -euo pipefail

REPO_URL="https://github.com/Pummelchen/TinyTitan.git"
REPO_URL_RAW="https://raw.githubusercontent.com/Pummelchen/TinyTitan/main"
DEFAULT_MODEL="ornith15-8bit"
DEFAULT_DIR="$HOME/TinyTitan"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Ask a yes/no question. With --yes, or when nothing can answer, take the
# fallback rather than hanging a piped install.
ASSUME_YES=0
ask() {
  local prompt="$1" fallback="${2:-no}" reply
  if (( ASSUME_YES )); then
    [[ "$fallback" == "yes" ]]
    return
  fi
  if [[ ! -t 0 ]]; then
    [[ "$fallback" == "yes" ]]
    return
  fi
  printf '%s [%s] ' "$prompt" "$([[ "$fallback" == yes ]] && echo 'Y/n' || echo 'y/N')"
  read -r reply || reply=""
  reply="${reply:-$fallback}"
  [[ "$reply" =~ ^[Yy] ]]
}

# --- flags -----------------------------------------------------------------
MODEL="$DEFAULT_MODEL"
# Set by --model. It decides whether the model step shows the menu (nothing was
# named, so ask) or installs the one that was named (do not second-guess it).
MODEL_WAS_SET=0
INSTALL_MODEL=1
TARGET_DIR="$DEFAULT_DIR"
# ask | yes | no. `--yes` deliberately does not imply `yes` here: pulling ~320 MB
# of Node/DeepSeek Harness into someone's home on an unattended run is a side
# effect that has to be asked for by name, with --web.
WEB_MODE="ask"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)    ASSUME_YES=1 ;;
    --model)     MODEL="${2:?--model needs a name}"; MODEL_WAS_SET=1; shift ;;
    --no-model)  INSTALL_MODEL=0 ;;
    --web)       WEB_MODE="yes" ;;
    --no-web)    WEB_MODE="no" ;;
    --dir)       TARGET_DIR="${2:?--dir needs a path}"; shift ;;
    --help|-h)   sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *)           die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

say "TinyTitan installer"
echo "  This takes a while and mostly waits. You can stop it with Ctrl-C at any"
echo "  point; run it again later and it continues where it can."
echo

# A pipe takes the default at every question, and a person who expected to choose
# would otherwise never learn why nothing asked them. Say what is about to happen
# and how to get the questions, before the 37 GB download rather than after it.
if [[ ! -t 0 ]] && (( ASSUME_YES == 0 )); then
  warn "This is running from a pipe, so it cannot ask you anything."
  warn "It will take the default at every step — including downloading $MODEL"
  warn "and setting up the browser window."
  echo "     To choose instead, run:"
  echo "       bash -c \"\$(curl -fsSL $REPO_URL_RAW/tools/install_tinytitan.sh)\""
  echo "     Flags still work through a pipe:"
  echo "       curl -fsSL $REPO_URL_RAW/tools/install_tinytitan.sh | bash -s -- --no-model"
  echo
fi

# --- 1) the machine ---------------------------------------------------------
say "1/6  Checking this Mac"

os_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
os_major="${os_version%%.*}"
arch="$(uname -m)"
if [[ "$arch" != "arm64" ]]; then
  die "TinyTitan needs Apple Silicon (M1 or newer). This Mac reports $arch."
fi
ok "Apple Silicon ($arch), macOS $os_version"
if [[ "${os_major:-0}" -lt 26 ]]; then
  warn "TinyTitan targets macOS 26 or later; this is $os_version."
  warn "The build may fail. If it does, updating macOS fixes it."
fi

free_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
free_gb=$(( free_kb / 1048576 ))
if [[ "$free_gb" -lt 45 ]]; then
  warn "Only about ${free_gb} GB free on this volume."
  warn "The build needs a few GB, and a 35B 4-bit model about 20 GB."
  ask "Continue anyway?" no || die "Stopped at your request. Free up space and re-run."
else
  ok "About ${free_gb} GB free"
fi

if [[ "$(pgrep -fl 'TinyTitanServer|TinyTitanCLI' 2>/dev/null | wc -l | tr -d ' ')" != "0" ]]; then
  warn "A TinyTitan process is already running. Stop it before starting a server,"
  warn "since one model runs at a time on this Mac."
fi

# --- 2) the source ----------------------------------------------------------
say "2/6  Getting the source"

# Are we inside a checkout? Walk up from both this script and the directory
# the user is standing in, so `cd ~/TinyTitan && tools/install_tinytitan.sh` and
# `bash tools/install_tinytitan.sh` both work.
find_checkout() {
  local start="$1" probe
  probe="$start"
  while [[ -n "$probe" && "$probe" != "/" ]]; do
    if [[ -f "$probe/Package.swift" ]]; then printf '%s' "$probe"; return 0; fi
    probe="$(dirname "$probe")"
  done
  return 1
}

REPO_ROOT=""
if ! REPO_ROOT="$(find_checkout "$(cd "$(dirname "$0")" && pwd)")"; then
  REPO_ROOT="$(find_checkout "$PWD" || true)"
fi

if [[ -n "$REPO_ROOT" ]]; then
  ok "Using the checkout at $REPO_ROOT"
else
  command -v git >/dev/null 2>&1 \
    || die "git is missing. Install Xcode (App Store), open it once, then re-run."
  if [[ -d "$TARGET_DIR/.git" ]]; then
    ok "Updating the existing checkout at $TARGET_DIR"
    git -C "$TARGET_DIR" pull --ff-only || warn "Could not update; using what is there."
    REPO_ROOT="$TARGET_DIR"
  else
    [[ -e "$TARGET_DIR" ]] && die "$TARGET_DIR already exists and is not a checkout. Move it or use --dir."
    echo "  Downloading TinyTitan into $TARGET_DIR ..."
    git clone --depth 1 "$REPO_URL" "$TARGET_DIR" || die "Could not download TinyTitan. Check your connection."
    REPO_ROOT="$TARGET_DIR"
  fi
  ok "Source ready"
fi
cd "$REPO_ROOT"

# --- 3) the toolchain -------------------------------------------------------
say "3/6  Checking the Swift toolchain"

if ! command -v swift >/dev/null 2>&1; then
  warn "Swift is not installed yet."
  echo "  Pressing Enter opens the installer for Apple's command-line tools."
  if ask "Install them now?" yes; then
    xcode-select --install 2>/dev/null || true
    echo
    echo "  A dialog should appear. Accept it, wait for it to finish (it can take"
    echo "  several minutes), then run this installer again."
  fi
  exit 1
fi

swift_line="$(swift --version 2>&1 | head -1)"
swift_ver="$(printf '%s' "$swift_line" | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
if [[ -z "$swift_ver" ]]; then
  warn "Could not read a Swift version from: $swift_line"
  ask "Try the build anyway?" yes || exit 1
elif (( $(printf '%s' "$swift_ver" | cut -d. -f1) < 6 )) \
  || { [[ "$(printf '%s' "$swift_ver" | cut -d. -f1)" == "6" ]] \
       && (( $(printf '%s' "$swift_ver" | cut -d. -f2) < 4 )); }; then
  die "TinyTitan needs Swift 6.4 or later; this Mac has $swift_ver.
     Update Xcode from the App Store (or set it with xcode-select), then re-run."
else
  ok "Swift $swift_ver"
fi

# --- 4) build ---------------------------------------------------------------
say "4/6  Building (this is the slow part)"

if ! swift build -c release; then
  die "The build failed. The last few lines explain why.
     Copy the whole message to https://github.com/Pummelchen/TinyTitan/issues and someone will help."
fi
ok "Build complete"

# --- 5) a model -------------------------------------------------------------
say "5/6  Model"

installed_any() {
  local d
  for d in "$REPO_ROOT"/models/*/manifest.json; do
    [[ -f "$d" ]] && return 0
  done
  return 1
}

if (( ! INSTALL_MODEL )); then
  ok "Skipped (--no-model)"
elif installed_any; then
  ok "A model is already installed under models/"
  echo "     Install another any time:  tools/install_models.sh --choose"
else
  # The model is the only real choice in this install, so it gets a list rather
  # than a yes/no on one default: what each model is, how much disk it takes, and
  # the verified default on the first line for someone who just presses Enter.
  # It lives in `install_models.sh --choose` so the list, the labels and the
  # sizes come from the one catalogue.
  if (( MODEL_WAS_SET )) || [[ ! -t 0 ]]; then
    echo "  No model is installed yet. TinyTitan needs one to run."
    if [[ "$MODEL" == "$DEFAULT_MODEL" ]]; then
      echo "  The recommended starting model is Ornith 1.5 35B-A3B at 8-bit,"
      echo "  about 37 GB installed. The 4-bit version is about 20 GB and faster"
      echo "  to download if that is a lot:  tools/install_models.sh ornith15"
    else
      echo "  This run was asked for '$MODEL'."
    fi
    if ask "Download $MODEL now?" yes; then
      if ! tools/install_models.sh "$MODEL"; then
        warn "The model download did not finish."
        echo "     Re-run this installer to continue, or start it directly:"
        echo "       tools/install_models.sh $MODEL"
      else
        ok "Model installed"
      fi
    else
      echo "  Fine — TinyTitan is built but will have nothing to load until you run:"
      echo "       tools/install_models.sh --choose"
    fi
  elif ! tools/install_models.sh --choose; then
    warn "No model was installed."
    echo "     Pick one whenever you like:  tools/install_models.sh --choose"
  else
    ok "Model installed"
  fi
fi

# --- 6) a server you can start ----------------------------------------------
say "6/6  Your server"

# A command for the terminal-minded: it starts the server from this checkout,
# and only ever stops a server that launcher started.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/tinytitan" <<RUNNER
#!/bin/sh
# Installed by tools/install_tinytitan.sh. Starts the TinyTitan server from its checkout.
exec "$REPO_ROOT/tools/server_launcher.sh" "\$@"
RUNNER
chmod +x "$HOME/.local/bin/tinytitan"
ok "Start it with: ~/.local/bin/tinytitan"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "     Add it to your PATH to use the 'tinytitan' command anywhere:"
     echo "       echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

if ! installed_any; then
  echo
  warn "No model is installed yet, so a server would have nothing to load."
  echo "     Install one, then start the server:"
  echo "       $REPO_ROOT/tools/install_models.sh $MODEL"
  echo "       ~/.local/bin/tinytitan"
fi

# The chat window. Offered only once a model is on disk: the whole point is a
# page that opens onto a model that is already there, and setting up 320 MB of
# runtime for an empty picker helps nobody.
WANT_WEB=0
if ! installed_any; then
  :
elif [[ "$WEB_MODE" == "no" ]]; then
  ok "Browser chat window: skipped (--no-web)"
elif [[ "$WEB_MODE" == "yes" ]] \
  || { (( ASSUME_YES == 0 )) && [[ -t 0 ]] \
       && ask "Also set up a chat window in your browser?" yes; }; then
  echo
  if "$REPO_ROOT/tools/dsh_local.sh" ensure; then
    WANT_WEB=1
    cat > "$HOME/.local/bin/tinytitan-web" <<WEBRUNNER
#!/bin/sh
# Installed by tools/install_tinytitan.sh. Starts the server and opens
# TinyTitan's own DeepSeek Harness in the browser.
exec "$REPO_ROOT/tools/server_launcher.sh" --web "\$@"
WEBRUNNER
    chmod +x "$HOME/.local/bin/tinytitan-web"
    ok "Chat window ready: ~/.local/bin/tinytitan-web"
  else
    warn "The chat window could not be set up; it does not affect the server."
    warn "Retry any time with: $REPO_ROOT/tools/dsh_local.sh ensure"
  fi
fi

# --- done -------------------------------------------------------------------
echo
# Hand over to the launcher whenever a person is there to watch: the launcher
# prints the base URL and the client settings, and the health check it does
# first is the proof that what was just built actually serves. An unattended
# install prints the command instead, so a pipe never blocks on a server.
if installed_any && (( ASSUME_YES == 0 )) && [[ -t 0 && -t 1 ]]; then
  if ask "Start the TinyTitan server now?" yes; then
    if (( WANT_WEB )); then
      say "Starting the model and opening the chat window in your browser."
    else
      say "Starting the server. Leave this window open; Ctrl-C stops it."
    fi
    echo
    if (( WANT_WEB )); then
      exec "$REPO_ROOT/tools/server_launcher.sh" --web
    fi
    exec "$REPO_ROOT/tools/server_launcher.sh" --client server
  fi
fi

say "Done."
echo
if (( WANT_WEB )); then
  echo "  Start TinyTitan with the browser chat window:"
  echo "    ~/.local/bin/tinytitan-web"
  echo "    (or: $REPO_ROOT/tools/server_launcher.sh --web)"
  echo
  echo "  A page opens in your browser with a prompt box, already pointed at"
  echo "  the model. Keep the window open while you use it; Ctrl-C stops both."
  echo "  The server alone is still:  ~/.local/bin/tinytitan"
else
  echo "  Start the TinyTitan server:"
  echo "    ~/.local/bin/tinytitan"
  echo "    (or: $REPO_ROOT/tools/server_launcher.sh)"
  echo
  echo "  It prints the base URL to point a client at - by default"
  echo "  http://127.0.0.1:8080/v1 with any API key; --port changes the port."
  echo "  Keep the window open while you use it; one model runs at a time."
  echo
  echo "  For a chat window in the browser instead, re-run this installer with"
  echo "  --web, or run: $REPO_ROOT/tools/dsh_local.sh ensure"
fi
echo
echo "  New to this? Start here:"
echo "    https://github.com/Pummelchen/TinyTitan/wiki/Getting-Started"
echo "  Questions and bug reports: https://github.com/Pummelchen/TinyTitan/issues"
