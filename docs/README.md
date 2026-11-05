# AItrans 文档

v2 是双原生客户端：macOS 用 SwiftUI，Windows 用 C# + .NET + WinUI 3。两端共享 `spec/` 与 `fixtures/`，不共享 UI 代码。

## 进仓库的文档

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 分层、模块边界、契约与生成物、为什么两端各写一份逻辑 |
| [release.md](release.md) | GitHub Actions 构建与发布、无签名分发、用户如何放行 |
| [verification-windows.md](verification-windows.md) | Windows 端需要人工验证的清单 |
| [verification-macos.md](verification-macos.md) | macOS 端需要人工验证的清单 |
| [legacy-cli.md](legacy-cli.md) | v1 命令行与旧图形界面的完整用法 |
| [../spec/README.md](../spec/README.md) | 契约文件说明与修改流程 |

## 只留本地

`docs/local/` 已加入 `.gitignore`，用于放方案草稿、排期与个人笔记，不随仓库分发。
旧的 `native-client-plan.md` 已过时并删除；需要新的方案草稿时再在本地新建。

## 为什么这样分

进仓库的是**别人接手也需要知道的**：架构约束、发布流程、验收清单。
留本地的是**决策过程与个人排期**：它有价值，但会随讨论变化，且不适合作为仓库的长期契约。
