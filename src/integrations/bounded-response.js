'use strict';

const DEFAULT_MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

async function readBoundedResponseText(response, maxBytes = DEFAULT_MAX_RESPONSE_BYTES) {
  const limit = Math.max(1, Math.trunc(Number(maxBytes) || DEFAULT_MAX_RESPONSE_BYTES));
  const contentLength = Number(response?.headers?.get?.('content-length'));
  if (Number.isFinite(contentLength) && contentLength > limit) {
    await response.body?.cancel?.();
    throw new Error(`服务响应超过 ${limit} 字节上限`);
  }
  if (!response?.body) return '';

  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value?.byteLength) continue;
      total += value.byteLength;
      if (total > limit) {
        await reader.cancel('response too large');
        throw new Error(`服务响应超过 ${limit} 字节上限`);
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks, total).toString('utf8');
}

module.exports = {
  DEFAULT_MAX_RESPONSE_BYTES,
  readBoundedResponseText
};
