#!/bin/bash
cd "$(dirname "$0")"
if [ -f .env.local ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.local
  set +a
fi
# macOS 27 需要对 Electron 做本地签名才能运行
xattr -cr node_modules/electron/dist/Electron.app 2>/dev/null
codesign --force --deep --sign - node_modules/electron/dist/Electron.app 2>/dev/null
node scripts/prepare-renderer-assets.js
npx electron .
