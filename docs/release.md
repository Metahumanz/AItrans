# 发布与更新

> 状态：macOS 与 Windows 的构建、测试、打包均已在 CI 验证通过；`v*` 标签触发创建 Release 这一步尚未真实跑过。

## 1. 发布方式

推一个 `v*` 标签即可触发 `.github/workflows/release.yml`：

```sh
git tag v2.0.0
git push origin v2.0.0
```

工作流会：

1. 校验 `spec/` 与生成代码一致（`tools/gen_spec.py --check`）；
2. 跑两端单元测试；
3. 构建产物并附加到该标签对应的 GitHub Release。

## 2. 产物

| 平台 | 产物 | 说明 |
| --- | --- | --- |
| macOS | `AITrans-<version>-arm64.zip` | `.app` 压缩包，解压后拖入「应用程序」 |
| Windows | `AITrans-<version>-win-x64.zip` | 自包含目录，解压后运行 `AITrans.exe` |

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
3. 有新版则展示更新说明与下载按钮；
4. 下载 zip 到临时目录，校验后替换旧版本并重启。

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
