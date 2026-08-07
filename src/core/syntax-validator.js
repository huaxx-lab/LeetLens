'use strict';

const MAX_SOURCE_LENGTH = 50000;
const MAX_DIAGNOSTICS = 50;
const parserCache = new Map();

function normalizeLanguage(value) {
  const language = String(value || '').trim().toLocaleLowerCase('en-US');
  return {
    c: 'cpp',
    'c++': 'cpp',
    js: 'javascript',
    ts: 'typescript',
    py: 'python'
  }[language] || language;
}

function parserForLanguage(value) {
  const language = normalizeLanguage(value);
  if (parserCache.has(language)) return parserCache.get(language);
  let parser = null;
  if (language === 'java') parser = require('@lezer/java').parser;
  else if (language === 'python') parser = require('@lezer/python').parser;
  else if (language === 'cpp') parser = require('@lezer/cpp').parser;
  else if (language === 'javascript') parser = require('@lezer/javascript').parser;
  else if (language === 'typescript') parser = require('@lezer/javascript').parser.configure({ dialect: 'ts' });
  parserCache.set(language, parser);
  return parser;
}

function diagnosticMessage(code, from, to) {
  if (from === to) return from >= code.length ? '文件末尾缺少语法成分' : '此处缺少或未完成语法成分';
  const excerpt = code.slice(from, Math.min(to, from + 20)).replace(/\s+/g, ' ').trim();
  return excerpt ? `无法解析「${excerpt}」附近的语法` : '无法解析此处语法';
}

function validateSyntax(source, requestedLanguage) {
  const language = normalizeLanguage(requestedLanguage);
  const parser = parserForLanguage(language);
  if (!parser) return { supported: false, language, diagnostics: [] };
  const code = String(source || '');
  if (code.length > MAX_SOURCE_LENGTH) throw new Error(`代码不能超过 ${MAX_SOURCE_LENGTH} 个字符`);
  if (!code.trim()) return { supported: true, language, diagnostics: [] };

  const startedAt = performance.now();
  const diagnostics = [];
  const seen = new Set();
  try {
    const cursor = parser.parse(code).cursor();
    do {
      if (!cursor.type.isError) continue;
      const from = Math.max(0, Math.min(code.length, cursor.from));
      const to = Math.max(from, Math.min(code.length, cursor.to));
      const key = `${from}:${to}`;
      if (seen.has(key)) continue;
      seen.add(key);
      diagnostics.push({ from, to, severity: 'error', message: diagnosticMessage(code, from, to) });
    } while (diagnostics.length < MAX_DIAGNOSTICS && cursor.next());
  } catch (error) {
    diagnostics.push({
      from: 0,
      to: 0,
      severity: 'error',
      message: '代码结构过于复杂，无法完成本地语法检查'
    });
  }

  return {
    supported: true,
    language,
    diagnostics,
    parseMs: Math.max(0, performance.now() - startedAt)
  };
}

module.exports = {
  MAX_SOURCE_LENGTH,
  normalizeLanguage,
  validateSyntax
};
