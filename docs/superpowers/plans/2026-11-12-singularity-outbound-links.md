# 外部链接确认页：实施计划

Spec：`docs/superpowers/specs/2026-11-12-singularity-outbound-links-design.md`。

1. `SingularityWeb.Outbound`：`web?/1`、`path/1`、`external_link/1`，在 `html_helpers` 中导入。
2. `OutboundController` 和 `OutboundHTML`：
   - 路由 `get "/out"`。
   - 合法地址和非法地址两种状态。
   - "返回"只回到本站的 Referer。
3. Markdown（README、Instruction、描述）中的外部链接改为经过 `/out`；项目页的三个外部链接改用 `external_link`。
4. 测试：
   - 新增 `outbound_controller_test.exs`。
   - 在 `knowledge_live_test.exs` 中补充链接断言。
   - 提取 gettext，更新 DESIGN.md。
5. 验证：
   - 运行 format、compile、test。
   - 截图确认页。
