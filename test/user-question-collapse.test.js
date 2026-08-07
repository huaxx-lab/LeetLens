'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const sourcePaths = require('./helpers/source-paths');

const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');
const styles = fs.readFileSync(sourcePaths.styles, 'utf8');

test('long user questions collapse the first time they are measured', () => {
  const block = renderer.match(/function wireUserCollapse[\s\S]*?\n  function clearMessages/)?.[0] || '';
  assert.match(block, /aria-expanded="false"/);
  assert.match(block, /<span>展开<\/span>/);
  assert.match(block, /if \(!longSeen && body\.scrollHeight > userCollapseCap\(body\) \+ 4\)/);
  assert.match(block, /messageEl\.classList\.add\('user-collapsed'\)/);
  assert.match(block, /const collapsed = messageEl\.classList\.toggle\('user-collapsed'\)/);
});

test('collapsed questions pass trackpad scrolling to the conversation', () => {
  const rule = styles.match(/\.message\.is-user\.user-collapsed \.msg-body\s*\{([^}]*)\}/)?.[1] || '';
  assert.match(rule, /overflow:\s*clip/);
  assert.match(rule, /overscroll-behavior:\s*auto/);
  assert.doesNotMatch(rule, /overflow:\s*hidden/);
});
