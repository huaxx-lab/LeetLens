'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const sourcePaths = require('./helpers/source-paths');

const styles = fs.readFileSync(sourcePaths.styles, 'utf8');
const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');

test('fullscreen display rule does not override chat rail reveal opacity', () => {
  const fullscreenRule = styles.match(/body\.is-fullscreen \.chat-rail\.has-items\s*\{([^}]*)\}/)?.[1] || '';
  assert.doesNotMatch(fullscreenRule, /opacity\s*:/);
  assert.match(styles, /\.chat-rail\.has-items\.is-scroll-revealed\s*\{\s*opacity:\s*1;/);
});

test('chat rail geometry uses stable percentages instead of fullscreen size overrides', () => {
  assert.match(styles, /\.chat-rail-tick\s*\{[\s\S]*?width:\s*var\(--rail-tick-w, 48%\);/);
  assert.match(styles, /--rail-active-index/);
  assert.match(renderer, /railPerspectiveSpread = 3\.7 \+ largeDisplayRatio \* 1\.5/);
  assert.doesNotMatch(styles, /\.chat-rail\.is-priming/);
  const updateBlock = renderer.match(/function updateChatRailActive[\s\S]*?\n  function revealChatRailFromScroll/)?.[0] || '';
  assert.doesNotMatch(updateBlock, /chatRail\.client(?:Width|Height)|active\.offsetTop/);
});
