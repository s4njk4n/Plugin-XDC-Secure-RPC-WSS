#!/bin/bash
# Optional companion script: create a non-root sudo user
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
║         Plugin-XDC-Secure-RPC-WSS                            ║
║         Create Non-Root Sudo User (Optional)                 ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

header "New user details"

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
info "Next steps once you are logged in as $USERNAME:"
echo "  sudo ./install_xdc_rpc_wss.sh"
echo

if yesno "Switch to the new user now (opens a shell in the repo directory)?" "y"; then
  info "Switching to user '$USERNAME' and entering the repository..."
  info "Type 'exit' later if you want to return to root."
  # Start a login shell for the new user already inside the repo
  exec su - "$USERNAME" -c "cd '$TARGET_DIR' && exec bash -l"
else
  success "Done."
  echo "You can switch later with:"
  echo "  su - $USERNAME"
  echo "  cd ~/$REPO_NAME"
fi
