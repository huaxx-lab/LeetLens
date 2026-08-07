'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const packageJson = require('../package.json');
const packageLock = require('../package-lock.json');
const installer = fs.readFileSync(path.join(root, 'scripts', 'replace-macos-app.js'), 'utf8');
const readmeZh = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
const readmeEn = fs.readFileSync(path.join(root, 'README.en.md'), 'utf8');

test('release version stays synchronized across package metadata and readmes', () => {
  assert.equal(packageLock.version, packageJson.version);
  assert.equal(packageLock.packages[''].version, packageJson.version);
  assert.match(readmeZh, new RegExp(`version-v${packageJson.version.replaceAll('.', '\\.')}`));
  assert.match(readmeEn, new RegExp(`version-v${packageJson.version.replaceAll('.', '\\.')}`));
});

test('macOS installer quits the old process before replacement and reopens after signing', () => {
  const quitIndex = installer.indexOf('quitRunningApp(resolvedDestination)');
  const trashIndex = installer.indexOf("spawnSync('/usr/bin/trash'");
  assert.ok(quitIndex >= 0 && trashIndex > quitIndex);
  assert.match(installer, /timeout:\s*3_000/);
  assert.match(installer, /CFBundleDisplayName/);
  assert.match(installer, /process\.kill\(pid, 'SIGTERM'\)/);
  assert.match(installer, /attempt < 3/);
  assert.doesNotMatch(installer, /SIGKILL/);

  const installCommand = packageJson.scripts['install:mac'];
  const signIndex = installCommand.lastIndexOf('sign-macos-bundle.js');
  const openIndex = installCommand.lastIndexOf('open');
  assert.ok(signIndex >= 0 && openIndex > signIndex);
});
