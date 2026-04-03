# Repository Workflow

This repository owns the reusable OpenClaw Lagoon base image and its GHCR publishing flow.

When asked to update OpenClaw in this repository:

- Treat the Dockerfile ARG `OPENCLAW_VERSION` as the source of truth for the packaged OpenClaw version.
- Treat `RELEASE_VERSION` as the source of truth for the published image release tag.
- Use `scripts/release-openclaw.sh` instead of manually editing the version when the task is a version bump or release.
- Default to discovering the latest published `openclaw` npm version automatically unless the user asks for a specific version.
- The default git tag format is `v<openclaw-version>`, for example `v2026.3.8`.
- Base-only image rebuilds should use `v<openclaw-version>_b<n>`, for example `v2026.4.2_b2`.
- The release flow must create a commit, keep `Dockerfile` aligned to the packaged OpenClaw version, keep `RELEASE_VERSION` aligned to the published image tag, create an annotated git tag with the release version, and push both the branch and the tag when the user asks for a pushed release.
- Do not create ad hoc tag formats, and do not leave `RELEASE_VERSION` and the git tag out of sync.

Release safety rules:

- Do not force-push.
- Do not create a release commit if the repository has unrelated uncommitted changes.
- Do not create a duplicate tag if `v<version>` already exists.
- After bumping, validate with `docker compose` or Docker-related checks only when relevant to the change.

Preferred commands:

- Dry run or local release preparation: `./scripts/release-openclaw.sh`
- Pin a specific version: `./scripts/release-openclaw.sh 2026.3.8`
- Cut a base-only release: `./scripts/release-openclaw.sh --base-revision 2`
- Commit, tag, and push: `./scripts/release-openclaw.sh --push`

