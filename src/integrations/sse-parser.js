'use strict';

const { StringDecoder } = require('string_decoder');

const MAX_SSE_BUFFER_CHARS = 1024 * 1024;
const MAX_SSE_EVENT_CHARS = 4 * 1024 * 1024;

function limitError(message) {
  return Object.assign(new Error(message), { code: 'SSE_LIMIT' });
}

class SSEParser {
  constructor(onData, options = {}) {
    this.onData = onData;
    this.buffer = '';
    this.dataLines = [];
    this.dataLength = 0;
    this.decoder = new StringDecoder('utf8');
    this.maxBufferedChars = Math.max(1024, Number(options.maxBufferedChars) || MAX_SSE_BUFFER_CHARS);
    this.maxEventChars = Math.max(1024, Number(options.maxEventChars) || MAX_SSE_EVENT_CHARS);
  }

  push(chunk) {
    this.buffer += Buffer.isBuffer(chunk) ? this.decoder.write(chunk) : String(chunk);
    let newlineIndex = this.buffer.indexOf('\n');
    while (newlineIndex !== -1) {
      this.processLine(this.buffer.slice(0, newlineIndex));
      this.buffer = this.buffer.slice(newlineIndex + 1);
      newlineIndex = this.buffer.indexOf('\n');
    }
    if (this.buffer.length > this.maxBufferedChars) throw limitError('SSE 单行数据超过安全上限');
  }

  finish() {
    this.buffer += this.decoder.end();
    if (this.buffer.length > this.maxBufferedChars) throw limitError('SSE 单行数据超过安全上限');
    if (this.buffer) this.processLine(this.buffer);
    this.buffer = '';
    this.flush();
  }

  processLine(rawLine) {
    const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine;
    if (!line) {
      this.flush();
      return;
    }
    if (line.startsWith(':') || !line.startsWith('data:')) return;
    const value = line.slice(5).replace(/^ /, '');
    this.dataLength += value.length + (this.dataLines.length ? 1 : 0);
    if (this.dataLength > this.maxEventChars) throw limitError('SSE 事件数据超过安全上限');
    this.dataLines.push(value);
  }

  flush() {
    if (!this.dataLines.length) return;
    const data = this.dataLines.join('\n');
    this.dataLines = [];
    this.dataLength = 0;
    this.onData(data);
  }
}

module.exports = { SSEParser };
