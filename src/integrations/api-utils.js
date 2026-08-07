'use strict';

function normalizeUsage(usage, model) {
  if (!usage || typeof usage !== 'object') return null;
  const hasOwn = (object, key) => Object.hasOwn(object, key);
  const record = value => value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  const count = value => {
    const normalized = Number(value);
    return Number.isFinite(normalized) && normalized >= 0 ? normalized : 0;
  };
  const promptDetails = record(usage.prompt_tokens_details);
  const inputDetails = record(usage.input_tokens_details);
  const completionDetails = record(usage.completion_tokens_details);
  const outputDetails = record(usage.output_tokens_details);
  const cacheCreationDetails = record(
    inputDetails.cache_creation
    ?? promptDetails.cache_creation
    ?? usage.cache_creation
  );
  const hasDeepSeekCacheStats = hasOwn(usage, 'prompt_cache_hit_tokens')
    || hasOwn(usage, 'prompt_cache_miss_tokens');
  const deepSeekCacheHitTokens = count(usage.prompt_cache_hit_tokens);
  const deepSeekCacheMissTokens = count(usage.prompt_cache_miss_tokens);
  const promptTokens = count(
    usage.input_tokens
    ?? usage.prompt_tokens
    ?? (hasDeepSeekCacheStats ? deepSeekCacheHitTokens + deepSeekCacheMissTokens : 0)
  );
  const completionTokens = count(usage.output_tokens ?? usage.completion_tokens ?? 0);
  const totalTokens = count(usage.total_tokens ?? promptTokens + completionTokens);
  const cachedTokens = count(
    inputDetails.cached_tokens
    ?? promptDetails.cached_tokens
    ?? usage.cached_tokens
    ?? usage.cache_read_input_tokens
    ?? usage.prompt_cache_hit_tokens
    ?? 0
  );
  const cacheCreationTokens = count(
    inputDetails.cache_creation_input_tokens
    ?? promptDetails.cache_creation_input_tokens
    ?? cacheCreationDetails.ephemeral_5m_input_tokens
    ?? cacheCreationDetails.input_tokens
    ?? usage.cache_creation_input_tokens
    ?? 0
  );
  const cacheSupported = Boolean(
    hasOwn(inputDetails, 'cached_tokens')
    || hasOwn(promptDetails, 'cached_tokens')
    || hasOwn(inputDetails, 'cache_creation_input_tokens')
    || hasOwn(promptDetails, 'cache_creation_input_tokens')
    || hasOwn(cacheCreationDetails, 'ephemeral_5m_input_tokens')
    || hasOwn(cacheCreationDetails, 'input_tokens')
    || hasOwn(usage, 'cached_tokens')
    || hasOwn(usage, 'cache_read_input_tokens')
    || hasOwn(usage, 'cache_creation_input_tokens')
    || hasDeepSeekCacheStats
  );
  const isAnthropicStyle = hasOwn(usage, 'cache_read_input_tokens');
  const toolUsage = {};
  for (const [name, details] of Object.entries(record(usage.x_tools))) {
    const exactCount = details && typeof details === 'object'
      ? count(record(details).count)
      : count(details);
    if (exactCount > 0) toolUsage[name] = exactCount;
  }
  const toolCalls = Object.values(toolUsage).reduce((total, count) => total + count, 0);
  return {
    cacheStatsVersion: 2,
    model,
    promptTokens,
    completionTokens,
    totalTokens,
    cachedTokens,
    cacheCreationTokens,
    reasoningTokens: count(outputDetails.reasoning_tokens ?? completionDetails.reasoning_tokens),
    textTokens: count(outputDetails.text_tokens ?? completionDetails.text_tokens),
    toolCalls,
    toolUsage,
    exactRequests: 1,
    estimatedRequests: 0,
    cacheTrackedPromptTokens: cacheSupported
      ? promptTokens + (isAnthropicStyle ? cachedTokens + cacheCreationTokens : 0)
      : 0,
    cacheSupported
  };
}

function isAlibabaCompatibleUrl(apiUrl) {
  return /(^|\.)aliyuncs\.com$/i.test(apiUrl.hostname)
    && apiUrl.pathname.includes('/compatible-mode/');
}

function isDeepSeekCompatibleUrl(apiUrl) {
  return /(^|\.)deepseek\.com$/i.test(apiUrl.hostname);
}

function isAlibabaTokenPlanUrl(apiUrl) {
  return /^token-plan\.[a-z0-9-]+\.maas\.aliyuncs\.com$/i.test(apiUrl.hostname)
    && apiUrl.pathname.includes('/compatible-mode/');
}

function harnessToolsForModel(model) {
  const normalized = String(model || '').toLowerCase();
  if (normalized === 'qwen3.8-max-preview' || normalized === 'qwen3.7-plus') {
    return [
      { type: 'web_search' },
      { type: 'web_extractor' },
      { type: 'code_interpreter', container: { type: 'auto' } },
      { type: 'web_search_image' }
    ];
  }
  if (normalized === 'qwen3.7-max') {
    return [
      { type: 'web_search' },
      { type: 'web_extractor' },
      { type: 'code_interpreter', container: { type: 'auto' } }
    ];
  }
  return [];
}

function nativeResponseTools(apiUrl, model) {
  if (isDeepSeekCompatibleUrl(apiUrl) && String(model || '').toLowerCase() === 'deepseek-v4-flash') {
    return [{ type: 'web_search' }];
  }
  return isAlibabaCompatibleUrl(apiUrl) ? harnessToolsForModel(model) : [];
}

function supportsResponsesApi(apiUrl, model) {
  const normalized = String(model || '').toLowerCase();
  if (isDeepSeekCompatibleUrl(apiUrl)) return normalized === 'deepseek-v4-flash';
  if (isAlibabaCompatibleUrl(apiUrl)) {
    return normalized === 'qwen3.8-max-preview'
      || /^qwen3-(?:max|coder(?:-|$))/.test(normalized)
      || /^qwen3\.7-(?:max|plus)/.test(normalized)
      || /^qwen3\.6-(?:flash|35b-a3b)/.test(normalized)
      || /^qwen3\.5-(?:397b|122b|27b|35b|ocr)/.test(normalized)
      || /^qwen-(?:max|plus|flash|coder)/.test(normalized);
  }
  return false;
}

function normalizeReasoningEffort(value, fallback = 'high') {
  const normalized = String(value || '').trim().toLowerCase();
  return ['off', 'low', 'high', 'max'].includes(normalized) ? normalized : fallback;
}

function chatReasoningOptions(apiUrl, model, value, { forceDisabled = false } = {}) {
  const effort = forceDisabled ? 'off' : normalizeReasoningEffort(value);
  if (isDeepSeekCompatibleUrl(apiUrl)) {
    return effort === 'off'
      ? { thinking: { type: 'disabled' } }
      : { thinking: { type: 'enabled' }, reasoning_effort: effort };
  }
  if (isAlibabaCompatibleUrl(apiUrl) && /^qwen/i.test(String(model || ''))) {
    return { enable_thinking: effort !== 'off' };
  }
  return {};
}

function responsesReasoningOptions(apiUrl, model, value, { forceDisabled = false } = {}) {
  const effort = forceDisabled ? 'off' : normalizeReasoningEffort(value);
  if (isDeepSeekCompatibleUrl(apiUrl)) {
    return { reasoning: { effort: effort === 'off' ? 'none' : effort } };
  }
  if (isAlibabaCompatibleUrl(apiUrl)) {
    // qwen3.8-max-preview is currently the exception: its Token Plan endpoint
    // rejects disabled thinking. Other Qwen Responses models accept "none".
    const effective = effort === 'off' && String(model || '').toLowerCase() === 'qwen3.8-max-preview'
      ? 'low'
      : (effort === 'off' ? 'none' : effort);
    return { reasoning: { effort: effective } };
  }
  return {};
}

function estimatePromptTokens(text) {
  let asciiCharacters = 0;
  let nonAsciiCharacters = 0;
  for (const character of String(text || '')) {
    if (character.codePointAt(0) <= 0x7f) asciiCharacters += 1;
    else nonAsciiCharacters += 1;
  }
  return Math.ceil(asciiCharacters / 4 + nonAsciiCharacters);
}

function prepareMessagesForApi(messages, apiUrl) {
  if (!isAlibabaCompatibleUrl(apiUrl)) return messages;

  const userIndexes = messages
    .map((message, index) => message.role === 'user' ? index : -1)
    .filter(index => index >= 0);
  const candidateIndexes = new Set([userIndexes[0], userIndexes[userIndexes.length - 1]].filter(Number.isInteger));
  const markerIndexes = new Set();
  let prefixTokens = 0;
  messages.forEach((message, index) => {
    prefixTokens += estimatePromptTokens(typeof message.content === 'string' ? message.content : '');
    // Keep a margin above Alibaba's 1,024-token explicit-cache minimum. Shorter
    // requests remain unmarked so the provider can use its 256-token implicit cache.
    if (candidateIndexes.has(index) && prefixTokens >= 1100) markerIndexes.add(index);
  });

  return messages.map((message, index) => {
    if (!markerIndexes.has(index) || typeof message.content !== 'string') return message;
    return {
      ...message,
      content: [{
        type: 'text',
        text: message.content,
        cache_control: { type: 'ephemeral' }
      }]
    };
  });
}

function parseConversationSummary(content) {
  const text = String(content || '').trim().replace(/^```(?:json)?\s*|\s*```$/gi, '');
  const jsonText = text.match(/\{[\s\S]*\}/)?.[0] || text;
  const parsed = JSON.parse(jsonText);
  const clean = (value, maxLength) => String(value || '').replace(/\s+/g, ' ').trim().slice(0, maxLength);
  const title = clean(parsed.title, 32);
  const summary = clean(parsed.summary, 100);
  const context = clean(parsed.context, 1800);
  if (!title || !summary || !context) throw new Error('摘要字段不完整');
  return { title, summary, context };
}

module.exports = {
  normalizeUsage,
  prepareMessagesForApi,
  parseConversationSummary,
  isAlibabaCompatibleUrl,
  isDeepSeekCompatibleUrl,
  isAlibabaTokenPlanUrl,
  nativeResponseTools,
  supportsResponsesApi,
  normalizeReasoningEffort,
  chatReasoningOptions,
  responsesReasoningOptions,
  estimatePromptTokens
};
