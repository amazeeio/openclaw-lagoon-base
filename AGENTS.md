# Repository Workflow

This repository owns the reusable OpenClaw Lagoon base image and its GHCR publishing flow.

When asked to update OpenClaw in this repository:

- Treat the Dockerfile ARG `OPENCLAW_VERSION` as the source of truth for the packaged OpenClaw version.
- Use `scripts/release-openclaw.sh` instead of manually editing the version when the task is a version bump or release.
- Default to discovering the latest published `openclaw` npm version automatically unless the user asks for a specific version.
- The expected git tag format is `v<openclaw-version>`, for example `v2026.3.8`.
- The release flow must create a commit that bumps the Dockerfile version, create an annotated git tag with the same version, and push both the branch and the tag when the user asks for a pushed release.
- Do not create ad hoc tag formats, and do not leave the Dockerfile version and git tag out of sync.

Release safety rules:

- Do not force-push.
- Do not create a release commit if the repository has unrelated uncommitted changes.
- Do not create a duplicate tag if `v<version>` already exists.
- After bumping, validate with `docker compose` or Docker-related checks only when relevant to the change.

Preferred commands:

- Dry run or local release preparation: `./scripts/release-openclaw.sh`
- Pin a specific version: `./scripts/release-openclaw.sh 2026.3.8`
- Commit, tag, and push: `./scripts/release-openclaw.sh --push`

Runtime control rule for this repository:

- When work in this repository requires an OpenClaw gateway restart, reload, reconnect, or configuration refresh, use the tool named `gateway` only.
- The required call for reload-style requests is the tool named `gateway` with the `restart` action.
- Do not use the `openclaw` CLI for runtime control, and do not use `kill`, `pkill`, `killall`, `SIGHUP`, `SIGTERM`, `SIGINT`, or `SIGKILL` against OpenClaw processes.
