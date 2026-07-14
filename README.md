# VibeUsage

VibeUsage 是一款 macOS 菜单栏应用，用来汇总本机 AI 编程助手的 Token 用量、估算费用和订阅额度。打开菜单栏就能查看今天花了多少、哪些 Agent 和模型用得最多，以及最近一段时间的使用趋势。

本地用量统计直接读取各个 Agent 已保存在 Mac 上的会话记录，不需要上传原始日志，也不需要为每个 Agent 配置 API Key。

> [下载最新稳定版](https://github.com/tyuan511/vibe-usage/releases/latest) · 需要 macOS 26 或更高版本

<img src="docs/usage-share-preview.png" alt="VibeUsage 菜单栏用量面板" width="360">

## 可以做什么

- **随时查看今日用量**：菜单栏图标旁以两行显示今日估算费用和 Token，也可以在设置中只保留图标。
- **按时间查看统计**：支持今天、昨天、近 7 天、近 30 天、近 90 天、本周和本月。
- **了解使用构成**：显示总费用、总 Token、缓存读取比例，并按 Agent、模型和同步设备拆分。
- **观察长期活跃度**：24 周活跃热力图直观展示每天的使用强度，悬停可查看当天 Token 和费用。
- **筛选关注的数据**：可以只看某个模型，也可以在设置中隐藏不想计入统计的 Agent 或远端设备。
- **监控订阅额度**：可选连接 Claude 和 Codex/ChatGPT 账号，查看订阅类型、各额度窗口的使用比例和重置倒计时。
- **导出用量图片**：将当前面板保存为 PNG、拷贝到剪贴板，或通过 macOS 分享菜单发送。
- **在多台 Mac 间汇总**：使用自己的 WebDAV 或 S3 兼容存储同步小时聚合数据，并按设备查看或隐藏用量。
- **自动保持数据新鲜**：Agent 产生新日志后自动刷新，同时定期补扫；模型价格和应用版本也支持自动及手动更新。
- **跟随系统语言**：根据 macOS 首选语言显示中文或英文界面。

## 支持的 AI 编程助手

VibeUsage 当前可以读取以下 14 种工具的本地用量：

| Agent | 默认数据位置 | 自定义位置环境变量 |
|---|---|---|
| Claude Code | `~/.config/claude`、`~/.claude` | `CLAUDE_CONFIG_DIR` |
| Codex CLI | `~/.codex` | `CODEX_HOME` |
| OpenCode | `~/.local/share/opencode` | `OPENCODE_DATA_DIR` |
| Amp | `~/.local/share/amp` | `AMP_DATA_DIR` |
| Droid | `~/.factory/sessions` | `DROID_SESSIONS_DIR` |
| Hermes Agent | `~/.hermes` | `HERMES_HOME` |
| pi-agent | `~/.pi/agent/sessions` | `PI_AGENT_DIR` |
| Goose | `~/.local/share/goose/sessions`、`~/Library/Application Support/goose/sessions`、`~/.local/share/Block/goose/sessions` | `GOOSE_PATH_ROOT` |
| OpenClaw | `~/.openclaw`、`~/.clawdbot`、`~/.moltbot`、`~/.moldbot` | `OPENCLAW_DIR` |
| Kilo | `~/.local/share/kilo` | `KILO_DATA_DIR` |
| Kimi | `~/.kimi` | `KIMI_DATA_DIR` |
| Qwen | `~/.qwen/projects` | `QWEN_DATA_DIR` |
| GitHub Copilot CLI | `~/.copilot/otel` | `COPILOT_OTEL_FILE_EXPORTER_PATH` |
| Gemini CLI | `~/.gemini/tmp` | `GEMINI_DATA_DIR` |

只要相应目录存在，VibeUsage 就会自动发现该 Agent。环境变量支持用逗号分隔多个位置；修改后请退出并重新打开 VibeUsage。

## 安装

1. 打开 [Releases](https://github.com/tyuan511/vibe-usage/releases/latest)，下载最新的 `VibeUsage-版本号.dmg`。
2. 打开 DMG，将 `VibeUsage.app` 拖到“应用程序”。
3. 启动 VibeUsage。它不会显示在 Dock 中，启动后请在菜单栏寻找柱状图图标。

当前发布包没有经过 Apple notarization。如果 macOS 提示“VibeUsage 已损坏，无法打开”或要求移到废纸篓，请确认应用已经放入“应用程序”目录，然后执行：

```bash
sudo xattr -dr com.apple.quarantine /Applications/VibeUsage.app
```

重新打开应用即可。如果安装在其他目录，请把命令中的路径替换为实际路径。

### 从当前源码运行

如果更喜欢直接从源码运行，安装 Swift 6.2 和 macOS 26 SDK 后，可以执行：

```bash
git clone https://github.com/tyuan511/vibe-usage.git
cd vibe-usage
Scripts/build-app.sh release
open .build/VibeUsage.app
```

## 快速开始

1. 先在任意受支持的 Agent 中完成至少一次对话，让它生成本地会话记录。
2. 启动 VibeUsage。首次运行会扫描已有记录，并尝试注册为登录启动项。
3. 点击菜单栏图标查看今日总费用、Token、限额、活跃热力图、Agent 和模型明细。
4. 使用顶部的时间菜单切换统计范围；使用“模型”右侧的菜单只查看某个模型。
5. 点击刷新按钮可以立即重新扫描；后续日志变化也会自动触发刷新。

费用统一以美元显示。日志中已有费用时优先使用原值，否则根据当前模型价格估算；带“估算”标记的结果可能与服务商最终账单不同。

## 功能使用指南

### 调整统计范围

点击面板顶部的时间菜单，可以在以下范围之间切换：

- 今天、昨天
- 近 7 天、近 30 天、近 90 天
- 本周、本月

选择模型后，总费用、Token、活跃热力图、Agent、设备和模型明细都会使用同一筛选条件。选择“全部模型”即可恢复完整统计。

### 选择要统计的 Agent

打开齿轮图标进入“设置 > 数据来源”。这里仅列出 VibeUsage 已经发现过的 Agent：

- 取消勾选后，该 Agent 不再计入菜单栏数字和面板中的所有本地统计。
- 再次勾选即可恢复，原始日志和本地缓存不会被删除。
- 新发现的 Agent 默认加入统计。

### 查看 Claude 和 Codex 订阅额度

额度监控与本地 Token 统计互相独立。它是可选的，可以在“设置 > 订阅额度”中整体关闭，也可以分别隐藏 Claude 或 Codex。

连接方式：

- **Claude**：先确保这台 Mac 上的 Claude Code 已经登录，再在面板中点击“连接 Claude 账号”。VibeUsage 只读复用 Claude Code 的本机凭据，不会改写 Claude Code 的凭据存储。
- **Codex / ChatGPT**：点击“连接 Codex 账号”，在浏览器中完成 OAuth 授权；授权完成后会自动回到应用。

连接后可看到订阅类型、各额度窗口已使用百分比和重置倒计时。点击账号旁的断开按钮会清除 VibeUsage 保存的连接信息。额度数据大约每 5 分钟刷新一次。

### 导出或分享面板

点击面板顶部的分享按钮，可以：

- 保存为 PNG 图片；
- 拷贝图片到剪贴板；
- 使用 macOS 系统分享菜单发送图片。

导出的内容与当前面板一致，会保留已选择的时间、模型、Agent 和设备筛选。没有用量数据时导出按钮不可用。

### 在多台 Mac 间同步

同步使用你自己的 HTTPS WebDAV 或 S3 兼容对象存储，默认关闭。每台 Mac 都需要使用同一同步目标。

1. 打开“设置 > 多端同步”，先修改当前设备名称，方便之后识别。
2. 点击“配置”，选择 WebDAV 或 S3。
3. 填写连接信息后点击“测试并保存”。VibeUsage 只接受 HTTPS 地址。
4. 打开“启用同步”。
5. 在其他 Mac 上重复以上步骤，并连接到同一个目录、Bucket 和前缀。

启用后，VibeUsage 会在启动时、手动刷新后及每 15 分钟同步一次。面板会增加“设备”明细；在设置中可以隐藏远端设备、删除某台设备的远端历史，或手动点击“立即同步”。本机设备始终包含在总数中。

同步内容只包括设备名、UTC 小时、Agent、模型、Token、费用、事件数和是否为估算费用，不包含原始日志、文件路径、项目名、会话、请求 ID 或账号令牌。

“移除配置与缓存”只清理当前 Mac 上的同步配置、凭据和远端缓存，不会删除服务器文件。切换同步目标也不会自动迁移旧目标中的数据。

### 登录启动与菜单栏显示

在“设置 > 通用”中可以：

- 开启或关闭“登录时启动”；
- 开启或关闭菜单栏中的今日费用和 Token，关闭后只显示图标。

首次运行会尝试自动启用登录启动。如果系统要求批准，设置页会提供“打开系统设置”按钮。

### 更新模型价格和应用

打开“设置 > 更新”可以：

- 查看当前 VibeUsage 版本并手动检查更新；
- 查看模型价格更新时间并立即更新价格。

模型价格更新成功后，VibeUsage 会重新计算此前由价格表估算的费用。应用也会自动检查新版本，并在发现更新时在面板底部显示提示；安装更新时可能需要 macOS 授权写入“应用程序”目录。

## 隐私与网络行为

VibeUsage 是本机优先应用，但模型价格和应用更新会使用网络。各项行为如下：

| 功能 | 何时联网 | 发送或读取的内容 |
|---|---|---|
| 本地用量统计 | 不联网 | 只在本机读取 Agent 日志并生成统计 |
| 多端同步 | 配置并启用后 | 与你自己的 WebDAV/S3 交换不含日志和会话信息的小时聚合数据 |
| Claude/Codex 额度 | 启用监控并连接账号后 | 使用账号令牌读取官方额度接口；不写入用量数据库 |
| 模型价格 | 本地价格不存在或超过 24 小时时，也可手动触发 | 从本项目仓库下载价格快照 |
| 应用更新 | 启动后及之后定期检查，也可手动触发 | 从 GitHub Releases 读取更新信息和安装包 |

本地数据默认保存在：

```text
~/Library/Application Support/VibeUsage/usage.sqlite
~/Library/Application Support/VibeUsage/model_prices.json
```

`usage.sqlite` 是从 Agent 日志生成的本地缓存和同步聚合缓存；`model_prices.json` 是最近下载的价格快照。WebDAV 密码、S3 Secret Key 和 VibeUsage 自己持有的账号令牌保存在 macOS Keychain。

## 常见问题

### 面板没有显示某个 Agent 的数据

依次检查：

1. 该 Agent 是否已经产生过包含 Token 用量的本地会话记录；
2. 日志是否位于上表中的默认目录，或是否已经通过对应环境变量指定自定义目录；
3. “设置 > 数据来源”中是否勾选了该 Agent；
4. 当前时间范围和模型筛选是否包含这部分数据；
5. 点击面板右上角的刷新按钮重新扫描。

### 为什么费用和官方账单不同

VibeUsage 是本地使用视图，不是官方账单。差异可能来自日志缺少模型或费用、价格快照与服务商实时价格不同、订阅内含额度，以及不同 Agent 对缓存或 reasoning Token 的记录方式不同。

### 会上传我的聊天记录或代码吗

不会。VibeUsage 的本地统计只读取日志，不上传日志内容。即使启用多端同步，也只同步按小时聚合的用量数字，不包含提示词、回复、代码、项目路径或会话标识。

## 参与项目

如果你想报告问题、改进适配器或贡献新的 Agent 支持，请查看 [CONTRIBUTING.md](CONTRIBUTING.md)。

VibeUsage 的本地用量统计思路参考了 [ccusage](https://github.com/ccusage/ccusage)，并针对 macOS 菜单栏、后台增量扫描、额度监控和多设备使用场景进行了设计。

项目使用 [MIT License](LICENSE)。
