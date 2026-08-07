'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  PROVIDER_DEFAULTS,
  buildGenerationUrl,
  detectProvider,
  normalizeProviderBaseUrl,
  openCodeGoModelMode,
  resolveTaskModel,
  sanitizeProviderSettings
} = require('../src/integrations/provider-settings');

test('OpenCode Go is a built-in provider with the official API root', () => {
  assert.equal(PROVIDER_DEFAULTS['opencode-go'].apiBase, 'https://opencode.ai/zen/go/v1');
  assert.equal(detectProvider('https://opencode.ai/zen/go/v1'), 'opencode-go');
  assert.deepEqual(normalizeProviderBaseUrl('https://opencode.ai/zen/go/v1/messages'), {
    apiBase: 'https://opencode.ai/zen/go/v1',
    endpointHint: 'messages'
  });
});

test('OpenCode Go models resolve to their required wire protocols', () => {
  assert.equal(openCodeGoModelMode('deepseek-v4-flash'), 'chat');
  assert.equal(openCodeGoModelMode('gpt-5.6-luna'), 'responses');
  assert.equal(openCodeGoModelMode('minimax-m3'), 'messages');
  assert.equal(openCodeGoModelMode('qwen3.8-max'), 'messages');

  const profile = { apiBase: 'https://opencode.ai/zen/go/v1', apiMode: 'auto' };
  assert.equal(buildGenerationUrl(profile, {}, 'gpt-5.6-luna').pathname, '/zen/go/v1/responses');
  assert.equal(buildGenerationUrl(profile, {}, 'minimax-m2.7').pathname, '/zen/go/v1/messages');
  assert.equal(buildGenerationUrl(profile, {}, 'kimi-k3').pathname, '/zen/go/v1/chat/completions');
});

test('task routing uses the routed OpenCode Go model protocol', () => {
  const settings = sanitizeProviderSettings({
    activeProvider: 'deepseek',
    providers: {
      'opencode-go': {
        apiBase: 'https://opencode.ai/zen/go/v1',
        apiKey: 'test-key',
        model: 'deepseek-v4-flash',
        apiMode: 'auto'
      }
    },
    taskModels: { learning: { providerId: 'opencode-go', model: 'qwen3.7-plus' } }
  });
  const route = resolveTaskModel(settings, 'learning');
  assert.equal(route.providerId, 'opencode-go');
  assert.equal(route.model, 'qwen3.7-plus');
  assert.equal(route.resolvedMode, 'messages');
});
