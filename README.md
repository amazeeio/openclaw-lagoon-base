# openclaw-lagoon-base

This repository owns the reusable OpenClaw runtime image for Lagoon deployments. It builds the base container once and publishes it to GHCR so downstream Lagoon projects can pull the image instead of copying this entire repository and rebuilding the same stack.

## Published image

The image is published to:

- `ghcr.io/amazeeio/openclaw-lagoon-base:latest`
- `ghcr.io/amazeeio/openclaw-lagoon-base:main`
- `ghcr.io/amazeeio/openclaw-lagoon-base:<git-tag>` for version tags such as `v2026.3.8`
- `ghcr.io/amazeeio/openclaw-lagoon-base:<git-tag>` for base-only image revisions such as `v2026.4.2_2`

`latest` is the floating consumer tag. `main` is the integration tag. Version tags are the rollback-safe option.

## What lives here

This repo is the source of truth for:

- The multi-stage Docker build for OpenClaw
- The OpenClaw runtime dependencies and OS packages
- Lagoon entrypoint orchestration
- SSH key bootstrap for Git access
- amazee.ai model discovery and runtime config generation
- Shell prompt configuration and dashboard URL helpers
- Bundled runtime customizations copied into OpenClaw bootstrap and managed skill locations

Downstream repos should not duplicate these files.

## Publish flow

A GitHub Actions workflow at `.github/workflows/publish.yml` builds and publishes the image to GHCR on every push to `main`, and also on version tags matching `v*`.

The workflow uses the repository `GITHUB_TOKEN` to publish to GHCR. After the first publish, set the package visibility to public in GitHub Packages if it is not already public.

## Updating OpenClaw

This repository includes a helper script for bumping the packaged OpenClaw version and creating the matching git tag that drives tagged image builds.

```bash
./scripts/release-openclaw.sh
```

That command resolves the latest published `openclaw` npm version, updates `ARG OPENCLAW_VERSION` in `Dockerfile`, writes the matching image release version to `RELEASE_VERSION`, creates a commit, and creates an annotated git tag in the format `v<release-version>`.

`Dockerfile` remains the source of truth for the packaged OpenClaw version. `RELEASE_VERSION` is the source of truth for the published image release tag.

To pin a specific version:

```bash
./scripts/release-openclaw.sh 2026.3.8
```

To publish a base-image-only revision without changing the packaged OpenClaw version:

```bash
./scripts/release-openclaw.sh --base-revision 2
```

That produces a release tag such as `v2026.4.2_2`.

If OpenClaw itself later ships a prerelease such as `2026.4.2-1`, the second base-only revision would be released as `v2026.4.2-1_2`. The `_` separator is deliberate because it cannot appear in valid npm semver versions.

To also push the branch and tag to `origin`:

```bash
./scripts/release-openclaw.sh --push
```

## Automatic OpenClaw releases

This repository can also release itself automatically when a newer `openclaw`
npm package is published. The scheduled workflow at
`.github/workflows/release-openclaw.yml` runs four times per day and also
supports manual dispatch.

When it detects a newer OpenClaw version, it runs the same release helper,
commits the Dockerfile bump, updates `RELEASE_VERSION`, creates the matching annotated git tag, pushes both, and publishes the GHCR image in the same workflow run.

No extra repository secret is required for the scheduled release flow. It uses
the repository `GITHUB_TOKEN` to push the release commit and tag, and to publish
the image directly. This avoids relying on a second workflow trigger from the
automation-created push.

Repository-local agent guidance for this workflow is stored in `AGENTS.md`.

## Consumer usage

A downstream Lagoon repo can reference the published image directly in `docker-compose.yml`:

```yaml
services:
  openclaw-gateway:
    image: ghcr.io/amazeeio/openclaw-lagoon-base:latest
    user: "10000"
    env_file:
      - .env
    volumes:
      - ./.local:/home/.openclaw
    ports:
      - "3000:3000"
    labels:
      lagoon.type: node-persistent
      lagoon.persistent: /home/.openclaw
```

If a downstream project needs extra tooling, prefer a tiny derivative Dockerfile such as:

```dockerfile
FROM ghcr.io/amazeeio/openclaw-lagoon-base:latest

RUN apt-get update && apt-get install -y ripgrep && rm -rf /var/lib/apt/lists/*
```

If the downstream change is reusable across deployments, make it here instead.

## Local build

For local verification of the base image itself:

```bash
docker build -t openclaw-lagoon-base:dev .
docker run --rm -p 3000:3000 --env-file .env openclaw-lagoon-base:dev
```

## Runtime environment

The image expects the same environment variables currently used by OpenClaw Lagoon deployments, including:

- `AMAZEEAI_BASE_URL`
- `AMAZEEAI_API_KEY`
- `AMAZEEAI_DEFAULT_MODEL`
- `SSH_PRIVATE_KEY` when Git access is required
- `SLACK_APP_TOKEN` and `SLACK_BOT_TOKEN` for Slack integration

Runtime state is stored under `/home/.openclaw`.

## Bundled customizations

Files under `.lagoon/amazeeai-bootstrap/` are copied into the runtime workspace at boot with their relative paths preserved.

Files under `.lagoon/amazeeai-skills/` are copied into `~/.openclaw/skills/` at boot.

That means bundled OpenClaw customizations should be added there using the final runtime layout, for example:

- `amazee/AGENTS.md` for always-on workspace guidance
- `.lagoon/amazeeai-skills/<skill-name>/SKILL.md` for managed shared skills

OpenClaw documents `AGENTS.md`, `SOUL.md`, and `TOOLS.md` as injected prompt files, while shared managed skills live separately under `~/.openclaw/skills/<skill>/SKILL.md`.

This repository bundles the amazee AGENTS file and managed shared skills. Bootstrap prompt files and skills are copied by separate functions so `bootstrap-extra-files` only tracks injected prompt files such as `AGENTS.md`, `SOUL.md`, and `TOOLS.md`.
