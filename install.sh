#!/usr/bin/env bash
# ClipBridge installer — run on the Mac. Sets up both machines over SSH.
#
#   ./install.sh user@windows-host
#   bash <(curl -fsSL https://raw.githubusercontent.com/encorechow/clipbridge/main/install.sh) user@windows-host
#
# Requirements: macOS with Xcode Command Line Tools; Windows 10 1803+/11 with the
# OpenSSH Server feature enabled and the target user logged in at the desktop.
set -euo pipefail

REPO="encorechow/clipbridge"
BRANCH="${CLIPBRIDGE_BRANCH:-main}"
LABEL="com.clipbridge.agent"
BIN="$HOME/.local/bin/clipbridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/clipbridge.log"
REMOTE_DIR="clipbridge"
SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [user@windows-host]

Installs ClipBridge: two-way clipboard sync (text, images, files) between this
Mac and a Windows PC over SSH. Run it again any time to upgrade or change host.
Uninstall with uninstall.sh.
EOF
}

# Encode a PowerShell script for `powershell -EncodedCommand` (UTF-16LE, base64).
ps_encode() { iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'; }

# Silence progress records, which otherwise come back over SSH as CLIXML noise.
ps_prelude() { printf '%s\n' "\$ProgressPreference = 'SilentlyContinue'"; cat; }

remote_ps() { # remote_ps <ssh-extra-opts...> -- <script on stdin>
  local opts=()
  while [[ $# -gt 0 && $1 != -- ]]; do opts+=("$1"); shift; done
  local encoded; encoded="$(ps_prelude | ps_encode)"
  # shellcheck disable=SC2029  # expanding locally is intended: the script is base64-encoded
  ssh "${SSH_OPTS[@]}" ${opts[@]+"${opts[@]}"} "$HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $encoded"
}

ssh_works() {
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$HOST" "echo clipbridge-ok" 2>/dev/null | grep -q clipbridge-ok
}

read_host() {
  HOST="${1:-}"
  if [[ -z $HOST ]]; then
    read -rp "Windows SSH target (user@host or ~/.ssh/config alias): " HOST </dev/tty
  fi
  [[ $HOST =~ ^[A-Za-z0-9._@%+\\-]+$ ]] || die "Invalid SSH target '$HOST'"
}

check_mac() {
  [[ $(uname -s) == Darwin ]] || die "Run this installer on the Mac."
  for tool in ssh tar iconv base64 launchctl; do
    command -v "$tool" >/dev/null || die "Missing '$tool'."
  done
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    warn "Swift compiler not found; opening the Command Line Tools installer."
    xcode-select --install 2>/dev/null || true
    die "Finish installing Command Line Tools, then run this installer again."
  fi
}

# Locate the source tree: next to this script, or download the repository tarball.
find_sources() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n $here && -d $here/mac/Sources && -d $here/windows ]]; then
    SRC="$here"
    return
  fi
  SRC="$(mktemp -d)/clipbridge"
  info "Downloading $REPO ($BRANCH)"
  mkdir -p "$SRC"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$SRC" --strip-components 1 \
    || die "Download failed."
}

pick_public_key() {
  local candidate
  for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f $candidate ]]; then PUBKEY="$candidate"; return; fi
  done
  info "No SSH key found; creating ~/.ssh/id_ed25519 (no passphrase, so the background agent can use it)"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -q -C "clipbridge@$(hostname -s)"
  PUBKEY="$HOME/.ssh/id_ed25519.pub"
}

# Install our public key on Windows. Admin accounts must use administrators_authorized_keys.
setup_key() {
  pick_public_key
  local key; key="$(tr -d '\r\n' <"$PUBKEY")"
  [[ $key != *"'"* ]] || die "Unexpected quote in $PUBKEY"
  info "Installing $PUBKEY on Windows — enter the Windows password when asked."
  remote_ps -o PreferredAuthentications=keyboard-interactive,password -- <<EOF
\$ErrorActionPreference = 'Stop'
\$key = '$key'
\$isAdmin = [bool]((whoami /groups) -match 'S-1-5-32-544')
if (\$isAdmin) {
    \$file = Join-Path \$env:ProgramData 'ssh\administrators_authorized_keys'
} else {
    \$dir = Join-Path \$env:USERPROFILE '.ssh'
    New-Item -ItemType Directory -Force -Path \$dir | Out-Null
    \$file = Join-Path \$dir 'authorized_keys'
}
if (-not (Test-Path -LiteralPath \$file) -or -not (Select-String -LiteralPath \$file -SimpleMatch \$key -Quiet)) {
    Add-Content -LiteralPath \$file -Value \$key -Encoding ascii
}
if (\$isAdmin) { icacls \$file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null }
"key installed in \$file"
EOF
}

ensure_ssh() {
  info "Checking SSH access to $HOST"
  if ssh_works; then return; fi
  setup_key
  ssh_works || die "Key login to $HOST still fails. See README > Troubleshooting."
}

check_windows() {
  info "Checking Windows prerequisites"
  remote_ps -o BatchMode=yes -- <<'EOF' || die "Windows prerequisites missing (see above)."
$ok = $true
if ($PSVersionTable.PSVersion.Major -lt 5) { 'Windows PowerShell 5+ is required'; $ok = $false }
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { 'tar.exe missing (needs Windows 10 1803 or newer)'; $ok = $false }
if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { 'ScheduledTasks module missing'; $ok = $false }
if (-not $ok) { exit 1 }
EOF
}

build_mac() {
  info "Building the Mac agent"
  mkdir -p "$(dirname "$BIN")"
  xcrun swiftc -O -o "$BIN.new" "$SRC"/mac/Sources/*.swift || die "Build failed."
  mv -f "$BIN.new" "$BIN"
}

deploy_windows() {
  info "Installing the Windows listener"
  COPYFILE_DISABLE=1 tar -c -f - -C "$SRC/windows" . \
    | ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$HOST" "(if not exist $REMOTE_DIR mkdir $REMOTE_DIR) && tar -xf - -C $REMOTE_DIR" \
    || die "Copying scripts to Windows failed."
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$HOST" \
    "powershell -NoProfile -ExecutionPolicy Bypass -File $REMOTE_DIR\\install-windows.ps1" \
    || die "Registering the Windows scheduled task failed."
}

install_agent() {
  info "Installing the launchd agent ($LABEL)"
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>CLIPBRIDGE_HOST</key><string>$HOST</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || die "Generated plist is invalid."
  LOG_LINES_BEFORE=0
  if [[ -f $LOG ]]; then LOG_LINES_BEFORE=$(wc -l <"$LOG" | tr -d ' '); fi
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || die "launchctl bootstrap failed."
}

wait_connected() {
  for _ in $(seq 1 30); do
    if tail -n +"$((LOG_LINES_BEFORE + 1))" "$LOG" 2>/dev/null | grep -q "connected to"; then
      info "Connected. Copy on one machine, paste on the other."
      return
    fi
    sleep 0.5
  done
  warn "Agent started but has not connected yet; check $LOG"
}

main() {
  case "${1:-}" in -h|--help) usage; exit 0 ;; esac
  check_mac
  read_host "${1:-}"
  find_sources
  ensure_ssh
  check_windows
  build_mac
  deploy_windows
  install_agent
  wait_connected
  cat <<EOF

  Mac log:      $LOG
  Windows log:  %USERPROFILE%\\$REMOTE_DIR\\listener.log
  Uninstall:    uninstall.sh   (or: bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/uninstall.sh))
EOF
}

main "$@"
