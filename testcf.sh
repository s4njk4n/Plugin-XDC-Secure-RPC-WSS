#!/bin/bash
# Interactive manager for Nginx IP whitelist (RPC + WSS)
# Plugin-XDC-Secure-RPC-WSS
# With Cloudflare IPv4 toggle support

set -euo pipefail

# ========== Colours & helpers ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

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

NGINX_CONF="/etc/nginx/sites-available/xdc-node"
CF_IPS_URL="https://www.cloudflare.com/ips-v4"

if [[ $EUID -ne 0 ]]; then
  error "This script must be run with sudo / as root."
  exit 1
fi

if [[ ! -f "$NGINX_CONF" ]]; then
  error "Nginx config not found: $NGINX_CONF"
  error "Have you run the main installer yet?"
  exit 1
fi

# Extract allow lines from a location block
extract_allows() {
  local location="$1"
  awk -v loc="$location" '
    $0 ~ "location = " loc " {" { inblock=1; next }
    inblock && /deny all;/ { inblock=0 }
    inblock && /allow / { print }
  ' "$NGINX_CONF"
}

reload_nginx() {
  if nginx -t &>/dev/null; then
    systemctl reload nginx
    success "Nginx reloaded."
  else
    error "Nginx config test failed. Changes not applied."
    nginx -t
  fi
}

view_all() {
  header "Current whitelist"
  echo -e "${BOLD}RPC (/xdcrpc):${NC}"
  extract_allows "/xdcrpc" || echo "  (none)"
  echo
  echo -e "${BOLD}WSS (/xdcwss):${NC}"
  extract_allows "/xdcwss" || echo "  (none)"
  echo
}

add_ip() {
  local target="$1"   # rpc, wss, or both
  local ip label

  read -rp "$(echo -e "${YELLOW}IP address to add: ${NC}")" ip
  [[ -z "$ip" ]] && { warn "Empty IP, cancelled."; return; }

  read -rp "$(echo -e "${YELLOW}Label / comment for this IP: ${NC}")" label
  label="${label:-Unlabelled}"

  # Exactly 8 spaces to match the installer
  local line="        allow ${ip};  # ${label}"

  if [[ "$target" == "rpc" || "$target" == "both" ]]; then
    sed -i "/location = \\/xdcrpc {/,/deny all;/ s/^[[:space:]]*deny all;/${line}\\n        deny all;/" "$NGINX_CONF"
  fi
  if [[ "$target" == "wss" || "$target" == "both" ]]; then
    sed -i "/location = \\/xdcwss {/,/deny all;/ s/^[[:space:]]*deny all;/${line}\\n        deny all;/" "$NGINX_CONF"
  fi

  success "Added $ip ($label) to ${target}"
  reload_nginx
}

remove_ip() {
  local target="$1"
  local tmpfile
  tmpfile=$(mktemp)

  extract_allows "/xdcrpc" > "$tmpfile.rpc" 2>/dev/null || true
  extract_allows "/xdcwss" > "$tmpfile.wss" 2>/dev/null || true

  echo
  echo -e "${BOLD}Select an entry to remove:${NC}"
  local i=1
  declare -a choices=()

  if [[ "$target" == "both" ]]; then
    # Only show IPs that exist in both lists
    while IFS= read -r rpc_line; do
      [[ -z "$rpc_line" ]] && continue
      # Extract just the IP for comparison
      local ip
      ip=$(echo "$rpc_line" | awk '{print $2}' | tr -d ';')
      if grep -q "allow ${ip};" "$tmpfile.wss"; then
        echo "  $i) BOTH $rpc_line"
        choices[$i]="both|$rpc_line"
        ((i++))
      fi
    done < "$tmpfile.rpc"
  else
    if [[ "$target" == "rpc" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "  $i) RPC  $line"
        choices[$i]="rpc|$line"
        ((i++))
      done < "$tmpfile.rpc"
    fi
    if [[ "$target" == "wss" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "  $i) WSS  $line"
        choices[$i]="wss|$line"
        ((i++))
      done < "$tmpfile.wss"
    fi
  fi

  if [[ $i -eq 1 ]]; then
    warn "No entries found to remove."
    rm -f "$tmpfile"*
    return
  fi

  read -rp "$(echo -e "${YELLOW}Enter number to remove (or 0 to cancel): ${NC}")" choice
  if [[ "$choice" == "0" || -z "${choices[$choice]:-}" ]]; then
    info "Cancelled."
    rm -f "$tmpfile"*
    return
  fi

  IFS='|' read -r loc line <<< "${choices[$choice]}"

  # Escape characters that are special to sed (including #)
  local escaped
  escaped=$(printf '%s\n' "$line" | sed 's/[\/&\#]/\\&/g')

  if [[ "$loc" == "rpc" || "$loc" == "both" ]]; then
    sed -i "/location = \\/xdcrpc {/,/deny all;/ { /${escaped}/d; }" "$NGINX_CONF"
  fi
  if [[ "$loc" == "wss" || "$loc" == "both" ]]; then
    sed -i "/location = \\/xdcwss {/,/deny all;/ { /${escaped}/d; }" "$NGINX_CONF"
  fi

  success "Removed: $line"
  reload_nginx
  rm -f "$tmpfile"*
}

# ========== Cloudflare helpers ==========
fetch_cloudflare_ips() {
  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required to fetch Cloudflare IP ranges."
    return 1
  fi

  info "Fetching latest Cloudflare IPv4 ranges..."
  local ips
  ips=$(curl -fsSL --max-time 20 "$CF_IPS_URL" 2>/dev/null || true)
  if [[ -z "$ips" ]]; then
    error "Failed to fetch Cloudflare IP list from $CF_IPS_URL"
    return 1
  fi

  local filtered
  filtered=$(echo "$ips" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -u || true)
  if [[ -z "$filtered" ]]; then
    error "No valid IPv4 CIDRs found in Cloudflare response."
    return 1
  fi

  # Only the CIDR list goes to stdout
  echo "$filtered"
  return 0
}

cloudflare_present() {
  extract_allows "/xdcrpc" | grep -q '# Cloudflare' && return 0
  extract_allows "/xdcwss" | grep -q '# Cloudflare' && return 0
  return 1
}

# Safer line insertion that avoids sed newline problems
insert_allow_line() {
  local location="$1"   # /xdcrpc or /xdcwss
  local line="$2"

  local tmp
  tmp=$(mktemp)

  awk -v loc="$location" -v newline="$line" '
    $0 ~ "location = " loc " {" { inblock=1 }
    inblock && /deny all;/ {
      print newline
      inblock=0
    }
    { print }
  ' "$NGINX_CONF" > "$tmp"

  mv "$tmp" "$NGINX_CONF"
}

toggle_cloudflare() {
  if cloudflare_present; then
    info "Cloudflare ranges are currently present — removing from both RPC and WSS..."
    sed -i "/location = \\/xdcrpc {/,/deny all;/ { /# Cloudflare/d; }" "$NGINX_CONF" || true
    sed -i "/location = \\/xdcwss {/,/deny all;/ { /# Cloudflare/d; }" "$NGINX_CONF" || true
    success "Removed all Cloudflare IPv4 ranges from RPC and WSS."
  else
    local ips
    if ! ips=$(fetch_cloudflare_ips); then
      error "Could not obtain Cloudflare IP list. Aborting."
      return 1
    fi

    local count=0
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      ((count++)) || true

      local line="        allow ${ip};  # Cloudflare"

      # Add to RPC if not already present
      if ! extract_allows "/xdcrpc" | grep -qF "allow ${ip};"; then
        insert_allow_line "/xdcrpc" "$line"
      fi

      # Add to WSS if not already present
      if ! extract_allows "/xdcwss" | grep -qF "allow ${ip};"; then
        insert_allow_line "/xdcwss" "$line"
      fi
    done <<< "$ips"

    success "Added Cloudflare IPv4 ranges to both RPC and WSS ($count ranges)."
  fi

  reload_nginx || true
}

# ========== Menu ==========
while true; do
  clear

  echo -e "${BOLD}${CYAN}"
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║         XDCoutpost.xyz – for Plugin RPCaaS Operators         ║
║         Nginx Whitelist Manager                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"

  echo "  1) View current whitelist"
  echo "  2) Add IP to RPC only"
  echo "  3) Add IP to WSS only"
  echo "  4) Add IP to both RPC and WSS"
  echo "  5) Remove IP from RPC"
  echo "  6) Remove IP from WSS"
  echo "  7) Remove IP from both"
  echo
  echo -e "${BOLD}${CYAN}  Cloudflare:${NC}"
  if cloudflare_present; then
    echo "  8) Toggle Cloudflare IPv4 ranges  [currently: ON]"
  else
    echo "  8) Toggle Cloudflare IPv4 ranges  [currently: OFF]"
  fi
  echo
  echo "  0) Exit"
  echo
  read -rp "$(echo -e "${YELLOW}Choose an option [0-8]: ${NC}")" opt

  case "$opt" in
    1) view_all ; read -rp "Press Enter to continue..." ;;
    2) add_ip rpc ;;
    3) add_ip wss ;;
    4) add_ip both ;;
    5) remove_ip rpc ;;
    6) remove_ip wss ;;
    7) remove_ip both ;;
    8) toggle_cloudflare || warn "Toggle finished with errors (see messages above)." ;;
    0) success "Goodbye."; exit 0 ;;
    *) warn "Invalid option." ;;
  esac

  if [[ "$opt" != "1" && "$opt" != "0" ]]; then
    echo
    read -rp "Press Enter to continue..."
  fi
done
