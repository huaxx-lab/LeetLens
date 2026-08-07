'use strict';

const TOOL_NAMES = '(web_search|web_extractor|code_interpreter|web_search_image|image_search)';

function cleanLabel(value, maxLength = 120) {
  return String(value || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, maxLength);
}

function safeResponseArtifacts(item) {
  const artifacts = [];
  const seen = new Set();
  let visited = 0;
  const visit = (value, depth = 0, insideImageResult = false) => {
    if (!value || depth > 6 || visited++ > 500) return;
    if (typeof value === 'string') {
      const source = value.trim();
      if (insideImageResult && source.length <= 128 * 1024 && /^[\[{]/.test(source)) {
        try { visit(JSON.parse(source), depth + 1, true); } catch (error) {}
      }
      return;
    }
    if (typeof value !== 'object') return;
    if (Array.isArray(value)) {
      for (const child of value.slice(0, 40)) visit(child, depth + 1, insideImageResult);
      return;
    }
    const nodeType = String(value.type || value.kind || '').toLowerCase();
    const imageResult = insideImageResult || /image|web_search_image/.test(nodeType);
    const title = cleanLabel(value.title || value.name || value.alt || '工具图片');
    for (const [key, child] of Object.entries(value)) {
      if (typeof child === 'string' && /^https:\/\//i.test(child)) {
        const imageLike = (imageResult && key.toLowerCase() === 'url')
          || /image|thumbnail|preview|original/i.test(key)
          || /image|thumbnail/.test(nodeType)
          || /\.(?:png|jpe?g|webp|gif)(?:\?|$)/i.test(child);
        if (imageResult && imageLike && !seen.has(child) && artifacts.length < 12) {
          seen.add(child);
          artifacts.push({ type: 'image', url: child.slice(0, 2048), title });
        }
      } else {
        visit(child, depth + 1, imageResult);
      }
    }
  };
  visit(item);
  return artifacts;
}

function responseToolEvent(event) {
  const eventType = String(event?.type || '');
  const direct = eventType.match(new RegExp(`^response\\.${TOOL_NAMES}_call\\.(in_progress|searching|interpreting|completed|failed)$`));
  if (direct) return { name: direct[1], status: direct[2] };
  if (!/^response\.output_item\.(added|done)$/.test(eventType)) return null;
  const item = event?.item && typeof event.item === 'object' ? event.item : {};
  const itemType = String(item.type || '').match(new RegExp(`^${TOOL_NAMES}_call$`))?.[1];
  if (!itemType) return null;
  const status = eventType.endsWith('.done')
    ? (item.status === 'failed' ? 'failed' : 'completed')
    : String(item.status || 'in_progress');
  return { name: itemType, status };
}

module.exports = { safeResponseArtifacts, responseToolEvent };
