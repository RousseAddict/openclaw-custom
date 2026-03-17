# ---------- base ----------
FROM node:24-bookworm AS base

ARG OPENCLAW_EXTENSIONS=""
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
ARG OPENCLAW_INSTALL_DOCKER_CLI=""
ARG OPENCLAW_SANDBOX=""

ENV NODE_ENV=production

# Install system packages requested at build time
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# Install Docker CLI when sandbox is enabled or explicitly requested
RUN if [ "$OPENCLAW_SANDBOX" = "1" ] || [ "$OPENCLAW_SANDBOX" = "true" ] || \
       [ "$OPENCLAW_SANDBOX" = "yes" ] || [ "$OPENCLAW_SANDBOX" = "on" ] || \
       [ -n "$OPENCLAW_INSTALL_DOCKER_CLI" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends ca-certificates curl gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
      apt-get update && \
      apt-get install -y --no-install-recommends docker-ce-cli && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# Install Bun (required for build scripts) and enable corepack for pnpm
RUN npm install -g bun && corepack enable

# ---------- deps ----------
FROM base AS deps

WORKDIR /app

# Copy dependency metadata first (layer caching)
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/ packages/

RUN pnpm install --frozen-lockfile

# ---------- build ----------
FROM deps AS build

WORKDIR /app

COPY . .

RUN pnpm build

# Build UI
WORKDIR /app/ui
RUN pnpm install --frozen-lockfile && pnpm build

# ---------- production ----------
FROM base AS production

WORKDIR /app

# Copy built application
COPY --from=build /app /app

# Install only production dependencies
RUN pnpm install --frozen-lockfile --prod

# Pre-install extensions if requested
RUN if [ -n "$OPENCLAW_EXTENSIONS" ]; then \
      for ext in $OPENCLAW_EXTENSIONS; do \
        pnpm add "$ext"; \
      done; \
    fi

# Run as non-root user
USER node

EXPOSE 18789

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:18789/healthz || exit 1

ENTRYPOINT ["node"]
CMD ["dist/gateway.js", "--allow-unconfigured"]

# OCI metadata
LABEL org.opencontainers.image.base.name="docker.io/library/node:24-bookworm" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.documentation="https://docs.openclaw.ai/install/docker" \
      org.opencontainers.image.source="https://github.com/openclaw/openclaw"
