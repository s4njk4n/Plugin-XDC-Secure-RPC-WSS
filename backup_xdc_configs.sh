#!/bin/bash
# Standalone backup of current XDC node Nginx config, .env and docker-compose.yml
# Run anytime (e.g. before upgrades or git pulls)

set -euo pipefail

# Colours (optional, matches installer style)
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

backup_timestamp() {
  date +%Y-%m-%d_%H-%M-%S
}

# Determine real home (works whether run with sudo or not)
REAL_HOME=$([[ -n ${SUDO_USER:-} ]] && getent passwd "$SUDO_USER" | cut -d: -f6 || echo "$HOME")
TS=$(backup_timestamp)

info "Backup timestamp: $TS"
info "Target directory: $REAL_HOME"

# --- Nginx ---
NGINX_SRC="/etc/nginx/sites-available/xdc-node"
if [[ -f "$NGINX_SRC" ]]; then
  NGINX_DEST="${REAL_HOME}/XDCnode-Nginx.config.backup-xdc-node_${TS}"
  cp "$NGINX_SRC" "$NGINX_DEST"
  chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$NGINX_DEST" 2>/dev/null || true
  success "Nginx config → $NGINX_DEST"
else
  warn "Nginx config not found at $NGINX_SRC"
fi

# --- Locate node directory ---
NODE_DIR="$REAL_HOME/XinFin-Node"
if [[ ! -d "$NODE_DIR" ]]; then
  warn "XinFin-Node directory not found at $NODE_DIR — skipping .env and docker-compose backups"
  exit 0
fi

# Try both networks; back up whichever exists
for NETWORK in mainnet testnet; do
  CHAIN_DIR="$NODE_DIR/$NETWORK"
  if [[ -d "$CHAIN_DIR" ]]; then
    info "Found $NETWORK chain directory"

    # .env
    if [[ -f "$CHAIN_DIR/.env" ]]; then
      ENV_DEST="${REAL_HOME}/XDCnode-env.backup-.env_${TS}"
      cp "$CHAIN_DIR/.env" "$ENV_DEST"
      chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$ENV_DEST" 2>/dev/null || true
      success ".env ($NETWORK) → $ENV_DEST"
    else
      warn "No .env in $CHAIN_DIR"
    fi

    # docker-compose.yml
    if [[ -f "$CHAIN_DIR/docker-compose.yml" ]]; then
      COMPOSE_DEST="${REAL_HOME}/XDCnode-docker.settings.backup-docker-compose.yml_${TS}"
      cp "$CHAIN_DIR/docker-compose.yml" "$COMPOSE_DEST"
      chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$COMPOSE_DEST" 2>/dev/null || true
      success "docker-compose.yml ($NETWORK) → $COMPOSE_DEST"
    else
      warn "No docker-compose.yml in $CHAIN_DIR"
    fi
  fi
done

success "Backup complete."
echo
echo "Files are in: $REAL_HOME"
ls -1 "$REAL_HOME"/XDCnode-*.backup-* 2>/dev/null | tail -n 10 || true
