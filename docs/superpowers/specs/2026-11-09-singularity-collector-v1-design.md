# Singularity Collector v1 设计

**状态：** 已确认（2026-11-09 brainstorming）
**取代：** 所有 2026-11-09 之前的 Singularity spec、plan、AGENTS.md（已归档到 `archive/*` tag）

## 1. 背景与目标

Singularity 是个人信息聚合与知识保存系统：用户配置信息来源，系统负责收集，沉淀为可回溯的知识条目。来源类型会逐步增加（GitHub Trending → Hacker News → 更多），以后也会有 agent 参与处理信息。

旧实现（Codex 开发的 v0.1 / v0.2 草稿，约 10 万行代码和 172 份流程文档）过度设计，已整体归档。main 从零开始。

**v1 目标：**

1. 建立**与来源类型无关的采集框架**：来源配置、调度、采集执行、条目与观测的存储、浏览 UI。
2. 实现第一种来源类型 **GitHub Trending**。

**成功标准：**

- 新增一种来源类型只需要：一个实现 `Collector` behaviour 的模块、它的测试、在配置中注册一行，以及一个可选的条目展示组件。**不需要数据库 migration，也不需要改动框架代码。**
- 在 UI 中添加 GitHub Trending 来源后，系统按该来源的调度间隔自动采集，也可以手动"立即采集"。
- 同一个外部对象（比如同一个仓库）无论被观测多少次、出现在多少个来源里，都只对应一条条目，观测历史完整。
- 重复采集结果相同，不会产生重复数据。
- 采集失败会显示在 UI 上，不会静默变成"成功 0 条"。

## 2. 范围

**v1 包含：** 采集框架（第 4–7 节），GitHub Trending 来源类型（第 8 节），条目、来源、采集记录的 LiveView 页面，Docker 部署。

**v1 不做：** 登录与权限（部署在内网，依赖反向代理保护）、关键词搜索、阅读状态、收藏、归档、agent 处理、MCP/API 查询接口、GitHub Trending 以外的来源类型实现、条目之间的关联、笔记和文档功能、加密存储、备份格式。

**已规划的下一步（不在 v1 内）：** Hacker News 来源类型。本设计用它来检验扩展性（第 8.2 节），但 v1 不实现它。

**其他预留：**

- **Agent 集成：** 见第 10 节。
- **Hologram：** `duskmoon_hologram` 适合以后对外公开、资源占用低的展示页；v1 的 UI 全部用 LiveView。

## 3. 技术栈与结构

沿用 `gsmlg-opt/backplane` 的惯例：

- Elixir ~> 1.18 umbrella，两个 app：
  - `apps/singularity`：Repo、领域上下文、采集框架、各来源类型的 collector、Styx workers。
  - `apps/singularity_web`：Phoenix 1.8 + LiveView + `phoenix_duskmoon` ~> 10 + `duskmoon_bundler` ~> 10.1。只调用领域上下文的公开函数，不直接访问 Repo。
- PostgreSQL；后台任务用 Styx（自维护的 Oban fork）；HTTP 用 Req ~> 0.5；HTML 解析用 Floki。
- 开发环境用 devenv，部署用 Docker。
- **上游依赖规则：** Styx、phoenix_duskmoon、duskmoon_bundler 都是自维护的库。缺少功能或有 bug 时去对应仓库提 issue，不在本地绕过。

**`apps/singularity` 的模块划分：**

```
Singularity.Sources          来源的增删改查、配置校验、调度（next_run_at）
Singularity.Knowledge        条目与观测：记录、查询、浏览
Singularity.Collection       采集执行：fetch_run 的生命周期、PubSub 广播、workers
Singularity.Collector        behaviour 与注册表（kind → 模块）
Singularity.Collectors.GithubTrending      第一种来源类型
Singularity.Collectors.<Future>            以后的来源类型，比如 HackerNews
```

依赖方向：`Collection` 依赖 `Sources`、`Knowledge` 和 `Collector`；各个 collector 模块只依赖 `Collector` 中定义的数据结构，**不访问 Repo**，也不依赖其他上下文。

## 4. 数据模型（与来源类型无关）

```
sources
  id, kind (string，注册表中的来源类型，例如 "github_trending"),
  name, config jsonb (由该类型自己校验),
  enabled boolean,
  interval_minutes integer (采集间隔，默认值由来源类型提供),
  next_run_at utc_datetime (调度用),
  timestamps

items
  id, kind (string，条目类型，例如 "github_repo"、以后的 "hn_story"),
  external_id (在该 kind 内唯一，例如 "owner/repo"、HN 的 story id),
  title, url, summary, published_at (可为空),
  attributes jsonb (类型特有的最新快照),
  first_seen_at, last_seen_at, timestamps
  unique(kind, external_id)

item_observations
  id, item_id → items, source_id → sources,
  period (string，观测窗口键，由 collector 给出，例如 "2026-11-09"、"2026-11-09T13"),
  observed_at utc_datetime,
  rank integer (可为空),
  attributes jsonb (这次观测时类型特有的指标),
  raw jsonb (这次观测解析出的原始数据),
  unique(source_id, item_id, period)

fetch_runs
  id, source_id → sources, status ("running"|"ok"|"failed"),
  item_count, skipped_count, error text (简短，不含页面内容),
  started_at, finished_at
```

**设计要点：**

- **通用列只放所有来源都有的东西**：标题、链接、摘要、发布时间、排名。类型特有的数据都放进 `attributes` 和 `raw`（jsonb）。新增来源类型不需要 migration。
- **`kind` 是字符串，不是数据库 enum。** 合法值由运行时注册表决定，增加类型不需要改表。
- **幂等的粒度由来源类型决定**：collector 为每次采集给出 `period`。GitHub Trending daily 用日期，以后的 HN 可以用小时。同一个窗口内重复采集会被唯一约束去重。
- **条目按 `(kind, external_id)` 去重，与来源无关。** 每次 upsert 时，`title`、`url`、`summary`、`published_at`、`attributes`、`last_seen_at` 更新为最新值；`first_seen_at` 不变。
- 删除 source 时，它的 observations 和 fetch_runs 级联删除；items 保留，因为它们本身就是知识。

## 5. Collector behaviour 与注册表

新增来源类型的**唯一扩展点**：

```elixir
defmodule Singularity.Collector do
  @type field :: %{name: atom, type: :string | :select | :integer,
                   label: String.t, required: boolean, options: [String.t]}

  # 元数据
  @callback kind() :: String.t()                   # "github_trending"
  @callback label() :: String.t()                  # UI 显示名
  @callback config_fields() :: [field]             # 用来生成来源配置表单
  @callback default_interval_minutes() :: pos_integer()

  # 配置
  @callback validate_config(map()) :: {:ok, map()} | {:error, [{atom, String.t}]}

  # 采集：只负责获取和解析，不访问数据库
  @callback fetch(config :: map(), now :: DateTime.t()) ::
              {:ok, Singularity.Collector.Result.t()} | {:error, term()}
end

# Result: period, entries :: [Entry], skipped :: non_neg_integer
# Entry:  item_kind, external_id, title, url, summary, published_at,
#         item_attributes, rank, observation_attributes, raw
```

- **注册表：** 在 `config :singularity, :collectors` 里列出 collector 模块，`Singularity.Collector.fetch_module(kind)`（返回 `{:ok, module}` 或 `:error`）和 `Singularity.Collector.all()` 从配置读取。测试环境可以注册假的 collector。
- **约定：** 每个 collector 把"HTTP 获取"和"纯函数解析"分开，解析部分用保存下来的真实响应做 fixture 测试。
- 如果来源的 `kind` 已不在注册表中（比如某个类型被移除），这个来源在 UI 里显示为"不可用"，并且不会被调度。

## 6. 调度与采集流程

调度按来源各自进行，不再是全局只跑一次的 cron：

```
Styx.Cron（每分钟）→ ScheduleWorker
  → 找出 enabled 且 next_run_at <= now 的来源
  → 对每个来源：入队 CollectSourceWorker(source_id)，
     并把 next_run_at 推进到 now + interval_minutes

UI "立即采集" → 直接入队 CollectSourceWorker(source_id)

CollectSourceWorker（queue :collect，并发 1，max_attempts 3，
                     同一个 source_id 在 Styx 中保持唯一）
  1. Collection 创建 fetch_run(running)，广播状态
  2. {:ok, collector} = Collector.fetch_module(source.kind)（:error 时任务取消）
  3. collector.fetch(source.config, now)          —— 网络 IO，在事务之外
  4. Knowledge.record(source, result)            —— 单个事务：upsert items，
                                                    insert observations（冲突时跳过）
  5. 把 fetch_run 更新为 ok 或 failed，广播状态
```

- 新建来源时 `next_run_at = now`，所以会立即进行第一次采集。
- 这里只用到 Styx 已有的 cron、worker 和 unique job 能力。如果实现时发现 Styx 缺少需要的能力，就按上游规则提 issue。

**错误处理（框架统一处理，与类型无关）：**

| 情况 | 处理 |
|---|---|
| collector 返回 `{:error, reason}`（网络错误、非 2xx、429 等） | fetch_run 记为 failed，Styx 退避重试（共 3 次） |
| 返回 0 条 entry | 框架把它当作失败（`:no_entries`），因为很可能是页面或接口变了 |
| 单条数据解析失败 | 由 collector 跳过并计入 `skipped`；框架记录 `skipped_count` |
| 同一窗口内重复采集 | 唯一约束加 upsert 保证幂等 |
| 来源被禁用或删除时还有排队中的 job | worker 读取来源后发现不可用，直接结束，不产生 fetch_run |

## 7. UI（LiveView）

布局参考 backplane admin：左侧导航（条目 / 来源），右侧内容，使用 `dm_*` 组件。页面框架与来源类型无关，类型差异只体现在两个地方：**配置表单的字段**和**条目卡片的展示**。

- **`/` 条目：** 按观测时间倒序显示最近被观测到的条目（数据来自 observations），同一条目只显示一次。可按来源、条目类型、日期范围筛选，分页显示。
  - 当只选了一个来源时，显示该来源最近一个 `period` 的完整列表，按 rank 排序，相当于"那一期的榜单"。
- **`/items/:id` 条目详情：** 通用字段（标题、链接、摘要、发布时间、首次和最近一次观测时间），类型特有的信息，以及观测历史表（时间、来源、period、rank、该次观测的指标）。
- **`/sources` 来源：** 列表显示名称、类型、调度间隔、启用开关、最近一次 fetch_run 的状态。新建来源时先选择类型，表单字段由该类型的 `config_fields/0` 生成，校验调用 `validate_config/1`。支持编辑、删除；每个来源有"立即采集"按钮。
- **`/sources/:id` 来源详情：** 配置信息和最近 20 条 fetch_run，失败的显示错误信息。
- **条目展示组件：** `SingularityWeb.ItemComponents` 先显示通用信息（标题、链接、摘要），再根据 `item.kind` 分派到类型专属的函数组件，比如 `github_repo` 显示语言、star、fork、区间新增 star。**没有专属组件的 kind 回退到通用展示**，所以新增来源类型时，即使不写 UI 也能正常浏览。
- **实时刷新：** `Singularity.Collection` 在 fetch_run 状态变化时通过 PubSub 广播；LiveView 只在 `connected?/1` 分支中订阅。

## 8. 来源类型

### 8.1 GitHub Trending（v1 实现）

- `kind`：`"github_trending"`；条目 kind：`"github_repo"`；`external_id`：`"owner/repo"`。
- `config_fields`：`language`（字符串，可为空，空表示全部语言），`since`（下拉选择 daily / weekly / monthly）。
- `default_interval_minutes`：1440（每天一次）。
- `fetch`：请求 `https://github.com/trending[/<language>]?since=<since>`，请求头为 `User-Agent: Singularity`；`period` 取 `now` 的 UTC 日期（`"2026-11-09"`）。
- 解析（纯函数，用 Floki）：排名、`owner/repo`、描述、语言、总 star、fork、区间新增 star。
- `item_attributes`：`{language, stars, forks}`；`observation_attributes`：`{stars, forks, stars_in_period, since}`。
- 首次启动时，如果没有任何来源，就创建一个默认来源："GitHub Trending · All languages · daily"。

### 8.2 扩展性检验：Hacker News（下一版，仅用于验证本设计）

| 需要的东西 | 在本框架中如何满足 |
|---|---|
| 每小时采集首页 | `default_interval_minutes: 60`，`period` 用 `"2026-11-09T13"` |
| story 去重 | 条目 kind `"hn_story"`，`external_id` 用 HN 的 id |
| points、评论数、作者 | 放进 `item_attributes` 或 `observation_attributes`，不需要 migration |
| 发布时间 | 通用列 `published_at` |
| 配置（比如 top / new / best，最低 points） | `config_fields` 加 `validate_config` |
| 展示 | 可选的 `hn_story` 条目组件；不写也能用通用展示 |

**结论：** 加入 HN 只需要新增一个 collector 模块、fixture 测试、一行配置注册，以及一个可选的展示组件。

**已知但暂不处理：** 一个 HN story 链接到一个 GitHub 仓库时，它们是两条不同 kind 的条目。以后需要关联时，再加一张 `item_links` 表，现有表不需要改。

## 9. 新增来源类型的检查清单

1. 在 `Singularity.Collectors.<Name>` 实现 `Singularity.Collector` 的全部回调。
2. 把"获取"和"解析"分开；解析部分用真实响应的 fixture 测试，覆盖正常、空结果、单条损坏三种情况。
3. 在 `config :singularity, :collectors` 中注册。
4. （可选）在 `SingularityWeb.ItemComponents` 中加一个 kind 专属的展示组件。
5. 不需要 migration，也不需要改动框架代码。如果确实需要改，说明框架有缺陷，应该先更新本 spec。

## 10. Agent 集成预留（v1 不实现）

- **清晰的边界：** 所有读写都通过 `Sources`、`Knowledge`、`Collection` 的公开函数。以后的 MCP 工具或 agent 适配器调用同一组函数。
- **原始数据保留：** `item_observations.raw` 和 `attributes` 保存完整的解析结果，以后可以重新处理。
- **任务链：** 以后的 agent 处理（比如总结、打标签、关联）作为 `Knowledge.record` 之后的 Styx job 接入，产出写进新表（例如 `item_annotations`），现有表不需要改。
- **agent 本身也可以是一种来源：** 由 agent 驱动的采集同样可以实现 `Collector` behaviour，复用同一套调度、存储和 UI。

## 11. 测试与验证

- **框架（使用假 collector）：** 注册表的查找与"不可用"处理；调度（到期判断、`next_run_at` 推进、禁用的来源不被调度）；fetch_run 的状态流转；返回 0 条时视为失败；单条跳过的计数；PubSub 广播。
- **领域（DataCase，真实 PostgreSQL）：** upsert 幂等、跨来源去重、同一 period 内重复采集、不同 period 各自记录、`first_seen_at` 与 `last_seen_at` 的语义、删除来源时的级联行为、默认来源。
- **GitHub Trending：** `validate_config`；用 fixture 测试解析（全部语言、指定语言、0 条结果、单行损坏）；用 `Req.Test` 测试 `fetch` 拼出的 URL 和 period。
- **UI（`Phoenix.LiveViewTest`）：** 条目列表和筛选、单个来源的那一期列表、详情页的观测历史、按类型生成的来源表单和校验错误、立即采集、收到 PubSub 后刷新、未知 kind 回退到通用展示。
- **测试中不访问真实网络。** 手动冒烟测试用 `mix singularity.collect <source_id>`。
- **验证门槛：** `mix format --check-formatted`、`mix compile --warnings-as-errors`、`mix test`。CI 跑这三项，再加 Docker 构建。

## 12. 流程约定

- 一个功能对应一份 spec 和一份 plan，完成后统一 review 一次。新增来源类型如果符合第 9 节的清单，只需要写一份简短的 plan，不需要新的 spec。
- 不产生回执文件、SHA 清单，也不做切片级的多重审查。证据就是 git commit 和测试结果。
- 直接在 main 上开发，除非用户明确要求，否则不创建分支或 worktree。
- 坚持 YAGNI：第 2 节中"不做"的内容，必须先有新的 spec 才能开始。

## 13. 旧代码归档（实施的第一步）

1. 把 Phase 5 worktree 中 12 个未提交的文件、Phase 2 worktree 中 1 个未跟踪的 plan 文档，分别在各自分支上提交为 `wip:` commit。
2. 打 tag：`archive/main-2026-11-09`（`e866990`）、`archive/phase-2-import-extraction`、`archive/phase-2-verification`、`archive/phase-3-search`、`archive/phase-4-knowledge-links`、`archive/phase-5-export-backup`；原有的 `v0.1.0` 保留。
3. 推送 tag 到 origin（执行前需要用户确认）。
4. 确认远端 tag 都在之后，删除 `.trees/*` worktree 和对应的本地分支；是否删除远端 `codex/*` 分支，单独询问用户。
5. 在 main 上删除旧代码和文档，写一份简短的新 `AGENTS.md`（范围、技术栈、第 3 节的上游规则、第 9 节的扩展清单、第 12 节的流程约定、验证命令），把本 spec 作为第一份文档提交。
