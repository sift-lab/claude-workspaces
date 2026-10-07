#!/bin/bash
# Builds workspacesd and workspaces-hook on Linux, puts them in ~/.local/bin and runs the daemon as a
# systemd user service that survives logout (linger). Run it again to update; the sessions stay in
# tmux while the daemon restarts, and the new one adopts them.
set -euo pipefail
cd "$(dirname "$0")/.."

# Linked against the toolchain's shared libraries (Swift 6.4 fails to link Foundation statically).
swift build -c release -j "${WORKSPACES_BUILD_JOBS:-4}"
BIN="$(swift build -c release --show-bin-path)"
mkdir -p ~/.local/bin
for tool in workspacesd workspaces-hook; do
  # A running copy (the MCP bridge of each session) keeps the old file open: replace, never overwrite.
  install -m 755 "$BIN/$tool" ~/.local/bin/"$tool.new"
  mv -f ~/.local/bin/"$tool.new" ~/.local/bin/"$tool"
done

UNIT_DIR=~/.config/systemd/user
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/workspacesd.service" <<'UNIT'
[Unit]
Description=Workspaces no servidor (sessões do Claude Code em tmux)

[Service]
ExecStart=%h/.local/bin/workspacesd serve
# Claude Code lives in ~/.local/bin, out of systemd's PATH.
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=on-failure
RestartSec=5
# Only the daemon stops: tmux and the Claude sessions it started keep running.
KillMode=process

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable workspacesd.service >/dev/null
systemctl --user restart workspacesd.service
loginctl enable-linger "$USER"
systemctl --user --no-pager status workspacesd.service | head -5
echo "Pronto: ~/.local/bin/workspacesd (workspacesd status)"
