#!/bin/bash
# Standalone backup of current XDC node Nginx config, .env and docker-compose.yml
# Detects which network is in use:
#   1. Running container (preferred)
#   2. Presence of chain data (fallback)

set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

REAL_HOME=$([[ -n ${SUDO_USER:-} ]] && getent passwd "$SUDO_USER" | cut -d: -f6 || echo "$HOME")
BACKUP_DIR="${REAL_HOME}/XDC-Backups"
TS=$(date +%Y-%m-%d_%H-%M-%S)
NODE_DIR="$REAL_HOME/XinFin-Node"

mkdir -p "$BACKUP_DIR"
chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$BACKUP_DIR" 2>/dev/null || true

info "Backup timestamp: $TS"
info "Backup directory: $BACKUP_DIR"

# --- Detect active network ---
NETWORK=""

# 1. Prefer a running container
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^xdcnetwork-mainnet-node$'; then
    NETWORK="mainnet"
    info "Detected running mainnet container"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^xdcnetwork-testnet-node$'; then
    NETWORK="testnet"
    info "Detected running testnet container"
  fi
fi

# 2. Fallback: which network has chain data?
if [[ -z "$NETWORK" ]]; then
  MAINNET_XDC="$NODE_DIR/mainnet/xdcchain/XDC"
  TESTNET_XDC="$NODE_DIR/testnet/xdcchain-testnet/XDC"

  MAINNET_HAS_DATA=false
  TESTNET_HAS_DATA=false

  [[ -d "$MAINNET_XDC" && -n "$(ls -A "$MAINNET_XDC" 2>/dev/null)" ]] && MAINNET_HAS_DATA=true
  [[ -d "$TESTNET_XDC" && -n "$(ls -A "$TESTNET_XDC" 2>/dev/null)" ]] && TESTNET_HAS_DATA=true

  if $MAINNET_HAS_DATA && ! $TESTNET_HAS_DATA; then
    NETWORK="mainnet"
    info "No running container — using mainnet (chain data found)"
  elif $TESTNET_HAS_DATA && ! $MAINNET_HAS_DATA; then
    NETWORK="testnet"
    info "No running container — using testnet (chain data found)"
  elif $MAINNET_HAS_DATA && $TESTNET_HAS_DATA; then
    warn "Both mainnet and testnet have chain data. Using mainnet by default."
    NETWORK="mainnet"
  else
    warn "Could not determine network (no running container and no chain data found)."
    exit 1
  fi
fi

CHAIN_DIR="$NODE_DIR/$NETWORK"
info "Using network: $NETWORK"

# --- Nginx (shared) ---
NGINX_SRC="/etc/nginx/sites-available/xdc-node"
if [[ -f "$NGINX_SRC" ]]; then
  NGINX_DEST="${BACKUP_DIR}/XDCnode-Nginx.config.backup-xdc-node_${TS}"
  cp "$NGINX_SRC" "$NGINX_DEST"
  chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$NGINX_DEST" 2>/dev/null || true
  success "Nginx config → $NGINX_DEST"
else
  warn "Nginx config not found at $NGINX_SRC"
fi

# --- .env ---
if [[ -f "$CHAIN_DIR/.env" ]]; then
  ENV_DEST="${BACKUP_DIR}/XDCnode-env.backup-${NETWORK}-.env_${TS}"
  cp "$CHAIN_DIR/.env" "$ENV_DEST"
  chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$ENV_DEST" 2>/dev/null || true
  success ".env ($NETWORK) → $ENV_DEST"
else
  warn "No .env found at $CHAIN_DIR/.env"
fi

# --- docker-compose.yml ---
if [[ -f "$CHAIN_DIR/docker-compose.yml" ]]; then
  COMPOSE_DEST="${BACKUP_DIR}/XDCnode-docker.settings.backup-${NETWORK}-docker-compose.yml_${TS}"
  cp "$CHAIN_DIR/docker-compose.yml" "$COMPOSE_DEST"
  chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$COMPOSE_DEST" 2>/dev/null || true
  success "docker-compose.yml ($NETWORK) → $COMPOSE_DEST"
else
  warn "No docker-compose.yml found at $CHAIN_DIR/docker-compose.yml"
fi

success "Backup complete."
echo
echo "Files are in: $BACKUP_DIR"
ls -1 "$BACKUP_DIR"/XDCnode-*.backup-* 2>/dev/null | tail -n 10 || true
