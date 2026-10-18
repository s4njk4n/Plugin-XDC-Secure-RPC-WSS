#!/bin/bash
# Companion script: create a non-root sudo user
# and move the Plugin-XDC-Secure-RPC-WSS repo into their home

set -euo pipefail

# ========== Colours & helpers (matching main installer) ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${YELLOW}${prompt_text} [${default}]: ${NC}")" value
    value="${value:-$default}"
  else
    while true; do
      read -rp "$(echo -e "${YELLOW}${prompt_text}: ${NC}")" value
      [[ -n "$value" ]] && break
      warn "This field cannot be empty."
    done
  fi
  printf -v "$var_name" '%s' "$value"
}

yesno() {
  local prompt_text="$1"
  local default="${2:-n}"
  local answer
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  while true; do
    read -rp "$(echo -e "${YELLOW}${prompt_text} ${hint}: ${NC}")" answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# ========== Main ==========
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root."
  exit 1
fi

clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║         XDCoutpost.xyz – for Plugin RPCaaS Operators         ║
║         Create Non-Root Sudo User                            ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

prompt USERNAME "Username for the new account"
prompt PASSWORD "Password for the new account"

if id "$USERNAME" &>/dev/null; then
  error "User '$USERNAME' already exists."
  exit 1
fi

header "Creating user"
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo "$USERNAME"
success "User '$USERNAME' created and added to sudo group."

# ========== Move the repo ==========
# Detect the directory this script lives in (the repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$SCRIPT_DIR")"
NEW_HOME="/home/$USERNAME"
TARGET_DIR="$NEW_HOME/$REPO_NAME"

header "Moving repository"
info "Current repo location: $SCRIPT_DIR"

if [[ -d "$TARGET_DIR" ]]; then
  warn "Target directory already exists: $TARGET_DIR"
  if ! yesno "Overwrite it?" "n"; then
    error "Aborted. Please remove or rename the existing directory first."
    exit 1
  fi
  rm -rf "$TARGET_DIR"
fi

mv "$SCRIPT_DIR" "$TARGET_DIR"
chown -R "$USERNAME:$USERNAME" "$TARGET_DIR"
success "Repository moved to $TARGET_DIR and ownership set to $USERNAME."

echo
header "Next steps"

info "First, log out of this root session:"
echo -e "   ${GREEN}exit${NC}"
echo

# Try to detect a public IP for the SSH command (best effort)
PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || \
            curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || \
            curl -4 -s --max-time 5 ipinfo.io/ip 2>/dev/null || \
            echo "<your-server-ip>")

echo -e "${BOLD}Then SSH in as the new user (copy & paste):${NC}"
echo -e "   ${GREEN}ssh ${USERNAME}@${PUBLIC_IP}${NC}"
echo

echo -e "${BOLD}Once logged in, run this single command:${NC}"
echo -e "   ${GREEN}cd ~/${REPO_NAME} && screen -L -S xdc-install sudo ./install_xdc_rpc_wss.sh; status=\$?; echo; echo '=== Screen log ==='; cat screenlog.0 2>/dev/null || true; if [[ \$status -ne 0 ]]; then echo; echo '=== Summary / error note ==='; cat xdc-install-summary.txt 2>/dev/null || true; fi${NC}"
echo
echo -e "${CYAN}After the screen session ends you can view:${NC}"
echo -e "   Summary:     ${GREEN}cat xdc-install-summary.txt${NC}"
echo -e "   Full log:    ${GREEN}cat screenlog.0${NC}"
echo -e "${CYAN}Detach from screen early with Ctrl+A then D. Reattach with: screen -r xdc-install${NC}"
echo
echo
echo -e "${CYAN}The repository has already been moved to:${NC} /home/${USERNAME}/${REPO_NAME}"
echo
