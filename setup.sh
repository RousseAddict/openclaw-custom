#!/usr/bin/env bash
set -euo pipefail

# ── Colours & helpers ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}[info]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ok]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[error]${NC} %s\n" "$*" >&2; }

# Helper: show current value hint (masked for secrets)
hint() {
  local val="$1"
  if [ -n "$val" ]; then
    local masked="${val:0:4}...${val: -4}"
    printf " [current: %s]" "$masked"
  fi
}

# ── Detect runtime: --colima flag or auto-detect ───────────────────
RUNTIME="docker"
COLIMA_SOCKET=""
DOCKER_SOCKET="/var/run/docker.sock"

for arg in "$@"; do
  case "$arg" in
    --colima) RUNTIME="colima" ;;
    --docker) RUNTIME="docker" ;;
  esac
done

# Auto-detect: if colima is installed and Docker Desktop isn't running
if [ "$RUNTIME" = "docker" ] && command -v colima >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    info "Docker not reachable — switching to Colima mode."
    RUNTIME="colima"
  fi
fi

# ── Paths ──────────────────────────────────────────────────────────
OPENCLAW_DIR="${HOME}/.openclaw"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Load existing .env if present ─────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  set +e
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set -e
  info "Loaded existing .env — press Enter to keep current values."
fi

# ══════════════════════════════════════════════════════════════════
#  COLIMA: VM management
# ══════════════════════════════════════════════════════════════════
if [ "$RUNTIME" = "colima" ]; then
  COLIMA_PROFILE="${COLIMA_PROFILE:-openclaw}"
  COLIMA_CPU="${COLIMA_CPU:-2}"
  COLIMA_MEMORY="${COLIMA_MEMORY:-4}"
  COLIMA_DISK="${COLIMA_DISK:-30}"

  command -v colima >/dev/null 2>&1 || {
    err "Colima is not installed."
    info "Install with: brew install colima"
    exit 1
  }

  command -v docker >/dev/null 2>&1 || {
    err "Docker CLI is not installed."
    info "Install with: brew install docker docker-compose"
    exit 1
  }

  docker compose version >/dev/null 2>&1 || {
    err "Docker Compose v2 is required."
    info "Install with: brew install docker-compose"
    exit 1
  }

  # Start or verify Colima VM
  if colima status -p "$COLIMA_PROFILE" >/dev/null 2>&1; then
    ok "Colima profile '${COLIMA_PROFILE}' is already running."
  else
    info "Starting Colima profile '${COLIMA_PROFILE}' (${COLIMA_CPU} CPU, ${COLIMA_MEMORY} GB RAM, ${COLIMA_DISK} GB disk)..."
    colima start \
      --profile "$COLIMA_PROFILE" \
      --cpu "$COLIMA_CPU" \
      --memory "$COLIMA_MEMORY" \
      --disk "$COLIMA_DISK" \
      --mount-type virtiofs
    ok "Colima VM started."
  fi

  # Resolve Docker socket
  if [ "$COLIMA_PROFILE" = "default" ]; then
    COLIMA_SOCKET="${HOME}/.colima/default/docker.sock"
  else
    COLIMA_SOCKET="${HOME}/.colima/${COLIMA_PROFILE}/docker.sock"
  fi

  if [ ! -S "$COLIMA_SOCKET" ]; then
    err "Colima socket not found at ${COLIMA_SOCKET}"
    info "Try: colima status -p ${COLIMA_PROFILE}"
    exit 1
  fi

  export DOCKER_HOST="unix://${COLIMA_SOCKET}"
  DOCKER_SOCKET="$COLIMA_SOCKET"
  ok "Using Docker socket: ${COLIMA_SOCKET}"

  # Verify Docker is responsive
  if ! docker info >/dev/null 2>&1; then
    err "Cannot connect to Docker via Colima socket."
    info "Try restarting: colima restart -p ${COLIMA_PROFILE}"
    exit 1
  fi

# ══════════════════════════════════════════════════════════════════
#  DOCKER DESKTOP: standard checks
# ══════════════════════════════════════════════════════════════════
else
  command -v docker >/dev/null 2>&1 || { err "Docker is not installed."; exit 1; }
  docker compose version >/dev/null 2>&1 || { err "Docker Compose v2 is required."; exit 1; }
fi

# ── Memory check (shared) ─────────────────────────────────────────
MEM_MB=$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%.0f", $1/1048576}')
if [ -n "$MEM_MB" ] && [ "$MEM_MB" -lt 2048 ] 2>/dev/null; then
  warn "Docker has ${MEM_MB} MB RAM — builds need at least 2 GB (OOM risk)."
fi

# ── Configuration ──────────────────────────────────────────────────
mkdir -p "${OPENCLAW_DIR}/workspace"

# Copy default config if not present
if [ ! -f "${OPENCLAW_DIR}/openclaw.json" ] && [ -f "${SCRIPT_DIR}/openclaw.json" ]; then
  cp "${SCRIPT_DIR}/openclaw.json" "${OPENCLAW_DIR}/openclaw.json"
  ok "Copied default openclaw.json to ${OPENCLAW_DIR}/"
fi

# ══════════════════════════════════════════════════════════════════
#  ONBOARDING WIZARD
# ══════════════════════════════════════════════════════════════════
if [ "$RUNTIME" = "colima" ]; then
  info "OpenClaw Setup (Colima)"
else
  info "OpenClaw Setup (Docker)"
fi
echo ""

# Gateway bind mode
printf "Gateway bind mode [loopback/lan/auto] (default: ${OPENCLAW_GATEWAY_BIND:-loopback}): "
read -r INPUT
BIND_MODE="${INPUT:-${OPENCLAW_GATEWAY_BIND:-loopback}}"

# Sandbox
PREV_SANDBOX="${OPENCLAW_SANDBOX:-}"
if [ -n "$PREV_SANDBOX" ]; then
  printf "Enable sandbox? [y/N] (current: yes): "
else
  printf "Enable sandbox? [y/N]: "
fi
read -r ENABLE_SANDBOX
case "$ENABLE_SANDBOX" in
  [yY]|[yY][eE][sS]) SANDBOX="1" ;;
  "") SANDBOX="${PREV_SANDBOX}" ;;
  *) SANDBOX="" ;;
esac

# OpenRouter API key
printf "OpenRouter API key$(hint "${OPENROUTER_API_KEY:-}"): "
read -r INPUT
OPENROUTER_KEY="${INPUT:-${OPENROUTER_API_KEY:-}}"

# ── Channel setup ─────────────────────────────────────────────────
echo ""
info "Channel setup — select which messaging platforms to enable."
info "You can enable multiple channels. Press Enter to keep existing values."
echo ""

# -- Discord --
PREV_DISCORD="${DISCORD_BOT_TOKEN:-}"
PREV_DISCORD_SID="${DISCORD_SERVER_ID:-}"
PREV_DISCORD_UID="${DISCORD_USER_ID:-}"

if [ -n "$PREV_DISCORD" ]; then
  printf "Enable Discord? [Y/n] (currently enabled): "
else
  printf "Enable Discord? [y/N]: "
fi
read -r ENABLE_DISCORD

DISCORD_TOKEN="$PREV_DISCORD"
DISCORD_SID="$PREV_DISCORD_SID"
DISCORD_UID="$PREV_DISCORD_UID"

if [ -n "$PREV_DISCORD" ]; then
  if [[ "$ENABLE_DISCORD" =~ ^[nN] ]]; then
    DISCORD_TOKEN=""
    DISCORD_SID=""
    DISCORD_UID=""
  else
    printf "  Discord bot token$(hint "$PREV_DISCORD"): "
    read -r INPUT
    DISCORD_TOKEN="${INPUT:-$PREV_DISCORD}"
    printf "  Server (guild) ID$(hint "$PREV_DISCORD_SID"): "
    read -r INPUT
    DISCORD_SID="${INPUT:-$PREV_DISCORD_SID}"
    printf "  Your user ID$(hint "$PREV_DISCORD_UID"): "
    read -r INPUT
    DISCORD_UID="${INPUT:-$PREV_DISCORD_UID}"
    ok "Discord configured."
    echo ""
  fi
elif [[ "$ENABLE_DISCORD" =~ ^[yY] ]]; then
  info "Create a bot at https://discord.com/developers/applications"
  info "Required intents: Message Content, Server Members"
  printf "  Discord bot token: "
  read -r DISCORD_TOKEN
  printf "  Server (guild) ID (right-click server → Copy ID): "
  read -r DISCORD_SID
  printf "  Your user ID (right-click avatar → Copy ID): "
  read -r DISCORD_UID
  ok "Discord configured."
  echo ""
fi

# -- Telegram --
PREV_TELEGRAM="${TELEGRAM_BOT_TOKEN:-}"

if [ -n "$PREV_TELEGRAM" ]; then
  printf "Enable Telegram? [Y/n] (currently enabled): "
else
  printf "Enable Telegram? [y/N]: "
fi
read -r ENABLE_TELEGRAM

TELEGRAM_TOKEN="$PREV_TELEGRAM"

if [ -n "$PREV_TELEGRAM" ]; then
  if [[ "$ENABLE_TELEGRAM" =~ ^[nN] ]]; then
    TELEGRAM_TOKEN=""
  else
    printf "  Telegram bot token$(hint "$PREV_TELEGRAM"): "
    read -r INPUT
    TELEGRAM_TOKEN="${INPUT:-$PREV_TELEGRAM}"
    ok "Telegram configured."
    echo ""
  fi
elif [[ "$ENABLE_TELEGRAM" =~ ^[yY] ]]; then
  info "Create a bot via @BotFather on Telegram"
  printf "  Telegram bot token: "
  read -r TELEGRAM_TOKEN
  ok "Telegram configured."
  echo ""
fi

# -- Slack --
PREV_SLACK_APP="${SLACK_APP_TOKEN:-}"
PREV_SLACK_BOT="${SLACK_BOT_TOKEN:-}"

if [ -n "$PREV_SLACK_APP" ]; then
  printf "Enable Slack? [Y/n] (currently enabled): "
else
  printf "Enable Slack? [y/N]: "
fi
read -r ENABLE_SLACK

SLACK_APP="$PREV_SLACK_APP"
SLACK_BOT="$PREV_SLACK_BOT"

if [ -n "$PREV_SLACK_APP" ]; then
  if [[ "$ENABLE_SLACK" =~ ^[nN] ]]; then
    SLACK_APP=""
    SLACK_BOT=""
  else
    printf "  Slack app token$(hint "$PREV_SLACK_APP"): "
    read -r INPUT
    SLACK_APP="${INPUT:-$PREV_SLACK_APP}"
    printf "  Slack bot token$(hint "$PREV_SLACK_BOT"): "
    read -r INPUT
    SLACK_BOT="${INPUT:-$PREV_SLACK_BOT}"
    ok "Slack configured."
    echo ""
  fi
elif [[ "$ENABLE_SLACK" =~ ^[yY] ]]; then
  info "Create a Slack app at https://api.slack.com/apps"
  info "Enable Socket Mode and grab both tokens."
  printf "  Slack app token (xapp-...): "
  read -r SLACK_APP
  printf "  Slack bot token (xoxb-...): "
  read -r SLACK_BOT
  ok "Slack configured."
  echo ""
fi

# -- WhatsApp --
ENABLE_WA=""
printf "Enable WhatsApp? [y/N]: "
read -r ENABLE_WA_INPUT
if [[ "$ENABLE_WA_INPUT" =~ ^[yY] ]]; then
  ENABLE_WA="1"
  info "WhatsApp uses QR pairing — run after startup:"
  info "  docker exec -it openclaw-gateway openclaw channels login --channel whatsapp"
  ok "WhatsApp will be enabled."
  echo ""
fi

# -- Browser --
INSTALL_BROWSER=""
printf "Install Chromium browser for web browsing? [y/N]: "
read -r ENABLE_BROWSER
if [[ "$ENABLE_BROWSER" =~ ^[yY] ]]; then
  INSTALL_BROWSER="1"
  info "Chromium will be installed after the gateway starts."
  echo ""
fi

# Image source
PREV_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
printf "Docker image [${PREV_IMAGE}] (or 'build' to build locally): "
read -r IMAGE_CHOICE
if [ "$IMAGE_CHOICE" = "build" ]; then
  REMOTE_IMAGE=""
else
  REMOTE_IMAGE="${IMAGE_CHOICE:-$PREV_IMAGE}"
fi

# ══════════════════════════════════════════════════════════════════
#  GENERATE CONFIG
# ══════════════════════════════════════════════════════════════════

# ── Generate or keep gateway token ─────────────────────────────────
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  ok "Keeping existing gateway token."
else
  GATEWAY_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ok "Generated new gateway token."
fi

# ── Write .env ─────────────────────────────────────────────────────
ENV_HEADER="# Generated by setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Colima-specific env vars
COLIMA_ENV=""
if [ "$RUNTIME" = "colima" ]; then
  COLIMA_ENV="# Colima profile: ${COLIMA_PROFILE}
DOCKER_HOST=unix://${COLIMA_SOCKET}"
fi

cat > "$ENV_FILE" <<EOF
${ENV_HEADER}
${COLIMA_ENV}
GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=${BIND_MODE}
OPENCLAW_SANDBOX=${SANDBOX}
OPENCLAW_IMAGE=${REMOTE_IMAGE:-openclaw:local}

# Provider
OPENROUTER_API_KEY=${OPENROUTER_KEY}

# Channels
DISCORD_BOT_TOKEN=${DISCORD_TOKEN}
DISCORD_SERVER_ID=${DISCORD_SID}
DISCORD_USER_ID=${DISCORD_UID}
TELEGRAM_BOT_TOKEN=${TELEGRAM_TOKEN}
SLACK_APP_TOKEN=${SLACK_APP}
SLACK_BOT_TOKEN=${SLACK_BOT}

# Docker
OPENCLAW_EXTENSIONS=
OPENCLAW_DOCKER_APT_PACKAGES=
OPENCLAW_DOCKER_SOCKET=${DOCKER_SOCKET}
OPENCLAW_EXTRA_MOUNTS=
OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=
EOF

ok "Configuration written to ${ENV_FILE}"

# ── Generate openclaw.json with only enabled channels ──────────────
CONFIG_FILE="${OPENCLAW_DIR}/openclaw.json"

CHANNELS_JSON=""

if [ -n "$DISCORD_TOKEN" ]; then
  GUILD_BLOCK="{}"
  if [ -n "$DISCORD_SID" ] && [ -n "$DISCORD_UID" ]; then
    GUILD_BLOCK="{ \"${DISCORD_SID}\": { \"requireMention\": true, \"users\": [\"${DISCORD_UID}\"] } }"
  fi
  CHANNELS_JSON="${CHANNELS_JSON}    discord: {
      enabled: true,
      token: \"\${DISCORD_BOT_TOKEN}\",
      dmPolicy: \"pairing\",
      groupPolicy: \"allowlist\",
      guilds: ${GUILD_BLOCK}
    },
"
fi

if [ -n "$TELEGRAM_TOKEN" ]; then
  CHANNELS_JSON="${CHANNELS_JSON}    telegram: {
      enabled: true,
      botToken: \"\${TELEGRAM_BOT_TOKEN}\",
      dmPolicy: \"pairing\"
    },
"
fi

if [ -n "$SLACK_APP" ]; then
  CHANNELS_JSON="${CHANNELS_JSON}    slack: {
      enabled: true,
      mode: \"socket\",
      appToken: \"\${SLACK_APP_TOKEN}\",
      botToken: \"\${SLACK_BOT_TOKEN}\"
    },
"
fi

if [ -n "$ENABLE_WA" ]; then
  CHANNELS_JSON="${CHANNELS_JSON}    whatsapp: {
      enabled: true,
      dmPolicy: \"pairing\"
    },
"
fi

cat > "$CONFIG_FILE" <<JSONEOF
{
  // OpenClaw configuration — JSON5 format
  // Docs: https://docs.openclaw.ai/gateway/configuration

  agents: {
    list: [
      {
        id: "main",
        default: true,
        model: "openrouter/nvidia/nemotron-3-super-120b-a12b:free",
        workspace: "~/.openclaw/workspace"
      }
    ],
    defaults: {
      model: {
        primary: "openrouter/nvidia/nemotron-3-super-120b-a12b:free",
        fallbacks: ["openrouter/openrouter/free"]
      },
      models: {
        "openrouter/nvidia/nemotron-3-super-120b-a12b:free": { alias: "Nemotron 120B" },
        "openrouter/nvidia/nemotron-3-nano-30b-a3b:free": { alias: "Nemotron 30B" },
        "openrouter/stepfun/step-3.5-flash:free": { alias: "Step Flash" },
        "openrouter/minimax/minimax-m2.5:free": { alias: "MiniMax M2.5" },
        "openrouter/openrouter/free": { alias: "Auto Free" }
      }
    }
  },

  models: {
    providers: {
      openrouter: {
        baseUrl: "https://openrouter.ai/api/v1",
        apiKey: "\${OPENROUTER_API_KEY}",
        models: []
      }
    }
  },

  browser: {
    enabled: ${INSTALL_BROWSER:+true}${INSTALL_BROWSER:-false},
    headless: true,
    noSandbox: true
  },

  channels: {
${CHANNELS_JSON}  }
}
JSONEOF

ok "Generated openclaw.json with enabled channels only."

# ══════════════════════════════════════════════════════════════════
#  BUILD / PULL / START
# ══════════════════════════════════════════════════════════════════

if [ -n "$REMOTE_IMAGE" ]; then
  info "Pulling image: ${REMOTE_IMAGE}"
  docker pull "$REMOTE_IMAGE"
else
  info "Building image locally (this may take a while)..."
  docker compose -f docker-compose.yml -f docker-compose.build.yml --env-file "$ENV_FILE" build
fi

ok "Image ready."

info "Starting OpenClaw gateway..."
if [ -n "$REMOTE_IMAGE" ]; then
  docker compose --env-file "$ENV_FILE" up -d
else
  docker compose -f docker-compose.yml -f docker-compose.build.yml --env-file "$ENV_FILE" up -d
fi

# ── Install Chromium if requested ──────────────────────────────────
if [ -n "$INSTALL_BROWSER" ]; then
  info "Installing Chromium inside the container (this may take a minute)..."
  docker exec openclaw-gateway npx playwright install --with-deps chromium 2>/dev/null || \
    docker exec -u root openclaw-gateway bash -c "apt-get update && apt-get install -y --no-install-recommends chromium" 2>/dev/null || \
    warn "Chromium auto-install failed. Run manually: ./openclaw.sh install-browser"
  ok "Chromium installed."
fi

# ══════════════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════════════
echo ""
if [ "$RUNTIME" = "colima" ]; then
  ok "OpenClaw is running! (via Colima profile '${COLIMA_PROFILE}')"
else
  ok "OpenClaw is running!"
fi
echo ""
info "Open http://127.0.0.1:18789/ in your browser."
info "Paste this token in the Control UI (Settings → Token):"
echo ""
printf "  ${GREEN}%s${NC}\n" "$GATEWAY_TOKEN"
echo ""

# Post-setup hints
if [ -n "$DISCORD_TOKEN" ]; then
  info "Discord: DM your bot to start pairing."
fi
if [ -n "$TELEGRAM_TOKEN" ]; then
  info "Telegram: Message your bot to start pairing."
fi
if [ -n "$SLACK_APP" ]; then
  info "Slack: Invite the bot to a channel, then mention it."
fi
if [ -n "$ENABLE_WA" ]; then
  info "WhatsApp: Run this to pair via QR code:"
  info "  docker exec -it openclaw-gateway openclaw channels login --channel whatsapp"
fi

if [ "$RUNTIME" = "colima" ]; then
  echo ""
  info "Useful Colima commands:"
  info "  colima status -p ${COLIMA_PROFILE}    # check VM status"
  info "  colima stop -p ${COLIMA_PROFILE}      # stop VM"
  info "  colima delete -p ${COLIMA_PROFILE}    # remove VM"
fi
echo ""
