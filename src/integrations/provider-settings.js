'use strict';

const PROVIDER_IDS = Object.freeze(['deepseek', 'alibaba', 'opencode-go']);
const TASK_MODEL_IDS = Object.freeze(['video', 'title', 'learning']);
const DEFAULT_CONTEXT_POLICY = Object.freeze({
  contextWindowTokens: 128000,
  reservedOutputTokens: 8192,
  compressionThreshold: 0.95,
  postCompressionRatio: 0.82,
  recentMessages: 12,
  maxImages: 4
});
const API_MODES = Object.freeze(['auto', 'chat', 'responses', 'messages']);
const RESOLVED_API_MODES = Object.freeze(['chat', 'responses', 'messages']);
const API_MODE_ENDPOINTS = Object.freeze({
  chat: 'chat/completions',
  responses: 'responses',
  messages: 'messages'
});
const PROVIDER_DEFAULTS = Object.freeze({
  deepseek: Object.freeze({
    name: 'DeepSeek',
    apiBase: 'https://api.deepseek.com',
    apiKey: '',
    model: 'deepseek-v4-flash',
    apiMode: 'auto',
    resolvedMode: 'chat',
    builtIn: true
  }),
  alibaba: Object.freeze({
    name: '阿里云',
    apiBase: 'https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
    apiKey: '',
    model: 'qwen3.8-max-preview',
    apiMode: 'auto',
    resolvedMode: 'responses',
    builtIn: true
  }),
  'opencode-go': Object.freeze({
    name: 'OpenCode Go',
    apiBase: 'https://opencode.ai/zen/go/v1',
    apiKey: '',
    model: 'deepseek-v4-flash',
    apiMode: 'auto',
    resolvedMode: 'chat',
    builtIn: true
  })
});

function detectProvider(apiBase) {
  let hostname = '';
  let pathname = '';
  try {
    const parsed = new URL(String(apiBase || ''));
    hostname = parsed.hostname.toLowerCase();
    pathname = parsed.pathname;
  } catch (error) {}
  if (hostname === 'api.deepseek.com' || hostname.endsWith('.deepseek.com')) return 'deepseek';
  if (hostname.endsWith('.aliyuncs.com') || hostname.endsWith('.dashscope.com')) return 'alibaba';
  if (hostname === 'opencode.ai' && /\/zen\/go(?:\/|$)/i.test(pathname)) return 'opencode-go';
  return 'custom';
}

function isLoopbackHostname(hostname) {
  const normalized = String(hostname || '').trim().toLowerCase().replace(/^\[|\]$/g, '');
  return normalized === 'localhost'
    || normalized === '::1'
    || /^127(?:\.\d{1,3}){3}$/.test(normalized);
}

function parseProviderUrl(value) {
  let parsed;
  try {
    parsed = new URL(String(value || '').trim());
  } catch (error) {
    throw new Error('API Base URL 格式无效');
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new Error('API Base URL 仅支持 HTTP/HTTPS');
  }
  if (parsed.protocol === 'http:' && !isLoopbackHostname(parsed.hostname)) {
    throw new Error('远程 API Base URL 必须使用 HTTPS');
  }
  if (parsed.username || parsed.password) {
    throw new Error('API Base URL 不能包含账号或密码');
  }
  if (parsed.search || parsed.hash) {
    throw new Error('API Base URL 不能包含查询参数或片段');
  }
  return parsed;
}

/**
 * Converts either an SDK base URL or a pasted generation endpoint back to its
 * API root. Provider-specific path segments (for example compatible-mode/v1)
 * are intentionally retained; unknown providers must not be forced to /v1.
 */
function normalizeProviderBaseUrl(value) {
  const parsed = parseProviderUrl(value);
  let pathname = parsed.pathname.replace(/\/{2,}/g, '/').replace(/\/+$/, '');
  let endpointHint = '';
  if (/\/chat\/completions$/i.test(pathname)) {
    pathname = pathname.replace(/\/chat\/completions$/i, '');
    endpointHint = 'chat';
  } else if (/\/responses$/i.test(pathname)) {
    pathname = pathname.replace(/\/responses$/i, '');
    endpointHint = 'responses';
  } else if (/\/messages$/i.test(pathname)) {
    pathname = pathname.replace(/\/messages$/i, '');
    endpointHint = 'messages';
  }
  parsed.pathname = pathname || '/';
  const apiBase = parsed.href.replace(/\/+$/, '');
  return { apiBase, endpointHint };
}

function buildProviderUrl(apiBase, endpoint = '') {
  const normalized = normalizeProviderBaseUrl(apiBase).apiBase;
  const rawEndpoint = String(endpoint || '').trim();
  if (/^[a-z][a-z\d+.-]*:/i.test(rawEndpoint)
    || rawEndpoint.startsWith('//')) {
    throw new Error('API 端点格式无效');
  }
  const relativeEndpoint = rawEndpoint.replace(/^\/+/, '');
  if (relativeEndpoint.split('/').includes('..')) throw new Error('API 端点格式无效');
  const base = new URL(`${normalized}/`);
  const result = new URL(relativeEndpoint, base);
  if (result.origin !== base.origin || !result.pathname.startsWith(base.pathname)) {
    throw new Error('API 端点不能离开 Base URL');
  }
  return result;
}

function defaultResolvedMode(providerId, apiBase) {
  const detected = PROVIDER_IDS.includes(providerId) ? providerId : detectProvider(apiBase);
  return detected === 'alibaba' ? 'responses' : 'chat';
}

function openCodeGoModelMode(model) {
  const normalized = String(model || '').trim().toLowerCase().replace(/^opencode-go\//, '');
  if (normalized === 'gpt-5.6-luna') return 'responses';
  if (/^(?:minimax-m(?:3|2\.[57])|qwen3\.(?:8-max|7-(?:max|plus)|6-plus))$/.test(normalized)) return 'messages';
  return 'chat';
}

function resolveProviderMode(profile = {}, capabilities = {}, model = profile.model) {
  const apiMode = API_MODES.includes(profile.apiMode) ? profile.apiMode : 'auto';
  if (apiMode !== 'auto') return apiMode;
  if (detectProvider(profile.apiBase) === 'opencode-go') return openCodeGoModelMode(model);
  if (capabilities.responses === true) return 'responses';
  if (capabilities.chat === true && capabilities.responses === false) return 'chat';
  if (RESOLVED_API_MODES.includes(profile.resolvedMode)) return profile.resolvedMode;
  return defaultResolvedMode(profile.id, profile.apiBase);
}

function buildGenerationUrl(profile = {}, capabilities = {}, model = profile.model) {
  const mode = resolveProviderMode(profile, capabilities, model);
  return buildProviderUrl(profile.apiBase, API_MODE_ENDPOINTS[mode]);
}

function sanitizeName(value, fallback) {
  const name = typeof value === 'string' ? value.trim().replace(/\s+/g, ' ') : '';
  return (name || fallback).slice(0, 60);
}

function sanitizeProfile(value, defaults, { id, builtIn } = {}) {
  const profile = value && typeof value === 'object' ? value : {};
  let normalizedBase;
  try {
    normalizedBase = normalizeProviderBaseUrl(profile.apiBase || defaults.apiBase);
  } catch (error) {
    normalizedBase = normalizeProviderBaseUrl(defaults.apiBase);
  }
  const apiMode = API_MODES.includes(profile.apiMode) ? profile.apiMode : 'auto';
  const hintedMode = normalizedBase.endpointHint;
  const storedResolvedMode = RESOLVED_API_MODES.includes(profile.resolvedMode)
    ? profile.resolvedMode
    : '';
  const resolvedMode = apiMode === 'auto'
    ? (hintedMode || storedResolvedMode || defaultResolvedMode(id, normalizedBase.apiBase))
    : apiMode;
  return {
    name: sanitizeName(profile.name, defaults.name),
    apiBase: normalizedBase.apiBase,
    apiKey: typeof profile.apiKey === 'string' ? profile.apiKey.trim() : '',
    model: typeof profile.model === 'string' && profile.model.trim()
      ? profile.model.trim().slice(0, 200)
      : defaults.model,
    apiMode,
    resolvedMode,
    builtIn: Boolean(builtIn)
  };
}

function sanitizeCustomId(value) {
  const id = String(value || '').trim().toLowerCase();
  return /^custom-[a-z0-9][a-z0-9-]{0,63}$/.test(id) ? id : '';
}

function slugifyProviderName(value) {
  const slug = String(value || '')
    .normalize('NFKD')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
  return slug || 'provider';
}

function nextCustomProviderId(name, providers = {}) {
  const base = `custom-${slugifyProviderName(name)}`;
  if (!providers[base]) return base;
  let suffix = 2;
  while (providers[`${base}-${suffix}`]) suffix += 1;
  return `${base}-${suffix}`;
}

function sanitizeTaskModels(value, providers, activeProvider) {
  const source = value && typeof value === 'object' ? value : {};
  return Object.fromEntries(TASK_MODEL_IDS.map(taskId => {
    const route = source[taskId] && typeof source[taskId] === 'object' ? source[taskId] : {};
    const requestedProvider = typeof route.providerId === 'string' ? route.providerId : '';
    const providerId = requestedProvider && providers[requestedProvider] ? requestedProvider : '';
    const model = providerId && typeof route.model === 'string'
      ? route.model.trim().slice(0, 200)
      : '';
    return [taskId, { providerId, model }];
  }));
}

function finiteClamped(value, fallback, minimum, maximum, round = false) {
  const parsed = Number(value);
  const normalized = Number.isFinite(parsed) ? parsed : fallback;
  const clamped = Math.min(maximum, Math.max(minimum, normalized));
  return round ? Math.round(clamped) : clamped;
}

function sanitizeContextPolicy(value) {
  const source = value && typeof value === 'object' ? value : {};
  const contextWindowTokens = finiteClamped(
    source.contextWindowTokens,
    DEFAULT_CONTEXT_POLICY.contextWindowTokens,
    4096,
    4000000,
    true
  );
  const reservedOutputTokens = finiteClamped(
    source.reservedOutputTokens,
    DEFAULT_CONTEXT_POLICY.reservedOutputTokens,
    256,
    Math.max(256, contextWindowTokens - 1024),
    true
  );
  const compressionThreshold = finiteClamped(
    source.compressionThreshold,
    DEFAULT_CONTEXT_POLICY.compressionThreshold,
    0.5,
    0.99
  );
  return {
    contextWindowTokens,
    reservedOutputTokens,
    compressionThreshold,
    postCompressionRatio: finiteClamped(
      source.postCompressionRatio,
      DEFAULT_CONTEXT_POLICY.postCompressionRatio,
      0.5,
      compressionThreshold
    ),
    recentMessages: finiteClamped(source.recentMessages, DEFAULT_CONTEXT_POLICY.recentMessages, 4, 80, true),
    maxImages: finiteClamped(source.maxImages, DEFAULT_CONTEXT_POLICY.maxImages, 0, 24, true)
  };
}

function resolveTaskModel(settings, taskId) {
  if (!TASK_MODEL_IDS.includes(taskId)) throw new Error('未知的后台任务类型');
  const normalized = sanitizeProviderSettings(settings);
  const route = normalized.taskModels[taskId];
  const providerId = route.providerId || normalized.activeProvider;
  const profile = normalized.providers[providerId] || normalized.providers[normalized.activeProvider];
  return {
    providerId,
    model: route.model || profile.model,
    apiBase: profile.apiBase,
    apiKey: profile.apiKey,
    apiMode: profile.apiMode,
    resolvedMode: resolveProviderMode(profile, {}, route.model || profile.model)
  };
}

function sanitizeProviderSettings(settings = {}, { normalizeReasoningEffort } = {}) {
  const source = settings && typeof settings === 'object' ? settings : {};
  const storedProfiles = source.providers && typeof source.providers === 'object' ? source.providers : {};
  const legacyProfile = {
    apiBase: source.apiBase,
    apiKey: source.apiKey,
    model: source.model
  };
  const hasLegacyProfile = source.schemaVersion !== 3
    && ['apiBase', 'apiKey', 'model'].some(key => typeof source[key] === 'string');
  const requestedActiveProvider = typeof source.activeProvider === 'string'
    ? source.activeProvider
    : '';
  const detectedLegacyProvider = detectProvider(source.apiBase);
  const legacyProvider = requestedActiveProvider && storedProfiles[requestedActiveProvider]
    ? requestedActiveProvider
    : (PROVIDER_IDS.includes(detectedLegacyProvider) ? detectedLegacyProvider : 'deepseek');
  const providers = {};

  for (const id of PROVIDER_IDS) {
    const profileSource = hasLegacyProfile && id === legacyProvider
      ? { ...(storedProfiles[id] || {}), ...legacyProfile }
      : storedProfiles[id];
    providers[id] = sanitizeProfile(profileSource, PROVIDER_DEFAULTS[id], { id, builtIn: true });
  }

  for (const [storedId, storedProfile] of Object.entries(storedProfiles)) {
    const id = sanitizeCustomId(storedId);
    if (!id || PROVIDER_IDS.includes(id) || !storedProfile || typeof storedProfile !== 'object') continue;
    const fallback = {
      name: '自定义供应商',
      apiBase: 'https://api.example.com',
      apiKey: '',
      model: 'model-name'
    };
    const profileSource = hasLegacyProfile && id === legacyProvider
      ? { ...storedProfile, ...legacyProfile }
      : storedProfile;
    providers[id] = sanitizeProfile(profileSource, fallback, { id, builtIn: false });
  }

  const storedOrder = Array.isArray(source.providerOrder) ? source.providerOrder : [];
  const customIds = Object.keys(providers).filter(id => !PROVIDER_IDS.includes(id));
  const providerOrder = [
    ...PROVIDER_IDS,
    ...storedOrder.filter(id => customIds.includes(id)),
    ...customIds.filter(id => !storedOrder.includes(id))
  ];
  const activeProvider = providers[requestedActiveProvider]
    ? requestedActiveProvider
    : (hasLegacyProfile && providers[legacyProvider] ? legacyProvider : 'deepseek');
  const active = providers[activeProvider];
  const taskModels = sanitizeTaskModels(source.taskModels, providers, activeProvider);
  const contextPolicy = sanitizeContextPolicy(source.contextPolicy);
  const normalizeEffort = typeof normalizeReasoningEffort === 'function'
    ? normalizeReasoningEffort
    : value => ['off', 'low', 'high', 'max'].includes(value) ? value : 'high';
  return {
    schemaVersion: 3,
    activeProvider,
    providerOrder,
    providers,
    taskModels,
    contextPolicy,
    apiBase: active.apiBase,
    apiKey: active.apiKey,
    model: active.model,
    reasoningEffort: normalizeEffort(source.reasoningEffort),
    videoAutoplay: typeof source.videoAutoplay === 'boolean' ? source.videoAutoplay : true,
    alwaysOnTop: source.alwaysOnTop === true
  };
}

function validateProviderDraft(draft = {}) {
  const name = sanitizeName(draft.name, '');
  if (!name) throw new Error('请输入供应商名称');
  const normalizedBase = normalizeProviderBaseUrl(draft.apiBase);
  const model = typeof draft.model === 'string' ? draft.model.trim() : '';
  if (!model) throw new Error('请输入模型名称');
  return { name, normalizedBase, model };
}

function addCustomProvider(settings, draft) {
  const current = sanitizeProviderSettings(settings);
  const valid = validateProviderDraft(draft);
  const requestedId = sanitizeCustomId(draft?.id);
  const id = requestedId && !current.providers[requestedId]
    ? requestedId
    : nextCustomProviderId(valid.name, current.providers);
  const providers = {
    ...current.providers,
    [id]: sanitizeProfile({
      ...draft,
      apiBase: valid.normalizedBase.apiBase,
      resolvedMode: valid.normalizedBase.endpointHint || draft.resolvedMode
    }, {
      name: valid.name,
      apiBase: valid.normalizedBase.apiBase,
      apiKey: '',
      model: valid.model
    }, { id, builtIn: false })
  };
  return sanitizeProviderSettings({
    ...current,
    activeProvider: id,
    providerOrder: [...current.providerOrder, id],
    providers
  });
}

function updateProvider(settings, providerId, patch = {}) {
  const current = sanitizeProviderSettings(settings);
  if (!current.providers[providerId]) throw new Error('供应商不存在');
  const original = current.providers[providerId];
  const merged = { ...original, ...patch };
  if (original.builtIn) merged.name = original.name;
  const valid = validateProviderDraft(merged);
  const providers = {
    ...current.providers,
    [providerId]: sanitizeProfile({
      ...merged,
      apiBase: valid.normalizedBase.apiBase,
      resolvedMode: valid.normalizedBase.endpointHint || merged.resolvedMode
    }, {
      name: original.name,
      apiBase: original.apiBase,
      apiKey: original.apiKey,
      model: original.model
    }, { id: providerId, builtIn: original.builtIn })
  };
  return sanitizeProviderSettings({ ...current, providers });
}

function deleteCustomProvider(settings, providerId) {
  const current = sanitizeProviderSettings(settings);
  const profile = current.providers[providerId];
  if (!profile) return current;
  if (profile.builtIn || PROVIDER_IDS.includes(providerId)) {
    throw new Error('内置供应商不能删除');
  }
  const providers = { ...current.providers };
  delete providers[providerId];
  const providerOrder = current.providerOrder.filter(id => id !== providerId);
  const activeProvider = current.activeProvider === providerId ? 'deepseek' : current.activeProvider;
  return sanitizeProviderSettings({ ...current, activeProvider, providerOrder, providers });
}

module.exports = {
  API_MODES,
  API_MODE_ENDPOINTS,
  DEFAULT_CONTEXT_POLICY,
  PROVIDER_DEFAULTS,
  PROVIDER_IDS,
  TASK_MODEL_IDS,
  addCustomProvider,
  buildGenerationUrl,
  buildProviderUrl,
  deleteCustomProvider,
  detectProvider,
  isLoopbackHostname,
  nextCustomProviderId,
  normalizeProviderBaseUrl,
  openCodeGoModelMode,
  resolveProviderMode,
  resolveTaskModel,
  sanitizeContextPolicy,
  sanitizeProviderSettings,
  updateProvider
};
