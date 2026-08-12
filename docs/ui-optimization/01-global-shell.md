# 01 · 全局外壳（窗口 titlebar + 全局侧栏）优化任务

> 涉及文件：`Views/RootWorkspaceView.swift`、`Views/GlobalSidebarView.swift`、`App/LeetCodeAssistantApp.swift`、`Models/WorkspaceState.swift`
> 页面定位：所有页面共用的一层外壳。它是"分裂感"的第一来源：titlebar 自身两行控件、侧栏独立头部、侧栏两条 Divider、与页面内容各自为政。

## 现状核实（行号为当前快照）

| 项 | 证据 | 问题 |
|---|---|---|
| titlebar 左组 | Root L132–192：后退/前进/新建 + 标题（14 semibold 硬编码）+ ellipsis 菜单 22×22（L183） | 菜单键命中区 <28；标题字号未走 token |
| 标题显示阈值 | Root L162：`windowWidth >= 1_260` 直接布尔切换 | 1259/1260 之间标题瞬间消失，无迟滞、无渐隐 |
| titlebar 右组 | Root L320–470：固定宽 116、图标 16pt / 32×30、两套按钮组（chromeButtons ↔ toolWorkspaceButtons，Root L346–352） | 展开/收起工具面板时整组瞬间替换，无过渡动画 |
| 空态隐藏 | Root L45/L81–83：空会话时隐藏整个 window toolbar | 新上线的正确方向，需固化为规范并复核边界 |
| 侧栏顶部 | Sidebar L82–133："LeetCode AI" 20 semibold（fixedSize）+ 搜索键 30×30 + 展开后搜索框 32 高 | 20pt 与 15pt 的窗口内容不搭；`20` 硬编码 |
| 侧栏按钮 | Sidebar L135–146：新建会话整宽 36 高按钮 | 与 titlebar 新建键重复，可保留但样式需降级为"行" |
| 侧栏分界线 | Sidebar L21、L58：两条 Divider + 一段 LazyVStack | 直接违反主线 2 |
| 侧栏字号 | Sidebar L154/L184/L219/L252/L277：13.5pt 半点 ×5 处 | 统一切到 Typography |
| 行缩进 | Sidebar L156 `.padding(.leading, 27)` vs L221/L254 `35` | 两级缩进体系对不齐 |
| 分组图标 | Sidebar L29/L36/L43：三组全用 `folder` | 会话/题单语义不符：应为 `clock`、`list.bullet.rectangle` |
| 选中色 | Sidebar L344–347：`primary.opacity(0.075/0.13)` 深浅两值 | 未走 listSelection 体系（G-T6） |
| 账户行 | Sidebar L287 inlineGlass；头像 28 圆形 + 阴影 | 阴影 `.black.opacity(0.14)` 在浅色下偏重 |
|大连看板| WorkspaceState L438–444：900/1180/1280/1600/1850 + 44 迟滞 | 正确机制，但常量是 private，与 DesignTokens 分离 |

## 优化目标

1. titlebar 成为全 App **唯一全局顶条**：左侧导航+标题，右侧胶囊操作组；空会话时整栏（含右组）隐藏且行为有明确规范。
2. 侧栏 = 品牌/搜索行 + 主导航 + 底部账户，**零 Divider**，分组用留白。
3. 全部字号/间距/圆角走 token；侧栏与内容区视觉同源（同一选中色、同一行高族）。

## 任务拆分

| 编号 | 任务 | 关联 | 改动要点 | 优先级 |
|---|---|---|---|---|
| T-01 | ellipsis 与 icon-only 键命中区 ≥ 28 | G-T5 | Root L183 `frame(width: 22, height: 22)` → 28×28；侧栏搜索键 30 保持 | P0 |
| T-02 | 标题阈值加迟滞 | — | Root L162 的 `>= 1_260` 改为迟滞比较（宽度跌破 1260 隐藏、回到 1320 以上才显示），与 WorkspaceState 的 `compactFlag` 同构 | P1 |
| T-03 | 右组按钮切换过渡 | — | Root L346–352 两组按钮 swap 包进 `withAnimation(AppDesign.Motion.panel)` + `.transition(.opacity)`，消除展开/收起工具面板时的瞬跳 | P1 |
| T-04 | 侧栏"一顶"重构 | G-T3/G-T4 | Sidebar L82–133 品牌行降为 15 semibold（Typography.sectionTitle），移除 L21  Divider；新建会话行（L135）保留但视觉降为普通行 + 快捷键提示，不再当主按钮 | P0 |
| T-05 | 移除侧栏底部 Divider | G-T4 | Sidebar L58 Divider 删除，账户行上用 8pt 留白分隔；accountMenu 保持 inlineGlass | P0 |
| T-06 | 侧栏行口径统一 | G-T5/Typography | L154/L184/L219/L252/L277 13.5 → Typography.body；`indented` 缩进统一为 27（删 35）；分组图标按语义更换（最近会话 `clock`、力扣题单 `list.bullet.rectangle`） | P0 |
| T-07 | 侧栏选中色统一 | G-T6 | `hoverlessSelection(_:)` 改为 `ColorToken.listSelection`（见 06 T-04 定义），删除深浅双值分支 | P0 |
| T-08 | 头像阴影收敛 | — | Sidebar L312 shadow 0.14 → 0.08、`y: 1` 保持；白色描边 0.45 → 0.3 | P2 |
| T-09 | 断点单源化 | — | WorkspaceState `LayoutBreakpoints`（900/1180/1280/1600/1850/44 迟滞）迁移到 `AppDesign.Size.Breakpoint`，行为参数零变化 | P1 |
| T-10 | 空态隐藏行为固化 | — | 把 `hidesWindowToolbar`/`hidesTrailingChrome` 的判定收敛为一份 `WindowChromePolicy`（纯函数），补单元测试覆盖：空会话+工具开、空会话+工具关、有内容三种组合 | P1 |

## 验收标准

| 编号 | 关联 | 验收条件 | 验证方式 |
|---|---|---|---|
| AC-01 | T-01/T-03 | 窗口缩放往复 1250→1350：标题不闪烁；工具面板展开收起时右组按钮淡入淡出 | 手动：拖动窗口边框观察 |
| AC-02 | T-04/T-05 | 侧栏自上而下：品牌/搜索行 → 新建会话行 → 导航列表 → 账户行，全程 0 根 Divider | 截图比对 |
| AC-03 | T-06 | GlobalSidebarView 内 `.system(size:` 出现次数为 0；两级缩进数值仅 27 一个 | `grep -n "system(size" GlobalSidebarView.swift` 为空 |
| AC-04 | T-07 | 侧栏选中色由 `ColorToken.listSelection` 渲染；深浅色外观下选中都可见 | 切换系统外观人工核对 |
| AC-05 | T-09 | `grep -rn "LayoutBreakpoints" native/` 仅剩 Design/ 内的定义；行为回归通过 WorkspaceStateTests | `swift test --filter WorkspaceStateTests` |
| AC-06 | T-10 | WindowChromePolicy 三组合真值表测试全部通过 | 单元测试 |

## 进度追踪表

| 任务 | 关联 | AC | 状态 |
|---|---|---|---|
| T-01 命中区 | G-T5 | AC-01 | 待办 |
| T-02 标题迟滞 | — | AC-01 | 待办 |
| T-03 右组过渡 | — | AC-01 | 待办 |
| T-04 侧栏一顶 | G-T3/T-04 | AC-02 | 待办 |
| T-05 去底部分割线 | G-T4 | AC-02 | 完成（2026-08-10：L58 Divider 已删） |
| T-06 行口径 | Typography | AC-03 | 待办 |
| T-07 选中色 | G-T6 | AC-04 | 完成（2026-08-10：`hoverlessSelection` 已改 `listSelection`） |
| T-08 头像阴影 | — | AC-02 | 待办 |
| T-09 断点单源 | — | AC-05 | 待办 |
| T-10 空态规范 | — | AC-06 | 待办 |

> 对照参照系（README 第三节）自查结论：侧栏"品牌行 + 新会话行 + 零横线"与 Codex 结构一致，差距在去掉 Divider 后的执行（T-04/T-05）与行口径统一（T-06），以及入口样式不要比 Codex 的"新聊天"更重。
