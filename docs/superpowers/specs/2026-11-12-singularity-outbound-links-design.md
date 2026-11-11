# 外部链接确认页

日期：2026-11-12。

## 目标

点击任何指向站外的链接时，先进入站内的确认页 `/out`。确认页显示目标地址，用户点击"继续"后才跳转。确认页不会自动跳转。

## 规则

- 外部链接指 `http://` 或 `https://` 地址。界面上所有外部链接一律改为 `/out?to=<地址>`：
  - 项目页的 GitHub、Homepage、仓库地址。
  - README 和 Instruction 里的链接（Markdown 链接和 HTML `href`）。README 的相对链接先解析成仓库地址，再改为经过 `/out`。
  - 项目描述里的链接。
- 图片地址不受影响，`src` 仍直接指向原地址。
- 链接在当前标签页打开（不加 `target="_blank"`），这样确认页的"返回"能回到原页面。
- 站内链接、`#` 锚点、`mailto:` 等非 web 地址不变。

## 确认页 `GET /out?to=<地址>`

- 由 `SingularityWeb.OutboundController` 渲染，不用左侧菜单骨架，页面居中显示一张卡片。
- 标题 "Leaving Singularity"。
- 突出显示目标主机名；下面用等宽字体完整显示目标地址，长地址自动换行。
- 操作按钮：
  - `primary` 的 "Continue to <主机>"：普通链接，在当前标签页打开。
  - `ghost` 的 "Back"：回到 `Referer`，只接受本站地址；没有 Referer 或不是本站时回到 `/`。
- 地址不是 http(s)、缺主机或缺参数时：返回 400，提示 "This is not a web address."，只显示 "Back"。
- 响应头带 `Referrer-Policy: no-referrer`，目标站拿不到确认页和来源页的地址。

## 实现

- `SingularityWeb.Outbound`：`web?/1`、`path/1`，以及组件 `external_link/1`，在 `html_helpers` 中导入。
- `ItemComponents.markdown/1` 和 `inline_markdown/1` 在渲染前，把外部链接改为 `Outbound.path/1`。
- DESIGN.md：外部链接一律用 `external_link`，不直接写 `href`。

## 测试

- 控制器：
  - 合法地址：显示主机名和完整地址，"继续"按钮指向原地址。
  - 非法地址：返回 400，没有"继续"按钮。
  - "返回"只回到本站的 Referer。
- 项目页：GitHub 和 Homepage 链接指向 `/out`。
- Markdown：
  - 外部链接（含 README 解析后的相对链接）指向 `/out`。
  - 图片和 `#` 锚点不变。
