# 抓取限速：实施计划

Spec：`docs/superpowers/specs/2026-11-12-singularity-fetch-rate-limits-design.md`。

1. Styx（gsmlg-dev/styx）：
   - Basic 引擎支持 `rate_limit`，Lite 和 Dolphin 拒绝该选项。
   - 文档和测试。
   - CI 通过后用 release workflow 发布 0.2.0。
2. Singularity 依赖升到 `{:styx, "~> 0.2.0"}`。
3. 队列配置和迁移：删除 `details`，新增 `github_web` 和 `github_api`。
4. 采集框架：
   - `Collector.queue/0`，以及 `Collection.enqueue/1` 选择队列。
   - CollectSourceWorker 遇到限流时 snooze。
5. `GitHub.Quota`：ETS 表，在 `GitHub` 的请求前后检查和记录配额。
6. Stars 分页间隔；Trending 的 429 处理。
7. 验证：
   - 运行 format、compile、test。
   - 在 devenv 中观察 README 任务的节奏（约每 2 秒 1 个）和 Trending 任务的节奏。
