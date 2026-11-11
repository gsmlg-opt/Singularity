# 手动添加软件项目（任意 git 地址）

日期：2026-11-11。在 v2 设计（`2026-11-11-singularity-knowledge-v2-design.md`）之上，替换其中"手动添加项目只支持 GitHub"的部分。

## 目标

在 Source 板块里，"Manual"是和 Trending 并列的一种来源：用户手动填写**名字**和**仓库地址**，添加一个软件项目。地址不限于 GitHub，任何 git 仓库都可以。

## 界面

- Source 左侧菜单的 "Add project"（`/source/add`）改为 **Manual**（`/source/manual`，菜单 id `source-manual`）。旧路由删除，不做重定向。
- Manual 页面：`<h1>Manual</h1>`，右上角一个 `primary` 按钮 "Add project"，打开 modal。下面是手动添加过的软件项目表格，按最近一次手动添加时间倒序，最多 100 条：

  | 列 | 内容 |
  |---|---|
  | Project | 名字（链接到项目详情），下面一行是仓库地址 |
  | Host | 主机名，如 `github.com`、`gitlab.com` |
  | Labels | label 徽标 |
  | Details | 详情状态（见下） |
  | Added | 最近一次手动添加的时间 |

  没有记录时显示提示文字，不显示空表格。
- modal 表单：Name（必填）、Repository address（必填）。底部 ghost 取消、primary "Add"。校验失败留在 modal 里显示字段错误；成功后跳到项目详情页。
  - 新项目：提示 "Project added"（GitHub 项目追加"fetching its details"）。
  - 已有项目：提示 "Already in the knowledge base"，跳到已有项目；不改它的名字。

## 地址

`Singularity.Knowledge.Address.normalize/1` 接受：

- `owner/repo`（没有主机，按 GitHub 处理，和以前一样）。
- `https://host/path`、`http://host/path`，以及不带协议的 `host/path`（第一段含 `.` 才算主机）。
- `ssh://[user@]host[:port]/path`、`git://host[:port]/path`。
- scp 形式 `[user@]host:path`（如 `git@gitlab.com:group/repo.git`）。

规则：

- 去掉 `?query`、`#fragment`、末尾的 `/` 和 `.git`；路径段只能是 `[A-Za-z0-9._~-]`，不能是 `.`、`..`。
- 主机是 `github.com`（含 `www.`）时沿用原规则：只取前两段 `owner/repo`（`/tree/main/...` 之类忽略），owner、repo 的校验不变。
- 其他主机：路径至少一段，全部保留（GitLab 有多级 group）。
- 结果：`%{external_id, host, path, url, github?}`。
  - `external_id` 是小写的 `host/path`（不含端口和用户名），GitHub 项目和以前完全相同，已有数据不受影响。
  - `url`：http(s) 地址是 `scheme://host[:port]/path`；ssh、git、scp 地址保留用户输入（去掉首尾空白和 `.git` 以外不改）。
- 其他情况返回 `{:error, :unsupported_address}`。

## 数据

- `items` 加一列 `custom_title boolean not null default false`。手动添加时 `title` 是用户填的名字，`custom_title = true`；GitHub 详情获取（`put_details`）不再覆盖这种项目的 `title`，其余字段照常更新。
- 只有 `github.com` 的项目会排队获取详情。其他主机的项目：
  - 不排队，`enqueue_details/1` 对它们返回 `{:error, :details_unsupported}`。
  - 创建时加一个自动 label `host:<host>`。
  - 公开函数 `Knowledge.details_supported?/1` 判断项目是否支持获取详情（`external_id` 以 `github.com/` 开头）。
- 手动添加仍然写一条 `source_id` 为 nil 的观测记录（每天一条），Manual 列表就是有这种记录的项目。

## 服务函数

- `Knowledge.change_manual_project(attrs \\ %{})`：给表单用的无 schema changeset（`name`、`address`）。
- `Knowledge.add_project(attrs, now \\ DateTime.utc_now())`：attrs 是 `%{"name" => …, "address" => …}`。
  - 返回 `{:ok, item}`、`{:existing, item}`。
  - 校验失败返回 `{:error, changeset}`：名字为空，地址为空或不支持（错误在 `address` 字段上）。
- `Knowledge.list_manual_projects(limit)`：手动添加过的项目，预加载 labels，带 `manual_added_at`（最近一次手动观测时间），按它倒序。

## 详情状态与详情页

- `details_status`：不支持获取详情的项目显示中性徽标 "No automatic details"，不再显示 "Fetching details"。
- 项目详情页：
  - 支持获取详情的项目：卡片仍叫 "GitHub details"，有 "Fetch again"。
  - 不支持的项目：卡片叫 "Repository"，显示主机和地址，没有 "Fetch again"，也不显示 GitHub 的星数等字段。

## 不做

- GitLab、Gitea 等其他主机的详情获取。
- 修改已有项目的名字或地址。
- 给 GitHub 项目加 `host:` label。
