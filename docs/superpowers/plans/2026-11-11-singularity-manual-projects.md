# 手动添加软件项目：实施计划

Spec：`docs/superpowers/specs/2026-11-11-singularity-manual-projects-design.md`。

1. `Address.normalize/1` 支持任意 git 地址，返回 `%{external_id, host, path, url, github?}`；更新 `address_test.exs`（GitHub 形式不变，新增 GitLab、自建、ssh、scp，拒绝畸形地址）。`GithubTrending` 只用 `external_id`、`url`，不受影响。
2. 迁移：`items.custom_title`。`Item` schema 加字段。
3. `Knowledge`：
   - `change_manual_project/1`、`add_project/2`（attrs 版）。
   - `details_supported?/1`；`enqueue_details/1` 拒绝非 GitHub。
   - `put_details` 尊重 `custom_title`。
   - 非 GitHub 项目创建时加 `host:` label。
   - `list_manual_projects/1`。
   - `FetchDetailsWorker` 遇到非 GitHub 项目直接取消。

   测试放在 `knowledge_add_project_test.exs`。
4. Web：`SourceLive.Manual`（`/source/manual`）：表格加 modal 表单；删除 `SourceLive.Add` 和 `/source/add`；左侧菜单改名；`details_status` 加 "No automatic details"；`KnowledgeLive.Show` 区分 GitHub 和其他仓库。更新 `source_live_test.exs`、`navigation_test.exs`、`knowledge_live_test.exs`。
5. 验证：format、compile、test、gettext 提取；在 `devenv up` 的本机测试环境（http://10.100.10.10:4120/）截图 Manual 页、modal 和一个 GitLab 项目的详情页。
