# VibeUsage

VibeUsage 是一个 macOS 菜单栏应用，用来从本机各种 AI 编程助手的日志中统计 Token 用量和估算成本。它会扫描本地会话文件，归一化不同工具的用量字段，写入本机 SQLite 缓存，并在菜单栏状态项中显示今日金额和 Token。展开下拉后，可以按今天、昨天、近 7/30/90 天、本周或本月查看总金额、Token、活动热力图、Agent 和模型拆分。

项目的目标不是替代官方账单，而是给日常使用 AI coding agent 的人一个轻量、本机优先的视图：默认情况下，本地日志、解析结果和聚合数据不会上传。用户也可以主动配置自己的 WebDAV 或 S3 兼容存储，在多台 Mac 间同步不含日志、路径、项目和会话的小时聚合数据。订阅额度监控是可选功能，由用户在应用内主动连接账号后才访问额度接口——Codex 走独立 OAuth 授权、令牌由 VibeUsage 自己持有，Claude 则只读复用 Claude Code 本机已登录的令牌（Anthropic 已从服务端禁止第三方自建 Claude OAuth）。额度监控可以随时断开或在设置中完全关闭。应用还会联网获取每日模型价格快照，并通过 Sparkle 检查应用更新；具体行为见下方“网络行为”。

菜单栏下拉顶部可以把当前界面一键导出为图片（保存图片 / 拷贝图片 / 系统分享）：

<img src="docs/usage-share-preview.png" alt="VibeUsage 菜单栏下拉分享预览" width="360">

## 功能

- 菜单栏状态项在图标右侧分两行显示今日用量（上方金额、下方 Token），也可以在设置中只保留图标。
- 菜单栏下拉集中展示金额、Token、缓存读取比例、活动热力图、Agent 和模型明细，并支持模型筛选。
- 支持今天、昨天、近 7 天、近 30 天、近 90 天、本周和本月等时间范围。
- Agent 显示范围由一处设置统一控制，同时影响菜单栏状态项和下拉中的所有本地用量统计；新发现的 Agent 默认加入。
- 订阅额度监控（可选）：Claude 只读导入 Claude Code 本机凭据，Codex/ChatGPT 使用浏览器 OAuth；显示会话/周期额度、订阅类型和重置倒计时，可按来源隐藏、断开或整体关闭。
- 菜单栏下拉顶部可保存图片、拷贝图片或通过系统分享当前下拉界面的真实截图。
- 原生设置窗口按“通用 / 数据来源 / 更新”组织登录启动、菜单栏显示、Agent 范围、额度监控、应用更新和模型价格。
- 首次运行会尝试注册登录启动项，之后可在设置中随时开启或关闭；需要系统批准时会提供系统设置入口。
- 将不同来源统一为 `UsageEvent`，包含输入、输出、缓存写入、缓存读取、reasoning token、模型、会话、项目和成本。
- 使用 GRDB + SQLite 做本地缓存，保存增量解析 checkpoint，避免每次全量重扫。
- 可选多端同步：直接连接用户自己的 HTTPS WebDAV 或通用 S3 兼容存储，按设备查看聚合 Token 和金额。
- 内置模型价格快照，并每日获取仓库维护的最新快照；支持手动更新，成功后立即重算此前的估算费用。
- 使用 Sparkle 2 检查、验证并在应用内安装更新，更新包与 feed 均使用 EdDSA 签名。
- 自动刷新：FSEvents 监听 agent 日志目录，并在 5 分钟周期内做兜底 rescan。
- 适配器架构清晰，新增来源时只需要实现 `UsageSourceAdapter` 并注册。

## 支持的数据源

当前内置适配器覆盖：

- Claude Code
- Codex CLI
- OpenCode
- Amp
- Droid
- Hermes Agent
- pi-agent
- Goose
- OpenClaw
- Kilo
- Kimi
- Qwen
- GitHub Copilot CLI
- Gemini CLI

不同工具的日志格式差异很大。VibeUsage 为每个来源提供独立适配器，按各自日志结构解析 timestamp、model、session、request、usage 和 cost，避免跨 agent 猜测字段。

## 与 ccusage 的关系

VibeUsage 的用量统计思路参考了 [ccusage/ccusage](https://github.com/ccusage/ccusage) 的实现，参考版本为 `cdda1821cf8a130c4d92cfd5aec101dfba96e1c9`。本项目没有复制或 vendoring ccusage 源码，而是将其中成熟的数据处理逻辑改写成 Swift/macOS 应用形态。

主要参考点包括：

- 从本机 agent CLI 日志读取用量，而不是依赖远端账单 API。
- 为不同 agent 建立独立 adapter：负责发现文件、解析日志、提取会话/项目/模型信息。
- 将来源差异归一化为统一 token 结构：input、output、cache creation、cache read，以及 Codex 的 reasoning token。
- 处理 Claude Code 的 `costUSD`：日志自带成本时优先使用，否则按模型价格估算。
- 处理 Codex token_count：支持 `last_token_usage`，也支持从累计 `total_token_usage` 中计算增量。
- 做模型 family 归一化，例如去掉 Claude 模型名末尾的日期后缀，再用归一化后的 key 查价格。
- 按去重 key 做幂等写入；冲突时优先保留非 sidechain replay，或保留 token 总量更大的记录。
- 使用 LiteLLM 社区价格数据作为价格表来源，并将快照打包进应用。

ccusage 是 CLI 报表工具，擅长直接生成 daily、weekly、monthly、session、blocks 等终端报表；VibeUsage 则把类似的解析和聚合逻辑放到本机常驻的菜单栏应用里，重点是后台增量扫描、本机缓存和随手查看。

## 架构

代码按 SwiftPM target 拆分：

- `VibeUsageCore`：核心模型、协议、adapter registry、价格协议。
- `VibeUsagePricing`：内置与下载价格快照、模型别名解析、价格查询和运行时价格更新。
- `VibeUsageStorage`：SQLite schema、GRDB 存储、去重和聚合查询。
- `VibeUsageSync`：设备聚合分片、同步状态机、Keychain 凭据，以及 WebDAV/S3 对象存储适配器。
- `VibeUsageWatching`：扫描所有 adapter，按文件 checkpoint 增量解析。
- `VibeUsageAggregation`：把存储层数据聚合成 UI 使用的 snapshot。
- `VibeUsageAdapter`：Claude Code、Codex CLI，以及其他 agent 的独立适配器实现。
- `VibeUsageQuota`：订阅额度监控子系统，独立于上面的本地用量统计管线（不依赖 GRDB/Storage）：驱动 OAuth 授权/刷新流程、把 VibeUsage 自己的访问令牌存进独立的钥匙串项、调用官方额度接口、解析成 UI 用的 quota snapshot。
- `VibeUsageUI`：SwiftUI 菜单栏、设置窗口与下拉截图导出。
- `VibeUsageApp`：应用入口、依赖装配、登录启动、价格刷新调度和 Sparkle 应用内更新。

数据流（本地用量统计）：

```text
Agent logs
  -> UsageSourceAdapter
  -> UsageIngestor
  -> GRDBUsageEventStore
  -> UsageAggregationService
  -> SwiftUI menu bar
```

启用多端同步后的附加数据流：

```text
Local UsageEvent -> UTC hourly/day shards -> WebDAV or S3
WebDAV or S3 -> verified remote shards -> local aggregate cache -> SwiftUI
```

数据流（订阅额度监控，完全独立的实时子系统）：

```text
用户在应用内点击"连接"
  -> QuotaConnectionManager（OAuth 授权/刷新，VibeUsage 自己的钥匙串）
  -> ClaudeQuotaProvider / CodexQuotaProvider
  -> QuotaService
  -> SwiftUI menu bar
```

## 本地数据位置

VibeUsage 默认会把本地缓存写到：

```text
~/Library/Application Support/VibeUsage/usage.sqlite
~/Library/Application Support/VibeUsage/model_prices.json
```

`usage.sqlite` 保存本地解析结果、增量 checkpoint、设备身份和可选的远端聚合缓存；`model_prices.json` 是最近一次成功下载的价格快照。下载快照不存在或不可用时，应用回退到随应用打包的内置价格。WebDAV 密码或 S3 Secret Key 只保存在 macOS Keychain。

各 agent 的源日志仍保留在它们自己的默认目录中。部分适配器支持环境变量覆盖：

| 环境变量 | 默认路径 / 说明 |
|----------|-----------------|
| `CLAUDE_CONFIG_DIR` | Claude Code 配置目录 |
| `CODEX_HOME` | Codex CLI 数据目录 |
| `OPENCODE_DATA_DIR` | OpenCode 数据目录 |
| `AMP_DATA_DIR` | Amp 数据目录 |
| `GEMINI_DATA_DIR` | Gemini CLI 数据目录 |
| `KIMI_DATA_DIR` | Kimi 数据目录 |
| `QWEN_DATA_DIR` | Qwen 数据目录 |
| `KILO_DATA_DIR` | Kilo 数据目录 |
| `HERMES_HOME` | Hermes Agent 目录 |

## 网络行为

- **本地用量统计**：默认只在本机扫描 Agent 日志、写入 SQLite、聚合和导出图片，不上传日志或统计数据。
- **多端同步（可选）**：只有用户配置自己的 HTTPS WebDAV/S3 目标、通过读写测试并启用后才联网；上传内容仅包含设备名、UTC 小时、Agent、模型、Token、金额和事件数，不包含日志、路径、项目、会话、请求 ID 或 OAuth 凭据。同步默认关闭。
- **订阅额度**：只有启用额度监控并连接相应账号后，才会访问 Claude 或 Codex/ChatGPT 的官方额度接口；关闭监控后不会读取额度钥匙串，也不会发送额度请求。
- **模型价格**：没有下载快照或快照超过 24 小时时，应用会从本仓库的 GitHub Raw 地址获取价格；失败尝试同样按 24 小时节流。也可以在“设置 > 更新”中手动触发。
- **应用更新**：Sparkle 在启动时及之后每小时读取 GitHub Release 的更新 feed，也可以从菜单栏下拉或设置中手动检查。

## 自动刷新

应用启动后会：

1. 立即执行一次 ingest scan。
2. 通过 FSEvents 监听已发现 adapter 的日志根目录；目录变化会在约 2 秒 debounce 后触发 rescan。
3. 每 5 分钟执行一次兜底 rescan，防止漏掉文件系统事件。

如果 FSEvents 初始化失败，应用会记录日志并继续依赖定时 rescan。

## 额度监控数据来源

订阅额度监控是一个独立于本地用量统计的实时子系统（不写入 SQLite）。两家来源的连接机制不同，原因是 Anthropic 自 2026-01 起在服务端强制"消费级订阅的 OAuth token 只能由 Claude Code / Claude.ai 使用"，第三方应用无法自己走 OAuth 签发 Claude token（会 403）——所以 Claude 只能像 CodexBar 一样复用 Claude Code 已签发的 token，而 Codex/ChatGPT 不受此限制、仍可自建 OAuth：

| 来源 | 连接方式 | 令牌来源 | 额度接口 |
|------|----------|----------|----------|
| Claude | 点击"连接 Claude 账号"，复用 Claude Code 本机已登录的 token（只读，过期时用其 refreshToken 刷新，从不写回 Claude Code 的存储） | 读取钥匙串条目 `Claude Code-credentials`，回退 `~/.claude/.credentials.json` | `GET https://api.anthropic.com/api/oauth/usage` |
| Codex / ChatGPT | 点击"连接 Codex 账号"，浏览器 OAuth 授权、本地回调（`localhost:1455`）自动完成 | VibeUsage 自建并持有的令牌，存于专属钥匙串条目 `VibeUsage-connected-accounts` | `GET https://chatgpt.com/backend-api/wham/usage` |

Claude 侧需要本机已安装并登录 Claude Code（否则连接时提示"未检测到 Claude Code 登录"）；Codex 侧复用的是 Codex CLI 官方客户端公开的 OAuth client id（OpenAI 未开放第三方独立注册），但授权同意与令牌签发/刷新都是 VibeUsage 自己发起和持有的。未连接时显示"未连接"和"连接"按钮；令牌失效时提示"登录已过期，请重新连接"；随时可断开清除本地令牌。可以在设置里关闭"监控订阅额度（联网）"，完全禁用这部分网络请求。

## macOS 提示应用已损坏

如果从 GitHub Release 下载 DMG 后，macOS 提示“VibeUsage 已损坏，无法打开”或要求移到废纸篓，通常是因为当前 release 使用 ad-hoc 签名，没有经过 Apple notarization，系统给下载的 `.app` 加上了 quarantine 标记。

把应用拖到“应用程序”目录后，可以在终端执行：

```bash
sudo xattr -dr com.apple.quarantine /Applications/VibeUsage.app
```

然后重新打开 VibeUsage。如果你放在其他目录，把命令中的 `/Applications/VibeUsage.app` 替换为实际路径即可。

## 开发

要求：

- Swift 6.2
- macOS 26 SDK

运行测试：

```bash
swift test
# 或
make test
```

重新编译并重启本地应用：

```bash
Scripts/rebuild-and-restart.sh
# 或
make restart
```

生成下拉分享预览图：

```bash
Scripts/regenerate-preview.sh
# 或
make preview
```

构建可执行文件：

```bash
swift build
```

打包成本机 `.app`：

```bash
Scripts/build-app.sh release
open .build/VibeUsage.app
```

未显式传入 `VERSION` 时，本地构建会使用当前提交可达的最新 `v*` Git tag；发布工作流仍会显式注入 tag 版本。

打包 DMG：

```bash
VERSION=0.1.0 BUILD_NUMBER=1 Scripts/package-dmg.sh release
open .build/VibeUsage-0.1.0.dmg
```

更新模型价格快照：

```bash
python3 Scripts/update-pricing.py
```

价格快照会写入 `Sources/VibeUsagePricing/Resources/model_prices.json`，并在构建时随应用一起打包。GitHub Actions 每日从 LiteLLM 刷新该表并直接提交变更，覆盖 GPT、Claude、Grok、Gemini、DeepSeek、GLM、Kimi、MiniMax 等常见模型族。

应用默认使用内置快照。首次安装或本地快照超过 24 小时时，应用会静默从本仓库的 GitHub Raw 快照更新价格表；失败会保留当前快照，并在一天后再试。在“设置 > 更新”中也可手动更新，成功后会立即重算此前的估算费用。

更多贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 发布

仓库包含 GitHub Actions workflow：

- `CI`：在 push / pull request 时运行 `swift test`；`main` 分支 push 后会尝试自动更新下拉分享预览图。
- `Update model pricing`：每天从 LiteLLM 刷新模型价格快照并直接提交变更。
- `Release`：推送 `v*` tag 后构建 DMG 并创建 GitHub Release。

```bash
git tag v0.1.0
git push origin v0.1.0
```

发布产物包含：

```text
VibeUsage-0.1.0.dmg
appcast.xml
```

workflow 会把 tag 中的版本号写入 `CFBundleShortVersionString`，把 GitHub Actions run number 写入 `CFBundleVersion`，并使用 `SPARKLE_PRIVATE_KEY` secret 对 DMG 和 appcast 进行 EdDSA 签名。当前脚本默认使用 ad-hoc codesign，下载后 macOS 可能提示开发者身份未验证；如果要正式分发，可以在 CI 中配置 `SIGN_IDENTITY` 仓库 secret，或在本地执行：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh release
```

## 应用内更新

VibeUsage 使用 Sparkle 2 从以下稳定地址读取更新 feed：

```text
https://github.com/tyuan511/vibe-usage/releases/latest/download/appcast.xml
```

应用启动时会检查一次新版本，之后每小时由 Sparkle 在后台轮询；发现新版本后，菜单栏下拉左下角会显示版本提示。也可以在设置页查看当前版本，或从设置页和下拉底部手动检查更新。Sparkle 会在应用内下载、验证、替换并重启应用；需要写入 `/Applications` 时 macOS 可能要求授权。

项目没有 Apple Developer ID 证书，因此首次从浏览器下载和安装仍可能遇到 Gatekeeper 提示。Sparkle 使用独立的 Ed25519 密钥验证更新包和 feed，不依赖 Apple 开发者证书。`v0.1.8` 及更早版本没有内置 Sparkle，用户需要手动安装首个包含 Sparkle 的版本一次，之后才能使用应用内更新。

## 说明

VibeUsage 的成本结果是基于本地日志和当前价格快照（下载快照或应用内置回退）的估算，可能与服务商最终账单存在差异。日志缺少模型、价格表缺少模型，或不同 Agent 对 Token 字段定义不一致时，应用会尽量保留用量并标记成本为估算。
