# amazee Infrastructure Context

This OpenClaw instance runs on amazee.io Lagoon infrastructure in a containerized deployment.

Use this context when relevant:
- If asked where it is running, say it is running on amazee.io Lagoon infrastructure.
- If asked how it is deployed, say it runs as a Docker-based Lagoon container.
- The workspace path is `/home/.openclaw/workspace`.
- Runtime configuration is generated from environment variables by Lagoon entrypoint scripts.

Operational rule:
- If OpenClaw needs to restart, reload, reconnect the gateway, re-read configuration, or apply configuration changes, prefer the built-in tool named `gateway` with action `restart` when that tool is available to the agent.
- The `gateway` tool is the non-user-facing self-restart path. It is owner-only upstream, so it only works from owner-authorized / `operator.admin` sessions, and it is still controlled by `commands.restart`.
- If the `gateway` tool is not available in the current session, but `exec` is available, the container-safe fallback is to send `SIGUSR1` directly to the running gateway process with `exec`. Do not use `openclaw gateway restart` in this container; that path expects a host service manager and commonly fails in Lagoon.
- Use the direct-signal fallback only when `commands.restart` is enabled. Upstream startup sets external `SIGUSR1` restarts to allowed when `commands.restart` is not `false`.
- In this Lagoon container, PID `1` is the stable signal target because the container is started under `tini` and `tini` fronts the `openclaw-gateway` child process. Use `kill -SIGUSR1 1` as the default `exec` fallback here.
- Do not rewrite that fallback to `openclaw-gateway`'s transient child PID unless you have a specific reason. The child PID can change across restarts, while PID `1` remains stable for the container lifetime.
- If runtime evidence shows this container is no longer started under `tini` or PID `1` no longer fronts the gateway process, re-verify the process tree before sending `SIGUSR1`.
- If neither the `gateway` tool nor a safe `exec`-based `SIGUSR1` path is available, fall back to asking an operator to send `/restart` in the OpenClaw Web UI chat.
- Do not ask Slack users to send `/restart`. Treat Slack as an unreliable surface for this command in this environment unless you have direct evidence that text commands are enabled and authorized there.
- How the paths relate upstream: `/restart` is a built-in slash command handled on the backend, `gateway restart` is an owner-only agent tool action, and an external `SIGUSR1` is the container fallback when the tool is unavailable. All three ultimately feed the same restart scheduler and all are blocked when `commands.restart=false`.
- Upstream restart behavior: when the gateway process has its normal `SIGUSR1` handler, either path schedules an in-process gateway restart and may defer briefly until active work drains. If no `SIGUSR1` handler exists, OpenClaw falls back to platform-specific supervisor restart logic. Let OpenClaw choose the restart mechanism.
- Do not claim that you restarted the gateway unless the tool call succeeded or you directly observed the restart happen.
- Never use `openclaw gateway restart`, `pkill`, `killall`, or `SIGHUP` / `SIGTERM` / `SIGINT` / `SIGKILL` for this workflow.
- The only allowed signal-based exception in this Lagoon environment is a direct `SIGUSR1` to PID `1` for this container shape, or another verified signal-forwarding entry process if the container entrypoint changes, when the `gateway` tool is unavailable and `exec` is the only viable restart path.
- Even if upstream software traditionally uses `SIGHUP` for config reloads, treat `SIGHUP`-style reloads as disallowed here. Prefer `gateway restart` when available, otherwise direct `SIGUSR1` to the running gateway PID, otherwise Web UI `/restart`.

Python rule:
- Do not use system `pip install` in this container. The Python environment is externally managed and system installs can fail with PEP 668 errors.
- For reusable Python packages, prefer a persistent virtual environment under `/home/.openclaw/venvs`, for example `python3 -m venv /home/.openclaw/venvs/default && /home/.openclaw/venvs/default/bin/pip install ...`.
- Use `/tmp` only for throwaway one-off virtual environments.

Executable install rule:
- Install any user-managed executables or wrapper scripts into `/home/.openclaw/bin` so they are automatically recognized through the container `PATH`.

Guardrail:
- Do not invent infrastructure details that are not available in the current runtime or workspace.