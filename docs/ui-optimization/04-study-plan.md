# 04 · 学习计划页优化任务

> 涉及文件：`Views/StudyPlanWorkspaceView.swift`（含 `StudyTaskEditorView`、`AIStudyPlanPreviewView`）
> 页面定位：日历（左）+ 时间线（右）双栏。当前是"多个顶部 + 多条分界线"问题最典型的页面：header(58) → 线 → summaryStrip(64) → 线 → HSplit，而日历列内部又夹 3 根 Divider。

## 现状核实

| 项 | 证据 | 问题 |
|---|---|---|
| 页面骨架 | L11–21：header(58) + Divider + summaryStrip(64) + Divider + HSplitView | 页面级横线 2 根 + 双条带；行高 58 是全局独一档 |
| 页面头 | L46–89：标题 .title3 + 日期 caption + AI安排/今天/新建任务，`.controlSize(.small)`，`padding(.horizontal, 18)` | 58 高度独一档；padding 18 野生值 |
| summaryStrip | L91–114：4 指标 + 3 条竖 Divider(30) | 指标条本身是内容，不应被上下夹成"第二根顶" |
| 日历列 | L116–144：月头(46) + Divider + 月历 + Divider + 图例(42) + Divider + 当日日程 | **一个栏目内部 3 根 Divider**，直接违反主线 2 |
| 信息重复 | L146–218 `selectedDayAgenda` 与 L288+ `timelinePane` 渲染同一份 selectedTasks；新建入口 3 处（header "新建任务"、日程加号、时间线"添加"） | 同一信息在两个栏目重复 |
| 完成键 | L344–347：17pt checkmark 图标，无 frame | 命中区仅 ~17pt |
| 状态圆点 | L682–685：7×7 + top 6；力扣页同类圆点 4×4 | 同一视觉语义两套尺寸 |
| 分栏 | L17–20：日历 292/330/390（max 写死）+ 时间线 min 480 | min 合计 772 ≫ 620 token；日历 max 390 浪费宽屏 |
| 重复实现 | `priorityColor` L441 与 L714 两份 | 合并为一份 |
| 错误反馈 | L466：保存失败仅 `NSSound.beep()` | 无 UI 可见反馈 |
| 日历周起始 | L394/L402：硬编码周一起始 | 与系统 firstWeekday 脱耦 |
| 其他 | sheet 固定 500×420 / 620×560；L249 日期 12 mono、L345 完成钮 17、L354/L690 标题 14 medium ×2 硬编码 | token 化 |

## 优化目标

1. 页面骨架收敛为：页头(54 prominent) → 1 根线 → 双栏；页面级横线 ≤ 2 根（含时间线内侧 1 根）。
2. 日历列内部 0 Divider：月头/月历/图例用 8/16 留白分隔。
3. 同一日任务只在一个栏目出现；新建入口全局唯一（页头主按钮）。
4. 分栏最小宽 ≤ 620。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | 页头规格化 | G-T3 | header 58 → `PageHeader.prominent = 54`；`padding(.horizontal, 18)` → `Spacing.md`(16)；保留 AI安排/今天/新建任务三键，新建任务保持 borderedProminent 唯一主按钮 | **P0** |
| T-02 | 页面横线收敛 | G-T4 | 删除 summaryStrip 上下的第 2 根 Divider：保留 header 下边界 1 根；strip 与 HSplit 之间用留白 | P0 |
| T-03 | 日历列 0 线化 | G-T4 | 删除日历列内 3 根 Divider（L128/133/139）；月头 46→44；图例高度 42→40 并入月历底部留白块 | P0 |
| T-04 | 去重 | — | 删除 `selectedDayAgenda`（L146–218）；日历列 = 月头 + 月历 + 图例；时间线列保留当日任务；删除日程列的加号入口，新建统一走页头"新建任务" | P0 |
| T-05 | 分栏放行 | — | 日历 260/300/360 + 时间线 min 360，合计 min 620；日历 max 由 390 → 360 | P1 |
| T-06 | 完成键命中区 | G-T5 | L344 完成键套 28×28 内容形状；图标 17 → 15 并保持视觉密度 | P1 |
| T-07 | 圆点统一 | G-T6 | 7×7 → 6×6，与 ColorToken 映射合并；`priorityColor` 两份实现合并到文件底部单一函数 | P1 |
| T-08 | 保存反馈 | — | L466 beep 外加 Sheet 内错误横幅（`Label(失败原因, systemImage: "exclamationmark.triangle")` + warning 色），失败时不关 sheet | P1 |
| T-09 | 字体 token 化 | Typography | 空态 19 light、日期 mono 12、完成钮 17、任务标题 14 medium ×2 全部接入 Type Ramp（rowTitle 15 medium / aux 12） | P1 |
| T-10 | 周起始跟随系统 | — | L394/L402 硬编码周一 → `Calendar.current.firstWeekday` 动态 | P2 |
| T-11 | 页头按钮收敛 | G-T7 | 当前 AI安排(bordered) + 今天(borderless) + 新建任务(borderedProminent) 三种样式并吵：保留新建任务为唯一 borderedProminent；"AI 安排"改 borderless + sparkles 图标；"今天"保持 borderless；`.controlSize(.small)` 保留 | P1 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01/T-02 | 页面 top→HSplit 之间仅 1 根横 Divider；页头 54 高 | 截图测量 |
| AC-02 | T-03 | 日历列内无 Divider，月头/月历/图例三段视觉次序与原来一致 | 截图对比 |
| AC-03 | T-04 | 选中某天，左侧只显示月历与图例，任务只出现在右栏；全页新建入口仅 1 处 | 人工点选 |
| AC-04 | T-05 | 窗口 900px，日历+时间线均无横向裁切 | 拖窗核对 |
| AC-05 | T-06/T-07 | 完成键 1 次点击命中；两页面圆点视觉一致 | 人工对比 |
| AC-06 | T-08 | 断开磁盘写权限触发保存失败，sheet 内出现错误横幅且不关闭 | 单元/手工注入 |
| AC-07 | T-09 | 本文件 `.system(size:` 出现次数为 0 | grep 核对 |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 页头规格化 | AC-01 | 待办 |
| T-02 横线收敛 | AC-01 | 待办 |
| T-03 日历 0 线化 | AC-02 | 待办 |
| T-04 信息去重 | AC-03 | 待办 |
| T-05 分栏放行 | AC-04 | 待办 |
| T-06 完成键 | AC-05 | 待办 |
| T-07 圆点统一 | AC-05 | 待办 |
| T-08 保存反馈 | AC-06 | 待办 |
| T-09 字体 token 化 | AC-07 | 待办 |
| T-10 周起始 | AC-04 | 待办 |
| T-11 页头按钮收敛 | AC-01 | 待办 |
