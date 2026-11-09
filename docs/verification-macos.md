# macOS 端验证清单

> 用途：在 Mac 上按此逐项勾选。状态：构建、打包、启动与本地密钥存储已在本机验证；其余界面、真实服务和安装包项仍待逐项人工验收。

## 0. 环境

- [ ] macOS 14 或更新版本
- [ ] Xcode 命令行工具可用（`swift --version` 能输出 6.0+）

## 1. 构建与启动

```sh
cd macos
swift test
../macos/Scripts/package-app.sh 0.3.6
open dist/AITrans.app
```

- [x] 测试全绿（当前 65 个，其中 2 个真实接口用例默认跳过；v0.3.6 的 release 工作流已在 macos-15 上跑过）
- [x] 打包生成 `macos/dist/AITrans.app`、zip 与 dmg
- [x] 启动后出现主窗口（本机用 `open` 验证，窗口 900×612）
- [ ] 双击启动后菜单栏显示 AITrans
- [ ] 首次启动若被 Gatekeeper 拦截，右键「打开」或到「隐私与安全性」放行后可用
- [ ] 关闭窗口后进程退出（Dock 图标消失）

## 2. 输入

- [ ] 拖拽 `.srt` 文件到列表
- [ ] 拖拽文件夹到列表（自动收集其中的 SRT）
- [ ] 「添加文件」选择器可用
- [ ] 「添加文件夹」选择器可用
- [ ] 粘贴路径（含 `~`）后回车可添加
- [ ] 不存在的路径给出提示
- [ ] 重复添加同一文件不会出现两条
- [ ] 超过 200 个文件时截断并提示

## 3. 编码与解析

用 `fixtures/srt/` 里的样本，或自备字幕：

- [ ] UTF-8 正常
- [ ] UTF-8 带 BOM 正常（首行无多余字符）
- [ ] UTF-16 LE 带 BOM 正常
- [ ] GBK / GB18030 中文正常
- [ ] CRLF 换行正常
- [ ] 多行字幕保持换行
- [ ] 畸形块（缺正文）原样保留，不报错

## 4. 输出

- [ ] 源目录模式生成 `原名_translated.srt`，不覆盖原文件
- [ ] 应用输出目录模式（`~/Library/Application Support/AITrans/output`）
- [ ] 自定义目录模式
- [ ] 后缀含 `/` `:` 等非法字符时被拒绝并提示
- [ ] 两个源文件会撞同一输出时提前报错
- [ ] 「强制重新处理」覆盖已有输出；不勾选时跳过非空输出
- [ ] 「打开输出目录」能打开访达

## 5. 引擎与网络

- [ ] API 提供商：只翻译
- [ ] API 提供商：翻译 + 润色
- [ ] 断网时重试后给出可读错误（不是崩溃）
- [ ] 错误 Key 时提示鉴权失败
- [ ] 任务进行中「取消」，数秒内停止且不留半截文件
- [ ] 未安装 Ollama 时切到 Ollama 引擎，提示清晰
- [ ] 已安装 Ollama：能自动拉起 `ollama serve` 并检查模型
- [ ] 缺少模型时提示 `ollama pull <模型>`

## 6. 提供商与本地密钥

- [ ] 9 个预设都能填入表单
- [ ] 新建 / 编辑 / 删除提供商
- [ ] 切换当前提供商后立即生效
- [ ] 「测试连接」对错误 Key 返回鉴权失败
- [x] API Key 保存在 `~/Library/Application Support/AITrans/secrets.json`（0600），`providers.json` 中无明文
- [x] 正常启动不读 `secrets.json`；首次开始任务、测试连接或打开提供商编辑面板时才读取。若检测到旧版明文 key，启动阶段会读写一次以完成迁移
- [x] 读取密钥不会创建目录或 `secrets.json.lock`（只有写入才加锁）
- [x] 删除提供商时对应 key 从 `secrets.json` 移除（删除前有确认框）
- [x] 「清除已保存的密钥」能删掉条目但保留提供商；`providers.json` 不变（清除前有确认框）
- [ ] 公网 `http://` 接口保存时被拒绝并提示改用 https；`localhost` / 局域网 `http://` 可正常保存
- [ ] 旧钥匙串条目不参与读取；升级后需要重新填写一次 API Key
- [ ] 「从旧版导入…」能导入 v1 的 `providers.json`
- [ ] `secrets.json` 损坏时删除提供商失败，提示里给出文件路径和手工处理方式

## 7. 界面

- [ ] 浅色 / 深色模式切换正常
- [ ] 窗口缩放时布局不错位（最小 900×560）
- [ ] 列表滚动流畅（200 条时）
- [ ] 翻译时底部出现「翻译」进度条，按段推进并显示 `已完成/总段数` 与成功、失败计数
- [ ] 开启润色后，翻译完成自动切换到「润色」进度条
- [ ] 多文件时「文件」进度条按文件推进，当前文件的段级进度独立显示
- [ ] `⌘↩` 开始任务，`⌘⇧U` 检查更新
- [x] 启动不读钥匙串/密钥文件（懒加载后主窗口先出现）
- [ ] 启动约 3 秒后自动检查一次；有新版本时文件列顶部出现横幅（不弹 sheet），「查看更新」才弹更新面板
- [ ] 设置面板「关于」里关掉自动检查后，重启不再自动请求
- [ ] 菜单「关于 AITrans」可用

## 8. 更新

- [ ] 无发布版本时提示「仓库还没有发布版本」
- [ ] 已是最新时提示正确
- [ ] 有新版本时显示版本号与更新说明
- [ ] 「下载更新」能把 zip 存到「下载」并定位到文件
- [ ] 「打开下载页」能打开 GitHub Release

## 9. 当前验证状态（2026-11-08）

环境：macOS 27.2（26B123），arm64，Swift 6.x。

已验证：

- `swift test --disable-sandbox`：65 个测试，2 个跳过，0 失败（2026-11-08 本机重跑；v0.3.6 的 Release macOS 工作流在 macos-15 上执行）。
- `package-app.sh 0.3.2` 能生成 `AITrans.app`、zip 和 dmg。
- `package-app.sh 0.3.5` 能生成 app / zip / dmg；本地 dmg 可挂载、版本 0.3.5、卷内 `Applications` 软链与 ad-hoc 签名校验通过（2026-11-05）。
- Release v0.3.2 的 dmg 能挂载：UDZO/UDIF、尾部 `koly`、卷内 `Applications -> /Applications` 软链、App 版本 0.3.2、ad-hoc 签名校验通过。
- 用真实配置启动 v0.3.2：主窗口 900×612，启动阶段不读密钥，无授权框。
- v0.3.2 起 macOS 密钥保存在本地 `secrets.json`（明文，0600）：正常启动只解析 `providers.json`；检测到旧版明文 key 时会在载入后立即迁移；开始任务、测试连接、打开提供商编辑面板时才按需读取。
- v0.3.3：读取密钥不再创建目录或锁文件，新增「清除已保存的密钥」；Release 已发布 dmg（约 0.8 MB）与 zip（约 0.45 MB）。
- v0.3.4：删除提供商 / 清除密钥前增加确认；公网 `http://` 提供商保存时拒绝并提示改用 https；显示名统一为 `AITrans`；清理 `ContentView` 的未使用变量警告。Release 已发布 dmg（约 0.8 MB）与 zip（约 0.45 MB），macOS 60 个测试全绿。
- v0.3.5：打包 App 在 `Info.plist` 声明本机/局域网 ATS 例外；Ollama 默认地址改为 `http://localhost:11434`；Release 已发布 dmg（约 0.8 MB）与 zip（约 0.45 MB），macOS 62 个测试全绿。发布包实测 `localhost`、`127.0.0.1` 与局域网 IP 的 http 均放行，公网 http 仍被拦截。
- v0.3.6：双端新增翻译 / 润色段级进度条；Release 已发布 macOS dmg（约 0.8 MB）、zip（约 0.46 MB）与 Windows setup（约 8.2 MB）、zip（约 10.1 MB），macOS 65 个、Windows 80 个测试全绿（2026-11-09）。

已知限制：

- `v0.3.1` 及以前使用钥匙串；`v0.3.2` 起使用本地 `secrets.json`。
- 旧钥匙串条目不自动迁移；升级到本地文件版本后，需要在提供商里重新填写一次 API Key。
- `secrets.json` 是明文 0600，不再有 Keychain ACL 保护；这是脱离钥匙串的取舍。
- macOS ATS 只放行本机/局域网明文 HTTP；公网 `http://` 提供商在保存时会被拒绝，需改用 `https://`（Windows 无此限制）。打包 App 的 `Info.plist` 已为 `localhost`、回环与私有网段声明 `NSExceptionDomains`，覆盖 macOS 14+ 对 IP 字面量的限制。
- 尚未验证：横幅/InfoBar 视觉、开关点击、拖拽、真实翻译与 Gatekeeper 双击拦截流程。
- `spctl -a` 对 ad-hoc 包返回 `rejected`，这是未签名/未公证的预期结果；本机没有 quarantine 属性，所以 `open` 能直接启动。

## 10. 反馈格式

```text
项目：5. 引擎与网络
环境：macOS 27.2 / Xcode 26
现象：……
日志：~/Library/Logs/AITrans/ 或控制台.app 中 AITrans 的相关输出
```
