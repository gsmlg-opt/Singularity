# GitHub Trending 语言自动补全

新建和编辑 GitHub Trending 来源时，语言输入框提供 GitHub Trending 的完整编程语言筛选列表。建议显示 GitHub 的语言名称，选中后提交对应的 URL slug。留空继续表示全部语言，已有来源仍可编辑其原有值。

建议列表在输入框下方展开，限定高度并支持滚动、方向键和回车选择。Range 对应的默认采集间隔为 daily 1 天、weekly 7 天、monthly 30 天。切换 Range 时跟随默认值，手填的采集间隔优先。

语言目录取自 [GitHub Trending](https://github.com/trending) 的 Language 筛选菜单。目录随应用发布，打开表单时无需访问 GitHub。采集器接受目录中所有 slug，包括带标点的值，拼接请求时按 URL 路径段编码。
