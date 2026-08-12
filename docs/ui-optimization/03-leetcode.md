# 03 · 力扣页（题库 / 题目 / 作答 / 提交）优化任务

> 涉及文件：`Views/LeetCodeWorkspaceView.swift`、`Views/LeetCodeCodeEditor.swift`
> 页面定位：三内态（library / activity / submissions）+ 两内嵌场景（题目详情、作答）。它是"顶部堆叠"最严重的页面：titlebar 之下最多叠 3 根功能横条（overviewToolbar 46 → summaryStrip 68 → 筛选条 44），作答时再叠 editorToolbar 42。**2026-08-10 截图复核新增 3 个缺陷：整页横向错位裁切、控件系统蓝突兀、题单/题库空态不良。**

## 现状核实

| 项 | 证据 | 问题 |
|---|---|---|
| **整页错位（新增 P0）** | 截图：左侧"题库/全部"分段与"16 题目"指标贴到窗口左缘、右侧筛选条计数"16 道题"被裁成"16 道"；根因：body 是默认居中的 `VStack(spacing: 0)`（L70），`overviewToolbar`（L117–174：248+180+220）与筛选条（L189–209：218+112）固定宽叠加超过视口时，SwiftUI 将超宽子视图**居中裁切**——左右两端同时被切 | 内容在任何宽度都不许贴边/被切 |
| **控件系统蓝（新增 P0）** | 截图：`pickerStyle(.segmented)` 渲染成深蓝分段块（L125、L194、L461）；难度 Picker 显示系统蓝色 `chevron.up.chevron.down` 指示器；题单 Menu 是 borderless 裸文字 | 与全 App 低调灰体系完全两种语言，且三种菜单外观互相不一致 |
| **题单/题库空态（新增 P0）** | 题单 Menu（L128–152）当前总是显示"自动跟踪"字样 | 无题单/未同步时应显示引导或隐藏菜单；题库列表空态只有"没有符合条件的题目"文案，无下一步引导 |
| overviewToolbar | L117–174：segmented Picker 固定 248、题单 Menu maxWidth 180、搜索框 220×28、刷新 icon-only 无尺寸、行高 46 | 固定件合计 ~690pt；刷新命中区 <28 |
| summaryStrip | L227–251：指标数字 **19pt 硬编码**（L242）+ green/orange/blue/pink 裸色 + 每格 trailing 分隔线 | 指标是内容却夹在横线正中，制造"第二根顶"的观感 |
| 筛选条 | L189–209：独立 44 高横条 + 上下两 Divider | 主线 1/2 双违规 |
| 题目列表行 | L253–284：题号槽 44、难度槽 40、行间 `Divider().padding(.leading, 48)` | 同类行间排队线 → 删；行内容也不许贴边（当前状态图标贴左边） |
| questionToolbar | L442–470：返回 chevron、标题 14 semibold 硬编码、segmented 176、globe icon-only | 标题未走 token；icon-only 命中区 <28；segmented 系统蓝（G-T7） |
| 提交详情 | L505–548：L573 提交行 `frame(height: 54)` 内含 3 段文本（AI insight 允许 2 行） | 有 insight 时必然裁切 |
| editorToolbar | L779–803：语言 Picker 128 + 状态 caption2 + 撤销/重做/复制/格式四个 icon-only | 4 个按钮命中区都 <28；行高 42 又添一挡 |
| 分栏宽度 | L473–502：HSplitView 360 + 380 = 740 | 超 `primaryMinimum` 620 |
| 代码字体三体系 | SyntaxHighlighted L46 12.5pt；editor.html 13px；LeetCodeProblemWebView CSS `12.5px` | 三个代码面三种字号 |
| 诊断小字 | L878/L981：12.5 / 11.5 monospaced 硬编码 | 半点 + 低于可读下限 |

## 优化目标

1. **任何窗口宽度下内容不贴边、不裁切**：改为弹性布局，空间不足时**折叠**而不是裁切。
2. 题库页 titlebar 之下**只剩 1 根页面头**（44 高），控件形态全 App 统一（G-T7），无系统蓝。
3. 作答页 2 根：题目头（44）+ 编辑器工具（44 同档）。
4. 分栏最小宽 ≤ 620。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-00 | **整页错位修复** | — | ① body VStack 显式 `alignment: .leading` 或给子视图 `frame(maxWidth: .infinity, alignment: .leading)`；② 去掉 `overviewToolbar`/筛选条的固定宽：segmented 自适应，搜索框 `frame(minWidth: 160, maxWidth: 240)` 弹性；③ 枚举所有"固定宽 Spacer 行"，给最右侧元素加 `layoutPriority` 与截断规则，保证 820px 窗口时压缩顺序是"搜索框缩短 → 题单名截断 → 右计数缩短"，永不两端裁切；用 820/900/1100/1400 四档截图复核 | **P0** |
| T-01 | overviewToolbar 与筛选条合并 | G-T3/G-T4/G-T7 | 删除独立筛选横条（L189–209）；状态/难度并入新自绘 `SegmentedControl`（G-T7），与视图切换共用一行；行高统一 `PageHeader.standard=44`；只留 1 根页头底线 | P0 |
| T-02 | **控件形态统一** | G-T7 | segmented ×3（L125/194/461）→ 自绘灰底胶囊选中态；难度 Picker 菜单指示器换 caption2 tertiary chevron；题单 Menu 保留 borderless 但加 9pt 三级色 chevron；全页禁止出现系统蓝 | **P0** |
| T-03 | 刷新键命中区 | G-T5 | L164–169 刷新键套 28×28 + 圆角 8 悬停底 | P0 |
| T-04 | 题单/题库空态 | — | 题单为空：隐藏菜单 + toolbar 显"未连接"引导文案；题库为空：`ContentUnavailableView` 保持，补"连接力扣同步"引导按钮 | P0 |
| T-05 | summaryStrip 去夹线 + token 化 | G-T4/G-T6 | 删除上下两根 Divider，与列表间留白 12；指标数字 19 → `Typography.metricValue`(22 semibold+monoDigit)；已通过=success、尝试过=warning、其余 primary；删 blue/pink；与列表左缘同 padding 对齐 | P0 |
| T-06 | 行间线删除 + 贴边治理 | G-T4 | L218 行间 Divider 删除，LazyVStack spacing 2→4；**行内状态图标/计数/难度与窗口内缘保持 ≥16**，任何列不贴边 | P0 |
| T-07 | questionToolbar 统一 | G-T3/G-T5/G-T7 | 标题 → `Typography.rowTitle`；返回/globe 键 ≥28；segmented 176 → 自绘胶囊 | P1 |
| T-08 | editorToolbar 规格化 | G-T5 | 四 icon-only 键 28×28；行高 42→44；语言 Picker 外观同 G-T7 | P1 |
| T-09 | HSplitView 最小宽放行 | — | 360/380 → 320/360（与 `Size.primaryMinimum` 对齐） | P1 |
| T-10 | 提交行高度修复 | — | L573 `frame(height: 54)` → `frame(minHeight: 54)`；insight 2 行不裁切 | P1 |
| T-11 | 代码字体统一 | Typography | `Typography.mono = 12pt ui-monospaced`：SyntaxHighlighted、diagnosis（L734/981）、editor.html、LeetCodeProblemWebView CSS、conversation.html 代码块五处统一 | P1 |
| T-12 | 裸色收敛 | G-T6 | `.green/.orange/.red/.blue/.pink` → `ColorToken.success/warning` 等；错误文本 L527 同改 | P1 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-00 | T-00 | 窗口 820px / 900px / 1100px / 1400px 四档：题库页**无任何一处文字贴窗口边缘或被裁切**，压缩顺序符合 T-00 | 四档截图逐张核对 |
| AC-01 | T-01/T-06 | 题库视图 titlebar 之下：页头(44) → 1 线 → summaryStrip（无夹线） → 列表；页面级 Divider = 1 | 截图 + `grep -c "Divider()" LeetCodeWorkspaceView.swift` 前后对比 |
| AC-02 | T-02 | 全页（含题目头/编辑器）截图中不出现系统蓝色的 segmented/menu 指示器 | 三场景截图 |
| AC-03 | T-04 | 未同步状态下打开刷题页，出现引导而非空列表/裸"自动跟踪" | 清空数据源回归 |
| AC-04 | T-05 | 四个指标：已通过绿/尝试过橙/其余主色；22pt 等宽数字；与列表左缘同一根垂直对齐线 | 截图放大核对 |
| AC-05 | T-07/T-08 | 作答页：页头(44) → 编辑器工具(44) → 代码区；icon 键 1 次点击命中 | 人工点击 ×4 |
| AC-06 | T-10 | 双行 insight 提交记录完整显示 | 注入长 insight 数据 |
| AC-07 | T-11 | 四处代码视觉字号一致（12） | 并排截图 |
| AC-08 | T-09 | 窗口 900px 时 HSplitView 两侧无横向裁切 | 拖窗核对 |
| AC-09 | T-12 | `LeetCodeWorkspaceView.swift` 无 `.green/.orange/.red/.blue/.pink` 裸字 | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-00 错位修复 | AC-00 | 待办 |
| T-01 头部合并 | AC-01 | 待办 |
| T-02 控件形态 | AC-02 | 待办 |
| T-03 刷新命中区 | AC-05 | 待办 |
| T-04 空态引导 | AC-03 | 待办 |
| T-05 summaryStrip | AC-04 | 待办 |
| T-06 行间线+贴边 | AC-01 | 待办 |
| T-07 题目头统一 | AC-05 | 待办 |
| T-08 编辑器工具 | AC-05 | 待办 |
| T-09 分栏放行 | AC-08 | 待办 |
| T-10 提交行高 | AC-06 | 待办 |
| T-11 代码字体 | AC-07 | 待办 |
| T-12 裸色收敛 | AC-09 | 待办 |
