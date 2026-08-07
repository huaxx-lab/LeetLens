'use strict';

const path = require('node:path');
const { Worker } = require('node:worker_threads');
const { MAX_SOURCE_LENGTH } = require('./syntax-validator');
const { MAX_FORMAT_SOURCE_LENGTH } = require('./code-formatter');

const VALIDATION_TIMEOUT_MS = 2500;
const FORMAT_TIMEOUT_MS = 5000;

class SyntaxValidationService {
  constructor() {
    this.worker = null;
    this.nextId = 1;
    this.pending = new Map();
  }

  ensureWorker() {
    if (this.worker) return this.worker;
    const worker = new Worker(path.join(__dirname, 'syntax-validator-worker.js'));
    worker.on('message', message => this.handleMessage(message));
    worker.on('error', error => this.resetWorker(error));
    worker.on('exit', code => {
      if (this.worker !== worker) return;
      this.resetWorker(code === 0 ? null : new Error(`语法检查进程异常退出（${code}）`));
    });
    this.worker = worker;
    return worker;
  }

  validate(source, language) {
    const code = String(source || '');
    if (code.length > MAX_SOURCE_LENGTH) {
      return Promise.reject(new Error(`代码不能超过 ${MAX_SOURCE_LENGTH} 个字符`));
    }
    return this.run('validate', { source: code, language: String(language || '') }, VALIDATION_TIMEOUT_MS, '语法检查');
  }

  format(source, language, cursorOffset) {
    const code = String(source || '');
    if (code.length > MAX_FORMAT_SOURCE_LENGTH) {
      return Promise.reject(new Error(`代码不能超过 ${MAX_FORMAT_SOURCE_LENGTH} 个字符`));
    }
    return this.run('format', {
      source: code,
      language: String(language || ''),
      cursorOffset: Number(cursorOffset) || 0
    }, FORMAT_TIMEOUT_MS, '代码格式化');
  }

  run(type, payload, timeoutMs, label) {
    const id = this.nextId++;
    const worker = this.ensureWorker();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${label}超时，请缩短代码后重试`));
        this.restartWorker();
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer });
      worker.postMessage({ id, type, ...payload });
    });
  }

  handleMessage(message) {
    const request = this.pending.get(message?.id);
    if (!request) return;
    clearTimeout(request.timer);
    this.pending.delete(message.id);
    if (message.error) request.reject(Object.assign(new Error(message.error.message), { code: message.error.code }));
    else request.resolve(message.result);
  }

  resetWorker(error) {
    const worker = this.worker;
    this.worker = null;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error || new Error('语法检查进程已关闭'));
    }
    this.pending.clear();
    worker?.removeAllListeners();
  }

  restartWorker() {
    const worker = this.worker;
    this.resetWorker(new Error('语法检查已重新启动'));
    worker?.terminate().catch(() => {});
  }

  async close() {
    const worker = this.worker;
    this.resetWorker(new Error('应用正在退出'));
    if (worker) await worker.terminate();
  }
}

module.exports = {
  SyntaxValidationService
};
