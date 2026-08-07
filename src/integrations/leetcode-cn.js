'use strict';

const { sanitizeAnalysisState } = require('./leetcode-analysis');

const DAY_MS = 24 * 60 * 60 * 1000;
const DEFAULT_PLAN_SLUG = 'top-100-liked';
const MAX_SUBMISSIONS = 2400;
const REVIEW_SESSION_GAP_MS = 12 * 60 * 60 * 1000;

function cleanText(value, maximum = 160) {
  return String(value || '').replace(/\s+/g, ' ').trim().slice(0, maximum);
}

function validSlug(value) {
  const slug = cleanText(value, 100).toLowerCase();
  return /^[a-z0-9][a-z0-9-]{0,99}$/.test(slug) ? slug : '';
}

function extractStudyPlanSlug(value) {
  const input = cleanText(value, 500);
  if (!input) return DEFAULT_PLAN_SLUG;
  const direct = validSlug(input);
  if (direct) return direct;
  let parsed;
  try {
    parsed = new URL(input);
  } catch {
    throw new Error('请输入有效的力扣题单链接或标识');
  }
  if (parsed.protocol !== 'https:' || parsed.hostname !== 'leetcode.cn') {
    throw new Error('仅支持 leetcode.cn 的学习计划链接');
  }
  const match = parsed.pathname.match(/^\/studyplan\/([a-z0-9-]+)\/?$/i);
  const slug = validSlug(match?.[1]);
  if (!slug) throw new Error('无法识别这个力扣学习计划链接');
  return slug;
}

function normalizeQuestionStatus(value) {
  const status = cleanText(value, 30).toUpperCase();
  if (['AC', 'SOLVED', 'ACCEPTED'].includes(status)) return 'SOLVED';
  if (['TRIED', 'ATTEMPTED'].includes(status)) return 'TRIED';
  return 'TO_DO';
}

function normalizeDifficulty(value) {
  const difficulty = cleanText(value, 20).toUpperCase();
  if (difficulty === 'EASY') return 'EASY';
  if (difficulty === 'HARD') return 'HARD';
  return 'MEDIUM';
}

function createLeetCodeState() {
  return {
    schemaVersion: 1,
    account: { signedIn: false, username: '', realName: '', userSlug: '', avatar: '', isPremium: false },
    plans: {},
    activePlanSlug: '',
    submissions: [],
    tracking: { baselineCompletedAt: 0 },
    analysis: sanitizeAnalysisState({}),
    learningSync: { appliedSubmissionIds: [], lastAppliedAt: 0 },
    lastSyncAt: 0,
    lastError: '',
    updatedAt: 0
  };
}

function normalizeAccount(value) {
  const source = value && typeof value === 'object' ? value : {};
  const avatarData = String(source.avatarData || '');
  return {
    signedIn: Boolean(source.signedIn ?? source.isSignedIn),
    username: cleanText(source.username, 80),
    realName: cleanText(source.realName, 80),
    userSlug: cleanText(source.userSlug, 100),
    avatar: /^https:\/\//i.test(String(source.avatar || '')) ? String(source.avatar).slice(0, 1000) : '',
    avatarData: /^data:image\/(?:png|jpe?g|webp);base64,[a-z0-9+/=]+$/i.test(avatarData) && avatarData.length <= 700000 ? avatarData : '',
    isPremium: Boolean(source.isPremium)
  };
}

function normalizeQuestion(value, group = {}, index = 0) {
  const source = value && typeof value === 'object' ? value : {};
  const titleSlug = validSlug(source.titleSlug);
  if (!titleSlug) return null;
  return {
    titleSlug,
    frontendId: cleanText(source.questionFrontendId ?? source.frontendId, 24),
    title: cleanText(source.title, 160),
    translatedTitle: cleanText(source.translatedTitle, 160),
    difficulty: normalizeDifficulty(source.difficulty),
    status: normalizeQuestionStatus(source.status),
    paidOnly: Boolean(source.paidOnly),
    acRate: Number.isFinite(Number(source.acRate)) ? Number(source.acRate) : null,
    groupSlug: validSlug(group.slug || source.groupSlug),
    groupName: cleanText(group.name || source.groupName, 80),
    order: Math.max(0, Number(source.order ?? index) || 0),
    topicTags: (Array.isArray(source.topicTags) ? source.topicTags : []).slice(0, 16).map(tag => ({
      slug: validSlug(tag?.slug),
      name: cleanText(tag?.name, 60),
      translatedName: cleanText(tag?.nameTranslated ?? tag?.translatedName, 60)
    })).filter(tag => tag.slug || tag.name || tag.translatedName)
  };
}

function normalizeStudyPlan(value, slugHint = '', now = Date.now()) {
  const source = value && typeof value === 'object' ? value : {};
  const slug = validSlug(source.slug || slugHint);
  if (!slug) throw new Error('力扣学习计划缺少有效标识');
  const groups = Array.isArray(source.planSubGroups) ? source.planSubGroups : Array.isArray(source.groups) ? source.groups : [];
  const questions = [];
  const normalizedGroups = [];
  let order = 0;
  for (const rawGroup of groups) {
    const group = { slug: validSlug(rawGroup?.slug), name: cleanText(rawGroup?.name, 80) };
    const groupQuestions = [];
    for (const rawQuestion of Array.isArray(rawGroup?.questions) ? rawGroup.questions : []) {
      const question = normalizeQuestion(rawQuestion, group, order++);
      if (!question) continue;
      questions.push(question);
      groupQuestions.push(question.titleSlug);
    }
    normalizedGroups.push({ ...group, questionSlugs: groupQuestions });
  }
  if (!questions.length && Array.isArray(source.questions)) {
    for (const rawQuestion of source.questions) {
      const question = normalizeQuestion(rawQuestion, rawQuestion, order++);
      if (question) questions.push(question);
    }
  }
  return {
    slug,
    name: cleanText(source.name, 120) || slug,
    description: cleanText(source.description, 600),
    highlight: cleanText(source.highlight, 200),
    groups: normalizedGroups,
    questions,
    importedAt: Math.max(0, Number(source.importedAt) || now),
    syncedAt: now
  };
}

function normalizeSubmission(value, question = null) {
  const source = value && typeof value === 'object' ? value : {};
  const id = cleanText(source.id, 80);
  if (!id) return null;
  const rawTimestamp = Number(source.submittedAt ?? source.timestamp);
  const submittedAt = rawTimestamp > 0 && rawTimestamp < 100000000000 ? rawTimestamp * 1000 : rawTimestamp;
  const statusDisplay = cleanText(source.statusDisplay, 80);
  const accepted = source.accepted === true || /accepted|通过|成功/i.test(statusDisplay);
  const titleSlug = validSlug(source.titleSlug || question?.titleSlug);
  const url = String(source.url || '');
  return {
    id,
    titleSlug,
    frontendId: cleanText(source.frontendId || question?.frontendId, 24),
    title: cleanText(source.title || question?.title || question?.translatedTitle, 160),
    translatedTitle: cleanText(source.translatedTitle || question?.translatedTitle, 160),
    statusDisplay,
    accepted,
    lang: cleanText(source.lang, 40),
    runtime: cleanText(source.runtime, 40),
    memory: cleanText(source.memory, 40),
    submittedAt: Number.isFinite(submittedAt) ? Math.max(0, submittedAt) : 0,
    url: /^https:\/\/leetcode\.cn\//i.test(url) || /^\/submissions\//i.test(url) ? url.slice(0, 1000) : '',
    activityType: ['new', 'review', 'attempt', 'historical'].includes(source.activityType) ? source.activityType : ''
  };
}

function sanitizeLeetCodeState(value, now = Date.now()) {
  const source = value && typeof value === 'object' ? value : {};
  const state = createLeetCodeState();
  state.account = normalizeAccount(source.account);
  for (const [key, valuePlan] of Object.entries(source.plans || {})) {
    try {
      const plan = normalizeStudyPlan(valuePlan, key, Number(valuePlan?.syncedAt) || now);
      state.plans[plan.slug] = plan;
    } catch {}
  }
  state.activePlanSlug = validSlug(source.activePlanSlug);
  if (!state.plans[state.activePlanSlug]) state.activePlanSlug = Object.keys(state.plans)[0] || '';
  state.submissions = mergeSubmissions([], source.submissions || []);
  state.tracking = { baselineCompletedAt: Math.max(0, Number(source.tracking?.baselineCompletedAt) || 0) };
  state.analysis = sanitizeAnalysisState(source.analysis);
  const submissionsById = new Map(state.submissions.map(item => [item.id, item]));
  for (const [slug, task] of Object.entries(state.analysis.queue)) {
    if (task.reason === 'on_demand') continue;
    task.submissionIds = task.submissionIds.filter(id => submissionsById.get(id)?.activityType !== 'historical');
    if (!task.submissionIds.length) delete state.analysis.queue[slug];
  }
  state.learningSync = {
    appliedSubmissionIds: [...new Set((Array.isArray(source.learningSync?.appliedSubmissionIds)
      ? source.learningSync.appliedSubmissionIds : []).map(value => cleanText(value, 80)).filter(Boolean))].slice(-6000),
    lastAppliedAt: Math.max(0, Number(source.learningSync?.lastAppliedAt) || 0)
  };
  state.lastSyncAt = Math.max(0, Number(source.lastSyncAt) || 0);
  state.lastError = cleanText(source.lastError, 300);
  state.updatedAt = Math.max(0, Number(source.updatedAt) || 0);
  return state;
}

function mergeStudyPlan(value, rawPlan, slugHint = '', now = Date.now()) {
  const state = sanitizeLeetCodeState(value, now);
  const plan = normalizeStudyPlan(rawPlan, slugHint, now);
  const previous = state.plans[plan.slug];
  plan.importedAt = previous?.importedAt || plan.importedAt;
  state.plans[plan.slug] = plan;
  state.activePlanSlug = plan.slug;
  state.updatedAt = now;
  return state;
}

function mergeSubmissions(existing, incoming) {
  const byId = new Map();
  for (const raw of [...(Array.isArray(existing) ? existing : []), ...(Array.isArray(incoming) ? incoming : [])]) {
    const submission = normalizeSubmission(raw);
    if (!submission) continue;
    const previous = byId.get(submission.id) || {};
    byId.set(submission.id, {
      ...previous,
      ...submission,
      activityType: submission.activityType || previous.activityType || ''
    });
  }
  return [...byId.values()].sort((a, b) => b.submittedAt - a.submittedAt).slice(0, MAX_SUBMISSIONS);
}

function classifySubmissionActivities(existing, incoming, previousQuestions = [], { baseline = false } = {}) {
  const existingItems = mergeSubmissions([], existing);
  const knownIds = new Set(existingItems.map(item => item.id));
  const existingById = new Map(existingItems.map(item => [item.id, item]));
  const latestBySlug = new Map();
  for (const item of [...existingItems].sort((a, b) => a.submittedAt - b.submittedAt)) {
    if (item.titleSlug) latestBySlug.set(item.titleSlug, item);
  }
  const priorStatus = new Map((Array.isArray(previousQuestions) ? previousQuestions : [])
    .map(question => [question?.titleSlug, normalizeQuestionStatus(question?.status)]));
  const classified = [];
  for (const raw of [...(Array.isArray(incoming) ? incoming : [])].sort((a, b) => a.submittedAt - b.submittedAt)) {
    const item = normalizeSubmission(raw);
    if (!item) continue;
    if (knownIds.has(item.id)) {
      classified.push({ ...item, activityType: existingById.get(item.id)?.activityType || item.activityType });
      continue;
    }
    const previous = latestBySlug.get(item.titleSlug);
    let activityType = 'attempt';
    if (baseline) activityType = 'historical';
    else if (!item.titleSlug) activityType = 'attempt';
    else if (!previous) activityType = priorStatus.get(item.titleSlug) === 'SOLVED' ? 'review' : 'new';
    else if (item.submittedAt - previous.submittedAt >= REVIEW_SESSION_GAP_MS) activityType = 'review';
    item.activityType = activityType;
    classified.push(item);
    knownIds.add(item.id);
    if (item.titleSlug) latestBySlug.set(item.titleSlug, item);
  }
  return classified.sort((a, b) => b.submittedAt - a.submittedAt);
}

function localDayKey(timestamp) {
  const date = new Date(timestamp);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function buildActivity(submissions, now = Date.now(), days = 365) {
  const today = new Date(now);
  today.setHours(0, 0, 0, 0);
  const start = today.getTime() - (days - 1) * DAY_MS;
  const counts = new Map();
  for (const submission of submissions) {
    if (submission.submittedAt < start || submission.submittedAt >= today.getTime() + DAY_MS) continue;
    const key = localDayKey(submission.submittedAt);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  const activity = [];
  let total = 0;
  for (let offset = 0; offset < days; offset += 1) {
    const timestamp = start + offset * DAY_MS;
    const date = localDayKey(timestamp);
    const count = counts.get(date) || 0;
    total += count;
    activity.push({ date, count });
  }
  let streak = 0;
  for (let index = activity.length - 1; index >= 0; index -= 1) {
    if (activity[index].count > 0) streak += 1;
    else if (index === activity.length - 1) continue;
    else break;
  }
  return { activity, total, streak };
}

function questionStatus(question, submissions) {
  if (submissions.some(item => item.accepted)) return 'SOLVED';
  if (submissions.length) return 'TRIED';
  return normalizeQuestionStatus(question.status);
}

function buildLeetCodeDashboard(value, now = Date.now()) {
  const state = sanitizeLeetCodeState(value, now);
  const plan = state.plans[state.activePlanSlug] || null;
  const bySlug = new Map();
  for (const submission of state.submissions) {
    if (!submission.titleSlug) continue;
    if (!bySlug.has(submission.titleSlug)) bySlug.set(submission.titleSlug, []);
    bySlug.get(submission.titleSlug).push(submission);
  }
  const questions = (plan?.questions || []).map(question => {
    const submissions = bySlug.get(question.titleSlug) || [];
    return {
      ...question,
      status: questionStatus(question, submissions),
      submissionCount: submissions.length,
      acceptedCount: submissions.filter(item => item.accepted).length,
      lastSubmittedAt: submissions[0]?.submittedAt || 0,
      lastStatus: submissions[0]?.statusDisplay || ''
    };
  });
  const activity = buildActivity(state.submissions, now);
  return {
    schemaVersion: 1,
    account: state.account,
    plans: Object.values(state.plans).map(item => ({ slug: item.slug, name: item.name, questionCount: item.questions.length, syncedAt: item.syncedAt })),
    activePlanSlug: state.activePlanSlug,
    plan: plan ? { slug: plan.slug, name: plan.name, description: plan.description, groups: plan.groups } : null,
    questions,
    submissions: state.submissions,
    activity: activity.activity,
    stats: {
      total: questions.length,
      solved: questions.filter(item => item.status === 'SOLVED').length,
      tried: questions.filter(item => item.status === 'TRIED').length,
      todo: questions.filter(item => item.status === 'TO_DO').length,
      submissions: activity.total,
      acceptedSubmissions: state.submissions.filter(item => item.accepted && item.submittedAt >= now - 365 * DAY_MS).length,
      streak: activity.streak,
      newProblems: state.submissions.filter(item => item.activityType === 'new' && item.submittedAt >= now - 365 * DAY_MS).length,
      reviews: state.submissions.filter(item => item.activityType === 'review' && item.submittedAt >= now - 365 * DAY_MS).length
    },
    lastSyncAt: state.lastSyncAt,
    lastError: state.lastError,
    learningSync: {
      appliedCount: state.learningSync.appliedSubmissionIds.length,
      lastAppliedAt: state.learningSync.lastAppliedAt
    },
    analysis: {
      pendingQuestions: Object.keys(state.analysis.queue).length,
      pending: Object.fromEntries(Object.entries(state.analysis.queue).map(([slug, task]) => [slug, {
        submissionCount: task.submissionIds.length,
        queuedAt: task.queuedAt,
        lastAttemptAt: task.lastAttemptAt,
        lastError: task.lastError,
        nextAttemptAt: task.nextAttemptAt
      }])),
      records: state.analysis.records
    }
  };
}

module.exports = {
  DEFAULT_PLAN_SLUG,
  buildActivity,
  buildLeetCodeDashboard,
  classifySubmissionActivities,
  createLeetCodeState,
  extractStudyPlanSlug,
  mergeStudyPlan,
  mergeSubmissions,
  normalizeAccount,
  normalizeSubmission,
  normalizeStudyPlan,
  sanitizeLeetCodeState,
  validSlug
};
