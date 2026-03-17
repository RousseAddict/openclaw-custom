# OpenClaw Docker Setup

Docker deployment for [OpenClaw](https://docs.openclaw.ai/) — an AI gateway that connects LLM agents to messaging platforms like Discord, Telegram, Slack, and WhatsApp.

## Quick Start

### Using Docker Desktop

```bash
./docker-setup.sh
```

### Using Colima (macOS, no Docker Desktop)

```bash
./colima-setup.sh
```

Both scripts walk you through an interactive wizard and start the gateway. Once running, open `http://127.0.0.1:18789/` and paste the gateway token shown in the terminal.

## What the Setup Wizard Asks

### Gateway bind mode

Controls which network interface the gateway listens on.

| Mode | Listens on | When to use |
|------|-----------|-------------|
| **loopback** (default) | `127.0.0.1` | Local-only access. Safest option. |
| **lan** | `0.0.0.0` | Access from other devices on your network. |
| **tailnet** | Tailscale IP | Restrict to your Tailscale VPN members. |
| **custom** | You specify | Reverse proxies or special network setups. |
| **auto** | Auto-detected | Picks the best mode automatically. |

For a personal setup accessed from the same machine, **loopback** is fine.

### Enable sandbox

Sandbox runs agent tools (shell commands, file access) inside isolated throwaway Docker containers instead of directly in the gateway.

**Without sandbox (default):** Tools run directly in the gateway container. Simpler, faster, full access.

**With sandbox:** Each tool call runs in a locked-down container with no network, read-only filesystem option, 1 GB RAM cap, and all Linux capabilities dropped. Idle containers are auto-cleaned after 24 hours.

**When you need it:** Multi-tenant or public-facing bots, untrusted agents, mixed trust levels.
**When you don't:** Personal use, trusted agents, simpler setup. You can always enable it later by setting `OPENCLAW_SANDBOX=1` in `.env`.

### Docker image

By default the wizard pulls the official pre-built image (`ghcr.io/openclaw/openclaw:latest`). This is the recommended option — fast and no compilation needed.

Type `build` instead if you need to compile from source (custom modifications, pinned builds).

The image is just the application; your configuration (`~/.openclaw/openclaw.json`) and data (`~/.openclaw/workspace`) are mounted as volumes and persist independently.

### OpenRouter API key

The default configuration uses [OpenRouter](https://openrouter.ai/) as the LLM provider with free models. Get an API key at [openrouter.ai/keys](https://openrouter.ai/keys).

You can skip this during setup and add it later in `.env`:
```bash
OPENROUTER_API_KEY=sk-or-v1-your-key-here
```

### Channel setup

The wizard lets you enable multiple messaging platforms. Each channel is independent — enable as many as you want.

**Discord** — Requires a bot token, server ID, and your user ID.
1. Create a bot at [discord.com/developers/applications](https://discord.com/developers/applications)
2. Enable **Message Content Intent** and **Server Members Intent** under Bot settings
3. Under OAuth2, select scopes `bot` + `applications.commands` with permissions: View Channels, Send Messages, Read Message History, Embed Links, Attach Files
4. Copy the invite URL, open it, and add the bot to your server
5. Enable Developer Mode in Discord (User Settings → Advanced), then right-click to copy your Server ID and User ID

**Telegram** — Requires a bot token from [@BotFather](https://t.me/BotFather).

**Slack** — Requires an app token (`xapp-...`) and bot token (`xoxb-...`). Create a Slack app at [api.slack.com/apps](https://api.slack.com/apps) with Socket Mode enabled.

**WhatsApp** — No token needed during setup. After the gateway starts, pair via QR code:
```bash
docker exec -it openclaw-gateway openclaw channels login --channel whatsapp
```

## Managing the Gateway

After setup, use `openclaw.sh` to manage the gateway. It automatically loads your `.env` (including `DOCKER_HOST` for Colima) so you don't need to export anything manually.

```bash
./openclaw.sh start       # start the gateway
./openclaw.sh stop        # stop the gateway
./openclaw.sh restart     # recreate and restart
./openclaw.sh logs        # tail live logs (last 100 lines)
./openclaw.sh logs 500    # tail with custom line count
./openclaw.sh status      # show container status
./openclaw.sh token       # print the gateway token
./openclaw.sh shell       # open a shell in the container
./openclaw.sh pull        # pull the latest image
./openclaw.sh update      # pull latest image + restart
```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build from `node:24-bookworm` |
| `docker-compose.yml` | Production service definition with security hardening |
| `docker-setup.sh` | Interactive setup for Docker Desktop |
| `colima-setup.sh` | Interactive setup for Colima (macOS) |
| `openclaw.json` | Default config — OpenRouter provider + free models + channel templates |
| `openclaw.sh` | Management script (start/stop/restart/logs/update) |
| `docker-compose.build.yml` | Build override for local compilation |

## Configuration

All runtime config lives in `~/.openclaw/openclaw.json` (JSON5 format). The setup wizard copies `openclaw.json` from this repo on first run.

Secrets live in `.env` (generated by the setup script, never committed):
```
GATEWAY_TOKEN=...
OPENROUTER_API_KEY=...
DISCORD_BOT_TOKEN=...
TELEGRAM_BOT_TOKEN=...
SLACK_APP_TOKEN=...
SLACK_BOT_TOKEN=...
```

### Models

The default config uses free OpenRouter models:

| Model | Alias |
|-------|-------|
| `nvidia/nemotron-3-super-120b-a12b:free` | Nemotron 120B (primary) |
| `nvidia/nemotron-3-nano-30b-a3b:free` | Nemotron 30B |
| `stepfun/step-3.5-flash:free` | Step Flash |
| `minimax/minimax-m2.5:free` | MiniMax M2.5 |
| `openrouter/free` | Auto Free (fallback) |

Switch models via the `/model` command in chat, or edit `openclaw.json`.

### Agents

Agents are defined in `openclaw.json` under `agents.list`. Each agent gets its own workspace, model, and session store:

```json5
{
  agents: {
    list: [
      { id: "main", default: true, model: "openrouter/nvidia/nemotron-3-super-120b-a12b:free" },
      { id: "creative", model: "openrouter/openrouter/free" }
    ]
  }
}
```

### Spending limits

OpenClaw does not have built-in per-agent spending caps. It provides usage monitoring (`/status`, `/usage full`), but enforcement must be done at the provider level — set limits on your API key in the OpenRouter or Anthropic dashboard.

## Colima-Specific Notes

The Colima script auto-starts a dedicated VM with sensible defaults (2 CPU, 4 GB RAM, 30 GB disk). Customize with environment variables:

```bash
COLIMA_CPU=4 COLIMA_MEMORY=8 ./colima-setup.sh
```

Useful commands:
```bash
colima status -p openclaw     # check VM status
colima stop -p openclaw       # stop VM
colima delete -p openclaw     # remove VM entirely
```

## Documentation

- [OpenClaw Docs](https://docs.openclaw.ai/)
- [Docker Install Guide](https://docs.openclaw.ai/install/docker)
- [Gateway Configuration](https://docs.openclaw.ai/gateway/configuration)
- [Multi-Agent Setup](https://docs.openclaw.ai/concepts/multi-agent)
- [Discord Channel Setup](https://docs.openclaw.ai/channels/discord)
