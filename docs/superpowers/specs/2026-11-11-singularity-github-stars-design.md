# GitHub Stars 来源与项目的来源追踪、自动移除

日期：2026-11-11。在 v2 设计（`2026-11-11-singularity-knowledge-v2-design.md`）和手动添加设计（`2026-11-11-singularity-manual-projects-design.md`）之上。取代 v2 中"不做：删除软件项目"：软件项目可以被系统自动移除，规则见下。

## 目标

- 新来源类型 **GitHub Stars**：某个 GitHub 用户 star 的全部仓库成为软件项目。
- 每个软件项目都能看到它是**怎么进入知识库的**：由哪些来源加入、什么时候加入、什么时候离开。
- 用户取消 star 后，如果没有别的来源保留这个项目，项目进入**待移除**状态；30 天内没有任何来源重新加入它，就从知识库中删除。

## 来源归属（item_sources，新表）

| 列 | 说明 |
|---|---|
| `item_id` | 外键，`on_delete: :delete_all` |
| `source_id` | 外键，`on_delete: :delete_all`；`NULL` 表示手动添加 |
| `added_at` | 第一次由这个来源加入的时间 |
| `removed_at` | 这个来源不再列出它的时间；`NULL` 表示仍然有效 |
| timestamps | |

唯一约束 `(item_id, source_id)`，`NULLS NOT DISTINCT`。

- 迁移按现有观测记录回填：每个 `(item_id, source_id)` 一行，`added_at` 取最早的 `observed_at`，全部有效。
- 观测记录（item_observations）不变，仍是每次上榜、每次 star、每次手动添加的事件历史；item_sources 是"现在由谁保留"。

`items` 加一列 `removal_due_at`（utc_datetime，可空，加索引）：项目会在这个时间被删除。

## 规则

- 任何来源写入一个项目（采集或手动添加），都会让这个项目的这条来源归属有效：没有就新建；已离开的，`removed_at` 清空，`added_at` 不变。同时清空项目的 `removal_due_at`。
- 只有**完整列表**型来源会让项目离开。采集结果 `complete: true` 表示条目就是这个来源当前的全部列表。这次没有列出的、原来有效的归属，`removed_at` 设为本次采集时间。
- 项目离开后如果没有任何有效归属，`removal_due_at` 设为离开时间加 30 天。
- 一次性的来源（Trending 上榜、手动添加）永远不会离开：上过 Trending 或手动添加过的项目，取消 star 后仍然保留。
- 每天 03:00（UTC）由 Styx cron 运行 `Singularity.Knowledge.PurgeWorker`，删除 `removal_due_at <= now` 的项目（label、观测、归属随外键一起删除）。
- 防止误删：
  - 采集失败（任一页请求失败、限流）就整次失败，不写入，也不让任何项目离开。
  - `complete: true` 但有无法解析的条目（`skipped > 0`）时，照常写入，但不让任何项目离开。
  - 空结果仍按现有规则算失败（`:no_entries`）。

## 采集框架的改动

- `Singularity.Collector.Result` 加字段 `complete`（默认 `false`）。
- `Singularity.Collector.Entry` 加两个可选字段：
  - `period`：这条观测的期次；为空时用 `Result.period`。Stars 用 star 的日期，同一次 star 只记一条观测。
  - `details`：`Singularity.GitHub.details()`。有值时，`Knowledge.record` 在同一事务里把它当作刚获取的 GitHub 详情保存（同 `put_details`：更新描述、属性、`details_fetched_at`，重算自动 label，`custom_title` 的项目不改名），不再排队获取详情。
- `Knowledge.record/3` 按上面的规则维护 item_sources 和 `removal_due_at`。

## GitHub Stars collector

`Singularity.Collectors.GithubStars`：

- `kind` `"github_stars"`，`label` `"GitHub Stars"`。
- 配置只有一项 `user`，即 GitHub 用户名，必填，格式同 GitHub login。
- 默认间隔 1440 分钟。
- 获取：
  - 由 `Singularity.GitHub.fetch_starred(user, page, opts)` 请求 `GET https://api.github.com/users/:user/starred?per_page=100&page=N`。
  - 请求头 `Accept: application/vnd.github.star+json`，返回的每条记录带 `starred_at` 和完整的仓库 JSON。
  - 有令牌时带令牌（同 `fetch_repo`）。
  - 逐页请求，某页不足 100 条就停止。超过 100 页（1 万个 star）返回错误，不写入部分结果。
  - 错误：
    - 404：`{:error, :not_found}`
    - 限流：`{:error, {:rate_limited, seconds}}`
    - 其他：同 `fetch_repo`
- 解析：纯函数 `parse/2`（输入页面 JSON 列表和用户名），把每条记录转成 Entry：
  - `external_id`、`url` 由 `Address.normalize(full_name)` 得到。
  - `title` 取 `full_name`。
  - `details` 用 `GitHub.parse_repo/1` 解析仓库 JSON。
  - `period` 取 star 日期（`starred_at` 的日期部分）。
  - `observation_attributes` 为 `%{"user" => user, "starred_at" => starred_at}`。
  - `raw` 只存 `full_name` 和 `starred_at`。
  - 字段缺失或地址不合法的记录计入 `skipped`。
- 返回 `%Result{complete: true}`。
- 一次采集就带回了全部详情，所以不会为每个仓库单独请求 GitHub API。2000 多个 star 只需要约 23 次请求，不配置令牌也在限额之内。

## 界面

- 新建来源时可以选 "GitHub Stars"，填用户名，沿用通用的来源表单，不需要专属页面。
- 项目详情页加一张 **"Sources"** 表格，在观测记录表之前。每行一个来源：
  - Source：来源名，手动添加的显示 "Added manually"。
  - Added：加入时间。
  - Status：有效时显示 "Active"，否则显示 "Left on <日期>"。
- 项目详情页：待移除的项目在标题下显示 warning alert："No source keeps this project any more. It will be removed on <日期> unless a source adds it again."
- 列表的 Details 列：待移除的项目额外显示 warning 徽标 "Removal on <日期>"。
- 观测记录表：Stars 的观测记录，期次一列显示 star 日期，排名和本期 star 增量显示 "—"。
- 界面文字全部经 gettext（`knowledge`、`source` domain）。

## 服务函数

- `Knowledge.list_item_sources(item_id)`：项目的来源归属，预加载 source，按 `added_at` 排序。
- `Knowledge.purge_removed(now)`：删除到期项目，返回删除的数量。
- `Knowledge.add_project/2`：写手动归属，清空 `removal_due_at`。

## 测试

- GithubStars：
  - `parse/2` 用真实 API 响应 fixture 测试，覆盖正常、空列表、单条损坏三种情况。
  - `fetch` 用 http_test 覆盖：多页、404、限流、中途某页失败（整次失败）。
  - `validate_config`。
- `Knowledge.record`：
  - 写入归属。
  - 完整列表的离开：设置 `removed_at`，没有其他归属时设置 `removal_due_at`。
  - 有其他归属（Trending、手动）时不进入待移除。
  - 重新加入后清空待移除。
  - `skipped > 0` 时不离开。
  - `details` 被保存且不排队获取详情。
  - Entry 的 `period` 生效。
- `purge_removed`：只删到期项目。
- 迁移回填由 `record` 和 `add_project` 的测试间接覆盖。
- LiveView：详情页的 Sources 表格和待移除提示；列表中的待移除徽标。

## 不做

- 删除来源时让它的项目进入待移除。删除来源时，归属随外键一起删除，项目保留。
- "保留"按钮。要保留一个待移除的项目，就手动添加它。
- 按待移除状态筛选列表。
- `starred:<user>` 这类自动 label。
- 停用来源不触发离开。
