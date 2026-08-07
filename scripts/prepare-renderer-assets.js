'use strict';

const fs = require('fs');
const path = require('path');

const projectRoot = path.resolve(__dirname, '..');
const outputRoot = path.join(projectRoot, '.renderer-assets');
const assetFiles = [
  'markdown-it/dist/markdown-it.min.js',
  '@highlightjs/cdn-assets/highlight.min.js',
  'dompurify/dist/purify.min.js',
  'dashjs/dist/modern/umd/dash.mediaplayer.min.js',
  'artplayer/dist/artplayer.js',
  'jsmind/style/jsmind.css',
  'jsmind/es6/jsmind.js',
  'codemirror/lib/codemirror.css',
  'codemirror/lib/codemirror.js',
  'codemirror/mode/clike/clike.js',
  'codemirror/mode/python/python.js',
  'codemirror/mode/javascript/javascript.js',
  'codemirror/addon/edit/matchbrackets.js',
  'codemirror/addon/edit/closebrackets.js',
  'codemirror/addon/hint/show-hint.css',
  'codemirror/addon/hint/show-hint.js',
  'codemirror/addon/hint/anyword-hint.js',
  'split.js/dist/split.min.js',
  'katex/dist/katex.min.css',
  'katex/dist/katex.min.js',
  'mermaid/dist/mermaid.min.js',
  'markdown-it/LICENSE',
  '@highlightjs/cdn-assets/LICENSE',
  'dompurify/LICENSE',
  'dashjs/LICENSE.md',
  'artplayer/package.json',
  'jsmind/LICENSE',
  'codemirror/LICENSE',
  'split.js/LICENSE.txt',
  'katex/LICENSE',
  'mermaid/LICENSE'
];
const assetDirectories = ['katex/dist/fonts', 'aliyun-aliplayer/build'];

if (path.dirname(outputRoot) !== projectRoot || path.basename(outputRoot) !== '.renderer-assets') {
  throw new Error(`Refusing to prepare an unexpected asset path: ${outputRoot}`);
}

fs.rmSync(outputRoot, { recursive: true, force: true });

if (process.argv.includes('--clean')) {
  console.log('Removed temporary renderer assets.');
  process.exit(0);
}

for (const relativePath of assetFiles) {
  const source = path.join(projectRoot, 'node_modules', relativePath);
  const target = path.join(outputRoot, relativePath);
  if (!fs.existsSync(source)) throw new Error(`Missing renderer dependency: ${relativePath}`);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(source, target);
}

for (const relativePath of assetDirectories) {
  const source = path.join(projectRoot, 'node_modules', relativePath);
  const target = path.join(outputRoot, relativePath);
  if (!fs.existsSync(source)) throw new Error(`Missing renderer dependency: ${relativePath}`);
  fs.cpSync(source, target, { recursive: true });
}

// AliPlayer's UMD header detects Electron's hidden CommonJS globals inside a
// sandboxed renderer and exports to that module instead of window. Replace only
// the distribution header; the official player factory remains byte-for-byte.
const aliplayerSource = path.join(projectRoot, 'node_modules', 'aliyun-aliplayer', 'build', 'aliplayer-min.js');
const aliplayerBrowserTarget = path.join(outputRoot, 'aliyun-aliplayer', 'build', 'browser-aliplayer.min.js');
const aliplayerOfficialRuntime = fs.readFileSync(aliplayerSource, 'utf8');
const aliplayerFactoryOffset = aliplayerOfficialRuntime.indexOf('(function(){');
if (aliplayerFactoryOffset < 0) throw new Error('AliPlayer browser factory was not found.');
const aliplayerLicense = aliplayerOfficialRuntime.slice(0, aliplayerOfficialRuntime.indexOf('\n') + 1);
const aliplayerFactory = aliplayerOfficialRuntime.slice(aliplayerFactoryOffset)
  .replace('!new Function("try {return this===window;}catch(e){ return false;}")()', '!1');
if (aliplayerFactory.includes('new Function("try {return this===window;}catch(e){ return false;}")')) {
  throw new Error('AliPlayer CSP-safe browser transform failed.');
}
const aliplayerBrowserRuntime = `${aliplayerLicense}!function(factory){window.Aliplayer=factory()}${aliplayerFactory}\n`;
fs.writeFileSync(aliplayerBrowserTarget, aliplayerBrowserRuntime);

console.log(`Prepared ${assetFiles.length} renderer assets and ${assetDirectories.length} asset directories.`);
