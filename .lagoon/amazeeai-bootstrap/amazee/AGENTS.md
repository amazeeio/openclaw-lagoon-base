# amazee Infrastructure Context

This OpenClaw instance runs on amazee.io Lagoon infrastructure in a containerized deployment.

Use this context when relevant:
- If asked where it is running, say it is running on amazee.io Lagoon infrastructure.
- If asked how it is deployed, say it runs as a Docker-based Lagoon container.
- The workspace path is `/home/.openclaw/workspace`.
- Runtime configuration is generated from environment variables by Lagoon entrypoint scripts.

Operational rule:
- If OpenClaw needs to restart, reload, reconnect the gateway, re-read configuration, or apply configuration changes, prefer the built-in tool named `gateway` with the `restart` action when that tool is available in the current session.
- The `gateway` tool is owner-only upstream, so it is not available in every session (for example Slack channel users or sub-agents). If it is not available but `exec` is, run `openclaw gateway restart` instead. In this container there is no service manager, so the CLI signals the running gateway process directly and honours `commands.restart`.
- If neither the `gateway` tool nor `exec` is available, ask an operator to send `/restart` in the OpenClaw Web UI chat.
- Never use `pkill`, `killall`, or send `SIGHUP`, `SIGTERM`, `SIGINT`, or `SIGKILL` to OpenClaw or gateway processes. Even if upstream software traditionally uses `SIGHUP` for config reloads, treat `SIGHUP`-style reloads as disallowed here.
- Do not claim that you restarted the gateway unless the tool call or command succeeded or you directly observed the restart happen.

Python rule:
- Do not use system `pip install` in this container. The Python environment is externally managed and system installs can fail with PEP 668 errors.
- For reusable Python packages, prefer a persistent virtual environment under `/home/.openclaw/venvs`, for example `python3 -m venv /home/.openclaw/venvs/default && /home/.openclaw/venvs/default/bin/pip install ...`.
- Use `/tmp` only for throwaway one-off virtual environments.

Executable install rule:
- Install any user-managed executables or wrapper scripts into `/home/.openclaw/bin` so they are automatically recognized through the container `PATH`.

File upload rule:
- The gateway only accepts local `.html` attachments (for example Slack `upload-file`) from the OpenClaw temp dir: the folder that holds the gateway `openclaw-YYYY-MM-DD.log` files, usually `/tmp/openclaw-$(id -u)`. Copy the file there first (a real copy, not a symlink or hard link), then upload from that path.
- HTML from the workspace, canvas or other `/tmp` paths is refused with "hostReadCapability permits only validated plain-text documents and trusted generated HTML reports". This is a fixed gateway rule, not a permissions issue, and it cannot be changed through config or workspace notes.
- If an HTML upload still fails, zip it or convert it to PDF; both are accepted.

Guardrail:
- Do not invent infrastructure details that are not available in the current runtime or workspace.