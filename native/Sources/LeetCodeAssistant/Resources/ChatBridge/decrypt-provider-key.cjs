const fs = require('node:fs');
const { app, safeStorage } = require('electron');

app.setName('LeetCode 助手');
if (app.dock) app.dock.hide();

const [, , settingsPath, providerId] = process.argv;

function exitAfterWrite(stream, text, code) {
  let settled = false;
  const finish = error => {
    if (settled) return;
    settled = true;
    stream.removeListener('error', finish);
    app.exit(error && error.code !== 'EPIPE' ? 1 : code);
  };
  stream.once('error', finish);
  stream.write(text, finish);
}

app.whenReady().then(() => {
  try {
    const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    const stored = String(settings?.providers?.[providerId]?.apiKey || '');
    const prefix = 'safe-storage:v1:';
    if (!stored.startsWith(prefix)) throw new Error('API Key 不是可识别的安全存储格式');
    if (!safeStorage.isEncryptionAvailable()) throw new Error('系统安全存储不可用');
    const apiKey = safeStorage.decryptString(Buffer.from(stored.slice(prefix.length), 'base64'));
    exitAfterWrite(process.stdout, `__CHAT_CONFIG__${JSON.stringify({ apiKey })}\n`, 0);
  } catch (error) {
    exitAfterWrite(process.stderr, `${error?.message || '无法读取 API Key'}\n`, 1);
  }
});
