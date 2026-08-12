<p align="center">
  <img src="assets/app-icon.png" width="104" height="104" alt="LeetCode AI 助手图标">
</p>

<h1 align="center">LeetCode AI 助手 2.0</h1>

<p align="center"><strong>你只管提问、刷题和作答，AI 负责把学习自动整理成下一步。</strong></p>

<p align="center">2.0 把整个客户端用 SwiftUI 重写成原生 macOS 应用：同一套学习引擎，换成不吃内存的原生外壳、可拖动的知识图谱、分级 AI 提示，以及一条全程可查账的模型调用链路。</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-292E33?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/SwiftUI-native-0B84FF?logo=swift&logoColor=white" alt="SwiftUI">
  <img src="https://img.shields.io/badge/version-v2.0.0-2563EB" alt="Version 2.0.0">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0F766E" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#项目介绍">项目介绍</a> ·
  <a href="#为什么值得一试">为什么值得一试</a> ·
  <a href="#亮点速览">亮点速览</a> ·
  <a href="#产品展示">产品展示</a> ·
  <a href="#核心亮点">核心亮点</a> ·
  <a href="#工作原理">工作原理</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/huaxx-lab/leetcode-ai-helper/stargazers">
    <img src="https://img.shields.io/github/stars/huaxx-lab/leetcode-ai-helper?style=social" alt="给项目点个 Star">
  </a>
</p>

<p align="center"><strong>⭐ 如果它帮你少走了弯路，点个 Star 让更多人看到——这是这个项目继续做下去最直接的动力。</strong></p>

---

| 你只需要做 | AI 在后台自动完成 |
| --- | --- |
| 提问不懂的地方、编写并提交代码、完成复习检测 | 识别学习问题、归并重复知识、分析错因、提取前置知识、记录能力证据、更新掌握度、按遗忘曲线安排复习、总结主题模板、管理上下文与学习进展 |

<a id="项目介绍"></a>

## 项目介绍

LeetCode AI 助手不是一个自动给答案的聊天外壳，而是一套运行在 macOS 上的个人算法学习系统。它把提问、代码提交、判题结果和复习作答视为连续的学习证据，由 AI 自动完成「发现问题 → 提取本质知识 → 更新掌握判断 → 安排下一次练习」的后续工作。

它刻意不做的事同样重要：不替你写完整解法（写代码时的 AI 提示只给方向和卡点）、不把「看过题解」算作掌握、不覆盖历史尝试。每一个掌握判断都能追回到某一次具体的提问、提交或检测。

<a id="为什么值得一试"></a>

## 为什么值得一试

**真·macOS 原生，不是套壳网页。** 2.0 全部界面由 SwiftUI 重写，Swift 6 严格并发。窗口、侧栏、工具区、滚动、玻璃材质都是原生视图，冷启动是 O(1) 的：首屏只读必要索引，向量与长期记忆在后台补齐。同样的学习数据，原生版启动更快、滚动不掉帧、内存占用只有 Electron 版的一小部分，也不用为一个学习工具常驻一个 Chromium。

| | 一般 AI 刷题工具 | 本项目 2.0 |
| --- | --- | --- |
| 形态 | 网页 / 套壳客户端 | 原生 macOS 应用（SwiftUI + Swift 6） |
| 学到什么 | 给答案、给题解 | 只给方向与卡点，答案要你自己写出来 |
| 掌握度 | 打卡数、做题数 | 证据驱动，且按遗忘曲线折算「现在还剩多少」 |
| 复习 | 固定提醒 | FSRS 间隔 + 遗忘曲线 + 薄弱度动态重排 |
| 笔记 | 你自己维护 | AI 派生知识树，你只补自己的笔记与链接 |
| 模型 | 绑定单一供应商 | 任意兼容供应商，六类任务可分别路由 |
| 花了多少钱 | 不透明 | 按供应商 / 模型 / 任务分别记账，精确与估算分开 |

**本机优先，也能接自己的后端。** 全部数据默认落在本机；需要多端共用时，可以自己接一套可选后端：Redis 做分析结果、提交详情与用量计数的热缓存，PostgreSQL + pgvector 做跨对话检索的向量库，Eclipse JDT LS 提供 Java 补全。三者都是旁路——任何一个不可用都会自动回落到本机路径，功能不会因此中断。部署脚本随仓库提供，见 [可选后端服务](#可选后端服务)。

<a id="亮点速览"></a>

## 亮点速览

<table>
<tr>
<td width="33%" valign="top">

### 🖥 真·原生

SwiftUI + Swift 6 重写全部界面，冷启动 O(1)，滚动不掉帧，不为一个学习工具常驻 Chromium。

</td>
<td width="33%" valign="top">

### 🧠 会遗忘的掌握度

FSRS 保持率贯穿复习、洞察、图谱与计划——「学过」和「现在还会」是两回事。

</td>
<td width="33%" valign="top">

### 💡 只给方向

三级提示读你当前的代码，指路不给答案；输出后还要过一遍完整解法拦截。

</td>
</tr>
<tr>
<td valign="top">

### 🗺 会长大的知识图谱

AI 从真实题目派生知识树，你只补自己的笔记与链接；点哪段改哪段，点开就写。

</td>
<td valign="top">

### 🧾 每一分钱都可查

按供应商 / 模型 / 任务记账，精确与估算分开；六类任务可分别路由到不同模型。

</td>
<td valign="top">

### 🗄 本机优先，后端可选

数据默认留本机；要多端共用再接 Redis 与 pgvector，掉线自动回落，不掉功能。

</td>
</tr>
</table>

<a id="产品展示"></a>

## 产品展示

### 知识图谱

AI 从真实题目派生知识树，节点显示分支下的题目数与平均掌握度（已按遗忘曲线折算）。手工层只叠加你自己的东西：笔记、链接、排序、折叠。删掉一个知识点，挂在它上面的笔记和链接会跟着清掉，不会留下指向空气的虚线。

<p align="center">
  <img src="docs/screenshots/knowledge-graph.png" width="100%" alt="知识图谱画布：概念分支、掌握度与笔记卡片">
</p>

### 刷题闭环

<table>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/problem-and-submission.png" alt="题面与提交轨迹"><br><sub><b>题面 + 提交轨迹</b>：每次提交按 <code>submissionId</code> 独立归因，汇成「待巩固 / 下一步」</sub></td>
<td width="50%" align="center"><img src="docs/screenshots/ai-hint.png" alt="AI 分级提示"><br><sub><b>分级提示</b>：方向 → 卡点 → 下一步，读你的代码但不写你的代码</sub></td>
</tr>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/java-completion.png" alt="Java 补全"><br><sub><b>原生编辑器</b>：语法检查、格式化，可选接入 Eclipse JDT LS 做类型与 API 补全</sub></td>
<td width="50%" align="center"><img src="docs/screenshots/study-plan.png" alt="学习计划"><br><sub><b>学习计划</b>：AI 只决定学什么，排到哪一天由本地按配额与时长算</sub></td>
</tr>
</table>

### 对话、浏览器与模型

<table>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/chat-and-browser.png" alt="对话与内置浏览器"><br><sub><b>一套代码渲染</b>：对话、题解、题面、笔记共用同一套高亮与复制；右侧是真正的多标签浏览器</sub></td>
<td width="50%" align="center"><img src="docs/screenshots/provider-settings.png" alt="模型供应商设置"><br><sub><b>任意供应商</b>：六类任务分别路由，API Key 存系统钥匙串，界面只显示「已配置」</sub></td>
</tr>
</table>

<a id="核心亮点"></a>

## 核心亮点

### 学习闭环：证据进，下一步出

| 能力 | 它具体做什么 |
| --- | --- |
| **增量证据识别** | 只分析尚未处理的消息与新提交，不重复烧同一段上下文 |
| **跨对话归并** | 同一知识点按稳定的 `canonicalKey` 合并，证据累积而不是长出重复卡片 |
| **本质知识提取** | 把一道题拆成算法模式 / 数据结构 / 语言机制 / 常用 API，路径来自受控词表 |
| **掌握度与置信度** | 每条证据带信号与置信度，后来的表现可以推翻先前的判断 |
| **遗忘曲线折算** | FSRS 保持率决定「现在还剩多少」，全项目共用同一个掌握度口径 |
| **今日复习** | 按配额出队，逾期优先、忘得多的更优先，支持手动评分回写 |
| **复习检测** | 针对最小缺口出选择 / 简答 / 代码补全 / 编程题，判分写回掌握度与下次到期 |
| **算法模板** | 同一主题题目够多后，归纳适用条件、步骤、常见错误与可编译骨架 |
| **学习洞察** | 主题分布、薄弱项、到期预测、掌握趋势 |
| **回收站** | 删掉的学习项可找回，误删不等于永久丢失 |

### 力扣集成：从题面到判题都在应用里

| 能力 | 它具体做什么 |
| --- | --- |
| **内置登录** | 力扣中国站登录跑在应用自己的隔离会话里，微信 / QQ / GitHub 等第三方弹窗登录都能走通 |
| **题单与同步** | 导入热题 100 等题单，按 `titleSlug` 直取提交记录并增量同步 |
| **原生题面** | 题面、示例、约束、提示原生渲染，代码块与应用其他地方同一套高亮 |
| **运行与提交** | 直接运行样例、提交判题，轮询结果并解析编译错误 / 失败用例 / 通过数 / 耗时内存 |
| **提交轨迹** | 每次提交独立归因，得出「待巩固 / 下一步」，历史尝试只追加不覆盖 |
| **在线看题解** | 官方与社区题解在应用内直接翻，多图收进轮播容器，题解视频就地播放 |
| **题目操作栏** | 点赞、讨论、收藏、分享、官方提示、当前在线人数 |
| **上一题 / 下一题** | 在题单里连着刷，不用回列表页 |
| **活动热力图** | 提交热力图、连击、周节奏与难度分布 |

### 会话与上下文

| 能力 | 它具体做什么 |
| --- | --- |
| **流式回答** | 边生成边渲染，随时中断；推理档位可选关闭 / 低 / 高 / 最高 |
| **上下文预算** | 实时显示占用、输入估算、可用预算与距压缩还有多少 Token |
| **滚动摘要** | 接近上限时后台预热摘要，保留系统指令、当前题目与关键结论 |
| **问题导航** | 长对话里按问题跳转，长提问自动折叠，一键回到底部 |
| **跨对话记忆** | 不记 / 建索引 / 检索回填三档可选，事实抽取 + 向量检索 |
| **图片输入** | 仅 HTTPS 图片、自动去重限量，只有支持视觉的模型才附带 |

### 内置浏览器与工具区

| 能力 | 它具体做什么 |
| --- | --- |
| **真多标签** | 工具标签与网页标签同排一条，宽度随数量收缩，拖动跟手换位 |
| **会话恢复** | 关掉再开还是那几个标签，可在设置里关掉 |
| **历史与下载** | 浏览历史可查可删，下载可选每次询问保存位置 |
| **弹窗桥接** | `window.open` / `target=_blank` 正常工作，OAuth 登录不会把原页面冲掉 |
| **媒体生命周期** | 切走标签自动暂停播放，不让后台标签偷偷占资源 |
| **链接打开位置** | 对话、题解、来源里的链接可设为应用内打开或交给系统浏览器 |
| **B 站视频** | 只有 AI 判定为力扣题目或值得系统学习的知识点时才出现视频入口 |

### 模型与用量

| 能力 | 它具体做什么 |
| --- | --- |
| **任意供应商** | 内置 DeepSeek / 阿里云 / OpenCode Go，也可添加任何兼容接口，支持自定义模型名 |
| **十类任务路由** | 主对话、标题摘要、视频匹配、证据分析、学习计划、讲解出题、作答评分、提交分析、跨对话记忆、写代码提示，各自可指定供应商与模型 |
| **中央账本** | 按对话 / 任务 / 供应商 / 模型统计输入、输出、缓存、推理 Token 与工具调用 |
| **精确与估算分开** | 供应商回传用量才算精确，其余标为估算，不混成一个数 |
| **失败也记账** | 结构化任务要在解码、语义校验与本地处理全部通过后才记成功 |
| **密钥安全** | API Key 存系统钥匙串，界面只显示「已配置」，供应商地址走 HTTPS 白名单校验 |

### 界面与工程

| 能力 | 它具体做什么 |
| --- | --- |
| **液态玻璃** | 卡片、胶囊、弹层统一玻璃材质，背后铺渐变才折射得出来 |
| **自绘悬浮滚动条** | 全项目一套：滚动时淡入、停下淡出，不占布局宽度 |
| **动效有出处** | 选择、面板、淡入各有独立时序；拖拽用补间保证连线与卡片同帧，不甩线 |
| **窗口能力** | 置顶、全屏、跨屏位置记忆、单实例守卫 |
| **外观** | 跟随系统 / 浅色 / 深色，字号随系统文字大小缩放 |
| **回归测试** | 原生侧 216 项 XCTest + 100 项 Swift Testing，Electron 侧 103 项，全绿才发布 |

<a id="工作原理"></a>

## 工作原理

用户只产生真实学习行为，应用围绕这些「证据」自动组织后续工作。原始提问与判题结果负责说明发生了什么，AI 负责结构化、归因和总结，调度器负责决定接下来学什么。

```mermaid
flowchart TD
  A[用户：提问 / 做题 / 作答] --> B[AI：增量证据识别]
  B --> C[题目快照与来源锚点]
  B --> D[本质知识与前置知识]
  C --> E[跨对话归并同一学习项]
  D --> E
  E --> F[更新掌握度 / 置信度 / 证据历史]
  F --> G[FSRS 排期 + 遗忘曲线折算当前记忆]
  G --> H[今日复习队列与 AI 学习计划]
  H --> I[最小讲解与针对性检测]
  I --> J[评分 / 错因 / 下一步]
  J --> F
  E --> K[知识图谱与主题解题模板]
```

三条原则贯穿始终：模型回答本身不算学习证据；看过题解不等于掌握；历史尝试只追加、不覆盖。

## 安全设计

- 仓库不包含 API Key、账号 Cookie、SSH 私钥或服务器地址。
- 原生版的供应商密钥保存在系统钥匙串，Electron 版通过 `safeStorage` 加密后写入本机；界面只显示是否已配置，不回显原文。
- 为生成回答、摘要与提交分析，题目、提问和相关代码会发送给你选择的 AI 供应商；请按对应供应商的隐私政策选择模型与账号。
- 对话、学习项和提交分析保存在本机应用数据目录的 JSON 文件中，目前不做静态加密。请保护本机账号和磁盘，并在分享日志或备份前检查内容。
- 力扣与哔哩哔哩登录状态保存在应用自己的隔离会话中，不写入仓库。
- 远程 Java 补全默认关闭，必须通过本地环境变量显式启用。
- `.env.local`、构建产物、依赖目录、调试截图和私钥文件均已加入 `.gitignore`。

更多说明见 [SECURITY.md](SECURITY.md)。

<a id="快速开始"></a>

## 快速开始

### 环境要求

- 原生版：macOS 15 或更高版本、Xcode 26（含 Swift 6 工具链）、Apple Silicon；
- Electron 版：macOS 13 或更高版本、Node.js 22、Xcode Command Line Tools、Python 3（供 `node-gyp` 使用）；
- 一个受支持 AI 供应商的 API Key。

### 构建并运行原生版（2.0）

```bash
git clone https://github.com/huaxx-lab/leetcode-ai-helper.git
cd leetcode-ai-helper/native
swift build            # 需要 Xcode 26 的 Swift 6 工具链
swift test             # 回归测试
./scripts/build-preview-app.sh
```

脚本会生成图标、构建、清理扩展属性并本地签名，产物在：

```text
native/.build/LeetCode AI 助手 Preview.app
```

仓库在 iCloud / 文件提供程序托管目录下时，`swift build` 可能因为资源包上的扩展属性导致签名失败。把构建目录放到别处即可：

```bash
swift build --scratch-path /tmp/leetcode-native-build
```

### 构建并运行 Electron 版（1.x）

```bash
npm install
npm start              # 或 ./start.sh
npm run install:mac    # 构建并安装到 /Applications
```

### 首次配置

1. 打开设置 → 模型供应商，选择 DeepSeek、阿里云、OpenCode Go 或添加自定义供应商。
2. 填写 API 地址、API Key 和模型，刷新模型列表并保存；需要时按任务分别指定供应商。
3. 在内置浏览器里登录力扣中国站。
4. 导入题单或同步提交记录，即可进入题目工作区运行、提交并查看 AI 分析。

应用数据保存在：

```text
~/Library/Application Support/leetcode-ai-helper/
```

删除仓库或重新构建不会删除这部分数据。提交问题日志前，请移除账号、代码、题目历史和任何凭据内容。

<a id="可选后端服务"></a>

## 可选后端服务

三个服务都是可选的：不部署，应用照常跑（分析结果和向量落本机文件，Java 用本地语法检查与基础补全）。部署之后，多台机器上的客户端共用同一份缓存与向量库。部署脚本在 [`scripts/remote-services`](scripts/remote-services) 与 [`scripts/remote-lsp`](scripts/remote-lsp)。

| 服务 | 作用 | 不可用时 |
| --- | --- | --- |
| Redis | 分析结果、提交详情、用量计数的热缓存，两个客户端共用 | 每次调用有超时上限，失败即熔断，回落本机文件 |
| PostgreSQL + pgvector | 跨对话检索用的 640 维向量库，多端共享 | 暂停该层两分钟，退回本机向量缓存 |
| Eclipse JDT LS | Java 补全 | 退回本地语法检查与基础补全 |

三者都只监听 `127.0.0.1`，客户端通过 SSH 本地端口转发访问；**不要在防火墙上放行 6379 / 5432 / 9092**。

### Redis 与 pgvector

```bash
scp -r scripts/remote-services ubuntu@example.com:/tmp/leetcode-services
ssh ubuntu@example.com
cd /tmp/leetcode-services
cp .env.example .env && $EDITOR .env && chmod 600 .env
docker compose up -d
```

在客户端建隧道，然后在「设置 → 数据与缓存」里填地址、账号与密码并测试连接（密码存进系统钥匙串）：

```bash
ssh -f -N -L 6379:127.0.0.1:6379 -L 5432:127.0.0.1:5432 ubuntu@example.com
```

向量表由应用自动创建；`init-pgvector.sql` 让首次部署一步到位并附带近邻索引。

### Java 补全服务

```bash
scp -r scripts/remote-lsp ubuntu@example.com:/tmp/leetcode-lsp
ssh ubuntu@example.com
cd /tmp/leetcode-lsp
sudo bash install.sh
curl http://127.0.0.1:9092/health
```

客户端把连接信息写进 `.env.local`（不会被 Git 跟踪，也不要把私钥内容放进去）：

```dotenv
LEETCODE_LSP_SSH_HOST=example.com
LEETCODE_LSP_SSH_USER=ubuntu
LEETCODE_LSP_SSH_PORT=22
LEETCODE_LSP_TARGET_PORT=9092
LEETCODE_LSP_SSH_IDENTITY_FILE=/absolute/path/to/ssh_private_key
```

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `cd native && swift build` | 构建原生客户端 |
| `cd native && swift test` | 原生侧回归测试（XCTest + Swift Testing） |
| `native/scripts/build-preview-app.sh` | 生成可直接运行的 `.app` |
| `npm start` / `./start.sh` | 启动 Electron 版 |
| `npm test` | Electron 侧回归测试 |
| `npm run package:mac` | 构建 Electron 版 `.app`、zip 与 DMG |
| `npm run install:mac` | 构建并安装 Electron 版到 `/Applications` |

## 项目结构

```text
native/Sources/             原生客户端：视图、模型、服务与随包资源
native/Tests/               原生侧回归测试
native/scripts/             图标生成与预览 App 构建脚本
src/main/                   Electron 生命周期、IPC 与安全的 preload 桥接
src/renderer/               Electron 版界面、交互状态与样式
src/core/                   学习引擎、知识归并、代码检查与内容处理
src/integrations/           力扣、视频、模型供应商与流式协议适配
src/platform/               macOS 窗口布局、显示器配置与媒体缓存
assets/                     应用图标与供应商图标
scripts/remote-services/    可选后端：Redis + pgvector 的 compose 与初始化 SQL
scripts/remote-lsp/         可选后端：Eclipse JDT LS 安装脚本与 systemd 单元
scripts/                    构建、签名与安装脚本
test/                       无账号数据的回归与安全测试
docs/screenshots/           README 使用的真实产品截图（1.x 的存档在 legacy-electron/）
docs/ui-optimization/       各界面的设计与改造记录
```

## 参与开发

提交前请阅读 [贡献指南](CONTRIBUTING.md) 并运行两侧回归测试。不要提交真实 API Key、Cookie、服务器地址、私钥、应用数据或构建产物。许可证为 [MIT](LICENSE)。

> LeetCode 是其权利人的商标。本项目为独立开源工具，与 LeetCode 官方无隶属或背书关系。
