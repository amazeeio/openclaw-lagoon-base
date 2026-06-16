const fs = require('fs');
const path = require('path');

const stateDir = process.env.OPENCLAW_STATE_DIR || path.join(process.env.HOME || '/home', '.openclaw');
const configPath = path.join(stateDir, 'openclaw.json');

const baseUrl = (process.env.AMAZEEAI_BASE_URL || '');
const cleanBaseUrl = baseUrl.endsWith('/') ? baseUrl.slice(0, -1) : baseUrl;
const apiKey = process.env.AMAZEEAI_API_KEY || '';
const defaultModel = process.env.AMAZEEAI_DEFAULT_MODEL || '';

if (!baseUrl) {
  console.log('[amazeeai-refresher] No AMAZEEAI_BASE_URL set, exiting refresher');
  process.exit(0);
}

const intervalMs = parseInt(process.env.AMAZEEAI_REFRESH_INTERVAL_MS, 10) || 10 * 60 * 1000;

console.log('[amazeeai-refresher] Starting background model refresher daemon (interval: ' + intervalMs + 'ms)');

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

async function fetchModels() {
  const headers = { 'Content-Type': 'application/json' };
  if (apiKey) {
    headers['Authorization'] = 'Bearer ' + apiKey;
  }

  let data;
  let format = 'info';
  let success = false;

  try {
    const response = await fetch(cleanBaseUrl + '/v1/model/info', { headers });
    if (response.ok) {
      const payload = await response.json();
      if (payload.data && Array.isArray(payload.data)) {
        data = payload;
        format = 'info';
        success = true;
      }
    }
  } catch (e) {}

  if (!success) {
    try {
      const response = await fetch(cleanBaseUrl + '/v1/models', { headers });
      if (response.ok) {
        const payload = await response.json();
        const list = Array.isArray(payload) ? payload : (payload && Array.isArray(payload.data) ? payload.data : null);
        if (list) {
          data = { data: list };
          format = 'list';
          success = true;
        }
      }
    } catch (e) {}
  }

  if (!success) {
    try {
      const response = await fetch(cleanBaseUrl + '/models', { headers });
      if (response.ok) {
        const payload = await response.json();
        const list = Array.isArray(payload) ? payload : (payload && Array.isArray(payload.data) ? payload.data : null);
        if (list) {
          data = { data: list };
          format = 'list';
          success = true;
        }
      }
    } catch (e) {}
  }

  if (!success) {
    return null;
  }

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

  return models;
}

function sanitizeModelInputs(models) {
  const allowedInputs = new Set(['text', 'image']);
  for (const model of models) {
    const originalInput = Array.isArray(model.input) ? model.input : ['text'];
    const sanitizedInput = originalInput.filter(value => allowedInputs.has(value));
    const uniqueInput = Array.from(new Set(sanitizedInput));
    model.input = uniqueInput.length > 0 ? uniqueInput : ['text'];
  }
}

async function runRefresh() {
  try {
    const models = await fetchModels();
    if (!models || models.length === 0) {
      return;
    }

    sanitizeModelInputs(models);

    if (!fs.existsSync(configPath)) {
      return;
    }

    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const existingModels = config.models?.providers?.amazeeai?.models || [];
    const existingModelIds = existingModels.map(m => m.id).sort().join(',');
    const newModelIds = models.map(m => m.id).sort().join(',');

    if (existingModelIds === newModelIds) {
      return;
    }

    console.log('[amazeeai-refresher] Models changed! Refreshing ' + models.length + ' model(s) in openclaw.json');

    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.amazeeai = config.models.providers.amazeeai || {};
    config.models.providers.amazeeai.baseUrl = cleanBaseUrl;
    config.models.providers.amazeeai.api = 'openai-completions';
    config.models.providers.amazeeai.models = models;
    if (apiKey) {
      config.models.providers.amazeeai.apiKey = apiKey;
    }

    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};

    const discoveredAllowlist = {};
    for (const model of models) {
      discoveredAllowlist['amazeeai/' + model.id] = {};
    }
    config.agents.defaults.models = discoveredAllowlist;

    if (typeof config.agents.defaults.model === 'string') {
      config.agents.defaults.model = { primary: config.agents.defaults.model };
    } else {
      config.agents.defaults.model = config.agents.defaults.model || {};
    }

    const modelIds = models.map(m => m.id);
    const currentPrimary = config.agents.defaults.model.primary || '';
    const cleanPrimary = currentPrimary.replace('amazeeai/', '');

    if (!currentPrimary || !currentPrimary.startsWith('amazeeai/') || !modelIds.includes(cleanPrimary)) {
      if (defaultModel && modelIds.includes(defaultModel)) {
        config.agents.defaults.model.primary = 'amazeeai/' + defaultModel;
      } else if (modelIds.length > 0) {
        config.agents.defaults.model.primary = 'amazeeai/' + modelIds[0];
      }
    }

    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
    console.log('[amazeeai-refresher] Config file updated and saved');
  } catch (error) {
    console.error('[amazeeai-refresher] Refresh failed:', error.message);
  }
}

const once = process.argv.includes('--once') || process.env.AMAZEEAI_REFRESH_ONCE === 'true';
runRefresh().then(() => {
  if (!once) {
    setInterval(runRefresh, intervalMs);
  }
});
