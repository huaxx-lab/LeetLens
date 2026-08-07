'use strict';

const path = require('node:path');

const root = path.join(__dirname, '..', '..');

module.exports = {
  root,
  main: path.join(root, 'src', 'main', 'main.js'),
  preload: path.join(root, 'src', 'main', 'preload.js'),
  renderer: path.join(root, 'src', 'renderer', 'renderer.js'),
  styles: path.join(root, 'src', 'renderer', 'styles.css'),
  index: path.join(root, 'src', 'renderer', 'index.html')
};
