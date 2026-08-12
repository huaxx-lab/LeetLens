'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  analysisFingerprint,
  markAnalysisDead,
  normalizeSubmissionDetail,
  queueSubmissionAnalysis,
  sanitizeAnalysisState
} = require('../src/integrations/leetcode-analysis');

test('submission details preserve bounded official performance percentiles', () => {
  const detail = normalizeSubmissionDetail({
    id: '42',
    titleSlug: 'two-sum',
    runtimePercentile: '92.35',
    memoryPercentile: 104
  });
  assert.equal(detail.runtimePercentile, 92.35);
  assert.equal(detail.memoryPercentile, 100);
  assert.equal(normalizeSubmissionDetail({ id: '42', titleSlug: 'two-sum' }).runtimePercentile, null);
});

test('analysis fingerprint is stable for the same submission details', () => {
  const details = [{ id: '2', titleSlug: 'two-sum', code: 'return 1;', timestamp: 2 }, { id: '1', titleSlug: 'two-sum', code: 'return 0;', timestamp: 1 }];
  assert.equal(analysisFingerprint(details), analysisFingerprint([...details].reverse()));
  assert.notEqual(analysisFingerprint(details), analysisFingerprint([{ ...details[0], code: 'return 2;' }, details[1]]));
});

test('queues only new non-historical submissions and keeps analyzed ids out', () => {
  let state = sanitizeAnalysisState({ records: { 'two-sum': { analyzedSubmissionIds: ['1'] } } });
  state = queueSubmissionAnalysis(state, [
    { id: '1', titleSlug: 'two-sum', activityType: 'attempt' },
    { id: '2', titleSlug: 'two-sum', activityType: 'review' },
    { id: '3', titleSlug: 'three-sum', activityType: 'historical' }
  ]);
  assert.deepEqual(state.queue['two-sum'].submissionIds, ['2']);
  assert.equal(state.queue['three-sum'], undefined);
});

test('persists complete per-submission analysis snapshots', () => {
  const state = sanitizeAnalysisState({ records: { 'two-sum': {
    analyzedSubmissionIds: ['42'],
    submissionAnalyses: { 42: {
      summary: '哈希表方向正确',
      rootCause: '重复元素覆盖错误',
      evidence: ['失败用例包含重复值'],
      suggestions: ['先检查再写入'],
      knowledgeGaps: ['哈希表更新顺序'],
      model: 'test-model',
      updatedAt: 123
    } }
  } } });
  assert.deepEqual(state.records['two-sum'].submissionAnalyses['42'].evidence, ['失败用例包含重复值']);
  assert.deepEqual(state.records['two-sum'].submissionAnalyses['42'].suggestions, ['先检查再写入']);
});

test('analysis queue keeps the newest submissions when capped', () => {
  const submissions = Array.from({ length: 100 }, (_, index) => ({
    id: String(index + 1),
    titleSlug: 'two-sum',
    activityType: 'attempt',
    submittedAt: index + 1
  })).reverse();
  const state = queueSubmissionAnalysis({}, submissions);
  assert.equal(state.queue['two-sum'].submissionIds.length, 80);
  assert.equal(state.queue['two-sum'].submissionIds[0], '21');
  assert.equal(state.queue['two-sum'].submissionIds.at(-1), '100');
});

test('analysis state preserves retry diagnostics and summary ordering metadata', () => {
  const state = sanitizeAnalysisState({
    queue: { 'two-sum': {
      submissionIds: ['2'],
      failedSubmissionAttempts: { 2: 99 },
      lastAttemptAt: 456,
      lastError: 'detail unavailable'
    } },
    records: { 'two-sum': {
      summary: 'newest method',
      latestSubmissionAt: 900,
      summaryUpdatedAt: 1000,
      updatedAt: 1200
    } }
  });
  assert.equal(state.queue['two-sum'].failedSubmissionAttempts['2'], 20);
  assert.equal(state.queue['two-sum'].lastAttemptAt, 456);
  assert.equal(state.queue['two-sum'].lastError, 'detail unavailable');
  assert.equal(state.records['two-sum'].latestSubmissionAt, 900);
  assert.equal(state.records['two-sum'].summaryUpdatedAt, 1000);
});

test('dead-lettered submissions leave the active queue and stay out of incremental sync', () => {
  let state = queueSubmissionAnalysis({}, [
    { id: '1', titleSlug: 'two-sum', activityType: 'attempt' },
    { id: '2', titleSlug: 'two-sum', activityType: 'attempt' }
  ]);
  state = markAnalysisDead(state, 'two-sum', ['1'], {
    reason: 'detail_unavailable',
    error: 'detail unavailable',
    failedAt: 100,
    lastAttemptAt: 90
  });
  assert.deepEqual(state.queue['two-sum'].submissionIds, ['2']);
  assert.deepEqual(state.dead['two-sum'].submissionIds, ['1']);
  assert.equal(state.dead['two-sum'].lastError, 'detail unavailable');

  state = queueSubmissionAnalysis(state, [{ id: '1', titleSlug: 'two-sum', activityType: 'attempt' }]);
  assert.deepEqual(state.queue['two-sum'].submissionIds, ['2']);
});

test('an explicit on-demand analysis can revive a dead-lettered submission', () => {
  let state = markAnalysisDead({}, 'two-sum', ['1'], { failedAt: 100 });
  state = queueSubmissionAnalysis(state, [
    { id: '1', titleSlug: 'two-sum', activityType: 'historical' }
  ], { includeHistorical: true, reason: 'on_demand' });
  assert.deepEqual(state.queue['two-sum'].submissionIds, ['1']);
  assert.equal(state.dead['two-sum'], undefined);
});
