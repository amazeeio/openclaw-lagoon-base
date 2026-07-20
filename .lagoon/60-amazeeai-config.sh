#!/bin/sh
# Lagoon entrypoint: Configure OpenClaw from environment variables
# Discovers models from amazee.ai API when AMAZEEAI_BASE_URL is set; otherwise
# writes a minimal config so the container can start without amazee.ai.

echo "[amazeeai-config] Configuring OpenClaw..."

# Clean up duplicate state directories that can split session history in Lagoon environments
if [ -d "/home/node/.openclaw" ]; then
  echo "[amazeeai-config] Cleaning up duplicate node state directory..."
  rm -rf "/home/node/.openclaw" || true
fi

# Attempt to tighten state directory permissions safely (ignoring filesystem/EPERM limitations on NFS/EFS)
if [ -d "/home/.openclaw" ]; then
  chmod 700 /home/.openclaw 2>/dev/null || true
fi

# Clear stale SQLite WAL/SHM lock sidecars left by a previous pod on NFS/EFS
# so RollingUpdate deployments don't deadlock. Never delete the DB itself: it
# is OpenClaw's canonical runtime store (cron jobs, device pairings, exec
# approvals, plugin state), not a transient cache.
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/.openclaw}/state"
STATE_DB="${STATE_DIR}/openclaw.sqlite"
if [ -f "${STATE_DB}-shm" ] || [ -f "${STATE_DB}-wal" ]; then
  echo "[amazeeai-config] Clearing stale SQLite WAL/SHM lock files to prevent RollingUpdate deadlocks..."
  rm -f "${STATE_DB}-shm" "${STATE_DB}-wal" || true
fi


node << 'EOFNODE'
const fs = require('fs');
const path = require('path');

// Config paths - use OPENCLAW_STATE_DIR if set, otherwise default to home directory
const stateDir = process.env.OPENCLAW_STATE_DIR || path.join(process.env.HOME || '/home', '.openclaw');
const configPath = path.join(stateDir, 'openclaw.json');
const approvalsPath = path.join(stateDir, 'exec-approvals.json');
const workspaceDir = process.env.OPENCLAW_WORKSPACE || '/home/.openclaw/workspace';
const bundledBootstrapSourceDir = '/lagoon/amazeeai-bootstrap';
const bundledSkillsSourceDir = '/lagoon/amazeeai-skills';
const managedSkillsDir = path.join(stateDir, 'skills');
const injectedPromptFiles = new Set(['AGENTS.md', 'SOUL.md', 'TOOLS.md']);

console.log('[amazeeai-config] Config path:', configPath);

// Ensure config directory exists
fs.mkdirSync(stateDir, { recursive: true });

// Minimal config template - OpenClaw requires certain base fields to start properly
// Based on: https://github.com/CrocSwap/clawdbot-docker/blob/main/openclaw.json.template
const gatewayPort = parseInt(process.env.OPENCLAW_GATEWAY_PORT, 10) || 18789;

const configTemplate = {
  agents: {
    defaults: {
      workspace: process.env.OPENCLAW_WORKSPACE || '/home/.openclaw/workspace'
    }
  },
  tools: {
    profile: 'full',
    allow: ['*'],
    exec: {
      host: 'gateway',
      security: 'full',
      ask: 'off'
    }
  },
  gateway: {
    port: gatewayPort,
    mode: 'local',
    controlUi: {
      dangerouslyDisableDeviceAuth: true,
      allowedOrigins: ['http://localhost:3000', 'http://localhost:4173', 'http://localhost:6006', 'https://alpha.amazeeclaw.amazee.ai', 'https://my.amazee.io', 'https://my.amazeeio.review'],
    },
  },
  update: {
    checkOnStart: false,
  },
};

// Load existing config or initialize from template
let config = {};
try {
  if (fs.existsSync(configPath)) {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    console.log('[amazeeai-config] Loaded existing config');
  } else {
    // No config exists - initialize from template
    config = JSON.parse(JSON.stringify(configTemplate));
    console.log('[amazeeai-config] No existing config found, initializing from template');
  }
} catch (e) {
  // Config file exists but is invalid - back it up, then start from template.
  if (fs.existsSync(configPath)) {
    try {
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const backupPath = `${configPath}.parse-error-${timestamp}.bak`;
      fs.copyFileSync(configPath, backupPath);
      console.log('[amazeeai-config] Backed up invalid config to:', backupPath);
    } catch (backupError) {
      console.warn('[amazeeai-config] Failed to back up invalid config:', backupError.message);
    }
  }

  console.log('[amazeeai-config] Config parse error, reinitializing from template:', e.message);
  config = JSON.parse(JSON.stringify(configTemplate));
}

// Ensure nested objects exist and required fields are set
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
if (typeof config.agents.defaults.model === 'string') {
  config.agents.defaults.model = { primary: config.agents.defaults.model };
} else {
  config.agents.defaults.model = config.agents.defaults.model || {};
}
config.agents.defaults.compaction = config.agents.defaults.compaction || {};
config.models = config.models || {};
config.models.providers = config.models.providers || {};
config.tools = config.tools || {};
config.gateway = config.gateway || {};
config.update = config.update || {};
config.channels = config.channels || {};
config.hooks = config.hooks || {};
config.hooks.internal = config.hooks.internal || {};
config.hooks.internal.entries = config.hooks.internal.entries || {};

config.tools.profile = 'full';
config.tools.allow = ['*'];
config.tools.exec = config.tools.exec || {};
config.tools.exec.host = 'gateway';
config.tools.exec.security = 'full';
config.tools.exec.ask = 'off';
console.log('[amazeeai-config] Enforced autonomous tool execution defaults (profile=full, allow=*, exec.host=gateway, exec.security=full, exec.ask=off)');

config.agents.defaults.sandbox = config.agents.defaults.sandbox || {};
config.agents.defaults.sandbox.mode = 'off';
console.log('[amazeeai-config] Disabled sandbox globally to allow unhindered tool execution in containerized environments (sandbox.mode=off)');

// Ensure default exec-approvals.json exists or has the correct defaults
const defaultApprovals = {
  version: 1,
  defaults: {
    security: 'full',
    ask: 'off',
    askFallback: 'full'
  }
};

let approvals = {};
try {
  if (fs.existsSync(approvalsPath)) {
    approvals = JSON.parse(fs.readFileSync(approvalsPath, 'utf8'));
    console.log('[amazeeai-config] Loaded existing exec-approvals.json');
  } else {
    approvals = JSON.parse(JSON.stringify(defaultApprovals));
    console.log('[amazeeai-config] Initializing exec-approvals.json from template');
  }
} catch (e) {
  console.log('[amazeeai-config] Error parsing exec-approvals.json, resetting to default:', e.message);
  approvals = JSON.parse(JSON.stringify(defaultApprovals));
}

// Ensure defaults are set
approvals.version = approvals.version || 1;
approvals.defaults = approvals.defaults || {};
approvals.defaults.security = 'full';
approvals.defaults.ask = 'off';
approvals.defaults.askFallback = 'full';

fs.writeFileSync(approvalsPath, JSON.stringify(approvals, null, 2));
console.log('[amazeeai-config] Enforced default exec-approvals.json at:', approvalsPath);


// Ensure required base fields from template are present
// OpenClaw needs these to start properly
if (!config.agents.defaults.workspace) {
  config.agents.defaults.workspace = workspaceDir;
  console.log('[amazeeai-config] Set default workspace:', config.agents.defaults.workspace);
}

function ensureBundledBootstrapFiles() {
  if (!fs.existsSync(bundledBootstrapSourceDir)) {
    console.warn('[amazeeai-config] Bundled bootstrap source not found:', bundledBootstrapSourceDir);
    return [];
  }

  const seededRelativePaths = [];
  const pendingDirs = [bundledBootstrapSourceDir];

  while (pendingDirs.length > 0) {
    const currentDir = pendingDirs.pop();
    const entries = fs.readdirSync(currentDir, { withFileTypes: true });

    for (const entry of entries) {
      const sourcePath = path.join(currentDir, entry.name);
      const relativePath = path.relative(bundledBootstrapSourceDir, sourcePath);

      if (entry.isDirectory()) {
        pendingDirs.push(sourcePath);
        continue;
      }

      if (!entry.isFile()) {
        continue;
      }

      const targetPath = path.join(workspaceDir, relativePath);
      fs.mkdirSync(path.dirname(targetPath), { recursive: true });
      fs.copyFileSync(sourcePath, targetPath);
      seededRelativePaths.push(relativePath);
      console.log('[amazeeai-config] Seeded extra bootstrap file:', targetPath);
    }
  }

  return seededRelativePaths.sort();
}

function ensureBundledSkillFiles() {
  if (!fs.existsSync(bundledSkillsSourceDir)) {
    console.warn('[amazeeai-config] Bundled skills source not found:', bundledSkillsSourceDir);
    return [];
  }

  const seededSkillPaths = [];
  const pendingDirs = [bundledSkillsSourceDir];

  while (pendingDirs.length > 0) {
    const currentDir = pendingDirs.pop();
    const entries = fs.readdirSync(currentDir, { withFileTypes: true });

    for (const entry of entries) {
      const sourcePath = path.join(currentDir, entry.name);
      const relativePath = path.relative(bundledSkillsSourceDir, sourcePath);

      if (entry.isDirectory()) {
        pendingDirs.push(sourcePath);
        continue;
      }

      if (!entry.isFile()) {
        continue;
      }

      const targetPath = path.join(managedSkillsDir, relativePath);
      fs.mkdirSync(path.dirname(targetPath), { recursive: true });
      fs.copyFileSync(sourcePath, targetPath);
      seededSkillPaths.push(relativePath);
      console.log('[amazeeai-config] Seeded bundled skill file:', targetPath);
    }
  }

  return seededSkillPaths.sort();
}

function getBundledBootstrapExtraFiles(relativePaths) {
  if (!Array.isArray(relativePaths) || relativePaths.length === 0) {
    return [];
  }

  return relativePaths.filter(relativePath => injectedPromptFiles.has(path.basename(relativePath)));
}

function configureExtraBootstrapHooks(relativePaths) {
  if (!Array.isArray(relativePaths) || relativePaths.length === 0) {
    delete config.hooks.internal.entries['bootstrap-extra-files'];
    console.log('[amazeeai-config] No bundled bootstrap files found; removed bootstrap-extra-files hook');
    return;
  }

  config.hooks.internal.enabled = true;
  config.hooks.internal.entries['bootstrap-extra-files'] = {
    enabled: true,
    paths: relativePaths,
  };
  console.log('[amazeeai-config] Enabled hooks.internal.entries.bootstrap-extra-files for', relativePaths.length, 'path(s)');
}

// Initialize compaction memory flush defaults and ensure reserveTokensFloor is at least 50000.
const minReserveTokensFloor = parseInt(process.env.OPENCLAW_RESERVE_TOKENS_FLOOR, 10) || 50000;
if (!config.agents.defaults.compaction.reserveTokensFloor || config.agents.defaults.compaction.reserveTokensFloor < minReserveTokensFloor) {
  config.agents.defaults.compaction.reserveTokensFloor = minReserveTokensFloor;
  console.log('[amazeeai-config] Set agents.defaults.compaction.reserveTokensFloor to:', minReserveTokensFloor);
}

if (!config.agents.defaults.compaction.memoryFlush) {
  config.agents.defaults.compaction.memoryFlush = {
    enabled: true,
    softThresholdTokens: 40000,
    prompt: 'Pre-compaction memory flush. Store durable memories now in memory/YYYY-MM-DD.md (create memory/ if needed). If the file already exists, APPEND only and do not overwrite existing entries. Do not create timestamped variant files (for example, YYYY-MM-DD-HHMM.md); always use the canonical YYYY-MM-DD.md filename. Capture only lasting notes: key decisions made, current project status, lessons learned, and active blockers. If there is nothing durable to store, reply with NO_REPLY.'
  };
  console.log('[amazeeai-config] Initialized compaction memory flush defaults');
} else {
  console.log('[amazeeai-config] Existing compaction memory flush config detected; leaving unchanged');
}

// Initialize context pruning defaults only when not already configured.
if (!config.agents.defaults.contextPruning) {
  config.agents.defaults.contextPruning = {
    mode: 'cache-ttl',
    ttl: '6h',
    keepLastAssistants: 3,
  };
  console.log('[amazeeai-config] Initialized context pruning defaults');
} else {
  console.log('[amazeeai-config] Existing context pruning config detected; leaving unchanged');
}

// Initialize memory search defaults only when not already configured.
if (!config.agents.defaults.memorySearch) {
  config.agents.defaults.memorySearch = {
    experimental: {
      sessionMemory: true,
    },
    sources: ['memory', 'sessions'],
  };
  console.log('[amazeeai-config] Initialized memory search defaults');
} else {
  console.log('[amazeeai-config] Existing memory search config detected; leaving unchanged');
}

// Initialize memory search hybrid query defaults only when not already configured.
if (!config.agents.defaults.memorySearch.query?.hybrid) {
  config.agents.defaults.memorySearch.query = config.agents.defaults.memorySearch.query || {};
  config.agents.defaults.memorySearch.query.hybrid = {
    enabled: true,
    vectorWeight: 0.7,
    textWeight: 0.3,
  };
  console.log('[amazeeai-config] Initialized memory search hybrid query defaults');
} else {
  console.log('[amazeeai-config] Existing memory search hybrid query config detected; leaving unchanged');
}

// Deep-merge default values into config WITHOUT overwriting anything a user (via
// the Control UI / SSH) or a prior run already set. Objects recurse; any existing
// leaf or array is left untouched. This lets us ship new minimal defaults from
// this repo that reach existing instances additively while preserving user edits.
// It cannot CHANGE a value a user already has -- do that with a one-off rule in
// migrateLegacyConfig() when a fleet-wide value change is genuinely needed.
function deepFillDefaults(target, defaults) {
  for (const key of Object.keys(defaults)) {
    const defVal = defaults[key];
    const isPlainObject = defVal && typeof defVal === 'object' && !Array.isArray(defVal);
    if (isPlainObject) {
      if (target[key] === undefined) {
        target[key] = {};
      }
      // Only recurse when the user hasn't replaced this with a non-object; if they
      // have, respect their edit and leave it alone.
      if (target[key] && typeof target[key] === 'object' && !Array.isArray(target[key])) {
        deepFillDefaults(target[key], defVal);
      }
    } else if (target[key] === undefined) {
      target[key] = defVal;
    }
  }
  return target;
}

// Minimal platform defaults seeded into every instance (fill-if-absent only, so
// user edits always win and survive redeploys). Add future minimal defaults here.
const seededDefaults = {
  plugins: {
    entries: {
      // The bundled `webhooks` plugin ships in the OpenClaw image; enable it so
      // users only need to add a route to start receiving webhooks -- via the
      // Control UI, or by editing plugins.entries.webhooks.config.routes. Enabling
      // with no routes is a safe no-op. A user who sets enabled:false to opt out
      // keeps that choice (fill-if-absent never overwrites it).
      webhooks: {
        enabled: true,
        config: { routes: {} },
      },
    },
  },
};
deepFillDefaults(config, seededDefaults);
console.log('[amazeeai-config] Applied minimal platform defaults (webhooks plugin enabled by default)');

if (!config.gateway.port) {
  config.gateway.port = gatewayPort;
}
if (!config.gateway.mode) {
  config.gateway.mode = 'local';
}
if (!config.gateway.controlUi) {
  config.gateway.controlUi = {};
}
if (config.gateway.controlUi.dangerouslyDisableDeviceAuth === undefined) {
  config.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
  console.log('[amazeeai-config] Set gateway.controlUi.dangerouslyDisableDeviceAuth to default value: true');
}

// The gateway only ever sees traffic via Lagoon's in-cluster router, so trust
// the private pod/service networks for x-forwarded-for. Without this the gateway
// treats every request as coming from an untrusted address and cannot detect
// the real client ("Proxy headers detected from untrusted address" warning).
// ponytail: RFC1918 ranges cover any in-cluster proxy; narrow to the router IP
// if a tighter allowlist is ever needed.
if (!Array.isArray(config.gateway.trustedProxies) || config.gateway.trustedProxies.length === 0) {
  config.gateway.trustedProxies = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'];
  console.log('[amazeeai-config] Set gateway.trustedProxies default for the in-cluster Lagoon proxy');
}

if (config.update.checkOnStart !== false) {
  config.update.checkOnStart = false;
  console.log('[amazeeai-config] Forced update.checkOnStart to Lagoon default: false');
}

// Always set allowed origins at startup to ensure secure defaults are enforced.
const parseLagoonRoutes = (rawRoutes) => {
  if (!rawRoutes || typeof rawRoutes !== 'string') {
    return [];
  }

  return rawRoutes
    .split(',')
    .map(route => route.trim())
    .filter(Boolean)
    .map(route => route.replace(/\/+$/, ''))
    .map(route => {
      if (/^https?:\/\//i.test(route)) {
        return route;
      }
      return `https://${route}`;
    });
};

const fixedAllowedOrigins = [
  'http://localhost:3000',
  'http://localhost:3001',
  'http://localhost:4173',
  'http://localhost:6006',
  'https://alpha.amazeeclaw.amazee.ai',
  'https://my.amazee.io',
  'https://my.amazeeio.review',
];

const lagoonRouteOrigins = parseLagoonRoutes(process.env.LAGOON_ROUTES || '');
// Union (not replace) so the platform origins are always guaranteed while any
// origin a user added via the Control UI survives redeploys.
const existingAllowedOrigins = Array.isArray(config.gateway.controlUi.allowedOrigins)
  ? config.gateway.controlUi.allowedOrigins
  : [];
config.gateway.controlUi.allowedOrigins = Array.from(new Set([
  ...fixedAllowedOrigins,
  ...lagoonRouteOrigins,
  ...existingAllowedOrigins,
]));
console.log('[amazeeai-config] Set gateway.controlUi.allowedOrigins to:', config.gateway.controlUi.allowedOrigins.join(', '));

// ============================================================
// AMAZEEAI MODEL DISCOVERY
// ============================================================
async function discoverModels() {
  const baseUrl = (process.env.AMAZEEAI_BASE_URL || '').replace(/\/+$/, '');
  const apiKey = process.env.AMAZEEAI_API_KEY || '';
  const defaultModel = process.env.AMAZEEAI_DEFAULT_MODEL || '';

  if (!baseUrl) {
    console.log('[amazeeai-config] No AMAZEEAI_BASE_URL set, skipping model discovery');
    return;
  }

  console.log('[amazeeai-config] Discovering models from:', baseUrl);

  try {
    const headers = { 'Content-Type': 'application/json' };
    if (apiKey) {
      headers['Authorization'] = `Bearer ${apiKey}`;
    }

    let data;
    let format = 'info';
    let success = false;

    // Try /v1/model/info
    try {
      console.log('[amazeeai-config] Attempting model discovery from /v1/model/info...');
      const response = await fetch(`${baseUrl}/v1/model/info`, { headers });
      if (response.ok) {
        const payload = await response.json();
        if (payload.data && Array.isArray(payload.data)) {
          data = payload;
          format = 'info';
          success = true;
        }
      } else {
        console.warn(`[amazeeai-config] /v1/model/info returned status ${response.status}`);
      }
    } catch (e) {
      console.warn('[amazeeai-config] /v1/model/info fetch error:', e.message);
    }

    // Fallback 1: Try /v1/models
    if (!success) {
      try {
        console.log('[amazeeai-config] Attempting model discovery from /v1/models...');
        const response = await fetch(`${baseUrl}/v1/models`, { headers });
        if (response.ok) {
          const payload = await response.json();
          const list = Array.isArray(payload) ? payload : (payload && Array.isArray(payload.data) ? payload.data : null);
          if (list) {
            data = { data: list };
            format = 'list';
            success = true;
          }
        } else {
          console.warn(`[amazeeai-config] /v1/models returned status ${response.status}`);
        }
      } catch (e) {
        console.warn('[amazeeai-config] /v1/models fetch error:', e.message);
      }
    }

    // Fallback 2: Try /models
    if (!success) {
      try {
        console.log('[amazeeai-config] Attempting model discovery from /models...');
        const response = await fetch(`${baseUrl}/models`, { headers });
        if (response.ok) {
          const payload = await response.json();
          const list = Array.isArray(payload) ? payload : (payload && Array.isArray(payload.data) ? payload.data : null);
          if (list) {
            data = { data: list };
            format = 'list';
            success = true;
          }
        } else {
          console.warn(`[amazeeai-config] /models returned status ${response.status}`);
        }
      } catch (e) {
        console.warn('[amazeeai-config] /models fetch error:', e.message);
      }
    }

    if (!success) {
      console.error('[amazeeai-config] Failed to discover models from any endpoint');
      return;
    }

    console.log(`[amazeeai-config] Discovered ${data.data.length} models (${format} format)`);

    const toNumberOr = (value, fallback) => {
      if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
      }
      return fallback;
    };

    const isReasoningModel = (modelName, info) => {
      if (info?.supports_reasoning === true) {
        return true;
      }
      const supportedParams = Array.isArray(info?.supported_openai_params) ? info.supported_openai_params : [];
      if (supportedParams.includes('thinking') || supportedParams.includes('reasoning_effort')) {
        return true;
      }
      return false;
    };

    const deriveInputTypes = (info) => {
      const mode = info?.mode;
      const inputTypes = ['text'];
      if (mode === 'embedding') {
        return inputTypes;
      }
      if (info?.supports_vision === true) {
        inputTypes.push('image');
      }
      return inputTypes;
    };

    const resolveModelApi = (modelName) => {
      const normalizedModelName = String(modelName || '').trim().toLowerCase();
      return normalizedModelName.startsWith('claude-') || normalizedModelName.includes('claude')
        ? 'anthropic-messages'
        : 'openai-completions';
    };

    let models = [];
    if (format === 'info') {
      models = data.data.map(m => {
        const info = m.model_info || {};
        const modelName = m.model_name || info.key || m.litellm_params?.model || '';
        const contextWindow = toNumberOr(info.max_input_tokens, toNumberOr(info.max_tokens, 128000));
        const maxTokens = toNumberOr(info.max_output_tokens, toNumberOr(info.max_tokens, 4096));

        return {
          id: modelName,
          name: modelName,
          api: resolveModelApi(modelName),
          reasoning: isReasoningModel(modelName, info),
          input: deriveInputTypes(info),
          cost: {
            input: toNumberOr(info.input_cost_per_token, 0),
            output: toNumberOr(info.output_cost_per_token, 0),
            cacheRead: toNumberOr(info.cache_read_input_token_cost, 0),
            cacheWrite: toNumberOr(info.cache_creation_input_token_cost, 0),
          },
          contextWindow,
          maxTokens,
        };
      }).filter(m => m.id);
    } else {
      models = data.data.map(m => {
        const modelName = typeof m === 'string' ? m : (m.id || m.name || '');

        return {
          id: modelName,
          name: modelName,
          api: resolveModelApi(modelName),
          reasoning: isReasoningModel(modelName, {}),
          input: ['text'],
          cost: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
          },
          contextWindow: 128000,
          maxTokens: 4096,
        };
      }).filter(m => m.id);
    }

    if (models.length === 0) {
      console.log('[amazeeai-config] No valid models after filtering');
      return;
    }

    const providerConfig = {
      baseUrl: baseUrl,
      api: 'openai-completions',
      models: models,
    };

    if (apiKey) {
      providerConfig.apiKey = apiKey;
    }

    config.models.providers.amazeeai = providerConfig;
    console.log('[amazeeai-config] Added amazeeai provider with', models.length, 'models');

    const discoveredAllowlist = {};
    for (const model of models) {
      discoveredAllowlist[`amazeeai/${model.id}`] = {};
    }
    config.agents.defaults.models = discoveredAllowlist;

    const modelIds = models.map(m => m.id);
    if (defaultModel) {
      const requestedPrimaryModel = `amazeeai/${defaultModel}`;
      if (modelIds.includes(defaultModel)) {
        config.agents.defaults.model.primary = requestedPrimaryModel;
        console.log('[amazeeai-config] Set default primary model from AMAZEEAI_DEFAULT_MODEL:', requestedPrimaryModel);
      } else {
        console.warn(`[amazeeai-config] Warning: AMAZEEAI_DEFAULT_MODEL "${defaultModel}" not found in discovered models`);
        console.warn('[amazeeai-config] Available models:', modelIds.join(', '));
        if (modelIds.length > 0) {
          config.agents.defaults.model.primary = `amazeeai/${modelIds[0]}`;
          console.log('[amazeeai-config] Falling back to first discovered model:', config.agents.defaults.model.primary);
        }
      }
    } else if (modelIds.length > 0) {
      config.agents.defaults.model.primary = `amazeeai/${modelIds[0]}`;
      console.log('[amazeeai-config] No AMAZEEAI_DEFAULT_MODEL set; defaulting to first discovered model:', config.agents.defaults.model.primary);
    } else {
      console.log('[amazeeai-config] No AMAZEEAI_DEFAULT_MODEL set and no models discovered; leaving default model config unchanged');
    }
  } catch (error) {
    console.error('[amazeeai-config] Model discovery failed:', error.message);
  }
}

function hasAmazeeaiEmbeddingsModel() {
  const models = config.models?.providers?.amazeeai?.models;
  if (!Array.isArray(models) || models.length === 0) {
    return false;
  }

  return models.some(model => {
    const mode = String(model?.mode || model?.type || '').toLowerCase();
    if (mode === 'embedding' || mode === 'embeddings') {
      return true;
    }

    const idAndName = `${model?.id || ''} ${model?.name || ''}`.toLowerCase();
    return /\bembed(ding|dings)?\b/.test(idAndName);
  });
}

function configureMemorySearchRemoteFromAmazeeai() {
  if (!hasAmazeeaiEmbeddingsModel()) {
    console.warn('[amazeeai-config] Skipping memorySearch remote override: embeddings model not found in amazeeai provider');
    return;
  }

  const memorySearchBaseUrl = (process.env.AMAZEEAI_BASE_URL || '').replace(/\/+$/, '');
  const memorySearchApiKey = process.env.AMAZEEAI_API_KEY || '';
  config.agents.defaults.memorySearch = config.agents.defaults.memorySearch || {};
  config.agents.defaults.memorySearch.provider = 'openai';
  config.agents.defaults.memorySearch.model = 'embeddings';
  config.agents.defaults.memorySearch.remote = {
    baseUrl: memorySearchBaseUrl ? `${memorySearchBaseUrl}/v1/` : '',
    apiKey: memorySearchApiKey,
  };
  console.log('[amazeeai-config] Configured memorySearch for amazee.ai embeddings model');
}

// ============================================================
// GATEWAY TOKEN CONFIGURATION
// ============================================================
function configureGatewayToken() {
  const crypto = require('crypto');

  if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    console.log('[amazeeai-config] Gateway token set via OPENCLAW_GATEWAY_TOKEN env var');
    return;
  }

  const existingToken = config.gateway?.auth?.token;
  if (existingToken && typeof existingToken === 'string' && existingToken.trim().length > 0) {
    console.log('[amazeeai-config] Gateway token already configured');
    return;
  }

  const generatedToken = crypto.randomBytes(24).toString('hex');
  config.gateway.auth = config.gateway.auth || {};
  config.gateway.auth.token = generatedToken;
  console.log('[amazeeai-config] Auto-generated gateway token:', generatedToken);
  console.log('[amazeeai-config] Use this token to connect to the gateway');
}

// ============================================================
// CHANNEL CONFIGURATION (from environment variables)
// Using ${VAR_NAME} references - OpenClaw substitutes at load time
// ============================================================
function configureChannels() {
  if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = '${TELEGRAM_BOT_TOKEN}';
    config.channels.telegram.enabled = true;
    config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    console.log('[amazeeai-config] Configured Telegram channel');
  }

  if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = '${DISCORD_BOT_TOKEN}';
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
    console.log('[amazeeai-config] Configured Discord channel');
  }

  if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = '${SLACK_BOT_TOKEN}';
    config.channels.slack.appToken = '${SLACK_APP_TOKEN}';
    config.channels.slack.enabled = true;
    config.channels.slack.groupPolicy = process.env.SLACK_GROUP_POLICY || 'open';
    console.log('[amazeeai-config] Configured Slack channel (groupPolicy=' + config.channels.slack.groupPolicy + ')');
  }

  // Fleet policy: Slack replies always go into a thread on the triggering
  // message. Enforced on every start (covers Control-UI-configured Slack too).
  if (config.channels.slack) {
    config.channels.slack.replyToMode = 'first';
    console.log('[amazeeai-config] Enforced Slack replyToMode=first (always reply in thread)');
  }
}

function sanitizeModelInputs() {
  const allowedInputs = new Set(['text', 'image']);
  const providers = config.models?.providers;
  if (!providers || typeof providers !== 'object') {
    return;
  }

  let sanitizedCount = 0;
  for (const provider of Object.values(providers)) {
    if (!provider || !Array.isArray(provider.models)) {
      continue;
    }
    for (const model of provider.models) {
      const originalInput = Array.isArray(model.input) ? model.input : ['text'];
      const sanitizedInput = originalInput.filter(value => allowedInputs.has(value));
      const uniqueInput = Array.from(new Set(sanitizedInput));
      const finalInput = uniqueInput.length > 0 ? uniqueInput : ['text'];

      const changed = finalInput.length !== originalInput.length
        || finalInput.some((value, idx) => value !== originalInput[idx]);

      if (changed) {
        model.input = finalInput;
        sanitizedCount += 1;
      }
    }
  }

  if (sanitizedCount > 0) {
    console.log(`[amazeeai-config] Sanitized input types for ${sanitizedCount} model(s) to OpenClaw-supported values`);
  }
}

// Migrate legacy config shapes that newer OpenClaw schemas reject so the
// gateway can boot. The gateway hard-refuses to start on an invalid config and
// `openclaw doctor --fix` will NOT auto-migrate these (it bails on the hard
// validation errors), so we normalise them here, in place, before writing.
// Idempotent: each rule only rewrites the known legacy shape.
//   - mcp.servers[].auth {type:"oauth"} -> "oauth"  (auth is a string now)
//   - mcp.servers[].type "http"/"sse" (legacy CLI alias) -> canonical transport
//     ("streamable-http"/"sse"); see docs.openclaw.ai/gateway/configuration-reference
//   - channels.slack.streaming "partial" (string) -> { mode: "partial" }
//   - channels.slack.nativeStreaming: true -> folded into streaming.nativeTransport
//   - channels.slack.channels.<id>.allow -> enabled
function migrateLegacyConfig() {
  let changed = 0;
  const servers = config.mcp && config.mcp.servers;
  if (servers && typeof servers === 'object') {
    for (const s of Object.values(servers)) {
      if (!s || typeof s !== 'object') continue;
      if (s.auth && typeof s.auth === 'object' && typeof s.auth.type === 'string') {
        s.auth = s.auth.type; changed++;
      }
      if (s.transport == null && typeof s.type === 'string') {
        if (s.type === 'http') { s.transport = 'streamable-http'; changed++; }
        else if (s.type === 'sse') { s.transport = 'sse'; changed++; }
      }
      if (s.transport != null && 'type' in s) { delete s.type; changed++; }
    }
  }
  const slack = config.channels && config.channels.slack;
  if (slack && typeof slack === 'object') {
    let streaming = null;
    if (typeof slack.streaming === 'string') streaming = { mode: slack.streaming };
    else if (slack.streaming && typeof slack.streaming === 'object') streaming = slack.streaming;
    if (slack.nativeStreaming === true) streaming = Object.assign(streaming || {}, { nativeTransport: true });
    if (streaming && slack.streaming !== streaming) { slack.streaming = streaming; changed++; }
    if ('nativeStreaming' in slack) { delete slack.nativeStreaming; changed++; }
    if (slack.channels && typeof slack.channels === 'object') {
      for (const ch of Object.values(slack.channels)) {
        if (ch && typeof ch === 'object' && ch.allow != null) {
          ch.enabled = ch.allow; delete ch.allow; changed++;
        }
      }
    }
  }
  if (changed > 0) {
    console.log(`[amazeeai-config] Migrated ${changed} legacy config field(s) to the current schema`);
  }
}

async function main() {
  const bundledWorkspacePaths = ensureBundledBootstrapFiles();
  ensureBundledSkillFiles();
  const bootstrapExtraFiles = getBundledBootstrapExtraFiles(bundledWorkspacePaths);
  await discoverModels();
  configureMemorySearchRemoteFromAmazeeai();
  configureGatewayToken();
  configureChannels();
  configureExtraBootstrapHooks(bootstrapExtraFiles);
  sanitizeModelInputs();
  migrateLegacyConfig();

  // Ensure MEMORY.md exists in the workspace
  const memoryMdPath = path.join(workspaceDir, 'MEMORY.md');
  if (!fs.existsSync(memoryMdPath)) {
    fs.mkdirSync(workspaceDir, { recursive: true });
    fs.writeFileSync(memoryMdPath, '# Long-Term Memory\n\nThis file contains durable facts, preferences, and standing decisions.\n');
    console.log('[amazeeai-config] Generated missing MEMORY.md');
  }

  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  console.log('[amazeeai-config] Configuration saved to:', configPath);
}

main().catch(err => {
  console.error('[amazeeai-config] Fatal error:', err);
  process.exit(1);
});
EOFNODE


configPath="/home/.openclaw/openclaw.json"

# Detect OpenClaw core version change and legacy state files
OLD_VER="0"
IS_FRESH_INSTALL=0
if [ -f "$configPath" ]; then
  OLD_VER=$(jq -r '.meta.lastTouchedVersion // "0"' "$configPath" 2>/dev/null || echo "0")
else
  IS_FRESH_INSTALL=1
fi
CURRENT_VER=$(openclaw --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "unknown")

LEGACY_FILES_FOUND=0
if [ -f "/home/.openclaw/subagents/runs.json" ] || [ -f "/home/.openclaw/workspace/setup-state.json" ] || [ -f "/home/.openclaw/workspace/.setup-state" ]; then
  LEGACY_FILES_FOUND=1
fi

# ============================================================
# Ensure external channel plugins are present on the state volume (BACKGROUND)
#
# In current OpenClaw, several chat channels ship as EXTERNAL plugins whose code
# must live under /home/.openclaw/npm/projects before their config takes effect
# (bundled channels such as Telegram and iMessage need no install). Without the
# plugin code present, writing channels.slack into openclaw.json silently does
# nothing -- this is why Slack disappeared after the core upgrade.
#
# The DEFAULT set is baked into the image at build time (see Dockerfile
# OPENCLAW_SEED_DIR) and copied onto the volume here -- a plain local->NFS file
# copy, NOT `openclaw plugins install`. The npm install path runs npm/network/
# builds against the slow NFS volume and is what stalled the Kubernetes rollout
# progress deadline; a copy avoids all of that. The gateway rebuilds its plugin
# install records from a filesystem scan at startup, so copied-in projects are
# discovered on the next gateway start with no `plugins install`/`registry
# --refresh` needed (the documented "restart to activate" model).
#
# CRITICAL: entrypoints.sh runs this script to completion *before* it execs the
# gateway, so this work is detached to the background: the gateway starts
# immediately and the pod becomes Ready, while plugins are populated out-of-band.
# Newly seeded channels activate on the next gateway restart.
#
# Extras not baked into the image are installed via npm from OPENCLAW_EXTRA_PLUGINS,
# e.g. OPENCLAW_EXTRA_PLUGINS="@openclaw/signal" (kept out of the default set: no
# stable npm release matching the core version yet).
# ============================================================
ensure_channel_plugins() {
  projects_dir="/home/.openclaw/npm/projects"
  seed_projects="${OPENCLAW_SEED_DIR:-/lagoon/seed-openclaw}/npm/projects"

  # Let the freshly-started gateway initialise its state DB first, to minimise
  # SQLite lock contention on the NFS volume while we touch the plugin projects.
  sleep 20

  # Copy the image-baked default plugins onto the volume. `cp -RP` recurses but
  # never dereferences symlinks, so the openclaw -> /app peer symlink is copied as
  # a symlink (needed so the plugin resolves the core) rather than following it and
  # duplicating /app. It also does not try to preserve root ownership as the
  # openclaw user. Seed and volume project dir names are the same deterministic
  # hash, so a per-dir copy lands exactly where the gateway looks. Re-copy on a
  # core version change so the plugins match the new core; otherwise only fill in
  # what's missing.
  if [ -d "$seed_projects" ]; then
    mkdir -p "$projects_dir"
    for src in "$seed_projects"/*/; do
      [ -d "$src" ] || continue
      name=$(basename "$src")
      dest="$projects_dir/$name"
      if [ ! -d "$dest" ] || [ "$OLD_VER" != "$CURRENT_VER" ]; then
        echo "[amazeeai-config] Seeding plugin project $name from image (core $OLD_VER -> $CURRENT_VER)"
        rm -rf "$dest"
        cp -RP "$src" "$dest"
      fi
    done
    echo "[amazeeai-config] Default channel plugins seeded from image"
  else
    echo "[amazeeai-config] WARNING: no baked plugin seed at $seed_projects; skipping default plugin seeding"
  fi

  # Extras are not baked into the image: install any configured-but-missing ones
  # via npm (rare; accepts the npm cost since it is opt-in per environment).
  if [ -n "${OPENCLAW_EXTRA_PLUGINS:-}" ]; then
    refreshed=""
    for pkg in $OPENCLAW_EXTRA_PLUGINS; do
      [ -n "$pkg" ] || continue
      plugin_id="${pkg##*/}"   # e.g. "signal" from "@openclaw/signal"
      ls -d "$projects_dir"/openclaw-"$plugin_id"-* >/dev/null 2>&1 && continue
      [ -n "$refreshed" ] || { openclaw plugins registry --refresh || true; refreshed=1; }
      echo "[amazeeai-config] Installing extra plugin $pkg ..."
      openclaw plugins install "$pkg" || echo "[amazeeai-config] WARNING: failed to install plugin $pkg (continuing)"
    done
  fi

  echo "[amazeeai-config] Channel plugin maintenance complete; restart gateway to activate newly added channels."
}

# NOTE: invalid-config repair is handled inside the node block above by
# migrateLegacyConfig(), which rewrites legacy shapes (mcp auth/transport, slack
# streaming/channels) the gateway would otherwise reject at boot. We deliberately
# do NOT run `openclaw doctor --fix` here: it refuses to auto-migrate those hard
# validation errors, and `--post-upgrade` needs the plugin index that the state-DB
# wipe above removes (chicken-and-egg). The JS migration is self-sufficient and
# leaves a config the gateway accepts directly.

echo "[amazeeai-config] Scheduling background channel-plugin maintenance (non-blocking)..."
( ensure_channel_plugins ) >/home/.openclaw/plugin-maintenance.log 2>&1 &

echo "[amazeeai-config] Enforcing YOLO exec-policy (no approval prompts for tools or scripts)..."
openclaw exec-policy preset yolo || true

# Only run openclaw doctor --fix if upgrading from an older version or legacy state files exist.
# Fresh project deployments skip this check completely (0ms overhead).
if [ "$LEGACY_FILES_FOUND" -eq 1 ] || { [ "$IS_FRESH_INSTALL" -eq 0 ] && [ "$OLD_VER" != "$CURRENT_VER" ]; }; then
  echo "[amazeeai-config] OpenClaw upgrade/legacy state detected ($OLD_VER -> $CURRENT_VER). Running openclaw doctor --fix..."
  openclaw doctor --fix --yes 2>/dev/null || openclaw doctor --fix 2>/dev/null || true
  
  # Stamp current version into openclaw.json so future restarts skip doctor
  if [ -f "$configPath" ]; then
    tmp_cfg=$(mktemp)
    jq --arg v "$CURRENT_VER" '.meta = (.meta // {}) | .meta.lastTouchedVersion = $v' "$configPath" > "$tmp_cfg" 2>/dev/null && mv "$tmp_cfg" "$configPath" || true
  fi
else
  echo "[amazeeai-config] Fresh deployment or up-to-date state; skipping openclaw doctor --fix."
fi

echo "[amazeeai-config] Configuration complete. Starting OpenClaw gateway..."
echo "[amazeeai-config] Note: OpenClaw may take a moment to initialize (no output is normal)."
