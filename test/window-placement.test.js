'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const sourcePaths = require('./helpers/source-paths');
const { fitBoundsToWorkArea, sameBounds } = require('../src/platform/window-placement');
const mainSource = fs.readFileSync(sourcePaths.main, 'utf8');

test('cross-display placement preserves a window size that already fits', () => {
  const bounds = { x: 1680, y: 90, width: 520, height: 620 };
  const workArea = { x: 1512, y: 0, width: 1920, height: 1080 };
  const fitted = fitBoundsToWorkArea(bounds, workArea);
  assert.equal(fitted.width, 520);
  assert.equal(fitted.height, 620);
});

test('placement clamps position without stretching width or height', () => {
  const fitted = fitBoundsToWorkArea(
    { x: 3300, y: 900, width: 520, height: 620 },
    { x: 1512, y: 0, width: 1920, height: 1080 }
  );
  assert.deepEqual(fitted, { x: 2904, y: 452, width: 520, height: 620 });
});

test('placement shrinks only when the saved window cannot fit', () => {
  const fitted = fitBoundsToWorkArea(
    { x: 0, y: 0, width: 2400, height: 1400 },
    { x: 0, y: 0, width: 1920, height: 1080 }
  );
  assert.deepEqual(fitted, { x: 8, y: 8, width: 1904, height: 1064 });
  assert.equal(sameBounds(fitted, { ...fitted }), true);
});

test('native fullscreen restores the saved normal frame after leaving', () => {
  const toggleBlock = mainSource.match(/ipcMain\.on\('toggle-fullscreen'[\s\S]*?\n\}\);/)?.[0] || '';
  assert.match(toggleBlock, /floatWindow\.setFullScreen\(true\)/);
  assert.match(toggleBlock, /floatWindow\.setFullScreen\(false\)/);
  assert.doesNotMatch(toggleBlock, /setSimpleFullScreen|setBounds\(/);
  assert.match(mainSource, /window\.on\('leave-full-screen'[\s\S]*restoreWindowPlacement\(window, restoreSnapshot, false\)/);
  assert.match(mainSource, /captureWindowPlacement\(window\)[\s\S]*window\.isFullScreen\(\)/);
  assert.match(mainSource, /settleWindowPlacement\(window\)[\s\S]*window\.isFullScreen\(\)/);
});
