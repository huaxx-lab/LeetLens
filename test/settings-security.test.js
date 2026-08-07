'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const sourcePaths = require('./helpers/source-paths');

const main = fs.readFileSync(sourcePaths.main, 'utf8');
const gitignore = fs.readFileSync(path.join(sourcePaths.root, '.gitignore'), 'utf8');

test('provider API keys are encrypted before settings are persisted', () => {
  assert.match(main, /safeStorage/);
  assert.match(main, /ENCRYPTED_SETTING_PREFIX = 'safe-storage:v1:'/);
  assert.match(main, /safeStorage\.encryptString\(value\)/);
  assert.match(main, /safeStorage\.decryptString\(encrypted\)/);
  assert.match(main, /writeJsonAtomic\(SETTINGS_FILE, encryptSettingsSecrets\(sanitized\)\)/);
});

test('local secrets and generated application data are excluded from Git', () => {
  assert.match(gitignore, /^\.env\.\*$/m);
  assert.match(gitignore, /^!\.env\.example$/m);
  assert.match(gitignore, /^\*\.key$/m);
  assert.match(gitignore, /^node_modules\/$/m);
  assert.match(gitignore, /^dist\.noindex\/$/m);
});
