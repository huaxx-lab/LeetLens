'use strict';

const crypto = require('crypto');
const { createEmptyCard, fsrs, Rating } = require('ts-fsrs');

const DAY_MS = 24 * 60 * 60 * 1000;
const RECYCLE_RETENTION_MS = 30 * DAY_MS;
const MAX_ANALYSIS_HISTORY = 50;
const scheduler = fsrs({
  request_retention: 0.9,
  maximum_interval: 3650,
  enable_fuzz: true,
  enable_short_term: false,
  learning_steps: [],
  relearning_steps: []
});

const DEFAULT_LEARNING_SETTINGS = Object.freeze({
  dailyNewTarget: 3,
  weekdayReviewTarget: 4,
  weeklyReviewDay: 0,
  weeklyReviewTarget: 12,
  requestRetention: 0.9,
  preferredLanguage: 'java'
});

const PRACTICE_TYPES = new Set(['choice', 'short_answer', 'code_completion', 'coding']);
const PRACTICE_VERDICTS = new Set(['correct', 'partial', 'incorrect']);
const EDITABLE_ITEM_FIELDS = Object.freeze([
  'title',
  'question',
  'diagnosis',
  'labels',
  'prerequisiteLabels',
  'knowledgePath',
  'language',
  'videoEligible'
]);

const SIGNAL_BASE = Object.freeze({
  gap: 24,
  struggling: 30,
  learning: 42,
  applying: 58,
  demonstrated: 72,
  mastered: 84,
  neutral: 46
});

const SIGNAL_DELTA = Object.freeze({
  gap: -14,
  struggling: -9,
  learning: 3,
  applying: 8,
  demonstrated: 14,
  mastered: 18,
  neutral: 0
});

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, Number(value) || 0));
}

function cleanText(value, maximum = 160) {
  return String(value || '').replace(/\s+/g, ' ').trim().slice(0, maximum);
}

function cleanMultilineText(value, maximum = 6000) {
  return String(value || '')
    .replace(/\r\n?/g, '\n')
    .replace(/[\t ]+$/gm, '')
    .replace(/\n{4,}/g, '\n\n\n')
    .trim()
    .slice(0, maximum);
}

function finiteSetting(value, fallback) {
  if (value === '' || value === null || typeof value === 'undefined') return fallback;
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function uniqueStrings(values, maximum = 8, length = 36) {
  const seen = new Set();
  const result = [];
  for (const value of Array.isArray(values) ? values : []) {
    const normalized = cleanText(value, length);
    const key = normalized.toLocaleLowerCase('zh-CN');
    if (!normalized || seen.has(key)) continue;
    seen.add(key);
    result.push(normalized);
    if (result.length >= maximum) break;
  }
  return result;
}

function stableId(prefix, parts) {
  return `${prefix}_${crypto.createHash('sha256').update(parts.map(value => String(value || '')).join('\0')).digest('hex').slice(0, 16)}`;
}

function inferLanguage(value) {
  const explicit = cleanText(value?.language, 32).toLocaleLowerCase('en-US');
  if (explicit) return explicit;
  const haystack = [value?.title, value?.question, ...(value?.labels || []), ...(value?.knowledgePath || [])].join(' ');
  if (/\bjava\b/i.test(haystack)) return 'java';
  if (/\b(?:python|py)\b/i.test(haystack)) return 'python';
  if (/\b(?:javascript|typescript|js|ts)\b/i.test(haystack)) return /typescript|\bts\b/i.test(haystack) ? 'typescript' : 'javascript';
  if (/\b(?:c\+\+|cpp)\b/i.test(haystack)) return 'cpp';
  return '';
}

// 受控分类词表：知识路径不再由模型逐条自由发挥。
// 根因是同一个概念（如「双指针」）在不同条目里被挂到不同父节点下，脑图就会
// 长出多个同名节点、层级深浅不一。这里给每个主题唯一的归属，模型给什么都规范到这棵树。
const KNOWLEDGE_TAXONOMY = Object.freeze({
  '算法与解题模式': {
    '双指针': ['双指针', '对撞指针', '快慢指针', '左右指针'],
    '滑动窗口': ['滑动窗口', '窗口'],
    '二分查找': ['二分', '二分查找', '折半查找', '二分答案'],
    '排序': ['排序', '快速排序', '归并排序', '冒泡排序', '排序算法'],
    '哈希与查找': ['哈希表', '哈希', '散列', '查找与匹配', '查找', '哈希映射'],
    '动态规划': ['动态规划', 'dp', '状态压缩', '背包', '线性dp', '区间dp'],
    '贪心': ['贪心', '贪心算法'],
    '回溯': ['回溯', '回溯算法', '全排列', '组合搜索'],
    '搜索': ['搜索', 'dfs', 'bfs', '深度优先搜索', '广度优先搜索', '深搜', '广搜'],
    '图论': ['图论', '最短路', '拓扑排序', '并查集', '最小生成树'],
    '前缀和与差分': ['前缀和', '差分', '区间和'],
    '单调栈与单调队列': ['单调栈', '单调队列'],
    '堆与优先队列': ['堆', '优先队列', 'topk', 'top k'],
    '字符串处理': ['字符串处理', '字符串算法', 'kmp', '回文', '子串'],
    '数学': ['数学', '数论', '位运算', '组合数学', '快速幂']
  },
  '数据结构': {
    '数组': ['数组', '顺序表'],
    '链表': ['链表', '单链表', '双链表'],
    '栈': ['栈'],
    '队列': ['队列', '双端队列', 'deque'],
    '树': ['树', '二叉树', '二叉搜索树', '平衡树', '线段树', '字典树', 'trie'],
    '图': ['图', '邻接表', '邻接矩阵'],
    '哈希表': ['哈希表结构', '散列表'],
    '堆': ['堆结构', '二叉堆']
  },
  '编程语言': {
    'Java': ['java'],
    'Python': ['python', 'py'],
    'JavaScript': ['javascript', 'js'],
    'TypeScript': ['typescript', 'ts'],
    'C++': ['c++', 'cpp']
  },
  '工程与工具': {
    '构建与依赖': ['maven', 'gradle', 'npm', '构建', '依赖管理'],
    '版本控制': ['git', '版本控制'],
    '调试与测试': ['调试', '测试', 'junit', '断点']
  },
  '计算机基础': {
    '操作系统': ['操作系统', '进程', '线程', '内存管理'],
    '网络': ['网络', 'tcp', 'http', '协议'],
    '数据库': ['数据库', 'sql', '索引', '事务'],
    '并发': ['并发', '多线程', '锁', '同步']
  }
});

// 语言内主题作为第三层：集合框架在 Java 下与在 Python 下本就是不同的知识，
// 但在同一语言内只允许有一个归属。
const LANGUAGE_TOPICS = Object.freeze({
  '集合框架': ['集合框架', '集合', 'collection', 'list', 'map', 'set', 'arraylist', 'hashmap', 'deque'],
  '字符串 API': ['字符串api', 'string', 'stringbuilder', '字符串方法', '字符串'],
  '流与函数式': ['stream', '流', 'lambda', '函数式'],
  '工具类': ['arrays', 'collections', 'math', '工具类'],
  '并发': ['并发', '多线程', '线程', '锁'],
  '基础语法': ['基础语法', '语法', '泛型', '异常', '反射']
});

const LANGUAGE_TOPIC_INDEX = (() => {
  const index = new Map();
  const key = text => String(text || '').toLocaleLowerCase('zh-CN').replace(/[^\p{L}\p{N}+]+/gu, '');
  for (const [topic, aliases] of Object.entries(LANGUAGE_TOPICS)) {
    for (const alias of [topic, ...aliases]) {
      const aliasKey = key(alias);
      if (aliasKey && !index.has(aliasKey)) index.set(aliasKey, topic);
    }
  }
  return index;
})();

const TAXONOMY_INDEX = (() => {
  const index = new Map();
  const key = text => String(text || '').toLocaleLowerCase('zh-CN').replace(/[^\p{L}\p{N}+]+/gu, '');
  for (const [root, topics] of Object.entries(KNOWLEDGE_TAXONOMY)) {
    index.set(key(root), { root, topic: '' });
    for (const [topic, aliases] of Object.entries(topics)) {
      for (const alias of [topic, ...aliases]) {
        const aliasKey = key(alias);
        if (aliasKey && !index.has(aliasKey)) index.set(aliasKey, { root, topic });
      }
    }
  }
  return { index, key };
})();

// 把任意路径映射到受控词表：取最具体（最靠后）的可识别主题决定归属，
// 于是同一主题在任何条目里都拥有相同的父节点与相同深度。
function canonicalizeKnowledgePath(path, value) {
  const segments = uniqueStrings(path, 10, 42);
  if (!segments.length) return [];
  const { index, key } = TAXONOMY_INDEX;
  let root = '';
  let topic = '';
  let matchedAt = -1;
  segments.forEach((segment, position) => {
    const hit = index.get(key(segment));
    if (!hit) return;
    if (hit.topic) {
      root = hit.root;
      topic = hit.topic;
      matchedAt = position;
    } else if (!root) {
      root = hit.root;
    }
  });
  if (!root) return segments;
  if (root === '编程语言') {
    const languageName = { java: 'Java', python: 'Python', javascript: 'JavaScript', typescript: 'TypeScript', cpp: 'C++' }[inferLanguage(value)] || topic;
    if (!languageName) return [root];
    // 语言内主题：从整条路径与标签里找唯一归属，找不到则停在语言层。
    const scope = [...segments, ...uniqueStrings(value?.labels, 8, 42), cleanText(value?.title, 100)];
    for (const segment of scope) {
      const languageTopic = LANGUAGE_TOPIC_INDEX.get(key(segment));
      if (languageTopic) return [root, languageName, languageTopic];
    }
    return [root, languageName];
  }
  if (!topic) return [root];
  return [root, topic];
}

function compactKnowledgePath(values) {
  let path = uniqueStrings(values, 10, 42);
  const generic = /^(?:标准库|常用方法|知识点|题目|解法|分类)$/u;
  if (path.length >= 4) {
    const compacted = path.filter((part, index) => index < 2 || !generic.test(part));
    if (compacted.length >= 2) path = compacted;
  }
  if (path.length <= 4) return path;
  return [path[0], path[1], ...path.slice(-2)];
}

// 分类路径里不能出现条目自身的题名/主题名：那会让每道题都长出一层只属于自己的
// 分类节点，脑图退化成一题一枝，同名题还会分叉出多个同名节点。
function stripSelfTitleFromPath(path, title) {
  const normalize = text => String(text || '')
    .toLocaleLowerCase('zh-CN')
    .replace(/[（(].*?[)）]/gu, '')
    .replace(/[^\p{L}\p{N}]+/gu, '');
  const selfKey = normalize(title);
  if (!selfKey) return path;
  const trimmed = path.filter((part, index) => {
    if (index === 0) return true;
    const partKey = normalize(part);
    if (!partKey) return false;
    if (partKey === selfKey) return false;
    // 末层若是题名的前缀（如「接雨水」之于「接雨水问题中少于三根柱子…」）也是题名层级；
    // 用前缀而非包含，避免误删「Java List 常用方法」里的合法分类「List」。
    return !(index === path.length - 1 && partKey.length >= 3 && selfKey.startsWith(partKey));
  });
  return trimmed.length ? trimmed : path.slice(0, 1);
}

function inferKnowledgePath(value) {
  // 1) 模型给的路径：先去掉题名层级，再规范到受控词表。
  const explicit = stripSelfTitleFromPath(compactKnowledgePath(value?.knowledgePath), value?.title);
  const canonical = canonicalizeKnowledgePath(explicit, value);
  if (canonical.length >= 2) return canonical;

  // 2) 模型没给可用路径时，从标签与标题里找受控词表命中。
  const labels = uniqueStrings(value?.labels, 8, 42);
  const title = cleanText(value?.title, 100);
  const { index, key } = TAXONOMY_INDEX;
  for (const candidate of [...labels, title]) {
    const hit = index.get(key(candidate));
    if (hit?.topic) return [hit.root, hit.topic];
  }
  const language = inferLanguage(value);
  if (language) {
    const languageName = { java: 'Java', python: 'Python', javascript: 'JavaScript', typescript: 'TypeScript', cpp: 'C++' }[language] || language;
    for (const candidate of [...labels, title]) {
      const languageTopic = LANGUAGE_TOPIC_INDEX.get(key(candidate));
      if (languageTopic) return ['编程语言', languageName, languageTopic];
    }
    return ['编程语言', languageName];
  }
  if (canonical.length) return canonical;
  return value?.kind === 'problem' ? ['算法与解题模式'] : ['计算机基础'];
}

function dateValue(value, fallback = 0) {
  const timestamp = value instanceof Date ? value.getTime() : Number(value);
  return Number.isFinite(timestamp) && timestamp > 0 ? timestamp : fallback;
}

function localDayKey(timestamp) {
  const date = new Date(timestamp);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function startOfLocalDay(timestamp) {
  const date = new Date(timestamp);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

function nextPreferredReviewAt(now, signal, reviewDay) {
  if (signal === 'gap' || signal === 'struggling') return startOfLocalDay(now) + DAY_MS + 9 * 60 * 60 * 1000;
  const date = new Date(startOfLocalDay(now) + 9 * 60 * 60 * 1000);
  let days = (reviewDay - date.getDay() + 7) % 7;
  if (days === 0) days = 7;
  return date.getTime() + days * DAY_MS;
}

function serializeCard(card) {
  return {
    ...card,
    due: dateValue(card?.due, Date.now()),
    last_review: dateValue(card?.last_review, 0) || null
  };
}

function deserializeCard(value, now = Date.now()) {
  const source = value && typeof value === 'object' ? value : {};
  return {
    ...createEmptyCard(new Date(dateValue(source.due, now))),
    ...source,
    due: new Date(dateValue(source.due, now)),
    last_review: dateValue(source.last_review, 0) ? new Date(Number(source.last_review)) : undefined
  };
}

function normalizeSettings(value) {
  const source = value && typeof value === 'object' ? value : {};
  return {
    dailyNewTarget: Math.round(clamp(finiteSetting(source.dailyNewTarget, DEFAULT_LEARNING_SETTINGS.dailyNewTarget), 0, 12)),
    weekdayReviewTarget: Math.round(clamp(finiteSetting(source.weekdayReviewTarget, DEFAULT_LEARNING_SETTINGS.weekdayReviewTarget), 0, 30)),
    weeklyReviewDay: Math.round(clamp(
      Number.isFinite(Number(source.weeklyReviewDay)) ? source.weeklyReviewDay : DEFAULT_LEARNING_SETTINGS.weeklyReviewDay,
      0,
      6
    )),
    weeklyReviewTarget: Math.round(clamp(finiteSetting(source.weeklyReviewTarget, DEFAULT_LEARNING_SETTINGS.weeklyReviewTarget), 0, 60)),
    requestRetention: clamp(finiteSetting(source.requestRetention, DEFAULT_LEARNING_SETTINGS.requestRetention), 0.75, 0.97),
    preferredLanguage: cleanText(source.preferredLanguage || DEFAULT_LEARNING_SETTINGS.preferredLanguage, 24).toLocaleLowerCase('en-US') || 'java'
  };
}

function createLearningState() {
  return {
    schemaVersion: 3,
    settings: { ...DEFAULT_LEARNING_SETTINGS },
    items: {},
    templates: {},
    deletedItems: {},
    suppressedItems: {},
    analysis: {},
    reviewLog: [],
    changeLog: [],
    updatedAt: 0
  };
}

function normalizeEvidence(value) {
  if (!value || typeof value !== 'object') return null;
  const observedAt = dateValue(value.observedAt, Date.now());
  const type = cleanText(value.type, 32) || 'analysis';
  return {
    id: cleanText(value.id, 40) || stableId('ev', [type, observedAt, value.summary]),
    type,
    signal: Object.hasOwn(SIGNAL_BASE, value.signal) ? value.signal : 'neutral',
    confidence: clamp(value.confidence ?? 0.5, 0, 1),
    summary: cleanText(value.summary, 600),
    conversationId: cleanText(value.conversationId, 80),
    messageIds: uniqueStrings(value.messageIds, 64, 100),
    attemptId: cleanText(value.attemptId, 40),
    observedAt
  };
}

function normalizeLesson(value) {
  if (!value || typeof value !== 'object') return null;
  return {
    overview: cleanText(value.overview, 4000),
    keyPoints: uniqueStrings(value.keyPoints, 12, 320),
    pitfalls: uniqueStrings(value.pitfalls, 10, 320),
    example: cleanMultilineText(value.example, 6000)
  };
}

function normalizeExercise(value) {
  if (!value || typeof value !== 'object') return null;
  const type = PRACTICE_TYPES.has(value.type) ? value.type : 'short_answer';
  return {
    type,
    title: cleanText(value.title, 120) || '掌握度检测',
    prompt: cleanText(value.prompt, 6000),
    instructions: cleanText(value.instructions, 1200),
    language: cleanText(value.language, 32).toLocaleLowerCase('en-US'),
    starterCode: String(value.starterCode || '').slice(0, 30000),
    choices: uniqueStrings(value.choices, 8, 600),
    examples: uniqueStrings(value.examples, 8, 1200),
    constraints: uniqueStrings(value.constraints, 12, 600),
    rubric: uniqueStrings(value.rubric, 10, 600),
    referenceAnswer: String(value.referenceAnswer || '').slice(0, 30000)
  };
}

function normalizeStudyPackage(value, itemId, now = Date.now()) {
  if (!value || typeof value !== 'object') return null;
  const generatedAt = dateValue(value.generatedAt, now);
  const exercise = normalizeExercise(value.exercise);
  const lesson = normalizeLesson(value.lesson);
  if (!exercise && !lesson) return null;
  return {
    id: cleanText(value.id, 40) || stableId('pkg', [itemId, generatedAt, exercise?.prompt]),
    lesson,
    exercise,
    generatedAt,
    model: cleanText(value.model, 120)
  };
}

function normalizeAttempt(value, itemId, now = Date.now()) {
  if (!value || typeof value !== 'object') return null;
  const submittedAt = dateValue(value.submittedAt, now);
  const verdict = PRACTICE_VERDICTS.has(value.verdict) ? value.verdict : 'incorrect';
  return {
    id: cleanText(value.id, 40) || stableId('attempt', [itemId, submittedAt, value.answer]),
    packageId: cleanText(value.packageId, 40),
    type: PRACTICE_TYPES.has(value.type) ? value.type : 'short_answer',
    answer: String(value.answer || '').slice(0, 40000),
    score: clamp(value.score, 0, 100),
    verdict,
    feedback: cleanText(value.feedback, 4000),
    strengths: uniqueStrings(value.strengths, 10, 500),
    gaps: uniqueStrings(value.gaps, 10, 500),
    nextStep: cleanText(value.nextStep, 1000),
    rating: Math.round(clamp(value.rating, Rating.Again, Rating.Easy)),
    submittedAt,
    model: cleanText(value.model, 120)
  };
}

function normalizeSourceRef(value) {
  if (!value || typeof value !== 'object') return null;
  const conversationId = cleanText(value.conversationId, 80);
  const messageId = cleanText(value.messageId, 100);
  if (!conversationId || !messageId) return null;
  return {
    conversationId,
    messageId,
    excerpt: cleanText(value.excerpt, 420)
  };
}

function normalizeItem(value, id, now = Date.now()) {
  const source = value && typeof value === 'object' ? value : {};
  const mastery = source.mastery && typeof source.mastery === 'object' ? source.mastery : {};
  const review = source.review && typeof source.review === 'object' ? source.review : {};
  const knowledgePath = inferKnowledgePath(source);
  const packages = (Array.isArray(source.study?.packages) ? source.study.packages : [])
    .map(item => normalizeStudyPackage(item, id, now)).filter(Boolean);
  const attempts = (Array.isArray(source.study?.attempts) ? source.study.attempts : [])
    .map(item => normalizeAttempt(item, id, now)).filter(Boolean);
  return {
    id,
    kind: source.kind === 'knowledge' ? 'knowledge' : 'problem',
    title: cleanText(source.title, 100) || '未命名学习项',
    question: cleanText(source.question, 2400),
    labels: uniqueStrings(source.labels, 8, 42),
    prerequisiteLabels: uniqueStrings(source.prerequisiteLabels, 8, 42),
    knowledgePath,
    language: inferLanguage({ ...source, knowledgePath }),
    diagnosis: cleanText(source.diagnosis, 360),
    canonicalKey: cleanText(source.canonicalKey, 120).toLocaleLowerCase('zh-CN'),
    sourceRefs: (Array.isArray(source.sourceRefs) ? source.sourceRefs : []).map(normalizeSourceRef).filter(Boolean),
    evidence: (Array.isArray(source.evidence) ? source.evidence : []).map(normalizeEvidence).filter(Boolean),
    mastery: {
      score: clamp(mastery.score ?? 42, 0, 100),
      confidence: clamp(mastery.confidence ?? 0.2, 0, 1),
      evidenceCount: Math.max(0, Math.round(Number(mastery.evidenceCount) || 0)),
      lastSignal: Object.hasOwn(SIGNAL_BASE, mastery.lastSignal) ? mastery.lastSignal : 'neutral',
      lastObservedAt: dateValue(mastery.lastObservedAt, 0)
    },
    review: {
      card: serializeCard(deserializeCard(review.card, now)),
      lastRating: Math.round(clamp(review.lastRating, 0, 4)),
      lastReviewedAt: dateValue(review.lastReviewedAt, 0),
      reviewCount: Math.max(0, Math.round(Number(review.reviewCount) || 0))
    },
    videoEligible: Boolean(source.videoEligible),
    study: {
      packages,
      activePackageId: cleanText(source.study?.activePackageId, 40) || packages.at(-1)?.id || '',
      attempts
    },
    revision: Math.max(1, Math.round(Number(source.revision) || 1)),
    manualFields: Object.fromEntries(EDITABLE_ITEM_FIELDS
      .filter(field => dateValue(source.manualFields?.[field], 0))
      .map(field => [field, dateValue(source.manualFields[field], now)])),
    createdAt: dateValue(source.createdAt, now),
    updatedAt: dateValue(source.updatedAt, now),
    archived: Boolean(source.archived)
  };
}

// 同类同名的条目合并成一条：保留最早创建的作为主体，其余的证据、来源、标签
// 与复习记录并入，返回「旧 id -> 保留 id」的改写表。
function dedupeLearningItems(items) {
  const byKey = new Map();
  const remap = new Map();
  for (const item of Object.values(items).sort((a, b) => a.createdAt - b.createdAt)) {
    const key = normalizedTitleKey(item);
    const kept = byKey.get(key);
    if (!kept) {
      byKey.set(key, item);
      continue;
    }
    kept.labels = uniqueStrings([...kept.labels, ...item.labels], 8, 42);
    kept.prerequisiteLabels = uniqueStrings([...kept.prerequisiteLabels, ...item.prerequisiteLabels], 8, 42);
    for (const ref of item.sourceRefs) {
      if (!kept.sourceRefs.some(existing => existing.conversationId === ref.conversationId && existing.messageId === ref.messageId)) {
        kept.sourceRefs.push(ref);
      }
    }
    for (const evidence of item.evidence) {
      if (!kept.evidence.some(existing => existing.id === evidence.id)) kept.evidence.push(evidence);
    }
    kept.study.packages.push(...item.study.packages.filter(
      entry => !kept.study.packages.some(existing => existing.id === entry.id)
    ));
    kept.study.attempts.push(...item.study.attempts.filter(
      entry => !kept.study.attempts.some(existing => existing.id === entry.id)
    ));
    // 掌握度取证据更充分的一方，复习进度取更靠前的到期时间。
    if (item.mastery.evidenceCount > kept.mastery.evidenceCount) kept.mastery = item.mastery;
    if (item.review.reviewCount > kept.review.reviewCount) kept.review = item.review;
    kept.videoEligible ||= item.videoEligible;
    kept.question ||= item.question;
    kept.diagnosis ||= item.diagnosis;
    kept.canonicalKey ||= item.canonicalKey;
    kept.updatedAt = Math.max(kept.updatedAt, item.updatedAt);
    kept.revision += 1;
    remap.set(item.id, kept.id);
    delete items[item.id];
  }
  return remap;
}

function remapItemIds(values, remap) {
  if (!remap.size) return values;
  return (Array.isArray(values) ? values : []).map(id => remap.get(id) || id);
}

function sanitizeLearningState(value, now = Date.now()) {
  const source = value && typeof value === 'object' ? value : {};
  const items = {};
  for (const [id, item] of Object.entries(source.items || {})) {
    if (!/^l_[a-f0-9]{16}$/i.test(id)) continue;
    items[id] = normalizeItem(item, id, now);
  }
  // 早期版本的合并键两侧不对称，同一题会被反复沉淀成多条。合并键已修正，
  // 这里把历史遗留的重复条目并成一条，并记录 id 改写关系。
  const itemIdRemap = dedupeLearningItems(items);
  const deletedItems = {};
  const suppressedItems = {};
  for (const [id, record] of Object.entries(source.suppressedItems || {})) {
    if (!/^l_[a-f0-9]{16}$/i.test(id) || !record || typeof record !== 'object') continue;
    suppressedItems[id] = {
      id,
      kind: record.kind === 'knowledge' ? 'knowledge' : 'problem',
      title: cleanText(record.title, 100) || '已删除学习项',
      canonicalKeys: uniqueStrings(record.canonicalKeys, 12, 120).map(key => key.toLocaleLowerCase('zh-CN')),
      titleKeys: uniqueStrings(record.titleKeys, 12, 120).map(key => key.toLocaleLowerCase('zh-CN')),
      sourceRefs: (Array.isArray(record.sourceRefs) ? record.sourceRefs : []).map(normalizeSourceRef).filter(Boolean)
        .map(ref => ({ conversationId: ref.conversationId, messageId: ref.messageId, excerpt: '' })),
      deletedAt: dateValue(record.deletedAt, now)
    };
  }
  for (const [id, record] of Object.entries(source.deletedItems || {})) {
    if (!/^l_[a-f0-9]{16}$/i.test(id) || !record || typeof record !== 'object') continue;
    const snapshot = normalizeItem(record.snapshot || record.item || {}, id, now);
    const normalizedRecord = {
      id,
      snapshot,
      canonicalKeys: uniqueStrings(record.canonicalKeys, 12, 120).map(key => key.toLocaleLowerCase('zh-CN')),
      titleKeys: uniqueStrings(record.titleKeys, 12, 120).map(key => key.toLocaleLowerCase('zh-CN')),
      deletedAt: dateValue(record.deletedAt, now),
      deletedRevision: Math.max(snapshot.revision, Math.round(Number(record.deletedRevision) || snapshot.revision)),
      reason: cleanText(record.reason, 240) || 'manual'
    };
    if (normalizedRecord.deletedAt + RECYCLE_RETENTION_MS > now) deletedItems[id] = normalizedRecord;
    if (!suppressedItems[id]) {
      suppressedItems[id] = {
        id,
        kind: snapshot.kind,
        title: snapshot.title,
        canonicalKeys: normalizedRecord.canonicalKeys,
        titleKeys: normalizedRecord.titleKeys,
        sourceRefs: snapshot.sourceRefs.map(ref => ({ conversationId: ref.conversationId, messageId: ref.messageId, excerpt: '' })),
        deletedAt: normalizedRecord.deletedAt
      };
    }
  }
  const templates = {};
  for (const [key, record] of Object.entries(source.templates || {})) {
    const normalized = normalizeLearningTemplate(record, key, now);
    if (normalized) templates[key] = normalized;
  }
  const analysis = {};
  for (const [conversationId, record] of Object.entries(source.analysis || {})) {
    if (!conversationId || !record || typeof record !== 'object') continue;
    analysis[conversationId] = {
      fingerprint: cleanText(record.fingerprint, 128),
      analyzedAt: dateValue(record.analyzedAt, 0),
      itemIds: uniqueStrings(remapItemIds(record.itemIds, itemIdRemap), 512, 40),
      messageVersions: uniqueStrings(record.messageVersions, 20000, 180),
      history: (Array.isArray(record.history) ? record.history : []).slice(-MAX_ANALYSIS_HISTORY).map(entry => ({
        fingerprint: cleanText(entry?.fingerprint, 128),
        analyzedAt: dateValue(entry?.analyzedAt, 0),
        itemIds: uniqueStrings(remapItemIds(entry?.itemIds, itemIdRemap), 512, 40)
      })).filter(entry => entry.fingerprint)
    };
  }
  return {
    schemaVersion: 3,
    settings: normalizeSettings(source.settings),
    items,
    templates,
    deletedItems,
    suppressedItems,
    analysis,
    reviewLog: (Array.isArray(source.reviewLog) ? source.reviewLog : []).filter(entry => entry && typeof entry === 'object'),
    changeLog: (Array.isArray(source.changeLog) ? source.changeLog : []).filter(entry => entry && typeof entry === 'object'),
    updatedAt: dateValue(source.updatedAt, 0)
  };
}

function normalizedCanonicalKey(item) {
  const explicit = cleanText(item.canonicalKey, 120).toLocaleLowerCase('zh-CN');
  if (explicit) return explicit;
  const title = cleanText(item.title, 100).toLocaleLowerCase('zh-CN').replace(/[^\p{L}\p{N}]+/gu, '');
  return `${item.kind === 'knowledge' ? 'k' : 'p'}:${title}`;
}

function normalizedTitleKey(item) {
  return `${item?.kind === 'knowledge' ? 'k' : 'p'}:${cleanText(item?.title, 100)
    .toLocaleLowerCase('zh-CN')
    .replace(/[^\p{L}\p{N}]+/gu, '')}`;
}

function tombstoneMatches(state, analysisItem) {
  const canonicalKey = normalizedCanonicalKey(analysisItem);
  const titleKey = normalizedTitleKey(analysisItem);
  return Object.values(state.suppressedItems || {}).some(record => {
    if (record.kind !== analysisItem.kind) return false;
    return record.canonicalKeys.includes(canonicalKey) || record.titleKeys.includes(titleKey);
  });
}

function learningItemId(conversationId, item) {
  const firstMessage = uniqueStrings(item.sourceMessageIds, 1, 100)[0] || normalizedCanonicalKey(item);
  return `l_${crypto.createHash('sha256').update(`${conversationId}\0${firstMessage}\0${normalizedCanonicalKey(item)}`).digest('hex').slice(0, 16)}`;
}

function normalizeAnalysisItem(value) {
  const source = value && typeof value === 'object' ? value : {};
  const signal = Object.hasOwn(SIGNAL_BASE, source.masterySignal) ? source.masterySignal : 'neutral';
  const knowledgePath = inferKnowledgePath(source);
  return {
    kind: source.kind === 'knowledge' ? 'knowledge' : 'problem',
    title: cleanText(source.title, 100),
    question: cleanText(source.question, 2400),
    labels: uniqueStrings(source.labels, 8, 42),
    prerequisiteLabels: uniqueStrings(source.prerequisiteLabels, 8, 42),
    knowledgePath,
    language: inferLanguage({ ...source, knowledgePath }),
    diagnosis: cleanText(source.diagnosis, 360),
    canonicalKey: cleanText(source.canonicalKey, 120),
    sourceMessageIds: uniqueStrings(source.sourceMessageIds, 24, 100),
    masterySignal: signal,
    confidence: clamp(source.confidence ?? 0.5, 0.1, 1),
    videoEligible: Boolean(source.videoEligible)
  };
}

function findMatchingItem(state, conversationId, analysisItem) {
  const messageIds = new Set(analysisItem.sourceMessageIds);
  const canonicalKey = normalizedCanonicalKey(analysisItem);
  const titleKey = normalizedTitleKey(analysisItem);
  return Object.values(state.items).find(item => {
    if (item.archived || item.kind !== analysisItem.kind) return false;
    const sameConversationMessage = item.sourceRefs.some(ref => ref.conversationId === conversationId && messageIds.has(ref.messageId));
    if (sameConversationMessage) return true;
    // 两侧都取归一化键：已存条目的 canonicalKey 可能为空（模型没给），
    // 此时必须回退到标题键，否则同一道题会被反复沉淀成多条。
    if (canonicalKey.length >= 5 && normalizedCanonicalKey(item) === canonicalKey) return true;
    return normalizedTitleKey(item) === titleKey;
  });
}

function updateMastery(mastery, signal, confidence, now) {
  const previous = mastery && typeof mastery === 'object' ? mastery : {};
  const evidenceCount = Math.max(0, Number(previous.evidenceCount) || 0);
  const score = evidenceCount
    ? clamp((Number(previous.score) || 42) + SIGNAL_DELTA[signal] * confidence, 0, 100)
    : SIGNAL_BASE[signal];
  return {
    score,
    confidence: clamp(1 - (1 - clamp(previous.confidence || 0, 0, 1)) * (1 - 0.24 * confidence), 0, 0.98),
    evidenceCount: evidenceCount + 1,
    lastSignal: signal,
    lastObservedAt: now
  };
}

function mergeLearningAnalysis(value, conversationId, analysisResult, sourceMessages, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const sourceMap = new Map((Array.isArray(sourceMessages) ? sourceMessages : []).map(message => [String(message.id || ''), message]));
  const itemIds = [];
  for (const rawItem of Array.isArray(analysisResult?.items) ? analysisResult.items : []) {
    const item = normalizeAnalysisItem(rawItem);
    if (!item.title || !item.sourceMessageIds.length) continue;
    if (tombstoneMatches(state, item)) continue;
    let existing = findMatchingItem(state, conversationId, item);
    const id = existing?.id || learningItemId(conversationId, item);
    if (!existing) {
      const due = nextPreferredReviewAt(now, item.masterySignal, state.settings.weeklyReviewDay);
      existing = normalizeItem({
        ...item,
        canonicalKey: normalizedCanonicalKey(item),
        mastery: updateMastery(null, item.masterySignal, item.confidence, now),
        review: { card: serializeCard(createEmptyCard(new Date(due))) },
        createdAt: now,
        updatedAt: now
      }, id, now);
    } else {
      if (!existing.manualFields.title) existing.title = item.title || existing.title;
      if (!existing.manualFields.question) existing.question = item.question || existing.question;
      if (!existing.manualFields.labels) existing.labels = uniqueStrings([...existing.labels, ...item.labels], 8, 42);
      if (!existing.manualFields.prerequisiteLabels) {
        existing.prerequisiteLabels = uniqueStrings([...existing.prerequisiteLabels, ...item.prerequisiteLabels], 8, 42);
      }
      // 已有分类路径保持稳定：同一条目在后续消息里被归到别的分支会让脑图分叉出
      // 重复节点，只有原本没有路径时才写入。
      if (!existing.manualFields.knowledgePath && !existing.knowledgePath.length) {
        existing.knowledgePath = item.knowledgePath;
      }
      if (!existing.manualFields.language) existing.language = item.language || existing.language;
      if (!existing.manualFields.diagnosis) existing.diagnosis = item.diagnosis || existing.diagnosis;
      existing.canonicalKey = normalizedCanonicalKey(item) || existing.canonicalKey;
      existing.mastery = updateMastery(existing.mastery, item.masterySignal, item.confidence, now);
      if (!existing.manualFields.videoEligible) existing.videoEligible ||= item.videoEligible;
      existing.updatedAt = now;
      existing.revision += 1;
    }

    const refs = [...existing.sourceRefs];
    for (const messageId of item.sourceMessageIds) {
      const source = sourceMap.get(messageId);
      if (!source || refs.some(ref => ref.conversationId === conversationId && ref.messageId === messageId)) continue;
      refs.push({ conversationId, messageId, excerpt: cleanText(source.content, 420) });
    }
    existing.sourceRefs = refs;
    existing.evidence.push(normalizeEvidence({
      id: stableId('ev', ['analysis', conversationId, analysisResult?.fingerprint, id]),
      type: 'analysis',
      signal: item.masterySignal,
      confidence: item.confidence,
      summary: item.diagnosis || `从日常提问识别到「${item.title}」`,
      conversationId,
      messageIds: item.sourceMessageIds,
      observedAt: now
    }));
    state.items[id] = existing;
    itemIds.push(id);
  }

  const previousAnalysis = state.analysis[conversationId];
  const analysisHistory = [...(previousAnalysis?.history || [])];
  if (previousAnalysis?.fingerprint && previousAnalysis.fingerprint !== analysisResult?.fingerprint) {
    analysisHistory.push({
      fingerprint: previousAnalysis.fingerprint,
      analyzedAt: previousAnalysis.analyzedAt,
      itemIds: previousAnalysis.itemIds
    });
  }
  state.analysis[conversationId] = {
    fingerprint: cleanText(analysisResult?.fingerprint, 128),
    analyzedAt: now,
    itemIds: uniqueStrings([...(previousAnalysis?.itemIds || []), ...itemIds], 512, 40),
    messageVersions: uniqueStrings([
      ...(previousAnalysis?.messageVersions || []),
      ...(Array.isArray(analysisResult?.messageVersions) ? analysisResult.messageVersions : [])
    ], 20000, 180),
    history: analysisHistory.slice(-MAX_ANALYSIS_HISTORY)
  };
  state.updatedAt = now;
  return state;
}

function mergeLeetCodeSubmissions(value, planQuestions, submissions, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const questions = new Map();
  for (const raw of Array.isArray(planQuestions) ? planQuestions : []) {
    const titleSlug = cleanText(raw?.titleSlug, 100).toLocaleLowerCase('en-US');
    if (!/^[a-z0-9][a-z0-9-]{0,99}$/.test(titleSlug)) continue;
    questions.set(titleSlug, raw);
  }
  const ordered = (Array.isArray(submissions) ? submissions : [])
    .filter(entry => questions.has(cleanText(entry?.titleSlug, 100).toLocaleLowerCase('en-US')))
    .sort((a, b) => dateValue(a?.submittedAt, now) - dateValue(b?.submittedAt, now));
  let changed = false;

  for (const submission of ordered) {
    const titleSlug = cleanText(submission.titleSlug, 100).toLocaleLowerCase('en-US');
    const question = questions.get(titleSlug);
    const title = cleanText(question?.translatedTitle || question?.title || submission?.translatedTitle || submission?.title, 100);
    if (!title) continue;
    const canonicalKey = `leetcode:${titleSlug}`;
    const labels = uniqueStrings((question?.topicTags || []).flatMap(tag => [tag?.translatedName, tag?.name]), 8, 42);
    const analysisItem = {
      kind: 'problem',
      title,
      labels,
      knowledgePath: [question?.groupName, ...labels],
      canonicalKey
    };
    if (tombstoneMatches(state, analysisItem)) continue;

    let item = Object.values(state.items).find(candidate => {
      if (candidate.archived) return false;
      const candidateCanonical = cleanText(candidate.canonicalKey, 120).toLocaleLowerCase('zh-CN');
      if (candidateCanonical === canonicalKey) return true;
      return !candidateCanonical && normalizedTitleKey(candidate) === normalizedTitleKey(analysisItem);
    });
    const itemId = item?.id || stableId('l', ['leetcode-cn', titleSlug]);
    const evidenceId = stableId('ev', ['leetcode-cn', submission.id]);
    if (item?.evidence.some(evidence => evidence.id === evidenceId)) continue;

    const observedAt = dateValue(submission.submittedAt, now);
    const accepted = Boolean(submission.accepted) || /accepted|通过|成功/i.test(String(submission.statusDisplay || ''));
    const signal = accepted ? 'demonstrated' : 'struggling';
    const status = cleanText(submission.statusDisplay, 80) || (accepted ? '通过' : '未通过');
    const activityLabel = { new: '新题', review: '复习', attempt: '继续尝试', historical: '历史提交' }[submission.activityType] || '力扣提交';
    const detail = uniqueStrings([submission.lang, submission.runtime, submission.memory], 3, 60).join(' · ');

    if (!item) {
      const due = nextPreferredReviewAt(observedAt, signal, state.settings.weeklyReviewDay);
      item = normalizeItem({
        kind: 'problem',
        title,
        question: `力扣 ${cleanText(question?.frontendId, 24)} ${title}`.trim(),
        labels,
        knowledgePath: analysisItem.knowledgePath,
        language: cleanText(submission.lang, 32),
        diagnosis: accepted ? '最近一次同步提交已通过' : '最近一次同步提交未通过，需要复盘',
        canonicalKey,
        mastery: { score: 42, confidence: 0, evidenceCount: 0, lastSignal: 'neutral', lastObservedAt: 0 },
        review: { card: serializeCard(createEmptyCard(new Date(due))) },
        createdAt: observedAt,
        updatedAt: observedAt
      }, itemId, observedAt);
    } else {
      if (!item.manualFields.labels) item.labels = uniqueStrings([...item.labels, ...labels], 8, 42);
      if (!item.manualFields.knowledgePath && !item.knowledgePath.length) item.knowledgePath = inferKnowledgePath(analysisItem);
      if (!item.manualFields.language && submission.lang) item.language = cleanText(submission.lang, 32).toLocaleLowerCase('en-US');
      if (!item.manualFields.diagnosis) item.diagnosis = accepted ? '最近一次同步提交已通过' : '最近一次同步提交未通过，需要复盘';
      item.canonicalKey = canonicalKey;
    }

    item.mastery = updateMastery(item.mastery, signal, 0.92, observedAt);
    item.evidence.push(normalizeEvidence({
      id: evidenceId,
      type: 'leetcode_submission',
      signal,
      confidence: 0.92,
      summary: `${activityLabel} · ${status}${detail ? ` · ${detail}` : ''}`,
      attemptId: `lc_${cleanText(submission.id, 36)}`,
      observedAt
    }));
    if (!item.review.reviewCount) {
      const due = nextPreferredReviewAt(observedAt, signal, state.settings.weeklyReviewDay);
      item.review.card = serializeCard(createEmptyCard(new Date(due)));
    }
    item.updatedAt = Math.max(item.updatedAt, observedAt);
    item.revision += 1;
    state.items[itemId] = item;
    changed = true;
  }

  if (changed) state.updatedAt = now;
  return state;
}

function mergeLeetCodeAnalysis(value, titleSlug, analysis, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const slug = cleanText(titleSlug, 100).toLocaleLowerCase('en-US');
  const item = Object.values(state.items).find(candidate => candidate.canonicalKey === `leetcode:${slug}`);
  const fingerprint = cleanText(analysis?.fingerprint, 80);
  if (!item || !fingerprint) return state;
  const evidenceId = stableId('ev', ['leetcode-analysis', slug, fingerprint]);
  if (item.evidence.some(evidence => evidence.id === evidenceId)) return state;
  const summary = cleanText(analysis?.summary, 600);
  if (!item.manualFields.diagnosis && summary) item.diagnosis = summary;
  item.evidence.push(normalizeEvidence({
    id: evidenceId,
    type: 'leetcode_analysis',
    signal: 'neutral',
    confidence: 0.9,
    summary: summary || '力扣提交轨迹分析已更新',
    observedAt: now
  }));
  item.updatedAt = now;
  item.revision += 1;
  state.updatedAt = now;
  return state;
}

function masteryState(score, confidence) {
  if (confidence < 0.25) return '待观察';
  if (score >= 78) return '已掌握';
  if (score >= 58) return '逐渐熟练';
  if (score >= 38) return '学习中';
  return '需要巩固';
}

function retrievability(item, now) {
  const card = deserializeCard(item.review.card, now);
  if (!card.reps || !card.last_review) return 0.55;
  try {
    return clamp(scheduler.get_retrievability(card, new Date(now), false), 0, 1);
  } catch {
    return 0.55;
  }
}

function viewItem(item, now) {
  const recall = retrievability(item, now);
  const effectiveScore = clamp(item.mastery.score - Math.max(0, 0.9 - recall) * 24, 0, 100);
  return {
    ...item,
    mastery: {
      ...item.mastery,
      effectiveScore,
      state: masteryState(effectiveScore, item.mastery.confidence),
      retrievability: recall
    },
    review: {
      ...item.review,
      dueAt: dateValue(item.review.card?.due, now),
      overdue: dateValue(item.review.card?.due, now) <= now
    }
  };
}

function applyReview(state, itemId, rating, now, metadata = {}) {
  const item = state.items[itemId];
  const normalizedRating = Math.round(clamp(rating, Rating.Again, Rating.Easy));
  if (!item || ![Rating.Again, Rating.Hard, Rating.Good, Rating.Easy].includes(normalizedRating)) {
    throw new Error('复习记录无效');
  }

  const result = scheduler.next(deserializeCard(item.review.card, now), new Date(now), normalizedRating);
  item.review = {
    card: serializeCard(result.card),
    lastRating: normalizedRating,
    lastReviewedAt: now,
    reviewCount: item.review.reviewCount + 1
  };
  const scoreDelta = { [Rating.Again]: -18, [Rating.Hard]: 2, [Rating.Good]: 12, [Rating.Easy]: 18 }[normalizedRating];
  item.mastery = {
    score: clamp(item.mastery.score + scoreDelta, 0, 100),
    confidence: clamp(item.mastery.confidence + 0.12, 0, 0.99),
    evidenceCount: item.mastery.evidenceCount + 1,
    lastSignal: normalizedRating === Rating.Again ? 'struggling' : (normalizedRating >= Rating.Good ? 'demonstrated' : 'learning'),
    lastObservedAt: now
  };
  item.evidence.push(normalizeEvidence({
    id: stableId('ev', ['review', itemId, now, metadata.attemptId]),
    type: metadata.attemptId ? 'practice' : 'self_review',
    signal: normalizedRating === Rating.Again ? 'struggling' : (normalizedRating >= Rating.Good ? 'demonstrated' : 'learning'),
    confidence: metadata.attemptId ? 0.9 : 0.65,
    summary: metadata.summary || `复习反馈：${{ [Rating.Again]: '忘了', [Rating.Hard]: '困难', [Rating.Good]: '掌握', [Rating.Easy]: '简单' }[normalizedRating]}`,
    attemptId: metadata.attemptId,
    observedAt: now
  }));
  item.updatedAt = now;
  item.revision += 1;
  state.reviewLog.push({
    itemId,
    rating: normalizedRating,
    attemptId: cleanText(metadata.attemptId, 40),
    source: metadata.attemptId ? 'practice' : 'self_review',
    reviewedAt: now,
    dueAt: dateValue(result.card.due, now),
    score: item.mastery.score
  });
  state.updatedAt = now;
  return state;
}

function reviewLearningItem(value, itemId, rating, now = Date.now()) {
  return applyReview(sanitizeLearningState(value, now), itemId, rating, now);
}

// 解题模板挂在「知识主题」上而不是单个条目：同一主题下的题目共用一套模板。
// 主题路径来自受控词表，所以键是稳定的。
function templateKeyForPath(path) {
  const normalized = uniqueStrings(path, 4, 42);
  return normalized.length ? normalized.join(' / ') : '';
}

function normalizeLearningTemplate(value, key, now = Date.now()) {
  if (!value || typeof value !== 'object') return null;
  const code = cleanMultilineText(value.code, 6000);
  if (!code) return null;
  return {
    key,
    path: uniqueStrings(value.path, 4, 42),
    title: cleanText(value.title, 80) || '解题模板',
    language: cleanText(value.language, 32).toLocaleLowerCase('en-US') || 'java',
    summary: cleanText(value.summary, 240),
    applicableWhen: uniqueStrings(value.applicableWhen, 6, 120),
    steps: uniqueStrings(value.steps, 8, 160),
    pitfalls: uniqueStrings(value.pitfalls, 6, 160),
    code,
    itemCount: Math.max(0, Math.round(Number(value.itemCount) || 0)),
    generatedAt: dateValue(value.generatedAt, now),
    model: cleanText(value.model, 120),
    manual: Boolean(value.manual),
    revision: Math.max(1, Math.round(Number(value.revision) || 1))
  };
}

function saveLearningTemplate(value, path, template, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const key = templateKeyForPath(path);
  if (!key) throw new Error('知识主题无效');
  const previous = state.templates[key];
  const normalized = normalizeLearningTemplate({
    ...template,
    path,
    generatedAt: now,
    revision: (previous?.revision || 0) + 1
  }, key, now);
  if (!normalized) throw new Error('模板内容为空');
  state.templates[key] = normalized;
  state.updatedAt = now;
  return state;
}

function deleteLearningTemplate(value, path, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const key = templateKeyForPath(path);
  if (key && state.templates[key]) {
    delete state.templates[key];
    state.updatedAt = now;
  }
  return state;
}

// 自动沉淀的触发条件：同一主题下累计到足够条目，且还没有模板（或模板明显落后于新证据）。
function pendingTemplateTopics(state, { minimumItems = 2 } = {}) {
  const grouped = new Map();
  for (const item of Object.values(state.items || {})) {
    if (item.archived) continue;
    const key = templateKeyForPath(item.knowledgePath);
    if (!key) continue;
    const record = grouped.get(key) || { key, path: item.knowledgePath, items: [], latestAt: 0 };
    record.items.push(item);
    record.latestAt = Math.max(record.latestAt, item.updatedAt || 0);
    grouped.set(key, record);
  }
  return [...grouped.values()]
    .filter(record => {
      if (record.items.length < minimumItems) return false;
      const template = state.templates[record.key];
      if (!template) return true;
      if (template.manual) return false;
      // 主题下条目增加过半，或有更新的证据时重新沉淀。
      return record.items.length >= template.itemCount * 2 || record.latestAt > template.generatedAt;
    })
    .sort((a, b) => b.items.length - a.items.length);
}

function saveLearningPackage(value, itemId, learningPackage, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const item = state.items[itemId];
  if (!item) throw new Error('学习项不存在');
  const normalized = normalizeStudyPackage({ ...learningPackage, generatedAt: now }, itemId, now);
  if (!normalized?.lesson || !normalized?.exercise) throw new Error('学习内容格式无效');
  if (!item.study.packages.some(entry => entry.id === normalized.id)) item.study.packages.push(normalized);
  item.study.activePackageId = normalized.id;
  item.updatedAt = now;
  item.revision += 1;
  state.updatedAt = now;
  return state;
}

function recordLearningAttempt(value, itemId, submission, judgment, now = Date.now()) {
  let state = sanitizeLearningState(value, now);
  const item = state.items[itemId];
  if (!item) throw new Error('学习项不存在');
  const requestedPackageId = cleanText(submission?.packageId, 40);
  const activePackage = (requestedPackageId && item.study.packages.find(entry => entry.id === requestedPackageId))
    || item.study.packages.find(entry => entry.id === item.study.activePackageId)
    || item.study.packages.at(-1);
  if (!activePackage?.exercise) throw new Error('请先生成检测题');
  if (requestedPackageId && activePackage.id !== requestedPackageId) throw new Error('检测题已更新，请重新提交');
  const score = clamp(judgment?.score, 0, 100);
  const verdict = PRACTICE_VERDICTS.has(judgment?.verdict)
    ? judgment.verdict
    : (score >= 85 ? 'correct' : (score >= 55 ? 'partial' : 'incorrect'));
  const rating = verdict === 'incorrect' ? Rating.Again : (verdict === 'partial' ? Rating.Hard : (score >= 96 ? Rating.Easy : Rating.Good));
  const attempt = normalizeAttempt({
    id: stableId('attempt', [itemId, activePackage.id, now, submission?.answer]),
    packageId: activePackage.id,
    type: activePackage.exercise.type,
    answer: submission?.answer,
    score,
    verdict,
    feedback: judgment?.feedback,
    strengths: judgment?.strengths,
    gaps: judgment?.gaps,
    nextStep: judgment?.nextStep,
    rating,
    submittedAt: now,
    model: judgment?.model
  }, itemId, now);
  item.study.attempts.push(attempt);
  state = applyReview(state, itemId, rating, now, {
    attemptId: attempt.id,
    summary: `AI 检测 ${score} 分：${attempt.feedback || attempt.nextStep || verdict}`
  });
  return state;
}

function normalizeItemField(field, value, currentItem) {
  if (field === 'title') return cleanText(value, 100) || currentItem.title;
  if (field === 'question') return cleanText(value, 2400);
  if (field === 'diagnosis') return cleanText(value, 360);
  if (field === 'labels' || field === 'prerequisiteLabels') return uniqueStrings(value, 8, 42);
  if (field === 'knowledgePath') return compactKnowledgePath(value);
  if (field === 'language') return cleanText(value, 32).toLocaleLowerCase('en-US');
  if (field === 'videoEligible') return Boolean(value);
  return undefined;
}

function sameItemField(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function learningConflict(message, current, conflicts) {
  const error = new Error(message);
  error.code = 'LEARNING_CONFLICT';
  error.current = current;
  error.conflicts = conflicts;
  return error;
}

function patchLearningItem(value, itemId, patch, options = {}, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const item = state.items[itemId];
  if (!item) throw learningConflict('学习项已被删除或不存在', null, ['deleted']);
  const source = patch && typeof patch === 'object' ? patch : {};
  const fields = EDITABLE_ITEM_FIELDS.filter(field => Object.hasOwn(source, field));
  if (!fields.length) throw new Error('没有可保存的修改');

  const expectedRevision = Math.max(0, Math.round(Number(options.expectedRevision) || 0));
  const base = options.base && typeof options.base === 'object' ? options.base : {};
  if (expectedRevision && expectedRevision !== item.revision) {
    const conflicts = fields.filter(field => !Object.hasOwn(base, field)
      || !sameItemField(item[field], normalizeItemField(field, base[field], item)));
    if (conflicts.length) throw learningConflict('知识项在编辑期间已更新', item, conflicts);
  }

  const changed = [];
  for (const field of fields) {
    const nextValue = normalizeItemField(field, source[field], item);
    if (field === 'knowledgePath' && !nextValue.length) throw new Error('知识路径不能为空');
    if (sameItemField(item[field], nextValue)) continue;
    item[field] = nextValue;
    item.manualFields[field] = now;
    changed.push(field);
  }
  if (!changed.length) return state;
  const baseRevision = item.revision;
  item.revision += 1;
  item.updatedAt = now;
  state.changeLog.push({
    id: stableId('change', [itemId, now, 'patch', changed.join(',')]),
    itemId,
    type: 'patch',
    fields: changed,
    source: 'user',
    baseRevision,
    resultRevision: item.revision,
    changedAt: now
  });
  state.updatedAt = now;
  return state;
}

function deleteLearningItem(value, itemId, options = {}, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const item = state.items[itemId];
  if (!item) {
    if (state.deletedItems[itemId]) return state;
    throw learningConflict('学习项已被删除或不存在', null, ['deleted']);
  }
  const expectedRevision = Math.max(0, Math.round(Number(options.expectedRevision) || 0));
  if (expectedRevision && expectedRevision !== item.revision) {
    throw learningConflict('知识项在删除前已更新', item, ['revision']);
  }
  const canonicalKeys = uniqueStrings([
    item.canonicalKey,
    normalizedCanonicalKey(item)
  ], 12, 120).map(key => key.toLocaleLowerCase('zh-CN'));
  const titleKeys = uniqueStrings([normalizedTitleKey(item)], 12, 120).map(key => key.toLocaleLowerCase('zh-CN'));
  state.deletedItems[itemId] = {
    id: itemId,
    snapshot: item,
    canonicalKeys,
    titleKeys,
    deletedAt: now,
    deletedRevision: item.revision,
    reason: cleanText(options.reason, 240) || 'manual'
  };
  state.suppressedItems[itemId] = {
    id: itemId,
    kind: item.kind,
    title: item.title,
    canonicalKeys,
    titleKeys,
    sourceRefs: item.sourceRefs.map(ref => ({ conversationId: ref.conversationId, messageId: ref.messageId, excerpt: '' })),
    deletedAt: now
  };
  delete state.items[itemId];
  state.changeLog.push({
    id: stableId('change', [itemId, now, 'delete']),
    itemId,
    type: 'delete',
    fields: [],
    source: 'user',
    baseRevision: item.revision,
    resultRevision: item.revision,
    changedAt: now
  });
  state.updatedAt = now;
  return state;
}

function restoreLearningItem(value, itemId, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const deleted = state.deletedItems[itemId];
  if (!deleted) throw new Error('已删除学习项不存在');
  if (state.items[itemId]) throw learningConflict('相同学习项已经存在', state.items[itemId], ['restored']);
  const item = normalizeItem(deleted.snapshot, itemId, now);
  const baseRevision = item.revision;
  item.revision += 1;
  item.updatedAt = now;
  state.items[itemId] = item;
  delete state.deletedItems[itemId];
  delete state.suppressedItems[itemId];
  state.changeLog.push({
    id: stableId('change', [itemId, now, 'restore']),
    itemId,
    type: 'restore',
    fields: [],
    source: 'user',
    baseRevision,
    resultRevision: item.revision,
    changedAt: now
  });
  state.updatedAt = now;
  return state;
}

function purgeDeletedLearningItem(value, itemId, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const deleted = state.deletedItems[itemId];
  if (!deleted) return state;
  delete state.deletedItems[itemId];
  state.changeLog.push({
    id: stableId('change', [itemId, now, 'purge']),
    itemId,
    type: 'purge',
    fields: [],
    source: 'user',
    baseRevision: deleted.deletedRevision,
    resultRevision: deleted.deletedRevision,
    changedAt: now
  });
  state.updatedAt = now;
  return state;
}

function updateLearningSettings(value, patch, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  state.settings = normalizeSettings({ ...state.settings, ...(patch && typeof patch === 'object' ? patch : {}) });
  state.updatedAt = now;
  return state;
}

function buildKnowledge(items) {
  const records = new Map();
  const treeRecords = new Map();
  const edges = new Map();
  for (const item of items) {
    const itemLabels = uniqueStrings([...item.labels, ...item.prerequisiteLabels], 16, 42);
    for (const label of itemLabels) {
      const key = label.toLocaleLowerCase('zh-CN');
      const record = records.get(key) || { name: label, itemIds: [], total: 0, confidence: 0, problemCount: 0, knowledgeCount: 0 };
      if (!record.itemIds.includes(item.id)) record.itemIds.push(item.id);
      record.total += item.mastery.effectiveScore;
      record.confidence += item.mastery.confidence;
      if (item.kind === 'knowledge') record.knowledgeCount += 1;
      else record.problemCount += 1;
      records.set(key, record);
    }
    const path = inferKnowledgePath(item);
    for (let depth = 0; depth < path.length; depth += 1) {
      const nodePath = path.slice(0, depth + 1);
      const id = stableId('kn', nodePath.map(part => part.toLocaleLowerCase('zh-CN')));
      const parentPath = nodePath.slice(0, -1);
      const parentId = parentPath.length
        ? stableId('kn', parentPath.map(part => part.toLocaleLowerCase('zh-CN')))
        : 'knowledge-root';
      const node = treeRecords.get(id) || {
        id,
        parentId,
        name: nodePath.at(-1),
        path: nodePath,
        depth,
        itemIds: [],
        total: 0,
        confidenceTotal: 0,
        directItemIds: []
      };
      if (!node.itemIds.includes(item.id)) {
        node.itemIds.push(item.id);
        node.total += item.mastery.effectiveScore;
        node.confidenceTotal += item.mastery.confidence;
      }
      if (depth === path.length - 1 && !node.directItemIds.includes(item.id)) node.directItemIds.push(item.id);
      treeRecords.set(id, node);
    }
    for (const prerequisite of item.prerequisiteLabels) {
      for (const label of item.labels) {
        if (prerequisite.toLocaleLowerCase('zh-CN') === label.toLocaleLowerCase('zh-CN')) continue;
        const key = `${prerequisite.toLocaleLowerCase('zh-CN')}\0${label.toLocaleLowerCase('zh-CN')}`;
        const edge = edges.get(key) || { from: prerequisite, to: label, itemIds: [] };
        if (!edge.itemIds.includes(item.id)) edge.itemIds.push(item.id);
        edges.set(key, edge);
      }
    }
  }
  const nodes = [...records.values()].map(record => ({
    ...record,
    score: record.itemIds.length ? record.total / record.itemIds.length : 0,
    confidence: record.itemIds.length ? record.confidence / record.itemIds.length : 0,
    state: masteryState(
      record.itemIds.length ? record.total / record.itemIds.length : 0,
      record.itemIds.length ? record.confidence / record.itemIds.length : 0
    )
  })).sort((a, b) => a.score - b.score || b.itemIds.length - a.itemIds.length);
  const tree = [...treeRecords.values()].map(node => {
    const score = node.itemIds.length ? node.total / node.itemIds.length : 0;
    const confidence = node.itemIds.length ? node.confidenceTotal / node.itemIds.length : 0;
    return {
      id: node.id,
      parentId: node.parentId,
      name: node.name,
      path: node.path,
      depth: node.depth,
      itemIds: node.itemIds,
      directItemIds: node.directItemIds,
      score,
      confidence,
      state: masteryState(score, confidence)
    };
  }).sort((a, b) => a.depth - b.depth || a.path.join('/').localeCompare(b.path.join('/'), 'zh-CN'));
  return { nodes, tree, edges: [...edges.values()] };
}

function buildLearningDashboard(value, now = Date.now()) {
  const state = sanitizeLearningState(value, now);
  const items = Object.values(state.items).filter(item => !item.archived).map(item => viewItem(item, now));
  const todayStart = startOfLocalDay(now);
  const todayEnd = todayStart + DAY_MS;
  const isWeeklyReviewDay = new Date(now).getDay() === state.settings.weeklyReviewDay;
  const reviewTarget = isWeeklyReviewDay ? state.settings.weeklyReviewTarget : state.settings.weekdayReviewTarget;
  const dueHorizon = isWeeklyReviewDay ? now + 7 * DAY_MS : todayEnd;
  let reviewPlan = items.filter(item => item.review.dueAt <= dueHorizon && item.createdAt < todayStart);
  if (reviewPlan.length < reviewTarget) {
    const selected = new Set(reviewPlan.map(item => item.id));
    const weak = items.filter(item => !selected.has(item.id) && item.createdAt < todayStart && item.mastery.effectiveScore < 72);
    reviewPlan.push(...weak);
  }
  reviewPlan = reviewPlan
    .sort((a, b) => Number(b.review.overdue) - Number(a.review.overdue)
      || a.mastery.effectiveScore - b.mastery.effectiveScore
      || a.review.dueAt - b.review.dueAt)
    .slice(0, reviewTarget);

  const newToday = items.filter(item => item.kind === 'problem' && item.createdAt >= todayStart && item.createdAt < todayEnd).length;
  const reviewsToday = state.reviewLog.filter(entry => Number(entry.reviewedAt) >= todayStart && Number(entry.reviewedAt) < todayEnd).length;
  const knowledgeGraph = buildKnowledge(items);
  const attempts = items.flatMap(item => item.study.attempts.map(attempt => ({ ...attempt, itemId: item.id, itemTitle: item.title })));
  const activity = {};
  for (let offset = 13; offset >= 0; offset -= 1) activity[localDayKey(todayStart - offset * DAY_MS)] = 0;
  for (const item of items) {
    const key = localDayKey(item.createdAt);
    if (Object.hasOwn(activity, key)) activity[key] += 1;
  }
  for (const review of state.reviewLog) {
    const key = localDayKey(Number(review.reviewedAt));
    if (Object.hasOwn(activity, key)) activity[key] += 1;
  }

  return {
    schemaVersion: 3,
    generatedAt: now,
    settings: state.settings,
    plan: {
      date: localDayKey(now),
      isWeeklyReviewDay,
      newTarget: state.settings.dailyNewTarget,
      newCompleted: newToday,
      reviewTarget,
      reviewCompleted: reviewsToday,
      reviewItems: reviewPlan.map(item => item.id)
    },
    stats: {
      total: items.length,
      problems: items.filter(item => item.kind === 'problem').length,
      knowledge: items.filter(item => item.kind === 'knowledge').length,
      mastered: items.filter(item => item.mastery.state === '已掌握').length,
      learning: items.filter(item => item.mastery.state === '学习中' || item.mastery.state === '逐渐熟练').length,
      weak: items.filter(item => item.mastery.state === '需要巩固').length,
      due: items.filter(item => item.review.overdue).length,
      averageMastery: items.length ? items.reduce((sum, item) => sum + item.mastery.effectiveScore, 0) / items.length : 0,
      attempts: attempts.length,
      correctAttempts: attempts.filter(attempt => attempt.verdict === 'correct').length,
      practiceAccuracy: attempts.length ? attempts.reduce((sum, attempt) => sum + attempt.score, 0) / attempts.length : 0,
      reviews: state.reviewLog.length,
      evidence: items.reduce((sum, item) => sum + item.evidence.length, 0),
      sourceSnapshots: items.reduce((sum, item) => sum + item.sourceRefs.length, 0)
    },
    deletedItems: Object.values(state.deletedItems).map(record => ({
      id: record.id,
      title: record.snapshot.title,
      kind: record.snapshot.kind,
      deletedAt: record.deletedAt,
      expiresAt: record.deletedAt + RECYCLE_RETENTION_MS,
      sourceRefs: record.snapshot.sourceRefs.map(ref => ({ conversationId: ref.conversationId, messageId: ref.messageId })),
      revision: record.deletedRevision
    })).sort((a, b) => b.deletedAt - a.deletedAt),
    items: items.sort((a, b) => b.updatedAt - a.updatedAt),
    templates: Object.values(state.templates || {}).sort((a, b) => b.generatedAt - a.generatedAt),
    pendingTemplates: pendingTemplateTopics(state).map(record => ({ key: record.key, path: record.path, itemCount: record.items.length })),
    knowledge: knowledgeGraph.nodes,
    knowledgeTree: knowledgeGraph.tree,
    knowledgeEdges: knowledgeGraph.edges,
    activity: Object.entries(activity).map(([date, count]) => ({ date, count })),
    timeline: items.flatMap(item => item.evidence.map(event => ({
      ...event,
      itemId: item.id,
      itemTitle: item.title
    }))).sort((a, b) => b.observedAt - a.observedAt).slice(0, 120)
  };
}

module.exports = {
  RECYCLE_RETENTION_MS,
  Rating,
  buildLearningDashboard,
  createLearningState,
  deleteLearningItem,
  mergeLeetCodeAnalysis,
  mergeLeetCodeSubmissions,
  mergeLearningAnalysis,
  patchLearningItem,
  purgeDeletedLearningItem,
  recordLearningAttempt,
  restoreLearningItem,
  reviewLearningItem,
  saveLearningPackage,
  saveLearningTemplate,
  deleteLearningTemplate,
  pendingTemplateTopics,
  templateKeyForPath,
  sanitizeLearningState,
  updateLearningSettings
};
