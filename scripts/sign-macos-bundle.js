'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const appPath = process.argv[2] ? path.resolve(process.argv[2]) : '';
const archiveFlagIndex = process.argv.indexOf('--archive');
const archivePath = archiveFlagIndex >= 0 && process.argv[archiveFlagIndex + 1]
  ? path.resolve(process.argv[archiveFlagIndex + 1])
  : '';
const appIdentifier = 'io.github.huaxxlab.leetcode-ai-helper';

if (process.platform !== 'darwin') process.exit(0);
if (!appPath || !fs.existsSync(appPath)) throw new Error(`App bundle is missing: ${appPath || '(empty path)'}`);

function availableSigningIdentities() {
  const output = execFileSync('/usr/bin/security', ['find-identity', '-v', '-p', 'codesigning'], {
    encoding: 'utf8'
  });
  return [...output.matchAll(/^\s*\d+\)\s+[A-F0-9]+\s+"(.+)"\s*$/gm)].map(match => match[1]);
}

const requestedIdentity = String(process.env.MAC_CODE_SIGN_IDENTITY || '').trim();
const identities = availableSigningIdentities();
const signingIdentity = requestedIdentity || '-';

if (requestedIdentity && !identities.includes(requestedIdentity)) {
  throw new Error(`MAC_CODE_SIGN_IDENTITY is not a valid code-signing identity: ${requestedIdentity}`);
}

function signAndVerify(targetPath) {
  execFileSync('/usr/bin/xattr', ['-cr', targetPath], { stdio: 'inherit' });
  execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', signingIdentity, targetPath], { stdio: 'inherit' });

  if (signingIdentity === '-') {
    // Keep a stable bundle identifier for this exact local build. Ad-hoc signing
    // still cannot preserve TCC grants across rebuilt binaries, so the app also
    // guards automatic Accessibility prompts by the build CDHash.
    execFileSync('/usr/bin/codesign', [
      '--force',
      '--sign', '-',
      '--requirements', `=designated => identifier "${appIdentifier}"`,
      targetPath
    ], { stdio: 'inherit' });
    console.warn('Signed ad-hoc: macOS privacy permissions may require one renewal after a rebuilt app is installed.');
  } else {
    console.log(`Signed with persistent identity: ${signingIdentity}`);
  }

  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', targetPath], { stdio: 'inherit' });
}

if (!archivePath) {
  signAndVerify(appPath);
  process.exit(0);
}

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'leetcode-helper-sign-'));
const temporaryApp = path.join(temporaryRoot, path.basename(appPath));
try {
  execFileSync('/usr/bin/ditto', ['--norsrc', appPath, temporaryApp], { stdio: 'inherit' });
  signAndVerify(temporaryApp);
  fs.mkdirSync(path.dirname(archivePath), { recursive: true });
  fs.rmSync(archivePath, { force: true });
  execFileSync('/usr/bin/ditto', [
    '-c', '-k', '--norsrc', '--keepParent', temporaryApp, archivePath
  ], { stdio: 'inherit' });
  console.log(`Created signed macOS archive: ${archivePath}`);
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
