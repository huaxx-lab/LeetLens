'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { buildDisplayProfile, displayProfileChanged } = require('../src/platform/display-profile');

function display(id, width, height, scaleFactor = 2) {
  return { id, workArea: { width, height }, scaleFactor };
}

test('display reading scale grows continuously with the available work area', () => {
  const internal = buildDisplayProfile(display(1, 1512, 982));
  const external = buildDisplayProfile(display(2, 1920, 1080, 1));

  assert.equal(internal.uiScale, 1.003);
  assert.ok(external.uiScale > internal.uiScale);
  assert.ok(external.uiScale > 1.35);
  assert.ok(external.uiScale < 1.42);
});

test('display reading scale is clamped for very large and small work areas', () => {
  assert.equal(buildDisplayProfile(display(1, 1280, 720)).uiScale, 1);
  assert.equal(buildDisplayProfile(display(2, 3840, 2160, 1)).uiScale, 1.5);
});

test('profile updates only when display identity or scale changes', () => {
  const previous = buildDisplayProfile(display(1, 1512, 982));
  assert.equal(displayProfileChanged(previous, { ...previous }), false);
  assert.equal(displayProfileChanged(previous, { ...previous, id: '2' }), true);
  assert.equal(displayProfileChanged(previous, { ...previous, uiScale: 1.1 }), true);
  assert.equal(displayProfileChanged(previous, { ...previous }, true), true);
});
