'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const projectRoot = path.resolve(__dirname, '..');
const outputPath = path.join(projectRoot, 'dist.noindex');
const rendererAssetsPath = path.join(projectRoot, '.renderer-assets');
const packagedApp = path.join(outputPath, 'mac-arm64', 'LeetCode 助手.app');
const lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';

if (path.dirname(outputPath) !== projectRoot || path.basename(outputPath) !== 'dist.noindex') {
  throw new Error(`Refusing to clean an unexpected build path: ${outputPath}`);
}

if (process.platform === 'darwin' && fs.existsSync(packagedApp)) {
  try {
    execFileSync(lsregister, ['-u', packagedApp], { stdio: 'ignore' });
  } catch (error) {
    console.warn(`Failed to unregister temporary app: ${error.message}`);
  }
}

fs.rmSync(outputPath, { recursive: true, force: true });
fs.rmSync(rendererAssetsPath, { recursive: true, force: true });
console.log('Removed temporary macOS package output.');
