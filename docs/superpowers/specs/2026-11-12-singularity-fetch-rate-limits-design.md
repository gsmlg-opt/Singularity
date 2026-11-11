# 抓取限速（Styx 队列限速）

日期：2026-11-12。

## 目标

所有对外请求都在 Styx 任务里执行，并按目标站点限速，避免被 GitHub 封禁或限流：

| 目标 | 内容 | 预算 |
|---|---|---|
| `github.com`（HTML） | Trending 页面 | 每 30 秒 1 个请求 |
| `api.github.com` | Stars 分页、项目详情、README | 每 2 秒 1 个请求（≤ 1800/小时）；剩余配额低于 10% 时暂停到配额重置 |

## Styx：队列限速（上游功能）

Styx 0.2.0（gsmlg-dev/styx）新增 Basic 引擎的队列选项 `rate_limit: [allowed: n, period: p]`：

- 同一队列在任意 `p` 秒的滑动窗口内，最多开始 `n` 个任务。
- 按 `attempted_at` 计数，所有节点共享同一个窗口；领取任务时在事务里对该队列加 advisory lock。
- 被限速挡住的任务保持 `available`，由 stager 下一次通知（约每秒一次）时再领取。

## 队列

```elixir
queues: [
  default: 5,
  collect: 1,
  github_web: [limit: 1, rate_limit: [allowed: 1, period: 30]],
  github_api: [limit: 1, rate_limit: [allowed: 1, period: 2]]
]
```

- 删除 `details` 队列。`FetchDetailsWorker`、`FetchReadmeWorker` 改用 `github_api` 队列。
- 迁移把还未完成的 `details` 任务（`available`、`scheduled`、`retryable`）改到 `github_api`。

## 采集框架

- `Singularity.Collector` 新增可选回调 `queue/0`，表示这种来源的采集任务进入哪个队列，默认为 `:collect`。
  - GithubTrending 用 `:github_web`。
  - GithubStars 用 `:github_api`。
- `Collection.enqueue/1` 按来源类型选择队列。
- 一个采集任务可能发出多个请求（Stars 分页）。`github_api` 队列并发为 1，采集任务运行时其他 API 任务不会同时运行，所以 GithubStars 在相邻两页请求之间等待 2 秒（配置项 `page_interval`，测试中为 0）。这样整个 API 的请求速率仍不超过每 2 秒 1 个。

## 配额退避（`Singularity.GitHub.Quota`）

- 每个 API 响应都记录 `x-ratelimit-remaining`、`x-ratelimit-limit`、`x-ratelimit-reset`，存在 ETS 表里，由应用启动时创建。
- 每次发 API 请求前检查：剩余低于上限的 10% 且重置时间未到，就不发请求，直接返回 `{:error, {:rate_limited, 距离重置的秒数}}`。
- 各 worker 对 `{:rate_limited, s}` 一律 snooze `s` 秒：
  - 详情、README 原来就这样处理。
  - CollectSourceWorker 是新增的。
- 测试环境不启用配额（配置 `quota: nil`）；`Quota` 自身用独立的表测试。

## Trending

github.com 返回 429 时：
- 有 `retry-after`：返回 `{:error, {:rate_limited, s}}`，任务 snooze。
- 没有：仍是 `{:http_status, 429}`。

## 测试

- Styx：
  - 限速：窗口内不超额；窗口过后继续；窗口计入已执行的任务。
  - 选项校验；Lite 和 Dolphin 拒绝该选项。
- Singularity：
  - Collector 的 `queue/0`；`Collection.enqueue` 入队到正确的队列。
  - worker 的队列。
  - Quota：记录、低于阈值时阻止、重置后放行。
  - Stars 分页间隔可配置。
  - Trending 429 处理。
  - CollectSourceWorker 遇到限流时 snooze。

## 不做

- 非 GitHub 主机的限速（目前没有对它们的请求）。
- 管理界面上调整限速。
