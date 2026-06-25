ARG OPENCLAW_VERSION=2026.6.10
ARG RELEASE_VERSION=2026.6.10_2

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
COPY .lagoon/60-amazeeai-config.sh /lagoon/entrypoints/60-amazeeai-config.sh
COPY .lagoon/ssh_config /etc/ssh/ssh_config

RUN mkdir -p /home/.openclaw /home/.openclaw/npm \
    && fix-claw-permissions /home/.openclaw

ENV NODE_ENV=production \
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

RUN chown -R openclaw:openclaw /home/.openclaw && \
    fix-claw-permissions /home/.openclaw

WORKDIR /home/.openclaw
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--", "/lagoon/entrypoints.sh"]
CMD ["openclaw", "gateway", "--bind", "lan"]
