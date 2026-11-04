# Windows 端验证清单

> 用途：你在 Windows 机器上验证时按此逐项勾选，把失败项连同日志反馈。
> 状态：`windows/AITrans.Core` 与 WinUI 3 客户端均已落地，CI 能编译并打出 zip；尚未在真实 Windows 桌面上人工跑过，本清单就是待勾选的部分。

## 0. 环境

- [ ] Windows 10 1809+ 或 Windows 11
- [ ] .NET SDK 10 已安装（`dotnet --version`）
- [ ] 能访问 GitHub（或已配置代理）

## 1. 构建

```bat
dotnet test windows/AITrans.Core.Tests/AITrans.Core.Tests.csproj -c Release
dotnet build windows/AITrans.App/AITrans.App.csproj -c Release -p:Platform=x64

:: 生成可分发的 zip
dotnet publish windows/AITrans.App/AITrans.App.csproj ^
  -c Release -r win-x64 --self-contained true -p:Version=0.0.1 -o windows\dist\app
```

- [ ] 构建无错误
- [ ] 单元测试全绿（与 macOS 同一批 `fixtures/`，当前 31 个）
- [ ] `windows\dist\app\AITrans.exe` 能启动并显示主窗口

## 2. 编码与解析

用 `fixtures/srt/` 里的样本，或自备字幕：

- [ ] UTF-8 正常
- [ ] UTF-8 带 BOM 正常（首行不出现乱码字符）
- [ ] UTF-16 LE 带 BOM 正常（记事本「Unicode」另存）
- [ ] GBK / GB18030 中文正常
- [ ] CRLF 换行正常
- [ ] 多行字幕保持换行
- [ ] 畸形块（缺正文）原样保留，不报错

## 3. 输出

- [ ] 源目录模式：生成 `原名_translated.srt`，不覆盖原文件
- [ ] output 模式：落到输出目录，文件名不变
- [ ] 自定义目录模式
- [ ] 后缀含 `\ / : * ? " < > |` 时被拒绝并给出中文提示
- [ ] 两个源文件会撞同一输出时提前报错
- [ ] 「强制重新处理」覆盖已有输出；不勾选时跳过非空输出

## 4. 引擎与网络

- [ ] API 提供商：翻译成功
- [ ] API 提供商：翻译 + 润色成功
- [ ] 断网时重试 3 次后给出可读错误
- [ ] 429/5xx 触发重试（可用代理模拟）
- [ ] Ollama 未安装时给出明确提示
- [ ] Ollama 已安装时能自动拉起 `ollama serve` 并检查模型

## 5. 并发与取消

- [ ] 并发 20 时任务正常完成
- [ ] 任务进行中取消，能在数秒内停止且不产生半截文件
- [ ] 200 个文件上限生效

## 6. 提供商与密钥

- [ ] 预设列表完整（9 个）
- [ ] 新增/编辑/删除提供商
- [ ] 切换启用项后立即生效
- [ ] 连通性测试对错误 Key 返回鉴权失败
- [ ] API Key 存入 **Windows 凭据管理器**，不在明文文件里
- [ ] 首次启动能从旧 `providers.json` / `.env` 导入并提示删除明文

## 7. 界面

- [ ] 高 DPI（125% / 150%）下不模糊、不错位
- [ ] 深色模式正常
- [ ] 拖拽文件/文件夹进窗口可用
- [ ] 系统文件对话框返回真实路径
- [ ] 任务列表显示进度、成功/失败计数
- [ ] 关闭窗口后进程退出（不留后台）

## 8. 更新

- [ ] 「检查更新」能读到 GitHub 最新 release
- [ ] 已是最新时提示正确
- [ ] 有新版本时能下载并替换、重启后版本号变化
- [ ] 更新失败（断网/权限）给出可读错误，不破坏现有安装

## 9. 反馈格式

```text
项目：4. 引擎与网络
环境：Windows 11 24H2 / .NET 10.0.x
现象：……
日志：%LOCALAPPDATA%\AITrans\logs\app.log 的相关片段
```
