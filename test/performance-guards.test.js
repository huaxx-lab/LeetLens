'use strict';

const fs = require('node:fs');
const test = require('node:test');
const assert = require('node:assert/strict');
const sourcePaths = require('./helpers/source-paths');

const main = fs.readFileSync(sourcePaths.main, 'utf8');
const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');

test('video eligibility short-circuits without a configured task API key', () => {
  const classifier = main.slice(
    main.indexOf('async function classifyBilibiliVideoEligibility'),
    main.indexOf('async function identifyBilibiliQuery')
  );
  assert.match(classifier, /resolveTaskModel\(loadSettings\(\), 'video'\)/);
  assert.match(classifier, /if \(!String\(route\.apiKey \|\| ''\)\.trim\(\)\)/);
  assert.match(classifier, /skipped: 'provider_unavailable'/);
  assert.ok(classifier.indexOf("skipped: 'provider_unavailable'") < classifier.indexOf("requestTaskText('video'"));
  assert.doesNotMatch(renderer, /explicitlyReferencesHistory/);
});

test('learning queue hydration and processing retain persisted retry deadlines', () => {
  const hydrate = main.slice(
    main.indexOf('function hydrateLearningAnalysisQueue'),
    main.indexOf('function settleLearningFlushWaiters')
  );
  const processor = main.slice(
    main.indexOf('async function processLearningAnalysisQueue'),
    main.indexOf('function enqueueLearningAnalysis')
  );
  assert.match(hydrate, /nextAttemptAt:/);
  assert.match(processor, /task\.nextAttemptAt/);
  assert.match(processor, /scheduleLearningAnalysisQueue\(0\)/);
});

test('LeetCode analysis uses bounded task and submission-detail retries', () => {
  assert.match(main, /LEETCODE_ANALYSIS_MAX_ATTEMPTS = 12/);
  assert.match(main, /LEETCODE_DETAIL_MAX_ATTEMPTS = 6/);
  assert.match(main, /markAnalysisDead\(state\.analysis, slug, deadIds/);
  assert.match(main, /failures >= LEETCODE_DETAIL_MAX_ATTEMPTS/);
});

test('conversation persistence coalesces bursts and flushes atomically before quit', () => {
  assert.match(main, /CONVERSATION_SAVE_COALESCE_MS = 180/);
  assert.match(main, /function flushConversations\(\)/);
  assert.match(main, /writeJsonAtomic\(CONVERSATIONS_FILE, snapshot\)/);
  assert.match(renderer, /CONVERSATION_SAVE_DEBOUNCE_MS = 24/);
  assert.match(renderer, /state\.latest = snapshot/);
  assert.match(renderer, /while \(state\.latest\)/);
  const safeQuit = main.slice(main.indexOf('async function requestSafeQuit'), main.indexOf('function finishReasonError'));
  assert.match(safeQuit, /flushConversations\(\)/);
});

test('composer input avoids full message-action scans on every keystroke', () => {
  const inputListener = renderer.slice(
    renderer.indexOf("chatInput.addEventListener('input'"),
    renderer.indexOf("$('#btn-close').addEventListener")
  );
  assert.match(inputListener, /updateInput\(\{ refreshMessageActions: false \}\)/);
});
