(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ContextManager = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const IMAGE_MARKDOWN = /!\[([^\]\n]{0,160})\]\((https:\/\/[^)\s]{1,2048})\)/gi;
  const CONTEXT_OMISSION = '【上下文说明】部分较早消息已因上下文上限省略；历史摘要覆盖首次阶段，以下为最近对话。';
  const DEFAULT_CONTEXT_WINDOW_TOKENS = 128000;
  const DEFAULT_RESERVED_OUTPUT_TOKENS = 8192;
  const DEFAULT_COMPRESSION_THRESHOLD = 0.95;
  const DEFAULT_POST_COMPRESSION_RATIO = 0.82;
  const DEFAULT_IMAGE_METADATA_TOKENS = 96;

  function finiteNumber(value, fallback) {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  }

  function clamp(value, minimum, maximum) {
    return Math.min(maximum, Math.max(minimum, value));
  }

  function estimateTextTokens(value) {
    const source = String(value || '');
    if (!source) return 0;
    let ideographs = 0;
    let latinOrDigits = 0;
    let punctuation = 0;
    let whitespace = 0;
    let other = 0;

    for (const character of source) {
      const codePoint = character.codePointAt(0);
      const eastAsian = (codePoint >= 0x3400 && codePoint <= 0x9fff)
        || (codePoint >= 0xf900 && codePoint <= 0xfaff)
        || (codePoint >= 0x20000 && codePoint <= 0x323af)
        || (codePoint >= 0x3040 && codePoint <= 0x30ff)
        || (codePoint >= 0xac00 && codePoint <= 0xd7af);
      if (eastAsian) {
        ideographs += 1;
      } else if ((codePoint >= 0x30 && codePoint <= 0x39)
        || (codePoint >= 0x41 && codePoint <= 0x5a)
        || (codePoint >= 0x61 && codePoint <= 0x7a)
        || codePoint === 0x5f) {
        latinOrDigits += 1;
      } else if (codePoint <= 0x20 || codePoint === 0xa0 || codePoint === 0x3000) {
        whitespace += 1;
      } else if (codePoint < 0x80) {
        punctuation += 1;
      } else {
        other += 1;
      }
    }

    // Mixed Chinese/code conversations tokenize differently between providers.
    // This intentionally leans slightly conservative so the 95% guard remains useful.
    return Math.max(1, Math.ceil(
      ideographs
      + latinOrDigits / 3.5
      + punctuation / 2
      + whitespace / 12
      + other
    ));
  }

  function contentTokenEstimate(content, options = {}) {
    if (!Array.isArray(content)) return estimateTextTokens(content);
    const imageMetadataTokens = Math.max(0, finiteNumber(options.imageMetadataTokens, DEFAULT_IMAGE_METADATA_TOKENS));
    return content.reduce((total, part) => {
      if (!part || typeof part !== 'object') return total;
      if (typeof part.text === 'string') return total + estimateTextTokens(part.text);
      if (typeof part.input_text === 'string') return total + estimateTextTokens(part.input_text);
      if (part.type === 'input_image' || part.type === 'image_url') return total + imageMetadataTokens;
      return total;
    }, 0);
  }

  // Message content is append-only while streaming, so a content-length check is
  // enough to invalidate the per-message estimate cache.
  const tokenEstimateCache = new WeakMap();

  function estimateMessageTokens(message, options = {}) {
    const imageMetadataTokens = Math.max(0, finiteNumber(options.imageMetadataTokens, DEFAULT_IMAGE_METADATA_TOKENS));
    const structuralTokens = Math.max(0, finiteNumber(options.messageOverheadTokens, 4));
    const cacheable = message && typeof message === 'object' && typeof message.content === 'string';
    if (cacheable) {
      const cached = tokenEstimateCache.get(message);
      if (cached
        && cached.contentLength === message.content.length
        && cached.artifactsRef === message.artifacts
        && cached.imageMetadataTokens === imageMetadataTokens
        && cached.structuralTokens === structuralTokens) {
        return cached.value;
      }
    }
    const artifacts = messageArtifacts(message);
    const value = Math.ceil(structuralTokens
      + contentTokenEstimate(message?.content, options)
      + artifacts.length * imageMetadataTokens);
    if (cacheable) {
      tokenEstimateCache.set(message, {
        contentLength: message.content.length,
        artifactsRef: message.artifacts,
        imageMetadataTokens,
        structuralTokens,
        value
      });
    }
    return value;
  }

  function normalizeContextBudget(options = {}) {
    const requestedWindow = finiteNumber(
      options.contextWindowTokens ?? options.modelContextTokens,
      DEFAULT_CONTEXT_WINDOW_TOKENS
    );
    const contextWindowTokens = Math.max(512, Math.floor(requestedWindow));
    const defaultReserve = Math.min(DEFAULT_RESERVED_OUTPUT_TOKENS, Math.floor(contextWindowTokens / 4));
    const reservedOutputTokens = clamp(
      Math.floor(finiteNumber(options.reservedOutputTokens, defaultReserve)),
      0,
      Math.max(0, contextWindowTokens - 256)
    );
    const availableInputTokens = Math.max(256, contextWindowTokens - reservedOutputTokens);
    const compressionThreshold = clamp(
      finiteNumber(options.compressionThreshold, DEFAULT_COMPRESSION_THRESHOLD),
      0.5,
      0.99
    );
    const compressionTriggerTokens = Math.max(1, Math.floor(availableInputTokens * compressionThreshold));
    const postCompressionRatio = clamp(
      finiteNumber(options.postCompressionRatio, DEFAULT_POST_COMPRESSION_RATIO),
      0.5,
      compressionThreshold
    );
    const targetInputTokens = Math.max(1, Math.floor(availableInputTokens * postCompressionRatio));

    return {
      contextWindowTokens,
      reservedOutputTokens,
      availableInputTokens,
      compressionThreshold,
      compressionTriggerTokens,
      postCompressionRatio,
      targetInputTokens
    };
  }

  function estimateContextUsage(messages, options = {}) {
    const budget = normalizeContextBudget(options);
    const snapshot = Array.isArray(messages) ? messages : [];
    const tokenEstimator = typeof options.tokenEstimator === 'function'
      ? options.tokenEstimator
      : message => estimateMessageTokens(message, options);
    let estimatedInputTokens = 0;
    const imageUrls = new Set();
    for (const message of snapshot) {
      const estimate = Number(tokenEstimator(message));
      if (Number.isFinite(estimate) && estimate > 0) estimatedInputTokens += Math.ceil(estimate);
      for (const image of messageArtifacts(message)) imageUrls.add(image.url);
    }
    estimatedInputTokens = Math.max(0, Math.ceil(estimatedInputTokens));
    const remainingInputTokens = Math.max(0, budget.availableInputTokens - estimatedInputTokens);
    const tokensUntilCompression = Math.max(0, budget.compressionTriggerTokens - estimatedInputTokens);

    return {
      estimatedInputTokens,
      remainingInputTokens,
      tokensUntilCompression,
      utilization: budget.availableInputTokens
        ? Math.min(1, estimatedInputTokens / budget.availableInputTokens)
        : 1,
      rawUtilization: budget.availableInputTokens
        ? estimatedInputTokens / budget.availableInputTokens
        : 1,
      thresholdProgress: budget.compressionTriggerTokens
        ? Math.min(1, estimatedInputTokens / budget.compressionTriggerTokens)
        : 1,
      overInputBudget: estimatedInputTokens > budget.availableInputTokens,
      shouldCompress: estimatedInputTokens >= budget.compressionTriggerTokens,
      messageCount: snapshot.length,
      imageCount: imageUrls.size,
      budget
    };
  }

  function planContextCompression(messages, options = {}) {
    const usage = estimateContextUsage(messages, options);
    return {
      shouldCompact: usage.shouldCompress,
      reason: usage.shouldCompress ? 'token-threshold' : 'none',
      usage,
      targetInputTokens: usage.budget.targetInputTokens
    };
  }

  function normalizeArtifact(value) {
    if (!value || value.type !== 'image') return null;
    const url = String(value.url || '').trim();
    if (!/^https:\/\//i.test(url) || url.length > 2048) return null;
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password) return null;
    } catch (error) {
      return null;
    }
    const title = String(value.title || '参考图片').replace(/\s+/g, ' ').trim().slice(0, 120) || '参考图片';
    return { type: 'image', url, title };
  }

  function normalizeArtifacts(value, limit = 8) {
    const result = [];
    const seen = new Set();
    for (const item of Array.isArray(value) ? value : []) {
      const artifact = normalizeArtifact(item);
      if (!artifact || seen.has(artifact.url)) continue;
      seen.add(artifact.url);
      result.push(artifact);
      if (result.length >= limit) break;
    }
    return result;
  }

  function markdownArtifacts(content) {
    const result = [];
    const seen = new Set();
    const source = String(content || '');
    IMAGE_MARKDOWN.lastIndex = 0;
    let match;
    while ((match = IMAGE_MARKDOWN.exec(source))) {
      const artifact = normalizeArtifact({ type: 'image', title: match[1], url: match[2] });
      if (!artifact || seen.has(artifact.url)) continue;
      seen.add(artifact.url);
      result.push(artifact);
      if (result.length >= 16) break;
    }
    return result;
  }

  const artifactCache = new WeakMap();

  function messageArtifacts(message) {
    const cacheable = message && typeof message === 'object';
    const contentLength = cacheable && typeof message.content === 'string' ? message.content.length : -1;
    if (cacheable) {
      const cached = artifactCache.get(message);
      if (cached && cached.contentLength === contentLength && cached.artifactsRef === message.artifacts) {
        return cached.value;
      }
    }
    const seen = new Set();
    const value = [];
    for (const artifact of [...normalizeArtifacts(message?.artifacts, 8), ...markdownArtifacts(message?.content)]) {
      if (seen.has(artifact.url)) continue;
      seen.add(artifact.url);
      value.push(artifact);
      if (value.length >= 16) break;
    }
    if (cacheable) {
      artifactCache.set(message, { contentLength, artifactsRef: message.artifacts, value });
    }
    return value;
  }

  function selectTailByTokenBudget(messages, maxTokens, maxMessages, minMessages, options = {}) {
    const result = [];
    let tokens = 0;
    const tokenEstimator = typeof options.tokenEstimator === 'function'
      ? options.tokenEstimator
      : message => estimateMessageTokens(message, options);
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      if (result.length >= maxMessages) break;
      const message = messages[index];
      const estimated = Number(tokenEstimator(message));
      const messageTokens = Number.isFinite(estimated) && estimated > 0 ? Math.ceil(estimated) : 0;
      if (result.length >= minMessages && tokens + messageTokens > maxTokens) break;
      result.push(message);
      tokens += messageTokens;
    }
    return result.reverse();
  }

  function applyImageBudget(messages, maxImages) {
    const allowedByIndex = new Map();
    const selected = [];
    const seen = new Set();
    for (let index = messages.length - 1; index >= 0 && selected.length < maxImages; index -= 1) {
      const allowed = new Set();
      const artifacts = messageArtifacts(messages[index]);
      for (let artifactIndex = artifacts.length - 1; artifactIndex >= 0 && selected.length < maxImages; artifactIndex -= 1) {
        const artifact = artifacts[artifactIndex];
        if (seen.has(artifact.url)) continue;
        seen.add(artifact.url);
        allowed.add(artifact.url);
        selected.push(artifact);
      }
      if (allowed.size) allowedByIndex.set(index, allowed);
    }
    return { allowedByIndex, images: selected.reverse() };
  }

  function contentWithImages(message, allowedUrls) {
    let content = String(message?.content || '');
    const artifacts = messageArtifacts(message);
    const knownUrls = new Set(artifacts.map(item => item.url));
    IMAGE_MARKDOWN.lastIndex = 0;
    content = content.replace(IMAGE_MARKDOWN, (match, title, url) => {
      return knownUrls.has(url) && !allowedUrls.has(url) ? '' : match;
    });
    content = content.replace(/\n*#{2,4}\s*参考图片\s*$/u, '').replace(/\n{3,}/g, '\n\n').trim();

    const missing = artifacts.filter(item => allowedUrls.has(item.url) && !content.includes(item.url));
    if (missing.length) {
      const index = missing.map(item => `- ${item.title}：${item.url}`).join('\n');
      content = `${content}\n\n【图片上下文】\n${index}`.trim();
    }
    return content;
  }

  function withBoundedImages(messages, maxImages) {
    const { allowedByIndex, images } = applyImageBudget(messages, maxImages);
    const usageMessages = [];
    const outputMessages = messages.map((message, index) => {
      const allowedUrls = allowedByIndex.get(index) || new Set();
      const content = contentWithImages(message, allowedUrls);
      usageMessages.push({
        role: message.role,
        content,
        artifacts: messageArtifacts(message).filter(item => allowedUrls.has(item.url))
      });
      return { role: message.role, content };
    });
    return {
      images,
      messages: outputMessages,
      usageMessages
    };
  }

  function buildManagedContext(messages, options = {}) {
    const snapshot = (Array.isArray(messages) ? messages : [])
      .filter(message => message && ['system', 'user', 'assistant'].includes(message.role))
      .map(message => ({
        role: message.role,
        content: String(message.content || ''),
        artifacts: normalizeArtifacts(message.artifacts, 8)
      }));
    const plan = planContextCompression(snapshot, options);
    const requestedMaxImages = options.maxImages === undefined ? 12 : finiteNumber(options.maxImages, 12);
    const maxImages = Math.max(0, Math.min(24, Math.floor(requestedMaxImages)));
    const compact = plan.shouldCompact;
    let selected = snapshot;

    if (compact) {
      const stableSystemMessages = snapshot.filter(message => message.role === 'system');
      const contextSummary = String(options.contextSummary || '').trim();
      const summaryMessageCount = Math.min(snapshot.length, Math.max(0, Number(options.summaryMessageCount) || 0));
      const prefix = [...stableSystemMessages];
      const firstUser = snapshot.find(message => message.role === 'user');
      let candidates;
      if (contextSummary && summaryMessageCount > 0) {
        // 原始题面是解题的核心约束，即使已被摘要覆盖也完整保留。
        if (firstUser && snapshot.indexOf(firstUser) < summaryMessageCount) prefix.push(firstUser);
        prefix.push({
          role: 'system',
          content: `【历史对话摘要】\n${contextSummary}\n\n请将该摘要视为此前对话的事实记录，并结合后续消息继续回答。`
        });
        candidates = snapshot.slice(summaryMessageCount).filter(message => message.role !== 'system');
      } else {
        if (firstUser) prefix.push(firstUser);
        candidates = snapshot.filter(message => message.role !== 'system' && message !== firstUser);
      }
      const omission = { role: 'system', content: CONTEXT_OMISSION };
      const fixedPrefix = [...prefix, omission];
      const fixedTokens = estimateContextUsage(fixedPrefix, options).estimatedInputTokens;
      const tailTokenBudget = Math.max(1, plan.targetInputTokens - fixedTokens);
      const requestedRecentMessages = Number.isFinite(Number(options.recentMessages))
        ? Math.max(1, Math.floor(Number(options.recentMessages)))
        : Infinity;
      const tailMessageLimit = Math.max(1, requestedRecentMessages - fixedPrefix.length);
      const minRecentMessages = clamp(
        Math.floor(finiteNumber(options.minRecentMessages, 6)),
        1,
        tailMessageLimit
      );
      const tail = selectTailByTokenBudget(
        candidates,
        tailTokenBudget,
        tailMessageLimit,
        minRecentMessages,
        options
      );
      selected = [...fixedPrefix, ...tail];
    }

    const bounded = withBoundedImages(selected, maxImages);
    const outputUsage = estimateContextUsage(bounded.usageMessages, options);
    const snapshotSet = new Set(snapshot);
    const selectedSources = new Set(selected.filter(message => snapshotSet.has(message)));
    return {
      messages: bounded.messages,
      images: bounded.images,
      stats: {
        compacted: compact,
        compactionReason: plan.reason,
        inputMessages: snapshot.length,
        outputMessages: bounded.messages.length,
        omittedMessages: snapshot.filter(message => !selectedSources.has(message)).length,
        imageCount: bounded.images.length,
        estimatedInputTokens: outputUsage.estimatedInputTokens,
        remainingInputTokens: outputUsage.remainingInputTokens,
        tokensUntilCompression: outputUsage.tokensUntilCompression,
        utilization: outputUsage.utilization,
        thresholdProgress: outputUsage.thresholdProgress,
        overInputBudget: outputUsage.overInputBudget,
        budget: outputUsage.budget,
        originalUsage: plan.usage,
        usage: outputUsage
      }
    };
  }

  function messagesForSummary(messages, maxImages = 12) {
    const snapshot = (Array.isArray(messages) ? messages : [])
      .filter(message => message && ['user', 'assistant'].includes(message.role));
    return withBoundedImages(snapshot, maxImages).messages;
  }

  function supportsVisualInputModel(model) {
    const normalized = String(model || '').trim().toLowerCase();
    return /(?:^|[-_.])(?:vl|vision)(?:$|[-_.])/.test(normalized)
      || /(?:qwen|deepseek).*?(?:vl|vision|omni)/.test(normalized);
  }

  function attachImagesToResponsesMessages(messages, images, model) {
    const clean = (Array.isArray(messages) ? messages : []).map(message => ({
      role: message.role,
      content: message.content
    }));
    const safeImages = normalizeArtifacts(images, 4);
    if (!safeImages.length || !supportsVisualInputModel(model)) return clean;
    const target = clean.map(message => message.role).lastIndexOf('user');
    if (target < 0 || typeof clean[target].content !== 'string') return clean;
    clean[target] = {
      ...clean[target],
      content: [
        { type: 'input_text', text: clean[target].content },
        ...safeImages.map(image => ({ type: 'input_image', image_url: image.url, detail: 'auto' }))
      ]
    };
    return clean;
  }

  function attachImagesToChatMessages(messages, images, model) {
    const clean = (Array.isArray(messages) ? messages : []).map(message => ({
      role: message.role,
      content: message.content
    }));
    const safeImages = normalizeArtifacts(images, 4);
    if (!safeImages.length || !supportsVisualInputModel(model)) return clean;
    const target = clean.map(message => message.role).lastIndexOf('user');
    if (target < 0) return clean;
    const sourceContent = clean[target].content;
    const textParts = Array.isArray(sourceContent)
      ? sourceContent
      : [{ type: 'text', text: String(sourceContent || '') }];
    clean[target] = {
      ...clean[target],
      content: [
        ...textParts,
        ...safeImages.map(image => ({ type: 'image_url', image_url: { url: image.url, detail: 'auto' } }))
      ]
    };
    return clean;
  }

  return {
    DEFAULT_CONTEXT_WINDOW_TOKENS,
    DEFAULT_RESERVED_OUTPUT_TOKENS,
    DEFAULT_COMPRESSION_THRESHOLD,
    estimateTextTokens,
    estimateMessageTokens,
    normalizeContextBudget,
    estimateContextUsage,
    planContextCompression,
    normalizeArtifact,
    normalizeArtifacts,
    markdownArtifacts,
    messageArtifacts,
    buildManagedContext,
    messagesForSummary,
    supportsVisualInputModel,
    attachImagesToResponsesMessages,
    attachImagesToChatMessages
  };
});
