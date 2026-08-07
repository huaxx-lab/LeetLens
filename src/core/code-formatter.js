'use strict';

const MAX_FORMAT_SOURCE_LENGTH = 50000;

let formatterPromise = null;

function loadFormatters() {
  if (!formatterPromise) {
    formatterPromise = Promise.resolve().then(() => ({
      prettier: require('prettier'),
      javaPlugin: require('prettier-plugin-java')
    }));
  }
  return formatterPromise;
}

function formatterOptions(language) {
  if (language === 'java') return { parser: 'java', useJavaPlugin: true };
  if (language === 'javascript' || language === 'js' || language === 'jsx') return { parser: 'babel' };
  if (language === 'typescript' || language === 'ts' || language === 'tsx') return { parser: 'typescript' };
  return null;
}

function normalizeCursorOffset(value, sourceLength) {
  const offset = Number(value);
  if (!Number.isFinite(offset)) return 0;
  return Math.max(0, Math.min(sourceLength, Math.trunc(offset)));
}

async function formatCode(source, requestedLanguage, cursorOffset = 0) {
  const code = String(source || '');
  const language = String(requestedLanguage || '').trim().toLowerCase();
  if (code.length > MAX_FORMAT_SOURCE_LENGTH) {
    throw new Error(`代码不能超过 ${MAX_FORMAT_SOURCE_LENGTH} 个字符`);
  }
  const options = formatterOptions(language);
  if (!options) {
    return { supported: false, language, formatted: code, cursorOffset: normalizeCursorOffset(cursorOffset, code.length) };
  }
  if (!code.trim()) {
    return { supported: true, language, formatted: code, cursorOffset: 0 };
  }

  const { prettier, javaPlugin } = await loadFormatters();
  const result = await prettier.formatWithCursor(code, {
    parser: options.parser,
    ...(options.useJavaPlugin ? { plugins: [javaPlugin] } : {}),
    cursorOffset: normalizeCursorOffset(cursorOffset, code.length),
    tabWidth: 4,
    useTabs: false,
    printWidth: 100,
    ...(options.parser !== 'java' ? { semi: true, singleQuote: true, trailingComma: 'none' } : {}),
    endOfLine: 'lf'
  });
  return {
    supported: true,
    language,
    formatted: result.formatted,
    cursorOffset: normalizeCursorOffset(result.cursorOffset, result.formatted.length)
  };
}

module.exports = {
  MAX_FORMAT_SOURCE_LENGTH,
  formatCode
};
