'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const sourcePaths = require('./helpers/source-paths');

const main = fs.readFileSync(sourcePaths.main, 'utf8');
const preload = fs.readFileSync(sourcePaths.preload, 'utf8');
const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');
const settings = fs.readFileSync(path.join(sourcePaths.root, 'src', 'integrations', 'provider-settings.js'), 'utf8');

test('main window pinning is user controlled and fullscreen covers the menu bar', () => {
  assert.match(settings, /alwaysOnTop: source\.alwaysOnTop === true/);
  assert.match(main, /let floatWindowPinned = false/);
  assert.match(main, /effectiveAlwaysOnTop = Boolean\(floatWindowPinned\)/);
  assert.doesNotMatch(main, /effectiveAlwaysOnTop = Boolean\([^\n]*(?:fullscreenActive|restoringFullscreen)/);
  assert.match(main, /try \{ await app\.dock\?\.show\(\); \} catch \(error\) \{\}/);
  assert.match(main, /try \{ app\.dock\?\.hide\(\); \} catch \(error\) \{\}/);
  assert.match(main, /alwaysOnTop: floatWindowPinned/);
  assert.match(main, /ipcMain\.handle\('set-always-on-top'/);
  assert.match(main, /else window\.setAlwaysOnTop\(false\)/);
  assert.match(main, /ipcMain\.handle\('get-window-layer-state'/);
  assert.match(main, /temporaryFullscreen: false/);
  assert.doesNotMatch(main, /function revealFloatWindow[\s\S]{0,500}setAlwaysOnTop\(true/);
  assert.doesNotMatch(main, /function revealFloatWindow[\s\S]{0,500}(?:moveTop|steal:\s*true)/);
  assert.match(preload, /setAlwaysOnTop:/);
  assert.match(renderer, /btn-pin-window/);
  assert.match(renderer, /renderWindowPinState\(await window\.api\.setAlwaysOnTop/);
});

test('native glass leaves pinning and workspace visibility to Electron', () => {
  const nativeGlass = fs.readFileSync(path.join(__dirname, '..', 'native', 'liquid_glass.mm'), 'utf8');
  assert.doesNotMatch(nativeGlass, /NSWindowCollectionBehaviorCanJoinAllSpaces/);
  assert.doesNotMatch(nativeGlass, /NSWindowCollectionBehaviorStationary/);
});
