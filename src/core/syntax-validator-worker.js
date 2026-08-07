'use strict';

const { parentPort } = require('node:worker_threads');
const { validateSyntax } = require('./syntax-validator');
const { formatCode } = require('./code-formatter');

parentPort.on('message', async ({ id, type, source, language, cursorOffset }) => {
  try {
    const result = type === 'format'
      ? await formatCode(source, language, cursorOffset)
      : validateSyntax(source, language);
    parentPort.postMessage({ id, result });
  } catch (error) {
    parentPort.postMessage({
      id,
      error: {
        message: String(error?.message || '本地语法检查失败'),
        code: String(error?.code || '')
      }
    });
  }
});
