ARG OPENCLAW_VERSION=2026.7.1-2
ARG RELEASE_VERSION=2026.7.1-2

# Stage 1: Get Lagoon commons tools
# uselagoon/commons:26.5.1
FROM uselagoon/commons@sha256:e5a1592d38c60f31db28a50974bfc69d785ecf642da62d98322c2edc587edec5 AS commons

# Stage 2: Build the runtime image from the official OpenClaw image
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}-browser

# Switch to root to perform setup and package installation
USER root

# Install Lagoon fix-permissions tool from commons
COPY --from=commons /bin/fix-permissions /bin/fix-permissions

ARG EXTRA_APT_PACKAGES=""
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    git \
    bash \
    curl \
    nano \
    vim-tiny \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    procps \
    sqlite3 \
    $EXTRA_APT_PACKAGES \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /bin/bash /bin/sh

RUN if ! getent group openclaw >/dev/null 2>&1; then \
      groupadd --gid 10000 openclaw; \
    fi && \
    if ! getent passwd openclaw >/dev/null 2>&1; then \
      useradd --uid 10000 --gid 0 --groups openclaw --home-dir /home --shell /bin/bash --no-create-home openclaw; \
    fi

RUN mkdir -p /lagoon/entrypoints /lagoon/bin /home
COPY .lagoon/entrypoints.sh /lagoon/entrypoints.sh
COPY .lagoon/bashrc /home/.bashrc
COPY .lagoon/profile /home/.profile
COPY .lagoon/amazeeai-bootstrap /lagoon/amazeeai-bootstrap
COPY .lagoon/amazeeai-skills /lagoon/amazeeai-skills
COPY .lagoon/polydock_claim.sh /lagoon/polydock_claim.sh
COPY .lagoon/polydock_post_deploy.sh /lagoon/polydock_post_deploy.sh
COPY .lagoon/fix-claw-permissions /bin/fix-claw-permissions

RUN chmod +x /bin/fix-permissions /bin/fix-claw-permissions /lagoon/entrypoints.sh /lagoon/polydock_claim.sh /lagoon/polydock_post_deploy.sh && \
    fix-permissions /home

COPY .lagoon/05-ssh-key.sh /lagoon/entrypoints/05-ssh-key.sh
COPY .lagoon/10-passwd.sh /lagoon/entrypoints/10-passwd.sh
COPY .lagoon/50-shell-config.sh /lagoon/entrypoints/50-shell-config.sh
COPY .lagoon/amazeeai-model-refresher.js /lagoon/amazeeai-model-refresher.js
COPY .lagoon/openclaw-patch.js /lagoon/openclaw-patch.js
COPY .lagoon/60-amazeeai-config.sh /lagoon/entrypoints/60-amazeeai-config.sh
COPY .lagoon/ssh_config /etc/ssh/ssh_config

RUN mkdir -p /home/.openclaw /home/.openclaw/npm \
    && fix-claw-permissions /home/.openclaw

ENV NODE_ENV=production \
    NODE_OPTIONS="--require /lagoon/openclaw-patch.js --max-old-space-size=3072" \
    HOME=/home \
    OPENCLAW_GATEWAY_PORT=3000 \
    OPENCLAW_NO_RESPAWN=1 \
    OPENCLAW_NO_AUTO_UPDATE=1 \
    XDG_DATA_HOME=/home/.openclaw/.local/share/ \
    PNPM_HOME=/home/.openclaw/.local/share/pnpm \
    npm_config_cache=/tmp/.npm \
    npm_config_prefix=/home/.openclaw/npm \
    NODE_COMPILE_CACHE=/tmp/openclaw-compile-cache \
    PATH="/home/.openclaw/bin:/home/.openclaw/npm/bin:/home/.openclaw/.local/share/pnpm:$PATH" \
    LAGOON=openclaw \
    TMPDIR=/tmp \
    TMP=/tmp \
    BASH_ENV=/home/.bashrc \
    ENV=/home/.profile

# Pre-install the default channel plugins at build time into an image-baked seed
# dir that lives OUTSIDE the runtime state volume (/home/.openclaw is a mounted
# persistent volume at runtime, so anything installed there during build is
# hidden). The entrypoint copies this seed onto the volume on boot, so instances
# get channel plugins without running `openclaw plugins install` (npm over the NFS
# volume) at runtime -- that install storm is what stalled rollouts. Plugin
# project dir names are a deterministic hash of the package name, so the seeded
# paths match exactly what the gateway looks for. We keep only the npm/ tree (the
# gateway rebuilds install records from a filesystem scan at startup) and drop the
# build-time state/config so no stale config is seeded.
ENV OPENCLAW_SEED_DIR=/lagoon/seed-openclaw
ARG DEFAULT_PLUGINS="@openclaw/slack @openclaw/discord @openclaw/whatsapp @openclaw/msteams @openclaw/googlechat"
# `openclaw plugins install` takes ONE package per invocation, so loop. Refresh
# the registry first so version resolution against the fresh seed state dir works.
# set -e makes any plugin install failure fail the build, so a shipped image
# always has the complete default plugin set (no silent partial seed).
RUN set -eu; \
    export OPENCLAW_STATE_DIR="$OPENCLAW_SEED_DIR" HOME="$OPENCLAW_SEED_DIR"; \
    mkdir -p "$OPENCLAW_SEED_DIR"; \
    openclaw plugins registry --refresh || true; \
    for pkg in $DEFAULT_PLUGINS; do \
      echo "[seed] installing $pkg"; \
      openclaw plugins install "$pkg"; \
    done; \
    rm -rf "$OPENCLAW_SEED_DIR/state" "$OPENCLAW_SEED_DIR/logs" "$OPENCLAW_SEED_DIR"/*.json; \
    chmod -R a+rX "$OPENCLAW_SEED_DIR/npm"

RUN chown -R openclaw:openclaw /home/.openclaw && \
    fix-claw-permissions /home/.openclaw

WORKDIR /home/.openclaw
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--", "/lagoon/entrypoints.sh"]
CMD ["openclaw", "gateway", "--bind", "lan"]
