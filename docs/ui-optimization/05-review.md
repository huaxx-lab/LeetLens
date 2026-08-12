# 05 · 复习页优化任务

> 涉及文件：`Views/LearningWorkspaces.swift` 中 `ReviewWorkspaceView`、`DeprecatedLeetCodeWorkspaceView`（死代码段）
> 页面定位：左复习队列（244–312）+ 右详情 min 540 = **分栏最小宽 784，全 App 最宽**。队列列内部二次堆叠（列头 44 → Divider → 搜索条 → 列表），详情区内又大标题 + Divider + 24 间距并存。

## 现状核实

| 项 | 证据 | 问题 |
|---|---|---|
| 分栏 | L408–426：queue 244/276/312 + detail min 540 = 784 | 远超 `primaryMinimum=620`，窄窗首期挤压 |
| 队列列 | L442–492：header 44 + Divider + 搜索框 30(`padding 10`) + row spacing 2 | 队列 header 与搜索条实质叠成两段（两段落结构是否保留见任务） |
| 详情区 | L495–539：ScrollView maxWidth 760 + header(title2) + Divider(L500) + spacing 24 + 底部 56 | header 与正文之间用线分隔，而 VStack 已有 24 留白——线与留白重复 |
| 作答区 | L687：TextEditor `frame(height: 190)`；选择行 checkmark 图标无字号（L639） | 固定高度；图标尺寸失控 |
| 字体 | 本区域语义化较好（.headline/.title2/.caption），少量硬编码散见 | 总体较健康 |
| 选中色 | L822（复习队列行）：`colorScheme == .light ? 0.075 : 0.13` 双值 | 未走 listSelection 体系（G-T6） |
| 死代码 | **L4–395 `DeprecatedLeetCodeWorkspaceView`**，private 且全文零引用，携带整套旧样式（25pt 标题、绿底、44 工具栏） | 视觉"污染源"，删 |
| 空态 | L536 `ContentUnavailableView("今日复习已完成", ...)` | ✅ 保持 |

## 优化目标

1. 分栏最小宽压到 620 体系内；窄窗优先让右栏可读。
2. 队列列：列头(44) + 1 根线 + 搜索条（承压进入列头区）+ 列表，不再叠多层。
3. 详情区移除自绘 Divider，用既有 24 留白做层级。
4. 清除死代码，掐断旧样式回流的路径。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | **删除死代码** | — | 整段移除 L4–395 `DeprecatedLeetCodeWorkspaceView`（约 392 行）；编译验证；顺带检查是否有其他文件引用其相关资源（热力色阶函数等） | **P0** |
| T-02 | 分栏放行 | — | queue minWidth 244→228、max 312→300；detail minWidth 540→392（内容本来就按 760 max 居中，窄宽由 maxWidth 内收即可），合计 min ≈ 620 | **P0** |
| T-03 | 队列列收敛 | G-T4 | 列头 44 保持；列头下 Divider 保留（1 根，语义断层）；搜索条保持 30 高，**与列头合并为同一视觉块**（列头下方紧贴搜索条，分割线仍 1 根） | P1 |
| T-04 | 详情区去线 | G-T4 | L500 Divider 删除；`.title2` 标题改 `Typography.pageTitle`（22）保持视觉一致；meta 行（L546–556）保持 caption secondary | P0 |
| T-05 | 作答区弹性 | — | TextEditor 190 → `minHeight: 160, maxHeight: 320` 随输入增高；选择行图标补 `.font(.system(size: 15))`；答案反馈 Label 色改 `ColorToken.success/warning` | P1 |
| T-06 | 队列行选中色 | G-T6 | L822 双值分支 → `ColorToken.listSelection`（见 06 T-04 定义） | P0 |
| T-07 | 搜索框统一 | — | 复习队列搜索框改用 `UnifiedSearchField` 通用组件（组件在 06 学习库文档 T-05 定义，完成后本页替换本地写法） | P1 |
| T-08 | 掌握度仪表盘检查 | G-T6 | `MasteryGauge` 色映射与 ColorToken 对齐（绿→success、黄→warning、其余 accentColor），字号接入 Typography | P2 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01 | `DeprecatedLeetCodeWorkspaceView` 符号全文检索为 0；`swift build` 通过 | grep + 编译 |
| AC-02 | T-02 | 窗口 820px 时，复习页左右栏均不出现裁切；queue 列 ≤ 300 | 拖窗 + 测量 |
| AC-03 | T-03/T-04 | 复习页一屏自上而下：列头 → 1 线 → 搜索条 → 列表；详情标题与正文之间无横线 | 截图比对 |
| AC-04 | T-05 | 输入 10 行答案，作答框增高到 320 不再增长且可滚动 | 人工输入 |
| AC-05 | T-06 | 深浅外观下队列选中行清晰可见 | 双外观截图 |
| AC-06 | 整体 | 本文件 `.system(size:` 次数从当前 14+ 降到 ≤ 3（图谱 Canvas 动态字号除外，归 07 文档管） | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 删死代码 | AC-01 | 待办 |
| T-02 分栏放行 | AC-02 | 待办 |
| T-03 队列列收敛 | AC-03 | 完成（2026-08-10：L455 列头 Divider 已删，进一步连那根语义断层线也省略，纯留白分组） |
| T-04 详情去线 | AC-03 | 完成（2026-08-10：L500 标题下 Divider + lesson pitfalls 前 Divider 均已删） |
| T-05 作答区弹性 | AC-04 | 待办 |
| T-06 选中色 | AC-05 | 完成（2026-08-10：队列行改 `ColorToken.listSelection`） |
| T-07 搜索框统一 | AC-03 | 待办 |
| T-08 掌握度盘 | AC-05 | 待办 |

> 2026-08-10 截图复核：用户确认分割线割裂感，左列一根线、右侧两根线已清；剩余割裂来自控件边框与作答卡片边框，属 T-05 与全局 G-T6 材质统一的后续范围。
