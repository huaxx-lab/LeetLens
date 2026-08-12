# 10 · 设置页优化任务

> 涉及文件：`Views/SettingsView.swift`（含登录 sheet、账户/外观/供应商/路由/历史/统计等全部子页）
> 页面定位：全量替换窗口内容的"应用内应用"，自带侧栏 + 详情。它是字体硬编码最多（≈30 处）、顶部结构最重（侧栏带两行顶部 + 详情大标题）、且藏有一个**用户可见的文案 bug** 的页面。

## 现状核实

| 域 | 证据 | 问题 |
|---|---|---|
| 侧栏宽度 | L84：`min 252, ideal 278, max 304` | 与全局侧栏 token（218/256/310）同概念两套 |
| 侧栏顶部 | L27–63：返回行（Label 15pt / 高 32）+ 刷新键（15pt / 32×32）+ 搜索胶囊（40 高/半径 20）| 三行顶部叠放；胶囊 20 圆角与行圆角 10 两套语言 |
| 侧栏行 | L115–139：图标 17pt/槽 24 + 文字 15 + 高 40 + radius 10 + 选中 `primary 0.075` | 与全局侧栏（13pt / 34 高 / radius 8 / listSelection）两套系统 |
| 详情页头 | L98–113：标题 **28 bold** + 副标题 14，`padding(.top, 34)` | 全 App 最大硬编码标题字 |
| 行字体三体系 | SettingsRow 15/13；providerRow·routeRow 15/12；视频历史 14/12；另有 14.5 半点（L958） | 同级信息四档字号 |
| 图标槽位 | L284 槽 26 / L623 槽 22 / L916 槽 24 / ProviderRow 15pt | 四种槽位宽，左缘不齐 |
| 固定列 | API 地址/Key 320（L477/483）、响应模式 180、路由行 245+172、分段 210、视频封面 128×72 | detail 列硬下限 ≈750，窗口收窄即截断 |
| CardDivider | L359–363：前导 18，而带图标行文字起点 18+26+14=58 | 分隔线"切开"图标列，与文字左边沿错位 |
| 文案 bug | **L1113：`"UID (dataStore.bilibiliUserID)"` 缺 `\`** | 用户会看到字面代码 |
| 滑杆色 | L838–862：六个 Slider 分别 `.tint(.blue/.cyan/.orange/.purple/.green/.pink)` | 违反 macOS 单 accent 惯例 |
| 表面色 | L59/93/1529 直写 `textBackgroundColor` | 绕过 `ColorToken.canvas` |
| 其余 | L979 `.background(.primary.opacity(0.001))` 命中 hack；L1226 关闭 xmark 无 frame；L557 状态靠 `contains("成功")` 判定文字色 | 多处工艺债 |

## 优化目标

1. 设置侧栏**完全复用全局侧栏口径**：行高 34、图标 15/24、字 13、选中 listSelection、搜索统一组件。
2. 详情页头从 28 bold 大标题收敛为页面标准头（26 display / 54 体系），并与内容同列对齐。
3. 行字体统一 rowTitle 15 medium + aux 12；图标槽唯一。
4. 固定列弹性化，窗口最小宽内无截断。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | **修复 L1113 插值** | — | `"UID \(dataStore.bilibiliUserID) · 官方 Web 会话"` | **P0** |
| T-02 | 侧栏列宽对齐 token | — | 252/278/304 → 218/256/310（`Size.sidebarMin/Ideal/Max`） | P0 |
| T-03 | 侧栏顶部收敛为一行 + 搜索 | G-T3/T-04 | 返回行与刷新键合并为一行 32 高；搜索胶囊 40/r20 → UnifiedSearchField（30/radius 8）；删除搜索下多余 padding | P0 |
| T-04 | 侧栏行复用全局口径 | G-T5/T-06 | 图标 17→15、槽 24 保持；文字 15→13；行高 40→34；radius 10→8；选中 `primary 0.075` → `listSelection` | P0 |
| T-05 | 详情页头缩放 | G-T3 | 28 bold → `Typography.display`(26 semibold)；`padding(.top,34)` → 24；maxWidth 700 → `Size.contentReadable`(780) | P0 |
| T-06 | 行字体统一 | Typography | 全部行标题 `Typography.rowTitle`（15 medium）、副标 `Typography.aux`（12）；消灭 14 档与 14.5 | P0 |
| T-07 | 图标槽统一 | G-T5 | 四种槽宽 → 24；图标 15pt；卡片标题 17 → `Typography.sectionTitle` | P1 |
| T-08 | CardDivider 对齐文字 | G-T4 | 带图标行前导 = 文字起点（18→58 或按新槽重算） | P1 |
| T-09 | 固定列弹性化 | — | API/Key 320 → `maxWidth 380` 弹性；路由行 245+172 → `Grid` 列或 `layoutPriority` 分配；视频封面 128×72 保持 | P1 |
| T-10 | 滑杆色归一 | G-T6 | 六 Slider 的彩虹 tint → `accentColor`，每个滑杆靠 Label 文案区分 | P1 |
| T-11 | 表面色入 token | G-T6/G-T2 | L59/93/1529 `textBackgroundColor` 直写 → `ColorToken.canvas` | P1 |
| T-12 | 工艺债 | — | L979 命中 hack → `.contentShape(Rectangle())`；L1226 关闭键 28×28 | P2 |
| T-13 | 状态判定健壮性 | — | `contains("成功")` → 状态中台（枚举驱动颜色），本轮先加注释+最小提取函数 | P2 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01 | 登录 B 站后账户行显示真实 UID，无字面代码 | 人工登录回归 |
| AC-02 | T-02/T-03/T-04 | 设置侧栏与全局侧栏并排：行高/字号/选中一致；侧栏顶部只剩两行（返回行、搜索框） | 双窗口对照截图 |
| AC-03 | T-05 | 详情页头 26pt、与内容列同宽起点；上留白 24 | 截图测量 |
| AC-04 | T-06/T-07 | `SettingsView.swift` 内 `.system(size:` 出现为 0；行标题/副标全为 token | grep 核对 |
| AC-05 | T-08 | CardDivider 左边沿与行文字左缘像素对齐 | 截图放大核对 |
| AC-06 | T-09 | 窗口 900px 时，连接/路由/外观各页详情无横向截断 | 拖窗逐页核对 |
| AC-07 | T-10 | 外观页滑杆全部 accent 色，不分组变色 | 截图 |
| AC-08 | T-01..T-13 | `Divider()` 以 CardDivider 为主统一实现；无 `0.001` hit hack | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 L1113 | AC-01 | 待办 |
| T-02 侧栏宽 | AC-02 | 待办 |
| T-03 顶部收敛 | AC-02 | 待办 |
| T-04 行口径 | AC-02/04 | 待办 |
| T-05 页头缩放 | AC-03 | 待办 |
| T-06 行字体 | AC-04 | 待办 |
| T-07 图标槽 | AC-04/05 | 待办 |
| T-08 Divider 对齐 | AC-05 | 待办 |
| T-09 列弹性 | AC-06 | 待办 |
| T-10 滑杆色 | AC-07 | 待办 |
| T-11 表面色 | AC-04 | 待办 |
| T-12 工艺债 | AC-08 | 待办 |
| T-13 状态判定 | AC-08 | 待办 |
