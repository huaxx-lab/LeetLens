'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const sourcePaths = require('./helpers/source-paths');

const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');
const styles = fs.readFileSync(sourcePaths.styles, 'utf8');
const main = fs.readFileSync(sourcePaths.main, 'utf8');
const preload = fs.readFileSync(sourcePaths.preload, 'utf8');
const nativeGlass = fs.readFileSync(path.join(__dirname, '..', 'native', 'liquid_glass.mm'), 'utf8');

test('macOS fullscreen uses one native titlebar and native transition', () => {
  assert.match(main, /titleBarStyle:\s*'hiddenInset'/);
  assert.match(main, /titleBarOverlay:\s*true/);
  assert.match(main, /fullscreenable:\s*true/);
  assert.match(main, /setFullScreen\(true\)/);
  assert.match(main, /window\.on\('enter-full-screen'/);
  assert.match(main, /window\.on\('leave-full-screen'/);
  assert.match(main, /function showNativeWindowButtons\(window\)[\s\S]*setWindowButtonVisibility\(true\)/);
  assert.match(main, /window\.on\('enter-full-screen'[\s\S]*showNativeWindowButtons\(window\)/);
  assert.match(main, /window\.on\('leave-full-screen'[\s\S]*showNativeWindowButtons\(window\)/);
  assert.match(nativeGlass, /NSToolbar/);
  assert.match(nativeGlass, /NSWindowWillEnterFullScreenNotification/);
  assert.match(nativeGlass, /NSWindowDidExitFullScreenNotification/);
  assert.match(nativeGlass, /NSApplicationPresentationAutoHideToolbar/);
  assert.match(nativeGlass, /willUseFullScreenPresentationOptions/);
  assert.match(nativeGlass, /self\.toolbar\.visible = self\.navigationActive && fullscreen/);
  assert.doesNotMatch(main, /setSimpleFullScreen|isSimpleFullScreen/);
  assert.match(preload, /platform:\s*process\.platform/);
  assert.match(renderer, /uses-native-titlebar/);
  assert.match(styles, /body\.uses-native-titlebar \.mac-controls\s*\{[^}]*visibility:\s*hidden/s);
});

test('fullscreen regions live in the macOS application menu', () => {
  assert.match(main, /app\.setName\('LeetCode 助手'\)/);
  assert.match(main, /function installApplicationMenu\(\)/);
  assert.match(main, /Menu\.setApplicationMenu\(Menu\.buildFromTemplate\(template\)\)/);
  assert.match(main, /label:\s*'导航'/);
  for (const action of ['chat', 'today', 'leetcode', 'library', 'insights', 'usage', 'history', 'settings']) {
    assert.match(main, new RegExp(`dispatchAppMenuAction\\('${action}'\\)`));
  }
  assert.match(preload, /onAppMenuAction/);
  assert.match(renderer, /onAppMenuAction/);
  assert.doesNotMatch(main, /native-titlebar-action|installNativeTitlebarActions/);
});

test('fullscreen preserves a bottom scroll anchor without flashing the composer', () => {
  assert.match(renderer, /const shouldKeepBottom = nearBottom\(\)/);
  assert.match(renderer, /beginWindowTransition\(shouldKeepBottom\)/);
  assert.match(renderer, /function scheduleWindowTransitionBottom\(\)/);
  assert.match(renderer, /if \(shouldPinBottom\) \{\s*suppressScrollChromeUntil = performance\.now\(\) \+ 240;\s*autoFollow = true;\s*pinToBottom\(4\);/);
  assert.match(renderer, /scheduleWindowTransitionEnd\(700\)/);
  assert.match(renderer, /scheduleWindowTransitionBottom\(\);\s*scheduleWindowTransitionEnd\(140\);/);
  assert.doesNotMatch(styles, /body\.is-window-transition \.input-bar/);
  assert.doesNotMatch(styles, /body\.is-scrolling \.input-bar/);
  assert.doesNotMatch(styles, /body\.is-scrolling \.titlebar(?:\s|\{)/);
});

test('fullscreen zen composer returns on pointer movement and stays while hovered', () => {
  assert.match(renderer, /function revealZenChromeFromPointer\(event\)/);
  assert.match(renderer, /document\.addEventListener\('pointermove', revealZenChromeFromPointer, \{ passive: true \}\)/);
  assert.match(renderer, /inputBar\.addEventListener\('pointerenter', revealZenChrome\)/);
  assert.match(renderer, /inputBar\.matches\(':hover, :focus-within'\)/);
  assert.match(styles, /body\.is-zen \.input-bar:hover,\s*body\.is-zen \.input-bar:focus-within\s*\{[^}]*opacity:\s*1;[^}]*pointer-events:\s*auto;[^}]*transform:\s*none;/s);
});

test('fullscreen overlays cover the hidden titlebar area', () => {
  assert.match(styles, /body\.is-fullscreen \.overlay\s*\{\s*inset:\s*0;/);
});

test('renderer does not add a second fullscreen titlebar animation or gray strip', () => {
  assert.match(renderer, /navigator\.windowControlsOverlay/);
  assert.match(renderer, /addEventListener\('geometrychange', syncWindowControlsOverlay\)/);
  assert.match(renderer, /native-titlebar-visible/);
  assert.match(styles, /body\.is-fullscreen \.titlebar\s*\{\s*display:\s*none;/);
  assert.doesNotMatch(styles, /body\.is-fullscreen\.native-titlebar-visible \.overlay/);
  assert.doesNotMatch(renderer, /fullscreen-top-reveal|fullscreen-native-chrome|menu-bar-up|menuBarHeight/);
  assert.doesNotMatch(styles, /fullscreen-top-reveal|fullscreen-native-chrome|menu-bar-up|--menu-bar-h/);
  assert.match(main, /installNativeNavigationToolbar/);
  assert.match(preload, /setNativeLearningNavigation/);
  assert.match(styles, /body\.is-fullscreen \.learning-overlay \.learning-header\s*\{[^}]*display:\s*none/s);
  assert.doesNotMatch(renderer, /syncFullscreenLearningHeaderReveal|learning-header-revealed|clientY\s*<=\s*92/);
  assert.doesNotMatch(renderer, /handleFullscreenPointerMove|scheduleLearningHeaderCollapse|is-header-collapsed/);
  assert.doesNotMatch(styles, /is-header-collapsed/);
});
