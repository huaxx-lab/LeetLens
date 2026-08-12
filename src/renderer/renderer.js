(function () {
  'use strict';

  document.body.classList.toggle('uses-native-titlebar', window.api?.platform === 'darwin');

  function syncWindowControlsOverlay() {
    const overlay = navigator.windowControlsOverlay;
    const rect = overlay?.getTitlebarAreaRect?.();
    const visible = Boolean(overlay?.visible && rect && rect.height > 0);
    document.body.classList.toggle('native-titlebar-visible', visible);
    document.documentElement.style.setProperty('--native-titlebar-area-y', `${visible ? rect.y : 0}px`);
    document.documentElement.style.setProperty('--native-titlebar-area-height', `${visible ? rect.height : 0}px`);
  }

  navigator.windowControlsOverlay?.addEventListener('geometrychange', syncWindowControlsOverlay);
  requestAnimationFrame(syncWindowControlsOverlay);

  window.api?.onAppMenuAction?.(action => {
    const learningTabs = {
      today: 'today',
      leetcode: 'leetcode',
      library: 'knowledge',
      insights: 'insights'
    };
    if (learningTabs[action]) {
      openLearningOverlay({ tab: learningTabs[action] }).catch(error => {
        console.warn('Failed to open learning region:', error);
      });
      return;
    }
    if (action === 'chat') {
      hideOverlays();
      return;
    }
    const selectors = {
      new: '#btn-new-chat',
      learning: '#btn-learning',
      usage: '#btn-usage',
      history: '#btn-history',
      settings: '#btn-settings'
    };
    document.querySelector(selectors[action])?.click();
  });

  // Keep this prompt byte-stable. Dynamic context belongs at the end of user messages
  // so Alibaba's prefix cache can reuse the longest possible request prefix.
  const SYSTEM_PROMPT = `你是一位资深算法工程师和 LeetCode 竞赛解题专家。始终使用中文，结论准确、简洁、可执行。

## 上下文规则
- 带有「浏览器当前选区」标记的内容，是用户刚刚主动选择的核心上下文。优先围绕它解释、排错或解题，不要向用户复述该标记。
- 如果内容只是代码片段或题目局部，不要虚构缺失条件；必要时明确写出最少的合理假设。
- 追问必须延续当前对话，直接回答新增问题，不重复整篇首答，除非用户明确要求重写。
- 遇到「衔接任务」时，先判断上一任务在已有部分回答中是否完成。若未完成，先给出简短的合并执行顺序，再把遗留任务与新增要求一起完成；若已完成，直接处理新要求。

## 新算法题的默认结构
### 思路分析
说明题意、关键观察、为什么选择该算法，以及算法如何工作。

### 复杂度
- 时间复杂度：O(?)
- 空间复杂度：O(?)

### Java 代码
提供完整、可直接提交到 LeetCode 的 Java 代码。中文注释应解释核心逻辑、关键数据结构、边界条件和易错步骤；禁止没有信息量的逐行翻译式注释。

### 关键点
列出 2-3 个最值得检查的边界或错误点。

## 图解规则
- 默认只输出文字和代码。用户当前请求没有明确要求图解时，绝不主动考虑、建议、生成或附带任何示例图。
- “不要图解”“无需画图”等否定表达不构成图解授权。
- 只有用户明确要求图解、流程图、示意图、可视化、Mermaid 或 SVG 时才生成图。
- 流程、状态转移和关系结构优先使用 mermaid 代码块；数组指针、树结构或精细布局使用 svg 代码块。
- 只有用户同时明确要求动态图、动画或动态演示时，才可使用 SVG 的声明式 SMIL animate / animateTransform；否则图必须保持静态。
- SVG 必须自包含，禁止脚本、事件处理器和外部资源。需要 SVG 时尽早输出完整 SVG 代码块，再继续解释。

## 工具真实性规则
- 工具能力以本次请求实际提供的工具定义为准；未收到工具定义时，视为当前没有任何可调用工具。
- 不得声称当前拥有未实际提供的联网、网页抓取、代码解释或图片搜索能力；不得虚构“联网搜索按钮”、用户授权步骤或平台开关。
- 用户要求实时检索，但本次请求未提供搜索工具时，应直接说明“当前供应商或模型在本应用中未接入联网搜索”，不要凭记忆冒充实时结果。
- 联网搜索、网页抓取、代码解释和图片搜索只在已实际提供且解决当前问题确有必要时调用；普通算法题不要为了展示能力而调用工具。
- 图片搜索同样受上述图解授权约束：用户未明确要求图片或图解时，不调用图片工具、不附带搜索图片。
- 使用工具后直接整合结论，不输出工具协议、调用参数或中间过程；引用外部事实时给出可核验来源。

如果用户并非在问完整算法题，应选择适合当前问题的短格式，不要强行套用上述章节。`;

  const INITIAL_TASK_PREFIX = '【任务】请基于下面的内容解决用户问题；如果它是算法题，请给出最优方案和完整 Java 实现。';
  const QUEUED_CONTINUATION_PREFIX = '【衔接任务】上一条回答可能在生成中被打断。请先判断上一任务是否已完成；若未完成，将遗留内容与下面的新要求统一规划并完成。';
  const AUTO_RESUME_INSTRUCTION = '【自动续接】上一轮响应因连接长时间无新数据或输出上限而中断。请严格从已有回答的中断处继续完成原任务，只输出尚未完成的后续内容，不要重复已有段落、代码或图解；如果已有回答其实已经完整，只需补充遗漏的收尾。';
  const REASONING_LABELS = Object.freeze({ off: '关闭', low: '低', high: '高', max: '最大' });
  const DEFAULT_CONTEXT_POLICY = Object.freeze({ contextWindowTokens: 128000, reservedOutputTokens: 8192, compressionThreshold: 0.95, postCompressionRatio: 0.82, recentMessages: 12, maxImages: 4 });
  const VIDEO_ELIGIBILITY_VERSION = 2;

  let conversations = {};
  let currentConvId = null;
  let currentMessages = [];
  let isStreaming = false;
  let activeStream = null;
  let autoFollow = true;
  let lastScrollTop = 0;
  let scrollUserIntentUntil = 0;
  let touchScrollY = null;
  let scrollFrame = 0;
  let windowTransitioning = false;
  let fullscreenTransitioning = false;
  let windowTransitionPinsBottom = false;
  let windowTransitionScrollFrame = 0;
  let suppressScrollChromeUntil = 0;
  let mermaidPromise = null;
  let mermaidRenderQueue = Promise.resolve();
  let selectionDraftPending = false;
  let availableModels = [];
  let usageScope = 'current';
  let videoAutoplay = true;
  let windowPinned = false;
  let reasoningEffort = 'high';
  let currentAiProvider = 'deepseek';
  let currentAiModel = 'deepseek-v4-flash';
  let settingsDraft = null;
  let quickModelSettings = null;
  let contextPolicy = { ...DEFAULT_CONTEXT_POLICY };
  let quickModelWarmPromise = null;
  const quickModelLoadingProviders = new Set();
  let videoHistory = [];
  let biliAuthState = { loggedIn: false, name: '', avatar: '', isVip: false, vipLabel: '' };
  let activeWorkspaceVideo = null;
  let activeVideoQuestionId = '';
  let activePlayer = null;
  let activeDashPlayer = null;
  let activePlayback = null;
  let activePlayerContext = null;
  let playerProgressTimer = 0;
  let playerRecoveryTimer = 0;
  let playerAutoplayCleanup = null;
  let playerLoadGeneration = 0;
  let videoCacheTimer = 0;
  let playerRecoveryAttempts = 0;
  let videoReturnTarget = null;
  let chatScrollAnchor = null;
  let activeVideoTab = 'player';
  let loginPollTimer = 0;
  let activeLoginSessionId = '';
  let biliLoginGeneration = 0;
  let biliAccountGeneration = 0;
  let activeOverlayTrigger = null;
  let imageViewerItems = [];
  let imageViewerIndex = 0;
  let imageViewerZoom = 1;
  let imageViewerReturnTarget = null;
  let learningDashboard = null;
  let learningTab = 'today';
  let learningQuery = '';
  let learningLabel = '';
  let learningPath = '';
  let learningSelectedItemId = '';
  let learningDetailOpen = false;
  let videoReturnLearningContext = null;
  let learningPracticeType = 'auto';
  let learningPackageBusy = false;
  let learningJudgeBusy = false;
  let activeLearningEditor = null;
  let activeLearningMindMap = null;
  let learningMindMapResizeObserver = null;
  let learningMindMapSelectedId = 'knowledge-root';
  let learningMindMapSearchMatches = [];
  let learningMindMapSearchIndex = -1;
  let learningMindMapViewState = null;
  let learningMindMapFocusedBranchId = '';
  let learningMindMapResizeTimer = 0;
  let learningMindMapStageSize = null;
  let learningSyntaxTimer = 0;
  let learningSyntaxGeneration = 0;
  let learningFormatGeneration = 0;
  let learningSyntaxMarkers = [];
  let learningEditorWheelCleanup = null;
  let learningEditorCompletionCleanup = null;
  let learningEditState = null;
  let learningDeleteConfirmItemId = '';
  let learningDeleteConflict = '';
  let learningMutationBusy = false;
  let lastDeletedLearningItem = null;
  let learningUndoTimer = 0;
  let learningPurgeConfirmItemId = '';
  let learningPurgeAllConfirming = false;
  let learningTemplateBusyKey = '';
  let learningSelectedTemplateKey = '';
  let learningTrashMessage = '';
  let leetcodeDashboard = null;
  let leetcodeBusy = '';
  let leetcodeError = '';
  let leetcodeFilter = 'all';
  let leetcodeQuery = '';
  let leetcodeOverviewView = ['library', 'activity', 'submissions'].includes(localStorage.getItem('leetcode-overview-view'))
    ? localStorage.getItem('leetcode-overview-view')
    : 'library';
  let leetcodeRoute = window.LeetCodeNavigation.createLeetCodeRoute();
  let leetcodeExpandedSubmissionId = '';
  let leetcodeHeatmapTooltipFrame = 0;
  let leetcodeWorkspace = null;
  let leetcodeWorkspaceBusy = '';
  let leetcodeWorkspaceError = '';
  let leetcodeWorkspaceLang = '';
  let leetcodeWorkspaceTestcase = '';
  let leetcodeWorkspaceResult = null;
  let leetcodeWorkspaceAnalysis = null;
  let leetcodeExecutionNotice = null;
  let leetcodeExecutionNoticeTimer = 0;
  let leetcodeExecutionNoticeTicker = 0;
  let leetcodeWorkspaceProblemTab = 'problem';
  let leetcodeWorkspaceSolutionSlug = '';
  let leetcodeWorkspaceSolutionsBusy = '';
  let leetcodeWorkspaceSolutionsError = '';
  let activeLeetcodeEditor = null;
  let leetcodeEditorCompletionCleanup = null;
  let activeLeetcodeWorkspaceSplit = null;
  let activeLeetcodeEditorSplit = null;
  let leetcodeWorkspaceSplitDirection = '';
  let leetcodeWorkspaceSplitResizeObserver = null;
  let leetcodeWorkspaceSplitFrame = 0;
  let leetcodeWorkspaceSplitResizeTimer = 0;
  let leetcodeQuestionRequestGeneration = 0;
  let leetcodeWorkspaceRequestGeneration = 0;
  let leetcodeSyntaxTimer = 0;
  let leetcodeSyntaxGeneration = 0;
  let leetcodeSyntaxResult = null;
  let leetcodeSyntaxMarkers = [];
  const leetcodeQuestionHistories = new Map();
  const leetcodeQuestionHistoryBusy = new Set();
  const leetcodeQuestionHistoryErrors = new Map();
  const leetcodeQuestionWorkspaces = new Map();
  const leetcodeQuestionWorkspaceErrors = new Map();
  const leetcodeWorkspaceRequests = new Map();
  const leetcodeSubmissionDetails = new Map();
  const leetcodeSubmissionDetailBusy = new Set();
  const leetcodeSubmissionDetailErrors = new Map();
  const leetcodeSubmissionAnalysisBusy = new Set();
  const leetcodeSubmissionAnalysisErrors = new Map();
  const leetcodeWorkspaceDrafts = new Map();
  const leetcodeWorkspaceSolutionLists = new Map();
  const leetcodeWorkspaceSolutionDetails = new Map();
  const leetcodeGalleryTimers = new Map();
  const leetcodeVideoPlayers = new Map();
  let leetcodeVideoRuntimePromise = null;
  let leetcodeVideoPlayerSequence = 0;
  const learningDrafts = new Map();

  function leetcodeIsWorkspace() {
    return leetcodeRoute.page === 'workspace';
  }

  function leetcodeCurrentSlug() {
    return leetcodeRoute.slug;
  }

  function restoreLeetcodeScroll(page = leetcodeRoute.page) {
    const top = page === 'overview' ? leetcodeRoute.overviewScrollTop : leetcodeRoute.questionScrollTop;
    requestAnimationFrame(() => {
      const content = $('#learning-content');
      if (content && leetcodeRoute.page === page) content.scrollTop = Math.max(0, Number(top) || 0);
    });
  }

  function setLeetcodeRoute(page, patch = {}) {
    leetcodeRoute = window.LeetCodeNavigation.navigateLeetCodeRoute(
      leetcodeRoute,
      { ...patch, page },
      $('#learning-content')?.scrollTop || 0
    );
  }

  function switchLeetcodeOverviewView(view, { focus = false } = {}) {
    const views = ['activity', 'submissions', 'library'];
    const nextIndex = views.indexOf(view);
    if (nextIndex < 0) return;
    leetcodeOverviewView = view;
    localStorage.setItem('leetcode-overview-view', view);
    if (leetcodeRoute.page !== 'overview') {
      destroyLeetcodeWorkspaceSplit();
      destroyActiveLeetcodeEditor();
      setLeetcodeRoute('overview', { slug: '', submissionId: '' });
    }
    renderLearningShellChrome();
    renderLeetcode();
    const content = $('#learning-content');
    if (content) content.scrollTop = 0;
    if (focus) requestAnimationFrame(() => document.querySelector(`[data-leetcode-overview-view="${view}"]`)?.focus({ preventScroll: true }));
  }

  function cacheLeetcodeWorkspace(workspace) {
    const slug = workspace?.question?.titleSlug;
    if (!slug) return;
    leetcodeQuestionWorkspaceErrors.delete(slug);
    leetcodeQuestionWorkspaces.delete(slug);
    leetcodeQuestionWorkspaces.set(slug, workspace);
    while (leetcodeQuestionWorkspaces.size > 24) {
      leetcodeQuestionWorkspaces.delete(leetcodeQuestionWorkspaces.keys().next().value);
    }
  }

  function loadLeetcodeQuestionWorkspace(slug) {
    if (!slug) return Promise.reject(new Error('题目标识无效'));
    if (leetcodeQuestionWorkspaces.has(slug)) return Promise.resolve(leetcodeQuestionWorkspaces.get(slug));
    if (leetcodeWorkspaceRequests.has(slug)) return leetcodeWorkspaceRequests.get(slug);
    const request = window.api.getLeetCodeWorkspace(slug).then(workspace => {
      cacheLeetcodeWorkspace(workspace);
      return workspace;
    }).finally(() => leetcodeWorkspaceRequests.delete(slug));
    leetcodeWorkspaceRequests.set(slug, request);
    return request;
  }

  function setLearningDraft(key, value) {
    if (learningDrafts.has(key)) learningDrafts.delete(key);
    learningDrafts.set(key, value);
    while (learningDrafts.size > 100) learningDrafts.delete(learningDrafts.keys().next().value);
  }

  const STREAM_RENDER_INTERVAL = 80;
  const MAX_CHAT_INPUT_CHARS = 100000;
  const CONVERSATION_SAVE_DEBOUNCE_MS = 24;
  const QUICK_MODEL_OPEN_BUDGET_MS = 140;
  const MAX_AUTO_RESUME_ATTEMPTS = 1;
  const AUTO_RESUME_DELAY_MS = 650;
  const PROVIDER_UI_DEFAULTS = Object.freeze({
    deepseek: Object.freeze({ name: 'DeepSeek', apiBase: 'https://api.deepseek.com', apiKey: '', model: 'deepseek-v4-flash', apiMode: 'auto', resolvedMode: 'chat', builtIn: true }),
    alibaba: Object.freeze({ name: '阿里云', apiBase: 'https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1', apiKey: '', model: 'qwen3.8-max-preview', apiMode: 'auto', resolvedMode: 'responses', builtIn: true }),
    'opencode-go': Object.freeze({ name: 'OpenCode Go', apiBase: 'https://opencode.ai/zen/go/v1', apiKey: '', model: 'deepseek-v4-flash', apiMode: 'auto', resolvedMode: 'chat', builtIn: true })
  });
  const saveQueues = new Map();
  const conversationSaveStates = new Map();
  const summaryQueues = new Map();
  const contextCompressionQueues = new Map();
  const videoSearchStates = new Map();
  const videoEligibilityChecks = new Map();
  const svgAnimationStates = new WeakMap();
  let videoEligibilityQueue = Promise.resolve();
  const numberFormatter = new Intl.NumberFormat('zh-CN');

  const $ = s => document.querySelector(s);
  const rendererAssetPromises = new Map();
  let appErrorTimer = 0;

  function showAppError(message) {
    let notice = $('#app-error-notice');
    if (!notice) {
      notice = document.createElement('div');
      notice.id = 'app-error-notice';
      notice.className = 'app-error-notice';
      notice.setAttribute('role', 'alert');
      document.body.appendChild(notice);
    }
    notice.textContent = String(message || '操作失败，请重试');
    notice.dataset.visible = 'true';
    if (appErrorTimer) clearTimeout(appErrorTimer);
    appErrorTimer = setTimeout(() => {
      delete notice.dataset.visible;
      appErrorTimer = 0;
    }, 6000);
  }

  function loadRendererScript(source, ready) {
    if (typeof ready === 'function' && ready()) return Promise.resolve();
    if (rendererAssetPromises.has(source)) return rendererAssetPromises.get(source);
    const pending = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = source;
      script.async = true;
      script.addEventListener('load', () => {
        if (typeof ready !== 'function' || ready()) resolve();
        else reject(new Error(`资源加载后未初始化：${source}`));
      }, { once: true });
      script.addEventListener('error', () => reject(new Error(`无法加载资源：${source}`)), { once: true });
      document.head.appendChild(script);
    }).catch(error => {
      rendererAssetPromises.delete(source);
      throw error;
    });
    rendererAssetPromises.set(source, pending);
    return pending;
  }

  function loadRendererStyle(source) {
    if (document.querySelector(`link[data-lazy-style="${source}"]`)) return Promise.resolve();
    const key = `style:${source}`;
    if (rendererAssetPromises.has(key)) return rendererAssetPromises.get(key);
    const pending = new Promise((resolve, reject) => {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = source;
      link.dataset.lazyStyle = source;
      link.addEventListener('load', resolve, { once: true });
      link.addEventListener('error', () => reject(new Error(`无法加载样式：${source}`)), { once: true });
      document.head.appendChild(link);
    }).catch(error => {
      rendererAssetPromises.delete(key);
      throw error;
    });
    rendererAssetPromises.set(key, pending);
    return pending;
  }

  async function ensureVideoRuntime() {
    await Promise.all([
      loadRendererScript('../../.renderer-assets/dashjs/dist/modern/umd/dash.mediaplayer.min.js', () => Boolean(window.dashjs)),
      loadRendererScript('../../.renderer-assets/artplayer/dist/artplayer.js', () => Boolean(window.Artplayer))
    ]);
  }

  async function ensureMindMapRuntime() {
    await Promise.all([
      loadRendererStyle('../../.renderer-assets/jsmind/style/jsmind.css'),
      loadRendererScript('../../.renderer-assets/jsmind/es6/jsmind.js', () => Boolean(window.jsMind))
    ]);
  }

  async function ensureCodeEditorRuntime() {
    await Promise.all([
      loadRendererStyle('../../.renderer-assets/codemirror/lib/codemirror.css'),
      loadRendererStyle('../../.renderer-assets/codemirror/addon/hint/show-hint.css'),
      loadRendererScript('../../.renderer-assets/codemirror/lib/codemirror.js', () => Boolean(window.CodeMirror))
    ]);
    await Promise.all([
      loadRendererScript('../../.renderer-assets/codemirror/mode/clike/clike.js'),
      loadRendererScript('../../.renderer-assets/codemirror/mode/python/python.js'),
      loadRendererScript('../../.renderer-assets/codemirror/mode/javascript/javascript.js'),
      loadRendererScript('../../.renderer-assets/codemirror/addon/edit/matchbrackets.js'),
      loadRendererScript('../../.renderer-assets/codemirror/addon/edit/closebrackets.js'),
      loadRendererScript('../../.renderer-assets/codemirror/addon/hint/show-hint.js'),
      loadRendererScript('../../.renderer-assets/codemirror/addon/hint/anyword-hint.js')
    ]);
  }

  async function ensureWorkspaceSplitRuntime() {
    await loadRendererScript('../../.renderer-assets/split.js/dist/split.min.js', () => typeof window.Split === 'function');
  }

  const CODE_COMPLETIONS = Object.freeze({
    java: [
      ['class', '关键字'], ['public', '关键字'], ['private', '关键字'], ['static', '关键字'], ['final', '关键字'], ['return', '关键字'],
      ['new', '关键字'], ['if', '关键字'], ['else', '关键字'], ['for', '关键字'], ['while', '关键字'], ['int', '类型'], ['long', '类型'],
      ['double', '类型'], ['boolean', '类型'], ['String', '类型'], ['StringBuilder', '类型'], ['List', '类型'], ['ArrayList', '类型'],
      ['Map', '类型'], ['HashMap', '类型'], ['Set', '类型'], ['HashSet', '类型'], ['Deque', '类型'], ['ArrayDeque', '类型'],
      ['PriorityQueue', '类型'], ['length', '属性'], ['size()', '方法'], ['add()', '方法'], ['get()', '方法'], ['set()', '方法'],
      ['put()', '方法'], ['contains()', '方法'], ['containsKey()', '方法'], ['getOrDefault()', '方法'], ['computeIfAbsent()', '方法'],
      ['charAt()', '方法'], ['substring()', '方法'], ['toCharArray()', '方法'], ['append()', '方法'], ['reverse()', '方法'],
      ['Arrays.sort()', '函数'], ['Arrays.fill()', '函数'], ['Collections.sort()', '函数'], ['Math.max()', '函数'], ['Math.min()', '函数'], ['Math.abs()', '函数']
    ],
    python: [
      ['def', '关键字'], ['class', '关键字'], ['return', '关键字'], ['if', '关键字'], ['elif', '关键字'], ['else', '关键字'],
      ['for', '关键字'], ['while', '关键字'], ['in', '关键字'], ['import', '关键字'], ['from', '关键字'], ['lambda', '关键字'],
      ['len()', '函数'], ['range()', '函数'], ['enumerate()', '函数'], ['zip()', '函数'], ['sorted()', '函数'], ['sum()', '函数'],
      ['min()', '函数'], ['max()', '函数'], ['abs()', '函数'], ['set()', '类型'], ['dict()', '类型'], ['list()', '类型'],
      ['defaultdict()', '类型'], ['Counter()', '类型'], ['deque()', '类型'], ['append()', '方法'], ['popleft()', '方法'], ['heappush()', '函数'],
      ['heappop()', '函数'], ['bisect_left()', '函数'], ['bisect_right()', '函数'], ['join()', '方法'], ['split()', '方法'], ['items()', '方法']
    ],
    cpp: [
      ['class', '关键字'], ['public', '关键字'], ['private', '关键字'], ['return', '关键字'], ['auto', '关键字'], ['const', '关键字'],
      ['if', '关键字'], ['else', '关键字'], ['for', '关键字'], ['while', '关键字'], ['int', '类型'], ['long long', '类型'],
      ['string', '类型'], ['vector', '类型'], ['unordered_map', '类型'], ['unordered_set', '类型'], ['queue', '类型'], ['deque', '类型'],
      ['stack', '类型'], ['priority_queue', '类型'], ['size()', '方法'], ['push_back()', '方法'], ['emplace_back()', '方法'], ['pop_back()', '方法'],
      ['find()', '方法'], ['count()', '方法'], ['insert()', '方法'], ['erase()', '方法'], ['sort()', '函数'], ['reverse()', '函数'],
      ['lower_bound()', '函数'], ['upper_bound()', '函数'], ['min()', '函数'], ['max()', '函数'], ['abs()', '函数'], ['accumulate()', '函数']
    ],
    javascript: [
      ['const', '关键字'], ['let', '关键字'], ['function', '关键字'], ['class', '关键字'], ['return', '关键字'], ['if', '关键字'],
      ['else', '关键字'], ['for', '关键字'], ['while', '关键字'], ['of', '关键字'], ['async', '关键字'], ['await', '关键字'],
      ['Array', '类型'], ['Object', '类型'], ['Map', '类型'], ['Set', '类型'], ['length', '属性'], ['push()', '方法'],
      ['pop()', '方法'], ['shift()', '方法'], ['unshift()', '方法'], ['slice()', '方法'], ['splice()', '方法'], ['includes()', '方法'],
      ['indexOf()', '方法'], ['map()', '方法'], ['filter()', '方法'], ['reduce()', '方法'], ['sort()', '方法'], ['forEach()', '方法'],
      ['Object.keys()', '函数'], ['Object.entries()', '函数'], ['Math.max()', '函数'], ['Math.min()', '函数'], ['Math.abs()', '函数']
    ],
    typescript: [
      ['interface', '关键字'], ['type', '关键字'], ['const', '关键字'], ['let', '关键字'], ['function', '关键字'], ['class', '关键字'],
      ['public', '关键字'], ['private', '关键字'], ['readonly', '关键字'], ['return', '关键字'], ['string', '类型'], ['number', '类型'],
      ['boolean', '类型'], ['Array', '类型'], ['Record', '类型'], ['Map', '类型'], ['Set', '类型'], ['length', '属性'],
      ['push()', '方法'], ['pop()', '方法'], ['slice()', '方法'], ['includes()', '方法'], ['map()', '方法'], ['filter()', '方法'],
      ['reduce()', '方法'], ['sort()', '方法'], ['Object.keys()', '函数'], ['Object.entries()', '函数'], ['Math.max()', '函数'], ['Math.min()', '函数']
    ]
  });

  const MEMBER_COMPLETIONS = Object.freeze({
    java: {
      arrays: ['sort()', 'parallelSort()', 'binarySearch()', 'fill()', 'copyOf()', 'copyOfRange()', 'equals()', 'deepEquals()', 'asList()', 'stream()', 'toString()', 'deepToString()', 'setAll()', 'parallelPrefix()'],
      collections: ['sort()', 'reverse()', 'binarySearch()', 'max()', 'min()', 'frequency()', 'swap()', 'fill()', 'shuffle()', 'unmodifiableList()'],
      math: ['max()', 'min()', 'abs()', 'ceil()', 'floor()', 'round()', 'sqrt()', 'pow()', 'log()', 'random()'],
      string: ['valueOf()', 'format()', 'join()', 'compareTo()', 'charAt()', 'substring()', 'split()', 'startsWith()', 'endsWith()', 'indexOf()', 'toCharArray()'],
      array: ['length', 'clone()'],
      list: ['size()', 'isEmpty()', 'add()', 'addAll()', 'get()', 'set()', 'remove()', 'contains()', 'indexOf()', 'subList()', 'sort()', 'stream()', 'clear()'],
      map: ['size()', 'isEmpty()', 'put()', 'putAll()', 'get()', 'getOrDefault()', 'containsKey()', 'containsValue()', 'computeIfAbsent()', 'keySet()', 'values()', 'entrySet()', 'remove()', 'clear()'],
      set: ['size()', 'isEmpty()', 'add()', 'addAll()', 'contains()', 'remove()', 'retainAll()', 'stream()', 'clear()'],
      deque: ['size()', 'isEmpty()', 'offer()', 'offerFirst()', 'offerLast()', 'peek()', 'peekFirst()', 'peekLast()', 'poll()', 'pollFirst()', 'pollLast()', 'push()', 'pop()', 'clear()'],
      '*': ['size()', 'isEmpty()', 'add()', 'get()', 'set()', 'put()', 'remove()', 'contains()', 'containsKey()', 'getOrDefault()', 'computeIfAbsent()', 'peek()', 'poll()', 'offer()', 'push()', 'pop()', 'clear()']
    },
    javascript: {
      math: ['max()', 'min()', 'abs()', 'ceil()', 'floor()', 'round()', 'sqrt()', 'pow()', 'random()'],
      object: ['keys()', 'values()', 'entries()', 'assign()', 'fromEntries()'],
      json: ['parse()', 'stringify()'],
      '*': ['push()', 'pop()', 'shift()', 'unshift()', 'slice()', 'splice()', 'includes()', 'indexOf()', 'map()', 'filter()', 'reduce()', 'sort()', 'forEach()', 'join()']
    },
    typescript: {
      math: ['max()', 'min()', 'abs()', 'ceil()', 'floor()', 'round()', 'sqrt()', 'pow()', 'random()'],
      object: ['keys()', 'values()', 'entries()', 'assign()', 'fromEntries()'],
      '*': ['push()', 'pop()', 'slice()', 'includes()', 'map()', 'filter()', 'reduce()', 'sort()', 'forEach()', 'join()']
    }
  });

  const JAVA_CONSTRUCTOR_COMPLETIONS = Object.freeze({
    list: [['ArrayList<>()', 'List 实现'], ['LinkedList<>()', 'List 实现']],
    set: [['HashSet<>()', 'Set 实现'], ['TreeSet<>()', '有序 Set']],
    map: [['HashMap<>()', 'Map 实现'], ['TreeMap<>()', '有序 Map']],
    deque: [['ArrayDeque<>()', 'Deque 实现'], ['LinkedList<>()', 'Deque 实现']],
    default: [
      ['ArrayList<>()', '集合'], ['HashMap<>()', '键值映射'], ['HashSet<>()', '集合'],
      ['ArrayDeque<>()', '双端队列'], ['PriorityQueue<>()', '优先队列'], ['StringBuilder()', '字符串构建器']
    ]
  });

  function normalizedCompletionLanguage(language) {
    const value = String(language || '').toLocaleLowerCase('en-US');
    if (value === 'python3' || value.startsWith('python')) return 'python';
    if (value === 'c++' || value.startsWith('cpp')) return 'cpp';
    if (value === 'js' || value.startsWith('javascript')) return 'javascript';
    if (value === 'ts' || value.startsWith('typescript')) return 'typescript';
    return value;
  }

  function renderCodeCompletion(element, _data, completion) {
    const completionText = completion.displayText || completion.text;
    element.dataset.completionKind = completion.kind || (completionText.includes('(') ? 'method' : 'symbol');
    const label = document.createElement('span');
    label.className = 'code-completion-label';
    label.textContent = completionText;
    element.appendChild(label);
    if (!completion.detail) return;
    const detail = document.createElement('small');
    detail.textContent = completion.detail;
    element.appendChild(detail);
  }

  function completionKind(detail, text) {
    if (detail === '关键字') return 'keyword';
    if (detail === '类型') return 'type';
    if (detail === '局部变量' || detail === '方法参数' || detail === '当前文件') return 'variable';
    if (detail === '属性') return 'property';
    return String(text || '').includes('(') ? 'method' : 'symbol';
  }

  function remoteCompletionKind(kind) {
    const value = Number(kind);
    if ([2, 3, 4].includes(value)) return 'method';
    if (value === 5) return 'property';
    if ([6, 12, 13].includes(value)) return 'variable';
    if ([7, 8, 9, 22, 25].includes(value)) return 'type';
    if (value === 14) return 'keyword';
    return 'symbol';
  }

  function normalizedJavaType(type) {
    const source = String(type || '').replace(/\s+/g, '');
    const base = source.replace(/<.*>/, '').replace(/\[\]$/, '').split('.').pop().toLocaleLowerCase('en-US');
    if (source.endsWith('[]')) return 'array';
    if (['list', 'arraylist', 'linkedlist'].includes(base)) return 'list';
    if (['map', 'hashmap', 'treemap', 'linkedhashmap'].includes(base)) return 'map';
    if (['set', 'hashset', 'treeset', 'linkedhashset'].includes(base)) return 'set';
    if (['deque', 'queue', 'arraydeque', 'priorityqueue'].includes(base)) return 'deque';
    if (base === 'string' || base === 'stringbuilder') return 'string';
    return base;
  }

  function javaSymbolsBeforeCursor(editor, cursor) {
    const lines = editor.getValue().split('\n');
    const source = [...lines.slice(0, cursor.line), lines[cursor.line].slice(0, cursor.ch)].join('\n');
    const variables = new Map();
    const declaration = /\b([A-Za-z_$][\w$]*(?:\s*<[^;{}()=]+>)?(?:\s*\[\])*)\s+([A-Za-z_$][\w$]*)\s*(?=[=,;:)])/g;
    const primitives = new Set(['byte', 'short', 'int', 'long', 'float', 'double', 'boolean', 'char', 'var']);
    for (const match of source.matchAll(declaration)) {
      const rawType = match[1].trim();
      const baseType = rawType.replace(/<.*>/, '').replace(/\[\]$/, '').trim();
      if (!primitives.has(baseType) && !/^[A-Z]/.test(baseType)) continue;
      variables.set(match[2], { name: match[2], type: rawType, detail: match[0].trim().endsWith(')') ? '方法参数' : '局部变量' });
    }
    const methods = new Set();
    const methodPattern = /\b(?:public|protected|private|static|final|synchronized|abstract|native|\s)+[A-Za-z_$][\w$<>, ?\[\].]*\s+([A-Za-z_$][\w$]*)\s*\([^;{}]*\)\s*\{/g;
    for (const match of source.matchAll(methodPattern)) methods.add(match[1]);
    return { source, variables, methods };
  }

  function javaConstructorCompletions(lineBeforeCursor, prefix) {
    const assignment = lineBeforeCursor.match(/([A-Za-z_$][\w$]*(?:\s*<[^>]+>)?(?:\s*\[\])?)\s+[A-Za-z_$][\w$]*\s*=\s*new\s+(?:[A-Za-z_$][\w$]*)?$/);
    const expectedType = normalizedJavaType(assignment?.[1]);
    const definitions = JAVA_CONSTRUCTOR_COMPLETIONS[expectedType] || JAVA_CONSTRUCTOR_COMPLETIONS.default;
    return definitions
      .filter(([text]) => !prefix || text.toLocaleLowerCase('en-US').startsWith(prefix))
      .map(([text, detail]) => ({ text, displayText: text, detail, kind: 'type', render: renderCodeCompletion }));
  }

  function codeCompletionHint(editor, language) {
    const cursor = editor.getCursor();
    const line = editor.getLine(cursor.line);
    const lineBeforeCursor = line.slice(0, cursor.ch);
    const memberMatch = lineBeforeCursor.match(/([A-Za-z_$][\w$]*)\.([\w$]*)$/);
    const normalizedLanguage = normalizedCompletionLanguage(language);
    if (memberMatch) {
      const ownerName = memberMatch[1];
      let owner = ownerName.toLocaleLowerCase('en-US');
      const memberPrefix = memberMatch[2].toLocaleLowerCase('en-US');
      const languageMembers = MEMBER_COMPLETIONS[normalizedLanguage] || {};
      let detail = ownerName;
      if (normalizedLanguage === 'java') {
        const symbol = javaSymbolsBeforeCursor(editor, cursor).variables.get(ownerName);
        if (symbol) {
          owner = normalizedJavaType(symbol.type);
          detail = symbol.type.replace(/\s+/g, ' ');
        }
      }
      const members = [...new Set(languageMembers[owner] || languageMembers['*'] || [])]
        .filter(text => !memberPrefix || text.toLocaleLowerCase('en-US').startsWith(memberPrefix))
        .map(text => ({ text, displayText: text, detail: text.includes('(') ? detail : '属性', kind: text.includes('(') ? 'method' : 'property', render: renderCodeCompletion }));
      return {
        list: members,
        from: window.CodeMirror.Pos(cursor.line, cursor.ch - memberMatch[2].length),
        to: cursor
      };
    }
    const constructorMatch = normalizedLanguage === 'java' && lineBeforeCursor.match(/\bnew\s+([A-Za-z_$][\w$]*)?$/);
    if (constructorMatch) {
      const prefix = String(constructorMatch[1] || '').toLocaleLowerCase('en-US');
      return {
        list: javaConstructorCompletions(lineBeforeCursor, prefix),
        from: window.CodeMirror.Pos(cursor.line, cursor.ch - prefix.length),
        to: cursor
      };
    }
    let start = cursor.ch;
    while (start && /[\w$+#-]/.test(line.charAt(start - 1))) start -= 1;
    const prefix = line.slice(start, cursor.ch).toLocaleLowerCase('en-US');
    const definitions = CODE_COMPLETIONS[normalizedLanguage] || [];
    const builtIns = definitions
      .filter(([text]) => !prefix || text.toLocaleLowerCase('en-US').startsWith(prefix))
      .map(([text, detail]) => ({ text, displayText: text, detail, kind: completionKind(detail, text), render: renderCodeCompletion }));
    const anyword = window.CodeMirror.hint.anyword(editor, {
      word: /[\w$]+/,
      range: 500
    });
    const scoped = [];
    if (normalizedLanguage === 'java') {
      const symbols = javaSymbolsBeforeCursor(editor, cursor);
      for (const symbol of symbols.variables.values()) {
        if (!prefix || symbol.name.toLocaleLowerCase('en-US').startsWith(prefix)) {
          scoped.push({ text: symbol.name, displayText: symbol.name, detail: symbol.type, kind: 'variable', render: renderCodeCompletion });
        }
      }
      for (const method of symbols.methods) {
        const text = `${method}()`;
        if (!prefix || method.toLocaleLowerCase('en-US').startsWith(prefix)) {
          scoped.push({ text, displayText: text, detail: '当前类', kind: 'method', render: renderCodeCompletion });
        }
      }
    }
    const seen = new Set();
    const list = [...scoped, ...(anyword.list || []).map(item => typeof item === 'string'
      ? { text: item, displayText: item, detail: '当前文件', kind: 'variable', render: renderCodeCompletion }
      : item), ...builtIns].filter(item => {
      const text = item?.text;
      if (!text || seen.has(text) || (prefix && !text.toLocaleLowerCase('en-US').startsWith(prefix))) return false;
      seen.add(text);
      return true;
    });
    return { ...anyword, list, from: window.CodeMirror.Pos(cursor.line, start), to: cursor };
  }

  function remoteCompletionText(item) {
    const source = String(item?.insertText || item?.text || item?.label || '');
    return source
      .replace(/\$\{\d+:([^}]*)\}/g, '$1')
      .replace(/\$\{\d+\}/g, '')
      .replace(/\$\d+/g, '');
  }

  function mergeRemoteCodeCompletions(local, remoteItems) {
    const seen = new Set();
    const list = [];
    for (const item of local?.list || []) {
      const text = typeof item === 'string' ? item : item?.text;
      if (!text || seen.has(text)) continue;
      seen.add(text);
      list.push(item);
    }
    for (const item of Array.isArray(remoteItems) ? remoteItems : []) {
      const text = remoteCompletionText(item);
      if (!text || seen.has(text)) continue;
      seen.add(text);
      list.push({
        text,
        displayText: String(item?.label || text),
        detail: String(item?.detail || item?.kind || 'Java 语义'),
        kind: remoteCompletionKind(item?.kind),
        render: renderCodeCompletion,
        className: 'is-remote-completion'
      });
    }
    return { ...local, list };
  }

  function completionRequestStillCurrent(editor, generation, expectedCursor, expectedCode) {
    if (editor !== activeLeetcodeEditor || !editor.hasFocus() || generation !== editor.state.remoteCompletionGeneration) return false;
    const cursor = editor.getCursor();
    return cursor.line === expectedCursor.line
      && cursor.ch === expectedCursor.ch
      && editor.getValue() === expectedCode;
  }

  function installCodeCompletion(editor, language) {
    let remoteTimer = 0;
    let generation = 0;
    const normalizedLanguage = normalizedCompletionLanguage(language);
    const show = remoteItems => {
      if (!editor.hasFocus()) editor.focus();
      try {
        editor.showHint({
          hint: instance => mergeRemoteCodeCompletions(codeCompletionHint(instance, language), remoteItems),
          completeSingle: false,
          closeOnUnfocus: true,
          alignWithWord: true,
          customKeys: {
            Tab: (_editor, handle) => handle.pick(),
            Enter: (_editor, handle) => handle.pick(),
            Up: (_editor, handle) => handle.moveFocus(-1),
            Down: (_editor, handle) => handle.moveFocus(1),
            Esc: (_editor, handle) => handle.close()
          },
          container: document.body
        });
      } catch (error) {
        console.warn('Failed to open code completion:', error);
      }
    };
    const open = () => {
      generation += 1;
      editor.state.remoteCompletionGeneration = generation;
      clearTimeout(remoteTimer);
      show([]);
      if (normalizedLanguage !== 'java' || typeof window.api.getRemoteCodeCompletions !== 'function') return;
      const requestGeneration = generation;
      const cursor = editor.getCursor();
      const code = editor.getValue();
      remoteTimer = setTimeout(async () => {
        try {
          const response = await window.api.getRemoteCodeCompletions({
            code,
            line: cursor.line,
            character: cursor.ch,
            language: 'java'
          });
          if (!completionRequestStillCurrent(editor, requestGeneration, cursor, code)) return;
          const items = Array.isArray(response) ? response : response?.items;
          if (Array.isArray(items) && items.length) show(items);
        } catch (error) {
          // Local suggestions are already visible; remote completion is optional.
        }
      }, 70);
    };
    const keyMap = { 'Ctrl-Space': open, 'Cmd-Space': open };
    editor.addKeyMap(keyMap);
    editor.state.openLocalCompletion = open;
    const onInput = (_instance, change) => {
      const cursor = editor.getCursor();
      const line = editor.getLine(cursor.line).slice(0, cursor.ch);
      const prefix = line.match(/[\w$]+$/)?.[0] || '';
      const inserted = (change.text || []).join('\n');
      const constructorContext = normalizedLanguage === 'java' && /\bnew\s+(?:[A-Za-z_$][\w$]*)?$/.test(line);
      if (/[\w$.]$/.test(inserted) && (prefix.length >= 1 || line.endsWith('.'))) open();
      else if (/\s$/.test(inserted) && constructorContext) open();
    };
    editor.on('inputRead', onInput);
    return () => {
      clearTimeout(remoteTimer);
      generation += 1;
      editor.state.remoteCompletionGeneration = generation;
      editor.off('inputRead', onInput);
      editor.removeKeyMap(keyMap);
      delete editor.state.openLocalCompletion;
      editor.closeHint?.();
    };
  }

  const contextManager = window.ContextManager;
  const messagesEl = $('#messages');
  const chatInput = $('#chat-input');
  const scrollBottomButton = $('#btn-scroll-bottom');
  const chatRail = $('#chat-rail');
  const chatContainer = $('#chat-container');
  const inputBar = $('.input-bar');
  let emptyState = $('#empty-state');
  let appWindowFocused = document.hasFocus();

  const MODAL_FOCUS_SELECTOR = [
    'a[href]',
    'button:not([disabled])',
    'input:not([disabled])',
    'select:not([disabled])',
    'textarea:not([disabled])',
    '[contenteditable="true"]',
    '[tabindex]:not([tabindex="-1"])'
  ].join(',');

  function activeModalLayer() {
    const imageViewer = $('#image-viewer');
    if (!imageViewer.classList.contains('hidden')) return imageViewer;
    return null;
  }

  function modalFocusables(layer) {
    return [...layer.querySelectorAll(MODAL_FOCUS_SELECTOR)]
      .filter(element => element.tabIndex >= 0 && !element.closest('[inert]') && element.getClientRects().length > 0);
  }

  function keepFocusInModal(event) {
    if (event.key !== 'Tab') return;
    const layer = activeModalLayer();
    if (!layer) return;
    const focusable = modalFocusables(layer);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    const current = document.activeElement;
    if (!layer.contains(current)) {
      event.preventDefault();
      (event.shiftKey ? last : first).focus({ preventScroll: true });
    } else if (event.shiftKey && current === first) {
      event.preventDefault();
      last.focus({ preventScroll: true });
    } else if (!event.shiftKey && current === last) {
      event.preventDefault();
      first.focus({ preventScroll: true });
    }
  }

  function handleHorizontalTabKey(event, tabSelector) {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    const tabs = [...event.currentTarget.querySelectorAll(tabSelector)];
    const current = event.target instanceof Element ? event.target.closest(tabSelector) : null;
    const currentIndex = tabs.indexOf(current);
    if (currentIndex < 0 || !tabs.length) return;
    let nextIndex = currentIndex;
    if (event.key === 'Home') nextIndex = 0;
    else if (event.key === 'End') nextIndex = tabs.length - 1;
    else if (event.key === 'ArrowLeft') nextIndex = (currentIndex - 1 + tabs.length) % tabs.length;
    else nextIndex = (currentIndex + 1) % tabs.length;
    event.preventDefault();
    tabs[nextIndex].click();
    tabs[nextIndex].focus({ preventScroll: true });
  }

  document.addEventListener('keydown', event => {
    if (event.key === 'Tab') document.body.dataset.keyboardNavigation = 'true';
  }, true);
  document.addEventListener('pointerdown', () => {
    delete document.body.dataset.keyboardNavigation;
  }, true);
  document.addEventListener('keydown', keepFocusInModal, true);

  // 播放信息栏高度写回 CSS 变量：播放区首屏高度 = 可用高度 - 信息栏，
  // 标题换行或多出徽章时也能精确占满一屏，不会多出几像素滚动条。
  const videoInfoRow = $('.video-now-row');
  if (videoInfoRow) {
    const videoInfoObserver = new ResizeObserver(() => {
      // offsetHeight 含内边距与边框，contentRect.height 不含 —— 用前者才能
      // 让播放区首屏高度精确扣除信息栏，不会把信息栏挤出可视区。
      const height = Math.ceil(videoInfoRow.offsetHeight || 40);
      $('.video-player-view')?.style.setProperty('--video-info-h', `${height}px`);
    });
    videoInfoObserver.observe(videoInfoRow);
  }

  let appliedComposerHeight = 0;
  let composerResizeTimer = 0;
  const applyComposerHeight = () => {
    const height = Math.ceil(inputBar.offsetHeight || 58);
    if (height === appliedComposerHeight) return;
    appliedComposerHeight = height;
    chatContainer.style.setProperty('--composer-height', `${height}px`);
  };
  const composerResizeObserver = new ResizeObserver(() => {
    if (!windowTransitioning) return applyComposerHeight();
    clearTimeout(composerResizeTimer);
    composerResizeTimer = setTimeout(applyComposerHeight, 180);
  });
  composerResizeObserver.observe(inputBar);

  const svgVisibilityObserver = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const state = svgAnimationStates.get(entry.target);
      if (!state) continue;
      state.inViewport = entry.isIntersecting && entry.intersectionRatio > 0;
      applySvgPlaybackState(entry.target, state);
    }
  }, { root: messagesEl, threshold: [0, 0.01] });
  // 一次交互可能连续 toggle 多个面板；用 rAF 合并成一次全量刷新，避免布局风暴。
  let svgLayerRefreshFrame = 0;
  const svgLayerObserver = new MutationObserver(() => {
    if (svgLayerRefreshFrame) return;
    svgLayerRefreshFrame = requestAnimationFrame(() => {
      svgLayerRefreshFrame = 0;
      refreshSvgAnimationPlayback();
    });
  });
  for (const layer of [$('#video-workspace'), ...document.querySelectorAll('.overlay')]) {
    if (layer) svgLayerObserver.observe(layer, { attributes: true, attributeFilter: ['class'] });
  }

  let svgResizeFrame = 0;

  function refreshResponsiveSvgs() {
    for (const canvas of document.querySelectorAll('.svg-canvas')) {
      // A canvas could retain a horizontal scroll offset from an earlier,
      // wider SVG while the window is being resized. SVG visuals are always
      // scaled as a whole, so an offset is never useful here.
      if (canvas.scrollLeft) canvas.scrollLeft = 0;
      const svg = canvas.querySelector(':scope > svg');
      if (svg) makeSvgResponsive(svg);
    }
  }

  const svgResizeObserver = new ResizeObserver(() => {
    // 全屏动画每帧都会触发；期间跳过，动画结束后统一刷新一次。
    if (windowTransitioning) return;
    if (svgResizeFrame) cancelAnimationFrame(svgResizeFrame);
    svgResizeFrame = requestAnimationFrame(() => {
      svgResizeFrame = 0;
      refreshResponsiveSvgs();
    });
  });
  svgResizeObserver.observe(messagesEl);

  // ===== Markdown =====

  function esc(text) {
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  const languageAliases = {
    js: 'javascript',
    ts: 'typescript',
    py: 'python',
    'c++': 'cpp',
    cs: 'csharp',
    sh: 'bash',
    shell: 'bash'
  };

  function codeCopyButtonHtml(extraClass = '') {
    return `<button class="btn-copy${extraClass ? ` ${extraClass}` : ''}" type="button" aria-label="复制代码" title="复制代码"><span class="copy-glyph" aria-hidden="true"></span></button>`;
  }

  const markdown = window.markdownit({
    html: false,
    breaks: true,
    linkify: true,
    typographer: true,
    highlight(code, info) {
      const requested = (info || '').trim().split(/\s+/)[0].toLowerCase();
      const language = languageAliases[requested] || requested;
      if (language && window.hljs?.getLanguage(language)) {
        try {
          return window.hljs.highlight(code, { language, ignoreIllegals: true }).value;
        } catch (error) {}
      }
      return esc(code);
    }
  });

  markdown.renderer.rules.fence = (tokens, index, options, env = {}) => {
    const token = tokens[index];
    const requested = (token.info || '').trim().split(/\s+/)[0].toLowerCase();
    if (requested === 'mermaid') {
      return `<div class="visual-block mermaid-block">
        <div class="visual-header"><span class="visual-dot mermaid-dot"></span><span>流程图解</span></div>
        <pre class="mermaid">${esc(token.content)}</pre>
      </div>`;
    }
    if (requested === 'svg') {
      return `<div class="visual-block svg-block">
        <div class="visual-actions hidden">
          <button class="tb-btn visual-control svg-animation-replay" type="button" title="重播动画" aria-label="重播动画"><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12a9 9 0 1 0 3-6.7L3 8" stroke-linecap="round" stroke-linejoin="round"/><path d="M3 3v5h5" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
          <button class="tb-btn visual-control svg-animation-toggle" type="button" title="暂停动画" aria-label="暂停动画"><svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg></button>
        </div>
        <pre class="svg-source hidden">${esc(token.content)}</pre>
        <div class="svg-canvas"></div>
      </div>`;
    }
    const language = languageAliases[requested] || requested;
    const label = requested || 'text';
    // The final answer is highlighted once at completion. Re-highlighting a
    // growing code block for every streamed token causes avoidable input lag.
    const highlighted = env.streaming
      ? esc(token.content)
      : markdown.options.highlight(token.content, language);
    const languageClass = language ? ` language-${esc(language)}` : '';

    return `<div class="code-block">
      <div class="code-header">
        <span class="code-lang">${esc(label)}</span>
        ${codeCopyButtonHtml()}
      </div>
      <pre><code class="hljs${languageClass}">${highlighted}</code></pre>
    </div>`;
  };

  const defaultLinkOpen = markdown.renderer.rules.link_open
    || ((tokens, index, options, env, self) => self.renderToken(tokens, index, options));

  markdown.renderer.rules.link_open = (tokens, index, options, env, self) => {
    tokens[index].attrSet('target', '_blank');
    tokens[index].attrSet('rel', 'noopener noreferrer');
    return defaultLinkOpen(tokens, index, options, env, self);
  };

  markdown.renderer.rules.table_open = () => '<div class="table-scroll"><table>';
  markdown.renderer.rules.table_close = () => '</table></div>';

  function balanceStreamingMarkdown(text) {
    const source = String(text || '');
    const fences = source.match(/^```/gm)?.length || 0;
    return fences % 2 === 0 ? source : `${source}\n\n\`\`\``;
  }

  function renderMarkdownMath(expression, displayMode) {
    try {
      const markup = window.katex?.renderToString(String(expression || '').trim(), {
        displayMode,
        throwOnError: false,
        strict: 'ignore',
        trust: false
      });
      if (!markup) return '';
      return `<${displayMode ? 'div' : 'span'} class="${displayMode ? 'leetcode-math-display' : 'leetcode-math-inline'}">${markup}</${displayMode ? 'div' : 'span'}>`;
    } catch (error) {
      return '';
    }
  }

  function protectMarkdownMath(text) {
    const codeSegments = [];
    const mathSegments = [];
    const reserveCode = value => {
      const token = `CODESEGMENTTOKEN${codeSegments.length}END`;
      codeSegments.push([token, value]);
      return token;
    };
    const reserveMath = (expression, displayMode, original) => {
      const markup = renderMarkdownMath(expression, displayMode);
      if (!markup) return original;
      const token = `MATHSEGMENTTOKEN${mathSegments.length}END`;
      mathSegments.push([token, markup, displayMode]);
      return displayMode ? `\n\n${token}\n\n` : token;
    };
    let source = String(text || '')
      .replace(/^(```|~~~)[^\n]*\n[\s\S]*?^\1[ \t]*$/gm, reserveCode)
      .replace(/(`+)[^\n]*?\1/g, reserveCode);
    source = source
      .replace(/\$\$([\s\S]+?)\$\$/g, (original, expression) => reserveMath(expression, true, original))
      .replace(/\\\[([\s\S]+?)\\\]/g, (original, expression) => reserveMath(expression, true, original))
      .replace(/\\\(([^\n]+?)\\\)/g, (original, expression) => reserveMath(expression, false, original))
      .replace(/(^|[^\\$])\$([^$\n]+?)\$/g, (original, prefix, expression) => `${prefix}${reserveMath(expression, false, original.slice(prefix.length))}`);
    for (const [token, value] of codeSegments) source = source.replaceAll(token, value);
    return {
      source,
      restore(rendered) {
        let result = rendered;
        for (const [token, markup, displayMode] of mathSegments) {
          if (displayMode) result = result.replaceAll(`<p>${token}</p>`, markup);
          result = result.replaceAll(token, markup);
        }
        return result;
      }
    };
  }

  function md(text, streaming = false) {
    const source = streaming ? balanceStreamingMarkdown(text) : String(text || '');
    const protectedMath = protectMarkdownMath(source);
    const rendered = protectedMath.restore(markdown.render(protectedMath.source, { streaming }));
    return window.DOMPurify.sanitize(rendered, {
      USE_PROFILES: { html: true, mathMl: true },
      ADD_ATTR: ['target', 'rel', 'aria-label']
    });
  }

  function renderLearningMarkdown(value) {
    const source = String(value || '')
      .replace(/\s+(示例\s*\d+)\s*[:：]\s*/gu, '\n\n#### $1\n')
      .replace(/\s+(提示|约束)\s*[:：]\s*/gu, '\n\n#### $1\n')
      .replace(/\s+(输入|输出)\s*[:：]\s*/gu, '\n- **$1：** ');
    return md(source);
  }

  const CODE_LANGUAGE_LABELS = Object.freeze({
    java: 'Java', python: 'Python', python3: 'Python', cpp: 'C++', c: 'C',
    csharp: 'C#', javascript: 'JavaScript', typescript: 'TypeScript', go: 'Go',
    kotlin: 'Kotlin', swift: 'Swift', rust: 'Rust', ruby: 'Ruby', php: 'PHP',
    dart: 'Dart', scala: 'Scala'
  });
  let codeLanguageGroupSequence = 0;

  function normalizedCodeTabLanguage(value) {
    const raw = String(value || '').trim().toLowerCase().replace(/\s+/g, '');
    return languageAliases[raw] || ({ 'c#': 'csharp', 'python3': 'python' }[raw] || raw);
  }

  function codeBlockLanguage(block) {
    return normalizedCodeTabLanguage(block?.querySelector('.code-lang')?.textContent || 'text');
  }

  function isCodeLanguageBridge(element) {
    if (!element?.matches?.('h2, h3, h4, h5, h6, p, hr')) return false;
    if (element.matches('hr')) return true;
    const text = element.textContent.trim().replace(/^(?:代码|解法|实现)\s*[:：-]?\s*/u, '');
    const language = normalizedCodeTabLanguage(text.replace(/[()（）]/g, ''));
    return Boolean(CODE_LANGUAGE_LABELS[language]);
  }

  function activateCodeLanguageTab(group, language) {
    for (const button of group.querySelectorAll('[data-code-language-tab]')) {
      const active = button.dataset.codeLanguageTab === language;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', active ? 'true' : 'false');
      button.tabIndex = active ? 0 : -1;
    }
    for (const panel of group.querySelectorAll('[data-code-language-panel]')) {
      panel.hidden = panel.dataset.codeLanguagePanel !== language;
    }
  }

  function enhanceCodeLanguageTabs(container) {
    if (!container) return;
    const parents = new Set([...container.querySelectorAll('.code-block:not([data-code-tabbed])')].map(block => block.parentElement));
    for (const parent of parents) {
      const children = [...parent.children];
      for (let index = 0; index < children.length;) {
        const first = children[index];
        if (!first?.classList?.contains('code-block') || first.dataset.codeTabbed) { index += 1; continue; }
        const blocks = [first];
        const bridges = [];
        let cursor = index + 1;
        while (cursor < children.length) {
          const item = children[cursor];
          if (item.classList?.contains('code-block') && !item.dataset.codeTabbed) {
            blocks.push(item);
            cursor += 1;
            continue;
          }
          if (isCodeLanguageBridge(item)) {
            bridges.push(item);
            cursor += 1;
            continue;
          }
          break;
        }
        const languages = blocks.map(codeBlockLanguage);
        if (blocks.length < 2 || new Set(languages).size !== blocks.length || languages.some(language => !CODE_LANGUAGE_LABELS[language])) {
          index += 1;
          continue;
        }
        const groupId = `code-language-group-${++codeLanguageGroupSequence}`;
        const group = document.createElement('section');
        group.className = 'code-language-group';
        group.innerHTML = `<header class="code-language-toolbar"><div class="code-language-tabs" role="tablist" aria-label="代码语言">${languages.map((language, tabIndex) => `<button type="button" role="tab" id="${groupId}-tab-${tabIndex}" data-code-language-tab="${esc(language)}" aria-controls="${groupId}-panel-${tabIndex}">${esc(CODE_LANGUAGE_LABELS[language])}</button>`).join('')}</div>${codeCopyButtonHtml('code-group-copy')}</header><div class="code-language-panels"></div>`;
        first.before(group);
        const panels = group.querySelector('.code-language-panels');
        blocks.forEach((block, blockIndex) => {
          const panel = document.createElement('div');
          panel.id = `${groupId}-panel-${blockIndex}`;
          panel.dataset.codeLanguagePanel = languages[blockIndex];
          panel.setAttribute('role', 'tabpanel');
          panel.setAttribute('aria-labelledby', `${groupId}-tab-${blockIndex}`);
          block.dataset.codeTabbed = 'true';
          panel.append(block);
          panels.append(panel);
        });
        bridges.forEach(element => element.remove());
        const previous = group.previousElementSibling;
        if (isCodeLanguageBridge(previous)) previous.remove();
        const preferred = languages.includes('java') ? 'java' : languages[0];
        activateCodeLanguageTab(group, preferred);
        group.addEventListener('click', event => {
          const button = event.target.closest('[data-code-language-tab]');
          if (button) activateCodeLanguageTab(group, button.dataset.codeLanguageTab);
        });
        group.addEventListener('keydown', event => {
          const button = event.target.closest('[data-code-language-tab]');
          if (!button || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
          event.preventDefault();
          const tabs = [...group.querySelectorAll('[data-code-language-tab]')];
          const direction = event.key === 'ArrowRight' ? 1 : -1;
          const next = tabs[(tabs.indexOf(button) + direction + tabs.length) % tabs.length];
          activateCodeLanguageTab(group, next.dataset.codeLanguageTab);
          next.focus();
        });
        index = cursor;
      }
    }
  }

  function enhanceRenderedAnswer(container) {
    if (!container) return;
    enhanceCodeLanguageTabs(container);
    enhancePreviewImages(container);
  }

  function codeTextForCopyButton(button) {
    const group = button.closest('.code-language-group');
    const visiblePanel = group?.querySelector('[data-code-language-panel]:not([hidden])');
    const codeBlock = visiblePanel?.querySelector('.code-block') || button.closest('.code-block');
    return codeBlock?.querySelector('code')?.textContent || '';
  }

  async function copyCodeFromButton(button) {
    const code = codeTextForCopyButton(button);
    if (!code) return;
    clearTimeout(button._copyResetTimer);
    try {
      await window.api.setClipboard(code);
      button.classList.remove('copy-failed');
      button.classList.add('copied');
      button.setAttribute('aria-label', '代码已复制');
      button.title = '代码已复制';
    } catch (error) {
      console.warn('Clipboard write failed:', error);
      button.classList.remove('copied');
      button.classList.add('copy-failed');
      button.setAttribute('aria-label', '复制失败');
      button.title = '复制失败';
    }
    button._copyResetTimer = setTimeout(() => {
      if (!button.isConnected) return;
      button.classList.remove('copied', 'copy-failed');
      button.setAttribute('aria-label', '复制代码');
      button.title = '复制代码';
    }, 1500);
  }

  const safeAnimatedAttributes = new Set([
    'opacity', 'transform', 'x', 'y', 'cx', 'cy', 'r', 'rx', 'ry',
    'width', 'height', 'fill', 'fill-opacity', 'stroke', 'stroke-opacity',
    'stroke-width', 'stroke-dashoffset', 'd', 'points'
  ]);
  const safeSmilAttributes = new Set([
    'attributename', 'attributetype', 'begin', 'dur', 'repeatcount',
    'repeatdur', 'restart', 'fill', 'from', 'to', 'by', 'values', 'keytimes',
    'keysplines', 'calcmode', 'additive', 'accumulate', 'type'
  ]);

  function isSafeSmilValue(value) {
    const withoutInternalReferences = value.replace(/url\(\s*#[\w:.-]+\s*\)/gi, '');
    return !/[<>&]|(?:javascript|data|file):|url\s*\(/i.test(withoutInternalReferences);
  }

  function validateSmilAnimation(animation) {
    const tagName = animation.localName.toLowerCase();
    for (const attribute of [...animation.attributes]) {
      if (!safeSmilAttributes.has(attribute.name.toLowerCase())) animation.removeAttribute(attribute.name);
    }

    const attributeName = (animation.getAttribute('attributeName') || '').toLowerCase();
    if (!safeAnimatedAttributes.has(attributeName)) return false;
    if (tagName === 'animatetransform' && attributeName !== 'transform') return false;

    const begin = animation.getAttribute('begin');
    const duration = animation.getAttribute('dur');
    const repeatDuration = animation.getAttribute('repeatDur');
    const safeTime = value => /^\d*\.?\d+(?:ms|s|min|h)?$/i.test(value.trim());
    if (begin && !safeTime(begin)) return false;
    if (!duration || !safeTime(duration)) return false;
    if (repeatDuration && repeatDuration !== 'indefinite' && !safeTime(repeatDuration)) return false;

    const repeatCount = animation.getAttribute('repeatCount');
    if (repeatCount && repeatCount !== 'indefinite' && !/^\d*\.?\d+$/.test(repeatCount)) return false;
    const enumerated = {
      attributeType: ['auto', 'CSS', 'XML'],
      restart: ['always', 'whenNotActive', 'never'],
      fill: ['remove', 'freeze'],
      calcMode: ['discrete', 'linear', 'paced', 'spline'],
      additive: ['replace', 'sum'],
      accumulate: ['none', 'sum']
    };
    for (const [name, allowed] of Object.entries(enumerated)) {
      const value = animation.getAttribute(name);
      if (value && !allowed.includes(value)) return false;
    }
    if (tagName === 'animatetransform') {
      const type = animation.getAttribute('type');
      if (!['translate', 'scale', 'rotate', 'skewX', 'skewY'].includes(type)) return false;
    }
    return ['from', 'to', 'by', 'values', 'keyTimes', 'keySplines']
      .every(name => !animation.hasAttribute(name) || isSafeSmilValue(animation.getAttribute(name)));
  }

  function sanitizeSvg(source) {
    const sanitized = window.DOMPurify.sanitize(source, {
      USE_PROFILES: { svg: true, svgFilters: true },
      FORBID_TAGS: ['script', 'foreignObject', 'style', 'animateMotion', 'animateColor', 'mpath'],
      FORBID_ATTR: ['href', 'xlink:href'],
      ADD_TAGS: ['animate'],
      ADD_ATTR: [...safeSmilAttributes]
    });
    const container = document.createElement('div');
    container.innerHTML = sanitized;
    for (const element of container.querySelectorAll('*')) {
      for (const attribute of [...element.attributes]) {
        if (/^on/i.test(attribute.name) || !isSafeSmilValue(attribute.value)) {
          element.removeAttribute(attribute.name);
        }
      }
      const tagName = element.localName.toLowerCase();
      if ((tagName === 'animate' || tagName === 'animatetransform') && !validateSmilAnimation(element)) {
        element.remove();
      }
    }
    const svg = container.querySelector('svg');
    if (!svg) return '';
    if (!svg.hasAttribute('viewBox')) {
      const numericSize = name => {
        const match = String(svg.getAttribute(name) || '').trim().match(/^(\d+(?:\.\d+)?)(?:px)?$/i);
        const value = match ? Number(match[1]) : 0;
        return Number.isFinite(value) && value > 0 ? value : 0;
      };
      const width = numericSize('width');
      const height = numericSize('height');
      if (width && height) svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
    }
    if (!svg.hasAttribute('preserveAspectRatio')) svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    return svg.outerHTML;
  }

  function makeSvgResponsive(svg) {
    if (!svg) return;

    const viewBox = svg.viewBox?.baseVal;
    const hasValidViewBox = viewBox
      && Number.isFinite(viewBox.width)
      && Number.isFinite(viewBox.height)
      && viewBox.width > 0
      && viewBox.height > 0;

    // Some generated SVGs declare a fixed pixel canvas without a viewBox.
    // Recover their drawable bounds after insertion so they can scale down
    // with the chat window instead of creating a horizontal scroll area.
    if (!hasValidViewBox) {
      try {
        const bounds = svg.getBBox();
        if (bounds.width > 0 && bounds.height > 0) {
          const padding = Math.max(2, Math.min(bounds.width, bounds.height) * 0.012);
          svg.setAttribute('viewBox', [
            bounds.x - padding,
            bounds.y - padding,
            bounds.width + padding * 2,
            bounds.height + padding * 2
          ].join(' '));
        }
      } catch (error) {}
    }

    svg.removeAttribute('width');
    svg.removeAttribute('height');
    svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    svg.style.width = '100%';
    svg.style.maxWidth = '100%';
    svg.style.height = 'auto';
  }

  function mountSvg(canvas, markup) {
    canvas.innerHTML = markup;
    canvas.scrollLeft = 0;
    const svg = canvas.querySelector(':scope > svg');
    if (svg) makeSvgResponsive(svg);
    return svg;
  }

  function hasVisibleSvgContent(svg) {
    const nonZero = value => Boolean(value) && !/^0(?:\.0+)?(?:px|%)?$/i.test(value.trim());
    return [...svg.querySelectorAll('path, rect, circle, ellipse, line, polyline, polygon, text')]
      .some(element => {
        switch (element.localName.toLowerCase()) {
          case 'path': return Boolean(element.getAttribute('d')?.trim());
          case 'rect': return nonZero(element.getAttribute('width')) && nonZero(element.getAttribute('height'));
          case 'circle': return nonZero(element.getAttribute('r'));
          case 'ellipse': return nonZero(element.getAttribute('rx')) && nonZero(element.getAttribute('ry'));
          case 'line': return ['x1', 'y1', 'x2', 'y2'].some(name => element.hasAttribute(name));
          case 'polyline':
          case 'polygon': return Boolean(element.getAttribute('points')?.trim());
          case 'text': return Boolean(element.textContent.trim());
          default: return false;
        }
      });
  }

  function streamingSvgCandidate(source) {
    const snapshot = window.StreamingSvg?.buildStreamingSvgSnapshot(source) || '';
    if (!snapshot) return null;
    const sanitized = sanitizeSvg(snapshot);
    const parser = document.createElement('div');
    parser.innerHTML = sanitized;
    const svg = parser.querySelector('svg');
    return {
      snapshot,
      markup: svg && hasVisibleSvgContent(svg) ? svg.outerHTML : ''
    };
  }

  function hasSmilAnimation(svg) {
    return [...svg.querySelectorAll('*')].some(element => {
      const name = element.localName.toLowerCase();
      return name === 'animate' || name === 'animatetransform';
    });
  }

  function updateSvgToggleButton(button, paused) {
    if (!button) return;
    button.title = paused ? '继续动画' : '暂停动画';
    button.setAttribute('aria-label', button.title);
    button.innerHTML = paused
      ? '<svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor"><path d="M8 5v14l11-7Z"/></svg>'
      : '<svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>';
  }

  function messageLayerCoversSvg() {
    if (!$('#video-workspace').classList.contains('hidden')) return true;
    return [...document.querySelectorAll('.overlay')].some(overlay => !overlay.classList.contains('hidden'));
  }

  function isInsideMessageViewport(block) {
    if (!block?.isConnected) return false;
    const rootRect = messagesEl.getBoundingClientRect();
    const rect = block.getBoundingClientRect();
    return rect.bottom > rootRect.top && rect.top < rootRect.bottom
      && rect.right > rootRect.left && rect.left < rootRect.right;
  }

  function applySvgPlaybackState(block, state = svgAnimationStates.get(block)) {
    const svg = block?.querySelector('.svg-canvas svg');
    if (!svg || !state) return;
    const shouldPause = Boolean(state.userPaused)
      || !state.inViewport
      || document.visibilityState !== 'visible'
      || !appWindowFocused
      || messageLayerCoversSvg();
    try {
      if (shouldPause) svg.pauseAnimations();
      else svg.unpauseAnimations();
      state.runtimePaused = shouldPause;
      block.dataset.animationRunning = shouldPause ? 'false' : 'true';
    } catch (error) {
      console.warn('Failed to update SVG playback visibility:', error);
    }
  }

  function refreshSvgAnimationPlayback() {
    for (const block of document.querySelectorAll('.svg-block')) {
      const state = svgAnimationStates.get(block);
      if (!state) continue;
      state.inViewport = isInsideMessageViewport(block);
      applySvgPlaybackState(block, state);
    }
  }

  function unobserveSvgAnimations(root) {
    for (const block of root?.querySelectorAll?.('.svg-block') || []) {
      svgVisibilityObserver.unobserve(block);
      svgAnimationStates.delete(block);
    }
  }

  function setupSvgAnimationControls(block, svg, state = null) {
    const actions = block.querySelector('.visual-actions');
    const canControl = svg
      && hasSmilAnimation(svg)
      && typeof svg.pauseAnimations === 'function'
      && typeof svg.unpauseAnimations === 'function'
      && typeof svg.setCurrentTime === 'function';
    actions?.classList.toggle('hidden', !canControl);
    if (!canControl) {
      svgVisibilityObserver.unobserve(block);
      svgAnimationStates.delete(block);
      delete block.dataset.animationPaused;
      delete block.dataset.animationRunning;
      return;
    }

    const animationState = state || {};
    animationState.userPaused = Boolean(animationState.userPaused ?? animationState.paused);
    animationState.inViewport = isInsideMessageViewport(block);
    svgAnimationStates.set(block, animationState);
    block.dataset.animationPaused = animationState.userPaused ? 'true' : 'false';
    svgVisibilityObserver.observe(block);
    const replayButton = block.querySelector('.svg-animation-replay');
    if (replayButton) {
      replayButton.innerHTML = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12a9 9 0 1 0 3-6.7L3 8" stroke-linecap="round" stroke-linejoin="round"/><path d="M3 3v5h5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    }
    updateSvgToggleButton(block.querySelector('.svg-animation-toggle'), animationState.userPaused);
    applySvgPlaybackState(block, animationState);
  }

  function applyStreamingSvgMarkup(block, canvas, state) {
    const version = String(state.version || 0);
    if (!state.markup || (block.dataset.svgPreviewVersion === version && canvas.querySelector('svg'))) return;

    const parser = document.createElement('div');
    parser.innerHTML = state.markup;
    const nextSvg = parser.querySelector('svg');
    if (!nextSvg) return;

    const previousSvg = canvas.querySelector('svg');
    let currentTime = Number(state.currentTime);
    if (previousSvg && typeof previousSvg.getCurrentTime === 'function') {
      try { currentTime = previousSvg.getCurrentTime(); } catch (error) {}
    }

    canvas.replaceChildren(nextSvg);
    canvas.scrollLeft = 0;
    makeSvgResponsive(nextSvg);
    canvas.classList.remove('visual-error');
    block.dataset.svgPreviewVersion = version;
    setupSvgAnimationControls(block, nextSvg, state);
    if (Number.isFinite(currentTime) && currentTime > 0 && typeof nextSvg.setCurrentTime === 'function') {
      try { nextSvg.setCurrentTime(currentTime); } catch (error) {}
    }
  }

  function renderStreamingSvgs(root, session) {
    const blocks = [...root.querySelectorAll('.svg-block')];
    blocks.forEach((block, index) => {
      const source = block.querySelector('.svg-source')?.textContent || '';
      const canvas = block.querySelector('.svg-canvas');
      if (!canvas) return;
      const state = session.svgStates[index] || { rawSource: '', snapshot: '', markup: '', version: 0, userPaused: false };
      if (state.rawSource === source) {
        applyStreamingSvgMarkup(block, canvas, state);
        return;
      }
      state.rawSource = source;
      const candidate = streamingSvgCandidate(source);

      if (candidate && candidate.snapshot !== state.snapshot) {
        state.snapshot = candidate.snapshot;
        if (candidate.markup) {
          state.markup = candidate.markup;
          state.version += 1;
        }
      }
      session.svgStates[index] = state;

      applyStreamingSvgMarkup(block, canvas, state);
    });
  }

  function loadMermaid() {
    if (!mermaidPromise) {
      mermaidPromise = loadRendererScript(
        '../../.renderer-assets/mermaid/dist/mermaid.min.js',
        () => Boolean(window.mermaid)
      )
        .then(() => {
          const mermaid = window.mermaid;
          mermaid.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            suppressErrorRendering: true,
            theme: 'base',
            themeVariables: {
              fontFamily: '-apple-system, BlinkMacSystemFont, SF Pro Text, sans-serif',
              primaryColor: '#e6f3ff',
              primaryTextColor: '#161719',
              primaryBorderColor: '#0877e6',
              secondaryColor: '#e6f7f4',
              tertiaryColor: '#fff4df',
              lineColor: '#5f6670'
            },
            flowchart: { htmlLabels: false, useMaxWidth: true }
          });
          return mermaid;
        })
        .catch(error => {
          mermaidPromise = null;
          throw error;
        });
    }
    return mermaidPromise;
  }

  async function renderVisuals(root, svgStates = null) {
    const svgBlocks = [...root.querySelectorAll('.svg-block:not([data-rendered])')];
    for (const [index, block] of svgBlocks.entries()) {
      block.dataset.rendered = 'true';
      const source = block.querySelector('.svg-source')?.textContent || '';
      const canvas = block.querySelector('.svg-canvas');
      if (!canvas) continue;
      const sanitized = sanitizeSvg(source);
      const svg = mountSvg(canvas, sanitized);
      if (!svg) {
        canvas.textContent = '图解暂时无法渲染';
        canvas.classList.add('visual-error');
      } else {
        setupSvgAnimationControls(block, svg, svgStates?.[index]);
      }
    }

    const mermaidNodes = [...root.querySelectorAll('.mermaid:not([data-processed])')];
    if (!mermaidNodes.length) return;

    // Mermaid keeps shared renderer state, so history restoration must not
    // launch several batches concurrently.
    mermaidRenderQueue = mermaidRenderQueue
      .catch(() => {})
      .then(async () => {
        let connectedNodes = mermaidNodes.filter(node => node.isConnected);
        if (!connectedNodes.length) return;
        try {
          const mermaid = await loadMermaid();
          connectedNodes = connectedNodes.filter(node => node.isConnected);
          if (!connectedNodes.length) return;
          await mermaid.run({ nodes: connectedNodes, suppressErrors: true });
        } catch (error) {
          console.warn('Mermaid render failed:', error);
        }
        for (const node of connectedNodes) {
          if (!node.querySelector('svg')) node.classList.add('visual-error');
        }
      });
    await mermaidRenderQueue;
  }

  // ===== Conversation =====

  function genId() { return 'c_' + Date.now() + '_' + Math.random().toString(36).slice(2, 6); }

  function genMessageId() { return 'm_' + Date.now() + '_' + Math.random().toString(36).slice(2, 9); }

  function normalizeMessage(message, index, conversationId) {
    const role = ['system', 'user', 'assistant'].includes(message?.role) ? message.role : 'user';
    const existingId = /^m_[a-z0-9_]+$/i.test(String(message?.id || '')) ? String(message.id) : '';
    const fallbackId = `m_${String(conversationId || 'legacy').replace(/[^a-z0-9_]/gi, '')}_${index}`;
    const content = String(message?.content || '');
    return {
      id: existingId || fallbackId,
      role,
      content,
      artifacts: contextManager.normalizeArtifacts([
        ...(Array.isArray(message?.artifacts) ? message.artifacts : []),
        ...contextManager.markdownArtifacts(content)
      ], 8),
      createdAt: Math.max(0, Number(message?.createdAt) || 0)
    };
  }

  function createMessage(role, content, artifacts = []) {
    return {
      id: genMessageId(),
      role,
      content: String(content || ''),
      artifacts: contextManager.normalizeArtifacts(artifacts, 8),
      createdAt: Date.now()
    };
  }

  function displayUserContent(text) {
    return String(text || '')
      .replace(/^【浏览器当前选区】\s*/u, '')
      .replace(/^请解答以下 LeetCode 题目，给出最优解法和完整 Java 代码：\s*/u, '')
      .replace(/^【任务】请基于下面的内容解决用户问题；如果它是算法题，请给出最优方案和完整 Java 实现。\s*/u, '')
      .replace(/^【衔接任务】上一条回答可能在生成中被打断。请先判断上一任务是否已完成；若未完成，将遗留内容与下面的新要求统一规划并完成。\s*/u, '')
      .replace(/^【用户新增要求】\s*/u, '')
      .replace(/^【(?:浏览器当前选区|用户输入)】\s*/u, '')
      .trim();
  }

  function extractTitle(text) {
    const cleaned = displayUserContent(text).replace(/```[\s\S]*?```/g, ' ').trim();
    const lines = cleaned.split('\n');
    for (const l of lines) {
      const c = l.replace(/^[\d.、)\]#【】]+\s*/, '').replace(/\s+/g, ' ').trim();
      if (c.length > 2) return c.length > 34 ? `${c.slice(0, 34)}…` : c;
    }
    return cleaned.slice(0, 30).trim() || '新对话';
  }

  function normalizeConversationVideo(value) {
    const bvid = window.BilibiliVideo.extractBvid(value?.bvid || value);
    if (!bvid) return null;
    return {
      bvid,
      title: String(value?.title || '视频讲解').replace(/\s+/g, ' ').trim().slice(0, 120),
      cover: /^https:\/\/[^/]+\.hdslb\.com\//i.test(String(value?.cover || '')) ? String(value.cover) : '',
      plays: Math.max(0, Math.round(Number(value?.plays) || 0))
    };
  }

  function normalizeVideoCandidates(value) {
    const seen = new Set();
    return (Array.isArray(value) ? value : []).map(normalizeConversationVideo).filter(video => {
      if (!video || seen.has(video.bvid)) return false;
      seen.add(video.bvid);
      return true;
    }).slice(0, 8);
  }

  function normalizeQuestionVideoState(value = {}) {
    const source = value && typeof value === 'object' ? value : {};
    const video = normalizeConversationVideo(source.video || source.selected);
    const storedEligibilityVersion = Math.max(0, Number(source.eligibilityVersion) || 0);
    const eligibilityVersion = video ? VIDEO_ELIGIBILITY_VERSION : storedEligibilityVersion;
    const eligibilityCheckedAt = eligibilityVersion === VIDEO_ELIGIBILITY_VERSION
      ? Math.max(0, Number(source.eligibilityCheckedAt) || 0)
      : 0;
    const storedEligibility = ['unknown', 'checking', 'eligible', 'ineligible'].includes(source.eligibility)
      ? source.eligibility
      : 'unknown';
    const status = ['idle', 'identifying', 'searching', 'ready', 'empty', 'error'].includes(source.status)
      ? source.status
      : (video ? 'ready' : 'idle');
    return {
      status,
      video,
      candidates: normalizeVideoCandidates(source.candidates || source.videoCandidates),
      query: String(source.query || source.videoSearchQuery || '').slice(0, 160),
      identifiedTitle: String(source.identifiedTitle || source.videoIdentifiedTitle || '').slice(0, 100),
      requestedAt: Math.max(0, Number(source.requestedAt || source.videoRequestedAt) || 0),
      attemptedAt: Math.max(0, Number(source.attemptedAt || source.videoSearchAttemptedAt) || 0),
      error: String(source.error || source.videoSearchError || '').slice(0, 160),
      progress: Math.max(0, Number(source.progress) || 0),
      duration: Math.max(0, Number(source.duration) || 0),
      qualityId: Math.max(0, Number(source.qualityId) || 0),
      playbackRate: Math.max(0.5, Math.min(3, Number(source.playbackRate) || 1)),
      volume: Math.max(0, Math.min(1, Number.isFinite(Number(source.volume)) ? Number(source.volume) : 0.8)),
      muted: Boolean(source.muted),
      eligibility: video ? 'eligible' : (eligibilityCheckedAt ? storedEligibility : 'unknown'),
      eligibilityReason: String(source.eligibilityReason || '').slice(0, 120),
      eligibilityCheckedAt,
      eligibilityVersion,
      updatedAt: Math.max(0, Number(source.updatedAt) || 0)
    };
  }

  function normalizeQuestionVideos(conversation, messages) {
    const stored = conversation?.questionVideos && typeof conversation.questionVideos === 'object'
      ? conversation.questionVideos
      : {};
    const result = {};
    const userIds = new Set(messages.filter(message => message.role === 'user').map(message => message.id));
    for (const [questionId, state] of Object.entries(stored)) {
      if (userIds.has(questionId)) {
        result[questionId] = Object.assign(state, normalizeQuestionVideoState(state));
      }
    }
    const firstQuestion = messages.find(message => message.role === 'user');
    if (firstQuestion && !result[firstQuestion.id] && (
      conversation?.video || conversation?.videoRequestedAt || conversation?.videoSearchError
    )) {
      result[firstQuestion.id] = normalizeQuestionVideoState({
        video: conversation.video,
        videoCandidates: conversation.videoCandidates,
        videoSearchQuery: conversation.videoSearchQuery,
        videoIdentifiedTitle: conversation.videoIdentifiedTitle,
        videoRequestedAt: conversation.videoRequestedAt,
        videoSearchAttemptedAt: conversation.videoSearchAttemptedAt,
        videoSearchError: conversation.videoSearchError
      });
    }
    return result;
  }

  function questionVideoState(conversation, questionId, create = false) {
    if (!conversation || !questionId) return null;
    if (!conversation.questionVideos || typeof conversation.questionVideos !== 'object') conversation.questionVideos = {};
    if (!conversation.questionVideos[questionId] && create) {
      conversation.questionVideos[questionId] = normalizeQuestionVideoState();
    }
    return conversation.questionVideos[questionId] || null;
  }

  function summarizeConversation(messages) {
    const questions = (Array.isArray(messages) ? messages : [])
      .filter(message => message?.role === 'user')
      .map(message => displayUserContent(message.content))
      .filter(Boolean);
    if (!questions.length) return { title: '新对话', summary: '尚未发送问题' };
    const title = extractTitle(questions[0]);
    if (questions.length === 1) {
      const compact = questions[0].replace(/\s+/g, ' ');
      return { title, summary: compact.length > 64 ? `${compact.slice(0, 64)}…` : compact };
    }
    const latest = extractTitle(questions[questions.length - 1]);
    return { title, summary: `${questions.length} 次提问 · 最近：${latest}` };
  }

  function normalizeStoredUsage(usage) {
    const source = usage && typeof usage === 'object' ? usage : {};
    const number = value => Math.max(0, Number.isFinite(Number(value)) ? Number(value) : 0);
    const hasExactCacheStats = Number(source.cacheStatsVersion) === 2
      || Object.hasOwn(source, 'cacheTrackedPromptTokens');
    const estimatedRequests = number(source.estimatedRequests);
    // Legacy estimates never carried exact cache/tool data. Reject those fields
    // unless this record explicitly contains at least one provider-reported call.
    const hasProviderUsage = number(source.exactRequests) > 0 || estimatedRequests === 0;
    const cacheSupported = hasProviderUsage && hasExactCacheStats && Boolean(source.cacheSupported);
    const promptTokens = number(source.promptTokens);
    const toolUsage = {};
    for (const [name, count] of Object.entries(source.toolUsage || {})) {
      const normalized = number(count);
      if (normalized > 0) toolUsage[name] = normalized;
    }
    const toolCalls = hasProviderUsage && Object.hasOwn(source, 'toolCalls')
      ? number(source.toolCalls)
      : (hasProviderUsage ? Object.values(toolUsage).reduce((total, count) => total + count, 0) : 0);
    return {
      cacheStatsVersion: 2,
      promptTokens,
      completionTokens: number(source.completionTokens),
      totalTokens: number(source.totalTokens),
      cachedTokens: hasProviderUsage && hasExactCacheStats ? number(source.cachedTokens) : 0,
      cacheCreationTokens: hasProviderUsage && hasExactCacheStats ? number(source.cacheCreationTokens) : 0,
      reasoningTokens: number(source.reasoningTokens),
      textTokens: number(source.textTokens),
      toolCalls,
      toolUsage: hasProviderUsage ? toolUsage : {},
      exactRequests: number(source.exactRequests) || (estimatedRequests === 0 && hasExactCacheStats ? 1 : 0),
      estimatedRequests,
      cacheTrackedPromptTokens: hasProviderUsage && hasExactCacheStats && Object.hasOwn(source, 'cacheTrackedPromptTokens')
        ? number(source.cacheTrackedPromptTokens)
        : 0,
      cacheSupported,
      model: typeof source.model === 'string' ? source.model : ''
    };
  }

  function addUsage(left, right) {
    const a = normalizeStoredUsage(left);
    const b = normalizeStoredUsage(right);
    const toolUsage = { ...a.toolUsage };
    for (const [name, count] of Object.entries(b.toolUsage)) toolUsage[name] = (toolUsage[name] || 0) + count;
    return {
      cacheStatsVersion: 2,
      promptTokens: a.promptTokens + b.promptTokens,
      completionTokens: a.completionTokens + b.completionTokens,
      totalTokens: a.totalTokens + b.totalTokens,
      cachedTokens: a.cachedTokens + b.cachedTokens,
      cacheCreationTokens: a.cacheCreationTokens + b.cacheCreationTokens,
      reasoningTokens: a.reasoningTokens + b.reasoningTokens,
      textTokens: a.textTokens + b.textTokens,
      toolCalls: a.toolCalls + b.toolCalls,
      toolUsage,
      exactRequests: a.exactRequests + b.exactRequests,
      estimatedRequests: a.estimatedRequests + b.estimatedRequests,
      cacheTrackedPromptTokens: a.cacheTrackedPromptTokens + b.cacheTrackedPromptTokens,
      cacheSupported: a.cacheSupported || b.cacheSupported,
      model: b.model || a.model
    };
  }

  function estimateTextTokens(text) {
    let asciiCharacters = 0;
    let nonAsciiCharacters = 0;
    for (const character of String(text || '')) {
      if (character.codePointAt(0) <= 0x7f) asciiCharacters += 1;
      else nonAsciiCharacters += 1;
    }
    return Math.ceil(asciiCharacters / 4 + nonAsciiCharacters);
  }

  function estimateMessagesTokens(messages) {
    return (Array.isArray(messages) ? messages : []).reduce(
      (total, message) => total + 4 + estimateTextTokens(message?.content),
      3
    );
  }

  function estimateSessionUsage(session) {
    const promptTokens = Math.max(0, Number(session?.estimatedPromptTokens) || 0);
    const reasoningTokens = estimateTextTokens(session?.thinking);
    const textTokens = estimateTextTokens(session?.content);
    const completionTokens = reasoningTokens + textTokens;
    const previousModel = normalizeStoredUsage(conversations[session?.convId]?.lastChatUsage).model;
    return normalizeStoredUsage({
      cacheStatsVersion: 2,
      model: previousModel,
      promptTokens,
      completionTokens,
      totalTokens: promptTokens + completionTokens,
      reasoningTokens,
      textTokens,
      estimatedRequests: 1,
      cacheSupported: false
    });
  }

  function commitStreamUsage(session) {
    if (!session || session.usageCommitted || !conversations[session.convId]) return;
    if (!session.usage && (session.thinking || session.content)) {
      session.usage = estimateSessionUsage(session);
    }
    if (!session.usage) return;
    const normalizedUsage = normalizeStoredUsage(session.usage);
    conversations[session.convId].usage = addUsage(conversations[session.convId].usage, normalizedUsage);
    conversations[session.convId].lastChatUsage = normalizedUsage;
    session.usageCommitted = true;
  }

  function persistConversationSnapshot(id, snapshot, { throwOnError = false } = {}) {
    let state = conversationSaveStates.get(id);
    if (!state) {
      state = { latest: null, waiters: [], running: true, resolveCompletion: null };
      state.completion = new Promise(resolve => { state.resolveCompletion = resolve; });
      conversationSaveStates.set(id, state);
      saveQueues.set(id, state.completion);
      (async () => {
        await new Promise(resolve => setTimeout(resolve, CONVERSATION_SAVE_DEBOUNCE_MS));
        while (state.latest) {
          const pendingSnapshot = state.latest;
          state.latest = null;
          const waiters = state.waiters.splice(0);
          let error = null;
          try {
            await window.api.saveConversation(id, pendingSnapshot);
          } catch (caught) {
            error = caught;
            console.error('Failed to save conversation:', caught);
            showAppError(caught?.message || '对话保存失败，请检查磁盘空间后重试');
          }
          for (const waiter of waiters) {
            if (error && waiter.throwOnError) waiter.reject(error);
            else waiter.resolve();
          }
        }
      })().finally(() => {
        state.running = false;
        state.resolveCompletion();
        if (conversationSaveStates.get(id) === state) conversationSaveStates.delete(id);
        if (saveQueues.get(id) === state.completion) saveQueues.delete(id);
      });
    }
    state.latest = snapshot;
    return new Promise((resolve, reject) => {
      state.waiters.push({ resolve, reject, throwOnError });
    });
  }

  function saveConv(id = currentConvId, messages = currentMessages, { touch = true, throwOnError = false } = {}) {
    if (!id || !conversations[id]) return Promise.resolve();
    const snapshot = Array.isArray(messages)
      ? messages.map((message, index) => normalizeMessage(message, index, id))
      : [];
    const autoSummary = summarizeConversation(snapshot);
    const previousData = conversations[id];
    const data = {
      schemaVersion: 3,
      title: String(previousData.aiTitle || autoSummary.title),
      summary: String(previousData.aiSummary || autoSummary.summary),
      aiTitle: String(previousData.aiTitle || ''),
      aiSummary: String(previousData.aiSummary || ''),
      contextSummary: String(previousData.contextSummary || ''),
      summaryMessageCount: Math.max(0, Number(previousData.summaryMessageCount) || 0),
      summaryQuestionCount: Math.max(0, Number(previousData.summaryQuestionCount) || 0),
      summaryUpdatedAt: Math.max(0, Number(previousData.summaryUpdatedAt) || 0),
      questionVideos: normalizeQuestionVideos(previousData, snapshot),
      messages: snapshot,
      usage: normalizeStoredUsage(previousData.usage),
      lastChatUsage: normalizeStoredUsage(previousData.lastChatUsage),
      updatedAt: touch ? Date.now() : (Number(previousData.updatedAt) || Date.now())
    };
    Object.assign(previousData, data);
    conversations[id] = previousData;

    return persistConversationSnapshot(id, previousData, { throwOnError });
  }

  function userQuestionCount(messages) {
    return (Array.isArray(messages) ? messages : []).filter(message => message?.role === 'user').length;
  }

  function shouldAutoSummarize(conversation, messages) {
    if (!conversation || !Array.isArray(messages)) return false;
    if (!messages.some(message => message?.role === 'assistant' && String(message.content || '').trim())) return false;
    return !String(conversation.aiSummary || '').trim();
  }

  function buildChatPayload(id, messages, policyOverride = null) {
    const conversation = conversations[id];
    return contextManager.buildManagedContext(messages, {
      contextSummary: conversation?.contextSummary,
      summaryMessageCount: conversation?.summaryMessageCount,
      ...contextPolicy,
      ...(policyOverride || {}),
      recentMessages: contextPolicy.recentMessages,
      maxImages: contextPolicy.maxImages
    });
  }

  async function ensureRollingContextSummary(id, messages, { eager = false } = {}) {
    const usage = contextManager.estimateContextUsage(messages, contextPolicy);
    if (!eager && !usage.shouldCompress) return true;
    if (contextCompressionQueues.has(id)) return contextCompressionQueues.get(id);
    const conversation = conversations[id];
    const previousCount = Math.max(0, Number(conversation?.summaryMessageCount) || 0);
    const recentCount = Math.max(6, Number(contextPolicy.recentMessages) || 12);
    const cutoff = Math.max(previousCount, messages.length - recentCount);
    if (!conversation || cutoff <= previousCount) return Boolean(conversation?.contextSummary);
    const incremental = messages.slice(previousCount, cutoff);
    const summarySource = [
      ...(conversation.contextSummary ? [{ role: 'assistant', content: `【已有滚动摘要】\n${conversation.contextSummary}` }] : []),
      ...incremental
    ];
    const pending = window.api.summarizeConversation(id, contextManager.messagesForSummary(summarySource, contextPolicy.maxImages))
      .then(async result => {
        const latest = conversations[id];
        if (!latest || !result?.context) return false;
        latest.contextSummary = String(result.context).trim();
        latest.summaryMessageCount = cutoff;
        latest.summaryUpdatedAt = Date.now();
        await saveConv(id, latest.messages, { touch: false });
        return true;
      })
      .catch(error => {
        console.warn('Context compression failed; retaining the full recent context:', error);
        return false;
      })
      .finally(() => contextCompressionQueues.delete(id));
    contextCompressionQueues.set(id, pending);
    return pending;
  }

  // 发送路径上的压缩会阻塞首字输出；接近阈值时提前在后台生成滚动摘要。
  function prewarmRollingContextSummary(id, messages) {
    if (!id || !conversations[id] || !Array.isArray(messages)) return;
    const usage = contextManager.estimateContextUsage(messages, contextPolicy);
    if (usage.thresholdProgress < 0.8) return;
    Promise.resolve(ensureRollingContextSummary(id, messages, { eager: true })).catch(() => {});
  }

  let contextMeterTimer = 0;

  function updateContextMeter() {
    if (contextMeterTimer) return;
    contextMeterTimer = setTimeout(() => {
      contextMeterTimer = 0;
      renderContextMeter();
    }, 180);
  }

  function contextMeterUsage() {
    const draft = chatInput.value.trim();
    const messages = draft
      ? [...currentMessages, { role: 'user', content: draft }]
      : currentMessages;
    return contextManager.estimateContextUsage(messages, contextPolicy);
  }

  function contextLevel(percent) {
    return percent >= 95 ? 'critical' : (percent >= 90 ? 'high' : (percent >= 70 ? 'warning' : 'normal'));
  }

  let contextPopoverOpen = false;

  function renderContextPopover() {
    const popover = $('#context-meter-popover');
    if (!popover || !contextManager) return;
    const usage = contextMeterUsage();
    const percent = Math.max(0, Math.min(100, Math.round(usage.utilization * 100)));
    const compressed = Boolean(conversations[currentConvId]?.contextSummary);
    popover.dataset.level = contextLevel(percent);
    popover.innerHTML = `
      <div class="context-pop-head"><span>上下文</span><strong>${percent}%</strong></div>
      <div class="context-pop-track" aria-hidden="true"><i style="width:${percent}%"></i></div>
      <dl>
        <div><dt>输入估算</dt><dd>${numberFormatter.format(usage.estimatedInputTokens)} Token</dd></div>
        <div><dt>可用预算</dt><dd>${numberFormatter.format(usage.budget.availableInputTokens)} Token</dd></div>
        <div><dt>距自动压缩</dt><dd>${usage.shouldCompress ? '已触发' : `${numberFormatter.format(usage.tokensUntilCompression)} Token`}</dd></div>
        <div><dt>消息</dt><dd>${numberFormatter.format(usage.messageCount)} 条${usage.imageCount ? ` · 图 ${numberFormatter.format(usage.imageCount)}` : ''}</dd></div>
      </dl>
      ${compressed ? '<p class="context-pop-note">已启用滚动摘要压缩</p>' : ''}`;
  }

  function showContextPopover() {
    const popover = $('#context-meter-popover');
    if (!popover) return;
    contextPopoverOpen = true;
    renderContextPopover();
    popover.classList.remove('hidden');
    popover.setAttribute('aria-hidden', 'false');
  }

  function hideContextPopover() {
    const popover = $('#context-meter-popover');
    if (!popover) return;
    contextPopoverOpen = false;
    popover.classList.add('hidden');
    popover.setAttribute('aria-hidden', 'true');
  }

  function renderContextMeter() {
    const meter = $('#context-meter');
    if (!meter || !contextManager) return;
    const usage = contextMeterUsage();
    const percent = Math.max(0, Math.min(100, Math.round(usage.utilization * 100)));
    meter.style.setProperty('--context-progress', `${percent}`);
    meter.dataset.level = contextLevel(percent);
    meter.setAttribute('aria-label', `上下文已使用 ${percent}% · 剩余约 ${numberFormatter.format(usage.remainingInputTokens)} Token`);
    if (contextPopoverOpen) renderContextPopover();
  }

  function maybeAutoSummarize(id, messages) {
    if (!id || summaryQueues.has(id) || document.visibilityState === 'hidden') return Promise.resolve();
    const conversation = conversations[id];
    if (!shouldAutoSummarize(conversation, messages)) return Promise.resolve();
    const snapshot = contextManager.messagesForSummary(messages, 12);
    const sourceVersion = messages.map(message => `${message.id || ''}:${message.role}`).join('|');

    const pending = window.api.summarizeConversation(id, snapshot)
      .then(async result => {
        const latest = conversations[id];
        if (!latest || !result) return;
        const latestVersion = (latest.messages || []).map(message => `${message.id || ''}:${message.role}`).join('|');
        if (latestVersion !== sourceVersion) return;
        latest.aiTitle = String(result.title || '').trim();
        latest.aiSummary = String(result.summary || '').trim();
        latest.contextSummary = String(result.context || '').trim();
        latest.title = latest.aiTitle || latest.title;
        latest.summary = latest.aiSummary || latest.summary;
        latest.summaryMessageCount = Array.isArray(latest.messages) ? latest.messages.length : snapshot.length;
        latest.summaryQuestionCount = userQuestionCount(snapshot);
        latest.summaryUpdatedAt = Date.now();
        if (result.usage) {
          const summaryUsage = normalizeStoredUsage(result.usage);
          summaryUsage.model = normalizeStoredUsage(latest.usage).model || summaryUsage.model;
          // Summary tokens remain part of total usage, but cache effectiveness
          // measures user chat requests only.
          summaryUsage.cachedTokens = 0;
          summaryUsage.cacheCreationTokens = 0;
          summaryUsage.cacheTrackedPromptTokens = 0;
          summaryUsage.cacheSupported = false;
          latest.usage = addUsage(latest.usage, summaryUsage);
        }
        const latestMessages = Array.isArray(latest.messages) ? latest.messages : snapshot;
        await saveConv(id, latestMessages, { touch: false });
        if (!$('#history-overlay').classList.contains('hidden')) renderHistory();
        if (!$('#usage-overlay').classList.contains('hidden')) renderUsage();
      })
      .catch(error => {
        console.warn('Automatic conversation summary failed:', error);
      })
      .finally(() => {
        if (summaryQueues.get(id) === pending) summaryQueues.delete(id);
      });
    summaryQueues.set(id, pending);
    return pending;
  }

  // ===== UI =====

  function updateScrollButton() {
    scrollBottomButton.classList.toggle('hidden', nearBottom());
  }

  function scrollBottom(force = false, smooth = false) {
    if (!force && !autoFollow) return;
    if (force) autoFollow = true;
    if (scrollFrame) cancelAnimationFrame(scrollFrame);
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = 0;
      if (!force && !autoFollow) return;
      messagesEl.scrollTo({
        top: messagesEl.scrollHeight,
        behavior: smooth ? 'smooth' : 'auto'
      });
      updateScrollButton();
    });
  }

  function nearBottom() { return messagesEl.scrollHeight - messagesEl.scrollTop - messagesEl.clientHeight < 80; }

  // 回答收尾后的几帧里高度还会因重新排版而跳变，单次滚动会被后续重排推翻。
  // 连续几帧钉住底部，保证「输出完就停在最下面」，且中途上滑会立刻中止。
  function pinToBottom(frames = 6) {
    let left = frames;
    const step = () => {
      if (left-- <= 0 || !autoFollow) return;
      messagesEl.scrollTop = messagesEl.scrollHeight;
      lastScrollTop = messagesEl.scrollTop;
      requestAnimationFrame(step);
    };
    autoFollow = true;
    requestAnimationFrame(step);
    updateScrollButton();
  }

  // ===== 边缘问题导航条 =====
  // 每个提问一个刻度，等距排布；悬浮玻璃气泡显示提问原文，点击丝滑滚动到该提问并完整可见。
  let railActiveFrame = 0;
  let railRevealTimer = 0;
  let railPointerFrame = 0;
  let railActiveIndex = -1;
  let railQuestions = [];
  let railTicks = [];
  let railPerspectiveSpread = 3.7;
  // 约 6 行以上才提供「收起」。行高随窗口缩放，这里按实际计算样式换算，不用写死像素。
  function userCollapseCap(body) {
    const lineHeight = parseFloat(getComputedStyle(body).lineHeight) || 21;
    return lineHeight * 6;
  }

  function questionLabelText(messageEl) {
    const text = (messageEl?.querySelector('.msg-body')?.textContent || '').replace(/\s+/g, ' ').trim();
    return text.slice(0, 46) || '提问';
  }

  function answerPreviewText(messageEl) {
    let sibling = messageEl?.nextElementSibling;
    while (sibling && !sibling.classList.contains('is-user')) {
      if (sibling.classList.contains('message') && sibling.querySelector('.msg-avatar.ai')) {
        const text = (sibling.querySelector('.msg-body')?.textContent || '').replace(/\s+/g, ' ').trim();
        if (text) return text.slice(0, 58);
      }
      sibling = sibling.nextElementSibling;
    }
    return '等待回答摘要';
  }

  function syncChatRail() {
    if (!chatRail) return;
    if (railPointerFrame) cancelAnimationFrame(railPointerFrame);
    railPointerFrame = 0;
    const questions = [...messagesEl.querySelectorAll('.message.is-user')];
    railActiveIndex = -1;
    railQuestions = questions;
    if (questions.length < 2) {
      clearTimeout(railRevealTimer);
      chatRail.classList.remove('has-items');
      chatRail.classList.remove('is-scroll-revealed');
      chatRail.innerHTML = '';
      railTicks = [];
      return;
    }
    chatRail.classList.add('has-items');
    chatRail.innerHTML = `<div class="chat-rail-track">${questions.map((messageEl, index) => {
      const label = esc(questionLabelText(messageEl));
      const answer = esc(answerPreviewText(messageEl));
      return `<button class="chat-rail-tick" type="button" style="--i:${index}" data-rail-target="${esc(messageEl.dataset.messageId || '')}" data-rail-label="${label}" data-rail-answer="${answer}" data-rail-ordinal="${index + 1}" aria-label="跳转到：${label}"></button>`;
    }).join('')}</div><div class="chat-rail-preview" aria-hidden="true"><strong></strong><span></span><small></small></div>`;
    railTicks = [...chatRail.querySelectorAll('.chat-rail-tick')];
    updateChatRailActive(true);
    primeChatRail();
  }

  function hideChatRailPreview() {
    const preview = chatRail?.querySelector('.chat-rail-preview');
    if (!preview) return;
    preview.classList.remove('is-visible');
    preview.setAttribute('aria-hidden', 'true');
  }

  function showChatRailPreview(tick) {
    const preview = chatRail?.querySelector('.chat-rail-preview');
    if (!preview || !tick) return;
    preview.querySelector('strong').textContent = tick.dataset.railLabel || '提问';
    preview.querySelector('span').textContent = tick.dataset.railAnswer || '等待回答摘要';
    preview.querySelector('small').textContent = `当前会话 · 第 ${tick.dataset.railOrdinal || 1} 次提问`;
    const railRect = chatRail.getBoundingClientRect();
    const tickRect = tick.getBoundingClientRect();
    preview.classList.add('is-visible');
    preview.setAttribute('aria-hidden', 'false');
    const halfHeight = preview.offsetHeight / 2;
    const desiredTop = tickRect.top + tickRect.height / 2 - railRect.top;
    preview.style.top = `${Math.min(railRect.height - halfHeight - 8, Math.max(halfHeight + 8, desiredTop))}px`;
  }

  function updateChatRailActive(force = false) {
    if (!chatRail?.classList.contains('has-items')) return;
    if (!railTicks.length || !railQuestions.length) return;
    const line = messagesEl.scrollTop + 64;
    let activeIndex = 0;
    for (let i = 0; i < railQuestions.length; i++) {
      if (railQuestions[i].offsetTop <= line) activeIndex = i;
      else break;
    }
    if (nearBottom()) activeIndex = railQuestions.length - 1;
    if (!force && activeIndex === railActiveIndex) return;
    railActiveIndex = activeIndex;
    railTicks.forEach((tick, i) => tick.classList.toggle('is-active', i === activeIndex));
    const track = chatRail.querySelector('.chat-rail-track');
    const active = railTicks[activeIndex];
    if (track && active) {
      track.style.setProperty('--rail-active-index', String(activeIndex));
      const spread = railPerspectiveSpread;
      railTicks.forEach((tick, i) => {
        const distance = Math.abs(i - activeIndex);
        // 大屏采用更宽的缓坡：中心不过分凸出，同时露出更多远端刻度。
        const perspective = 1 / (1 + Math.pow(distance / spread, 1.45));
        const scale = Math.max(0.022, perspective);
        const opacity = Math.max(0.032, Math.pow(perspective, 1.18));
        tick.style.setProperty('--d', String(distance));
        tick.style.setProperty('--tick-scale', scale.toFixed(4));
        tick.style.setProperty('--tick-opacity', opacity.toFixed(3));
        tick.style.setProperty('--tick-x', `${Math.min(4, distance * 0.28).toFixed(2)}px`);
      });
    }
  }

  function revealChatRailFromScroll() {
    if (!chatRail?.classList.contains('has-items')) return;
    hideChatRailPreview();
    chatRail.classList.add('is-scroll-revealed');
    clearTimeout(railRevealTimer);
    railRevealTimer = setTimeout(() => chatRail.classList.remove('is-scroll-revealed'), 900);
  }

  function primeChatRail() {
    if (!chatRail?.classList.contains('has-items')) return;
    requestAnimationFrame(() => {
      railActiveIndex = -1;
      updateChatRailActive(true);
    });
  }

  function scheduleRailActive() {
    if (railActiveFrame) return;
    railActiveFrame = requestAnimationFrame(() => {
      railActiveFrame = 0;
      updateChatRailActive();
    });
  }

  chatRail?.addEventListener('pointerover', event => {
    const tick = event.target.closest('.chat-rail-tick');
    if (tick) showChatRailPreview(tick);
  }, { passive: true });
  chatRail?.addEventListener('pointermove', event => {
    if (railPointerFrame || !railTicks.length) return;
    const pointerY = event.clientY;
    railPointerFrame = requestAnimationFrame(() => {
      railPointerFrame = 0;
      let nearest = railTicks[0];
      let nearestDistance = Infinity;
      for (const tick of railTicks) {
        const rect = tick.getBoundingClientRect();
        const distance = Math.abs(pointerY - (rect.top + rect.height / 2));
        if (distance < nearestDistance) {
          nearest = tick;
          nearestDistance = distance;
        }
      }
      showChatRailPreview(nearest);
    });
  }, { passive: true });
  chatRail?.addEventListener('pointerleave', () => {
    if (railPointerFrame) cancelAnimationFrame(railPointerFrame);
    railPointerFrame = 0;
    hideChatRailPreview();
  }, { passive: true });
  chatRail?.addEventListener('focusin', event => {
    const tick = event.target.closest('.chat-rail-tick');
    if (tick) showChatRailPreview(tick);
  });
  chatRail?.addEventListener('focusout', event => {
    if (!event.relatedTarget?.closest?.('.chat-rail-tick')) hideChatRailPreview();
  });

  function jumpToQuestion(messageId) {
    const target = messagesEl.querySelector(`.message.is-user[data-message-id="${CSS.escape(messageId)}"]`);
    if (!target) return;
    autoFollow = false;
    scrollUserIntentUntil = Date.now() + 1600;
    // 跳转常常落偏：越过的消息带 content-visibility:auto，滚动前用的是 260px 估算高度，
    // 滚动过程中真实高度陆续算出来，目标就被推走了。所以滚完再按实际位置校正几次，
    // 直到目标真正停在顶部（scrollIntoView 一次性计算，做不到这点）。
    const settle = (attempt = 0) => {
      const top = messagesEl.getBoundingClientRect().top;
      const delta = target.getBoundingClientRect().top - top - 12;
      if (Math.abs(delta) <= 2 || attempt >= 6) return;
      messagesEl.scrollTop += delta;
      lastScrollTop = messagesEl.scrollTop;
      requestAnimationFrame(() => settle(attempt + 1));
    };
    messagesEl.scrollTo({
      top: messagesEl.scrollTop + target.getBoundingClientRect().top - messagesEl.getBoundingClientRect().top - 12,
      behavior: 'smooth'
    });
    setTimeout(() => {
      settle();
      scheduleRailActive();
    }, 380);
    target.classList.add('learning-source-highlight');
    setTimeout(() => target.classList.remove('learning-source-highlight'), 1900);
    scheduleRailActive();
  }

  // 长提问默认收起。用 IntersectionObserver 把关测量：
  // 离屏消息受 content-visibility 影响，布局被跳过，此时读 scrollHeight 会得到估计值而误判，
  // 所以只在消息进入视口（已渲染）时测量，宽度变化时也只在可见时重测。
  function wireUserCollapse(messageEl) {
    const body = messageEl.querySelector('.msg-body');
    if (!body) return;
    const row = document.createElement('div');
    row.className = 'msg-collapse-row';
    row.innerHTML = '<button class="msg-collapse-toggle" type="button" aria-expanded="false"><svg viewBox="0 0 20 20" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.9" aria-hidden="true"><path d="m6 8 4 4 4-4" stroke-linecap="round" stroke-linejoin="round"/></svg><span>展开</span></button>';
    body.insertAdjacentElement('afterend', row);
    const toggle = row.querySelector('.msg-collapse-toggle');
    let longSeen = false;
    let inView = false;
    let deferredEvaluateTimer = 0;
    const evaluate = () => {
      if (!inView || messageEl.classList.contains('user-collapsed')) return;
      if (!longSeen && body.scrollHeight > userCollapseCap(body) + 4) {
        longSeen = true;
        messageEl.classList.add('user-collapsed');
        toggle.setAttribute('aria-expanded', 'false');
        toggle.querySelector('span').textContent = '展开';
        if (autoFollow) scrollBottom();
      }
      messageEl.classList.toggle('is-clampable', longSeen);
    };
    const intersection = new IntersectionObserver(entries => {
      inView = Boolean(entries[0]?.isIntersecting);
      if (inView) evaluate();
    }, { root: messagesEl, threshold: 0 });
    intersection.observe(messageEl);
    const resize = new ResizeObserver(() => {
      if (!inView) return;
      if (!windowTransitioning) return evaluate();
      clearTimeout(deferredEvaluateTimer);
      deferredEvaluateTimer = setTimeout(evaluate, 180);
    });
    resize.observe(body);
    messageEl._collapseCleanup = () => {
      intersection.disconnect();
      resize.disconnect();
      clearTimeout(deferredEvaluateTimer);
    };
    toggle.addEventListener('click', () => {
      const collapsed = messageEl.classList.toggle('user-collapsed');
      toggle.setAttribute('aria-expanded', String(!collapsed));
      toggle.querySelector('span').textContent = collapsed ? '展开' : '收起';
      if (longSeen) messageEl.classList.add('is-clampable');
    });
  }

  function clearMessages() {
    if (scrollFrame) cancelAnimationFrame(scrollFrame);
    scrollFrame = 0;
    autoFollow = true;
    lastScrollTop = 0;
    unobserveSvgAnimations(messagesEl);
    stopClock();
    for (const message of messagesEl.querySelectorAll('.message.is-user')) message._collapseCleanup?.();
    if (chatRail) {
      chatRail.innerHTML = '';
      chatRail.classList.remove('has-items');
    }
    messagesEl.innerHTML = '';
    emptyState = null;
  }

  // Braun 风格时钟：60 道刻度（每 5 道加长加深）、内圈数字、方头黑针与橙色秒针。
  // 关键细节：中心白雾盖在指针之上，指针在轴心处被雾化；光源自左上，指针带柔和投影。
  function clockFaceMarkup() {
    // 比例对齐参考实物（以盘面半径 100 为基准）：刻度外沿 .93R，数字圈 .76R，
    // 时针 .52R、分针 .72R、秒针 .80R（尾配重 .12R），中心雾圈仅 .13R。
    let ticks = '';
    for (let index = 0; index < 60; index += 1) {
      const major = index % 5 === 0;
      ticks += `<line x1="100" y1="7" x2="100" y2="${major ? 15 : 11.5}" transform="rotate(${index * 6} 100 100)"${major ? ' class="tick-major"' : ''}/>`;
    }
    let numerals = '';
    for (let hour = 1; hour <= 12; hour += 1) {
      const radians = (hour * 30 - 90) * Math.PI / 180;
      const x = (100 + Math.cos(radians) * 76).toFixed(1);
      const y = (100 + Math.sin(radians) * 76).toFixed(1);
      numerals += `<text x="${x}" y="${y}">${hour}</text>`;
    }
    // 秒针 + 中心雾 + 轴心单独放在上层 SVG：每秒只重绘这一层，
    // 不会连带触发下层时针/分针投影滤镜的重新栅格化（那正是残余抖动的来源）。
    return `<svg class="empty-clock-face" viewBox="0 0 200 200" aria-hidden="true">
      <defs>
        <filter id="clock-hand-shadow" x="-30%" y="-30%" width="160%" height="160%">
          <feDropShadow dx="0.5" dy="1" stdDeviation="0.8" flood-color="#1a222c" flood-opacity=".13"/>
        </filter>
      </defs>
      <g class="clock-ticks">${ticks}</g>
      <g class="clock-numerals">${numerals}</g>
      <g filter="url(#clock-hand-shadow)">
        <line class="clock-hand-hour" id="clock-hour" x1="100" y1="100" x2="100" y2="48"/>
        <line class="clock-hand-minute" id="clock-minute" x1="100" y1="100" x2="100" y2="28"/>
      </g>
    </svg>
    <svg class="empty-clock-overlay" viewBox="0 0 200 200" aria-hidden="true">
      <defs>
        <radialGradient id="clock-center-mist">
          <stop offset="0%" stop-color="#fefefe" stop-opacity=".92"/>
          <stop offset="45%" stop-color="#fefefe" stop-opacity=".72"/>
          <stop offset="78%" stop-color="#fefefe" stop-opacity=".3"/>
          <stop offset="100%" stop-color="#fefefe" stop-opacity="0"/>
        </radialGradient>
      </defs>
      <line class="clock-hand-second" id="clock-second" x1="100" y1="112" x2="100" y2="20"/>
      <circle class="clock-mist" cx="100" cy="100" r="25.5" fill="url(#clock-center-mist)"/>
      <circle class="clock-cap" cx="100" cy="100" r="4.6"/>
    </svg>`;
  }

  let clockTimer = 0;

  function tickClock() {
    const hour = $('#clock-hour');
    const minute = $('#clock-minute');
    const second = $('#clock-second');
    if (!hour || !minute || !second) return stopClock();
    const now = new Date();
    const seconds = now.getSeconds();
    // 石英钟走法：分针每分钟整跳一次。若按秒插值，分针每秒只移动 0.1°，
    // 在大屏上是亚像素位移，边缘反锯齿每秒重算会看成抖动。
    const minutes = now.getMinutes();
    const hours = (now.getHours() % 12) + minutes / 60;
    // 用 CSS transform 而非 SVG 属性：交给合成层做旋转，不会每秒重新栅格化矢量。
    const hourAngle = `rotate(${(hours * 30).toFixed(2)}deg)`;
    const minuteAngle = `rotate(${minutes * 6}deg)`;
    if (hour.style.transform !== hourAngle) hour.style.transform = hourAngle;
    if (minute.style.transform !== minuteAngle) minute.style.transform = minuteAngle;
    second.style.transform = `rotate(${seconds * 6}deg)`;
  }

  function startClock() {
    stopClock();
    if (!$('#clock-second') || document.visibilityState === 'hidden') return;
    tickClock();
    // 对齐整秒再按秒走针，避免长时间运行后的累积漂移。
    clockTimer = setTimeout(() => {
      tickClock();
      clockTimer = setInterval(tickClock, 1000);
    }, 1000 - (Date.now() % 1000));
  }

  function stopClock() {
    if (clockTimer) {
      clearTimeout(clockTimer);
      clearInterval(clockTimer);
    }
    clockTimer = 0;
  }

  // 全屏 + 空状态时进入沉浸模式：收起标题栏与输入框，只留时钟面板。
  // 鼠标移动、键盘输入或输入框获得焦点时临时唤出。
  let zenRevealTimer = 0;
  let zenPointerFrame = 0;

  function updateZenMode() {
    const immersive = document.body.classList.contains('is-fullscreen')
      && Boolean(emptyState) && !emptyState.classList.contains('hidden');
    document.body.classList.toggle('is-zen', immersive);
    if (immersive) ensureAgendaData();
    else {
      clearTimeout(zenRevealTimer);
      document.body.classList.remove('zen-reveal');
    }
  }

  function revealZenChrome() {
    if (!document.body.classList.contains('is-zen')) return;
    document.body.classList.add('zen-reveal');
    clearTimeout(zenRevealTimer);
    zenRevealTimer = setTimeout(() => {
      if (inputBar.matches(':hover, :focus-within')) return;
      document.body.classList.remove('zen-reveal');
    }, 2400);
  }

  function revealZenChromeFromPointer(event) {
    if (event.pointerType === 'touch' || zenPointerFrame) return;
    zenPointerFrame = requestAnimationFrame(() => {
      zenPointerFrame = 0;
      revealZenChrome();
    });
  }

  function agendaDueLabel(item) {
    const due = Number(item.review?.dueAt) || 0;
    if (!due) return { text: '待安排', now: false };
    const diff = due - Date.now();
    if (diff <= 0) return { text: '现在', now: true };
    const hours = Math.ceil(diff / 3600000);
    if (hours < 24) return { text: `${hours} 小时后`, now: false };
    return { text: `${Math.ceil(hours / 24)} 天后`, now: false };
  }

  function emptyAgendaMarkup() {
    const dashboard = learningDashboard;
    if (!dashboard) {
      return '<aside class="empty-agenda" aria-label="今日复习"><div class="agenda-panel"><p class="agenda-note">正在读取学习档案</p></div></aside>';
    }
    const plan = dashboard.plan || {};
    const stats = dashboard.stats || {};
    const items = (plan.reviewItems || []).map(learningItem).filter(Boolean).slice(0, 4);
    const rows = items.length
      ? items.map(item => {
        const due = agendaDueLabel(item);
        const meta = (item.knowledgePath || []).slice(-1)[0]
          || item.labels?.[0]
          || (item.kind === 'knowledge' ? '知识点' : '题目');
        return `<button class="agenda-row" type="button" data-agenda-item="${esc(item.id)}">
          <span class="agenda-row-copy"><strong>${esc(item.title)}</strong><small>${esc(meta)}</small></span>
          <span class="agenda-row-due${due.now ? ' is-now' : ''}">${esc(due.text)}</span>
        </button>`;
      }).join('')
      : '<p class="agenda-note">复习队列已清空</p>';
    const summary = [
      `${stats.total || 0} 个学习项`,
      stats.weak ? `${stats.weak} 待巩固` : '',
      stats.mastered ? `${stats.mastered} 已掌握` : ''
    ].filter(Boolean).join(' · ');
    return `<aside class="empty-agenda" aria-label="今日复习">
      <div class="agenda-panel">
        <header class="agenda-head">
          <strong>今日复习</strong>
          <button class="agenda-more" type="button" data-agenda-action="open-learning">学习中心</button>
        </header>
        ${rows}
        <p class="agenda-foot">${esc(summary)}</p>
      </div>
    </aside>`;
  }

  function emptyStateMarkup() {
    return `<div class="empty-state" id="empty-state">
      <div class="empty-hero">
        <div class="empty-clock">${clockFaceMarkup()}</div>
        <h2>准备解题</h2>
        <p>选中题目或直接输入</p>
      </div>
      ${emptyAgendaMarkup()}
    </div>`;
  }

  // 全屏首页才展示待办面板；数据按需拉取一次，之后随学习中心更新。
  let agendaLoadPromise = null;
  function refreshEmptyAgenda() {
    const host = emptyState?.querySelector('.empty-agenda');
    if (!host) return;
    host.outerHTML = emptyAgendaMarkup();
  }

  function ensureAgendaData() {
    if (learningDashboard) return refreshEmptyAgenda();
    if (agendaLoadPromise) return agendaLoadPromise;
    agendaLoadPromise = window.api.getLearningDashboard()
      .then(dashboard => {
        if (dashboard) learningDashboard = dashboard;
        refreshEmptyAgenda();
      })
      .catch(error => console.warn('Failed to load learning agenda:', error))
      .finally(() => { agendaLoadPromise = null; });
    return agendaLoadPromise;
  }

  function renderEmptyState() {
    clearMessages();
    messagesEl.innerHTML = emptyStateMarkup();
    emptyState = $('#empty-state');
    startClock();
    updateZenMode();
  }

  function messageHeaderHtml(ai, label, trailingHtml = '') {
    return `<div class="msg-head"><div class="msg-head-label"><div class="msg-avatar ${ai ? 'ai' : 'user'}"></div><span class="msg-kind-label">${esc(label)}</span></div>${trailingHtml}</div>`;
  }

  function messageLearningAnnotations(conversationId, messageId) {
    const records = conversations[conversationId]?.learningAnnotations?.[messageId];
    return records && typeof records === 'object' ? Object.values(records).filter(Boolean) : [];
  }

  function messageLearningBadgeHtml(conversationId, messageId) {
    const annotations = messageLearningAnnotations(conversationId, messageId);
    const active = annotations.filter(item => item.status === 'active');
    if (active.length) {
      const target = active[0];
      const title = active.map(item => item.title).join('、');
      return `<button class="message-learning-state" type="button" data-learning-message-item="${esc(target.itemId)}" title="${esc(title)}"><i aria-hidden="true"></i><span>已沉淀${active.length > 1 ? ` ${active.length}` : ''}</span></button>`;
    }
    if (annotations.some(item => item.status === 'removed')) {
      return '<span class="message-learning-state is-removed" title="该消息仍保留，但已从学习档案移除"><i aria-hidden="true"></i><span>已取消沉淀</span></span>';
    }
    return '';
  }

  function updateMessageLearningBadge(messageId) {
    const message = document.querySelector(`.message[data-message-id="${CSS.escape(String(messageId || ''))}"]`);
    const slot = message?.querySelector('.message-learning-slot');
    if (slot) slot.innerHTML = messageLearningBadgeHtml(currentConvId, messageId);
  }

  // 打开长会话时，视口外的旧回答先以纯文本占位，空闲时再升级为完整 Markdown。
  const pendingMarkdownBodies = new Map();
  let deferredMarkdownScheduled = false;

  function upgradeDeferredMarkdown() {
    if (deferredMarkdownScheduled || !pendingMarkdownBodies.size) return;
    deferredMarkdownScheduled = true;
    const run = deadline => {
      deferredMarkdownScheduled = false;
      // 流式生成期间不动上方内容：高度变化会让视口跳到之前的对话。
      if (isStreaming) {
        setTimeout(upgradeDeferredMarkdown, 800);
        return;
      }
      // 自底向上升级：先处理靠近视口（底部）的消息，减少可见跳动。
      const entries = [...pendingMarkdownBodies.entries()].reverse();
      for (const [element, content] of entries) {
        pendingMarkdownBodies.delete(element);
        if (element.isConnected) {
          const host = element.closest('.message');
          const scrollerRect = messagesEl.getBoundingClientRect();
          const beforeRect = host ? host.getBoundingClientRect() : null;
          element.innerHTML = md(content);
          element.classList.remove('msg-body-pending');
          enhanceRenderedAnswer(element);
          if (host) {
            // 跟随底部时直接贴底；否则按高度差补偿，保持可见内容不动。
            if (autoFollow) {
              scrollBottom(true);
            } else if (beforeRect && beforeRect.bottom < scrollerRect.top) {
              const delta = host.getBoundingClientRect().height - beforeRect.height;
              if (delta) messagesEl.scrollTop += delta;
            }
            const preVisualHeight = host.getBoundingClientRect().height;
            renderVisuals(host).catch(() => {}).finally(() => {
              if (!host.isConnected) return;
              if (autoFollow) return scrollBottom(true);
              const rect = host.getBoundingClientRect();
              const delta = rect.height - preVisualHeight;
              if (delta && rect.bottom - delta < messagesEl.getBoundingClientRect().top) {
                messagesEl.scrollTop += delta;
              }
            });
          }
        }
        if (deadline && typeof deadline.timeRemaining === 'function' && deadline.timeRemaining() < 8) break;
      }
      if (pendingMarkdownBodies.size) upgradeDeferredMarkdown();
    };
    if (typeof requestIdleCallback === 'function') requestIdleCallback(run, { timeout: 400 });
    else setTimeout(run, 40);
  }

  function addMsg(role, content, { target = messagesEl, render = true, scroll = true, message = null, animate = true, deferMarkdown = false } = {}) {
    emptyState?.classList.add('hidden');
    stopClock();
    updateZenMode();
    const d = document.createElement('div');
    d.className = 'message';
    if (!animate) d.classList.add('message-restored');
    const ai = role === 'assistant';
    if (!ai) d.classList.add('is-user');
    const visibleContent = ai ? content : displayUserContent(content);
    if (message?.id) d.dataset.messageId = message.id;
    const ordinal = ai || !message?.id ? 0 : userQuestionOrdinal(currentMessages, message.id);
    const videoAction = ai || !message?.id ? '' : `<button class="message-video-action hidden" type="button" data-video-question="${esc(message.id)}" aria-label="为这条消息查找视频讲解" title="视频讲解">
      <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m8 4 2.4 3M16 4l-2.4 3M5.5 7.5h13A2.5 2.5 0 0 1 21 10v7.5a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5V10a2.5 2.5 0 0 1 2.5-2.5Z" stroke-linecap="round" stroke-linejoin="round"/><path d="m9 12 4.5 2.7V9.3L9 12Z" stroke-linejoin="round"/></svg>
      <span>视频讲解</span>
    </button>`;
    const deleteAction = !message?.id ? '' : `<button class="message-delete-action" type="button" data-delete-message="${esc(message.id)}" title="删除这条消息" aria-label="删除这条${ai ? '回答' : '消息'}">
      <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.9" aria-hidden="true"><path d="M4 7h16M9 7V4h6v3m3 0-1 13H7L6 7" stroke-linecap="round" stroke-linejoin="round"/><path d="M10 11v5M14 11v5" stroke-linecap="round"/></svg>
    </button>`;
    const messageActions = videoAction || deleteAction ? `<div class="message-actions">${videoAction}${deleteAction}</div>` : '';
    const learningSlot = !ai && message?.id
      ? `<span class="message-learning-slot">${messageLearningBadgeHtml(currentConvId, message.id)}</span>`
      : '';
    const headTools = learningSlot || messageActions ? `<div class="msg-head-tools">${learningSlot}${messageActions}</div>` : '';
    const initialLabel = ai ? '解答' : (ordinal <= 1 ? `题目 ${ordinal || 1}` : '追问');
    const deferred = ai && deferMarkdown;
    const bodyHtml = ai
      ? (deferred ? '' : md(visibleContent))
      : esc(visibleContent).replace(/\n/g, '<br>');
    d.innerHTML = `${messageHeaderHtml(ai, initialLabel, headTools)}<div class="msg-body${deferred ? ' msg-body-pending' : ''}">${bodyHtml}</div>`;
    if (deferred) {
      const bodyElement = d.querySelector('.msg-body');
      bodyElement.textContent = visibleContent;
      pendingMarkdownBodies.set(bodyElement, visibleContent);
    }
    target.appendChild(d);
    if (ai && !deferred) enhanceRenderedAnswer(d.querySelector('.msg-body'));
    else enhancePreviewImages(d);
    if (ai && render) {
      renderVisuals(d).catch(error => {
        console.warn('Visual render failed:', error);
      }).finally(() => {
        if (d.isConnected && autoFollow) scrollBottom();
      });
    }
    if (scroll) scrollBottom(true);
    if (!ai && message?.id) updateMessageVideoAction(message.id);
    if (!ai) {
      wireUserCollapse(d);
      syncChatRail();
    }
    return d;
  }

  function updateVideoTrigger() {
    for (const button of document.querySelectorAll('.message-video-action')) {
      updateMessageVideoAction(button.dataset.videoQuestion);
    }
  }

  function lastUserMessageId(messages) {
    for (let index = (Array.isArray(messages) ? messages.length : 0) - 1; index >= 0; index -= 1) {
      if (messages[index]?.role === 'user') return messages[index].id || '';
    }
    return '';
  }

  function updateMessageDeleteActions() {
    const activeUserId = activeStream && !activeStream.finalized && activeStream.convId === currentConvId
      ? lastUserMessageId(activeStream.messages)
      : '';
    for (const button of document.querySelectorAll('.message-delete-action')) {
      const locked = Boolean(activeUserId && button.dataset.deleteMessage === activeUserId);
      button.disabled = locked;
      button.title = locked ? '当前回答生成完成后可删除' : '删除这条消息';
      button.setAttribute('aria-label', button.title);
    }
  }

  function updateMessageVideoAction(questionId) {
    const button = document.querySelector(`.message-video-action[data-video-question="${CSS.escape(String(questionId || ''))}"]`);
    if (!button) return;
    const state = questionVideoState(conversations[currentConvId], questionId, false);
    const runtime = videoSearchStates.get(`${currentConvId}:${questionId}`);
    const status = runtime?.phase || state?.status || 'idle';
    const active = questionId === activeVideoQuestionId && !$('#video-workspace').classList.contains('hidden');
    const labels = {
      identifying: '识别题目',
      searching: '匹配中',
      enriching: '播放视频',
      ready: '播放视频',
      empty: '重新匹配',
      error: '重新匹配'
    };
    const eligible = Boolean(state?.video) || state?.eligibility === 'eligible';
    button.classList.toggle('hidden', !eligible);
    const label = active ? '正在播放' : (labels[status] || (state?.video ? '播放视频' : '视频讲解'));
    button.querySelector('span').textContent = label;
    button.classList.toggle('is-loading', ['identifying', 'searching'].includes(status));
    button.classList.toggle('is-ready', Boolean(state?.video));
    button.classList.toggle('is-active', active);
    button.setAttribute('aria-busy', ['identifying', 'searching'].includes(status) ? 'true' : 'false');
    button.setAttribute('aria-current', active ? 'true' : 'false');
    const message = button.closest('.message');
    const kindLabel = message?.querySelector('.msg-kind-label');
    if (kindLabel) {
      const ordinal = questionOrdinal(conversations[currentConvId], questionId);
      kindLabel.textContent = eligible
        ? `题目 ${ordinal || 1}`
        : (state?.eligibility === 'checking' ? '正在识别' : (ordinal <= 1 ? '问题' : '追问'));
    }
  }

  function setVideoStage(state, title, detail = '') {
    const status = $('#video-stage-state');
    status.classList.toggle('searching', state === 'searching');
    status.classList.toggle('error', state === 'error');
    $('#video-stage-title').textContent = title;
    $('#video-stage-detail').textContent = detail;
    status.classList.remove('hidden');
    if (state !== 'ready') {
      $('#video-player-mount').classList.add('hidden');
      $('#video-cache-badge').classList.add('hidden');
    }
  }

  function formatByteSize(bytes) {
    const value = Math.max(0, Number(bytes) || 0);
    if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
    return `${(value / (1024 * 1024)).toFixed(value < 10 * 1024 * 1024 ? 1 : 0)} MB`;
  }

  async function refreshVideoCacheBadge() {
    if ($('#video-workspace').classList.contains('hidden')) return;
    try {
      const stats = await window.api.getVideoCacheStats();
      const badge = $('#video-cache-badge');
      const hitRate = Number(stats?.hitRate) || 0;
      badge.textContent = `${formatByteSize(stats?.storedBytes)} · ${stats?.hits + stats?.misses ? `${Math.round(hitRate * 100)}% 命中` : '缓存就绪'}`;
      badge.title = `媒体分段缓存：${stats?.entries || 0} 块，命中 ${stats?.hits || 0} 次`;
      badge.classList.remove('hidden');
    } catch (error) {}
  }

  function startVideoCacheUpdates() {
    if (videoCacheTimer) clearInterval(videoCacheTimer);
    refreshVideoCacheBadge();
    videoCacheTimer = setInterval(refreshVideoCacheBadge, 4000);
  }

  function activeQuestionVideoState(create = false) {
    return questionVideoState(conversations[currentConvId], activeVideoQuestionId, create);
  }

  function persistPlayerProgress(force = false) {
    const conversationId = activePlayerContext?.conversationId || currentConvId;
    const questionId = activePlayerContext?.questionId || activeVideoQuestionId;
    const conversation = conversations[conversationId];
    if (!activePlayer || !questionId || !conversationId || !conversation) return;
    const state = questionVideoState(conversation, questionId, true);
    const currentTime = Math.max(0, Number(activePlayer.currentTime) || 0);
    const duration = Math.max(0, Number(activePlayer.duration) || Number(activePlayback?.duration) || 0);
    state.progress = currentTime;
    state.duration = duration;
    state.playbackRate = Math.max(0.5, Math.min(3, Number(activePlayer.playbackRate) || 1));
    state.volume = Math.max(0, Math.min(1, Number(activePlayer.volume) || 0));
    state.muted = Boolean(activePlayer.muted);
    state.updatedAt = Date.now();
    if (force) {
      if (playerProgressTimer) clearTimeout(playerProgressTimer);
      playerProgressTimer = 0;
      saveConv(conversationId, conversation.messages, { touch: false });
      if (activeWorkspaceVideo) {
        const question = conversation.messages?.find(message => message.id === questionId);
        window.api.recordVideoHistory({
          ...activeWorkspaceVideo,
          query: state.query,
          conversationId,
          questionId,
          questionTitle: extractTitle(question?.content || ''),
          progress: state.progress,
          duration: state.duration,
          increment: false
        }).then(history => {
          videoHistory = Array.isArray(history) ? history : videoHistory;
          renderVideoHistory();
        }).catch(() => {});
      }
      return;
    }
    if (playerProgressTimer) return;
    playerProgressTimer = setTimeout(() => {
      playerProgressTimer = 0;
      if (conversations[conversationId] === conversation) {
        saveConv(conversationId, conversation.messages, { touch: false });
      }
    }, 10000);
  }

  function unmountVideoPlayer() {
    playerLoadGeneration += 1;
    persistPlayerProgress(true);
    if (playerAutoplayCleanup) playerAutoplayCleanup();
    playerAutoplayCleanup = null;
    if (playerRecoveryTimer) clearTimeout(playerRecoveryTimer);
    playerRecoveryTimer = 0;
    destroyDashPlayer();
    activePlayerContext = null;
    if (activePlayer) {
      try { activePlayer.destroy(false); } catch (error) {}
      activePlayer = null;
    }
    activePlayback = null;
    if (videoCacheTimer) clearInterval(videoCacheTimer);
    videoCacheTimer = 0;
    $('#video-player-mount').replaceChildren();
    $('#video-player-mount').classList.add('hidden');
    $('#video-cache-badge').classList.add('hidden');
  }

  function destroyDashPlayer() {
    if (!activeDashPlayer) return;
    try {
      if (typeof activeDashPlayer.destroy === 'function') activeDashPlayer.destroy();
      else activeDashPlayer.reset();
    } catch (error) {}
    activeDashPlayer = null;
  }

  function configureDashPlayer(video, url) {
    destroyDashPlayer();
    const player = window.dashjs.MediaPlayer().create();
    player.updateSettings({
      debug: { logLevel: window.dashjs.Debug.LOG_LEVEL_WARNING },
      streaming: {
        abandonLoadTimeout: 8000,
        cacheInitSegments: true,
        scheduling: { scheduleWhilePaused: true },
        buffer: {
          fastSwitchEnabled: true,
          flushBufferAtTrackSwitch: true,
          reuseExistingSourceBuffers: true,
          bufferPruningInterval: 8,
          bufferToKeep: 18,
          bufferTimeDefault: 22,
          bufferTimeAtTopQuality: 30,
          bufferTimeAtTopQualityLongForm: 40,
          longFormContentDurationThreshold: 600
        }
      }
    });
    player.initialize(video, url, false);
    const dashErrorEvent = window.dashjs.MediaPlayer.events?.ERROR || 'error';
    player.on(dashErrorEvent, () => {
      setTimeout(() => {
        if (activeDashPlayer === player) recoverVideoPlayer();
      }, 0);
    });
    activeDashPlayer = player;
  }

  function recoverVideoPlayer() {
    if (!activeWorkspaceVideo || playerRecoveryAttempts >= 1) return;
    playerRecoveryAttempts += 1;
    mountVideoPlayer(activeWorkspaceVideo, { force: true, recovery: true });
  }

  function updateDashBufferForRate(rate) {
    if (!activeDashPlayer) return;
    const playbackRate = Math.max(0.5, Math.min(3, Number(rate) || 1));
    const target = Math.round(Math.max(22, Math.min(48, 22 * playbackRate)));
    activeDashPlayer.updateSettings({
      streaming: { buffer: { bufferTimeDefault: target, bufferTimeAtTopQuality: target + 8 } }
    });
  }

  function armVideoAutoplay(art, loadGeneration, shouldPlay) {
    if (!shouldPlay || !art?.video) return;
    if (playerAutoplayCleanup) playerAutoplayCleanup();
    const video = art.video;
    let retryTimer = 0;
    let stopped = false;
    let attempts = 0;
    const cleanup = () => {
      if (stopped) return;
      stopped = true;
      if (retryTimer) clearTimeout(retryTimer);
      for (const eventName of ['loadedmetadata', 'loadeddata', 'canplay', 'progress', 'playing']) {
        video.removeEventListener(eventName, attempt);
      }
      if (playerAutoplayCleanup === cleanup) playerAutoplayCleanup = null;
    };
    const valid = () => activePlayer === art
      && playerLoadGeneration === loadGeneration
      && !$('#video-workspace').classList.contains('hidden');
    const scheduleRetry = () => {
      if (stopped || attempts >= 10 || retryTimer) return;
      retryTimer = setTimeout(() => {
        retryTimer = 0;
        attempt();
      }, Math.min(1200, 180 + attempts * 120));
    };
    function attempt() {
      if (!valid()) {
        cleanup();
        return;
      }
      if (!video.paused && !video.ended) {
        cleanup();
        return;
      }
      attempts += 1;
      video.muted = true;
      video.autoplay = true;
      video.playsInline = true;
      const playResult = video.play();
      if (playResult && typeof playResult.then === 'function') {
        playResult.then(cleanup).catch(scheduleRetry);
      } else {
        scheduleRetry();
      }
    }
    playerAutoplayCleanup = cleanup;
    for (const eventName of ['loadedmetadata', 'loadeddata', 'canplay', 'progress', 'playing']) {
      video.addEventListener(eventName, attempt, { passive: true });
    }
    queueMicrotask(attempt);
  }

  async function mountVideoPlayer(video, { force = false, recovery = false } = {}) {
    const normalized = normalizeConversationVideo(video);
    const conversationId = currentConvId;
    const questionId = activeVideoQuestionId;
    if (!normalized || !conversationId || !questionId) return;
    if (!force && activeWorkspaceVideo?.bvid === normalized.bvid && activePlayer) return;
    const resumeAt = activePlayer ? Number(activePlayer.currentTime) || 0 : Number(activeQuestionVideoState()?.progress) || 0;
    const wasPlaying = activePlayer ? activePlayer.playing : videoAutoplay;
    const previousRate = activePlayer ? Number(activePlayer.playbackRate) || 1 : Number(activeQuestionVideoState()?.playbackRate) || 1;
    const previousVolume = activePlayer ? Number(activePlayer.volume) : Number(activeQuestionVideoState()?.volume);
    const previousMuted = activePlayer ? Boolean(activePlayer.muted) : Boolean(activeQuestionVideoState()?.muted);
    unmountVideoPlayer();
    const loadGeneration = ++playerLoadGeneration;
    setVideoStage('searching', recovery ? '正在刷新播放地址' : '正在准备播放器');
    let playback;
    try {
      [playback] = await Promise.all([
        window.api.getBilibiliPlayback(normalized.bvid),
        ensureVideoRuntime()
      ]);
    } catch (error) {
      if (loadGeneration === playerLoadGeneration && conversationId === currentConvId && questionId === activeVideoQuestionId) {
        setVideoStage('error', '暂时无法播放', error?.message || '无法获取播放地址');
      }
      return;
    }
    if (loadGeneration !== playerLoadGeneration
      || conversationId !== currentConvId
      || questionId !== activeVideoQuestionId
      || normalized.bvid !== activeWorkspaceVideo?.bvid
      || $('#video-workspace').classList.contains('hidden')) return;
    const qualities = Array.isArray(playback?.qualities) ? playback.qualities.filter(item => item?.url) : [];
    if (!qualities.length || !window.Artplayer || !window.dashjs) {
      setVideoStage('error', '播放器初始化失败', '这个视频暂时无法播放，试试换一个');
      return;
    }
    updateBilibiliAuthUi(playback.authState);
    const state = activeQuestionVideoState(true);
    const selected = qualities.find(item => Number(item.id) === Number(state.qualityId)) || qualities[0];
    state.qualityId = Number(selected.id) || 0;
    state.duration = Math.max(state.duration, Number(playback.duration) || 0);
    activePlayback = playback;
    // 播放量取自 /x/web-interface/view 的 stat.view（见 getBilibiliPlayback），比搜索页抓取稳定；
    // 旧匹配存的是 0，这里在真正播放时补上，信息栏徽章立刻就有数。
    const playbackPlays = Math.max(0, Math.round(Number(playback.plays) || 0));
    activeWorkspaceVideo = {
      ...normalized,
      title: playback.title || normalized.title,
      cover: playback.cover || normalized.cover,
      plays: playbackPlays || normalized.plays
    };
    const mount = $('#video-player-mount');
    mount.replaceChildren();
    mount.classList.remove('hidden');
    $('#video-stage-state').classList.add('hidden');
    $('#video-cache-badge').classList.remove('hidden');
    $('#video-now-title').textContent = activeWorkspaceVideo.title;
    const nowPlays = window.BilibiliVideo.formatPlayCount(activeWorkspaceVideo.plays);
    const playsBadge = $('#video-now-plays');
    if (playsBadge) {
      playsBadge.textContent = nowPlays;
      playsBadge.classList.toggle('hidden', !nowPlays);
    }
    // 把真实播放量回写进存档：当前视频与同名候选都补上，下一次打开无需再抓就有数。
    if (playbackPlays && state) {
      let persisted = false;
      if (state.video && state.video.bvid === activeWorkspaceVideo.bvid && Number(state.video.plays || 0) !== playbackPlays) {
        state.video = { ...state.video, plays: playbackPlays };
        persisted = true;
      }
      if (Array.isArray(state.candidates)) {
        for (const candidate of state.candidates) {
          if (candidate && candidate.bvid === activeWorkspaceVideo.bvid && Number(candidate.plays || 0) !== playbackPlays) {
            candidate.plays = playbackPlays;
            persisted = true;
          }
        }
      }
      if (persisted) {
        saveConv(currentConvId, currentMessages, { touch: false });
        renderVideoCandidates(conversations[currentConvId], activeVideoQuestionId);
      }
    }
    const qualityOptions = qualities.map(item => ({
      default: item.url === selected.url,
      html: item.label,
      url: item.url
    }));
    const art = new window.Artplayer({
      container: mount,
      url: selected.url,
      type: selected.type,
      poster: playback.cover || normalized.cover,
      title: playback.title || normalized.title,
      autoplay: false,
      muted: recovery ? previousMuted : Boolean(previousMuted || videoAutoplay),
      volume: Number.isFinite(previousVolume) ? previousVolume : 0.8,
      theme: '#fb7299',
      lang: 'zh-cn',
      setting: true,
      playbackRate: true,
      aspectRatio: false,
      flip: false,
      pip: true,
      hotkey: true,
      fullscreen: true,
      fullscreenWeb: true,
      mutex: true,
      quality: qualityOptions,
      moreVideoAttr: { playsInline: true, preload: 'auto', crossOrigin: 'anonymous' },
      customType: {
        mpd: (element, url) => configureDashPlayer(element, url)
      }
    });
    activePlayer = art;
    activePlayerContext = { conversationId, questionId, bvid: normalized.bvid, generation: loadGeneration };
    startVideoCacheUpdates();
    const restoreTime = Math.max(0, resumeAt || Number(state.progress) || 0);
    art.on('ready', () => {
      if (activePlayer !== art || playerLoadGeneration !== loadGeneration) return;
      if (restoreTime > 0 && restoreTime < art.duration - 2) art.currentTime = restoreTime;
      art.playbackRate = previousRate;
      playerRecoveryAttempts = recovery ? playerRecoveryAttempts : 0;
    });
    art.on('video:timeupdate', () => persistPlayerProgress());
    art.on('video:seeked', () => persistPlayerProgress());
    art.on('video:pause', () => persistPlayerProgress(true));
    art.on('video:ended', () => persistPlayerProgress(true));
    art.on('video:ratechange', () => updateDashBufferForRate(art.playbackRate));
    art.on('video:playing', () => {
      if (playerRecoveryTimer) clearTimeout(playerRecoveryTimer);
      playerRecoveryTimer = setTimeout(() => {
        playerRecoveryTimer = 0;
        if (activePlayer === art && art.playing) playerRecoveryAttempts = 0;
      }, 10000);
    });
    art.on('restart', url => {
      const quality = qualities.find(item => item.url === url);
      if (quality) {
        state.qualityId = Number(quality.id) || 0;
        persistPlayerProgress(true);
      }
    });
    art.on('error', () => {
      if (activePlayer === art) recoverVideoPlayer();
    });
    armVideoAutoplay(art, loadGeneration, Boolean(wasPlaying));
  }

  function mergeVideoCandidates(...groups) {
    return normalizeVideoCandidates(groups.flat());
  }

  function renderVideoCandidates(conversation = conversations[currentConvId], questionId = activeVideoQuestionId) {
    const container = $('#video-candidates');
    const state = questionVideoState(conversation, questionId, false);
    const candidates = normalizeVideoCandidates(state?.candidates)
      .filter(video => video.bvid !== activeWorkspaceVideo?.bvid)
      // 候选之间按播放量高低排列。
      .sort((a, b) => (b.plays || 0) - (a.plays || 0));
    if (!candidates.length) {
      container.classList.add('hidden');
      container.innerHTML = '';
      return;
    }
    container.innerHTML = `<div class="video-candidates-label">智能候选</div>${candidates.map(video => {
      const plays = window.BilibiliVideo.formatPlayCount(video.plays);
      return `<button class="video-candidate" type="button" data-bvid="${esc(video.bvid)}">
        <span class="video-candidate-title">${esc(video.title)}</span>
        ${plays ? `<span class="video-candidate-plays">${esc(plays)}</span>` : ''}
      </button>`;
    }).join('')}`;
    container.classList.remove('hidden');
  }

  // 旧存档里的候选播放量可能全是 0（搜索页抓取当时没取到）。打开后用稳定的 view 接口
  // 并发回补一次，列表与按播放量排序随即恢复；只补缺的，不重复请求已有播放量的。
  function healCandidatePlays(conversation, questionId) {
    const state = questionVideoState(conversation, questionId, false);
    const candidates = Array.isArray(state?.candidates) ? state.candidates : [];
    const missing = candidates.filter(video => video && video.bvid && !Number(video.plays)).map(video => video.bvid);
    if (!missing.length) return;
    const convId = currentConvId;
    const qid = questionId;
    window.api.enrichBilibiliStats(missing).then(items => {
      if (!Array.isArray(items) || !items.length) return;
      const byBvid = new Map(items.map(item => [item.bvid, item]));
      const latest = conversations[convId];
      const latestState = questionVideoState(latest, qid, false);
      if (!latestState || !Array.isArray(latestState.candidates)) return;
      let changed = false;
      for (const video of latestState.candidates) {
        const stats = byBvid.get(video?.bvid);
        if (!stats) continue;
        if (stats.plays && Number(video.plays || 0) !== stats.plays) { video.plays = stats.plays; changed = true; }
        if (!video.cover && stats.cover) { video.cover = stats.cover; changed = true; }
        if ((!video.title || video.title === '视频讲解') && stats.title) { video.title = stats.title; changed = true; }
      }
      if (latestState.video && byBvid.has(latestState.video.bvid)) {
        const stats = byBvid.get(latestState.video.bvid);
        if (stats && stats.plays && Number(latestState.video.plays || 0) !== stats.plays) {
          latestState.video = { ...latestState.video, plays: stats.plays };
          changed = true;
        }
      }
      if (!changed) return;
      saveConv(convId, latest.messages, { touch: false });
      if (convId === currentConvId && qid === activeVideoQuestionId) {
        renderVideoCandidates(latest, qid);
        if (activeWorkspaceVideo && latestState.video && activeWorkspaceVideo.bvid === latestState.video.bvid) {
          activeWorkspaceVideo = { ...activeWorkspaceVideo, plays: latestState.video.plays };
        }
        const nowPlays = window.BilibiliVideo.formatPlayCount(activeWorkspaceVideo?.plays);
        const badge = $('#video-now-plays');
        if (badge) {
          badge.textContent = nowPlays;
          badge.classList.toggle('hidden', !nowPlays);
        }
      }
    }).catch(error => console.warn('Failed to backfill video play counts:', error));
  }

  // 题目识别同样只看这条消息本身，不拼接 AI 解答或前文。
  function videoIdentificationSource(conversation, questionId) {
    const messages = Array.isArray(conversation?.messages) ? conversation.messages : [];
    const question = messages.find(message => message?.id === questionId && message.role === 'user')?.content || '';
    return displayUserContent(question).slice(0, 14000);
  }

  // 只判定这一条消息本身：带上前文会让模型把新贴的完整题干误判成追问。
  function videoEligibilitySource(conversation, questionId) {
    const messages = Array.isArray(conversation?.messages) ? conversation.messages : [];
    const index = messages.findIndex(message => message?.id === questionId && message.role === 'user');
    if (index < 0) return null;
    return { message: displayUserContent(messages[index].content).slice(0, 8000) };
  }

  function hasConfiguredVideoTaskModel() {
    if (!quickModelSettings) return true;
    const providerId = quickModelSettings.taskModels?.video?.providerId || quickModelSettings.activeProvider;
    const profile = quickModelSettings.providers?.[providerId];
    return Boolean(profile && String(profile.apiKey || '').trim());
  }

  function queueQuestionEligibilityCheck(conversationId, questionId) {
    const conversation = conversations[conversationId];
    const state = questionVideoState(conversation, questionId, true);
    if (!conversation || !state || state.video || ['eligible', 'ineligible'].includes(state.eligibility)) return;
    if (!hasConfiguredVideoTaskModel()) {
      state.eligibility = 'unknown';
      state.eligibilityReason = '未配置视频判定模型';
      updateMessageVideoAction(questionId);
      return;
    }
    const key = `${conversationId}:${questionId}`;
    if (videoEligibilityChecks.has(key)) return;
    state.eligibility = 'checking';
    updateMessageVideoAction(questionId);

    const task = videoEligibilityQueue
      .catch(() => {})
      .then(async () => {
        const latest = conversations[conversationId];
        const latestState = questionVideoState(latest, questionId, false);
        if (!latest || !latestState || latestState.video || ['eligible', 'ineligible'].includes(latestState.eligibility)) return;
        try {
          const result = await window.api.classifyBilibiliVideoEligibility(videoEligibilitySource(latest, questionId));
          if (conversations[conversationId] !== latest
            || !latest.messages?.some(message => message.id === questionId && message.role === 'user')
            || questionVideoState(latest, questionId, false) !== latestState) return;
          const providerUnavailable = result?.skipped === 'provider_unavailable';
          latestState.eligibility = providerUnavailable ? 'unknown' : (result?.eligible === true ? 'eligible' : 'ineligible');
          latestState.eligibilityReason = String(result?.reason || '').slice(0, 120);
          latestState.eligibilityCheckedAt = providerUnavailable ? 0 : Date.now();
          latestState.eligibilityVersion = providerUnavailable ? 0 : VIDEO_ELIGIBILITY_VERSION;
          if (latestState.eligibility === 'eligible') {
            latestState.identifiedTitle = String(result?.title || '').slice(0, 100);
            latestState.query = String(result?.query || '').trim().slice(0, 160);
          }
          addVideoSearchUsage(latest, result?.usage);
        } catch (error) {
          if (conversations[conversationId] !== latest
            || !latest.messages?.some(message => message.id === questionId && message.role === 'user')
            || questionVideoState(latest, questionId, false) !== latestState) return;
          latestState.eligibility = 'ineligible';
          latestState.eligibilityReason = '资格判定失败，默认隐藏';
          latestState.eligibilityCheckedAt = Date.now();
          latestState.eligibilityVersion = VIDEO_ELIGIBILITY_VERSION;
          console.warn('Video eligibility check failed; hiding the video entry:', error);
        }
        await saveConv(conversationId, latest.messages, { touch: false });
        if (currentConvId === conversationId) updateMessageVideoAction(questionId);
      })
      .finally(() => videoEligibilityChecks.delete(key));
    videoEligibilityChecks.set(key, task);
    videoEligibilityQueue = task;
  }

  function videoSearchKey(conversationId, questionId) {
    return `${conversationId}:${questionId}`;
  }

  function invalidateQuestionVideoSearch(conversationId, questionId) {
    const key = videoSearchKey(conversationId, questionId);
    const search = videoSearchStates.get(key);
    if (search) window.api.cancelBilibiliVideoSearch(search.token);
    videoSearchStates.delete(key);
  }

  function isOwnedVideoSearch(conversationId, questionId, token) {
    return conversations[conversationId]
      && videoSearchStates.get(videoSearchKey(conversationId, questionId))?.token === token;
  }

  async function recordOpenedVideo(video, conversationId = currentConvId, questionId = activeVideoQuestionId) {
    const normalized = normalizeConversationVideo(video);
    if (!normalized) return;
    const conversation = conversations[conversationId];
    const state = questionVideoState(conversation, questionId, false);
    const question = conversation?.messages?.find(message => message.id === questionId);
    try {
      videoHistory = await window.api.recordVideoHistory({
        ...normalized,
        query: state?.query || '',
        conversationId,
        questionId,
        questionTitle: extractTitle(question?.content || ''),
        progress: state?.progress || 0,
        duration: state?.duration || 0
      });
      renderVideoHistory();
    } catch (error) {
      console.warn('Failed to record video history:', error);
    }
  }

  function addVideoSearchUsage(conversation, usage) {
    if (!conversation || !usage) return;
    conversation.usage = addUsage(conversation.usage, normalizeStoredUsage(usage));
  }

  async function requestQuestionVideo(conversationId, questionId, { force = false } = {}) {
    const conversation = conversations[conversationId];
    const state = questionVideoState(conversation, questionId, true);
    if (!conversation || !state) return;
    if (!force && normalizeConversationVideo(state.video)) {
      activeWorkspaceVideo = normalizeConversationVideo(state.video);
      mountVideoPlayer(activeWorkspaceVideo);
      renderVideoCandidates(conversation, questionId);
      healCandidatePlays(conversation, questionId);
      return;
    }

    const searchKey = videoSearchKey(conversationId, questionId);
    const previous = videoSearchStates.get(searchKey);
    if (previous) window.api.cancelBilibiliVideoSearch(previous.token);
    const token = `v_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
    videoSearchStates.set(searchKey, { token, phase: 'identifying' });
    state.status = 'identifying';
    state.requestedAt = Date.now();
    state.error = '';
    state.attemptedAt = 0;
    await saveConv(conversationId, conversation.messages, { touch: false });
    updateMessageVideoAction(questionId);
    if (conversationId === currentConvId && questionId === activeVideoQuestionId) {
      unmountVideoPlayer();
      setVideoStage('searching', 'AI 正在识别题目');
      $('#video-now-source').textContent = '正在识别题目';
    }

    let query;
    let identifyError = null;
    for (let attempt = 0; attempt < 2 && !query; attempt += 1) {
      if (attempt) await new Promise(resolve => setTimeout(resolve, 500));
      try {
        const identified = await window.api.identifyBilibiliQuery(videoIdentificationSource(conversation, questionId));
        if (!isOwnedVideoSearch(conversationId, questionId, token)) return;
        const identifiedTitle = String(identified?.title || '').slice(0, 100);
        if (identifiedTitle) state.identifiedTitle = identifiedTitle;
        query = String(identified?.query || '').trim().slice(0, 160);
        addVideoSearchUsage(conversation, identified?.usage);
      } catch (error) {
        identifyError = error;
      }
    }
    if (!query) {
      if (!isOwnedVideoSearch(conversationId, questionId, token)) return;
      const question = conversation.messages.find(message => message.id === questionId)?.content || '';
      query = `LeetCode ${extractTitle(question).slice(0, 48)} 题解`;
      console.warn('AI problem identification failed twice, using short local fallback:', identifyError);
    }

    state.query = query;
    state.status = 'searching';
    videoSearchStates.set(searchKey, { token, phase: 'searching' });
    updateMessageVideoAction(questionId);
    if (conversationId === currentConvId && questionId === activeVideoQuestionId) {
      setVideoStage('searching', '正在匹配讲解', query);
      $('#video-now-source').textContent = query;
    }

    try {
      const directResult = await window.api.searchBilibiliVideo(query);
      if (!isOwnedVideoSearch(conversationId, questionId, token)) return;
      const video = normalizeConversationVideo(directResult);
      if (!video) throw new Error('暂未匹配到可播放视频');
      state.video = video;
      state.candidates = mergeVideoCandidates(directResult?.candidates, [video]);
      state.attemptedAt = Date.now();
      state.error = '';
      state.status = 'ready';
      await saveConv(conversationId, conversation.messages, { touch: false });
      updateMessageVideoAction(questionId);
      await recordOpenedVideo(video, conversationId, questionId);
      if (conversationId === currentConvId && questionId === activeVideoQuestionId && !$('#video-workspace').classList.contains('hidden')) {
        activeWorkspaceVideo = video;
        mountVideoPlayer(video);
        $('#video-now-source').textContent = query;
        renderVideoCandidates(conversation, questionId);
      }
    } catch (error) {
      if (!isOwnedVideoSearch(conversationId, questionId, token)) return;
      state.attemptedAt = Date.now();
      state.error = String(error?.message || '视频搜索失败').slice(0, 160);
      state.status = 'error';
      videoSearchStates.delete(searchKey);
      await saveConv(conversationId, conversation.messages, { touch: false });
      updateMessageVideoAction(questionId);
      if (conversationId === currentConvId && questionId === activeVideoQuestionId) setVideoStage('error', '暂未找到合适视频', state.error);
      return;
    }

    videoSearchStates.set(searchKey, { token, phase: 'enriching' });
    window.api.searchBilibiliVideoAi(token, query).then(async result => {
      if (!isOwnedVideoSearch(conversationId, questionId, token)) return;
      const latest = conversations[conversationId];
      const latestState = questionVideoState(latest, questionId, true);
      latestState.candidates = mergeVideoCandidates(latestState.candidates, result?.candidates);
      addVideoSearchUsage(latest, result?.usage);
      await saveConv(conversationId, latest.messages, { touch: false });
      if (conversationId === currentConvId && questionId === activeVideoQuestionId) renderVideoCandidates(latest, questionId);
    }).catch(error => {
      if (error?.name !== 'AbortError') console.warn('AI video web search failed:', error);
    }).finally(() => {
      if (isOwnedVideoSearch(conversationId, questionId, token)) {
        videoSearchStates.delete(searchKey);
        updateMessageVideoAction(questionId);
      }
    });
  }

  function setVideoTab(tab) {
    activeVideoTab = tab === 'history' ? 'history' : 'player';
    const historyActive = activeVideoTab === 'history';
    $('#video-tab-player').classList.toggle('active', !historyActive);
    $('#video-tab-player').setAttribute('aria-selected', historyActive ? 'false' : 'true');
    $('#video-tab-player').tabIndex = historyActive ? -1 : 0;
    $('#video-tab-history').classList.toggle('active', historyActive);
    $('#video-tab-history').setAttribute('aria-selected', historyActive ? 'true' : 'false');
    $('#video-tab-history').tabIndex = historyActive ? 0 : -1;
    $('#video-player-view').classList.toggle('hidden', historyActive);
    $('#video-history-view').classList.toggle('hidden', !historyActive);
    if (historyActive) renderVideoHistory();
  }

  // 每次流式/输入刷新都会查询序号；按消息数组引用+长度缓存，避免全量遍历。
  let ordinalCacheMessages = null;
  let ordinalCacheLength = -1;
  let ordinalCacheMap = null;

  function userQuestionOrdinal(messages, questionId) {
    const list = Array.isArray(messages) ? messages : [];
    if (list !== ordinalCacheMessages || list.length !== ordinalCacheLength) {
      ordinalCacheMap = new Map();
      let count = 0;
      for (const item of list) {
        if (item?.role === 'user') ordinalCacheMap.set(item.id, ++count);
      }
      ordinalCacheMessages = list;
      ordinalCacheLength = list.length;
    }
    return ordinalCacheMap.get(questionId) || 0;
  }

  function questionOrdinal(conversation, questionId) {
    return userQuestionOrdinal(conversation?.messages, questionId);
  }

  function openVideoWorkspace(questionId, { force = false } = {}) {
    const conversation = conversations[currentConvId];
    const question = conversation?.messages?.find(message => message.id === questionId && message.role === 'user');
    if (!currentConvId || !conversation || !question) return;
    if (activeVideoQuestionId && activeVideoQuestionId !== questionId) unmountVideoPlayer();
    activeVideoQuestionId = questionId;
    videoReturnTarget = document.querySelector(`.message-video-action[data-video-question="${CSS.escape(questionId)}"]`);
    const switching = anyPanelOpen();
    if (!switching) chatScrollAnchor = captureMessagesAnchor();
    $('#history-overlay').classList.add('hidden');
    $('#usage-overlay').classList.add('hidden');
    $('#settings-overlay').classList.add('hidden');
    $('#learning-overlay').classList.add('hidden');
    $('#video-workspace').classList.toggle('no-entry-anim', switching);
    $('#video-workspace').classList.remove('hidden');
    messagesEl.inert = true;
    inputBar.inert = true;
    scrollBottomButton.inert = true;
    setVideoTab('player');
    const ordinal = questionOrdinal(conversation, questionId);
    $('#video-workspace-title').textContent = `题目 ${ordinal} · 视频讲解`;
    $('#video-question-label').textContent = extractTitle(question.content);
    const state = questionVideoState(conversation, questionId, true);
    const existingVideo = normalizeConversationVideo(state.video);
    $('#video-autoplay-input').checked = videoAutoplay;
    updateVideoTrigger();
    $('#btn-close-video').focus({ preventScroll: true });
    if (existingVideo) {
      activeWorkspaceVideo = existingVideo;
      mountVideoPlayer(existingVideo);
      $('#video-now-source').textContent = state.query || '历史匹配';
      renderVideoCandidates(conversation, questionId);
      healCandidatePlays(conversation, questionId);
      recordOpenedVideo(existingVideo, currentConvId, questionId);
    } else {
      activeWorkspaceVideo = null;
      requestQuestionVideo(currentConvId, questionId, { force: force || ['error', 'empty'].includes(state.status) });
    }
  }

  function stopLoginPolling() {
    if (loginPollTimer) clearTimeout(loginPollTimer);
    loginPollTimer = 0;
    activeLoginSessionId = '';
    biliLoginGeneration += 1;
  }

  function closeVideoWorkspace({ returnToQuestion = false, restoreScroll = true } = {}) {
    const returnTarget = videoReturnTarget;
    const learningContext = videoReturnLearningContext;
    videoReturnLearningContext = null;
    $('#video-workspace').classList.add('hidden');
    messagesEl.inert = false;
    inputBar.inert = false;
    scrollBottomButton.inert = false;
    biliAccountGeneration += 1;
    $('#bili-account-sheet').classList.add('hidden');
    stopLoginPolling();
    unmountVideoPlayer();
    updateVideoTrigger();
    if (learningContext) {
      setTimeout(() => {
        openLearningOverlay({ itemId: learningContext.itemId, tab: learningContext.tab })
          .catch(error => console.warn('Failed to restore learning center:', error));
      }, 0);
      return;
    }
    // 回到离开时的那一屏，而不是把题目重新居中。
    if (restoreScroll) {
      const savedAnchor = chatScrollAnchor;
      chatScrollAnchor = null;
      restoreMessagesAnchor(savedAnchor);
    }
    if (returnToQuestion && returnTarget?.isConnected) {
      returnTarget.focus({ preventScroll: true });
    }
  }

  // 用「哪条消息停在视口顶部、偏移多少」记录位置。视频按钮显隐会改变消息区总高度，
  // 单纯记像素偏移在内容变高后就不再是同一屏了。
  function captureMessagesAnchor() {
    const scrollerTop = messagesEl.getBoundingClientRect().top;
    for (const message of messagesEl.querySelectorAll('.message')) {
      const rect = message.getBoundingClientRect();
      if (rect.bottom > scrollerTop + 1) {
        return { id: message.dataset.messageId || '', offset: rect.top - scrollerTop, top: messagesEl.scrollTop, autoFollow };
      }
    }
    return { id: '', offset: 0, top: messagesEl.scrollTop, autoFollow };
  }

  function restoreMessagesAnchor(anchor) {
    if (!anchor) return;
    autoFollow = anchor.autoFollow;
    const apply = () => {
      const message = anchor.id
        ? messagesEl.querySelector(`.message[data-message-id="${CSS.escape(anchor.id)}"]`)
        : null;
      if (message) {
        const scrollerTop = messagesEl.getBoundingClientRect().top;
        messagesEl.scrollTop += (message.getBoundingClientRect().top - scrollerTop) - anchor.offset;
      } else {
        messagesEl.scrollTop = anchor.top;
      }
      lastScrollTop = messagesEl.scrollTop;
    };
    apply();
    // 关闭瞬间按钮重新显示会再改一次高度，下一帧按同一锚点校正。
    requestAnimationFrame(() => {
      if ($('#video-workspace').classList.contains('hidden')) apply();
      updateScrollButton();
    });
    updateScrollButton();
  }

  function formatVideoHistoryTime(timestamp) {
    const value = Number(timestamp) || 0;
    if (!value) return '';
    return new Date(value).toLocaleString('zh-CN', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  }

  function formatVideoPosition(seconds) {
    const value = Math.max(0, Math.floor(Number(seconds) || 0));
    const minutes = Math.floor(value / 60);
    return `${minutes}:${String(value % 60).padStart(2, '0')}`;
  }

  function renderVideoHistory() {
    const count = $('#video-history-count');
    count.textContent = String(videoHistory.length);
    count.classList.toggle('hidden', !videoHistory.length);
    $('#btn-clear-video-history').classList.toggle('hidden', !videoHistory.length);
    const list = $('#video-history-list');
    if (!videoHistory.length) {
      list.innerHTML = '<div class="video-history-empty">暂无视频记录</div>';
      return;
    }
    list.innerHTML = videoHistory.map(item => `<article class="video-history-item" data-bvid="${esc(item.bvid)}">
      <button class="video-history-open" type="button" aria-label="播放 ${esc(item.title)}">
        <div class="video-history-cover">${item.cover ? `<img src="${esc(item.cover)}" alt="" loading="lazy">` : ''}</div>
        <div class="video-history-info"><strong>${esc(item.title)}</strong><span>${item.questionTitle ? `${esc(item.questionTitle)} · ` : ''}${item.progress > 1 ? `${formatVideoPosition(item.progress)} · ` : ''}${esc(formatVideoHistoryTime(item.lastOpenedAt))}${item.openCount > 1 ? ` · ${numberFormatter.format(item.openCount)} 次` : ''}</span></div>
      </button>
      <button class="video-tool-button video-history-delete" type="button" data-delete-bvid="${esc(item.bvid)}" title="删除视频记录" aria-label="删除视频记录"><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 7h16M9 7V4h6v3m3 0-1 13H7L6 7" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
    </article>`).join('');
  }

  function updateBilibiliAuthUi(state) {
    biliAuthState = state?.loggedIn ? {
      loggedIn: true,
      name: String(state.name || 'B站用户'),
      avatar: String(state.avatar || ''),
      isVip: Boolean(state.isVip),
      vipLabel: String(state.vipLabel || '')
    } : { loggedIn: false, name: '', avatar: '', isVip: false, vipLabel: '' };
    for (const button of [$('#btn-bili-account'), ...document.querySelectorAll('.message-video-action')]) {
      button.dataset.auth = biliAuthState.loggedIn ? 'authenticated' : 'guest';
    }
    const avatar = $('#bili-account-avatar');
    avatar.classList.toggle('hidden', !biliAuthState.loggedIn || !biliAuthState.avatar);
    avatar.style.backgroundImage = biliAuthState.avatar ? `url("${biliAuthState.avatar.replace(/"/g, '')}")` : '';
    $('#btn-bili-account').title = biliAuthState.loggedIn ? biliAuthState.name : '扫码登录 B 站';
  }

  function renderBilibiliProfile() {
    $('#bili-account-content').innerHTML = `<div class="bili-profile-view">
      <div class="bili-profile-avatar" style="background-image:url('${esc(biliAuthState.avatar)}')"></div>
      <strong class="bili-profile-name">${esc(biliAuthState.name)}</strong>
      ${biliAuthState.isVip ? `<span class="bili-vip-badge">${esc(biliAuthState.vipLabel || '大会员')}</span>` : ''}
      <button class="bili-logout" id="btn-bili-logout" type="button">退出登录</button>
    </div>`;
  }

  function renderBilibiliLoginQr(sessionInfo, status = 'waiting') {
    const statusText = status === 'scanned' ? '已扫码，请在手机上确认' : '使用哔哩哔哩客户端扫码';
    $('#bili-account-content').innerHTML = `<div class="bili-login-view">
      <div class="bili-qr-shell"><img src="${esc(sessionInfo.qrDataUrl)}" alt="B站登录二维码"><div class="bili-qr-overlay hidden" id="bili-qr-overlay"></div></div>
      <strong class="bili-login-status" id="bili-login-status">${statusText}</strong>
    </div>`;
  }

  function scheduleBilibiliLoginPoll(sessionInfo) {
    loginPollTimer = setTimeout(async () => {
      const ownsSession = () => activeLoginSessionId === sessionInfo.id && !$('#bili-account-sheet').classList.contains('hidden');
      if (!ownsSession()) return;
      try {
        const result = await window.api.pollBilibiliLogin(sessionInfo.id);
        if (!ownsSession()) return;
        if (result.status === 'success') {
          stopLoginPolling();
          updateBilibiliAuthUi(result.authState);
          renderBilibiliProfile();
          if (activeWorkspaceVideo) mountVideoPlayer(activeWorkspaceVideo, { force: true });
          return;
        }
        if (result.status === 'confirming') {
          { const status = $('#bili-login-status'); if (status) status.textContent = '登录成功，正在同步账号'; }
          const overlay = $('#bili-qr-overlay');
          if (overlay) {
            overlay.textContent = '正在同步';
            overlay.classList.remove('hidden');
          }
        }
        if (result.status === 'expired') {
          const authState = await window.api.getBilibiliAuthState().catch(() => null);
          if (!ownsSession()) return;
          if (authState?.loggedIn) {
            stopLoginPolling();
            updateBilibiliAuthUi(authState);
            renderBilibiliProfile();
            if (activeWorkspaceVideo) mountVideoPlayer(activeWorkspaceVideo, { force: true });
            return;
          }
          stopLoginPolling();
          const expiredOverlay = $('#bili-qr-overlay');
          if (expiredOverlay) {
            expiredOverlay.textContent = '二维码已过期';
            expiredOverlay.classList.remove('hidden');
          }
          const status = $('#bili-login-status');
          if (status) status.textContent = '请刷新后重新扫码';
          if (!$('#btn-refresh-bili-login')) {
            $('#bili-account-content')?.insertAdjacentHTML('beforeend', '<button class="bili-login-refresh" id="btn-refresh-bili-login" type="button">刷新二维码</button>');
          }
          return;
        }
        if (result.status === 'scanned') { const status = $('#bili-login-status'); if (status) status.textContent = '已扫码，请在手机上确认'; }
      } catch (error) {
        console.warn('Bilibili login poll failed:', error);
      }
      if (ownsSession()) scheduleBilibiliLoginPoll(sessionInfo);
    }, 1400);
  }

  async function startBilibiliLogin() {
    stopLoginPolling();
    const generation = biliLoginGeneration;
    $('#bili-account-content').innerHTML = '<div class="bili-login-view"><div class="bili-login-spinner" aria-hidden="true"></div><strong class="bili-login-status">正在创建登录二维码</strong></div>';
    try {
      const sessionInfo = await window.api.beginBilibiliLogin();
      if (generation !== biliLoginGeneration || $('#bili-account-sheet').classList.contains('hidden')) return;
      activeLoginSessionId = sessionInfo.id;
      renderBilibiliLoginQr(sessionInfo);
      scheduleBilibiliLoginPoll(sessionInfo);
    } catch (error) {
      if (generation !== biliLoginGeneration || $('#bili-account-sheet').classList.contains('hidden')) return;
      $('#bili-account-content').innerHTML = `<div class="bili-login-view"><strong class="bili-login-status">${esc(error?.message || '无法创建登录二维码')}</strong><button class="bili-login-refresh" id="btn-refresh-bili-login" type="button">重试</button></div>`;
    }
  }

  async function openBilibiliAccount() {
    const generation = ++biliAccountGeneration;
    $('#bili-account-sheet').classList.remove('hidden');
    $('#bili-account-content').innerHTML = '<div class="bili-login-view"><div class="bili-login-spinner" aria-hidden="true"></div><strong class="bili-login-status">正在检查账号状态</strong></div>';
    const latest = await window.api.getBilibiliAuthState().catch(() => biliAuthState);
    if (generation !== biliAccountGeneration || $('#bili-account-sheet').classList.contains('hidden')) return;
    updateBilibiliAuthUi(latest);
    if (biliAuthState.loggedIn) renderBilibiliProfile();
    else startBilibiliLogin();
  }

  async function setVideoAutoplay(enabled) {
    const previousValue = videoAutoplay;
    videoAutoplay = Boolean(enabled);
    try {
      await window.api.patchSettings({ videoAutoplay });
      $('#video-autoplay-input').checked = videoAutoplay;
    } catch (error) {
      videoAutoplay = previousValue;
      $('#video-autoplay-input').checked = videoAutoplay;
      console.warn('Failed to save video autoplay setting:', error);
    }
  }

  function renderWindowPinState(value) {
    windowPinned = value === true;
    if (settingsDraft) settingsDraft.alwaysOnTop = windowPinned;
    const button = $('#btn-pin-window');
    if (!button) return;
    button.setAttribute('aria-pressed', String(windowPinned));
    const label = windowPinned ? '取消窗口置顶' : '保持窗口置顶';
    button.setAttribute('aria-label', label);
    button.title = label;
  }

  function normalizeSettingsForUi(settings = {}) {
    const source = settings && typeof settings === 'object' ? settings : {};
    const storedProfiles = source.providers && typeof source.providers === 'object' ? source.providers : {};
    const providers = {};
    for (const provider of ['deepseek', 'alibaba', 'opencode-go']) {
      const defaults = PROVIDER_UI_DEFAULTS[provider];
      const stored = storedProfiles[provider] && typeof storedProfiles[provider] === 'object' ? storedProfiles[provider] : {};
      providers[provider] = { ...defaults, ...stored, name: String(stored.name || defaults.name), apiBase: String(stored.apiBase || defaults.apiBase).trim().replace(/\/+$/, ''), apiKey: String(stored.apiKey || '').trim(), model: String(stored.model || defaults.model).trim() };
    }
    for (const [provider, stored] of Object.entries(storedProfiles)) {
      if (providers[provider] || !/^custom-[a-z0-9][a-z0-9-]{0,63}$/i.test(provider) || !stored || typeof stored !== 'object') continue;
      providers[provider] = {
        name: String(stored.name || '自定义供应商').trim(),
        apiBase: String(stored.apiBase || '').trim().replace(/\/+$/, ''),
        apiKey: String(stored.apiKey || '').trim(),
        model: String(stored.model || 'model-name').trim(),
        apiMode: ['auto', 'responses', 'chat', 'messages'].includes(stored.apiMode) ? stored.apiMode : 'auto',
        resolvedMode: ['responses', 'messages'].includes(stored.resolvedMode) ? stored.resolvedMode : 'chat',
        builtIn: false
      };
    }
    const requestedOrder = Array.isArray(source.providerOrder) ? source.providerOrder : [];
    const providerOrder = [...new Set(['deepseek', 'alibaba', 'opencode-go', ...requestedOrder, ...Object.keys(providers)])].filter(id => providers[id]);
    const activeProvider = providers[source.activeProvider] ? source.activeProvider : 'deepseek';
    const taskIds = ['conversation', 'title', 'video', 'learning', 'studyPlan', 'studyContent', 'studyAssessment', 'leetCodeAnalysis'];
    const learningFallbacks = new Set(['studyPlan', 'studyContent', 'studyAssessment', 'leetCodeAnalysis']);
    const taskModels = Object.fromEntries(taskIds.map(task => {
      const route = source.taskModels?.[task]
        || (learningFallbacks.has(task) ? source.taskModels?.learning : null)
        || {};
      return [task, { providerId: providers[route.providerId] ? route.providerId : '', model: String(route.model || '').trim() }];
    }));
    const storedContext = source.contextPolicy && typeof source.contextPolicy === 'object' ? source.contextPolicy : {};
    return {
      schemaVersion: 3,
      activeProvider,
      providerOrder,
      providers,
      taskModels,
      contextPolicy: { ...DEFAULT_CONTEXT_POLICY, ...storedContext },
      reasoningEffort: normalizeReasoningEffort(source.reasoningEffort),
      videoAutoplay: source.videoAutoplay !== false,
      alwaysOnTop: source.alwaysOnTop === true
    };
  }

  function providerIds(settings = quickModelSettings) {
    if (!settings) return ['deepseek', 'alibaba'];
    return (Array.isArray(settings.providerOrder) ? settings.providerOrder : Object.keys(settings.providers || {}))
      .filter((provider, index, list) => settings.providers?.[provider] && list.indexOf(provider) === index);
  }

  function providerLabel(provider, settings = quickModelSettings) {
    return settings?.providers?.[provider]?.name || PROVIDER_UI_DEFAULTS[provider]?.name || '自定义供应商';
  }

  function providerAvatar(provider) {
    if (provider === 'deepseek') return '<img src="../../assets/providers/deepseek.png" alt="">';
    if (provider === 'alibaba') return '<img src="../../assets/providers/alibaba-cloud.svg" alt="">';
    if (provider === 'opencode-go') return '<img src="../../assets/providers/opencode.svg" alt="">';
    return esc(providerLabel(provider, settingsDraft).slice(0, 2).toUpperCase());
  }

  function renderActiveModelStatus(settings = null) {
    const normalized = settings ? normalizeSettingsForUi(settings) : null;
    if (normalized) {
      const previous = quickModelSettings;
      const available = {};
      for (const provider of providerIds(normalized)) {
        const previousProfile = previous?.providers?.[provider];
        const nextProfile = normalized.providers[provider];
        if (previousProfile
          && previousProfile.apiBase === nextProfile.apiBase
          && previousProfile.apiKey === nextProfile.apiKey
          && Array.isArray(previous.available?.[provider])) {
          available[provider] = previous.available[provider];
        }
      }
      currentAiProvider = normalized.activeProvider;
      currentAiModel = normalized.providers[currentAiProvider].model;
      contextPolicy = { ...DEFAULT_CONTEXT_POLICY, ...normalized.contextPolicy };
      quickModelSettings = {
        ...normalized,
        available
      };
    }
    const label = providerLabel(currentAiProvider, quickModelSettings);
    const chip = $('#btn-active-model');
    chip.dataset.provider = currentAiProvider;
    chip.title = `${label} · ${currentAiModel}`;
    $('#active-model-provider').textContent = label;
    $('#active-model-name').textContent = currentAiModel;
    renderReasoningControl();
    updateContextMeter();
  }

  function closeQuickModelOptions({ restoreFocus = false } = {}) {
    const options = $('#chat-model-options');
    if (options.dataset.open !== 'true') return;
    options.dataset.open = 'false';
    options.inert = true;
    options.setAttribute('aria-hidden', 'true');
    $('#btn-active-model').setAttribute('aria-expanded', 'false');
    if (restoreFocus) $('#btn-active-model').focus({ preventScroll: true });
  }

  function quickModelList(provider) {
    const profile = quickModelSettings?.providers?.[provider] || PROVIDER_UI_DEFAULTS[provider] || {};
    return [...new Set([profile.model, ...(quickModelSettings?.available?.[provider] || [])].filter(Boolean))].slice(0, 40);
  }

  function ensureQuickModelShell(options) {
    const signature = providerIds().join('|');
    if (options.querySelector('.quick-model-scroll') && options.dataset.providerSignature === signature) return;
    options.dataset.providerSignature = signature;
    options.innerHTML = `<div class="quick-model-scroll">
      ${providerIds().map(provider => `<section class="quick-model-group" data-provider="${esc(provider)}"><div class="quick-model-heading"><span>${esc(providerLabel(provider))}</span><i aria-hidden="true"></i></div></section>`).join('')}
    </div><button class="quick-model-settings" id="btn-quick-model-settings" type="button" role="menuitem">
      <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.9" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.4 1A8 8 0 0 0 15 6.2L14.7 3h-4L10.4 6.2a8 8 0 0 0-1.5.9l-2.4-1-2 3.4 2 1.5a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.4-1a8 8 0 0 0 1.5.9l.3 3.2h4l.3-3.2a8 8 0 0 0 1.5-.9l2.4 1 2-3.4-2-1.5a7 7 0 0 0 .1-1Z" stroke-linecap="round" stroke-linejoin="round"/></svg>
      <span>管理供应商与模型</span>
    </button>`;
  }

  function renderQuickModelOptions(loadingProviders = quickModelLoadingProviders) {
    if (!quickModelSettings) return;
    const options = $('#chat-model-options');
    ensureQuickModelShell(options);
    const previousScrollTop = options.querySelector('.quick-model-scroll')?.scrollTop || 0;
    for (const provider of providerIds()) {
      const profile = quickModelSettings.providers[provider];
      const models = quickModelList(provider);
      const section = options.querySelector(`.quick-model-group[data-provider="${provider}"]`);
      const desired = new Set(models);
      const existing = new Map([...section.querySelectorAll('.quick-model-option')]
        .map(button => [button.dataset.quickModel, button]));
      for (const [model, button] of existing) {
        if (!desired.has(model)) button.remove();
      }

      const statusText = !profile.apiKey
        ? '未配置 API Key'
        : (loadingProviders.has(provider) ? '正在获取模型…' : '');
      let status = section.querySelector('.quick-model-status');
      if (statusText) {
        if (!status) {
          status = document.createElement('div');
          status.className = 'quick-model-status';
          section.appendChild(status);
        }
        status.textContent = statusText;
      } else {
        status?.remove();
        status = null;
      }

      for (const model of models) {
        let button = existing.get(model);
        if (!button || !button.isConnected) {
          button = document.createElement('button');
          button.className = 'quick-model-option';
          button.type = 'button';
          button.setAttribute('role', 'menuitemradio');
          button.appendChild(document.createElement('span'));
        }
        button.dataset.quickProvider = provider;
        button.dataset.quickModel = model;
        button.querySelector('span').textContent = model;
        button.setAttribute('aria-checked', quickModelSettings.activeProvider === provider && profile.model === model ? 'true' : 'false');
        button.disabled = !profile.apiKey;
        button.title = profile.apiKey ? '' : '请先配置该供应商 API Key';
        section.insertBefore(button, status);
      }
    }
    const scroll = options.querySelector('.quick-model-scroll');
    if (scroll) scroll.scrollTop = Math.min(previousScrollTop, Math.max(0, scroll.scrollHeight - scroll.clientHeight));
  }

  function warmQuickModelCache({ force = false } = {}) {
    if (!quickModelSettings) return Promise.resolve();
    if (quickModelWarmPromise) return quickModelWarmPromise;
    const providers = providerIds().filter(provider => {
      const profile = quickModelSettings.providers[provider];
      return profile.apiKey && (force || !Array.isArray(quickModelSettings.available[provider]));
    });
    if (!providers.length) return Promise.resolve();

    const snapshots = Object.fromEntries(providers.map(provider => {
      const profile = quickModelSettings.providers[provider];
      return [provider, { ...profile }];
    }));
    providers.forEach(provider => quickModelLoadingProviders.add(provider));
    renderQuickModelOptions();
    quickModelWarmPromise = Promise.all(providers.map(async provider => {
      const profile = snapshots[provider];
      try {
        const models = await window.api.listModels({ activeProvider: provider, ...profile });
        const current = quickModelSettings?.providers?.[provider];
        if (current?.apiBase === profile.apiBase && current?.apiKey === profile.apiKey) {
          quickModelSettings.available[provider] = Array.isArray(models) ? models : [];
        }
      } catch (error) {
        const current = quickModelSettings?.providers?.[provider];
        if (current?.apiBase === profile.apiBase && current?.apiKey === profile.apiKey) {
          quickModelSettings.available[provider] = [];
        }
      } finally {
        quickModelLoadingProviders.delete(provider);
        renderQuickModelOptions();
      }
    })).finally(() => {
      quickModelWarmPromise = null;
    });
    return quickModelWarmPromise;
  }

  async function openQuickModelOptions() {
    const options = $('#chat-model-options');
    if (options.dataset.open === 'true') {
      closeQuickModelOptions({ restoreFocus: true });
      return;
    }
    if (!quickModelSettings) renderActiveModelStatus(await window.api.getSettings());
    const warming = warmQuickModelCache().catch(error => {
      console.warn('Failed to warm quick models:', error);
    });
    await Promise.race([
      warming,
      new Promise(resolve => setTimeout(resolve, QUICK_MODEL_OPEN_BUDGET_MS))
    ]);
    renderQuickModelOptions();
    options.inert = false;
    options.setAttribute('aria-hidden', 'false');
    options.dataset.open = 'true';
    $('#btn-active-model').setAttribute('aria-expanded', 'true');
  }

  async function switchQuickModel(provider, model) {
    if (!quickModelSettings?.providers?.[provider] || !model) return;
    const saved = normalizeSettingsForUi(await window.api.getSettings());
    saved.activeProvider = provider;
    saved.providers[provider].model = model;
    const profile = saved.providers[provider];
    const next = await window.api.saveSettings({
      ...saved,
      apiBase: profile.apiBase,
      apiKey: profile.apiKey,
      model: profile.model,
      reasoningEffort,
      videoAutoplay
    });
    renderActiveModelStatus(next);
    closeQuickModelOptions({ restoreFocus: true });
  }

  function captureSettingsProfile() {
    if (!settingsDraft) return;
    const current = settingsDraft.providers[settingsDraft.activeProvider] || {};
    settingsDraft.providers[settingsDraft.activeProvider] = {
      ...current,
      name: $('#s-provider-name').value.trim() || current.name,
      apiBase: $('#s-base').value.trim(),
      apiKey: $('#s-key').value.trim(),
      model: $('#s-model').value.trim(),
      apiMode: $('#s-api-mode').value
    };
  }

  function renderProviderList() {
    if (!settingsDraft) return;
    $('#provider-list').innerHTML = providerIds(settingsDraft).map(provider => {
      const profile = settingsDraft.providers[provider];
      let hostname = profile.apiBase;
      try { hostname = new URL(profile.apiBase).hostname; } catch (error) {}
      return `<button class="provider-row" type="button" role="option" data-provider="${esc(provider)}" data-custom="${profile.builtIn ? 'false' : 'true'}" aria-selected="${provider === settingsDraft.activeProvider ? 'true' : 'false'}"><i class="provider-avatar">${providerAvatar(provider)}</i><span><strong>${esc(profile.name)}</strong><span>${esc(profile.model || hostname || '待配置')}</span></span></button>`;
    }).join('');
  }

  function renderTaskRoutes() {
    if (!settingsDraft) return;
    const options = [`<option value="">跟随当前聊天</option>`, ...providerIds(settingsDraft).map(provider => `<option value="${esc(provider)}">${esc(providerLabel(provider, settingsDraft))}</option>`)].join('');
    for (const row of document.querySelectorAll('[data-task-route]')) {
      const route = settingsDraft.taskModels[row.dataset.taskRoute] || { providerId: '', model: '' };
      const providerSelect = row.querySelector('[data-task-provider]');
      providerSelect.innerHTML = options;
      providerSelect.value = route.providerId;
      const modelInput = row.querySelector('[data-task-model]');
      modelInput.value = route.model;
      modelInput.disabled = !route.providerId;
    }
  }

  function renderContextSettings() {
    const policy = settingsDraft?.contextPolicy || DEFAULT_CONTEXT_POLICY;
    $('#s-context-window').value = Math.round(Number(policy.contextWindowTokens) || DEFAULT_CONTEXT_POLICY.contextWindowTokens);
    $('#s-context-reserve').value = Math.round(Number(policy.reservedOutputTokens) || DEFAULT_CONTEXT_POLICY.reservedOutputTokens);
    $('#s-context-threshold').value = Math.round((Number(policy.compressionThreshold) || DEFAULT_CONTEXT_POLICY.compressionThreshold) * 100);
    $('#s-context-target').value = Math.round((Number(policy.postCompressionRatio) || DEFAULT_CONTEXT_POLICY.postCompressionRatio) * 100);
    $('#s-context-recent').value = Math.round(Number(policy.recentMessages) || DEFAULT_CONTEXT_POLICY.recentMessages);
    $('#s-context-images').value = Math.max(0, Math.round(Number(policy.maxImages) || 0));
  }

  function selectSettingsProvider(provider, { refresh = true } = {}) {
    if (!settingsDraft || !settingsDraft.providers[provider]) return;
    if (settingsDraft.activeProvider !== provider) captureSettingsProfile();
    settingsDraft.activeProvider = provider;
    const profile = settingsDraft.providers[provider];
    $('#s-base').value = profile.apiBase;
    $('#s-key').value = profile.apiKey;
    $('#s-model').value = profile.model;
    $('#s-provider-name').value = profile.name;
    $('#s-provider-name').readOnly = Boolean(profile.builtIn);
    $('#s-api-mode').value = profile.apiMode || 'auto';
    $('#btn-delete-provider').classList.toggle('hidden', Boolean(profile.builtIn));
    $('#deepseek-account-links').classList.toggle('hidden', provider !== 'deepseek');
    $('#opencode-account-links').classList.toggle('hidden', provider !== 'opencode-go');
    availableModels = [];
    closeModelOptions();
    renderProviderList();
    const status = $('#model-status');
    status.classList.remove('error');
    status.textContent = profile.apiKey ? '正在获取模型列表…' : '填写 API Key 后可获取模型列表';
    if (refresh && profile.apiKey) refreshModels({ quiet: true });
  }

  function addSettingsProvider() {
    if (!settingsDraft) return;
    captureSettingsProfile();
    let id;
    do { id = `custom-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`; } while (settingsDraft.providers[id]);
    settingsDraft.providers[id] = {
      name: '自定义供应商',
      apiBase: '',
      apiKey: '',
      model: 'model-name',
      apiMode: 'auto',
      resolvedMode: 'chat',
      builtIn: false
    };
    settingsDraft.providerOrder.push(id);
    renderTaskRoutes();
    selectSettingsProvider(id, { refresh: false });
    $('#s-base').focus({ preventScroll: true });
  }

  function deleteSettingsProvider() {
    if (!settingsDraft) return;
    const provider = settingsDraft.activeProvider;
    if (settingsDraft.providers[provider]?.builtIn) return;
    delete settingsDraft.providers[provider];
    settingsDraft.providerOrder = settingsDraft.providerOrder.filter(id => id !== provider);
    for (const task of Object.keys(settingsDraft.taskModels)) {
      if (settingsDraft.taskModels[task].providerId === provider) settingsDraft.taskModels[task] = { providerId: '', model: '' };
    }
    settingsDraft.activeProvider = settingsDraft.providers.deepseek ? 'deepseek' : settingsDraft.providerOrder[0];
    renderTaskRoutes();
    selectSettingsProvider(settingsDraft.activeProvider, { refresh: false });
  }

  function captureTaskRoutes() {
    if (!settingsDraft) return;
    for (const row of document.querySelectorAll('[data-task-route]')) {
      const providerId = row.querySelector('[data-task-provider]').value;
      settingsDraft.taskModels[row.dataset.taskRoute] = {
        providerId,
        model: providerId ? row.querySelector('[data-task-model]').value.trim() : ''
      };
    }
  }

  function captureContextSettings() {
    if (!settingsDraft) return;
    settingsDraft.contextPolicy = {
      contextWindowTokens: Number($('#s-context-window').value),
      reservedOutputTokens: Number($('#s-context-reserve').value),
      compressionThreshold: Number($('#s-context-threshold').value) / 100,
      postCompressionRatio: Number($('#s-context-target').value) / 100,
      recentMessages: Number($('#s-context-recent').value),
      maxImages: Number($('#s-context-images').value)
    };
  }

  function showSettingsPage(page) {
    const target = ['providers', 'routing', 'context', 'media'].includes(page) ? page : 'providers';
    for (const button of document.querySelectorAll('[data-settings-page]')) {
      const active = button.dataset.settingsPage === target;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', active ? 'true' : 'false');
      button.tabIndex = active ? 0 : -1;
    }
    for (const panel of document.querySelectorAll('[data-settings-panel]')) {
      panel.classList.toggle('active', panel.dataset.settingsPanel === target);
    }
  }

  function normalizeReasoningEffort(value) {
    const normalized = String(value || '').trim().toLowerCase();
    return Object.hasOwn(REASONING_LABELS, normalized) ? normalized : 'high';
  }

  function activeModelRequiresThinking() {
    return currentAiProvider === 'alibaba'
      && String(currentAiModel).toLowerCase() === 'qwen3.8-max-preview';
  }

  function effectiveReasoningEffort(value = reasoningEffort) {
    const normalized = normalizeReasoningEffort(value);
    return activeModelRequiresThinking() && normalized === 'off' ? 'low' : normalized;
  }

  function closeReasoningOptions({ restoreFocus = false } = {}) {
    const options = $('#reasoning-options');
    const trigger = $('#btn-reasoning');
    options.classList.add('hidden');
    trigger.setAttribute('aria-expanded', 'false');
    if (restoreFocus) trigger.focus({ preventScroll: true });
  }

  function renderReasoningControl() {
    reasoningEffort = normalizeReasoningEffort(reasoningEffort);
    const effectiveEffort = effectiveReasoningEffort();
    const minimumIsLow = activeModelRequiresThinking();
    $('#reasoning-value').textContent = REASONING_LABELS[effectiveEffort];
    $('#btn-reasoning').title = activeStream
      ? `调整下一次请求的推理强度，当前生成保持${REASONING_LABELS[activeStream.reasoningEffort] || '原设置'}`
      : (minimumIsLow ? `推理强度：${REASONING_LABELS[effectiveEffort]}（当前模型最低为低）` : `推理强度：${REASONING_LABELS[effectiveEffort]}`);
    for (const option of document.querySelectorAll('[data-reasoning-effort]')) {
      const unavailable = minimumIsLow && option.dataset.reasoningEffort === 'off';
      option.disabled = unavailable;
      option.title = unavailable ? '当前模型使用工具时必须开启思考' : '';
      option.setAttribute('aria-checked', option.dataset.reasoningEffort === effectiveEffort ? 'true' : 'false');
    }
  }

  async function setReasoningEffort(value) {
    const previous = reasoningEffort;
    reasoningEffort = normalizeReasoningEffort(value);
    renderReasoningControl();
    closeReasoningOptions({ restoreFocus: true });
    try {
      await window.api.patchSettings({ reasoningEffort });
    } catch (error) {
      reasoningEffort = previous;
      renderReasoningControl();
      console.warn('Failed to save reasoning effort:', error);
    }
  }

  function createStreamMsg() {
    const d = document.createElement('div');
    d.className = 'message';
    d.dataset.streaming = 'true';
    d.innerHTML = `${messageHeaderHtml(true, '解答')}<div class="stream-resume-status hidden" role="status" aria-live="polite"><i aria-hidden="true"></i><span>正在继续完成</span></div><div class="tool-activity hidden" role="status" aria-live="polite"></div><div class="tool-artifacts hidden" aria-label="工具返回的图片"></div><div class="thinking-box hidden"><button class="thinking-header" type="button" aria-expanded="false"><span class="thinking-arrow">▶</span> 正在分析</button><div class="thinking-body"><div class="thinking-body-inner"></div></div></div><div class="msg-body"></div><div class="typing"><div class="dot"></div><div class="dot"></div><div class="dot"></div></div>`;
    return d;
  }

  const TOOL_LABELS = Object.freeze({
    web_search: '联网搜索',
    web_extractor: '网页抓取',
    code_interpreter: '代码解释',
    web_search_image: '图片搜索',
    image_search: '以图搜图'
  });

  function renderStreamTools(session) {
    const container = session.message?.querySelector('.tool-activity');
    if (!container) return;
    const tools = Object.entries(session.tools || {});
    container.classList.toggle('hidden', !tools.length);
    container.innerHTML = tools.map(([name, status]) => {
      const complete = status === 'completed';
      const failed = status === 'failed';
      return `<span class="tool-chip${complete ? ' complete' : ''}${failed ? ' failed' : ''}"><i aria-hidden="true"></i>${esc(TOOL_LABELS[name] || name)}</span>`;
    }).join('');
  }

  function renderStreamArtifacts(session) {
    const container = session.message?.querySelector('.tool-artifacts');
    if (!container) return;
    const images = Array.isArray(session.artifacts) ? session.artifacts.slice(0, 8) : [];
    container.classList.toggle('hidden', !images.length);
    container.innerHTML = images.map(item => `<figure><img src="${esc(item.url)}" alt="${esc(item.title || '搜索图片')}" loading="lazy" referrerpolicy="no-referrer"><figcaption>${esc(item.title || '搜索图片')}</figcaption></figure>`).join('');
    enhancePreviewImages(container);
  }

  function enhancePreviewImages(root) {
    for (const image of root.querySelectorAll('.msg-body img, .tool-artifacts img')) {
      const title = image.alt || image.closest('figure')?.querySelector('figcaption')?.textContent || '图片';
      image.tabIndex = 0;
      image.setAttribute('role', 'button');
      image.setAttribute('aria-haspopup', 'dialog');
      image.setAttribute('aria-label', `打开图片预览：${title}`);
    }
  }

  function viewerImagesFor(sourceImage) {
    const scope = sourceImage.closest('.message') || messagesEl;
    return [...scope.querySelectorAll('.msg-body img, .tool-artifacts img')].map(image => ({
      url: image.currentSrc || image.src,
      title: image.alt || image.closest('figure')?.querySelector('figcaption')?.textContent || '图片预览'
    })).filter(item => /^https:\/\//i.test(item.url));
  }

  function renderImageViewer() {
    const item = imageViewerItems[imageViewerIndex];
    if (!item) return;
    $('#image-viewer-image').src = item.url;
    $('#image-viewer-image').alt = item.title;
    $('#image-viewer-title').textContent = item.title;
    $('#image-viewer-count').textContent = `${imageViewerIndex + 1} / ${imageViewerItems.length}`;
    $('#image-viewer-scale').textContent = `${Math.round(imageViewerZoom * 100)}%`;
    const image = $('#image-viewer-image');
    // 属性赋值覆盖旧回调，快速切图不会堆积 load 监听。
    image.onload = layoutImageViewer;
    requestAnimationFrame(layoutImageViewer);
    $('#btn-image-zoom-out').disabled = imageViewerZoom <= 0.3;
    $('#btn-image-zoom-in').disabled = imageViewerZoom >= 4;
    $('#btn-image-original').href = item.url;
    $('#btn-image-previous').disabled = imageViewerItems.length < 2;
    $('#btn-image-next').disabled = imageViewerItems.length < 2;
  }

  function layoutImageViewer() {
    const image = $('#image-viewer-image');
    const stage = $('#image-viewer-stage');
    const canvas = $('#image-viewer-canvas');
    if (!image?.complete || !image.naturalWidth || !stage || !canvas) return;
    const availableWidth = Math.max(1, stage.clientWidth - 28);
    const availableHeight = Math.max(1, stage.clientHeight - 28);
    const containScale = Math.min(1, availableWidth / image.naturalWidth, availableHeight / image.naturalHeight);
    const width = Math.max(1, Math.round(image.naturalWidth * containScale * imageViewerZoom));
    const height = Math.max(1, Math.round(image.naturalHeight * containScale * imageViewerZoom));
    image.style.width = `${width}px`;
    image.style.height = `${height}px`;
    canvas.style.width = `${Math.max(availableWidth, width)}px`;
    canvas.style.height = `${Math.max(availableHeight, height)}px`;
  }

  function openImageViewer(sourceImage) {
    imageViewerItems = viewerImagesFor(sourceImage);
    if (!imageViewerItems.length) return;
    imageViewerReturnTarget = sourceImage;
    const source = sourceImage.currentSrc || sourceImage.src;
    imageViewerIndex = Math.max(0, imageViewerItems.findIndex(item => item.url === source));
    imageViewerZoom = 1;
    renderImageViewer();
    $('#image-viewer').classList.remove('hidden');
    chatContainer.inert = true;
    $('#btn-close-image-viewer').focus({ preventScroll: true });
  }

  function closeImageViewer({ restoreFocus = true } = {}) {
    if ($('#image-viewer').classList.contains('hidden')) return;
    const returnTarget = imageViewerReturnTarget;
    $('#image-viewer').classList.add('hidden');
    chatContainer.inert = false;
    imageViewerItems = [];
    imageViewerReturnTarget = null;
    if (restoreFocus && returnTarget?.isConnected) {
      requestAnimationFrame(() => returnTarget.focus({ preventScroll: true }));
    }
  }

  function stepImageViewer(direction) {
    if (imageViewerItems.length < 2) return;
    imageViewerIndex = (imageViewerIndex + direction + imageViewerItems.length) % imageViewerItems.length;
    imageViewerZoom = 1;
    renderImageViewer();
  }

  function zoomImageViewer(delta) {
    imageViewerZoom = Math.min(4, Math.max(0.3, Math.round((imageViewerZoom + delta) * 10) / 10));
    renderImageViewer();
  }

  function appendArtifactMarkdown(session) {
    const images = (Array.isArray(session.artifacts) ? session.artifacts : [])
      .filter(item => item?.type === 'image' && /^https:\/\//i.test(item.url) && !session.content.includes(item.url));
    if (!images.length) return;
    const lines = images.slice(0, 8).map(item => {
      const label = String(item.title || '参考图片').replace(/[\[\]]/g, '').slice(0, 80);
      const url = String(item.url).replace(/\(/g, '%28').replace(/\)/g, '%29').replace(/ /g, '%20');
      return `![${label}](${url})`;
    });
    session.content = `${session.content.trimEnd()}\n\n### 参考图片\n\n${lines.join('\n\n')}`.trim();
  }

  function addStreamMsg({ scroll = true } = {}) {
    emptyState?.classList.add('hidden');
    const d = createStreamMsg();
    messagesEl.appendChild(d);
    if (scroll) scrollBottom(true);
    return d;
  }

  function attachActiveStreamToConversation(conversationId) {
    const session = activeStream;
    if (!session || session.finalized || session.convId !== conversationId) return;
    session.message = addStreamMsg({ scroll: false });
    session.renderedContent = null;
    renderStreamFrame(session);
  }

  function detachStreamingSvgBlocks(body, session) {
    const blocks = [...body.querySelectorAll('.svg-block')];
    blocks.forEach((block, index) => {
      const state = session.svgStates[index];
      const svg = block.querySelector('.svg-canvas svg');
      if (state && svg && typeof svg.getCurrentTime === 'function') {
        try { state.currentTime = svg.getCurrentTime(); } catch (error) {}
      }
      block.remove();
    });
    return blocks;
  }

  function restoreStreamingSvgBlocks(body, preservedBlocks, session) {
    const placeholders = [...body.querySelectorAll('.svg-block')];
    placeholders.forEach((placeholder, index) => {
      const preserved = preservedBlocks[index];
      if (!preserved) return;
      const nextSource = placeholder.querySelector('.svg-source')?.textContent || '';
      const source = preserved.querySelector('.svg-source');
      if (source) source.textContent = nextSource;
      placeholder.replaceWith(preserved);

      const state = session.svgStates[index];
      const svg = preserved.querySelector('.svg-canvas svg');
      if (state && svg && Number.isFinite(state.currentTime) && typeof svg.setCurrentTime === 'function') {
        try { svg.setCurrentTime(state.currentTime); } catch (error) {}
      }
    });
    for (const unused of preservedBlocks.slice(placeholders.length)) {
      unobserveSvgAnimations(unused);
    }
  }

  // 长回答每帧全量重解析 Markdown 是 O(n²)。把已稳定的前缀冻结成独立容器，
  // 每帧只重渲染尾部窗口；分割点只允许落在「空行 + 标题/代码围栏」且围栏配平处，
  // 避免拆散列表、表格或代码块。含 SVG 图解的回答走原全量路径，保持动画状态逻辑不变。
  const STREAM_SPLIT_MIN_CONTENT = 8000;
  const STREAM_SPLIT_MIN_ADVANCE = 3000;
  const STREAM_SPLIT_TAIL_WINDOW = 1600;

  function ensureStreamStableSplit(session) {
    const content = session.content;
    if (!session.streamStable || session.streamStable.length > content.length) {
      session.streamStable = { length: 0, html: '' };
    }
    const stable = session.streamStable;
    if (content.length < STREAM_SPLIT_MIN_CONTENT) return stable;
    if (content.length - stable.length < STREAM_SPLIT_MIN_ADVANCE + STREAM_SPLIT_TAIL_WINDOW) return stable;
    const windowEnd = content.length - STREAM_SPLIT_TAIL_WINDOW;
    let candidate = -1;
    for (const pattern of ['\n\n#', '\n\n```']) {
      const found = content.lastIndexOf(pattern, windowEnd);
      if (found > candidate) candidate = found;
    }
    if (candidate <= stable.length) return stable;
    const splitAt = candidate + 2;
    const prefix = content.slice(0, splitAt);
    const fenceCount = (prefix.match(/^(?:```|~~~)/gm) || []).length;
    if (fenceCount % 2 !== 0) return stable;
    stable.length = splitAt;
    stable.html = md(prefix, true);
    return stable;
  }

  function renderStreamFrame(session) {
    if (session.finalized || !session.message.isConnected) return;
    const thinkingBox = session.message.querySelector('.thinking-box');
    const thinkingText = session.message.querySelector('.thinking-body-inner');
    if (session.thinking && session.renderedThinking !== session.thinking && thinkingBox && thinkingText) {
      thinkingBox.classList.remove('hidden');
      thinkingText.textContent = session.thinking;
      session.renderedThinking = session.thinking;
    }

    const body = session.message.querySelector('.msg-body');
    if (body && session.renderedContent !== session.content) {
      session.hasSvgFence ||= session.content.includes('```svg') || Boolean(session.svgStates?.length);
      const stable = session.hasSvgFence ? null : ensureStreamStableSplit(session);
      if (!stable || !stable.length) {
        const preservedSvgBlocks = detachStreamingSvgBlocks(body, session);
        body.innerHTML = md(session.content, true);
        restoreStreamingSvgBlocks(body, preservedSvgBlocks, session);
        enhancePreviewImages(body);
        renderStreamingSvgs(body, session);
      } else {
        let stableEl = body.firstElementChild;
        let tailEl = stableEl?.nextElementSibling;
        if (!stableEl?.classList?.contains('stream-stable') || !tailEl) {
          body.innerHTML = '<div class="stream-stable"></div><div class="stream-tail"></div>';
          stableEl = body.firstElementChild;
          tailEl = body.lastElementChild;
        }
        if (stableEl.dataset.len !== String(stable.length)) {
          stableEl.innerHTML = stable.html;
          stableEl.dataset.len = String(stable.length);
          enhancePreviewImages(stableEl);
        }
        tailEl.innerHTML = md(session.content.slice(stable.length), true);
        enhancePreviewImages(tailEl);
      }
      session.renderedContent = session.content;
    }
    if (autoFollow) scrollBottom();
    else updateScrollButton();
    if (!$('#usage-overlay').classList.contains('hidden')) renderUsage();
  }

  function scheduleStreamRender(session) {
    if (session.finalized || session.renderTimer || session.renderFrame || document.visibilityState === 'hidden') return;
    const streamedChars = session.content.length + session.thinking.length;
    const renderInterval = streamedChars > 40000 ? 220 : (streamedChars > 12000 ? 140 : STREAM_RENDER_INTERVAL);
    const delay = Math.max(0, renderInterval - (performance.now() - session.lastRenderAt));
    session.renderTimer = setTimeout(() => {
      session.renderTimer = 0;
      session.renderFrame = requestAnimationFrame(() => {
        session.renderFrame = 0;
        session.lastRenderAt = performance.now();
        renderStreamFrame(session);
      });
    }, delay);
  }

  function cancelStreamRender(session) {
    if (session.renderTimer) clearTimeout(session.renderTimer);
    if (session.renderFrame) cancelAnimationFrame(session.renderFrame);
    session.renderTimer = 0;
    session.renderFrame = 0;
  }

  function setStreamResumeStatus(session, message = '') {
    const status = session?.message?.querySelector('.stream-resume-status');
    if (!status) return;
    status.classList.toggle('hidden', !message);
    const label = status.querySelector('span');
    if (label && message) label.textContent = message;
  }

  function estimateStreamAttemptUsage(session) {
    const promptTokens = Math.max(0, Number(session?.attemptPromptTokens) || 0);
    const thinking = String(session?.thinking || '').slice(Math.max(0, Number(session?.attemptThinkingStart) || 0));
    const content = String(session?.content || '').slice(Math.max(0, Number(session?.attemptContentStart) || 0));
    const reasoningTokens = estimateTextTokens(thinking);
    const textTokens = estimateTextTokens(content);
    const completionTokens = reasoningTokens + textTokens;
    if (!promptTokens && !completionTokens) return null;
    return normalizeStoredUsage({
      cacheStatsVersion: 2,
      model: normalizeStoredUsage(conversations[session?.convId]?.lastChatUsage).model,
      promptTokens,
      completionTokens,
      totalTokens: promptTokens + completionTokens,
      reasoningTokens,
      textTokens,
      estimatedRequests: 1,
      cacheSupported: false
    });
  }

  function bankStreamAttemptUsage(session) {
    if (!session) return;
    const attemptUsage = session.attemptUsage || estimateStreamAttemptUsage(session);
    if (attemptUsage) {
      session.accumulatedUsage = session.accumulatedUsage
        ? addUsage(session.accumulatedUsage, attemptUsage)
        : normalizeStoredUsage(attemptUsage);
    }
    session.attemptUsage = null;
    session.usage = session.accumulatedUsage || null;
    session.attemptContentStart = session.content.length;
    session.attemptThinkingStart = session.thinking.length;
    session.attemptPromptTokens = 0;
  }

  function buildAutoResumePayload(session) {
    const context = buildChatPayload(session.convId, session.messages);
    const payload = context.messages.map(message => ({ ...message }));
    const partial = session.content.trim();
    if (partial) {
      payload.push({ role: 'assistant', content: partial });
      payload.push({ role: 'user', content: AUTO_RESUME_INSTRUCTION });
    } else {
      const last = payload[payload.length - 1];
      if (last?.role === 'user' && typeof last.content === 'string') {
        payload[payload.length - 1] = { ...last, content: `${last.content}\n\n${AUTO_RESUME_INSTRUCTION}` };
      } else {
        payload.push({ role: 'user', content: AUTO_RESUME_INSTRUCTION });
      }
    }
    return { payload, images: context.images.slice(-4) };
  }

  function canAutoResumeStream(session, details) {
    return Boolean(
      session
      && !session.finalized
      && details?.retryable === true
      && session.resumeAttempts < MAX_AUTO_RESUME_ATTEMPTS
      && !session.queue?.length
      && conversations[session.convId]
    );
  }

  function autoResumeStream(session) {
    if (!session || session.finalized || session.resumeTimer) return;
    bankStreamAttemptUsage(session);
    session.resumeAttempts += 1;
    setStreamResumeStatus(session, '连接波动，正在从中断处继续完成');
    session.resumeTimer = setTimeout(() => {
      session.resumeTimer = 0;
      if (session.finalized || activeStream !== session) return;
      if (session.queue?.length) {
        finishStream(session, { error: '原回答连接中断，已开始处理队列中的新要求' });
        return;
      }
      const continuation = buildAutoResumePayload(session);
      session.requestId = `r_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      session.attemptPromptTokens = estimateMessagesTokens(continuation.payload);
      session.estimatedPromptTokens += session.attemptPromptTokens;
      window.api.startStream(session.requestId, continuation.payload, {
        reasoningEffort: session.reasoningEffort,
        contextImages: continuation.images
      });
    }, AUTO_RESUME_DELAY_MS);
  }

  function appendStreamError(session, message) {
    if (!session.message.isConnected) return;
    const error = document.createElement('div');
    error.className = 'error-msg';
    error.textContent = String(message || '生成失败，请重试');
    session.message.after(error);
    if (autoFollow) scrollBottom();
    else updateScrollButton();
  }

  function renderQueuedMessage() {
    const panel = $('#queued-message');
    const session = activeStream && !activeStream.finalized && activeStream.convId === currentConvId ? activeStream : null;
    const queue = Array.isArray(session?.queue) ? session.queue : [];
    panel.classList.toggle('hidden', !queue.length);
    if (!queue.length) return;
    $('#queued-message-count').textContent = `待发送 ${queue.length} 条`;
    $('#queued-message-preview').textContent = queue.map(item => item.text).join(' · ');
  }

  function enqueueCurrentDraft() {
    const session = activeStream;
    const text = chatInput.value.trim();
    if (!session || session.finalized || session.convId !== currentConvId || !text) return false;
    session.queue ||= [];
    session.queue.push({ text, fromSelection: selectionDraftPending });
    chatInput.value = '';
    selectionDraftPending = false;
    chatInput.style.height = 'auto';
    renderQueuedMessage();
    updateInput();
    return true;
  }

  function queuedContinuationContent(queue) {
    const items = (Array.isArray(queue) ? queue : []).filter(item => String(item?.text || '').trim());
    const additions = items.map((item, index) => items.length > 1
      ? `【补充 ${index + 1}】\n${String(item.text).trim()}`
      : String(item.text).trim()).join('\n\n');
    return `${QUEUED_CONTINUATION_PREFIX}\n\n【用户新增要求】\n${additions}`;
  }

  async function sendQueuedFollowUps(session, queuedItems = null) {
    const conversation = conversations[session?.convId];
    if (!conversation || activeStream) return;
    const queue = Array.isArray(queuedItems)
      ? queuedItems
      : (Array.isArray(session?.queue) ? session.queue.splice(0) : []);
    if (!queue.length) return;
    const message = createMessage('user', queuedContinuationContent(queue));
    conversation.messages ||= [];
    conversation.messages.push(message);
    conversation.questionVideos ||= {};
    conversation.questionVideos[message.id] = normalizeQuestionVideoState();
    if (currentConvId === session.convId) {
      currentMessages = conversation.messages;
      addMsg('user', message.content, { message });
    }
    queueQuestionEligibilityCheck(session.convId, message.id);
    await saveConv(session.convId, conversation.messages);
    renderQueuedMessage();
    sendToAI(session.convId);
  }

  function finishStream(session, { error = '', stopped = false } = {}) {
    if (!session || session.finalized) return Promise.resolve();
    session.finalized = true;
    // 记录「结束时是否还在跟读」：跟读则收尾强制落底，避免收尾重排把视口留在提问处；
    // 用户中途上滑阅读则为 false，不会被强行拽回底部。
    const wasFollowing = autoFollow;
    if (session.resumeTimer) clearTimeout(session.resumeTimer);
    session.resumeTimer = 0;
    cancelStreamRender(session);
    setStreamResumeStatus(session);
    bankStreamAttemptUsage(session);
    appendArtifactMarkdown(session);
    const conversation = conversations[session.convId];
    if (Array.isArray(conversation?.messages) && conversation.messages !== session.messages) {
      session.messages = conversation.messages;
    }
    const queuedHandoff = !stopped && Array.isArray(session.queue) ? session.queue.splice(0) : [];
    if (activeStream === session) activeStream = null;
    isStreaming = Boolean(queuedHandoff.length);

    const message = session.message;
    if (message.isConnected) {
      message.querySelector('.typing')?.remove();
      message.querySelector('.tool-artifacts')?.remove();
      const body = message.querySelector('.msg-body');
      if (body && session.content) {
        unobserveSvgAnimations(body);
        body.innerHTML = md(session.content);
        enhanceRenderedAnswer(body);
      }
      const header = message.querySelector('.thinking-header');
      if (header && session.thinking) {
        header.innerHTML = '<span class="thinking-arrow">▶</span> 思考过程';
      }
      message.removeAttribute('data-streaming');
      // 回答完成后只刷新一次悬浮卡摘要，避免流式期间反复重建轨道。
      syncChatRail();
    }

    // 收尾时整段答案被重新写入并重新测量（content-visibility），高度会跳变一次；
    // 跟读状态下连钉几帧底部，避免视口被留在上方的提问处。
    if (wasFollowing) pinToBottom();

    commitStreamUsage(session);
    if (!$('#usage-overlay').classList.contains('hidden')) renderUsage();
    let saved = Promise.resolve();
    if (session.content) {
      session.messages.push(createMessage('assistant', session.content, session.artifacts));
      if (conversation) conversation.messages = session.messages;
      if (currentConvId === session.convId) currentMessages = session.messages;
      saved = saveConv(session.convId, session.messages);
      if (message.isConnected) {
        renderVisuals(message, session.svgStates).catch(renderError => {
          console.warn('Visual render failed:', renderError);
        }).finally(() => {
          if (message.isConnected && wasFollowing) pinToBottom();
        });
      }
    } else {
      if (!stopped && !error) error = 'AI 未返回内容，请重试';
      if (error) appendStreamError(session, error);
      error = '';
      message.remove();
      if (session.usageCommitted) saved = saveConv(session.convId, session.messages);
    }

    if (error) appendStreamError(session, error);
    if (session.content) {
      saved.then(() => {
        window.api.queueLearningAnalysis(session.convId, session.messages);
        prewarmRollingContextSummary(session.convId, session.messages);
        return maybeAutoSummarize(session.convId, session.messages);
      });
    }
    updateInput();
    if (currentConvId === session.convId && !queuedHandoff.length) chatInput.focus();
    if (queuedHandoff.length) {
      return saved.then(async () => {
        isStreaming = false;
        updateInput();
        await sendQueuedFollowUps(session, queuedHandoff);
      });
    }
    return saved;
  }

  function stopStream() {
    const session = activeStream;
    if (!session) return Promise.resolve();
    window.api.stopStream(session.requestId);
    return finishStream(session, { stopped: true });
  }

  // 切换任务前停止旧流时，把已排队的追问写回原会话，避免静默丢失。
  async function stopStreamPreservingQueue() {
    const session = activeStream;
    if (!session) return;
    const queued = Array.isArray(session.queue) ? session.queue.splice(0) : [];
    await stopStream();
    const conversation = conversations[session.convId];
    if (!queued.length || !conversation) return;
    const message = createMessage('user', queuedContinuationContent(queued));
    conversation.messages ||= [];
    conversation.messages.push(message);
    conversation.questionVideos ||= {};
    conversation.questionVideos[message.id] = normalizeQuestionVideoState();
    if (currentConvId === session.convId) {
      currentMessages = conversation.messages;
      addMsg('user', message.content, { message });
      renderQueuedMessage();
    }
    await saveConv(session.convId, conversation.messages);
  }

  async function interruptStreamAndSendQueue() {
    const session = activeStream;
    if (!session || session.finalized || session.convId !== currentConvId) return;
    enqueueCurrentDraft();
    const shouldContinue = Boolean(session.queue?.length);
    await stopStream();
    if (shouldContinue) await sendQueuedFollowUps(session);
  }

  function hideWindowAndStop() {
    if (activeStream?.queue?.length && activeStream.convId === currentConvId) {
      const queuedDraft = activeStream.queue.map(item => item.text).join('\n\n');
      chatInput.value = chatInput.value.trim() ? `${queuedDraft}\n\n${chatInput.value.trim()}` : queuedDraft;
      activeStream.queue.length = 0;
    }
    if (activeStream) stopStream();
    closeVideoWorkspace();
    window.api.hideWindow();
  }

  async function quitApplication() {
    if (activeStream?.queue?.length && activeStream.convId === currentConvId) {
      const queuedDraft = activeStream.queue.map(item => item.text).join('\n\n');
      chatInput.value = chatInput.value.trim() ? `${queuedDraft}\n\n${chatInput.value.trim()}` : queuedDraft;
      activeStream.queue.length = 0;
    }
    try {
      if (activeStream) await stopStream();
    } finally {
      closeVideoWorkspace();
      window.api.quitApp();
    }
  }

  // ===== Streaming =====

  async function sendToAI(conversationId = currentConvId) {
    const conversation = conversations[conversationId];
    const messages = Array.isArray(conversation?.messages) ? conversation.messages : null;
    if (isStreaming || !conversationId || !messages) return;
    isStreaming = true;
    updateInput();
    let compressed;
    let context;
    try {
      compressed = await ensureRollingContextSummary(conversationId, messages);
      context = buildChatPayload(conversationId, messages, compressed ? null : { compressionThreshold: 0.99 });
    } catch (error) {
      isStreaming = false;
      updateInput();
      showAppError(error?.message || '上下文整理失败，请重试');
      return;
    }
    if (!conversations[conversationId]) {
      isStreaming = false;
      updateInput();
      return;
    }
    const payload = context.messages;
    activeStream = {
      requestId: `r_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
      convId: conversationId,
      messages,
      message: currentConvId === conversationId ? addStreamMsg() : createStreamMsg(),
      content: '',
      thinking: '',
      queue: [],
      tools: {},
      artifacts: [],
      renderedContent: null,
      renderedThinking: null,
      svgStates: [],
      lastRenderAt: 0,
      renderTimer: 0,
      renderFrame: 0,
      finalized: false,
      reasoningEffort: effectiveReasoningEffort(),
      usage: null,
      usageCommitted: false,
      contextStats: context.stats,
      estimatedPromptTokens: estimateMessagesTokens(payload),
      attemptPromptTokens: estimateMessagesTokens(payload),
      attemptContentStart: 0,
      attemptThinkingStart: 0,
      attemptUsage: null,
      accumulatedUsage: null,
      resumeAttempts: 0,
      resumeTimer: 0
    };
    updateInput();
    window.api.startStream(activeStream.requestId, payload, {
      reasoningEffort: activeStream.reasoningEffort,
      contextImages: context.images.slice(-4)
    });
  }

  // Preload replaces listeners per channel. Binding once keeps stream lifecycle
  // ownership here and prevents callbacks from closing over a later conversation.
  window.api.onThinking((requestId, chunk) => {
    const session = activeStream;
    if (!session || session.finalized || session.requestId !== requestId) return;
    session.thinking += String(chunk || '');
    setStreamResumeStatus(session);
    scheduleStreamRender(session);
  });
  window.api.onChunk((requestId, chunk) => {
    const session = activeStream;
    if (!session || session.finalized || session.requestId !== requestId) return;
    session.content += String(chunk || '');
    setStreamResumeStatus(session);
    scheduleStreamRender(session);
  });
  window.api.onTool((requestId, tool) => {
    const session = activeStream;
    if (!session || session.finalized || session.requestId !== requestId || !tool?.name) return;
    session.tools[tool.name] = String(tool.status || 'in_progress');
    setStreamResumeStatus(session);
    renderStreamTools(session);
  });
  window.api.onArtifacts((requestId, artifacts) => {
    const session = activeStream;
    if (!session || session.finalized || session.requestId !== requestId || !Array.isArray(artifacts)) return;
    const seen = new Set(session.artifacts.map(item => item.url));
    setStreamResumeStatus(session);
    for (const artifact of artifacts) {
      const url = String(artifact?.url || '');
      if (artifact?.type !== 'image' || !/^https:\/\//i.test(url) || url.length > 2048 || seen.has(url)) continue;
      session.artifacts.push({ type: 'image', url, title: String(artifact.title || '搜索图片').slice(0, 120) });
      seen.add(url);
      if (session.artifacts.length >= 8) break;
    }
    renderStreamArtifacts(session);
  });
  window.api.onUsage((requestId, usage) => {
    const session = activeStream;
    if (!session || session.finalized || session.requestId !== requestId) return;
    session.attemptUsage = normalizeStoredUsage(usage);
    session.usage = session.accumulatedUsage
      ? addUsage(session.accumulatedUsage, session.attemptUsage)
      : session.attemptUsage;
    if (!$('#usage-overlay').classList.contains('hidden')) renderUsage();
  });
  window.api.onDone(requestId => {
    if (activeStream?.requestId === requestId) finishStream(activeStream);
  });
  window.api.onError((requestId, error, details) => {
    const session = activeStream;
    if (session?.requestId !== requestId) return;
    if (canAutoResumeStream(session, details)) {
      autoResumeStream(session);
      return;
    }
    const finalError = session.resumeAttempts > 0 ? `自动续接失败：${error}` : error;
    finishStream(session, { error: finalError });
  });

  function updateInput({ refreshMessageActions = true } = {}) {
    const sendButton = $('#btn-send');
    const activeHere = Boolean(activeStream && !activeStream.finalized && activeStream.convId === currentConvId);
    const hasDraft = Boolean(chatInput.value.trim());
    const hasQueue = Boolean(activeHere && activeStream.queue?.length);
    sendButton.disabled = isStreaming ? !activeHere : !hasDraft;
    sendButton.classList.toggle('is-stopping', activeHere && !hasDraft);
    sendButton.classList.toggle('is-queueing', activeHere && hasDraft);
    sendButton.title = activeHere
      ? (hasDraft ? '加入任务队列' : (hasQueue ? '打断并发送队列' : '停止生成'))
      : (isStreaming ? '另一对话正在生成' : '发送');
    sendButton.setAttribute('aria-label', sendButton.title);
    chatInput.disabled = isStreaming && !activeHere;
    chatInput.placeholder = activeHere
      ? '输入补充，发送后进入队列…'
      : (isStreaming ? '另一对话正在生成…' : (currentConvId ? '继续追问…' : '输入或粘贴题目…'));
    if (refreshMessageActions) {
      updateVideoTrigger();
      updateMessageDeleteActions();
    }
    renderQueuedMessage();
    renderReasoningControl();
    updateContextMeter();
  }

  // ===== New Query =====

  async function startQuery(text, fromSelection = false) {
    if (isStreaming) await stopStreamPreservingQueue();
    text = String(text || '').trim();
    if (!text) return;
    if (text.length > MAX_CHAT_INPUT_CHARS) {
      showAppError(`输入不能超过 ${MAX_CHAT_INPUT_CHARS} 个字符`);
      return;
    }
    currentConvId = genId();
    currentMessages = [
      createMessage('system', SYSTEM_PROMPT),
      createMessage('user', `${INITIAL_TASK_PREFIX}\n\n${fromSelection ? '【浏览器当前选区】' : '【用户输入】'}\n${text}`)
    ];
    const autoSummary = summarizeConversation(currentMessages);
    const initialVideo = normalizeConversationVideo(text);
    conversations[currentConvId] = {
      schemaVersion: 3,
      title: autoSummary.title,
      summary: autoSummary.summary,
      messages: currentMessages,
      usage: normalizeStoredUsage(),
      questionVideos: {
        [currentMessages[1].id]: normalizeQuestionVideoState({
          video: initialVideo,
          query: initialVideo ? window.BilibiliVideo.buildVideoSearchQuery(text) : '',
          attemptedAt: initialVideo ? Date.now() : 0
        })
      },
      updatedAt: Date.now()
    };
    clearMessages();
    addMsg('user', currentMessages[1].content, { message: currentMessages[1] });
    chatInput.value = '';
    selectionDraftPending = false;
    chatInput.style.height = 'auto';
    try {
      await saveConv(currentConvId, currentMessages, { throwOnError: true });
    } catch (error) {
      updateInput();
      return;
    }
    queueQuestionEligibilityCheck(currentConvId, currentMessages[1].id);
    updateVideoTrigger();
    sendToAI();
  }

  function openConv(id) {
    const c = conversations[id];
    if (!c || typeof c !== 'object') return;
    const needsMigration = Number(c.schemaVersion) !== 3
      || (Array.isArray(c.messages) && c.messages.some(message => !message?.id));
    if (!$('#video-workspace').classList.contains('hidden')) closeVideoWorkspace();
    currentConvId = id;
    activeVideoQuestionId = '';
    const normalizedMessages = Array.isArray(c.messages)
      ? c.messages
        .filter(message => message && ['system', 'user', 'assistant'].includes(message.role))
        .map((message, index) => normalizeMessage(message, index, id))
      : [];
    const streamSession = activeStream && !activeStream.finalized && activeStream.convId === id ? activeStream : null;
    if (streamSession && Array.isArray(streamSession.messages)) {
      streamSession.messages.splice(0, streamSession.messages.length, ...normalizedMessages);
      currentMessages = streamSession.messages;
    } else {
      currentMessages = normalizedMessages;
    }
    const systemMessage = currentMessages.find(message => message.role === 'system');
    if (systemMessage) systemMessage.content = SYSTEM_PROMPT;
    else currentMessages.unshift(createMessage('system', SYSTEM_PROMPT));
    c.messages = currentMessages;
    c.questionVideos = normalizeQuestionVideos(c, currentMessages);
    clearMessages();
    pendingMarkdownBodies.clear();
    const fragment = document.createDocumentFragment();
    const eagerFrom = Math.max(0, currentMessages.length - 12);
    currentMessages.forEach((m, index) => {
      if (m.role === 'system') return;
      addMsg(m.role, m.content, {
        target: fragment,
        render: false,
        scroll: false,
        message: m,
        animate: false,
        deferMarkdown: index < eagerFrom
      });
    });
    messagesEl.appendChild(fragment);
    upgradeDeferredMarkdown();
    syncChatRail();
    attachActiveStreamToConversation(id);
    scrollBottom(true);
    renderVisuals(messagesEl).catch(error => {
      console.warn('History visual render failed:', error);
    }).finally(() => {
      if (autoFollow) scrollBottom();
    });
    hideOverlays();
    updateInput();
    updateVideoTrigger();
    if (needsMigration) saveConv(id, currentMessages, { touch: false });
  }

  async function newConversation() {
    if (!$('#video-workspace').classList.contains('hidden')) closeVideoWorkspace();
    closeImageViewer({ restoreFocus: false });
    currentConvId = null;
    currentMessages = [];
    activeVideoQuestionId = '';
    selectionDraftPending = false;
    chatInput.value = '';
    chatInput.style.height = 'auto';
    hideOverlays();
    renderEmptyState();
    updateInput();
    updateVideoTrigger();
    chatInput.focus();
  }

  async function deleteConv(id) {
    if (!id || !conversations[id]) return;
    if (activeStream?.convId === id) await stopStream();
    if (summaryQueues.has(id)) window.api.cancelSummary(id);
    for (const [key, videoSearch] of videoSearchStates) {
      if (!key.startsWith(`${id}:`)) continue;
      window.api.cancelBilibiliVideoSearch(videoSearch.token);
      videoSearchStates.delete(key);
    }
    await (saveQueues.get(id) || Promise.resolve());
    try {
      await window.api.deleteConversation(id);
    } catch (error) {
      console.error('Failed to delete conversation:', error);
      return;
    }
    delete conversations[id];
    if (currentConvId === id) {
      currentConvId = null;
      currentMessages = [];
      renderEmptyState();
      updateInput();
      closeVideoWorkspace();
      updateVideoTrigger();
    }
    renderHistory();
  }

  async function deleteMessage(messageId) {
    const conversationId = currentConvId;
    const conversation = conversations[conversationId];
    const index = currentMessages.findIndex(message => message.id === messageId && message.role !== 'system');
    if (!conversationId || !conversation || index < 0) return;
    const activeUserId = activeStream && !activeStream.finalized && activeStream.convId === conversationId
      ? lastUserMessageId(activeStream.messages)
      : '';
    if (messageId === activeUserId) return;

    const [removed] = currentMessages.splice(index, 1);
    // 摘要游标之前的消息被删除后，游标必须回退，否则未摘要的消息会被当作已覆盖而丢出上下文。
    const summaryCursor = Math.max(0, Number(conversation.summaryMessageCount) || 0);
    if (index < summaryCursor) conversation.summaryMessageCount = index;
    if (removed.role === 'user') {
      const searchKey = videoSearchKey(conversationId, messageId);
      const search = videoSearchStates.get(searchKey);
      if (search) window.api.cancelBilibiliVideoSearch(search.token);
      videoSearchStates.delete(searchKey);
      delete conversation.questionVideos?.[messageId];
      if (activeVideoQuestionId === messageId) {
        activeVideoQuestionId = '';
        closeVideoWorkspace();
      }
    }

    const messageElement = document.querySelector(`.message[data-message-id="${CSS.escape(messageId)}"]`);
    if (messageElement) {
      unobserveSvgAnimations(messageElement);
      messageElement._collapseCleanup?.();
      messageElement.remove();
    }
    conversation.messages = currentMessages;
    await saveConv(conversationId, currentMessages);
    if (!currentMessages.some(message => message.role !== 'system')) {
      renderEmptyState();
    } else {
      updateVideoTrigger();
      updateMessageDeleteActions();
      updateScrollButton();
    }
    syncChatRail();
    if (!$('#history-overlay').classList.contains('hidden')) renderHistory();
  }

  async function sendFollowUp(text, fromSelection = false) {
    const value = String(text || '').trim();
    if (!value || isStreaming) return;
    if (value.length > MAX_CHAT_INPUT_CHARS) {
      showAppError(`输入不能超过 ${MAX_CHAT_INPUT_CHARS} 个字符`);
      return;
    }
    if (!currentConvId) {
      await startQuery(value, fromSelection);
      return;
    }
    const message = createMessage('user', fromSelection ? `【浏览器当前选区】\n${value}` : value);
    currentMessages.push(message);
    conversations[currentConvId].questionVideos ||= {};
    conversations[currentConvId].questionVideos[message.id] = normalizeQuestionVideoState();
    addMsg('user', message.content, { message });
    chatInput.value = '';
    selectionDraftPending = false;
    chatInput.style.height = 'auto';
    try {
      await saveConv(currentConvId, currentMessages, { throwOnError: true });
    } catch (error) {
      updateInput();
      return;
    }
    queueQuestionEligibilityCheck(currentConvId, message.id);
    sendToAI();
  }

  async function handleSelectedText(text) {
    const value = String(text || '').trim();
    if (!value) return;
    if (isStreaming) await stopStreamPreservingQueue();
    if (currentConvId) {
      await sendFollowUp(value, true);
    } else {
      await startQuery(value, true);
    }
  }

  async function placeSelectionDraft(text) {
    const value = String(text || '').trim();
    if (!value) return;
    const existing = chatInput.value.trim();
    chatInput.value = existing ? `${existing}\n\n${value}` : value;
    selectionDraftPending = true;
    chatInput.style.height = 'auto';
    chatInput.style.height = `${Math.min(chatInput.scrollHeight, 100)}px`;
    hideOverlays();
    updateInput();
    chatInput.focus();
    chatInput.setSelectionRange(chatInput.value.length, chatInput.value.length);
  }

  // ===== History =====

  function renderHistory() {
    const list = $('#history-list');
    const sorted = Object.entries(conversations)
      .filter(([, conversation]) => conversation && typeof conversation === 'object')
      .sort((a, b) => (Number(b[1].updatedAt) || 0) - (Number(a[1].updatedAt) || 0));
    if (!sorted.length) {
      list.innerHTML = `<div class="hist-empty"><span class="hist-empty-mark" aria-hidden="true"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 7v5l3 2" stroke-linecap="round" stroke-linejoin="round"/><circle cx="12" cy="12" r="8"/></svg></span><strong>暂无历史对话</strong><span>完成一次对话后会显示在这里</span></div>`;
      return;
    }
    list.innerHTML = sorted.map(([id, c]) => {
      const t = c.updatedAt ? new Date(c.updatedAt).toLocaleString('zh-CN', { month:'short', day:'numeric', hour:'2-digit', minute:'2-digit' }) : '';
      const autoSummary = (!c.title || !c.summary) ? summarizeConversation(c.messages) : null;
      const title = c.title || autoSummary.title;
      const summary = c.summary || autoSummary.summary;
      const summaryMark = c.aiSummary ? '<span class="hist-summary-mark">AI</span>' : '';
      return `<article class="hist-item"><button class="hist-open" type="button" data-id="${esc(id)}" aria-label="打开对话 ${esc(title)}"><span class="hist-info"><span class="hist-title">${esc(title)}</span><span class="hist-summary">${summaryMark}${esc(summary)}</span><span class="hist-time">${t}</span></span></button><button class="tb-btn hist-del" type="button" data-id="${esc(id)}" title="删除对话" aria-label="删除对话"><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 7h16M9 7V4h6v3m3 0-1 13H7L6 7m4 4v5m4-5v5" stroke-linecap="round" stroke-linejoin="round"/></svg></button></article>`;
    }).join('');
  }

  function usageForScope(scope = usageScope) {
    if (scope === 'current') return normalizeStoredUsage(conversations[currentConvId]?.usage);
    return Object.values(conversations).reduce(
      (total, conversation) => addUsage(total, conversation?.usage),
      normalizeStoredUsage()
    );
  }

  function renderUsage() {
    let usage = usageForScope();
    let liveUsage = null;
    if (usageScope === 'current' && activeStream?.convId === currentConvId && !activeStream.usageCommitted) {
      liveUsage = activeStream.usage || estimateSessionUsage(activeStream);
      usage = addUsage(usage, liveUsage);
    }
    const containsEstimate = usage.estimatedRequests > 0;
    const approximate = containsEstimate ? '≈' : '';
    $('#usage-prompt').textContent = `${approximate}${numberFormatter.format(usage.promptTokens)}`;
    $('#usage-completion').textContent = `${approximate}${numberFormatter.format(usage.completionTokens)}`;
    $('#usage-total').textContent = `${approximate}${numberFormatter.format(usage.totalTokens)}`;
    $('#usage-tools').textContent = numberFormatter.format(usage.toolCalls);
    $('#usage-tools').title = Object.entries(usage.toolUsage)
      .map(([name, count]) => `${name}: ${numberFormatter.format(count)}`)
      .join('\n') || '尚未调用模型工具';
    $('#usage-model').textContent = usage.model || '尚未请求';
    const quality = $('#usage-data-quality');
    quality.textContent = liveUsage?.estimatedRequests
      ? '最近模型 · 实时估算'
      : (containsEstimate ? `最近模型 · 含 ${numberFormatter.format(usage.estimatedRequests)} 次中断估算` : '最近模型 · 精确统计');
    quality.classList.toggle('estimated', containsEstimate);

    const cached = $('#usage-cached');
    const rate = $('#usage-cache-rate');
    const fill = $('#usage-cache-fill');
    const note = $('#usage-cache-note');
    const lastUsage = usageScope === 'current'
      ? normalizeStoredUsage(liveUsage || conversations[currentConvId]?.lastChatUsage)
      : null;
    if (!usage.cacheSupported) {
      cached.textContent = '—';
      rate.textContent = '—';
      fill.style.width = '0%';
      note.textContent = lastUsage?.estimatedRequests
        ? 'Token 正在估算；缓存命中只能等待最后一个 usage 包确认'
        : '服务端返回缓存明细后显示';
      return;
    }
    const trackedPromptTokens = usage.cacheTrackedPromptTokens;
    const ratio = trackedPromptTokens > 0
      ? Math.min(100, Math.max(0, usage.cachedTokens / trackedPromptTokens * 100))
      : 0;
    cached.textContent = numberFormatter.format(usage.cachedTokens);
    rate.textContent = `${ratio.toFixed(ratio >= 10 ? 1 : 2)}%`;
    fill.style.width = `${ratio}%`;
    if (lastUsage?.estimatedRequests) {
      note.textContent = liveUsage
        ? '当前请求尚未返回最终 usage；缓存率暂不加入累计统计'
        : '最近请求中断，缓存字段未返回；累计缓存率仅统计完整请求';
    } else if (lastUsage?.cacheSupported && lastUsage.cachedTokens > 0) {
      const lastRatio = lastUsage.cacheTrackedPromptTokens > 0
        ? lastUsage.cachedTokens / lastUsage.cacheTrackedPromptTokens * 100
        : 0;
      note.textContent = `最近请求实际命中 ${numberFormatter.format(lastUsage.cachedTokens)} / ${numberFormatter.format(lastUsage.cacheTrackedPromptTokens)} Token（${lastRatio.toFixed(1)}%）`;
    } else if (lastUsage?.cacheSupported && lastUsage.cacheCreationTokens > 0) {
      note.textContent = `最近请求创建 ${numberFormatter.format(lastUsage.cacheCreationTokens)} 个缓存 Token；创建不计作命中`;
    } else if (lastUsage?.cacheSupported) {
      note.textContent = '最近请求实际命中 0 Token；尚未形成可复用的完整前缀或缓存已过期时属于正常结果';
    } else if (usage.cachedTokens > 0) {
      note.textContent = `累计实际命中 ${numberFormatter.format(usage.cachedTokens)} / ${numberFormatter.format(trackedPromptTokens)} 个可统计输入 Token`;
    } else if (usage.cacheCreationTokens > 0) {
      note.textContent = `累计创建 ${numberFormatter.format(usage.cacheCreationTokens)} 个缓存 Token，创建不计作命中`;
    } else {
      note.textContent = '接口已返回缓存明细，但尚未产生实际命中';
    }
  }

  function setUsageScope(scope) {
    usageScope = scope === 'all' ? 'all' : 'current';
    for (const button of document.querySelectorAll('.usage-scope')) {
      const active = button.dataset.scope === usageScope;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', active ? 'true' : 'false');
      button.tabIndex = active ? 0 : -1;
      if (active) $('#usage-panel').setAttribute('aria-labelledby', button.id);
    }
    renderUsage();
  }

  function closeModelOptions() {
    $('#model-options').classList.add('hidden');
    $('#s-model').setAttribute('aria-expanded', 'false');
  }

  function renderModelOptions(query = '') {
    const list = $('#model-options');
    const needle = String(query || '').trim().toLowerCase();
    const matches = availableModels.filter(model => model.toLowerCase().includes(needle)).slice(0, 80);
    if (!availableModels.length) {
      closeModelOptions();
      return;
    }
    if (!matches.length) {
      list.innerHTML = '<div class="model-empty">没有匹配，可直接输入</div>';
    } else {
      const selected = $('#s-model').value.trim();
      list.innerHTML = matches.map(model => `<button class="model-option" type="button" role="option" aria-selected="${model === selected ? 'true' : 'false'}" data-model="${esc(model)}">${esc(model)}</button>`).join('');
    }
    list.classList.remove('hidden');
    $('#s-model').setAttribute('aria-expanded', 'true');
  }

  async function refreshModels({ quiet = false } = {}) {
    const refreshButton = $('#btn-refresh-models');
    const status = $('#model-status');
    const draft = {
      activeProvider: settingsDraft?.activeProvider,
      apiBase: $('#s-base').value.trim(),
      apiKey: $('#s-key').value.trim(),
      model: $('#s-model').value.trim(),
      discoverBaseUrl: true
    };
    if (!draft.apiKey) {
      status.textContent = '请先填写 API Key';
      status.classList.add('error');
      return;
    }
    refreshButton.disabled = true;
    refreshButton.classList.add('loading');
    status.classList.remove('error');
    status.textContent = '正在获取模型列表…';
    try {
      const result = await window.api.listModels(draft);
      availableModels = Array.isArray(result) ? result.map(String) : (Array.isArray(result?.models) ? result.models.map(String) : []);
      if (result?.apiBase && result.apiBase !== draft.apiBase) {
        $('#s-base').value = result.apiBase;
        status.textContent = `已识别 ${result.apiBase}，获取 ${availableModels.length} 个模型`;
      } else {
        status.textContent = `已获取 ${availableModels.length} 个模型，可搜索后直接选择`;
      }
      if (!quiet) renderModelOptions('');
    } catch (error) {
      availableModels = [];
      status.textContent = error?.message || '获取模型列表失败，仍可手动输入模型';
      status.classList.add('error');
      closeModelOptions();
    } finally {
      refreshButton.disabled = false;
      refreshButton.classList.remove('loading');
    }
  }

  // ===== Learning center =====

  function learningItem(itemId) {
    return learningDashboard?.items?.find(item => item.id === itemId) || null;
  }

  function learningPercent(value) {
    return `${Math.round(Math.max(0, Math.min(100, Number(value) || 0)))}%`;
  }

  function formatLearningDate(timestamp) {
    if (!Number(timestamp)) return '待安排';
    return new Date(Number(timestamp)).toLocaleDateString('zh-CN', { month: 'short', day: 'numeric' });
  }

  function learningBadge(item) {
    return `<span class="learning-state" data-state="${esc(item.mastery.state)}">${esc(item.mastery.state)}</span>`;
  }

  function learningCategory(item) {
    const path = (Array.isArray(item?.knowledgePath) ? item.knowledgePath : []).map(value => String(value || '').trim()).filter(Boolean);
    return path[1] || path[0] || (item?.kind === 'knowledge' ? '基础知识' : '未分类');
  }

  function learningLinkedLeetcodeQuestion(item) {
    const canonical = String(item?.canonicalKey || '').toLocaleLowerCase('en-US');
    const normalizedTitle = String(item?.title || '').replace(/[（(].*?[）)]/g, '').trim();
    return leetcodeDashboard?.questions?.find(entry => entry.titleSlug === canonical
      || entry.translatedTitle === item?.title
      || entry.translatedTitle === normalizedTitle);
  }

  function learningItemDifficulty(item) {
    const question = learningLinkedLeetcodeQuestion(item);
    return question ? leetcodeDifficultyLabel(question.difficulty) : '';
  }

  function learningItemRow(item, { plan = false } = {}) {
    const category = learningCategory(item);
    return `<button class="learning-item-row" type="button" data-learning-item="${esc(item.id)}">
      <span class="learning-item-kind" data-kind="${esc(item.kind)}">${item.kind === 'knowledge' ? '知识' : '题目'}</span>
      <span class="learning-item-copy"><strong>${esc(item.title)}</strong><span class="learning-item-category">${esc(category)}</span></span>
      <span class="learning-item-meta">${plan && item.review.overdue ? '<em>到期</em>' : learningBadge(item)}<i><b style="width:${learningPercent(item.mastery.effectiveScore)}"></b></i></span>
    </button>`;
  }

  function renderLearningToday() {
    const dashboard = learningDashboard;
    const content = $('#learning-content');
    if (!dashboard) {
      content.innerHTML = '<div class="learning-loading"><span></span><strong>正在读取学习档案</strong></div>';
      return;
    }
    const planItems = dashboard.plan.reviewItems.map(learningItem).filter(Boolean);
    const newProgress = dashboard.plan.newTarget
      ? Math.min(100, dashboard.plan.newCompleted / dashboard.plan.newTarget * 100)
      : 100;
    const reviewProgress = dashboard.plan.reviewTarget
      ? Math.min(100, dashboard.plan.reviewCompleted / dashboard.plan.reviewTarget * 100)
      : 100;
    const remaining = Math.max(0, dashboard.plan.newTarget - dashboard.plan.newCompleted);
    const reviewRemaining = Math.max(0, dashboard.plan.reviewTarget - dashboard.plan.reviewCompleted);
    const statusLine = remaining === 0 && reviewRemaining === 0
      ? '今日计划已全部完成'
      : remaining > 0 ? `还差 ${remaining} 道新题完成今日目标` : `复习还剩 ${reviewRemaining} 项`;
    content.innerHTML = `<div class="learning-today">
      <section class="learning-day-band">
        <div class="learning-day-copy"><span>${dashboard.plan.isWeeklyReviewDay ? '集中复习日' : '今日学习'}</span><strong><b data-count-up="${dashboard.plan.newCompleted}">${dashboard.plan.newCompleted}</b><small> / ${dashboard.plan.newTarget} 新题</small></strong><p>${statusLine}</p></div>
        <div class="learning-rings" aria-label="今日计划进度">
          <div style="--progress:0" data-progress="${newProgress}" title="新题完成 ${Math.round(newProgress)}%"><span>新题</span><strong>${Math.round(newProgress)}%</strong></div>
          <div style="--progress:0" data-progress="${reviewProgress}" title="复习完成 ${Math.round(reviewProgress)}%"><span>复习</span><strong>${Math.round(reviewProgress)}%</strong></div>
        </div>
        <button class="learning-settings-button" type="button" data-learning-action="settings" title="调整学习计划" aria-label="调整学习计划"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.9"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.6-2-3.4-2.5 1a7 7 0 0 0-1.7-1L14.3 3h-4.6L9.3 6a7 7 0 0 0-1.7 1L5 6 3 9.4 5.1 11a7 7 0 0 0 0 2L3 14.6 5 18l2.6-1a7 7 0 0 0 1.7 1l.4 3h4.6l.4-3a7 7 0 0 0 1.7-1l2.6 1 2-3.4-2.1-1.6a7 7 0 0 0 .1-1Z" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
      </section>
      <section class="learning-stat-strip" aria-label="学习概览">
        <div><strong data-count-up="${dashboard.stats.total}">${dashboard.stats.total}</strong><span>学习项</span></div>
        <div><strong data-count-up="${dashboard.stats.mastered}">${dashboard.stats.mastered}</strong><span>已掌握</span></div>
        <div><strong data-count-up="${dashboard.stats.weak}">${dashboard.stats.weak}</strong><span>待巩固</span></div>
        <div class="${dashboard.stats.due ? 'is-accent' : ''}"><strong data-count-up="${dashboard.stats.due}">${dashboard.stats.due}</strong><span>已到期</span></div>
      </section>
      <section class="learning-plan-section">
        <header><div><strong>${dashboard.plan.isWeeklyReviewDay ? '本周复习队列' : '零散复习'}</strong><span>${planItems.length ? `${planItems.length} 项` : '当前没有到期内容'}</span></div></header>
        <div class="learning-plan-list">${planItems.length
          ? planItems.map(item => learningItemRow(item, { plan: true })).join('')
          : '<div class="learning-plan-empty"><span>✓</span><strong>复习队列已完成</strong></div>'}</div>
      </section>
    </div>`;
    requestAnimationFrame(() => {
      for (const ring of content.querySelectorAll('.learning-rings > div')) {
        ring.style.setProperty('--progress', ring.dataset.progress || 0);
      }
      if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
      for (const el of content.querySelectorAll('[data-count-up]')) {
        const target = Number(el.dataset.countUp) || 0;
        if (!target) continue;
        const duration = 700;
        const start = performance.now();
        const tick = now => {
          const t = Math.min(1, (now - start) / duration);
          el.textContent = String(Math.round(target * (1 - (1 - t) ** 3)));
          if (t < 1) requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      }
    });
  }

  function learningLibraryFilteredItems(dashboard) {
    const query = learningQuery.trim().toLocaleLowerCase('zh-CN');
    const selectedPath = learningPath ? learningPath.split(' / ') : [];
    return dashboard.items.filter(item => {
      const matchesQuery = !query || [item.title, item.question, item.diagnosis, ...item.labels, ...(item.knowledgePath || [])]
        .some(value => String(value || '').toLocaleLowerCase('zh-CN').includes(query));
      const matchesPath = !selectedPath.length || selectedPath.every((part, index) => item.knowledgePath?.[index] === part);
      return matchesQuery && matchesPath;
    });
  }

  function learningLibraryListHtml(items) {
    if (!items.length) return '<div class="learning-library-empty">没有符合条件的题目</div>';
    const groups = new Map();
    for (const item of items) {
      const category = learningCategory(item);
      if (!groups.has(category)) groups.set(category, []);
      groups.get(category).push(item);
    }
    return [...groups.entries()].map(([category, groupItems]) => `<section class="learning-question-group">
      <header><strong>${esc(category)}</strong><span>${groupItems.length} 题</span></header>
      <div>${groupItems.map(item => {
        const leetcodeQuestion = learningLinkedLeetcodeQuestion(item);
        const difficulty = learningItemDifficulty(item);
        const score = Math.round(Number(item.mastery?.effectiveScore ?? item.mastery?.score) || 0);
        const due = Boolean(item.review?.overdue || (Number(item.review?.card?.due) > 0 && Number(item.review.card.due) <= Date.now()));
        const status = leetcodeQuestion?.status || (score > 0 ? 'TRIED' : 'TO_DO');
        const icon = status === 'SOLVED' ? '<path d="m7 12 3 3 7-7" stroke-linecap="round" stroke-linejoin="round"/><circle cx="12" cy="12" r="9"/>' : status === 'TRIED' ? '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2.3" fill="currentColor" stroke="none"/>' : '<circle cx="12" cy="12" r="9"/>';
        return `<button class="learning-question-row" type="button" data-learning-item="${esc(item.id)}" data-status="${status}" data-review="${due && status === 'SOLVED' ? 'due' : 'current'}">
          <i aria-hidden="true"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2">${icon}</svg></i>
          <strong>${esc(item.title)}</strong>
          <span class="${difficulty ? `difficulty-${difficulty === '简单' ? 'easy' : difficulty === '困难' ? 'hard' : 'medium'}` : ''}">${esc(difficulty || (due ? '待复习' : score >= 70 ? '熟练' : '学习中'))}</span>
        </button>`;
      }).join('')}</div>
    </section>`).join('');
  }

  function renderLearningLibrary() {
    const dashboard = learningDashboard;
    const content = $('#learning-content');
    if (!dashboard) return renderLearningToday();
    const problemItems = dashboard.items.filter(item => item.kind === 'problem');
    const categoryCounts = new Map();
    for (const item of problemItems) {
      const category = learningCategory(item);
      const path = (item.knowledgePath || []).slice(0, 2).join(' / ') || category;
      const entry = categoryCounts.get(path) || { category, count: 0 };
      entry.count += 1;
      categoryCounts.set(path, entry);
    }
    const categories = [...categoryCounts.entries()];
    const items = learningLibraryFilteredItems({ ...dashboard, items: problemItems });
    content.innerHTML = `<div class="learning-library">
      <div class="learning-filter-bar">
        <label><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="m16 16 4 4" stroke-linecap="round"/></svg><input id="learning-search" type="search" value="${esc(learningQuery)}" placeholder="搜索题目或知识" aria-label="搜索学习档案"></label>
        <span id="learning-search-count">${items.length} 项</span>
      </div>
      ${learningPath ? `<div class="learning-path-filter"><span>${esc(learningPath.replaceAll(' / ', ' › '))}</span><button type="button" data-learning-action="clear-path" aria-label="清除知识路径筛选">×</button></div>` : ''}
      <div class="learning-category-filter" aria-label="题目类别筛选"><button class="${learningPath ? '' : 'active'}" type="button" data-learning-path="">全部 <small>${problemItems.length}</small></button>${categories.map(([path, entry]) => `<button class="${learningPath === path ? 'active' : ''}" type="button" data-learning-path="${esc(path)}">${esc(entry.category)} <small>${entry.count}</small></button>`).join('')}</div>
      <div class="learning-library-list">${learningLibraryListHtml(items)}</div>
    </div>`;
    const input = $('#learning-search');
    if (!input) return;
    // 键入只局部刷新列表：保住输入法组合态、光标位置和筛选条滚动位置。
    let searchTimer = 0;
    const applySearch = () => {
      learningQuery = input.value;
      const latest = learningDashboard ? { ...learningDashboard, items: learningDashboard.items.filter(item => item.kind === 'problem') } : null;
      const list = content.querySelector('.learning-library-list');
      if (!latest || !list) return;
      const filtered = learningLibraryFilteredItems(latest);
      list.innerHTML = learningLibraryListHtml(filtered);
      const count = content.querySelector('#learning-search-count');
      if (count) count.textContent = `${filtered.length} 项`;
    };
    input.addEventListener('input', event => {
      if (event.isComposing) return;
      clearTimeout(searchTimer);
      searchTimer = setTimeout(applySearch, 120);
    });
    input.addEventListener('compositionend', () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(applySearch, 60);
    });
  }

  function renderLearningTrash() {
    const content = $('#learning-content');
    const deletedItems = learningDashboard?.deletedItems || [];
    if (!deletedItems.length) {
      content.innerHTML = `<div class="learning-trash-empty"><span><svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M4 7h16M9 7V4h6v3m3 0-1 13H7L6 7" stroke-linecap="round" stroke-linejoin="round"/></svg></span><strong>回收站为空</strong><p>删除的学习项会在这里保留 30 天</p></div>`;
      return;
    }
    const now = Date.now();
    content.innerHTML = `<div class="learning-trash">
      <header><div><strong>回收站</strong><span>完整学习快照保留 30 天</span></div><div class="learning-trash-tools"><em>${deletedItems.length} 项</em><button class="learning-trash-purge-all ${learningPurgeAllConfirming ? 'is-confirming' : ''}" type="button" data-learning-action="purge-all-trash">${learningPurgeAllConfirming ? '确认清空' : '清空回收站'}</button></div></header>
      ${learningTrashMessage ? `<p class="learning-trash-message" role="status">${esc(learningTrashMessage)}</p>` : ''}
      <div class="learning-trash-list">${deletedItems.map(item => {
        const remainingDays = Math.max(1, Math.ceil((Number(item.expiresAt) - now) / 86400000));
        const sourceAvailable = (item.sourceRefs || []).some(ref => Boolean(conversations[ref.conversationId]));
        const confirming = learningPurgeConfirmItemId === item.id;
        return `<article class="learning-trash-row" data-learning-trash-item="${esc(item.id)}">
          <span class="learning-trash-kind" data-kind="${esc(item.kind)}">${item.kind === 'knowledge' ? '知识' : '题目'}</span>
          <div><strong>${esc(item.title)}</strong><span>${sourceAvailable ? '原对话可用' : '原对话已删除，知识快照仍可恢复'} · ${remainingDays} 天后清理</span></div>
          <footer>
            <button class="learning-trash-restore" type="button" data-learning-action="restore-trash" data-item-id="${esc(item.id)}">恢复</button>
            <button class="learning-trash-purge ${confirming ? 'is-confirming' : ''}" type="button" data-learning-action="purge-trash" data-item-id="${esc(item.id)}">${confirming ? '确认彻底删除' : '彻底删除'}</button>
          </footer>
        </article>`;
      }).join('')}</div>
    </div>`;
  }

  const MINDMAP_VISIBLE_ITEMS_PER_BRANCH = 3;

  function walkLearningMindMapNodes(callback, node = activeLearningMindMap?.get_root?.()) {
    if (!node) return;
    callback(node);
    for (const child of node.children || []) walkLearningMindMapNodes(callback, child);
  }

  function captureLearningMindMapView() {
    const map = activeLearningMindMap;
    if (!map?.view) return learningMindMapViewState;
    const expandedIds = [];
    walkLearningMindMapNodes(node => {
      if (node.expanded && node.children?.length) expandedIds.push(node.id);
    });
    const viewport = document.querySelector('#learning-mindmap .jsmind-inner');
    learningMindMapViewState = {
      selectedId: map.get_selected_node?.()?.id || learningMindMapSelectedId || 'knowledge-root',
      expandedIds,
      zoom: Number(map.view.zoom_current) || 1,
      scrollLeft: viewport?.scrollLeft || 0,
      scrollTop: viewport?.scrollTop || 0,
      focusedBranchId: learningMindMapFocusedBranchId
    };
    return learningMindMapViewState;
  }

  function destroyActiveLearningMindMap({ preserveView = true } = {}) {
    if (preserveView) captureLearningMindMapView();
    learningMindMapResizeObserver?.disconnect();
    learningMindMapResizeObserver = null;
    clearTimeout(learningMindMapResizeTimer);
    learningMindMapResizeTimer = 0;
    learningMindMapStageSize = null;
    activeLearningMindMap?.clear_event_listener?.();
    activeLearningMindMap = null;
    learningMindMapSearchMatches = [];
    learningMindMapSearchIndex = -1;
    if (!preserveView) {
      learningMindMapViewState = null;
      learningMindMapFocusedBranchId = '';
      learningMindMapSelectedId = 'knowledge-root';
    }
  }

  function mindMapPalette(score) {
    if (score >= 78) return { accent: '#128060', surface: '#e4f5ee' };
    if (score >= 58) return { accent: '#0871cf', surface: '#e4f1fd' };
    if (score >= 38) return { accent: '#bd7309', surface: '#fff1d8' };
    return { accent: '#c64b3f', surface: '#fde9e6' };
  }

  function buildLearningMindMapData(tree) {
    const totalItemIds = new Set(tree.flatMap(node => node.itemIds || []));
    const roots = tree.filter(node => node.depth === 0);
    const rootDirections = new Map();
    let leftWeight = 0;
    let rightWeight = 0;
    roots.forEach((node, index) => {
      const weight = Math.max(1, node.itemIds?.length || 0);
      const direction = rightWeight < leftWeight || (rightWeight === leftWeight && index % 2 === 0) ? 'right' : 'left';
      rootDirections.set(node.id, direction);
      if (direction === 'right') rightWeight += weight;
      else leftWeight += weight;
    });

    const data = [{
      id: 'knowledge-root',
      isroot: true,
      topic: '我的学习图谱',
      nodeType: 'root',
      totalItems: totalItemIds.size,
      totalNodes: tree.length
    }];

    for (const node of tree) {
      const palette = mindMapPalette(node.score);
      data.push({
        id: node.id,
        parentid: node.parentId,
        topic: node.name,
        direction: node.depth === 0 ? rootDirections.get(node.id) : undefined,
        nodeType: 'concept',
        name: node.name,
        path: node.path.join(' / '),
        score: Math.round(node.score),
        itemCount: node.itemIds?.length || 0,
        depth: node.depth,
        accent: palette.accent,
        surface: palette.surface,
        'leading-line-color': palette.accent
      });

      const directItems = (node.directItemIds || [])
        .map(learningItem)
        .filter(Boolean)
        .sort((left, right) => (left.mastery?.score || 0) - (right.mastery?.score || 0)
          || left.title.localeCompare(right.title, 'zh-CN'));
      for (const item of directItems.slice(0, MINDMAP_VISIBLE_ITEMS_PER_BRANCH)) {
        data.push({
          id: `mind-item-${node.id}-${item.id}`,
          parentid: node.id,
          topic: item.title,
          nodeType: 'item',
          itemId: item.id,
          itemKind: item.kind,
          name: item.title,
          searchText: `${item.title} ${(item.labels || []).join(' ')}`,
          path: node.path.join(' / '),
          score: Math.round(item.mastery?.score || 0),
          'leading-line-color': '#aebdc5'
        });
      }
      if (directItems.length > MINDMAP_VISIBLE_ITEMS_PER_BRANCH) {
        data.push({
          id: `mind-more-${node.id}`,
          parentid: node.id,
          topic: `其余 ${directItems.length - MINDMAP_VISIBLE_ITEMS_PER_BRANCH} 项`,
          nodeType: 'more',
          name: `其余 ${directItems.length - MINDMAP_VISIBLE_ITEMS_PER_BRANCH} 项`,
          path: node.path.join(' / '),
          itemCount: directItems.length,
          'leading-line-color': '#aebdc5'
        });
      }
    }
    data[0].totalMapNodes = data.length;
    return data;
  }

  function defaultLearningMindMapDepth(totalMapNodes) {
    if (totalMapNodes <= 28) return 4;
    if (totalMapNodes <= 60) return 2;
    return 1;
  }

  function renderLearningMindMapNode(_, element, node) {
    const data = node.data || {};
    const type = data.nodeType || 'concept';
    element.replaceChildren();
    element.classList.add(`mind-node-${type}`);
    element.dataset.nodeType = type;
    element.dataset.search = String(data.searchText || `${data.name || node.topic} ${data.path || ''}`).toLocaleLowerCase('zh-CN');
    element.tabIndex = 0;
    element.setAttribute('role', 'treeitem');
    element.setAttribute('aria-level', String(type === 'root' ? 1 : (Number(data.depth) || 0) + 2));

    if (type === 'root') {
      const title = document.createElement('strong');
      const summary = document.createElement('span');
      title.textContent = '学习图谱';
      summary.textContent = `${data.totalItems || 0} 项 · ${data.totalNodes || 0} 个节点`;
      element.append(title, summary);
      element.setAttribute('aria-label', `${title.textContent}，${summary.textContent}`);
      return true;
    }

    if (type === 'concept') {
      const title = document.createElement('strong');
      const meta = document.createElement('span');
      const count = document.createElement('small');
      const score = document.createElement('b');
      const meter = document.createElement('i');
      const fill = document.createElement('em');
      title.textContent = data.name || node.topic;
      count.textContent = `${data.itemCount || 0} 项`;
      score.textContent = `${data.score || 0}%`;
      meta.append(count, score);
      meter.append(fill);
      element.append(title, meta, meter);
      element.style.setProperty('--mind-accent', data.accent || '#0877e6');
      element.style.setProperty('--mind-surface', data.surface || '#e4f1fd');
      element.style.setProperty('--mind-progress', `${Math.max(0, Math.min(100, Number(data.score) || 0))}%`);
      element.title = `${data.path?.replaceAll(' / ', ' › ') || title.textContent} · ${score.textContent}`;
      element.setAttribute('aria-label', `${data.path || title.textContent}，掌握度 ${score.textContent}，${count.textContent}`);
      return true;
    }

    const badge = document.createElement('span');
    const title = document.createElement('strong');
    badge.className = 'mind-item-kind';
    badge.dataset.kind = data.itemKind || type;
    badge.textContent = type === 'more' ? '···' : (data.itemKind === 'problem' ? '题' : '知');
    title.textContent = data.name || node.topic;
    element.append(badge, title);
    element.title = title.textContent;
    element.setAttribute('aria-label', type === 'more' ? `${title.textContent}，打开完整列表` : `${data.itemKind === 'problem' ? '题目' : '知识'}：${title.textContent}`);
    return true;
  }

  function updateLearningMapZoomControls() {
    const view = activeLearningMindMap?.view;
    const zoom = Number(view?.zoom_current) || 1;
    const output = $('#learning-map-zoom');
    if (output) output.textContent = `${Math.round(zoom * 100)}%`;
    const zoomOut = document.querySelector('[data-learning-action="map-zoom-out"]');
    const zoomIn = document.querySelector('[data-learning-action="map-zoom-in"]');
    if (zoomOut) zoomOut.disabled = !view || zoom <= (view.opts?.zoom?.min || 0.5) + 0.001;
    if (zoomIn) zoomIn.disabled = !view || zoom >= (view.opts?.zoom?.max || 2) - 0.001;
  }

  function setLearningMindMapZoom(nextZoom, centerNode = null) {
    const view = activeLearningMindMap?.view;
    if (!view) return;
    const minimum = view.opts?.zoom?.min || 0.5;
    const maximum = view.opts?.zoom?.max || 2;
    view.set_zoom(Math.max(minimum, Math.min(maximum, nextZoom)));
    updateLearningMapZoomControls();
    if (centerNode) requestAnimationFrame(() => activeLearningMindMap?.scroll_node_to_center(centerNode));
  }

  function relayoutLearningMindMap({ centerNode = null, preserveViewport = true } = {}) {
    const map = activeLearningMindMap;
    const viewport = map?.view?.e_panel;
    if (!map?.mind?.nodes || !viewport) return;
    const anchor = centerNode || map.get_selected_node?.() || map.get_root?.();
    const anchorElement = anchor?._data?.view?.element;
    const viewportRect = viewport.getBoundingClientRect();
    const anchorRect = preserveViewport && anchorElement?.getBoundingClientRect?.();
    const anchorOffset = anchorRect ? {
      x: anchorRect.left + anchorRect.width / 2 - viewportRect.left,
      y: anchorRect.top + anchorRect.height / 2 - viewportRect.top
    } : null;

    for (const node of Object.values(map.mind.nodes)) map.view.update_node(node);
    map.layout.layout();
    map.view.resize();
    updateLearningMapZoomControls();

    if (!anchor || !map.is_node_visible(anchor)) return;
    requestAnimationFrame(() => {
      if (!activeLearningMindMap || activeLearningMindMap !== map) return;
      if (!anchorOffset) {
        map.scroll_node_to_center(anchor);
        return;
      }
      const nextRect = anchorElement.getBoundingClientRect();
      viewport.scrollBy(
        nextRect.left + nextRect.width / 2 - viewportRect.left - anchorOffset.x,
        nextRect.top + nextRect.height / 2 - viewportRect.top - anchorOffset.y
      );
    });
  }

  function fitLearningMindMap() {
    const map = activeLearningMindMap;
    const stage = document.querySelector('.learning-graph-stage');
    if (!map?.view || !stage) return;
    const viewport = stage.querySelector('.jsmind-inner');
    const currentZoom = Number(map.view.zoom_current) || 1;
    const contentWidth = Math.max(1, viewport?.scrollWidth || map.view.size?.w || 1);
    const contentHeight = Math.max(1, viewport?.scrollHeight || map.view.size?.h || 1);
    const widthRatio = Math.max(0.1, (stage.clientWidth - 36) / contentWidth);
    const heightRatio = Math.max(0.1, (stage.clientHeight - 30) / contentHeight);
    const minimum = map.view.opts?.zoom?.min || 0.5;
    const zoom = Math.max(minimum, Math.min(1, currentZoom * widthRatio, currentZoom * heightRatio));
    setLearningMindMapZoom(zoom, map.get_root());
  }

  function learningMindMapBranchNode(node) {
    let branch = node;
    while (branch && !branch.isroot && branch.data?.nodeType !== 'concept') branch = branch.parent;
    return branch?.isroot ? null : branch;
  }

  function updateLearningMindMapScope() {
    const scope = $('#learning-map-scope');
    const reset = document.querySelector('[data-learning-action="map-reset-scope"]');
    const focusedNode = learningMindMapFocusedBranchId && activeLearningMindMap?.get_node(learningMindMapFocusedBranchId);
    if (scope) {
      scope.textContent = focusedNode ? `聚焦 · ${focusedNode.data?.name || focusedNode.topic}` : '全部分支';
      scope.classList.toggle('is-focused', Boolean(focusedNode));
    }
    if (reset) reset.disabled = !focusedNode;
  }

  function focusLearningMindMapBranch(node = activeLearningMindMap?.get_selected_node?.()) {
    const map = activeLearningMindMap;
    const branch = learningMindMapBranchNode(node);
    if (!map || !branch) return;
    map.collapse_all();
    const ancestors = [];
    let parent = branch.parent;
    while (parent) {
      ancestors.unshift(parent);
      parent = parent.parent;
    }
    for (const ancestor of ancestors) map.expand_node(ancestor);
    map.expand_node(branch);
    for (const child of branch.children || []) {
      if (child.data?.nodeType === 'concept') map.expand_node(child);
    }
    learningMindMapFocusedBranchId = branch.id;
    learningMindMapSelectedId = node?.id || branch.id;
    map.select_node(node || branch);
    updateLearningMindMapScope();
    updateLearningMapInspector(node || branch);
    requestAnimationFrame(() => {
      relayoutLearningMindMap({ centerNode: node || branch, preserveViewport: false });
    });
  }

  function resetLearningMindMapScope({ fit = true } = {}) {
    const map = activeLearningMindMap;
    if (!map) return;
    learningMindMapFocusedBranchId = '';
    map.collapse_all();
    const totalMapNodes = Number(map.get_root()?.data?.totalMapNodes) || 0;
    map.expand_to_depth(defaultLearningMindMapDepth(totalMapNodes));
    updateLearningMindMapScope();
    requestAnimationFrame(() => {
      relayoutLearningMindMap({ preserveViewport: false });
      if (fit) requestAnimationFrame(() => requestAnimationFrame(fitLearningMindMap));
    });
  }

  function updateLearningMapInspector(node = activeLearningMindMap?.get_selected_node?.()) {
    const title = $('#learning-map-selection-title');
    const meta = $('#learning-map-selection-meta');
    const score = $('#learning-map-selection-score');
    const primaryAction = document.querySelector('[data-learning-action="map-open-selected"]');
    const secondaryAction = document.querySelector('[data-learning-action="map-secondary-selected"]');
    if (!title || !meta || !score || !primaryAction || !secondaryAction) return;
    const data = node?.data || {};
    learningMindMapSelectedId = node?.id || 'knowledge-root';
    if (!node || node.isroot) {
      title.textContent = '全图概览';
      meta.textContent = `${learningDashboard?.stats?.total || 0} 个学习项 · ${learningDashboard?.knowledgeTree?.length || 0} 个知识节点`;
      score.textContent = '';
      score.hidden = true;
      secondaryAction.disabled = !learningMindMapFocusedBranchId;
      secondaryAction.textContent = '回到全图';
      primaryAction.disabled = false;
      primaryAction.textContent = '适配全图';
      return;
    }
    title.textContent = data.name || node.topic;
    meta.textContent = data.itemId
      ? (data.path || '学习项').replaceAll(' / ', ' › ')
      : `${(data.path || '').replaceAll(' / ', ' › ')}${data.itemCount ? ` · ${data.itemCount} 项` : ''}`;
    score.hidden = data.nodeType !== 'concept';
    score.textContent = data.nodeType === 'concept' ? `${data.score || 0}%` : '';
    score.style.setProperty('--mind-score-color', data.accent || '#0877e6');
    secondaryAction.disabled = !learningMindMapBranchNode(node);
    secondaryAction.textContent = data.itemId ? '定位分支' : '聚焦';
    primaryAction.disabled = !data.itemId && !data.path;
    primaryAction.textContent = data.itemId ? '进入学习' : `查看${data.itemCount ? ` ${data.itemCount} 项` : '相关项'}`;
  }

  function activateLearningMindMapNode(node = activeLearningMindMap?.get_selected_node?.()) {
    const data = node?.data || {};
    if (data.itemId) {
      renderLearningDetail(data.itemId);
      return;
    }
    if (!data.path) return;
    learningPath = data.path;
    learningLabel = '';
    learningTab = 'library';
    renderLearningContent();
  }

  function focusLearningMindMapNode(node) {
    if (!node || !activeLearningMindMap?.is_node_visible(node)) return;
    activeLearningMindMap.select_node(node);
    activeLearningMindMap.scroll_node_to_center(node);
    updateLearningMapInspector(node);
    requestAnimationFrame(() => {
      document.querySelector(`#learning-mindmap jmnode[nodeid="${CSS.escape(node.id)}"]`)?.focus({ preventScroll: true });
    });
  }

  function restoreLearningMindMapView() {
    const map = activeLearningMindMap;
    const state = learningMindMapViewState;
    if (!map || !state) return false;
    map.collapse_all();
    for (const nodeId of state.expandedIds || []) {
      const node = map.get_node(nodeId);
      if (node?.children?.length) map.expand_node(node);
    }
    const selected = map.get_node(state.selectedId) || map.get_root();
    learningMindMapFocusedBranchId = map.get_node(state.focusedBranchId)?.id || '';
    setLearningMindMapZoom(state.zoom, null);
    map.select_node(selected);
    updateLearningMapInspector(selected);
    updateLearningMindMapScope();
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const viewport = document.querySelector('#learning-mindmap .jsmind-inner');
      if (!viewport) return;
      viewport.scrollLeft = Math.max(0, state.scrollLeft || 0);
      viewport.scrollTop = Math.max(0, state.scrollTop || 0);
    }));
    return true;
  }

  function stepLearningMindMapSearch(direction) {
    if (!learningMindMapSearchMatches.length || !activeLearningMindMap) return;
    learningMindMapSearchIndex = (learningMindMapSearchIndex + direction + learningMindMapSearchMatches.length)
      % learningMindMapSearchMatches.length;
    const node = activeLearningMindMap.get_node(learningMindMapSearchMatches[learningMindMapSearchIndex]);
    if (!node) return;
    let parent = node.parent;
    while (parent && !parent.isroot) {
      activeLearningMindMap.expand_node(parent);
      parent = parent.parent;
    }
    focusLearningMindMapNode(node);
    const count = $('#learning-map-search-count');
    if (count) count.textContent = `${learningMindMapSearchIndex + 1} / ${learningMindMapSearchMatches.length}`;
  }

  function updateLearningMindMapSearch(value) {
    const query = String(value || '').trim().toLocaleLowerCase('zh-CN');
    const nodes = [...document.querySelectorAll('#learning-mindmap jmnode:not(.root)')];
    learningMindMapSearchMatches = [];
    learningMindMapSearchIndex = -1;
    for (const element of nodes) {
      const matches = Boolean(query) && element.dataset.search.includes(query);
      element.classList.toggle('search-match', matches);
      element.classList.toggle('search-muted', Boolean(query) && !matches);
      if (matches) learningMindMapSearchMatches.push(element.getAttribute('nodeid'));
    }
    const count = $('#learning-map-search-count');
    if (count) count.textContent = query ? `${learningMindMapSearchMatches.length} 个结果` : `${nodes.length} 个节点`;
    for (const button of document.querySelectorAll('[data-learning-action="map-search-previous"], [data-learning-action="map-search-next"]')) {
      button.disabled = !learningMindMapSearchMatches.length;
    }
  }

  function bindLearningMindMapInteraction(container) {
    container.addEventListener('dblclick', event => {
      const element = event.target.closest('jmnode');
      if (!element) return;
      const node = activeLearningMindMap?.get_node(element.getAttribute('nodeid'));
      if (node?.data?.itemId) activateLearningMindMapNode(node);
      else if (node && !node.isroot && node.data?.nodeType === 'concept') focusLearningMindMapBranch(node);
      else activateLearningMindMapNode(node);
    });
    container.addEventListener('keydown', event => {
      const element = event.target.closest('jmnode');
      const node = element && activeLearningMindMap?.get_node(element.getAttribute('nodeid'));
      if (!node) return;
      if (event.key === 'Escape' && learningMindMapFocusedBranchId) {
        event.preventDefault();
        resetLearningMindMapScope();
        return;
      }
      if (event.key === 'Enter') {
        event.preventDefault();
        activateLearningMindMapNode(node);
        return;
      }
      if (event.key === ' ') {
        event.preventDefault();
        if (node.children?.length) activeLearningMindMap.toggle_node(node);
        else activateLearningMindMapNode(node);
        return;
      }
      let target = null;
      if (event.key === 'ArrowUp') target = activeLearningMindMap.find_node_before(node);
      else if (event.key === 'ArrowDown') target = activeLearningMindMap.find_node_after(node);
      else if (event.key === 'Home') target = activeLearningMindMap.get_root();
      else if (event.key === 'ArrowLeft') {
        if (node.children?.length && node.expanded) activeLearningMindMap.collapse_node(node);
        else target = node.parent;
      } else if (event.key === 'ArrowRight') {
        if (node.children?.length && !node.expanded) activeLearningMindMap.expand_node(node);
        else target = node.children?.find(child => activeLearningMindMap.is_node_visible(child));
      } else return;
      event.preventDefault();
      event.stopPropagation();
      if (target) focusLearningMindMapNode(target);
      else updateLearningMapInspector(node);
    });

    const search = $('#learning-map-search');
    search?.addEventListener('input', () => updateLearningMindMapSearch(search.value));
    search?.addEventListener('keydown', event => {
      if (event.key === 'Enter') {
        event.preventDefault();
        stepLearningMindMapSearch(event.shiftKey ? -1 : 1);
      } else if (event.key === 'Escape' && search.value) {
        search.value = '';
        updateLearningMindMapSearch('');
      }
    });
  }

  function renderLearningKnowledge() {
    const content = $('#learning-content');
    const tree = learningDashboard?.knowledgeTree || [];
    destroyActiveLearningMindMap();
    if (!tree.length) {
      content.innerHTML = '<div class="learning-graph-empty"><strong>知识脑图正在形成</strong><span>先去提问，知识会自动归类到这里</span></div>';
      return;
    }
    const totalItems = new Set(tree.flatMap(node => node.itemIds || [])).size;
    content.innerHTML = `<div class="learning-graph-view">
      <header><div class="learning-map-heading"><strong>知识脑图</strong><span>${tree.length} 个知识节点 · ${totalItems} 个学习项</span></div><span class="learning-map-scope" id="learning-map-scope">全部分支</span><div class="learning-map-actions"><button type="button" data-learning-action="map-collapse" title="仅显示一级分支" aria-label="仅显示一级分支"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m7 9 5-5 5 5M7 15l5 5 5-5" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button type="button" data-learning-action="map-expand" title="展开全部分支" aria-label="展开全部分支"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m7 7 5 5 5-5M7 17l5-5 5 5" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button type="button" data-learning-action="map-reset-scope" title="回到全部分支" aria-label="回到全部分支" disabled><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M4 12h10M4 18h7" stroke-linecap="round"/><path d="m17 15 3 3-3 3" stroke-linecap="round" stroke-linejoin="round"/></svg></button><i aria-hidden="true"></i><button type="button" data-learning-action="map-center-selected" title="居中当前节点" aria-label="居中当前节点"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3" stroke-linecap="round"/></svg></button><button type="button" data-learning-action="map-fit" title="适配窗口" aria-label="适配脑图到窗口"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M8 3H3v5M16 3h5v5M8 21H3v-5M16 21h5v-5" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button type="button" data-learning-action="map-zoom-out" title="缩小" aria-label="缩小脑图"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="M7 12h10" stroke-linecap="round"/></svg></button><output id="learning-map-zoom" aria-live="polite">100%</output><button type="button" data-learning-action="map-zoom-in" title="放大" aria-label="放大脑图"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 7v10M7 12h10" stroke-linecap="round"/></svg></button></div></header>
      <div class="learning-mastery-legend" aria-label="掌握度颜色"><span data-mastery="mastered">已掌握</span><span data-mastery="familiar">逐渐熟练</span><span data-mastery="learning">学习中</span><span data-mastery="weak">待巩固</span></div>
      <div class="learning-map-search-row"><label><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="m16 16 4 4" stroke-linecap="round"/></svg><input id="learning-map-search" type="search" placeholder="查找知识或题目" aria-label="查找脑图节点" aria-controls="learning-mindmap"><span id="learning-map-search-count">0 个节点</span></label><div><button type="button" data-learning-action="map-search-previous" title="上一个结果" aria-label="上一个搜索结果" disabled><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 16-4-4 4-4" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button type="button" data-learning-action="map-search-next" title="下一个结果" aria-label="下一个搜索结果" disabled><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="m9 8 4 4-4 4" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div></div>
      <div class="learning-graph-stage"><div id="learning-mindmap" role="tree" aria-label="知识脑图"></div></div>
      <div class="learning-map-inspector" id="learning-map-inspector"><div><strong id="learning-map-selection-title">全图概览</strong><span id="learning-map-selection-meta">${totalItems} 个学习项 · ${tree.length} 个知识节点</span></div><output id="learning-map-selection-score" hidden></output><div class="learning-map-inspector-actions"><button type="button" data-learning-action="map-secondary-selected" disabled>回到全图</button><button type="button" data-learning-action="map-open-selected">适配全图</button></div></div>
    </div>`;
    mountLearningMindMap(tree).catch(error => {
      console.warn('Failed to load learning mind map:', error);
      const stage = document.querySelector('.learning-graph-stage');
      if (stage) stage.innerHTML = '<div class="learning-map-error" role="alert">脑图加载失败，请重新打开学习中心</div>';
    });
  }

  async function mountLearningMindMap(tree) {
    const container = $('#learning-mindmap');
    if (!container) return;
    await ensureMindMapRuntime();
    if (!container.isConnected || container !== $('#learning-mindmap') || !window.jsMind) return;
    const data = buildLearningMindMapData(tree);
    activeLearningMindMap = new window.jsMind({
      container: 'learning-mindmap',
      editable: false,
      theme: null,
      mode: 'full',
      support_html: false,
      log_level: 'warn',
      view: {
        engine: 'svg',
        hmargin: 34,
        vmargin: 24,
        line_width: 1.5,
        line_color: '#9db3bf',
        line_style: 'curved',
        draggable: true,
        hide_scrollbars_when_draggable: true,
        node_overflow: 'wrap',
        zoom: { min: 0.5, max: 1.7, step: 0.1, mask_key: 4096 },
        custom_node_render: renderLearningMindMapNode,
        expander_style: 'number'
      },
      layout: { hspace: 56, vspace: 16, pspace: 16, cousin_space: 12 },
      shortcut: { enable: false }
    });
    activeLearningMindMap.show({ meta: { name: 'learning', author: 'local', version: '2' }, format: 'node_array', data });
    activeLearningMindMap.add_event_listener((type, event) => {
      if (type !== window.jsMind.event_type.select || !event?.node) return;
      const node = activeLearningMindMap?.get_node(event.node);
      if (node) updateLearningMapInspector(node);
    });
    bindLearningMindMapInteraction(container);
    learningMindMapStageSize = { width: container.clientWidth, height: container.clientHeight };
    learningMindMapResizeObserver = new ResizeObserver(entries => {
      if (!activeLearningMindMap || !container.isConnected) return;
      const box = entries[0]?.contentRect;
      const nextSize = { width: box?.width || container.clientWidth, height: box?.height || container.clientHeight };
      const previousSize = learningMindMapStageSize;
      learningMindMapStageSize = nextSize;
      clearTimeout(learningMindMapResizeTimer);
      learningMindMapResizeTimer = setTimeout(() => {
        if (!activeLearningMindMap || !container.isConnected) return;
        const selected = activeLearningMindMap.get_selected_node?.();
        relayoutLearningMindMap();
        const widthChange = previousSize?.width ? Math.abs(nextSize.width - previousSize.width) / previousSize.width : 0;
        const heightChange = previousSize?.height ? Math.abs(nextSize.height - previousSize.height) / previousSize.height : 0;
        if (selected && Math.max(widthChange, heightChange) > 0.18) {
          requestAnimationFrame(() => activeLearningMindMap?.scroll_node_to_center(selected));
        }
      }, 120);
    });
    learningMindMapResizeObserver.observe(container);
    updateLearningMindMapSearch('');
    if (!restoreLearningMindMapView()) {
      activeLearningMindMap.expand_to_depth(defaultLearningMindMapDepth(data.length));
      const root = activeLearningMindMap.get_root();
      activeLearningMindMap.select_node(root);
      updateLearningMapInspector(root);
      updateLearningMindMapScope();
      requestAnimationFrame(() => requestAnimationFrame(fitLearningMindMap));
    }
  }

  function renderLearningInsights() {
    const dashboard = learningDashboard;
    const content = $('#learning-content');
    if (!dashboard) return renderLearningToday();
    const states = ['已掌握', '逐渐熟练', '学习中', '需要巩固', '待观察'];
    const stateCounts = Object.fromEntries(states.map(state => [state, dashboard.items.filter(item => item.mastery.state === state).length]));
    const maxActivity = Math.max(1, ...dashboard.activity.map(day => day.count));
    const activityTotal = dashboard.activity.reduce((sum, day) => sum + day.count, 0);
    const recentTimeline = (dashboard.timeline || []).slice(0, 10);
    const timelineSignalLabel = signal => ({ mastered: '已掌握', demonstrated: '已验证', learning: '学习中', applying: '应用中', gap: '待修正', struggling: '需巩固' }[signal] || '已记录');
    content.innerHTML = `<div class="learning-insights">
      <section class="learning-insight-lead">
        <div class="learning-insight-heading"><span>能力概览</span><strong>平均掌握度</strong></div>
        <div class="learning-insight-score"><strong>${Math.round(dashboard.stats.averageMastery)}</strong><small>%</small></div>
        <div class="learning-insight-progress"><header><span>学习覆盖</span><strong>${dashboard.stats.problems} 道题目 · ${dashboard.stats.knowledge} 个知识点</strong></header><i><b style="width:${learningPercent(dashboard.stats.averageMastery)}"></b></i></div>
      </section>
      <section class="learning-record-stats"><div><strong>${dashboard.stats.attempts || 0}</strong><span>检测次数</span></div><div><strong>${Math.round(dashboard.stats.practiceAccuracy || 0)}%</strong><span>平均得分</span></div><div><strong>${dashboard.stats.evidence || 0}</strong><span>能力证据</span></div><div><strong>${dashboard.stats.sourceSnapshots || 0}</strong><span>提问快照</span></div></section>
      <section class="learning-activity"><header><div><span>学习节奏</span><strong>最近 14 天</strong></div><small>${activityTotal} 次学习活动</small></header><div>${dashboard.activity.map(day => `<span title="${esc(day.date)} · ${day.count} 次"><i style="height:${Math.max(5, day.count / maxActivity * 100)}%"></i><small>${day.date.slice(8)}</small></span>`).join('')}</div></section>
      <section class="learning-distribution"><header><div><span>能力结构</span><strong>掌握分布</strong></div><small>${dashboard.stats.total || 0} 个学习项</small></header>${states.map(state => { const count = stateCounts[state]; const ratio = dashboard.stats.total ? count / dashboard.stats.total * 100 : 0; return `<div data-state="${state}"><span>${state}</span><i><b style="width:${ratio}%"></b></i><strong>${count}<small>${Math.round(ratio)}%</small></strong></div>`; }).join('')}</section>
      <section class="learning-weak-concepts"><header><div><span>下一步</span><strong>优先巩固</strong></div><small>${Math.min(6, dashboard.knowledge.length)} 个薄弱项</small></header>${dashboard.knowledge.slice(0, 6).map(concept => `<button type="button" data-learning-label="${esc(concept.name)}"><span>${esc(concept.name)}</span><strong>${Math.round(concept.score)}%</strong><i><b style="width:${learningPercent(concept.score)}"></b></i></button>`).join('') || '<div class="learning-library-empty">暂无知识分类</div>'}</section>
      <section class="learning-record-timeline"><header><div><span>成长轨迹</span><strong>提交记录</strong></div><small>最近 ${recentTimeline.length} 条</small></header>${recentTimeline.map(event => `<button type="button" data-learning-item="${esc(event.itemId)}" data-signal="${esc(event.signal)}" aria-label="打开 ${esc(event.itemTitle)} 的学习记录"><i aria-hidden="true" data-signal="${esc(event.signal)}"></i><span class="learning-timeline-copy"><strong>${esc(event.itemTitle)}</strong><small>${esc(event.summary || '学习状态更新')}</small></span><span class="learning-timeline-meta"><em>${timelineSignalLabel(event.signal)}</em><time datetime="${esc(event.observedAt)}">${new Date(event.observedAt).toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' })}</time><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m9 18 6-6-6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></span></button>`).join('') || '<p>暂无提交记录</p>'}</section>
    </div>`;
  }

  function leetcodeStatusLabel(status) {
    return { SOLVED: '已通过', TRIED: '尝试中', TO_DO: '未开始' }[status] || '未开始';
  }

  function leetcodeActivityLabel(type) {
    return { new: '新题', review: '复习', attempt: '继续尝试', historical: '历史' }[type] || '提交';
  }

  function leetcodeDifficultyLabel(value) {
    return { EASY: '简单', MEDIUM: '中等', HARD: '困难' }[value] || value;
  }

  function formatLeetcodeTime(timestamp, fallback = '尚未同步') {
    if (!timestamp) return fallback;
    return new Date(timestamp).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  }

  function leetcodeQuestionRows() {
    const query = leetcodeQuery.trim().toLocaleLowerCase('zh-CN');
    return (leetcodeDashboard?.questions || []).filter(question => {
      if (leetcodeFilter !== 'all' && question.status !== leetcodeFilter) return false;
      if (!query) return true;
      return [question.frontendId, question.title, question.translatedTitle, question.groupName, ...(question.topicTags || []).flatMap(tag => [tag.name, tag.translatedName])]
        .join(' ').toLocaleLowerCase('zh-CN').includes(query);
    });
  }

  function leetcodeQuestionMasteryTone(question) {
    if (question.learning?.overdue) return 'review';
    if (question.status === 'TO_DO') return 'unseen';
    const score = Number(question.learning?.masteryScore) || 0;
    if (score >= 78) return 'mastered';
    if (score >= 58 || (question.status === 'SOLVED' && !score)) return 'familiar';
    return 'learning';
  }

  function hideLeetcodeHeatmapTooltip() {
    if (leetcodeHeatmapTooltipFrame) cancelAnimationFrame(leetcodeHeatmapTooltipFrame);
    leetcodeHeatmapTooltipFrame = 0;
    const tooltip = $('#leetcode-heatmap-tooltip');
    if (tooltip) tooltip.hidden = true;
  }

  function showLeetcodeHeatmapTooltip(cell, clientX, clientY) {
    if (!cell?.dataset.tooltip) return hideLeetcodeHeatmapTooltip();
    let tooltip = $('#leetcode-heatmap-tooltip');
    if (!tooltip) {
      tooltip = document.createElement('div');
      tooltip.id = 'leetcode-heatmap-tooltip';
      tooltip.className = 'leetcode-heatmap-tooltip';
      tooltip.setAttribute('role', 'tooltip');
      document.body.appendChild(tooltip);
    }
    tooltip.textContent = cell.dataset.tooltip;
    tooltip.hidden = false;
    if (leetcodeHeatmapTooltipFrame) cancelAnimationFrame(leetcodeHeatmapTooltipFrame);
    leetcodeHeatmapTooltipFrame = requestAnimationFrame(() => {
      leetcodeHeatmapTooltipFrame = 0;
      const bounds = tooltip.getBoundingClientRect();
      const margin = 8;
      const left = Math.min(window.innerWidth - bounds.width - margin, Math.max(margin, clientX - bounds.width / 2));
      const above = clientY - bounds.height - 12;
      const top = above >= margin ? above : Math.min(window.innerHeight - bounds.height - margin, clientY + 14);
      tooltip.style.transform = `translate3d(${Math.round(left)}px,${Math.round(top)}px,0)`;
    });
  }

  function renderLeetcodeQuestionList() {
    const list = $('#leetcode-question-list');
    const count = $('#leetcode-question-count');
    if (!list) return;
    const questions = leetcodeQuestionRows();
    if (count) count.textContent = `${questions.length} / ${leetcodeDashboard?.stats?.total || 0}`;
    const grouped = new Map();
    for (const question of questions) {
      const group = question.groupName || '未分类';
      if (!grouped.has(group)) grouped.set(group, []);
      grouped.get(group).push(question);
    }
    list.innerHTML = [...grouped.entries()].map(([group, items]) => `<section class="leetcode-question-group">
      <header><strong>${esc(group)}</strong><span>${items.filter(item => item.status === 'SOLVED').length} / ${items.length}</span></header>
      <div>${items.map(question => {
        const solved = question.status === 'SOLVED';
        const tried = question.status === 'TRIED';
        const overdue = solved && question.learning?.overdue;
        const statusIcon = solved
          ? '<path d="m7 12 3 3 7-7" stroke-linecap="round" stroke-linejoin="round"/><circle cx="12" cy="12" r="9"/>'
          : tried
            ? '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2.3" fill="currentColor" stroke="none"/>'
            : '<circle cx="12" cy="12" r="9"/>';
        return `<button class="leetcode-question-row" type="button" data-status="${esc(question.status)}" data-review="${overdue ? 'due' : 'current'}" data-mastery="${leetcodeQuestionMasteryTone(question)}" data-leetcode-question="${esc(question.titleSlug)}">
          <i aria-label="${overdue ? '已通过，待复习' : esc(leetcodeStatusLabel(question.status))}"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2">${statusIcon}</svg></i>
          <span class="leetcode-question-main"><strong>${esc(question.translatedTitle || question.title)}</strong>${question.lastSubmittedAt ? `<small>${formatLeetcodeTime(question.lastSubmittedAt, '')}${overdue ? ' · 待复习' : ''}</small>` : ''}</span>
          <span class="leetcode-difficulty" data-difficulty="${esc(question.difficulty)}">${esc(leetcodeDifficultyLabel(question.difficulty))}</span>
        </button>`;
      }).join('')}</div>
    </section>`).join('') || '<div class="leetcode-empty">没有匹配的题目</div>';
  }

  function leetcodeEditorMode(language) {
    const value = normalizedCompletionLanguage(language);
    return { java: 'text/x-java', cpp: 'text/x-c++', python: 'python', javascript: 'javascript', typescript: 'text/typescript' }[value] || 'text/plain';
  }

  function leetcodeWorkspaceDraftKey() {
    return `${leetcodeWorkspace?.question?.titleSlug || leetcodeCurrentSlug()}:${leetcodeWorkspaceLang || 'code'}`;
  }

  function setLeetcodeWorkspaceDraft(value) {
    const key = leetcodeWorkspaceDraftKey();
    if (!key || key.startsWith(':')) return;
    if (leetcodeWorkspaceDrafts.has(key)) leetcodeWorkspaceDrafts.delete(key);
    leetcodeWorkspaceDrafts.set(key, String(value || ''));
    while (leetcodeWorkspaceDrafts.size > 80) leetcodeWorkspaceDrafts.delete(leetcodeWorkspaceDrafts.keys().next().value);
  }

  function leetcodeWorkspaceSplitSizes(direction) {
    const fallback = direction === 'vertical' ? [35, 65] : [42, 58];
    try {
      const stored = JSON.parse(localStorage.getItem(`leetcode-workspace-split-${direction}`) || 'null');
      if (!Array.isArray(stored) || stored.length !== 2) return fallback;
      const first = Number(stored[0]);
      const second = Number(stored[1]);
      if (!Number.isFinite(first) || !Number.isFinite(second) || first < 15 || second < 15) return fallback;
      return [first, second];
    } catch (error) {
      return fallback;
    }
  }

  function saveLeetcodeWorkspaceSplitSizes(direction, sizes) {
    try {
      localStorage.setItem(`leetcode-workspace-split-${direction}`, JSON.stringify(
        sizes.map(value => Math.round(Number(value) * 100) / 100)
      ));
    } catch (error) {}
  }

  function destroyLeetcodeWorkspaceSplit() {
    if (leetcodeWorkspaceSplitFrame) cancelAnimationFrame(leetcodeWorkspaceSplitFrame);
    leetcodeWorkspaceSplitFrame = 0;
    clearTimeout(leetcodeWorkspaceSplitResizeTimer);
    leetcodeWorkspaceSplitResizeTimer = 0;
    leetcodeWorkspaceSplitResizeObserver?.disconnect();
    leetcodeWorkspaceSplitResizeObserver = null;
    activeLeetcodeEditorSplit?.destroy?.();
    activeLeetcodeEditorSplit = null;
    activeLeetcodeWorkspaceSplit?.destroy?.();
    activeLeetcodeWorkspaceSplit = null;
    leetcodeWorkspaceSplitDirection = '';
  }

  function refreshLeetcodeEditorAfterSplit() {
    if (leetcodeWorkspaceSplitFrame) return;
    leetcodeWorkspaceSplitFrame = requestAnimationFrame(() => {
      leetcodeWorkspaceSplitFrame = 0;
      activeLeetcodeEditor?.refresh();
    });
  }

  async function bindLeetcodeWorkspaceSplit() {
    const grid = document.querySelector('.leetcode-workspace-grid');
    const problemPane = grid?.querySelector('.leetcode-problem-pane');
    const codePane = grid?.querySelector('.leetcode-code-pane');
    const codeWorkarea = codePane?.querySelector('.leetcode-code-workarea');
    const editorPane = codeWorkarea?.querySelector('.leetcode-workspace-editor');
    const feedbackPane = codeWorkarea?.querySelector('.leetcode-code-feedback');
    if (!grid || !problemPane || !codePane || !codeWorkarea || !editorPane || !feedbackPane) return;
    await ensureWorkspaceSplitRuntime();
    if (!grid.isConnected || grid !== document.querySelector('.leetcode-workspace-grid')) return;
    destroyLeetcodeWorkspaceSplit();
    const direction = grid.clientWidth <= 820 ? 'vertical' : 'horizontal';
    leetcodeWorkspaceSplitDirection = direction;
    grid.dataset.splitDirection = direction;
    const minimum = direction === 'vertical'
      ? [Math.min(180, Math.max(90, grid.clientHeight * 0.22)), Math.min(300, Math.max(150, grid.clientHeight * 0.42))]
      : [280, 390];
    activeLeetcodeWorkspaceSplit = window.Split([problemPane, codePane], {
      direction,
      sizes: leetcodeWorkspaceSplitSizes(direction),
      minSize: minimum,
      gutterSize: 8,
      snapOffset: 24,
      cursor: direction === 'vertical' ? 'row-resize' : 'col-resize',
      onDrag: refreshLeetcodeEditorAfterSplit,
      onDragEnd: sizes => {
        saveLeetcodeWorkspaceSplitSizes(direction, sizes);
        refreshLeetcodeEditorAfterSplit();
      }
    });
    const editorSplitKey = 'leetcode-workspace-editor-split';
    let editorSizes = [64, 36];
    try {
      const stored = JSON.parse(localStorage.getItem(editorSplitKey) || 'null');
      if (Array.isArray(stored) && stored.length === 2 && stored.every(value => Number.isFinite(Number(value)))) {
        editorSizes = stored.map(Number);
      }
    } catch (error) {}
    const workareaHeight = Math.max(320, codeWorkarea.clientHeight);
    activeLeetcodeEditorSplit = window.Split([editorPane, feedbackPane], {
      direction: 'vertical',
      sizes: editorSizes,
      minSize: [Math.min(210, workareaHeight * 0.42), Math.min(150, workareaHeight * 0.28)],
      gutterSize: 9,
      snapOffset: 20,
      cursor: 'row-resize',
      onDrag: refreshLeetcodeEditorAfterSplit,
      onDragEnd: sizes => {
        try {
          localStorage.setItem(editorSplitKey, JSON.stringify(sizes.map(value => Math.round(Number(value) * 100) / 100)));
        } catch (error) {}
        refreshLeetcodeEditorAfterSplit();
      }
    });
    const editorGutter = codeWorkarea.querySelector('.gutter-vertical');
    if (editorGutter) {
      editorGutter.setAttribute('role', 'separator');
      editorGutter.setAttribute('aria-orientation', 'horizontal');
      editorGutter.setAttribute('aria-label', '调整代码与官方样例高度');
      editorGutter.title = '拖动调整代码与官方样例高度';
    }
    leetcodeWorkspaceSplitResizeObserver = new ResizeObserver(() => {
      clearTimeout(leetcodeWorkspaceSplitResizeTimer);
      leetcodeWorkspaceSplitResizeTimer = setTimeout(() => {
        leetcodeWorkspaceSplitResizeTimer = 0;
        if (!grid.isConnected || !leetcodeIsWorkspace() || grid.clientWidth < 1 || grid.clientHeight < 1) return;
        const nextDirection = grid.clientWidth <= 820 ? 'vertical' : 'horizontal';
        if (nextDirection !== leetcodeWorkspaceSplitDirection) {
          bindLeetcodeWorkspaceSplit().catch(error => console.warn('Failed to switch LeetCode split direction:', error));
        } else {
          refreshLeetcodeEditorAfterSplit();
        }
      }, 120);
    });
    leetcodeWorkspaceSplitResizeObserver.observe(grid);
    refreshLeetcodeEditorAfterSplit();
  }

  function destroyActiveLeetcodeEditor({ preserveDraft = true } = {}) {
    clearTimeout(leetcodeSyntaxTimer);
    leetcodeSyntaxTimer = 0;
    leetcodeSyntaxGeneration += 1;
    leetcodeEditorCompletionCleanup?.();
    leetcodeEditorCompletionCleanup = null;
    if (!activeLeetcodeEditor) return;
    if (preserveDraft) setLeetcodeWorkspaceDraft(activeLeetcodeEditor.getValue());
    clearLeetcodeSyntaxDiagnostics(activeLeetcodeEditor);
    activeLeetcodeEditor.toTextArea();
    activeLeetcodeEditor = null;
    leetcodeSyntaxResult = null;
  }

  function leetcodeWorkspaceTemplateCode() {
    const snippet = leetcodeWorkspace?.snippets?.find(item => item.langSlug === leetcodeWorkspaceLang)
      || leetcodeWorkspace?.snippets?.find(item => normalizedCompletionLanguage(item.langSlug) === normalizedCompletionLanguage(leetcodeWorkspaceLang));
    return snippet?.code || '';
  }

  function leetcodeWorkspaceCode() {
    const key = leetcodeWorkspaceDraftKey();
    if (leetcodeWorkspaceDrafts.has(key)) return leetcodeWorkspaceDrafts.get(key);
    const code = leetcodeWorkspaceTemplateCode();
    setLeetcodeWorkspaceDraft(code);
    return code;
  }

  function preferredLeetcodeWorkspaceLanguage(workspace) {
    const available = new Set((workspace?.languages || []).map(item => item.slug));
    const preferred = learningDashboard?.settings?.preferredLanguage || 'java';
    const candidates = preferred === 'python'
      ? ['python3', 'python']
      : preferred === 'javascript'
        ? ['javascript', 'typescript']
        : [preferred];
    return candidates.find(value => available.has(value))
      || workspace?.snippets?.find(item => available.has(item.langSlug))?.langSlug
      || workspace?.languages?.[0]?.slug
      || '';
  }

  function safeLeetcodeVideoSource(value) {
    try {
      const url = new URL(String(value || ''), 'https://leetcode.cn/');
      if (url.protocol !== 'https:') return null;
      const extension = url.pathname.match(/\.(mp4|webm)$/i)?.[1]?.toLowerCase();
      if (!extension) return null;
      return { url: url.href, type: `video/${extension}` };
    } catch (error) {
      return null;
    }
  }

  function safeLeetcodeVideoHtml(source) {
    const documentFragment = new DOMParser().parseFromString(String(source || ''), 'text/html');
    const video = documentFragment.querySelector('video');
    if (!video) return '';
    const candidates = [video.getAttribute('src'), ...[...video.querySelectorAll('source')].map(item => item.getAttribute('src'))];
    const sources = candidates.map(safeLeetcodeVideoSource).filter(Boolean);
    if (!sources.length) return '';
    return `<video class="leetcode-content-video" controls preload="metadata" playsinline>${sources.map(item => `<source src="${esc(item.url)}" type="${item.type}">`).join('')}</video>`;
  }

  function safeLeetcodeVideoUrlHtml(source) {
    const video = safeLeetcodeVideoSource(source);
    if (!video) return '';
    return `<video class="leetcode-content-video" controls preload="metadata" playsinline><source src="${esc(video.url)}" type="${video.type}"></video>`;
  }

  function sanitizeLeetcodeRichContent(source) {
    const sanitized = window.DOMPurify.sanitize(String(source || ''), {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ['script', 'style', 'iframe', 'form', 'input', 'button', 'object'],
      FORBID_ATTR: ['style', 'srcset'],
      ADD_TAGS: ['video', 'source'],
      ADD_ATTR: ['target', 'rel', 'controls', 'preload', 'playsinline', 'src', 'type']
    });
    const template = document.createElement('template');
    template.innerHTML = sanitized;
    for (const video of template.content.querySelectorAll('video')) {
      const safeVideo = safeLeetcodeVideoHtml(video.outerHTML);
      if (!safeVideo) video.remove();
      else video.outerHTML = safeVideo;
    }
    return template.innerHTML;
  }

  function renderLeetcodeSolutionContent(source) {
    const videos = [];
    const reserveVideo = video => {
      if (!video) return '';
      const token = `LEETCODEVIDEOTOKEN${videos.length}END`;
      videos.push({ token, video });
      return `\n\n${token}\n\n`;
    };
    let markdownSource = String(source || '')
      .replace(/<((?:!\[[^\]]*\]\([^\r\n)]+\)\s*,?\s*){2,})>/g, (_bundle, images) => `\n\n${images.replace(/\)\s*,\s*(?=!\[)/g, ')\n\n')}\n\n`)
      .replace(/<video\b[\s\S]*?<\/video\s*>/gi,
      candidate => reserveVideo(safeLeetcodeVideoHtml(candidate)));
    markdownSource = markdownSource.replace(/!\[([^\]]*)\]\(\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\)/gi,
      (_candidate, label, uuid) => reserveVideo(`<div class="leetcode-official-video" data-leetcode-video-uuid="${esc(uuid.toLowerCase())}"><span></span><strong>${esc(label || '正在获取官方视频')}</strong></div>`));
    markdownSource = markdownSource.replace(/!\[[^\]]*\]\(\s*(https:\/\/[^\s)]+\.(?:mp4|webm)(?:\?[^\s)]*)?)\s*(?:"[^"]*")?\s*\)/gi,
      (candidate, url) => reserveVideo(safeLeetcodeVideoUrlHtml(url)) || candidate);
    markdownSource = markdownSource.replace(/\[(?:\u89c6\u9891|video)[^\]]*\]\(\s*(https:\/\/[^\s)]+\.(?:mp4|webm)(?:\?[^\s)]*)?)\s*\)/gi,
      (candidate, url) => reserveVideo(safeLeetcodeVideoUrlHtml(url)) || candidate);
    markdownSource = markdownSource.replace(/^\s*(https:\/\/\S+\.(?:mp4|webm)(?:\?\S*)?)\s*$/gim,
      (candidate, url) => reserveVideo(safeLeetcodeVideoUrlHtml(url)) || candidate);
    let rendered = md(markdownSource);
    for (const { token, video } of videos) rendered = rendered.replaceAll(token, video);
    return sanitizeLeetcodeRichContent(rendered);
  }

  function sanitizeLeetcodeProblemContent(source) {
    return sanitizeLeetcodeRichContent(source);
  }

  function renderLeetcodeMath(container) {
    if (!container || !window.katex) return;
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (!node.nodeValue?.includes('$') || node.parentElement?.closest('code, pre, textarea, video, .katex')) continue;
      nodes.push(node);
    }
    const pattern = /\$\$([\s\S]+?)\$\$|\$([^$\n]+?)\$/g;
    for (const node of nodes) {
      const source = node.nodeValue;
      pattern.lastIndex = 0;
      let match;
      let cursor = 0;
      const fragment = document.createDocumentFragment();
      let rendered = false;
      while ((match = pattern.exec(source))) {
        const expression = (match[1] || match[2] || '').trim();
        if (!expression) continue;
        fragment.append(document.createTextNode(source.slice(cursor, match.index)));
        const math = document.createElement(match[1] ? 'div' : 'span');
        math.className = match[1] ? 'leetcode-math-display' : 'leetcode-math-inline';
        const markup = window.katex.renderToString(expression, {
          displayMode: Boolean(match[1]),
          throwOnError: false,
          strict: 'ignore',
          trust: false
        });
        math.innerHTML = window.DOMPurify.sanitize(markup, {
          USE_PROFILES: { html: true, mathMl: true }
        });
        fragment.append(math);
        cursor = pattern.lastIndex;
        rendered = true;
      }
      if (!rendered) continue;
      fragment.append(document.createTextNode(source.slice(cursor)));
      node.replaceWith(fragment);
    }
  }

  function stopLeetcodeGalleries(root) {
    for (const [gallery, timer] of leetcodeGalleryTimers) {
      if (!root || root.contains(gallery) || gallery === root || !gallery.isConnected) {
        clearInterval(timer);
        leetcodeGalleryTimers.delete(gallery);
      }
    }
  }

  function ensureLeetcodeVideoRuntime() {
    if (window.Aliplayer) return Promise.resolve(window.Aliplayer);
    if (leetcodeVideoRuntimePromise) return leetcodeVideoRuntimePromise;
    leetcodeVideoRuntimePromise = new Promise((resolve, reject) => {
      if (!document.querySelector('link[data-leetcode-video-runtime]')) {
        const stylesheet = document.createElement('link');
        stylesheet.rel = 'stylesheet';
        stylesheet.href = '../../.renderer-assets/aliyun-aliplayer/build/skins/default/aliplayer-min.css';
        stylesheet.dataset.leetcodeVideoRuntime = 'true';
        document.head.append(stylesheet);
      }
      const script = document.createElement('script');
      script.src = '../../.renderer-assets/aliyun-aliplayer/build/browser-aliplayer.min.js';
      script.async = true;
      script.dataset.leetcodeVideoRuntime = 'true';
      script.addEventListener('load', () => window.Aliplayer ? resolve(window.Aliplayer) : reject(new Error('视频播放器加载失败')), { once: true });
      script.addEventListener('error', () => reject(new Error('视频播放器加载失败')), { once: true });
      document.head.append(script);
    }).catch(error => {
      leetcodeVideoRuntimePromise = null;
      throw error;
    });
    return leetcodeVideoRuntimePromise;
  }

  function stopLeetcodeVideoPlayers(root) {
    for (const [container, player] of leetcodeVideoPlayers) {
      if (!root || root.contains(container) || container === root || !container.isConnected) {
        try { player.dispose(); } catch (error) {}
        leetcodeVideoPlayers.delete(container);
      }
    }
  }

  async function mountLeetcodeOfficialVideo(container) {
    const uuid = container?.dataset.leetcodeVideoUuid;
    if (!uuid || container.dataset.videoMounted === 'true') return;
    container.dataset.videoMounted = 'true';
    try {
      const [info, Aliplayer] = await Promise.all([
        window.api.getLeetCodeVideoInfo(uuid),
        ensureLeetcodeVideoRuntime()
      ]);
      if (!container.isConnected) return;
      const host = document.createElement('div');
      host.id = `leetcode-official-video-${++leetcodeVideoPlayerSequence}`;
      host.className = 'prism-player leetcode-official-video-player';
      if (info.width > 0 && info.height > 0) host.style.aspectRatio = `${info.width} / ${info.height}`;
      container.replaceChildren(host);
      container.classList.add('is-ready');
      const player = new Aliplayer({
        id: host.id,
        vid: info.videoId,
        playauth: info.playAuth,
        encryptType: 1,
        cover: info.coverUrl,
        autoplay: false,
        preload: true,
        playsinline: true,
        useH5Prism: true,
        assetPrefix: new URL('../../.renderer-assets/aliyun-aliplayer/build', window.location.href).href.replace(/\/$/, '')
      });
      leetcodeVideoPlayers.set(container, player);
      player.on('error', () => {
        if (!container.isConnected) return;
        container.classList.add('is-error');
      });
    } catch (error) {
      if (!container?.isConnected) return;
      container.classList.add('is-error');
      container.innerHTML = `<strong>官方视频暂时无法播放</strong><small>${esc(error?.message || '请稍后重试')}</small>`;
    }
  }

  function mountLeetcodeOfficialVideos(container) {
    for (const video of container?.querySelectorAll('[data-leetcode-video-uuid]') || []) {
      mountLeetcodeOfficialVideo(video).catch(error => console.warn('Failed to mount official LeetCode video:', error));
    }
  }

  function enhanceLeetcodeImageGalleries(container) {
    if (!container) return;
    const candidate = element => {
      const images = element.matches('img') ? [element] : [...element.querySelectorAll('img')];
      if (images.length !== 1) return false;
      return element.matches('img, figure') || !element.textContent.trim();
    };
    const spacer = element => {
      if (!element?.matches?.('p, br, hr')) return false;
      if (element.querySelector?.('img, video, pre, code')) return false;
      return /^[\s<>,，、;；:：'"〈〉《》]*$/u.test(element.textContent || '');
    };
    const parents = [container, ...container.querySelectorAll('article, section, div')].reverse();
    for (const parent of parents) {
      if (parent.closest('.leetcode-image-gallery') || !parent.isConnected) continue;
      const children = [...parent.children];
      for (let index = 0; index < children.length;) {
        if (!candidate(children[index])) { index += 1; continue; }
        let end = index;
        const run = [];
        const separators = [];
        while (end < children.length) {
          if (candidate(children[end])) run.push(children[end]);
          else if (run.length && spacer(children[end])) separators.push(children[end]);
          else break;
          end += 1;
        }
        index = end;
        if (run.length < 2 || run.some(item => !item.isConnected)) continue;
        const gallery = document.createElement('section');
        gallery.className = 'leetcode-image-gallery';
        gallery.dataset.index = '0';
        gallery.innerHTML = `<div class="leetcode-image-gallery-stage" tabindex="0" role="group" aria-roledescription="carousel" aria-label="图解，共 ${run.length} 张"><div class="leetcode-image-gallery-track"></div></div><footer><button type="button" data-gallery-action="previous" title="上一张" aria-label="上一张"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 18-6-6 6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button type="button" data-gallery-action="play" title="播放图集" aria-label="播放图集"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="m8 5 11 7-11 7V5Z"/></svg></button><span aria-live="polite">1 / ${run.length}</span><button type="button" data-gallery-action="next" title="下一张" aria-label="下一张"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="m9 18 6-6-6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button></footer>`;
        parent.insertBefore(gallery, run[0]);
        const stage = gallery.querySelector('.leetcode-image-gallery-stage');
        const track = gallery.querySelector('.leetcode-image-gallery-track');
        run.forEach((item, slideIndex) => {
          const slide = document.createElement('div');
          slide.className = 'leetcode-image-gallery-slide';
          slide.setAttribute('role', 'group');
          slide.setAttribute('aria-label', `第 ${slideIndex + 1} 张，共 ${run.length} 张`);
          slide.setAttribute('aria-hidden', slideIndex === 0 ? 'false' : 'true');
          slide.append(item);
          track.append(slide);
        });
        separators.forEach(element => element.remove());
        const show = requested => {
          const slides = [...track.children];
          const next = (requested + slides.length) % slides.length;
          slides.forEach((slide, slideIndex) => slide.setAttribute('aria-hidden', slideIndex === next ? 'false' : 'true'));
          track.style.transform = `translate3d(${-next * 100}%,0,0)`;
          gallery.dataset.index = String(next);
          gallery.querySelector('footer span').textContent = `${next + 1} / ${slides.length}`;
        };
        const stop = () => {
          clearInterval(leetcodeGalleryTimers.get(gallery));
          leetcodeGalleryTimers.delete(gallery);
          gallery.classList.remove('is-playing');
          gallery.querySelector('[data-gallery-action="play"]').title = '播放图集';
        };
        gallery.addEventListener('click', event => {
          const action = event.target.closest('[data-gallery-action]')?.dataset.galleryAction;
          if (!action) return;
          if (action === 'play') {
            if (leetcodeGalleryTimers.has(gallery)) stop();
            else {
              gallery.classList.add('is-playing');
              event.target.closest('button').title = '暂停播放';
              leetcodeGalleryTimers.set(gallery, setInterval(() => show(Number(gallery.dataset.index) + 1), 3200));
            }
            return;
          }
          stop();
          show(Number(gallery.dataset.index) + (action === 'next' ? 1 : -1));
        });
        let pointerStart = null;
        stage.addEventListener('pointerdown', event => {
          if (event.pointerType === 'mouse' && event.button !== 0) return;
          pointerStart = { id: event.pointerId, x: event.clientX, y: event.clientY };
          stage.setPointerCapture?.(event.pointerId);
          gallery.classList.add('is-dragging');
        });
        stage.addEventListener('pointerup', event => {
          if (!pointerStart || pointerStart.id !== event.pointerId) return;
          const deltaX = event.clientX - pointerStart.x;
          const deltaY = event.clientY - pointerStart.y;
          pointerStart = null;
          gallery.classList.remove('is-dragging');
          if (Math.abs(deltaX) < 36 || Math.abs(deltaX) <= Math.abs(deltaY)) return;
          stop();
          show(Number(gallery.dataset.index) + (deltaX < 0 ? 1 : -1));
        });
        stage.addEventListener('pointercancel', () => {
          pointerStart = null;
          gallery.classList.remove('is-dragging');
        });
        let lastWheelAt = 0;
        stage.addEventListener('wheel', event => {
          if (Math.abs(event.deltaX) <= Math.abs(event.deltaY) || Math.abs(event.deltaX) < 8) return;
          event.preventDefault();
          const now = performance.now();
          if (now - lastWheelAt < 360) return;
          lastWheelAt = now;
          stop();
          show(Number(gallery.dataset.index) + (event.deltaX > 0 ? 1 : -1));
        }, { passive: false });
        stage.addEventListener('keydown', event => {
          if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
          event.preventDefault();
          stop();
          show(Number(gallery.dataset.index) + (event.key === 'ArrowRight' ? 1 : -1));
        });
      }
    }
  }

  function enhanceLeetcodeRichContent(container) {
    renderLeetcodeMath(container);
    enhanceCodeLanguageTabs(container);
    enhanceLeetcodeImageGalleries(container);
    mountLeetcodeOfficialVideos(container);
  }

  function leetcodeSolutionList(slug = leetcodeWorkspace?.question?.titleSlug) {
    const payload = leetcodeWorkspaceSolutionLists.get(slug);
    if (Array.isArray(payload)) return payload;
    if (Array.isArray(payload?.items)) return payload.items;
    if (Array.isArray(payload?.solutions)) return payload.solutions;
    if (Array.isArray(payload?.articles)) return payload.articles;
    if (Array.isArray(payload?.edges)) return payload.edges.map(edge => edge?.node).filter(Boolean);
    return [];
  }

  function leetcodeProblemPaneHeaderHtml() {
    return `<div class="leetcode-problem-tabs" role="tablist" aria-label="题目内容">
      <button type="button" role="tab" aria-selected="${leetcodeWorkspaceProblemTab === 'problem'}" class="${leetcodeWorkspaceProblemTab === 'problem' ? 'active' : ''}" data-leetcode-problem-tab="problem">题目</button>
      <button type="button" role="tab" aria-selected="${leetcodeWorkspaceProblemTab === 'solutions'}" class="${leetcodeWorkspaceProblemTab === 'solutions' ? 'active' : ''}" data-leetcode-problem-tab="solutions">题解</button>
    </div>`;
  }

  function leetcodeSolutionsHtml() {
    if (leetcodeWorkspaceSolutionsBusy === 'list') {
      return '<div class="leetcode-solutions-state"><span></span><strong>正在读取题解</strong></div>';
    }
    if (leetcodeWorkspaceSolutionsError) {
      return `<div class="leetcode-solutions-state is-error"><strong>${esc(leetcodeWorkspaceSolutionsError)}</strong><button type="button" data-leetcode-solution-action="retry-list">重试</button></div>`;
    }
    if (leetcodeWorkspaceSolutionSlug) {
      if (leetcodeWorkspaceSolutionsBusy === 'detail') {
        return '<div class="leetcode-solutions-state"><span></span><strong>正在打开题解</strong></div>';
      }
      const detail = leetcodeWorkspaceSolutionDetails.get(leetcodeWorkspaceSolutionSlug);
      if (!detail) {
        return '<div class="leetcode-solutions-state is-error"><strong>题解内容暂时不可用</strong><button type="button" data-leetcode-solution-action="back-list">返回列表</button></div>';
      }
      const tags = (detail.tags || []).map(tag => typeof tag === 'string' ? tag : (tag.nameTranslated || tag.name)).filter(Boolean);
      const listPayload = leetcodeWorkspaceSolutionLists.get(leetcodeWorkspace?.question?.titleSlug);
      const summary = leetcodeSolutionList().find(item => (item.slug || item.uuid) === leetcodeWorkspaceSolutionSlug);
      const official = Boolean(summary?.official || summary?.byLeetcode || summary?.isOfficial
        || listPayload?.officialSolutionSlug === leetcodeWorkspaceSolutionSlug);
      return `<article class="leetcode-solution-detail"><header><button type="button" data-leetcode-solution-action="back-list" aria-label="返回题解列表" title="返回题解列表"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 18-6-6 6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div><div class="leetcode-solution-title"><strong>${esc(detail.title || '题解')}</strong>${official ? '<em>官方</em>' : ''}</div>${tags.length ? `<span>${esc(tags.slice(0, 4).join(' · '))}</span>` : ''}</div></header><div class="leetcode-solution-markdown">${renderLeetcodeSolutionContent(detail.content || detail.markdown || '')}</div></article>`;
    }
    const items = leetcodeSolutionList();
    if (!items.length) return '<div class="leetcode-solutions-state"><strong>暂时没有可显示的公开题解</strong></div>';
    return `<div class="leetcode-solution-list">${items.map(item => {
      const author = item.author?.realName || item.author?.profile?.realName || item.author?.username || item.authorName || '力扣用户';
      const views = Number(item.hitCount || item.topic?.views || item.topic?.viewCount || item.viewCount) || 0;
      const votes = Number(item.upvoteCount) || 0;
      const official = Boolean(item.official || item.byLeetcode || item.isOfficial);
      const featured = Boolean(item.editorsPick || item.isEditorsPick);
      const badge = official ? '官方' : (featured ? '精选' : '');
      return `<button type="button" data-leetcode-solution="${esc(item.slug || item.uuid)}"><span><strong>${esc(item.title || '未命名题解')}</strong>${badge ? `<em>${badge}</em>` : ''}</span>${item.summary ? `<p>${esc(item.summary)}</p>` : ''}<small>${esc(author)}${votes ? ` · ${numberFormatter.format(votes)} 赞` : ''}${views ? ` · ${numberFormatter.format(views)} 阅读` : ''}</small></button>`;
    }).join('')}</div>`;
  }

  function leetcodeProblemPaneBodyHtml() {
    if (leetcodeWorkspaceProblemTab === 'solutions') return leetcodeSolutionsHtml();
    const content = sanitizeLeetcodeProblemContent(leetcodeWorkspace?.question?.content);
    return `<article class="leetcode-problem-article">${content || '<p>题面暂时无法显示，可从右上角打开力扣原题。</p>'}</article>`;
  }

  function leetcodeWorkspaceNavigation() {
    const questions = (leetcodeDashboard?.questions || []).filter(question => question?.titleSlug);
    const index = questions.findIndex(question => question.titleSlug === leetcodeCurrentSlug());
    return {
      index,
      total: questions.length,
      previous: index > 0 ? questions[index - 1] : null,
      next: index >= 0 && index < questions.length - 1 ? questions[index + 1] : null
    };
  }

  function leetcodeQuestionStepLabel(prefix, question) {
    if (!question) return prefix === '上一题' ? '已经是第一题' : '已经是最后一题';
    const identity = question.frontendId ? `${question.frontendId}. ` : '';
    return `${prefix}：${identity}${question.translatedTitle || question.title || question.titleSlug}`;
  }

  function refreshLeetcodeProblemPane() {
    const pane = document.querySelector('.leetcode-problem-pane');
    if (!pane) return;
    const header = pane.querySelector(':scope > header');
    const body = pane.querySelector('.leetcode-problem-body');
    if (header) header.innerHTML = leetcodeProblemPaneHeaderHtml();
    if (body) {
      stopLeetcodeGalleries(body);
      stopLeetcodeVideoPlayers(body);
      body.innerHTML = leetcodeProblemPaneBodyHtml();
      enhanceLeetcodeRichContent(body);
    }
  }

  async function loadLeetcodeSolutions({ force = false } = {}) {
    const slug = leetcodeWorkspace?.question?.titleSlug;
    if (!slug || leetcodeWorkspaceSolutionsBusy) return;
    leetcodeWorkspaceProblemTab = 'solutions';
    leetcodeWorkspaceSolutionSlug = '';
    leetcodeWorkspaceSolutionsError = '';
    if (!force && leetcodeWorkspaceSolutionLists.has(slug)) {
      refreshLeetcodeProblemPane();
      return;
    }
    leetcodeWorkspaceSolutionsBusy = 'list';
    refreshLeetcodeProblemPane();
    try {
      const result = await window.api.getLeetCodeSolutions(slug);
      if (leetcodeWorkspace?.question?.titleSlug !== slug) return;
      leetcodeWorkspaceSolutionLists.set(slug, result);
    } catch (error) {
      leetcodeWorkspaceSolutionsError = error?.message || '题解列表加载失败';
    } finally {
      if (leetcodeWorkspace?.question?.titleSlug === slug) {
        leetcodeWorkspaceSolutionsBusy = '';
        refreshLeetcodeProblemPane();
      }
    }
  }

  async function openLeetcodeSolution(solutionSlug) {
    const slug = String(solutionSlug || '');
    if (!slug || leetcodeWorkspaceSolutionsBusy) return;
    leetcodeWorkspaceProblemTab = 'solutions';
    leetcodeWorkspaceSolutionSlug = slug;
    leetcodeWorkspaceSolutionsError = '';
    if (leetcodeWorkspaceSolutionDetails.has(slug)) {
      refreshLeetcodeProblemPane();
      return;
    }
    leetcodeWorkspaceSolutionsBusy = 'detail';
    refreshLeetcodeProblemPane();
    try {
      const detail = await window.api.getLeetCodeSolution(slug);
      if (leetcodeWorkspaceSolutionSlug !== slug) return;
      leetcodeWorkspaceSolutionDetails.set(slug, detail);
    } catch (error) {
      if (leetcodeWorkspaceSolutionSlug === slug) leetcodeWorkspaceSolutionsError = error?.message || '题解内容加载失败';
    } finally {
      if (leetcodeWorkspaceSolutionSlug === slug) {
        leetcodeWorkspaceSolutionsBusy = '';
        refreshLeetcodeProblemPane();
      }
    }
  }

  function leetcodeExecutionResultTone(result) {
    if (result?.accepted) return 'accepted';
    if (result?.kind === 'syntax' || result?.compileError) return 'compile';
    if (result?.runtimeError) return 'runtime';
    return /time limit|超时/i.test(String(result?.status || '')) ? 'timeout' : 'wrong';
  }

  function leetcodeExecutionResultDetail(result) {
    if (!result) return '';
    const parts = [];
    if (result.totalTestcases) parts.push(`${result.totalCorrect || 0} / ${result.totalTestcases} 个用例`);
    else if (result.accepted) parts.push('全部测试通过');
    if (result.runtime) parts.push(`耗时 ${result.runtime}`);
    if (result.memory) parts.push(`内存 ${result.memory}`);
    if (!parts.length && result.compileError) parts.push(String(result.compileError).split('\n')[0]);
    if (!parts.length && result.runtimeError) parts.push(String(result.runtimeError).split('\n')[0]);
    return parts.join(' · ').slice(0, 180);
  }

  function leetcodeExecutionNoticeHtml() {
    const notice = leetcodeExecutionNotice;
    if (!notice) return '';
    const result = notice.result;
    const pending = !result || notice.phase === 'syncing';
    const state = result?.accepted ? 'accepted' : (result ? 'failed' : 'pending');
    const actionLabel = notice.action === 'submit' ? '提交判题' : '运行代码';
    const elapsed = Math.max(0, Math.floor((notice.elapsedMs || Date.now() - notice.startedAt) / 1000));
    const detail = notice.detail || (pending ? `已等待 ${elapsed} 秒` : leetcodeExecutionResultDetail(result));
    const status = result?.status || notice.title || (notice.action === 'submit' ? '正在提交到力扣' : '正在运行官方样例');
    return `<div class="leetcode-execution-notice${notice.leaving ? ' is-leaving' : ''}" data-state="${state}" data-tone="${esc(result ? leetcodeExecutionResultTone(result) : '')}" role="status" aria-live="polite">
      <span class="leetcode-execution-symbol" aria-hidden="true"><i></i></span>
      <span class="leetcode-execution-copy"><small>${actionLabel}</small><strong>${esc(status)}</strong><em>${esc(detail)}</em></span>
      ${pending ? '<span class="leetcode-execution-motion" aria-hidden="true"><i></i><i></i><i></i></span>' : ''}
    </div>`;
  }

  function renderLeetcodeExecutionNotice() {
    const slot = document.querySelector('.leetcode-execution-notice-slot');
    if (slot) slot.innerHTML = leetcodeExecutionNoticeHtml();
  }

  function clearLeetcodeExecutionTimers() {
    if (leetcodeExecutionNoticeTimer) clearTimeout(leetcodeExecutionNoticeTimer);
    if (leetcodeExecutionNoticeTicker) clearInterval(leetcodeExecutionNoticeTicker);
    leetcodeExecutionNoticeTimer = 0;
    leetcodeExecutionNoticeTicker = 0;
  }

  function startLeetcodeExecutionNotice(action, requestId) {
    clearLeetcodeExecutionTimers();
    leetcodeExecutionNotice = {
      action,
      requestId,
      phase: 'uploading',
      title: action === 'submit' ? '正在上传提交' : '正在发送测试代码',
      detail: '正在连接力扣判题服务',
      startedAt: Date.now(),
      elapsedMs: 0,
      result: null,
      leaving: false
    };
    renderLeetcodeExecutionNotice();
    leetcodeExecutionNoticeTicker = setInterval(() => {
      if (!leetcodeExecutionNotice || leetcodeExecutionNotice.requestId !== requestId || leetcodeExecutionNotice.result) return;
      leetcodeExecutionNotice.elapsedMs = Date.now() - leetcodeExecutionNotice.startedAt;
      renderLeetcodeExecutionNotice();
    }, 1000);
  }

  function updateLeetcodeExecutionNotice(requestId, progress = {}) {
    const notice = leetcodeExecutionNotice;
    if (!notice || notice.requestId !== requestId) return;
    const phase = String(progress.phase || 'judging');
    const labels = {
      queued: notice.action === 'submit' ? '提交成功，等待判题' : '代码已送达，等待运行',
      judging: '力扣正在判题',
      result: progress.result?.accepted ? '判题通过' : '判题已返回',
      syncing: progress.result?.accepted ? '已通过，正在同步轨迹' : '已返回，正在同步轨迹'
    };
    notice.phase = phase;
    notice.title = labels[phase] || notice.title;
    notice.elapsedMs = Math.max(0, Number(progress.elapsedMs) || Date.now() - notice.startedAt);
    if (progress.result) notice.result = progress.result;
    if (phase === 'judging') {
      const attempt = Math.max(1, Number(progress.attempt) || 1);
      const remoteStatus = String(progress.status || '').trim();
      notice.detail = remoteStatus && !/pending|started/i.test(remoteStatus)
        ? remoteStatus
        : `第 ${attempt} 次获取判题状态 · ${Math.floor(notice.elapsedMs / 1000)} 秒`;
    } else if (progress.result) {
      notice.detail = leetcodeExecutionResultDetail(progress.result) || '判题结果已返回';
    } else if (phase === 'queued') {
      notice.detail = `任务已创建 · ${Math.floor(notice.elapsedMs / 1000)} 秒`;
    }
    renderLeetcodeExecutionNotice();
  }

  function finishLeetcodeExecutionNotice(action, result, requestId = '') {
    const notice = leetcodeExecutionNotice;
    if (!notice || (requestId && notice.requestId !== requestId)) {
      startLeetcodeExecutionNotice(action, requestId || `local-${Date.now()}`);
    }
    if (leetcodeExecutionNoticeTicker) clearInterval(leetcodeExecutionNoticeTicker);
    leetcodeExecutionNoticeTicker = 0;
    leetcodeExecutionNotice.phase = 'complete';
    leetcodeExecutionNotice.result = result;
    leetcodeExecutionNotice.title = result?.status || (result?.accepted ? '通过' : '未通过');
    leetcodeExecutionNotice.detail = leetcodeExecutionResultDetail(result) || '判题结果已返回';
    leetcodeExecutionNotice.elapsedMs = Date.now() - leetcodeExecutionNotice.startedAt;
    renderLeetcodeExecutionNotice();
    const completedRequestId = leetcodeExecutionNotice.requestId;
    leetcodeExecutionNoticeTimer = setTimeout(() => {
      if (leetcodeExecutionNotice?.requestId !== completedRequestId) return;
      leetcodeExecutionNotice.leaving = true;
      renderLeetcodeExecutionNotice();
      leetcodeExecutionNoticeTimer = setTimeout(() => {
        if (leetcodeExecutionNotice?.requestId === completedRequestId) {
          leetcodeExecutionNotice = null;
          renderLeetcodeExecutionNotice();
        }
        leetcodeExecutionNoticeTimer = 0;
      }, 220);
    }, 2800);
  }

  function leetcodeWorkspaceResultHtml(result) {
    if (!result) return '<div class="leetcode-judge-empty">等待运行</div>';
    const count = result.totalTestcases
      ? `${result.totalCorrect} / ${result.totalTestcases}`
      : (result.accepted ? '全部通过' : '未返回样例计数');
    const tone = leetcodeExecutionResultTone(result);
    const context = result.kind === 'syntax' ? '运行前检查' : (result.kind === 'submit' ? '提交结果' : '运行结果');
    const diagnostics = [
      ['编译信息', result.compileError],
      ['运行错误', result.runtimeError],
      ['输入', result.input],
      ['实际输出', result.output],
      ['预期输出', result.expectedOutput]
    ].filter(([, value]) => value);
    return `<div class="leetcode-judge-result" data-tone="${tone}" data-accepted="${result.accepted ? 'true' : 'false'}">
      <header><div><i></i><span><small>${context}</small><strong>${esc(result.status || (result.accepted ? '通过' : '未通过'))}</strong></span></div><b>${esc(count)}</b></header>
      ${result.runtime || result.memory ? `<div class="leetcode-judge-metrics">${result.runtime ? `<span><small>耗时</small>${esc(result.runtime)}</span>` : ''}${result.memory ? `<span><small>内存</small>${esc(result.memory)}</span>` : ''}</div>` : ''}
      ${diagnostics.length ? `<div class="leetcode-judge-diagnostics">${diagnostics.map(([label, value]) => `<section><span>${label}</span><pre>${esc(value)}</pre></section>`).join('')}</div>` : ''}
      ${result.aiJudgeMessage ? `<p class="leetcode-judge-message">${esc(result.aiJudgeMessage)}</p>` : ''}
      ${leetcodeWorkspaceAnalysis ? `<section class="leetcode-code-analysis"><header><span>AI 分析</span><strong>${esc(leetcodeWorkspaceAnalysis.rootCause || '已完成诊断')}</strong></header><p>${esc(leetcodeWorkspaceAnalysis.summary || '')}</p>${leetcodeWorkspaceAnalysis.evidence?.length ? `<div><span>判断依据</span>${leetcodeWorkspaceAnalysis.evidence.map(item => `<small>${esc(item)}</small>`).join('')}</div>` : ''}${leetcodeWorkspaceAnalysis.suggestions?.length ? `<div><span>修复顺序</span>${leetcodeWorkspaceAnalysis.suggestions.map(item => `<small>${esc(item)}</small>`).join('')}</div>` : ''}</section>` : ''}
      ${result.kind === 'submit' && !result.accepted && !leetcodeWorkspaceAnalysis ? `<footer><button type="button" data-leetcode-workspace-action="analyze" ${leetcodeWorkspaceBusy ? 'disabled' : ''}>AI 分析错误</button></footer>` : ''}
    </div>`;
  }

  function refreshLeetcodeWorkspaceExecutionUi() {
    if (!leetcodeIsWorkspace() || !document.querySelector('.leetcode-workspace')) return;
    const errorSlot = document.querySelector('.leetcode-workspace-error-slot');
    if (errorSlot) {
      errorSlot.textContent = leetcodeWorkspaceError;
      errorSlot.hidden = !leetcodeWorkspaceError;
    }
    const judgePane = document.querySelector('.leetcode-judge-pane');
    if (judgePane) {
      const status = leetcodeWorkspaceBusy === 'run'
        ? '正在运行官方样例'
        : leetcodeWorkspaceBusy === 'submit'
          ? '正在提交并等待判题'
          : leetcodeWorkspaceBusy === 'analyze' ? '正在分析失败原因' : '';
      const body = ['run', 'submit'].includes(leetcodeWorkspaceBusy)
        ? '<div class="leetcode-judge-loading"><span></span>力扣判题中</div>'
        : leetcodeWorkspaceResultHtml(leetcodeWorkspaceResult);
      judgePane.innerHTML = `<header><strong>判题反馈</strong><span>${status}</span></header>${body}`;
    }
    const busy = Boolean(leetcodeWorkspaceBusy);
    const language = document.querySelector('#leetcode-workspace-language');
    if (language) language.disabled = busy;
    const runButton = document.querySelector('[data-leetcode-workspace-action="run"]');
    const submitButton = document.querySelector('[data-leetcode-workspace-action="submit"]');
    if (runButton) runButton.disabled = busy || !leetcodeWorkspace?.question?.enableRunCode;
    if (submitButton) submitButton.disabled = busy || !leetcodeWorkspace?.question?.enableSubmit;
    renderLeetcodeExecutionNotice();
  }

  function clearLeetcodeSyntaxDiagnostics(editor = activeLeetcodeEditor) {
    for (const marker of leetcodeSyntaxMarkers) marker?.clear?.();
    leetcodeSyntaxMarkers = [];
    editor?.clearGutter?.('CodeMirror-lint-markers');
  }

  function setLeetcodeSyntaxStatus(state, label, title = '') {
    const status = $('#leetcode-code-status');
    if (!status) return;
    status.dataset.state = state;
    status.setAttribute('aria-label', label);
    status.title = title || label;
    const text = status.querySelector('b');
    if (text) text.textContent = label;
  }

  function applyLeetcodeSyntaxDiagnostics(editor, result) {
    clearLeetcodeSyntaxDiagnostics(editor);
    leetcodeSyntaxResult = result;
    if (!result?.supported) {
      setLeetcodeSyntaxStatus('unsupported', '语法检查不可用');
      return [];
    }
    const diagnostics = Array.isArray(result.diagnostics) ? result.diagnostics : [];
    if (!diagnostics.length) {
      setLeetcodeSyntaxStatus('valid', '可以运行');
      return diagnostics;
    }
    const lineMessages = new Map();
    const documentLength = editor.getValue().length;
    for (const diagnostic of diagnostics) {
      const fromIndex = Math.max(0, Math.min(documentLength, Number(diagnostic.from) || 0));
      const toIndex = Math.max(fromIndex, Math.min(documentLength, Number(diagnostic.to) || fromIndex));
      const from = editor.posFromIndex(fromIndex);
      const to = editor.posFromIndex(toIndex);
      if (toIndex > fromIndex) {
        leetcodeSyntaxMarkers.push(editor.markText(from, to, {
          className: 'learning-syntax-error',
          title: diagnostic.message
        }));
      } else {
        const widget = document.createElement('span');
        widget.className = 'learning-syntax-caret';
        widget.title = diagnostic.message;
        leetcodeSyntaxMarkers.push(editor.setBookmark(from, { widget, insertLeft: true }));
      }
      const messages = lineMessages.get(from.line) || [];
      messages.push(diagnostic.message);
      lineMessages.set(from.line, messages);
    }
    for (const [line, messages] of lineMessages) {
      const marker = document.createElement('span');
      marker.className = 'learning-syntax-gutter-marker';
      marker.title = messages.join('\n');
      editor.setGutterMarker(line, 'CodeMirror-lint-markers', marker);
    }
    setLeetcodeSyntaxStatus('invalid', `${diagnostics.length} 处语法问题`, diagnostics.map(item => item.message).join('\n'));
    return diagnostics;
  }

  async function validateLeetcodeWorkspaceSyntax({ focusFirst = false } = {}) {
    const editor = activeLeetcodeEditor;
    if (!editor) return { supported: false, diagnostics: [] };
    const source = editor.getValue();
    const generation = ++leetcodeSyntaxGeneration;
    setLeetcodeSyntaxStatus('checking', '正在检查');
    try {
      const result = await window.api.validateLearningCode(normalizedCompletionLanguage(leetcodeWorkspaceLang), source);
      if (generation !== leetcodeSyntaxGeneration || editor !== activeLeetcodeEditor || source !== editor.getValue()) return null;
      const diagnostics = applyLeetcodeSyntaxDiagnostics(editor, result);
      if (focusFirst && diagnostics.length) {
        const first = Math.max(0, Number(diagnostics[0].from) || 0);
        editor.focus();
        editor.setCursor(editor.posFromIndex(first));
        editor.scrollIntoView(editor.posFromIndex(first), 80);
      }
      return result;
    } catch (error) {
      if (generation !== leetcodeSyntaxGeneration || editor !== activeLeetcodeEditor) return null;
      clearLeetcodeSyntaxDiagnostics(editor);
      leetcodeSyntaxResult = null;
      setLeetcodeSyntaxStatus('unsupported', '检查不可用', error?.message || '本地语法检查失败');
      return { supported: false, diagnostics: [] };
    }
  }

  function scheduleLeetcodeSyntaxCheck(editor, immediate = false) {
    clearTimeout(leetcodeSyntaxTimer);
    const generation = ++leetcodeSyntaxGeneration;
    if (!editor.getValue().trim()) {
      clearLeetcodeSyntaxDiagnostics(editor);
      leetcodeSyntaxResult = null;
      setLeetcodeSyntaxStatus('idle', '等待输入');
      return;
    }
    setLeetcodeSyntaxStatus('checking', '正在检查');
    leetcodeSyntaxTimer = setTimeout(async () => {
      if (generation !== leetcodeSyntaxGeneration || editor !== activeLeetcodeEditor) return;
      await validateLeetcodeWorkspaceSyntax();
    }, immediate ? 0 : 320);
  }

  async function bindLeetcodeWorkspaceEditor() {
    const textarea = $('#leetcode-workspace-code');
    destroyActiveLeetcodeEditor();
    if (!textarea) return;
    await ensureCodeEditorRuntime();
    if (!textarea.isConnected || textarea !== $('#leetcode-workspace-code') || !window.CodeMirror) return;
    activeLeetcodeEditor = window.CodeMirror.fromTextArea(textarea, {
      mode: leetcodeEditorMode(leetcodeWorkspaceLang),
      lineNumbers: true,
      gutters: ['CodeMirror-lint-markers', 'CodeMirror-linenumbers'],
      indentUnit: 4,
      tabSize: 4,
      indentWithTabs: false,
      smartIndent: true,
      electricChars: true,
      matchBrackets: true,
      autoCloseBrackets: true,
      lineWrapping: false,
      viewportMargin: 30,
      extraKeys: {
        Tab: editor => editor.somethingSelected() ? editor.indentSelection('add') : editor.execCommand('insertSoftTab'),
        'Shift-Tab': editor => editor.indentSelection('subtract')
      }
    });
    activeLeetcodeEditor.setSize(null, '100%');
    activeLeetcodeEditor.on('change', editor => {
      setLeetcodeWorkspaceDraft(editor.getValue());
      scheduleLeetcodeSyntaxCheck(editor);
    });
    leetcodeEditorCompletionCleanup = installCodeCompletion(activeLeetcodeEditor, leetcodeWorkspaceLang);
    scheduleLeetcodeSyntaxCheck(activeLeetcodeEditor, true);
    requestAnimationFrame(() => activeLeetcodeEditor?.refresh());
  }

  function renderLeetcodeWorkspace() {
    hideLeetcodeHeatmapTooltip();
    destroyLeetcodeWorkspaceSplit();
    destroyActiveLeetcodeEditor();
    const content = $('#learning-content');
    stopLeetcodeGalleries(content);
    stopLeetcodeVideoPlayers(content);
    content.scrollLeft = 0;
    if (!leetcodeWorkspace) {
      content.innerHTML = `<div class="leetcode-workspace-empty"><button type="button" data-leetcode-workspace-action="back" title="返回题目复盘" aria-label="返回题目复盘"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 18-6-6 6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div>${leetcodeWorkspaceBusy === 'loading' ? '<span></span>' : '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="12" r="9"/><path d="M12 7v6m0 4h.01" stroke-linecap="round"/></svg>'}<strong>${esc(leetcodeWorkspaceError || '正在加载题目')}</strong>${leetcodeWorkspaceBusy === 'loading' ? '' : '<button type="button" data-leetcode-workspace-action="retry">重新加载</button>'}</div></div>`;
      return;
    }
    const question = leetcodeWorkspace.question;
    const code = leetcodeWorkspaceCode();
    const examples = question.exampleTestcases || [];
    const topicTags = (question.topicTags || []).slice(0, 3).map(tag => tag.name).filter(Boolean);
    const difficulty = String(question.difficulty || '').toUpperCase();
    const navigation = leetcodeWorkspaceNavigation();
    const navigationBusy = Boolean(leetcodeWorkspaceBusy);
    const previousLabel = leetcodeQuestionStepLabel('上一题', navigation.previous);
    const nextLabel = leetcodeQuestionStepLabel('下一题', navigation.next);
    const navigationHtml = `<div class="leetcode-workspace-header-actions"><div class="leetcode-question-stepper" role="group" aria-label="题目切换"><button type="button" data-leetcode-workspace-action="previous-question" title="${esc(previousLabel)}" aria-label="${esc(previousLabel)}" ${!navigation.previous || navigationBusy ? 'disabled' : ''}><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 18-6-6 6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><output aria-label="当前题目进度">${navigation.index >= 0 ? navigation.index + 1 : '–'} / ${navigation.total || '–'}</output><button type="button" data-leetcode-workspace-action="next-question" title="${esc(nextLabel)}" aria-label="${esc(nextLabel)}" ${!navigation.next || navigationBusy ? 'disabled' : ''}><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m9 6 6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div><button class="leetcode-workspace-open" type="button" data-leetcode-action="open-problem" title="在力扣打开" aria-label="在力扣打开"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M14 5h5v5M10 14 19 5M19 14v5H5V5h5" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div>`;
    content.innerHTML = `<div class="leetcode-workspace">
      <header class="leetcode-workspace-header"><button type="button" data-leetcode-workspace-action="back" title="返回题目复盘" aria-label="返回题目复盘"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 18-6-6 6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div><strong>${esc(question.frontendId)}. ${esc(question.translatedTitle || question.title)}</strong><div class="leetcode-workspace-meta"><b data-difficulty="${esc(difficulty)}">${esc(leetcodeDifficultyLabel(question.difficulty))}</b>${(topicTags.length ? topicTags : ['力扣题目']).map(tag => `<span>${esc(tag)}</span>`).join('')}</div></div>${navigationHtml}</header>
      <div class="leetcode-execution-notice-slot">${leetcodeExecutionNoticeHtml()}</div>
      <div class="leetcode-workspace-error-slot leetcode-inline-error" ${leetcodeWorkspaceError ? '' : 'hidden'}>${esc(leetcodeWorkspaceError)}</div>
      <div class="leetcode-workspace-grid">
        <section class="leetcode-problem-pane"><header>${leetcodeProblemPaneHeaderHtml()}</header><div class="leetcode-problem-body">${leetcodeProblemPaneBodyHtml()}</div></section>
        <section class="leetcode-code-pane">
          <header><label><span>语言</span><select id="leetcode-workspace-language" ${leetcodeWorkspaceBusy ? 'disabled' : ''}>${leetcodeWorkspace.languages.map(language => `<option value="${esc(language.slug)}" ${language.slug === leetcodeWorkspaceLang ? 'selected' : ''}>${esc(language.name)}</option>`).join('')}</select></label><div class="leetcode-editor-tools"><span class="leetcode-code-status" id="leetcode-code-status" data-state="checking" role="status" aria-live="polite"><i></i><b>正在检查</b></span><button type="button" data-leetcode-workspace-action="complete" title="显示代码补全" aria-label="显示代码补全"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 6h14M5 12h9M5 18h6" stroke-linecap="round"/><path d="m16 16 2 2 4-5" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button type="button" data-leetcode-workspace-action="format" title="一键格式化" aria-label="一键格式化"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 7h16M4 12h11M4 17h16" stroke-linecap="round"/></svg></button><button type="button" data-leetcode-workspace-action="reset-code" title="还原官方代码模板" aria-label="还原官方代码模板"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 8v5h5" stroke-linecap="round" stroke-linejoin="round"/><path d="M5.5 13A7 7 0 1 0 7 6.5L4 9" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div></header>
          <div class="leetcode-code-workarea">
            <div class="leetcode-workspace-editor"><textarea id="leetcode-workspace-code" aria-label="力扣代码编辑器">${esc(code)}</textarea></div>
            <div class="leetcode-code-feedback">
              <section class="leetcode-testcase-pane"><header><strong>官方样例</strong>${examples.length ? `<div>${examples.map((_, index) => `<button type="button" data-leetcode-example="${index}" class="${leetcodeWorkspaceTestcase === examples[index] ? 'active' : ''}">${index + 1}</button>`).join('')}</div>` : ''}</header><textarea id="leetcode-workspace-testcase" aria-label="测试用例输入" placeholder="输入符合题目参数格式的测试数据">${esc(leetcodeWorkspaceTestcase)}</textarea></section>
              <section class="leetcode-judge-pane" aria-live="polite"><header><strong>判题反馈</strong><span>${leetcodeWorkspaceBusy === 'run' ? '正在运行官方样例' : leetcodeWorkspaceBusy === 'submit' ? '正在提交并等待判题' : ''}</span></header>${leetcodeWorkspaceBusy === 'run' || leetcodeWorkspaceBusy === 'submit' ? '<div class="leetcode-judge-loading"><span></span>力扣判题中</div>' : leetcodeWorkspaceResultHtml(leetcodeWorkspaceResult)}</section>
            </div>
          </div>
          <footer class="leetcode-workspace-actions"><button type="button" data-leetcode-workspace-action="run" ${leetcodeWorkspaceBusy || !question.enableRunCode ? 'disabled' : ''}><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="m8 5 11 7-11 7V5Z"/></svg>运行</button><button class="is-primary" type="button" data-leetcode-workspace-action="submit" ${leetcodeWorkspaceBusy || !question.enableSubmit ? 'disabled' : ''}><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="m5 12 4 4L19 6" stroke-linecap="round" stroke-linejoin="round"/></svg>提交</button></footer>
        </section>
      </div>
    </div>`;
    enhanceLeetcodeRichContent(content.querySelector('.leetcode-problem-body'));
    bindLeetcodeWorkspaceEditor().catch(error => {
      leetcodeWorkspaceError = error?.message || '代码编辑器加载失败';
    });
    bindLeetcodeWorkspaceSplit().catch(error => {
      console.warn('Failed to initialize LeetCode workspace split:', error);
    });
  }

  async function openLeetcodeWorkspace() {
    const slug = leetcodeCurrentSlug();
    if (!slug || ['run', 'submit', 'analyze', 'format'].includes(leetcodeWorkspaceBusy)) return;
    const generation = ++leetcodeWorkspaceRequestGeneration;
    // Preserve the current editor under its original question before swapping workspaces.
    destroyActiveLeetcodeEditor();
    setLeetcodeRoute('workspace');
    leetcodeWorkspace = leetcodeQuestionWorkspaces.get(slug) || null;
    leetcodeWorkspaceResult = null;
    leetcodeWorkspaceAnalysis = null;
    leetcodeWorkspaceProblemTab = 'problem';
    leetcodeWorkspaceSolutionSlug = '';
    leetcodeWorkspaceSolutionsBusy = '';
    leetcodeWorkspaceSolutionsError = '';
    leetcodeWorkspaceError = '';
    leetcodeWorkspaceBusy = leetcodeWorkspace ? '' : 'loading';
    if (leetcodeWorkspace) {
      const available = new Set(leetcodeWorkspace.languages.map(language => language.slug));
      if (!available.has(leetcodeWorkspaceLang)) leetcodeWorkspaceLang = preferredLeetcodeWorkspaceLanguage(leetcodeWorkspace);
      if (!leetcodeWorkspaceTestcase) leetcodeWorkspaceTestcase = leetcodeWorkspace.question.exampleTestcases?.[0] || '';
    }
    renderLeetcodeWorkspace();
    if (leetcodeWorkspace) return;
    try {
      const workspace = await loadLeetcodeQuestionWorkspace(slug);
      if (generation !== leetcodeWorkspaceRequestGeneration || !leetcodeIsWorkspace() || leetcodeCurrentSlug() !== slug) return;
      leetcodeWorkspace = workspace;
      leetcodeWorkspaceLang = preferredLeetcodeWorkspaceLanguage(leetcodeWorkspace);
      leetcodeWorkspaceTestcase = leetcodeWorkspace.question.exampleTestcases?.[0] || '';
    } catch (error) {
      if (generation === leetcodeWorkspaceRequestGeneration && leetcodeIsWorkspace() && leetcodeCurrentSlug() === slug) {
        leetcodeWorkspaceError = error?.message || '题目加载失败';
      }
    } finally {
      if (generation === leetcodeWorkspaceRequestGeneration && leetcodeIsWorkspace() && leetcodeCurrentSlug() === slug) {
        leetcodeWorkspaceBusy = '';
        if (learningTab === 'leetcode') renderLeetcode();
      }
    }
  }

  async function moveLeetcodeWorkspaceQuestion(direction) {
    if (leetcodeWorkspaceBusy) return;
    const navigation = leetcodeWorkspaceNavigation();
    const target = direction < 0 ? navigation.previous : navigation.next;
    if (!target?.titleSlug) return;
    setLeetcodeRoute('question', {
      slug: target.titleSlug,
      submissionId: '',
      origin: 'overview',
      questionScrollTop: 0
    });
    leetcodeWorkspaceTestcase = '';
    await openLeetcodeWorkspace();
  }

  async function runLeetcodeWorkspaceAction(action) {
    if (action === 'previous-question' || action === 'next-question') {
      await moveLeetcodeWorkspaceQuestion(action === 'previous-question' ? -1 : 1);
      return;
    }
    if (action === 'retry') {
      leetcodeWorkspaceBusy = '';
      await openLeetcodeWorkspace();
      return;
    }
    if (action === 'complete') {
      activeLeetcodeEditor?.state?.openLocalCompletion?.();
      return;
    }
    if (action === 'reset-code') {
      if (!activeLeetcodeEditor || leetcodeWorkspaceBusy) return;
      const editor = activeLeetcodeEditor;
      const template = leetcodeWorkspaceTemplateCode();
      if (editor.getValue() === template) {
        setLeetcodeSyntaxStatus('valid', '已是官方模板');
      } else {
        const lastLine = editor.lastLine();
        editor.operation(() => {
          editor.replaceRange(template, { line: 0, ch: 0 }, { line: lastLine, ch: editor.getLine(lastLine).length }, '+reset');
          editor.setCursor({ line: 0, ch: 0 });
        });
        setLeetcodeWorkspaceDraft(template);
        leetcodeWorkspaceResult = null;
        leetcodeWorkspaceAnalysis = null;
        refreshLeetcodeWorkspaceExecutionUi();
        setLeetcodeSyntaxStatus('checking', '正在检查');
      }
      editor.focus();
      scheduleLeetcodeSyntaxCheck(editor, true);
      return;
    }
    if (action === 'format') {
      if (!activeLeetcodeEditor || leetcodeWorkspaceBusy) return;
      const editor = activeLeetcodeEditor;
      const source = editor.getValue();
      const cursorOffset = editor.indexFromPos(editor.getCursor());
      leetcodeWorkspaceBusy = 'format';
      try {
        const result = await window.api.formatLearningCode(normalizedCompletionLanguage(leetcodeWorkspaceLang), source, cursorOffset);
        if (editor !== activeLeetcodeEditor || editor.getValue() !== source) return;
        if (result?.supported && typeof result.formatted === 'string') {
          editor.operation(() => {
            const lastLine = editor.lastLine();
            editor.replaceRange(result.formatted, { line: 0, ch: 0 }, { line: lastLine, ch: editor.getLine(lastLine).length }, '+format');
            editor.setCursor(editor.posFromIndex(Math.min(result.cursorOffset, result.formatted.length)));
          });
          setLeetcodeWorkspaceDraft(result.formatted);
          setLeetcodeSyntaxStatus('checking', '正在检查');
        } else {
          editor.operation(() => {
            for (let line = 0; line < editor.lineCount(); line += 1) editor.indentLine(line, 'smart');
          });
          setLeetcodeWorkspaceDraft(editor.getValue());
          setLeetcodeSyntaxStatus('checking', '正在检查');
        }
      } catch (error) {
        editor.operation(() => {
          for (let line = 0; line < editor.lineCount(); line += 1) editor.indentLine(line, 'smart');
        });
        setLeetcodeWorkspaceDraft(editor.getValue());
        setLeetcodeSyntaxStatus('checking', '正在检查');
      } finally {
        leetcodeWorkspaceBusy = '';
        refreshLeetcodeWorkspaceExecutionUi();
        editor?.focus();
        if (editor === activeLeetcodeEditor) scheduleLeetcodeSyntaxCheck(editor, true);
      }
      return;
    }
    if (action === 'back') {
      leetcodeWorkspaceRequestGeneration += 1;
      destroyLeetcodeWorkspaceSplit();
      destroyActiveLeetcodeEditor();
      clearLeetcodeExecutionTimers();
      leetcodeExecutionNotice = null;
      setLeetcodeRoute('question');
      leetcodeWorkspaceBusy = '';
      leetcodeWorkspaceError = '';
      renderLeetcodeQuestionDetail();
      restoreLeetcodeScroll('question');
      return;
    }
    if (action === 'analyze') {
      if (leetcodeWorkspaceBusy || !leetcodeWorkspaceResult || leetcodeWorkspaceResult.accepted) return;
      const code = activeLeetcodeEditor?.getValue() || leetcodeWorkspaceCode();
      leetcodeWorkspaceBusy = 'analyze';
      leetcodeWorkspaceError = '';
      refreshLeetcodeWorkspaceExecutionUi();
      try {
        leetcodeWorkspaceAnalysis = await window.api.analyzeLeetCodeAttempt({
          titleSlug: leetcodeWorkspace.question.titleSlug,
          submissionId: leetcodeWorkspaceResult.taskId,
          lang: leetcodeWorkspaceLang,
          code,
          result: leetcodeWorkspaceResult
        });
        leetcodeDashboard = await window.api.getLeetCodeDashboard();
      } catch (error) {
        leetcodeWorkspaceError = error?.message || 'AI 分析失败';
      } finally {
        leetcodeWorkspaceBusy = '';
        refreshLeetcodeWorkspaceExecutionUi();
      }
      return;
    }
    if (!['run', 'submit'].includes(action) || leetcodeWorkspaceBusy || !leetcodeWorkspace) return;
    const code = activeLeetcodeEditor?.getValue() || leetcodeWorkspaceCode();
    const requestId = globalThis.crypto?.randomUUID?.() || `leetcode-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    startLeetcodeExecutionNotice(action, requestId);
    const syntax = await validateLeetcodeWorkspaceSyntax({ focusFirst: true });
    if (!syntax) {
      finishLeetcodeExecutionNotice(action, {
        kind: 'syntax',
        accepted: false,
        status: '语法检查未完成',
        compileError: '请稍后重试'
      }, requestId);
      return;
    }
    if (syntax?.supported && syntax.diagnostics?.length) {
      leetcodeWorkspaceResult = {
        kind: 'syntax',
        accepted: false,
        status: '请先修复语法问题',
        compileError: syntax.diagnostics.map((item, index) => `${index + 1}. ${item.message}`).join('\n')
      };
      finishLeetcodeExecutionNotice(action, leetcodeWorkspaceResult, requestId);
      refreshLeetcodeWorkspaceExecutionUi();
      return;
    }
    setLeetcodeWorkspaceDraft(code);
    leetcodeWorkspaceTestcase = $('#leetcode-workspace-testcase')?.value || leetcodeWorkspaceTestcase;
    leetcodeWorkspaceBusy = action;
    leetcodeWorkspaceError = '';
    leetcodeWorkspaceAnalysis = null;
    refreshLeetcodeWorkspaceExecutionUi();
    try {
      const payload = {
        titleSlug: leetcodeWorkspace.question.titleSlug,
        lang: leetcodeWorkspaceLang,
        code,
        testcase: leetcodeWorkspaceTestcase,
        requestId
      };
      leetcodeWorkspaceResult = action === 'run'
        ? await window.api.runLeetCodeCode(payload)
        : await window.api.submitLeetCodeCode(payload);
      finishLeetcodeExecutionNotice(action, leetcodeWorkspaceResult, requestId);
      if (leetcodeWorkspaceResult?.dashboard) leetcodeDashboard = leetcodeWorkspaceResult.dashboard;
      if (action === 'submit') {
        try {
          const slug = leetcodeCurrentSlug();
          const history = await window.api.getLeetCodeQuestionHistory(slug);
          if (slug === leetcodeCurrentSlug()) leetcodeQuestionHistories.set(slug, history);
          leetcodeDashboard = await window.api.getLeetCodeDashboard();
        } catch (error) {
          console.warn('Failed to refresh submitted question history:', error);
        }
      }
    } catch (error) {
      leetcodeWorkspaceResult = {
        kind: action,
        accepted: false,
        status: action === 'run' ? '运行请求失败' : '提交请求失败',
        runtimeError: error?.message || (action === 'run' ? '代码运行失败' : '代码提交失败')
      };
      finishLeetcodeExecutionNotice(action, leetcodeWorkspaceResult, requestId);
      leetcodeWorkspaceError = '';
    } finally {
      leetcodeWorkspaceBusy = '';
      if (learningTab === 'leetcode' && leetcodeIsWorkspace()) refreshLeetcodeWorkspaceExecutionUi();
    }
  }

  function leetcodeCodeLanguage(value) {
    const language = String(value || '').toLowerCase();
    if (language.includes('python')) return 'python';
    if (language.includes('c++') || language === 'cpp') return 'cpp';
    if (language.includes('javascript') || language === 'js') return 'javascript';
    if (language.includes('typescript')) return 'typescript';
    if (language.includes('golang') || language === 'go') return 'go';
    if (language.includes('c#') || language === 'csharp') return 'csharp';
    return language.replace(/[^a-z0-9_-]/g, '') || 'plaintext';
  }

  function leetcodeSubmissionDetailHtml(submission, insight, analysisSnapshot) {
    if (leetcodeExpandedSubmissionId !== submission.id) return '';
    if (leetcodeSubmissionDetailBusy.has(submission.id)) {
      return '<div class="leetcode-submission-detail"><div class="leetcode-history-loading"><span></span>正在读取源码与失败用例</div></div>';
    }
    const detailError = leetcodeSubmissionDetailErrors.get(submission.id);
    if (detailError) {
      return `<div class="leetcode-submission-detail"><div class="leetcode-inline-error">${esc(detailError)}</div></div>`;
    }
    const detail = leetcodeSubmissionDetails.get(submission.id);
    if (!detail) return '';
    const diagnostics = [
      ['编译信息', detail.compileError],
      ['运行错误', detail.runtimeError],
      ['失败用例', detail.lastTestcase],
      ['实际输出', detail.codeOutput],
      ['预期输出', detail.expectedOutput]
    ].filter(([, value]) => value);
    const passed = detail.totalTestcases
      ? `${detail.totalCorrect || 0} / ${detail.totalTestcases} 个样例`
      : (submission.accepted ? '全部样例通过' : '样例数据不可用');
    const performanceMetrics = [
      ['runtime', '运行用时', detail.runtime, detail.runtimePercentile],
      ['memory', '内存消耗', detail.memory, detail.memoryPercentile]
    ].filter(([, , value, percentile]) => value || percentile !== null);
    const performanceHtml = submission.accepted && performanceMetrics.length
      ? `<section class="leetcode-performance-ranking" aria-label="官方性能排行">${performanceMetrics.map(([kind, label, value, percentile]) => {
        const ranked = percentile !== null && percentile !== undefined && Number.isFinite(Number(percentile));
        const score = ranked ? Math.max(0, Math.min(100, Number(percentile))) : 0;
        const scoreLabel = score.toLocaleString('zh-CN', { maximumFractionDigits: 2 });
        const language = detail.lang || submission.lang || '同语言';
        return `<article data-kind="${kind}" data-ranked="${ranked ? 'true' : 'false'}"><header><span>${label}</span><strong>${esc(value || '暂无数据')}</strong><em>${ranked ? `击败 ${scoreLabel}%` : '排行暂不可用'}</em></header><div class="leetcode-percentile-chart" role="img" aria-label="${label}${ranked ? `击败 ${scoreLabel}% 的${language}用户` : '排行暂不可用'}"><i style="--percentile:${score}%"></i><b style="--percentile:${score}%"></b></div><footer><span>0%</span><small>官方同语言提交排行</small><span>100%</span></footer></article>`;
      }).join('')}</section>`
      : '';
    return `<div class="leetcode-submission-detail">
      <header><div><strong>${esc(passed)}</strong><span>${esc([detail.runtime, detail.memory].filter(Boolean).join(' · ') || '暂无性能数据')}</span></div><div class="leetcode-submission-detail-actions">${!submission.accepted && !insight ? `<button class="is-analysis ${leetcodeSubmissionAnalysisBusy.has(submission.id) ? 'is-busy' : ''}" type="button" data-leetcode-analyze-submission="${esc(submission.id)}" ${leetcodeSubmissionAnalysisBusy.size ? 'disabled' : ''}><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3l1.25 4.1L17 9l-3.75 1.9L12 15l-1.25-4.1L7 9l3.75-1.9L12 3Z" stroke-linejoin="round"/><path d="m18.5 14 .7 2.3 2.3.7-2.3.7-.7 2.3-.7-2.3-2.3-.7 2.3-.7.7-2.3Z" stroke-linejoin="round"/></svg><span>${leetcodeSubmissionAnalysisBusy.has(submission.id) ? '分析中' : '分析错误'}</span></button>` : ''}${detail.code ? `<button class="is-copy" type="button" data-leetcode-copy-submission="${esc(submission.id)}" title="复制代码" aria-label="复制代码"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" stroke-linecap="round"/></svg></button>` : ''}</div></header>
      ${leetcodeSubmissionAnalysisErrors.has(submission.id) ? `<div class="leetcode-inline-error">${esc(leetcodeSubmissionAnalysisErrors.get(submission.id))}</div>` : ''}
      ${performanceHtml}
      ${diagnostics.length ? `<div class="leetcode-submission-diagnostics">${diagnostics.map(([label, value]) => `<section><span>${label}</span><pre>${esc(value)}</pre></section>`).join('')}</div>` : ''}
      ${insight || analysisSnapshot ? `<div class="leetcode-submission-insight"><span>AI 分析</span><p>${esc(analysisSnapshot?.rootCause || insight?.issue || insight?.outcome || '已纳入学习轨迹')}</p>${(analysisSnapshot?.evidence || []).length ? `<div><strong>判断依据</strong>${analysisSnapshot.evidence.map(item => `<small>${esc(item)}</small>`).join('')}</div>` : ''}${(analysisSnapshot?.suggestions || []).length ? `<div><strong>建议</strong>${analysisSnapshot.suggestions.map(item => `<small>${esc(item)}</small>`).join('')}</div>` : (insight?.change ? `<small>${esc(insight.change)}</small>` : '')}</div>` : ''}
      ${detail.code ? `<div class="leetcode-submission-code"><header><span>${esc(detail.lang || submission.lang || '代码')}</span><small>提交 #${esc(submission.id)}</small></header><pre><code class="hljs language-${esc(leetcodeCodeLanguage(detail.lang || submission.lang))}">${esc(detail.code)}</code></pre></div>` : '<p class="leetcode-code-empty">这条提交没有返回可显示的源码</p>'}
    </div>`;
  }

  async function analyzeLeetcodeSubmission(submissionId) {
    const id = String(submissionId || '');
    if (!id || leetcodeSubmissionAnalysisBusy.size) return;
    const slug = leetcodeCurrentSlug();
    leetcodeSubmissionAnalysisBusy.add(id);
    leetcodeSubmissionAnalysisErrors.delete(id);
    renderLeetcodeQuestionDetail();
    try {
      await window.api.analyzeLeetCodeSubmission(id);
      leetcodeDashboard = await window.api.getLeetCodeDashboard();
    } catch (error) {
      leetcodeSubmissionAnalysisErrors.set(id, error?.message || 'AI 分析失败');
    } finally {
      leetcodeSubmissionAnalysisBusy.delete(id);
      if (learningTab === 'leetcode' && leetcodeCurrentSlug() === slug && leetcodeExpandedSubmissionId === id) renderLeetcodeQuestionDetail();
    }
  }

  async function toggleLeetcodeSubmissionDetail(submissionId) {
    const id = String(submissionId || '');
    if (!id) return;
    if (leetcodeExpandedSubmissionId === id) {
      leetcodeExpandedSubmissionId = '';
      setLeetcodeRoute('question', { submissionId: '' });
      renderLeetcodeQuestionDetail();
      return;
    }
    leetcodeExpandedSubmissionId = id;
    setLeetcodeRoute('question', { submissionId: id });
    leetcodeSubmissionDetailErrors.delete(id);
    if (leetcodeSubmissionDetails.has(id)) {
      renderLeetcodeQuestionDetail();
      return;
    }
    const questionSlug = leetcodeCurrentSlug();
    leetcodeSubmissionDetailBusy.add(id);
    renderLeetcodeQuestionDetail();
    try {
      const detail = await window.api.getLeetCodeSubmissionDetail(id);
      leetcodeSubmissionDetails.delete(id);
      leetcodeSubmissionDetails.set(id, detail);
      while (leetcodeSubmissionDetails.size > 40) leetcodeSubmissionDetails.delete(leetcodeSubmissionDetails.keys().next().value);
    } catch (error) {
      leetcodeSubmissionDetailErrors.set(id, error?.message || '提交详情读取失败');
    } finally {
      leetcodeSubmissionDetailBusy.delete(id);
      if (learningTab === 'leetcode' && leetcodeCurrentSlug() === questionSlug && leetcodeExpandedSubmissionId === id) {
        renderLeetcodeQuestionDetail();
      }
    }
  }

  function leetcodeQuestionProblemHtml(slug) {
    const workspace = leetcodeQuestionWorkspaces.get(slug);
    const error = leetcodeQuestionWorkspaceErrors.get(slug);
    if (error) return `<div class="leetcode-review-loading is-error"><strong>${esc(error)}</strong><button type="button" data-leetcode-action="retry-problem">重试</button></div>`;
    if (!workspace) return '<div class="leetcode-review-loading"><span></span>正在读取题目</div>';
    const content = sanitizeLeetcodeProblemContent(workspace.question?.content);
    return `<article class="leetcode-problem-article">${content || '<p>题面暂时无法显示。</p>'}</article>`;
  }

  function renderLeetcodeQuestionDetail() {
    const content = $('#learning-content');
    const preservedScrollTop = leetcodeRoute.page === 'question' ? content.scrollTop : 0;
    stopLeetcodeGalleries(content);
    stopLeetcodeVideoPlayers(content);
    content.scrollLeft = 0;
    const slug = leetcodeCurrentSlug();
    const dashboardQuestion = leetcodeDashboard?.questions?.find(item => item.titleSlug === slug);
    const recentQuestion = leetcodeDashboard?.submissions?.find(item => item.titleSlug === slug);
    const workspaceQuestion = leetcodeQuestionWorkspaces.get(slug)?.question;
    const question = dashboardQuestion || workspaceQuestion || (recentQuestion ? {
      titleSlug: slug,
      frontendId: recentQuestion.frontendId || '',
      translatedTitle: recentQuestion.translatedTitle || recentQuestion.title,
      title: recentQuestion.title,
      groupName: '最近提交',
      difficulty: recentQuestion.difficulty || '',
      status: recentQuestion.accepted ? 'SOLVED' : 'TRIED'
    } : null);
    if (!question) {
      setLeetcodeRoute('overview', { slug: '', submissionId: '' });
      return renderLeetcode();
    }
    const analysis = leetcodeDashboard?.analysis?.records?.[question.titleSlug];
    const pendingAnalysis = leetcodeDashboard?.analysis?.pending?.[question.titleSlug];
    const history = leetcodeQuestionHistories.get(slug)?.submissions || [];
    const historyBusy = leetcodeQuestionHistoryBusy.has(slug);
    const historyError = leetcodeQuestionHistoryErrors.get(slug) || '';
    content.innerHTML = `<div class="leetcode-detail-view">
      <header class="leetcode-detail-header"><button type="button" data-leetcode-action="back" title="返回力扣概览" aria-label="返回力扣概览"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 18-6-6 6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div><strong>${question.frontendId ? `${esc(question.frontendId)}. ` : ''}${esc(question.translatedTitle || question.title)}</strong><span>${[question.groupName, leetcodeDifficultyLabel(question.difficulty), leetcodeStatusLabel(question.status)].filter(Boolean).map(esc).join(' · ')}</span></div><div class="leetcode-detail-actions"><button class="leetcode-solve-action" type="button" data-leetcode-action="solve"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.9"><path d="m8 17-5-5 5-5M16 7l5 5-5 5M14 4l-4 16" stroke-linecap="round" stroke-linejoin="round"/></svg><span>作答</span></button><button type="button" data-leetcode-action="open-problem" title="在力扣打开" aria-label="在力扣打开"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M14 5h5v5M10 14 19 5M19 14v5H5V5h5" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div></header>
      <div class="leetcode-review-grid">
        <section class="leetcode-review-problem"><header><strong>题目</strong></header><div class="leetcode-review-problem-body">${leetcodeQuestionProblemHtml(slug)}</div></section>
        <div class="leetcode-review-side">
          ${analysis ? `<section class="leetcode-analysis${pendingAnalysis ? ' is-pending' : ''}"><header><strong>提交轨迹</strong><span>${pendingAnalysis ? `${pendingAnalysis.submissionCount} 条新提交待分析` : formatLeetcodeTime(analysis.summaryUpdatedAt || analysis.updatedAt, '')}</span></header>${pendingAnalysis?.lastError ? `<div class="leetcode-analysis-status is-error">上次分析失败：${esc(pendingAnalysis.lastError)}，将自动重试</div>` : pendingAnalysis ? '<div class="leetcode-analysis-status">当前显示上一次分析，新轨迹正在更新</div>' : ''}<p>${esc(analysis.summary || '分析已完成')}</p>${analysis.weaknesses?.length ? `<div><span>待巩固</span><div>${analysis.weaknesses.map(item => `<small>${esc(item)}</small>`).join('')}</div></div>` : ''}${analysis.improvements?.length ? `<div><span>下一步</span><div>${analysis.improvements.map(item => `<small>${esc(item)}</small>`).join('')}</div></div>` : ''}</section>` : `<section class="leetcode-analysis is-pending"><header><strong>提交轨迹</strong><span>${pendingAnalysis ? pendingAnalysis.lastError ? '分析失败，等待重试' : '等待分析' : '暂无记录'}</span></header></section>`}
          <section class="leetcode-history"><header><strong>提交记录</strong><span>${history.length ? `${history.length} 次` : ''}</span></header>
        ${historyBusy ? '<div class="leetcode-history-loading"><span></span>正在读取提交记录</div>' : ''}
        ${historyError && !history.length ? `<div class="leetcode-inline-error">${esc(historyError)}</div>` : ''}
        ${history.map(item => {
          const insight = analysis?.attemptInsights?.find(entry => String(entry.submissionId) === String(item.id));
          const analysisSnapshot = analysis?.submissionAnalyses?.[item.id];
          const expanded = leetcodeExpandedSubmissionId === item.id;
          return `<article class="leetcode-submission ${expanded ? 'is-expanded' : ''}"><button type="button" data-leetcode-submission="${esc(item.id)}" aria-expanded="${expanded ? 'true' : 'false'}"><i data-accepted="${item.accepted ? 'true' : 'false'}"></i><span><header><strong>${esc(item.statusDisplay || (item.accepted ? '通过' : '未通过'))}</strong><em data-activity="${esc(item.activityType || '')}">${esc(leetcodeActivityLabel(item.activityType))}</em><time>${formatLeetcodeTime(item.submittedAt, '')}</time><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="m8 10 4 4 4-4" stroke-linecap="round" stroke-linejoin="round"/></svg></header><p>${esc([item.lang, item.runtime, item.memory].filter(Boolean).join(' · ') || '暂无性能数据')}</p>${insight ? `<small>${esc(insight.issue || insight.outcome || '')}</small>` : ''}</span></button>${leetcodeSubmissionDetailHtml(item, insight, analysisSnapshot)}</article>`;
        }).join('') || (!historyBusy && !historyError ? '<div class="leetcode-empty">暂无提交记录</div>' : '')}
          </section>
        </div>
      </div>
    </div>`;
    requestAnimationFrame(() => {
      if (leetcodeRoute.page === 'question' && leetcodeCurrentSlug() === slug) content.scrollTop = preservedScrollTop;
      enhanceLeetcodeRichContent(content.querySelector('.leetcode-review-problem-body'));
      const code = document.querySelector('.leetcode-submission.is-expanded .leetcode-submission-code code:not(.hljs-highlighted)');
      if (!code || !window.hljs) return;
      try {
        window.hljs.highlightElement(code);
        code.classList.add('hljs-highlighted');
      } catch {}
    });
  }

  function renderLeetcode() {
    hideLeetcodeHeatmapTooltip();
    const content = $('#learning-content');
    content.scrollLeft = 0;
    if (leetcodeIsWorkspace()) return renderLeetcodeWorkspace();
    if (leetcodeRoute.page === 'question' && leetcodeCurrentSlug()) return renderLeetcodeQuestionDetail();
    if (!leetcodeDashboard) {
      content.innerHTML = '<div class="learning-loading"><span></span><strong>正在读取力扣数据</strong></div>';
      return;
    }
    const dashboard = leetcodeDashboard;
    const account = dashboard.account || {};
    const stats = dashboard.stats || {};
    const maxCount = Math.max(1, ...(dashboard.activity || []).map(day => day.count));
    const firstWeekday = dashboard.activity?.length ? new Date(`${dashboard.activity[0].date}T12:00:00`).getDay() : 0;
    const monthLabels = Array.from({ length: 12 }, (_, offset) => {
      const start = dashboard.activity?.[0]?.date ? new Date(`${dashboard.activity[0].date}T12:00:00`) : new Date();
      return new Date(start.getFullYear(), start.getMonth() + offset, 1).toLocaleDateString('zh-CN', { month: 'numeric' });
    });
    const heatmapDays = [
      ...Array.from({ length: firstWeekday }, () => null),
      ...(dashboard.activity || [])
    ];
    while (heatmapDays.length % 7) heatmapDays.push(null);
    const heatmapWeeks = Array.from({ length: heatmapDays.length / 7 }, (_, weekIndex) => heatmapDays.slice(weekIndex * 7, weekIndex * 7 + 7));
    const heatmap = heatmapWeeks.map(week => `<span class="leetcode-heatmap-week">${week.map(day => day
      ? `<i data-level="${day.count ? Math.max(1, Math.ceil(day.count / maxCount * 4)) : 0}" data-tooltip="${esc(day.date)} · ${day.count} 次提交" aria-label="${esc(day.date)}，${day.count} 次提交"></i>`
      : '<i class="is-empty"></i>').join('')}</span>`).join('');
    const questionsBySlug = new Map((dashboard.questions || []).map(question => [question.titleSlug, question]));
    const recentSubmissions = [...(dashboard.submissions || [])]
      .filter(submission => submission.titleSlug)
      .sort((left, right) => right.submittedAt - left.submittedAt)
      .slice(0, 20);
    const recentHistory = recentSubmissions.map(submission => {
      const question = questionsBySlug.get(submission.titleSlug);
      const title = submission.translatedTitle || question?.translatedTitle || submission.title || question?.title || submission.titleSlug;
      const status = submission.statusDisplay || (submission.accepted ? '通过' : '未通过');
      return `<button class="leetcode-recent-item" type="button" data-leetcode-question="${esc(submission.titleSlug)}" data-leetcode-submission-id="${esc(submission.id)}" data-accepted="${submission.accepted ? 'true' : 'false'}" aria-label="打开 ${esc(title)} 的提交详情"><i aria-hidden="true" data-accepted="${submission.accepted ? 'true' : 'false'}"></i><span class="leetcode-recent-copy"><strong>${esc(title)}</strong><small>${esc(submission.lang || '未知语言')} · ${esc(leetcodeActivityLabel(submission.activityType))}</small></span><span class="leetcode-recent-meta"><em>${esc(status)}</em><time>${formatLeetcodeTime(submission.submittedAt, '')}</time></span><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m9 18 6-6-6-6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>`;
    }).join('');
    const questions = dashboard.questions || [];
    const completion = stats.total ? Math.round((stats.solved || 0) / stats.total * 100) : 0;
    const acceptance = stats.submissions ? Math.round((stats.acceptedSubmissions || 0) / stats.submissions * 100) : 0;
    const reviewDue = questions.filter(question => question.status === 'SOLVED' && question.learning?.overdue).length;
    const difficultyRows = [['EASY', '简单'], ['MEDIUM', '中等'], ['HARD', '困难']].map(([difficulty, label]) => {
      const matching = questions.filter(question => question.difficulty === difficulty);
      const solved = matching.filter(question => question.status === 'SOLVED').length;
      const percent = matching.length ? Math.round(solved / matching.length * 100) : 0;
      return { difficulty: difficulty.toLowerCase(), label, solved, total: matching.length, percent };
    });
    const languageCounts = new Map();
    for (const submission of dashboard.submissions || []) {
      const language = String(submission.lang || '').trim();
      if (language) languageCounts.set(language, (languageCounts.get(language) || 0) + 1);
    }
    const languages = [...languageCounts.entries()].sort((left, right) => right[1] - left[1]).slice(0, 4);
    const languageMax = Math.max(1, ...languages.map(([, count]) => count));
    const topicCounts = new Map();
    for (const question of questions.filter(question => question.status === 'SOLVED')) {
      const topic = String(question.groupName || question.topicTags?.[0]?.translatedName || question.topicTags?.[0]?.name || '').trim();
      if (topic) topicCounts.set(topic, (topicCounts.get(topic) || 0) + 1);
    }
    const topTopics = [...topicCounts.entries()].sort((left, right) => right[1] - left[1]).slice(0, 4);
    const recentWeek = (dashboard.activity || []).slice(-7);
    const weekMax = Math.max(1, ...recentWeek.map(day => day.count));
    const viewSwitcher = [['library', '题目清单'], ['activity', '学习活动'], ['submissions', '提交记录']]
      .map(([view, label]) => `<button type="button" data-leetcode-overview-view="${view}" class="${leetcodeOverviewView === view ? 'active' : ''}" aria-current="${leetcodeOverviewView === view ? 'page' : 'false'}">${label}</button>`)
      .join('');
    content.innerHTML = `<div class="leetcode-view">
      <section class="leetcode-account"><div class="leetcode-brand">${account.signedIn && (account.avatarData || account.avatar) ? `<img src="${esc(account.avatarData || account.avatar)}" alt="${esc(account.realName || account.username || '力扣头像')}">` : '<span>LC</span>'}<div><strong>${account.signedIn ? esc(account.realName || account.username) : '力扣中国站'}</strong><small>${account.signedIn ? `@${esc(account.username)} · ${formatLeetcodeTime(dashboard.lastSyncAt)}` : '未连接账号'}</small></div></div><nav class="leetcode-view-switcher" aria-label="力扣视图">${viewSwitcher}</nav><div class="leetcode-account-actions">${account.signedIn ? `<button class="leetcode-sync-action ${leetcodeBusy === 'sync' ? 'is-syncing' : ''}" type="button" data-leetcode-action="sync" title="同步力扣" aria-label="同步力扣" ${leetcodeBusy ? 'disabled' : ''}><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M19 8a7.5 7.5 0 0 0-12.8-2L4 8.2M5 16a7.5 7.5 0 0 0 12.8 2L20 15.8" stroke-linecap="round"/><path d="M4 4v4.2h4.2M20 20v-4.2h-4.2" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button class="leetcode-logout-action" type="button" data-leetcode-action="logout">退出</button>` : `<button class="leetcode-login" type="button" data-leetcode-action="login">扫码登录</button>`}</div></section>
      ${leetcodeError ? `<div class="leetcode-error">${esc(leetcodeError)}</div>` : ''}
      ${leetcodeOverviewView === 'activity' ? `<section class="leetcode-activity-page learning-page-enter" data-leetcode-overview-panel="activity"><div class="leetcode-section-inner">
        <header class="leetcode-activity-heading"><div><span>学习活动</span><strong>刷题节奏与能力分布</strong><small>过去一年 ${stats.submissions || 0} 次提交 · ${stats.newProblems || 0} 道新题 · ${stats.reviews || 0} 次复习</small></div><em>${dashboard.analysis?.pendingQuestions || 0} 题待分析</em></header>
        <section class="leetcode-activity-metrics" aria-label="学习概览">
          <article class="is-progress"><div class="leetcode-progress-ring" style="--progress:${completion}"><strong>${completion}<small>%</small></strong></div><span>题单完成度</span><small>${stats.solved || 0} / ${stats.total || 0} 题</small></article>
          <article><strong>${stats.streak || 0}<small> 天</small></strong><span>连续学习</span><small>${recentWeek.reduce((sum, day) => sum + day.count, 0)} 次本周提交</small></article>
          <article><strong>${acceptance}<small>%</small></strong><span>通过提交占比</span><small>${stats.acceptedSubmissions || 0} 次通过</small></article>
          <article><strong>${reviewDue}<small> 题</small></strong><span>等待复习</span><small>${reviewDue ? '优先巩固薄弱题' : '复习进度良好'}</small></article>
        </section>
        <div class="leetcode-activity-layout">
          <section class="leetcode-activity-calendar"><header><div><strong>年度提交</strong><span>颜色越深，提交越集中</span></div><small>${stats.submissions || 0} 次</small></header><div class="leetcode-heatmap-wrap"><div class="leetcode-heatmap" style="--heatmap-weeks:${heatmapWeeks.length}">${heatmap}</div><div class="leetcode-months">${monthLabels.map(month => `<span>${month}</span>`).join('')}</div></div><div class="leetcode-week-rhythm" aria-label="最近七天提交">${recentWeek.map(day => `<span title="${esc(day.date)} · ${day.count} 次"><i style="height:${Math.max(6, Math.round(day.count / weekMax * 100))}%"></i><small>${new Date(`${day.date}T12:00:00`).toLocaleDateString('zh-CN', { weekday: 'short' })}</small></span>`).join('')}</div></section>
          <aside class="leetcode-activity-details">
            <section><header><strong>难度完成</strong><span>当前题单</span></header>${difficultyRows.map(row => `<div class="leetcode-skill-row" data-tone="${row.difficulty}"><span>${row.label}</span><i><b style="width:${row.percent}%"></b></i><small>${row.solved} / ${row.total}</small></div>`).join('')}</section>
            <section><header><strong>常用语言</strong><span>全部提交</span></header>${languages.length ? languages.map(([language, count]) => `<div class="leetcode-skill-row"><span>${esc(language)}</span><i><b style="width:${Math.round(count / languageMax * 100)}%"></b></i><small>${count}</small></div>`).join('') : '<p>暂无语言数据</p>'}</section>
            <section class="leetcode-topic-strengths"><header><strong>优势专题</strong><span>已通过题目</span></header><div>${topTopics.length ? topTopics.map(([topic, count]) => `<span>${esc(topic)} <small>${count}</small></span>`).join('') : '<p>完成题目后自动形成</p>'}</div></section>
          </aside>
        </div>
      </div></section>` : ''}
      ${leetcodeOverviewView === 'submissions' ? `<section class="leetcode-recent-band learning-page-enter" data-leetcode-overview-panel="submissions"><div class="leetcode-section-inner leetcode-recent"><header><div><span>提交记录</span><strong>最近提交</strong></div><small>${recentSubmissions.length} 条</small></header><div class="leetcode-recent-list">${recentHistory || '<p>暂无提交记录</p>'}</div></div></section>` : ''}
      ${leetcodeOverviewView === 'library' ? `<section class="leetcode-library-zone learning-page-enter" data-leetcode-overview-panel="library"><header class="leetcode-library-heading"><div><span>题库</span><strong>题目清单</strong></div><small>${dashboard.questions?.length || 0} 道题</small></header><div class="leetcode-library-shell"><section class="leetcode-library-controls">
          <div class="leetcode-plan-switcher"><label><select id="leetcode-plan-select" aria-label="当前力扣题单">${(dashboard.plans || []).map(plan => `<option value="${esc(plan.slug)}" ${plan.slug === dashboard.activePlanSlug ? 'selected' : ''}>${esc(plan.name)} · ${plan.questionCount}</option>`).join('')}</select></label><details class="leetcode-plan-import"><summary title="添加题单" aria-label="添加题单"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14" stroke-linecap="round"/></svg></summary><div><input id="leetcode-plan-input" type="text" placeholder="题单链接或标识" aria-label="力扣题单链接或标识"><button type="button" data-leetcode-action="import" ${leetcodeBusy ? 'disabled' : ''}>导入</button></div></details></div>
          <div class="leetcode-summary"><div><strong>${stats.solved || 0}</strong><span>已通过</span></div><div><strong>${stats.tried || 0}</strong><span>尝试中</span></div><div><strong>${stats.todo || 0}</strong><span>未开始</span></div><div><strong>${stats.acceptedSubmissions || 0}</strong><span>通过提交</span></div></div>
          <div class="leetcode-library-query"><div class="leetcode-filters">${[['all','全部'],['SOLVED','已通过'],['TRIED','尝试中'],['TO_DO','未开始']].map(([value,label]) => `<button type="button" data-leetcode-filter="${value}" class="${leetcodeFilter === value ? 'active' : ''}">${label}</button>`).join('')}</div><label class="leetcode-search"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="m16 16 4 4" stroke-linecap="round"/></svg><input id="leetcode-search-input" type="search" value="${esc(leetcodeQuery)}" placeholder="搜索题目" aria-label="搜索力扣题目"></label><span id="leetcode-question-count"></span></div>
        </section><section class="leetcode-library"><div id="leetcode-question-list"></div></section></div></section>` : ''}
    </div>`;
    if (leetcodeOverviewView === 'library') renderLeetcodeQuestionList();
    restoreLeetcodeScroll('overview');
  }

  async function loadLeetcodeDashboard({ ensurePlan = false } = {}) {
    try {
      leetcodeError = '';
      leetcodeDashboard = await window.api.getLeetCodeDashboard();
      if (ensurePlan && !leetcodeDashboard?.plans?.length) {
        leetcodeBusy = 'import';
        leetcodeDashboard = await window.api.importLeetCodePlan('top-100-liked');
      }
    } catch (error) {
      leetcodeError = error?.message || '力扣数据读取失败';
    } finally {
      leetcodeBusy = '';
      if (learningTab === 'leetcode' && !$('#learning-overlay').classList.contains('hidden')) renderLeetcode();
    }
  }

  async function openLeetcodeQuestion(slug, { submissionId = '', origin = 'overview' } = {}) {
    const targetSlug = String(slug || '');
    const targetSubmissionId = String(submissionId || '');
    if (!targetSlug) return;
    const generation = ++leetcodeQuestionRequestGeneration;
    leetcodeWorkspaceRequestGeneration += 1;
    destroyActiveLeetcodeEditor();
    leetcodeWorkspace = null;
    leetcodeWorkspaceResult = null;
    leetcodeWorkspaceAnalysis = null;
    setLeetcodeRoute('question', {
      slug: targetSlug,
      submissionId: targetSubmissionId,
      origin,
      questionScrollTop: 0
    });
    leetcodeExpandedSubmissionId = '';
    leetcodeError = '';
    if (!leetcodeQuestionHistories.has(targetSlug)) leetcodeQuestionHistoryBusy.add(targetSlug);
    leetcodeQuestionHistoryErrors.delete(targetSlug);
    renderLeetcode();
    loadLeetcodeQuestionWorkspace(targetSlug).then(() => {
      leetcodeQuestionWorkspaceErrors.delete(targetSlug);
      if (learningTab === 'leetcode' && leetcodeRoute.page === 'question' && leetcodeCurrentSlug() === targetSlug) {
        renderLeetcodeQuestionDetail();
      }
    }).catch(error => {
      leetcodeQuestionWorkspaceErrors.set(targetSlug, error?.message || '题目读取失败');
      if (learningTab === 'leetcode' && leetcodeRoute.page === 'question' && leetcodeCurrentSlug() === targetSlug) {
        renderLeetcodeQuestionDetail();
      }
    });
    if (targetSubmissionId) toggleLeetcodeSubmissionDetail(targetSubmissionId);
    try {
      const [historyResult, dashboardResult] = await Promise.allSettled([
        window.api.getLeetCodeQuestionHistory(targetSlug),
        window.api.getLeetCodeDashboard()
      ]);
      if (historyResult.status === 'fulfilled') leetcodeQuestionHistories.set(targetSlug, historyResult.value);
      else leetcodeQuestionHistoryErrors.set(targetSlug, historyResult.reason?.message || '提交记录读取失败');
      if (dashboardResult.status === 'fulfilled' && generation === leetcodeQuestionRequestGeneration) {
        leetcodeDashboard = dashboardResult.value;
      }
    } finally {
      leetcodeQuestionHistoryBusy.delete(targetSlug);
      if (generation === leetcodeQuestionRequestGeneration && learningTab === 'leetcode' && leetcodeRoute.page === 'question' && leetcodeCurrentSlug() === targetSlug) {
        renderLeetcodeQuestionDetail();
      }
    }
  }

  async function runLeetcodeAction(action) {
    if (leetcodeBusy && !['back', 'solve', 'open-problem'].includes(action)) return;
    leetcodeError = '';
    if (action === 'solve') {
      await openLeetcodeWorkspace();
      return;
    }
    if (action === 'back') {
      leetcodeQuestionRequestGeneration += 1;
      leetcodeWorkspaceRequestGeneration += 1;
      destroyActiveLeetcodeEditor();
      setLeetcodeRoute('overview', { slug: '', submissionId: '' });
      leetcodeExpandedSubmissionId = '';
      renderLeetcode();
      restoreLeetcodeScroll('overview');
      return;
    }
    if (action === 'open-problem') {
      await window.api.openLeetCodeProblem(leetcodeCurrentSlug());
      return;
    }
    if (action === 'retry-problem') {
      const slug = leetcodeCurrentSlug();
      leetcodeQuestionWorkspaceErrors.delete(slug);
      renderLeetcodeQuestionDetail();
      try {
        await loadLeetcodeQuestionWorkspace(slug);
      } catch (error) {
        leetcodeQuestionWorkspaceErrors.set(slug, error?.message || '题目读取失败');
      }
      if (leetcodeRoute.page === 'question' && leetcodeCurrentSlug() === slug) renderLeetcodeQuestionDetail();
      return;
    }
    leetcodeBusy = action;
    renderLeetcode();
    try {
      if (action === 'login') await window.api.openLeetCodeLogin();
      else if (action === 'logout') leetcodeDashboard = await window.api.logoutLeetCode();
      else if (action === 'sync') leetcodeDashboard = await window.api.syncLeetCode();
      else if (action === 'import') {
        const input = $('#leetcode-plan-input')?.value || 'top-100-liked';
        leetcodeDashboard = await window.api.importLeetCodePlan(input);
      }
    } catch (error) {
      leetcodeError = error?.message || '力扣操作失败';
    } finally {
      leetcodeBusy = '';
      if (learningTab === 'leetcode') renderLeetcode();
    }
  }

  function learningPrimarySection(tab = learningTab) {
    return ['library', 'knowledge', 'templates'].includes(tab) ? 'knowledge' : tab;
  }

  function learningViewMetadata() {
    if (learningTab === 'leetcode') {
      return {
        title: { activity: '学习活动', submissions: '提交记录', library: '题目清单' }[leetcodeOverviewView] || '力扣',
        caption: { activity: '年度节奏与完成情况', submissions: '按时间回看每次尝试', library: '题单、筛选与练习入口' }[leetcodeOverviewView] || '题单与提交'
      };
    }
    return {
      today: { title: '今日', caption: '复习计划' },
      library: { title: '学习题目', caption: '按主题整理的学习档案' },
      knowledge: { title: '知识图谱', caption: '概念关系与掌握状态' },
      templates: { title: '解题模板', caption: '可复用的方法结构' },
      insights: { title: '洞察', caption: '学习趋势与成长轨迹' },
      trash: { title: '回收站', caption: '最近删除的学习项' }
    }[learningTab] || { title: '学习中心', caption: '本地学习档案' };
  }

  function renderLearningShellChrome() {
    const primarySection = learningPrimarySection();
    const metadata = learningViewMetadata();
    const workspace = $('#learning-workspace');
    const shell = $('#learning-shell');
    if (workspace) {
      workspace.dataset.learningView = primarySection;
      workspace.dataset.learningSubview = learningTab === 'leetcode' ? leetcodeOverviewView : learningTab;
    }
    if (shell) shell.dataset.learningSection = primarySection;
    if ($('#learning-title')) $('#learning-title').textContent = metadata.title;
    if ($('#learning-view-caption')) $('#learning-view-caption').textContent = metadata.caption;
    for (const button of document.querySelectorAll('[data-learning-region]')) {
      const active = button.dataset.learningRegion === primarySection;
      button.classList.toggle('active', active);
      button.toggleAttribute('aria-current', active);
    }
    for (const button of document.querySelectorAll('[data-leetcode-overview-view]')) {
      const active = primarySection === 'leetcode' && button.dataset.leetcodeOverviewView === leetcodeOverviewView;
      button.classList.toggle('active', active);
      button.toggleAttribute('aria-current', active);
    }
    for (const button of document.querySelectorAll('[data-learning-subtab]')) {
      const active = primarySection === 'knowledge' && button.dataset.learningSubtab === learningTab;
      button.classList.toggle('active', active);
      button.toggleAttribute('aria-current', active);
    }
  }

  function switchLearningPrimaryRegion(nextTab) {
    if (!['today', 'leetcode', 'knowledge', 'insights'].includes(nextTab)) return;
    if (learningTab === 'leetcode' && nextTab !== 'leetcode') {
      destroyLeetcodeWorkspaceSplit();
      destroyActiveLeetcodeEditor();
    }
    learningTab = nextTab;
    learningSelectedItemId = '';
    learningDetailOpen = false;
    learningEditState = null;
    learningDeleteConfirmItemId = '';
    learningDeleteConflict = '';
    learningPurgeConfirmItemId = '';
    learningPurgeAllConfirming = false;
    learningSelectedTemplateKey = '';
    learningTrashMessage = '';
    $('#learning-detail').classList.add('hidden');
    renderLearningContent();
    if (learningTab === 'leetcode') loadLeetcodeDashboard({ ensurePlan: true });
  }

  function renderLearningContent() {
    if (learningTab !== 'knowledge') destroyActiveLearningMindMap();
    window.api.setNativeLearningNavigation?.(learningTab);
    const trashCount = learningDashboard?.deletedItems?.length || 0;
    const trashButton = document.querySelector('[data-learning-tab="trash"]');
    const trashCountLabel = $('#learning-trash-count');
    if (trashCountLabel) trashCountLabel.textContent = trashCount ? String(Math.min(99, trashCount)) : '';
    if (trashButton) trashButton.title = trashCount ? `回收站（${trashCount}）` : '回收站';
    renderLearningShellChrome();
    if (trashButton) trashButton.classList.toggle('active', learningTab === 'trash');
    if (learningTab === 'leetcode') renderLeetcode();
    else if (learningTab === 'templates') renderLearningTemplates();
    else if (learningTab === 'library') renderLearningLibrary();
    else if (learningTab === 'knowledge') renderLearningKnowledge();
    else if (learningTab === 'insights') renderLearningInsights();
    else if (learningTab === 'trash') renderLearningTrash();
    else renderLearningToday();
    if (lastDeletedLearningItem) {
      $('#learning-content')?.insertAdjacentHTML('afterbegin', `<div class="learning-undo-delete"><span>已删除「${esc(lastDeletedLearningItem.title)}」</span><button type="button" data-learning-action="restore-delete">撤销</button></div>`);
    }
  }

  function clearLearningUndo({ animate = false } = {}) {
    clearTimeout(learningUndoTimer);
    learningUndoTimer = 0;
    lastDeletedLearningItem = null;
    const banner = document.querySelector('.learning-undo-delete');
    if (!banner) return;
    if (animate) {
      banner.classList.add('is-leaving');
      setTimeout(() => banner.remove(), 160);
    } else {
      banner.remove();
    }
  }

  function showLearningUndo(item) {
    clearTimeout(learningUndoTimer);
    lastDeletedLearningItem = { id: item.id, title: item.title };
    learningUndoTimer = setTimeout(() => clearLearningUndo({ animate: true }), 6000);
  }

  function renderLearningSettings() {
    const settings = learningDashboard?.settings;
    if (!settings) return;
    $('#learning-detail').innerHTML = `<header><button type="button" data-learning-action="detail-back" aria-label="返回"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m14 6-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div><strong>学习计划</strong></div></header>
      <form class="learning-settings-form" id="learning-settings-form">
        <label><span>每天新题</span><input name="dailyNewTarget" type="number" min="0" max="12" value="${settings.dailyNewTarget}"></label>
        <label><span>平日零散复习</span><input name="weekdayReviewTarget" type="number" min="0" max="30" value="${settings.weekdayReviewTarget}"></label>
        <label><span>集中复习日</span><select name="weeklyReviewDay">${['周日','周一','周二','周三','周四','周五','周六'].map((label, index) => `<option value="${index}" ${index === settings.weeklyReviewDay ? 'selected' : ''}>${label}</option>`).join('')}</select></label>
        <label><span>集中复习数量</span><input name="weeklyReviewTarget" type="number" min="0" max="60" value="${settings.weeklyReviewTarget}"></label>
        <label><span>代码练习语言</span><select name="preferredLanguage">${[['java','Java'],['python','Python'],['javascript','JavaScript'],['typescript','TypeScript'],['cpp','C++']].map(([value, label]) => `<option value="${value}" ${value === settings.preferredLanguage ? 'selected' : ''}>${label}</option>`).join('')}</select></label>
        <button type="submit">保存计划</button>
      </form>`;
  }

  function activeLearningPackage(item) {
    return item?.study?.packages?.find(entry => entry.id === item.study.activePackageId) || item?.study?.packages?.at(-1) || null;
  }

  function learningPracticeLabel(type) {
    return { auto: '智能选择', choice: '选择题', short_answer: '简答题', code_completion: '代码补全', coding: '编程题' }[type] || '检测';
  }

  function learningVerdictLabel(verdict) {
    return { correct: '掌握', partial: '部分掌握', incorrect: '需要巩固' }[verdict] || '待评估';
  }

  function learningDraftKey(item, learningPackage) {
    return `${item.id}:${learningPackage?.id || 'draft'}`;
  }

  const LEARNING_EDIT_FIELDS = Object.freeze([
    'title', 'question', 'diagnosis', 'labels', 'prerequisiteLabels', 'knowledgePath', 'language', 'videoEligible'
  ]);

  function learningEditableSnapshot(item) {
    return {
      title: String(item?.title || ''),
      question: String(item?.question || ''),
      diagnosis: String(item?.diagnosis || ''),
      labels: [...(item?.labels || [])],
      prerequisiteLabels: [...(item?.prerequisiteLabels || [])],
      knowledgePath: [...(item?.knowledgePath || [])],
      language: String(item?.language || ''),
      videoEligible: Boolean(item?.videoEligible)
    };
  }

  function sameLearningEditValue(left, right) {
    return JSON.stringify(left) === JSON.stringify(right);
  }

  function learningEditFieldClass(field) {
    return learningEditState?.conflicts?.includes(field) ? ' has-conflict' : '';
  }

  function renderLearningEditForm(item) {
    if (learningEditState?.itemId !== item.id) return '';
    const draft = learningEditState.draft || learningEditableSnapshot(item);
    const languageOptions = [['', '自动识别'], ['java', 'Java'], ['python', 'Python'], ['javascript', 'JavaScript'], ['typescript', 'TypeScript'], ['cpp', 'C++']];
    const conflictNotice = learningEditState.message
      ? `<div class="learning-edit-conflict"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M12 3 2.8 19h18.4L12 3Z" stroke-linejoin="round"/><path d="M12 9v4m0 3h.01" stroke-linecap="round"/></svg><p><strong>内容已被其他修改更新</strong><span>${esc(learningEditState.message)}，请复核后再保存。</span></p></div>`
      : '';
    return `<section class="learning-edit-panel">
      <header><div><strong>内容与归类</strong></div></header>
      ${conflictNotice}
      <form id="learning-edit-form">
        <label class="learning-edit-wide${learningEditFieldClass('title')}"><span>名称</span><input name="title" maxlength="100" value="${esc(draft.title)}" required></label>
        <label class="learning-edit-wide${learningEditFieldClass('knowledgePath')}"><span>知识路径</span><input name="knowledgePath" maxlength="260" value="${esc(draft.knowledgePath.join(' › '))}" placeholder="编程语言 › Java › 集合"></label>
        <label class="${learningEditFieldClass('labels')}"><span>标签</span><input name="labels" maxlength="260" value="${esc(draft.labels.join('，'))}" placeholder="逗号分隔"></label>
        <label class="${learningEditFieldClass('prerequisiteLabels')}"><span>前置知识</span><input name="prerequisiteLabels" maxlength="260" value="${esc(draft.prerequisiteLabels.join('，'))}" placeholder="逗号分隔"></label>
        <label class="${learningEditFieldClass('language')}"><span>语言</span><select name="language">${languageOptions.map(([value, label]) => `<option value="${value}" ${draft.language === value ? 'selected' : ''}>${label}</option>`).join('')}</select></label>
        <label class="learning-edit-toggle${learningEditFieldClass('videoEligible')}"><span>视频讲解</span><input name="videoEligible" type="checkbox" ${draft.videoEligible ? 'checked' : ''}><i></i></label>
        <label class="learning-edit-wide${learningEditFieldClass('question')}"><span>${item.kind === 'knowledge' ? '学习问题' : '题目内容'}</span><textarea name="question" maxlength="2400">${esc(draft.question)}</textarea></label>
        <label class="learning-edit-wide${learningEditFieldClass('diagnosis')}"><span>当前诊断</span><textarea name="diagnosis" maxlength="360">${esc(draft.diagnosis)}</textarea></label>
      </form>
      <footer><button type="button" data-learning-action="cancel-edit">取消</button><button type="button" data-learning-action="save-edit" ${learningMutationBusy ? 'disabled' : ''}>${learningMutationBusy ? '保存中' : '保存修改'}</button></footer>
    </section>`;
  }

  function learningEditDraftFromForm(item) {
    const form = $('#learning-edit-form');
    if (!form) return learningEditState?.draft || learningEditableSnapshot(item);
    const splitList = value => String(value || '').split(/[，,\n]+/u).map(part => part.trim()).filter(Boolean);
    const splitPath = value => String(value || '').split(/[>›/\n]+/u).map(part => part.trim()).filter(Boolean);
    return {
      title: form.elements.title.value.trim(),
      question: form.elements.question.value.trim(),
      diagnosis: form.elements.diagnosis.value.trim(),
      labels: splitList(form.elements.labels.value),
      prerequisiteLabels: splitList(form.elements.prerequisiteLabels.value),
      knowledgePath: splitPath(form.elements.knowledgePath.value),
      language: form.elements.language.value,
      videoEligible: form.elements.videoEligible.checked
    };
  }

  function learningDeleteConfirmHtml(item) {
    if (learningDeleteConfirmItemId !== item.id) return '';
    return `<section class="learning-delete-confirm"><div><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M4 7h16M9 7V4h6v3m3 0-1 13H7L6 7" stroke-linecap="round" stroke-linejoin="round"/></svg><p><strong>从学习系统删除？</strong><span>${esc(learningDeleteConflict || '聊天记录会保留，之后不会再自动创建这个知识项。')}</span></p></div><footer><button type="button" data-learning-action="cancel-delete">取消</button><button type="button" data-learning-action="confirm-delete" ${learningMutationBusy ? 'disabled' : ''}>${learningMutationBusy ? '删除中' : '确认删除'}</button></footer></section>`;
  }

  function renderLearningModePicker() {
    return `<div class="learning-mode-picker" role="group" aria-label="练习题型">${[
      ['auto', '智能'], ['choice', '选择'], ['short_answer', '简答'], ['code_completion', '补全'], ['coding', '编程']
    ].map(([value, label]) => `<button class="${learningPracticeType === value ? 'active' : ''}" type="button" data-learning-type="${value}">${label}</button>`).join('')}</div>`;
  }

  function renderLearningStudy(item) {
    const learningPackage = activeLearningPackage(item);
    if (!learningPackage) {
      return `<section class="learning-study learning-study-empty">
        <div class="learning-section-heading"><div><strong>讲解与练习</strong></div></div>
        ${renderLearningModePicker()}
        <button class="learning-primary-action" type="button" data-learning-action="prepare-study" ${learningPackageBusy ? 'disabled' : ''}>${learningPackageBusy ? '<i></i>正在准备' : '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v18M3 12h18" stroke-linecap="round"/></svg>生成讲解与检测'}</button>
      </section>`;
    }
    const { lesson, exercise } = learningPackage;
    const draftKey = learningDraftKey(item, learningPackage);
    const draft = learningDrafts.has(draftKey)
      ? learningDrafts.get(draftKey)
      : (['coding', 'code_completion'].includes(exercise.type) ? exercise.starterCode : '');
    if (!learningDrafts.has(draftKey)) setLearningDraft(draftKey, draft);
    const attempts = (item.study.attempts || []).filter(attempt => attempt.packageId === learningPackage.id);
    const latestAttempt = attempts.at(-1);
    const promptExtras = [
      exercise.examples?.length ? `<section class="learning-exercise-extras"><span>示例</span>${exercise.examples.map(value => `<div>${renderLearningMarkdown(value)}</div>`).join('')}</section>` : '',
      exercise.constraints?.length ? `<section class="learning-exercise-extras"><span>约束</span>${exercise.constraints.map(value => `<div>${renderLearningMarkdown(value)}</div>`).join('')}</section>` : ''
    ].join('');
    let answer = '';
    if (exercise.type === 'choice') {
      answer = `<div class="learning-choice-list">${exercise.choices.map((choice, index) => `<label><input type="radio" name="learning-choice" value="${esc(choice)}" ${draft === choice ? 'checked' : ''}><span>${String.fromCharCode(65 + index)}</span><strong>${esc(choice)}</strong></label>`).join('')}</div>`;
    } else if (['coding', 'code_completion'].includes(exercise.type)) {
      answer = `<div class="learning-code-shell"><header><div class="learning-code-meta"><span>${esc(exercise.language || item.language || 'code')}</span><span class="learning-code-status" id="learning-code-status" data-state="checking" role="status" aria-live="polite" aria-label="正在检查语法" title="正在检查语法"><i aria-hidden="true"></i></span></div><button type="button" data-learning-action="format-code" title="格式化代码" aria-label="格式化代码"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 7h16M4 12h11M4 17h16" stroke-linecap="round"/></svg></button></header><div class="learning-code-editor"><textarea id="learning-answer" aria-label="代码作答">${esc(draft)}</textarea></div></div>`;
    } else {
      answer = `<textarea class="learning-text-answer" id="learning-answer" placeholder="写下你的理解，系统会根据关键概念判分…">${esc(draft)}</textarea>`;
    }
    return `<section class="learning-study">
      <div class="learning-section-heading"><div><span>自适应讲解</span><strong>${esc(item.knowledgePath?.join(' › ') || item.title)}</strong></div><button type="button" data-learning-action="prepare-study" title="重新生成" aria-label="重新生成讲解和检测">${learningPackageBusy ? '<i></i>' : '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M20 7v5h-5M4 17v-5h5"/><path d="M18.5 9A7 7 0 0 0 6 6.5L4 9m16 6-2 2.5A7 7 0 0 1 5.5 15" stroke-linecap="round" stroke-linejoin="round"/></svg>'}</button></div>
      <article class="learning-lesson"><div class="learning-rich-text">${renderLearningMarkdown(lesson.overview)}</div>${lesson.keyPoints?.length ? `<ul>${lesson.keyPoints.map(point => `<li>${renderLearningMarkdown(point)}</li>`).join('')}</ul>` : ''}${lesson.example ? `<pre><code>${esc(lesson.example)}</code></pre>` : ''}${lesson.pitfalls?.length ? `<div class="learning-pitfalls"><span>易错点</span>${lesson.pitfalls.map(point => `<div>${renderLearningMarkdown(point)}</div>`).join('')}</div>` : ''}</article>
      <div class="learning-exercise">
        <header><div><span>${learningPracticeLabel(exercise.type)}</span><strong>${esc(exercise.title)}</strong></div><em>第 ${attempts.length + 1} 次</em></header>
        <div class="learning-exercise-prompt learning-rich-text">${renderLearningMarkdown(exercise.prompt)}</div>${exercise.instructions ? `<div class="learning-exercise-instructions learning-rich-text">${renderLearningMarkdown(exercise.instructions)}</div>` : ''}${promptExtras}
        ${answer}
        <footer><span></span><button type="button" data-learning-action="submit-attempt" ${learningJudgeBusy ? 'disabled' : ''}>${learningJudgeBusy ? '<i></i>正在判分' : '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="m5 12 4 4L19 6" stroke-linecap="round" stroke-linejoin="round"/></svg>提交检测'}</button></footer>
      </div>
      ${latestAttempt ? `<div class="learning-attempt-result" data-verdict="${esc(latestAttempt.verdict)}"><header><span>${learningVerdictLabel(latestAttempt.verdict)}</span><strong>${Math.round(latestAttempt.score)}<small> / 100</small></strong></header><div class="learning-rich-text">${renderLearningMarkdown(latestAttempt.feedback)}</div>${latestAttempt.strengths.length ? `<div><span>做得好</span>${latestAttempt.strengths.map(value => `<em>${esc(value)}</em>`).join('')}</div>` : ''}${latestAttempt.gaps.length ? `<div><span>待补齐</span>${latestAttempt.gaps.map(value => `<em>${esc(value)}</em>`).join('')}</div>` : ''}<footer>${renderLearningMarkdown(latestAttempt.nextStep)}</footer></div>` : ''}
      <div class="learning-study-options"><span>练习题型</span>${renderLearningModePicker()}</div>
    </section>`;
  }

  function clearLearningSyntaxDiagnostics(editor = activeLearningEditor) {
    for (const marker of learningSyntaxMarkers) marker?.clear?.();
    learningSyntaxMarkers = [];
    editor?.clearGutter?.('CodeMirror-lint-markers');
  }

  function destroyActiveLearningEditor() {
    clearTimeout(learningSyntaxTimer);
    learningSyntaxTimer = 0;
    learningSyntaxGeneration += 1;
    learningEditorWheelCleanup?.();
    learningEditorWheelCleanup = null;
    learningEditorCompletionCleanup?.();
    learningEditorCompletionCleanup = null;
    if (!activeLearningEditor) return;
    clearLearningSyntaxDiagnostics(activeLearningEditor);
    activeLearningEditor.toTextArea();
    activeLearningEditor = null;
  }

  function setLearningSyntaxStatus(state, label, title = '') {
    const status = $('#learning-code-status');
    if (!status) return;
    status.dataset.state = state;
    status.setAttribute('aria-label', label);
    status.title = title || label;
  }

  function applyLearningSyntaxDiagnostics(editor, result) {
    clearLearningSyntaxDiagnostics(editor);
    if (!result?.supported) {
      setLearningSyntaxStatus('unsupported', '仅高亮', '当前语言暂不支持本地语法检查');
      return;
    }
    const diagnostics = Array.isArray(result.diagnostics) ? result.diagnostics : [];
    if (!diagnostics.length) {
      setLearningSyntaxStatus('valid', '语法正常', `本地解析 ${Number(result.parseMs || 0).toFixed(1)}ms`);
      return;
    }
    const lineMessages = new Map();
    const documentLength = editor.getValue().length;
    for (const diagnostic of diagnostics) {
      const fromIndex = Math.max(0, Math.min(documentLength, Number(diagnostic.from) || 0));
      const toIndex = Math.max(fromIndex, Math.min(documentLength, Number(diagnostic.to) || fromIndex));
      const from = editor.posFromIndex(fromIndex);
      const to = editor.posFromIndex(toIndex);
      if (toIndex > fromIndex) {
        learningSyntaxMarkers.push(editor.markText(from, to, {
          className: 'learning-syntax-error',
          title: diagnostic.message
        }));
      } else {
        const widget = document.createElement('span');
        widget.className = 'learning-syntax-caret';
        widget.title = diagnostic.message;
        learningSyntaxMarkers.push(editor.setBookmark(from, { widget, insertLeft: true }));
      }
      const messages = lineMessages.get(from.line) || [];
      messages.push(diagnostic.message);
      lineMessages.set(from.line, messages);
    }
    for (const [line, messages] of lineMessages) {
      const marker = document.createElement('span');
      marker.className = 'learning-syntax-gutter-marker';
      marker.title = messages.join('\n');
      editor.setGutterMarker(line, 'CodeMirror-lint-markers', marker);
    }
    setLearningSyntaxStatus('invalid', `${diagnostics.length} 处错误`, diagnostics.map(item => item.message).join('\n'));
  }

  function scheduleLearningSyntaxCheck(editor, language, immediate = false) {
    clearTimeout(learningSyntaxTimer);
    const generation = ++learningSyntaxGeneration;
    if (!editor.getValue().trim()) {
      clearLearningSyntaxDiagnostics(editor);
      setLearningSyntaxStatus('idle', '等待输入');
      return;
    }
    setLearningSyntaxStatus('checking', '检查中');
    learningSyntaxTimer = setTimeout(async () => {
      try {
        const result = await window.api.validateLearningCode(language, editor.getValue());
        if (generation !== learningSyntaxGeneration || editor !== activeLearningEditor) return;
        applyLearningSyntaxDiagnostics(editor, result);
      } catch (error) {
        if (generation !== learningSyntaxGeneration || editor !== activeLearningEditor) return;
        clearLearningSyntaxDiagnostics(editor);
        setLearningSyntaxStatus('invalid', '检查失败', error?.message || '本地解析失败');
      }
    }, immediate ? 0 : 280);
  }

  function bindLearningEditorWheel(editor) {
    const scroller = editor.getScrollerElement();
    const detailBody = scroller.closest('.learning-detail-body');
    if (!detailBody) return () => {};
    const onWheel = event => {
      if (!event.deltaY || event.ctrlKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
      const scale = event.deltaMode === WheelEvent.DOM_DELTA_LINE
        ? 16
        : event.deltaMode === WheelEvent.DOM_DELTA_PAGE
          ? detailBody.clientHeight
          : 1;
      const delta = event.deltaY * scale;
      const info = editor.getScrollInfo();
      const maximum = Math.max(0, info.height - info.clientHeight);
      const canScrollEditor = delta < 0 ? info.top > 0.5 : info.top < maximum - 0.5;
      if (canScrollEditor) return;
      const outerMaximum = Math.max(0, detailBody.scrollHeight - detailBody.clientHeight);
      const canScrollOuter = delta < 0 ? detailBody.scrollTop > 0.5 : detailBody.scrollTop < outerMaximum - 0.5;
      if (!canScrollOuter) return;
      event.preventDefault();
      event.stopPropagation();
      detailBody.scrollTop = Math.max(0, Math.min(outerMaximum, detailBody.scrollTop + delta));
    };
    scroller.addEventListener('wheel', onWheel, { passive: false, capture: true });
    return () => scroller.removeEventListener('wheel', onWheel, { capture: true });
  }

  async function bindLearningAnswer(item) {
    const learningPackage = activeLearningPackage(item);
    if (!learningPackage) return;
    const key = learningDraftKey(item, learningPackage);
    const textarea = $('#learning-answer');
    destroyActiveLearningEditor();
    if (textarea?.closest('.learning-code-editor')) {
      await ensureCodeEditorRuntime();
      if (!textarea.isConnected || textarea !== $('#learning-answer') || !window.CodeMirror) return;
      const language = learningPackage.exercise.language || item.language || 'java';
      const mode = { java: 'text/x-java', cpp: 'text/x-c++', python: 'python', javascript: 'javascript', typescript: 'text/typescript' }[language] || 'text/x-java';
      activeLearningEditor = window.CodeMirror.fromTextArea(textarea, {
        mode,
        lineNumbers: true,
        gutters: ['CodeMirror-lint-markers', 'CodeMirror-linenumbers'],
        indentUnit: 4,
        tabSize: 4,
        indentWithTabs: false,
        smartIndent: true,
        electricChars: true,
        matchBrackets: true,
        autoCloseBrackets: true,
        lineWrapping: false,
        viewportMargin: 20,
        extraKeys: {
          Tab: editor => editor.somethingSelected() ? editor.indentSelection('add') : editor.execCommand('insertSoftTab'),
          'Shift-Tab': editor => editor.indentSelection('subtract'),
          Esc: editor => {
            editor.getInputField().blur();
            document.querySelector('[data-learning-action="format-code"]')?.focus();
          }
        }
      });
      activeLearningEditor.setSize(null, Math.min(440, Math.max(230, activeLearningEditor.lineCount() * 20 + 32)));
      activeLearningEditor.on('change', editor => {
        setLearningDraft(key, editor.getValue());
        scheduleLearningSyntaxCheck(editor, language);
      });
      learningEditorWheelCleanup = bindLearningEditorWheel(activeLearningEditor);
      learningEditorCompletionCleanup = installCodeCompletion(activeLearningEditor, language);
      scheduleLearningSyntaxCheck(activeLearningEditor, language, true);
      requestAnimationFrame(() => activeLearningEditor?.refresh());
    } else if (textarea) {
      textarea.addEventListener('input', () => setLearningDraft(key, textarea.value));
    }
    for (const option of document.querySelectorAll('input[name="learning-choice"]')) {
      option.addEventListener('change', () => setLearningDraft(key, option.value));
    }
  }

  function learningTemplateForItem(item) {
    const key = (item?.knowledgePath || []).join(' / ');
    if (!key) return null;
    return (learningDashboard?.templates || []).find(entry => entry.key === key) || null;
  }

  function learningTemplateByKey(key) {
    return (learningDashboard?.templates || []).find(entry => entry.key === key) || null;
  }

  function learningItemsForTopic(key) {
    return (learningDashboard?.items || []).filter(item => (item.knowledgePath || []).join(' / ') === key);
  }

  // 模板是主题下的一个节点：模板本体在上，归属它的题目列在里面。
  function renderLearningTemplates() {
    const content = $('#learning-content');
    const dashboard = learningDashboard;
    if (!dashboard) return renderLearningToday();
    const templates = dashboard.templates || [];
    const pending = (dashboard.pendingTemplates || []).filter(entry => !templates.some(t => t.key === entry.key));
    const busy = key => learningTemplateBusyKey === key;
    const cards = templates.map(template => {
      const items = learningItemsForTopic(template.key);
      return `<button class="template-card" type="button" data-template-key="${esc(template.key)}">
        <span class="template-card-head"><strong>${esc(template.title)}</strong><em>${esc(template.language)}</em></span>
        <span class="template-card-path">${esc(template.key.replaceAll(' / ', ' › '))}</span>
        ${template.summary ? `<span class="template-card-summary">${esc(template.summary)}</span>` : ''}
        <span class="template-card-meta">${items.length} 道题 · 第 ${template.revision} 版</span>
      </button>`;
    }).join('');
    const pendingCards = pending.map(entry => `<div class="template-card is-pending">
      <span class="template-card-head"><strong>${esc(entry.path.at(-1) || entry.key)}</strong></span>
      <span class="template-card-path">${esc(entry.key.replaceAll(' / ', ' › '))}</span>
      <span class="template-card-summary">已有 ${entry.itemCount} 道题，还没有沉淀模板</span>
      <button type="button" data-template-generate="${esc(entry.key)}" ${busy(entry.key) ? 'disabled' : ''}>${busy(entry.key) ? '正在沉淀' : '沉淀模板'}</button>
    </div>`).join('');
    content.innerHTML = templates.length || pending.length
      ? `<div class="template-list">
          ${cards}
          ${pendingCards}
        </div>`
      : `<div class="learning-library-empty">同一知识主题积累到 2 道题后会自动沉淀解题模板</div>`;
  }

  function renderLearningTemplateDetail(key = learningSelectedTemplateKey) {
    const detail = $('#learning-detail');
    const template = learningTemplateByKey(key);
    const items = learningItemsForTopic(key);
    if (!key || (!template && !items.length)) {
      learningSelectedTemplateKey = '';
      detail.classList.add('hidden');
      detail.innerHTML = '';
      return;
    }
    destroyActiveLearningEditor();
    learningSelectedItemId = '';
    learningDetailOpen = true;
    learningSelectedTemplateKey = key;
    const path = key.split(' / ');
    const topic = path.join(' › ');
    const busy = learningTemplateBusyKey === key;
    const action = `<button type="button" data-learning-action="${template ? 'refresh-template' : 'generate-template'}" ${busy ? 'disabled' : ''}>${busy ? '正在沉淀' : (template ? '重新沉淀' : '沉淀模板')}</button>`;
    const list = (values, className) => values.length
      ? `<ul class="${className}">${values.map(value => `<li>${esc(value)}</li>`).join('')}</ul>`
      : '';
    const body = template
      ? `${template.summary ? `<p class="learning-template-summary">${esc(template.summary)}</p>` : ''}
        ${template.applicableWhen.length ? `<div class="learning-template-block"><span>什么时候用</span>${list(template.applicableWhen, 'learning-template-list')}</div>` : ''}
        <div class="learning-template-code"><pre><code class="hljs language-${esc(template.language)}">${esc(template.code)}</code></pre><button class="learning-template-copy" type="button" data-learning-action="copy-template">复制</button></div>
        ${template.steps.length ? `<div class="learning-template-block"><span>套用步骤</span>${list(template.steps, 'learning-template-steps')}</div>` : ''}
        ${template.pitfalls.length ? `<div class="learning-template-block"><span>易错点</span>${list(template.pitfalls, 'learning-template-pitfalls')}</div>` : ''}
        <p class="learning-template-meta">归纳自 ${template.itemCount} 道同主题题目 · 第 ${template.revision} 版</p>`
      : `<p class="learning-template-empty">同主题积累到 2 道题后会自动沉淀，也可以现在手动生成。</p>`;
    detail.innerHTML = `<header>
        <button type="button" data-learning-action="detail-back" aria-label="返回"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m14 6-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
        <div><strong>${esc(template?.title || `${path.at(-1)} 模板`)}</strong><span>${esc(topic)}</span></div>
        <div class="learning-detail-actions">${action}</div>
      </header>
      <div class="learning-detail-body">
        <section class="learning-template">${body}</section>
        <section class="learning-template-items">
          <span>本模板下的题目 · ${items.length}</span>
          ${items.length
            ? items.map(item => learningItemRow(item)).join('')
            : '<p class="learning-template-empty">这个主题下还没有学习项。</p>'}
        </section>
      </div>`;
    detail.classList.remove('hidden');
  }

  async function generateLearningTemplateForTopic(key = learningSelectedTemplateKey) {
    if (!key || learningTemplateBusyKey) return;
    learningTemplateBusyKey = key;
    renderLearningTemplateDetail(key);
    try {
      learningDashboard = await window.api.generateLearningTemplate(key.split(' / '));
    } catch (error) {
      showAppError(error?.message || '模板沉淀失败，请重试');
    } finally {
      learningTemplateBusyKey = '';
      if (learningSelectedTemplateKey === key) renderLearningTemplateDetail(key);
      else renderLearningContent();
    }
  }

  function renderLearningDetail(itemId = learningSelectedItemId) {
    const detail = $('#learning-detail');
    destroyActiveLearningEditor();
    const item = learningItem(itemId);
    if (!item) {
      if (learningEditState?.itemId === itemId) learningEditState = null;
      if (learningDeleteConfirmItemId === itemId) {
        learningDeleteConfirmItemId = '';
        learningDeleteConflict = '';
      }
      learningSelectedItemId = '';
      learningDetailOpen = false;
      detail.classList.add('hidden');
      detail.innerHTML = '';
      return;
    }
    // 同一学习项内的重渲染（提交答案、评分、编辑）保留滚动位置，避免跳回顶部。
    const previousBody = detail.querySelector('.learning-detail-body');
    const preservedScrollTop = previousBody && learningSelectedItemId === item.id ? previousBody.scrollTop : 0;
    learningSelectedItemId = item.id;
    learningDetailOpen = true;
    if (learningEditState?.itemId === item.id) {
      detail.innerHTML = `<header><button type="button" data-learning-action="cancel-edit" aria-label="返回学习详情"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m14 6-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div><strong>编辑学习项</strong><span>${esc(item.title)}</span></div></header><div class="learning-detail-body is-editing">${renderLearningEditForm(item)}</div>`;
      detail.classList.remove('hidden');
      return;
    }
    const sources = item.sourceRefs.map((ref, index) => {
      const available = Boolean(conversations[ref.conversationId]);
      return `<button type="button" ${available ? `data-learning-source="${index}"` : 'disabled'}><span>${index + 1}</span><strong>${esc(ref.excerpt || '原始提问快照')}</strong>${available ? '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="m9 6 6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>' : '<em>原对话已删除 · 快照保留</em>'}</button>`;
    }).join('');
    const evidence = [...(item.evidence || [])].sort((a, b) => b.observedAt - a.observedAt).slice(0, 20);
    detail.innerHTML = `<header><button type="button" data-learning-action="detail-back" aria-label="返回"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"><path d="m14 6-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div><strong>${esc(item.title)}</strong><span>${item.kind === 'knowledge' ? '知识点' : '题目'} · 下次 ${formatLearningDate(item.review.dueAt)}</span></div><div class="learning-detail-actions">${learningBadge(item)}<button type="button" data-learning-action="edit-item" title="编辑知识项" aria-label="编辑知识项"><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.9"><path d="m4 16.5-.8 4.3 4.3-.8L19 8.5 15.5 5 4 16.5Z" stroke-linejoin="round"/><path d="m13.8 6.7 3.5 3.5"/></svg></button><button class="learning-delete-button" type="button" data-learning-action="delete-item" title="删除知识项" aria-label="删除知识项"><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M4 7h16M9 7V4h6v3m3 0-1 13H7L6 7" stroke-linecap="round" stroke-linejoin="round"/><path d="M10 11v5M14 11v5" stroke-linecap="round"/></svg></button></div></header>
      <div class="learning-detail-body">
        ${learningDeleteConfirmHtml(item)}
        <section class="learning-mastery"><div><span>当前掌握度</span><strong>${Math.round(item.mastery.effectiveScore)}<small>%</small></strong></div><i><b style="width:${learningPercent(item.mastery.effectiveScore)}"></b></i><p>证据可信度 ${Math.round(item.mastery.confidence * 100)}% · ${item.mastery.evidenceCount} 条证据</p></section>
        <section class="learning-path"><span>知识路径</span><div>${(item.knowledgePath || []).map((part, index) => `<button type="button" data-learning-path="${esc(item.knowledgePath.slice(0, index + 1).join(' / '))}">${esc(part)}</button>`).join('<i>›</i>')}</div></section>
        <section class="learning-question"><span>${item.kind === 'knowledge' ? '学习问题' : '题目内容'}</span><p>${esc(item.question || item.sourceRefs[0]?.excerpt || item.title)}</p></section>
        <section class="learning-diagnosis"><span>当前诊断</span><p>${esc(item.diagnosis || '等待更多学习证据')}</p><div>${item.labels.map(label => `<button type="button" data-learning-label="${esc(label)}">${esc(label)}</button>`).join('')}</div></section>
        ${renderLearningStudy(item)}
        <section class="learning-review"><span>这次记得怎么样？</span><div><button type="button" data-learning-rating="1">忘了</button><button type="button" data-learning-rating="2">困难</button><button type="button" data-learning-rating="3">掌握</button><button type="button" data-learning-rating="4">简单</button></div></section>
        ${item.videoEligible && item.review.reviewCount > 0 ? `<section class="learning-resource"><span>学习资源</span><button type="button" data-learning-action="video"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M8 5.5 18 12 8 18.5v-13Z" stroke-linejoin="round"/></svg><strong>视频讲解</strong><small>在应用内打开</small></button></section>` : ''}
        <section class="learning-evidence"><span>学习证据</span>${evidence.length ? evidence.map(event => `<div><i data-signal="${esc(event.signal)}"></i><p>${esc(event.summary || '学习状态更新')}<small>${new Date(event.observedAt).toLocaleString('zh-CN', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</small></p></div>`).join('') : '<p>等待新的学习证据</p>'}</section>
        <section class="learning-sources"><span>原始提问快照</span>${sources || '<p>没有来源快照</p>'}</section>
      </div>`;
    detail.classList.remove('hidden');
    if (preservedScrollTop) {
      const nextBody = detail.querySelector('.learning-detail-body');
      if (nextBody) nextBody.scrollTop = preservedScrollTop;
    }
    bindLearningAnswer(item).catch(error => {
      console.warn('Failed to initialize learning answer editor:', error);
    });
  }

  function startLearningItemEdit(item) {
    if (!item) return;
    const snapshot = learningEditableSnapshot(item);
    learningEditState = {
      itemId: item.id,
      baseRevision: item.revision,
      base: snapshot,
      draft: structuredClone(snapshot),
      conflicts: [],
      message: ''
    };
    learningDeleteConfirmItemId = '';
    learningDeleteConflict = '';
    renderLearningDetail(item.id);
    requestAnimationFrame(() => $('#learning-edit-form input')?.focus({ preventScroll: true }));
  }

  async function saveLearningItemEdit() {
    const item = learningItem(learningSelectedItemId);
    if (!item || learningEditState?.itemId !== item.id || learningMutationBusy) return;
    const draft = learningEditDraftFromForm(item);
    if (!draft.title || !draft.knowledgePath.length) {
      const target = !draft.title ? $('#learning-edit-form [name="title"]') : $('#learning-edit-form [name="knowledgePath"]');
      target?.classList.add('needs-answer');
      target?.focus({ preventScroll: true });
      setTimeout(() => target?.classList.remove('needs-answer'), 900);
      return;
    }
    const patch = Object.fromEntries(LEARNING_EDIT_FIELDS
      .filter(field => !sameLearningEditValue(draft[field], learningEditState.base[field]))
      .map(field => [field, draft[field]]));
    if (!Object.keys(patch).length) {
      learningEditState = null;
      renderLearningDetail(item.id);
      return;
    }
    const requestState = learningEditState;
    learningMutationBusy = true;
    learningEditState.draft = draft;
    renderLearningDetail(item.id);
    try {
      const result = await window.api.patchLearningItem(item.id, patch, {
        expectedRevision: requestState.baseRevision,
        base: Object.fromEntries(Object.keys(patch).map(field => [field, requestState.base[field]]))
      });
      learningDashboard = result.dashboard || learningDashboard;
      if (result.ok) {
        learningEditState = null;
        renderLearningContent();
        renderLearningDetail(item.id);
        return;
      }
      const latest = learningItem(item.id);
      if (!latest) {
        learningEditState = null;
        learningSelectedItemId = '';
        learningDetailOpen = false;
        renderLearningContent();
        $('#learning-detail').classList.add('hidden');
        return;
      }
      const latestBase = learningEditableSnapshot(latest);
      const dirtyFields = Object.keys(patch);
      const mergedDraft = structuredClone(latestBase);
      for (const field of dirtyFields) mergedDraft[field] = draft[field];
      learningEditState = {
        itemId: item.id,
        baseRevision: latest.revision,
        base: latestBase,
        draft: mergedDraft,
        conflicts: result.conflict?.fields || [],
        message: result.conflict?.message || '知识项已更新'
      };
      renderLearningDetail(item.id);
    } catch (error) {
      console.warn('Failed to patch learning item:', error);
      learningEditState.message = error?.message || '保存失败，请重试';
      learningEditState.conflicts = [];
      renderLearningDetail(item.id);
    } finally {
      learningMutationBusy = false;
      if (learningEditState?.itemId === item.id) renderLearningDetail(item.id);
    }
  }

  async function confirmDeleteLearningItem() {
    const item = learningItem(learningSelectedItemId);
    if (!item || learningDeleteConfirmItemId !== item.id || learningMutationBusy) return;
    learningMutationBusy = true;
    renderLearningDetail(item.id);
    try {
      const result = await window.api.deleteLearningItem(item.id, { expectedRevision: item.revision, reason: 'manual' });
      learningDashboard = result.dashboard || learningDashboard;
      if (!result.ok) {
        learningDeleteConflict = `${result.conflict?.message || '知识项已更新'}，请检查最新内容后再次确认删除`;
        renderLearningDetail(item.id);
        return;
      }
      showLearningUndo(item);
      learningEditState = null;
      learningDeleteConfirmItemId = '';
      learningDeleteConflict = '';
      learningSelectedItemId = '';
      learningDetailOpen = false;
      $('#learning-detail').classList.add('hidden');
      renderLearningContent();
    } catch (error) {
      learningDeleteConflict = error?.message || '删除失败，请重试';
      renderLearningDetail(item.id);
    } finally {
      learningMutationBusy = false;
      if (learningDeleteConfirmItemId === item.id && learningItem(item.id)) renderLearningDetail(item.id);
    }
  }

  async function restoreLastDeletedLearningItem() {
    if (!lastDeletedLearningItem || learningMutationBusy) return;
    const target = lastDeletedLearningItem;
    learningMutationBusy = true;
    try {
      const result = await window.api.restoreLearningItem(target.id);
      learningDashboard = result.dashboard || learningDashboard;
      clearLearningUndo();
      renderLearningContent();
      renderLearningDetail(target.id);
    } catch (error) {
      console.warn('Failed to restore learning item:', error);
    } finally {
      learningMutationBusy = false;
    }
  }

  async function restoreLearningTrashItem(itemId) {
    if (!itemId || learningMutationBusy) return;
    learningMutationBusy = true;
    learningTrashMessage = '';
    try {
      const result = await window.api.restoreLearningItem(itemId);
      learningDashboard = result.dashboard || learningDashboard;
      if (lastDeletedLearningItem?.id === itemId) clearLearningUndo();
      learningPurgeConfirmItemId = '';
      learningTab = 'library';
      renderLearningContent();
      renderLearningDetail(itemId);
    } catch (error) {
      learningTrashMessage = error?.message || '恢复失败，请重试';
      renderLearningContent();
    } finally {
      learningMutationBusy = false;
    }
  }

  async function purgeLearningTrashItem(itemId) {
    if (!itemId || learningMutationBusy) return;
    if (learningPurgeConfirmItemId !== itemId) {
      learningPurgeConfirmItemId = itemId;
      learningTrashMessage = '再次点击可彻底删除可恢复快照';
      renderLearningContent();
      return;
    }
    learningMutationBusy = true;
    learningTrashMessage = '';
    try {
      const result = await window.api.purgeLearningItem(itemId);
      learningDashboard = result.dashboard || learningDashboard;
      if (lastDeletedLearningItem?.id === itemId) clearLearningUndo();
      learningPurgeConfirmItemId = '';
      renderLearningContent();
    } catch (error) {
      learningTrashMessage = error?.message || '彻底删除失败，请重试';
      renderLearningContent();
    } finally {
      learningMutationBusy = false;
    }
  }

  async function purgeAllLearningTrash() {
    if (learningMutationBusy) return;
    if (!learningPurgeAllConfirming) {
      learningPurgeAllConfirming = true;
      learningTrashMessage = '再次点击将彻底删除全部快照，且不可恢复';
      renderLearningContent();
      return;
    }
    learningMutationBusy = true;
    learningTrashMessage = '';
    try {
      const result = await window.api.purgeAllLearningItems();
      learningDashboard = result.dashboard || learningDashboard;
      clearLearningUndo();
      learningPurgeConfirmItemId = '';
      learningPurgeAllConfirming = false;
      renderLearningContent();
    } catch (error) {
      learningPurgeAllConfirming = false;
      learningTrashMessage = error?.message || '清空回收站失败，请重试';
      renderLearningContent();
    } finally {
      learningMutationBusy = false;
    }
  }

  async function prepareLearningStudy({ force = false } = {}) {
    const itemId = learningSelectedItemId;
    if (!itemId || learningPackageBusy) return;
    learningPackageBusy = true;
    renderLearningDetail(itemId);
    try {
      learningDashboard = await window.api.prepareLearningPackage(itemId, learningPracticeType, force);
      renderLearningContent();
    } catch (error) {
      console.warn('Failed to prepare learning package:', error);
      const action = document.querySelector('[data-learning-action="prepare-study"]');
      if (action) {
        action.disabled = false;
        action.textContent = error?.message || '生成失败，请重试';
      }
    } finally {
      learningPackageBusy = false;
      if (learningSelectedItemId === itemId) renderLearningDetail(itemId);
    }
  }

  function currentLearningAnswer(item) {
    const learningPackage = activeLearningPackage(item);
    if (!learningPackage) return '';
    if (learningPackage.exercise.type === 'choice') {
      return document.querySelector('input[name="learning-choice"]:checked')?.value || learningDrafts.get(learningDraftKey(item, learningPackage)) || '';
    }
    return activeLearningEditor?.getValue() || $('#learning-answer')?.value || learningDrafts.get(learningDraftKey(item, learningPackage)) || '';
  }

  async function submitLearningAttempt() {
    const itemId = learningSelectedItemId;
    const item = learningItem(itemId);
    if (!item || learningJudgeBusy) return;
    const answer = currentLearningAnswer(item).trim();
    if (!answer) {
      const field = activeLearningEditor?.getWrapperElement() || $('#learning-answer') || document.querySelector('.learning-choice-list');
      field?.classList.add('needs-answer');
      if (activeLearningEditor) activeLearningEditor.focus();
      else field?.focus?.({ preventScroll: true });
      setTimeout(() => field?.classList.remove('needs-answer'), 900);
      return;
    }
    learningJudgeBusy = true;
    renderLearningDetail(itemId);
    try {
      learningDashboard = await window.api.judgeLearningAttempt(itemId, {
        answer,
        packageId: activeLearningPackage(item)?.id || '',
        expectedRevision: item.revision
      });
      renderLearningContent();
    } catch (error) {
      console.warn('Failed to judge learning attempt:', error);
      const action = document.querySelector('[data-learning-action="submit-attempt"]');
      if (action) {
        action.disabled = false;
        action.textContent = error?.message || '判分失败，请重试';
      }
    } finally {
      learningJudgeBusy = false;
      if (learningSelectedItemId === itemId) {
        renderLearningDetail(itemId);
        requestAnimationFrame(() => document.querySelector('.learning-attempt-result')?.scrollIntoView({ behavior: 'smooth', block: 'center' }));
      }
    }
  }

  async function formatLearningCode() {
    if (!activeLearningEditor) return;
    const editor = activeLearningEditor;
    const source = editor.getValue();
    const item = learningItem(learningSelectedItemId);
    const language = activeLearningPackage(item)?.exercise?.language || item?.language || 'java';
    const cursorOffset = editor.indexFromPos(editor.getCursor());
    const generation = ++learningFormatGeneration;
    const button = document.querySelector('[data-learning-action="format-code"]');
    button?.setAttribute('aria-busy', 'true');
    if (button) button.disabled = true;
    try {
      const result = await window.api.formatLearningCode(language, source, cursorOffset);
      if (generation !== learningFormatGeneration || editor !== activeLearningEditor || editor.getValue() !== source) return;
      if (result?.supported) {
        editor.operation(() => {
          const lastLine = editor.lastLine();
          editor.replaceRange(result.formatted, { line: 0, ch: 0 }, { line: lastLine, ch: editor.getLine(lastLine).length }, '+format');
          editor.setCursor(editor.posFromIndex(result.cursorOffset));
        });
      } else {
        editor.operation(() => {
          for (let line = 0; line < editor.lineCount(); line += 1) editor.indentLine(line, 'smart');
        });
      }
      scheduleLearningSyntaxCheck(editor, language, true);
    } catch (error) {
      setLearningSyntaxStatus('invalid', '格式化失败', error?.message || '代码格式化失败');
    } finally {
      if (generation === learningFormatGeneration) {
        button?.removeAttribute('aria-busy');
        if (button) button.disabled = false;
      }
      if (editor === activeLearningEditor) editor.focus();
    }
  }

  async function openLearningOverlay({ itemId = '', tab = '' } = {}) {
    if (tab) learningTab = tab;
    if (!itemId) {
      learningDetailOpen = false;
      learningSelectedItemId = '';
    }
    openOverlay('#learning-overlay', $('#btn-learning'));
    renderLearningShellChrome();
    window.api.setNativeLearningNavigation?.(learningTab);
    if (learningDashboard) renderLearningContent();
    else $('#learning-content').innerHTML = '<div class="learning-loading"><span></span><strong>正在读取学习档案</strong></div>';
    try {
      $('#learning-sync-state').textContent = '正在补齐未分析消息';
      const [dashboard, lcDashboard] = await Promise.all([
        window.api.flushLearningAnalysis(),
        window.api.getLeetCodeDashboard().catch(() => null)
      ]);
      learningDashboard = dashboard;
      if (lcDashboard) leetcodeDashboard = lcDashboard;
      $('#learning-sync-state').textContent = '已同步全部提问';
      renderLearningContent();
      if (learningTab === 'leetcode' && !leetcodeDashboard?.plans?.length) loadLeetcodeDashboard({ ensurePlan: true });
      if (itemId) renderLearningDetail(itemId);
    } catch (error) {
      $('#learning-content').innerHTML = `<div class="learning-library-empty">${esc(error?.message || '学习档案读取失败')}</div>`;
    }
  }

  function jumpToLearningSource(item, sourceIndex = 0) {
    const ref = item?.sourceRefs?.[sourceIndex];
    if (!ref || !conversations[ref.conversationId]) return;
    videoReturnLearningContext = null;
    openConv(ref.conversationId);
    requestAnimationFrame(() => {
      const message = document.querySelector(`.message[data-message-id="${CSS.escape(ref.messageId)}"]`);
      message?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      if (message) {
        message.classList.add('learning-source-highlight');
        setTimeout(() => message.classList.remove('learning-source-highlight'), 1800);
      }
    });
  }

  function openLearningVideo(item) {
    const ref = item?.sourceRefs?.find(source => conversations[source.conversationId]);
    if (!ref) return;
    openConv(ref.conversationId);
    videoReturnLearningContext = { itemId: item.id, tab: learningTab };
    requestAnimationFrame(() => openVideoWorkspace(ref.messageId));
  }

  function hideOverlays({
    restoreFocus = true,
    restoreScroll = true,
    preserveNativeLearningNavigation = false
  } = {}) {
    destroyActiveLearningEditor();
    destroyActiveLearningMindMap();
    $('#history-overlay').classList.add('hidden');
    $('#usage-overlay').classList.add('hidden');
    $('#settings-overlay').classList.add('hidden');
    $('#learning-overlay').classList.add('hidden');
    $('#learning-detail').classList.add('hidden');
    if (!preserveNativeLearningNavigation) window.api.setNativeLearningNavigation?.(null);
    learningDetailOpen = false;
    for (const button of [$('#btn-history'), $('#btn-usage'), $('#btn-settings'), $('#btn-learning')]) {
      button.setAttribute('aria-expanded', 'false');
    }
    chatContainer.inert = false;
    closeVideoWorkspace({ restoreScroll: false });
    closeModelOptions();
    const trigger = activeOverlayTrigger;
    activeOverlayTrigger = null;
    if (restoreFocus && trigger?.isConnected) trigger.focus({ preventScroll: true });
    // 回到聊天时把视口放回离开前的那一屏（所有面板共用同一套锚点）。
    if (restoreScroll) {
      const anchor = chatScrollAnchor;
      chatScrollAnchor = null;
      restoreMessagesAnchor(anchor);
    }
  }

  function anyPanelOpen() {
    return ['#history-overlay', '#usage-overlay', '#settings-overlay', '#learning-overlay'].some(overlayIsOpen)
      || !$('#video-workspace').classList.contains('hidden');
  }

  function openOverlay(selector, trigger) {
    closeImageViewer({ restoreFocus: false });
    // 面板之间直接切换时跳过入场淡入，避免中间透出底层内容闪一下。
    const switching = anyPanelOpen();
    if (!switching) chatScrollAnchor = captureMessagesAnchor();
    hideOverlays({
      restoreFocus: false,
      restoreScroll: false,
      preserveNativeLearningNavigation: selector === '#learning-overlay'
    });
    activeOverlayTrigger = trigger;
    const overlay = $(selector);
    overlay.classList.toggle('no-entry-anim', switching);
    overlay.classList.remove('hidden');
    trigger.setAttribute('aria-expanded', 'true');
    chatContainer.inert = true;
    overlay.querySelector('.tb-close')?.focus({ preventScroll: true });
    refreshSvgAnimationPlayback();
  }

  function overlayIsOpen(selector) {
    return !$(selector).classList.contains('hidden');
  }

  async function toggleSettingsOverlay() {
    if (overlayIsOpen('#settings-overlay')) {
      hideOverlays();
      return;
    }
    const saved = await window.api.getSettings();
    settingsDraft = normalizeSettingsForUi(saved);
    renderTaskRoutes();
    renderContextSettings();
    selectSettingsProvider(settingsDraft.activeProvider, { refresh: false });
    showSettingsPage('providers');
    openOverlay('#settings-overlay', $('#btn-settings'));
    if (settingsDraft.providers[settingsDraft.activeProvider].apiKey) refreshModels({ quiet: true });
  }

  // ===== Events =====

  document.addEventListener('keydown', event => {
    if (!['Enter', ' '].includes(event.key) || !(event.target instanceof Element)) return;
    const previewImage = event.target.closest('.msg-body img, .tool-artifacts img');
    if (!previewImage) return;
    event.preventDefault();
    openImageViewer(previewImage);
  });

  document.addEventListener('click', e => {
    const copyCodeButton = e.target.closest('.btn-copy');
    if (copyCodeButton) {
      e.preventDefault();
      copyCodeFromButton(copyCodeButton);
      return;
    }
    const leetcodeOverviewButton = e.target.closest('[data-leetcode-overview-view]');
    if (leetcodeOverviewButton) {
      switchLeetcodeOverviewView(leetcodeOverviewButton.dataset.leetcodeOverviewView);
      return;
    }
    const learningSubtab = e.target.closest('[data-learning-subtab]');
    if (learningSubtab) {
      learningTab = learningSubtab.dataset.learningSubtab || 'library';
      learningSelectedItemId = '';
      learningDetailOpen = false;
      learningEditState = null;
      $('#learning-detail').classList.add('hidden');
      renderLearningContent();
      return;
    }
    const railTick = e.target.closest('.chat-rail-tick');
    if (railTick) {
      jumpToQuestion(railTick.dataset.railTarget);
      return;
    }
    const leetcodeCopySubmission = e.target.closest('[data-leetcode-copy-submission]');
    if (leetcodeCopySubmission) {
      const detail = leetcodeSubmissionDetails.get(leetcodeCopySubmission.dataset.leetcodeCopySubmission);
      if (detail?.code) navigator.clipboard.writeText(detail.code).catch(() => {});
      leetcodeCopySubmission.textContent = '已复制';
      setTimeout(() => {
        if (leetcodeCopySubmission.isConnected) leetcodeCopySubmission.textContent = '复制代码';
      }, 1200);
      return;
    }
    const leetcodeAnalyzeSubmission = e.target.closest('[data-leetcode-analyze-submission]');
    if (leetcodeAnalyzeSubmission) {
      analyzeLeetcodeSubmission(leetcodeAnalyzeSubmission.dataset.leetcodeAnalyzeSubmission);
      return;
    }
    const leetcodeProblemTabButton = e.target.closest('[data-leetcode-problem-tab]');
    if (leetcodeProblemTabButton) {
      const tab = leetcodeProblemTabButton.dataset.leetcodeProblemTab;
      if (tab === 'problem') {
        leetcodeWorkspaceProblemTab = 'problem';
        leetcodeWorkspaceSolutionSlug = '';
        leetcodeWorkspaceSolutionsError = '';
        refreshLeetcodeProblemPane();
      } else {
        loadLeetcodeSolutions().catch(error => {
          leetcodeWorkspaceSolutionsBusy = '';
          leetcodeWorkspaceSolutionsError = error?.message || '题解列表加载失败';
          refreshLeetcodeProblemPane();
        });
      }
      return;
    }
    const leetcodeSolutionButton = e.target.closest('[data-leetcode-solution]');
    if (leetcodeSolutionButton) {
      openLeetcodeSolution(leetcodeSolutionButton.dataset.leetcodeSolution).catch(error => {
        leetcodeWorkspaceSolutionsBusy = '';
        leetcodeWorkspaceSolutionsError = error?.message || '题解内容加载失败';
        refreshLeetcodeProblemPane();
      });
      return;
    }
    const leetcodeSolutionAction = e.target.closest('[data-leetcode-solution-action]');
    if (leetcodeSolutionAction) {
      const action = leetcodeSolutionAction.dataset.leetcodeSolutionAction;
      if (action === 'back-list') {
        leetcodeWorkspaceSolutionSlug = '';
        leetcodeWorkspaceSolutionsError = '';
        refreshLeetcodeProblemPane();
      } else if (action === 'retry-list') {
        loadLeetcodeSolutions({ force: true }).catch(error => {
          leetcodeWorkspaceSolutionsBusy = '';
          leetcodeWorkspaceSolutionsError = error?.message || '题解列表加载失败';
          refreshLeetcodeProblemPane();
        });
      }
      return;
    }
    const leetcodeWorkspaceAction = e.target.closest('[data-leetcode-workspace-action]');
    if (leetcodeWorkspaceAction) {
      runLeetcodeWorkspaceAction(leetcodeWorkspaceAction.dataset.leetcodeWorkspaceAction).catch(error => {
        leetcodeWorkspaceError = error?.message || '作答操作失败';
        leetcodeWorkspaceBusy = '';
        if (leetcodeIsWorkspace()) renderLeetcodeWorkspace();
      });
      return;
    }
    const leetcodeExample = e.target.closest('[data-leetcode-example]');
    if (leetcodeExample && leetcodeWorkspace) {
      const example = leetcodeWorkspace.question.exampleTestcases?.[Number(leetcodeExample.dataset.leetcodeExample)];
      if (typeof example === 'string') {
        leetcodeWorkspaceTestcase = example;
        const field = $('#leetcode-workspace-testcase');
        if (field) field.value = example;
        for (const button of document.querySelectorAll('[data-leetcode-example]')) button.classList.toggle('active', button === leetcodeExample);
      }
      return;
    }
    const leetcodeSubmission = e.target.closest('[data-leetcode-submission]');
    if (leetcodeSubmission) {
      toggleLeetcodeSubmissionDetail(leetcodeSubmission.dataset.leetcodeSubmission);
      return;
    }
    const leetcodeAction = e.target.closest('[data-leetcode-action]');
    if (leetcodeAction) {
      runLeetcodeAction(leetcodeAction.dataset.leetcodeAction).catch(error => {
        leetcodeError = error?.message || '力扣操作失败';
        leetcodeBusy = '';
        renderLeetcode();
      });
      return;
    }
    const leetcodeQuestion = e.target.closest('[data-leetcode-question]');
    if (leetcodeQuestion) {
      openLeetcodeQuestion(leetcodeQuestion.dataset.leetcodeQuestion, {
        submissionId: leetcodeQuestion.dataset.leetcodeSubmissionId || '',
        origin: leetcodeQuestion.dataset.leetcodeSubmissionId ? 'recent' : 'library'
      });
      return;
    }
    const leetcodeFilterButton = e.target.closest('[data-leetcode-filter]');
    if (leetcodeFilterButton) {
      leetcodeFilter = leetcodeFilterButton.dataset.leetcodeFilter || 'all';
      renderLeetcode();
      return;
    }
    const templateGenerate = e.target.closest('[data-template-generate]');
    if (templateGenerate) {
      generateLearningTemplateForTopic(templateGenerate.dataset.templateGenerate);
      return;
    }
    const templateCard = e.target.closest('[data-template-key]');
    if (templateCard) {
      renderLearningTemplateDetail(templateCard.dataset.templateKey);
      return;
    }
    const agendaItem = e.target.closest('[data-agenda-item]');
    if (agendaItem) {
      openLearningOverlay({ itemId: agendaItem.dataset.agendaItem, tab: 'library' })
        .catch(error => console.warn('Failed to open agenda item:', error));
      return;
    }
    if (e.target.closest('[data-agenda-action="open-learning"]')) {
      openLearningOverlay({ tab: 'today' })
        .catch(error => console.warn('Failed to open learning center:', error));
      return;
    }
    const messageLearningLink = e.target.closest('[data-learning-message-item]');
    if (messageLearningLink) {
      openLearningOverlay({ itemId: messageLearningLink.dataset.learningMessageItem, tab: 'library' })
        .catch(error => console.warn('Failed to open linked learning item:', error));
      return;
    }
    const learningTypeButton = e.target.closest('[data-learning-type]');
    if (learningTypeButton) {
      learningPracticeType = learningTypeButton.dataset.learningType || 'auto';
      renderLearningDetail(learningSelectedItemId);
      return;
    }
    const learningRating = e.target.closest('[data-learning-rating]');
    if (learningRating) {
      const itemId = learningSelectedItemId;
      const rating = Number(learningRating.dataset.learningRating);
      for (const button of document.querySelectorAll('[data-learning-rating]')) button.disabled = true;
      window.api.reviewLearningItem(itemId, rating).then(dashboard => {
        learningDashboard = dashboard;
        renderLearningContent();
        renderLearningDetail(itemId);
      }).catch(error => {
        console.warn('Failed to record review:', error);
        renderLearningDetail(itemId);
      });
      return;
    }
    const learningSource = e.target.closest('[data-learning-source]');
    if (learningSource) {
      jumpToLearningSource(learningItem(learningSelectedItemId), Number(learningSource.dataset.learningSource));
      return;
    }
    const learningItemButton = e.target.closest('[data-learning-item]');
    if (learningItemButton) {
      renderLearningDetail(learningItemButton.dataset.learningItem);
      return;
    }
    const learningPathButton = e.target.closest('[data-learning-path]');
    if (learningPathButton) {
      learningPath = learningPathButton.dataset.learningPath || '';
      learningLabel = '';
      learningTab = 'library';
      learningSelectedItemId = '';
      learningDetailOpen = false;
      $('#learning-detail').classList.add('hidden');
      renderLearningContent();
      return;
    }
    const learningLabelButton = e.target.closest('[data-learning-label]');
    if (learningLabelButton) {
      learningQuery = learningLabelButton.dataset.learningLabel || '';
      learningLabel = '';
      learningTab = 'library';
      learningSelectedItemId = '';
      learningDetailOpen = false;
      $('#learning-detail').classList.add('hidden');
      renderLearningContent();
      return;
    }
    const learningAction = e.target.closest('[data-learning-action]');
    if (learningAction) {
      const action = learningAction.dataset.learningAction;
      if (action === 'detail-back') {
        learningSelectedItemId = '';
        learningDetailOpen = false;
        learningEditState = null;
        learningDeleteConfirmItemId = '';
        learningDeleteConflict = '';
        $('#learning-detail').classList.add('hidden');
      } else if (action === 'edit-item') {
        startLearningItemEdit(learningItem(learningSelectedItemId));
      } else if (action === 'cancel-edit') {
        learningEditState = null;
        renderLearningDetail(learningSelectedItemId);
      } else if (action === 'save-edit') {
        saveLearningItemEdit();
      } else if (action === 'delete-item') {
        learningEditState = null;
        learningDeleteConfirmItemId = learningSelectedItemId;
        learningDeleteConflict = '';
        renderLearningDetail(learningSelectedItemId);
      } else if (action === 'cancel-delete') {
        learningDeleteConfirmItemId = '';
        learningDeleteConflict = '';
        renderLearningDetail(learningSelectedItemId);
      } else if (action === 'confirm-delete') {
        confirmDeleteLearningItem();
      } else if (action === 'restore-delete') {
        restoreLastDeletedLearningItem();
      } else if (action === 'restore-trash') {
        restoreLearningTrashItem(learningAction.dataset.itemId);
      } else if (action === 'purge-trash') {
        purgeLearningTrashItem(learningAction.dataset.itemId);
      } else if (action === 'generate-template' || action === 'refresh-template') {
        generateLearningTemplateForTopic();
      } else if (action === 'copy-template') {
        const code = learningAction.closest('.learning-template-code')?.querySelector('code')?.textContent || '';
        if (code) navigator.clipboard.writeText(code).catch(() => {});
        learningAction.textContent = '已复制';
        setTimeout(() => { learningAction.textContent = '复制'; }, 1200);
      } else if (action === 'purge-all-trash') {
        purgeAllLearningTrash();
      } else if (action === 'settings') {
        learningSelectedItemId = '';
        learningDetailOpen = true;
        renderLearningSettings();
        $('#learning-detail').classList.remove('hidden');
      } else if (action === 'library') {
        learningTab = 'library';
        renderLearningContent();
      } else if (action === 'clear-path') {
        learningPath = '';
        renderLearningContent();
      } else if (action === 'prepare-study') {
        const item = learningItem(learningSelectedItemId);
        prepareLearningStudy({ force: Boolean(activeLearningPackage(item)) });
      } else if (action === 'submit-attempt') {
        submitLearningAttempt();
      } else if (action === 'format-code') {
        formatLearningCode();
      } else if (action === 'map-collapse') {
        learningMindMapFocusedBranchId = '';
        activeLearningMindMap?.collapse_all();
        activeLearningMindMap?.expand_to_depth(1);
        updateLearningMindMapScope();
        requestAnimationFrame(() => requestAnimationFrame(fitLearningMindMap));
      } else if (action === 'map-expand') {
        learningMindMapFocusedBranchId = '';
        activeLearningMindMap?.expand_all();
        updateLearningMindMapScope();
        requestAnimationFrame(() => requestAnimationFrame(fitLearningMindMap));
      } else if (action === 'map-reset-scope') {
        resetLearningMindMapScope();
      } else if (action === 'map-center-selected') {
        const node = activeLearningMindMap?.get_node(learningMindMapSelectedId);
        if (node) focusLearningMindMapNode(node);
      } else if (action === 'map-fit') {
        fitLearningMindMap();
      } else if (action === 'map-zoom-out') {
        const view = activeLearningMindMap?.view;
        if (view) setLearningMindMapZoom(view.zoom_current - view.opts.zoom.step, activeLearningMindMap.get_selected_node());
      } else if (action === 'map-zoom-in') {
        const view = activeLearningMindMap?.view;
        if (view) setLearningMindMapZoom(view.zoom_current + view.opts.zoom.step, activeLearningMindMap.get_selected_node());
      } else if (action === 'map-search-previous') {
        stepLearningMindMapSearch(-1);
      } else if (action === 'map-search-next') {
        stepLearningMindMapSearch(1);
      } else if (action === 'map-secondary-selected') {
        const node = activeLearningMindMap?.get_node(learningMindMapSelectedId);
        if (!node || node.isroot) resetLearningMindMapScope();
        else focusLearningMindMapBranch(node);
      } else if (action === 'map-open-selected') {
        const node = activeLearningMindMap?.get_node(learningMindMapSelectedId);
        if (!node || node.isroot) fitLearningMindMap();
        else activateLearningMindMapNode(node);
      } else if (action === 'video') {
        openLearningVideo(learningItem(learningSelectedItemId));
      }
      return;
    }
    const previewImage = e.target.closest('.msg-body img, .tool-artifacts img');
    if (previewImage) {
      e.preventDefault();
      openImageViewer(previewImage);
      return;
    }
    const deleteMessageButton = e.target.closest('[data-delete-message]');
    if (deleteMessageButton) {
      if (deleteMessageButton.disabled) return;
      if (deleteMessageButton.dataset.confirm !== 'true') {
        deleteMessageButton.dataset.confirm = 'true';
        deleteMessageButton.classList.add('is-confirming');
        deleteMessageButton.title = '再次点击确认删除';
        deleteMessageButton.setAttribute('aria-label', deleteMessageButton.title);
        setTimeout(() => {
          if (!deleteMessageButton.isConnected) return;
          deleteMessageButton.dataset.confirm = '';
          deleteMessageButton.classList.remove('is-confirming');
          updateMessageDeleteActions();
        }, 1800);
        return;
      }
      deleteMessage(deleteMessageButton.dataset.deleteMessage).catch(error => {
        console.warn('Failed to delete message:', error);
      });
      return;
    }

    const messageVideoButton = e.target.closest('.message-video-action');
    if (messageVideoButton) {
      const questionId = messageVideoButton.dataset.videoQuestion;
      const state = questionVideoState(conversations[currentConvId], questionId, true);
      openVideoWorkspace(questionId, { force: ['error', 'empty'].includes(state?.status) });
      return;
    }

    const candidateButton = e.target.closest('.video-candidate');
    if (candidateButton && currentConvId && activeVideoQuestionId) {
      const conversation = conversations[currentConvId];
      const state = questionVideoState(conversation, activeVideoQuestionId, true);
      const video = normalizeVideoCandidates(state.candidates)
        .find(item => item.bvid === candidateButton.dataset.bvid);
      if (video) {
        invalidateQuestionVideoSearch(currentConvId, activeVideoQuestionId);
        state.video = video;
        state.progress = 0;
        state.duration = 0;
        state.qualityId = 0;
        activeWorkspaceVideo = video;
        saveConv(currentConvId, conversation.messages, { touch: false });
        mountVideoPlayer(video, { force: true });
        recordOpenedVideo(video, currentConvId, activeVideoQuestionId);
        renderVideoCandidates(conversation, activeVideoQuestionId);
      }
      return;
    }

    const deleteVideoHistory = e.target.closest('[data-delete-bvid]');
    if (deleteVideoHistory) {
      e.stopPropagation();
      window.api.removeVideoHistory(deleteVideoHistory.dataset.deleteBvid).then(history => {
        videoHistory = Array.isArray(history) ? history : [];
        renderVideoHistory();
      }).catch(error => console.warn('Failed to remove video history:', error));
      return;
    }

    const historyVideo = e.target.closest('.video-history-item');
    if (historyVideo) {
      const video = videoHistory.find(item => item.bvid === historyVideo.dataset.bvid);
      if (video) {
        invalidateQuestionVideoSearch(currentConvId, activeVideoQuestionId);
        const state = activeQuestionVideoState(true);
        if (state) {
          state.video = normalizeConversationVideo(video);
          state.progress = Number(video.progress) || 0;
          state.duration = Number(video.duration) || 0;
          state.qualityId = 0;
          state.status = 'ready';
        }
        activeWorkspaceVideo = normalizeConversationVideo(video);
        setVideoTab('player');
        mountVideoPlayer(activeWorkspaceVideo, { force: true });
        $('#video-now-source').textContent = '视频历史';
        saveConv(currentConvId, currentMessages, { touch: false });
        recordOpenedVideo(video, currentConvId, activeVideoQuestionId);
      }
      return;
    }

    if (e.target.closest('#btn-refresh-bili-login')) {
      startBilibiliLogin();
      return;
    }

    if (e.target.closest('#btn-bili-logout')) {
      stopLoginPolling();
      window.api.logoutBilibili().then(state => {
        updateBilibiliAuthUi(state);
        startBilibiliLogin();
        if (activeWorkspaceVideo) mountVideoPlayer(activeWorkspaceVideo, { force: true });
      }).catch(error => console.warn('Failed to log out from Bilibili:', error));
      return;
    }

    const modelOption = e.target.closest('.model-option');
    if (modelOption) {
      $('#s-model').value = modelOption.dataset.model || '';
      $('#model-status').classList.remove('error');
      $('#model-status').textContent = '已选择模型';
      closeModelOptions();
      return;
    }

    const replayAnimation = e.target.closest('.svg-animation-replay');
    if (replayAnimation) {
      const block = replayAnimation.closest('.svg-block');
      const svg = block?.querySelector('.svg-canvas svg');
      if (svg && typeof svg.setCurrentTime === 'function') {
        try {
          svg.setCurrentTime(0);
          const state = svgAnimationStates.get(block);
          if (state) applySvgPlaybackState(block, state);
        } catch (error) {
          console.warn('Failed to replay SVG animation:', error);
        }
      }
      return;
    }

    const toggleAnimation = e.target.closest('.svg-animation-toggle');
    if (toggleAnimation) {
      const block = toggleAnimation.closest('.svg-block');
      const svg = block?.querySelector('.svg-canvas svg');
      if (!svg) return;
      const state = svgAnimationStates.get(block) || { userPaused: false, inViewport: isInsideMessageViewport(block) };
      try {
        state.userPaused = !state.userPaused;
        svgAnimationStates.set(block, state);
        block.dataset.animationPaused = state.userPaused ? 'true' : 'false';
        updateSvgToggleButton(toggleAnimation, state.userPaused);
        applySvgPlaybackState(block, state);
      } catch (error) {
        console.warn('Failed to toggle SVG animation:', error);
      }
      return;
    }

    const thinkToggle = e.target.closest('.thinking-header');
    if (thinkToggle) {
      thinkToggle.classList.toggle('open');
      thinkToggle.setAttribute('aria-expanded', thinkToggle.classList.contains('open') ? 'true' : 'false');
      const body = thinkToggle.nextElementSibling;
      body?.classList.toggle('open');
      return;
    }
    const del = e.target.closest('.hist-del');
    if (del) { e.stopPropagation(); deleteConv(del.dataset.id); return; }
    const hist = e.target.closest('.hist-open');
    if (hist) { openConv(hist.dataset.id); return; }
  });

  document.addEventListener('submit', event => {
    if (event.target.id !== 'learning-settings-form') return;
    event.preventDefault();
    const form = new FormData(event.target);
    const submit = event.target.querySelector('button[type="submit"]');
    submit.disabled = true;
    window.api.updateLearningSettings({
      dailyNewTarget: Number(form.get('dailyNewTarget')),
      weekdayReviewTarget: Number(form.get('weekdayReviewTarget')),
      weeklyReviewDay: Number(form.get('weeklyReviewDay')),
      weeklyReviewTarget: Number(form.get('weeklyReviewTarget')),
      preferredLanguage: String(form.get('preferredLanguage') || 'java')
    }).then(dashboard => {
      learningDashboard = dashboard;
      $('#learning-detail').classList.add('hidden');
      renderLearningContent();
    }).catch(error => {
      console.warn('Failed to save learning settings:', error);
      submit.disabled = false;
    });
  });

  $('#btn-send').addEventListener('click', () => {
    if (!isStreaming) {
      sendFollowUp(chatInput.value, selectionDraftPending);
      return;
    }
    if (chatInput.value.trim()) enqueueCurrentDraft();
    else interruptStreamAndSendQueue();
  });
  $('#btn-clear-queue').addEventListener('click', () => {
    if (!activeStream || activeStream.convId !== currentConvId) return;
    activeStream.queue = [];
    renderQueuedMessage();
    updateInput();
  });
  $('#btn-close-video').addEventListener('click', () => closeVideoWorkspace({ returnToQuestion: true }));
  $('#video-tab-player').addEventListener('click', () => setVideoTab('player'));
  $('#video-tab-history').addEventListener('click', () => setVideoTab('history'));
  $('.video-tabs').addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const nextTab = event.key === 'ArrowLeft' || event.key === 'Home' ? 'player' : 'history';
    setVideoTab(nextTab);
    $(`#video-tab-${nextTab}`).focus();
  });
  $('#btn-bili-account').addEventListener('click', openBilibiliAccount);
  $('#btn-close-bili-account').addEventListener('click', () => {
    biliAccountGeneration += 1;
    $('#bili-account-sheet').classList.add('hidden');
    stopLoginPolling();
  });
  $('#video-autoplay-input').addEventListener('change', event => setVideoAutoplay(event.target.checked));
  $('#btn-video-retry').addEventListener('click', () => currentConvId && activeVideoQuestionId && requestQuestionVideo(currentConvId, activeVideoQuestionId, { force: true }));
  $('#btn-video-rematch').addEventListener('click', () => {
    if (!currentConvId || !activeVideoQuestionId) return;
    const conversation = conversations[currentConvId];
    const state = questionVideoState(conversation, activeVideoQuestionId, true);
    const candidates = normalizeVideoCandidates(state.candidates);
    const currentIndex = candidates.findIndex(video => video.bvid === activeWorkspaceVideo?.bvid);
    const next = candidates.length > 1 ? candidates[(currentIndex + 1 + candidates.length) % candidates.length] : null;
    if (next && next.bvid !== activeWorkspaceVideo?.bvid) {
      state.video = next;
      state.progress = 0;
      state.duration = 0;
      state.qualityId = 0;
      activeWorkspaceVideo = next;
      saveConv(currentConvId, conversation.messages, { touch: false });
      mountVideoPlayer(next, { force: true });
      recordOpenedVideo(next, currentConvId, activeVideoQuestionId);
      renderVideoCandidates(conversation, activeVideoQuestionId);
    } else {
      requestQuestionVideo(currentConvId, activeVideoQuestionId, { force: true });
    }
  });
  $('#btn-clear-video-history').addEventListener('click', event => {
    const button = event.currentTarget;
    if (button.dataset.confirm !== 'true') {
      button.dataset.confirm = 'true';
      button.textContent = '确认清空';
      setTimeout(() => { button.dataset.confirm = ''; button.textContent = '清空'; }, 1800);
      return;
    }
    window.api.clearVideoHistory().then(history => {
      videoHistory = Array.isArray(history) ? history : [];
      renderVideoHistory();
    }).catch(error => console.warn('Failed to clear video history:', error));
  });
  $('#btn-clear-video-cache').addEventListener('click', event => {
    const button = event.currentTarget;
    if (button.dataset.confirm !== 'true') {
      button.dataset.confirm = 'true';
      button.classList.add('is-confirming');
      button.title = '再次点击确认清理媒体缓存';
      setTimeout(() => {
        button.dataset.confirm = '';
        button.classList.remove('is-confirming');
        button.title = '清理媒体缓存';
      }, 2200);
      return;
    }
    button.dataset.confirm = '';
    button.classList.remove('is-confirming');
    window.api.clearVideoCache().then(() => {
      refreshVideoCacheBadge();
      if (activeWorkspaceVideo) mountVideoPlayer(activeWorkspaceVideo, { force: true });
    }).catch(error => console.warn('Failed to clear video cache:', error));
  });
  scrollBottomButton.addEventListener('click', () => scrollBottom(true, true));
  document.addEventListener('visibilitychange', () => {
    refreshSvgAnimationPlayback();
    if (document.visibilityState === 'visible' && activeStream) scheduleStreamRender(activeStream);
  });
  window.addEventListener('focus', () => {
    appWindowFocused = true;
    refreshSvgAnimationPlayback();
  });
  window.addEventListener('blur', () => {
    appWindowFocused = false;
    refreshSvgAnimationPlayback();
  });
  // 被动监听，只记录用户意图。代码块内的纵向滚动由 CSS overscroll-behavior-y: auto
  // 自然链到消息区，横向手势由浏览器原生处理；一旦在这里 preventDefault 再手动
  // 改 scrollTop，就等于把系统的惯性滚动整个替掉，滚动会明显不跟手。
  messagesEl.addEventListener('wheel', event => {
    if (Math.abs(event.deltaY) > 0.5) scrollUserIntentUntil = Date.now() + 500;
    if (event.deltaY < 0) {
      windowTransitionPinsBottom = false;
      autoFollow = false;
    }
  }, { passive: true });
  messagesEl.addEventListener('pointerdown', () => {
    scrollUserIntentUntil = Date.now() + 1500;
  }, { passive: true });
  messagesEl.addEventListener('touchstart', event => {
    touchScrollY = event.touches[0]?.clientY ?? null;
    scrollUserIntentUntil = Date.now() + 800;
  }, { passive: true });
  messagesEl.addEventListener('touchmove', event => {
    const nextY = event.touches[0]?.clientY ?? null;
    if (touchScrollY !== null && nextY !== null && nextY > touchScrollY + 2) {
      windowTransitionPinsBottom = false;
      autoFollow = false;
      scrollUserIntentUntil = Date.now() + 500;
    }
    touchScrollY = nextY;
  }, { passive: true });
  messagesEl.addEventListener('touchend', () => { touchScrollY = null; }, { passive: true });
  let scrollIdleTimer = 0;
  messagesEl.addEventListener('scroll', () => {
    const currentScrollTop = messagesEl.scrollTop;
    const userInitiatedScroll = Date.now() < scrollUserIntentUntil;
    if (currentScrollTop < lastScrollTop - 1 && userInitiatedScroll) autoFollow = false;
    if (nearBottom()) autoFollow = true;
    lastScrollTop = currentScrollTop;
    if (userInitiatedScroll) revealChatRailFromScroll();
    scheduleRailActive();
    updateScrollButton();
    const suppressScrollChrome = fullscreenTransitioning || performance.now() < suppressScrollChromeUntil;
    if (suppressScrollChrome) {
      clearTimeout(scrollIdleTimer);
      document.body.classList.remove('is-scrolling');
    } else {
      if (!document.body.classList.contains('is-scrolling')) document.body.classList.add('is-scrolling');
      clearTimeout(scrollIdleTimer);
      scrollIdleTimer = setTimeout(() => document.body.classList.remove('is-scrolling'), 120);
    }
  }, { passive: true });
  document.addEventListener('keydown', event => {
    const target = event.target;
    if (target instanceof HTMLElement
      && (target.matches('input, textarea, select, button') || target.isContentEditable)) return;
    if (!['ArrowUp', 'PageUp', 'Home'].includes(event.key) && !(event.key === ' ' && event.shiftKey)) return;
    autoFollow = false;
    scrollUserIntentUntil = Date.now() + 800;
    updateScrollButton();
  });
  chatInput.addEventListener('keydown', e => {
    if (e.key !== 'Enter' || e.shiftKey || e.isComposing) return;
    e.preventDefault();
    if (isStreaming) enqueueCurrentDraft();
    else sendFollowUp(chatInput.value, selectionDraftPending);
  });
  chatInput.addEventListener('input', () => {
    chatInput.style.height = 'auto';
    chatInput.style.height = Math.min(chatInput.scrollHeight, 100) + 'px';
    updateInput({ refreshMessageActions: false });
  });

  $('#btn-close').addEventListener('click', () => quitApplication());
  $('#btn-minimize').addEventListener('click', () => window.api.minimizeWindow());
  $('#btn-fullscreen').addEventListener('click', () => window.api.toggleFullscreen());
  $('#btn-pin-window').addEventListener('click', async () => {
    const previous = windowPinned;
    renderWindowPinState(!previous);
    try {
      renderWindowPinState(await window.api.setAlwaysOnTop(!previous));
    } catch (error) {
      renderWindowPinState(previous);
      console.warn('Failed to change window pin state:', error);
    }
  });
  window.api.onAlwaysOnTopChanged?.(renderWindowPinState);
  window.api.onFullscreenChanged?.((state) => {
    const shouldKeepBottom = nearBottom();
    document.body.classList.toggle('is-fullscreen', Boolean(state));
    beginWindowTransition(shouldKeepBottom);
    primeChatRail();
    updateZenMode();
  });
  document.addEventListener('pointerover', event => {
    const cell = event.target.closest?.('.leetcode-heatmap i[data-tooltip]');
    if (cell) showLeetcodeHeatmapTooltip(cell, event.clientX, event.clientY);
  }, { passive: true });
  document.addEventListener('pointermove', event => {
    const cell = event.target.closest?.('.leetcode-heatmap i[data-tooltip]');
    if (cell) showLeetcodeHeatmapTooltip(cell, event.clientX, event.clientY);
  }, { passive: true });
  document.addEventListener('pointerout', event => {
    const cell = event.target.closest?.('.leetcode-heatmap i[data-tooltip]');
    if (cell && !event.relatedTarget?.closest?.('.leetcode-heatmap i[data-tooltip]')) hideLeetcodeHeatmapTooltip();
  }, { passive: true });
  document.addEventListener('keydown', revealZenChrome);
  document.addEventListener('pointermove', revealZenChromeFromPointer, { passive: true });
  inputBar.addEventListener('pointerenter', revealZenChrome);
  inputBar.addEventListener('pointerleave', revealZenChrome);

  // 显示器阅读比例只由主进程提交。renderer 不再根据动画中的 window.outerWidth
  // 自己切档，避免跨屏与全屏过程中反复改尺寸。
  function applyDisplayProfile(profile) {
    const displayScale = Math.min(1.5, Math.max(1, Number(profile?.uiScale) || 1));
    document.body.dataset.displayDensity = Number(profile?.scaleFactor) > 1.25 ? 'retina' : 'standard';
    const displayDiagonal = Math.hypot(Number(profile?.width) || 1, Number(profile?.height) || 1);
    const largeDisplayRatio = Math.min(1, Math.max(0, (displayDiagonal - 1800) / 2600));
    railPerspectiveSpread = 3.7 + largeDisplayRatio * 1.5;
    document.body.style.setProperty('--display-scale', displayScale.toFixed(3));
    document.body.style.setProperty('--rail-tick-w', `${(48 - largeDisplayRatio * 6).toFixed(2)}%`);
    document.body.style.setProperty('--rail-gap', `${(13 - largeDisplayRatio).toFixed(2)}px`);
    document.body.style.setProperty('--rail-h', `${(49 + largeDisplayRatio * 2).toFixed(2)}vh`);
    requestAnimationFrame(() => relayoutLearningMindMap());
    primeChatRail();
    refreshResponsiveSvgs();
  }
  window.api.onDisplayProfileChanged?.(applyDisplayProfile);
  window.api.getDisplayProfile?.().then(applyDisplayProfile).catch(error => {
    console.warn('Failed to read initial display profile:', error);
  });

  // 全屏动画期间冻结重排：目标缩放在动画开始前一次定好，过程中不再响应 resize。
  let windowTransitionTimer = 0;
  let windowLayoutTimer = 0;
  function scheduleWindowTransitionBottom() {
    if (!windowTransitionPinsBottom || windowTransitionScrollFrame) return;
    windowTransitionScrollFrame = requestAnimationFrame(() => {
      windowTransitionScrollFrame = 0;
      if (!windowTransitionPinsBottom) return;
      suppressScrollChromeUntil = performance.now() + 180;
      messagesEl.scrollTop = messagesEl.scrollHeight;
      lastScrollTop = messagesEl.scrollTop;
      updateScrollButton();
    });
  }

  function finishWindowTransition() {
    const shouldPinBottom = windowTransitionPinsBottom;
    fullscreenTransitioning = false;
    windowTransitionPinsBottom = false;
    windowTransitioning = false;
    document.body.classList.remove('is-window-transition');
    if (shouldPinBottom) {
      suppressScrollChromeUntil = performance.now() + 240;
      autoFollow = true;
      pinToBottom(4);
    }
    railActiveIndex = -1;
    scheduleRailActive();
    refreshResponsiveSvgs();
  }

  function scheduleWindowTransitionEnd(delay) {
    clearTimeout(windowTransitionTimer);
    windowTransitionTimer = setTimeout(finishWindowTransition, delay);
  }

  function beginWindowTransition(pinBottom = false) {
    fullscreenTransitioning = true;
    windowTransitionPinsBottom = Boolean(pinBottom);
    windowTransitioning = true;
    clearTimeout(windowLayoutTimer);
    clearTimeout(scrollIdleTimer);
    hideChatRailPreview();
    document.body.classList.remove('is-resizing', 'is-scrolling');
    document.body.classList.add('is-window-transition');
    if (windowTransitionPinsBottom) {
      suppressScrollChromeUntil = performance.now() + 800;
      scheduleWindowTransitionBottom();
    }
    // 原生动画时长随显示器而变；没有 resize 时 700ms 兜底，有事件则以下方静默期为准。
    scheduleWindowTransitionEnd(700);
  }

  window.addEventListener('resize', () => {
    if (fullscreenTransitioning) {
      scheduleWindowTransitionBottom();
      scheduleWindowTransitionEnd(140);
      return;
    }
    windowTransitioning = true;
    document.body.classList.add('is-window-transition', 'is-resizing');
    clearTimeout(windowLayoutTimer);
    windowLayoutTimer = setTimeout(() => {
      windowTransitioning = false;
      document.body.classList.remove('is-window-transition', 'is-resizing');
      primeChatRail();
      refreshResponsiveSvgs();
    }, 260);
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') stopClock();
    else if (emptyState && !emptyState.classList.contains('hidden')) startClock();
  });
  $('#btn-close-image-viewer').addEventListener('click', closeImageViewer);
  $('#btn-image-previous').addEventListener('click', () => stepImageViewer(-1));
  $('#btn-image-next').addEventListener('click', () => stepImageViewer(1));
  $('#btn-image-zoom-out').addEventListener('click', () => zoomImageViewer(-0.1));
  $('#btn-image-zoom-in').addEventListener('click', () => zoomImageViewer(0.1));
  $('#btn-image-reset').addEventListener('click', () => { imageViewerZoom = 1; renderImageViewer(); });
  $('#image-viewer-stage').addEventListener('dblclick', () => {
    imageViewerZoom = imageViewerZoom === 1 ? 1.8 : 1;
    renderImageViewer();
  });
  $('#image-viewer').addEventListener('keydown', event => {
    if (event.key === 'ArrowLeft') stepImageViewer(-1);
    if (event.key === 'ArrowRight') stepImageViewer(1);
  });
  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    if (!$('#image-viewer').classList.contains('hidden')) {
      closeImageViewer();
      return;
    }
    if ($('#chat-model-options').dataset.open === 'true') {
      closeQuickModelOptions({ restoreFocus: true });
      return;
    }
    if (!$('#reasoning-options').classList.contains('hidden')) {
      closeReasoningOptions({ restoreFocus: true });
      return;
    }
    if (!$('#bili-account-sheet').classList.contains('hidden')) {
      biliAccountGeneration += 1;
      $('#bili-account-sheet').classList.add('hidden');
      stopLoginPolling();
      return;
    }
    if (!$('#video-workspace').classList.contains('hidden')) {
      closeVideoWorkspace({ returnToQuestion: true });
      return;
    }
    const overlayOpen = [...document.querySelectorAll('.overlay')].some(overlay => !overlay.classList.contains('hidden'));
    if (overlayOpen) {
      hideOverlays();
      return;
    }
    if (activeStream?.convId === currentConvId) {
      interruptStreamAndSendQueue().catch(error => console.warn('Failed to continue queued task:', error));
      return;
    }
    hideWindowAndStop();
  });

  $('#btn-new-chat').addEventListener('click', () => newConversation());
  $('#btn-learning').addEventListener('click', () => {
    if (overlayIsOpen('#learning-overlay')) {
      hideOverlays();
      return;
    }
    openLearningOverlay().catch(error => console.warn('Failed to open learning center:', error));
  });
  $('#btn-close-learning').addEventListener('click', hideOverlays);
  $('#learning-tab-trash').addEventListener('click', () => {
    learningTab = 'trash';
    learningSelectedItemId = '';
    learningDetailOpen = false;
    $('#learning-detail').classList.add('hidden');
    renderLearningContent();
  });
  $('#learning-content').addEventListener('input', event => {
    if (event.target.id === 'leetcode-search-input') {
      leetcodeQuery = event.target.value;
      renderLeetcodeQuestionList();
    } else if (event.target.id === 'leetcode-workspace-testcase') {
      leetcodeWorkspaceTestcase = event.target.value;
    }
  });
  $('#learning-content').addEventListener('keydown', event => {
    if (event.target.id === 'leetcode-plan-input' && event.key === 'Enter') {
      event.preventDefault();
      runLeetcodeAction('import');
    }
  });
  for (const button of document.querySelectorAll('[data-learning-region]')) {
    button.addEventListener('click', () => switchLearningPrimaryRegion(button.dataset.learningRegion));
  }
  $('#learning-content').addEventListener('change', event => {
    if (event.target.id === 'learning-hub-select') {
      learningTab = event.target.value || 'library';
      learningSelectedItemId = '';
      learningDetailOpen = false;
      learningEditState = null;
      $('#learning-detail').classList.add('hidden');
      renderLearningContent();
      return;
    }
    if (event.target.id === 'leetcode-workspace-language') {
      destroyActiveLeetcodeEditor();
      leetcodeWorkspaceLang = event.target.value;
      leetcodeWorkspaceResult = null;
      leetcodeWorkspaceAnalysis = null;
      renderLeetcodeWorkspace();
      return;
    }
    if (event.target.id !== 'leetcode-plan-select') return;
    leetcodeBusy = 'plan';
    window.api.selectLeetCodePlan(event.target.value).then(dashboard => {
      leetcodeDashboard = dashboard;
      leetcodeBusy = '';
      renderLeetcode();
    }).catch(error => {
      leetcodeError = error?.message || '题单切换失败';
      leetcodeBusy = '';
      renderLeetcode();
    });
  });
  $('#btn-history').addEventListener('click', () => {
    if (overlayIsOpen('#history-overlay')) {
      hideOverlays();
      return;
    }
    renderHistory();
    openOverlay('#history-overlay', $('#btn-history'));
    if (currentConvId) maybeAutoSummarize(currentConvId, currentMessages);
  });
  $('#btn-close-history').addEventListener('click', hideOverlays);
  $('#btn-usage').addEventListener('click', () => {
    if (overlayIsOpen('#usage-overlay')) {
      hideOverlays();
      return;
    }
    setUsageScope('current');
    openOverlay('#usage-overlay', $('#btn-usage'));
  });
  $('#btn-close-usage').addEventListener('click', hideOverlays);
  for (const button of document.querySelectorAll('.usage-scope')) {
    button.addEventListener('click', () => setUsageScope(button.dataset.scope));
  }
  $('.usage-segmented').addEventListener('keydown', event => {
    handleHorizontalTabKey(event, '.usage-scope');
  });
  $('#btn-settings').addEventListener('click', () => toggleSettingsOverlay().catch(error => {
    console.error('Failed to load settings:', error);
  }));
  $('#btn-close-settings').addEventListener('click', hideOverlays);
  $('#btn-active-model').addEventListener('click', () => openQuickModelOptions().catch(error => {
    console.warn('Failed to load quick models:', error);
  }));
  $('#chat-model-options').addEventListener('click', event => {
    const option = event.target.closest('[data-quick-provider][data-quick-model]');
    if (option) {
      switchQuickModel(option.dataset.quickProvider, option.dataset.quickModel).catch(error => {
        console.warn('Failed to switch model:', error);
      });
      return;
    }
    if (event.target.closest('#btn-quick-model-settings')) {
      closeQuickModelOptions();
      toggleSettingsOverlay().catch(error => console.warn('Failed to open provider settings:', error));
    }
  });
  $('#btn-reasoning').addEventListener('click', () => {
    closeQuickModelOptions();
    const options = $('#reasoning-options');
    const opening = options.classList.contains('hidden');
    options.classList.toggle('hidden', !opening);
    $('#btn-reasoning').setAttribute('aria-expanded', opening ? 'true' : 'false');
    if (opening) options.querySelector('[aria-checked="true"]')?.focus({ preventScroll: true });
  });
  for (const option of document.querySelectorAll('[data-reasoning-effort]')) {
    option.addEventListener('click', () => setReasoningEffort(option.dataset.reasoningEffort));
  }
  $('#provider-list').addEventListener('click', event => {
    const row = event.target.closest('[data-provider]');
    if (row) selectSettingsProvider(row.dataset.provider);
  });
  $('#btn-add-provider').addEventListener('click', addSettingsProvider);
  $('#btn-delete-provider').addEventListener('click', deleteSettingsProvider);
  $('.settings-nav').addEventListener('click', event => {
    const button = event.target.closest('[data-settings-page]');
    if (button) showSettingsPage(button.dataset.settingsPage);
  });
  $('.settings-nav').addEventListener('keydown', event => handleHorizontalTabKey(event, '[data-settings-page]'));
  $('.task-route-list').addEventListener('change', event => {
    const providerSelect = event.target.closest('[data-task-provider]');
    if (!providerSelect) return;
    const row = providerSelect.closest('[data-task-route]');
    const modelInput = row.querySelector('[data-task-model]');
    modelInput.disabled = !providerSelect.value;
    if (!providerSelect.value) modelInput.value = '';
    else if (!modelInput.value.trim()) modelInput.value = settingsDraft.providers[providerSelect.value]?.model || '';
  });
  $('#context-meter').addEventListener('click', async () => {
    hideContextPopover();
    if (!overlayIsOpen('#settings-overlay')) await toggleSettingsOverlay();
    showSettingsPage('context');
  });
  {
    const meterWrap = document.querySelector('.context-meter-wrap');
    meterWrap?.addEventListener('mouseenter', showContextPopover);
    meterWrap?.addEventListener('mouseleave', hideContextPopover);
    $('#context-meter').addEventListener('focus', showContextPopover);
    $('#context-meter').addEventListener('blur', hideContextPopover);
  }
  for (const links of document.querySelectorAll('.deepseek-account-links')) {
    links.addEventListener('click', event => {
      const button = event.target.closest('[data-provider-link]');
      if (button) window.api.openProviderLink(button.dataset.providerLink).catch(error => showAppError(error?.message));
    });
  }
  $('#btn-refresh-models').addEventListener('click', () => refreshModels());
  $('#btn-toggle-models').addEventListener('click', () => {
    const list = $('#model-options');
    if (list.classList.contains('hidden')) renderModelOptions('');
    else closeModelOptions();
  });
  $('#s-model').addEventListener('focus', () => renderModelOptions(''));
  $('#s-model').addEventListener('input', () => renderModelOptions($('#s-model').value));
  $('#s-key').addEventListener('keydown', event => {
    if (!(event.metaKey || event.ctrlKey) || event.altKey || event.key.toLowerCase() !== 'v') return;
    event.preventDefault();
    window.api.getClipboard().then(text => {
      const input = event.currentTarget;
      const start = Number.isInteger(input.selectionStart) ? input.selectionStart : input.value.length;
      const end = Number.isInteger(input.selectionEnd) ? input.selectionEnd : start;
      input.setRangeText(String(text || ''), start, end, 'end');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }).catch(error => console.warn('Failed to paste API key:', error));
  });
  document.addEventListener('pointerdown', event => {
    if (!event.target.closest('.model-picker')) closeModelOptions();
    if (!event.target.closest('.reasoning-picker')) closeReasoningOptions();
    if (!event.target.closest('.chat-model-picker')) closeQuickModelOptions();
  });
  $('#btn-save-settings').addEventListener('click', async () => {
    const ok = $('#save-ok');
    try {
      const nextAutoplay = videoAutoplay;
      captureSettingsProfile();
      captureTaskRoutes();
      captureContextSettings();
      const profile = settingsDraft.providers[settingsDraft.activeProvider];
      if (!profile.apiBase) throw new Error('请填写 API Base URL');
      if (!profile.model) throw new Error('请填写模型名称');
      const saved = await window.api.saveSettings({
        ...settingsDraft,
        apiBase: profile.apiBase,
        apiKey: profile.apiKey,
        model: profile.model,
        reasoningEffort,
        videoAutoplay: nextAutoplay
      });
      settingsDraft = normalizeSettingsForUi(saved);
      renderActiveModelStatus(saved);
      videoAutoplay = nextAutoplay;
      $('#video-autoplay-input').checked = videoAutoplay;
      ok.textContent = '已保存';
      ok.classList.remove('error');
      ok.classList.remove('hidden');
      setTimeout(() => ok.classList.add('hidden'), 1500);
    } catch (error) {
      console.error('Failed to save settings:', error);
      ok.textContent = error?.message || '保存失败';
      ok.classList.add('error');
      ok.classList.remove('hidden');
    }
  });

  // ===== IPC: new query from main =====
  window.api.onNewQuery(text => {
    handleSelectedText(text).catch(error => {
      console.error('Failed to handle selected text:', error);
    });
  });
  window.api.onSelectionDraft(text => {
    placeSelectionDraft(text).catch(error => {
      console.error('Failed to place selected text:', error);
    });
  });
  window.api.onBilibiliAuthChanged(state => {
    updateBilibiliAuthUi(state);
    if (activeWorkspaceVideo && !$('#video-workspace').classList.contains('hidden')) {
      mountVideoPlayer(activeWorkspaceVideo, { force: true });
    }
  });
  window.api.onLearningUpdated(dashboard => {
    learningDashboard = dashboard;
    $('#learning-sync-state').textContent = '刚刚更新';
    if (!$('#learning-overlay').classList.contains('hidden')) {
      if (!(learningTab === 'leetcode' && leetcodeIsWorkspace())) {
        const content = $('#learning-content');
        const scrollTop = content?.scrollTop || 0;
        renderLearningContent();
        if (learningDetailOpen && learningSelectedItemId) renderLearningDetail(learningSelectedItemId);
        requestAnimationFrame(() => {
          if (content?.isConnected) content.scrollTop = scrollTop;
        });
      }
    }
  });
  window.api.onLearningConversationsUpdated(updates => {
    for (const update of Array.isArray(updates) ? updates : []) {
      const conversation = conversations[update?.conversationId];
      if (!conversation || !update.learningAnnotations || typeof update.learningAnnotations !== 'object') continue;
      conversation.learningAnnotations = update.learningAnnotations;
      if (update.conversationId !== currentConvId) continue;
      for (const message of currentMessages) {
        if (message.role === 'user') updateMessageLearningBadge(message.id);
      }
    }
  });
  window.api.onLeetCodeUpdated(dashboard => {
    leetcodeDashboard = dashboard;
    if (learningTab === 'leetcode' && !$('#learning-overlay').classList.contains('hidden') && !leetcodeIsWorkspace()) renderLeetcode();
  });
  window.api.onLeetCodeJudgeProgress?.((requestId, progress) => {
    updateLeetcodeExecutionNotice(requestId, progress);
  });

  // ===== Init =====
  ensureQuickModelShell($('#chat-model-options'));
  (async () => {
    try {
      const [loaded, settings] = await Promise.all([
        window.api.loadConversations(),
        window.api.getSettings().catch(() => null)
      ]);
      videoAutoplay = settings?.videoAutoplay !== false;
      renderWindowPinState(settings?.alwaysOnTop === true);
      reasoningEffort = normalizeReasoningEffort(settings?.reasoningEffort);
      renderActiveModelStatus(settings);
      if (quickModelSettings) {
        renderQuickModelOptions();
      }
      $('#video-autoplay-input').checked = videoAutoplay;
      renderReasoningControl();
      conversations = loaded && typeof loaded === 'object' && !Array.isArray(loaded) ? loaded : {};
      const latest = Object.entries(conversations)
        .filter(([, conversation]) => conversation && typeof conversation === 'object')
        .sort((a, b) => (Number(b[1].updatedAt) || 0) - (Number(a[1].updatedAt) || 0))[0];
      if (latest) openConv(latest[0]);
      else renderEmptyState();
      setTimeout(() => {
        warmQuickModelCache().catch(error => console.warn('Failed to preload quick models:', error));
        // 预取学习档案：进入全屏时便签已有数据，不会因异步到达再抖一次。
        ensureAgendaData();
      }, 900);
      Promise.all([
        window.api.loadVideoHistory().catch(() => []),
        window.api.getBilibiliAuthState().catch(() => null)
      ]).then(([loadedVideoHistory, authState]) => {
        videoHistory = Array.isArray(loadedVideoHistory) ? loadedVideoHistory : [];
        updateBilibiliAuthUi(authState);
        renderVideoHistory();
      });
    } catch (error) {
      console.error('Failed to load conversations:', error);
      conversations = {};
      renderEmptyState();
    } finally {
      updateInput();
      updateVideoTrigger();
    }
  })();
})();
