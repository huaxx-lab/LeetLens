const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const [source, destination] = process.argv.slice(2);
if (!source || !destination) throw new Error('source and destination app paths are required');

const resolvedSource = path.resolve(source);
const resolvedDestination = path.resolve(destination);
if (!resolvedSource.endsWith('.app') || !resolvedDestination.endsWith('.app')) {
  throw new Error('only .app bundles can be replaced');
}
if (!fs.existsSync(resolvedSource)) throw new Error(`source app does not exist: ${resolvedSource}`);

if (fs.existsSync(resolvedDestination)) {
  const trashed = spawnSync('/usr/bin/trash', [resolvedDestination], { stdio: 'inherit' });
  if (trashed.status !== 0) throw new Error(`failed to move existing app to Trash: ${resolvedDestination}`);
}

const copied = spawnSync('/usr/bin/ditto', [resolvedSource, resolvedDestination], { stdio: 'inherit' });
if (copied.status !== 0) throw new Error(`failed to install app: ${resolvedDestination}`);
