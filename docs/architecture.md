# 架构

## 1. 分层

```text
spec/                 语言无关契约：schema、提示词、预设、解析规则、重试策略
fixtures/             黄金样本：SRT 输入 + 由 legacy Python 生成期望输出
tools/                生成器：spec → 各语言常量；fixtures → 期望值
macos/                SwiftUI 客户端（AITransCore 纯逻辑 + AITransApp 界面）
windows/              WinUI 3 客户端（AITrans.Core 纯逻辑 + AITrans.App 界面）
app/ web/ legacy/     v1 Python 实现，保留作 CLI 与迁移参考
```

## 2. 关键决策

### 2.1 两端各写一份逻辑，不共享二进制

业务逻辑约 2,500 行，规则稳定。用 Rust FFI 或本地服务共享会引入内存管理、错误映射、异步桥接的复杂度，收益低于成本。
防漂移靠**同一份契约 + 同一批测试样本**，而不是共享代码。

### 2.2 `spec/` 是唯一事实来源

提示词、提供商预设、解析正则、重试参数都写在 `spec/*.json`。
`tools/gen_spec.py` 把它们生成为 `Spec.swift` / `Spec.cs`，**生成物必须提交**，CI 会重新生成并检查 diff。

这样做的原因：提示词是最容易在两端悄悄漂移的东西，手抄必然出错。

### 2.3 `fixtures/` 由 legacy 实现生成

`tools/gen_fixtures.py` 不复制解析逻辑，而是给现有 Python 实现注入确定性假模型，让真实代码产出期望值。
所以 fixtures 描述的是「当前真实行为」，而不是「我以为的行为」。Swift/C# 的测试直接比对这批 JSON。

覆盖：UTF-8、UTF-8 BOM、UTF-16LE BOM、GBK、CRLF、多行字幕、畸形块（少于 3 行）。

## 3. 模块边界（macOS）

| 模块 | 职责 | 是否可测 |
| --- | --- | --- |
| `SRT.swift` | 分块、解析、组装、引号剥离 | 纯函数，fixtures 驱动 |
| `TextDecoding.swift` | 编码探测 | 纯函数，fixtures 驱动 |
| `OutputPaths.swift` | 后缀校验、输出位置、同名冲突 | 纯函数 |
| `RetryPolicy.swift` | 可重试判定、指数退避 | 纯函数 |
| `ChatClient.swift` | OpenAI 兼容请求 | 依赖网络，测 payload 构造 |
| `Translator.swift` | 并发翻译、分批润色 | 依赖 ChatClient 抽象 |
| `AITransApp` | SwiftUI 界面 | 手工验证 |

Windows 端保持一一对应的模块划分（`AITrans.Core` / `AITrans.App`），便于逐项对照。

Windows 端保持一一对应的模块划分，便于逐项对照。

## 4. 行为契约（必须与 v1 一致）

1. 以空行切块；不足 3 行的块原样输出。
2. 输出为「译文在上、原文在下」，块之间空一行。
3. 译文首尾的中英文引号会被剥掉。
4. 重试：传输错误、429、5xx 可重试，退避为 1、2、4 秒。
5. 润色按 8 条一批，取前两批作为上下文。
6. 目标语言：zh / en / ja / ko，对应「中文 / 英文 / 日文 / 韩文」。

## 5. 与 v1 的差异

| 项 | v1 | v2 |
| --- | --- | --- |
| 界面 | 浏览器 + 本地 HTTP 服务 | 原生窗口 |
| 密钥存储 | `.env` / `providers.json` | macOS 本地 `secrets.json`（0600）；Windows DPAPI `secrets.dat` |
| 文件路径 | 受浏览器限制，需服务端代写 | 直接读写 |
| CLI 入口 | `legacy/` 四个脚本 | 新 GUI 不含；仓库保留 |
| 更新 | 手动 | 应用内检查 + 下载安装 |

## 6. 测试策略

| 层次 | 方式 | 何时跑 |
| --- | --- | --- |
| 行为等价 | 两端读同一批 `fixtures/`，逐块比对 | 每次 CI |
| 重试与错误分类 | Swift 用 `URLProtocol` 桩，C# 用假 `IChatCompleter` | 每次 CI |
| 真实接口 | `AITRANS_LIVE_TEST=1 AITRANS_LIVE_KEY=… swift test --filter LiveAPITests` | 本地手动 |

真实接口测试默认跳过（CI 不设环境变量），避免把密钥和网络依赖带进流水线。
