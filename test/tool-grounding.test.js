'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const sourcePaths = require('./helpers/source-paths');

const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');

test('system prompt grounds tool claims in the actual request', () => {
  assert.match(renderer, /本次请求实际提供的工具定义为准/);
  assert.match(renderer, /不得虚构“联网搜索按钮”/);
  assert.match(renderer, /当前供应商或模型在本应用中未接入联网搜索/);
});
