# GitHub Stars 来源：实施计划

Spec：`docs/superpowers/specs/2026-11-11-singularity-github-stars-design.md`。

1. 迁移：
   - 新建 `item_sources` 表并按观测记录回填。
   - `items` 加 `removal_due_at`。
   - 新增 `ItemSource` schema；`Item` 加 `removal_due_at` 字段和 `has_many :item_sources`。
2. 框架：
   - `Result.complete`，`Entry.period`、`Entry.details`。
   - `Knowledge.record/3` 维护归属和离开，保存 `details`，并按 Entry 的 `period` 写观测。
   - `add_project` 写手动归属。
   - 新增 `list_item_sources/1`、`purge_removed/1` 和 `PurgeWorker`，在 cron 中注册（`0 3 * * *`）。
   - 测试：`knowledge_record_test.exs`、`knowledge_add_project_test.exs`，新增 `knowledge_sources_test.exs`。
3. GitHub：
   - 在 `GitHub` 中实现 `fetch_starred/3`，和 `fetch_repo` 共用请求和错误处理。
   - 实现 `Collectors.GithubStars`，在 `:collectors` 中注册。
   - fixture `test/fixtures/github_api/starred.json` 取自真实响应并裁剪。
   - 测试：`github_test.exs`，新增 `collectors/github_stars_test.exs`。
4. Web：
   - 项目详情页加 Sources 表格和待移除 alert。
   - `details_status` 显示待移除徽标。
   - 更新 `knowledge_live_test.exs`，然后提取 gettext。
5. 验证：
   - 运行 format、compile、test。
   - 在 `devenv up` 的环境里新建 "GitHub Stars · gsmlg" 来源并立即采集，确认 2000 多个项目入库，截图来源页和一个项目的 Sources 表格。
