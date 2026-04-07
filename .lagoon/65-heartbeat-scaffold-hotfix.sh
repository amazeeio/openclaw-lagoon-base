#!/bin/sh

# Rewrite the shipped fenced HEARTBEAT scaffold to the older comment-only form,
# but only when the workspace file still exactly matches the installed template.
node <<'EOFNODE'
const fs = require('fs');
const path = require('path');

function stripFrontMatter(content) {
  if (!content.startsWith('---')) {
    return content;
  }
  const endIndex = content.indexOf('\n---', 3);
  if (endIndex === -1) {
    return content;
  }
  return content.slice(endIndex + '\n---'.length).replace(/^\s+/, '');
}

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

function deriveHeartbeatScaffold(templateRaw) {
  const scaffold = stripFrontMatter(templateRaw);
  const match = scaffold.match(
    /^# HEARTBEAT\.md Template\s*\n\s*```(?:markdown|md)\s*\n([\s\S]*?)\n```\s*$/i,
  );
  if (!match) {
    return null;
  }
  return {
    scaffold,
    normalized: `${match[1].trimEnd()}\n`,
  };
}

const templatePath =
  process.env.OPENCLAW_HEARTBEAT_TEMPLATE_PATH ||
  '/usr/local/lib/node_modules/openclaw/docs/reference/templates/HEARTBEAT.md';
const heartbeatPath = path.join(resolveWorkspaceDir(), 'HEARTBEAT.md');

try {
  if (!fs.existsSync(templatePath) || !fs.existsSync(heartbeatPath)) {
    process.exit(0);
  }

  const derived = deriveHeartbeatScaffold(fs.readFileSync(templatePath, 'utf8'));
  if (!derived) {
    process.exit(0);
  }

  const current = fs.readFileSync(heartbeatPath, 'utf8');
  if (current !== derived.scaffold) {
    process.exit(0);
  }

  fs.writeFileSync(heartbeatPath, derived.normalized, 'utf8');
  console.log('[heartbeat-hotfix] Rewrote shipped HEARTBEAT scaffold to comment-only form');
} catch (error) {
  console.warn(`[heartbeat-hotfix] Skipped due to error: ${error instanceof Error ? error.message : String(error)}`);
}
EOFNODE
