'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createLeetCodeRoute,
  navigateLeetCodeRoute
} = require('../src/integrations/leetcode-navigation');

test('LeetCode review and workspace return context keeps both scroll positions', () => {
  let route = createLeetCodeRoute();
  route = navigateLeetCodeRoute(route, {
    page: 'question',
    slug: 'two-sum',
    submissionId: '738765706',
    origin: 'recent'
  }, 428);
  assert.equal(route.overviewScrollTop, 428);
  assert.equal(route.submissionId, '738765706');

  route = navigateLeetCodeRoute(route, { page: 'workspace' }, 936);
  assert.equal(route.questionScrollTop, 936);
  assert.equal(route.slug, 'two-sum');
  assert.equal(route.submissionId, '738765706');

  route = navigateLeetCodeRoute(route, { page: 'question' }, 0);
  assert.equal(route.questionScrollTop, 936);
  route = navigateLeetCodeRoute(route, { page: 'overview', slug: '', submissionId: '' }, 936);
  assert.equal(route.overviewScrollTop, 428);
  assert.equal(route.slug, '');
  assert.equal(route.submissionId, '');
});

test('LeetCode route normalization rejects zombie workspace state', () => {
  assert.deepEqual(createLeetCodeRoute({ page: 'workspace', slug: '' }), createLeetCodeRoute());
  assert.equal(createLeetCodeRoute({ page: 'unknown', slug: 'two-sum', submissionId: '1' }).page, 'overview');
});
