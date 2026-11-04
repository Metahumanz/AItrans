# v1 命令行与旧图形界面

> v2 原生客户端是推荐入口。本文保留 v1 的完整用法，便于脚本化与排查。
> 代码位于 `app/`、`web/`、`launchers/`、`legacy/`。

## 启动器

| 启动文件 | 位置 | 功能 |
| --- | --- | --- |
| `aitrans.command` / `aitrans.bat` | 根目录 | 旧图形界面（浏览器打开，翻译 + 提供商） |
| `provider.command` / `provider.bat` | `legacy/` | 打开旧界面的「提供商」标签页 |
| `trans.command` / `trans.bat` | `legacy/` | Ollama 本地翻译 |
| `transopt.command` / `transopt.bat` | `legacy/` | Ollama 本地翻译 + 润色 |
| `transdeepseek.command` / `transdeepseek.bat` | `legacy/` | 当前 API 提供商翻译 |
| `transoptdeepseek.command` / `transoptdeepseek.bat` | `legacy/` | 当前 API 提供商翻译 + 润色 |

首次运行会在项目根目录创建 `.venv` 并联网安装依赖（`tqdm`、`ollama`）。

## 引擎与参数

| 引擎 | 只翻译 | 翻译 + 润色 |
| --- | --- | --- |
| API 提供商 | `app/transdeepseek.py` | `app/transoptdeepseek.py` |
| Ollama 本地 | `app/trans.py` | `app/transopt.py` |

```sh
./legacy/trans.command --model qwen2.5 --lang zh
./legacy/transopt.command --model qwen2.5 --lang zh --force
./legacy/transdeepseek.command --lang ja
./legacy/transoptdeepseek.command --input ~/Movies/a.srt --save-to-source --suffix _zh
```

常用参数：`--input`、`--output-dir`、`--save-to-source`、`--suffix`、`--force`、`--workers`、`--retries`、`--model`、`--timeout`；`--help` 查看全部。

## 并发与重试

| 引擎 | 并发默认 | 重试默认 | 可选范围 |
| --- | --- | --- | --- |
| API 提供商 | 20 | 2 | 并发 1–64，重试 0–5 |
| Ollama 本地 | 2 | 1 | 并发 1–64，重试 0–5 |

重试只针对可重试错误（网络异常、超时、429、5xx），按 1、2、4 秒指数退避。Ollama 的润色阶段按批次串行。

## 输出规则

- **源文件目录**（默认）：`原文件名 + 后缀 + .srt`，不覆盖源文件；
- **output 文件夹**：保持原文件名；
- **自定义目录**：任意位置。

后缀不能包含 `\ / : * ? " < > |` 与控制字符。「强制重新处理」会覆盖已存在输出；不勾选时非空输出自动跳过。

浏览器拿不到源路径时，结果先落临时目录，可用「写回文件夹…」复制出去；目标已存在时不覆盖，内容相同视为已写回。临时目录在退出时清理，异常退出留下的旧目录会在下次启动清掉。

## 编码

读取 UTF-8（含 BOM）、UTF-16、GBK/GB18030；输出统一 UTF-8 + LF。CRLF 输入可正常处理。

## Ollama

旧界面会检查本地服务，必要时自动启动 `ollama serve`。需要提前准备模型：

```sh
ollama pull qwen2.5
```

日志：`.ollama-mac.log`（macOS 命令行）、`.ollama-win.log`（Windows 命令行）、`.ollama-gui.log`（旧界面）。

## 配置文件

- `settings.json`：旧界面设置，权限 `600`，已忽略；
- `providers.json`：提供商配置，权限 `600`，已忽略；
- `.env`：当前启用的提供商，权限 `600`，已忽略。

v2 客户端可从这些文件导入配置（提供商面板里的「从旧版导入…」）。

## 旧界面说明

关闭页面不会立即结束后台服务；点页面底部「退出工具」，或回到终端按 `Ctrl+C`。任务进行中退出会先取消任务。
