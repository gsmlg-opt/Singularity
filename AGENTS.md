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
