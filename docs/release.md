# 发布与更新

> 状态：`v0.3.1` 为当前版本；`v0.3.0` 已走通完整流程——tag 推送 → 双端构建 → 创建 Release，产物可下载。
> 仓库已设为**公开**，应用内的匿名检查更新（`api.github.com/repos/Metahumanz/AItrans/releases/latest`）
> 才能拿到数据；如果以后改回私有，检查更新会静默失效。

## 1. 发布方式

推一个 `v*` 标签即可同时触发两个独立工作流：

```sh
git tag v2.0.0
git push origin v2.0.0
```

| 工作流 | 平台 | 内容 |
| --- | --- | --- |
| `release-macos.yml` | macOS | 跑测试 → 打包 `.app` → 上传 dmg/zip |
| `release-windows.yml` | Windows | 跑测试 → `dotnet publish` → 上传 zip/setup.exe |

两者**互不依赖**：任一平台排队或失败，都不会阻塞另一平台发布。都支持 `workflow_dispatch`
（传入 tag），可以只重跑单个平台。

发布步骤是幂等的：Release 已存在就补传（`--clobber`），不存在才创建；两个平台同时创建时，
后到的一方会退回补传。

## 2. 产物

| 平台 | 产物 | 说明 |
| --- | --- | --- |
| macOS | `AITrans-<version>-arm64.dmg` | 磁盘映像（约 0.8 MB），打开后把 App 拖进「应用程序」 |
| macOS | `AITrans-<version>-arm64.zip` | `.app` 压缩包（约 0.5 MB），解压后拖入「应用程序」 |
| Windows | `AITrans-<version>-win-x64-setup.exe` | 安装包（约 8 MB），默认按当前用户安装，带快捷方式与卸载项 |
| Windows | `AITrans-<version>-win-x64.zip` | 免安装版：依赖运行时的目录（约 10 MB），解压后运行 `AITrans.exe` |

### macOS dmg

`macos/Scripts/package-app.sh` 里用 `hdiutil` 生成，卷内附带一个 `/Applications` 软链，
用户拖进去就等于安装。zip 仍然保留（体积更小、便于脚本化）。

### Windows 安装包

用 Inno Setup 6 构建（[windows/installer/AITrans.iss](../windows/installer/AITrans.iss)），
发布工作流里自动编译，本地也可以直接跑：

```sh
ISCC.exe /DMyAppVersion=0.3.1 /DSourceDir=..\dist\app windows\installer\AITrans.iss
```

- 默认装到 `%LocalAppData%\Programs\AITrans`，**不需要管理员权限**；
  向导里可以改成「为所有用户安装」（那时才需要提权，装到 Program Files）；
- 创建开始菜单快捷方式，桌面图标是可选项；卸载走「应用和功能」，会删掉安装目录，
  但**保留** `%AppData%\AITrans` 里的配置、提供商与 API Key；
- 升级直接覆盖安装，`CloseApplications=yes` 会先关掉正在运行的 AITrans；
- 安装向导的「准备安装」页会先列出两个运行时依赖和下载地址（安装包不含运行时）。

安装包同样**未签名**，SmartScreen 仍会拦一次。

Windows 包**不带** .NET 运行时和 Windows App SDK 运行时，使用前需要装好：

- [.NET 10 桌面运行时](https://dotnet.microsoft.com/download/dotnet/10.0)（`Microsoft.WindowsDesktop.App 10.x`）；
- [Windows App Runtime 1.8](https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads)。

缺任一运行时时，`AITrans.exe` 会启动失败并提示缺少运行时，而不是闪退无提示。

## 3. 不签名的影响

本项目不做代码签名，因此**首次打开需要手动放行**。

### macOS

下载的 zip 带有隔离属性，直接双击会提示「无法验证开发者」：

- 方式一：右键点 App →「打开」→ 再点「打开」；
- 方式二：系统设置 → 隐私与安全性 → 底部「仍要打开」；
- 方式三（命令行）：`xattr -dr com.apple.quarantine /Applications/AITrans.app`。

### Windows

SmartScreen 会提示「Windows 已保护你的电脑」：

- 点「更多信息」→「仍要运行」。

> 这两步每个大版本只需做一次；应用内更新替换后的副本不会再触发（更新由 App 自己下载，不会带上隔离属性）。

## 4. 应用内更新

两端共用同一套协议，避免引入额外依赖。请求
`https://api.github.com/repos/Metahumanz/AItrans/releases/latest`，比较 `tag_name` 与当前版本。

两种触发方式：

| 方式 | 行为 |
| --- | --- |
| 启动后自动检查 | 延迟 3 秒静默请求一次。**只在发现新版本时**在界面顶部亮一条提示条（Windows 是任务页的 InfoBar，macOS 是文件列顶部的横幅），不弹窗、不打断；没网、被限流、已是最新都保持沉默 |
| 手动「检查更新」 | 立即请求并弹窗展示更新说明，可选「下载更新」或「打开下载页」 |

自动检查可以关掉：Windows 在「关于 → 维护 → 启动时自动检查更新」，macOS 在设置面板的
「关于」分组里。开关状态存在 `settings.json` 的 `auto_check_updates`，两端同一个键。

下载时优先挑安装包：Windows 取 `*-setup.exe`，macOS 取 `*.dmg`，都没有才回退到 zip。
文件落到系统「下载」文件夹并在资源管理器中定位。

**不做静默自替换**：未签名分发下自动覆盖安装目录风险过高，替换由用户完成（退出 → 解压 → 覆盖）。
两端都会在下载完成后给出这一步的说明。

> 自动检查用的是 GitHub 的**匿名**接口，额度是每 IP 每小时 60 次。正常使用（每次启动一次）
> 远低于这个量，但共享出口 IP 的网络里可能被限流；这种情况下检查会静默失败，不影响正常使用。

不使用 Sparkle / Velopack 的原因：两者在**未签名**分发下都会遇到额外限制（Sparkle 依赖代码签名校验与公证流程，Velopack 主要面向签名安装包）。自更新实现约 200 行，行为可控。

## 5. 版本号

单一来源：git 标签。构建时注入：

- macOS：`CFBundleShortVersionString` / `CFBundleVersion`；
- Windows：`AssemblyVersion` / `FileVersion`。

## 6. 本地打包（macOS）

```sh
macos/Scripts/package-app.sh 2.0.0
# 产物：macos/dist/AITrans.app 与 macos/dist/AITrans-2.0.0-arm64.zip
```

脚本使用 ad-hoc 签名（Apple Silicon 上可执行的最低要求），不是 Developer ID。
