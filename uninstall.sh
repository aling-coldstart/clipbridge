#!/usr/bin/env bash
# ClipBridge uninstaller — run on the Mac. Removes the Mac agent and, when the
# Windows host is reachable, the Windows listener and scheduled task.
#
#   ./uninstall.sh [user@windows-host]
set -euo pipefail

LABEL="com.clipbridge.agent"
BIN="$HOME/.local/bin/clipbridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/clipbridge.log"
DATA="$HOME/.local/share/clipbridge"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }

HOST="${1:-}"
if [[ -z $HOST && -f $PLIST ]]; then
  HOST="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:CLIPBRIDGE_HOST' "$PLIST" 2>/dev/null || true)"
fi

info "Stopping the Mac agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$BIN" "$LOG"
rm -rf "$DATA"
rm -f "$HOME"/.ssh/clipbridge-*

if [[ -n $HOST ]]; then
  info "Removing the Windows listener on $HOST"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
      "powershell -NoProfile -ExecutionPolicy Bypass -File clipbridge\\uninstall-windows.ps1"; then
    warn "Could not reach $HOST. On Windows, run: powershell -File %USERPROFILE%\\clipbridge\\uninstall-windows.ps1"
  fi
else
  warn "Windows host unknown; on Windows run: powershell -File %USERPROFILE%\\clipbridge\\uninstall-windows.ps1"
fi
info "ClipBridge removed."
