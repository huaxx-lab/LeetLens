# 11 · 工具面板 + 上下文面板 + 浮层 优化任务

> 涉及文件：`Views/ToolWorkspaceView.swift`、`Views/ContextPanelView.swift`、`Views/UsageStatisticsView.swift`、`Views/SyntaxHighlightedCodeView.swift`、`Views/WebViewPresentation.swift`
> 页面定位：右侧 inspector（浏览器/视频/预览/运行/证据）+ 悬浮任务上下文 + 用量弹窗 + 通用代码块。结构最近已被整改，残留的是口径级小项 + 1 个**安全作用域**收口（视觉零变化）。

## 现状核实

| 域 | 证据 | 问题 |
|---|---|---|
| 浏览器地址条 | Tool L41–52：刷新 icon-only 无 frame；输入框 `.quaternary` 底 radius 7；`padding(10)`；`Divider()` 后接内容 | 刷新命中区 <28；半径 7 野值 |
| 证据面板 | Tool L153–168：标题 headline + 副标 caption；L156 `掌握度 42` **缺 %**；圆点 8×8 top 5、行距 22、`padding(18)` | 与其他页"42%"不一致；野值 |
| evidenceColor | Tool L188–194：四档映射已接 ColorToken ✅ | ✅ 作为全局母版，供 06 T-07 抽取共用 |
| ContextPanel | L79 副标题 **10.5pt**；L75 标题 13 medium；L68 图标 13；L41 `point.3.filled.connected.trianglepath.dotted` 当展开/收起图标；L94 悬停 `primary 0.055` | 10.5 近乎不可读；"连接节点"图标语义误用 |
| 用量弹窗 | 620×440 固定、分段 240、Grid 42/18、padding 20/24/22；`.orange` 中断提示（L57） | 均可入 token；橙色 → warning |
| 代码块 | SyntaxHighlighted L46 12.5 mono、L40 头 34、L58 半径 7、复制键 24×24 | 12.5 半点；7 野值；复制键命中 ≤ 24 |
| **滚动条注入** | WebViewPresentation L19–26：`forMainFrameOnly: false` + `!important`，被工具面板、设置登录页（leetcode.cn/bilibili）使用 | **用户有意隐藏滚动条——样式保持不变**；但注入打到第三方页面所有 iframe（验证码/内嵌播放器），可能破坏对方布局脚本 |

## 优化目标

1. 各面板与主区口径对齐：面板内 0 半点字号、命中区 ≥ 24、表面色全 token。
2. 用量弹窗尺寸固定可接受，但数值入 `Size.popover/sheet` token。
3. 滚动条视觉：**保持隐藏**；仅把注入收敛到主文档，不碰第三方 iframe。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | 浏览器地址条 | G-T5/T-02 | 刷新键 28×28；输入框 radius 7 → 8、高 30；`padding(10)` → `Spacing.xs`；Divider 保持 | P0 |
| T-02 | 证据面板 | 06 T-07 | L156 补 `%`；圆点 8×8→6×6 与全局一致；行距 22/底距 18 → token；`evidenceColor` 抽到共享层供学习库复用 | P0 |
| T-03 | **滚动条注入受体收口** | — | `forMainFrameOnly: false` → `true`；代码注释写明"隐藏滚动条为有意设计"；样式串本身一字不改 | **P0** |
| T-04 | ContextPanel 字体修复 | Typography | L79 10.5 → `Typography.aux`（12）；L75 13 → `Typography.body` medium；图标 13 → 15、槽 24 | P0 |
| T-05 | ContextPanel 图标语义 | G-T5 | L41 展开/收起换 `chevron.up.chevron.down`（同外层 Menu 一致）或 disclosure chevron；悬停色 0.055 → token `hover = primary.opacity(0.05)` 统一档 | P1 |
| T-06 | 用量弹窗 token 化 | G-T2 | 620×440 → `Size.sheetMedium`；分段 240 保持并入 token；Grid 42/18、padding 20/24/22 → token 族；`.orange` → `ColorToken.warning` | P1 |
| T-07 | 代码块规格 | Typography | 12.5 → `Typography.mono`(12)；头 34 → `Size.compactRow`；半径 7 → `Radius.small`(6) 或 medium(8) 择一与卡片体系一致；复制键 28×28 | P1 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01/T-02 | 刷新键、证据行各 1 次点击命中；掌握度显示 `42%` | 人工操作 |
| AC-02 | T-03 | bilibili 登录页、验证码 iframe 内滚动行为与视觉**和改前一致**（自有界面滚动条依旧隐藏） | 人工走一遍登录流程 |
| AC-03 | T-04/T-05 | 上下文面板无 10.5 字；图标语义与展开/收起匹配 | 截图评审 |
| AC-04 | T-06/T-07 | 两个文件 `.system(size:` 出现为 0；无半点 | grep 核对 |
| AC-05 | 综合 | 本组文件裸 `padding(18/22/20/24)` 收敛为零或 token | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 地址条 | AC-01 | 待办 |
| T-02 证据面板 | AC-01 | 待办 |
| T-03 注入收口 | AC-02 | 待办 |
| T-04 面板字体 | AC-03 | 待办 |
| T-05 图标语义 | AC-03 | 待办 |
| T-06 弹窗 token 化 | AC-04 | 待办 |
| T-07 代码块 | AC-04/05 | 待办 |
