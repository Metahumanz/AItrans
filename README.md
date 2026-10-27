# 字幕翻译工具

## macOS 一键运行

先安装 Python 3.10 或更新版本，把要处理的 `.srt` 文件放进本目录的 `ori` 文件夹，然后在 Finder 中双击对应的启动文件：

| 启动文件 | 功能 |
| --- | --- |
| `provider.command` | 图形化配置 / 切换模型提供商 |
| `trans.command` | Ollama 本地翻译 |
| `transopt.command` | Ollama 本地翻译 + 润色 |
| `transdeepseek.command` | 使用当前启用的 API 提供商翻译 |
| `transoptdeepseek.command` | 使用当前启用的 API 提供商翻译 + 润色 |

首次运行自动创建本目录的 `.venv` 并联网安装依赖，以后复用该环境。四种翻译模式的结果均保存到 `output`。默认会自动跳过 `output` 中已存在的翻译结果，避免重复消耗时间与 Token；如需重新翻译，可删除对应输出文件或在终端加上 `--force`（`-f`）参数。窗口会保留处理日志，按回车关闭。

## 模型提供商（图形化配置）

双击 `provider.command`，会在浏览器中打开本地配置页面（只监听 `127.0.0.1`，配置只保存在本机）：

- 从预设添加 DeepSeek、OpenAI、Moonshot、智谱 GLM、阿里云百炼、硅基流动、OpenRouter、Ollama 等（预设只是填写起点，所有字段都可以修改）；
- 保存任意多个提供商配置，随时切换「当前启用」；
- 测试接口是否可访问；
- 保存并启用后自动写入 `.env`。

`transdeepseek.command` 和 `transoptdeepseek.command` 每次启动都会读取 `.env` 中启用的提供商；`trans.command` / `transopt.command` 仍使用 Ollama 原生接口。

配置档案保存在 `providers.json`（文件权限 `600`，已加入 `.gitignore`），当前选择写入 `.env`（同样是 `600`）。也可以手工编辑 `.env`：

```sh
AI_PROVIDER=deepseek
AI_PROVIDER_NAME=DeepSeek
AI_API_KEY=sk-...
AI_BASE_URL=https://api.deepseek.com
AI_MODEL=deepseek-flash
```

选择 DeepSeek 时，旧版 `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` 仍会被识别。脚本会自动在 `AI_BASE_URL` 后追加 `/chat/completions`；DeepSeek 之外的服务默认不发送 `thinking` 参数，可用 `AI_THINKING=on` / `AI_THINKING=off` 强制控制。

### DeepSeek

首次运行若没有 Key，会提示输入并保存到 `.env`（输入时不显示字符）。也可以先双击 `provider.command` 配置好再运行。API 调用按账户计费。

### Ollama

先安装 [Ollama](https://ollama.com/download/mac)，并在终端执行一次：

```sh
ollama pull qwen2.5
```

启动文件会检查服务是否可用，必要时自动运行 `ollama serve`。结束时仅关闭本次启动的服务进程。启动错误日志保存在 `.ollama-mac.log`。

### 终端运行 / 自定义参数

在本目录打开终端，可以传入与原 Python 脚本相同的参数，例如：

```sh
./trans.command --model qwen2.5 --lang zh
./transoptdeepseek.command --lang ja --force
./transdeepseek.command --help
```

`--model` 不指定时会读取 `.env` 中的 `AI_MODEL`。自动化调用可设置 `AITRANS_NO_PAUSE=1`，避免结束时等待回车。

配置工具也支持只启动服务、不自动打开浏览器：

```sh
./provider.command --no-browser
```

如果复制文件后丢失执行权限，在本目录执行：

```sh
chmod +x *.command launch-mac.sh
```

Windows 可直接运行 `python provider_gui.py` 启动配置界面，并用 `python transdeepseek.py` / `python transoptdeepseek.py` 运行翻译；仓库中原有的 `.bat` 启动器不在此次改动范围内。
