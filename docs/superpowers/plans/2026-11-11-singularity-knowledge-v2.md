# Singularity Knowledge v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Singularity 从"采集条目"改成以软件项目为知识的知识库：软件项目用规范化的 git 地址标识，从 GitHub 获取详情，带自动和手动 label；可以手动添加，也可以由 GitHub Trending 来源产出；新增 Settings（GitHub 令牌）和只读的 System 状态；按 backplane 的结构重做全部页面；HTTP 从 Req 换成 http_fetch；界面文字全部经 gettext，默认英文。

**Architecture:** 仍是两个 app 的 umbrella。`apps/singularity` 新增纯函数模块 `Knowledge.Address`、`Knowledge.Labels`，GitHub REST 客户端 `Singularity.GitHub`（纯函数 `parse_repo/1` + 不抛异常的 `fetch_repo/3`），所有 HTTP 都经过 `Singularity.HttpClient`（http_fetch 的薄封装，adapter 由应用配置注入，测试用 http_test），Styx worker `Knowledge.FetchDetailsWorker`（队列 `:details`，并发 1），新上下文 `Singularity.Settings`、`Singularity.System`。`apps/singularity_web` 用 `Layouts.app` 渲染 appbar 和 sticky `dm_left_menu`，按 Overview / Knowledge / Source / System 四个区重做页面，只调用 `Sources`、`Knowledge`、`Collection`、`Settings`、`System` 的公开函数；界面文字通过 `SingularityWeb.Gettext` 输出。

**Tech Stack:** Elixir 1.20.4 / OTP 29（devenv），Phoenix 1.8 + LiveView 1.2，phoenix_duskmoon 10.1.1（@duskmoon-dev/core 1.21.2），PostgreSQL 17，Styx 0.1.1，http_fetch / http_test 1.0.0-rc.11，Floki，gettext 1.0。

**Spec:** `docs/superpowers/specs/2026-11-11-singularity-knowledge-v2-design.md`

---

## 已核实的依赖 API

写本计划时对照 `deps/` 和 hex 包源码确认过，任务中的代码以此为准：

- **http_fetch 1.0.0-rc.11**
  - `HTTP.fetch(url, headers: [{name, value}], adapter: adapter, timeout: ms)` 返回 `%HTTP.Promise{}`；`timeout:` 是请求总时限，`adapter: nil`（默认）走真实 socket。
  - `HTTP.Promise.await(promise, ms)` 成功返回 `%HTTP.Response{}`，失败返回 `{:error, reason}`；等待超时返回 `{:error, :timeout}` 但**不取消**请求；任务进程崩溃时 `await` 会让调用方 `exit`。默认 `error_mode: :raw`，失败原因是原始项，实测：DNS 失败 `:nxdomain`，拒绝连接 `:econnrefused`，连接超时 `:connect_timeout`，请求超时 `:request_timeout`。
  - `%HTTP.Response{status, headers, body}`：`headers` 是 `%HTTP.Headers{}`，用 `HTTP.Headers.get(headers, "x-ratelimit-reset")`（大小写不敏感，返回字符串或 nil）或 `HTTP.Response.get_header/2` 读取。`HTTP.Response.text/1` 和 `json/1`（内部用 Elixir 的 `JSON`）在流式响应读取失败时会**抛 RuntimeError**。没有 Content-Length 或大于 5MB 的响应体是流（实测 trending 页面就是流），`text/1` 会读完整个流。
  - 不读取 `HTTPS_PROXY` 等环境变量（文档："Environment/NO_PROXY selection belongs to the caller"）。本机直连 api.github.com 和 github.com 已实测可用。
- **http_test 1.0.0-rc.11**（`adapter: {HTTP.Test, name}`，name 可以是任意项，只在注册它的进程及其 `$callers` 内有效）
  - `HTTP.Test.expect(name, count \\ 1, fun)`、`stub(name, fun)`、`allow(name, owner, pid)`、`verify!/0`、`verify_on_exit!/0`（在 `setup` 里调用，返回 `:ok`）。
  - `fun` 收到 `%HTTP.Request{url: %URI{}, headers: %HTTP.Headers{}}`，返回 `HTTP.Test.response(status, body, headers)`、`json(value, status)`、`text(body, status)`、`html(body, status)`、`status(code)`，`HTTP.Test.headers(response, headers)` 替换响应头；`HTTP.Test.transport_error(reason)` 让 fetch 返回 `{:error, reason}`；`HTTP.Test.stream(["chunk", {:error, reason}])` 模拟读到一半失败的流。
  - 没有注册 fixture 时返回 `{:error, {:http_test, reason}}`，不会落到真实网络。
- **phoenix_duskmoon 10.1.1**
  - `dm_left_menu`：`sticky socket={@socket}` 时内部 `live_render` 一个 sticky 子 LiveView，必须有稳定的 `id`，`active` 是 item id 字符串（`""` 表示无）。`groups` 是 `[%{id: "…", label: "…", open: true（可选）, items: [%{id: "…", label: "…", to: "/path", icon: "mdi-name"（可选）}]}]`，id 和 label 必须是非空字符串，item id 全局唯一。父页面会渲染 `#<id>-navigation[data-active-nav]` 标记，子视图渲染 `nav#<id>`，菜单链接带 `aria-label=label`。
  - `appbar appbar-sticky appbar-primary appbar-brand appbar-title appbar-actions appbar-action` 都来自 `@duskmoon-dev/core` 的 `components/appbar.css`，app.css 已 `@import "@duskmoon-dev/core/components"`，可直接使用；`.appbar-action` 默认是 2.5rem 圆形图标按钮，文字菜单要像 backplane 一样覆盖宽高。
  - `dm_stat`：`title`、`value`（都必须是字符串）、`description`、`id`。`dm_card`：`:title`、`:action` 插槽，渲染为 `<article>`。`dm_badge`：`variant`（primary/secondary/tertiary/accent/info/success/warning/error/ghost/neutral）、`size`（xs/sm/md/lg）、`pill`、`soft`、`outline`，渲染为 `<span>`，`data-*` 可透传。`dm_table`：`data` + `:col`（`label`）。`dm_input`：`name`/`value`/`label`/`type`/`errors`（字符串列表），透传 `placeholder`、`autocomplete`、`phx-*`。`dm_select`：`options` 是 `{value, label}` 元组。`dm_btn`：`variant`、`size`、`type`。`dm_mdi name="…"`，计划中用到的图标名都已确认存在。
  - 只有 `dm_btn`（`el-dm-button`）和 flash（`el-dm-alert`）用到自定义元素，`app.js` 已注册；`DuskmoonLeftMenu`、`DuskmoonLeftMenuNavigation` hook 由已有的 `...DuskmoonHooks` 提供。**`app.js` 不需要改动。**
- **Styx 0.1.1**：`perform/1` 可返回 `{:snooze, seconds}`（正整数）；`Styx.insert/1` 的 unique 插入在同一 Repo 里用嵌套事务，可以放进 `Repo.transaction`；unique 默认 `period: 60`，所以"同时只有一个任务"必须写 `period: :infinity`；`Styx.Job` 表的 `queue`、`state` 是字符串。
- **gettext 1.0.2**：`use Gettext.Backend, otp_app: :singularity_web`，模块中 `use Gettext, backend: SingularityWeb.Gettext` 导入 `gettext/dgettext/dngettext` 宏；运行时函数 `Gettext.dgettext(backend, domain, msgid, bindings)`。`mix gettext.extract` 是 recursive 任务，要在 `apps/singularity_web` 目录下运行；自动抽取的条目带 `elixir-autogen` 标记，手写在 `.pot` 中的条目（如 errors 域）会保留。
- **GitHub API**：`GET https://api.github.com/repos/elixir-lang/elixir` 实测返回 6.3KB 紧凑 JSON，未认证限额 60 次/小时，响应头带 `x-ratelimit-remaining` / `x-ratelimit-reset`（Unix 秒）。

## 执行约定

- 直接在 `main` 上工作，不创建分支或 worktree。
- 先 `devenv up -d` 启动 PostgreSQL；所有命令都用 `devenv shell -- <cmd>`。Web 测试在 umbrella 根目录用 `mix test apps/singularity_web/test/...` 运行，领域测试用 `mix test apps/singularity/test/...`。
- 网络经过很慢的代理。`mix deps.get` 和抓取 fixture 超时就重试，不要改用其它来源。
- 每个 Task 提交前依次运行：`devenv shell -- mix format`、`devenv shell -- mix compile --warnings-as-errors`、`devenv shell -- mix test`，全部通过再提交。commit 只按文件名暂存（不用 `git add -A`），message 不加 Co-Authored-By，也不加 "Generated with"。
- 改了界面文字的 Task 在提交前运行 `devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --merge'`，并把生成的 `.pot` / `.po` 一起提交。
- Styx、phoenix_duskmoon、duskmoon_bundler、http_fetch、http_test 都是自维护的库。遇到缺陷或缺少功能时**停下来**，按 upstream-issue-routing 去对应仓库提 issue，不在本地绕过。
- 不新增本计划以外的流程文档、回执或清单。

## 文件结构

```
apps/singularity/
  mix.exs                                   （http_fetch、http_test；移除 req）
  lib/singularity/
    http_client.ex                          新：http_fetch 的薄封装，不抛异常
    github.ex                               新：fetch_repo/3、parse_repo/1
    settings.ex                             新：Settings 上下文
    settings/setting.ex                     新：Setting schema
    system.ex                               新：System.status/0
    knowledge.ex                            改：软件项目查询、label、add_project、details、record
    knowledge/address.ex                    新：Address.normalize/1
    knowledge/labels.ex                     新：Labels.auto_labels/2
    knowledge/label.ex                      新：item_labels schema
    knowledge/item.ex                       改：details 字段、labels 关联
    knowledge/observation.ex                改：source_id 可空
    knowledge/fetch_details_worker.ex       新
    collection.ex                           改：list_recent_runs/1
    collectors/github_trending.ex           改：http_fetch、software_project
    sources.ex                              改：删除 type_label/1
  priv/repo/migrations/20261111090000_knowledge_v2.exs
  test/fixtures/github_api/elixir.json      新：真实 API 响应
  test/support/fixtures.ex                  改：project/label/observation fixture
  test/singularity/
    http_client_test.exs, github_test.exs, settings_test.exs, system_test.exs
    knowledge/address_test.exs, knowledge/labels_test.exs, knowledge/fetch_details_worker_test.exs
    knowledge_projects_test.exs, knowledge_add_project_test.exs
    knowledge_record_test.exs, schema_test.exs, collection_test.exs, sources_test.exs（改）
    collectors/github_trending_test.exs（改）
    knowledge_query_test.exs（删除）
apps/singularity_web/
  mix.exs                                   （gettext）
  lib/singularity_web.ex                    改：html_helpers 引入 Gettext 和 FormHelpers
  lib/singularity_web/gettext.ex            新
  lib/singularity_web/form_helpers.ex       新：translate_error/1、field_errors/1
  lib/singularity_web/components/layouts.ex 改：appbar + dm_left_menu
  lib/singularity_web/components/item_components.ex  改：project_card 等
  lib/singularity_web/components/run_components.ex   新
  lib/singularity_web/live/overview_live/index.ex, activity.ex
  lib/singularity_web/live/knowledge_live/index.ex, show.ex
  lib/singularity_web/live/source_live/index.ex, form.ex, show.ex（改）, add.ex, runs.ex（新）
  lib/singularity_web/live/system_live/github.ex, status.ex
  lib/singularity_web/live/item_live/（删除）
  lib/singularity_web/router.ex
  assets/css/app.css                        改：appbar 文字菜单样式
  priv/gettext/{default,errors,overview,knowledge,source,system}.pot
  priv/gettext/en/LC_MESSAGES/*.po
  test/singularity_web/form_helpers_test.exs
  test/singularity_web/live/{overview,knowledge,source,system}_live_test.exs, navigation_test.exs
  test/singularity_web/live/item_live_test.exs（删除）
config/config.exs, config/test.exs
AGENTS.md, mix.exs（版本号）
```

---
### Task 1: HTTP 换成 http_fetch，移除 Req

**Files:**
- Modify: `apps/singularity/mix.exs`、`mix.lock`、`config/test.exs`
- Create: `apps/singularity/lib/singularity/http_client.ex`
- Modify: `apps/singularity/lib/singularity/collectors/github_trending.ex`
- Test: `apps/singularity/test/singularity/http_client_test.exs`（新）、`apps/singularity/test/singularity/collectors/github_trending_test.exs`（改）

- [ ] **Step 1: 先加新依赖（暂时保留 req）**

`apps/singularity/mix.exs` 的 `deps/0` 改为：
```elixir
  defp deps do
    [
      {:dns_cluster, "~> 0.2.0"},
      {:phoenix_pubsub, "~> 2.4"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      {:styx, "~> 0.1.1"},
      {:req, "~> 0.5"},
      {:http_fetch, "~> 1.0.0-rc.11"},
      {:http_test, "~> 1.0.0-rc.11", only: :test},
      {:floki, ">= 0.30.0"}
    ]
  end
```

Run: `devenv shell -- mix deps.get`（超时就重试）
Expected：下载 `http_test 1.0.0-rc.11`，`mix.lock` 中出现 `"http_test"`。

- [ ] **Step 2: 写失败的测试**

`apps/singularity/test/singularity/http_client_test.exs`：
```elixir
defmodule Singularity.HttpClientTest do
  use ExUnit.Case, async: true

  alias Singularity.HttpClient

  @adapter {HTTP.Test, :http_client}

  setup do
    HTTP.Test.verify_on_exit!()
  end

  test "returns status, headers and the whole body" do
    HTTP.Test.expect(:http_client, fn request ->
      assert request.url.path == "/hello"
      assert HTTP.Headers.get(request.headers, "user-agent") == "Singularity"
      HTTP.Test.response(201, "hi", [{"x-test", "yes"}])
    end)

    assert {:ok, %{status: 201, body: "hi", headers: headers}} =
             HttpClient.get("https://example.test/hello", [{"User-Agent", "Singularity"}], @adapter)

    assert HTTP.Headers.get(headers, "x-test") == "yes"
  end

  test "maps transport failures to {:transport, message}" do
    HTTP.Test.expect(:http_client, fn _request -> HTTP.Test.transport_error(:econnrefused) end)

    assert {:error, {:transport, "econnrefused"}} =
             HttpClient.get("https://example.test/", [], @adapter)
  end

  test "maps a body that fails mid-stream to a transport error instead of raising" do
    HTTP.Test.expect(:http_client, fn _request ->
      HTTP.Test.stream(["partial", {:error, :closed}])
    end)

    assert {:error, {:transport, message}} = HttpClient.get("https://example.test/", [], @adapter)
    assert message =~ "closed"
  end
end
```

在 `apps/singularity/test/singularity/collectors/github_trending_test.exs` 中，把整个 `describe "fetch/2"` 块替换为：
```elixir
  describe "fetch/2" do
    setup do
      HTTP.Test.verify_on_exit!()
    end

    test "requests the language page and returns a dated result" do
      HTTP.Test.expect(GithubTrending, fn request ->
        assert request.url.path == "/trending/c%2B%2B"
        assert request.url.query == "since=weekly"
        assert HTTP.Headers.get(request.headers, "user-agent") == "Singularity"
        HTTP.Test.html(fixture("minimal.html"))
      end)

      assert {:ok, %Result{period: "2026-11-09", entries: [_, _], skipped: 1}} =
               GithubTrending.fetch(
                 %{"language" => "c++", "since" => "weekly"},
                 ~U[2026-11-09 23:30:00Z]
               )
    end

    test "requests the all-languages page when language is blank" do
      HTTP.Test.expect(GithubTrending, fn request ->
        assert request.url.path == "/trending"
        HTTP.Test.html(fixture("minimal.html"))
      end)

      assert {:ok, _} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end

    test "maps non-200 responses to errors" do
      HTTP.Test.expect(GithubTrending, fn _request -> HTTP.Test.text("slow down", 429) end)

      assert {:error, {:http_status, 429}} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end

    test "maps transport failures to errors instead of raising" do
      HTTP.Test.expect(GithubTrending, fn _request -> HTTP.Test.transport_error(:econnrefused) end)

      assert {:error, {:transport, "econnrefused"}} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end
  end
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/http_client_test.exs apps/singularity/test/singularity/collectors/github_trending_test.exs`
Expected：FAIL。`HttpClient` 测试报 `Singularity.HttpClient.get/3 is undefined`；`fetch/2` 的测试因为仍走 Req（找不到 `Req.Test` stub）而失败，并且 `verify_on_exit!` 报告有未消费的 expectation。

- [ ] **Step 4: 实现**

`apps/singularity/lib/singularity/http_client.ex`：
```elixir
defmodule Singularity.HttpClient do
  @moduledoc """
  The one place that talks to http_fetch: a GET with a 15 second deadline whose
  body is read completely. Never raises; every failure becomes
  `{:error, {:transport, message}}`. Callers pass the adapter from their
  application config (`nil` in production, `{HTTP.Test, name}` in tests).
  """

  @timeout 15_000

  @type response :: %{status: pos_integer(), headers: HTTP.Headers.t(), body: binary()}

  @spec get(String.t(), [{String.t(), String.t()}], module() | {module(), term()} | nil) ::
          {:ok, response()} | {:error, {:transport, String.t()}}
  def get(url, headers, adapter) do
    url
    |> HTTP.fetch(headers: headers, adapter: adapter, timeout: @timeout)
    # The fetch gives its worker up to one more second to report its own timeout.
    |> HTTP.Promise.await(@timeout + 2_000)
    |> read()
  catch
    # HTTP.Promise.await/2 exits the caller when the request process crashes.
    :exit, reason -> {:error, {:transport, "request exited: " <> inspect(reason)}}
  end

  # HTTP.Response.text/1 raises when a streamed body fails part way.
  defp read(%HTTP.Response{} = response) do
    {:ok,
     %{status: response.status, headers: response.headers, body: HTTP.Response.text(response)}}
  rescue
    exception -> {:error, {:transport, Exception.message(exception)}}
  end

  defp read({:error, reason}), do: {:error, {:transport, describe(reason)}}

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
```

`apps/singularity/lib/singularity/collectors/github_trending.ex`：
- 在 `alias Singularity.Collector.{Entry, Result}` 下面加一行 `alias Singularity.HttpClient`。
- 把 `fetch/2` 替换为：
```elixir
  @impl true
  def fetch(config, now) do
    case HttpClient.get(trending_url(config), [{"User-Agent", "Singularity"}], adapter()) do
      {:ok, %{status: 200, body: body}} ->
        {entries, skipped} = parse(body, config["since"])
        period = now |> DateTime.to_date() |> Date.to_iso8601()
        {:ok, %Result{period: period, entries: entries, skipped: skipped}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, {:transport, _message}} = error ->
        error
    end
  end
```
- 把文件末尾的 `req_options/0` 替换为：
```elixir
  defp adapter, do: :singularity |> Application.get_env(__MODULE__, []) |> Keyword.get(:adapter)
```

`config/test.exs` 中把
```elixir
config :singularity, Singularity.Collectors.GithubTrending,
  req_options: [plug: {Req.Test, Singularity.Collectors.GithubTrending}]
```
替换为：
```elixir
config :singularity, Singularity.Collectors.GithubTrending,
  adapter: {HTTP.Test, Singularity.Collectors.GithubTrending}
```

- [ ] **Step 5: 移除 Req**

从 `apps/singularity/mix.exs` 的 `deps/0` 中删除 `{:req, "~> 0.5"},` 这一行，然后：
```bash
devenv shell -- mix deps.unlock --unused
grep -nE '"(req|finch)":' mix.lock
grep -rn 'Req\.' apps/*/lib apps/*/test config
devenv shell -- mix compile --warnings-as-errors
```
Expected：两个 `grep` 都没有输出；编译通过，没有警告。

- [ ] **Step 6: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test`
Expected：全部 PASS。

- [ ] **Step 7: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/mix.exs mix.lock config/test.exs \
  apps/singularity/lib/singularity/http_client.ex \
  apps/singularity/lib/singularity/collectors/github_trending.ex \
  apps/singularity/test/singularity/http_client_test.exs \
  apps/singularity/test/singularity/collectors/github_trending_test.exs
git commit -m "refactor: fetch GitHub Trending with http_fetch and drop Req"
```

---

### Task 2: v2 数据表与 schema

**Files:**
- Create: `apps/singularity/priv/repo/migrations/20261111090000_knowledge_v2.exs`
- Create: `apps/singularity/lib/singularity/knowledge/label.ex`、`apps/singularity/lib/singularity/settings/setting.ex`
- Modify: `apps/singularity/lib/singularity/knowledge/item.ex`、`apps/singularity/lib/singularity/knowledge/observation.ex`
- Test: `apps/singularity/test/singularity/schema_test.exs`

- [ ] **Step 1: 写失败的测试**

`apps/singularity/test/singularity/schema_test.exs`：把 `alias Singularity.Knowledge.{Item, Observation}` 改为
```elixir
  alias Singularity.Knowledge.{Item, Label, Observation}
  alias Singularity.Settings.Setting
```
并在模块末尾（最后一个 `end` 之前）加入：
```elixir
  test "labels are normalized, unique per item and name, and deleted with the item" do
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    attrs = %{item_id: item.id, name: "  Lang:Elixir ", origin: "manual"}

    label = Repo.insert!(Label.changeset(%Label{}, attrs))
    assert label.name == "lang:elixir"

    assert {:error, changeset} = Repo.insert(Label.changeset(%Label{}, attrs))
    assert %{item_id: ["has already been taken"]} = errors_on(changeset)

    assert %{origin: ["is invalid"]} =
             errors_on(Label.changeset(%Label{}, %{attrs | origin: "other"}))

    Repo.delete!(item)
    assert Repo.aggregate(Label, :count) == 0
  end

  test "manual observations have no source and are unique per item and period" do
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))

    attrs = %{
      item_id: item.id,
      period: "2026-11-11",
      observed_at: now(),
      attributes: %{"via" => "manual"}
    }

    assert %Observation{source_id: nil} = Repo.insert!(Observation.changeset(%Observation{}, attrs))
    assert {:error, _changeset} = Repo.insert(Observation.changeset(%Observation{}, attrs))
  end

  test "new items have no details yet" do
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    assert %Item{details_fetched_at: nil, details_error: nil} = item
  end

  test "settings are unique per key" do
    Repo.insert!(Setting.changeset(%Setting{}, %{key: "k", value: "v"}))
    assert {:error, changeset} = Repo.insert(Setting.changeset(%Setting{}, %{key: "k", value: "w"}))
    assert %{key: ["has already been taken"]} = errors_on(changeset)
  end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/schema_test.exs`
Expected：FAIL，编译错误提示 `Singularity.Knowledge.Label.__struct__/1 is undefined`（或 `Setting`）。

- [ ] **Step 3: 实现**

`apps/singularity/priv/repo/migrations/20261111090000_knowledge_v2.exs`：
```elixir
defmodule Singularity.Repo.Migrations.KnowledgeV2 do
  use Ecto.Migration

  def up do
    # v1 data is disposable (spec §3): the knowledge base starts empty.
    execute "DELETE FROM item_observations"
    execute "DELETE FROM fetch_runs"
    execute "DELETE FROM items"

    alter table(:items) do
      add :details_fetched_at, :utc_datetime
      add :details_error, :text
    end

    create table(:item_labels) do
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :origin, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:item_labels, [:item_id, :name])
    create index(:item_labels, [:name])

    # Manual additions have no source. NULLS NOT DISTINCT keeps them unique per
    # item and period, so ON CONFLICT on these columns stays idempotent.
    drop unique_index(:item_observations, [:source_id, :item_id, :period])
    execute "ALTER TABLE item_observations ALTER COLUMN source_id DROP NOT NULL"

    create unique_index(:item_observations, [:source_id, :item_id, :period],
             nulls_distinct: false
           )

    create table(:settings) do
      add :key, :string, null: false
      add :value, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:key])
  end

  def down do
    drop table(:settings)

    execute "DELETE FROM item_observations WHERE source_id IS NULL"
    drop unique_index(:item_observations, [:source_id, :item_id, :period])
    execute "ALTER TABLE item_observations ALTER COLUMN source_id SET NOT NULL"
    create unique_index(:item_observations, [:source_id, :item_id, :period])

    drop table(:item_labels)

    alter table(:items) do
      remove :details_fetched_at
      remove :details_error
    end
  end
end
```

`apps/singularity/lib/singularity/knowledge/label.ex`：
```elixir
defmodule Singularity.Knowledge.Label do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @origins ~w(auto manual)

  schema "item_labels" do
    belongs_to :item, Singularity.Knowledge.Item
    field :name, :string
    field :origin, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:item_id, :name, :origin])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:item_id, :name, :origin])
    |> validate_length(:name, max: 100)
    |> validate_inclusion(:origin, @origins)
    |> unique_constraint([:item_id, :name])
  end

  @doc "Labels are compared trimmed and lowercased."
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
end
```

`apps/singularity/lib/singularity/settings/setting.ex`：
```elixir
defmodule Singularity.Settings.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "settings" do
    field :key, :string
    field :value, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
```

`apps/singularity/lib/singularity/knowledge/item.ex` 的 `schema "items"` 块改为：
```elixir
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
    field :details_fetched_at, :utc_datetime
    field :details_error, :string
    has_many :observations, Singularity.Knowledge.Observation
    has_many :labels, Singularity.Knowledge.Label
    timestamps(type: :utc_datetime)
  end
```

`apps/singularity/lib/singularity/knowledge/observation.ex`：把 `@required [:item_id, :source_id, :period, :observed_at]` 改为
```elixir
  @required [:item_id, :period, :observed_at]
```
并把 `changeset/2` 中的 `cast` 改为：
```elixir
    |> cast(attrs, @required ++ [:source_id, :rank, :attributes, :raw])
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test`
Expected：全部 PASS（`mix test` 别名会先执行新迁移）。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/priv/repo/migrations/20261111090000_knowledge_v2.exs \
  apps/singularity/lib/singularity/knowledge/label.ex \
  apps/singularity/lib/singularity/settings/setting.ex \
  apps/singularity/lib/singularity/knowledge/item.ex \
  apps/singularity/lib/singularity/knowledge/observation.ex \
  apps/singularity/test/singularity/schema_test.exs
git commit -m "feat: add v2 knowledge schema for labels, details state and settings"
```

---

### Task 3: Address.normalize/1

**Files:**
- Create: `apps/singularity/lib/singularity/knowledge/address.ex`
- Test: `apps/singularity/test/singularity/knowledge/address_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule Singularity.Knowledge.AddressTest do
  use ExUnit.Case, async: true

  alias Singularity.Knowledge.Address

  @elixir %{
    external_id: "github.com/elixir-lang/elixir",
    owner: "elixir-lang",
    repo: "elixir",
    url: "https://github.com/elixir-lang/elixir"
  }

  test "accepts the supported GitHub address forms" do
    for input <- [
          "elixir-lang/elixir",
          " elixir-lang/elixir ",
          "elixir-lang/elixir.git",
          "github.com/elixir-lang/elixir",
          "www.github.com/elixir-lang/elixir",
          "https://github.com/elixir-lang/elixir",
          "http://github.com/elixir-lang/elixir/",
          "https://github.com/elixir-lang/elixir.git",
          "https://github.com/elixir-lang/elixir/tree/main/lib",
          "https://github.com/elixir-lang/elixir?tab=readme#top",
          "git@github.com:elixir-lang/elixir.git"
        ] do
      assert Address.normalize(input) == {:ok, @elixir}, "input: #{inspect(input)}"
    end
  end

  test "lowercases the external id and keeps the given spelling elsewhere" do
    assert Address.normalize("https://GitHub.com/PhoenixFramework/Phoenix_Live_View") ==
             {:ok,
              %{
                external_id: "github.com/phoenixframework/phoenix_live_view",
                owner: "PhoenixFramework",
                repo: "Phoenix_Live_View",
                url: "https://github.com/PhoenixFramework/Phoenix_Live_View"
              }}
  end

  test "keeps dots in repository names" do
    assert {:ok, %{external_id: "github.com/vercel/next.js", repo: "next.js"}} =
             Address.normalize("vercel/next.js")
  end

  test "rejects non-GitHub and malformed addresses" do
    for input <- [
          "",
          "elixir",
          "https://gitlab.com/a/b",
          "gitlab.com/a/b",
          "git@gitlab.com:a/b.git",
          "example.com/a",
          "https://github.com/elixir-lang",
          "a/b/c",
          "-bad/repo",
          "owner/..",
          nil,
          42
        ] do
      assert Address.normalize(input) == {:error, :unsupported_address}, "input: #{inspect(input)}"
    end
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge/address_test.exs`
Expected：FAIL，`Singularity.Knowledge.Address.normalize/1 is undefined`。

- [ ] **Step 3: 实现**

```elixir
defmodule Singularity.Knowledge.Address do
  @moduledoc """
  Normalizes GitHub repository addresses into the `github.com/<owner>/<repo>`
  key (lowercase) that identifies a software project. Other hosts are not
  supported yet.
  """

  @scp ~r/^git@github\.com:(.+)$/i
  @url ~r/^(?:https?:\/\/)?(?:www\.)?github\.com\/(.*)$/i
  @bare ~r/^[^\/.:@\s]+\/[^\/:@\s]+$/
  @owner ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/
  @repo ~r/^[A-Za-z0-9._-]{1,100}$/

  @type t :: %{external_id: String.t(), owner: String.t(), repo: String.t(), url: String.t()}

  @spec normalize(term()) :: {:ok, t()} | {:error, :unsupported_address}
  def normalize(input) when is_binary(input), do: input |> String.trim() |> path() |> parse()
  def normalize(_input), do: {:error, :unsupported_address}

  defp path(text) do
    case {Regex.run(@scp, text), Regex.run(@url, text)} do
      {[_, path], _} -> path
      {nil, [_, path]} -> path
      {nil, nil} -> if Regex.match?(@bare, text), do: text
    end
  end

  defp parse(nil), do: {:error, :unsupported_address}

  defp parse(path) do
    [path | _query_or_fragment] = String.split(path, ["?", "#"], parts: 2)

    case String.split(path, "/", trim: true) do
      [owner, repo | _rest] -> build(owner, String.replace_suffix(repo, ".git", ""))
      _ -> {:error, :unsupported_address}
    end
  end

  defp build(owner, repo) do
    if Regex.match?(@owner, owner) and Regex.match?(@repo, repo) and repo not in [".", ".."] do
      {:ok,
       %{
         external_id: String.downcase("github.com/#{owner}/#{repo}"),
         owner: owner,
         repo: repo,
         url: "https://github.com/#{owner}/#{repo}"
       }}
    else
      {:error, :unsupported_address}
    end
  end
end
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge/address_test.exs`
Expected：全部 PASS。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/lib/singularity/knowledge/address.ex \
  apps/singularity/test/singularity/knowledge/address_test.exs
git commit -m "feat: normalize GitHub repository addresses"
```

---

### Task 4: Labels.auto_labels/2

**Files:**
- Create: `apps/singularity/lib/singularity/knowledge/labels.ex`
- Test: `apps/singularity/test/singularity/knowledge/labels_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule Singularity.Knowledge.LabelsTest do
  use ExUnit.Case, async: true

  alias Singularity.Knowledge.Labels

  test "derives language, topic, trending and archived labels" do
    attributes = %{"language" => "Elixir", "topics" => ["web", "Phoenix"], "archived" => true}

    assert Labels.auto_labels(attributes, ["daily", "weekly"]) == [
             "lang:elixir",
             "topic:web",
             "topic:phoenix",
             "trending:daily",
             "trending:weekly",
             "archived"
           ]
  end

  test "skips missing and blank values and removes duplicates" do
    assert Labels.auto_labels(%{"language" => nil, "topics" => nil, "archived" => false}, []) == []
    assert Labels.auto_labels(%{}, ["daily", "daily", "", nil]) == ["trending:daily"]
    assert Labels.auto_labels(%{"language" => " ", "topics" => ["", "x"]}, []) == ["topic:x"]
  end

  test "keeps a multi-word language as one label" do
    assert Labels.auto_labels(%{"language" => "Jupyter Notebook"}, []) == ["lang:jupyter notebook"]
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge/labels_test.exs`
Expected：FAIL，`Singularity.Knowledge.Labels.auto_labels/2 is undefined`。

- [ ] **Step 3: 实现**

```elixir
defmodule Singularity.Knowledge.Labels do
  @moduledoc "Pure rules for a software project's automatic labels."

  @doc """
  Labels derived from GitHub attributes and the `since` values of the project's
  trending observations: `lang:<language>`, `topic:<topic>`, `trending:<since>`
  and `archived`. Lowercase, no duplicates.
  """
  @spec auto_labels(map(), [String.t() | nil]) :: [String.t()]
  def auto_labels(attributes, observation_sinces)
      when is_map(attributes) and is_list(observation_sinces) do
    (prefixed("lang:", attributes["language"]) ++
       Enum.flat_map(List.wrap(attributes["topics"]), &prefixed("topic:", &1)) ++
       Enum.flat_map(observation_sinces, &prefixed("trending:", &1)) ++
       archived(attributes["archived"]))
    |> Enum.uniq()
  end

  defp prefixed(prefix, value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> []
      value -> [prefix <> value]
    end
  end

  defp prefixed(_prefix, _value), do: []

  defp archived(true), do: ["archived"]
  defp archived(_archived), do: []
end
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge/labels_test.exs`
Expected：全部 PASS。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/lib/singularity/knowledge/labels.ex \
  apps/singularity/test/singularity/knowledge/labels_test.exs
git commit -m "feat: derive automatic project labels"
```

---
### Task 5: GitHub 客户端

**Files:**
- Create: `apps/singularity/test/fixtures/github_api/elixir.json`（真实响应）
- Create: `apps/singularity/lib/singularity/github.ex`
- Modify: `config/test.exs`
- Test: `apps/singularity/test/singularity/github_test.exs`

- [ ] **Step 1: 抓取真实 API 响应作为 fixture**

```bash
mkdir -p apps/singularity/test/fixtures/github_api
curl -sS --fail -m 120 \
  -H 'Accept: application/vnd.github+json' -H 'User-Agent: Singularity' \
  https://api.github.com/repos/elixir-lang/elixir \
  -o apps/singularity/test/fixtures/github_api/elixir.json
grep -c '"full_name":"elixir-lang/elixir"' apps/singularity/test/fixtures/github_api/elixir.json
wc -c apps/singularity/test/fixtures/github_api/elixir.json
```
Expected：`grep` 输出 `1`；文件约 6KB（GitHub 返回紧凑 JSON），不需要裁剪。超时就重试；如果返回 403（限流），等 `x-ratelimit-reset` 之后再试。

- [ ] **Step 2: 写失败的测试**

`apps/singularity/test/singularity/github_test.exs`：
```elixir
defmodule Singularity.GitHubTest do
  use ExUnit.Case, async: true

  alias Singularity.GitHub

  @fixture Path.join([__DIR__, "../fixtures/github_api/elixir.json"])
  @now ~U[2026-11-11 08:00:00Z]

  defp repo_json, do: @fixture |> File.read!() |> JSON.decode!()

  describe "parse_repo/1" do
    test "extracts details from a real API response" do
      assert %{title: "elixir-lang/elixir", summary: summary, attributes: attributes} =
               GitHub.parse_repo(repo_json())

      assert is_binary(summary)

      assert %{
               "language" => "Elixir",
               "license" => "Apache-2.0",
               "archived" => false,
               "created_at" => "2011-01-09T08:43:57Z",
               "default_branch" => "main"
             } = attributes

      assert is_integer(attributes["stars"]) and attributes["stars"] > 0
      assert is_integer(attributes["forks"])
      assert is_list(attributes["topics"])
      assert is_binary(attributes["homepage"])
      assert is_binary(attributes["pushed_at"])

      assert attributes |> Map.keys() |> Enum.sort() ==
               ~w(archived created_at default_branch forks homepage language license pushed_at stars topics)
    end

    test "tolerates missing fields" do
      json = Map.drop(repo_json(), ~w(description language topics license homepage archived))

      assert %{summary: nil, attributes: attributes} = GitHub.parse_repo(json)

      assert %{
               "language" => nil,
               "topics" => [],
               "license" => nil,
               "homepage" => nil,
               "archived" => false
             } = attributes
    end

    test "marks archived repositories and drops blank homepages" do
      json =
        repo_json()
        |> Map.put("archived", true)
        |> Map.put("homepage", "")
        |> Map.put("topics", ["lang", "web"])
        |> Map.put("license", %{"spdx_id" => "NOASSERTION", "name" => "Other"})

      assert %{
               attributes: %{
                 "archived" => true,
                 "homepage" => nil,
                 "topics" => ["lang", "web"],
                 "license" => "Other"
               }
             } = GitHub.parse_repo(json)
    end
  end

  describe "fetch_repo/3" do
    setup do
      HTTP.Test.verify_on_exit!()
    end

    test "requests the repository with GitHub headers and returns parsed details" do
      HTTP.Test.expect(GitHub, fn request ->
        assert request.url.host == "api.github.com"
        assert request.url.path == "/repos/elixir-lang/elixir"
        assert HTTP.Headers.get(request.headers, "accept") == "application/vnd.github+json"
        assert HTTP.Headers.get(request.headers, "user-agent") == "Singularity"
        assert HTTP.Headers.get(request.headers, "authorization") == nil
        HTTP.Test.response(200, File.read!(@fixture), [{"content-type", "application/json"}])
      end)

      assert {:ok, %{title: "elixir-lang/elixir", attributes: %{"language" => "Elixir"}}} =
               GitHub.fetch_repo("elixir-lang", "elixir", token: nil)
    end

    test "sends a token as a bearer token" do
      HTTP.Test.expect(GitHub, fn request ->
        assert HTTP.Headers.get(request.headers, "authorization") == "Bearer secret"
        HTTP.Test.response(200, File.read!(@fixture))
      end)

      assert {:ok, _details} = GitHub.fetch_repo("elixir-lang", "elixir", token: "secret")
    end

    test "maps 404 to :not_found" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(404) end)
      assert {:error, :not_found} = GitHub.fetch_repo("nobody", "nothing")
    end

    test "maps an exhausted rate limit to the seconds until x-ratelimit-reset" do
      reset = Integer.to_string(DateTime.to_unix(@now) + 120)

      HTTP.Test.expect(GitHub, fn _request ->
        HTTP.Test.status(403)
        |> HTTP.Test.headers([{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", reset}])
      end)

      assert {:error, {:rate_limited, 120}} = GitHub.fetch_repo("a", "b", now: @now)
    end

    test "prefers retry-after" do
      HTTP.Test.expect(GitHub, fn _request ->
        HTTP.Test.status(429) |> HTTP.Test.headers([{"retry-after", "30"}])
      end)

      assert {:error, {:rate_limited, 30}} = GitHub.fetch_repo("a", "b", now: @now)
    end

    test "treats a 403 without rate limit headers as an HTTP error" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(403) end)
      assert {:error, {:http_status, 403}} = GitHub.fetch_repo("a", "b", now: @now)
    end

    test "maps other statuses and unreadable bodies" do
      HTTP.Test.expect(GitHub, 2, fn request ->
        case request.url.path do
          "/repos/a/server-error" -> HTTP.Test.status(500)
          "/repos/a/html" -> HTTP.Test.html("<html></html>")
        end
      end)

      assert {:error, {:http_status, 500}} = GitHub.fetch_repo("a", "server-error")
      assert {:error, :invalid_response} = GitHub.fetch_repo("a", "html")
    end

    test "maps connection errors to transport errors" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.transport_error(:nxdomain) end)
      assert {:error, {:transport, "nxdomain"}} = GitHub.fetch_repo("a", "b")
    end
  end
end
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/github_test.exs`
Expected：FAIL，`Singularity.GitHub.parse_repo/1 is undefined`。

- [ ] **Step 4: 实现**

`apps/singularity/lib/singularity/github.ex`：
```elixir
defmodule Singularity.GitHub do
  @moduledoc """
  GitHub REST client on http_fetch. `fetch_repo/3` never raises; turning the
  JSON into project details is the pure `parse_repo/1`.
  """

  alias Singularity.HttpClient

  @api "https://api.github.com"

  @type details :: %{title: String.t() | nil, summary: String.t() | nil, attributes: map()}
  @type error ::
          :not_found
          | :invalid_response
          | {:rate_limited, pos_integer()}
          | {:http_status, pos_integer()}
          | {:transport, String.t()}

  @doc """
  `GET /repos/:owner/:repo`. Options: `:token` (sent as a bearer token when
  present) and `:now` (turns `x-ratelimit-reset` into a delay; defaults to now).
  """
  @spec fetch_repo(String.t(), String.t(), keyword()) :: {:ok, details()} | {:error, error()}
  def fetch_repo(owner, repo, opts \\ []) do
    url = "#{@api}/repos/#{encode(owner)}/#{encode(repo)}"

    headers =
      [{"Accept", "application/vnd.github+json"}, {"User-Agent", "Singularity"}] ++
        authorization(opts[:token])

    case HttpClient.get(url, headers, adapter()) do
      {:ok, %{status: 200, body: body}} ->
        decode(body)

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, headers: response_headers}} when status in [403, 429] ->
        rate_limited(status, response_headers, Keyword.get(opts, :now, DateTime.utc_now()))

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, {:transport, _message}} = error ->
        error
    end
  end

  @doc "Pure: turns a `GET /repos/:owner/:repo` JSON object into project details."
  @spec parse_repo(map()) :: details()
  def parse_repo(json) when is_map(json) do
    %{
      title: json["full_name"],
      summary: blank_to_nil(json["description"]),
      attributes: %{
        "stars" => json["stargazers_count"],
        "forks" => json["forks_count"],
        "language" => json["language"],
        "topics" => topics(json["topics"]),
        "license" => license(json["license"]),
        "homepage" => blank_to_nil(json["homepage"]),
        "archived" => json["archived"] == true,
        "created_at" => json["created_at"],
        "pushed_at" => json["pushed_at"],
        "default_branch" => json["default_branch"]
      }
    }
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = json} -> {:ok, parse_repo(json)}
      _other -> {:error, :invalid_response}
    end
  end

  defp rate_limited(status, headers, now) do
    case retry_after(headers) || until_reset(headers, now) do
      nil -> {:error, {:http_status, status}}
      seconds -> {:error, {:rate_limited, max(seconds, 1)}}
    end
  end

  defp retry_after(headers), do: headers |> HTTP.Headers.get("retry-after") |> to_integer()

  defp until_reset(headers, now) do
    with "0" <- HTTP.Headers.get(headers, "x-ratelimit-remaining"),
         reset when is_integer(reset) <-
           headers |> HTTP.Headers.get("x-ratelimit-reset") |> to_integer() do
      reset - DateTime.to_unix(now)
    else
      _no_reset -> nil
    end
  end

  defp to_integer(nil), do: nil

  defp to_integer(text) do
    case Integer.parse(String.trim(text)) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp topics(topics) when is_list(topics), do: Enum.filter(topics, &is_binary/1)
  defp topics(_topics), do: []

  defp license(%{"spdx_id" => id}) when is_binary(id) and id not in ["", "NOASSERTION"], do: id
  defp license(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp license(_license), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp authorization(token) when is_binary(token) and token != "",
    do: [{"Authorization", "Bearer " <> token}]

  defp authorization(_token), do: []

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp adapter, do: :singularity |> Application.get_env(__MODULE__, []) |> Keyword.get(:adapter)
end
```

`config/test.exs` 中，在 GithubTrending 的 adapter 配置下面加：
```elixir
config :singularity, Singularity.GitHub, adapter: {HTTP.Test, Singularity.GitHub}
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test/singularity/github_test.exs`
Expected：全部 PASS。

- [ ] **Step 6: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/test/fixtures/github_api/elixir.json \
  apps/singularity/lib/singularity/github.ex config/test.exs \
  apps/singularity/test/singularity/github_test.exs
git commit -m "feat: fetch repository details from the GitHub API"
```

---

### Task 6: Settings 上下文

**Files:**
- Create: `apps/singularity/lib/singularity/settings.ex`
- Test: `apps/singularity/test/singularity/settings_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule Singularity.SettingsTest do
  # Not async: these tests change the GITHUB_TOKEN environment variable.
  use Singularity.DataCase, async: false

  alias Singularity.Settings

  setup do
    previous = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      if previous,
        do: System.put_env("GITHUB_TOKEN", previous),
        else: System.delete_env("GITHUB_TOKEN")
    end)
  end

  test "without a stored or environment token there is none" do
    assert Settings.get_github_token() == nil
    assert Settings.github_token_status() == :unset
  end

  test "falls back to GITHUB_TOKEN" do
    System.put_env("GITHUB_TOKEN", "env-token-1234")
    assert Settings.get_github_token() == "env-token-1234"
    assert Settings.github_token_status() == {:env, "1234"}
  end

  test "a stored token wins over the environment and is reported by its last four characters" do
    System.put_env("GITHUB_TOKEN", "env-token-1234")
    assert {:ok, _setting} = Settings.put_github_token("  ghp_secretabcd ")
    assert Settings.get_github_token() == "ghp_secretabcd"
    assert Settings.github_token_status() == {:settings, "abcd"}
  end

  test "putting a token again replaces it; clearing removes it" do
    {:ok, _} = Settings.put_github_token("first-1111")
    {:ok, _} = Settings.put_github_token("second-2222")
    assert Settings.get_github_token() == "second-2222"

    assert :ok = Settings.clear_github_token()
    assert Settings.get_github_token() == nil
  end

  test "rejects a blank token" do
    assert {:error, changeset} = Settings.put_github_token("   ")
    assert %{value: ["can't be blank"]} = errors_on(changeset)
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/settings_test.exs`
Expected：FAIL，`Singularity.Settings.get_github_token/0 is undefined`。

- [ ] **Step 3: 实现**

```elixir
defmodule Singularity.Settings do
  @moduledoc "System configuration in the settings table. v2 has one key: the GitHub token."

  import Ecto.Query

  alias Singularity.Repo
  alias Singularity.Settings.Setting

  @github_token "github_token"

  @doc "The stored token, else the GITHUB_TOKEN environment variable, else nil."
  @spec get_github_token() :: String.t() | nil
  def get_github_token, do: stored_token() || env_token()

  @doc "Where the token comes from and its last four characters; never the full token."
  @spec github_token_status() :: :unset | {:env, String.t()} | {:settings, String.t()}
  def github_token_status do
    case {stored_token(), env_token()} do
      {token, _env} when is_binary(token) -> {:settings, last4(token)}
      {nil, token} when is_binary(token) -> {:env, last4(token)}
      {nil, nil} -> :unset
    end
  end

  @spec put_github_token(String.t()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put_github_token(token) when is_binary(token) do
    %Setting{}
    |> Setting.changeset(%{key: @github_token, value: String.trim(token)})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key,
      returning: true
    )
  end

  @spec clear_github_token() :: :ok
  def clear_github_token do
    Setting |> where(key: @github_token) |> Repo.delete_all()
    :ok
  end

  defp stored_token,
    do: Setting |> where(key: @github_token) |> select([s], s.value) |> Repo.one()

  defp env_token do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" -> token
      _unset -> nil
    end
  end

  defp last4(token), do: String.slice(token, -4, 4)
end
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test/singularity/settings_test.exs`
Expected：全部 PASS。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/lib/singularity/settings.ex \
  apps/singularity/test/singularity/settings_test.exs
git commit -m "feat: store the GitHub token in settings"
```

---

### Task 7: Knowledge：软件项目查询与手动 label

**Files:**
- Modify: `apps/singularity/lib/singularity/knowledge.ex`
- Modify: `apps/singularity/test/support/fixtures.ex`
- Test: `apps/singularity/test/singularity/knowledge_projects_test.exs`（新）

- [ ] **Step 1: 补充测试 fixture**

`apps/singularity/test/support/fixtures.ex`：把 alias 改为
```elixir
  alias Singularity.Collection.FetchRun
  alias Singularity.Knowledge.{Item, Label, Observation}
  alias Singularity.Repo
  alias Singularity.Sources.Source
```
并在模块末尾加入：
```elixir
  def project_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    title = Map.get(attrs, :title, "acme/project-#{System.unique_integer([:positive])}")

    defaults = %{
      kind: "software_project",
      external_id: "github.com/" <> String.downcase(title),
      title: title,
      url: "https://github.com/" <> title,
      attributes: %{},
      first_seen_at: now(),
      last_seen_at: now()
    }

    Item |> struct!(Map.merge(defaults, attrs)) |> Repo.insert!()
  end

  def label_fixture(%Item{} = item, name, origin \\ "auto"),
    do: Repo.insert!(%Label{item_id: item.id, name: name, origin: origin})

  def observation_fixture(%Item{} = item, source, attrs \\ %{}) do
    defaults = %{
      item_id: item.id,
      source_id: source && source.id,
      period: "2026-11-11",
      observed_at: now(),
      attributes: %{}
    }

    Observation |> struct!(Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end
```

- [ ] **Step 2: 写失败的测试**

`apps/singularity/test/singularity/knowledge_projects_test.exs`：
```elixir
defmodule Singularity.KnowledgeProjectsTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Knowledge

  defp days_ago(days), do: DateTime.add(now(), -days * 86_400, :second)
  defp ids(projects), do: Enum.map(projects, & &1.id)

  describe "list_projects/1" do
    setup do
      old =
        project_fixture(
          title: "acme/old-rocket",
          summary: "A rocket engine",
          attributes: %{"stars" => 900},
          first_seen_at: days_ago(10)
        )

      new =
        project_fixture(
          title: "zeta/new-tool",
          summary: "Tooling for 100% coverage",
          attributes: %{"stars" => 50},
          first_seen_at: days_ago(1)
        )

      unstarred = project_fixture(title: "solo/plain", first_seen_at: days_ago(5))

      label_fixture(old, "lang:rust")
      label_fixture(new, "topic:cli")
      label_fixture(new, "lang:rust", "manual")

      %{old: old, new: new, unstarred: unstarred}
    end

    test "orders by recently added and preloads labels by name", %{
      old: old,
      new: new,
      unstarred: unstarred
    } do
      projects = Knowledge.list_projects()
      assert ids(projects) == [new.id, unstarred.id, old.id]
      assert projects |> hd() |> Map.fetch!(:labels) |> Enum.map(& &1.name) == ["lang:rust", "topic:cli"]
    end

    test "sorts by stars with unknown counts last", %{old: old, new: new, unstarred: unstarred} do
      assert ids(Knowledge.list_projects(sort: :stars)) == [old.id, new.id, unstarred.id]
    end

    test "filters by label", %{old: old, new: new} do
      assert ids(Knowledge.list_projects(label: "lang:rust")) == [new.id, old.id]
      assert ids(Knowledge.list_projects(label: "topic:cli")) == [new.id]
    end

    test "searches owner/repo and description, treating % literally", %{old: old, new: new} do
      assert ids(Knowledge.list_projects(q: "ROCKET")) == [old.id]
      assert ids(Knowledge.list_projects(q: "zeta/")) == [new.id]
      assert ids(Knowledge.list_projects(q: "%")) == [new.id]
    end

    test "paginates" do
      assert length(Knowledge.list_projects(per_page: 2, page: 1)) == 2
      assert length(Knowledge.list_projects(per_page: 2, page: 2)) == 1
    end

    test "ignores items of other kinds" do
      project_fixture(kind: "fake_item")
      assert length(Knowledge.list_projects()) == 3
    end
  end

  test "count_projects/0, count_projects_since/1 and recent_projects/1" do
    project_fixture(first_seen_at: days_ago(10))
    recent = project_fixture(first_seen_at: days_ago(2))

    assert Knowledge.count_projects() == 2
    assert Knowledge.count_projects_since(days_ago(7)) == 1
    assert [%{id: id, labels: []}] = Knowledge.recent_projects(1)
    assert id == recent.id
  end

  test "get_project!/1 preloads labels; items of other kinds are not projects" do
    project = project_fixture()
    label_fixture(project, "archived")
    assert %{labels: [%{name: "archived"}]} = Knowledge.get_project!(project.id)

    other = project_fixture(kind: "fake_item")
    assert_raise Ecto.NoResultsError, fn -> Knowledge.get_project!(other.id) end
    assert Knowledge.get_project(other.id) == nil
  end

  test "top_labels/1 ranks labels by project count" do
    a = project_fixture()
    b = project_fixture()
    label_fixture(a, "lang:rust")
    label_fixture(b, "lang:rust")
    label_fixture(b, "topic:cli")

    assert Knowledge.top_labels(1) == [{"lang:rust", 2}]
    assert Knowledge.top_labels(5) == [{"lang:rust", 2}, {"topic:cli", 1}]
  end

  test "list_observations/1 returns history newest first, with nil sources for manual additions" do
    source = source_fixture()
    project = project_fixture()
    observation_fixture(project, source, period: "2026-11-09", observed_at: ~U[2026-11-09 08:00:00Z])
    observation_fixture(project, nil, period: "2026-11-10", observed_at: ~U[2026-11-10 08:00:00Z])

    assert [
             %{period: "2026-11-10", source: nil},
             %{period: "2026-11-09", source: %{name: "Fake source"}}
           ] = Knowledge.list_observations(project.id)
  end

  test "list_additions/1 lists projects newest first with the source that brought them" do
    source = source_fixture(name: "Trending")
    trending = project_fixture(first_seen_at: days_ago(2))
    manual = project_fixture(first_seen_at: days_ago(1))
    observation_fixture(trending, source, observed_at: days_ago(2))
    observation_fixture(manual, nil, observed_at: days_ago(1))

    assert [
             %{item: %{id: manual_id}, source: nil, at: %DateTime{}},
             %{item: %{id: trending_id}, source: %{name: "Trending"}}
           ] = Knowledge.list_additions(10)

    assert {manual_id, trending_id} == {manual.id, trending.id}
  end

  describe "manual labels" do
    test "add_label/2 normalizes, broadcasts and turns an automatic label into a manual one" do
      Knowledge.subscribe()
      project = project_fixture()
      project_id = project.id
      label_fixture(project, "lang:rust")

      assert {:ok, %{name: "my-pick", origin: "manual"}} = Knowledge.add_label(project, "  My-Pick ")
      assert_receive {:project_updated, ^project_id}
      assert {:ok, %{origin: "manual"}} = Knowledge.add_label(project, "lang:rust")

      assert project.id
             |> Knowledge.get_project!()
             |> Map.fetch!(:labels)
             |> Enum.map(&{&1.name, &1.origin}) == [{"lang:rust", "manual"}, {"my-pick", "manual"}]
    end

    test "add_label/2 rejects blank and overlong names" do
      project = project_fixture()
      assert {:error, changeset} = Knowledge.add_label(project, " ")
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert {:error, changeset} = Knowledge.add_label(project, String.duplicate("x", 101))
      assert %{name: [_too_long]} = errors_on(changeset)
    end

    test "remove_label/2 deletes manual labels only" do
      project = project_fixture()
      label_fixture(project, "lang:rust")
      label_fixture(project, "mine", "manual")

      assert :ok = Knowledge.remove_label(project, "MINE")
      assert {:error, :auto_label} = Knowledge.remove_label(project, "lang:rust")
      assert {:error, :not_found} = Knowledge.remove_label(project, "nope")
      assert [%{name: "lang:rust"}] = Knowledge.get_project!(project.id).labels
    end
  end
end
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge_projects_test.exs`
Expected：FAIL，`Singularity.Knowledge.list_projects/0 is undefined` 等。

- [ ] **Step 4: 实现**

`apps/singularity/lib/singularity/knowledge.ex`：把模块开头到 `@replace_on_conflict` 之前的部分改为：
```elixir
defmodule Singularity.Knowledge do
  @moduledoc "Knowledge items (v2: software projects), their labels and source records."

  import Ecto.Query

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge.{Item, Label, Observation}
  alias Singularity.Repo
  alias Singularity.Sources.Source

  @topic "knowledge"
  @project "software_project"
```
保留 `@replace_on_conflict`、`record/3` 及其私有函数和 v1 的查询函数不动，在模块末尾（最后一个 `end` 之前）加入：
```elixir
  @doc "Subscribes the caller to `{:project_updated, item_id}` messages."
  def subscribe, do: Phoenix.PubSub.subscribe(Singularity.PubSub, @topic)

  defp broadcast_project(item_id),
    do: Phoenix.PubSub.broadcast(Singularity.PubSub, @topic, {:project_updated, item_id})

  @doc """
  Software projects with labels preloaded. Options: `:label`, `:q` (ILIKE on
  owner/repo and description), `:sort` (`:recent` or `:stars`), `:page`
  (default 1) and `:per_page` (default 30).
  """
  @spec list_projects(keyword()) :: [Item.t()]
  def list_projects(opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, 30)

    projects_query()
    |> filter_label(opts[:label])
    |> search(opts[:q])
    |> sort_projects(Keyword.get(opts, :sort, :recent))
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> preload(labels: ^labels_query())
    |> Repo.all()
  end

  defp projects_query, do: where(Item, [i], i.kind == ^@project)
  defp labels_query, do: order_by(Label, asc: :name)

  defp filter_label(query, label) when label in [nil, ""], do: query

  defp filter_label(query, label) do
    tagged = from(l in Label, where: l.name == ^label, select: l.item_id)
    where(query, [i], i.id in subquery(tagged))
  end

  defp search(query, q) when q in [nil, ""], do: query

  defp search(query, q) do
    pattern = "%" <> escape_like(String.trim(q)) <> "%"
    where(query, [i], ilike(i.title, ^pattern) or ilike(i.summary, ^pattern))
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")

  defp sort_projects(query, :stars) do
    order_by(query, [i],
      desc_nulls_last: fragment("(?->>'stars')::bigint", i.attributes),
      desc: i.id
    )
  end

  defp sort_projects(query, _recent), do: order_by(query, [i], desc: i.first_seen_at, desc: i.id)

  @spec count_projects() :: non_neg_integer()
  def count_projects, do: Repo.aggregate(projects_query(), :count)

  @doc "Projects added at or after `since` (the Overview's \"added this week\")."
  @spec count_projects_since(DateTime.t()) :: non_neg_integer()
  def count_projects_since(%DateTime{} = since),
    do: projects_query() |> where([i], i.first_seen_at >= ^since) |> Repo.aggregate(:count)

  @spec recent_projects(pos_integer()) :: [Item.t()]
  def recent_projects(limit) do
    projects_query()
    |> order_by([i], desc: i.first_seen_at, desc: i.id)
    |> limit(^limit)
    |> preload(labels: ^labels_query())
    |> Repo.all()
  end

  def get_project!(id), do: projects_query() |> preload(labels: ^labels_query()) |> Repo.get!(id)
  def get_project(id), do: Repo.get(projects_query(), id)

  @doc "`{name, project_count}` for the most used labels."
  @spec top_labels(pos_integer()) :: [{String.t(), pos_integer()}]
  def top_labels(limit) do
    Label
    |> join(:inner, [l], i in Item, on: i.id == l.item_id and i.kind == ^@project)
    |> group_by([l], l.name)
    |> order_by([l], desc: count(l.id), asc: l.name)
    |> limit(^limit)
    |> select([l], {l.name, count(l.id)})
    |> Repo.all()
  end

  @doc "Project additions, newest first, with the source of the first record (nil = manual)."
  @spec list_additions(pos_integer()) :: [
          %{at: DateTime.t(), item: Item.t(), source: Source.t() | nil}
        ]
  def list_additions(limit) do
    first_records =
      Observation
      |> distinct([o], o.item_id)
      |> order_by([o], asc: o.item_id, asc: o.observed_at, asc: o.id)
      |> select([o], %{item_id: o.item_id, source_id: o.source_id})

    projects_query()
    |> join(:left, [i], f in subquery(first_records), on: f.item_id == i.id)
    |> join(:left, [i, f], s in Source, on: s.id == f.source_id)
    |> order_by([i], desc: i.first_seen_at, desc: i.id)
    |> limit(^limit)
    |> select([i, f, s], %{at: i.first_seen_at, item: i, source: s})
    |> Repo.all()
  end

  @doc "Adds a manual label; an automatic label with the same name becomes manual."
  @spec add_label(Item.t(), String.t()) :: {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def add_label(%Item{} = item, name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Label{}
    |> Label.changeset(%{item_id: item.id, name: name, origin: "manual"})
    |> Repo.insert(
      on_conflict: [set: [origin: "manual", updated_at: now]],
      conflict_target: [:item_id, :name],
      returning: true
    )
    |> case do
      {:ok, label} ->
        broadcast_project(item.id)
        {:ok, label}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Removes a manual label. Automatic labels belong to the system."
  @spec remove_label(Item.t(), String.t()) :: :ok | {:error, :auto_label | :not_found}
  def remove_label(%Item{} = item, name) do
    case Repo.get_by(Label, item_id: item.id, name: Label.normalize_name(name)) do
      nil ->
        {:error, :not_found}

      %Label{origin: "auto"} ->
        {:error, :auto_label}

      %Label{} = label ->
        Repo.delete!(label)
        broadcast_project(item.id)
        :ok
    end
  end
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test`
Expected：全部 PASS。

- [ ] **Step 6: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/lib/singularity/knowledge.ex \
  apps/singularity/test/support/fixtures.ex \
  apps/singularity/test/singularity/knowledge_projects_test.exs
git commit -m "feat: query software projects and manage manual labels"
```

---
### Task 8: FetchDetailsWorker 与手动添加

**Files:**
- Create: `apps/singularity/lib/singularity/knowledge/fetch_details_worker.ex`
- Modify: `apps/singularity/lib/singularity/knowledge.ex`、`config/config.exs`
- Test: `apps/singularity/test/singularity/knowledge/fetch_details_worker_test.exs`、`apps/singularity/test/singularity/knowledge_add_project_test.exs`

- [ ] **Step 1: 写失败的测试**

`apps/singularity/test/singularity/knowledge/fetch_details_worker_test.exs`：
```elixir
defmodule Singularity.Knowledge.FetchDetailsWorkerTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.{GitHub, Knowledge, Settings}
  alias Singularity.Knowledge.FetchDetailsWorker

  @fixture Path.join([__DIR__, "../../fixtures/github_api/elixir.json"])

  setup do
    HTTP.Test.verify_on_exit!()

    project =
      project_fixture(
        title: "elixir-lang/Elixir",
        external_id: "github.com/elixir-lang/elixir",
        details_error: "old failure"
      )

    observation_fixture(project, source_fixture(), attributes: %{"since" => "weekly"})
    label_fixture(project, "topic:stale")
    label_fixture(project, "lang:elixir", "manual")
    %{project: project}
  end

  test "stores details, clears the error and recomputes automatic labels", %{project: project} do
    Knowledge.subscribe()
    project_id = project.id
    # Fixed topics keep the expected labels independent of the captured repository.
    body = @fixture |> File.read!() |> JSON.decode!() |> Map.put("topics", ["functional"])

    HTTP.Test.expect(GitHub, fn request ->
      assert request.url.path == "/repos/elixir-lang/elixir"
      HTTP.Test.response(200, JSON.encode!(body), [{"content-type", "application/json"}])
    end)

    assert :ok = perform_job(FetchDetailsWorker, %{item_id: project.id})

    project = Knowledge.get_project!(project.id)
    assert project.title == "elixir-lang/elixir"
    assert project.attributes["language"] == "Elixir"
    assert %DateTime{} = project.details_fetched_at
    assert project.details_error == nil

    assert Enum.map(project.labels, &{&1.name, &1.origin}) == [
             {"lang:elixir", "manual"},
             {"topic:functional", "auto"},
             {"trending:weekly", "auto"}
           ]

    assert_receive {:project_updated, ^project_id}
  end

  test "snoozes until the rate limit resets", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request ->
      HTTP.Test.status(429) |> HTTP.Test.headers([{"retry-after", "90"}])
    end)

    assert {:snooze, 90} = perform_job(FetchDetailsWorker, %{item_id: project.id})
    assert Knowledge.get_project!(project.id).details_error == "old failure"
  end

  test "records a missing repository without retrying", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(404) end)

    assert :ok = perform_job(FetchDetailsWorker, %{item_id: project.id})
    assert Knowledge.get_project!(project.id).details_error == "repository not found"
  end

  test "records other failures and returns an error so Styx retries", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.transport_error(:timeout) end)

    assert {:error, {:transport, "timeout"}} =
             perform_job(FetchDetailsWorker, %{item_id: project.id})

    assert Knowledge.get_project!(project.id).details_error == "transport error: timeout"
  end

  test "sends the stored GitHub token", %{project: project} do
    {:ok, _setting} = Settings.put_github_token("ghp_stored")

    HTTP.Test.expect(GitHub, fn request ->
      assert HTTP.Headers.get(request.headers, "authorization") == "Bearer ghp_stored"
      HTTP.Test.status(404)
    end)

    assert :ok = perform_job(FetchDetailsWorker, %{item_id: project.id})
  end

  test "cancels when the project no longer exists" do
    assert {:cancel, :project_not_found} = perform_job(FetchDetailsWorker, %{item_id: -1})
  end
end
```

`apps/singularity/test/singularity/knowledge_add_project_test.exs`：
```elixir
defmodule Singularity.KnowledgeAddProjectTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Knowledge
  alias Singularity.Knowledge.{FetchDetailsWorker, Item, Observation}

  @now ~U[2026-11-11 08:00:00Z]

  test "creates a project, records a manual addition and queues a details fetch" do
    Knowledge.subscribe()

    assert {:ok, %Item{} = item} =
             Knowledge.add_project("https://github.com/Elixir-Lang/Elixir.git", @now)

    assert item.kind == "software_project"
    assert item.external_id == "github.com/elixir-lang/elixir"
    assert item.title == "Elixir-Lang/Elixir"
    assert item.url == "https://github.com/Elixir-Lang/Elixir"
    assert item.first_seen_at == @now

    assert [
             %Observation{
               source_id: nil,
               period: "2026-11-11",
               attributes: %{"via" => "manual"}
             }
           ] = Repo.all(Observation)

    assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: item.id}, queue: :details)
    item_id = item.id
    assert_receive {:project_updated, ^item_id}
  end

  test "adding a known project returns it without a second fetch" do
    {:ok, item} = Knowledge.add_project("elixir-lang/elixir", @now)
    next_day = DateTime.add(@now, 86_400, :second)

    assert {:existing, %Item{id: id}} =
             Knowledge.add_project("git@github.com:elixir-lang/elixir.git", next_day)

    assert id == item.id
    assert {:existing, _item} = Knowledge.add_project("elixir-lang/elixir", next_day)
    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 2
    assert length(all_enqueued(worker: FetchDetailsWorker)) == 1
  end

  test "rejects unsupported addresses" do
    assert {:error, :unsupported_address} = Knowledge.add_project("https://gitlab.com/a/b")
    assert Repo.aggregate(Item, :count) == 0
  end

  test "enqueue_details/1 keeps one incomplete fetch per project" do
    project = project_fixture()
    assert {:ok, _job} = Knowledge.enqueue_details(project.id)
    assert {:ok, _job} = Knowledge.enqueue_details(project.id)
    assert length(all_enqueued(worker: FetchDetailsWorker)) == 1
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge/fetch_details_worker_test.exs apps/singularity/test/singularity/knowledge_add_project_test.exs`
Expected：FAIL，`Singularity.Knowledge.FetchDetailsWorker` 未定义、`Knowledge.add_project/2 is undefined`。

- [ ] **Step 3: 实现**

`config/config.exs` 中 Styx 的 `queues` 改为：
```elixir
  queues: [default: 5, collect: 1, details: 1],
```

`apps/singularity/lib/singularity/knowledge/fetch_details_worker.ex`：
```elixir
defmodule Singularity.Knowledge.FetchDetailsWorker do
  @moduledoc """
  Fetches a software project's GitHub details and recomputes its automatic
  labels. Rate limits snooze the job; a missing repository is recorded and not
  retried; other failures are recorded and retried by Styx.
  """

  use Styx.Worker,
    queue: :details,
    max_attempts: 5,
    unique: [keys: [:item_id], states: :incomplete, period: :infinity]

  alias Singularity.{GitHub, Knowledge, Settings}

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"item_id" => item_id}}) do
    case Knowledge.get_project(item_id) do
      nil -> {:cancel, :project_not_found}
      project -> fetch(project)
    end
  end

  defp fetch(project) do
    ["github.com", owner, repo] = String.split(project.external_id, "/")

    case GitHub.fetch_repo(owner, repo, token: Settings.get_github_token()) do
      {:ok, details} ->
        {:ok, _project} = Knowledge.put_details(project, details, DateTime.utc_now())
        :ok

      {:error, {:rate_limited, seconds}} ->
        {:snooze, seconds}

      {:error, :not_found} ->
        {:ok, _project} = Knowledge.put_details_error(project, "repository not found")
        :ok

      {:error, reason} ->
        {:ok, _project} = Knowledge.put_details_error(project, describe(reason))
        {:error, reason}
    end
  end

  defp describe({:http_status, status}), do: "GitHub returned HTTP #{status}"
  defp describe({:transport, message}), do: "transport error: " <> message
  defp describe(:invalid_response), do: "GitHub returned an unreadable response"
end
```

`apps/singularity/lib/singularity/knowledge.ex`：
- alias 行改为：
```elixir
  alias Singularity.Knowledge.{Address, FetchDetailsWorker, Item, Label, Labels, Observation}
```
- 在模块末尾（最后一个 `end` 之前）加入：
```elixir
  @doc """
  Adds a software project from a GitHub address. A new project gets a manual
  source record and a queued details fetch. A known project is returned as
  `{:existing, item}`; its manual source record is still written (once per day).
  """
  @spec add_project(String.t(), DateTime.t()) ::
          {:ok, Item.t()}
          | {:existing, Item.t()}
          | {:error, :unsupported_address | Ecto.Changeset.t()}
  def add_project(address, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with {:ok, normalized} <- Address.normalize(address),
         {:ok, outcome} <- Repo.transaction(fn -> find_or_create_project(normalized, now) end) do
      case outcome do
        {:created, item} ->
          broadcast_project(item.id)
          {:ok, item}

        {:existing, item} ->
          {:existing, item}
      end
    end
  end

  defp find_or_create_project(%{external_id: external_id} = address, now) do
    case Repo.get_by(Item, kind: @project, external_id: external_id) do
      %Item{} = item ->
        insert_manual_observation!(item, now)
        {:existing, item}

      nil ->
        case insert_project(address, now) do
          {:ok, item} ->
            insert_manual_observation!(item, now)
            {:ok, _job} = enqueue_details(item.id)
            {:created, item}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp insert_project(%{external_id: external_id, owner: owner, repo: repo, url: url}, now) do
    %Item{}
    |> Item.changeset(%{
      kind: @project,
      external_id: external_id,
      title: owner <> "/" <> repo,
      url: url,
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert()
  end

  defp insert_manual_observation!(%Item{} = item, now) do
    %Observation{}
    |> Observation.changeset(%{
      item_id: item.id,
      period: now |> DateTime.to_date() |> Date.to_iso8601(),
      observed_at: now,
      attributes: %{"via" => "manual"}
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:source_id, :item_id, :period])
  end

  @doc "Queues a GitHub details fetch; at most one is incomplete per project."
  @spec enqueue_details(integer()) :: {:ok, Styx.Job.t()} | {:error, term()}
  def enqueue_details(item_id) when is_integer(item_id),
    do: %{item_id: item_id} |> FetchDetailsWorker.new() |> Styx.insert()

  @doc "Stores fetched GitHub details, clears the last error and recomputes automatic labels."
  @spec put_details(Item.t(), Singularity.GitHub.details(), DateTime.t()) :: {:ok, Item.t()}
  def put_details(%Item{} = item, %{attributes: attributes} = details, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    {:ok, item} =
      Repo.transaction(fn ->
        item =
          item
          |> Ecto.Changeset.change(
            title: details.title || item.title,
            summary: details.summary,
            attributes: attributes,
            details_fetched_at: now,
            details_error: nil
          )
          |> Repo.update!()

        names = Labels.auto_labels(attributes, observation_sinces(item.id))
        sync_auto_labels!(item.id, names, now)
        item
      end)

    broadcast_project(item.id)
    {:ok, item}
  end

  @doc "Records why the last details fetch failed."
  @spec put_details_error(Item.t(), String.t()) :: {:ok, Item.t()}
  def put_details_error(%Item{} = item, message) when is_binary(message) do
    item = item |> Ecto.Changeset.change(details_error: message) |> Repo.update!()
    broadcast_project(item.id)
    {:ok, item}
  end

  defp observation_sinces(item_id) do
    Observation
    |> where([o], o.item_id == ^item_id)
    |> select([o], fragment("?->>'since'", o.attributes))
    |> distinct(true)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
  end

  # Only automatic rows are added or removed; a manual label with the same name is kept.
  defp sync_auto_labels!(item_id, names, now) do
    existing = Label |> where(item_id: ^item_id) |> Repo.all()

    stale_ids =
      for %Label{origin: "auto", name: name, id: id} <- existing, name not in names, do: id

    Label |> where([l], l.id in ^stale_ids) |> Repo.delete_all()

    taken = MapSet.new(existing, & &1.name)
    rows = for name <- names, not MapSet.member?(taken, name), do: auto_label_row(item_id, name, now)
    Repo.insert_all(Label, rows, on_conflict: :nothing, conflict_target: [:item_id, :name])
    :ok
  end

  defp auto_label_row(item_id, name, now),
    do: %{item_id: item_id, name: name, origin: "auto", inserted_at: now, updated_at: now}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test`
Expected：全部 PASS。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add config/config.exs \
  apps/singularity/lib/singularity/knowledge/fetch_details_worker.ex \
  apps/singularity/lib/singularity/knowledge.ex \
  apps/singularity/test/singularity/knowledge/fetch_details_worker_test.exs \
  apps/singularity/test/singularity/knowledge_add_project_test.exs
git commit -m "feat: add projects manually and fetch their GitHub details"
```

---

### Task 9: 采集写入改为软件项目

**Files:**
- Modify: `apps/singularity/lib/singularity/knowledge.ex`（`record/3`）
- Modify: `apps/singularity/lib/singularity/collectors/github_trending.ex`
- Test: `apps/singularity/test/singularity/knowledge_record_test.exs`、`apps/singularity/test/singularity/collectors/github_trending_test.exs`

- [ ] **Step 1: 写失败的测试**

`apps/singularity/test/singularity/knowledge_record_test.exs`：
- 在 `use Singularity.DataCase, async: true` 下面加 `use Styx.Testing, repo: Singularity.Repo`。
- alias 改为：
```elixir
  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge
  alias Singularity.Knowledge.{Address, FetchDetailsWorker, Item, Label, Observation}
  alias Singularity.Repo
  alias Singularity.Test.FakeCollector
```
- 在模块末尾加入：
```elixir
  defp trending(owner_repo, rank, since) do
    {:ok, address} = Address.normalize(owner_repo)

    %Entry{
      item_kind: "software_project",
      external_id: address.external_id,
      title: owner_repo,
      url: address.url,
      summary: "From the trending page",
      rank: rank,
      item_attributes: %{"language" => "Rust", "stars" => 10},
      observation_attributes: %{"since" => since, "stars_in_period" => 3}
    }
  end

  test "a trending project gets a trending label and a queued details fetch" do
    {:ok, 1} =
      Knowledge.record(
        source_fixture(),
        %Result{period: "2026-11-09", entries: [trending("acme/rocket", 1, "weekly")]},
        @t1
      )

    item = Repo.one!(Item)
    assert item.kind == "software_project"
    assert item.summary == "From the trending page"
    assert [%Label{name: "trending:weekly", origin: "auto"}] = Repo.all(Label)
    assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: item.id})
  end

  test "recording a known project keeps its GitHub details and skips fresh details" do
    project =
      project_fixture(
        title: "Acme/Rocket",
        external_id: "github.com/acme/rocket",
        summary: "From GitHub",
        attributes: %{"stars" => 999},
        details_fetched_at: @t2
      )

    {:ok, 1} =
      Knowledge.record(
        source_fixture(),
        %Result{period: "2026-11-10", entries: [trending("acme/rocket", 2, "daily")]},
        DateTime.add(@t2, 3600, :second)
      )

    item = Repo.get!(Item, project.id)
    assert {item.title, item.summary, item.attributes} == {"Acme/Rocket", "From GitHub", %{"stars" => 999}}
    assert item.last_seen_at == DateTime.add(@t2, 3600, :second)
    refute_enqueued(worker: FetchDetailsWorker)
  end

  test "details older than a day are fetched again" do
    project = project_fixture(external_id: "github.com/acme/rocket", details_fetched_at: @t1)

    {:ok, 1} =
      Knowledge.record(
        source_fixture(),
        %Result{period: "2026-11-10", entries: [trending("acme/rocket", 1, "daily")]},
        DateTime.add(@t1, 25 * 3600, :second)
      )

    assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: project.id})
  end

  test "items of other kinds get neither labels nor details fetches" do
    {:ok, _} = Knowledge.record(source_fixture(), result("2026-11-09", ["a"]), @t1)
    assert Repo.aggregate(Label, :count) == 0
    refute_enqueued(worker: FetchDetailsWorker)
  end
```

`apps/singularity/test/singularity/collectors/github_trending_test.exs`：
- 在 `"extracts entries, ranks by page position and counts broken rows"` 中，把
```elixir
      assert rocket.external_id == "acme/rocket"
```
改为
```elixir
      assert rocket.external_id == "github.com/acme/rocket"
```
把
```elixir
      assert rocket.item_kind == "github_repo"
```
改为
```elixir
      assert rocket.item_kind == "software_project"
```
- 在 `"parses a captured real trending page"` 中，把
```elixir
        assert entry.external_id =~ ~r{^[^/\s]+/[^/\s]+$}
```
改为
```elixir
        assert entry.external_id =~ ~r{^github\.com/[a-z0-9-]+/[a-z0-9._-]+$}
        assert entry.item_kind == "software_project"
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/knowledge_record_test.exs apps/singularity/test/singularity/collectors/github_trending_test.exs`
Expected：FAIL：没有 `trending:weekly` label、没有入队的 FetchDetailsWorker、已知项目的 title/summary/attributes 被覆盖；trending 测试中 `external_id` 仍是 `"acme/rocket"`。

- [ ] **Step 3: 实现**

`apps/singularity/lib/singularity/knowledge.ex`：
- 把 `@replace_on_conflict [...]`（多行）替换为：
```elixir
  # title, summary and attributes come from GitHub details; collected values only seed new items.
  @replace_on_conflict [:last_seen_at, :updated_at]
  @details_ttl_seconds 24 * 60 * 60
```
- 把 `record/3` 替换为：
```elixir
  @doc """
  Upserts items and inserts one observation per entry for the result's period,
  atomically. Trending entries add a `trending:<since>` label; software projects
  without fresh details get a details fetch queued in the same transaction.
  """
  @spec record(Source.t(), Result.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record(%Source{} = source, %Result{} = result, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      Enum.each(result.entries, fn entry ->
        item = upsert_item!(entry, now)
        insert_observation!(item, source, result.period, entry, now)
        add_trending_label!(item, entry, now)
        maybe_enqueue_details!(item, now)
      end)

      length(result.entries)
    end)
  end

  defp add_trending_label!(%Item{} = item, %Entry{observation_attributes: %{"since" => since}}, now)
       when is_binary(since) and since != "" do
    Repo.insert_all(Label, [auto_label_row(item.id, "trending:" <> since, now)],
      on_conflict: :nothing,
      conflict_target: [:item_id, :name]
    )

    :ok
  end

  defp add_trending_label!(_item, _entry, _now), do: :ok

  defp maybe_enqueue_details!(%Item{kind: @project} = item, now) do
    if details_stale?(item, now) do
      {:ok, _job} = enqueue_details(item.id)
    end

    :ok
  end

  defp maybe_enqueue_details!(_item, _now), do: :ok

  defp details_stale?(%Item{details_fetched_at: nil}, _now), do: true

  defp details_stale?(%Item{details_fetched_at: fetched_at}, now),
    do: DateTime.diff(now, fetched_at) >= @details_ttl_seconds
```

`apps/singularity/lib/singularity/collectors/github_trending.ex`：
- alias 改为：
```elixir
  alias Singularity.Collector.{Entry, Result}
  alias Singularity.HttpClient
  alias Singularity.Knowledge.Address
```
- 把 `parse_row/3` 的 `with` 头部和 `%Entry{}` 的前几个字段改为：
```elixir
  defp parse_row(row, rank, since) do
    with [href | _] <- Floki.attribute(row, "h2 a", "href"),
         "/" <> path <- String.trim(href),
         [owner, repo] <- String.split(path, "/", trim: true),
         {:ok, address} <- Address.normalize(owner <> "/" <> repo) do
      full_name = owner <> "/" <> repo
      summary = row |> Floki.find("p") |> Floki.text() |> squish()

      language =
        row |> Floki.find(~s([itemprop="programmingLanguage"])) |> Floki.text() |> squish()

      stars = link_count(row, "/stargazers")
      forks = link_count(row, "/forks")
      stars_in_period = row |> Floki.text() |> stars_in_period()

      {:ok,
       %Entry{
         item_kind: "software_project",
         external_id: address.external_id,
         title: full_name,
         url: address.url,
         summary: summary,
         rank: rank,
```
`item_attributes`、`observation_attributes`、`raw` 以及 `else` 分支保持不变。

- [ ] **Step 4: 运行测试，确认通过**

Run: `devenv shell -- mix test`
Expected：全部 PASS（`item_live_test.exs` 自己构造 `github_repo` 条目，仍然通过）。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/lib/singularity/knowledge.ex \
  apps/singularity/lib/singularity/collectors/github_trending.ex \
  apps/singularity/test/singularity/knowledge_record_test.exs \
  apps/singularity/test/singularity/collectors/github_trending_test.exs
git commit -m "feat: record trending repositories as software projects"
```

---

### Task 10: System.status/0 与跨来源的采集记录

**Files:**
- Create: `apps/singularity/lib/singularity/system.ex`
- Modify: `apps/singularity/lib/singularity/collection.ex`
- Test: `apps/singularity/test/singularity/system_test.exs`（新）、`apps/singularity/test/singularity/collection_test.exs`

- [ ] **Step 1: 写失败的测试**

`apps/singularity/test/singularity/system_test.exs`：
```elixir
defmodule Singularity.SystemTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Knowledge

  test "status/0 reports the version and job counts for every configured queue" do
    project = project_fixture()
    {:ok, _job} = Knowledge.enqueue_details(project.id)

    # Fully qualified on purpose: aliasing Singularity.System would shadow Elixir's System.
    status = Singularity.System.status()

    assert status.version == to_string(Application.spec(:singularity, :vsn))
    assert Enum.map(status.queues, & &1.name) == ["collect", "default", "details"]

    assert %{available: 1, executing: 0, retryable: 0} =
             Enum.find(status.queues, &(&1.name == "details"))
  end
end
```

`apps/singularity/test/singularity/collection_test.exs` 末尾加入：
```elixir
  test "list_recent_runs/1 spans sources, newest first, with sources loaded" do
    a = source_fixture(name: "A")
    b = source_fixture(name: "B")
    fetch_run_fixture(a, started_at: ~U[2026-11-09 07:00:00Z])
    fetch_run_fixture(b, started_at: ~U[2026-11-09 08:00:00Z])

    assert [%FetchRun{source: %{name: "B"}}, %FetchRun{source: %{name: "A"}}] =
             Collection.list_recent_runs(10)

    assert [_newest] = Collection.list_recent_runs(1)
  end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity/test/singularity/system_test.exs apps/singularity/test/singularity/collection_test.exs`
Expected：FAIL，`Singularity.System.status/0` 和 `Collection.list_recent_runs/1` 未定义。

- [ ] **Step 3: 实现**

`apps/singularity/lib/singularity/system.ex`：
```elixir
defmodule Singularity.System do
  @moduledoc """
  Read-only system status. Refer to it as `Singularity.System`: an alias would
  shadow Elixir's `System`.
  """

  import Ecto.Query

  alias Singularity.Repo

  @states ~w(available executing retryable)

  @type queue_status :: %{
          name: String.t(),
          available: non_neg_integer(),
          executing: non_neg_integer(),
          retryable: non_neg_integer()
        }

  @spec status() :: %{version: String.t(), queues: [queue_status()]}
  def status do
    counts =
      Styx.Job
      |> where([j], j.state in ^@states)
      |> group_by([j], [j.queue, j.state])
      |> select([j], {{j.queue, j.state}, count(j.id)})
      |> Repo.all()
      |> Map.new()

    configured =
      :singularity
      |> Application.fetch_env!(Styx)
      |> Keyword.fetch!(:queues)
      |> Enum.map(fn {name, _limit} -> Atom.to_string(name) end)

    names =
      (configured ++ Enum.map(Map.keys(counts), fn {queue, _state} -> queue end))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      version: :singularity |> Application.spec(:vsn) |> to_string(),
      queues:
        Enum.map(names, fn name ->
          %{
            name: name,
            available: Map.get(counts, {name, "available"}, 0),
            executing: Map.get(counts, {name, "executing"}, 0),
            retryable: Map.get(counts, {name, "retryable"}, 0)
          }
        end)
    }
  end
end
```

`apps/singularity/lib/singularity/collection.ex`，在 `latest_runs/0` 后面加入：
```elixir
  @doc "The most recent runs across all sources, newest first, with sources preloaded."
  def list_recent_runs(limit \\ 50) do
    FetchRun
    |> order_by(desc: :started_at, desc: :id)
    |> limit(^limit)
    |> preload(:source)
    |> Repo.all()
  end
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity/test`
Expected：全部 PASS。

- [ ] **Step 5: 提交**

```bash
devenv shell -- mix format
git add apps/singularity/lib/singularity/system.ex apps/singularity/lib/singularity/collection.ex \
  apps/singularity/test/singularity/system_test.exs \
  apps/singularity/test/singularity/collection_test.exs
git commit -m "feat: report system status and recent runs across sources"
```

---
### Task 11: 接入 gettext

**Files:**
- Modify: `apps/singularity_web/mix.exs`、`mix.lock`、`config/config.exs`
- Create: `apps/singularity_web/lib/singularity_web/gettext.ex`、`apps/singularity_web/lib/singularity_web/form_helpers.ex`
- Modify: `apps/singularity_web/lib/singularity_web.ex`、`apps/singularity_web/lib/singularity_web/live/source_live/form.ex`
- Create: `apps/singularity_web/priv/gettext/errors.pot`、`apps/singularity_web/priv/gettext/en/LC_MESSAGES/errors.po`（由 `mix gettext.merge` 生成）
- Test: `apps/singularity_web/test/singularity_web/form_helpers_test.exs`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule SingularityWeb.FormHelpersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import SingularityWeb.FormHelpers

  test "the default locale is English" do
    assert Gettext.get_locale(SingularityWeb.Gettext) == "en"
  end

  test "translate_error/1 goes through the errors domain with interpolation and plurals" do
    assert translate_error({"can't be blank", [validation: :required]}) == "can't be blank"

    assert translate_error(
             {"should be at most %{count} character(s)",
              [count: 100, validation: :length, kind: :max, type: :string]}
           ) == "should be at most 100 character(s)"
  end

  test "field_errors/1 shows a field's errors only after validation" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required(:name)

    fresh = Phoenix.Component.to_form(changeset, as: :thing)
    refute render_component(&field_errors/1, form: fresh, field: :name) =~ "blank"

    validated = Phoenix.Component.to_form(%{changeset | action: :validate}, as: :thing)
    assert render_component(&field_errors/1, form: validated, field: :name) =~ "can&#39;t be blank"
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity_web/test/singularity_web/form_helpers_test.exs`
Expected：FAIL，`SingularityWeb.FormHelpers` 未定义（`module SingularityWeb.FormHelpers is not loaded`）。

- [ ] **Step 3: 加依赖**

`apps/singularity_web/mix.exs` 的 `deps/0` 中，在 `{:jason, "~> 1.2"},` 前面加：
```elixir
      {:gettext, "~> 1.0"},
```

Run: `devenv shell -- mix deps.get`（超时就重试）
Expected：`mix.lock` 中出现 `"gettext"` 和 `"expo"`。

- [ ] **Step 4: 实现**

`apps/singularity_web/lib/singularity_web/gettext.ex`：
```elixir
defmodule SingularityWeb.Gettext do
  @moduledoc """
  Gettext backend for the web UI. Messages live in `priv/gettext`, one domain
  per area (default, errors, overview, knowledge, source, system); msgids are
  English and English is the default locale. Adding a language only needs a new
  `.po` directory.
  """
  use Gettext.Backend, otp_app: :singularity_web
end
```

`apps/singularity_web/lib/singularity_web/form_helpers.ex`：
```elixir
defmodule SingularityWeb.FormHelpers do
  @moduledoc "Form error rendering shared by all pages; messages go through the errors domain."
  use Phoenix.Component

  @doc "Translates one changeset error through the `errors` gettext domain."
  def translate_error({message, opts}) do
    case opts[:count] do
      nil -> Gettext.dgettext(SingularityWeb.Gettext, "errors", message, opts)
      count -> Gettext.dngettext(SingularityWeb.Gettext, "errors", message, message, count, opts)
    end
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :field, :atom, required: true

  @doc "Renders a field's errors once its changeset has been validated or submitted."
  def field_errors(assigns) do
    assigns = assign(assigns, :messages, messages(assigns.form.source, assigns.field))

    ~H"""
    <p :for={message <- @messages} class="text-sm text-error" data-role="error">{message}</p>
    """
  end

  defp messages(%Ecto.Changeset{action: action, errors: errors}, field) when not is_nil(action),
    do: for({^field, error} <- errors, do: translate_error(error))

  defp messages(_source, _field), do: []
end
```

`apps/singularity_web/lib/singularity_web.ex` 的 `html_helpers/0` 改为：
```elixir
  defp html_helpers do
    quote do
      # Translations: gettext/dgettext/dngettext against SingularityWeb.Gettext
      use Gettext, backend: SingularityWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # DuskMoon UI components
      use PhoenixDuskmoon.Component
      # Form errors through the errors domain
      import SingularityWeb.FormHelpers

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias SingularityWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end
```

`apps/singularity_web/lib/singularity_web/live/source_live/form.ex`：删除私有的 `field_errors/1` 组件（从 `attr :form, :any, required: true` 到它的 `end`，包括两个 `attr` 行），模板中的 `<.field_errors form={@form} field={...} />` 调用不变，改由导入的 `SingularityWeb.FormHelpers.field_errors/1` 渲染。

`config/config.exs` 中，在 `config :singularity_web, SingularityWeb.Endpoint, ...` 之前加入：
```elixir
config :singularity_web, SingularityWeb.Gettext, default_locale: "en"
```

`apps/singularity_web/priv/gettext/errors.pot`（手写；没有 `elixir-autogen` 标记，`mix gettext.extract` 会保留）：
```
## Messages from Ecto validations and domain changesets. They are not
## extracted automatically; keep this list in sync by hand.
msgid ""
msgstr ""

msgid "can't be blank"
msgstr ""

msgid "has already been taken"
msgstr ""

msgid "is invalid"
msgstr ""

msgid "is not a registered source type"
msgstr ""

msgid "must be greater than or equal to %{number}"
msgstr ""

msgid "should be at most %{count} character(s)"
msgid_plural "should be at most %{count} character(s)"
msgstr[0] ""
msgstr[1] ""
```

生成英文 `.po`：
```bash
devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.merge priv/gettext --locale en'
ls apps/singularity_web/priv/gettext/en/LC_MESSAGES
```
Expected：生成 `errors.po`。

- [ ] **Step 5: 运行测试，确认通过**

Run: `devenv shell -- mix test apps/singularity_web/test`
Expected：全部 PASS（来源表单的校验错误改由 `FormHelpers` 渲染，原有测试不变）。

- [ ] **Step 6: 提交**

```bash
devenv shell -- mix format
git add apps/singularity_web/mix.exs mix.lock config/config.exs \
  apps/singularity_web/lib/singularity_web/gettext.ex \
  apps/singularity_web/lib/singularity_web/form_helpers.ex \
  apps/singularity_web/lib/singularity_web.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/form.ex \
  apps/singularity_web/priv/gettext/errors.pot \
  apps/singularity_web/priv/gettext/en/LC_MESSAGES/errors.po \
  apps/singularity_web/test/singularity_web/form_helpers_test.exs
git commit -m "feat(web): add gettext with an English default locale"
```

---

### Task 12: 新布局与 Knowledge 页面

替换 v1 的条目详情页（`/items/:id`）。v1 首页（`ItemLive.Index`）留到 Task 13 再替换，这里只改它的布局调用；来源页面同理，留到 Task 14。顶栏和左侧菜单的路径用字符串（与 backplane 一致），所以还没有页面的菜单项不影响编译。

**Files:**
- Modify: `apps/singularity_web/lib/singularity_web/components/layouts.ex`、`apps/singularity_web/assets/css/app.css`
- Modify: `apps/singularity_web/lib/singularity_web/components/item_components.ex`
- Create: `apps/singularity_web/lib/singularity_web/live/knowledge_live/index.ex`、`show.ex`
- Delete: `apps/singularity_web/lib/singularity_web/live/item_live/show.ex`
- Modify: `apps/singularity_web/lib/singularity_web/live/item_live/index.ex`、`apps/singularity_web/lib/singularity_web/live/source_live/index.ex`、`form.ex`、`show.ex`
- Modify: `apps/singularity_web/lib/singularity_web/router.ex`、`apps/singularity/lib/singularity/knowledge.ex`（删除 `get_item!/1`）
- Test: `apps/singularity_web/test/singularity_web/live/knowledge_live_test.exs`（新）、`item_live_test.exs`（删一个测试）
- Gettext: `priv/gettext/default.pot`、`knowledge.pot` 及对应 `.po`

- [ ] **Step 1: 写失败的测试**

`apps/singularity_web/test/singularity_web/live/knowledge_live_test.exs`：
```elixir
defmodule SingularityWeb.KnowledgeLiveTest do
  use SingularityWeb.ConnCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.Knowledge
  alias Singularity.Knowledge.FetchDetailsWorker

  describe "index" do
    setup do
      rocket =
        project_fixture(
          title: "acme/rocket",
          summary: "A fast rocket engine",
          attributes: %{"stars" => 12_345, "language" => "Rust"},
          details_fetched_at: now(),
          first_seen_at: DateTime.add(now(), -60, :second)
        )

      tool = project_fixture(title: "solo/tool", details_error: "repository not found")
      label_fixture(rocket, "lang:rust")
      label_fixture(rocket, "favorite", "manual")
      %{rocket: rocket, tool: tool}
    end

    test "shows project cards with stars, language, labels and details state", %{
      conn: conn,
      rocket: rocket
    } do
      {:ok, view, html} = live(conn, ~p"/knowledge")
      card = "#project-#{rocket.id}"

      assert html =~ "Software projects"
      assert has_element?(view, "#{card} a[href='/knowledge/projects/#{rocket.id}']", "acme/rocket")
      assert has_element?(view, card, "A fast rocket engine")
      assert has_element?(view, card, "12,345")
      assert has_element?(view, card, "Rust")
      assert has_element?(view, "#{card} [data-origin='manual']", "favorite")
      assert has_element?(view, "#{card} [data-origin='auto']", "lang:rust")
      assert has_element?(view, "#projects [data-role='details-status']", "Details failed")
    end

    test "uses the Knowledge section menu with browse items and top labels", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge")

      assert has_element?(view, "#top-nav-knowledge[aria-current='page']")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='knowledge-all']")
      assert has_element?(view, "#section-menu a[href='/knowledge']", "All knowledge")
      assert has_element?(view, "#section-menu a[href='/knowledge/projects']", "Software projects")
      assert has_element?(view, "#section-menu a[href='/knowledge?label=lang%3Arust']", "lang:rust")

      {:ok, view, _html} = live(conn, ~p"/knowledge/projects")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='knowledge-projects']")
    end

    test "filters by label and clears the filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge?label=favorite")

      assert has_element?(view, "#active-label", "favorite")
      assert has_element?(view, "#projects", "acme/rocket")
      refute has_element?(view, "#projects", "solo/tool")

      view |> element("#clear-label") |> render_click()
      assert_patch(view, ~p"/knowledge")
      assert has_element?(view, "#projects", "solo/tool")
    end

    test "searches and sorts through the toolbar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge")

      view
      |> element("#project-filters")
      |> render_change(%{"filters" => %{"q" => "rocket", "sort" => "stars"}})

      assert_patch(view, ~p"/knowledge?q=rocket&sort=stars")
      assert has_element?(view, "#projects", "acme/rocket")
      refute has_element?(view, "#projects", "solo/tool")
    end

    test "reloads when a project is updated", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge")
      late = project_fixture(title: "late/arrival")
      send(view.pid, {:project_updated, late.id})
      assert has_element?(view, "#projects", "late/arrival")
    end
  end

  describe "show" do
    setup do
      source = source_fixture(name: "Trending daily")

      project =
        project_fixture(
          title: "elixir-lang/elixir",
          summary: "Simple from zero to scale",
          attributes: %{
            "stars" => 26_710,
            "forks" => 3_717,
            "language" => "Elixir",
            "license" => "Apache-2.0",
            "homepage" => "https://elixir-lang.org/",
            "archived" => false,
            "created_at" => "2011-01-09T08:43:57Z",
            "pushed_at" => "2026-11-10T15:13:02Z"
          },
          details_fetched_at: now()
        )

      observation_fixture(project, source,
        period: "2026-11-09",
        rank: 3,
        observed_at: ~U[2026-11-09 08:00:00Z],
        attributes: %{"since" => "daily", "stars_in_period" => 45}
      )

      observation_fixture(project, nil,
        period: "2026-11-10",
        observed_at: ~U[2026-11-10 08:00:00Z],
        attributes: %{"via" => "manual"}
      )

      label_fixture(project, "lang:elixir")
      label_fixture(project, "mine", "manual")
      %{project: project}
    end

    test "shows GitHub details and source records", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      assert html =~ "Simple from zero to scale"
      assert has_element?(view, "#github-details", "26,710")
      assert has_element?(view, "#github-details", "Apache-2.0")
      assert has_element?(view, "#github-details", "2011-01-09")
      assert has_element?(view, "#github-details a[href='https://elixir-lang.org/']")
      assert has_element?(view, "#github-details a[href='https://github.com/elixir-lang/elixir']")
      assert has_element?(view, "#observations", "Trending daily")
      assert has_element?(view, "#observations", "Added manually")
      assert has_element?(view, "#observations", "45")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='knowledge-projects']")
    end

    test "adds and removes manual labels; automatic labels are read-only", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      view |> form("#label-form", label: %{name: "Favorite"}) |> render_submit()
      assert has_element?(view, "#project-labels [data-origin='manual']", "favorite")

      labels = Knowledge.get_project!(project.id).labels
      mine = Enum.find(labels, &(&1.name == "mine"))
      auto = Enum.find(labels, &(&1.name == "lang:elixir"))

      view |> element("#remove-label-#{mine.id}") |> render_click()
      refute has_element?(view, "#project-labels", "mine")
      refute has_element?(view, "#remove-label-#{auto.id}")
      assert has_element?(view, "#project-labels [data-origin='auto']", "lang:elixir")
    end

    test "shows label validation errors", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")
      html = view |> form("#label-form", label: %{name: " "}) |> render_submit()
      assert html =~ "can&#39;t be blank"
    end

    test "fetch again queues a details fetch", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")
      view |> element("#refetch") |> render_click()
      assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: project.id})
    end

    test "reloads when its project is updated", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      {:ok, _project} =
        Knowledge.put_details(
          project,
          %{title: "elixir-lang/elixir", summary: "Updated summary", attributes: %{}},
          now()
        )

      send(view.pid, {:project_updated, project.id})
      assert render(view) =~ "Updated summary"
    end
  end
end
```

`apps/singularity_web/test/singularity_web/live/item_live_test.exs`：删除 `test "item detail shows the observation history"` 整个测试（`/items/:id` 被项目详情页取代）。

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity_web/test/singularity_web/live/knowledge_live_test.exs`
Expected：FAIL，`/knowledge` 没有路由（`no route found for GET /knowledge`）。

- [ ] **Step 3: 实现布局**

`apps/singularity_web/lib/singularity_web/components/layouts.ex`（整个文件）：
```elixir
defmodule SingularityWeb.Layouts do
  @moduledoc """
  The root layout and the app shell, following backplane_admin: a sticky
  primary appbar with the four sections, a sticky per-section `dm_left_menu`,
  and content in `max-w-7xl`.
  """
  use SingularityWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the app shell.

      <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-all">
        <h1>…</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :socket, Phoenix.LiveView.Socket, required: true
  attr :section, :atom, required: true, values: [:overview, :knowledge, :source, :system]
  attr :active, :string, default: "", doc: "id of the active left-menu item"
  attr :labels, :list, default: [], doc: "top labels as {name, count}, listed in the Knowledge menu"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-full bg-surface text-on-surface">
      <header class="appbar appbar-sticky appbar-primary">
        <.link navigate="/" class="appbar-brand no-underline">
          <.dm_mdi name="bookshelf" class="h-8 w-8" />
          <span class="appbar-title">Singularity</span>
        </.link>
        <nav class="appbar-actions ml-auto" aria-label={gettext("Main navigation")}>
          <.link
            :for={item <- top_nav_items()}
            id={"top-nav-#{item.section}"}
            navigate={item.to}
            class={[
              "appbar-action rounded-md whitespace-nowrap no-underline",
              item.section == @section && "bg-primary-container text-on-primary-container"
            ]}
            aria-current={item.section == @section && "page"}
          >
            {item.label}
          </.link>
        </nav>
      </header>
      <div class="min-h-[calc(100vh-4rem)] bg-surface-container-low lg:flex">
        <.dm_left_menu
          id="section-menu"
          sticky
          socket={@socket}
          groups={left_menu_groups(@section, @labels)}
          active={@active}
          nav_label={gettext("Section navigation")}
          class="sticky top-16 h-[calc(100dvh-4rem)]"
        />
        <main class="min-w-0 flex-1">
          <div class="mx-auto w-full max-w-7xl space-y-6 px-4 py-6 sm:px-6 lg:px-8">
            <.dm_flash_group flash={@flash} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>
    """
  end

  @doc "The appbar's top-level sections."
  def top_nav_items do
    [
      %{section: :overview, label: gettext("Overview"), to: "/"},
      %{section: :knowledge, label: gettext("Knowledge"), to: "/knowledge"},
      %{section: :source, label: gettext("Source"), to: "/source/sources"},
      %{section: :system, label: gettext("System"), to: "/system/github"}
    ]
  end

  @doc "Left-menu groups of a section, in the data shape `dm_left_menu` expects."
  def left_menu_groups(:overview, _labels) do
    [
      %{
        id: "overview",
        label: gettext("Overview"),
        items: [
          %{id: "overview-home", label: gettext("Overview"), to: "/", icon: "view-dashboard-outline"},
          %{
            id: "overview-activity",
            label: gettext("Activity"),
            to: "/overview/activity",
            icon: "timeline-clock-outline"
          }
        ]
      }
    ]
  end

  def left_menu_groups(:knowledge, labels) do
    browse = %{
      id: "browse",
      label: gettext("Browse"),
      items: [
        %{id: "knowledge-all", label: gettext("All knowledge"), to: "/knowledge", icon: "bookshelf"},
        %{
          id: "knowledge-projects",
          label: gettext("Software projects"),
          to: "/knowledge/projects",
          icon: "source-repository"
        }
      ]
    }

    if labels == [],
      do: [browse],
      else: [browse, %{id: "labels", label: gettext("Top labels"), items: label_items(labels)}]
  end

  def left_menu_groups(:source, _labels) do
    [
      %{
        id: "source",
        label: gettext("Source"),
        items: [
          %{id: "source-sources", label: gettext("Sources"), to: "/source/sources", icon: "rss"},
          %{id: "source-add", label: gettext("Add project"), to: "/source/add", icon: "plus-box-outline"},
          %{id: "source-runs", label: gettext("Collection runs"), to: "/source/runs", icon: "history"}
        ]
      }
    ]
  end

  def left_menu_groups(:system, _labels) do
    [
      %{
        id: "system",
        label: gettext("System"),
        items: [
          %{id: "system-github", label: gettext("GitHub"), to: "/system/github", icon: "github"},
          %{id: "system-status", label: gettext("System status"), to: "/system/status", icon: "server"}
        ]
      }
    ]
  end

  @doc "The left-menu item id of a top label, or nil when the label is not listed."
  def label_menu_id(labels, name) do
    labels
    |> Enum.with_index(1)
    |> Enum.find_value(fn {{label, _count}, index} ->
      if label == name, do: "menu-label-#{index}"
    end)
  end

  defp label_items(labels) do
    labels
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, _count}, index} ->
      %{
        id: "menu-label-#{index}",
        label: name,
        to: "/knowledge?" <> URI.encode_query(%{"label" => name}),
        icon: "tag-outline"
      }
    end)
  end
end
```

`apps/singularity_web/assets/css/app.css` 末尾追加：
```css
/* Top-level sections are text links, not the default round icon buttons (as in backplane). */
.appbar-actions .appbar-action {
  width: auto;
  height: auto;
  padding: 0.375rem 0.75rem;
}
```

- [ ] **Step 4: 实现项目组件**

`apps/singularity_web/lib/singularity_web/components/item_components.ex`：把开头的
```elixir
  use Phoenix.Component
```
改为 `use SingularityWeb, :html`，把 `@moduledoc` 改为：
```elixir
  @moduledoc """
  Knowledge item rendering. Software projects are the only kind in v2; a new
  item kind gets its own component here.
  """
```
`item_meta/1`、`observation_meta/1` 暂时保留（v1 首页还在用，Task 13 删除）。在 `format_count/1` 前面加入：
```elixir
  attr :project, :map, required: true

  def project_card(assigns) do
    ~H"""
    <.dm_card id={"project-#{@project.id}"} class="h-full" shadow="sm">
      <:title>
        <.link navigate={~p"/knowledge/projects/#{@project.id}"} class="hover:underline">
          {@project.title}
        </.link>
      </:title>
      <p :if={@project.summary} class="text-sm text-on-surface-variant line-clamp-3">
        {@project.summary}
      </p>
      <div class="flex flex-wrap items-center gap-3 text-xs text-on-surface-variant">
        <span class="inline-flex items-center gap-1">
          <.dm_mdi name="star-outline" class="h-4 w-4" />{format_count(@project.attributes["stars"])}
        </span>
        <span :if={@project.attributes["language"]} class="inline-flex items-center gap-1">
          <.dm_mdi name="code-tags" class="h-4 w-4" />{@project.attributes["language"]}
        </span>
        <.details_status project={@project} />
      </div>
      <.label_badges labels={@project.labels} />
    </.dm_card>
    """
  end

  attr :project, :map, required: true

  def details_status(assigns) do
    ~H"""
    <.dm_badge :if={@project.details_error} variant="error" size="sm" data-role="details-status">
      {dgettext("knowledge", "Details failed")}
    </.dm_badge>
    <.dm_badge
      :if={!@project.details_error && !@project.details_fetched_at}
      variant="info"
      size="sm"
      data-role="details-status"
    >
      {dgettext("knowledge", "Fetching details")}
    </.dm_badge>
    """
  end

  attr :labels, :list, required: true

  def label_badges(assigns) do
    ~H"""
    <div :if={@labels != []} class="flex flex-wrap gap-1">
      <.dm_badge
        :for={label <- @labels}
        size="sm"
        variant={label_variant(label.origin)}
        soft={label.origin == "auto"}
        data-origin={label.origin}
      >
        {label.name}
      </.dm_badge>
    </div>
    """
  end

  @doc "Manual labels use a different style from automatic ones."
  def label_variant("manual"), do: "secondary"
  def label_variant(_auto), do: "neutral"
```
并在 `format_time/1` 后面加入：
```elixir
  def format_date(nil), do: "—"
  def format_date(iso8601) when is_binary(iso8601), do: String.slice(iso8601, 0, 10)
```

- [ ] **Step 5: 实现 Knowledge 页面**

`apps/singularity_web/lib/singularity_web/live/knowledge_live/index.ex`：
```elixir
defmodule SingularityWeb.KnowledgeLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.{Collection, Knowledge}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok, assign(socket, page_title: dgettext("knowledge", "Software projects"))}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, socket |> assign(filters: parse_filters(params)) |> load()}

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{
      socket.assigns.filters
      | q: blank_to_nil(params["q"]),
        sort: parse_sort(params["sort"]),
        page: 1
    }

    {:noreply, push_patch(socket, to: path(socket.assigns.live_action, filters))}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, %{status: "ok"}}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  defp load(%{assigns: %{filters: filters}} = socket) do
    projects =
      Knowledge.list_projects(
        label: filters.label,
        q: filters.q,
        sort: filters.sort,
        page: filters.page,
        per_page: @per_page
      )

    assign(socket,
      projects: projects,
      has_next: length(projects) == @per_page,
      top_labels: Knowledge.top_labels(12)
    )
  end

  defp parse_filters(params) do
    %{
      label: blank_to_nil(params["label"]),
      q: blank_to_nil(params["q"]),
      sort: parse_sort(params["sort"]),
      page: parse_page(params["page"])
    }
  end

  defp parse_sort("stars"), do: :stars
  defp parse_sort(_recent), do: :recent

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 1 -> page
      _other -> 1
    end
  end

  defp parse_page(_value), do: 1

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # The empty filter state has no query string at all.
  defp path(action, filters) do
    query =
      [
        {"label", filters.label},
        {"q", filters.q},
        {"sort", if(filters.sort == :stars, do: "stars")},
        {"page", if(filters.page > 1, do: filters.page)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case {action, query == %{}} do
      {:projects, true} -> ~p"/knowledge/projects"
      {:projects, false} -> ~p"/knowledge/projects?#{query}"
      {_index, true} -> ~p"/knowledge"
      {_index, false} -> ~p"/knowledge?#{query}"
    end
  end

  defp active_item(live_action, top_labels, label) do
    case Layouts.label_menu_id(top_labels, label) do
      nil when live_action == :projects -> "knowledge-projects"
      nil -> "knowledge-all"
      id -> id
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      section={:knowledge}
      labels={@top_labels}
      active={active_item(@live_action, @top_labels, @filters.label)}
    >
      <h1 class="text-2xl font-semibold">{dgettext("knowledge", "Software projects")}</h1>

      <div class="flex flex-wrap items-end gap-4">
        <form id="project-filters" phx-change="filter" phx-submit="filter" class="flex flex-wrap items-end gap-3">
          <.dm_input
            id="filter-q"
            name="filters[q]"
            label={dgettext("knowledge", "Search")}
            placeholder={dgettext("knowledge", "owner/repo or description")}
            value={@filters.q}
            phx-debounce="300"
          />
          <.dm_select
            id="filter-sort"
            name="filters[sort]"
            label={dgettext("knowledge", "Sort by")}
            value={Atom.to_string(@filters.sort)}
            options={[
              {"recent", dgettext("knowledge", "Recently added")},
              {"stars", dgettext("knowledge", "Stars")}
            ]}
          />
        </form>
        <div :if={@filters.label} id="active-label" class="flex items-center gap-2">
          <span class="text-sm">{dgettext("knowledge", "Label")}</span>
          <.dm_badge variant="primary">{@filters.label}</.dm_badge>
          <.link
            id="clear-label"
            patch={path(@live_action, %{@filters | label: nil, page: 1})}
            aria-label={dgettext("knowledge", "Clear label filter")}
          >
            <.dm_mdi name="close" class="h-4 w-4" />
          </.link>
        </div>
      </div>

      <p :if={@projects == []} id="projects-empty">
        {dgettext("knowledge", "No software projects match.")}
      </p>
      <div id="projects" class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <.project_card :for={project <- @projects} project={project} />
      </div>

      <nav class="flex gap-3" aria-label={dgettext("knowledge", "Pagination")}>
        <.link
          :if={@filters.page > 1}
          id="page-prev"
          patch={path(@live_action, %{@filters | page: @filters.page - 1})}
        >
          {dgettext("knowledge", "Previous")}
        </.link>
        <.link
          :if={@has_next}
          id="page-next"
          patch={path(@live_action, %{@filters | page: @filters.page + 1})}
        >
          {dgettext("knowledge", "Next")}
        </.link>
      </nav>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/live/knowledge_live/show.ex`：
```elixir
defmodule SingularityWeb.KnowledgeLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.Knowledge

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Knowledge.get_project!(id)
    if connected?(socket), do: Knowledge.subscribe()

    {:ok,
     socket
     |> assign(page_title: project.title, label_form: empty_label_form())
     |> load(project.id)}
  end

  @impl true
  def handle_event("refetch", _params, socket) do
    {:ok, _job} = Knowledge.enqueue_details(socket.assigns.project.id)
    {:noreply, put_flash(socket, :info, dgettext("knowledge", "Details will be fetched again shortly"))}
  end

  def handle_event("add_label", %{"label" => %{"name" => name}}, socket) do
    case Knowledge.add_label(socket.assigns.project, name) do
      {:ok, _label} ->
        {:noreply,
         socket |> assign(label_form: empty_label_form()) |> load(socket.assigns.project.id)}

      {:error, changeset} ->
        {:noreply, assign(socket, label_form: to_form(changeset, as: :label))}
    end
  end

  def handle_event("remove_label", %{"name" => name}, socket) do
    case Knowledge.remove_label(socket.assigns.project, name) do
      {:error, :auto_label} ->
        {:noreply,
         put_flash(socket, :error, dgettext("knowledge", "Automatic labels cannot be removed"))}

      _removed_or_gone ->
        {:noreply, load(socket, socket.assigns.project.id)}
    end
  end

  @impl true
  def handle_info({:project_updated, id}, %{assigns: %{project: %{id: id}}} = socket),
    do: {:noreply, load(socket, id)}

  def handle_info({:project_updated, _other}, socket),
    do: {:noreply, assign(socket, top_labels: Knowledge.top_labels(12))}

  defp load(socket, id) do
    assign(socket,
      project: Knowledge.get_project!(id),
      observations: Knowledge.list_observations(id),
      top_labels: Knowledge.top_labels(12)
    )
  end

  defp empty_label_form, do: to_form(%{"name" => ""}, as: :label)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      section={:knowledge}
      labels={@top_labels}
      active="knowledge-projects"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-2xl font-semibold">{@project.title}</h1>
        <.details_status project={@project} />
      </div>

      <div class="grid gap-6 lg:grid-cols-3">
        <.dm_card id="github-details" class="lg:col-span-2">
          <:title>{dgettext("knowledge", "GitHub details")}</:title>
          <p :if={@project.summary}>{@project.summary}</p>
          <div class="flex flex-wrap gap-4 text-sm">
            <a href={@project.url} target="_blank" rel="noopener noreferrer" class="inline-flex items-center gap-1 text-primary">
              <.dm_mdi name="github" class="h-4 w-4" />GitHub
            </a>
            <a
              :if={@project.attributes["homepage"]}
              href={@project.attributes["homepage"]}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 text-primary"
            >
              <.dm_mdi name="open-in-new" class="h-4 w-4" />{dgettext("knowledge", "Homepage")}
            </a>
          </div>
          <dl class="grid grid-cols-[10rem_1fr] gap-1 text-sm">
            <dt>{dgettext("knowledge", "Stars")}</dt>
            <dd>{format_count(@project.attributes["stars"])}</dd>
            <dt>{dgettext("knowledge", "Forks")}</dt>
            <dd>{format_count(@project.attributes["forks"])}</dd>
            <dt>{dgettext("knowledge", "Language")}</dt>
            <dd>{@project.attributes["language"] || "—"}</dd>
            <dt>{dgettext("knowledge", "License")}</dt>
            <dd>{@project.attributes["license"] || "—"}</dd>
            <dt>{dgettext("knowledge", "Created")}</dt>
            <dd>{format_date(@project.attributes["created_at"])}</dd>
            <dt>{dgettext("knowledge", "Last pushed")}</dt>
            <dd>{format_date(@project.attributes["pushed_at"])}</dd>
            <dt>{dgettext("knowledge", "Archived")}</dt>
            <dd>
              {if @project.attributes["archived"],
                do: dgettext("knowledge", "Yes"),
                else: dgettext("knowledge", "No")}
            </dd>
            <dt>{dgettext("knowledge", "Details fetched")}</dt>
            <dd>{format_time(@project.details_fetched_at)}</dd>
          </dl>
          <p :if={@project.details_error} id="details-error" class="text-sm text-error">
            {@project.details_error}
          </p>
          <:action>
            <.dm_btn id="refetch" size="sm" phx-click="refetch">
              <.dm_mdi name="refresh" class="h-4 w-4" />{dgettext("knowledge", "Fetch again")}
            </.dm_btn>
          </:action>
        </.dm_card>

        <.dm_card id="project-labels">
          <:title>{dgettext("knowledge", "Labels")}</:title>
          <ul class="flex flex-wrap gap-2">
            <li :for={label <- @project.labels} id={"project-label-#{label.id}"}>
              <.dm_badge
                size="sm"
                variant={label_variant(label.origin)}
                soft={label.origin == "auto"}
                data-origin={label.origin}
              >
                {label.name}
                <button
                  :if={label.origin == "manual"}
                  type="button"
                  id={"remove-label-#{label.id}"}
                  phx-click="remove_label"
                  phx-value-name={label.name}
                  aria-label={dgettext("knowledge", "Remove label %{name}", name: label.name)}
                >
                  <.dm_mdi name="close" class="h-3 w-3" />
                </button>
              </.dm_badge>
            </li>
          </ul>
          <.form for={@label_form} id="label-form" phx-submit="add_label" class="flex items-end gap-2">
            <.dm_input
              id="label-name"
              name={@label_form[:name].name}
              value={@label_form[:name].value}
              label={dgettext("knowledge", "Add label")}
            />
            <.dm_btn type="submit" size="sm" variant="primary">{dgettext("knowledge", "Add")}</.dm_btn>
          </.form>
          <.field_errors form={@label_form} field={:name} />
        </.dm_card>
      </div>

      <h2 class="text-lg font-semibold">{dgettext("knowledge", "Source records")}</h2>
      <.dm_table id="observations" data={@observations}>
        <:col :let={obs} label={dgettext("knowledge", "Time")}>{format_time(obs.observed_at)}</:col>
        <:col :let={obs} label={dgettext("knowledge", "Source")}>
          {if obs.source, do: obs.source.name, else: dgettext("knowledge", "Added manually")}
        </:col>
        <:col :let={obs} label={dgettext("knowledge", "Period")}>{obs.period}</:col>
        <:col :let={obs} label={dgettext("knowledge", "Rank")}>{obs.rank || "—"}</:col>
        <:col :let={obs} label={dgettext("knowledge", "Stars in period")}>
          {format_count(obs.attributes["stars_in_period"])}
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 6: 路由与旧页面**

`apps/singularity_web/lib/singularity_web/router.ex` 的 browser scope 改为：
```elixir
  scope "/", SingularityWeb do
    pipe_through :browser

    live "/", ItemLive.Index, :index
    live "/knowledge", KnowledgeLive.Index, :index
    live "/knowledge/projects", KnowledgeLive.Index, :projects
    live "/knowledge/projects/:id", KnowledgeLive.Show, :show
    live "/sources", SourceLive.Index, :index
    live "/sources/new", SourceLive.Form, :new
    live "/sources/:id/edit", SourceLive.Form, :edit
    live "/sources/:id", SourceLive.Show, :show
  end
```

删除旧的条目详情页：
```bash
git rm apps/singularity_web/lib/singularity_web/live/item_live/show.ex
```

`apps/singularity/lib/singularity/knowledge.ex`：删除 `def get_item!(id), do: Repo.get!(Item, id)`（唯一的调用者已删除）。

`apps/singularity_web/lib/singularity_web/live/item_live/index.ex`：把 `<Layouts.app flash={@flash} current={:items}>` 改为
```heex
    <Layouts.app flash={@flash} socket={@socket} section={:overview} active="overview-home">
```
把 `<.link navigate={~p"/items/#{row.item.id}"} class="font-medium">` 改为
```heex
            <.link navigate={~p"/knowledge/projects/#{row.item.id}"} class="font-medium">
```

`source_live/index.ex`、`form.ex`、`show.ex`：把各自的 `<Layouts.app flash={@flash} current={:sources}>` 改为
```heex
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
```

- [ ] **Step 7: 抽取界面文字**

```bash
devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --merge'
ls apps/singularity_web/priv/gettext apps/singularity_web/priv/gettext/en/LC_MESSAGES
```
Expected：出现 `default.pot`、`knowledge.pot` 和 `en/LC_MESSAGES/default.po`、`knowledge.po`；`errors.pot` 的手写条目保留。

- [ ] **Step 8: 运行测试，确认通过**

Run: `devenv shell -- mix test`
Expected：全部 PASS。

- [ ] **Step 9: 提交**

```bash
devenv shell -- mix format
git add apps/singularity_web/lib/singularity_web/components/layouts.ex \
  apps/singularity_web/assets/css/app.css \
  apps/singularity_web/lib/singularity_web/components/item_components.ex \
  apps/singularity_web/lib/singularity_web/live/knowledge_live/index.ex \
  apps/singularity_web/lib/singularity_web/live/knowledge_live/show.ex \
  apps/singularity_web/lib/singularity_web/live/item_live/index.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/index.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/form.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/show.ex \
  apps/singularity_web/lib/singularity_web/router.ex \
  apps/singularity/lib/singularity/knowledge.ex \
  apps/singularity_web/test/singularity_web/live/knowledge_live_test.exs \
  apps/singularity_web/test/singularity_web/live/item_live_test.exs \
  apps/singularity_web/priv/gettext/*.pot apps/singularity_web/priv/gettext/en/LC_MESSAGES/*.po
git commit -m "feat(web): add the appbar layout and Knowledge pages"
```

---
### Task 13: Overview 页面，移除 v1 条目页

**Files:**
- Create: `apps/singularity_web/lib/singularity_web/components/run_components.ex`
- Create: `apps/singularity_web/lib/singularity_web/live/overview_live/index.ex`、`activity.ex`
- Delete: `apps/singularity_web/lib/singularity_web/live/item_live/index.ex`、`apps/singularity_web/test/singularity_web/live/item_live_test.exs`
- Modify: `apps/singularity_web/lib/singularity_web/router.ex`、`apps/singularity_web/lib/singularity_web/components/item_components.ex`
- Modify: `apps/singularity/lib/singularity/knowledge.ex`（删除 v1 浏览查询）
- Delete: `apps/singularity/test/singularity/knowledge_query_test.exs`（`list_observations/1` 已在 Task 7 的测试中覆盖）
- Test: `apps/singularity_web/test/singularity_web/live/overview_live_test.exs`
- Gettext: `overview.pot`、`source.pot` 及对应 `.po`

- [ ] **Step 1: 写失败的测试**

```elixir
defmodule SingularityWeb.OverviewLiveTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  test "shows an empty knowledge base in English", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Recently added"
    assert has_element?(view, "#recent-empty")
    assert has_element?(view, "#stat-projects", "0")
    assert has_element?(view, "#stat-last-run", "Never")
    assert has_element?(view, "#top-nav-overview[aria-current='page']")
    assert has_element?(view, "#section-menu-navigation[data-active-nav='overview-home']")
  end

  test "shows statistics, recently added projects and popular labels", %{conn: conn} do
    source = source_fixture(name: "Trending")
    source_fixture(name: "Paused", enabled: false)
    fetch_run_fixture(source, status: "ok", item_count: 25)

    old =
      project_fixture(
        title: "acme/old",
        first_seen_at: DateTime.add(now(), -10 * 86_400, :second)
      )

    new = project_fixture(title: "acme/new")
    label_fixture(old, "lang:rust")
    label_fixture(new, "lang:rust")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#stat-projects", "2")
    assert has_element?(view, "#stat-week", "1")
    assert has_element?(view, "#stat-sources", "1")
    assert has_element?(view, "#stat-last-run", "OK")
    assert has_element?(view, "#recent-projects #project-#{new.id}", "acme/new")
    assert has_element?(view, "#label-cloud a[href='/knowledge?label=lang%3Arust']", "lang:rust · 2")
    assert has_element?(view, "#view-all[href='/knowledge']")
  end

  test "updates when projects or runs change", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    project = project_fixture(title: "late/arrival")
    send(view.pid, {:project_updated, project.id})
    assert has_element?(view, "#recent-projects", "late/arrival")

    run = fetch_run_fixture(source_fixture(), status: "failed", error: "HTTP 500")
    send(view.pid, {:fetch_run, run})
    assert has_element?(view, "#stat-last-run", "Failed")
  end

  test "activity merges project additions and collection runs, newest first", %{conn: conn} do
    source = source_fixture(name: "Trending")
    trending = project_fixture(title: "acme/rocket", first_seen_at: ~U[2026-11-10 08:00:00Z])
    observation_fixture(trending, source, observed_at: ~U[2026-11-10 08:00:00Z])
    manual = project_fixture(title: "solo/tool", first_seen_at: ~U[2026-11-11 08:00:00Z])
    observation_fixture(manual, nil, observed_at: ~U[2026-11-11 08:00:00Z])

    run =
      fetch_run_fixture(source,
        status: "failed",
        item_count: 0,
        started_at: ~U[2026-11-10 09:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/overview/activity")

    assert has_element?(view, "#addition-#{trending.id}", "Added from Trending")
    assert has_element?(view, "#addition-#{manual.id}", "Added manually")
    assert has_element?(view, "#run-#{run.id}", "Failed")
    assert :binary.match(html, "addition-#{manual.id}") < :binary.match(html, "run-#{run.id}")
    assert :binary.match(html, "run-#{run.id}") < :binary.match(html, "addition-#{trending.id}")
    assert has_element?(view, "#section-menu-navigation[data-active-nav='overview-activity']")
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity_web/test/singularity_web/live/overview_live_test.exs`
Expected：FAIL，`/` 仍是 v1 条目页（找不到 `#stat-projects`），`/overview/activity` 没有路由。

- [ ] **Step 3: 实现**

`apps/singularity_web/lib/singularity_web/components/run_components.ex`：
```elixir
defmodule SingularityWeb.RunComponents do
  @moduledoc "Fetch run status rendering shared by the Overview and Source pages."
  use SingularityWeb, :html

  attr :run, :map, required: true

  def run_status(assigns) do
    ~H"""
    <.dm_badge size="sm" variant={variant(@run.status)}>{status_label(@run.status)}</.dm_badge>
    """
  end

  def status_label("ok"), do: dgettext("source", "OK")
  def status_label("failed"), do: dgettext("source", "Failed")
  def status_label(_running), do: dgettext("source", "Running")

  defp variant("ok"), do: "success"
  defp variant("failed"), do: "error"
  defp variant(_running), do: "info"
end
```

`apps/singularity_web/lib/singularity_web/live/overview_live/index.ex`：
```elixir
defmodule SingularityWeb.OverviewLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.{Collection, Knowledge, Sources}
  alias SingularityWeb.RunComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok, socket |> assign(page_title: dgettext("overview", "Overview")) |> load()}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    assign(socket,
      project_count: Knowledge.count_projects(),
      week_count: Knowledge.count_projects_since(week_ago),
      enabled_sources: Enum.count(Sources.list_sources(), & &1.enabled),
      last_run: List.first(Collection.list_recent_runs(1)),
      recent: Knowledge.recent_projects(12),
      labels: Knowledge.top_labels(20)
    )
  end

  defp last_run_value(nil), do: dgettext("overview", "Never")
  defp last_run_value(run), do: RunComponents.status_label(run.status)

  defp last_run_description(nil), do: nil
  defp last_run_description(run), do: "#{run.source.name} · #{format_time(run.started_at)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:overview} active="overview-home">
      <h1 class="text-2xl font-semibold">{dgettext("overview", "Overview")}</h1>

      <div id="overview-stats" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.dm_stat
          id="stat-projects"
          title={dgettext("overview", "Software projects")}
          value={Integer.to_string(@project_count)}
        />
        <.dm_stat
          id="stat-week"
          title={dgettext("overview", "Added this week")}
          value={Integer.to_string(@week_count)}
        />
        <.dm_stat
          id="stat-sources"
          title={dgettext("overview", "Enabled sources")}
          value={Integer.to_string(@enabled_sources)}
        />
        <.dm_stat
          id="stat-last-run"
          title={dgettext("overview", "Last collection")}
          value={last_run_value(@last_run)}
          description={last_run_description(@last_run)}
        />
      </div>

      <section class="space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold">{dgettext("overview", "Recently added")}</h2>
          <.link navigate={~p"/knowledge"} id="view-all">{dgettext("overview", "View all")}</.link>
        </div>
        <p :if={@recent == []} id="recent-empty">
          {dgettext("overview", "No software projects yet. Add one or run a source.")}
        </p>
        <div id="recent-projects" class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          <.project_card :for={project <- @recent} project={project} />
        </div>
      </section>

      <section :if={@labels != []} class="space-y-3">
        <h2 class="text-lg font-semibold">{dgettext("overview", "Popular labels")}</h2>
        <div id="label-cloud" class="flex flex-wrap gap-2">
          <.link
            :for={{name, count} <- @labels}
            navigate={~p"/knowledge?#{%{label: name}}"}
            class="no-underline"
          >
            <.dm_badge variant="primary" soft>{name} · {count}</.dm_badge>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/live/overview_live/activity.ex`：
```elixir
defmodule SingularityWeb.OverviewLive.Activity do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.{Collection, Knowledge}

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok, socket |> assign(page_title: dgettext("overview", "Activity")) |> load()}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    additions = Enum.map(Knowledge.list_additions(@limit), &{:addition, &1.at, &1})
    runs = Enum.map(Collection.list_recent_runs(@limit), &{:run, &1.started_at, &1})

    events =
      (additions ++ runs)
      |> Enum.sort_by(fn {_type, at, _event} -> at end, {:desc, DateTime})
      |> Enum.take(@limit)

    assign(socket, events: events)
  end

  defp event_id(:addition, %{item: item}), do: "addition-#{item.id}"
  defp event_id(:run, run), do: "run-#{run.id}"

  defp added_via(nil), do: dgettext("overview", "Added manually")
  defp added_via(source), do: dgettext("overview", "Added from %{source}", source: source.name)

  attr :addition, :map, required: true

  defp addition_event(assigns) do
    ~H"""
    <.dm_mdi name="plus-box-outline" class="h-5 w-5" />
    <.link navigate={~p"/knowledge/projects/#{@addition.item.id}"}>{@addition.item.title}</.link>
    <span class="text-sm text-on-surface-variant">{added_via(@addition.source)}</span>
    """
  end

  attr :run, :map, required: true

  defp run_event(assigns) do
    ~H"""
    <.dm_mdi name="history" class="h-5 w-5" />
    <span>{dgettext("overview", "Collected %{source}", source: @run.source.name)}</span>
    <.run_status run={@run} />
    <span class="text-sm text-on-surface-variant">
      {dngettext("overview", "%{count} item", "%{count} items", @run.item_count)}
    </span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:overview} active="overview-activity">
      <h1 class="text-2xl font-semibold">{dgettext("overview", "Activity")}</h1>
      <p :if={@events == []} id="activity-empty">{dgettext("overview", "Nothing has happened yet.")}</p>
      <ol id="activity" class="space-y-2">
        <li
          :for={{type, at, event} <- @events}
          id={event_id(type, event)}
          class="flex flex-wrap items-center gap-3 rounded border border-outline-variant p-3"
        >
          <span class="w-44 shrink-0 text-xs text-on-surface-variant">{format_time(at)}</span>
          <.addition_event :if={type == :addition} addition={event} />
          <.run_event :if={type == :run} run={event} />
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/router.ex`：把 `live "/", ItemLive.Index, :index` 替换为
```elixir
    live "/", OverviewLive.Index, :index
    live "/overview/activity", OverviewLive.Activity, :index
```

删除 v1 首页和 v1 浏览查询：
```bash
git rm apps/singularity_web/lib/singularity_web/live/item_live/index.ex \
  apps/singularity_web/test/singularity_web/live/item_live_test.exs \
  apps/singularity/test/singularity/knowledge_query_test.exs
```

`apps/singularity_web/lib/singularity_web/components/item_components.ex`：删除 `item_meta/1`（两个子句及其 `attr`）和 `observation_meta/1`（两个子句及其 `attr`）。

`apps/singularity/lib/singularity/knowledge.ex`：删除 `list_items/1`、`observed_from/2`、`observed_to/2`、`item_kind/2`、`list_item_kinds/0`、`latest_period/1`、`list_period/2`（以及 `list_items/1` 的 `@doc`）。保留 `list_observations/1`。

- [ ] **Step 4: 抽取界面文字**

```bash
devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --merge'
```
Expected：新增 `overview.pot`、`source.pot`（RunComponents 的状态文字）和对应的 `en/LC_MESSAGES/*.po`。

- [ ] **Step 5: 运行测试，确认通过**

Run: `devenv shell -- mix test`
Expected：全部 PASS；`grep -rn "list_items\|list_period\|ItemLive" apps/*/lib apps/*/test` 没有输出。

- [ ] **Step 6: 提交**

```bash
devenv shell -- mix format
git add apps/singularity_web/lib/singularity_web/components/run_components.ex \
  apps/singularity_web/lib/singularity_web/live/overview_live/index.ex \
  apps/singularity_web/lib/singularity_web/live/overview_live/activity.ex \
  apps/singularity_web/lib/singularity_web/router.ex \
  apps/singularity_web/lib/singularity_web/components/item_components.ex \
  apps/singularity/lib/singularity/knowledge.ex \
  apps/singularity_web/test/singularity_web/live/overview_live_test.exs \
  apps/singularity_web/priv/gettext/*.pot apps/singularity_web/priv/gettext/en/LC_MESSAGES/*.po
git commit -m "feat(web): add Overview pages and retire v1 item pages"
```

---

### Task 14: Source 页面

**Files:**
- Modify: `apps/singularity_web/lib/singularity_web/live/source_live/index.ex`、`form.ex`、`show.ex`（整文件替换）
- Create: `apps/singularity_web/lib/singularity_web/live/source_live/add.ex`、`runs.ex`
- Modify: `apps/singularity_web/lib/singularity_web/router.ex`
- Modify: `apps/singularity/lib/singularity/sources.ex`（删除 `type_label/1`）、`apps/singularity/test/singularity/sources_test.exs`
- Modify: `apps/singularity/lib/singularity/collectors/github_trending.ex`（表单字段标签改成英文）
- Test: `apps/singularity_web/test/singularity_web/live/source_live_test.exs`（整文件替换）
- Gettext: `source.pot` 及对应 `.po`

- [ ] **Step 1: 写失败的测试**

`apps/singularity_web/test/singularity_web/live/source_live_test.exs`（整个文件）：
```elixir
defmodule SingularityWeb.SourceLiveTest do
  use SingularityWeb.ConnCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.{Knowledge, Sources}
  alias Singularity.Collection.{CollectSourceWorker, FetchRun}
  alias Singularity.Knowledge.FetchDetailsWorker

  describe "index" do
    test "lists sources with type and latest run status", %{conn: conn} do
      source = source_fixture(name: "My fake")
      fetch_run_fixture(source, status: "failed", error: "HTTP 500")

      {:ok, view, html} = live(conn, ~p"/source/sources")
      assert html =~ "My fake"
      assert html =~ "Fake"
      assert html =~ "Failed"
      assert has_element?(view, "#top-nav-source[aria-current='page']")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='source-sources']")
    end

    test "reports unavailable source types", %{conn: conn} do
      source_fixture(kind: "gone")
      {:ok, _view, html} = live(conn, ~p"/source/sources")
      assert html =~ "Unavailable (gone)"
    end

    test "collect now enqueues a job", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/source/sources")

      view |> element("#collect-#{source.id}") |> render_click()
      assert_enqueued(worker: CollectSourceWorker, args: %{source_id: source.id})
    end

    test "toggle and delete", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/source/sources")

      view |> element("#toggle-#{source.id}") |> render_click()
      refute Sources.get_source!(source.id).enabled

      view |> element("#delete-#{source.id}") |> render_click()
      assert Sources.get_source(source.id) == nil
    end
  end

  describe "form" do
    test "new: choose a type, then fill type-specific fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/source/sources/new")
      assert html =~ "GitHub Trending"
      assert html =~ "Fake"

      {:ok, view, html} = live(conn, ~p"/source/sources/new?kind=fake")
      assert html =~ "Topic"

      html =
        view
        |> form("#source-form", source: %{name: "N", config: %{topic: ""}})
        |> render_submit()

      assert html =~ "topic can&#39;t be blank"

      view
      |> form("#source-form", source: %{name: "N", config: %{topic: "x"}})
      |> render_submit()

      [source] = Sources.list_sources()
      assert source.config == %{"topic" => "x"}
      assert_redirect(view, ~p"/source/sources/#{source.id}")
    end

    test "edit updates the source", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/source/sources/#{source.id}/edit")

      view |> form("#source-form", source: %{name: "Renamed"}) |> render_submit()
      assert Sources.get_source!(source.id).name == "Renamed"
    end
  end

  describe "show" do
    test "lists runs and refreshes on broadcasts", %{conn: conn} do
      source = source_fixture()
      fetch_run_fixture(source, status: "failed", error: "HTTP 429")

      {:ok, view, html} = live(conn, ~p"/source/sources/#{source.id}")
      assert html =~ "HTTP 429"

      fetch_run_fixture(source,
        status: "ok",
        item_count: 25,
        started_at: DateTime.add(now(), 60, :second)
      )

      send(view.pid, {:fetch_run, %FetchRun{source_id: source.id, status: "ok"}})
      assert render(view) =~ "25"
    end
  end

  describe "add project" do
    test "adds a project and opens it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/source/add")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='source-add']")

      view
      |> form("#add-project-form", project: %{address: "https://github.com/elixir-lang/elixir"})
      |> render_submit()

      [project] = Knowledge.list_projects()
      {path, flash} = assert_redirect(view)
      assert path == ~p"/knowledge/projects/#{project.id}"
      assert flash["info"] =~ "Project added"
      assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: project.id})
    end

    test "opens a known project with a notice", %{conn: conn} do
      {:ok, project} = Knowledge.add_project("elixir-lang/elixir")
      {:ok, view, _html} = live(conn, ~p"/source/add")

      view
      |> form("#add-project-form", project: %{address: "git@github.com:elixir-lang/elixir.git"})
      |> render_submit()

      {path, flash} = assert_redirect(view)
      assert path == ~p"/knowledge/projects/#{project.id}"
      assert flash["info"] == "Already in the knowledge base"
    end

    test "shows an error for unsupported addresses", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/source/add")

      html =
        view
        |> form("#add-project-form", project: %{address: "https://gitlab.com/a/b"})
        |> render_submit()

      assert html =~ "Only GitHub repositories are supported"
      assert Knowledge.list_projects() == []
    end
  end

  describe "runs" do
    test "lists recent runs across sources", %{conn: conn} do
      fetch_run_fixture(source_fixture(name: "Daily"), status: "failed", error: "HTTP 500")
      fetch_run_fixture(source_fixture(name: "Weekly"), status: "ok", item_count: 25)

      {:ok, view, html} = live(conn, ~p"/source/runs")
      assert html =~ "Daily"
      assert html =~ "Weekly"
      assert has_element?(view, "#runs", "HTTP 500")
      assert has_element?(view, "#runs", "25")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='source-runs']")
    end
  end
end
```

`apps/singularity/test/singularity/sources_test.exs`：删除 `test "type_label/1 reports unavailable kinds"` 整个测试（不可用类型的显示移到 Web 层，由上面的 `"reports unavailable source types"` 覆盖）。

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity_web/test/singularity_web/live/source_live_test.exs`
Expected：FAIL，`/source/sources`、`/source/add`、`/source/runs` 没有路由。

- [ ] **Step 3: 实现**

`apps/singularity_web/lib/singularity_web/router.ex` 的 browser scope 改为：
```elixir
  scope "/", SingularityWeb do
    pipe_through :browser

    live "/", OverviewLive.Index, :index
    live "/overview/activity", OverviewLive.Activity, :index
    live "/knowledge", KnowledgeLive.Index, :index
    live "/knowledge/projects", KnowledgeLive.Index, :projects
    live "/knowledge/projects/:id", KnowledgeLive.Show, :show
    live "/source/sources", SourceLive.Index, :index
    live "/source/sources/new", SourceLive.Form, :new
    live "/source/sources/:id/edit", SourceLive.Form, :edit
    live "/source/sources/:id", SourceLive.Show, :show
    live "/source/add", SourceLive.Add, :new
    live "/source/runs", SourceLive.Runs, :index
  end
```

`apps/singularity_web/lib/singularity_web/live/source_live/index.ex`（整个文件）：
```elixir
defmodule SingularityWeb.SourceLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.{Collection, Sources}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    {:ok, socket |> assign(page_title: dgettext("source", "Sources")) |> load()}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    source = Sources.get_source!(id)
    {:ok, _} = Sources.set_enabled(source, !source.enabled)
    {:noreply, load(socket)}
  end

  def handle_event("collect", %{"id" => id}, socket) do
    {:ok, _job} = Collection.enqueue(String.to_integer(id))
    {:noreply, put_flash(socket, :info, dgettext("source", "Collection queued"))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> Sources.get_source!() |> Sources.delete_source()
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket),
    do: assign(socket, sources: Sources.list_sources(), runs: Collection.latest_runs())

  @doc "The source type's label, or a notice when the type is no longer registered."
  def type_label(source) do
    case Sources.fetch_source_type(source.kind) do
      {:ok, type} -> type.label
      :error -> dgettext("source", "Unavailable (%{kind})", kind: source.kind)
    end
  end

  def enabled_label(true), do: dgettext("source", "Enabled")
  def enabled_label(false), do: dgettext("source", "Disabled")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{dgettext("source", "Sources")}</h1>
        <.link navigate={~p"/source/sources/new"} id="new-source">
          <.dm_btn variant="primary" size="sm">{dgettext("source", "New source")}</.dm_btn>
        </.link>
      </div>

      <.dm_table id="sources" data={@sources}>
        <:col :let={source} label={dgettext("source", "Name")}>
          <.link navigate={~p"/source/sources/#{source.id}"} id={"source-#{source.id}"}>
            {source.name}
          </.link>
        </:col>
        <:col :let={source} label={dgettext("source", "Type")}>{type_label(source)}</:col>
        <:col :let={source} label={dgettext("source", "Interval")}>
          {dngettext("source", "%{count} minute", "%{count} minutes", source.interval_minutes)}
        </:col>
        <:col :let={source} label={dgettext("source", "Status")}>
          <.dm_badge size="sm" variant={if source.enabled, do: "success", else: "warning"}>
            {enabled_label(source.enabled)}
          </.dm_badge>
        </:col>
        <:col :let={source} label={dgettext("source", "Latest run")}>
          <span :if={run = @runs[source.id]}>
            <.run_status run={run} />
            {format_time(run.started_at)} · {dngettext(
              "source",
              "%{count} item",
              "%{count} items",
              run.item_count
            )}
          </span>
          <span :if={!@runs[source.id]}>—</span>
        </:col>
        <:col :let={source} label={dgettext("source", "Actions")}>
          <div class="flex gap-2">
            <.dm_btn
              :if={source.enabled}
              size="sm"
              id={"collect-#{source.id}"}
              phx-click="collect"
              phx-value-id={source.id}
            >
              {dgettext("source", "Collect now")}
            </.dm_btn>
            <.dm_btn size="sm" id={"toggle-#{source.id}"} phx-click="toggle" phx-value-id={source.id}>
              {if source.enabled,
                do: dgettext("source", "Disable"),
                else: dgettext("source", "Enable")}
            </.dm_btn>
            <.link navigate={~p"/source/sources/#{source.id}/edit"}>
              <.dm_btn size="sm">{dgettext("source", "Edit")}</.dm_btn>
            </.link>
            <.dm_btn
              size="sm"
              id={"delete-#{source.id}"}
              phx-click="delete"
              phx-value-id={source.id}
              data-confirm={dgettext("source", "Delete this source and its records? Projects are kept.")}
            >
              {dgettext("source", "Delete")}
            </.dm_btn>
          </div>
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/live/source_live/form.ex`（整个文件）：
```elixir
defmodule SingularityWeb.SourceLive.Form do
  use SingularityWeb, :live_view

  alias Singularity.Sources

  @impl true
  def mount(params, _session, socket),
    do: {:ok, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :new, params) do
    case params["kind"] && Sources.fetch_source_type(params["kind"]) do
      {:ok, type} ->
        source = Sources.new_source(type.kind)

        assign(socket,
          page_title: dgettext("source", "New source: %{type}", type: type.label),
          source: source,
          type: type,
          form: to_form(Sources.change_source(source))
        )

      _no_type ->
        assign(socket,
          page_title: dgettext("source", "Choose a source type"),
          source: nil,
          type: nil,
          form: nil,
          types: Sources.list_source_types()
        )
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    source = Sources.get_source!(id)

    case Sources.fetch_source_type(source.kind) do
      {:ok, type} ->
        assign(socket,
          page_title: dgettext("source", "Edit source"),
          source: source,
          type: type,
          form: to_form(Sources.change_source(source))
        )

      :error ->
        socket
        |> put_flash(
          :error,
          dgettext("source", "Source type %{kind} is unavailable, so the source cannot be edited",
            kind: source.kind
          )
        )
        |> push_navigate(to: ~p"/source/sources")
    end
  end

  @impl true
  def handle_event("validate", %{"source" => params}, socket) do
    changeset =
      socket.assigns.source |> Sources.change_source(params) |> Map.put(:action, :validate)

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
        {:noreply,
         socket
         |> put_flash(:info, dgettext("source", "Saved"))
         |> push_navigate(to: ~p"/source/sources/#{source.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp config_value(form, name) do
    config = form[:config].value || %{}
    Map.get(config, to_string(name)) || Map.get(config, name)
  end

  # Collector field labels are English data; translate them at runtime.
  defp field_label(field), do: Gettext.dgettext(SingularityWeb.Gettext, "source", field.label)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
      <h1 class="text-2xl font-semibold">{@page_title}</h1>

      <ul :if={is_nil(@type)} id="source-types" class="space-y-2">
        <li :for={type <- @types}>
          <.link navigate={~p"/source/sources/new?kind=#{type.kind}"} id={"type-#{type.kind}"}>
            {type.label}
          </.link>
        </li>
      </ul>

      <.form
        :if={@type}
        for={@form}
        id="source-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-lg space-y-3"
      >
        <.dm_input
          id="source-name"
          name="source[name]"
          label={dgettext("source", "Name")}
          value={@form[:name].value}
        />
        <.field_errors form={@form} field={:name} />

        <div :for={field <- @type.fields}>
          <.dm_select
            :if={field.type == :select}
            id={"config-#{field.name}"}
            name={"source[config][#{field.name}]"}
            label={field_label(field)}
            value={config_value(@form, field.name)}
            options={Enum.map(field.options, &{&1, &1})}
          />
          <.dm_input
            :if={field.type != :select}
            id={"config-#{field.name}"}
            type={if field.type == :integer, do: "number", else: "text"}
            name={"source[config][#{field.name}]"}
            label={field_label(field)}
            value={config_value(@form, field.name)}
          />
        </div>
        <.field_errors form={@form} field={:config} />

        <.dm_input
          id="source-interval"
          type="number"
          name="source[interval_minutes]"
          label={dgettext("source", "Collection interval (minutes)")}
          value={@form[:interval_minutes].value}
        />
        <.field_errors form={@form} field={:interval_minutes} />

        <.dm_btn type="submit" variant="primary" id="source-save">{dgettext("source", "Save")}</.dm_btn>
      </.form>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/live/source_live/show.ex`（整个文件）：
```elixir
defmodule SingularityWeb.SourceLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.{Collection, Sources}
  alias SingularityWeb.SourceLive.Index

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    source = Sources.get_source!(id)

    {:ok,
     assign(socket, page_title: source.name, source: source, runs: Collection.list_runs(source.id))}
  end

  @impl true
  def handle_event("collect", _params, socket) do
    {:ok, _job} = Collection.enqueue(socket.assigns.source.id)
    {:noreply, put_flash(socket, :info, dgettext("source", "Collection queued"))}
  end

  @impl true
  def handle_info(
        {:fetch_run, %{source_id: source_id}},
        %{assigns: %{source: %{id: source_id}}} = socket
      ) do
    {:noreply, assign(socket, runs: Collection.list_runs(source_id))}
  end

  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{@source.name}</h1>
        <div class="flex gap-2">
          <.dm_btn :if={@source.enabled} size="sm" id="collect-now" phx-click="collect">
            {dgettext("source", "Collect now")}
          </.dm_btn>
          <.link navigate={~p"/source/sources/#{@source.id}/edit"}>
            <.dm_btn size="sm">{dgettext("source", "Edit")}</.dm_btn>
          </.link>
        </div>
      </div>

      <dl class="grid grid-cols-[10rem_1fr] gap-1 text-sm">
        <dt>{dgettext("source", "Type")}</dt>
        <dd>{Index.type_label(@source)}</dd>
        <dt>{dgettext("source", "Config")}</dt>
        <dd><code>{Jason.encode!(@source.config)}</code></dd>
        <dt>{dgettext("source", "Interval")}</dt>
        <dd>
          {dngettext("source", "%{count} minute", "%{count} minutes", @source.interval_minutes)}
        </dd>
        <dt>{dgettext("source", "Status")}</dt>
        <dd>{Index.enabled_label(@source.enabled)}</dd>
        <dt>{dgettext("source", "Next run")}</dt>
        <dd>{format_time(@source.next_run_at)}</dd>
      </dl>

      <h2 class="text-lg font-semibold">{dgettext("source", "Recent runs")}</h2>
      <.dm_table id="runs" data={@runs}>
        <:col :let={run} label={dgettext("source", "Status")}><.run_status run={run} /></:col>
        <:col :let={run} label={dgettext("source", "Started")}>{format_time(run.started_at)}</:col>
        <:col :let={run} label={dgettext("source", "Finished")}>{format_time(run.finished_at)}</:col>
        <:col :let={run} label={dgettext("source", "Items")}>{run.item_count}</:col>
        <:col :let={run} label={dgettext("source", "Skipped")}>{run.skipped_count}</:col>
        <:col :let={run} label={dgettext("source", "Error")}>{run.error}</:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/live/source_live/add.ex`：
```elixir
defmodule SingularityWeb.SourceLive.Add do
  use SingularityWeb, :live_view

  alias Singularity.Knowledge

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("source", "Add project"),
       form: to_form(%{"address" => ""}, as: :project),
       error: nil
     )}
  end

  @impl true
  def handle_event("add", %{"project" => %{"address" => address}}, socket) do
    case Knowledge.add_project(address) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("source", "Project added; fetching its GitHub details"))
         |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}

      {:existing, project} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("source", "Already in the knowledge base"))
         |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}

      {:error, :unsupported_address} ->
        {:noreply,
         failed(
           socket,
           address,
           dgettext(
             "source",
             "Only GitHub repositories are supported for now, e.g. owner/repo or https://github.com/owner/repo"
           )
         )}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         failed(socket, address, dgettext("source", "The project could not be added; try again"))}
    end
  end

  defp failed(socket, address, message),
    do: assign(socket, form: to_form(%{"address" => address}, as: :project), error: message)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-add">
      <h1 class="text-2xl font-semibold">{dgettext("source", "Add project")}</h1>
      <p class="text-sm text-on-surface-variant">
        {dgettext("source", "Enter a GitHub repository; its details and labels are fetched automatically.")}
      </p>
      <.form for={@form} id="add-project-form" phx-submit="add" class="max-w-xl space-y-3">
        <.dm_input
          id="project-address"
          name={@form[:address].name}
          value={@form[:address].value}
          label={dgettext("source", "Repository address")}
          placeholder="owner/repo"
          errors={List.wrap(@error)}
        />
        <.dm_btn type="submit" variant="primary" id="add-project">{dgettext("source", "Add")}</.dm_btn>
      </.form>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/live/source_live/runs.ex`：
```elixir
defmodule SingularityWeb.SourceLive.Runs do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.Collection

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()

    {:ok,
     assign(socket,
       page_title: dgettext("source", "Collection runs"),
       runs: Collection.list_recent_runs(@limit)
     )}
  end

  @impl true
  def handle_info({:fetch_run, _run}, socket),
    do: {:noreply, assign(socket, runs: Collection.list_recent_runs(@limit))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-runs">
      <h1 class="text-2xl font-semibold">{dgettext("source", "Collection runs")}</h1>
      <p :if={@runs == []} id="runs-empty">{dgettext("source", "No collection has run yet.")}</p>
      <.dm_table :if={@runs != []} id="runs" data={@runs}>
        <:col :let={run} label={dgettext("source", "Source")}>
          <.link navigate={~p"/source/sources/#{run.source_id}"}>{run.source.name}</.link>
        </:col>
        <:col :let={run} label={dgettext("source", "Status")}><.run_status run={run} /></:col>
        <:col :let={run} label={dgettext("source", "Started")}>{format_time(run.started_at)}</:col>
        <:col :let={run} label={dgettext("source", "Items")}>{run.item_count}</:col>
        <:col :let={run} label={dgettext("source", "Error")}>{run.error}</:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

`apps/singularity/lib/singularity/sources.ex`：删除 `type_label/1`（整个函数；中文文案随之去掉）。

`apps/singularity/lib/singularity/collectors/github_trending.ex` 的 `config_fields/0` 改为：
```elixir
  @impl true
  def config_fields do
    [
      %{
        name: :language,
        type: :string,
        label: "Language (leave blank for all)",
        required: false,
        options: []
      },
      %{name: :since, type: :select, label: "Range", required: true, options: @since_values}
    ]
  end
```

- [ ] **Step 4: 抽取界面文字**

```bash
devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --merge'
grep -rnP '\p{Han}' apps/singularity_web/lib apps/singularity/lib
```
Expected：`source.pot` / `source.po` 更新；`grep` 没有输出（界面和领域代码中不再有中文文案）。

- [ ] **Step 5: 运行测试，确认通过**

Run: `devenv shell -- mix test`
Expected：全部 PASS。

- [ ] **Step 6: 提交**

```bash
devenv shell -- mix format
git add apps/singularity_web/lib/singularity_web/live/source_live/index.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/form.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/show.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/add.ex \
  apps/singularity_web/lib/singularity_web/live/source_live/runs.ex \
  apps/singularity_web/lib/singularity_web/router.ex \
  apps/singularity/lib/singularity/sources.ex \
  apps/singularity/lib/singularity/collectors/github_trending.ex \
  apps/singularity/test/singularity/sources_test.exs \
  apps/singularity_web/test/singularity_web/live/source_live_test.exs \
  apps/singularity_web/priv/gettext/*.pot apps/singularity_web/priv/gettext/en/LC_MESSAGES/*.po
git commit -m "feat(web): move source pages under Source and add manual project entry"
```

---
### Task 15: System 页面与导航测试

**Files:**
- Create: `apps/singularity_web/lib/singularity_web/live/system_live/github.ex`、`status.ex`
- Modify: `apps/singularity_web/lib/singularity_web/router.ex`
- Test: `apps/singularity_web/test/singularity_web/live/system_live_test.exs`、`apps/singularity_web/test/singularity_web/live/navigation_test.exs`
- Gettext: `system.pot` 及对应 `.po`

- [ ] **Step 1: 写失败的测试**

`apps/singularity_web/test/singularity_web/live/system_live_test.exs`：
```elixir
defmodule SingularityWeb.SystemLiveTest do
  # Not async: these tests change the GITHUB_TOKEN environment variable.
  use SingularityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.{Knowledge, Settings}

  setup do
    previous = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      if previous,
        do: System.put_env("GITHUB_TOKEN", previous),
        else: System.delete_env("GITHUB_TOKEN")
    end)
  end

  test "sets and clears the GitHub token without echoing it", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/github")
    assert html =~ "Not set"
    refute has_element?(view, "#clear-token")

    html = view |> form("#github-token-form", github: %{token: "ghp_secretabcd"}) |> render_submit()
    assert html =~ "••••abcd"
    refute html =~ "ghp_secretabcd"
    assert Settings.get_github_token() == "ghp_secretabcd"

    view |> element("#clear-token") |> render_click()
    assert Settings.github_token_status() == :unset
    assert render(view) =~ "Not set"
  end

  test "reports a token from the environment", %{conn: conn} do
    System.put_env("GITHUB_TOKEN", "env-token-9876")
    {:ok, view, html} = live(conn, ~p"/system/github")
    assert html =~ "GITHUB_TOKEN"
    assert html =~ "••••9876"
    refute has_element?(view, "#clear-token")
  end

  test "rejects a blank token", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/system/github")
    html = view |> form("#github-token-form", github: %{token: "  "}) |> render_submit()
    assert html =~ "can&#39;t be blank"
  end

  test "status shows the version and queue counts", %{conn: conn} do
    {:ok, _job} = Knowledge.enqueue_details(project_fixture().id)

    {:ok, view, html} = live(conn, ~p"/system/status")
    assert html =~ to_string(Application.spec(:singularity, :vsn))
    assert has_element?(view, "#queue-details-available", "1")
    assert has_element?(view, "#queue-collect-available", "0")
    assert has_element?(view, "#section-menu-navigation[data-active-nav='system-status']")
  end
end
```

`apps/singularity_web/test/singularity_web/live/navigation_test.exs`：
```elixir
defmodule SingularityWeb.NavigationTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @top [
    {"/", "Overview"},
    {"/knowledge", "Knowledge"},
    {"/source/sources", "Source"},
    {"/system/github", "System"}
  ]

  @sections [
    {"/", "overview", "overview-home", [{"/", "Overview"}, {"/overview/activity", "Activity"}]},
    {"/knowledge", "knowledge", "knowledge-all",
     [{"/knowledge", "All knowledge"}, {"/knowledge/projects", "Software projects"}]},
    {"/source/sources", "source", "source-sources",
     [
       {"/source/sources", "Sources"},
       {"/source/add", "Add project"},
       {"/source/runs", "Collection runs"}
     ]},
    {"/system/github", "system", "system-github",
     [{"/system/github", "GitHub"}, {"/system/status", "System status"}]}
  ]

  test "the appbar has four sections, each with its own left menu", %{conn: conn} do
    for {path, section, active, items} <- @sections do
      {:ok, view, _html} = live(conn, path)

      for {top_path, label} <- @top do
        assert has_element?(view, "header.appbar a[href='#{top_path}']", label)
      end

      assert has_element?(view, "#top-nav-#{section}[aria-current='page']")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='#{active}']")

      for {item_path, label} <- items do
        assert has_element?(view, "#section-menu a[href='#{item_path}'][aria-label='#{label}']")
      end
    end
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `devenv shell -- mix test apps/singularity_web/test/singularity_web/live/system_live_test.exs apps/singularity_web/test/singularity_web/live/navigation_test.exs`
Expected：FAIL，`/system/github`、`/system/status` 没有路由。

- [ ] **Step 3: 实现**

`apps/singularity_web/lib/singularity_web/router.ex`：在 `live "/source/runs", SourceLive.Runs, :index` 后面加：
```elixir
    live "/system/github", SystemLive.Github, :show
    live "/system/status", SystemLive.Status, :show
```

`apps/singularity_web/lib/singularity_web/live/system_live/github.ex`：
```elixir
defmodule SingularityWeb.SystemLive.Github do
  use SingularityWeb, :live_view

  alias Singularity.Settings

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: dgettext("system", "GitHub")) |> load()}

  @impl true
  def handle_event("save", %{"github" => %{"token" => token}}, socket) do
    case Settings.put_github_token(token) do
      {:ok, _setting} ->
        {:noreply, socket |> put_flash(:info, dgettext("system", "Token saved")) |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :github))}
    end
  end

  def handle_event("clear", _params, socket) do
    :ok = Settings.clear_github_token()
    {:noreply, socket |> put_flash(:info, dgettext("system", "Token cleared")) |> load()}
  end

  defp load(socket),
    do: assign(socket, status: Settings.github_token_status(), form: to_form(%{}, as: :github))

  defp status_text(:unset), do: dgettext("system", "Not set")

  defp status_text({:env, last4}),
    do:
      dgettext("system", "From the GITHUB_TOKEN environment variable (••••%{last4})",
        last4: last4
      )

  defp status_text({:settings, last4}), do: dgettext("system", "Set ••••%{last4}", last4: last4)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:system} active="system-github">
      <h1 class="text-2xl font-semibold">{dgettext("system", "GitHub")}</h1>
      <.dm_card id="github-token">
        <:title>{dgettext("system", "Access token")}</:title>
        <p class="text-sm text-on-surface-variant">
          {dgettext(
            "system",
            "Without a token GitHub allows 60 requests per hour; detail fetches wait when the limit is reached."
          )}
        </p>
        <p id="token-status">{status_text(@status)}</p>
        <.form for={@form} id="github-token-form" phx-submit="save" class="flex flex-wrap items-end gap-2">
          <.dm_input
            id="github-token-input"
            type="password"
            name="github[token]"
            value=""
            label={dgettext("system", "New token")}
            autocomplete="off"
          />
          <.dm_btn type="submit" variant="primary" id="save-token">
            {dgettext("system", "Save token")}
          </.dm_btn>
        </.form>
        <.field_errors form={@form} field={:value} />
        <:action :if={match?({:settings, _last4}, @status)}>
          <.dm_btn id="clear-token" phx-click="clear">{dgettext("system", "Clear token")}</.dm_btn>
        </:action>
      </.dm_card>
    </Layouts.app>
    """
  end
end
```

`apps/singularity_web/lib/singularity_web/live/system_live/status.ex`：
```elixir
defmodule SingularityWeb.SystemLive.Status do
  use SingularityWeb, :live_view

  # Singularity.System is called fully qualified: an alias would shadow Elixir's System.

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("system", "System status"),
       status: Singularity.System.status()
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, status: Singularity.System.status())}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:system} active="system-status">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{dgettext("system", "System status")}</h1>
        <.dm_btn id="refresh-status" size="sm" phx-click="refresh">
          <.dm_mdi name="refresh" class="h-4 w-4" />{dgettext("system", "Refresh")}
        </.dm_btn>
      </div>
      <.dm_stat id="app-version" title={dgettext("system", "Version")} value={@status.version} />
      <h2 class="text-lg font-semibold">{dgettext("system", "Job queues")}</h2>
      <.dm_table id="queues" data={@status.queues}>
        <:col :let={queue} label={dgettext("system", "Queue")}>{queue.name}</:col>
        <:col :let={queue} label={dgettext("system", "Available")}>
          <span id={"queue-#{queue.name}-available"}>{queue.available}</span>
        </:col>
        <:col :let={queue} label={dgettext("system", "Executing")}>
          <span id={"queue-#{queue.name}-executing"}>{queue.executing}</span>
        </:col>
        <:col :let={queue} label={dgettext("system", "Retryable")}>
          <span id={"queue-#{queue.name}-retryable"}>{queue.retryable}</span>
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: 抽取界面文字**

```bash
devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --merge'
ls apps/singularity_web/priv/gettext/*.pot
```
Expected：`default.pot errors.pot knowledge.pot overview.pot source.pot system.pot` 六个 domain 齐全，`en/LC_MESSAGES` 下有对应的 `.po`。

- [ ] **Step 5: 运行测试，确认通过**

Run: `devenv shell -- mix test`
Expected：全部 PASS。

- [ ] **Step 6: 提交**

```bash
devenv shell -- mix format
git add apps/singularity_web/lib/singularity_web/live/system_live/github.ex \
  apps/singularity_web/lib/singularity_web/live/system_live/status.ex \
  apps/singularity_web/lib/singularity_web/router.ex \
  apps/singularity_web/test/singularity_web/live/system_live_test.exs \
  apps/singularity_web/test/singularity_web/live/navigation_test.exs \
  apps/singularity_web/priv/gettext/*.pot apps/singularity_web/priv/gettext/en/LC_MESSAGES/*.po
git commit -m "feat(web): add System pages"
```

---

### Task 16: AGENTS.md 与版本号

**Files:**
- Modify: `AGENTS.md`
- Modify: `mix.exs`、`apps/singularity/mix.exs`、`apps/singularity_web/mix.exs`（版本 0.1.0 → 0.2.0）

- [ ] **Step 1: 更新 AGENTS.md**

把 `当前设计：...` 一行改为：
```markdown
当前设计：`docs/superpowers/specs/2026-11-11-singularity-knowledge-v2-design.md`（v1 设计 `2026-11-09-singularity-collector-v1-design.md` 中未被它取代的部分仍然有效）。
```

把"技术栈"一节改为：
```markdown
## 技术栈

- Elixir umbrella：`apps/singularity`（领域与采集），`apps/singularity_web`（Phoenix LiveView + phoenix_duskmoon）。
- PostgreSQL；后台任务用 Styx（自维护的 Oban fork）；HTTP 用 http_fetch（统一经过 `Singularity.HttpClient`，测试用 http_test 的 fixture）；HTML 解析用 Floki。
- 界面文字全部经 gettext（`SingularityWeb.Gettext`，msgid 用英文，默认 locale `en`）。按区域分 domain：`overview`、`knowledge`、`source`、`system`；通用文字和布局放 `default`；changeset 错误放 `errors`。
- `singularity_web` 只调用 `Singularity.Sources`、`Singularity.Knowledge`、`Singularity.Collection`、`Singularity.Settings`、`Singularity.System` 的公开函数，不直接访问 Repo、schema 或 `Singularity.Collector`。Web 表单提交的数据一律交给对应上下文的服务函数处理。
```

"新增来源类型"第 2 条改为：
```markdown
2. 把"获取"和"纯函数解析"分开；获取用 `Singularity.HttpClient`，adapter 从应用配置读取；解析部分用真实响应的 fixture 测试，覆盖正常、空结果、单条损坏三种情况。
```

"上游依赖"一节改为：
```markdown
## 上游依赖

Styx、phoenix_duskmoon、duskmoon_bundler、http_fetch、http_test 都是自维护的库。遇到缺陷或缺少功能时，去对应仓库提 issue，不在本地绕过。
```

在"验证"一节的代码块后面加一段：
```markdown
改了界面文字后，在提交前更新翻译模板：

    devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --merge'
```

- [ ] **Step 2: 版本号改为 0.2.0**

`mix.exs`、`apps/singularity/mix.exs`、`apps/singularity_web/mix.exs` 中的 `version: "0.1.0",` 都改为 `version: "0.2.0",`。

- [ ] **Step 3: 运行测试**

Run: `devenv shell -- mix test`
Expected：全部 PASS（System 页面和 `System.status/0` 的测试按 `Application.spec/2` 读取版本）。

- [ ] **Step 4: 提交**

```bash
devenv shell -- mix format
git add AGENTS.md mix.exs apps/singularity/mix.exs apps/singularity_web/mix.exs
git commit -m "docs: update AGENTS.md and version for knowledge v2"
```

---

### Task 17: 最终验证

- [ ] **Step 1: 验证门槛**

```bash
devenv up -d
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --check-up-to-date'
grep -nE '"(req|finch)":' mix.lock
grep -rn 'Req\.\|ItemLive\|list_items\|"/sources\|"/items' apps/*/lib apps/*/test config
git status --short
```
Expected：格式、编译、测试全部通过；翻译模板是最新的；两个 `grep` 没有输出；工作区干净。

- [ ] **Step 2: 部署到本机测试环境**

```bash
deploy/local/deploy.sh
```
Expected：输出 `Singularity test environment is up: http://10.100.10.10:4120/ (<commit>)`。release 启动时运行迁移，旧的 v1 条目和采集记录被清空，来源保留。如果失败，查看 `docker compose -f deploy/local/compose.yaml logs --tail 100 app`，诊断后再重试。

- [ ] **Step 3: 浏览器验收（spec §10）**

在 http://10.100.10.10:4120/ 逐项确认（可用 chrome-devtools MCP 截图记录）：
1. 顶部 appbar：左边 Singularity，右边 Overview、Knowledge、Source、System 四个菜单，当前菜单高亮；切换菜单时左侧菜单随之切换（Overview：Overview / Activity；Knowledge：All knowledge / Software projects / Top labels；Source：Sources / Add project / Collection runs；System：GitHub / System status）；内容区宽度为 `max-w-7xl`。
2. Overview 首页显示四个统计、"Recently added" 和 label 云；界面文字都是英文。
3. Source → Add project 输入 `elixir-lang/elixir`：跳转到项目详情，先显示 "Fetching details"，详情获取完成后（页面实时更新）显示 star、fork、语言、license、创建和推送时间、主页，以及 `lang:elixir` 等自动 label；再次添加同一地址时提示 "Already in the knowledge base"；输入 `https://gitlab.com/a/b` 时表单显示不支持的错误。
4. Source → Sources 中对默认的 GitHub Trending 来源点 "Collect now"：状态由 Running 变为 OK，不需要手动刷新；Collection runs 出现这次记录；Knowledge 列表出现新的软件项目，带 `trending:daily` label，项目详情的来源记录表里能看到上榜记录（来源名、期次、排名、本期 star 增量）。
5. Knowledge 列表：按名称搜索、按 Stars 排序、点击左侧 Top labels 或 Overview 的 label 云按 label 筛选并能清除筛选、分页。
6. 项目详情：添加一个手动 label 后能删除；自动 label 没有删除按钮；点 "Fetch again" 后详情更新，手动 label 保留。
7. System → GitHub：初始为 "Not set"（未设置环境变量时）；保存令牌后只显示 `••••` 加末 4 位；清除后恢复 "Not set"。System → System status 显示版本 0.2.0 和 collect、default、details 三个队列的任务数。

- [ ] **Step 4: 对照 spec 自查并报告**

对照 spec §1 的 8 条成功标准逐条确认，在最终报告中记录：提交列表、执行过的命令及结果、浏览器验收结果，以及未验证的部分。

---

## 计划自查记录

对照 spec 逐节检查过覆盖范围，结论如下：

| Spec | 覆盖的 Task |
|---|---|
| §3 迁移：清空旧数据、`details_fetched_at`/`details_error`、`item_labels`、`source_id` 可空、`settings` | 2 |
| §4 `Address.normalize/1` | 3 |
| §4 `Labels.auto_labels/2` | 4 |
| §4 / §8 GitHub 客户端、`parse_repo/1`、真实 fixture、http_test 覆盖 200/404/限流/连接错误 | 5（HttpClient 在 1） |
| §4 `Settings` | 6 |
| §4 Knowledge 扩展（list/count/recent/get/observations/top_labels/add_label/remove_label） | 7 |
| §4 / §5 `FetchDetailsWorker`、`add_project/1`、获取时机 | 8 |
| §6 `Knowledge.record` 改动、§4 GithubTrending 产出 software_project | 9 |
| §4 `System.status/0` | 10 |
| §7.5 gettext | 11（各页面任务抽取各自 domain） |
| §7 布局、§7.2 Knowledge | 12 |
| §7.1 Overview（含动态） | 13 |
| §7.3 Source（来源、添加、采集记录） | 14 |
| §7.4 System；§9 四个顶级菜单的导航测试 | 15 |
| §8 移除 Req | 1 |
| §10 AGENTS.md | 16 |
| §10 验证门槛、部署与浏览器验收 | 17 |

与 spec 字面不同、需要知道的实现决定：

- `Knowledge.add_project/1` 对已存在的项目返回 `{:existing, item}`，而不是 `{:ok, item}`。spec 的返回类型无法区分"新建"和"已存在"，但 §7.3 要求已存在时提示"已在知识库中"。
- `GitHub.fetch_repo/3` 成功时返回 `{:ok, %{title, summary, attributes}}`，而不是只有 attributes，因为 worker 要按 §4 写入 `title` 和 `summary`；另外多一个 `{:error, :invalid_response}`（200 但响应体不是 JSON 对象），worker 记录错误并重试。选项 `:token`、`:now` 由调用方传入。
- `FetchDetailsWorker` 的 unique 加了 `period: :infinity`：Styx 默认 `period: 60`，只写 `states: :incomplete` 只能保证 60 秒内唯一，达不到 §5"同时只有一个获取任务"。
- `item_observations` 的唯一索引改为 `NULLS NOT DISTINCT`（PostgreSQL 15+，本项目用 17）：否则 `source_id` 为 NULL 的手动记录不受唯一约束，重复添加同一天会写多条。
- "加入时间"、"本周新增"、最近加入的排序都用 `first_seen_at`（等于首次写入时间，可由 `record/3` 和 `add_project/2` 的 `now` 控制）。
- Knowledge 左侧菜单的"软件项目"对应新路由 `/knowledge/projects`（与 `/knowledge` 是同一个 LiveView，只是左侧菜单高亮不同），为以后的知识类型留位置。
- 来源类型的表单字段标签是领域数据，改成英文后在 Web 层用 `Gettext.dgettext/3` 运行时翻译（不会被 `mix gettext.extract` 抽取）；`Sources.type_label/1`（含中文文案）移到 Web 层的 `SourceLive.Index.type_label/1`。
- 版本号改为 0.2.0，System 状态页显示的就是它。
