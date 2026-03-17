#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Load .env ──────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
  echo "No .env found. Run ./docker-setup.sh or ./colima-setup.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Set DOCKER_HOST if present in .env (Colima)
if [ -n "${DOCKER_HOST:-}" ]; then
  export DOCKER_HOST
fi

# ── Commands ───────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: ./openclaw.sh <command>

Commands:
  start             Start the gateway
  stop              Stop the gateway
  restart           Restart the gateway
  logs              Tail live logs
  status            Show container status
  token             Show the gateway token
  shell             Open a shell in the container
  pull              Pull the latest image
  update            Pull latest image and restart
  install-browser   Install Chromium inside the container
EOF
}

case "${1:-}" in
  start)
    docker compose --env-file "$ENV_FILE" up -d
    echo "Gateway started at http://127.0.0.1:18789/"
    ;;
  stop)
    docker compose --env-file "$ENV_FILE" down
    ;;
  restart)
    docker compose --env-file "$ENV_FILE" up -d --force-recreate
    echo "Gateway restarted at http://127.0.0.1:18789/"
    ;;
  logs)
    docker compose --env-file "$ENV_FILE" logs -f --tail "${2:-100}"
    ;;
  status)
    docker compose --env-file "$ENV_FILE" ps
    ;;
  token)
    echo "${GATEWAY_TOKEN:-not set}"
    ;;
  shell)
    docker exec -it openclaw-gateway /bin/bash
    ;;
  pull)
    docker compose --env-file "$ENV_FILE" pull
    ;;
  update)
    docker compose --env-file "$ENV_FILE" pull
    docker compose --env-file "$ENV_FILE" up -d --force-recreate
    echo "Gateway updated and restarted."
    ;;
  install-browser)
    echo "Installing Chromium inside the container..."
    docker exec openclaw-gateway npx playwright install --with-deps chromium 2>/dev/null || \
      docker exec -u root openclaw-gateway bash -c "apt-get update && apt-get install -y --no-install-recommends chromium" 2>/dev/null || \
      { echo "Auto-install failed. Try: ./openclaw.sh shell, then install manually." >&2; exit 1; }
    echo "Chromium installed. Browser tools are now available."
    ;;
  *)
    usage
    ;;
esac
