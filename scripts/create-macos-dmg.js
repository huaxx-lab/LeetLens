'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

if (process.platform !== 'darwin') process.exit(0);

const archivePath = process.argv[2] ? path.resolve(process.argv[2]) : '';
const dmgPath = process.argv[3] ? path.resolve(process.argv[3]) : '';
const appName = 'LeetCode 助手.app';

if (!archivePath || !fs.existsSync(archivePath)) {
  throw new Error(`Signed macOS archive is missing: ${archivePath || '(empty path)'}`);
}
if (!dmgPath) throw new Error('DMG output path is required.');

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'leetcode-helper-dmg-'));
const stagingPath = path.join(temporaryRoot, 'staging');
const appPath = path.join(stagingPath, appName);

try {
  fs.mkdirSync(stagingPath, { recursive: true });
  execFileSync('/usr/bin/ditto', ['-x', '-k', archivePath, stagingPath], { stdio: 'inherit' });
  if (!fs.existsSync(appPath)) throw new Error(`Archive does not contain ${appName}.`);

  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', appPath], { stdio: 'inherit' });
  fs.symlinkSync('/Applications', path.join(stagingPath, 'Applications'));

  fs.mkdirSync(path.dirname(dmgPath), { recursive: true });
  fs.rmSync(dmgPath, { force: true });
  execFileSync('/usr/bin/hdiutil', [
    'create',
    '-volname', 'LeetCode 助手',
    '-srcfolder', stagingPath,
    '-format', 'UDZO',
    '-ov',
    dmgPath
  ], { stdio: 'inherit' });

  console.log(`Created macOS disk image: ${dmgPath}`);
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
