'use strict';

function createStreamWatchdog({ firstByteTimeoutMs, idleTimeoutMs, onTimeout }) {
  if (typeof onTimeout !== 'function') throw new TypeError('onTimeout must be a function');

  const firstByteMs = Math.max(1, Number(firstByteTimeoutMs) || 1);
  const idleMs = Math.max(1, Number(idleTimeoutMs) || firstByteMs);
  let timer = null;
  let stopped = false;
  let receivedData = false;

  const arm = timeoutMs => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      if (stopped) return;
      stopped = true;
      onTimeout(receivedData ? 'idle' : 'first_byte');
    }, timeoutMs);
    timer.unref?.();
  };

  arm(firstByteMs);

  return {
    markActivity() {
      if (stopped) return;
      receivedData = true;
      arm(idleMs);
    },
    stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
      timer = null;
    }
  };
}

function retriableStreamError(code, extra = {}) {
  return {
    code: String(code || 'stream_interrupted'),
    retryable: true,
    ...extra
  };
}

module.exports = { createStreamWatchdog, retriableStreamError };
