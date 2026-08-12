'use strict';

const fs = require('fs');
const path = require('path');
const engine = require('./learning-engine.cjs');

const MARKER = '__LEARNING_ENGINE__';
const LOCK_STALE_MS = 30000;
const LOCK_TIMEOUT_MS = 10000;

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function withFileLock(filePath, operation) {
  const lockPath = `${filePath}.lock`;
  const startedAt = Date.now();
  for (;;) {
    try {
      fs.mkdirSync(lockPath, { mode: 0o700 });
      try {
        fs.writeFileSync(path.join(lockPath, 'owner.json'), JSON.stringify({ pid: process.pid, createdAt: Date.now() }));
      } catch (ownerError) {
        fs.rmSync(lockPath, { recursive: true, force: true });
        throw ownerError;
      }
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        if (Date.now() - fs.statSync(lockPath).mtimeMs > LOCK_STALE_MS) {
          fs.rmSync(lockPath, { recursive: true, force: true });
          continue;
        }
      } catch (statError) {
        if (statError.code === 'ENOENT') continue;
        throw statError;
      }
      if (Date.now() - startedAt >= LOCK_TIMEOUT_MS) throw new Error('学习数据正被另一个进程占用，请稍后重试');
      await delay(20 + Math.floor(Math.random() * 30));
    }
  }
  try {
    return await operation();
  } finally {
    fs.rmSync(lockPath, { recursive: true, force: true });
  }
}

function readInput() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on('data', chunk => chunks.push(chunk));
    process.stdin.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'));
      } catch (error) {
        reject(new Error(`学习引擎输入无效: ${error.message}`));
      }
    });
    process.stdin.on('error', reject);
  });
}

function loadState(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return {};
    throw error;
  }
}

function saveState(filePath, state) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.native-${process.pid}-${Date.now()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(state), { mode: 0o600 });
  fs.renameSync(temporary, filePath);
}

function mutate(state, input) {
  switch (input.operation) {
    case 'mergeAnalysis':
      return engine.mergeLearningAnalysis(
        state,
        String(input.conversationId || ''),
        input.analysis || {},
        Array.isArray(input.messages) ? input.messages : []
      );
    case 'review':
      return engine.reviewLearningItem(state, String(input.itemId || ''), Number(input.rating));
    case 'savePackage':
      return engine.saveLearningPackage(state, String(input.itemId || ''), input.package || {});
    case 'recordAttempt':
      return engine.recordLearningAttempt(
        state,
        String(input.itemId || ''),
        input.submission || {},
        input.judgment || {}
      );
    case 'mergeLeetCodeSubmissions':
      return engine.mergeLeetCodeSubmissions(
        state,
        Array.isArray(input.planQuestions) ? input.planQuestions : [],
        Array.isArray(input.submissions) ? input.submissions : []
      );
    case 'mergeLeetCodeAnalysis':
      return engine.mergeLeetCodeAnalysis(
        state,
        String(input.titleSlug || ''),
        input.analysis || {}
      );
    // 删除活动知识点。走 canonical engine，才能一并写入 deleted 快照、
    // suppressedItems tombstone、revision 与 changeLog——手写版本会漏掉这些语义，
    // 结果是被删的知识点之后又被自动重新识别出来。
    case 'delete':
      return engine.deleteLearningItem(
        state,
        String(input.itemId || ''),
        { reason: String(input.reason || 'manual') }
      );
    case 'restore':
      return engine.restoreLearningItem(state, String(input.itemId || ''));
    case 'purge': {
      const itemId = String(input.itemId || '');
      if (!state.deletedItems?.[itemId]) throw new Error('学习记录已不存在');
      state.deletedItems = { ...(state.deletedItems || {}) };
      delete state.deletedItems[itemId];
      state.updatedAt = Date.now();
      return state;
    }
    case 'emptyTrash':
      state.deletedItems = {};
      state.updatedAt = Date.now();
      return state;
    case 'updateSettings':
      return engine.updateLearningSettings(state, input.settings || {});
    default:
      throw new Error(`不支持的学习引擎操作: ${input.operation || 'empty'}`);
  }
}

function finish(payload, exitCode = 0) {
  const output = `${MARKER}${JSON.stringify(payload)}\n`;
  process.stdout.write(output, () => {
    process.exitCode = exitCode;
  });
}

process.stdout.on('error', error => {
  if (error.code !== 'EPIPE') throw error;
});

readInput().then(async input => {
  const filePath = String(process.argv[2] || '');
  if (!filePath) throw new Error('缺少 learning.json 路径');
  const state = await withFileLock(filePath, async () => {
    const latest = mutate(loadState(filePath), input);
    saveState(filePath, latest);
    return latest;
  });
  finish({ ok: true, updatedAt: state.updatedAt || Date.now() });
}).catch(error => {
  process.stderr.write(`${error.stack || error.message}\n`, () => {
    finish({ ok: false, error: error.message }, 1);
  });
});
