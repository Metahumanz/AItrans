# spec —— 语言无关的契约

两端（Swift / C#）不共享代码，共享这里的**数据与规则**。

| 文件 | 内容 | 谁在用 |
| --- | --- | --- |
| `prompts/prompts.json` | 翻译与润色的提示词、语言名映射、编号行格式 | 两端生成常量 |
| `providers.presets.json` | 9 个提供商预设 | 两端生成常量 |
| `parsing.json` | 分块正则、引号剥离、重试与并发默认值、思考模式规则 | 两端生成常量 |
| `settings.schema.json` | `settings.json` 的结构与取值 | 两端校验 |
| `providers.schema.json` | 提供商存储结构 | 两端校验 |
| `job.schema.json` | 任务与结果模型 | 两端内部 |

## 修改流程

1. 改 `spec/*.json`；
2. 重新生成常量：

   ```sh
   python3 tools/gen_spec.py
   ```

3. 提交 spec 与生成物（`macos/Sources/AITransCore/Generated/Spec.swift`、
   `windows/AITrans.Core/Generated/Spec.cs`）；
4. CI 会跑 `python3 tools/gen_spec.py --check`，生成物过期即失败。

## 为什么生成而不是运行时读取

- 运行时读文件需要处理打包、资源路径、缺失兜底，两端各写一套；
- 生成物可被编译期检查，提示词写错会直接编译失败或测试失败；
- 生成物进仓库后，review 时能看到提示词的每一次改动。

## 与 fixtures 的关系

`spec/` 描述**规则**，`fixtures/` 描述**行为**。
规则改了但 fixtures 没变，说明行为可能被意外改动；测试会暴露这一点。
