'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { formatCode } = require('../src/core/code-formatter');

test('Java formatting normalizes indentation, commas, operators, and braces', async () => {
  const result = await formatCode('class A{int add(int a,int b){return a+b;}}', 'java', 10);
  assert.equal(result.supported, true);
  assert.match(result.formatted, /int add\(int a, int b\)/);
  assert.match(result.formatted, /return a \+ b;/);
  assert.ok(result.cursorOffset >= 0 && result.cursorOffset <= result.formatted.length);
});

test('JavaScript and TypeScript use their syntax-aware Prettier parsers', async () => {
  const javascript = await formatCode('const add=(a,b)=>{return a+b}', 'javascript');
  const typescript = await formatCode('function add(a:number,b:number){return a+b}', 'typescript');
  assert.match(javascript.formatted, /const add = \(a, b\) =>/);
  assert.match(typescript.formatted, /add\(a: number, b: number\)/);
});

test('unknown languages remain untouched and report unsupported', async () => {
  const source = 'print(  1)';
  const result = await formatCode(source, 'python', 3);
  assert.equal(result.supported, false);
  assert.equal(result.formatted, source);
});
