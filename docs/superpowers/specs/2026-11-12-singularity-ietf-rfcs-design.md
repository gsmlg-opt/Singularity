# IETF RFC 来源

日期：2026-11-12。在 v2（`2026-11-11-singularity-knowledge-v2-design.md`）、手动项目和 GitHub Stars 设计之上。本文取代 v2 "不做"中的"软件项目以外的知识类型"一项，只针对 IETF RFC。

## 1. 目标

IETF RFC 作为单独一类知识条目进入知识库，包含完整元数据和全文。数据从 RFC Editor 官方 rsync 同步，每月检查一次更新。

成功标准：

1. 在 Source 中添加一个 "IETF RFCs" 来源后，首次采集把全部 RFC（约 1 万篇）写成 `ietf_rfc` 知识条目，每篇都有元数据和全文。
2. 之后每月采集一次。rsync 只传输有变化的文件；只有全文真正变化的条目才会更新 `content` 和 `content_updated_at`。
3. Knowledge 左侧菜单有 "IETF RFCs"：列表可搜索、可按 label 筛选；详情页显示元数据、相关 RFC（可跳转）、label 和全文。
4. 同步文件保存在统一配置的数据目录下，以后的其它同步数据也放在这个目录下。
5. Overview 页面（统计、最近加入、label 云、动态）仍然只统计软件项目，不会被 RFC 刷屏。

## 2. 数据目录

所有需要在本地保存同步文件的功能，共用一个数据根目录。

- 配置：`config :singularity, :data_dir`。
  - dev：`<项目根>/tmp/data`（已被 `.gitignore` 的 `/tmp/` 覆盖）。
  - test：`<项目根>/tmp/test-data`。
  - prod：`runtime.exs` 读环境变量 `DATA_DIR`，默认 `/var/lib/singularity`。
- `Singularity.DataDir.path!(name)`：返回 `<data_dir>/<name>`，目录不存在时创建（`File.mkdir_p!`）。`name` 是固定的子目录名，每个功能各用一个。
- 这一版只有一个子目录：`ietf-rfcs`。
- 部署需要把 `DATA_DIR` 挂成持久卷。

## 3. 数据模型

一份 migration。

### 3.1 items 新增通用列

| 列 | 说明 |
|---|---|
| `content` | text，可空。条目的全文。通用列，不专属于 RFC；以后导入的文档也用它 |
| `content_updated_at` | utc_datetime，可空。`content` 最近一次真正变化的时间。内容不变时不写 |

### 3.2 `ietf_rfc` 条目

- `kind` = `"ietf_rfc"`。
- `external_id` = `rfc<编号>`，如 `rfc8446`。
- `title` = JSON 的 `title`。
- `url` = `https://www.rfc-editor.org/rfc/rfc<编号>`。
- `summary` = JSON 的 `abstract`；为空字符串时为 `nil`。
- `published_at` = 发布月份第一天 00:00 UTC。`pub_date` 形如 `"August 2018"`，无法解析时为 `nil`。
- `attributes`（键为字符串）：

| 键 | 来源 |
|---|---|
| `number` | 整数，取自 `doc_id` |
| `authors` | 列表 |
| `status` | `status` |
| `stream_source` | `source`（工作组或来源，如 `"Transport Layer Security"`、`"Legacy"`） |
| `keywords` | 列表 |
| `obsoletes`、`obsoleted_by`、`updates`、`updated_by`、`see_also` | 列表，元素规范化为 `rfc<编号>` 小写 |
| `doi` | `doi` |
| `errata_url` | `errata_url` |
| `page_count` | 整数；无法解析时为 `nil` |
| `draft` | `draft` |
| `formats` | `format` 列表 |

- 自动 label：
  - `status:<slug>`：`status` 转小写，空格换成 `-`，如 `status:proposed-standard`。
  - `obsoleted`：当 `obsoleted_by` 不为空时添加。
  - 关键词不生成 label。
- 来源记录（observation）：`period` = 发布月份 `YYYY-MM`（无法解析时为 `"unknown"`）。唯一约束 `(source_id, item_id, period)` 保证每篇 RFC 对同一来源只有一条记录，每月采集不会新增行。

## 4. 采集框架的改动

### 4.1 `Singularity.Collector.Entry` 新增两个字段

默认都是 `nil`，现有 collector 不受影响。

- `content_path`：这一条的全文文件路径。
- `labels`：字符串列表。不为 `nil` 时，它就是条目全部的自动 label：
  - 不在列表中的 `origin = "auto"` label 删除。
  - 手动 label 不动。
  - 与手动 label 同名时保留手动的。

### 4.2 `Singularity.Knowledge.record/3`

- **采集值是否权威**：
  - 只有 `software_project` 的标题、描述、attributes 以 GitHub 详情为准，保持现状：冲突时只更新 `last_seen_at`、`updated_at`。
  - 其它 kind 的采集值是权威的。冲突时还要覆盖 `title`、`url`、`summary`、`published_at`、`attributes`。
- **写入全文**：
  - 在事务开始时，用一次查询取出本次条目所属 kind 已有条目的 `md5(content)`。
  - 对每个带 `content_path` 的条目逐个读取文件，计算 md5 并与已有值比较。
  - 只有不同时才更新 `content` 和 `content_updated_at = now`。
  - 文件按 UTF-8 读取；不是合法 UTF-8 的字节按 Latin-1 转换（早期 RFC 中有少量非 ASCII 字节），保证写入的是合法文本。
  - 文件读取失败时，这一条不写全文，不中断整个事务，并计入日志。
- **label**：`entry.labels` 不为 `nil` 时，按 4.1 的规则同步自动 label。
- 其余逻辑（keep、leave、observation、软件项目的详情获取）不变。
- **首次写入的规模**：首次写入约 1 万条、约 545 MB 全文。现有事务超时是 10 分钟，Styx Lifeline 在任务执行 30 分钟后会把它救回。实现时在 dev 环境做一次真实的首次同步，记录 rsync 和 `record/3` 各自的耗时。超过任一限制时调大对应的超时，并把实测数据写回本节。

## 5. Collector：`Singularity.Collectors.IetfRfc`

### 5.1 回调

| 回调 | 值 |
|---|---|
| `kind/0` | `"ietf_rfc"` |
| `label/0` | `"IETF RFCs"` |
| `config_fields/0` | `[]` |
| `validate_config/1` | `{:ok, %{}}` |
| `default_interval_minutes/0` | `43_200`（30 天） |
| `queue/0` | `:rfc_editor` |

新队列：`rfc_editor: [limit: 1, rate_limit: [allowed: 1, period: 3600]]`。

### 5.2 获取

`fetch/2` 做两件事：

1. 用 `Singularity.DataDir.path!("ietf-rfcs")` 得到镜像目录。
2. 调用 rsync 运行器同步：

       rsync -rt --delete --timeout=600 \
         --include='rfc*.json' --include='rfc*.txt' --exclude='*' \
         rsync.rfc-editor.org::rfcs/ <镜像目录>/

   只连接一次，元数据和全文来自同一时刻。

- rsync 运行器从应用配置读取：`config :singularity, Singularity.Collectors.IetfRfc, rsync: module`。
  - 默认 `Singularity.Collectors.IetfRfc.Rsync`，用 `System.cmd/3` 调用 `rsync`。
  - 返回 `:ok` 或 `{:error, {:rsync, exit_status, output_tail}}`。
  - 找不到 `rsync` 可执行文件时，返回 `{:error, :rsync_not_found}`。
- rsync 失败时，`fetch/2` 返回 `{:error, reason}`，由 Styx 重试。镜像目录保留，下次续传。

### 5.3 解析（纯函数）

- `parse_dir(dir)` 遍历 `rfc<数字>.json` 文件。`rfcThis.json`、`-n.json` 等不匹配的文件名直接忽略，不计入 skipped。
- 对每个 JSON 调用 `parse_rfc(json_map, txt_path_or_nil)`，生成 `Entry`。
  - 对应的 `rfc<数字>.txt` 存在时，`content_path` 指向它；不存在时为 `nil`。
  - JSON 无法解码或缺少 `doc_id`、`title` 时，计入 `skipped`，不中断。
- 返回 `%Result{period: "YYYY-MM"（采集当月）, entries: entries, skipped: n, complete: true}`。
- `skipped == 0` 时，RFC Editor 不再列出的 RFC 离开来源，适用现有的 30 天删除规则。

### 5.4 注册

- 在 `config :singularity, :collectors` 中加入 `Singularity.Collectors.IetfRfc`。
- 在 test 配置中把 rsync 运行器换成测试替身。

## 6. Knowledge 服务函数

- `list_rfcs(opts)`，选项：
  - `:q`：数字时按编号精确匹配；否则对 `title` 做 ILIKE。
  - `:label`
  - `:page`、`:per_page`（默认 50）
  - 排序：编号倒序
- `count_rfcs(opts)`：与 `list_rfcs` 的筛选条件相同，用于分页。
- `get_rfc!(number)`：按编号取，预载 labels。
- `get_rfcs_by_external_ids(ids)`：给详情页的相关 RFC 用；返回 `%{external_id => item}`，不存在的不返回。
- `add_label/2`、`remove_label/2`：现有函数直接适用于 RFC 条目。

## 7. 界面

按 `DESIGN.md`。文字放 gettext 的 `knowledge` domain。

- Knowledge 左侧菜单在 "Software projects" 后加 "IETF RFCs"。
- `/knowledge/ietf-rfcs` 列表：
  - 工具栏：搜索框（编号或标题）；当前 label 筛选（可清除）。
  - 表格列：编号（`RFC 8446`，链接到详情）、标题、status 徽章、发布日期（月份）。
  - 分页。
- `/knowledge/ietf-rfcs/:number` 详情：
  - 头部：`RFC 8446`、标题、status 徽章；外部链接（原文、DOI、勘误）经过 `/out`。
  - 元数据卡片：作者、工作组（`stream_source`）、发布月份、页数、draft、关键词。
  - 相关 RFC 卡片：
    - 分 Obsoletes、Obsoleted by、Updates、Updated by、See also 五组，空组不显示。
    - 每项链接到对应的详情页；库里没有的 RFC 只显示编号，不加链接。
  - label 卡片：显示自动 label 和手动 label，可增删手动 label。
  - 全文卡片：等宽字体的 `<pre>`，卡片内限高滚动。没有全文时显示 "Full text not synced yet."。
- 订阅 `"knowledge"` 主题；采集完成后列表刷新。
- Overview（统计、最近加入、label 云、动态）不变，继续只统计软件项目。

## 8. 向量搜索的接入点（这一版不实现）

以后的向量搜索使用 Qdrant，另写 spec。这一版只保证以下约定成立：

- 任何 kind 的全文都在 `items.content` 中。
- `content_updated_at` 只在内容真正变化时更新，可以作为增量索引的水位线。索引器记住上次处理到的时间，只处理 `content_updated_at` 晚于它的条目；全量重建时把水位线清零。
- Qdrant 中的 point id 用 `items.id`。条目被删除时，以后由索引器对账清理。

这一版不加 Qdrant 依赖、不加服务、不加任何索引代码。

## 9. 环境与部署

- `devenv.nix` 的 packages 加 `pkgs.rsync`。
- Dockerfile 的运行阶段 `apt-get install` 加 `rsync`。
- 生产环境设置 `DATA_DIR`，并挂载持久卷。

## 10. 测试

- **`Singularity.DataDirTest`**：`path!/1` 返回根目录下的子目录，并且会创建这个目录。
- **`IetfRfc` 解析**：
  - 使用真实 JSON fixture：
    - `rfc8446.json`：字段齐全，包含 obsoletes/obsoleted_by。
    - `rfc791.json`：abstract 为空。
  - 加一个损坏的 JSON 和一个 `rfcThis.json`。
  - 加一个小的 `rfc8446.txt`。
  - 覆盖正常、空目录、单条损坏三种情况。
  - 断言 attributes、自动 label、`period`、`content_path`、`skipped`。
- **`IetfRfc.fetch/2`**：用测试替身运行器把 fixture 复制到镜像目录，覆盖成功和 rsync 失败两种情况。
- **`Knowledge.record/3`**：
  - RFC 元数据在第二次采集时被覆盖（如 `obsoleted_by` 变化）。
  - 内容相同时 `content_updated_at` 不变；内容变化时更新。
  - 非 UTF-8 字节被转换为合法文本。
  - 手动 label 保留，过期的自动 label 被删除。
  - 现有软件项目的测试不改，并且全部通过。
- **LiveView**：
  - 列表搜索（编号和标题）和 label 筛选。
  - 详情页显示元数据。
  - 相关 RFC：库里有的有链接，没有的无链接。
  - 显示全文，或显示未同步提示。
  - 增删手动 label。

## 11. 不做

- 向量搜索、Qdrant、全文搜索（tsvector）。
- HTML、PDF、XML 格式，以及用 xberg 转换。
- Internet-Drafts、勘误内容、BCP/STD/FYI 子系列。
- 把 RFC 混入 "All knowledge" 列表或 Overview 统计。
- 每个来源自定义同步目录。
