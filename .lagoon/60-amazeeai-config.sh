#!/bin/sh
# Lagoon entrypoint: Configure OpenClaw from environment variables
# Discovers models from amazee.ai API when AMAZEEAI_BASE_URL is set; otherwise
# writes a minimal config so the container can start without amazee.ai.

echo "[amazeeai-config] Configuring OpenClaw..."

node << 'EOFNODE'
const fs = require('fs');
const path = require('path');

// Config paths - use OPENCLAW_STATE_DIR if set, otherwise default to home directory
const stateDir = process.env.OPENCLAW_STATE_DIR || path.join(process.env.HOME || '/home', '.openclaw');
const configPath = path.join(stateDir, 'openclaw.json');
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

// Initialize compaction memory flush defaults only when not already configured.
if (!config.agents.defaults.compaction.memoryFlush) {
  config.agents.defaults.compaction.reserveTokensFloor = 20000;
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
config.gateway.controlUi.allowedOrigins = Array.from(new Set([
  ...fixedAllowedOrigins,
  ...lagoonRouteOrigins,
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
    console.log('[amazeeai-config] Configured Slack channel');
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

refresherScript="/lagoon/amazeeai-model-refresher.js"
if [ -f "$refresherScript" ] && [ "$AMAZEEAI_DISABLE_BACKGROUND_REFRESH" != "true" ]; then
  echo "[amazeeai-config] Starting background model refresher daemon..."
  node "$refresherScript" > /tmp/amazeeai-model-refresher.log 2>&1 &
fi

configPath="/home/.openclaw/openclaw.json"
if [ -f "$configPath" ]; then
  OLD_VER=$(jq -r '.meta.lastTouchedVersion // "0"' "$configPath" 2>/dev/null || echo "0")
  CURRENT_VER=$(openclaw --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "unknown")

  if [ "$OLD_VER" != "$CURRENT_VER" ]; then
    echo "[amazeeai-config] Configuration version changed ($OLD_VER -> $CURRENT_VER). Running migrations..."
    openclaw plugins registry --refresh || true
    openclaw doctor --post-upgrade --fix --yes || true
    openclaw doctor --lint || true
  fi
fi

echo "[amazeeai-config] Configuration complete. Starting OpenClaw gateway..."
echo "[amazeeai-config] Note: OpenClaw may take a moment to initialize (no output is normal)."
