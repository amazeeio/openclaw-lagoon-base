# Stage 1: Install OpenClaw (skip native builds for API-based usage)
FROM node:22-bookworm AS builder

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

ARG OPENCLAW_VERSION=a
RUN npm install -g --ignore-scripts openclaw@${OPENCLAW_VERSION}
RUN openclaw --version

# Stage 2: Runtime image
FROM node:22-bookworm-slim

RUN npm install -g pnpm

COPY --from=builder /usr/local/lib/node_modules/openclaw /usr/local/lib/node_modules/openclaw
RUN set -eu; \
    pkg_dir=/usr/local/lib/node_modules/openclaw; \
    find "$pkg_dir/dist/extensions" -mindepth 2 -maxdepth 2 -type d -name node_modules | while read -r node_modules_dir; do \
            find "$node_modules_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | while read -r entry; do \
                entry_name=$(basename "$entry"); \
                if [ "$entry_name" = .bin ]; then \
                    continue; \
                fi; \
                if [ "${entry_name#@}" != "$entry_name" ]; then \
                    mkdir -p "$pkg_dir/node_modules/$entry_name"; \
                    find "$entry" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | while read -r scoped_entry; do \
                        ln -sfn "$scoped_entry" "$pkg_dir/node_modules/$entry_name/$(basename "$scoped_entry")"; \
                    done; \
                else \
                    ln -sfn "$entry" "$pkg_dir/node_modules/$entry_name"; \
                fi; \
            done; \
        done
RUN ln -s /usr/local/lib/node_modules/openclaw/openclaw.mjs /usr/local/bin/openclaw
RUN openclaw --version

ARG EXTRA_APT_PACKAGES=""
RUN apt-get update && apt-get install -y \
    tini \
    git \
    bash \
    curl \
    nano \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    procps \
    $EXTRA_APT_PACKAGES \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /bin/bash /bin/sh

RUN groupadd --gid 10000 openclaw && \
    useradd --uid 10000 --gid 0 --groups openclaw --home-dir /home --shell /bin/bash --no-create-home openclaw

RUN mkdir -p /lagoon/entrypoints /lagoon/bin /home

COPY .lagoon/fix-permissions /bin/fix-permissions
COPY .lagoon/entrypoints.sh /lagoon/entrypoints.sh
COPY .lagoon/bashrc /home/.bashrc
COPY .lagoon/amazeeai-bootstrap /lagoon/amazeeai-bootstrap
COPY .lagoon/amazeeai-skills /lagoon/amazeeai-skills
COPY .lagoon/polydock_claim.sh /lagoon/polydock_claim.sh
COPY .lagoon/polydock_post_deploy.sh /lagoon/polydock_post_deploy.sh

RUN chmod +x /bin/fix-permissions /lagoon/entrypoints.sh /lagoon/polydock_claim.sh /lagoon/polydock_post_deploy.sh && \
    fix-permissions /home

COPY .lagoon/05-ssh-key.sh /lagoon/entrypoints/05-ssh-key.sh
COPY .lagoon/50-shell-config.sh /lagoon/entrypoints/50-shell-config.sh
COPY .lagoon/60-amazeeai-config.sh /lagoon/entrypoints/60-amazeeai-config.sh
COPY .lagoon/ssh_config /etc/ssh/ssh_config

RUN mkdir -p /home/.openclaw /home/.openclaw/npm \
    && fix-permissions /home/.openclaw

ENV NODE_ENV=production \
    HOME=/home \
    OPENCLAW_GATEWAY_PORT=3000 \
    OPENCLAW_NO_RESPAWN=1 \
    XDG_DATA_HOME=/home/.openclaw/.local/share/ \
    PNPM_HOME=/home/.openclaw/.local/share/pnpm \
    npm_config_cache=/tmp/.npm \
    npm_config_prefix=/home/.openclaw/npm \
    NODE_COMPILE_CACHE=/tmp/openclaw-compile-cache \
    PATH="/home/.openclaw/bin:/home/.openclaw/npm/bin:/home/.openclaw/.local/share/pnpm:$PATH" \
    LAGOON=openclaw \
    TMPDIR=/tmp \
    TMP=/tmp \
    BASH_ENV=/home/.bashrc

WORKDIR /home/.openclaw
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--", "/lagoon/entrypoints.sh"]
CMD ["openclaw", "gateway", "--bind", "lan"]
