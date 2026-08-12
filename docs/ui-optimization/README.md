# 界面优化任务总览（UI Optimization Tasks）

> 范围：`native/Sources/LeetCodeAssistant` 全部页面。文档按页面拆分为 11 份任务书，本文件是总纲：定义三条全局主线、六个共用任务（G-T）、全局进度表。行号基于 2026-08-10 的代码快照，引用时以"关键字 + 周边结构"复核，防止行号漂移误导。

## 一、问题全景（实测）

界面目前"几个顶部、几条分界线"的量化事实：

| 页面 | 顶部从上到下的堆叠 | 顶条数 | 页面内横 Divider |
|---|---|---|---|
| 对话 | titlebar → 消息区 → composer | 1（标杆） | 1（队列条下） |
| 力扣·题库 | titlebar → overviewToolbar(46) → summaryStrip(68) → 筛选条(44) → 列表 | 3 | 3+ |
| 力扣·题目/作答 | titlebar → questionToolbar(46) → [editorToolbar(42)] | 最多 3 | 1 |
| 学习计划 | titlebar → header(58) → summaryStrip(64) → 日历头(46)/图例(42)/时间线头 | 3–4 | 4 |
| 复习 | titlebar → 队列头(44) → 搜索条 → 详情大标题 | 2 | 2 |
| 学习库 | titlebar → 分类条 → 搜索条 → 详情区底部操作条(48/.bar) | 2+1 底 | 2 |
| 知识图谱 | titlebar → graphToolbar(46) | 2 | 0 |
| 模板 / 回收站 | titlebar → 搜索或 header(54) | 2 | 1 |
| 设置 | 侧栏：返回条(32) + 搜索胶囊(40)；详情：28pt 大标题区 | 3 | — |
| 工具面板 | inspector 内地址条 | 1 | 1 |

系统性数值债：`.system(size:)` 硬编码 115 处、26 种取值（含 8/9.5/10.5/11.5/12.5/13.5/14.5 七种半点）；裸 padding 214 处 vs Spacing token 仅 5 次引用；cornerRadius 9 种取值（7、10、12、14、20 不在 token 内）；页面头高度 42/44/46/48/54/58 六档。

## 二、三条全局主线

### 主线 1：一顶（One Chrome）
全窗口只有**一根全局顶条**（系统 titlebar，承载前进/后退/新建/标题/右侧操作组）。每个页面内容区内**最多一根页面头**，高度统一走两档：`PageHeader.standard = 44`（列表类）与 `PageHeader.prominent = 54`（带主按钮的页面，对齐现回收站做法）。页面内**禁止再叠第二根功能横条**——二级控件并入页面头或内容区封面。

### 主线 2：两线（Two Dividers）
横分割线只用于"语义断层"（块与块的职责切换），不用于"同类块的视觉排队"。每页页面级横 Divider **≤ 2 根**；同类列表行优先用留白（8pt 纵向 spacing）替代行间线。统一 divider 样式：`.primary.opacity(0.075)`、按需前导缩进，禁止 0.32/0.09 等散点值。分栏竖线交给 NavigationSplitView/HSplitView 自带，不自绘。

### 主线 3：一阶梯（One Ramp）
字体一步走 macOS 语义阶梯，收敛为单一 token 组（见 G-T1）；间距、圆角、行高、图标口径全部 token 化（G-T2/G-T5），消灭半点字号与 7/18/22/26/34/44 等野生间距。

## 三、参照系：Codex 客户端的整体感从哪来（实测观察）

对照 Codex(ChatGPT) mac 客户端截图，整体感=**减少"面"和"线"的数量**，而不是加上去：

1. **全窗只有两个面**：浅灰侧栏 + 白内容，中间一根竖线；titlebar 与内容同白色，融为一体，看不见"工具栏底边"。
2. **侧栏零横线**：品牌行、新会话、列表、账户之间全部只用留白分组，无一根水平 Divider。
3. **单列限宽**：内容区一根中轴列，超宽屏才居中留白；composer 底部悬浮居中，与列表共用同一中轴。
4. **无系统蓝控件**：没有 macOS 默认蓝色的 segmented / 下拉指示器；切换器是自绘灰底胶囊，菜单箭头是低调的三级色 chevron。
5. **滚动条贴内容边缘**：细条、无轨道底、只在滚动时可见，且永远压在内容内侧，不与分割线/面板边叠加。

映射到我们的行动：主线 1/2 已覆盖 1-3；新增 G-T7 覆盖 4。滚动条：我们"隐藏滚动条"为有意设计（红线不变），Codex 的做法与它不冲突——**前提是内容内缘永远有安全 padding，任何文字不贴窗口/面板边缘**（刷题页当前的贴边裁切即反例，见 03）。

## 四、共用任务（G-T，各页面任务引用这里的编号）

| 编号 | 任务 | 说明 | 验收 |
|---|---|---|---|
| G-T1 | 建立 `AppDesign.Typography` 字体阶梯 | 新增 token：`display(26 semibold)`、`pageTitle(22 semibold)`、`metricValue(22 semibold + monospacedDigit)`、`sectionTitle(17 semibold)`、`rowTitle(15 medium)`、`body(13)`、`aux(12)`、`micro(11)`、`mono(12)`；禁止在 View 里新增 `.system(size:)`，存量按页面分批替换 | View 层硬编码字号清零（26 种 → 9 档 token），半点字号清零 |
| G-T2 | 间距/圆角 token 化扫尾 | 把高频野值并入 token：新增 `Spacing.compact(10)`、`Spacing.rowInset(14)`、`Spacing.section(28)`；Radius 收敛为 6/8/10/16/22，删除 7/12/14/20 | Views 层裸 padding/radius 数字为 0（`Padding()` 无参与 token 除外）|
| G-T3 | `PageHeader` 统一组件 | 新建 `Design/PageHeader.swift`：标准 44 / 加强 54 两档，左标题（15 semibold）+ 副标题（12 secondary）+ 右侧操作区；各页面替换自绘 header/toolbar | 全 App 页面头高度只剩 44/54 两种 |
| G-T4 | 分界线收敛 | 按主线 2 逐页治理，删除同类排队线；保留语义断层线并统一 opacity/缩进 | 每页页面级横 Divider ≤ 2 根 |
| G-T5 | 图标口径统一 | 行内图标统一 `.font(.system(size: 15))` 或 `.body` 级 SF Symbols；槽位统一宽 24；一切 icon-only 按钮命中区 ≥ 28×28（对齐 `Size.toolbarControl`）| 无 <28 的裸 icon-only 点击区；同列图标左缘对齐 |
| G-T6 | 选中色/材质统一 | 新增 `ColorToken.listSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)`（系统列表惯例，06 页已实现为原型），全 App 列表选中收敛到它；卡片表面统一走 `navigationGlass` 或 `raised`，消灭手写的 `primary.opacity(0.065/0.075/0.13)` 混用；按需补充 `ColorToken.hover`(primary 0.05) 与 `ColorToken.info`(系统蓝) | 选中态/悬停态全 App 各一种实现 |
| G-T7 | **控件形态统一（去系统蓝）** | 新建 `Design/SegmentedControl.swift` + `Design/DropdownMenuLabel.swift`：选中态 = 灰底胶囊（`listSelection` 或 `primary 0.08`），不用 `.pickerStyle(.segmented)` 的系统蓝；下拉箭头统一 `chevron.up.chevron.down`/`chevron.down` caption2 tertiary，不用系统 menu 指示器；文字键统一 `borderless` + secondary，主按钮仅允许 1 个 `borderedProminent` | 任何页面截图里看不到系统蓝控件；每页主按钮 ≤1 |

## 四、页面文档索引与进度追踪

| 阶段 | 文档 | 页面 | 范围 | 状态 |
|---|---|---|---|---|
| 一 | README.md | 全局主线 + 共用任务 G-T1~G-T6 | 全 App | 待办 |
| 一 | 01-global-shell.md | 窗口 titlebar + 全局侧栏 | 全 App 外壳 | 待办 |
| 二 | 02-conversation.md | 对话页（消息/composer/空状态/问题轨道） | .conversation | 待办 |
| 二 | 03-leetcode.md | 力扣页（题库/题目/作答/提交） | .leetCode | 待办 |
| 二 | 04-study-plan.md | 学习计划页 | .plan | 待办 |
| 二 | 05-review.md | 复习页 | .review | 待办 |
| 二 | 06-library.md | 学习库页 | .library | 待办 |
| 二 | 07-knowledge-graph.md | 知识图谱页 | .knowledge | 待办 |
| 二 | 08-templates-trash.md | 模板页 + 回收站页 | .templates / .trash | 待办 |
| 二 | 09-insights.md | 学习洞察页 | .insights | 待办 |
| 三 | 10-settings.md | 设置页（全量） | SettingsView | 待办 |
| 三 | 11-toolpanel-context.md | 工具面板 + 上下文面板 | ToolWorkspace / ContextPanel | 待办 |

阶段顺序：一是全局（不动页面观感先做地基）；二是九个页面（可并行）；三是设置与浮层面板。

## 五、明确不做的事（红线）

- **滚动条保持隐藏不变**（`.scrollIndicators(.hidden)` 为有意设计，任何任务不得恢复显示；唯一的安全收口见 11 号文档任务 T-03：仅收敛注入作用域，视觉不变）。
- 不改页面信息结构与业务流程，只动视觉组织与数值。
- 不引入第三方 UI 库；SF Symbols 不换成自绘图标或 emoji。
- 中文界面文案不随本次改版重写（中英混排、提示语优化另立专项）。
