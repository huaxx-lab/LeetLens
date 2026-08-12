# 06 · 学习库页优化任务

> 涉及文件：`Views/LearningCenterViews.swift` 中 `LearningLibraryWorkspaceView`、`LearningRecordDetailView`
> 页面定位：左记录列表（250–360）+ 右详情（min 500）= 合计 min 750，超 620 token。侧栏自主一套 搜索框样式，详情区末尾带 `.bar` 材质的操作底条（48 高）。

## 现状核实

| 项 | 证据 | 问题 |
|---|---|---|
| 分栏 | L31–100：sidebar 250/300/360 + detail min 500 | 合计 750 > 620 |
| 侧栏头 | L33–45：分类 Picker + "N 项"计数，`padding(10)` | 与搜索条叠为两段落，可合并 |
| 搜索框 | L47–50：本页私有写法（其他页各一套） | 同一形态至少 5 处实现（侧栏/复习/模板/设置/学习库） |
| 行选中 | L62/L80→`selectionBackground`（`.unemphasizedSelectedContentBackgroundColor`） | ✅ 已符合系统惯例——本轮把它上升为全局 token |
| 详情头部 | L126 标题 22 semibold；L134 掌握度 20 semibold；L136 "掌握度" 标签 11pt | 22/20/11 三个非 token 值 |
| 详情分节 | L244–252：`detailSection` 标题 13 semibold secondary | 标题权重过重（等同正文标题） |
| 证据色 | 证据点 `.green`（positive）/`.blue` 二分，与 ToolWorkspace 四档映射（demonstrated/mastered/struggling/error）不一致 | 同一证据跨页不同色 |
| 操作底条 | L237–241：`开始练习` borderedProminent + `.bar` 底 + 48 高 | 详情底又生一根"水平面"，主线 1 违规 |
| 分类兜底 | L12 `Set(...).sorted()` 生成 categories，选中值无兜底 | 分类消失后 Picker 选中失效 |
| 掌握度圆点 | L59–61：7×7（学习库）vs 复习/力扣 4×4 / 计划 7×7 | 全局需统一 6×6 |

## 优化目标

1. 分栏最小宽 ≤ 620；
2. 侧栏列头 = 分类 + 搜索的**单块**（0–1 根线），行高族与复习页一致；
3. 详情区信息层级：标题 22 → 采用 `Typography.pageTitle`（22 semibold）保持不变，指标数字并入 `Typography.metricValue`，标签 11→`Typography.micro`；
4. 证据颜色映射全局唯一实现；
5. 底部 `.bar` 条消失，"开始练习"进入详情内容流末尾。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | 分栏放行 | — | sidebar 250→228（min）、detail 500→400；合计 min 628 ≈ 620 体系内（inspector 关闭时） | **P0** |
| T-02 | 侧栏列头整合 | G-T4 | Picker+计数并入搜索条所在区块，上下用 12 留白；保留 1 根 Divider（列头与列表之间）| P0 |
| T-03 | **定义 `UnifiedSearchField`** | G-T2 | 新建 `Design/UnifiedSearchField.swift`：高 30、图标 12 secondary、清空键 tertiary、圆角 8、底 `ColorToken.canvas`、描边 0.07；本页先行替换 | P0 |
| T-04 | 选中色全局统一 | G-T6 | 新增 `ColorToken.listSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)`（本页实现为原型）；README/01/05 中相关任务同步把"手写 opacity 选中"收敛到此 token | P0 |
| T-05 | 详情底条消除 | G-T3/G-T4 | 删除 `.bar` 48 底条；"开始练习"以 borderedProminent 放入详情 ScrollView 末尾，随内容滚 | P0 |
| T-06 | 详情字体 token 化 | Typography | 22 → `Typography.pageTitle`；20 → `Typography.metricValue`；11 → `Typography.micro`；`detailSection` 的 13 semibold → `Typography.aux` weight semibold | P1 |
| T-07 | 证据色单一映射 | G-T6 | 抽取 `evidenceColor(signal:)` 到 Models 或 Design 层，删除本页 `.green/.blue` 二分；与工具面板（文档 11 T-02）共用 | P0 |
| T-08 | 分类兜底 | — | `category` 在 categories 中缺失时回退 "全部" | P1 |
| T-09 | 掌握度圆点统一 | G-T6 | 7×7 → 6×6，映射走 ColorToken | P2 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01 | 窗口 900px 时学习库两栏无裁切 | 拖窗核对 |
| AC-02 | T-02/T-03 | 列头区一眼整体；UnifiedSearchField 与侧栏（01）式样一致 | 双页截图 |
| AC-03 | T-04 | `ColorToken.listSelection` 定义在 DesignTokens.swift；`LearningCenterViews.swift`/`GlobalSidebarView.swift`/复习页选中实现均引用它，`primary.opacity(0.065/0.075)` 选中痕迹为 0 | grep 核对 |
| AC-04 | T-05 | 详情页无 `.bar` 底条；点击"开始练习"仍跳复习页 | 人工回归 |
| AC-05 | T-07 | `evidenceColor` 只有 1 处实现，详情页与工具面板同 signal 同色 | grep + 双页对照 |
| AC-06 | T-08 | 变更新缩分类后 Picker 回退"全部"且无异常 | 数据注入回归 |
| AC-07 | T-02..T-09 | 本页 `Divider()` ≤ 2；`.system(size:` 出现为 0 | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 分栏放行 | AC-01 | 待办 |
| T-02 列头整合 | AC-02 | 待办 |
| T-03 UnifiedSearchField | AC-02 | 待办 |
| T-04 listSelection | AC-03 | 待办 |
| T-05 去底部条 | AC-04 | 待办 |
| T-06 详情字体 | AC-07 | 待办 |
| T-07 证据色 | AC-05 | 待办 |
| T-08 分类兜底 | AC-06 | 待办 |
| T-09 圆点统一 | AC-02 | 待办 |
