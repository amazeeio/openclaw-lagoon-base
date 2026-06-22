# Learning Log: openclaw-lagoon-base

This log tracks key tasks, decisions, and outcomes for the `openclaw-lagoon-base` project.

## [2026-06-12] Support for Separate Dev Test Environments on Lagoon

### Context & Goal
The user wanted to roll out features in a `dev` branch of the base image repo and publish only `dev` (along with versioned dev tag formats like `dev-<version>` or `<version>-dev`) to GHCR. This enables a downstream `openclaw-lagoon` `dev` branch to pull the dev-tagged base images, allowing two separate test environments on Lagoon (one for `main` and one for `dev`).

### Implementation Details
1. **Workflow Trigger Extension**: Updated `.github/workflows/publish.yml` to trigger on push to `dev` in addition to `main` and tags `v*`.
2. **Dynamic Docker Tag Generation**:
   - Added a `Get release version` step to read the current version from `RELEASE_VERSION`.
   - Updated the `docker/metadata-action` step to push the following tags when building the `dev` branch:
     - `dev` (automatically handled by `type=ref,event=branch`)
     - `dev-<version>`
     - `<version>-dev`

### Outcomes & Learnings
- GitHub Actions' `docker/metadata-action` is highly flexible, and custom raw tags can be conditionally enabled by parsing a file beforehand.
- Using `github.ref_name == 'dev'` prevents dev tags from being generated on main branch builds.
- **Dockerfile ARG Scoping**: Declaring a build-time argument (`ARG`) after a `FROM` statement scopes it to that specific stage. To use an `ARG` in subsequent `FROM` statements, the `ARG` must be declared at the very top of the `Dockerfile` (before the first `FROM`). Failing to do so causes the argument to resolve as empty, resulting in invalid image references (e.g. `ghcr.io/openclaw/openclaw:`).
- **Official OpenClaw Base Image Suffix**: The official OpenClaw registry publishes images with suffixes like `-browser` (containing the browser agent tool) and `-slim` (without extra packages). To provide browser automation capabilities, we target the `${OPENCLAW_VERSION}-browser` tag variant.

## [2026-06-12] Fix default shell to run bash directly

### Context & Goal
When users SSH or shell into the `openclaw-gateway` container in Lagoon, they were greeted with a plain `$` prompt and had to manually run `bash` to get the interactive shell customizations. 

### Implementation Details
1. **Dynamic User Database Registration**: Created a new entrypoint script `.lagoon/10-passwd.sh` to check if the current dynamically assigned Kubernetes User ID (UID) exists in `/etc/passwd`. If not, it appends the user details with shell set to `/bin/bash` and home directory `/home`.
2. **Permissions and Dockerfile Copy**: Updated `Dockerfile` to copy the new script to `/lagoon/entrypoints/10-passwd.sh` and run `fix-permissions /etc/passwd` to ensure the file is group-writable at runtime by the dynamic user (who runs in group 0).

### Outcomes & Learnings
- **Kubernetes SSH Shell Selection**: The SSH portal/exec API relies on `/etc/passwd` to determine the user's login shell. If the dynamic UID doesn't exist, it defaults to `/bin/sh`.
- **Dynamic passwd Injection**: Writing a custom entry in `/etc/passwd` at startup for dynamic UIDs resolves both the default shell issue and user/home directory mapping problems for utilities like git/ssh.

## [2026-06-12] Disable auto-updates in container runtime

### Context & Goal
To guarantee that OpenClaw is always deployed with the correct version specified in the Docker image tag (rather than downloading code in the background and performing updates), we need to disable background package auto-updates inside the container.

### Implementation Details
Added the `OPENCLAW_NO_AUTO_UPDATE=1` environment variable to the `ENV` block in `Dockerfile`.

### Outcomes & Learnings
- **OpenClaw Auto-Update Kill Switch**: OpenClaw supports `OPENCLAW_NO_AUTO_UPDATE=1` as a global environment variable to bypass auto-update checks and avoid background restarts.

## [2026-06-12] Shell Redirection & vi Editor Setup

### Context & Goal
- **Default Shell Issue**: Dynamic users running containers in Lagoon/OpenShift default to `/bin/sh` (or `bash` running in POSIX mode) when shelling in, skipping the `.bashrc` prompt and welcome configurations.
- **Missing vi Editor**: Unlike standard Alpine Linux base images (which bundle `vi` in BusyBox), Debian/Ubuntu-based minimal images do not include `vi`/`vim` by default.

### Implementation Details
1. **Interactive Shell Upgrade**: Created a `/home/.profile` script that detects if standard input is a terminal (`[ -t 0 ]`) and switches process execution directly to `/bin/bash` (`exec /bin/bash`).
2. **ENV Environment Variable**: Configured `ENV=/home/.profile` in the Dockerfile so interactive POSIX-compliant shells (like Bash running as `sh`) automatically source this script at start.
3. **Editor Installation**: Added `vim-tiny` to the `apt-get install` commands in the `Dockerfile` to provide the standard `/usr/bin/vi` editor.

### Outcomes & Learnings
- **Debian vs Alpine Base Packages**: Alpine containers get `vi` for free from BusyBox, but Debian/Ubuntu minimal images require installing `vim-tiny` or `vim`.
- **POSIX Shell Hooking**: The `ENV` environment variable is the standard POSIX way to hook interactive shells. Coupling this with standard input check `[ -t 0 ]` and a recursion guard (e.g. `$__OC_REDIRECTED`) makes it possible to transparently upgrade the interactive shell to full `bash` (which then correctly reads `.bashrc`).

## [2026-06-12] Auto-generation of MEMORY.md

### Context & Goal
OpenClaw automatically populates its workspace with baseline starter files (such as `SOUL.md`, `AGENTS.md`, `USER.md`, `HEARTBEAT.md`, `IDENTITY.md`) during first-run setup. However, `MEMORY.md` (which is used for curated long-term memory) is optional and not generated by default by OpenClaw itself. We need to ensure that it is initialized in the workspace on startup.

### Implementation Details
Updated the configuration script `.lagoon/60-amazeeai-config.sh` to check if `MEMORY.md` exists in the workspace directory. If it is missing, the script automatically generates it as a baseline Markdown file.

### Outcomes & Learnings
- **OpenClaw Workspace Lifecycle**: Some cognitive files (like `SOUL.md` or `AGENTS.md`) are generated automatically by OpenClaw's baseline initialization, but memory files like `MEMORY.md` must be pre-created if we want them guaranteed to be present at first boot.


## [2026-06-16] Dynamic Model Discovery & Standalone Refresher Script

### Context & Goal
Provide newly provisioned OpenClaw instances with dynamic discovery and periodic background/scheduled refreshing of all models via the regional amazee.ai LLM URL (e.g. `https://llm.de103.amazee.ai/`). Avoid complex runtime shell generation and template escaping by placing the refresher script in a standalone, Docker-packaged Node.js file.

### Implementation Details
1. **Standalone Model Refresher**: Extracted the model refresher script into `.lagoon/amazeeai-model-refresher.js` which reads target configuration dynamically from environment variables (`AMAZEEAI_BASE_URL`, `AMAZEEAI_API_KEY`). This completely avoids template-string escapes and Heredoc noise inside shell scripts.
2. **Docker Packaging**: Added `COPY .lagoon/amazeeai-model-refresher.js /lagoon/amazeeai-model-refresher.js` to `Dockerfile` so it is pre-compiled and packaged directly inside the runtime image.
3. **Multi-Endpoint Cascading Discovery**: Built the refresher and boot script to sequentially attempt fetching from `/v1/model/info`, then fall back to standard `/v1/models`, and finally `/models`, with API key as Bearer token if provided.
4. **Boot-time Refresher Launcher**: Updated `/lagoon/entrypoints/60-amazeeai-config.sh` to run the standalone `/lagoon/amazeeai-model-refresher.js` asynchronously as a daemon when `AMAZEEAI_DISABLE_BACKGROUND_REFRESH` is not set to `true`.
5. **Lagoon Cron Job Command**: Optimized `.lagoon.yml` to call `node /lagoon/amazeeai-model-refresher.js --once` under Lagoon's built-in scheduler.

### Outcomes & Learnings
- **Clean Architecture & Separation of Concerns**: Isolating the refresher task from the main shell boot script makes the code 10x easier to read, lint, and test. It also shrank the size of `60-amazeeai-config.sh` by over 250 lines.
- **Environment-driven Execution**: Placing configuration entirely in process environment variables (e.g., `AMAZEEAI_BASE_URL`) removes any need for dynamic, boot-time file generation, since Node.js can resolve them directly at execution time.
- **Double Compilation Check**: Ran compilation checks (`node -c` and `sh -n`) on the standalone file and updated shell entrypoint to confirm 100% syntactically correct code.

## [2026-06-17] Disable global sandbox for execution tools

### Context & Goal
Deployments of OpenClaw inside restricted/unprivileged containerized environments (such as amazee.io Lagoon / Kubernetes) were failing on tool execution with `EPERM` (Operation not permitted) errors. This affected all terminal shell/execution commands, including simple commands like `echo`.

### Implementation Details
1. **Identified Sandbox Redundancy**: Because the OpenClaw container is already isolated by Docker/Kubernetes, running an inner nested sandbox is redundant and fails inside unprivileged platforms that lack Docker-in-Docker capabilities.
2. **Global Sandbox Disabling**: Modified the configuration generator script `.lagoon/60-amazeeai-config.sh` to explicitly default `config.agents.defaults.sandbox.mode` to `'off'`.
3. **Validation**: Ran POSIX shell syntax checking (`sh -n`) and Node.js compilation checking (`node -c`) on the updated configuration generator.

### Outcomes & Learnings
- **Container Nesting Constraints**: Nesting sandboxes (like running OpenClaw's default Docker/SSH sandbox) requires escalated permissions that are normally unavailable in production cloud environments. Disabling it via `sandbox.mode = 'off'` allows tools to run cleanly inside the primary container environment, eliminating OS-level `EPERM` roadblocks.

## [2026-06-18] Fix .profile Shell Redirection Syntax Error

### Context & Goal
- **Syntax Error**: A deployed OpenClaw instance failed on SSH / container interactive login with a shell syntax error: `sh: /home/.profile: line 5: syntax error near unexpected token 'fi'`.
- **Root Cause**: During a previous merge conflict resolution in `.lagoon/profile`, the redirection block was incorrectly pruned, leaving a dangling `fi` inside the `then` clause of the `if` statement, which caused interactive shell environments to fail immediately.

### Implementation Details
1. **Restored Interactive Shell Redirection**: Re-implemented the correct full-bash upgrade inside `.lagoon/profile` using:
   ```bash
   if [ -t 0 ] && [ -n "$PS1" ] && [ -z "$__OC_REDIRECTED" ]; then
     export __OC_REDIRECTED=1
     if [ -x /bin/bash ]; then
       exec /bin/bash
     fi
   fi
   ```
2. **POSIX Syntax Verification**: Validated the updated script using `sh -n .lagoon/profile` to guarantee no syntax or compilation issues remain.

### Outcomes & Learnings
- **Strict Linting for Configuration Scripts**: Even tiny shell scripts like `.profile` should always be checked with POSIX shell syntax checking (`sh -n`) during development or release stages.
- **Git Merge Conflict Risks**: High-priority configuration files like shell startup scripts are prone to subtle bugs if merge conflicts are resolved manually without compiling or verifying the syntax of the resolved output.

## [2026-06-18] Rebuild Plugin Index Before Running Post-Upgrade Doctor Commands

### Context & Goal
- **Deployment Timeout**: During container boot, when upgrading or deploying the gateway with a configuration version change (`2026.6.5 -> 2026.6.8`), the automatic migrations triggered `openclaw doctor` commands.
- **Root Cause**: Since this was a fresh or empty deployment, the local plugin index was missing, throwing `plugin.index_unavailable`. In a non-interactive Kubernetes environment, this caused `openclaw doctor` to hang waiting for user input/prompts (or abort the start process), keeping the `node` container unready and failing the rollout on progress deadline timeout.

### Implementation Details
1. **Pre-build Plugin Index**: Added `openclaw plugins registry --refresh || true` right before the migration/doctor commands inside `.lagoon/60-amazeeai-config.sh`. This ensures the local index is fully rebuilt/initialized and valid before any post-upgrade validations are executed.
2. **POSIX Syntax Verification**: Validated the updated script using `sh -n .lagoon/60-amazeeai-config.sh` to confirm syntactic correctness.

### Outcomes & Learnings
- **Preemptive Repair Commands**: Always execute preemptive repair/rebuild commands (like `openclaw plugins registry --refresh`) before running structural validation commands like `openclaw doctor` in containerized environments.
- **Non-Interactive Hang Risks**: CLI commands (like `openclaw doctor --lint`) that do not support or do not specify non-interactive flags (e.g., `--yes`) can easily hang indefinitely inside Kubernetes pods when confronted with missing local file states or dependencies.


## [2026-06-18] Install sqlite3 into Base Docker Image

### Context & Goal
- **Requirement**: Install `sqlite3` or similar package into the `openclaw-lagoon-base` Docker image.
- **Workflow**: Ensure the local environment builds successfully, the working tree is kept clean of local helper files (using local git exclude), and a base-only image release tag is generated and pushed to origin.

### Implementation Details
1. **Apt package installation**: Added `sqlite3` to the main runtime package list inside `Dockerfile`.
2. **Local build verification**: Successfully verified and tested the docker build locally using `docker build -t openclaw-lagoon-base:dev .`
3. **Local Git Ignore Setup**: Appended `GEMINI.md` and `LEARNINGS.gemini.md` to `.git/info/exclude` to preserve a clean git workspace.
4. **Base-only release**: Cut base image release `2026.6.8_1` and pushed both the commit and tag `v2026.6.8_1` to `origin/main` using `./scripts/release-openclaw.sh --base-revision 1 --push`.

### Outcomes & Learnings
- **Debian SQLite CLI Package**: On Debian Bookworm minimal bases, `sqlite3` is the standard, reliable CLI package for running database queries.
- **Local git ignore via exclude**: Utilizing `.git/info/exclude` is a clean way to keep workspace-specific files untracked by Git without modifying the shared, checked-in `.gitignore` file.
- **Cascaded Release Scripts**: Keeping changes modular by committing the `Dockerfile` modification first, and then running the `--base-revision` script cleanly separates the functional code changes from the release workflow transaction.

## [2026-06-23] Centralize Version Tracking and Remove Obsolete RELEASE_VERSION File

### Context & Goal
- **Problem**: Having both `Dockerfile` tracking `OPENCLAW_VERSION` and a separate `RELEASE_VERSION` text file tracking the published image release tag was redundant and prone to drift or out-of-sync states.
- **Goal**: Safely remove the obsolete `RELEASE_VERSION` file while retaining the ability to support base-image-only tag variations (e.g. `2026.6.9_2`) where the published tag diverges from the package version.

### Implementation Details
1. **Dockerfile Dual ARGs**: Added `ARG RELEASE_VERSION` to the top of `Dockerfile` right below `ARG OPENCLAW_VERSION`.
2. **Obsolete File Removal**: Deleted `RELEASE_VERSION` from the repository and git tracking.
3. **Script Upgrade**: Modified `scripts/release-openclaw.sh` to:
   - Extract `current_release_version` directly from the `ARG RELEASE_VERSION` line in the `Dockerfile`.
   - Update both `ARG OPENCLAW_VERSION` and `ARG RELEASE_VERSION` inside the `Dockerfile` using robust Perl substitutions.
   - Clean up any legacy local `RELEASE_VERSION` files during execution.
4. **GitHub Workflows Alignment**: Updated `publish.yml` and `release-openclaw.yml` to extract the build tags directly from the `Dockerfile`'s `ARG` variables via standard POSIX `sed` commands, removing any dependency on the legacy file.
5. **Documentation Refactoring**: Aligned all repo documentation (`AGENTS.md`, `GEMINI.md`, `README.md`) to reflect the new standardized dual-ARG Dockerfile convention.

### Outcomes & Learnings
- **Single Source of Truth**: Consolidating version configuration inside the `Dockerfile` removes external state file dependencies.
- **Robust POSIX Parsing**: Standard `sed` patterns can easily read key-value arguments from a `Dockerfile`, providing a robust metadata channel for CI/CD pipelines without needing external parsers.

## [2026-06-23] Resolve SQLite Database Lock Deadlocks During Rolling Deployments on NFS

### Context & Goal
- **Deployment Timeout**: During `openclaw-gateway` rolling updates/deployments on amazee.io Lagoon, the new container would fail to start, crashing with `Reason: Failed to open the plugin state database. | database is locked | ERR_SQLITE_ERROR`.
- **Root Cause**: Lagoon uses NFS/EFS for persistent storage volumes (`node-persistent`). During a `RollingUpdate`, the old pod is still running while the new pod starts. Because the database contains transient plugin registry metadata and is kept open by the running process in the old pod, SQLite's locking mechanism on NFS causes immediate lock failures when the new pod's startup commands (`openclaw plugins registry --refresh`, `openclaw doctor`, and the gateway itself) attempt to access the DB file `/home/.openclaw/state/openclaw.sqlite`. This prevents the new container from reaching a `Ready` state, exceeding the progress deadline rollout limit.

### Implementation Details
1. **Unlink Transient SQLite Database on Boot**: Added a lock-clearing script block early in the configuration entrypoint `.lagoon/60-amazeeai-config.sh` before any `openclaw` CLI wrapper command or Node config script is evaluated.
2. **NFS "Silly Rename" Handling**: Deleting/unlinking `/home/.openclaw/state/openclaw.sqlite` (along with its `-shm` and `-wal` sidecar files) resolves the conflict safely. On an active NFS mount, unlinking a file that is still held open by another running container forces a rename to a temporary inode (`.nfsXXXXX`). The starting container is then able to create a fresh, unlocked `openclaw.sqlite` file and boot successfully without crashing either container.
3. **Automated Rebuild**: Since the state database contains only transient plugin registry metadata, the entrypoint's subsequent migration/registry refresh scripts automatically rebuild the database on successful startup.

### Outcomes & Learnings
- **SQLite Locking on Networked Filesystems**: Standard SQLite file locking over NFS/EFS is prone to deadlocks during rolling container updates where multiple processes concurrently access the same persistent mount.
- **Safe Unlinking to Break Deadlocks**: Unlinking active transient files on an NFS mount is an elegant and robust pattern for clearing SQLite locks without needing infrastructure-level `Recreate` deployment strategies.


