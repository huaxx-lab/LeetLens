'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createLearningState, mergeLeetCodeSubmissions } = require('../src/core/learning-engine');

const QUESTION = {
  titleSlug: 'two-sum',
  frontendId: '1',
  title: 'Two Sum',
  translatedTitle: '两数之和',
  groupName: '哈希',
  topicTags: [{ translatedName: '哈希表', name: 'Hash Table' }]
};

test('turns LeetCode submissions into deduplicated learning evidence', () => {
  const now = new Date(2026, 7, 2, 12).getTime();
  const submission = {
    id: '123',
    titleSlug: 'two-sum',
    accepted: false,
    statusDisplay: 'Wrong Answer',
    lang: 'java',
    submittedAt: now
  };
  let state = mergeLeetCodeSubmissions(createLearningState(), [QUESTION], [submission], now);
  state = mergeLeetCodeSubmissions(state, [QUESTION], [submission], now + 1000);
  const item = Object.values(state.items)[0];
  assert.equal(Object.keys(state.items).length, 1);
  assert.equal(item.canonicalKey, 'leetcode:two-sum');
  assert.equal(item.evidence.length, 1);
  assert.equal(item.mastery.lastSignal, 'struggling');
  assert.deepEqual(item.knowledgePath, ['算法与解题模式', '哈希与查找']);
});

test('accepted follow-up increases mastery and remains one learning item', () => {
  const now = new Date(2026, 7, 2, 12).getTime();
  const failed = { id: '1', titleSlug: 'two-sum', statusDisplay: 'Wrong Answer', submittedAt: now };
  const accepted = { id: '2', titleSlug: 'two-sum', statusDisplay: 'Accepted', accepted: true, submittedAt: now + 1000 };
  const state = mergeLeetCodeSubmissions({}, [QUESTION], [failed, accepted], now + 2000);
  const item = Object.values(state.items)[0];
  assert.equal(item.evidence.length, 2);
  assert.equal(item.mastery.lastSignal, 'demonstrated');
  assert.ok(item.mastery.score > 30);
});
