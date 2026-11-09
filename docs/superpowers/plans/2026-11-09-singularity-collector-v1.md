# Singularity Collector v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 归档 Codex 时代的旧代码，在 main 上重建一个与来源类型无关的信息采集框架，并实现第一种来源类型 GitHub Trending。

**Architecture:** 两个 app 的 umbrella：`apps/singularity` 放领域代码（Sources / Knowledge / Collection 三个上下文、`Collector` behaviour 与注册表、Styx workers），`apps/singularity_web` 放 Phoenix LiveView + phoenix_duskmoon UI，只调用领域上下文。新增来源类型只需实现 `Collector` behaviour 并在配置中注册。

**Tech Stack:** Elixir ~> 1.18 / OTP 28，Phoenix 1.8 + LiveView，phoenix_duskmoon ~> 10，duskmoon_bundler ~> 10.1，PostgreSQL 17，Styx ~> 0.1.1（自维护的 Oban fork），Req ~> 0.5，Floki。

**Spec:** `docs/superpowers/specs/2026-11-09-singularity-collector-v1-design.md`

---

## 执行约定

- 直接在 `main` 上工作，不创建分支或 worktree（Task 1 只删除旧的 worktree）。
- 所有 `mix`、`psql` 命令都在 devenv 环境中执行：先 `devenv up -d` 启动 PostgreSQL，再用 `devenv shell -- <cmd>`，或者先进入 `devenv shell`。
- 每个 Task 结束时，`mix test` 必须全部通过再提交。commit message 不加 "Generated with Claude Code"，也不加 Co-Authored-By。
- Styx、phoenix_duskmoon、duskmoon_bundler 都是自维护的库。如果遇到它们的缺陷或缺少功能，**停下来**，按 upstream-issue-routing 去对应仓库提 issue，不在本地绕过。
- 不新增本计划以外的流程文档、回执或清单。

## 文件结构

```
apps/singularity/
  lib/singularity/
    collector.ex                     behaviour + 注册表
    collector/entry.ex               Entry 结构
    collector/result.ex              Result 结构
    collectors/github_trending.ex    第一种来源类型
    sources.ex                       Sources 上下文
    sources/source.ex                Source schema
    knowledge.ex                     Knowledge 上下文（record + 浏览查询）
    knowledge/item.ex                Item schema
    knowledge/observation.ex         Observation schema
    collection.ex                    Collection 上下文（run、PubSub、runs 查询）
    collection/fetch_run.ex          FetchRun schema
    collection/collect_source_worker.ex
    collection/schedule_worker.ex
    release.ex
  lib/mix/tasks/singularity.collect.ex
  priv/repo/migrations/*_add_styx_jobs.exs
  priv/repo/migrations/*_create_collector_tables.exs
  priv/repo/seeds.exs
  test/support/fixtures.ex           Singularity.Fixtures
  test/support/fake_collector.ex     Singularity.Test.FakeCollector
  test/fixtures/github_trending/minimal.html, daily.html
  test/singularity/*_test.exs
apps/singularity_web/
  lib/singularity_web/components/layouts.ex      （修改 app/1）
  lib/singularity_web/components/item_components.ex
  lib/singularity_web/live/item_live/index.ex, show.ex
  lib/singularity_web/live/source_live/index.ex, form.ex, show.ex
  lib/singularity_web/router.ex                   （修改）
  test/singularity_web/live/item_live_test.exs, source_live_test.exs
rel/overlays/bin/server, rel/overlays/bin/migrate
Dockerfile, .dockerignore, .github/workflows/ci.yml
AGENTS.md, README.md, devenv.nix
```

---

### Task 1: 归档旧工作

**Files:** 无代码改动，只操作 git。

- [ ] **Step 1: 确认 worktree 状态**

Run:
```bash
git worktree list
for wt in .trees/*; do echo "== $wt"; git -C "$wt" status --short; done
```
Expected：`v0.2-phase-5-export-backup` 有 3 个修改文件和 9 个未跟踪路径；`v0.2-phase-2-import-extraction` 有 1 个未跟踪的 plan 文档；其余的 worktree 是干净的。如果和这里不一致，停下来报告。

- [ ] **Step 2: 把未提交的内容提交为 WIP**

```bash
git -C .trees/v0.2-phase-5-export-backup add -A
git -C .trees/v0.2-phase-5-export-backup commit -m "wip: preserve uncommitted phase 5 task 18 work before archive"
git -C .trees/v0.2-phase-2-import-extraction add -A
git -C .trees/v0.2-phase-2-import-extraction commit -m "wip: preserve untracked phase 2 plan before archive"
```

- [ ] **Step 3: 打归档 tag**

```bash
git tag -a archive/main-2026-11-09 e866990 -m "Archive: Codex-era main before collector rewrite"
git tag -a archive/phase-2-import-extraction codex/v0.2-phase-2-import-extraction -m "Archive: Codex v0.2 phase 2"
git tag -a archive/phase-2-verification codex/v0.2-phase-2-verification -m "Archive: Codex v0.2 phase 2 verification"
git tag -a archive/phase-3-search codex/v0.2-phase-3-search-design -m "Archive: Codex v0.2 phase 3"
git tag -a archive/phase-4-knowledge-links codex/v0.2-phase-4-knowledge-links -m "Archive: Codex v0.2 phase 4"
git tag -a archive/phase-5-export-backup codex/v0.2-phase-5-export-backup -m "Archive: Codex v0.2 phase 5"
git tag -l 'archive/*' -n1
```
Expected：列出 6 个 tag。

- [ ] **Step 4: 推送 tag（推送前必须先得到用户确认）**

向用户确认后再执行：
```bash
git push origin 'refs/tags/archive/*'
git ls-remote --tags origin 'refs/tags/archive/*'
```
Expected：远端能看到 6 个 `archive/*` tag（`^{}` 解引用的行除外）。

- [ ] **Step 5: 删除本地 worktree 和分支**

只有在 Step 4 的远端校验通过之后才执行：
```bash
for wt in .trees/*; do git worktree remove "$wt"; done
git worktree prune
git branch -D codex/v0.2-phase-2-import-extraction codex/v0.2-phase-2-verification \
  codex/v0.2-phase-3-search-design codex/v0.2-phase-4-knowledge-links codex/v0.2-phase-5-export-backup
git worktree list
```
Expected：只剩下主 worktree。如果 `git worktree remove` 因为存在被忽略的文件而拒绝执行，先用 `git -C <wt> status --short` 确认没有未提交的内容，再加 `--force`。

- [ ] **Step 6: 询问远端分支**

询问用户是否删除远端的 `origin/codex/v0.2-phase-1-canonical-model` 和 `origin/codex/v0.2-phase-2-import-extraction`。只有用户同意后才执行 `git push origin --delete <branch>`。

---

### Task 2: 清空 main，写新的 AGENTS.md 和 README

**Files:**
- Delete: 所有旧的跟踪文件，保留 `devenv.nix`、`devenv.yaml`、`devenv.lock`、`.gitignore`
- Create: `AGENTS.md`、`README.md`
- Modify: `devenv.nix`、`.gitignore`
- Commit: spec 和本 plan

- [ ] **Step 1: 删除旧的跟踪文件**

```bash
git rm -r -q AGENTS.md apps build config Dockerfile .dockerignore docs .formatter.exs .github \
  mix.exs mix.lock package.json package-lock.json playwright.config.ts README.md rel test \
  tsconfig.json vitest.config.ts
rm -rf _build deps node_modules apps
git ls-files
git status --short
```
Expected：`git ls-files` 只剩下 `.gitignore`、`devenv.lock`、`devenv.nix`、`devenv.yaml`；`git status` 中，未跟踪文件只有 `docs/superpowers/specs/2026-11-09-singularity-collector-v1-design.md` 和 `docs/superpowers/plans/2026-11-09-singularity-collector-v1.md`。

- [ ] **Step 2: 清理旧的数据库**

```bash
devenv up -d
devenv shell -- psql -d postgres -Atc "select datname from pg_database where datname like 'singularity%'"
```
查看输出的数据库名，然后逐个删除：
```bash
devenv shell -- psql -d postgres -c 'DROP DATABASE IF EXISTS "<name>"'
```
（旧库里的数据是 Codex 时代的测试数据，用户已确认可以丢弃。）

- [ ] **Step 3: 精简 devenv.nix**

```nix
{ pkgs, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  packages = with pkgs-stable; [
    git
    beam28Packages.elixir-ls
    nodejs_24
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
  };
}
```

- [ ] **Step 4: 精简 .gitignore**

```gitignore
/_build/
/cover/
/deps/
/doc/
erl_crash.dump
*.ez
/tmp/
/.elixir_ls/
/.devenv/
/.direnv/
/node_modules/
/apps/singularity_web/priv/static/assets/
/apps/singularity_web/priv/static/cache_manifest.json
```

- [ ] **Step 5: 写新的 AGENTS.md**

```markdown
# Singularity

自托管的个人信息采集与知识保存系统。用户配置信息来源，系统负责收集，沉淀为可回溯的知识条目。

当前设计：`docs/superpowers/specs/2026-11-09-singularity-collector-v1-design.md`。

## 技术栈

- Elixir umbrella：`apps/singularity`（领域与采集），`apps/singularity_web`（Phoenix LiveView + phoenix_duskmoon）。
- PostgreSQL；后台任务用 Styx（自维护的 Oban fork）；HTTP 用 Req；HTML 解析用 Floki。
- `singularity_web` 只调用 `Singularity.Sources`、`Singularity.Knowledge`、`Singularity.Collection` 的公开函数，不直接访问 Repo。

## 新增来源类型

1. 在 `Singularity.Collectors.<Name>` 实现 `Singularity.Collector` 的全部回调。
2. 把"获取"和"纯函数解析"分开；解析部分用真实响应的 fixture 测试，覆盖正常、空结果、单条损坏三种情况。
3. 在 `config :singularity, :collectors` 中注册。
4. （可选）在 `SingularityWeb.ItemComponents` 中加一个 kind 专属的展示组件。

如果新增类型时必须改框架或加 migration，说明框架有缺陷，要先更新 spec。

## 上游依赖

Styx、phoenix_duskmoon、duskmoon_bundler 都是自维护的库。遇到缺陷或缺少功能时，去对应仓库提 issue，不在本地绕过。

## 流程

- 一个功能对应一份 spec 和一份 plan，完成后统一 review 一次。符合"新增来源类型"清单的工作只需要一份简短的 plan。
- 不产生回执文件、SHA 清单，也不做切片级的多重审查。
- 直接在 main 上开发，除非用户明确要求，否则不创建分支或 worktree。
- YAGNI：spec 中列为"不做"的内容，必须先有新的 spec 才能开始。

## 验证

    devenv up -d
    devenv shell -- mix format --check-formatted
    devenv shell -- mix compile --warnings-as-errors
    devenv shell -- mix test
```

- [ ] **Step 6: 写新的 README.md**

```markdown
# Singularity

Self-hosted personal information collector. Configure sources in the web UI;
Singularity collects them on a schedule and keeps every observation as a
browsable knowledge item.

First source type: GitHub Trending.

## Development

    devenv up -d
    devenv shell -- mix setup
    devenv shell -- mix phx.server

Open http://localhost:4000.

Collect one source immediately: `devenv shell -- mix singularity.collect <source_id>`.

See `AGENTS.md` for conventions and `docs/superpowers/specs/` for the design.
```

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "chore: archive Codex-era implementation and restart as collector

The previous implementation is preserved under archive/* tags."
```

---

### Task 3: 生成 umbrella 骨架并接入 duskmoon UI

**Files:** 由 `mix phx.new` 生成；然后由 setup-phoenix-duskmoon skill 修改前端工具链。

- [ ] **Step 1: 生成项目**

```bash
devenv shell -- mix archive.install hex phx_new 1.8.16 --force
rm -rf /tmp/singularity_umbrella
(cd /tmp && devenv shell -- mix phx.new singularity --umbrella --no-mailer --no-gettext --no-dashboard --no-install)
rsync -a --exclude .gitignore /tmp/singularity_umbrella/ ./
cat /tmp/singularity_umbrella/.gitignore
```
注意：`devenv shell` 要从仓库根目录执行。如果在 `/tmp` 里没有 devenv 环境，就先进入 `devenv shell`，再在 shell 里执行 `cd /tmp && mix phx.new ...`。把生成的 `.gitignore` 里本仓库 `.gitignore` 还没有的条目补进去。

- [ ] **Step 2: 让数据库配置兼容 devenv 的 Unix socket**

devenv 的 PostgreSQL 通过 `PGHOST`（socket 目录）访问，而 CI 使用 `localhost` 加 `postgres/postgres`。在 `config/dev.exs` 中，把生成的 `config :singularity, Singularity.Repo, username: ..., password: ..., hostname: ...` 替换为：

```elixir
pg_conn =
  case System.get_env("PGHOST") do
    nil -> [hostname: "localhost", username: "postgres", password: "postgres"]
    socket_dir -> [socket_dir: socket_dir, username: System.get_env("USER")]
  end

config :singularity,
       Singularity.Repo,
       pg_conn ++
         [
           database: "singularity_dev",
           stacktrace: true,
           show_sensitive_data_on_connection_error: true,
           pool_size: 10
         ]
```

`config/test.exs` 做同样的处理：

```elixir
pg_conn =
  case System.get_env("PGHOST") do
    nil -> [hostname: "localhost", username: "postgres", password: "postgres"]
    socket_dir -> [socket_dir: socket_dir, username: System.get_env("USER")]
  end

config :singularity,
       Singularity.Repo,
       pg_conn ++
         [
           database: "singularity_test#{System.get_env("MIX_TEST_PARTITION")}",
           pool: Ecto.Adapters.SQL.Sandbox,
           pool_size: System.schedulers_online() * 2
         ]
```

- [ ] **Step 3: 验证生成的项目**

```bash
devenv shell -- mix deps.get
devenv shell -- mix ecto.create
devenv shell -- mix test
```
Expected：所有生成的测试都通过。

- [ ] **Step 4: 接入 duskmoon UI**

调用 skill `phoenix-tools:setup-phoenix-duskmoon`，作用于 `apps/singularity_web`。目标：tailwindcss v4、duskmoon_bundler ~> 10.1、phoenix_duskmoon ~> 10，`SingularityWeb` 的 html_helpers 中包含 `use PhoenixDuskmoon.Component`，并参考 `../backplane/apps/backplane_admin` 的配置（`assets/css/app.css` 引入 `@duskmoon-dev/core`，主题使用 sunshine 和 moonlight）。

验收：
```bash
devenv shell -- mix assets.build
devenv shell -- mix test
devenv shell -- mix compile --warnings-as-errors
```
Expected：资源构建成功，测试通过，没有编译警告；`mix phx.server` 打开 http://localhost:4000 能看到使用 duskmoon 样式的默认首页。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add -A
git commit -m "feat: scaffold umbrella with phoenix_duskmoon UI"
```

---

### Task 4: 接入 Styx、Req 和 Floki

**Files:**
- Modify: `apps/singularity/mix.exs`、`config/config.exs`、`config/test.exs`、`apps/singularity/lib/singularity/application.ex`
- Create: `apps/singularity/priv/repo/migrations/<ts>_add_styx_jobs.exs`

- [ ] **Step 1: 添加依赖**

在 `apps/singularity/mix.exs` 的 `deps/0` 中加入：
```elixir
      {:styx, "~> 0.1.1"},
      {:req, "~> 0.5"},
      {:floki, ">= 0.30.0"}
```
Run: `devenv shell -- mix deps.get`

- [ ] **Step 2: 配置 Styx**

在 `config/config.exs` 中，紧接 `config :singularity, ecto_repos: ...` 之后加入：
```elixir
config :singularity, Styx,
  repo: Singularity.Repo,
  queues: [default: 5, collect: 1],
  plugins: [{Styx.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]
```

在 `config/test.exs` 中加入：
```elixir
config :singularity, Styx, testing: :manual
```

- [ ] **Step 3: 启动 Styx**

在 `apps/singularity/lib/singularity/application.ex` 的 children 列表中，紧接 `Singularity.Repo` 之后加入：
```elixir
      {Styx, Application.fetch_env!(:singularity, Styx)},
```

- [ ] **Step 4: 生成 Styx 的数据表 migration**

```bash
(cd apps/singularity && devenv shell -- mix ecto.gen.migration add_styx_jobs)
```
把生成的文件内容替换为：
```elixir
defmodule Singularity.Repo.Migrations.AddStyxJobs do
  use Ecto.Migration

  def up, do: Styx.Migrations.up()
  def down, do: Styx.Migrations.down(version: 1)
end
```

- [ ] **Step 5: 验证**

```bash
devenv shell -- mix ecto.migrate
devenv shell -- mix test
```
Expected：migration 成功，测试通过。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: add Styx job processing"
```

---

### Task 5: 数据表与 schema

**Files:**
- Create: `apps/singularity/priv/repo/migrations/<ts>_create_collector_tables.exs`
- Create: `apps/singularity/lib/singularity/sources/source.ex`、`knowledge/item.ex`、`knowledge/observation.ex`、`collection/fetch_run.ex`
- Create: `apps/singularity/test/support/fixtures.ex`
- Test: `apps/singularity/test/singularity/schema_test.exs`

- [ ] **Step 1: 写 migration**

```bash
(cd apps/singularity && devenv shell -- mix ecto.gen.migration create_collector_tables)
```
内容：
```elixir
defmodule Singularity.Repo.Migrations.CreateCollectorTables do
  use Ecto.Migration

  def change do
    create table(:sources) do
      add :kind, :string, null: false
      add :name, :string, null: false
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :interval_minutes, :integer, null: false
      add :next_run_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:sources, [:enabled, :next_run_at])

    create table(:items) do
      add :kind, :string, null: false
      add :external_id, :string, null: false
      add :title, :text, null: false
      add :url, :text, null: false
      add :summary, :text
      add :published_at, :utc_datetime
      add :attributes, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:kind, :external_id])
    create index(:items, [:last_seen_at])

    create table(:item_observations) do
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :observed_at, :utc_datetime, null: false
      add :rank, :integer
      add :attributes, :map, null: false, default: %{}
      add :raw, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:item_observations, [:source_id, :item_id, :period])
    create index(:item_observations, [:item_id])
    create index(:item_observations, [:observed_at])

    create table(:fetch_runs) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :item_count, :integer, null: false, default: 0
      add :skipped_count, :integer, null: false, default: 0
      add :error, :text
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
    end

    create index(:fetch_runs, [:source_id, :started_at])
  end
end
```

- [ ] **Step 2: 写 schema**

`apps/singularity/lib/singularity/sources/source.ex`（changeset 在 Task 7 中添加）：
```elixir
defmodule Singularity.Sources.Source do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "sources" do
    field :kind, :string
    field :name, :string
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true
    field :interval_minutes, :integer
    field :next_run_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
```

`apps/singularity/lib/singularity/knowledge/item.ex`：
```elixir
defmodule Singularity.Knowledge.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @required [:kind, :external_id, :title, :url, :first_seen_at, :last_seen_at]

  schema "items" do
    field :kind, :string
    field :external_id, :string
    field :title, :string
    field :url, :string
    field :summary, :string
    field :published_at, :utc_datetime
    field :attributes, :map, default: %{}
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    has_many :observations, Singularity.Knowledge.Observation
    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required ++ [:summary, :published_at, :attributes])
    |> validate_required(@required)
    |> unique_constraint([:kind, :external_id])
  end
end
```

`apps/singularity/lib/singularity/knowledge/observation.ex`：
```elixir
defmodule Singularity.Knowledge.Observation do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @required [:item_id, :source_id, :period, :observed_at]

  schema "item_observations" do
    belongs_to :item, Singularity.Knowledge.Item
    belongs_to :source, Singularity.Sources.Source
    field :period, :string
    field :observed_at, :utc_datetime
    field :rank, :integer
    field :attributes, :map, default: %{}
    field :raw, :map, default: %{}
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, @required ++ [:rank, :attributes, :raw])
    |> validate_required(@required)
    |> unique_constraint([:source_id, :item_id, :period])
  end
end
```

`apps/singularity/lib/singularity/collection/fetch_run.ex`：
```elixir
defmodule Singularity.Collection.FetchRun do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "fetch_runs" do
    belongs_to :source, Singularity.Sources.Source
    field :status, :string
    field :item_count, :integer, default: 0
    field :skipped_count, :integer, default: 0
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
  end
end
```

- [ ] **Step 3: 写测试 fixture**

`apps/singularity/test/support/fixtures.ex`：
```elixir
defmodule Singularity.Fixtures do
  @moduledoc "Direct-insert fixtures that bypass context validation."

  alias Singularity.Collection.FetchRun
  alias Singularity.Repo
  alias Singularity.Sources.Source

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def source_fixture(attrs \\ %{}) do
    defaults = %{
      kind: "fake",
      name: "Fake source",
      config: %{"topic" => "t"},
      enabled: true,
      interval_minutes: 60,
      next_run_at: now()
    }

    Source |> struct!(Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end

  def fetch_run_fixture(%Source{} = source, attrs \\ %{}) do
    defaults = %{source_id: source.id, status: "ok", item_count: 1, started_at: now(), finished_at: now()}
    FetchRun |> struct!(Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end
end
```

- [ ] **Step 4: 写测试（约束是否生效）**

`apps/singularity/test/singularity/schema_test.exs`：
```elixir
defmodule Singularity.SchemaTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Knowledge.{Item, Observation}
  alias Singularity.Repo

  defp item_attrs(external_id) do
    %{kind: "fake_item", external_id: external_id, title: "T", url: "https://example.test",
      first_seen_at: now(), last_seen_at: now()}
  end

  test "items are unique per kind and external_id" do
    Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    assert {:error, changeset} = Repo.insert(Item.changeset(%Item{}, item_attrs("a")))
    assert %{kind: ["has already been taken"]} = errors_on(changeset)
  end

  test "observations are unique per source, item and period; deleting a source cascades" do
    source = source_fixture()
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    attrs = %{item_id: item.id, source_id: source.id, period: "2026-11-09", observed_at: now()}

    Repo.insert!(Observation.changeset(%Observation{}, attrs))
    assert {:error, _} = Repo.insert(Observation.changeset(%Observation{}, attrs))

    fetch_run_fixture(source)
    Repo.delete!(source)

    assert Repo.aggregate(Observation, :count) == 0
    assert Repo.aggregate(Singularity.Collection.FetchRun, :count) == 0
    assert Repo.get(Item, item.id)
  end
end
```

- [ ] **Step 5: 运行测试**

Run: `devenv shell -- mix ecto.migrate && devenv shell -- mix test apps/singularity/test/singularity/schema_test.exs`
Expected：2 个测试通过。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: add source, item, observation and fetch run tables"
```

---

### Task 6: Collector behaviour、数据结构与注册表

**Files:**
- Create: `apps/singularity/lib/singularity/collector.ex`、`collector/entry.ex`、`collector/result.ex`
- Create: `apps/singularity/test/support/fake_collector.ex`
- Modify: `config/config.exs`、`config/test.exs`
- Test: `apps/singularity/test/singularity/collector_test.exs`

- [ ] **Step 1: 写失败的测试**

`apps/singularity/test/singularity/collector_test.exs`：
```elixir
defmodule Singularity.CollectorTest do
  use ExUnit.Case, async: true

  alias Singularity.Collector

  test "fetch_module/1 resolves registered kinds" do
    assert {:ok, Singularity.Test.FakeCollector} = Collector.fetch_module("fake")
    assert :error = Collector.fetch_module("unknown")
  end

  test "all/0 lists registered collectors" do
    assert Singularity.Test.FakeCollector in Collector.all()
  end
end
```

Run: `devenv shell -- mix test apps/singularity/test/singularity/collector_test.exs`
Expected：FAIL，提示 `Singularity.Collector` 未定义。

- [ ] **Step 2: 实现 behaviour 和数据结构**

`apps/singularity/lib/singularity/collector/entry.ex`：
```elixir
defmodule Singularity.Collector.Entry do
  @moduledoc "One collected object as reported by a collector."

  @enforce_keys [:item_kind, :external_id, :title, :url]
  defstruct [
    :item_kind,
    :external_id,
    :title,
    :url,
    :summary,
    :published_at,
    :rank,
    item_attributes: %{},
    observation_attributes: %{},
    raw: %{}
  ]

  @type t :: %__MODULE__{
          item_kind: String.t(),
          external_id: String.t(),
          title: String.t(),
          url: String.t(),
          summary: String.t() | nil,
          published_at: DateTime.t() | nil,
          rank: pos_integer() | nil,
          item_attributes: map(),
          observation_attributes: map(),
          raw: map()
        }
end
```

`apps/singularity/lib/singularity/collector/result.ex`：
```elixir
defmodule Singularity.Collector.Result do
  @moduledoc "Outcome of one successful fetch."

  @enforce_keys [:period]
  defstruct [:period, entries: [], skipped: 0]

  @type t :: %__MODULE__{
          period: String.t(),
          entries: [Singularity.Collector.Entry.t()],
          skipped: non_neg_integer()
        }
end
```

`apps/singularity/lib/singularity/collector.ex`：
```elixir
defmodule Singularity.Collector do
  @moduledoc """
  The only extension point for new source types.

  A collector fetches and parses; it never touches the database. Register
  implementations under `config :singularity, :collectors`.
  """

  alias Singularity.Collector.Result

  @type field :: %{
          name: atom(),
          type: :string | :select | :integer,
          label: String.t(),
          required: boolean(),
          options: [String.t()]
        }

  @callback kind() :: String.t()
  @callback label() :: String.t()
  @callback config_fields() :: [field()]
  @callback default_interval_minutes() :: pos_integer()
  @callback validate_config(map()) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  @callback fetch(config :: map(), now :: DateTime.t()) :: {:ok, Result.t()} | {:error, term()}

  @spec all() :: [module()]
  def all, do: Application.get_env(:singularity, :collectors, [])

  @spec fetch_module(String.t()) :: {:ok, module()} | :error
  def fetch_module(kind) when is_binary(kind) do
    case Enum.find(all(), &(&1.kind() == kind)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
```

- [ ] **Step 3: 测试用的假 collector**

`apps/singularity/test/support/fake_collector.ex`：
```elixir
defmodule Singularity.Test.FakeCollector do
  @moduledoc """
  Test collector. By default returns one entry derived from the "topic" config.
  Override per test with `Process.put(:fake_collector_response, fn config, now -> ... end)`.
  """

  @behaviour Singularity.Collector

  alias Singularity.Collector.{Entry, Result}

  @impl true
  def kind, do: "fake"

  @impl true
  def label, do: "Fake"

  @impl true
  def config_fields,
    do: [%{name: :topic, type: :string, label: "Topic", required: true, options: []}]

  @impl true
  def default_interval_minutes, do: 60

  @impl true
  def validate_config(%{"topic" => topic}) when is_binary(topic) and topic != "",
    do: {:ok, %{"topic" => topic}}

  def validate_config(_config), do: {:error, [{:topic, "can't be blank"}]}

  @impl true
  def fetch(config, now) do
    case Process.get(:fake_collector_response) do
      nil -> {:ok, %Result{period: period(now), entries: [entry(config["topic"] <> "-1", 1)]}}
      fun when is_function(fun, 2) -> fun.(config, now)
    end
  end

  def period(now), do: now |> DateTime.to_date() |> Date.to_iso8601()

  def entry(external_id, rank) do
    %Entry{
      item_kind: "fake_item",
      external_id: external_id,
      title: "Item " <> external_id,
      url: "https://example.test/" <> external_id,
      rank: rank,
      item_attributes: %{"n" => rank},
      observation_attributes: %{"n" => rank},
      raw: %{"id" => external_id}
    }
  end
end
```

- [ ] **Step 4: 注册 collector**

`config/config.exs`（GitHub Trending 在 Task 11 加入）：
```elixir
config :singularity, :collectors, []
```

`config/test.exs`：
```elixir
config :singularity, :collectors, [Singularity.Test.FakeCollector]
```

- [ ] **Step 5: 运行测试**

Run: `devenv shell -- mix test apps/singularity/test/singularity/collector_test.exs`
Expected：PASS。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: add collector behaviour and registry"
```

---

### Task 7: Sources 上下文

**Files:**
- Modify: `apps/singularity/lib/singularity/sources/source.ex`
- Create: `apps/singularity/lib/singularity/sources.ex`
- Test: `apps/singularity/test/singularity/sources_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule Singularity.SourcesTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Sources
  alias Singularity.Sources.Source

  @now ~U[2026-11-09 08:00:00Z]

  describe "create_source/2" do
    test "applies the collector's default interval, normalized config and immediate schedule" do
      assert {:ok, %Source{} = source} =
               Sources.create_source(%{"kind" => "fake", "name" => "F", "config" => %{"topic" => "x"}}, @now)

      assert source.interval_minutes == 60
      assert source.config == %{"topic" => "x"}
      assert source.next_run_at == @now
      assert source.enabled
    end

    test "rejects invalid config via the collector" do
      assert {:error, changeset} =
               Sources.create_source(%{"kind" => "fake", "name" => "F", "config" => %{}}, @now)

      assert %{config: ["topic can't be blank"]} = errors_on(changeset)
    end

    test "rejects unregistered kinds" do
      assert {:error, changeset} = Sources.create_source(%{"kind" => "nope", "name" => "F"}, @now)
      assert %{kind: ["is not a registered source type"]} = errors_on(changeset)
    end

    test "rejects intervals under five minutes" do
      attrs = %{"kind" => "fake", "name" => "F", "config" => %{"topic" => "x"}, "interval_minutes" => "1"}
      assert {:error, changeset} = Sources.create_source(attrs, @now)
      assert %{interval_minutes: [_]} = errors_on(changeset)
    end
  end

  test "update_source/2 and set_enabled/2" do
    source = source_fixture()
    assert {:ok, source} = Sources.update_source(source, %{"name" => "Renamed"})
    assert source.name == "Renamed"
    assert {:ok, %Source{enabled: false}} = Sources.set_enabled(source, false)
  end

  describe "claim_due_sources/1" do
    test "returns due enabled sources of registered kinds and advances them" do
      due = source_fixture(next_run_at: ~U[2026-11-09 07:00:00Z])
      _future = source_fixture(next_run_at: ~U[2026-11-09 09:00:00Z])
      _disabled = source_fixture(enabled: false, next_run_at: ~U[2026-11-09 07:00:00Z])
      _gone = source_fixture(kind: "gone", next_run_at: ~U[2026-11-09 07:00:00Z])

      assert [claimed] = Sources.claim_due_sources(@now)
      assert claimed.id == due.id
      assert claimed.next_run_at == ~U[2026-11-09 09:00:00Z]
      assert Sources.claim_due_sources(@now) == []
    end
  end

  test "type_label/1 reports unavailable kinds" do
    assert Sources.type_label(source_fixture()) == "Fake"
    assert Sources.type_label(source_fixture(kind: "gone")) =~ "gone"
  end

  test "ensure_default_source/1 creates the GitHub Trending default only once" do
    Application.put_env(:singularity, :collectors, [Singularity.Test.FakeCollector, GithubTrendingStub])
    on_exit(fn -> Application.put_env(:singularity, :collectors, [Singularity.Test.FakeCollector]) end)

    assert {:ok, %Source{kind: "github_trending"}} = Sources.ensure_default_source(@now)
    assert {:ok, :exists} = Sources.ensure_default_source(@now)
    assert length(Sources.list_sources()) == 1
  end
end

defmodule GithubTrendingStub do
  @moduledoc false
  @behaviour Singularity.Collector
  def kind, do: "github_trending"
  def label, do: "GitHub Trending"
  def config_fields, do: []
  def default_interval_minutes, do: 1440
  def validate_config(config), do: {:ok, config}
  def fetch(_config, _now), do: {:error, :stub}
end
```
注意：`ensure_default_source` 的测试会修改全局应用配置，所以这个测试文件改为 `async: false`。把第 2 行改成 `use Singularity.DataCase, async: false`。在 Task 11 注册了真正的 GitHub Trending collector 之后，这个 stub 和 `put_env` 仍然可以保留，因为它们与真实实现无关。

Run: `devenv shell -- mix test apps/singularity/test/singularity/sources_test.exs`
Expected：FAIL，提示 `Singularity.Sources` 未定义。

- [ ] **Step 2: 给 Source 加 changeset**

在 `Singularity.Sources.Source` 中加入 `import Ecto.Changeset` 和 `alias Singularity.Collector`，并在 schema 之后加入：
```elixir
  def changeset(source, attrs) do
    source
    |> cast(attrs, [:kind, :name, :config, :enabled, :interval_minutes])
    |> validate_required([:kind, :name])
    |> validate_collector()
  end

  defp validate_collector(changeset) do
    case Collector.fetch_module(get_field(changeset, :kind) || "") do
      :error ->
        add_error(changeset, :kind, "is not a registered source type")

      {:ok, collector} ->
        changeset
        |> put_default_interval(collector)
        |> validate_number(:interval_minutes, greater_than_or_equal_to: 5)
        |> validate_config(collector)
    end
  end

  defp put_default_interval(changeset, collector) do
    if get_field(changeset, :interval_minutes),
      do: changeset,
      else: put_change(changeset, :interval_minutes, collector.default_interval_minutes())
  end

  defp validate_config(changeset, collector) do
    case collector.validate_config(get_field(changeset, :config) || %{}) do
      {:ok, config} ->
        put_change(changeset, :config, config)

      {:error, errors} ->
        Enum.reduce(errors, changeset, fn {field, message}, acc ->
          add_error(acc, :config, "#{field} #{message}", field: field)
        end)
    end
  end
```

- [ ] **Step 3: 实现 Sources 上下文**

`apps/singularity/lib/singularity/sources.ex`：
```elixir
defmodule Singularity.Sources do
  @moduledoc "Source configuration and scheduling."

  import Ecto.Query

  alias Singularity.{Collector, Repo}
  alias Singularity.Sources.Source

  @default_source %{
    "kind" => "github_trending",
    "name" => "GitHub Trending · All languages · daily",
    "config" => %{"language" => "", "since" => "daily"}
  }

  def list_sources, do: Source |> order_by(asc: :inserted_at, asc: :id) |> Repo.all()

  def get_source!(id), do: Repo.get!(Source, id)
  def get_source(id), do: Repo.get(Source, id)

  def change_source(%Source{} = source, attrs \\ %{}), do: Source.changeset(source, attrs)

  def create_source(attrs, now \\ DateTime.utc_now()) do
    %Source{}
    |> Source.changeset(attrs)
    |> Ecto.Changeset.put_change(:next_run_at, DateTime.truncate(now, :second))
    |> Repo.insert()
  end

  def update_source(%Source{} = source, attrs), do: source |> Source.changeset(attrs) |> Repo.update()

  def set_enabled(%Source{} = source, enabled) when is_boolean(enabled),
    do: source |> Ecto.Changeset.change(enabled: enabled) |> Repo.update()

  def delete_source(%Source{} = source), do: Repo.delete(source)

  def type_label(%Source{kind: kind}) do
    case Collector.fetch_module(kind) do
      {:ok, collector} -> collector.label()
      :error -> "不可用（#{kind}）"
    end
  end

  @doc "Locks due sources, advances their next_run_at, and returns them."
  def claim_due_sources(%DateTime{} = now) do
    now = DateTime.truncate(now, :second)
    kinds = Enum.map(Collector.all(), & &1.kind())

    {:ok, claimed} =
      Repo.transaction(fn ->
        Source
        |> where([s], s.enabled and s.next_run_at <= ^now and s.kind in ^kinds)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()
        |> Enum.map(fn source ->
          source
          |> Ecto.Changeset.change(next_run_at: DateTime.add(now, source.interval_minutes * 60, :second))
          |> Repo.update!()
        end)
      end)

    claimed
  end

  def ensure_default_source(now \\ DateTime.utc_now()) do
    if Repo.exists?(Source), do: {:ok, :exists}, else: create_source(@default_source, now)
  end
end
```

- [ ] **Step 4: 运行测试**

Run: `devenv shell -- mix test apps/singularity/test/singularity/sources_test.exs`
Expected：全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: add sources context with per-source scheduling"
```

---

### Task 8: Knowledge.record（幂等写入）

**Files:**
- Create: `apps/singularity/lib/singularity/knowledge.ex`
- Test: `apps/singularity/test/singularity/knowledge_record_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule Singularity.KnowledgeRecordTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Collector.Result
  alias Singularity.Knowledge
  alias Singularity.Knowledge.{Item, Observation}
  alias Singularity.Repo
  alias Singularity.Test.FakeCollector

  @t1 ~U[2026-11-09 08:00:00Z]
  @t2 ~U[2026-11-10 08:00:00Z]

  defp result(period, ids),
    do: %Result{period: period, entries: Enum.with_index(ids, 1) |> Enum.map(fn {id, r} -> FakeCollector.entry(id, r) end)}

  test "creates items and observations" do
    source = source_fixture()
    assert {:ok, 2} = Knowledge.record(source, result("2026-11-09", ["a", "b"]), @t1)

    assert Repo.aggregate(Item, :count) == 2
    obs = Repo.all(Observation)
    assert Enum.map(obs, & &1.period) == ["2026-11-09", "2026-11-09"]
    assert Enum.sort(Enum.map(obs, & &1.rank)) == [1, 2]
  end

  test "re-recording the same period is idempotent" do
    source = source_fixture()
    {:ok, _} = Knowledge.record(source, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = Knowledge.record(source, result("2026-11-09", ["a"]), @t1)

    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 1
  end

  test "a new period appends an observation and updates last_seen_at only" do
    source = source_fixture()
    {:ok, _} = Knowledge.record(source, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = Knowledge.record(source, result("2026-11-10", ["a"]), @t2)

    item = Repo.one!(Item)
    assert item.first_seen_at == @t1
    assert item.last_seen_at == @t2
    assert Repo.aggregate(Observation, :count) == 2
  end

  test "the same item from two sources is one item with two observations" do
    s1 = source_fixture()
    s2 = source_fixture(name: "Other")
    {:ok, _} = Knowledge.record(s1, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = Knowledge.record(s2, result("2026-11-09", ["a"]), @t1)

    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 2
  end
end
```

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge_record_test.exs`
Expected：FAIL，提示 `Singularity.Knowledge` 未定义。

- [ ] **Step 2: 实现**

`apps/singularity/lib/singularity/knowledge.ex`：
```elixir
defmodule Singularity.Knowledge do
  @moduledoc "Knowledge items and their observations."

  import Ecto.Query

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge.{Item, Observation}
  alias Singularity.Repo
  alias Singularity.Sources.Source

  @replace_on_conflict [:title, :url, :summary, :published_at, :attributes, :last_seen_at, :updated_at]

  @doc "Upserts items and inserts one observation per entry for the result's period, atomically."
  @spec record(Source.t(), Result.t(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def record(%Source{} = source, %Result{} = result, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      Enum.each(result.entries, fn entry ->
        item = upsert_item!(entry, now)
        insert_observation!(item, source, result.period, entry, now)
      end)

      length(result.entries)
    end)
  end

  defp upsert_item!(%Entry{} = entry, now) do
    %Item{}
    |> Item.changeset(%{
      kind: entry.item_kind,
      external_id: entry.external_id,
      title: entry.title,
      url: entry.url,
      summary: entry.summary,
      published_at: entry.published_at,
      attributes: entry.item_attributes,
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!(
      on_conflict: {:replace, @replace_on_conflict},
      conflict_target: [:kind, :external_id],
      returning: true
    )
  end

  defp insert_observation!(%Item{} = item, %Source{} = source, period, %Entry{} = entry, now) do
    %Observation{}
    |> Observation.changeset(%{
      item_id: item.id,
      source_id: source.id,
      period: period,
      observed_at: now,
      rank: entry.rank,
      attributes: entry.observation_attributes,
      raw: entry.raw
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:source_id, :item_id, :period])
  end
end
```

- [ ] **Step 3: 运行测试**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge_record_test.exs`
Expected：全部 PASS。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "feat: record collected entries idempotently"
```

---

### Task 9: Knowledge 浏览查询

**Files:**
- Modify: `apps/singularity/lib/singularity/knowledge.ex`
- Test: `apps/singularity/test/singularity/knowledge_query_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule Singularity.KnowledgeQueryTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Collector.Result
  alias Singularity.Knowledge
  alias Singularity.Test.FakeCollector

  defp record!(source, period, at, ids) do
    entries = ids |> Enum.with_index(1) |> Enum.map(fn {id, r} -> FakeCollector.entry(id, r) end)
    {:ok, _} = Knowledge.record(source, %Result{period: period, entries: entries}, at)
  end

  setup do
    source = source_fixture()
    record!(source, "2026-11-09", ~U[2026-11-09 08:00:00Z], ["a", "b"])
    record!(source, "2026-11-10", ~U[2026-11-10 08:00:00Z], ["c", "a"])
    %{source: source}
  end

  test "list_items/1 orders by most recent observation, one row per item" do
    # c and a share the latest observed_at; ties break by item id, newest first.
    assert Knowledge.list_items() |> Enum.map(& &1.item.external_id) == ["c", "a", "b"]
  end

  test "list_items/1 filters by date range and kind" do
    ids = Knowledge.list_items(from: ~D[2026-11-09], to: ~D[2026-11-09]) |> Enum.map(& &1.item.external_id)
    assert Enum.sort(ids) == ["a", "b"]
    assert Knowledge.list_items(kind: "other") == []
  end

  test "list_items/1 paginates" do
    assert length(Knowledge.list_items(per_page: 2, page: 1)) == 2
    assert length(Knowledge.list_items(per_page: 2, page: 2)) == 1
  end

  test "latest_period/1 and list_period/2 return the latest ranked list", %{source: source} do
    assert Knowledge.latest_period(source.id) == "2026-11-10"
    rows = Knowledge.list_period(source.id, "2026-11-10")
    assert Enum.map(rows, &{&1.rank, &1.item.external_id}) == [{1, "c"}, {2, "a"}]
  end

  test "list_observations/1 returns history newest first with sources" do
    [%{item: item}] = Knowledge.list_items() |> Enum.filter(&(&1.item.external_id == "a"))
    history = Knowledge.list_observations(item.id)
    assert Enum.map(history, & &1.period) == ["2026-11-10", "2026-11-09"]
    assert hd(history).source.name == "Fake source"
  end

  test "list_item_kinds/0" do
    assert Knowledge.list_item_kinds() == ["fake_item"]
  end
end
```

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge_query_test.exs`
Expected：FAIL，提示查询函数未定义。

- [ ] **Step 2: 实现**

在 `Singularity.Knowledge` 中追加：
```elixir
  @doc """
  Most recently observed items, one row per item.
  Options: :kind, :from (Date), :to (Date), :page (default 1), :per_page (default 50).
  """
  def list_items(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    latest =
      Observation
      |> observed_from(opts[:from])
      |> observed_to(opts[:to])
      |> group_by([o], o.item_id)
      |> select([o], %{item_id: o.item_id, observed_at: max(o.observed_at)})

    Item
    |> join(:inner, [i], o in subquery(latest), on: o.item_id == i.id)
    |> item_kind(opts[:kind])
    |> order_by([i, o], desc: o.observed_at, desc: i.id)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> select([i, o], %{item: i, observed_at: o.observed_at, rank: nil, observation_attributes: nil})
    |> Repo.all()
  end

  defp observed_from(query, nil), do: query

  defp observed_from(query, %Date{} = from),
    do: where(query, [o], o.observed_at >= ^DateTime.new!(from, ~T[00:00:00], "Etc/UTC"))

  defp observed_to(query, nil), do: query

  defp observed_to(query, %Date{} = to),
    do: where(query, [o], o.observed_at < ^DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC"))

  defp item_kind(query, nil), do: query
  defp item_kind(query, kind), do: where(query, [i], i.kind == ^kind)

  def list_item_kinds,
    do: Item |> distinct(true) |> order_by(:kind) |> select([i], i.kind) |> Repo.all()

  def latest_period(source_id) do
    Observation
    |> where(source_id: ^source_id)
    |> order_by(desc: :observed_at, desc: :id)
    |> limit(1)
    |> select([o], o.period)
    |> Repo.one()
  end

  def list_period(source_id, period) do
    Observation
    |> where(source_id: ^source_id, period: ^period)
    |> join(:inner, [o], i in assoc(o, :item))
    |> order_by([o], asc_nulls_last: o.rank, asc: o.id)
    |> select([o, i], %{item: i, observed_at: o.observed_at, rank: o.rank, observation_attributes: o.attributes})
    |> Repo.all()
  end

  def get_item!(id), do: Repo.get!(Item, id)

  def list_observations(item_id) do
    Observation
    |> where(item_id: ^item_id)
    |> order_by(desc: :observed_at, desc: :id)
    |> preload(:source)
    |> Repo.all()
  end
```

- [ ] **Step 3: 运行测试**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge_query_test.exs`
Expected：全部 PASS。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "feat: add knowledge browsing queries"
```

---

### Task 10: Collection（执行采集、PubSub、workers、调度）

**Files:**
- Create: `apps/singularity/lib/singularity/collection.ex`、`collection/collect_source_worker.ex`、`collection/schedule_worker.ex`
- Modify: `config/config.exs`
- Test: `apps/singularity/test/singularity/collection_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule Singularity.CollectionTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Collection
  alias Singularity.Collection.{CollectSourceWorker, FetchRun, ScheduleWorker}
  alias Singularity.Collector.Result
  alias Singularity.Knowledge.Item
  alias Singularity.Repo

  @now ~U[2026-11-09 08:00:00Z]

  describe "run/2" do
    test "records entries, marks the run ok and broadcasts both transitions" do
      Collection.subscribe()
      source = source_fixture()

      assert {:ok, %FetchRun{status: "ok", item_count: 1, skipped_count: 0}} = Collection.run(source, @now)
      assert Repo.aggregate(Item, :count) == 1
      assert_receive {:fetch_run, %FetchRun{status: "running"}}
      assert_receive {:fetch_run, %FetchRun{status: "ok"}}
    end

    test "treats zero entries as a failure" do
      Process.put(:fake_collector_response, fn _c, _n -> {:ok, %Result{period: "p", entries: []}} end)

      assert {:error, :no_entries, %FetchRun{status: "failed", error: error}} =
               Collection.run(source_fixture(), @now)

      assert error =~ "no entries"
    end

    test "records collector errors and skipped counts" do
      Process.put(:fake_collector_response, fn _c, _n -> {:error, {:http_status, 429}} end)
      assert {:error, _, %FetchRun{status: "failed", error: "HTTP 429"}} = Collection.run(source_fixture(), @now)

      Process.put(:fake_collector_response, fn _c, _n ->
        {:ok, %Result{period: "p", entries: [Singularity.Test.FakeCollector.entry("x", 1)], skipped: 2}}
      end)

      assert {:ok, %FetchRun{skipped_count: 2}} = Collection.run(source_fixture(), @now)
    end

    test "returns :unavailable without a run for unregistered kinds" do
      assert {:error, :unavailable} = Collection.run(source_fixture(kind: "gone"), @now)
      assert Repo.aggregate(FetchRun, :count) == 0
    end
  end

  describe "CollectSourceWorker" do
    test "collects an enabled source" do
      source = source_fixture()
      assert :ok = perform_job(CollectSourceWorker, %{source_id: source.id})
    end

    test "cancels for disabled or missing sources" do
      source = source_fixture(enabled: false)
      assert {:cancel, _} = perform_job(CollectSourceWorker, %{source_id: source.id})
      assert {:cancel, _} = perform_job(CollectSourceWorker, %{source_id: -1})
    end

    test "returns an error so Styx retries failed collections" do
      Process.put(:fake_collector_response, fn _c, _n -> {:error, :boom} end)
      assert {:error, :boom} = perform_job(CollectSourceWorker, %{source_id: source_fixture().id})
    end
  end

  test "enqueue/1 is unique per source while incomplete" do
    source = source_fixture()
    assert {:ok, _} = Collection.enqueue(source.id)
    assert {:ok, _} = Collection.enqueue(source.id)
    assert length(all_enqueued(worker: CollectSourceWorker)) == 1
  end

  test "ScheduleWorker enqueues due sources" do
    due = source_fixture(next_run_at: DateTime.add(DateTime.utc_now(), -60, :second))
    assert :ok = perform_job(ScheduleWorker, %{})
    assert_enqueued(worker: CollectSourceWorker, args: %{source_id: due.id})
  end

  test "latest_runs/0 and list_runs/2" do
    source = source_fixture()
    fetch_run_fixture(source, started_at: ~U[2026-11-09 07:00:00Z], status: "failed")
    newest = fetch_run_fixture(source, started_at: ~U[2026-11-09 08:00:00Z])

    assert %{} = runs = Collection.latest_runs()
    assert runs[source.id].id == newest.id
    assert [%{id: id}, _] = Collection.list_runs(source.id)
    assert id == newest.id
  end
end
```

Run: `devenv shell -- mix test apps/singularity/test/singularity/collection_test.exs`
Expected：FAIL，提示 `Singularity.Collection` 未定义。

- [ ] **Step 2: 实现 Collection**

`apps/singularity/lib/singularity/collection.ex`：
```elixir
defmodule Singularity.Collection do
  @moduledoc "Runs collections, tracks fetch runs and broadcasts their state."

  import Ecto.Query

  alias Singularity.Collection.{CollectSourceWorker, FetchRun}
  alias Singularity.Collector.Result
  alias Singularity.{Collector, Knowledge, Repo}
  alias Singularity.Sources.Source

  @topic "collection"

  def subscribe, do: Phoenix.PubSub.subscribe(Singularity.PubSub, @topic)

  def enqueue(source_id) when is_integer(source_id),
    do: %{source_id: source_id} |> CollectSourceWorker.new() |> Styx.insert()

  @spec run(Source.t(), DateTime.t()) ::
          {:ok, FetchRun.t()} | {:error, term(), FetchRun.t()} | {:error, :unavailable}
  def run(%Source{} = source, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    case Collector.fetch_module(source.kind) do
      :error ->
        {:error, :unavailable}

      {:ok, collector} ->
        run = start_run!(source, now)
        outcome = collect(collector, source, now)
        run = finish_run!(run, outcome)

        case outcome do
          {:ok, _count, _skipped} -> {:ok, run}
          {:error, reason} -> {:error, reason, run}
        end
    end
  end

  defp collect(collector, source, now) do
    case collector.fetch(source.config, now) do
      {:ok, %Result{entries: []}} -> {:error, :no_entries}
      {:ok, %Result{} = result} -> record(source, result, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(source, result, now) do
    case Knowledge.record(source, result, now) do
      {:ok, count} -> {:ok, count, result.skipped}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  end

  defp start_run!(source, now) do
    %FetchRun{source_id: source.id, status: "running", started_at: now}
    |> Repo.insert!()
    |> broadcast()
  end

  defp finish_run!(run, outcome) do
    changes =
      case outcome do
        {:ok, count, skipped} -> [status: "ok", item_count: count, skipped_count: skipped]
        {:error, reason} -> [status: "failed", error: format_error(reason)]
      end

    run
    |> Ecto.Changeset.change([finished_at: DateTime.utc_now() |> DateTime.truncate(:second)] ++ changes)
    |> Repo.update!()
    |> broadcast()
  end

  defp broadcast(%FetchRun{} = run) do
    Phoenix.PubSub.broadcast(Singularity.PubSub, @topic, {:fetch_run, run})
    run
  end

  def format_error(:no_entries), do: "no entries parsed (page structure may have changed)"
  def format_error({:http_status, status}), do: "HTTP #{status}"
  def format_error({:transport, message}) when is_binary(message), do: "transport error: " <> String.slice(message, 0, 300)
  def format_error(other), do: other |> inspect() |> String.slice(0, 300)

  def list_runs(source_id, limit \\ 20) do
    FetchRun
    |> where(source_id: ^source_id)
    |> order_by(desc: :started_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  def latest_runs do
    FetchRun
    |> distinct([r], r.source_id)
    |> order_by([r], asc: r.source_id, desc: r.started_at, desc: r.id)
    |> Repo.all()
    |> Map.new(&{&1.source_id, &1})
  end
end
```

- [ ] **Step 3: 实现两个 worker**

`apps/singularity/lib/singularity/collection/collect_source_worker.ex`：
```elixir
defmodule Singularity.Collection.CollectSourceWorker do
  use Styx.Worker,
    queue: :collect,
    max_attempts: 3,
    unique: [keys: [:source_id], states: :incomplete, period: :infinity]

  alias Singularity.{Collection, Sources}

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"source_id" => source_id}}) do
    case Sources.get_source(source_id) do
      %{enabled: true} = source ->
        case Collection.run(source) do
          {:ok, _run} -> :ok
          {:error, :unavailable} -> {:cancel, :source_type_unavailable}
          {:error, reason, _run} -> {:error, reason}
        end

      _missing_or_disabled ->
        {:cancel, :source_unavailable}
    end
  end
end
```

`apps/singularity/lib/singularity/collection/schedule_worker.ex`：
```elixir
defmodule Singularity.Collection.ScheduleWorker do
  @moduledoc "Runs every minute; enqueues a collection for each due source."

  use Styx.Worker, queue: :default, max_attempts: 1

  alias Singularity.{Collection, Sources}

  @impl Styx.Worker
  def perform(_job) do
    DateTime.utc_now()
    |> Sources.claim_due_sources()
    |> Enum.each(fn source -> {:ok, _job} = Collection.enqueue(source.id) end)
  end
end
```

- [ ] **Step 4: 加入每分钟的 cron**

在 `config/config.exs` 的 Styx 配置中，把 `plugins` 改为：
```elixir
  plugins: [
    {Styx.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Styx.Cron, crontab: [{"* * * * *", Singularity.Collection.ScheduleWorker}]}
  ]
```

- [ ] **Step 5: 运行测试**

Run: `devenv shell -- mix test apps/singularity/test/singularity/collection_test.exs`
Expected：全部 PASS。如果 `unique` 的 `keys` 或 `states: :incomplete` 的行为与 Oban 不一致导致唯一性测试失败，**不要**修改测试，按上游规则给 Styx 提 issue 并停下来报告。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: run collections through Styx with per-source scheduling"
```

---

### Task 11: GitHub Trending collector

**Files:**
- Create: `apps/singularity/lib/singularity/collectors/github_trending.ex`
- Create: `apps/singularity/test/fixtures/github_trending/minimal.html`、`daily.html`
- Modify: `config/config.exs`、`config/test.exs`
- Test: `apps/singularity/test/singularity/collectors/github_trending_test.exs`

- [ ] **Step 1: 准备 fixture**

`apps/singularity/test/fixtures/github_trending/minimal.html`（手写，结构与真实页面一致：一行正常、一行损坏、一行缺少描述和语言）：
```html
<html><body>
<article class="Box-row">
  <h2 class="h3 lh-condensed">
    <a href="/acme/rocket" class="Link"><span class="text-normal">acme /</span> rocket</a>
  </h2>
  <p class="col-9 color-fg-muted my-1">
    A fast   rocket engine
  </p>
  <div class="f6 color-fg-muted mt-2">
    <span class="d-inline-block ml-0"><span itemprop="programmingLanguage">Rust</span></span>
    <a href="/acme/rocket/stargazers" class="Link Link--muted d-inline-block">
      12,345</a>
    <a href="/acme/rocket/forks" class="Link Link--muted d-inline-block">
      678</a>
    <span class="d-inline-block float-sm-right">
      1,234 stars today
    </span>
  </div>
</article>
<article class="Box-row">
  <h2 class="h3 lh-condensed"><a class="Link">missing href</a></h2>
</article>
<article class="Box-row">
  <h2 class="h3 lh-condensed">
    <a href="/solo/tool" class="Link">solo / tool</a>
  </h2>
  <div class="f6 color-fg-muted mt-2">
    <a href="/solo/tool/stargazers" class="Link">
      99</a>
    <a href="/solo/tool/forks" class="Link">
      1</a>
    <span class="float-sm-right">
      7 stars this week
    </span>
  </div>
</article>
</body></html>
```

抓取一份真实页面：
```bash
mkdir -p apps/singularity/test/fixtures/github_trending
curl -sfL -A Singularity "https://github.com/trending?since=daily" \
  -o apps/singularity/test/fixtures/github_trending/daily.html
grep -o '<article class="Box-row">' apps/singularity/test/fixtures/github_trending/daily.html | wc -l
```
Expected：行数大于 0。

- [ ] **Step 2: 配置 Req.Test**

`config/test.exs`：
```elixir
config :singularity, Singularity.Collectors.GithubTrending,
  req_options: [plug: {Req.Test, Singularity.Collectors.GithubTrending}]
```

- [ ] **Step 3: 写失败的测试**

`apps/singularity/test/singularity/collectors/github_trending_test.exs`：
```elixir
defmodule Singularity.Collectors.GithubTrendingTest do
  use ExUnit.Case, async: true

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Collectors.GithubTrending

  defp fixture(name), do: Path.join([__DIR__, "../../fixtures/github_trending", name]) |> File.read!()

  describe "parse/2" do
    test "extracts entries, ranks by page position and counts broken rows" do
      {entries, skipped} = GithubTrending.parse(fixture("minimal.html"), "daily")

      assert skipped == 1
      assert [%Entry{} = rocket, %Entry{} = tool] = entries

      assert rocket.external_id == "acme/rocket"
      assert rocket.title == "acme/rocket"
      assert rocket.url == "https://github.com/acme/rocket"
      assert rocket.summary == "A fast rocket engine"
      assert rocket.rank == 1
      assert rocket.item_kind == "github_repo"
      assert rocket.item_attributes == %{"language" => "Rust", "stars" => 12_345, "forks" => 678}

      assert rocket.observation_attributes == %{
               "stars" => 12_345,
               "forks" => 678,
               "stars_in_period" => 1_234,
               "since" => "daily"
             }

      assert tool.rank == 3
      assert tool.summary == nil
      assert tool.item_attributes["language"] == nil
      assert tool.observation_attributes["stars_in_period"] == 7
    end

    test "returns no entries for pages without trending rows" do
      assert {[], 0} = GithubTrending.parse("<html><body><p>nothing</p></body></html>", "daily")
    end

    test "parses a captured real trending page" do
      html = fixture("daily.html")
      {:ok, doc} = Floki.parse_document(html)
      row_count = doc |> Floki.find("article.Box-row") |> length()

      {entries, skipped} = GithubTrending.parse(html, "daily")

      assert row_count > 0
      assert skipped == 0
      assert Enum.map(entries, & &1.rank) == Enum.to_list(1..row_count)

      for entry <- entries do
        assert entry.external_id =~ ~r{^[^/\s]+/[^/\s]+$}
        assert is_integer(entry.item_attributes["stars"])
        assert is_integer(entry.observation_attributes["stars_in_period"])
      end
    end
  end

  describe "validate_config/1" do
    test "normalizes valid config" do
      assert {:ok, %{"language" => "elixir", "since" => "weekly"}} =
               GithubTrending.validate_config(%{"language" => " Elixir ", "since" => "weekly"})

      assert {:ok, %{"language" => "", "since" => "daily"}} = GithubTrending.validate_config(%{})
    end

    test "rejects bad values" do
      assert {:error, errors} = GithubTrending.validate_config(%{"language" => "a/b", "since" => "yearly"})
      assert Keyword.has_key?(errors, :language)
      assert Keyword.has_key?(errors, :since)
    end
  end

  describe "fetch/2" do
    test "requests the language page and returns a dated result" do
      Req.Test.stub(GithubTrending, fn conn ->
        assert conn.request_path == "/trending/c%2B%2B"
        assert conn.query_string == "since=weekly"
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["Singularity"]
        Plug.Conn.send_resp(conn, 200, fixture("minimal.html"))
      end)

      assert {:ok, %Result{period: "2026-11-09", entries: [_, _], skipped: 1}} =
               GithubTrending.fetch(%{"language" => "c++", "since" => "weekly"}, ~U[2026-11-09 23:30:00Z])
    end

    test "requests the all-languages page when language is blank" do
      Req.Test.stub(GithubTrending, fn conn ->
        assert conn.request_path == "/trending"
        Plug.Conn.send_resp(conn, 200, fixture("minimal.html"))
      end)

      assert {:ok, _} = GithubTrending.fetch(%{"language" => "", "since" => "daily"}, ~U[2026-11-09 00:00:00Z])
    end

    test "maps non-200 responses to errors" do
      Req.Test.stub(GithubTrending, &Plug.Conn.send_resp(&1, 429, "slow down"))
      assert {:error, {:http_status, 429}} = GithubTrending.fetch(%{"language" => "", "since" => "daily"}, ~U[2026-11-09 00:00:00Z])
    end
  end
end
```

Run: `devenv shell -- mix test apps/singularity/test/singularity/collectors/github_trending_test.exs`
Expected：FAIL，提示 `GithubTrending` 未定义。

- [ ] **Step 4: 实现**

`apps/singularity/lib/singularity/collectors/github_trending.ex`：
```elixir
defmodule Singularity.Collectors.GithubTrending do
  @moduledoc "Collects https://github.com/trending (optionally per language and range)."

  @behaviour Singularity.Collector

  alias Singularity.Collector.{Entry, Result}

  @base_url "https://github.com/trending"
  @since_values ~w(daily weekly monthly)
  @stars_in_period ~r/([\d,]+)\s+stars?\s+(?:today|this week|this month)/

  @impl true
  def kind, do: "github_trending"

  @impl true
  def label, do: "GitHub Trending"

  @impl true
  def config_fields do
    [
      %{name: :language, type: :string, label: "语言（留空表示全部）", required: false, options: []},
      %{name: :since, type: :select, label: "时间范围", required: true, options: @since_values}
    ]
  end

  @impl true
  def default_interval_minutes, do: 1440

  @impl true
  def validate_config(config) when is_map(config) do
    language = config |> Map.get("language", "") |> to_string() |> String.trim() |> String.downcase()
    since = config |> Map.get("since", "daily") |> to_string()

    errors =
      [
        unless(language == "" or Regex.match?(~r/^[a-z0-9+#.\-]+$/, language),
          do: {:language, "contains invalid characters"}
        ),
        unless(since in @since_values, do: {:since, "must be one of daily, weekly, monthly"})
      ]
      |> Enum.reject(&is_nil/1)

    if errors == [], do: {:ok, %{"language" => language, "since" => since}}, else: {:error, errors}
  end

  @impl true
  def fetch(config, now) do
    request = [user_agent: "Singularity", retry: false] ++ req_options()

    case Req.get(trending_url(config), request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {entries, skipped} = parse(body, config["since"])
        period = now |> DateTime.to_date() |> Date.to_iso8601()
        {:ok, %Result{period: period, entries: entries, skipped: skipped}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  def trending_url(config) do
    base =
      case config["language"] do
        language when language in [nil, ""] -> @base_url
        language -> @base_url <> "/" <> URI.encode(language, &URI.char_unreserved?/1)
      end

    base <> "?" <> URI.encode_query(%{"since" => config["since"] || "daily"})
  end

  @doc "Pure parser: returns entries ranked by page position and the number of unparseable rows."
  @spec parse(String.t(), String.t() | nil) :: {[Entry.t()], non_neg_integer()}
  def parse(html, since) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find("article.Box-row")
        |> Enum.with_index(1)
        |> Enum.reduce({[], 0}, fn {row, rank}, {entries, skipped} ->
          case parse_row(row, rank, since) do
            {:ok, entry} -> {[entry | entries], skipped}
            :error -> {entries, skipped + 1}
          end
        end)
        |> then(fn {entries, skipped} -> {Enum.reverse(entries), skipped} end)

      {:error, _reason} ->
        {[], 0}
    end
  end

  defp parse_row(row, rank, since) do
    with [href | _] <- Floki.attribute(row, "h2 a", "href"),
         "/" <> path <- String.trim(href),
         [owner, repo] <- String.split(path, "/", trim: true) do
      full_name = owner <> "/" <> repo
      summary = row |> Floki.find("p") |> Floki.text() |> squish()
      language = row |> Floki.find(~s([itemprop="programmingLanguage"])) |> Floki.text() |> squish()
      stars = link_count(row, "/stargazers")
      forks = link_count(row, "/forks")
      stars_in_period = row |> Floki.text() |> stars_in_period()

      {:ok,
       %Entry{
         item_kind: "github_repo",
         external_id: full_name,
         title: full_name,
         url: "https://github.com/" <> full_name,
         summary: summary,
         rank: rank,
         item_attributes: %{"language" => language, "stars" => stars, "forks" => forks},
         observation_attributes: %{
           "stars" => stars,
           "forks" => forks,
           "stars_in_period" => stars_in_period,
           "since" => since
         },
         raw: %{
           "owner" => owner,
           "repo" => repo,
           "description" => summary,
           "language" => language,
           "stars" => stars,
           "forks" => forks,
           "stars_in_period" => stars_in_period,
           "rank" => rank
         }
       }}
    else
      _ -> :error
    end
  end

  defp link_count(row, suffix) do
    row
    |> Floki.find("a")
    |> Enum.find(fn link -> link |> Floki.attribute("href") |> List.first("") |> String.ends_with?(suffix) end)
    |> case do
      nil -> nil
      link -> link |> Floki.text() |> to_integer()
    end
  end

  defp stars_in_period(text) do
    case Regex.run(@stars_in_period, text) do
      [_, count] -> to_integer(count)
      nil -> nil
    end
  end

  defp to_integer(text) do
    case text |> String.replace(~r/[^\d]/, "") |> Integer.parse() do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp squish(text) do
    case text |> String.split() |> Enum.join(" ") do
      "" -> nil
      value -> value
    end
  end

  defp req_options do
    :singularity |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end
end
```

- [ ] **Step 5: 注册**

`config/config.exs`：
```elixir
config :singularity, :collectors, [Singularity.Collectors.GithubTrending]
```

`config/test.exs`：
```elixir
config :singularity, :collectors, [
  Singularity.Collectors.GithubTrending,
  Singularity.Test.FakeCollector
]
```
同时把 Task 7 测试中 `on_exit` 的恢复值改成上面这个列表，并且把 `GithubTrendingStub` 和 `put_env` 删掉（`ensure_default_source` 改用真实的 collector），然后把 `SourcesTest` 恢复为 `async: true`。

- [ ] **Step 6: 运行全部测试**

Run: `devenv shell -- mix test`
Expected：全部 PASS。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: add GitHub Trending collector"
```

---

### Task 12: Web 布局、条目组件与条目页面

**Files:**
- Modify: `apps/singularity_web/lib/singularity_web/components/layouts.ex`、`router.ex`
- Create: `apps/singularity_web/lib/singularity_web/components/item_components.ex`
- Create: `apps/singularity_web/lib/singularity_web/live/item_live/index.ex`、`show.ex`
- Delete: 生成的 `PageController`、它的模板和测试
- Test: `apps/singularity_web/test/singularity_web/live/item_live_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule SingularityWeb.ItemLiveTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.Collection.FetchRun
  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge
  alias Singularity.Test.FakeCollector

  defp gh_entry(id, rank) do
    %Entry{
      item_kind: "github_repo",
      external_id: id,
      title: id,
      url: "https://github.com/" <> id,
      summary: "About " <> id,
      rank: rank,
      item_attributes: %{"language" => "Elixir", "stars" => 1200, "forks" => 3},
      observation_attributes: %{"stars" => 1200, "stars_in_period" => 45, "since" => "daily"}
    }
  end

  defp record!(source, period, at, entries),
    do: {:ok, _} = Knowledge.record(source, %Result{period: period, entries: entries}, at)

  test "shows an empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "还没有采集到条目"
  end

  test "lists recently observed items with kind-specific meta", %{conn: conn} do
    record!(source_fixture(), "2026-11-09", ~U[2026-11-09 08:00:00Z], [gh_entry("acme/rocket", 1)])

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "acme/rocket"
    assert html =~ "About acme/rocket"
    assert html =~ "Elixir · ★ 1,200"
  end

  test "falls back to the generic display for kinds without a component", %{conn: conn} do
    record!(source_fixture(), "p", ~U[2026-11-09 08:00:00Z], [FakeCollector.entry("plain", 1)])

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Item plain"
  end

  test "a selected source shows its latest period ranked", %{conn: conn} do
    source = source_fixture()
    record!(source, "2026-11-09", ~U[2026-11-09 08:00:00Z], [gh_entry("old/one", 1)])
    record!(source, "2026-11-10", ~U[2026-11-10 08:00:00Z], [gh_entry("new/b", 2), gh_entry("new/a", 1)])

    {:ok, _view, html} = live(conn, ~p"/?source_id=#{source.id}")
    assert html =~ "2026-11-10"
    refute html =~ "old/one"
    assert :binary.match(html, "new/a") < :binary.match(html, "new/b")
  end

  test "changing filters patches the URL", %{conn: conn} do
    source = source_fixture()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#item-filters")
    |> render_change(%{"filters" => %{"source_id" => to_string(source.id), "kind" => ""}})

    assert_patch(view, ~p"/?source_id=#{source.id}")
  end

  test "reloads when a fetch run completes", %{conn: conn} do
    source = source_fixture()
    {:ok, view, _html} = live(conn, ~p"/")

    record!(source, "p", ~U[2026-11-09 08:00:00Z], [gh_entry("late/arrival", 1)])
    send(view.pid, {:fetch_run, %FetchRun{status: "ok", source_id: source.id}})

    assert render(view) =~ "late/arrival"
  end

  test "item detail shows the observation history", %{conn: conn} do
    source = source_fixture()
    record!(source, "2026-11-09", ~U[2026-11-09 08:00:00Z], [gh_entry("acme/rocket", 3)])
    [%{item: item}] = Knowledge.list_items()

    {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
    assert html =~ "https://github.com/acme/rocket"
    assert html =~ "2026-11-09"
    assert html =~ "Fake source"
    assert html =~ "+45"
  end
end
```

Run: `devenv shell -- mix test apps/singularity_web/test/singularity_web/live/item_live_test.exs`
Expected：FAIL（路由不存在）。

- [ ] **Step 2: 修改布局**

在 `apps/singularity_web/lib/singularity_web/components/layouts.ex` 中，把生成的 `app/1`（包括它前面的 `attr` 和 `slot` 声明）替换为：
```elixir
  attr :flash, :map, required: true
  attr :current, :atom, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex">
      <nav class="w-48 shrink-0 border-r border-outline-variant p-4 space-y-2" aria-label="主导航">
        <div class="text-lg font-semibold mb-4">Singularity</div>
        <.link navigate={~p"/"} id="nav-items" class={nav_class(@current == :items)}>条目</.link>
        <.link navigate={~p"/sources"} id="nav-sources" class={nav_class(@current == :sources)}>来源</.link>
      </nav>
      <main class="flex-1 p-6 space-y-4 min-w-0">
        <.dm_flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  defp nav_class(true), do: "block rounded px-3 py-2 bg-primary text-primary-content"
  defp nav_class(false), do: "block rounded px-3 py-2 hover:bg-surface-container"
```
如果 setup skill 之后 `dm_flash_group` 的属性名与这里不同，以 `deps/phoenix_duskmoon` 里的定义为准。

- [ ] **Step 3: 条目展示组件**

`apps/singularity_web/lib/singularity_web/components/item_components.ex`：
```elixir
defmodule SingularityWeb.ItemComponents do
  @moduledoc """
  Kind-specific item rendering. Add a clause per item kind; kinds without a
  clause fall back to the generic display.
  """

  use Phoenix.Component

  attr :item, :map, required: true

  def item_meta(%{item: %{kind: "github_repo"}} = assigns) do
    ~H"""
    <span data-role="item-meta">
      {@item.attributes["language"] || "—"} · ★ {format_count(@item.attributes["stars"])} · forks {format_count(@item.attributes["forks"])}
    </span>
    """
  end

  def item_meta(assigns), do: ~H""

  attr :kind, :string, required: true
  attr :attributes, :map, required: true

  def observation_meta(%{kind: "github_repo"} = assigns) do
    ~H"""
    <span>★ {format_count(@attributes["stars"])} · +{format_count(@attributes["stars_in_period"])} ({@attributes["since"]})</span>
    """
  end

  def observation_meta(assigns) do
    ~H"""
    <span>{Enum.map_join(@attributes || %{}, " · ", fn {key, value} -> "#{key}: #{value}" end)}</span>
    """
  end

  def format_count(nil), do: "—"

  def format_count(number) when is_integer(number),
    do: number |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  def format_count(other), do: to_string(other)

  def format_time(nil), do: "—"
  def format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
```

- [ ] **Step 4: 条目列表页**

`apps/singularity_web/lib/singularity_web/live/item_live/index.ex`：
```elixir
defmodule SingularityWeb.ItemLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.{Collection, Knowledge, Sources}

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    {:ok, assign_options(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(filters: parse_filters(params), query: clean(params)) |> load_rows()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?#{clean(filters)}")}
  end

  @impl true
  def handle_info({:fetch_run, %{status: "ok"}}, socket),
    do: {:noreply, socket |> assign_options() |> load_rows()}

  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  defp assign_options(socket),
    do: assign(socket, sources: Sources.list_sources(), kinds: Knowledge.list_item_kinds())

  defp load_rows(%{assigns: %{filters: %{source_id: source_id}}} = socket) when is_integer(source_id) do
    period = Knowledge.latest_period(source_id)
    rows = if period, do: Knowledge.list_period(source_id, period), else: []
    assign(socket, mode: :period, period: period, rows: rows, has_next: false)
  end

  defp load_rows(%{assigns: %{filters: filters}} = socket) do
    rows =
      Knowledge.list_items(
        kind: filters.kind,
        from: filters.from,
        to: filters.to,
        page: filters.page,
        per_page: @per_page
      )

    assign(socket, mode: :recent, period: nil, rows: rows, has_next: length(rows) == @per_page)
  end

  defp parse_filters(params) do
    %{
      source_id: parse_int(params["source_id"]),
      kind: blank_to_nil(params["kind"]),
      from: parse_date(params["from"]),
      to: parse_date(params["to"]),
      page: max(parse_int(params["page"]) || 1, 1)
    }
  end

  defp clean(params) do
    params
    |> Map.take(~w(source_id kind from to page))
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp page_query(query, page), do: Map.put(query, "page", page)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:items}>
      <h1 class="text-2xl font-semibold">条目</h1>

      <form id="item-filters" phx-change="filter" class="flex flex-wrap gap-3 items-end">
        <.dm_select
          id="filter-source"
          name="filters[source_id]"
          label="来源"
          value={@filters.source_id}
          prompt="全部来源"
          options={Enum.map(@sources, &{&1.id, &1.name})}
        />
        <.dm_select
          id="filter-kind"
          name="filters[kind]"
          label="类型"
          value={@filters.kind}
          prompt="全部类型"
          options={Enum.map(@kinds, &{&1, &1})}
        />
        <.dm_input :if={@mode == :recent} id="filter-from" type="date" name="filters[from]" label="从" value={@filters.from} />
        <.dm_input :if={@mode == :recent} id="filter-to" type="date" name="filters[to]" label="到" value={@filters.to} />
      </form>

      <p :if={@mode == :period && @period} id="period-label" class="text-sm">期次：{@period}</p>
      <p :if={@rows == []} id="items-empty">还没有采集到条目。</p>

      <ol id="items" class="space-y-3">
        <li :for={row <- @rows} id={"item-#{row.item.id}"} class="rounded border border-outline-variant p-3 space-y-1">
          <div class="flex items-baseline gap-2">
            <span :if={row.rank} class="font-mono text-sm">#{row.rank}</span>
            <.link navigate={~p"/items/#{row.item.id}"} class="font-medium">{row.item.title}</.link>
            <.dm_badge size="sm">{row.item.kind}</.dm_badge>
          </div>
          <p :if={row.item.summary} class="text-sm text-on-surface-variant">{row.item.summary}</p>
          <div class="text-xs flex flex-wrap gap-3">
            <.item_meta item={row.item} />
            <.observation_meta :if={row.observation_attributes} kind={row.item.kind} attributes={row.observation_attributes} />
            <span>最近观测 {format_time(row.observed_at)}</span>
          </div>
        </li>
      </ol>

      <nav :if={@mode == :recent} class="flex gap-3" aria-label="分页">
        <.link :if={@filters.page > 1} patch={~p"/?#{page_query(@query, @filters.page - 1)}"} id="page-prev">上一页</.link>
        <.link :if={@has_next} patch={~p"/?#{page_query(@query, @filters.page + 1)}"} id="page-next">下一页</.link>
      </nav>
    </Layouts.app>
    """
  end
end
```
说明：`dm_select` 的 `options` 使用 `{value, label}`，这和 backplane `api_usage_live.ex` 中的用法一致。

- [ ] **Step 5: 条目详情页**

`apps/singularity_web/lib/singularity_web/live/item_live/show.ex`：
```elixir
defmodule SingularityWeb.ItemLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.Knowledge

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    item = Knowledge.get_item!(id)
    {:ok, assign(socket, item: item, observations: Knowledge.list_observations(item.id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:items}>
      <div class="space-y-2">
        <h1 class="text-2xl font-semibold">{@item.title}</h1>
        <a href={@item.url} target="_blank" rel="noopener noreferrer" class="text-primary">{@item.url}</a>
        <p :if={@item.summary}>{@item.summary}</p>
        <div class="text-sm flex flex-wrap gap-3">
          <.dm_badge size="sm">{@item.kind}</.dm_badge>
          <.item_meta item={@item} />
          <span :if={@item.published_at}>发布于 {format_time(@item.published_at)}</span>
          <span>首次观测 {format_time(@item.first_seen_at)}</span>
          <span>最近观测 {format_time(@item.last_seen_at)}</span>
        </div>
      </div>

      <h2 class="text-lg font-semibold">观测历史</h2>
      <.dm_table id="observations" data={@observations}>
        <:col :let={obs} label="时间">{format_time(obs.observed_at)}</:col>
        <:col :let={obs} label="来源">{obs.source.name}</:col>
        <:col :let={obs} label="期次">{obs.period}</:col>
        <:col :let={obs} label="排名">{obs.rank || "—"}</:col>
        <:col :let={obs} label="指标"><.observation_meta kind={@item.kind} attributes={obs.attributes} /></:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 6: 路由**

在 `apps/singularity_web/lib/singularity_web/router.ex` 中，把 `scope "/", SingularityWeb do ... end` 里生成的 `get "/", PageController, :home` 替换为：
```elixir
    live "/", ItemLive.Index, :index
    live "/items/:id", ItemLive.Show, :show
```
删除 `PageController`、`PageHTML`、`page_html/` 模板目录，以及 `test/singularity_web/controllers/page_controller_test.exs`。

- [ ] **Step 7: 运行测试**

Run: `devenv shell -- mix test apps/singularity_web`
Expected：全部 PASS。

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat(web): browse collected items"
```

---

### Task 13: 来源页面

**Files:**
- Create: `apps/singularity_web/lib/singularity_web/live/source_live/index.ex`、`form.ex`、`show.ex`
- Modify: `apps/singularity_web/lib/singularity_web/router.ex`
- Test: `apps/singularity_web/test/singularity_web/live/source_live_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule SingularityWeb.SourceLiveTest do
  use SingularityWeb.ConnCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.Collection.{CollectSourceWorker, FetchRun}
  alias Singularity.Sources

  describe "index" do
    test "lists sources with type and latest run status", %{conn: conn} do
      source = source_fixture(name: "My fake")
      fetch_run_fixture(source, status: "failed", error: "HTTP 500")

      {:ok, _view, html} = live(conn, ~p"/sources")
      assert html =~ "My fake"
      assert html =~ "Fake"
      assert html =~ "failed"
    end

    test "collect now enqueues a job", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/sources")

      view |> element("#collect-#{source.id}") |> render_click()
      assert_enqueued(worker: CollectSourceWorker, args: %{source_id: source.id})
    end

    test "toggle and delete", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/sources")

      view |> element("#toggle-#{source.id}") |> render_click()
      refute Sources.get_source!(source.id).enabled

      view |> element("#delete-#{source.id}") |> render_click()
      assert Sources.get_source(source.id) == nil
    end
  end

  describe "form" do
    test "new: choose a type, then fill type-specific fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sources/new")
      assert html =~ "GitHub Trending"
      assert html =~ "Fake"

      {:ok, view, html} = live(conn, ~p"/sources/new?kind=fake")
      assert html =~ "Topic"

      html = view |> form("#source-form", source: %{name: "N", config: %{topic: ""}}) |> render_submit()
      assert html =~ "topic can&#39;t be blank"

      view
      |> form("#source-form", source: %{name: "N", config: %{topic: "x"}})
      |> render_submit()

      [source] = Sources.list_sources()
      assert source.config == %{"topic" => "x"}
      assert_redirect(view, ~p"/sources/#{source.id}")
    end

    test "edit updates the source", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/sources/#{source.id}/edit")

      view |> form("#source-form", source: %{name: "Renamed"}) |> render_submit()
      assert Sources.get_source!(source.id).name == "Renamed"
    end
  end

  describe "show" do
    test "lists runs and refreshes on broadcasts", %{conn: conn} do
      source = source_fixture()
      fetch_run_fixture(source, status: "failed", error: "HTTP 429")

      {:ok, view, html} = live(conn, ~p"/sources/#{source.id}")
      assert html =~ "HTTP 429"

      fetch_run_fixture(source, status: "ok", item_count: 25, started_at: DateTime.add(now(), 60, :second))
      send(view.pid, {:fetch_run, %FetchRun{source_id: source.id, status: "ok"}})
      assert render(view) =~ "25"
    end
  end
end
```

Run: `devenv shell -- mix test apps/singularity_web/test/singularity_web/live/source_live_test.exs`
Expected：FAIL（路由不存在）。

- [ ] **Step 2: 路由**

在 `router.ex` 的同一个 scope 中加入（`/sources/new` 必须放在 `/sources/:id` 之前）：
```elixir
    live "/sources", SourceLive.Index, :index
    live "/sources/new", SourceLive.Form, :new
    live "/sources/:id/edit", SourceLive.Form, :edit
    live "/sources/:id", SourceLive.Show, :show
```

- [ ] **Step 3: 来源列表页**

`apps/singularity_web/lib/singularity_web/live/source_live/index.ex`：
```elixir
defmodule SingularityWeb.SourceLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]

  alias Singularity.{Collection, Sources}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    source = Sources.get_source!(id)
    {:ok, _} = Sources.set_enabled(source, !source.enabled)
    {:noreply, load(socket)}
  end

  def handle_event("collect", %{"id" => id}, socket) do
    {:ok, _job} = Collection.enqueue(String.to_integer(id))
    {:noreply, put_flash(socket, :info, "已加入采集队列")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> Sources.get_source!() |> Sources.delete_source()
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, sources: Sources.list_sources(), runs: Collection.latest_runs())

  def run_variant("ok"), do: "success"
  def run_variant("failed"), do: "error"
  def run_variant(_running), do: "info"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:sources}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">来源</h1>
        <.link navigate={~p"/sources/new"} id="new-source"><.dm_btn variant="primary" size="sm">新建来源</.dm_btn></.link>
      </div>

      <.dm_table id="sources" data={@sources}>
        <:col :let={source} label="名称">
          <.link navigate={~p"/sources/#{source.id}"} id={"source-#{source.id}"}>{source.name}</.link>
        </:col>
        <:col :let={source} label="类型">{Sources.type_label(source)}</:col>
        <:col :let={source} label="间隔">{source.interval_minutes} 分钟</:col>
        <:col :let={source} label="状态">
          <.dm_badge size="sm" variant={if source.enabled, do: "success", else: "warning"}>
            {if source.enabled, do: "启用", else: "停用"}
          </.dm_badge>
        </:col>
        <:col :let={source} label="最近采集">
          <span :if={run = @runs[source.id]}>
            <.dm_badge size="sm" variant={run_variant(run.status)}>{run.status}</.dm_badge>
            {format_time(run.started_at)} · {run.item_count} 条
          </span>
          <span :if={!@runs[source.id]}>—</span>
        </:col>
        <:col :let={source} label="操作">
          <div class="flex gap-2">
            <.dm_btn :if={source.enabled} size="sm" id={"collect-#{source.id}"} phx-click="collect" phx-value-id={source.id}>立即采集</.dm_btn>
            <.dm_btn size="sm" id={"toggle-#{source.id}"} phx-click="toggle" phx-value-id={source.id}>
              {if source.enabled, do: "停用", else: "启用"}
            </.dm_btn>
            <.link navigate={~p"/sources/#{source.id}/edit"}><.dm_btn size="sm">编辑</.dm_btn></.link>
            <.dm_btn size="sm" id={"delete-#{source.id}"} phx-click="delete" phx-value-id={source.id} data-confirm="删除该来源及其观测记录？条目会保留。">删除</.dm_btn>
          </div>
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: 来源表单页**

`apps/singularity_web/lib/singularity_web/live/source_live/form.ex`：
```elixir
defmodule SingularityWeb.SourceLive.Form do
  use SingularityWeb, :live_view

  alias Singularity.{Collector, Sources}
  alias Singularity.Sources.Source

  @impl true
  def mount(params, _session, socket), do: {:ok, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :new, params) do
    case params["kind"] && Collector.fetch_module(params["kind"]) do
      {:ok, collector} ->
        source = %Source{kind: collector.kind(), config: %{}}

        socket
        |> assign(page_title: "新建来源 · #{collector.label()}", source: source, collector: collector)
        |> assign(form: to_form(Sources.change_source(source)))

      _ ->
        assign(socket, page_title: "选择来源类型", source: nil, collector: nil, form: nil, collectors: Collector.all())
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    source = Sources.get_source!(id)

    case Collector.fetch_module(source.kind) do
      {:ok, collector} ->
        assign(socket,
          page_title: "编辑来源",
          source: source,
          collector: collector,
          form: to_form(Sources.change_source(source))
        )

      :error ->
        socket
        |> put_flash(:error, "来源类型 #{source.kind} 不可用，无法编辑")
        |> push_navigate(to: ~p"/sources")
    end
  end

  @impl true
  def handle_event("validate", %{"source" => params}, socket) do
    changeset = socket.assigns.source |> Sources.change_source(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"source" => params}, socket) do
    result =
      case socket.assigns.live_action do
        :new -> Sources.create_source(Map.put(params, "kind", socket.assigns.source.kind))
        :edit -> Sources.update_source(socket.assigns.source, params)
      end

    case result do
      {:ok, source} ->
        {:noreply, socket |> put_flash(:info, "已保存") |> push_navigate(to: ~p"/sources/#{source.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp config_value(form, name) do
    config = form[:config].value || %{}
    Map.get(config, to_string(name)) || Map.get(config, name)
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true

  defp field_errors(assigns) do
    changeset = assigns.form.source

    messages =
      if changeset.action do
        for {field, {message, opts}} <- changeset.errors, field == assigns.field do
          Enum.reduce(opts, message, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", to_string(value))
          end)
        end
      else
        []
      end

    assigns = assign(assigns, :messages, messages)

    ~H"""
    <p :for={message <- @messages} class="text-sm text-error" data-role="error">{message}</p>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:sources}>
      <h1 class="text-2xl font-semibold">{@page_title}</h1>

      <ul :if={is_nil(@collector)} id="source-types" class="space-y-2">
        <li :for={collector <- @collectors}>
          <.link navigate={~p"/sources/new?kind=#{collector.kind()}"} id={"type-#{collector.kind()}"}>{collector.label()}</.link>
        </li>
      </ul>

      <.form :if={@collector} for={@form} id="source-form" phx-change="validate" phx-submit="save" class="space-y-3 max-w-lg">
        <.dm_input id="source-name" name="source[name]" label="名称" value={@form[:name].value} />
        <.field_errors form={@form} field={:name} />

        <div :for={field <- @collector.config_fields()}>
          <.dm_select
            :if={field.type == :select}
            id={"config-#{field.name}"}
            name={"source[config][#{field.name}]"}
            label={field.label}
            value={config_value(@form, field.name)}
            options={Enum.map(field.options, &{&1, &1})}
          />
          <.dm_input
            :if={field.type != :select}
            id={"config-#{field.name}"}
            type={if field.type == :integer, do: "number", else: "text"}
            name={"source[config][#{field.name}]"}
            label={field.label}
            value={config_value(@form, field.name)}
          />
        </div>
        <.field_errors form={@form} field={:config} />

        <.dm_input id="source-interval" type="number" name="source[interval_minutes]" label="采集间隔（分钟）" value={@form[:interval_minutes].value} />
        <.field_errors form={@form} field={:interval_minutes} />

        <.dm_btn type="submit" variant="primary" id="source-save">保存</.dm_btn>
      </.form>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: 来源详情页**

`apps/singularity_web/lib/singularity_web/live/source_live/show.ex`：
```elixir
defmodule SingularityWeb.SourceLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]

  alias Singularity.{Collection, Sources}
  alias SingularityWeb.SourceLive.Index

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    source = Sources.get_source!(id)
    {:ok, assign(socket, source: source, runs: Collection.list_runs(source.id))}
  end

  @impl true
  def handle_event("collect", _params, socket) do
    {:ok, _job} = Collection.enqueue(socket.assigns.source.id)
    {:noreply, put_flash(socket, :info, "已加入采集队列")}
  end

  @impl true
  def handle_info({:fetch_run, %{source_id: source_id}}, %{assigns: %{source: %{id: source_id}}} = socket) do
    {:noreply, assign(socket, runs: Collection.list_runs(source_id))}
  end

  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:sources}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{@source.name}</h1>
        <div class="flex gap-2">
          <.dm_btn :if={@source.enabled} size="sm" id="collect-now" phx-click="collect">立即采集</.dm_btn>
          <.link navigate={~p"/sources/#{@source.id}/edit"}><.dm_btn size="sm">编辑</.dm_btn></.link>
        </div>
      </div>

      <dl class="grid grid-cols-[8rem_1fr] gap-1 text-sm">
        <dt>类型</dt><dd>{Sources.type_label(@source)}</dd>
        <dt>配置</dt><dd><code>{Jason.encode!(@source.config)}</code></dd>
        <dt>间隔</dt><dd>{@source.interval_minutes} 分钟</dd>
        <dt>状态</dt><dd>{if @source.enabled, do: "启用", else: "停用"}</dd>
        <dt>下次采集</dt><dd>{format_time(@source.next_run_at)}</dd>
      </dl>

      <h2 class="text-lg font-semibold">最近采集</h2>
      <.dm_table id="runs" data={@runs}>
        <:col :let={run} label="状态"><.dm_badge size="sm" variant={Index.run_variant(run.status)}>{run.status}</.dm_badge></:col>
        <:col :let={run} label="开始">{format_time(run.started_at)}</:col>
        <:col :let={run} label="结束">{format_time(run.finished_at)}</:col>
        <:col :let={run} label="条数">{run.item_count}</:col>
        <:col :let={run} label="跳过">{run.skipped_count}</:col>
        <:col :let={run} label="错误">{run.error}</:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 6: 运行测试**

Run: `devenv shell -- mix test apps/singularity_web`
Expected：全部 PASS。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat(web): manage sources and watch fetch runs"
```

---

### Task 14: mix 任务、Release、默认来源

**Files:**
- Create: `apps/singularity/lib/mix/tasks/singularity.collect.ex`、`apps/singularity/lib/singularity/release.ex`
- Modify: `apps/singularity/priv/repo/seeds.exs`、根目录的 `mix.exs`
- Create: `rel/overlays/bin/server`、`rel/overlays/bin/migrate`

- [ ] **Step 1: mix 任务**

`apps/singularity/lib/mix/tasks/singularity.collect.ex`：
```elixir
defmodule Mix.Tasks.Singularity.Collect do
  @shortdoc "Collects one source immediately, bypassing the job queue"
  @moduledoc "Usage: mix singularity.collect SOURCE_ID"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([id]) do
    source = Singularity.Sources.get_source!(String.to_integer(id))

    case Singularity.Collection.run(source) do
      {:ok, run} -> Mix.shell().info("ok: #{run.item_count} items, #{run.skipped_count} skipped")
      {:error, _reason, run} -> Mix.raise("failed: #{run.error}")
      {:error, :unavailable} -> Mix.raise("source type #{source.kind} is not registered")
    end
  end

  def run(_args), do: Mix.raise("usage: mix singularity.collect SOURCE_ID")
end
```

- [ ] **Step 2: seeds**

`apps/singularity/priv/repo/seeds.exs` 的全部内容：
```elixir
{:ok, _} = Singularity.Sources.ensure_default_source()
```

- [ ] **Step 3: Release 模块**

`apps/singularity/lib/singularity/release.ex`：
```elixir
defmodule Singularity.Release do
  @moduledoc "Release tasks: `bin/singularity eval Singularity.Release.migrate`."

  @app :singularity

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Singularity.Repo, fn _repo -> Singularity.Sources.ensure_default_source() end)

    :ok
  end
end
```

- [ ] **Step 4: release 配置与启动脚本**

在根目录 `mix.exs` 的 `project/0` 中加入 `releases: releases()`，并定义：
```elixir
  defp releases do
    [
      singularity: [
        applications: [singularity: :permanent, singularity_web: :permanent],
        include_executables_for: [:unix]
      ]
    ]
  end
```

`rel/overlays/bin/migrate`：
```sh
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
exec ./singularity eval Singularity.Release.migrate
```

`rel/overlays/bin/server`：
```sh
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
./singularity eval Singularity.Release.migrate
PHX_SERVER=true exec ./singularity start
```

```bash
chmod +x rel/overlays/bin/migrate rel/overlays/bin/server
```

- [ ] **Step 5: 验证**

```bash
devenv shell -- mix ecto.reset
devenv shell -- psql -d singularity_dev -Atc "select id, kind, name from sources"
devenv shell -- mix singularity.collect 1
devenv shell -- mix test
```
Expected：`ecto.reset` 通过 seeds 创建默认来源（id 1）；`singularity.collect 1` 输出 `ok: N items, 0 skipped`，其中 N > 0（这是一次真实的网络请求）；测试全部通过。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: add collect task, release migrations and default source"
```

---

### Task 15: Docker 与 CI

**Files:**
- Create: `Dockerfile`、`.dockerignore`、`.github/workflows/ci.yml`

- [ ] **Step 1: Dockerfile**

参照 `../backplane/Dockerfile` 中构建资源的方式（`mix npm.install --frozen`、`DUSKMOON_NATIVE_MODE=precompiled`、`mix assets.deploy`），写成单个 builder 阶段：
```dockerfile
ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-28.0.2-debian-bookworm-20250630-slim
ARG RUNNER_IMAGE=debian:bookworm-slim

FROM ${ELIXIR_IMAGE} AS builder
ENV MIX_ENV=prod DUSKMOON_NATIVE_MODE=precompiled LANG=C.UTF-8
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates curl git unzip \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/singularity/mix.exs ./apps/singularity/mix.exs
COPY apps/singularity_web/mix.exs ./apps/singularity_web/mix.exs
RUN mix deps.get --only prod && mix deps.compile

COPY . .
RUN mix assets.setup && mix assets.deploy && mix release singularity

FROM ${RUNNER_IMAGE}
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 locales openssl \
  && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 MIX_ENV=prod
WORKDIR /app
RUN useradd --system --home /app singularity && chown singularity /app
COPY --from=builder --chown=singularity /app/_build/prod/rel/singularity ./
USER singularity
EXPOSE 4000
CMD ["/app/bin/server"]
```
`mix assets.setup` 和 `mix assets.deploy` 是 Task 3 中 setup skill 在 `singularity_web` 里定义的 alias。如果 setup 产出的是 `package.json`，并且需要 `mix npm.install --frozen`，就在 `COPY . .` 之前按 backplane 的方式复制 `package.json` 和 lock 文件，再执行安装。

`.dockerignore`：
```
_build
deps
.devenv
.elixir_ls
node_modules
apps/singularity_web/priv/static/assets
.git
```

- [ ] **Step 2: 构建并冒烟测试**

```bash
docker build -t singularity:local .
docker run --rm --network host \
  -e DATABASE_URL="ecto://postgres:postgres@localhost/singularity_docker" \
  -e SECRET_KEY_BASE="$(devenv shell -- mix phx.gen.secret | tail -1)" \
  -e PHX_HOST=localhost singularity:local
```
Expected：镜像构建成功；容器执行 migration、创建默认来源，然后在 4000 端口提供服务（`curl -fsS localhost:4000/` 返回 200）。如果本地 PostgreSQL 只能通过 socket 访问，只验证 `docker build` 能成功，运行时验证留到部署时进行，并在最终报告中写明这一点。

- [ ] **Step 3: CI**

`.github/workflows/ci.yml`：
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5
    env:
      MIX_ENV: test
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "28"
          elixir-version: "1.18"
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix compile --warnings-as-errors
      - run: mix test

  docker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t singularity:ci .
```

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "ci: add test workflow and Docker image build"
```

---

### Task 16: 最终验证

- [ ] **Step 1: 完整的验证门槛**

```bash
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
git status --short
```
Expected：全部通过，工作区干净。

- [ ] **Step 2: 手动验收**

```bash
devenv shell -- mix phx.server
```
在浏览器中逐项确认：
1. `/sources` 显示默认来源；点"立即采集"后，状态由 running 变为 ok，**不需要手动刷新页面**。
2. 新建一个 GitHub Trending 来源：language 填 `elixir`，since 选 `weekly`。保存后自动开始第一次采集。
3. `/` 显示条目；选择单个来源后显示该来源的那一期列表；点进条目能看到观测历史。
4. 把 language 改成 `a/b`，表单显示校验错误。

- [ ] **Step 3: 对照 spec 自查**

对照 spec 第 1 节的成功标准逐条确认，并在最终报告中记录：提交列表、执行过的命令和结果、未验证的部分（例如 Docker 容器的运行时验证）。
