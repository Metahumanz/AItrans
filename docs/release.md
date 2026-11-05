# 发布与更新

> 状态：`v0.2.0` 已走通完整流程——tag 推送 → 双端构建 → 创建 Release，产物可下载。

## 1. 发布方式

推一个 `v*` 标签即可同时触发两个独立工作流：

```sh
git tag v2.0.0
git push origin v2.0.0
```

| 工作流 | 平台 | 内容 |
| --- | --- | --- |
| `release-macos.yml` | macOS | 跑测试 → 打包 `.app` → 上传 zip |
| `release-windows.yml` | Windows | 跑测试 → `dotnet publish` → 上传 zip |

两者**互不依赖**：任一平台排队或失败，都不会阻塞另一平台发布。都支持 `workflow_dispatch`
（传入 tag），可以只重跑单个平台。

发布步骤是幂等的：Release 已存在就补传（`--clobber`），不存在才创建；两个平台同时创建时，
后到的一方会退回补传。

## 2. 产物

| 平台 | 产物 | 说明 |
| --- | --- | --- |
| macOS | `AITrans-<version>-arm64.zip` | `.app` 压缩包（约 370 KB），解压后拖入「应用程序」 |
| Windows | `AITrans-<version>-win-x64.zip` | 依赖运行时的目录（约 37 MB），解压后运行 `AITrans.exe` |

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

两端共用同一套协议，避免引入额外依赖：

1. 启动后（可关闭）或手动点「检查更新」，请求
   `https://api.github.com/repos/Metahumanz/AItrans/releases/latest`；
2. 比较 `tag_name` 与当前版本；
3. 有新版则展示更新说明，可「下载更新」或打开下载页；
4. 下载 zip 到系统「下载」文件夹，并定位到该文件。

**不做静默自替换**：未签名分发下自动覆盖安装目录风险过高，替换由用户完成（退出 → 解压 → 覆盖）。
两端都会在下载完成后给出这一步的说明。

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
