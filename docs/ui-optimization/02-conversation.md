# 02 · 对话页（消息 / composer / 空态 / 问题轨道）优化任务

> 涉及文件：`Views/ConversationWorkspaceView.swift`（含 `ComposerView`、`ConversationEmptyStateView`、`BraunClockView`、`ReasoningPopover`、`ContextUsagePopover`）、`Views/RichConversationWebView.swift` 及其加载的 `conversation.html`、Root 内 `QuestionRailView`
> 页面定位：App 的主界面，也是全局"一顶"的标杆页：系统 titlebar 之下不再有页面级头部，消息区直接铺满，composer 悬浮式落地。本轮优化**保护这一结论**，只处理 composer 内部口径、空态材质、Web 层字号。

## 现状核实

| 项 | 证据 | 问题 |
|---|---|---|
| 整体结构 | L9–37：ZStack 底对齐 + WebView + composer | ✅ 无页面头、无多余横线，符合主线 1/2 |
| composer 间距 | L567 `HStack(spacing: 9)`；L626–627 `padding(.horizontal, 10)/(.vertical, 8)` | 9/10 均野生值，距 token(8/12) 一步之遥 |
| 队列条 | L664–671 `.padding(.leading,13)/(.trailing,7)/(.vertical,7)` + L564 `Divider().padding(.horizontal,10)` | 三向不对称；队列清钮 22×22 命中区偏小 |
| 模型选择器 | L718–782：宽度三档 92/116/142 死断点 980/1260，三层 `.clipped()`（L758/763/772），文本 12 medium 硬编码 | 窗口掠过断点时宽度瞬跳；clipped 嵌套冗余 |
| 发送按钮 | L613–621：符号 13pt、停止 10pt 切换；L829–832：isGenerating 时底色 `.primary` | 生成中图标尺寸突变；**深色模式生成中 = 白底+白图标，不可见（色差 bug）** |
| 添加图片键 | L567–583：plus 无字号、28×28；角标 8pt/13×13 | 角标低于可读下限 |
| 上下文圆环 | L834–844：16pt 环 + 28×30 槽；L839 `Color.orange` | 未走 `ColorToken.warning`；口径可保留 |
| Popover | L931/L976：两个 Popover 均固定宽 300 | 可入 token `Size.popoverWidth = 300` |
| 空态 | L397–432：Braun 时钟直径 220~300、日期 13 medium、composer | L493–503 表盘 `Color.white` 渐变 + 白描边，深色模式下刺眼；spacers 32/72 硬编码 |
| 问题轨道 | Root L631–755：宽 68、题型数 ≥6、宽度 ≥1250 出现 | 基本定型；触发条件 6 题偏高，建议 4 题启用 |
| Web 层 | conversation.html：根 `font: 15px`；`.code-head 12px`、`figcaption 11.5px`、`think 12.5/13.5px`、`tool-chip 11.5px`；灯箱用 `‹ › × − +` 文本字符 | 半点字号 ×4；文本符号代图标；根字号与 SwiftUI 体系脱钩 |

## 优化目标

1. composer 成为全局"控件条"的规范样板：分距 8、控件高 28、按序排列（附件 → 输入 → 模型/上下文/推理 → 发送）。
2. 深色/浅色下所有控件对比度达标，无色阶反相 bug。
3. conversation.html 字号与 SwiftUI Type Ramp 对齐，消除半点 px。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | 发送按钮深色反相修复 | — | L617 `.foregroundStyle(.white)` 改为根据 `sendButtonColor` 取反色（`.white` ↔ `Color(nsColor: .textBackgroundColor)`），覆盖生成态 `.primary` 底 | **P0** |
| T-02 | composer 间距 token 化 | G-T2 | `spacing: 9` → `Spacing.xs`(8)；`horizontal 10` → 新增 `Spacing.compact`(10)；`vertical 8` → `Spacing.xs`(8) | P1 |
| T-03 | 队列条整合 | G-T4 | 去掉 13/7/7 不对称值（→ 12/8/10），清空键 22×22 → 28×28；条下 Divider 保留但 `.horizontal` 12 | P1 |
| T-04 | 模型选择器重构 | G-T5 | 三层 `.clipped()` 合并一层；宽度三档改为迟滞（980→96、1260→144，60 迟滞带）；文本 12 → `Typography.aux`；`showsModelIcon` 阈值 1050 同步迟滞 | P1 |
| T-05 | 上下文环接入 token | G-T6 | L839 `.orange` → `ColorToken.warning` | P2 |
| T-06 | 添加图片键字号 | G-T5 | plus 图标补 `.font(.system(size: 15))`；角标 8pt → 10pt（`Typography.micro`）并改圆角矩形 background 以维持可读 | P1 |
| T-07 | 空态时钟深色适配 | — | 表盘渐变改按 `colorScheme`：浅色白→controlBackground，深色 controlBackground→black；阴影值入 token；spacer 32/72 → `Spacing.xl` / `Spacing.xl*2` | P1 |
| T-08 | Popover 宽入 token | G-T2 | 新增 `Size.popover = 300`，替换 L931/L976 | P2 |
| T-09 | Web 层字号收敛 | Typography | conversation.html 根 15px → 14px；11.5/12.5/13.5 → 11/12/13；'.code-head' 12 保持；灯箱字符替换为内嵌 SVG chevron/xmark（沿用现有 CSS 按钮样式） | P1 |
| T-10 | 问题轨道路径 | — | 出现条件 `questionCount >= 6` 降为 4；宽度 68 保持；railPreview 宽 260 → `Size.popover` 的同系 token（260 新档） | P2 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01 | 深色外观、生成中点击发送键，图标与底色对比度 ≥ 7:1 | 深色模式手动生成一次 |
| AC-02 | T-02/T-03 | 拖拽窗口 820→1700，composer 控件无错位、无不必要间隙；清空键可 1 次命中 | 人工拖窗 + 点击 |
| AC-03 | T-04 | 窗口宽 975/985 之间往复，模型选择器宽度不闪跳；长模型名中间截断正常 | 拖窗 + 选择超长模型名 |
| AC-04 | T-09 | 会话内正文 14px 无半点字号（HTML 全文检索不到 `.5px`）；灯箱图标为 SVG | 在 WebView 内 Inspect / 搜源码 |
| AC-05 | T-07 | 深浅外观切换，空态时钟不刺眼、描边可见 | 双外观截图 |
| AC-06 | T-05/T-06/T-08 | `ConversationWorkspaceView.swift` 内 `.system(size:` 出现次数为 0（图标尺寸走 G-T5 统一口径） | `grep -n "system(size" ConversationWorkspaceView.swift` |

## 进度追踪表

| 任务 | AC | 状态 |
|---|---|---|
| T-01 发送按钮反相 | AC-01 | 待办 |
| T-02 composer 间距 | AC-02 | 待办 |
| T-03 队列条 | AC-02 | 待办 |
| T-04 模型选择器 | AC-03 | 待办 |
| T-05 上下文环 | AC-06 | 待办 |
| T-06 添加图片键 | AC-06 | 待办 |
| T-07 空态时钟 | AC-05 | 待办 |
| T-08 Popover 宽 | AC-06 | 待办 |
| T-09 Web 字号 | AC-04 | 待办 |
| T-10 问题轨道 | AC-02 | 待办 |
