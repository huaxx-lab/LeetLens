const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const waitBuffer = new Int32Array(new SharedArrayBuffer(4));

function runningAppPids(appPath) {
  const executablePrefix = `${path.join(appPath, 'Contents', 'MacOS')}${path.sep}`;
  const processes = spawnSync('/bin/ps', ['-axo', 'pid=,command='], { encoding: 'utf8' });
  if (processes.status !== 0) throw new Error(`failed to inspect running applications: ${processes.stderr || ''}`.trim());
  return String(processes.stdout || '')
    .split('\n')
    .map(line => line.trim().match(/^(\d+)\s+(.+)$/))
    .filter(match => match && match[2].startsWith(executablePrefix))
    .map(match => Number(match[1]));
}

function bundleDisplayName(appPath) {
  const infoPlist = path.join(appPath, 'Contents', 'Info.plist');
  for (const key of ['CFBundleDisplayName', 'CFBundleName']) {
    const result = spawnSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, infoPlist], { encoding: 'utf8' });
    const name = String(result.stdout || '').trim();
    if (result.status === 0 && name) return name;
  }
  throw new Error(`failed to read bundle display name: ${infoPlist}`);
}

function quitRunningApp(appPath) {
  const running = runningAppPids(appPath);
  if (!running.length) return false;

  const displayName = bundleDisplayName(appPath);
  const escapedName = displayName.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  const quit = spawnSync('/usr/bin/osascript', ['-e', `tell application "${escapedName}" to quit`], {
    encoding: 'utf8',
    timeout: 3_000,
    killSignal: 'SIGTERM'
  });

  let deadline = Date.now() + 2_000;
  while (Date.now() < deadline && runningAppPids(appPath).length) {
    Atomics.wait(waitBuffer, 0, 0, 100);
  }
  let remaining = runningAppPids(appPath);
  for (let attempt = 0; attempt < 3 && remaining.length; attempt += 1) {
    remaining.forEach(pid => {
      try {
        process.kill(pid, 'SIGTERM');
      } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
    });
    deadline = Date.now() + 2_000;
    while (Date.now() < deadline && runningAppPids(appPath).length) {
      Atomics.wait(waitBuffer, 0, 0, 100);
    }
    remaining = runningAppPids(appPath);
  }
  if (remaining.length) {
    const reason = quit.error?.code === 'ETIMEDOUT'
      ? 'quit request timed out'
      : `quit request failed: ${quit.stderr || quit.error?.message || 'unknown error'}`;
    throw new Error(`${reason}; repeated SIGTERM did not stop the app, refusing replacement (PIDs: ${remaining.join(', ')})`);
  }
  return true;
}

const [source, destination] = process.argv.slice(2);
if (!source || !destination) throw new Error('source and destination app paths are required');

const resolvedSource = path.resolve(source);
const resolvedDestination = path.resolve(destination);
if (!resolvedSource.endsWith('.app') || !resolvedDestination.endsWith('.app')) {
  throw new Error('only .app bundles can be replaced');
}
if (!fs.existsSync(resolvedSource)) throw new Error(`source app does not exist: ${resolvedSource}`);

if (fs.existsSync(resolvedDestination)) {
  quitRunningApp(resolvedDestination);
  const trashed = spawnSync('/usr/bin/trash', [resolvedDestination], { stdio: 'inherit' });
  if (trashed.status !== 0) throw new Error(`failed to move existing app to Trash: ${resolvedDestination}`);
}

const copied = spawnSync('/usr/bin/ditto', [resolvedSource, resolvedDestination], { stdio: 'inherit' });
if (copied.status !== 0) throw new Error(`failed to install app: ${resolvedDestination}`);
