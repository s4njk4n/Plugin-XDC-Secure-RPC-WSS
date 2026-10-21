#!/bin/bash
# Hardened XDC node installer – SSL/TLS RPC + WSS (domain + Let's Encrypt only)
# Exact path endpoints: /xdcrpc and /xdcwss

set -euo pipefail

# =============================================================================
# Colours & helpers
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

trap '
  local_home="${REAL_HOME:-$HOME}"
  SUMMARY_FILE="${local_home}/Plugin-XDC-Secure-RPC-WSS/xdc-install-summary.txt"
  {
    echo "=== INSTALLATION FAILED ==="
    echo "Date: $(date)"
    echo "Failed at line $LINENO (exit code $?)"
    echo
    echo "Check the screen log and the output above for the exact error."
  } > "$SUMMARY_FILE" 2>/dev/null || true
  error "Script failed at line $LINENO (exit code $?)"
  echo "Details written to: $SUMMARY_FILE"
  exit 1
' ERR

prompt() {
  local var="$1" text="$2" def="${3:-}" val
  if [[ -n "$def" ]]; then
    read -rp "$(echo -e "${YELLOW}${text} [${def}]: ${NC}")" val
    val="${val:-$def}"
  else
    while [[ -z "${val:-}" ]]; do
      read -rp "$(echo -e "${YELLOW}${text}: ${NC}")" val
      [[ -z "$val" ]] && warn "This field cannot be empty."
    done
  fi
  printf -v "$var" '%s' "$val"
}

yesno() {
  local text="$1" def="${2:-n}" ans hint="[y/N]"
  [[ "$def" == "y" ]] && hint="[Y/n]"
  while true; do
    read -rp "$(echo -e "${YELLOW}${text} ${hint}: ${NC}")" ans
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# =============================================================================
# Configurable snapshot URLs
# =============================================================================
MAINNET_FULL_SNAPSHOT="https://download.xinfin.network/xdcchain.tar"
MAINNET_ARCHIVE_SNAPSHOT="https://downloads.xinfin.network/xdcchain_archive.tar"
TESTNET_FULL_SNAPSHOT="https://downloads.apothem.network/xdcchain.tar"
TESTNET_ARCHIVE_SNAPSHOT="https://downloads.apothem.network/xdcchain_archive.tar"

# =============================================================================
# Interactive configuration
# =============================================================================
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
[[ "$NETWORK" =~ ^(mainnet|testnet)$ ]] || { error "NETWORK must be 'mainnet' or 'testnet'."; exit 1; }

prompt GC_MODE "Node type: full (pruned, less disk) or archive (full history)" "full"
[[ "$GC_MODE" =~ ^(full|archive)$ ]] || { error "GC_MODE must be 'full' or 'archive'."; exit 1; }

info "Available APIs:"
info "  eth,net,web3                  (recommended default)"
info "  debug,trace                   (recommended for archive nodes)"
info "  db,txpool,XDPoS               (optional extras)"
info "  admin,personal                (dangerous if exposed — avoid)"
info "  miner                         (rarely needed)"

DEFAULT_API="eth,net,web3"
[[ "$GC_MODE" == "archive" ]] && DEFAULT_API+=",debug,trace"
prompt API "Comma-separated APIs to enable" "$DEFAULT_API"

if [[ "$API" =~ (admin|personal) ]]; then
  warn "You included 'admin' and/or 'personal'. These can be dangerous if the endpoint is reachable."
  yesno "Continue anyway?" "n" || exit 1
fi

prompt INSTANCE_NAME "Node name (shown on network stats)" "XDCoutpost.xyz_Secure_XDC_Node"
prompt CONTACT_EMAIL "Contact email"
prompt DOMAIN "Domain name (DNS A record must already point to this server)"

# =============================================================================
# DNS verification
# =============================================================================
header "Verifying domain points to this server"
info "Detecting this server's public IP..."
PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me || curl -4 -s --max-time 10 icanhazip.com || curl -4 -s --max-time 10 ipinfo.io/ip || true)
[[ -n "$PUBLIC_IP" ]] || { error "Could not detect public IP."; exit 1; }
info "This server's public IP: ${PUBLIC_IP}"

command -v dig &>/dev/null || { info "Installing dnsutils..."; apt-get update -qq && apt-get install -y dnsutils >/dev/null; }
DOMAIN_IP=$(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
[[ -n "$DOMAIN_IP" ]] || { error "No A record for ${DOMAIN}. Point it to ${PUBLIC_IP} and re-run."; exit 1; }
[[ "$DOMAIN_IP" == "$PUBLIC_IP" ]] || { error "DNS mismatch: ${DOMAIN} → ${DOMAIN_IP} (expected ${PUBLIC_IP})."; exit 1; }
success "Domain ${DOMAIN} correctly points to this server"

prompt CERT_EMAIL "Let's Encrypt email" "$CONTACT_EMAIL"
prompt SSH_PORT "SSH port" "22"

# =============================================================================
# Snapshot & whitelist
# =============================================================================
header "Chain snapshot"
yesno "Download the official chain snapshot? (much faster sync, but a large download)" "y" && USE_SNAPSHOT=true || USE_SNAPSHOT=false
[[ "$USE_SNAPSHOT" == true ]] && info "Snapshot selected." || info "Will sync from genesis."

header "RPC / WSS IP whitelist"
declare -a ALLOWED_IPS=() ALLOWED_LABELS=()

yesno "Whitelist the Plugin RPCaaS server (194.163.189.137)?" "y" && {
  ALLOWED_IPS+=("194.163.189.137"); ALLOWED_LABELS+=("Plugin RPCaaS")
  success "Added Plugin RPCaaS"
}

yesno "Add an IP for testing the RPC/WSS endpoints?" "y" && {
  while [[ -z "${test_ip:-}" ]]; do
    read -rp "$(echo -e "${YELLOW}Testing IP address: ${NC}")" test_ip
    [[ -z "$test_ip" ]] && warn "IP cannot be empty."
  done
  ALLOWED_IPS+=("$test_ip"); ALLOWED_LABELS+=("Testing IP")
  success "Added testing IP ${test_ip}"
}

while yesno "Add another IP address?" "n"; do
  while [[ -z "${ip:-}" ]]; do
    read -rp "$(echo -e "${YELLOW}IP address: ${NC}")" ip
    [[ -z "$ip" ]] && warn "IP cannot be empty."
  done
  read -rp "$(echo -e "${YELLOW}Label / comment: ${NC}")" label
  ALLOWED_IPS+=("$ip"); ALLOWED_LABELS+=("${label:-Unlabelled}")
  success "Added ${ip}"
  unset ip label
done

(( ${#ALLOWED_IPS[@]} )) || { warn "No IPs whitelisted."; yesno "Continue anyway?" "n" || exit 1; }

echo
info "Summary:"
printf "  %-16s %s\n" "Network:" "$NETWORK" "Node type:" "$GC_MODE" "APIs:" "$API" \
  "Instance name:" "$INSTANCE_NAME" "Domain:" "$DOMAIN" "SSH port:" "$SSH_PORT" \
  "Snapshot:" "$([[ $USE_SNAPSHOT == true ]] && echo Yes || echo No)"
echo "  Allowed IPs:"
for i in "${!ALLOWED_IPS[@]}"; do printf "    - %s  # %s\n" "${ALLOWED_IPS[$i]}" "${ALLOWED_LABELS[$i]}"; done
echo
yesno "Proceed with installation?" "y" || exit 1

# =============================================================================
# Paths
# =============================================================================
REAL_HOME=$([[ -n ${SUDO_USER:-} ]] && getent passwd "$SUDO_USER" | cut -d: -f6 || echo "$HOME")
NODE_DIR="$REAL_HOME/XinFin-Node"
CHAIN_DIR="$NODE_DIR/$NETWORK"
CHAIN_DATA_DIR="$CHAIN_DIR/$([[ $NETWORK == testnet ]] && echo xdcchain-testnet || echo xdcchain)"
TARGET_XDC="$CHAIN_DATA_DIR/XDC"

# =============================================================================
# System & Docker
# =============================================================================
header "Updating system and installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release git jq \
  nginx certbot python3-certbot-nginx ufw fail2ban openssl aria2

header "Installing Docker"
apt-get remove -y docker docker-engine docker.io containerd runc docker-compose || true
rm -f /usr/local/bin/docker-compose || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list >/dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
apt-get remove -y docker-ce-rootless-extras || true
apt-mark hold docker-ce-rootless-extras
systemctl restart docker
[[ -n ${SUDO_USER:-} ]] && usermod -aG docker "$SUDO_USER" || true
success "Docker installed"

# =============================================================================
# Clone & configure node
# =============================================================================
header "Cloning / updating XinFin-Node"
[[ -d $NODE_DIR ]] || git clone https://github.com/XinFinOrg/XinFin-Node.git "$NODE_DIR"
(cd "$NODE_DIR" && git pull) || true
[[ -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER:$SUDO_USER" "$NODE_DIR"
cd "$CHAIN_DIR"

header "Configuring .env"
cp -n env.example .env || true
sed -i \
  -e "s/^INSTANCE_NAME=.*/INSTANCE_NAME=${INSTANCE_NAME}/" \
  -e "s/^CONTACT_DETAILS=.*/CONTACT_DETAILS=${CONTACT_EMAIL}/" \
  -e "s/^ENABLE_RPC=.*/ENABLE_RPC=true/" \
  -e "s/^ENABLE_WS=.*/ENABLE_WS=true/" \
  -e "s/^GC_MODE=.*/GC_MODE=${GC_MODE}/" \
  -e "s|^API=.*|API=${API}|" .env
grep -q '^NODE_NAME=' .env && sed -i "s/^NODE_NAME=.*/NODE_NAME=${INSTANCE_NAME}/" .env

RPC_PORT=$(grep '^RPC_PORT=' .env | cut -d= -f2 || echo 8989)
WS_PORT=$(grep '^WS_PORT=' .env | cut -d= -f2 || echo 8888)

# =============================================================================
# docker-compose
# =============================================================================
header "Writing docker-compose.yml"
cp -n docker-compose.yml docker-compose.yml.bak || true
IMAGE=$(awk '/image:/{print $2; exit}' docker-compose.yml.bak || echo "xinfinorg/xdposchain:v2.7.0")

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
    restart: always
    env_file: [.env]
    ports:
      - "30303:30303"
      - "127.0.0.1:${RPC_PORT}:${RPC_PORT}"
      - "127.0.0.1:${WS_PORT}:${WS_PORT}"
EOF

[[ $NETWORK == testnet ]] && sed -i -e 's|start-node.sh|start-apothem.sh|' -e 's|./xdcchain:|./xdcchain-testnet:|' docker-compose.yml

# =============================================================================
# Initial start + optional snapshot
# =============================================================================
header "Starting the node (initial run to create directories)"
docker compose up -d
sleep 20
docker compose logs --tail 20 || true
success "Node started for initial setup"

if [[ $USE_SNAPSHOT == true ]]; then
  header "Preparing for chain snapshot"
  docker compose down || true
  [[ -d $TARGET_XDC ]] && rm -rf "$TARGET_XDC"

  SNAP_DIR="$CHAIN_DIR/snapshot-download"
  rm -rf "$SNAP_DIR" && mkdir -p "$SNAP_DIR" && cd "$SNAP_DIR"

  if [[ $NETWORK == mainnet ]]; then
    SNAPSHOT_URL=$([[ $GC_MODE == archive ]] && echo "$MAINNET_ARCHIVE_SNAPSHOT" || echo "$MAINNET_FULL_SNAPSHOT")
  else
    SNAPSHOT_URL=$([[ $GC_MODE == archive ]] && echo "$TESTNET_ARCHIVE_SNAPSHOT" || echo "$TESTNET_FULL_SNAPSHOT")
  fi
  info "Using snapshot: $SNAPSHOT_URL"
  SNAPSHOT_FILE=$(basename "$SNAPSHOT_URL")

  info "Checking disk space..."
  REMOTE_SIZE=$(curl -sI --max-time 30 "$SNAPSHOT_URL" | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tr -d '\r' || true)
  if [[ $REMOTE_SIZE =~ ^[0-9]+$ ]]; then
    REQUIRED=$(( REMOTE_SIZE * 2 + 200*1024*1024*1024 ))
    AVAIL=$(df -B1 "$CHAIN_DIR" | awk 'NR==2{print $4}')
    info "Snapshot: $(numfmt --to=iec $REMOTE_SIZE)  Required free: $(numfmt --to=iec $REQUIRED)  Available: $(numfmt --to=iec $AVAIL)"
    (( AVAIL >= REQUIRED )) || { error "Insufficient disk space."; exit 1; }
  else
    warn "Could not determine remote size; skipping precise check."
  fi

  info "Downloading..."
  aria2c -x 8 -s 8 -k 1M --continue=true "$SNAPSHOT_URL" || { error "Download failed."; exit 1; }

  info "Extracting..."
  if file "$SNAPSHOT_FILE" | grep -q gzip; then
    tar_cmd=(tar -xzf "$SNAPSHOT_FILE")
  else
    tar_cmd=(tar -xf "$SNAPSHOT_FILE")
  fi
  "${tar_cmd[@]}" --checkpoint=5000 --checkpoint-action=echo="  ... %u files" || { error "Extract failed."; exit 1; }

  mkdir -p "$TARGET_XDC"
  if [[ $NETWORK == mainnet ]]; then
    [[ -d XDC ]] || { error "Mainnet snapshot missing XDC/."; exit 1; }
    shopt -s dotglob; mv XDC/* "$TARGET_XDC/"; shopt -u dotglob
    rmdir XDC 2>/dev/null || true
  else
    [[ -d chaindata || -d nodes || -d lightchaindata || -d rewards ]] || { error "Testnet snapshot missing expected dirs."; exit 1; }
    shopt -s dotglob
    for item in *; do
      [[ $item == "$SNAPSHOT_FILE" ]] && continue
      mv "$item" "$TARGET_XDC/"
    done
    shopt -u dotglob
  fi

  rm -f "$TARGET_XDC"/{nodekey,transactions.rlp} || true
  [[ -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER:$SUDO_USER" "$CHAIN_DATA_DIR" || true
  [[ -d $TARGET_XDC/chaindata || -d $TARGET_XDC/nodes ]] || { error "Verification failed."; exit 1; }
  success "Snapshot installed at $TARGET_XDC"

  cd / && rm -rf "$SNAP_DIR" && cd "$CHAIN_DIR"
fi

# =============================================================================
# Final start + firewall
# =============================================================================
header "Starting the node"
docker compose up -d
sleep 15
docker compose logs --tail 30 || true
success "Node container started"

header "Configuring UFW"
grep -q '^IPV6=' /etc/default/ufw && sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || echo "IPV6=no" >> /etc/default/ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw allow 30303/tcp comment 'XDC P2P'
ufw allow 30303/udp comment 'XDC P2P'
ufw allow 80,443/tcp comment 'HTTP/HTTPS'
ufw --force enable
success "UFW configured"

header "Configuring Fail2Ban"
[[ -f /etc/fail2ban/jail.local ]] || cp -p /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
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
systemctl enable --now fail2ban
success "Fail2Ban enabled"

# =============================================================================
# Nginx + Let's Encrypt
# =============================================================================
HOST=$DOMAIN
CERT_FULLCHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
CERT_PRIVKEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

header "Temporary HTTP config for Certbot"
cat > /etc/nginx/sites-available/xdc-node << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location / { return 200 'Certbot validation ready'; add_header Content-Type text/plain; }
}
EOF
ln -sf /etc/nginx/sites-available/xdc-node /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx || systemctl start nginx

header "Obtaining certificate"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL" --redirect || { error "Certbot failed."; exit 1; }

ALLOW_LINES=""
for i in "${!ALLOWED_IPS[@]}"; do
  ALLOW_LINES+="        allow ${ALLOWED_IPS[$i]};  # ${ALLOWED_LABELS[$i]}"$'\n'
done

header "Writing final Nginx configuration"
cat > /etc/nginx/sites-available/xdc-node << EOF
server {
    listen 80;
    server_name ${HOST};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${HOST};
    ssl_certificate ${CERT_FULLCHAIN};
    ssl_certificate_key ${CERT_PRIVKEY};
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location = /xdcrpc {
${ALLOW_LINES}        deny all;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
        if (\$request_method = OPTIONS) { return 204; }
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
    location / { return 404; }
}
EOF
ln -sf /etc/nginx/sites-available/xdc-node /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
success "Nginx configuration applied"

# =============================================================================
# Summary
# =============================================================================
SUMMARY_FILE="${REAL_HOME}/Plugin-XDC-Secure-RPC-WSS/xdc-install-summary.txt"
cat > "$SUMMARY_FILE" << EOF
=== Installation complete ===

Node type: $GC_MODE
APIs:      $API

RPC:  https://${HOST}/xdcrpc
WSS:  wss://${HOST}/xdcwss

Test from a whitelisted external IP:

RPC:
  curl -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' https://${HOST}/xdcrpc

WSS (using wscat):
  sudo npm install -g wscat
  wscat -c wss://${HOST}/xdcwss
  # Once connected, paste this and press Enter:
  {"jsonrpc":"2.0","method":"net_version","params":[],"id":1}
  # Expected result: "50" (mainnet) or "51" (testnet)
  # To exit: type exit or press Ctrl+C

Node status:
  sudo docker compose -f $CHAIN_DIR/docker-compose.yml ps

Managing whitelisted IPs:
  sudo ./manage_whitelist.sh
EOF

success "Summary saved to: $SUMMARY_FILE"

header "Installation complete"

echo -e "${BOLD}${CYAN}Node type:${NC}  ${GREEN}${GC_MODE}${NC}"
echo -e "${BOLD}${CYAN}APIs:${NC}       ${GREEN}${API}${NC}"
echo
echo -e "${BOLD}${GREEN}RPC:${NC}  ${CYAN}https://${HOST}/xdcrpc${NC}"
echo -e "${BOLD}${GREEN}WSS:${NC}  ${CYAN}wss://${HOST}/xdcwss${NC}"
echo

echo -e "${BOLD}${YELLOW}Test from a whitelisted external IP:${NC}"
echo
echo -e "  ${BOLD}RPC:${NC}"
echo -e "  ${CYAN}curl -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}' https://${HOST}/xdcrpc${NC}"
echo
echo -e "  ${BOLD}WSS (using wscat):${NC}"
echo -e "  ${CYAN}sudo npm install -g wscat${NC}"
echo -e "  ${CYAN}wscat -c wss://${HOST}/xdcwss${NC}"
echo -e "  ${CYAN}# Once connected, paste this and press Enter:${NC}"
echo -e "  ${CYAN}{\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}${NC}"
echo -e "  ${CYAN}# Expected result: \"50\" (mainnet) or \"51\" (testnet)${NC}"
echo -e "  ${CYAN}# To exit: type exit or press Ctrl+C${NC}"
echo

echo -e "${BOLD}${YELLOW}Node status:${NC}"
echo -e "  ${CYAN}sudo docker compose -f ${CHAIN_DIR}/docker-compose.yml ps${NC}"
echo

echo -e "${BOLD}${YELLOW}Managing whitelisted IPs:${NC}"
echo -e "  ${CYAN}sudo ./manage_whitelist.sh${NC}"
echo

success "Done."
