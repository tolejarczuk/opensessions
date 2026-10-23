#!/usr/bin/env bash
# opensessions.tmux — TPM entry point
# Registers keybindings and bootstraps the TUI if needed.
#
# Install:
#   1. Add to .tmux.conf:  set -g @plugin 'Ataraxy-Labs/opensessions'
#   2. Press prefix + I to install
#   3. Prebuilt release binaries are downloaded automatically on first load
#
# Default keybindings:
#   prefix + o → s   — reveal and focus sidebar
#   prefix + o → t   — toggle sidebar
#   prefix + o → e   — spread non-sidebar panes even-horizontal in current window
#   prefix + o → 1-9 — switch to visible session by index
#
# Options (set before TPM init):
#   @opensessions-prefix-key        "o"  — prefix + key to enter opensessions command table
#   @opensessions-focus-global-key  ""   — optional no-prefix key to reveal and focus sidebar
#   @opensessions-index-keys        ""   — optional no-prefix keys mapped to visible sessions 1..9
#   @opensessions-width             deprecated — use config.json sidebarWidth or the in-sidebar width slider

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/integrations/tmux-plugin/scripts"
SCRIPT_DIR="$SCRIPTS_DIR"

# TPM installs from GitHub source, so fetch the matching release binaries instead
# of asking users to build Rust locally. Local/dev checkouts can set
# OPENSESSIONS_SKIP_BINARY_DOWNLOAD=1 and use target/{debug,release}.
PACKAGE_VERSION="$(grep -o '"version": *"[^"]*"' "$CURRENT_DIR/package.json" 2>/dev/null | head -1 | cut -d'"' -f4)"
BIN_VERSION="$(cat "$CURRENT_DIR/bin/.opensessions-version" 2>/dev/null || true)"
if [ ! -x "$CURRENT_DIR/bin/opensessions-sidebar" ] || [ ! -x "$CURRENT_DIR/bin/opensessions-server" ] || [ ! -x "$CURRENT_DIR/bin/lazydiff" ] || [ "$BIN_VERSION" != "$PACKAGE_VERSION" ]; then
  sh "$SCRIPTS_DIR/install-binaries.sh" "$CURRENT_DIR" >/tmp/opensessions-install.log 2>&1 || true
fi

. "$SCRIPTS_DIR/server-common.sh"

# --- Read user options with defaults ---

get_option() {
  local option="$1"
  local default="$2"
  local value
  value=$(tmux show-option -gqv "$option" 2>/dev/null)
  echo "${value:-$default}"
}

PREFIX_KEY=$(get_option "@opensessions-prefix-key" "o")
FOCUS_GLOBAL_KEY=$(get_option "@opensessions-focus-global-key" "")
INDEX_KEYS=$(get_option "@opensessions-index-keys" "")
NOTIFICATIONS=$(get_option "@opensessions-notifications" "on")
COMMAND_TABLE="opensessions"

bind_global_key() {
  local key="$1"
  local command="$2"
  [ -n "$key" ] || return
  tmux bind-key -n "$key" run-shell "$command"
}

bind_global_index_keys() {
  local index=1
  local key
  for key in $INDEX_KEYS; do
    [ "$index" -le 9 ] || break
    tmux bind-key -n "$key" run-shell "sh '$SCRIPTS_DIR/switch-index.sh' $index"
    index=$((index + 1))
  done
}

# Export so scripts can read them
tmux set-environment -g OPENSESSIONS_DIR "$CURRENT_DIR"
tmux set-environment -g OPENSESSIONS_NOTIFICATIONS "$NOTIFICATIONS"
tmux set-environment -gu OPENSESSIONS_WIDTH 2>/dev/null || true

# --- Bootstrap: kill stale server if version, install path, or binaries changed ---
VERSION_FILE="${PID_FILE%.pid}.version"

# Include the server binary's mtime so a rebuilt or re-downloaded binary
# restarts a stale server even when package.json did not change.
BIN_STAMP=""
if [ -x "$CURRENT_DIR/bin/opensessions-server" ]; then
  BIN_STAMP="$(stat -c %Y "$CURRENT_DIR/bin/opensessions-server" 2>/dev/null \
    || stat -f %m "$CURRENT_DIR/bin/opensessions-server" 2>/dev/null \
    || true)"
fi
CURRENT_VERSION="${CURRENT_DIR}:${PACKAGE_VERSION}:${BIN_STAMP}:${NOTIFICATIONS}"
RUNNING_VERSION=""
[ -f "$VERSION_FILE" ] && RUNNING_VERSION=$(cat "$VERSION_FILE" 2>/dev/null)

# Only kill the pid when it still belongs to an opensessions server; a stale
# pid file must never take down an unrelated process.
kill_stale_server() {
  [ -f "$PID_FILE" ] || return 0
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q 'opensessions-server'; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

if [ "$CURRENT_VERSION" != "$RUNNING_VERSION" ]; then
  kill_stale_server
  echo -n "$CURRENT_VERSION" > "$VERSION_FILE"
fi

# --- Bind tmux shortcuts ---

# Command table for manual use: prefix o → s/t/e/1-9
if [ -n "$PREFIX_KEY" ]; then
  tmux bind-key "$PREFIX_KEY" switch-client -T "$COMMAND_TABLE"
  tmux bind-key -T "$COMMAND_TABLE" Any switch-client -T root
  tmux bind-key -T "$COMMAND_TABLE" s run-shell "sh '$SCRIPTS_DIR/focus.sh'"
  tmux bind-key -T "$COMMAND_TABLE" t run-shell "sh '$SCRIPTS_DIR/toggle.sh'"
  tmux bind-key -T "$COMMAND_TABLE" e run-shell "sh '$SCRIPTS_DIR/even-horizontal.sh' '#{window_id}' '#{pane_id}'"
  for i in 1 2 3 4 5 6 7 8 9; do
    tmux bind-key -T "$COMMAND_TABLE" "$i" run-shell "sh '$SCRIPTS_DIR/switch-index.sh' $i"
  done
fi

# Direct prefix bindings for programmatic use (terminal emulator shortcuts).
# C-s/C-t are single-byte Ctrl codes; M-1..9 are 2-byte Alt sequences.
# Both are safe to send as text from terminal emulators without timing issues.
tmux bind-key C-s run-shell "sh '$SCRIPTS_DIR/focus.sh'"
tmux bind-key C-t run-shell "sh '$SCRIPTS_DIR/toggle.sh'"
for i in 1 2 3 4 5 6 7 8 9; do
  tmux bind-key "M-$i" run-shell "sh '$SCRIPTS_DIR/switch-index.sh' $i"
done

bind_global_key "$FOCUS_GLOBAL_KEY" "sh '$SCRIPTS_DIR/focus.sh'"
bind_global_index_keys
