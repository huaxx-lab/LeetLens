# 09 · 学习洞察页优化任务

> 涉及文件：`Views/LearningCenterViews.swift` 中 `LearningInsightsWorkspaceView`
> 页面定位：单栏滚动看板（指标卡 + 两列清单）。页面本身无分割线、结构清新，是字体/间距 token 化薄弱的页面：26/21/16/14.5/13.5 多种硬编码档次并存，卡片材质为 tint 平涂，与全局玻璃体系两套语言。

## 现状核实（当前快照）

| 项 | 证据 | 问题 |
|---|---|---|
| 页头 | L269–275：标题 26 semibold 硬编码 + 副标题 14 | 未接 token；与设置页 28 bold、力扣 19/20 指标互成"大数字混战" |
| 指标卡 | L353–368：图标 16pt 入 34×34 圆角块、数字 21 semibold mono、卡底 `tint.opacity(0.035)` 半径 10 | 卡底平涂与全局玻璃/G-T6 材质不统一 |
| 布局 | L277–282 `ViewThatFits` + LazyVGrid adaptive 160 → 两列 `HStack(spacing: 44)`；`maxWidth: 1080`；`padding 34/30` | 自适应思路 ✅；44/34/30 野值 |
| 优先巩固行 | L292–301：14.5 medium 半点、8×8 圆点 | 半点字号 + 圆点尺寸大 |
| 知识分布行 | L315–323：13.5 medium 半点 + ProgressView small | 同上 |
| sectionHeading | L370–375：Label 16 semibold + hierarchical + tint | 字号与"26 标题"之间缺一档，层级跳跃 |
| 颜色 | tint: `.blue/.orange/.pink/.green` 裸色 | G-T6 收敛 |

## 优化目标

1. 页面字号阶梯：26（页级）→ 20/17（分区/指标）→ 13（行）→ 11（辅助），零半点。
2. 指标卡材质与全局统一：要么走 `raised` 平面卡，要么 `navigationGlass`，不再手涂 tint 透明度。
3. 行圆点 6×6 统一。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | 字体 token 化 | Typography | 26 → `Typography.display`；副标题 14 → `Typography.body`/secondary；21 → `Typography.metricValue`；16 heading → `Typography.sectionTitle`；14.5/13.5 → 13 `Typography.body` + medium | **P0** |
| T-02 | 间距 token 化 | G-T2 | spacing 44 → `Spacing.xl`（32）或新增 40；padding 34/30 → `Spacing.xl`/24；卡内 padding 14 → 12/16 tokens | P1 |
| T-03 | 指标卡材质 | G-T6 | `tint.opacity(0.035)` 平涂 → `ColorToken.raised` 卡底 + `navigationGlass(cornerRadius: 10)` 二选一，打磨并全局粘贴；图标块 tint 底可保留 | P1 |
| T-04 | 裸色收敛 | G-T6 | tint 蓝/橙/粉/绿 → success/warning/accentInfo（新 token）/success，配合图标底保持 | P1 |
| T-05 | 圆点统一 | G-T6 | 8×8 → 6×6，映射走 ColorToken | P2 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01 | 本区域 `.system(size:` 出现为 0；无半点字号 | grep 核对 |
| AC-02 | T-01 | 页面一眼三层：页题 > 指标/分节 > 行内容，层级明显但不靠新字号档 | 截图人工评审 |
| AC-03 | T-03 | 指标卡与设置卡片/复习卡片同材质体系 | 双页对照 |
| AC-04 | 综合 | `LearningCenterViews.swift` 全文 `.system(size:` 出现为 0、无半点 | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 字体 token 化 | AC-01/02 | 待办 |
| T-02 间距 token 化 | AC-01 | 待办 |
| T-03 指标卡材质 | AC-03 | 待办 |
| T-04 裸色收敛 | AC-03 | 待办 |
| T-05 圆点统一 | AC-02 | 待办 |
