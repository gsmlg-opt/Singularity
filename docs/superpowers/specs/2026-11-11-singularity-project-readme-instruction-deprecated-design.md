# 软件项目的 README、介绍（Instruction）和废弃标记

日期：2026-11-11。在 v2 设计、手动添加设计和 GitHub Stars 设计之上。

## 目标

- **README**：每个软件项目都显示项目自己的 README。仓库有 README 就显示，没有就显示"没有 README"。
- **Instruction（介绍）**：由我们自己写的软件介绍，说明这个软件是做什么的。默认为空，现在在项目页手动编辑，以后可能由采集填写，写入同一个字段。
- **废弃（Deprecated）**：项目可以标记为废弃。满足下面任一条件即为废弃：
  - 手动标记（可以写原因，可以撤销）。
  - GitHub 上已归档（`attributes["archived"] == true`，自动，不能手动撤销）。

## 数据

`items` 加列：

| 列 | 说明 |
|---|---|
| `readme` | text，可空。README 原文（Markdown）。`readme_fetched_at` 不为空且这一列为空，表示仓库没有 README |
| `readme_fetched_at` | utc_datetime，可空。最近一次成功获取 README 的时间；为空表示还没获取过 |
| `instruction` | text，可空。我们写的介绍（Markdown），空白保存为 `NULL` |
| `deprecated_at` | utc_datetime，可空。手动标记废弃的时间 |
| `deprecation_reason` | text，可空 |

## README 获取

- `Singularity.GitHub.fetch_readme(owner, repo, opts)`：
  - 请求 `GET /repos/:owner/:repo/readme`，`Accept: application/vnd.github.raw+json`，返回原文。
  - 返回 `{:ok, text}`；404 返回 `{:error, :not_found}`；其他错误同 `fetch_repo`。
  - 原文中无效的 UTF-8 用 `String.replace_invalid/1` 替换。超过 200,000 字符的截断。
- `Singularity.Knowledge.FetchReadmeWorker`（Styx）：
  - 配置：queue `:details`，`max_attempts: 5`，`unique: [keys: [:item_id], states: :incomplete]`。
  - 成功：写 `readme` 和 `readme_fetched_at`。
  - 404：`readme = NULL`，写 `readme_fetched_at`（表示没有 README）。
  - 限流：snooze。
  - 其他错误：交给 Styx 重试。
  - 项目不支持获取（非 GitHub）或已不存在：cancel。
  - 完成后广播 `{:project_updated, id}`。
- 入队时机：
  - 手动添加 GitHub 项目时。
  - 项目页的 "Fetch again"：详情和 README 一起重新获取。
  - `Singularity.Knowledge.ReadmeRefreshWorker`：Styx cron 每小时第 15 分钟运行一次。它为 README 从没获取过、或获取时间早于 30 天的 GitHub 项目入队，每次最多 500 个，先处理从没获取过的。已有的 2000 多个项目由它逐步补齐。
- 非 GitHub 项目没有自动 README。

## 服务函数（Knowledge）

- `deprecated?(item)`：手动标记了废弃，或 GitHub 已归档。
- `deprecate(item, reason)`：写 `deprecated_at` 和原因（空白为 `NULL`）。
- `undeprecate(item)`：清除手动标记，GitHub 归档状态不受影响。
- `change_instruction(item, attrs)`、`update_instruction(item, attrs)`：字段 `instruction`，最长 20,000 字符，空白保存为 `NULL`。
- `put_readme(item, text | nil, now)`。
- `enqueue_readme(item_id)`：非 GitHub 项目返回 `{:error, :details_unsupported}`。
- `enqueue_stale_readmes(now, limit)`。
- `list_projects` 加选项 `:status`：
  - `:active`：未废弃。
  - `:deprecated`：已废弃。
  - 为空：全部。

## 界面

**项目详情页**

- **标题行**：废弃时显示 warning 徽标 "Deprecated"。
  - 页面顶部有一条 warning alert，说明原因：手动标记的显示原因，GitHub 归档的显示 "Archived on GitHub"。
  - 按钮（`outline`）：
    - 未手动标记时显示 "Mark deprecated"，打开 modal，填可选的原因，`primary` "Mark deprecated"。
    - 已手动标记时显示 "Not deprecated"，直接撤销，`data-confirm`。
- **Instruction 卡片**：
  - 有内容时渲染 Markdown；没有时显示 "No instruction yet."。
  - 卡片 action 是 "Edit"（`outline`），打开 modal，modal 里用 Markdown 文本框 `dm_textarea`。
  - 成功后 `push_navigate` 回到本页；校验失败留在 modal 里显示错误。
- **README 卡片**（全宽，放在 Labels 之后、Sources 之前）：
  - 有 README：渲染 Markdown，卡片内限高滚动。
  - 获取过、但没有 README：显示 "This repository has no README."。
  - GitHub 项目，还没获取过：显示 "README not fetched yet."。
  - 非 GitHub 项目：显示 "README is fetched automatically only for GitHub."。
- **Markdown 渲染**：用 `dm_markdown_body`，插件只用 `MDExGFM`，开启 MDEx sanitize（README 来自第三方）。Instruction 也用同样的渲染方式。

**列表**

- 软件项目列表、Manual 列表：Details 列显示 "Deprecated" 徽标（warning）。
- Knowledge 工具栏加 "Status" 下拉：All、Active、Deprecated，对应 URL 参数 `status`。

## 测试

- `GitHub.fetch_readme`：200 返回原文、404、限流、无效 UTF-8 和截断。
- `FetchReadmeWorker`：成功、404、非 GitHub 时 cancel。
- `ReadmeRefreshWorker` 和 `enqueue_stale_readmes`：只为从没获取过或过期的 GitHub 项目入队，有数量上限。
- Knowledge：`deprecated?`、`deprecate`、`undeprecate`（归档项目仍算废弃）、instruction 校验和空白保存为 `NULL`、`list_projects` 的 `status` 选项。
- LiveView：
  - 详情页三种 README 状态，以及 README 中的 `<script>` 被清除。
  - instruction 编辑。
  - 标记废弃和撤销；归档项目显示为废弃，且没有撤销按钮。
  - 列表的 Deprecated 徽标和 Status 筛选。

## 不做

- README 中相对路径的图片和链接改写为绝对地址。
- 非 GitHub 仓库的 README。
- instruction 的自动采集（另写 spec）。
- 废弃项目从知识库中移除或隐藏。
