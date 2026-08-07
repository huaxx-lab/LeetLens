'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const sourcePaths = require('./helpers/source-paths');

const main = fs.readFileSync(sourcePaths.main, 'utf8');
const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');

test('video entry is restricted to LeetCode problems and durable learning topics', () => {
  assert.match(main, /category=leetcode_problem/);
  assert.match(main, /category=learning_topic/);
  assert.match(main, /项目改代码、修 bug、看日志、配环境、界面操作、工具命令/);
  assert.match(main, /confidence >= 0\.72/);
  assert.match(main, /learningValue && confidence/);
});

test('failed classification hides the video entry instead of guessing locally', () => {
  assert.doesNotMatch(renderer, /function fallbackVideoEligibility/);
  assert.doesNotMatch(renderer, /text\.length >= 220/);
  assert.match(renderer, /资格判定失败，默认隐藏/);
  assert.match(renderer, /latestState\.eligibility = 'ineligible'/);
});

test('old broad eligibility decisions are invalidated by a schema version', () => {
  assert.match(renderer, /VIDEO_ELIGIBILITY_VERSION = 2/);
  assert.match(renderer, /eligibilityVersion === VIDEO_ELIGIBILITY_VERSION/);
  assert.match(renderer, /latestState\.eligibilityVersion = VIDEO_ELIGIBILITY_VERSION/);
});
