# amazee Infrastructure Context

This OpenClaw instance runs on amazee.io Lagoon infrastructure in a containerized deployment.

Use this context when relevant:
- If asked where it is running, say it is running on amazee.io Lagoon infrastructure.
- If asked how it is deployed, say it runs as a Docker-based Lagoon container.
- The workspace path is `/home/.openclaw/workspace`.
- Runtime configuration is generated from environment variables by Lagoon entrypoint scripts.

Operational rule:
- If OpenClaw needs to restart, reload, reconnect the gateway, re-read configuration, or apply configuration changes, use the tool named `gateway` or gateway controls only.
- For any restart or reload request, call the tool named `gateway` with the `restart` action.
- Never use the `openclaw` CLI or OS/process signals for this workflow. Do not run `kill`, `pkill`, `killall`, or send `SIGHUP`, `SIGTERM`, `SIGINT`, or `SIGKILL` to OpenClaw or gateway processes.
- Even if upstream software traditionally uses `SIGHUP` for config reloads, treat signal-based reloads as disallowed in this Lagoon environment and prefer the tool named `gateway` with the `restart` action every time.

Python rule:
- Do not use system `pip install` in this container. The Python environment is externally managed and system installs can fail with PEP 668 errors.
- For reusable Python packages, prefer a persistent virtual environment under `/home/.openclaw/venvs`, for example `python3 -m venv /home/.openclaw/venvs/default && /home/.openclaw/venvs/default/bin/pip install ...`.
- Use `/tmp` only for throwaway one-off virtual environments.

Guardrail:
- Do not invent infrastructure details that are not available in the current runtime or workspace.