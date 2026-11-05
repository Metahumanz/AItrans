# AItrans 字幕翻译

把 SRT 字幕批量翻译（可选润色）成中文 / 英文 / 日文 / 韩文。支持两种引擎：任意 OpenAI 兼容 API，或本地 Ollama。

当前仓库同时包含：

- **v2 原生客户端**（开发中）：macOS SwiftUI + Windows WinUI 3，双端由 GitHub Actions 构建发布；
- **v1 Python 实现**：保留作命令行入口与迁移参考，`legacy/` 里的启动器仍然可用。

## 目录结构

```text
AItrans/
├─ spec/                 语言无关契约：提示词、预设、解析规则、JSON Schema
├─ fixtures/             黄金样本：编码与结构用例 + 由 v1 生成的期望输出
├─ tools/                生成器：spec → Swift/C# 常量；fixtures → 期望值
├─ macos/                SwiftUI 客户端
│  ├─ Sources/AITransCore/   纯逻辑（可单测）
│  ├─ Sources/AITransApp/    界面
│  └─ Scripts/package-app.sh 打包为 .app
├─ windows/              WinUI 3 客户端
│  ├─ AITrans.Core/          纯逻辑（可单测）
│  ├─ AITrans.Core.Tests/    xunit 测试
│  └─ AITrans.App/           界面
├─ app/ web/ launchers/  v1 Python 实现
├─ legacy/               v1 命令行启动器
└─ docs/                 架构、发布、Windows 验证清单
```

## v2 客户端

### 构建

```sh
# macOS
cd macos && swift test && ../macos/Scripts/package-app.sh 0.3.3
# 产物：macos/dist/AITrans.app

# Windows
dotnet test windows/AITrans.Core.Tests/AITrans.Core.Tests.csproj -c Release
dotnet build windows/AITrans.App/AITrans.App.csproj -c Release -p:Platform=x64
# 一条命令跑完上面两步（加 -Publish 还会校验发布产物）：
powershell -ExecutionPolicy Bypass -File windows\scripts\verify.ps1 -Publish
```

Windows 客户端是原生 WinUI 3（`NavigationView` + Mica + 自绘标题栏），发布产物**不打包运行时**
（约 37 MB）：目标机器需要 .NET 10 桌面运行时与 Windows App Runtime 1.8，详见
[docs/release.md](docs/release.md)。

Windows 提供两种产物：`AITrans-<version>-win-x64-setup.exe` 安装包（约 8 MB，默认装到当前用户目录，
带开始菜单快捷方式和卸载项）与免安装的 zip。安装包本地构建：

```
ISCC.exe /DMyAppVersion=0.3.3 windows\installer\AITrans.iss
# 产物：windows\dist\AITrans-0.3.3-win-x64-setup.exe
```

两个客户端都**不做代码签名**，首次打开需要手动放行：

- macOS：右键点 App →「打开」；或系统设置 → 隐私与安全性 →「仍要打开」；
- Windows：SmartScreen 里点「更多信息」→「仍要运行」。

### 功能

- 拖拽 / 系统选择器 / 粘贴路径三种方式添加字幕，单次最多 200 个文件；
- API 与本地 Ollama 两种引擎，四种目标语言，翻译与润色可分别开关；
- 输出到源文件目录（加后缀）、应用输出目录或自定义目录；
- 并发与重试可调，任务可取消，进度与结果逐文件展示；
- 提供商管理：9 个预设、增删改、切换、连通性测试、清除已保存的密钥；
- 提供商地址：macOS 上公网接口必须用 `https://`；`localhost` 与局域网地址（含 Ollama 默认的 `http://127.0.0.1:11434`）可继续用 `http://`（系统 ATS 限制，Windows 不受影响）；
- 密钥保存在本地：macOS 用 `secrets.json`（**明文**，0600，不使用钥匙串），Windows 用 DPAPI 加密的 `secrets.dat`；`providers.json` 中不写明文；
- macOS 从 v0.3.1 及更早版本升级到 v0.3.2+ 时，旧钥匙串里的 Key 不会自动迁移，需要在「提供商」里重新填写一次（只需一次）。
- 应用内检查更新：启动后静默查一次（可关），发现新版本在界面顶部提示；下载到「下载」文件夹后按提示覆盖。

### 开发约定

- `spec/` 是提示词与规则**唯一**的事实来源，改动后运行 `python3 tools/gen_spec.py` 并提交生成物；CI 会校验是否最新。
- `fixtures/` 由 `python3 tools/gen_fixtures.py` 调用 v1 实现生成，两端测试读取同一批样本；CI 会校验可重现。
- 详细说明见 [docs/architecture.md](docs/architecture.md)、[docs/release.md](docs/release.md)，以及两端验收清单 [macOS](docs/verification-macos.md) / [Windows](docs/verification-windows.md)。

## v1 命令行（保留）

`legacy/` 下的启动器行为不变，适合脚本化：

```sh
./legacy/trans.command --model qwen2.5 --lang zh
./legacy/transopt.command --model qwen2.5 --lang zh --force
./legacy/transdeepseek.command --lang ja
./legacy/transoptdeepseek.command --input ~/Movies/a.srt --save-to-source --suffix _zh
```

Windows 上把 `./legacy/trans.command` 换成 `legacy\trans.bat`，参数一致。

常用参数：`--input`、`--output-dir`、`--save-to-source`、`--suffix`、`--force`、`--workers`、`--retries`、`--model`；`--help` 查看全部。

v1 的图形界面仍可通过 `aitrans.command` / `aitrans.bat` 启动（浏览器界面），但它不再是推荐入口。
完整说明（启动器对照表、并发参数、编码支持、Ollama 设置、故障排查）见 [docs/legacy-cli.md](docs/legacy-cli.md)。

## 配置

v1 与命令行使用项目根目录的 `.env` / `providers.json`；v2 客户端使用各自的应用数据目录，并在首次配置时支持从旧文件导入。

```sh
AI_PROVIDER=deepseek
AI_PROVIDER_NAME=DeepSeek
AI_API_KEY=sk-...
AI_BASE_URL=https://api.deepseek.com
AI_MODEL=deepseek-flash
```

## 许可

个人项目，未声明开源许可。
