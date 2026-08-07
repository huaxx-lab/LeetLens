'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const sourcePaths = require('./helpers/source-paths');

const main = fs.readFileSync(sourcePaths.main, 'utf8');
const preload = fs.readFileSync(sourcePaths.preload, 'utf8');
const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');
const styles = fs.readFileSync(sourcePaths.styles, 'utf8');

function topLevelFunctionSource(name) {
  const start = main.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} should exist`);
  const tail = main.slice(start);
  const end = tail.search(/\n}\n/);
  assert.notEqual(end, -1, `${name} should have a top-level closing brace`);
  return tail.slice(0, end + 2);
}

function cleanText(value, maximum = 160) {
  return String(value || '').replace(/\s+/g, ' ').trim().slice(0, maximum);
}

test('remote Java completion uses a loopback-only reusable SSH tunnel', () => {
  assert.match(main, /spawn\('\/usr\/bin\/ssh'/);
  assert.match(main, /'BatchMode=yes'/);
  assert.match(main, /'ExitOnForwardFailure=yes'/);
  assert.match(main, /'StrictHostKeyChecking=accept-new'/);
  assert.match(main, /`127\.0\.0\.1:\$\{port}:127\.0\.0\.1:\$\{REMOTE_LSP_TARGET_PORT\}`/);
  assert.match(main, /process\.env\.LEETCODE_LSP_SSH_HOST/);
  assert.match(main, /process\.env\.LEETCODE_LSP_SSH_USER/);
  assert.match(main, /if \(!REMOTE_LSP_HOST\) return Promise\.reject/);
  assert.doesNotMatch(main, /117\.72\.184\.7/);
  assert.doesNotMatch(main, /`root@\$\{REMOTE_LSP_HOST\}`/);
  assert.doesNotMatch(main, /-L[^\n]*0\.0\.0\.0/);
  assert.match(main, /if \(remoteLspTunnelProcess\?\.exitCode === null && remoteLspTunnelPort\)/);
  assert.match(main, /stopRemoteLspTunnel\(\);[\s\S]*app\.on\('window-all-closed'/);
});

test('remote completion is bounded and returns a non-throwing fallback contract', () => {
  assert.match(main, /REMOTE_LSP_MAX_CODE_BYTES = 192 \* 1024/);
  assert.match(main, /REMOTE_LSP_MAX_RESPONSE_BYTES = 512 \* 1024/);
  const timeout = Number(main.match(/REMOTE_LSP_REQUEST_TIMEOUT_MS = (\d+)/)?.[1]);
  assert.ok(timeout >= 10000 && timeout <= 20000, 'remote completion timeout should cover a bounded cold start');
  assert.match(main, /if \(language !== 'java'\) return remoteCompletionFallback/);
  assert.match(main, /if \(remoteLspActiveRequests >= 2\) return remoteCompletionFallback/);
  assert.match(main, /catch \(error\) \{[\s\S]*return remoteCompletionFallback\(error\?\.message\)/);
  assert.match(preload, /getRemoteCodeCompletions: \(payload\) => ipcRenderer\.invoke\('get-remote-code-completions', payload\)/);
  assert.match(main, /ipcMain\.handle\('get-remote-code-completions'/);
});

test('remote completion normalization deduplicates and caps server results', () => {
  const source = topLevelFunctionSource('normalizeRemoteCompletionItems');
  const normalize = new Function('cleanText', `${source}; return normalizeRemoteCompletionItems;`)(cleanText);
  const input = [
    { label: 'add(String)', insertText: 'add(value)', detail: 'List method', kind: 2 },
    { label: 'add(String)', insertText: 'add(value)', detail: 'duplicate', kind: 2 },
    ...Array.from({ length: 140 }, (_, index) => ({ label: `item${index}`, insertText: `item${index}` }))
  ];
  const result = normalize(input);
  assert.equal(result.length, 120);
  assert.equal(result.filter(item => item.label === 'add(String)').length, 1);
  assert.deepEqual(result[0], {
    label: 'add(String)',
    insertText: 'add(value)',
    detail: 'List method',
    kind: 2,
    sortText: ''
  });
});

test('LeetCode solution slugs are validated before GraphQL use', () => {
  const source = topLevelFunctionSource('validLeetCodeSolutionSlug');
  const validate = new Function('cleanText', `${source}; return validLeetCodeSolutionSlug;`)(cleanText);
  assert.equal(validate('Liang-Shu-Zhi-He-By-Leetcode-Solution'), 'liang-shu-zhi-he-by-leetcode-solution');
  assert.equal(validate('../graphql'), '');
  assert.equal(validate('solution_with_underscore'), '');
  assert.equal(validate(`a${'b'.repeat(180)}`), '');
});

test('official LeetCode solution list and detail APIs are cached and exposed', () => {
  assert.match(main, /questionSolutionArticles\(questionSlug: \$questionSlug/);
  assert.match(main, /questionSolutionOfficialArticle\(questionSlug: \$questionSlug\)/);
  assert.match(main, /solutionArticle\(slug: \$slug\)/);
  assert.match(main, /leetcodeSolutionsCache\.set\(slug/);
  assert.match(main, /leetcodeSolutionCache\.set\(slug/);
  assert.match(main, /title: '力扣官方题解'/);
  assert.match(main, /items\.unshift\(/);
  assert.match(main, /String\(article\.content \|\| ''\)\.slice\(0, 1024 \* 1024\)/);
  assert.match(main, /ipcMain\.handle\('get-leetcode-solutions'/);
  assert.match(main, /ipcMain\.handle\('get-leetcode-solution'/);
  assert.match(preload, /getLeetCodeSolutions: \(questionSlug\) => ipcRenderer\.invoke\('get-leetcode-solutions', questionSlug\)/);
  assert.match(preload, /getLeetCodeSolution: \(solutionSlug\) => ipcRenderer\.invoke\('get-leetcode-solution', solutionSlug\)/);
});

test('synthetic or unavailable study plans cannot block submission synchronization', () => {
  assert.match(main, /if \(slug === 'auto-tracked'\) continue/);
  assert.match(main, /const planSyncErrors = \[\]/);
  assert.match(main, /planSyncErrors\.push/);
  assert.match(main, /const raw = await fetchLeetCodeSubmissions/);
  assert.match(main, /部分题单未更新/);
});

test('stable LeetCode content and submission code survive app restarts', () => {
  assert.match(main, /LEETCODE_CONTENT_FILE/);
  assert.match(main, /loadLeetCodeContentCache\(\)\.workspaces\[slug\]/);
  assert.match(main, /loadLeetCodeContentCache\(\)\.submissionDetails\[id\]/);
  assert.match(main, /historySyncedAt\[slug\]/);
  assert.match(main, /LEETCODE_PLAN_REFRESH_MS = 24 \* 60 \* 60 \* 1000/);
  assert.match(main, /avatarData: `data:\$\{type/);
});

test('official submission performance ranking degrades safely on older GraphQL schemas', () => {
  assert.match(main, /runtimePercentile memoryPercentile/);
  assert.match(main, /LEETCODE_SUBMISSION_DETAIL_FALLBACK_QUERY/);
  assert.match(main, /cannot query field\|unknown field\|runtimePercentile\|memoryPercentile\|422/i);
  assert.match(main, /performanceChecked: true/);
});

test('LeetCode judge progress streams real phases into the animated workspace notice', () => {
  assert.match(main, /onProgress\?\.\(\{ phase: 'queued'/);
  assert.match(main, /phase: 'judging'/);
  assert.match(main, /phase: 'result'/);
  assert.match(main, /onProgress\?\.\(\{ phase: 'syncing', result \}\)/);
  assert.match(main, /event\.sender\.send\('leetcode-judge-progress'/);
  assert.match(preload, /onLeetCodeJudgeProgress/);
  assert.match(renderer, /updateLeetcodeExecutionNotice\(requestId, progress\)/);
  assert.match(renderer, /result\.runtime/);
  assert.match(renderer, /result\.memory/);
  assert.match(styles, /@keyframes leetcode-notice-in/);
  assert.match(styles, /leetcode-execution-notice\[data-state="accepted"\]/);
  assert.match(styles, /\.leetcode-execution-notice-slot \{[^}]*top: 50%;[^}]*left: 50%;[^}]*translate\(-50%,-50%\)/s);
});

test('older analysis retries cannot replace the newest submission summary', () => {
  assert.match(main, /const batchLatestSubmissionAt = Math\.max/);
  assert.match(main, /const advancesSummary = !previous \|\| batchLatestSubmissionAt >= previousLatestSubmissionAt/);
  assert.match(main, /summary: advancesSummary \? cleanText\(result\.summary, 2000\) : previous\.summary/);
  assert.match(main, /latestSubmissionAt: Math\.max\(previousLatestSubmissionAt, batchLatestSubmissionAt\)/);
  assert.match(main, /repairLeetCodeAnalysisOrdering\(state\)/);
  assert.match(main, /scheduleLeetCodeAnalysis\(1000\)/);
});
