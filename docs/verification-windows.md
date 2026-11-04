# Windows 端验收

分两部分：**自动化**（一条命令，覆盖绝大部分逻辑）与**人工**（只包含无法自动化的界面交互）。

## 一、自动化

### 准备

```bat
git clone https://github.com/Metahumanz/AItrans.git
cd AItrans
git checkout main
```

需要 **.NET 10 SDK**（`dotnet --version` 应为 10.x）。

### 运行

```bat
powershell -ExecutionPolicy Bypass -File windows\scripts\verify.ps1
```

加 `-Publish` 会额外执行一次自包含发布，并检查 `AITrans.exe` 是否生成：

```bat
powershell -ExecutionPolicy Bypass -File windows\scripts\verify.ps1 -Publish
```

退出码 `0` 表示全部通过。脚本会依次执行：

1. 检查 SDK 版本；
2. `dotnet test`（全部单元测试）；
3. `dotnet build`（WinUI 客户端能否编译）；
4. 可选：`dotnet publish` 并校验产物。

### 覆盖了哪些验收项

| 原清单项目 | 对应测试 | 说明 |
| --- | --- | --- |
| 编码：UTF-8 / BOM / UTF-16 / GBK | `FixtureTests.DecodingMatchesLegacy` | 与 macOS 读同一批 `fixtures/srt` |
| 解析：多行、畸形块、CRLF | `FixtureTests.BlocksMatchLegacy` | 逐块比对原文与结构 |
| 组装：译文在上、原文在下 | `FixtureTests.AssembleTranslateMatchesLegacy` | 与 v1 输出逐字一致 |
| 润色后的组装 | `FixtureTests.AssemblePolishMatchesLegacy` | 含多行条目 |
| 引号剥离 | `FixtureTests.StripQuotesHandlesBothQuoteStyles` | 中英文引号 |
| 翻译 → 润色全链路 | `TranslatorTests.TranslateThenPolishMatchesLegacy` | 假模型驱动 |
| 失败回退原文 | `TranslatorTests.FailureKeepsOriginal` | 单条失败不影响整体 |
| 批量结果三种格式 | `TranslatorTests.Parses*` | `[n]` / `n.` / 纯行 |
| 源目录 / 输出目录 / 自定义目录 | `OutputPathsTests` + `JobRunnerTests` | 路径规则与落盘 |
| 后缀非法字符 | `OutputPathsTests.Rejects*` | 含控制字符 |
| 同名输出冲突 | `OutputPathsTests.DetectsTwoSourcesCollidingOnOneOutput` | 提前报错 |
| 跳过已存在 / 强制重跑 | `JobRunnerTests.SkipsExistingOutputWithoutForce` 等 | 两种行为都覆盖 |
| 200 文件上限 | `JobRunnerTests.RejectsTooManyFiles` | |
| 取消任务 | `CancellationTests.CancellingMidRunStopsWithoutOutput` | 且不留半截文件 |
| 429 重试、400 不重试、预算耗尽 | `ChatClientRetryTests` | 假 HTTP 处理器，不联网 |
| DeepSeek 关闭思考模式 | `ChatClientRetryTests.DisablesThinkingForDeepSeekHost` | |
| Ollama 请求/响应格式 | `OllamaClientTests` | 原生 `/api/chat`，非流式 |
| 提供商校验、id 生成 | `ProviderStoreTests` | 含非法 URL、空名称、控制字符 |
| 密钥不落 JSON | `ProviderStoreTests.SaveKeepsSecretsOutOfJson` | DPAPI 存储 |
| 旧配置导入 | `ProviderStoreTests.ImportsLegacyEnvFile` | `.env` 与 `providers.json` |
| 设置取值收敛 | `SettingsStoreTests.SanitizesOutOfRangeValues` | 并发/重试/后缀 |
| 版本比较 | `UpdateCheckerTests.ComparesVersions` | 语义化版本 |

### 期望输出

```text
Passed!  - Failed:     0, Passed:    50+, Skipped:     0, Total:    50+
```

数量会随开发增长，关键是 **Failed: 0**。

## 二、人工确认（无法自动化）

这些涉及真实桌面交互或外部服务，需要手动过一遍。

### 启动

- [ ] `windows\dist\app\AITrans.exe`（或 `dotnet run`）能启动并显示主窗口
- [ ] 首次运行被 SmartScreen 拦截时，「更多信息 → 仍要运行」可放行
- [ ] 关闭窗口后进程退出

### 界面

- [ ] 拖拽 `.srt` 文件到列表可用
- [ ] 拖拽文件夹可用（收集其中的 SRT）
- [ ] 「添加文件」「添加文件夹」打开系统对话框
- [ ] 粘贴完整路径后回车可添加；错误路径有提示
- [ ] 高 DPI（125% / 150%）下不模糊、不错位
- [ ] 深色模式正常
- [ ] 任务进行中「取消」能及时停止

### 真实服务

- [ ] 用真实 API Key 翻译一个文件，结果正确
- [ ] 翻译 + 润色正确
- [ ] 错误 Key 时提示鉴权失败
- [ ] 已安装 Ollama 时：能自动拉起服务、校验模型并完成翻译
- [ ] 未安装 Ollama 时：提示清晰

### 系统集成

- [ ] API Key 出现在「凭据管理器」或 `%APPDATA%\AITrans\secrets.dat`（加密），`providers.json` 中无明文
- [ ] 「检查更新」能读到 GitHub 最新 release
- [ ] 「打开输出目录」能打开资源管理器

## 三、反馈格式

```text
步骤：自动化 / 人工
环境：Windows 11 24H2，.NET 10.0.x
命令：powershell -ExecutionPolicy Bypass -File windows\scripts\verify.ps1
现象：……
完整输出：……
```

自动化失败时，把脚本输出整段贴回即可定位；人工项失败请附截图或 `%APPDATA%\AITrans\` 下的相关文件。
