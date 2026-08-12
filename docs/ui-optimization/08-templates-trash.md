# 08 · 模板页 + 回收站页优化任务

> 涉及文件：`Views/LearningCenterViews.swift` 中 `LearningTemplatesWorkspaceView`、`LearningTrashWorkspaceView`
> 页面定位：两个体量较小的列表页，结构上已接近"一顶"规范。任务以接入共用组件（搜索框、选中 token、命中区）为主。

## 现状核实

| 页 | 项 | 证据 | 问题 |
|---|---|---|---|
| 模板页 | 侧栏搜索框 | L395–407：高 36、半径 8、底 `primary 0.025` + 描边 0.09（私有实现） | 高度 36 与其他搜索框（30/32）不一致；私有样式 |
| 模板页 | 列表行 | subheadline medium + caption2 两行 + `selectionBackground` | ✅ 结构良好；圆点/材料随 06 T-09/T-04 转 token |
| 模板页 | 分栏 | `250/300/360` + 详情 min 500（与学习库同构） | 合计 750，同步放行 |
| 回收站 | 页头 | L567–575：标题 headline + 副标题 caption + 清空钮，54 高 + 1 根 Divider | 基本等于 `PageHeader.prominent`，直接规格化 |
| 回收站 | 行操作 | L587–588：`Button("恢复")` / `Button("彻底删除", role: .destructive)`，`.controlSize(.small)` | 文字按钮命中高度 <24；破坏性键色 OK |
| 回收站 | 弹窗 | `confirmationDialog` ×2（清空/彻底删除） | ✅ 保持 |

## 优化目标

1. 模板页结构对齐学习库：列头 = 搜索单块；分栏 min ≤ 620；列表行选中走 token。
2. 回收站页头接入 `PageHeader.prominent`（54），行操作命中区 ≥ 28。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | 模板搜索框换共用组件 | 06 T-03 | 私有实现 → `UnifiedSearchField`（高 30）；`.padding(.horizontal,10)/(.top,10)/(.bottom,12)` 其余保持 | P0 |
| T-02 | 模板分栏放行 | — | 250/300/360 → 228/300/340 min/ideal/max，详情 min 500→400 | P0 |
| T-03 | 选中 token 落地 | 06 T-04 | `selectionBackground(isSelected:)`（L435 附近 shared func）改为返回 `ColorToken.listSelection` 占位，模板/学习库共用 | P0 |
| T-04 | 回收站页头规格化 | G-T3 | header 54 保持内容，改用 `PageHeader.prominent` 组件（标题 15 semibold + 副标题 12 secondary + 右侧"清空" destructive 文字键） | P1 |
| T-05 | 行操作命中区 | G-T5 | "恢复"/"彻底删除" 套 28 高内容形状或改用 `.controlSize(.regular)` 文字键；保持 destructive 样式 | P1 |
| T-06 | 模板详情 token 化扫尾 | Typography/G-T2 | 详情区一处复核：padding/字号/标题全部上 token | P2 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01/T-02 | 模板页列头 = 搜索框 30 高单块；900px 窗下两栏无裁切 | 截图 + 拖窗 |
| AC-02 | T-03 | `selectionBackground` 返回 token；06/08 两处选中视觉一致 | 双页对照 |
| AC-03 | T-04 | 回收站页头与其他页 `PageHeader.prominent` 视觉一致（54 高、同字号段） | 截图对比 |
| AC-04 | T-05 | 行尾两键各 1 次点击命中 | 人工操作 |
| AC-05 | 综合 | 两个页面 `.system(size:` 出现为 0；Divider 每页 ≤ 1 | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 搜索框 | AC-01 | 待办 |
| T-02 分栏 | AC-01 | 待办 |
| T-03 选中 token | AC-02 | 待办 |
| T-04 页头规格化 | AC-03 | 待办 |
| T-5 按钮命中区 | AC-04 | 待办 |
| T-6 详情 token 化 | AC-05 | 待办 |
