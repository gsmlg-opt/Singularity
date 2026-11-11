# Singularity

自托管的个人知识库。知识条目是核心；采集只是条目的一种来源。用户配置信息来源，系统收集后沉淀为可回溯的知识条目。设计、界面和数据模型都以知识条目为中心，不以采集为中心。

当前设计：`docs/superpowers/specs/2026-11-11-singularity-knowledge-v2-design.md`（v1 设计 `2026-11-09-singularity-collector-v1-design.md` 中未被它取代的部分仍然有效）。

## 技术栈

- Elixir umbrella：`apps/singularity`（领域与采集），`apps/singularity_web`（Phoenix LiveView + phoenix_duskmoon）。
- PostgreSQL；后台任务用 Styx（自维护的 Oban fork）；HTTP 用 http_fetch（统一经过 `Singularity.HttpClient`，测试用 http_test 的 fixture）；HTML 解析用 Floki。
- 界面文字全部经 gettext（`SingularityWeb.Gettext`，msgid 用英文，默认 locale `en`）。按区域分 domain：`overview`、`knowledge`、`source`、`system`；通用文字和布局放 `default`；changeset 错误放 `errors`。
- `singularity_web` 只调用 `Singularity.Sources`、`Singularity.Knowledge`、`Singularity.Collection`、`Singularity.Settings`、`Singularity.System` 的公开函数，不直接访问 Repo、schema 或 `Singularity.Collector`。Web 表单提交的数据一律交给对应上下文的服务函数处理。

## 界面

改任何界面之前先读 `DESIGN.md`，所有界面改动都必须遵守它（DuskMoon 设计规范，骨架参照 backplane）。

## 新增来源类型

1. 在 `Singularity.Collectors.<Name>` 实现 `Singularity.Collector` 的全部回调。
2. 把"获取"和"纯函数解析"分开；获取用 `Singularity.HttpClient`，adapter 从应用配置读取；解析部分用真实响应的 fixture 测试，覆盖正常、空结果、单条损坏三种情况。
3. 在 `config :singularity, :collectors` 中注册。
4. （可选）在 `SingularityWeb.ItemComponents` 中加一个 kind 专属的展示组件。

如果新增类型时必须改框架或加 migration，说明框架有缺陷，要先更新 spec。

## 上游依赖

Styx、phoenix_duskmoon、duskmoon_bundler、http_fetch、http_test 都是自维护的库。遇到缺陷或缺少功能时，去对应仓库提 issue，不在本地绕过。

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

改了界面文字后，在提交前更新翻译模板：

    devenv shell -- bash -c 'cd apps/singularity_web && mix gettext.extract --merge --no-fuzzy'

## 本机测试环境

每个版本开发完成后，都要部署到本机测试环境，给用户看效果：

    deploy/local/deploy.sh

它会用当前代码构建 release 镜像，连同独立的 Postgres 一起用 Docker Compose 启动，地址是 http://10.100.10.10:4120/。数据保存在 `singularity-test_db` 卷里，重新部署不会丢失。配置在 `deploy/local/.env`（不进 git）。
