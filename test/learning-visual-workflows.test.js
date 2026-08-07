'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const sourcePaths = require('./helpers/source-paths');

const renderer = fs.readFileSync(sourcePaths.renderer, 'utf8');
const styles = fs.readFileSync(sourcePaths.styles, 'utf8');
const index = fs.readFileSync(sourcePaths.index, 'utf8');
const main = fs.readFileSync(sourcePaths.main, 'utf8');
const preload = fs.readFileSync(sourcePaths.preload, 'utf8');
const nativeGlass = fs.readFileSync(path.join(__dirname, '..', 'native', 'liquid_glass.mm'), 'utf8');
const prepareRendererAssets = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'prepare-renderer-assets.js'), 'utf8');

test('mind map preserves its viewport and expanded nodes across data renders', () => {
  assert.match(renderer, /function captureLearningMindMapView\(\)/);
  assert.match(renderer, /expandedIds[\s\S]*scrollLeft[\s\S]*scrollTop/);
  assert.match(renderer, /function restoreLearningMindMapView\(\)/);
  assert.match(renderer, /if \(!restoreLearningMindMapView\(\)\)/);
});

test('mind map supports branch focus and opens item study without implicit editing', () => {
  assert.match(renderer, /function focusLearningMindMapBranch\(/);
  assert.match(renderer, /function resetLearningMindMapScope\(/);
  assert.match(renderer, /data-learning-action="map-center-selected"/);
  assert.match(renderer, /data-learning-action="map-secondary-selected"/);
  assert.match(renderer, /primaryAction\.textContent = data\.itemId \? '进入学习'/);
  assert.match(renderer, /if \(node\?\.data\?\.itemId\) activateLearningMindMapNode\(node\)/);
  assert.doesNotMatch(renderer, /editLearningMindMapItem/);
  assert.match(renderer, /data-learning-action="edit-item"/);
  assert.match(renderer, /class="learning-detail-body is-editing"/);
});

test('mind map resize handling is debounced and preserves the selected anchor', () => {
  assert.match(renderer, /learningMindMapResizeTimer = setTimeout\(/);
  assert.match(renderer, /function relayoutLearningMindMap\(/);
  assert.match(renderer, /map\.view\.update_node\(node\)/);
  assert.match(renderer, /map\.layout\.layout\(\)/);
  assert.match(renderer, /requestAnimationFrame\(\(\) => relayoutLearningMindMap\(\)\)/);
  assert.match(renderer, /Math\.max\(widthChange, heightChange\) > 0\.18/);
  assert.match(renderer, /scroll_node_to_center\(selected\)/);
});

test('LeetCode heatmap fills its container with responsive weekly columns', () => {
  assert.match(renderer, /leetcode-heatmap-week/);
  assert.match(renderer, /--heatmap-weeks:\$\{heatmapWeeks\.length\}/);
  assert.match(styles, /grid-template-columns:\s*repeat\(var\(--heatmap-weeks, 53\), minmax\(0,1fr\)\)/);
  assert.match(styles, /\.leetcode-heatmap i[^}]*aspect-ratio:\s*1/);
  assert.doesNotMatch(styles, /\.leetcode-months\s*\{[^}]*width:\s*448px/);
});

test('LeetCode account and overview navigation stay pinned while content scrolls', () => {
  assert.match(styles, /\.leetcode-account\s*\{[^}]*position:\s*sticky;/s);
  assert.match(styles, /\.leetcode-account\s*\{[^}]*top:\s*0;/s);
  assert.match(styles, /\.leetcode-account\s*\{[^}]*z-index:\s*24;/s);
});

test('recent LeetCode submissions are rendered as an interactive responsive timeline', () => {
  assert.match(renderer, /const recentSubmissions =/);
  assert.match(renderer, /class="leetcode-recent-item"[^>]*data-leetcode-question/);
  assert.match(renderer, /data-leetcode-submission-id="\$\{esc\(submission\.id\)\}"/);
  assert.match(renderer, /class="leetcode-recent-meta"/);
  assert.match(renderer, /leetcodeOverviewView === 'activity'[\s\S]*data-leetcode-overview-panel="activity"/);
  assert.match(renderer, /leetcodeOverviewView === 'submissions'[\s\S]*data-leetcode-overview-panel="submissions"/);
  assert.match(renderer, /leetcodeOverviewView === 'library'[\s\S]*data-leetcode-overview-panel="library"/);
  assert.match(renderer, /class="leetcode-library-shell"/);
  assert.match(styles, /\.leetcode-recent-list::before/);
  assert.doesNotMatch(styles, /\.leetcode-recent-item::before/);
  assert.match(styles, /\.leetcode-recent-item\[data-accepted="true"\]/);
  assert.match(styles, /@container learning-content \(max-width: 560px\)[\s\S]*?\.leetcode-recent-item/);
});

test('LeetCode review keeps the official problem beside the selected submission', () => {
  assert.match(renderer, /class="leetcode-review-grid"/);
  assert.match(renderer, /function leetcodeQuestionProblemHtml\(/);
  assert.match(renderer, /leetcodeQuestionWorkspaces\.get\(slug\)/);
  assert.match(styles, /\.leetcode-review-grid[^}]*grid-template-columns/);
  assert.match(styles, /\.leetcode-detail-view[^}]*grid-template-rows:\s*auto minmax\(0,1fr\)/);
  assert.match(styles, /\.leetcode-review-problem-body[^}]*overflow-y:\s*auto/);
});

test('learning library groups problems by category instead of exposing raw tag noise', () => {
  assert.match(renderer, /function learningCategory\(/);
  assert.match(renderer, /class="learning-question-group"/);
  assert.match(renderer, /class="learning-category-filter"/);
  assert.doesNotMatch(renderer, /class="learning-label-filter" aria-label="知识标签筛选"/);
});

test('learning insights use a responsive dashboard and interactive submission timeline', () => {
  assert.match(renderer, /const recentTimeline = \(dashboard\.timeline \|\| \[\]\)\.slice\(0, 10\)/);
  assert.match(renderer, /class="learning-insight-score"/);
  assert.match(renderer, /class="learning-record-timeline"/);
  assert.match(renderer, /data-learning-item="\$\{esc\(event\.itemId\)\}" data-signal=/);
  assert.match(renderer, /class="learning-timeline-meta"/);
  assert.match(styles, /container-name:\s*learning-content/);
  assert.match(styles, /grid-template-areas:[\s\S]*?"activity timeline"[\s\S]*?"weak timeline"/);
  assert.match(styles, /@container learning-content \(max-width: 899px\)/);
  assert.match(styles, /@container learning-content \(max-width: 560px\)[\s\S]*?grid-template-columns:\s*repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(styles, /\.learning-timeline-copy > small[\s\S]*?-webkit-line-clamp:\s*2/);
  assert.match(styles, /\.learning-record-timeline > button::before/);
  assert.match(styles, /\.learning-record-timeline > button:hover/);
});

test('learning navigation uses the native fullscreen toolbar instead of edge guessing', () => {
  assert.match(nativeGlass, /NSToolbar/);
  assert.match(nativeGlass, /NSWindowWillEnterFullScreenNotification/);
  assert.match(nativeGlass, /NSWindowDidExitFullScreenNotification/);
  assert.match(nativeGlass, /NSApplicationPresentationAutoHideToolbar/);
  assert.match(nativeGlass, /willUseFullScreenPresentationOptions/);
  assert.match(nativeGlass, /LeetCodeWindowDelegateProxy/);
  assert.match(nativeGlass, /navigationActive/);
  assert.match(nativeGlass, /NSGlassEffectView/);
  assert.match(nativeGlass, /NSWindowDidChangeScreenNotification/);
  assert.match(nativeGlass, /NSWindowDidChangeBackingPropertiesNotification/);
  assert.match(nativeGlass, /NSWindowDidEnterFullScreenNotification/);
  assert.match(nativeGlass, /LeetCodeNavigationItemIdentifier/);
  assert.match(nativeGlass, /centeredItemIdentifiers = \[NSSet setWithObject:LeetCodeNavigationItemIdentifier\]/);
  assert.match(nativeGlass, /initWithLabels:@\[@"今日", @"力扣", @"知识库", @"洞察"\]/);
  assert.match(nativeGlass, /NSWindowToolbarStyleUnifiedCompact/);
  assert.match(nativeGlass, /NSTitlebarSeparatorStyleNone/);
  assert.doesNotMatch(nativeGlass, /NSToolbarFlexibleSpaceItemIdentifier/);
  assert.match(main, /still hidden[\s\S]*installNativeNavigationToolbar\(window\)/);
  assert.match(main, /installNativeNavigationToolbar/);
  assert.match(preload, /setNativeLearningNavigation/);
  assert.match(renderer, /setNativeLearningNavigation/);
  assert.match(renderer, /preserveNativeLearningNavigation:\s*selector === '#learning-overlay'/);
  assert.match(main, /setNavigationToolbarSelection\(nativeLearningAction\)/);
  assert.match(styles, /body\.is-fullscreen \.learning-overlay \.learning-header\s*\{[^}]*display:\s*none/s);
  assert.doesNotMatch(renderer, /syncFullscreenLearningHeaderReveal|learning-header-revealed|clientY\s*<=\s*92/);
  assert.doesNotMatch(styles, /body\.is-fullscreen \.learning-shell[^}]*padding-top/s);
  assert.match(styles, /\.learning-header\s*\{[^}]*position:\s*relative/s);
  assert.match(index, /id="learning-region-select"[^>]*aria-label="学习区域"/);
  assert.match(index, /data-learning-subtab="knowledge"/);
  assert.match(renderer, /\[\['library', '题目清单'\], \['activity', '学习活动'\], \['submissions', '提交记录'\]\]/);
  assert.match(renderer, /:\s*'library';/);
  assert.match(styles, /\.learning-region-picker[\s\S]*\.learning-context-nav/);
  assert.doesNotMatch(index, /learning-sidebar/);
  assert.doesNotMatch(renderer, /toggleLearningSidebar|syncLearningResponsiveLayout/);
  assert.doesNotMatch(styles, /sidebar-collapsed|sidebar-drawer-open/);
  assert.doesNotMatch(main, /toggle-learning-sidebar/);
  assert.doesNotMatch(nativeGlass, /LeetCodeSidebarItemIdentifier|sidebar\.left/);
});

test('knowledge base opens on the mind map by default', () => {
  assert.match(index, /<option value="knowledge">知识库<\/option>/);
  assert.match(renderer, /library:\s*'knowledge'/);
});

test('native learning navigation derives consistent inset and radii from its live bounds', () => {
  assert.match(nativeGlass, /return MIN\(5\.0, MAX\(3\.0, round\(NSHeight\(self\.bounds\) \* 0\.105\)\)\)/);
  assert.match(nativeGlass, /const CGFloat width = MAX\(0\.0, slotWidth\)/);
  assert.match(nativeGlass, /NSHeight\(self\.bounds\) \* 0\.5 - \[self contentInset\]/);
  assert.match(nativeGlass, /context\.duration = 0\.28/);
  assert.match(nativeGlass, /hypot\(point\.x - initialPoint\.x, point\.y - initialPoint\.y\) < 3\.0/);
  assert.doesNotMatch(nativeGlass, /_backgroundGlass/);
  assert.doesNotMatch(nativeGlass, /contentVerticalOffset/);
  assert.match(nativeGlass, /self\.layer\.masksToBounds = YES/);
  assert.match(nativeGlass, /self\.layer\.cornerCurve = kCACornerCurveContinuous/);
  assert.match(nativeGlass, /self\.layer\.cornerRadius = cornerRadius/);
});

test('LeetCode workspace exposes responsive previous and next question navigation', () => {
  assert.match(renderer, /function leetcodeWorkspaceNavigation\(\)/);
  assert.match(renderer, /data-leetcode-workspace-action="previous-question"/);
  assert.match(renderer, /data-leetcode-workspace-action="next-question"/);
  assert.match(renderer, /async function moveLeetcodeWorkspaceQuestion\(direction\)/);
  assert.match(styles, /\.leetcode-question-stepper[^}]*grid-template-columns:\s*auto minmax\(44px,auto\) auto/);
  assert.match(styles, /@media \(max-width: 620px\)[\s\S]*?\.leetcode-question-stepper output\s*\{\s*display:\s*none;/);
  assert.match(renderer, /async function openLeetcodeWorkspace\(\)[\s\S]*?destroyActiveLeetcodeEditor\(\);[\s\S]*?leetcodeWorkspace = leetcodeQuestionWorkspaces\.get\(slug\)/);
});

test('LeetCode question rows expose mastery and overdue review tones', () => {
  assert.match(renderer, /function leetcodeQuestionMasteryTone\(/);
  assert.match(renderer, /data-mastery="\$\{leetcodeQuestionMasteryTone\(question\)\}"/);
  assert.match(styles, /\.leetcode-question-row\[data-mastery="mastered"\]/);
  assert.match(styles, /\.leetcode-question-row\[data-mastery="review"\]/);
});

test('submission history expands lazy-loaded code and diagnostics', () => {
  assert.match(main, /async function getLeetCodeSubmissionDetail\(submissionId\)/);
  assert.match(main, /ipcMain\.handle\('get-leetcode-submission-detail'/);
  assert.match(preload, /getLeetCodeSubmissionDetail:/);
  assert.match(renderer, /window\.api\.getLeetCodeSubmissionDetail\(id\)/);
  assert.match(renderer, /data-leetcode-submission=/);
  assert.match(renderer, /leetcode-submission-diagnostics/);
  assert.match(renderer, /leetcode-submission-code/);
  assert.match(styles, /\.leetcode-submission-code > pre/);
  assert.match(renderer, /leetcode-performance-ranking/);
  assert.match(renderer, /官方同语言提交排行/);
  assert.match(styles, /\.leetcode-percentile-chart/);
});

test('heatmap cells expose visible per-day tooltip text', () => {
  assert.match(renderer, /data-tooltip="\$\{esc\(day\.date\)\} · \$\{day\.count\} 次提交"/);
  assert.match(renderer, /function showLeetcodeHeatmapTooltip\(/);
  assert.match(renderer, /\.leetcode-heatmap i\[data-tooltip\]/);
  assert.match(styles, /\.leetcode-heatmap-tooltip\s*\{/);
  assert.doesNotMatch(styles, /\.leetcode-heatmap i\[data-tooltip\]::after/);
});

test('display profile is available both initially and on later monitor changes', () => {
  assert.match(main, /ipcMain\.handle\('get-display-profile'/);
  assert.match(preload, /getDisplayProfile:/);
  assert.match(renderer, /window\.api\.getDisplayProfile\?\.\(\)\.then\(applyDisplayProfile\)/);
});

test('LeetCode workspace formats the returned formatted field and falls back to smart indentation', () => {
  assert.match(renderer, /typeof result\.formatted === 'string'/);
  assert.match(renderer, /editor\.replaceRange\(result\.formatted[\s\S]*?'\+format'/);
  assert.match(renderer, /editor\.indentLine\(line, 'smart'\)/);
});

test('LeetCode execution updates feedback without rebuilding the active editor', () => {
  assert.match(renderer, /function refreshLeetcodeWorkspaceExecutionUi\(\)/);
  assert.match(renderer, /leetcodeWorkspaceBusy = action;[\s\S]*refreshLeetcodeWorkspaceExecutionUi\(\)/);
  assert.match(renderer, /leetcodeIsWorkspace\(\)\) refreshLeetcodeWorkspaceExecutionUi\(\)/);
  assert.match(renderer, /if \(!leetcodeIsWorkspace\(\)/);
});

test('LeetCode editor validates syntax while typing and before remote execution', () => {
  assert.match(renderer, /gutters:\s*\['CodeMirror-lint-markers', 'CodeMirror-linenumbers'\]/);
  assert.match(renderer, /scheduleLeetcodeSyntaxCheck\(editor\)/);
  assert.match(renderer, /await validateLeetcodeWorkspaceSyntax\(\{ focusFirst: true \}\)/);
  assert.match(renderer, /kind:\s*'syntax'/);
  assert.match(renderer, /editor\.setCursor\(editor\.posFromIndex\(first\)\)/);
  assert.match(styles, /\.leetcode-code-status\[data-state="invalid"\]/);
});

test('LeetCode run task ids accept the dotted official runcode format', () => {
  assert.match(main, /\^\[a-z0-9_\.\-\]\{1,120\}\$/i);
  assert.match(main, /error\.statusCode !== 404/);
});

test('LeetCode workspace uses a responsive persistent Split.js layout', () => {
  assert.match(renderer, /\.renderer-assets\/split\.js\/dist\/split\.min\.js/);
  assert.match(renderer, /leetcode-workspace-split-\$\{direction\}/);
  assert.match(renderer, /direction = grid\.clientWidth <= 820 \? 'vertical' : 'horizontal'/);
  assert.match(renderer, /onDrag:\s*refreshLeetcodeEditorAfterSplit/);
  assert.match(renderer, /activeLeetcodeWorkspaceSplit\?\.destroy\?\.\(\)/);
  assert.match(styles, /\.leetcode-workspace-grid\[data-split-direction="vertical"\]/);
  assert.match(styles, /\.leetcode-workspace-grid > \.gutter-horizontal/);
  assert.match(renderer, /activeLeetcodeEditorSplit = window\.Split\(\[editorPane, feedbackPane\]/);
  assert.match(renderer, /leetcode-workspace-editor-split/);
  assert.match(renderer, /调整代码与官方样例高度/);
  assert.match(styles, /\.leetcode-code-workarea > \.gutter/);
  assert.match(styles, /\.leetcode-code-feedback/);
});

test('LeetCode solutions load lazily inside the problem pane', () => {
  assert.match(preload, /getLeetCodeSolutions:/);
  assert.match(preload, /getLeetCodeSolution:/);
  assert.match(renderer, /data-leetcode-problem-tab="solutions"/);
  assert.match(renderer, /async function loadLeetcodeSolutions/);
  assert.match(renderer, /async function openLeetcodeSolution/);
  assert.match(renderer, /window\.api\.getLeetCodeSolutions\(slug\)/);
  assert.match(renderer, /window\.api\.getLeetCodeSolution\(slug\)/);
  assert.match(renderer, /leetcode-solution-markdown/);
  assert.match(styles, /\.leetcode-solution-list/);
});

test('LeetCode problem and solution videos use a strict native media renderer', () => {
  assert.match(renderer, /function safeLeetcodeVideoSource/);
  assert.match(renderer, /url\.protocol !== 'https:'/);
  assert.match(renderer, /\\\.\(mp4\|webm\)/);
  assert.match(renderer, /controls preload="metadata" playsinline/);
  assert.match(renderer, /FORBID_TAGS:\s*\['script', 'style', 'iframe'/);
  assert.match(renderer, /renderLeetcodeSolutionContent/);
  assert.match(renderer, /!\\\[[^\n]*mp4\|webm/);
  assert.match(renderer, /safeLeetcodeVideoUrlHtml/);
  assert.match(renderer, /listPayload\?\.officialSolutionSlug === leetcodeWorkspaceSolutionSlug/);
  assert.match(styles, /\.leetcode-content-video/);
});

test('official LeetCode UUID videos resolve play auth and mount the packaged player lazily', () => {
  assert.match(main, /videosVideoInfo\(uuid: \$uuid, fetchType: PLAY_AUTH\)/);
  assert.match(main, /async function getLeetCodeVideoInfo/);
  assert.match(preload, /getLeetCodeVideoInfo:/);
  assert.match(renderer, /data-leetcode-video-uuid/);
  assert.match(renderer, /function ensureLeetcodeVideoRuntime/);
  assert.match(renderer, /skins\/default\/aliplayer-min\.css/);
  assert.match(renderer, /aliyun-aliplayer\/build\/browser-aliplayer\.min\.js/);
  assert.match(styles, /\.CodeMirror-hints\s*\{[\s\S]*?z-index:\s*10000\s*!important/);
  assert.match(renderer, /playauth: info\.playAuth/);
  assert.match(renderer, /assetPrefix:\s*new URL\('\.\.\/\.\.\/\.renderer-assets\/aliyun-aliplayer\/build'/);
  assert.match(prepareRendererAssets, /window\.Aliplayer=factory\(\)/);
  assert.match(prepareRendererAssets, /AliPlayer CSP-safe browser transform failed/);
});

test('LeetCode rich content renders math, image galleries, and distinct difficulty metadata', () => {
  assert.match(renderer, /window\.katex\.renderToString/);
  assert.match(renderer, /function enhanceLeetcodeImageGalleries/);
  assert.match(renderer, /data-gallery-action="play"/);
  assert.match(renderer, /class="leetcode-workspace-meta"/);
  assert.match(styles, /\.leetcode-workspace-meta b\[data-difficulty="HARD"\]/);
  assert.match(styles, /\.leetcode-image-gallery-stage/);
  assert.match(styles, /\.learning-overlay \.leetcode-solution-title em[\s\S]*?font-size:\s*calc\(11px \* var\(--display-scale\)\)/);
});

test('AI answers render math, consolidate language variants, and carousel image sequences', () => {
  assert.match(renderer, /function protectMarkdownMath\(/);
  assert.match(renderer, /\\\[([\s\S]+?)\\\]/);
  assert.match(renderer, /function enhanceCodeLanguageTabs\(/);
  assert.match(renderer, /const preferred = languages\.includes\('java'\) \? 'java' : languages\[0\]/);
  assert.match(renderer, /className = 'code-language-group'/);
  assert.match(renderer, /class="code-language-toolbar"/);
  assert.match(renderer, /codeCopyButtonHtml\('code-group-copy'\)/);
  assert.match(renderer, /function copyCodeFromButton\(button\)/);
  assert.match(renderer, /await window\.api\.setClipboard\(code\)/);
  assert.match(preload, /setClipboard:\s*\(text\) => ipcRenderer\.invoke\('set-clipboard', text\)/);
  assert.match(main, /ipcMain\.handle\('set-clipboard'/);
  assert.match(styles, /\.code-language-group \.code-header\s*\{\s*display:\s*none/);
  assert.match(styles, /\.copy-glyph::before/);
  assert.match(renderer, /class="leetcode-image-gallery-track"/);
  assert.match(renderer, /pointermove/);
  assert.match(renderer, /Math\.abs\(event\.deltaX\)/);
  assert.match(styles, /\.leetcode-image-gallery-track\s*\{[^}]*display:\s*flex/);
  assert.match(renderer, /<\(\(\?:!\\\[[^\n]+\{2,\}/);
  assert.match(renderer, /images\.replace\(\/\\\)\\s\*\,\\s\*\(\?=!\\\[\)\/g/);
});

test('learning detail typography and isolated edit form follow display scale', () => {
  assert.match(styles, /\.learning-overlay \.learning-detail > header strong\s*\{[^}]*font-size:\s*calc\(13px \* var\(--display-scale\)\)/);
  assert.match(styles, /\.learning-overlay \.learning-edit-panel input:not\(\[type="checkbox"\]\)[\s\S]*?font-size:\s*calc\(12px \* var\(--display-scale\)\)/);
  assert.match(styles, /\.learning-overlay \.learning-detail-body\.is-editing/);
  assert.match(styles, /width:\s*min\(100%, calc\(880px \* var\(--display-scale\)\)\)/);
  assert.match(styles, /\.learning-overlay \.learning-evidence > div p\s*\{[^}]*font-size:\s*calc\(12px \* var\(--display-scale\)\)/);
  assert.match(styles, /\.learning-overlay \.learning-sources > button > strong\s*\{[^}]*font-size:\s*calc\(12px \* var\(--display-scale\)\)/);
});

test('AI-generated study content uses rich rendering and a readable assessment scale', () => {
  assert.match(renderer, /function renderLearningMarkdown\(/);
  assert.match(renderer, /class="learning-exercise-prompt learning-rich-text"/);
  assert.match(renderer, /renderLearningMarkdown\(exercise\.prompt\)/);
  assert.match(renderer, /renderLearningMarkdown\(latestAttempt\.feedback\)/);
  assert.match(styles, /\.learning-overlay \.learning-exercise-prompt\s*\{[^}]*font-size:\s*calc\(14\.5px \* var\(--display-scale\)\)/);
  assert.match(styles, /\.learning-overlay \.learning-lesson pre\s*\{[^}]*font-size:\s*calc\(12\.5px \* var\(--display-scale\)\)/);
});

test('submission AI analysis action keeps readable text contrast and dynamic sizing', () => {
  assert.match(styles, /\.is-analysis span\s*\{[^}]*color:\s*inherit;[^}]*font-size:\s*inherit/);
  assert.match(styles, /\.learning-overlay \.leetcode-submission-detail > header \.leetcode-submission-detail-actions button\s*\{[^}]*font-size:\s*calc\(11\.5px \* var\(--display-scale\)\)/);
});

test('refresh icon controls retain a circular fixed-size shape', () => {
  assert.match(styles, /\.model-refresh\s*\{[\s\S]*?border-radius:\s*50%/);
  assert.match(styles, /\.leetcode-account-actions \.leetcode-sync-action\s*\{[\s\S]*?width:\s*30px;[\s\S]*?height:\s*30px;[\s\S]*?border-radius:\s*50%/);
});

test('Java completion keeps local hints responsive and ignores stale remote responses', () => {
  assert.match(preload, /getRemoteCodeCompletions:/);
  assert.match(renderer, /function mergeRemoteCodeCompletions/);
  assert.match(renderer, /show\(\[\]\);/);
  assert.match(renderer, /getRemoteCodeCompletions\(\{/);
  assert.match(renderer, /language:\s*'java'/);
  assert.match(renderer, /completionRequestStillCurrent/);
  assert.match(renderer, /editor\.on\('inputRead', onInput\)/);
  assert.match(renderer, /prefix\.length >= 1 \|\| line\.endsWith\('\.'\)/);
  assert.match(styles, /\.CodeMirror-hint-active[\s\S]*?background:\s*rgba\(47,106,137,\.11\)\s*!important/);
  assert.match(styles, /font:\s*clamp\(10\.5px/);
  assert.match(renderer, /JAVA_CONSTRUCTOR_COMPLETIONS/);
  assert.match(renderer, /function javaSymbolsBeforeCursor/);
  assert.match(renderer, /constructorContext[\s\S]*?open\(\)/);
  assert.match(renderer, /show\(\[\]\);[\s\S]*await window\.api\.getRemoteCodeCompletions/);
  assert.doesNotMatch(renderer, /setTimeout\(\(\) => resolve\(null\), 220\)/);
});

test('workspace can restore the official language template without destroying undo history', () => {
  assert.match(renderer, /data-leetcode-workspace-action="reset-code"/);
  assert.match(renderer, /function leetcodeWorkspaceTemplateCode/);
  assert.match(renderer, /editor\.replaceRange\(template[\s\S]*?'\+reset'/);
  assert.match(renderer, /scheduleLeetcodeSyntaxCheck\(editor, true\)/);
});
