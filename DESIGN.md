# Singularity 界面设计规范

所有界面改动必须遵守本文件。依据是 DuskMoon 设计规范（phoenix-duskmoon-design）；页面骨架参照 `gsmlg-opt/backplane` 的 `backplane_admin`。本文件和代码不一致时，以本文件为准，修改代码；如果确实需要偏离，先更新本文件。

## 1. 主题

- 主题偏好来自 `Settings.theme()`：`auto`（跟随系统，默认，与 backplane 一致）、`sunshine`（浅色）、`moonlight`（深色），在 System → Appearance 里切换。根布局对浅色、深色直接渲染 `data-theme`；`auto` 由 `<head>` 里的内联脚本在首次绘制前按 `prefers-color-scheme` 解析，并跟随系统变化。CSS 同时引入 `sunshine` 和 `moonlight`；新增主题要同时改 CSS 引入、`Settings.themes/0` 和这段脚本。
- `<body class="bg-surface text-on-surface">`，每个页面都从 surface 开始。
- 不在应用栏放主题切换器；主题是系统配置。

## 2. 页面骨架

骨架由 `SingularityWeb.Layouts.app/1` 统一提供，页面不要自己再拼一套。

| 区域 | 规定 |
|---|---|
| 应用栏 | `appbar appbar-sticky appbar-primary`。左边是品牌（图标 + Singularity），右边是四个板块：Overview、Knowledge、Source、System。当前板块用 `bg-primary-container text-on-primary-container` 标出 |
| 左侧菜单 | `dm_left_menu`，sticky，底色 **secondary**（`app-sidebar bg-secondary text-secondary-content`），文字 secondary-content，选中项是 secondary-content 底色配 secondary 文字 |
| 内容区 | `<main>` 内用 `mx-auto w-full max-w-7xl space-y-6 px-4 py-6 sm:px-6 lg:px-8`，最上面是 `dm_flash_group` |

左侧菜单的 secondary 配色暂时由 `assets/css/app.css` 里的 `.app-sidebar` 在侧栏范围内重新映射 token 实现，标记为 `WORKAROUND(upstream): duskmoon-dev/duskmoonui#79`。上游提供 secondary 变体后，删除这段 CSS，改用上游的写法。不要在别处复制这种 token 重映射。

## 3. 颜色

1. **只用设计 token。** 禁止 hex、rgb、hsl、颜色名，也禁止 Tailwind 色板类（`bg-blue-500`、`text-gray-600`、`bg-white/80` 等），也不写 `style="color: …"`。
2. **底色和文字成对使用**：`bg-primary` 配 `text-primary-content`，`bg-secondary` 配 `text-secondary-content`，`bg-surface-container-*` 配 `text-on-surface`，`bg-primary-container` 配 `text-on-primary-container`，`bg-error` 配 `text-error-content`。
3. **层级从低到高嵌套**：surface（页面）→ surface-container（卡片）→ surface-container-high（浮层、导航条）→ surface-container-highest（对话框）。不要把低层级放进高层级里。
4. **语义色只表示状态**：`success`、`warning`、`error`、`info` 只用来表示状态（如"详情获取失败"用 error，"获取中"用 info），不用于装饰或品牌。
5. **角色分工**：primary 是品牌和主操作；secondary 是辅助操作和导航（侧栏）；tertiary 是少量强调。
6. **图标继承颜色**：`dm_mdi` 不设 `color`，除非图标必须和周围文字不同色。
7. 边框：装饰性分隔线用 `border-outline-variant`，可交互元素的边框用 `border-outline`。

## 4. 组件

优先使用 `dm_*` 组件，只有没有合适组件时才写原生 HTML 加 Tailwind 布局类。

### 按钮（`dm_btn`）

每个按钮都必须写明 `variant`，不依赖默认值。

| 用途 | variant |
|---|---|
| 当前视图的主操作（保存、添加、新建） | `primary`，**每个视图只有一个** |
| 详情页上的次要操作（立即采集、重新获取、刷新） | `secondary` |
| 页面或面板上的编辑、启用/停用 | `outline` |
| 取消、工具栏里的低强调操作 | `ghost` |
| 删除、清除等破坏性操作 | `error`，并加 `data-confirm` |

表格行内的操作不用上表的文字按钮，见下面的"数据表格"。

moonlight 下 `error` 按钮的文字对比度偏低，属于上游主题的问题（TODO(upstream): duskmoon-dev/duskmoonui#80）。不在本地覆盖，等上游修复后升级依赖即可。

### 其他

| 组件 | 规定 |
|---|---|
| `dm_card` | 详情页上的分组内容（如项目的 GitHub 信息、label）。默认 surface-container，不加颜色 class。**不用卡片展示列表数据** |
| `dm_stat` | 概览指标。只给最关键的一个指标加 `color="primary"` |
| `dm_badge` | label 和状态。状态用语义色，分类区分用 primary/secondary/tertiary |
| `dm_table` | 所有列表数据，见下面的"数据表格" |
| `dm_input` / `dm_select` | 表单字段，不设颜色；错误信息用 `text-error` |
| `dm_flash_group` | 只在骨架里出现一次 |

### 数据表格

- **数据展示一律用表格**（`dm_table`，加 `hover`）：知识列表、最近添加、动态、来源、采集记录、观测历史、队列都是表格。不用卡片网格或自拼的列表展示多条数据。
- 需要行 id（测试、LiveView 更新）时用 stream：`stream_configure(:name, dom_id: …)`，加载时 `stream(…, reset: true)`，表格传 `stream`。空状态用单独的提示文字，不渲染空表格。
- 第一列是条目名，链接到详情页；次要描述放在名字下面，`text-sm text-on-surface-variant line-clamp-1`。
- 操作列放最后，表头 `Actions` 右对齐。**行内操作一律是图标按钮**：用 `SingularityWeb.TableComponents` 的 `row_actions` 包住若干 `row_action`，每个 `row_action` 必须给 `label`（操作名，渲染为 `title` 提示和 `aria-label`）和 `icon`。按钮都是 `ghost`；破坏性操作加 `destructive`（图标变成 `text-error`，不用整块红底，避免每行一个红块）和 `data-confirm`；跳转用 `navigate`。按钮上不写文字。
- 详情页的单条信息（键值）不是列表数据，继续用键值网格。

### 配置页

系统配置分两类，交互方式不同：

- **偏好选择**（主题等，从几个固定选项里选一个）：直接在页面上展示，用分段控件（`segment-control`，`role="radiogroup"`），点击即保存、即生效，不用 modal，也没有保存按钮。参照 backplane 的 Appearance：`<h1>`、一行说明、下面就是控件。
- **需要填写或添加的配置数据**（账户令牌等）：用 `SingularityWeb.SettingsComponents`，数据在 modal 里编辑，规则如下。

- 页面结构：`<h1>` 下面是一个 `settings_container`。同类配置有多项时（如账户），左边列出各项（`entries`），右边是选中项的面板；只有一项时不传 `entries`。
- 面板以 `settings_header` 开头：小标题（eyebrow）、标题、说明，右侧放操作按钮。下面用键值网格展示当前状态。
- **填写类数据在 modal 里编辑**：点"Configure"（`outline`）用 `command="show-modal"` 打开 `dm_modal`，modal 里放表单，底部是 `ghost` 的取消和 `primary` 的保存。保存成功后用 `push_navigate`（或需要换根布局时用 `redirect`）回到本页，modal 随页面重新挂载而关闭；校验失败时留在 modal 里显示错误。
- 破坏性操作（清除令牌等）放在 header 的操作区，`error` 加 `data-confirm`。
- 新增一类账户：在 `entries` 里加一项，再加对应的面板，不新增左侧菜单项。

### 详情页（软件项目）

参照 `KnowledgeLive.Show`，从上到下依次是：

1. **页头**（不放在卡片里）：
   - `<h1>` 和状态徽标。
   - 下面一行描述（`text-on-surface-variant`）。
   - 再下面一行关键事实：图标加数值，`text-sm text-on-surface-variant`，数值用 `text-on-surface`；外链用 `text-primary`。
   - 页面级操作放在右上角：`secondary` 的重新获取，`outline` 的编辑或标记。
2. **状态提示**：用 warning `dm_alert`，例如待移除、已废弃。
3. **两栏**（`grid items-start gap-6 lg:grid-cols-3`）：
   - 主栏 `lg:col-span-2`：叙述性内容（Instruction、README）。
   - 侧栏：键值信息（About）和 label。
   - 卡片标题用 `<h2 class="text-lg font-semibold">`，卡片自己的操作放在标题右侧。
   - 空内容用虚线框提示（`border border-dashed border-outline-variant`）。
4. **历史表格**：全宽，每个表格上面是一个 `<h2>`（来源、来源记录）。

Markdown 一律用 `ItemComponents.markdown/1` 渲染（服务端渲染并 sanitize），长内容在卡片里限高滚动。`markdown-body` 里图片恢复为 inline 的规则在 `assets/css/app.css`，标记为 `WORKAROUND(upstream): duskmoon-dev/duskmoonui#86`；上游修复后删除。

## 5. 排版

| 元素 | class |
|---|---|
| 页面标题 `<h1>` | `text-2xl font-bold`，每页一个 |
| 区块标题 `<h2>` | `text-lg font-semibold` |
| 正文 | `text-base` |
| 次要文字（描述、提示） | `text-sm text-on-surface-variant` |
| 说明文字（时间、元数据） | `text-xs text-on-surface-variant` |
| 行内链接 | `text-primary` |

字体沿用 DuskMoon 默认值，暂不引入自定义字体。

## 6. 布局与间距

- 一个视图只用一种间距尺度：内容页用 `gap-6`，数据密集的列表用 `gap-3` 或 `gap-4`，不要混用。
- 概览指标用 `grid gap-4 sm:grid-cols-2 lg:grid-cols-4`，键值信息用 `grid grid-cols-[10rem_1fr] gap-1 text-sm`。
- 不同类型的页面要有各自的布局：概览是指标加最近条目表格，知识列表是筛选加表格，详情是信息加历史表格，表单是单列 `max-w-lg`。

## 7. 动效

- 只做轻微的悬停反馈（表格行用 `hover` 高亮，可点的卡片最多 `translateY(-2px)`），一次交互只动一个属性。
- 加载状态用 `dm_loading_spinner` 或骨架屏，不自己写 spinner。
- 必须遵守 `prefers-reduced-motion`。

## 8. 文字

界面文字全部经 gettext，规则见 AGENTS.md。

## 9. 改界面前后的检查

1. 新代码里没有 hex、Tailwind 色板类或内联颜色：

       grep -rnE '#[0-9a-fA-F]{3,6}\b|(bg|text|border)-(slate|gray|zinc|neutral|red|blue|green|white|black)' apps/singularity_web/lib apps/singularity_web/assets/css

2. 每个 `dm_btn` 都写了 `variant`，每个视图只有一个 `primary`；表格里没有文字按钮，每个 `row_action` 都有 `label`。
3. 列表数据都在 `dm_table` 里，没有卡片网格。
4. 在本机测试环境或开发服务器上截图，在 moonlight 主题下确认对比度和层级。
