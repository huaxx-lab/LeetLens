'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const projectRoot = path.resolve(__dirname, '..');
const appPath = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(projectRoot, 'dist.noindex', 'mac-arm64', 'LeetCode 助手.app');
const contentsPath = path.join(appPath, 'Contents');
const mainIcon = path.join(contentsPath, 'Resources', 'icon.icns');
const plistBuddy = '/usr/libexec/PlistBuddy';

function setPlistString(plistPath, key, value) {
  try {
    execFileSync(plistBuddy, ['-c', `Set :${key} ${value}`, plistPath], { stdio: 'ignore' });
  } catch {
    execFileSync(plistBuddy, ['-c', `Add :${key} string ${value}`, plistPath], { stdio: 'ignore' });
  }
}

if (process.platform !== 'darwin') process.exit(0);
if (!fs.existsSync(mainIcon)) throw new Error(`Packaged icon is missing: ${mainIcon}`);

// Some macOS surfaces fall back to Electron's resource name even though the
// main bundle points at icon.icns. Keep both names visually identical.
fs.copyFileSync(mainIcon, path.join(contentsPath, 'Resources', 'electron.icns'));

const frameworksPath = path.join(contentsPath, 'Frameworks');
const helperApps = fs.readdirSync(frameworksPath)
  .filter(name => /^LeetCode 助手 Helper(?: \(.+\))?\.app$/.test(name));

for (const helperName of helperApps) {
  const helperContents = path.join(frameworksPath, helperName, 'Contents');
  const helperResources = path.join(helperContents, 'Resources');
  const helperPlist = path.join(helperContents, 'Info.plist');
  const displayName = helperName.replace(/\.app$/, '');

  fs.mkdirSync(helperResources, { recursive: true });
  fs.copyFileSync(mainIcon, path.join(helperResources, 'icon.icns'));
  setPlistString(helperPlist, 'CFBundleIconFile', 'icon.icns');
  setPlistString(helperPlist, 'CFBundleName', displayName);
  setPlistString(helperPlist, 'CFBundleDisplayName', displayName);
}

console.log(`Prepared macOS bundle identity for ${1 + helperApps.length} app bundles.`);
