#!/usr/bin/env bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

banner() { echo -e "\n${CYAN}${BOLD}=== $1 ===${RESET}\n"; }
ok()     { echo -e "${GREEN}✓${RESET} $1"; }
info()   { echo -e "${YELLOW}→${RESET} $1"; }
die()    { echo -e "${RED}✗ $1${RESET}" >&2; exit 1; }

CHOICE=0
prompt_choice() {
  local prompt="$1"; shift
  local options=("$@")
  echo -e "${BOLD}$prompt${RESET}"
  for i in "${!options[@]}"; do echo "  $((i+1)). ${options[$i]}"; done
  while true; do
    read -rp "Choice [1-${#options[@]}]: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )) && break
    echo "Invalid choice, try again."
  done
  CHOICE=$((choice - 1))
}

banner "SSH Clipboard Setup"
echo "This script configures copy-over-SSH using OSC 52 + tunnel fallback."

# --- Role ---
prompt_choice "Is this the LOCAL machine or REMOTE server?" "Local machine" "Remote server"
role_idx=$CHOICE

# --- OS ---
prompt_choice "What OS is this machine?" "macOS" "Ubuntu/Debian" "Arch Linux" "Windows 11 (WSL2)" "Windows 11 (native PowerShell)"
os_idx=$CHOICE
OS_NAMES=("macos" "ubuntu" "arch" "wsl2" "windows")
OS="${OS_NAMES[$os_idx]}"

# ─────────────────────────────────────────────
# REMOTE SETUP
# ─────────────────────────────────────────────
if [[ $role_idx -eq 1 ]]; then
  banner "Remote Server Setup"

  SHELL_RC="$HOME/.bashrc"
  if [[ "$SHELL" == */zsh ]]; then SHELL_RC="$HOME/.zshrc"; fi
  info "Writing copy() function to $SHELL_RC"

  cat >> "$SHELL_RC" << 'EOF'

copy() {
  local content
  content=$(cat "$@" 2>/dev/null || printf '%s' "$@")
  printf "\033]52;c;$(printf '%s' "$content" | base64 | tr -d '\n')\a"
  if command -v socat &>/dev/null && nc -z localhost 2224 2>/dev/null; then
    printf '%s' "$content" | socat - TCP:localhost:2224
  fi
  echo "✓ Copied" >&2
}
EOF

  # Install socat if missing
  if ! command -v socat &>/dev/null; then
    info "Installing socat (tunnel fallback)..."
    if command -v apt-get &>/dev/null; then
      sudo apt-get install -y -q socat
    elif command -v pacman &>/dev/null; then
      sudo pacman -S --noconfirm socat
    elif command -v brew &>/dev/null; then
      brew install socat
    else
      info "Could not auto-install socat. Install it manually if you need the tunnel fallback."
    fi
  fi

  ok "Remote setup done. Run: source $SHELL_RC"
  echo ""
  info "Usage: copy file.txt  OR  cat file.txt | copy"
  echo ""
  echo -e "${YELLOW}Now run this script on your LOCAL machine(s) to complete setup.${RESET}"
  exit 0
fi

# ─────────────────────────────────────────────
# LOCAL SETUP
# ─────────────────────────────────────────────
banner "Local Machine Setup ($OS)"

SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

add_ssh_config() {
  local block="$1"
  if grep -qF "$block" "$SSH_CONFIG" 2>/dev/null; then
    info "SSH config entry already present, skipping."
  else
    printf "\n%s\n" "$block" >> "$SSH_CONFIG"
    ok "Added to $SSH_CONFIG"
  fi
}

# ── macOS ──────────────────────────────────────
if [[ "$OS" == "macos" ]]; then
  add_ssh_config "Host *
    SetEnv TERM=xterm-256color"

  echo ""
  info "Terminal checklist:"
  echo "  • iTerm2/WezTerm: Preferences → Profiles → Terminal → enable 'Allow clipboard access'"
  echo "  • Terminal.app: OSC 52 not supported — use a different terminal or the tunnel fallback"
  echo ""

  read -rp "Set up tunnel fallback listener? (needed for Terminal.app) [y/N]: " want_tunnel
  if [[ "$want_tunnel" =~ ^[Yy]$ ]]; then
    if ! command -v socat &>/dev/null; then
      info "Installing socat via Homebrew..."
      brew install socat || die "Install Homebrew first: https://brew.sh"
    fi

    PLIST="$HOME/Library/LaunchAgents/com.user.ssh-clipboard.plist"
    cat > "$PLIST" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.user.ssh-clipboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-c</string>
    <string>while true; do socat TCP-LISTEN:2224,reuseaddr - | pbcopy; done</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST_EOF
    launchctl load "$PLIST" 2>/dev/null || true
    ok "Tunnel listener installed as LaunchAgent (auto-starts on login)"

    read -rp "Enter your SSH host alias to add RemoteForward (or press Enter to skip): " ssh_host
    if [[ -n "$ssh_host" ]]; then
      add_ssh_config "Host $ssh_host
    RemoteForward 2224 localhost:2224"
    fi
  fi

# ── Ubuntu/Debian ──────────────────────────────
elif [[ "$OS" == "ubuntu" ]]; then
  info "Installing dependencies..."
  sudo apt-get install -y -q socat xclip wl-clipboard 2>/dev/null || true

  SHELL_RC="$HOME/.bashrc"
  [[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"

  if ! grep -q "ssh-clipboard-listen" "$SHELL_RC"; then
    cat >> "$SHELL_RC" << 'EOF'

ssh-clipboard-listen() {
  pkill -f "socat TCP-LISTEN:2224" 2>/dev/null || true
  if command -v wl-copy &>/dev/null; then
    socat TCP-LISTEN:2224,fork,reuseaddr - | wl-copy &
  elif command -v xclip &>/dev/null; then
    socat TCP-LISTEN:2224,fork,reuseaddr - | xclip -selection clipboard &
  fi
}
ssh-clipboard-listen 2>/dev/null
EOF
    ok "Listener added to $SHELL_RC"
  else
    info "Listener already in $SHELL_RC"
  fi

  add_ssh_config "Host *
    SetEnv TERM=xterm-256color"

  read -rp "Enter your SSH host alias to add RemoteForward (or press Enter to skip): " ssh_host
  if [[ -n "$ssh_host" ]]; then
    add_ssh_config "Host $ssh_host
    RemoteForward 2224 localhost:2224"
  fi

# ── Arch ──────────────────────────────────────
elif [[ "$OS" == "arch" ]]; then
  info "Installing dependencies..."
  sudo pacman -S --noconfirm socat xclip wl-clipboard 2>/dev/null || true

  SHELL_RC="$HOME/.bashrc"
  [[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"

  if ! grep -q "ssh-clipboard-listen" "$SHELL_RC"; then
    cat >> "$SHELL_RC" << 'EOF'

ssh-clipboard-listen() {
  pkill -f "socat TCP-LISTEN:2224" 2>/dev/null || true
  if command -v wl-copy &>/dev/null; then
    socat TCP-LISTEN:2224,fork,reuseaddr - | wl-copy &
  elif command -v xclip &>/dev/null; then
    socat TCP-LISTEN:2224,fork,reuseaddr - | xclip -selection clipboard &
  fi
}
ssh-clipboard-listen 2>/dev/null
EOF
    ok "Listener added to $SHELL_RC"
  else
    info "Listener already in $SHELL_RC"
  fi

  add_ssh_config "Host *
    SetEnv TERM=xterm-256color"

  read -rp "Enter your SSH host alias to add RemoteForward (or press Enter to skip): " ssh_host
  if [[ -n "$ssh_host" ]]; then
    add_ssh_config "Host $ssh_host
    RemoteForward 2224 localhost:2224"
  fi

# ── WSL2 ──────────────────────────────────────
elif [[ "$OS" == "wsl2" ]]; then
  info "Installing socat..."
  sudo apt-get install -y -q socat 2>/dev/null || true

  SHELL_RC="$HOME/.bashrc"
  [[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"

  if ! grep -q "ssh-clipboard-listen" "$SHELL_RC"; then
    cat >> "$SHELL_RC" << 'EOF'

ssh-clipboard-listen() {
  pkill -f "socat TCP-LISTEN:2224" 2>/dev/null || true
  socat TCP-LISTEN:2224,fork,reuseaddr - | clip.exe &
}
ssh-clipboard-listen 2>/dev/null
EOF
    ok "Listener added to $SHELL_RC (uses clip.exe)"
  else
    info "Listener already in $SHELL_RC"
  fi

  add_ssh_config "Host *
    SetEnv TERM=xterm-256color"

  read -rp "Enter your SSH host alias to add RemoteForward (or press Enter to skip): " ssh_host
  if [[ -n "$ssh_host" ]]; then
    add_ssh_config "Host $ssh_host
    RemoteForward 2224 localhost:2224"
  fi

# ── Windows native ─────────────────────────────
elif [[ "$OS" == "windows" ]]; then
  echo ""
  echo -e "${YELLOW}Run this in PowerShell (as your user, not admin):${RESET}"
  echo ""
  cat << 'PS'
# Add to SSH config
$sshConfig = "$env:USERPROFILE\.ssh\config"
if (-not (Test-Path $sshConfig)) { New-Item -Force $sshConfig | Out-Null }
Add-Content $sshConfig "`nHost *`n    SetEnv TERM=xterm-256color"

# One-shot clipboard listener (run once per session, or add to $PROFILE for persistence)
$listener = {
  while ($true) {
    $srv = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 2224)
    $srv.Start()
    $conn = $srv.AcceptTcpClient()
    $data = (New-Object IO.StreamReader($conn.GetStream())).ReadToEnd()
    Set-Clipboard -Value $data
    $conn.Close(); $srv.Stop()
  }
}
Start-Job -ScriptBlock $listener | Out-Null
Write-Host "✓ Clipboard listener running"
PS
  echo ""
  info "Windows Terminal supports OSC 52 natively — the listener above is only needed for older terminals."
  exit 0
fi

# ─────────────────────────────────────────────
banner "All done!"
ok "OSC 52 is the primary method (works with Windows Terminal, iTerm2, WezTerm, kitty)"
ok "Tunnel fallback on port 2224 is active for terminals that don't support OSC 52"
echo ""
echo -e "Reload your shell: ${BOLD}source ~/${SHELL_RC##*/}${RESET}"