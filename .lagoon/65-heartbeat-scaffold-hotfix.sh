#!/bin/sh

# Temporary workaround for OpenClaw issue #61492. Keep this runtime rewrite for
# old workspaces that already copied the legacy fenced HEARTBEAT scaffold, and
# remove it once upstream fixes the shipped template and existing agents are no
# longer carrying the bad workspace file forward.
# Rewrite any already-seeded workspace HEARTBEAT scaffold that still uses the
# legacy fenced template form shipped by older images.
node <<'EOFNODE'
const fs = require('fs');
const path = require('path');

function resolveWorkspaceDir() {
  const envWorkspace = process.env.OPENCLAW_WORKSPACE?.trim();
  if (envWorkspace) {
    return envWorkspace;
  }

  const stateDir =
    process.env.OPENCLAW_STATE_DIR || path.join(process.env.HOME || '/home', '.openclaw');
  const configPath = path.join(stateDir, 'openclaw.json');

  try {
    if (fs.existsSync(configPath)) {
      const parsed = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      const configWorkspace = parsed?.agents?.defaults?.workspace;
      if (typeof configWorkspace === 'string' && configWorkspace.trim()) {
        return configWorkspace.trim();
      }
    }
  } catch {
    // Ignore config parse issues and fall back to the default workspace path.
  }

  return '/home/.openclaw/workspace';
}

function deriveLegacyHeartbeatScaffold(content) {
  const match = content.match(
    /^# HEARTBEAT\.md Template\s*\n\s*```(?:markdown|md)\s*\n([\s\S]*?)\n```\s*$/i,
  );
  if (!match) {
    return null;
  }
  return {
    scaffold: content,
    normalized: `${match[1].trimEnd()}\n`,
  };
}

function ensureTrailingNewline(content) {
  return content.endsWith('\n') ? content : `${content}\n`;
}

const heartbeatPath = path.join(resolveWorkspaceDir(), 'HEARTBEAT.md');

try {
  if (!fs.existsSync(heartbeatPath)) {
    process.exit(0);
  }

  const current = fs.readFileSync(heartbeatPath, 'utf8');
  const legacyWorkspace = deriveLegacyHeartbeatScaffold(current);
  if (!legacyWorkspace) {
    process.exit(0);
  }

  fs.writeFileSync(heartbeatPath, legacyWorkspace.normalized, 'utf8');
  console.log('[heartbeat-hotfix] Rewrote workspace HEARTBEAT scaffold to comment-only form');
} catch (error) {
  console.warn(`[heartbeat-hotfix] Skipped due to error: ${error instanceof Error ? error.message : String(error)}`);
}
EOFNODE
