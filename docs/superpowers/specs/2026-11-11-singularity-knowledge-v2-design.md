# Singularity v2：以软件项目为知识的知识库

日期：2026-11-11。取代 v1 设计（`2026-11-09-singularity-collector-v1-design.md`）中与本文冲突的部分；未提到的部分（调度、Styx、部署、上游依赖规则）保持不变。

## 1. 目标

Singularity 是个人知识库，不是采集软件。v2 把 v1 的"采集条目"改成真正的知识：

- 这一版的知识项是**软件项目**，用 git 地址唯一标识。
- 系统通过项目地址从 GitHub 获取软件的详细信息。
- 软件项目上有 **label**，标识语言、主题、来源等信息；label 由系统自动生成，也可手动增删。
- 软件项目进入知识库有两种方式：GitHub Trending 来源（daily / weekly / monthly，可按语言，可建多个），以及手动输入地址添加。
- 界面参照 backplane：顶部 appbar 加分区左侧菜单。

成功标准：

1. 首页（Overview）展示知识库概况和最近加入的软件项目；Knowledge 板块列出全部软件项目，能按 label 筛选、按名称搜索、排序。
2. 手动输入 `owner/repo` 或 GitHub 地址可以添加软件项目，随后自动获取 GitHub 详情和自动 label。
3. Trending 采集到的仓库成为软件项目，项目详情里能看到上榜记录。
4. 项目详情页能增删手动 label，自动更新不会覆盖手动 label。
5. 顶栏有 Overview、Knowledge、Source、System 四个顶级菜单，每个菜单下有自己的一套左侧菜单。
6. 所有 HTTP 请求使用自研的 http_fetch，项目不再依赖 Req。
7. 界面文字全部经 gettext，默认语言是英文。
8. 新版本部署在本机测试环境 http://10.100.10.10:4120/。

## 2. 范围

做：

- 软件项目知识类型、git 地址规范化、GitHub 详情获取、label（自动 + 手动）。
- 手动添加软件项目。
- 把 GithubTrending collector 的产出改成软件项目。
- System：GitHub 访问令牌、只读系统状态。
- 按 backplane 结构重做全部页面。
- HTTP 从 Req 换成 http_fetch / http_test。
- 接入 gettext，界面默认英文。

不做：

- 非 GitHub 的 git 地址（手动添加时提示"暂不支持"）。
- 软件项目以外的知识类型。
- label 的层级、颜色、重命名。
- 全文搜索（只按 `owner/repo` 和描述做 `ILIKE` 匹配）。
- 登录、agent、Hacker News。
- 删除软件项目。

## 3. 数据模型

0.1.0 / v1 的数据可以丢弃。迁移清空 `item_observations`、`items`、`fetch_runs`。

### 3.1 items（软件项目）

沿用 `items` 表，含义收窄为知识项：

- `kind` = `"software_project"`。
- `external_id` = 规范化地址，格式 `github.com/<owner>/<repo>`，全部小写。唯一约束 `(kind, external_id)` 不变。
- `title` = `<owner>/<repo>`，大小写取自 GitHub 返回的 `full_name`；获取详情之前，先用输入的写法。
- `url` = `https://github.com/<owner>/<repo>`。
- `summary` = GitHub 描述。
- `attributes`：GitHub 详情，键为 `stars`、`forks`、`language`、`topics`（列表）、`license`、`homepage`、`archived`、`created_at`、`pushed_at`、`default_branch`。
- 新增 `details_fetched_at`（utc_datetime，可空）：最近一次成功获取详情的时间。
- 新增 `details_error`（text，可空）：最近一次获取失败的原因；成功后清空。

### 3.2 item_labels（新表）

| 列 | 说明 |
|---|---|
| `item_id` | 外键，`on_delete: :delete_all` |
| `name` | label 文本，小写，如 `lang:elixir` |
| `origin` | `"auto"` 或 `"manual"` |
| timestamps | |

唯一约束 `(item_id, name)`，索引 `name`。

规则：

- 同名 label 已是 `manual` 时，自动更新不改它。
- 自动更新只会增删 `origin = "auto"` 的行。

### 3.3 item_observations（来源记录）

- `source_id` 改为可空。
- 手动添加写一条 `source_id = NULL`、`period = 添加日期`、`attributes = %{"via" => "manual"}` 的记录。
- Trending 记录不变：期次、排名、本期 star 增量、`since`。

### 3.4 settings（新表）

键值表，存系统配置：

| 列 | 说明 |
|---|---|
| `key` | string，唯一 |
| `value` | text |
| timestamps | |

这一版只有一个键：`github_token`。

- 运行时读取顺序：settings 表中的值，其次是环境变量 `GITHUB_TOKEN`，都没有就不带令牌。
- 页面只显示令牌是否已设置及其末 4 位，不回显完整令牌。

## 4. 模块

新增或改动的领域模块都在 `apps/singularity`。Web 层只调用上下文的公开函数。

- **`Singularity.Knowledge`**（上下文，扩展）
  - `list_projects(opts)`：`:label`、`:q`、`:sort`（`:recent` 最近加入，或 `:stars`）、`:page`、`:per_page`（默认 30）。
  - `count_projects/0`、`count_projects_since/1`（"本周新增"）、`recent_projects(limit)`（按加入时间）。
  - `get_project!/1`，预载 labels。
  - `list_observations/1`。
  - `add_project(address)`：规范化地址，创建或取回已有项目，写一条手动来源记录，并入队获取详情。返回 `{:ok, item}` 或 `{:error, :unsupported_address | changeset}`。
  - `add_label(item, name)`、`remove_label(item, name)`：只处理手动 label；删除自动 label 返回 `{:error, :auto_label}`。
  - `top_labels(limit)`：按项目数排序。
  - `record/3`（采集写入，见 §6）。
- **`Singularity.Knowledge.Address`**：纯函数 `normalize/1`。
  - 接受 `owner/repo`、`github.com/owner/repo`、`https://github.com/owner/repo`（可带 `.git`、末尾斜杠、`/tree/...` 等路径）、`git@github.com:owner/repo.git`。
  - 返回 `{:ok, %{external_id, owner, repo, url}}` 或 `{:error, :unsupported_address}`。
- **`Singularity.Knowledge.Labels`**：纯函数 `auto_labels(attributes, observation_sinces)`，生成：
  - `lang:<language 小写>`
  - `topic:<topic>`
  - `trending:<since>`
  - `archived`
- **`Singularity.GitHub`**：GitHub REST 客户端，基于 http_fetch。
  - `fetch_repo(owner, repo, opts)`：`GET https://api.github.com/repos/:owner/:repo`，带 `Accept: application/vnd.github+json`、`User-Agent: Singularity`，有令牌时带 `Authorization: Bearer`。返回值：
    - `{:ok, attributes}`
    - `{:error, :not_found}`
    - `{:error, {:rate_limited, retry_after_seconds}}`
    - `{:error, {:http_status, s}}`
    - `{:error, {:transport, msg}}`
  - 解析是纯函数 `parse_repo/1`，用真实 API 响应 fixture 测试。
  - 任何情况都不抛异常。
- **`Singularity.Knowledge.FetchDetailsWorker`**（Styx）
  - 配置：queue `:details`，并发 1；`max_attempts: 5`；`unique: [keys: [:item_id], states: :incomplete]`。
  - 成功：写 `attributes`、`summary`、`title`、`details_fetched_at`，清 `details_error`，重算自动 label。
  - 限流：`{:snooze, retry_after}`。
  - 404：写 `details_error = "repository not found"`，返回 `:ok`，不重试。
  - 其它错误：写 `details_error`，返回 `{:error, reason}`，让 Styx 重试。
  - 完成后在 `"knowledge"` 主题广播 `{:project_updated, item_id}`。
- **`Singularity.Settings`**（新上下文）：`get_github_token/0`、`github_token_status/0`、`put_github_token/1`、`clear_github_token/0`。
- **`Singularity.Collectors.GithubTrending`**（改动）
  - 改用 http_fetch。
  - Entry 的 `item_kind` 改为 `"software_project"`，`external_id` 改为规范化地址。
  - `observation_attributes` 保留 `since`、`stars_in_period`、`rank` 等。
- **`Singularity.System`**（新，只读）：`status/0`，返回应用版本、Styx 各队列中 available、executing、retryable 的任务数。

AGENTS.md 的边界规则相应更新：Web 层可调用 `Sources`、`Knowledge`、`Collection`、`Settings`、`System`。

## 5. 获取详情的时机

- `add_project/1` 新建项目时入队。
- `Knowledge.record/3` 写入 Trending 结果时，对以下项目入队：新项目，以及 `details_fetched_at` 为空或早于 24 小时前的项目。
- 唯一约束保证同一项目同时只有一个获取任务。
- 不配置令牌时，GitHub 限额是每小时 60 次。被限流时任务按 `retry_after` 延后，不丢失。

## 6. 采集写入（Knowledge.record）

在 v1 的基础上：

- 条目 upsert 不覆盖 `attributes`、`summary`、`title`。这些以 GitHub 详情为准；只有新建时用 Trending 页面上的值作初始值。
- 写入观测后，为每个条目加自动 label `trending:<since>`（`origin = "auto"`）。
- 同一事务中插入获取详情任务（`Styx.insert` 在同一 Repo 事务内）。

## 7. 界面

整体结构参照 backplane 的 `backplane_admin`：

- 顶部 `appbar appbar-sticky appbar-primary`：左边品牌名 Singularity，右边四个顶级菜单 **Overview**、**Knowledge**、**Source**、**System**。当前菜单高亮。
- 下方 `dm_left_menu`（sticky）显示当前顶级菜单的那一套左侧菜单。
- 内容区 `max-w-7xl`。
- 组件用 `dm_card`、`dm_stat`、`dm_badge`、`dm_btn`、`dm_input`、`dm_table` 和 `dm_mdi` 图标。

所有列表页订阅相关主题实时更新：项目更新走 `"knowledge"`，采集记录走 `"collection"`。

### 7.1 Overview（首页）

左侧菜单：概览、动态。

- `/` 概览：
  - 四个 `dm_stat`：软件项目总数、本周新增、启用的来源数、最近一次采集状态。
  - "最近加入"卡片列表（12 个，格式同 7.2 的卡片），带"查看全部"链接到 Knowledge。
  - 常用 label 云（前 20 个，点击进入 Knowledge 并按该 label 筛选）。
- `/overview/activity` 动态：按时间倒序的最近 50 条事件，合并以下两类：
  - 软件项目加入（来自来源记录：Trending 或手动）
  - 采集记录

### 7.2 Knowledge（`/knowledge`）

左侧菜单：

- 浏览：全部知识；软件项目（这一版两者相同，为以后的知识类型留位置）。
- 常用 label：按项目数排序的前 12 个，点击即按该 label 筛选。

列表页：

- 工具栏：名称搜索框、排序（最近加入或 star 数）、当前 label 筛选（可清除）。
- 软件项目卡片。每张卡片显示：
  - `owner/repo`，链接到详情
  - 描述
  - star 数、语言
  - label 徽章，手动 label 用另一种样式区分
  - "详情获取中"或"详情获取失败"的状态
- 分页，每页 30 个。

项目详情 `/knowledge/projects/:id`：

- **GitHub 详情卡片**：
  - 描述、主页、GitHub 链接
  - star、fork、语言、license
  - 创建时间、最近推送时间
  - 是否已归档
  - 最近获取时间或错误，加"重新获取"按钮
- **Label 卡片**：
  - 自动 label 只读。
  - 手动 label 可删除。
  - 有一个输入框用来添加 label。
- **来源记录表**：时间、来源（Trending 来源名或"手动添加"）、期次、排名、本期 star 增量。

### 7.3 Source（`/source/...`）

左侧菜单：来源、添加软件项目、采集记录。

- `/source/sources`：来源列表，即 v1 的功能，换成新布局，包括启停、立即采集、实时状态。
- `/source/sources/new`、`/source/sources/:id`、`/source/sources/:id/edit`：v1 的新建、详情和编辑页面，换成新布局。
- `/source/add`：手动添加软件项目，一个地址输入框。
  - 成功后跳转项目详情。
  - 地址不支持时在表单上显示错误。
  - 项目已存在时跳转已有项目，并提示"已在知识库中"。
- `/source/runs`：最近 50 次采集记录，跨所有来源，显示状态、条数、错误。

### 7.4 System（`/system/...`）

左侧菜单：Accounts、Appearance、系统状态。

- `/system/accounts`、`/system/accounts/:account`：外部账户。左边是账户列表（目前只有 GitHub），右边是选中账户的面板：令牌状态（未设置、来自环境变量、已设置 ••••abcd），在 modal 里设置令牌，可以清除令牌。以后的账户只加列表项和面板。
- `/system/appearance`：颜色主题（moonlight、sunshine），在 modal 里选择，保存在 settings 表（key `theme`），根布局据此渲染 `data-theme`。
- `/system/status`：版本、各队列的任务数。

旧路由 `/items/:id` 和 `/sources...` 删除，不做重定向（v1 数据已丢弃）。

### 7.5 语言（gettext）

- 项目当前没有 gettext：给 `singularity_web` 加 `:gettext` 依赖和 `SingularityWeb.Gettext` 后端（`priv/gettext`），在 html_helpers 中 `use Gettext, backend: SingularityWeb.Gettext`。
- 所有界面文字（菜单、标题、按钮、表单标签、提示、flash、校验错误）都通过 gettext 输出。msgid 用英文，默认 locale 为 `en`。
- 本文中的中文界面描述只说明含义，实际文案是英文，例如"最近加入"对应 "Recently added"，"添加软件项目"对应 "Add project"。
- 按区域分 domain：`overview`、`knowledge`、`source`、`system`；通用文字和布局放 `default`；changeset 错误放 `errors`。
- 领域层存进数据库的文字（如 `details_error`、采集错误）用英文。label 文本是数据，不翻译。
- 这一版只提供英文。翻译文件结构就绪，以后加中文只需新增 `.po`，不改代码。
- 不做语言切换界面。

## 8. HTTP：http_fetch

- 依赖：`{:http_fetch, "~> 1.0.0-rc.11"}`；测试用 `{:http_test, "~> 1.0.0-rc.11", only: :test}`。移除 `:req`。
- 用法：`HTTP.fetch(url, headers: ..., adapter: adapter) |> HTTP.Promise.await(timeout)`，再用 `HTTP.Response.json/1` 或 `text/1` 读取响应体。
- adapter 通过应用配置注入，测试环境用 `{HTTP.Test, fixture}`。
- 每个请求设置超时（15 秒），超时和连接错误映射为 `{:error, {:transport, msg}}`。
- http_fetch 是自维护的库（gsmlg-dev/http_fetch）。缺功能或有缺陷时提 issue，不在本地绕过。

## 9. 测试

- **`Address.normalize/1`**：各种地址写法、大小写、非 GitHub 地址。
- **`GitHub.parse_repo/1`**：用真实 API 响应 fixture 测试，覆盖正常、缺字段、归档仓库。
- **`fetch_repo`**：用 http_test 覆盖 200、404、403 限流（带 `x-ratelimit-reset` 或 `retry-after`）和连接错误。
- **`Labels.auto_labels/2`**：纯函数测试。
- **`Knowledge`**：
  - `add_project` 的新建、重复和不支持地址。
  - 手动 label 增删，以及自动更新不覆盖手动 label。
  - `record` 写入时入队获取详情，并加 `trending:` label。
  - `list_projects` 的筛选、搜索、排序和分页。
- **`FetchDetailsWorker`**：成功、404、限流 snooze、其它错误重试。
- **Settings**：令牌读取顺序和掩码显示。
- **LiveView**：
  - 四个顶级菜单的导航和各自的左侧菜单。
  - Overview 统计和最近加入；Knowledge 卡片、label 筛选和搜索。
  - 手动添加流程。
  - 详情页 label 增删。
  - 来源页的原有行为。
  - System 页面。
  - 渲染出的界面文字是英文（gettext 默认 locale）。
- **GithubTrending**：换成 http_test 后，原有测试全部保留。

## 10. 交付

- 验证门槛同 AGENTS.md：format、warnings-as-errors 编译、测试。
- 部署：`deploy/local/deploy.sh`，在 http://10.100.10.10:4120/ 验收以下项目：
  - appbar 加四个顶级菜单和各自的左侧菜单
  - Overview 首页和 Knowledge 列表
  - 手动添加 `elixir-lang/elixir` 并看到详情和 label
  - Trending 采集
  - label 增删
  - System 页面
- AGENTS.md：技术栈改为 http_fetch；边界规则加入 `Settings`、`System`；"当前设计"指向本文。
