# 字幕翻译工具

## 快速开始（图形界面）

双击 `aitrans.command`（macOS）或 `aitrans.bat`（Windows），会在浏览器中打开本地图形界面（只监听 `127.0.0.1`，不会把文件上传到第三方；翻译仍按所选引擎访问 API 或本地 Ollama）：

- 拖入 `.srt` 文件或文件夹，也可以使用系统原生文件选择器；
- 默认勾选「翻译 + 润色」，可以只翻译或增加润色；
- 默认把结果保存到源文件目录，文件名加 `_translated` 后缀，不覆盖原文件；
- 顶部可快速切换当前模型提供商；
- 设置会自动保存，下次打开恢复上次使用的引擎、模型、语言、输出位置等选项。

| 启动文件（macOS / Windows） | 功能 |
| --- | --- |
| `aitrans.command` / `aitrans.bat` | 统一图形界面（推荐） |
| `provider.command` / `provider.bat` | 打开统一界面的「提供商」页 |
| `trans.command` / `trans.bat` | 原版：Ollama 本地翻译 |
| `transopt.command` / `transopt.bat` | 原版：Ollama 本地翻译 + 润色 |
| `transdeepseek.command` / `transdeepseek.bat` | 原版：使用当前 API 提供商翻译 |
| `transoptdeepseek.command` / `transoptdeepseek.bat` | 原版：使用当前 API 提供商翻译 + 润色 |

图形界面是新增入口，原有四个翻译启动器和命令行用法保持不变。首次运行会自动创建本目录的 `.venv` 并联网安装依赖，以后复用该环境。

## 图形界面

### 添加文件

- **拖入文件夹**：Chrome / Edge 会读取文件夹内的 SRT；在默认的「源文件目录」模式下，任务完成后会按原目录结构把结果写回，文件名加后缀，不覆盖原文件。
- **拖入单个文件**：浏览器不会暴露原始绝对路径；默认模式下结果会提供「下载」按钮，下载的文件名同样带后缀。需要直接写回源目录时，请用「选择文件」或「选择文件夹」。
- **选择文件 / 选择文件夹**：调用系统原生对话框（macOS 用「访达」，Windows 用系统文件对话框），能拿到真实路径；默认设置下结果直接保存到源文件目录。
- 也可以在输入框粘贴文件或文件夹路径后点「添加」。

一次最多添加 200 个文件；同名输出会提前报错，避免互相覆盖。

### 翻译与润色

| 引擎 | 只翻译 | 翻译 + 润色 |
| --- | --- | --- |
| API 提供商 | `transdeepseek.py` | `transoptdeepseek.py` |
| Ollama 本地 | `trans.py` | `transopt.py` |

默认「翻译」和「润色」都勾选。取消「润色」就只翻译；「翻译」是必选步骤。

### 保存位置

- **源文件目录**（默认）：`原文件名 + 后缀 + .srt`，例如 `movie_translated.srt`，不会覆盖源文件；
- **output 文件夹**：保持原文件名，保存到项目的 `output` 目录；
- **自定义目录**：选择任意输出文件夹。

后缀不能包含 `\ / : * ? " < > |` 等文件名非法字符（Windows 上尤其需要注意）。

「强制重新处理」会覆盖已存在的输出；不勾选时，已有非空输出会自动跳过。

### Ollama

使用 Ollama 引擎时，图形界面会检查本地服务，必要时自动启动 `ollama serve`。如果未安装 Ollama，可以切换到 API 提供商。Ollama 原生模式仍需提前准备模型：

```sh
ollama pull qwen2.5
```

启动日志保存在 `.ollama-mac.log`（macOS 命令行）、`.ollama-win.log`（Windows 命令行）或 `.ollama-gui.log`。

### 设置与配置

- `settings.json`：保存上次使用的引擎、模型、语言、输出方式、后缀等，权限 `600`，已加入 `.gitignore`；
- `providers.json`：保存所有 API 提供商配置，权限 `600`，已加入 `.gitignore`；
- `.env`：保存当前启用的提供商，权限 `600`，已加入 `.gitignore`。

关闭页面不会立即结束后台服务；请点页面底部「退出工具」，或回到启动它的终端按 `Ctrl+C`。任务进行中退出会先取消任务。

## 模型提供商

在统一界面顶部点「提供商」，或双击 `provider.command`（Windows：`provider.bat`）：

- 从预设添加 DeepSeek、OpenAI、Moonshot、智谱 GLM、阿里云百炼、硅基流动、OpenRouter、Ollama 等（预设只是填写起点，所有字段都可以修改）；
- 保存任意多个提供商配置，随时切换「当前启用」；
- 测试接口是否可访问；
- 保存并启用后自动写入 `.env`。

`transdeepseek.command` 和 `transoptdeepseek.command` 每次启动都会读取 `.env` 中启用的提供商；`trans.command` / `transopt.command` 仍使用 Ollama 原生接口。

也可以手工编辑 `.env`：

```sh
AI_PROVIDER=deepseek
AI_PROVIDER_NAME=DeepSeek
AI_API_KEY=sk-...
AI_BASE_URL=https://api.deepseek.com
AI_MODEL=deepseek-flash
```

选择 DeepSeek 时，旧版 `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` 仍会被识别。脚本会自动在 `AI_BASE_URL` 后追加 `/chat/completions`；DeepSeek 之外的服务默认不发送 `thinking` 参数，可用 `AI_THINKING=on` / `AI_THINKING=off` 强制控制。

### DeepSeek

首次运行若没有 Key，会提示输入并保存到 `.env`（输入时不显示字符）。也可以先双击 `provider.command`（Windows：`provider.bat`）配置好再运行。API 调用按账户计费。

## 原版命令行

原来的四个启动器仍按原方式工作：默认读取 `ori` 文件夹，结果写入 `output`，不会自动保存到源文件目录。适合脚本化或批处理：

```sh
./trans.command --model qwen2.5 --lang zh
./transopt.command --model qwen2.5 --lang zh --force
./transdeepseek.command --lang ja
./transoptdeepseek.command --lang ja --force
```

Windows 上把 `./trans.command` 换成 `trans.bat` 即可，参数完全一致。

四个翻译脚本新增了通用的输入/输出参数，`aitrans.command` / `aitrans.bat` 的图形界面调用的就是这些参数：

```sh
# 处理单个文件，结果写到源文件旁边
./transdeepseek.command --input ~/Movies/a.srt --save-to-source --suffix _zh

# 处理整个文件夹，结果写到指定目录
./transoptdeepseek.command --input ~/Movies/subs --output-dir ~/Movies/out --force
```

常用参数：

- `--input PATH`：SRT 文件或文件夹，可重复指定；不传时仍使用 `ori`；
- `--output-dir DIR`：输出目录；不传时仍使用 `output`；
- `--save-to-source`：保存到每个源文件旁边，配合 `--suffix`；
- `--suffix`：源文件目录模式的文件名后缀，默认 `_translated`；
- `--force` / `-f`：强制重新处理；
- `--model`：不指定时读取 `.env` 的 `AI_MODEL`，Ollama 模式默认 `qwen2.5`。

`--help` 可查看当前脚本的全部参数。自动化调用可设置 `AITRANS_NO_PAUSE=1`，避免结束时等待回车。

只启动服务、不自动打开浏览器：

```sh
./aitrans.command --no-browser
./provider.command --no-browser
```

Windows 上使用 `aitrans.bat --no-browser` / `provider.bat --no-browser`。

如果复制文件后丢失执行权限，在本目录执行：

```sh
chmod +x *.command launch-mac.sh
```

## Windows

双击对应的 `.bat` 即可，功能与 macOS 的 `.command` 一一对应（见顶部表格）。

首次运行会自动：

1. 查找 Python 3.10 或更新版本（优先 `py -3`，其次 `python`、`python3`）；
2. 在本目录创建 `.venv` 并安装 `tqdm` / `ollama`（需要联网）；
3. 使用 API 提供商时提示输入 API Key 并保存到 `.env`；
4. 使用 Ollama 时自动查找并启动 `ollama.exe`，日志写入 `.ollama-win.log`。

也可以在命令行中直接调用，参数和 macOS 完全一致：

```bat
aitrans.bat
provider.bat
trans.bat --model qwen2.5 --lang zh
transoptdeepseek.bat --lang ja --force
transdeepseek.bat --input "D:\Movies\a.srt" --save-to-source --suffix _zh
```

说明：

- 图形界面同样支持「选择文件 / 选择文件夹」，调用的是 Windows 原生对话框（需要 Python 自带的 tkinter，python.org 安装包默认包含）；
- 结果行里的按钮在 Windows 上是「在资源管理器中显示」；
- SRT 的 CRLF / LF 换行都可以正常处理，UTF-8（含 BOM）、UTF-16 与 GBK/GB18030 编码的字幕都能读取，输出统一为 UTF-8；
- 如果 `.venv` 是从 macOS 复制过来的（只有 `bin/`，没有 `Scripts/`），启动器会自动重建；
- 自动化调用可设置 `AITRANS_NO_PAUSE=1`，避免结束时等待按键。

已经自行准备好 Python 环境时，也可以直接运行：

```bat
python aitrans_gui.py
```

