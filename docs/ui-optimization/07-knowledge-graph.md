# 07 · 知识图谱页优化任务

> 涉及文件：`Views/LearningWorkspaces.swift` 中 `KnowledgeWorkspaceView`（graphToolbar / graphCanvas / inspector / legend）
> 页面定位：一整块 Canvas + 一根 46 高工具栏，结构本身最克制。问题集中在：工具栏在窄窗溢出、节点卡片缩放与文字缩放下限不匹配造成截断、9.5pt 副标题不可读。

## 现状核实

| 项 | 证据 | 问题 |
|---|---|---|
| 工具栏 | L986–1062：标题 14 semibold 硬编码 + 计数 + 可选 focus 面包屑 + 3 图例 + 搜索框（动态宽 min(max(0.14w,138),190)，高 28，半径 7）+ 匹配计数 + Divider(18) + 5 个 CompactIconButton + 缩放百分号 | 一屏需求 ≈500pt；窄窗最小需求未被压缩策略覆盖；半径 7 野值 |
| 分段分隔 | L995/L1037：竖 Divider 高度 18 ×2 | 保持，但统一为 `Size.toolbarSeparator = 18` token |
| 节点卡片 | L961–962 卡片宽 176×unit（unit 下限 0.6） vs L1162/L1169/L1172 字号下限 `max(0.9, unit)` / 副标题 9.5 | **卡片缩到 60%，字号只缩到 90% → 小视口副标题/标题必然溢出卡片**；9.5pt 低于可读下限 |
| 折叠钮 | L1202–1205：9pt chevron，命中约 18×18；L1180 条件 padding 22/0 | 命中区过小；卡片 padding 不对称 |
| inspector | L1316–1322 宽高按 viewport 钳制 OK；L1243–1307 内容 VStack 缩进错乱 | 代码缩进错误（层级嵌套多退一级） |
| 空态 | 仅根节点时画布无任何引导 | 新用户面对空白 |
| 图例 | L1064–1069：6×6 圆点 + caption2 | ✅ 保持 |

## 优化目标

1. 工具栏成为"画布工具条"的规范版：标题 → 面包屑（如有）→ 弹性区 → 图例（窄窗折叠）→ 搜索 → 缩放/视图操作。
2. 节点卡片任何缩放下文字不裁切；副标题 ≥ 11pt。
3. inspector 代码结构与视觉层级一致。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | 工具栏窄窗折叠 | G-T3 | detail 宽 < 860 时图例折叠为 `info.circle` Popover；标题 14 → `Typography.rowTitle`；保留 3 段式分隔（Divider 18 入 token） | P0 |
| T-02 | 节点缩放一致性 | — | 字号缩放下限 0.9 → 0.75 并同步卡片下限；副标题保底 `max(11pt, 9.5×unit)`；标题/副标题行数 lineLimit 保持 1 | **P0** |
| T-3 | 折叠钮命中区 | G-T5 | 9pt 18×18 → 12pt + 28×28 `.contentShape(Circle())`；L1180 的条件 padding 改为常量 8 两侧 | P1 |
| T-4 | 空态引导 | — | 记录 ≤1 时画布中央显示 `ContentUnavailableView("先去对话或做题沉淀知识", systemImage: "brain")` 覆盖层 | P1 |
| T-5 | inspector 修复 | — | L1243–1307 缩进归零重排；标题 lineLimit(2) 保持；字号接入 Typography | P1 |
| T-6 | 搜索框统一 | G-T2 | 半径 7 → 8；高 28 → 30 对齐 UnifiedSearchField；宽公式保留（建议 min 140） | P1 |
| T-7 | 颜色 token | G-T6 | legend/节点色已用 success/accent/warning ✅；检查边线 `secondary.opacity(0.32)`、选中描边 `accentColor 0.55` 数字化收敛到 token | P2 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01 | 窗口 820px 时工具栏完整可见：图例折叠为 Popover，其余键可点 | 拖窗核对 |
| AC-02 | T-02 | 最小缩放（unit=0.6）下逐 Node 检查：文字不溢卡片左右缘；副标题肉眼可读 | 2 张缩放截图（max/min） |
| AC-03 | T-3 | ↕ 折叠钮任何位置 1 次点击命中 | 人工点击 |
| AC-04 | T-4 | 清空学习项后打开图谱，中央出现引导文案与图标 | 数据注入 |
| AC-05 | T-5/T-6 | graphToolbar 搜索框半径 8 高 30；inspector 编译警告 0、结构清晰 | 截图 + 编译 |
| AC-06 | 综合 | 本区域（980–1736 行）`.system(size:` 数量 ≤ 2（Canvas 动态字号数学表达式除外） | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 工具栏折叠 | AC-01 | 待办 |
| T-02 缩放一致性 | AC-02 | 待办 |
| T-3 折叠钮 | AC-03 | 待办 |
| T-4 空态引导 | AC-04 | 待办 |
| T-5 inspector | AC-05 | 待办 |
| T-6 搜索框 | AC-05 | 待办 |
| T-7 颜色 token | AC-06 | 待办 |
