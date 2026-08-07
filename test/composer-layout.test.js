'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const sourcePaths = require('./helpers/source-paths');

const styles = fs.readFileSync(sourcePaths.styles, 'utf8');

test('composer floats on a soft fog gradient as a single card', () => {
  const inputBar = styles.match(/\n\.input-bar\s*\{([^}]*)\}/)?.[1] || '';
  assert.match(inputBar, /right:\s*0/);
  assert.match(inputBar, /left:\s*0/);
  assert.match(inputBar, /bottom:\s*0/);
  assert.match(inputBar, /width:\s*100%/);
  assert.match(inputBar, /background:\s*linear-gradient\(to bottom, rgba\(247, 250, 251, 0\)/);
  assert.doesNotMatch(inputBar, /border-top/);
  assert.match(styles, /\.input-composer-shell\s*\{[^}]*width:\s*min\(calc\(100% - 24px\), 1020px\)/s);
  assert.match(styles, /\.composer-card\s*\{[^}]*border-radius:\s*16px/s);
  assert.match(styles, /body\.is-fullscreen \.input-bar\s*\{[^}]*width:\s*100%/s);
});
