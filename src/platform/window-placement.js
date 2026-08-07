'use strict';

function finiteInteger(value, fallback = 0) {
  return Number.isFinite(Number(value)) ? Math.round(Number(value)) : fallback;
}

function fitBoundsToWorkArea(bounds, workArea, options = {}) {
  const padding = Math.max(0, finiteInteger(options.padding, 8));
  const minimumWidth = Math.max(1, finiteInteger(options.minimumWidth, 420));
  const minimumHeight = Math.max(1, finiteInteger(options.minimumHeight, 360));
  const area = {
    x: finiteInteger(workArea?.x),
    y: finiteInteger(workArea?.y),
    width: Math.max(1, finiteInteger(workArea?.width, 1)),
    height: Math.max(1, finiteInteger(workArea?.height, 1))
  };
  const maximumWidth = Math.max(minimumWidth, area.width - padding * 2);
  const maximumHeight = Math.max(minimumHeight, area.height - padding * 2);
  const width = Math.min(maximumWidth, Math.max(minimumWidth, finiteInteger(bounds?.width, minimumWidth)));
  const height = Math.min(maximumHeight, Math.max(minimumHeight, finiteInteger(bounds?.height, minimumHeight)));
  const maximumX = area.x + area.width - width - padding;
  const maximumY = area.y + area.height - height - padding;
  return {
    x: Math.max(area.x + padding, Math.min(finiteInteger(bounds?.x, area.x + padding), maximumX)),
    y: Math.max(area.y + padding, Math.min(finiteInteger(bounds?.y, area.y + padding), maximumY)),
    width,
    height
  };
}

function sameBounds(left, right) {
  return ['x', 'y', 'width', 'height'].every(key => finiteInteger(left?.[key]) === finiteInteger(right?.[key]));
}

module.exports = { fitBoundsToWorkArea, sameBounds };
