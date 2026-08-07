'use strict';

(function exposeStreamingSvg(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.StreamingSvg = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, () => {
  function tagName(tag) {
    const match = tag.match(/^<\/?\s*([A-Za-z][\w:.-]*)/);
    return match ? match[1].toLowerCase() : '';
  }

  function buildStreamingSvgSnapshot(source) {
    const text = String(source || '');
    const start = text.search(/<svg(?:\s|>)/i);
    if (start < 0) return '';

    const stack = [];
    let tagStart = -1;
    let quote = '';
    let inComment = false;
    let lastTagEnd = -1;
    let invalid = false;

    for (let index = start; index < text.length; index += 1) {
      const character = text[index];
      if (tagStart < 0) {
        if (character === '<') {
          tagStart = index;
          inComment = text.startsWith('<!--', index);
        }
        continue;
      }

      if (inComment) {
        if (!text.startsWith('-->', index)) continue;
        index += 2;
      } else if (quote) {
        if (character === quote) quote = '';
        continue;
      } else if (character === '"' || character === "'") {
        quote = character;
        continue;
      } else if (character !== '>') {
        continue;
      }

      const tag = text.slice(tagStart, index + 1);
      const name = tagName(tag);
      const isDeclaration = /^<\s*[!?]/.test(tag);
      const isClosing = /^<\s*\//.test(tag);
      const isSelfClosing = /\/\s*>$/.test(tag);

      if (name && !isDeclaration && !inComment) {
        if (isClosing) {
          if (stack[stack.length - 1] !== name) {
            invalid = true;
            break;
          }
          stack.pop();
        } else {
          if (!stack.length && name !== 'svg') {
            invalid = true;
            break;
          }
          if (!isSelfClosing) stack.push(name);
        }
      }

      lastTagEnd = index + 1;
      tagStart = -1;
      quote = '';
      inComment = false;
      if (!stack.length) break;
    }

    if (invalid || lastTagEnd < 0 || !stack.includes('svg') && !/<\/svg\s*>$/i.test(text.slice(start, lastTagEnd))) {
      return '';
    }

    const prefix = text.slice(start, lastTagEnd);
    if (!stack.length) return prefix;
    return `${prefix}${[...stack].reverse().map(name => `</${name}>`).join('')}`;
  }

  return { buildStreamingSvgSnapshot };
});
