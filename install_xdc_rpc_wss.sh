#!/bin/bash
# Hardened XDC node installer – SSL/TLS RPC + WSS (domain + Let's Encrypt only)
# Exact path endpoints: /xdcrpc and /xdcwss

set -euo pipefail

# ========== Colours & helpers ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

# Log failures to the summary file so they are visible after screen exits
trap '
  SUMMARY_FILE="${REAL_HOME}/Plugin-XDC-Secure-RPC-WSS/xdc-install-summary.txt"
  {
    echo "=== INSTALLATION FAILED ==="
    echo "Date: $(date)"
    echo "Failed at line $LINENO (exit code $?)"
    echo
    echo "Last known location: Preparing for / downloading chain snapshot"
    echo
    echo "Check disk space and the aria2c / tar output above."
  } > "$SUMMARY_FILE" 2>/dev/null || true
  error "Script failed at line $LINENO (exit code $?)"
  echo "Details written to: $SUMMARY_FILE"
  exit 1
' ERR

# false # Testing error-trapping and handling

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
  local default="${2:-n}"   # y or n
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

# ========== Configurable snapshot URLs ==========
# Override these if the official locations change.
# Leave empty to skip a particular snapshot type.
MAINNET_FULL_SNAPSHOT="https://download.xinfin.network/xdcchain.tar"
MAINNET_ARCHIVE_SNAPSHOT="https://downloads.xinfin.network/xdcchain_archive.tar"
TESTNET_FULL_SNAPSHOT="https://downloads.apothem.network/xdcchain.tar"
TESTNET_ARCHIVE_SNAPSHOT="https://downloads.apothem.network/xdcchain_archive.tar"

# ========== Interactive configuration ==========
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║         XDCoutpost.xyz – for Plugin RPCaaS Operators         ║
║         Secure RPC + WSS Node Installer                      ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

header "Node configuration"

prompt NETWORK "Network (mainnet or testnet)" "mainnet"
if [[ "$NETWORK" != "mainnet" && "$NETWORK" != "testnet" ]]; then
  error "NETWORK must be 'mainnet' or 'testnet'."
  exit 1
fi

prompt GC_MODE "Node type: full (pruned, less disk) or archive (full history)" "full"
if [[ "$GC_MODE" != "full" && "$GC_MODE" != "archive" ]]; then
  error "GC_MODE must be 'full' or 'archive'."
  exit 1
fi

info "Available APIs:"
info "  eth,net,web3                  (recommended default)"
info "  debug,trace                   (recommended for archive nodes)"
info "  db,txpool,XDPoS               (optional extras)"
info "  admin,personal                (dangerous if exposed — avoid)"
info "  miner                         (rarely needed)"

DEFAULT_API="eth,net,web3"
if [[ "$GC_MODE" == "archive" ]]; then
  DEFAULT_API="${DEFAULT_API},debug,trace"
fi

prompt API "Comma-separated APIs to enable" "$DEFAULT_API"

# Safety warning
if [[ "$API" == *admin* || "$API" == *personal* ]]; then
  warn "You included 'admin' and/or 'personal'. These can be dangerous if the endpoint is reachable."
  if ! yesno "Continue anyway?" "n"; then
    exit 1
  fi
fi

prompt INSTANCE_NAME "Node name (shown on network stats)" "XDCoutpost.xyz_Secure_XDC_Node"
prompt CONTACT_EMAIL "Contact email"

prompt DOMAIN "Domain name (DNS A record must already point to this server)"

# ========== DNS check ==========
header "Verifying domain points to this server"
info "Detecting this server's public IP..."
PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me || \
            curl -4 -s --max-time 10 icanhazip.com || \
            curl -4 -s --max-time 10 ipinfo.io/ip || true)

if [[ -z "$PUBLIC_IP" ]]; then
  error "Could not detect this server's public IP address."
  error "Check your internet connection and try again."
  exit 1
fi
info "This server's public IP: ${PUBLIC_IP}"

info "Looking up A record for ${DOMAIN}..."
# Ensure dig is available
if ! command -v dig &>/dev/null; then
  info "Installing dnsutils for DNS lookup..."
  apt-get update -qq
  apt-get install -y dnsutils >/dev/null
fi

DOMAIN_IP=$(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)

if [[ -z "$DOMAIN_IP" ]]; then
  echo
  error "No A record found for ${DOMAIN}."
  error "Please create a DNS A record that points ${DOMAIN} to ${PUBLIC_IP}"
  error "and wait for it to propagate, then re-run this installer."
  exit 1
fi

info "Domain ${DOMAIN} currently resolves to: ${DOMAIN_IP}"

if [[ "$DOMAIN_IP" != "$PUBLIC_IP" ]]; then
  echo
  error "DNS mismatch!"
  error "  Domain ${DOMAIN} points to: ${DOMAIN_IP}"
  error "  This server's IP is:       ${PUBLIC_IP}"
  echo
  error "Let's Encrypt will fail unless the domain points to this server."
  error "Update your DNS A record so that ${DOMAIN} → ${PUBLIC_IP}"
  error "Wait for propagation (usually a few minutes), then re-run the installer."
  exit 1
fi

success "Domain ${DOMAIN} correctly points to this server (${PUBLIC_IP})"
echo

prompt CERT_EMAIL "Let's Encrypt email" "$CONTACT_EMAIL"
prompt SSH_PORT "SSH port" "22"

# ========== Snapshot option ==========
header "Chain snapshot"
if yesno "Download the official chain snapshot? (much faster sync, but a large download)" "y"; then
  USE_SNAPSHOT=true
  info "Snapshot selected."
else
  USE_SNAPSHOT=false
  info "Will sync from genesis (slower)."
fi

# ========== IP whitelist collection ==========
header "RPC / WSS IP whitelist"

declare -a ALLOWED_IPS=()
declare -a ALLOWED_LABELS=()

if yesno "Whitelist the Plugin RPCaaS server (194.163.189.137)?" "y"; then
  ALLOWED_IPS+=("194.163.189.137")
  ALLOWED_LABELS+=("Plugin RPCaaS")
  success "Added Plugin RPCaaS (194.163.189.137)"
fi

# Optional testing IP (so the user can verify from outside)
if yesno "Add an IP address that you will use for testing the RPC/WSS endpoints?" "y"; then
  while true; do
    read -rp "$(echo -e "${YELLOW}Testing IP address: ${NC}")" test_ip
    [[ -n "$test_ip" ]] && break
    warn "IP cannot be empty."
  done
  test_label="Testing IP"
  ALLOWED_IPS+=("$test_ip")
  ALLOWED_LABELS+=("$test_label")
  success "Added testing IP ${test_ip} (${test_label})"
fi

info "You can now add any additional IP addresses that should be allowed to reach /xdcrpc and /xdcwss."
while yesno "Add another IP address?" "n"; do
  local_ip=""
  local_label=""
  while true; do
    read -rp "$(echo -e "${YELLOW}IP address: ${NC}")" local_ip
    [[ -n "$local_ip" ]] && break
    warn "IP cannot be empty."
  done
  read -rp "$(echo -e "${YELLOW}Label / comment for this IP: ${NC}")" local_label
  local_label="${local_label:-Unlabelled}"

  ALLOWED_IPS+=("$local_ip")
  ALLOWED_LABELS+=("$local_label")
  success "Added ${local_ip} (${local_label})"
done

if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
  warn "No IPs were whitelisted. The endpoints will deny all traffic."
  if ! yesno "Continue anyway?" "n"; then
    error "Aborted by user."
    exit 1
  fi
fi

echo
info "Summary of configuration:"
echo "  Network:        $NETWORK"
echo "  Node type:      $GC_MODE"
echo "  APIs:           $API"
echo "  Instance name:  $INSTANCE_NAME"
echo "  Domain:         $DOMAIN"
echo "  SSH port:       $SSH_PORT"
echo "  Chain snapshot: $([[ "$USE_SNAPSHOT" == true ]] && echo "Yes (download official tarball)" || echo "No (sync from genesis)")"
echo "  Allowed IPs:"
for i in "${!ALLOWED_IPS[@]}"; do
  echo "    - ${ALLOWED_IPS[$i]}  # ${ALLOWED_LABELS[$i]}"
done
echo

if ! yesno "Proceed with installation?" "y"; then
  error "Aborted by user."
  exit 1
fi

# ========== Paths ==========
# Use the real user's home even when run with sudo
if [[ -n "${SUDO_USER:-}" ]]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_HOME="$HOME"
fi
NODE_DIR="$REAL_HOME/XinFin-Node"
CHAIN_DIR="$NODE_DIR/$NETWORK"

# ========== System update & packages ==========
header "Updating system and installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release git jq nginx certbot python3-certbot-nginx ufw fail2ban openssl aria2

# ========== Docker ==========
header "Installing Docker"
apt-get remove -y docker docker-engine docker.io containerd runc docker-compose || true
rm -f /usr/local/bin/docker-compose || true

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

apt-get remove -y docker-ce-rootless-extras || true
apt-mark hold docker-ce-rootless-extras
systemctl restart docker
if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG docker "$SUDO_USER" || true
fi
success "Docker installed"

# ========== Clone & configure node ==========
header "Cloning / updating XinFin-Node"
if [[ ! -d "$NODE_DIR" ]]; then
  git clone https://github.com/XinFinOrg/XinFin-Node.git "$NODE_DIR"
else
  cd "$NODE_DIR" && git pull || true
fi
# Ensure the real user owns the node directory
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$NODE_DIR"
fi
cd "$CHAIN_DIR"

header "Configuring .env"
cp -n env.example .env || true
sed -i "s/^INSTANCE_NAME=.*/INSTANCE_NAME=${INSTANCE_NAME}/" .env
sed -i "s/^CONTACT_DETAILS=.*/CONTACT_DETAILS=${CONTACT_EMAIL}/" .env
sed -i "s/^ENABLE_RPC=.*/ENABLE_RPC=true/" .env
sed -i "s/^ENABLE_WS=.*/ENABLE_WS=true/" .env
sed -i "s/^GC_MODE=.*/GC_MODE=${GC_MODE}/" .env
sed -i "s|^API=.*|API=${API}|" .env

# Handle both mainnet (INSTANCE_NAME) and testnet (NODE_NAME)
if grep -q '^NODE_NAME=' .env; then
  sed -i "s/^NODE_NAME=.*/NODE_NAME=${INSTANCE_NAME}/" .env
fi

RPC_PORT=$(grep '^RPC_PORT=' .env | cut -d= -f2 || echo 8989)
WS_PORT=$(grep '^WS_PORT=' .env | cut -d= -f2 || echo 8888)

# ========== docker-compose ==========
header "Writing docker-compose.yml (localhost-only RPC/WS)"
cp -n docker-compose.yml docker-compose.yml.bak || true

IMAGE=$(grep -A1 'image:' docker-compose.yml.bak | head -1 | awk '{print $2}' || echo "xinfinorg/xdposchain:v2.7.0")

cat > docker-compose.yml << EOF
services:
  xinfinnetwork:
    container_name: xdcnetwork-${NETWORK}-node
    image: ${IMAGE}
    volumes:
      - "./xdcchain:/work/xdcchain"
      - "./genesis.json:/work/genesis.json"
      - "./start-node.sh:/work/start.sh"
      - "./bootnodes.list:/work/bootnodes.list"
      - "./.pwd:/work/.pwd"
      - "/etc/localtime:/etc/localtime:ro"
    pull_policy: always
    restart: "always"
    env_file:
      - .env
    ports:
      - "30303:30303"
      - "127.0.0.1:${RPC_PORT}:${RPC_PORT}"
      - "127.0.0.1:${WS_PORT}:${WS_PORT}"
EOF

if [[ "$NETWORK" == "testnet" ]]; then
  sed -i 's|start-node.sh|start-apothem.sh|' docker-compose.yml
  sed -i 's|./xdcchain:|./xdcchain-testnet:|' docker-compose.yml || true
fi

# ========== Start node once (creates directory structure) ==========
header "Starting the node (initial run to create directories)"
docker compose -f docker-compose.yml up -d
sleep 20
docker compose -f docker-compose.yml logs --tail 20 || true
success "Node started for initial setup"

# ========== Optional chain snapshot ==========
if [[ "$USE_SNAPSHOT" == true ]]; then
  header "Preparing for chain snapshot"
  info "Stopping node..."
  docker compose -f docker-compose.yml down || true

  # Remove only the inner XDC chain directory
  if [[ -d "$CHAIN_DIR/xdcchain/XDC" ]]; then
    info "Removing generated xdcchain/XDC directory..."
    rm -rf "$CHAIN_DIR/xdcchain/XDC" || true
  fi

  header "Downloading chain snapshot"
  SNAP_DIR="$CHAIN_DIR/snapshot-download"
  mkdir -p "$SNAP_DIR"
  cd "$SNAP_DIR"

  # Select correct snapshot based on NETWORK + GC_MODE
  if [[ "$NETWORK" == "mainnet" ]]; then
    if [[ "$GC_MODE" == "archive" ]]; then
      SNAPSHOT_URL="$MAINNET_ARCHIVE_SNAPSHOT"
    else
      SNAPSHOT_URL="$MAINNET_FULL_SNAPSHOT"
    fi
  else  # testnet / apothem
    if [[ "$GC_MODE" == "archive" ]]; then
      SNAPSHOT_URL="$TESTNET_ARCHIVE_SNAPSHOT"
    else
      SNAPSHOT_URL="$TESTNET_FULL_SNAPSHOT"
    fi
  fi

  info "Using snapshot: $SNAPSHOT_URL"

  # Derive the filename from the URL (handles both xdcchain.tar and xdcchain_archive.tar)
  SNAPSHOT_FILE=$(basename "$SNAPSHOT_URL")

  info "Downloading snapshot (this can take a long time)..."
  if ! aria2c -x 8 -s 8 -k 1M --continue=true "$SNAPSHOT_URL"; then
    error "aria2c download failed."
    ls -lh || true
    df -h /tmp "$CHAIN_DIR" || true
    exit 1
  fi

  info "Extracting snapshot (this can take a long time — progress updates every few thousand files)..."
  if ! tar -xf "$SNAPSHOT_FILE" --checkpoint=5000 --checkpoint-action=echo="  ... extracted %u files"; then
    error "tar extract failed."
    ls -lh || true
    exit 1
  fi
  success "Extraction finished."

  if [[ -d XDC ]]; then
    # Clean files that must not be reused
    rm -f XDC/nodekey XDC/transactions.rlp || true

    # Place the new XDC directory where the node expects it
    if mv XDC "$CHAIN_DIR/xdcchain/XDC"; then
      # Fix ownership
      if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER:$SUDO_USER" "$CHAIN_DIR/xdcchain" || true
      fi
      success "Snapshot installed at $CHAIN_DIR/xdcchain/XDC (nodekey and transactions.rlp removed)"
    else
      error "Failed to move XDC directory into place."
      exit 1
    fi
  else
    warn "Expected XDC directory not found after extract. Starting without snapshot."
    ls -lh || true
  fi

  # Cleanup
  cd /
  rm -rf "$SNAP_DIR" || true
  
  # Return to the chain directory
  cd "$CHAIN_DIR"
fi

# ========== Final node start ==========
header "Starting the node"
docker compose -f docker-compose.yml up -d
sleep 15
docker compose -f docker-compose.yml logs --tail 30 || true
success "Node container started"

# ========== UFW ==========
header "Configuring UFW (IPv4 only)"
# Force IPv6 off
if grep -q '^IPV6=' /etc/default/ufw; then
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
else
  echo "IPV6=no" >> /etc/default/ufw
fi

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw allow 30303/tcp comment 'XDC P2P TCP'
ufw allow 30303/udp comment 'XDC P2P UDP'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
success "UFW configured (IPv6 disabled)"

# ========== Fail2Ban ==========
header "Configuring Fail2Ban (SSH)"
if [[ ! -f /etc/fail2ban/jail.local ]]; then
  cp -p /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

cat > /etc/fail2ban/jail.d/sshd-hardened.local << EOF
[sshd]
enabled = true
filter = sshd
port = ${SSH_PORT}
banaction = iptables-multiport
findtime = 86400
bantime = -1
maxretry = 3
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl restart fail2ban
systemctl enable fail2ban
success "Fail2Ban SSH jail enabled (3 fails in 24h → permanent ban)"

# ========== Let's Encrypt + Nginx ==========
HOST="$DOMAIN"
CERT_FULLCHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
CERT_PRIVKEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
SSL_INCLUDE='include /etc/letsencrypt/options-ssl-nginx.conf; ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;'

header "Temporary HTTP config for Certbot"
cat > /etc/nginx/sites-available/xdc-node << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        return 200 'Certbot validation ready';
        add_header Content-Type text/plain;
    }
}
EOF
ln -sf /etc/nginx/sites-available/xdc-node /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx || systemctl start nginx

header "Obtaining Let's Encrypt certificate"
certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${CERT_EMAIL}" --redirect || {
  warn "Certbot failed. Ensure the DNS A record points to this server and ports 80/443 are open."
  warn "You can re-run certbot later: certbot --nginx -d ${DOMAIN}"
}

# Build allow lines with labels
ALLOW_LINES=""
for i in "${!ALLOWED_IPS[@]}"; do
  ALLOW_LINES+="        allow ${ALLOWED_IPS[$i]};  # ${ALLOWED_LABELS[$i]}"$'\n'
done

header "Writing final Nginx configuration"
cat > /etc/nginx/sites-available/xdc-node << EOF
# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name ${HOST};
    return 301 https://\$host\$request_uri;
}

# HTTPS – exact match endpoints
server {
    listen 443 ssl http2;
    server_name ${HOST};

    ssl_certificate ${CERT_FULLCHAIN};
    ssl_certificate_key ${CERT_PRIVKEY};
    ${SSL_INCLUDE}

    add_header Strict-Transport-Security "max-age=31536000" always;

    location = /xdcrpc {
${ALLOW_LINES}        deny all;

        # CORS for MetaMask and browser clients
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;

        if (\$request_method = OPTIONS) {
            return 204;
        }

        proxy_pass http://127.0.0.1:${RPC_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }

    location = /xdcwss {
${ALLOW_LINES}        deny all;

        proxy_pass http://127.0.0.1:${WS_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    location / {
        return 404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/xdc-node /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
success "Nginx configuration applied"

# Write a copy of the summary that survives after screen exits
SUMMARY_FILE="${REAL_HOME}/Plugin-XDC-Secure-RPC-WSS/xdc-install-summary.txt"
{
  echo "=== Installation complete ==="
  echo
  echo "Node type: $GC_MODE"
  echo "APIs:      $API"
  echo
  echo "RPC:  https://${HOST}/xdcrpc"
  echo "WSS:  wss://${HOST}/xdcwss"
  echo
  echo "Test from a whitelisted external IP:"
  echo
  echo "RPC:"
  echo "  curl -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}' https://${HOST}/xdcrpc"
  echo
  echo "WSS (using wscat):"
  echo "  # Install once if needed: sudo npm install -g wscat"
  echo "  wscat -c wss://${HOST}/xdcwss"
  echo "  # You should see: Connected (press CTRL+C to quit)"
  echo "  # Then type: {\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}"
  echo "  # To exit wscat: type exit or press CTRL+C"
  echo
  echo "Node status:"
  echo "  sudo docker compose -f $CHAIN_DIR/docker-compose.yml ps"
  echo
  echo "Managing whitelisted IPs:"
  echo "  Use the companion script instead of editing Nginx by hand:"
  echo "    sudo ./manage_whitelist.sh"
  echo
  echo "  It lets you view, add, or remove IPs (with labels) for RPC and/or WSS."
  echo "  You can remove the testing IP later if you no longer need it."
  echo
  echo "Done."
} > "$SUMMARY_FILE"

success "Summary also saved to: $SUMMARY_FILE"

# ========== Final output ==========
header "Installation complete
echo -e "${GREEN}RPC:${NC}  https://${HOST}/xdcrpc"
echo -e "${GREEN}WSS:${NC}  wss://${HOST}/xdcwss"
echo
echo -e "${BOLD}Test from a whitelisted external IP:${NC}"
echo
echo -e "${BOLD}RPC:${NC}"
echo "  curl -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}' https://${HOST}/xdcrpc"
echo
echo -e "${BOLD}WSS (using wscat):${NC}"
echo "  # Install once if needed: sudo npm install -g wscat"
echo "  wscat -c wss://${HOST}/xdcwss"
echo "  # You should see: Connected (press CTRL+C to quit)"
echo "  # Then type: {\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}"
echo "  # To exit wscat: type exit or press CTRL+C"
echo
echo -e "${BOLD}Node status:${NC}"
echo "  sudo docker compose -f $CHAIN_DIR/docker-compose.yml ps"
echo
echo -e "${BOLD}Managing whitelisted IPs:${NC}"
echo "  Use the companion script instead of editing Nginx by hand:"
echo "    sudo ./manage_whitelist.sh"
echo
echo "  It lets you view, add, or remove IPs (with labels) for RPC and/or WSS."
echo "  You can remove the testing IP later if you no longer need it."
echo
success "Done."
