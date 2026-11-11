# README、Instruction、废弃：实施计划

Spec：`docs/superpowers/specs/2026-11-11-singularity-project-readme-instruction-deprecated-design.md`。

1. 迁移：`items` 加 `readme`、`readme_fetched_at`、`instruction`、`deprecated_at`、`deprecation_reason`；`Item` schema 同步加字段。
2. GitHub 和 Worker：
   - `GitHub.fetch_readme/3`，和其他请求共用请求和错误处理。
   - `FetchReadmeWorker`、`ReadmeRefreshWorker`，后者在 cron 中注册（`15 * * * *`）。
   - 测试：`github_test.exs`，新增 `knowledge/fetch_readme_worker_test.exs`。
3. Knowledge：
   - `deprecated?/1`、`deprecate/2`、`undeprecate/1`。
   - `change_instruction/2`、`update_instruction/2`。
   - `put_readme/3`、`enqueue_readme/1`、`enqueue_stale_readmes/2`。
   - `list_projects` 的 `:status` 选项。
   - `add_project` 为 GitHub 项目入队获取 README。
   - 测试：新增 `knowledge_project_text_test.exs`。
4. Web：
   - 详情页：废弃徽标、alert 和按钮，Instruction 卡片和 modal，README 卡片；"Fetch again" 同时获取 README。
   - `details_status` 加 Deprecated 徽标；Knowledge 工具栏加 Status 筛选。
   - 测试：`knowledge_live_test.exs`。
   - 提取 gettext。
5. 验证：
   - 运行 format、compile、test。
   - 在 devenv 环境确认 README 开始逐步补齐，截图一个项目页（README、Instruction、废弃）。
