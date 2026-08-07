'use strict';

const BASE_WORK_AREA_DIAGONAL = 1800;
const MAX_UI_SCALE = 1.5;

function buildDisplayProfile(display) {
  const width = Math.max(1, Number(display?.workArea?.width) || 1);
  const height = Math.max(1, Number(display?.workArea?.height) || 1);
  const diagonal = Math.hypot(width, height);
  const proportionalScale = 1 + ((diagonal / BASE_WORK_AREA_DIAGONAL) - 1) * 1.7;
  const uiScale = Math.min(MAX_UI_SCALE, Math.max(1, proportionalScale));
  return {
    id: String(display?.id ?? ''),
    width,
    height,
    scaleFactor: Math.max(1, Number(display?.scaleFactor) || 1),
    uiScale: Number(uiScale.toFixed(3))
  };
}

function displayProfileChanged(previous, next, force = false) {
  return Boolean(force || !previous || previous.id !== next.id || previous.uiScale !== next.uiScale);
}

module.exports = {
  BASE_WORK_AREA_DIAGONAL,
  MAX_UI_SCALE,
  buildDisplayProfile,
  displayProfileChanged
};
