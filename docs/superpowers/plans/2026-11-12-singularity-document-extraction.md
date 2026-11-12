# 文档提取基础（xberg）：实施计划

Spec：`docs/superpowers/specs/2026-11-12-singularity-document-extraction-design.md`。

1. 依赖：`apps/singularity` 加 `{:xberg, "~> 1.3.10"}`，`deps.get`，确认预编译 NIF 在 devenv 中能加载。
2. `Singularity.Documents.Extractor`（behaviour）和 `Singularity.Documents.XbergExtractor`：
   - 用 `kind: :uri` 传路径。
   - 输出 Markdown。
   - 把错误映射为 `{:extract_failed, message}`。
3. `Singularity.Documents.extract/2`：
   - 检查路径和大小。
   - 从 `:document_extractor` 配置读取提取器。
4. 测试：
   - `documents_test.exs`：test 配置中使用测试替身提取器。
   - `xberg_extractor_test.exs`：使用真实 fixture，包括 md、html、pdf 和损坏的 pdf。
5. AGENTS.md 技术栈加 xberg。
6. 验证：
   - 运行 format、compile、test。
   - 在 `MIX_ENV=prod mix release` 产物中提取 `sample.pdf`。
