'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  buildLeetCodeDashboard,
  classifySubmissionActivities,
  createLeetCodeState,
  extractStudyPlanSlug,
  mergeStudyPlan,
  mergeSubmissions
} = require('../src/integrations/leetcode-cn');

const PLAN = {
  name: 'LeetCode 热题 100',
  slug: 'top-100-liked',
  planSubGroups: [{
    name: '哈希',
    slug: 'hash',
    questions: [{
      titleSlug: 'two-sum',
      title: 'Two Sum',
      translatedTitle: '两数之和',
      questionFrontendId: '1',
      difficulty: 'EASY',
      status: 'TO_DO',
      topicTags: [{ slug: 'hash-table', name: 'Hash Table', nameTranslated: '哈希表' }]
    }]
  }]
};

test('extracts only valid leetcode.cn study plan slugs', () => {
  assert.equal(extractStudyPlanSlug(''), 'top-100-liked');
  assert.equal(extractStudyPlanSlug('top-100-liked'), 'top-100-liked');
  assert.equal(extractStudyPlanSlug('https://leetcode.cn/studyplan/top-100-liked/'), 'top-100-liked');
  assert.throws(() => extractStudyPlanSlug('https://example.com/studyplan/top-100-liked/'));
});

test('merges plans and submissions without duplicating submission evidence', () => {
  const now = new Date(2026, 7, 2, 12).getTime();
  let state = mergeStudyPlan(createLeetCodeState(), PLAN, '', now);
  state.submissions = mergeSubmissions(state.submissions, [
    { id: '10', titleSlug: 'two-sum', title: 'Two Sum', timestamp: Math.floor(now / 1000), statusDisplay: 'Wrong Answer' },
    { id: '11', titleSlug: 'two-sum', title: 'Two Sum', timestamp: Math.floor(now / 1000), statusDisplay: 'Accepted' },
    { id: '11', titleSlug: 'two-sum', title: 'Two Sum', timestamp: Math.floor(now / 1000), statusDisplay: 'Accepted', runtime: '1 ms' }
  ]);
  const dashboard = buildLeetCodeDashboard(state, now);
  assert.equal(state.submissions.length, 2);
  assert.equal(dashboard.questions[0].status, 'SOLVED');
  assert.equal(dashboard.questions[0].submissionCount, 2);
  assert.equal(dashboard.stats.submissions, 2);
  assert.equal(dashboard.learningSync.appliedCount, 0);
});

test('preserves authenticated plan status without recent submissions', () => {
  const now = new Date(2026, 7, 2, 12).getTime();
  const solvedPlan = structuredClone(PLAN);
  solvedPlan.planSubGroups[0].questions[0].status = 'AC';
  const dashboard = buildLeetCodeDashboard(mergeStudyPlan({}, solvedPlan, '', now), now);
  assert.equal(dashboard.stats.solved, 1);
});

test('classifies baseline, new work, same-session attempts, and later reviews once', () => {
  const start = new Date(2026, 7, 1, 9).getTime();
  const historical = classifySubmissionActivities([], [
    { id: '1', titleSlug: 'two-sum', timestamp: start / 1000, statusDisplay: 'Accepted' }
  ], [], { baseline: true });
  assert.equal(historical[0].activityType, 'historical');

  const first = classifySubmissionActivities([], [
    { id: '2', titleSlug: 'three-sum', timestamp: start / 1000, statusDisplay: 'Wrong Answer' },
    { id: '3', titleSlug: 'three-sum', timestamp: (start + 10 * 60 * 1000) / 1000, statusDisplay: 'Accepted' }
  ]);
  assert.deepEqual(first.map(item => item.activityType), ['attempt', 'new']);

  const review = classifySubmissionActivities(first, [
    { id: '4', titleSlug: 'three-sum', timestamp: (start + 24 * 60 * 60 * 1000) / 1000, statusDisplay: 'Accepted' }
  ]);
  assert.equal(review[0].activityType, 'review');
  assert.equal(classifySubmissionActivities(review, review)[0].activityType, 'review');
  const duplicateWithoutMarker = classifySubmissionActivities(historical, [
    { id: '1', titleSlug: 'two-sum', timestamp: start / 1000, statusDisplay: 'Accepted' }
  ]);
  assert.equal(duplicateWithoutMarker[0].activityType, 'historical');
});

test('submissions without a resolved slug are not counted as new problems', () => {
  const classified = classifySubmissionActivities([], [
    { id: 'missing-1', title: 'Unknown Problem', timestamp: Date.now() / 1000, statusDisplay: 'Accepted' }
  ], [], { baseline: false });
  assert.equal(classified[0].activityType, 'attempt');
});
