<p align="center">
  <img src="assets/app-icon.svg" width="104" height="104" alt="LeetCode AI 助手图标">
</p>

<h1 align="center">LeetCode AI 助手</h1>

<p align="center"><strong>你只管提问、刷题和作答，AI 负责把学习自动整理成下一步。</strong></p>

<p align="center">无需手动记笔记、打标签或排复习表。AI 会持续总结问题、分析每次提交、提取本质知识、更新掌握度并安排复习；你只需要保持真实的学习、提问和练习。</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-292E33?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Electron-43.2-47848F?logo=electron&logoColor=white" alt="Electron 43.2">
  <img src="https://img.shields.io/badge/Node.js-22%2B-3C873A?logo=nodedotjs&logoColor=white" alt="Node.js 22+">
  <img src="https://img.shields.io/badge/version-v1.0.1-2563EB" alt="Version 1.0.1">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0F766E" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#项目介绍">项目介绍</a> ·
  <a href="#产品展示">产品展示</a> ·
  <a href="#核心亮点">核心亮点</a> ·
  <a href="#上下文设计">上下文设计</a> ·
  <a href="#工作原理">工作原理</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="README.en.md">English</a>
</p>

---

| 你只需要做 | AI 在后台自动完成 |
| --- | --- |
| 提问不懂的地方、编写并提交代码、完成复习检测 | 识别学习问题、归并重复知识、分析错因、提取前置知识、记录能力证据、更新掌握度、安排复习、总结主题模板、管理上下文与学习进展 |

<a id="项目介绍"></a>

## 项目介绍

LeetCode AI 助手不是一个自动给答案的聊天外壳，而是一套运行在 macOS 上的个人算法学习系统。它把提问、代码提交、判题结果和复习作答视为连续的学习证据，由 AI 自动完成“发现问题 -> 提取本质知识 -> 更新掌握判断 -> 安排下一次练习”的后续工作。

它主要解决三个长期刷题中最容易被忽略的问题：AI 对话结束后知识随之丢失，同一个错误反复出现却没有形成轨迹，以及复习计划依赖人工维护而难以坚持。这里的目标不是替你完成题目，而是让每一次真实思考都能累积成可追溯、可复习、会随表现变化的能力档案。

项目适合已经使用 AI 辅助学习，但不想继续手工整理聊天记录、错题本、知识标签和复习日历的人。模型和辅助服务可以替换，学习记录与调度逻辑由应用统一管理。

<a id="产品展示"></a>

## 产品展示

### 提交轨迹与 AI 复盘

每次提交都保留独立结论，结合真实判题反馈、代码变化与性能结果解释这一次为什么失败、改变了什么，以及下一步最值得修正的地方。

<p align="center">
  <img src="docs/screenshots/submission-review.png" width="100%" alt="力扣题目、提交轨迹与 AI 复盘界面">
</p>

<table>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/knowledge-map.png" alt="知识图谱"></td>
    <td width="50%" align="center"><img src="docs/screenshots/learning-insights.png" alt="学习洞察"></td>
  </tr>
  <tr>
    <td align="center"><strong>知识图谱</strong><br>把题目归入稳定知识路径，查看主题覆盖、薄弱分支与相关学习项。</td>
    <td align="center"><strong>学习洞察</strong><br>用掌握度、证据量、学习节奏和成长轨迹观察真实进展。</td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/focus-home.png" alt="今日复习与专注入口"></td>
    <td width="50%" align="center"><img src="docs/screenshots/provider-settings.png" alt="模型供应商设置"></td>
  </tr>
  <tr>
    <td align="center"><strong>今日复习</strong><br>从到期项和薄弱项生成当天队列，在练习、反馈与再检测之间循环。</td>
    <td align="center"><strong>模型供应商</strong><br>内置 DeepSeek、阿里云与 OpenCode Go，也支持兼容接口。</td>
  </tr>
</table>

### 从一次做题到长期能力

做题只是输入，后续整理全部自动发生：AI 读取真实判题结果形成提交证据，把暴露出的知识缺口写入学习项，再为相同主题归纳可复用模板。用户不需要在多个页面之间手工搬运内容。

<table>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/practice-workspace.png" alt="力扣题目与代码练习工作区"></td>
    <td width="50%" align="center"><img src="docs/screenshots/submission-evidence.png" alt="提交结果与 AI 分析证据"></td>
  </tr>
  <tr>
    <td align="center"><strong>专注做题</strong><br>题目、编辑器、样例和动态判题集中在同一个工作区，你只负责思考与提交。</td>
    <td align="center"><strong>AI 自动复盘</strong><br>根据通过率、性能、代码和约束生成本次独立结论，并给出可执行改进。</td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/learning-item.png" alt="掌握度、诊断与学习证据详情"></td>
    <td width="50%" align="center"><img src="docs/screenshots/solution-templates.png" alt="AI 自动归纳的主题解题模板"></td>
  </tr>
  <tr>
    <td align="center"><strong>AI 维护学习档案</strong><br>自动整理知识路径、当前诊断、掌握度、证据可信度与下一次复习时间。</td>
    <td align="center"><strong>AI 沉淀通用方法</strong><br>从多道相关题中归纳适用条件、步骤、易错点和可复用代码骨架。</td>
  </tr>
</table>

### 对话、视频与上下文都自动管理

你可以持续围绕同一道题追问，不需要手动整理上下文。应用实时显示上下文占用、可用预算、消息数与自动压缩距离；接近窗口上限时启用滚动摘要压缩，尽量保留当前题目、关键约束和已有结论。视频入口也不是逢对话就出现，只有 AI 识别为力扣题目或确实值得系统学习的知识点时才提供。

<p align="center">
  <img src="docs/screenshots/context-video.png" width="100%" alt="AI 解答、自动视频入口与上下文预算显示">
</p>

### AI 使用透明可见

应用按当前对话和全部历史统计输入、输出、缓存 Token 与工具调用。学习管理可以自动运行，但资源消耗始终可检查，而不是藏在后台。

<p align="center">
  <img src="docs/screenshots/token-usage.png" width="100%" alt="模型 Token 使用统计">
</p>

<a id="核心亮点"></a>

## 核心亮点

- **AI 自动管理完整学习闭环**：你只需自然提问、刷题、提交和参与检测。问题整理、重复项归并、错因总结、知识分类、掌握度更新、复习排序、主题归纳和进度统计都由系统在后台衔接完成，不要求额外维护笔记系统。
- **问题不是被“收藏”，而是被自动沉淀**：系统只增量分析尚未处理的用户消息与新提交，保留整理后的题目快照、来源消息和时间。跨对话再次遇到同一问题时，通过稳定的 `canonicalKey` 归并到原学习项，证据累积而不是生成重复卡片。
- **从题目表象提取本质知识**：AI 将一道具体题拆成算法模式、数据结构、语言机制或常用 API，并补充细粒度标签和必要前置知识。分类来自受控知识路径，避免模型每次自创目录导致知识图谱失控。
- **以证据判断掌握，而不是以“看过”判断掌握**：提问暴露的缺口、反复卡住、独立应用、正确解释、提交结果和检测作答都会形成带置信度的能力信号。掌握分数、证据数和最近状态随新证据更新，后续表现可以推翻旧判断。
- **每次提交都有自己的学习轨迹**：系统按 `submissionId` 读取编译错误、运行错误、失败用例、通过数、源码差异和性能变化，为每次尝试保存独立分析。新方法不会复用旧结论，累计总结也不会被较早的迟到任务倒写覆盖。
- **复习计划由薄弱度和记忆规律共同驱动**：基于 FSRS 调度复习间隔，再结合掌握分数、置信度、逾期程度和薄弱项排序生成今日队列。复习不是固定提醒，而是随着新证据动态重排。
- **复习必须产生新的能力证据**：系统针对当前最小知识缺口生成短讲解和选择、简答、代码补全或编程检测；判分会给出实际优势、缺口与下一步，并把结果重新写回掌握度和下一次复习时间。
- **知识图谱最终沉淀为可复用方法**：学习项按稳定主题聚合，展示覆盖率、掌握分布和关联题目。当同一主题积累足够题目后，系统自动归纳适用条件、操作步骤、常见错误和可编译的通用代码骨架，而不是保存某一道题的答案。
- **上下文由系统维护，不把负担转给用户**：实时展示上下文占比、输入估算、可用预算和压缩阈值，并在长对话中自动生成滚动摘要，保留当前题目与关键结论。用户可以继续追问，无需反复复制题面或自己压缩历史。
- **辅助能力保持克制且可替换**：视频入口只对力扣题目或明确值得独立学习的知识点出现；AI 路由支持 DeepSeek、阿里云、OpenCode Go 与兼容接口；Java 可选接入 Eclipse JDT LS，本地基础能力不依赖远程服务。

<a id="工作原理"></a>

## 工作原理

用户只产生真实学习行为，应用围绕这些“证据”自动组织后续工作，而不是围绕聊天次数堆积内容。原始提问与判题结果负责说明发生了什么，AI 负责结构化、归因和总结，调度器负责决定接下来学什么。

```mermaid
flowchart TD
  A[用户：提问 / 做题 / 作答] --> B[AI：增量证据识别]
  B --> C[题目快照与来源锚点]
  B --> D[本质知识与前置知识]
  C --> E[跨对话归并同一学习项]
  D --> E
  E --> F[AI 更新掌握度 / 置信度 / 证据历史]
  F --> G[AI 结合 FSRS 与薄弱度安排复习]
  G --> H[AI 生成最小讲解与针对性检测]
  H --> I[AI 总结评分 / 错因 / 下一步]
  I --> F
  E --> J[知识图谱与主题解题模板]
```

这条链路遵守三个原则：模型回答本身不算学习证据；看过题解不等于掌握；历史尝试只追加、不覆盖，因此任何掌握判断都能追溯到具体提问、提交或检测结果。

<a id="上下文设计"></a>

## 上下文设计

多数 AI 学习工具只保留最近若干条消息，或者等模型报错后直接截断。这个项目把上下文当作一个可观察、可压缩、有保留优先级的预算系统：用户持续追问，应用负责在模型窗口内维持题目、约束和推理连续性。

| 常见做法 | 本项目的处理 |
| --- | --- |
| 固定保留最近 N 条消息 | 按 Token 预算保留内容，不让一条长代码或长题面挤乱窗口 |
| 到达上限后直接删除前文 | 固定保留系统指令与原始题目，注入滚动摘要，再装入尽可能完整的近期消息 |
| 每次重新总结整段历史 | 保存摘要游标，只处理上次摘要之后的增量内容，避免反复消耗相同上下文 |
| 压缩发生时才开始等待 | 占用达到约 80% 时后台预热摘要，默认 95% 触发压缩，压缩后目标约 82% |
| 用户看不到窗口为何变短 | 实时显示输入估算、可用预算、距压缩 Token、消息数与图片数；供应商返回用量时展示精确统计 |
| 图片无约束进入对话 | 仅接受 HTTPS 图片，去重并限制数量；只有支持视觉的模型才附带图片，单次请求最多 4 张 |

Token 估算针对中文、英文、代码和标点采用不同权重，并缓存单条消息的估算结果，避免长对话中的界面计算反复抖动。压缩失败时不会丢弃正在学习的内容，而是继续保留近期上下文并在下一次尝试恢复。阿里云兼容接口还会在足够长的稳定前缀上标记临时缓存，短提示则交给供应商默认策略。

默认窗口为 128K Token，并为输出预留 8K；这些参数、近期消息数量与图片预算都可以在设置中调整。界面里的实时占用是保守估算，供应商响应中返回的 Token 用量才作为精确账单统计。

## 安全设计

- 仓库不包含 API Key、账号 Cookie、SSH 私钥或服务器地址。
- AI 供应商密钥在应用设置中填写，写入本机前通过 Electron `safeStorage` 加密；旧版明文配置会在启动后自动迁移。
- 为生成回答、摘要与提交分析，题目、提问和相关代码会发送给你选择的 AI 供应商；请按对应供应商的隐私政策选择模型与账号。
- 对话、学习项和提交分析保存在本机应用数据目录的 JSON 文件中，目前不做静态加密。请保护本机账号和磁盘，并在分享日志或备份前检查内容。
- 力扣和哔哩哔哩登录状态保存在 Electron 的隔离会话中，不写入仓库。
- 远程 Java 补全默认关闭，必须通过本地环境变量显式启用。
- `.env.local`、构建产物、依赖目录和私钥文件均已加入 `.gitignore`。

更多说明见 [SECURITY.md](SECURITY.md)。

<a id="快速开始"></a>

## 快速开始

### 直接下载安装

从 [GitHub Releases](https://github.com/huaxx-lab/leetcode-ai-helper/releases/latest) 下载 Apple Silicon 版本：

- `LeetCode-AI-Helper-mac-arm64.dmg`：打开后将应用拖入“应用程序”；
- `LeetCode-AI-Helper-mac-arm64.zip`：解压后手动移动到“应用程序”。

当前公开构建使用 ad-hoc 本地签名，尚未经过 Apple Developer ID 公证。首次启动时请在 Finder 中右键应用并选择“打开”。如果 macOS 仍提示应用已损坏，请确认安装包来自本仓库后执行：

```bash
xattr -dr com.apple.quarantine "/Applications/LeetCode 助手.app"
```

### 环境要求

当前构建和安装流程针对 Apple Silicon macOS：

- macOS 13 或更高版本；
- Node.js 22 和 npm；
- Xcode Command Line Tools；
- Python 3，供 `node-gyp` 编译原生模块；
- 一个受支持 AI 供应商的 API Key。

安装命令行工具：

```bash
xcode-select --install
```

建议通过 `nvm`、`fnm` 或 Homebrew 安装 Node.js 22。项目依赖 Electron 原生模块，不建议跳过安装脚本。

### 安装并运行

```bash
git clone https://github.com/huaxx-lab/leetcode-ai-helper.git
cd leetcode-ai-helper
npm install
npm start
```

macOS 若阻止本地 Electron 二进制运行，可以使用项目启动脚本，它会清理隔离属性并进行本地临时签名：

```bash
chmod +x start.sh
./start.sh
```

### 首次配置

1. 打开设置，选择 DeepSeek、阿里云、OpenCode Go 或添加自定义供应商。
2. 填写 API Base URL、API Key 和模型，刷新模型列表并保存。
3. 打开“学习活动 > 力扣”，登录力扣中国站。
4. 导入题单或同步提交记录，即可进入题目工作区运行、提交和查看 AI 分析。

应用数据保存在：

```text
~/Library/Application Support/leetcode-ai-helper/
```

删除仓库或重新构建不会删除这部分数据。提交问题日志前，请移除账号、代码、题目历史和任何凭据内容。

<a id="构建项目"></a>

## 构建项目

生成 Apple Silicon `.app`、签名后的 zip 和可拖拽安装的 DMG：

```bash
npm run package:mac
```

产物位于：

```text
dist.noindex/mac-arm64/LeetCode 助手.app
dist.noindex/LeetCode-AI-Helper-mac-arm64.zip
dist.noindex/LeetCode-AI-Helper-mac-arm64.dmg
```

直接替换安装到 `/Applications`：

```bash
npm run install:mac
```

默认使用 ad-hoc 本地签名。若本机钥匙串中有有效的 Developer ID Application 证书，可指定：

```bash
MAC_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" npm run package:mac
```

## 可选：远程 Java 补全

不配置远程服务时，应用仍可使用本地语法检查和基础补全。远程服务通过 SSH 本地端口转发访问，服务端 HTTP 网关只监听 `127.0.0.1`。

### 1. 部署服务端

准备一台 Debian/Ubuntu 服务器，将目录上传后执行安装脚本：

```bash
scp -r scripts/remote-lsp ubuntu@example.com:/tmp/leetcode-lsp
ssh ubuntu@example.com
cd /tmp/leetcode-lsp
sudo bash install.sh
```

脚本会安装 Java 21、Eclipse JDT LS 和 systemd 服务。检查状态：

```bash
sudo systemctl status leetcode-lsp
curl http://127.0.0.1:9092/health
```

不要在防火墙中公开 9092 端口；客户端通过 SSH 隧道访问它。

### 2. 配置客户端

```bash
cp .env.example .env.local
```

编辑 `.env.local`：

```dotenv
LEETCODE_LSP_SSH_HOST=example.com
LEETCODE_LSP_SSH_USER=ubuntu
LEETCODE_LSP_SSH_PORT=22
LEETCODE_LSP_TARGET_PORT=9092
LEETCODE_LSP_SSH_IDENTITY_FILE=/absolute/path/to/ssh_private_key
```

确保 SSH 密钥权限正确，并可在无交互模式下连接：

```bash
chmod 600 /absolute/path/to/ssh_private_key
ssh -o BatchMode=yes ubuntu@example.com true
./start.sh
```

`.env.local` 不会被 Git 跟踪。不要把私钥内容放进环境文件。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `npm start` | 准备前端依赖并启动开发应用 |
| `./start.sh` | 加载 `.env.local`、本地签名 Electron 后启动 |
| `npm run rebuild:native` | 为当前 Electron 版本重编译 macOS 原生模块 |
| `npm run package:mac` | 构建 `.app` 和 zip |
| `npm run install:mac` | 构建并安装到 `/Applications` |

## 项目结构

```text
src/main/                   Electron 生命周期、IPC 与安全的 preload 桥接
src/renderer/               桌面界面、交互状态和视觉样式
src/core/                   学习引擎、知识归并、代码检查与内容处理
src/integrations/           力扣、视频、模型供应商与流式协议适配
src/platform/               macOS 窗口布局、显示器配置与媒体缓存
assets/                     应用图标与供应商图标
native/                     macOS 原生 Liquid Glass 与窗口能力
scripts/                    构建、签名、安装及可选远程 LSP 脚本
test/                       无账号数据的回归与安全测试
docs/screenshots/           README 使用的真实产品截图
```

## 参与开发

提交前请阅读 [贡献指南](CONTRIBUTING.md) 并运行项目回归测试。不要提交真实 API Key、Cookie、服务器地址、私钥、应用数据或构建产物。许可证为 [MIT](LICENSE)。

> LeetCode 是其权利人的商标。本项目为独立开源工具，与 LeetCode 官方无隶属或背书关系。
