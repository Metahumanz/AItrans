# 字幕翻译工具

## macOS 一键运行

先安装 Python 3.10 或更新版本，把要处理的 `.srt` 文件放进本目录的 `ori` 文件夹，然后在 Finder 中双击对应的启动文件：

| 启动文件 | 功能 |
| --- | --- |
| `trans.command` | Ollama 本地翻译 |
| `transopt.command` | Ollama 本地翻译 + 润色 |
| `transdeepseek.command` | DeepSeek API 翻译 |
| `transoptdeepseek.command` | DeepSeek API 翻译 + 润色 |

首次运行自动创建本目录的 `.venv` 并联网安装依赖，以后复用该环境。四种模式的结果均保存到 `output`。默认会自动跳过 `output` 中已存在的翻译结果，避免重复消耗时间与 Token；如需重新翻译，可删除对应输出文件或在终端加上 `--force`（`-f`）参数。窗口会保留处理日志，按回车关闭。

### DeepSeek

首次运行若没有 Key，会提示输入并保存到 `.env`（输入时不显示字符）。已有 `.env` 或环境变量中的 `DEEPSEEK_API_KEY` 会直接复用。API 调用按账户计费。

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

自动化调用可设置 `AITRANS_NO_PAUSE=1`，避免结束时等待回车。

如果复制文件后丢失执行权限，在本目录执行：

```sh
chmod +x *.command launch-mac.sh
```

Windows 仍使用原有 `.bat` 文件。
