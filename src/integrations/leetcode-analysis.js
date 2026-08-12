'use strict';

const crypto = require('crypto');

const ANALYSIS_VERSION = 1;

function cleanText(value, maximum = 600) {
  return String(value || '').replace(/\r\n?/g, '\n').trim().slice(0, maximum);
}

function validSlug(value) {
  const slug = cleanText(value, 100).toLowerCase();
  return /^[a-z0-9][a-z0-9-]{0,99}$/.test(slug) ? slug : '';
}

function validPercentile(value) {
  if (value === null || value === undefined || value === '') return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? Math.max(0, Math.min(100, numeric)) : null;
}

function normalizeSubmissionDetail(value) {
  const source = value && typeof value === 'object' ? value : {};
  const id = cleanText(source.id ?? source.submissionId, 80);
  const titleSlug = validSlug(source.titleSlug || source.question?.titleSlug);
  if (!id || !titleSlug) return null;
  return {
    id,
    titleSlug,
    code: cleanText(source.code, 30000),
    lang: cleanText(source.lang?.name || source.lang, 40),
    statusCode: cleanText(source.statusCode, 30),
    statusDisplay: cleanText(source.statusDisplay, 80),
    runtime: cleanText(source.runtimeDisplay || source.runtime, 60),
    memory: cleanText(source.memoryDisplay || source.memory, 60),
    runtimePercentile: validPercentile(source.runtimePercentile),
    memoryPercentile: validPercentile(source.memoryPercentile),
    runtimeError: cleanText(source.runtimeError, 5000),
    compileError: cleanText(source.compileError, 5000),
    lastTestcase: cleanText(source.lastTestcase, 5000),
    codeOutput: cleanText(source.codeOutput, 5000),
    expectedOutput: cleanText(source.expectedOutput, 5000),
    totalCorrect: Math.max(0, Number(source.totalCorrect) || 0),
    totalTestcases: Math.max(0, Number(source.totalTestcases) || 0),
    timestamp: Math.max(0, Number(source.timestamp) || 0)
  };
}

function detailHash(detail) {
  const normalized = normalizeSubmissionDetail(detail);
  if (!normalized) return '';
  return crypto.createHash('sha256').update(JSON.stringify(normalized)).digest('hex').slice(0, 24);
}

function analysisFingerprint(details, version = ANALYSIS_VERSION) {
  const keys = (Array.isArray(details) ? details : [])
    .map(detail => normalizeSubmissionDetail(detail))
    .filter(Boolean)
    .sort((a, b) => a.timestamp - b.timestamp || a.id.localeCompare(b.id))
    .map(detail => `${detail.id}:${detailHash(detail)}`);
  return crypto.createHash('sha256').update(`${version}\0${keys.join('\0')}`).digest('hex').slice(0, 24);
}

function sanitizeAnalysisState(value) {
  const source = value && typeof value === 'object' ? value : {};
  const queue = {};
  for (const [key, raw] of Object.entries(source.queue || {})) {
    const slug = validSlug(key);
    if (!slug || !raw || typeof raw !== 'object') continue;
    const submissionIds = [...new Set((Array.isArray(raw.submissionIds) ? raw.submissionIds : [])
      .map(id => cleanText(id, 80)).filter(Boolean))].slice(-80);
    if (!submissionIds.length) continue;
    queue[slug] = {
      submissionIds,
      queuedAt: Math.max(0, Number(raw.queuedAt) || Date.now()),
      attempts: Math.max(0, Math.min(12, Number(raw.attempts) || 0)),
      nextAttemptAt: Math.max(0, Number(raw.nextAttemptAt) || 0),
      failedSubmissionAttempts: Object.fromEntries(Object.entries(raw.failedSubmissionAttempts || {})
        .map(([id, attempts]) => [cleanText(id, 80), Math.max(0, Math.min(20, Number(attempts) || 0))])
        .filter(([id, attempts]) => id && attempts > 0)
        .slice(-80)),
      lastAttemptAt: Math.max(0, Number(raw.lastAttemptAt) || 0),
      lastError: cleanText(raw.lastError, 300),
      reason: raw.reason === 'on_demand' ? 'on_demand' : 'incremental'
    };
  }
  const dead = {};
  for (const [key, raw] of Object.entries(source.dead || {}).slice(-200)) {
    const slug = validSlug(key);
    if (!slug || !raw || typeof raw !== 'object') continue;
    const submissionIds = [...new Set((Array.isArray(raw.submissionIds) ? raw.submissionIds : [])
      .map(id => cleanText(id, 80)).filter(Boolean))].slice(-80);
    if (!submissionIds.length) continue;
    dead[slug] = {
      submissionIds,
      failedAt: Math.max(0, Number(raw.failedAt) || Date.now()),
      lastAttemptAt: Math.max(0, Number(raw.lastAttemptAt) || 0),
      lastError: cleanText(raw.lastError, 300),
      reason: raw.reason === 'detail_unavailable' ? 'detail_unavailable' : 'retry_exhausted'
    };
  }
  const records = {};
  for (const [key, raw] of Object.entries(source.records || {})) {
    const slug = validSlug(key);
    if (!slug || !raw || typeof raw !== 'object') continue;
    const submissionAnalyses = Object.fromEntries(Object.entries(raw.submissionAnalyses || {})
      .map(([submissionId, item]) => [cleanText(submissionId, 80), {
        summary: cleanText(item?.summary, 2000),
        rootCause: cleanText(item?.rootCause, 800),
        evidence: (Array.isArray(item?.evidence) ? item.evidence : []).map(value => cleanText(value, 400)).filter(Boolean).slice(0, 8),
        suggestions: (Array.isArray(item?.suggestions) ? item.suggestions : []).map(value => cleanText(value, 400)).filter(Boolean).slice(0, 8),
        knowledgeGaps: (Array.isArray(item?.knowledgeGaps) ? item.knowledgeGaps : []).map(value => cleanText(value, 400)).filter(Boolean).slice(0, 8),
        model: cleanText(item?.model, 120),
        updatedAt: Math.max(0, Number(item?.updatedAt) || 0)
      }])
      .filter(([submissionId]) => submissionId)
      .sort((left, right) => left[1].updatedAt - right[1].updatedAt)
      .slice(-80));
    records[slug] = {
      version: Math.max(1, Number(raw.version) || ANALYSIS_VERSION),
      fingerprint: cleanText(raw.fingerprint, 80),
      analyzedSubmissionIds: [...new Set((Array.isArray(raw.analyzedSubmissionIds) ? raw.analyzedSubmissionIds : [])
        .map(id => cleanText(id, 80)).filter(Boolean))].slice(-500),
      analyzedKeys: [...new Set((Array.isArray(raw.analyzedKeys) ? raw.analyzedKeys : [])
        .map(id => cleanText(id, 120)).filter(Boolean))].slice(-800),
      summary: cleanText(raw.summary, 2000),
      weaknesses: (Array.isArray(raw.weaknesses) ? raw.weaknesses : []).map(item => cleanText(item, 400)).filter(Boolean).slice(0, 12),
      improvements: (Array.isArray(raw.improvements) ? raw.improvements : []).map(item => cleanText(item, 400)).filter(Boolean).slice(0, 12),
      attemptInsights: (Array.isArray(raw.attemptInsights) ? raw.attemptInsights : []).map(item => ({
        submissionId: cleanText(item?.submissionId, 80),
        issue: cleanText(item?.issue, 600),
        change: cleanText(item?.change, 600),
        outcome: cleanText(item?.outcome, 600)
      })).filter(item => item.submissionId).slice(-80),
      submissionAnalyses,
      model: cleanText(raw.model, 120),
      latestSubmissionAt: Math.max(0, Number(raw.latestSubmissionAt) || 0),
      summaryUpdatedAt: Math.max(0, Number(raw.summaryUpdatedAt) || Number(raw.updatedAt) || 0),
      updatedAt: Math.max(0, Number(raw.updatedAt) || 0)
    };
  }
  return { version: ANALYSIS_VERSION, queue, dead, records };
}

function queueSubmissionAnalysis(value, submissions, { includeHistorical = false, reason = 'incremental' } = {}) {
  const state = sanitizeAnalysisState(value);
  const grouped = new Map();
  const orderedSubmissions = [...(Array.isArray(submissions) ? submissions : [])]
    .sort((left, right) => (Number(left?.submittedAt) || 0) - (Number(right?.submittedAt) || 0));
  for (const submission of orderedSubmissions) {
    const slug = validSlug(submission?.titleSlug);
    const id = cleanText(submission?.id, 80);
    if (!slug || !id || (!includeHistorical && submission.activityType === 'historical')) continue;
    const analyzed = new Set(state.records[slug]?.analyzedSubmissionIds || []);
    const dead = new Set(state.dead[slug]?.submissionIds || []);
    if (analyzed.has(id) || (reason !== 'on_demand' && dead.has(id))) continue;
    if (!grouped.has(slug)) grouped.set(slug, []);
    grouped.get(slug).push(id);
  }
  for (const [slug, ids] of grouped) {
    if (reason === 'on_demand' && state.dead[slug]) {
      const revived = new Set(ids);
      state.dead[slug].submissionIds = state.dead[slug].submissionIds.filter(id => !revived.has(id));
      if (!state.dead[slug].submissionIds.length) delete state.dead[slug];
    }
    const previous = state.queue[slug] || { submissionIds: [], queuedAt: Date.now(), attempts: 0, nextAttemptAt: 0 };
    state.queue[slug] = {
      ...previous,
      submissionIds: [...new Set([...previous.submissionIds, ...ids])].slice(-80),
      queuedAt: Math.min(previous.queuedAt || Date.now(), Date.now()),
      lastError: '',
      reason: reason === 'on_demand' || previous.reason === 'on_demand' ? 'on_demand' : 'incremental'
    };
  }
  return state;
}

function markAnalysisDead(value, titleSlug, submissionIds, {
  reason = 'retry_exhausted',
  error = '',
  failedAt = Date.now(),
  lastAttemptAt = Date.now()
} = {}) {
  const state = sanitizeAnalysisState(value);
  const slug = validSlug(titleSlug);
  const ids = [...new Set((Array.isArray(submissionIds) ? submissionIds : [])
    .map(id => cleanText(id, 80)).filter(Boolean))];
  if (!slug || !ids.length) return state;
  const previous = state.dead[slug] || { submissionIds: [] };
  state.dead[slug] = {
    submissionIds: [...new Set([...previous.submissionIds, ...ids])].slice(-80),
    failedAt: Math.max(0, Number(failedAt) || Date.now()),
    lastAttemptAt: Math.max(0, Number(lastAttemptAt) || 0),
    lastError: cleanText(error, 300),
    reason: reason === 'detail_unavailable' ? 'detail_unavailable' : 'retry_exhausted'
  };
  const active = state.queue[slug];
  if (active) {
    const deadIds = new Set(ids);
    active.submissionIds = active.submissionIds.filter(id => !deadIds.has(id));
    for (const id of ids) delete active.failedSubmissionAttempts[id];
    if (!active.submissionIds.length) delete state.queue[slug];
  }
  return state;
}

module.exports = {
  ANALYSIS_VERSION,
  analysisFingerprint,
  detailHash,
  markAnalysisDead,
  normalizeSubmissionDetail,
  queueSubmissionAnalysis,
  sanitizeAnalysisState
};
